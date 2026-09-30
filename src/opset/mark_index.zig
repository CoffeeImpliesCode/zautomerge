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
//! (`mark_index.rs:213-217`): a prefix column whose prefix is a *set*, and the
//! aggregate the index stores per slab is that same set. `marks_at` reads it
//! in one descent (`hexane/src/prefix.rs:550-555`, which is
//! `get_prefix(index + 1)` at `:543-548` — a fold over the rows `0..=index`).
//!
//! The port's column engine instantiates `btree.Tree(A)` over a weight that
//! declares `Aggregate.{identity, merge, itemCount, eql}` and never looks
//! inside one (`hexane/btree.zig:156-168`; those four aliases are the whole of
//! the generic core's use of `A`) — which is why a set-valued aggregate *fits*
//! the tree. It cannot hold one as written, because the tree copies weights
//! byte for byte (`copyOf` is `gpa.dupe`, `btree.zig:140-147`, called from
//! `:277` and `:480`) and `Tree.deinit` (`:232-243`) frees none of what a
//! weight owns: a weight carrying sets would alias the staging buffer the
//! column frees immediately after building the index
//! (`hexane/column.zig:3227-3237`) and leak the rest of itself.
//!
//! So `MarkAcc` is the prefix aggregate of the column's *values*, and
//! `MarkIndexColumn.total` folds it from the first row to `target`: the same
//! value `get_total` returns, reached by walking the other way. The difference
//! is cost, not answer — a fold is O(runs before `target`) where a descent is
//! O(log S) set merges — and `marks_at`'s only production caller is
//! `rich_text_at` (`op_set2/op_set.rs:484`, `:557`, `:1035`), which asks once
//! per query rather than once per row. Giving the weight ownership is a change
//! to `btree.zig` — an `Aggregate` that declares `deinit` and `clone` for its
//! weight — and it is not this file's to make.
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
    /// The shift is done in `u64` and reinterpreted, because the port treats a
    /// signed shift that discards bits as undefined where upstream's Rust `<<`
    /// is a plain bit shift (`types.rs:447-453` has the same shape for the
    /// actor index). At and above actor index 2^31 the top bit is the sign
    /// bit and the row's polarity stops being recoverable, so the encoding is
    /// only injective below 2^31 — upstream's property too, noted at
    /// `docs/survey/02-transaction-opset.md:1155`.
    pub fn asI64(self: MarkIdx) i64 {
        return switch (self) {
            .start => |begin| startWord(begin),
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

    pub fn eql(a: MarkIdx, b: MarkIdx) bool {
        return switch (a) {
            .start => |begin| b == .start and b.start.eql(begin),
            .end => |begin| b == .end and b.end.eql(begin),
        };
    }
};

/// `(actor << 32) | counter` as the stored word (`mark_index.rs:27`, `:43`).
/// Both halves are `u32` and disjoint, so upstream's `+` and a bitwise or agree.
fn startWord(begin: OpId) i64 {
    return @bitCast((@as(u64, begin.actor) << 32) | @as(u64, begin.counter));
}

/// The same word negated: what an `End` row occupies (`mark_index.rs:31-33`).
fn endWord(begin: OpId) i64 {
    return -%startWord(begin);
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
            .start => |s| startWord(s.id),
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
    /// frees the two sets `rhs` names. `addAssignRef` is the form that borrows.
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
    /// the other set is restored. `rhs` is consumed, as above.
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
    acc: MarkAcc,
    /// Which open mark the next `next` returns.
    index: usize = 0,
    /// When set, only the marks the clock covers are yielded
    /// (`mark_index.rs:328`).
    clock: ?Clock,

    pub fn deinit(self: *MarkIter) void {
        self.acc.deinit();
        self.* = undefined;
    }

    /// The next open mark the clock covers, or null at the end.
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
/// `gpa` is the allocator both the column and the cache were built with, and
/// every entry point that allocates takes that same one: the column frees its
/// own slabs with it (`hexane/column.zig:1671-1674`).
pub const MarkIndexColumn = struct {
    gpa: Allocator,
    /// The rows. Upstream's is a `PrefixColumn<Option<MarkIdx>>`; the module
    /// comment gives why the port's holds the word and folds its own prefix.
    data: DataColumn,
    /// The `MarkData` of every live mark-begin op (`mark_index.rs:216`,
    /// `:277-286`). This is what `hasAnyMarks` and `markData` read
    /// (`:261-269`).
    cache: std.AutoHashMapUnmanaged(OpId, MarkData),

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
    pub fn init(gpa: Allocator) ParseError!MarkIndexColumn {
        return .{ .gpa = gpa, .data = try DataColumn.init(gpa), .cache = .empty };
    }

    /// Frees the column and the cache. Upstream frees both by dropping them
    /// (`:213-217`); the port has to be told, and the allocator is the one
    /// `init` was given.
    pub fn deinit(self: *MarkIndexColumn) void {
        self.data.deinit();
        self.cache.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many rows the index has, which is the op set's row count
    /// (`mark_index.rs:248-250`).
    pub fn len(self: *const MarkIndexColumn) usize {
        return self.data.len();
    }

    /// A cursor over every row, in order (`mark_index.rs:252-254`).
    pub fn iter(self: *const MarkIndexColumn) ParseError!ValueIter {
        return .{ .inner = try self.data.iterator() };
    }

    /// A cursor over the rows in `range`, clamped to the column
    /// (`mark_index.rs:256-260`).
    pub fn iterRange(self: *const MarkIndexColumn, range: column.RowRange) ParseError!ValueIter {
        return .{ .inner = try self.data.iterRange(range) };
    }

    /// Whether any mark exists anywhere in the document: the cache holds the
    /// `MarkData` of every live mark-begin op (`mark_index.rs:261-265`).
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
    pub fn rewriteWithNewActor(self: *MarkIndexColumn, gpa: Allocator, idx: ActorIdx) ParseError!void {
        return self.remapValues(gpa, idx);
    }

    /// Rebuilds the data column with every row's actor index shifted, and the
    /// cache re-keyed to match (`mark_index.rs:280-289` plus the cache half of
    /// `:271-278`).
    ///
    /// Both halves have to move. A remap that moved only the rows would leave
    /// the cache keyed by the old actor table, and `markData` would then answer
    /// null for every mark in the document.
    ///
    /// Upstream keeps these in two functions because its worker is a closure
    /// over `MarkIdx` — `remap_values(f: impl Fn(MarkIdx) -> MarkIdx)` — and a
    /// closure over a row cannot be applied to the cache's `OpId` keys. The
    /// port's worker is a comptime function over `ActorIdx` and `MarkIdx`
    /// (`hexane/column.zig:2356-2361`) for the same reason a closure is not
    /// available, so the split buys nothing here and the halves travel
    /// together: a caller cannot get one without the other.
    ///
    /// The rebuild is run-at-a-time (`hexane/column.zig:2362-2386`), so an index
    /// over a document with no marks at all costs a handful of null-run headers
    /// rather than a row apiece.
    pub fn remapValues(self: *MarkIndexColumn, gpa: Allocator, idx: ActorIdx) ParseError!void {
        try self.data.remap(gpa, idx, remapWord);

        // `OpId::with_new_actor` is a shift, not a fold, so two keys never land
        // on one (`types.rs:447-453`) and the fresh map cannot lose an entry to
        // a collision. It is built before the old one is torn down, so an
        // allocation failure leaves the cache as it was.
        var fresh: std.AutoHashMapUnmanaged(OpId, MarkData) = .empty;
        errdefer fresh.deinit(gpa);
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            try fresh.put(gpa, kv.key_ptr.*.withNewActor(idx), kv.value_ptr.*);
        }
        self.cache.deinit(gpa);
        self.cache = fresh;
    }

    /// Inserts `values` before row `index` (`mark_index.rs:277-289`).
    ///
    /// A `Start` puts its `MarkData` in the cache as it is mapped, before the
    /// column is written (`mark_index.rs:280-284`). The cache goes first on
    /// purpose: an entry with no row is invisible to every reader here, because
    /// they all reach the cache *through* the rows, while a row with no entry is
    /// not, and `richTextAt` has to answer for every mark it yields.
    ///
    /// The `MarkData` kept is the one handed in, name and all, and `MarkData`'s
    /// name is borrowed (`op_set2/types.rs:56-60`, and the rule `marks.zig:133-136`
    /// states for `Mark`). So the name must outlive this index: upstream gets
    /// that for free because its `MarkData<'static>` owns a `String`
    /// (`op_set2/op.rs:75-79`), and a port caller has to hand in a name that
    /// lives as long as the op set — the document's own interned string, not a
    /// name borrowed out of the change being applied.
    ///
    /// Upstream's parameter is a `Vec` it consumes; a slice is the port's
    /// spelling.
    pub fn extend(
        self: *MarkIndexColumn,
        gpa: Allocator,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!void {
        const words = try gpa.alloc(Word, values.len);
        defer gpa.free(words);
        for (values, 0..) |value, i| {
            if (value) |v| switch (v) {
                .start => |s| try self.cache.put(gpa, s.id, s.data),
                .end => {},
            };
            words[i] = if (value) |v| v.word() else null;
        }
        try self.data.splice(gpa, index, 0, words);
    }

    /// Removes the `values.len` rows at `index` and forgets the marks that
    /// began there (`mark_index.rs:291-300`).
    ///
    /// Upstream prunes the cache and then splices (`:292-299`); here the splice
    /// goes first, so a splice the column refuses — `error.InvalidValue` for an
    /// out-of-range range (`hexane/column.zig:2409`) — leaves the cache alone
    /// instead of dropping the `MarkData` of a row that is still there. The
    /// success path is the same either way.
    pub fn undo(
        self: *MarkIndexColumn,
        gpa: Allocator,
        index: usize,
        values: []const ?MarkIndexBuilder,
    ) ParseError!void {
        try self.data.splice(gpa, index, values.len, &.{});
        for (values) |maybe| {
            const value = maybe orelse continue;
            switch (value) {
                .start => |s| {
                    _ = self.cache.remove(s.id);
                },
                .end => {},
            }
        }
    }

    /// The prefix aggregate over the rows `0..=target` (`mark_index.rs:315-318`,
    /// upstream's `PrefixColumn::get_total` at `hexane/src/prefix.rs:550-555`).
    ///
    /// `target` at or past the end folds every row, which is what upstream's
    /// `get_prefix` does through `iter_range`'s clamp (`prefix.rs:543-548`,
    /// `:670-671`). A run folds as one delta; the module comment says why that
    /// is the whole rule. The caller owns the result and frees it with
    /// `deinit`.
    pub fn total(self: *const MarkIndexColumn, gpa: Allocator, target: usize) ParseError!MarkAcc {
        var acc = MarkAcc.init(gpa);
        errdefer acc.deinit();
        if (self.data.len() == 0) return acc;
        const end = if (target >= self.data.len()) self.data.len() else target + 1;
        var it = try self.head(end);
        while (try it.nextRun()) |run| {
            if (run.value) |mark| try acc.applyOne(mark);
        }
        return acc;
    }

    /// A cursor over the rows `[0, end)`, which is what a prefix fold over
    /// this column is: the head of the column with its window closed at `end`.
    fn head(self: *const MarkIndexColumn, end: usize) ParseError!ValueIter {
        var inner = try self.data.iterator();
        inner.setMax(end);
        return .{ .inner = inner };
    }

    /// The mark ids open at `target` (`mark_index.rs:315-331`). The caller owns
    /// the result and frees it with `deinit`.
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
    /// (`mark_index.rs:302-313`). The caller owns the result and frees it with
    /// `deinit`.
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

/// `Column::remap`'s row function: an actor index at or above `idx` shifts up
/// (`mark_index.rs:51-58`). A null row stays null.
fn remapWord(idx: ActorIdx, word: Word) Word {
    const m = decodeWord(word) orelse return null;
    return m.withNewActor(idx).asI64();
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
    try col.extend(gpa, 0, values);
    return col;
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
    try col.extend(gpa, 0, values);
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
    // upstream's property too (`mark_index.rs:25-34`; noted at
    // `docs/survey/02-transaction-opset.md:1155`). Pinned because the word is
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

    try col.undo(gpa, bold_rows[1], &[_]?MarkIndexBuilder{.{ .end = bold }});
    try col.undo(gpa, bold_rows[0], &[_]?MarkIndexBuilder{.{
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
    try col.undo(gpa, b_rows[1], &[_]?MarkIndexBuilder{.{ .end = b }});
    try col.undo(gpa, b_rows[0], &[_]?MarkIndexBuilder{.{
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
        try col.undo(gpa, rows[1], &[_]?MarkIndexBuilder{.{ .end = step.mark }});
        try col.undo(gpa, rows[0], &[_]?MarkIndexBuilder{.{
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
            try col.extend(gpa, at, &added);
            try col.undo(gpa, at, &added);

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
    try col.remapValues(gpa, 1);

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
        try col.undo(gpa, rows[1], &[_]?MarkIndexBuilder{.{ .end = mark.id }});
        try col.undo(gpa, rows[0], &[_]?MarkIndexBuilder{.{
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
