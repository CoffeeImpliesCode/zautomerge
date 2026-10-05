//! An object's values, with the id of the operation each one came from
//! (`rust/automerge/src/iter/values.rs`, 36 lines).
//!
//! This is the shape `ReadDoc::values` returns
//! ([`read.rs:129`](../../github-automerge-automerge/rust/automerge/src/read.rs)):
//! a `(value, id)` pair per register, for a map, a list or a text object alike.
//! Upstream's whole body is a stored `(&OpSet, Box<dyn OpQueryTerm>)` and a
//! `next` that renders the pair ([`values.rs:8-36`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)),
//! and so is this file's.
//!
//! # `Values` holds a query term; it is not one
//!
//! Upstream's `Values` **wraps** an `OpQueryTerm` and its `Iterator::next`
//! answers `(Value, ExId)`, not an `Op`
//! ([`values.rs:10,26-36`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)),
//! so it is not itself an `OpQueryTerm` and does not claim to be. What the file
//! *is* about is the term: [`RowQuery`] and [`TopQuery`] are the port of the two
//! trait impls upstream's file leans on,
//! `impl OpQueryTerm for OpIter` ([`op_query.rs:48-56`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs))
//! and `impl OpQueryTerm for TopOps`
//! ([`top_op.rs:67-75`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)),
//! and the port has neither because
//! [`op_query.zig`](../opset/op_query.zig) states the contract as a comptime
//! check and nothing has asked for those two types yet. **They are here because
//! `Values` needs an inner and the port's production inner — the winner walk —
//! has no query-term surface without one.**
//!
//! [`Values`] forwards the term's `pos`, `maxPos`, `range` and `getMarks`
//! unchanged, which is what makes it a usable reader over a term rather than a
//! wrapper that hides it: a caller asking "what does this read cover" asks the
//! walk.
//!
//! # One of the two inners is a query term and the other is not, and that is
//! # a port/upstream difference worth stating
//!
//! `assertQueryTerm` requires `next` to answer
//! `op_query.QueryError!?Op` ([`op_query.zig:174`](../opset/op_query.zig)), and
//! `QueryError` is `Error || ReadOpError` — it does **not** contain
//! [`InternalError`](../../src/error.zig). [`TopQuery.next`] can raise
//! `error.Invariant`, because the port's [`TopOps.next`] keeps upstream's two
//! `assert!`s as [`InternalError`] rather than as a panic
//! ([`top_op.rs:49-56,781-784`](../opset/top_op.zig); upstream's `AutomergeError`
//! has no way to say it).
//! So `assertQueryTerm(TopQuery(O))` **does not compile**
//! and is not claimed, while `assertQueryTerm(RowQuery(O))` and
//! `assertQueryTerm(marks.MarkIter(RowQuery(O)))` both do — the test
//! "the query-term contract is a comptime check, over two different walks" is
//! the proof, and it is the honest shape of the claim.
//!
//! **And [`Values`] checks the wider surface itself**, with
//! [`assertValueTerm`]: the same five declarations against
//! [`ValuesError`] rather than `QueryError`. That is what lets the winner walk —
//! which is the production inner — be a `Values` inner at all, and it is why a
//! third term gets one `@compileError` per missing declaration instead of a
//! member-not-found from the body.
//!
//! # `getMarks` forwards, and that is the whole point
//!
//! A query term whose `getMarks` answers null always is a *different* thing from
//! one that answers the mark set for the register it stands on, and
//! `docs/STATUS.md` keeps that distinction open for `MarkIndexColumn`'s own
//! cursor. So [`Values.getMarks`] forwards rather than deciding, and the test
//! "a term that answers null always is not a term that answers correctly" walks
//! the same rows through both an inner that can only answer null and one that
//! cannot, and reads the mark out of the second.
//!
//! # The clock is accepted and dropped, exactly as upstream drops it
//!
//! [`Values.init`] takes a `?Clock` and **ignores it** — upstream's third
//! parameter is literally `_clock` under a `FIXME`
//! ([`values.rs:14-19`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)),
//! because the clock has already been applied by the term the walk was built
//! with (`automerge.rs:1703` builds the `top_ops` walk *with* the clock and
//! then hands the same clock over). The parameter is kept so the call shape is
//! upstream's and so a future fix is a one-line change rather than a signature
//! change.
//!
//! # One place this file is not upstream-identical, and why
//!
//! [`Values.next`] derives the value with
//! [`optypes.ValueRef.fromActionValue`] ([`opset/types.zig:243-251`](../opset/types.zig)),
//! which is the **op set's** answer, and which is what [map_range.zig](map_range.zig)
//! uses for the same job. Upstream composes `Op::value()`
//! ([`op.rs:1096-1106`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
//! with `ValueRef::to_value()`
//! ([`types.rs:701-706`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs)),
//! and those agree on every action except **mark**: upstream answers the literal
//! `"markBegin"` or `"markEnd"` for a mark row (`op.rs:1100-1103`) where
//! `fromActionValue` answers the mark's own scalar. A second spelling of "what
//! value does this action carry" inside `iter/` would be a second source of
//! truth for the same question, and the op set's is the one that has to be
//! right, so this file uses it and the difference is recorded rather than
//! papered over. Two further consequences of using it, both improvements:
//! upstream's `_ => panic!` arm (`op.rs:1104`) is unreachable here anyway — a
//! register's winner is never a delete (a delete is never a row,
//! [`columns.zig:81-85`](../opset/columns.zig)) and never an increment
//! ([`index.zig:730-741`](../opset/index.zig)) — and `fromActionValue` is total
//! where that arm is not.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const marksmod = @import("../marks.zig");
const column = @import("../hexane/column.zig");
const opcols = @import("../opset/columns.zig");
const optypes = @import("../opset/types.zig");
const opiter = @import("../opset/op_iter.zig");
const opmarks = @import("../opset/marks.zig");
const opmod = @import("../opset/op.zig");
const opquery = @import("../opset/op_query.zig");
const topop = @import("../opset/top_op.zig");
const opset = @import("../opset/op_set.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const InternalError = err.InternalError;
const ParseError = err.ParseError;

const Action = optypes.Action;
const MarkSet = marksmod.MarkSet;
const Op = opmod.Op;
const RowRange = column.RowRange;
const ScalarValue = optypes.ScalarValue;
const ValueRef = optypes.ValueRef;
const Clock = clockmod.Clock;
const ExId = types.ExId;
const OpId = types.OpId;

// ── What a value walk can fail with ─────────────────────────────────────────

/// What reading a value walk can fail with.
///
/// [`op_query.QueryError`] — the document [`Error`](../../src/error.zig) and the
/// column layer's [`opiter.ReadOpError`](../opset/op_iter.zig) — plus
/// [`InternalError`](../../src/error.zig) for the inner.
///
/// **`InternalError` is here and not in `QueryError` because of the winner
/// walk.** [`TopOps.next`] keeps upstream's two assertions as
/// `error.Invariant` ([`top_op.rs:781-784`](../opset/top_op.zig)), and
/// `QueryError` cannot name it, so a `Values` over [`TopQuery`] carries the
/// larger set. An inner that is a query term in the strict sense — a `RowQuery`
/// or a mark fold over one — narrows this to `QueryError`, which is the
/// difference the module's fourth section is about.
pub const ValuesError = opquery.QueryError || InternalError;

/// One value and the operation that put it there
/// ([`ValuesItem`], [`values.rs:27`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)).
///
/// **Upstream returns a bare tuple** `(types::Value<'a>, ExId)` and Zig's tuple
/// types cannot be named in a signature, so the pair has a name — the same
/// reason [`op_set.OpAndVisible`] has one
/// ([`op_set.zig:258-270`](../opset/op_set.zig)).
///
/// The value is **borrowed**: its payload is read out of the op set's value
/// column, which a splice rewrites, so it is valid **until the next mutation**
/// ([`AGENTS.md`](../../AGENTS.md) *Invariants*). Upstream's `types::Value<'a>`
/// is a `Cow`, so an owned copy is [`ValueRef.intoOwned`](../opset/types.zig).
///
/// **The id is a second borrow, and it is the one a caller forgets.** It is
/// resolved against the op set's actor table and holds **the actor's bytes**,
/// which in a document are that document's arena
/// ([`ExId.Named.actor`](../../src/types.zig), `types.zig:280-288`). An
/// [`ExId`] resolved from an op index cannot be made to own its bytes without
/// copying them, so **an item still has to be read while the document is
/// alive**, and `ValueRef.intoOwned` does not change that: it copies the
/// *value*, never the *id*.
pub const ValuesItem = struct {
    /// What the operation carries: the object a make action produces, or the
    /// scalar a put carries
    /// (`op_set2/types.rs:667-675`, `op.rs:1096-1106`).
    ///
    /// **Borrowed out of the op set's value column**, valid until the next
    /// mutation; [`ValueRef.intoOwned`](../opset/types.zig) is the copy that
    /// outlives one. A `.str` scalar's bytes live there; the numbers, the
    /// counter and an object reference are values and borrow nothing.
    value: ValueRef,
    /// The id the operation itself has, resolved against the op set's actor
    /// table (`OpSet::id_to_exid`, `op_set.rs:1054-1060`).
    ///
    /// **Borrows the actor's bytes** from the document that interned the actor
    /// ([`ExId.Named.actor`](../../src/types.zig), `types.zig:280-288`), so it
    /// is valid for as long as that document and not one step longer. Nothing
    /// on this type copies it.
    id: ExId,
};

// ── The two inner walks ─────────────────────────────────────────────────────

/// A raw row walk as a query term ([`impl OpQueryTerm for OpIter`],
/// [`op_query.rs:48-56`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_query.rs)).
///
/// Upstream's impl is `get_marks: None` and `range: self.range()`; the port's
/// [`opiter.OpIter`] already has `pos`, `maxPos`, `range` and `next` and lacks
/// only `getMarks`, so this is the two methods and the type that carries them.
///
/// **It borrows the op set's successor buffer**, which is what that buffer is
/// for ([`op_set.zig:638-640`](../opset/op_set.zig) and its module doc's third
/// and fourth sections): only one such walk may be live at a time, and a caller
/// that needs a second one sizes its own with
/// [`opiter.maxSuccCount`](../opset/op_iter.zig) and calls
/// [`opiter.OpIter.init`] directly. [`TopQuery`] does exactly that, because
/// three walks are alive at once inside a top walk.
pub fn RowQuery(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The row walk this instantiation is ([`opiter.OpIter`](../opset/op_iter.zig),
        /// `op_set.rs:1291-1341`).
        ///
        /// **It borrows the op set's shared successor buffer**, so only one
        /// `RowQuery` over one op set may be live at a time, and the op set
        /// must not be mutated while it is. The type's own section says so; the
        /// field is where a reader looks.
        walk: opiter.OpIter(O),

        /// A query term over `rows` of `op_set` (`OpSet::iter_range`,
        /// `op_set.rs:1317-1341`).
        ///
        /// **Borrows, and takes no teardown**: the buffer is the op set's, so
        /// there is nothing for this term to free — which is why
        /// [`Values`], which holds a `*I`, cannot free its inner on the caller's
        /// behalf either.
        ///
        /// **No clock is taken here**, unlike [`TopQuery.ofObj`]: a `RowQuery`
        /// is built by a caller that wants raw rows, and the clock, if any, was
        /// applied by whatever scoped the walk it came from.
        pub fn over(op_set: *opset.OpSet(O), rows: RowRange) ParseError!Self {
            return .{ .walk = try opiter.OpIter(O).init(
                &op_set.cols,
                op_set.strings,
                rows,
                op_set.succ_scratch.items,
            ) };
        }

        /// The row the next `next` returns ([`Shiftable`](column.zig)'s
        /// read-only accessor, `shift.rs:20-22`).
        pub fn pos(self: *const Self) usize {
            return self.walk.pos();
        }

        /// One past the last row this walk can read (`shift.rs:23-25`).
        pub fn maxPos(self: *const Self) usize {
            return self.walk.maxPos();
        }

        /// The rows still to be walked (`OpQueryTerm::range`, `op_query.rs:54`).
        pub fn range(self: *const Self) RowRange {
            return self.walk.range();
        }

        /// Null, always (`OpQueryTerm::get_marks` for `OpIter`,
        /// `op_query.rs:49-51`).
        ///
        /// A raw row walk carries no fold, so there is no mark set to hand out.
        /// This is the *upstream* answer and not a shortcut — and the contrast
        /// with [`opmarks.MarkIter`] over the same rows is the test "a term that
        /// answers null always is not a term that answers correctly".
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            _ = self;
            return null;
        }

        /// The next row, or null at the end of the walk (`op_iter.rs:99-126`).
        pub fn next(self: *Self) opiter.ReadOpError!?Op {
            return self.walk.next();
        }
    };
}

/// The winner walk as a query term ([`impl OpQueryTerm for TopOps`],
/// [`top_op.rs:67-75`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)).
///
/// Upstream's impl forwards `get_marks` and `range` to its `inner`, which is a
/// `FixCounters<SkipIter<OpIter, TopIter>>`; the chain resolves to
/// `OpIter`'s answers, so `range` is the row walk's remaining rows
/// ([`op_iter.rs:87-89`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_iter.rs))
/// and `get_marks` is **null** — through [`op_query.rs:114-116`](../opset/op_query.zig),
/// `:63-65`, `:49-51`. The same two answers are given here, and `pos`/`maxPos`
/// are the row walk's.
///
/// **It owns the successor buffers, and there is no second set.** [`ofObj`] is
/// `OpSet.topOps` verbatim and hands over the [`TopWalk`] it built;
/// [`over`] builds a `TopWalk` of its own over a row range, with its own
/// [`topop.topScratch`] — the port's one borrowing difference from upstream,
/// named at [`op_set.zig:40-49`](../opset/op_set.zig). A caller holding two of
/// these has two sets, which is the point.
pub fn TopQuery(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The winner walk, **together with the three successor buffers it owns**
        /// ([`TopWalk`](../opset/op_set.zig), `op_set.rs:1085-1091`).
        ///
        /// **These buffers are this walk's and no other walk's**, whether the
        /// walk came from [`ofObj`](TopQuery.ofObj) or [`over`](TopQuery.over),
        /// so **two of these may be live over one op set at once** — the port's
        /// one-live-at-a-time rule ([`op_set.zig:40-49`](../opset/op_set.zig)) is
        /// about the walks that borrow the op set's *shared* buffer, which a top
        /// walk does not. [`deinit`](TopQuery.deinit) releases them.
        walk: opset.TopWalk(O),

        /// The winners of `obj`'s registers as they stand at `clock`
        /// ([`TopOps::new`](../opset/top_op.zig), `top_op.rs:26-42`; upstream's caller is
        /// [`automerge.rs:1703`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        ///
        /// **Takes no allocator, because it allocates none of its own**: it is
        /// `OpSet.topOps`, and the op set allocates the scratch
        /// ([`topScratch`](../opset/top_op.zig), `top_op.zig:730-744`) — which is
        /// also **the allocator [`deinit`](TopQuery.deinit) must be given**,
        /// the op set's own. [`over`](TopQuery.over) is the constructor that
        /// allocates from the caller's allocator, and it takes it first.
        ///
        /// **`clock` is borrowed and `null` is the present.** It is a
        /// [`Clock`](../../src/clock.zig) by value — a `[]u32` plus the
        /// allocator that allocated it — and the walk reads through it on every
        /// row, so **the caller's clock has to outlive the walk**: a
        /// `Clock.deinit` while this walk is still being read leaves it reading
        /// released counters. A non-null clock bounds the walk to the operations
        /// it covers. `op_set` is borrowed too.
        pub fn ofObj(op_set: *opset.OpSet(O), obj: ExId, clock: ?Clock) ValuesError!Self {
            return .{ .walk = try op_set.topOps(obj, clock) };
        }

        /// The winners **in `rows`**, as they stand at `clock`
        /// ([`TopIter`](../opset/top_op.zig)'s `rows` parameter, `top_op.rs:178-196`).
        ///
        /// This is the constructor a sub-range read uses, and the reason
        /// [`opset.TopWalk`] is spelled out here rather than reached through
        /// `topOps`: `topOps` is always a whole object.
        ///
        /// **`gpa` is the allocator of both halves**: the three buffers are
        /// taken with it here and must be given back to
        /// [`deinit`](TopQuery.deinit) with the same one. **Failure leaves
        /// nothing behind** — the scratch is registered with `errdefer` before
        /// the one other fallible step, so an error frees what was allocated and
        /// returns no walk.
        ///
        /// **`clock` and `op_set` are borrowed**, with the same window
        /// [`ofObj`](TopQuery.ofObj) gives: the caller's clock has to outlive the
        /// walk, and `null` is the present.
        pub fn over(
            gpa: Allocator,
            op_set: *opset.OpSet(O),
            rows: RowRange,
            clock: ?Clock,
        ) ValuesError!Self {
            var scratch = try topop.topScratch(O, gpa, &op_set.cols, rows);
            errdefer scratch.deinit(gpa);
            return .{ .walk = .{
                .ops = try topop.TopOps(O).init(&op_set.cols, op_set.strings, rows, clock, scratch),
                .scratch = scratch,
            } };
        }

        /// Frees the three successor buffers and nothing else
        /// ([`TopWalk.deinit`](../opset/op_set.zig)).
        ///
        /// **Which allocator depends on which constructor built it**, and the
        /// answer is the same in both cases: the allocator the buffers were
        /// allocated with. A walk from [`ofObj`](TopQuery.ofObj) was allocated
        /// by the op set and must be freed with the **op set's own `gpa`** —
        /// for a document, [`Document.allocator`](../../doc.zig) — and a walk
        /// from [`over`](TopQuery.over) with the `gpa` that call was given. Any
        /// other allocator is a mismatched free.
        ///
        /// **Once, on the one owner.** The receiver is a pointer and the body
        /// ends in `self.* = undefined`, so a second call reads undefined
        /// storage rather than freeing the same three buffers again. **A copy
        /// carries the buffers but not the teardown**: `var b = a;
        /// a.deinit(gpa); b.deinit(gpa);` frees them twice, because the copy's
        /// own outer state was never poisoned. Moving the walk is fine.
        ///
        /// Nothing this walk borrowed is freed here — not the op set, not the
        /// string table, not the caller's clock.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.walk.deinit(gpa);
            self.* = undefined;
        }

        /// The row the next `next` returns.
        pub fn pos(self: *const Self) usize {
            return self.walk.ops.walk.pos();
        }

        /// One past the last row this walk can read.
        pub fn maxPos(self: *const Self) usize {
            return self.walk.ops.walk.maxPos();
        }

        /// The rows still to be walked ([`OpIter.range`](../opset/op_iter.zig),
        /// `op_iter.rs:87-89`).
        pub fn range(self: *const Self) RowRange {
            return self.walk.ops.walk.range();
        }

        /// Null, always — the whole upstream chain, spelled out.
        ///
        /// `TopOps::get_marks` forwards to `self.inner.get_marks()`
        /// ([`top_op.rs:68-70`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)),
        /// `FixCounters` forwards again
        /// ([`op_query.rs:114-116`](../opset/op_query.zig)), a `SkipIter`
        /// answers `None` ([`op_query.rs:63-65`](../opset/op_query.zig)), and
        /// the `OpIter` at the bottom answers `None`
        /// ([`op_query.rs:49-51`](../opset/op_query.zig)). A winner walk has no
        /// fold, so this is the correct answer and not a suppression.
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            _ = self;
            return null;
        }

        /// The next register's winner, or null at the end of the rows
        /// ([`TopOps::next`](../opset/top_op.zig), `top_op.rs:44-65`).
        ///
        /// **The row it returns borrows three things**: its successors out of the
        /// buffers above, its value out of the op set's value column, and its
        /// key out of the string table. All three are valid only while the op
        /// set is, and the row is over the moment the next `next` runs — which
        /// is why a caller that keeps one copies what it needs rather than
        /// keeping the `Op`.
        ///
        /// **Null is the end of the rows**, and a register with no visible row
        /// is skipped rather than answered.
        pub fn next(self: *Self) ValuesError!?Op {
            return self.walk.next();
        }
    };
}

/// The surface a [`Values`] inner has to carry, checked once when the type is
/// instantiated.
///
/// **Not [`opquery.assertQueryTerm`], and the difference is the error set.** A
/// query term's `next` answers [`opquery.QueryError`], which is what the trait
/// requires; the winner walk's answers [`ValuesError`] as well, because the
/// port keeps upstream's two `assert!`s as
/// [`InternalError`](../../src/error.zig) rather than as a panic
/// ([`top_op.zig:781-784`](../opset/top_op.zig)) and `QueryError` cannot name it.
/// So this asks for the **wider** set — the one [`Values`] forwards — and a
/// third term that can raise `InternalError` is a valid inner here where it
/// would not be a query term. The five names are
/// [`opquery.query_term_decls`], so there is one list.
///
/// **One `@compileError` per missing declaration, naming the name**, so a
/// caller who writes a third term recovers the contract from the failure
/// instead of from this file's body. The signature checks are the point as much
/// as the names: a `getMarks` answering something other than
/// `?*const MarkSet`, or a `next` answering a bare `?Op` with no error, would
/// otherwise be a mistake at the call site.
fn assertValueTerm(comptime I: type) void {
    inline for (opquery.query_term_decls) |name| {
        if (!@hasDecl(I, name)) {
            @compileError("a Values inner needs this method: " ++ @typeName(I) ++
                " has no " ++ name ++ "; see op_query.zig's query_term_decls");
        }
    }
    const pos: *const fn (*const I) usize = &I.pos;
    const max_pos: *const fn (*const I) usize = &I.maxPos;
    const range: *const fn (*const I) RowRange = &I.range;
    const get_marks: *const fn (*const I) ?*const MarkSet = &I.getMarks;
    const next: *const fn (*I) ValuesError!?Op = &I.next;
    _ = pos;
    _ = max_pos;
    _ = range;
    _ = get_marks;
    _ = next;
}

// ── The walk ────────────────────────────────────────────────────────────────

/// An object's values, one per visible register, with the id each came from
/// ([`Values`], [`values.rs:8-36`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)).
///
/// `I` is the query term the walk reads through, and the file is shaped around
/// it: [`RowQuery`] and [`TopQuery`] are the two the port has, and a caller with
/// a third hands it over the same way. **Upstream spells the field
/// `Box<dyn OpQueryTerm<'a>>` and the port spells it `*I`**, which is the same
/// decision the rest of the crate makes: a dispatch that is resolved at comptime
/// is not worth an indirect call per row
/// ([`op_query.zig:13-27`](../opset/op_query.zig)). The consequence is that
/// **`Values` borrows the walk and the caller frees it** — `MarkIter.deinit()`
/// takes no allocator and `TopQuery.deinit(gpa)` takes one, so there is no one
/// free this could call on the caller's behalf.
///
/// # What `I` has to be
///
/// **A duck-typed comptime parameter with a checked surface, checked here and
/// not left to the body.** `I` needs the five declarations
/// [`opquery.query_term_decls`] — `pos`, `maxPos`, `range`, `getMarks`, `next`
/// — with the signatures [`assertValueTerm`] checks, and it is `Values`' own
/// check rather than [`opquery.assertQueryTerm`]'s because the inner's `next`
/// may raise the wider [`ValuesError`] (see that function). A third term that
/// is missing one fails to compile with the name of the declaration and the
/// list to read, which is the whole point of asking a caller for a type rather
/// than a vtable.
///
/// **One reader, no `deinit`, and nothing owned.** `op_set` and `iter` are both
/// borrowed: the op set has to outlive the walk, and so does the term — which
/// is why the term's own teardown is the caller's to call.
///
/// Constructing one allocates nothing: two pointers.
pub fn Values(comptime O: type, comptime I: type) type {
    return struct {
        const Self = @This();

        comptime {
            // **The check is the instantiation.** Naming `I` in a `comptime`
            // block is what makes it a contract rather than a convention: a
            // third term missing a declaration fails here, where the error names
            // the declaration, instead of at the first `next` with a
            // member-not-found.
            assertValueTerm(I);
        }

        /// The op set an id is resolved against (`values.rs:10`).
        ///
        /// **Not optional, and that is a departure from upstream**, for the
        /// reason [map_range.zig](map_range.zig)'s `MapDiff` records
        /// (`map_range.zig:740-749`): upstream's is `Option<&OpSet>` and its
        /// empty reader is a `Default`, which `automerge.rs:1701-1704` reaches
        /// for when an id names nothing. A caller with no object scopes to an
        /// **empty row range** and builds the same reader, which answers
        /// nothing for the same reason and needs no second shape.
        ///
        /// **Borrowed, and not just for the id**: it is the table the inner term
        /// walks, so it must not be mutated, moved or freed while the walk is
        /// alive.
        op_set: *opset.OpSet(O),
        /// The query term (`values.rs:10`).
        ///
        /// **Borrowed, and the teardown is the caller's** — the type's second
        /// section. Its own buffer rules apply too: a [`RowQuery`] borrows the
        /// op set's shared successor buffer, so only one such walk may be live
        /// over one op set, while a [`TopQuery`] brings its own.
        iter: *I,

        /// A read of `iter` against `op_set`, as `clock` saw it
        /// ([`Values::new`],
        /// [`values.rs:15-23`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)).
        ///
        /// **`clock` is accepted and dropped**, under upstream's own `FIXME`
        /// ([`values.rs:14`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs));
        /// the module's fifth section says why the parameter is still here.
        ///
        /// **Because it is dropped, no clock is retained and so no clock has to
        /// outlive this reader.** The clock was already applied by the term the
        /// walk was built with — that is what the module's fifth section says,
        /// and it is why the caller builds the term with the clock rather than
        /// handing it over here. A caller that wants a read at a past state
        /// passes the clock to [`TopQuery.ofObj`] or [`TopQuery.over`], and the
        /// term **does** borrow it from there.
        ///
        /// **`op_set` and `iter` are both borrowed** and both must outlive the
        /// walk; see the fields.
        pub fn init(op_set: *opset.OpSet(O), iter: *I, clock: ?Clock) Self {
            _ = clock;
            return .{ .op_set = op_set, .iter = iter };
        }

        /// The row the walk is on, forwarded to the term
        /// ([`Shiftable`](../src/hexane/column.zig)'s read-only accessor,
        /// `shift.rs:20-22`).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// One past the last row the term can read, forwarded
        /// (`shift.rs:23-25`).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// The rows this read covers, forwarded ([`OpQueryTerm::range`](../opset/op_query.zig)).
        pub fn range(self: *const Self) RowRange {
            return self.iter.range();
        }

        /// The mark set the term is standing on, forwarded
        /// ([`OpQueryTerm::get_marks`](../opset/op_query.zig)).
        ///
        /// **Forwarded and not decided.** A read that answered null here would
        /// be a different thing from one that answers the register's marks, and
        /// the two differ over real walks — see the test "a term that answers
        /// null always is not a term that answers correctly".
        pub fn getMarks(self: *const Self) ?*const MarkSet {
            return self.iter.getMarks();
        }

        /// The next value and the id it came from, or null at the end of the
        /// walk ([`Iterator::next` for `Values`],
        /// [`values.rs:29-35`](../../github-automerge-automerge/rust/automerge/src/iter/values.rs)).
        ///
        /// `op_set.id_to_exid(op.id)` (`values.rs:33`) and
        /// `op.value().to_value()` (`values.rs:32`), which is
        /// [`ValueRef.fromActionValue`] here — see the module's last section for
        /// the one action where that is not upstream-identical and why.
        ///
        /// **The item it returns is borrowed in both halves** — the value's
        /// payload out of the op set's value column, and the id's actor bytes
        /// out of its actor table. See [`ValuesItem`]'s first section for each
        /// window, and [`ValueRef.intoOwned`](../../opset/types.zig) for the
        /// copy that detaches the value.
        ///
        /// **Null is the end of the walk**, and a register whose rows have all
        /// been deleted is not a register and yields nothing.
        pub fn next(self: *Self) ValuesError!?ValuesItem {
            const op = (try self.iter.next()) orelse return null;
            return .{
                .value = ValueRef.fromActionValue(op.action(), op.value()),
                .id = self.op_set.idToExid(op.id()),
            };
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The concrete op set the fixtures are read through, and the op type every
/// walk here is instantiated at.
///
/// **`opmod.Op` and not `opmod.ChangeOp`**, for the reason
/// [map_range.zig](map_range.zig) records: `Op` borrows its row's successors
/// and its value, so a fixture is an array of `Op` over its own spans and needs
/// no allocator. The index columns come from [`OpSet.rebuildIndex`] rather than
/// from the rows, which is the only way a fixture with a conflicted or deleted
/// register can be right — `Op.top` is `Op.visible`
/// ([`op.zig:1868-1871`](../opset/op.zig)).
const Set = opset.OpSet(opmod.Op);

/// The concrete row walk both inner terms are built on, named once so the
/// `assertQueryTerm` instantiations below read as the two different walks they
/// are.
const Row = RowQuery(opmod.Op);
const Marked = opmarks.MarkIter(Row);

/// The encoding every fixture is built with, so a width is a count of code
/// points and not a count of bytes.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's actor, **sorted**: an actor index is a position in the table
/// ([`types.zig:20-21`](../../src/types.zig)).
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

fn opId(ctr: u32, actor: types.ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: types.ActorIdx) ExId {
    return .{ .id = opId(ctr, actor) };
}

fn anchor(id: OpId) optypes.KeyRef {
    return .{ .seq = types.ElemId.fromOpId(id) };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value,
/// the mark name and the successor span — belongs to the fixture, which outlives
/// the op set.
fn row(
    id: OpId,
    obj: ExId,
    key: optypes.KeyRef,
    insert: bool,
    act: Action,
    val: ScalarValue,
    succs: []const opmod.SuccEntry,
) Op {
    return opmod.Op.init(
        0,
        false,
        id,
        act,
        obj,
        key,
        insert,
        val,
        false,
        null,
        opmod.SuccCursors.fromSpan(succs, 0),
    );
}

/// A row that opens a mark, which is the only thing a mark fold has to see for
/// [`Marked.getMarks`](../opset/marks.zig) to answer anything.
///
/// `mark_name` non-null is a mark **begin** and null is a mark **end**
/// ([`op_set2/op.rs:1015-1017`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs),
/// `OpType::from_action_and_value`).
fn markRow(
    id: OpId,
    obj: ExId,
    key: optypes.KeyRef,
    insert: bool,
    val: ScalarValue,
    mark_name: ?[]const u8,
) Op {
    return opmod.Op.init(
        0,
        false,
        id,
        .mark,
        obj,
        key,
        insert,
        val,
        false,
        mark_name,
        opmod.SuccCursors.fromSpan(&.{}, 0),
    );
}

/// The common shape of every row above: a map row that inserts nothing.
fn mapRow(
    id: OpId,
    obj: ExId,
    key: []const u8,
    val: ScalarValue,
    succs: []const opmod.SuccEntry,
) Op {
    return row(id, obj, .{ .map = key }, false, .set, val, succs);
}

/// A successor edge with no increment, which is how a delete reaches the op
/// set ([`columns.zig:81-85`](../opset/columns.zig)).
fn shadows(succ_id: OpId) [1]opmod.SuccEntry {
    return [1]opmod.SuccEntry{.{ .id = succ_id, .inc = null }};
}

/// The string table a fixture's op set borrows. **Heap-allocated, and that is an
/// ownership rule rather than a convenience**
/// ([`op_set.zig`](../opset/op_set.zig)'s `documentSet`): the op set borrows the
/// table, so it has to sit at one address for as long as the set does.
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
    fn asTable(self: *Table) opcols.StringTable {
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
        try self.items.ensureUnusedCapacity(gpa, 1);
        self.items.appendAssumeCapacity(try gpa.dupe(u8, text));
        return id;
    }
};

/// An op set and the table it borrows, built together.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    fn build(gpa: Allocator, actors: []const types.ActorId, rows: []const Op) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, encoding, self.table.asTable()) catch |e| {
            self.table.deinit();
            return e;
        };
        errdefer self.table.deinit();
        errdefer self.set.deinit();
        _ = try self.set.splice(0, rows);
        // The index is **derived**, never declared: a row carries no statement
        // about which register it wins.
        try self.set.rebuildIndex();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// A clock over every operation up to and including `cutoff`, which is the
/// document as it was just after that operation.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// The scalar a value carries, read out of an item, for a test that has already
/// decided the item is a scalar.
fn intOf(v: ScalarValue) ?i64 {
    return switch (v) {
        .int => |n| n,
        else => null,
    };
}

fn strOf(v: ScalarValue) ?[]const u8 {
    return switch (v) {
        .str => |s| s,
        else => null,
    };
}

// ── The tests ───────────────────────────────────────────────────────────────

test "the query-term contract is a comptime check, over two different walks" {
    // **The instantiation is the check** ([`op_query.zig:150-180`](../opset/op_query.zig)):
    // a marker nothing referenced would prove nothing, so the two instantiations
    // below are the assertion. They are over two *different* walks and not one
    // walk twice, because the thing being claimed is that the contract holds
    // for whatever `Values` is handed.
    comptime opquery.assertQueryTerm(Row);
    comptime opquery.assertQueryTerm(Marked);

    // And `Values` over each of them is a real, walked instantiation, so the
    // generic is exercised at both inners rather than only declared.
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(.root);

    var raw = try Row.over(&doc.set, rows);
    var walk = Values(opmod.Op, Row).init(&doc.set, &raw, null);
    const item = (try walk.next()).?;
    try testing.expectEqual(@as(i64, 1), intOf(item.value.scalar).?);
    try testing.expect((try walk.next()) == null);

    var marked = Marked.init(gpa, try Row.over(&doc.set, rows));
    defer marked.deinit();
    var marked_walk = Values(opmod.Op, Marked).init(&doc.set, &marked, null);
    const same = (try marked_walk.next()).?;
    try testing.expectEqual(@as(i64, 1), intOf(same.value.scalar).?);
    try testing.expect((try marked_walk.next()) == null);
}

test "a term that answers null always is not a term that answers correctly" {
    const gpa = testing.allocator;
    // A text object with one element. Its register's first row is a **mark
    // begin** and the next two are sets on the same register, so the mark row is
    // folded before the first set is handed out — which is the only way to ask
    // the fold a question at all, because `MarkIter.getMarks` reports "the marks
    // open at the row the walk is standing on" and is invalidated by the next
    // `next` ([`marks.zig:186-193`](../opset/marks.zig), `marks.rs:46-48`).
    const text = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(2, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        markRow(opId(3, 0), text, anchor(opId(3, 0)), true, .{ .bool_value = true }, "bold"),
        row(opId(4, 0), text, anchor(opId(3, 0)), false, .set, .{ .str = "x" }, &.{}),
        row(opId(5, 0), text, anchor(opId(3, 0)), false, .set, .{ .str = "y" }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(text);

    // **The raw term can only answer null**, before the walk and at every point
    // in it. The check inside the loop is not decoration: a reader that
    // answered something before the first `next` would pass the check before it
    // and fail the one inside.
    var raw = try Row.over(&doc.set, rows);
    try testing.expectEqual(@as(?*const MarkSet, null), raw.getMarks());
    var raw_walk = Values(opmod.Op, Row).init(&doc.set, &raw, null);
    var seen: usize = 0;
    while (try raw_walk.next()) |item| {
        seen += 1;
        _ = item;
        try testing.expectEqual(@as(?*const MarkSet, null), raw_walk.getMarks());
    }
    // Three rows and no fold, so three values — the mark row among them.
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqual(@as(?*const MarkSet, null), raw_walk.getMarks());

    // **The folded term answers the register's marks**, and `Values` forwards
    // that answer rather than deciding it.
    var marked = Marked.init(gpa, try Row.over(&doc.set, rows));
    defer marked.deinit();
    var walk = Values(opmod.Op, Marked).init(&doc.set, &marked, null);

    // **Before the walk**: nothing folded, so the set is empty and the answer is
    // null — the same null the raw term gives, and for a different reason. This
    // is why the two answers cannot be told apart by asking once: the test that
    // separates them is the one after the first row.
    try testing.expectEqual(@as(?*const MarkSet, null), walk.getMarks());

    // **After the first value**: the mark row has been folded and the set names
    // it. This is the assertion that a term which "answers null always" cannot
    // pass.
    const first = (try walk.next()).?;
    try testing.expectEqualStrings("x", strOf(first.value.scalar).?);
    const after = walk.getMarks() orelse return error.TestExpectedResult;

    // The set is asked by **name**, not by position: `MarkSet` is sorted by
    // name ([`marks.zig:327-329`](../../src/marks.zig)) and a reader that
    // counted entries would pass whatever name the fold happened to write.
    try testing.expectEqual(@as(usize, 1), after.len());
    var entries = after.iter();
    const entry = entries.next() orelse return error.TestExpectedResult;
    try testing.expectEqualStrings("bold", entry.name);
    try testing.expect(entry.value.eql(.{ .bool_value = true }));

    // **And the answer survives to the end of the walk**, because no mark row
    // closes it. A fold that dropped the mark when the walk moved on would
    // answer null here and would be a different thing from upstream's
    // (`marks.rs:46-48`).
    const second = (try walk.next()).?;
    try testing.expectEqualStrings("y", strOf(second.value.scalar).?);
    try testing.expect((try walk.next()) == null);
    try testing.expect((walk.getMarks() orelse return error.TestExpectedResult).len() == 1);
}

test "Values answers on a map, a list and a text object through one interface" {
    const gpa = testing.allocator;
    // Three objects, each read through the *same* walk type and the same two
    // field accesses. That is the claim: `read.values()` is one function over
    // three object types ([`automerge.rs:1700-1705`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // and this is the port of that claim.
    const list = made(2, 0);
    const text = made(3, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        // Root map: one scalar, a list, and a text object.
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        row(opId(2, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(3, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, &.{}),
        // A list: two elements.
        row(opId(4, 0), list, anchor(opId(4, 0)), true, .set, .{ .str = "x" }, &.{}),
        row(opId(5, 0), list, anchor(opId(4, 0)), true, .set, .{ .str = "y" }, &.{}),
        // A text object: one element.
        row(opId(6, 0), text, anchor(opId(6, 0)), true, .set, .{ .str = "t" }, &.{}),
    });
    defer doc.destroy();

    // The map: a scalar and two objects. Make actions carry an object type,
    // not a null scalar.
    // ([`op_set2/types.rs:667-675`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs));
    // this is where a reader that read the scalar column alone would answer
    // null.
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

        const first = (try walk.next()).?;
        try testing.expectEqual(@as(i64, 1), intOf(first.value.scalar).?);
        try testing.expect(!first.id.eql(.root));
        try testing.expect(first.id.opId().?.counter == 1);

        const second = (try walk.next()).?;
        try testing.expectEqual(types.ObjType.list, second.value.object);
        try testing.expectEqual(@as(u32, 2), second.id.opId().?.counter);
        const third = (try walk.next()).?;
        try testing.expectEqual(types.ObjType.text, third.value.object);
        try testing.expectEqual(@as(u32, 3), third.id.opId().?.counter);
        try testing.expect((try walk.next()) == null);
    }

    // The list: two scalars, in element order.
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, list, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

        const first = (try walk.next()).?;
        try testing.expectEqualStrings("x", strOf(first.value.scalar).?);
        const second = (try walk.next()).?;
        try testing.expectEqualStrings("y", strOf(second.value.scalar).?);
        try testing.expect((try walk.next()) == null);
    }

    // The text object: one scalar, through the same two field accesses.
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, text, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

        const only = (try walk.next()).?;
        try testing.expectEqualStrings("t", strOf(only.value.scalar).?);
        try testing.expect((try walk.next()) == null);
    }
}

test "a three-row register yields one value, and it is the winner's" {
    const gpa = testing.allocator;
    // `c`'s three rows, the first two shadowed. The winner is the **highest
    // id** — a backwards scan of the register
    // ([`index.zig:536-572`](../opset/index.zig), `index.rs:175-184`) — so the
    // value a reader sees is 90 and not 70.
    const s7 = shadows(opId(8, 0));
    const s8 = shadows(opId(9, 0));
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(7, 0), .root, "c", .{ .int = 70 }, &s7),
        mapRow(opId(8, 0), .root, "c", .{ .int = 80 }, &s8),
        mapRow(opId(9, 0), .root, "c", .{ .int = 90 }, &.{}),
    });
    defer doc.destroy();

    var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
    defer inner.deinit(gpa);
    var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

    // Two registers, three rows in the second: **two values, not four**.
    _ = (try walk.next()).?; // "a"
    const won = (try walk.next()).?;
    try testing.expectEqual(@as(i64, 90), intOf(won.value.scalar).?);
    try testing.expectEqual(@as(u32, 9), won.id.opId().?.counter);
    try testing.expect((try walk.next()) == null);
}

test "a sub-range yields exactly its rows, and a range that starts mid-register is defined" {
    const gpa = testing.allocator;
    // Four rows in the canonical order, and the row numbers are the whole
    // point of the test so they are pinned rather than assumed: register "b" is
    // **rows 0 and 1** and its winner is row 1; register "c" is **rows 2 and 3**
    // and its winner is row 3. Registers ascend by key (rule **R2**,
    // [`op.zig:2215-2222`](../opset/op.zig)) and a register's rows ascend in id
    // (rule **R3**), so "b" before "c" and 1 before 2, 3 before 4.
    const s1 = shadows(opId(2, 0));
    const s3 = shadows(opId(4, 0));
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "b", .{ .int = 10 }, &s1),
        mapRow(opId(2, 0), .root, "b", .{ .int = 20 }, &.{}),
        mapRow(opId(3, 0), .root, "c", .{ .int = 30 }, &s3),
        mapRow(opId(4, 0), .root, "c", .{ .int = 40 }, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), rows.start);
    try testing.expectEqual(@as(usize, 4), rows.end);

    // **The whole object first**, so the sub-ranges below have a baseline to be
    // different from.
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        try testing.expectEqual(@as(usize, 0), walk.range().start);
        try testing.expectEqual(@as(usize, 4), walk.range().end);
        _ = (try walk.next()).?;
        _ = (try walk.next()).?;
        try testing.expect((try walk.next()) == null);
    }

    // **A sub-range that starts on a winner.** Row 1 is register "b"'s winner,
    // so a range from row 1 yields that winner and then register "c"'s — exactly
    // the winners in the range, and not the row 0 that the range excludes.
    {
        var inner = try TopQuery(opmod.Op).over(gpa, &doc.set, .{ .start = 1, .end = 4 }, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        try testing.expectEqual(@as(usize, 1), walk.range().start);
        try testing.expectEqual(@as(usize, 4), walk.range().end);
        try testing.expectEqual(@as(usize, 1), walk.pos());

        const first = (try walk.next()).?;
        try testing.expectEqual(@as(i64, 20), intOf(first.value.scalar).?);
        const second = (try walk.next()).?;
        try testing.expectEqual(@as(i64, 40), intOf(second.value.scalar).?);
        try testing.expect((try walk.next()) == null);
        // The cursor walked to the end of the window, so the two accessors a
        // caller positions by agree with the range it was given.
        try testing.expectEqual(@as(usize, 4), walk.maxPos());
    }

    // **A range that starts mid-register.** Row 2 is the *first* row of
    // register "c" and not its winner — the winner is row 3 — so the walk
    // starts inside a register and still reports that register's winner. That is
    // the defined answer and the one a reader of a document needs: a range cut
    // in the middle of a register must not lose the register.
    {
        var inner = try TopQuery(opmod.Op).over(gpa, &doc.set, .{ .start = 2, .end = 4 }, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        try testing.expectEqual(@as(usize, 2), walk.range().start);
        try testing.expectEqual(@as(usize, 4), walk.range().end);

        const only = (try walk.next()).?;
        try testing.expectEqual(@as(i64, 40), intOf(only.value.scalar).?);
        try testing.expect((try walk.next()) == null);
    }

    // **And a range that ends mid-register truncates it.** Rows 0 to 2 cover
    // register "b" in full and register "c" not at all, so the answer is "b"'s
    // winner alone — a register cut off before its winner contributes nothing
    // rather than an earlier row.
    {
        var inner = try TopQuery(opmod.Op).over(gpa, &doc.set, .{ .start = 0, .end = 2 }, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        try testing.expectEqual(@as(usize, 0), walk.range().start);
        try testing.expectEqual(@as(usize, 2), walk.range().end);

        const only = (try walk.next()).?;
        try testing.expectEqual(@as(i64, 20), intOf(only.value.scalar).?);
        try testing.expect((try walk.next()) == null);
    }

    // **And an empty range is a read with no values**, not a refused one.
    {
        var inner = try TopQuery(opmod.Op).over(gpa, &doc.set, .{ .start = 4, .end = 4 }, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        try testing.expectEqual(@as(usize, 4), walk.range().start);
        try testing.expectEqual(@as(usize, 4), walk.range().end);
        try testing.expect((try walk.next()) == null);
    }
}

test "a clock changes the answer, and the scoped read is a prefix of the unscoped one" {
    const gpa = testing.allocator;
    // Two objects. The list has three elements, one per register, ids 1..3. The
    // map's key "a" has two rows and the second wins.
    const list = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "l", .null_value, &shadows(opId(2, 0))),
        row(opId(2, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(1, 0), list, anchor(opId(1, 0)), true, .set, .{ .str = "x" }, &.{}),
        row(opId(2, 0), list, anchor(opId(2, 0)), true, .set, .{ .str = "y" }, &.{}),
        row(opId(3, 0), list, anchor(opId(3, 0)), true, .set, .{ .str = "z" }, &.{}),
    });
    defer doc.destroy();

    // A clock over counters 1 and 2 of actor 0: the document as it stood just
    // after the second operation of this fixture.
    var clock = try clockUpTo(gpa, 2);
    defer clock.deinit();

    // **A list, where the clock hides a whole register.** Unscoped the read is
    // three values; scoped it is two, and the two are the first two
    // position-for-position — which is the only prefix claim a clock can make
    // here, because registers ascend and a hidden register is hidden *after*
    // the ones before it.
    var unscoped: [8]ValuesItem = undefined;
    var n_unscoped: usize = 0;
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, list, null);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        while (try walk.next()) |item| {
            unscoped[n_unscoped] = item;
            n_unscoped += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), n_unscoped);
    try testing.expectEqualStrings("x", strOf(unscoped[0].value.scalar).?);
    try testing.expectEqualStrings("z", strOf(unscoped[2].value.scalar).?);

    var scoped: [8]ValuesItem = undefined;
    var n_scoped: usize = 0;
    {
        var inner = try TopQuery(opmod.Op).ofObj(&doc.set, list, clock);
        defer inner.deinit(gpa);
        var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
        while (try walk.next()) |item| {
            scoped[n_scoped] = item;
            n_scoped += 1;
        }
    }

    // **It differs**, and the scoped read is *strictly* shorter.
    try testing.expect(n_scoped < n_unscoped);
    try testing.expectEqual(@as(usize, 2), n_scoped);

    // **And it is a prefix, position for position** — the same value and the
    // same id at every position it does answer. A clock that dropped a register
    // from the middle, or answered a register's earlier row at a position the
    // unscoped read filled with the later one, would fail here.
    for (scoped[0..n_scoped], unscoped[0..n_scoped]) |got, want| {
        try testing.expectEqualStrings(
            strOf(want.value.scalar).?,
            strOf(got.value.scalar).?,
        );
        try testing.expectEqual(want.id.opId().?.counter, got.id.opId().?.counter);
    }

    // **A clock reaches into a register, not just over one.** This is the second
    // half of what `?Clock` is for, and it needs its own fixture: a map whose
    // key "a" has two rows, the first shadowed by the second. A clock that
    // covers only the first answers the *earlier* row at the position the
    // unscoped read fills with the later one — which is the one thing the prefix
    // check above cannot see, because there the clock hid whole registers.
    const map_doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &shadows(opId(2, 0))),
        mapRow(opId(2, 0), .root, "a", .{ .int = 2 }, &.{}),
    });
    defer map_doc.destroy();

    var early = try clockUpTo(gpa, 1);
    defer early.deinit();

    var now_inner = try TopQuery(opmod.Op).ofObj(&map_doc.set, .root, null);
    defer now_inner.deinit(gpa);
    var now = Values(opmod.Op, TopQuery(opmod.Op)).init(&map_doc.set, &now_inner, null);
    const now_item = (try now.next()).?;
    try testing.expectEqual(@as(i64, 2), intOf(now_item.value.scalar).?);

    var then_inner = try TopQuery(opmod.Op).ofObj(&map_doc.set, .root, early);
    defer then_inner.deinit(gpa);
    var then = Values(opmod.Op, TopQuery(opmod.Op)).init(&map_doc.set, &then_inner, null);
    const then_item = (try then.next()).?;
    // The same register, the same position, **a different value** — the row the
    // clock had not yet seen shadowed, and a *different* id, because the id is
    // the id of the row the walk read. Two answers with the same value and
    // different ids would be a walk that rewrote the value and kept the id;
    // two with the same id would be a walk that did not re-derive the winner.
    try testing.expectEqual(@as(i64, 1), intOf(then_item.value.scalar).?);
    try testing.expectEqual(@as(u32, 2), now_item.id.opId().?.counter);
    try testing.expectEqual(@as(u32, 1), then_item.id.opId().?.counter);
    try testing.expect(!now_item.id.eql(then_item.id));
    try testing.expect((try then.next()) == null);
    try testing.expect((try now.next()) == null);
}

test "constructing a value walk allocates nothing, and neither does reading one" {
    // The same instrument as the key walk's test: `FailingAllocator` with no
    // `fail_index` never fails and counts every byte its inner allocator hands
    // out ([parents.zig:1089-1096](../opset/parents.zig)). It is the op set's
    // allocator, which is the only one a `Values` can reach: `Values.init` takes
    // none.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
    });
    defer doc.destroy();

    // **The term is built first, outside the measured span**, because
    // `TopQuery` does allocate — the three successor buffers
    // ([`top_op.zig:687-701`](../opset/top_op.zig)) — and it allocates them
    // because a winner walk is three walks alive at once. `docs/plan.md` §3 says
    // *constructing an iterator* allocates nothing, and the wrapper is what that
    // is about; the term is the walk it reads through and the caller owns it.
    var warm_inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
    defer warm_inner.deinit(gpa);
    {
        // Warm the op set and the buffer, and walk one term **out**: a term is
        // a cursor, so a second read through the same one would see nothing and
        // a counting test that read nothing would pass for the wrong reason.
        var warm = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &warm_inner, null);
        var warmed: usize = 0;
        while (try warm.next()) |_| warmed += 1;
        try testing.expectEqual(@as(usize, 1), warmed);
    }

    // The term the measurement uses is built **before** the measured span, so
    // its three successor buffers are already accounted for. That is the whole
    // claim: the wrapper adds nothing to the walk it reads through.
    var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
    defer inner.deinit(gpa);

    const before = counter.allocated_bytes;
    var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **And reading one allocates nothing either**: the value is borrowed out
    // of the value column and the id is a two-word union, so a reader that
    // copied either would move the counter.
    var read: usize = 0;
    while (try walk.next()) |item| {
        read += 1;
        try testing.expect(item.value == .scalar);
    }
    try testing.expectEqual(@as(usize, 1), read);
    try testing.expectEqual(before, counter.allocated_bytes);
}

test "an empty object has no values, and so has an empty row range" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{});
    defer doc.destroy();

    // An op set with no rows: the root's range is empty, and an empty range is
    // a defined read rather than a corner. This is the case upstream's
    // `Option<&OpSet>` and its `Default` exist for
    // ([`automerge.rs:1701-1704`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // a caller with no object has an empty range here, and answers the same way
    // without a second shape.
    const rows = try doc.set.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), rows.end - rows.start);

    var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
    defer inner.deinit(gpa);
    var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

    try testing.expectEqual(@as(usize, 0), walk.range().start);
    try testing.expectEqual(@as(usize, 0), walk.range().end);
    try testing.expect((try walk.next()) == null);
    try testing.expect((try walk.next()) == null);
}

test "a key whose rows are all deleted has no value either" {
    const gpa = testing.allocator;
    // The same shape as keys.zig's deleted-key test, read through `Values`:
    // register "d" is two rows and both are shadowed, so it has no winner and
    // therefore no value. **Not a null value** — a `Values` that answered null
    // here would be indistinguishable from a key that was put and never
    // removed, and the item's id would name an operation no reader can see.
    const s4 = shadows(opId(5, 0));
    const s5 = shadows(opId(6, 0));
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(4, 0), .root, "d", .{ .int = 4 }, &s4),
        mapRow(opId(5, 0), .root, "d", .{ .int = 5 }, &s5),
    });
    defer doc.destroy();

    var inner = try TopQuery(opmod.Op).ofObj(&doc.set, .root, null);
    defer inner.deinit(gpa);
    var walk = Values(opmod.Op, TopQuery(opmod.Op)).init(&doc.set, &inner, null);

    // One value, and it is "a"'s. The loop is bounded by the count below, so a
    // walk that answered `d` would fail the count rather than the contents.
    const only = (try walk.next()).?;
    try testing.expectEqual(@as(i64, 1), intOf(only.value.scalar).?);
    try testing.expectEqual(@as(u32, 1), only.id.opId().?.counter);
    try testing.expect((try walk.next()) == null);
}

comptime {
    // The claim the file makes about its own inners, checked where it is made
    // rather than only in a test.
    _ = Values(opmod.Op, Row);
    _ = Values(opmod.Op, Marked);
    _ = Values(opmod.Op, TopQuery(opmod.Op));
}
