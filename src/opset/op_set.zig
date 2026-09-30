//! The op set: the columns, the object index, and every walk the document
//! hands out over them.
//!
//! Upstream `op_set2/op_set.rs` (2,061 lines) is the `OpSet` struct and its
//! whole method surface, plus the six supporting types at `:1432-1609`. This is
//! that file, and it is a **leaf**: it imports every other file in the slice
//! and nothing in the slice imports it.
//!
//! # What the op set is
//!
//! Four fields (`op_set.rs:59-65`): the actor table, the object index, the
//! columns, and the text encoding. It **holds the columns and the object index
//! and hands out walks** — never the reverse. Nothing walks an `OpSet` it did
//! not build over its own columns, and no other file in the slice owns a
//! `Columns(O)`.
//!
//! # Three additions to those four fields, and why each is forced
//!
//! **The allocator.** `AGENTS.md` says every entry point that allocates takes
//! one and does not hide it in a global, and the columns, the object index and
//! the mark cache each own memory. A document is a value in this port, not a
//! global.
//!
//! **The string table.** The two string columns hold *interned ids*, not bytes
//! ([plan §5.3](../../docs/plan.md)); `columns.zig` reads and writes them
//! through a [`StringTable`](columns.zig), and so does every walk
//! ([`op_iter.OpIter.init`](op_iter.zig)). Upstream's `Columns` holds the bytes
//! and needs no table. Holding it here rather than threading it through thirty
//! methods is what keeps the method surface the same shape as upstream's.
//!
//! **The successor buffer.** [`op_iter.OpIter`] materialises each row's
//! successors into a caller-supplied `[]SuccEntry`, because
//! [`opmod.SuccCursors`] holds a span rather than three cursors and so has to
//! carry the flattened position itself (`op_iter.zig:895-910`). Upstream's
//! `OpIter` allocates nothing because its `SuccCursors` is lazy over the
//! columns. The buffer therefore has to live somewhere, and this is the only
//! layer that hands out walks. It is sized to [`op_iter.maxSuccCount`] and
//! refitted on every mutation.
//!
//! **The rule that follows, and it is load-bearing:** a walk borrows the op
//! set's buffer, and the [`Op`](op.zig) a walk hands back points its successors
//! into it, so that row is valid until the next walk over the *same* op set is
//! advanced. Two walks over one op set alive at the same time share the buffer
//! and the later read overwrites the earlier row's successors. A caller that
//! needs two at once — [`top_op.TopOps`] is the case in this slice, which is
//! why it takes a [`top_op.TopScratch`] of its own — allocates its own with
//! `op_iter.maxSuccCount` and builds the walk with
//! [`op_iter.OpIter.init`] directly. This is the port's one borrowing
//! difference from upstream and it is the same one `op_iter.zig` documents.
//!
//! # The load path rebuilds the index, and that is not optional
//!
//! The five index columns are derived state. The exporter writes the sixteen
//! data columns and has no arm for the index (`columns.rs:135-170`), and
//! `Columns.load` builds them empty (`columns.rs:314`). **Every load
//! therefore arrives with no index at all**, and a document that loads with a
//! wrong index reads back plausibly wrong, which is the failure mode this
//! project can least afford. [`OpSet.load`] walks its own rows with an
//! [`indexmod.IndexBuilder`] and installs the result, exactly as
//! `storage/document.rs:332-344` does: flush at every `(obj, elemid_or_key)`
//! change, then `processOp`, then one `processSucc` per successor edge, in that
//! order (`change/collector.rs:39-53`, `:61-72`).
//!
//! # Two invariant checkers, and both are the point of this file
//!
//! [`OpSet.validateOpOrder`] runs [`opmod.Op.step`] over [`OpSet.iter`] and is
//! the gate for the whole port: `step` is the executable form of the row-order
//! invariant (rules **R1**–**R4**, `op.rs:1048-1073`). It answers `false` rather
//! than trapping, so a checker that never fires is a checker that has not been
//! tested; three of the tests below are about making it fire.
//!
//! [`OpSet.validateTopIndex`] asserts per `(obj, elemid_or_key)` group that
//! `first_top == last_vis`, that `top` implies `visible`, and that the three
//! lengths agree (`op_set.rs:177-214`). Upstream asserts; this *reports*, as a
//! [`TopIndexFault`] naming which of the four checks failed, and four of the
//! tests below are about making each one fire.
//!
//! # A third checker, and the one that was not running
//!
//! [`OpSet.seekOpsByIndex`]'s fast/slow cross-check is upstream's own
//! (`op_set.rs:645-649`) and sits behind [`check_slow_paths`], which is
//! `false` unless `-Dslow-path` is passed — **so it was comptime-dead in
//! every build anyone had run**, including every gate in the plan. The
//! option was built and run for the first time on 2026-10-01 and it found a
//! defect on that first run: the fast seek's register could reach behind the
//! object it is in, and the two answers disagreed. See
//! [`OpSet.listRegisterAtPos`] for the mechanism and the measurement.
//!
//! **The lesson is the reason the port keeps the comparison in a test of its
//! own** rather than only in the gated arm: a check behind an option nobody
//! passes is not a check, and a green suite over one is not evidence. The
//! test below the checkers' own compares the two answers unconditionally.
//!
//! # What this file does not declare
//!
//! Four of upstream's query accessors — `keys`, `spans`, `list_range`,
//! `map_range` (`op_set.rs:377-419`) — each wrap a walk of theirs around
//! something computed here, in **one line each**. `Keys`, `SpansInternal`,
//! `ListRange` and `MapRange` are declared in `src/iter/`, outside this slice,
//! and declaring them here would be a second definition of a type the consumer
//! layer owns. So [`OpSet.keys`], [`OpSet.spans`] and [`OpSet.listRange`] are
//! the walks those wrappers take, and [`OpSet.mapRange`] is upstream's whole
//! key-bounding computation — that one is real logic and it is here.
//!
//! # Four types this file re-exports rather than redefines
//!
//! [`QueryNth`] (`op_set.rs:1441-1446`) is declared in
//! [insert.zig](insert.zig), [`OpsFound`] (`op_set.rs:1455-1461`) in
//! [found_op.zig](found_op.zig), and [`ResolvedAction`] (`op_set.rs:1525-1541`)
//! and [`SuccUndo`] (`op_set.rs:1587-1593`) in [op.zig](op.zig). Upstream
//! declares four of its six supporting types in this file and two in
//! submodules it declares; the port declares each in the file that owns the
//! behaviour, and this one re-exports. Two definitions of the same rows would
//! be the failure `columns.zig:48-59` and `insert.zig` both refuse to accept.
//!
//! # The construction order, which is not negotiable
//!
//! A walk is built first and then wrapped. For a map or a list that is
//! `scopeToObj` or `propRange` → `iterRange` → wrap. `OpSet` never hands out a
//! cursor it did not build over its own columns, and every walk it hands out
//! carries the [`op_iter.RowRange`] it was built over, so the three walks inside
//! a wrapper cannot disagree about where the range ends
//! ([`top_op.TopOps.init`](top_op.zig) is the worked example).

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const value = @import("../value.zig");
const clockmod = @import("../clock.zig");
const marksmod = @import("../marks.zig");
const column = @import("../hexane/column.zig");
const rawcol = @import("../hexane/raw.zig");
const btree = @import("../hexane/btree.zig");
const colspec = @import("../storage/column_spec.zig");
const optypes = @import("types.zig");
const ids = @import("ids.zig");
const opmod = @import("op.zig");
const opcols = @import("columns.zig");
const markidx = @import("mark_index.zig");
const opiter = @import("op_iter.zig");
const opquery = @import("op_query.zig");
const opmarks = @import("marks.zig");
const foundop = @import("found_op.zig");
const insertmod = @import("insert.zig");
const indexmod = @import("index.zig");
const vis = @import("visible.zig");
const topop = @import("top_op.zig");
const tools = @import("../iter/tools.zig");

/// The option module `build.zig` generates for `-Dslow-path`. Read by
/// [`check_slow_paths`](op_set.zig) here and by `SlabBTree.assertSound` in
/// `src/hexane/btree.zig`, so the two gated checks turn on and off together.
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Clock = clockmod.Clock;
const ClockRange = clockmod.ClockRange;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const Mark = marksmod.Mark;
const MarkData = optypes.MarkData;
const MarkSet = marksmod.MarkSet;
const Op = opmod.Op;
const Action = optypes.Action;
const OpId = types.OpId;
const ObjId = types.ExId;
const ObjMeta = types.ObjMeta;
const ObjType = types.ObjType;
const OpType = value.OpType;
const ParseError = err.ParseError;
const Prop = types.Prop;
const RawColumns = colspec.RawColumns;
const ReadOpError = opiter.ReadOpError;
const ResolveError = insertmod.ResolveError;
const RowRange = column.RowRange;
const ScalarValue = optypes.ScalarValue;
const SequenceType = types.SequenceType;
const StringTable = opcols.StringTable;
const SuccCursors = opmod.SuccCursors;
const SuccEntry = opmod.SuccEntry;
const OpSuccInsert = opmod.SuccInsert;
const TextEncoding = types.TextEncoding;
const TopError = opiter.ReadOpError || err.Error || err.InternalError;
const ValueMeta = optypes.ValueMeta;

const testing = std.testing;

// ── Re-exports ─────────────────────────────────────────────────────────────

/// Where a new sequence row goes (`QueryNth`, `op_set2/op_set.rs:1441-1446`).
/// Re-exported: it is declared in [insert.zig](insert.zig), which owns the
/// resolver that produces it, and the module doc gives the reason.
pub const QueryNth = insertmod.QueryNth;

/// The rows one register holds (`OpsFound`, `op_set2/op_set.rs:1455-1461`).
/// Re-exported from [found_op.zig](found_op.zig), which owns the grouper.
pub const OpsFound = foundop.OpsFound;

/// The grouper over a contiguous op stream (`OpsFoundIter`,
/// `op_set2/op_set/found_op.rs:24-31`). Re-exported from
/// [found_op.zig](found_op.zig).
pub const OpsFoundIter = foundop.OpsFoundIter;

/// What `OpsFound.resolveAction` decided (`ResolvedAction`,
/// `op_set2/op_set.rs:1525-1541`). Re-exported from [op.zig](op.zig), next to
/// the three constructors that build it.
pub const ResolvedAction = opmod.ResolvedAction;

/// What an undone successor edge has to restore (`SuccUndo`,
/// `op_set2/op_set.rs:1587-1609`). Re-exported from [op.zig](op.zig), which
/// declares [`SuccInsert`] beside it.
pub const SuccUndo = opmod.SuccUndo;

/// Where a successor edge goes (`SuccInsert`, `op_set2/op.rs:933-940`).
/// Re-exported from [op.zig](op.zig), which is where `Op.addSucc` produces it.
pub const SuccInsert = opmod.SuccInsert;

/// The index rebuild's two halves, re-exported because `OpSet.indexBuilder`
/// and `OpSet.setIndexes` hand them across.
pub const IndexBuilder = indexmod.IndexBuilder;
pub const ObjInfo = indexmod.ObjInfo;
pub const ObjIndex = indexmod.ObjIndex;
pub const MarkOrderError = indexmod.MarkOrderError;
pub const Rebuilt = indexmod.Rebuilt;

/// The column set the op set holds (`columns.Columns(O)`), re-exported so a
/// consumer of this file does not have to import `columns.zig` to name the type
/// of a walk's back end.
pub const Columns = opcols.Columns;

/// The sixteen saved columns and the block their ranges index
/// ([`columns.Exported`](columns.zig)).
pub const Exported = opcols.Exported;

/// What [`OpSet.load`] can raise. `MarkOrderError` is
/// [`indexmod.MarkOrderError`], which `index.zig:201-207` declared for exactly
/// this refusal and expects the load path to surface.
pub const LoadError = ParseError || indexmod.MarkOrderError || opiter.ReadOpError || InternalError;

/// What the mark readers can raise. [`marksmod.MarkAccumulator.add`] is the
/// document `Error` and the mark column is `ParseError`, and neither is a
/// member of the other.
pub const MarksError = Error || ParseError || insertmod.ResolveError;

// ── Parent ─────────────────────────────────────────────────────────────────

/// Where an object hangs, and whether the operation that made it is what a
/// reader would see (`Parent`, `op_set2/op_set.rs:1432-1438`).
pub const Parent = struct {
    /// The object the child hangs in.
    obj: ObjId,
    /// What kind of object that is.
    typ: ObjType,
    /// The property of it the child hangs by: a map key, or the index the
    /// child sits at in a sequence.
    prop: Prop,
    /// Whether the child is visible in the clock the caller asked about.
    visible: bool,
};

// ── FoundOpId ───────────────────────────────────────────────────────────────

/// An operation found by its own id, with where it sits in its sequence
/// (`FoundOpId`, `op_set2/op_set.rs:1448-1453`).
pub const FoundOpId = struct {
    /// The row itself.
    op: Op,
    /// Where the element it belongs to sits in the sequence.
    index: usize,
    /// Whether that element is the one a reader would see.
    visible: bool,
};

/// A row and whether a reader would see it as the winner of its register
/// (upstream's `(Op, bool)` from `find_op_by_id_and_vis`,
/// `op_set2/op_set.rs:1100-1140`).
///
/// Upstream returns a bare tuple. Zig's tuple types are anonymous and cannot
/// be named in a signature, so the pair has a name — and the name says what
/// the `bool` is, which the tuple did not.
pub const OpAndVisible = struct {
    /// The row.
    op: Op,
    /// Whether it won its register in the clock the caller asked about.
    visible: bool,
};

/// The two counter values a clock range puts on one row
/// (`get_increment_diff_at_pos`'s `(i64, i64)`, `op_set2/op_set.rs:1165`).
///
/// Named rather than a tuple, and the two fields say which is which: `before`
/// is the sum of the increments the *before* clock covers and `after` the sum
/// of those the *after* clock covers. The caller subtracts them
/// ([`OpSet.getIncrementDiffAtPos`]).
pub const IncrDiff = struct {
    /// What a reader at the start of the range would see.
    before: i64,
    /// What a reader at the end of the range would see.
    after: i64,
};

/// One object and its rows, as [`OpSet.iterObjs`] hands them out.
pub const ObjectRows = struct {
    /// The object and what kind it is.
    meta: ObjMeta,
    /// Its rows, half open.
    range: RowRange,
};

/// A `(obj, register)` group — the unit the index's winner and visibility
/// columns are checked and flushed per (upstream's
/// `Some((op.obj, op.elemid_or_key()))`, `op_set2/op_set.rs:193`).
///
/// Upstream's tuple is what `validate_top_index` compares to decide that a
/// group has ended, and what `ChangeCollector::process_op` compares to decide
/// to `flush` (`:62-66`). The port spells the same pair as a struct so that
/// the two places can share one type and one comparison.
pub const Group = struct {
    /// The parent object.
    obj: ObjId,
    /// The register: a map key, or the element a sequence row belongs to.
    key: KeyRef,
};

/// One end of a map-key range: upstream's `Bound<&str>` at that end
/// ([`OpSet::map_range`], `op_set.rs:406-416`).
///
/// **The excluded arm is not decoration, and the C binding is why.** The
/// reference's `AMmapRange` builds Rust's `begin..end`
/// ([`automerge-c/src/doc/map.rs:518-529`](../../github-automerge-automerge/rust/automerge-c/src/doc/map.rs))
/// and documents `end` as "The key one past the last key in a subrange"
/// (`:482-483`), so a C caller **cannot name an inclusive end at all** — there
/// is no header entry for one. `Included(end)` and `Excluded(end)` name
/// **different** row ranges, one register apart, so a pair of optional keys
/// cannot stand in for a `RangeBounds`: that pair reaches `op_set.rs:408` and
/// `:414` and cannot reach `:409` or `:415` at all.
///
/// **It is declared here and not in `src/read.zig` because
/// [`OpSet.mapRange`] takes it** and `read.zig` imports this file. `read.zig`
/// re-exports it under the same name for the reader's own API.
pub const KeyBound = union(enum) {
    /// The key is in the range (`Bound::Included`, `op_set.rs:408,414`).
    included: []const u8,
    /// The key is one past the range, so the reader does not answer it
    /// (`Bound::Excluded`, `op_set.rs:409,415`).
    excluded: []const u8,
};

/// A winner walk that owns its three successor buffers
/// ([`TopWalk`](op_set.zig), wrapping [`top_op.TopOps`] and
/// [`top_op.TopScratch`]).
///
/// Upstream's `TopOps` is a value that borrows three lazy column cursors and
/// allocates nothing, so nothing has to be freed. The port's is three walks
/// alive at once and each needs its own buffer — which is why
/// [`top_op.TopScratch`](top_op.zig) is three and not one — so
/// [`OpSet.topOps`](op_set.zig) hands out this: the walk, and the buffers it
/// borrowed, in one value with one `deinit`.
pub fn TopWalk(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The walk itself (`TopOps`, `op_set.rs:1085-1091`).
        ops: topop.TopOps(O),
        /// The three buffers [`top_op.TopOps.init`] was given.
        scratch: topop.TopScratch,

        /// The next register's winner, or null at the end of the object's rows
        /// ([`top_op.TopOps.next`](top_op.zig)).
        pub fn next(self: *Self) TopError!?Op {
            return self.ops.next();
        }

        /// Frees the three buffers and nothing else — the walks own no memory.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.scratch.deinit(gpa);
            self.* = undefined;
        }
    };
}

/// One open run of marks while [`OpSet.calculateMarks`] walks an object
/// (upstream's `Option<(usize, Arc<MarkSet>)>`, `op_set.rs:980`).
///
/// The port's [`MarkSet`] is owned rather than reference counted
/// ([src/marks.zig:484-492](../../src/marks.zig) says why) and
/// `MarkSet::from_query_state` builds a fresh one rather than handing back a
/// shared one, so the segment owns its set and `deinit` frees it.
pub const MarkSegment = struct {
    /// The sequence index the run starts at.
    start: usize,
    /// The marks open over the run.
    set: MarkSet,

    /// Frees the mark set and nothing else.
    pub fn deinit(self: *MarkSegment) void {
        self.set.deinit();
        self.* = undefined;
    }
};

// ── IterObjIds ─────────────────────────────────────────────────────────────

/// One object's id and the rows that belong to it (`IterObjIds`,
/// `op_set2/op_set.rs:1543-1585`).
pub const ObjRows = struct {
    /// The object.
    id: ObjId,
    /// Its rows, half open. Contiguous by rule **R1**.
    range: RowRange,
};

/// The run boundaries between objects, over both object columns
/// (`IterObjIds`, `op_set2/op_set.rs:1543-1585`).
///
/// **The only consumer of run iteration in this file.** It walks the two
/// nullable object columns in lockstep and emits a boundary wherever either
/// column's run ends, which is where an object's rows end: the two columns are
/// what sort by object, and an object's rows are a contiguous run of equal
/// values in both (`scopeToObj` is the same statement read as a range, and
/// `top_op.zig`'s `checkOneObject` is the same statement read as a check).
///
/// The lockstep is upstream's `:1554-1584` and its order is load-bearing:
/// when the two runs are the same length both advance, and when they differ
/// the *shorter* one advances and the *longer* one keeps the remainder, so a
/// boundary is emitted at `min(len_ctr, len_actor)`. That is where an object
/// ends even though only one of the two columns changed value.
///
/// Generic over `O` because the column set is
/// ([`op_iter.OpIter`](op_iter.zig) is generic for the same reason); it reads
/// no op accessor, only the two object columns.
pub fn IterObjIds(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set walked.
        pub const Ops = opcols.Columns(O);

        /// `obj_ctr`, read run by run.
        ctr: opcols.UintOptColumn.Iterator,
        /// `obj_actor`, read run by run.
        actor: opcols.ActorOptColumn.Iterator,
        /// The `obj_ctr` run the cursor has read but not consumed.
        next_ctr: ?opcols.UintOptColumn.Run,
        /// The `obj_actor` run the cursor has read but not consumed.
        next_actor: ?opcols.ActorOptColumn.Run,
        /// The row the next boundary starts at.
        pos: usize,

        /// The boundaries in `cols` (`iter_obj_ids`, `op_set.rs:1062-1075`).
        ///
        /// Both runs are read up front, so the first boundary is available
        /// before the first `next` — the same eager read upstream does
        /// (`:1065-1066`).
        pub fn init(cols: *const Ops) ParseError!Self {
            var ctr = try cols.obj_ctr.iterator();
            var actor = try cols.obj_actor.iterator();
            // **The first run of each is read before the cursor is stored**,
            // so the cursor that goes into the struct is the one that has
            // already given it up. Written as a struct literal it is not: the
            // fields are evaluated in order, so `.ctr = ctr` stores the
            // *un*-advanced cursor and `.next_ctr = try ctr.nextRun()` then
            // hands the first run out a second time on the first `next`. That
            // is one phantom boundary for every object and a last range
            // running past the end of the column, which is what the test "the
            // row-order checker…" next door caught.
            const first_ctr = try ctr.nextRun();
            const first_actor = try actor.nextRun();
            return .{
                .ctr = ctr,
                .actor = actor,
                .next_ctr = first_ctr,
                .next_actor = first_actor,
                .pos = 0,
            };
        }

        /// The next object and its rows, or null at the end of the columns
        /// (`Iterator for IterObjIds`, `op_set.rs:1554-1584`).
        ///
        /// The values of both runs are read from the run that was consumed, and
        /// the two runs describe the same rows, so the pair is the object every
        /// row in `start..end` names. Both halves absent is the root
        /// (`types.zig:225`), and one half absent is not an object at all:
        /// upstream `panic!()`s on that (`op_set.rs:1582`) and this is
        /// `error.InvalidValue`, because it is bytes and not a bug
        /// ([error.zig:6-12](../error.zig)). `error.InvalidObjId` says it
        /// better but is a member of the *document* set
        /// ([error.zig:44](../error.zig)), and widening every caller of this
        /// walk to the document set to carry it would be the wrong trade.
        pub fn next(self: *Self) ParseError!?ObjRows {
            const start = self.pos;
            var run_ctr = self.next_ctr orelse {
                // op_set.rs:1581-1582 — one run exhausted means the other is
                // too, because a boundary is emitted at the shorter of the two.
                if (self.next_actor != null) return error.InvalidValue;
                return null;
            };
            var run_actor = self.next_actor orelse return error.InvalidValue;

            // op_set.rs:1558-1575
            switch (std.math.order(run_ctr.count, run_actor.count)) {
                .lt => {
                    run_actor.count -= run_ctr.count;
                    self.next_actor = run_actor;
                    self.pos += run_ctr.count;
                    self.next_ctr = try self.ctr.nextRun();
                },
                .gt => {
                    run_ctr.count -= run_actor.count;
                    self.next_ctr = run_ctr;
                    self.pos += run_actor.count;
                    self.next_actor = try self.actor.nextRun();
                },
                .eq => {
                    self.pos += run_ctr.count;
                    self.next_ctr = try self.ctr.nextRun();
                    self.next_actor = try self.actor.nextRun();
                },
            }
            const end = self.pos;
            const id = types.ExId.fromParts(
                if (run_ctr.value) |c| c else null,
                run_actor.value,
            ) orelse return error.InvalidValue;
            return .{ .id = id, .range = .{ .start = start, .end = end } };
        }
    };
}

// ── The two invariant checkers' results ────────────────────────────────────

/// Which of [`OpSet.validateTopIndex`]'s four checks failed
/// (`op_set2/op_set.rs:177-214`).
///
/// Upstream `assert_eq!`s and `assert!`s, so a failure is a panic with a line
/// number. This is a *checker* whose whole value is being wrong, and a test
/// cannot observe a panic without catching one — so the failure is a value
/// naming the check that failed and the two numbers it compared. Nothing
/// traps, and a caller that ignores the answer reads a document that is wrong
/// in the way the value says, which is strictly better than a document that is
/// wrong silently.
///
/// The four checks, and where each comes from:
///
/// | fault | upstream |
/// | --- | --- |
/// | `top_visible_len` | `assert_eq!(_top.len(), _visible.len())`, `:181` |
/// | `top_row_len` | `assert_eq!(_top.len(), self.len())`, `:182` |
/// | `top_not_visible` | `assert!(vis)` inside `if top`, `:202-207` |
/// | `group_mismatch` | `assert_eq!(first_top, last_vis)` on a group change, `:196` |
/// | `final_group_mismatch` | the same, after the loop, `:212` |
///
/// The last two are the same expression reached by two different paths, and
/// they are separate cases because a caller debugging a failure needs to know
/// whether the document's *last* register is the broken one or an earlier one.
pub const TopIndexFault = union(enum) {
    /// The `top` and `visible` index columns disagree about how many rows
    /// there are (`op_set.rs:181`).
    top_visible_len: struct { top: usize, visible: usize },
    /// The `top` column does not have one row per op (`op_set.rs:182`).
    top_row_len: struct { index: usize, rows: usize },
    /// A row `index.top` calls the winner of its register and `index.visible`
    /// says is not there at all (`op_set.rs:202-207`).
    top_not_visible: usize,
    /// A `(obj, elemid_or_key)` group whose first winner is not its last
    /// visible row (`op_set.rs:196`).
    group_mismatch: struct { at: usize, first_top: ?usize, last_vis: ?usize },
    /// The same, for the group the walk ended in (`op_set.rs:212`).
    final_group_mismatch: struct { at: usize, first_top: ?usize, last_vis: ?usize },

    /// Whether this is the length check, as opposed to the per-group ones.
    /// A caller that only wants "are the lengths right" asks this.
    pub fn isLength(self: TopIndexFault) bool {
        return switch (self) {
            .top_visible_len, .top_row_len => true,
            else => false,
        };
    }
};

/// Which of the two op sets a [`DebugCmpFault`] is about.
///
/// **A fault has to name a side, and that is the whole point of the type.**
/// Upstream's [`OpSet::debug_cmp`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)
/// and this port's `debugCmp` both answer one bit — "the same or not" — and
/// upstream's `assert_eq!`s do not even answer that much: a failing
/// comparison is a panic that names a column. A caller holding two documents
/// that differ cannot tell from that **which one is wrong**, and a document
/// that is wrong in its row order is wrong in every read over it, while a
/// document that is merely *different* is not wrong at all. The two are
/// different faults and this is the type that says which.
pub const DebugSide = enum {
    /// The op set `debugCmp` was called on.
    left,
    /// The op set it was called with.
    right,
};

/// The first thing [`OpSet.debugDiff`] found wrong with two op sets
/// (`op_set2/op_set.rs:68-71` has the one-bit version).
///
/// Null is not a member: [`OpSet.debugDiff`] answers `null` for "the same
/// document" and one of these for anything else, so a caller cannot read a
/// fault as a success.
///
/// **Every variant is a difference a reader could act on, and none of them is
/// "the other side is nicer".** `row_order` and `top_index` are about one op
/// set *by itself*: they are the two invariant checkers
/// ([`OpSet.validateOpOrder`], [`OpSet.validateTopIndex`]). Upstream asserts
/// `validate_op_order` at exactly **one** place in the whole crate — the
/// `debug_assert!` at the end of every apply ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs))
/// — and `validate_top_index` on every load
/// ([`storage/document.rs:351`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
/// so each is a statement about a single document. The rest are about the pair.
pub const DebugCmpFault = union(enum) {
    /// The two actor tables are not the same, so every actor index in every
    /// column below names an actor that is not yet pinned.
    actor_table,
    /// One document measures text in code points and the other in code units.
    text_encoding,
    /// A row breaks the row-order invariant — rules **R1**–**R4** of
    /// [`opmod.Op.step`] (`op.rs:1048-1073`) — and `at` is the first row that
    /// does. `side` says **which document** is the broken one.
    ///
    /// This is the fault the port's own two doors to the same document
    /// disagreeing produces, and it is a *correctness* fault and not a
    /// comparison one: a map reader does not sort
    /// ([`map_range.rs:1486-1490`](iter/map_range.zig)) and a walk's output
    /// has to be in this order for the grouping in
    /// [`OpSet.validateTopIndex`] to mean anything.
    row_order: struct { side: DebugSide, at: usize },
    /// The `top` and `visible` index columns of one document disagree with
    /// its rows or with each other, and `fault` says which of the four checks
    /// failed ([`TopIndexFault`]).
    top_index: struct { side: DebugSide, fault: TopIndexFault },
    /// One column has a different number of rows on the two sides.
    column_length: struct { tag: []const u8, left: usize, right: usize },
    /// One row of one column holds different values.
    column: struct { tag: []const u8, at: usize },
    /// The value arena's bytes differ, with every column above agreeing.
    ///
    /// Upstream's own last check (`columns.rs:132`), and the only one that
    /// compares bytes rather than values: the arena is written in row order,
    /// so a difference here is a difference in the rows, not in the layout.
    value_arena,
    /// The mark index differs. Upstream's `debug_cmp` does not look at it
    /// (`columns.rs:97-133` names sixteen columns and no index column).
    mark_index,
    /// The object tables differ, so the two documents disagree about what is
    /// an object and what it hangs in. Upstream's `debug_cmp` does not look at
    /// this either (`op_set.rs:69-71` reaches only `cols`).
    obj_info,
};

/// The encoded bytes of every column, by name (`Columns::save_checkpoint`,
/// `op_set2/columns.rs:187-215`).
///
/// Upstream's is a `HashMap<&'static str, Vec<u8>>` holding the sixteen data
/// columns and **four** of the five index columns — everything except `top`
/// (`:208-211`). That omission is upstream's and this keeps it, so a
/// checkpoint is comparable with one taken from the reference. It is a
/// *test* instrument: it is how "the undo restored the column byte for byte"
/// is checked, and it is how two builds of the same document are compared
/// without going near a compressed chunk.
///
/// The caller owns the bytes and frees them with
/// [`Checkpoint.deinit`](checkpoint.Deinit).
pub const Checkpoint = std.StringArrayHashMapUnmanaged([]u8);

/// The twenty column names [`OpSet.saveCheckpoint`] fills, in upstream's
/// order (`columns.rs:189-211`).
pub const checkpoint_column_names = [_][]const u8{
    "id_actor", "id_ctr",     "obj_actor",  "obj_ctr",    "key_actor", "key_ctr",
    "key_str",  "insert",     "action",     "value_meta", "value",     "mark_name",
    "expand",   "succ_count", "succ_actor", "succ_ctr",   "visible",   "inc",
    "mark",     "text",
};

// ── OpSet ──────────────────────────────────────────────────────────────────

/// The document's operation rows, its actor table and its object index, and
/// every walk the document hands out over them (`OpSet`,
/// `op_set2/op_set.rs:59-65`).
///
/// Generic over the op type `O` because the column set is
/// ([`columns.Columns(O)`](columns.zig)); upstream's `Columns` is concrete and
/// only upstream's `OpLike` trait is generic, so upstream's `OpSet::splice` is
/// generic while its `OpSet` is not. One type parameter and the whole surface
/// is written once, which is the same split `op_iter.zig` and `insert.zig`
/// make.
///
/// `O` needs the seventeen accessors [`columns.Columns`] calls, plus
/// `objInfo` for [`OpSet.spliceObjects`]. `opmod.Op`, `opmod.OpBuilder`,
/// `opmod.TxOp` and `opmod.ChangeOp` all qualify; a test fixture declares
/// seventeen methods and that is all.
pub fn OpSet(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the op set holds, written in terms of the op type
        /// `O` (`OpSet::cols`, `op_set.rs:63`).
        pub const Ops = opcols.Columns(O);
        /// A walk over rows of this op set (`OpIter`, `op_set.rs:1291-1341`).
        pub const Row = opiter.OpIter(O);
        /// The run-boundary walk (`IterObjIds`, `op_set.rs:1062-1075`).
        pub const ObjIds = IterObjIds(O);
        /// Every object the op set holds, paired with its rows.
        pub const ObjSpan = ObjRows;
        /// The winner walk itself ([`top_op.TopOps`], `op_set.rs:1085-1091`).
        pub const WinnerIter = topop.TopOps(O);
        /// A winner walk that owns its three successor buffers, which is what
        /// [`OpSet.topOps`] hands out and what a caller frees.
        pub const Winners = TopWalk(O);
        /// The top-op walk (`TopIter`, `op_set.rs:1085`).
        pub const Top = topop.TopIter(O);
        /// The visible-op walk (`VisIter`, `op_set.rs:436`, `:941`).
        pub const Visible = vis.VisIter(O);
        /// The insertion-point resolver (`InsertQuery`, `op_set.rs:558`, `:600`).
        pub const Insert = insertmod.InsertQuery(O);
        /// The grouper (`OpsFoundIter`, `op_set.rs:666`).
        pub const Grouped = foundop.OpsFoundIter(opmarks.NoMarkIter(Row));
        /// The visible rows of a range (`OpQuery::visible`, `op_set.rs:618`,
        /// `:717`).
        ///
        /// **This is upstream's composition item for item**
        /// ([`op_query.rs:38-45`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs)):
        /// `FixCounters::new(SkipIter::new(iter, VisIter::new(op_set,
        /// clock, iter.range())), clock.cloned())`. The skipper is
        /// [`Self.Visible`] — the *row-position* walk over `index.visible` for
        /// the present and over `id`, `action` and `succ` for a clock — and the
        /// thing it thins is the plain row walk, [`Self.Row`], which
        /// [`tools.SkipIter`] can step over positionally with `tryNth`.
        ///
        /// **The inner walk must not be a filter, and that is the whole of
        /// this declaration.** A skip counts *rows*; `Op.iter().nth(skip)`
        /// ([`iter/tools.rs:174-185`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs))
        /// moves a cursor `skip` rows. Wrapping the row walk in
        /// [`vis.VisibleOpIter`] — a filter, which
        /// [`tools.takeAt`] can only step one yielded row at a time — makes
        /// `skip` mean "*skip* `skip` **visible** rows*", and the two walks
        /// then disagree about which row `skip` names. Upstream keeps them
        /// apart on purpose: `visible` ([`op_query.rs:38-45`]) thins by the
        /// cheap positional walk, `visible_slow` (`:34-36`) is
        /// `VisibleOpIter`, and the two are separate methods. Composing the
        /// slow half into the fast one is not a slower fast path; it is a
        /// walk that skips the wrong number of rows.
        ///
        /// **This leaves [`vis.VisibleOpIter`] with no production caller in the
        /// port, and that is the correct shape.** It is upstream's *other*
        /// method — `OpQuery::visible_slow` ([`op_query.rs:34-36`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs))
        /// — which upstream reaches from the slow top-op cross-check
        /// ([`top_op.rs:86`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs))
        /// and from `values_for`
        /// ([`automerge.rs:1983`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        /// The port spells the same per-row rule directly instead:
        /// [`Self.Grouped`]'s `next` asks [`opmod.Op.scopeToClock`] row by row
        /// ([`found_op.rs:61`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/found_op.rs)),
        /// which is upstream's own spelling of `OpsFoundIter::next` and does
        /// not go through this type. So the type stays, exercised by every
        /// test in [visible.zig](visible.zig) as upstream's oracle for the
        /// cheap-column rule, and **no call site is left that could put a
        /// filter behind a row count again.**
        pub const VisibleRows = opquery.FixCounters(tools.SkipIter(Op, Row, Visible));
        /// The action and value of each visible row (`action_value_iter`,
        /// `op_set.rs:934-948`).
        pub const ActionValues = tools.SkipIter(opiter.ActionValue, opiter.ActionValueIter, Visible);
        /// The action and value of each register's winner
        /// (`action_value_top_iter`, `op_set.rs:949-959`).
        pub const TopActionValues = tools.SkipIter(opiter.ActionValue, opiter.ActionValueIter, Top);

        /// The allocator every entry point here is given and every owned
        /// buffer belongs to.
        gpa: Allocator,
        /// The document's actors, in actor-index order (`op_set.rs:61`).
        /// Sorted, because [`OpSet.lookupActor`] binary searches them
        /// (`:1187-1189`) and because a change's actor column is written in
        /// that order ([types.zig:108-110]).
        actors: std.ArrayList(ActorId) = .empty,
        /// What every object is and where it hangs (`op_set.rs:62`).
        obj_info: ObjIndex,
        /// The sixteen data columns and the five index columns
        /// (`op_set.rs:63`).
        cols: Ops,
        /// How every text width in the document is measured (`op_set.rs:64`).
        text_encoding: TextEncoding,
        /// The document's string table, which the two string columns and every
        /// walk read through ([plan §5.3](../../docs/plan.md)). The module doc
        /// says why it lives here.
        strings: StringTable,
        /// The successor buffer every walk this hands out borrows. The module
        /// doc's third and fourth sections are the rule.
        succ_scratch: std.ArrayList(SuccEntry) = .empty,

        // ── Structure and lifecycle ─────────────────────────────────────

        /// An op set with no rows, no actors and no objects
        /// (`OpSet::new`, `op_set.rs:1191-1198`).
        pub fn init(gpa: Allocator, text_encoding: TextEncoding, strings: StringTable) ParseError!Self {
            return .{
                .gpa = gpa,
                .obj_info = ObjIndex.init(gpa),
                .cols = try Ops.init(gpa),
                .text_encoding = text_encoding,
                .strings = strings,
            };
        }

        /// An op set with no rows and the given actors
        /// (`OpSet::from_actors`, `op_set.rs:79-86`).
        pub fn fromActors(
            gpa: Allocator,
            actors: []const ActorId,
            text_encoding: TextEncoding,
            strings: StringTable,
        ) ParseError!Self {
            var set = try init(gpa, text_encoding, strings);
            errdefer set.deinit();
            try set.actors.appendSlice(gpa, actors);
            return set;
        }

        /// Frees the columns, the object index, the actor table and the
        /// successor buffer. Not the string table: the document owns that, and
        /// the mark cache inside the columns borrows from it.
        pub fn deinit(self: *Self) void {
            self.actors.deinit(self.gpa);
            self.obj_info.deinit();
            self.cols.deinit();
            self.succ_scratch.deinit(self.gpa);
            self.* = undefined;
        }

        /// The op set's rows, read back out of a document's column set
        /// (`OpSet::load`, `op_set.rs:1200-1205`; `from_parts`, `:1224-1240`).
        ///
        /// **The index is rebuilt here, not by the caller**, and that is the
        /// one difference from upstream that is not a port convention. Upstream
        /// splits the two: `load` reads the columns and `storage/document.rs:332-344`
        /// walks `op_set.iter()` with an `IndexBuilder` and calls
        /// `set_indexes`. The split is possible there because the index is
        /// *stored*; here it is not — the exporter has no arm for it
        /// (`columns.rs:135-170`) and `Columns.load` builds it empty
        /// (`:314`) — so a loader that did the upstream dance would have a
        /// window in which the document has rows and no index at all, and every
        /// query in this file would be reading nothing.
        ///
        /// The rebuild is [`OpSet.rebuildIndex`] verbatim, so the loader is one
        /// line and the mark-order check that follows it
        /// (`storage/document.rs:355`) happens at the same place in the order
        /// as upstream. `error.InvalidMarkOrder` is the class `index.zig:201-207`
        /// declared for it, under the name upstream gives it.
        pub fn load(
            gpa: Allocator,
            cols: RawColumns,
            actors: []const ActorId,
            text_encoding: TextEncoding,
            strings: StringTable,
        ) LoadError!Self {
            var set = try fromParts(gpa, cols, actors, text_encoding, strings);
            errdefer set.deinit();
            try set.rebuildIndex();
            return set;
        }

        /// The columns with **no** index and no object table
        /// (`OpSet::from_parts`, `op_set.rs:1224-1240`).
        ///
        /// Public because [`OpSet.load`] is `fromParts` plus one step and the
        /// difference is the whole reason this file owns the rebuild; a caller
        /// that wants the two apart has a reason this port cannot see.
        pub fn fromParts(
            gpa: Allocator,
            cols: RawColumns,
            actors: []const ActorId,
            text_encoding: TextEncoding,
            strings: StringTable,
        ) ParseError!Self {
            var set = try init(gpa, text_encoding, strings);
            errdefer set.deinit();
            try set.actors.appendSlice(gpa, actors);
            // **The load comes before the free, and that order is the whole
            // point.** `Columns.deinit` ends in `self.* = undefined`
            // (`columns.rs:647`), so deiniting first and then calling a
            // fallible function leaves `set.cols` poisoned: if that call
            // returns an error the assignment never happens and the
            // `errdefer` above frees 0xAA bytes. `test/fixtures/missing_actor.automerge`
            // is the input that reached it — `Ops.load` answers
            // `error.InvalidValue` for it — and the process died in
            // `Slab.deinit` on a `General protection exception`.
            //
            // The general rule this is: `X.deinit(); try …; X = …` is a defect
            // anywhere in this slice, and the only question is whether the gap
            // between the free and the assignment is fallible.
            const loaded = try Ops.load(gpa, cols, strings);
            set.cols.deinit();
            set.cols = loaded;
            // The successor buffer is refitted here rather than left for the
            // first mutation, because a loaded set is read before it is
            // written: every walk borrows it ([op_set.zig](op_set.zig)'s module
            // doc) and a walk over a row with one successor would answer
            // `error.TooLarge` on a buffer that holds none
            // ([op_iter.zig:988](op_iter.zig)).
            try set.refitScratch();
            return set;
        }

        /// The op set's columns as a document column set (`OpSet::export`,
        /// `op_set.rs:1242-1244`).
        ///
        /// Sixteen data columns and **no index column**, because the index is
        /// derived and the exporter has no arm for it (`columns.rs:135-170`).
        pub fn exportColumns(self: *const Self, gpa: Allocator) ParseError!Exported {
            return self.cols.exportColumns(gpa, self.strings);
        }

        /// Every column's encoded bytes, by name (`OpSet::save_checkpoint`,
        /// `op_set.rs:74-76`).
        ///
        /// Sixteen data columns and four index columns; `top` is not among
        /// them, which is upstream's list (`columns.rs:187-215`) and this
        /// keeps. The caller owns the result.
        ///
        /// **Two of these entries are comparable only within one op set.** The
        /// `key_str` and `mark_name` entries are the encoded **ids**
        /// ([plan §5.3](../../docs/plan.md)), where upstream's are
        /// `self.key_str.save()` and `self.mark_name.save()` over
        /// `Column<Option<String>>` (`columns.rs:196`, `:201`) and so hold the
        /// strings themselves. A checkpoint is an undo target here and is
        /// compared only against another taken from the same op set, which is
        /// what makes it sound; **a checkpoint is not a document identity**, and
        /// [`OpSet.debugCmp`] is the thing that is.
        pub fn saveCheckpoint(self: *const Self, gpa: Allocator) ParseError!Checkpoint {
            var out: Checkpoint = .empty;
            errdefer freeCheckpoint(gpa, &out);
            const cols = &self.cols;
            try putCheckpoint(gpa, "id_actor", try cols.id_actor.encode(gpa), &out);
            try putCheckpoint(gpa, "id_ctr", try cols.id_ctr.encode(gpa), &out);
            try putCheckpoint(gpa, "obj_actor", try cols.obj_actor.encode(gpa), &out);
            try putCheckpoint(gpa, "obj_ctr", try cols.obj_ctr.encode(gpa), &out);
            try putCheckpoint(gpa, "key_actor", try cols.key_actor.encode(gpa), &out);
            try putCheckpoint(gpa, "key_ctr", try cols.key_ctr.encode(gpa), &out);
            try putCheckpoint(gpa, "key_str", try cols.key_str.encode(gpa), &out);
            try putCheckpoint(gpa, "insert", try cols.insert.encode(gpa), &out);
            try putCheckpoint(gpa, "action", try cols.action.encode(gpa), &out);
            try putCheckpoint(gpa, "value_meta", try cols.value_meta.encode(gpa), &out);
            try putCheckpoint(gpa, "value", try cols.value.encode(gpa), &out);
            try putCheckpoint(gpa, "mark_name", try cols.mark_name.encode(gpa), &out);
            try putCheckpoint(gpa, "expand", try cols.expand.encode(gpa), &out);
            try putCheckpoint(gpa, "succ_count", try cols.succ_count.encode(gpa), &out);
            try putCheckpoint(gpa, "succ_actor", try cols.succ_actor.encode(gpa), &out);
            try putCheckpoint(gpa, "succ_ctr", try cols.succ_ctr.encode(gpa), &out);
            try putCheckpoint(gpa, "visible", try cols.index.visible.encode(gpa), &out);
            try putCheckpoint(gpa, "inc", try cols.index.inc.encode(gpa), &out);
            try putCheckpoint(gpa, "mark", try cols.index.mark.data.encode(gpa), &out);
            try putCheckpoint(gpa, "text", try cols.index.text.encode(gpa), &out);
            return out;
        }

        /// The document's rows, one per line, for a human
        /// (`OpSet::dump`, `op_set.rs:88-93`; `Columns::dump`, `columns.rs:512-573`).
        ///
        /// `std.debug.print` is this port's `log!`; there is no subscriber to
        /// configure and the column set is the thing being looked at.
        pub fn dump(self: *const Self) ParseError!void {
            std.debug.print("OpSet\n  len: {}\n  actors: {d}\n", .{
                self.len(),
                self.actors.items.len,
            });
            std.debug.print("::::: id       obj      key        elem     i v t tx act suc value\n", .{});
            var id_a = try self.cols.id_actor.iterator();
            var id_c = try self.cols.id_ctr.iterator();
            var act = try self.cols.action.iterator();
            var obj_a = try self.cols.obj_actor.iterator();
            var obj_c = try self.cols.obj_ctr.iterator();
            var key_str = try self.cols.key_str.iterator();
            var key_a = try self.cols.key_actor.iterator();
            var key_c = try self.cols.key_ctr.iterator();
            var succ = try self.cols.succ_count.prefixIter();
            var insert = try self.cols.insert.prefixIter();
            var text_col = try self.cols.index.text.prefixIter();
            var visible_col = try self.cols.index.visible.iterator();
            var top = try self.cols.index.top.prefixIter();
            var pos: usize = 0;
            while (true) {
                const a = try id_a.next();
                const c = try id_c.next();
                const oa = try obj_a.next();
                const oc = try obj_c.next();
                if (a == null and c == null and oa == null and oc == null) break;
                // A nullable column's cursor answers `??T`: the outer null is
                // the cursor running out and the inner one is the column
                // holding null, and the two are different facts
                // (`column.zig:3417`). The row records the column's own
                // value, so the outer null is what becomes null.
                const row = dumpRow{
                    .pos = pos,
                    .id_actor = a,
                    .id_ctr = c,
                    .obj_actor = if (oa) |v| v else null,
                    .obj_ctr = if (oc) |v| v else null,
                    .key_str = if (try key_str.next()) |v| v else null,
                    .key_actor = if (try key_a.next()) |v| v else null,
                    .key_ctr = if (try key_c.next()) |v| v else null,
                    .insert = if (try insert.next()) |pv| pv.value else null,
                    .visible = try visible_col.next(),
                    .top = if (try top.next()) |pv| pv.value else null,
                    .text = if (try text_col.next()) |pv| pv.value else null,
                    // The action column holds wire codes, not the enum
                    // (`columns.rs:29`), so the row decodes the way every
                    // reader does (`op_iter.zig:759-761`).
                    .action = if (try act.next()) |code|
                        try optypes.actionFromCode(code)
                    else
                        null,
                    .succ = if (try succ.next()) |pv| pv.value else null,
                };
                row.print();
                pos += 1;
            }
        }

        /// The first thing wrong with this op set and `other`, or null when
        /// they are the same document — and the answer to **both** questions a
        /// caller has: "are these the same?" and "is either of them sound?".
        ///
        /// # The two questions, and why one function answers them together
        ///
        /// Upstream has one method, [`OpSet::debug_cmp`]
        /// (`op_set2/op_set.rs:68-71`), it is `#[cfg(test)]`, and it compares
        /// **positionally**: `Columns::debug_cmp` walks each column with
        /// `a.to_vec()` against `b.to_vec()` (`op_set2/columns.rs:99-130`).
        /// That positional comparison is **correct and is kept**. It is not a
        /// document identity that this port may relax, for two reasons that
        /// are the same reason:
        ///
        /// * **Upstream requires the order.** `Op::step` (`op.rs:1048-1073`)
        ///   is the row-order invariant, and the only call site of
        ///   `validate_op_order` in the whole crate is
        ///   `debug_assert!(doc.ops.validate_op_order())` at the end of
        ///   `BatchApply::apply` ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
        ///   The port runs it always, and it is the one the two doors to one
        ///   document disagree about.
        /// * **A reader requires the order.** A map walk does not sort: "the
        ///   reader does not sort, so this order is the answer order"
        ///   ([`map_range.zig:1486-1490`](iter/map_range.zig)), and a walk's
        ///   output has to be in it for the per-group rule in
        ///   [`OpSet.validateTopIndex`] to mean anything. Two op sets holding
        ///   the same rows in a different order are **not** the same document;
        ///   one of them reads differently.
        ///
        /// So this compares row for row, and the addition over upstream is that
        /// it also **runs both invariant checkers, on both op sets, and says
        /// which side failed**. Upstream's `debug_cmp` cannot: it is a
        /// one-bit answer with no side, and the caller is left with two
        /// documents that differ and no way to tell which is the broken one.
        /// That is the blind spot this closes, and it is not hypothetical — it
        /// is what the two doors to one document disagreeing look like: the
        /// local-transaction path and the apply path place a row in different
        /// places, the comparison reports `id_actor differs at row 0`, and
        /// nothing in the report says which document is out of order.
        ///
        /// # What it compares
        ///
        /// Upstream delegates to `Columns::debug_cmp` (`columns.rs:97-133`),
        /// which compares fifteen columns' values and the raw value arena's
        /// bytes. This compares those, the two prefix-indexed columns
        /// `debug_cmp` reaches through `to_vec()` on a `PrefixColumn`, and the
        /// four more that upstream's list omits, so that **all twenty** of
        /// [`checkpoint_column_names`] are compared — plus the actor table and
        /// the `obj_info` table, which upstream's does not look at and which
        /// are what make this the instrument for "a save and a reload are the
        /// same document" rather than only "a save and a reload have the same
        /// rows".
        ///
        /// **The two string columns are compared as strings, not as ids.**
        /// Upstream's are `hexane::Column<Option<String>>` (`columns.rs:24`,
        /// `:32`) and `Columns::debug_cmp` compares them with
        /// `assert_eq!(self.key_str.to_vec(), other.key_str.to_vec())`
        /// (`columns.rs:111`, `:117`), so the question upstream answers is
        /// "are these the same strings"; this port's columns hold interned
        /// ids, so both sides are resolved first. See [`cmpStrCol`].
        ///
        /// # The checkers and the `*const` receiver
        ///
        /// [`OpSet.validateOpOrder`] and [`OpSet.validateTopIndex`] take
        /// `*Self` because [`OpSet.iter`] does, and neither writes: the walk
        /// borrows the successor buffer and reads the columns. This receiver
        /// is `*const Self` to match [`OpSet.debugCmp`] and every other
        /// comparison, so the two are reached through `@constCast` here. That
        /// is sound and it is narrow: a caller holding `*const OpSet` gets a
        /// mutable alias that this function does not use, and nothing escapes.
        pub fn debugDiff(
            self: *const Self,
            other: *const Self,
        ) (ParseError || ReadOpError || InternalError)!?DebugCmpFault {
            // ── Soundness, before sameness ──────────────────────────────
            //
            // **This runs first, and on both sides, and that ordering is the
            // content of the function.** "These two differ" and "this one is
            // broken" are different facts, and a reader that reports the
            // first and can compute the second is a reader that sends whoever
            // is debugging it to the wrong document. A broken document can
            // also compare equal to a sound one column for column — the
            // columns are the same rows, only the order is wrong — so
            // answering the pair question first would report green on it.
            const sides = [_]struct { side: DebugSide, set: *const Self }{
                .{ .side = .left, .set = self },
                .{ .side = .right, .set = other },
            };
            for (sides) |entry| {
                const set: *Self = @constCast(entry.set);
                // The row where the order first breaks, and `null` when it
                // never does — one walk, not two, because `validateOpOrder`
                // answers the question without saying where.
                //
                // **Nothing is printed here.** The fault is the answer and
                // [`OpSet.debugCmp`] is the one that prints it, so a caller
                // that goes through both does not get the line twice.
                if (try set.firstBadRow()) |at| {
                    return .{ .row_order = .{ .side = entry.side, .at = at } };
                }
                if (try set.validateTopIndex()) |fault| {
                    return .{ .top_index = .{ .side = entry.side, .fault = fault } };
                }
            }

            // ── Sameness ────────────────────────────────────────────────
            if (self.actors.items.len != other.actors.items.len) return .actor_table;
            for (self.actors.items, other.actors.items) |a, b| {
                if (!ActorId.eql(a, b)) return .actor_table;
            }
            if (self.text_encoding != other.text_encoding) return .text_encoding;
            if (try self.cmpCol("id_actor", &self.cols.id_actor, &other.cols.id_actor)) |f| return f;
            if (try self.cmpCol("id_ctr", &self.cols.id_ctr, &other.cols.id_ctr)) |f| return f;
            if (try self.cmpCol("obj_actor", &self.cols.obj_actor, &other.cols.obj_actor)) |f| return f;
            if (try self.cmpCol("obj_ctr", &self.cols.obj_ctr, &other.cols.obj_ctr)) |f| return f;
            if (try self.cmpCol("key_actor", &self.cols.key_actor, &other.cols.key_actor)) |f| return f;
            if (try self.cmpCol("key_ctr", &self.cols.key_ctr, &other.cols.key_ctr)) |f| return f;
            // The two string columns are the two the ids do not settle, and
            // they are compared as strings: `cmpStrCol`.
            if (try self.cmpStrCol(other, "key_str", &self.cols.key_str, &other.cols.key_str)) |f| return f;
            if (try self.cmpCol("insert", &self.cols.insert, &other.cols.insert)) |f| return f;
            if (try self.cmpCol("action", &self.cols.action, &other.cols.action)) |f| return f;
            if (try self.cmpCol("value_meta", &self.cols.value_meta, &other.cols.value_meta)) |f| return f;
            if (try self.cmpStrCol(other, "mark_name", &self.cols.mark_name, &other.cols.mark_name)) |f| return f;
            if (try self.cmpCol("expand", &self.cols.expand, &other.cols.expand)) |f| return f;
            if (try self.cmpCol("succ_count", &self.cols.succ_count, &other.cols.succ_count)) |f| return f;
            if (try self.cmpCol("succ_actor", &self.cols.succ_actor, &other.cols.succ_actor)) |f| return f;
            if (try self.cmpCol("succ_ctr", &self.cols.succ_ctr, &other.cols.succ_ctr)) |f| return f;
            if (try self.cmpCol("index.text", &self.cols.index.text, &other.cols.index.text)) |f| return f;
            if (try self.cmpCol("index.top", &self.cols.index.top, &other.cols.index.top)) |f| return f;
            if (try self.cmpCol("index.visible", &self.cols.index.visible, &other.cols.index.visible)) |f| return f;
            if (try self.cmpCol("index.inc", &self.cols.index.inc, &other.cols.index.inc)) |f| return f;
            // columns.rs:132 — the value arena's bytes, not the decoded values.
            const mine = try self.cols.value.encode(self.gpa);
            defer self.gpa.free(mine);
            const theirs = try other.cols.value.encode(other.gpa);
            defer other.gpa.free(theirs);
            if (!std.mem.eql(u8, mine, theirs)) return .value_arena;
            // The mark column's cache: same words, same `MarkData`.
            const words = self.cols.index.mark.len();
            if (words != other.cols.index.mark.len()) return .mark_index;
            var mi: usize = 0;
            while (mi < words) : (mi += 1) {
                if (try self.cols.index.mark.get(mi) != try other.cols.index.mark.get(mi)) {
                    return .mark_index;
                }
            }
            if (self.cols.index.mark.cache.count() != other.cols.index.mark.cache.count()) {
                return .mark_index;
            }
            var mit = self.cols.index.mark.cache.iterator();
            while (mit.next()) |entry| {
                const theirs_data = other.cols.index.mark.cache.get(entry.key_ptr.*) orelse
                    return .mark_index;
                // `MarkData` has deliberately no `eql` ([marks.zig:470-477]);
                // the fold compares the name and the value apart, and so does
                // a structural comparison of two caches.
                if (!std.mem.eql(u8, entry.value_ptr.name, theirs_data.name)) return .mark_index;
                if (!markValueEql(entry.value_ptr.value, theirs_data.value)) return .mark_index;
            }
            // obj_info, which upstream's debug_cmp does not look at.
            if (self.obj_info.count() != other.obj_info.count()) return .obj_info;
            var oit = self.obj_info.map.iterator();
            while (oit.next()) |entry| {
                const theirs_info = other.obj_info.map.get(entry.key_ptr.*) orelse
                    return .obj_info;
                const mine_info = entry.value_ptr.*;
                if (mine_info.obj_type != theirs_info.obj_type) return .obj_info;
                if (!mine_info.parent.eql(theirs_info.parent)) return .obj_info;
            }
            return null;
        }

        /// The row at which this op set first breaks the row-order invariant,
        /// or null when it never does.
        ///
        /// [`OpSet.validateOpOrder`] is the same walk with the same
        /// [`opmod.OpStepper`] and answers the same question, and it answers it
        /// as a `bool` because `op_set.rs:167-175` returns a `bool`. A fault
        /// value has nowhere to put a row, so the second walk here is the
        /// answer to "the order is wrong, **where**".
        fn firstBadRow(self: *Self) ReadOpError!?usize {
            var stepper = opmod.OpStepper.initial();
            var walk = try self.iter();
            var at: usize = 0;
            while (try walk.next()) |row| {
                if (!row.step(&stepper)) return at;
                at += 1;
            }
            return null;
        }

        /// Whether this op set and `other` are the same document, row for row
        /// and byte for byte (`OpSet::debug_cmp`, `op_set.rs:69-71`).
        ///
        /// Upstream's `debug_cmp` has a one-bit answer; this is
        /// [`OpSet.debugDiff`] with that answer thrown away, so the comparison
        /// a caller gets from `error.Invariant` **and which of the two op sets
        /// is at fault** are computed from the same walk in the same order, and
        /// the printed diagnostic is the one the fault names. A caller that
        /// wants the fault calls `debugDiff`; a caller that only wants to know
        /// "same or not" is `debugCmp` and is unchanged.
        ///
        /// The narrowing is [`InternalError.Invariant`] for all four of
        /// [`ReadOpError`]'s own members and a rethrow for everything else.
        /// **It is not a widening of what this function accepts**: the four are
        /// `InvalidOpId`, `InvalidKey`, `MissingKey` and `MissingValue`, and
        /// each of them is a walk that could not read a row out of an op set it
        /// was handed. The op set is not untrusted input — it is the
        /// document — so a walk that fails over one is an invariant failure,
        /// and that is the one error this function has.
        pub fn debugCmp(self: *const Self, other: *const Self) (ParseError || InternalError)!void {
            const fault = self.debugDiff(other) catch |e| {
                switch (e) {
                    error.InvalidOpId, error.InvalidKey, error.MissingKey, error.MissingValue => {
                        std.debug.print("OpSet: a walk over the rows failed: {s}\n", .{@errorName(e)});
                        return error.Invariant;
                    },
                    else => {},
                }
                return @errorCast(e);
            } orelse return;
            switch (fault) {
                .actor_table, .text_encoding, .value_arena, .mark_index, .obj_info => {},
                .row_order => |r| std.debug.print("OpSet: {s} is out of row order at row {d}\n", .{
                    @tagName(r.side),
                    r.at,
                }),
                .top_index => |t| std.debug.print("OpSet: {s} top index fault: {any}\n", .{
                    @tagName(t.side),
                    t.fault,
                }),
                .column => |c| std.debug.print("OpSet: {s} differs at row {d}\n", .{ c.tag, c.at }),
                .column_length => |c| std.debug.print("OpSet: {s} length {d} != {d}\n", .{
                    c.tag,
                    c.left,
                    c.right,
                }),
            }
            return error.Invariant;
        }

        /// Whether one column of this op set holds the same **ids** as the same
        /// column of `other`, row for row — `Columns::debug_cmp`'s
        /// `debug_cmp("TAG", a.to_vec(), b.to_vec())`
        /// (`columns.rs:99-130`), over the values rather than the bytes so that
        /// a difference in slab layout is not a difference in the document.
        ///
        /// **"The same ids" is the right question for every column that reaches
        /// here**, because each one is a number whose meaning the rest of
        /// [`OpSet.debugDiff`] has already pinned:
        ///
        /// It answers with a [`DebugCmpFault`] rather than an error, so the
        /// caller learns **which column and which row** without parsing a
        /// printed line, and so a caller that wants only "same or not" is
        /// [`OpSet.debugCmp`].
        ///
        /// * `id_actor`, `obj_actor`, `key_actor` and `succ_actor` are
        ///   positions in the **actor table**, and `debugDiff` compares the two
        ///   tables element-wise before it gets here, so an index that agrees
        ///   names an actor that agrees.
        /// * `id_ctr`, `obj_ctr`, `key_ctr`, `succ_ctr` and `succ_count` are
        ///   counters and counts, and `index.text`, `index.top`,
        ///   `index.visible` and `index.inc` are row positions, widths and
        ///   increments: absolute numbers with no table behind them.
        /// * `insert` and `expand` are booleans and `action` is the action
        ///   enum, which are the same thing on both sides by construction.
        /// * `value_meta` holds the value arena's own offsets, and the arena
        ///   is compared byte for byte below, so an offset that differs is a
        ///   value that differs.
        ///
        /// **What does not belong here is an interned string id.** Those are
        /// positions in a *string table*, and each op set has its own, so two
        /// documents that reached the same vocabulary in a different order
        /// number the same string differently — and an id comparison there
        /// reports a difference where the document has none. The two string
        /// columns go to [`cmpStrCol`] instead.
        fn cmpCol(self: *const Self, tag: []const u8, mine: anytype, other: anytype) (ParseError || InternalError)!?DebugCmpFault {
            if (mine.len() != other.len()) {
                return .{ .column_length = .{ .tag = tag, .left = mine.len(), .right = other.len() } };
            }
            const all: RowRange = .{ .start = 0, .end = mine.len() };
            const a = try mine.sliceRange(self.gpa, all);
            defer self.gpa.free(a);
            const b = try other.sliceRange(other.gpa, all);
            defer other.gpa.free(b);
            for (a, b, 0..) |x, y, i| {
                if (x != y) return .{ .column = .{ .tag = tag, .at = i } };
            }
            return null;
        }

        /// Whether one of the two **string** columns of this op set holds the
        /// same **strings** as the same column of `other`, row for row.
        ///
        /// **Upstream compares strings here, and it has no resolving to do**:
        /// `key_str` and `mark_name` are `hexane::Column<Option<String>>`
        /// (`columns.rs:24`, `:32`), so the column *is* the string, and
        /// `Columns::debug_cmp` compares them with
        /// `assert_eq!(self.key_str.to_vec(), other.key_str.to_vec())`
        /// (`columns.rs:111`) and the same for `mark_name` (`:117`).
        ///
        /// **This port's two string columns hold interned ids**
        /// ([plan §5.3](../../docs/plan.md)) and two op sets have two string
        /// tables, so both sides are resolved through their own
        /// [`OpSet.strings`] and the bytes are compared. Comparing the ids
        /// would answer a different question — *were these two documents built
        /// against the same table* — and two documents that reached the same
        /// vocabulary in a different order are the same document: a splice
        /// interns each row's key in the order the rows arrive
        /// ([columns.zig:994](columns.zig)), so a document built by applying
        /// changes one at a time numbers its strings in arrival order, while
        /// one loaded from a save numbers them in row order
        /// ([columns.zig:1362](columns.zig)).
        ///
        /// **The claim that used to justify comparing the ids** — that a table
        /// interns each string once, so two ids are equal exactly when the
        /// strings they name are — is true *within one table* and false across
        /// two. That is the whole content of this function.
        ///
        /// **It takes both op sets** where [`cmpCol`] takes one, because the
        /// two string tables are two: an id names a string only in the table
        /// that interned it.
        fn cmpStrCol(self: *const Self, other: *const Self, tag: []const u8, mine: anytype, theirs: anytype) (ParseError || InternalError)!?DebugCmpFault {
            if (mine.len() != theirs.len()) {
                return .{ .column_length = .{ .tag = tag, .left = mine.len(), .right = theirs.len() } };
            }
            const all: RowRange = .{ .start = 0, .end = mine.len() };
            const a = try mine.sliceRange(self.gpa, all);
            defer self.gpa.free(a);
            const b = try theirs.sliceRange(other.gpa, all);
            defer other.gpa.free(b);
            for (a, b, 0..) |x, y, i| {
                // Both sides name a string, and each is its own table's to
                // name — so what is compared is the strings, not the ids.
                var same = false;
                if (x) |mine_id| {
                    if (y) |their_id| {
                        same = std.mem.eql(
                            u8,
                            self.strings.resolve(self.strings.ctx, mine_id),
                            other.strings.resolve(other.strings.ctx, their_id),
                        );
                    }
                } else {
                    same = y == null;
                }
                if (!same) return .{ .column = .{ .tag = tag, .at = i } };
            }
            return null;
        }

        // ── The actor table ─────────────────────────────────────────────

        /// Interns `actor` at index `idx` (`OpSet::insert_actor`,
        /// `op_set.rs:1400-1405`).
        ///
        /// A new actor is *always* appended by the reference's load path, so
        /// `idx == actors.len` is the normal case and the rewrite is skipped.
        /// Any other index means interning an actor into the middle of the
        /// table, which renumbers every actor index at or above `idx` — so the
        /// rewrite happens first, and the new actor lands at the position the
        /// shifted ones vacated.
        pub fn insertActor(self: *Self, idx: usize, actor: ActorId) ParseError!void {
            if (self.actors.items.len != idx) {
                // Upstream's index is a `usize` (`op_set.rs:1400`) and an
                // actor index is a `u32` here, so the rewrite's argument is
                // the checked narrowing rather than a silent one.
                try self.rewriteWithNewActor(std.math.cast(ActorIdx, idx) orelse return error.Overflow);
            }
            try self.actors.insert(self.gpa, idx, actor);
        }

        /// Renumbers every actor index at or above `idx`, as if a new actor
        /// had been interned there (`OpSet::rewrite_with_new_actor`,
        /// `op_set.rs:1407-1417`).
        ///
        /// Three things move, and all three have to: the four data columns
        /// that hold an actor index (`columns.rs:342-348`), the mark index's
        /// rows **and its cache** (`mark_index.rs:252-259`, and
        /// `mark_index.zig:623-627` for the half that re-keys), and the object
        /// table's own keys and parents. Upstream's `ObjIndex` rebuild maps
        /// both halves of each entry; so does this, through
        /// [`indexmod.withNewActor`].
        pub fn rewriteWithNewActor(self: *Self, idx: ActorIdx) ParseError!void {
            try self.cols.rewriteWithNewActor(self.gpa, idx);
            try self.cols.index.mark.rewriteWithNewActor(self.gpa, idx);
            var fresh = ObjIndex.init(self.gpa);
            errdefer fresh.deinit();
            var it = self.obj_info.map.iterator();
            while (it.next()) |entry| {
                try fresh.insert(entry.key_ptr.*.withNewActor(idx), indexmod.withNewActor(entry.value_ptr.*, idx));
            }
            self.obj_info.deinit();
            self.obj_info = fresh;
        }

        /// Forgets the actor at `idx` and renumbers the ones above it down
        /// (`OpSet::remove_actor`, `op_set.rs:1419-1429`).
        ///
        /// Upstream drops the actor from the table first and then rewrites, and
        /// upstream's rewrite panics if the actor is still referenced
        /// (`columns.rs:355-357`). This one rewrites first, because the port's
        /// rewrite *refuses* (`columns.zig:853-861`) — and a refusal after the
        /// table had been edited would leave a document whose actor table and
        /// columns disagree about how many actors there are. Rewriting first
        /// has no other observable effect: the rewrite either succeeds or the
        /// document is left exactly as it was.
        ///
        /// An object made by the removed actor has no identity left, so its
        /// entry goes with it — upstream's `filter_map` (`:1426`) and
        /// [`indexmod.withoutActor`] returning null.
        pub fn removeActor(self: *Self, idx: ActorIdx) ParseError!void {
            try self.cols.rewriteWithoutActor(self.gpa, idx);
            _ = self.actors.orderedRemove(idx);
            var fresh = ObjIndex.init(self.gpa);
            errdefer fresh.deinit();
            var it = self.obj_info.map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*.withoutActor(idx) orelse continue;
                const info = indexmod.withoutActor(entry.value_ptr.*, idx) orelse continue;
                try fresh.insert(key, info);
            }
            self.obj_info.deinit();
            self.obj_info = fresh;
        }

        /// The actor at `idx` (`OpSet::get_actor`, `op_set.rs:1179-1181`).
        /// Null rather than a trap for an index the table does not have, for
        /// the reason [`OpSet.getActorSafe`] gives.
        pub fn getActor(self: *const Self, idx: ActorIdx) ?ActorId {
            if (idx >= self.actors.items.len) return null;
            return self.actors.items[idx];
        }

        /// The actor at `idx`, or null (`OpSet::get_actor_safe`,
        /// `op_set.rs:1183-1185`).
        pub fn getActorSafe(self: *const Self, idx: ActorIdx) ?ActorId {
            return self.getActor(idx);
        }

        /// Where `actor` sits in the table (`OpSet::lookup_actor`,
        /// `op_set.rs:1187-1189`).
        ///
        /// A binary search, which is why the table is kept sorted
        /// ([types.zig:108-110]). The search is over the actor table, not over
        /// the columns, so it is O(log n) and needs nothing from `self` but the
        /// table.
        pub fn lookupActor(self: *const Self, actor: ActorId) ?usize {
            var lo: usize = 0;
            var hi: usize = self.actors.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (ActorId.order(self.actors.items[mid], actor)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return mid,
                }
            }
            return null;
        }

        /// How many actors the table holds, which is one past the largest legal
        /// actor index.
        pub fn actorCount(self: *const Self) usize {
            return self.actors.items.len;
        }

        // ── The index ───────────────────────────────────────────────────

        /// A fresh index builder, sized to this op set
        /// (`OpSet::index_builder`, `op_set.rs:103-105`).
        ///
        /// Upstream hands the op set itself and reads `len()` and `sub_len()`
        /// off it to size its vectors (`index.rs:160-173`); the port takes the
        /// two counts directly, because this file is a layer above
        /// `index.zig` and the counts are all the builder wants.
        pub fn indexBuilder(self: *const Self) ParseError!IndexBuilder {
            return IndexBuilder.init(
                self.gpa,
                self.len(),
                self.subLen(),
                self.text_encoding,
            );
        }

        /// Installs a rebuilt index (`OpSet::set_indexes`, `op_set.rs:216-230`).
        ///
        /// Upstream asserts the lengths (`:219-222`) and this reports:
        /// `error.IndexMismatch` names the failure, and a caller that installs
        /// an index of the wrong length has a bug that would otherwise be a
        /// document that reads back plausibly wrong. `indexmod.Indexes`
        /// carries the same check as
        /// [`checkLengths`](index.zig) and this is its single call site, so
        /// there is one rule and not two.
        ///
        /// The five columns are replaced whole, and so is the object table,
        /// because the rebuild produces a fresh one (`op_set.rs:229`).
        pub fn setIndexes(self: *Self, indexes: indexmod.Indexes) (ParseError || InternalError)!void {
            if (!indexes.checkLengths(self.len(), self.subLen())) return error.IndexMismatch;
            self.cols.index.deinit();
            self.cols.index = .{
                .text = indexes.text,
                .top = indexes.top,
                .visible = indexes.visible,
                .inc = indexes.inc,
                .mark = indexes.mark,
            };
            self.obj_info.deinit();
            self.obj_info = indexes.obj_info;
        }

        /// Rebuilds the five index columns from this op set's own rows and
        /// installs them, checking the mark order on the way
        /// (`storage/document.rs:332-344`, then `:355`).
        ///
        /// **This is what a load must do**, and the reason is in the module doc:
        /// the index is never stored, so a document that arrives without one has
        /// to build it from the sixteen data columns or it answers every query
        /// with nothing.
        ///
        /// The loop is [`indexmod.IndexBuilder`]'s contract and it is in this
        /// order for a reason each time:
        ///
        /// 1. `flush` **before** the first row of a new `(obj, elemid_or_key)`
        ///    group (`change/collector.rs:62-66`). `flush` marks the winner of
        ///    the register that has just ended, and the caller is what knows
        ///    where a register ends — flushing anywhere else would attribute a
        ///    register's winner to a row of the next register.
        /// 2. `processOp` for the row (`index.rs:185-208`).
        /// 3. one `processSucc` per successor edge, **after** `processOp` for
        ///    the row that owns them (`change/collector.rs:47-52`): the edge's
        ///    index in the increment column is `incs.len()` and the row it
        ///    shadows is `succ.len() - 1`, and both are only right once the row
        ///    itself has been pushed.
        ///
        /// `error.InvalidMarkOrder` is the class
        /// [`indexmod.MarkOrderError`], which is upstream's
        /// `ReconstructError::InvalidMarkOrderDoc`
        /// (`storage/document.rs:355-359`).
        pub fn rebuildIndex(self: *Self) LoadError!void {
            // **A column set that arrives from a load has an empty index**
            // (`columns.rs:314`) and the port's walk refuses to be built over
            // one, so the five are sized first. `sizeIndexForWalk` says why
            // and why none of it survives.
            try self.sizeIndexForWalk();
            // The builder is consumed by `finish`, so its `errdefer` is scoped
            // to this block: a `break` out of it is a normal exit and runs no
            // cleanup, which is right because `finish` has already moved every
            // buffer into its result.
            var rebuilt = blk: {
                var builder = try self.indexBuilder();
                errdefer builder.deinit();
                var walk = try self.iter();
                var last: ?Group = null;
                while (try walk.next()) |row| {
                    // change/collector.rs:62-66, over the object and the
                    // register key.
                    const here: Group = .{ .obj = row.objId(), .key = row.elemidOrKey() };
                    if (last) |prev| {
                        if (!prev.obj.eql(here.obj) or !prev.key.eql(here.key)) builder.flush();
                    }
                    last = here;
                    try builder.processOp(row);
                    const is_counter = row.isCounter();
                    var edges = row.succ().withInc();
                    while (edges.next()) |edge| try builder.processSucc(is_counter, edge.id);
                }
                break :blk try builder.finish();
            };
            // Upstream hands the validator to its caller
            // (`storage/document.rs:343`, `:355-362`). This file *is* the
            // loader — `load` is `fromParts` plus this call — so the check
            // happens here, at the same point in the same order.
            indexmod.checkMarkOrder(&rebuilt.mark_order) catch |e| {
                var doomed = rebuilt;
                doomed.deinit();
                return e;
            };
            rebuilt.mark_order.deinit();
            errdefer rebuilt.indexes.deinit();
            try self.setIndexes(rebuilt.indexes);
        }

        /// Sizes the five index columns so a walk over this op set can be
        /// built, and does nothing at all when they already are.
        ///
        /// **Only a set that arrived from a load needs this, and it is the
        /// price of the port's index columns.** A set built by
        /// [`OpSet.splice`] has all five written from the rows
        /// ([columns.rs:468-489](columns.zig)) and a set that has been through
        /// [`OpSet.rebuildIndex`] has the ones the builder produced. A set
        /// straight out of [`OpSet.fromParts`] has an *empty* index
        /// (`columns.rs:314`) and **no walk can be built over it**:
        /// [`opiter.OpIter`] refuses a column set whose four per-row index
        /// columns are not `len()` long, or whose `inc` is not `subLen()` long,
        /// because it advances the cursors in lockstep
        /// ([op_iter.zig:1372-1423](op_iter.zig)). Upstream has no such
        /// requirement — its `OpIter` reads no index column — so upstream's
        /// `load` can be handed to a walker with no index at all
        /// ([`storage/document.rs:332-344`](op_set.rs)), and this cannot.
        ///
        /// Nothing written here survives: [`OpSet.setIndexes`] replaces all
        /// five index columns whole with the ones `IndexBuilder.finish`
        /// produced ([index.rs:217-227](index.zig)). This is scratch space for
        /// the walk, and that is the only thing it is.
        fn sizeIndexForWalk(self: *Self) ParseError!void {
            const rows = self.cols.len();
            const succs = self.subLen();

            if (self.cols.index.text.len() < rows) {
                const pad = try self.gpa.alloc(?u32, rows - self.cols.index.text.len());
                defer self.gpa.free(pad);
                @memset(pad, null);
                try self.cols.index.text.splice(self.gpa, self.cols.index.text.len(), 0, pad);
            }
            if (self.cols.index.top.len() < rows) {
                const pad = try self.gpa.alloc(bool, rows - self.cols.index.top.len());
                defer self.gpa.free(pad);
                @memset(pad, false);
                try self.cols.index.top.splice(self.gpa, self.cols.index.top.len(), 0, pad);
            }
            if (self.cols.index.visible.len() < rows) {
                const pad = try self.gpa.alloc(bool, rows - self.cols.index.visible.len());
                defer self.gpa.free(pad);
                @memset(pad, false);
                try self.cols.index.visible.splice(self.gpa, self.cols.index.visible.len(), 0, pad);
            }
            if (self.cols.index.mark.len() < rows) {
                // `extend` takes builders, not words, because a begin also
                // seeds the cache ([mark_index.zig:683-699](mark_index.zig));
                // a run of nulls is a run of rows with no mark, and a null
                // builder is a null word with no cache entry.
                const pad = try self.gpa.alloc(?markmod.MarkIndexBuilder, rows - self.cols.index.mark.len());
                defer self.gpa.free(pad);
                @memset(pad, null);
                try self.cols.index.mark.extend(self.gpa, self.cols.index.mark.len(), pad);
            }
            if (self.cols.index.inc.len() < succs) {
                const pad = try self.gpa.alloc(?i64, succs - self.cols.index.inc.len());
                defer self.gpa.free(pad);
                @memset(pad, null);
                try self.cols.index.inc.splice(self.gpa, self.cols.index.inc.len(), 0, pad);
            }
        }

        // ── Mutation ───────────────────────────────────────────────────

        /// How many rows the op set holds (`OpSet::len`, `op_set.rs:421-423`).
        pub fn len(self: *const Self) usize {
            return self.cols.len();
        }

        /// How many successor edges the op set holds, across every row
        /// (`OpSet::sub_len`, `op_set.rs:425-427`).
        ///
        /// This is the length of the *flattened* pair, not of `succ_count`, and
        /// it is the only count a splice at a non-zero position may not disturb
        /// (`columns.rs:906-909`).
        pub fn subLen(self: *const Self) usize {
            return self.cols.subLen();
        }

        /// Whether the op set holds no rows.
        pub fn isEmpty(self: *const Self) bool {
            return self.cols.isEmpty();
        }

        /// Records what every op that made an object made, in the op set's own
        /// object table (`OpSet::splice_objects`, `op_set.rs:232-238`).
        ///
        /// Only an op that *makes* something has an entry, so a `set` op adds
        /// nothing. Called by [`OpSet.splice`] for every op it writes, which is
        /// why the object table and the rows cannot disagree about which ops
        /// made which objects.
        pub fn spliceObjects(self: *Self, ops: []const O) ParseError!void {
            for (ops) |op| {
                if (op.objInfo()) |info| try self.obj_info.insert(op.id(), info);
            }
        }

        /// Inserts `ops` before row `pos` and returns how many **rows** were
        /// written (`OpSet::splice`, `op_set.rs:240-244`).
        ///
        /// A delete is not a row: it is filtered out inside
        /// [`columns.Columns.splice`] (`columns.rs:423`) and does not appear in
        /// the count. The object table is brought along in the same call, which
        /// is the whole of what `splice` adds over `cols.splice`.
        ///
        /// **The successor buffer is refitted afterwards**, because a row that
        /// arrives with more successors than the buffer holds would make every
        /// later walk over this op set answer `error.TooLarge`
        /// (`op_iter.zig:908-910`). A buffer that is already wide enough is
        /// left alone, so a splice in a document with a wide register costs
        /// nothing.
        pub fn splice(self: *Self, pos: usize, ops: []const O) ParseError!usize {
            const added = try self.cols.splice(self.gpa, pos, ops, self.text_encoding, self.strings);
            try self.spliceObjects(ops);
            try self.refitScratch();
            return added;
        }

        /// An op set built from a stream of rows, in the order they arrive
        /// (`OpSet::from_doc_ops`, `op_set.rs:1207-1222`; `Columns::new`,
        /// `columns.rs:496-503`).
        ///
        /// Upstream splices the whole stream at position zero in one call; this
        /// appends each op in turn, which is the same rows in the same order
        /// and the same index columns — every column is written from the op's
        /// own `top`, `visible` and `width` either way
        /// (`columns.rs:475-489`).
        ///
        /// The index columns here are the ones each op *claims*, which is not
        /// the same as the ones a rebuild derives: `splice` trusts the op, and
        /// [`OpSet.rebuildIndex`] recomputes. The test that holds the two to
        /// each other is the reason this method is here.
        pub fn fromDocOps(
            gpa: Allocator,
            actors: []const ActorId,
            ops: []const O,
            text_encoding: TextEncoding,
            strings: StringTable,
        ) ParseError!Self {
            var set = try init(gpa, text_encoding, strings);
            errdefer set.deinit();
            try set.actors.appendSlice(gpa, actors);
            for (ops) |op| _ = try set.splice(set.len(), &.{op});
            return set;
        }

        /// Takes one transaction's operation back out
        /// (`OpSet::undo_op`, `op_set.rs:246-257`).
        ///
        /// Four steps in upstream's order and each one is conditional on
        /// something the op carries: the successor edges the transaction
        /// recorded go first (`:247-249`) because the rows they belong to are
        /// about to be removed; then the row itself (`:250`); then the object
        /// it made, if it made one (`:251-253`); then `reset_top` over the
        /// range the transaction captured, which is what undoes the conflict
        /// reordering an insert performed (`:254-256`).
        pub fn undoOp(self: *Self, op: *const opmod.TxOp) (ParseError || ReadOpError)!void {
            if (op.undo.items.len != 0) try self.undoSucc(op.undo.items);
            const builders = [_]opmod.OpBuilder{op.bld};
            _ = try self.cols.removeOps(self.gpa, op.pos, &builders);
            if (op.objInfo() != null) self.obj_info.remove(op.bld.id());
            // `OpRange` and `RowRange` are the same two fields under two
            // names, and this is the one call that crosses between them.
            if (op.reset_range) |rows| try self.resetTop(.{ .start = rows.start, .end = rows.end });
            try self.refitScratch();
        }

        /// Recomputes the `top` column over `rows` (`OpSet::reset_top`,
        /// `op_set.rs:107-138`).
        ///
        /// The pass is upstream's and its two accumulators are the whole of it:
        /// `conflicts` collects every row that was a winner and no longer is,
        /// and `expose` is the single row that becomes the winner without
        /// demoting anybody — the last visible row of the range, if the range
        /// ends on one. They are applied *after* the scan, not during it,
        /// because a row's `top` value is read once and the answer for the
        /// whole range is only known at the end.
        ///
        /// `top ⇒ visible` is asserted upstream at `:116` and cannot be
        /// violated here — the only writer of `top` in this loop is `expose`,
        /// and `expose` is only reached from the `else if v` arm, i.e. a row
        /// the `visible` column already marks.
        pub fn resetTop(self: *Self, rows: RowRange) (ParseError || ReadOpError)!void {
            const window = column.clampRange(rows, self.cols.len());
            var conflicts: std.ArrayList(usize) = .empty;
            defer conflicts.deinit(self.gpa);
            var expose_at: ?usize = null;
            var last_t: ?usize = null;
            var visible_rows = try self.cols.index.visible.iterRange(window);
            var top = try self.cols.index.top.iterRange(window);
            var i: usize = 0;
            while (try visible_rows.next()) |v| {
                const t = (try top.next()) orelse break;
                if (t) {
                    if (last_t) |n| try conflicts.append(self.gpa, n);
                    last_t = i;
                    expose_at = null;
                } else if (v) {
                    if (last_t) |n| try conflicts.append(self.gpa, n);
                    last_t = null;
                    expose_at = i;
                }
                i += 1;
            }
            for (conflicts.items) |n| try self.conflict(window.start + n);
            if (expose_at) |n| try self.expose(window.start + n);
        }

        /// Demotes the row at `pos` from winner of its register
        /// (`OpSet::conflict`, `op_set.rs:140-145`).
        ///
        /// Two columns, and the second is the point: a losing row must stop
        /// contributing width to the text index, or the sequence's measured
        /// length would count a conflicted character twice
        /// (`op_set.rs:143-144`).
        pub fn conflict(self: *Self, pos: usize) ParseError!void {
            try self.cols.index.top.splice(self.gpa, pos, 1, &.{false});
            try self.cols.index.text.splice(self.gpa, pos, 1, &.{null});
        }

        /// Promotes the row at `pos` to winner of its register
        /// (`OpSet::expose`, `op_set.rs:147-158`).
        ///
        /// **The width is always measured as text**, for every object type, and
        /// upstream says why at `:149-153`: the text index is only ever read on
        /// a top row of a text object, and a non-text row's width is never
        /// measured, so requiring the caller to pass the object type would buy
        /// nothing. [`columns.Columns.splice`] makes the same choice on the way
        /// in (`columns.rs:475-485`).
        pub fn expose(self: *Self, pos: usize) (ParseError || ReadOpError)!void {
            try self.cols.index.top.splice(self.gpa, pos, 1, &.{true});
            const width: ?u32 = if (try self.get(pos)) |row| blk: {
                const w = row.width(.text, self.text_encoding);
                break :blk if (w < 0) null else std.math.cast(u32, w) orelse null;
            } else null;
            try self.cols.index.text.splice(self.gpa, pos, 1, &.{width});
        }

        /// Adds a successor edge to each of `inserts`, with nothing recorded
        /// for undo (`OpSet::add_succ`, `op_set.rs:259-283`).
        ///
        /// **The pass runs backwards, and that is not an implementation
        /// detail.** `inserts` is a transaction's operations in the order it
        /// built them, and the edges a row receives are recorded in that order;
        /// adding them forwards would put the *last* operation's edge at the
        /// front of the row's successor list and shift the others along, and
        /// `Op.addSucc` — which chose `sub_pos` by that ordering
        /// (`op.rs:2027-2038`) — would then be describing a list that no longer
        /// matches. Backwards, each insert lands where it was computed to land
        /// and the earlier ones are already in place.
        ///
        /// `succ_inc` is upstream's running count of how many edges *this row*
        /// has already received in this pass (`:262-268`): because the pass is
        /// backwards, the count is the position from the end, and the new
        /// `succ_count` is the row's old count plus that.
        pub fn addSucc(self: *Self, inserts: []const SuccInsert) ParseError!void {
            var succ_inc: usize = 0;
            var last_pos: ?usize = null;
            var i = inserts.len;
            while (i > 0) {
                i -= 1;
                const item = inserts[i];
                if (last_pos != null and last_pos.? == item.pos) {
                    succ_inc += 1;
                } else {
                    last_pos = item.pos;
                    succ_inc = 1;
                }
                try self.writeSuccEdge(item, succ_inc);
            }
            try self.refitScratch();
        }

        /// Adds a successor edge to each of `inserts` and records what undoing
        /// them has to restore (`OpSet::add_succ_with_undo`,
        /// `op_set.rs:285-325`).
        ///
        /// **Backwards, for the reason [`OpSet.addSucc`] gives**, and the undo
        /// list comes out in that same backwards order, which is why
        /// [`OpSet.undoSucc`] replays it backwards again: forward-in,
        /// forward-out, and the column is byte-identical to what it was.
        ///
        /// Four cases, and the order is upstream's (`:306-322`):
        ///
        /// * `inc == null` — a **delete**. The row stops being visible, loses
        ///   its text width and loses `top`; all three are recorded, because all
        ///   three are about to change. This also sets `delete`, which is what
        ///   arms the next case.
        /// * `inc != null` and `delete` and not yet exposed — an **increment
        ///   onto a row that has just been deleted**. A counter whose only
        ///   successor deletes it is dead, but an increment is not a delete, so
        ///   the row is exposed again and its `top` recorded. This happens at
        ///   most once per pass, which is what the `expose` flag is for.
        /// * `inc != null` and no delete seen — a plain **increment**. Nothing
        ///   in the index moves, so the undo records nothing, and replaying it
        ///   is a no-op on all three index columns. This is the "no-op undo"
        ///   case.
        /// * `inc != null` after the expose — another increment on the same
        ///   row, or on any other row. Also a no-op undo.
        ///
        /// The caller owns the returned list and frees it.
        pub fn addSuccWithUndo(self: *Self, inserts: []const SuccInsert) ParseError![]SuccUndo {
            var undo: std.ArrayList(SuccUndo) = .empty;
            errdefer undo.deinit(self.gpa);
            try undo.ensureTotalCapacity(self.gpa, inserts.len);

            var succ_inc: usize = 0;
            var last_pos: ?usize = null;
            var delete = false;
            var did_expose = false;
            var i = inserts.len;
            while (i > 0) {
                i -= 1;
                const item = inserts[i];
                if (last_pos != null and last_pos.? == item.pos) {
                    succ_inc += 1;
                } else {
                    last_pos = item.pos;
                    succ_inc = 1;
                }
                // op_set.rs:298-305 — the four column writes, and *only*
                // those. Upstream reads the three index values at `:308-310`
                // and `:317` **before** it writes them at `:312-314` and
                // `:319`, so sharing a helper that also mutated the index
                // would record the post-write values and make the undo a
                // no-op. The helper is `writeSuccColumns`; the delete's
                // index block is below, in upstream's order.
                try self.writeSuccColumns(item, succ_inc);
                if (item.inc == null) {
                    // op_set.rs:306-314 — a delete.
                    delete = true;
                    const row_vis = try self.cols.index.visible.get(item.pos);
                    const row_text = try self.cols.index.text.get(item.pos);
                    const row_top = try self.cols.index.top.get(item.pos);
                    try undo.append(self.gpa, .{
                        .succ = item,
                        .visible = row_vis,
                        .text = if (row_text) |t| @as(?u32, t) else null,
                        .top = row_top,
                    });
                    try self.cols.index.visible.splice(self.gpa, item.pos, 1, &.{false});
                    try self.cols.index.text.splice(self.gpa, item.pos, 1, &.{null});
                    try self.cols.index.top.splice(self.gpa, item.pos, 1, &.{false});
                } else if (delete and !did_expose) {
                    // op_set.rs:315-319 — the re-expose.
                    did_expose = true;
                    const row_top = try self.cols.index.top.get(item.pos);
                    try undo.append(self.gpa, .{
                        .succ = item,
                        .visible = null,
                        .text = null,
                        .top = row_top,
                    });
                    try self.cols.index.top.splice(self.gpa, item.pos, 1, &.{true});
                } else {
                    // op_set.rs:320-322 — nothing in the index moved.
                    try undo.append(self.gpa, .{
                        .succ = item,
                        .visible = null,
                        .text = null,
                        .top = null,
                    });
                }
            }
            try self.refitScratch();
            return undo.toOwnedSlice(self.gpa);
        }

        /// Removes the successor edges `undos` names, restoring what they
        /// changed (`OpSet::undo_succ`, `op_set.rs:327-351`).
        ///
        /// **Backwards again**, and for a different reason from
        /// [`OpSet.addSucc`]: the list came out of
        /// [`OpSet.addSuccWithUndo`] in reverse, so replaying it in reverse
        /// undoes the *last* edge first, which is the one whose `succ_count` and
        /// `sub_pos` were computed against the state its predecessor left. A
        /// `succ_count` is read back out of the column each time, so the count
        /// going down by one per edge is the whole of it.
        ///
        /// The three `?` payloads are upstream's nested `Option`s
        /// ([`SuccUndo`](op.zig)): null means this column was not touched, and a
        /// null *inside* `text` means it was set to null.
        pub fn undoSucc(self: *Self, undos: []const SuccUndo) ParseError!void {
            var i = undos.len;
            while (i > 0) {
                i -= 1;
                const entry = undos[i];
                const item = entry.succ;
                try self.cols.succ_count.splice(self.gpa, item.pos, 1, &.{
                    std.math.cast(u32, item.len) orelse return error.Overflow,
                });
                try self.cols.succ_actor.splice(self.gpa, item.sub_pos, 1, &.{});
                try self.cols.succ_ctr.splice(self.gpa, item.sub_pos, 1, &.{});
                try self.cols.index.inc.splice(self.gpa, item.sub_pos, 1, &.{});
                if (entry.visible) |v| {
                    try self.cols.index.visible.splice(self.gpa, item.pos, 1, &.{v});
                }
                if (entry.text) |t| {
                    try self.cols.index.text.splice(self.gpa, item.pos, 1, &.{t});
                }
                if (entry.top) |t| {
                    try self.cols.index.top.splice(self.gpa, item.pos, 1, &.{t});
                }
            }
            try self.refitScratch();
        }

        /// The one successor edge's four *column* writes, shared by
        /// [`OpSet.addSucc`] and [`OpSet.addSuccWithUndo`] because upstream
        /// writes the same four statements twice (`op_set.rs:269-275` and
        /// `:298-304`) and they have to be the same four.
        ///
        /// **The index is deliberately not touched here.** `add_succ` writes
        /// it in the same loop (`op_set.rs:277-281`); `add_succ_with_undo`
        /// *reads* it first and writes it after, and the order is the whole
        /// of what the undo list is (`op_set.rs:308-314`). A helper that also
        /// demoted the row would make that method record the values it had
        /// just written, and the undo would restore nothing.
        ///
        /// `succ_inc` is the number of edges *this row* has already received in
        /// this pass, counted from the end because the pass runs backwards; the
        /// new count is the row's old count plus that, which is what keeps
        /// `succ_count` and the flattened pair the same length.
        fn writeSuccColumns(self: *Self, item: SuccInsert, succ_inc: usize) ParseError!void {
            const new_count = std.math.add(u64, item.len, succ_inc) catch return error.Overflow;
            try self.cols.succ_count.splice(self.gpa, item.pos, 1, &.{
                std.math.cast(u32, new_count) orelse return error.Overflow,
            });
            try self.cols.succ_actor.splice(self.gpa, item.sub_pos, 0, &.{item.id.actor});
            try self.cols.succ_ctr.splice(self.gpa, item.sub_pos, 0, &.{item.id.counter});
            try self.cols.index.inc.splice(self.gpa, item.sub_pos, 0, &.{item.inc});
        }

        /// The same edge, *including* the index: what [`OpSet.addSucc`]
        /// writes (`op_set.rs:269-281`).
        ///
        /// A delete (`inc == null`) takes the row out of `visible`, out of
        /// the text index and out of `top` — the same three columns
        /// `add_succ_with_undo` records and then writes, in the other order.
        fn writeSuccEdge(self: *Self, item: SuccInsert, succ_inc: usize) ParseError!void {
            try self.writeSuccColumns(item, succ_inc);
            if (item.inc == null) {
                try self.cols.index.visible.splice(self.gpa, item.pos, 1, &.{false});
                try self.cols.index.text.splice(self.gpa, item.pos, 1, &.{null});
                try self.cols.index.top.splice(self.gpa, item.pos, 1, &.{false});
            }
        }

        /// Widens the successor buffer to the widest row in the op set.
        ///
        /// Called after every mutation, because a row can arrive with more
        /// successors than the buffer holds and every later walk would then
        /// answer `error.TooLarge` ([`op_iter.SuccIterIter`]). A buffer that is
        /// already wide enough is left alone, so the common case costs one pass
        /// over `succ_count` and no allocation.
        fn refitScratch(self: *Self) ParseError!void {
            const want = try opiter.maxSuccCount(O, &self.cols, .{
                .start = 0,
                .end = self.cols.len(),
            });
            if (self.succ_scratch.items.len < want) {
                try self.succ_scratch.resize(self.gpa, want);
            }
        }

        // ── Queries ─────────────────────────────────────────────────────

        /// The rows that belong to `obj` (`OpSet::scope_to_obj`,
        /// `op_set.rs:1246-1252`).
        ///
        /// Two columns, two steps, and the order is upstream's: the counter
        /// column narrows first and the actor column narrows inside that
        /// (`:1250-1251`). Each step is a `scopeToValue` — the contiguous run
        /// of equal values — which is a B-tree descent rather than a walk, and
        /// which is only correct because the object columns are sorted by
        /// object. That is rule **R1** (`op.rs:1049-1054`) read as a fact about
        /// the data, and the rest of this file's range arithmetic rests on it.
        ///
        /// The root is both halves absent, so both `scopeToValue` calls look for
        /// null and find the root's rows.
        pub fn scopeToObj(self: *const Self, obj: ObjId) ParseError!RowRange {
            const all: RowRange = .{ .start = 0, .end = self.cols.len() };
            const by_ctr = try self.cols.obj_ctr.scopeToValue(obj.counter(), all);
            return self.cols.obj_actor.scopeToValue(obj.actor(), by_ctr);
        }

        /// The rows of one map key of `obj` (`OpSet::prop_range`,
        /// `op_set.rs:1268-1271`).
        ///
        /// Upstream is `key_str.scope_to_value(Some(prop), obj_range)`, one
        /// B-tree descent. **This is a walk, and it has to be**, because the
        /// port's `key_str` holds interned ids ([plan §5.3](../../docs/plan.md))
        /// and a `scopeToValue` needs its values *sorted* — which interned ids
        /// are not: a table interns each string once, in the order the strings
        /// are first seen, so id order is insertion order and not the
        /// lexicographic order the row-order invariant sorts map registers by
        /// (rule **R2**, `op.rs:1055-1059`). Descent would find the wrong
        /// register, or none.
        ///
        /// So the walk compares the *resolved* strings, and the row order is
        /// what makes the walk short: a register's rows are contiguous (rules
        /// **R2** and **R3**), so the first row after a match that does not
        /// match ends the register.
        ///
        /// **A key the object does not hold answers the row it would sort at,
        /// not the object's end.** `scope_to_value` is
        /// [`column.sortedScanToValue`](../../src/hexane/column.zig), whose
        /// three arms are upstream's: equal is the run, greater is the cursor
        /// where it stands, and smaller accumulates — so a value the column
        /// does not hold answers `at..at` with `at` one past the last row
        /// below it (`column.rs:958-1000`, ported at
        /// [column.zig:3939-3977](../../src/hexane/column.zig)). Hexane's own
        /// test says it: over `aaa aaa bbb bbb bbb ccc`, `"aab"` is `2..2` and
        /// `"ddd"` is `6..6`
        /// ([`hexane/src/tests.rs:3464-3476`](../../github-automerge-automerge/rust/hexane/src/tests.rs)).
        /// **This walk cannot inherit that for free** — it has no descent to
        /// fall out of — so it counts the rows it steps over, which is the same
        /// accumulation and O(rows of the object) either way. The answer was
        /// the object's end until this was fixed, which is *right by luck* for
        /// a key greater than every key the object holds and wrong for every
        /// other absent key: a range bounded by one landed past the end of the
        /// object instead of where the key sorts.
        pub fn propRange(self: *const Self, obj: ObjId, prop: []const u8) ParseError!RowRange {
            const range = try self.scopeToObj(obj);
            var it = try self.cols.key_str.iterRange(range);
            var start: ?usize = null;
            var at = range.start;
            // `column.rs:971` — one past the last row whose key sorts below
            // `prop`, which is where `prop` itself would go.
            var point = range.start;
            while (try it.next()) |id| {
                const key = if (id) |i| self.strings.resolve(self.strings.ctx, i) else null;
                if (key) |resolved| {
                    if (std.mem.eql(u8, resolved, prop)) {
                        if (start == null) start = at;
                    } else if (start) |s| {
                        return .{ .start = s, .end = at };
                    } else if (std.mem.order(u8, resolved, prop) == .lt) {
                        point = at + 1;
                    }
                } else if (start) |s| {
                    // A sequence anchor cannot be inside a map register
                    // ([`tryLoadKeyRef`](op_iter.zig),
                    // `op_iter.rs:251-265`), so a null key either ends the
                    // register or was never in one. Neither moves `point`: a
                    // row with no key is not a place a map key could sort.
                    return .{ .start = s, .end = at };
                }
                at += 1;
            }
            if (start) |s| return .{ .start = s, .end = range.end };
            return .{ .start = point, .end = point };
        }

        /// A walk over `rows` (`OpSet::iter_range`, `op_set.rs:1318-1342`).
        ///
        /// `rows` is clamped to the op set here
        /// ([`column.clampRange`](../../src/hexane/column.zig)), so a caller
        /// holding a stale range gets a short walk rather than a wrong one.
        /// **The walk borrows the op set's successor buffer** — the module doc's
        /// fourth section is the rule.
        pub fn iterRange(self: *Self, rows: RowRange) ParseError!Row {
            return Row.init(&self.cols, self.strings, rows, self.succ_scratch.items);
        }

        /// A walk over every row (`OpSet::iter`, `op_set.rs:1348-1371`).
        pub fn iter(self: *Self) ParseError!Row {
            return self.iterRange(.{ .start = 0, .end = self.cols.len() });
        }

        /// A walk over the rows of `obj` (`OpSet::iter_obj`,
        /// `op_set.rs:1273-1276`).
        ///
        /// `scopeToObj` then `iterRange`, which is the construction order the
        /// module doc states and the one every wrapper in this file follows.
        pub fn iterObj(self: *Self, obj: ObjId) ParseError!Row {
            return self.iterRange(try self.scopeToObj(obj));
        }

        /// The row at `pos`, or null past the end (`OpSet::get`,
        /// `op_set.rs:786-788`).
        pub fn get(self: *Self, pos: usize) ReadOpError!?Op {
            var walk = try self.iterRange(.{ .start = pos, .end = pos + 1 });
            return walk.next();
        }

        /// The row at `pos` that named an object, over both object columns
        /// (`OpIter::obj_id_iter`, `op_set.rs:1344-1346`).
        pub fn objIdIter(self: *const Self) ParseError!opiter.ObjIdIter {
            return opiter.ObjIdIter.init(
                try self.cols.obj_actor.iterator(),
                try self.cols.obj_ctr.iterator(),
            );
        }

        /// The two halves of each row's own id (`OpSet::id_iter_range`,
        /// `op_set.rs:1285-1290`).
        pub fn idIterRange(self: *const Self, rows: RowRange) ParseError!opiter.OpIdIter {
            return opiter.OpIdIter.init(
                try self.cols.id_actor.iterRange(rows),
                try self.cols.id_ctr.iterRange(rows),
            );
        }

        /// Each row's value (`OpSet::value_iter_range`, `op_set.rs:1278-1283`).
        ///
        /// The two prefix positions are read before anything moves
        /// (`op_set.rs:1280-1281`), because the raw-value cursor is a window
        /// into an arena the metadata column indexes.
        pub fn valueIterRange(self: *const Self, rows: RowRange) ParseError!opiter.ValueIter {
            const meta = try self.cols.value_meta.prefixIterRange(rows);
            const start = try self.cols.value_meta.getPrefix(rows.start);
            const advance = std.math.cast(usize, start) orelse return error.Overflow;
            return opiter.ValueIter.init(meta, try self.cols.value.iteratorAt(advance));
        }

        /// Each row's mark name and expansion (`OpSet::mark_info_iter_range`,
        /// `op_set.rs:1292-1297`).
        pub fn markInfoIterRange(self: *const Self, rows: RowRange) ParseError!opiter.MarkInfoIter {
            return opiter.MarkInfoIter.init(
                try self.cols.mark_name.iterRange(rows),
                try self.cols.expand.iterRange(rows),
                self.strings,
            );
        }

        /// The successor edges of the rows in `rows`, as a walk
        /// (`OpSet::succ_iter_range`, `op_set.rs:1299-1316`).
        ///
        /// The flattened cursors start at the *prefix* offset of `rows.start`
        /// and run to the end of the flattened pair, not to the end of the
        /// range (`op_set.rs:1302-1314`): a row's successors are the next
        /// `succ_count` entries and the walker advances past exactly that many.
        pub fn succIterRange(self: *const Self, rows: RowRange) ParseError!opiter.SuccIterIter {
            const offset = try self.cols.succ_count.getPrefix(rows.start);
            const succ_start = std.math.cast(usize, offset) orelse return error.Overflow;
            return opiter.SuccIterIter.init(
                try self.cols.succ_count.prefixIterRange(rows),
                try self.cols.succ_actor.iterRange(.{
                    .start = succ_start,
                    .end = self.cols.succ_actor.len(),
                }),
                try self.cols.succ_ctr.iterRange(.{
                    .start = succ_start,
                    .end = self.cols.succ_ctr.len(),
                }),
                try self.cols.index.inc.iterRange(.{
                    .start = succ_start,
                    .end = self.cols.index.inc.len(),
                }),
                succ_start,
                self.succ_scratch.items,
            );
        }

        /// Each row's action (`OpSet::action_iter_range`, `op_set.rs:898-900`).
        pub fn actionIterRange(self: *const Self, rows: RowRange) ParseError!opiter.ActionIter {
            return opiter.ActionIter.init(try self.cols.action.iterRange(rows));
        }

        /// The `insert` column as a prefix walk, so a caller can count
        /// inserts without walking rows (`OpSet::insert_acc_range`,
        /// `op_set.rs:902-904`).
        ///
        /// `PrefixIter<bool>` — upstream's `InsertAcc` (`op_set.rs:57`) and
        /// the same type — with a true row one unit long and a false row
        /// none (`[prefix.rs:316-325]`
        /// (../../github-automerge-automerge/rust/automerge/hexane/src/prefix.rs)).
        pub fn insertAccRange(
            self: *const Self,
            rows: RowRange,
        ) ParseError!opcols.BoolPrefixColumn.PrefixIter {
            return self.cols.insert.prefixIterRange(rows);
        }

        /// The `insert` column as a plain walk (`OpSet::insert_iter_range`,
        /// `op_set.rs:906-908`).
        pub fn insertIterRange(self: *const Self, rows: RowRange) ParseError!opiter.InsertIter {
            return opiter.InsertIter.init(try self.cols.insert.iterRange(rows));
        }

        /// The `index.top` column as a plain walk (`OpSet::top_index_range`,
        /// `op_set.rs:910-912`).
        pub fn topIndexRange(self: *const Self, rows: RowRange) ParseError!opcols.BoolPrefixColumn.Iterator {
            return self.cols.index.top.iterRange(rows);
        }

        /// The `key_str` column as a plain walk (`OpSet::key_str_iter_range`,
        /// `op_set.rs:927-932`).
        ///
        /// The values are interned **ids**, where upstream's are the strings
        /// themselves ([plan §5.3](../../docs/plan.md)). Resolve each through
        /// the op set's string table; [`OpSet.propRange`] is what does that
        /// when a caller wants a *range* rather than a walk.
        pub fn keyStrIterRange(self: *const Self, rows: RowRange) ParseError!opcols.UintOptColumn.Iterator {
            return self.cols.key_str.iterRange(rows);
        }

        /// The visible rows of `rows` (`OpQuery::visible`, `op_set.rs:618`,
        /// `:717`).
        ///
        /// Upstream is three lines ([`op_query.rs:42-45`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs)):
        /// build the positional skipper over `self.range()`, wrap the row walk
        /// in it, and wrap *that* in the counter folder. The row walk is the
        /// op set's own [`Self.Row`] and the skipper is [`Self.Visible`], so the
        /// two halves are indexed by the same row numbers — which is the whole
        /// of what a skip means. [`Self.VisibleRows`] says why the inner walk
        /// must not be a filter.
        ///
        /// Both halves read the op set's successor buffer, so this is a
        /// *finished iterator* rather than something a caller is meant to hold
        /// next to another walk.
        pub fn visible(self: *Self, rows: RowRange, c: ?Clock) ReadOpError!Self.VisibleRows {
            const window = column.clampRange(rows, self.cols.len());
            return Self.VisibleRows.init(
                tools.SkipIter(Op, Row, Visible).init(
                    try Row.init(&self.cols, self.strings, window, self.succ_scratch.items),
                    try Self.Visible.init(&self.cols, c, window, self.succ_scratch.items),
                ),
                c,
            );
        }

        // ── Finding a row by its own id ─────────────────────────────────

        /// Where the row with id `id` is, or null (`OpSet::get_op_id_pos`,
        /// `op_set.rs:830-835`).
        ///
        /// Upstream finds the slabs whose value range covers `id.counter` and
        /// takes the first row in one of them whose actor column is
        /// `id.actor`. So does this, and the descent is a B-tree walk with a
        /// stack one frame per level ([`btree.FindByValue`]), which is why this
        /// is the one query in this file that can allocate: it is the only one
        /// upstream's does too (`op.rs:1330`).
        ///
        /// **The first match, and why that is right.** A document's op ids are
        /// unique, so there is at most one row that answers both halves; and
        /// because `id_ctr` is delta coded and its values ascend, the first row
        /// of a candidate slab that carries the right counter is the only one
        /// that can.
        pub fn getOpIdPos(self: *const Self, id: OpId) SearchError!?usize {
            var find = try self.cols.id_ctr.findByValue(id.counter);
            defer find.deinit();
            while (find.next()) |hit| {
                const slab = self.cols.id_ctr.slabAt(hit.slab) orelse return error.InvalidValue;
                const start = hit.items_before;
                const rows: RowRange = .{ .start = start, .end = start + slab.len };
                var ctr = try self.cols.id_ctr.iterRange(rows);
                var actor = try self.cols.id_actor.iterRange(rows);
                var i: usize = 0;
                while (try ctr.next()) |c| {
                    const a = (try actor.next()) orelse break;
                    if (c == id.counter and a == id.actor) return start + i;
                    i += 1;
                }
            }
            return null;
        }

        /// The row with id `id` and whether it won its register, or null
        /// (`OpSet::find_op_by_id_and_vis_fast`, `op_set.rs:1114-1119`).
        ///
        /// [`SearchError`] is in the set because [`OpSet.getOpIdPos`] is the
        /// only method here that descends a B-tree
        /// ([`btree.TreeError`](op_set.zig)), and the three methods that
        /// call it all carry it.
        pub fn findOpByIdAndVisFast(self: *Self, id: OpId) (ReadOpError || SearchError)!?OpAndVisible {
            const pos = (try self.getOpIdPos(id)) orelse return null;
            const top = (try self.cols.index.top.get(pos)) orelse false;
            const row = (try self.get(pos)) orelse return null;
            return .{ .op = row, .visible = top };
        }

        /// The row with id `id` and whether it won its register, walking the
        /// rest of its register (`OpSet::find_op_by_id_and_vis_slow`,
        /// `op_set.rs:1121-1140`).
        ///
        /// The slow path is not about the row but about the *register*: the
        /// fast path answers with `index.top[pos]`, which is the winner for the
        /// present; for a clock the row is the one a reader would see only if
        /// no later row of the same register is in view (`:1131-1138`). Upstream
        /// `break`s out with `vis = false` on the first such row, and so does
        /// this.
        pub fn findOpByIdAndVisSlow(self: *Self, id: OpId, c: ?Clock) (ReadOpError || SearchError)!?OpAndVisible {
            const start = (try self.getOpIdPos(id)) orelse return null;
            var walk = try self.iterRange(.{ .start = start, .end = self.len() });
            var first = (try walk.next()) orelse return null;
            var in_view = first.scopeToClock(c);
            while (try walk.next()) |row_const| {
                // `scope_to_clock` rewrites a counter's value in place
                // (`op.zig:2129`), so the row is copied into a `var` first:
                // the walk's own yield is a `const` value.
                var row = row_const;
                if (!first.objId().eql(row.objId()) or
                    !first.elemidOrKey().eql(row.elemidOrKey()))
                {
                    break;
                }
                if (row.scopeToClock(c)) {
                    in_view = false;
                    break;
                }
            }
            return .{ .op = first, .visible = in_view };
        }

        /// The row with id `id` and whether it won its register
        /// (`OpSet::find_op_by_id_and_vis`, `op_set.rs:1100-1112`).
        ///
        /// The fast answer for the present, the slow one for a clock, and
        /// **upstream's `debug_assert_eq!` between them is ported as a real
        /// check** (`:1107`) — the two must agree for a null clock too, and
        /// `error.Invariant` names the disagreement rather than leaving it to a
        /// debug build to notice.
        pub fn findOpByIdAndVis(self: *Self, id: OpId, c: ?Clock) (ReadOpError || SearchError || InternalError)!?OpAndVisible {
            if (c) |cover| return self.findOpByIdAndVisSlow(id, cover);
            const fast = try self.findOpByIdAndVisFast(id);
            const slow = try self.findOpByIdAndVisSlow(id, null);
            if (!opAndVisibleEqual(fast, slow)) return error.Invariant;
            return fast;
        }

        // ── Parent ──────────────────────────────────────────────────────

        /// Where `child` hangs, and whether the operation that made it is what
        /// a reader would see (`OpSet::parent_object`, `op_set.rs:353-375`).
        ///
        /// Four steps in upstream's order: find the making operation
        /// (`:354`), ask the object index what it made (`:356`), read the
        /// property off the operation's own key (`:357-368`), and report. A
        /// sequence child is reported by *index*, not by anchor, which is why
        /// this needs [`OpSet.seekListOpid`] and why a clock changes the answer
        /// (`:365`).
        ///
        /// Upstream `panic!`s if a sequence key hangs off something that is
        /// not a sequence (`:363`); that is `error.InvalidValue` here. It
        /// cannot arise from a well-formed document — a key's shape and its
        /// parent's type are written together by the merge walkers — but the
        /// port does not trap on bytes
        /// ([error.zig:6-12](../error.zig)).
        pub fn parentObject(self: *Self, child: ObjId, c: ?Clock) (ReadOpError || SearchError || InternalError)!?Parent {
            const id = child.opId() orelse return null;
            const found = (try self.findOpByIdAndVis(id, c)) orelse return null;
            const obj = found.op.objId();
            const typ = self.objectType(obj) orelse return null;
            const prop: Prop = switch (found.op.key()) {
                .map => |k| .{ .key = k },
                .seq => blk: {
                    const seq_type: SequenceType = switch (typ) {
                        .list => .list,
                        .text => .text,
                        else => return error.InvalidValue,
                    };
                    const at = (try self.seekListOpid(obj, found.op.id(), seq_type, c)) orelse
                        return null;
                    break :blk .{ .index = at.index };
                },
            };
            return .{ .obj = obj, .typ = typ, .prop = prop, .visible = found.visible };
        }

        // ── The object index, read out ──────────────────────────────────

        /// What kind of object `obj` is (`OpSet::object_type`,
        /// `op_set.rs:1171-1173`).
        pub fn objectType(self: *const Self, obj: ObjId) ?ObjType {
            return self.obj_info.objectType(obj);
        }

        /// Which object `obj` hangs in (`OpSet::object_parent`,
        /// `op_set.rs:1175-1177`).
        pub fn objectParent(self: *const Self, obj: ObjId) ?ObjId {
            return self.obj_info.objectParent(obj);
        }

        /// The export id of `id` ([`OpSet::id_to_exid`](
        /// `op_set.rs:1054-1060`)).
        ///
        /// **Upstream's `ExId::Id` is `(counter, actor, index)` — counter,
        /// actor **bytes**, actor index — and the bytes are the whole point of
        /// the middle field** ([`exid.rs`:17](../../github-automerge-automerge/rust/automerge/src/exid.rs)).
        /// The actor table is sorted ([`op_set.rs`:1400-1405](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
        /// so interning an actor that sorts before the others — which is what
        /// `isolate` does, with a concurrency actor whose magic bytes are
        /// `0x13 b2 23 09` ([`types.rs`:23](../../github-automerge-automerge/rust/automerge/src/types.rs))
        /// — renumbers every index at or above it. An `ExId` therefore only
        /// means something *beside* the table it was minted from, and upstream
        /// compares the **bytes** ([`exid.rs`:126-138](../../github-automerge-automerge/rust/automerge/src/exid.rs))
        /// and re-resolves the index on every use ([`automerge.rs`:744-758](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        ///
        /// The op set *is* the table ([`OpSet.getActor`](op_set.zig),
        /// `op_set.rs`:1183-1185`), so the bytes are one bounds-checked read
        /// away and there is nothing to look up beyond it — which is why
        /// [`Document.idToExid`](../doc.zig) is now this same answer, and why
        /// the port's own "identity is the [`OpId`] alone, in both shapes"
        /// ([`types.zig`:267-272](../types.zig)) keeps every hash map keyed by
        /// an `ExId` working: the bytes are a repair hint, never part of what
        /// the id *is*.
        ///
        /// **An index the table does not have is a bare `ExId.id`, which is the
        /// old behaviour and has no actor to check.** It is reachable only
        /// from a row whose actor column is out of range, which
        /// [`OpSet.splice`] would have rejected.
        pub fn idToExid(self: *const Self, id: OpId) ExId {
            if (id.eql(OpId.root)) return .root;
            const who = self.getActorSafe(id.actor) orelse return .{ .id = id };
            return ExId.withActor(id, who);
        }

        /// `"<counter>@<actor>"` for `id` (`OpSet::to_string`,
        /// `op_set.rs:1093-1098`).
        ///
        /// The root's text is upstream's `Export::Special("root")`
        /// (`types.rs:376-383`); everything else is the format string at
        /// `op_set.rs:1095`. The caller owns the result.
        pub fn opIdText(self: *const Self, gpa: Allocator, id: OpId) Error![]u8 {
            if (id.eql(OpId.root)) return gpa.dupe(u8, "root");
            const actor = self.getActor(id.actor) orelse return error.InvalidActorIndex;
            return std.fmt.allocPrint(gpa, "{}@{s}", .{ id.counter, actor.bytes });
        }

        // ── The object boundary walk ────────────────────────────────────

        /// The objects in the op set, with their rows (`OpSet::iter_obj_ids`,
        /// `op_set.rs:1062-1075`).
        pub fn iterObjIds(self: *const Self) ParseError!Self.ObjIds {
            return Self.ObjIds.init(&self.cols);
        }

        /// Every object the op set knows about, with its rows
        /// (`OpSet::iter_objs`, `op_set.rs:1077-1083`).
        ///
        /// A **callable**, because upstream's returns an `impl Iterator` and
        /// building one allocates: a `filter_map` over
        /// [`OpSet.iterObjIds`] that drops a boundary whose object the index
        /// does not hold. There is no such object in a well-formed document —
        /// the index is written by the same splice that writes the rows — and
        /// the drop is upstream's (`:1079`).
        ///
        /// The caller owns the list and frees it. Each entry is an
        /// [`ObjMeta`] and the walk over that object's rows, and every walk
        /// borrows the op set's successor buffer, so a caller that keeps one
        /// alive past the next one has to build the second with
        /// [`op_iter.OpIter.init`] and its own buffer.
        pub fn iterObjs(self: *Self, gpa: Allocator) ParseError![]ObjectRows {
            var out: std.ArrayList(ObjectRows) = .empty;
            errdefer out.deinit(gpa);
            var boundaries = try self.iterObjIds();
            while (try boundaries.next()) |span| {
                const typ = self.objectType(span.id) orelse continue;
                try out.append(gpa, .{
                    .meta = .{ .id = span.id, .typ = typ },
                    .range = span.range,
                });
            }
            return out.toOwnedSlice(gpa);
        }

        // ── The winner walk ─────────────────────────────────────────────

        /// The winners of `obj`'s registers (`OpSet::top_ops`,
        /// `op_set.rs:1085-1091`).
        ///
        /// `scopeToObj` then [`top_op.TopOps.init`] with a fresh
        /// [`top_op.TopScratch`] of the op set's own successor buffer. Upstream
        /// has three lazy cursors and needs no scratch; the port's
        /// [`Self.Winners`] holds three walks alive at once and each needs its
        /// own (see [`top_op.TopScratch`]), so one is built here and freed by
        /// [`Winners.deinit`].
        pub fn topOps(self: *Self, obj: ObjId, c: ?Clock) TopError!Self.Winners {
            const range = try self.scopeToObj(obj);
            var scratch = try topop.topScratch(O, self.gpa, &self.cols, range);
            errdefer scratch.deinit(self.gpa);
            return .{
                .ops = try Self.WinnerIter.init(&self.cols, self.strings, range, c, scratch),
                .scratch = scratch,
            };
        }

        // ── Increment differences ────────────────────────────────────────

        /// The counter value a reader would see at `pos` before and after a
        /// clock range (`OpSet::get_increment_diff_at_pos`,
        /// `op_set.rs:1142-1169`).
        ///
        /// Two sums over the same walk: the increments the *before* clock
        /// covers and the increments the *after* clock covers, and the caller
        /// subtracts them. Both are `ClockRange`'s two predicates —
        /// `visible_before` and `visible_after` (`clock.rs:99-116`) — which the
        /// port's [`ClockRange`] does not carry, so [`visibleBefore`] and
        /// [`visibleAfter`] below are that code.
        pub fn getIncrementDiffAtPos(self: *Self, pos: usize, over: ClockRange) (Error || ParseError)!IncrDiff {
            // `get` is the bounds test — a row past the end has none
            // (`op_set.rs:1143`) — and the two prefix lookups are the
            // window this row's own successors occupy: `sc.prefix()` is the
            // offset of the first and `sc.total()` one past the last
            // (`op_set.rs:1144-1145`), which for a `Prefix(u32)` column is
            // `getPrefix(pos)` and `getPrefix(pos + 1)`.
            _ = (try self.cols.succ_count.get(pos)) orelse return .{ .before = 0, .after = 0 };
            const start = std.math.cast(usize, try self.cols.succ_count.getPrefix(pos)) orelse
                return error.Overflow;
            const end = std.math.cast(usize, try self.cols.succ_count.getPrefix(pos + 1)) orelse
                return error.Overflow;
            const rows: RowRange = .{ .start = start, .end = end };
            // op_set.rs:1150-1152 — the three cursors over the flattened pair,
            // windowed to this row's own successors.
            var succ_actor = try self.cols.succ_actor.iterRange(rows);
            var succ_ctr = try self.cols.succ_ctr.iterRange(rows);
            var incs = try self.cols.index.inc.iterRange(rows);
            var before: i64 = 0;
            var after: i64 = 0;
            while (try succ_actor.next()) |a| {
                const c = (try succ_ctr.next()) orelse break;
                const inc = (try incs.next()) orelse break;
                const edge = if (inc) |v| v else continue;
                const id = OpId.init(c, a);
                if (visibleBefore(over, id)) before += edge;
                if (visibleAfter(over, id)) after += edge;
            }
            return .{ .before = before, .after = after };
        }

        // ── The iteration wrappers upstream declares in `src/iter/` ─────

        /// The winners `Keys` wraps (`OpSet::keys`, `op_set.rs:377-379`).
        ///
        /// Upstream is `Keys::new(self, self.top_ops(obj, clock))`, one line,
        /// and the module doc says why the wrapper is not declared here. This
        /// is the walk it takes.
        pub fn keys(self: *Self, obj: ObjId, c: ?Clock) TopError!Self.Winners {
            return self.topOps(obj, c);
        }

        /// The rows `SpansInternal` walks (`OpSet::spans`, `op_set.rs:381-384`).
        ///
        /// Upstream is `SpansInternal::new(self, self.scope_to_obj(obj), clock,
        /// self.text_encoding)`, so the pieces are the object's rows, the clock
        /// the caller already has, and [`OpSet.textEncoding`].
        pub fn spans(self: *const Self, obj: ObjId) ParseError!RowRange {
            return self.scopeToObj(obj);
        }

        /// The rows `ListRange` walks (`OpSet::list_range`, `op_set.rs:386-394`).
        ///
        /// Upstream is `ListRange::new(self, self.scope_to_obj(obj), clock,
        /// range)`: the object's rows, the caller's own `[from, to)` bound, and
        /// the clock. This is the first of the three.
        pub fn listRange(self: *const Self, obj: ObjId) ParseError!RowRange {
            return self.scopeToObj(obj);
        }

        /// The rows of `obj` whose key falls in a span of map keys
        /// (`OpSet::map_range`, `op_set.rs:396-419`).
        ///
        /// This one is **real logic and it is here**: upstream turns the two
        /// `RangeBounds<String>` into one row range by scoping `key_str` to
        /// each bound, and the four arms (included/excluded/unbounded at each
        /// end) are the whole of it. **All four are reachable here**, which is
        /// what the [`KeyBound`] arms are for: `Included` and `Excluded` at
        /// the same end name **different** row ranges, one register apart
        /// (`:408` against `:409`, `:414` against `:415`), so a pair of plain
        /// optional keys could not express this — it reached only the two
        /// `Included` arms. A null bound is upstream's `Unbounded` (`:407`,
        /// `:413`) and is the head or the tail of the object.
        ///
        /// Every arm is a [`OpSet.propRange`] call, which is what makes this
        /// O(rows of the object) rather than O(log S) — see that method for why
        /// a descent is not available for a string column in this port.
        ///
        /// **`start >= end` is empty, not reversed.** Upstream's `start..end`
        /// is a Rust `Range`, which carries no rows under that condition, and
        /// `MapRange::new` hands it straight through
        /// ([`map_range.rs:204-208`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs));
        /// `@max` is that emptiness.
        pub fn mapRange(
            self: *const Self,
            obj: ObjId,
            start: ?KeyBound,
            end: ?KeyBound,
        ) ParseError!RowRange {
            const obj_range = try self.scopeToObj(obj);
            const first: usize = blk: {
                const bound = start orelse break :blk obj_range.start;
                break :blk switch (bound) {
                    .included => |k| (try self.propRange(obj, k)).start,
                    .excluded => |k| (try self.propRange(obj, k)).end,
                };
            };
            const last: usize = blk: {
                const bound = end orelse break :blk obj_range.end;
                break :blk switch (bound) {
                    .included => |k| (try self.propRange(obj, k)).end,
                    .excluded => |k| (try self.propRange(obj, k)).start,
                };
            };
            return .{ .start = first, .end = @max(first, last) };
        }

        /// How this op set measures text (`OpSet`'s `text_encoding` field,
        /// `op_set.rs:64`).
        pub fn textEncoding(self: *const Self) TextEncoding {
            return self.text_encoding;
        }

        // ── Sequence positions ──────────────────────────────────────────

        /// Whether every row in `rows` won its register
        /// (`OpSet::all_of_range_is_top`, `op_set.rs:916-925`).
        ///
        /// One prefix arithmetic, no walk: `index.top`'s prefix over the range
        /// is the number of winners in it (`:923-924`), and a range where that
        /// equals the range's length has a winner in every row. The empty range
        /// is trivially all-top and says so first, because the arithmetic on an
        /// empty range is not worth trusting.
        ///
        /// This exists so a span walk over a dense current document can skip
        /// top-filtering entirely (`op_set.rs:917`).
        pub fn allOfRangeIsTop(self: *const Self, rows: RowRange) ParseError!bool {
            if (rows.start >= rows.end) return true;
            var top = try self.cols.index.top.prefixIter();
            const seek = try top.delta(rows.start, rows.end) orelse return false;
            return seek.delta == (rows.end - rows.start);
        }

        /// The element the row at `pos` belongs to, and the last row that
        /// belongs to the same element (`OpSet::elemid_at`, `op_set.rs:793-828`).
        ///
        /// The `ElemId` is the row's own id when it inserts and its key's
        /// element otherwise (`:807-814`), and the walk forward stops at the
        /// first row with a different one — which is rule **R3**, a register's
        /// rows being contiguous, and is why this is a forward walk of at most
        /// one register.
        ///
        /// A row whose key is neither a map key nor a sequence anchor is
        /// `error.MissingKey` from the walk, and a row past `end` is null.
        pub fn elemidAt(self: *Self, pos: usize, end: usize) ReadOpError!?ElemPos {
            const rows: RowRange = .{ .start = pos, .end = end };
            var insert = try self.cols.insert.iterRange(rows);
            var id_ctr = try self.cols.id_ctr.iterRange(rows);
            var id_actor = try self.cols.id_actor.iterRange(rows);
            var key_ctr = try self.cols.key_ctr.iterRange(rows);
            var key_actor = try self.cols.key_actor.iterRange(rows);
            const elemid = try nextElemid(
                &insert,
                &id_ctr,
                &id_actor,
                &key_ctr,
                &key_actor,
            ) orelse return null;
            var last_pos = pos;
            var at = pos + 1;
            while (at < end) : (at += 1) {
                const next = try nextElemid(&insert, &id_ctr, &id_actor, &key_ctr, &key_actor) orelse
                    break;
                if (!next.eql(elemid)) break;
                last_pos = at;
            }
            return .{ .elemid = elemid, .last_pos = last_pos };
        }

        /// The rows of the register a row at `pos` belongs to
        /// (`OpSet::list_register_at_pos`, `op_set.rs:688-704`).
        ///
        /// Four arms, and they are upstream's (`:692-703`). The shape: if the
        /// row at `pos` inserts and the run behind it does not, the register
        /// is the whole run plus this row; if the row inserts and the run
        /// behind it is also inserts, it is just this row — the row *is* the
        /// element; if the row overwrites, the register starts at the element's
        /// own insert, which `getIndexForTotal` finds because the `insert`
        /// column's total at that row is the number of inserts at or before it.
        ///
        /// The walk is over `0..range.end` and then `nth(pos)`, so `pos` is an
        /// absolute row: upstream's `iter_range(0..range.end)` with
        /// `iter.nth(pos)` (`:689-690`) is the same, and the `0..` is load
        /// bearing because the cursor's `nth` is relative to where it started.
        ///
        /// **A register does not leave its object, and upstream's third arm
        /// can.** `start` is `get_index_for_total(pv.total())`
        /// (`op_set.rs:696`), which is the row of the `pv.total()`-th
        /// before `pos` ([`prefix.rs:706-710`](../../github-automerge-automerge/rust/hexane/src/prefix.rs)).
        /// **When that count is zero the question has no answer**, and
        /// upstream's answer is row 0 of the whole op set:
        /// `get_index_for_total(t)` is `get_index_for_prefix(t) -
        /// saturating_sub(1)` (`prefix.rs:596-598`) and
        /// `get_index_for_prefix` returns `0` for a `t` at or below zero
        /// (`prefix.rs:605-608`), so `t = 0` gives `0 -| 1 = 0`. A list
        /// element made as the very first row of its object — a `set` hung
        /// by the head, or a row keyed by a map string — has no insert
        /// before it, and the register the fast paths then walk is
        /// `0..pos + 1`: **rows out of the object**, which the prefix
        /// descent had already excluded.
        ///
        /// The `@max` is the whole of the difference, and it is a no-op
        /// wherever the write path can reach. A sequence register's element
        /// is always made by an earlier `insert`: an overwrite carries the
        /// element id of an element that exists, and the one upstream
        /// constructor that pairs `insert: false` with a `Seq` key —
        /// `TxOp::list` (`op.rs:261-294`, `key: KeyRef::Seq(elemid)` at
        /// `:289` and `insert: false` at `:290`) — takes that id from
        /// `query.ops.first().and_then(|op| op.cursor().ok())`
        /// (`inner.rs:510-514`), which for an `insert` row is the row's own
        /// id (`op.rs:1073-1076`). So `pv.total() >= 1` there, `start` is
        /// that insert's row, and that row is in `range`. The degenerate
        /// case needs a first row that is `insert = false` and keyed by the
        /// head or by a map string, and `Op::cursor` answers such a row's own
        /// key (`op.rs:1077-1080`), so the head can only be a key if such a
        /// row already exists — the first one is not writable.
        ///
        /// **Measured, 2026-10-01**, on the two fixtures of that shape —
        /// `src/cursor.zig`'s `head_set_list` and `a_list`. Before: object
        /// range `1..2`, register `0..2`, two rows where the reference walk
        /// (`op_set.rs:663-666`, `iter_obj`) has one. That was two of
        /// `zig build slow-path`'s failures and both of its leaks. After:
        /// the cross-check agrees over the whole suite.
        pub fn listRegisterAtPos(self: *const Self, pos: usize, range: RowRange) ParseError!RowRange {
            var it = try self.cols.insert.prefixIterRange(.{ .start = 0, .end = range.end });
            const at_pos = try it.nth(pos);
            const next_run = try it.nextRun();
            if (at_pos) |pv| {
                if (pv.value) {
                    if (next_run) |run| {
                        if (!run.value.value) return .{ .start = pos, .end = pos + run.count + 1 };
                    }
                    return .{ .start = pos, .end = pos + 1 };
                }
                // op_set.rs:696 — the register starts at its own insert,
                // and `range.start` is the floor that arm does not say.
                const start = @max(try self.cols.insert.getIndexForTotal(pv.total()), range.start);
                if (next_run) |run| {
                    if (!run.value.value) return .{ .start = start, .end = pos + run.count + 1 };
                }
                return .{ .start = start, .end = pos + 1 };
            }
            return .{ .start = pos, .end = pos };
        }

        // ── Finding a register by map key ───────────────────────────────

        /// The rows of one map key of `obj` that a clock has in view
        /// (`OpSet::seek_ops_by_map_key`, `op_set.rs:611-628`).
        ///
        /// `propRange` → `iterRange` → the visible walk, collected. Upstream
        /// asserts that the walk ended where the register does (`:621`); the
        /// port reports it as `error.Invariant`, because a walk that ended
        /// early would otherwise hand back a short register and read as a
        /// document with fewer rows than it has.
        ///
        /// The caller owns `found` and frees it with
        /// [`OpsFound.deinit`](found_op.zig).
        pub fn seekOpsByMapKey(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            key: []const u8,
            c: ?Clock,
        ) (ReadOpError || InternalError)!OpsFound {
            const range = try self.propRange(obj, key);
            var walk = try self.iterRange(range);
            const end_pos = walk.endPos();
            var found = OpsFound.init(gpa);
            errdefer found.deinit(gpa);
            var rows = try self.visible(range, c);
            while (try rows.next()) |row| try found.ops.append(gpa, row);
            if (end_pos != range.end) return error.Invariant;
            found.range = range;
            found.end_pos = end_pos;
            return found;
        }

        // ── Finding a register by sequence index ────────────────────────

        /// The rows of the list element at `index` in `obj`
        /// (`OpSet::seek_ops_by_index`, `op_set.rs:632-654`).
        ///
        /// The fast path for the present and the slow one for a clock, and
        /// **upstream's `slow_path_assertions` cross-check is ported behind
        /// [`check_slow_paths`]** (`:645-649`), which is the port's spelling of
        /// upstream's feature gate ([plan §2](../../docs/plan.md)). A test
        /// compares the two answers directly, so the check is exercised whether
        /// or not the flag is set.
        pub fn seekOpsByIndex(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
            seq_type: SequenceType,
            c: ?Clock,
        ) (ReadOpError || InternalError)!OpsFound {
            if (c) |cover| return self.seekOpsByIndexSlow(gpa, obj, index, seq_type, cover);
            var found = if (seq_type == .list)
                try self.seekListOpsByIndexFast(gpa, obj, index)
            else
                try self.seekTextOpsByIndexFast(gpa, obj, index);
            // **`found` owns its rows, so every arm that leaves without
            // handing it back has to give them away.** Upstream's
            // `assert_eq!` aborts the process and never returns
            // (`op_set.rs:648`); this port reports `error.Invariant` and
            // carries on, and a cross-check that reported the fault by
            // leaking the answer it was checking was an `ABRT` two lines
            // after the diagnosis — `zig build slow-path` lost two tests to
            // it, both leaks one `ArrayList` buffer allocated at
            // `seekListOpsByIndexFast`'s `append`.
            errdefer found.deinit(gpa);
            if (check_slow_paths) {
                var slow = try self.seekOpsByIndexSlow(gpa, obj, index, seq_type, null);
                defer slow.deinit(gpa);
                if (!opsFoundEqual(found, slow)) return error.Invariant;
            }
            return found;
        }

        /// The rows of the list element at `index`, found by grouping the
        /// object's registers (`OpSet::seek_ops_by_index_slow`,
        /// `op_set.rs:656-686`).
        ///
        /// **Grouping, not widths**: upstream accumulates `ops.width(..)` per
        /// group and stops at the first group that would pass `index`
        /// (`:670-673`). A group's width is its *last* row's
        /// ([`OpsFound.width`](found_op.zig)), which is the register's winner —
        /// so a conflicted register contributes the width of the value that
        /// won, and that is what a reader sees.
        ///
        /// The grouper drops mark rows ([`opmarks.NoMarkIter`],
        /// `op_set.rs:666`) because a mark is not a value and has no width.
        ///
        /// Upstream's trailing `assert_eq!(range.end, end_pos)` (`:679`) checks
        /// the *grouper's own* bookkeeping against itself, which
        /// [found_op.zig](found_op.zig) maintains row by row; it is not
        /// reproduced here because there is nothing left for it to compare.
        /// An index past the end of the sequence is upstream's
        /// `OpsFound { index, ops: vec![], end_pos: end, range: end..end }`
        /// (`:680-685`).
        pub fn seekOpsByIndexSlow(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
            seq_type: SequenceType,
            c: ?Clock,
        ) (ReadOpError || InternalError)!OpsFound {
            const sub = try self.iterObj(obj);
            const end = sub.endPos();
            var grouper = Self.Grouped.init(gpa, opmarks.NoMarkIter(Row).init(sub), c);
            defer grouper.deinit();
            var walked: usize = 0;
            while (try grouper.next()) |group| {
                // A group this walk steps *over* owns a `Vec<Op>` in Rust and
                // is dropped with it; here it owns an `ArrayList` and has to
                // be freed. The `defer` is registered only on the arm that
                // drops it, so the group that is returned is not freed twice.
                var found = group;
                const width = found.width(seq_type, self.text_encoding);
                if (walked + width > index) {
                    found.index = walked;
                    return found;
                }
                defer found.deinit(gpa);
                walked += width;
            }
            return .{
                .index = index,
                .ops = .empty,
                .end_pos = end,
                .range = .{ .start = end, .end = end },
            };
        }

        /// The rows of the list element at `index`, found by prefix arithmetic
        /// on `index.top` (`OpSet::seek_list_ops_by_index_fast`,
        /// `op_set.rs:706-733`).
        ///
        /// `index.top`'s prefix is the number of winners before a row, so
        /// `advancePrefix(index)` lands on the index-th winner and one prefix
        /// descent gets there. The register is then expanded backwards to its
        /// insert with [`OpSet.listRegisterAtPos`], so the group a reader sees
        /// is the whole register and not just its winner.
        pub fn seekListOpsByIndexFast(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
        ) ReadOpError!OpsFound {
            const range = try self.scopeToObj(obj);
            var top = try self.cols.index.top.prefixIterRange(range);
            const tx = try top.advancePrefix(@intCast(index)) orelse return .{
                .index = index,
                .ops = .empty,
                .end_pos = range.end,
                .range = .{ .start = range.end, .end = range.end },
            };
            const register = try self.listRegisterAtPos(tx.pos, range);
            var found = OpsFound.init(gpa);
            errdefer found.deinit(gpa);
            const walk = try self.iterRange(register);
            var rows = try self.visible(register, null);
            while (try rows.next()) |row| try found.ops.append(gpa, row);
            found.index = index;
            found.range = register;
            found.end_pos = register.end;
            _ = walk;
            return found;
        }

        /// The rows of the text character at `index`, found by prefix
        /// arithmetic on `index.text` (`OpSet::seek_text_ops_by_index_fast`,
        /// `op_set.rs:735-784`).
        ///
        /// **The text index carries an element's width on its `top` row, which
        /// is the element's *last* row** — upstream says so at `:748-752` — so
        /// `advancePrefix` lands on the winner, not on the insert. The register
        /// is therefore expanded back to its insert and then walked forward
        /// (`:753-770`), which is what collects every row of the element
        /// including the conflicting values that sort before the winner, and
        /// stops at the second insert.
        ///
        /// `index` is *rewritten* to `tx.delta` on the way: the prefix the
        /// descent consumed is the index of the element, and the index asked
        /// for may have been inside a multi-unit character.
        pub fn seekTextOpsByIndexFast(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
        ) (ReadOpError || InternalError)!OpsFound {
            var range = try self.scopeToObj(obj);
            var text_col = try self.cols.index.text.prefixIterRange(range);
            const seek = try text_col.advancePrefix(@intCast(index)) orelse return .{
                .index = index,
                .ops = .empty,
                .end_pos = range.end,
                .range = .{ .start = range.end, .end = range.end },
            };
            // op_set.rs:747 — a descent that overshot would be a bug in the
            // index, not a document.
            if (seek.delta < 0 or seek.delta > @as(i64, @intCast(index))) return error.Invariant;
            var found = OpsFound.init(gpa);
            errdefer found.deinit(gpa);
            const register = try self.listRegisterAtPos(seek.pos, range);
            range.start = register.start;
            const at: usize = @intCast(seek.delta);
            var walk = try self.iterRange(range);
            var end_pos = range.end;
            while (try walk.next()) |row| {
                if (row.insert()) {
                    if (found.ops.items.len != 0) break;
                    range.start = row.pos;
                }
                end_pos = row.pos + 1;
                range.end = row.pos + 1;
                if (row.succCount() == 0 and row.action() != .mark) {
                    try found.ops.append(gpa, row);
                }
            }
            found.index = at;
            found.range = range;
            found.end_pos = end_pos;
            return found;
        }

        // ── Finding an operation by id inside a sequence ────────────────

        /// The operation `opid`, where its element sits, and whether that
        /// element is visible (`OpSet::seek_list_opid`, `op_set.rs:837-851`).
        ///
        /// The fast path for the present and the slow one for a clock, and
        /// **upstream's `debug_assert_eq!` between them is ported as a real
        /// check** (`:846`). The two arms agree on every document whose index
        /// is sound, and the check is what says so; where they do not agree the
        /// check is the answer. **Both arms read `index.visible` for
        /// [`FoundOpId.visible`](op_set.zig)** — upstream's read `index.top`
        /// (`op_set.rs:867`) and `index.text` (`:872`) against the walk's
        /// `ops.ops.contains` (`:890`), which are two different questions and
        /// disagree on a merged document; see the two arms' own doc comments
        /// and the difference block at the foot of this file.
        pub fn seekListOpid(
            self: *Self,
            obj: ObjId,
            opid: OpId,
            seq_type: SequenceType,
            c: ?Clock,
        ) (ReadOpError || SearchError || InternalError)!?FoundOpId {
            if (c) |cover| return self.seekListOpidSlow(obj, opid, seq_type, cover);
            const fast = try self.seekListOpidFast(obj, opid, seq_type);
            const slow = try self.seekListOpidSlow(obj, opid, seq_type, null);
            if (!foundOpIdEqual(fast, slow)) return error.Invariant;
            return fast;
        }

        /// The fast answer: two prefix descents — one on `index.top` or
        /// `index.text` for the index, and `index.visible[pos]` read straight
        /// out for the visibility (`OpSet::seek_list_opid_fast`,
        /// `op_set.rs:853-876`).
        ///
        /// The row's position is found first ([`OpSet.getOpIdPos`]) and the
        /// prefix at that position is the index of the element: `index.top`'s
        /// prefix counts winners and `index.text`'s counts width, and on a
        /// list a register has exactly one winner, so the count of winners
        /// before a row is the count of registers before it. **That is the
        /// whole correctness argument for the index**, and it rests on a
        /// property of the index rather than on this code: one winner per
        /// register. [`OpSet.validateTopIndex`] is the checker for it
        /// (upstream's `assert_eq!(first_top, last_vis)`, `op_set.rs:196-212`),
        /// and [`OpSet.seekListOpid`]'s cross-check is what reports a document
        /// that breaks it. A register with two winners makes the prefix count
        /// one element too many, and no descent can repair that: the register's
        /// first row is only findable by walking back over the key column,
        /// which is the walk [`OpSet.seekListOpidSlow`] already does. So the
        /// answer there is the disagreement, not a number.
        ///
        /// **The visibility is `index.visible`, and not the value the index
        /// descent happened to land on.** Upstream reads `prefix.pv.value` —
        /// `index.top`'s value at the row (`op_set.rs:867`) and `index.text`'s
        /// (`:872`) — and that answers a *different* question: "did this row
        /// win its register", which is `top`'s meaning and not `visible`'s.
        /// The two columns are separate facts and upstream's own index
        /// checker says so (`op_set.rs:202-207`). A row that is still visible
        /// and lost its register to a later conflicting write is the ordinary
        /// shape of a merged document, and for that row `index.top` is false
        /// while `index.visible` is true — so upstream's fast arm reported a
        /// row a reader can see as absent, and the slow arm reported it as
        /// present, and the `debug_assert_eq!` between them (`op_set.rs:846`)
        /// panicked. The only consumer of the flag asks the question
        /// `index.visible` answers: "is this element still there"
        /// (`automerge.rs:1803`, [`getCursorPosition`](cursor.zig)'s
        /// `found.visible` arm at `cursor.zig:796`).
        pub fn seekListOpidFast(
            self: *Self,
            obj: ObjId,
            id: OpId,
            seq_type: SequenceType,
        ) (ReadOpError || SearchError || InternalError)!?FoundOpId {
            const obj_range = try self.scopeToObj(obj);
            const pos = (try self.getOpIdPos(id)) orelse return null;
            if (pos < obj_range.start or pos >= obj_range.end) return error.InvalidIndex;
            const row = (try self.get(pos)) orelse return null;
            var index: usize = undefined;
            if (seq_type == .list) {
                var top = try self.cols.index.top.prefixIter();
                const prefix = (try top.delta(obj_range.start, pos)) orelse return error.InvalidIndex;
                index = std.math.cast(usize, prefix.delta) orelse return error.Overflow;
            } else {
                var text_col = try self.cols.index.text.prefixIter();
                const prefix = (try text_col.delta(obj_range.start, pos)) orelse return error.InvalidIndex;
                index = std.math.cast(usize, prefix.delta) orelse return error.Overflow;
            }
            // `index.visible` has one row per row of the set, like `index.top`
            // (`op_set.rs:181-182`), and `pos` is a row of this object. A
            // column that stops short of it is an index fault
            // [`OpSet.validateTopIndex`] names, and this is the wrong place to
            // answer it.
            const is_visible = (try self.cols.index.visible.get(pos)) orelse
                return error.Invariant;
            return .{ .op = row, .index = index, .visible = is_visible };
        }

        /// The slow answer: walk the object's registers and find the one the row
        /// belongs to (`OpSet::seek_list_opid_slow`, `op_set.rs:878-896`).
        ///
        /// The index is accumulated a group at a time (`:893`), and a group
        /// whose end is *past* the row is the one the row is in (`:889`) —
        /// the group that contains the row, so the row is found by a
        /// containment test rather than by arithmetic.
        ///
        /// **The grouper runs out, and the answer is not `null`** (upstream's
        /// `None`, `op_set.rs:895`). A register whose rows are all filtered
        /// out is dropped and never yielded ([found_op.rs:70-75]), so a
        /// document in which every register *after* the last visible one is
        /// deleted exhausts the walk before the row's own register is offered.
        /// The row is still there — `iterObjAndFind` found it in this
        /// object — and every group the walk skipped was empty, so it
        /// contributed no width and the accumulated index is exactly the
        /// index the prefix descent in [`OpSet.seekListOpidFast`] reports.
        /// Returning `null` here instead made the two disagree, and
        /// [`OpSet.seekListOpid`]'s cross-check answer `error.Invariant` for a
        /// document a cursor has to resolve: a cursor on an element that was
        /// deleted, in an object where everything after it was deleted too.
        /// That is the `MoveCursor` case `MoveCursor::After` is defined by
        /// (`automerge.rs:1790-1794`).
        ///
        /// **The visibility is [`Self.rowVisibleIn`](op_set.zig)'s, and that is
        /// the one place it is written.** Upstream's slow arm answers
        /// `ops.ops.contains(&op)` over an `iter_obj(obj).no_marks()` walk
        /// (`op_set.rs:886`, `:890`), which drops the one row a `FoundOpId`
        /// still has to answer for — **a mark** — and so reports a mark as
        /// absent while upstream's own fast arm reports it present
        /// (`index.text` is `Some(0)` on a mark, `index.rs:223-228`, so
        /// `prefix.pv.value != null` at `op_set.rs:872`) and the
        /// `debug_assert_eq!` between them (`op_set.rs:846`) panics on a marked
        /// text object. A mark is at a position: `index.top` counts it, and it
        /// holds no width.
        pub fn seekListOpidSlow(
            self: *Self,
            obj: ObjId,
            opid: OpId,
            seq_type: SequenceType,
            c: ?Clock,
        ) (ReadOpError || SearchError || InternalError)!?FoundOpId {
            const row = (try self.iterObjAndFind(obj, opid)) orelse return null;
            const sub = try self.iterObj(obj);
            var grouper = Self.Grouped.init(self.gpa, opmarks.NoMarkIter(Row).init(sub), c);
            defer grouper.deinit();
            var index: usize = 0;
            while (try grouper.next()) |group| {
                var owned = group;
                defer owned.deinit(self.gpa);
                if (owned.end_pos > row.pos) {
                    return .{
                        .op = row,
                        .index = index,
                        .visible = try self.rowVisibleIn(row.pos, owned.ops.items, c),
                    };
                }
                index += owned.width(seq_type, self.text_encoding);
            }
            // **The walk ran out, so the index is the one below and the
            // visibility is the column's** — for the same reason the index is:
            // this arm is reached because every register *after* the row's own
            // yielded nothing, and that says nothing about the row. The one
            // case where it changes the answer is a text object whose tail is a
            // mark: the mark's own registers carry no width and are dropped
            // ([found_op.rs:61-63] keeps a row only when it is visible and is
            // not a mark), so a cursor on the **last value element** of a text
            // that ends inside a mark reaches here, and `false` would be a lie
            // about a row that is there.
            return .{
                .op = row,
                .index = index,
                .visible = try self.rowVisibleIn(row.pos, &.{}, c),
            };
        }

        /// Whether the row at `pos` is visible at `c`, as **both** arms of
        /// [`OpSet.seekListOpid`] define it, in one place so the two cannot
        /// drift apart again.
        ///
        /// With no clock that is [`index.visible`](index.zig)'s own answer for
        /// the row — the fact, not a filter. A mark row is in the document and
        /// has a position (`index.top` counts it and it holds no width,
        /// `index.rs:223-228`), and a row that is visible but lost its register
        /// to a later conflicting write is still there for a reader
        /// ([`Op.visible`](op.zig), `op.rs:1148-1156`).
        ///
        /// With a clock it is whether the walk's group for the row's register
        /// holds it, because `index.visible` says what a row looks like **now**
        /// and a scoped read needs what it looked like at the clock
        /// ([visible.zig]'s module doc, "The path a scoped read takes"). An
        /// empty group is the answer there, which is what the arm above hands
        /// it when the walk ran out before reaching the row's own register.
        fn rowVisibleIn(
            self: *Self,
            pos: usize,
            group: []const Op,
            c: ?Clock,
        ) (ReadOpError || InternalError)!bool {
            if (c == null) {
                return (try self.cols.index.visible.get(pos)) orelse
                    return error.Invariant;
            }
            for (group) |candidate| {
                if (candidate.pos == pos) return true;
            }
            return false;
        }

        /// The row of `obj` whose own id is `opid`, or null
        /// (`self.iter_obj(obj).find(|op| op.id == opid)`, `op_set.rs:885`).
        fn iterObjAndFind(self: *Self, obj: ObjId, opid: OpId) ReadOpError!?Op {
            var walk = try self.iterObj(obj);
            while (try walk.next()) |row| {
                if (row.id().eql(opid)) return row;
            }
            return null;
        }

        // ── Where a new row goes ────────────────────────────────────────

        /// Where a new row goes in the text object `obj` at `index`
        /// (`OpSet::query_insert_at_text`, `op_set.rs:463-492`).
        ///
        /// `index` is upstream's `NonZeroUsize` and this is a `usize` with the
        /// same precondition, checked by the caller
        /// ([`OpSet.queryInsertAt`] only calls it with `index > 0`,
        /// `op_set.rs:576`).
        ///
        /// Five steps in upstream's order, and the third is the one that is not
        /// obvious:
        ///
        /// 1. `index.text`'s prefix descent to `index - 1` (`:470-473`).
        /// 2. `elemidAt` from the row landed on, which expands to the whole
        ///    register and gives the element a new row would hang by (`:475-476`).
        /// 3. `scanForStickyMarks` over the zero-width entries that follow
        ///    (`:479-481`).
        /// 4. if that moved the position, the element is recomputed at the new
        ///    one — a mark end invalidated the candidate, so the element it hung
        ///    by is the one at the corrected position (`:480-482`).
        /// 5. the marks open at the answer, from the mark index (`:484-491`).
        ///
        /// Null when the descent finds nothing, which is an index past the end
        /// of the sequence.
        pub fn queryInsertAtText(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
        ) ResolveError!?QueryNth {
            std.debug.assert(index > 0);
            const range = try self.scopeToObj(obj);
            var text_col = try self.cols.index.text.prefixIterRange(range);
            const tx = try text_col.advancePrefix(@intCast(index - 1)) orelse return null;
            const at_index = std.math.cast(usize, tx.delta + @as(i64, tx.pv.value orelse 0)) orelse
                return error.Overflow;
            const found = (try self.elemidAt(tx.pos, range.end)) orelse return null;
            var elemid = found.elemid;
            var pos = found.last_pos;
            try text_col.advanceTo(pos);
            const pre_marks_pos = pos;
            pos = try self.scanForStickyMarks(text_col, pos) orelse pos;
            if (pos != pre_marks_pos) {
                // **Upstream's `?`, and the distinction is the whole line.**
                // `op_set.rs:481` is `elemid = self.elemid_at(pos, range.end)?.0`,
                // and the `?` returns `None` out of `query_insert_at_text`, not
                // a panic: `query_insert_at` then has no `Some(q)` and falls
                // through to the general walk at `:600-608`. Unwrapping here
                // instead turns "the corrected position names no element" into
                // a crash, and the walk that can reach such a position — one
                // whose `pos` has run to the end of the object — is exactly the
                // one `scanForStickyMarks` walks.
                elemid = ((try self.elemidAt(pos, range.end)) orelse return null).elemid;
            }
            var query = QueryNth{
                .marks = null,
                .pos = pos + 1,
                .index = at_index,
                .elemid = elemid,
            };
            errdefer query.deinit(gpa);
            query.marks = try self.markSetAt(gpa, pos, null);
            return query;
        }

        /// Where a new row goes in the list object `obj` at `index`
        /// (`OpSet::query_insert_at_list`, `op_set.rs:546-567`).
        ///
        /// `index.top`'s prefix descent to `index - 1` finds the row that *is*
        /// the element before the insertion point, and the walk starts there
        /// rather than at the object's start (`:554-556`) — the prefix descent
        /// has already accounted for everything before it, which is the `index -
        /// 1` that [`Self.Insert.init`]'s second argument is.
        pub fn queryInsertAtList(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
        ) ResolveError!?QueryNth {
            std.debug.assert(index > 0);
            const range = try self.scopeToObj(obj);
            var top = try self.cols.index.top.prefixIterRange(range);
            const tx = try top.advancePrefix(@intCast(index - 1)) orelse return null;
            var marks = insertmod.RichTextQueryState.init(gpa);
            defer marks.deinit();
            const open = try self.cols.index.mark.richTextAt(gpa, tx.pos, null);
            marks.map = open;
            var query = Self.Insert.init(
                gpa,
                try self.iterRange(.{ .start = tx.pos, .end = range.end }),
                index,
                .list,
                self.text_encoding,
                null,
                marks,
            );
            defer query.deinit();
            return query.resolve(index - 1) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => null,
            };
        }

        /// Where a new row goes in `obj` at `index`
        /// (`OpSet::query_insert_at`, `op_set.rs:569-609`).
        ///
        /// **Three paths, and the middle one is the one that is kept.** With no
        /// clock and a non-zero index, the prefix descent is tried first and
        /// only if it finds nothing does the general walk run (`:576-599`); with
        /// a clock, or at index zero, the walk runs directly (`:600-608`).
        ///
        /// **Upstream's `debug_assert_eq!` between the fast and the general
        /// answer is ported as a real check** (`:584-596`) — the two must agree,
        /// and the general answer is computed and compared. A disagreement is
        /// `error.Invariant`: it means the index and the rows disagree, which
        /// is a bug rather than a document, and a bug that would otherwise be
        /// visible only as a wrong insertion point in a debug build.
        ///
        /// The general walk is [`insertmod.InsertQuery`], and **`resolve` is
        /// called exactly once per query**: it consumes the walk and half-folds
        /// the mark state, and there is no way to un-fold it
        /// ([insert.zig](insert.zig) says so and says why). This function
        /// therefore builds a *second* query for the cross-check rather than
        /// re-asking the first, and frees both.
        ///
        /// `error.InvalidIndex` when the index is past the end of the sequence,
        /// which is the only way a caller learns that
        /// ([insert.zig](insert.zig), `insert.rs:136-137`).
        pub fn queryInsertAt(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
            seq_type: SequenceType,
            c: ?Clock,
        ) (ResolveError || InternalError)!QueryNth {
            if (c == null and index > 0) {
                const fast = if (seq_type == .list)
                    try self.queryInsertAtList(gpa, obj, index)
                else
                    try self.queryInsertAtText(gpa, obj, index);
                if (fast) |answer| {
                    // op_set.rs:584-596 — the general answer, computed and
                    // compared, never returned. **`answer` owns a `MarkSet`**
                    // (`insert.zig:203-206`), so the disagreement has to give
                    // it back before the error leaves; otherwise every
                    // cross-check failure leaks the fast path's mark set and
                    // `std.testing.allocator` aborts the whole run.
                    var owned = answer;
                    errdefer owned.deinit(gpa);
                    var slow = try self.queryInsertAtSlow(gpa, obj, index, seq_type, c);
                    defer slow.deinit(gpa);
                    if (!queryNthEqual(owned, slow)) return error.Invariant;
                    return owned;
                }
            }
            return self.queryInsertAtSlow(gpa, obj, index, seq_type, c);
        }

        /// The general answer: walk the whole object
        /// (`InsertQuery::new(..).resolve(0)`, `op_set.rs:600-608`).
        ///
        /// The walk is [`OpSet.iterObj`] — `scopeToObj` then `iterRange` — and
        /// the `0` is how much of the target the walk has already accounted
        /// for, which for the general path is nothing.
        fn queryInsertAtSlow(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
            seq_type: SequenceType,
            c: ?Clock,
        ) ResolveError!QueryNth {
            var query = Self.Insert.init(
                gpa,
                try self.iterObj(obj),
                index,
                seq_type,
                self.text_encoding,
                c,
                insertmod.RichTextQueryState.init(gpa),
            );
            defer query.deinit();
            return query.resolve(0);
        }

        /// The zero-width stretch a mark makes uninsertable-into
        /// (`OpSet::scan_for_sticky_marks`, `op_set.rs:494-544`).
        ///
        /// A mark's begin and end are two rows at the same position with width
        /// zero, and a row cannot be inserted between them: the mark would be
        /// split. This walk collects the candidate positions that are legal
        /// *because* of a mark — an **expanding begin**, or an end that does not
        /// expand forwards (`:529-534`) — and reports the last one, or the last
        /// one before a real element. The direction is the whole rule: a new
        /// row placed just after an expanding begin is *inside* the mark, and
        /// one placed just after a non-expanding end is *outside* it, so those
        /// are the two points the plain `last_pos + 1` gets wrong.
        ///
        /// Three arms of the run loop are load-bearing, and **the first one is
        /// an empty block** (`:504-541`): a run whose text-index value is
        /// `None` is not scanned at all, and `pos` still advances by the run's
        /// count (`:540`). **"No scan" and "the position advances" are two
        /// separate statements and upstream makes both**, which is why the
        /// block is empty rather than the advance: a port that scans such a run
        /// over-advances, and a port that does not advance it stalls.
        ///
        /// **What a `None` run is, is upstream's own comment's shorthand and
        /// the port states it fully**: upstream writes `None => (), // deleted
        /// chars` (`:506`), but the entry is `None` for *every* row that is not
        /// the element's winner — a deleted row, a shadowed row, and a
        /// zero-width mark anchor alike (`columns.rs:478-483`, `if top { Some(
        /// width) } else { None }`). **A mark's two anchors are in it**, and
        /// they are the rows this walk exists for: scanning them would end the
        /// walk at the first non-mark row it met (`:515-517`), which is a
        /// position *before* the marks rather than one inside them.
        ///
        /// **The `break` arm does not advance.** `_ => break` (`:538`) leaves
        /// the loop before `:540`, so the position a run of real width ends at
        /// is never moved past.
        ///
        /// Inside the scanning arm, two rules end a row's turn:
        ///
        /// * a **visible non-mark row** ends the scan and reports the last
        ///   candidate (`:515-517`). A zero-width text entry can be a mark row
        ///   or a real element such as an empty string, and only the mark rows
        ///   are transparent here — upstream spells that out at `:510-514` and
        ///   this is the same rule.
        /// * a **mark end** whose begin is in the candidate list truncates the
        ///   list at that begin and contributes nothing of its own
        ///   (`:520-528`): between a begin and its end there is nowhere in the
        ///   op set to insert.
        fn scanForStickyMarks(
            self: *Self,
            text_col: opcols.TextColumn.PrefixIter,
            start_pos: usize,
        ) (ParseError || ReadOpError)!?usize {
            var text_iter = text_col;
            var pos = start_pos;
            const end = text_iter.maxPos();
            var expand = try self.cols.expand.iterator();
            var marks = try self.cols.index.mark.iter();
            var found: std.ArrayList(markidx.MarkIdx) = .empty;
            defer found.deinit(self.gpa);
            var found_at: std.ArrayList(usize) = .empty;
            defer found_at.deinit(self.gpa);

            while (try text_iter.nextRun()) |run| {
                // :504-541 — **three arms, arm by arm.**
                //
                // `None => ()` (`:506`) — **an empty block, and the whole of
                // it is that the position advances without the scan running.**
                // A `None` entry is upstream's `// deleted chars`, but the rule
                // that writes it is wider (`columns.rs:478-483`,
                // `if top { Some(width) } else { None }`): **every row that is
                // not its register's winner is `None`, a mark's zero-width
                // anchor included**, and those are the rows this walk exists to
                // step over. Scanning one would let `:515-517` fire on the
                // first non-mark row met and answer the position *before* the
                // marks. Measured on upstream's own case (`test.rs:2618-2635`,
                // the third `splice_text` at index 2): folded into the
                // `Some(0)` arm the fast answer is `pos = 3` against
                // [`Self.queryInsertAtSlow`]'s `pos = 11`; honoured, both are
                // `11` and the inserted `'a'` lands between the link end and
                // the bold end, inside `bold` — which is what the reference's
                // own `dbg!` at `test.rs:2634` prints.
                //
                // `Some(0) => { .. }` (`:507-537`) — the per-row scan below.
                //
                // `_ => break` (`:538`) — any other width ends the walk, **and
                // leaves `pos` where it was**, because `break` is before the
                // `pos += run.count` at `:540`. So a run of real width is
                // never stepped over by this walk; the caller gets the plain
                // `last_pos + 1`.
                if (run.value.value) |w| {
                    if (w != 0) break; // :538 — the end of the stretch
                    var i: usize = 0;
                    while (i < run.count) : (i += 1) {
                        const p = pos + i + 1;
                        // :515-517 — only a mark row is transparent.
                        //
                        // **`is_some_and` is not an `if let`, and the two differ
                        // at the fall-through.** A row the op set has nothing at
                        // makes the condition *false* and the scan carries on to
                        // the shifts below (`:515`); only a row that is there and
                        // is not a mark ends the walk. Ported as an `if let` with
                        // an `else` that returns, this walk stops *at* a gap
                        // where upstream's steps over it.
                        //
                        // **That is a second defect and not a restatement of the
                        // one above.** The missing `None` arm makes the walk do
                        // too much and stop too early; this one makes it stop at
                        // all where the reference falls through. Both are one
                        // transcription habit — *an `Option` combinator read as
                        // control flow* — and the two differ only at the case
                        // where the condition is false and the code is meant to
                        // carry on. `is_some_and`, `is_none_or` and `or_else`
                        // all encode a decision and all read exactly like an
                        // `if let` with an early return until that case, so
                        // wherever one appears upstream the port's arm is
                        // "fall through", never "return".
                        if (try self.get(p)) |row| {
                            if (!row.isMark()) {
                                if (found_at.items.len == 0) return null;
                                return found_at.items[found_at.items.len - 1];
                            }
                        }
                        const e = (try expand.shiftNext(.{ .start = p, .end = end })) orelse return null;
                        if (try marks.shiftNext(.{ .start = p, .end = end })) |m| {
                            // :520-528 — a mark end whose own begin is already a
                            // candidate removes it and everything behind it: a
                            // point between a begin and its end is nowhere in the
                            // op set. **Only a matched end falls out here.** An
                            // end that matched nothing goes on to the rule below,
                            // and that fall-through is the only way
                            // `(End, false)` is ever reached — an end that is
                            // dropped unconditionally loses half the sticky-mark
                            // rule, which is the half that says a mark's end does
                            // not expand.
                            var matched = false;
                            if (m == .end) {
                                var j: usize = 0;
                                while (j < found.items.len) : (j += 1) {
                                    if (found.items[j].eql(markIdxStart(m.end))) {
                                        found.shrinkRetainingCapacity(j);
                                        found_at.shrinkRetainingCapacity(j);
                                        matched = true;
                                        break;
                                    }
                                }
                            }
                            if (matched) continue;
                            // :529-534 — `(MarkIdx::Start(_), true) |
                            // (MarkIdx::End(_), false)`: a begin that expands
                            // backwards, or an end that does not expand forwards,
                            // is an anchor a new row may not land on, so the point
                            // just after it is. **The predicate is the one
                            // [`InsertQuery.identifyValidInsertionSpot`] uses**
                            // (`insert.zig:530-540`) and the two must not drift:
                            // they are two walks over one rule, and
                            // `queryInsertAt`'s cross-check reports a disagreement
                            // between them as `error.Invariant`.
                            if (switch (m) {
                                .start => e,
                                .end => !e,
                            }) {
                                try found.append(self.gpa, m);
                                try found_at.append(self.gpa, p);
                            }
                        }
                    }
                }
                pos += run.count;
            }
            if (found_at.items.len == 0) return null;
            return found_at.items[found_at.items.len - 1];
        }

        // ── Marks ───────────────────────────────────────────────────────

        /// The mark set open at `pos`, or null when nothing is marked there
        /// (`mark_index.rich_text_at` folded through `MarkSet::from_query_state`,
        /// `op_set.rs:484-491`, `:1035-1038`).
        ///
        /// The two steps are the same everywhere they appear: the mark column
        /// gives the *open marks*, and folding those through a
        /// [`marksmod.MarkStateMachine`] gives the *set* — which is where a
        /// same-name mark above shadows one below and where a mark that
        /// resolves to `Null` is recognised as an unmark tombstone
        /// ([`insertmod.markSetFromQueryState`](insert.zig)). Upstream's
        /// `if let Some(set)` is this function's null.
        ///
        /// The caller owns the result.
        pub fn markSetAt(
            self: *const Self,
            gpa: Allocator,
            pos: usize,
            c: ?Clock,
        ) ResolveError!?MarkSet {
            const open = try self.cols.index.mark.richTextAt(gpa, pos, c);
            var state = insertmod.RichTextQueryState{ .gpa = gpa, .map = open, .block = null };
            defer state.deinit();
            return insertmod.markSetFromQueryState(gpa, &state);
        }

        /// Every mark in `obj`, coalesced into runs
        /// (`OpSet::calculate_marks_fast`, `op_set.rs:961-1024`).
        ///
        /// The walk is over the *mark index* and the *text index* together, and
        /// the way the two are kept in step is upstream's comment at `:971-974`:
        /// a sequence position is the exclusive prefix of the text index, mark
        /// boundaries arrive in ascending row order, and so one forward width
        /// iterator serves them all in O(1) amortised per boundary. Each
        /// boundary closes the run that was open and opens the one the mark
        /// index now describes (`:995-1013`).
        ///
        /// **Every position here is object-relative**, and both readings of the
        /// text index have to be kept in that one space: upstream's `base`
        /// (`:976`) is `widths.total()` — the *absolute* prefix of the whole
        /// text column at the object's first row — and it is what `:995` and
        /// `:1018` subtract, which is what reports a mark over the second half
        /// of an object at its own index rather than at its row. **This port's
        /// cursor reports absolute sums**, because
        /// [`PrefixIter.prefixIterRange`](../../src/hexane/column.zig) is
        /// upstream's `iter_range` (`prefix.rs:668-676`) and `advance_by`
        /// accumulates the widths it skips into `total` and never into `base`
        /// (`prefix.rs:903-907`, `column.zig:2181-2185`, `:2420-2433`). So
        /// `seq` subtracts `seq_base` here, the closing line subtracts it again,
        /// and the two are one subtraction applied to the two ends of one run.
        ///
        /// An unmark — a mark whose value is `Null` — is dropped on the way out
        /// (`:1023`): it is a tombstone, not a mark. The caller owns the list.
        ///
        /// **This is the indexed arm and it takes no clock**, because the mark
        /// index and the text index name the present and nothing else. It is
        /// reached through [`OpSet.calculateMarksAt`], which holds upstream's
        /// dispatch (`automerge.rs:1569-1597`, the arm at `:1585`), and that is
        /// how `Document.marks` in `doc.zig`, the `hydrate.zig` text fold and
        /// `read.zig` get it: each of them has a clock to hand and hands it, so
        /// the dispatch chooses the arm and the present is one of its answers.
        /// **The two callers left on this entry point are the two in
        /// `transact.zig`** (`transact.zig:2102`, `:2117`), which have no clock
        /// to dispatch on and want exactly this.
        pub fn calculateMarks(self: *Self, gpa: Allocator, obj: ObjId) MarksError![]Mark {
            if (!self.cols.index.mark.hasAnyMarks()) return &.{};
            const range = try self.scopeToObj(obj);
            // Upstream's `base` (`op_set.rs:976`), which is **the prefix of
            // the whole text column at the object's first row** — absolute,
            // because upstream's `iter_range` pays for the descent in
            // `advance_by` and so hands back a cursor whose sums are absolute
            // (`hexane/src/prefix.rs:669-676`, `:903-907`). Both of the two
            // places that subtract it subtract *this* number.
            const seq_base = try self.cols.index.text.getPrefix(range.start);
            var acc = marksmod.MarkAccumulator.init(gpa);
            defer acc.deinit();
            var widths = try self.cols.index.text.prefixIterRange(range);
            var widths_at = range.start;
            var state = insertmod.RichTextQueryState.init(gpa);
            defer state.deinit();
            var seg: ?MarkSegment = null;
            defer if (seg) |*open| open.deinit();
            var mark_rows = try self.cols.index.mark.iterRange(range);
            var pos = range.start;
            while (try mark_rows.nextRun()) |run| {
                const idx = run.value orelse {
                    pos += run.count;
                    continue;
                };
                var n: usize = 0;
                while (n < run.count) : (n += 1) {
                    const seek = try widths.deltaNth(pos - widths_at) orelse
                        return error.InvalidValue;
                    widths_at = pos + 1;
                    // `:995` — `(seek.pv.prefix() - base) as usize`. **The
                    // subtraction is load-bearing**, because `base` is not zero
                    // for an object that does not start at the column's first
                    // row: the run's *length* is right either way, so the whole
                    // answer is displaced by everything the text column holds
                    // before the object, and every caller sees marks at their
                    // rows.
                    const rel = std.math.sub(i64, seek.pv.prefix(), seq_base) catch
                        return error.Overflow;
                    const seq = std.math.cast(usize, rel) orelse return error.Overflow;
                    if (seg) |open| {
                        if (seq > open.start) try acc.add(open.start, seq - open.start, &open.set);
                    }
                    if (seg) |*open| open.deinit();
                    seg = null;
                    switch (idx) {
                        .start => |begin| {
                            if (self.cols.index.mark.markData(begin)) |data| {
                                try state.map.put(gpa, begin, data);
                            }
                        },
                        .end => |begin| {
                            _ = state.map.remove(begin);
                        },
                    }
                    if (try insertmod.markSetFromQueryState(gpa, &state)) |set| {
                        seg = .{ .start = seq, .set = set };
                    }
                    pos += 1;
                }
            }
            if (seg) |open| {
                // Upstream's `text.get_prefix(range.end) - base`
                // (`op_set.rs:1018`), closing a mark that is still open on the
                // object's last row. **`getPrefix` is the whole column's
                // prefix and `seq_base` is the object's first row's**, so the
                // difference is the object's own width — the same space every
                // `seq` above is in. Subtracting anything else here — the walk's
                // own zero included — reports the mark running on past the end
                // of the object by everything the column holds before it.
                const end_i = try self.cols.index.text.getPrefix(range.end);
                const span = std.math.sub(i64, end_i, seq_base) catch
                    return error.Overflow;
                const end = std.math.cast(usize, span) orelse return error.Overflow;
                if (end > open.start) try acc.add(open.start, end - open.start, &open.set);
            }
            return marksFromAccumulator(gpa, &acc);
        }

        /// Every mark in `obj` as the clock `c` sees it, coalesced into runs
        /// (`Automerge::calculate_marks`,
        /// [`automerge.rs`:1569-1596](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        ///
        /// **Every mark read goes through this, because the dispatch below is
        /// the whole of upstream's `calculate_marks`:**
        ///
        /// | the read | how |
        /// |---|---|
        /// | **no clock** and `obj` is a text | [`OpSet.calculateMarks`], the two indexes |
        /// | anything else | [`OpSet.calculateMarksSlow`], the object's rows |
        ///
        /// and the test is `clock.is_none() && seq_type == SequenceType::Text`
        /// ([`automerge.rs`:1585](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        /// **It is the rule and not an optimisation**: the mark index names the
        /// present and nothing else, so the walk is the only arm that can answer
        /// a historical read. Upstream compares the two answers under
        /// `slow_path_assertions` (`:1587-1591`), which is the port's
        /// [`check_slow_paths`](op_set.zig).
        ///
        /// **A non-sequence is the empty list and not an error**
        /// ([`automerge.rs`:1576-1580](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
        /// which is upstream's `let Some(seq_type) = .. else { return Ok(Vec::new()) }`
        /// and its own comment that this should be an error and is kept for
        /// compatibility.
        ///
        /// **The clock is borrowed, not owned**, and that is already the rule
        /// rather than a new requirement. The walk below stores it by value
        /// ([`top_op.TopOps`](top_op.zig)'s field is a `?Clock`) and frees
        /// nothing, and a [`Clock`](clock.zig) is a `{slots, len, gpa}` whose
        /// buffer belongs to whoever built it — so a caller may hand this a
        /// clock that outlives the call, which is what
        /// [`Document.readScope`](doc.zig)'s cached one is for.
        ///
        /// The caller owns the list.
        pub fn calculateMarksAt(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            c: ?Clock,
        ) TopError![]Mark {
            // `let obj = self.exid_to_obj(..)?` (`:1574`) is the caller's, and
            // this is the port's one total answer to what it left: an object the
            // index does not know is not a sequence.
            const typ = self.objectType(obj) orelse return &.{};
            const seq = typ.asSequenceType() orelse return &.{}; // `:1576-1580`
            // `:1582-1594`, and **not** `c == null` alone: a list has no text
            // index widths to measure against (`:1582-1584`).
            if (c == null and typ == .text) {
                const found = try self.calculateMarks(gpa, obj);
                // **The cross-check, and the one this function's own doc has
                // been claiming since it was written** (`automerge.rs:1587-1591`
                // — upstream's `assert_eq!` under `slow_path_assertions`).
                //
                // **The two arms are two structures computing the same thing
                // by different rules** — this one measures an object against
                // the mark index and the text index, [`calculateMarksSlow`]
                // walks its winners and counts widths — and this is the only
                // place they can be made to say so. It is the check that would
                // have caught a `- base` dropped at [`calculateMarks`]'s `:995`:
                // the walk answered `bold[0, 1) bold[6, 10)` on the very
                // documents the index arm answered `[1, 2) [7, 11)` on, and one
                // comparison says so with no diagnosis at all.
                //
                // **`errdefer`, and it is registered before the compare rather
                // than released after it.** The answer being checked is owned,
                // and a cross-check that reported the fault by leaking the
                // value it was checking is the defect this same file already
                // records at `seekOpsByIndex` (`:2905-2913`).
                errdefer gpa.free(found);
                if (check_slow_paths) {
                    const slow = try self.calculateMarksSlow(gpa, obj, seq, null);
                    defer gpa.free(slow);
                    // The same three lines as `getMarks`'s arm, and for the
                    // same reason: a check that cannot say what it caught is a
                    // check nobody can act on.
                    if (!marksEqual(found, slow)) {
                        std.debug.print("calculateMarks: the two arms disagree\n", .{});
                        markRunLines(found, "indexed");
                        markRunLines(slow, "walked");
                        return error.Invariant;
                    }
                }
                return found;
            }
            return self.calculateMarksSlow(gpa, obj, seq, c); // `:1595`
        }

        /// Every mark in `obj` as the clock `c` sees it, walked row by row
        /// (`Automerge::calculate_marks_slow`,
        /// [`automerge.rs`:1598-1631](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        ///
        /// **A mark run is a property of rows, and this is the walk over rows.**
        /// The indexed arm measures an object against two *indexes*; this one
        /// walks the object's winners and folds the mark rows as they go past,
        /// which is the only way to answer for a clock the index does not
        /// describe.
        ///
        /// **Composing the scoped answer out of
        /// [`iter::Spans`](../../src/iter/spans.zig) was tried and does not
        /// hold**, and the measurement is why: a scoped `Spans` walk does not
        /// filter the *mark rows* by the clock the way this loop does, so the
        /// runs it folded disagreed with the indexed ones on the same state —
        /// `bold [0, 6)` where `bold [0, 3)` was right. The two walks fold the
        /// same accumulator and so look interchangeable, and they are not: a
        /// character is not a row.
        ///
        /// The loop is upstream's, in its order and under its names. `index` is
        /// the sequence position the walk stands at, `last` is the set that was
        /// open over the run being measured, `mark_index` is where that run
        /// began and `mark_len` how far it has been measured (`:1606-1610`).
        /// A row that is not a mark row is where the comparison happens
        /// (`:1614`): **when the set has changed since the last row, the run
        /// that was open goes into the accumulator at the length it reached and
        /// a new one starts at `index`** (`:1615-1622`). The trailing `match`
        /// is `:1626-1629` and the drain is `:1630`.
        ///
        /// **The mark rows are folded and skipped** rather than returned, which
        /// is [`opmarks.MarkIter`](marks.zig)'s whole `next`
        /// (`op_set2/op_set/marks.rs:26-42`) and not this loop's own decision —
        /// a mark row carries no element and no width, so folding it here is
        /// what lets one loop serve both kinds of row. The fold is spelled out
        /// here rather than reached through that adapter for the reason
        /// [`OpSet.markSetAtIndex`] gives: its `next` is declared in
        /// [`opmarks.MarkError`](marks.zig) and a winner walk answers in
        /// [`TopError`], which also carries [`InternalError`].
        ///
        /// `seq` is the object's sequence type and the caller reads it, because
        /// [`OpBuilder::width`](op.zig) measures a list element as one and a
        /// text element as its width under the encoding (`op.rs:204-210`) —
        /// which is upstream's stated reason the indexed arm is text-only
        /// ([`automerge.rs`:1582-1584](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
        /// "the text index carries text widths, so lists still take the walk
        /// below").
        ///
        /// The caller owns the list.
        pub fn calculateMarksSlow(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            seq: SequenceType,
            c: ?Clock,
        ) TopError![]Mark {
            var winners = try self.topOps(obj, c);
            defer winners.deinit(self.gpa);
            var state = marksmod.MarkStateMachine.init(gpa);
            defer state.deinit();
            var acc = marksmod.MarkAccumulator.init(gpa);
            defer acc.deinit();
            // Upstream's `last_marks: Option<Arc<MarkSet>>` (`:1608`), which is
            // an `Arc` clone and here is a copy: the port's `MarkSet` is owned
            // and the machine writes into its own in place, so the set as it
            // stood a moment ago has to be kept rather than aliased. The copy
            // costs what upstream's refcount bump costs and no more, which is
            // the same trade `withoutUnmarksCopy` below makes.
            var last: ?MarkSet = null;
            defer if (last) |*open| open.deinit();
            var index: usize = 0;
            var mark_index: usize = 0;
            var mark_len: usize = 0;
            while (try winners.next()) |row| {
                if (row.action() == .mark) {
                    // `marks.rs:32-36`: a mark row with a name is a begin and
                    // one without is the end of the mark its own id names, and
                    // which is which is decided by the name column alone.
                    if (row.markName()) |name| {
                        _ = try state.markBegin(row.id(), .{
                            .name = name,
                            .value = row.value(),
                        });
                    } else {
                        _ = try state.markEnd(row.id());
                    }
                    continue;
                }
                // `let marks = top_ops.get_marks()` (`:1612`) — the set as it
                // stands after every mark row this row was preceded by, which
                // is `MarkIter`'s fold having already run.
                const now = state.current();
                // `last_marks.as_ref() != marks` (`:1614`), which upstream gets
                // from `Arc<MarkSet>: PartialEq`. Both nulls compare equal, so
                // an unmarked stretch of the object is one run and not a run
                // per row.
                if (!markSetOptEql(if (last) |*open| open else null, now)) {
                    // `:1615-1618`, then `last_marks = marks.cloned()`
                    // (`:1619`) — and the two halves of that are one statement
                    // here: the run that was open is added and the set that
                    // measured it is freed, because the copy below is what
                    // measures the next run.
                    if (last) |*open| {
                        if (mark_len > 0) try acc.add(mark_index, mark_len, open);
                        open.deinit();
                        last = null;
                    }
                    last = if (now) |set| try MarkSet.fromPairs(gpa, set.entries.items) else null;
                    mark_index = index;
                    mark_len = 0;
                }
                // `let len = o.width(seq_type, self.text_encoding())` (`:1613`).
                const w = row.width(seq, self.text_encoding);
                // **The cast is total**: a width is one, a text element's width
                // under the encoding, or zero for a mark (`op.zig:1844-1850`),
                // and no mark row reaches it.
                std.debug.assert(w >= 0);
                mark_len += @intCast(w);
                index += @intCast(w);
            }
            // `:1626-1629`, closing the run the walk ended on.
            if (last) |*open| {
                if (mark_len > 0) try acc.add(mark_index, mark_len, open);
            }
            return marksFromAccumulator(gpa, &acc); // `:1630`
        }

        /// The mark set open at text index `index` in `obj`
        /// (`OpSet::get_marks_fast`, `op_set.rs:1026-1039`).
        ///
        /// One prefix descent on `index.text` to turn a *text index* into a
        /// *row*, then [`OpSet.markSetAt`]. An index past the end is an empty
        /// set, which is upstream's `return MarkSet::default()`
        /// (`:1032-1034`) and not an error: a reader asking past the end of a
        /// text object gets no marks rather than a failure.
        ///
        /// The caller owns the result.
        ///
        /// **`ResolveError` widened by one error**, and the one is
        /// [`InternalError`](../../error.zig)'s `Invariant`: this function
        /// now reports a disagreement between itself and
        /// [`markSetAtIndex`](op_set.zig) and needs somewhere to put it. **Its
        /// one production caller already carries it** —
        /// [`read.zig`](../../src/read.zig)'s `ReadError` is
        /// `ReadOpError || Error || InternalError` (`read.zig:148`) — so the
        /// widening stops here and reaches no file this slice does not own.
        pub fn getMarks(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
        ) (ResolveError || err.InternalError)!MarkSet {
            if (!self.cols.index.mark.hasAnyMarks()) return MarkSet.init(gpa);
            const range = try self.scopeToObj(obj);
            var widths = try self.cols.index.text.prefixIterRange(range);
            // All three of the arms upstream writes, gathered into one
            // `found`, because the cross-check below has to see the answer
            // whichever of them produced it — **and a check that only runs on
            // one of three exits is a check that cannot see two thirds of what
            // it is checking** (`:1032-1034` for the first).
            var found: MarkSet = blk: {
                const seek = (try widths.advancePrefix(@intCast(index))) orelse
                    break :blk MarkSet.init(gpa);
                const set = try self.markSetAt(gpa, seek.pos, null);
                break :blk set orelse MarkSet.init(gpa);
            };
            // **The cross-check, and the one [`markSetAtIndex`]'s own doc has
            // been claiming since it was written** (`automerge.rs:1939-1943`).
            // **`.text` and not `obj`'s own sequence type**, because the descent
            // above is a descent on `index.text` and the two answers are only
            // comparable when the walk measures the same units.
            if (check_slow_paths) {
                var slow = try self.markSetAtIndex(gpa, obj, index, .text, null);
                defer slow.deinit();
                if (!MarkSet.eql(&found, &slow)) {
                    // **The three lines that turn `Invariant` into a
                    // diagnosis.** Without them this check reports a fault and
                    // a stack of twenty identical `leb128.zig:139` frames,
                    // which says that two mark sets differ and nothing about
                    // which, or at which index — and a check that cannot say
                    // what it caught is a check nobody can act on.
                    std.debug.print("getMarks: index {d} disagrees\n", .{index});
                    markSetLines(&found, "indexed");
                    markSetLines(&slow, "walked");
                    // **`found` is freed here and not left to an `errdefer`**:
                    // the one above the compare cannot be reached from an
                    // `if (!...)` arm, and a check that reports the fault by
                    // leaking the value it was checking is what
                    // `seekOpsByIndex` records at `:2905-2913`.
                    found.deinit();
                    return error.Invariant;
                }
            }
            return found;
        }

        /// The mark set open at `index` in `obj`, found by walking the
        /// object's winners and folding the mark rows as they go past
        /// (`Automerge::get_marks_slow`, `automerge.rs:1950-1971`).
        ///
        /// **Upstream's other arm, and the one the index cannot serve.**
        /// `get_marks_for` takes [`OpSet.getMarks`](op_set.zig) only when there
        /// is no clock *and* the object is text
        /// (`clock.is_none() && obj.typ == Text`, `automerge.rs:1937`), and
        /// otherwise comes here; the `slow_path_assertions` feature compares
        /// the two answers (`:1939-1943`), which is this port's
        /// [`check_slow_paths`](op_set.zig).
        ///
        /// `seq` is the object's sequence type and is **not** checked here:
        /// upstream reads it off the object and refuses a non-sequence itself
        /// (`let Some(seq_type) = .. else { return MarkSet::default() }`,
        /// `:1956-1958`), so the caller makes that decision and this answers a
        /// question about a sequence.
        ///
        /// **The walk stops on the row that carries `index`, and that is what
        /// `pos > index` means**: `pos` is the prefix sum of the widths it has
        /// passed (`:1961-1962`), so the first row whose exclusive end is past
        /// `index` is the element at `index`. A mark row is folded and skipped
        /// — upstream's `MarkIter::next` (`marks.rs:26-42`), which is the loop
        /// below — and a mark row's width in text is zero anyway
        /// (`op.rs:204-207`), so the row the answer comes from is always an
        /// element and never a zero-width transient between two.
        ///
        /// An index past the end walks off the object and answers the empty
        /// set, which is upstream's trailing `MarkSet::default()` (`:1970`) and
        /// not an error.
        ///
        /// The caller owns the result.
        pub fn markSetAtIndex(
            self: *Self,
            gpa: Allocator,
            obj: ObjId,
            index: usize,
            seq: SequenceType,
            c: ?Clock,
        ) TopError!MarkSet {
            var winners = try self.topOps(obj, c);
            defer winners.deinit(self.gpa);
            // **`MarkIter` itself, and not this loop's author.** The fold is
            // the same [`MarkStateMachine`](../../src/marks.zig) either way
            // (`marks.rs:16-21`), and `op_query.rs:15`'s `get_marks` is
            // `self.marks.current()` (`marks.rs:46-48`) — both of which are
            // what the two calls below are. What could not be reused is the
            // *wrapper*: `opmarks.MarkIter` declares its `next` in
            // `QueryError` (`marks.rs:120`), and a winner walk answers in
            // `TopError`, which carries [`InternalError`](../error.zig) as
            // well — so reaching the fold through it would mean widening a
            // published error set every query term in the crate is checked
            // against.
            var state = marksmod.MarkStateMachine.init(gpa);
            defer state.deinit();
            var pos: usize = 0;
            while (try winners.next()) |row| {
                // **The discriminator, and it is one line.** The two
                // cross-checks report this walk answering `<empty>` where the
                // indexed arm answers one entry, on rows the fixture helpers
                // build and not on rows the public API builds. **Either the
                // walk cannot classify the fixture's mark row, or the fixture
                // builds one it cannot classify** — and those are the same
                // observation until this says which arm the row arrives in.
                if (check_slow_paths) {
                    std.debug.print(
                        "  markSetAtIndex: action={s} name={?s}\n",
                        .{ @tagName(row.action()), row.markName() },
                    );
                }
                // `marks.rs:32-36`: a mark row with a name is a begin and one
                // without is the end of the mark its own id names, and which is
                // which is decided by the name column alone.
                if (row.action() == .mark) {
                    if (row.markName()) |name| {
                        _ = try state.markBegin(row.id(), .{
                            .name = name,
                            .value = row.value(),
                        });
                    } else {
                        _ = try state.markEnd(row.id());
                    }
                    continue;
                }
                const w = row.width(seq, self.text_encoding);
                // **The cast is total**: a width is one, a text element's
                // width, or zero for a mark (`op.zig:1844-1850`), and no mark
                // row reaches it.
                std.debug.assert(w >= 0);
                pos += @intCast(w);
                if (pos > index) {
                    // `Some(arc) => arc.as_ref().clone().without_unmarks()`
                    // (`:1964-1966`), and the clone is upstream's own: the set
                    // belongs to the fold, which writes it again on the next
                    // row. `None => MarkSet::default()` is the `:1966` arm,
                    // and so is an empty fold anywhere else — which is what
                    // `current()` answers for nothing open.
                    const open = state.current() orelse return MarkSet.init(gpa);
                    return withoutUnmarksCopy(gpa, open);
                }
            }
            return MarkSet.init(gpa);
        }

        // ── Text ────────────────────────────────────────────────────────

        /// `obj` as text (`OpSet::text`, `op_set.rs:1041-1052`).
        ///
        /// Only the action and the value are read: the [`Self.TopActionValues`]
        /// skipper jumps between winners without materialising full rows
        /// (`:1042-1043`), and a conflicted position therefore contributes one
        /// character rather than two. A mark contributes nothing and anything
        /// that is not a string contributes U+FFFC, the replacement character
        /// (`:1046-1050`).
        ///
        /// The caller owns the bytes.
        pub fn text(self: *Self, gpa: Allocator, obj: ObjId, c: ?Clock) TopError![]u8 {
            const range = try self.scopeToObj(obj);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var rows = try self.actionValueTopIter(range, c);
            while (try rows.next()) |item| {
                switch (item.action) {
                    .set => switch (item.value) {
                        .str => |s| try out.appendSlice(gpa, s),
                        else => try out.appendSlice(gpa, "\u{fffc}"),
                    },
                    .mark => {},
                    else => try out.appendSlice(gpa, "\u{fffc}"),
                }
            }
            return out.toOwnedSlice(gpa);
        }

        /// How long `obj` is, in `text_encoding` (`OpSet::seq_length`,
        /// `op_set.rs:429-461`).
        ///
        /// Three arms, and the text one is the only one that is not a count of
        /// something:
        ///
        /// * **text, no clock** — the text index's prefix sum over the object
        ///   (`:439-440`), which is a single lookup. This is why a text object
        ///   carries a width index and a list does not.
        /// * **text, with a clock** — a walk, because a past state's widths are
        ///   not in the index (`:441-449`). A string's width under the encoding,
        ///   zero for a mark, and U+FFFC's width for anything else.
        /// * **list** — the number of *distinct* `insert` prefix positions among
        ///   the visible rows (`:451-456`). The `dedup` is the point: a run of
        ///   rows that all carry `false` has the same prefix total as the row
        ///   before it, so the distinct totals are exactly the elements.
        /// * **anything else** — the same count over `key_str` (`:457-459`).
        ///
        /// An object the index does not know is treated as a map
        /// (`unwrap_or(ObjType::Map)`, `:437`).
        pub fn seqLength(
            self: *Self,
            obj: ObjId,
            text_encoding: TextEncoding,
            c: ?Clock,
        ) (ParseError || ReadOpError)!usize {
            const range = try self.scopeToObj(obj);
            const typ = self.objectType(obj) orelse .map;
            if (typ == .text) {
                if (c == null) {
                    const sum = try self.cols.index.text.sumRange(range);
                    return std.math.cast(usize, sum) orelse error.Overflow;
                }
                var total: usize = 0;
                var rows = try self.actionValueIter(range, c);
                while (try rows.next()) |item| {
                    switch (item.action) {
                        .set => switch (item.value) {
                            .str => |s| total += text_encoding.width(s),
                            else => total += text_encoding.width("\u{fffc}"),
                        },
                        .mark => {},
                        else => total += text_encoding.width("\u{fffc}"),
                    }
                }
                return total;
            }
            var visible_rows = try Self.Visible.init(&self.cols, c, range, self.succ_scratch.items);
            var last: ?i64 = null;
            var count: usize = 0;
            if (typ == .list) {
                var acc = try self.cols.insert.prefixIterRange(range);
                var at = range.start;
                while (try visible_rows.next()) |skip| {
                    at += skip;
                    const pv = (try acc.seekTo(at)) orelse break;
                    if (last == null or last.? != pv.total()) {
                        count += 1;
                        last = pv.total();
                    }
                    at += 1;
                }
                return count;
            }
            var key_col = try self.cols.key_str.iterRange(range);
            var at = range.start;
            while (try visible_rows.next()) |skip| {
                at += skip;
                const k = (try key_col.seekTo(at)) orelse break;
                const k_total: i64 = @intCast(k orelse 0);
                if (last == null or last.? != k_total) {
                    count += 1;
                    last = k_total;
                }
                at += 1;
            }
            return count;
        }

        /// The action and the value of each visible row of `rows`
        /// (`OpSet::action_value_iter`, `op_set.rs:934-948`).
        ///
        /// `SkipIter(ActionValueIter, VisIter)`, which is
        /// [`Self.ActionValues`]. The action and the value are read as one pair
        /// because a caller that wants one almost always wants the other, and
        /// reading them from two walks would mean two position counters that
        /// have to be kept in step.
        pub fn actionValueIter(
            self: *Self,
            rows: RowRange,
            c: ?Clock,
        ) ReadOpError!Self.ActionValues {
            const window = column.clampRange(rows, self.cols.len());
            return Self.ActionValues.init(
                opiter.ActionValueIter.init(
                    opiter.ActionIter.init(try self.cols.action.iterRange(window)),
                    try self.valueIterRange(window),
                ),
                try Self.Visible.init(&self.cols, c, window, self.succ_scratch.items),
            );
        }

        /// The action and the value of each register's winner in `rows`
        /// (`OpSet::action_value_top_iter`, `op_set.rs:949-959`).
        ///
        /// `SkipIter(ActionValueIter, TopIter)`, which is
        /// [`Self.TopActionValues`]. One item per element, so a conflicted text
        /// position contributes a single character — which is the whole reason
        /// this exists separately from [`OpSet.actionValueIter`]
        /// (`:946-948`).
        pub fn actionValueTopIter(
            self: *Self,
            rows: RowRange,
            c: ?Clock,
        ) TopError!Self.TopActionValues {
            const window = column.clampRange(rows, self.cols.len());
            return Self.TopActionValues.init(
                opiter.ActionValueIter.init(
                    opiter.ActionIter.init(try self.cols.action.iterRange(window)),
                    try self.valueIterRange(window),
                ),
                try Self.Top.init(&self.cols, c, window, self.succ_scratch.items),
            );
        }

        // ── The two invariant checkers ──────────────────────────────────

        /// Whether every row follows the row-order invariant
        /// (`OpSet::validate_op_order`, `op_set.rs:167-175`).
        ///
        /// [`opmod.Op.step`] over [`OpSet.iter`], from
        /// [`opmod.OpStepper.initial`] — the root object, the empty map key and
        /// the root op id, which is a state every first row passes
        /// ([op.zig](op.zig) `OpStepper`). **This is the gate for the whole
        /// port**: upstream calls it from exactly one place in the crate, the
        /// `debug_assert!` at the end of every apply ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)),
        /// and the port runs it always. **The load path does not call it** —
        /// it asserts `validate_top_index` instead
        /// ([`storage/document.rs:351`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)) —
        /// so upstream never checks the row order of a document it read from
        /// bytes, only of one it just applied to. That is a gap, and it is why
        /// this file's comparison checks it on both sides rather than only the
        /// half upstream reaches.
        ///
        /// It answers `false` rather than asserting, so it can be *tested* —
        /// and the test that matters is the one that makes it answer `false`.
        pub fn validateOpOrder(self: *Self) ReadOpError!bool {
            var stepper = opmod.OpStepper.initial();
            var walk = try self.iter();
            while (try walk.next()) |row| {
                if (!row.step(&stepper)) return false;
            }
            return true;
        }

        /// Whether the `top` and `visible` index columns agree with the rows
        /// and with each other (`OpSet::validate_top_index`, `op_set.rs:177-214`).
        ///
        /// Null when every check passes, and a [`TopIndexFault`] naming the one
        /// that did not when one does. The per-group rule is the one that says
        /// something: for every `(obj, elemid_or_key)` group, the **first**
        /// winner is the **last** visible row (`:195-210`). A register has
        /// exactly one winner and it is the row a reader sees, so the first
        /// `top` and the last `visible` in a group have to be the same row — and
        /// a group with two winners, or with a visible row past the winner, is a
        /// document that reads back as something other than what it is.
        ///
        /// The check is made *per group* because that is where it is true: the
        /// rows are grouped by `elemid_or_key`, and a group's boundary is a
        /// change in the object or in the register key.
        ///
        /// # When this fires, the rows are usually what is wrong, and here is
        /// the worked case
        ///
        /// The two halves of the port — `Columns::splice` on the write path
        /// and [`OpSet.rebuildIndex`] on the load path — do not compute `top`
        /// by the same rule and are not supposed to. Upstream's splice writes
        /// whatever the op it is handed says (`columns.rs:478-482`, and the
        /// only `OpLike::top` a change op has is `!conflicted && visible`,
        /// `op.rs:660-662` — `conflicted` is set at construction and never
        /// again, `op.rs:55`), while the rebuild marks the **last** row of
        /// each register that has no successors (`IndexBuilder::flush`,
        /// `op_set2/op_set/index.rs:159-176`). The two agree exactly when
        /// every register ends up with one visible row.
        ///
        /// So a `group_mismatch` means one register has two visible rows, and
        /// the question is **which structure put them there**. Measured on
        /// 2026-10-01, on a `group_mismatch { at = 11, first_top = 9,
        /// last_vis = 10 }` from five `doc.test` round-trip tests: the
        /// rebuilt side was already right (row 9 `top = false`, row 10
        /// `top = true`), and the **rows** were the defect. The two rows
        /// were the `"hi"` insert and the `bold` mark over it, and the mark
        /// carried `insert = false`, so `Op::elemid_or_key` returned its
        /// predecessor element instead of its own (`op.rs:1040-1046`) and the
        /// mark landed **inside the register of the insert it annotates**.
        /// Upstream cannot write that: `TxOp::insert` hard-codes
        /// `insert: true` for every insert including a mark
        /// (`op.rs:330-357`), and the one constructor that pairs
        /// `insert: false` with a `Seq` key — `TxOp::list` (`op.rs:261-292`)
        /// — is reached only from `local_list_op` (`inner.rs:495-558`) and is
        /// never given a mark.
        ///
        /// **So a `group_mismatch` on a locally written document is a
        /// question about the rows first**, and only a `group_mismatch` that
        /// survives on the *reloaded* side is a question about the index.
        /// Both halves run over both sides ([`OpSet.debugDiff`]), which is
        /// what makes the distinction answerable rather than guessed at.
        pub fn validateTopIndex(self: *Self) (ParseError || ReadOpError)!?TopIndexFault {
            const top_len = self.cols.index.top.len();
            const vis_len = self.cols.index.visible.len();
            if (top_len != vis_len) {
                return .{ .top_visible_len = .{ .top = top_len, .visible = vis_len } };
            }
            if (top_len != self.len()) {
                return .{ .top_row_len = .{ .index = top_len, .rows = self.len() } };
            }
            var top = try self.cols.index.top.iterator();
            var visible_rows = try self.cols.index.visible.iterator();
            var walk = try self.iter();
            var last: ?Group = null;
            var first_top: ?usize = null;
            var last_vis: ?usize = null;
            var at: usize = 0;
            while (try top.next()) |t| {
                const v = (try visible_rows.next()) orelse break;
                const row = (try walk.next()) orelse break;
                const here: Group = .{ .obj = row.objId(), .key = row.elemidOrKey() };
                if (last) |prev| {
                    if (!prev.obj.eql(here.obj) or !prev.key.eql(here.key)) {
                        if (!eqlOpt(first_top, last_vis)) {
                            return .{ .group_mismatch = .{
                                .at = at,
                                .first_top = first_top,
                                .last_vis = last_vis,
                            } };
                        }
                        first_top = null;
                        last_vis = null;
                    }
                }
                last = here;
                if (t) {
                    // op_set.rs:202-207
                    if (!v) return .{ .top_not_visible = at };
                    if (first_top == null) first_top = at;
                }
                if (v) last_vis = at;
                at += 1;
            }
            // op_set.rs:212 — the last group, checked after the loop.
            if (!eqlOpt(first_top, last_vis)) {
                return .{ .final_group_mismatch = .{
                    .at = at,
                    .first_top = first_top,
                    .last_vis = last_vis,
                } };
            }
            return null;
        }

        /// The layout of an op column block, checked, with the index columns
        /// dropped (`OpSet::validate`, `op_set.rs:160-165`).
        pub fn validate(cols: RawColumns) ParseError!RawColumns {
            return Ops.validate(std.testing.allocator, cols);
        }
    };
}

// ── The fast-versus-slow flag ──────────────────────────────────────────────

/// Whether the fast paths cross-check themselves against the slow ones
/// (upstream's `slow_path_assertions` feature, `plan.md` §2).
///
/// Upstream gates two of the four cross-checks behind the feature
/// (`op_set.rs:645-649`, `:1088-1089`) and leaves the other two as plain
/// `debug_assert_eq!`s (`:584-596`, `:846`, `:1107`). This is the port's
/// spelling of the gate for the two upstream gated.
///
/// **The value is `-Dslow-path`, not a literal.** It was `= false` until the
/// option existed, and a `const` next to the checks it gates is a constant
/// with a new name and no new behaviour: `zig build slow-path` turns both
/// this cross-check and [`SlabBTree.assertSound`](hexane/btree.zig) on, and
/// a build with no `-Dslow-path` leaves both compiled out, which is
/// upstream's default feature set.
///
/// **The other two are not behind it.** They are cheap and upstream has them
/// as `debug_assert_eq!`s, so a mismatch is a bug that would otherwise surface
/// only in a debug build: [`OpSet.queryInsertAt`](op_set.zig) against the
/// general walk, and [`OpSet.seekListOpid`](op_set.zig) and
/// [`OpSet.findOpByIdAndVis`](op_set.zig) between their two paths. All three
/// report `error.Invariant`.
///
/// A test compares the fast and the slow answer for
/// [`OpSet.seekOpsByIndex`](op_set.zig) directly, so the check is exercised
/// whether or not this is set.
pub const check_slow_paths: bool = build_options.check_slow_paths;

/// What a value search can raise. [`btree.TreeError`] is not a subset of
/// [`ParseError`] — it has `InvalidIndex`, which `ParseError` does not — so
/// the one method that descends a B-tree names both.
pub const SearchError = ParseError || btree.TreeError;

// ── Equality helpers, for the cross-checks and the checkers ────────────────

/// Whether two optional positions are the same, with null equal to null —
/// which is what `assert_eq!(Option<usize>, Option<usize>)` means.
fn eqlOpt(a: ?usize, b: ?usize) bool {
    if (a == null) return b == null;
    return b != null and a.? == b.?;
}

/// Whether the two answers agree (`find_op_by_id_and_vis`'s
/// `debug_assert_eq!`, `op_set.rs:1107`).
fn opAndVisibleEqual(a: ?OpAndVisible, b: ?OpAndVisible) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.op.pos == y.op.pos and x.visible == y.visible;
}

/// Whether the two answers agree (`seek_list_opid`'s `debug_assert_eq!`,
/// `op_set.rs:846`).
fn foundOpIdEqual(a: ?FoundOpId, b: ?FoundOpId) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return x.op.pos == y.op.pos and x.index == y.index and x.visible == y.visible;
}

/// Whether two groups are the same register at the same index, row for row.
///
/// `OpsFound`'s `PartialEq` (`op_set.rs:1455`), which is what upstream's
/// `assert_eq!(found, slow, "fast != slow")` compares (`op_set.rs:648`). The
/// port compares the fields explicitly because `Op` is a borrowed row: a row
/// is the same row when its *position* is the same, and the columns behind it
/// are the columns of one op set.
fn opsFoundEqual(a: OpsFound, b: OpsFound) bool {
    if (a.index != b.index) return false;
    if (a.end_pos != b.end_pos) return false;
    if (a.range.start != b.range.start or a.range.end != b.range.end) return false;
    if (a.ops.items.len != b.ops.items.len) return false;
    for (a.ops.items, b.ops.items) |x, y| {
        if (x.pos != y.pos) return false;
    }
    return true;
}

/// Whether two insertion points are the same one — position, index, the
/// element the new row hangs by, and the marks it would carry.
///
/// Upstream's `debug_assert_eq!(Ok(&q), ..)` at `op_set.rs:584-596` compares
/// two `QueryNth`s, which derives `PartialEq` (`:1440`) and whose `marks` is an
/// `Option<Arc<MarkSet>>` compared by content. The port's `MarkSet` is a value
/// whose entries are sorted by name
/// ([src/marks.zig:321-330](../../src/marks.zig)), so entry for entry is the
/// same test.
fn queryNthEqual(a: QueryNth, b: QueryNth) bool {
    if (a.pos != b.pos) return false;
    if (a.index != b.index) return false;
    if (!a.elemid.eql(b.elemid)) return false;
    if ((a.marks == null) != (b.marks == null)) return false;
    const mine = a.marks orelse return true;
    const theirs = b.marks orelse return false;
    if (mine.entries.items.len != theirs.entries.items.len) return false;
    for (mine.entries.items, theirs.entries.items) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!x.value.eql(y.value)) return false;
    }
    return true;
}

// ── The clock-range predicates ─────────────────────────────────────────────

/// Whether `id` is in the past state a [`ClockRange`] names
/// (`ClockRange::visible_before`, `clock.rs:107-116`).
///
/// **Upstream's is `self.predates(id)`, and `predates` is a `Diff` and nothing
/// else** (`:111-116`): a `Current` range — `Current(None)` for the present
/// and `Current(Some(..))` for one past state — has no "before", so this is
/// false for both. The port's [`ClockRange`](../../src/clock.zig) does not
/// carry these two methods, so they are here; they belong on that type and the
/// next person to touch `clock.zig` should move them.
fn visibleBefore(over: ClockRange, id: OpId) bool {
    return switch (over) {
        .diff => |d| d.before.contains(id),
        .current => false,
    };
}

/// Whether `id` is in the present state a [`ClockRange`] names
/// (`ClockRange::visible_after`, `clock.rs:99-105`).
///
/// `Current(None)` is the present and answers true for every id (`:103`),
/// because the present contains every operation the document has.
fn visibleAfter(over: ClockRange, id: OpId) bool {
    return switch (over) {
        .diff => |d| d.after.contains(id),
        .current => |maybe| if (maybe) |c| c.contains(id) else true,
    };
}

// ── Checkpoint helpers ─────────────────────────────────────────────────────

/// Records one column's bytes under `name`.
fn putCheckpoint(gpa: Allocator, name: []const u8, bytes: []u8, out: *Checkpoint) ParseError!void {
    errdefer gpa.free(bytes);
    try out.put(gpa, name, bytes);
}

/// Frees every column's bytes in a checkpoint and the table itself.
fn freeCheckpoint(gpa: Allocator, cp: *Checkpoint) void {
    // `iterator()` is a by-value cursor over the entries, so the bytes are
    // read through `value_ptr` rather than a dedicated value cursor
    // (`std/array_hash_map.zig:265`).
    var it = cp.iterator();
    while (it.next()) |entry| gpa.free(entry.value_ptr.*);
    cp.deinit(gpa);
    cp.* = .empty;
}

/// Two mark values compared the way the fold compares them: the tag, and then
/// the payload for the tags a mark can carry ([marks.rs:333], `:347`).
///
/// A [`MarkData`]'s value is a boolean, a null or an integer
/// ([op_set2/types.rs:56-60](op_set.rs)), and for the two boolean tags the tag
/// alone is not enough — `true` and `false` are different marks. The remaining
/// tags are compared by tag alone, which is exact for them because each one's
/// payload is determined by the tag or is a byte string a mark cannot carry.
fn markValueEql(a: ScalarValue, b: ScalarValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .bool_value => |v| v == b.bool_value,
        .uint => |v| v == b.uint,
        else => true,
    };
}

/// [`MarkSet.withoutUnmarks`](../../src/marks.zig) applied to a **borrowed**
/// set, which is the shape every reader that hands a fold's set back has.
///
/// Upstream reaches the same answer with `arc.as_ref().clone().without_unmarks()`
/// ([`automerge.rs`:1965](../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// the [`MarkSet`] is reference counted there and the clone is its own
/// `FIXME - do I need this clone?`, and the port's is owned rather than
/// reference counted, so a borrowed set cannot be consumed at all. The copy
/// costs the same allocation upstream's does and no more.
///
/// `hydrate.zig`:1989-1994 is the same function for the same reason, and it
/// belongs on [`MarkSet`](../../src/marks.zig) rather than in either of the
/// two files that needs it.
fn withoutUnmarksCopy(gpa: Allocator, set: *const MarkSet) Error!MarkSet {
    var pairs: std.ArrayList(MarkSet.Entry) = .empty;
    defer pairs.deinit(gpa);
    for (set.entries.items) |entry| switch (entry.value) {
        .null_value => {},
        else => try pairs.append(gpa, entry),
    };
    return MarkSet.fromPairs(gpa, pairs.items);
}

/// Whether two *optional* mark sets are the same set, content and all
/// ([`automerge.rs`:1614](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
/// `last_marks.as_ref() != marks`).
///
/// **Both nulls are equal, and that is load-bearing.** The empty set is not a
/// set with nothing in it, it is the absence of one
/// ([`MarkStateMachine.current`](marks.zig), `marks.rs:250-256`), so `null`
/// against `null` is "unchanged" and an unmarked stretch of an object is one
/// measured run rather than a run closed and reopened at every row. `null`
/// against a set is a change, which is how the first mark on an object opens
/// the run it measures.
fn markSetOptEql(a: ?*const MarkSet, b: ?*const MarkSet) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.eql(y);
}

/// The `[]Mark` a folded accumulator is handed back as
/// ([`MarkAccumulator::intoIterNoUnmark`](marks.zig), `marks.rs:76-85`), which
/// is the `collect()` at [`automerge.rs`:1630](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
/// and at `op_set.rs:1023`.
///
/// **The one place an accumulator becomes a list**, and both mark walks end
/// here. [`OpSet.calculateMarks`] and [`OpSet.calculateMarksSlow`] differ in
/// where the runs come from — two indexes against a walk of the rows the clock
/// sees — and in nothing else about how a run is turned into a `Mark`, so this
/// is the step they share rather than two copies of it.
///
/// The caller owns the slice.
fn marksFromAccumulator(gpa: Allocator, acc: *const marksmod.MarkAccumulator) Error![]Mark {
    var out: std.ArrayList(Mark) = .empty;
    errdefer out.deinit(gpa);
    var it = acc.intoIterNoUnmark();
    while (it.next()) |m| try out.append(gpa, m);
    return out.toOwnedSlice(gpa);
}

/// Whether two answers to "the marks of this object" are the same answer,
/// for the cross-check [`OpSet.calculateMarksAt`] makes against
/// [`OpSet.calculateMarksSlow`] (`automerge.rs:1587-1591`).
///
/// **Order is part of the answer, and it is the same order on both sides**
/// because both arms build their list from a name-sorted accumulator
/// ([`MarkAccumulator`](marks.zig), `marks.rs:87-102`) through
/// [`marksFromAccumulator`]. A difference in order is therefore a difference
/// in the answer, and this compares element-wise rather than as two sets —
/// which is the only reading that would notice the two walks disagreeing
/// about *where* a run starts.
fn marksEqual(a: []const Mark, b: []const Mark) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end) return false;
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!x.value.eql(y.value)) return false;
    }
    return true;
}

/// One line per run, for the cross-checks' diagnostics.
///
/// **`{any}` over a [`Mark`] is not usable for this**: it prints the whole
/// struct, so the first disagreement landed four hundred characters in with the
/// marks at the end of the line. A diagnostic nobody can read is a diagnostic
/// nobody acts on.
fn markRunLines(marks: []const Mark, label: []const u8) void {
    if (marks.len == 0) {
        std.debug.print("  {s} <no runs>\n", .{label});
        return;
    }
    for (marks, 0..) |m, i| {
        std.debug.print("  {s}[{d}] {s} [{d}, {d}) = {any}\n", .{ label, i, m.name, m.start, m.end, m.value });
    }
}

/// One line per entry, for the same reason as [`markRunLines`] — and for a
/// stronger one here, because a [`MarkSet`] holds its allocator inline, so
/// `{any}` prints the vtable *first*.
fn markSetLines(set: *const MarkSet, label: []const u8) void {
    var it = set.iter();
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) {
        std.debug.print("  {s}[{d}] {s} = {any}\n", .{ label, n, entry.name, entry.value });
    }
    if (n == 0) std.debug.print("  {s} <empty>\n", .{label});
}

// ── The element a row belongs to ───────────────────────────────────────────

/// The element the next row of five column cursors belongs to
/// (`OpSet::elemid_at`'s `next_elemid` closure, `op_set.rs:801-816`).
///
/// The five cursors are read in lockstep and the two arms are the two shapes a
/// row's key can take: an **insert** hangs by the element it made, so its
/// anchor is its own id; anything else hangs by its key's element, which is
/// `null` for a map key (`:807-814`). A row whose key columns name neither is
/// `error.MissingKey`, from [`opiter.tryLoadElemId`](op_iter.zig).
fn nextElemid(
    insert: *opcols.BoolPrefixColumn.Iterator,
    id_ctr: *opcols.CounterColumn.Iterator,
    id_actor: *opcols.ActorColumn.Iterator,
    key_ctr: *opcols.OptCounterColumn.Iterator,
    key_actor: *opcols.ActorOptColumn.Iterator,
) ReadOpError!?ElemId {
    const is_insert = (try insert.next()) orelse return null;
    const ctr = (try id_ctr.next()) orelse return null;
    const actor = (try id_actor.next()) orelse return null;
    const k_ctr = (try key_ctr.next()) orelse return null;
    const k_actor = (try key_actor.next()) orelse return null;
    if (is_insert) return try opiter.tryLoadElemId(actor, @intCast(ctr));
    const k_ctr_i: ?i64 = if (k_ctr) |v| @intCast(v) else null;
    return try opiter.tryLoadElemId(k_actor, k_ctr_i);
}

/// The element a row at `pos` belongs to and the last row of that element
/// (upstream's `(ElemId, usize)` from `elemid_at`, `op_set.rs:793-828`).
pub const ElemPos = struct {
    /// The element.
    elemid: ElemId,
    /// The last row that belongs to it.
    last_pos: usize,
};

/// The `MarkIdx` that names the begin at `id`, for the truncate upstream
/// performs at `op_set.rs:523`.
fn markIdxStart(begin: OpId) markidx.MarkIdx {
    return .{ .start = begin };
}

/// One line of [`OpSet.dump`], assembled before it is printed so that the
/// fourteen column cursors are read in one place (`Columns::dump` reads them
/// inline, `columns.rs:512-573`, and this is the same set in the same order).
///
/// Upstream renders each column through one of four formatters —
/// `fmt_display`, `fmt_opt_display`, `fmt_opt_debug` and `fmt_bool`
/// (`columns.rs:575-593`) — so that a run of booleans reads as `t`/`f`/`.` and
/// one character wide. Those are the two helpers below; the rest print with
/// `{any}`, which is the same information in more characters.
const dumpRow = struct {
    pos: usize,
    id_actor: ?ActorIdx,
    id_ctr: ?u32,
    obj_actor: ?ActorIdx,
    obj_ctr: ?u32,
    key_str: ?u32,
    key_actor: ?ActorIdx,
    key_ctr: ?u32,
    insert: ?bool,
    visible: ?bool,
    top: ?bool,
    text: ?u32,
    action: ?Action,
    succ: ?u32,

    fn print(self: dumpRow) void {
        std.debug.print(
            "{d:4}: id=({any},{any}) obj=({any},{any}) key=({any},{any},{any}) " ++
                "i={s} v={s} t={s} tx={any} act={any} succ={any}\n",
            .{
                self.pos,
                self.id_ctr,
                self.id_actor,
                self.obj_ctr,
                self.obj_actor,
                self.key_ctr,
                self.key_actor,
                self.key_str,
                boolCell(self.insert),
                boolCell(self.visible),
                boolCell(self.top),
                self.text,
                self.action,
                self.succ,
            },
        );
    }
};

/// `fmt_bool` (`columns.rs:589-593`): a run of booleans reads as `t`, `f` or
/// `.` for a run the cursor has walked past, and is one character wide.
fn boolCell(v: ?bool) []const u8 {
    if (v) |b| return if (b) "t" else "f";
    return ".";
}

// ── Tests ──────────────────────────────────────────────────────────────────

const markmod = @import("mark_index.zig");

/// The encoding every test measures widths in, so the expected `text` rows are
/// arithmetic rather than grapheme segmentation (the same choice
/// [index.zig](index.zig)'s tests make, for the same reason).
const encoding: TextEncoding = .unicode_code_point;

/// The document's one actor (`types.zig:154-156`).
const actor0: ActorId = .{ .bytes = "aaaa" };

/// The actor table every fixture starts from: one actor, so every actor index
/// in the columns is `0`.
const fixture_actors = [_]ActorId{actor0};

/// The id of the operation at `ctr` made by `actor` (`types.rs:154-156`).
fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

/// The object `op` made (`types.rs:200-202`).
fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// A sequence row's anchor at `id` (`ElemId::from_op_id`,
/// `rust/automerge/src/types.rs:652-654`).
fn anchor(id: OpId) ElemId {
    return ElemId.fromOpId(id);
}

/// The head of a sequence: the element id that means "inserted at the front"
/// (`ElemId::head`, `rust/automerge/src/types.rs:657-659`).
const head: ElemId = ElemId.head();

/// An allocator that counts what goes through it, so a test can assert that
/// building something asked for nothing. `insert.zig`'s is the same shape,
/// written for the same reason.
const Counting = struct {
    inner: Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, ra: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.inner.rawAlloc(len, ra, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, ra, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, ra, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, ra: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, ra, ret_addr);
    }
};

/// A counter value (`value.zig:107-118`).
fn counter(v: i64) ScalarValue {
    return .{ .counter = ScalarValue.Counter.init(v) };
}

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, so an interned id is stable for the life of the
/// test. `index.zig:954-981` is the same helper for the same reason — a splice
/// interns the map key and the mark name, and the mark cache reads the name
/// back.
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

// ── The fixture row ────────────────────────────────────────────────────────

/// A row as `splice` reads it: the [`Op`] every walk hands back, plus the
/// `top` and `visible` the splice path is *told*.
///
/// **They have to be separate because they are separate facts.**
/// [`columns.Columns.splice`] writes what `top` and `visible` answer
/// (`columns.zig:986`, `:989`), and for a row already in the document
/// [`Op.top`] is the default [`Op.visible`] — which is **not** the register
/// winner the rebuild computes. A conflicted register is exactly where the two
/// differ, so a fixture that let `Op.top` stand in for the index column would
/// compare nothing.
///
/// The other thirty-eight accessors are `Op`'s own, forwarded unchanged; the
/// fixture is a statement about the *index columns*, not about the rows, and
/// re-declaring `width` or `markName` here would be a second source of truth
/// for something [`opmod.Op`] already owns.
const TestRow = struct {
    op: Op,
    is_top: bool,
    is_visible: bool,

    pub fn id(self: *const TestRow) OpId {
        return self.op.id();
    }
    pub fn obj(self: *const TestRow) ?OpId {
        return self.op.obj();
    }
    pub fn objId(self: *const TestRow) ObjId {
        return self.op.objId();
    }
    pub fn objActor(self: *const TestRow) ?ActorIdx {
        return self.op.objActor();
    }
    pub fn objCtr(self: *const TestRow) ?u32 {
        return self.op.objCtr();
    }
    pub fn objInfo(self: *const TestRow) ?opmod.ObjInfo {
        return self.op.objInfo();
    }
    pub fn action(self: *const TestRow) Action {
        return self.op.action();
    }
    pub fn key(self: *const TestRow) KeyRef {
        return self.op.key();
    }
    pub fn keyStr(self: *const TestRow) ?[]const u8 {
        return self.op.keyStr();
    }
    pub fn keyActor(self: *const TestRow) ?ActorIdx {
        return self.op.keyActor();
    }
    pub fn keyCtr(self: *const TestRow) ?i64 {
        return self.op.keyCtr();
    }
    pub fn insert(self: *const TestRow) bool {
        return self.op.insert();
    }
    pub fn value(self: *const TestRow) ScalarValue {
        return self.op.value();
    }
    pub fn metaValue(self: *const TestRow) ValueMeta {
        return self.op.metaValue();
    }
    pub fn rawValue(self: *const TestRow) ?[]const u8 {
        return self.op.rawValue();
    }
    pub fn expand(self: *const TestRow) bool {
        return self.op.expand();
    }
    pub fn markName(self: *const TestRow) ?[]const u8 {
        return self.op.markName();
    }
    pub fn markData(self: *const TestRow) ?MarkData {
        return self.op.markData();
    }
    pub fn markIndex(self: *const TestRow) ?i64 {
        return self.op.markIndex();
    }
    pub fn width(self: *const TestRow, seq_type: SequenceType, enc: TextEncoding) i64 {
        return self.op.width(seq_type, enc);
    }
    pub fn visible(self: *const TestRow) bool {
        return self.is_visible;
    }
    pub fn top(self: *const TestRow) bool {
        return self.is_top;
    }
    pub fn elemidOrKey(self: *const TestRow) KeyRef {
        return self.op.elemidOrKey();
    }
    pub fn asStr(self: *const TestRow) []const u8 {
        return self.op.asStr();
    }
    pub fn isInc(self: *const TestRow) bool {
        return self.op.isInc();
    }
    pub fn isCounter(self: *const TestRow) bool {
        return self.op.isCounter();
    }
    pub fn isMark(self: *const TestRow) bool {
        return self.op.isMark();
    }
    pub fn isDelete(self: *const TestRow) bool {
        return self.op.isDelete();
    }
    pub fn getIncrementValue(self: *const TestRow) ?i64 {
        return self.op.getIncrementValue();
    }
    pub fn cursor(self: *const TestRow) Error!ElemId {
        return self.op.cursor();
    }
    pub fn succCount(self: *const TestRow) usize {
        return self.op.succCount();
    }
    pub fn succAt(self: *const TestRow, i: usize) OpId {
        return self.op.succAt(i);
    }
    pub fn succIncCount(self: *const TestRow) usize {
        return self.op.succIncCount();
    }
    pub fn succIncAt(self: *const TestRow, i: usize) ?i64 {
        return self.op.succIncAt(i);
    }
    pub fn succ(self: *const TestRow) SuccCursors {
        return self.op.succ();
    }
    pub fn succInc(self: *const TestRow) opmod.SuccIncCursors {
        return self.op.succInc();
    }
    pub fn idActor(self: *const TestRow) ActorIdx {
        return self.op.idActor();
    }
    pub fn idCtr(self: *const TestRow) i64 {
        return self.op.idCtr();
    }
    pub fn opIdCtr(self: *const TestRow) u32 {
        return self.op.opIdCtr();
    }
    pub fn predCount(self: *const TestRow) u32 {
        return self.op.predCount();
    }
    pub fn pred(self: *const TestRow) []const OpId {
        return self.op.pred();
    }
};

/// A row as a fixture declares it. `succs` must outlive the value, exactly as
/// an [`Op`]'s borrowed key and value must ([op.zig](op.zig)'s module doc).
fn makeOp(
    id: OpId,
    obj: ObjId,
    key: KeyRef,
    insert: bool,
    action: Action,
    val: ScalarValue,
    name: ?[]const u8,
    succs: []const SuccEntry,
) Op {
    return Op.init(0, false, id, action, obj, key, insert, val, false, name, SuccCursors.fromSpan(succs, 0));
}

/// A row as [`Row`] declares it, with the two index columns spelled out.
fn rowAt(
    id: OpId,
    obj: ObjId,
    key: KeyRef,
    insert: bool,
    action: Action,
    val: ScalarValue,
    name: ?[]const u8,
    succs: []const SuccEntry,
    is_top: bool,
    is_visible: bool,
) TestRow {
    return .{
        .op = makeOp(id, obj, key, insert, action, val, name, succs),
        .is_top = is_top,
        .is_visible = is_visible,
    };
}

/// A mark's expansion, which a mark row must state and every other row leaves
/// false. Separate from `row` so a fixture line reads as the mark it is.
fn bold(id: OpId, obj: ObjId, at: ElemId) TestRow {
    return .{
        .op = Op.init(
            0,
            false,
            id,
            .mark,
            obj,
            .{ .seq = at },
            true,
            .null_value,
            true,
            "bold",
            SuccCursors.fromSpan(&.{}, 0),
        ),
        // **Top, and that is what the index builder says.** Both halves of a
        // mark are inserts, so each is the only row of its own register
        // ([`Op.elemidOrKey`], `op.rs:1040-1046`), and
        // [`indexmod.IndexBuilder.flush`] marks the last successor-free row of
        // each register — this row, with none. **The mark contributes no
        // width, which is a separate thing**: the width is zero, so the text
        // index entry is `Some(0)` rather than `None`
        // (`columns.rs:478-483`). `is_top = false` here was the other
        // spelling of this fixture — it went with spelling the mark end as a
        // non-insert, which put the two rows in one register where only the
        // last is top — and it is `group_mismatch { first_top = null, last_vis
        // = 9 }` once the end is the insert the reference writes.
        .is_top = true,
        .is_visible = true,
    };
}

/// A mark **begin** at `at`, carrying the name and the value it puts on its
/// span. A `Null` value is an **unmark** — a mark begin whose value resolves
/// to nothing ([`markSetFromQueryState`](insert.zig)), which is a different
/// row from a mark end and is the one that removes a mark.
///
/// Both halves of a mark are inserts, which is what upstream's
/// `insert_mark_end_after` produces (`transaction/inner.rs:830-866`); the
/// difference between the two rows is the name column and nothing else
/// (`op_set2/types.rs:177-186`).
fn markBegin(id: OpId, obj: ObjId, at: ElemId, name: []const u8, val: ScalarValue) TestRow {
    return .{
        .op = Op.init(
            0,
            false,
            id,
            .mark,
            obj,
            .{ .seq = at },
            true,
            val,
            true,
            name,
            SuccCursors.fromSpan(&.{}, 0),
        ),
        // **Top, and it has to be.** A mark begin is an insert, so
        // [`Op.elemidOrKey`](op.zig) answers its own id and it is the only row
        // of its own register (`op.rs:1040-1046`);
        // [`indexmod.IndexBuilder.flush`] marks the last successor-free row of
        // each register (`index.rs:175-183`), and a mark begin has no
        // successor. **A visible row that is not top is a document the
        // reference cannot hold**: `validate_top_index` asserts
        // `first_top == last_vis` on every group change (`op_set.rs:196`),
        // which for this row is `None == Some(pos)`. Measured on this file's
        // own checker, the two fixtures the cross-checks fired on were exactly
        // that — `group_mismatch { at = 4, first_top = null, last_vis = 3 }`
        // and `{ at = 2, first_top = null, last_vis = 1 }`. A `top` of false
        // also hides the row from every row walk ([`top_op.TopIter`](top_op.zig)'s
        // `Current` flavour reads `index.top`, `top_op.rs:212-215`), so the
        // fold in [`OpSet.calculateMarksSlow`] never met the begin at all.
        //
        // **The mark's width is zero, which is a different fact from topness.**
        // It says the `text` entry is `Some(0)` rather than `None`
        // (`index.rs:223-228`, the port's [index.zig:655-664](index.zig)) — a
        // `top` of false was the only way to get a `None` there, and the
        // reason it was written that way.
        .is_top = true,
        .is_visible = true,
    };
}

/// A mark **end** at `at`: no name, a `Null` value, and an index derived from
/// `id`'s own predecessor ([`Op.markIndex`](op.zig)), which is what pairs it
/// with a begin.
fn markEnd(id: OpId, obj: ObjId, at: ElemId) TestRow {
    return .{
        .op = Op.init(
            0,
            false,
            id,
            .mark,
            obj,
            .{ .seq = at },
            true,
            .null_value,
            false,
            null,
            SuccCursors.fromSpan(&.{}, 0),
        ),
        // **Top, and for [`bold`]'s reason**: an insert is the only row of its
        // own register and has no successor, so
        // [`indexmod.IndexBuilder.flush`] marks it.
        .is_top = true,
        .is_visible = true,
    };
}

// ── The document ───────────────────────────────────────────────────────────

/// The successor of row 0: a **delete** by the operation at row 1. This is
/// the document's one deletion, and it is the only successor edge the fixture
/// declares, so `subLen` is one and the `inc` column is one null.
const succ_r0 = [_]SuccEntry{.{ .id = opId(2, 0), .inc = null }};

/// The list object row 2 makes, and the text object row 3 makes.
const list_obj: ObjId = made(3, 0);
const text_obj: ObjId = made(4, 0);

/// The twelve rows every test in this file walks, in the order
/// [`opmod.Op.step`] enforces (`op.rs:1048-1073`), so the fixture is a
/// document a real merge could have produced.
///
/// * rows 0-1 are the counter register `ROOT.a`: a `set` and the `set` that
///   overwrites it, which is the delete;
/// * row 2 makes the list, row 3 the text object, row 4 a plain map value;
/// * rows 5-7 are the list: two inserts at the head and the overwrite of one
///   of them, in that element's own register;
/// * rows 8-11 are the text: two inserts and a bold mark with its end.
///
/// **The ids do not run in row order, and that is rule R4, not a mistake.**
/// Every head insert is the *front* of its list, so a row anchoring to the
/// head must have an id that sorts *before* the element the previous row
/// belongs to ([op.rs:1064-1067](op.zig)) — which for two inserts at the head
/// means the later one comes **first**. Rows 5 and 6 are therefore ids 7 and 6
/// in that order, and rows 8-11 are ids 12, 10, 11 and 9. The test "the
/// row-order checker accepts the document" is what proves the order is legal;
/// a "sorted by id" fixture would not be a document automerge could produce.
///
/// The `top` and `visible` columns are **not** guesses; they are what
/// [`indexmod.IndexBuilder`] derives from these rows, and the test "a load
/// with no stored index rebuilds it, and the rebuilt rows are the ones the
/// rows say" pins the same values again as literals, so the two are not two
/// copies of one answer.
///
/// **The two mark rows are not top, and that is upstream's rule rather than a
/// fixture convenience.** A mark row opens a register of its own — both halves
/// are inserts ([`inner.rs`:827-857](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// `insert_mark_end_after` at `:404-430`) — and an insert is its own element
/// ([`Op.elemidOrKey`], `op.rs:1040-1046`), so it is the register's only row
/// and still contributes no width: `None` in the text index
/// ([`columns.zig`](columns.zig)'s `index.text`, `columns.rs:478-483` in the
/// reference) and not top. **Spelling the mark end as a non-insert instead
/// puts it in the begin's register**, which is a document the reference cannot
/// write and which makes the two `queryInsertAt` paths disagree; see the test
/// "queryInsertAt answers at the front, in the middle and at the end, with and
/// without a clock".
fn documentRows() [12]TestRow {
    return .{
        // ROOT."a" — a counter and the counter that overwrites it. Row 0's
        // successor is row 1's id, so this is the document's one **delete**:
        // [`Op.visible`] says a counter is visible only while every successor
        // increments it ([op.zig:1857-1862](op.zig)), and this one deletes.
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &succ_r0, false, false),
        rowAt(opId(2, 0), .root, .{ .map = "a" }, false, .set, counter(7), null, &.{}, true, true),
        rowAt(opId(3, 0), .root, .{ .map = "b" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(4, 0), .root, .{ .map = "c" }, false, .make_text, .null_value, null, &.{}, true, true),
        rowAt(opId(5, 0), .root, .{ .map = "d" }, false, .set, .{ .str = "keep" }, null, &.{}, true, true),
        // The list: "y" (id 7) at the head ahead of "x" (id 6), and "x"
        // overwritten to "X" (id 8) in the element's own register.
        rowAt(opId(7, 0), list_obj, .{ .seq = head }, true, .set, .{ .str = "y" }, null, &.{}, true, true),
        rowAt(opId(6, 0), list_obj, .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, false, true),
        rowAt(opId(8, 0), list_obj, .{ .seq = anchor(opId(6, 0)) }, false, .set, .{ .str = "X" }, null, &.{}, true, true),
        // The text: "b" (id 12), a bold mark (id 10) and the mark end that
        // closes it (id 11), then "a" (id 9).
        rowAt(opId(12, 0), text_obj, .{ .seq = head }, true, .set, .{ .str = "b" }, null, &.{}, true, true),
        bold(opId(10, 0), text_obj, head),
        markEnd(opId(11, 0), text_obj, anchor(opId(10, 0))),
        rowAt(opId(9, 0), text_obj, .{ .seq = head }, true, .set, .{ .str = "a" }, null, &.{}, true, true),
    };
}

/// The op set every test builds, and the table its strings live in.
///
/// The two are one value because the mark index's cache holds a
/// [`MarkData`] whose name points into the table
/// ([columns.zig](columns.zig)'s module doc, "The one borrow in this file"),
/// and the op set does **not** own the table.
/// The document's op set, built over `table`.
///
/// **The string table is not in here on purpose, and this is the ownership
/// rule rather than a convenience.** The op set borrows the table
/// ([columns.zig](columns.zig)'s module doc: "The one borrow in this file"),
/// so the table must live at one address for as long as the set does. A struct
/// that *owns* the table and is then returned by value cannot promise that: the
/// copy lands in the caller's frame and the set's `strings.ctx` is left
/// pointing at the callee's dead local, which is a use-after-free the moment a
/// walk resolves an interned key. So the table is the caller's, in the
/// caller's frame, and this is one function that builds the set over it.
fn documentSet(gpa: Allocator, table: *Table) !Set {
    // **The actor table is the document's**, not empty: a load is handed the
    // same table (`OpSet.load`'s `actors`), and `debugCmp` compares it
    // ([op_set.zig](op_set.zig)'s `debugCmp`), so a fixture that spliced rows
    // with no actors would fail a save-and-reload comparison over nothing but
    // the actors.
    const rows = documentRows();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    errdefer set.deinit();
    _ = try set.splice(0, &rows);
    return set;
}

/// The same, with no rows.
fn emptySet(gpa: Allocator, table: *Table) !Set {
    return Set.init(gpa, encoding, table.asTable());
}

/// A document's op set and the table it borrows, built together.
///
/// The pair is a struct so a test reads as one line, and the table is
/// **heap-allocated** for the same reason [`documentSet`] takes a pointer: a
/// returned-by-value struct would move it, and the set's `strings.ctx` would
/// dangle. `Table` carries its own allocator, so a test frees it with
/// [`destroy`] and the set with `deinit`.
fn Document(gpa: Allocator) !*DocumentHandle {
    const self = try gpa.create(DocumentHandle);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .table = Table.init(gpa), .set = undefined };
    self.set = try documentSet(gpa, &self.table);
    return self;
}

/// The pair [`Document`] hands out. Declared after it so the name is the one a
/// test writes.
const DocumentHandle = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    /// Frees the op set, the table's strings, the table and the handle.
    fn destroy(self: *DocumentHandle) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// An empty op set and the table it borrows, for a test that splices its own
/// rows. [`Document`] without the document.
fn Empty(gpa: Allocator) !*DocumentHandle {
    const self = try gpa.create(DocumentHandle);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .table = Table.init(gpa), .set = undefined };
    self.set = try emptySet(gpa, &self.table);
    return self;
}

/// The document's second actor, for the object-index tests. It sorts **after**
/// `actor0`, which is what keeps the actor table sorted
/// ([`types.zig:108-110`](../types.zig)) and so keeps every actor index a
/// position rather than an accident.
const actor1: ActorId = .{ .bytes = "bbbb" };

/// The actor table the object-index tests need: two actors, so one of them can
/// be dropped without emptying the table (`OpSet::remove_actor`,
/// `op_set.rs:1419-1429`).
const two_actors = [_]ActorId{ actor0, actor1 };

/// The same, with no rows. The table is the caller's for the reason
/// [`documentSet`] gives.
fn twoActorSet(gpa: Allocator, table: *Table) !Set {
    return Set.fromActors(gpa, &two_actors, encoding, table.asTable());
}

/// An op set over two actors and the table it borrows, for a test that removes
/// one of them. [`Empty`] with an actor table.
fn TwoActors(gpa: Allocator) !*DocumentHandle {
    const self = try gpa.create(DocumentHandle);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .table = Table.init(gpa), .set = undefined };
    self.set = try twoActorSet(gpa, &self.table);
    return self;
}

// ── Test helpers ───────────────────────────────────────────────────────────

/// The op set the invariant checkers read, as a value the test can point at.
const Set = OpSet(TestRow);

// What the visible-row walk and the two action-value walks above can be asked
// to do, decided at comptime and written down once.
//
// Naming a mark *is* the check: [`tools.Shiftable`] fails to compile on a walk
// missing one of its eight names ([`column.zig:4006-4026`](../hexane/column.zig)),
// so a non-null mark here proves all eight are there.
//
// **All three are cursors now, and the visible-row walk is the one that had to
// become one.** Its inner walk used to be [`vis.VisibleOpIter`] — a filter,
// with no positional entry point to forward a cursor to — and this block
// asserted the opposite. [`OpSet.VisibleRows`] says why the filter had to
// leave: a filter cannot be stepped over by a row count, and the skipper's row
// count is what the skip means.
comptime {
    std.debug.assert(Set.ActionValues.isShiftable());
    std.debug.assert(Set.TopActionValues.isShiftable());
    // Naming a non-null mark instantiates `Shiftable` over it, and *that* is
    // the check on all eight names.
    _ = Set.ActionValues.shiftable.?;
    _ = Set.TopActionValues.shiftable.?;
    _ = Set.VisibleRows.shiftable;
}

/// The index rows the document in [`documentRows`] must produce.
///
/// **Pinned separately from the fixture on purpose.** The fixture *declares*
/// `top` and `visible` to `splice`, which writes them; these literals are what
/// a reader must see, and the two agree only if the declaration was right. A
/// comparison of "the rebuilt index" against "the spliced index" alone would
/// be two copies of one answer, and the mismatch this file most needs to catch
/// is exactly the one that would pass.
const want_top = [_]bool{
    false, true,  true, true, true,
    true,  false, true, true, true,
    true,  true,
};
const want_visible = [_]bool{
    false, true, true, true, true,
    true,  true, true, true, true,
    true,  true,
};

/// The text index the document must produce: a width on every `top` row and
/// nothing on the others ([columns.rs:475-485](columns.zig)).
///
/// **Widths are measured as text for every row** ([index.rs:193-194]), so a
/// value that is not a string measures as the object replacement character,
/// one code point, and a mark measures as nothing
/// ([op.rs:997-1005](op.zig)). Row 4's `"keep"` is four, and **rows 9 and 10
/// are the mark's two anchors and are both `Some(0)`**: both are `top`, each
/// is the only row of its own register ([`Op.elemidOrKey`],
/// `op.rs:1040-1046`), and a top row's entry is its width
/// (`columns.rs:478-483`) — zero for a mark, which is a different thing from
/// not being top. Row 6 is the one row here that is top-free *and* width-free.
const want_text = [_]?u32{
    null, 1,    1, 1, 4,
    1,    null, 1, 1, 0,
    0,    1,
};

/// One slot per successor edge: row 0's single deleting successor, which
/// carries none ([index.rs:217](index.zig), `:200`).
const want_inc = [_]?i64{null};

/// The `succ_count` the document must produce: row 0 has the one successor,
/// every other row none.
const want_succ_count = [_]u32{
    1, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 0,
};

/// That two columns hold the same values in the same order, row for row.
///
/// `expectEqual` on two slices compares their **pointers**
/// ([std/testing.zig:130-139](../../tmp/zig-global-cache/lib/std/testing.zig)),
/// so a test that used it here would pass on any two slices and fail on none.
fn expectSameCol(comptime Col: type, a: *const Col, b: *const Col, gpa: Allocator) !void {
    const av = try a.toSlice(gpa);
    defer gpa.free(av);
    const bv = try b.toSlice(gpa);
    defer gpa.free(bv);
    try testing.expectEqual(av.len, bv.len);
    for (av, bv) |x, y| try testing.expectEqual(x, y);
}

/// A boolean prefix column read as plain values, so a test can state the rows
/// it expects without knowing the prefix sums.
///
/// [`column.zig:1729`](../../src/hexane/column.zig) `iterator()` is the plain
/// cursor; the prefix cursor is what `advancePrefix` needs and not what a
/// test needs.
fn boolRows(col: anytype, gpa: Allocator) ![]bool {
    var it = try col.iterator();
    var out: std.ArrayList(bool) = .empty;
    errdefer out.deinit(gpa);
    while (try it.next()) |v| try out.append(gpa, v);
    return out.toOwnedSlice(gpa);
}

/// The `top` and `visible` rows of `set`, as two freshly allocated slices.
fn indexRows(set: *const Set, gpa: Allocator) !struct { top: []bool, visible: []bool } {
    return .{
        .top = try boolRows(&set.cols.index.top, gpa),
        .visible = try boolRows(&set.cols.index.visible, gpa),
    };
}

/// The `text` rows of `set`.
fn textRows(set: *const Set, gpa: Allocator) ![]?u32 {
    return set.cols.index.text.toSlice(gpa);
}

/// The `inc` rows of `set`.
fn incRows(set: *const Set, gpa: Allocator) ![]?i64 {
    return set.cols.index.inc.toSlice(gpa);
}

/// A clock over every operation the document holds, which is the *present*.
fn fullClock(gpa: Allocator, highest: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, highest);
    return c;
}

/// A clock over the operations up to and including `cutoff`, which is the
/// document as it was just after that operation.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    return fullClock(gpa, cutoff);
}

/// A new successor edge for a row at `pos` whose successor list is currently
/// `len` long, with the flattened columns' coordinates the way
/// [`opmod.Op.addSucc`] computes them ([op.zig:2027-2038](op.zig)).
///
/// `sub_pos` is the row's *current* end in the flattened pair, which is the
/// prefix sum of `succ_count` up to and including `pos`
/// ([columns.rs:299-300](columns.zig)).
fn succInsert(
    set: *const Set,
    pos: usize,
    id: OpId,
    inc: ?i64,
    len: u64,
) !opmod.SuccInsert {
    const sub_pos = std.math.cast(usize, try set.cols.succ_count.getPrefix(pos + 1)) orelse
        return error.Overflow;
    return .{ .id = id, .pos = pos, .inc = inc, .len = len, .sub_pos = sub_pos };
}

// ── The row-order checker, and the four rules it enforces ──────────────────

test "the row-order checker accepts the document and rejects each of R1 to R4" {
    const gpa = testing.allocator;

    // The well-ordered set first: a checker that cannot pass is not a checker
    // either, and `op.zig`'s own tests cover `Op::step` in isolation, so what
    // is being checked here is that this file drives it over the columns.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        try testing.expect(try doc.set.validateOpOrder());
    }

    // **R1 — object ids strictly ascend, root first** (`op.rs:1049-1054`).
    // Two objects, the second's id below the first's, so the third row's
    // object descends. Each row is its own register, so nothing else is wrong.
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const rows = [_]TestRow{
            rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, true, true),
            rowAt(opId(2, 0), made(2, 0), .{ .map = "k" }, false, .set, counter(1), null, &.{}, true, true),
            rowAt(opId(3, 0), made(1, 0), .{ .map = "k" }, false, .set, counter(1), null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &rows);
        try testing.expect(!(try doc.set.validateOpOrder()));
    }

    // **R2 — a `Map` row and a `Seq` row are never adjacent in one object**
    // (`op.rs:1055-1059`, the `_ => false` arm of the key comparison).
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const rows = [_]TestRow{
            rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, true, true),
            rowAt(opId(2, 0), .root, .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &rows);
        try testing.expect(!(try doc.set.validateOpOrder()));
    }

    // **R3 — one register's rows ascend strictly in id** (`op.rs:1061-1062`).
    // Descending, and then the same id twice: a strict order, so a tie is as
    // wrong as a descent.
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const descending = [_]TestRow{
            rowAt(opId(2, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, false, true),
            rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(2), null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &descending);
        try testing.expect(!(try doc.set.validateOpOrder()));
    }
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const tied = [_]TestRow{
            rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, false, true),
            rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(2), null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &tied);
        try testing.expect(!(try doc.set.validateOpOrder()));
    }

    // **R4 — an insert opening a register is anchored to the previous
    // element, or its own id sorts before it** (`op.rs:1064-1067`). Two
    // inserts at the head: the later one first is legal, the later one second
    // is not, and the only thing that differs is the two rows' order.
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const legal = [_]TestRow{
            rowAt(opId(2, 0), made(1, 0), .{ .seq = head }, true, .set, .{ .str = "y" }, null, &.{}, true, true),
            rowAt(opId(1, 0), made(1, 0), .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &legal);
        try testing.expect(try doc.set.validateOpOrder());
    }
    {
        const doc = try Empty(gpa);
        defer doc.destroy();
        const forward = [_]TestRow{
            rowAt(opId(1, 0), made(1, 0), .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, true, true),
            rowAt(opId(2, 0), made(1, 0), .{ .seq = head }, true, .set, .{ .str = "y" }, null, &.{}, true, true),
        };
        _ = try doc.set.splice(0, &forward);
        try testing.expect(!(try doc.set.validateOpOrder()));
    }
}

test "the row-order checker rejects a register whose rows are not contiguous" {
    // R3's other half: a register's rows must be a *run*, not merely ascending
    // somewhere in the column. `ROOT."a"`, `ROOT."b"`, `ROOT."a"` — the third
    // row's own key ascends against the second, so the key arm rejects it
    // before the contiguity is ever consulted. The rule under test is the same
    // one either way: the document has one register in two places.
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "b" }, false, .set, counter(1), null, &.{}, true, true),
        rowAt(opId(3, 0), .root, .{ .map = "a" }, false, .set, counter(2), null, &.{}, true, true),
    };
    _ = try doc.set.splice(0, &rows);
    try testing.expect(!(try doc.set.validateOpOrder()));
}

// ── The index checker, and the four things it asserts ──────────────────────

test "the top-index checker names each of the four things it asserts" {
    const gpa = testing.allocator;

    // A well-ordered document with a well-ordered index: the checker must pass
    // before any of its failures means anything.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        try testing.expectEqual(@as(?TopIndexFault, null), try doc.set.validateTopIndex());
    }

    // **Length 1 — `top` and `visible` disagree about how many rows there
    // are** (`op_set.rs:181`). One value appended to `top` and not to
    // `visible`.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        const before = doc.set.cols.index.top.len();
        try doc.set.cols.index.top.splice(gpa, before, 0, &.{true});
        const fault = (try doc.set.validateTopIndex()).?;
        switch (fault) {
            .top_visible_len => |v| {
                try testing.expectEqual(before + 1, v.top);
                try testing.expectEqual(before, v.visible);
            },
            else => return error.TestUnexpectedResult,
        }
        try testing.expect(fault.isLength());
    }

    // **Length 2 — `top` does not have one row per op** (`op_set.rs:182`).
    // Both columns are now one longer than the document, so the *first* check
    // passes and this one fires.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        const rows = doc.set.len();
        try doc.set.cols.index.top.splice(gpa, rows, 0, &.{true});
        try doc.set.cols.index.visible.splice(gpa, rows, 0, &.{true});
        const fault = (try doc.set.validateTopIndex()).?;
        switch (fault) {
            .top_row_len => |v| {
                try testing.expectEqual(rows + 1, v.index);
                try testing.expectEqual(rows, v.rows);
            },
            else => return error.TestUnexpectedResult,
        }
        try testing.expect(fault.isLength());
    }

    // **`top` implies `visible`** (`op_set.rs:202-207`). Row 8 is a winner;
    // clearing its visibility is exactly what the assertion forbids.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        try testing.expectEqual(true, (try doc.set.cols.index.top.get(8)).?);
        try doc.set.cols.index.visible.splice(gpa, 8, 1, &.{false});
        const fault = (try doc.set.validateTopIndex()).?;
        switch (fault) {
            .top_not_visible => |at| try testing.expectEqual(@as(usize, 8), at),
            else => return error.TestUnexpectedResult,
        }
        try testing.expect(!fault.isLength());
    }

    // **A group's first winner is its last visible row** (`op_set.rs:196`),
    // and the group in question is *not* the last one. Rows 6 and 7 are the
    // list element `seq(6,0)`; promoting row 6 gives the group two winners,
    // so its first winner is 6 and its last visible row is 7.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        try doc.set.cols.index.top.splice(gpa, 6, 1, &.{true});
        const fault = (try doc.set.validateTopIndex()).?;
        switch (fault) {
            .group_mismatch => |v| {
                try testing.expectEqual(@as(usize, 8), v.at);
                try testing.expectEqual(@as(?usize, 6), v.first_top);
                try testing.expectEqual(@as(?usize, 7), v.last_vis);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    // **The same check, for the group the walk ended in** (`op_set.rs:212`).
    // Row 11 is the last group and its own only row; clearing its `top` leaves
    // the group with a visible row and no winner, and because nothing follows
    // it the in-loop check never runs.
    {
        const doc = try Document(gpa);
        defer doc.destroy();
        try doc.set.cols.index.top.splice(gpa, 11, 1, &.{false});
        const fault = (try doc.set.validateTopIndex()).?;
        switch (fault) {
            .final_group_mismatch => |v| {
                try testing.expectEqual(@as(usize, 12), v.at);
                try testing.expectEqual(@as(?usize, null), v.first_top);
                try testing.expectEqual(@as(?usize, 11), v.last_vis);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

// ── The load path rebuilds the index, because nothing stores it ────────────

test "a load with no stored index rebuilds it, and the rebuilt rows are the ones the rows say" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // **The five index columns are never written.** The exporter has no arm for
    // them ([columns.rs:135-170](columns.zig)) and `Columns.load` builds them
    // empty (`:314`), so a load arrives with rows and no index at all and
    // [`OpSet.load`] has to rebuild it ([op_set.zig](op_set.zig)'s module doc,
    // "The load path rebuilds the index").
    var exported = try doc.set.exportColumns(gpa);
    defer exported.deinit(gpa);
    var saved_names: usize = 0;
    for (exported.cols.columns) |col| {
        // Not one of the five: `ids.id_actor_col_spec` and its neighbours are
        // the sixteen data columns only.
        switch (col.spec.raw) {
            ids.id_actor_col_spec.raw,
            ids.id_counter_col_spec.raw,
            ids.obj_id_actor_col_spec.raw,
            ids.obj_id_counter_col_spec.raw,
            ids.key_actor_col_spec.raw,
            ids.key_counter_col_spec.raw,
            ids.key_str_col_spec.raw,
            ids.insert_col_spec.raw,
            ids.action_col_spec.raw,
            ids.mark_name_col_spec.raw,
            ids.expand_col_spec.raw,
            ids.succ_count_col_spec.raw,
            ids.succ_actor_col_spec.raw,
            ids.succ_counter_col_spec.raw,
            ids.value_meta_col_spec.raw,
            ids.value_col_spec.raw,
            => saved_names += 1,
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 16), saved_names);

    var loaded = try Set.load(gpa, exported.cols, &fixture_actors, encoding, doc.table.asTable());
    defer loaded.deinit();

    // **The literals first, then the comparison.** The rebuild derived its
    // rows from the sixteen data columns alone; these are the values the
    // document says those rows have. Pinning them before comparing is what
    // keeps the comparison from being two copies of one answer.
    {
        const got_top = try indexRows(&loaded, gpa);
        defer gpa.free(got_top.top);
        defer gpa.free(got_top.visible);
        try testing.expectEqualSlices(bool, &want_top, got_top.top);
        try testing.expectEqualSlices(bool, &want_visible, got_top.visible);

        const text = try textRows(&loaded, gpa);
        defer gpa.free(text);
        try testing.expectEqualSlices(?u32, &want_text, text);

        const inc = try incRows(&loaded, gpa);
        defer gpa.free(inc);
        try testing.expectEqualSlices(?i64, &want_inc, inc);

        const succ = try loaded.cols.succ_count.toSlice(gpa);
        defer gpa.free(succ);
        try testing.expectEqualSlices(u32, &want_succ_count, succ);
    }

    // And now the rebuild against the splice-built set, row for row, over all
    // twenty columns and the object table.
    try loaded.debugCmp(&doc.set);
    try testing.expectEqual(@as(usize, doc.set.len()), loaded.len());
    try testing.expectEqual(@as(usize, doc.set.subLen()), loaded.subLen());
    try testing.expect(try loaded.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try loaded.validateTopIndex());

    // The object table came through the rebuild too, which is the other half
    // of what `set_indexes` installs ([op_set.rs:216-230](op_set.rs)).
    try testing.expectEqual(doc.set.objectType(list_obj), loaded.objectType(list_obj));
    try testing.expectEqual(doc.set.objectType(text_obj), loaded.objectType(text_obj));
    try testing.expectEqual(doc.set.objectType(.root), loaded.objectType(.root));

    // **A second load of the same bytes is the same document**, so the rebuild
    // is a function of the data columns and not of anything it remembers.
    var again = try Set.load(gpa, exported.cols, &fixture_actors, encoding, doc.table.asTable());
    defer again.deinit();
    try again.debugCmp(&loaded);
}

// ── debugCmp ───────────────────────────────────────────────────────────────

test "debugCmp is identical across a save and a reload, and a one-row change makes it fail" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    var exported = try doc.set.exportColumns(gpa);
    defer exported.deinit(gpa);
    var loaded = try Set.load(gpa, exported.cols, &fixture_actors, encoding, doc.table.asTable());
    defer loaded.deinit();

    // The document holds a map, a list, a text object, a delete and a mark, so
    // the comparison covers every column kind there is.
    // **The gate's own operation, asserted at the fault level too.** A save
    // and a reload has to be the same document *and* both halves have to be
    // internally consistent, and `debugCmp` now checks the second half as
    // well; naming it here is what says the round trip is not resting on the
    // pair comparison alone.
    try testing.expectEqual(@as(?DebugCmpFault, null), try loaded.debugDiff(&doc.set));
    try testing.expectEqual(@as(?DebugCmpFault, null), try doc.set.debugDiff(&loaded));

    try loaded.debugCmp(&doc.set);

    // **A difference must make it fail.** The same document with one row's
    // value changed — the map string at row 4 — and nothing else touched, so
    // the comparator is shown to be looking.
    var other_table = Table.init(gpa);
    defer other_table.deinit();
    var other = try emptySet(gpa, &other_table);
    defer other.deinit();
    {
        const rows = documentRows();
        _ = try other.splice(0, rows[0..4][0..]);
        _ = try other.splice(4, &.{
            rowAt(opId(5, 0), .root, .{ .map = "d" }, false, .set, .{ .str = "kept" }, null, &.{}, true, true),
        });
        _ = try other.splice(5, rows[5..][0..]);
    }
    try testing.expectError(error.Invariant, doc.set.debugCmp(&other));

    // A difference in the **actor table** is caught too, because upstream's
    // `Columns::debug_cmp` does not look at either table and this one does
    // ([op_set.zig](op_set.zig)'s `debugCmp`).
    var bare = try Set.init(gpa, encoding, doc.table.asTable());
    defer bare.deinit();
    try testing.expectError(error.Invariant, doc.set.debugCmp(&bare));
}

test "a comparison of two op sets that differ names which of them is out of row order" {
    // **The invariant: a comparison that cannot say *which* document is wrong
    // sends whoever is debugging it to the wrong document.** Upstream's
    // `debug_cmp` is one bit (`op_set.rs:69-71`) and its `assert_eq!`s
    // (`columns.rs:99-130`) print a column and a row, which is a statement
    // about the *pair* and nothing at all about either side. That is a real
    // cost here, because the two doors to one document — the local
    // transaction path and the apply path — can disagree about where one row
    // goes, and the pair then differs in a column while one of the two is not
    // a document at all.
    //
    // **The fixture is the document with rows 0 and 1 exchanged and nothing
    // else touched.** Those two rows are the counter register `ROOT."a"`: a
    // `set` and the `set` that overwrites it, ids `1@0` and `2@0`, and the
    // first is the delete the second records as its successor. Exchanging
    // them is a permutation *inside one register*, so it cannot disturb any
    // other row, any other register, or the object table.
    const gpa = testing.allocator;
    const good = try Document(gpa);
    defer good.destroy();
    try testing.expect(try good.set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try good.set.validateTopIndex());

    // **The broken one is the *other* side on purpose.** A fault that always
    // said `left` would pass a test that only ever compares a sound document
    // against a broken one in that order.
    var bad_table = Table.init(gpa);
    defer bad_table.deinit();
    var bad = try Set.fromActors(gpa, &fixture_actors, encoding, bad_table.asTable());
    defer bad.deinit();
    {
        const rows = documentRows();
        _ = try bad.splice(0, rows[1..2][0..1]);
        _ = try bad.splice(1, rows[0..1][0..1]);
        _ = try bad.splice(2, rows[2..][0..]);
    }
    // **The same rows in a different order, and both halves of that are
    // checked rather than asserted.** It is the premise of the whole test, and
    // a test that did not establish it would pass for the wrong reason the day
    // the two fixtures drifted apart: the row sequences must differ, and the
    // multisets they sort to must be equal.
    try testing.expectEqual(good.set.len(), bad.len());
    {
        const mine = try rowCtrs(gpa, &good.set);
        defer gpa.free(mine);
        const theirs = try rowCtrs(gpa, &bad);
        defer gpa.free(theirs);
        try testing.expect(!std.mem.eql(u32, mine, theirs));
        std.mem.sort(u32, mine, {}, std.sort.asc(u32));
        std.mem.sort(u32, theirs, {}, std.sort.asc(u32));
        try testing.expectEqualSlices(u32, mine, theirs);
    }
    // Row 1 is the first row that breaks **R3**: it is the register's first
    // row, so `step` compares ids in the same register
    // ([`op.rs:1056-1057`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // and `1@0 > 2@0` is false.
    try testing.expect(!(try bad.validateOpOrder()));
    // **The index is not what is wrong**, and saying so is what makes this a
    // row-order fault rather than a general one: the register still holds both
    // its rows and still has exactly one winner.
    try testing.expectEqual(@as(?TopIndexFault, null), try bad.validateTopIndex());

    // **The answer, and the whole of the change.** Before [`OpSet.debugDiff`]
    // this comparison reported `id_actor differs at row 0` — true, and a
    // statement about the pair that leaves the reader to work out which
    // document is the broken one.
    const fault = (try good.set.debugDiff(&bad)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DebugSide.right, fault.row_order.side);
    try testing.expectEqual(@as(usize, 1), fault.row_order.at);
    // The throwing form is the same answer with the detail thrown away, so a
    // caller that only wants "same or not" is unchanged.
    try testing.expectError(error.Invariant, good.set.debugCmp(&bad));
    // And the side is not an artefact of the argument order.
    const flipped = (try bad.debugDiff(&good.set)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DebugSide.left, flipped.row_order.side);
    try testing.expectEqual(@as(usize, 1), flipped.row_order.at);
    // **A sound document against itself is null, not a fault.** A comparison
    // that reported something here would be reporting its own walk.
    try testing.expectEqual(@as(?DebugCmpFault, null), try good.set.debugDiff(&good.set));
    try good.set.debugCmp(&good.set);
}

/// Every row's op counter, in row order. The caller owns the result.
///
/// **A multiset check sorts a copy of this; a row-order check reads it as it
/// is.** A test about row order has to establish both halves — that the two
/// op sets hold the same rows, and that they do not hold them in the same
/// order — and one helper that returns row order is what lets a test do both
/// from one value.
fn rowCtrs(gpa: Allocator, set: *Set) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    var walk = try set.iter();
    while (try walk.next()) |row| {
        const ctr = std.math.cast(u32, row.opIdCtr()) orelse return error.Overflow;
        try out.append(gpa, ctr);
    }
    return out.toOwnedSlice(gpa);
}

/// The root map's keys, in the order the rows are in — one per register, the
/// winner's.
///
/// **The reader does not sort** ([`map_range.zig:1486-1490`](iter/map_range.zig)),
/// so this is the answer order and nothing else. It is here so a test about row
/// order can show that the order is a *read*, not only a rule a checker
/// enforces.
///
/// The walk is [`OpSet.topOps`] rather than [`OpSet.iter`], because that is
/// what a map walk is: it yields **one row per register** — the winner — and
/// walks them in row order. A raw row walk would yield the losing row of a
/// conflicted register as well, and the answer would then be a statement about
/// the columns rather than about the map.
fn rootKeysInRowOrder(gpa: Allocator, set: *Set) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var winners = try set.topOps(.root, null);
    defer winners.deinit(gpa);
    while (try winners.next()) |row| {
        // A root-map row always has a key: a sequence row carries none, and a
        // root map holds nothing but map rows. A row that did not is a
        // fixture mistake, not a value to compare.
        try out.append(gpa, row.keyStr() orelse return error.MissingKey);
    }
    return out.toOwnedSlice(gpa);
}

/// Two lists of strings, compared one string at a time **by content**.
///
/// Neither [`std.mem.eql`] nor [`testing.expectEqualSlices`] does this: the
/// first compares the elements of a slice with `!=`, which is not defined for
/// a slice, and the second compares them with [`std.meta.eql`], which for a
/// slice is the pointer and the length — so it fails on two lists of the same
/// four bytes at two addresses and passes on two different strings at one
/// address. The same trap [`batch.zig`](batch.zig)'s `eqlLines` is written
/// against, and this is that helper for a list of keys.
fn eqlKeys(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

test "two op sets that hold the same rows in a different order are not the same document" {
    // **The guard on the decision [`OpSet.debugDiff`] makes, and the reason it
    // is not the other way round.** The tempting fix for "the two doors to one
    // document disagree" is to compare the columns by value and stop seeing
    // the disagreement. That would be wrong, and the reason is that the row
    // order is **required**, twice over:
    //
    // * upstream requires it. [`opmod.Op.step`](op.zig) is the row-order
    //   invariant ([`op.rs:1048-1073`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    //   and upstream calls it from exactly one place in the crate — the
    //   `debug_assert!` at the end of `BatchApply::apply`
    //   ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
    //   **The load path does not call it**: `storage/document.rs:351` asserts
    //   `validate_top_index` instead, so upstream never checks the row order of
    //   a document it read from bytes. That gap is the reason this file's
    //   comparison checks it on both sides.
    // * a reader requires it. A map walk does not sort — "the reader does not
    //   sort, so this order is the answer order"
    //   ([`map_range.zig:1486-1490`](iter/map_range.zig)) — and the grouping in
    //   [`OpSet.validateTopIndex`] is per contiguous
    //   `(obj, elemid_or_key)` run, so a permuted object is read as a
    //   different map.
    //
    // **The claim is established by a read, not by a citation.** Rows 2 and 3
    // are `ROOT."b"` and `ROOT."c"`; exchanging them is a permutation of the
    // same twelve rows that leaves every register holding its own rows, so the
    // top index is clean and the *only* thing wrong is that the root's map
    // registers no longer ascend. The map then answers `a, c, b, d` where the
    // sound document answers `a, b, c, d`, which is what "not the same
    // document" means here.
    const gpa = testing.allocator;
    const good = try Document(gpa);
    defer good.destroy();
    const rows = documentRows();

    var table = Table.init(gpa);
    defer table.deinit();
    var swapped = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer swapped.deinit();
    _ = try swapped.splice(0, rows[0..2][0..]);
    _ = try swapped.splice(2, rows[3..4][0..1]);
    _ = try swapped.splice(3, rows[2..3][0..1]);
    _ = try swapped.splice(4, rows[4..][0..]);

    {
        const mine = try rowCtrs(gpa, &good.set);
        defer gpa.free(mine);
        const theirs = try rowCtrs(gpa, &swapped);
        defer gpa.free(theirs);
        try testing.expect(!std.mem.eql(u32, mine, theirs));
        std.mem.sort(u32, mine, {}, std.sort.asc(u32));
        std.mem.sort(u32, theirs, {}, std.sort.asc(u32));
        try testing.expectEqualSlices(u32, mine, theirs);
    }
    try testing.expect(!(try swapped.validateOpOrder()));
    try testing.expectEqual(@as(?TopIndexFault, null), try swapped.validateTopIndex());

    // **The read that differs.** Both documents hold the same four keys and
    // the same four values, and the map answers them in a different order,
    // because the walk does not sort.
    //
    // **Compared by content, not by `expectEqualSlices`.** That helper uses
    // `std.meta.eql`, which for a slice is the pointer and the length, so it
    // would fail on two lists of the same four bytes at different addresses —
    // the trap `batch.zig`'s `eqlLines` is written against.
    {
        const a = try rootKeysInRowOrder(gpa, &good.set);
        defer gpa.free(a);
        const b = try rootKeysInRowOrder(gpa, &swapped);
        defer gpa.free(b);
        try testing.expect(eqlKeys(&.{ "a", "b", "c", "d" }, a));
        try testing.expect(eqlKeys(&.{ "a", "c", "b", "d" }, b));
    }

    // **And so the comparison says they are not the same document, and says
    // why.** A by-value comparison would answer `null` here, and that answer
    // would be a false green over a document that reads as a different map.
    const fault = (try good.set.debugDiff(&swapped)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DebugSide.right, fault.row_order.side);
    try testing.expectEqual(@as(usize, 3), fault.row_order.at);
    try testing.expectError(error.Invariant, good.set.debugCmp(&swapped));
}

test "a comparison that cannot fail is not a comparison" {
    // The one-difference case, at the fault level rather than the error level:
    // **a fault has to name the column and the row**, or it is a boolean with
    // a union around it.
    const gpa = testing.allocator;
    const good = try Document(gpa);
    defer good.destroy();
    const rows = documentRows();

    // **One key changed, from `"d"` to `"e"`, and nothing else touched.** The
    // root's keys are then `a, a, b, c, e`, which still ascends, so both
    // checkers are clean on both sides and the fault can only be about the
    // pair. The key column is compared as a **string** on both sides
    // ([`cmpStrCol`]) and this op set has its own string table, so a
    // comparison of the interned ids would not even be a comparison of the
    // same question.
    var table = Table.init(gpa);
    defer table.deinit();
    var other = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer other.deinit();
    _ = try other.splice(0, rows[0..4][0..]);
    _ = try other.splice(4, &.{
        rowAt(opId(5, 0), .root, .{ .map = "e" }, false, .set, .{ .str = "keep" }, null, &.{}, true, true),
    });
    _ = try other.splice(5, rows[5..][0..]);
    try testing.expect(try other.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try other.validateTopIndex());
    try testing.expect(try good.set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try good.set.validateTopIndex());

    const fault = (try good.set.debugDiff(&other)) orelse return error.TestUnexpectedResult;
    // **`key_str`, row 4** — the first thing wrong, which is the string column
    // and not the value arena behind it.
    try testing.expectEqualStrings("key_str", fault.column.tag);
    try testing.expectEqual(@as(usize, 4), fault.column.at);
    try testing.expectError(error.Invariant, good.set.debugCmp(&other));
    // **The other direction names the same row**, so the diagnostic is not a
    // statement about which side was walked first.
    const flipped = (try other.debugDiff(&good.set)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("key_str", flipped.column.tag);
    try testing.expectEqual(@as(usize, 4), flipped.column.at);
}

test "a top-index fault is a fault about one document, and it names the side" {
    // **The other checker, reached through the same door.** `validateTopIndex`
    // is about a single op set — `first_top == last_vis` per
    // `(obj, elemid_or_key)` group (`op_set.rs:196-212`) — so a fault from it
    // is not a statement about the pair at all, and a comparison that reported
    // it as one would send the reader to the wrong document.
    const gpa = testing.allocator;
    const good = try Document(gpa);
    defer good.destroy();

    // A register with **two** winners: the second row is left `top` alongside
    // the first, which is what a put that recorded no successor edge leaves
    // behind and what the existing "a third put on one register" fixture in
    // this file builds by hand.
    var table = Table.init(gpa);
    defer table.deinit();
    var bad = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer bad.deinit();
    _ = try bad.splice(0, &.{
        rowAt(opId(1, 0), .root, .{ .map = "k" }, false, .set, .{ .int = 1 }, null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "k" }, false, .set, .{ .int = 2 }, null, &.{}, true, true),
    });
    // The row order is right — one register, ids ascending — so this is a
    // top-index fault and **not** a row-order one, which is the discrimination
    // the two cases above between them exists to make.
    try testing.expect(try bad.validateOpOrder());
    const check = (try bad.validateTopIndex()) orelse return error.TestUnexpectedResult;

    const fault = (try bad.debugDiff(&good.set)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(DebugSide.left, fault.top_index.side);
    try testing.expectEqual(check, fault.top_index.fault);
    // And the other side is the sound one, so the fault is not the pair's.
    try testing.expectEqual(@as(?DebugCmpFault, null), try good.set.debugDiff(&good.set));
}

/// How many rows two interned string columns number differently, asserting as
/// it goes that **every row where the ids differ is a row where the strings
/// do not**. That assertion is the premise: the ids differing is the whole of
/// what separates two op sets that hold the same document, and a test that
/// did not check it would pass for the wrong reason the day the two tables
/// happened to agree.
fn internedRows(
    gpa: Allocator,
    mine: *const opcols.UintOptColumn,
    mine_table: *const Table,
    theirs: *const opcols.UintOptColumn,
    theirs_table: *const Table,
) !usize {
    const a = try mine.toSlice(gpa);
    defer gpa.free(a);
    const b = try theirs.toSlice(gpa);
    defer gpa.free(b);
    try testing.expectEqual(a.len, b.len);
    var differing: usize = 0;
    for (a, b) |x, y| {
        if (x == null or y == null) {
            try testing.expectEqual(x == null, y == null);
            continue;
        }
        if (x.? == y.?) continue;
        differing += 1;
        try testing.expectEqualStrings(mine_table.items.items[x.?], theirs_table.items.items[y.?]);
    }
    return differing;
}

/// The same twelve rows, spliced as three blocks in an order that is **not**
/// row order, over a string table of their own.
///
/// **The rows are the document; the order they arrived in is not.**
/// [`columns.Columns.splice`] interns each row's key and mark name in the
/// order the batch hands them over ([columns.zig:994](columns.zig)), so this
/// table numbers the strings differently from [`documentRows`]'s while the
/// columns that come out are the same twelve rows in the same order — every
/// block is spliced at position zero, so each one lands ahead of the last.
///
/// This is the shape a merge has next to a save. `BatchApply` splices one
/// change at a time, so a merged document interns in arrival order, and a
/// document loaded from its own save interns in row order
/// ([columns.zig:1362](columns.zig)).
fn scrambledSet(gpa: Allocator, table: *Table) !Set {
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    errdefer set.deinit();
    const rows = documentRows();
    _ = try set.splice(0, rows[8..12][0..]);
    _ = try set.splice(0, rows[5..8][0..]);
    _ = try set.splice(0, rows[0..5][0..]);
    return set;
}

test "two documents that interned the same vocabulary in different orders are the same document" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    var other_table = Table.init(gpa);
    defer other_table.deinit();
    var other = try scrambledSet(gpa, &other_table);
    defer other.deinit();

    // **The premise, before the comparison.** Both string columns are
    // numbered differently here, and both resolve to the same strings.
    try testing.expect(try internedRows(
        gpa,
        &doc.set.cols.key_str,
        &doc.table,
        &other.cols.key_str,
        &other_table,
    ) > 0);
    try testing.expect(try internedRows(
        gpa,
        &doc.set.cols.mark_name,
        &doc.table,
        &other.cols.mark_name,
        &other_table,
    ) > 0);
    try testing.expectEqual(@as(usize, doc.set.len()), other.len());

    // **The conclusion.** The same rows, the same index, the same object
    // table: the same document.
    try other.debugCmp(&doc.set);
}

test "a mark name numbered differently is still the same mark" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // **A narrower premise than the test above, and a narrower case.** This
    // table has already seen the document's four map keys, so every **key** id
    // agrees with the document's, and it has also seen one string the document
    // never holds (`"decoy"`, in no row of either), so the mark name lands one
    // id higher than the document's. `cmpStrCol`'s key arm cannot see this, and
    // nothing else in `debugCmp` compares a mark name's id.
    var primed_table = Table.init(gpa);
    defer primed_table.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "decoy" }) |name| {
        _ = try Table.intern(&primed_table, name, gpa);
    }
    const rows = documentRows();
    var primed = try Set.fromActors(gpa, &fixture_actors, encoding, primed_table.asTable());
    defer primed.deinit();
    _ = try primed.splice(0, &rows);

    try testing.expectEqual(@as(usize, 0), try internedRows(
        gpa,
        &doc.set.cols.key_str,
        &doc.table,
        &primed.cols.key_str,
        &primed_table,
    ));
    try testing.expect(try internedRows(
        gpa,
        &doc.set.cols.mark_name,
        &doc.table,
        &primed.cols.mark_name,
        &primed_table,
    ) > 0);

    try primed.debugCmp(&doc.set);
}

test "a document spliced a change at a time and the same document reloaded from its save are the same document" {
    const gpa = testing.allocator;

    // The merge-shaped document: the vocabulary reached in arrival order.
    var merge_table = Table.init(gpa);
    defer merge_table.deinit();
    var merged = try scrambledSet(gpa, &merge_table);
    defer merged.deinit();

    // The save-shaped document: the same bytes, loaded over a table of its
    // own, which therefore numbers the strings in row order.
    var exported = try merged.exportColumns(gpa);
    defer exported.deinit(gpa);
    var save_table = Table.init(gpa);
    defer save_table.deinit();
    var reloaded = try Set.load(gpa, exported.cols, &fixture_actors, encoding, save_table.asTable());
    defer reloaded.deinit();

    // **The premise.** The two tables disagree about the numbering, so this is
    // not a document compared with itself in a weaker sense — and this is the
    // round trip the document slice runs, so it is the case that will run next.
    try testing.expect(try internedRows(
        gpa,
        &merged.cols.key_str,
        &merge_table,
        &reloaded.cols.key_str,
        &save_table,
    ) > 0);
    try testing.expectEqual(@as(usize, merged.len()), reloaded.len());

    try reloaded.debugCmp(&merged);
}

test "debugCmp still reports a changed key string, a changed mark name, and one row more" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // **A relaxed comparison is a defect of its own, so each of the three
    // arms is here.** Every one of these documents is the fixture with one
    // thing changed and nothing else touched.

    // A key that is genuinely a different string. Nothing else can catch it:
    // every id, every counter, every index column and the whole value arena
    // agree, because the row is the same row with one word of its key
    // changed. (`cmpStrCol` and nothing else compares this.)
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var other = try emptySet(gpa, &table);
        defer other.deinit();
        const rows = documentRows();
        _ = try other.splice(0, rows[0..4][0..]);
        _ = try other.splice(4, &.{
            rowAt(opId(5, 0), .root, .{ .map = "e" }, false, .set, .{ .str = "keep" }, null, &.{}, true, true),
        });
        _ = try other.splice(5, rows[5..][0..]);
        try testing.expectError(error.Invariant, doc.set.debugCmp(&other));
    }

    // A mark that is genuinely a different name — the other string column.
    // The mark index's cache sees this one too, and it has to: every named
    // mark row is a mark *begin* (`opTypeFromActionAndValue`,
    // `op_set2/types.rs:177-186`) and every begin is in the cache, so no
    // document-level test can separate the two comparisons. What this pins is
    // that the answer is still `error.Invariant`.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var other = try emptySet(gpa, &table);
        defer other.deinit();
        const rows = documentRows();
        _ = try other.splice(0, rows[0..9][0..]);
        _ = try other.splice(9, &.{
            markBegin(opId(10, 0), text_obj, head, "italic", .null_value),
        });
        _ = try other.splice(10, rows[10..][0..]);
        try testing.expectError(error.Invariant, doc.set.debugCmp(&other));
    }

    // One row more: a new map key, spliced into the map's own group.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var other = try emptySet(gpa, &table);
        defer other.deinit();
        const rows = documentRows();
        _ = try other.splice(0, rows[0..5][0..]);
        _ = try other.splice(5, &.{
            rowAt(opId(13, 0), .root, .{ .map = "e" }, false, .set, counter(1), null, &.{}, true, true),
        });
        _ = try other.splice(6, rows[5..][0..]);
        try testing.expectError(error.Invariant, doc.set.debugCmp(&other));
    }
}

test "a difference in slab layout is not a difference in the document" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const rows = documentRows();

    // The same twelve rows, as one splice of twelve against twelve splices of
    // one ([OpSet.fromDocOps] is upstream's `from_doc_ops`, `op_set.rs:1207`).
    // Two different edits, two different code paths, one document.
    var batched = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer batched.deinit();
    _ = try batched.splice(0, &rows);
    var one_at_a_time = try Set.fromDocOps(gpa, &fixture_actors, &rows, encoding, table.asTable());
    defer one_at_a_time.deinit();

    // **The premise, and it is the opposite of what it looks like.** The two
    // sets' encoded columns are **byte-identical**, and that is why the
    // stronger version of this test cannot be written here: the RLE codec is
    // canonical — one run per maximal stretch of equal values and nothing
    // else (`rle/decoder.rs:444-455`) — so the same values have exactly one
    // encoding however they were written, and a slab only splits at the run
    // budget (`column.zig:3139`), which the bytes decide. **There is no pair
    // of op sets in this port that holds the same values and a different
    // encoding**, so the invariant [`cmpCol`] states cannot be staged from the
    // outside; it can only be kept honest by the comparison being over decoded
    // values, which is what this asserts next, on the one pair that is
    // reachable — the same rows written two different ways.
    {
        var a = try batched.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &a);
        var b = try one_at_a_time.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &b);
        var differing: usize = 0;
        for (checkpoint_column_names) |name| {
            if (!std.mem.eql(u8, a.get(name).?, b.get(name).?)) differing += 1;
        }
        try testing.expectEqual(@as(usize, 0), differing);
    }

    // **The conclusion**: [`cmpCol`] reads through `sliceRange`, so the
    // comparison is over values and no layout of them could change its answer.
    try one_at_a_time.debugCmp(&batched);
}

// ── Successor edges, and undoing them ─────────────────────────────────────

/// Every column's encoded bytes, so two checkpoints can be compared name by
/// name ([OpSet.saveCheckpoint]).
fn sameCheckpoint(a: Checkpoint, b: Checkpoint) !void {
    try testing.expectEqual(checkpoint_column_names.len, a.count());
    try testing.expectEqual(checkpoint_column_names.len, b.count());
    for (checkpoint_column_names) |name| {
        const mine = a.get(name) orelse return error.TestUnexpectedResult;
        const theirs = b.get(name) orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, mine, theirs)) {
            std.debug.print("checkpoint column {s} differs\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

/// A two-row counter document: row 0 is a counter, row 1 is a second counter.
/// Both are the whole register, so an edge added to either is visible in the
/// index.
fn counterRows() [2]TestRow {
    return .{
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "b" }, false, .set, counter(2), null, &.{}, true, true),
    };
}

/// A counter document, its checkpoint taken, so a test can undo into it.
fn counterSet(gpa: Allocator, table: *Table) !struct { set: Set, before: Checkpoint } {
    const rows = counterRows();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    errdefer set.deinit();
    _ = try set.splice(0, &rows);
    return .{ .set = set, .before = try set.saveCheckpoint(gpa) };
}

fn freeCheckpointOf(gpa: Allocator, cp: *Checkpoint) void {
    freeCheckpoint(gpa, cp);
}

test "addSuccWithUndo handles a delete, an increment, a re-expose and a no-op, and undo restores the columns" {
    const gpa = testing.allocator;

    // **Case 1 — a plain delete** (`op_set.rs:306-314`). The row stops being
    // visible, loses its text width and loses `top`, and all three are
    // recorded because all three are about to change.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var built = try counterSet(gpa, &table);
        defer built.set.deinit();
        defer freeCheckpointOf(gpa, &built.before);

        try testing.expectEqual(true, (try built.set.cols.index.visible.get(0)).?);
        try testing.expectEqual(true, (try built.set.cols.index.top.get(0)).?);
        try testing.expectEqual(@as(?u32, 1), (try built.set.cols.index.text.get(0)).?);

        const edges = [_]opmod.SuccInsert{.{
            .id = opId(2, 0),
            .pos = 0,
            .inc = null,
            .len = 0,
            .sub_pos = 0,
        }};
        const undo = try built.set.addSuccWithUndo(&edges);
        defer gpa.free(undo);

        // The undo records the three values it is about to overwrite, which is
        // the whole of the case: read them *before* the writes, as
        // `op_set.rs:308-310` does.
        try testing.expectEqual(@as(usize, 1), undo.len);
        try testing.expectEqual(@as(?bool, true), undo[0].visible);
        try testing.expectEqual(@as(??u32, @as(?u32, 1)), undo[0].text);
        try testing.expectEqual(@as(?bool, true), undo[0].top);

        try testing.expectEqual(false, (try built.set.cols.index.visible.get(0)).?);
        try testing.expectEqual(false, (try built.set.cols.index.top.get(0)).?);
        try testing.expectEqual(@as(?u32, null), (try built.set.cols.index.text.get(0)).?);
        try testing.expectEqual(@as(u32, 1), (try built.set.cols.succ_count.get(0)).?);

        try built.set.undoSucc(undo);
        var after = try built.set.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &after);
        try sameCheckpoint(built.before, after);
    }

    // **Case 2 — a plain increment** (`op_set.rs:320-322`). Nothing in the
    // index moves, so the undo records nothing and replaying it is a no-op on
    // all three index columns.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var built = try counterSet(gpa, &table);
        defer built.set.deinit();
        defer freeCheckpointOf(gpa, &built.before);

        const edges = [_]opmod.SuccInsert{.{
            .id = opId(3, 0),
            .pos = 0,
            .inc = 5,
            .len = 0,
            .sub_pos = 0,
        }};
        const undo = try built.set.addSuccWithUndo(&edges);
        defer gpa.free(undo);

        try testing.expectEqual(@as(usize, 1), undo.len);
        try testing.expectEqual(@as(?bool, null), undo[0].visible);
        try testing.expectEqual(@as(??u32, null), undo[0].text);
        try testing.expectEqual(@as(?bool, null), undo[0].top);
        // An increment leaves the row visible and the register's winner.
        try testing.expectEqual(true, (try built.set.cols.index.visible.get(0)).?);
        try testing.expectEqual(true, (try built.set.cols.index.top.get(0)).?);
        try testing.expectEqual(@as(?i64, 5), (try built.set.cols.index.inc.get(0)).?);

        try built.set.undoSucc(undo);
        var after = try built.set.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &after);
        try sameCheckpoint(built.before, after);
    }

    // **Case 3 — an increment onto a row that has just been deleted**
    // (`op_set.rs:315-319`). A counter whose only successor deletes it is
    // dead, but an increment is not a delete, so the row is exposed again and
    // its `top` recorded. The pass runs **backwards**, so the increment has to
    // come *first* in `inserts` to be seen after the delete.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var built = try counterSet(gpa, &table);
        defer built.set.deinit();
        defer freeCheckpointOf(gpa, &built.before);

        const edges = [_]opmod.SuccInsert{
            // index 0: the increment, at the front of the flattened pair.
            .{ .id = opId(3, 0), .pos = 0, .inc = 7, .len = 0, .sub_pos = 0 },
            // index 1: the delete, which the backwards pass meets first.
            .{ .id = opId(4, 0), .pos = 0, .inc = null, .len = 0, .sub_pos = 0 },
        };
        const undo = try built.set.addSuccWithUndo(&edges);
        defer gpa.free(undo);

        try testing.expectEqual(@as(usize, 2), undo.len);
        // The undo list comes out in the pass's own order, which is backwards
        // over `inserts` — so `undo[0]` is the **delete** (`inserts[1]`), the
        // one the pass meets first, and `undo[1]` is the re-expose.
        try testing.expectEqual(@as(?bool, true), undo[0].visible);
        try testing.expectEqual(@as(??u32, 1), undo[0].text);
        try testing.expectEqual(@as(?bool, true), undo[0].top);
        // The re-expose records only `top`, which is the only column it
        // changed, and what it records is the `false` the delete just wrote.
        try testing.expectEqual(@as(?bool, null), undo[1].visible);
        try testing.expectEqual(@as(??u32, null), undo[1].text);
        try testing.expectEqual(@as(?bool, false), undo[1].top);

        // **The re-expose writes `top` and nothing else**
        // (`op_set.rs:319` splices `index.top` alone), so the row is the
        // register's winner again while `visible` stays false — the delete
        // that took it out of view is still in the row's successor list. That
        // is upstream's shape and it is why this case is worth a test: an
        // implementation that "helpfully" also restored `visible` would be
        // wrong.
        try testing.expectEqual(true, (try built.set.cols.index.top.get(0)).?);
        try testing.expectEqual(false, (try built.set.cols.index.visible.get(0)).?);
        try testing.expectEqual(@as(u32, 2), (try built.set.cols.succ_count.get(0)).?);

        try built.set.undoSucc(undo);
        var after = try built.set.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &after);
        try sameCheckpoint(built.before, after);
    }

    // **Case 4 — two increments on one row with no delete anywhere.** The
    // second is a no-op undo (`op_set.rs:320-322`) and the pass's `succ_inc`
    // reaches two, so the row's successor count is its old count plus two.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var built = try counterSet(gpa, &table);
        defer built.set.deinit();
        defer freeCheckpointOf(gpa, &built.before);

        const edges = [_]opmod.SuccInsert{
            .{ .id = opId(4, 0), .pos = 0, .inc = 1, .len = 0, .sub_pos = 0 },
            .{ .id = opId(3, 0), .pos = 0, .inc = 2, .len = 0, .sub_pos = 0 },
        };
        const undo = try built.set.addSuccWithUndo(&edges);
        defer gpa.free(undo);

        try testing.expectEqual(@as(usize, 2), undo.len);
        for (undo) |entry| {
            try testing.expectEqual(@as(?bool, null), entry.visible);
            try testing.expectEqual(@as(??u32, null), entry.text);
            try testing.expectEqual(@as(?bool, null), entry.top);
        }
        try testing.expectEqual(@as(u32, 2), (try built.set.cols.succ_count.get(0)).?);
        // Both edges carry `sub_pos == 0`, which is what a caller computes for
        // the first edge into a row with no successors yet
        // ([op.zig:2027-2038](op.zig)): the pass meets `inserts[1]` first and
        // writes it there, and the second write at the same position goes
        // *behind* it. So the flattened `inc` column reads in the pass's own
        // order, which is the reverse of `inserts`.
        try testing.expectEqual(@as(?i64, 1), (try built.set.cols.index.inc.get(0)).?);
        try testing.expectEqual(@as(?i64, 2), (try built.set.cols.index.inc.get(1)).?);

        try built.set.undoSucc(undo);
        var after = try built.set.saveCheckpoint(gpa);
        defer freeCheckpointOf(gpa, &after);
        try sameCheckpoint(built.before, after);
    }
}

test "addSucc places an edge and takes it away with the same round trip" {
    // The no-undo sibling of the test above, and the reason
    // [`OpSet.addSucc`] and [`OpSet.addSuccWithUndo`] share their four column
    // writes (`op_set.rs:269-276` and `:298-305`): the same edges through the
    // other entry point must land in the same place and come back out the same
    // way.
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var built = try counterSet(gpa, &table);
    defer built.set.deinit();
    defer freeCheckpointOf(gpa, &built.before);

    const edges = [_]opmod.SuccInsert{
        .{ .id = opId(3, 0), .pos = 0, .inc = 5, .len = 0, .sub_pos = 0 },
        .{ .id = opId(4, 0), .pos = 0, .inc = null, .len = 0, .sub_pos = 0 },
    };
    try built.set.addSucc(&edges);
    try testing.expectEqual(@as(u32, 2), (try built.set.cols.succ_count.get(0)).?);
    try testing.expectEqual(false, (try built.set.cols.index.visible.get(0)).?);

    const undo = [_]opmod.SuccUndo{
        .{ .succ = edges[1], .visible = true, .text = 1, .top = true },
        .{ .succ = edges[0], .visible = null, .text = null, .top = false },
    };
    try built.set.undoSucc(&undo);
    var after = try built.set.saveCheckpoint(gpa);
    defer freeCheckpointOf(gpa, &after);
    try sameCheckpoint(built.before, after);
}

// ── Where a new row goes ───────────────────────────────────────────────────

test "queryInsertAt answers at the front, in the middle and at the end, with and without a clock" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // The list holds two elements — row 5 ("y") and row 7 ("X", the
    // overwrite) — so index 0 is the front, index 1 is between them and index
    // 2 is past the last one.
    const list = try doc.set.scopeToObj(list_obj);
    try testing.expectEqual(@as(usize, 5), list.start);
    try testing.expectEqual(@as(usize, 8), list.end);

    // **Index 0**, which takes the general walk directly
    // (`op_set.rs:600-608`) because a prefix descent needs a row in front of
    // the target.
    {
        var q = try doc.set.queryInsertAt(gpa, list_obj, 0, .list, null);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(usize, 5), q.pos);
        try testing.expectEqual(@as(usize, 0), q.index);
        try testing.expect(head.eql(q.elemid));
    }

    // **Index 1**, which takes the prefix descent and then cross-checks it
    // against the general walk (`op_set.rs:584-596`). `queryInsertAt` returns
    // `error.Invariant` if the two disagree, so reaching the end of this block
    // *is* the cross-check passing; it is also made explicit below.
    {
        var q = try doc.set.queryInsertAt(gpa, list_obj, 1, .list, null);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(usize, 6), q.pos);
        try testing.expectEqual(@as(usize, 1), q.index);
        try testing.expect(anchor(opId(7, 0)).eql(q.elemid));
    }

    // **Index 2**, the end.
    {
        var q = try doc.set.queryInsertAt(gpa, list_obj, 2, .list, null);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(usize, 8), q.pos);
        try testing.expectEqual(@as(usize, 2), q.index);
        try testing.expect(anchor(opId(6, 0)).eql(q.elemid));
    }

    // **With a clock.** A clock over the whole document is the present, and
    // the answers must be the same; the general walk is the only path a clock
    // takes (`op_set.rs:600-608`), so this is the cross-check with the fast
    // path on one side and nothing on the other.
    {
        var cover = try fullClock(gpa, 14);
        defer cover.deinit();
        for ([_]usize{ 0, 1, 2 }) |index| {
            var with = try doc.set.queryInsertAt(gpa, list_obj, index, .list, cover);
            defer with.deinit(gpa);
            var without = try doc.set.queryInsertAt(gpa, list_obj, index, .list, null);
            defer without.deinit(gpa);
            try testing.expect(queryNthEqual(with, without));
        }
    }

    // **The fast and the general answer agree**, stated directly rather than
    // only through the `error.Invariant` [`OpSet.queryInsertAt`] raises.
    for ([_]usize{ 1, 2 }) |index| {
        var fast = try doc.set.queryInsertAt(gpa, list_obj, index, .list, null);
        defer fast.deinit(gpa);
        var slow = try doc.set.queryInsertAtSlow(gpa, list_obj, index, .list, null);
        defer slow.deinit(gpa);
        try testing.expect(queryNthEqual(fast, slow));
    }

    // **The text object** takes the other fast path, and the same three
    // positions are the three answers. The text reads "ba" — "b" is row 8 and
    // "a" is row 11, with the mark's two rows between them contributing no
    // width.
    {
        var q = try doc.set.queryInsertAt(gpa, text_obj, 0, .text, null);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(usize, 8), q.pos);
    }
    // **Index 1 is the mark case, and both paths answer `9`.** The rows are
    // row 8 `"b"` (id 12), row 9 the bold begin (id 10), row 10 the bold end
    // (id 11) and row 11 `"a"` (id 9) — the mark's two rows between the two
    // characters, contributing no width of their own.
    //
    // **The `9` is what the reference answers, measured rather than reasoned
    // about.** The oracle's `insertat` subcommand asks the reference through
    // `Transactable::split_block` (`transaction/inner.rs:893-929`), which is
    // `query_insert_at` plus one spliced row, on a text built by the
    // reference's own writer — `"b"`, `"a"`, then
    // `mark(.., Mark::new("bold", true, 1, 1), ExpandMark::Before)` — and the
    // block it splices at index 1 lands **between `"b"` and `"a"`**, which is
    // this fixture's row 9. The oracle is built in a debug profile for that
    // run: `query_insert_at` compares the prefix descent against the general
    // walk on every call (`op_set.rs:583-598`, a `debug_assert_eq!`), so a
    // reference that printed an answer at all printed one both of its own
    // paths hold.
    //
    // **What the walk does here, arm by arm.** `queryInsertAtText` lands
    // `elemidAt` on row 8 and leaves the text cursor past it
    // (`op_set.rs:475-476`), so the runs the scan sees are rows 9 and 10 and
    // both are `None`: both are non-top, and a non-top row's text-index entry
    // is `None` (`columns.rs:478-483`, `if top { Some(width) } else { None }`).
    // The `None` arm (`:506`) does not scan them and `pos` still advances
    // (`:540`); the next run is row 11's `Some(1)`, which is the `_ => break`
    // (`:538`); `found` is empty, so `unwrap_or(pos)` (`:479`) gives row 8 and
    // `pos + 1` (`:488`) gives `9`.
    //
    // **This is what the disagreement was, and it was in the fixture rather
    // than in either path.** [`documentRows`] used to spell the bold end as a
    // **non-insert** row in the begin's own register, which put rows 9 and 10
    // in one element register and made the end top — a `Some(0)` the scan
    // stopped at, whose `End(10)` had no `Start(10)` to truncate because the
    // begin had been stepped over. The fast path then answered `11` against
    // the walk's `9` and `queryInsertAt` raised `error.Invariant`.
    // **That spelling is a shape the reference cannot write**: both halves of
    // a mark are inserts (`inner.rs:827-857`), and `insert_mark_end_after`
    // (`:404-430`) splices the end at `begin.pos + 1` keyed to
    // `ElemId(begin.id)` — an insert, so the end opens its own register. The
    // same fact is recorded for the `doc.zig` hand fixture at
    // `doc.zig:5971-5993`. Spelled the reference's way, the two paths agree
    // on `9`, and `test/upstream_doc_test.zig`'s "inserting text near deleted
    // marks" — where the reference's own `dbg!` (`test.rs:2634`) prints
    // `bold[2,3)` and the text `"aha"` — stays green with
    // [`OpSet.scanForStickyMarks`]'s three arms (`:504-541`) intact.
    {
        var q = try doc.set.queryInsertAt(gpa, text_obj, 1, .text, null);
        defer q.deinit(gpa);
        try testing.expectEqual(@as(usize, 9), q.pos);
    }

    // **An index past the end is the only way a caller learns**
    // ([insert.zig](insert.zig), `insert.rs:136-137`).
    try testing.expectError(error.InvalidIndex, doc.set.queryInsertAt(gpa, list_obj, 9, .list, null));
    try testing.expectError(error.InvalidIndex, doc.set.queryInsertAt(gpa, text_obj, 9, .text, null));
}

// ── Object boundaries ──────────────────────────────────────────────────────

test "iterObjIds yields one boundary per object, and a long object is still one boundary" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // The document has three objects: the root, the list and the text object,
    // and their rows are three contiguous runs.
    {
        // The document has three objects and their rows are three contiguous
        // runs, and `obj_actor` holds actor 0 for the list *and* the text
        // object — so only `obj_ctr` separates them, and the lockstep in
        // [`IterObjIds.next`] is what stops one actor run merging two objects.
        // That is also why the boundary after the root is at 8 and not at 5:
        // the shorter run (`obj_ctr`, 3 rows of the list) is what ends a
        // boundary while the actor run keeps its remainder.
        var boundary_ids = try doc.set.iterObjIds();

        const first = (try boundary_ids.next()).?;
        try testing.expectEqual(@as(usize, 0), first.range.start);
        try testing.expectEqual(@as(usize, 5), first.range.end);
        try testing.expectEqual(ObjId.root, first.id);

        const second = (try boundary_ids.next()).?;
        try testing.expectEqual(@as(usize, 5), second.range.start);
        try testing.expectEqual(@as(usize, 8), second.range.end);
        try testing.expectEqual(list_obj, second.id);

        const third = (try boundary_ids.next()).?;
        try testing.expectEqual(@as(usize, 8), third.range.start);
        try testing.expectEqual(@as(usize, 12), third.range.end);
        try testing.expectEqual(text_obj, third.id);

        try testing.expect((try boundary_ids.next()) == null);

        // And the boundaries are the ranges the object columns themselves
        // give, which is the statement every reader in this file rests on.
        for ([_]ObjId{ .root, list_obj, text_obj }) |obj| {
            const rows = try doc.set.scopeToObj(obj);
            const from_walk = blk: {
                var again = try doc.set.iterObjIds();
                while (try again.next()) |span| {
                    if (span.id.eql(obj)) break :blk span.range;
                }
                return error.TestUnexpectedResult;
            };
            try testing.expectEqual(rows.start, from_walk.start);
            try testing.expectEqual(rows.end, from_walk.end);
        }
    }

    // **A long object is still one boundary.** The lockstep in
    // [`IterObjIds.next`] reads `obj_ctr` and `obj_actor` as two independent
    // run sequences and emits a boundary wherever *either* run ends, at
    // `min(len_ctr, len_actor)` — which is one boundary only because the two
    // runs are both open for the whole object.
    {
        var table = Table.init(gpa);
        defer table.deinit();
        var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
        defer set.deinit();
        const many = 180;
        var i: usize = 0;
        while (i < many) : (i += 1) {
            const key = try std.fmt.allocPrint(gpa, "k{d}", .{i});
            defer gpa.free(key);
            const r = rowAt(
                opId(@intCast(i + 1), 0),
                .root,
                .{ .map = key },
                false,
                .set,
                .{ .str = "v" },
                null,
                &.{},
                true,
                true,
            );
            _ = try set.splice(set.len(), &.{r});
        }
        // **The slab budget is over runs, not rows**
        // ([column.rs:21](../../src/hexane/column.zig)), and every one of
        // these rows is in the root, so `obj_ctr` and `obj_actor` are one run
        // of nulls however many rows there are. What a long run of one value
        // does exercise is the *long* side of the lockstep in
        // [`IterObjIds.next`]: the actor run outlives the counter run by the
        // whole object, so the `.lt` arm is the one that has to keep its
        // remainder, and a boundary is emitted only when the shorter run ends.
        // A column genuinely spread over several slabs is covered by
        // `top_op.zig`'s "a walk over a column spread over several slabs
        // reports the walk's own skips".

        var boundary_ids = try set.iterObjIds();
        var spans: usize = 0;
        while (try boundary_ids.next()) |span| {
            try testing.expectEqual(ObjId.root, span.id);
            try testing.expectEqual(@as(usize, 0), span.range.start);
            try testing.expectEqual(@as(usize, many), span.range.end);
            spans += 1;
        }
        try testing.expectEqual(@as(usize, 1), spans);
    }
}

// ── The empty op set ───────────────────────────────────────────────────────

test "every entry point answers on an op set with no rows" {
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const set = &doc.set;

    try testing.expectEqual(@as(usize, 0), set.len());
    try testing.expectEqual(@as(usize, 0), set.subLen());
    try testing.expect(set.isEmpty());
    try testing.expectEqual(encoding, set.textEncoding());
    try testing.expectEqual(@as(usize, 0), set.actorCount());
    // An object the table has never been told about is a **map**, which is
    // upstream's `unwrap_or(ObjType::Map)` (`op_set.rs:437`, and the same
    // default in `seq_length`); only a *parent* is null, because an object that
    // hangs in nothing is a different question.
    try testing.expectEqual(@as(?ObjType, .map), set.objectType(.root));
    try testing.expectEqual(@as(?ObjId, null), set.objectParent(.root));
    try testing.expectEqual(@as(?Op, null), try set.get(0));
    try testing.expectEqual(@as(?usize, null), try set.getOpIdPos(opId(1, 0)));

    // Every walk over no rows ends immediately rather than trapping.
    var walk = try set.iter();
    try testing.expect((try walk.next()) == null);
    var over_root = try set.iterObj(.root);
    try testing.expect((try over_root.next()) == null);
    var visible_rows = try set.visible(.{ .start = 0, .end = 0 }, null);
    try testing.expect((try visible_rows.next()) == null);
    var values = try set.actionValueIter(.{ .start = 0, .end = 0 }, null);
    try testing.expect((try values.next()) == null);
    var top_values = try set.actionValueTopIter(.{ .start = 0, .end = 0 }, null);
    try testing.expect((try top_values.next()) == null);
    var boundary_ids = try set.iterObjIds();
    try testing.expect((try boundary_ids.next()) == null);
    const objs = try set.iterObjs(gpa);
    defer gpa.free(objs);
    try testing.expectEqual(@as(usize, 0), objs.len);
    var winners = try set.topOps(.root, null);
    while (try winners.next()) |_| {}
    winners.deinit(gpa);

    // Both checkers pass on nothing: an empty document satisfies every rule.
    try testing.expect(try set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // The ranges are empty at zero rather than past the end.
    const root_rows = try set.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), root_rows.start);
    try testing.expectEqual(@as(usize, 0), root_rows.end);
    const key_rows = try set.propRange(.root, "a");
    try testing.expectEqual(@as(usize, 0), key_rows.start);
    try testing.expectEqual(@as(usize, 0), key_rows.end);
    const span_rows = try set.mapRange(
        .root,
        .{ .included = "a" },
        .{ .excluded = "z" },
    );
    try testing.expectEqual(@as(usize, 0), span_rows.start);
    try testing.expectEqual(@as(usize, 0), span_rows.end);
    try testing.expect(try set.allOfRangeIsTop(.{ .start = 0, .end = 0 }));
    try testing.expectEqual(@as(usize, 0), try set.seqLength(.root, encoding, null));
    try testing.expectEqual(@as(?ElemPos, null), try set.elemidAt(0, 0));

    // The readers answer with nothing, and the text readers with empty bytes.
    const text_bytes = try set.text(gpa, .root, null);
    defer gpa.free(text_bytes);
    try testing.expectEqual(@as(usize, 0), text_bytes.len);
    const marks = try set.calculateMarks(gpa, .root);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 0), marks.len);
    var mark_set = try set.getMarks(gpa, .root, 0);
    defer mark_set.deinit();
    try testing.expectEqual(@as(usize, 0), mark_set.entries.items.len);
    const open = try set.markSetAt(gpa, 0, null);
    try testing.expect(open == null);

    // An insertion point in an empty sequence is the only refusal, and it is
    // the documented one.
    try testing.expectError(error.InvalidIndex, set.queryInsertAt(gpa, .root, 1, .list, null));

    // The mutations are no-ops that answer rather than trap, and the setters
    // that have nothing to write still run.
    try testing.expectEqual(@as(usize, 0), try set.splice(0, &.{}));
    try set.spliceObjects(&.{});
    try set.addSucc(&.{});
    const undo = try set.addSuccWithUndo(&.{});
    defer gpa.free(undo);
    try testing.expectEqual(@as(usize, 0), undo.len);
    try set.undoSucc(undo);
    try set.resetTop(.{ .start = 0, .end = 0 });
    try testing.expectError(error.InvalidValue, set.conflict(0));
    try testing.expectError(error.InvalidValue, set.expose(0));
    try set.rebuildIndex();

    // A rebuild of nothing installs an index of nothing, and the checkers
    // still pass over it.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());
    try testing.expectEqual(@as(usize, 0), set.cols.index.top.len());
    try testing.expectEqual(@as(usize, 0), set.cols.index.visible.len());

    // The seek readers answer with an empty register rather than failing.
    {
        var by_key = try set.seekOpsByMapKey(gpa, .root, "a", null);
        defer by_key.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), by_key.ops.items.len);
    }
    {
        var by_index = try set.seekOpsByIndex(gpa, .root, 0, .list, null);
        defer by_index.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), by_index.ops.items.len);
    }
    try testing.expect((try set.findOpByIdAndVis(opId(1, 0), null)) == null);
    try testing.expect((try set.parentObject(made(1, 0), null)) == null);
    const diff = try set.getIncrementDiffAtPos(0, .{ .current = null });
    try testing.expectEqual(@as(i64, 0), diff.before);
    try testing.expectEqual(@as(i64, 0), diff.after);
}

// ── Bounding a map key range ────────────────────────────────────────────────

/// The fixture this test reads: the root map's four registers over rows
/// `0..5`, and the object's own rows are exactly those.
///
/// `documentRows` puts two rows in `ROOT."a"` (`op_set.zig:4454-4459`) and one
/// row in each of `"b"`, `"c"` and `"d"`, so the register table is
/// `a 0..2`, `b 2..3`, `c 3..4`, `d 4..5`. **Every bound below is read off
/// that table and not off the number of keys**, because the rows behind a key
/// are what a bound moves across: a `?[]const u8` implementation would pass
/// every case here that names four one-row registers and fail on `a`.
const root_registers = [_]struct { key: []const u8, rows: [2]usize }{
    .{ .key = "a", .rows = .{ 0, 2 } },
    .{ .key = "b", .rows = .{ 2, 3 } },
    .{ .key = "c", .rows = .{ 3, 4 } },
    .{ .key = "d", .rows = .{ 4, 5 } },
};

test "the four bound arms are four row ranges, and a key the map does not hold sorts" {
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();

    // **The premise, from the table and not from the walk**: the root's rows
    // are `0..5` and each register is where the table says. A test whose
    // expected answers came from the same function it is testing would pass
    // for the wrong reason the day the fixture changed.
    {
        const obj_rows = try doc.set.scopeToObj(.root);
        try testing.expectEqual(@as(usize, 0), obj_rows.start);
        try testing.expectEqual(@as(usize, 5), obj_rows.end);
        for (root_registers) |reg| {
            const rows = try doc.set.propRange(.root, reg.key);
            try testing.expectEqual(reg.rows[0], rows.start);
            try testing.expectEqual(reg.rows[1], rows.end);
        }
    }

    // **A key the map does not hold answers the row it would sort at**
    // (`column.rs:958-1000`, hexane's own test at
    // [`hexane/src/tests.rs:3464-3476`](../../github-automerge-automerge/rust/hexane/src/tests.rs)
    // gives `2..2` for `"aab"` over `aaa aaa bbb bbb bbb ccc`). `"aa"` sorts
    // between `"a"` and `"b"`, `"cc"` between `"c"` and `"d"`, and neither
    // register moves: this is a walk of the key column, so the answer is one
    // past the last row whose key sorts **below** the probe.
    //
    // **`"z"` and `"zz"` are the case that hides the defect**, and they are
    // here for that reason: both answer `5..5`, which is right, because the
    // object's end *is* where a key above every register sorts. A reader that
    // answered the object's end for every absent key passes those two and
    // fails the two before them.
    const Absent = struct { key: []const u8, at: usize };
    const absent = [_]Absent{
        .{ .key = "A", .at = 0 }, // above nothing: `"A" < "a"`
        .{ .key = "aa", .at = 2 },
        .{ .key = "bb", .at = 3 },
        .{ .key = "cc", .at = 4 },
        .{ .key = "z", .at = 5 },
        .{ .key = "zz", .at = 5 },
    };
    for (absent) |case| {
        const rows = try doc.set.propRange(.root, case.key);
        try testing.expectEqual(case.at, rows.start);
        try testing.expectEqual(case.at, rows.end);
    }

    // **Upstream's four arms, arm for arm** (`op_set.rs:406-416`). A null bound
    // is the object range; an `included` start is the register's `.start` and
    // an `excluded` start is its `.end`; an `included` end is the register's
    // `.end` and an `excluded` end is its `.start`. **The pairing is inverted
    // between the two ends**, and that asymmetry is the whole reason a pair of
    // optional keys could not stand in for a `RangeBounds` — `Included("c")`
    // and `Excluded("c")` name ranges three rows apart.
    const Arm = struct {
        start: ?KeyBound,
        end: ?KeyBound,
        want: [2]usize,
        what: []const u8,
    };
    const arms = [_]Arm{
        // The two `Unbounded` arms: the whole object.
        .{ .start = null, .end = null, .want = .{ 0, 5 }, .what = "unbounded .. unbounded" },
        .{ .start = null, .end = .{ .included = "c" }, .want = .{ 0, 4 }, .what = "unbounded ..=c" },
        .{ .start = null, .end = .{ .excluded = "c" }, .want = .{ 0, 3 }, .what = "unbounded ..<c" },
        .{ .start = .{ .included = "b" }, .end = null, .want = .{ 2, 5 }, .what = "b.. unbounded" },
        // **The same start, the other arm**: `b` is one row, so the two
        // differ by exactly that register.
        .{ .start = .{ .excluded = "b" }, .end = null, .want = .{ 3, 5 }, .what = ">b .. unbounded" },
        // **`included` and `excluded` over the same two keys**, which is the
        // pair a both-inclusive implementation cannot pass.
        .{
            .start = .{ .included = "b" },
            .end = .{ .included = "d" },
            .want = .{ 2, 5 },
            .what = "b..=d",
        },
        .{
            .start = .{ .included = "b" },
            .end = .{ .excluded = "d" },
            .want = .{ 2, 4 },
            .what = "b..<d",
        },
        // **`a` is two rows**, so a bound that resolved to the key's *first*
        // row rather than its register's ends differently here than anywhere
        // else in the table.
        .{
            .start = .{ .included = "a" },
            .end = .{ .included = "a" },
            .want = .{ 0, 2 },
            .what = "a..=a",
        },
        .{
            .start = .{ .included = "a" },
            .end = .{ .excluded = "a" },
            .want = .{ 0, 0 },
            .what = "a..<a",
        },
        .{
            .start = .{ .excluded = "a" },
            .end = .{ .included = "d" },
            .want = .{ 2, 5 },
            .what = ">a..=d",
        },
        // **A bound the map does not hold**, at both ends, and both arms: the
        // sorted point is one row, so `included` and `excluded` are the **same**
        // answer here — the difference between the two arms is the register
        // that is named, and there is none.
        .{
            .start = .{ .included = "aa" },
            .end = .{ .included = "cc" },
            .want = .{ 2, 4 },
            .what = "aa..=cc",
        },
        .{
            .start = .{ .included = "aa" },
            .end = .{ .excluded = "cc" },
            .want = .{ 2, 4 },
            .what = "aa..<cc",
        },
        // **A start at or past its end is empty**, not reversed: upstream's
        // `start..end` is a Rust `Range` and carries no rows under that
        // condition (`map_range.rs:204-208`).
        .{
            .start = .{ .included = "d" },
            .end = .{ .included = "a" },
            .want = .{ 4, 4 },
            .what = "start past its end",
        },
        .{
            .start = .{ .included = "b" },
            .end = .{ .included = "b" },
            .want = .{ 2, 3 },
            .what = "start equal to its end",
        },
    };
    for (arms) |arm| {
        const rows = try doc.set.mapRange(.root, arm.start, arm.end);
        testing.expectEqual(arm.want[0], rows.start) catch |e| {
            std.debug.print("mapRange {s}: start {d}, wanted {d}\n", .{
                arm.what, rows.start, arm.want[0],
            });
            return e;
        };
        testing.expectEqual(arm.want[1], rows.end) catch |e| {
            std.debug.print("mapRange {s}: end {d}, wanted {d}\n", .{
                arm.what, rows.end, arm.want[1],
            });
            return e;
        };
    }
}

// ── The borrowed successor buffer ──────────────────────────────────────────

test "a row's successors point into the op set's buffer, and the next walk overwrites them" {
    const gpa = testing.allocator;

    // Two rows, each with successors, so the overwrite is visible as a
    // *different successor* rather than as a null.
    const succs_a = [_]SuccEntry{ .{ .id = opId(90, 0), .inc = null }, .{ .id = opId(91, 0), .inc = null } };
    const succs_b = [_]SuccEntry{.{ .id = opId(80, 0), .inc = null }};
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &succs_a, false, false),
        rowAt(opId(2, 0), .root, .{ .map = "b" }, false, .set, counter(2), null, &succs_b, true, true),
    };
    var table = Table.init(gpa);
    defer table.deinit();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);

    // The first walk's row reads its own successors.
    var first_walk = try set.iter();
    const first = (try first_walk.next()).?;
    // Kept alive across the second walk on purpose: the point of the test is
    // what this row reads afterwards.
    try testing.expectEqual(@as(usize, 0), first.pos);
    {
        var edges = first.succ();
        try testing.expectEqual(@as(?OpId, opId(90, 0)), edges.next());
        try testing.expectEqual(@as(?OpId, opId(91, 0)), edges.next());
        try testing.expectEqual(@as(?OpId, null), edges.next());
    }

    var second_walk = try set.iter();
    _ = try second_walk.next(); // row 0, whose window the first walk also used
    const second = (try second_walk.next()).?;
    try testing.expectEqual(@as(usize, 1), second.pos);
    {
        // **The rule, stated so it does not depend on which value the
        // overwrite leaves behind**: the row's first successor is no longer the
        // one the columns held when it was read, because a walk over the same
        // op set has rewritten the shared buffer
        // ([op_set.zig](op_set.zig)'s module doc, "The rule that follows").
        var check = first.succ();
        const now = check.next();
        try testing.expectEqual(@as(usize, 2), check.len());
        if (now) |id| try testing.expect(!id.eql(opId(90, 0)));
    }

    // **And a mutation refits the buffer**, so a row that arrives with more
    // successors than it holds can never answer `error.TooLarge`
    // ([op_iter.zig:988](op_iter.zig)). One row of the document already has
    // two successors and the buffer is exactly two wide, so the assertion
    // below is that the width tracks `maxSuccCount` and not the number of
    // rows.
    const widest = try opiter.maxSuccCount(TestRow, &set.cols, .{
        .start = 0,
        .end = set.len(),
    });
    try testing.expectEqual(widest, set.succ_scratch.items.len);

    // **And the documented way out**: a walk built over a buffer of its own
    // does not disturb the op set's, so two walks can be live at once. This is
    // the construction the module doc names — `opiter.maxSuccCount` for the
    // width and `opiter.OpIter.init` for the walk — and it is what
    // [`OpSet.topOps`] does with a [`top_op.TopScratch`] of its own.
    //
    // The rule is checked by reading the op set's buffer either side of the
    // second walk rather than against a value from before the *first* one,
    // because the first walk already clobbered it.
    const own = try gpa.alloc(SuccEntry, try opiter.maxSuccCount(TestRow, &set.cols, .{
        .start = 0,
        .end = set.len(),
    }));
    defer gpa.free(own);
    var third_walk = try opiter.OpIter(TestRow).init(&set.cols, table.asTable(), .{
        .start = 0,
        .end = set.len(),
    }, own);
    const before_own = readTwo(first);
    {
        const third = try third_walk.next();
        try testing.expectEqual(@as(usize, 0), third.?.pos);
    }
    const after_own = readTwo(first);
    try testing.expect(std.meta.eql(before_own[0], after_own[0]));
    try testing.expect(std.meta.eql(before_own[1], after_own[1]));

    // **The op set's buffer is the op set's**, and its width is
    // `maxSuccCount` rather than the row count, so a row that arrives with more
    // successors than the buffer holds can never answer `error.TooLarge`
    // ([op_iter.zig:988](op_iter.zig)). One row here has two successors and the
    // buffer is exactly two wide.
    try testing.expectEqual(
        try opiter.maxSuccCount(TestRow, &set.cols, .{ .start = 0, .end = set.len() }),
        set.succ_scratch.items.len,
    );
}

/// The first two ids a row's borrowed successor cursor yields, so a test can
/// compare a row's successors either side of something.
fn readTwo(row_: Op) [2]?OpId {
    var cursors = row_.succ();
    return .{ cursors.next(), cursors.next() };
}

/// The rows a pinned index column keeps, so a walk is compared against the
/// literals the fixture declares rather than against itself.
fn keptRowsOf(comptime N: usize, flags: *const [N]bool, gpa: Allocator) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (flags, 0..) |f, i| if (f) try out.append(gpa, i);
    return out;
}

test "every skip-filtered walk reaches the end of its window and answers null there" {
    // **Every skipper gives one more answer after the last kept row**
    // ([`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
    // and that answer is the distance from the last kept row to the end of the
    // window — which is a skip of **zero** whenever the last row is kept, as
    // the last row of this document is ([`column.zig:4143-4145`](../hexane/column.zig)).
    //
    // So a walk is asked for a row one past its end on every run, and a walk
    // whose step is *total* would raise `error.MissingValue` there where
    // upstream returns `None` ([`tools.takeAt`](../../iter/tools.zig) is where
    // the zero-skip arm is kept honest). The three walks here are the only
    // ones in the tree that reach it.
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();
    const whole = RowRange{ .start = 0, .end = doc.set.len() };
    var want_vis = try keptRowsOf(want_visible.len, &want_visible, gpa);
    defer want_vis.deinit(gpa);
    var want_tops = try keptRowsOf(want_top.len, &want_top, gpa);
    defer want_tops.deinit(gpa);

    {
        // The filter over a row cursor: its skip is a walk, and this is the
        // only one of the three that applies a second rule on top of the
        // cheap column ([`visible.rs:165-192`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/visible.rs)),
        // so `want_visible` is an over-approximation of its rows and not their
        // oracle. What matters here is the end of the window; the row set is
        // `visible.zig`'s own statement and is not repeated.
        var rows = try doc.set.visible(whole, null);
        while (try rows.next()) |_| {}
        try testing.expect((try rows.next()) == null);
        try testing.expect((try rows.next()) == null);
    }
    {
        // The pair of cursors, whose step is *total* — the case a zero skip
        // must not be answered by. Its rows are exactly the cheap column's,
        // because `ActionValueIter` applies no second rule.
        var rows = try doc.set.actionValueIter(whole, null);
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try rows.next()) |item| try got.append(gpa, item.pos);
        try testing.expectEqualSlices(usize, want_vis.items, got.items);
        try testing.expect((try rows.next()) == null);
        try testing.expect((try rows.next()) == null);
    }
    {
        // The top walk, whose skipper is the prefix column the index is built
        // from, so `want_top` is its oracle exactly.
        var rows = try doc.set.actionValueTopIter(whole, null);
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try rows.next()) |item| try got.append(gpa, item.pos);
        try testing.expectEqualSlices(usize, want_tops.items, got.items);
        try testing.expect((try rows.next()) == null);
        try testing.expect((try rows.next()) == null);
    }
}

test "an action-value walk is repositioned by shifting it, and both halves move together" {
    // Six of the eight `Shiftable` names, over the op set's own
    // `ActionValueIter`. **The other two — `shift` and `seekTo` — are not
    // here because the walk underneath them does not compile when they are
    // called**: `op_iter.ValueIter.shift` ([`op_iter.zig:863-865`](op_iter.zig))
    // discards a `ParseError`, and `op_iter.ActionValueIter.seekTo`
    // ([`op_iter.zig:1129-1135`](op_iter.zig)) applies `orelse` to two *total*
    // `tryNth`s. Both are one-line fixes in a file this slice does not own; both
    // are named in the handoff. Until they are made, the `shiftable` mark on
    // `ActionValueIter` ([`op_iter.zig:1075`](op_iter.zig)) is a claim about the
    // eight *names* and nothing more, which is all `column.Shiftable` checks
    // ([`column.zig:4006-4026`](../hexane/column.zig)).
    const gpa = testing.allocator;
    const doc = try Document(gpa);
    defer doc.destroy();
    const whole = RowRange{ .start = 0, .end = doc.set.len() };
    var rows = try doc.set.actionValueIter(whole, null);

    try testing.expectEqual(@as(usize, 0), rows.pos());
    try testing.expectEqual(@as(usize, doc.set.len()), rows.maxPos());

    // `shiftNext` is the one repositioning a `SkipIter` supports: the skipper
    // says how far into the range the first kept row is and the walk is asked
    // for that row ([`iter/tools.rs:165-172`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    // Every row from 1 on is visible, so the first kept row of [5, 8) is 5 —
    // and the cursor is left **one past** it, which is what `pos` is
    // ([`shift.rs:20-22`](../../github-automerge-automerge/rust/hexane/src/shift.rs),
    // and the same off-by-one as `ActionValue.pos`).
    try testing.expectEqual(@as(usize, 5), (try rows.shiftNext(.{ .start = 5, .end = 8 })).?.pos);
    try testing.expectEqual(@as(usize, 6), rows.pos());
    try testing.expectEqual(@as(usize, 8), rows.maxPos());

    // `setMax` truncates the window and `advanceTo`/`advanceBy` move the
    // position, and each says where it left the walk
    // ([`shift.rs:26-27`, `:34-47`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
    rows.setMax(7);
    try testing.expectEqual(@as(usize, 7), rows.maxPos());
    try rows.advanceBy(1);
    try testing.expectEqual(@as(usize, 7), rows.pos());
    // A target behind the walk is a no-op, which is what makes the moves above
    // composable.
    try rows.advanceTo(3);
    try testing.expectEqual(@as(usize, 7), rows.pos());

    // A second shift puts both halves back in step and reads the new range's
    // first kept row.
    try testing.expectEqual(@as(usize, 9), (try rows.shiftNext(.{ .start = 9, .end = 10 })).?.pos);
    try testing.expectEqual(@as(usize, 10), rows.pos());
    try testing.expectEqual(@as(usize, 10), rows.maxPos());
    // A window past the end of the op set is a defined answer, not an error.
    try testing.expect((try rows.shiftNext(.{ .start = 12, .end = 16 })) == null);
}

// ── The object index ────────────────────────────────────────────────────────

test "every action that makes an object reaches the index, and a rebuild finds the same three" {
    const gpa = testing.allocator;
    const doc = try TwoActors(gpa);
    defer doc.destroy();

    // Four rows in the root, in ascending key order, of which three make an
    // object and one does not. `make_list`, `make_text` and `make_map` are the
    // three actions `ObjType::try_from` accepts
    // (`op_set2/types.rs:135-146`; the port's `Action::objType`,
    // [`value.zig:196-204`](../value.zig)), so all three and only those three
    // may claim an entry.
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, .{ .str = "plain" }, null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "list" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(3, 0), .root, .{ .map = "map" }, false, .make_map, .null_value, null, &.{}, true, true),
        rowAt(opId(4, 0), .root, .{ .map = "text" }, false, .make_text, .null_value, null, &.{}, true, true),
    };
    _ = try doc.set.splice(0, &rows);

    // The three claims, each with **both** of the index's answers. A count of
    // three beside three `objectType` answers is what says the index is not
    // holding anything else: the root has no entry and is still answered, and
    // the `set` row's id is not an object.
    try testing.expectEqual(@as(usize, 3), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(2, 0)));
    try testing.expectEqual(@as(?ObjType, .map), doc.set.objectType(made(3, 0)));
    try testing.expectEqual(@as(?ObjType, .text), doc.set.objectType(made(4, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(2, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(3, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(4, 0)));
    // The root is a map and hangs in nothing, with no entry of its own.
    try testing.expectEqual(@as(?ObjType, .map), doc.set.objectType(.root));
    try testing.expectEqual(@as(?ObjId, null), doc.set.objectParent(.root));
    // An op that made nothing claims nothing, in either direction.
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(made(1, 0)));
    try testing.expectEqual(@as(?ObjId, null), doc.set.objectParent(made(1, 0)));

    // **The other door into the same index.** A splice claims an object from
    // the op (`OpSet::splice_objects`, `op_set.rs:232-238`) and a rebuild
    // derives it from the rows it walks
    // ([`indexmod.IndexBuilder.processOp`](index.zig):610-612), so a document
    // that arrives with no stored index has to come back with the same three
    // answers. `splice` trusts the op and `rebuildIndex` recomputes, and this
    // is the test that holds the two to each other.
    try doc.set.rebuildIndex();
    try testing.expectEqual(@as(usize, 3), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(2, 0)));
    try testing.expectEqual(@as(?ObjType, .map), doc.set.objectType(made(3, 0)));
    try testing.expectEqual(@as(?ObjType, .text), doc.set.objectType(made(4, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(2, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(3, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(4, 0)));
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(made(1, 0)));
    try testing.expectEqual(@as(usize, 4), doc.set.len());
}

test "a register the fast index seek finds stays inside the object it is in" {
    // **The invariant: the fast seek's register and the reference walk's
    // register are rows of one object.** [`OpSet.listRegisterAtPos`] asks the
    // `insert` column for the row of the register's own insert
    // (`op_set.rs:696`), and that question has no answer when the register has
    // no insert before it — upstream's answer is row 0 of the whole op set
    // (`get_index_for_prefix(0)` is `0`, `prefix.rs:605-608`, and
    // `get_index_for_total` subtracts one, `:596-598`).
    //
    // A list whose **first** row is a `set` hung by the head is exactly that,
    // and the write path cannot build one: `TxOp::list`'s key comes from
    // `Op::cursor` on a row that already exists (`inner.rs:510-514`,
    // `op.rs:1073-1082`), so the head is a key only for a row that is already
    // there. The document is still one a load accepts, and the fast path has
    // to answer it the way `iter_obj` plus the grouper does
    // (`op_set.rs:663-666`).
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const list = made(1, 0);
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), list, .{ .seq = head }, false, .set, .{ .str = "x" }, null, &.{}, true, true),
    };
    _ = try doc.set.splice(0, &rows);

    // The object is row 1 alone, so a register that starts at row 0 is
    // handing back **the root's own map put** — a row of another object,
    // with another object's key and another object's width.
    const obj_range = try doc.set.scopeToObj(list);
    try testing.expectEqual(@as(usize, 1), obj_range.start);
    try testing.expectEqual(@as(usize, 2), obj_range.end);
    const register = try doc.set.listRegisterAtPos(1, obj_range);
    try testing.expectEqual(@as(usize, 1), register.start);
    try testing.expectEqual(@as(usize, 2), register.end);

    // **Both answers, side by side, in every build.** The gated cross-check is
    // what found this and it is off by default, so a comparison that runs
    // without it is what keeps it found. `opsFoundEqual` is the same function
    // the gate calls, so this is the gate's comparison and not a copy of it.
    var fast = try doc.set.seekListOpsByIndexFast(gpa, list, 0);
    defer fast.deinit(gpa);
    var slow = try doc.set.seekOpsByIndexSlow(gpa, list, 0, .list, null);
    defer slow.deinit(gpa);
    try testing.expect(opsFoundEqual(fast, slow));
    try testing.expectEqual(@as(usize, 1), fast.ops.items.len);
    try testing.expectEqual(@as(usize, 1), fast.ops.items[0].pos);
    // And the object reads as the one element it holds, so the register that
    // was too wide is not answered correctly and compensated for later.
    try testing.expectEqual(@as(usize, 1), try doc.set.seqLength(list, .unicode_code_point, null));
}

test "interning an actor renumbers the objects the index already holds" {
    const gpa = testing.allocator;
    const doc = try TwoActors(gpa);
    defer doc.destroy();
    // The fixture holds two actors and the rows below are written against one
    // of them, so drop the other first: an interned actor no row names is
    // exactly what `removeUnusedActors` is for
    // ([`automerge.rs:446-455`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and the test then has a one-actor table to renumber.
    try doc.set.removeActor(1);
    try testing.expectEqual(@as(usize, 1), doc.set.actorCount());

    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "list" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), made(1, 0), .{ .seq = head }, true, .set, .{ .str = "a" }, null, &.{}, true, true),
    };
    _ = try doc.set.splice(0, &rows);
    try testing.expectEqual(@as(usize, 1), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(1, 0)));

    // An actor interned **in the middle** of the table
    // ([`OpSet.insertActor`], `op_set.rs:1400-1405`) renumbers every actor
    // index at or above it, so the object the rows made moves with them — and
    // the index has to move the entry's key *and* the parent in its value
    // ([`ObjSet.rewriteWithNewActor`], `op_set.rs:1407-1417`; upstream
    // `ObjIndex(… .map(|(id, make)| (id.with_new_actor(idx), make.with_new_actor(idx)))`).
    // A key moved and a parent left behind would make the walk ask about the
    // object under an id nothing answers.
    try doc.set.insertActor(0, .{ .bytes = "aaab" });

    try testing.expectEqual(@as(usize, 2), doc.set.actorCount());
    try testing.expectEqual(@as(usize, 1), doc.set.obj_info.count());
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(made(1, 0)));
    try testing.expectEqual(@as(?ObjId, null), doc.set.objectParent(made(1, 0)));
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(1, 1)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(1, 1)));
    // The row that hangs in it moved with it, so the index and the rows still
    // agree about which object the element belongs to.
    try testing.expect((try doc.set.get(1)).?.objId().eql(made(1, 1)));
    try testing.expect((try doc.set.get(0)).?.objId().eql(.root));
}

test "removing an actor renumbers the objects that survive it and forgets the identity it had" {
    const gpa = testing.allocator;
    const doc = try TwoActors(gpa);
    defer doc.destroy();
    // Every row is actor `1`'s, so **no column names actor `0`** and the
    // removal is the one `removeActor` can do: `cols.rewriteWithoutActor`
    // refuses an actor the columns still name (`columns.rs:355-357`; this
    // file's [`OpSet.removeActor`] for why the port rewrites first where
    // upstream drops the actor and panics, `op_set.rs:1419-1429`).
    const rows = [_]TestRow{
        rowAt(opId(1, 1), .root, .{ .map = "list" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 1), made(1, 1), .{ .seq = head }, true, .set, .{ .str = "a" }, null, &.{}, true, true),
    };
    _ = try doc.set.splice(0, &rows);
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(1, 1)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(1, 1)));
    try testing.expectEqual(@as(usize, 1), doc.set.obj_info.count());

    try doc.set.removeActor(0);

    // **Both halves of every entry move.** The key is the op that made the
    // object and the value holds the parent, and upstream maps both
    // (`ObjIndex(… .map(|(id, make)| (id.with_new_actor(idx), make.with_new_actor(idx)))`,
    // `op_set.rs:1407-1417`; the removal is the same with `without_actor`,
    // `:1419-1429`).
    try testing.expectEqual(@as(usize, 1), doc.set.actorCount());
    try testing.expectEqual(@as(usize, 1), doc.set.obj_info.count());
    // The id the removed actor's identity named is not an object any more.
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(made(1, 1)));
    try testing.expectEqual(@as(?ObjId, null), doc.set.objectParent(made(1, 1)));
    // The id that replaced it names the same object, and the row that used to
    // hang in it hangs in it still.
    try testing.expectEqual(@as(?ObjType, .list), doc.set.objectType(made(1, 0)));
    try testing.expectEqual(@as(?ObjId, .root), doc.set.objectParent(made(1, 0)));
    try testing.expect((try doc.set.get(1)).?.objId().eql(made(1, 0)));
    try testing.expectEqual(@as(usize, 2), doc.set.len());
}

// ── The mark walk ───────────────────────────────────────────────────────────

/// The text object two of the mark-walk tests share: `"ab"` under a root list
/// that holds one element, with a mark over the whole of it.
///
/// **The counters are spread out, and that is the point of the fixture.** The
/// marked text is op 5 and the mark is ops 16 and 17 — eleven and twelve
/// counters later — because a mark's index is an *op-counter* word derived
/// from its own id ([`Op.markIndex`](op.zig)), while the walk steps in *row*
/// order and counts widths in *sequence* order. A fixture that put the mark at
/// the counter of the text it marks would agree with a walk that confused any
/// two of those three spaces. `doc.zig`'s sample document spreads them for
/// real: its mark is three counters past the `set` it marks.
fn markedTextRows() [6]TestRow {
    const list = made(1, 0);
    const txt = made(2, 0);
    return .{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null, &.{}, true, true),
        // **The text object does not start the column**, so the whole-column
        // prefix at its first row is not zero — three, in fact: `index.text`
        // measures *every* row as text whether or not the row is in a text
        // object (`index.rs:193-194`), so each of the two root `make_*` rows
        // is one wide as well as the list's element. A text object at the top
        // of the column would make the two prefix spaces agree by accident.
        rowAt(opId(3, 0), list, .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, true, true),
        // The mark opens at the head of the text and closes after the element
        // it covers, so the rows are 16, 5, 17: a head insert sorts *before*
        // the element it displaces, and the mark's begin is the higher
        // counter of the two head inserts ([`Op.step`]'s R4,
        // `op_set2/op.rs:1061-1063`).
        markBegin(opId(16, 0), txt, head, "bold", .{ .bool_value = true }),
        rowAt(opId(5, 0), txt, .{ .seq = head }, true, .set, .{ .str = "ab" }, null, &.{}, true, true),
        markEnd(opId(17, 0), txt, anchor(opId(5, 0))),
    };
}

test "a mark over two graphemes is one run, at the object's own indices" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &markedTextRows());
    try testing.expect(try set.validateOpOrder());
    // **The top index too, and this is the check that makes the fixture's
    // `top` and `visible` columns a claim rather than a convenience.** Upstream
    // asserts `validate_top_index` where a document is loaded
    // ([`storage/document.rs:351`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
    // and its `first_top == last_vis` per group ([`op_set.rs:196`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
    // is what says a mark row is the winner of its own register. **Measured on
    // this fixture with [`markBegin`] writing a `top` of false: `group_mismatch
    // { at = 4, first_top = null, last_vis = 3 }`** — and the two arms then
    // answered `bold` and nothing, which is what the cross-checks under
    // [`check_slow_paths`](op_set.zig) caught. A fixture that the reference
    // cannot load cannot be held to its answer, so the precondition is
    // asserted here where the default build can see it too.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // **The reference agrees with what is asserted here**, measured rather
    // than read: `mark(0, 2)` over a two-grapheme text answers one mark,
    // `bold`, `Boolean(true)`, `start = 0`, `end = 2`.
    const marks = try set.calculateMarks(gpa, made(2, 0));
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqualStrings("bold", marks[0].name);
    try testing.expect(marks[0].value == .bool_value);
    try testing.expectEqual(true, marks[0].value.bool_value);
    // **The object's own indices, not the column's.** `"ab"` is two code
    // points under [`encoding`], so the run is `[0, 2)` whatever the list
    // element before the object contributed.
    try testing.expectEqual(@as(usize, 0), marks[0].start);
    try testing.expectEqual(@as(usize, 2), marks[0].end);
    try testing.expectEqual(@as(usize, 2), try set.seqLength(made(2, 0), encoding, null));

    // **The other reader, asked the other question.** [`OpSet.getMarks`] is
    // `mark_index.richTextAt` reached through one prefix descent
    // (`op_set.rs:1031-1035`): it answers for a *position*, where
    // `calculateMarks` answers for a *range walked*. Both answer here, and the
    // standing distinction in `docs/STATUS.md` is that they are not
    // interchangeable — so this asserts both rather than one standing in for
    // the other.
    var open_at_one = try set.getMarks(gpa, made(2, 0), 1);
    defer open_at_one.deinit();
    try testing.expectEqual(@as(usize, 1), open_at_one.numMarks());
    try testing.expectEqualStrings("bold", open_at_one.entries.items[0].name);
    // And past the end it is an empty set rather than a failure
    // (`op_set.rs:1032-1034`).
    var past = try set.getMarks(gpa, made(2, 0), 2);
    defer past.deinit();
    try testing.expectEqual(@as(usize, 0), past.numMarks());
}

test "a mark that is un-marked leaves nothing, and the pairing is the negation" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const txt = made(1, 0);
    // The same shape with an **unmark** over the same span, which is what the
    // reference answers `marks() == 0` to — measured, not read: `mark(0, 1)`
    // then `unmark("bold", 0, 1)` on a two-grapheme text.
    //
    // **The unmark's begin is the *higher* counter, so it opens first in row
    // order** — both are head inserts and a head insert sorts before the
    // element it displaces. The walk therefore meets the unmark before the
    // mark it removes. Each end's index is derived from its own id's
    // predecessor, so op 21 closes op 20 and op 11 closes op 10 and nothing
    // else ([`Op.markIndex`](op.zig)), which is what makes the two ends
    // distinguishable at all.
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null, &.{}, true, true),
        markBegin(opId(20, 0), txt, head, "bold", .null_value),
        markBegin(opId(10, 0), txt, head, "bold", .{ .bool_value = true }),
        rowAt(opId(5, 0), txt, .{ .seq = head }, true, .set, .{ .str = "ab" }, null, &.{}, true, true),
        markEnd(opId(21, 0), txt, anchor(opId(5, 0))),
        markEnd(opId(11, 0), txt, anchor(opId(5, 0))),
    };
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);
    try testing.expect(try set.validateOpOrder());
    // The same check on this fixture's own rows — the unmark is a second mark
    // begin in the same object, which is a register the top index sees too.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // The text is still there and still two wide: what the unmark removed is
    // the mark, not the sequence. Without this the assertion below would also
    // pass on a walk that found nothing at all.
    try testing.expectEqual(@as(usize, 2), try set.seqLength(txt, encoding, null));
    const body = try set.text(gpa, txt, null);
    defer gpa.free(body);
    try testing.expectEqualStrings("ab", body);

    const marks = try set.calculateMarks(gpa, txt);
    defer gpa.free(marks);
    // An unmark is a tombstone, not a mark: it is dropped on the way out
    // (`op_set.rs:1023`), and while it is open it *shadows* the mark beneath
    // it, so neither run reaches the accumulator.
    try testing.expectEqual(@as(usize, 0), marks.len);

    // The position reader agrees, and for its own reason: the mark set at a
    // position is resolved through the same state machine and comes back
    // empty because the open set is only unmarks.
    var at_zero = try set.getMarks(gpa, txt, 0);
    defer at_zero.deinit();
    try testing.expectEqual(@as(usize, 0), at_zero.numMarks());
}

test "a mark still open when the object's rows run out runs to the end of that object" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const list = made(1, 0);
    const txt = made(2, 0);
    // **The mark is opened and never closed**, which is the only state that
    // reaches the walk's closing line — upstream's `:1017-1022`, the block
    // that exists for a mark still open when the object's rows run out.
    //
    // It is a state the port loads and answers for rather than refuses:
    // [`MarkOrderValidator`](index.zig) inspects mark **end** rows and nothing
    // else (`op_set2/op_set/index.rs:58-73`), so a document whose mark begin
    // has no end is not one of the two it rejects. The end's index is derived
    // from the begin's id rather than from the begin's row
    // ([`Op.markIndex`](op.zig)), so a begin on its own is simply a mark this
    // walk never closes — and how far it runs is the question this pins.
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null, &.{}, true, true),
        rowAt(opId(3, 0), list, .{ .seq = head }, true, .set, .{ .str = "x" }, null, &.{}, true, true),
        markBegin(opId(40, 0), txt, head, "bold", .{ .bool_value = true }),
        rowAt(opId(5, 0), txt, .{ .seq = head }, true, .set, .{ .str = "ab" }, null, &.{}, true, true),
    };
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);
    try testing.expect(try set.validateOpOrder());
    // And here: a mark opened and never closed is one register with one row, so
    // it is the case where a wrong `top` has no second row to hide behind.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());
    // The mark-order check the loader runs is run here too, so this fixture is
    // a document the port has rather than one it refuses to hold.
    var ordered = indexmod.MarkOrderValidator.init(gpa);
    defer ordered.deinit();
    {
        var every_row = try set.iter();
        while (try every_row.next()) |row| try ordered.processOp(row);
    }
    try indexmod.checkMarkOrder(&ordered);

    const marks = try set.calculateMarks(gpa, txt);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqualStrings("bold", marks[0].name);
    try testing.expect(marks[0].value == .bool_value);
    // **Two, not five.** The whole column's prefix at the object's last row is
    // five — the two root `make_*` rows and the list's element are one wide
    // each, and `"ab"` is two — while the object's own width is two. Upstream's
    // closing line is `text.get_prefix(range.end) - base` (`op_set.rs:1018`)
    // and its `base` is that same whole-column prefix at the object's *first*
    // row (`:976`), so the two cancel to the object's own width. Subtracting
    // anything else — the walk's own zero included — reports the mark running
    // on past the end of the object by everything the column holds before it,
    // which for a text object late in a long document is most of the document.
    try testing.expectEqual(@as(usize, 0), marks[0].start);
    try testing.expectEqual(@as(usize, 2), marks[0].end);
}

test "building the mark walk allocates nothing; the fold that follows it does" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &markedTextRows());

    // **The root's rows hold no mark, but the document's mark index is
    // populated**, so `hasAnyMarks` does not short-circuit and the whole walk
    // is built: the scope descent, the text index's prefix cursor, the mark
    // index's cursor, the accumulator and the query state. A walk is a value
    // and building one asks for nothing.
    var counting: Counting = .{ .inner = gpa };
    const none = try set.calculateMarks(counting.allocator(), .root);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectEqual(@as(usize, 0), counting.count);

    // And the fold *does* allocate once there is a mark to fold, so the count
    // above is about the construction and not about a walk that never ran.
    const one = try set.calculateMarks(counting.allocator(), made(2, 0));
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expect(counting.count > 0);
}

test "the indexed arm of the mark fold runs only when there is no clock" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    // **The op set's own allocator is the instrument, and that is the whole
    // trick.** The two arms differ in what they read — two indexes against a
    // walk of the rows — and the walk is the one that needs buffers, which
    // [`OpSet.topOps`] takes from `self.gpa` rather than from the allocator the
    // caller handed down. So on one document and through one entry point, a read
    // with no clock costs this counter **zero in the default build and exactly
    // one walk in the `-Dslow-path` build**, where a read with a clock costs one
    // walk either way. **A change that made the walk unconditional would fail
    // the assertion that says so**, which is the only way to catch it: the two
    // arms answer the same present, so nothing else can tell them apart. The
    // arithmetic is spelled out where the counts are taken.
    const txt = made(1, 0);
    var counting: Counting = .{ .inner = gpa };
    // **Two writes to one element, and the first is superseded.** That is what
    // gives the object a row with a successor, which is what
    // [`op_iter.maxSuccCount`](op_iter.zig) counts and what decides whether
    // [`top_op.topScratch`](top_op.zig) allocates at all: the walk's three
    // buffers are `alloc(SuccEntry, n)`, and **a zero-length allocation never
    // reaches an allocator's vtable**, so the counter is only an instrument if
    // some row in the object has a successor. Both arms answer `[0, 2)` either
    // way, because `index.text` is only ever read on a *top* row
    // ([`index.zig`:579-582](index.zig)) and the superseded row is not one.
    //
    // **The superseded row is also not visible**, and that is derived rather
    // than chosen: `visible` is `succ == 0` ([`index.zig`:666-675](index.zig),
    // `index.rs:230`), and one successor that is not an increment never brings
    // the count back down — the port pins the same case on a `set` row in
    // [index.zig:1201-1205](index.zig). Leaving it visible made the walk pair
    // it with the winner as a conflict ([`top_op.TopOps.next`](top_op.zig)'s
    // `top_op.rs:50-56`), which a mark fold never reads and a reader would.
    const supersede = [_]SuccEntry{.{ .id = opId(6, 0), .inc = null }};
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, null, &.{}, true, true),
        markBegin(opId(16, 0), txt, head, "bold", .{ .bool_value = true }),
        rowAt(opId(5, 0), txt, .{ .seq = head }, true, .set, .{ .str = "a" }, null, &supersede, false, false),
        rowAt(opId(6, 0), txt, .{ .seq = anchor(opId(5, 0)) }, true, .set, .{ .str = "ab" }, null, &.{}, true, true),
        markEnd(opId(17, 0), txt, anchor(opId(6, 0))),
    };
    var set = try Set.fromActors(counting.allocator(), &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);
    try testing.expect(try set.validateOpOrder());
    // The same check on this fixture, and here the row that carries it is the
    // superseded one: `visible` is `succ == 0`
    // ([`index.zig`:666-675](index.zig)), so a row the second write replaces is
    // a group with no top row and no visible row, which is the one shape
    // `validate_top_index` allows (`op_set.rs:196` compares two nulls).
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // **What the counter reads is walks, and under `-Dslow-path` the
    // cross-check is itself one.** [`OpSet.calculateMarksAt`] compares the two
    // arms behind [`check_slow_paths`](op_set.zig) — upstream's own
    // `assert_eq!(fast, slow, "indexed marks != walked marks")`
    // ([`automerge.rs:1587-1591`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — and the arm it compares against is [`OpSet.calculateMarksSlow`], which
    // **is** the walk. So a no-clock read runs one walk when the gate is on
    // and none when it is off, where a clocked read runs exactly one either
    // way. **A zero here is only the answer in the build with no cross-check**,
    // and asserting one under the other would be asserting that the gate does
    // not run — which is the assertion this test must not make.
    const no_clock_cost = blk: {
        const before = counting.count;
        const runs = try set.calculateMarksAt(gpa, txt, null);
        defer gpa.free(runs);
        try testing.expectEqual(@as(usize, 1), runs.len);
        try testing.expectEqual(@as(usize, 0), runs[0].start);
        try testing.expectEqual(@as(usize, 2), runs[0].end);
        break :blk counting.count - before;
    };

    // **And the same document, the same object and a clock**, which is upstream's
    // `calculate_marks_slow` (`:1595`). The clock covers every operation, so the
    // answer is the same one — **and the walk is visibly the thing that ran.**
    var clock = try Clock.init(gpa, 1);
    defer clock.deinit();
    try clock.isolate(0);
    const walk_cost = blk: {
        const before = counting.count;
        const runs = try set.calculateMarksAt(gpa, txt, clock);
        defer gpa.free(runs);
        try testing.expectEqual(@as(usize, 1), runs.len);
        try testing.expectEqual(@as(usize, 0), runs[0].start);
        try testing.expectEqual(@as(usize, 2), runs[0].end);
        break :blk counting.count - before;
    };
    // **A walk is not free, and that is what makes it countable.** The walk's
    // three buffers are `alloc(SuccEntry, n)` each
    // ([`top_op.topScratch`](top_op.zig)), and `n` is one here because the
    // fixture has the superseded row the comment above this test describes —
    // which is the whole reason that row is in it. **Every count is read
    // against this number rather than against a literal**, because a literal
    // would pin `topScratch`'s buffer count as well as the dispatch, and only
    // the dispatch is the subject here.
    try testing.expect(walk_cost > 0);
    // **What is pinned is the dispatch, not the cross-check**: the cost a
    // no-clock read adds is **zero without the gate and exactly one walk with
    // it**, where a dispatch that took the walk unconditionally would add one
    // walk's worth without the gate and two with it, and a dispatch that took
    // the index arm unconditionally would leave `walk_cost` at zero. Both were
    // measured: the second fails here on `expect(walk_cost > 0)`, the first on
    // the `else` arm below. **This is strictly stronger than "the counter did
    // not move"**, which said nothing under the gate at all.
    //
    // **And the one thing this instrument cannot see, stated rather than left
    // to be found.** Under `-Dslow-path` both reads cost exactly one walk
    // whatever the dispatch chose, because the cross-check runs the other arm
    // anyway — that is arithmetic, not a gap in the count — so there, a
    // dispatch that took the index arm **with a clock** (dropping `c == null`
    // from [`OpSet.calculateMarksAt`]) is invisible here. It is caught by the
    // default build, which is where this test earns its keep for it; what a
    // historical read costs is another fixture's subject, and upstream's rule
    // that the index arm is the present only (`automerge.rs:1584-1585`) is the
    // reason.
    try testing.expectEqual(
        if (check_slow_paths) walk_cost else @as(usize, 0),
        no_clock_cost,
    );

    // **The fast path is still reachable and still the indexed one**, which is
    // what [`OpSet.calculateMarks`] is for. **The callers left on that entry
    // point are the two in `transact.zig`** (`transact.zig:2102`, `:2117`):
    // `Document.marks`, the `hydrate.zig` text fold and `read.zig` all reach it
    // through [`OpSet.calculateMarksAt`] with a clock, and the dispatch is what
    // picks the arm. **A second unscoped read costs exactly what the first
    // did** — the walk's buffers are freed before it returns, so the counter is
    // left where the first read left it and a repeat must not move it again.
    const repeat = blk: {
        const before = counting.count;
        const runs = try set.calculateMarksAt(gpa, txt, null);
        defer gpa.free(runs);
        try testing.expectEqual(@as(usize, 1), runs.len);
        break :blk counting.count - before;
    };
    try testing.expectEqual(no_clock_cost, repeat);
}

test "a list takes the walk with no clock present, and a list element is one wide" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const list = made(1, 0);
    // **One list, one element of three code points, one mark over it.** The
    // element's width is what tells the two arms apart: `OpBuilder::width`
    // answers `SequenceType::List => 1` and
    // `SequenceType::Text => encoding.width(self.as_str())` (`op.rs:204-210`),
    // so the walk says the mark covers one position and the text index — which
    // measures every row as text, text object or not (`index.rs:193-194`) —
    // would say three. Upstream never lets that happen, because
    // `calculate_marks` takes the indexed arm only for a text object
    // (`automerge.rs:1585`) and its own comment gives the reason: "the text
    // index carries text widths, so lists still take the walk below".
    // **Both mark rows are top, which is what the index builds and what this
    // test is here to exercise.** A list has no text index widths to measure
    // against, so this is the one document that *must* be read by the row walk
    // — and a row walk reads `index.top` ([`top_op.TopIter`](top_op.zig)'s
    // `Current` flavour, `top_op.rs:212-215`), so a mark begin the helpers
    // spelled as not-top would leave the fold with no begin to close. The
    // helpers now say what the builder derives (see [`markBegin`]), and this
    // fixture no longer has to write the rows out to correct them.
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        markBegin(opId(16, 0), list, head, "bold", .{ .bool_value = true }),
        rowAt(opId(5, 0), list, .{ .seq = head }, true, .set, .{ .str = "xyz" }, null, &.{}, true, true),
        markEnd(opId(17, 0), list, anchor(opId(5, 0))),
    };
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);
    try testing.expect(try set.validateOpOrder());
    // The same check on this fixture, which is the one document that *must* be
    // read by a row walk: a row walk reads `index.top`, so a mark row the
    // fixture spelled as not-top would leave the fold with no begin.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // **One, not three** — and this is a read with **no clock at all**, so the
    // only thing that can have chosen the walk is the object type.
    const runs = try set.calculateMarksAt(gpa, list, null);
    defer gpa.free(runs);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("bold", runs[0].name);
    try testing.expectEqual(@as(usize, 0), runs[0].start);
    try testing.expectEqual(@as(usize, 1), runs[0].end);

    // **And the indexed arm on the same object is where the two disagree**,
    // which is the reason the rule has two halves and not one. Measured on
    // this fixture: it answers `end = 3`, because it measures the run against
    // the text index's width for the element. Upstream never reaches that call
    // for a list (`automerge.rs:1585`), so this is not a defect the port has —
    // **it is what the object type in the dispatch is there to prevent.**
    const indexed = try set.calculateMarks(gpa, list);
    defer gpa.free(indexed);
    try testing.expectEqual(@as(usize, 1), indexed.len);
    try testing.expectEqual(@as(usize, 0), indexed[0].start);
    try testing.expectEqual(@as(usize, 3), indexed[0].end);
}

// ── Taking a row back out ──────────────────────────────────────────────────

test "splicing a range and removing it again leaves every column byte-identical" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();

    const first = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "a" }, false, .set, counter(1), null, &.{}, true, true),
    };
    try testing.expectEqual(@as(usize, 1), try set.splice(0, &first));
    var before = try set.saveCheckpoint(gpa);
    defer freeCheckpointOf(gpa, &before);

    const added = [_]TestRow{
        rowAt(opId(2, 0), .root, .{ .map = "b" }, false, .set, counter(2), null, &.{}, true, true),
        rowAt(opId(3, 0), .root, .{ .map = "c" }, false, .set, counter(3), null, &.{}, true, true),
    };
    try testing.expectEqual(@as(usize, 2), try set.splice(1, &added));
    try testing.expectEqual(@as(usize, 3), set.len());

    // The order a rollback walks is **reverse** (`inner.rs:214`), and it is not
    // decoration: row 2's position only means what it means while row 1 is
    // still there.
    var undo_c = try opmod.TxOp.map(
        gpa,
        opId(3, 0),
        ObjMeta.root(),
        2,
        .{ .visible_update = .{ .put = counter(3) } },
        "c",
        &.{},
    );
    defer undo_c.deinit(gpa);
    var undo_b = try opmod.TxOp.map(
        gpa,
        opId(2, 0),
        ObjMeta.root(),
        1,
        .{ .visible_update = .{ .put = counter(2) } },
        "b",
        &.{},
    );
    defer undo_b.deinit(gpa);
    try set.undoOp(&undo_c);
    try set.undoOp(&undo_b);

    try testing.expectEqual(@as(usize, 1), set.len());
    var after = try set.saveCheckpoint(gpa);
    defer freeCheckpointOf(gpa, &after);
    // **The mirror claim, asserted from the side that was never asserted.**
    // `Columns::splice` and `Columns::removeOps` are each other's inverse by
    // construction (`columns.rs:419-492` against `:361-417`), and until this
    // test only the forward half had a test that could fail.
    try sameCheckpoint(before, after);

    // `saveCheckpoint` carries twenty columns and `index.top` is not one of
    // them (`checkpoint_column_names`, `:559-563`), so the one column the
    // checkpoint cannot speak for is read here.
    try testing.expectEqual(true, (try set.cols.index.top.get(0)).?);
    try testing.expectEqual(@as(?u32, 1), (try set.cols.index.text.get(0)).?);
}

test "undoOp instantiates over OpSet(ChangeOp), the one op set a document holds" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    // `Set` is `OpSet(TestRow)`, and a `TestRow` and a `ChangeOp` are different
    // types with different `cols`. An instantiation is per type parameter, so
    // the test above does **not** cover this one.
    const ChangeSet = OpSet(opmod.ChangeOp);
    var set = try ChangeSet.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();

    var r0 = try opmod.ChangeOp.init(
        gpa,
        opId(1, 0),
        .root,
        .set,
        .{ .map = "a" },
        counter(1),
        false,
        false,
        null,
        &.{},
    );
    defer r0.deinit(gpa);
    var r1 = try opmod.ChangeOp.init(
        gpa,
        opId(2, 0),
        .root,
        .set,
        .{ .map = "b" },
        counter(2),
        false,
        false,
        null,
        &.{},
    );
    defer r1.deinit(gpa);
    const rows = [_]opmod.ChangeOp{ r0, r1 };
    try testing.expectEqual(@as(usize, 2), try set.splice(0, &rows));
    try testing.expectEqual(@as(usize, 2), set.len());

    var undo = try opmod.TxOp.map(
        gpa,
        opId(2, 0),
        ObjMeta.root(),
        1,
        .{ .visible_update = .{ .put = counter(2) } },
        "b",
        &.{},
    );
    defer undo.deinit(gpa);
    try set.undoOp(&undo);
    try testing.expectEqual(@as(usize, 1), set.len());
    try testing.expectEqual(true, (try set.cols.index.top.get(0)).?);
}

// ── The overwrite rule ──────────────────────────────────────────────────────

/// One successor edge onto the register row at `pos`
/// (`Op::add_succ`, `op_set2/op.rs:956-977`).
///
/// **Read from the columns rather than from a walked row, and that is not a
/// shortcut.** [`opmod.Op.addSucc`] reads the row's *existing* successors, and
/// every walk over the op set shares the one successor buffer
/// ([`OpSet.refitScratch`](op_set.zig)), so a row the walk has already moved
/// past no longer holds them. [`succInsert`] is the same edge with the
/// coordinates taken from `succ_count`, which is a column and outlives the
/// walk.
fn edgeOnto(set: *const Set, pos: usize, id: OpId) !opmod.SuccInsert {
    const len = (try set.cols.succ_count.get(pos)) orelse return error.Overflow;
    return try succInsert(set, pos, id, null, len);
}

/// One local `put` on a root map key, at the level this file can reach:
/// upstream's `insert_local_op`
/// ([`transaction/inner.rs:308-329`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// which is splice the row, then record the edges.
///
/// **The order is upstream's and it is load-bearing.** The row goes in first,
/// because an edge names a row position and the new row shifts the ones after
/// it (`:317-319`); the edges go on second, because they are the predecessor
/// rows losing (`:319`).
///
/// `preds` are the row positions the put **sees**, which is the question the
/// whole overwrite-versus-conflict rule turns on
/// ([`op_set.rs:1489-1508`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)):
/// every predecessor it names records the new operation as a successor, and a
/// predecessor whose edge carries no increment is taken out of the index
/// ([`op_set.rs:306-314`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
/// **A `put` has no increment value**, so `inc` is null and the predecessor is
/// demoted — the branch upstream spells `i.inc.is_none()` covers a delete and
/// a put alike. An empty `preds` is a **concurrent** put: the operation was
/// made without seeing the register it lands beside.
fn localPut(
    gpa: Allocator,
    set: *Set,
    key: []const u8,
    val: ScalarValue,
    id: OpId,
    preds: []const usize,
) !void {
    var query = try set.seekOpsByMapKey(gpa, .root, key, null);
    defer query.deinit(gpa);
    // `op_set.rs:1489-1508` — the decision a put makes before it writes
    // anything. Every value these fixtures write is distinct from the one the
    // register holds, so this is always a visible update; the other arm is a
    // put that repeats the register's value, which writes no row at all.
    switch (query.resolveAction(.{ .put = val }) orelse return) {
        .visible_update => {},
        .conflict_resolution => return error.TestUnexpectedResult,
    }

    const succ = try gpa.alloc(opmod.SuccInsert, preds.len);
    defer gpa.free(succ);
    for (preds, succ) |pos, *slot| slot.* = try edgeOnto(set, pos, id);

    const register = try set.propRange(.root, key);
    const row = rowAt(id, .root, .{ .map = key }, false, .set, val, null, &.{}, true, true);
    _ = try set.splice(register.end, &.{row});
    const undo = try set.addSuccWithUndo(succ);
    gpa.free(undo);
}

/// How many of the register's rows are `top`, and how many are `visible`.
///
/// **Counts, not values, and the reason is the defect this file had.** A
/// reader can be handed the right value while the index behind it says
/// something else; that is what happened while [`OpSet.visible`] thinned the
/// row walk by *visible* rows rather than by *row* counts, and the value was
/// right only because the register was empty. The counts are the property a
/// value read cannot check for itself.
fn registerIndex(set: *const Set, key: []const u8) !struct { top: usize, visible: usize } {
    const rows = try set.propRange(.root, key);
    var tops = try set.topIndexRange(rows);
    var top: usize = 0;
    while (try tops.next()) |t| {
        if (t) top += 1;
    }
    var seen = try set.cols.index.visible.iterRange(rows);
    var visible: usize = 0;
    while (try seen.next()) |v| {
        if (v) visible += 1;
    }
    return .{ .top = top, .visible = visible };
}

test "a put that overwrites the register is the register's only row, and its value is the one a reader gets" {
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const set = &doc.set;

    try localPut(gpa, set, "k", .{ .int = 1 }, opId(1, 0), &.{});
    try expectRegisterValue(gpa, set, "k", 1);

    // **The second put sees the first, so it overwrites it** — one row left,
    // carrying the second value. A reader that reports the register empty here
    // has lost the only row a reader is entitled to see.
    try localPut(gpa, set, "k", .{ .int = 2 }, opId(2, 0), &.{0});
    try expectRegisterValue(gpa, set, "k", 2);

    // And the third, which demotes the second the same way. **The
    // demotion is the part that was missing:** without it the register holds
    // two `top` rows, [`OpSet.validateTopIndex`] names the disagreement, and
    // the *fourth* put — one that did see the register — would find a winner
    // that is not there.
    try localPut(gpa, set, "k", .{ .int = 3 }, opId(3, 0), &.{1});
    try expectRegisterValue(gpa, set, "k", 3);

    try testing.expectEqual(@as(usize, 3), set.len());
    try testing.expect(try set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());
}

/// [`localPut`] with the predecessors the register itself reports, which is
/// upstream's `local_map_op` and nothing more
/// ([`inner.rs:477-481`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
/// the rows a put overwrites are the rows its read returned.
fn putOverRegister(
    gpa: Allocator,
    set: *Set,
    key: []const u8,
    val: ScalarValue,
    id: OpId,
) !void {
    var query = try set.seekOpsByMapKey(gpa, .root, key, null);
    defer query.deinit(gpa);
    const preds = try gpa.alloc(usize, query.ops.items.len);
    defer gpa.free(preds);
    for (query.ops.items, preds) |row, *slot| slot.* = row.pos;
    try localPut(gpa, set, key, val, id, preds);
}

test "a third put on one register demotes the second, and the index names the one that is left" {
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const set = &doc.set;

    // Three ordinary puts, each finding the register the last one left. This
    // is the whole of `local_map_op`, and it is why a broken register read is
    // a write bug and not only a read bug: a put that finds nothing has no
    // predecessor to record itself on, and the row it did overwrite is still
    // marked as the register's winner.
    try putOverRegister(gpa, set, "k", .{ .int = 1 }, opId(1, 0));
    try putOverRegister(gpa, set, "k", .{ .int = 2 }, opId(2, 0));
    try putOverRegister(gpa, set, "k", .{ .int = 3 }, opId(3, 0));

    // **The index-level statement, and the one a value read cannot make for
    // itself.** Upstream's own checker: within one `(obj, key)` group the
    // first `top` row is the last `visible` row
    // ([`op_set.rs:196-212`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
    // A third put that recorded no edge leaves the second put's row `top`
    // alongside its own, and that is `final_group_mismatch`.
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());
    const after = try registerIndex(set, "k");
    try testing.expectEqual(@as(usize, 1), after.top);
    try testing.expectEqual(@as(usize, 1), after.visible);
    try testing.expectEqual(@as(usize, 3), set.len());
    try expectRegisterValue(gpa, set, "k", 3);
    try testing.expect(try set.validateOpOrder());
}

/// The one row the register `key` holds, and the value it carries.
///
/// A register with more than one row is a conflict, and a register with none
/// is a key the reader cannot find — both are answers this helper refuses
/// rather than reports, because the tests that call it are about which value
/// one row carries.
fn expectRegisterValue(
    gpa: Allocator,
    set: *Set,
    key: []const u8,
    want: i64,
) !void {
    var found = try set.seekOpsByMapKey(gpa, .root, key, null);
    defer found.deinit(gpa);
    if (found.ops.items.len != 1) return error.TestUnexpectedResult;
    try testing.expectEqual(want, found.ops.items[0].value().int);
}

test "an overwrite leaves the register one winner and one visible row" {
    const gpa = testing.allocator;
    const doc = try Empty(gpa);
    defer doc.destroy();
    const set = &doc.set;

    try localPut(gpa, set, "k", .{ .int = 1 }, opId(1, 0), &.{});
    try testing.expectEqual(@as(usize, 1), (try registerIndex(set, "k")).top);
    try testing.expectEqual(@as(usize, 1), (try registerIndex(set, "k")).visible);

    try localPut(gpa, set, "k", .{ .int = 2 }, opId(2, 0), &.{0});
    try localPut(gpa, set, "k", .{ .int = 3 }, opId(3, 0), &.{1});

    // **The counts, over three rows of one register.** The overwritten rows
    // keep their place in the op set — that is what a successor edge is — and
    // leave `top` and `visible` behind. One of each left is the whole of
    // `validate_top_index`'s assertion (`op_set.rs:196-212`), said here in a
    // form that cannot pass by accident.
    const after = try registerIndex(set, "k");
    try testing.expectEqual(@as(usize, 1), after.top);
    try testing.expectEqual(@as(usize, 1), after.visible);
    try testing.expectEqual(@as(usize, 3), set.len());
}

test "a put that does not see the register conflicts with it instead of overwriting it" {
    const gpa = testing.allocator;
    const doc = try TwoActors(gpa);
    defer doc.destroy();
    const set = &doc.set;

    try localPut(gpa, set, "k", .{ .int = 1 }, opId(1, 0), &.{});
    // **No successor edge, from a second actor.** This is the half of a merge
    // that did not see the other half, and it is the case that keeps the
    // conflict rule honest: an overwrite is "the second put saw the first",
    // and nothing here says it did.
    try localPut(gpa, set, "k", .{ .int = 2 }, opId(1, 1), &.{});

    // The winner is recomputed over the register rather than declared by the
    // fixture: this is what a scoped transaction's `insert_local_op` does
    // (`inner.rs:321-324`) and what the merge walkers do with `conflict` and
    // `expose` (`batch.rs:942-946`). Both rows arrive as writers; exactly one
    // leaves as the winner.
    try set.resetTop(try set.propRange(.root, "k"));

    var found = try set.seekOpsByMapKey(gpa, .root, "k", null);
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), found.ops.items.len);
    try testing.expectEqual(@as(i64, 1), found.ops.items[0].value().int);
    try testing.expectEqual(@as(i64, 2), found.ops.items[1].value().int);

    // **Two visible rows and one winner is what "conflicted" means**
    // ([`map_range.rs:262-263`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)),
    // and the winner is the second operation: a register's rows ascend in op
    // id, and an op id orders by counter then actor
    // ([`op.rs:1059-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
    const after = try registerIndex(set, "k");
    try testing.expectEqual(@as(usize, 1), after.top);
    try testing.expectEqual(@as(usize, 2), after.visible);
    try testing.expect(try set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());
}

/// One element of one list, written twice by two actors that never saw each
/// other — **the merge of two writes to the same list index**, which is the
/// shape [`OpSet.seekListOpid`] is asked about after every concurrent edit.
///
/// The second row carries **no successor edge**: that is what a conflict *is*.
/// An `overwrite` would put one there (`Transaction.localListOp`,
/// `transact.zig:816-818`), which deletes the insert and leaves
/// the register with one row — and a register with one row is a shape the two
/// arms of the seek always agree on. **The two rows are both visible here, and
/// that is the whole point**: the register's *winner* is row 2 (`index.top`,
/// `index.zig:555-570`) while row 1 is still there for a reader to see
/// ([`Op.visible`](op.zig), `op.rs:1148-1156`).
fn conflictRows() [3]TestRow {
    const lst = made(1, 0);
    return .{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), lst, .{ .seq = head }, true, .set, .{ .str = "a" }, null, &.{}, false, true),
        rowAt(opId(3, 1), lst, .{ .seq = anchor(opId(2, 0)) }, false, .set, .{ .str = "A" }, null, &.{}, true, true),
    };
}

test "a register that merged into a conflict answers one index and one visibility for both of its ids" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const lst = made(1, 0);
    const rows = conflictRows();
    var set = try Set.fromActors(gpa, &two_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);

    // **The fixture is a document, not a broken one**, and that is asserted
    // before the behaviour it is used for: a disagreement between the two
    // arms is only a fact about the *seek* on a document both checkers accept.
    try testing.expect(try set.validateOpOrder());
    try testing.expectEqual(@as(?TopIndexFault, null), try set.validateTopIndex());

    // The premise: one element, and `seekOpsByIndex` holds both of its rows,
    // so the two ids name **one** element and must answer the same index and
    // the same visibility.
    var found = try set.seekOpsByIndex(gpa, lst, 0, .list, null);
    defer found.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), found.ops.items.len);
    try testing.expect(found.ops.items[0].id().eql(opId(2, 0)));
    try testing.expect(found.ops.items[1].id().eql(opId(3, 1)));
    var past = try set.seekOpsByIndex(gpa, lst, 1, .list, null);
    defer past.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), past.ops.items.len);

    // **The checked entry point, which is what every caller reaches, and the
    // line this whole test is about.** `getCursorPosition` (`cursor.zig:788`),
    // `getCursor` (`cursor.zig:727`) and `parentObject` (`op_set.zig:2465`) all
    // go through [`OpSet.seekListOpid`], and all three are `error.Invariant` on
    // a document a merge produces — which is what the cross-check at
    // `op_set.zig:3089` reports when one row of a conflicted register is asked
    // about. `visible = true` is the only answer a caller can act on: the row
    // is still in the document, `index.visible` says so, and a reader sees it
    // as a conflict (`automerge.rs:1803`, the `MoveCursor::Before` test).
    const answered = (try set.seekListOpid(lst, opId(2, 0), .list, null)).?;
    try testing.expectEqual(@as(usize, 0), answered.index);
    try testing.expectEqual(true, answered.visible);

    // **Each arm, called directly, so the test names the one that was wrong.**
    // The slow arm walks the register and counts the visible rows it is handed
    // ([`OpSet.seekListOpidSlow`](op_set.zig), upstream's
    // `OpsFoundIter::next` at `found_op.rs:58-63`): row 1 is visible and is
    // not a mark, so it is in the group and the answer is `visible = true`.
    for ([_]OpId{ opId(2, 0), opId(3, 1) }) |id| {
        const slow = (try set.seekListOpidSlow(lst, id, .list, null)).?;
        try testing.expectEqual(@as(usize, 0), slow.index);
        try testing.expectEqual(true, slow.visible);
        // And the fast arm, **on the same row and the same column read
        // straight out**: `index.visible[pos]`. Reading `index.top` here —
        // upstream's `visible = prefix.pv.value` (`op_set.rs:867`) — answers a
        // different question, "did this row win its register", and answers
        // *false* for row 1, which a reader can still see.
        const fast = (try set.seekListOpidFast(lst, id, .list)).?;
        try testing.expectEqual(@as(usize, 0), fast.index);
        try testing.expectEqual(true, fast.visible);
        try testing.expect(foundOpIdEqual(fast, slow));
    }

    // **The index is not what changed, and this is why.** `index.top`'s prefix
    // over the object counts the register's single winner, and that is the
    // element's index: the element is element zero because no winner precedes
    // row 1. Both arms say zero, for row 1 and for row 2, on this document and
    // on every document whose index carries one winner per register
    // ([`OpSet.validateTopIndex`], upstream's `assert_eq!(first_top,
    // last_vis)` at `op_set.rs:196-212`).
    const top = try indexRows(&set, gpa);
    defer gpa.free(top.top);
    defer gpa.free(top.visible);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, top.top);
    try testing.expectEqualSlices(bool, &.{ true, true, true }, top.visible);
}

test "the opid seek's fast arm is the one that answers, and only that arm can make the check fire" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const lst = made(1, 0);

    // **An allocation counter is the wrong instrument here and this says why,
    // because a reader will reach for one.** Both arms allocate through
    // `self.gpa` — the descent for its column cursors, the walk for the
    // [`Self.Grouped`] — and on these fixtures the counts come out *equal*, so
    // "the cost moved" would be a fact about `OpsFoundIter`'s buffering and
    // not about which arm answered. The perturbation below needs no
    // instrumentation at all, and it is stronger.
    const rows = conflictRows();
    var set = try Set.fromActors(gpa, &two_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);

    // **The perturbation: one element, two ids, and the two arms made to
    // disagree.** A second actor writes over the first actor's element without
    // having seen it, which is what merging two changes to one list index
    // produces — `Transaction.localListOp` is the local half of it
    // (`transact.zig:816-818`), and the merge is what leaves the second row
    // with no successor edge to the first. The register keeps both rows, both
    // are visible, and only the later one won (`index.top`,
    // `index.zig:555-570`).
    //
    // **Before the fix this is the row that broke it**: `index.top` is false
    // for the losing row and `index.visible` is true, and the fast arm read
    // `index.top`, so it reported a row a reader can see as gone. Both rows of
    // one element have to answer the same thing, and `seekListOpid` answered
    // neither — it answered `error.Invariant` (`op_set.zig:3089`). That is the
    // perturbation, and it fails *only* the fast arm: the walk hands the losing
    // row over as one of the group's visible rows and has always said so
    // (`found_op.rs:58-63`).
    for ([_]OpId{ opId(2, 0), opId(3, 1) }) |id| {
        const fast = (try set.seekListOpidFast(lst, id, .list)).?;
        const slow = (try set.seekListOpidSlow(lst, id, .list, null)).?;
        try testing.expect(foundOpIdEqual(fast, slow));
        // **Pinned as literals, in the fast arm, not as one function's output
        // compared with another's.** An implementation of
        // [`OpSet.seekListOpid`] that quietly returned `slow` would leave both
        // of these green and the code still wrong, which is exactly the shape
        // of a clamp: the walk is right and the descent is broken and nobody
        // says so. Calling [`OpSet.seekListOpidFast`] directly is what makes
        // the descent's own arithmetic the subject.
        try testing.expectEqual(@as(usize, 0), fast.index);
        try testing.expectEqual(true, fast.visible);
        try testing.expectEqual(fast.index, slow.index);
        try testing.expectEqual(fast.visible, slow.visible);
        const answered = (try set.seekListOpid(lst, id, .list, null)).?;
        try testing.expectEqual(fast.index, answered.index);
        try testing.expectEqual(fast.visible, answered.visible);
    }

    // **The half of it that "returns `fast`" alone cannot carry, and why it is
    // here.** The checked entry point hands back `fast`
    // (`op_set.zig:3090`), and when the two arms agree the two candidates are
    // the same value, so no caller can tell which one it got — the check makes
    // that unobservable by construction. What *is* observable is the check
    // firing, and it can only fire if **both** arms ran and both computed an
    // answer: `seekListOpid` at `op_set.zig:3087-3089` is the fast descent, the
    // walk, and the comparison, and removing either arm leaves nothing to
    // disagree. The test below pins that on a document where they do disagree.
    // Together the two say what this one cannot: the descent ran, it ran with
    // the arithmetic above, and its value is the one handed back.
}

test "a register with two winners is a broken index, and the cross-check still says so" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    const lst = made(1, 0);
    // **The same three rows as `conflictRows`, written by one actor rather than
    // two.** The row's shape is identical — it hangs by the element and names
    // no successor — and that is the point: the register now holds *two* rows
    // that `index.top` calls winners, which is what
    // [`OpSet.validateTopIndex`] rejects — upstream's `assert_eq!(first_top,
    // last_vis)` (`op_set.rs:196-212`) over one `(obj, elemid_or_key)` group.
    // `localListOp` cannot write this — an overwrite puts a successor edge on
    // every row of the register (`transact.zig:816-818`) — so it is a
    // hand-built document, and the disagreement it causes is information
    // rather than a bug to be clamped away.
    const rows = [_]TestRow{
        rowAt(opId(1, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, null, &.{}, true, true),
        rowAt(opId(2, 0), lst, .{ .seq = head }, true, .set, .{ .str = "a" }, null, &.{}, true, true),
        rowAt(opId(3, 0), lst, .{ .seq = anchor(opId(2, 0)) }, false, .set, .{ .str = "b" }, null, &.{}, true, true),
    };
    var set = try Set.fromActors(gpa, &fixture_actors, encoding, table.asTable());
    defer set.deinit();
    _ = try set.splice(0, &rows);

    // **Another checker names the fault, and this is why the cross-check's
    // answer is worth having.** `error.Invariant` says "these two disagree";
    // `final_group_mismatch` says *which row* and *what* — the register's
    // first winner is row 1 and its last visible row is row 2
    // (`op_set.rs:205-212`).
    switch (try set.validateTopIndex() orelse return error.TestExpectedEqual) {
        .final_group_mismatch => |fault| {
            try testing.expectEqual(@as(usize, 3), fault.at);
            try testing.expectEqual(@as(?usize, 1), fault.first_top);
            try testing.expectEqual(@as(?usize, 2), fault.last_vis);
        },
        else => return error.TestUnexpectedResult,
    }

    // **The two arms, and where they part.** `index.top`'s prefix counts both
    // winners, so the fast descent answers element *one* for a row whose
    // register begins the object; the slow walk counts the register that ends
    // before the row and answers zero. One of those two numbers is an index in
    // a one-element list and the other is not, and there is nothing the fast
    // arm can do about it in one descent — which is why `error.Invariant` is
    // the answer and not a clamp.
    const fast = (try set.seekListOpidFast(lst, opId(3, 0), .list)).?;
    const slow = (try set.seekListOpidSlow(lst, opId(3, 0), .list, null)).?;
    try testing.expectEqual(@as(usize, 1), fast.index);
    try testing.expectEqual(@as(usize, 0), slow.index);
    try testing.expect(!foundOpIdEqual(fast, slow));

    // **So the check still fires, and it fires here.** Upstream's
    // `debug_assert_eq!` (`op_set.rs:846`) is the same report with a different
    // disposition; the port raises the error and returns nothing, which is the
    // difference between naming a fault and shipping one.
    try testing.expectError(error.Invariant, set.seekListOpid(lst, opId(3, 0), .list, null));
}

// ── Differences from upstream, in one place ─────────────────────────────────

// | here | upstream | why |
// | --- | --- | --- |
// | [`OpSet.debugDiff`] returns `?`[`DebugCmpFault`](DebugCmpFault) and names **which** op set is at fault and where | `OpSet::debug_cmp` is `#[cfg(test)]`, returns `()`, and panics through `assert_eq!` ([`op_set.rs:68-71`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs), [`columns.rs:99-130`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)) | a one-bit answer leaves the reader of two documents that differ with no way to tell which is broken, and the two doors to one document — the local transaction path and the apply path — can disagree about where a row goes. Upstream's own `debug_assert!(doc.ops.validate_op_order())` ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)) is what says which of the two is wrong, and a comparison that cannot compute it cannot route the reader |
// | `debugCmp` runs both invariant checkers, on **both** sides, before it compares a column | `Columns::debug_cmp` compares fifteen columns and the value arena and nothing else ([`columns.rs:97-133`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)) | "these two differ" and "this one is broken" are different facts. A broken op set can be **column for column identical** to a sound one — the rows are the same, only the order is wrong — so a comparison that answers the pair question first reports green on it |
// | `debugCmp` compares the **actor table** and the **`obj_info` table** | neither ([`op_set.rs:69-71`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs) reaches only `cols`) | upstream's answer does not say whether a reloaded document still knows what its objects are, which is what makes the comparison the instrument for "a save and a reload are the same document" rather than only "have the same rows" |
// | the two **string** columns are compared as strings, through each side's own [`OpSet.strings`] | they are `hexane::Column<Option<String>>` and hold the strings ([`columns.rs:24`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs), [`columns.rs:111`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs), [`columns.rs:117`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)) | this port's hold interned ids ([plan §5.3](../../docs/plan.md)) and two op sets have two string tables, so an id comparison would answer "were these built against the same table" |
// | the comparison stays **positional** | so does upstream's | the row order is required, not free: [`opmod.Op.step`](op.zig) is the invariant ([`op.rs:1048-1073`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)), upstream's one and only call site of `validate_op_order` is the `debug_assert!` at the end of every apply ([`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)) — **the load path does not check the row order at all**, it asserts `validate_top_index` instead ([`storage/document.rs:351`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)) — and a map walk does not sort ([`map_range.rs:1486-1490`](../iter/map_range.zig)). Two op sets with the same rows in a different order **read** differently, so comparing them by value would report green on a broken document |
// | the two checkers, twenty columns, the arena, the mark cache and the object table — **all twenty** of [`checkpoint_column_names`] | fifteen columns and the arena | the four index columns are derived state that a reloaded document rebuilds ([`OpSet.load`](op_set.zig)), and comparing them is what catches a rebuild that disagrees with the rows it was built from |
// | [`OpSet.debugCmp`]'s error set is `ParseError \|\| InternalError` and the four of [`ReadOpError`]'s own members become `error.Invariant` | `debug_cmp` panics | the op set is not untrusted input — it is the document — so a walk that cannot read a row of one is an invariant failure. [`Document.debugCmp`](../doc.zig) declares that error set and is not this file's to widen |
// | [`OpSet.validateOpOrder`] and [`OpSet.validateTopIndex`] are `pub` and answer rather than assert | the same two are `pub(crate)`, and `validate_op_order` is reached only from a `debug_assert!` ([`op_set.rs:167-175`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs), [`batch.rs:949`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)) | a checker that is a panic cannot be tested, and the port's rule is that a checker answers rather than traps |
// | the row where the order first breaks is a **value** on the fault | `validate_op_order` returns a `bool` ([`op_set.rs:167-175`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) | a fault has nowhere to put a row, and "the order is wrong, **where**" is the question a reader of the fault has |
// | [`DebugCmpFault`], [`DebugSide`] | no such type | the same rule as [`TopIndexFault`]: a failure is a value naming what failed, so a test can make the checker fire and a caller can act on it |
// | [`OpSet.mapRange`] takes `?KeyBound` at each end, and so reaches all four of upstream's arms | `map_range` takes a `RangeBounds<String>` and matches four ways ([`op_set.rs:406-416`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) | Zig has no range-bounds protocol, so [`KeyBound`] is `RangeBounds`' spelling the way [iter/list_range.zig](iter/list_range.zig)'s `IndexRange` is `RangeBounds<usize>`'s. `Included` and `Excluded` at the same end name **different** row ranges one register apart, so a pair of `?[]const u8` could reach only the two `Included` arms — and the two a C `AMmapRange` needs, because its `end` is one past the last key ([`automerge-c/src/doc/map.rs:482-483`](../../github-automerge-automerge/rust/automerge-c/src/doc/map.rs)) |
// | [`OpSet.propRange`] **walks** the key column and counts the rows below the key to answer an absent key's sorted point | `prop_range` is `key_str.scope_to_value(Some(prop), obj_range)`, one descent ([`op_set.rs:1268-1271`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) | this port's `key_str` holds interned ids ([plan §5.3](../../docs/plan.md)), which are in first-seen order and not key order, so `scopeToValue` needs sorted values and cannot be used. A walk that finds nothing has no descent to fall out of, so the accumulation is written out: one past the last row whose key sorts below the probe, which is what the descent answers ([`column.rs:958-1000`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs), [hexane/src/tests.rs:3464-3476](../../github-automerge-automerge/rust/hexane/src/tests.rs)). Without it the answer was the object's end, which is right **only** for a key above every key the object holds |
// | `OpSet.mapRange` takes **no clock** | `map_range` takes one and passes it to `MapRange::new` ([`op_set.rs:396-419`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) | upstream's four arms are row arithmetic over `key_str` and `obj_range` and never mention the clock; the narrowing happens in the walk. The port puts the clock where it goes — on the walk's constructor ([`OpSet.keys`], [`OpSet.listRange`]) — rather than on the bounds, where nothing would read it |
// | [`OpSet.idToExid`] answers an [`ExId.id`](../types.zig) — the operation alone — for an index the actor table does not have, and an [`ExId.named`](../types.zig) — the operation **plus the actor's bytes** — for every index it does | `OpSet::id_to_exid` reads `self.actors[id.actor()].clone()` and has no arm that does not ([`op_set.rs:1054-1060`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)); the third field of `ExId::Id` is the actor's bytes precisely so an id survives a renumbering ([`exid.rs:15-18`](../../github-automerge-automerge/rust/automerge/src/exid.rs), read back at [`automerge.rs:744-758`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) | an index out of range is a row the set should not hold ([`OpSet.splice`] rejects it), and there is no actor to record for one. The bare id is the old behaviour and is what a caller with only an index gets; it is **not** the answer for an index the table *does* have, because that answer used to drop the one field that makes an id mean the same thing in two documents. The actor table is sorted, so interning an actor that sorts first — which is what `isolate` does, with a concurrency actor whose magic bytes are `0x13 b2 23 09` ([`types.rs:23`](../../github-automerge-automerge/rust/automerge/src/types.rs)) — renumbers every index at or above it ([`op_set.rs:1400-1405`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)) |
// | [`OpSet.queryInsertAt`] **computes the general answer and returns `error.Invariant`** when the two disagree, and [`OpSet.queryInsertAtText`] answers `null` — falling through to the general walk — where `elemid_at` finds no element at the corrected position | `query_insert_at` compares the fast answer with `InsertQuery`'s under a `debug_assert_eq!` and returns `Ok(q)` either way ([`op_set.rs:583-598`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)); `elemid_at(..)?` propagates `None` out of `query_insert_at_text`, which is the same fall-through, and unwrapping there instead is a panic | a `debug_assert_eq!` is compiled out of a release build, so a disagreement between two rules that must give one answer is a wrong insertion point only a debug build sees. Computing both is what makes it a **value** — `error.Invariant` reaches the caller and a test can assert it — rather than a message on stderr. **The extra call is not optional**: the fast path's [`QueryNth`] owns a [`MarkSet`](insert.zig), so the disagreement has to hand it back before the error leaves or every failure leaks and `std.testing.allocator` aborts the run |
// | [`OpSet.seekListOpidFast`] reads **`index.visible[pos]`** for [`FoundOpId.visible`](op_set.zig), and [`OpSet.seekListOpidSlow`] reads it too whenever there is no clock | `seek_list_opid_fast` sets `visible` from the value the index descent landed on — `index.top` at `op_set.rs:867` and `index.text` at `:872` — and `seek_list_opid_slow` sets it from `ops.ops.contains(&op)` over an `iter_obj(obj).no_marks()` walk (`op_set.rs:886`, `:890`) | the two arms answer **two different questions**, and the `debug_assert_eq!` between them (`op_set.rs:846`) fires on documents a merge produces. `index.top` answers "did this row win its register" and `index.visible` answers "is this row still there" ([`OpSet`](op_set.zig)'s own [`TopIndexFault.top_not_visible`](op_set.zig), upstream's `assert!(vis)` at `op_set.rs:202-203` — the two are separate facts there too). A row that is visible and lost its register to a later conflicting write is the ordinary shape of a merged list, and upstream's fast arm called it gone; and because the walk drops mark rows while the descent counts them, upstream's slow arm called a mark gone too. The only consumer asks the question `index.visible` answers — "is this element still there" ([`automerge.rs:1803`](../../github-automerge-automerge/rust/automerge/src/automerge.rs), [`getCursorPosition`](cursor.zig)'s `found.visible` arm at `cursor.zig:796`) — so **both** arms read that column, and a conflict loser or a mark resolves instead of raising `error.Invariant` |
// | [`OpSet.seekListOpidFast`]'s **index** is upstream's `prefix.delta` unchanged, and a register with two winners still answers `error.Invariant` | so does upstream (`op_set.rs:868`, `:873`), with the same `debug_assert_eq!` | this is a deliberate non-change, and the reason is that the fast path's index is right wherever the index is sound: a register carries exactly one `index.top` ([`IndexBuilder`](index.zig), `index.rs:223-228`), which is what [`OpSet.validateTopIndex`] asserts (`op_set.rs:196-212`), so the count of winners before a row is the count of registers before it. A register with two winners is a document neither `local_list_op` nor a load can write — an overwrite puts a successor edge on every row of the register (`transact.zig:816-818`) — and the port cannot repair it in one descent, because the register's first row is only findable by walking the key column, which is what the slow arm already does. **So the disagreement is the report**, and it is one another checker names: `final_group_mismatch` at `op_set.rs:196-212` says *which* row and *what*, where `error.Invariant` can only say "these two differ" |
