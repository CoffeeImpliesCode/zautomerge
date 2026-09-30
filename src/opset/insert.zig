//! The sequence insertion-point resolver: where a new row goes, what it hangs
//! by, and what marks it carries
//! (`rust/automerge/src/op_set2/op_set/insert.rs`, 191 lines, plus the
//! `QueryNth` it answers, which upstream declares at
//! `op_set2/op_set.rs:1441-1446`).
//!
//! This is what a local insert goes through. `OpSet::query_insert_at`
//! (`op_set2/op_set.rs:569-609`) hands a target index to
//! [`InsertQuery.resolve`], and the answer is where the new row is spliced,
//! which element it is anchored to, and which marks the inserted text carries.
//! A write that got any of the three wrong produces a document that either
//! renders in the wrong place or fails the row-order invariant on the next
//! load, which is why the third of them — the anchor — is the load-bearing one
//! and is what the tests below pin hardest.
//!
//! # The three answers, and which of them is the row-order invariant
//!
//! [`QueryNth`] is `pos`, `elemid`, `index` and `marks`
//! (`op_set2/op_set.rs:1441-1446`):
//!
//! * `pos` — the row the new row is spliced at, so every row at or after it
//!   moves down one.
//! * `elemid` — the element the new row is **anchored to**, which is
//!   `Op.elemidOrKey` of the new row once it exists and therefore the register
//!   the whole op-set has to stay ordered around. Rule R4 of the row-order
//!   invariant says an insert opening a new register is legal iff it is
//!   anchored to the element the previous row belongs to, or its own id sorts
//!   before that element (`op.zig:2081-2086`, `op_set2/op.rs:1061-1063`), and
//!   `resolve` picks the anchor so that whichever arm applies is the one that
//!   holds. **This is the answer that has to be right.**
//! * `index` — the sequence index the resolver reached, which is how the fast
//!   path's prefix advance and the general walk agree
//!   (`op_set2/op_set.rs:584-596` `debug_assert_eq!`s the two).
//! * `marks` — the marks open at `pos`, which the transaction writes onto the
//!   inserted text (`transaction/inner.rs:995`, and the `finalize_op` call at
//!   `transaction/inner.rs:376-403`).
//!
//! # The sticky-mark rule
//!
//! **A mark that begins before the insertion point and ends after it must
//! stick, or text edits land outside their marks.** The rule is a list of
//! candidate positions, built while the walk is past the target and popped at
//! the end (`insert.rs:62-87`, `:138-150`):
//!
//! 1. The first insert seen after the target, anchored at the last visible
//!    element before it (`insert.rs:64-68`). This is the plain answer.
//! 2. A mark **begin** whose `expand` is set, at `op.pos + 1`
//!    (`insert.rs:80-85`, the `MarkBegin(true, _)` arm). The mark reaches
//!    backwards over the insertion point, so the point moves to just after the
//!    begin and the inserted text lands inside the mark.
//! 3. A mark **end** whose `expand` is *not* set, at `op.pos + 1` (the
//!    `MarkEnd(false)` arm). The mark does not reach forwards, so the point
//!    moves to just after the end and the inserted text lands outside it.
//!
//! And one correction, which is what makes the list a list rather than a
//! maximum (`insert.rs:73-79`): when a mark **end** is reached and a candidate
//! was pushed by that mark's own **begin**, the candidates from that begin
//! onwards are dropped. A point between a mark's begin and its end is invalid
//! — there is nowhere in the op set to put a row that is inside a mark's span
//! but not inside its text — so the begin's candidate must go, and so must
//! anything that was queued behind it.
//!
//! Read as three cases, which is how the tests are named:
//!
//! | where the mark is | the mark set at the answer | the point moves |
//! |---|---|---|
//! | entirely **before** the point | the mark is closed, so it is absent | yes, to just after the mark's end (rule 3) |
//! | **spanning** the point | the mark is open, so it is carried | no, unless the end is non-expanding |
//! | entirely **after** the point | the mark has not opened, so it is absent | the begin's candidate is dropped (the correction) |
//!
//! Upstream states the same rule a second time for the text fast path, in
//! `scan_for_sticky_marks` (`op_set2/op_set.rs:494-544`), and the two are
//! cross-checked against each other by a `debug_assert_eq!`
//! (`op_set2/op_set.rs:584-596`): `plan.md` §2 keeps `slow_path_assertions`,
//! so the port keeps both.
//!
//! # Non-visible rows are read too
//!
//! The walk here is the one place in the op set that must see invisible rows
//! as well as visible ones (`insert.rs:89-90`, and the `index.top`-free walk it
//! implies). It counts widths over the rows the clock *covers* and consults
//! invisible rows only for the sticky-mark scan, which is why `pos` is advanced
//! by every row and `last_visible_cursor` only by the visible ones
//! (`insert.rs:112-127`).
//!
//! # `resolve` is called once, and a resolver cannot be re-asked
//!
//! `resolve` takes `&mut self`, and in Zig that looks re-enterable. It is not:
//! it consumes the walk, it accumulates into the mark state, and it leaves the
//! candidate list holding whatever survived. A second call would start from a
//! spent walk with a half-folded mark state, and the mark fold cannot be
//! un-folded — [`MarkStateMachine`](../../src/marks.zig) has no inverse, and
//! adding one would be inventing behaviour upstream does not have.
//!
//! Upstream's shape is the same: `resolve` is `&mut self`
//! (`insert.rs:92`) and every call site constructs a query and calls it once
//! (`op_set.rs:558-567`, `:584-608`). So **one `InsertQuery` answers one
//! target**, and a caller that wants a second target constructs a second one.
//! The `Shiftable` forwards below exist for repositioning the *walk* — the next
//! agent that slices a resolver is expected to reset the rest — and the note on
//! [`InsertQuery.advanceTo`] says what a caller must not do with them.
//!
//! The general form and the fast paths are two calls with different `index`
//! arguments into the *same* query type, and a `debug_assert_eq!` between them
//! is what keeps them to one answer (`op_set2/op_set.rs:584-596`,
//! `plan.md` §2 keeps `slow_path_assertions`).

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const marksmod = @import("../marks.zig");
const markidx = @import("mark_index.zig");
const opmod = @import("op.zig");
const opcols = @import("columns.zig");
const opiter = @import("op_iter.zig");
const oquery = @import("op_query.zig");
const value = @import("../value.zig");

const Allocator = std.mem.Allocator;
const Clock = clockmod.Clock;
const ElemId = types.ElemId;
const Error = err.Error;
const MarkSet = marksmod.MarkSet;
const MarkStateMachine = marksmod.MarkStateMachine;
const ObjId = types.ExId;
const Op = opmod.Op;
const OpBuilder = opmod.OpBuilder;
const OpId = types.OpId;
const OpStepper = opmod.OpStepper;
const ParseError = err.ParseError;
const ReadOpError = opiter.ReadOpError;
const RowRange = column.RowRange;
const SequenceType = types.SequenceType;
const StringTable = opcols.StringTable;
const SuccEntry = opmod.SuccEntry;
const TextEncoding = types.TextEncoding;

const opmarks = @import("marks.zig");

const testing = std.testing;

/// What [`InsertQuery.resolve`] can raise. Upstream's is
/// `Result<QueryNth, AutomergeError>` (`insert.rs:92`), and the walk inside it
/// can raise the column layer's `ReadOpError` as well; Zig has no
/// `From<ReadOpError> for AutomergeError` to make that invisible, so both sets
/// are named here. `ParseError` is a member of `ReadOpError`, and neither is a
/// member of `Error`, so the union is genuinely three sets' worth — the same
/// union `op_query.zig` declares for a query term's `next`, and for the same
/// reason.
pub const ResolveError = Error || ReadOpError;

// ── Loc ────────────────────────────────────────────────────────────────────

/// One candidate position, and the element a row placed there would hang by
/// (`Loc`, `insert.rs:164-169`).
///
/// `id` is set only for a candidate a **mark** row pushed, and it is the *end*
/// row's own id. That is what lets the correction at `insert.rs:73-79` find
/// the candidate a given mark end invalidates: a mark's end is the operation
/// immediately after its begin (`src/marks.zig:93-107`), so
/// `end.id.prev()` is the begin's id, and `matches` is the identity test
/// between the two (`insert.rs:188-190`).
pub const Loc = struct {
    /// The element a row placed here would be anchored to
    /// (`insert.rs:166`).
    cursor: ElemId,
    /// The row a row placed here would be spliced at (`insert.rs:167`).
    pos: usize,
    /// The mark end row that pushed this candidate, or null
    /// (`insert.rs:168`).
    id: ?OpId,

    /// A candidate no mark pushed (`Loc::new`, `insert.rs:172-178`).
    pub fn new(pos: usize, cursor: ElemId) Loc {
        return .{ .cursor = cursor, .pos = pos, .id = null };
    }

    /// A candidate a mark row pushed (`Loc::mark`, `insert.rs:180-186`).
    pub fn mark(pos: usize, cursor: ElemId, id: OpId) Loc {
        return .{ .cursor = cursor, .pos = pos, .id = id };
    }

    /// Whether this candidate is the one `op` — a mark **end** — invalidates
    /// (`matches`, `insert.rs:188-190`).
    ///
    /// Only ever true for a candidate a mark row pushed, because only those
    /// carry an `id`, and only ever for a `MarkEnd` row. That is what confines
    /// the correction at `insert.rs:73-79` to a begin/end pair and leaves a
    /// plain candidate alone.
    pub fn matches(self: Loc, op: *const Op) bool {
        const mine = self.id orelse return false;
        return mine.eql(op.id().prev());
    }
};

// ── QueryNth ───────────────────────────────────────────────────────────────

/// Where a new row goes, what it hangs by, and what marks it carries
/// (`QueryNth`, `op_set2/op_set.rs:1441-1446`).
///
/// `marks` is owned, because the port's [`MarkSet`] is owned rather than
/// reference counted (`src/marks.zig:484-492` says why) and
/// `MarkSet::from_query_state` builds a fresh one rather than handing back a
/// shared one (`src/marks.zig:165-178`). `deinit` gives it back.
pub const QueryNth = struct {
    /// The marks open at `pos`, or null when nothing is marked there.
    marks: ?MarkSet,
    /// The row to splice the new row at.
    pos: usize,
    /// The sequence index the walk reached, which is the `index` the fast path
    /// computed by prefix advance.
    index: usize,
    /// The element the new row is anchored to. **The row-order invariant's
    /// load-bearing answer** — see the module documentation.
    elemid: ElemId,

    /// Frees `marks` and nothing else.
    pub fn deinit(self: *QueryNth, gpa: Allocator) void {
        _ = gpa;
        if (self.marks) |*set| set.deinit();
        self.* = undefined;
    }
};

// ── RichTextQueryState ─────────────────────────────────────────────────────

/// The marks open at a point, keyed by the **begin** operation's id
/// (`RichTextQueryState`, `src/marks.rs:402-432`).
///
/// This is upstream's `map` field and nothing else: its `block` field is set
/// only by its own `process` and read by no path in the op set
/// (`mark_index.zig:412-419` says the same), so a consumer that needs the
/// block carries it. The map itself is [`markidx.OpenMarks`], which is the type
/// `MarkIndexColumn` already publishes for exactly this pair, so it is used
/// rather than declared a second time.
pub const RichTextQueryState = struct {
    /// The allocator the map's buckets belong to.
    gpa: Allocator,
    /// The marks open here, keyed by the begin operation's own id
    /// (`src/marks.rs:404`).
    map: markidx.OpenMarks = .empty,
    /// The id of the last map-making op seen (`src/marks.rs:405`).
    block: ?OpId = null,

    /// An empty state. Allocates nothing: the map is an empty
    /// `AutoHashMapUnmanaged`.
    pub fn init(gpa: Allocator) RichTextQueryState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RichTextQueryState) void {
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    /// Folds one row in (`process`, `src/marks.rs:409-427`).
    ///
    /// A row the clock does not cover is ignored outright
    /// (`src/marks.rs:410-414`), which is why this is called with a `null`
    /// clock from [`InsertQuery.resolve`]: the walk has already decided what is
    /// visible, and this is told nothing more. The mark arms are the whole of
    /// the state — a begin inserts, an end removes at `id.prev()`
    /// (`src/marks.rs:416-421`) — and a map-making row records the block
    /// (`src/marks.rs:422-424`), which no path in the op set reads.
    ///
    /// The `OpType` is assembled from the columns rather than taken from a
    /// field, which is upstream's `Op::action()` spelled the port's way
    /// (`value.opTypeFromActionAndValue`, from `op_set2/types.rs:158-189`).
    pub fn process(self: *RichTextQueryState, op: Op, c: ?Clock) ResolveError!void {
        if (c) |cover| {
            // `clock.map(|c| c.covers(&op.id)).unwrap_or(true)` upstream
            // (`src/marks.rs:410`); `Clock.contains` is the port's `covers`
            // for an op id (`clock.zig:104-109`).
            if (!cover.contains(op.id())) return;
        }
        const kind = try value.opTypeFromActionAndValue(op.action(), op.value(), op.markName(), op.expand());
        switch (kind) {
            .mark_begin => |begin| {
                try self.map.put(self.gpa, op.id(), .{ .name = begin.name, .value = begin.value });
            },
            .mark_end => {
                // `self.map.remove(&op.id.prev())` (`src/marks.rs:420`).
                _ = self.map.remove(op.id().prev());
            },
            .make => |o| {
                if (o == .map) self.block = op.id();
            },
            else => {},
        }
    }

    /// The marks open here, in ascending op-id order. The sort is the one
    /// deviation from upstream and it is deliberate: upstream iterates a
    /// `SmallHashMap` (`src/marks.rs:429-431`), so the order it feeds
    /// `MarkStateMachine::mark_begin` is a hash order, and the fold's answer
    /// then depends on it. The port orders by op id — the document's own order
    /// (`src/types.zig:163-170`) — for the reason `mark_index.zig:73-80` gives:
    /// a sorted iteration order is what lets every test be an exact comparison.
    /// It is a behaviour difference only for a document whose marks are in
    /// conflict at one position, where upstream's answer is not defined.
    fn sortedIds(self: *const RichTextQueryState, gpa: Allocator) ResolveError![]OpId {
        const ids = try gpa.alloc(OpId, self.map.count());
        errdefer gpa.free(ids);
        var it = self.map.keyIterator();
        var n: usize = 0;
        while (it.next()) |id| {
            ids[n] = id.*;
            n += 1;
        }
        std.mem.sort(OpId, ids, {}, struct {
            fn less(_: void, a: OpId, b: OpId) bool {
                return a.order(b) == .lt;
            }
        }.less);
        return ids;
    }
};

/// The mark set at a query state (`MarkSet::from_query_state`,
/// `src/marks.rs:165-178`).
///
/// The state is a set of *open* marks, not a set of values, so it is folded
/// through a [`MarkStateMachine`](../../src/marks.zig) rather than read
/// directly: that is where a same-name mark above shadows one below, and where
/// a mark that resolves to `Null` is recognised as an unmark tombstone
/// (`src/marks.rs:170-171`). Upstream's `marks.current()?` returns a `null` when
/// the machine has resolved nothing at all, and the `without_unmarks` after it
/// drops the tombstones — so **a query state whose only marks are unmarks
/// answers `null`**, and that is the case a test should reach for rather than
/// an empty set.
pub fn markSetFromQueryState(gpa: Allocator, q: *const RichTextQueryState) ResolveError!?MarkSet {
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    const ids = try q.sortedIds(gpa);
    defer gpa.free(ids);
    for (ids) |id| {
        const data = q.map.get(id) orelse continue;
        _ = try machine.markBegin(id, data);
    }

    // `marks.current()?` (`src/marks.rs:172`): a machine that has resolved
    // nothing has no set to clone.
    const current = machine.current() orelse return null;
    var copy = try MarkSet.fromPairs(gpa, current.entries.items);
    errdefer copy.deinit();
    // `without_unmarks` consumes and frees its receiver
    // (`src/marks.zig:397-413`), so the copy is handed over rather than
    // deinit'd afterwards.
    const out = try copy.withoutUnmarks();
    if (out.isEmpty()) {
        var empty = out;
        empty.deinit();
        return null;
    }
    return out;
}

// ── InsertQuery ────────────────────────────────────────────────────────────

/// The insertion-point resolver for one sequence (`InsertQuery`,
/// `insert.rs:12-22`).
///
/// Generic over the op type `O` so that the walk it holds is
/// `op_iter.OpIter(O)`, the port's split of the `OpLike` trait
/// (`op.zig:34-52`). It is not itself an iterator: upstream's is not either
/// (`insert.rs:92` walks `self.iter` by hand), it answers one question about
/// one target.
pub fn InsertQuery(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The column set the walk's sub-iterators read (`OpIter::Ops`).
        pub const Ops = opcols.Columns(O);

        /// The allocator the candidate list, the mark list and the mark set all
        /// belong to. It is named here so [`deinit`] can be called with
        /// nothing.
        gpa: Allocator,
        /// The walk over the sequence's rows (`insert.rs:14`).
        iter: opiter.OpIter(O),
        /// The marks open at the point being resolved (`insert.rs:15`).
        marks: RichTextQueryState,
        /// Whether the sequence is a list or text, which decides a row's width
        /// (`insert.rs:16`).
        seq_type: SequenceType,
        /// How text is measured (`insert.rs:17`).
        text_encoding: TextEncoding,
        /// The clock, or null for the document's current state
        /// (`insert.rs:18`).
        clock: ?Clock,
        /// The `target == 0` candidate, held by value.
        ///
        /// Upstream pushes it at construction (`insert.rs:35-37`), which is an
        /// allocation; this keeps it in a field so that constructing a query
        /// costs nothing, and [`candidateCount`] counts it as the first
        /// candidate exactly as upstream's `Vec` would.
        head: ?Loc,
        /// The sticky-mark candidates, oldest first (`insert.rs:19`).
        candidates: std.ArrayList(Loc) = .empty,
        /// The visible mark rows seen after the target, replayed once the
        /// answer's position is known (`insert.rs:96`, `:140-144`).
        post_marks: std.ArrayList(Op) = .empty,
        /// The element the last visible non-mark row hangs by
        /// (`insert.rs:20`).
        last_visible_cursor: ?ElemId = null,
        /// The index being resolved (`insert.rs:21`).
        target: usize,

        pub const shiftable = column.Shiftable(Self);

        /// A resolver for `target` over `iter` (`InsertQuery::new`,
        /// `insert.rs:25-48`).
        ///
        /// `index` is the general form's `0` and the fast path's
        /// `index - 1` (`op_set2/op_set.rs:566`, `:594`): it is how much of
        /// the target the walk has already accounted for, and the fast path has
        /// already accounted for the width of everything before its prefix
        /// position. The `debug_assert_eq!` at `op_set2/op_set.rs:584-596` is
        /// what holds the two forms to the same answer.
        ///
        /// Allocates nothing — see the module documentation's last section.
        pub fn init(
            gpa: Allocator,
            iter: opiter.OpIter(O),
            target: usize,
            seq_type: SequenceType,
            text_encoding: TextEncoding,
            c: ?Clock,
            marks: RichTextQueryState,
        ) Self {
            return .{
                .gpa = gpa,
                .iter = iter,
                .marks = marks,
                .seq_type = seq_type,
                .text_encoding = text_encoding,
                .clock = c,
                // `insert.rs:35-37`: an insert at index zero is anchored at the
                // head of the sequence, and the row it lands at is the first
                // row of the walk.
                .head = if (target == 0) Loc.new(iter.pos(), ElemId.head()) else null,
                .target = target,
            };
        }

        /// Frees the candidate list, the mark list and the mark state, and
        /// nothing else: the walk is a value the caller built and owns.
        pub fn deinit(self: *Self) void {
            self.candidates.deinit(self.gpa);
            self.post_marks.deinit(self.gpa);
            self.marks.deinit();
            self.* = undefined;
        }

        /// How many candidates there are, `head` included. Upstream's
        /// `self.candidates.len()` and `self.candidates.is_empty()`
        /// (`insert.rs:64`, `:71`) both mean this.
        fn candidateCount(self: *const Self) usize {
            return self.candidates.items.len + self.headCount();
        }

        /// Whether the `target == 0` candidate is present. It is the first
        /// candidate when it is, so the index arithmetic below is the same as a
        /// list that had been pushed into.
        fn headCount(self: *const Self) usize {
            return if (self.head != null) 1 else 0;
        }

        /// The candidate at `i`, counting `head` as index 0.
        fn candidateAt(self: *const Self, i: usize) Loc {
            if (i < self.headCount()) return self.head.?;
            return self.candidates.items[i - self.headCount()];
        }

        /// The last candidate, which is the one the answer uses
        /// (`self.candidates.pop()`, `insert.rs:138`).
        fn popCandidate(self: *Self) ?Loc {
            if (self.candidates.items.len > 0) return self.candidates.pop();
            const h = self.head orelse return null;
            self.head = null;
            return h;
        }

        /// Drops the candidates from index `n` onwards (`self.candidates
        /// .truncate(pos)`, `insert.rs:76`).
        fn truncateCandidates(self: *Self, n: usize) void {
            const heads = self.headCount();
            if (n < heads) {
                self.head = null;
                self.candidates.clearRetainingCapacity();
                return;
            }
            self.candidates.shrinkRetainingCapacity(n - heads);
        }

        /// Records the positions a row past the target makes valid
        /// (`identify_valid_insertion_spot`, `insert.rs:62-87`).
        ///
        /// The three rules are the module documentation's; the correction is
        /// the `truncate` at `insert.rs:73-79`, and it `return`s rather than
        /// falling through, so a mark end that matched contributes no candidate
        /// of its own.
        fn identifyValidInsertionSpot(self: *Self, op: Op, cursor: ElemId) Allocator.Error!void {
            // The first insert after the target, anchored at the last visible
            // element before it (`insert.rs:64-68`).
            if (op.insert() and self.candidateCount() == 0) {
                if (self.last_visible_cursor) |c| {
                    try self.candidates.append(self.gpa, Loc.new(op.pos, c));
                }
            }
            if (self.candidateCount() == 0) return;

            // A mark end whose own begin queued a candidate invalidates it and
            // everything behind it: a point between a mark's begin and its end
            // is nowhere in the op set (`insert.rs:71-79`).
            if (op.isMark() and op.markName() == null) {
                var i: usize = 0;
                const total = self.candidateCount();
                while (i < total) : (i += 1) {
                    if (self.candidateAt(i).matches(&op)) {
                        self.truncateCandidates(i);
                        return;
                    }
                }
            }

            // A begin that expands backwards, or an end that does not expand
            // forwards, makes a point just after itself valid
            // (`insert.rs:80-85`). Which of the two a mark row is comes from
            // the name column alone (`op_set2/types.rs:177-186`).
            if (op.isMark()) {
                const expands = op.expand();
                const begin = op.markName() != null;
                if (begin == expands) {
                    try self.candidates.append(self.gpa, Loc.mark(op.pos + 1, cursor, op.id()));
                }
            }
        }

        /// Where a new row goes, what it hangs by and what marks it carries
        /// (`resolve`, `insert.rs:92-161`).
        ///
        /// `index` is how much of the target the caller has already accounted
        /// for — see [`init`]. `error.InvalidIndex` when the walk ran out
        /// before reaching the target (`insert.rs:136-137`, `:158-159`), which
        /// is the only way a caller learns the index was past the end of a
        /// sequence.
        pub fn resolve(self: *Self, index_in: usize) ResolveError!QueryNth {
            var index = index_in;
            var last_width: ?i64 = null;
            var done = index >= self.target;
            var at = self.iter.pos();
            self.post_marks.clearRetainingCapacity();

            while (try self.iter.next()) |row| {
                var op = row;
                const op_pos = op.pos;
                // An increment is not a value and contributes no width; it only
                // moves the position (`insert.rs:99-102`).
                if (op.isInc()) {
                    at = op_pos;
                    continue;
                }
                const visible = op.scopeToClock(self.clock); // :103

                // This is the one place that needs non-visible rows: the
                // accumulated index is the position in the *sequence*, so it
                // advances on every insert, whether or not the row is visible
                // (`insert.rs:104-110`).
                if (op.insert()) {
                    if (last_width) |w| {
                        index += widthOf(w);
                        done = index >= self.target;
                        last_width = null;
                    }
                }

                const cursor = try op.cursor(); // :111

                if (done) {
                    try self.identifyValidInsertionSpot(op, cursor);
                    if (visible) {
                        if (op.action() == .mark) {
                            // Held back rather than folded: whether it is inside
                            // the answer's position is not known until the
                            // candidates are popped (`insert.rs:115-116`).
                            try self.post_marks.append(self.gpa, op);
                        } else if (self.candidateCount() > 0) {
                            break; // :118
                        }
                    }
                } else if (visible) {
                    if (!op.isMark()) {
                        self.last_visible_cursor = cursor;
                        last_width = op.width(self.seq_type, self.text_encoding);
                    }
                    // Only the rows *before* the target are folded here; the
                    // ones after it are `post_marks` (`insert.rs:121-127`).
                    try self.marks.process(op, null);
                }
                at = op_pos; // :128
            }

            if (last_width) |w| {
                index += widthOf(w);
                done = index >= self.target;
            }

            if (!done) return error.InvalidIndex; // :136-137

            if (self.popCandidate()) |loc| {
                // Replay the mark rows the answer's position left behind
                // (`insert.rs:140-144`): a mark ending at or after the point is
                // not yet closed there.
                for (self.post_marks.items) |op| {
                    if (op.pos < loc.pos) try self.marks.process(op, null);
                }
                return .{
                    .marks = try markSetFromQueryState(self.gpa, &self.marks),
                    .pos = loc.pos,
                    .elemid = loc.cursor,
                    .index = index,
                };
            }
            // Past the end of the walk, the answer is one past the last row and
            // anchored at the last visible element (`insert.rs:151-157`).
            if (self.last_visible_cursor) |cursor| {
                return .{
                    .marks = try markSetFromQueryState(self.gpa, &self.marks),
                    .pos = at + 1,
                    .elemid = cursor,
                    .index = index,
                };
            }
            // A sequence with no visible element at all, and no candidate: there
            // is nowhere to insert (`insert.rs:158-159`).
            return error.InvalidIndex;
        }

        /// The row the walk is standing on (`column.zig:4000`).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// One past the last row the walk can yield (`column.zig:4001`).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the walk at `at` (`OpIter.setMax`).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances the walk so the next row it would read is `target`
        /// (`OpIter.advanceTo`).
        ///
        /// A resolver that has already been asked to `resolve` has consumed its
        /// walk and folded its marks, so a caller that repositions and asks
        /// again gets the answer for the new window from a state that was
        /// folded over the old one. There is no way to un-fold it, and upstream
        /// has the same property: `resolve` is `&mut self` and is called once.
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows (`OpIter.advanceBy`).
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the walk's window to `rows` — the window only, not the
        /// position (`OpIter.shift`).
        pub fn shift(self: *Self, rows: RowRange) void {
            self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the row at its start
        /// (`OpIter.shiftNext`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?Op {
            return self.iter.shiftNext(rows);
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk (`OpIter.seekTo`).
        pub fn seekTo(self: *Self, at: usize) ReadOpError!?Op {
            return self.iter.seekTo(at);
        }
    };
}

/// A row's width as a `usize`. A width is one, a text element's width under
/// its encoding, or zero for a mark (`op.zig:1817-1822`), so it is never
/// negative and the assertion documents that rather than papering over it.
fn widthOf(w: i64) usize {
    std.debug.assert(w >= 0);
    return @intCast(w);
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, which is what makes an interned id stable.
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

    fn intern(ctx: *const anyopaque, bytes: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, bytes)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, bytes));
        return id;
    }
};

/// An allocator that counts what goes through it, so a test can assert that
/// constructing something asked for nothing (`op_iter.zig:1979-2026` is the
/// same shape, written for the same reason).
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

/// The text object the tests resolve against: `"ab"` with a mark named `bold`
/// over the `"b"`.
///
/// The rows are the ones a transaction produces, in its order
/// (`transaction/inner.rs:827-857`): the three text elements are ids 1..3, and
/// the mark's two operations are ids 4 and 5, back to back, because `mark`
/// builds nothing between them. The begin lands on the row the inserted
/// position names and the end on the row after the marked text
/// (`insert_mark_end_after` and the `end.pos > begin.pos` guard,
/// `transaction/inner.rs:830-866`), which is the row order below. `expand` is
/// the only thing `init` varies, and it is the one column the sticky-mark rule
/// reads — so the two fixtures differ in that column and nothing else.
const text_obj: ObjId = .{ .id = .{ .counter = 1, .actor = 0 } };
const a_elem: ElemId = ElemId.fromOpId(.{ .counter = 2, .actor = 0 });
const b_elem: ElemId = ElemId.fromOpId(.{ .counter = 3, .actor = 0 });

fn textRows(gpa: Allocator, expand: bool) !std.ArrayList(OpBuilder) {
    var ops: std.ArrayList(OpBuilder) = .empty;
    errdefer {
        for (ops.items) |*o| o.deinit(gpa);
        ops.deinit(gpa);
    }
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .make_text, .fromStr("t"), .null_value, false, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 2, .actor = 0 }, text_obj, .set, .fromElemId(ElemId.head()), .{ .str = "a" }, true, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 4, .actor = 0 }, text_obj, .mark, .fromElemId(a_elem), .{ .bool_value = true }, true, expand, "bold", &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 3, .actor = 0 }, text_obj, .set, .fromElemId(a_elem), .{ .str = "b" }, true, false, null, &.{}));
    try ops.append(gpa, try OpBuilder.init(gpa, .{ .counter = 5, .actor = 0 }, text_obj, .mark, .fromElemId(b_elem), .null_value, true, expand, null, &.{}));
    return ops;
}

/// A spliced op set plus the table its strings are interned in and a successor
/// buffer sized for it.
const Fixture = struct {
    gpa: Allocator,
    cols: opcols.Columns(OpBuilder),
    table: Table,
    succ: []SuccEntry,
    rows: usize,

    fn init(gpa: Allocator, expand: bool) !Fixture {
        var table = Table.init(gpa);
        errdefer table.deinit();
        var cols = try opcols.Columns(OpBuilder).init(gpa);
        errdefer cols.deinit();
        var ops = try textRows(gpa, expand);
        defer {
            for (ops.items) |*o| o.deinit(gpa);
            ops.deinit(gpa);
        }
        const written = try cols.splice(gpa, 0, ops.items, .unicode_code_point, table.asTable());
        return .{
            .gpa = gpa,
            .cols = cols,
            .table = table,
            .succ = try gpa.alloc(SuccEntry, try opiter.maxSuccCount(OpBuilder, &cols, .{ .start = 0, .end = written })),
            .rows = written,
        };
    }

    fn deinit(self: *Fixture) void {
        self.gpa.free(self.succ);
        self.table.deinit();
        self.cols.deinit();
        self.* = undefined;
    }

    /// A resolver for `target` over the object's rows, which are `1..rows`:
    /// row 0 is the `make_text` that made it.
    fn query(
        self: *Fixture,
        gpa: Allocator,
        target: usize,
        seq_type: SequenceType,
    ) !InsertQuery(OpBuilder) {
        const walk = try opiter.OpIter(OpBuilder).init(
            &self.cols,
            self.table.asTable(),
            .{ .start = 1, .end = self.rows },
            self.succ,
        );
        return InsertQuery(OpBuilder).init(
            gpa,
            walk,
            target,
            seq_type,
            .unicode_code_point,
            null,
            RichTextQueryState.init(gpa),
        );
    }
};

test "a mark spanning the insertion point sticks to it" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // Inserting between the `"a"` and the `"b"`, where the mark's begin is
    // exactly the insertion point. The mark expands backwards, so the point
    // moves to just after the begin and the inserted text lands inside the
    // mark, carrying it (`insert.rs:80-85`, the `MarkBegin(true, _)` arm).
    var q = try fix.query(gpa, 1, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), answer.pos);
    // The element is the mark *begin's* own id: the point moved to just after
    // the begin row, so the new row is anchored to the begin
    // (`insert.rs:84`).
    try testing.expect(answer.elemid.eql(ElemId.fromOpId(.{ .counter = 4, .actor = 0 })));
    try testing.expectEqual(@as(usize, 1), answer.index);
    // And the mark is open at the answer, which is what "sticks" means here.
    const set = answer.marks.?;
    try testing.expectEqual(@as(usize, 1), set.numMarks());
    var it = set.iter();
    try testing.expectEqualStrings("bold", it.next().?.name);
}

test "a mark entirely before the insertion point does not stick" {
    const gpa = testing.allocator;
    // The same rows with `expand` off: the mark reaches neither backwards nor
    // forwards.
    var fix = try Fixture.init(gpa, false);
    defer fix.deinit();

    // Resolving the end of the text, which is past the mark. The mark's end is
    // a `MarkEnd(false)`, so it queues a point just after itself
    // (`insert.rs:80-85`), the answer moves past the end, and the end is then
    // replayed (`insert.rs:140-144`) — which closes the mark. The point is
    // outside the mark, so the mark is not in the answer.
    var q = try fix.query(gpa, 2, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);

    try testing.expectEqual(@as(usize, 5), answer.pos);
    try testing.expect(answer.elemid.eql(ElemId.fromOpId(.{ .counter = 5, .actor = 0 })));
    try testing.expectEqual(@as(usize, 2), answer.index);
    try testing.expectEqual(@as(?*const MarkSet, null), if (answer.marks) |*m| m else null);
}

test "a mark that does not expand backwards leaves the point before it" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, false);
    defer fix.deinit();

    // The same rows, resolved between the `"a"` and the `"b"`. The mark's begin
    // does not expand backwards, so it queues no candidate of its own, and the
    // plain answer — the first insert after the target — stands: the point
    // lands on the begin's row, *before* the begin, so the mark is not yet
    // open there. This is the "entirely after the point, not yet open" case
    // (`insert.rs:64-68` against `:80-85`).
    var q = try fix.query(gpa, 1, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), answer.pos);
    try testing.expect(answer.elemid.eql(ElemId.fromOpId(.{ .counter = 2, .actor = 0 })));
    try testing.expectEqual(@as(usize, 1), answer.index);
    try testing.expect(answer.marks == null);
}

test "a mark entirely after the insertion point is not yet open" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // The very start of the text. The walk stops at the first row, which is
    // the `"a"`, so the mark's begin on row 2 is never reached at all: the
    // answer is the head candidate at the first row of the walk
    // (`insert.rs:35-37`, `:151-157`) and carries no mark.
    var q = try fix.query(gpa, 0, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), answer.pos);
    // The head: an insert at index zero anchors to the head of the sequence,
    // which is what the candidate was built with (`insert.rs:36`).
    try testing.expect(answer.elemid.isHead());
    try testing.expectEqual(@as(usize, 0), answer.index);
    try testing.expect(answer.marks == null);
}

test "a target past the end of the sequence is refused" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // Two text elements and a mark, so index 3 is one past the end. The walk
    // runs out with the target unreached and `resolve` says so
    // (`insert.rs:136-137`).
    var q = try fix.query(gpa, 3, .text);
    defer q.deinit();
    try testing.expectError(error.InvalidIndex, q.resolve(0));
}

test "an empty sequence has nowhere to insert past its head" {
    const gpa = testing.allocator;
    var cols = try opcols.Columns(OpBuilder).init(gpa);
    defer cols.deinit();
    var table = Table.init(gpa);
    defer table.deinit();
    const succ = try gpa.alloc(SuccEntry, 0);
    defer gpa.free(succ);

    // A `make_text` and nothing else: the object's range is empty. An insert
    // at index 0 is still answered — the head candidate does not need a row
    // (`insert.rs:35-37`) — and an insert at index 1 has nowhere to go, because
    // there is no visible element to anchor to and no candidate
    // (`insert.rs:158-159`).
    var make = try OpBuilder.init(gpa, .{ .counter = 1, .actor = 0 }, .root, .make_text, .fromStr("t"), .null_value, false, false, null, &.{});
    defer make.deinit(gpa);
    const written = try cols.splice(gpa, 0, &.{make}, .unicode_code_point, table.asTable());

    const walk = struct {
        fn build(c: *const opcols.Columns(OpBuilder), t: StringTable, s: []SuccEntry, w: usize) !opiter.OpIter(OpBuilder) {
            return opiter.OpIter(OpBuilder).init(c, t, .{ .start = 1, .end = w }, s);
        }
    };

    var at_head = InsertQuery(OpBuilder).init(
        gpa,
        try walk.build(&cols, table.asTable(), succ, written),
        0,
        .text,
        .unicode_code_point,
        null,
        RichTextQueryState.init(gpa),
    );
    defer at_head.deinit();
    var head_answer = try at_head.resolve(0);
    defer head_answer.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), head_answer.pos);
    try testing.expect(head_answer.marks == null);

    var past = InsertQuery(OpBuilder).init(
        gpa,
        try walk.build(&cols, table.asTable(), succ, written),
        1,
        .text,
        .unicode_code_point,
        null,
        RichTextQueryState.init(gpa),
    );
    defer past.deinit();
    try testing.expectError(error.InvalidIndex, past.resolve(0));
}

test "the element the answer names is the one the new row may hang by" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // The acceptance case: splice a row at the position and anchor the answer
    // names, then run the row-order invariant over the whole op set. R4 says an
    // insert opening a new register is legal iff it is anchored to the element
    // the previous row belongs to, or its own id sorts before that element
    // (`op.zig:2081-2086`); the answer's `elemid` is what makes the first arm
    // hold, and the new row's own id is what makes the second one available.
    var q = try fix.query(gpa, 1, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);

    // The new row: an insert, anchored to `answer.elemid`, with an id that
    // sorts *after* every existing id, so the second arm of R4 is what it must
    // satisfy — a stronger test than anchoring to the previous element.
    const fresh_id: OpId = .{ .counter = 9, .actor = 0 };
    var fresh = try OpBuilder.init(
        gpa,
        fresh_id,
        text_obj,
        .set,
        .fromElemId(answer.elemid),
        .{ .str = "X" },
        true,
        false,
        null,
        &.{},
    );
    defer fresh.deinit(gpa);
    const written = try fix.cols.splice(gpa, answer.pos, &.{fresh}, .unicode_code_point, fix.table.asTable());
    try testing.expectEqual(@as(usize, 1), written);

    // Every consecutive pair of the op set, in order, from the initial stepper
    // — which is exactly what `OpSet::validate_op_order` is
    // (`op_set2/op_set.rs:167-175`).
    try expectRowOrder(gpa, &fix);
}

test "the row-order invariant still holds when the mark end is what moves" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, false);
    defer fix.deinit();

    // The same splice at the point the sticky rule chose for a non-expanding
    // end, where the row is anchored to the mark *end's* element and lands
    // between the end and nothing else. The end's own id is the anchor, so R4's
    // second arm is the one that has to hold for the end row that follows.
    var q = try fix.query(gpa, 2, .text);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), answer.pos);

    var fresh = try OpBuilder.init(
        gpa,
        .{ .counter = 9, .actor = 0 },
        text_obj,
        .set,
        .fromElemId(answer.elemid),
        .{ .str = "X" },
        true,
        false,
        null,
        &.{},
    );
    defer fresh.deinit(gpa);
    const written = try fix.cols.splice(gpa, answer.pos, &.{fresh}, .unicode_code_point, fix.table.asTable());
    try testing.expectEqual(@as(usize, 1), written);
    try expectRowOrder(gpa, &fix);
}

test "a resolver over a list counts every visible element once" {
    const gpa = testing.allocator;
    // A list is the same shape with `.list`, and the difference that matters is
    // the width: a list element is one wide whatever its value
    // (`op.zig:1817-1822`), so `index` advances by rows rather than by text
    // units. The two marks are width zero in a text and must still be width
    // zero here.
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    var q = try fix.query(gpa, 1, .list);
    defer q.deinit();
    var answer = try q.resolve(0);
    defer answer.deinit(gpa);
    // Same position and same anchor as the text answer: the mark rows are
    // transparent to the index in a list too, because they are not rows the
    // index counts (`insert.rs:122-125`).
    try testing.expectEqual(@as(usize, 3), answer.pos);
    try testing.expectEqual(@as(usize, 1), answer.index);
}

test "the caller may hand the resolver a clock it does not cover" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // A clock that names no actor, so nothing is visible. The sticky-mark scan
    // still runs over the rows it reads — it is the one thing that reads
    // invisible rows (`insert.rs:89-90`, `:112-120`) — but the widths are
    // counted over visible rows only, so the target is never reached and the
    // answer is `error.InvalidIndex` rather than a position.
    const walk = try opiter.OpIter(OpBuilder).init(&fix.cols, fix.table.asTable(), .{
        .start = 1,
        .end = fix.rows,
    }, fix.succ);
    var q = InsertQuery(OpBuilder).init(
        gpa,
        walk,
        1,
        .text,
        .unicode_code_point,
        Clock.initEmpty(gpa),
        RichTextQueryState.init(gpa),
    );
    defer q.deinit();
    try testing.expectError(error.InvalidIndex, q.resolve(0));
}

test "a resolver over a sub-range agrees with one over the object" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // A range that starts and ends inside the object. The answer's *position*
    // is relative to the whole op set and does not move, because `resolve`
    // answers an op-set row, not an offset into the walk — which is what
    // `OpSet::splice` needs.
    var whole = try fix.query(gpa, 1, .text);
    defer whole.deinit();
    var a = try whole.resolve(0);
    defer a.deinit(gpa);

    var partial = try fix.query(gpa, 1, .text);
    defer partial.deinit();
    partial.setMax(3);
    var b = try partial.resolve(0);
    defer b.deinit(gpa);
    // A walk that ends before the mark's end still finds the same point: the
    // begin queued it, the `"b"` row is the walk's last, and the end row is
    // only needed to close the mark — which it must not, because the point is
    // before it.
    try testing.expectEqual(a.pos, b.pos);
    try testing.expectEqual(a.elemid, b.elemid);
}

test "constructing a resolver allocates nothing" {
    const gpa = testing.allocator;
    var fix = try Fixture.init(gpa, true);
    defer fix.deinit();

    // The walk is built first and from the real allocator, so the only thing
    // that can move the count is the constructor. Upstream allocates here for
    // the `target == 0` candidate (`insert.rs:33-37`); this does not, which is
    // what `head` is for.
    var counting: Counting = .{ .inner = gpa };
    const walk = try opiter.OpIter(OpBuilder).init(&fix.cols, fix.table.asTable(), .{
        .start = 1,
        .end = fix.rows,
    }, fix.succ);
    var q = InsertQuery(OpBuilder).init(
        counting.allocator(),
        walk,
        0,
        .text,
        .unicode_code_point,
        null,
        RichTextQueryState.init(counting.allocator()),
    );
    try testing.expectEqual(@as(usize, 0), counting.count);
    defer q.deinit();
    // And a target that is not zero, to show the head field is not what makes
    // it free.
    const walk2 = try opiter.OpIter(OpBuilder).init(&fix.cols, fix.table.asTable(), .{
        .start = 1,
        .end = fix.rows,
    }, fix.succ);
    var q2 = InsertQuery(OpBuilder).init(
        counting.allocator(),
        walk2,
        1,
        .text,
        .unicode_code_point,
        null,
        RichTextQueryState.init(counting.allocator()),
    );
    try testing.expectEqual(@as(usize, 0), counting.count);
    q2.deinit();
}

test "the resolver is a Shiftable cursor" {
    // The instantiation is the check.
    comptime _ = InsertQuery(OpBuilder).shiftable;
}

test "a query term over a resolver is not required, and one over a mark walk is" {
    // `MarkIter` and `NoMarkIter` are the query terms the resolver feeds, and
    // the instantiations are the checks (`marks.zig:663-671` runs the same one
    // over the same pair).
    comptime oquery.assertQueryTerm(opmarks.MarkIter(opiter.OpIter(OpBuilder)));
    comptime oquery.assertQueryTerm(opmarks.NoMarkIter(opiter.OpIter(OpBuilder)));
}

/// Every consecutive pair of the op set, in order, from the initial stepper
/// (`OpSet::validate_op_order`, `op_set2/op_set.rs:167-175`).
///
/// This is the gate the whole op set is checked against, run after every apply
/// and once on every loaded document (`op_set2/change/batch.rs:949`,
/// `storage/document.rs:332-344`), and it is what a splice has to leave intact.
fn expectRowOrder(gpa: Allocator, fix: *Fixture) !void {
    const succ = try gpa.alloc(SuccEntry, try opiter.maxSuccCount(OpBuilder, &fix.cols, .{
        .start = 0,
        .end = fix.rows,
    }));
    defer gpa.free(succ);
    var walk = try opiter.OpIter(OpBuilder).init(&fix.cols, fix.table.asTable(), .{
        .start = 0,
        .end = fix.rows,
    }, succ);
    var stepper = OpStepper.initial();
    var checked: usize = 0;
    while (try walk.next()) |op| {
        if (checked > 0 and !op.step(&stepper)) {
            std.debug.print("row {d} (id {d}:{d}) is out of order\n", .{
                op.pos,
                op.id().actor,
                op.id().counter,
            });
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expectEqual(fix.rows, checked);
}
