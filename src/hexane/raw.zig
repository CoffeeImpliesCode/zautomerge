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
//! `RawColumn.beginOverlay` prepares a durable multi-edit projection without
//! copying existing slab bytes. Bind a caller-held view, use ordinary mutators,
//! capture it, then publish the overlay or abort it with `deinit`. The source
//! stays unchanged until publication; source, overlay and bound view must remain
//! live at stable addresses throughout that protocol.
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
    /// `null` for an owner; otherwise this arena is a borrowed overlay view.
    overlay_owner: ?*Overlay = null,

    /// Begins a durable multi-edit projection at `out`'s final address.
    ///
    /// Only slab descriptors and index metadata are copied; original bytes remain
    /// borrowed. Source, overlay and any bound view must stay live and address
    /// stable until publication or abort. Do not mutate or release the source
    /// meanwhile. On allocation failure the source is unchanged and no overlay
    /// resources survive. A successful overlay must be published or deinited.
    pub fn beginOverlay(self: *Self, out: *Overlay) ParseError!void {
        std.debug.assert(self.overlay_owner == null);
        out.* = .{
            .source = self,
            .projected = self.*,
            .originals = .empty,
            .bound = null,
            .spent = true,
        };
        out.projected.slabs = .empty;
        out.projected.bit = .{ .gpa = self.gpa, .items = .empty };
        out.projected.overlay_owner = out;
        errdefer out.projected.slabs.deinit(self.gpa);
        errdefer out.projected.bit.deinit();
        errdefer out.originals.deinit(self.gpa);
        try out.projected.slabs.appendSlice(self.gpa, self.slabs.items);
        try out.projected.bit.items.appendSlice(self.gpa, self.bit.items.items);
        const count = std.math.cast(u32, self.slabs.items.len) orelse return error.Overflow;
        try out.originals.ensureTotalCapacity(self.gpa, count);
        for (self.slabs.items) |slab| {
            out.originals.putAssumeCapacity(@intFromPtr(slab.data.ptr), false);
        }
        out.spent = false;
    }

    /// A single-owner projection that borrows source bytes and owns its metadata
    /// and replacement buffers. It must not be copied or moved while open.
    /// `bind` lends the projection to one view; `capture` ends that loan.
    /// Publication transfers retained and new buffers to the source. Abort
    /// releases only new buffers. Both terminal operations invalidate the view.
    pub const Overlay = struct {
        /// The unchanged source, borrowed until a terminal operation.
        source: *Self,
        /// Owned metadata and a mixture of borrowed and new byte buffers.
        projected: Self,
        /// Original buffer identities; `true` means detached by a projected edit.
        originals: std.AutoHashMapUnmanaged(usize, bool),
        /// The sole live view, or `null` while the projection is captured.
        bound: ?*Self,
        /// Terminal operations have consumed this overlay when `true`.
        spent: bool,

        /// Lends the projection to `view`, which must be uninitialized storage.
        /// Mutate it with ordinary arena methods; do not copy or deinit it.
        /// Only one view may be bound, and no staged edit may outlive capture.
        pub fn bind(self: *Overlay, view: *Self) void {
            std.debug.assert(!self.spent);
            std.debug.assert(self.bound == null);
            std.debug.assert(view != self.source);
            std.debug.assert(view != &self.projected);
            view.* = self.projected;
            view.overlay_owner = self;
            self.bound = view;
        }

        /// Captures the sole bound view and invalidates its borrowed handle.
        /// Every staged edit on the view must already be published or aborted.
        pub fn capture(self: *Overlay, view: *Self) void {
            std.debug.assert(!self.spent);
            std.debug.assert(self.bound == view);
            std.debug.assert(view.overlay_owner == self);
            self.projected = view.*;
            self.bound = null;
            view.* = undefined;
        }

        /// Publishes to the original source without allocating. Consumes the
        /// projection, frees detached originals once, and transfers all retained
        /// original and new buffers. Captures a bound view before transfer.
        /// All original borrowed reads are invalidated by this publication.
        pub fn publish(self: *Overlay, source: *Self) void {
            std.debug.assert(!self.spent);
            std.debug.assert(source == self.source);
            std.debug.assert(source.overlay_owner == null);
            if (self.bound) |view| self.capture(view);
            const gpa = source.gpa;
            for (source.slabs.items) |*slab| {
                if (self.originals.get(@intFromPtr(slab.data.ptr)).?) slab.deinit(gpa);
            }
            source.slabs.deinit(gpa);
            source.bit.deinit();
            source.* = self.projected;
            source.overlay_owner = null;
            self.originals.deinit(gpa);
            self.spent = true;
        }

        /// Aborts without changing the source or invalidating its byte borrows.
        /// Captures a bound view, frees only new buffers and metadata, and is a
        /// no-op after abort or publication, so it is safe in a `defer`.
        pub fn deinit(self: *Overlay) void {
            if (self.spent) return;
            if (self.bound) |view| self.capture(view);
            const gpa = self.projected.gpa;
            for (self.projected.slabs.items) |*slab| {
                if (!self.originals.contains(@intFromPtr(slab.data.ptr))) slab.deinit(gpa);
            }
            self.projected.slabs.deinit(gpa);
            self.projected.bit.deinit();
            self.originals.deinit(gpa);
            self.spent = true;
        }

        fn releaseSlab(self: *Overlay, slab: *RawSlab) void {
            std.debug.assert(!self.spent);
            if (self.originals.getPtr(@intFromPtr(slab.data.ptr))) |detached| {
                std.debug.assert(!detached.*);
                detached.* = true;
            } else {
                slab.deinit(self.projected.gpa);
            }
        }
    };

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
        std.debug.assert(self.overlay_owner == null);
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
    /// as the call found them and [`checkInvariants`] still holds. Staging may
    /// change the slab list's *spare capacity*, but never the published index.
    /// It prepares checked point replacements or owns a complete prospective
    /// tree, so [`StagedSlice.publish`] cannot allocate or fail.
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
            .index_plan = .none,
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
            try self.findSlab(index);
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
            errdefer gpa.free(buffer);
            try self.copySplicedRange(buffer, range, index, del, bytes);
            staged.put(.{ .data = buffer });
        }
        const new_count = try std.math.add(usize, count_before - staged.drop, staged.len);
        if (staged.drop == 1 and staged.len == 1) {
            staged.index_plan = .{ .point = try self.bit.preparePointUpdate(
                staged.at,
                .{ .n = self.slabs.items[staged.at].data.len },
                .{ .n = staged.slots[0].data.len },
            ) };
        } else {
            // The future layout borrows untouched lengths and reads replacements
            // from staged slots. Its tree never aliases the published index.
            var candidate: indexmod.Fenwick(indexmod.Bytes) = .{ .gpa = gpa, .items = .empty };
            errdefer candidate.deinit();
            const layout: *const StagedSlice = &staged;
            try candidate.rebuildFrom(gpa, layout, new_count, StagedSlice.prospectiveSlabBytes);
            staged.index_plan = .{ .rebuilt = candidate };
        }
        try self.slabs.ensureTotalCapacity(gpa, new_count);
        return staged;
    }

    /// An edit an arena has planned but not yet applied.
    ///
    /// It owns replacement buffers and any prospective tree, and borrows the
    /// arena it was planned against: **the arena must outlive the staged edit
    /// and must not be mutated until publication or abort**. [`publish`] takes
    /// that same arena and no other. Do not copy an open staged edit.
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
        /// Checked replacements for an unchanged-cardinality single slab, or
        /// the independently owned tree describing the complete future layout.
        index_plan: union(enum) {
            none,
            point: indexmod.Fenwick(indexmod.Bytes).PreparedPointUpdate,
            rebuilt: indexmod.Fenwick(indexmod.Bytes),
        },
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
            for (col.slabs.items[self.at..][0..self.drop]) |*old| {
                if (col.overlay_owner) |overlay| {
                    overlay.releaseSlab(old);
                } else {
                    old.deinit(gpa);
                }
            }
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

            // Like-for-like replacement keeps O(log S) point publication;
            // structural edits transfer the already constructed tree.
            switch (self.index_plan) {
                .none => unreachable,
                .point => |*prepared| col.bit.publishPointUpdate(prepared),
                .rebuilt => |candidate| {
                    col.bit.deinit();
                    col.bit = candidate;
                },
            }
            self.index_plan = .none;
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
            switch (self.index_plan) {
                .none, .point => {},
                .rebuilt => |*candidate| candidate.deinit(),
            }
            self.index_plan = .none;
        }

        fn prospectiveSlabBytes(self: *const This, i: usize) indexmod.Bytes {
            if (i < self.at) return slabBytes(self.owner, i);
            const relative = i - self.at;
            if (relative < self.len) return .{ .n = self.slots[relative].data.len };
            return slabBytes(self.owner, self.at + self.drop + (relative - self.len));
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
            var chunks = try src.chunksIn(sp.range.start, sp.range.end);
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
        const pos = try self.bit.findSlab(start);
        const data = self.slabs.items[pos.slab].data;
        const span = end - start;
        if (pos.offset > data.len or span > data.len - pos.offset) return error.InvalidValue;
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
        const at = try self.bit.findSlab(pos);
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
        // Reserve before copying; deinit owns the bytes as soon as they exist.
        try self.slabs.ensureUnusedCapacity(gpa, 1);
        self.slabs.appendAssumeCapacity(.{ .data = try gpa.dupe(u8, data) });
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
        return (a_len < min or b_len < min) and
            a_len <= self.max_segments and b_len <= self.max_segments - a_len;
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
    fn findSlab(self: *const Self, index: usize) error{Overflow}!indexmod.SlabPos {
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
    ) error{Overflow}!void {
        var at = range.start;
        if (at < index) {
            const end = @min(range.end, index);
            try self.copyOriginalRange(out[0 .. end - at], at, end);
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
        try self.copyOriginalRange(out[at - range.start ..], at - bytes.len + del, range.end - bytes.len + del);
    }

    fn copyOriginalRange(self: *const Self, out: []u8, start: usize, end: usize) error{Overflow}!void {
        var chunks = try self.chunksIn(start, end);
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
    fn chunksIn(self: *const Self, start: usize, end_in: usize) error{Overflow}!ChunksIter {
        const end = @min(end_in, self.total_len);
        var slab_idx: usize = 0;
        var offset: usize = 0;
        if (start < end) {
            const at = try self.findSlab(start);
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
    // **`tests.rs:2745-2784`.** A thousand seeds and ten splices each, over a
    // **run-length column** — upstream's `Column<u64>`, built by
    // `from_values_with_max_segments` with a budget drawn per seed
    // (`:2752-2753`), over `5..=24` values drawn from `0..=4` (`:2750-2751`).
    //
    // **The budget counts runs, and that is the whole reason the case exists.**
    // Three to eight runs against a value stream that repeats one of five
    // numbers cuts *inside* the run sequence, so the runs either side of a cut
    // carry the same value, and every splice has to merge across that seam and
    // re-encode the column canonically. A byte budget over four-byte rows cuts
    // on a row boundary, has no run to merge and nothing to re-encode — so the
    // arena sweep in this file is a **different case under its own name**
    // ([`byte_arena_cross_slab_fuzz`] below), not a substitute for this one.
    //
    // **The seeds are pinned, not drawn.** Upstream uses `SmallRng`; the port
    // uses `std.Random.DefaultPrng` over the same `0..1000` seed range, which
    // is the convention `hexane_test.zig` records — a proptest failure is
    // reproducible from its regressions file and a random one is not. **The
    // seed is not upstream's op list**, only upstream's seed *range*, and the
    // reason is not that these are two different generators: on a 64-bit
    // target both are Xoshiro256++ (`rngs/small.rs:15`, `Random.zig:13`). They
    // part **before** the first draw — rand_core expands a `u64` seed with
    // PCG32 (`seedable_rng.rs:109-121`), Zig expands one with SplitMix64
    // (`Random/Xoshiro256.zig:57-65`) — and each reduces a bounded draw its own
    // way. What the port substitutes here is the *sample*, not the property:
    // this sweep is upstream's op sequence over a thousand seeds of our own.
    // Seed 799 itself is [`cross_slab_fuzz_regression`] below, recorded.
    for (0..1000) |seed| try rleCrossSlabRound(testing.allocator, seed, "cross_slab_fuzz");
}

test "cross_slab_fuzz_regression" {
    // **`tests.rs:2711-2743`.** Upstream replays seed 799 out of the sweep
    // above, so a divergence there is reproduced on its own. **This is that
    // replay**, not a round of our own wearing upstream's number: the op list
    // is read from `test/golden/hexane-regression.jsonl`, which `tools/oracle`'s
    // `hexane-regression` subcommand records by drawing upstream's own
    // requests against upstream's own `SmallRng` and asking the reference's
    // `Column<u64>` what it made of each one. Nothing here is re-drawn locally
    // and nothing is typed in by hand.
    //
    // **Why a recorded trace rather than a local draw.** On a 64-bit target
    // `SmallRng` *is* `Xoshiro256PlusPlus` (rand `rngs/small.rs:15`) and
    // `std.Random.DefaultPrng` *is* `Xoshiro256` (`Random.zig:13`) — the same
    // generator, not two of them. They part **before** the first draw: rand_core
    // expands a `u64` seed with PCG32 (`seedable_rng.rs:109-121`) where Zig
    // expands one with SplitMix64 (`Random/Xoshiro256.zig:57-65`), and each then
    // reduces a bounded draw its own way. So no seed in one reproduces an op
    // list in the other, and seed 799 had to be *recorded* rather than
    // re-drawn. See [`cross_slab_fuzz`] for what the sweep keeps instead.
    //
    // **What is checked, after every step and not once at the end**: the
    // column's rows against a plain `Vec` model, the column's rows against the
    // reference's own `expected`, and the column's canonical bytes against the
    // reference's own `hex`. The last is the wire claim — the very
    // `Column::save()` bytes the reference wrote for that state — and it is
    // the one a model check cannot stand in for.
    //
    // **A missing vector fails this test.** There is no path through it that
    // passes without replaying the trace.
    const gpa = testing.allocator;
    const trace = try readRegressionTrace(gpa);
    defer gpa.free(trace);

    var lines = std.mem.splitScalar(u8, trace, '\n');
    const line = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    var parsed = try std.json.parseFromSlice(RegressionRecord, gpa, line, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const rec = parsed.value;
    try testing.expectEqualStrings("hexane-regression", rec.kind);
    try testing.expectEqual(@as(u64, 799), rec.seed);

    const colmod = @import("column.zig");
    const RleU64 = colmod.Column(u64, colmod.Rle(u64));
    var col = try RleU64.fromValues(gpa, rec.values, rec.budget);
    defer col.deinit();
    var mirror: std.ArrayList(u64) = .empty;
    defer mirror.deinit(gpa);
    try mirror.appendSlice(gpa, rec.values);

    for (rec.steps, 0..) |step, k| {
        try col.splice(gpa, step.index, step.delete, step.insert);
        try mirror.replaceRange(gpa, step.index, step.delete, step.insert);

        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        if (!std.mem.eql(u64, got, step.expected)) {
            std.debug.print("cross_slab_fuzz_regression step {d}: splice({d}, {d}, {d} value(s)) left the column holding {d} row(s); the reference recorded {d}\n", .{
                k, step.index, step.delete, step.insert.len, got.len, step.expected.len,
            });
            return error.TestExpectedEqual;
        }
        try testing.expectEqualSlices(u64, mirror.items, got);

        const encoded = try col.encode(gpa);
        defer gpa.free(encoded);
        const want = try hexDecode(gpa, step.hex);
        defer gpa.free(want);
        if (!std.mem.eql(u8, encoded, want)) {
            std.debug.print("cross_slab_fuzz_regression step {d}: the column encodes to {d} byte(s), the reference recorded {d}\n", .{
                k, encoded.len, want.len,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// `test/golden/hexane-regression.jsonl`, relative to the process working
/// directory. **Probed rather than assumed**, for the reason
/// [`codec_golden`] gives its own corpus: a unit test binary inherits the
/// directory it was started in, which is the package root under
/// `zig build test` and this file's own directory under a direct `zig test`.
const regression_paths = [_][]const u8{
    "test/golden/hexane-regression.jsonl",
    "../test/golden/hexane-regression.jsonl",
    "../../test/golden/hexane-regression.jsonl",
};

/// The trace's own size limit. One record, at most ten steps, and a step's
/// bytes are a slab's worth of runs — this is generous by orders of magnitude.
/// A limit rather than a bare read is what keeps a wrong path from reading a
/// directory tree.
const regression_limit: usize = 1 << 20;

/// One line of `test/golden/hexane-regression.jsonl`, as
/// `tools/oracle`'s `hexane-regression` subcommand records it.
///
/// **Every field has a default and unknown fields are ignored**, because the
/// oracle is free to grow a field: a new one must not stop this file from
/// reading the vector, and a missing one must not stop a record from being
/// read at all. The same rule `codec_golden.Record` is written under.
const RegressionRecord = struct {
    /// Always `hexane-regression`, and checked rather than assumed.
    kind: []const u8 = "",
    /// Always 799, and checked rather than assumed.
    seed: u64 = 0,
    /// The initial rows, the reference's own draws at `tests.rs:2717`.
    values: []const u64 = &.{},
    /// `max_segments` in **runs**, the reference's draw at `tests.rs:2718`.
    budget: usize = 0,
    /// One entry per splice that ran, in order. **The count is whatever
    /// ran**: upstream's loop breaks on an empty column (`:2724-2726`), so a
    /// short list is the record, not a truncated one.
    steps: []const Step = &.{},

    const Step = struct {
        /// Where the splice landed. A step's own number is its position in
        /// `steps`, not a field.
        index: usize = 0,
        /// Rows removed, counted from `index`.
        delete: usize = 0,
        /// Rows inserted at `index`, after the delete. Zero to three of them.
        insert: []const u64 = &.{},
        /// The reference column's rows **after** this step, `col.to_vec()`.
        expected: []const u64 = &.{},
        /// `col.save()` — the reference's canonical encoding of that same
        /// state, the bytes both implementations must agree on.
        hex: []const u8 = "",
    };
};

/// Reads the recorded trace, or returns `error.GoldenVectorsNotFound` naming
/// every path that was tried.
fn readRegressionTrace(gpa: std.mem.Allocator) ![]u8 {
    for (regression_paths) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(regression_limit)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
    }
    std.debug.print("hexane-regression.jsonl not found; tried", .{});
    for (regression_paths) |path| std.debug.print(" {s}", .{path});
    std.debug.print("\n", .{});
    return error.GoldenVectorsNotFound;
}

/// The bytes `hex` spells, for comparing against what the column encodes to.
/// Lowercase and unprefixed, which is what the oracle writes
/// (`tools/oracle/src/main.rs`, `hex_encode`), and this crate's own
/// [`hexFrom`] decodes exactly that.
fn hexDecode(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    return err.hexFrom(gpa, hex);
}

/// One round of [`cross_slab_fuzz`]: the run-budget column, compared against a
/// `Vec` model **after every single operation** rather than only at the end,
/// and against its own structural invariants.
///
/// **Every draw is upstream's draw, in upstream's order and over upstream's
/// ranges** (`:2750-2753`): the row count first, then one value a row, then the
/// budget — only the generator and the bounded reduction are ours, which is
/// what [`cross_slab_fuzz`] says at length. `name` is the calling case's own
/// name so a failure names the sweep it came from.
fn rleCrossSlabRound(gpa: std.mem.Allocator, seed: u64, name: []const u8) !void {
    const colmod = @import("column.zig");
    const RleU64 = colmod.Column(u64, colmod.Rle(u64));
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    const n = random.intRangeAtMost(usize, 0, 19) + 5;
    var values: [24]u64 = undefined;
    for (values[0..n]) |*v| v.* = random.intRangeAtMost(u64, 0, 4);
    const budget = random.intRangeAtMost(usize, 0, 5) + 3;

    var col = try RleU64.fromValues(gpa, values[0..n], budget);
    defer col.deinit();
    var mirror: std.ArrayList(u64) = .empty;
    defer mirror.deinit(gpa);
    try mirror.appendSlice(gpa, values[0..n]);

    for (0..10) |op| {
        const len = col.len();
        if (len == 0) break;
        const idx = random.intRangeAtMost(usize, 0, len - 1);
        const del = random.intRangeAtMost(usize, 0, @min(len - idx, 5));
        const ins_count = random.intRangeAtMost(usize, 0, 3);
        var inserted: [3]u64 = undefined;
        for (inserted[0..ins_count]) |*v| v.* = random.intRangeAtMost(u64, 0, 4);

        try col.splice(gpa, idx, del, inserted[0..ins_count]);
        try mirror.replaceRange(gpa, idx, del, inserted[0..ins_count]);

        // Upstream's `assert_eq!(col.to_vec(), mirror)` (`:2770`), run after
        // every operation rather than at the end of the round.
        const got = try col.toSlice(gpa);
        defer gpa.free(got);
        if (got.len != mirror.items.len or !std.mem.eql(u64, got, mirror.items) or col.len() != mirror.items.len) {
            std.debug.print("{s} seed {d} op {d}: budget {d}, the column holds {d}/{d} value(s), the model {d}\n", .{
                name, seed, op, budget, got.len, col.len(), mirror.items.len,
            });
            return error.TestExpectedEqual;
        }
        // And the layout: a run merged across a cut that should not have been,
        // or a slab left holding more runs than the budget, is the defect this
        // sweep exists for and it does not change what the column answers with.
        if (try col.checkInvariants()) |v| {
            if (v.detail_len != 0) {
                std.debug.print("{s} seed {d} op {d}: {s} ({s}, at {d})\n", .{ name, seed, op, v.what, v.detail(), v.at });
            } else {
                std.debug.print("{s} seed {d} op {d}: {s} (at {d})\n", .{ name, seed, op, v.what, v.at });
            }
            return error.TestUnexpectedResult;
        }
    }
}

test "byte_arena_cross_slab_fuzz" {
    // **A byte-budget sweep of the arena, which is a different case from
    // upstream's and is named as one.** A `RawColumn` has no values, only
    // bytes: the bytes spliced in are the bytes that come out
    // (`raw.rs:3-7`), so its budget is a *byte* count and a cut lands on a
    // **row boundary**. There is no run to merge across a seam and nothing to
    // re-encode canonically, and upstream's `cross_slab_fuzz` is about
    // precisely that — it is [`cross_slab_fuzz`] above, under upstream's name.
    //
    // **What this one covers that the run-budget column does not**: a splice
    // in byte coordinates, over at most twenty-four four-byte rows at a budget
    // of three to eight bytes, so every slab holds one or two rows and the
    // Fenwick tree over the byte lengths is re-walked on nearly every
    // operation. The op set's `value` column is this arena
    // (`op_set2/columns.rs:31`), so the sweep is a consumer's obligation too.
    //
    // **The seeds are pinned** over the same `0..1000` range, for the reason
    // `cross_slab_fuzz` gives.
    for (0..1000) |seed| try arenaCrossSlabRound(testing.allocator, seed);
}

/// One round of [`byte_arena_cross_slab_fuzz`], compared against a `Vec` model
/// **after every single operation** rather than only at the end.
///
/// **The coordinates are byte ones**, so the draws are the byte shapes the
/// arena admits: a position in rows turned into a byte offset, a delete capped
/// at five rows past it, and up to three four-byte words spliced in.
fn arenaCrossSlabRound(gpa: std.mem.Allocator, seed: u64) !void {
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
            std.debug.print("byte_arena seed {d} op {d}: the arena holds {d} byte(s), the model {d} row(s)\n", .{
                seed, op, col.len(), mirror.items.len,
            });
            return error.TestExpectedEqual;
        }
        try expectWords(&col, mirror.items);
    }
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

test "prepared point split empty and tail layouts publish with allocation refused" {
    // Abort must preserve borrowed bytes and release candidate ownership once.
    // Publication must not allocate for either point or structural handoff.
    const Case = struct {
        at: usize,
        del: usize,
        bytes: []const u8,
        want: []const u8,
        budget: usize = 4,
    };
    const cases = [_]Case{
        .{ .at = 4, .del = 0, .bytes = "XYZ", .want = "abcdXYZefgh" },
        .{ .at = 0, .del = 8, .bytes = "", .want = "" },
        .{ .at = 8, .del = 0, .bytes = "!", .want = "abcdefgh!" },
        .{ .at = 2, .del = 1, .bytes = "XYZ", .want = "abXYZdefgh", .budget = 32 },
        .{ .at = 2, .del = 3, .bytes = "", .want = "abfgh", .budget = 32 },
    };
    for (cases) |case| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var col = try RawColumn.loadWithMaxSegments(gpa, "abcdefgh", case.budget);
        defer col.deinit();
        const borrowed = try col.get(0, 8);
        var aborted = try col.stageSpliceSlice(case.at, case.del, case.bytes);
        aborted.deinit();
        aborted.deinit();
        try testing.expectEqualStrings("abcdefgh", borrowed);
        try expectArena(&col, gpa, "abcdefgh");
        var staged = try col.stageSpliceSlice(case.at, case.del, case.bytes);
        defer staged.deinit();
        try testing.expectEqualStrings("abcdefgh", borrowed);

        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        staged.publish(&col);
        try testing.expectEqual(case.want.len, col.len());
        for (case.want, 0..) |byte, pos| {
            try testing.expectEqual(byte, (try col.get(pos, pos + 1))[0]);
            var cursor = try col.iteratorAt(pos);
            try testing.expectEqual(byte, (try cursor.take(1))[0]);
            try testing.expectEqual(pos + 1, cursor.pos());
        }
        var end = try col.iteratorAt(col.len());
        try testing.expectEqualStrings("", try end.take(0));
        try testing.expectError(error.InvalidValue, end.take(1));
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        try expectArena(&col, gpa, case.want);
    }
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

fn rawOverlayMixedEdits(view: *RawColumn) !void {
    var first = try view.stageSpliceSlice(4, 4, "WXYZ");
    defer first.deinit();
    first.publish(view);
    try view.spliceSlice(5, 2, "!");
    try view.spliceChunks(view.len(), 0, &.{ "12", "34" });
    var aborted = try view.stageSpliceSlice(0, 4, "never");
    aborted.deinit();
}

test "raw overlay mixed projected edits preserve borrowed source until publish" {
    // Ordinary mutators must release provisional buffers, not borrowed source bytes.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var source = try RawColumn.withMaxSegments(gpa, 4);
    defer source.deinit();
    try source.spliceSlice(0, 0, "abcd");
    try source.spliceSlice(4, 0, "efgh");
    try source.spliceSlice(8, 0, "ijkl");
    const borrowed = source.slabs.items[1].data;
    const retained = source.slabs.items[0].data.ptr;
    var expected = try RawColumn.withMaxSegments(gpa, 4);
    defer expected.deinit();
    try expected.spliceSlice(0, 0, "abcd");
    try expected.spliceSlice(4, 0, "efgh");
    try expected.spliceSlice(8, 0, "ijkl");
    try rawOverlayMixedEdits(&expected);

    var overlay: RawColumn.Overlay = undefined;
    try source.beginOverlay(&overlay);
    defer overlay.deinit();
    var view: RawColumn = undefined;
    overlay.bind(&view);
    try rawOverlayMixedEdits(&view);
    try testing.expectEqualStrings("efgh", borrowed);
    try expectArena(&source, gpa, "abcdefghijkl");
    try expectSameArena(&view, &expected);
    for (view.slabs.items, expected.slabs.items) |got, want| {
        try testing.expectEqualSlices(u8, want.data, got.data);
    }
    for (view.bit.items.items, expected.bit.items.items) |got, want| {
        try testing.expectEqual(want.n, got.n);
    }
    try view.checkInvariants(gpa);
    overlay.capture(&view);
    overlay.bind(&view);
    const projected_bytes = try view.encode(gpa);
    defer gpa.free(projected_bytes);
    try testing.expectEqualStrings("abcdW!Zijkl1234", projected_bytes);
    overlay.capture(&view);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    overlay.publish(&source);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try expectSameArena(&source, &expected);
    try testing.expectEqual(retained, source.slabs.items[0].data.ptr);
    try source.checkInvariants(gpa);
}

test "raw overlay abort leaves source borrowed buffers and future edits usable" {
    const gpa = testing.allocator;
    var source = try RawColumn.loadWithMaxSegments(gpa, "abcdefghijkl", 4);
    defer source.deinit();
    const borrowed = try source.get(0, source.len());
    var overlay: RawColumn.Overlay = undefined;
    try source.beginOverlay(&overlay);
    var view: RawColumn = undefined;
    defer overlay.deinit();
    overlay.bind(&view);
    try rawOverlayMixedEdits(&view);
    overlay.deinit();
    overlay.deinit();
    try testing.expectEqualStrings("abcdefghijkl", borrowed);
    try expectArena(&source, gpa, "abcdefghijkl");
    try source.spliceSlice(4, 4, "OK");
    try expectArena(&source, gpa, "abcdOKijkl");
    try source.checkInvariants(gpa);
}

fn rawOverlayAllocationFailures(gpa: std.mem.Allocator, publish: bool) !void {
    var source = try RawColumn.withMaxSegments(gpa, 4);
    defer source.deinit();
    try source.spliceSlice(0, 0, "abcd");
    try source.spliceSlice(4, 0, "efgh");
    try source.spliceSlice(8, 0, "ijkl");
    const original_slabs = source.slabs.items.ptr;
    const original_tree = source.bit.items.items.ptr;
    const borrowed = source.slabs.items[1].data;
    var checking_original = true;
    errdefer if (checking_original) {
        std.debug.assert(source.len() == 12);
        std.debug.assert(source.slabs.items.ptr == original_slabs);
        std.debug.assert(source.bit.items.items.ptr == original_tree);
        std.debug.assert(std.mem.eql(u8, borrowed, "efgh"));
    };
    var overlay: RawColumn.Overlay = undefined;
    try source.beginOverlay(&overlay);
    defer overlay.deinit();
    var view: RawColumn = undefined;
    overlay.bind(&view);
    try rawOverlayMixedEdits(&view);
    try testing.expectEqualStrings("efgh", borrowed);
    overlay.capture(&view);
    checking_original = false;
    if (publish) {
        overlay.publish(&source);
        try expectArena(&source, testing.allocator, "abcdW!Zijkl1234");
        try source.checkInvariants(testing.allocator);
    } else {
        overlay.deinit();
        try testing.expectEqualStrings("efgh", borrowed);
        try expectArena(&source, testing.allocator, "abcdefghijkl");
        source.spliceSlice(4, 4, "OK") catch |failure| {
            try testing.expectEqual(@as(usize, 12), source.len());
            try testing.expectEqualStrings("efgh", borrowed);
            return failure;
        };
        try expectArena(&source, testing.allocator, "abcdOKijkl");
        try source.checkInvariants(testing.allocator);
    }
}

test "raw overlay multi edit publication survives every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        rawOverlayAllocationFailures,
        .{true},
    );
}

test "raw overlay abort and reuse survive every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        rawOverlayAllocationFailures,
        .{false},
    );
}

test "max_segments_zero_rejected" {
    // **Upstream's `Column::with_max_segments` floor
    // (`column.rs:1121-1126`), driven through `RawColumn.withMaxSegments`.**
    // A zero budget is refused at construction: no slab could ever be over
    // it, so the arena would fragment to one slab per splice point.
    //
    // **The bound differs and the port is the looser one here.** Upstream
    // requires `max_segments >= 2`; the arena refuses only zero
    // (`raw.zig:208`), because a one-byte slab is a degenerate but
    // well-formed layout. **The two floors count different things** — this
    // one is bytes per slab and upstream's is run segments — so refusing zero
    // here is not a laxer statement about the same quantity. The refusals of a
    // one-*segment* budget are `column.zig`'s, under their upstream names:
    // `max_segments_one_rejected` and `max_segments_one_rejected_at_load`,
    // over `initWithBudget` and `LoadOpts.withMaxSegments`.
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
// * **Six of the seven `cross_slab_*` cases are this file's cases wearing
//   upstream's names; the seventh is upstream's own.** Upstream builds a
//   `Column<u64>` with a small *segment* budget and splices across the seams;
//   the drain-across-slabs, the seam choice (`pickSplit`, `raw.zig:730-737`)
//   and the coalescing that follows are written once, here, from `raw.rs`, and
//   they are the same code paths either kind of column walks. **The rows here
//   are 4-byte words, so the weights are bytes and the budget is a runtime
//   argument** — a `Column<u64>` cut at four segments is a *different* cut.
//
//   **`cross_slab_fuzz` and `cross_slab_fuzz_regression` are that exception,
//   and they are not substitutes any more.** They build a real
//   `Column(u64, Rle(u64))` at the run budget drawn per seed (`3..=8` runs,
//   `tests.rs:2752`), because upstream's budget counts **runs**: three runs
//   against a `0..=4` value stream cuts inside the run sequence, and the whole
//   case is that the runs either side of a cut carry the same value and have to
//   merge and re-encode canonically. A byte budget cuts on a row boundary and
//   has neither. **The arena sweep is kept, under its own name**
//   (`byte_arena_cross_slab_fuzz`), because a splice in byte coordinates at
//   one or two rows a slab is this file's own obligation — it is the op set's
//   `value` column (`op_set2/columns.rs:31`) — and `column.zig` cannot reach
//   it.
//
// * **`cross_slab_fuzz_regression` is a replay, and the trace is recorded.**
//   Its op list is `test/golden/hexane-regression.jsonl`, which `tools/oracle`'s
//   `hexane-regression` subcommand draws from upstream's own `SmallRng` and
//   records step by step — because the port cannot re-draw 799. `SmallRng` and
//   `std.Random.DefaultPrng` are the **same** generator on a 64-bit target
//   (Xoshiro256++, `rngs/small.rs:15` and `Random.zig:13`) and part at the
//   **seed expansion** — PCG32 in `rand_core` (`seedable_rng.rs:109-121`) against
//   SplitMix64 in Zig (`Random/Xoshiro256.zig:57-65`) — not at the algorithm.
//   The 1000-seed sweep keeps its own pinned seeds; what it substitutes is the
//   sample, not the property.
//
// * **`max_segments_zero_rejected` covers the zero case; the one case is
//   `column.zig`'s.** Upstream's assert is `max_segments >= 2`
//   (`column.rs:1121-1126`); the arena refuses only zero (`raw.zig:208`),
//   because a one-byte slab is degenerate but well formed. **A byte budget and
//   a run-segment budget are different quantities**, so the looser floor here is
//   not a laxer version of the same rule. `max_segments_one_rejected` and
//   `max_segments_one_rejected_at_load` are declared there, over
//   `initWithBudget` and `LoadOpts.withMaxSegments`.
//
// * **`fuzz_slab_merge_invariant` is not declared in this file, and the arena is
//   the wrong place for it.** Upstream asserts a *global* postcondition — no
//   undersized slab anywhere has a neighbour pair that would still fit
//   (`tests.rs:4022-4054`). `canMerge` states the same rule, but this file
//   applies it **only to the boundaries around a splice**
//   (`stageSpliceSlice`), deliberately never globally, so a port here would
//   have to weaken the case into a per-boundary predicate, and a weaker
//   assertion wearing the same name would prove less. The postcondition is
//   asserted where the quantity in it exists: `column.zig`'s
//   `mergeableNeighbours` is upstream's predicate — `min_seg = budget / 4`, and
//   `prev + cur <= budget` — walked over every adjacent pair
//   (`column.zig:6302-6312`), and `expectSound` runs it after every splice in
//   the boolean, integer, nullable, delta and prefix codecs. **What differs is
//   the sweep behind it**, which is short of upstream's 200 trials of 500
//   operations, and a reported `error` stands in for its `panic!`.
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
// ## Where per-case occurrence status lives
//
// **This file keeps no tally of upstream cases, and that is deliberate.** It
// did, and the number went stale every time another file gained a case: a
// name-presence list is a second instrument, it drifts, and the port renames
// ported cases into English, so it under-counts what is actually asserted.
// Per-case status, module-qualified ids, exclusion kinds, and the mapping from
// an upstream case to a Zig declaration are owned by
// `docs/hexane-cases.json`, pinned to the reference commit; the denominator is
// published once, in `docs/STATUS.md`.
//
// What stays here is the half a tally cannot carry: **where a blocked case
// would be unblocked**, and why this file is the wrong home for it. Three
// facts do that work, and none of them is a name — the arena's budget is bytes
// per slab where `column.zig`'s is run segments, `canMerge` is a predicate to
// ask at a splice boundary rather than a postcondition to assert globally, and
// a codec file has no `Column` to hand a load option to. The bullets above
// name each remaining case and the surface that owns it.
