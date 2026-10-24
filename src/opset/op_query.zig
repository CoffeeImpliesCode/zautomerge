//! What makes an op iterator a *query*, and the adapter that folds a
//! counter's increments into its value
//! (`rust/automerge/src/op_set2/op_set/op_query.rs`, 121 lines).
//!
//! Upstream states the contract twice, as two traits that are three methods
//! wide in total: `OpQueryTerm` is `get_marks` and `range` on top of
//! `Iterator<Item = Op>` (`op_query.rs:14-18`), and `OpQuery` is that plus
//! `Clone` and four combinators (`op_query.rs:20-47`). The only other thing in
//! the file is [`FixCounters`] (`op_query.rs:74-121`).
//!
//! # Why the traits are a static check here, and not a `std.interface`
//!
//! **The shape is a `comptime` assertion over a caller's own type, plus free
//! constructors that are generic over the walk they wrap.** Three reasons, all
//! of which are the port's own and none of which is a preference.
//!
//! * No op-set query site needs runtime dispatch. Every consumer
//!   writes one generic walk and instantiates it: `TopOps::new(op_set, clock,
//!   range)` is generic over its inner (`op_set2/op_set/top_op.rs:26`),
//!   `VisibleOpIter::new` is generic (`op_set2/op_set/visible.rs:174-177`),
//!   and `OpQuery::visible` composes two generics (`op_query.rs:38-45`).
//!   Choosing an inner is a comptime decision everywhere, so a vtable would
//!   charge one indirect call per *row* for a dispatch that never happens at
//!   runtime.
//! * The port has already made this call once, on the trait that is hardest
//!   to spell, and it made it the same way: upstream's `OpLike` has a generic
//!   associated type `SuccIter<'b>` in its successor half
//!   (`op_set2/op.rs:1324-1327`) that Zig cannot express, so the port split
//!   the trait into static-arity functions, made a caller generic over
//!   `comptime O: type`, and wrote `assertOpLike` to check the whole set at
//!   compile time (`op.zig:34-52`, `op.zig:484-557`). `OpQueryTerm` is a
//!   weaker version of the same problem and gets the weaker version of the
//!   same answer.
//! * A query in this port is a *cursor*, and cursors here are values carrying
//!   a `Shiftable` kernel (`hexane/column.zig:3996-4016`). The kernel is
//!   already a comptime check over the type. A query that had to be a vtable
//!   could not also be a `Shiftable` cursor without boxing it, and
//!   *constructing one allocates nothing* is the rule this slice is judged by.
//!
//! So [`assertQueryTerm`] is the contract, spelled as a compile-time check,
//! and [`FixCounters`] is the one adapter that lives here. A caller that
//! wants a different inner instantiates the adapter at the inner it has,
//! which is what "a caller can hold either flavour" means in Zig: one generic
//! function, instantiated twice.
//!
//! # Where `OpQuery`'s four combinators went
//!
//! `OpQuery` is `marks`, `no_marks`, `visible`, `visible_slow`
//! (`op_query.rs:20-47`) — all four *constructors*, and none of them belongs in
//! this file, because two of the three modules that own them sit **downstream**
//! of this one:
//!
//! | combinator | the module that owns it | why not here |
//! |---|---|---|
//! | `marks`, `no_marks` | [`marks.zig`](marks.zig) | upstream `op_set2/op_set/marks.rs:3` imports `OpQueryTerm` *from this file*, so the dependency runs that way there too |
//! | `visible`, `visible_slow` | `visible.zig` | upstream `visible.rs:267-275` implements `OpQueryTerm` for `VisibleOpIter`, same direction, and `VisIter` does not exist yet |
//! | `key_ops` | — | `#[cfg(test)]` upstream (`op_query.rs:29-32`) and its `KeyOpIter` is not ported |
//!
//! In Rust a trait's default body can name any type in the crate, so one
//! `impl OpQuery for I {}` (`op_query.rs:72`) hands all four to every query.
//! Zig has no equivalent, and the honest spelling is the table above: a caller
//! writes `MarkIter.init(gpa, my_query)` and gets the same thing.
//!
//! # What a query term has to carry here, and why it is five methods
//!
//! [`query_term_decls`] is upstream's two methods plus the three the port
//! gives every walk in the crate:
//!
//! | method | upstream | port |
//! |---|---|---|
//! | `next` | `Iterator<Item = Op>` (`op_query.rs:14`) | `next() ReadOpError!?Op` (`op_iter.zig:1674-1692`) |
//! | `range` | `OpQueryTerm::range` (`op_query.rs:17`) | `range() RowRange` |
//! | `getMarks` | `OpQueryTerm::get_marks` (`op_query.rs:15`) | `getMarks() ?*const MarkSet` |
//! | `pos` | — | the `Shiftable` kernel's read-only accessor (`column.zig:4000`) |
//! | `maxPos` | — | the same, for the window's end (`column.zig:4001`) |
//!
//! `getMarks` answers `Option<&Arc<MarkSet>>` upstream. Three of the six impls
//! answer `None` outright — the raw walk (`op_query.rs:48-51`), a skipper
//! (`op_query.rs:63-65`) and `NoMarkIter` (`marks.rs:81-83`) — one returns its
//! own fold (`marks.rs:46-48`) and one forwards (`op_query.rs:114-116`). The
//! port's `MarkSet` is owned rather than reference counted
//! (`src/marks.zig:484-492` says why), so the borrow is `?*const MarkSet` and
//! a null is "nothing is marked here".
//!
//! # `next` must not answer "nothing here" by accident
//!
//! One trap this port has already been bitten by, so it is stated: a `next`
//! that answers `null` both for "the row carries nothing" and for "the walk is
//! over" is unusable, because a row-at-a-time caller stops at the first empty
//! row. The mark index's cursor is that shape and says so
//! (`mark_index.zig:488-511`, which is walked run at a time for exactly this
//! reason). Every `next` here answers `null` only at the end of the walk — an
//! [`Op`] row that carries no mark is an `Op` with a null mark name, not a null
//! (`op_iter.zig:120-141`) — and the kernel's `shiftNext` is the accessor that
//! *distinguishes* a row from the end, because it answers
//! `error.InvalidValue` for a backward range rather than a bare `null`
//! (`op_iter.zig:1655-1663`).

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const column = @import("../hexane/column.zig");
const marksmod = @import("../marks.zig");
const opmod = @import("op.zig");
const opiter = @import("op_iter.zig");

const Clock = clockmod.Clock;
const Error = err.Error;
const MarkSet = marksmod.MarkSet;
const Op = opmod.Op;
const OpId = types.OpId;
const ParseError = err.ParseError;
const ReadOpError = opiter.ReadOpError;
const RowRange = column.RowRange;
const ScalarValue = @import("../value.zig").ScalarValue;
const Action = @import("../value.zig").Action;
const SuccCursors = opmod.SuccCursors;
const SuccEntry = opmod.SuccEntry;

const testing = std.testing;

// ── The contract ───────────────────────────────────────────────────────────

/// What a query term's `next` may raise, and what [`assertQueryTerm`]
/// requires of it.
///
/// The column layer's `ReadOpError` (`op_iter.zig:142-152`) on its own, plus
/// the document `Error` — because an adapter that folds as it walks can
/// allocate, and a fold that allocates can fail. `ParseError` is a member of
/// `ReadOpError` and neither of those is a member of `Error`, so the union is
/// genuinely three sets' worth. Upstream gets this for free: `OpQueryTerm`'s
/// `Iterator` bound lets any error `impl Into<AutomergeError>`, so a fold that
/// allocates raises nothing at the trait (`op_query.rs:14`, `:103-107`).
pub const QueryError = Error || ReadOpError;

/// The methods a query term has to carry, and where each comes from. See the
/// module documentation for the table.
pub const query_term_decls = [_][]const u8{
    "pos",
    "maxPos",
    "range",
    "getMarks",
    "next",
};

/// Fails to compile unless `Q` carries the whole query-term surface, and
/// carries it with these signatures.
///
/// This is `OpQueryTerm` (`op_query.rs:14-18`) split into static-arity
/// methods, which is what `op.assertOpLike` is for the harder trait: the
/// instantiation *is* the check, so a per-type marker that nothing referenced
/// would prove nothing. The five names are [`query_term_decls`].
///
/// The signature checks are the point as much as the names. A `next` that
/// answered `?Op` with no error could not report the `ReadOpError` the column
/// layer raises, and an adapter forwarding it would have to invent one;
/// requiring the exact type here makes that a compile error at the adapter
/// rather than a silent widening at the call site.
pub fn assertQueryTerm(comptime Q: type) void {
    inline for (query_term_decls) |name| {
        if (!@hasDecl(Q, name)) {
            @compileError("a query term needs this method: " ++ @typeName(Q) ++
                " has no " ++ name ++ "; see op_query.zig's query_term_decls");
        }
    }
    const pos: *const fn (*const Q) usize = &Q.pos;
    const max_pos: *const fn (*const Q) usize = &Q.maxPos;
    const range: *const fn (*const Q) RowRange = &Q.range;
    const get_marks: *const fn (*const Q) ?*const MarkSet = &Q.getMarks;
    const next: *const fn (*Q) QueryError!?Op = &Q.next;
    _ = pos;
    _ = max_pos;
    _ = range;
    _ = get_marks;
    _ = next;
}

// ── FixCounters ────────────────────────────────────────────────────────────

/// A query that folds each counter row's increments into its value as it
/// yields it (`FixCounters`, `op_query.rs:74-121`).
///
/// A counter's value in the columns is only what it was *set* to; every
/// increment that has landed on it since is a successor edge carrying an amount
/// (`op_set2/op.rs:979-995`, and `Op.fixCounter` in `op.zig` is the same fold).
/// Upstream applies `op.fix_counter` to each row as the iterator hands it out
/// (`op_query.rs:103-107`), which is what makes a read of a *past* state see a
/// counter as it stood then: `clock` bounds which increments are folded in, and
/// a null folds in all of them.
///
/// The wrapper is `SkipIter(query, VisIter)` upstream (`op_query.rs:38-45`) —
/// this is the outer half of that composition, and `visible.zig` owns the
/// inner one.
///
/// `init` allocates nothing: the wrapper is the walk plus a nullable clock
/// beside it.
///
/// **It owns nothing, so it declares no `deinit`.** The fold is upstream's
/// rather than this adapter's, and the walk is the caller's, so the teardown a
/// caller writes for a composed walk is the *inner* walk's. A consumer
/// reaching for the uniform `defer x.deinit()` over this family finds one on
/// [`MarkIter`](marks.zig), which owns a fold, and none here.
pub fn FixCounters(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The query whose rows are being fixed (`op_query.rs:76`).
        iter: I,
        /// The clock whose increments are folded in, or null to fold in every
        /// one of them (`op_query.rs:77`).
        ///
        /// **`Clock` is stored by value and its slots are the caller's.** The
        /// copy shares the one allocation [`Clock.init`](../../src/clock.zig)
        /// and [`next`] reads it on every row through [`Op.fixCounter`], so the
        /// clock must outlive this walk.
        clock: ?Clock,

        pub const shiftable = column.Shiftable(Self);

        /// A wrapper that fixes `iter`'s counters against `c`
        /// (`FixCounters::new`, `op_query.rs:82-88`).
        ///
        /// `c` is borrowed rather than copied, so the clock the caller holds
        /// has to outlive the walk — see the `clock` field for what that
        /// obliges.
        pub fn init(iter: I, c: ?Clock) Self {
            return .{ .iter = iter, .clock = c };
        }

        /// The row the next `next` returns (the `Shiftable` kernel's read-only
        /// accessor, `column.zig:4000`).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// One past the last row this walk can yield (`column.zig:4001`).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the walk at `at` (`OpIter.setMax`, `op_iter.zig:1599-1608`).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`
        /// (`OpIter.advanceTo`, `op_iter.zig:1619-1630`).
        pub fn advanceTo(self: *Self, target: usize) ParseError!void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows (`OpIter.advanceBy`, `op_iter.zig:1633-1635`).
        pub fn advanceBy(self: *Self, amount: usize) ParseError!void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the walk's window to `rows` — the window only, not the
        /// position, which is what the kernel's `void` `shift` means here
        /// (`OpIter.shift`, `op_iter.zig:1652-1654`).
        pub fn shift(self: *Self, rows: RowRange) void {
            self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the row at its start
        /// (`OpIter.shiftNext`, `op_iter.zig:1656-1663`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadOpError!?Op {
            return self.iter.shiftNext(rows);
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk (`OpIter.seekTo`, `op_iter.zig:1665-1672`).
        pub fn seekTo(self: *Self, at: usize) ReadOpError!?Op {
            return self.iter.seekTo(at);
        }

        /// The rows still to be walked (`OpQueryTerm::range` forwarded,
        /// `op_query.rs:118-120`).
        pub fn range(self: *const Self) RowRange {
            return self.iter.range();
        }

        /// The mark set the inner query holds, or null
        /// (`OpQueryTerm::get_marks` forwarded, `op_query.rs:114-116`).
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            return self.iter.getMarks();
        }

        /// The next row, with its counter folded, or null at the end of the
        /// walk (`next`, `op_query.rs:103-107`).
        ///
        /// The fold is on the row this hands out. The inner walk holds column
        /// cursors and no rows, so there is nothing behind it to rewrite, and
        /// a caller that wants the unfolded row asks the inner walk.
        ///
        /// Null only ever means the walk is over: a counter with no increments
        /// is still a row, and this is the accessor that keeps the two cases
        /// apart (the module documentation's last section).
        pub fn next(self: *Self) ReadOpError!?Op {
            var fixed = (try self.iter.next()) orelse return null;
            fixed.fixCounter(self.clock);
            return fixed;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// The smallest thing that answers everything a query term must: four rows
/// read from a caller-owned array, carrying the mark set the test hands it.
///
/// It exists so the contract above is checked against a *shape* rather than
/// against one particular op-set walk — the two are checked separately, so a
/// mistake in either does not hide the other.
const FakeQuery = struct {
    rows: []const Op = &.{},
    row: usize = 0,
    marks: ?*const MarkSet = null,

    fn init(rows: []const Op) FakeQuery {
        return .{ .rows = rows };
    }

    pub fn pos(self: *const FakeQuery) usize {
        return self.row;
    }

    pub fn maxPos(self: *const FakeQuery) usize {
        return self.rows.len;
    }

    pub fn range(self: *const FakeQuery) RowRange {
        return .{ .start = self.row, .end = self.rows.len };
    }

    pub fn getMarks(self: *const FakeQuery) ?*const MarkSet {
        return self.marks;
    }

    pub fn next(self: *FakeQuery) ReadOpError!?Op {
        if (self.row >= self.rows.len) return null;
        defer self.row += 1;
        return self.rows[self.row];
    }
};

/// A row as these tests state one: an id, an action, a value and its
/// successors. Nothing else in [`Op`] is read here.
fn makeRow(id: OpId, act: Action, v: ScalarValue, succs: []const SuccEntry) Op {
    return Op.init(
        0,
        false,
        id,
        act,
        .root,
        .{ .map = "k" },
        false,
        v,
        false,
        null,
        SuccCursors.fromSpan(succs, 0),
    );
}

test "a query term is five methods, and the check is the assertion" {
    // The list is the contract, so pin both the names and the count: a sixth
    // method is a decision somebody has to make, not an accident.
    try testing.expectEqual(@as(usize, 5), query_term_decls.len);
    try testing.expectEqualStrings("next", query_term_decls[query_term_decls.len - 1]);

    // `FixCounters` is a query term and a `Shiftable` cursor, and the
    // instantiation is the check.
    comptime assertQueryTerm(FixCounters(FakeQuery));
    comptime _ = FixCounters(FakeQuery).shiftable;
}

test "FixCounters folds every increment when it has no clock" {
    const succs = [_]SuccEntry{
        .{ .id = .{ .counter = 2, .actor = 0 }, .inc = 5 },
        .{ .id = .{ .counter = 3, .actor = 0 }, .inc = 7 },
    };
    const rows = [_]Op{
        makeRow(.{ .counter = 1, .actor = 0 }, .set, .{ .counter = .init(10) }, &succs),
        makeRow(.{ .counter = 2, .actor = 0 }, .set, .{ .int = 1 }, &.{}),
    };

    // Constructing the wrapper allocates nothing: the two fields are `I` and
    // a clock, and the walk it holds was already the caller's.
    var q = FixCounters(FakeQuery).init(FakeQuery.init(&rows), null);
    try testing.expectEqual(@as(usize, 0), q.pos());
    try testing.expectEqual(@as(usize, 2), q.maxPos());

    const first = (try q.next()).?;
    try testing.expectEqual(@as(i64, 22), first.value().counter.current);
    // The row handed out is a copy, so fixing it did not touch the array it
    // was read from — the property every reader of a counter relies on.
    try testing.expectEqual(@as(i64, 10), rows[0].value().counter.current);

    const second = (try q.next()).?;
    try testing.expectEqual(@as(Action, .set), second.action());
    // A non-counter row is not a counter row with an increment of zero: the
    // fold returns early, so the value is exactly what the column held.
    try testing.expect(second.value().eql(.{ .int = 1 }));

    try testing.expect((try q.next()) == null);
    try testing.expectEqual(@as(usize, 2), q.pos());
}

test "FixCounters folds only the increments its clock covers" {
    // A clock at counter 2 from actor 0 covers the increment whose id is
    // (0,2) and not the one at (0,3): `Clock.contains` is the port's
    // `Clock::covers(&OpId)` (`clock.zig:104-109`, upstream `types.rs:134-136`).
    var clock = try Clock.init(testing.allocator, 1);
    defer clock.deinit();
    _ = clock.include(0, 2);

    const succs = [_]SuccEntry{
        .{ .id = .{ .counter = 2, .actor = 0 }, .inc = 5 },
        .{ .id = .{ .counter = 3, .actor = 0 }, .inc = 7 },
    };
    const rows = [_]Op{
        makeRow(.{ .counter = 1, .actor = 0 }, .set, .{ .counter = .init(10) }, &succs),
    };

    var q = FixCounters(FakeQuery).init(FakeQuery.init(&rows), clock);
    try testing.expectEqual(@as(i64, 15), (try q.next()).?.value().counter.current);
    try testing.expect((try q.next()) == null);
}

test "a null and an empty clock are the same query term" {
    // `getMarks` forwards and `range` forwards, so an adapter over a query
    // answers both without knowing anything about the thing it wraps. Pinned
    // here because the forwarding is the whole of `FixCounters`' query-term
    // half (`op_query.rs:110-121`).
    var set = MarkSet.init(testing.allocator);
    defer set.deinit();
    try set.put("bold", .{ .bool_value = true });

    const rows = [_]Op{makeRow(.{ .counter = 1, .actor = 0 }, .set, .{ .int = 3 }, &.{})};
    var inner = FakeQuery.init(&rows);
    inner.marks = &set;

    const q = FixCounters(FakeQuery).init(inner, null);
    try testing.expectEqual(@as(?*const MarkSet, &set), q.getMarks());
    try testing.expectEqual(@as(usize, 0), q.range().start);
    try testing.expectEqual(@as(usize, 1), q.range().end);
}
