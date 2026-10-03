//! Progressive editing: a forward-only read/write cursor over a
//! [`Column`](column.zig), and the rebuild it owns over the slab it stands
//! in (`rust/hexane/src/edit.rs`).
//!
//! A batch of edits to one region of a column costs **one partition, one
//! byte splice and one index update** through a cursor, and one of each per
//! edit through [`Column.splice`](column.zig). The cursor keeps one slab open
//! across the whole batch, so the edits that land in the slab it already
//! stands in cost nothing extra: no second partition, no second buffer, no
//! second byte splice, no second index update. That is the shape real
//! workloads have — in an automerge fragment chain 94% of splices land in
//! the slab the previous one just rebuilt (`edit.rs:95-101`).
//!
//! ```ignore
//! var e = try Edit.init(col.allocator(), &col, 0);
//! try e.seek(10).delete(5).insert(value).seek(100).insertRuns(runs);
//! try e.finish();
//! ```
//!
//! # The two coordinates
//!
//! Seeks take positions in the column **as it was when the cursor opened**,
//! so a caller holding a list of edits applies them in the order it has
//! them. The cursor therefore keeps two positions: `orig`, how many of the
//! column's own items it has consumed, and `out`, the same place in the
//! column as edited so far. Every caller upstream holds pre-edit positions
//! (splice lists, merges, succ writes), so making them convert would only
//! move the drift bookkeeping outside (`edit.rs:118-124`).
//!
//! # The rebuild, and what it replaces
//!
//! Upstream reaches the rebuild through two traits: `SlabEdit`, which names
//! an encoding's rebuild, and `EditSlab`, the six operations it has to
//! support (`edit.rs:12-63`). This port resolves both at comptime against the
//! codec seam `Column` already has, so [`Rebuild`] is generic over `E` rather
//! than a per-encoding type, and it holds the rebuilt region's *values*
//! rather than an incremental writer.
//!
//! The cost of that is named, not hidden: upstream's writer carries a run
//! across a seam without materialising it, so carrying a span of one value
//! through a rebuild is O(1) (`rle/edit.rs:151-168`); this port's rebuild
//! holds the values, so carrying is O(items carried). Everything the
//! acceptance of a *result* can see is the same — the same run budget, the
//! same slab split, the same index, the same bytes.
//!
//! What the rebuild does *not* do is re-encode the region it did not touch.
//! The write-back is one column-level splice — replace `[at, read)` of the
//! slab with the rebuilt values — and the splice copies the runs before the
//! cut and after the tail's first run verbatim (`rle/edit.rs:193-217` reads
//! only the tail's first run and carries the rest as bytes). So one
//! write-back is one partition, one byte splice, one cut to the run budget,
//! one coalescing of the neighbours and one index rebuild, however many
//! edits the slab took — and all five happen inside the one staged splice
//! the write-back publishes.
//!
//! # The open rebuild is a staging buffer
//!
//! Nothing an open rebuild has absorbed reaches the column until a
//! write-back, which happens at `finish`, at a carry-budget close, or when
//! the cursor walks into the next slab. So abandoning a cursor never
//! half-applies a rebuild: it throws it away whole, and the column still
//! holds every row it held before the rebuild opened. That is the one place
//! this port is deliberately stricter than upstream, whose `Drop` closes an
//! open rebuild and so commits the batch (`edit.rs:611-626`); Zig has no
//! destructors, `deinit` has no error channel, and a cursor that could only
//! be released by committing would make "I meant to throw that away"
//! impossible to say.
//!
//! **The cursor is not a transaction; the stage is.** A delete that covers
//! whole slabs publishes them the moment that stage is done, whether or not
//! a rebuild was open behind them, so a cursor's work is a sequence of
//! published stages plus at most one rebuild held for `finish`. A caller
//! that wants a cursor's whole run or none of it has to say which before it
//! starts, because `deinit` rolls back the held rebuild and cannot roll back
//! what a stage already published.
//!
//! **A write-back that is refused is the same as one that was not
//! attempted.** The batch is staged beside the column and published into it,
//! never written into it, so the whole write-back — the partition, the byte
//! splice, the length, the cut to the run budget, the coalescing, the index
//! — happens against a provisional column whose slab list starts as copies
//! of this one's. Every allocation the hand-over needs is taken before the
//! stage returns and the hand-over itself cannot fail, so a write-back
//! refused at any of its steps — out of `finish`, out of a carry-budget
//! close, out of the walk into the next slab — leaves that batch staged,
//! the cursor open, and the column byte-for-byte as it was *before that
//! stage*. The caller may retry it, or discard it with `deinit`; it is
//! never left believing a batch was committed when it was not, nor holding
//! a column whose length and index still measure the rows from before the
//! batch. That is the same discipline the staging buffer gives on the way
//! out, applied to the way in. It is a guarantee about the stage, though,
//! and a call that makes several of them — `delete` over several slabs —
//! keeps the ones that already published.
//!
//! # The codecs
//!
//! The cursor serves every codec whose stored value does not depend on the
//! value in front of it: the run-length codecs, the prefix codec and the
//! boolean codec. It refuses a delta column at comptime, because there the
//! wire value is a difference and the cursor has to carry the running value
//! and the debt an edit leaves behind — which is what upstream's separate
//! `DeltaEdit` wrapper does, layered over this cursor and never inside it
//! (`delta/mod.rs:1154-1400`). Upstream's own `SlabEdit` impls are the same
//! two codecs' (`rle/edit.rs:229-235`, `bool.rs:1538-1540`).

const std = @import("std");
const err = @import("../error.zig");
const column = @import("column.zig");
const slabmod = @import("slab.zig");

const ParseError = err.ParseError;
const Slab = slabmod.Slab;

/// The default carry budget, in runs — an encoding may state its own as
/// `E.carry_budget` (`SlabEdit::CARRY_BUDGET`, `edit.rs:18`).
///
/// Carrying costs a decode and a push per run; closing costs a partition, a
/// byte splice and an index update, and leaves the skipped bytes where they
/// are. In runs rather than items because that is what the work is: a long
/// span of one value is carried for nothing, the same span of distinct values
/// is better memmoved (`edit.rs:77-85`).
pub const run_budget: usize = 8;

/// The budget `E` carries through an open rebuild before closing it instead
/// (`edit.rs:18`). No ported codec states one of its own, so this is always
/// [`run_budget`].
fn carryBudget(comptime E: type) usize {
    if (@hasDecl(E, "carry_budget")) return E.carry_budget;
    return run_budget;
}

/// A cursor over the bytes of the current slab, standing at one of its items
/// (upstream `Reader`, `edit.rs:75-78`).
///
/// It trails the cursor and only catches up when something reads, so a caller
/// that just moves never decodes at all (`edit.rs:139-152`). It is `null`
/// until a read asks for one, and again after every jump through the index
/// or every write-back: those move bytes, and whatever the reader pointed at
/// is gone (`edit.rs:517-531`, `:539-546`).
fn Reader(comptime E: type) type {
    return struct {
        /// The reader itself.
        dec: E.WireDecoder,
        /// The item of the slab it stands at.
        at: usize,
    };
}

/// A rebuild in progress within one slab (upstream `RleEdit`,
/// `rle/edit.rs:31-43`).
///
/// Item offsets are into the slab as it was when the rebuild opened. `read`
/// is how far the rebuild has consumed the original, and `wires` is what it
/// has emitted; the two differ by the net edit, and `close` replaces
/// `[at, read)` of the slab with `wires`.
///
/// It owns both buffers it holds — the encode buffer and the segment list —
/// and releases them with `gpa`, which is the allocator the cursor was
/// opened with rather than the column's. `data` is the opposite: a read-only
/// view of the slab, borrowed from the column and dropped by `release`
/// without being freed. A copied rebuild is a second owner of both buffers.
fn Rebuild(comptime E: type) type {
    return struct {
        const Self = @This();

        /// The allocator both owned buffers are allocated and released
        /// with. It is the allocator `Edit.init` was given, and it is not
        /// released itself.
        gpa: std.mem.Allocator,
        /// The rebuilt region's values, in the codec's wire domain.
        wires: std.ArrayList(E.Wire),
        /// Item offset in the original slab where the rebuild starts.
        at: usize,
        /// How many of the slab's own items the rebuild has consumed.
        read: usize,
        /// The original slab's bytes, read-only for the rebuild's life.
        data: []const u8,
        /// Every run of the original slab, kept for the carry budget.
        segs: []const slabmod.Segment(E.Wire),

        /// An idle rebuild, holding no buffer and pointing at nothing.
        fn init(gpa: std.mem.Allocator) Self {
            return .{
                .gpa = gpa,
                .wires = .empty,
                .at = 0,
                .read = 0,
                .data = &.{},
                .segs = &.{},
            };
        }

        /// Frees the rebuild's buffer and its segment list. The column is
        /// untouched, so a caller that abandons the cursor has discarded
        /// the batch and nothing else.
        fn deinit(self: *Self) void {
            if (self.segs.len != 0) self.gpa.free(self.segs);
            self.wires.deinit(self.gpa);
            self.* = undefined;
        }

        /// Points the rebuild at item `at` of `slab` (`EditSlab::reset`,
        /// `edit.rs:30-31`). One pass over the slab's runs, which is what
        /// the carry budget is measured against and what upstream's
        /// `find_partition_at` walks to derive the reader and the partition
        /// together (`rle/edit.rs:130-149`).
        fn reset(self: *Self, slab: *const Slab, at: usize) ParseError!void {
            self.release();
            self.segs = try E.segmentsOf(self.gpa, slab.data);
            self.data = slab.data;
            self.at = at;
            self.read = at;
        }

        /// Carries `n` of the slab's own items through the rebuild
        /// unchanged, spending at most `runs` pushes, and returns what it
        /// declined to carry (`EditSlab::pass`, `edit.rs:33-49`).
        ///
        /// The budget is in runs because that is what the work is: a
        /// 10,000-item run costs one push, ten literals cost ten
        /// (`rle/edit.rs:151-168`). A push may stop part-way through a run,
        /// which is what upstream's `next_run_max` does — the remainder is
        /// the tail the write-back re-encodes.
        fn pass(self: *Self, n: usize, runs: usize) ParseError!usize {
            var want = n;
            var pushes: usize = 0;
            while (want > 0 and pushes < runs) {
                const ri = slabmod.runAt(E, self.segs, self.read);
                // Past the last run the cursor stands at the slab's end,
                // which the caller never asks a carry for: `step` only
                // offers what the slab still holds.
                if (ri >= self.segs.len) break;
                const seg = self.segs[ri];
                const take = @min(seg.item_end - self.read, want);
                if (seg.kind == .repeat or seg.kind == .absent) {
                    // A repeat or absent run's items are all one value, so
                    // the run's own metadata is the whole of them — the
                    // same reading `wireRange` does, without the
                    // allocation (`column.zig:337-348`).
                    @memset(try self.wires.addManyAsSlice(self.gpa, take), seg.first_value.?);
                } else {
                    const vals = try E.wireRange(self.gpa, self.data, self.read, self.read + take);
                    defer self.gpa.free(vals);
                    try self.wires.appendSlice(self.gpa, vals);
                }
                self.read += take;
                want -= take;
                pushes += 1;
            }
            return want;
        }

        /// Inserts `n` copies of `value` at the cursor (`EditSlab::insert`,
        /// `edit.rs:51-52`).
        fn insert(self: *Self, value: E.Wire, n: usize) !void {
            if (n == 0) return;
            @memset(try self.wires.addManyAsSlice(self.gpa, n), value);
        }

        /// Drops `n` of the slab's own items (`EditSlab::delete`,
        /// `edit.rs:54-58`). Nothing is decoded: the items are not in the
        /// rebuilt region, and the codec this cursor serves stores values
        /// that do not depend on the items in front of them.
        fn delete(self: *Self, n: usize) void {
            self.read += n;
        }

        /// Drops everything the rebuild was holding.
        ///
        /// Run after the write-back has been published. The staged slab list
        /// shares the original column's buffers and the publish frees the
        /// slabs it detached — the one the rebuild was reading among them —
        /// so nothing may reach back into them after this. Neither does
        /// anything that was not released above: `segs` is the rebuild's own
        /// copy and `wires` is its own buffer, and `data` is only ever
        /// cleared, never read.
        fn release(self: *Self) void {
            self.wires.clearRetainingCapacity();
            if (self.segs.len != 0) self.gpa.free(self.segs);
            self.segs = &.{};
            self.data = &.{};
            self.at = 0;
            self.read = 0;
        }
    };
}

/// A forward-only read/write cursor over a [`Column`](column.zig).
///
/// See the module doc for the contract. `T` is the column's value type and
/// `E` its slab codec, which have to be the pair `Column(T, E)` was built
/// from. Every entry point that allocates takes the allocator, and it has to
/// be the column's own: a slab the cursor leaves behind is freed by the
/// column's `deinit`.
///
/// # What the cursor owns
///
/// * **The column is borrowed, not owned.** `col` is a mutable borrow that
///   must outlive the cursor, and the cursor writes to it. A column freed
///   while a cursor is open leaves the cursor pointing at nothing.
/// * **The rebuild buffer is owned.** It is allocated with the allocator
///   `init` was given and released by [`deinit`](Edit.deinit) with that same
///   allocator — not with the column's, which is a different value whenever
///   the cursor was opened over a column built in an arena.
/// * **A copy is a second owner of one buffer.** Zig has no move semantics,
///   so `var b = a;` gives two cursors that both free the same encode buffer
///   on `deinit`. Hand a cursor around as a pointer, or rebuild it.
/// * **Not thread-safe.** The cursor, its buffer and the column it writes to
///   are one mutable state with no synchronisation.
pub fn Edit(comptime T: type, comptime E: type) type {
    // The wire value is what a slab's bytes decode to, and the cursor reads
    // and writes the rebuilt region in the wire domain. Every codec this
    // cursor serves stores the value itself; a delta column stores a
    // difference, so its wire value is not its value and it needs the
    // running value and the debt an edit leaves behind — which is upstream's
    // `DeltaEdit` wrapper, layered over this cursor (`delta/mod.rs:1154`).
    if (E.Wire != T) {
        @compileError("the edit cursor serves a codec whose stored value is its column value; a delta column needs the DeltaEdit wrapper, not this cursor");
    }
    // Named here rather than inside the struct: a struct member named
    // `column` shadows the import for the whole of its own body, and that
    // body names the column type on every signature.
    const ColType = column.Column(T, E);
    return struct {
        const Self = @This();

        /// The column's value type.
        pub const Value = T;
        /// The column type this cursor edits.
        pub const Col = ColType;

        /// One run of an insert: `count` copies of `value` (`Run`, `lib.rs:196-201`).
        pub const Run = struct {
            /// The value every item of the run carries.
            value: T,
            /// How many items the run holds.
            count: usize,
        };

        col: *Col,
        /// Index of the slab the cursor is standing in.
        slab: usize,
        /// Item offset of the cursor within that slab, in the slab's
        /// *original* (pre-edit) coordinates.
        in_slab: usize,
        /// Absolute cursor position in the column's *original* coordinates —
        /// how many of its own items the cursor has consumed. This is what
        /// `seek` takes.
        orig: usize,
        /// The matching position in the column as edited so far, needed to
        /// re-find the cursor's slab after a write-back.
        out: usize,
        /// The rebuild, reset onto each slab this cursor edits. One of
        /// these lives for the whole cursor, holding the encode buffer, so a
        /// slab session costs a few field writes rather than building a few
        /// hundred bytes of encoder (`edit.rs:128-133`).
        edit: Rebuild(E),
        /// Whether `edit` is pointed at the current slab.
        dirty: bool,
        /// Original items after the cursor, maintained as it moves.
        ///
        /// The tail beyond the cursor is untouched, so this is both how many
        /// original items are left and how many current ones — which is why
        /// it can answer "is this the end of the column?" while a rebuild is
        /// open and `total_len` is stale (`edit.rs:135-142`).
        ahead: usize,
        /// Slabs this cursor has written back — what the batching is meant to
        /// keep down, and what a no-op `replace` must not increment.
        write_backs: usize,
        /// Times the cursor has brought the slab index and the weight
        /// prefixes back into step.
        index_writes: usize,
        /// The reader for the current slab, at `in_slab` in that slab's
        /// original bytes — valid clean *and* dirty, since a rebuild leaves
        /// the slab's bytes alone until it closes.
        dec: ?Reader(E),

        /// Opens a cursor over `col` at original position `at` (`Edit::new`,
        /// `edit.rs:164-191`).
        ///
        /// `at` past the end of the column is `error.InvalidValue`, matching
        /// upstream's out-of-bounds assertion. A column with no slabs is
        /// given one, because a column with no slabs cannot answer a locate
        /// and a splice into an empty column still has to land somewhere.
        pub fn init(gpa: std.mem.Allocator, col: *Col, at: usize) ParseError!Self {
            if (at > col.len()) return error.InvalidValue;
            try col.ensureSlab();
            // The front of the column needs no lookup — and a cursor opened
            // at 0 and then seeked, which is the common chain, would
            // otherwise pay for positioning twice (`edit.rs:173-174`).
            const hit = if (at == 0) Col.SlabPos{ .slab = 0, .in_slab = 0 } else col.locate(at);
            return .{
                .col = col,
                .slab = hit.slab,
                .in_slab = hit.in_slab,
                .orig = at,
                .out = at,
                .edit = Rebuild(E).init(gpa),
                .dirty = false,
                .ahead = col.len() - @min(at, col.len()),
                .write_backs = 0,
                .index_writes = 0,
                .dec = null,
            };
        }

        /// Releases the cursor, and with it the rebuild's encode buffer —
        /// freed with the allocator [`init`](Edit.init) was given, which is
        /// not necessarily the column's. The allocator itself is not
        /// released.
        ///
        /// An open rebuild is **discarded**, not written back: of what the
        /// cursor was carrying, nothing that was still in it reaches the
        /// column. Upstream's `Drop` closes the rebuild instead
        /// (`edit.rs:611-626`); see the module doc for why this port does
        /// not, and use `finish` to commit a batch.
        ///
        /// **This is not a rollback of the cursor's whole run.** It undoes
        /// the rebuild held here and nothing else. Whole slabs a
        /// [`delete`](Edit.delete) covered were published the moment their
        /// stage completed, and a [`finish`](Edit.finish) that already
        /// landed is in the column; both stay, because a caller cannot unwrite
        /// a column it has already handed back. Say which run you want before
        /// you start one.
        ///
        /// Calling this on a *copy* of a live cursor frees the buffer both
        /// own, and the second free is a double free: a cursor is moved by
        /// pointer, not by value.
        pub fn deinit(self: *Self) void {
            self.edit.deinit();
            self.* = undefined;
        }

        /// The cursor's position in the column's original coordinates — the
        /// coordinate system `seek` takes (`edit.rs:194-199`).
        pub fn pos(self: *const Self) usize {
            return self.orig;
        }

        /// The cursor's position in the column as edited so far
        /// (`edit.rs:201-205`).
        pub fn outPos(self: *const Self) usize {
            return self.out;
        }

        /// Original items still ahead of the cursor (`edit.rs:207-211`).
        pub fn remaining(self: *const Self) usize {
            return self.ahead;
        }

        /// The column under the cursor, borrowed for the cursor's life.
        ///
        /// **It answers the pre-batch column while a rebuild is open.** An
        /// open rebuild has not been written back, so `len` and the slab
        /// metadata still describe the column as it was before the batch and
        /// do not match what the cursor has already absorbed
        /// (`edit.rs:213-217`). This is neither an error nor a trap — the
        /// pointer is always right, and reading through it simply sees the
        /// pre-batch column until a write-back lands.
        pub fn column(self: *const Self) *const Col {
            return self.col;
        }

        /// How many slabs this cursor has written back. One per slab
        /// *touched*, however many edits landed in it — which is the whole
        /// point (`edit.rs:219-223`). Each write-back is one partition, one
        /// byte splice, one index update and one weight rebuild, so this is
        /// the count the batching is measured in.
        pub fn rebuilds(self: *const Self) usize {
            return self.write_backs;
        }

        /// How many times the cursor has brought the slab index and the
        /// weight prefixes back into step.
        ///
        /// A batch of edits inside one slab bumps this once however many
        /// edits it took, like `rebuilds`. It differs from `rebuilds` when
        /// a delete covers whole slabs: those are dropped without a rebuild,
        /// so the index moves without one.
        pub fn indexWrites(self: *const Self) usize {
            return self.index_writes;
        }

        /// Whether a rebuild is open, so the batch is not yet in the column.
        pub fn isOpen(self: *const Self) bool {
            return self.dirty;
        }

        // ── Moving ─────────────────────────────────────────────────────

        /// Moves forward to original position `to`, carrying everything in
        /// between through unchanged (`edit.rs:226-233`).
        ///
        /// Forward-only: every caller is already ascending, and it is what
        /// lets the cursor keep one slab open. `to` before the cursor is
        /// `error.InvalidValue`, matching upstream's assertion.
        pub fn seek(self: *Self, to: usize) ParseError!*Self {
            if (to < self.orig) return error.InvalidValue;
            _ = try self.advanceWith(to - self.orig);
            return self;
        }

        /// Moves forward `n` items from wherever the cursor is
        /// (`edit.rs:235-240`).
        pub fn advance(self: *Self, n: usize) ParseError!*Self {
            _ = try self.advanceWith(n);
            return self;
        }

        // ── Editing ────────────────────────────────────────────────────

        /// Inserts one `value` at the cursor (`edit.rs:295-301`).
        pub fn insert(self: *Self, value: T) ParseError!*Self {
            return self.insertRun(value, 1);
        }

        /// Inserts `n` copies of `value` at the cursor (`edit.rs:303-313`).
        pub fn insertRun(self: *Self, value: T, n: usize) ParseError!*Self {
            if (n == 0) return self;
            try self.open();
            _ = try self.edit.insert(value, n);
            self.out += n;
            return self;
        }

        /// Inserts a batch of runs at the cursor (`edit.rs:315-322`). A
        /// plain slice rather than an iterator, so a caller can hand it a
        /// list it already has and nothing is allocated to hand it over.
        pub fn insertRuns(self: *Self, runs: []const Run) ParseError!*Self {
            for (runs) |r| _ = try self.insertRun(r.value, r.count);
            return self;
        }

        /// The value at the cursor, without consuming it (`edit.rs:330-343`).
        ///
        /// A rebuild being open changes nothing: it writes into its own
        /// buffer and leaves the slab's bytes alone until it closes, so the
        /// item at the cursor is the same item either way.
        ///
        /// Upstream peeks off a decoder *state*, which a peek does not move.
        /// This port's reader is a live decoder, so reading a value moves it,
        /// and `at` is bumped to say so — otherwise the next read advances
        /// it past the value this one just took and the cursor drifts a
        /// whole run ahead of itself.
        pub fn peek(self: *Self) ParseError!?T {
            if (self.ahead == 0) return null;
            try self.loadReader();
            if (self.dec) |*r| {
                const v = try r.dec.next();
                r.at += 1;
                return v;
            }
            return error.InvalidValue;
        }

        /// Reads the value at the cursor and replaces it with what `f`
        /// returns — the shape of an in-place update: bumping a succ count,
        /// clearing a visibility bit (`edit.rs:347-364`).
        ///
        /// `f` takes and returns the column value itself, which for a
        /// nullable column is itself optional: a `null` it returns is the
        /// value *absent*, not a "leave it alone" signal. There are exactly
        /// two ways to change nothing, and neither is `f`'s return:
        ///
        /// * the cursor is at the end of the column, which `peek` reports
        ///   as `null` and this method returns from before `f` is called
        ///   (`edit.rs:352`);
        /// * `f` returned what was already there, which is compared rather
        ///   than written, so a caller that scans a column replacing only
        ///   some rows does not pay for the rows it left alone
        ///   (`edit.rs:355-358`).
        ///
        /// Upstream takes `impl FnOnce(T::Get<'_>) -> V where V:
        /// AsColumnRef<T>`; the end-of-column `Option` lives in `peek`'s
        /// return type there, not in `f`'s, and `AsColumnRef` is how it lets
        /// `f` hand back a borrowed value. This takes `T` both ways, which
        /// is the same rule without the indirection.
        ///
        /// `f` is a plain function pointer, so a captureless function
        /// literal and a named function both fit.
        pub fn replace(self: *Self, f: *const fn (T) T) ParseError!*Self {
            const cur = (try self.peek()) orelse return self;
            const next = f(cur);
            if (next == cur) return self.advance(1);
            _ = try self.delete(1);
            _ = try self.insert(next);
            return self;
        }

        /// Deletes `n` items at the cursor (`edit.rs:366-372`).
        ///
        /// **A refusal leaves the column and the cursor coherent, not
        /// untouched.** Every stage this call makes — a whole-slab drop, a
        /// write-back — takes what it needs before it touches the column and
        /// publishes in one step that cannot fail, so a refusal costs no
        /// half-applied edit: what is in the column is whole, and what is not
        /// is staged in the open rebuild, where [`finish`](Edit.finish) will
        /// commit it and [`deinit`](Edit.deinit) will throw it away. A delete
        /// over several slabs makes several stages, so a refusal can arrive
        /// after an earlier one published and the rows that one took stay
        /// taken; this call is not a transaction.
        ///
        /// **The cursor does not owe the batch twice, and does not owe all
        /// of it once.** By the time a refusal arrives, `pos`, `outPos` and
        /// `remaining` have already moved past the rows it consumed, and past
        /// nothing else: a refusal in the last write-back leaves `pos` at the
        /// end of the delete with the tail of it still staged. How far `pos`
        /// came depends on which stage refused. A stage refuses with its rows
        /// already consumed and staged whenever it got as far as taking them
        /// — and `close` runs after `took`, so a write-back that cannot be
        /// staged says so even when it is the *first* stage of the call. Only
        /// a refusal before the rows were taken leaves `pos` where the call
        /// found it: opening a rebuild, and staging a drop, which has moved
        /// nothing at all. So re-issuing `delete(n)` would delete a second
        /// span rather than continue this one, and `finish` on its own commits
        /// only the staged rebuild — it does not reach the rows this call
        /// never got to.
        ///
        /// **The recovery, in full.** A caller that wants the delete it asked
        /// for records `start = pos()` and `wanted = @min(n, remaining())`
        /// before the call. On a refusal it calls `finish` — which may itself
        /// refuse, and is retried the same way — and then deletes only what
        /// is left owing: `owed = wanted - (pos() - start)`, which is at most
        /// `remaining()` and is zero once the delete is complete. That is a
        /// fresh call on the same cursor, with the same recovery if it is
        /// refused, so the loop makes progress until `owed` is zero or the
        /// allocator lets a stage through. Nothing about the refusal is
        /// special-cased: every path into it leaves the cursor owned by the
        /// caller and valid to keep using.
        ///
        /// A caller that cannot afford to keep the part that published calls
        /// [`deinit`](Edit.deinit) instead, which discards the staged rebuild
        /// and leaves what is already in the column — that part is spent, and
        /// the caller's `owed` stops mattering because the cursor is gone.
        pub fn delete(self: *Self, n: usize) ParseError!*Self {
            // A delete off the end of the column takes what is there;
            // counting the rest would move the cursor past items that never
            // existed, and a later `seek` would look like it went backwards.
            var left = @min(n, self.ahead);
            while (left > 0) {
                const avail = self.origLen() - self.in_slab;
                // A locate never leaves the cursor at a slab's end except at
                // the end of the column, where nothing is left to take — so
                // reaching here means there is something in front of it.
                std.debug.assert(avail != 0);
                if (left < avail) {
                    try self.open();
                    self.edit.delete(left);
                    self.took(left);
                    return self;
                }
                // Whole slabs at the cursor, and no rebuild reading them:
                // drop them outright rather than through a rebuild. The
                // column always keeps one slab, so the last one is emptied
                // through the rebuild instead (`edit.rs:388-401`) — and
                // that is the condition to ask for, not merely "the column
                // holds more than one slab". At the last slab the two
                // disagree, and a drop taken there takes nothing: its own
                // loop stops short of the last slab, so it would answer
                // zero and `left` would never come down.
                const one_more = self.slab + 1 < self.col.slabs.items.len;
                if (self.in_slab == 0 and !self.dirty and one_more) {
                    left -= try self.dropSlabs(left);
                    continue;
                }
                // The delete reaches this slab's end: finish it here and go
                // on. `close` re-locates, which is what carries the cursor
                // into the next slab.
                try self.open();
                self.edit.delete(avail);
                self.took(avail);
                left -= avail;
                try self.close();
            }
            return self;
        }

        /// Drops the run of whole slabs at the cursor that `left` can cover,
        /// and answers how many items went (`edit.rs:388-401`).
        ///
        /// **The drop is staged and published, like a write-back, and it
        /// publishes the moment it is done.** The run reached no further than
        /// its own start, so the cursor does not move in edited coordinates —
        /// `orig` and `ahead` advance, and only once the column has taken the
        /// slabs. A refusal inside the stage therefore leaves the cursor
        /// where the caller left it, with the slabs still named and the index
        /// still measuring them, and `delete` can be called again. A stage
        /// that publishes is not undone by a later refusal in the same
        /// `delete`; see [`delete`](Edit.delete).
        ///
        /// **No value in a dropped slab is read.** The cut's head is empty by
        /// construction — the run starts on a slab boundary — so no piece is
        /// built from the range's front, and the slabs themselves are freed
        /// rather than rebuilt. What *is* decoded is the first slab behind
        /// the run: the cut ends on a boundary, and the column resolves that
        /// boundary to the slab that starts there rather than the one that
        /// ends there (`findByPrefix`'s strict `<`), so it rebuilds that
        /// whole slab as the range's one piece. That is the price of going
        /// through the column's splice, and it is one slab per drop however
        /// many slabs the run took — which is what `Rebuild.reset` would have
        /// cost had the run gone through a rebuild, and no more than the
        /// bytes one cut of the column already reads.
        ///
        /// **One stage covers the whole run**, so the price is one copy of
        /// the slab list and the index however many slabs go, rather than
        /// one per slab. Dropping them one at a time is what let a refusal
        /// leave a column holding an index that measured the rows from
        /// before the batch while the cursor's own counters had already
        /// moved. The seam the run leaves is coalesced by the stage's own
        /// reconciliation, over the one piece that replaced the range,
        /// exactly as a [`Column.splice`](column.zig) of the same range
        /// coalesces it.
        fn dropSlabs(self: *Self, left: usize) ParseError!usize {
            const col = self.col;
            var items: usize = 0;
            var s = self.slab;
            // The column always keeps one slab, so the run stops short of
            // the last one. It is never empty: the caller has established
            // that the current slab fits in `left` and that there is another
            // slab behind it.
            while (items < left and s + 1 < col.slabs.items.len) {
                const n = col.slabs.items[s].len;
                if (items + n > left) break;
                items += n;
                s += 1;
            }
            var stage = try col.stageSplice(col.tree.itemsBeforeSlab(self.slab), items, &.{});
            defer stage.deinit();
            stage.publish(col);
            self.index_writes += 1;
            // The run started at the cursor, so the rows it took were the
            // rows *at* it rather than rows behind it, and `out` — the
            // position in the column as edited — does not move.
            self.orig += items;
            self.ahead -= items;
            self.locateOut();
            return items;
        }

        /// Closes the open rebuild, if any, and reconciles the column. Ends
        /// a chain (`edit.rs:458-461`).
        ///
        /// **A refusal leaves the batch open and owed.** The write-back is
        /// staged beside the column and published into it, and the hand-over
        /// cannot fail, so an `error.OutOfMemory` out of here means the
        /// edits are still staged, `isOpen` is still true, and this call can
        /// simply be made again; `deinit` discards them instead and leaves
        /// the column as it was. A caller that cannot retry has to choose,
        /// and this is what it chooses on: neither outcome is silent.
        ///
        /// Idempotent in the sense that matters: a second call with nothing
        /// open returns at once without touching the column.
        pub fn finish(self: *Self) ParseError!void {
            try self.close();
        }

        // ── Internals ─────────────────────────────────────────────────

        /// The current slab's item count in its original coordinates —
        /// `slab.len` is only updated when the rebuild closes
        /// (`edit.rs:463-466`).
        fn origLen(self: *const Self) usize {
            return self.col.slabs.items[self.slab].len;
        }

        /// Accounts for `n` items the cursor has consumed (`edit.rs:427-432`).
        fn took(self: *Self, n: usize) void {
            self.in_slab += n;
            self.orig += n;
            self.ahead -= n;
        }

        /// from the slab's start if the cursor arrived through the index
        /// (`edit.rs:434-457`). Paid per read, over the ground since the
        /// last one.
        ///
        /// A reader standing *past* the cursor is the one case that cannot
        /// be walked forward, because a live decoder cannot be rewound: a
        /// caller that peeks twice without moving in between — peek, then a
        /// no-op `replace`, which peeks again — leaves it one value ahead.
        /// Upstream's reader is a state a peek does not move, so it never
        /// hits this. Here it costs a re-decode, and only for that caller.
        fn loadReader(self: *Self) ParseError!void {
            const slab = &self.col.slabs.items[self.slab];
            const held = self.dec orelse return self.readerAtStart(slab);
            if (held.at > self.in_slab) return self.readerAtStart(slab);
            var dec = held.dec;
            var i = held.at;
            while (i < self.in_slab) : (i += 1) {
                _ = (try dec.next()) orelse return error.InvalidValue;
            }
            self.dec = .{ .dec = dec, .at = self.in_slab };
        }

        /// A reader standing at the cursor, decoded from the slab's start.
        /// What a jump through the index needs, and what a reader left past
        /// the cursor needs too.
        fn readerAtStart(self: *Self, slab: *const Slab) ParseError!void {
            var dec = try E.WireDecoder.init(slab.data);
            var i: usize = 0;
            while (i < self.in_slab) : (i += 1) {
                _ = (try dec.next()) orelse return error.InvalidValue;
            }
            self.dec = .{ .dec = dec, .at = self.in_slab };
        }

        /// Moves `n` items forward, closing the open rebuild when the carry
        /// budget says the span is better memmoved than re-encoded
        /// (`advance_with`, `edit.rs:241-264`).
        fn advanceWith(self: *Self, n: usize) ParseError!usize {
            if (self.dirty and self.estRuns(n) >= carryBudget(E)) try self.close();
            var want = n;
            var jumped: usize = 0;
            while (want > 0) {
                if (!self.dirty) {
                    jumped += self.jump(want);
                    break;
                }
                const avail = self.origLen() - self.in_slab;
                const take = @min(want, avail);
                const left = try self.step(take);
                want -= take - left;
                if (left > 0) {
                    // The carry budget ran out; the loop jumps the rest.
                    try self.close();
                } else if (take == avail and !try self.nextSlab()) break;
            }
            return jumped;
        }

        /// Moves `n` items with no rebuild open (`jump`, `edit.rs:266-287`).
        ///
        /// The slabs in between are never visited — stepping through them
        /// would make a long seek O(slabs) — so the new position is looked up
        /// once. A move that stays inside the current slab skips the lookup
        /// and carries the reader along instead.
        fn jump(self: *Self, n: usize) usize {
            const moved = @min(n, self.ahead);
            // Strictly inside: landing exactly on the slab's end would rest
            // the cursor where no value can be read, which `locateOut`
            // resolves by moving on to the next slab.
            if (moved < self.origLen() - self.in_slab) {
                self.in_slab += moved;
                self.orig += moved;
                self.out += moved;
                self.ahead -= moved;
                return moved;
            }
            self.orig += moved;
            self.out += moved;
            self.ahead -= moved;
            self.locateOut();
            return moved;
        }

        /// Moves `n` items inside the current slab, returning the ones the
        /// open rebuild declined to carry (`step`, `edit.rs:468-495`).
        fn step(self: *Self, n: usize) ParseError!usize {
            if (n == 0) return 0;
            var left: usize = 0;
            // Dirty: the items have to be carried through the rebuild.
            if (self.dirty) left = try self.edit.pass(n, carryBudget(E));
            // Clean: nothing to do but move — no decode, no write.
            const done = n - left;
            self.in_slab += done;
            self.orig += done;
            self.out += done;
            self.ahead -= done;
            return left;
        }

        /// The runs a move of `n` items is expected to cross, from the
        /// slab's own run and item counts (`est_runs`, `edit.rs:496-504`).
        /// A cheap average, and only ever compared against the budget.
        fn estRuns(self: *const Self, n: usize) usize {
            const s = &self.col.slabs.items[self.slab];
            if (s.len == 0) return 0;
            return (n *| s.segments) / s.len;
        }

        /// Points `slab`/`in_slab` at the cursor's position, looked up
        /// through the index (`locate_out`, `edit.rs:515-531`). Only valid
        /// with no rebuild open: `out` is a position in the column as it
        /// stands, which is only true once the slab it touched has been
        /// written back.
        fn locateOut(self: *Self) void {
            const hit = self.col.locate(self.out);
            self.slab = @min(hit.slab, self.col.slabs.items.len - 1);
            self.in_slab = hit.in_slab;
            // The write-back moved bytes and the index answered in items:
            // whatever the reader was pointing at is gone.
            self.dec = null;
        }

        /// Steps to the next slab, closing the open rebuild if there is one.
        /// False at the end of the column (`next_slab`, `edit.rs:533-550`).
        fn nextSlab(self: *Self) ParseError!bool {
            if (self.dirty) {
                // `close` re-locates: the write-back can merge, split or
                // drop slabs, so the absolute position is the only way back
                // — and it has to happen even when this was the last slab,
                // or a following insert would land through a stale offset.
                try self.close();
                return self.ahead > 0;
            }
            if (self.slab + 1 >= self.col.slabs.items.len) return false;
            self.slab += 1;
            self.in_slab = 0;
            self.dec = .{ .dec = try E.WireDecoder.init(self.col.slabs.items[self.slab].data), .at = 0 };
            return true;
        }

        /// Begins a rebuild of the current slab if one is not already open
        /// (`open`, `edit.rs:552-563`).
        fn open(self: *Self) ParseError!void {
            if (self.dirty) return;
            const slab: *const Slab = &self.col.slabs.items[self.slab];
            try self.edit.reset(slab, self.in_slab);
            self.dirty = true;
        }

        /// Finishes the open rebuild: write it back, cut it to the run
        /// budget, coalesce the neighbours and update the index — each once,
        /// however many edits the slab took (`close`, `edit.rs:565-600`).
        ///
        /// **The batch is staged beside the column and published into it,
        /// never written into it.** [`Column.stageSplice`](column.zig) runs
        /// the whole write-back — the partition, the byte splice, the
        /// length, the cut to the run budget, the coalescing and the index
        /// — against a provisional column whose slab list starts as copies
        /// of this one's, and takes every allocation the hand-over needs
        /// before it returns. `publish` then hands the column the staged
        /// slabs, index, bases and length, and cannot fail.
        ///
        /// So `dirty` and `write_backs` are set only after a publish that
        /// cannot fail, and a refusal anywhere before it — the splice, the
        /// split, the merge, the re-index — leaves the rebuild staged in
        /// `edit`, the cursor open, and the column byte-for-byte as it was.
        /// `finish` can be called again, and `deinit` still discards the
        /// batch rather than half-applying it.
        ///
        /// Settling the live column beside the splice instead would leave
        /// two ways to be wrong on one refusal. Marking the cursor clean
        /// first would drop the staged edits on the floor; writing the bytes
        /// first and settling after would leave a column whose length and
        /// index still measure the rows from before the batch, so a later
        /// read resolves the wrong slab out of a tree that no longer
        /// describes the slab list. `isOpen` would answer false either way,
        /// and the caller would have no way to tell the column never
        /// received them.
        ///
        /// The batch is a column-level splice of `[at, read)` in slab `si`,
        /// which is the same splice the rebuild would have made in that
        /// slab's own bytes — the tail the rebuild did not reach is copied
        /// verbatim, and a rebuild that outgrew the run budget spills where
        /// the stage cuts it. Two costs this stops paying: the rebuild's
        /// `wires` are copied once by the stage's own value encoding, and the
        /// slab the splice writes comes out of the column's allocator rather
        /// than the cursor's, which is where a column-owned buffer belongs.
        fn close(self: *Self) ParseError!void {
            if (!self.dirty) return;
            const si = self.slab;
            var stage = try self.col.stageSplice(
                self.col.tree.itemsBeforeSlab(si) + self.edit.at,
                self.edit.read - self.edit.at,
                self.edit.wires.items,
            );
            defer stage.deinit();
            stage.publish(self.col);
            // The batch is in the column and its buffer is spent: a second
            // close must not splice it again.
            self.edit.release();
            self.dirty = false;
            self.write_backs += 1;
            self.index_writes += 1;
            // The write-back can merge, split or drop slabs, so `si` and
            // `in_slab` mean nothing until they are looked up again. Doing
            // it here rather than at each call site is what lets everything
            // downstream trust them.
            self.locateOut();
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A generated value for run `tag`: values one apart, so a column of them is
/// all runs. A nullable column is absent every eleventh run, which is what a
/// null run is for.
fn tagValue(comptime T: type, tag: usize) T {
    if (T == bool) return (tag % 2) == 1;
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (tag % 11 == 5) return null;
            return tagValue(o.child, tag);
        },
        else => {},
    }
    return @intCast(tag + 1);
}

/// A plain array standing in for the column a cursor is editing.
///
/// It carries the same two positions the cursor does (`edit.rs:118-124`),
/// and it carries them the same way, as two counters rather than one
/// derived from the other: `pos` is how much of `orig` the cursor has
/// consumed, `out` is where that is in `built`. A seek advances both and
/// changes neither list, because a seek carries the values between the two
/// positions through unchanged; an insert moves `out` and puts `n` values
/// at it; a delete moves `pos` and takes values at `out`. That is the
/// cursor's own arithmetic, so a disagreement with the column is a
/// disagreement about the cursor.
///
/// `out + (orig.len - pos) == built.len` holds throughout, but nothing
/// reads it to find a position: deriving `out` from it is what made an
/// earlier version of this model silently wrong across a second cursor,
/// where `orig` is no longer the column the cursor opened on. Use
/// `rebase` for that, which is what upstream's fuzz does between batches
/// (`edit_fuzz.rs:367`).
fn Model(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The values the column held when the cursor opened.
        orig: []const T,
        /// `orig`, when the model owns it rather than borrowing the slice
        /// `init` was handed. `rebase` has to copy, because the list it
        /// would otherwise point at is the one the edits move.
        owned: ?[]T = null,
        /// What the column holds now.
        built: std.ArrayList(T),
        /// How much of `orig` the cursor has consumed — the coordinate
        /// system `seek` takes.
        pos: usize = 0,
        /// Where that is in `built`.
        out: usize = 0,

        fn init(gpa: std.mem.Allocator, orig: []const T) !Self {
            var built: std.ArrayList(T) = .empty;
            try built.appendSlice(gpa, orig);
            return .{ .orig = orig, .built = built };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (self.owned) |buf| gpa.free(buf);
            self.built.deinit(gpa);
        }

        /// Makes what the column holds now the values a new cursor opens
        /// on, and puts the cursor at its front. A second cursor over the
        /// same column needs this: its positions are in the coordinates the
        /// column had when *it* opened, not the ones the first cursor saw.
        fn rebase(self: *Self, gpa: std.mem.Allocator) !void {
            if (self.owned) |buf| gpa.free(buf);
            self.owned = try gpa.dupe(T, self.built.items);
            self.orig = self.owned.?;
            self.pos = 0;
            self.out = 0;
        }

        /// The value the cursor is on.
        fn peek(self: *const Self) ?T {
            if (self.pos >= self.orig.len) return null;
            return self.built.items[self.out];
        }

        /// Moves to original position `to`, carrying the values in between
        /// through unchanged. A carry moves the list not at all, so both
        /// positions advance by the same amount.
        fn seek(self: *Self, to: usize) void {
            const n = to - self.pos;
            self.pos = to;
            self.out += n;
        }

        fn insert(self: *Self, gpa: std.mem.Allocator, value: T, n: usize) !void {
            if (n == 0) return;
            const at = self.out;
            // `insertSlice` grows by exactly `n` and shifts everything from
            // the cursor up, which is what inserting a run at the cursor
            // means.
            const run = try gpa.alloc(T, n);
            defer gpa.free(run);
            @memset(run, value);
            try self.built.insertSlice(gpa, at, run);
            self.out += n;
        }

        /// Deletes, clamping to what is left, as the cursor does
        /// (`edit.rs:377-378`). A delete does not move `out`: the values
        /// that were behind the cursor are now behind it still.
        fn delete(self: *Self, n: usize) void {
            const took = @min(n, self.orig.len - self.pos);
            self.built.replaceRangeAssumeCapacity(self.out, took, &.{});
            self.pos += took;
        }
    };
}

/// The column's structural invariants, with a report rather than a panic.
fn expectSound(comptime T: type, comptime E: type, col: *const column.Column(T, E)) !void {
    if (try col.checkInvariants()) |v| {
        std.debug.print("invariant broken: {s} {s} (slab {d} of {d})\n", .{
            @typeName(E),
            v.what,
            v.at,
            col.slabCount(),
        });
        return error.TestUnexpectedResult;
    }
    // The wire form is what a load validates, so a column that cannot be
    // written out cannot be reloaded either.
    const bytes = try col.encode(testing.allocator);
    defer testing.allocator.free(bytes);
    try E.canonicalSlab(bytes);
}

/// The value one row contributes to a prefix column's sum: its own value,
/// and nothing at all for an absent row (`column.zig:694-699`).
fn rowSum(comptime T: type, v: T) ParseError!i64 {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (v) |x| return rowSum(o.child, x);
            return 0;
        },
        else => return @intCast(v),
    }
}

/// The sum a prefix column's index must hold over `values`.
fn sumOf(comptime T: type, values: []const T) ParseError!i64 {
    var total: i64 = 0;
    for (values) |v| total = try std.math.add(i64, total, try rowSum(T, v));
    return total;
}

/// The column against the model, in order and by index, and its length.
fn expectModel(
    comptime T: type,
    comptime E: type,
    col: *const column.Column(T, E),
    model: *const Model(T),
) !void {
    const gpa = testing.allocator;
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    // `expectEqual` on a slice compares the pointer, not the contents
    // (`std/testing.zig:130-139`), so this has to be `expectEqualSlices` or
    // it is not a test at all.
    try testing.expectEqualSlices(T, model.built.items, got);
    try testing.expectEqual(model.built.items.len, col.len());
    try testing.expectEqual(model.built.items.len == 0, col.isEmpty());
    if (comptime E.tracks_prefix) {
        // The grand total is what the op-set loader sizes a companion column
        // with, so an edit has to leave it right (`op_set2/columns.rs:294-300`).
        try testing.expectEqual(try sumOf(T, model.built.items), try col.runningAt(model.built.items.len));
    }
    for (model.built.items, 0..) |want, i| {
        try testing.expectEqual(want, (try col.get(i)) orelse return error.TestUnexpectedResult);
    }
}

/// A column of `runs` runs of `3` values each, the tags running 0, 1, 2, ….
fn buildRuns(comptime T: type, comptime E: type, runs: usize) !struct {
    col: column.Column(T, E),
    orig: std.ArrayList(T),
} {
    const gpa = testing.allocator;
    var col = try column.Column(T, E).init(gpa);
    errdefer col.deinit();
    var orig: std.ArrayList(T) = .empty;
    errdefer orig.deinit(gpa);
    for (0..runs) |tag| {
        for (0..3) |_| {
            try orig.append(gpa, tagValue(T, tag));
            try col.append(gpa, tagValue(T, tag));
        }
    }
    try expectSound(T, E, &col);
    return .{ .col = col, .orig = orig };
}

/// The function `replace` takes when it is asked to change nothing.
fn same(comptime T: type) *const fn (T) T {
    return struct {
        fn f(v: T) T {
            return v;
        }
    }.f;
}

/// The function `replace` takes when it is asked to change a row: the value
/// ten thousand past what is there, which is a change for every row of the
/// column it is used on.
fn bump(v: u64) u64 {
    return v + 10_000;
}

test "an empty batch over an empty column leaves it empty and sound" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var col = try column.Column(T, E).init(gpa);
    defer col.deinit();

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        try testing.expectEqual(0, e.pos());
        try testing.expectEqual(0, e.outPos());
        try testing.expectEqual(0, e.remaining());
        try testing.expect(!e.isOpen());
        try testing.expectEqual(@as(?T, null), try e.peek());
        try e.finish();
        // An empty batch closes no rebuild, so nothing was written back.
        try testing.expectEqual(0, e.rebuilds());
        try testing.expectEqual(0, e.indexWrites());
    }

    try expectSound(T, E, &col);
    try testing.expectEqual(0, col.len());
    try testing.expect(col.isEmpty());
    // An empty column keeps exactly one slab, so the next write has
    // somewhere to land (`column.rs:1299-1308`).
    try testing.expectEqual(1, col.slabCount());
}

test "one insert and one delete through one cursor are each one write-back" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 20);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 5);
        defer e.deinit();
        _ = try e.insert(999);
        try e.finish();
        try testing.expectEqual(1, e.rebuilds());
        try testing.expectEqual(1, e.indexWrites());
    }
    m.seek(5);
    _ = try m.insert(gpa, 999, 1);
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    // The second cursor opens on the column the first one left, so the
    // model's coordinates are re-based on it before that.
    try m.rebase(gpa);
    m.seek(5);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 5);
        defer e.deinit();
        _ = try e.delete(2);
        try e.finish();
        try testing.expectEqual(1, e.rebuilds());
    }
    m.delete(2);
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
}

/// The gate: a batch of edits inside one slab is one partition, one byte
/// splice and one index update, not one of each per edit.
fn exerciseOneSlabBatch(comptime T: type, comptime E: type) !void {
    const gpa = testing.allocator;
    // 20 runs of 3 is 60 values in 20 segments: one slab, well inside the
    // run budget, so the batch below cannot spill for want of room.
    var built = try buildRuns(T, E, 20);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    try testing.expectEqual(1, col.slabCount());

    // Twenty inserts of two values and twenty advances: forty edit
    // operations, forty new values, and sixty original items consumed.
    const runs = 20;
    const values = runs * 2;
    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        for (0..runs) |tag| {
            const v = tagValue(T, 1000 + tag);
            _ = try e.insertRun(v, 2);
            _ = try m.insert(gpa, v, 2);
            _ = try e.advance(3);
            m.seek(m.pos + 3);
        }
        try testing.expectEqual(values, m.built.items.len - m.orig.len);
        try e.finish();
        // Twenty inserts and twenty advances, one write-back.
        try testing.expectEqual(1, e.rebuilds());
        try testing.expectEqual(1, e.indexWrites());
    }

    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    // Still one slab: twenty new runs and twenty original ones is inside
    // the budget, so nothing had to be cut.
    try testing.expectEqual(1, col.slabCount());
}

test "a batch of forty edits inside one slab is one partition, one byte splice and one index update" {
    try exerciseOneSlabBatch(u64, column.Rle(u64));
}

test "a delete that spans a slab boundary writes each slab it touches once" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    // 400 runs of 3 is 1200 values, far more runs than one slab holds.
    var built = try buildRuns(T, E, 400);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    const slabs_before = col.slabCount();
    try testing.expect(slabs_before > 2);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 300);
        defer e.deinit();
        // 200 items over several slabs, then an insert behind them.
        _ = try e.delete(200);
        _ = try e.insert(777);
        _ = try e.insertRuns(&.{
            .{ .value = 778, .count = 2 },
            .{ .value = 779, .count = 1 },
        });
        try e.finish();
        // One write-back per slab the batch touched, which is at most one
        // per slab the column had — and nowhere near one per item.
        try testing.expect(e.rebuilds() > 0);
        try testing.expect(e.rebuilds() <= slabs_before);
        try testing.expectEqual(e.rebuilds(), e.indexWrites());
    }
    m.seek(300);
    m.delete(200);
    _ = try m.insert(gpa, 777, 1);
    _ = try m.insert(gpa, 778, 2);
    _ = try m.insert(gpa, 779, 1);

    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
}

test "a batch that outgrows the run budget is one write-back and a partition" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 4);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    try testing.expectEqual(1, col.slabCount());

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        // Ninety new runs of two into one twelve-value slab: far past the
        // 64-run budget, so the write-back has to cut it.
        for (0..90) |tag| {
            const v = tagValue(T, 1000 + tag);
            _ = try e.insertRun(v, 2);
            _ = try m.insert(gpa, v, 2);
        }
        try e.finish();
        try testing.expectEqual(1, e.rebuilds());
        try testing.expectEqual(1, e.indexWrites());
    }

    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    try testing.expect(col.slabCount() > 1);
    // Every slab but the last is cut at the budget, never over it.
    for (0..col.slabCount() - 1) |i| {
        const s = col.slabAt(i).?;
        try testing.expectEqual(column.default_max_segments, s.segments);
    }
}

test "abandoning a cursor mid-batch leaves the column sound and its values intact" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 60);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    const before = try col.encode(gpa);
    defer gpa.free(before);

    // Absorb a batch and then release the cursor without finishing it: the
    // open rebuild holds every edit, and none of them has reached the
    // column. The `defer` is the abandonment — there is no `finish` in the
    // block, and the cursor cannot be released any other way without one.
    {
        var e = try Edit(T, E).init(col.allocator(), &col, 10);
        defer e.deinit();
        try testing.expect(e.isOpen() == false);
        _ = try e.seek(20);
        _ = try e.delete(5);
        _ = try e.insertRun(4242, 4);
        _ = try e.insert(4243);
        try testing.expect(e.isOpen());
        try testing.expectEqual(0, e.rebuilds());
        // Seeked to 20, deleted 5, inserted 5: the cursor has consumed 25 of
        // the column's own items, sits at 25 of the edited ones, and 155 of
        // its own are still ahead of it.
        try testing.expectEqual(25, e.pos());
        try testing.expectEqual(25, e.outPos());
        try testing.expectEqual(155, e.remaining());
        _ = try e.delete(2);
        // No `finish`: the batch goes with the cursor.
    }

    // The column is whole: not one byte of it moved, because not one write
    // happened.
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    const after = try col.encode(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);

    // And it is still a column the next write can use.
    try col.splice(gpa, 3, 2, &.{ 31, 32 });
    try expectSound(T, E, &col);
    try testing.expectEqual(built.orig.items.len, col.len());
    try testing.expectEqual(@as(T, 31), (try col.get(3)).?);
    try testing.expectEqual(@as(T, 32), (try col.get(4)).?);
}

test "a cursor that only reads never opens a rebuild" {
    const gpa = testing.allocator;
    const T = ?u64;
    const E = column.RleOption(u64);
    var built = try buildRuns(T, E, 70);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    const before = try col.encode(gpa);
    defer gpa.free(before);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        for (built.orig.items, 0..) |want, i| {
            try testing.expectEqual(@as(?T, want), try e.peek());
            _ = try e.replace(same(T));
            // A replacement equal to what was there must not dirty the
            // slab, or a caller that scans a column would pay a write-back
            // per row (`edit.rs:352-357`, `edit_fuzz.rs:640-664`).
            try testing.expectEqual(0, e.rebuilds());
            try testing.expectEqual(i + 1, e.pos());
        }
        try e.finish();
        try testing.expectEqual(0, e.rebuilds());
    }

    const after = try col.encode(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try expectSound(T, E, &col);
}

test "replace rewrites the value under the cursor and steps over the one it left alone" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 20);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 4);
        defer e.deinit();
        _ = try e.replace(same(T)); // row 4 is left alone
        try testing.expectEqual(0, e.rebuilds());
        // A real replacement dirties the slab, so the rebuild is open — but
        // it is not written back until the cursor closes, so `rebuilds` is
        // still zero here. That is upstream's own accounting, asserted the
        // same way at `column.rs:2291-2296`.
        _ = try e.replace(bump);
        try testing.expect(e.isOpen());
        try testing.expectEqual(0, e.rebuilds());
        try e.finish();
        try testing.expectEqual(1, e.rebuilds());
    }

    // The identity replace stepped the cursor to row 5, and the second one
    // rewrote that row.
    m.seek(5);
    const bumped = m.peek().?;
    m.delete(1);
    _ = try m.insert(gpa, bumped + 10_000, 1);
    m.seek(6);
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
}

test "a span past the carry budget closes the rebuild instead of re-encoding it" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 20);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);

    // A short span stays inside the open rebuild, so the whole batch is one
    // write-back and the slab is re-encoded once.
    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        _ = try e.insert(5000);
        _ = try m.insert(gpa, 5000, 1);
        _ = try e.advance(6);
        m.seek(6);
        _ = try e.insert(5001);
        _ = try m.insert(gpa, 5001, 1);
        try testing.expectEqual(0, e.rebuilds());
        try e.finish();
        try testing.expectEqual(1, e.rebuilds());
    }
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    try m.rebase(gpa);

    // A long one does not: the budget says the span is better memmoved, so
    // the rebuild closes where the cursor stands before the seek.
    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        _ = try e.insert(6000);
        _ = try m.insert(gpa, 6000, 1);
        _ = try e.advance(m.orig.len);
        m.seek(m.orig.len);
        try testing.expectEqual(1, e.rebuilds());
        try e.finish();
    }
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
}

test "a delete that covers whole slabs drops them without decoding" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var built = try buildRuns(T, E, 400);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    const slabs_before = col.slabCount();

    {
        var e = try Edit(T, E).init(col.allocator(), &col, 0);
        defer e.deinit();
        _ = try e.delete(300);
        try e.finish();
        // A whole slab at the head of the column is dropped outright, so the
        // index moved without a write-back: the batch costs a bounded number
        // of write-backs rather than one per deleted item, and the drop is
        // counted as an index write of its own.
        try testing.expect(e.rebuilds() <= 2);
        try testing.expect(e.indexWrites() > e.rebuilds());
    }
    m.delete(300);

    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    try testing.expect(col.slabCount() < slabs_before);
}

test "a delete that empties the last slab is emptied through a rebuild" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Prefix(u64);
    // A prefix codec, so the retained rows are held to an index that the
    // delete had to rebuild per slab and not only to bytes it could re-read.
    // 400 runs of 3 is 1200 values, far more runs than one slab holds.
    var built = try buildRuns(T, E, 400);
    var col = built.col;
    defer built.orig.deinit(gpa);
    defer col.deinit();
    var m = try Model(T).init(gpa, built.orig.items);
    defer m.deinit(gpa);
    const slabs = col.slabCount();
    const total = col.len();
    try testing.expect(slabs > 2);

    // The first item of the last slab: a boundary resolves to the slab that
    // starts there, so this is the final slab at its own start.
    const cut = blk: {
        var n: usize = 0;
        for (0..slabs - 1) |i| n += col.slabAt(i).?.len;
        break :blk n;
    };
    try testing.expect(cut > 0 and cut < total);

    {
        var e = try Edit(T, E).init(col.allocator(), &col, cut);
        defer e.deinit();
        // **The bug was the guard asking only whether the column held more
        // than one slab.** The drop stops short of the last one, so here it
        // took nothing, answered zero, and `left` never came down — the
        // delete spun, with the cursor going nowhere.
        try testing.expectEqual(slabs - 1, e.slab);
        try testing.expectEqual(0, e.in_slab);

        _ = try e.delete(total - cut);
        try e.finish();

        try testing.expect(!e.isOpen());
        // Every original row past the boundary is taken, and the cursor
        // answers in both coordinate systems rather than only the first.
        try testing.expectEqual(total, e.pos());
        try testing.expectEqual(cut, e.outPos());
        try testing.expectEqual(0, e.remaining());
    }
    m.seek(cut);
    m.delete(total - cut);

    // What the column kept is the prefix before the boundary, row for row.
    try testing.expectEqual(cut, col.len());
    try expectSound(T, E, &col);
    try expectModel(T, E, &col, &m);
    // And it answers a prefix sum over that prefix from inside a slab, not
    // only its grand total: the bases were rebuilt for the slabs that
    // survived rather than carried over from the ones that went.
    const mid = cut / 2;
    try testing.expectEqual(try sumOf(T, m.built.items[0..mid]), try col.runningAt(mid));
}

test "the cursor is forward-only and refuses a position past the end" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);
    var col = try column.Column(T, E).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3, 4, 5, 6 });

    try testing.expectError(
        error.InvalidValue,
        Edit(T, E).init(col.allocator(), &col, col.len() + 1),
    );

    var e = try Edit(T, E).init(col.allocator(), &col, 3);
    defer e.deinit();
    _ = try e.advance(2);
    try testing.expectEqual(5, e.pos());
    try testing.expectError(error.InvalidValue, e.seek(4));
    try testing.expectError(error.InvalidValue, e.seek(0));
    // The refused seeks moved nothing.
    try testing.expectEqual(5, e.pos());
    // A delete past the end takes what is there and stops, rather than
    // running the cursor past items that never existed.
    _ = try e.delete(10);
    try e.finish();
    try testing.expectEqual(0, e.remaining());
    try expectSound(T, E, &col);
    try testing.expectEqual(5, col.len());
}

test "inserts and deletes at the ends of the column, and into an empty one" {
    const gpa = testing.allocator;
    const T = u64;
    const E = column.Rle(u64);

    {
        var col = try column.Column(T, E).init(gpa);
        defer col.deinit();
        {
            var e = try Edit(T, E).init(col.allocator(), &col, 0);
            defer e.deinit();
            _ = try e.insertRun(9, 5);
            try e.finish();
        }
        try expectSound(T, E, &col);
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(T, &.{ 9, 9, 9, 9, 9 }, got);
    }

    // A cursor opened at the end of a column appends to its last slab
    // rather than starting one of its own (`edit.rs:172-175`).
    var col = try column.Column(T, E).init(gpa);
    defer col.deinit();
    try col.extend(gpa, &.{ 1, 2, 3 });
    const slabs_before = col.slabCount();
    {
        var e = try Edit(T, E).init(col.allocator(), &col, col.len());
        defer e.deinit();
        // Opening a cursor must not restructure the column: the cursor stands
        // in the last slab, so the insert appends to it.
        try testing.expectEqual(slabs_before, e.column().slabCount());
        _ = try e.insertRun(4, 3);
        try e.finish();
    }
    try expectSound(T, E, &col);
    try testing.expectEqual(slabs_before, col.slabCount());
    const got = try col.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(T, &.{ 1, 2, 3, 4, 4, 4 }, got);
}

test "every codec the cursor serves edits through it" {
    try exerciseOneSlabBatch(i64, column.Rle(i64));
    try exerciseOneSlabBatch(u32, column.Rle(u32));
    try exerciseOneSlabBatch(?u32, column.RleOption(u32));
    try exerciseOneSlabBatch(u32, column.Prefix(u32));
    try exerciseOneSlabBatch(?u32, column.Prefix(?u32));
    try exerciseOneSlabBatch(bool, column.Bool);
}

/// Exact values through both the sequential reader and the positional index,
/// plus every prefix boundary for a codec that keeps prefix weights.
fn expectWritebackValues(comptime E: type, col: *const column.Column(u64, E), want: []const u64) !void {
    try expectSound(u64, E, col);
    const got = try col.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(want.len, col.len());
    try testing.expectEqualSlices(u64, want, got);
    var running: i64 = 0;
    for (want, 0..) |value, i| {
        try testing.expectEqual(@as(?u64, value), try col.get(i));
        if (comptime E.tracks_prefix) {
            try testing.expectEqual(running, try col.runningAt(i));
            running += @intCast(value);
        }
    }
    try testing.expectEqual(@as(?u64, null), try col.get(want.len));
    if (comptime E.tracks_prefix) try testing.expectEqual(running, try col.runningAt(want.len));
}

/// Refuses successive allocation points of the same held write-back, then
/// lets it land. Setup and the invariant checks run with refusals disarmed.
fn sweepFinish(comptime E: type, orig: []const u64, at: usize, ins: []const u64) !usize {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var col = try column.Column(u64, E).initWithBudget(gpa, 4);
    defer col.deinit();
    try col.extend(gpa, orig);
    try expectWritebackValues(E, &col, orig);
    const before = try col.encode(testing.allocator);
    defer testing.allocator.free(before);

    var want: std.ArrayList(u64) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, orig[0..at]);
    try want.appendSlice(testing.allocator, ins);
    try want.appendSlice(testing.allocator, orig[at..]);

    var e = try Edit(u64, E).init(gpa, &col, at);
    defer e.deinit();
    for (ins) |value| _ = try e.insert(value);
    const next: ?u64 = if (at < orig.len) orig[at] else null;
    try testing.expect(e.isOpen());
    try testing.expect(e.column() == &col);
    try testing.expectEqual(0, e.rebuilds());
    try testing.expectEqual(0, e.indexWrites());
    try testing.expectEqual(at, e.pos());
    try testing.expectEqual(at + ins.len, e.outPos());
    try testing.expectEqual(orig.len - at, e.remaining());
    try testing.expectEqual(next, try e.peek());
    try expectWritebackValues(E, &col, orig);

    var held: usize = 0;
    while (true) {
        failing.fail_index = failing.alloc_index + held;
        const outcome = e.finish();
        // FailingAllocator does not advance alloc_index on a refusal, so it
        // keeps refusing until disarmed. An invariant check allocates through
        // the column's allocator too; leaving it armed would turn that check
        // or the retry into another OOM, not evidence about the write-back.
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            break;
        } else |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            // The caller still owns the cursor and its batch. Neither the
            // dual positions nor either write counter may claim a commit.
            try testing.expect(e.isOpen());
            try testing.expect(e.column() == &col);
            try testing.expectEqual(0, e.rebuilds());
            try testing.expectEqual(0, e.indexWrites());
            try testing.expectEqual(at, e.pos());
            try testing.expectEqual(at + ins.len, e.outPos());
            try testing.expectEqual(orig.len - at, e.remaining());
            try testing.expectEqual(next, try e.peek());
            try expectWritebackValues(E, &col, orig);
            const refused = try col.encode(testing.allocator);
            defer testing.allocator.free(refused);
            try testing.expectEqualSlices(u8, before, refused);
            held += 1;
            // Bound a broken retry loop rather than hanging the test.
            if (held > 256) return error.Fail;
        }
    }

    // The same cursor commits the entire batch once the allocator permits it.
    try testing.expect(!e.isOpen());
    try testing.expect(e.column() == &col);
    try testing.expectEqual(1, e.rebuilds());
    try testing.expectEqual(1, e.indexWrites());
    try testing.expectEqual(at, e.pos());
    try testing.expectEqual(at + ins.len, e.outPos());
    try testing.expectEqual(orig.len - at, e.remaining());
    try testing.expectEqual(next, try e.peek());
    try expectWritebackValues(E, &col, want.items);
    // A further finish must not insert the batch a second time.
    try e.finish();
    try testing.expectEqual(1, e.rebuilds());
    try testing.expectEqual(1, e.indexWrites());
    try expectWritebackValues(E, &col, want.items);
    return held;
}

test "a refused write-back leaves the batch open, owed, and retryable" {
    // A cursor marked clean before staging loses its batch on the first
    // refusal: the retry returns without publishing what it still owes.
    // Refuse only finish, and disarm before checking or retrying. Otherwise
    // an OOM in the check itself can hide the refusal this test must observe.
    // The cut is inside a run and at a run boundary. Following slabs also
    // have to retain their positional index and, for Prefix, their bases.
    const orig = [_]u64{
        1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4,
        5, 5, 5, 6, 6, 6, 7, 7, 7, 8, 8, 8,
    };
    const ins = [_]u64{ 9, 9, 9, 9, 9, 9, 9 };
    for ([_]usize{ 2, 9 }) |at| {
        try testing.expect(try sweepFinish(column.Rle(u64), &orig, at, &ins) != 0);
        try testing.expect(try sweepFinish(column.Prefix(u64), &orig, at, &ins) != 0);
    }
}

test "finishing an unchanged cursor succeeds while allocations are refused" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    const E = column.Prefix(u64);
    const orig = [_]u64{ 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4 };
    var col = try column.Column(u64, E).initWithBudget(gpa, 4);
    defer col.deinit();
    try col.extend(gpa, &orig);
    var e = try Edit(u64, E).init(gpa, &col, 0);
    defer e.deinit();

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (orig) |_| _ = try e.replace(same(u64));
    try e.finish();
    try testing.expect(!e.isOpen());
    try testing.expect(e.column() == &col);
    try testing.expectEqual(0, e.rebuilds());
    try testing.expectEqual(0, e.indexWrites());
    try testing.expectEqual(orig.len, e.pos());
    try testing.expectEqual(orig.len, e.outPos());
    try testing.expectEqual(0, e.remaining());

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try expectWritebackValues(E, &col, &orig);
}
