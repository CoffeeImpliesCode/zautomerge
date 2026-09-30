//! The walk from an object up to the document root: [`Parents`], the walk
//! itself, and [`Parent`], one level of it.
//!
//! Upstream `op_set2/parents.rs`, 133 lines, owns three things:
//!
//! | what | upstream |
//! |------|----------|
//! | [`Parents`] — the iterator, holding the object, the op set and a clock | `:14-18` |
//! | [`Parents.path`] and [`Parents.visiblePath`] — the same chain, forward | `:24-46` |
//! | [`Parent`] — one level: object, type, property, visibility | `:79-92` |
//!
//! # The walk runs backwards, and that is not a detail
//!
//! `Parents` yields **innermost first**: the first item is the object's
//! immediate container, the last is the root's own property
//! (`parents.rs:8-10`). Both accessors reverse what they collect
//! (`parents.rs:28`, `:44`) so `path()` reads root-down.
//!
//! **Do not "fix" this.** A port that makes `next` yield root-down silently
//! reverses twice and returns the path upside down, which looks plausible
//! until a path is applied to a document with more than one container
//! ([survey §"Patches and parents" notes 61 and 5](../../docs/survey/01-core-api.md)).
//! The reverse order is stated on [`Parents.next`] and pinned by every test in
//! this file.
//!
//! # `ObjId` versus `ExId`, and why the API keeps them apart
//!
//! Upstream has two object-id types ([`types.rs:519-576`](../../github-automerge-automerge/rust/automerge/src/types.rs)
//! and [`exid.rs:13-17`](../../github-automerge-automerge/rust/automerge/src/exid.rs)),
//! and this file preserves the split:
//!
//! * **`ObjId`** is what the object index stores. Upstream's is
//!   `struct ObjId(OpId)` with `ObjId::root() == ObjId(OpId(0, 0))`
//!   (`types.rs:552-554`) and `is_root()` reading the **counter**
//!   (`types.rs:556-558`). [`Parents`] holds one (`parents.rs:15`) and it is
//!   what [`OpSet.parentObject`] is asked about
//!   ([`op_set.rs:353`](op_set.zig)).
//! * **`ExId`** is what a caller is handed. Upstream's carries the counter,
//!   the actor's **bytes** and the actor's index (`exid.rs:13-17`), which is
//!   why it can be persisted on its own (`exid.rs:24-66`); it converts inwards
//!   through `to_internal_obj` (`exid.rs:71-76`) and back out through
//!   `OpSet::id_to_exid` ([`op_set.rs:1054-1060`](op_set.zig)).
//!
//! So the walk *starts* on an `ObjId` and *reports* an `ExId`, which is exactly
//! what [`Parents.next`] does (`parents.rs:66-67`) — the object it yields is
//! `id_to_exid` of the object it moves to, not the object's own id.
//!
//! **The port's [`types.zig`](../../src/types.zig) has one type, not two**
//! (`types.zig:215-217`): a two-variant union of the root and an `OpId`, which
//! is `ObjId`'s representation. The distinction is kept here as two names for
//! that one type and as the rule that says which side of the boundary a value
//! is on — the walk state is an `ObjId`, everything reported to a caller is an
//! `ExId`. The root is `.root`, and [`types.ExId.isRoot`](../../src/types.zig)
//! is what tells a root object from a made one, which is the property the two
//! upstream types exist to keep.
//!
//! # The walk is bounded, and upstream's is not
//!
//! Upstream's `next` loops until `obj.is_root()` (`parents.rs:53-55`) and has
//! no other exit. An object index is rebuilt from an op stream that came off
//! disk or off a peer
//! ([`storage/document.rs:332-344`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
//! so a parent chain is untrusted input and can loop: nothing in the merge
//! walkers rules out an index that says `a` hangs in `b` and `b` hangs in
//! `a`. Upstream's `.unwrap()` at `parents.rs:65` is on a lookup that a cyclic
//! index never fails, so the loop is silent.
//!
//! **The port therefore stops after `obj_info.count()` levels** — the number of
//! objects the index holds, which is the number of distinct objects a
//! non-looping chain can visit ([`ObjIndex.count`](index.zig)). That is a
//! proved bound, not a heuristic: [`Parents.init`] takes the count once and
//! [`Parents.next`] spends one per level, so no input can make the walk
//! unbounded. A chain that loops stops at the bound and the caller sees a
//! truncated path rather than a hang.
//!
//! # Constructing a `Parents` allocates nothing, and it owns nothing
//!
//! The struct is four words and a pointer: an object id, a pointer to the op
//! set, an optional clock and the bound. Upstream's three fields
//! (`parents.rs:14-18`) plus that one `usize` are the whole of it, and there
//! is **no allocator on it at all** — [`Parents.init`] is the only thing that
//! reads the op set and it reads a `usize`. So there is no `deinit`:
//! [`Parents.path`] and [`Parents.visiblePath`] allocate, and the **caller**
//! frees what they return.
//!
//! **What a level costs is not this file's business, and the walk pays
//! exactly it.** [`Parents.next`] is one [`OpSet.parentObject`] call, and that
//! call allocates: [`OpSet.getOpIdPos`](op_set.zig) descends the id B-tree
//! and the descent owns a stack of frames
//! ([`CtrWalker`](op_iter.zig)). The walk adds nothing on top — its own
//! contribution per level is the two comparisons and one id conversion — and
//! the test says so by measuring a walk against three direct
//! `parentObject` calls rather than against zero. Upstream's `next` allocates
//! for the same reason: `get_op_id_pos` descends the same tree
//! ([`op_set.rs:830-836`](op_set.zig)).
//!
//! # What this file does not hold
//!
//! * `ReadDoc::parents` and `ReadDoc::parents_at`
//!   ([`read.rs:35-46`](../../github-automerge-automerge/rust/automerge/src/read.rs)),
//!   which convert an `ExId` and build a clock, and
//!   `Automerge::parents_for` (`automerge.rs:1652-1660`). Those are the
//!   document API's, and they name [`Parents`] as their return type
//!   (`read.rs:7`, `:35`).
//! * `OpSet::parent_object` (`op_set.rs:353-375`). It is the only thing
//!   [`Parents.next`] reads and it already lives at
//!   [`OpSet.parentObject`](op_set.zig), one level down.
const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clocks = @import("../clock.zig");
const opmod = @import("op.zig");
const opsetmod = @import("op_set.zig");
const opcols = @import("columns.zig");
const opiter = @import("op_iter.zig");
const optypes = @import("types.zig");

const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Clock = clocks.Clock;
const Error = err.Error;
const ElemId = types.ElemId;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const ObjType = types.ObjType;
const OpId = types.OpId;
const ParseError = err.ParseError;
const Prop = types.Prop;
const ReadOpError = opiter.ReadOpError;
const ScalarValue = optypes.ScalarValue;
const SearchError = opsetmod.SearchError;
const SequenceType = types.SequenceType;
const StringTable = opcols.StringTable;
const SuccCursors = opmod.SuccCursors;
const SuccEntry = opmod.SuccEntry;
const TextEncoding = types.TextEncoding;
const ValueMeta = optypes.ValueMeta;
const Action = optypes.Action;
const Op = opmod.Op;

/// The id the object index stores (`ObjId`, `types.rs:519-576`).
///
/// The port's [`types.zig`](../../src/types.zig) has one object-id type
/// (`types.zig:215-217`), which is upstream's `ObjId` representation; the name
/// says which side of the boundary a value is on. See the module doc.
const ObjId = types.ExId;

/// The id a caller is handed (`ExId`, `exid.rs:13-17`).
///
/// Same representation as [`ObjId`], different side: this is what every value
/// **reported** to a caller is, and what a document API's `parents` takes.
const ExId = types.ExId;

const testing = std.testing;

// ── Errors ──────────────────────────────────────────────────────────────────

/// What one step of the walk can raise.
///
/// Exactly what [`OpSet.parentObject`](op_set.zig) raises
/// ([`op_set.zig`](op_set.zig) spells it out at that declaration): the four
/// refusals a bad row read makes ([`opiter.ReadOpError`](op_iter.zig)), the
/// B-tree descent under [`OpSet.getOpIdPos`](op_set.zig)
/// ([`SearchError`](op_set.zig)), and the checks upstream treats as impossible
/// ([`InternalError`]).
pub const StepError = ReadOpError || SearchError || InternalError;

/// What [`Parents.path`] and [`Parents.visiblePath`] can raise: a step's
/// errors, plus the allocator for the array they build.
pub const PathError = StepError || Allocator.Error;

// ── PathElem ────────────────────────────────────────────────────────────────

/// One `(ExId, Prop)` step of a path from the root down to an object
/// (upstream's `Vec<(ExId, Prop)>`, `parents.rs:24` and `patch.rs:21`).
///
/// Upstream has no name for it — it is the same tuple in
/// [`Parents.path`] (`parents.rs:26`) and in [`Patch.path`](../../src/patches.zig)
/// (`patch.rs:21`) — and this file declares it once. **It borrows its map key
/// from the op set's key column** rather than copying it, which upstream's
/// `Prop::Map(k.to_string())` does (`op_set.rs:358`): the walk already borrows
/// the op set for as long as the path is readable, and
/// [AGENTS.md](../../AGENTS.md) says a slice into a document's own storage is
/// valid until the next mutation.
pub const PathElem = struct {
    /// The object this step leaves.
    obj: ExId,
    /// The property of that object the next object hangs by.
    prop: Prop,
};

/// Whether two steps are the same object reached by the same property.
pub fn pathElemEqual(a: PathElem, b: PathElem) bool {
    return a.obj.eql(b.obj) and a.prop.eql(b.prop);
}

// ── Parent ──────────────────────────────────────────────────────────────────

/// One level of a path to an object (`Parent`, `parents.rs:79-92`).
///
/// Upstream derives `Debug, PartialEq, Eq` (`:78`); the comparisons here are
/// [`types.ExId.eql`](../../src/types.zig) and
/// [`Prop.eql`](../../src/types.zig), which the port spells as functions
/// because a `Prop` holds a slice and `==` on two of those compares pointers.
///
/// **Not [`OpSet.Parent`](op_set.zig).** Upstream has two: `op_set::Parent`
/// (`op_set.rs:1432-1438`), `pub(crate)`, carrying the container as an
/// `ObjId` and returned by `OpSet::parent_object`, and this one, public,
/// carrying it as an `ExId` and yielded by the walk. The difference is the
/// `ObjId`/`ExId` boundary the module doc is about, and it is the reason
/// [`Parents.next`] cannot just hand `parent_object`'s value back.
pub const Parent = struct {
    /// The object this component refers to (`parents.rs:81`).
    ///
    /// The container, not the object the walk started from: this is
    /// `id_to_exid` of the *parent*, and the root arrives as
    /// [`ExId.root`](../../src/types.zig).
    obj: ExId,
    /// The type of the parent object (`parents.rs:83`).
    typ: ObjType,
    /// The property within `obj` this component refers to (`parents.rs:85`).
    ///
    /// A map key, or the index the child sits at in a sequence — never a
    /// sequence anchor, because a sequence parent is reported by *index*
    /// ([`op_set.rs:365-367`](op_set.zig)).
    prop: Prop,
    /// Whether this component is "visible" (`parents.rs:86-91`).
    ///
    /// An "invisible" component is one where the property is hidden, either
    /// because it has been deleted or because there is a conflict on this
    /// (object, property) pair and this value does not win the conflict
    /// (`parents.rs:88-90`). The index is the register winner
    /// ([`op_set.rs:1116`](op_set.zig)) read in the clock the walk was given.
    visible: bool,
};

// ── Parents ─────────────────────────────────────────────────────────────────

/// The walk from an object up to the document root (`Parents`,
/// `parents.rs:14-18`).
///
/// Generic over `O` for the same reason [`opsetmod.OpSet`](op_set.zig) is: the
/// op set is written in terms of the op type `O`, and a walk that borrowed it
/// would have to be written twice. One type parameter and the whole surface is
/// written once, which is the same split [`op_iter.zig`](op_iter.zig) makes.
pub fn Parents(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op set this walk reads.
        pub const Set = opsetmod.OpSet(O);

        /// Where the walk is now (`Parents.obj`, `parents.rs:15`).
        ///
        /// An **`ObjId`** — the index's own spelling — not the `ExId` a caller
        /// named. Upstream converts inwards before it constructs the walk
        /// ([`exid.rs:71-76`](../../github-automerge-automerge/rust/automerge/src/exid.rs))
        /// and this is the field that conversion lands in.
        obj: ObjId,
        /// The op set it reads (`Parents.ops`, `parents.rs:16`).
        ///
        /// Upstream borrows it immutably; the port's
        /// [`OpSet.parentObject`](op_set.zig) takes a mutable pointer because
        /// its row walk borrows the set's successor buffer, which is the same
        /// borrow every other walk over this op set makes
        /// ([`op_iter.zig`](op_iter.zig)'s module doc, "The storage behind an
        /// `Op` must outlive it").
        ops: *Set,
        /// The clock the walk is scoped to (`Parents.clock`, `parents.rs:17`).
        ///
        /// Null is "the present", not "no filter": it selects the fast
        /// register-winner read ([`op_set.rs:1104-1106`](op_set.zig)) and a
        /// clock selects the slow one, which is why the two are a dispatch and
        /// not the same answer computed twice.
        clock: ?Clock,
        /// Levels still to be yielded before the walk stops.
        ///
        /// **The port's addition** and the whole of its cycle defence; see the
        /// module doc. Set once by [`Parents.init`] to the object count and
        /// spent one per yield, so it cannot run out while the walk can go on.
        budget: usize,

        /// A walk from `obj` up to the root, read in `clock`
        /// (`OpSet::parents`, `op_set.rs:95-101`).
        ///
        /// Upstream's `parents` is a `pub(crate)` literal construction and
        /// this is its spelling.
        ///
        /// **The bound is read here rather than in `next`**, from
        /// [`ObjIndex.count`](index.zig) through the op set's `obj_info`
        /// table. Zig has no field privacy, and a count read once is a count
        /// read once: the walk is a value, so the number travels with it and
        /// `next` never looks it up.
        pub fn init(ops: *Set, obj: ObjId, clock: ?Clock) Self {
            return .{
                .obj = obj,
                .ops = ops,
                .clock = clock,
                .budget = ops.obj_info.count(),
            };
        }

        /// How many levels this walk may still yield.
        ///
        /// What [`Parents.init`] set it to — the number of objects the index
        /// holds, which is what a chain with no repeats in it can spend —
        /// less one for every level already yielded. Zero means the walk has
        /// reached the root or exhausted its bound.
        pub fn remaining(self: *const Self) usize {
            return self.budget;
        }

        /// The next level, innermost first (`Parents::next`, `parents.rs:52-74`).
        ///
        /// Null when the walk has reached the root — `obj.is_root()` is
        /// upstream's own first test (`parents.rs:53-55`), which is how "once
        /// the iterator returns `None` you have reached the root of the
        /// document" (`parents.rs:9-10`) is true.
        ///
        /// **Null also when the walk hits its bound** (module doc, "The walk
        /// is bounded"), and **null when the op set does not hold the object**.
        /// Upstream `.unwrap()`s both of those (`parents.rs:65`) and traps;
        /// the port treats a missing object as the end of the walk, which is
        /// the answer a caller can act on — see the module doc's cycle section
        /// for why an unbounded loop is not an option here.
        ///
        /// **Yields in reverse order.** The first item is the object's
        /// immediate container and the last is the root's own property
        /// (`parents.rs:8-10`); [`Parents.path`] and [`Parents.visiblePath`]
        /// reverse what they collect.
        pub fn next(self: *Self) StepError!?Parent {
            if (self.obj.isRoot()) return null;
            if (self.budget == 0) return null;
            self.budget -= 1;
            const parent = (try self.ops.parentObject(self.obj, self.clock)) orelse return null;
            // Upstream moves first and converts the moved-to object second
            // (`parents.rs:66-67`), so the reported id is the *parent's*.
            self.obj = parent.obj;
            // `id_to_exid` takes the `OpId` out of the `ObjId`
            // (`parents.rs:67` is `self.obj.0`), and the root is `OpId(0, 0)`
            // (`types.rs:552-554`) — which is exactly what `id_to_exid`
            // maps back to `ExId::Root` ([`op_set.rs:1055-1056`](op_set.zig)).
            const parent_id = parent.obj.opId() orelse OpId.root;
            return .{
                .obj = self.ops.idToExid(parent_id),
                .typ = parent.typ,
                .prop = parent.prop,
                .visible = parent.visible,
            };
        }

        /// The whole chain from the root down to this object
        /// (`Parents::path`, `parents.rs:24-30`).
        ///
        /// **Forward order** — "This is _not_ in reverse order"
        /// (`parents.rs:23`). The walk yields innermost first
        /// (`parents.rs:8-10`) and this reverses what it collected
        /// (`parents.rs:28`), so the result starts at the root.
        ///
        /// Upstream returns an owned `Vec` of owned `Prop`s. The port returns
        /// an owned array of [`PathElem`]s whose map keys **borrow** the op
        /// set's key column (see [`PathElem`]); the caller frees the array with
        /// `gpa.free`.
        ///
        /// Takes `self` by value, as upstream does, so the caller's walk is
        /// untouched and can be walked again.
        pub fn path(self: Self, gpa: Allocator) PathError![]PathElem {
            var out: std.ArrayList(PathElem) = .empty;
            errdefer out.deinit(gpa);
            var it = self;
            while (try it.next()) |step| {
                try out.append(gpa, .{ .obj = step.obj, .prop = step.prop });
            }
            std.mem.reverse(PathElem, out.items);
            return out.toOwnedSlice(gpa);
        }

        /// [`Parents.path`], or null when any level is not visible
        /// (`Parents::visible_path`, `parents.rs:33-46`).
        ///
        /// Upstream returns `None` on the **first** invisible component
        /// (`parents.rs:39-41`) and does not collect the rest, so the answer is
        /// a whole path or nothing: a caller applying it gets a document the
        /// user can see, or no document at all. A partial path would be the
        /// third thing and is not one upstream produces.
        ///
        /// **The root's path is empty, not null.** `visible_path` returns
        /// `Some(vec![])` for an object with no levels, because the loop body
        /// at `parents.rs:35-43` never runs and `:45` returns `Some`
        /// unconditionally — so the root is distinguishable from an invisible
        /// one, which is null.
        pub fn visiblePath(self: Self, gpa: Allocator) PathError!?[]PathElem {
            var out: std.ArrayList(PathElem) = .empty;
            errdefer out.deinit(gpa);
            var it = self;
            while (try it.next()) |step| {
                if (!step.visible) {
                    out.deinit(gpa);
                    return null;
                }
                try out.append(gpa, .{ .obj = step.obj, .prop = step.prop });
            }
            std.mem.reverse(PathElem, out.items);
            return try out.toOwnedSlice(gpa);
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The encoding every fixture measures widths in, so a map key's width is
/// arithmetic rather than grapheme segmentation — the choice
/// [`op_set.zig`](op_set.zig)'s tests make, for the same reason.
const encoding: TextEncoding = .unicode_code_point;

/// The document's one actor (`types.zig:154-156`), so every actor index in the
/// columns is `0` and a clock is one `u32`.
const actor0: ActorId = .{ .bytes = "aaaa" };
const fixture_actors = [_]ActorId{actor0};

/// The walk under test, written over the [`Row`] fixture.
///
/// `Walk.Set` is the op set it reads — [`opsetmod.OpSet`] over the same `O`,
/// which is the one type parameter the walk costs.
const Walk = Parents(Row);

/// The operation at `ctr` by `actor` (`types.rs:154-156`).
fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

/// The object the operation at `ctr` made (`types.rs:200-202`).
fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// The string table the op set borrows. It **must** live at one address for as
/// long as the op set does, so [`Handle`] heap-allocates the pair — the same
/// ownership rule and the same reason as [`op_set.zig`](op_set.zig)'s
/// `Document`.
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

// ── The fixture row ─────────────────────────────────────────────────────────

/// A row as `splice` reads it: the [`Op`] every walk hands back, plus the
/// `top` and `visible` the splice path is *told*.
///
/// **They have to be separate because they are separate facts.**
/// [`columns.Columns.splice`](columns.zig) writes `index.top` and
/// `index.visible` from what this type claims, and a register winner that lost
/// a conflict is still visible — so a fixture that let [`OpBuilder.visible`]
/// stand in for the index column would report a deleted register as visible
/// and this file's clock test could not be written at all.
const Row = struct {
    op: Op,
    is_top: bool,
    is_visible: bool,

    pub fn id(self: *const Row) OpId {
        return self.op.id();
    }
    pub fn obj(self: *const Row) ?OpId {
        return self.op.obj();
    }
    pub fn objId(self: *const Row) ObjId {
        return self.op.objId();
    }
    pub fn objActor(self: *const Row) ?ActorIdx {
        return self.op.objActor();
    }
    pub fn objCtr(self: *const Row) ?u32 {
        return self.op.objCtr();
    }
    pub fn objInfo(self: *const Row) ?opmod.ObjInfo {
        return self.op.objInfo();
    }
    pub fn action(self: *const Row) Action {
        return self.op.action();
    }
    pub fn key(self: *const Row) KeyRef {
        return self.op.key();
    }
    pub fn keyStr(self: *const Row) ?[]const u8 {
        return self.op.keyStr();
    }
    pub fn keyActor(self: *const Row) ?ActorIdx {
        return self.op.keyActor();
    }
    pub fn keyCtr(self: *const Row) ?i64 {
        return self.op.keyCtr();
    }
    pub fn insert(self: *const Row) bool {
        return self.op.insert();
    }
    pub fn value(self: *const Row) ScalarValue {
        return self.op.value();
    }
    pub fn metaValue(self: *const Row) ValueMeta {
        return self.op.metaValue();
    }
    pub fn rawValue(self: *const Row) ?[]const u8 {
        return self.op.rawValue();
    }
    pub fn expand(self: *const Row) bool {
        return self.op.expand();
    }
    pub fn markName(self: *const Row) ?[]const u8 {
        return self.op.markName();
    }
    pub fn markData(self: *const Row) ?MarkData {
        return self.op.markData();
    }
    pub fn markIndex(self: *const Row) ?i64 {
        return self.op.markIndex();
    }
    pub fn width(self: *const Row, seq_type: SequenceType, enc: TextEncoding) i64 {
        return self.op.width(seq_type, enc);
    }
    pub fn visible(self: *const Row) bool {
        return self.is_visible;
    }
    pub fn top(self: *const Row) bool {
        return self.is_top;
    }
    pub fn elemidOrKey(self: *const Row) KeyRef {
        return self.op.elemidOrKey();
    }
    pub fn asStr(self: *const Row) []const u8 {
        return self.op.asStr();
    }
    pub fn isInc(self: *const Row) bool {
        return self.op.isInc();
    }
    pub fn isCounter(self: *const Row) bool {
        return self.op.isCounter();
    }
    pub fn isMark(self: *const Row) bool {
        return self.op.isMark();
    }
    pub fn isDelete(self: *const Row) bool {
        return self.op.isDelete();
    }
    pub fn getIncrementValue(self: *const Row) ?i64 {
        return self.op.getIncrementValue();
    }
    pub fn cursor(self: *const Row) Error!ElemId {
        return self.op.cursor();
    }
    pub fn succCount(self: *const Row) usize {
        return self.op.succCount();
    }
    pub fn succAt(self: *const Row, i: usize) OpId {
        return self.op.succAt(i);
    }
    pub fn succIncCount(self: *const Row) usize {
        return self.op.succIncCount();
    }
    pub fn succIncAt(self: *const Row, i: usize) ?i64 {
        return self.op.succIncAt(i);
    }
    pub fn succ(self: *const Row) SuccCursors {
        return self.op.succ();
    }
    pub fn succInc(self: *const Row) opmod.SuccIncCursors {
        return self.op.succInc();
    }
    pub fn idActor(self: *const Row) ActorIdx {
        return self.op.idActor();
    }
    pub fn idCtr(self: *const Row) i64 {
        return self.op.idCtr();
    }
    pub fn opIdCtr(self: *const Row) u32 {
        return self.op.opIdCtr();
    }
    pub fn predCount(self: *const Row) u32 {
        return self.op.predCount();
    }
    pub fn pred(self: *const Row) []const OpId {
        return self.op.pred();
    }
};

/// A mark's payload, named so [`Row.markData`] has a return type to spell.
const MarkData = optypes.MarkData;

/// A `make_map` row carrying the given successor edges, and not the register
/// winner — a register whose winner is some other row.
fn shadowedRow(id: OpId, obj: ObjId, key: []const u8, succs: []const SuccEntry) Row {
    return plainRow(id, obj, key, succs);
}

fn plainRow(id: OpId, obj: ObjId, key: []const u8, succs: []const SuccEntry) Row {
    return .{
        .op = Op.init(
            0,
            false,
            id,
            .make_map,
            obj,
            .{ .map = key },
            false,
            .null_value,
            false,
            null,
            SuccCursors.fromSpan(succs, 0),
        ),
        .is_top = false,
        .is_visible = false,
    };
}

/// The chain `ROOT."a" -> A -> B -> C`, every level a made map and every row the
/// winner of its register.
///
/// `obj_info` then holds three objects — `A`, `B`, `C` — so a walk from `C`
/// spends all three and reaches the root.
fn chainRows() [3]Row {
    var rows: [3]Row = undefined;
    rows[0] = winner(opId(1, 0), .root, "a"); // makes A
    rows[1] = winner(opId(2, 0), made(1, 0), "b"); // makes B
    rows[2] = winner(opId(3, 0), made(2, 0), "c"); // makes C
    return rows;
}

/// The same chain with **`B`'s** making row losing a conflict: row 1 sits in
/// `A."b"` beside row 2, and row 1 carries a successor edge naming row 2, which
/// is how a conflict is written in the columns
/// ([`op_set.zig`](op_set.zig)'s `succ_r0` writes the same shape for a delete).
///
/// So a walk from `C` sees `B` as a container whose property is **not
/// visible** — the case `visible_path` answers null to (`parents.rs:39-41`) —
/// while `C`'s and `A`'s levels are visible.
fn conflictedRows() [4]Row {
    var rows: [4]Row = undefined;
    rows[0] = winner(opId(1, 0), .root, "a"); // makes A
    rows[1] = shadowedRow(opId(2, 0), made(1, 0), "b", &shadow_succ); // makes B, loses A."b"
    rows[2] = winner(opId(3, 0), made(1, 0), "b"); // makes the other map in A."b"
    rows[3] = winner(opId(4, 0), made(2, 0), "c"); // makes C, inside B
    return rows;
}

/// The one successor edge in this file: the operation at counter 3 took the
/// register `A."b"` from the operation at counter 2, which is what makes that
/// row the shadowed one in [`conflictedRows`].
///
/// **At container scope, not written inline.** A row's successor list is a
/// borrow, so `&.{ … }` written at the call site is a pointer into that call's
/// stack frame — and by the time the rows are spliced the frame is gone.
/// Written here it is static, exactly as [`op_set.zig`](op_set.zig)'s
/// `succ_r0` is.
const shadow_succ = [_]SuccEntry{.{ .id = opId(3, 0), .inc = null }};

/// Two objects whose parent entries point at each other: the operation at
/// counter 1 hangs in the object counter 2 made and vice versa.
///
/// **This is not a document automerge could produce.** It is exactly what the
/// bound in the module doc is for: an object index is rebuilt from an op
/// stream off disk or off a peer, and nothing in the column writer rules this
/// out. `obj_info` holds two objects, so the walk spends two and stops.
fn cycleRows() [2]Row {
    var rows: [2]Row = undefined;
    rows[0] = winner(opId(1, 0), made(2, 0), "a"); // object 1 hangs in object 2
    rows[1] = winner(opId(2, 0), made(1, 0), "b"); // object 2 hangs in object 1
    return rows;
}

/// The same row, declared as the register winner and visible.
fn winner(id: OpId, obj: ObjId, key: []const u8) Row {
    var row = plainRow(id, obj, key, &.{});
    row.is_top = true;
    row.is_visible = true;
    return row;
}

// ── The fixture op set ──────────────────────────────────────────────────────

/// An op set and the string table it borrows, at one address.
///
/// Heap-allocated because a struct that **owns** the table and is returned by
/// value cannot promise the table stays put: the copy lands in the caller's
/// frame and the op set's `strings.ctx` is left pointing at a dead local. This
/// is the same rule and the same reason as [`op_set.zig`](op_set.zig)'s
/// `Document`.
const Handle = struct {
    gpa: Allocator,
    table: Table,
    set: Walk.Set,

    /// Frees the op set, the table's strings, the table and the handle.
    fn destroy(self: *Handle) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// An op set holding `rows`, and the table it borrows.
fn handle(gpa: Allocator, rows: []const Row) !*Handle {
    const self = try gpa.create(Handle);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .table = Table.init(gpa), .set = undefined };
    errdefer self.table.deinit();
    self.set = try Walk.Set.fromActors(gpa, &fixture_actors, encoding, self.table.asTable());
    errdefer self.set.deinit();
    _ = try self.set.splice(0, rows);
    return self;
}

/// The chain document: `ROOT."a" -> A -> B -> C`, every level visible.
fn chainDoc(gpa: Allocator) !*Handle {
    const rows = chainRows();
    return handle(gpa, &rows);
}

/// The chain document with `B`'s making row in conflict.
fn conflictedDoc(gpa: Allocator) !*Handle {
    const rows = conflictedRows();
    return handle(gpa, &rows);
}

/// A clock over every operation up to and including `cutoff`.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// Collects a whole walk.
///
/// `limit` is a hard stop the test supplies so that a walk which did *not*
/// terminate reports itself instead of hanging the suite.
fn collect(
    gpa: Allocator,
    set: *Walk.Set,
    obj: ObjId,
    clock: ?Clock,
    limit: usize,
) ![]Parent {
    var out: std.ArrayList(Parent) = .empty;
    errdefer out.deinit(gpa);
    var walk = Parents(Row).init(set, obj, clock);
    while (try walk.next()) |step| {
        if (out.items.len >= limit) return error.WalkDidNotTerminate;
        try out.append(gpa, step);
    }
    return out.toOwnedSlice(gpa);
}

/// Compares two paths element-wise.
///
/// `expectEqual` on two slices compares their **pointers**
/// ([`std/testing.zig:130-139`](../../tmp/zig-global-cache/lib/std/testing.zig)),
/// and a [`Prop`] holds a slice besides, so neither `expectEqual` nor `==`
/// says anything here.
fn expectPath(got: []const PathElem, want: []const PathElem) !void {
    try testing.expectEqual(want.len, got.len);
    for (got, want, 0..) |g, w, i| {
        testing.expect(pathElemEqual(g, w)) catch |e| {
            std.debug.print("at {d}: got {any} want {any}\n", .{ i, g, w });
            return e;
        };
    }
}

/// `(ROOT, "a")`, `(A, "b")`, `(B, "c")` — the chain, root down.
///
/// **Returned by value on purpose.** `&.{ … }` from a function is a pointer to
/// a temporary, and two calls in one test measured differently — so a test
/// takes the array into a local and slices *that*.
fn chainPath() [3]PathElem {
    return .{
        .{ .obj = .root, .prop = .{ .key = "a" } },
        .{ .obj = exid(made(1, 0)), .prop = .{ .key = "b" } },
        .{ .obj = exid(made(2, 0)), .prop = .{ .key = "c" } },
    };
}

fn exid(id: ObjId) ExId {
    return id;
}

/// Every level of `chainDoc`'s walk, innermost first.
fn expectChainLevels(parents: []const Parent) !void {
    try testing.expectEqual(@as(usize, 3), parents.len);
    // Innermost first (`parents.rs:8-10`): the container, then its container,
    // then the root.
    try testing.expect(parents[0].obj.eql(exid(made(2, 0))));
    try testing.expect(parents[0].prop.eql(.{ .key = "c" }));
    try testing.expectEqual(ObjType.map, parents[0].typ);
    try testing.expect(parents[0].visible);

    try testing.expect(parents[1].obj.eql(exid(made(1, 0))));
    try testing.expect(parents[1].prop.eql(.{ .key = "b" }));
    try testing.expectEqual(ObjType.map, parents[1].typ);
    try testing.expect(parents[1].visible);

    try testing.expect(parents[2].obj.eql(.root));
    try testing.expect(parents[2].prop.eql(.{ .key = "a" }));
    try testing.expectEqual(ObjType.map, parents[2].typ);
    try testing.expect(parents[2].visible);
}

// ── 1 ───────────────────────────────────────────────────────────────────────

test "the root object has no parents: the walk is empty, and the path is empty" {
    const gpa = testing.allocator;
    const doc = try chainDoc(gpa);
    defer doc.destroy();

    var walk = Parents(Row).init(&doc.set, .root, null);
    try testing.expect((try walk.next()) == null);

    const nothing: [0]PathElem = .{};
    const path = try walk.path(gpa);
    defer gpa.free(path);
    try expectPath(path, &nothing);

    // `visible_path` returns `Some(vec![])` and not `None` for an object with
    // no levels (`parents.rs:35-45`), so the root is *distinguishable* from an
    // invisible object — which is null.
    const visible = (try walk.visiblePath(gpa)).?;
    defer gpa.free(visible);
    try expectPath(visible, &nothing);
}

// ── 2 ───────────────────────────────────────────────────────────────────────

test "a three-level object yields three parents innermost first, and path is the three pairs in order" {
    const gpa = testing.allocator;
    const doc = try chainDoc(gpa);
    defer doc.destroy();

    // Three made levels, so the index holds three objects and the walk has
    // three to spend (`Parents.init` reads the count).
    try testing.expectEqual(@as(usize, 3), doc.set.obj_info.count());

    const walk = Parents(Row).init(&doc.set, made(3, 0), null);
    try testing.expectEqual(@as(usize, 3), walk.remaining());

    const parents = try collect(gpa, &doc.set, made(3, 0), null, 8);
    defer gpa.free(parents);
    try expectChainLevels(parents);

    const want = chainPath();
    const path = try walk.path(gpa);
    defer gpa.free(path);
    try expectPath(path, &want);

    // The same three levels from the middle object: the path is a prefix of
    // the longer one, not a different answer.
    const mid = try Parents(Row).init(&doc.set, made(2, 0), null).path(gpa);
    defer gpa.free(mid);
    try expectPath(mid, want[0..2]);

    const top = try Parents(Row).init(&doc.set, made(1, 0), null).path(gpa);
    defer gpa.free(top);
    try expectPath(top, want[0..1]);
}

// ── 3 ───────────────────────────────────────────────────────────────────────

test "visiblePath is null when an ancestor is not visible, and the full path when every level is" {
    const gpa = testing.allocator;

    // Every level visible: the full path, in order.
    {
        const doc = try chainDoc(gpa);
        defer doc.destroy();
        const want = chainPath();
        const visible = (try Parents(Row).init(&doc.set, made(3, 0), null).visiblePath(gpa)).?;
        defer gpa.free(visible);
        try expectPath(visible, &want);
    }

    // `B`'s making row lost the conflict on `A."b"`, so the level that reports
    // `B` is not visible (`parents.rs:88-90`) and `visible_path` answers null
    // rather than a partial path (`parents.rs:39-41`).
    {
        const doc = try conflictedDoc(gpa);
        defer doc.destroy();

        const parents = try collect(gpa, &doc.set, made(4, 0), null, 8);
        defer gpa.free(parents);
        try testing.expectEqual(@as(usize, 3), parents.len);
        // The invisible level is the one whose container is `A`: the object it
        // made is `B`.
        try testing.expect(parents[1].obj.eql(exid(made(1, 0))));
        try testing.expect(!parents[1].visible);
        // Its neighbours are visible, so the null is the conflict and not a
        // walk that stopped early.
        try testing.expect(parents[0].visible);
        try testing.expect(parents[2].visible);

        // `path` still has all three: `visible` is dropped, not the level.
        const path = try Parents(Row).init(&doc.set, made(4, 0), null).path(gpa);
        defer gpa.free(path);
        try testing.expectEqual(@as(usize, 3), path.len);
        try testing.expect(path[1].obj.eql(exid(made(1, 0))));
        try testing.expect(path[1].prop.eql(.{ .key = "b" }));

        const visible = try Parents(Row).init(&doc.set, made(4, 0), null).visiblePath(gpa);
        try testing.expect(visible == null);
    }
}

// ── 4 ───────────────────────────────────────────────────────────────────────

test "a cyclic parent chain terminates at the object count" {
    const gpa = testing.allocator;
    const rows = cycleRows();
    const doc = try handle(gpa, &rows);
    defer doc.destroy();

    // Two objects, so the bound is two. A chain that does not repeat an object
    // cannot need more, so the bound is exactly what a good walk spends.
    try testing.expectEqual(@as(usize, 2), doc.set.obj_info.count());
    try testing.expectEqual(@as(usize, 2), (Parents(Row).init(&doc.set, made(1, 0), null)).remaining());

    // The index really is a cycle: each object hangs in the other. Without
    // this the test would pass for the wrong reason — a walk that stopped
    // because it could not find the object would also terminate.
    try testing.expect(doc.set.objectParent(made(1, 0)).?.eql(made(2, 0)));
    try testing.expect(doc.set.objectParent(made(2, 0)).?.eql(made(1, 0)));

    // `limit` is far above the bound: reaching it would mean the walk ran on.
    const parents = try collect(gpa, &doc.set, made(1, 0), null, 1000);
    defer gpa.free(parents);
    try testing.expectEqual(@as(usize, 2), parents.len);
    try testing.expect(parents[0].obj.eql(exid(made(2, 0))));
    try testing.expect(parents[0].prop.eql(.{ .key = "a" }));
    try testing.expect(parents[1].obj.eql(exid(made(1, 0))));
    try testing.expect(parents[1].prop.eql(.{ .key = "b" }));

    // The bound is spent, so the walk is over — not the root.
    var walk = Parents(Row).init(&doc.set, made(1, 0), null);
    _ = try walk.next();
    _ = try walk.next();
    try testing.expectEqual(@as(usize, 0), walk.remaining());
    try testing.expect((try walk.next()) == null);
    try testing.expect(!walk.obj.isRoot());

    const want: [2]PathElem = .{
        .{ .obj = exid(made(1, 0)), .prop = .{ .key = "b" } },
        .{ .obj = exid(made(2, 0)), .prop = .{ .key = "a" } },
    };
    const path = try Parents(Row).init(&doc.set, made(1, 0), null).path(gpa);
    defer gpa.free(path);
    try expectPath(path, &want);
}

// ── 5 ───────────────────────────────────────────────────────────────────────

test "the clock narrows the walk: a covering clock and a non-covering one answer differently" {
    const gpa = testing.allocator;
    const doc = try chainDoc(gpa);
    defer doc.destroy();
    const want = chainPath();

    // The document's own present: every operation is in view, so all three
    // levels are visible and `visible_path` is the whole chain.
    var full = try clockUpTo(gpa, 3);
    defer full.deinit();
    const in_present = try collect(gpa, &doc.set, made(3, 0), full, 8);
    defer gpa.free(in_present);
    try testing.expectEqual(@as(usize, 3), in_present.len);
    for (in_present) |step| try testing.expect(step.visible);
    const seen = (try Parents(Row).init(&doc.set, made(3, 0), full).visiblePath(gpa)).?;
    defer gpa.free(seen);
    try expectPath(seen, &want);

    // A clock that stops at counter 1: it covers `A`'s own making row and not
    // `B`'s, so the innermost level is out of view and `visible_path` is null
    // rather than a truncated path (`parents.rs:39-41`). The walk itself is
    // still three long — the clock scopes what is *visible*, it does not
    // shorten the chain (`parents.rs:52-74` reads the parent either way).
    var early = try clockUpTo(gpa, 1);
    defer early.deinit();
    const in_past = try collect(gpa, &doc.set, made(3, 0), early, 8);
    defer gpa.free(in_past);
    try testing.expectEqual(@as(usize, 3), in_past.len);
    try testing.expect(in_present[0].visible != in_past[0].visible);
    try testing.expect(in_present[1].visible != in_past[1].visible);
    try testing.expectEqual(in_present[2].visible, in_past[2].visible);
    for (in_present, in_past) |a, b| {
        try testing.expect(a.obj.eql(b.obj));
        try testing.expect(a.prop.eql(b.prop));
        try testing.expectEqual(a.typ, b.typ);
    }
    try testing.expect((try Parents(Row).init(&doc.set, made(3, 0), early).visiblePath(gpa)) == null);

    // A clock between the two is a third answer again: it covers `B`'s own
    // making row and not `C`'s, so exactly one level is out of view.
    var middle = try clockUpTo(gpa, 2);
    defer middle.deinit();
    const in_middle = try collect(gpa, &doc.set, made(3, 0), middle, 8);
    defer gpa.free(in_middle);
    try testing.expect(!in_middle[0].visible);
    try testing.expect(in_middle[1].visible);
    try testing.expect(in_middle[2].visible);
}

test "the clock decides a conflict: a level that lost the present wins an earlier one" {
    const gpa = testing.allocator;
    const doc = try conflictedDoc(gpa);
    defer doc.destroy();

    // The document's own present: `B`'s making row is covered *and* so is the
    // row that took its register from it, so it is not visible — the
    // "lost a conflict" half of `parents.rs:88-90`.
    var full = try clockUpTo(gpa, 4);
    defer full.deinit();
    const in_present = try collect(gpa, &doc.set, made(4, 0), full, 8);
    defer gpa.free(in_present);
    try testing.expectEqual(@as(usize, 3), in_present.len);
    try testing.expect(!in_present[1].visible); // `B` loses `A."b"`

    // A clock that stops at counter 2: the making row is covered and the row
    // that beat it is not, so within this clock nothing has deleted it and it
    // **is** the winner. The two answers differ at a level that is not the
    // innermost, which is what pins the clock to `parent_object` rather than
    // to "the object does not exist yet".
    var early = try clockUpTo(gpa, 2);
    defer early.deinit();
    const in_past = try collect(gpa, &doc.set, made(4, 0), early, 8);
    defer gpa.free(in_past);
    try testing.expectEqual(@as(usize, 3), in_past.len);
    try testing.expect(in_past[1].visible); // `B` wins `A."b"` at this clock
    try testing.expect(!in_past[0].visible); // `C` is not in this document yet
    try testing.expect(in_present[1].visible != in_past[1].visible);

    // Every other field is the clock's business nowhere: the chain, the
    // properties and the types are the same document either way.
    for (in_present, in_past) |a, b| {
        try testing.expect(a.obj.eql(b.obj));
        try testing.expect(a.prop.eql(b.prop));
        try testing.expectEqual(a.typ, b.typ);
    }

    // And it reaches the accessor: the present refuses a visible path, and so
    // does a clock that has not seen `C` — which is the honest answer for a
    // chain whose last made level is outside the clock.
    try testing.expect((try Parents(Row).init(&doc.set, made(4, 0), full).visiblePath(gpa)) == null);
    try testing.expect((try Parents(Row).init(&doc.set, made(4, 0), early).visiblePath(gpa)) == null);

    // `path` is the same under both clocks and is a real three-step answer,
    // not the null both `visible_path` calls gave.
    const want = chainPath();
    const path = try Parents(Row).init(&doc.set, made(4, 0), full).path(gpa);
    defer gpa.free(path);
    try expectPath(path, &want);
}

// ── 6 ───────────────────────────────────────────────────────────────────────

test "constructing a Parents allocates nothing, and reading it costs only what the op set's lookups cost" {
    // `FailingAllocator` with no `fail_index` set never fails and counts
    // every byte its inner allocator hands out, so it is a counter and a real
    // allocator at once. It is the **op set's** allocator, which is the only
    // allocator a walk can reach: `Parents` has none of its own, so any
    // allocation inside `init` or `next` would come through here.
    var counter: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const rows = chainRows();
    var doc = try handle(gpa, &rows);
    defer doc.destroy();

    // Warm the op set first: it sizes its own successor buffer the first time a
    // row walk needs one, and that allocation belongs to the op set
    // ([`OpSet.splice`](op_set.zig) refits it the same way).
    var warm = Parents(Row).init(&doc.set, made(3, 0), null);
    while (try warm.next()) |_| {}

    const before = counter.allocated_bytes;

    // **Constructing one allocates nothing**: four words and a pointer, and
    // the object count it reads is a field lookup.
    var walk = Parents(Row).init(&doc.set, made(3, 0), null);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **Reading it costs exactly what the op set's own lookups cost, and not
    // one byte more.** A level is one `OpSet.parentObject` call, and that call
    // is what allocates: `OpSet.getOpIdPos` descends the id B-tree, and the
    // descent's frame stack is the allocation. The baseline below is three of
    // those calls made directly, so the walk is measured against the cost of
    // the work it does rather than against nothing.
    const baseline_before = counter.allocated_bytes;
    _ = try doc.set.parentObject(made(3, 0), null);
    _ = try doc.set.parentObject(made(2, 0), null);
    _ = try doc.set.parentObject(made(1, 0), null);
    const baseline_after = counter.allocated_bytes;

    var seen: [3]Parent = undefined;
    var levels: usize = 0;
    while (try walk.next()) |step| {
        try testing.expect(levels < seen.len);
        seen[levels] = step;
        levels += 1;
    }
    const walk_after = counter.allocated_bytes;
    try testing.expectEqual(@as(usize, 3), levels);
    try testing.expectEqual(baseline_after - baseline_before, walk_after - baseline_after);
    try expectChainLevels(seen[0..levels]);

    // `path` allocates, by design: the depth is not known until the walk is
    // over. It is the one entry point here that takes an allocator.
    const want = chainPath();
    const path = try Parents(Row).init(&doc.set, made(3, 0), null).path(gpa);
    defer gpa.free(path);
    try testing.expect(counter.allocated_bytes > before);
    try expectPath(path, &want);
}

// ── 7 ───────────────────────────────────────────────────────────────────────

test "an object the op set does not hold is an empty walk, not a trap" {
    const gpa = testing.allocator;
    const doc = try chainDoc(gpa);
    defer doc.destroy();

    // Counter 99 is in no column and in no index entry, which is what an
    // `ExId` from a peer that has not been merged yet looks like.
    const unknown = made(99, 0);
    try testing.expectEqual(@as(?ObjId, null), doc.set.objectParent(unknown));
    try testing.expectEqual(@as(?ObjType, null), doc.set.objectType(unknown));

    var walk = Parents(Row).init(&doc.set, unknown, null);
    try testing.expect((try walk.next()) == null);

    const nothing: [0]PathElem = .{};
    const path = try walk.path(gpa);
    defer gpa.free(path);
    try expectPath(path, &nothing);

    // Upstream `.unwrap()`s here (`parents.rs:62-65`) and panics; the port
    // answers "no parents", which is the same answer it gives the root and the
    // one a caller can act on.
    const visible = (try walk.visiblePath(gpa)).?;
    defer gpa.free(visible);
    try expectPath(visible, &nothing);

    // A root id is not an object id: `opId()` is null for it and the walk
    // stops on that alone, before any lookup (`parents.rs:53-55`).
    const root_id: ExId = .root;
    try testing.expectEqual(@as(?OpId, null), root_id.opId());
    var root_walk = Parents(Row).init(&doc.set, .root, null);
    try testing.expectEqual(@as(usize, 3), root_walk.remaining());
    try testing.expect((try root_walk.next()) == null);
}
