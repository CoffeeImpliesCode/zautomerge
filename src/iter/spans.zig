//! The spans reader: a text object as a sequence of runs of graphemes and block
//! markers, each run carrying the marks that were active over it
//! (`rust/automerge/src/iter/spans.rs`, 684 lines).
//!
//! This is the third of the three range readers and the only one that reads
//! **marks**: [`iter/list_range.zig`](list_range.zig) and
//! [`iter/map_range.zig`](map_range.zig) produce one entry per visible element
//! and stop there, and this one folds the mark operations interleaved with the
//! text so that each span answers "what text, and what marks" as one value.
//!
//! # The unit is a span, not an element
//!
//! A `set` row's value can be several graphemes wide (`"héllo"` is one element
//! of width five), so a span is **not** an element. Two spans can also cover the
//! same element at different points of a diff, and one span can cover several
//! elements. The reader therefore coalesces: [`SpanState.pushStr`] appends to
//! the buffered run whenever the diff tag and the active marks are unchanged
//! (`spans.rs:492-511`), and a *mark* row never starts a span of its own — it
//! changes what the next run carries.
//!
//! # The index counts width, and `Del` counts none
//!
//! [`SpanState.index`] is a **text index in the document's encoding**, not an
//! element index. It advances by `encoding.width(s)` for every run and by
//! `encoding.width(PLACEHOLDER)` — one — for a block marker, and by **nothing**
//! for a `Del` (`spans.rs:536-542`, `:575-586`, `:588-595`). A deleted run is
//! not a position in the later state, so it must not move the index; a reader
//! that counted it would report every subsequent span at the wrong offset.
//!
//! # Two mark folds, because this is also the diff side
//!
//! [`SpansDiff`] carries a [`batch.RichTextDiff`] — a `MarkStateMachine` for the
//! document and one for the merge — and a `Same` mark operation is fed to both,
//! an `Add` only to the second and a `Del` only to the first
//! (`spans.rs:663-682`). What [`batch.MarkDiff`] then describes is a *change*:
//! a mark both states agree on is not in it at all (`spans.rs:373-382`). That is
//! what makes a `Same` span carry only the marks that moved, which is exactly
//! what a patch needs — and what a *read* must not do, because a reader wants
//! the marks the span has. [`markView`] is where the two answers are told apart:
//! the tag of the run decides which one the span gets (`spans.rs:317-324`).
//!
//! # What a read gets, and what a diff gets
//!
//! [`Spans`] is a *read*: it is always scoped to a single state, so every row is
//! an `Add` and the marks a span carries are the whole active set. [`SpansDiff`]
//! is the same fold with a [`tools.ClockRange`] in it, and is what a document
//! diff or a patch log drives.
//!
//! # Detached output
//!
//! Blocks are hydrated maps at export time, using the same clock as the read.
//! Text spans own their bytes and deeply copied mark names and values.
//! [`Span.deinit`] releases every payload once. Input [`SpanInput`] values,
//! in contrast, borrow caller maps, text, and mark sets for the write call.
//!
//! **Nothing here reads or writes a stored byte.** The columns, their ids and
//! their order are the compatibility contract and this file is a reader over
//! them.
//!
//! # Ownership
//!
//! **Constructing a reader allocates nothing.** Every cursor is a value over
//! storage the op set already holds and the mark folds start empty; what a read
//! allocates is the run it is buffering and the span it hands out, and those
//! are the caller's.
//!
//! **A reader may be moved at any time, and a span may be held.** Upstream gets
//! both from `Arc<MarkSet>`: a run's marks are a refcount bump on the fold's
//! resolved set, so several spans can name the same set and outlive the reader.
//! The port has no `Arc`, and [`marks.MarkStateMachine`] **mutates its resolved
//! set in place** ([`marks.zig:491`](../../src/marks.zig)), so a borrow of it
//! would read whatever the set says at the next mark operation rather than what
//! it said when the run started. Every mark set a span carries is therefore
//! **copied out** — [`SpanState.refreshMarks`] copies both folds once per mark
//! operation that changes anything, and [`SpanState.runMarks`] copies the view
//! the buffered run needs once per run. That is the price of no refcount, it is
//! the same copy [`opset/batch.zig`](../opset/batch.zig) makes per patch event,
//! and it is why nothing here needs a lifetime parameter.
//!
//! The buffered text transfers to the exported span. At the public export
//! boundary mark names and scalar payloads are copied, and block maps are
//! hydrated recursively. Public spans therefore outlive both the reader and
//! its document; internal spans still borrow scalar payloads from the op set.
//!
//! **The two folds are copied separately and flattened once.** A patch's mark
//! payload is one set, and [`batch.MarkDiff.exportSet`] is where the two folds
//! become one — `Pop::Before` rewrites a name the merge side lacks to a `Null`
//! tombstone (`spans.rs:360-366`), because in a patch a name that is gone *is*
//! an unmark. That rewriting is a statement about the **difference** between
//! two folds, so it may not be applied to one fold on its own:
//! [`SpanState.refreshMarks`] copies each fold with [`copyFold`], name for name
//! and value for value, which is upstream's `MarkDiff::Diff(b.clone(),
//! a.clone())` (`spans.rs:658`), and the flattening happens once per run in
//! [`SpanState.runMarks`]. Applied to a single fold it turns that fold's own
//! marks into tombstones, and every mark boundary then reads as a change.
//!
//! # What one row costs
//!
//! **The rows are read in lockstep, and stepping is `O(1)` amortised.** The
//! action and value columns move together through
//! [`opiter.ActionValueIter`]'s [`tryNext`](../../opset/op_iter.zig), which is a
//! metadata step plus a raw-column take and **does not re-seek the byte
//! cursor** ([`ValueIter.tryNext`](../../opset/op_iter.zig)'s own note is that a
//! step is not a jump). The mark name and op id are read by **distance** rather
//! than by stepping ([`SpansDiff.nextOpid`](Self.nextOpid),
//! [`nextMarkName`](Self.nextMarkName)) — but **only on a `mark` or block row**,
//! so a text with no marks never touches either column, and a text with `P`
//! mark rows pays `O(P · (log S + slab))` for both of them over the whole read,
//! not `O(R)` for each of `R` rows. **The clock is never re-seeked**:
//! [`predates`](map_range.zig) reads [`Clock.contains`](../../src/clock.zig), an
//! array index, and only on a block row.
//!
//! **The mark fold is the one part that was superlinear, and it is now
//! `O(R + P·M)`.** [`NextText.canExtend`] has to answer "do the folds still
//! flatten to what this run carries", and the answer upstream gets from an
//! `Arc` **pointer** test (`spans.rs:301-313`). This port has no `Arc`, so the
//! answer was a **content walk of both folds** — `O(M)` — and it ran on
//! **every row**, which is `O(R·M)`. [`SpanState.marks_epoch`] is the
//! substitute for the pointer: it moves only where the resolved content moved,
//! so an unchanged epoch proves the folds are as the run copied them and the
//! walk is skipped. `R` rows and `P` content-changing mark operations now cost
//! `O(R + P·M)` where they cost `O(R·M)`. **The epoch is a fast path and never
//! the answer** — a moved epoch falls through to the walk, which is what keeps
//! a mark that opens and closes with no text between from splitting the run.
//!
//! [`SpansDiff`], [`SpansInternal`] and [`Spans`] are generic over the op set's
//! row type, and so is [`SpanDiff`], because a span's block payload is an
//! [`maprange.ExIdPromise`]. The fold itself, [`SpanState`], is **not** generic:
//! it holds no op set, and the deferred block it keeps between two `next` calls
//! holds an `OpId` rather than a promise. That is why its three span-returning
//! methods take `comptime O: type` — it is what lets them hand back a
//! [`SpanDiff`] without the fold being generic itself.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const marks = @import("../marks.zig");
const batch = @import("../opset/batch.zig");
const optypes = @import("../opset/types.zig");
const opiter = @import("../opset/op_iter.zig");
const opset = @import("../opset/op_set.zig");
const column = @import("../hexane/column.zig");
const maprange = @import("map_range.zig");
const tools = @import("tools.zig");
const hydrate = @import("../hydrate.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const ReadError = maprange.ReadError || hydrate.OpHydrateError;
const ExIdPromise = maprange.ExIdPromise;
const predates = maprange.predates;
const RowRange = tools.RowRange;
const Diff = tools.Diff;
const Clock = clockmod.Clock;
const ClockRange = clockmod.ClockRange;
const ActorIdx = types.ActorIdx;
const ExId = types.ExId;
const OpId = types.OpId;
const ScalarValue = optypes.ScalarValue;
const MarkDiff = batch.MarkDiff;
const MarkSet = marks.MarkSet;

/// The object replacement character: what a block marker reads as, and what a
/// non-string value in a text reads as (`PLACEHOLDER`, `spans.rs:429`).
///
/// **It is one position wide in every text encoding**, which is the whole
/// reason a block contributes a span of width one and not a run of graphemes.
const placeholder: []const u8 = "\u{fffc}";

// ── The mark diff, as this reader needs it ──────────────────────────────────
//
// [`batch.MarkDiff`] is the type and [`batch.MarkDiff.exportSet`] is the only
// mark flattening in this file — the patch layer's copy carries `export` alone
// and this reader consumes it rather than writing a second one. What is here
// are the two things `batch.zig` does not have and this file needs:
// [`markView`], which is upstream's `RichTextDiff::current` composed with
// `MarkDiff::with` (`spans.rs:653-660`, `:317-324`), and the two feed functions
// [`markBeginDiff`] and [`markEndDiff`] (`spans.rs:663-683`). They live here
// rather than in `batch.zig` because this is the only consumer, and a method
// nobody calls in the other is dead weight.

/// The marks a run of text tagged `diff` carries: upstream's
/// [`RichTextDiff::current`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)
/// (`spans.rs:653-660`) read through [`MarkDiff::with`] (`spans.rs:317-324`).
///
/// `before` and `after` are the two folds' resolved sets **as of the last mark
/// operation**, and the [`SpanState`] that owns them owns what this points at.
/// That ownership is the port's version of upstream's `Arc<MarkSet>`: upstream
/// clones the `Arc` to snapshot a run's marks and the port's
/// [`MarkStateMachine`] **mutates its resolved set in place**
/// ([`marks.zig:491`](../../src/marks.zig)), so a borrow taken earlier reads
/// whatever the set says now. Both steps are here: [`markView`] picks the
/// shape, and [`SpanState.runMarks`] resolves it with
/// [`batch.MarkDiff.exportSet`], which is the only mark flattening in this
/// file.
fn markView(before: ?*const MarkSet, after: ?*const MarkSet, diff: Diff) ?MarkDiff {
    // `RichTextDiff::current`, `spans.rs:653-660`: which of the four shapes a
    // pair of folds is in. All four are reachable, and each is a case upstream
    // spells out.
    const here: ?MarkDiff = if (before) |b|
        (if (after) |a| MarkDiff{ .diff = .{ .before = b, .after = a } } else MarkDiff{ .before = b })
    else if (after) |a|
        MarkDiff{ .after = a }
    else
        null;
    const current = here orelse return null;
    // `MarkDiff::with`, `spans.rs:317-324`: which of the four a run of this tag
    // reads. An `Add` run reads the merge fold outright, a `Same` run reads the
    // difference, and a `Del` run reads nothing.
    return switch (diff) {
        .add => switch (current) {
            .diff => |d| MarkDiff{ .after = d.after },
            .after => current,
            else => null,
        },
        .same => current,
        .del => null,
    };
}

/// One fold's own resolved set, copied name for name and value for value
/// (upstream's `MarkDiff::Diff(b.clone(), a.clone())`, `spans.rs:658`).
///
/// **The copy is the whole of it, and nothing is flattened here.** The fold's
/// set is already one name per mark, in name order
/// ([`MarkSet`](../../src/marks.zig)), so appending its entries reproduces it
/// exactly — including an unmark tombstone, which a flattening would drop
/// (`spans.rs:367-372`, `:419`).
///
/// **It has to be a copy.** Upstream's `Arc<MarkSet>` is copied by bumping a
/// count; the port's [`marks.MarkStateMachine`] **mutates its resolved set in
/// place** ([`marks.zig:491`](../../src/marks.zig)), so a borrow of it would
/// read whatever the set says when the run is finally flushed rather than what
/// it said when the run started. The names inside are borrowed from the
/// document and are not freed with the set, which is [`MarkSet`]'s own rule.
///
/// # Why this appends and does not go through [`MarkSet.fromPairs`]
///
/// **A straight append, and the reason is that the source is already in the
/// shape the destination wants.** [`MarkSet.put`] finds
/// [`lowerBound`](../../src/marks.zig) and **inserts at that index**, which is
/// an `O(M)` shift of every entry behind it — so `fromPairs` over `M` names is
/// `O(M²)` in the memmoves alone, and it grows the array one insert at a time.
/// The source here is a [`MarkSet`], so its entries are **sorted by name and
/// unique**: `lowerBound` on the next name lands on `items.len` and every
/// insert is an append. `appendSlice` is the same `M` appends with the
/// capacity reserved once, so it is **`O(M)` time and one allocation** where
/// `fromPairs` was `O(M²)` time and an amortised-growth array.
///
/// **The output is identical, and that is the whole justification.**
/// `fromPairs`'s own doc says "later pairs replacing earlier ones with the
/// same name", and a `MarkSet` cannot hold two entries with the same name — so
/// over a sorted unique source the replacement arm never fires and the two
/// builders produce byte-identical entry arrays. `refreshMarks` calls this
/// twice per **changed** mark operation, so the term it removes is
/// `O(mark operations × names²)` over a document and `O(names)` per call.
fn copyFold(gpa: Allocator, set: ?*const MarkSet) Error!?MarkSet {
    const s = set orelse return null;
    var out = MarkSet.init(gpa);
    errdefer out.deinit();
    try out.entries.appendSlice(gpa, s.entries.items);
    return out;
}

/// Feeds one mark begin to one or both folds
/// ([`RichTextDiff::mark_begin_diff`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
/// `spans.rs:663-672`) and reports **whether the mark state moved**.
///
/// Upstream's `Diff::Same` arm feeds the document fold first and the merge fold
/// second, and that order is the order here: a corrupt document that raises on
/// the second fold raises the same way.
///
/// **The `Same` arm answers for both folds, not just the second.** The answer is
/// what [`SpanState.refreshMarks`] keys off — a mark operation that changes
/// nothing must not split a buffered run — and for a `Same` mark the two folds
/// are fed the same operation, so either of them moving is a change.
pub fn markBeginDiff(
    folds: *batch.RichTextDiff,
    diff: Diff,
    id: OpId,
    data: marks.MarkData,
) Error!bool {
    return switch (diff) {
        .add => folds.after.markBegin(id, data),
        .del => folds.before.markBegin(id, data),
        .same => blk: {
            const was_before = try folds.before.markBegin(id, data);
            const was_after = try folds.after.markBegin(id, data);
            break :blk was_before or was_after;
        },
    };
}

/// Feeds one mark end to one or both folds
/// ([`RichTextDiff::mark_end_diff`], `spans.rs:674-683`).
/// **Both folds answer for a `Same`**, for the reason
/// [`markBeginDiff`] gives.
pub fn markEndDiff(folds: *batch.RichTextDiff, diff: Diff, id: OpId) Error!bool {
    return switch (diff) {
        .add => folds.after.markEnd(id),
        .del => folds.before.markEnd(id),
        .same => blk: {
            const was_before = try folds.before.markEnd(id);
            const was_after = try folds.after.markEnd(id);
            break :blk was_before or was_after;
        },
    };
}

/// The two folds' entries, as [`batch.MarkDiff.exportSet`] reads them
/// ([`Pop::Before` and `Pop::After`](spans.rs):326-340`).
fn beforeEntriesOf(view: batch.MarkDiff) []const MarkSet.Entry {
    return switch (view) {
        .nothing, .after => &.{},
        .before => |b| b.entries.items,
        .diff => |d| d.before.entries.items,
    };
}

fn afterEntriesOf(view: batch.MarkDiff) []const MarkSet.Entry {
    return switch (view) {
        .nothing, .before => &.{},
        .after => |a| a.entries.items,
        .diff => |d| d.after.entries.items,
    };
}

/// Whether the pairs `view` flattens to are exactly those of `flat`
/// ([`MarkDiff::eq`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs):299-314`'s
/// `_ => self.iter().eq(other.iter())` arm).
///
/// **A content comparison, and that is the whole of the question
/// [`SpanState.next_text`] has to ask.** Upstream's equality is a pointer test
/// on the two `Arc`s **and then a walk of both flattenings**
/// (`spans.rs:301-313`); the pointer test is the fast path the comment at
/// `spans.rs:300` says was added because the walk "was a big performance
/// issue", and the walk is the definition. [`MarkSet`] is a `BTreeMap`
/// upstream (`marks.rs:106-108`) and a name-sorted array here
/// ([`MarkSet.entries`](../../src/marks.zig)), so the two flattenings are
/// compared **in name order**, which is what `Iterator::eq` does upstream.
///
/// **The same three-way merge as [`batch.MarkDiff.exportSet`], without the
/// allocation, and for every one of the four shapes.** `exportSet` builds the
/// list and hands it over; here the list is compared against `flat` as it is
/// produced, which is what makes the comparison affordable on **every** row
/// rather than once per run.
///
/// **There is deliberately no shortcut for the one-fold shapes.** A `before`
/// or an `after` does not flatten to itself: `Pop::Before` rewrites every
/// non-tombstone name to `ScalarValue::Null` (`spans.rs:360-366`) and
/// `Pop::After` drops every tombstone (`spans.rs:367-372`), so
/// `{bold: true}` flattens to `{bold: Null}` under the first and to `{bold:
/// true}` under the second. Comparing the raw entries instead answers a
/// different question, and it answers it wrongly for any mark being added
/// (`after`) or deleted (`before`) — which is to say, for a mark that exists
/// on exactly one side of a diff. [`beforeEntriesOf`] and
/// [`afterEntriesOf`] already read a one-fold shape as an empty other side,
/// so the merge below covers all four with no arm of its own.
fn flattenedEql(view: ?batch.MarkDiff, flat: ?MarkSet) bool {
    const v = view orelse return flat == null;
    // `.nothing` is not reachable from [`markView`] — a view with neither fold
    // is a null view, not a `.nothing` — but the union is exhaustive and the
    // answer is the same either way: no folds, no pairs.
    if (v == .nothing) return flat == null;
    const b = beforeEntriesOf(v);
    const a = afterEntriesOf(v);
    // **`flat` is walked by a cursor and not indexed by name**: a `MarkSet`
    // keeps its entries sorted, so the flattening and the set agree on the
    // order and one index answers "is there anything left to disagree with".
    const want = if (flat) |f| f.entries.items else &[_]MarkSet.Entry{};
    var at: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    // **The same merge, arm for arm, as [`batch.MarkDiff.exportSet`].** The
    // only difference is the tail: `exportSet` appends, this compares and
    // gives up on the first disagreement.
    while (i < b.len or j < a.len) {
        const which: enum { before, after, both } = if (i >= b.len)
            .after
        else if (j >= a.len)
            .before
        else switch (std.mem.order(u8, b[i].name, a[j].name)) {
            .lt => .before,
            .gt => .after,
            .eq => .both,
        };
        var pair: MarkSet.Entry = undefined;
        switch (which) {
            .before => {
                pair = .{ .name = b[i].name, .value = .null_value };
                i += 1;
                // `spans.rs:360-366` — a name only the document had comes out
                // as an unmark tombstone, and a name whose value already was
                // null contributes no pair at all.
                if (b[i - 1].value == .null_value) continue;
            },
            .after => {
                pair = .{ .name = a[j].name, .value = a[j].value };
                j += 1;
                // `spans.rs:367-372` — a name only the merge fold had, kept.
                if (a[j - 1].value == .null_value) continue;
            },
            .both => {
                std.debug.assert(std.mem.eql(u8, b[i].name, a[j].name));
                pair = .{ .name = a[j].name, .value = a[j].value };
                i += 1;
                j += 1;
                // `spans.rs:373-382` — both folds agree, so the pair is
                // dropped; that is what makes an unchanged mark invisible.
                if (b[i - 1].value.eql(a[j - 1].value)) continue;
            },
        }
        if (at >= want.len) return false;
        if (!std.mem.eql(u8, want[at].name, pair.name) or !want[at].value.eql(pair.value)) {
            return false;
        }
        at += 1;
    }
    return at == want.len;
}

// ── One span, as the diff sees it ───────────────────────────────────────────

/// One span of a text object, with what happened to it ([`SpanDiff`],
/// `spans.rs:15-19`).
///
/// Upstream's is not generic and neither would this be, except that the block
/// arm carries an [`maprange.ExIdPromise`]: upstream holds an `OpId` here and
/// turns it into an `ObjId` at export ([`spans.rs:606-626`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)),
/// and a promise is the port's spelling of "the id, and the op set that will
/// resolve it". It is what keeps the actor table off the fold.
///
/// **The text is owned** and must be released with [`SpanDiff.deinit`], which is
/// upstream's `String` drop.
pub fn SpanDiff(comptime O: type) type {
    return struct {
        const Self = @This();

        /// What happened to the span between the two states (`spans.rs:17`).
        diff: Diff,
        /// The span itself (`spans.rs:18`).
        span: SpanInternal(O),

        /// Gives back the span's own bytes and its marks, **and the span is
        /// dead once this returns**: the call ends in `self.* = undefined`, so
        /// a second one reads undefined memory rather than reaching an
        /// allocator that could diagnose the double free — `Debug` and
        /// `ReleaseSafe` are the builds that would have said something. A block
        /// arm owns no bytes and frees none; the op set its
        /// [`maprange.ExIdPromise`](map_range.zig) names is borrowed.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.span.deinit(gpa);
            self.* = undefined;
        }

        /// Detaches the public payload, using the requested object clock.
        /// Consumes this span on success only; the caller retains it on error.
        /// `gpa` must be the allocator that owns the internal text buffer.
        pub fn exportSpan(
            self: Self,
            gpa: Allocator,
            set: *opset.OpSet(O),
            clock: ?Clock,
        ) ReadError!Span {
            return self.span.exportSpan(gpa, set, clock);
        }
    };
}

/// A span of a text object before its marks are resolved ([`SpanInternal`],
/// `spans.rs:403-407`).
///
/// Upstream's is a tuple; the port spells the three fields out because a
/// payload with three same-typed fields and no names is unreadable, and the
/// names are upstream's parameter names.
pub fn SpanInternal(comptime O: type) type {
    return union(enum) {
        const Self = @This();

        /// A run of graphemes (`spans.rs:405`, `Text(String, usize, MarkDiff)`).
        text: struct {
            /// The run's text, **owned** — upstream's `String`.
            text: []u8,
            /// Where the run starts, in the document's text encoding
            /// (`spans.rs:405`'s second field).
            index: usize,
            /// The marks that changed over the run (`spans.rs:405`'s third
            /// field), **resolved and owned**.
            ///
            /// Upstream's is a `MarkDiff` over an `Arc<MarkSet>` and it is
            /// resolved at export (`spans.rs:614-616`); the port resolves it
            /// when the run is flushed instead, because its fold's resolved set
            /// is mutated in place ([`marks.zig:491`](../../src/marks.zig)) and
            /// a borrow would not survive the next mark operation. What a caller
            /// sees is the same either way.
            marks: ?MarkSet,
        },
        /// A block marker (`spans.rs:406`, `Obj(OpId, usize, bool)`).
        obj: struct {
            /// The id of the object the marker names (`spans.rs:406`'s first
            /// field), and the op set that resolves it.
            id: ExIdPromise(O),
            /// Where the marker starts (`spans.rs:406`'s second field).
            index: usize,
            /// Whether this marker newly exposes an object that a state was
            /// shadowing (`spans.rs:406`'s third field; `ClockRange::predates`,
            /// `spans.rs:191`). A read at the present is never an expose, and
            /// only a `Diff` ever is.
            expose: bool,
        },

        /// Gives back the run's bytes and its marks, if this span holds any,
        /// **and leaves the value unusable**: `self.* = undefined` is the last
        /// line, so a second call reads undefined memory rather than reaching
        /// an allocator. A `.obj` arm owns nothing and frees nothing — its id
        /// is a number and its op set is the document's.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            switch (self.*) {
                .text => |*t| {
                    gpa.free(t.text);
                    if (t.marks) |*m| m.deinit();
                },
                .obj => {},
            }
            self.* = undefined;
        }

        /// Detaches all payloads from the source op set.
        /// Consumes text storage on success only; allocation failure leaves
        /// this internal span owned by the caller.
        /// Use the iterator's allocator for `gpa` and the result's deinit.
        pub fn exportSpan(
            self: Self,
            gpa: Allocator,
            set: *opset.OpSet(O),
            clock: ?Clock,
        ) ReadError!Span {
            return switch (self) {
                .text => |t| blk: {
                    const detached = if (t.marks) |*mark_set|
                        try mark_set.dup(gpa)
                    else
                        null;
                    var old_marks = t.marks;
                    if (old_marks) |*mark_set| mark_set.deinit();
                    break :blk .{ .text = .{ .text = t.text, .marks = detached } };
                },
                .obj => |o| blk: {
                    const value = try hydrate.hydrateMap(
                        opset.OpSet(O),
                        set,
                        gpa,
                        o.id.exid(),
                        clock,
                    );
                    break :blk .{ .block = value.object.map };
                },
            };
        }
    };
}

/// Owned text runs and block maps. Every byte, mark and actor hint is detached.
/// Release a returned span once with the allocator used by its iterator.
pub const Span = union(enum) {
    /// A span of text and the marks that were active for that span
    /// (`spans.rs:412-415`).
    text: struct {
        /// The text, owned.
        text: []u8,
        /// The marks, or null when the span carries none (`spans.rs:414`).
        marks: ?MarkSet,
    },
    /// The complete block payload, owned independently of the document.
    block: hydrate.Map,

    /// Releases every payload once. A shallow assignment is an ownership move.
    pub fn deinit(self: *Span, gpa: Allocator) void {
        switch (self.*) {
            .text => |*t| {
                gpa.free(t.text);
                if (t.marks) |*m| m.deinit();
            },
            .block => |*block| block.deinit(),
        }
        self.* = undefined;
    }

    /// Deeply copies all payloads; both spans can be mutated and freed alone.
    pub fn dup(self: *const Span, gpa: Allocator) Error!Span {
        return switch (self.*) {
            .block => |*block| .{ .block = try block.dup(gpa) },
            .text => |t| blk: {
                const text = try gpa.dupe(u8, t.text);
                errdefer gpa.free(text);
                const mark_set = if (t.marks) |*held| try held.dup(gpa) else null;
                break :blk .{ .text = .{ .text = text, .marks = mark_set } };
            },
        };
    }

    /// The text a span reads as ([`Span::as_str`], `spans.rs:421-426`).
    ///
    /// **A block reads as the object replacement character**, U+FFFC, and not
    /// as the empty string. That is what makes concatenating every span's
    /// `asStr()` the object's text, which the tests
    /// `test "plain text reads as one span per run, and the runs are the object's text"`
    /// and `test "a block marker is its own span of width one, and the text around it is untouched"`
    /// both hold.
    pub fn asStr(self: *const Span) []const u8 {
        return switch (self.*) {
            .text => |t| t.text,
            .block => placeholder,
        };
    }
};

/// Borrowed update-spans input. The writer copies block and mark payloads;
/// every source slice/map/set must remain live only until the call returns.
pub const SpanInput = union(enum) {
    block: *const hydrate.Map,
    text: struct {
        text: []const u8,
        marks: ?*const MarkSet = null,
    },
};

// ── The fold ────────────────────────────────────────────────────────────────

/// The run of graphemes being built ([`NextText`], `spans.rs:457-478`).
///
/// Upstream's buffer is a `String` and so is this one, as an unmanaged list;
/// the difference is that this file has to say who frees it, and the answer is
/// the allocator [`SpanState`] was built with.
const NextText = struct {
    /// The text so far (`spans.rs:460`).
    buff: std.ArrayList(u8) = .empty,
    /// What happened to the run (`spans.rs:462`).
    diff: Diff = .same,
    /// The length of the run **in the document's text encoding** (`spans.rs:464`),
    /// which is not its byte length and not its grapheme count under every
    /// encoding.
    len: usize = 0,
    /// The marks the run carries (`spans.rs:467`), **owned**.
    ///
    /// Upstream's is `marks.with(diff)` over an `Arc<MarkSet>` it cloned; here
    /// the clone is [`batch.MarkDiff.exportSet`]'s own copy, and it happens once
    /// per run instead of once per row. It has to be a copy: the port's
    /// [`marks.MarkStateMachine`] mutates its resolved set in place, so a
    /// borrow of it would read whatever the set says when the run is finally
    /// flushed rather than what it said when the run started.
    marks: ?MarkSet = null,
    /// The fold's [`marks_epoch`](SpanState.marks_epoch) when this run took
    /// its marks, and **the only reason `canExtend` is O(1) on the common
    /// row**.
    ///
    /// **A stamp, not a decision.** An equal epoch means the folds have not
    /// moved since [`runMarks`](SpanState.runMarks) copied them, so the
    /// flattening this run holds is still what the folds flatten to — which
    /// makes [`flattenedEql`](spans.zig#L341) true without walking it. A
    /// differing epoch means only that something *may* have moved, and the
    /// walk answers as it always did. So this field never decides whether a
    /// run extends; it only decides whether deciding costs a walk.
    ///
    /// **Upstream gets the same short-circuit for free and by a different
    /// means.** Its run holds an `Arc<MarkSet>` and the fold holds the same
    /// `Arc`, so `MarkDiff::eq`'s pointer test (`spans.rs:301-313`) answers
    /// "equal" in one comparison whenever no mark operation has run. The port
    /// has no `Arc` and the resolved set is mutated in place, so the fold
    /// *copies* it and there is no pointer to compare — which is why this
    /// stamp exists, and why the copy is what makes the walk necessary at all.
    marks_epoch: u64 = 0,

    /// An empty run for `diff`, already carrying the marks `state` says a
    /// run of that tag carries ([`NextText::new`], `spans.rs:470-477`).
    fn init(state: *SpanState, diff: Diff) Error!NextText {
        return .{
            .diff = diff,
            .marks = try state.runMarks(diff),
            .marks_epoch = state.marks_epoch,
        };
    }

    /// Gives back the buffer and the marks.
    fn deinit(self: *NextText, gpa: Allocator) void {
        self.buff.deinit(gpa);
        if (self.marks) |*m| m.deinit();
        self.* = undefined;
    }

    /// Appends `s`, and adds its width in `enc` to the run's length.
    fn appendStr(self: *NextText, gpa: Allocator, enc: types.TextEncoding, s: []const u8) Error!void {
        try self.buff.appendSlice(gpa, s);
        self.len += enc.width(s);
    }

    /// Whether this run can absorb more text tagged `diff` — upstream's
    /// `diff != next.diff || self.marks != next.marks` (`spans.rs:496`).
    ///
    /// **The marks half is a content comparison, and it has to be.**
    /// `self.marks` is the fold's current [`batch.MarkDiff`] and `self` is
    /// the run's copy of what that view flattened to when the run started;
    /// upstream compares the two with [`flattenedEql`], which is
    /// [`MarkDiff::eq`](spans.rs):299-314`'s walk. The case that makes this
    /// the whole difference is a mark that opens and closes with no text in
    /// between: the fold's set changes and comes back, and a run whose marks
    /// still say what they said keeps the text it has — which is upstream's
    /// `marks_are_consolidated_in_the_presence_of_zero_length_spans`
    /// (`tests/text.rs:297-319`).
    ///
    /// # The complexity, and the two branches
    ///
    /// **O(1) when the epoch matches, O(M) when it does not**, where `M` is
    /// the number of mark names the folds hold. `flattenedEql` merges both
    /// folds' entries name by name, so it is `O(M)`; upstream is the same walk
    /// but reaches it only after a **pointer** test on the two `Arc`s has
    /// already answered (`spans.rs:301-313`, and the comment at `spans.rs:300`
    /// says that test was added because the walk "was a big performance
    /// issue"). This port has no `Arc` to test, so the stamp stands in: equal
    /// epochs are a proof that the folds have not moved since
    /// [`marks`](NextText.marks) was copied, which makes the walk's answer
    /// known without running it.
    ///
    /// **The epoch never turns a walk into a wrong answer, only into a
    /// skipped one.** It is bumped only where the resolved content moved
    /// ([`SpanState.marks_epoch`]), so `epoch == marks_epoch` implies the two
    /// flattenings are equal. The converse is not claimed: a differing epoch
    /// may still flatten equal, and then the walk says so, which is what keeps
    /// `marks_are_consolidated_in_the_presence_of_zero_length_spans` true —
    /// `bold` opening and closing bumps the epoch twice, so that case always
    /// takes the walk and is answered by content as upstream answers it.
    ///
    /// **What this buys, over a read.** The walk is per **row** and the epoch
    /// moves per **mark operation that changed the marks**, so a text of `R`
    /// rows and `P` mark operations costs `O(R + P·M)` where it cost `O(R·M)`.
    /// A marked document with many rows and few mark boundaries — the ordinary
    /// case — goes from quadratic in `R·M` to linear in `R`.
    ///
    /// **A `Del` run agrees on both branches, and that is checked rather than
    /// assumed.** [`markView`] answers `null` for a `del` tag (`spans.rs:317-324`),
    /// so [`runMarks`](SpanState.runMarks) gave such a run `marks == null`, and
    /// [`flattenedEql`] with a null view answers `flat == null`
    /// (`spans.zig:319`) — true against that `null`. So the short-circuit's
    /// `true` and the walk's `true` are the same answer for a `Del`, and a
    /// deleted run coalesces exactly as it did.
    fn canExtend(self: *const NextText, state: *const SpanState, diff: Diff) bool {
        if (self.diff != diff) return false;
        if (self.marks_epoch == state.marks_epoch) return true;
        const view = markView(
            if (state.before) |*b| b else null,
            if (state.after) |*a| a else null,
            diff,
        );
        return flattenedEql(view, self.marks);
    }
};

/// The fold that turns rows into spans ([`SpanState`], `spans.rs:431-595`).
///
/// **Not generic**, and the reason is worth stating because it is what the
/// three span-returning methods are shaped the way they are: this struct holds
/// no op set and no promise. What it holds between two `next` calls is a
/// *block* — [`pushBlock`](Self.pushBlock) is the only writer of
/// `next_diff` and [`flush`](Self.flush) and
/// [`pushStr`](Self.pushStr) both assert it is empty — and a block is
/// identified by an `OpId` plus an index, an expose flag and a width. Turning
/// that into a [`SpanDiff`] is the one job that needs `O`, so
/// [`pushBlock`](Self.pushBlock), [`flush`](Self.flush),
/// [`pop`](Self.pop) and [`pushStr`](Self.pushStr) / [`pushUnmarkedAddStr`](Self.pushUnmarkedAddStr)
/// take `comptime O: type` and take the op set where they need one.
const SpanState = struct {
    /// The allocator every buffer this fold makes is taken with.
    gpa: Allocator,
    /// Where the next span starts, in the document's text encoding
    /// (`spans.rs:434`).
    index: usize = 0,
    /// The run we will emit next (`spans.rs:436`).
    next_text: ?NextText = null,
    /// The **document** fold's resolved marks as of the last mark operation,
    /// **owned** (`spans.rs:448`'s `marks`, the `Before` half).
    before: ?MarkSet = null,
    /// The **merge** fold's resolved marks as of the last mark operation,
    /// **owned** (the `After` half).
    after: ?MarkSet = null,
    /// How many times the folds' resolved content has **moved**, as of the
    /// last mark operation.
    ///
    /// **This counts content changes and not mark operations, and that is the
    /// whole of what makes it usable.** The question
    /// [`NextText.canExtend`] asks is "do the fold's marks still say what the
    /// buffered run's marks say", and the source says the answer is the
    /// *content* of the two (`spans.rs:496`,
    /// [`MarkDiff::eq`](spans.rs):299-314'). A counter over mark
    /// *operations* was here and could not answer that question: it only goes
    /// up, so a mark that opened and closed with no text between — the case
    /// `spans.rs:436-447` is written about, where the active set passes
    /// through `['bold', 'bold,italic', 'bold']` while the buffered run keeps
    /// `bold` — split the run anyway.
    ///
    /// **This one is bumped in [`refreshMarks`](Self.refreshMarks) alone**,
    /// and that is only reached when [`markBeginDiff`] or [`markEndDiff`]
    /// reported that the *resolved set* changed — which is a statement about
    /// content, because [`marks.MarkStateMachine.markBegin`] returns whether
    /// it wrote `resolved` ([`marks.zig:674-695`](../../src/marks.zig)) and
    /// not whether it was fed an operation. So a shadowed mark, or one whose
    /// value the one below already has, leaves this alone.
    ///
    /// **It is a fast path and never the answer.** An epoch equal to the run's
    /// proves the folds have not moved since the run captured its marks, which
    /// makes [`flattenedEql`] *trivially* true — so the walk is skipped. An
    /// epoch that differs proves nothing either way (the fold may have moved
    /// and come back), and falls through to the walk unchanged. That is why the
    /// zero-length-span case still consolidates: `bold` opening and closing
    /// moves the content twice, so the epoch differs and
    /// [`flattenedEql`](spans.zig#L341) is what answers, and it answers true.
    marks_epoch: u64 = 0,
    /// A block marker seen but not yet emitted, because emitting it means
    /// emitting the text in front of it first (`spans.rs:449-453`).
    next_diff: ?PendingBlock = null,
    /// How the object measures text (`spans.rs:454`).
    encoding: types.TextEncoding,

    /// A block marker held back for one call
    /// (upstream's `Option<(SpanDiff, usize)>`, `spans.rs:453`).
    ///
    /// Upstream stores a whole `SpanDiff`; this stores the five facts one is
    /// made of, because a `SpanDiff` is generic over `O` and this struct is
    /// not. The second half of upstream's tuple — the width — is here as
    /// [`width`](Self.width) and is what [`pop`](Self.pop) adds to the index.
    const PendingBlock = struct {
        /// What happened to the marker (`spans.rs:544`).
        diff: Diff,
        /// The id of the object the marker names (`spans.rs:544`).
        id: OpId,
        /// Where the marker starts (`spans.rs:548`).
        index: usize,
        /// Whether it exposes (`spans.rs:548`).
        expose: bool,
        /// How wide it is in the document's encoding (`spans.rs:546`): one,
        /// and zero for a `Del`.
        width: usize,
    };

    /// A fold over `enc`, with nothing read and nothing allocated.
    fn init(gpa: Allocator, enc: types.TextEncoding) SpanState {
        return .{ .gpa = gpa, .encoding = enc };
    }

    /// Gives back the buffered run and both folds' snapshots.
    fn deinit(self: *SpanState) void {
        if (self.next_text) |*t| t.deinit(self.gpa);
        if (self.before) |*b| b.deinit();
        if (self.after) |*a| a.deinit();
        self.* = undefined;
    }

    /// Throws away the fold's state and starts again, keeping the allocator and
    /// the encoding ([`SpansDiff::shift_next`]'s
    /// `SpanState::empty(self.state.encoding)`, `spans.rs:158`).
    ///
    /// **The two fields are read before [`deinit`](Self.deinit), not after.**
    /// `deinit` ends with `self.* = undefined`, so reading `self.gpa` after it
    /// is a read of undefined memory — and `gpa` is a struct of two pointers,
    /// so the next allocation goes through a garbage vtable. That is what put
    /// `General protection exception` inside
    /// [`batch.MarkDiff.exportSet`](../../src/opset/batch.zig) and inside
    /// [`NextText.appendStr`](NextText.appendStr) on the
    /// [`SpansDiff::shiftNext`](Self.shiftNext) path: both allocate with
    /// `self.gpa`, and by then `self.gpa` was whatever `undefined` was.
    fn reset(self: *SpanState) void {
        const gpa = self.gpa;
        const enc = self.encoding;
        self.deinit();
        self.* = init(gpa, enc);
    }

    /// Copies both folds' resolved marks out
    /// ([`RichTextDiff::current`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
    /// `spans.rs:653-660`).
    ///
    /// **Called only when a mark operation actually changed something** — the
    /// same condition upstream pushes unconditionally for
    /// (`spans.rs:216-217`), and the reason the port can narrow it is that
    /// nothing downstream watches for the push: [`NextText.canExtend`]
    /// compares the content of the sets, so a mark operation that changes
    /// nothing and is not copied out leaves the same answer standing.
    ///
    /// **Each fold is copied on its own, and never through
    /// [`batch.MarkDiff.exportSet`](../../src/opset/batch.zig)** — that
    /// function is a *flattening*, and flattening one fold alone is where the
    /// tombstone mapping leaks in. `MarkDiff{ .before = set }` reads as
    /// `Pop::Before` (`spans.rs:360-366`), which turns every name the other
    /// side lacks into `ScalarValue::Null`: right for a patch, where a name
    /// the merge dropped *is* an unmark, and wrong here, where the document
    /// fold's own marks would all come back as tombstones. Upstream keeps the
    /// two sets apart for exactly this reason (`MarkDiff::Diff(b.clone(),
    /// a.clone())`, `spans.rs:658`) and flattens once, at export
    /// (`spans.rs:389-400`); the copy below is upstream's `clone`, and the
    /// flattening still happens once per run in [`runMarks`](Self.runMarks).
    ///
    /// # What this costs, and what it moves
    ///
    /// **Two `copyFold` calls, each `O(M)` in the names the fold holds and one
    /// allocation** (see [`copyFold`]). So this is `O(M)` per mark operation
    /// that changed the marks — not per row, and not `O(M²)` any more.
    ///
    /// **It moves [`marks_epoch`](Self.marks_epoch), and it is the only writer
    /// of that field.** That is what makes the epoch mean what
    /// [`NextText.canExtend`] needs it to mean: every content change passes
    /// through here, so an epoch that did not move is a proof the folds are
    /// exactly as the run copied them.
    ///
    /// **The bump comes first, and the order is the safety property.** A moved
    /// epoch sends [`canExtend`](NextText.canExtend) to the walk, which reads
    /// whatever the folds actually hold — so on every path out of this
    /// function the answer is at worst the pre-existing one, which always
    /// walked. Bumping last would be the other way round: a copy that failed
    /// on `error.OutOfMemory` would leave the epoch unmoved over folds whose
    /// content *had* moved, and the short-circuit would then publish a stale
    /// answer. Bumping first cannot: a moved epoch only ever costs a walk.
    fn refreshMarks(self: *SpanState, folds: *const batch.RichTextDiff) Error!void {
        self.marks_epoch +%= 1;
        if (self.before) |*b| b.deinit();
        self.before = null;
        if (self.after) |*a| a.deinit();
        self.after = null;
        self.before = try copyFold(self.gpa, folds.before.current());
        self.after = try copyFold(self.gpa, folds.after.current());
    }

    /// The marks a run tagged `diff` carries, resolved and owned
    /// ([`markView`] over [`batch.MarkDiff.exportSet`]).
    fn runMarks(self: *SpanState, diff: Diff) Error!?MarkSet {
        const before: ?*const MarkSet = if (self.before) |*b| b else null;
        const after: ?*const MarkSet = if (self.after) |*a| a else null;
        const view = markView(before, after, diff) orelse return null;
        return view.exportSet(self.gpa);
    }

    /// How wide `s` is under this diff: nothing at all for a `Del`
    /// ([`SpanState::diff_width`], `spans.rs:536-542`).
    ///
    /// **This is the whole of the index accounting's asymmetry.** A deleted
    /// span has a position — the position it used to occupy — but it is not a
    /// position in the later state, so it contributes nothing.
    fn diffWidth(self: *const SpanState, diff: Diff, s: []const u8) usize {
        return if (diff == .del) 0 else self.encoding.width(s);
    }

    /// Appends `s` to the run being built, emitting the run first if the diff
    /// tag or the marks have moved ([`SpanState::push_str`], `spans.rs:492-511`).
    ///
    /// The three tags are threaded through unchanged; **a `Del` is text like
    /// any other** and lands in the same buffer under the same flush rule, and
    /// [`SpanState.diffWidth`] is what makes it cost no index.
    fn pushStr(
        comptime O: type,
        self: *SpanState,
        diff: Diff,
        s: []const u8,
    ) Error!?SpanDiff(O) {
        // `spans.rs:493`, a `debug_assert!` upstream and an assertion here:
        // nothing may reach the run while a block is held back.
        std.debug.assert(self.next_diff == null);

        const flush_needed = if (self.next_text) |next| !next.canExtend(self, diff) else false;
        var span: ?SpanDiff(O) = if (flush_needed) try SpanState.flush(O, self) else null;
        errdefer if (span) |*owned| owned.deinit(self.gpa);

        if (self.next_text == null) self.next_text = try NextText.init(self, diff);
        const run = &self.next_text.?;
        std.debug.assert(run.diff == diff or run.len == 0);
        run.diff = diff;
        try run.appendStr(self.gpa, self.encoding, s);
        return span;
    }

    /// Appends unmarked added text to the run, skipping the diff and mark
    /// comparisons when the run is already exactly that
    /// ([`SpanState::push_unmarked_add_str`], `spans.rs:513-534`).
    ///
    /// **This is the hot path of a plain read** and the reason it is spelled
    /// out: an unmarked `Add` appended to an unmarked `Add` run cannot change
    /// the run's diff or its marks, so the two comparisons in
    /// [`pushStr`](Self.pushStr) are work whose answer is already known. Every
    /// other case falls through to [`pushStr`](Self.pushStr), and `s` is
    /// appended **once** on that path — the fast arms return before reaching
    /// it.
    fn pushUnmarkedAddStr(
        comptime O: type,
        self: *SpanState,
        s: []const u8,
    ) Error!?SpanDiff(O) {
        std.debug.assert(self.next_diff == null);
        // **Unmarked and added**: no mark snapshot is needed to know that, and
        // that is the whole of the fast path — a plain read of an unmarked text
        // never copies a mark set at all.
        //
        // **The two mark tests are the whole of upstream's condition and
        // nothing else** (`spans.rs:518-520`): the fold has no mark
        // (`matches!(self.marks, MarkDiff::Nothing)`) and the run has none
        // (`matches!(next.marks, MarkDiff::Nothing)`), and two "no marks" are
        // equal. There is deliberately no third test comparing the run against
        // the fold, because a run with no marks can only have been started
        // while the fold had none, and [`isUnmarked`](Self.isUnmarked) is that
        // same fact read now.
        if (self.isUnmarked()) {
            if (self.next_text) |*run| {
                if (run.diff == .add and run.marks == null) {
                    try run.appendStr(self.gpa, self.encoding, s);
                    return null;
                }
            } else {
                var run = try NextText.init(self, .add);
                errdefer run.deinit(self.gpa);
                run.marks = null;
                try run.appendStr(self.gpa, self.encoding, s);
                self.next_text = run;
                return null;
            }
        }
        return SpanState.pushStr(O, self, .add, s);
    }

    /// Emits a block marker, flushing the text in front of it first and holding
    /// the marker back for the next call
    /// ([`SpanState::push_block`], `spans.rs:544-556`).
    ///
    /// **The flush-then-hold is not an optimisation.** A caller's spans are in
    /// document order, so a marker cannot be handed out before the run that
    /// precedes it; holding it back is what keeps [`SpanState.pop`] able to
    /// emit it *after* the flushed run and before whatever comes next. The
    /// index does not advance when the marker is held — only when it is popped
    /// (`spans.rs:589-594`) — so the flushed run's own index is still correct
    /// at the moment it is emitted.
    fn pushBlock(
        comptime O: type,
        self: *SpanState,
        set: *opset.OpSet(O),
        diff: Diff,
        id: OpId,
        expose: bool,
    ) Error!?SpanDiff(O) {
        std.debug.assert(self.next_diff == null);
        const width = self.diffWidth(diff, placeholder);
        if (try SpanState.flush(O, self)) |result| {
            self.next_diff = .{
                .diff = diff,
                .id = id,
                .index = self.index,
                .expose = expose,
                .width = width,
            };
            return result;
        }
        const at = self.index;
        self.index += width;
        return .{
            .diff = diff,
            .span = .{ .obj = .{
                .id = ExIdPromise(O).init(set, id),
                .index = at,
                .expose = expose,
            } },
        };
    }

    /// Whether any mark is active — upstream's
    /// `matches!(self.marks, MarkDiff::Nothing)`
    /// ([`spans.rs:518`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    fn isUnmarked(self: *const SpanState) bool {
        return self.before == null and self.after == null;
    }

    /// Emits the run being built, if there is one
    /// ([`SpanState::flush`], `spans.rs:563-586`).
    ///
    /// **A zero-length run is not a span**, and that is what makes a run of
    /// mark operations produce nothing (`spans.rs:575-577`; upstream's
    /// `spans_are_consolidated_in_the_presence_of_zero_length_spans`,
    /// `tests/text.rs:298-319`). A mark that opens and closes with no text
    /// between it never reaches a caller's hands.
    fn flush(comptime O: type, self: *SpanState) Error!?SpanDiff(O) {
        std.debug.assert(self.next_diff == null);
        const run = if (self.next_text) |*held| held else return null;
        if (run.len == 0) {
            run.deinit(self.gpa);
            self.next_text = null;
            return null;
        }
        // Transfer an exact allocation-sized slice, not a best-effort shrink.
        // OOM leaves the complete run in the state for the reader to release.
        const text = try run.buff.toOwnedSlice(self.gpa);
        const diff = run.diff;
        const len = run.len;
        const marks_owned = run.marks;
        self.next_text = null;
        const at = self.index;
        if (diff != .del) self.index += len;
        return .{
            .diff = diff,
            .span = .{ .text = .{
                .text = text,
                .index = at,
                .marks = marks_owned,
            } },
        };
    }

    /// Emits a held block marker, if one is held
    /// ([`SpanState::pop`], `spans.rs:588-595`).
    fn pop(comptime O: type, self: *SpanState, set: *opset.OpSet(O)) ?SpanDiff(O) {
        const held = self.next_diff orelse return null;
        self.next_diff = null;
        if (held.diff != .del) self.index += held.width;
        return .{
            .diff = held.diff,
            .span = .{ .obj = .{
                .id = ExIdPromise(O).init(set, held.id),
                .index = held.index,
                .expose = held.expose,
            } },
        };
    }
};

// ── Where the rows come from ────────────────────────────────────────────────

/// The action and value columns read as one walk whose step can say "no more"
/// ([`ActionValueIter`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_iter.rs),
/// `op_iter.rs:766-805`).
///
/// **This is an adapter and not a new cursor.** Upstream's `ActionValueIter`
/// has one, [`Iterator::next`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_iter.rs)
/// (`op_iter.rs:781-787`), and it answers `None` at the end of the window. The
/// port spells that step `tryNext` and makes it **total** — a row it cannot
/// read is `error.MissingValue`, not a `null` every caller has to remember to
/// check ([`op_iter.zig:1081-1092`](../../opset/op_iter.zig)) — because every
/// sub-iterator under it has a total item type. A lookahead over a total step
/// cannot be built, and [`tools.Unshift`] is how a lookahead is built, so this
/// type is the four lines that restore the partial shape upstream had.
///
/// The window is `pos .. maxPos` and `next` respects it, which is exactly what
/// the underlying column cursor's own `next` does at its end.
///
/// **The methods are `pub` although the type is not**, and that is not
/// decoration: [`tools.ItemOf`] finds the step with `@hasDecl`, which does not
/// see a private declaration, so a private `next` here is a `compileError` the
/// moment [`tools.Unshift`] is instantiated over this type.
const PartialActionValues = struct {
    inner: opiter.ActionValueIter,

    /// The walk over `inner`.
    pub fn init(inner: opiter.ActionValueIter) PartialActionValues {
        return .{ .inner = inner };
    }

    /// The next row, or null past the end of the window.
    pub fn next(self: *PartialActionValues) ReadError!?opiter.ActionValue {
        if (self.inner.pos() >= self.inner.maxPos()) return null;
        const value = try self.inner.tryNext();
        return value;
    }

    /// Moves the **window** to `rows` and nothing else.
    pub fn shift(self: *PartialActionValues, rows: RowRange) err.ParseError!void {
        return self.inner.shift(rows);
    }

    /// Repositions onto `rows` and reads the row at its start.
    pub fn shiftNext(self: *PartialActionValues, rows: RowRange) ReadError!?opiter.ActionValue {
        return self.inner.shiftNext(rows);
    }
};

/// The top-op diff skipper for a clock range
/// ([`DiffSkipper::new_top`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs),
/// `iter/tools.rs:419-430`).
///
/// **This is the top walk and not the visible one**, and the difference is what
/// a text read is built on: a *map* or *list* diff compares **visibility**, so
/// it has to see the rows a state shadows ([`maprange.VisibleDiffSkipper`](map_range.zig));
/// a *text* diff compares **register winners**, because a text element has one
/// width and a conflicted character must be counted once
/// ([`OpSet.actionValueTopIter`](../../opset/op_set.zig), `op_set.rs:946-948`).
/// It lives here because [`maprange.VisibleDiffSkipper`]'s own doc names this
/// as the other one and leaves it to this file.
///
/// Upstream spells it `new_top` ([`iter/tools.rs:563-576`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs))
/// and the port spells it the way
/// [`tools.DiffSkipper`] spells its two constructors: a `Current` range is a
/// diff against one state and a `Diff` range is a diff between two, built from
/// the same walk twice with a different clock.
fn TopDiffSkipper(comptime O: type) type {
    const Top = opset.OpSet(O).Top;
    return struct {
        /// The winners of `rows` for the states `over` names.
        fn init(
            set: *opset.OpSet(O),
            over: ClockRange,
            rows: RowRange,
        ) ReadError!tools.DiffSkipper(Top) {
            return switch (over) {
                .current => |maybe| tools.DiffSkipper(Top).current(try Top.init(
                    &set.cols,
                    maybe,
                    rows,
                    set.succ_scratch.items,
                )),
                .diff => |d| tools.DiffSkipper(Top).past(
                    try Top.init(&set.cols, d.before, rows, set.succ_scratch.items),
                    try Top.init(&set.cols, d.after, rows, set.succ_scratch.items),
                ),
            };
        }
    };
}

/// The action and value columns, tagged with what happened to each row
/// ([`SpansActionValue`], `spans.rs:53-106`).
///
/// **Two arms, and the choice between them is the one upstream documents
/// above the enum** (`spans.rs:48-52`): the top index lets a diff *jump* from
/// one winner to the next, and in a range where every row is already a winner
/// that jump is pure overhead. So a read at the present over a range that is
/// all top streams the two columns straight through and tags everything
/// `Add`; anything else builds the [`tools.DiffKernel`] over the top walk
/// ([`SpansActionValue::new`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
/// `spans.rs:67-82`).
///
/// `shift` **demotes** a `Current` into a `Diff` when the new range is no
/// longer all top ([`spans.rs:84-93`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)):
/// the fast arm is a claim about the window, and a new window has to earn it.
fn SpansActionValue(comptime O: type) type {
    return union(enum) {
        const Self = @This();

        /// One answer of this walk ([`Iterator::Item` for `SpansActionValue`],
        /// `spans.rs:97`): `(Diff, (Action, ScalarValue, usize))`, which is this
        /// file's [`tools.DiffKernel.Entry`] shape over
        /// [`opiter.ActionValue`].
        pub const Entry = struct {
            /// What happened to the row.
            diff: Diff,
            /// The row: its action, its value and its position in the op set.
            item: opiter.ActionValue,
        };

        /// Every row is already a winner, so every row is an `Add`
        /// ([`spans.rs:102`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        current: tools.Unshift(PartialActionValues),
        /// The winners of the range, diffed between the two states the clock
        /// names ([`spans.rs:75-80`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        diff: tools.Unshift(TopWalk),
        /// **A new arm, and it is upstream's `Default` made expressible.**
        /// Upstream's [`SpansDiff::empty`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)
        /// (`spans.rs:138-149`) builds every field from `Default::default()`,
        /// whose value is the diff kernel over nothing (`spans.rs:61-65`). The
        /// port cannot build a column cursor without an op set, and
        /// [`SpansDiff.empty`] has none, so this arm answers nothing and is
        /// what that construction means here.
        empty: void,

        /// The walk this instantiation is: the two columns over the top walk.
        pub const TopWalk = tools.DiffKernel(
            opiter.ActionValue,
            opiter.ActionValueIter,
            opset.OpSet(O).Top,
        );

        /// The rows of `rows`, as the states `over` names see them
        /// ([`SpansActionValue::new`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:67-82`).
        pub fn init(set: *opset.OpSet(O), rows: RowRange, over: ClockRange) ReadError!Self {
            const plain = opiter.ActionValueIter.init(
                try set.actionIterRange(rows),
                try set.valueIterRange(rows),
            );
            // `spans.rs:72`: `matches!(clock, ClockRange::Current(None))` is
            // the "no clock to honour" case.
            const clockless = switch (over) {
                .current => |maybe| maybe == null,
                .diff => false,
            };
            if (clockless and try set.allOfRangeIsTop(rows)) {
                return .{ .current = try tools.Unshift(PartialActionValues).init(
                    PartialActionValues.init(plain),
                ) };
            }
            return .{ .diff = try tools.Unshift(TopWalk).init(TopWalk.init(
                plain,
                try TopDiffSkipper(O).init(set, over, rows),
            )) };
        }

        /// Moves the window to `rows`, rebuilding the walk if the fast arm's
        /// claim no longer holds
        /// ([`SpansActionValue::shift`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:84-93`).
        pub fn shift(
            self: *Self,
            set: *opset.OpSet(O),
            rows: RowRange,
            over: ClockRange,
        ) ReadError!void {
            if (self.* == .current and !try set.allOfRangeIsTop(rows)) {
                self.* = try init(set, rows, over);
                return;
            }
            switch (self.*) {
                .empty => {},
                .current => |*walk| try walk.shift(rows),
                .diff => |*walk| try walk.shift(rows),
            }
        }

        /// The next row, tagged with what happened to it, or null
        /// ([`Iterator::next` for `SpansActionValue`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:96-106`).
        ///
        /// **`Same`, `Add` and `Del` all arrive here**, and the `Diff` arm is
        /// where two of the three are born; the `Current` arm is hardwired to
        /// `Add` because a read against one state has nothing to compare with
        /// ([`spans.rs:102`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        pub fn next(self: *Self) ReadError!?Entry {
            return switch (self.*) {
                .empty => null,
                .current => |*walk| blk: {
                    const item = (try walk.next()) orelse return null;
                    break :blk Entry{ .diff = .add, .item = item };
                },
                .diff => |*walk| blk: {
                    const entry = (try walk.next()) orelse return null;
                    break :blk Entry{ .diff = entry.diff, .item = entry.item };
                },
            };
        }
    };
}

// ── The diff ────────────────────────────────────────────────────────────────

/// A text object's rows, folded into spans and tagged with what happened to
/// each ([`SpansDiff`], `spans.rs:108-241`).
///
/// **This is the whole of the reader.** [`Spans`] is this with a clock that
/// names one state, and a document diff is this with a clock that names two.
pub fn SpansDiff(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The rows, and what happened to each.
        action_value: SpansActionValue(O),
        /// The two mark columns, read in lockstep with `op_id`
        /// ([`MarkInfoIter`], `spans.rs:112`).
        mark_info: opiter.MarkInfoIter,
        /// The op-id column, which is where a mark row's identity comes from
        /// ([`OpIdIter`], `spans.rs:113`).
        op_id: opiter.OpIdIter,
        /// The two mark folds ([`RichTextDiff`], `spans.rs:114`).
        marks: batch.RichTextDiff,
        /// The op set the rows are read from, and the one an exported block's
        /// id is resolved against. **Null only for
        /// [`empty`](Self.empty)**, which has no rows to read and so never
        /// reaches a row handler.
        op_set: ?*opset.OpSet(O) = null,
        /// Which two states, or which one, the diff is between
        /// ([`spans.rs:115`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        clock: ClockRange,
        /// The fold ([`SpanState`], `spans.rs:116`).
        state: SpanState,
        /// The row the last action/value pair came from ([`spans.rs:117`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        pos: usize = 0,

        /// A diff over `rows` between the states `over` names
        /// ([`SpansDiff::new`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:162-187`).
        ///
        /// `gpa` is first because the fold allocates: the run it buffers is the
        /// caller's, and so is every span this hands back.
        pub fn init(
            gpa: Allocator,
            set: *opset.OpSet(O),
            rows: RowRange,
            over: ClockRange,
            enc: types.TextEncoding,
        ) ReadError!Self {
            const window = column.clampRange(rows, set.len());
            return .{
                .action_value = try SpansActionValue(O).init(set, window, over),
                .mark_info = try set.markInfoIterRange(window),
                .op_id = try set.idIterRange(window),
                .marks = batch.RichTextDiff.init(gpa),
                .op_set = set,
                .clock = over,
                .state = SpanState.init(gpa, enc),
                .pos = window.start,
            };
        }

        /// A diff over nothing ([`SpansDiff::empty`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:138-149`).
        ///
        /// **Upstream builds this out of `Default::default()` and this builds
        /// it out of [`SpansActionValue`]'s `empty` arm**, because there is no
        /// op set to build a column cursor over; see that arm's doc. It
        /// allocates nothing: both folds start empty and the fold has no run.
        pub fn empty(gpa: Allocator, enc: types.TextEncoding) Self {
            return .{
                .action_value = .empty,
                .mark_info = undefined,
                .op_id = undefined,
                .marks = batch.RichTextDiff.init(gpa),
                .op_set = null,
                .clock = .now(),
                .state = SpanState.init(gpa, enc),
            };
        }

        /// Gives back both mark folds and the buffered run, **and leaves the
        /// reader unusable**: `self.* = undefined` is the last line, so a second
        /// call reads undefined memory rather than reaching an allocator that
        /// could diagnose the double free. **A [`SpanDiff`] this reader has
        /// already handed out is the caller's** and is not touched here — see
        /// the module doc on why it shares no storage with the fold.
        pub fn deinit(self: *Self) void {
            self.marks.deinit();
            self.state.deinit();
            self.* = undefined;
        }

        /// Repositions onto `rows` and reads the first span in it
        /// ([`SpansDiff::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:151-160`).
        ///
        /// **The marks and the run are both thrown away**, which is the point:
        /// the next object has no marks open and no text buffered, and the fold
        /// would otherwise carry this object's index into the next one. The
        /// index is reset with them because [`SpanState.reset`] starts from
        /// scratch, exactly as upstream's `SpanState::empty` does.
        ///
        /// **One deviation, and it is a correctness one.** Upstream calls
        /// `set_max` on `mark_info` and `op_id` and never *repositions* them
        /// (`spans.rs:152-153`), so after a shift their positions are still
        /// where the previous object ended and [`nextOpid`](Self.nextOpid)'s
        /// skip is measured from a stale row — which for a next object further
        /// along is a skip past the end, and every block marker in it is
        /// silently dropped. `shift` **repositions** them, which is what
        /// `shift` means everywhere else in the port
        /// ([`tools.SkipIter.shift`](tools.zig),
        /// [`opset.OpSet.elemidAt`](../../opset/op_set.zig)) and what
        /// upstream's own `Shiftable::shift` does
        /// ([`shift.rs:50-55`](../../github-automerge-automerge/rust/hexane/src/shift.rs)).
        /// A `setMax` alone would leave the position stale, which is the bug
        /// this deviation exists to fix.
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?SpanDiff(O) {
            const set = self.op_set orelse return null;
            const window = column.clampRange(rows, set.len());
            try self.mark_info.shift(window);
            try self.op_id.shift(window);
            try self.action_value.shift(set, window, self.clock);
            self.marks.deinit();
            self.marks = batch.RichTextDiff.init(self.state.gpa);
            self.state.reset();
            self.pos = window.start;
            return self.next();
        }

        /// The next span, tagged with what happened to it, or null at the end of
        /// the range ([`Iterator::next` for `SpansDiff`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:120-135`).
        ///
        /// **Three sources, in this order, and the order is load-bearing.**
        /// A block marker that was held back comes first, because it sits
        /// between the run in front of it and whatever follows; then the rows,
        /// until a row handler produces a span; then the run still buffered when
        /// the rows run out, which is why the last span of a range comes from
        /// `flush` and not from a row.
        pub fn next(self: *Self) ReadError!?SpanDiff(O) {
            const set = self.op_set orelse return null;
            if (SpanState.pop(O, &self.state, set)) |span| return span;
            while (try self.action_value.next()) |entry| {
                if (try self.processActionValDiff(entry.diff, entry.item)) |span| return span;
            }
            return SpanState.flush(O, &self.state);
        }

        /// Emits a block marker ([`SpansDiff::push_block`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:189-193`).
        ///
        /// **`expose` is [`ClockRange::predates`](map_range.zig), and that is
        /// false for every arm of a read** ([`clock.rs:111-115`](../../github-automerge-automerge/rust/automerge/src/clock.rs)):
        /// only a `Diff` has a before, so only a diff reports an expose.
        fn pushBlock(self: *Self, diff: Diff) ReadError!?SpanDiff(O) {
            const set = self.op_set orelse return null;
            const id = (try self.nextOpid()) orelse return null;
            return SpanState.pushBlock(O, &self.state, set, diff, id, predates(self.clock, id));
        }

        /// The id of the row at `self.pos`, read out of the op-id column
        /// without consuming a row ([`SpansDiff::next_opid`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:195-198`).
        ///
        /// The op-id column is read by *distance*, not by stepping, because a
        /// mark row carries its identity there and nowhere else: the value
        /// column holds no id ([`spans.rs:200-204`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)
        /// reads the mark name the same way).
        ///
        /// Upstream subtracts two positions without checking; the port
        /// saturates, as [`tools.SkipWrap.next`](tools.zig) does for the same
        /// reason — a skipper's positions increase, and a caller that breaks it
        /// gets a skip of zero instead of a panic.
        fn nextOpid(self: *Self) ReadError!?OpId {
            return self.op_id.maybeTryNth(self.pos -| self.op_id.pos());
        }

        /// The mark name at `self.pos`, or null when the row carries none
        /// ([`SpansDiff::next_mark_name`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:200-204`).
        ///
        /// **The name column, not the value, is what says "begin"**
        /// ([`marks.rs`](../../github-automerge-automerge/rust/automerge/src/marks.rs)
        /// `:405-430`, [`opset/types.zig:428`](../../opset/types.zig)): a mark
        /// end has no name, and an **unmark is a mark begin whose value is
        /// null**, so a null value never makes a row a mark end. Reading the
        /// name as an optional rather than the value preserves that distinction.
        ///
        /// The port's [`opiter.MarkInfoIter.tryNth`] is **total** — it raises
        /// `error.MissingValue` at the end of the window where upstream's
        /// `nth` answers `None` (`op_iter.rs:737-744`) — so the end of the
        /// window is answered here rather than there.
        fn nextMarkName(self: *Self) ReadError!?[]const u8 {
            const skip = self.pos -| self.mark_info.pos();
            if (self.mark_info.pos() +| skip >= self.mark_info.maxPos()) return null;
            const info = try self.mark_info.tryNth(skip);
            return info.name;
        }

        /// Folds one mark row through the folds and updates the active marks
        /// ([`SpansDiff::process_mark`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:206-218`).
        ///
        /// **A mark row emits no span of its own**; what it does is change what
        /// the next run carries, which is why the return is `void` and why
        /// [`SpansDiff.processActionValDiff`](Self.processActionValDiff)
        /// answers null for it.
        ///
        /// A row with no id in the op-id column is skipped: there is nothing to
        /// pair a begin with its end (`spans.rs:207-209`).
        fn processMark(self: *Self, diff: Diff, value: ScalarValue) ReadError!void {
            const id = (try self.nextOpid()) orelse return;
            const changed = if (try self.nextMarkName()) |name|
                try markBeginDiff(&self.marks, diff, id, marks.MarkData.init(name, value))
            else
                try markEndDiff(&self.marks, diff, id);
            // `spans.rs:216-217` pushes the marks unconditionally; the port
            // copies them out only when they moved, which is the same answer
            // with a mark operation that changes nothing costing no run split.
            if (changed) try self.state.refreshMarks(&self.marks);
        }

        /// One row, and what it does to the fold
        /// ([`SpansDiff::process_action_val_diff`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:220-240`).
        ///
        /// **The diff tag is threaded through every arm**, and the six arms are
        /// upstream's:
        ///
        /// | row | what happens | `spans.rs` |
        /// | --- | --- | --- |
        /// | `Set` + `Str` + `Add` | [`SpanState.pushUnmarkedAddStr`] | `:228-230` |
        /// | `Set` + `Str` | [`SpanState.pushStr`] with the tag | `:231` |
        /// | `MakeMap` | [`SpansDiff.pushBlock`](Self.pushBlock) | `:232` |
        /// | `Mark` | [`SpansDiff.processMark`](Self.processMark), and **no span** | `:233-236` |
        /// | `Delete`, `Increment` | **nothing** | `:237` |
        /// | anything else | [`SpanState.pushStr`] with the tag and [`placeholder`] | `:238` |
        ///
        /// The last arm is what makes a text hold a number: upstream measures
        /// every non-string value as the object replacement character
        /// (`spans.rs:238`, `PLACEHOLDER` at `:429`), so a reader sees one
        /// position rather than nothing. **The `Set`+`Str`+`Add` arm is the only
        /// one that does not pass the tag on**, and it does not need to: the arm
        /// *is* `Add` ([`spans.rs:516-533`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
        pub fn processActionValDiff(
            self: *Self,
            diff: Diff,
            av: opiter.ActionValue,
        ) ReadError!?SpanDiff(O) {
            self.pos = av.pos;
            return switch (av.action) {
                .set => switch (av.value) {
                    .str => |s| if (diff == .add)
                        try SpanState.pushUnmarkedAddStr(O, &self.state, s)
                    else
                        try SpanState.pushStr(O, &self.state, diff, s),
                    else => try SpanState.pushStr(O, &self.state, diff, placeholder),
                },
                .make_map => try self.pushBlock(diff),
                .mark => {
                    try self.processMark(diff, av.value);
                    return null;
                },
                .delete, .increment => null,
                else => try SpanState.pushStr(O, &self.state, diff, placeholder),
            };
        }
    };
}

// ── The readers ─────────────────────────────────────────────────────────────

/// A [`SpansDiff`] with nothing on it
/// ([`SpansInternal`], `spans.rs:243-281`).
///
/// **Upstream's is a one-field wrapper** and it exists for one reason:
/// [`Spans`]'s `next` reaches through it to the op set, the clock and the
/// encoding, and a bare [`SpansDiff`] would expose those to the patch layer.
pub fn SpansInternal(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The diff this is a view of (`spans.rs:245`).
        iter: SpansDiff(O),

        /// A reader over nothing ([`SpansInternal::empty`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:249-253`).
        pub fn empty(gpa: Allocator, enc: types.TextEncoding) Self {
            return .{ .iter = SpansDiff(O).empty(gpa, enc) };
        }

        /// The reader over `rows` as the states `clock` names see them
        /// ([`SpansInternal::new`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:267-280`).
        ///
        /// **A null clock becomes `ClockRange::current(null)`**, which is what
        /// makes the fast arm of [`SpansActionValue`] reachable: a read at the
        /// present is the one case where there is no clock to honour
        /// (`spans.rs:276`, `clock.rs:111-115`).
        pub fn init(
            gpa: Allocator,
            set: *opset.OpSet(O),
            rows: RowRange,
            clock: ?Clock,
            enc: types.TextEncoding,
        ) ReadError!Self {
            return .{
                .iter = try SpansDiff(O).init(
                    gpa,
                    set,
                    rows,
                    .{ .current = clock },
                    enc,
                ),
            };
        }

        /// Gives back everything the reader made, **and leaves the reader
        /// unusable**: `self.* = undefined` is the last line, so a second call
        /// reads undefined memory rather than reaching an allocator. A
        /// [`SpanInternal`] already handed out is the caller's, freed with
        /// [`SpanInternal.deinit`] and the allocator this was built with.
        pub fn deinit(self: *Self) void {
            self.iter.deinit();
            self.* = undefined;
        }

        /// The next span, as the diff sees it
        /// ([`Iterator::next` for `SpansInternal`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:597-603`).
        pub fn next(self: *Self) ReadError!?SpanInternal(O) {
            const span = (try self.iter.next()) orelse return null;
            return span.span;
        }

        /// Repositions onto `rows` and reads the first span in it
        /// ([`SpansInternal::shift_next`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:255-257`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?SpanInternal(O) {
            const span = (try self.iter.shiftNext(rows)) orelse return null;
            return span.span;
        }
    };
}

/// A sequence of block markers and text spans ([`Spans`], `spans.rs:283-288`,
/// `:629-645`).
///
/// **The reader a caller renders.** What upstream's `ReadDoc::spans` and
/// `spans_at` hand back ([`read.rs:200,205-211`](../../github-automerge-automerge/rust/automerge/src/read.rs));
/// the port has neither method yet, so this is the entry point that will.
///
/// Constructing one allocates nothing.
pub fn Spans(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The diff this reader is a view of (`spans.rs:287`).
        internal: SpansInternal(O),

        /// The reader over `obj_rows`, as the state `clock` names sees it
        /// ([`Spans::new`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:629-633`).
        pub fn init(
            gpa: Allocator,
            set: *opset.OpSet(O),
            obj_rows: RowRange,
            clock: ?Clock,
            enc: types.TextEncoding,
        ) ReadError!Self {
            return .{
                .internal = try SpansInternal(O).init(gpa, set, obj_rows, clock, enc),
            };
        }

        /// Gives back the reader's own folds and buffer, **and leaves the
        /// reader unusable**: `self.* = undefined` is the last line, so a second
        /// call reads undefined memory rather than reaching an allocator.
        /// **The spans it has already handed out are the caller's** and are not
        /// touched here, **in either order** — they are detached copies, so a
        /// span may be read after this call.
        pub fn deinit(self: *Self) void {
            self.internal.deinit();
            self.* = undefined;
        }

        /// The next span, as a caller reads it, or null at the end of the object
        /// ([`Iterator::next` for `Spans`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs),
        /// `spans.rs:635-645`).
        ///
        /// Allocates detached block maps and mark payloads using the iterator's
        /// allocator. The caller releases each returned span once.
        pub fn next(self: *Self) ReadError!?Span {
            const iter = &self.internal.iter;
            const set = iter.op_set orelse return null;
            var span = (try self.internal.next()) orelse return null;
            errdefer span.deinit(iter.state.gpa);
            return try span.exportSpan(
                iter.state.gpa,
                set,
                switch (iter.clock) {
                    .current => |clock| clock,
                    .diff => |clocks| clocks.after,
                },
            );
        }

        /// Repositions onto `rows` and reads the first span in it
        /// ([`impl Spans`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)
        /// via `SpansInternal::shift_next`, `spans.rs:255-257`).
        pub fn shiftNext(self: *Self, rows: RowRange) ReadError!?Span {
            const iter = &self.internal.iter;
            const set = iter.op_set orelse return null;
            var span = (try self.internal.shiftNext(rows)) orelse return null;
            errdefer span.deinit(iter.state.gpa);
            return try span.exportSpan(
                iter.state.gpa,
                set,
                switch (iter.clock) {
                    .current => |clock| clock,
                    .diff => |clocks| clocks.after,
                },
            );
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const opmod = @import("../opset/op.zig");
const opcols = @import("../opset/columns.zig");
/// The op tree's own page size, which the page-boundary fixture is sized from
/// ([`page_chars`] below).
const btree = @import("../hexane/btree.zig");
const ObjId = ExId;

/// The concrete op set the fixtures are read through, for the reason
/// [`list_range.zig`](list_range.zig) gives: [`opmod.Op`] borrows its row's
/// successors and its value, so a fixture is an array of `Op` values over its
/// own spans and needs no allocator, and the index columns come from
/// [`opset.OpSet.rebuildIndex`](../../opset/op_set.zig) rather than from the
/// rows (`op_set.zig:695-700`).
const Set = opset.OpSet(opmod.Op);

/// The encoding every fixture is built with, so a width is a count of code
/// points and not of bytes.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's one actor. `ActorIdx` is a position in this table
/// ([`types.zig`](../../src/types.zig)).
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: ActorIdx) ObjId {
    return .{ .id = opId(ctr, actor) };
}

/// A sequence row anchored to the element at `id` ([`ElemId::from_op_id`],
/// [`types.rs:652-654`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
fn anchored(id: OpId) optypes.KeyRef {
    return .{ .seq = types.ElemId.fromOpId(id) };
}

/// The head of a sequence: the element id that means "inserted at the front"
/// ([`ElemId::head`], `types.rs:657-659`).
fn head() optypes.KeyRef {
    return .{ .seq = types.ElemId.head() };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value,
/// the mark name and the successor span — belongs to the fixture, which
/// outlives the op set.
fn row(
    id: OpId,
    obj: ObjId,
    key: optypes.KeyRef,
    insert: bool,
    act: optypes.Action,
    val: ScalarValue,
    expands: bool,
    mark: ?[]const u8,
    succs: []const opmod.SuccEntry,
) opmod.Op {
    return opmod.Op.init(
        0,
        false,
        id,
        act,
        obj,
        key,
        insert,
        val,
        expands,
        mark,
        opmod.SuccCursors.fromSpan(succs, 0),
    );
}

/// **A mark's begin.** The row *is* the mark: an insert into the text, with a
/// name in the mark-name column and the mark's value in the value column
/// ([`marks.zig`](../../src/marks.zig)'s module doc, the mark-operations table).
/// Its position in the op set is where the mark starts, which for a mark over
/// `[start, end)` is the element at index `start`.
fn markBegin(
    id: OpId,
    obj: ObjId,
    at: optypes.KeyRef,
    name: []const u8,
    val: ScalarValue,
) opmod.Op {
    return row(id, obj, at, true, .mark, val, true, name, &.{});
}

/// **A mark's end.** An insert like the begin, with **no name** — the name
/// column is what says "end", not the null value
/// ([`SpansDiff.nextMarkName`](Self.nextMarkName)'s doc). `id` is the begin's id
/// plus one, which is what every reader pairs on
/// ([`marks.zig`](../../src/marks.zig), "Two invariants tie the two operations
/// together").
fn markEnd(id: OpId, obj: ObjId, at: optypes.KeyRef) opmod.Op {
    return row(id, obj, at, true, .mark, .null_value, true, null, &.{});
}

/// A delete: a successor edge on another row and not a row of its own
/// ([`Op.del`](../../opset/op.zig), `op.rs:1158-1172`).
const del_of_b = [_]opmod.SuccEntry{.{ .id = opId(9, 0), .inc = null }};

/// The string table a fixture's op set borrows. **Heap-allocated, and that is
/// an ownership rule rather than a convenience**: the op set borrows the table,
/// so it has to sit at one address for as long as the set does.
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
    fn intern(ctx: *anyopaque, text: []const u8, gpa: Allocator) err.ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(ctx));
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

    fn build(gpa: Allocator, actors: []const types.ActorId, rows: []const opmod.Op) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, encoding, self.table.asTable()) catch |e| {
            self.table.deinit();
            return e;
        };
        // **The table is a second owner and this is its error path.** `destroy`
        // frees it beside the op set, and an error between the two — a refused
        // `splice`, a mark order the op set will not accept
        // ([`OpSet.rebuildIndex`](../../opset/op_set.zig)) — has to free it too,
        // or a fixture that fails on its rows leaks the key strings and the
        // mark name `splice` interned before it refused. **Declared before the
        // op set's own `errdefer` so it runs after it**: the op set borrows the
        // table, so the borrower goes first.
        errdefer self.table.deinit();
        errdefer self.set.deinit();
        _ = try self.set.splice(0, rows);
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

/// A clock over every operation up to and including `cutoff`.
fn clockUpTo(gpa: Allocator, cutoff: u32) !Clock {
    var c = try Clock.init(gpa, 1);
    _ = c.include(0, cutoff);
    return c;
}

/// Every span of `obj`, read at the present. The caller owns the result and
/// frees it with [`freeSpans`].
fn readAll(set: *Set, obj: ObjId, gpa: Allocator, clock: ?Clock) !std.ArrayList(Span) {
    var out: std.ArrayList(Span) = .empty;
    errdefer freeSpans(&out, gpa);
    var reader = try Spans(opmod.Op).init(gpa, set, try set.scopeToObj(obj), clock, encoding);
    defer reader.deinit();
    while (try reader.next()) |span| {
        var owned = span;
        errdefer owned.deinit(gpa);
        try out.append(gpa, owned);
    }
    return out;
}

/// Every span `obj` produced between two states, with what happened to each.
fn diffAll(
    set: *Set,
    obj: ObjId,
    gpa: Allocator,
    over: ClockRange,
) !std.ArrayList(SpanDiff(opmod.Op)) {
    var out: std.ArrayList(SpanDiff(opmod.Op)) = .empty;
    errdefer {
        for (out.items) |*span| span.deinit(gpa);
        out.deinit(gpa);
    }
    var reader = try SpansDiff(opmod.Op).init(
        gpa,
        set,
        try set.scopeToObj(obj),
        over,
        encoding,
    );
    defer reader.deinit();
    while (try reader.next()) |span| {
        var owned = span;
        errdefer owned.deinit(gpa);
        try out.append(gpa, owned);
    }
    return out;
}

/// Gives back every span in `list` and the list itself.
fn freeSpans(list: *std.ArrayList(Span), gpa: Allocator) void {
    for (list.items) |*span| span.deinit(gpa);
    list.deinit(gpa);
    list.* = undefined;
}

/// The width the **op set itself** records for the element the row at `pos`
/// belongs to.
///
/// **Read from the element's *last* row, and that is the whole point**
/// ([`op_set.rs:748-752`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)):
/// `index.text` carries a width only on a `top` row
/// ([`columns.rs:466-471`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)),
/// the `top` row of a register is its **last** row, and
/// [`opset.OpSet.elemidAt`](../../opset/op_set.zig) is what finds it
/// (`op_set.rs:793-828`).
///
/// This is [`list_range.zig`](list_range.zig)'s private `elementWidth` read the
/// same way and **not** imported from it: a private helper widened for a second
/// caller is a helper with two owners, and this is the first assertion in the
/// crate that checks a *span's* width against the op set rather than the
/// reader's own arithmetic.
fn elementWidth(set: *Set, pos: usize, end: usize) ReadError!usize {
    const elem = (try set.elemidAt(pos, end)) orelse return 0;
    const cell = (try set.cols.index.text.get(elem.last_pos)) orelse return 0;
    const width = cell orelse return 0;
    return std.math.cast(usize, width) orelse error.Overflow;
}

/// The text of `span`, or an error when it is a block. A caller rendering text
/// has to be able to say which of the two it got.
fn textOf(span: Span) ![]const u8 {
    return switch (span) {
        .text => |t| t.text,
        .block => error.TestUnexpectedResult,
    };
}

/// The borrowed block metadata id of `span`, or an error when it is text.
fn blockOf(span: Span) !ExId {
    return switch (span) {
        .text => error.TestUnexpectedResult,
        .block => |b| b.id,
    };
}

/// The marks `span` carries, as name/value pairs in the set's own order.
fn marksOf(span: Span) []const MarkSet.Entry {
    return switch (span) {
        .text => |*t| if (t.marks) |*m| m.entries.items else &.{},
        .block => &.{},
    };
}

/// **Asserts a span's mark set by content**, name by name and value by value.
///
/// `expectEqual` on two [`MarkSet.Entry`] slices would compare their *pointers*,
/// so a test written that way passes on any two mark sets and fails on none
/// ([`std/testing.zig:130-139`](../../lib/std/testing.zig)). The names are
/// borrowed from the document's string table, so they are compared as strings
/// rather than as pointers, and the values through
/// [`ScalarValue.eql`](../../src/value.zig).
fn expectMarks(got: Span, want: []const MarkSet.Entry) !void {
    const entries = marksOf(got);
    if (entries.len != want.len) {
        std.debug.print("span carries {d} mark(s), expected {d}\n", .{ entries.len, want.len });
        for (entries) |e| std.debug.print("  got: {s}\n", .{e.name});
        for (want) |e| std.debug.print("  want: {s}\n", .{e.name});
        return error.TestExpectedEqual;
    }
    for (entries, want) |entry, expected| {
        try testing.expectEqualStrings(expected.name, entry.name);
        try testing.expect(entry.value.eql(expected.value));
    }
}

/// Whether `span` carries no mark called `name`.
///
/// **An assertion about a name, and not about a length.** A count says the span
/// carries as many marks as expected; it passes just as happily on a span
/// carrying a *different* mark that many times, which is the failure the
/// page-boundary case is about — a mark that ended much earlier reappearing on
/// characters far after it (`tests/text.rs:419-422`). A length of zero would
/// also pass on a span carrying a mark under another name, so the name is the
/// assertion and the length is not.
fn expectNoMark(span: Span, name: []const u8) !void {
    for (marksOf(span)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            std.debug.print("span carries the mark {s}, which must not reach here\n", .{name});
            return error.TestExpectedEqual;
        }
    }
}

/// **A text long enough to cross an op-tree page boundary**, sized from the
/// op tree's own branching factor rather than from a copied number.
///
/// **This is the constant that has to travel with the page size.** Upstream's
/// case reaches its boundary by writing `B * 2` characters with `B = 16`
/// (`tests/text.rs:11`, `:461`) — and `B` is upstream's *test* constant, not its
/// page size, so a reader who copies the number gets a fixture that happens to
/// work here and stops working the day the page size moves. The port's page is
/// [`btree.branch_factor`](../../src/hexane/btree.zig) (`btree.zig:36-43`, `64`,
/// picked upstream at `btree.rs:30-34`), and this file's own sibling
/// `hexane/btree.zig` differential corpus calls `2 * 64 + 1` "two levels"
/// (`btree.zig:2818-2823`). So the fixture is **derived**, and the mark's
/// position is then **swept across every index of it** by the test below, which
/// is what makes the assertion independent of where the boundary actually
/// falls — the one property a page-size change must not be able to take away.
const page_chars = 2 * btree.branch_factor + 1;

/// The rows of [`page_chars`] single-character inserts over `obj`, a mark
/// `strong` over `[start, start + 2)`, and one insert `"z"` past the text.
///
/// **The row order is the mark's, not the text's**: a mark's begin sits before
/// the element at its start index and its end before the element at its end
/// index ([`transaction/inner.rs:827-857`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// the same rule the other diff fixture in this file states.
///
/// The characters take ids `2 ..= page_chars + 1`, then the mark's two and the
/// tail's one, and the mark's end is its begin's id plus one
/// ([`markEnd`] above).
fn pageBoundaryRows(obj: ObjId, start: usize) [page_chars + 4]opmod.Op {
    var rows: [page_chars + 4]opmod.Op = undefined;
    rows[0] = row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{});
    var at: usize = 1;
    // `prev` is the operation the next insert anchors on: the character before
    // it, or the mark operation when the mark falls between two characters.
    var prev: OpId = undefined;
    const begin_id = opId(@intCast(page_chars + 2), 0);
    const end_id = opId(@intCast(page_chars + 3), 0);
    const tail_id = opId(@intCast(page_chars + 4), 0);
    for (0..page_chars) |i| {
        if (i == start) {
            rows[at] = markBegin(begin_id, obj, if (i == 0) head() else anchored(prev), "strong", .{ .bool_value = true });
            at += 1;
            prev = begin_id;
        }
        if (i == start + 2) {
            rows[at] = markEnd(end_id, obj, anchored(prev));
            at += 1;
            prev = end_id;
        }
        const id = opId(@intCast(i + 2), 0);
        rows[at] = row(id, obj, if (i == 0) head() else anchored(prev), true, .set, .{ .str = "a" }, false, null, &.{});
        at += 1;
        prev = id;
    }
    // Past every mark, which is the whole of the case: the mark ended two
    // characters before this and must not reach it.
    rows[at] = row(tail_id, obj, anchored(prev), true, .set, .{ .str = "z" }, false, null, &.{});
    return rows;
}

/// The marks a [`SpanDiff`]'s text run carries, as name/value pairs in the set's
/// own order ([`marksOf`] above, over the unresolved half).
///
/// **Read in place rather than exported.** [`SpanDiff.exportSpan`] is a *move*
/// (`spans.zig:387-395`), so exporting a diff to assert on it leaves the diff
/// owning nothing and frees it a second time.
fn diffMarksOf(span: SpanDiff(opmod.Op)) []const MarkSet.Entry {
    return switch (span.span) {
        .text => |*t| if (t.marks) |*m| m.entries.items else &.{},
        .obj => &.{},
    };
}

/// Asserts that a [`SpanDiff`]'s run carries exactly `want`, by name and value.
fn expectDiffMarks(span: SpanDiff(opmod.Op), want: []const MarkSet.Entry) !void {
    const entries = diffMarksOf(span);
    if (entries.len != want.len) {
        std.debug.print("diff span carries {d} mark(s), expected {d}\n", .{ entries.len, want.len });
        for (entries) |e| std.debug.print("  got: {s}\n", .{e.name});
        for (want) |e| std.debug.print("  want: {s}\n", .{e.name});
        return error.TestExpectedEqual;
    }
    for (entries, want) |entry, expected| {
        try testing.expectEqualStrings(expected.name, entry.name);
        try testing.expect(entry.value.eql(expected.value));
    }
}

/// Asserts that a [`SpanDiff`]'s run carries no mark called `name`.
///
/// **A name, and not a length.** See [`expectNoMark`] above: a
/// length of zero passes on a span carrying a *different* mark the same number
/// of times, and a matching length passes on one carrying the wrong name.
fn expectNoDiffMark(span: SpanDiff(opmod.Op), name: []const u8) !void {
    for (diffMarksOf(span)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            std.debug.print("diff span carries the mark {s}, which must not reach here\n", .{name});
            return error.TestExpectedEqual;
        }
    }
}

/// The byte offset of the text index `index` in `bytes`, measured in `enc`.
fn byteOffset(enc: types.TextEncoding, bytes: []const u8, index: usize) !usize {
    var units: usize = 0;
    var at: usize = 0;
    while (units < index) {
        if (at >= bytes.len) return error.TestUnexpectedResult;
        // **One code point at a time**, not the rest of the buffer: a width is
        // measured per character, and `encoding.width` on a slice measures all
        // of it.
        const seq = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return error.TestUnexpectedResult;
        const wide = @min(seq, bytes.len - at);
        const width = enc.width(bytes[at .. at + wide]);
        if (width == 0) return error.TestUnexpectedResult;
        units += width;
        at += wide;
    }
    return at;
}

/// Asserts one entry of a mark set, by name and by value.
fn expectEntry(set: MarkSet, at: usize, name: []const u8, value: ScalarValue) !void {
    const entries = set.entries.items;
    if (at >= entries.len) {
        std.debug.print("mark set has {d} entries, wanted index {d}\n", .{ entries.len, at });
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings(name, entries[at].name);
    try testing.expect(entries[at].value.eql(value));
}

/// Concatenates what a caller would render: every span's
/// [`Span.asStr`](Span.asStr), in order.
///
/// **This is the round trip the reader exists for**, and the block marker is
/// in it: a block reads as U+FFFC and not as nothing, so a rendered text object
/// is its own concatenation.
fn renderAll(spans: []const Span, gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (spans) |span| try out.appendSlice(gpa, span.asStr());
    return out.toOwnedSlice(gpa);
}

test "plain text reads as one span per run, and the runs are the object's text" {
    const gpa = testing.allocator;
    // "abc" in three single-code-point elements. **The ids descend from the
    // head** (`3`, `2`, then an element chained onto `2`), which is rule R4:
    // an insert opening a register is legal when it is anchored to the element
    // the previous row belongs to or its own id sorts before it
    // ([`op.zig:2226-2231`](../../opset/op.zig)). A fixture ordered by
    // ascending id at the head is not a document automerge could produce.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(3, 0), text, head(), true, .set, .{ .str = "a" }, false, null, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "b" }, false, null, &.{}),
        row(opId(4, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    // **One span, not three.** The three elements share a diff tag and no
    // marks, so they coalesce into one run
    // ([`spans.rs:492-511`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    // A reader that emitted one span per element would give three here.
    try testing.expectEqual(@as(usize, 1), got.items.len);
    try testing.expectEqualStrings("abc", try textOf(got.items[0]));
    try expectMarks(got.items[0], &.{});

    // **Concatenating the spans reproduces the object's text exactly**, and
    // what the op set says its length is, measured in the document's encoding.
    const rendered = try renderAll(got.items, gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("abc", rendered);
    try testing.expectEqual(
        try doc.set.seqLength(text, encoding, null),
        encoding.width(rendered),
    );
}

test "a mark spanning several graphemes is on each of them, under one name" {
    const gpa = testing.allocator;
    // "abc" with `bold` over `[0, 2)`. The mark's **begin** sits before "a" and
    // its **end** before "c" — which is upstream's rule, since the end is
    // placed at the element at index `end`
    // ([`transaction/inner.rs:841-856`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
    // Both are inserts anchored to the element in front of them, so the end
    // carries no name of its own and the reader has to pair it with the begin
    // to know the name is "bold" at all.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(3, 0))),
        row(opId(4, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    // **Two spans, and the mark is the only thing that splits them.**
    // "a" and "b" are two elements with the same diff tag and the same marks,
    // so they are one span — the mark is on each of the graphemes it covers
    // and the span is where a reader finds it.
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("ab", try textOf(got.items[0]));
    try expectMarks(got.items[0], &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try testing.expectEqualStrings("c", try textOf(got.items[1]));
    try expectMarks(got.items[1], &.{});

    // The span the mark covers is exactly as wide as its two graphemes, in the
    // document's encoding, and the object is one wider.
    try testing.expectEqual(@as(usize, 2), encoding.width(got.items[0].asStr()));
    try testing.expectEqual(@as(usize, 3), try doc.set.seqLength(text, encoding, null));
}

test "an unmark removes a mark, and a zero-width unmark produces no span at all" {
    const gpa = testing.allocator;
    // "abcd" with `bold` over the whole object, an **unmark** of `bold` over
    // `[0, 2)` and a **zero-width** unmark of `bold` at index 4.
    //
    // An unmark is not a third kind of operation: it is a mark *begin* whose
    // value is null ([`marks.zig`](../../src/marks.zig)'s module doc, "An unmark
    // is not a third kind of operation"), so a reader that decided "begin or end"
    // by looking at the value would fold this as an end — silently, because a
    // mark end whose begin is not in the state is ignored
    // ([`marks.rs:296-299`](../../github-automerge-automerge/rust/automerge/src/marks.rs)).
    // The mark-name column is what says begin from end
    // ([`SpansDiff.nextMarkName`](Self.nextMarkName)).
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        markBegin(opId(12, 0), text, anchored(opId(5, 0)), "bold", .null_value),
        row(opId(8, 0), text, anchored(opId(12, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        row(opId(9, 0), text, anchored(opId(8, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        markEnd(opId(13, 0), text, anchored(opId(9, 0))),
        row(opId(10, 0), text, anchored(opId(13, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
        row(opId(11, 0), text, anchored(opId(10, 0)), true, .set, .{ .str = "d" }, false, null, &.{}),
        markBegin(opId(14, 0), text, anchored(opId(11, 0)), "bold", .null_value),
        markEnd(opId(15, 0), text, anchored(opId(14, 0))),
        markEnd(opId(6, 0), text, anchored(opId(15, 0))),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    // **The unmark takes the mark off "ab" and leaves it on "cd"**, and that
    // difference is the whole test: a reader that folded the null-valued begin
    // as an end would leave `bold` on "ab" and report one span, not two.
    try testing.expectEqual(@as(usize, 2), got.items.len);
    try testing.expectEqualStrings("ab", try textOf(got.items[0]));
    try expectMarks(got.items[0], &.{});
    try testing.expectEqualStrings("cd", try textOf(got.items[1]));
    try expectMarks(got.items[1], &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    // **The zero-width unmark produces no span and no text.** A run whose width
    // is zero is not emitted ([`SpanState.flush`](Self.flush), upstream's
    // `spans_are_consolidated_in_the_presence_of_zero_length_spans`,
    // [`tests/text.rs:298-319`](../../github-automerge-automerge/rust/automerge/tests/text.rs)),
    // and it does not disturb the marks around it: "cd" still reads `bold`.
    const rendered = try renderAll(got.items, gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("abcd", rendered);
}

test "a block marker is its own span of width one, and the text around it is untouched" {
    const gpa = testing.allocator;
    // "ab", a block, "cd". The block's row is an insert into the text that
    // makes an object, so it is one element and **one position wide** — the
    // object replacement character, U+FFFC ([`Op.asStr`](../../opset/op.zig),
    // `op.rs:997-1005`).
    const text = made(1, 0);
    const block = made(6, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(4, 0), text, head(), true, .set, .{ .str = "ab" }, false, null, &.{}),
        row(opId(6, 0), text, anchored(opId(4, 0)), true, .make_map, .null_value, false, null, &.{}),
        row(opId(5, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "cd" }, false, null, &.{}),
        row(opId(8, 0), block, .{ .map = "attrs" }, false, .make_map, .null_value, false, null, &.{}),
        row(opId(9, 0), block, .{ .map = "kind" }, false, .set, .{ .str = "paragraph" }, false, null, &.{}),
        row(opId(10, 0), block, .{ .map = "level" }, false, .set, .{ .int = 2 }, false, null, &.{}),
        row(opId(11, 0), made(8, 0), .{ .map = "align" }, false, .set, .{ .str = "center" }, false, null, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    // **Three spans: the text either side of the block, and the block.** The
    // block is its own span because [`processActionValDiff`](Self.processActionValDiff)
    // sends a `MakeMap` to [`SpanState.pushBlock`](Self.pushBlock) and to nothing
    // else, and because a block flushes the run in front of it
    // ([`spans.rs:544-556`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    try testing.expectEqual(@as(usize, 3), got.items.len);
    try testing.expectEqualStrings("ab", try textOf(got.items[0]));
    try testing.expectEqualStrings("cd", try textOf(got.items[2]));
    // The text either side is unaffected: two marks-free runs, one per side.
    try expectMarks(got.items[0], &.{});
    try expectMarks(got.items[2], &.{});

    // The block owns the full hydrated object, including its nested payload.
    try testing.expect((try blockOf(got.items[1])).eql(doc.set.idToExid(block.opId().?)));
    try testing.expectEqual(@as(usize, 3), got.items[1].block.count());
    try testing.expectEqualStrings("paragraph", got.items[1].block.get("kind").?.str);
    try testing.expectEqual(@as(i64, 2), got.items[1].block.get("level").?.int);
    const attrs = &got.items[1].block.get("attrs").?.object.map;
    try testing.expect(attrs.id.eql(doc.set.idToExid(opId(8, 0))));
    try testing.expectEqual(@as(usize, 1), attrs.count());
    try testing.expectEqualStrings("center", attrs.get("align").?.str);
    try testing.expectEqualStrings("\u{fffc}", got.items[1].asStr());
    try testing.expectEqual(@as(usize, 1), encoding.width(got.items[1].asStr()));

    // **And the op set's own width for the block's element is one**, read where
    // the width of an element actually lives: `index.text` on the register's
    // last row ([`elementWidth`] just above). This is the reader's width
    // checked against the document's, and not against itself.
    const rows = try doc.set.scopeToObj(text);
    var block_pos: ?usize = null;
    var at = rows.start;
    while (at < rows.end) : (at += 1) {
        const found = (try doc.set.get(at)) orelse continue;
        if (found.action() == .make_map) block_pos = at;
    }
    try testing.expect(block_pos != null);
    try testing.expectEqual(@as(usize, 1), try elementWidth(&doc.set, block_pos.?, rows.end));
    // The whole object is two, one, two — and the concatenation agrees.
    try testing.expectEqual(@as(usize, 5), try doc.set.seqLength(text, encoding, null));
    const rendered = try renderAll(got.items, gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("ab\u{fffc}cd", rendered);
}

test "span collectors release transferred text marks and block maps on allocation failure" {
    const text = made(1, 0);
    const block = made(3, 0);
    const doc = try Fixture.build(testing.allocator, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "a" }, false, null, &.{}),
        row(opId(3, 0), text, anchored(opId(2, 0)), true, .make_map, .null_value, false, null, &.{}),
        row(opId(4, 0), text, anchored(opId(3, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(4, 0))),
        row(opId(7, 0), block, .{ .map = "kind" }, false, .set, .{ .str = "paragraph" }, false, null, &.{}),
    });
    defer doc.destroy();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn exercise(gpa: Allocator, set: *Set, obj: ObjId) !void {
            var collected = try readAll(set, obj, gpa, null);
            defer freeSpans(&collected, gpa);
            try testing.expectEqual(@as(usize, 3), collected.items.len);
            try testing.expectEqualStrings("a", collected.items[0].asStr());
            try expectMarks(collected.items[0], &.{
                .{ .name = "bold", .value = .{ .bool_value = true } },
            });
            try testing.expectEqualStrings("paragraph", collected.items[1].block.get("kind").?.str);
            try testing.expectEqualStrings("b", collected.items[2].asStr());

            var diff = try diffAll(set, obj, gpa, .now());
            defer {
                for (diff.items) |*span| span.deinit(gpa);
                diff.deinit(gpa);
            }
            try testing.expectEqual(@as(usize, 3), diff.items.len);
            try testing.expectEqualStrings("a", diff.items[0].span.text.text);
            try testing.expect(diff.items[1].span == .obj);
            try testing.expectEqualStrings("b", diff.items[2].span.text.text);
        }
    }.exercise, .{ &doc.set, text });
}

test "nested marks and overlapping marks give different sets, and the difference is what a reader renders" {
    const gpa = testing.allocator;
    // Two documents over the same four elements and the same two names.
    //
    // `nested`: `bold` over all four and `italic` over "bc", so the middle run
    // carries **both**. `overlapping`: `bold` over "a" and `italic` over "bc",
    // so the middle carries one and the last run carries none.
    //
    // **The row order is what makes the two differ** and it is not the id
    // order: a mark's begin is placed before the element at its start index and
    // its end before the element at its end index
    // ([`transaction/inner.rs:827-857`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // and both are inserts anchored to the element in front of them.
    const nested_text = made(1, 0);
    const nested = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "n" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), nested_text, head(), "bold", .{ .bool_value = true }),
        row(opId(8, 0), nested_text, anchored(opId(5, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        markBegin(opId(12, 0), nested_text, anchored(opId(8, 0)), "italic", .{ .str = "under" }),
        row(opId(9, 0), nested_text, anchored(opId(12, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        row(opId(10, 0), nested_text, anchored(opId(9, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
        markEnd(opId(13, 0), nested_text, anchored(opId(10, 0))),
        row(opId(11, 0), nested_text, anchored(opId(13, 0)), true, .set, .{ .str = "d" }, false, null, &.{}),
        markEnd(opId(6, 0), nested_text, anchored(opId(11, 0))),
    });
    defer nested.destroy();

    const over_text = made(1, 0);
    const overlapping = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "o" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), over_text, head(), "bold", .{ .bool_value = true }),
        row(opId(8, 0), over_text, anchored(opId(5, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        markEnd(opId(6, 0), over_text, anchored(opId(8, 0))),
        markBegin(opId(12, 0), over_text, anchored(opId(6, 0)), "italic", .{ .str = "under" }),
        row(opId(9, 0), over_text, anchored(opId(12, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        row(opId(10, 0), over_text, anchored(opId(9, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
        markEnd(opId(13, 0), over_text, anchored(opId(10, 0))),
        row(opId(11, 0), over_text, anchored(opId(13, 0)), true, .set, .{ .str = "d" }, false, null, &.{}),
    });
    defer overlapping.destroy();

    var got_nested = try readAll(&nested.set, nested_text, gpa, null);
    defer freeSpans(&got_nested, gpa);
    var got_over = try readAll(&overlapping.set, over_text, gpa, null);
    defer freeSpans(&got_over, gpa);

    const bold = MarkSet.Entry{ .name = "bold", .value = .{ .bool_value = true } };
    const italic = MarkSet.Entry{ .name = "italic", .value = .{ .str = "under" } };
    const both = [_]MarkSet.Entry{ bold, italic };

    // **Nested**: the middle run is the only one carrying two names.
    try testing.expectEqual(@as(usize, 3), got_nested.items.len);
    try testing.expectEqualStrings("a", try textOf(got_nested.items[0]));
    try expectMarks(got_nested.items[0], &.{bold});
    try testing.expectEqualStrings("bc", try textOf(got_nested.items[1]));
    try expectMarks(got_nested.items[1], &both);
    try testing.expectEqualStrings("d", try textOf(got_nested.items[2]));
    try expectMarks(got_nested.items[2], &.{bold});

    // **Overlapping**: the middle carries one, and the tail carries none.
    try testing.expectEqual(@as(usize, 3), got_over.items.len);
    try testing.expectEqualStrings("a", try textOf(got_over.items[0]));
    try expectMarks(got_over.items[0], &.{bold});
    try testing.expectEqualStrings("bc", try textOf(got_over.items[1]));
    try expectMarks(got_over.items[1], &.{italic});
    try testing.expectEqualStrings("d", try textOf(got_over.items[2]));
    try expectMarks(got_over.items[2], &.{});

    // **The two answers are not the same answer**, and saying so is the point:
    // a reader that ignored one of the two folds would report the middle run of
    // both documents identically.
    try testing.expectEqualStrings(
        try textOf(got_nested.items[1]),
        try textOf(got_over.items[1]),
    );
    try testing.expectEqual(@as(usize, 2), marksOf(got_nested.items[1]).len);
    try testing.expectEqual(@as(usize, 1), marksOf(got_over.items[1]).len);
    try testing.expectEqual(@as(usize, 1), marksOf(got_nested.items[2]).len);
    try testing.expectEqual(@as(usize, 0), marksOf(got_over.items[2]).len);

    // Both documents still render to the same four characters: the marks are
    // what differs, not the text.
    const rendered_nested = try renderAll(got_nested.items, gpa);
    defer gpa.free(rendered_nested);
    const rendered_over = try renderAll(got_over.items, gpa);
    defer gpa.free(rendered_over);
    try testing.expectEqualStrings("abcd", rendered_nested);
    try testing.expectEqualStrings("abcd", rendered_over);
}

test "a scoped read differs from an unscoped one and is a span-for-span prefix of it" {
    const gpa = testing.allocator;
    // "ab", a block, then "cd" — and `cd` is written by an operation a clock
    // that stops before it does not see.
    //
    // **A block, not a run of text, is what makes the prefix assertable.** A
    // plain read coalesces adjacent unmarked text into one span, so dropping the
    // last element would shorten a span rather than remove one, and "the scoped
    // read is a prefix" would be a statement about characters rather than about
    // spans. A block ends a run, so the scoped read stops exactly on a span
    // boundary.
    const text = made(1, 0);
    const block = made(5, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "ab" }, false, null, &.{}),
        row(opId(5, 0), text, anchored(opId(2, 0)), true, .make_map, .null_value, false, null, &.{}),
        row(opId(7, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "cd" }, false, null, &.{}),
        row(opId(6, 0), block, .{ .map = "kind" }, false, .set, .{ .str = "paragraph" }, false, null, &.{}),
    });
    defer doc.destroy();

    var unscoped = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&unscoped, gpa);
    try testing.expectEqual(@as(usize, 3), unscoped.items.len);
    try testing.expectEqualStrings("cd", try textOf(unscoped.items[2]));

    var c = try clockUpTo(gpa, 6);
    defer c.deinit();
    var scoped = try readAll(&doc.set, text, gpa, c);
    defer freeSpans(&scoped, gpa);

    // **The two differ and the scoped one is a strict, position-for-position
    // prefix**: the same span, the same text and the same block at every index
    // it reaches, and nothing beyond.
    try testing.expect(scoped.items.len < unscoped.items.len);
    try testing.expectEqual(@as(usize, 2), scoped.items.len);
    for (scoped.items, 0..) |span, i| {
        try testing.expect(std.meta.activeTag(span) == std.meta.activeTag(unscoped.items[i]));
        try testing.expectEqualStrings(span.asStr(), unscoped.items[i].asStr());
        try testing.expectEqual(
            encoding.width(span.asStr()),
            encoding.width(unscoped.items[i].asStr()),
        );
    }
    try testing.expect((try blockOf(scoped.items[1])).eql(doc.set.idToExid(block.opId().?)));
    try testing.expectEqualStrings("paragraph", scoped.items[1].block.get("kind").?.str);
    try testing.expect(scoped.items[1].block.eql(&unscoped.items[1].block));
}

test "the diff says same, add and del, a deleted span costs no index, and a changed span is marked not replaced" {
    const gpa = testing.allocator;
    // The earlier state has "abc" with `bold` still to come; the later one has
    // "adc" with `bold` over "a" and "b" deleted by an operation only the later
    // state has.
    //
    // **The ids are chosen so the walk visits all three tags.** A `Del` is only
    // emitted where the earlier state has a winner the later one does not, and
    // the top walk is positional ([`tools.PastSkipper`](tools.zig); upstream's
    // `PastSkipper::next_skip`, [`iter/tools.rs:458-474`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs)).
    // The mark rows are winners only in the later state, and that is what
    // shifts the alignment onto a step of its own.
    //
    // **The row order is the mark's, not the text's.** A mark's begin sits
    // before the element at its start index and its end before the element at
    // its end index ([`transaction/inner.rs:827-857`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs));
    // here the mark covers `[0, 1)`, so its end lands between "a" and "d".
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(2, 0))),
        row(opId(8, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "d" }, false, null, &.{}),
        row(opId(3, 0), text, anchored(opId(8, 0)), true, .set, .{ .str = "b" }, false, null, &del_of_b),
        row(opId(4, 0), text, anchored(opId(3, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
    });
    defer doc.destroy();

    var before = try clockUpTo(gpa, 4);
    defer before.deinit();
    var after = try clockUpTo(gpa, 9);
    defer after.deinit();

    var got = try diffAll(&doc.set, text, gpa, .{ .diff = .{ .before = before, .after = after } });
    defer {
        for (got.items) |*span| span.deinit(gpa);
        got.deinit(gpa);
    }

    // **Four spans and three different tags.** A reader that hardcoded `.add`
    // would hand back four additions and pass a test that only ever produced
    // additions; this one counts them, so it cannot.
    var seen_same: usize = 0;
    var seen_add: usize = 0;
    var seen_del: usize = 0;
    for (got.items) |span| switch (span.diff) {
        .same => seen_same += 1,
        .add => seen_add += 1,
        .del => seen_del += 1,
    };
    try testing.expectEqual(@as(usize, 4), got.items.len);
    try testing.expectEqual(@as(usize, 2), seen_same);
    try testing.expectEqual(@as(usize, 1), seen_add);
    try testing.expectEqual(@as(usize, 1), seen_del);

    // **In order, with the tags and the indices above them.** The index is the
    // position the span occupies *after* the `Add` and `Del` before it have been
    // applied, which is what [`SpanState.diffWidth`](Self.diffWidth)
    // (`spans.rs:536-542`) is for.
    try testing.expectEqual(Diff.same, got.items[0].diff);
    try testing.expectEqualStrings("a", got.items[0].span.text.text);
    try testing.expectEqual(@as(usize, 0), got.items[0].span.text.index);
    try testing.expectEqual(Diff.add, got.items[1].diff);
    try testing.expectEqualStrings("d", got.items[1].span.text.text);
    try testing.expectEqual(@as(usize, 1), got.items[1].span.text.index);
    try testing.expectEqual(Diff.del, got.items[2].diff);
    try testing.expectEqualStrings("b", got.items[2].span.text.text);
    // **The deleted span costs no index**: "b" sat at index 1 in the earlier
    // state and "c" comes out at 2, which is where "c" sits in the *later*
    // state. A reader that counted a `Del` would put "c" at 3 and every patch
    // written after it would splice at the wrong offset.
    try testing.expectEqual(@as(usize, 2), got.items[2].span.text.index);
    try testing.expectEqual(Diff.same, got.items[3].diff);
    try testing.expectEqualStrings("c", got.items[3].span.text.text);
    try testing.expectEqual(@as(usize, 2), got.items[3].span.text.index);

    // **And applying the diff to the earlier text produces the later one.** A
    // `Same` span is checked rather than applied, an `Add` is inserted at the
    // index it reports, a `Del` is deleted there, and the result is the later
    // state's text — the property that says the indices are right.
    var earlier = try readAll(&doc.set, text, gpa, before);
    defer freeSpans(&earlier, gpa);
    var later = try readAll(&doc.set, text, gpa, after);
    defer freeSpans(&later, gpa);
    const seeded = try renderAll(earlier.items, gpa);
    defer gpa.free(seeded);
    try testing.expectEqualStrings("abc", seeded);
    var replayed: std.ArrayList(u8) = .empty;
    defer replayed.deinit(gpa);
    try replayed.appendSlice(gpa, seeded);
    for (got.items) |span| switch (span.diff) {
        .same => {
            // The span's own bytes, not the rest of the buffer: a `Same` span
            // must already be there, at the index it reports.
            const at = try byteOffset(encoding, replayed.items, span.span.text.index);
            try testing.expectEqualStrings(
                span.span.text.text,
                replayed.items[at .. at + span.span.text.text.len],
            );
        },
        .add => {
            const at = try byteOffset(encoding, replayed.items, span.span.text.index);
            try replayed.insertSlice(gpa, at, span.span.text.text);
        },
        .del => {
            const at = try byteOffset(encoding, replayed.items, span.span.text.index);
            try replayed.replaceRange(gpa, at, span.span.text.text.len, "");
        },
    };
    try testing.expectEqualStrings("adc", replayed.items);

    // **And that is exactly what the later state reads as**, which is the same
    // statement from the other side: the diff and the read agree.
    const later_text = try renderAll(later.items, gpa);
    defer gpa.free(later_text);
    try testing.expectEqualStrings(later_text, replayed.items);

    // **The unchanged span is marked, not replaced.** "a" is `same` — its text
    // did not move — and it carries the mark that arrived with it, so a patch
    // consumer is told "this text, now bold" rather than being handed an
    // unmarked replacement for it.
    var exported = try got.items[0].exportSpan(gpa, &doc.set, after);
    // `exportSpan` moved the payload out of the item, so the item now holds a
    // pointer it no longer owns; clear it before the loop below frees it.
    got.items[0] = .{ .diff = .same, .span = .{ .obj = .{
        .id = ExIdPromise(opmod.Op).init(&doc.set, OpId.root),
        .index = 0,
        .expose = false,
    } } };
    defer exported.deinit(gpa);
    try expectMarks(exported, &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
}

test "empty text reads as nothing, and a text holding only a block reads as that block" {
    const gpa = testing.allocator;
    const empty = made(1, 0);
    const only_block = made(2, 0);
    const block = made(3, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(2, 0), .root, .{ .map = "b" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(1, 0), .root, .{ .map = "e" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(3, 0), only_block, head(), true, .make_map, .null_value, false, null, &.{}),
        row(opId(4, 0), block, .{ .map = "kind" }, false, .set, .{ .str = "paragraph" }, false, null, &.{}),
    });
    defer doc.destroy();

    // An object with no rows at all: an empty range, and an empty read. **Not
    // a flush of an empty run and not a zero-length span** — there is nothing
    // to flush ([`SpanState.flush`](Self.flush)).
    {
        const rows = try doc.set.scopeToObj(empty);
        try testing.expectEqual(@as(usize, 0), rows.end - rows.start);
        var got = try readAll(&doc.set, empty, gpa, null);
        defer freeSpans(&got, gpa);
        try testing.expectEqual(@as(usize, 0), got.items.len);
    }

    // One block and no text: **the block is the whole read**, and the object is
    // one position long.
    {
        var got = try readAll(&doc.set, only_block, gpa, null);
        defer freeSpans(&got, gpa);
        try testing.expectEqual(@as(usize, 1), got.items.len);
        try testing.expect((try blockOf(got.items[0])).eql(doc.set.idToExid(block.opId().?)));
        try testing.expectEqualStrings("paragraph", got.items[0].block.get("kind").?.str);
        try testing.expectEqual(@as(usize, 1), try doc.set.seqLength(only_block, encoding, null));
        const rendered = try renderAll(got.items, gpa);
        defer gpa.free(rendered);
        try testing.expectEqualStrings("\u{fffc}", rendered);
    }
}

test "a mark's marks are resolved by name, and only the ones that moved are a change" {
    const gpa = testing.allocator;
    // The document fold has `bold` and `link`; the merge fold has `bold`
    // unchanged, a new `em`, and `link` with a different value. The three names
    // cover all three arms of [`batch.MarkDiff`]'s flatten
    // ([`batch.MarkDiff.exportSet`](../opset/batch.zig), upstream's `Pop` enum
    // at [`spans.rs:345-349`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    //
    // **This test pins the contract this file leans on rather than re-testing
    // `batch.zig`:** that the three arms keep, tombstone and drop exactly what a
    // reader renders, and that the tag chooses the view.
    var before = MarkSet.init(gpa);
    defer before.deinit();
    try before.put("bold", .{ .bool_value = true });
    try before.put("link", .{ .str = "x" });

    var after = MarkSet.init(gpa);
    defer after.deinit();
    try after.put("bold", .{ .bool_value = true });
    try after.put("em", .{ .int = 1 });
    try after.put("link", .{ .str = "y" });

    const both = MarkDiff{ .diff = .{ .before = &before, .after = &after } };

    // **A `Same` run reads the difference, and `bold` is not part of it.** It is
    // in both folds with the same value, so the flatten's `Both` arm drops it
    // ([`spans.rs:379-381`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    // A diff that reported it would send a mark patch for a mark that did not
    // move.
    {
        const view = markView(&before, &after, .same) orelse return error.TestExpectedItem;
        var flat = try view.exportSet(gpa);
        defer if (flat) |*m| m.deinit();
        try testing.expect(flat != null);
        try testing.expectEqual(@as(usize, 2), flat.?.len());
        try expectEntry(flat.?, 0, "em", .{ .int = 1 });
        try expectEntry(flat.?, 1, "link", .{ .str = "y" });
    }

    // **An `Add` run reads the merge fold outright**, name for name including
    // the one that did not move — `spans.rs:319-320`. This is the whole
    // difference between a read and a diff of the same two folds.
    {
        const view = markView(&before, &after, .add) orelse return error.TestExpectedItem;
        var flat = try view.exportSet(gpa);
        defer if (flat) |*m| m.deinit();
        try testing.expect(flat != null);
        try testing.expectEqual(@as(usize, 3), flat.?.len());
        try expectEntry(flat.?, 0, "bold", .{ .bool_value = true });
        try expectEntry(flat.?, 1, "em", .{ .int = 1 });
        try expectEntry(flat.?, 2, "link", .{ .str = "y" });
    }

    // **A `Del` run reads nothing**, whatever the folds hold.
    try testing.expect(markView(&before, &after, .del) == null);
    // And an unmarked object reads nothing for any tag.
    var none = MarkSet.init(gpa);
    defer none.deinit();
    try testing.expect(markView(null, null, .same) == null);
    try testing.expect(markView(null, null, .add) == null);
    try testing.expect(markView(null, null, .del) == null);

    // **A name only the document fold has becomes an unmark tombstone** — the
    // name with a null value, not the value it had and not a dropped entry
    // ([`spans.rs:360-366`](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
    // That is how a reader is told to *remove* the mark rather than to set it.
    {
        var gone = MarkSet.init(gpa);
        defer gone.deinit();
        try gone.put("dropped", .{ .bool_value = true });
        const view = markView(&gone, null, .same) orelse return error.TestExpectedItem;
        var flat = try view.exportSet(gpa);
        defer if (flat) |*m| m.deinit();
        try testing.expect(flat != null);
        try testing.expectEqual(@as(usize, 1), flat.?.len());
        try expectEntry(flat.?, 0, "dropped", .null_value);
    }

    // **A null value on the merge side is dropped**, not turned into a
    // tombstone (`spans.rs:367-372`): a mark the later state removed with no
    // mark before it is not something to tell a reader about.
    {
        var unmark = MarkSet.init(gpa);
        defer unmark.deinit();
        try unmark.put("bold", .null_value);
        const view = markView(null, &unmark, .add) orelse return error.TestExpectedItem;
        var flat = try view.exportSet(gpa);
        defer if (flat) |*m| m.deinit();
        try testing.expect(flat == null);
    }
    _ = both;
}

test "a spans reader allocates nothing to construct and frees everything it made" {
    // `FailingAllocator` with no `fail_index` never fails and counts every byte
    // its inner allocator hands out, so it is a counter and a real allocator at
    // once ([`parents.zig`](../../opset/parents.zig)).
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "ab" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(2, 0))),
        row(opId(3, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "cd" }, false, null, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(text);

    // Warm the op set: it sizes its own successor buffer the first time a walk
    // needs one, and that allocation belongs to the op set, not to a reader.
    {
        var warm = try Spans(opmod.Op).init(gpa, &doc.set, rows, null, encoding);
        defer warm.deinit();
        while (try warm.next()) |span| {
            var owned = span;
            owned.deinit(gpa);
        }
    }

    // **Live bytes, and not `allocated_bytes`**: `FailingAllocator` never
    // decrements `allocated_bytes` on a free, it adds to `freed_bytes`
    // ([`std/testing/FailingAllocator.zig:123-133`](../../lib/std/testing/FailingAllocator.zig)),
    // so the count of bytes still held is the difference.
    const live = counter.allocated_bytes - counter.freed_bytes;
    const before = live;

    // **Constructing a reader allocates nothing**: five column cursors, a
    // lookahead and two empty mark folds, every one of them a value over
    // storage the op set already holds.
    var reader = try Spans(opmod.Op).init(gpa, &doc.set, rows, null, encoding);
    try testing.expectEqual(before, live);

    // Reading allocates — the run it buffers and the span it hands out — and
    // each span is released as it is consumed, which is the rule the type says.
    var seen: usize = 0;
    while (try reader.next()) |span| {
        seen += 1;
        var owned = span;
        owned.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 2), seen);

    reader.deinit();
    // **Back to the baseline.** A missed `Span.deinit`, an unreleased fold or a
    // buffered run that outlived its reader all land here.
    try testing.expectEqual(before, live);
}

test "a span outlives the reader that produced it, and freeing the reader does not touch it" {
    // **`FailingAllocator` as a pure byte counter**, as the test above uses it.
    // The document is built with `testing.allocator` and not with `gpa`, so
    // every byte counted below belongs to the reader or to a span it handed
    // out, and none of it belongs to the fixture.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const text = made(1, 0);
    // **The marked fixture, not the plain one**: a plain run carries no mark
    // set, so a span that kept a *borrowed* fold rather than a copied one would
    // still read "ab" here and this test would pass with the defect it is for.
    // The mark set is the half that proves the copy.
    const doc = try Fixture.build(testing.allocator, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "ab" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(2, 0))),
        row(opId(3, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "cd" }, false, null, &.{}),
    });
    defer doc.destroy();
    const rows = try doc.set.scopeToObj(text);

    const held = blk: {
        var reader = try Spans(opmod.Op).init(gpa, &doc.set, rows, null, encoding);
        defer reader.deinit();
        // Constructing a reader allocates nothing.
        try testing.expectEqual(@as(usize, 0), counter.allocated_bytes - counter.freed_bytes);
        break :blk (try reader.next()) orelse return error.TestExpectedItem;
    };

    {
        var owned = held;
        defer owned.deinit(gpa);
        // The reader is gone; the span's bytes and marks remain independent.
        try testing.expectEqualStrings("ab", try textOf(owned));
        try expectMarks(owned, &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    }

    // The span and reader both released their independent storage exactly once.
    try testing.expectEqual(@as(usize, 0), counter.allocated_bytes - counter.freed_bytes);
}

test "a mark that crosses an op-tree page is neither split nor carried past its end, at every page boundary" {
    const gpa = testing.allocator;
    const text = made(1, 0);
    // **Two clocks that differ by exactly one operation**, the trailing insert.
    // Everything the mark wrote is in both, so both of its rows read `.same`
    // (`spans.rs:667-681`), which is the case the upstream test is about: the
    // mark is in the earlier state *and* the later one, so an unchanged mark has
    // to read as unchanged (`tests/text.rs:458-501`).
    var before = try clockUpTo(gpa, page_chars + 3);
    defer before.deinit();
    var after = try clockUpTo(gpa, page_chars + 4);
    defer after.deinit();

    // **Every start index, and not one chosen boundary.** The mark is two
    // characters wide, so `0 .. page_chars - 2` places its begin and its end on
    // every pair of adjacent rows of the fixture — which puts each of them on
    // the far side of a page boundary in some iteration, without the test
    // knowing or asserting where that boundary is. A test that picked one
    // position would be a test of the page size as much as of the walk.
    for (0..page_chars - 2) |start| {
        const rows = pageBoundaryRows(text, start);
        const doc = try Fixture.build(gpa, &.{actor_a}, &rows);
        defer doc.destroy();

        var got = try diffAll(&doc.set, text, gpa, .{ .diff = .{ .before = before, .after = after } });
        defer {
            for (got.items) |*span| span.deinit(gpa);
            got.deinit(gpa);
        }

        // **Two spans: the whole text, and the one character added past it.**
        //
        // **Three is the failure, and it is a mark count, not a character
        // count.** The mark's begin and its end are two rows inside the text,
        // and a walk that compared the folds' marks by anything but content
        // split the run at both of them — so the mark that began at `start` and
        // ended at `start + 2` came back over the run *before* it, over the two
        // characters it covers, and over the run after it. The third span is
        // what upstream's `assert_eq!(patches.len(), 1)` is really counting
        // (`tests/text.rs:486`): a `Same` text span carrying a mark set becomes
        // a patch (`spans.rs:32-36`), and three such spans are three patches
        // where the reference has one.
        if (got.items.len != 2) {
            std.debug.print("mark at {d}: {d} span(s), want 2\n", .{ start, got.items.len });
            for (got.items) |span| {
                switch (span.span) {
                    .text => |t| std.debug.print("  {s} idx={d} \"{s}\" marks={d}\n", .{
                        @tagName(span.diff), t.index, t.text, diffMarksOf(span).len,
                    }),
                    .obj => |o| std.debug.print("  {s} block at {d}\n", .{ @tagName(span.diff), o.index }),
                }
            }
            return error.TestExpectedEqual;
        }

        const same_run = got.items[0];
        const added = got.items[1];
        try testing.expectEqual(Diff.same, same_run.diff);
        try testing.expectEqual(@as(usize, 0), same_run.span.text.index);
        try testing.expectEqual(@as(usize, page_chars), same_run.span.text.text.len);

        // **The mark is asserted by name, on both spans, and not by a count.**
        // The run before the mark's start must not carry it (it is not there
        // yet) and neither must the run after its end (it is gone) — and
        // `expectNoDiffMark` says so by name, so a span carrying `strong` plus
        // something else, or something else entirely, is still a failure.
        try expectNoDiffMark(same_run, "strong");
        try expectDiffMarks(added, &.{});
        try expectNoDiffMark(added, "strong");

        // **And the added character really is past the mark's end.** Without
        // this the absence above would pass on a fixture whose mark happened to
        // reach the tail.
        try testing.expectEqual(Diff.add, added.diff);
        try testing.expectEqualStrings("z", added.span.text.text);
        try testing.expectEqual(@as(usize, page_chars), added.span.text.index);
    }
}

test "an unmark tombstone splits no run and reaches no span" {
    const gpa = testing.allocator;
    // **A plain read, so this is the most consumer-visible surface there is.**
    // `"abc"` with a mark `bold` that is opened as an *unmark* over `[1, 2)` —
    // a mark begin whose value is null (`marks.zig`, the mark-operations table)
    // — so the fold holds `{bold: null}` while it is open and the flattening
    // drops it (`spans.rs:367-372`).
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        row(opId(2, 0), text, head(), true, .set, .{ .str = "a" }, false, null, &.{}),
        markBegin(opId(5, 0), text, anchored(opId(2, 0)), "bold", .null_value),
        row(opId(3, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(3, 0))),
        row(opId(4, 0), text, anchored(opId(6, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    // **One span of three characters, and no mark on it.** The unmark opens and
    // closes with one character between, and the active set passes through
    // `['none', 'bold (null)', 'none']` while the buffered run keeps carrying
    // no marks at all — which is upstream's
    // `spans_are_consolidated_in_the_presence_of_zero_length_spans`
    // (`tests/text.rs:297-319`) for the tombstone case.
    //
    // **Two spans is the failure, and it is a fold comparison that cannot see a
    // tombstone.** With only the merge fold holding `{bold: null}`, the question
    // `NextText.canExtend` asks is whether the fold's marks still flatten to
    // what the run carries; the flattening is empty
    // (`spans.rs:367-372`) and the run carries nothing, so the answer is yes and
    // the run keeps its text. An equality over the fold's *entries* instead of
    // its flattening compares `{bold: null}` against nothing and says no.
    if (got.items.len != 1) {
        std.debug.print("{d} span(s), want 1\n", .{got.items.len});
        for (got.items) |span| std.debug.print("  \"{s}\" marks={d}\n", .{ span.asStr(), marksOf(span).len });
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings("abc", got.items[0].asStr());
    try expectMarks(got.items[0], &.{});
    try expectNoMark(got.items[0], "bold");
}

test "a marked text of many rows reads as one span, and its marks are copied per mark operation and not per row" {
    // **The per-run cost, measured.** Before [`NextText.marks_epoch`], every
    // row of a marked run asked `canExtend` to walk both folds' entries, so a
    // text of `R` rows under `M` active mark names cost `O(R·M)` — quadratic in
    // the product, and `M` grows with the document. With the epoch the walk
    // happens only on a row that follows a mark operation which **moved** the
    // resolved content, so the cost is `O(R + P·M)` for `P` such operations.
    //
    // **Bytes allocated is the instrument, and it is the right one here**
    // because the walk allocates nothing — so this does not directly count
    // walks. What it does pin is the *copy* half, which is the other half of
    // the claim and the one that is observable: `refreshMarks` copies both
    // folds once per **changed** mark operation (spans.zig:848-875) and
    // `runMarks` copies the view once per **run** (spans.zig:857-862), and
    // neither may scale with the number of rows between them.
    //
    // **The rows: `R` characters, one `bold` mark opened before the first and
    // not closed until after the last**, so every row sits inside the mark and
    // the whole text is one run. The mark is what makes the test bite: an
    // unmarked read takes `pushUnmarkedAddStr`'s fast arm (spans.zig:820-853),
    // which never asks `canExtend` at all, so an unmarked fixture would pass
    // this whether or not the epoch existed.
    //
    // **Ids: the characters take `2 ..= R+1`, the mark's begin is `R+2` and its
    // end is `R+3`**, and the end's id is the begin's plus one
    // ([`markEnd`]'s doc). The mark's rows come **before** the text they cover
    // and its end before the element at its end index, which is the order
    // [`pageBoundaryRows`] above states for the same reason.
    const build_gpa = testing.allocator;
    const R: usize = 300;
    const text = made(1, 0);

    const build = struct {
        /// `R` single-code-point inserts under one open `bold` mark, as rows
        /// over a caller-owned buffer that outlives the op set.
        fn rows(gpa: Allocator, text_obj: ObjId, n: usize) !std.ArrayList(opmod.Op) {
            var out: std.ArrayList(opmod.Op) = .empty;
            errdefer out.deinit(gpa);
            const begin_id = opId(@intCast(n + 2), 0);
            const end_id = opId(@intCast(n + 3), 0);
            var prev: OpId = begin_id;
            try out.append(gpa, row(
                text_obj.opId().?,
                .root,
                .{ .map = "t" },
                false,
                .make_text,
                .null_value,
                false,
                null,
                &.{},
            ));
            try out.append(gpa, markBegin(begin_id, text_obj, head(), "bold", .{ .bool_value = true }));
            for (0..n) |i| {
                const id = opId(@intCast(i + 2), 0);
                try out.append(gpa, row(
                    id,
                    text_obj,
                    if (i == 0) head() else anchored(prev),
                    true,
                    .set,
                    // Every character is `"a"`, so the rendered text is a run of
                    // `n` of them and the assertion below can say so exactly.
                    .{ .str = "a" },
                    false,
                    null,
                    &.{},
                ));
                prev = id;
            }
            // The end sits after the last character, anchored on it, so no row
            // is inside the mark's tail.
            try out.append(gpa, markEnd(end_id, text_obj, anchored(prev)));
            return out;
        }
    };

    var ops = try build.rows(build_gpa, text, R);
    defer ops.deinit(build_gpa);
    const doc = try Fixture.build(build_gpa, &.{actor_a}, ops.items);
    defer doc.destroy();

    // **One span for the whole text, carrying `bold`.** A reader that split the
    // run per row would answer `R` spans, and a reader that split it at the
    // mark's own boundaries would answer three. This is the same assertion
    // shape as the page-boundary test above, for the same reason: a count of
    // spans is what upstream's `assert_eq!(patches.len(), 1)` is counting.
    var got = try readAll(&doc.set, text, build_gpa, null);
    defer freeSpans(&got, build_gpa);
    if (got.items.len != 1) {
        std.debug.print("{d} span(s) over {d} rows, want 1\n", .{ got.items.len, R });
        return error.TestExpectedEqual;
    }
    try testing.expectEqual(@as(usize, R), got.items[0].asStr().len);
    try expectMarks(got.items[0], &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    // **And the reader's bytes do not grow with the rows.** The fold copies
    // are `O(M)` per mark operation (`refreshMarks`) and `O(M)` per run
    // (`runMarks`), there is **one** mark operation and **one** run here, and
    // the span hands its marks over rather than copying them — so the bytes a
    // walk of `R` rows spends on marks are the same handful a walk of **one**
    // row spends. **That is the observable half of the claim**: a reader that
    // copied the mark set per row would spend `R` times this, and the ratio
    // between the two measurements is exactly the `R` this test pins.
    //
    // Two sizes a factor of eight apart, measured on the **walk only** — the
    // fixture and the op set are built before the counter is read, so their
    // bytes are not in either figure.
    const Walk = struct {
        fn bytes(gpa: Allocator, text_obj: ObjId, n: usize, counter: *testing.FailingAllocator) !usize {
            var built = try build.rows(gpa, text_obj, n);
            defer built.deinit(gpa);
            const counted = try Fixture.build(gpa, &.{actor_a}, built.items);
            defer counted.destroy();

            // Warm the op set's own successor buffer, which belongs to the op
            // set and not to the reader. **The warm-up's spans are freed** — a
            // reader hands out owned text and marks, and dropping them on the
            // floor would be a leak the counting allocator's own inner would
            // report at the end of the test.
            {
                var warm = try readAll(&counted.set, text_obj, gpa, null);
                defer freeSpans(&warm, gpa);
            }

            const before = counter.allocated_bytes;
            var spans = try readAll(&counted.set, text_obj, gpa, null);
            defer freeSpans(&spans, gpa);
            // The spans are read, not only counted, so a reader that answered
            // nothing cannot pass by allocating nothing.
            try testing.expectEqual(@as(usize, 1), spans.items.len);
            try testing.expectEqual(n, spans.items[0].asStr().len);
            try expectMarks(spans.items[0], &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
            return counter.allocated_bytes - before;
        }
    };

    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const cgpa = counter.allocator();
    const one = try Walk.bytes(cgpa, text, 1, &counter);
    const many = try Walk.bytes(cgpa, text, R, &counter);

    // **The bound is on the growth, and it is per row of text** — a plain
    // `many <= one * k` would be wrong here and would fail on a correct
    // reader: the run's **text buffer** is `n` bytes and its capacity doubles,
    // so a 300-row read legitimately allocates about 512 where a 1-row read
    // allocates about 8. What must **not** grow per row is the **mark** work.
    //
    // **Why `R * 4` separates them.** Legitimate growth is the text: about one
    // byte per row plus the slack in a doubled capacity, so a few bytes per row.
    // A reader that copied the mark set per row would add a `MarkSet` — one
    // allocation, a struct, and a 24-byte `MarkSet.Entry` for `bold` — to
    // **every** row, which is tens of bytes per row and cannot fit under four.
    // So the bound is loose on purpose and is a growth ceiling rather than a
    // byte count, so it does not have to be restated when a struct field grows.
    try testing.expect(many - one <= R * 4);
}

test "a mark that opens and closes with no text between still splits no run" {
    const gpa = testing.allocator;
    // **The case the epoch's whole design turns on, and it is the one the
    // prose above names.** `"abc"` with `bold` opened before `"a"`, a second
    // mark `em` opened and closed **with no text between the two**, and `bold`
    // closing after `"c"`. The active set passes through
    // `[bold] → [bold, em] → [bold]` while the buffered run keeps `[bold]`.
    //
    // **A counter over mark *operations* fails this**, and one over mark
    // operations is what the comment [`NextText.marks_epoch`] had to be
    // rewritten away from: `em` opening and closing moves the content twice, so
    // the epoch differs from the run's and `canExtend` takes the
    // `flattenedEql` walk — which compares **content** and answers equal, so the
    // run keeps its text. This is upstream's
    // `spans_are_consolidated_in_the_presence_of_zero_length_spans`
    // (`tests/text.rs:297-319`) with a **non-tombstone** mark, which the
    // unmark-tombstone test above covers only in its tombstone shape: upstream's
    // two zero-length marks are `Mark::new("strong", true, 1, 1)` and
    // `Mark::new("strong", true, 2, 2)` (`tests/text.rs:303-315`), and an empty
    // mark is exactly that shape — a begin and an end with no row between them.
    //
    // **One span of three characters carrying `bold` and not `em`** is the
    // answer. Three spans is the failure a content-blind comparison gives, and
    // one span carrying `em` is the failure a fold that forgot to end it
    // gives — so both marks are asserted, by name, and not by count.
    //
    // **The ids below are load-bearing, and they are not free choices.** A mark
    // end carries no name, and a nameless mark row names the begin at
    // `id.prev()` ([`Op.markIndex`](../../opset/op.zig), `op.rs:191-202`, the
    // `MarkIndexBuilder::End(self.id.prev())` arm), so an end closes the begin
    // whose counter is one below its own. [`OpSet.rebuildIndex`](../../opset/op_set.zig)
    // runs that word past the validator, which refuses an end whose begin it has
    // not already seen in row order
    // ([`MarkOrderValidator.checkEnd`](../../opset/index.zig), `index.rs:52-73`).
    // So `bold` is `(5, 0)` and `(6, 0)` and `em` is `(7, 0)` and `(8, 0)`:
    // each end is the counter after its own begin, and `bold`'s end arrives
    // after every row it covers. This is the shape the overlapping fixture
    // above writes, where the second mark's pair is `(12, 0)`/`(13, 0)` and the
    // first's end still closes `(5, 0)` at `(6, 0)`.
    const text = made(1, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(1, 0), .root, .{ .map = "t" }, false, .make_text, .null_value, false, null, &.{}),
        markBegin(opId(5, 0), text, head(), "bold", .{ .bool_value = true }),
        row(opId(2, 0), text, anchored(opId(5, 0)), true, .set, .{ .str = "a" }, false, null, &.{}),
        // `em` opens and closes between `"a"` and `"b"`, so no row is inside it.
        markBegin(opId(7, 0), text, anchored(opId(2, 0)), "em", .{ .bool_value = true }),
        markEnd(opId(8, 0), text, anchored(opId(7, 0))),
        row(opId(3, 0), text, anchored(opId(8, 0)), true, .set, .{ .str = "b" }, false, null, &.{}),
        row(opId(4, 0), text, anchored(opId(3, 0)), true, .set, .{ .str = "c" }, false, null, &.{}),
        markEnd(opId(6, 0), text, anchored(opId(4, 0))),
    });
    defer doc.destroy();

    var got = try readAll(&doc.set, text, gpa, null);
    defer freeSpans(&got, gpa);

    if (got.items.len != 1) {
        std.debug.print("{d} span(s), want 1\n", .{got.items.len});
        for (got.items) |span| std.debug.print("  \"{s}\" marks={d}\n", .{ span.asStr(), marksOf(span).len });
        return error.TestExpectedEqual;
    }
    try testing.expectEqualStrings("abc", got.items[0].asStr());
    try expectMarks(got.items[0], &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    // **`em` must not reach the span at all**, asserted by name so a span
    // carrying `em` plus something else is still a failure.
    try expectNoMark(got.items[0], "em");
}

test "parity rich span copies survive source teardown with detached marks and block actors" {
    const gpa = testing.allocator;
    var mark_name = [_]u8{ 'l', 'i', 'n', 'k' };
    var mark_bytes = [_]u8{ 'u', 'r', 'l' };
    var source_text = blk: {
        var source_marks = MarkSet.init(gpa);
        errdefer source_marks.deinit();
        try source_marks.put(&mark_name, .{ .str = &mark_bytes });
        break :blk Span{ .text = .{
            .text = try gpa.dupe(u8, "text"),
            .marks = source_marks,
        } };
    };
    var copied_text = source_text.dup(gpa) catch |failure| {
        source_text.deinit(gpa);
        return failure;
    };
    defer copied_text.deinit(gpa);
    source_text.deinit(gpa);
    @memset(&mark_name, '!');
    @memset(&mark_bytes, '!');
    try testing.expectEqualStrings("text", copied_text.asStr());
    const copied_marks = &copied_text.text.marks.?;
    try testing.expectEqualStrings("link", copied_marks.entries.items[0].name);
    try testing.expectEqualStrings("url", copied_marks.entries.items[0].value.str);

    var actor_bytes = [_]u8{ 0x12, 0x34 };
    const actor = types.ActorId.init(&actor_bytes);
    var copied_block = blk: {
        var source_block = Span{ .block = hydrate.Map.init(
            gpa,
            ExId.withActor(opId(7, 0), actor),
        ) };
        defer source_block.deinit(gpa);
        try source_block.block.putOwned("actor", hydrate.MapValue.init(
            .{ .actor_id = actor },
            false,
        ));
        break :blk try source_block.dup(gpa);
    };
    defer copied_block.deinit(gpa);
    @memset(&actor_bytes, 0xff);
    try testing.expectEqualStrings(&.{ 0x12, 0x34 }, copied_block.block.id.named.actor.bytes);
    try testing.expectEqualStrings(&.{ 0x12, 0x34 }, copied_block.block.get("actor").?.actor_id.bytes);
    try testing.expectEqual(@as(usize, 1), copied_block.block.count());
}

test "parity rich span deep duplication releases partial copies on OOM" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn exercise(gpa: Allocator) !void {
            var source = blk: {
                var source_marks = MarkSet.init(gpa);
                errdefer source_marks.deinit();
                try source_marks.put("link", .{ .str = "target" });
                break :blk Span{ .text = .{
                    .text = try gpa.dupe(u8, "body"),
                    .marks = source_marks,
                } };
            };
            defer source.deinit(gpa);
            var copied = source.dup(gpa) catch |failure| {
                try testing.expectEqualStrings("body", source.asStr());
                try testing.expectEqualStrings("target", source.text.marks.?.entries.items[0].value.str);
                return failure;
            };
            defer copied.deinit(gpa);
            try testing.expectEqualStrings("body", copied.asStr());
            try testing.expect(copied.text.marks.?.eql(&source.text.marks.?));
        }
    }.exercise, .{});
}
