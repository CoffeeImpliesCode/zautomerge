//! The byte arena: a column of opaque bytes with O(log S) random splices
//! (`rust/hexane/src/raw.rs`).
//!
//! A [`RawColumn`] is conceptually a giant `Vec<u8>` whose slabs are found by
//! a Fenwick tree over their byte lengths. Unlike [`Column`](column.zig) it
//! stores no per-item encoding: the bytes spliced in are the bytes that come
//! out (`raw.rs:3-7`).
//!
//! # The column does not know where values begin
//!
//! That belongs to the caller, typically a paired `PrefixColumn` of lengths
//! whose running sums give byte offsets into this arena. What the column *does*
//! guarantee is that every splice point is a potential slab boundary and that
//! splits only ever happen at a splice point (`raw.rs:9-15`). As long as
//! callers splice at value boundaries no value ever crosses a slab, which is
//! what makes the zero-copy `get` safe: a range that would cross a boundary is
//! a caller mistake, and it is a refusal here rather than a copy
//! (`raw.rs:382-405`).
//!
//! # Import route and the shortest sequence that works
//!
//! `@import("hexane/raw.zig")`, or `zautomerge.hexane.raw` through the root
//! module. Zig 0.16.0.
//!
//! ```zig
//! var col = try RawColumn.init(gpa);   // an empty arena
//! defer col.deinit();
//! try col.spliceSlice(0, 0, "hello");
//! const out = try col.encode(gpa);      // the caller frees this
//! defer gpa.free(out);
//! ```
//!
//! # What it deliberately does not do
//!
//! It does not know where values begin, and it does not copy them out. A
//! caller that has to keep a value past the next edit copies it itself — the
//! rule [`RawColumn.get`] states is the same one [`RawColumn.slabAt`] and
//! [`RawColumnIter.take`] carry.
//!
//! # A standalone column, not a `Column(T, E)`
//!
//! Upstream this type is a peer of `Column`, not an encoding for it, and
//! `automerge` instantiates it directly for the op `value` column
//! (`op_set2/columns.rs:31`, `:74`). It cannot be a `Column(T, E)` here
//! either: that machinery decodes and re-encodes runs, and an arena has no
//! runs — the splices are over bytes, and the value boundaries live in the
//! caller. So the public surface mirrors its siblings' *shape* — `init`,
//! `deinit`, `len`, `isEmpty`, `slabCount`, `slabAt`, `spliceSlice`, `encode`,
//! `load`, `get`, `iterator` — with the run machinery left out. `save`
//! upstream is `encode` here, the name `column.zig` gives the same operation.
//!
//! # Canonical form
//!
//! **The RLE canonical rule does not apply here, and applying it would be a
//! bug, not a strictness.** For the run-length codecs canonical form means
//! adjacent runs carrying the same value must be one run
//! (`rle/decoder.rs:438-497`); the boolean codec is the standing example of
//! what happens when that rule is carried over to an encoding whose runs
//! carry no value (`docs/STATUS.md` defect 3). An arena's canonical form is a
//! *layout* rule, not an equality rule: adjacent slabs may hold identical
//! bytes and stay split, and what has to hold is
//!
//!  1. no slab is empty — a delete can empty one, and an empty slab weighs
//!     nothing in the tree yet is not transparent to a sequential reader, so
//!     it is never built: a splice stages its replacement buffers first, and
//!     a buffer with no bytes in it is not one of them
//!     (`raw.rs:242-249`);
//!  2. `total_len` is the sum of the slab lengths (`raw.rs:234-237`);
//!  3. the Fenwick tree describes the slabs it indexes, node for node;
//!  4. and the coalescing rule holds where a splice can reach: two neighbours
//!     are merged when either is under a quarter of the budget and the two
//!     together still fit in it (`try_merge_pair`, `raw.rs:284`).
//!
//! Rules 1 to 3 are [`RawColumn.checkInvariants`]. Rule 4 is
//! [`RawColumn.canMerge`] — the rule is applied to the *boundaries around a
//! splice*, never globally (`try_merge_range_skeleton`, `column.rs:185-229`),
//! so it is a predicate to ask rather than a postcondition to assert.
//!
//! # The wire form
//!
//! `encode` is the concatenation of the slabs, so the layout is not part of
//! the file format: a load accepts any byte string, and puts all of it in one
//! slab, leaving the caller to splice further if it wants splits
//! (`raw.rs:460-483`). That is why a load has nothing to validate, and why
//! there is no `canonicalSlab` to write here.

const std = @import("std");
const err = @import("../error.zig");
const indexmod = @import("index.zig");

const ParseError = err.ParseError;

/// The default per-slab byte budget (`raw.rs:30`).
///
/// Chosen empirically upstream: on a random-insert workload 4 KiB sits at the
/// bottom of a shallow plateau running from ~3 KiB to ~5 KiB — about 5× faster
/// than 64 KiB and 2× faster than 1 KiB (`raw.rs:24-29`). The budget is a
/// target, not a cap: a single blob wider than it lives in an oversize slab
/// of its own, because it cannot be cut anywhere the arena knows to be a value
/// boundary (`raw.rs:47-49`, `:526-532`).
pub const default_max_segments: usize = 4096;

/// A half-open byte range, which is what `get` takes and `saveTo` reports.
pub const Range = struct {
    /// The first byte.
    start: usize,
    /// One past the last byte.
    end: usize,

    /// The range that spans everything.
    pub const all: Range = .{ .start = 0, .end = std.math.maxInt(usize) };
};

/// One point of a multi-point `copyRanges`: at destination byte `pos` in
/// pre-merge coordinates, delete `delete` bytes and insert the source bytes
/// `range` (`Splice`, `column.rs:701-724`).
///
/// The default is *all of the source, inserted at the front, deleting
/// nothing*: source ranges are clamped to the source's length, so `all` is the
/// whole source. Copying a whole column onto the end of another is then
/// `.{ .pos = dst.len() }`.
pub const Splice = struct {
    /// The destination byte the edit lands at.
    pos: usize = 0,
    /// How many destination bytes it removes.
    delete: usize = 0,
    /// The source bytes it inserts.
    range: Range = .all,
};

/// One slab of the arena: a run of bytes with nothing above them
/// (`RawSlab`, `raw.rs:32-34`).
///
/// Upstream's slab is a `Vec<u8>` and nothing else, and so is this one. The
/// port's `slab.zig` `Slab` carries a run count and a tail because its slabs
/// are run sequences; an arena slab is one opaque blob, and a run count
/// nothing in this file could maintain would be a number with no meaning.
pub const RawSlab = struct {
    /// The slab's bytes, owned by the slab even when empty. A merge reallocs
    /// them, so they are always the allocator's memory and never a static
    /// empty slice.
    data: []u8,

    /// Frees the slab's bytes.
    pub fn deinit(self: *RawSlab, gpa: std.mem.Allocator) void {
        if (self.data.len != 0) gpa.free(self.data);
        self.* = undefined;
    }
};

/// The weight `Fenwick.rebuildFrom` reads off a slab: its byte length, which
/// is also its item count (`column.rs:144-146`).
fn slabBytes(col: *const RawColumn, i: usize) indexmod.Bytes {
    return .{ .n = col.slabs.items[i].data.len };
}

/// The weight of the one slab a load produces.
fn onlySlabBytes(col: *const RawColumn, _: usize) indexmod.Bytes {
    return .{ .n = col.slabs.items[0].data.len };
}

/// A byte arena with O(log S) random splices at any byte offset.
///
/// Not a `Column(T, E)` codec; see the module docs. The allocator is stored
/// rather than passed because the tree and the slab list are reallocated on
/// nearly every mutation, and threading one through every method would put it
/// in the signature of methods that do not otherwise allocate — `len`,
/// `isEmpty`, `slabAt` (`column.zig:1148-1170` has the same shape).
pub const RawColumn = struct {
    const Self = @This();

    /// The allocator the arena was built with, and the only one it uses.
    ///
    /// Every buffer an arena owns comes from it and goes back to it:
    /// `spliceSlice`, `spliceChunks`, `copyRanges`, and `stageSpliceSlice`
    /// allocate with it. `deinit` and publication release with it.
    /// No mutating method takes an allocator,
    /// so there is no way to hand this arena a slab one allocator made and
    /// another frees. The allocator itself is not owned and is not released by
    /// `deinit`; the methods that hand *caller-owned* memory back — `encode`,
    /// `saveTo` — still take the caller's, because that memory is the
    /// caller's to free.
    gpa: std.mem.Allocator,
    /// The slabs, in byte order. Concatenating their `data` is the wire form.
    slabs: std.ArrayList(RawSlab),
    /// A Fenwick tree over the slab byte lengths, one-indexed
    /// (`raw.rs:43-45`). It is the only index: the slab lengths *are* the
    /// weights, so there is no cache beside it.
    bit: indexmod.Fenwick(indexmod.Bytes),
    /// The total byte length, kept in step with the slabs so `len` is O(1)
    /// (`raw.rs:46`).
    total_len: usize,
    /// The per-slab byte budget (`raw.rs:47-49`).
    max_segments: usize,

    /// An empty arena with the default slab budget (`new`, `raw.rs:59-61`).
    pub fn init(gpa: std.mem.Allocator) ParseError!Self {
        return Self.withMaxSegments(gpa, default_max_segments);
    }

    /// An empty arena with a per-slab byte budget of `max_segments`
    /// (`with_max_segments`, `raw.rs:63-71`).
    ///
    /// A budget of zero is refused: no slab could ever be over it, so the
    /// arena would fragment to one slab per splice point. Upstream asserts
    /// the same thing on the way in (`raw.rs:64`).
    pub fn withMaxSegments(gpa: std.mem.Allocator, max_segments: usize) ParseError!Self {
        if (max_segments == 0) return error.InvalidValue;
        return .{
            .gpa = gpa,
            .slabs = .empty,
            .bit = try indexmod.Fenwick(indexmod.Bytes).init(gpa),
            .total_len = 0,
            .max_segments = max_segments,
        };
    }

    /// Frees every slab and the tree. The allocator came from `init`,
    /// `withMaxSegments`, `load` or `loadWithMaxSegments` and is **not**
    /// released: `deinit` returns the arena's own memory to it and leaves the
    /// allocator alone. Exactly one `deinit` per arena; a copy of an arena is
    /// a second owner of the same buffers, so releasing both is a double
    /// free.
    pub fn deinit(self: *Self) void {
        for (self.slabs.items) |*s| s.deinit(self.gpa);
        self.slabs.deinit(self.gpa);
        self.bit.deinit();
        self.* = undefined;
    }

    /// How many bytes the arena holds.
    pub fn len(self: *const Self) usize {
        return self.total_len;
    }

    /// Whether the arena holds no bytes.
    pub fn isEmpty(self: *const Self) bool {
        return self.total_len == 0;
    }

    /// How many slabs the bytes are spread over.
    pub fn slabCount(self: *const Self) usize {
        return self.slabs.items.len;
    }

    /// The slab at `index`, for a caller that walks the layout.
    ///
    /// The pointer is into this arena's slab list: `spliceSlice`,
    /// `spliceChunks` and `copyRanges` move that list, and `deinit` frees it,
    /// so **a slab from here is valid until the next mutation** — the same
    /// rule [`get`] states for a byte range, and the same one
    /// [`RawColumnIter.take`] carries for a read.
    pub fn slabAt(self: *const Self, index: usize) ?*const RawSlab {
        if (index >= self.slabs.items.len) return null;
        return &self.slabs.items[index];
    }

    /// The per-slab byte budget this arena was built with.
    pub fn maxSegments(self: *const Self) usize {
        return self.max_segments;
    }

    // ── Splice ──────────────────────────────────────────────────────────

    /// Replaces the bytes `index..index + del` with `bytes`
    /// (`try_splice_slice`, `raw.rs:145-261`).
    ///
    /// This is [`stageSpliceSlice`] followed by [`StagedSlice.publish`], and
    /// it is the shape a caller with one edit and nothing to coordinate wants.
    /// A caller writing several columns, or several edits that have to land
    /// together, stages each one and publishes them all at the end; see
    /// [`StagedSlice`].
    ///
    /// `index + del` past the end is `error.InvalidValue`, matching the
    /// out-of-bounds check upstream makes before it touches anything
    /// (`raw.rs:151-160`).
    pub fn spliceSlice(self: *Self, index: usize, del: usize, bytes: []const u8) ParseError!void {
        var staged = try self.stageSpliceSlice(index, del, bytes);
        defer staged.deinit();
        staged.publish(self);
    }

    /// Plans the edit that replaces the bytes `index..index + del` with
    /// `bytes`, and takes every allocation it will need (`try_splice_slice`,
    /// `raw.rs:145-261`).
    ///
    /// **The receiver is not touched.** On every path, including every
    /// `error`, the slabs, their bytes, the length and the tree are exactly
    /// as the call found them and [`checkInvariants`] still holds. The one
    /// thing staging may change is the *spare capacity* of the slab list and
    /// of the tree, which is what makes [`StagedSlice.publish`] unable to
    /// fail; capacity is not observable through any answer this type gives.
    ///
    /// **The allocator is the arena's own, not a parameter**, so a staged edit
    /// comes out of exactly the allocator [`deinit`] releases it with and
    /// there is no way to name a second one.
    ///
    /// Rebuilds only the touched slabs and the neighbours absorbed by the
    /// coalescing policy. Plans their lengths first, then copies each final
    /// replacement buffer once. Untouched buffers remain borrowed.
    ///
    /// `index + del` past the end is `error.InvalidValue`, matching the
    /// out-of-bounds check upstream makes before it touches anything
    /// (`raw.rs:151-160`). A `del` of zero together with an empty `bytes` plans
    /// a no-op, and publishing it does nothing.
    pub fn stageSpliceSlice(
        self: *Self,
        index: usize,
        del: usize,
        bytes: []const u8,
    ) ParseError!StagedSlice {
        const gpa = self.gpa;
        if (index > self.total_len or del > self.total_len - index) return error.InvalidValue;

        var staged: StagedSlice = .{
            .owner = self,
            .at = 0,
            .drop = 0,
            .slots = undefined,
            .len = 0,
            .new_total = self.total_len,
            .old_weight = indexmod.Bytes.zero,
            .count_before = self.slabs.items.len,
            .spent = false,
        };
        // A refusal anywhere below hands back the buffers this call already
        // built, and the receiver is untouched because nothing was written.
        errdefer staged.deinit();

        if (del == 0 and bytes.len == 0) return staged;

        const count_before = staged.count_before;
        const start: indexmod.SlabPos = if (count_before == 0)
            .{ .slab = 0, .offset = 0 }
        else
            self.findSlab(index);
        const first_len = if (count_before == 0) 0 else self.slabs.items[start.slab].data.len;
        const local_del = @min(del, first_len - start.offset);
        staged.new_total = std.math.add(usize, self.total_len - del, bytes.len) catch return error.Overflow;

        // Ranges use the edited arena's byte coordinates. Split only at the
        // splice points; an oversize value is never split through its bytes.
        var plans: [max_staged_slabs]Range = undefined;
        var plan_count: usize = 0;
        var output_at = index - start.offset;
        const first_new_len = std.math.add(usize, first_len - local_del, bytes.len) catch return error.Overflow;
        self.planSlab(&plans, &plan_count, &output_at, first_new_len, start.offset, bytes.len);

        var next = if (count_before == 0) 0 else start.slab + 1;
        var remaining = del - local_del;
        while (remaining > 0) {
            const slab_len = self.slabs.items[next].data.len;
            if (remaining >= slab_len) {
                remaining -= slab_len;
            } else {
                self.planSlab(&plans, &plan_count, &output_at, slab_len - remaining, 0, 0);
                remaining = 0;
            }
            next += 1;
        }
        staged.at = start.slab;
        staged.drop = next - start.slab;

        // Same boundary order as try_merge_range_skeleton
        // (rust/hexane/src/column.rs:185-229). No buffers exist yet.
        if (plan_count >= 3) {
            _ = self.mergePlans(&plans, &plan_count, plan_count - 3);
        }
        if (plan_count >= 2) {
            _ = self.mergePlans(&plans, &plan_count, plan_count - 2);
        }
        while (plan_count > 0 and next < count_before) {
            const last = &plans[plan_count - 1];
            const neighbour_len = self.slabs.items[next].data.len;
            if (!self.canMerge(last.end - last.start, neighbour_len)) break;
            last.end += neighbour_len;
            next += 1;
            staged.drop += 1;
        }
        if (plan_count >= 2) {
            _ = self.mergePlans(&plans, &plan_count, 0);
        }
        while (plan_count > 0 and staged.at > 0) {
            const first = &plans[0];
            const neighbour_len = self.slabs.items[staged.at - 1].data.len;
            if (!self.canMerge(neighbour_len, first.end - first.start)) break;
            first.start -= neighbour_len;
            staged.at -= 1;
            staged.drop += 1;
        }

        for (plans[0..plan_count]) |range| {
            const buffer = try gpa.alloc(u8, range.end - range.start);
            self.copySplicedRange(buffer, range, index, del, bytes);
            staged.put(.{ .data = buffer });
        }
        if (staged.drop > 0) staged.old_weight = .{ .n = self.slabs.items[staged.at].data.len };
        const new_count = count_before - staged.drop + staged.len;
        try self.slabs.ensureTotalCapacity(gpa, new_count);
        try self.bit.items.ensureTotalCapacity(gpa, new_count + 1);
        return staged;
    }

    /// An edit an arena has planned but not yet applied.
    ///
    /// It owns the replacement buffers and it borrows the arena it was planned
    /// against: **the arena must outlive the staged edit**, and
    /// [`publish`](RawColumn.StagedSlice.publish) takes that same arena and no
    /// other.
    ///
    /// The whole shape is the contract. `publish` is infallible and consumes,
    /// so every allocation the hand-over needs is taken by
    /// [`stageSpliceSlice`](RawColumn.stageSpliceSlice) instead; `deinit` is
    /// the abort and is a no-op once a publish has run, so the safe pattern is
    ///
    /// ```zig
    /// var staged = try col.stageSpliceSlice(index, del, bytes);
    /// defer staged.deinit();      // the abort; a no-op once published
    /// // ... stage the other columns ...
    /// staged.publish(col);         // cannot fail
    /// ```
    ///
    /// Staging every write before publishing any of them is what makes a group
    /// of edits all-or-nothing: the only failure left to see happens before
    /// the first byte of any column has moved.
    pub const StagedSlice = struct {
        const This = @This();

        /// The arena the edit was planned against. It owns every staged buffer
        /// through its own allocator.
        owner: *RawColumn,
        /// The first old slab the edit replaces.
        at: usize,
        /// How many old slabs it replaces. Zero together with an empty `len`
        /// is a staged no-op.
        drop: usize,
        /// The buffers that replace them, in byte order. At most
        /// [`max_staged_slabs`] of them, and only the first `len` are ever
        /// read.
        slots: [max_staged_slabs]RawSlab,
        /// How many of `slots` are filled.
        len: usize,
        /// The arena's length once the edit has landed.
        new_total: usize,
        /// The old weight of the slab at `at`, which the tree's point update
        /// needs and which is only the right number when the edit replaced one
        /// slab.
        old_weight: indexmod.Bytes,
        /// The arena's slab count before the edit.
        count_before: usize,
        /// Whether `publish` or `deinit` has already taken the buffers.
        spent: bool,

        /// Applies the staged edit to `col`, which must be the arena it was
        /// staged against.
        ///
        /// **This cannot fail.** Every allocation the hand-over needs was
        /// taken by [`stageSpliceSlice`](RawColumn.stageSpliceSlice). What is
        /// left frees the replaced slabs, moves the tail, writes the staged
        /// buffers and brings the tree back in step.
        ///
        /// It consumes the edit: publishing the same staged value twice would
        /// apply it twice and is a programmer error. A staged no-op does
        /// nothing at all.
        pub fn publish(self: *This, col: *RawColumn) void {
            std.debug.assert(!self.spent);
            std.debug.assert(col == self.owner);
            self.spent = true;
            if (self.drop == 0 and self.len == 0) return;

            const gpa = col.gpa;
            const added = self.len;
            // Nothing below allocates.
            for (col.slabs.items[self.at..][0..self.drop]) |*old| old.deinit(gpa);
            // The tail moves as one block. It never reads the range just
            // released, which is why the move is here and not in
            // `replaceRangeAssumeCapacity`: that one copies forwards out of
            // the replaced range whenever the list shrinks. The destination
            // can end past `items.len` — a split that grows the range is the
            // case where it does — so it is built from the backing array,
            // whose room staging took, rather than sliced out of the list.
            if (added != self.drop) {
                const tail = col.slabs.items[self.at + self.drop ..];
                const base: [*]RawSlab = col.slabs.items.ptr + (self.at + added);
                @memmove(base[0..tail.len], tail);
            }
            col.slabs.items.len = self.count_before - self.drop + added;
            @memcpy(col.slabs.items[self.at..][0..added], self.slots[0..added]);
            self.len = 0;
            col.total_len = self.new_total;

            // A like-for-like single-slab replacement needs one weight update;
            // every other prepared layout needs a tree rebuild (raw.rs:251-258).
            if (self.drop == 1 and added == 1) {
                col.bit.pointUpdate(self.at, self.old_weight, .{ .n = col.slabs.items[self.at].data.len });
            } else {
                // Preparation reserved this exact tree before publication.
                col.bit.rebuildFrom(gpa, col, col.slabs.items.len, slabBytes) catch unreachable;
            }
        }

        /// Releases the staged buffers without applying the edit, which is
        /// the abort.
        ///
        /// **A no-op once `publish` has run**, so the `defer` beside it costs
        /// nothing on the success path and cannot double free.
        pub fn deinit(self: *This) void {
            if (self.spent) return;
            self.spent = true;
            const gpa = self.owner.gpa;
            for (self.slots[0..self.len]) |*s| s.deinit(gpa);
            self.len = 0;
        }

        fn put(self: *This, slab: RawSlab) void {
            std.debug.assert(self.len < max_staged_slabs);
            self.slots[self.len] = slab;
            self.len += 1;
        }
    };

    /// Replaces the bytes `index..index + del` with the concatenation of
    /// `chunks` (`try_splice`, `raw.rs:103-130`).
    ///
    /// The scratch buffer is allocated with the arena's own allocator, the
    /// same one the staged buffers come out of.
    ///
    /// This is the shape a caller already has per-item byte slices in — one
    /// `raw_value()` per op — and it exists so the caller does not have to
    /// concatenate them first. Zero and one chunk skip the buffer entirely,
    /// as upstream (`raw.rs:111-117`).
    ///
    /// An `error` leaves the arena as it was: the concatenation buffer is
    /// released and [`spliceSlice`] has not been reached, or has left the
    /// arena alone. `chunks` are borrowed and are never retained.
    pub fn spliceChunks(
        self: *Self,
        index: usize,
        del: usize,
        chunks: []const []const u8,
    ) ParseError!void {
        if (chunks.len <= 1) {
            return self.spliceSlice(index, del, if (chunks.len == 0) &.{} else chunks[0]);
        }
        const gpa = self.gpa;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        for (chunks) |c| try buf.appendSlice(gpa, c);
        return self.spliceSlice(index, del, buf.items);
    }

    /// Splices byte ranges of `src` into this arena at several points in one
    /// pass (`copy_ranges`, `raw.rs:321-348`).
    ///
    /// The list is normalized with the arena's own allocator, the same one
    /// the staged buffers come out of.
    ///
    /// The splices are applied back to front, so each edit lands above every
    /// one still to be applied and the positions stay valid without any shift
    /// bookkeeping. They are the *only* bulk path: raw bytes have no
    /// decode/re-encode cost, so a second one would buy nothing but a way to
    /// diverge from the single-point policy — which is what the previous
    /// implementation did, cutting the destination at every splice point and
    /// never coalescing, so a chain of small merges fragmented the arena into
    /// one slab per insertion point (`raw.rs:303-312`).
    ///
    /// **Each splice is atomic; the pass as a whole is not.** Every one of
    /// them goes through [`stageSpliceSlice`] and [`StagedSlice.publish`], so
    /// an `error` from any single splice leaves this arena exactly as that
    /// splice found it. The splices already applied stand, though: a splice's
    /// offsets are measured in the layout the splices below it leave behind,
    /// so they cannot all be planned before the first byte moves. A caller
    /// that needs the whole pass to be all-or-nothing drives
    /// [`StagedSlice`] itself over offsets it has already resolved, which is
    /// what a caller writing several columns wants and what no bookkeeping
    /// here can do for it.
    ///
    /// `src` must not be this arena: the source's slabs are read while the
    /// destination's are being rewritten.
    ///
    /// `pos` and `delete` are in this arena's pre-merge coordinates and must
    /// ascend without overlapping; `range` is a byte range of `src` that does
    /// the same (`raw.rs:298-301`). Every endpoint must be on a value
    /// boundary, or a value will end up spanning a slab.
    pub fn copyRanges(
        self: *Self,
        src: *const RawColumn,
        splices_in: []const Splice,
    ) ParseError!void {
        const gpa = self.gpa;
        const splices = try normalizeSplices(gpa, splices_in, src.len(), self.total_len);
        defer gpa.free(splices);
        var k = splices.len;
        while (k > 0) {
            k -= 1;
            const sp = splices[k];
            var at = sp.pos;
            var del = sp.delete;
            // Chunked by the source's own slabs. A payload spliced as one
            // slice wider than the slab budget cannot be split anywhere the
            // arena knows to be a value boundary, so it would land as a
            // single oversize slab that every later splice has to memmove
            // whole; the source's slabs are already budgeted and already cut
            // at value boundaries (`raw.rs:334-341`).
            var chunks = src.chunksIn(sp.range.start, sp.range.end);
            while (chunks.next()) |chunk| {
                var staged = try self.stageSpliceSlice(at, del, chunk);
                staged.publish(self);
                at += chunk.len;
                del = 0;
            }
            if (del > 0) {
                // A pure delete, or one whose splice inserted nothing.
                var staged = try self.stageSpliceSlice(at, del, &.{});
                staged.publish(self);
            }
        }
    }

    // ── Range read ──────────────────────────────────────────────────────

    /// The bytes `start..end`, borrowed from the slab that holds them
    /// (`try_get`, `raw.rs:382-405`). The slice is valid until the next
    /// mutation.
    ///
    /// A range that leaves the arena, or that would cross a slab boundary, is
    /// `error.InvalidValue`. The second case is the caller's own contract
    /// being broken: the arena is only allowed to cut at splice points, so a
    /// crossing range means the caller spliced in the middle of a value.
    pub fn get(self: *const Self, start: usize, end: usize) ParseError![]const u8 {
        if (end > self.total_len or start > end) return error.InvalidValue;
        if (start == end) return &.{};
        const pos = self.bit.findSlab(start);
        const data = self.slabs.items[pos.slab].data;
        const span = end - start;
        if (pos.offset + span > data.len) return error.InvalidValue;
        return data[pos.offset..][0..span];
    }

    /// A sequential reader starting at byte 0 (`iter`, `raw.rs:410-417`).
    pub fn iterator(self: *const Self) RawColumnIter {
        return .{ .col = self, .slab_idx = 0, .offset_in_slab = 0, .byte_pos = 0 };
    }

    /// A sequential reader positioned at byte `pos` (`iter_at`,
    /// `raw.rs:421-442`). O(log S) to place. `pos` past the end is
    /// `error.InvalidValue`; `pos == len()` is a reader that has run out.
    pub fn iteratorAt(self: *const Self, pos: usize) ParseError!RawColumnIter {
        if (pos > self.total_len) return error.InvalidValue;
        if (pos == 0 or self.slabs.items.len == 0) return self.iterator();
        if (pos == self.total_len) {
            // One past the end of the last slab.
            return .{ .col = self, .slab_idx = self.slabs.items.len, .offset_in_slab = 0, .byte_pos = pos };
        }
        const at = self.bit.findSlab(pos);
        return .{ .col = self, .slab_idx = at.slab, .offset_in_slab = at.offset, .byte_pos = pos };
    }

    // ── Wire form ───────────────────────────────────────────────────────

    /// The arena's wire form: every slab's bytes in order (`save`,
    /// `raw.rs:446-450`). The caller owns the slice.
    pub fn encode(self: *const Self, gpa: std.mem.Allocator) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        _ = try self.saveTo(gpa, &out);
        return out.toOwnedSlice(gpa);
    }

    /// Appends the wire form to `out` and reports where it landed
    /// (`save_to`, `raw.rs:452-458`).
    pub fn saveTo(
        self: *const Self,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) ParseError!Range {
        const start = out.items.len;
        try out.ensureUnusedCapacity(gpa, self.total_len);
        for (self.slabs.items) |s| out.appendSliceAssumeCapacity(s.data);
        return .{ .start = start, .end = out.items.len };
    }

    /// An arena over `data` (`load`, `raw.rs:463-466`).
    pub fn load(gpa: std.mem.Allocator, data: []const u8) ParseError!Self {
        return Self.loadWithMaxSegments(gpa, data, default_max_segments);
    }

    /// An arena over `data`, with a per-slab byte budget of `max_segments`
    /// (`load_with_max_segments`, `raw.rs:468-484`).
    ///
    /// Everything lands in one slab: the caller knows where the value
    /// boundaries are and can splice further if it wants splits
    /// (`raw.rs:460-462`). A load therefore has no malformed input to refuse
    /// — every byte string is a valid arena — and no canonical form to check.
    pub fn loadWithMaxSegments(
        gpa: std.mem.Allocator,
        data: []const u8,
        max_segments: usize,
    ) ParseError!Self {
        var self = try Self.withMaxSegments(gpa, max_segments);
        errdefer self.deinit();
        if (data.len == 0) return self;
        try self.slabs.append(gpa, .{ .data = try gpa.dupe(u8, data) });
        self.total_len = data.len;
        try self.bit.rebuildFrom(gpa, &self, 1, onlySlabBytes);
        return self;
    }

    // ── The layout rule ────────────────────────────────────────────────

    /// Whether two neighbouring slabs of these lengths are coalesced into one
    /// by the arena's policy: either one is under a quarter of the budget,
    /// and the two together still fit in it (`try_merge_pair`, `raw.rs:284`).
    ///
    /// This is the arena's canonical-coalescing rule, and it is about *sizes*
    /// and not about values: two adjacent slabs holding identical bytes stay
    /// split. The rule applies only at the splice's prepared boundaries,
    /// never globally.
    pub fn canMerge(self: *const Self, a_len: usize, b_len: usize) bool {
        const min = self.max_segments / 4;
        return (a_len < min or b_len < min) and a_len + b_len <= self.max_segments;
    }

    /// Whether the layout is canonical — the three postconditions the module
    /// docs list: no empty slab, the total agrees with the slabs, and the tree
    /// describes the slabs node for node.
    ///
    /// Upstream asserts the total with a `debug_assert_eq` and asserts the
    /// tree is in step in one of its own tests (`raw.rs:234-237`, `:978-983`).
    /// This makes both a callable check, and it is total: it rebuilds the tree
    /// from the slabs and compares, so it cannot read out of bounds however the
    /// arena was built.
    pub fn checkInvariants(self: *const Self, gpa: std.mem.Allocator) ParseError!void {
        var sum: usize = 0;
        for (self.slabs.items) |s| {
            // An empty slab is the one a delete leaves behind; it is dropped
            // by the splice that made it (`raw.rs:247-248`).
            if (s.data.len == 0) return error.InvalidValue;
            sum = std.math.add(usize, sum, s.data.len) catch return error.Overflow;
        }
        if (sum != self.total_len) return error.InvalidValue;
        if (self.bit.len() != self.slabs.items.len) return error.InvalidValue;
        var fresh = try indexmod.Fenwick(indexmod.Bytes).init(gpa);
        defer fresh.deinit();
        try fresh.rebuildFrom(gpa, self, self.slabs.items.len, slabBytes);
        if (fresh.items.items.len != self.bit.items.items.len) return error.InvalidValue;
        for (fresh.items.items, self.bit.items.items) |want, got| {
            if (!indexmod.Bytes.Aggregate.eql(want, got)) return error.InvalidValue;
        }
    }

    // ── Internals ──────────────────────────────────────────────────────

    /// The slab holding byte `index`, and that byte's offset inside it
    /// (`find_slab`, `raw.rs:263-271`).
    ///
    /// A byte at the very end lands in the last slab at its end, so an append
    /// goes into the slab already there instead of starting one.
    fn findSlab(self: *const Self, index: usize) indexmod.SlabPos {
        if (index == self.total_len) {
            const last = self.slabs.items.len - 1;
            return .{ .slab = last, .offset = self.slabs.items[last].data.len };
        }
        return self.bit.findSlab(index);
    }

    // Record one slab's split without allocating or copying its bytes.
    fn planSlab(
        self: *const Self,
        plans: *[max_staged_slabs]Range,
        count: *usize,
        position: *usize,
        size: usize,
        prefix: usize,
        inserted: usize,
    ) void {
        if (size == 0) return;
        const split = if (size <= self.max_segments) 0 else pickSplit(prefix, inserted, size);
        const end = position.* + size;
        if (split != 0 and split != size) {
            plans[count.*] = .{ .start = position.*, .end = position.* + split };
            count.* += 1;
            position.* += split;
        }
        plans[count.*] = .{ .start = position.*, .end = end };
        count.* += 1;
        position.* = end;
    }

    fn mergePlans(self: *const Self, plans: *[max_staged_slabs]Range, count: *usize, at: usize) bool {
        const a = plans[at];
        const b = plans[at + 1];
        if (!self.canMerge(a.end - a.start, b.end - b.start)) return false;
        plans[at].end = b.end;
        @memmove(plans[at + 1 .. count.* - 1], plans[at + 2 .. count.*]);
        count.* -= 1;
        return true;
    }

    fn copySplicedRange(
        self: *const Self,
        out: []u8,
        range: Range,
        index: usize,
        del: usize,
        bytes: []const u8,
    ) void {
        var at = range.start;
        if (at < index) {
            const end = @min(range.end, index);
            self.copyOriginalRange(out[0 .. end - at], at, end);
            at = end;
            if (at == range.end) return;
        }
        const insert_end = index + bytes.len;
        if (at < insert_end) {
            const end = @min(range.end, insert_end);
            @memcpy(out[at - range.start ..][0 .. end - at], bytes[at - index .. end - index]);
            at = end;
            if (at == range.end) return;
        }
        self.copyOriginalRange(out[at - range.start ..], at - bytes.len + del, range.end - bytes.len + del);
    }

    fn copyOriginalRange(self: *const Self, out: []u8, start: usize, end: usize) void {
        var chunks = self.chunksIn(start, end);
        var written: usize = 0;
        while (chunks.next()) |chunk| {
            @memcpy(out[written..][0..chunk.len], chunk);
            written += chunk.len;
        }
        std.debug.assert(written == out.len);
    }

    /// The byte slices covering `start..end_in`, one per slab the range
    /// touches (`chunks_in`, `raw.rs:351-370`). The range is clamped to the
    /// arena, and an empty one yields nothing.
    fn chunksIn(self: *const Self, start: usize, end_in: usize) ChunksIter {
        const end = @min(end_in, self.total_len);
        var slab_idx: usize = 0;
        var offset: usize = 0;
        if (start < end) {
            const at = self.findSlab(start);
            slab_idx = at.slab;
            offset = at.offset;
        }
        return .{ .col = self, .pos = start, .end = end, .slab_idx = slab_idx, .offset = offset };
    }
};

// A touched slab splits at most once; a partial tail adds at most two plans.
// Coalescing only removes plans and absorbs neighbouring byte ranges.
const max_staged_slabs = 4;

/// The byte offset to split an overflowing slab at (`pick_split`,
/// `raw.rs:568-578`).
///
/// Two candidates, both on a splice-point boundary and so both preserving
/// "no value crosses a slab": before the inserted bytes, which leaves
/// `inserted + suffix` on the right, and after them, which leaves the suffix.
/// Whichever is more balanced wins, and a tie prefers "before".
fn pickSplit(offset_before_insert: usize, inserted_len: usize, total_len: usize) usize {
    const before = offset_before_insert;
    const after = offset_before_insert + inserted_len;
    // `split.abs_diff(total_len - split)`: the difference between the two
    // halves the split leaves behind, not the distance from the start.
    if (absDiff(before, total_len - before) <= absDiff(after, total_len - after)) return before;
    return after;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

/// Normalizes a multi-point splice list: clamps the source ranges to
/// `src_len`, drops the no-ops, and merges contiguous neighbours
/// (`normalize_splices`, `column.rs:731-769`).
///
/// Upstream asserts that the destination regions ascend without overlapping
/// and that the source ranges do the same. Those are caller mistakes rather
/// than input, so they are refusals here. The caller owns the slice.
pub fn normalizeSplices(
    gpa: std.mem.Allocator,
    splices: []const Splice,
    src_len: usize,
    dst_len: usize,
) ParseError![]Splice {
    var out: std.ArrayList(Splice) = .empty;
    errdefer out.deinit(gpa);
    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    for (splices) |sp| {
        if (sp.pos < dst_pos) return error.InvalidValue;
        if (sp.pos > dst_len or sp.delete > dst_len - sp.pos) return error.InvalidValue;
        if (sp.range.start < src_pos) return error.InvalidValue;
        dst_pos = sp.pos + sp.delete;
        src_pos = @max(src_pos, sp.range.end);
        const start = @min(sp.range.start, src_len);
        const end = @min(sp.range.end, src_len);
        if (end == start and sp.delete == 0) continue;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.pos + last.delete == sp.pos and last.range.end == start) {
                last.delete += sp.delete;
                last.range.end = end;
                continue;
            }
        }
        try out.append(gpa, .{ .pos = sp.pos, .delete = sp.delete, .range = .{ .start = start, .end = end } });
    }
    return out.toOwnedSlice(gpa);
}

/// The byte slices covering a range of an arena, one per slab the range
/// touches (`chunks_in`, `raw.rs:351-370`).
///
/// The natural unit of reading an arena is a variable-sized blob, so this is
/// not a `next() ?T` iterator over bytes: it yields the slab-aligned pieces
/// `copyRanges` splices in, and each piece is copied whole.
///
/// The pieces are windows on the source arena's slabs, so they are valid only
/// until that arena is mutated. `copyRanges` reads them and splices each one
/// in before asking for the next.
const ChunksIter = struct {
    col: *const RawColumn,
    /// The next byte to hand out.
    pos: usize,
    /// One past the last byte of the range.
    end: usize,
    slab_idx: usize,
    offset: usize,

    /// The next slab's piece of the range, or null when it is used up.
    pub fn next(self: *ChunksIter) ?[]const u8 {
        if (self.pos >= self.end or self.slab_idx >= self.col.slabs.items.len) return null;
        const data = self.col.slabs.items[self.slab_idx].data;
        const take = @min(data.len - self.offset, self.end - self.pos);
        const out = data[self.offset..][0..take];
        self.pos += take;
        self.slab_idx += 1;
        self.offset = 0;
        return out;
    }
};

/// A sequential reader over an arena (`RawColumnIter`, `raw.rs:591-668`).
///
/// Not an iterator over bytes: the natural unit of reading here is a
/// variable-sized blob, so the reader exposes `take` and `skip` instead of
/// `next`, and the state carries across calls so consecutive reads do not
/// re-look-up the slab (`raw.rs:582-588`). It is a value: a reader costs no
/// allocation, and copies of it are independent.
///
/// **What the copies are independent of is the reader, not the arena.** A
/// reader borrows its [`RawColumn`] and every value [`take`] returns is a
/// window on one of that arena's slabs, so a value held across a
/// `spliceSlice`, `spliceChunks`, `copyRanges` or `deinit` on it reads freed
/// memory. The rule is the one [`RawColumn.get`] states, and it belongs to
/// the column, which has to outlive the reader and every value read through
/// it.
pub const RawColumnIter = struct {
    col: *const RawColumn,
    slab_idx: usize,
    offset_in_slab: usize,
    /// The absolute byte position. It is the state the other two derive
    /// from, carried so `pos` and `seekTo` are free. Named `byte_pos` because
    /// `pos` is the accessor, and Zig has no room for a field and a method of
    /// the same name.
    byte_pos: usize,

    /// The current absolute byte position, for suspending a read and resuming
    /// it with `iteratorAt` (`RawColumnIter::pos`, `raw.rs:603-607`).
    pub fn pos(self: *const RawColumnIter) usize {
        return self.byte_pos;
    }

    /// Reads the next `n` bytes and advances (`take`, `raw.rs:609-634`).
    ///
    /// The slice is borrowed from the slab it lands in and is **valid until
    /// the next mutation of the column it reads** — `spliceSlice`,
    /// `spliceChunks`, `copyRanges` or `deinit` each move or free that slab.
    /// `take` itself only moves the cursor, so two reads in a row do not
    /// invalidate each other.
    ///
    /// A read that would cross a slab boundary is `error.InvalidValue`: by the
    /// column's invariant that only happens when `n` does not describe one
    /// value, which is the caller's mistake to make. Reading zero bytes
    /// always succeeds, even at the end.
    pub fn take(self: *RawColumnIter, n: usize) ParseError![]const u8 {
        if (n == 0) return &.{};
        if (self.slab_idx >= self.col.slabs.items.len) return error.InvalidValue;
        const slab = self.col.slabs.items[self.slab_idx].data;
        const available = slab.len - self.offset_in_slab;
        if (n > available) return error.InvalidValue;
        const out = slab[self.offset_in_slab..][0..n];
        self.offset_in_slab += n;
        self.byte_pos += n;
        if (self.offset_in_slab >= slab.len and self.slab_idx + 1 < self.col.slabs.items.len) {
            self.slab_idx += 1;
            self.offset_in_slab = 0;
        }
        return out;
    }

    /// Advances the cursor by `n` bytes, crossing slab boundaries as needed
    /// (`skip`, `raw.rs:636-655`). A skip past the end is
    /// `error.InvalidValue`.
    pub fn skip(self: *RawColumnIter, n: usize) ParseError!void {
        const end = std.math.add(usize, self.byte_pos, n) catch return error.Overflow;
        if (end > self.col.total_len) return error.InvalidValue;
        self.byte_pos = end;
        var remaining = n;
        while (remaining > 0) {
            if (self.slab_idx >= self.col.slabs.items.len) return error.InvalidValue;
            const slab = self.col.slabs.items[self.slab_idx].data;
            const available = slab.len - self.offset_in_slab;
            if (remaining < available) {
                self.offset_in_slab += remaining;
                return;
            }
            remaining -= available;
            self.slab_idx += 1;
            self.offset_in_slab = 0;
        }
    }

    /// Forward-only seek to `target` (`seek_to`, `raw.rs:657-667`).
    ///
    /// Going backwards is `error.InvalidValue`, and `iteratorAt` is the way to
    /// seek arbitrarily.
    pub fn seekTo(self: *RawColumnIter, target: usize) ParseError!void {
        if (target < self.byte_pos) return error.InvalidValue;
        return self.skip(target - self.byte_pos);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Asserts the length, the bytes and the layout of an arena.
fn expectArena(col: *const RawColumn, gpa: std.mem.Allocator, want: []const u8) !void {
    try testing.expectEqual(want.len, col.len());
    const got = try col.encode(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, want, got);
    try col.checkInvariants(gpa);
}

/// Asserts that slab `i` holds exactly `want`.
fn expectSlab(col: *const RawColumn, i: usize, want: []const u8) !void {
    const s = col.slabAt(i) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, want, s.data);
}

test "an empty arena holds no bytes" {
    const gpa = testing.allocator;
    var col = try RawColumn.init(gpa);
    defer col.deinit();
    try testing.expect(col.isEmpty());
    try testing.expectEqual(@as(usize, 0), col.len());
    try expectArena(&col, gpa, &.{});
    // A budget of zero would fragment the arena to one slab per splice point.
    try testing.expectError(error.InvalidValue, RawColumn.withMaxSegments(gpa, 0));
}

test "one slab takes appends, a middle insert, a delete and a replace" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 32);
    defer col.deinit();
    try col.spliceSlice(0, 0, "hello");
    try col.spliceSlice(5, 0, ", world");
    try expectArena(&col, gpa, "hello, world");
    try testing.expectEqual(@as(usize, 1), col.slabCount());
}

test "an insert in the middle, a delete and a replace all land in one slab" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 32);
    defer col.deinit();
    try col.spliceSlice(0, 0, "helloworld");
    try col.spliceSlice(5, 0, ", ");
    try expectArena(&col, gpa, "hello, world");
    try col.spliceSlice(5, 2, "");
    try expectArena(&col, gpa, "helloworld");
    try col.spliceSlice(5, 5, "hexane");
    try expectArena(&col, gpa, "hellohexane");
}

test "chunks are concatenated, and one chunk skips the buffer" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 32);
    defer col.deinit();
    try col.spliceChunks(0, 0, &.{ "ab", "cd", "ef" });
    try expectArena(&col, gpa, "abcdef");
    try col.spliceChunks(6, 0, &.{});
    try col.spliceChunks(6, 0, &.{"gh"});
    try expectArena(&col, gpa, "abcdefgh");
    // A pure delete is a splice with no chunks at all.
    try col.spliceChunks(0, 2, &.{});
    try expectArena(&col, gpa, "cdefgh");
}

test "an insert that overflows the budget splits the slab" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 8);
    defer col.deinit();
    try col.spliceSlice(0, 0, "abcdef");
    try expectArena(&col, gpa, "abcdef");
    // "abcXYZdef" is nine bytes, so the slab has to give some up.
    try col.spliceSlice(3, 0, "XYZ");
    try expectArena(&col, gpa, "abcXYZdef");
    try testing.expectEqual(@as(usize, 2), col.slabCount());
}

test "the split falls on the side that balances the two halves" {
    const gpa = testing.allocator;
    {
        // [PPPP | X | SSSSSSSS]: before is (4, 9), after is (5, 8). After
        // balances better, so it wins (`raw.rs:731-754`).
        var col = try RawColumn.withMaxSegments(gpa, 12);
        defer col.deinit();
        try col.spliceSlice(0, 0, "PPPPSSSSSSSS");
        try col.spliceSlice(4, 0, "X");
        try expectArena(&col, gpa, "PPPPXSSSSSSSS");
        try testing.expectEqual(@as(usize, 2), col.slabCount());
        try expectSlab(&col, 0, "PPPPX");
        try expectSlab(&col, 1, "SSSSSSSS");
    }
    {
        // [PPPPPPPPP | X | S]: before is (9, 2), after is (10, 1). Before
        // balances better, so it wins (`raw.rs:756-769`).
        var col = try RawColumn.withMaxSegments(gpa, 10);
        defer col.deinit();
        try col.spliceSlice(0, 0, "PPPPPPPPPS");
        try col.spliceSlice(9, 0, "X");
        try expectArena(&col, gpa, "PPPPPPPPPXS");
        try testing.expectEqual(@as(usize, 2), col.slabCount());
        try expectSlab(&col, 0, "PPPPPPPPP");
        try expectSlab(&col, 1, "XS");
    }
}

test "a blob wider than the budget keeps a slab of its own" {
    const gpa = testing.allocator;
    // Sixteen bytes against a budget of four cannot be cut anywhere the arena
    // knows to be a value boundary, so the slab stays oversize
    // (`raw.rs:526-532`).
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "xxxxxxxxxxxxxxxx");
    try expectArena(&col, gpa, "xxxxxxxxxxxxxxxx");
    try testing.expectEqualStrings("xxxxxxxxxxxxxxxx", try col.get(0, 16));
    // And it is still editable, in the middle.
    try col.spliceSlice(8, 0, "-");
    try expectArena(&col, gpa, "xxxxxxxx-xxxxxxxx");
}

test "get answers every range inside a slab and refuses the rest" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 32);
    defer col.deinit();
    try col.spliceSlice(0, 0, "hello, world");
    try testing.expectEqualStrings("hello", try col.get(0, 5));
    try testing.expectEqualStrings("world", try col.get(7, 12));
    try testing.expectEqualStrings("hello, world", try col.get(0, 12));
    try testing.expectEqualStrings("", try col.get(5, 5));
    try testing.expectError(error.InvalidValue, col.get(0, 13));
}

test "a range that crosses a slab is refused, not copied" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "abcd");
    try col.spliceSlice(4, 0, "efgh");
    try testing.expectEqual(@as(usize, 2), col.slabCount());
    try testing.expectEqualStrings("bc", try col.get(1, 3));
    // "bcd" + "e" spans two slabs, which by the column's invariant means the
    // caller spliced inside a value.
    try testing.expectError(error.InvalidValue, col.get(2, 6));
}

test "an out of bounds splice is a refusal" {
    const gpa = testing.allocator;
    var col = try RawColumn.init(gpa);
    defer col.deinit();
    try col.spliceSlice(0, 0, "abc");
    try testing.expectError(error.InvalidValue, col.spliceSlice(5, 0, "x"));
    try testing.expectError(error.InvalidValue, col.spliceSlice(0, 10, ""));
    // The refusals changed nothing.
    try expectArena(&col, gpa, "abc");
}

test "a delete across a slab boundary drains the slabs behind it" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "aaaa");
    try col.spliceSlice(4, 0, "bbbb");
    try col.spliceSlice(8, 0, "cccc");
    try expectArena(&col, gpa, "aaaabbbbcccc");
    // Six bytes from position 3 reaches into the second slab and empties the
    // third.
    try col.spliceSlice(3, 6, "");
    try expectArena(&col, gpa, "aaaccc");
}

test "a mass delete coalesces the slabs it leaves behind" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 16);
    defer col.deinit();
    for (0..100) |i| {
        const byte = [_]u8{@as(u8, 'a') + @as(u8, @intCast(i % 26))};
        try col.spliceSlice(col.len(), 0, &byte);
    }
    try testing.expect(col.slabCount() > 1);
    const before = col.slabCount();
    try col.spliceSlice(0, col.len() - 10, "");
    try testing.expectEqual(@as(usize, 10), col.len());
    try testing.expect(col.slabCount() <= before);
    // The last ten bytes are the ones the loop wrote last, so the delete left
    // exactly those: 'a' plus (90..99) modulo 26.
    try expectArena(&col, gpa, "mnopqrstuv");
}

test "the coalescing rule is about sizes, not about the bytes" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 16);
    defer col.deinit();
    // A quarter of the budget is the threshold: 4 is not under it, 3 is.
    try testing.expect(!col.canMerge(8, 8));
    try testing.expect(col.canMerge(3, 8));
    try testing.expect(col.canMerge(8, 3));
    // Two undersized slabs whose sum is over the budget stay split.
    try testing.expect(!col.canMerge(12, 12));

    // Two slabs holding identical bytes, each under the threshold, are one
    // slab — but because of their sizes, not their contents. The RLE rule
    // ("adjacent runs carrying the same value must merge") has nothing to do
    // with this: an arena slab carries no value, it carries bytes. A budget
    // of 7 is what makes the second insert overflow at all.
    var split = try RawColumn.withMaxSegments(gpa, 7);
    defer split.deinit();
    try split.spliceSlice(0, 0, "xxxx");
    try split.spliceSlice(4, 0, "xxxx");
    try testing.expectEqual(@as(usize, 2), split.slabCount());
    try expectSlab(&split, 0, "xxxx");
    try expectSlab(&split, 1, "xxxx");
    // Deleting the second leaves one, and the two that were identical were
    // never merged into one before that.
    try split.spliceSlice(4, 4, "");
    try testing.expectEqual(@as(usize, 1), split.slabCount());
    try expectSlab(&split, 0, "xxxx");
    try expectArena(&split, gpa, "xxxx");
}

test "the layout is canonical: no empty slab, the total agrees, the tree is in step" {
    const gpa = testing.allocator;
    var col = try RawColumn.loadWithMaxSegments(gpa, "abcdef", 4);
    defer col.deinit();
    try testing.expectEqual(@as(usize, 1), col.slabCount());
    // A tiny value inserted at the front of a loaded oversize slab and then
    // removed again is what leaves an empty slab behind (`raw.rs:912-923`).
    try col.spliceSlice(0, 0, "X");
    try expectSlab(&col, 0, "X");
    try col.spliceSlice(0, 1, "");
    try expectArena(&col, gpa, "abcdef");
    try testing.expectEqualStrings("a", try col.get(0, 1));
}

test "a layout that is not canonical is refused" {
    const gpa = testing.allocator;
    {
        // A slab with no bytes in it: the one postcondition a splice can
        // break, and the reason the cleanup runs before the tree is rebuilt.
        var col = RawColumn{
            .gpa = gpa,
            .slabs = .empty,
            .bit = try indexmod.Fenwick(indexmod.Bytes).init(gpa),
            .total_len = 0,
            .max_segments = 8,
        };
        defer col.deinit();
        try col.slabs.append(gpa, .{ .data = try gpa.alloc(u8, 0) });
        try testing.expectError(error.InvalidValue, col.checkInvariants(gpa));
    }
    {
        // A total that does not match the slabs.
        var col = try RawColumn.loadWithMaxSegments(gpa, "abcdef", 8);
        defer col.deinit();
        try col.checkInvariants(gpa);
        col.total_len += 1;
        try testing.expectError(error.InvalidValue, col.checkInvariants(gpa));
    }
    {
        // A slab that grew without the index noticing: the shape a stale
        // point update leaves behind, and the one that would make every
        // later `get` answer from the wrong slab.
        var col = try RawColumn.loadWithMaxSegments(gpa, "abcdef", 8);
        defer col.deinit();
        const grown = try gpa.alloc(u8, 9);
        @memcpy(grown, "abcdefzzz");
        gpa.free(col.slabs.items[0].data);
        col.slabs.items[0].data = grown;
        col.total_len = 9;
        // The total agrees with the slabs, and the tree still says six: node
        // for node, so a node-by-node comparison is what catches it.
        try testing.expectError(error.InvalidValue, col.checkInvariants(gpa));
    }
}

test "the reader takes and skips, across slabs" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "abcd");
    try col.spliceSlice(4, 0, "efgh");
    try col.spliceSlice(8, 0, "ijkl");

    var it = col.iterator();
    try testing.expectEqual(@as(usize, 0), it.pos());
    try testing.expectEqualStrings("abcd", try it.take(4));
    try it.skip(1);
    try testing.expectEqualStrings("fgh", try it.take(3));
    try testing.expectEqual(@as(usize, 8), it.pos());
    try it.seekTo(9);
    try testing.expectEqualStrings("j", try it.take(1));
    // A read that would cross a slab is a caller mistake.
    var it2 = col.iterator();
    try testing.expectError(error.InvalidValue, it2.take(8));
    // As is a skip past the end.
    try testing.expectError(error.InvalidValue, it2.skip(100));
    // And a backwards seek, once the reader has moved: `seekTo` is
    // forward-only (`raw.rs:657-667`).
    try testing.expectError(error.InvalidValue, it.seekTo(0));
}

test "the reader seeks to a position, and past the end it stops" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "abcd");
    try col.spliceSlice(4, 0, "efgh");
    var it = try col.iteratorAt(4);
    try testing.expectEqual(@as(usize, 4), it.pos());
    try testing.expectEqualStrings("efgh", try it.take(4));
    try testing.expectError(error.InvalidValue, it.take(1));
    try testing.expectError(error.InvalidValue, col.iteratorAt(9));

    var at_end = try col.iteratorAt(col.len());
    try testing.expectEqual(@as(usize, 8), at_end.pos());
    try testing.expectEqualStrings("", try at_end.take(0));
    try testing.expectError(error.InvalidValue, at_end.take(1));
}

test "load, encode and saveTo round trip" {
    const gpa = testing.allocator;
    {
        const data = "The quick brown fox jumps over the lazy dog";
        var col = try RawColumn.load(gpa, data);
        defer col.deinit();
        try testing.expectEqual(data.len, col.len());
        try expectArena(&col, gpa, data);
        try testing.expectEqual(@as(usize, 1), col.slabCount());
    }
    {
        var col = try RawColumn.load(gpa, "");
        defer col.deinit();
        try testing.expect(col.isEmpty());
        try expectArena(&col, gpa, &.{});
    }
    {
        var col = try RawColumn.withMaxSegments(gpa, 4);
        defer col.deinit();
        try col.spliceSlice(0, 0, "abcd");
        try col.spliceSlice(4, 0, "efgh");
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, "prefix:");
        const at = try col.saveTo(gpa, &out);
        try testing.expectEqualStrings("abcdefgh", out.items[at.start..at.end]);
        try testing.expectEqualStrings("prefix:", out.items[0..at.start]);
        try testing.expectEqual(out.items.len, at.end);
    }
}

test "copyRanges applies one splice" {
    const gpa = testing.allocator;
    var dst = try RawColumn.withMaxSegments(gpa, 32);
    defer dst.deinit();
    try dst.spliceSlice(0, 0, "abcd");
    var src = try RawColumn.withMaxSegments(gpa, 32);
    defer src.deinit();
    try src.spliceSlice(0, 0, "WXYZ");

    try dst.copyRanges(&src, &.{.{ .pos = 4, .range = .{ .start = 0, .end = 4 } }});
    try expectArena(&dst, gpa, "abcdWXYZ");
}

test "copyRanges applies several ascending splices with deletes" {
    const gpa = testing.allocator;
    var dst = try RawColumn.withMaxSegments(gpa, 32);
    defer dst.deinit();
    try dst.spliceSlice(0, 0, "aaaabbbbcccc");
    var src = try RawColumn.withMaxSegments(gpa, 32);
    defer src.deinit();
    try src.spliceSlice(0, 0, "XXXXYYYY");

    try dst.copyRanges(&src, &.{
        .{ .pos = 0, .delete = 4, .range = .{ .start = 0, .end = 4 } },
        .{ .pos = 8, .delete = 4, .range = .{ .start = 4, .end = 8 } },
    });
    // Applied back to front: the edit at 8 lands first, so the edit at 0 is
    // still measured in coordinates that include the bytes it is about to
    // remove. Four bytes out, four in, twice, so the length is unchanged.
    try expectArena(&dst, gpa, "XXXXbbbbYYYY");
}

test "copyRanges skips the parts of the source no range names" {
    const gpa = testing.allocator;
    var dst = try RawColumn.withMaxSegments(gpa, 4);
    defer dst.deinit();
    try dst.spliceSlice(0, 0, "..");
    var src = try RawColumn.loadWithMaxSegments(gpa, "AAAABBBBCCCC", 4);
    defer src.deinit();

    try dst.copyRanges(&src, &.{
        .{ .pos = 1, .range = .{ .start = 0, .end = 4 } },
        .{ .pos = 2, .range = .{ .start = 8, .end = 12 } },
    });
    try expectArena(&dst, gpa, ".AAAA.CCCC");
}

test "copyRanges into an empty arena, and with nothing to do" {
    const gpa = testing.allocator;
    {
        var dst = try RawColumn.withMaxSegments(gpa, 32);
        defer dst.deinit();
        var src = try RawColumn.load(gpa, "hello");
        defer src.deinit();
        try dst.copyRanges(&src, &.{.{ .pos = 0, .range = .all }});
        try expectArena(&dst, gpa, "hello");
    }
    {
        var dst = try RawColumn.withMaxSegments(gpa, 8);
        defer dst.deinit();
        try dst.spliceSlice(0, 0, "abcd");
        var src = try RawColumn.load(gpa, "xyz");
        defer src.deinit();
        try dst.copyRanges(&src, &.{});
        try expectArena(&dst, gpa, "abcd");
        // A range past the end of the source clamps, and a splice that names
        // no source bytes and deletes nothing is dropped.
        try dst.copyRanges(&src, &.{.{ .pos = 4, .range = .{ .start = 0, .end = 99 } }});
        try expectArena(&dst, gpa, "abcdxyz");
    }
}

test "copyRanges carries the source's slab boundaries across whole" {
    const gpa = testing.allocator;
    // Twelve four-byte values, one per splice, so every value boundary in the
    // source is a slab boundary too.
    var src = try RawColumn.withMaxSegments(gpa, 4);
    defer src.deinit();
    for (0..12) |i| {
        const v = [_]u8{@as(u8, 'a') + @as(u8, @intCast(i))} ** 4;
        try src.spliceSlice(src.len(), 0, &v);
    }
    try testing.expectEqual(@as(usize, 12), src.slabCount());

    var dst = try RawColumn.withMaxSegments(gpa, 4);
    defer dst.deinit();
    try dst.spliceSlice(0, 0, "0000");
    try dst.copyRanges(&src, &.{
        .{ .pos = 0, .range = .{ .start = 0, .end = 24 } },
        .{ .pos = 4, .range = .{ .start = 24, .end = 48 } },
    });
    try testing.expectEqual(@as(usize, 52), dst.len());
    // No byte copying: the twelve source slabs plus the untouched one.
    try testing.expectEqual(@as(usize, 13), dst.slabCount());
    // Every value is still one contiguous slice, which is the property the
    // whole chunking is there to keep (`raw.rs:334-341`).
    for (0..13) |i| {
        try testing.expectEqual(@as(usize, 4), (try dst.get(i * 4, i * 4 + 4)).len);
    }
}

test "a chain of small copies does not fragment the arena" {
    const gpa = testing.allocator;
    const budget: usize = 256;
    var dst = try RawColumn.withMaxSegments(gpa, budget);
    defer dst.deinit();
    const filler = try gpa.alloc(u8, 8 * budget);
    defer gpa.free(filler);
    @memset(filler, 'x');
    try dst.spliceSlice(0, 0, filler);

    for (0..400) |i| {
        var src = try RawColumn.load(gpa, "abcd");
        defer src.deinit();
        const at = ((i * 37) % (dst.len() - 4)) & ~@as(usize, 3);
        try dst.copyRanges(&src, &.{.{ .pos = at, .range = .{ .start = 0, .end = 4 } }});
    }
    // Bounded by the byte count, not by the 400 insertion points: the bug
    // this guards is a policy that cut at every splice point and never
    // coalesced (`raw.rs:303-312`, `:1012-1040`).
    const slabs = dst.slabCount();
    try testing.expect(slabs <= 2 * (dst.len() / budget + 1));
    try dst.checkInvariants(gpa);
}

test "normalizeSplices clamps, drops and merges" {
    const gpa = testing.allocator;
    {
        // A range past the end of the source clamps to it.
        const out = try normalizeSplices(gpa, &.{
            .{ .pos = 0, .range = .{ .start = 0, .end = 99 } },
        }, 4, 0);
        defer gpa.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqual(Range{ .start = 0, .end = 4 }, out[0].range);
    }
    {
        // A splice that inserts nothing and deletes nothing is dropped, so
        // `copyRanges` does no work at all.
        const out = try normalizeSplices(gpa, &.{
            .{ .pos = 2, .range = .{ .start = 2, .end = 2 } },
        }, 4, 4);
        defer gpa.free(out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
    {
        // Two splices that touch and take touching source ranges become one.
        const out = try normalizeSplices(gpa, &.{
            .{ .pos = 0, .delete = 2, .range = .{ .start = 0, .end = 2 } },
            .{ .pos = 2, .delete = 2, .range = .{ .start = 2, .end = 4 } },
        }, 4, 4);
        defer gpa.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectEqual(@as(usize, 4), out[0].delete);
        try testing.expectEqual(Range{ .start = 0, .end = 4 }, out[0].range);
    }
    {
        // Destination regions that do not ascend, or run off the end, and
        // source ranges that go backwards, are the caller's mistakes.
        try testing.expectError(error.InvalidValue, normalizeSplices(gpa, &.{
            .{ .pos = 4, .range = .all },
            .{ .pos = 0, .range = .all },
        }, 8, 8));
        try testing.expectError(error.InvalidValue, normalizeSplices(gpa, &.{
            .{ .pos = 6, .delete = 4, .range = .all },
        }, 8, 8));
        try testing.expectError(error.InvalidValue, normalizeSplices(gpa, &.{
            .{ .pos = 0, .range = .{ .start = 4, .end = 8 } },
            .{ .pos = 0, .range = .{ .start = 0, .end = 4 } },
        }, 8, 8));
    }
}

test "random splices agree with a plain array" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x1234_5678);
    const random = prng.random();

    var col = try RawColumn.withMaxSegments(gpa, 16);
    defer col.deinit();
    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(gpa);

    for (0..2000) |_| {
        const len = model.items.len;
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                const at = random.intRangeAtMost(usize, 0, len);
                const n = random.intRangeAtMost(usize, 1, 8);
                const bytes = try gpa.alloc(u8, n);
                defer gpa.free(bytes);
                random.bytes(bytes);
                try col.spliceSlice(at, 0, bytes);
                try model.insertSlice(gpa, at, bytes);
            },
            1 => {
                if (len == 0) continue;
                const at = random.intRangeLessThan(usize, 0, len);
                const del = random.intRangeAtMost(usize, 1, @min(len - at, 6));
                try col.spliceSlice(at, del, "");
                try model.replaceRange(gpa, at, del, &.{});
            },
            else => {
                if (len == 0) continue;
                const at = random.intRangeLessThan(usize, 0, len);
                const del = random.intRangeAtMost(usize, 1, @min(len - at, 4));
                const n = random.intRangeAtMost(usize, 1, 6);
                const bytes = try gpa.alloc(u8, n);
                defer gpa.free(bytes);
                random.bytes(bytes);
                try col.spliceSlice(at, del, bytes);
                try model.replaceRange(gpa, at, del, bytes);
            },
        }
        try testing.expectEqual(model.items.len, col.len());
        const got = try col.encode(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, model.items, got);
        try col.checkInvariants(gpa);
    }
}

test "random multi-point copies agree with a plain array" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xC0DE_1234);
    const random = prng.random();

    for (0..300) |round| {
        const max_seg = ([_]usize{ 4, 7, 16, 64 })[round % 4];
        const dst_len = random.intRangeAtMost(usize, 0, 40);
        const src_len = random.intRangeAtMost(usize, 0, 60);
        const dst_bytes = try gpa.alloc(u8, dst_len);
        defer gpa.free(dst_bytes);
        random.bytes(dst_bytes);
        const src_bytes = try gpa.alloc(u8, src_len);
        defer gpa.free(src_bytes);
        random.bytes(src_bytes);

        // Ascending, non-overlapping on both sides.
        var splices: std.ArrayList(Splice) = .empty;
        defer splices.deinit(gpa);
        var dst_pos: usize = 0;
        var src_pos: usize = 0;
        while (dst_pos <= dst_len and src_pos < src_len) {
            const pos = dst_pos + random.intRangeAtMost(usize, 0, dst_len - dst_pos);
            const del = random.intRangeAtMost(usize, 0, @min(dst_len - pos, 3));
            const start = src_pos + random.intRangeAtMost(usize, 0, @min(src_len - src_pos, 5));
            const end = start + random.intRangeAtMost(usize, 0, @min(src_len - start, 8));
            try splices.append(gpa, .{ .pos = pos, .delete = del, .range = .{ .start = start, .end = end } });
            dst_pos = pos + del;
            src_pos = end;
            if (random.uintLessThan(u8, 3) == 0) break;
        }

        var dst = try RawColumn.withMaxSegments(gpa, max_seg);
        defer dst.deinit();
        try dst.spliceSlice(0, 0, dst_bytes);
        var src = try RawColumn.withMaxSegments(gpa, max_seg);
        defer src.deinit();
        try src.spliceSlice(0, 0, src_bytes);

        // The model, applying the same splices front to back with a shift.
        var model: std.ArrayList(u8) = .empty;
        defer model.deinit(gpa);
        try model.appendSlice(gpa, dst_bytes);
        var shift: isize = 0;
        for (splices.items) |sp| {
            const at: usize = @intCast(@as(isize, @intCast(sp.pos)) + shift);
            const bytes = src_bytes[@min(sp.range.start, src_len)..@min(sp.range.end, src_len)];
            try model.replaceRange(gpa, at, sp.delete, bytes);
            shift += @as(isize, @intCast(bytes.len)) - @as(isize, @intCast(sp.delete));
        }

        try dst.copyRanges(&src, splices.items);
        try testing.expectEqual(model.items.len, dst.len());
        const got = try dst.encode(gpa);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, model.items, got);
        try dst.checkInvariants(gpa);

        // Every byte is still reachable through the sequential reader, which
        // is what an empty slab would break (`raw.rs:242-249`).
        var it = dst.iterator();
        var seen: usize = 0;
        while (it.pos() < dst.len()) {
            seen += (try it.take(1)).len;
        }
        try testing.expectEqual(dst.len(), seen);
    }
}

test "a caller can walk the slab layout" {
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 4);
    defer col.deinit();
    try col.spliceSlice(0, 0, "0123456789");
    try testing.expectEqual(@as(usize, 1), col.slabCount());
    const s = col.slabAt(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("0123456789", s.data);
    try testing.expect(col.slabAt(1) == null);
    try testing.expectEqual(@as(usize, 4), col.maxSegments());
}

// ── Upstream `hexane/src/tests.rs` ────────────────────────────────────────────
//
// **What lands here and what does not.** The cases below are named for
// upstream tests whose subject is a *column*, and no `Column` exists outside
// `column.zig`. They are ported anyway because the mechanism each one exists
// to catch is **this file's**, and upstream's is the same mechanism: the
// drain-across-slabs, the seam choice and the coalescing that follow a splice
// are written once, here, from `raw.rs`, and `column.zig` drives the same
// shape over run sequences (`raw.zig:232-250`).
//
// **What that does not cover, stated plainly.** The rows here are 4-byte
// words, so the weights are bytes and not run segments, and the budget is a
// runtime argument rather than the comptime `slabmod.default_max_segments`.
// A `Column<u64>` cut at four segments is still covered only by
// `column.zig`'s own transcription. These tests are **not** evidence about
// the typed column; they are the arena's own cases, wearing upstream's names
// because the mechanism is upstream's.

/// One row of the mirrors below, as the arena sees it: a four-byte
/// big-endian word, so a row boundary is a byte boundary and the drain and
/// the split both have somewhere clean to land.
fn wordOf(v: u32) [4]u8 {
    return .{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

/// The port's [`multi_slab_col`](
/// ../github-automerge-automerge/rust/hexane/src/tests.rs):2658-2661) — an
/// arena holding rows `0..n`, cut so that it spans more than one slab.
///
/// Upstream's helper builds a `Column` with a four-*segment* budget. **A byte
/// budget of 16 over four-byte rows is the same cut**: every slab fills with
/// four rows, and nothing coalesces back because a full slab is not *under* a
/// quarter of the budget (`canMerge`, `raw.zig:518-521`).
fn multiSlabArena(gpa: std.mem.Allocator, n: usize, budget: usize) !RawColumn {
    var col = try RawColumn.withMaxSegments(gpa, budget);
    errdefer col.deinit();
    for (0..n) |i| try col.spliceSlice(i * 4, 0, &wordOf(@intCast(i)));
    return col;
}

/// The arena's rows, compared one word at a time, and its layout checked.
///
/// **The element loop and not a length**, for the reason
/// `hexane_test.zig:185-192` gives: an arena whose bytes came back permuted
/// has the right length, and a splice that re-anchored the drain on the wrong
/// slab is that shape.
fn expectWords(col: *const RawColumn, want: []const u32) !void {
    const gpa = testing.allocator;
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (want) |w| try expected.appendSlice(gpa, &wordOf(w));

    const got = try col.encode(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, expected.items, got);
    try col.checkInvariants(gpa);
}

test "cross_slab_delete_all" {
    // **`tests.rs:2703-2708`.** Deleting every row leaves an empty arena.
    const gpa = testing.allocator;
    var col = try multiSlabArena(gpa, 10, 16);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    try col.spliceSlice(0, 10 * 4, &.{});
    try testing.expectEqual(@as(usize, 0), col.len());
    try testing.expect(col.isEmpty());
    // Every slab the delete emptied is dropped rather than left behind
    // holding nothing (`raw.rs:247-248`), so the walk finds no empty slab.
    try col.checkInvariants(gpa);
}

test "cross_slab_delete_from_start" {
    // **`tests.rs:2685-2691`.** The delete starts at the front and runs off
    // the end of the first slab, so the drain consumes whole slabs.
    const gpa = testing.allocator;
    var col = try multiSlabArena(gpa, 10, 16);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    try col.spliceSlice(0, 5 * 4, &.{});
    try expectWords(&col, &.{ 5, 6, 7, 8, 9 });
}

test "cross_slab_delete_middle" {
    // **`tests.rs:2664-2674`.** Upstream's own guard, kept: a delete that fits
    // inside one slab is a different case and this is not it.
    const gpa = testing.allocator;
    var col = try multiSlabArena(gpa, 10, 16);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    try col.spliceSlice(3 * 4, 4 * 4, &.{});
    try expectWords(&col, &.{ 0, 1, 2, 7, 8, 9 });
}

test "cross_slab_delete_to_end" {
    // **`tests.rs:2676-2682`.** The delete finishes in the *last* slab, so the
    // drain keeps that slab's head and drops only what it emptied.
    const gpa = testing.allocator;
    var col = try multiSlabArena(gpa, 10, 16);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    try col.spliceSlice(6 * 4, 4 * 4, &.{});
    try expectWords(&col, &.{ 0, 1, 2, 3, 4, 5 });
}

test "cross_slab_replace" {
    // **`tests.rs:2694-2700`.** The delete spans slabs while the insert fits
    // inside one, which is the seam `pickSplit` has to choose
    // (`raw.zig:730-737`).
    const gpa = testing.allocator;
    var col = try multiSlabArena(gpa, 10, 16);
    defer col.deinit();
    try testing.expect(col.slabCount() > 1);

    var payload: [8]u8 = undefined;
    @memcpy(payload[0..4], &wordOf(99));
    @memcpy(payload[4..8], &wordOf(88));
    try col.spliceSlice(3 * 4, 4 * 4, &payload);
    try expectWords(&col, &.{ 0, 1, 2, 99, 88, 7, 8, 9 });
}

test "cross_slab_fuzz" {
    // **`tests.rs:2745-2786`.** A thousand rounds, ten splices each, over an
    // arena of at most twenty-four rows with a per-round budget.
    //
    // **The seeds are pinned, not drawn.** Upstream uses `SmallRng`; the port
    // uses `std.Random.DefaultPrng` over the same `0..1000` seed range, which
    // is the convention `hexane_test.zig:241-247` records — a proptest
    // failure is reproducible from its regressions file and a random one is
    // not. **The seed is not upstream's op list**, only upstream's seed
    // *range*: `SmallRng` and `DefaultPrng` are different generators, so no
    // seed here reproduces an upstream round.
    const gpa = testing.allocator;
    for (0..1000) |seed| try crossSlabRound(gpa, seed);
}

/// One round of [`cross_slab_fuzz`], compared against a `Vec` model **after
/// every single operation** rather than only at the end.
fn crossSlabRound(gpa: std.mem.Allocator, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    const n = random.intRangeAtMost(usize, 0, 19) + 5;
    // A byte budget of 3..8 over four-byte rows is one or two rows per slab.
    const budget = random.intRangeAtMost(usize, 3, 8);

    var col = try multiSlabArena(gpa, n, budget);
    defer col.deinit();
    var mirror: std.ArrayList(u32) = .empty;
    defer mirror.deinit(gpa);
    for (0..n) |i| try mirror.append(gpa, @intCast(i));

    for (0..10) |op| {
        const len = mirror.items.len;
        if (len == 0) break;
        const idx = random.intRangeAtMost(usize, 0, len - 1);
        const del = random.intRangeAtMost(usize, 0, @min(len - idx, 5));
        const ins_count = random.intRangeAtMost(usize, 0, 3);

        var inserted: [3]u32 = undefined;
        var payload: [12]u8 = undefined;
        for (inserted[0..ins_count], 0..) |*v, k| {
            v.* = random.intRangeAtMost(u32, 0, 4);
            @memcpy(payload[k * 4 ..][0..4], &wordOf(v.*));
        }

        try col.spliceSlice(idx * 4, del * 4, payload[0 .. ins_count * 4]);
        try mirror.replaceRange(gpa, idx, del, inserted[0..ins_count]);

        if (col.len() != mirror.items.len * 4) {
            std.debug.print("seed {d} op {d}: the arena holds {d} byte(s), the model {d} row(s)\n", .{
                seed, op, col.len(), mirror.items.len,
            });
            return error.TestExpectedEqual;
        }
        try expectWords(&col, mirror.items);
    }
}

test "cross_slab_fuzz_regression" {
    // **`tests.rs:2711-2743`.** Upstream replays seed 799 out of the sweep
    // above, so a divergence there is reproduced on its own.
    //
    // **What the port can honestly say.** `SmallRng` and
    // `std.Random.DefaultPrng` are different generators, so seed 799 here is
    // **not** upstream's seed-799 op list and this is not a replay of it.
    // What it is: the sweep's per-operation mirror check, pinned to one seed
    // so a failure names a round rather than a range, and so a report that
    // says "seed 799" is re-runnable from this line. Upstream's number is
    // kept because it is the number upstream's failure reports carry.
    try crossSlabRound(std.testing.allocator, 799);
}

test "copy_ranges_rejects_overlap" {
    // **`tests.rs:1479-1489`.** Upstream marks this
    // `#[should_panic(expected = "ascending")]`: two splices naming source
    // ranges that overlap are refused before anything is copied, because the
    // ranges must ascend.
    //
    // **The port refuses rather than panics.** `normalizeSplices` returns
    // `error.InvalidValue` when a range starts behind the source position the
    // previous one reached (`raw.zig:788`), and `copyRanges` calls it before
    // the first mutation (`raw.zig:396-397`). The refusal is the assertion;
    // the arena must come out untouched, which is the half a `should_panic`
    // cannot check.
    const gpa = testing.allocator;
    var src = try multiSlabArena(gpa, 10, 16);
    defer src.deinit();
    var dst = try multiSlabArena(gpa, 4, 16);
    defer dst.deinit();

    try testing.expectError(error.InvalidValue, dst.copyRanges(&src, &.{
        .{ .pos = 0, .range = .{ .start = 10, .end = 30 } },
        .{ .pos = 0, .range = .{ .start = 20, .end = 40 } },
    }));
    try expectWords(&dst, &.{ 0, 1, 2, 3 });
}

/// Runs `stageSpliceSlice` with each of its allocations refused in turn,
/// asserting after every refusal that the arena is still the one `check`
/// describes, and leaving the last attempt — the one that allocated the whole
/// way through — published.
///
/// `check` is a value with a `check` method. It allocates, so it runs with
/// `fail_index` disarmed: a check refused by the very failure it is reporting
/// on would report nothing.
fn sweepStageRefusals(
    failing: *testing.FailingAllocator,
    col: *RawColumn,
    index: usize,
    del: usize,
    bytes: []const u8,
    check: anytype,
) !void {
    var skip: usize = 0;
    while (true) {
        failing.fail_index = failing.alloc_index + skip;
        const outcome = col.stageSpliceSlice(index, del, bytes);
        // The check below allocates, and it has to be able to.
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |prepared| {
            var staged = prepared;
            staged.publish(col);
            break;
        } else |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            try @call(.auto, @TypeOf(check).check, .{ col, failing.allocator(), check });
            skip += 1;
            // An edit that never lands is a test that never ends. The widest
            // edit below makes fewer allocations than this bound allows.
            if (skip > 256) return error.Fail;
        }
    }
    // An edit that allocated nothing could not have been refused, and the sweep
    // would not have proved anything.
    try testing.expect(skip > 0);
}

/// The check every refusal sweep here runs: the bytes, the length, the layout
/// and the tree. `checkInvariants` is the part that fails when an edit gave up
/// after rewriting the slabs and not the tree, or the other way round.
const UnchangedWords = struct {
    want: []const u32,

    fn check(col: *RawColumn, gpa: std.mem.Allocator, self: UnchangedWords) !void {
        try expectWords(col, self.want);
        try col.checkInvariants(gpa);
    }
};

/// Asserts that two arenas hold the same bytes, the same length and the same
/// number of slabs. The edit a sweep finally lands is compared this way rather
/// than against pinned bytes, because the two arenas differ only in how many
/// allocations they made and the point is that they do not differ at all.
fn expectSameArena(got: *const RawColumn, want: *const RawColumn) !void {
    const gpa = testing.allocator;
    const got_bytes = try got.encode(gpa);
    defer gpa.free(got_bytes);
    const want_bytes = try want.encode(gpa);
    defer gpa.free(want_bytes);
    try testing.expectEqualSlices(u8, want_bytes, got_bytes);
    try testing.expectEqual(want.len(), got.len());
    try testing.expectEqual(want.slabCount(), got.slabCount());
}

test "a splice that cannot be staged leaves the arena exactly as it was" {
    // **This is the contract `stageSpliceSlice` makes and an in-place rewrite
    // cannot.** An `error.OutOfMemory` from anywhere in the stage returns with
    // the slabs, the bytes, the length and the tree as the call found them, so
    // a caller may retry. The sweep is what makes it a claim about the whole
    // stage rather than about one allocation.
    //
    // A real allocator through a counter, and the arena is built with the same
    // allocator it stages from — which is now the only allocator there is,
    // because the stage takes none.
    {
        // The shape that reaches the most steps: the delete runs off the end
        // of the slab it starts in, the drain stops inside the next one and
        // cuts its head off, and an insert lands in the first slab too.
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var col = try multiSlabArena(gpa, 6, 8);
        defer col.deinit();
        try sweepStageRefusals(&failing, &col, 6, 5, "ABCD", UnchangedWords{ .want = &.{ 0, 1, 2, 3, 4, 5 } });
        // The attempt that allocated the whole way through landed, and it
        // landed the edit a plain arena lands.
        var plain = try multiSlabArena(gpa, 6, 8);
        defer plain.deinit();
        try plain.spliceSlice(6, 5, "ABCD");
        try expectSameArena(&col, &plain);
    }
    {
        // The shape where the staged range is longer than the range it
        // replaces, so publishing moves the tail backwards rather than
        // forwards.
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var col = try multiSlabArena(gpa, 6, 8);
        defer col.deinit();
        try sweepStageRefusals(&failing, &col, 0, 0, "ABCDEFGHIJ", UnchangedWords{ .want = &.{ 0, 1, 2, 3, 4, 5 } });
        var plain = try multiSlabArena(gpa, 6, 8);
        defer plain.deinit();
        try plain.spliceSlice(0, 0, "ABCDEFGHIJ");
        try expectSameArena(&col, &plain);
    }
}

test "prepared neighbour coalescing publishes with allocation refused" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var col = try RawColumn.withMaxSegments(gpa, 16);
    defer col.deinit();
    const original = "abcdefghijklmnop";
    try col.spliceSlice(0, 0, original);
    try col.spliceSlice(2, 0, "ABCDEFGHIJKLMNOPQRST");

    // Removing the oversized insertion leaves a two-byte slab beside a
    // fourteen-byte neighbour. Preparation must coalesce them before handoff.
    var staged = try col.stageSpliceSlice(2, 20, &.{});
    defer staged.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    staged.publish(&col);
    try testing.expectEqualStrings(original, try col.get(0, original.len));
    var cursor = try col.iteratorAt(7);
    try testing.expectEqualStrings("hijklmnop", try cursor.take(9));
    try testing.expectEqual(@as(usize, original.len), col.len());
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try col.checkInvariants(gpa);
}

test "publish consumes the staged edit, and deinit beside it is a no-op" {
    // `testing.allocator` is the arbiter: if `deinit` released buffers
    // `publish` had already handed over, the second free is a double free it
    // reports at the end of this test. Nothing here can pass by accident.
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 32);
    defer col.deinit();
    try col.spliceSlice(0, 0, "hello");

    var staged = try col.stageSpliceSlice(5, 0, ", world");
    defer staged.deinit();
    staged.publish(&col);
    try expectArena(&col, gpa, "hello, world");

    // A staged no-op publishes to nothing at all.
    var noop = try col.stageSpliceSlice(0, 0, &.{});
    defer noop.deinit();
    noop.publish(&col);
    try expectArena(&col, gpa, "hello, world");

    // An abort releases the staged buffers and leaves the arena where it was.
    var aborted = try col.stageSpliceSlice(5, 6, "!");
    aborted.deinit();
    try expectArena(&col, gpa, "hello, world");

    // And a refusal is a refusal, with the arena untouched.
    try testing.expectError(error.InvalidValue, col.stageSpliceSlice(0, 99, ""));
    try testing.expectError(error.InvalidValue, col.stageSpliceSlice(99, 0, ""));
    try expectArena(&col, gpa, "hello, world");
}

/// Stages one edit on each of two arenas and publishes both, which is the
/// shape a caller writing several columns uses.
fn stagePair(left: *RawColumn, right: *RawColumn, a: []const u8, b: []const u8) !void {
    var first = try left.stageSpliceSlice(0, 4, a);
    defer first.deinit();
    var second = try right.stageSpliceSlice(8, 4, b);
    defer second.deinit();
    first.publish(left);
    second.publish(right);
}

test "staging every column before publishing any keeps a group all-or-nothing" {
    // Two arenas, each staged before either is published. A refusal under the
    // second stage aborts the first through its own `defer`, and neither arena
    // has moved — which is the whole reason `deinit` is separate from
    // `publish` and why `publish` cannot fail. There is no full column copy
    // anywhere: each edit rebuilds only the slab it reaches into.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var left = try multiSlabArena(gpa, 4, 16);
    defer left.deinit();
    var right = try multiSlabArena(gpa, 4, 16);
    defer right.deinit();
    const a = wordOf(99);
    const b = wordOf(77);
    const before = UnchangedWords{ .want = &.{ 0, 1, 2, 3 } };

    var skip: usize = 0;
    while (true) {
        failing.fail_index = failing.alloc_index + skip;
        const outcome = stagePair(&left, &right, &a, &b);
        // The checks below allocate, and they have to be able to.
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |_| break else |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            try UnchangedWords.check(&left, gpa, before);
            try UnchangedWords.check(&right, gpa, before);
            skip += 1;
            if (skip > 256) return error.Fail;
        }
    }
    try testing.expect(skip > 0);
    try expectWords(&left, &.{ 99, 1, 2, 3 });
    try expectWords(&right, &.{ 0, 1, 77, 3 });
}

test "max_segments_zero_rejected" {
    // **Upstream's `Column::with_max_segments` floor
    // (`column.rs:1121-1126`), driven through `RawColumn.withMaxSegments`.**
    // A zero budget is refused at construction: no slab could ever be over
    // it, so the arena would fragment to one slab per splice point.
    //
    // **The bound differs and the port is the looser one here.** Upstream
    // requires `max_segments >= 2`; the arena refuses only zero
    // (`raw.zig:174-175`), because a one-byte slab is a degenerate but
    // well-formed layout. **So this covers the zero case and not the one
    // case** — `max_segments_one_rejected` and
    // `max_segments_one_rejected_at_load` are recorded as blocked on
    // `column.zig`, where the `>= 2` assert lives.
    try testing.expectError(
        error.InvalidValue,
        RawColumn.withMaxSegments(std.testing.allocator, 0),
    );
}

test "max_segments_two_full_cycle" {
    // **`tests.rs:1170-1190`.** The minimum legal budget survives a whole
    // build-mutate-save-load-mutate cycle.
    //
    // **Two is the minimum the upstream assert admits** (`column.rs:1121-1126`),
    // and the port's arena accepts it, so this is the budget upstream's own
    // floor names. With two bytes and four-byte rows every row is a blob wider
    // than the budget and keeps a slab of its own (`raw.zig:1032`), which is
    // the most fragmented layout the arena admits — the point of the case.
    const gpa = testing.allocator;
    var col = try RawColumn.withMaxSegments(gpa, 2);
    defer col.deinit();
    var mirror: std.ArrayList(u32) = .empty;
    defer mirror.deinit(gpa);

    for (0..100) |i| {
        const v: u32 = @intCast(i);
        try col.spliceSlice(i * 4, 0, &wordOf(v));
        try mirror.append(gpa, v);
    }
    try expectWords(&col, mirror.items);

    try col.spliceSlice(10 * 4, 4, &.{});
    _ = mirror.orderedRemove(10);
    try expectWords(&col, mirror.items);

    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var reloaded = try RawColumn.loadWithMaxSegments(gpa, bytes, 2);
    defer reloaded.deinit();
    try expectWords(&reloaded, mirror.items);

    // And mutate the reloaded arena once more, which is the half a save/load
    // pair on its own never reaches.
    try reloaded.spliceSlice(0, 0, &wordOf(7));
    try mirror.insert(gpa, 0, 7);
    try expectWords(&reloaded, mirror.items);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The seven `cross_slab_*` cases are this file's cases wearing upstream's
//   names.** Upstream builds a `Column<u64>` with a four-*segment* budget and
//   splices across the seams; the drain-across-slabs, the seam choice
//   (`pickSplit`, `raw.zig:730-737`) and the coalescing that follows are written
//   once, here, from `raw.rs`, and `column.zig` drives the same shape over run
//   sequences. **The rows here are 4-byte words, so the weights are bytes and
//   the budget is a runtime argument** — a `Column<u64>` cut at four segments is
//   still covered only by `column.zig`'s own transcription.
//
// * **`cross_slab_fuzz_regression` is not a replay of upstream's seed 799.**
//   `SmallRng` and `std.Random.DefaultPrng` are different generators, so seed
//   799 here is the port's own round. It is the sweep's per-operation mirror
//   check pinned to one seed, so a failure names a round rather than a range.
//
// * **`max_segments_zero_rejected` covers the zero case and not the one case.**
//   Upstream's assert is `max_segments >= 2` (`column.rs:1121-1126`); the arena
//   refuses only zero (`raw.zig:174-175`), because a one-byte slab is degenerate
//   but well formed. `max_segments_one_rejected` and
//   `max_segments_one_rejected_at_load` are therefore blocked on `column.zig`,
//   where the `>= 2` assert lives.
//
// * **`fuzz_slab_merge_invariant` is NOT ported here, and the arena is the wrong
//   place for it.** Upstream asserts a *global* postcondition — no undersized
//   slab anywhere has a neighbour pair that would still fit
//   (`tests.rs:4022-4054`). `canMerge` states the same rule, but this file
//   applies it **only to the boundaries around a splice**
//   (`stageSpliceSlice`), deliberately never globally, so a port would have
//   to weaken the case into a per-boundary predicate. **A weaker assertion
//   wearing the same name would inflate the coverage count and prove less** — it
//   is recorded as blocked instead.
//
// * **`try_merge_range_*` were recorded here as blocked, and were ported in
//   `column.zig` on 2026-10-02.** The original note was right about this file
//   and wrong about the port: `RawColumn.withMaxSegments` does take a budget,
//   but the arena splits at *byte* boundaries and holds no run structure, so
//   "a delete spanning several slab boundaries, then coalesce" cannot be built
//   here. **Upstream's `validate_rle_column` and its `slab_count_before > 5`
//   are run counts, and the run-count budget is `column.zig`'s** — which is
//   where all three now live, under their upstream names, at the port's own
//   budget of 64 runs (`slab.zig:114`) and with the slab count asserted rather
//   than assumed.
//
// * **`copy_ranges_rejects_overlap` is a refusal, and the port refuses rather
//   than panics.** Upstream marks it `#[should_panic(expected = "ascending")]`;
//   `normalizeSplices` returns `error.InvalidValue` before the first mutation
//   (`raw.zig:788`, `:396-397`), and the test additionally holds that the
//   destination is untouched — the half a `should_panic` cannot check.
//
// ## The upstream `hexane/src/tests.rs` cases with no `^test "NAME"` here
//
// **The instrument, named first, because a coverage number without one is not
// a measurement.** Upstream's denominator: every `fn NAME` in
// `rust/hexane/src/tests.rs` carrying `#[test]` within the eight preceding
// lines — **286 functions, 284 distinct names**, because `splice_and_nullable`
// and `u64_column_roundtrip_and_wire_divergence` are each declared twice, once
// per codec parameter. A name counts as present when some `test "NAME"`
// declaration anywhere in `src/` spells it.
//
// **This record was 103 on 2026-10-01, 79 on the first day of this pass, and
// is 28 now.** A figure carried forward is a measurement of a tree that no
// longer exists, so the number and the list below are one edit.
//
// **What the 79 became.** Every group that said *the thing is missing* now
// says *the thing is here*, because the thing was missing from the
// implementation rather than from the tests:
//
// * **A (19) — closed.** `rle.Rle`/`rle.RleOption` take `[]const u8` and
//   `rle.RleUtf8` validates it, and `column.zig`'s wire layer routes every
//   payload read, write, comparison and run merge through them
//   (`column.zig`'s `payloadRead`, `appendValue`, `eqlWire`,
//   `WireRle.sameValue`, `RunWriter`). `Column([]const u8, RleUtf8(false))`,
//   `Column(?[]const u8, RleUtf8(true))` and their byte-codec counterparts are
//   real columns, and the 19 cases are declared under their upstream names
//   across `column.zig` (`string_basic` … `scope_to_value_strings`; the five
//   codec-level ones — `golden_format_rle_str`, `golden_format_rle_opt_str`,
//   `golden_format_rle_bytes`, `load_invalid_utf8_in_string_is_error`,
//   `load_invalid_utf8_in_nullable_string_is_error` — are declared in
//   `rle.zig`, over the same codec the columns use).
// * **B (15) — 9 closed, 6 remain** (the second integer codec; below).
// * **C (3) — closed.** `Column.LoadIter` is a real streaming load:
//   `tryNextRun` validates the input run by run as it is pulled, cuts a slab
//   every half-budget runs and measures that slab's weight as it lands, and
//   `finalize` drains and validates whatever the consumer did not pull. The
//   three cases are `load_iter_partial_consume_then_error`,
//   `load_accumulates_prefix_weights_partial_consume` and
//   `load_roundtrip_proptest_streaming`.
// * **E (2) — closed.** `Column.initWithBudget`, `Column.loadWithBudget` and
//   `LoadOpts.withMaxSegments` make the run budget a runtime value, and a
//   budget below two is `error.InvalidValue` — the refusal, where upstream
//   asserts. `max_segments_one_rejected`,
//   `max_segments_one_rejected_at_load`.
// * **F (3) — closed.** `column.Ranges` is the range adapter
//   (`shift.rs:102-126`), with `Iterator.ranges`, `Runs.ranges` and
//   `PrefixIter.ranges`; `Column.spliceRuns` is the run-aware splice
//   (`column.rs:1563-1569`). `ranges_chains_windows`,
//   `ranges_touching_equals_union`, `prefix_iter_runs_splices`.
// * **G (7) — 6 closed, 1 remains** (`copy_ranges_bench`, `#[ignore]`d
//   upstream). `Column.copyStrategy`, `copyRangesWith`, `copySplices`,
//   `copySplicesWith`, `retainRanges`, `swapContents`, `normalizeRanges` and
//   `normalizeSplices` are all real, and the six cases are
//   `copy_ranges_heuristic`, `copy_ranges_into_empty_column`,
//   `copy_ranges_prefix_column`, `copy_ranges_strategies_agree`,
//   `copy_ranges_strategies_agree_nullable`,
//   `copy_ranges_multi_point_strategies_agree`.
// * **I (1) — closed.** `Column.IterState` and `Iterator.suspend` /
//   `tryResume` exist, and a splice bumps the column's mutation counter.
//   `splice_invalidates_a_suspended_iter`.
// * **J (2) — closed**, both arms, now that a string column and a boolean
//   column are real value kinds: `merge_slab_string_literal_boundary` and
//   `splice_runs_str_and_bool`. The integer versions they were folded into
//   are still there.
// * **L (4) — restored under their upstream names.** The reason they were
//   renamed is gone: the string and prefix columns they say exist now do.
//   `next_run_merges_across_slabs_strings_and_prefix`,
//   `next_run_never_yields_adjacent_equal_runs_at_default_config`,
//   `string_splice_at_literal_repeat_boundary`,
//   `string_splice_variable_length_values`. The behaviour-named blocks that
//   carried them (`next_run_merges_across_slabs`,
//   `prefix_next_run_merges_across_slabs`, `splice_over_mixed_width_payloads`)
//   are **kept** — they pin the integer column, which the restored names do
//   not.
// * **K — one of its 19 is now closed.** `fuzz_prefix_column_bool` needs a
//   `Column(bool, Prefix(…))`, which the column layer's integer-valued
//   codecs cannot instantiate; it is declared against the op set's real
//   boolean prefix codec in `opset/columns.zig`, which is where that codec
//   lives. The other 18 are below.
//
// **What this list is and is not.** It is a list of upstream *names* with no
// declaration. A name whose behaviour a ported test already carries is not a
// gap, and those are named below rather than duplicated: a second copy
// wearing upstream's name would inflate the count and prove the same thing.
//
// * **B — 6 cases. A second integer codec.** The port has exactly one
//   integer packing, LEB128, and no codec parameter to add a second. Every
//   one of these six is an `assert_ne!` between two codecs' bytes, or a
//   case written directly against the other codec's primitives:
//   `bijou64` is dead feature code (`AGENTS.md:50-52`) and the other operand
//   is upstream's own test-local `BeLen` (`tests.rs:5420-5431`), neither of
//   which is a surface this port has or should have. `save-load-save
//   identity` — the portable half of the same family — is now declared under
//   its upstream name (`save_load_save_is_identity`), and
//   `truncated_input_errors`'s portable half, "every strict prefix of a
//   multi-byte encoding is a decode error", is `src/leb128.zig:734`.
//   ```
//   codec_roundtrip_boundaries module_aliases_pick_the_codec
//   tier8_overflow_rejected truncated_input_errors
//   u64_column_roundtrip_and_wire_divergence wire_format_matches_spec
//   ```
//
// * **D — 1 case. A `#[derive(Copy)]`, not a behaviour.** `load_with_opts_is_copy`
//   asserts a derive on `LoadOpts` (`tests.rs`), which in Zig is
//   unconditional struct assignment; there is nothing for a test to observe.
//   ```
//   load_with_opts_is_copy
//   ```
//
// * **G — 1 case. A benchmark.** `copy_ranges_bench` is `#[ignore]`d
//   upstream and times two strategies against each other rather than
//   asserting anything. **Its arguments are asserted** — by
//   `copy_ranges_strategies_agree`, which runs both strategies over the same
//   shapes and holds them to the same bytes — and the decision the benchmark
//   was written to tune is pinned by `copy_ranges_heuristic`.
//   ```
//   copy_ranges_bench
//   ```
//
// * **H — 3 cases. `deep_fuzz`, which is dead feature code**
//   (`AGENTS.md:50-52`), and each of the three is
//   `#[cfg_attr(not(feature = "deep_fuzz"), ignore)]` upstream, so they do
//   not run in the reference either.
//   ```
//   fuzz_delta_column fuzz_delta_column_nullable fuzz_prefix_column
//   ```
//
// * **K — 17 cases a named port test already carries.** These are named
//   rather than duplicated.
//   ```
//   delta_scope_to_value_basic empty_born_iter_extends_with_next
//   empty_born_iter_extends_with_shift empty_born_iter_multi_slab_nth
//   fuzz_bool_splice_exhaustive fuzz_column_save_load_after_mutations
//   fuzz_option_u64_splice_exhaustive fuzz_scope_and_seek_to_value
//   fuzz_scope_to_value_nullable fuzz_sequential_splice_uint
//   fuzz_slab_merge_invariant fuzz_splice_ops nth_from_iter_range
//   remap_multi_slab remap_u64_basic remove_n_out_of_bounds_panics
//   seek_to_value_missing
//   ```
//   Where each is carried: `delta_scope_to_value_basic` by
//   `delta_scope_to_value_matches_plain_column`; the three
//   `empty_born_iter_*` by `an empty, an inverted and a past-the-end range
//   are all a position` (`column.zig`, which holds the empty-born `next`,
//   `shift` and far-`nth` arms); the three random-splice cases
//   (`fuzz_bool_splice_exhaustive`, `fuzz_option_u64_splice_exhaustive`,
//   `fuzz_splice_ops`, `fuzz_sequential_splice_uint`) by `random splices
//   agree with a plain array` and `splice_matches_a_model`, the latter over
//   four fixed seeds;
//   `fuzz_column_save_load_after_mutations` by `expectRoundTrip` after 300
//   splices; `fuzz_scope_and_seek_to_value` and
//   `fuzz_scope_to_value_nullable` by `scope_to_value_fuzz_vs_linear`,
//   `scope_to_value_multi_slab_span`, `scope_to_value_fuzz_multi_slab` and
//   the `seek_to_value_*` family;
//   `fuzz_slab_merge_invariant` by `expectSound`, which runs
//   `mergeableNeighbours` — upstream's own predicate, `min_seg =
//   DEFAULT_MAX_SEG / 4` and `sa + sb <= DEFAULT_MAX_SEG`
//   (`tests.rs:4022-4054`) — after **every** splice and splice in the
//   boolean, integer, nullable, delta, prefix and byte-payload codecs;
//   `nth_from_iter_range` by the window-relative arm of `expectNth` and the
//   `nth_across_runs` / `nth_across_slabs` family;
//   `remap_multi_slab` and `remap_u64_basic` by `a remap of a many-slab
//   column keeps every row` and `remap_runs_preserved`;
//   `remove_n_out_of_bounds_panics` by `an out of bounds splice is a
//   refusal, not a trap` and `exerciseBounds`, which hold that `removeN`
//   past the end is `error.InvalidValue` and that the column is unchanged —
//   **stronger** than a panic that never returns; `seek_to_value_missing` by
//   `seek_to_value_basic`'s absent-target arm and `seek_to_value_with_range`.
//
// 28 in total: six that need a second integer codec, one that is a Rust
// derive, one that is an ignored benchmark, three that are dead gated
// feature code, and seventeen whose behaviour a named port test already
// carries.
