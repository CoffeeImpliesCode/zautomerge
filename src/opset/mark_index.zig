//! The op set's mark index: the row-aligned column that says which rows open a
//! mark and which close one, the cache from a mark's begin operation to the
//! name and value it puts on its span, and the prefix aggregate that turns the
//! two into the set of marks open at a position
//! (`rust/automerge/src/op_set2/op_set/mark_index.rs`, 819 lines).
//!
//! # The word, and what it is pinned against
//!
//! `MarkIdx` is two operations over one row: `Start(id)` opens the mark whose
//! begin is `id`, and `End(id)` closes that same mark. The `id` in an `End` is
//! the *begin's*, not the end's (`mark_index.rs:12-16`, `:54-58`): a mark is
//! two back-to-back inserts, so the end operation's own id is the begin's plus
//! one in the same actor and `Op::mark_index` passes `self.id.prev()`
//! (`op_set2/op.rs:199`; the rule is at `marks.rs:96-101`). The two are one
//! signed 64-bit word, an `End` being the negation of its `Start`
//! (`mark_index.rs:25-34`, decoded by `load` at `:36-49`), and that word is
//! what upstream's RLE codec packs and unpacks through `as_i64` and `load`
//! (`:64-78`).
//!
//! **The word is not part of a saved document.** The exporter writes the
//! sixteen data columns and has no arm for the mark index
//! (`op_set2/columns.rs:135-170`); a load builds the index columns empty
//! (`:252-330`, `Indexes::default()` at `:314`) because a load *rebuilds*
//! them, every one of them being derived state the data columns already
//! determine (`:314`, `op_set2/op_set/index.rs:210-213`). The word is pinned
//! anyway, for two reasons that are real: upstream cross-checks it in both
//! directions with `debug_assert_eq!` (`mark_index.rs:29-33`, `:42-47`), so a
//! word that does not round trip is a bug upstream would have caught; and this
//! port's column layer is integer-only, so the word is what the column
//! actually holds. The aliasing the encoding admits at and above actor index
//! 2^31 is a property of that representation, so it is pinned as one and
//! written down where it bites rather than papered over.
//!
//! # The column, and the aggregate that is not its weight
//!
//! Upstream's column is a `PrefixColumn<Option<MarkIdx>>`
//! (`mark_index.rs:213-217`) over a `MarkIdx` whose prefix value *is* the
//! aggregate (`mark_index.rs:193-194`, `impl PrefixValue for MarkIdx { type
//! Prefix = MarkAcc; }`), so the aggregate the index stores per slab is that
//! same set, and the b-tree's own weight carries it.
//!
//! `marks_at` is one line: `let acc = self.data.get_total(target);`
//! (`mark_index.rs:323`, over the method at `:315-331`). That is
//! `get_prefix(index + 1)` (`hexane/src/prefix.rs:554-556`), which is
//! `iter_range(index..len()).total` (`:547-549`), and `iter_range` seeks with
//! `advance_by` (`:903`) — ONE `find_slab_at_item` descent (`:825`) that hands
//! back the aggregate standing at that slab's first row, which seeds the
//! running prefix. So upstream folds the runs of the **landing slab only**,
//! bounded by a slab's run budget, and the answer costs `O(log S)` plus one
//! slab.
//!
//! The port's column engine instantiates `btree.Tree(A)` over a weight that
//! declares `Aggregate.{identity, merge, itemCount, eql}` and never looks
//! inside one (`hexane/btree.zig:163-168`; those four aliases are the whole of
//! the generic core's use of `A`) — which is why a set-valued aggregate *fits*
//! the tree. It cannot hold one as written, because the tree copies weights
//! byte for byte (`copyOf` is `gpa.dupe`, `btree.zig:150-157`, called from the
//! clone at `:272-273` and from every node build after it) and `Tree.deinit`
//! (`:284-295`) frees none of what a weight owns: a weight carrying sets would
//! alias the staging buffer the column frees immediately after building the
//! index (`hexane/column.zig:3227-3237`) and leak the rest of itself. Giving
//! the weight ownership is a change to `btree.zig` — an `Aggregate` that
//! declares `deinit` and `clone` for its weight — and it is not this file's
//! to make.
//!
//! So the aggregate is kept the way a `Column` keeps its own `agg_before`
//! (`hexane/column.zig:2795`, filled by `rebuildAggs` at `:6428-6447`): a flat
//! per-slab prefix array **the column owns** ([`AggPrefix`]), one entry per
//! slab, holding the aggregate over the rows *before* that slab.
//! [`MarkIndexColumn.total`] descends to the slab holding `target`
//! ([`Column.locate`](../../src/hexane/column.zig), `:5732-5742`), copies that
//! entry, and folds the runs of the landing slab alone: the same answer
//! upstream reaches, by the same two steps, at the same cost. The array is not
//! the tree's weight — it is beside it, and `btree.zig` is not asked for
//! anything.
//!
//! # Why the aggregate is a set and not a count
//!
//! Upstream says it at `mark_index.rs:80-97` and the port repeats it: each op
//! id appears at most once as a `Start` and at most once as an `End` in one
//! column, so its net contribution is one of `{-1, 0, +1}` and `0` cancels
//! rather than being stored. That is what lets the aggregate be two sets
//! instead of a `HashMap<OpId, i32>`, and it is why `opens` is a *set* of ids:
//! every reader here asks which marks are open (`mark_index.rs:322-329`, and
//! the oracle at `:676-690`), which a count cannot answer.
//!
//! The port keeps each set as a sorted flat array of op ids rather than a hash
//! set, for the reason `marks.zig:192-198` gives for the other mark
//! collections in this crate and for one more: a set inside a value that gets
//! moved — into the iterator `marksAt` returns — cannot hand out a borrow of
//! itself, so a hash set would have to be boxed. A sorted array is a binary
//! search and a memmove, and it makes the iteration order the document's op-id
//! order (counter, then actor, `types.zig:162-170`) rather than a hash order,
//! which is what lets every test below be an exact comparison.
//!
//! # A run folds as one delta
//!
//! A run of more than one row carrying the same `MarkIdx` cannot occur in a
//! well-formed column, because the column's uniqueness invariant makes the same
//! op id open the same mark twice (`mark_index.rs:199-207`), so a run's count
//! is folded once and never multiplied by it. The tests do not take that on
//! faith: the oracle walks one row at a time, so a run of count two would make
//! the two disagree, and one test asserts that every non-null run of a
//! well-formed column has count one.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const optypes = @import("types.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const ParseError = err.ParseError;
const OpId = types.OpId;
const ActorIdx = types.ActorIdx;
const Clock = clockmod.Clock;
const MarkData = optypes.MarkData;

/// The word a `MarkIdx` occupies in the column: a signed 64-bit integer, or null
/// for a row that carries no mark (`mark_index.rs:25-34`, over the
/// `Option<MarkIdx>` column at `:213-217`).
///
/// The column layer stores integers, so this is the column's value type and
/// `MarkIdx.load` is the decode. Upstream splits the same pair the other way
/// round — a column of `Option<MarkIdx>` whose RLE codec converts at the byte
/// boundary (`:64-78`) — which is the same relation with the seam on the other
/// side of it.
const Word = ?i64;

/// The column of mark index words. Upstream's is a
/// `PrefixColumn<Option<MarkIdx>>` (`mark_index.rs:213-217`); the module
/// comment gives the one place this differs and why.
const DataColumn = column.Column(Word, column.RleOption(i64));

/// The column's own cursor, which is what `ValueIter` decodes.
const WordIter = DataColumn.Iterator;

/// A row of the mark index: a mark opens here, or the mark that opened earlier
/// closes here (`mark_index.rs:12-16`).
pub const MarkIdx = union(enum) {
    /// A mark's *begin* operation opens here.
    start: OpId,
    /// The mark whose begin is this id closes here. Never the end operation's
    /// own id (`mark_index.rs:54-58`, `op_set2/op.rs:199`).
    end: OpId,

    /// The word this row occupies: `(actor << 32) | counter`, and the negation
    /// of it for an `End` (`mark_index.rs:25-34`).
    ///
    /// The arithmetic is [`markIdxWord`]'s, and this is where a `MarkIdx` gets
    /// its word. The shift is `u64` and the result is reinterpreted, so the
    /// encoding is upstream's plain bit shift (`mark_index.rs:27`) whatever
    /// `Zig`'s `<<` does with bits past the sign bit — which nothing here has
    /// to know, because the operator table says only that `a << b` moves bits
    /// left and inserts zeroes at the least-significant bit, and the
    /// "integer overflow" list names `+`, `-`, negation, `*`, `/`,
    /// `@divTrunc`, `@divFloor` and `@divExact` and not `<<`. The two
    /// spellings are bit-identical in any case: the counter is widened from
    /// `u32` into only the low 32 bits, so nothing can carry into the actor
    /// half, and upstream's `+` over two disjoint `u32` halves cannot either.
    /// `types.rs:447-453` has the same shape for the actor index.
    ///
    /// At and above actor index 2^31 the top bit is the sign bit and the
    /// row's polarity stops being recoverable, so the encoding is only
    /// injective below 2^31.
    pub fn asI64(self: MarkIdx) i64 {
        return switch (self) {
            .start => |begin| markIdxWord(begin),
            .end => |begin| endWord(begin),
        };
    }

    /// The row a word stands for (`mark_index.rs:36-49`). Total over every
    /// `i64`: the negation wraps instead of overflowing, so `minInt(i64)`
    /// decodes to an `End` of actor 2^31 rather than trapping. Upstream's
    /// `-v as u64` wraps the same way in a release build and traps in a debug
    /// one; this port never traps.
    pub fn load(v: i64) MarkIdx {
        const bits: u64 = @bitCast(if (v < 0) -%v else v);
        const begin = OpId.init(@truncate(bits), @truncate(bits >> 32));
        return if (v < 0) .{ .end = begin } else .{ .start = begin };
    }

    /// The same row with `idx` inserted into the actor table
    /// (`mark_index.rs:51-58`). Every actor index at or above `idx` shifts up
    /// by one (`types.rs:447-453`).
    pub fn withNewActor(self: MarkIdx, idx: ActorIdx) MarkIdx {
        return switch (self) {
            .start => |begin| .{ .start = begin.withNewActor(idx) },
            .end => |begin| .{ .end = begin.withNewActor(idx) },
        };
    }

    /// The same row with the actor at `idx` taken out of the actor table
    /// (`MarkIdx::with_new_actor`'s inverse, `types.rs:455-461`): every actor
    /// index above `idx` comes down by one.
    ///
    /// **Null when the row names `idx` itself**, and that is the whole reason
    /// this exists. `OpId::withoutActor` can answer that with null because an
    /// op id *is* its actor and the caller drops the entry; a row of this column
    /// cannot drop anything — the index is row-aligned with the op set, so
    /// turning a row into "no mark" would move every row above it. So the
    /// caller has to ask ([`MarkIndexColumn.referencesActor`]) before it
    /// renumbers downwards, and the null here is the answer to a question
    /// nobody should have got wrong.
    ///
    /// Upstream has no counterpart: its `OpSet::remove_actor`
    /// (`op_set2/op_set.rs:1419-1429`) renumbers `cols` and `obj_info` and
    /// **never touches the mark index at all** — the omission the module's
    /// [`MarkIdx`] and [`MarkIndexColumn`] docs pin, and the reason this
    /// method exists on the port's side.
    pub fn withoutActor(self: MarkIdx, idx: ActorIdx) ?MarkIdx {
        return switch (self) {
            .start => |begin| if (begin.withoutActor(idx)) |shifted| .{ .start = shifted } else null,
            .end => |begin| if (begin.withoutActor(idx)) |shifted| .{ .end = shifted } else null,
        };
    }

    /// The actor index this row names, whichever way it opens or closes
    /// (`mark_index.rs:25-34`: both words carry the same actor half).
    pub fn actorIndex(self: MarkIdx) ActorIdx {
        return switch (self) {
            .start => |begin| begin.actor,
            .end => |begin| begin.actor,
        };
    }

    /// Whether two rows are the same row (`PartialEq for MarkIdx`,
    /// `mark_index.rs:99-102`): same variant, same `OpId`. It is **not** a
    /// comparison of the 64-bit word.
    ///
    /// The distinction has teeth at actor index 2^31, where the word stops
    /// being injective: `.{ .start = OpId.init(0, 0x8000_0000) }` and
    /// `.{ .end = OpId.init(0, 0) }` both encode as `minInt(i64)` and are
    /// unequal here. The alias is pinned by `test "the largest actor and
    /// counter the word holds, and the alias above it"`
    /// (`mark_index.zig:1081`); this method is what the RLE column and the
    /// uniqueness check compare by, so the answer stays the variant and the
    /// id even where the word cannot.
    pub fn eql(a: MarkIdx, b: MarkIdx) bool {
        return switch (a) {
            .start => |begin| b == .start and b.start.eql(begin),
            .end => |begin| b == .end and b.end.eql(begin),
        };
    }
};

/// `(actor << 32) | counter` as the stored word (`mark_index.rs:27`, `:43`).
/// Both halves are `u32` and disjoint, so upstream's `+` and a bitwise or agree.
///
/// **This is the one definition of the word in the crate.** [`MarkIdx.asI64`]
/// reads it, and so do `Op.markIndex` and `OpBuilder.markIndex`
/// ([`op.zig`](op.zig)), which build the same word from a mark row's own id
/// through their own `markIdxWord` forwarder. Those two used to be a second
/// copy of this expression written in `i64`; a word written by the op row and
/// read by this file's column is bit-identical now by construction rather
/// than by inspection, and the signed copy's justification is gone with it.
///
/// `columns.zig` owns the column the word is stored in
/// (`columns.zig:298-311`); this is only the arithmetic. The sign of the word
/// carries the row's polarity, which is what makes a begin sort before the
/// end that closes it.
pub fn markIdxWord(begin: OpId) i64 {
    return @bitCast((@as(u64, begin.actor) << 32) | @as(u64, begin.counter));
}

/// The same word negated: what an `End` row occupies (`mark_index.rs:31-33`).
/// The negation wraps, so it is the exact inverse of [`MarkIdx.load`] over
/// every `i64` rather than an overflow at `minInt(i64)`.
fn endWord(begin: OpId) i64 {
    return -%markIdxWord(begin);
}

/// A row of the mark index as it arrives from the op stream: a mark opens, and
/// the begin operation carries the name and value it puts on its span
/// (`mark_index.rs:18-22`). A mark end carries nothing but the begin's id,
/// because the value column alone does not tell an unmark from a mark end —
/// `MarkData` is present for a begin only (`op_set2/op.rs:75-79`).
pub const MarkIndexBuilder = union(enum) {
    /// A mark begins here. `id` is the begin operation's own id, and `data`
    /// is what it puts on the span.
    start: struct { id: OpId, data: MarkData },
    /// The mark whose begin is this id ends here.
    end: OpId,

    /// The word this row occupies in the column. Upstream maps the builder to a
    /// `MarkIdx` in the same pass that fills the cache
    /// (`mark_index.rs:279-288`).
    pub fn word(self: MarkIndexBuilder) Word {
        return switch (self) {
            .start => |s| markIdxWord(s.id),
            .end => |v| endWord(v),
        };
    }
};

// ── MarkAcc: the prefix aggregate over the column's rows ───────────────────

/// One set of op ids, sorted by the document's op-id order (`types.zig:162-170`).
/// The module comment gives why this is a sorted array and not a hash set.
const IdSet = std.ArrayList(OpId);

/// The aggregate of a run of the column: which marks are open over it and which
/// are left dangling (`mark_index.rs:99-103`).
///
/// **A set and not a count**, and this is why, from `mark_index.rs:80-97`: each
/// op id appears at most once as a `Start` and at most once as an `End` per
/// column, so its net contribution is one of `{-1, 0, +1}` and `0` cancels
/// rather than being stored. A count would answer "how many marks are open
/// here"; every reader asks *which*.
///
/// * `opens` — `+1`: a `Start` seen whose `End` has not been matched.
/// * `closes` — `-1`: an `End` seen whose `Start` has not been matched.
///
/// For the **running prefix** over a well-formed column, `closes` stays empty:
/// every `End` cancels with a `Start` from an earlier row
/// (`mark_index.rs:94-97`). A per-slab aggregate may hold a non-empty `closes`
/// when a mark's span crosses a subtree boundary, which is why `marksAt`
/// reports a non-empty `closes` as a malformed column (`mark_index.rs:319-323`).
///
/// An id is never in both sets: every operation that would put it in the second
/// one first takes it out of the first, which is upstream's remove-then-insert
/// order (`mark_index.rs:106-122`, `:126-157`).
pub const MarkAcc = struct {
    /// The allocator both sets are allocated with and the one
    /// [`MarkAcc.deinit`] frees them with. It is a field rather than a
    /// parameter because an aggregate is a *value* that gets moved — into the
    /// iterator `marksAt` returns, and in and out of [`MarkAcc.add`] and
    /// [`MarkAcc.sub`] — and a moved value cannot be handed the allocator it
    /// was built with. `marks.zig:325-338` keeps it the same way for the same
    /// reason. A copied aggregate shares its two allocations, so exactly one
    /// of the two copies may be freed.
    gpa: Allocator,

    /// The marks open over the rows this aggregate covers.
    opens: IdSet = .empty,
    /// The marks left dangling over the rows this aggregate covers.
    closes: IdSet = .empty,

    /// The aggregate of no rows at all.
    pub fn init(gpa: Allocator) MarkAcc {
        return .{ .gpa = gpa };
    }

    /// Frees both sets. The allocator is a field rather than a parameter
    /// because an aggregate is a *value* that gets moved — into the iterator
    /// `marksAt` returns — and a moved value cannot be handed the allocator it
    /// was built with. `marks.zig:325-338` keeps it the same way for the same
    /// reason.
    ///
    /// Afterwards the value is `undefined`: no method may be called on it, and
    /// a second call frees `undefined`, which no optimize mode diagnoses. Call
    /// it exactly once per aggregate. A copy taken beforehand shares both
    /// allocations, so freeing both copies frees the same memory twice — the
    /// copy is not a second owner.
    pub fn deinit(self: *MarkAcc) void {
        self.opens.deinit(self.gpa);
        self.closes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Folds one row's delta in (`mark_index.rs:105-123`).
    ///
    /// A `Start` cancels a prior dangling `End` and otherwise opens; an `End`
    /// cancels a prior open and otherwise records a dangling close. That is the
    /// whole rule, and the uniqueness guarantee is what makes cancelling
    /// unambiguous.
    pub fn applyOne(self: *MarkAcc, val: MarkIdx) Allocator.Error!void {
        switch (val) {
            .start => |begin| try self.absorb(&self.opens, &self.closes, begin),
            .end => |begin| try self.absorb(&self.closes, &self.opens, begin),
        }
    }

    /// Adds `rhs` in and frees it (`AddAssign for MarkAcc`,
    /// `mark_index.rs:126-139`).
    ///
    /// `rhs` is consumed, as upstream's by-value right-hand side is. Zig passes
    /// a struct by copy, so the caller must not use `rhs` afterwards: this
    /// frees the two sets `rhs` names, on the success path and on the failure
    /// path alike. `addAssignRef` is the form that borrows.
    ///
    /// **On failure `self` holds a partial merge.** The only failing step is
    /// growing one of the two sets, so an `Allocator.Error` here leaves some of
    /// `rhs.opens` already folded into `self.opens` and possibly some of
    /// `rhs.closes` already folded into `self.closes`, while `rhs` has already
    /// been freed. The residue is *not* idempotent: adding an id that is
    /// already present is what takes it out of the other set, so retrying with
    /// another copy of the same aggregate would undo entries that had landed.
    /// A caller that gets an error must therefore **discard** `self`, not retry
    /// it. [`MarkAcc.add`] does exactly that — its `errdefer` frees the partial
    /// result — which is why the composed helpers are safe even though this
    /// one is not. Upstream cannot reach the state at all: a Rust `Vec` push
    /// that cannot allocate aborts instead of returning an error.
    pub fn addAssign(self: *MarkAcc, rhs: MarkAcc) Allocator.Error!void {
        var taken = rhs;
        defer taken.deinit();
        for (taken.opens.items) |begin| try self.absorb(&self.opens, &self.closes, begin);
        for (taken.closes.items) |begin| try self.absorb(&self.closes, &self.opens, begin);
    }

    /// Adds `rhs` in without taking it (`AddAssign<&MarkAcc> for MarkAcc`,
    /// `mark_index.rs:141-157`).
    ///
    /// This is the shape the index descent wants, cited there as the hot path:
    /// the child aggregate is borrowed and merged one set operation per entry,
    /// with no clone. The port folds its own prefix rather than descending
    /// (see the module comment), so this has no caller in the column path; it
    /// is the operation the aggregate exists for, and the tests pin it.
    pub fn addAssignRef(self: *MarkAcc, rhs: *const MarkAcc) Allocator.Error!void {
        for (rhs.opens.items) |begin| try self.absorb(&self.opens, &self.closes, begin);
        for (rhs.closes.items) |begin| try self.absorb(&self.closes, &self.opens, begin);
    }

    /// Takes `rhs` back out and frees it (`SubAssign for MarkAcc`,
    /// `mark_index.rs:159-175`). The exact inverse of `addAssign`: a value
    /// that merged into a set is removed, and one that cancelled a member of
    /// the other set is restored. `rhs` is consumed, as above, and so is the
    /// failure path: an `Allocator.Error` leaves `self` holding a partial
    /// restore — some of `rhs.opens` already taken out of `self.opens` and
    /// possibly some of `rhs.closes` already moved back into it — which is
    /// exactly as non-retryable as [`MarkAcc.addAssign`]'s. Only growing a set
    /// fails here, never the removals, and the residue is discarded by the
    /// caller; [`MarkAcc.sub`] does it with an `errdefer`.
    pub fn subAssign(self: *MarkAcc, rhs: MarkAcc) Allocator.Error!void {
        var taken = rhs;
        defer taken.deinit();
        for (taken.opens.items) |begin| try self.restore(&self.opens, &self.closes, begin);
        for (taken.closes.items) |begin| try self.restore(&self.closes, &self.opens, begin);
    }

    /// `a + b`, consuming both (`Add for MarkAcc`, `mark_index.rs:177-183`).
    ///
    /// Both operands are left undefined: the result takes over `a`'s two sets
    /// and `b`'s are merged in and freed, which is what upstream's by-value
    /// `self` and `rhs` do. A Zig argument would be a copy, and mutating a
    /// copy of a set that still shares its storage with the caller is how this
    /// would corrupt one, so the consumed operands arrive as pointers and are
    /// undefined on return.
    pub fn add(a: *MarkAcc, b: *MarkAcc) Allocator.Error!MarkAcc {
        var out = a.*;
        a.* = undefined;
        errdefer out.deinit();
        const rhs = b.*;
        b.* = undefined;
        try out.addAssign(rhs);
        return out;
    }

    /// `a - b`, consuming both (`Sub for MarkAcc`, `mark_index.rs:185-191`).
    pub fn sub(a: *MarkAcc, b: *MarkAcc) Allocator.Error!MarkAcc {
        var out = a.*;
        a.* = undefined;
        errdefer out.deinit();
        const rhs = b.*;
        b.* = undefined;
        try out.subAssign(rhs);
        return out;
    }

    /// Order-independent, as upstream's derived `PartialEq` is
    /// (`mark_index.rs:99`). Both sets are sorted, so it is elementwise.
    pub fn eql(a: MarkAcc, b: MarkAcc) bool {
        return idSeqEql(a.opens.items, b.opens.items) and
            idSeqEql(a.closes.items, b.closes.items);
    }

    /// Two sorted id sequences, element by element. `std.mem.eql` needs `==`,
    /// which a struct has not got (`types.zig:145-157`).
    fn idSeqEql(x: []const OpId, y: []const OpId) bool {
        if (x.len != y.len) return false;
        for (x, y) |p, q| {
            if (!p.eql(q)) return false;
        }
        return true;
    }

    /// `begin` into `to`, unless it is in `other`, which it is taken out of
    /// instead: one `Start`-shaped delta (`mark_index.rs:108-113`, `:128-133`).
    fn absorb(self: *MarkAcc, to: *IdSet, other: *IdSet, begin: OpId) Allocator.Error!void {
        _ = removeSorted(other, begin) orelse try insertSorted(self.gpa, to, begin);
    }

    /// The inverse of `absorb`, `End`-shaped (`mark_index.rs:160-174`).
    fn restore(self: *MarkAcc, from_set: *IdSet, other: *IdSet, begin: OpId) Allocator.Error!void {
        _ = removeSorted(from_set, begin) orelse try insertSorted(self.gpa, other, begin);
    }
};

/// A fresh aggregate holding `src`'s two sets, in `gpa`.
///
/// **The room is taken before the merge, not during it.** `addAssignRef`
/// inserts one id at a time, and an `ArrayList` that has to grow on the way
/// allocates and copies on the way; reserved up front the same merge is two
/// allocations and one pass whichever of the two sets is bigger. A prefix
/// read is nothing but this merge, so it is where the count is worth taking.
///
/// **Two set differences, not a merge — and that is the whole of the
/// difference from `addAssignRef`.** `out` starts empty, and each of `src`'s
/// two sets is sorted and free of duplicates (`insertSorted`, which is the
/// only way an id gets into either), so the merge has nothing to merge
/// against and lands where it lands in two steps:
///
/// * the loop over `src.opens` misses an empty `out.closes` every time, so
///   every one of its ids is inserted — going in `src`'s own sorted order,
///   each at the end — and `out.opens` ends as `src.opens`;
/// * the loop over `src.closes` then takes each of its ids **out** of
///   `out.opens` where it is there, and otherwise puts it in `out.closes`.
///
/// So the answer is `opens \ closes` and `closes \ opens` — the second loop
/// again — and each is one linear walk of two already-sorted sequences
/// ([`differenceInto`]). That needs nothing of `src` beyond the two
/// properties above, so it holds for a `src` whose sets share an id as well
/// as for one that does not, and the argument does not rest on the
/// never-in-both invariant [`MarkAcc`] states.
///
/// What it buys is the difference between `O(k)` and `O(k*k)`: `addAssignRef`
/// inserts one id at a time, and an ordered insert into a sorted `ArrayList`
/// memmoves everything behind the insertion point, so `k` of them move
/// `0 + 1 + ... + (k-1)` slots — `k*(k-1)/2` of them, which for the `k`
/// marks open behind a row of a document with 2500 of them is hundreds of
/// thousands of `OpId`s moved per read, against the `k` a walk moves.
///
/// **The refusal is at the same point as it was.** Both `ensureTotalCapacity`
/// calls come first and are the only two steps that can fail; neither walk
/// allocates.
fn copyAcc(gpa: Allocator, src: *const MarkAcc) Allocator.Error!MarkAcc {
    var out = MarkAcc.init(gpa);
    errdefer out.deinit();
    try out.opens.ensureTotalCapacity(gpa, src.opens.items.len);
    try out.closes.ensureTotalCapacity(gpa, src.closes.items.len);
    differenceInto(&out.opens, src.opens.items, src.closes.items);
    differenceInto(&out.closes, src.closes.items, src.opens.items);
    return out;
}

/// Appends `keep \ drop` to `into`, in the order it is already in. `keep` and
/// `drop` are sorted and hold no duplicates — the invariant every aggregate
/// keeps ([`MarkAcc`]) — so the answer is the merge of the two sequences and
/// one pointer over `drop` is the whole of the state. The caller has reserved
/// the room, so this cannot refuse.
fn differenceInto(into: *IdSet, keep: []const OpId, drop: []const OpId) void {
    var d: usize = 0;
    for (keep) |begin| {
        while (d < drop.len and drop[d].order(begin) == .lt) d += 1;
        if (d < drop.len and drop[d].eql(begin)) continue;
        into.appendAssumeCapacity(begin);
    }
}

/// The first index of `items` whose id does not sort before `begin`. The sets are
/// sorted by `OpId.order` (`types.zig:163`), so this is a binary search, and it
/// is the routine `marks.zig:426-438` uses for mark names.
fn lowerBound(items: []const OpId, begin: OpId) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].order(begin) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Inserts `begin` keeping the order, and does nothing if it is already there.
fn insertSorted(gpa: Allocator, set: *IdSet, begin: OpId) Allocator.Error!void {
    const at = lowerBound(set.items, begin);
    if (at < set.items.len and set.items[at].eql(begin)) return;
    try set.insert(gpa, at, begin);
}

/// Removes `begin`, and answers whether it was there.
fn removeSorted(set: *IdSet, begin: OpId) ?OpId {
    const at = lowerBound(set.items, begin);
    if (at >= set.items.len or !set.items[at].eql(begin)) return null;
    return set.orderedRemove(at);
}

/// Whether `begin` is in the set.
fn containsSorted(items: []const OpId, begin: OpId) bool {
    const at = lowerBound(items, begin);
    return at < items.len and items[at].eql(begin);
}

// ── The readers ───────────────────────────────────────────────────────────

/// The marks open at one position, keyed by the *begin* operation's id
/// (`marks.rs:403-406`, upstream's `RichTextQueryState::map`).
///
/// This is that map and nothing else. Upstream's `RichTextQueryState` also
/// carries a `block` field, which only its `process` sets and which no path
/// through this column ever sets (`mark_index.rs:302-313` builds only the map),
/// so a consumer that needs the block adds it where it consumes the map.
pub const OpenMarks = std.AutoHashMapUnmanaged(OpId, MarkData);

/// The mark ids open at a position, filtered by a clock
/// (`mark_index.rs:315-331`).
///
/// The aggregate is owned rather than borrowed, so this is a value the caller
/// frees with `deinit`.
pub const MarkIter = struct {
    /// The marks open at the position, in the document's op-id order. Owned:
    /// `marksAt` hands this over and `deinit` gives it back, and it is the
    /// only allocation the iterator has — an `OpenMarks` map is a separate
    /// value with its own `deinit` (`richTextAt`).
    acc: MarkAcc,

    /// Which open mark the next `next` returns.
    index: usize = 0,
    /// When set, only the marks the clock covers are yielded
    /// (`mark_index.rs:328`).
    clock: ?Clock,

    /// Frees the owned [`MarkAcc`] — both of its `ArrayList`s, with the
    /// allocator `total` built the aggregate with — and nothing else. The
    /// borrowed `clock` is not freed: it is a view the caller still owns, and
    /// it must therefore outlive this iterator or be null.
    ///
    /// Afterwards the value is `undefined`: no method may be called on it and
    /// a second call frees `undefined`, which no optimize mode diagnoses, so
    /// call it exactly once per iterator. A copy shares the aggregate with the
    /// original, so at most one of the two may be freed. `next` returning null
    /// does not free anything and does not remove this obligation.
    pub fn deinit(self: *MarkIter) void {
        self.acc.deinit();
        self.* = undefined;
    }

    /// The next open mark the clock covers, or null at the end of the walk.
    ///
    /// Total: `null` is the end and only the end. A mark the clock does not
    /// cover is stepped over rather than yielded, so a mark that is open but
    /// not visible at this clock does not end the walk. Every id yielded is a
    /// *begin* id, which is the key `markData` and `richTextAt` answer by, and
    /// the value is borrowed from the aggregate, so it is valid until
    /// `deinit`. The cursor advances past every mark it examines, whether or
    /// not it yields one.
    pub fn next(self: *MarkIter) ?OpId {
        while (self.index < self.acc.opens.items.len) {
            const begin = self.acc.opens.items[self.index];
            self.index += 1;
            // `clock.covers(&begin)` upstream (`types.rs:134-136`), which is
            // `Clock.contains` here (`clock.zig:107-109`).
            if (self.clock) |c| if (!c.contains(begin)) continue;
            return begin;
        }
        return null;
    }
};

// ── MarkIndexColumn ───────────────────────────────────────────────────────

/// The mark index: the column of rows, and the cache of what each mark's begin
/// put on its span (`mark_index.rs:213-217`).
///
/// # Two allocator obligations, kept apart
///
/// `gpa` is the allocator the column and the cache were **built** with, and
/// [`MarkIndexColumn.deinit`] frees both with it: the column's own slabs
/// (`hexane/column.zig:1671-1674`) and the cache's map. Every method that
/// writes into this object uses that allocator and takes no parameter for it —
/// [`stage`], [`stageExtend`], [`stageUndo`], [`extend`], [`undo`],
/// [`stageRemap`], [`remapValues`] and [`rewriteWithNewActor`] — so a caller
/// cannot hand the column memory that `deinit` will not free.
///
/// The four readers that return an owned value — [`total`], [`marksAt`] and
/// [`richTextAt`] — take a `gpa` for a *different* thing: it is the allocator
/// the **returned** `MarkAcc`, `MarkIter` or `OpenMarks` must be freed with,
/// and it has no bearing on this column's storage. It is a parameter rather
/// than a field because the result is a separate value the caller owns and
/// can free with an allocator of its own choosing.
///
/// # Writes are staged, not applied in place
///
/// This type holds two stores that must agree: the rows, and the `MarkData`
/// of every begin. Every write goes through [`stage`](MarkIndexColumn.stage)
/// — [`stageExtend`] for a write, [`stageUndo`] for a removal — which builds
/// both halves beside the index and returns a [`StagedMarkIndex`]. Nothing on
/// the index is touched until [`StagedMarkIndex.publish`], and that publish
/// cannot fail. [`extend`] and [`undo`] are the stage plus the publish, which
/// is the right shape for the one caller that has nothing else to keep whole;
/// a caller writing a whole set of columns wants the stage itself.
///
/// # A third store, and it is derived
///
/// The two above are the only stores that have to be kept whole together. The
/// third — the per-slab prefix array [`AggPrefix`] that [`total`] reads — is
/// derived state in the sense the whole mark index already is: every entry is
/// a function of the rows, so a publish has only to record which of them
/// stopped being true and the next reader rebuilds the rest. That is why it is
/// not part of the all-or-nothing bargain, and why no write in this file can
/// fail over it.
///
/// [`stageRemap`](MarkIndexColumn.stageRemap) is the same bargain on the other
/// write path — an actor renumbering, which moves the rows and the cache
/// together and must be all-or-nothing **across an op set**, not merely within
/// one column — so it returns a [`StagedRemap`] and takes its publish the same
/// way.
///
/// The per-slab prefix aggregates [`MarkIndexColumn`] keeps beside its rows,
/// and how far into them is known to be current.
///
/// This is upstream's aggregate with the tree taken off it. Upstream's
/// `MarkIdx` carries a `MarkAcc` as the b-tree's own weight
/// (`mark_index.rs:193-194`, `:213-217`); here the column holds the aggregate
/// standing before each slab in a flat array it owns, which is the same value
/// the weight holds and the same one a descent reads
/// (`hexane/src/prefix.rs:825`).
///
/// **`valid` is the whole of the maintenance argument, and it is a frontier,
/// not a flag.** `entries[0..valid]` still line up with the column's slabs,
/// and every entry at or past it either names a slab the column no longer
/// cuts there or covers rows a write has moved, and is rebuilt before it is
/// read again. An entry survives a write exactly when the row its
/// `start_row` names is still the row its slab starts at **and** that row is
/// at or before the write's own row — the first because the entry's
/// aggregate is over the rows before exactly that row, and the second because
/// a splice rewrites the rows from its own row on and nothing before it
/// (`hexane/column.zig:5962-6099`). Both are checked against the published
/// layout by [`StagedMarkIndex.publish`](MarkIndexColumn.StagedMarkIndex.publish),
/// which is why the array cannot be a flag: the column is free to re-cut and
/// coalesce slabs around the cut (`tryMergeRange` merges outwards from it,
/// `hexane/column.zig:6352-6356`), so the frontier is measured rather than
/// assumed.
///
/// A remap renumbers every row, so nothing survives one and the frontier goes
/// to zero (`StagedRemap.publish`). Everything past it is rebuilt by the next
/// query that reaches it, which is what stops a write that no query follows
/// from paying for a prefix nobody reads.
const AggPrefix = struct {
    /// The entries, one per slab, in slab order. There is no entry for the
    /// aggregate over the *whole* column: a query never needs one, because a
    /// target past the end lands on the last row and that row's slab has a
    /// base.
    entries: std.ArrayList(AggEntry),
    /// How many leading entries line up with the column as it stands. Never
    /// more than `entries.items.len`, and never more than the slab count.
    valid: usize,
};

/// One slab's base: the aggregate over the rows before it, and the row it
/// starts at.
const AggEntry = struct {
    /// The row this slab's first row is at, as it was when the aggregate
    /// below was folded. This is what a write checks to decide whether the
    /// aggregate still answers for the slab that now sits at this index.
    start_row: usize,
    /// The aggregate over the rows `0..start_row` — upstream's tree weight
    /// for the slab, held here rather than in the tree because the tree
    /// cannot own it (the module comment).
    acc: MarkAcc,
};

pub const MarkIndexColumn = struct {
    /// The allocator `init` was given and `deinit` frees with. It is a field
    /// and not a parameter on the mutators because the column already owns
    /// storage built with it; see the type doc for the two obligations.
    gpa: Allocator,
    /// The rows. Upstream's is a `PrefixColumn<Option<MarkIdx>>`; the module
    /// comment gives why the port's holds the word and folds its own prefix.
    data: DataColumn,
    /// The `MarkData` of every live mark-begin op (`mark_index.rs:216`,
    /// `:277-286`). This is what `hasAnyMarks` and `markData` read
    /// (`:261-269`).
    /// Scalar byte payloads are owned here, independently of producer or value
    /// column storage. Names still borrow the document's interned string table.
    cache: std.AutoHashMapUnmanaged(OpId, MarkData),
    /// The per-slab prefix aggregates [`total`] reads, and the frontier that
    /// says how far into them is current ([`AggPrefix`]).
    ///
    /// **A pointer, and that is load-bearing.** [`total`], [`marksAt`] and
    /// [`richTextAt`] take a `*const MarkIndexColumn` — `OpSet.markSetAt`
    /// (`op_set.zig:4310-4316`) reaches the mark index through a `*const
    /// OpSet` — and the prefix has to be brought up to date by whichever of
    /// them asks first, because the write that invalidated it is a publish,
    /// which cannot fail and so cannot be where an allocating fold is paid
    /// for. A pointer to the state is the only shape a `*const` receiver can
    /// write through. What that buys is stated on [`total`]; what it costs is
    /// that this type is no longer free of a reader mutating it, so two
    /// threads sharing one index would race here.
    agg: *AggPrefix,
    /// Non-null only in an unpublished, address-stable batch view.
    staging: ?*Overlay = null,

    /// Selective row staging and a bounded tail of mark-cache changes.
    /// The source must stay alive and unchanged until publication or disposal.
    /// Initialize in place and keep both this value and its bound view stable.
    /// Provisional mark aggregates must not be queried after the first write.
    pub const Overlay = struct {
        source: *MarkIndexColumn,
        rows: DataColumn.Overlay,
        pending: std.ArrayList(StagedMarkIndex.Pending) = .empty,
        at: usize = std.math.maxInt(usize),
        insert_bound: usize = 0,
        spent: bool = false,

        /// Binds a provisional index. Capture it before disposing the overlay.
        pub fn bind(self: *Overlay, view: *MarkIndexColumn) void {
            std.debug.assert(!self.spent);
            view.* = self.source.*;
            view.staging = self;
            self.rows.bind(&view.data);
        }

        /// Captures the final provisional rows and clears their staging link.
        pub fn capture(self: *Overlay, view: *MarkIndexColumn) void {
            std.debug.assert(view.staging == self);
            self.rows.capture(&view.data);
            view.staging = null;
        }

        /// Publishes rows and pending cache entries without allocating.
        pub fn publish(self: *Overlay, source: *MarkIndexColumn) void {
            std.debug.assert(!self.spent);
            std.debug.assert(source == self.source);
            self.rows.publish(&source.data);
            for (self.pending.items) |record| source.applyPending(record);
            const reached = @min(source.agg.entries.items.len, source.data.slabCount());
            var row: usize = 0;
            var frontier: usize = 0;
            while (frontier < reached and row <= self.at and
                source.agg.entries.items[frontier].start_row == row) : (frontier += 1)
            {
                row += source.data.slabAt(frontier).?.len;
            }
            source.agg.valid = @min(source.agg.valid, frontier);
            self.pending.deinit(source.gpa);
            self.spent = true;
        }

        /// Releases provisional storage; source entries and rows stay intact.
        pub fn deinit(self: *Overlay) void {
            if (self.spent) return;
            self.rows.deinit();
            for (self.pending.items) |*record| record.deinit(self.source.gpa);
            self.pending.deinit(self.source.gpa);
            self.spent = true;
        }
    };

    /// Initializes a selective batch overlay without changing source entries.
    /// Cache capacity may grow, but source rows and cache values do not change.
    pub fn beginOverlay(self: *MarkIndexColumn, out: *Overlay) ParseError!void {
        out.* = .{ .source = self, .rows = undefined };
        try self.data.beginOverlay(&out.rows);
    }

    /// A cursor over the rows, decoded (`mark_index.rs:252-254`, `:256-260`).
    ///
    /// Upstream hands back the column's own iterator; here the column holds the
    /// word and this decodes it, so the adapter forwards the cursor interface
    /// rather than being one. The `shiftable` line is the compile-time proof
    /// that the forwarding is complete (`hexane/column.zig:3827-3863`).
    pub const ValueIter = struct {
        /// The column's own cursor (`hexane/column.zig`). The column holds the
        /// word and this decodes it, so every method is a forward.
        inner: WordIter,

        /// One run of the rows: `count` rows carrying `value`
        /// (`hexane/column.zig:176-184`).
        pub const Run = column.RunOf(?MarkIdx);

        /// The compile-time proof that the forwarding below carries the whole
        /// `Shiftable` kernel (`column.Shiftable`,
        /// `hexane/src/iter/tools.rs:19-74`).
        pub const shiftable = column.Shiftable(ValueIter);

        /// The next row, or null at the end of the window.
        ///
        /// A row that carries no mark and the end of the window are the same
        /// `null`, as they are in the column's own iterator, so a consumer that
        /// walks a stretch of unmarked rows walks runs (`nextRun`), which is
        /// what `calculate_marks_fast` does (`op_set2/op_set.rs:988-995`).
        pub fn next(self: *ValueIter) ParseError!?MarkIdx {
            return decodeMaybe(try self.inner.next());
        }

        /// The next run of equal rows, or null at the end of the window. This is
        /// the cursor `calculate_marks_fast` walks
        /// (`op_set2/op_set.rs:988-995`).
        pub fn nextRun(self: *ValueIter) ParseError!?Run {
            return self.nextRunMax(self.inner.itemsLeft());
        }

        /// The next run of equal rows, at most `max` of them.
        pub fn nextRunMax(self: *ValueIter, max: usize) ParseError!?Run {
            const run = (try self.inner.nextRunMax(max)) orelse return null;
            return .{ .count = run.count, .value = decodeWord(run.value) };
        }

        /// The row the next `next` returns.
        pub fn pos(self: *const ValueIter) usize {
            return self.inner.pos();
        }

        /// One past the last row this cursor can yield.
        pub fn maxPos(self: *const ValueIter) usize {
            return self.inner.maxPos();
        }

        /// How many rows are left in the window.
        pub fn itemsLeft(self: *const ValueIter) usize {
            return self.inner.itemsLeft();
        }

        /// Truncates the window so iteration stops at `at`.
        pub fn setMax(self: *ValueIter, at: usize) void {
            self.inner.setMax(at);
        }

        /// Consumes through row `target`.
        pub fn advanceTo(self: *ValueIter, target: usize) ParseError!void {
            return self.inner.advanceTo(target);
        }

        /// Consumes `amount` rows.
        pub fn advanceBy(self: *ValueIter, amount: usize) ParseError!void {
            return self.inner.advanceBy(amount);
        }

        /// Cuts the window to `range.end`.
        pub fn shift(self: *ValueIter, range: column.RowRange) void {
            self.inner.shift(range);
        }

        /// Repositions the window to `range` and returns the row landed on.
        pub fn shiftNext(self: *ValueIter, range: column.RowRange) ParseError!?MarkIdx {
            return decodeMaybe(try self.inner.shiftNext(range));
        }

        /// Consumes through row `at` and returns that row, or null when `at` is
        /// behind the cursor.
        pub fn seekTo(self: *ValueIter, at: usize) ParseError!?MarkIdx {
            return decodeMaybe(try self.inner.seekTo(at));
        }

        /// The row `n` rows ahead, consuming what it passes.
        pub fn nth(self: *ValueIter, n: usize) ParseError!?MarkIdx {
            return decodeMaybe(try self.inner.nth(n));
        }
    };

    /// An empty mark index (`mark_index.rs:242-246`, reached from
    /// `Indexes::default` at `op_set2/columns.rs:53` and from
    /// `op_set2/op_set/index.rs:224`).
    ///
    /// `gpa` becomes the column's own allocator: it is kept in the `gpa`
    /// field and used by every later write, so it must be the allocator
    /// [`deinit`] frees with — which it is, because `deinit` reads the field
    /// rather than taking one. Nothing else in the type takes an allocator
    /// for the column's own storage.
    ///
    /// **The prefix state is allocated here, so it is the third thing
    /// [`deinit`] gives back** (see `agg`). A refusal from
    /// `DataColumn.init` takes it with it, so `init` cannot leave a cell
    /// behind on an index it never returned.
    pub fn init(gpa: Allocator) ParseError!MarkIndexColumn {
        // The prefix state is a heap cell so the readers can refresh it
        // through a `*const` index (see `agg`): one allocation, for an index
        // that may never be asked a question.
        const agg = try gpa.create(AggPrefix);
        errdefer gpa.destroy(agg);
        agg.* = .{ .entries = .empty, .valid = 0 };
        return .{
            .gpa = gpa,
            .data = try DataColumn.init(gpa),
            .cache = .empty,
            .agg = agg,
        };
    }

    /// Frees the column's slabs, the cache's map and the prefix array, all
    /// with `self.gpa`. Upstream frees its two by dropping them
    /// (`:213-217`); the port keeps the allocator in a field rather than
    /// taking one, so a caller cannot free with an allocator other than the
    /// one it built with, and the prefix cell goes with them. Each entry in
    /// the array is an owned aggregate and is given back through its own
    /// `deinit` before the array naming them does.
    ///
    /// Afterwards the value is `undefined`: no method may be called on it, and
    /// a second call frees `undefined`, which no optimize mode diagnoses, so
    /// call it exactly once per index. A copy taken beforehand shares every
    /// allocation and is not a second owner.
    pub fn deinit(self: *MarkIndexColumn) void {
        self.data.deinit();
        var values = self.cache.valueIterator();
        while (values.next()) |data| data.value.deinitOwned(self.gpa);
        self.cache.deinit(self.gpa);
        for (self.agg.entries.items) |*entry| entry.acc.deinit();
        self.agg.entries.deinit(self.gpa);
        self.gpa.destroy(self.agg);
        self.* = undefined;
    }

    /// Moves one staged scalar into the cache, releasing only the replaced or
    /// removed entry's owned payload. Capacity is reserved before publication.
    fn applyPending(self: *MarkIndexColumn, record: StagedMarkIndex.Pending) void {
        if (self.cache.getPtr(record.id)) |old| old.value.deinitOwned(self.gpa);
        if (record.data) |data| {
            self.cache.putAssumeCapacity(record.id, data);
        } else {
            _ = self.cache.remove(record.id);
        }
    }

    /// How many rows the index has, which is the op set's row count
    /// (`mark_index.rs:248-250`).
    pub fn len(self: *const MarkIndexColumn) usize {
        return self.data.len();
    }

    /// A cursor over every row, in order (`mark_index.rs:252-254`).
    ///
    /// The cursor borrows the column, so it must not outlive it, and every
    /// `MarkIdx` it hands back is a decoded value that outlives the cursor.
    /// A `null` from its `next` is a row carrying no mark, not the end of the
    /// walk — `ValueIter` says which is which.
    pub fn iter(self: *const MarkIndexColumn) ParseError!ValueIter {
        return .{ .inner = try self.data.iterator() };
    }

    /// The rows of the index in `range`, clamped to the column
    /// (`mark_index.rs:256-260`).
    ///
    /// The same `null` answer as [`iter`]: a row with no mark and the end of
    /// the window are one `null`, which is why every reader of this column
    /// walks runs rather than rows (`hexane/column.zig:503-511`).
    pub fn iterRange(self: *const MarkIndexColumn, range: column.RowRange) ParseError!ValueIter {
        return .{ .inner = try self.data.iterRange(range) };
    }

    /// Whether any mark exists anywhere in the document: the cache holds the
    /// `MarkData` of every live mark-begin op (`mark_index.rs:261-265`).
    ///
    /// This is the one reader that does **not** go through the rows, so it is
    /// the one the cache has to be consistent with on its own: an entry here
    /// with no row behind it makes this answer "yes" for an index whose rows
    /// hold no marks. [`stage`](MarkIndexColumn.stage) is written so that
    /// state cannot arise — a mark and its row are built together and land
    /// together, so between the two the cache still describes the rows that
    /// are there.
    pub fn hasAnyMarks(self: *const MarkIndexColumn) bool {
        return self.cache.count() != 0;
    }

    /// What the mark beginning at `begin` puts on its span, or null
    /// (`mark_index.rs:267-269`). Upstream hands back a reference; the port's
    /// `MarkData` is a borrowed slice and a value, so it comes back by value
    /// (`op_set2/types.rs:56-60`).
    pub fn markData(self: *const MarkIndexColumn, begin: OpId) ?MarkData {
        return self.cache.get(begin);
    }

    /// The word the row at `pos` stores, or null for a row past the end and for
    /// a row that carries no mark — the same two answers the column's own `get`
    /// gives (`hexane/column.zig:1706-1724`).
    ///
    /// Upstream has no such method: the op set walks the column instead
    /// (`mark_index.rs:252-260`). The port's column layer has one, and a caller
    /// that wants a single row's word — a test, or a diagnostic dump — should
    /// not have to decode it out of `data` by hand.
    pub fn get(self: *const MarkIndexColumn, pos: usize) ParseError!Word {
        const word: Word = (try self.data.get(pos)) orelse return null;
        return word;
    }

    /// Rewrites the index for an actor inserted at `idx` (`mark_index.rs:271-278`,
    /// called from `op_set2/op_set.rs:1407-1409`).
    ///
    /// The upstream name, kept as an alias: it does the same work as
    /// [`remapValues`] and exists so a caller reading `mark_index.rs:271-278`
    /// finds the entry point it is looking for. It allocates nothing of its
    /// own, so it takes no allocator: the index is rewritten with the one it
    /// was built with.
    ///
    /// **This is the single-column form, and it is the wrong one for the op
    /// set.** `OpSet.rewriteWithNewActor` also renumbers four data columns and
    /// the object table, and the three together are what has to be
    /// all-or-nothing; a mark index that published itself the moment it was
    /// built would leave rows renumbered against columns that are not, which is
    /// a state no reader here survives. So this is [`remapValues`], which is
    /// [`stageRemap`] and the publish — and the op set calls the stage itself
    /// and publishes last.
    pub fn rewriteWithNewActor(self: *MarkIndexColumn, idx: ActorIdx) ParseError!void {
        return self.remapValues(idx);
    }

    /// [`stageRemap`] with [`Shift.up`] and
    /// [`StagedRemap.publish`](StagedRemap.publish), as one write.
    ///
    /// Both halves move together or not at all: the new rows and the new cache
    /// are built from the index as it stands and swapped in together, so a
    /// refusal anywhere leaves the rows and the cache describing the same actor
    /// table. [`stageRemap`] says what the two halves are and why they have to
    /// move together; this is the form a caller with nothing else to keep whole
    /// wants, and it allocates with `self.gpa` — the allocator the index was
    /// built with — because a remap run with any other allocator would leave
    /// the new slabs owned by somebody [`deinit`] does not free.
    pub fn remapValues(self: *MarkIndexColumn, idx: ActorIdx) ParseError!void {
        var staged = try self.stageRemap(idx, .up);
        defer staged.deinit();
        staged.publish(self);
    }

    /// The two halves of an actor renumbering, built beside this index and
    /// published into it in one step ([`StagedRemap`]).
    ///
    /// # Why it exists
    ///
    /// A remap is a write to **two** stores — the rows in `data` and the
    /// `MarkData` of every begin in `cache` — and both have to move. A remap
    /// that moved only the rows would leave the cache keyed by the old actor
    /// table, and [`markData`] would answer null for every mark in the
    /// document.
    ///
    /// [`remapValues`] already made the pair all-or-nothing *within this
    /// index*, by ordering. That was not enough: the op set's
    /// `rewriteWithNewActor` renumbers this index and four data columns, and an
    /// `error.OutOfMemory` from anywhere in that sequence left the mark index
    /// published against columns that were not — the whole reason
    /// `Columns.remapActors` stages its four columns and publishes them
    /// together. This is the same seam one layer down: a caller with a whole op
    /// set to keep whole stages this, stages everything else, and publishes
    /// each only once nothing further can fail.
    ///
    /// # What it owns
    ///
    /// * **The rows are the stage's**, from
    ///   [`Column.remapped`](../../src/hexane/column.zig): a whole provisional
    ///   column that borrows nothing from the index's own storage, because the
    ///   index still names that storage until the publish. An abort frees only
    ///   what the build allocated.
    /// * **The cache is the stage's**: a whole new map built from the index's
    ///   own entries. An abort frees it, and the index's own map is untouched.
    /// * **Nothing on the index is written before the publish**, and nothing
    ///   this returns reads the index again, so the two halves cannot disagree
    ///   about what they were built from.
    ///
    /// Upstream keeps the two halves in two functions because its worker is a
    /// closure over `MarkIdx` — `remap_values(f: impl Fn(MarkIdx) -> MarkIdx)`
    /// — and a closure over a row cannot be applied to the cache's `OpId` keys
    /// (`mark_index.rs:251-266`). The port's worker is a comptime function over
    /// `ActorIdx` and `MarkIdx` (`hexane/column.zig:3591-3623`) for the same
    /// reason a closure is not available, so the split buys nothing here and
    /// the halves travel together: a caller cannot get one without the other.
    ///
    /// **What it costs.** One pass over every row, plus the new column's own
    /// storage — which is what [`remapValues`] costs too, because that result
    /// is the column that gets installed. The run-at-a-time walk means the
    /// shift is applied once per *run* rather than once per row
    /// (`hexane/column.zig:3591-3623`); it does **not** mean the rows are
    /// written a run at a time, because the build lays the shifted values down
    /// a row at a time into a fixed stack buffer and extends from that. An
    /// index over a document with no marks therefore costs the same as any
    /// other column of its length, not a handful of run headers.
    pub fn stageRemap(
        self: *MarkIndexColumn,
        idx: ActorIdx,
        comptime way: Shift,
    ) ParseError!StagedRemap {
        // The removal path refuses first. `Shift.down` asks
        // [`MarkIdx.withoutActor`] for every row and every cache key, and it
        // answers null for one that names `idx` — an actor that is going away
        // and cannot be represented by a row, because this column is aligned
        // with the op set and has nothing to drop. **Without this the shift
        // below would have an unreachable arm**, so it is a precondition of the
        // seam rather than an extra check bolted onto it.
        //
        // In an op set the refusal is one the four data columns would have made
        // anyway — a mark's begin is a row, and a row names its actor — so this
        // runs first only because it is cheaper to ask here than to discover
        // the fact afterwards.
        if (way == .down and try self.referencesActor(idx)) return error.InvalidValue;

        // The rows. `remapped` reads this index's rows and writes a new column,
        // so a refusal here leaves both halves exactly as they were.
        var rows = try self.data.remapped(self.gpa, idx, shiftWord(way));
        errdefer rows.deinit();

        // The cache, from the index's own, which has not moved.
        //
        // `OpId::with_new_actor` is a shift, not a fold, so two keys never land
        // on one (`types.rs:447-453`) and the fresh map cannot lose an entry to
        // a collision; `without_actor` shifts everything above the removed slot
        // the same way (`types.rs:455-461`), and the entry naming `idx` was
        // refused above. `errdefer` gives the half-built map back on every path.
        var cache: std.AutoHashMapUnmanaged(OpId, MarkData) = .empty;
        errdefer cache.deinit(self.gpa);
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            try cache.put(self.gpa, shiftCacheKey(way, kv.key_ptr.*, idx), kv.value_ptr.*);
        }
        return .{ .rows = rows, .cache = cache, .gpa = self.gpa, .spent = false };
    }

    /// Whether this index still names the actor at `idx`, in a row or in the
    /// cache (`OpId::actor`, and `mark_index.rs:25-34` for the row's word).
    ///
    /// **This is the mark index's half of the reference check an actor removal
    /// needs**, asked of both stores because a begin's id lives in the cache
    /// and its row's word in `data`: an index whose two halves disagree is the
    /// state [`stageRemap`] refuses to produce. Upstream has no counterpart,
    /// because upstream's `OpSet::remove_actor`
    /// (`op_set2/op_set.rs:1419-1429`) never renumbers the mark index at all.
    ///
    /// It is a read, so answering `true` costs the caller nothing but a
    /// refusal that left the index exactly as it was — which is the bargain
    /// [`Columns.rewriteWithoutActor`](columns.zig) makes over the four data
    /// columns beside it. In a well-formed op set this is subsumed by that
    /// check, since a mark's begin is a row and a row names its actor; it is
    /// here so that a `MarkIndexColumn` on its own is total, which is what
    /// makes [`stageRemap`] total.
    pub fn referencesActor(self: *const MarkIndexColumn, idx: ActorIdx) ParseError!bool {
        // nextRun separates exhaustion from an unmarked row. ValueIter.next
        // flattens both to null and would stop at the first unmarked row.
        var rows = try self.iter();
        while (try rows.nextRun()) |run| {
            const m = run.value orelse continue;
            if (m.actorIndex() == idx) return true;
        }
        var cached = self.cache.iterator();
        while (cached.next()) |kv| {
            if (kv.key_ptr.*.actor == idx) return true;
        }
        return false;
    }

    /// A splice into the mark index, built beside the index instead of inside
    /// it (`Columns.splice`, `Columns.removeOps`).
    ///
    /// # Why this exists
    ///
    /// The mark index is **two** stores — the rows in `data`, and the
    /// `MarkData` of every begin in `cache` — and a write refused between
    /// them leaves an index that describes a document nobody has. The bad
    /// state is not visible to every reader, which is what makes it worth
    /// engineering out: [`hasAnyMarks`] reads the cache directly, so an
    /// entry with no row behind it answers "this document has a mark" for an
    /// index whose rows hold none, and a row with no entry makes
    /// [`richTextAt`] yield nothing for a mark the op set does contain.
    ///
    /// So the whole of it is prepared **ahead of the write** and published in
    /// one step. Between [`stage`](MarkIndexColumn.stage) and
    /// [`publish`](StagedMarkIndex.publish) no entry, name or row has
    /// changed; after the publish everything has. There is no third state,
    /// and no path that has to document what a half-applied splice degrades
    /// to.
    ///
    /// # What it owns
    ///
    /// * **The staged rows are the stage's**, from `DataColumn.stageSplice`
    ///   ([`column.zig:3616-3641`](../../src/hexane/column.zig)): a whole
    ///   provisional column whose untouched slabs *borrow* the original's
    ///   buffers. An abort must not free those — the index still names them.
    /// * **The pending records are the stage's**: one small owned record per
    ///   mark begin this splice adds or forgets, and nothing else. The cache
    ///   itself is **not** copied — it stays the index's own map, and the
    ///   publish puts these records into it.
    /// * **Nothing else.** `publish` needs no allocation, so it cannot fail.
    ///
    /// That is what makes the cost proportional to what changed rather than
    /// to what exists: a splice that touches no mark begins stages no records
    /// and allocates nothing for the cache at all, which is the case
    /// `OpSet.sizeIndexForWalk`'s all-null padding pad is
    /// (`op_set.zig:1836`).
    ///
    /// The allocator is `self.gpa` — the index's own — so every byte the stage
    /// holds comes out of, and goes back into, the one [`deinit`] releases
    /// the index with. There is no allocator parameter on any of this, which
    /// is what makes it impossible to build a stage nobody can free.
    ///
    /// `publish` is bound to the index the stage came from, and there is one
    /// stage per splice point: a caller with many writers stages each against
    /// columns that have not changed since, and only then publishes any of
    /// them. Publishing one twice, or into an index written since, is a
    /// programmer error the publish asserts.
    pub const StagedMarkIndex = struct {
        /// One mark begin this splice adds or forgets, held until the
        /// publish. A record is a value the stage owns, not a borrow of the
        /// caller's builder: `values` is the caller's slice and may be gone
        /// by the time the publish runs, and a record that outlived it would
        /// be a dangling borrow on the path that has no error to catch it.
        ///
        /// The name still borrows the document's string table. An insertion
        /// owns its scalar byte payload until it moves to the cache or overlay;
        /// abort releases it without changing any existing cache entry.
        pub const Pending = struct {
            /// The begin operation's id, which is the cache's key
            /// (`mark_index.rs:216`).
            id: OpId,
            /// The `MarkData` to put, or null for a record that takes the
            /// entry out. A removal needs only the id, which is why one
            /// shape covers both directions.
            data: ?MarkData,

            fn deinit(self: *Pending, gpa: Allocator) void {
                if (self.data) |*data| data.value.deinitOwned(gpa);
                self.data = null;
            }
        };

        /// The rows, staged against this index's own `data` column, which
        /// `publish` checks. `del` and the inserted `values` are the ones
        /// [`stage`](MarkIndexColumn.stage) was given.
        rows: DataColumn.StagedSplice,
        /// The row this splice was staged at. `publish` uses it to say which
        /// of the index's prefix entries a reader can still trust: the rows
        /// before this one are the rows the splice did not move.
        at: usize,
        /// What the publish has to do to the cache, in order. Empty — and
        /// then not one allocation — for a splice that changes no mark.
        pending: []Pending,
        /// The index's own allocator, which both halves above were built with
        /// and are handed back to it through.
        gpa: Allocator,
        /// Whether `publish` or [`deinit`](StagedMarkIndex.deinit) has run.
        /// A `deinit` after a `publish` is a no-op, so `defer stage.deinit()`
        /// beside `col.publish(stage)` is the right shape rather than a
        /// double free.
        spent: bool,

        /// **The abort.** Frees the staged rows and the pending records, and
        /// leaves the index exactly as it was: no entry, no mark name and no
        /// row moved. Infallible, and after it `publish` is no longer valid.
        pub fn deinit(self: *StagedMarkIndex) void {
            if (self.spent) return;
            self.rows.deinit();
            for (self.pending) |*record| record.deinit(self.gpa);
            if (self.pending.len != 0) self.gpa.free(self.pending);
            self.spent = true;
        }

        /// **The write.** Hands `col` the staged rows and applies the pending
        /// records to `col`'s own cache, in one step. Infallible: the room for
        /// the insertions was reserved by
        /// [`stageExtend`](MarkIndexColumn.stageExtend) and a removal only
        /// shrinks the map, so no step here can allocate or fail.
        ///
        /// `col` must be the index this stage was built from, and it must not
        /// have been written since — the staged rows describe a layout that no
        /// longer exists otherwise. Both are asserted rather than checked,
        /// which is why there is no recoverable case here.
        ///
        /// **The allocator check is on the vtable alone.** `Allocator` is a
        /// `{ ptr, vtable }` pair, and a stateless provider — `c_allocator`,
        /// and every provider that answers from a fixed table rather than from
        /// its own state — leaves `ptr` undefined
        /// (`std/heap.zig:139`), so reading it to compare two allocators is a
        /// read of undefined memory rather than a check. The vtable pointer is
        /// always defined and names the provider's *type*, so asserting on it
        /// catches the case worth catching here — a stage whose memory a
        /// different kind of allocator would free — and says nothing about the
        /// instance, which stays a caller precondition stated below.
        ///
        /// **Same allocator instance is a precondition, not a fact this
        /// proves.** Two allocators of the same type share a vtable and need
        /// not share storage; this publishes a stage built in one into an
        /// index owned by another, and `col.deinit` would then free the rows
        /// with the wrong allocator. The stage and the index it was built from
        /// are both owned by the same [`MarkIndexColumn`] here, so it holds by
        /// construction, and a caller that mixes two of them has a bug this
        /// cannot diagnose.
        pub fn publish(self: *StagedMarkIndex, col: *MarkIndexColumn) void {
            std.debug.assert(!self.spent);
            std.debug.assert(self.gpa.vtable == col.gpa.vtable);
            if (self.rows.noop and !self.rows.provisional) {
                std.debug.assert(self.pending.len == 0);
                self.rows.publish(&col.data);
                self.spent = true;
                return;
            }
            if (col.staging) |overlay| {
                overlay.pending.appendSliceAssumeCapacity(self.pending);
                overlay.at = @min(overlay.at, self.at);
                self.rows.publish(&col.data);
                if (self.pending.len != 0) self.gpa.free(self.pending);
                self.spent = true;
                return;
            } else {
                for (self.pending) |record| col.applyPending(record);
            }
            self.rows.publish(&col.data);
            // The prefix frontier, and the whole of what a publish owes the
            // prefix array. An entry survives exactly when the slab at its
            // index still starts at the row the entry folded over, and that
            // row is at or before this splice's own row — so the walk below
            // measures both and stops at the first entry that fails either.
            // Nothing here allocates, which is what keeps the publish
            // infallible; everything at or past the frontier is the next
            // reader's to rebuild.
            const reached = @min(col.agg.entries.items.len, col.data.slabCount());
            var row: usize = 0;
            var f: usize = 0;
            while (f < reached and row <= self.at and
                col.agg.entries.items[f].start_row == row) : (f += 1)
            {
                row += col.data.slabAt(f).?.len;
            }
            col.agg.valid = f;
            if (self.pending.len != 0) self.gpa.free(self.pending);
            self.spent = true;
        }

        /// How many rows the index holds once this is published, for a caller
        /// that has to size a companion buffer from it — a successor buffer, a
        /// prefix column — rather than adding the counts up itself.
        pub fn newLen(self: *const StagedMarkIndex) usize {
            return self.rows.newLen();
        }
    };

    /// A renumbered index, built beside the one it replaces and handed over in
    /// one step ([`stageRemap`](MarkIndexColumn.stageRemap)).
    ///
    /// It is the same shape of bargain as [`StagedMarkIndex`], and the reason
    /// is the same: the rows and the cache are two stores that must agree, and
    /// a caller that renumbers an actor is renumbering four data columns and
    /// an object table beside them — so "all-or-nothing" has to mean the whole
    /// op set, not one column. `StagedMarkIndex` publishes a splice; this
    /// publishes a renumbering, and the caller that has more to write stages
    /// every half before it publishes any.
    ///
    /// The rows and map shell are owned here. Scalar byte payloads borrow the
    /// source cache until publication transfers its ownership to the new map.
    /// Aborting this stage therefore releases no scalar payloads.
    pub const StagedRemap = struct {
        /// The renumbered rows, built with
        /// [`Column.remapped`](../../src/hexane/column.zig) and holding none of
        /// the original's storage.
        rows: DataColumn,
        /// The re-keyed cache: a whole map, so a refusal here frees it and
        /// leaves the index's own map alone.
        cache: std.AutoHashMapUnmanaged(OpId, MarkData),
        /// The index's own allocator, which both halves above were built with
        /// and are handed back through.
        gpa: Allocator,
        /// Whether `publish` or [`deinit`](StagedRemap.deinit) has run. A
        /// `deinit` after a `publish` is a no-op, so
        /// `defer staged.deinit()` beside `col.publish(staged)` is the right
        /// shape rather than a double free.
        spent: bool,

        /// **The abort.** Frees the staged rows and the staged cache and leaves
        /// the index exactly as it was: no row, no entry and no mark name
        /// moved. Infallible, and after it `publish` is no longer valid.
        pub fn deinit(self: *StagedRemap) void {
            if (self.spent) return;
            self.rows.deinit();
            self.cache.deinit(self.gpa);
            self.spent = true;
        }

        /// **The write.** Trades the index's rows for the staged ones and the
        /// index's cache for the staged one, together. Infallible: the rows
        /// were already built and the map already holds its entries, so all
        /// that is left is a swap and a pointer store.
        ///
        /// The rows move through [`Column.swapContents`](../../src/hexane/column.zig)
        /// rather than a bare assignment, which is what invalidates a cursor
        /// suspended over the rows this replaces — the swap moves the counter
        /// past either column's, so a resumed iterator cannot walk the
        /// pre-remap rows against the post-remap column. The local is then the
        /// retired half and releases the index's old bytes, in the allocator
        /// those bytes came from, which is why the swap and not an assignment:
        /// the contents carry their allocator with them. **A value of
        /// [`Column.allocator`](../../src/hexane/column.zig) taken from
        /// `col.data` before this call names a different allocator after it.**
        ///
        /// `col` must be the index this stage was built from, and it must not
        /// have been written since. **Same allocator instance is a caller
        /// precondition** — the vtable check below names the provider's type,
        /// not its instance, because a stateless provider
        /// (`std/heap.zig:139`) leaves `Allocator.ptr` undefined and reading it
        /// to compare is a read of undefined memory. The stage and the index
        /// come from the same [`MarkIndexColumn`] in every call in this crate,
        /// so it holds by construction.
        pub fn publish(self: *StagedRemap, col: *MarkIndexColumn) void {
            std.debug.assert(!self.spent);
            std.debug.assert(self.gpa.vtable == col.gpa.vtable);
            col.data.swapContents(&self.rows);
            self.rows.deinit();
            col.cache.deinit(col.gpa);
            col.cache = self.cache;
            // Every row moved onto a new actor table, so no prefix entry
            // describes these rows any more: the whole frontier goes, and the
            // next reader rebuilds all of it.
            col.agg.valid = 0;
            self.spent = true;
        }
    };

    /// Builds the splice that replaces `[index, index + del)` with `values`
    /// beside the index and returns it staged
    /// ([`StagedMarkIndex`](MarkIndexColumn.StagedMarkIndex)).
    ///
    /// **No entry, name or row changes on any path**, including every error
    /// path. The rows are staged in a provisional column and the cache work
    /// is reduced to one small record per mark begin this splice adds or
    /// forgets, which the publish replays.
    ///
    /// **The one exception, and it is deliberate: `stageExtend` reserves room
    /// in `cache`.** Growing a hash map's capacity can rehash it and move its
    /// backing storage, and that happens *before* the publish — the same
    /// bargain `RawColumn.stageSplice` makes when it reserves the original
    /// arena's list and the Fenwick's (`column.zig:3600-3603`). What it does
    /// not do is change an entry: the set of ids, their `MarkData`, and the
    /// mark names those borrow are all exactly as they were, and the names
    /// live in the document's string table rather than in map slots, so they
    /// are unaffected by the storage moving. What a caller must not do is
    /// hold an iterator or a pointer *into the map* across a stage; nothing
    /// in this crate does, and every reader here is a point lookup
    /// (`markData`, `hasAnyMarks`) or a fold into a value of its own.
    /// [`stageUndo`] reserves nothing, because a removal only shrinks the map.
    ///
    /// Every allocation the eventual publish needs is taken here, which is
    /// what makes the publish infallible — so a caller with many columns to
    /// write can stage all of them and only then publish, and a refusal
    /// anywhere leaves the set whole.
    ///
    /// One splice point is either a write or a removal, never both, and
    /// **`values` means different things on each**:
    ///
    /// * `del == 0` — `Columns.splice`. `values` describes the rows being
    ///   **written**: one builder per row written, and every `Start` among
    ///   them becomes a pending insertion carrying its `MarkData`. Those same
    ///   builders supply the words the staged column is spliced in from.
    /// * `del > 0` — `Columns.removeOps`. `values` describes the rows being
    ///   **removed**, and `values.len` must equal `del`: one builder per row
    ///   taken out. Every `Start` among them becomes a pending *removal* — the
    ///   begin is forgotten — and `starts` is still counted over the builders
    ///   for exactly that purpose. The removed rows are **not** written back:
    ///   the staged splice replaces `[index, index + del)` with nothing, so
    ///   the index shrinks by `del` and the builders are used for their ids
    ///   alone. A `delete` action is not a row, so it is in neither list and
    ///   not in `del` (`columns.rs:423` for the write, `:365` for the
    ///   removal).
    ///
    /// The mark-index words come from the builders exactly as they always
    /// did — the same `MarkIndexBuilder.word`, the same `id.prev()`
    /// saturation on the end arm — and on the removal path they are not built
    /// at all, because there is nothing to splice in. The bounds and value
    /// checks are the column's own, so the same `error.InvalidValue` for an
    /// out-of-range range (`column.zig:3783`).
    ///
    /// The stage is the caller's to release — `defer stage.deinit()` — or to
    /// publish, which consumes it.
    pub fn stage(
        self: *MarkIndexColumn,
        index: usize,
        del: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!StagedMarkIndex {
        // Counted on both paths, and for the same reason on each: these are
        // the mark begins the cache **gains** on a write and **forgets** on a
        // removal. On the removal path that is the *only* thing `values` is
        // used for — the rows it names go out, they do not come back in.
        var starts: usize = 0;
        for (values) |maybe| {
            if (maybe) |v| switch (v) {
                .start => starts += 1,
                .end => {},
            };
        }

        // Room for the insertions, before a single record is made. This is
        // the reservation the doc above describes: it can move the map's
        // storage, and it cannot change an entry.
        if (self.staging) |overlay| {
            try overlay.pending.ensureUnusedCapacity(self.gpa, starts);
            if (del == 0 and starts != 0) {
                overlay.insert_bound = std.math.add(usize, overlay.insert_bound, starts) catch
                    return error.Overflow;
                const room = std.math.add(usize, overlay.source.cache.count(), overlay.insert_bound) catch
                    return error.Overflow;
                const capacity = std.math.cast(u32, room) orelse return error.Overflow;
                try overlay.source.cache.ensureTotalCapacity(self.gpa, capacity);
            }
            self.cache = overlay.source.cache;
        } else if (del == 0 and starts != 0) {
            const room = std.math.add(usize, self.cache.count(), starts) catch
                return error.Overflow;
            const capacity = std.math.cast(u32, room) orelse return error.Overflow;
            try self.cache.ensureTotalCapacity(self.gpa, capacity);
        }

        // The records themselves: one per mark begin, and **none** for a
        // splice that touches no mark — the all-null padding pad, and any row
        // that is only an `End`. That is the whole cost of the cache half.
        // `@constCast` because the field is a mutable slice the publish frees
        // when it is non-empty, and a zero-length slice is never written to.
        const no_pending = [_]StagedMarkIndex.Pending{};
        const pending: []StagedMarkIndex.Pending = if (starts == 0) @constCast(no_pending[0..]) else records_blk: {
            const out = try self.gpa.alloc(StagedMarkIndex.Pending, starts);
            var at: usize = 0;
            errdefer {
                for (out[0..at]) |*record| record.deinit(self.gpa);
                self.gpa.free(out);
            }
            for (values) |maybe| {
                if (maybe) |v| switch (v) {
                    .start => |s| {
                        out[at] = .{
                            .id = s.id,
                            .data = if (del == 0) MarkData.init(
                                s.data.name,
                                try s.data.value.dup(self.gpa),
                            ) else null,
                        };
                        at += 1;
                    },
                    .end => {},
                };
            }
            std.debug.assert(at == starts);
            break :records_blk out;
        };
        errdefer {
            for (pending) |*record| record.deinit(self.gpa);
            if (pending.len != 0) self.gpa.free(pending);
        }

        // The rows. **A removal splices nothing in** — `values` names the rows
        // going out, not rows going in — so the staged splice replaces
        // `[index, index + del)` with an empty list and the index shrinks by
        // exactly `del`. That path allocates no word buffer at all.
        const rows = if (del == 0) words_blk: {
            const words = try self.gpa.alloc(Word, values.len);
            defer self.gpa.free(words);
            for (values, 0..) |maybe, i| {
                words[i] = if (maybe) |v| v.word() else null;
            }
            break :words_blk try self.data.stageSplice(index, 0, words);
        } else try self.data.stageSplice(index, del, &.{});
        return .{
            .rows = rows,
            .at = index,
            .pending = pending,
            .gpa = self.gpa,
            .spent = false,
        };
    }

    /// [`stage`] for the write path: inserts `values` before row `index`
    /// (`mark_index.rs:277-289`).
    ///
    /// A `Start` becomes a pending insertion carrying its `MarkData`
    /// (`mark_index.rs:280-284`), and the reservation that makes the publish
    /// infallible is taken here rather than at the publish.
    ///
    /// The name borrows the document's interned string table and must outlive
    /// this index. Scalar byte payloads are copied during staging and owned by
    /// the cache after publication, matching upstream's owned mark value
    /// (`op_set2/op.rs:943-950`, `op_set2/types.rs:296-309`). They never borrow
    /// transaction buffers or value-column resident slabs across mutations.
    ///
    /// Upstream's parameter is a `Vec` it consumes; a slice is the port's
    /// spelling.
    pub fn stageExtend(
        self: *MarkIndexColumn,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!StagedMarkIndex {
        return self.stage(index, 0, values);
    }

    /// [`stage`] for the removal path: takes the `values.len` rows `index`
    /// names out of the index and forgets the marks that began there
    /// (`mark_index.rs:291-300`).
    ///
    /// **`values` describes the rows being removed**, one builder per row
    /// taken out, so `del == values.len` and the index shrinks by exactly
    /// that many rows. The builders are used for their begin ids and for
    /// nothing else: the removed rows are not written back, and no mark-index
    /// words are built for them because there is nothing to splice in.
    ///
    /// `values` must name the rows exactly as [`stageExtend`] was given them,
    /// since the begin ids are what the cache is pruned by. Upstream prunes
    /// the cache and then splices (`:292-299`); here the removals are records
    /// and the rows are staged, and the publish does both — so there is no
    /// order for a refusal to land between. Nothing is reserved here: a
    /// removal only shrinks the map, and no word buffer is allocated either.
    pub fn stageUndo(
        self: *MarkIndexColumn,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!StagedMarkIndex {
        return self.stage(index, values.len, values);
    }

    /// [`stageExtend`] and the publish, as one write
    /// (`mark_index.rs:277-289`).
    ///
    /// The seam a caller with many columns to write wants is
    /// [`stageExtend`] plus [`StagedMarkIndex.publish`] on each; this is the
    /// single-column form of it, and it is what
    /// [`IndexBuilder.finish`](index.zig) — which has twenty-one columns to
    /// write and no set to keep whole — uses.
    ///
    /// Nothing here can fail after the stage is built, so this cannot leave
    /// the rows and the cache disagreeing, and there is no error a caller has
    /// to handle as a *possibly applied* write: an error means nothing was
    /// written.
    pub fn extend(
        self: *MarkIndexColumn,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!void {
        var staged = try self.stageExtend(index, values);
        defer staged.deinit();
        staged.publish(self);
    }

    /// [`stageUndo`] and the publish, as one write (`mark_index.rs:291-300`).
    ///
    /// The seam counterpart to [`extend`], and the same shape: an error means
    /// the rows are still there and their `MarkData` is still in the cache.
    pub fn undo(
        self: *MarkIndexColumn,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!void {
        var staged = try self.stageUndo(index, values);
        defer staged.deinit();
        staged.publish(self);
    }

    /// The prefix aggregate over the rows `0..=target` (`mark_index.rs:315-318`,
    /// upstream's `PrefixColumn::get_total` at `hexane/src/prefix.rs:554-556`).
    ///
    /// **This is upstream's two steps and not a fold from the first row.** The
    /// column descends to the slab holding `target` (`Column.locate`,
    /// `hexane/column.zig:5732-5742`), which is the port's `find_slab_at_item`,
    /// copies that slab's [`AggPrefix`] entry — the aggregate over every row
    /// before it — and folds the runs of the landing slab alone. Upstream
    /// reaches the same entry the same way, out of the tree's own weight
    /// (`hexane/src/prefix.rs:825`), and folds that same slab (`:810-836`).
    ///
    /// `target` at or past the end folds every row, which is what upstream's
    /// `get_prefix` does through `iter_range`'s clamp (`prefix.rs:670-671`).
    /// A run folds as one delta; the module comment says why that is the whole
    /// rule.
    ///
    /// **What it costs, and what it may have to pay first.** A read is
    /// `O(log S)` to descend, one owned copy of the landing slab's entry —
    /// `O(k)` for the `k` marks open behind that row, two allocations and one
    /// linear walk ([`copyAcc`]) — and at most one slab's worth of runs
    /// folded. What it replaces was `O(runs before target)`. The `k` is the
    /// answer's own size, so `O(k)` per query is what any reader of "which
    /// marks are open here" costs whatever this column is made of; nothing
    /// here grows with the length of the column except the `log S` and the
    /// single slab.
    ///
    /// **The fold inside the landing slab is `O(one slab's runs)` set
    /// operations, and each one is `O(k)`** — [`MarkAcc.applyOne`] inserts into
    /// a sorted array, which memmoves. That is the run budget (sixty-four),
    /// not the document, so it is a fixed multiplier on `k` and not a factor
    /// that grows with the row count. It is the one term of the three that is
    /// still quadratic in the number of *marks*, and it is left as it is:
    /// collapsing a slab's worth of deltas into one merge is only worth doing
    /// if a document ever holds marks open across many slabs at once, which is
    /// the deep-nesting case rather than this one.
    ///
    /// A read that reaches past the frontier first rebuilds the entries
    /// between it and the slab it wants, which is `O(rows from the frontier
    /// on)` — and it *writes* to do it ([`repairAggs`], reached through
    /// [`agg`]). The frontier moves when a write invalidates entries and at no
    /// other time, so a run of writes followed by a run of reads pays that
    /// fold once for the second, and a run of reads on its own pays nothing
    /// after its first. The worst case is one write and one read alternating,
    /// which is what this was before, and never worse than it.
    ///
    /// `gpa` allocates **the returned `MarkAcc` only** — its two sets, which
    /// the caller frees with [`MarkAcc.deinit`]. It says nothing about this
    /// column's own storage, which was allocated with `self.gpa` at [`init`],
    /// and nothing about the [`AggPrefix`] this may have had to extend;
    /// passing a different allocator here is correct and is what lets a reader
    /// fold into an arena. The aggregate is fresh either way: nothing is
    /// shared with this index, which is why it is a value and not a view.
    pub fn total(self: *const MarkIndexColumn, gpa: Allocator, target: usize) ParseError!MarkAcc {
        const landing = self.landingOf(target) orelse return MarkAcc.init(gpa);
        const width = self.data.len();
        const end = if (target >= width) width else target + 1;
        var acc = try self.accBefore(landing, gpa);
        errdefer acc.deinit();
        try self.foldRows(&acc, landing.row, end);
        return acc;
    }

    /// Where a positional question about `target` lands: the slab holding it,
    /// and the row that slab starts at.
    ///
    /// `target` at or past the end lands on the last row, because the prefix
    /// is inclusive and every row folded is what the last row's prefix is.
    /// Null for an empty column, which has no row to land on and no slab to
    /// fold.
    const Landing = struct {
        /// The slab holding the row.
        slab: usize,
        /// The row that slab starts at, and so where the fold begins.
        row: usize,
    };

    fn landingOf(self: *const MarkIndexColumn, target: usize) ?Landing {
        const width = self.data.len();
        if (width == 0) return null;
        const row = if (target >= width) width - 1 else target;
        const at = self.data.locate(row);
        return .{ .slab = at.slab, .row = row - at.in_slab };
    }

    /// Folds the rows `[from, to)` in, run at a time. This is the whole of
    /// what a prefix over this column is, once the rows before `from` are
    /// known — and `total` calls it with `from` at a slab's first row, so the
    /// window never crosses one.
    fn foldRows(
        self: *const MarkIndexColumn,
        acc: *MarkAcc,
        from: usize,
        to: usize,
    ) ParseError!void {
        if (from >= to) return;
        var rows = try self.iterRange(.{ .start = from, .end = to });
        while (try rows.nextRun()) |run| {
            if (run.value) |mark| try acc.applyOne(mark);
        }
    }

    /// The aggregate over the rows before `landing`'s slab, brought up to
    /// date first if the frontier says it is not.
    fn accBefore(
        self: *const MarkIndexColumn,
        landing: Landing,
        gpa: Allocator,
    ) ParseError!MarkAcc {
        if (landing.slab >= self.agg.valid) try self.repairAggs(landing.slab);
        return copyAcc(gpa, &self.agg.entries.items[landing.slab].acc);
    }

    /// Rebuilds the entries from the frontier up to and including `upto`, so
    /// that `entries[upto]` is the aggregate over the rows before slab `upto`.
    ///
    /// **It walks the rows from the frontier on, not the whole column.**
    /// `entries[valid - 1]` already holds the aggregate over the rows before
    /// slab `valid - 1`, so entry `valid` is that plus slab `valid - 1`'s own
    /// runs, and so on; the entries below the frontier are never looked at.
    /// That is what makes the cost proportional to how much of the column
    /// moved rather than to how much of it there is.
    ///
    /// **Getting to the frontier is one load.** The running aggregate and the
    /// row it covers both come out of `entries[next - 1]` — the row because
    /// that entry recorded it (`start_row`), which is what an entry below the
    /// frontier is *for*. This walk used to re-add the lengths of every slab
    /// in front of the frontier to recover that row, which made reaching the
    /// frontier `O(frontier)` — and the frontier grows with the column, so a
    /// run of reads at increasing positions paid that walk on every one of
    /// them, `O(S)` for `S` slabs and `O(S^2)` over the sweep. Reaching it is
    /// `O(1)` now, and a repair costs `O(rows from the frontier on)`: the
    /// entries below it are not walked, not summed and not copied.
    ///
    /// **This is a write, on the read path.** `total` takes `*const
    /// MarkIndexColumn` and reaches the state through `agg` ([`agg`]) and gets
    /// here, which allocates with `self.gpa`, appends to `entries` and moves
    /// `valid` forward. It cannot be otherwise: the write that invalidated the
    /// entries is a publish, which cannot fail and so cannot be where an
    /// allocating fold is paid for ([`agg`] says the same). The read that pays
    /// it is the first one past the frontier, and every read after it pays
    /// nothing — so the cost is amortised over the reads a write costs, not
    /// per query.
    ///
    /// **A refusal leaves the frontier where it was.** The running aggregate
    /// is given back by the `errdefer`, the entry a failed copy would have
    /// written is left as the empty aggregate the loop appended it as, and
    /// nothing below the frontier is touched — so the next call starts from
    /// the same place and does the same work, and a refusal is never a
    /// half-built prefix.
    ///
    /// **`upto` is the landing slab, so one repair reaches every entry a
    /// single query needs** and the loop below runs its share of them once.
    fn repairAggs(self: *const MarkIndexColumn, upto: usize) ParseError!void {
        const state = self.agg;
        // Everything at or past the frontier describes rows, or a slab layout,
        // that this column no longer has. It is given back here rather than at
        // the write that invalidated it, because a publish cannot fail and
        // this can; and it is given back rather than overwritten in place so
        // that the entries the loop below appends are the only ones it has to
        // build. `valid` is clamped to what is actually there, because a
        // frontier set by a splice in a column the array had not reached that
        // far names entries that do not exist yet.
        const valid: usize = @min(state.valid, state.entries.items.len);
        while (state.entries.items.len > valid) {
            state.entries.items[state.entries.items.len - 1].acc.deinit();
            state.entries.items.len -= 1;
        }
        try state.entries.ensureTotalCapacity(self.gpa, upto + 1);

        // The running aggregate and the row it covers up to. On entry to the
        // loop below, `next` names the first entry still to be written and
        // (`acc`, `row`) is the aggregate over the rows before slab `next`'s
        // own runs — that is, over the rows before slab `next - 1`'s first
        // row, which is what `row` is. Entry `next` is that plus slab
        // `next - 1`, so the loop needs exactly one fold per entry.
        var acc: MarkAcc = undefined;
        var row: usize = 0;
        var next: usize = valid;
        if (next > 0) {
            // The row comes **out of the array**, not out of a walk over every
            // slab in front of it. `storeAgg` recorded `start_row` as the row
            // the slab it wrote starts at, and `next - 1` is below the
            // frontier, which is exactly the claim that the entries below it
            // still line up with the slabs the column has — so the sum the walk
            // was computing is the number already sitting there. A test pins
            // the equality: `a column of many slabs answers every position`
            // walks the array and the slab lengths and wants them equal
            // (`mark_index.zig:3452-3455`).
            row = state.entries.items[next - 1].start_row;
            acc = try copyAcc(self.gpa, &state.entries.items[next - 1].acc);
        } else {
            // Entry zero aggregates no rows at all, and there is no slab in
            // front of the first one for a fold to cover, so it is written
            // from the identity. This is the branch every column nothing has
            // queried yet takes, and it is why the loop starts at one: at
            // zero its first `slabAt(next - 1)` would name slab minus one.
            acc = MarkAcc.init(self.gpa);
            try self.storeAgg(0, 0, &acc);
            next = 1;
        }
        // `defer`, not `errdefer`: `storeAgg` **copies** the aggregate into
        // the entry, so this one keeps owning its own two sets on the way
        // through the loop and has to give them back on the way out whether
        // the loop finished or was refused. An `errdefer` here freed it only
        // on the failure path and leaked the whole array on every call.
        defer acc.deinit();

        while (next <= upto) : (next += 1) {
            // Slab `next - 1` is the one slab between the aggregate in hand
            // and the entry being written, so the fold covers exactly its
            // rows, and `row` leaves the iteration standing on the first row
            // of slab `next` — which is the row the entry records.
            const slab_len = self.data.slabAt(next - 1).?.len;
            try self.foldRows(&acc, row, row + slab_len);
            row += slab_len;
            try self.storeAgg(next, row, &acc);
        }
        state.valid = upto + 1;
    }

    /// Writes entry `at`: `acc` is the aggregate over the rows before the slab
    /// whose first row is `row`, and `row` is that first row.
    ///
    /// **The copy is built before the array is touched**, so a refusal leaves
    /// the empty aggregate the growth loop appended standing where the array
    /// is counting it, rather than a half-written entry a later read could
    /// mistake for a built one.
    fn storeAgg(
        self: *const MarkIndexColumn,
        at: usize,
        row: usize,
        acc: *const MarkAcc,
    ) ParseError!void {
        const state = self.agg;
        while (state.entries.items.len <= at) {
            try state.entries.append(self.gpa, .{ .start_row = row, .acc = MarkAcc.init(self.gpa) });
        }
        const built = try copyAcc(self.gpa, acc);
        state.entries.items[at].acc.deinit();
        state.entries.items[at] = .{ .start_row = row, .acc = built };
    }

    /// The mark ids open at `target` (`mark_index.rs:315-331`).
    ///
    /// `gpa` allocates **the returned `MarkIter` only** — the `MarkAcc` it
    /// owns, which the caller frees with [`MarkIter.deinit`]. `clock` is
    /// *borrowed*: it is a view of the caller's, it is never freed here, and
    /// it must outlive the returned iterator.
    ///
    /// The prefix over a well-formed column has an empty `closes` set: every
    /// `End` has cancelled with a `Start` from an earlier row
    /// (`mark_index.rs:315-318`). Upstream asserts that (`mark_index.rs:319-323`)
    /// and this port *reports* it, as `error.InvalidValue` from `ParseError`.
    /// It is `ParseError` and not `InternalError` because the condition is a
    /// property of the document rather than of this code: a mark index column
    /// holding an `End` with no `Start` in front of it is bytes this port is
    /// expected to survive (`error.zig:6-12`), the refusal names the value that
    /// did not decode, and `InternalError` is reserved for a port bug
    /// (`error.zig:159-163`).
    pub fn marksAt(
        self: *const MarkIndexColumn,
        gpa: Allocator,
        target: usize,
        clock: ?Clock,
    ) ParseError!MarkIter {
        var acc = try self.total(gpa, target);
        errdefer acc.deinit();
        if (acc.closes.items.len != 0) return error.InvalidValue;
        return .{ .acc = acc, .clock = clock };
    }

    /// The marks open at `target`, with what each of them puts on its span
    /// (`mark_index.rs:302-313`).
    ///
    /// `gpa` allocates **the returned `OpenMarks` only**, which the caller
    /// frees with `out.deinit(gpa)`; `clock` is borrowed on the terms
    /// [`marksAt`] states. The map's `MarkData` values are the ones the cache
    /// holds, so their borrowed mark names are valid for as long as the
    /// document does — not merely for as long as the map.
    ///
    /// Every id `marksAt` yields has an entry in the cache — `extend` put one
    /// there for every `Start` — and upstream unwraps it (`mark_index.rs:306`);
    /// this port reports a missing one as `error.InvalidValue` rather than
    /// trapping, for the reason `marksAt` gives.
    pub fn richTextAt(
        self: *const MarkIndexColumn,
        gpa: Allocator,
        target: usize,
        clock: ?Clock,
    ) ParseError!OpenMarks {
        var out: OpenMarks = .empty;
        errdefer out.deinit(gpa);
        var ids = try self.marksAt(gpa, target, clock);
        defer ids.deinit();
        while (ids.next()) |begin| {
            const data = self.cache.get(begin) orelse return error.InvalidValue;
            try out.put(gpa, begin, data);
        }
        return out;
    }
};

/// The word a row's mark occupies, or null for a row that carries none.
fn decodeWord(word: Word) ?MarkIdx {
    const v = word orelse return null;
    return MarkIdx.load(v);
}

/// The same, for a cursor's answer, whose `null` is the end of the window — one
/// level out from the absent row that `decodeWord` answers.
fn decodeMaybe(maybe: ?Word) ?MarkIdx {
    const word = maybe orelse return null;
    return decodeWord(word);
}

/// Which way an actor renumbering moves the indices at or above the slot
/// ([`MarkIndexColumn.stageRemap`]'s second argument).
///
/// It is a second definition of a rule [`op_set.zig`](op_set.zig) also spells,
/// deliberately: that file's is private to the object table's staging and this
/// one's is about a row that cannot drop an entry the way an object entry can,
/// so the two have different reasons to exist and neither could be the other.
pub const Shift = enum {
    /// A new actor has been interned at the slot: everything at or above it
    /// moves up one (`mark_index.rs:51-58`).
    up,
    /// The actor at the slot has been removed: everything above it comes down
    /// one. Upstream renumbers nothing here — `OpSet::remove_actor`
    /// (`op_set2/op_set.rs:1419-1429`) touches `cols` and `obj_info` and not
    /// the mark index — which is what this arm exists to answer for.
    down,
};

/// [`Column.remapped`](../../src/hexane/column.zig)'s row function for `way`.
/// A row carrying no mark stays null on both arms.
fn shiftWord(comptime way: Shift) fn (ActorIdx, Word) Word {
    return switch (way) {
        .up => shiftWordUp,
        .down => shiftWordDown,
    };
}

/// An actor index at or above `idx` shifts up (`mark_index.rs:51-58`).
fn shiftWordUp(idx: ActorIdx, word: Word) Word {
    const m = decodeWord(word) orelse return null;
    return m.withNewActor(idx).asI64();
}

/// An actor index above `idx` comes down one (`OpId::without_actor`,
/// `types.rs:455-461`).
///
/// The `a == idx` arm cannot happen: [`stageRemap`](MarkIndexColumn.stageRemap)
/// has already refused an index that names `idx`, on this arm and only this
/// arm. A row cannot become "no mark" — this column is aligned with the op set
/// and has nothing to drop — so there is no honest answer for it here and the
/// unreachable arm says so rather than inventing one.
fn shiftWordDown(idx: ActorIdx, word: Word) Word {
    const m = decodeWord(word) orelse return null;
    return (m.withoutActor(idx) orelse unreachable).asI64();
}

/// A cache key's actor index moved the same way the rows' did, which is the
/// whole of [`stageRemap`](MarkIndexColumn.stageRemap): the two halves are
/// built from one `way` so they cannot disagree about it.
fn shiftCacheKey(comptime way: Shift, key: OpId, idx: ActorIdx) OpId {
    return switch (way) {
        .up => key.withNewActor(idx),
        // Unreachable for the reason [`shiftWordDown`] gives.
        .down => (key.withoutActor(idx) orelse unreachable),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// One mark's span, as the test tables name it: it opens at `start`, closes at
/// `end`, and its begin operation is `id` (`mark_index.rs:365-377`).
const Span = struct {
    start: usize,
    end: usize,
    id: OpId,
    name: []const u8,
};

/// One placed mark, for the tests that generate their spans.
const Placed = struct { id: OpId, start: usize, end: usize };

fn mkMark(name: []const u8) MarkData {
    return MarkData.init(name, .{ .bool_value = true });
}

fn id(actor: ActorIdx, counter: u32) OpId {
    return OpId.init(counter, actor);
}

/// A column of `n` rows with `spans` in it. A `Start` and an `End` occupy rows
/// that already exist; they insert nothing (`mark_index.rs:363-377`).
fn buildColumn(gpa: Allocator, n: usize, spans: []const Span) !MarkIndexColumn {
    var col = try MarkIndexColumn.init(gpa);
    errdefer col.deinit();
    const values = try gpa.alloc(?MarkIndexBuilder, n);
    defer gpa.free(values);
    for (values) |*value| value.* = null;
    for (spans) |span| {
        values[span.start] = .{ .start = .{ .id = span.id, .data = mkMark(span.name) } };
        values[span.end] = .{ .end = span.id };
    }
    try col.extend(0, values);
    return col;
}

fn retainedScalarAllocations(gpa: Allocator) !void {
    var col = try MarkIndexColumn.init(gpa);
    defer col.deinit();
    for (0..4) |kind| {
        var bytes = "example".*;
        const scalar: @import("../value.zig").ScalarValue = switch (kind) {
            0 => .{ .str = &bytes },
            1 => .{ .bytes = &bytes },
            2 => .{ .actor_id = .{ .bytes = &bytes } },
            3 => .{ .unknown = .{ .type_code = 15, .bytes = &bytes } },
            else => unreachable,
        };
        const begin = id(0, @intCast(kind + 1));
        const values = [_]?MarkIndexBuilder{
            .{ .start = .{ .id = begin, .data = MarkData.init("link", scalar) } },
            .{ .end = begin },
        };
        var staged = try col.stageExtend(col.len(), &values);
        defer staged.deinit();
        @memset(&bytes, 0xaa);
        staged.publish(&col);
        const kept = col.markData(begin) orelse return error.TestUnexpectedResult;
        const payload = switch (kept.value) {
            .str, .bytes => |v| v,
            .actor_id => |v| v.bytes,
            .unknown => |v| v.bytes,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqualStrings("example", payload);
    }
    // Two begins in one stage cover refusal after only the first scalar copy.
    const nested = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = id(0, 5), .data = MarkData.init("link", .{ .str = "outer" }) } },
        .{ .start = .{ .id = id(0, 6), .data = MarkData.init("link", .{ .str = "inner" }) } },
        .{ .end = id(0, 6) },
        .{ .end = id(0, 5) },
    };
    try col.extend(col.len(), &nested);
    var remapped = try col.stageRemap(0, .up);
    defer remapped.deinit();
    remapped.publish(&col);
    try testing.expectEqualStrings("example", col.markData(id(1, 1)).?.value.str);
    const removed = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = id(1, 1), .data = MarkData.init("link", .null_value) } },
        .{ .end = id(1, 1) },
    };
    try col.undo(0, &removed);
    try testing.expect(col.markData(id(1, 1)) == null);
    try testing.expectEqualStrings("example", col.markData(id(1, 2)).?.value.bytes);
}

test "cached mark scalars own bytes before their producer storage expires" {
    // Staging must retain all byte-bearing scalar variants independently.
    try testing.checkAllAllocationFailures(testing.allocator, retainedScalarAllocations, .{});
}

test "a staged URL mark survives releasing its producer allocation" {
    // A transaction may release its scalar buffer before the cache is read.
    const gpa = testing.allocator;
    var col = try MarkIndexColumn.init(gpa);
    defer col.deinit();
    var staged = blk: {
        const url = try gpa.dupe(u8, "https://example.com");
        defer gpa.free(url);
        const values = [_]?MarkIndexBuilder{
            .{ .start = .{ .id = id(0, 1), .data = MarkData.init("link", .{ .str = url }) } },
            .{ .end = id(0, 1) },
        };
        break :blk try col.stageExtend(0, &values);
    };
    defer staged.deinit();
    staged.publish(&col);
    try testing.expectEqualStrings("https://example.com", col.markData(id(0, 1)).?.value.str);
}

fn retainedOverlayAllocations(gpa: Allocator) !void {
    for ([_]bool{ false, true }) |publish| {
        var col = try MarkIndexColumn.init(gpa);
        defer col.deinit();
        const old = [_]?MarkIndexBuilder{
            .{ .start = .{ .id = id(0, 1), .data = MarkData.init("link", .{ .str = "old" }) } },
            .{ .end = id(0, 1) },
        };
        try col.extend(0, &old);
        var overlay: MarkIndexColumn.Overlay = undefined;
        try col.beginOverlay(&overlay);
        defer overlay.deinit();
        {
            var view: MarkIndexColumn = undefined;
            overlay.bind(&view);
            defer overlay.capture(&view);
            var bytes = "new".*;
            const added = [_]?MarkIndexBuilder{
                .{ .start = .{ .id = id(0, 2), .data = MarkData.init("link", .{ .str = &bytes }) } },
                .{ .end = id(0, 2) },
            };
            try view.extend(view.len(), &added);
            @memset(&bytes, 0xaa);
        }
        if (publish) {
            overlay.publish(&col);
            try testing.expectEqualStrings("new", col.markData(id(0, 2)).?.value.str);
        } else {
            overlay.deinit();
            try testing.expect(col.markData(id(0, 2)) == null);
        }
        try testing.expectEqualStrings("old", col.markData(id(0, 1)).?.value.str);
    }
}

test "mark cache overlay transfers or releases only its new scalar bytes" {
    // Failed staging, explicit abort and successful publication preserve old bytes.
    try testing.checkAllAllocationFailures(testing.allocator, retainedOverlayAllocations, .{});
}

/// The builder one modelled row arrives as (`mark_index.rs:363-377`).
fn builderOf(model: ?MarkIdx, name: []const u8) ?MarkIndexBuilder {
    const v = model orelse return null;
    return switch (v) {
        .start => |begin| .{ .start = .{ .id = begin, .data = mkMark(name) } },
        .end => |begin| .{ .end = begin },
    };
}

/// The column the model describes. One `Start` and one `End` per mark, and a
/// cache entry per `Start`.
fn columnFor(gpa: Allocator, model: []const ?MarkIdx) !MarkIndexColumn {
    var col = try MarkIndexColumn.init(gpa);
    errdefer col.deinit();
    const values = try gpa.alloc(?MarkIndexBuilder, model.len);
    defer gpa.free(values);
    for (values, model) |*value, m| {
        value.* = builderOf(m, "m");
    }
    try col.extend(0, values);
    return col;
}

/// Places `num_marks` marks over `n` rows, skipping any that would share a row
/// with another (`mark_index.rs:698-708`). A row carries one mark, so a
/// collision is a mark that cannot be placed.
fn placeMarks(
    gpa: Allocator,
    n: usize,
    num_marks: usize,
    seed: u64,
    model: []?MarkIdx,
    placed: *std.ArrayList(Placed),
) !void {
    for (model) |*v| v.* = null;
    var rng = Rng{ .state = seed };
    for (0..num_marks) |i| {
        const op_id = id(0, @intCast(i + 1));
        const start = rng.between(0, n - 2);
        const end = rng.between(start + 1, n);
        if (model[start] == null and model[end] == null) {
            model[start] = .{ .start = op_id };
            model[end] = .{ .end = op_id };
            try placed.append(gpa, .{ .id = op_id, .start = start, .end = end });
        }
    }
}

/// The mark ids open at `pos`, in op-id order (`mark_index.rs:379-381`).
fn activeMarkIds(gpa: Allocator, col: *const MarkIndexColumn, pos: usize) ![]OpId {
    var ids = try col.marksAt(gpa, pos, null);
    defer ids.deinit();
    var out: std.ArrayList(OpId) = .empty;
    errdefer out.deinit(gpa);
    while (ids.next()) |v| try out.append(gpa, v);
    return out.toOwnedSlice(gpa);
}

/// The names of the marks open at `pos`, in name order (`mark_index.rs:383-388`).
fn activeMarkNames(gpa: Allocator, col: *const MarkIndexColumn, pos: usize) ![][]const u8 {
    var ids = try col.marksAt(gpa, pos, null);
    defer ids.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    while (ids.next()) |v| {
        const data = col.markData(v) orelse return error.InvalidValue;
        try out.append(gpa, data.name);
    }
    std.mem.sort([]const u8, out.items, {}, nameLessThan);
    return out.toOwnedSlice(gpa);
}

fn nameLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }
    return false;
}

/// The two name lists, compared by content. `expectEqualSlices` over a slice of
/// slices would compare the elements' *pointers* (`std/testing.zig:120-136`),
/// which is not a comparison of the names.
fn expectNames(expected: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expect(std.mem.eql(u8, want, have));
}

fn expectIds(expected: []const OpId, got: []const OpId) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expect(want.eql(have));
}

/// The rows a mark's `Start` and `End` occupy (`mark_index.rs:390-402`).
fn findMarkPositions(gpa: Allocator, col: *const MarkIndexColumn, target: OpId) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var it = try col.iter();
    var pos: usize = 0;
    while (try it.nextRun()) |run| {
        if (run.value) |value| switch (value) {
            .start => |begin| if (begin.eql(target)) {
                for (0..run.count) |k| try out.append(gpa, pos + k);
            },
            .end => |begin| if (begin.eql(target)) {
                for (0..run.count) |k| try out.append(gpa, pos + k);
            },
        };
        pos += run.count;
    }
    return out.toOwnedSlice(gpa);
}

/// The brute-force oracle: scan the rows up to `pos` and collect what is open
/// (`mark_index.rs:673-690`). Deliberately a linear scan over an *unsorted*
/// list, so it shares no routine with the implementation it checks.
fn oracleMarksAt(gpa: Allocator, model: []const ?MarkIdx, pos: usize) ![]OpId {
    var open: std.ArrayList(OpId) = .empty;
    errdefer open.deinit(gpa);
    for (model[0..@min(pos + 1, model.len)]) |value| {
        if (value) |v| switch (v) {
            .start => |begin| try open.append(gpa, begin),
            .end => |begin| for (open.items, 0..) |held, i| {
                if (held.eql(begin)) {
                    _ = open.orderedRemove(i);
                    break;
                }
            },
        };
    }
    std.mem.sort(OpId, open.items, {}, OpId.lessThan);
    return open.toOwnedSlice(gpa);
}

/// A SplitMix64 generator, spelled as `sequence_tree.zig:659-677` spells it, so
/// the test stream is reproducible without a dependency.
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A value in `[lo, hi)`.
    fn between(self: *Rng, lo: usize, hi: usize) usize {
        std.debug.assert(hi > lo);
        return lo + @as(usize, @intCast(self.next() % @as(u64, @intCast(hi - lo))));
    }
};

test "a start and an end are the signed word upstream stores" {
    // `mark_index.rs:25-34` and its inverse at `:36-49`.
    try testing.expectEqual(@as(i64, 1), (MarkIdx{ .start = id(0, 1) }).asI64());
    try testing.expectEqual(@as(i64, -1), (MarkIdx{ .end = id(0, 1) }).asI64());
    // Actor 1, counter 0: the actor half sits a whole bit-word above.
    try testing.expectEqual(@as(i64, 4294967296), (MarkIdx{ .start = id(1, 0) }).asI64());
    try testing.expectEqual(@as(i64, -4294967296), (MarkIdx{ .end = id(1, 0) }).asI64());
    // Actor 0, counter 0xffffffff: the counter is masked to 32 bits.
    try testing.expectEqual(@as(i64, 4294967295), (MarkIdx{ .start = id(0, 0xffffffff) }).asI64());

    for ([_]MarkIdx{
        .{ .start = id(0, 0) },
        .{ .start = id(0, 1) },
        .{ .end = id(0, 1) },
        .{ .start = id(1, 0) },
        .{ .end = id(1, 0) },
        .{ .start = id(7, 0x89abcdef) },
        .{ .end = id(0xffff, 0xffffffff) },
    }) |value| {
        try testing.expect(value.eql(MarkIdx.load(value.asI64())));
    }
}

test "the largest actor and counter the word holds, and the alias above it" {
    // Actor 2^31-1 with the whole counter is the largest word whose sign bit is
    // still clear, so it is the largest `Start` there is.
    const biggest = MarkIdx{ .start = id(0x7fffffff, 0xffffffff) };
    try testing.expectEqual(@as(i64, 9223372036854775807), biggest.asI64());
    try testing.expect(biggest.eql(MarkIdx.load(biggest.asI64())));

    // One actor higher and the word is `minInt(i64)`, which decodes as an
    // `End`: the encoding is only injective below actor index 2^31, which is
    // upstream's property too (`mark_index.rs:25-34`). Pinned because the word is
    // the column's value type, not because a document carries it.
    const alias = MarkIdx{ .start = id(0x80000000, 0) };
    try testing.expectEqual(std.math.minInt(i64), alias.asI64());
    try testing.expect((MarkIdx{ .end = id(0x80000000, 0) }).eql(MarkIdx.load(alias.asI64())));
    // And the negation of the largest word is the smallest, which decodes to the
    // actor it lost its sign to rather than trapping.
    try testing.expectEqual(
        (MarkIdx{ .end = id(0x80000000, 0) }),
        MarkIdx.load(std.math.minInt(i64)),
    );
}

test "the aggregate is a set: what opens and closes cancels, and sub undoes add" {
    // `mark_index.rs:105-123` for the cancellation, `:159-191` for the algebra.
    const gpa = testing.allocator;
    const a = id(0, 1);
    const b = id(0, 2);

    var acc = MarkAcc.init(gpa);
    defer acc.deinit();
    try acc.applyOne(.{ .start = a });
    try acc.applyOne(.{ .start = b });
    try testing.expectEqual(@as(usize, 2), acc.opens.items.len);
    try testing.expectEqual(@as(usize, 0), acc.closes.items.len);

    // An `End` whose `Start` has been seen closes the mark and leaves nothing
    // dangling (`mark_index.rs:118-122`).
    try acc.applyOne(.{ .end = b });
    try testing.expectEqual(@as(usize, 1), acc.opens.items.len);
    try testing.expectEqual(@as(usize, 0), acc.closes.items.len);

    // An `End` with nothing open is a dangling close, which is a different
    // answer from "no marks" and the reason a count would not do.
    const c = id(0, 3);
    try acc.applyOne(.{ .end = c });
    try testing.expectEqual(@as(usize, 1), acc.opens.items.len);
    try testing.expectEqual(@as(usize, 1), acc.closes.items.len);
    try testing.expect(acc.closes.items[0].eql(c));
    // An id is never in both sets.
    try testing.expect(!containsSorted(acc.opens.items, c));

    // A `Start` for an id with a dangling close cancels the close and does not
    // open the mark: the pair of deltas is matched, and the net for an id is
    // one of {-1, 0, +1} (`mark_index.rs:82-86`).
    try acc.applyOne(.{ .start = c });
    try testing.expectEqual(@as(usize, 1), acc.opens.items.len);
    try testing.expect(acc.opens.items[0].eql(a));
    try testing.expectEqual(@as(usize, 0), acc.closes.items.len);

    // The borrowed merge, over an aggregate that has a dangling close in it.
    var dangling = MarkAcc.init(gpa);
    defer dangling.deinit();
    try dangling.applyOne(.{ .end = a });
    var merged = MarkAcc.init(gpa);
    defer merged.deinit();
    try merged.applyOne(.{ .start = a });
    try merged.addAssignRef(&dangling);
    // A close whose begin is already open cancels that open mark rather than
    // leaving a dangling close of its own (`mark_index.rs:159-161`).
    try testing.expectEqual(@as(usize, 0), merged.opens.items.len);
    try testing.expectEqual(@as(usize, 0), merged.closes.items.len);

    // The borrowed merge left `dangling` whole, so the merge can be taken back
    // out of it — that is what makes the prefix walk invertible, and it is
    // only the borrowing form that allows it.
    try merged.subAssign(try dupAcc(gpa, dangling));
    try testing.expectEqual(@as(usize, 1), merged.opens.items.len);
    try testing.expect(merged.opens.items[0].eql(a));
    try testing.expectEqual(@as(usize, 0), merged.closes.items.len);

    // `add` then `sub` is the identity. The right-hand side opens `b` and
    // closes `a`, so the sum is not the union: it is `b` alone. `add` and `sub`
    // each consume both of their operands, so every round builds its own.
    var left = try leftOf(gpa, a);
    var right = MarkAcc.init(gpa);
    try right.applyOne(.{ .start = b });
    try right.applyOne(.{ .end = a });
    var sum = try MarkAcc.add(&left, &right);
    defer sum.deinit();
    try testing.expectEqual(@as(usize, 1), sum.opens.items.len);
    try testing.expect(sum.opens.items[0].eql(b));
    try testing.expectEqual(@as(usize, 0), sum.closes.items.len);

    var left2 = try leftOf(gpa, a);
    var right2 = MarkAcc.init(gpa);
    try right2.applyOne(.{ .start = b });
    try right2.applyOne(.{ .end = a });
    // `sum2` is consumed by the `sub` below, so it is not freed here: `sub`
    // takes over its sets and leaves it undefined.
    var sum2 = try MarkAcc.add(&left2, &right2);
    try testing.expect(sum2.eql(sum));

    var right3 = MarkAcc.init(gpa);
    try right3.applyOne(.{ .start = b });
    try right3.applyOne(.{ .end = a });
    var back = try MarkAcc.sub(&sum2, &right3);
    defer back.deinit();

    var left3 = try leftOf(gpa, a);
    defer left3.deinit();
    try testing.expect(back.eql(left3));
    try testing.expectEqual(@as(usize, 1), back.opens.items.len);
    try testing.expect(back.opens.items[0].eql(a));
    try testing.expectEqual(@as(usize, 0), back.closes.items.len);
}

/// A fresh copy of `other`, for the case that needs an operand `subAssign` can
/// consume while the original is still wanted.
fn dupAcc(gpa: Allocator, other: MarkAcc) !MarkAcc {
    var out = MarkAcc.init(gpa);
    errdefer out.deinit();
    for (other.opens.items) |v| try out.opens.append(gpa, v);
    for (other.closes.items) |v| try out.closes.append(gpa, v);
    return out;
}

/// The aggregate of one `Start(begin)`: one open, nothing dangling.
fn leftOf(gpa: Allocator, begin: OpId) !MarkAcc {
    var out = MarkAcc.init(gpa);
    errdefer out.deinit();
    try out.opens.append(gpa, begin);
    return out;
}

test "copyAcc answers what the borrowed merge answers, on both sets and at size" {
    // `copyAcc` is what every prefix read runs: it is the merge of a slab's own
    // aggregate into a fresh one, and it is the one step of a read whose cost is
    // proportional to the answer. It was `addAssignRef` over an empty target and
    // is now two set differences (`copyAcc`'s doc carries the argument). This is
    // the witness that the two agree, over the three shapes the merge can see —
    // nothing, opens alone, opens and closes together — and at a size where the
    // sorted-insert cascade `addAssignRef` walks is wide enough for a difference
    // in what it lands to show.

    const gpa = testing.allocator;
    const n = 400;

    // A stream of deltas over `n` ids: three fifths are opened and stay open,
    // one fifth is closed and never opened (a dangling close), and one fifth
    // is opened and closed in turn and so cancels. `closes` is non-empty
    // throughout, which is the shape the second difference walks and the one
    // a prefix over a well-formed column never reaches.
    var both = MarkAcc.init(gpa);
    defer both.deinit();
    for (1..n + 1) |c| {
        const begin = id(@intCast(c % 3), @intCast(c));
        switch (c % 5) {
            0 => try both.applyOne(.{ .end = begin }),
            4 => {
                try both.applyOne(.{ .start = begin });
                try both.applyOne(.{ .end = begin });
            },
            else => try both.applyOne(.{ .start = begin }),
        }
    }
    try testing.expect(both.opens.items.len != 0);
    try testing.expect(both.closes.items.len != 0);

    var got = try copyAcc(gpa, &both);
    defer got.deinit();
    var want = MarkAcc.init(gpa);
    defer want.deinit();
    try want.addAssignRef(&both);
    try testing.expect(want.eql(got));
    try expectIds(want.opens.items, got.opens.items);
    try expectIds(want.closes.items, got.closes.items);
    // The order is the document's, which is what every exact comparison in
    // this file rests on, and no id is in both sets.
    for (got.opens.items, 0..) |v, i| {
        if (i != 0) try testing.expect(got.opens.items[i - 1].order(v) == .lt);
        try testing.expect(!containsSorted(got.closes.items, v));
    }

    // The other two shapes. The empty one is the identity, and the opens-only
    // one is the whole of what a prefix read over a well-formed column ever
    // copies ([`MarkAcc`], on why `closes` stays empty there).
    var nothing = MarkAcc.init(gpa);
    defer nothing.deinit();
    var empty = try copyAcc(gpa, &nothing);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.opens.items.len);
    try testing.expectEqual(@as(usize, 0), empty.closes.items.len);

    var opens_only = MarkAcc.init(gpa);
    defer opens_only.deinit();
    for (1..n + 1) |c| {
        try opens_only.applyOne(.{ .start = id(@intCast(c % 3), @intCast(c)) });
    }
    var opened = try copyAcc(gpa, &opens_only);
    defer opened.deinit();
    var want_opens = MarkAcc.init(gpa);
    defer want_opens.deinit();
    try want_opens.addAssignRef(&opens_only);
    try testing.expect(want_opens.eql(opened));
    try expectIds(want_opens.opens.items, opened.opens.items);

    // **A `src` whose two sets share an id**, which the copy this replaced
    // reached by absorbing a close out of the copy's own opens. The argument
    // the two differences rest on is that each set is sorted and duplicate
    // free, so this answers the same either way — and saying so is what keeps
    // the walk honest if an aggregate is ever built another way.
    var shared = MarkAcc.init(gpa);
    defer shared.deinit();
    try shared.opens.append(gpa, id(0, 1));
    try shared.opens.append(gpa, id(0, 2));
    try shared.closes.append(gpa, id(0, 2));
    var got_shared = try copyAcc(gpa, &shared);
    defer got_shared.deinit();
    var want_shared = MarkAcc.init(gpa);
    defer want_shared.deinit();
    try want_shared.addAssignRef(&shared);
    try testing.expect(want_shared.eql(got_shared));
    try testing.expectEqual(@as(usize, 1), got_shared.opens.items.len);
    try testing.expect(got_shared.opens.items[0].eql(id(0, 1)));
    try testing.expectEqual(@as(usize, 0), got_shared.closes.items.len);
}

test "an empty column has no marks anywhere" {
    // `mark_index.rs:399-403`.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 0, &.{});
    defer col.deinit();
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(!col.hasAnyMarks());

    var rt = try col.richTextAt(gpa, 0, null);
    defer rt.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rt.count());

    var it = try col.iter();
    try testing.expect((try it.next()) == null);
}

test "one mark's span is open from its start row to the row before its end" {
    // `mark_index.rs:405-421`: bold over positions 2..7.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 10, &.{
        .{ .start = 2, .end = 7, .id = id(0, 1), .name = "bold" },
    });
    defer col.deinit();
    try testing.expect(col.hasAnyMarks());
    try testing.expectEqual("bold", (col.markData(id(0, 1)) orelse return error.InvalidValue).name);
    try testing.expect(col.markData(id(0, 2)) == null);

    const before = try activeMarkNames(gpa, &col, 0);
    defer gpa.free(before);
    try expectNames(&.{}, before);
    const after = try activeMarkNames(gpa, &col, 9);
    defer gpa.free(after);
    try expectNames(&.{}, after);

    for ([_]usize{ 2, 4, 6 }) |pos| {
        const names = try activeMarkNames(gpa, &col, pos);
        defer gpa.free(names);
        try expectNames(&.{"bold"}, names);
    }
    // The `End` row itself is no longer open: the prefix is inclusive of it.
    const at_end = try activeMarkNames(gpa, &col, 7);
    defer gpa.free(at_end);
    try expectNames(&.{}, at_end);
}

test "marks that do not overlap" {
    // `mark_index.rs:423-440`.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 9, &.{
        .{ .start = 1, .end = 3, .id = id(0, 1), .name = "bold" },
        .{ .start = 5, .end = 7, .id = id(0, 2), .name = "italic" },
    });
    defer col.deinit();

    const cases = [_]struct { pos: usize, want: []const []const u8 }{
        .{ .pos = 0, .want = &.{} },
        .{ .pos = 1, .want = &.{"bold"} },
        .{ .pos = 2, .want = &.{"bold"} },
        .{ .pos = 3, .want = &.{} },
        .{ .pos = 4, .want = &.{} },
        .{ .pos = 5, .want = &.{"italic"} },
        .{ .pos = 6, .want = &.{"italic"} },
        .{ .pos = 7, .want = &.{} },
    };
    for (cases) |case| {
        const names = try activeMarkNames(gpa, &col, case.pos);
        defer gpa.free(names);
        try expectNames(case.want, names);
    }
}

test "overlapping marks" {
    // `mark_index.rs:442-459`: bold 1..6, italic 3..8.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 10, &.{
        .{ .start = 1, .end = 6, .id = id(0, 1), .name = "bold" },
        .{ .start = 3, .end = 8, .id = id(0, 2), .name = "italic" },
    });
    defer col.deinit();

    const cases = [_]struct { pos: usize, want: []const []const u8 }{
        .{ .pos = 0, .want = &.{} },
        .{ .pos = 1, .want = &.{"bold"} },
        .{ .pos = 2, .want = &.{"bold"} },
        .{ .pos = 3, .want = &.{ "bold", "italic" } },
        .{ .pos = 5, .want = &.{ "bold", "italic" } },
        .{ .pos = 6, .want = &.{"italic"} },
        .{ .pos = 7, .want = &.{"italic"} },
        .{ .pos = 8, .want = &.{} },
    };
    for (cases) |case| {
        const names = try activeMarkNames(gpa, &col, case.pos);
        defer gpa.free(names);
        try expectNames(case.want, names);
    }
}

test "nested marks" {
    // `mark_index.rs:461-473`: outer 0..9, inner 3..6.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 10, &.{
        .{ .start = 0, .end = 9, .id = id(0, 1), .name = "outer" },
        .{ .start = 3, .end = 6, .id = id(0, 2), .name = "inner" },
    });
    defer col.deinit();

    const cases = [_]struct { pos: usize, want: []const []const u8 }{
        .{ .pos = 0, .want = &.{"outer"} },
        .{ .pos = 2, .want = &.{"outer"} },
        .{ .pos = 3, .want = &.{ "inner", "outer" } },
        .{ .pos = 5, .want = &.{ "inner", "outer" } },
        .{ .pos = 6, .want = &.{"outer"} },
        .{ .pos = 8, .want = &.{"outer"} },
        .{ .pos = 9, .want = &.{} },
    };
    for (cases) |case| {
        const names = try activeMarkNames(gpa, &col, case.pos);
        defer gpa.free(names);
        try expectNames(case.want, names);
    }
}

test "undo removes a mark and leaves the others" {
    // `mark_index.rs:475-510`: bold 2..7, italic 4..9, undo bold.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 12, &.{
        .{ .start = 2, .end = 7, .id = id(0, 1), .name = "bold" },
        .{ .start = 4, .end = 9, .id = id(0, 2), .name = "italic" },
    });
    defer col.deinit();

    const both = try activeMarkNames(gpa, &col, 5);
    defer gpa.free(both);
    try expectNames(&.{ "bold", "italic" }, both);

    const bold = id(0, 1);
    const bold_rows = try findMarkPositions(gpa, &col, bold);
    defer gpa.free(bold_rows);
    try testing.expectEqual(@as(usize, 2), bold_rows.len);

    try col.undo(bold_rows[1], &[_]?MarkIndexBuilder{.{ .end = bold }});
    try col.undo(bold_rows[0], &[_]?MarkIndexBuilder{.{
        .start = .{ .id = bold, .data = mkMark("bold") },
    }});

    // The undone mark is gone from the cache, not only from the rows.
    try testing.expect(col.markData(bold) == null);
    try testing.expect(col.markData(id(0, 2)) != null);

    var any_italic = false;
    for (0..col.len()) |pos| {
        const names = try activeMarkNames(gpa, &col, pos);
        defer gpa.free(names);
        try testing.expect(!containsName(names, "bold"));
        if (containsName(names, "italic")) any_italic = true;
    }
    try testing.expect(any_italic);
}

test "undo preserves the other marks at every position" {
    // `mark_index.rs:512-551`: a 1..5, b 3..8, c 6..10, undo b.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 12, &.{
        .{ .start = 1, .end = 5, .id = id(0, 1), .name = "a" },
        .{ .start = 3, .end = 8, .id = id(0, 2), .name = "b" },
        .{ .start = 6, .end = 10, .id = id(0, 3), .name = "c" },
    });
    defer col.deinit();

    const cases = [_]struct { pos: usize, want: []const []const u8 }{
        .{ .pos = 1, .want = &.{"a"} },
        .{ .pos = 4, .want = &.{ "a", "b" } },
        .{ .pos = 7, .want = &.{ "b", "c" } },
    };
    for (cases) |case| {
        const names = try activeMarkNames(gpa, &col, case.pos);
        defer gpa.free(names);
        try expectNames(case.want, names);
    }

    const b = id(0, 2);
    const b_rows = try findMarkPositions(gpa, &col, b);
    defer gpa.free(b_rows);
    try testing.expectEqual(@as(usize, 2), b_rows.len);
    try col.undo(b_rows[1], &[_]?MarkIndexBuilder{.{ .end = b }});
    try col.undo(b_rows[0], &[_]?MarkIndexBuilder{.{
        .start = .{ .id = b, .data = mkMark("b") },
    }});

    var any_a = false;
    var any_c = false;
    for (0..col.len()) |pos| {
        const names = try activeMarkNames(gpa, &col, pos);
        defer gpa.free(names);
        try testing.expect(!containsName(names, "b"));
        if (containsName(names, "a")) any_a = true;
        if (containsName(names, "c")) any_c = true;
    }
    try testing.expect(any_a);
    try testing.expect(any_c);
}

test "undo is verified at every position" {
    // `mark_index.rs:553-635`: bold 2..8, italic 4..11, underline 6..13.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 15, &.{
        .{ .start = 2, .end = 8, .id = id(0, 1), .name = "bold" },
        .{ .start = 4, .end = 11, .id = id(0, 2), .name = "italic" },
        .{ .start = 6, .end = 13, .id = id(0, 3), .name = "underline" },
    });
    defer col.deinit();

    const cases = [_]struct { pos: usize, want: []const []const u8 }{
        .{ .pos = 0, .want = &.{} },
        .{ .pos = 2, .want = &.{"bold"} },
        .{ .pos = 5, .want = &.{ "bold", "italic" } },
        .{ .pos = 7, .want = &.{ "bold", "italic", "underline" } },
        .{ .pos = 9, .want = &.{ "italic", "underline" } },
        .{ .pos = 12, .want = &.{"underline"} },
        .{ .pos = 14, .want = &.{} },
    };
    for (cases) |case| {
        const names = try activeMarkNames(gpa, &col, case.pos);
        defer gpa.free(names);
        try expectNames(case.want, names);
    }

    // Undo italic, then underline, checking every row after each.
    const steps = [_]struct { mark: OpId, name: []const u8, len_after: usize }{
        .{ .mark = id(0, 2), .name = "italic", .len_after = 13 },
        .{ .mark = id(0, 3), .name = "underline", .len_after = 11 },
    };
    for (steps) |step| {
        const rows = try findMarkPositions(gpa, &col, step.mark);
        defer gpa.free(rows);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = step.mark }});
        try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
            .start = .{ .id = step.mark, .data = mkMark(step.name) },
        }});
        try testing.expectEqual(step.len_after, col.len());
        try testing.expect(col.markData(step.mark) == null);

        for (0..col.len()) |pos| {
            const names = try activeMarkNames(gpa, &col, pos);
            defer gpa.free(names);
            try testing.expect(!containsName(names, step.name));
        }
    }

    var has_bold = false;
    for (0..col.len()) |pos| {
        const names = try activeMarkNames(gpa, &col, pos);
        defer gpa.free(names);
        if (containsName(names, "bold")) has_bold = true;
    }
    try testing.expect(has_bold);
}

test "rich text at every position agrees with a brute force oracle" {
    // `mark_index.rs:637-661`, with the oracle of `:673-690`.
    const gpa = testing.allocator;
    // bold 2..6, italic 4..10, underline 8..12, as `mark_index.rs:642-652`.
    var full: [15]?MarkIdx = @splat(null);
    for ([_]struct { start: usize, end: usize, id: OpId }{
        .{ .start = 2, .end = 6, .id = id(0, 1) },
        .{ .start = 4, .end = 10, .id = id(0, 2) },
        .{ .start = 8, .end = 12, .id = id(0, 3) },
    }) |span| {
        full[span.start] = .{ .start = span.id };
        full[span.end] = .{ .end = span.id };
    }

    var col = try columnFor(gpa, &full);
    defer col.deinit();
    for (0..col.len()) |pos| {
        const want = try oracleMarksAt(gpa, &full, pos);
        defer gpa.free(want);

        const got = try activeMarkIds(gpa, &col, pos);
        defer gpa.free(got);
        try expectIds(want, got);

        var rt = try col.richTextAt(gpa, pos, null);
        defer rt.deinit(gpa);
        try testing.expectEqual(want.len, rt.count());
        for (want) |mark_id| try testing.expect(rt.contains(mark_id));
    }
}

test "extend then undo restores the column byte for byte, inside one slab and across many" {
    // `undo` is `splice(index, del, ())` (`mark_index.rs:297-299`) and `extend`
    // is `splice(index, 0, values)` (`:288`), so the two are exact inverses.
    // `encode` is the canonical run sequence whatever the slab layout was
    // (`hexane/column.zig:2429-2446`), so comparing the bytes compares the
    // column and not the way it happens to be cut up.
    const gpa = testing.allocator;

    for ([_]usize{ 24, 4000 }) |n| {
        const model = try gpa.alloc(?MarkIdx, n);
        defer gpa.free(model);
        var placed: std.ArrayList(Placed) = .empty;
        defer placed.deinit(gpa);
        try placeMarks(gpa, n, n / 8, 42, model, &placed);

        var col = try columnFor(gpa, model);
        defer col.deinit();
        // Every mark contributes two rows, and a slab holds at most
        // `default_max_segments` runs (`hexane/slab.zig:91`), so the larger
        // column is spread over many slabs and the undo below crosses them.
        if (n > 100) try testing.expect(col.data.slabCount() > 1);

        const before = try col.data.encode(gpa);
        defer gpa.free(before);

        for ([_]usize{ 0, n / 3, n - 1 }) |at| {
            const temp = id(9, 77);
            const added = [_]?MarkIndexBuilder{
                .{ .start = .{ .id = temp, .data = mkMark("temp") } },
                null,
                null,
                .{ .end = temp },
            };
            try col.extend(at, &added);
            try col.undo(at, &added);

            const after = try col.data.encode(gpa);
            defer gpa.free(after);
            try testing.expectEqualSlices(u8, before, after);
            try testing.expectEqual(n, col.len());
            try testing.expect(col.markData(temp) == null);
        }
    }
}

test "a remap moves the rows' actor indices and the cache's keys together" {
    // `mark_index.rs:271-289`. A remap that moved only the rows would leave the
    // cache keyed by the old actor table, and `markData` would answer null for
    // every mark in the document.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 9, &.{
        // Two actors, so the shift moves the second and leaves the first.
        .{ .start = 1, .end = 4, .id = id(0, 1), .name = "a" },
        .{ .start = 5, .end = 8, .id = id(1, 2), .name = "b" },
    });
    defer col.deinit();

    const before = try col.data.toSlice(gpa);
    defer gpa.free(before);
    try col.remapValues(1);

    // Every row's actor is shifted, and nothing else about the rows changes.
    const after = try col.data.toSlice(gpa);
    defer gpa.free(after);
    try testing.expectEqual(before.len, after.len);
    for (before, after) |was, now| {
        if (was == null) {
            try testing.expect(now == null);
            continue;
        }
        try testing.expectEqual(
            MarkIdx.load(was.?).withNewActor(1),
            MarkIdx.load(now.?),
        );
    }

    // Actor 0 is below the insertion point and stays; actor 1 shifts to 2.
    try testing.expect(col.markData(id(0, 1)) != null);
    try testing.expectEqual("a", (col.markData(id(0, 1)) orelse return error.InvalidValue).name);
    try testing.expect(col.markData(id(1, 2)) == null);
    try testing.expectEqual("b", (col.markData(id(2, 2)) orelse return error.InvalidValue).name);

    // And the two agree at every position: every id the rows yield is a key of
    // the cache, which is what `richTextAt` needs and what a row-only remap
    // would break.
    for (0..col.len()) |pos| {
        var rt = try col.richTextAt(gpa, pos, null);
        defer rt.deinit(gpa);
        var it = rt.iterator();
        while (it.next()) |kv| try testing.expect(col.cache.contains(kv.key_ptr.*));
    }
}

test "a downward remap moves both stores down, and the check covers both of them" {
    // Upstream's `OpSet::remove_actor` renumbers neither store
    // (`op_set2/op_set.rs:1419-1429`), so this direction is the port's own; the
    // actors *above* the removed one move, and their marks move with them.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 9, &.{
        .{ .start = 1, .end = 4, .id = id(0, 1), .name = "a" },
        .{ .start = 5, .end = 8, .id = id(2, 2), .name = "b" },
    });
    defer col.deinit();

    // Both actors are named, in a row and in the cache.
    try testing.expect(try col.referencesActor(0));
    try testing.expect(!try col.referencesActor(1));
    try testing.expect(try col.referencesActor(2));

    {
        var staged = try col.stageRemap(1, .down);
        defer staged.deinit();
        staged.publish(&col);
    }

    // The unused slot 1 is gone; actor 2 came down to 1 in both stores.
    try testing.expect(!try col.referencesActor(2));
    try testing.expect(col.markData(id(2, 2)) == null);
    try testing.expectEqualStrings("b", (col.markData(id(1, 2)) orelse return error.InvalidValue).name);
    // Actor 0's own mark was below the removed slot and did not move.
    try testing.expectEqualStrings("a", (col.markData(id(0, 1)) orelse return error.InvalidValue).name);
    for (0..col.len()) |pos| {
        var rt = try col.richTextAt(gpa, pos, null);
        defer rt.deinit(gpa);
        var it = rt.iterator();
        while (it.next()) |kv| try testing.expect(col.cache.contains(kv.key_ptr.*));
    }
}

test "a downward remap refuses an index that names the actor being removed" {
    // **The row has nowhere to go.** The column is aligned with the op set, so
    // a row naming the removed actor cannot be dropped without moving every
    // row above it — which is why [`MarkIdx.withoutActor`] answers null and
    // [`stageRemap`] refuses rather than reaching [`shiftWordDown`]'s
    // unreachable arm.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 9, &.{
        .{ .start = 1, .end = 4, .id = id(0, 1), .name = "a" },
        .{ .start = 5, .end = 8, .id = id(1, 2), .name = "b" },
    });
    defer col.deinit();
    const before = try col.data.toSlice(gpa);
    defer gpa.free(before);

    try testing.expectError(error.InvalidValue, col.stageRemap(0, .down));
    try testing.expectError(error.InvalidValue, col.stageRemap(1, .down));

    // Nothing moved: the rows byte for byte, and both entries still answer.
    const after = try col.data.toSlice(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(?i64, before, after);
    try testing.expectEqualStrings("a", (col.markData(id(0, 1)) orelse return error.InvalidValue).name);
    try testing.expectEqualStrings("b", (col.markData(id(1, 2)) orelse return error.InvalidValue).name);
}

test "a clock hides the marks it does not cover" {
    // `mark_index.rs:328`, with `Clock::covers` at `types.rs:134-136`.
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 9, &.{
        .{ .start = 1, .end = 6, .id = id(0, 1), .name = "a" },
        .{ .start = 2, .end = 5, .id = id(1, 1), .name = "b" },
    });
    defer col.deinit();

    // Actor 0 has seen counter 4; actor 1 has seen nothing.
    var clock = try Clock.init(gpa, 2);
    defer clock.deinit();
    try testing.expect(clock.include(0, 4));

    const all = try activeMarkIds(gpa, &col, 3);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);

    var scoped = try col.marksAt(gpa, 3, clock);
    defer scoped.deinit();
    const only_a = scoped.next();
    try testing.expect(only_a != null and only_a.?.eql(id(0, 1)));
    try testing.expect(scoped.next() == null);

    var rt = try col.richTextAt(gpa, 3, clock);
    defer rt.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), rt.count());
    try testing.expect(rt.contains(id(0, 1)));
    try testing.expect(!rt.contains(id(1, 1)));
}

test "iterRange walks the rows, and every non-null run of a well-formed column is one row" {
    // `mark_index.rs:256-260`, the run walk `calculate_marks_fast` makes
    // (`op_set2/op_set.rs:988-995`), and the uniqueness the run-at-a-time fold
    // rests on (`mark_index.rs:199-207`).
    const gpa = testing.allocator;
    var col = try buildColumn(gpa, 12, &.{
        .{ .start = 2, .end = 7, .id = id(0, 1), .name = "bold" },
    });
    defer col.deinit();

    var it = try col.iterRange(.{ .start = 0, .end = col.len() });
    var pos: usize = 0;
    var marks: usize = 0;
    while (try it.nextRun()) |run| {
        try testing.expect(run.count > 0);
        if (run.value) |value| switch (value) {
            .start => |begin| {
                try testing.expectEqual(@as(usize, 1), run.count);
                try testing.expect(begin.eql(id(0, 1)));
                try testing.expectEqual(@as(usize, 2), pos);
                marks += 1;
            },
            .end => |begin| {
                try testing.expectEqual(@as(usize, 1), run.count);
                try testing.expect(begin.eql(id(0, 1)));
                try testing.expectEqual(@as(usize, 7), pos);
                marks += 1;
            },
        };
        pos += run.count;
    }
    try testing.expectEqual(col.len(), pos);
    try testing.expectEqual(@as(usize, 2), marks);

    // A window of rows that carry no mark is a window of *absent* values, so
    // `next` cannot be the way to walk it: an absent row and the end of the
    // window are the same `null`. Upstream's `Iter<Option<MarkIdx>>` has the
    // same property, which is why `calculate_marks_fast` walks runs
    // (`op_set2/op_set.rs:988-995`).
    var window = try col.iterRange(.{ .start = 3, .end = 6 });
    try testing.expectEqual(@as(usize, 3), window.maxPos() - window.pos());
    var seen: usize = 0;
    while (try window.nextRun()) |run| {
        try testing.expect(run.value == null);
        seen += run.count;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a column of many slabs answers every position, before and after an undo" {
    // Upstream's `large_column_multi_slab` (`mark_index.rs:691-819`), which is
    // `#[ignore]`d there for its size. Ported at that size, with the oracle
    // kept: it is the only case that covers a prefix fold crossing slab
    // boundaries and an undo crossing them.
    const gpa = testing.allocator;
    const n = 100_000;
    const num_marks = 2500;

    const model = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(model);
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    try placeMarks(gpa, n, num_marks, 42, model, &placed);
    try testing.expect(placed.items.len > 100);

    var col = try columnFor(gpa, model);
    defer col.deinit();
    try testing.expectEqual(n, col.len());
    try testing.expect(col.data.slabCount() > 1);

    var check_positions: std.ArrayList(usize) = .empty;
    defer check_positions.deinit(gpa);
    var rng = Rng{ .state = 7 };
    for (0..200) |_| try check_positions.append(gpa, rng.between(0, n));
    for ([_]usize{ 0, 1, n / 4, n / 2, 3 * n / 4, n - 2, n - 1 }) |p| {
        try check_positions.append(gpa, p);
    }
    for (check_positions.items) |p| {
        const want = try oracleMarksAt(gpa, model, p);
        defer gpa.free(want);
        const got = try activeMarkIds(gpa, &col, p);
        defer gpa.free(got);
        try expectIds(want, got);
    }

    // Undo every third mark, the last one first so the rows behind it keep
    // their positions, then rebuild the model the column should now hold and
    // check every position against it (`mark_index.rs:760-790`).
    var undone: std.AutoHashMapUnmanaged(OpId, void) = .empty;
    defer undone.deinit(gpa);
    var index = placed.items.len;
    while (index > 0) {
        index -= 1;
        const mark = placed.items[index];
        if (index % 3 != 0) continue;
        const rows = try findMarkPositions(gpa, &col, mark.id);
        defer gpa.free(rows);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
        try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
            .start = .{ .id = mark.id, .data = mkMark("m") },
        }});
        try testing.expect(col.markData(mark.id) == null);
        try undone.put(gpa, mark.id, {});
    }

    var kept = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(kept);
    var kept_len: usize = 0;
    for (model) |value| {
        if (value) |v| switch (v) {
            .start => |begin| if (undone.contains(begin)) continue,
            .end => |begin| if (undone.contains(begin)) continue,
        };
        kept[kept_len] = value;
        kept_len += 1;
    }
    try testing.expectEqual(kept_len, col.len());

    var rng2 = Rng{ .state = 11 };
    check_positions.clearRetainingCapacity();
    for (0..200) |_| try check_positions.append(gpa, rng2.between(0, col.len()));
    for ([_]usize{ 0, 1, col.len() / 4, col.len() / 2, 3 * col.len() / 4, col.len() - 1 }) |p| {
        try check_positions.append(gpa, p);
    }
    for (check_positions.items) |p| {
        const want = try oracleMarksAt(gpa, kept[0..kept_len], p);
        defer gpa.free(want);
        const got = try activeMarkIds(gpa, &col, p);
        defer gpa.free(got);
        try expectIds(want, got);
    }
}

test "an extend the column refuses leaves no mark behind" {
    const gpa = testing.allocator;
    const begin = id(1, 1);
    var col = try MarkIndexColumn.init(gpa);
    defer col.deinit();
    try testing.expect(!col.hasAnyMarks());

    // `index` past the end is `error.InvalidValue` from the column's own
    // splice (`hexane/column.zig:3429`). `extend` writes the cache before the
    // rows, so without the rollback this index would carry a `MarkData` for a
    // row that was never inserted, and `hasAnyMarks` — which reads the cache
    // without going through the rows — would answer "this document has a
    // mark" for an index with no rows at all.
    try testing.expectError(error.InvalidValue, col.extend(4, &[_]?MarkIndexBuilder{.{
        .start = .{ .id = begin, .data = mkMark("bold") },
    }}));

    // The two halves agree on what happened: no row, and no cache entry for
    // it.
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expectEqual(@as(?i64, null), try col.get(0));
    try testing.expect(col.markData(begin) == null);
    try testing.expect(!col.hasAnyMarks());
}

test "a refused extend leaves the cache and the rows describing each other" {
    const gpa = testing.allocator;
    const begin = id(3, 5);
    const values = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = begin, .data = mkMark("bold") } },
        null,
        .{ .end = begin },
    };

    // The cache and the rows are two writes, and `hasAnyMarks` is the one
    // reader that reads the cache on its own, so an allocation refused
    // between them would show up as a mark in a document that has none.
    // Every refusal is swept: after each one the index must hold all three
    // rows **and** the cache entry, or none of either — never a cache entry
    // for a row the splice never inserted.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var col = try MarkIndexColumn.init(failing.allocator());
        defer col.deinit();
        try col.extend(0, &values);

        // **The probe is the successful outcome, not just an allocation
        // count.** It has to be: every arm of the sweep below refuses
        // somewhere, so the committed branch is only ever reached through
        // here, and a write that quietly landed nothing would otherwise pass
        // the whole test.
        try testing.expectEqual(@as(usize, 3), col.len());
        try testing.expect(col.hasAnyMarks());
        try testing.expect(col.markData(begin) != null);
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = begin }).asI64()), try col.get(0));
        break :blk failing.alloc_index;
    };

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const arm = failing.allocator();
        // A refusal in the setup says nothing about `extend`, so it is
        // skipped rather than turned into a pass: `fail_index` counts from
        // the first allocation of the run, and the run's first allocations
        // are the column's own.
        var col = MarkIndexColumn.init(arm) catch continue;
        defer col.deinit();

        var committed = true;
        col.extend(0, &values) catch |e| switch (e) {
            error.OutOfMemory => committed = false,
            else => return error.TestUnexpectedResult,
        };

        if (committed) {
            try testing.expectEqual(@as(usize, 3), col.len());
            try testing.expect(col.hasAnyMarks());
            try testing.expect(col.markData(begin) != null);
        } else {
            try testing.expectEqual(@as(usize, 0), col.len());
            try testing.expect(col.markData(begin) == null);
            try testing.expect(!col.hasAnyMarks());
        }
    }
}

test "a refused remap leaves the rows and the cache on the same actor table" {
    const gpa = testing.allocator;
    const bold = id(0, 1);
    const em = id(1, 1);
    const values = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = bold, .data = mkMark("bold") } },
        .{ .start = .{ .id = em, .data = mkMark("em") } },
        .{ .end = em },
        .{ .end = bold },
    };

    // **The two halves are staged, so the pair is all-or-nothing.** Every
    // refusal is swept, and after each one the index must still be
    // *consistent*: the cache is keyed by the same actor table the rows are.
    // A remap that moved the rows before the cache was rebuilt would leave
    // `markData` null for every mark and `richTextAt` yielding nothing, which
    // is the window `OpSet.rewriteWithNewActor` has no fallback for — the
    // mark index is the last fallible step on that path.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var probe = MarkIndexColumn.init(failing.allocator()) catch unreachable;
        defer probe.deinit();
        probe.extend(0, &values) catch unreachable;
        probe.remapValues(1) catch unreachable;

        // The probe checks the outcome, for the reason the staged write's
        // probe does: a remap that did nothing would pass a sweep whose arms
        // all refuse.
        try testing.expectEqual(@as(usize, 4), probe.len());
        try testing.expect(probe.markData(em.withNewActor(1)) != null);
        try testing.expect(probe.markData(em) == null);
        try testing.expectEqual(
            @as(?i64, (MarkIdx{ .start = em.withNewActor(1) }).asI64()),
            try probe.get(1),
        );
        break :blk failing.alloc_index;
    };

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const arm = failing.allocator();
        // A refusal in the setup says nothing about the remap, so it is
        // skipped rather than turned into a pass.
        var col = MarkIndexColumn.init(arm) catch continue;
        defer col.deinit();
        col.extend(0, &values) catch continue;

        var committed = true;
        col.remapValues(1) catch |e| switch (e) {
            error.OutOfMemory => committed = false,
            else => return error.TestUnexpectedResult,
        };

        // `bold`'s actor index is below the inserted one and `em`'s is not,
        // so a committed remap moves only `em`. Both halves are checked, so
        // a half-applied remap cannot pass by agreeing with itself.
        try testing.expectEqual(@as(usize, 4), col.len());
        try testing.expect(col.hasAnyMarks());
        try testing.expect(col.markData(bold) != null);
        if (committed) {
            try testing.expect(col.markData(em) == null);
            try testing.expect(col.markData(em.withNewActor(1)) != null);
            try testing.expectEqual(
                @as(?i64, (MarkIdx{ .start = em.withNewActor(1) }).asI64()),
                try col.get(1),
            );
        } else {
            try testing.expect(col.markData(em) != null);
            try testing.expect(col.markData(em.withNewActor(1)) == null);
            try testing.expectEqual(
                @as(?i64, (MarkIdx{ .start = em }).asI64()),
                try col.get(1),
            );
        }
    }
}

test "a refused staged write leaves the index exactly as it was" {
    const gpa = testing.allocator;
    const bold = id(0, 1);
    const em = id(1, 1);
    const ital = id(0, 2);
    const before = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = bold, .data = mkMark("bold") } },
        .{ .start = .{ .id = em, .data = mkMark("em") } },
        .{ .end = em },
        .{ .end = bold },
    };
    const added = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = ital, .data = mkMark("ital") } },
    };

    // Everything an unchanged index must still answer: the rows, the length,
    // the two cache entries and the two borrowed names, and the words the
    // rows decode to. A refusal that moved any one of them is the failure
    // this is here for.
    const unchanged = struct {
        fn run(col: *const MarkIndexColumn, bold_id: OpId, em_id: OpId, ital_id: OpId) !void {
            try testing.expectEqual(@as(usize, 4), col.len());
            try testing.expect(col.hasAnyMarks());
            try testing.expect(col.markData(bold_id) != null);
            try testing.expect(col.markData(em_id) != null);
            try testing.expect(col.markData(ital_id) == null);
            try testing.expectEqualStrings("bold", col.markData(bold_id).?.name);
            try testing.expectEqualStrings("em", col.markData(em_id).?.name);
            try testing.expectEqual(@as(?i64, (MarkIdx{ .start = bold_id }).asI64()), try col.get(0));
            try testing.expectEqual(@as(?i64, (MarkIdx{ .end = bold_id }).asI64()), try col.get(3));
        }
    }.run;

    // Every refusal is swept, from the first allocation of the run to the
    // last. `extend` is the stage plus a publish, so the sweep covers the
    // whole write and not just the staging half.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var probe = MarkIndexColumn.init(failing.allocator()) catch unreachable;
        defer probe.deinit();
        probe.extend(0, &before) catch unreachable;
        var staged = probe.stageExtend(2, &added) catch unreachable;
        staged.publish(&probe);

        // **This is the assertion the sweep's committed branch makes.** It
        // belongs here as well: every arm below refuses somewhere, so without
        // it a staged write that landed nothing would pass the whole test.
        try testing.expectEqual(@as(usize, 5), probe.len());
        try testing.expectEqualStrings("ital", probe.markData(ital).?.name);
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = ital }).asI64()), try probe.get(2));
        break :blk failing.alloc_index;
    };

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const arm = failing.allocator();
        // A refusal in the setup says nothing about the staged write, so it
        // is skipped rather than turned into a pass.
        var col = MarkIndexColumn.init(arm) catch continue;
        defer col.deinit();
        col.extend(0, &before) catch continue;

        var refused = false;
        var staged: MarkIndexColumn.StagedMarkIndex = undefined;
        if (col.stageExtend(2, &added)) |s| {
            staged = s;
        } else |e| switch (e) {
            error.OutOfMemory => refused = true,
            else => return error.TestUnexpectedResult,
        }

        if (refused) {
            try unchanged(&col, bold, em, ital);
            continue;
        }
        staged.publish(&col);

        // Committed: the row is there **and** its `MarkData` is, which is the
        // whole claim — a cache entry with no row is the state that cannot
        // arise.
        try testing.expectEqual(@as(usize, 5), col.len());
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = bold }).asI64()), try col.get(0));
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = ital }).asI64()), try col.get(2));
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = em }).asI64()), try col.get(3));
        try testing.expectEqualStrings("ital", col.markData(ital).?.name);
        try testing.expectEqualStrings("em", col.markData(em).?.name);
    }
}

test "a refused staged removal leaves the index exactly as it was" {
    const gpa = testing.allocator;
    const bold = id(0, 1);
    const em = id(1, 1);
    const before = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = bold, .data = mkMark("bold") } },
        .{ .start = .{ .id = em, .data = mkMark("em") } },
        .{ .end = em },
        .{ .end = bold },
    };
    const gone = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = em, .data = mkMark("em") } },
        .{ .end = em },
    };

    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var probe = MarkIndexColumn.init(failing.allocator()) catch unreachable;
        defer probe.deinit();
        probe.extend(0, &before) catch unreachable;
        var staged = probe.stageUndo(1, &gone) catch unreachable;
        staged.publish(&probe);

        // **This is the assertion that exercises the removal at all.** The
        // sweep below can only reach its committed branch if the probe got
        // this far, so without it the whole removal path would be checked for
        // refusals only — and a removal that removed nothing, or that put the
        // rows back, would pass.
        try testing.expectEqual(@as(usize, 2), probe.len());
        try testing.expect(probe.markData(em) == null);
        try testing.expect(probe.markData(bold) != null);
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = bold }).asI64()), try probe.get(0));
        try testing.expectEqual(@as(?i64, (MarkIdx{ .end = bold }).asI64()), try probe.get(1));
        break :blk failing.alloc_index;
    };

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const arm = failing.allocator();
        var col = MarkIndexColumn.init(arm) catch continue;
        defer col.deinit();
        col.extend(0, &before) catch continue;

        var refused = false;
        var staged: MarkIndexColumn.StagedMarkIndex = undefined;
        if (col.stageUndo(1, &gone)) |s| {
            staged = s;
        } else |e| switch (e) {
            error.OutOfMemory => refused = true,
            else => return error.TestUnexpectedResult,
        }

        if (refused) {
            // Both halves are still the old ones: four rows, and `em`'s
            // `MarkData` still cached for the row that is still there.
            try testing.expectEqual(@as(usize, 4), col.len());
            try testing.expect(col.markData(em) != null);
            try testing.expectEqual(@as(?i64, (MarkIdx{ .start = em }).asI64()), try col.get(1));
            continue;
        }
        staged.publish(&col);

        try testing.expectEqual(@as(usize, 2), col.len());
        try testing.expect(col.markData(em) == null);
        try testing.expectEqual(@as(?i64, (MarkIdx{ .start = bold }).asI64()), try col.get(0));
        try testing.expectEqual(@as(?i64, (MarkIdx{ .end = bold }).asI64()), try col.get(1));
        try testing.expect(col.hasAnyMarks());
    }
}

test "a staged write can be aborted, and deinit after publish is a no-op" {
    const gpa = testing.allocator;
    const bold = id(0, 1);
    const ital = id(0, 2);
    var col = try buildColumn(gpa, 2, &.{
        .{ .start = 0, .end = 1, .id = bold, .name = "bold" },
    });
    defer col.deinit();

    const added = [_]?MarkIndexBuilder{
        .{ .start = .{ .id = ital, .data = mkMark("ital") } },
    };

    // **The abort is free of side effects on the index**, which is what lets
    // a caller stage twenty writers and drop one without unwinding any of the
    // others.
    var abandoned = try col.stageExtend(2, &added);
    try testing.expectEqual(@as(usize, 3), abandoned.newLen());
    abandoned.deinit();
    try testing.expectEqual(@as(usize, 2), col.len());
    try testing.expect(col.markData(ital) == null);
    try testing.expect(col.markData(bold) != null);

    // And the same stage publishes: the `defer` below is the idiom a caller
    // uses at every site, and it must not be a double free once the publish
    // has run.
    var staged = try col.stageExtend(2, &added);
    defer staged.deinit();
    try testing.expectEqual(@as(usize, 3), staged.newLen());
    staged.publish(&col);
    try testing.expectEqual(@as(usize, 3), col.len());
    try testing.expectEqualStrings("ital", col.markData(ital).?.name);
    try testing.expectEqual(@as(?i64, (MarkIdx{ .start = ital }).asI64()), try col.get(2));
}

test "padding a mark index preserves marks and appends absent rows" {
    const gpa = testing.allocator;
    const bold = id(0, 1);
    var col = try buildColumn(gpa, 2, &.{
        .{ .start = 0, .end = 1, .id = bold, .name = "bold" },
    });
    defer col.deinit();

    // Pad the index to the op row count without adding or removing a mark.
    const pad = [_]?MarkIndexBuilder{ null, null, null };
    var staged = try col.stageExtend(2, &pad);
    defer staged.deinit();

    // Publishing the pad preserves the existing mark and leaves each new row absent.
    staged.publish(&col);
    try testing.expectEqual(@as(usize, 5), col.len());
    try testing.expect(col.hasAnyMarks());
    try testing.expectEqualStrings("bold", col.markData(bold).?.name);
    try testing.expectEqual(@as(?i64, (MarkIdx{ .start = bold }).asI64()), try col.get(0));
    for ([_]usize{ 2, 3, 4 }) |at| {
        try testing.expectEqual(@as(?i64, null), try col.get(at));
    }
}

/// The rows one mark occupies, taken out of a model in place: what an undone
/// mark leaves behind is the same rows with its own two gone.
fn removeMarkRows(live: []?MarkIdx, live_len: *usize, target: OpId) void {
    var kept: usize = 0;
    var at: usize = 0;
    while (at < live_len.*) : (at += 1) {
        const v = live[at];
        const gone = if (v) |m| switch (m) {
            .start => |begin| begin.eql(target),
            .end => |begin| begin.eql(target),
        } else false;
        if (gone) continue;
        live[kept] = v;
        kept += 1;
    }
    live_len.* = kept;
}

test "the prefix answers every position, before and after every write" {
    // The case the per-slab prefix exists for, and the one the case above it
    // cannot make. That one answers every position either side of ONE undo,
    // so a prefix a single write failed to invalidate would still agree with
    // the model at every position it asked about. Here a write is interleaved
    // with the reads, so a frontier that did not move — or a reader that took
    // an entry above it — is answered wrong at the *next* position asked for
    // rather than the next hundred.
    //
    // The rounds step through the placed marks by a stride that does not
    // divide their count, so the splice points walk across the whole column
    // rather than marching through it: the frontier is asked to hold at a low
    // slab and at a high one, at both ends, and with the array grown to only
    // part of the way.
    const gpa = testing.allocator;
    const n = 20_000;
    const num_marks = 600;

    const model = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(model);
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    try placeMarks(gpa, n, num_marks, 5, model, &placed);
    try testing.expect(placed.items.len > 100);

    var col = try columnFor(gpa, model);
    defer col.deinit();
    try testing.expectEqual(n, col.len());
    try testing.expect(col.data.slabCount() > 1);

    // The live model: what the column should hold after each removal, and what
    // every position is checked against.
    var live = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(live);
    @memcpy(live[0..n], model);
    var live_len: usize = n;

    var rng = Rng{ .state = 23 };
    for (0..40) |round| {
        const mark = placed.items[(round * 37) % placed.items.len];
        if (col.markData(mark.id) != null) {
            const rows = try findMarkPositions(gpa, &col, mark.id);
            defer gpa.free(rows);
            try testing.expectEqual(@as(usize, 2), rows.len);
            try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
            try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
                .start = .{ .id = mark.id, .data = mkMark("m") },
            }});
            try testing.expect(col.markData(mark.id) == null);
            removeMarkRows(live, &live_len, mark.id);
        }
        try testing.expectEqual(live_len, col.len());

        // Sampled positions, and the two ends — the ends are what an
        // off-by-one in the frontier or in the landing slab shows up on first.
        for (0..6) |_| {
            try expectActive(gpa, &col, live[0..live_len], rng.between(0, live_len));
        }
        for ([_]usize{ 0, live_len - 1, live_len / 2 }) |p| {
            try expectActive(gpa, &col, live[0..live_len], p);
        }
    }
}

/// What [`MarkIndexColumn.marksAt`] answers at `pos`, against the brute-force
/// oracle over `model`, in exact op-id order.
fn expectActive(
    gpa: Allocator,
    col: *const MarkIndexColumn,
    model: []const ?MarkIdx,
    pos: usize,
) !void {
    const want = try oracleMarksAt(gpa, model, pos);
    defer gpa.free(want);
    const got = try activeMarkIds(gpa, col, pos);
    defer gpa.free(got);
    try expectIds(want, got);
}

test "a position is answered before any other, on a column nothing has queried yet" {
    // The first ask on a fresh index is the path with no entry in front of it
    // to fold from: the frontier is zero and the walk that rebuilds from it
    // has no slab behind entry zero. Every position here is asked with the
    // frontier still at zero, which is the case that has to work.
    const gpa = testing.allocator;
    const bold = id(0, 1);
    const model = [_]?MarkIdx{
        null,
        .{ .start = bold },
        null,
        .{ .end = bold },
    };

    // One slab, so every position lands on slab zero: the first ask is the
    // `upto == 0` path with `valid == 0`, and the second reads the same entry
    // back out of the array rather than rebuilding it.
    {
        var col = try buildColumn(gpa, model.len, &.{
            .{ .start = 1, .end = 3, .id = bold, .name = "bold" },
        });
        defer col.deinit();
        try testing.expectEqual(@as(usize, 0), col.agg.valid);
        try expectActive(gpa, &col, &model, 0);
        try expectActive(gpa, &col, &model, 1);
        try expectActive(gpa, &col, &model, 2);
        // Past the end, which lands on the last row of the last slab.
        try expectActive(gpa, &col, &model, 99);
        // The first ask wrote exactly one entry, and it is slab zero's base.
        try testing.expectEqual(@as(usize, 1), col.agg.valid);
        try testing.expectEqual(@as(usize, 0), col.agg.entries.items[0].start_row);
        try testing.expect(col.agg.entries.items[0].acc.opens.items.len == 0);
    }

    // Many slabs, asked deepest first: the frontier is zero and the entry
    // wanted is the last one, so the whole walk from entry zero runs.
    const n = 8_000;
    {
        const wide = try gpa.alloc(?MarkIdx, n);
        defer gpa.free(wide);
        var placed: std.ArrayList(Placed) = .empty;
        defer placed.deinit(gpa);
        try placeMarks(gpa, n, 600, 9, wide, &placed);
        var wide_len: usize = n;
        var col = try columnFor(gpa, wide);
        defer col.deinit();
        try testing.expectEqual(@as(usize, 0), col.agg.valid);
        try testing.expect(col.data.slabCount() > 1);

        try expectActive(gpa, &col, wide, n - 1);
        try expectActive(gpa, &col, wide, 0);
        try expectActive(gpa, &col, wide, 2);
        // Every entry now names the row its slab starts at, which is what a
        // write measures the frontier against.
        try testing.expectEqual(col.data.slabCount(), col.agg.valid);
        try testing.expectEqual(col.data.slabCount(), col.agg.entries.items.len);
        var at: usize = 0;
        for (col.agg.entries.items, 0..) |entry, i| {
            try testing.expectEqual(at, entry.start_row);
            at += col.data.slabAt(i).?.len;
        }

        // And a write on top of a fully built array still answers: the
        // frontier has to survive a splice in the middle of the column, and
        // the entries below it have to keep naming the rows they folded.
        const mark = placed.items[placed.items.len / 2];
        const rows = try findMarkPositions(gpa, &col, mark.id);
        defer gpa.free(rows);
        try testing.expectEqual(@as(usize, 2), rows.len);
        try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
        try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
            .start = .{ .id = mark.id, .data = mkMark("m") },
        }});
        removeMarkRows(wide, &wide_len, mark.id);
        try testing.expectEqual(wide_len, col.len());

        try expectActive(gpa, &col, wide[0..wide_len], 0);
        try expectActive(gpa, &col, wide[0..wide_len], wide_len - 1);
        try expectActive(gpa, &col, wide[0..wide_len], wide_len / 2);
    }
}

test "a repair that resumes above the frontier reads its row out of the entry" {
    // `repairAggs` reading its row out of the entry it resumes from, which is
    // the whole of what reaching the frontier costs.
    //
    // The case above reaches the frontier from zero, because the first ask in
    // each block is at or near the head of the column. This one puts the frontier
    // in the middle: a write lowers it to some `f > 0`, and the next ask at the
    // **deepest** slab then resumes the walk at `valid` rather than at zero — so
    // the row the fold starts from has to be `entries[valid - 1].start_row`. If
    // that read were wrong the fold would start in the middle of a slab, and the
    // entry it wrote would name a row its slab does not start at.
    //
    // Every entry is then checked twice: that its `start_row` is the row its
    // slab starts at, and that its aggregate is the fold over exactly the rows
    // before that row — the second against the brute-force oracle, so this does
    // not check the aggregate against itself.

    const gpa = testing.allocator;
    const n = 8_000;
    const wide = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(wide);
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    try placeMarks(gpa, n, 600, 9, wide, &placed);
    var wide_len: usize = n;
    var col = try columnFor(gpa, wide);
    defer col.deinit();
    try testing.expect(col.data.slabCount() > 1);

    // Ask the deepest position first, so the whole array is built and the
    // frontier is the slab count.
    try expectActive(gpa, &col, wide, n - 1);
    try testing.expectEqual(col.data.slabCount(), col.agg.valid);

    // A write in the middle of the column lowers the frontier to somewhere
    // above zero and below the slab count — the case this test is about. The
    // mark is chosen by **position**, not by placement order, because a write
    // at row zero or at the tail would put the frontier at either end and
    // leave nothing between them to resume from.
    var chosen: ?Placed = null;
    for (placed.items) |p| {
        if (p.start > n / 4 and p.start < (3 * n) / 4) {
            chosen = p;
            break;
        }
    }
    const mark = chosen orelse placed.items[0];
    const rows = try findMarkPositions(gpa, &col, mark.id);
    defer gpa.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try col.undo(rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
    try col.undo(rows[0], &[_]?MarkIndexBuilder{.{
        .start = .{ .id = mark.id, .data = mkMark("m") },
    }});
    removeMarkRows(wide, &wide_len, mark.id);
    try testing.expectEqual(wide_len, col.len());
    try testing.expect(col.agg.valid > 0);
    try testing.expect(col.agg.valid < col.data.slabCount());

    // The deepest ask again: this repair starts above the frontier, so it
    // takes its running row from an entry rather than re-adding slab lengths.
    try expectActive(gpa, &col, wide[0..wide_len], wide_len - 1);
    try testing.expectEqual(col.data.slabCount(), col.agg.valid);

    var at: usize = 0;
    for (col.agg.entries.items, 0..) |entry, i| {
        // The row the entry folds up to is the row its slab starts at.
        try testing.expectEqual(at, entry.start_row);
        // And the aggregate over it is the fold over exactly `0..at`, against
        // the oracle rather than against another entry.
        try testing.expectEqual(@as(usize, 0), entry.acc.closes.items.len);
        if (at != 0) {
            const want = try oracleMarksAt(gpa, wide[0..wide_len], at - 1);
            defer gpa.free(want);
            try expectIds(want, entry.acc.opens.items);
        } else {
            try testing.expectEqual(@as(usize, 0), entry.acc.opens.items.len);
        }
        at += col.data.slabAt(i).?.len;
    }
    try testing.expectEqual(col.len(), at);
}

test "a refusal part way through building the prefix leaves it answering" {
    // The prefix is built by allocating, so a refusal can land between the
    // entry being appended and the copy being put into it. Two things have to
    // survive that, and they are separate claims:
    //
    //   * the frontier never names an entry that is not there, so no reader
    //     can take a half-built one, and `deinit` has what is left to
    //     release; and
    //   * **the same column answers the same positions afterwards**, which is
    //     what `storeAgg`'s copy-before-touch ordering and `repairAggs`'s
    //     `defer acc.deinit()` are for.
    //
    // The second claim needs an allocator that can recover, and
    // `std.testing.FailingAllocator` cannot supply one — see [`RefuseOnce`]
    // for what it does instead and why that matters here.
    const gpa = testing.allocator;
    const n = 800;
    const model = try gpa.alloc(?MarkIdx, n);
    defer gpa.free(model);
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    try placeMarks(gpa, n, 100, 3, model, &placed);
    try testing.expect(placed.items.len > 10);

    const asked = [_]usize{ n - 1, n / 2, 0 };

    // What a clean build plus those three reads has to answer, measured by a
    // probe that checks the outcome and not just the allocation count: an arm
    // that reaches the reads at all has to have produced these.
    const wanted = blk: {
        const out = try gpa.alloc([]OpId, asked.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |w| gpa.free(w);
            gpa.free(out);
        }
        while (filled < asked.len) : (filled += 1) {
            out[filled] = try oracleMarksAt(gpa, model, asked[filled]);
        }
        break :blk out;
    };
    defer {
        for (wanted) |w| gpa.free(w);
        gpa.free(wanted);
    }

    // How many allocations the clean run takes, so the sweep visits each one.
    // `FailingAllocator` with no `fail_index` never refuses and does count,
    // which is the only thing it is used for here.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var probe = try columnFor(failing.allocator(), model);
        defer probe.deinit();
        try testing.expect(probe.data.slabCount() > 1);
        for (asked, wanted) |p, want| {
            var ids = try probe.marksAt(failing.allocator(), p, null);
            defer ids.deinit();
            try idsMatch(&ids, want);
        }
        break :blk failing.alloc_index;
    };

    for (0..needed) |at| {
        var once: RefuseOnce = .{ .inner = gpa, .at = at };
        const arm = once.allocator();

        // A refusal in the build says nothing about the reads, so it is
        // skipped rather than turned into a pass.
        var col = columnFor(arm, model) catch |e| switch (e) {
            error.OutOfMemory => continue,
            else => return error.TestUnexpectedResult,
        };
        defer col.deinit();

        // The reads, which is where the prefix is built. An arm whose refusal
        // landed here either answers or reports `OutOfMemory`, and nothing
        // else is a pass.
        for (asked) |p| {
            var ids = col.marksAt(arm, p, null) catch |e| switch (e) {
                error.OutOfMemory => continue,
                else => return error.TestUnexpectedResult,
            };
            ids.deinit();
        }

        // The frontier never names an entry that is not there, whatever the
        // refusal did — and `deinit` on the way out has to give back what is
        // left of the array, which the testing allocator checks.
        try testing.expect(col.agg.valid <= col.agg.entries.items.len);

        // And the column answers every position again, with no further
        // refusal: the aggregate that was half-copied is gone, not merely
        // unreached.
        for (asked, wanted) |p, want| {
            var ids = try col.marksAt(arm, p, null);
            defer ids.deinit();
            try idsMatch(&ids, want);
        }
    }
}

/// Whether the marks still in `ids` are exactly `want`, in order. Allocates
/// nothing, so a refusal sweep can run it on an arm that is holding a
/// refusing allocator.
fn idsMatch(ids: *MarkIter, want: []const OpId) !void {
    var at: usize = 0;
    while (ids.next()) |begin| {
        if (at >= want.len or !begin.eql(want[at])) return error.TestUnexpectedResult;
        at += 1;
    }
    if (at != want.len) return error.TestUnexpectedResult;
}

/// An allocator that refuses **exactly one** allocation — the one at index
/// `at` — and behaves normally either side of it.
///
/// **`std.testing.FailingAllocator` cannot do this.** Its `alloc` returns
/// *before* `alloc_index` advances (`std/testing/FailingAllocator.zig:65-79`
/// on this Zig), so `fail_index = k` refuses every allocation that reaches
/// index `k`, for the rest of that allocator's life: it latches. There is no
/// "after" to observe, so a sweep built on it can assert that a refusal leaves
/// nothing corrupt but can never assert that the object it refused recovers.
/// That is the half of this file's refusal contract that `storeAgg`'s
/// copy-before-touch ordering and `repairAggs`'s `defer acc.deinit()` exist to
/// provide, and it is worth a test.
///
/// The index counts `resize` as well as `alloc`, because a managed
/// `std.ArrayList` may grow in place and a sweep counting only `alloc` would
/// step over allocations that matter. A refused `resize` is not terminal — the
/// caller falls back to `alloc`, which is the next index along.
const RefuseOnce = struct {
    /// The allocator every real request goes to.
    inner: Allocator,
    /// The allocation index this one refuses.
    at: usize,
    /// How many requests have been made, `alloc` and `resize` together.
    seen: usize = 0,
    /// Whether it already has. This is what makes it *once*: the counter is
    /// deliberately left where it was on the refusal, so the next request is
    /// the same index and would be refused again without this flag.
    refused: bool = false,

    fn allocator(self: *RefuseOnce) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *RefuseOnce = @ptrCast(@alignCast(ctx));
        if (self.seen == self.at and !self.refused) {
            self.refused = true;
            return null;
        }
        self.seen += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *RefuseOnce = @ptrCast(@alignCast(ctx));
        if (self.seen == self.at and !self.refused) {
            self.refused = true;
            return false;
        }
        self.seen += 1;
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    /// `remap` is the third growth path an allocator can be asked for, and this
    /// toolchain's `Allocator.VTable` carries it
    /// (`std/mem/Allocator.zig:69`), so a vtable without one does not
    /// compile. It refuses on the same condition as `alloc` and `resize`, and
    /// otherwise defers to the inner allocator: a caller that gets `null` from
    /// `remap` falls back to `alloc` plus `copy` at the next index along, which
    /// is the path the sweep is meant to exercise.
    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *RefuseOnce = @ptrCast(@alignCast(ctx));
        if (self.seen == self.at and !self.refused) {
            self.refused = true;
            return null;
        }
        self.seen += 1;
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *RefuseOnce = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ra);
    }
};
