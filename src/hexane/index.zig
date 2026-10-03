//! The per-slab weight index a column maintains
//! (`rust/hexane/src/index.rs`).
//!
//! Upstream's `ColumnIndex<W>` is a trait with two implementations: a Fenwick
//! tree (`BitIndex`, `index.rs:67-120`) and the B-tree
//! (`btree::SlabBTree`, `index.rs:126-153`). Both store one weight per slab
//! and answer positional queries in O(log n). The Fenwick is the faster of the
//! two for plain lookups but needs an invertible aggregate, which is why the
//! B-tree is the one a delta column uses — its `min`/`max` cannot be
//! subtracted (`index.rs:1-14`).
//!
//! In Zig the trait is a set of method names rather than a type: the two
//! backends are concrete types offering the same six operations, and this file
//! maps each operation to where it lives.
//!
//! | `ColumnIndex` (`index.rs:27-59`) | `BitIndex(W)` | `btree.Tree(SlabAgg)` |
//! | --- | --- | --- |
//! | `from_weights` (`index.rs:29`) | `fromWeights` | `fromSlice` |
//! | `len` (`index.rs:31`) | `len` | `len` |
//! | `is_empty` (`index.rs:35`) | `isEmpty` | `isEmpty` |
//! | `find_slab` (`index.rs:43`) | `findSlab` | `findByPrefix` |
//! | `items_before` (`index.rs:49`) | `itemsBefore` | `itemsBeforeSlab` |
//! | `update_slab` (`index.rs:53`) | `updateSlab` | `updateSlab` |
//! | `splice` (`index.rs:58`) | `splice` | `splice` |
//!
//! Nothing dispatches through a vtable: `column.zig` instantiates the B-tree
//! directly and the byte arena instantiates the Fenwick directly, so a vtable
//! with no polymorphic caller would be scaffolding. The agreement between the
//! two backends is a test instead — a positional query answered two ways has
//! to give the same answer, and that is exactly what either implementation
//! could get wrong alone.
//!
//! # The weight contract
//!
//! `W` is a port weight: a struct carrying an `Aggregate` namespace with
//! `identity`, `merge`, `itemCount` and `eql` — the shape `column.zig` and
//! `btree.zig` already use, and the port's form of upstream's `SlabWeight`
//! (`column.rs:53-70`). Two properties of that contract matter here:
//!
//! * `itemCount` is the additive component, and the Fenwick's prefix query
//!   only ever reads it — never a prefix sum (`index.rs:96-106`).
//! * `merge(identity, w) == w`, which is how an ancestor's total is
//!   reconstructed from a child that was just folded in
//!   (`column.rs:154-159`).
//!
//! A Fenwick additionally needs a *subtraction*, which `Aggregate` does not
//! carry: `bit_point_update` adjusts every ancestor of a slab by the weight
//! change (`column.rs:168-175`), while the B-tree recomputes a node's total
//! from its children instead (`btree.rs:1014-1025`). Upstream spells the same
//! requirement as `SlabWeight: AddAssign + SubAssign` (`column.rs:53`), so
//! [`Fenwick`] requires `W.Aggregate.sub` and says so at compile time. `Bytes`
//! is the weight that carries one.

const std = @import("std");
const btree = @import("btree.zig");

/// What the two position-checked operations refuse: a slab position outside
/// the index, which upstream treats as a panic, and the allocator. Local,
/// like `btree.zig`'s `TreeError`.
///
/// Only `updateSlab` and `splice` use it, because only they take a position
/// the caller could get wrong. Everything else here either allocates or
/// answers, and answers with `std.mem.Allocator.Error` so a caller that only
/// builds and queries — the byte arena, whose every index operation is a
/// rebuild or a lookup — can return the parser's set without carrying a slab
/// error it can never produce.
pub const IndexError = error{ InvalidIndex, OutOfMemory };
/// The weight of a byte-arena slab: its byte length, which is also its item
/// count. Upstream's is `usize` itself (`column.rs:65-70`); this is the same
/// number with the weight contract attached.
pub const Bytes = struct {
    /// The slab's byte length.
    n: usize = 0,

    /// The weight of no slabs at all.
    pub const zero: Bytes = .{};

    /// The weight contract the two index backends consume. `identity`,
    /// `merge`, `itemCount` and `eql` are the shared shape described under
    /// "The weight contract" above; `sub` is the Fenwick's extra and the
    /// reason this weight is not one of `column.zig`'s.
    pub const Aggregate = struct {
        /// The weight of no slabs at all.
        pub const identity: Bytes = .zero;
        /// The weight of two adjacent spans, in order.
        pub fn merge(l: Bytes, r: Bytes) Bytes {
            return .{ .n = l.n + r.n };
        }
        /// `a - b`. A Fenwick tree needs it and a B-tree does not, which is
        /// why it lives here and not in the shared contract: see the module
        /// docs.
        pub fn sub(a: Bytes, b: Bytes) Bytes {
            return .{ .n = a.n - b.n };
        }
        /// How many column rows the weight covers. For a byte slab that is
        /// its byte length, so it is both counts at once.
        pub fn itemCount(w: Bytes) usize {
            return w.n;
        }
        /// Whether two weights describe the same span.
        pub fn eql(a: Bytes, b: Bytes) bool {
            return a.n == b.n;
        }
    };
};

/// Where a positional search landed: the slab holding the item, and that
/// item's offset inside it. `find_slab_bit` answers exactly this shape
/// (`column.rs:301-321`).
pub const SlabPos = struct {
    /// The slab the item is in.
    slab: usize,
    /// The item's offset inside that slab.
    offset: usize,
};

/// The weight reader `Fenwick.rebuild` uses: a slice indexed by slab.
fn weightOfSlice(comptime W: type) fn ([]const W, usize) W {
    return struct {
        fn f(weights: []const W, i: usize) W {
            return weights[i];
        }
    }.f;
}

/// A Fenwick tree over per-slab weights: the array a byte arena indexes
/// itself with (`BitIndex`'s `bit`, `index.rs:67-70`).
///
/// One-indexed, as upstream: `items[0]` is unused and `items[1..=n]` holds
/// the tree (`column.rs:142-143`). The weight cache `BitIndex` keeps beside
/// it is not part of this type, because a caller that holds the slabs reads
/// each weight off its slab — which is why the rebuild helper takes a reader
/// rather than a slice (`column.rs:144-146`).
pub fn Fenwick(comptime W: type) type {
    return struct {
        const Self = @This();

        /// The allocator the tree is allocated and released with: the one
        /// `init` was given. `deinit` releases the tree, not the allocator.
        /// A per-call allocator — `rebuildFrom`'s and `rebuild`'s — has to
        /// be this one: the tree it reserves with it is handed back to
        /// `deinit`, which frees it with `self.gpa`.
        gpa: std.mem.Allocator,
        /// The tree, one-indexed. It always holds at least the unused slot,
        /// so a fresh tree can answer a query over no slabs.
        items: std.ArrayList(W),

        /// A tree over no slabs, holding just the unused slot — upstream's
        /// `bit: vec![0]` (`index.rs:75`).
        pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var self = Self{ .gpa = gpa, .items = .empty };
            errdefer self.items.deinit(gpa);
            try self.items.append(gpa, W.Aggregate.identity);
            return self;
        }

        /// Frees the tree.
        pub fn deinit(self: *Self) void {
            self.items.deinit(self.gpa);
            self.* = undefined;
        }

        /// How many slabs are indexed. The unused slot is not one of them.
        pub fn len(self: *const Self) usize {
            return self.items.items.len - 1;
        }

        /// Whether no slabs are indexed.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// The slab holding the `index`-th item, and that item's offset
        /// inside it, by binary lifting over the tree (`find_slab_bit`,
        /// `column.rs:301-321`). O(log S).
        ///
        /// An `index` equal to the total answers `(n, 0)`, the past-end
        /// sentinel the arena's append path relies on. An `index` *past* the
        /// total is outside the contract: the lift keeps stepping, so the
        /// offset comes back as `index - total` rather than 0, and that is
        /// upstream's own behaviour (`column.rs:312-320`). Every caller
        /// bounds-checks first — `RawColumn.spliceSlice` and
        /// `RawColumn.get` — which is why the divergence never shows. The
        /// B-tree answers the same out-of-contract query as `(n, 0)`, because
        /// it maps "no slab found" to the sentinel outright
        /// (`index.rs:136-140`).
        ///
        /// A slab of weight zero is stepped over rather than landed on,
        /// because the lift accepts a node whose running total still does not
        /// reach `index` — the same condition the B-tree's
        /// `remaining < count` loop uses (`btree.rs:1203-1212`).
        pub fn findSlab(self: *const Self, index: usize) SlabPos {
            const n = self.len();
            if (n == 0) return .{ .slab = 0, .offset = 0 };
            // The highest power of two that fits in `n`. Computed against
            // `n / 2` so the doubling cannot overflow on a slab count near
            // `maxInt`.
            var step: usize = 1;
            while (step <= n / 2) step *= 2;
            var pos: usize = 0;
            var idx: usize = 0;
            while (step > 0) {
                const next = idx + step;
                if (next <= n) {
                    // `pos` and this node's count are disjoint prefixes and
                    // suffixes of the same weights, so the sum cannot exceed
                    // the total the tree was built from.
                    const acc = pos + W.Aggregate.itemCount(self.items.items[next]);
                    if (acc <= index) {
                        pos = acc;
                        idx = next;
                    }
                }
                step >>= 1;
            }
            return .{ .slab = idx, .offset = index - pos };
        }

        /// The item count of the first `count` slabs (`index.rs:96-106`).
        ///
        /// A standard BIT prefix query, and it only ever adds `itemCount`: a
        /// prefix weight's running sum is not part of the answer. A `count`
        /// past the end answers the total, which is what the walk runs out
        /// of; upstream asserts it never happens (`index.rs:100`), and the
        /// port clamps so both backends answer a past-end query alike.
        pub fn prefixQuery(self: *const Self, count: usize) usize {
            var acc: usize = 0;
            var i = @min(count, self.len());
            while (i > 0) : (i -= i & (0 -% i)) {
                acc += W.Aggregate.itemCount(self.items.items[i]);
            }
            return acc;
        }

        /// Replaces the weight of slab `si` in O(log S), by removing the old
        /// weight and adding the new one at every ancestor node
        /// (`bit_point_update`, `column.rs:168-175`).
        ///
        /// The caller supplies the old weight because a caller holding the
        /// slabs — rather than a weight cache — reads it off the slab it just
        /// rewrote (`raw.rs:255`).
        ///
        /// `si` has to name a slab the tree holds, `si < len()`. There is no
        /// error channel: a position at or past the end has no ancestor
        /// node to fold the change into, so the walk never runs and the call
        /// is a silent no-op that leaves the tree describing the old weight.
        /// [`BitIndex.updateSlab`](BitIndex) checks the bound first and
        /// reports `error.InvalidIndex` for the same mistake, so a caller
        /// holding an index should go through it. The one caller that keeps
        /// the tree on its own — the byte arena's splice, which rewrote the
        /// slab it is naming — is inside that bound by construction.
        pub fn pointUpdate(self: *Self, si: usize, old: W, new: W) void {
            // A precondition, not validation of hostile input: a released
            // caller is a bug, and `si + 1` below must stay in range.
            std.debug.assert(si < self.len());
            var i = si + 1; // the tree is one-indexed
            while (i < self.items.items.len) {
                self.items.items[i] = W.Aggregate.sub(W.Aggregate.merge(self.items.items[i], new), old);
                i += i & (0 -% i);
            }
        }

        /// Rebuilds the tree from `n` weights read out of `ctx` one at a
        /// time, in O(S) (`rebuild_bit`, `column.rs:147-162`).
        ///
        /// The reader rather than a slice is upstream's own shape: the helper
        /// is handed the slabs and an extractor, so a column passes its weight
        /// function and the byte arena passes a slab length
        /// (`column.rs:144-146`). Reading one weight at a time keeps that
        /// shape without a temporary array.
        ///
        /// **Failure leaves the tree as it was.** The whole new tree is
        /// reserved before the old one is dropped, so `error.OutOfMemory`
        /// cannot leave a tree that is shorter than the weights it was built
        /// from — which would make every later query answer as though the
        /// index held fewer slabs than it does. Nothing is allocated after
        /// that point, and `gpa` has to be the tree's own allocator: the
        /// storage reserved here is released by `deinit` with `self.gpa`.
        pub fn rebuildFrom(
            self: *Self,
            gpa: std.mem.Allocator,
            ctx: anytype,
            n: usize,
            comptime weightOf: fn (@TypeOf(ctx), usize) W,
        ) std.mem.Allocator.Error!void {
            try self.items.ensureTotalCapacity(gpa, n + 1);
            self.items.clearRetainingCapacity();
            self.items.appendAssumeCapacity(W.Aggregate.identity);
            var i: usize = 0;
            while (i < n) : (i += 1) self.items.appendAssumeCapacity(weightOf(ctx, i));
            // Standard O(n) construction: every node hands its total to its
            // parent, so each node ends up holding the sum of its span.
            var j: usize = 1;
            while (j <= n) : (j += 1) {
                const parent = j + (j & (0 -% j));
                if (parent <= n) {
                    self.items.items[parent] = W.Aggregate.merge(self.items.items[parent], self.items.items[j]);
                }
            }
        }

        /// Rebuilds the tree from a slice of weights, in O(S). As
        /// `rebuildFrom`, failure leaves the tree as it was.
        pub fn rebuild(self: *Self, gpa: std.mem.Allocator, weights: []const W) std.mem.Allocator.Error!void {
            return self.rebuildFrom(gpa, weights, weights.len, weightOfSlice(W));
        }
    };
}

/// The Fenwick-backed `ColumnIndex`: a weight cache beside the tree, so a
/// point update can read the weight it is replacing (`index.rs:63-70`).
///
/// The byte arena holds only the tree — [`Fenwick`] — because it reads each
/// weight off its slab. This is the shape an index takes when its caller would
/// rather keep the weights than the slabs.
///
/// The cache and the tree are one answer kept twice: `len`, `isEmpty` and
/// `updateSlab` read the cache, `findSlab` and `itemsBefore` walk the tree,
/// and a caller that sees one count sees the other's. Every mutating
/// operation stages its allocations first, so no reachable state has the
/// two halves describing different slab counts.
pub fn BitIndex(comptime W: type) type {
    return struct {
        const Self = @This();

        /// The allocator both halves are allocated and released with. Not
        /// released itself: it is the caller's.
        gpa: std.mem.Allocator,
        /// One weight per slab, in slab order. The old value of a point
        /// update is read from here (`index.rs:111`).
        weights: std.ArrayList(W),
        /// The tree the positional queries walk. Its slab count always
        /// equals `weights.items.len`.
        bit: Fenwick(W),

        /// An index over no slabs.
        pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return .{ .gpa = gpa, .weights = .empty, .bit = try Fenwick(W).init(gpa) };
        }

        /// Frees the weight cache and the tree.
        pub fn deinit(self: *Self) void {
            self.weights.deinit(self.gpa);
            self.bit.deinit();
            self.* = undefined;
        }

        /// An index over `weights`, in slab order (`from_weights`,
        /// `index.rs:84-88`).
        pub fn fromWeights(gpa: std.mem.Allocator, weights: []const W) std.mem.Allocator.Error!Self {
            var self = try Self.init(gpa);
            errdefer self.deinit();
            try self.weights.appendSlice(gpa, weights);
            try self.bit.rebuild(gpa, weights);
            return self;
        }

        /// How many slabs are indexed.
        pub fn len(self: *const Self) usize {
            return self.weights.items.len;
        }

        /// Whether no slabs are indexed.
        pub fn isEmpty(self: *const Self) bool {
            return self.weights.items.len == 0;
        }

        /// The slab holding the `index`-th item, and that item's offset
        /// inside it. At the total it answers `(len(), 0)`.
        pub fn findSlab(self: *const Self, index: usize) SlabPos {
            return self.bit.findSlab(index);
        }

        /// The number of items in the slabs before `slab_idx` — the inverse
        /// of `findSlab` (`index.rs:97-108`).
        pub fn itemsBefore(self: *const Self, slab_idx: usize) usize {
            return self.bit.prefixQuery(slab_idx);
        }

        /// Replaces the weight of slab `slab_idx`, in O(log S)
        /// (`update_slab`, `index.rs:110-114`).
        pub fn updateSlab(self: *Self, slab_idx: usize, new_weight: W) IndexError!void {
            if (slab_idx >= self.weights.items.len) return error.InvalidIndex;
            const old = self.weights.items[slab_idx];
            self.weights.items[slab_idx] = new_weight;
            self.bit.pointUpdate(slab_idx, old, new_weight);
        }

        /// Replaces the weights of slabs `start..end` with `new_weights`
        /// (`splice`, `index.rs:116-119`). Time is O(S + N), where S and N
        /// are the old and resulting slab counts: replacement shifts the
        /// cache's suffix and the whole resulting Fenwick tree is rebuilt.
        /// Growth reserves O(N) storage; neither buffer is cloned.
        ///
        /// `start > end` or `end > len()` returns `error.InvalidIndex`.
        /// An unrepresentable storage size or a refused allocation returns
        /// `error.OutOfMemory`. On error, weights, slab counts and all
        /// positional answers remain unchanged, but capacity may grow and
        /// storage may move. Both buffers are reserved before replacement,
        /// so publication and the capacity-guaranteed rebuild cannot fail.
        /// `new_weights` is copied and must not alias the index's storage.
        pub fn splice(self: *Self, start: usize, end: usize, new_weights: []const W) IndexError!void {
            if (start > end or end > self.weights.items.len) return error.InvalidIndex;
            const kept = self.weights.items.len - (end - start);
            const new_len = std.math.add(usize, kept, new_weights.len) catch return error.OutOfMemory;
            const tree_len = std.math.add(usize, new_len, 1) catch return error.OutOfMemory;
            try self.weights.ensureTotalCapacity(self.gpa, new_len);
            try self.bit.items.ensureTotalCapacity(self.gpa, tree_len);
            self.weights.replaceRangeAssumeCapacity(start, end - start, new_weights);
            // The rebuild's reservation is already satisfied; no allocation
            // remains after the cache publishes the new weight sequence.
            self.bit.rebuild(self.gpa, self.weights.items) catch unreachable;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A slab of `len` items reaching prefix `total`, the weight a monotonic
/// column stores. `itemCount` is the same `len`, so the two backends answer
/// the same queries for the same sequence of slabs.
fn agg(len: usize, total: usize) btree.SlabAgg {
    return btree.SlabAgg.monotone(len, total);
}

/// Where a plain prefix-sum walk says the `index`-th item is. The reference
/// for both backends: the answer comes from neither of them.
fn referencePos(weights: []const Bytes, index: usize) SlabPos {
    var before: usize = 0;
    for (weights, 0..) |w, i| {
        if (index < before + w.n) return .{ .slab = i, .offset = index - before };
        before += w.n;
    }
    return .{ .slab = weights.len, .offset = 0 };
}

fn referenceBefore(weights: []const Bytes, slab_idx: usize) usize {
    var before: usize = 0;
    var i: usize = 0;
    while (i < slab_idx and i < weights.len) : (i += 1) before += weights[i].n;
    return before;
}

test "a fresh tree is empty and answers the past-end sentinel" {
    const gpa = testing.allocator;
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try testing.expect(bit.isEmpty());
    try testing.expectEqual(@as(usize, 0), bit.len());
    // Nothing is indexed, so a query cannot land anywhere (`column.rs:302-304`).
    try testing.expectEqual(SlabPos{ .slab = 0, .offset = 0 }, bit.findSlab(0));
    try testing.expectEqual(@as(usize, 0), bit.prefixQuery(0));
}

test "the tree answers every item boundary of its slabs" {
    const gpa = testing.allocator;
    const weights = [_]usize{ 3, 0, 5, 1, 4, 2, 7 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try bit.rebuild(gpa, &bytes);

    try testing.expectEqual(weights.len, bit.len());
    const total: usize = 22;
    for (0..total + 1) |index| {
        try testing.expectEqual(referencePos(&bytes, index), bit.findSlab(index));
    }
    // The last byte belongs to the last non-empty slab, and the byte at the
    // total is the past-end sentinel.
    try testing.expectEqual(SlabPos{ .slab = 6, .offset = 6 }, bit.findSlab(21));
    try testing.expectEqual(SlabPos{ .slab = 7, .offset = 0 }, bit.findSlab(22));
}

test "the prefix query answers the running total of the slabs before it" {
    const gpa = testing.allocator;
    const weights = [_]usize{ 4, 6, 2, 8, 1 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try bit.rebuild(gpa, &bytes);

    for (0..weights.len + 1) |slab_idx| {
        try testing.expectEqual(referenceBefore(&bytes, slab_idx), bit.prefixQuery(slab_idx));
    }
    // A slab count past the end answers the total rather than reading out of
    // the tree; upstream asserts it never happens (`index.rs:100`).
    try testing.expectEqual(@as(usize, 21), bit.prefixQuery(weights.len + 3));
}

test "a point update lands where a rebuild would put it" {
    const gpa = testing.allocator;
    const weights = [_]usize{ 4, 6, 2, 8, 1, 3, 5 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try bit.rebuild(gpa, &bytes);

    var changed = [_]usize{ 4, 6, 2, 8, 1, 3, 5 };
    changed[3] = 11;
    changed[0] = 1;
    bit.pointUpdate(3, .{ .n = 8 }, .{ .n = 11 });
    bit.pointUpdate(0, .{ .n = 4 }, .{ .n = 1 });

    var fresh_bytes: [weights.len]Bytes = undefined;
    for (changed, 0..) |w, i| fresh_bytes[i] = .{ .n = w };
    var fresh = try Fenwick(Bytes).init(gpa);
    defer fresh.deinit();
    try fresh.rebuild(gpa, &fresh_bytes);

    // Node for node, not just in total: a wrong ancestor would still sum
    // right at the root.
    try testing.expectEqualSlices(Bytes, fresh.items.items, bit.items.items);
    for (0..changed.len + 1) |index| {
        try testing.expectEqual(referencePos(&fresh_bytes, index), bit.findSlab(index));
    }
    try testing.expectEqual(referenceBefore(&fresh_bytes, changed.len), bit.prefixQuery(changed.len));
}

test "a slab that shrinks and one that grows both adjust the tree" {
    const gpa = testing.allocator;
    const weights = [_]usize{ 4, 6, 2, 8, 1, 3, 5 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try bit.rebuild(gpa, &bytes);

    // Shrinking to nothing and growing past every other slab, in one tree, so
    // a subtraction that ran the wrong way or an addition that ran twice
    // would show up as a total that is wrong rather than as a wrong slab.
    bit.pointUpdate(0, .{ .n = 4 }, .{ .n = 0 });
    bit.pointUpdate(6, .{ .n = 5 }, .{ .n = 100 });
    var fresh_bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| fresh_bytes[i] = .{ .n = w };
    fresh_bytes[0] = .{ .n = 0 };
    fresh_bytes[6] = .{ .n = 100 };
    var fresh = try Fenwick(Bytes).init(gpa);
    defer fresh.deinit();
    try fresh.rebuild(gpa, &fresh_bytes);
    try testing.expectEqualSlices(Bytes, fresh.items.items, bit.items.items);
    try testing.expectEqual(@as(usize, 120), bit.prefixQuery(weights.len));
}

test "the bit index keeps its cache and its tree in step" {
    const gpa = testing.allocator;
    const weights = [_]usize{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var idx = try BitIndex(Bytes).fromWeights(gpa, &bytes);
    defer idx.deinit();

    try testing.expectEqual(weights.len, idx.len());
    try testing.expect(!idx.isEmpty());
    try testing.expectEqual(@as(usize, 20), idx.itemsBefore(4));
    try testing.expectEqual(SlabPos{ .slab = 2, .offset = 1 }, idx.findSlab(11));

    try idx.updateSlab(2, .{ .n = 9 });
    try testing.expectEqual(Bytes{ .n = 9 }, idx.weights.items[2]);
    try testing.expectEqual(@as(usize, 10), idx.itemsBefore(2));
    try testing.expectEqual(SlabPos{ .slab = 2, .offset = 5 }, idx.findSlab(15));

    // A structural change rebuilds the tree, because a Fenwick has no way to
    // absorb one in O(log S) (`index.rs:116-119`).
    try idx.splice(0, 3, &.{ .{ .n = 2 }, .{ .n = 2 } });
    try testing.expectEqual(weights.len - 1, idx.len());
    try testing.expectEqual(@as(usize, 2), idx.itemsBefore(1));
    try testing.expectEqual(@as(usize, 4), idx.itemsBefore(2));
    // The tree still answers positions, not just totals, after a rebuild.
    const total = referenceBefore(idx.weights.items, idx.len());
    for (0..total + 1) |index| {
        try testing.expectEqual(referencePos(idx.weights.items, index), idx.findSlab(index));
    }

    try testing.expectError(error.InvalidIndex, idx.updateSlab(idx.len(), .{ .n = 1 }));
    try testing.expectError(error.InvalidIndex, idx.splice(0, idx.len() + 1, &.{}));
}

test "both index backends answer a positional query the same way" {
    const gpa = testing.allocator;
    // A different slab count and a different weight sequence every round, so
    // the sweep crosses a single-slab tree, the B=64 branch factor and a tree
    // three levels deep, with weights that include zero and weights that do
    // not.
    var prng: std.Random.DefaultPrng = .init(0x1D3C);
    const random = prng.random();
    for (0..8) |round| {
        const n = 1 + round * 47;
        const bytes = try gpa.alloc(Bytes, n);
        defer gpa.free(bytes);
        const aggs = try gpa.alloc(btree.SlabAgg, n);
        defer gpa.free(aggs);

        var running: usize = 0;
        for (bytes, aggs) |*b, *a| {
            b.* = .{ .n = random.intRangeAtMost(usize, 0, 9) };
            running += b.n;
            a.* = agg(b.n, running);
        }

        var bit = try BitIndex(Bytes).fromWeights(gpa, bytes);
        defer bit.deinit();
        var tree = try btree.SlabBTree.fromSlice(gpa, aggs);
        defer tree.deinit();

        try testing.expectEqual(tree.len(), bit.len());
        for (0..running + 1) |index| {
            const want = referencePos(bytes, index);
            const via_bit = bit.findSlab(index);
            try testing.expectEqual(want.slab, via_bit.slab);
            try testing.expectEqual(want.offset, via_bit.offset);

            // The tree reports the slab and the items before it; the offset is
            // what is left of the index (`index.rs:135-140`).
            const via_tree = tree.findByPrefix(index);
            if (via_tree) |hit| {
                try testing.expectEqual(via_bit.slab, hit.slab);
                try testing.expectEqual(via_bit.offset, index - hit.items_before);
            } else {
                try testing.expectEqual(bit.len(), via_bit.slab);
                try testing.expectEqual(@as(usize, 0), via_bit.offset);
            }
        }
        for (0..n + 2) |slab_idx| {
            try testing.expectEqual(tree.itemsBeforeSlab(@min(slab_idx, n)), bit.itemsBefore(slab_idx));
        }
    }
}

test "a zero-weight slab is stepped over, not landed on" {
    const gpa = testing.allocator;
    // Upstream accepts a lift node whose running total still does not reach
    // the index, so a slab of weight zero is passed (`column.rs:314-317`).
    const weights = [_]usize{ 2, 0, 3 };
    var bytes: [weights.len]Bytes = undefined;
    for (weights, 0..) |w, i| bytes[i] = .{ .n = w };
    var bit = try Fenwick(Bytes).init(gpa);
    defer bit.deinit();
    try bit.rebuild(gpa, &bytes);

    try testing.expectEqual(SlabPos{ .slab = 0, .offset = 0 }, bit.findSlab(0));
    try testing.expectEqual(SlabPos{ .slab = 0, .offset = 1 }, bit.findSlab(1));
    try testing.expectEqual(SlabPos{ .slab = 2, .offset = 0 }, bit.findSlab(2));
    try testing.expectEqual(SlabPos{ .slab = 2, .offset = 2 }, bit.findSlab(4));
    // And the B-tree steps over it the same way.
    var aggs = [_]btree.SlabAgg{ agg(2, 2), agg(0, 2), agg(3, 5) };
    var tree = try btree.SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();
    try testing.expectEqual(@as(?usize, 2), if (tree.findByPrefix(2)) |hit| hit.slab else null);
}

test "index_items_before_parity" {
    // **`tests.rs:4639-4669`.** For a column cut into several slabs, both
    // index backends report `items_before(i)` as the running sum of the
    // column's slab lengths, and `items_before(n)` as the total.
    //
    // **The weights come from a real fragmented arena, not from a
    // generator.** Upstream's are `Column::<u64>::from_values_with_max_segments(0..500, 4).slab_lens()`
    // (`tests.rs:4644-4645`), and this test's are the byte lengths a
    // `RawColumn` cut by `withMaxSegments` really produced — the same weights
    // `Bytes` exists for (`index.zig:68-70`). **The unit differs and the claim
    // does not**: upstream's are run counts of a typed column, whose index is
    // `column.zig`'s, and a column cut across slabs is not covered here.
    //
    // **Each backend is checked against the lengths themselves, not against
    // the other backend.** That is upstream's assertion and it is the one the
    // sweep above does *not* make: `both index backends answer a positional
    // query the same way` (`index.zig:521-570`) feeds both random weights and
    // compares them to each other, so two backends that agreed on the wrong
    // answer would pass it.
    const gpa = testing.allocator;
    const raw = @import("raw.zig");

    var col = try raw.RawColumn.withMaxSegments(gpa, 12);
    defer col.deinit();
    // Fifty real rows, four bytes each, appended one at a time so the budget
    // is what cuts them.
    for (0..50) |i| {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, @intCast(i * 37 % 1000), .big);
        try col.spliceSlice(i * 4, 0, &word);
    }
    // Upstream's own guard: with one slab there is nothing to be in parity
    // about.
    try testing.expect(col.slabCount() > 1);

    var lens: std.ArrayList(usize) = .empty;
    defer lens.deinit(gpa);
    var weights: std.ArrayList(Bytes) = .empty;
    defer weights.deinit(gpa);
    var aggs: std.ArrayList(btree.SlabAgg) = .empty;
    defer aggs.deinit(gpa);

    var running: usize = 0;
    for (0..col.slabCount()) |i| {
        const n = (col.slabAt(i) orelse return error.TestUnexpectedResult).data.len;
        try lens.append(gpa, n);
        try weights.append(gpa, .{ .n = n });
        running += n;
        try aggs.append(gpa, agg(n, running));
    }

    var bit = try BitIndex(Bytes).fromWeights(gpa, weights.items);
    defer bit.deinit();
    var tree = try btree.SlabBTree.fromSlice(gpa, aggs.items);
    defer tree.deinit();
    try tree.assertSound();

    // The Fenwick's `prefixQuery` is `items_before` (`index.rs:97-108`), and
    // the B-tree's is the items before the slab a descent reaches
    // (`index.rs:135-140`).
    for (0..lens.items.len) |i| {
        try testing.expectEqual(referenceBefore(weights.items, i), bit.itemsBefore(i));
        try testing.expectEqual(referenceBefore(weights.items, i), tree.itemsBeforeSlab(i));
    }
    // And one past the end is the total, which is upstream's last line.
    try testing.expectEqual(running, bit.itemsBefore(lens.items.len));
    try testing.expectEqual(running, tree.itemsBeforeSlab(lens.items.len));
}

test "a refused growing splice leaves the weight cache and the tree unchanged" {
    const gpa = testing.allocator;
    const before = [_]Bytes{ .{ .n = 3 }, .{ .n = 0 }, .{ .n = 5 }, .{ .n = 1 }, .{ .n = 4 } };
    var after: [64]Bytes = undefined;
    for (&after, 0..) |*weight, i| weight.* = .{ .n = i % 8 };
    const start: usize = 1;
    const end: usize = 3;
    const spliced_len = before.len - (end - start) + after.len;
    var spliced: [spliced_len]Bytes = undefined;
    @memcpy(spliced[0..start], before[0..start]);
    @memcpy(spliced[start..][0..after.len], &after);
    @memcpy(spliced[start + after.len ..], before[end..]);

    // Grow both buffers while replacing existing weights. Each fault gets a
    // fresh fixture, so an earlier successful reservation cannot hide a later
    // allocation boundary. Disallow in-place resizing to expose those faults.
    var refusals: usize = 0;
    var skip: usize = 0;
    while (true) : (skip += 1) {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        const arm = failing.allocator();
        var idx = try BitIndex(Bytes).fromWeights(arm, &before);
        defer idx.deinit();
        try testing.expect(spliced_len > idx.weights.capacity);
        try testing.expect(spliced_len + 1 > idx.bit.items.capacity);
        failing.fail_index = failing.alloc_index + skip;
        failing.resize_fail_index = failing.resize_index;

        var committed = true;
        idx.splice(start, end, &after) catch |e| switch (e) {
            error.OutOfMemory => {
                committed = false;
                refusals += 1;
            },
            error.InvalidIndex => return error.TestUnexpectedResult,
        };
        const expected: []const Bytes = if (committed) &spliced else &before;
        try testing.expectEqualSlices(Bytes, expected, idx.weights.items);
        try testing.expectEqual(expected.len, idx.len());
        try testing.expectEqual(expected.len, idx.bit.len());
        for (0..expected.len + 1) |i| {
            try testing.expectEqual(referenceBefore(expected, i), idx.itemsBefore(i));
        }
        const total = referenceBefore(expected, expected.len);
        for (0..total + 1) |k| {
            try testing.expectEqual(referencePos(expected, k), idx.findSlab(k));
        }
        if (committed) break;
    }
    // Both real growth reservations must have been refused, without pinning
    // an exact allocator count or permitting setup failures to count as coverage.
    try testing.expect(refusals >= 2);
}

test "a refused rebuild leaves the tree whole" {
    const gpa = testing.allocator;
    const before = [_]Bytes{ .{ .n = 3 }, .{ .n = 0 }, .{ .n = 5 }, .{ .n = 1 }, .{ .n = 4 } };
    const after = [_]Bytes{ .{ .n = 2 }, .{ .n = 7 }, .{ .n = 9 }, .{ .n = 1 } };

    // A tree over no slabs at all answers every query as though it held
    // none, so a rebuild that dropped the old tree before reserving the new
    // one would turn a refused call into a silently wrong answer rather than
    // an error. After every refusal the tree still describes `before` in
    // full — or the whole of `after`, if the rebuild got through.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var bit = try Fenwick(Bytes).init(failing.allocator());
        defer bit.deinit();
        try bit.rebuild(failing.allocator(), &before);
        try bit.rebuild(failing.allocator(), &after);
        break :blk failing.alloc_index;
    };

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const arm = failing.allocator();
        var bit = Fenwick(Bytes).init(arm) catch continue;
        defer bit.deinit();
        bit.rebuild(arm, &before) catch continue;

        // `OutOfMemory` is the only error a rebuild can report, so a refusal
        // is the only way it can leave. The two lists have different slab
        // counts, which is what tells a committed rebuild from a refused
        // one; the value sequence below then pins what the tree really holds.
        var committed = true;
        bit.rebuild(arm, &after) catch {
            committed = false;
        };
        const expected: []const Bytes = if (committed) after[0..] else before[0..];

        try testing.expectEqual(expected.len, bit.len());
        for (0..expected.len + 1) |i| {
            try testing.expectEqual(referenceBefore(expected, i), bit.prefixQuery(i));
        }
        const total = referenceBefore(expected, expected.len);
        for (0..total + 1) |k| {
            try testing.expectEqual(referencePos(expected, k), bit.findSlab(k));
        }
        // Teardown is `testing.allocator`'s to check: a tree whose reserve
        // was refused has to keep the bytes it already held and give them
        // back.
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`index_items_before_parity` checks each backend against the slab
//   lengths, not against the other backend.** That is upstream's assertion
//   (`tests.rs:4648-4669`): `items_before(i)` must equal the running sum of
//   `slab_lens()`. The sweep already in this file, `both index backends answer
//   a positional query the same way` (`index.zig:521-570`), feeds both
//   backends **random** weights and compares them to each other — so two
//   backends that agreed on the wrong answer would pass it. This case adds the
//   ground truth the sweep lacks, and the `i == n` line, which is the total.
//
// * **The weights come from a real fragmented arena, not from a generator.**
//   Upstream's are `Column::<u64>::from_values_with_max_segments(0..500, 4).slab_lens()`
//   (`tests.rs:4644-4645`) — run counts of a typed column, whose index is
//   `column.zig`'s. This case's are the byte lengths a `RawColumn` cut by
//   `withMaxSegments` really produced, which is what `Bytes` exists for
//   (`index.zig:68-70`). **The unit differs and the claim does not**: both
//   backends must report the running sum of the per-slab weights they were
//   given. **A typed column cut across slabs is not covered here** — upstream
//   has no `from_values_with_max_segments` counterpart in the port either
//   (`hexane_test.zig:25-28`), and the run-count budget is the comptime
//   `slabmod.default_max_segments`.
//
// * **Both backends are read through their own `items_before`.** The Fenwick's
//   is `prefixQuery` (`index.rs:97-108`) and the B-tree's is `itemsBeforeSlab`,
//   the items before the slab a descent reaches (`index.rs:135-140`). Upstream
//   reads `btree.index.items_before` and `bit.index.items_before` as two
//   columns' index fields; here they are two independent index types over one
//   weight list, which is the stronger statement — a shared prefix-sum
//   implementation would satisfy neither upstream's pair nor this one.
//
// * **`RawColumn` is imported inside the test, not at module scope.** The
//   module's own dependency graph is `btree` and nothing else, and adding a
//   file-level `raw` import would make `index.zig` and `raw.zig` mutually
//   dependent at the module level for one test. `slab.zig` already takes this
//   shape for `column.zig` (`slab.zig:1740`, and per-test at `:1223`).
