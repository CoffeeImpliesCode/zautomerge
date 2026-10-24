//! The iteration toolkit: the two lookahead wrappers, the skip filter and
//! the diff walkers every read in the iteration phase is composed from
//! (`rust/automerge/src/iter/tools.rs`, 627 lines).
//!
//! These are private items of one file upstream, and the rest of `iter/`
//! composes them. They live here rather than in `hexane/` because **both of the
//! lookahead wrappers can have their lookahead repositioned**, which is the
//! property the whole iteration phase rests on: a walk visits one object, the
//! reader moves it into the next object with `shiftNext`, and nothing is
//! allocated between the two objects. Constructing an iterator allocates nothing.
//!
//! # The two lookahead wrappers, and why both exist
//!
//! [`Unshift`] draws its lookahead in `init`, so `peek` needs no `*Self` and
//! costs nothing ([`shift.rs:238-268`](../../github-automerge-automerge/rust/hexane/src/shift.rs),
//! `iter/tools.rs:27-36`). [`PeekShift`] draws it on the first `peek`
//! (`iter/tools.rs:77-97`). That is the whole difference and it is not
//! cosmetic: `SuccWalker` peeks in a loop and would otherwise need a mutable
//! borrow across an error-returning `next`
//! ([`op_iter.zig:1337-1341`](../opset/op_iter.zig)), and the top-op scan needs
//! the lazy form because the row which terminates one group is the first row of
//! the next and must not be consumed
//! ([`top_op.rs:169-171`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)).
//!
//! # `shift` moves the window; `shiftNext` also reads
//!
//! **They are not interchangeable, and this file does not unify them.**
//! Upstream's `Shiftable::shift` is `set_max` + `advance_to` and returns
//! nothing ([`shift.rs:49-54`](../../github-automerge-automerge/rust/hexane/src/shift.rs));
//! it moves the window *and* the position, because its `advance_to` is
//! infallible. The port's `advanceTo` is fallible — a column that ran out
//! before the walk did is `error.MissingValue` — so the kernel's `shift` is
//! `void` and moves the **window only**
//! ([`column.zig:3603-3605`](../hexane/column.zig)), and reading the row the
//! move landed on is a second step, `shiftNext`
//! ([`shift.rs:56-63`](../../github-automerge-automerge/rust/hexane/src/shift.rs)):
//! `setMax` + `advanceTo` + `next`. An adapter depends on the difference —
//! [`SkipIter`] and [`DiffKernel`] are exactly the composition that cannot
//! express "move the window" in one void call and read in a second.
//!
//! A shift **past the end of a window is a defined answer everywhere**:
//! `shiftNext` answers `null`, and a range that starts *behind* the cursor is
//! `error.InvalidValue` ([`shift.rs:13-14,60`](../../github-automerge-automerge/rust/hexane/src/shift.rs),
//! where upstream asserts and the port refuses). A reader walks off the end of
//! every object it visits, and the last one is no different from the rest.
//!
//! # "The walk is over" and "this row carries nothing" are different answers
//!
//! A lookahead holds `?Item`, and its `Item` is the type *inside* the inner
//! cursor's optional — one layer peeled, never more ([`ItemOf`]). A cursor over
//! a nullable column therefore yields `??T`, where the outer `null` is "the
//! walk is over" and the inner `null` is "this row carries no value".
//! [`column.IterItem`](../hexane/column.zig) uses the same one-layer peel.
//! `MarkIndexColumn.ValueIter` has a different contract: its `next` returns
//! `?MarkIdx` for both an unmarked row and the end of the walk. Use its
//! run cursor when those cases must remain distinct.
//!
//! # Where `ExIdPromise` and `OpSetOrExId` live
//!
//! They are **live** upstream — [`iter/list_range.rs:19,207`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)
//! and [`iter/map_range.rs:19,56`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)
//! both use them — and they are **`pub` in [`map_range.zig`](map_range.zig)
//! now**, not a pending handoff. They are `OpSet`-typed and this toolkit is
//! not, so they live with the reader that holds the `OpSet`; the list reader
//! imports them from there rather than declaring a second copy.
//!
//! # Upstream has two `DiffIter`s, and this file is not the one at `iter.rs:17`
//!
//! **The document-object diff is ported, as [`doc.DiffIter`](doc.zig).**
//! Upstream's `iter.rs:17` (`pub(crate) use doc::DiffIter`) names it —
//! `iter/doc.rs:66`, walked at `iter/doc.rs:306-315` — the walk that goes over
//! a whole document through `MapDiff`/`ListDiff`/`SpansDiff`
//! (`iter/doc.rs:70-72`), fills a `PatchLog` item by item
//! (`DiffIter::log`, `iter/doc.rs:79-92`), and returns a `path_map` from every
//! nested object to its `(prop, parent)` (`iter/doc.rs:129`). **It was not
//! ported when this section was written; the gap is closed.** Four callers in
//! [src/doc.zig](../../src/doc.zig) reach for it, and the walk itself is
//! pinned by the test "the document diff reads the root's rows and then
//! descends into each child, in order" in [`doc.zig`](doc.zig).
//!
//! **The name collision, and why this file's kernel is called `DiffKernel`.**
//! The kernel below is upstream's `iter/tools.rs:528-608`, which upstream
//! *also* calls `DiffIter` and reaches as `iter::tools::DiffIter` — the port
//! was right about the shape and wrong about the name's uniqueness. Two
//! upstream types share that identifier, `iter.rs` re-exports the `doc` one
//! (`iter.rs:17`), and the `tools` one is private to its own module and is
//! never re-exported (`iter.rs:20` re-exports `tools::Diff`, the `Same`/`Add`/
//! `Del` tag at `iter/tools.rs:610-616`, and nothing else of `tools`).
//! `DiffKernel` keeps the name `DiffIter` meaning the document diff in every
//! `src/` file — the one thing upstream's `iter.rs` names on that line — and
//! [`doc.zig`](doc.zig) gives the document one that name.
//!
//! **Nothing about the port changed but the name.** The declaration, the eight
//! forwarders, its three constructors and every test below are upstream's
//! `iter/tools.rs:528-608` item for item, and the citations say so.

const std = @import("std");
const err = @import("../error.zig");
const column = @import("../hexane/column.zig");

const Allocator = std.mem.Allocator;
const ParseError = err.ParseError;

/// A half-open range of rows — upstream's `Range<usize>`, the argument every
/// `shift` and `shift_next` takes ([`shift.rs:51`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
///
/// Re-exported because every entry point below takes one, and a consumer of
/// this file should not have to import `hexane/column.zig` to name it.
pub const RowRange = column.RowRange;

/// The repositioning kernel ([`Shiftable`], `shift.rs:9-100`).
///
/// Re-exported rather than redeclared: [src/hexane/column.zig](../hexane/column.zig)
/// already spells a trait as a comptime check over the eight method names
/// (`pos`, `maxPos`, `setMax`, `advanceTo`, `advanceBy`, `shift`, `shiftNext`,
/// `seekTo` — `shift.rs:19-74` upstream), and a second spelling would be a
/// second source of truth. Instantiating it *is* the check.
pub const Shiftable = column.Shiftable;

/// A skipper over a boolean column, which is what the op set's visibility and
/// top-op walks are built from ([`BoolColumnSkipper`], `iter/tools.rs:306-383`).
///
/// Re-exported for the same reason: it is declared in
/// [src/hexane/column.zig](../hexane/column.zig) beside the column cursor it
/// reads, and this file's diff skippers are built on it.
pub const BoolColumnSkipper = column.BoolColumnSkipper;

// ── What a cursor is ────────────────────────────────────────────────────────

/// The name of the method that is a cursor's step: `next`, or `tryNext` for a
/// walk whose item type is *total* so its step cannot answer "no more"
/// ([`op_iter.zig:1085-1088`](../opset/op_iter.zig)).
fn stepNameOf(comptime I: type) []const u8 {
    if (comptime @hasDecl(I, "next")) return "next";
    if (comptime @hasDecl(I, "tryNext")) return "tryNext";
    @compileError("a cursor needs a step: `next`, or `tryNext` when its item type is total");
}

/// The type `I.name` returns.
fn returnOf(comptime I: type, comptime name: []const u8) type {
    return @typeInfo(@TypeOf(@field(I, name))).@"fn".return_type.?;
}

/// The error set `I.name` can raise, or the empty set when it cannot fail.
fn errSetOf(comptime I: type, comptime name: []const u8) type {
    return switch (@typeInfo(returnOf(I, name))) {
        .error_union => |e| e.error_set,
        else => error{},
    };
}

/// The item a cursor of type `I` yields (`iter/tools.rs:44-58`).
///
/// The error union comes off, and then **exactly one** optional layer — never
/// more, and that is the whole point:
///
/// * A cursor whose step is `E!?T` has item `T`, and a lookahead over it is
///   `?T`: the outer `null` is "the walk is over".
/// * A nullable cursor whose step is `E!(??T)` has item `?T`,
///   and a lookahead over it is `??T`: the outer `null` is "the walk is over"
///   and the inner `null` is "this row carries no value". Both are answers, and
///   a reader needs both.
///
/// [`column.IterItem`](../hexane/column.zig) removes the error union and one
/// end-of-stream optional, preserving the nullable item in the second case.
pub fn ItemOf(comptime I: type) type {
    const ret = returnOf(I, stepNameOf(I));
    const peeled = switch (@typeInfo(ret)) {
        .error_union => |e| e.payload,
        else => ret,
    };
    return switch (@typeInfo(peeled)) {
        .optional => |o| o.child,
        else => peeled,
    };
}

/// What a wrapper over `I` can raise: `I`'s step error set, and the error set
/// of `shiftNext` when `I` has one.
///
/// **Inferred, never declared**, because the halves of every composition below
/// do not raise the same errors: a column cursor is [`ParseError`](../../src/error.zig),
/// the op set's rows add `ReadOpError`, and the top-op scan adds the
/// document's `Error`. Upstream's `I: Iterator` bounds let each raise its own,
/// and the port's wrappers do the same by letting the union be inferred.
pub fn ErrorOf(comptime I: type) type {
    var e = errSetOf(I, stepNameOf(I));
    if (comptime @hasDecl(I, "shiftNext")) e = e || errSetOf(I, "shiftNext");
    return e;
}

/// Whether `I` carries the whole [`Shiftable`] kernel
/// ([`shift.rs:19-74`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
fn hasKernel(comptime I: type) bool {
    inline for (.{
        "pos",       "maxPos", "setMax",    "advanceTo",
        "advanceBy", "shift",  "shiftNext", "seekTo",
    }) |name| {
        if (!@hasDecl(I, name)) return false;
    }
    return true;
}

/// The next item of `q`, from whichever of the two step spellings it has.
fn nextOf(comptime Item: type, q: anytype) !?Item {
    if (comptime @hasDecl(@TypeOf(q.*), "next")) return q.next();
    if (comptime @hasDecl(@TypeOf(q.*), "tryNext")) return try q.tryNext();
    @compileError("a cursor needs a step: `next`, or `tryNext` when its item type is total");
}

/// The next position of a walk of `usize` positions.
fn stepOf(w: anytype) !?usize {
    const v = (try nextOf(usize, w)) orelse return null;
    return std.math.cast(usize, v) orelse return error.Overflow;
}

/// The item `skip` rows past `q`'s current position, consuming the rows
/// between.
///
/// Upstream's is one `nth` call on an `Iterator`
/// ([`iter/tools.rs:174-182`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
/// and the port's walks do not share one entry point, so the choice is made
/// at comptime:
///
/// * `tryNth` when the walk has one — [`op_iter.OpIter`](../opset/op_iter.zig),
///   the only walk that is a row cursor, and O(log S) for the same reason;
/// * `shiftNext` when the walk is a *pair* of cursors, which repositions both
///   at once;
/// * a plain walk when the walk is a *filter* with no positional entry point,
///   which is the same answer one row at a time and the only one a filter can
///   give.
///
/// **A skip of zero is a plain `next`, never a zero-`nth`** — but only when the
/// walk's step is the *partial* one, and that qualification is the whole point.
/// The hexane column iterators make `nth(0)` a real index descent, and upstream
/// branches on it for exactly that reason
/// ([`iter/tools.rs:596-604`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// Upstream's `iter` is a Rust `Iterator`, so its `next` is partial and answers
/// null at the end of the walk. The port has **two** step spellings and only one
/// of them is partial: [`op_iter.OpIter`](../opset/op_iter.zig) and every
/// column cursor say `next` and answer null, while a walk that says `tryNext`
/// ([`op_iter.ActionValueIter`](../opset/op_iter.zig), `op_iter.zig:1085-1088`)
/// is *total* and answers `error.MissingValue` at the end instead. So a zero
/// skip may only be answered by the step that can say "there is no next row";
/// a walk with no partial step falls through to the positional forms, which are
/// partial, and answers null the way upstream does.
///
/// **This is not a corner.** Every skipper gives "one more answer after the last
/// kept row" ([`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
/// and that answer is the distance from the last kept row to the end of the
/// window — which is *zero* whenever the last row of the window is kept
/// ([`column.BoolColumnSkipper.next`](../hexane/column.zig)). So a zero skip is
/// asked for at the end of every window, and a total step would raise
/// `error.MissingValue` there where upstream returns `None`.
fn takeAt(comptime Item: type, q: anytype, skip: usize) !?Item {
    const partial = comptime @hasDecl(@TypeOf(q.*), "next");
    if (skip == 0 and partial) return q.next();
    if (comptime @hasDecl(@TypeOf(q.*), "tryNth")) return q.tryNth(skip);
    if (comptime @hasDecl(@TypeOf(q.*), "shiftNext")) {
        const end = q.maxPos();
        return q.shiftNext(.{ .start = q.pos() + skip, .end = end });
    }
    var left = skip;
    while (true) {
        const item = try nextOf(Item, q);
        if (left == 0) return item;
        left -= 1;
    }
}

// ── Diff ────────────────────────────────────────────────────────────────────

/// What happened to a row between two states of a range (`Diff`,
/// [`iter/tools.rs:610-616`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// Upstream's default variant is `Same`
/// ([`iter/tools.rs:612`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
/// which is this file's first tag: the order is upstream's and `same` is first
/// because it is the case a walk meets most. The tags are the port's own and
/// carry nothing on the wire.
pub const Diff = enum {
    same,
    add,
    del,

    /// Whether the row is gone from the later state (`Diff::is_del`,
    /// [`iter/tools.rs:618-620`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    pub fn isDel(self: Diff) bool {
        return self == .del;
    }

    /// Whether the row survives into the later state (`Diff::is_visible`,
    /// [`iter/tools.rs:622-624`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    ///
    /// A `Del` row is not a row in the later state; every other one is. This
    /// is the predicate a consumer filters on
    /// ([`map_range.rs:260`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)).
    pub fn isVisible(self: Diff) bool {
        return self != .del;
    }
};

/// One answer of a diff skipper: what happened, and how far the walk has to
/// step to reach the row it happened to
/// (`(Diff, usize)`, [`iter/tools.rs:477-489`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
pub const Skip = struct {
    /// What happened to the row.
    diff: Diff,
    /// Rows to step over from where the walk stands.
    at: usize,
};

// ── Unshift ─────────────────────────────────────────────────────────────────

/// An iterator with its lookahead already drawn ([`Unshift`], `shift.rs:238-294`;
/// [`iter/tools.rs:12-57`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// `init` draws the first item *before* the struct is built, so the cursor
/// stored beside the lookahead is the one that drew it. Building from the
/// un-advanced cursor and advancing a copy afterwards stores a cursor one item
/// behind the lookahead and `next` hands the first item back twice
/// ([`shift.rs:259-263`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
///
/// **This is [`column.Unshift`](../hexane/column.zig) generalised over the item
/// and the error set, with the one-layer peel the column layer does not do** —
/// see [`ItemOf`] and the module's fourth section. The working consumer is
/// [`SuccWalker`](../opset/op_iter.zig), which holds one as a field, peeks it in
/// a loop and pulls from it; every method here is spelled the way that consumer
/// spells it, and the field is `inner` because that consumer reaches through it
/// to free the descent's stack.
pub fn Unshift(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The item a lookahead over `I` holds, one optional layer peeled
        /// ([`ItemOf`]).
        pub const Item = ItemOf(I);

        /// What reading the wrapper can raise ([`ErrorOf`]).
        pub const Error = ErrorOf(I);

        /// The cursor, one item ahead of the lookahead.
        inner: I,
        /// The item `next` will hand back, already drawn. Null once the inner
        /// cursor is spent, and after a `shift` that found nothing.
        ///
        /// When [`Item`] is itself optional this is a *second* layer of
        /// optional and the two are different answers: see the module's fourth
        /// section.
        held: ?Item,

        /// A wrapper over `inner` with its first item already pulled
        /// ([`Unshift::new`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:259-263`).
        ///
        /// Allocates nothing: the lookahead is a field beside the cursor the
        /// caller already owns.
        pub fn init(inner: I) Error!Self {
            var cursor = inner;
            const held = try cursor.next();
            return .{ .inner = cursor, .held = held };
        }

        /// The item `next` will return, without consuming it
        /// ([`Unshift::peek`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:265-267`).
        ///
        /// Needs no mutable self, which is the reason this shape exists rather
        /// than [`PeekShift`]: `SuccWalker.next` peeks in a loop and then calls
        /// a fallible `next`, and a `*Self` peek would hold a mutable borrow
        /// across it.
        pub fn peek(self: *const Self) ?Item {
            return self.held;
        }

        /// Whether the inner cursor is spent, which is the *outer* `null` and
        /// nothing else.
        ///
        /// When [`Item`] is optional this is the distinction the recorded trap
        /// turns on: `exhausted` is true only once the walk is over, and a row
        /// whose own value is absent leaves it false.
        pub fn exhausted(self: *const Self) bool {
            return self.held == null;
        }

        /// Repositions the inner cursor to `range` and refills the lookahead
        /// from the range's start ([`Unshift::shift`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:270-274`).
        ///
        /// This is upstream's `shift_next` under the port's name, not the
        /// kernel's window-only `shift`: it moves *and* reads, and a range that
        /// starts behind the cursor is `error.InvalidValue`.
        pub fn shift(self: *Self, range: RowRange) Error!void {
            if (comptime !@hasDecl(I, "shiftNext")) @compileError(
                "a lookahead can only be repositioned over a cursor that carries shiftNext",
            );
            self.held = try self.inner.shiftNext(range);
        }

        /// The next item, pulling one more behind it
        /// ([`Iterator::next` for `Unshift`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:276-283`).
        pub fn next(self: *Self) Error!?Item {
            const out = self.held;
            self.held = try self.inner.next();
            return out;
        }
    };
}

// ── PeekShift ───────────────────────────────────────────────────────────────

/// A peekable cursor whose lookahead can be discarded
/// ([`PeekShift`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:66-113`).
///
/// Unlike a plain peekable the lookahead is *repositionable*: `shift` throws it
/// away and refills it from the start of a new range. Unlike [`Unshift`] the
/// lookahead is drawn on the first `peek` rather than in `init`
/// ([`iter/tools.rs:77-97`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
/// against `shift.rs:259-263`) — a `PeekShift` over an empty range does no read
/// at all until something asks it to.
///
/// `TopIter`'s scan flavour is the user: the row that terminates one group is
/// the first row of the next
/// ([`top_op.rs:169-171`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)),
/// so the boundary row must be held rather than consumed, and a shift to the
/// next object's range must not leave a stale one behind.
pub fn PeekShift(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The item the lookahead holds, one optional layer peeled
        /// ([`ItemOf`]).
        pub const Item = ItemOf(I);

        /// What reading the wrapper can raise ([`ErrorOf`]).
        pub const Error = ErrorOf(I);

        inner: I,
        /// The item `next` will hand back. Null once the inner cursor is spent,
        /// and after a `shift` that found nothing — and, as for [`Unshift`], a
        /// *separate* answer from an item that is itself null.
        held: ?Item,
        /// Whether the lookahead has been drawn. **This flag is the whole
        /// difference from [`Unshift`].**
        drawn: bool,

        /// A wrapper over `inner` that reads nothing yet
        /// ([`PeekShift::new`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:79-82`).
        ///
        /// Allocates nothing, and unlike [`Unshift.init`] it cannot fail: there
        /// is no read to fail.
        pub fn init(inner: I) Self {
            return .{ .inner = inner, .held = null, .drawn = false };
        }

        /// The item `next` will return, drawing it on the first call
        /// ([`PeekShift::peek`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:84-90`).
        pub fn peek(self: *Self) Error!?Item {
            if (!self.drawn) {
                self.held = try self.inner.next();
                self.drawn = true;
            }
            return self.held;
        }

        /// Whether the lookahead has been drawn, read without drawing it, so a
        /// caller can tell a wrapper that has read from one that has not.
        pub fn isDrawn(self: *const Self) bool {
            return self.drawn;
        }

        /// Repositions the inner cursor to `range`, discarding the lookahead,
        /// and refills it from the range's start
        /// ([`PeekShift::shift`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:99-105`).
        pub fn shift(self: *Self, range: RowRange) Error!void {
            if (comptime !@hasDecl(I, "shiftNext")) @compileError(
                "a lookahead can only be repositioned over a cursor that carries shiftNext",
            );
            self.held = try self.inner.shiftNext(range);
            self.drawn = true;
        }

        /// The next item, pulling one more behind it
        /// ([`Iterator::next` for `PeekShift`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:107-113`).
        pub fn next(self: *Self) Error!?Item {
            if (!self.drawn) return self.inner.next();
            const out = self.held;
            self.held = try self.inner.next();
            return out;
        }

        /// The next item when `pred` accepts it, leaving it as the lookahead
        /// otherwise ([`PeekShift::next_if`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:88-96`).
        ///
        /// **The predicate is a named function, not a closure**, because Zig
        /// cannot hand a capture to a function pointer. `arg` is whatever the
        /// predicate needs beside the item — the top scan passes the group key
        /// ([`top_op.rs:250`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs)).
        pub fn nextIf(
            self: *Self,
            arg: anytype,
            comptime pred: fn (Item, @TypeOf(arg)) bool,
        ) Error!?Item {
            const held = (try self.peek()) orelse return null;
            if (!pred(held, arg)) return null;
            return self.next();
        }
    };
}

// ── SkipWrap ────────────────────────────────────────────────────────────────

/// An increasing walk of row positions turned into the *distances* between them
/// ([`SkipWrap`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:115-138`).
///
/// The skipper protocol upstream is a walk of counts, not a walk of positions
/// ([`iter/tools.rs:60`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
/// and this is the adapter between the two. [`MergeIter.skip`] is its
/// constructor upstream ([`iter/tools.rs:267-275`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
pub fn SkipWrap(comptime I: type) type {
    return struct {
        const Self = @This();

        /// The position the next distance is measured from
        /// ([`SkipWrap::pos`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:117`).
        pos: usize,
        inner: I,

        /// Distances from `pos`, over a walk of positions (`SkipWrap::new`,
        /// `iter/tools.rs:123-127`).
        pub fn init(pos: usize, inner: I) Self {
            return .{ .pos = pos, .inner = inner };
        }

        /// The next distance, or null once the walk is spent
        /// ([`Iterator::next` for `SkipWrap`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:129-138`).
        ///
        /// A position at or behind `pos` gives a distance of zero rather than a
        /// trap. Upstream's `pos - self.pos` is an unchecked subtraction
        /// ([`iter/tools.rs:134`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs));
        /// the contract is that a skipper's positions increase, and saturating
        /// turns a caller that breaks it into a zero skip instead of a panic.
        pub fn next(self: *Self) !?usize {
            const p = (try stepOf(&self.inner)) orelse return null;
            const delta = p -| self.pos;
            self.pos = p + 1;
            return delta;
        }
    };
}

// ── MergeIter ───────────────────────────────────────────────────────────────

/// Two walks of increasing positions merged into one, with the duplicates they
/// share thrown out ([`MergeIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:246-304`).
///
/// The successor walks of an op set are two such walks over two columns, and
/// their union is what a `SkipIter` over "every row that owns a successor"
/// needs ([`op_set.rs:1256-1263`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
pub fn MergeIter(comptime I: type, comptime J: type) type {
    return struct {
        const Self = @This();

        left: I,
        right: J,
        /// The left walk's next position, and whether it has been drawn
        /// (`Peekable`, `iter/tools.rs:249`).
        left_ahead: usize = 0,
        left_drawn: bool = false,
        right_ahead: usize = 0,
        right_drawn: bool = false,
        /// The last position handed out, which is what makes a duplicate a
        /// duplicate ([`last_yielded`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:253`).
        last: ?usize = null,

        /// The merged walk of `left` and `right`
        /// ([`MergeIter::new`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:258-265`).
        pub fn init(left: I, right: J) Self {
            return .{ .left = left, .right = right };
        }

        /// The merged walk as a walk of distances
        /// ([`MergeIter::skip`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:267-275`).
        pub fn skip(self: Self) SkipWrap(Self) {
            const pos = if (self.last) |n| n + 1 else 0;
            return SkipWrap(Self).init(pos, self);
        }

        /// The next position of the left walk, without consuming it.
        fn leftStep(self: *Self) !?usize {
            if (self.left_drawn) return self.left_ahead;
            self.left_ahead = (try stepOf(&self.left)) orelse return null;
            self.left_drawn = true;
            return self.left_ahead;
        }

        /// The next position of the right walk, without consuming it.
        fn rightStep(self: *Self) !?usize {
            if (self.right_drawn) return self.right_ahead;
            self.right_ahead = (try stepOf(&self.right)) orelse return null;
            self.right_drawn = true;
            return self.right_ahead;
        }

        /// The next position of the union, or null at the end of both
        /// ([`Iterator::next` for `MergeIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:277-304`).
        ///
        /// Upstream's arm for two equal heads advances *both* and keeps one,
        /// which is what drops a position both walks hold; the loop's second
        /// test drops a position already handed out.
        pub fn next(self: *Self) !?usize {
            while (true) {
                const l = try self.leftStep();
                const r = try self.rightStep();
                if (l == null and r == null) return null;
                const out: usize = if (r == null or (l != null and l.? < r.?))
                    (try self.leftTake()).?
                else if (l == null or r.? < l.?)
                    (try self.rightTake()).?
                else blk: {
                    _ = try self.leftTake();
                    break :blk (try self.rightTake()).?;
                };
                if (self.last == null or self.last.? != out) {
                    self.last = out;
                    return out;
                }
            }
        }

        /// Consumes the left walk's held position and draws the next one.
        fn leftTake(self: *Self) !?usize {
            const out = (try self.leftStep()) orelse return null;
            self.left_drawn = false;
            return out;
        }

        /// Consumes the right walk's held position and draws the next one.
        fn rightTake(self: *Self) !?usize {
            const out = (try self.rightStep()) orelse return null;
            self.right_drawn = false;
            return out;
        }
    };
}

// ── SkipIter ────────────────────────────────────────────────────────────────

/// A row walk thinned by a skipper ([`SkipIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
/// `iter/tools.rs:140-185`).
///
/// One type and three uses, which is the whole point: "these rows, thinned by
/// that walk" is [`OpSet.visible`](../opset/op_set.zig),
/// [`OpSet.actionValueIter`](../opset/op_set.zig) and
/// [`OpSet.actionValueTopIter`](../opset/op_set.zig) alike, and none of them is
/// a new iterator — all three instantiate *this*, from
/// [src/opset/op_set.zig](../opset/op_set.zig), which used to carry a second
/// copy of this shape for its own use. `Item` is named rather than derived
/// because one of the three yields an op and the other two yield an
/// action/value pair, and an item type is part of a walk's signature.
///
/// The three instantiations are between them **all four** of the inner shapes
/// [`takeAt`] dispatches on: a row cursor with `tryNth`, a pair of cursors
/// with `shiftNext`, a filter with neither, and — through
/// [`op_iter.ActionValueIter`](../opset/op_iter.zig) — a pair of cursors whose
/// step is *total*. The last is why [`takeAt`]'s zero-skip arm is written the
/// way it is, and `test "a zero skip is answered by a partial step, and never
/// by a total one"` below is the guard on it.
pub fn SkipIter(comptime Item: type, comptime Q: type, comptime S: type) type {
    return struct {
        const Self = @This();
        const ShiftCursorError = if (@hasDecl(Q, "shift")) errSetOf(Q, "shift") else error{};

        /// The rows, thinned (`iter/tools.rs:141-142`).
        iter: Q,
        /// Which rows to keep, as a count of rows to step over
        /// ([`iter/tools.rs:143`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        skip: S,

        /// Whether this instantiation is a [`Shiftable`] cursor: `Q` carries the
        /// whole kernel and `S` can be repositioned.
        ///
        /// A filter with no positional entry point cannot be repositioned, and
        /// saying so is better than a mark that instantiates over bodies that
        /// would not compile if they were ever called.
        pub fn isShiftable() bool {
            return comptime hasKernel(Q) and @hasDecl(S, "shiftNext");
        }

        /// The [`Shiftable`] conformance mark when [`isShiftable`], and null when
        /// it is not. Its instantiation *is* the check
        /// ([`impl Shiftable for SkipIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:165-172`).
        pub const shiftable: ?type = if (isShiftable()) Shiftable(Self) else null;

        /// The walk `SkipIter::new`, `iter/tools.rs:155-163`. Allocates nothing:
        /// both halves are cursors the caller built.
        pub fn init(iter: Q, skip: S) Self {
            return .{ .iter = iter, .skip = skip };
        }

        /// The next kept row, or null once the skipper is spent
        /// ([`Iterator::next` for `SkipIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:174-185`).
        ///
        /// Upstream's shape exactly: ask the skipper how far the next row is,
        /// then take that row. The error set is **inferred**, because the two
        /// halves do not raise the same errors and upstream's `S: Skipper` /
        /// `I: Iterator` bounds let each raise its own.
        pub fn next(self: *Self) !?Item {
            const skip = (try self.skip.next()) orelse return null;
            return takeAt(Item, &self.iter, skip);
        }

        /// The walk behind it ([`SkipIter::inner`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:163`).
        pub fn inner(self: *const Self) *const Q {
            return &self.iter;
        }

        /// The skipper behind it, for a caller that wants to reposition it.
        pub fn skipper(self: *Self) *S {
            return &self.skip;
        }

        // ── The kernel ───────────────────────────────────────────────────
        //
        // Eight forwarders onto the walk. Upstream's `Shiftable` is a
        // one-method trait (`iter/tools.rs:62-64`) and `SkipIter` implements
        // only `shift_next`; the port's kernel is the eight names of
        // `shift.rs:19-74`, and a wrapper that cannot honour all eight is not
        // a cursor — which is what [`isShiftable`] reports.

        /// The row the next `next` returns ([`shift.rs:20-22`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// The end of the walk's window ([`shift.rs:23-25`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the window at `at` ([`shift.rs:26-27`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`
        /// ([`shift.rs:34-40`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn advanceTo(self: *Self, target: usize) !void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows ([`shift.rs:42-47`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn advanceBy(self: *Self, amount: usize) !void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the walk onto `rows` ([`Shiftable::shift`](../../github-automerge-automerge/rust/hexane/src/shift.rs), `shift.rs:50-55`).
        ///
        /// **The kernel moves and the skipper does not.** A skipper's only
        /// repositioning entry point is `shiftNext`
        /// ([`iter/tools.rs:60-64`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
        /// and calling it here would consume the very skip the caller is about
        /// to read. Upstream has no `shift` on `SkipIter` at all for the same
        /// reason — `shiftNext` is the one that exists
        /// ([`iter/tools.rs:165-172`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        /// So the pair is repositioned only by [`shiftNext`](SkipIter.shiftNext)
        /// below, and this one is a reposition of the row cursor alone:
        /// `pos()` afterwards is the kernel's.
        pub fn shift(self: *Self, rows: RowRange) ShiftCursorError!void {
            return self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the first kept row in it
        /// ([`Shiftable::shift_next` for `SkipIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:165-172`).
        ///
        /// The skipper answers how far into `rows` the first kept row is, and
        /// the walk is asked for that row. A skipper that is spent answers
        /// null, which upstream turns into a skip of zero
        /// ([`iter/tools.rs:167`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)) and
        /// this port keeps, because a range with no kept row must answer the
        /// first row of the range rather than nothing.
        pub fn shiftNext(self: *Self, rows: RowRange) !?Item {
            if (comptime !@hasDecl(S, "shiftNext")) @compileError(
                "a SkipIter can only be repositioned over a skipper that carries shiftNext",
            );
            const skip = (try self.skip.shiftNext(rows)) orelse 0;
            return self.iter.shiftNext(.{ .start = rows.start + skip, .end = rows.end });
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk ([`shift.rs:65-74`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn seekTo(self: *Self, at: usize) !?Item {
            return self.iter.seekTo(at);
        }
    };
}

// ── PastSkipper ─────────────────────────────────────────────────────────────

/// Two skippers, one over each state of a range, and what changed between them
/// ([`PastSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:385-390`,
/// `:432-475`, `:491-502`).
///
/// Upstream declares this private; the port declares it `pub` because
/// [`DiffSkipper`] is the tag that holds it and a consumer of a diff needs to
/// name what it is holding. It is a skipper over `(Diff, usize)` rather than
/// over `usize`, which is the one thing about it that is not a plain skipper.
pub fn PastSkipper(comptime S: type) type {
    return struct {
        const Self = @This();

        /// The two skips this step compares, one pair per step
        /// ([`PastSkipper::next_skip`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:461-475`).
        const Gap = struct { before: usize, after: usize };

        /// The skipper over the earlier state.
        before: S,
        /// The skipper over the later state.
        after: S,
        /// What the last step decided, and what is left of a gap it opened
        /// ([`state`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:389`).
        ///
        /// The default is `(Same, 0)`, upstream's `#[derive(Default)]` on a
        /// `(Diff, usize)` field ([`iter/tools.rs:385`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs))
        /// — a `PastSkipper` starts by comparing the two skippers head to head.
        state: Skip = .{ .diff = .same, .at = 0 },

        /// A walker over the two states
        /// ([`PastSkipper::new`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:433-439`).
        pub fn init(before: S, after: S) Self {
            return .{ .before = before, .after = after, .state = .{ .diff = .same, .at = 0 } };
        }

        /// The two skips this step compares, opening a gap if one side is
        /// further ahead ([`PastSkipper::progress`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:441-459`).
        ///
        /// `before < after` means the earlier state has a row the later one does
        /// not — it is *deleted* — and the later skipper is told how much further
        /// it still has to go. `before > after` is the mirror: a row the later
        /// state added. Equal means the row is in both, and the gap closes.
        fn progress(self: *Self, before: usize, after: usize) Skip {
            if (before == after) {
                self.state = .{ .diff = .same, .at = 0 };
                return .{ .diff = .same, .at = before };
            }
            if (before < after) {
                self.state = .{ .diff = .del, .at = after - before - 1 };
                return .{ .diff = .del, .at = before };
            }
            self.state = .{ .diff = .add, .at = before - after - 1 };
            return .{ .diff = .add, .at = after };
        }

        /// The two skips the next step compares
        /// ([`PastSkipper::next_skip`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:461-475`).
        ///
        /// A gap is closed by reading **one** side and carrying the other side's
        /// remaining distance, which is why `before` and `after` are not read
        /// together once a gap is open.
        fn nextSkip(self: *Self) !?Gap {
            switch (self.state.diff) {
                .same => {
                    const before = (try stepOf(&self.before)) orelse return null;
                    const after = (try stepOf(&self.after)) orelse return null;
                    return .{ .before = before, .after = after };
                },
                .del => {
                    const before = (try stepOf(&self.before)) orelse return null;
                    return .{ .before = before, .after = self.state.at };
                },
                .add => {
                    const after = (try stepOf(&self.after)) orelse return null;
                    return .{ .before = self.state.at, .after = after };
                },
            }
        }

        /// The next step of the diff, or null once either state is spent
        /// ([`Iterator::next` for `PastSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:491-502`).
        pub fn next(self: *Self) !?Skip {
            const gap = (try self.nextSkip()) orelse return null;
            return self.progress(gap.before, gap.after);
        }

        /// Repositions both skippers to `rows` and reads the step that lands
        /// there ([`Shiftable for PastSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:516-526`).
        pub fn shiftNext(self: *Self, rows: RowRange) !?Skip {
            if (comptime !@hasDecl(S, "shiftNext")) @compileError(
                "a PastSkipper can only be repositioned over skippers that carry shiftNext",
            );
            const before = (try self.before.shiftNext(rows)) orelse return null;
            const after = (try self.after.shiftNext(rows)) orelse return null;
            return self.progress(before, after);
        }
    };
}

// ── DiffSkipper ─────────────────────────────────────────────────────────────

/// Which of the two skippers a diff is reading
/// ([`DiffSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:392-396`).
///
/// A diff is either against a *current* state — every row the skipper keeps is
/// an addition, because there is nothing to compare it with — or *between* two
/// states. Upstream picks the arm from a `ClockRange`
/// ([`iter/tools.rs:404-430`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs));
/// the port's two constructors are that choice written out, so the slice that
/// holds the document picks the arm with one call.
pub fn DiffSkipper(comptime S: type) type {
    return struct {
        const Self = @This();

        /// The step this skipper yields
        /// ([`Iterator::next` for `DiffSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:477-489`).
        pub const Step = Skip;

        inner: union(enum) {
            /// One state: everything the skipper keeps is new
            /// ([`iter/tools.rs:479`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
            current: S,
            /// Two states ([`iter/tools.rs:478`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
            past: PastSkipper(S),
        },

        /// A diff against one state, where every kept row is an addition
        /// ([`iter/tools.rs:479`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        pub fn current(one: S) Self {
            return .{ .inner = .{ .current = one } };
        }

        /// A diff between two states
        /// ([`iter/tools.rs:481`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        pub fn past(before: S, after: S) Self {
            return .{ .inner = .{ .past = PastSkipper(S).init(before, after) } };
        }

        /// The next step of the diff, or null
        /// ([`iter/tools.rs:477-489`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        pub fn next(self: *Self) !?Step {
            return switch (self.inner) {
                .current => |*one| blk: {
                    const at = (try stepOf(one)) orelse return null;
                    break :blk Skip{ .diff = .add, .at = at };
                },
                .past => |*two| two.next(),
            };
        }

        /// Repositions the skipper to `rows` and reads the step that lands there
        /// ([`Shiftable for DiffSkipper`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:504-514`).
        pub fn shiftNext(self: *Self, rows: RowRange) !?Step {
            if (comptime !@hasDecl(S, "shiftNext")) @compileError(
                "a DiffSkipper can only be repositioned over skippers that carry shiftNext",
            );
            return switch (self.inner) {
                .current => |*one| blk: {
                    const at = (try one.shiftNext(rows)) orelse return null;
                    break :blk Skip{ .diff = .add, .at = at };
                },
                .past => |*two| two.shiftNext(rows),
            };
        }
    };
}

// ── DiffKernel ───────────────────────────────────────────────────────────────

/// A row walk tagged with what happened to each row between two states of a
/// range ([`iter/tools.rs:528-608`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// **Upstream declares this as `DiffIter` and this port does not, because
/// upstream has two types by that name and `iter.rs` exports the other one.**
/// See the module's section on the collision: this is upstream's `tools` diff
/// over a *range of rows*, not the document-object diff `iter.rs:17` exports,
/// and the two were sharing one identifier in the port.
///
/// **This is the iterator a range diff and a patch are built on**: it answers
/// "what changed between these two positions of this range", and applying its
/// answers to the earlier state produces the later one. That last sentence is
/// the property its tests hold, and it is stronger than any count.
///
/// `Q` may be a single column cursor or a walk over several
/// ([`iter/tools.rs:529-536`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs) — the
/// upstream instantiations cover both `MapIter`/`ListIter` and
/// `ActionValueIter`); the type is the same either way.
pub fn DiffKernel(comptime Item: type, comptime Q: type, comptime S: type) type {
    return struct {
        const Self = @This();
        const ShiftCursorError = if (@hasDecl(Q, "shift")) errSetOf(Q, "shift") else error{};

        /// One row of the diff: what happened, and the row
        /// (`(Diff, I::Item)`, `iter/tools.rs:596-608`).
        pub const Entry = struct {
            /// What happened to the row.
            diff: Diff,
            /// The row itself, read out of the walk.
            item: Item,
        };

        /// The rows the diff reads.
        iter: Q,
        /// Which rows to keep, and what happened to them.
        skipper: DiffSkipper(S),

        /// Whether this instantiation is a [`Shiftable`] cursor.
        pub fn isShiftable() bool {
            return comptime hasKernel(Q) and @hasDecl(S, "shiftNext");
        }

        /// The [`Shiftable`] conformance mark when [`isShiftable`]
        /// ([`iter/tools.rs:578-589`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs) — upstream's `impl Shiftable` for this kernel).
        pub const shiftable: ?type = if (isShiftable()) Shiftable(Self) else null;

        /// A diff over `iter`, with `skipper` deciding which rows it reads
        /// ([`iter/tools.rs:553-561`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs) — upstream's `new`).
        pub fn init(iter: Q, skipper: DiffSkipper(S)) Self {
            return .{ .iter = iter, .skipper = skipper };
        }

        /// A diff against one state, where every kept row is an addition
        /// ([`DiffSkipper::Current`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:479`).
        pub fn initCurrent(iter: Q, one: S) Self {
            return init(iter, DiffSkipper(S).current(one));
        }

        /// A diff between two states
        /// ([`DiffSkipper::Diff`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs), `iter/tools.rs:481`).
        pub fn initDiff(iter: Q, before: S, after: S) Self {
            return init(iter, DiffSkipper(S).past(before, after));
        }

        /// The next row, tagged with what happened to it, or null
        /// ([`iter/tools.rs:591-608`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs) — upstream's `Iterator::next`).
        ///
        /// Upstream branches on `skip == 0` so a zero skip is a `next` and not a
        /// `nth(0)`, which is "noticeably slower for column iterators"
        /// ([`iter/tools.rs:596-604`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs));
        /// [`takeAt`] keeps that branch. A skip the walk cannot serve ends the
        /// walk, which is the "one more answer after the last kept row" every
        /// skipper gives ([`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        pub fn next(self: *Self) !?Entry {
            const step = (try self.skipper.next()) orelse return null;
            const item = (try takeAt(Item, &self.iter, step.at)) orelse return null;
            return .{ .diff = step.diff, .item = item };
        }

        /// The walk behind it, for a caller that wants the rows themselves.
        pub fn inner(self: *const Self) *const Q {
            return &self.iter;
        }

        // ── The eight forwarders ────────────────────────────────────────
        //
        // Eight forwarders onto the walk, as for [`SkipIter`]. Upstream's
        // `Shiftable` has one method and upstream's kernel implements `shift_next`
        // alone (`iter/tools.rs:578-589`); the port's `Shiftable` has eight, and
        // a wrapper that cannot honour all of them is not a cursor.

        /// The row the next `next` returns ([`shift.rs:20-22`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn pos(self: *const Self) usize {
            return self.iter.pos();
        }

        /// The end of the walk's window ([`shift.rs:23-25`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn maxPos(self: *const Self) usize {
            return self.iter.maxPos();
        }

        /// Truncates the window at `at` ([`shift.rs:26-27`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn setMax(self: *Self, at: usize) void {
            self.iter.setMax(at);
        }

        /// Advances so the next `next` is the row at `target`
        /// ([`shift.rs:34-40`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn advanceTo(self: *Self, target: usize) !void {
            return self.iter.advanceTo(target);
        }

        /// Advances past `amount` rows ([`shift.rs:42-47`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        pub fn advanceBy(self: *Self, amount: usize) !void {
            return self.iter.advanceBy(amount);
        }

        /// Moves the row cursor onto `rows`, propagating its exact shift
        /// error set. The skipper is untouched until [`shiftNext`], which
        /// is the pairing [`SkipIter.shift`] documents.
        pub fn shift(self: *Self, rows: RowRange) ShiftCursorError!void {
            return self.iter.shift(rows);
        }

        /// Repositions the walk onto `rows` and reads the first changed row in
        /// it ([`iter/tools.rs:578-589`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
        ///
        /// **The two comptime checks its three sibling `shiftNext`s carry, and
        /// the second is why the first is here too.** A caller asks
        /// [`isShiftable`](Self.isShiftable) whether this instantiation is
        /// repositionable at all, and it is answered from `Q` and `S` alone;
        /// without these two lines an instantiation that is not shiftable fails
        /// **inside** this body, on a field access, naming neither the parameter
        /// that has to change nor the declaration that has to grow. `S` is the
        /// check [`DiffSkipper.shiftNext`] and [`SkipIter.shiftNext`] already
        /// make, verbatim; `Q` is [`hasKernel`] — the eight forwarders above,
        /// of which this body calls one.
        pub fn shiftNext(self: *Self, rows: RowRange) !?Entry {
            if (comptime !hasKernel(Q)) @compileError(
                "a DiffKernel can only be repositioned over a walk that carries the whole kernel",
            );
            if (comptime !@hasDecl(S, "shiftNext")) @compileError(
                "a DiffKernel can only be repositioned over skippers that carry shiftNext",
            );
            const step = (try self.skipper.shiftNext(rows)) orelse return null;
            const start = rows.start + step.at;
            const item = (try self.iter.shiftNext(.{ .start = start, .end = rows.end })) orelse return null;
            return .{ .diff = step.diff, .item = item };
        }

        /// Consumes through `at` and reads the row there, or null when `at` is
        /// behind the walk ([`shift.rs:65-74`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        ///
        /// Upstream has no `seek_to` on this kernel (`iter/tools.rs:528-608`);
        /// the forwarder is here because [`Shiftable`] names it, and it reads a
        /// row rather than a step, so the skipper is not consulted.
        pub fn seekTo(self: *Self, at: usize) !?Item {
            return self.iter.seekTo(at);
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A value column with a distinguishable value in every row, so a walk that
/// landed on the wrong row reads as a wrong number rather than as a plausible
/// one.
const ValueCol = column.Column(u64, column.Rle(u64));
const ValueIter = ValueCol.Iterator;

/// The nullable value column, whose rows may carry nothing.
const NullCol = column.Column(?u64, column.RleOption(u64));

/// A boolean column, which is what a skipper reads.
const FlagCol = column.Column(bool, column.Bool);

/// The skipper every test below uses, and the one the op set's visibility and
/// top-op walks are made of
/// ([`iter/tools.rs:306-383`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
const BoolSkipper = column.BoolColumnSkipper(column.Bool);

/// A value column holding `0, 1, 2, …, n - 1`.
fn buildValues(gpa: Allocator, n: usize) !ValueCol {
    var col = try ValueCol.init(gpa);
    errdefer col.deinit();
    for (0..n) |i| try col.append(gpa, i);
    return col;
}

/// A value column holding exactly `model`.
fn buildModel(gpa: Allocator, model: []const u64) !ValueCol {
    var col = try ValueCol.init(gpa);
    errdefer col.deinit();
    try col.extend(gpa, model);
    return col;
}

/// A boolean column holding `flags`, for the caller to own and free.
fn buildFlags(gpa: Allocator, flags: []const bool) !FlagCol {
    var col = try FlagCol.init(gpa);
    errdefer col.deinit();
    try col.extend(gpa, flags);
    return col;
}

/// A skipper over the whole of `col`, which the caller keeps alive.
///
/// **The pointer is the point.** A `Column.Iterator` holds a `*const Column`,
/// so a cursor built over a column *local to a helper* and returned beside it
/// reads that helper's dead stack frame — the slab header it reads back is
/// whatever the frame held afterwards, which is an arithmetic overflow rather
/// than an error. One cursor over one column, both in the frame that uses
/// them.
fn skipperOver(col: *const FlagCol, len: usize) ParseError!BoolSkipper {
    return BoolSkipper.init(try col.iterRange(.{ .start = 0, .end = len }), len);
}

/// The rows `flags` keeps, read out of the flags and not out of any walk — the
/// oracle every skipper test is held to.
fn keptRows(gpa: Allocator, flags: []const bool) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (flags, 0..) |f, i| if (f) try out.append(gpa, i);
    return out.toOwnedSlice(gpa);
}

/// The exact sequence of skips a skipper over `flags` produces, read out of the
/// flags: the gap before each kept row, and then the distance from the last
/// kept row to the end of the window — which is the "one more answer after the
/// last `true`" every skipper gives
/// ([`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// It is also the reason there is always exactly one more answer than there are
/// kept rows, and it is what the dispatch tests count against.
fn skipGaps(gpa: Allocator, flags: []const bool) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    var kept: usize = 0;
    for (flags, 0..) |f, i| {
        if (f) {
            try out.append(gpa, i - at);
            at = i + 1;
            kept += 1;
        }
    }
    try out.append(gpa, flags.len -| at);
    return out.toOwnedSlice(gpa);
}

fn countNonZero(gaps: []const usize) usize {
    var n: usize = 0;
    for (gaps) |g| if (g != 0) {
        n += 1;
    };
    return n;
}

/// A walk over a caller-owned list of positions, which is all a position walk
/// needs to be.
const Positions = struct {
    items: []const usize,
    at: usize = 0,

    fn init(items: []const usize) Positions {
        return .{ .items = items };
    }

    pub fn next(self: *Positions) ParseError!?usize {
        if (self.at >= self.items.len) return null;
        defer self.at += 1;
        return self.items[self.at];
    }
};

/// The union of two increasing position lists, written out as the merge it is
/// meant to be: two cursors, always take the smaller, drop what has already
/// been handed out. The oracle for [`MergeIter`].
fn mergedPositions(gpa: Allocator, left: []const usize, right: []const usize) !std.ArrayList(usize) {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        const take_left = if (j >= right.len) true else if (i >= left.len) false else left[i] < right[j];
        const v = if (take_left) blk: {
            const v = left[i];
            i += 1;
            break :blk v;
        } else blk: {
            const v = right[j];
            j += 1;
            break :blk v;
        };
        if (out.items.len == 0 or out.items[out.items.len - 1] != v) try out.append(gpa, v);
    }
    return out;
}

// ── Walk shapes, for the three comptime dispatch forms ──────────────────────

/// A real column cursor behind a `tryNth` and the whole kernel: the shape
/// [`op_iter.OpIter`](../opset/op_iter.zig) has (`op_iter.rs:191-193`).
///
/// The op set is a sibling slice, so this file holds its own shape rather than
/// importing one being written next to it. The *data* under the walk is a real
/// column; only the entry points are a double, and the two counters are what
/// the tests read.
const NthWalk = struct {
    inner: ValueIter,
    nexts: usize = 0,
    nths: usize = 0,

    fn init(inner: ValueIter) NthWalk {
        return .{ .inner = inner };
    }

    pub fn pos(self: *const NthWalk) usize {
        return self.inner.pos();
    }
    pub fn maxPos(self: *const NthWalk) usize {
        return self.inner.maxPos();
    }
    pub fn setMax(self: *NthWalk, at: usize) void {
        self.inner.setMax(at);
    }
    pub fn advanceTo(self: *NthWalk, target: usize) ParseError!void {
        return self.inner.advanceTo(target);
    }
    pub fn advanceBy(self: *NthWalk, amount: usize) ParseError!void {
        return self.inner.advanceBy(amount);
    }
    pub fn shift(self: *NthWalk, rows: RowRange) ParseError!void {
        return self.inner.shift(rows);
    }
    pub fn seekTo(self: *NthWalk, at: usize) ParseError!?u64 {
        return self.inner.seekTo(at);
    }

    pub fn next(self: *NthWalk) ParseError!?u64 {
        self.nexts += 1;
        return self.inner.next();
    }
    pub fn tryNth(self: *NthWalk, n: usize) ParseError!?u64 {
        self.nths += 1;
        return self.inner.nth(n);
    }
    pub fn shiftNext(self: *NthWalk, rows: RowRange) ParseError!?u64 {
        self.nths += 1;
        return self.inner.shiftNext(rows);
    }
};

/// A real column cursor behind `next` and `shiftNext` and **no** `tryNth`: the
/// shape a pair of column cursors has
/// ([`op_iter.ActionValueIter`](../opset/op_iter.zig), `op_iter.rs:1120-1126`).
const ShiftWalk = struct {
    inner: ValueIter,
    nexts: usize = 0,
    shifts: usize = 0,

    fn init(inner: ValueIter) ShiftWalk {
        return .{ .inner = inner };
    }

    pub fn pos(self: *const ShiftWalk) usize {
        return self.inner.pos();
    }
    pub fn maxPos(self: *const ShiftWalk) usize {
        return self.inner.maxPos();
    }
    pub fn setMax(self: *ShiftWalk, at: usize) void {
        self.inner.setMax(at);
    }
    pub fn advanceTo(self: *ShiftWalk, target: usize) ParseError!void {
        return self.inner.advanceTo(target);
    }
    pub fn advanceBy(self: *ShiftWalk, amount: usize) ParseError!void {
        return self.inner.advanceBy(amount);
    }
    pub fn shift(self: *ShiftWalk, rows: RowRange) ParseError!void {
        return self.inner.shift(rows);
    }
    pub fn seekTo(self: *ShiftWalk, at: usize) ParseError!?u64 {
        return self.inner.seekTo(at);
    }

    pub fn next(self: *ShiftWalk) ParseError!?u64 {
        self.nexts += 1;
        return self.inner.next();
    }
    pub fn shiftNext(self: *ShiftWalk, rows: RowRange) ParseError!?u64 {
        self.shifts += 1;
        return self.inner.shiftNext(rows);
    }
};

/// A real column cursor behind `next` and nothing else: the shape a *filter*
/// has ([`visible.VisibleOpIter`](../opset/visible.zig)), which is why a
/// filter's skip is a walk.
const PlainWalk = struct {
    inner: ValueIter,
    nexts: usize = 0,

    fn init(inner: ValueIter) PlainWalk {
        return .{ .inner = inner };
    }

    pub fn next(self: *PlainWalk) ParseError!?u64 {
        self.nexts += 1;
        return self.inner.next();
    }
};

/// The three cardinalities a skip filter is held to: nothing kept, one row
/// kept, and many.
const Cardinalities = [_]struct { name: []const u8, flags: []const bool }{
    .{ .name = "nothing", .flags = &.{} },
    .{ .name = "one row", .flags = &.{ false, false, true, false } },
    .{ .name = "many", .flags = &.{ true, false, true, true, false, true, false, true } },
};

test "Unshift draws its lookahead in init, and peeking never consumes" {
    const gpa = testing.allocator;
    const model = [_]u64{ 5, 5, 5, 7, 7, 1, 1, 1, 1, 9 };
    var col = try buildModel(gpa, &model);
    defer col.deinit();

    const U = Unshift(ValueIter);
    var u = try U.init(try col.iterRange(.{ .start = 0, .end = model.len }));

    // The lookahead is already drawn, so `peek` is a field read and takes a
    // `*const Self`.
    try testing.expectEqual(@as(?u64, model[0]), u.peek());
    // **Twice.** A double peek that moved would hand the first item back again
    // and the walk would be short by one.
    try testing.expectEqual(@as(?u64, model[0]), u.peek());
    try testing.expectEqual(@as(usize, 1), u.inner.pos());

    // `next` after a `peek` hands back exactly what was peeked.
    for (model) |want| try testing.expectEqual(@as(?u64, want), (try u.next()).?);

    try testing.expectEqual(@as(?u64, null), u.peek());
    try testing.expect(u.exhausted());
    try testing.expectEqual(@as(?u64, null), try u.next());
}

test "Unshift keeps 'the walk is over' apart from 'this row carries nothing'" {
    // `MarkIndexColumn.ValueIter.next` at `mark_index.zig:488-496`: a cursor
    // over a nullable column answers `null` for a row that carries no value
    // *and* for the end of the window, and a walk flattened over it stops at
    // the first absent row.
    //
    // [`ItemOf`] peels **one** optional layer, so the item of a cursor whose
    // step is `E!(?T)` is `?T` and the lookahead is `??T`. That is the whole
    // fix and this is the case that fires it.
    const gpa = testing.allocator;
    const U = Unshift(NullCol.Iterator);
    try testing.expect(U.Item == ?u64);

    const values = [_]?u64{ null, 1, null, 3, null, null, 7, null };
    var col = try NullCol.init(gpa);
    defer col.deinit();
    try col.extend(gpa, &values);

    var u = try U.init(try col.iterRange(.{ .start = 0, .end = values.len }));

    // **Both layers, compared as `??u64` and not as `?u64`.** `expectEqual`
    // would coerce the outer layer away and the two answers would look the
    // same, which is the very thing the peel decides.
    const carries = struct {
        fn none() ??u64 {
            return @as(?u64, null);
        }
        fn some(v: u64) ??u64 {
            return @as(?u64, v);
        }
        fn over() ??u64 {
            return null;
        }
    };

    // Row 0 carries nothing and is *not* the end of the walk: the outer layer
    // says "there is a row" and the inner says what it holds. `exhausted`
    // reads the outer layer and only the outer layer.
    try testing.expect(!u.exhausted());
    try testing.expectEqual(carries.none(), u.peek());
    try testing.expectEqual(carries.none(), try u.next());

    // The walk did **not** stop at the absent row. It carried on to row 1 and
    // past the two absent rows in the middle.
    try testing.expectEqual(carries.some(1), u.peek());
    try testing.expectEqual(carries.some(1), try u.next());
    try testing.expectEqual(carries.none(), try u.next());
    try testing.expectEqual(carries.some(3), try u.next());
    try testing.expectEqual(carries.none(), try u.next());
    try testing.expectEqual(carries.none(), try u.next());
    try testing.expectEqual(carries.some(7), try u.next());
    try testing.expectEqual(carries.none(), try u.next());

    // And *now* the walk is over: the outer layer is null, and it is a
    // *different* value from the four absent rows above. The flattened shape
    // would have answered `over()` at row 0, and rows 1 to 7 would never have
    // been handed out at all.
    try testing.expect(u.exhausted());
    try testing.expectEqual(carries.over(), u.peek());
    try testing.expectEqual(carries.over(), try u.next());
    // Five rows carried nothing and three carried a value, so eight rows were
    // handed out and no more: every row of the column, exactly once. A walk
    // that stopped at the first absent row would have handed out one.
    var absent: usize = 0;
    for (values) |v| {
        if (v == null) absent += 1;
    }
    try testing.expectEqual(@as(usize, 5), absent);
    try testing.expectEqual(@as(usize, values.len), absent + 3);
}

test "PeekShift peeks lazily, and a peek then a shift hands back the new range" {
    const gpa = testing.allocator;
    const model = [_]u64{ 5, 5, 5, 7, 7, 1, 1, 1, 1, 9 };
    var col = try buildModel(gpa, &model);
    defer col.deinit();

    const P = PeekShift(ValueIter);
    var p = P.init(try col.iterRange(.{ .start = 0, .end = model.len }));

    // **Nothing has been read yet**, which is the difference from `Unshift`:
    // the wrapper is a value and building it cannot fail.
    try testing.expect(!p.isDrawn());
    try testing.expectEqual(@as(usize, 0), p.inner.pos());
    try testing.expect(!p.isDrawn());

    try testing.expectEqual(@as(?u64, model[0]), (try p.peek()).?);
    try testing.expect(p.isDrawn());
    // A second peek draws nothing more.
    try testing.expectEqual(@as(?u64, model[0]), (try p.peek()).?);

    // `next` hands back the peeked element, and then the one after it.
    try testing.expectEqual(@as(?u64, model[0]), (try p.next()).?);
    try testing.expectEqual(@as(?u64, model[1]), (try p.next()).?);

    // A shift discards the lookahead and refills it from the new range's start,
    // so `next` answers that row and then the one behind it.
    try p.shift(.{ .start = 6, .end = 9 });
    try testing.expectEqual(@as(?u64, model[6]), (try p.next()).?);
    try testing.expectEqual(@as(?u64, model[7]), (try p.next()).?);
    try testing.expectEqual(@as(?u64, model[8]), (try p.next()).?);
    try testing.expectEqual(@as(?u64, null), try p.next());
}

fn isEven(v: u64, parity: u64) bool {
    return v % 2 == parity;
}

test "PeekShift's next_if takes the lookahead only when the predicate accepts it" {
    const gpa = testing.allocator;
    const model = [_]u64{ 4, 1, 6, 3 };
    var col = try buildModel(gpa, &model);
    defer col.deinit();

    var p = PeekShift(ValueIter).init(try col.iterRange(.{ .start = 0, .end = model.len }));

    // Refused: the lookahead stays where it was.
    try testing.expectEqual(@as(?u64, null), try p.nextIf(@as(u64, 1), isEven));
    try testing.expectEqual(@as(?u64, 4), (try p.peek()).?);

    // Taken, and the next item is the one behind it.
    try testing.expectEqual(@as(?u64, 4), (try p.nextIf(@as(u64, 0), isEven)).?);
    try testing.expectEqual(@as(?u64, 1), (try p.peek()).?);
    try testing.expectEqual(@as(?u64, 1), (try p.next()).?);
    // Exhausted, the lookahead is null and `next_if` says so without consuming
    // anything.
    while ((try p.next()) != null) {}
    try testing.expectEqual(@as(?u64, null), try p.nextIf(@as(u64, 0), isEven));
}

test "SkipWrap turns positions into the distances between them" {
    const positions = [_]usize{ 0, 2, 3, 7, 8 };
    const oracle = [_]usize{ 0, 1, 0, 3, 0 };
    var w = SkipWrap(Positions).init(0, Positions.init(&positions));
    for (oracle) |want| try testing.expectEqual(want, (try w.next()).?);
    try testing.expectEqual(@as(?usize, null), try w.next());

    // A window that starts later measures from there: the first distance is
    // from `pos`, not from zero.
    const later = [_]usize{ 3, 7, 8 };
    var from2 = SkipWrap(Positions).init(2, Positions.init(&later));
    try testing.expectEqual(@as(usize, 1), (try from2.next()).?);
    try testing.expectEqual(@as(usize, 3), (try from2.next()).?);
    try testing.expectEqual(@as(usize, 0), (try from2.next()).?);
    try testing.expectEqual(@as(?usize, null), try from2.next());

    // A position at or behind the cursor is a zero skip and not a trap: the
    // contract is that positions increase, and a caller that breaks it gets a
    // defined answer rather than a panic. The zero is the *first* one only —
    // the cursor moves on to the next position behind it, which is also behind
    // where it was, and is then measured from there.
    var back = SkipWrap(Positions).init(9, Positions.init(&positions));
    try testing.expectEqual(@as(usize, 0), (try back.next()).?);
    try testing.expectEqual(@as(usize, 1), (try back.next()).?);
    try testing.expectEqual(@as(usize, 0), (try back.next()).?);
    try testing.expectEqual(@as(usize, 3), (try back.next()).?);
    try testing.expectEqual(@as(usize, 0), (try back.next()).?);
}

test "MergeIter merges two increasing walks and drops what they share" {
    const gpa = testing.allocator;
    const Cases = [_]struct { left: []const usize, right: []const usize }{
        .{ .left = &.{}, .right = &.{} },
        .{ .left = &.{ 0, 1, 2 }, .right = &.{ 3, 4, 5 } },
        .{ .left = &.{ 0, 2, 4 }, .right = &.{ 1, 3, 5 } },
        .{ .left = &.{ 1, 4, 9 }, .right = &.{ 1, 4, 9 } },
        .{ .left = &.{}, .right = &.{ 0, 1, 2 } },
        .{ .left = &.{ 0, 1, 2 }, .right = &.{} },
        // Overlapping runs, not just equal heads: every shared position has to
        // come out once.
        .{ .left = &.{ 0, 1, 2, 3 }, .right = &.{ 2, 3, 4, 5 } },
        // A run of positions both walks hold, so the duplicate filter and the
        // equal-head arm are both exercised.
        .{ .left = &.{ 0, 1, 2, 3, 4 }, .right = &.{ 1, 2, 3 } },
    };
    for (Cases) |c| {
        var m = MergeIter(Positions, Positions).init(Positions.init(c.left), Positions.init(c.right));
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try m.next()) |v| try got.append(gpa, v);
        var want = try mergedPositions(gpa, c.left, c.right);
        defer want.deinit(gpa);
        try testing.expectEqualSlices(usize, want.items, got.items);
    }
}

test "MergeIter.skip measures from one past the last position it handed out" {
    var m = MergeIter(Positions, Positions).init(Positions.init(&.{ 2, 3 }), Positions.init(&.{ 5, 6 }));
    // A walk that has handed nothing out is measured from zero.
    var s1 = m.skip();
    try testing.expectEqual(@as(usize, 2), (try s1.next()).?);

    var m2 = MergeIter(Positions, Positions).init(Positions.init(&.{ 2, 3 }), Positions.init(&.{ 5, 6 }));
    try testing.expectEqual(@as(usize, 2), (try m2.next()).?);
    try testing.expectEqual(@as(usize, 3), (try m2.next()).?);
    // Now measured from one past 3, which is where the next position sits.
    var s2 = m2.skip();
    try testing.expectEqual(@as(usize, 1), (try s2.next()).?);
    try testing.expectEqual(@as(usize, 0), (try s2.next()).?);
    try testing.expectEqual(@as(?usize, null), try s2.next());
}

test "SkipIter over a walk with tryNth takes the skip with tryNth" {
    const gpa = testing.allocator;
    for (Cardinalities) |card| {
        var col = try buildValues(gpa, card.flags.len);
        defer col.deinit();
        var f = try buildFlags(gpa, card.flags);
        defer f.deinit();

        var it = SkipIter(u64, NthWalk, BoolSkipper).init(
            NthWalk.init(try col.iterRange(.{ .start = 0, .end = card.flags.len })),
            try skipperOver(&f, card.flags.len),
        );
        var got: std.ArrayList(u64) = .empty;
        defer got.deinit(gpa);
        while (try it.next()) |v| try got.append(gpa, v);

        const want = try keptRows(gpa, card.flags);
        defer gpa.free(want);
        for (want, got.items) |row, v| try testing.expectEqual(@as(u64, row), v);
        try testing.expectEqual(want.len, got.items.len);

        // **The dispatch is the point.** Every non-zero skip went through
        // `nth`, and only the zero skips went through `next`.
        const gaps = try skipGaps(gpa, card.flags);
        defer gpa.free(gaps);
        try testing.expectEqual(gaps.len, it.iter.nexts + it.iter.nths);
        try testing.expectEqual(countNonZero(gaps), it.iter.nths);
        try testing.expectEqual(gaps.len - it.iter.nths, it.iter.nexts);
    }
}

test "SkipIter over a pair of cursors takes the skip with shiftNext" {
    const gpa = testing.allocator;
    for (Cardinalities) |card| {
        var col = try buildValues(gpa, card.flags.len);
        defer col.deinit();
        var f = try buildFlags(gpa, card.flags);
        defer f.deinit();

        var it = SkipIter(u64, ShiftWalk, BoolSkipper).init(
            ShiftWalk.init(try col.iterRange(.{ .start = 0, .end = card.flags.len })),
            try skipperOver(&f, card.flags.len),
        );
        var got: std.ArrayList(u64) = .empty;
        defer got.deinit(gpa);
        while (try it.next()) |v| try got.append(gpa, v);

        const want = try keptRows(gpa, card.flags);
        defer gpa.free(want);
        for (want, got.items) |row, v| try testing.expectEqual(@as(u64, row), v);
        try testing.expectEqual(want.len, got.items.len);

        // `shiftNext`, not `next`, carried every non-zero skip.
        const gaps = try skipGaps(gpa, card.flags);
        defer gpa.free(gaps);
        try testing.expectEqual(gaps.len, it.iter.nexts + it.iter.shifts);
        try testing.expectEqual(countNonZero(gaps), it.iter.shifts);
        try testing.expectEqual(gaps.len - it.iter.shifts, it.iter.nexts);
    }
}

test "SkipIter over a filter with no positional entry point walks the skip" {
    const gpa = testing.allocator;
    for (Cardinalities) |card| {
        var col = try buildValues(gpa, card.flags.len);
        defer col.deinit();
        var f = try buildFlags(gpa, card.flags);
        defer f.deinit();

        var it = SkipIter(u64, PlainWalk, BoolSkipper).init(
            PlainWalk.init(try col.iterRange(.{ .start = 0, .end = card.flags.len })),
            try skipperOver(&f, card.flags.len),
        );
        var got: std.ArrayList(u64) = .empty;
        defer got.deinit(gpa);
        while (try it.next()) |v| try got.append(gpa, v);

        const want = try keptRows(gpa, card.flags);
        defer gpa.free(want);
        for (want, got.items) |row, v| try testing.expectEqual(@as(u64, row), v);
        try testing.expectEqual(want.len, got.items.len);

        // A filter can only step one row at a time, so it walks every row of
        // the range exactly once and then asks once more for the answer that
        // is not there. **That is a different count from either other form**,
        // which is how a test can tell the three apart.
        try testing.expectEqual(card.flags.len + 1, it.iter.nexts);
        // And a filter cannot be repositioned, which is what the mark says.
        try testing.expect(!SkipIter(u64, PlainWalk, BoolSkipper).isShiftable());
        try testing.expect(SkipIter(u64, PlainWalk, BoolSkipper).shiftable == null);
    }
}

test "a walk is a Shiftable cursor only when it carries the whole kernel" {
    // The instantiations *are* the checks: `Shiftable` fails to compile on a
    // missing one of its eight names, so naming the mark at all is the proof.
    comptime {
        _ = SkipIter(u64, NthWalk, BoolSkipper).shiftable.?;
        _ = SkipIter(u64, ShiftWalk, BoolSkipper).shiftable.?;
        _ = DiffKernel(u64, NthWalk, BoolSkipper).shiftable.?;
        _ = DiffKernel(u64, ShiftWalk, BoolSkipper).shiftable.?;
    }
    try testing.expect(SkipIter(u64, NthWalk, BoolSkipper).isShiftable());
    try testing.expect(SkipIter(u64, ShiftWalk, BoolSkipper).isShiftable());
    // A filter is not, and says so instead of pretending.
    try testing.expect(!SkipIter(u64, PlainWalk, BoolSkipper).isShiftable());
    try testing.expect(!DiffKernel(u64, PlainWalk, BoolSkipper).isShiftable());
}

test "shift repositions to the range and shiftNext also reads" {
    const gpa = testing.allocator;
    const model = [_]u64{ 5, 5, 5, 7, 7, 1, 1, 1, 1, 9 };
    var col = try buildModel(gpa, &model);
    defer col.deinit();

    // **`shift` moves the window *and* lands on its start.** Upstream is
    // `set_max(range.end)` then `advance_to(range.start)`
    // (`column.rs:542-545`, `shift.rs:50-55`), and its own doc says the
    // window "yields the items in `range` and then returns `None`"
    // (`column.rs:536-537`): a truncation that left the cursor at row 0
    // yields rows 0 to 5 of a window ending at 6, which is not `range`.
    var bare = try col.iterRange(.{ .start = 0, .end = model.len });
    try testing.expectEqual(@as(usize, 0), bare.pos());
    try bare.shift(.{ .start = 4, .end = 6 });
    try testing.expectEqual(@as(usize, 4), bare.pos());
    try testing.expectEqual(@as(usize, 6), bare.maxPos());
    for (model[4..6]) |want| try testing.expectEqual(@as(?u64, want), (try bare.next()).?);
    try testing.expectEqual(@as(?u64, null), try bare.next());

    // **`shiftNext` moves, lands and reads.** Same window, different answer.

    var moved = try col.iterRange(.{ .start = 0, .end = model.len });
    try testing.expectEqual(@as(?u64, model[3]), (try moved.shiftNext(.{ .start = 3, .end = 7 })).?);
    // The position is the row the *next* `next` returns, and `shiftNext` has
    // already read row 3, so the cursor stands on 4 — which is the row the
    // next line gets.
    try testing.expectEqual(@as(usize, 4), moved.pos());
    try testing.expectEqual(@as(usize, 7), moved.maxPos());
    try testing.expectEqual(@as(?u64, model[4]), (try moved.next()).?);
    // And it walked off the end of the window, which is a defined answer.
    while ((try moved.next()) != null) {}
    try testing.expectEqual(@as(?u64, null), try moved.next());
}

test "a shift into a later object, into an earlier one, and past the end" {
    const gpa = testing.allocator;
    const model = [_]u64{ 5, 5, 5, 7, 7, 1, 1, 1, 1, 9 };
    var col = try buildModel(gpa, &model);
    defer col.deinit();

    var u = try Unshift(ValueIter).init(try col.iterRange(.{ .start = 0, .end = model.len }));
    try testing.expectEqual(@as(?u64, model[0]), u.peek());

    // **Later.** A range ahead of the cursor is served.
    try u.shift(.{ .start = 6, .end = 9 });
    try testing.expectEqual(@as(?u64, model[6]), u.peek());
    for (model[6..9]) |want| try testing.expectEqual(@as(?u64, want), (try u.next()).?);
    try testing.expect(u.exhausted());

    // **Earlier.** Repositioning only moves forward (`shift.rs:13-14`), so a
    // range behind the cursor is refused — a defined answer, and the lookahead
    // is untouched by the refusal.
    try testing.expectError(error.InvalidValue, u.shift(.{ .start = 0, .end = 3 }));
    try testing.expectEqual(@as(?u64, null), u.peek());

    // **Past the end.** The last object a reader visits is walked off the end
    // of like any other, and the answer is `null`, not a trap.
    try u.shift(.{ .start = model.len, .end = model.len + 10 });
    try testing.expectEqual(@as(?u64, null), u.peek());
    try testing.expect(u.exhausted());
    try testing.expectEqual(@as(?u64, null), try u.next());
    // A second shift past the end is the same answer.
    try u.shift(.{ .start = model.len + 100, .end = model.len + 200 });
    try testing.expectEqual(@as(?u64, null), try u.next());
}

test "a shifted SkipIter repositions both halves" {
    const gpa = testing.allocator;
    const flags = [_]bool{ true, true, false, true, true, false, true, true };
    var col = try buildValues(gpa, flags.len);
    defer col.deinit();
    var f = try buildFlags(gpa, &flags);
    defer f.deinit();

    var it = SkipIter(u64, ShiftWalk, BoolSkipper).init(
        ShiftWalk.init(try col.iterRange(.{ .start = 0, .end = flags.len })),
        try skipperOver(&f, flags.len),
    );

    // **Later:** the first kept row of the new range, and the rest of it. Row 3
    // is the first kept row at or after 3, so the range 3..6 keeps 3 and 4.
    try testing.expectEqual(@as(?u64, 3), (try it.shiftNext(.{ .start = 3, .end = 6 })).?);
    try testing.expectEqual(@as(?u64, 4), (try it.next()).?);
    try testing.expectEqual(@as(?u64, null), try it.next());

    // **Earlier:** refused, and the walk is left where it was.
    try testing.expectError(error.InvalidValue, it.shiftNext(.{ .start = 0, .end = 2 }));

    // **Past the end:** `null`, and the wrapper is still usable afterwards.
    try testing.expectEqual(@as(?u64, null), try it.shiftNext(.{ .start = flags.len, .end = flags.len + 4 }));

    // A `shift` moves the **kernel** and lands it on the range's start
    // (`shift.rs:50-55`), and reads nothing — that is the whole difference
    // from `shiftNext`, whose three answers above each came with a row. The
    // skipper is not moved by it, which is why `shiftNext` below is the entry
    // point that keeps the two halves in step.
    var windowed = SkipIter(u64, ShiftWalk, BoolSkipper).init(
        ShiftWalk.init(try col.iterRange(.{ .start = 0, .end = flags.len })),
        try skipperOver(&f, flags.len),
    );
    try testing.expectEqual(@as(usize, 0), windowed.pos());
    try windowed.shift(.{ .start = 2, .end = 3 });
    try testing.expectEqual(@as(usize, 2), windowed.pos());
    try testing.expectEqual(@as(usize, 3), windowed.maxPos());
    // A `shiftNext` whose range holds no kept row answers `null` rather than
    // the range's first row: the skipper answers the whole distance to the end
    // of the range (`iter/tools.rs:345-353`) and the walk is then asked for a
    // row at or past it. A range whose first row *is* kept answers that row.
    try testing.expectEqual(@as(?u64, null), try windowed.shiftNext(.{ .start = 2, .end = 3 }));
    var first_kept = SkipIter(u64, ShiftWalk, BoolSkipper).init(
        ShiftWalk.init(try col.iterRange(.{ .start = 0, .end = flags.len })),
        try skipperOver(&f, flags.len),
    );
    try testing.expectEqual(@as(?u64, 0), (try first_kept.shiftNext(.{ .start = 0, .end = 1 })).?);
}

// ── The diff ────────────────────────────────────────────────────────────────

/// The values `flags` makes visible, read out of the flags.
fn visibleValues(gpa: Allocator, model: []const u64, flags: []const bool) !std.ArrayList(u64) {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    for (flags, model) |f, v| if (f) try out.append(gpa, v);
    return out;
}

/// The sequence of `Diff` two states imply, written out as the two-pointer
/// merge it is meant to be.
///
/// This is the oracle for the diff skippers, and it reads the two visibility
/// lists and nothing else — no skipper, no column, no walk. A diff judged
/// against its own output is not a checker.
fn expectedDiffs(gpa: Allocator, before: []const bool, after: []const bool) !std.ArrayList(Diff) {
    var out: std.ArrayList(Diff) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.len or j < after.len) {
        while (i < before.len and !before[i]) i += 1;
        while (j < after.len and !after[j]) j += 1;
        if (i >= before.len and j >= after.len) break;
        if (i == j) {
            try out.append(gpa, .same);
            i += 1;
            j += 1;
        } else if (i < j) {
            try out.append(gpa, .del);
            i += 1;
        } else {
            try out.append(gpa, .add);
            j += 1;
        }
    }
    return out;
}

/// What a diff walk produced, and the two states it was between.
const DiffRun = struct {
    /// The values the earlier state shows.
    left: std.ArrayList(u64),
    /// The values the later state shows.
    right: std.ArrayList(u64),
    /// The values the diff keeps — its `Same` and `Add` entries, in order.
    applied: std.ArrayList(u64),
    /// The values the diff drops — its `Del` entries, in order.
    dropped: std.ArrayList(u64),
    /// The labels the diff gave, in order.
    diffs: std.ArrayList(Diff),

    fn deinit(self: *DiffRun, gpa: Allocator) void {
        self.left.deinit(gpa);
        self.right.deinit(gpa);
        self.applied.deinit(gpa);
        self.dropped.deinit(gpa);
        self.diffs.deinit(gpa);
    }
};

/// The diff between two visibility states of `0, 1, 2, …, n - 1`, walked with a
/// single-column walk — the shape upstream's single-column instantiations are
/// over (`MapIter<'a>` and `ListIter<'a>`,
/// [`iter/tools.rs:528-536`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
///
/// `before` is the earlier state and `after` the later one, in the port's
/// [`ClockRange`](../../src/clock.zig) order: `Diff{ before, after }`.
fn diffOverValues(gpa: Allocator, before: []const bool, after: []const bool) !DiffRun {
    std.debug.assert(before.len == after.len);
    var values = try buildValues(gpa, before.len);
    defer values.deinit();
    var fb = try buildFlags(gpa, before);
    defer fb.deinit();
    var fa = try buildFlags(gpa, after);
    defer fa.deinit();

    const model = try gpa.alloc(u64, before.len);
    defer gpa.free(model);
    for (model, 0..) |*v, i| v.* = i;

    var run: DiffRun = .{
        .left = try visibleValues(gpa, model, before),
        .right = .empty,
        .applied = .empty,
        .dropped = .empty,
        .diffs = .empty,
    };
    errdefer run.deinit(gpa);
    run.right = try visibleValues(gpa, model, after);

    var it = DiffKernel(u64, ValueIter, BoolSkipper).initDiff(
        try values.iterRange(.{ .start = 0, .end = before.len }),
        try skipperOver(&fb, before.len),
        try skipperOver(&fa, after.len),
    );
    while (try it.next()) |e| {
        try run.diffs.append(gpa, e.diff);
        if (e.diff.isDel()) {
            try run.dropped.append(gpa, e.item);
        } else {
            try run.applied.append(gpa, e.item);
        }
    }
    return run;
}

test "a diff over two equal states is all Same and reproduces the state" {
    const gpa = testing.allocator;
    const all = @as([6]bool, @splat(true));
    var run = try diffOverValues(gpa, &all, &all);
    defer run.deinit(gpa);

    for (run.diffs.items) |d| try testing.expectEqual(Diff.same, d);
    try testing.expectEqual(@as(usize, all.len), run.applied.items.len);
    try testing.expectEqual(@as(usize, 0), run.dropped.items.len);
    // **The property, not a count:** applying the diff to the earlier state
    // produces the later one.
    try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
    // And nothing the diff dropped came out of the earlier state, so the two
    // states agreed on every row.
    try testing.expectEqualSlices(u64, run.left.items, run.applied.items);
}

test "one differing row diffs to one entry, wherever it sits" {
    const gpa = testing.allocator;
    const all = @as([5]bool, @splat(true));
    var head = all;
    head[0] = false;
    var tail = all;
    tail[tail.len - 1] = false;
    const Cases = [_]struct {
        name: []const u8,
        before: []const bool,
        after: []const bool,
        want: []const Diff,
    }{
        .{
            .name = "one row added at the last position",
            .before = &tail,
            .after = &all,
            .want = &.{ .same, .same, .same, .same, .add },
        },
        .{
            .name = "one row deleted at the last position",
            .before = &all,
            .after = &tail,
            .want = &.{ .same, .same, .same, .same, .del },
        },
        .{
            .name = "one row added at the first position",
            .before = &head,
            .after = &all,
            .want = &.{ .add, .same, .same, .same, .same },
        },
        .{
            .name = "one row deleted at the first position",
            .before = &all,
            .after = &head,
            .want = &.{ .del, .same, .same, .same, .same },
        },
    };
    for (Cases) |c| {
        var run = try diffOverValues(gpa, c.before, c.after);
        defer run.deinit(gpa);
        try testing.expectEqualSlices(Diff, c.want, run.diffs.items);
        try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
    }
}

test "a run of differing rows diffs to a run" {
    const gpa = testing.allocator;
    const all7 = @as([7]bool, @splat(true));
    const Cases = [_]struct {
        name: []const u8,
        before: []const bool,
        after: []const bool,
        want: []const Diff,
    }{
        .{
            .name = "three added in the middle",
            .before = &.{ true, true, false, false, false, true, true },
            .after = &all7,
            .want = &.{ .same, .same, .add, .add, .add, .same, .same },
        },
        .{
            .name = "three deleted in the middle",
            .before = &all7,
            .after = &.{ true, true, false, false, false, true, true },
            .want = &.{ .same, .same, .del, .del, .del, .same, .same },
        },
        .{
            .name = "two scattered additions",
            .before = &.{ false, true, true, true, false, true, true },
            .after = &all7,
            .want = &.{ .add, .same, .same, .same, .add, .same, .same },
        },
        .{
            .name = "two scattered deletions",
            .before = &all7,
            .after = &.{ false, true, true, true, true, true, true },
            .want = &.{ .del, .same, .same, .same, .same, .same, .same },
        },
    };
    for (Cases) |c| {
        var run = try diffOverValues(gpa, c.before, c.after);
        defer run.deinit(gpa);
        try testing.expectEqualSlices(Diff, c.want, run.diffs.items);
        try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
    }
}

test "a state shorter than the other diffs to the missing tail" {
    const gpa = testing.allocator;
    const all4 = @as([4]bool, @splat(true));
    const all5 = @as([5]bool, @splat(true));
    const none4 = @as([4]bool, @splat(false));
    const Cases = [_]struct {
        name: []const u8,
        before: []const bool,
        after: []const bool,
        want: []const Diff,
    }{
        .{
            .name = "the later state is shorter",
            .before = &all5,
            .after = &.{ true, true, false, false, false },
            .want = &.{ .same, .same, .del, .del, .del },
        },
        .{
            .name = "the earlier state is shorter",
            .before = &.{ true, true, false, false, false },
            .after = &all5,
            .want = &.{ .same, .same, .add, .add, .add },
        },
        .{
            .name = "the later state is empty",
            .before = &all4,
            .after = &none4,
            .want = &.{ .del, .del, .del, .del },
        },
        .{
            .name = "the earlier state is empty",
            .before = &none4,
            .after = &all4,
            .want = &.{ .add, .add, .add, .add },
        },
        .{
            .name = "both states are empty",
            .before = &none4,
            .after = &none4,
            .want = &.{},
        },
    };
    for (Cases) |c| {
        var run = try diffOverValues(gpa, c.before, c.after);
        defer run.deinit(gpa);
        try testing.expectEqualSlices(Diff, c.want, run.diffs.items);
        try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
    }
}

test "a difference at the very first and the very last position" {
    const gpa = testing.allocator;
    const all = @as([5]bool, @splat(true));
    // The three shapes a difference at an end can take: the first row alone,
    // the last row alone, and the last two together.
    var head = all;
    head[0] = false;
    var tail = all;
    tail[tail.len - 1] = false;
    var tail2 = all;
    tail2[tail2.len - 2] = false;
    tail2[tail2.len - 1] = false;
    var first_and_last = all;
    first_and_last[0] = false;
    first_and_last[first_and_last.len - 1] = false;
    const Cases = [_]struct {
        name: []const u8,
        before: []const bool,
        after: []const bool,
        want: []const Diff,
    }{
        .{
            .name = "the first and last rows are both deleted",
            .before = &all,
            .after = &first_and_last,
            .want = &.{ .del, .same, .same, .same, .del },
        },
        .{
            .name = "the first and last rows are both added",
            .before = &first_and_last,
            .after = &all,
            .want = &.{ .add, .same, .same, .same, .add },
        },
        .{
            .name = "the last two rows are deleted",
            .before = &all,
            .after = &tail2,
            .want = &.{ .same, .same, .same, .del, .del },
        },
        .{
            .name = "the last two rows are added",
            .before = &tail2,
            .after = &all,
            .want = &.{ .same, .same, .same, .add, .add },
        },
        // A difference at the *last* row alone is the one a skipper's "one
        // more answer after the last kept row" can swallow
        // (`iter/tools.rs:373-381`), so it is worth pinning on its own too.
        .{
            .name = "the last row alone is deleted",
            .before = &all,
            .after = &tail,
            .want = &.{ .same, .same, .same, .same, .del },
        },
        .{
            .name = "the last row alone is added",
            .before = &tail,
            .after = &all,
            .want = &.{ .same, .same, .same, .same, .add },
        },
        .{
            .name = "the first row alone is deleted",
            .before = &all,
            .after = &head,
            .want = &.{ .del, .same, .same, .same, .same },
        },
        .{
            .name = "the first row alone is added",
            .before = &head,
            .after = &all,
            .want = &.{ .add, .same, .same, .same, .same },
        },
    };
    for (Cases) |c| {
        var run = try diffOverValues(gpa, c.before, c.after);
        defer run.deinit(gpa);
        try testing.expectEqualSlices(Diff, c.want, run.diffs.items);
        try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
        // The dropped rows are exactly the earlier state's rows the later
        // state does not have.
        var want_dropped: std.ArrayList(u64) = .empty;
        defer want_dropped.deinit(gpa);
        for (run.left.items) |v| {
            if (std.mem.indexOfScalar(u64, run.right.items, v) == null) try want_dropped.append(gpa, v);
        }
        try testing.expectEqualSlices(u64, want_dropped.items, run.dropped.items);
    }
}

test "the diff applied to the earlier state produces the later state" {
    // **The property, and not a count.** For a spread of pairs of states, the
    // walk's kept entries in order are the later state's values.
    const gpa = testing.allocator;
    const n: usize = 9;
    const all = @as([n]bool, @splat(true));
    const none = @as([n]bool, @splat(false));
    const Cases = [_]struct { before: []const bool, after: []const bool }{
        .{ .before = &all, .after = &all },
        .{ .before = &none, .after = &all },
        .{ .before = &all, .after = &none },
        .{ .before = &none, .after = &none },
        .{ .before = &.{ true, false, true, false, true, false, true, false, true }, .after = &.{ false, true, false, true, false, true, false, true, false } },
        .{ .before = &.{ true, true, true, false, false, false, true, true, true }, .after = &all },
        .{ .before = &all, .after = &.{ false, false, true, false, true, true, true, false, false } },
        // A row that leaves and a row that arrive in the same step, which is
        // the case a diff has to order right.
        .{ .before = &.{ true, true, true, false, true, true, true, false, true }, .after = &all },
        .{ .before = &.{ false, true, true, true, true, true, true, true, false }, .after = &all },
        .{ .before = &all, .after = &.{ true, true, true, true, true, true, true, true, false } },
        .{ .before = &.{ true, true, true, true, true, true, true, true, true }, .after = &.{ false, true, true, true, true, true, true, true, false } },
    };
    var differing: usize = 0;
    for (Cases) |c| {
        var run = try diffOverValues(gpa, c.before, c.after);
        defer run.deinit(gpa);

        // The labels agree with a merge written out separately.
        var want = try expectedDiffs(gpa, c.before, c.after);
        defer want.deinit(gpa);
        try testing.expectEqualSlices(Diff, want.items, run.diffs.items);

        // **Applying the diff to the earlier state produces the later one.**
        try testing.expectEqualSlices(u64, run.right.items, run.applied.items);
        // And the diff started from the earlier state: every dropped row was in
        // it, and every row it kept is in the later state.
        for (run.dropped.items) |v| {
            try testing.expect(std.mem.indexOfScalar(u64, run.left.items, v) != null);
        }
        for (run.applied.items) |v| {
            try testing.expect(std.mem.indexOfScalar(u64, run.right.items, v) != null);
        }
        // Every row the diff visited is in the earlier state, the later one,
        // or both, and the three counts are the two states' own. That is what
        // makes the applied list the later state rather than a subsequence of
        // it, and it is the only arithmetic here that holds for a pair of
        // states that share no rows at all.
        var before_rows: usize = 0;
        var after_rows: usize = 0;
        var either: usize = 0;
        for (c.before, c.after) |b, a| {
            if (b) before_rows += 1;
            if (a) after_rows += 1;
            if (b or a) either += 1;
        }
        var same: usize = 0;
        for (run.diffs.items) |d| {
            if (d == .same) same += 1;
        }
        try testing.expectEqual(either, run.applied.items.len + run.dropped.items.len);
        try testing.expectEqual(before_rows, same + run.dropped.items.len);
        try testing.expectEqual(after_rows, same + (run.applied.items.len - same));
        if (!std.mem.eql(u64, run.left.items, run.right.items)) differing += 1;
    }
    // The premise: all but the two pairs of *identical* states really do
    // differ, so the check above is not vacuous — one pair is `all`/`all` and
    // one is `none`/`none`, and both have nothing to say.
    try testing.expect(differing >= Cases.len - 2);
}

test "a diff against one current state tags every kept row an addition" {
    // `DiffSkipper::Current` has nothing to compare against, so everything it
    // keeps is new (`iter/tools.rs:479`).
    const gpa = testing.allocator;
    const flags = [_]bool{ true, false, true, true, false, true };
    var col = try buildValues(gpa, flags.len);
    defer col.deinit();
    var f = try buildFlags(gpa, &flags);
    defer f.deinit();

    var it = DiffKernel(u64, ValueIter, BoolSkipper).initCurrent(
        try col.iterRange(.{ .start = 0, .end = flags.len }),
        try skipperOver(&f, flags.len),
    );
    var got: std.ArrayList(u64) = .empty;
    defer got.deinit(gpa);
    while (try it.next()) |e| {
        try testing.expectEqual(Diff.add, e.diff);
        try got.append(gpa, e.item);
    }
    const want = try keptRows(gpa, &flags);
    defer gpa.free(want);
    for (want, got.items) |row, v| try testing.expectEqual(@as(u64, row), v);
    try testing.expectEqual(want.len, got.items.len);
}

/// A row read out of two columns at once, which is the shape a multi-column
/// walk yields ([`op_iter.ActionValue`](../opset/op_iter.zig)).
const Pair = struct { row: u64, action: bool };

/// A walk over two column cursors, which is the shape this kernel is
/// instantiated over upstream when it is not a single column
/// ([`iter/tools.rs:562-576`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
const PairWalk = struct {
    values: ValueIter,
    actions: ValueIter,
    nexts: usize = 0,

    fn init(values: ValueIter, actions: ValueIter) PairWalk {
        return .{ .values = values, .actions = actions };
    }

    pub fn pos(self: *const PairWalk) usize {
        return self.values.pos();
    }
    pub fn maxPos(self: *const PairWalk) usize {
        return self.values.maxPos();
    }
    pub fn setMax(self: *PairWalk, at: usize) void {
        self.values.setMax(at);
        self.actions.setMax(at);
    }
    pub fn advanceTo(self: *PairWalk, target: usize) ParseError!void {
        try self.values.advanceTo(target);
        try self.actions.advanceTo(target);
    }
    pub fn advanceBy(self: *PairWalk, amount: usize) ParseError!void {
        return self.advanceTo(self.pos() +| amount);
    }
    pub fn shift(self: *PairWalk, rows: RowRange) ParseError!void {
        var values = self.values;
        var actions = self.actions;
        try values.shift(rows);
        try actions.shift(rows);
        self.values = values;
        self.actions = actions;
    }
    pub fn seekTo(self: *PairWalk, at: usize) ParseError!?Pair {
        const row = (try self.values.seekTo(at)) orelse return null;
        const action = (try self.actions.seekTo(at)) orelse return null;
        return .{ .row = row, .action = action % 2 == 0 };
    }

    pub fn next(self: *PairWalk) !?Pair {
        self.nexts += 1;
        const row = (try self.values.next()) orelse return null;
        // A column that ran out before its twin did is a walk that cannot be
        // read, which is the op set's `MissingValue` and not a column's.
        const action = (try self.actions.next()) orelse return error.MissingValue;
        return .{ .row = row, .action = action % 2 == 0 };
    }

    pub fn shiftNext(self: *PairWalk, rows: RowRange) !?Pair {
        const row = (try self.values.shiftNext(rows)) orelse return null;
        const action = (try self.actions.shiftNext(rows)) orelse return error.MissingValue;
        return .{ .row = row, .action = action % 2 == 0 };
    }
};

test "a shifted multi-column diff yields the requested row tuple" {
    // Ordinary reads after a shift must observe both columns on the new row.
    const gpa = testing.allocator;
    const flags = @as([4]bool, @splat(true));
    var values = try buildValues(gpa, flags.len);
    defer values.deinit();
    var kept = try buildFlags(gpa, &flags);
    defer kept.deinit();
    var it = DiffKernel(Pair, PairWalk, BoolSkipper).initCurrent(
        PairWalk.init(try values.iterator(), try values.iterator()),
        try skipperOver(&kept, flags.len),
    );
    try it.shift(.{ .start = 2, .end = 4 });
    const first = (try it.next()).?;
    try testing.expectEqual(Diff.add, first.diff);
    try testing.expectEqual(Pair{ .row = 2, .action = true }, first.item);
    const second = (try it.next()).?;
    try testing.expectEqual(Pair{ .row = 3, .action = false }, second.item);
    try testing.expect((try it.next()) == null);
}

test "a diff over a multi-column walk is the same type as one over a single column" {
    // Upstream instantiates the kernel over both a single-column walk
    // (`MapIter`, `ListIter`) and a multi-column one (`ActionValueIter` with a
    // `TopIter` skipper, `iter/tools.rs:562-576`); the type is the same and
    // only `Q` differs.
    const gpa = testing.allocator;
    const before = [_]bool{ true, true, false, true, true, false };
    const after = @as([before.len]bool, @splat(true));
    var values = try buildValues(gpa, before.len);
    defer values.deinit();
    var fb = try buildFlags(gpa, &before);
    defer fb.deinit();
    var fa = try buildFlags(gpa, &after);
    defer fa.deinit();

    var it = DiffKernel(Pair, PairWalk, BoolSkipper).initDiff(
        PairWalk.init(
            try values.iterRange(.{ .start = 0, .end = before.len }),
            try values.iterRange(.{ .start = 0, .end = before.len }),
        ),
        try skipperOver(&fb, before.len),
        try skipperOver(&fa, after.len),
    );
    var got: std.ArrayList(Diff) = .empty;
    defer got.deinit(gpa);
    var applied: std.ArrayList(u64) = .empty;
    defer applied.deinit(gpa);
    while (try it.next()) |e| {
        try got.append(gpa, e.diff);
        if (e.diff.isVisible()) try applied.append(gpa, e.item.row);
        // **The second column came along.** Both cursors hold the same values
        // here, so the action a row carries is its own row's parity — and a
        // walk that repositioned only one of the pair could not answer that.
        try testing.expectEqual(e.item.row % 2 == 0, e.item.action);
    }
    var want = try expectedDiffs(gpa, &before, &after);
    defer want.deinit(gpa);
    try testing.expectEqualSlices(Diff, want.items, got.items);
    // The later state here is every row, so the applied list is every row.
    for (0..before.len) |i| try testing.expectEqual(@as(u64, i), applied.items[i]);
    try testing.expectEqual(before.len, applied.items.len);
}

test "a shifted diff answers a defined row, and null past the end" {
    const gpa = testing.allocator;
    const flags = [_]bool{ true, false, true, true, false, true, true, false };
    var col = try buildValues(gpa, flags.len);
    defer col.deinit();
    var fb = try buildFlags(gpa, &flags);
    defer fb.deinit();
    var fa = try buildFlags(gpa, &flags);
    defer fa.deinit();

    var it = DiffKernel(u64, ValueIter, BoolSkipper).initDiff(
        try col.iterRange(.{ .start = 0, .end = flags.len }),
        try skipperOver(&fb, flags.len),
        try skipperOver(&fa, flags.len),
    );
    // The two states agree, so every step is a `Same` at the first kept row of
    // the range, which in 4..8 is row 5. **`shiftNext` hands that row back
    // itself**, so the next `next` is the row behind it.
    const landed = (try it.shiftNext(.{ .start = 4, .end = 8 })).?;
    try testing.expectEqual(Diff.same, landed.diff);
    try testing.expectEqual(@as(u64, 5), landed.item);
    try testing.expectEqual(@as(u64, 6), (try it.next()).?.item);
    // Walking off the end of the range ends the walk, and it stays ended.
    while ((try it.next()) != null) {}
    try testing.expect((try it.next()) == null);
    // Past the end of the column altogether: the whole answer is `null`, not
    // an entry carrying nothing.
    try testing.expect((try it.shiftNext(.{ .start = flags.len, .end = flags.len + 4 })) == null);
}

test "constructing any of these allocates nothing" {
    // An iterator is a value. The count is compared across
    // the whole block, so a constructor that allocated would move it.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();

    const n: usize = 64;
    const flags = try gpa.alloc(bool, n);
    defer gpa.free(flags);
    for (flags, 0..) |*f, i| f.* = i % 3 != 0;
    var col = try buildValues(gpa, n);
    defer col.deinit();
    var fb = try buildFlags(gpa, flags);
    defer fb.deinit();
    var fa = try buildFlags(gpa, flags);
    defer fa.deinit();
    const built_at = failing.allocations;

    // The two lookahead wrappers over a real cursor.
    var u = try Unshift(ValueIter).init(try col.iterRange(.{ .start = 0, .end = n }));
    while ((try u.next()) != null) {}
    var p = PeekShift(ValueIter).init(try col.iterRange(.{ .start = 0, .end = n }));
    _ = try p.peek();
    while ((try p.next()) != null) {}
    // The skip filter, both arms of the diff, and the merge.
    var s = SkipIter(u64, ShiftWalk, BoolSkipper).init(
        ShiftWalk.init(try col.iterRange(.{ .start = 0, .end = n })),
        try skipperOver(&fb, n),
    );
    while ((try s.next()) != null) {}
    var d = DiffKernel(u64, ValueIter, BoolSkipper).initDiff(
        try col.iterRange(.{ .start = 0, .end = n }),
        try skipperOver(&fb, n),
        try skipperOver(&fa, n),
    );
    while ((try d.next()) != null) {}
    var cur = DiffKernel(u64, ValueIter, BoolSkipper).initCurrent(
        try col.iterRange(.{ .start = 0, .end = n }),
        try skipperOver(&fa, n),
    );
    while ((try cur.next()) != null) {}
    const positions = [_]usize{ 0, 2, 3, 7, 8, 11, 12, 20 };
    var m = MergeIter(Positions, Positions).init(Positions.init(&positions), Positions.init(&positions));
    while ((try m.next()) != null) {}
    var w = m.skip();
    while ((try w.next()) != null) {}

    try testing.expectEqual(built_at, failing.allocations);
}

/// The shape `op_iter.ActionValueIter` has: a **total** step spelled `tryNext`,
/// a positional `shiftNext`, and **no** `next` at all (`op_iter.zig:1085-1088`,
/// `:1123-1127`). `tryNext` answers `error.MissingValue` at the end of the
/// window where every other form answers null.
const TotalWalk = struct {
    inner: ValueIter,
    /// How many times the total step was called at all, which is the count
    /// [`takeAt`]'s zero-skip arm must keep at zero.
    nexts: usize = 0,
    /// How many times the walk was repositioned instead.
    shifts: usize = 0,

    fn init(inner: ValueIter) TotalWalk {
        return .{ .inner = inner };
    }

    pub fn pos(self: *const TotalWalk) usize {
        return self.inner.pos();
    }

    pub fn maxPos(self: *const TotalWalk) usize {
        return self.inner.maxPos();
    }

    pub fn tryNext(self: *TotalWalk) (ParseError || error{MissingValue})!u64 {
        self.nexts += 1;
        return (try self.inner.next()) orelse error.MissingValue;
    }

    pub fn shiftNext(self: *TotalWalk, rows: RowRange) ParseError!?u64 {
        self.shifts += 1;
        return self.inner.shiftNext(rows);
    }
};

test "a zero skip is answered by a partial step, and never by a total one" {
    // **The skipper's last answer is a skip of zero whenever the last row of
    // the window is kept** — it is the distance from the last kept row to the
    // end of the window ([`iter/tools.rs:373-381`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
    // [`column.BoolColumnSkipper.next`](../hexane/column.zig)) — and that answer
    // asks the walk for a row one past its end. A *total* step raises there, so
    // the zero arm is only ever the walk's **partial** step, and a walk with no
    // partial step falls through to the positional forms, which are partial and
    // answer null the way upstream's `Iterator::next` does.
    //
    // `TotalWalk` is that shape: the only instantiations of it are
    // [`op_iter.ActionValueIter`](../opset/op_iter.zig) and the two
    // `SkipIter`s over it in [src/opset/op_set.zig](../opset/op_set.zig).
    const gpa = testing.allocator;
    for (Cardinalities) |card| {
        var col = try buildValues(gpa, card.flags.len);
        defer col.deinit();
        var f = try buildFlags(gpa, card.flags);
        defer f.deinit();
        const gaps = try skipGaps(gpa, card.flags);
        defer gpa.free(gaps);

        var it = SkipIter(u64, TotalWalk, BoolSkipper).init(
            TotalWalk.init(try col.iterRange(.{ .start = 0, .end = card.flags.len })),
            try skipperOver(&f, card.flags.len),
        );
        var got: std.ArrayList(u64) = .empty;
        defer got.deinit(gpa);
        // **No `MissingValue` is in reach here**, and that is the assertion: the
        // walk drains to a null instead of raising on the way out.
        while (try it.next()) |v| try got.append(gpa, v);

        const want = try keptRows(gpa, card.flags);
        defer gpa.free(want);
        try testing.expectEqualSlices(u64, want, got.items);
        try testing.expect((try it.next()) == null);

        // And the total step was never the answer for anything, zero skip or
        // not: every skip went through `shiftNext`, so the shifts are as many
        // as the skipper had answers and the total steps are none.
        try testing.expectEqual(@as(usize, 0), it.iter.nexts);
        try testing.expectEqual(gaps.len, it.iter.shifts);
    }
}

test "a deleted row is the only row a diff does not call visible" {
    // `Diff::is_del` / `Diff::is_visible`, `iter/tools.rs:618-624`, are the
    // two predicates every leaf reader branches on
    // (`map_range.rs:260`, `map_range.rs:272`, `list_range.rs:134`,
    // `list_range.rs:151`), and neither had a test of its own. **The check
    // is on the tag, not on the spelling of the two functions**:
    // `is_visible` is `!is_del`, so a reader that answered `diff == .same` —
    // the other possible reading of "survives into the later state" — would
    // tag every *added* row invisible, and a diff over a growing document
    // would drop half of it while every row it kept still looked right.
    //
    // **Each predicate is asked of all three tags in both directions**, so an
    // implementation that answered one constant passes none of it.
    for ([_]Diff{ .same, .add, .del }) |tag| {
        try testing.expectEqual(tag == .del, tag.isDel());
        try testing.expectEqual(tag != .del, tag.isVisible());
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`Shiftable`'s range is counted in the walk's own positions, and there
//   is no grapheme anywhere in this file.** Upstream's trait is one method
//   ([`iter/tools.rs:62-64`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)):
//   `fn shift_next(&mut self, _range: Range<usize>) -> Option<Self::Item>`, and
//   `hexane`'s default body is `set_max(range.end)` then
//   `nth(range.start - get_pos())`
//   ([`shift.rs:56-63`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
//   So the unit is whatever the implementing cursor counts, and every
//   implementation of it in `iter/` counts **op rows**: `MapIter` repositions
//   four column cursors on the same row range
//   ([`map_range.rs:115-130`](../../github-automerge-automerge/rust/automerge/src/iter/map_range.rs)),
//   `ListIter` four more ([`list_range.rs:264-271`](../../github-automerge-automerge/rust/automerge/src/iter/list_range.rs)),
//   and `BoolColumnSkipper` counts row distances over a boolean column
//   ([`iter/tools.rs:334-353`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
//   **A shift over a map advancing by rows is therefore upstream's shape, not
//   a scaling mistake, and a diff over a map is not off by any element
//   width.** The width question is a *different* one and it is answered
//   elsewhere: an element's width in the text encoding is read off
//   `index.text` at the register's **last** row
//   ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//   which is [`list_range.elementWidth`] and not a shift. Checked by
//   perturbing `MapRange.shiftNext` to land one row past the range the caller
//   named: the new test "a map range shifts forward into the next object and
//   keeps row order" fails with `error.TestExpectedItem` at
//   `map_range.zig:1399`.
//
// * **`Diff::is_visible` is `!is_del` and not `diff == Same`, and the map
//   reader's own tests cannot tell the two apart.** Upstream is explicit
//   ([`iter/tools.rs:618-624`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)):
//   `is_visible` is `!self.is_del()`. `map_range.rs` only asks it about rows
//   that a `Same` can precede — `map_range.rs:268` guards a held-back
//   `last_visible` with `diff.is_visible() && next_diff.is_del()` — and none
//   of the port's map fixtures has an **added** row followed by a deleted one
//   in the same register, so rewriting `isVisible` as `self == .same` leaves
//   all fourteen `iter.map_range` tests green. The list reader has that shape
//   and seven of its tests go with it, and the new test "a deleted row is the
//   only row a diff does not call visible" asks both predicates of all three
//   tags.
//
// * **`PastSkipper`'s gap arithmetic is `- 1`, and the four diff tests are
//   what hold it.** `iter/tools.rs:451-457` opens a gap with
//   `after - before - 1` or `before - after - 1`; dropping the `- 1` fails
//   "one differing row diffs to one entry, wherever it sits", "a run of
//   differing rows diffs to a run", "a difference at the very first and the
//   very last position" and "the diff applied to the earlier state produces
//   the later state". **None of the range readers' own fixtures reaches
//   `PastSkipper`**: they all read at a `current` clock, which is the
//   `DiffSkipper::Current` arm where every kept row is an addition
//   ([`iter/tools.rs:479`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)),
//   so the two-state arithmetic is pinned here and in `src/doc.zig` only.
//
// * **`Unshift.init` must build from the *advanced* cursor.** `shift.rs:259-263`
//   and `iter/tools.rs:27-36` both draw the lookahead while the cursor is
//   local, and storing the un-advanced one hands the first item back twice.
//   Perturbed to store it, two tests fail: "Unshift draws its lookahead in
//   init, and peeking never consumes" (`expected 1, found 0` on
//   `u.inner.pos()`) and "Unshift keeps 'the walk is over' apart from 'this
//   row carries nothing'".
//
// * **The module doc above was wrong about `doc::DiffIter` and about
//   `ExIdPromise`, and both claims are corrected in place.** `doc::DiffIter`
//   is ported as [`doc.DiffIter`](doc.zig) with four callers in
//   `src/doc.zig`, and `ExIdPromise`/`OpSetOrExId` are `pub` in
//   [`map_range.zig`](map_range.zig).
