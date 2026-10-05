//! The slab B+tree index (`rust/hexane/src/btree.rs`).
//!
//! A column stores its items in *slabs*: bounded runs of values that are
//! compressed together. The index is a B+tree over those slabs. Each leaf
//! holds up to `branch_factor` slab aggregates in slab order; each internal
//! node holds up to `branch_factor` child slots, where a slot caches the
//! child subtree's aggregate and slab count so a top-down walk costs one
//! comparison per level (`ChildSlot`, upstream `btree.rs:226-230`).
//!
//! The aggregate is order-*sensitive*: `SlabAgg.merge` is associative but
//! not commutative (`btree.rs:44-46`, `:110-122`). That is the whole point.
//! `total` is the running sum the descent navigates by, and `min_offset` /
//! `max_offset` are the first and last item offsets inside the subtree, so a
//! search can skip a subtree it knows does not overlap its range.
//!
//! Mutation is `splice`: replace the slabs in `[start, end)` with a run of
//! new aggregates. Insertion splits an overfull leaf and cascades upward;
//! deletion removes emptied leaves, merges underfull ones with a sibling,
//! and collapses a single-child root chain. Internal nodes are deliberately
//! never rebalanced — they thin ~B times slower than leaves, so their fill
//! tracks the leaf count; the worst case is memory, never a wrong query
//! (`btree.rs:18-23`).
//!
//! Zig shape: the arena is a `std.ArrayList` of optional nodes plus a free
//! list (`Vec<Option<Node<A>>>` + `Vec<NodeId>`, `btree.rs:237-243`). The
//! tree is generic over the per-slab weight `A` exactly where upstream is
//! generic over `SlabAggregate` (`btree.rs:47-54`): the weight declares an
//! `Aggregate` namespace with `identity`, `merge`, `itemCount` and `eql`,
//! and the structural code never looks inside it. `SlabBTree` is the
//! `SlabAgg` instantiation, which is what the value/delta columns use; the
//! value-range cursors live beside it because they are `SlabAgg`-specific
//! upstream too (`btree.rs:1365-1373`).

const std = @import("std");

/// The option module `build.zig` generates for `-Dslow-path`. Read by
/// [`SlabBTree.assertSound`](btree.zig) here and by
/// [`check_slow_paths`](opset/op_set.zig) there, so both gated checks turn
/// on and off with one option.
const build_options = @import("build_options");

/// Branching factor: entries per leaf, and children per internal node.
///
/// Smaller means a deeper tree and cheaper per-node rebalancing; larger
/// means fewer nodes and more per-node cost. Upstream picked 64 empirically
/// across the `marks_at` (query-heavy) and `insert_null` (mutation-heavy)
/// benchmarks (`btree.rs:30-34`) and the port keeps the shape, because the
/// shape decides the later encode sizes.
pub const branch_factor: usize = 64;

/// A node's index in the arena. The arena is bounded by the heap, so `u32`
/// is the same width upstream chose (`btree.rs:194-197`).
pub const NodeId = u32;

/// Position, allocation and checked aggregate arithmetic errors.
pub const TreeError = error{ InvalidIndex, OutOfMemory, Overflow };

/// Normalizes legacy infallible providers and checked aggregate providers.
/// Providers return `A` or `error{Overflow}!A`; the adapter allocates nothing.
pub fn compose(comptime A: type, left: A, right: A) error{Overflow}!A {
    const Result = @typeInfo(@TypeOf(A.Aggregate.merge)).@"fn".return_type.?;
    if (comptime @typeInfo(Result) == .error_union) {
        return try A.Aggregate.merge(left, right);
    }
    return A.Aggregate.merge(left, right);
}

/// The running min/max of a slab's prefix-sum range, plus the number of
/// items in it. The weight of the value and delta columns
/// (`btree.rs:102-107`).
///
/// `total` is the slab's own prefix *increment*, not a cumulative value:
/// `merge` adds it, so the root's `total` is the whole column's prefix sum.
/// `min_offset` / `max_offset` are offsets relative to the slab's start, so
/// adding a left neighbour's `total` shifts them into absolute prefix
/// space. They are signed because a delta column's deltas can be negative
/// and a `usize` there would wrap into a plausible but wrong index.
pub const SlabAgg = struct {
    /// The number of items in the slab.
    len: usize = 0,
    /// `prefix(after the slab) - prefix(before the slab)`.
    total: i64 = 0,
    /// The smallest prefix offset any item in the slab can take.
    min_offset: i64 = 0,
    /// The largest prefix offset any item in the slab can take.
    max_offset: i64 = 0,

    /// The identity of `merge`: the aggregate of no slabs at all.
    pub const zero: SlabAgg = .{};

    /// The weight operations the tree needs. The generic core calls only
    /// these; it never inspects a field of `SlabAgg`.
    pub const Aggregate = struct {
        /// The weight of no slabs at all: the identity of `merge`.
        pub const identity: SlabAgg = .zero;
        /// The weight of two adjacent spans, left before right.
        pub fn merge(l: SlabAgg, r: SlabAgg) error{Overflow}!SlabAgg {
            if (l.len == 0) return r;
            if (r.len == 0) return l;
            return .{
                .len = try std.math.add(usize, l.len, r.len),
                .total = try std.math.add(i64, l.total, r.total),
                // Right offsets are relative to the left span's end.
                .min_offset = @min(l.min_offset, try std.math.add(i64, l.total, r.min_offset)),
                .max_offset = @max(l.max_offset, try std.math.add(i64, l.total, r.max_offset)),
            };
        }
        /// How many column rows the weight covers.
        pub fn itemCount(a: SlabAgg) usize {
            return a.len;
        }
        /// Whether two weights describe the same span.
        pub fn eql(a: SlabAgg, b: SlabAgg) bool {
            return a.len == b.len and a.total == b.total and
                a.min_offset == b.min_offset and a.max_offset == b.max_offset;
        }
    };

    /// A slab whose items all carry the prefix increment `total`, so the
    /// slab spans the offsets `0..=total` (upstream's `simple_agg`,
    /// `btree.rs:1706-1713`).
    pub fn uniform(len: usize, total: i64) SlabAgg {
        return .{
            .len = len,
            .total = total,
            .min_offset = @min(total, 0),
            .max_offset = @max(total, 0),
        };
    }

    /// `uniform` for a column whose prefix sum never decreases, whose
    /// prefix values are therefore lengths.
    /// Returns `error.Overflow` when `total` is outside the signed prefix domain.
    pub fn monotone(len: usize, total: usize) error{Overflow}!SlabAgg {
        return uniform(len, std.math.cast(i64, total) orelse return error.Overflow);
    }

    /// Whether the slab's value range, shifted to `prefix_before`, contains
    /// `target` (`btree.rs:138-142`).
    pub fn contains(self: SlabAgg, target: i64, prefix_before: i64) bool {
        return self.len > 0 and
            @as(i128, target) >= @as(i128, prefix_before) + self.min_offset and
            @as(i128, target) <= @as(i128, prefix_before) + self.max_offset;
    }

    /// Whether the slab's value range, shifted to `prefix_before`,
    /// overlaps the closed range `[lo, hi]` (`btree.rs:144-148`).
    pub fn overlaps(self: SlabAgg, lo: i64, hi: i64, prefix_before: i64) bool {
        return self.len > 0 and
            @as(i128, prefix_before) + self.max_offset >= lo and
            @as(i128, prefix_before) + self.min_offset <= hi;
    }
};

/// A list that owns a fresh copy of `items`. `std.ArrayList` has no
/// slice-taking constructor in Zig 0.16, and every node here hands a copy
/// of its slice to the arena.
fn copyOf(
    gpa: std.mem.Allocator,
    comptime T: type,
    items: []const T,
) std.mem.Allocator.Error!std.ArrayList(T) {
    const buf = try gpa.dupe(T, items);
    return .{ .items = buf, .capacity = buf.len };
}

/// `a / b` rounded up. `b` is never zero.
fn ceilDiv(a: usize, b: usize) usize {
    return a / b + @intFromBool(a % b != 0);
}

/// The B+tree over slab aggregates, generic over the weight `A`.
///
/// `A.Aggregate` supplies `identity: A`, `merge(A, A) A` or
/// `merge(A, A) error{Overflow}!A`, `itemCount(A) usize` and `eql(A, A) bool`.
/// Checked providers refuse any unrepresentable stored summary.
pub fn Tree(comptime A: type) type {
    return struct {
        const Self = @This();

        fn merge(left: A, right: A) error{Overflow}!A {
            return compose(A, left, right);
        }
        const itemCount = A.Aggregate.itemCount;
        const eql = A.Aggregate.eql;
        const identity = A.Aggregate.identity;

        /// One entry of an internal node: a child subtree plus that
        /// subtree's cached aggregate and slab count. The cache is an
        /// algorithmic dependency, not a micro-optimisation: every
        /// top-down walk reads it instead of descending first
        /// (`btree.rs:226-230`).
        const ChildSlot = struct {
            /// Child node id in this tree's arena.
            id: NodeId,
            /// Cached aggregate of the child's subtree.
            agg: A,
            /// Number of slabs in the child's subtree.
            slab_count: usize,
        };

        /// An aggregate plus a slab count, for a node summarised without
        /// naming it.
        const Summary = struct {
            agg: A,
            slab_count: usize,
        };

        const Node = union(enum) {
            /// Owned slab weights in logical order.
            leaf: std.ArrayList(A),
            /// Owned child summaries in logical order.
            internal: std.ArrayList(ChildSlot),
        };

        /// One step of a descent: the node entered and the index of the
        /// child taken. A path ends with the parent of a leaf
        /// (`locateLeafForStart`, `btree.rs:975-1009`).
        const PathEntry = struct {
            node: NodeId,
            child: usize,
        };

        /// Where `locateLeafForStart` landed.
        const Location = struct {
            leaf: NodeId,
            leaf_start: usize,
        };

        /// The slab a positional search landed in, and the item count
        /// strictly before it (`btree.rs:1192-1227`).
        pub const PositionalHit = struct {
            /// Zero-based index of the containing slab.
            slab: usize,
            /// Number of items strictly before that slab.
            items_before: usize,
        };

        /// Retained allocation provider; must remain live and must not be
        /// replaced independently of the arena.
        gpa: std.mem.Allocator,
        /// The arena. A `null` slot is a freed node, which is also on
        /// `free`.
        nodes: std.ArrayList(?Node),
        /// Reusable ids whose corresponding arena slots are null.
        free: std.ArrayList(NodeId),
        /// Live root node id. Arena ids are not stable across mutation.
        root: NodeId,
        /// Number of logical slabs, equal to the sum of the leaf lengths.
        total_slabs: usize,
        /// Validated full-tree summary, so readers do not replay arithmetic.
        root_agg: A,

        /// A tree with one empty leaf root and no slabs. The root leaf is
        /// the only node, so a fresh tree holds zero slabs. Only allocation
        /// can fail; no aggregate arithmetic or index lookup is performed.
        /// The caller owns the result and releases it with `deinit`.
        pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var nodes: std.ArrayList(?Node) = .empty;
            errdefer nodes.deinit(gpa);
            try nodes.append(gpa, .{ .leaf = .empty });
            return .{ .gpa = gpa, .nodes = nodes, .free = .empty, .root = 0, .total_slabs = 0, .root_agg = identity };
        }

        /// Copies the arena and every node buffer into `gpa`, preserving node
        /// ids, free slots and cached weights without recomputing aggregates.
        /// The caller owns the result and must call `deinit` exactly once.
        /// Weights are copied by value, as in `fromSlice`; any references
        /// inside `A` remain borrowed. Failure leaves `self` unchanged.
        /// Time and storage are proportional to the arena and its entries.
        pub fn clone(self: *const Self, gpa: std.mem.Allocator) std.mem.Allocator.Error!Self {
            var result: Self = .{
                .gpa = gpa,
                .nodes = .empty,
                .free = .empty,
                .root = self.root,
                .total_slabs = self.total_slabs,
                .root_agg = self.root_agg,
            };
            errdefer result.deinit();
            try result.nodes.ensureTotalCapacity(gpa, self.nodes.items.len);
            try result.free.appendSlice(gpa, self.free.items);
            for (self.nodes.items) |slot| {
                const copied: ?Node = if (slot) |entry| switch (entry) {
                    .leaf => |items| .{ .leaf = try copyOf(gpa, A, items.items) },
                    .internal => |items| .{ .internal = try copyOf(gpa, ChildSlot, items.items) },
                } else null;
                result.nodes.appendAssumeCapacity(copied);
            }
            return result;
        }

        /// Frees every node buffer, the arena and the free-slot list with
        /// the retained allocator, then poisons `self`. Exactly once; a
        /// shallow copy is not a second owner. Does not release `gpa` or
        /// references stored inside the copied weights.
        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |*slot| {
                if (slot.* == null) continue;
                switch (slot.*.?) {
                    .leaf => |*l| l.deinit(self.gpa),
                    .internal => |*c| c.deinit(self.gpa),
                }
            }
            self.nodes.deinit(self.gpa);
            self.free.deinit(self.gpa);
            self.* = undefined;
        }

        /// The number of slabs in the tree.
        pub fn len(self: *const Self) usize {
            return self.total_slabs;
        }

        /// Whether the tree holds no slabs.
        pub fn isEmpty(self: *const Self) bool {
            return self.total_slabs == 0;
        }

        /// The merged aggregate of every slab in the tree.
        pub fn rootAgg(self: *const Self) A {
            return self.root_agg;
        }

        /// Bulk-builds a tree over `aggs`: leaves of `branch_factor` slabs,
        /// then one level of internals at a time. This is the shape the
        /// tree has after a column is loaded, so a later incremental edit
        /// starts from the same tree a straight build would have made
        /// (`btree.rs:317-362`).
        /// The caller owns the result. Failure frees the candidate; `aggs`
        /// remains borrowed and unchanged, including on `error.Overflow`.
        pub fn fromSlice(gpa: std.mem.Allocator, aggs: []const A) TreeError!Self {
            var tree = try Self.init(gpa);
            errdefer tree.deinit();
            if (aggs.len == 0) return tree;
            tree.total_slabs = aggs.len;

            var level: std.ArrayList(ChildSlot) = .empty;
            defer level.deinit(gpa);

            var i: usize = 0;
            while (i < aggs.len) {
                const chunk = aggs[i..][0..@min(branch_factor, aggs.len - i)];
                const leaf = try copyOf(gpa, A, chunk);
                const id = tree.alloc(.{ .leaf = leaf }) catch |e| {
                    var owned = leaf;
                    owned.deinit(gpa);
                    return e;
                };
                try level.append(gpa, .{ .id = id, .agg = try mergeAll(chunk), .slab_count = chunk.len });
                i += chunk.len;
            }

            while (level.items.len > 1) {
                const next = try tree.buildLevel(gpa, level.items);
                level.deinit(gpa);
                level = next;
            }

            // The initial empty leaf root is now unreachable; its slot
            // goes back on the free list.
            tree.release(tree.root);
            tree.root = level.items[0].id;
            tree.root_agg = level.items[0].agg;
            return tree;
        }

        /// Replaces the aggregate of the slab at `slab_idx`
        /// (`btree.rs:366-410`).
        /// `error.Overflow` leaves the slab and every cached ancestor unchanged.
        pub fn updateSlab(self: *Self, slab_idx: usize, new_agg: A) TreeError!void {
            if (slab_idx >= self.total_slabs) return error.InvalidIndex;
            try self.splice(slab_idx, slab_idx + 1, &.{new_agg});
        }

        /// Replaces the slabs in `[start, end)` with `new` (upstream
        /// `splice`, `btree.rs:412-438`).
        /// `error.InvalidIndex` and `error.Overflow` leave the tree unchanged.
        /// Allocation refusal during structural publication retains the existing
        /// abort-only contract: callers must discard their staged candidate.
        pub fn splice(self: *Self, start: usize, end: usize, new: []const A) TreeError!void {
            if (start > end or end > self.total_slabs) return error.InvalidIndex;
            if (start == end and new.len == 0) return;
            const total = try std.math.add(usize, self.total_slabs - (end - start), new.len);
            if (new.len == end - start) {
                // Fold each affected ancestor once, with every replacement
                // present. Intermediate partial overwrites need not fit.
                const summary = try self.rewriteSummary(self.root, 0, start, new, false);
                _ = try self.rewriteSummary(self.root, 0, start, new, true);
                self.root_agg = summary;
                return;
            }
            const summary = try self.preflightStructural(start, end, new);
            try self.spliceStructural(start, end, new);
            self.total_slabs = total;
            self.root_agg = summary;
        }

        // ── Arena ────────────────────────────────────────────────────────

        /// Adds a node, reusing a freed slot when there is one
        /// (`btree.rs:283-292`).
        fn alloc(self: *Self, new_node: Node) TreeError!NodeId {
            if (self.free.pop()) |id| {
                self.nodes.items[id] = new_node;
                return id;
            }
            // Reserve the free-list room first: a release must never fail,
            // and one free entry per arena slot is always enough.
            try self.free.ensureTotalCapacity(self.gpa, try std.math.add(usize, self.nodes.items.len, 1));
            // `NodeId` is a `u32`, so the arena cannot grow past what it
            // addresses. Upstream mints the index unchecked
            // (`btree.rs:284-290`) and relies on the arena being small; the
            // port proves it instead, because a trap in Debug is worse than
            // an error.
            const id = std.math.cast(NodeId, self.nodes.items.len) orelse
                return error.InvalidIndex;
            try self.nodes.append(self.gpa, new_node);
            return id;
        }

        /// Marks `id` dead, frees the node it held, and puts it on the
        /// free list. Upstream's `free` drops the node value, so the
        /// payload goes with it (`btree.rs:294-297`). Cannot fail: the
        /// free list is kept large enough for one entry per arena slot.
        fn release(self: *Self, id: NodeId) void {
            const slot = &self.nodes.items[id];
            switch (slot.*.?) {
                .leaf => |*l| l.deinit(self.gpa),
                .internal => |*c| c.deinit(self.gpa),
            }
            slot.* = null;
            self.free.appendAssumeCapacity(id);
        }

        /// The live node `id`. Traps on a freed id, which only a bug in the
        /// structural code can produce.
        fn node(self: *const Self, id: NodeId) *const Node {
            return &self.nodes.items[id].?;
        }

        /// The live node `id`, mutably.
        fn nodeMut(self: *Self, id: NodeId) *Node {
            return &self.nodes.items[id].?;
        }

        /// The aggregate of every slab under `id` (`btree.rs:308-313`).
        fn aggOf(self: *const Self, id: NodeId) error{Overflow}!A {
            return switch (self.node(id).*) {
                .leaf => |l| try mergeAll(l.items),
                .internal => |n| (try summarizeSlots(n.items)).agg,
            };
        }

        /// The aggregate and slab count of an internal node
        /// (`btree.rs:1154-1163`).
        fn internalSummary(self: *const Self, id: NodeId) error{Overflow}!Summary {
            return summarizeSlots(self.node(id).internal.items);
        }

        /// Appends every aggregate under `id` to `out`, in slab order
        /// (`btree.rs:1172-1181`).
        fn collectInto(self: *const Self, id: NodeId, out: *std.ArrayList(A)) TreeError!void {
            switch (self.node(id).*) {
                .leaf => |l| try out.appendSlice(self.gpa, l.items),
                .internal => |n| for (n.items) |c| try self.collectInto(c.id, out),
            }
        }

        // ── Aggregate helpers ────────────────────────────────────────────

        /// Folds `items` left to right from the identity
        /// (`merge_all`, `btree.rs:88-94`).
        fn mergeAll(items: []const A) error{Overflow}!A {
            var acc = identity;
            for (items) |x| acc = try merge(acc, x);
            return acc;
        }

        /// Folds the cached child aggregates of an internal node.
        fn summarizeSlots(slots: []const ChildSlot) error{Overflow}!Summary {
            var acc = identity;
            var slab_count: usize = 0;
            for (slots) |s| {
                acc = try merge(acc, s.agg);
                slab_count = try std.math.add(usize, slab_count, s.slab_count);
            }
            return .{ .agg = acc, .slab_count = slab_count };
        }

        /// Computes the final weights without writing, then repeats the
        /// same folds while publishing. Unaffected children use their cache.
        fn rewriteSummary(
            self: *Self,
            id: NodeId,
            base: usize,
            start: usize,
            new: []const A,
            comptime publish: bool,
        ) error{Overflow}!A {
            var acc = identity;
            const end = start + new.len; // Bounds were checked by splice.
            switch (self.node(id).*) {
                .leaf => |l| {
                    for (l.items, 0..) |old, i| {
                        const pos = base + i;
                        const value = if (pos >= start and pos < end) new[pos - start] else old;
                        acc = try merge(acc, value);
                        if (publish) l.items[i] = value;
                    }
                },
                .internal => |n| {
                    var cursor = base;
                    for (n.items, 0..) |c, i| {
                        const child_end = cursor + c.slab_count;
                        const value = if (cursor < end and child_end > start)
                            try self.rewriteSummary(c.id, cursor, start, new, publish)
                        else
                            c.agg;
                        acc = try merge(acc, value);
                        if (publish) self.nodeMut(id).internal.items[i].agg = value;
                        cursor = child_end;
                    }
                },
            }
            return acc;
        }

        fn plannedSlot(summary: Summary) ChildSlot {
            return .{ .id = 0, .agg = summary.agg, .slab_count = summary.slab_count };
        }

        /// Summary-only equivalent of splitInternal/buildLevel. It owns
        /// only a temporary list, never nodes or a publication journal.
        fn plannedGroups(self: *const Self, slots: []const ChildSlot, balanced: bool) TreeError!std.ArrayList(ChildSlot) {
            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);
            if (slots.len == 0) return out;
            const groups = ceilDiv(slots.len, branch_factor);
            const base = slots.len / groups;
            const rem = slots.len % groups;
            var at: usize = 0;
            for (0..groups) |i| {
                const size = if (balanced) base + @intFromBool(i < rem) else @min(branch_factor, slots.len - at);
                try out.append(self.gpa, plannedSlot(try summarizeSlots(slots[at..][0..size])));
                at += size;
            }
            return out;
        }

        /// Mirrors makeLeaves and buildChildrenAtHeight exactly; signed
        /// relative summaries must fit at every newly introduced boundary.
        fn plannedChildren(self: *const Self, aggs: []const A, height: usize) TreeError!std.ArrayList(ChildSlot) {
            if (height > 0) {
                var below = try self.plannedChildren(aggs, height - 1);
                defer below.deinit(self.gpa);
                return self.plannedGroups(below.items, true);
            }
            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);
            if (aggs.len == 0) return out;
            const groups = ceilDiv(aggs.len, branch_factor);
            const base = aggs.len / groups;
            const rem = aggs.len % groups;
            var at: usize = 0;
            for (0..groups) |i| {
                const size = base + @intFromBool(i < rem);
                try out.append(self.gpa, .{ .id = 0, .agg = try mergeAll(aggs[at..][0..size]), .slab_count = size });
                at += size;
            }
            return out;
        }

        fn plannedPropagate(self: *const Self, path: []const PathEntry, replacement_in: std.ArrayList(ChildSlot)) TreeError!A {
            var replacement = replacement_in;
            defer replacement.deinit(self.gpa);
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const step = path[i];
                var siblings = try copyOf(self.gpa, ChildSlot, self.node(step.node).internal.items);
                defer siblings.deinit(self.gpa);
                try siblings.replaceRange(self.gpa, step.child, 1, replacement.items);
                const next = try self.plannedGroups(siblings.items, true);
                replacement.deinit(self.gpa);
                replacement = next;
            }
            while (replacement.items.len > branch_factor) {
                const next = try self.plannedGroups(replacement.items, false);
                replacement.deinit(self.gpa);
                replacement = next;
            }
            return (try summarizeSlots(replacement.items)).agg;
        }

        fn plannedBulk(self: *const Self, aggs: []const A) TreeError!A {
            var slots: std.ArrayList(ChildSlot) = .empty;
            defer slots.deinit(self.gpa);
            var at: usize = 0;
            while (at < aggs.len) {
                const size = @min(branch_factor, aggs.len - at);
                try slots.append(self.gpa, .{ .id = 0, .agg = try mergeAll(aggs[at..][0..size]), .slab_count = size });
                at += size;
            }
            while (slots.items.len > 1) {
                const next = try self.plannedGroups(slots.items, false);
                slots.deinit(self.gpa);
                slots = next;
            }
            return (try summarizeSlots(slots.items)).agg;
        }

        fn preflightStructural(self: *const Self, start: usize, end: usize, new: []const A) TreeError!A {
            if (self.total_slabs == 0) return self.plannedBulk(new);
            var path: std.ArrayList(PathEntry) = .empty;
            defer path.deinit(self.gpa);
            const loc = (try self.locateLeafForStart(start, &path)) orelse return error.InvalidIndex;
            const leaf = self.node(loc.leaf).leaf.items;
            if (end <= loc.leaf_start + leaf.len) {
                var combined = try copyOf(self.gpa, A, leaf);
                defer combined.deinit(self.gpa);
                try combined.replaceRange(self.gpa, start - loc.leaf_start, end - start, new);
                const children = try self.plannedChildren(combined.items, 0);
                const root_summary = try self.plannedPropagate(path.items, children);
                // The mutation refreshes ancestors before the optional merge,
                // so both representations must have representable summaries.
                if (path.items.len > 0 and combined.items.len > 0 and
                    combined.items.len < branch_factor / 4 and new.len < end - start)
                {
                    const last = path.items[path.items.len - 1];
                    const siblings = self.node(last.node).internal.items;
                    const dst = if (last.child > 0) last.child - 1 else last.child;
                    const src = if (last.child > 0) last.child else last.child + 1;
                    if (src < siblings.len) {
                        const neighbor = if (last.child > 0) dst else src;
                        const count = try std.math.add(usize, combined.items.len, siblings[neighbor].slab_count);
                        if (count <= branch_factor) {
                            var merged: std.ArrayList(A) = .empty;
                            defer merged.deinit(self.gpa);
                            const other = self.node(siblings[neighbor].id).leaf.items;
                            try merged.appendSlice(self.gpa, if (last.child > 0) other else combined.items);
                            try merged.appendSlice(self.gpa, if (last.child > 0) combined.items else other);
                            var parent = try copyOf(self.gpa, ChildSlot, siblings);
                            defer parent.deinit(self.gpa);
                            parent.items[dst] = .{ .id = 0, .agg = try mergeAll(merged.items), .slab_count = count };
                            _ = parent.orderedRemove(src);
                            const replacement = try self.plannedGroups(parent.items, true);
                            return self.plannedPropagate(path.items[0 .. path.items.len - 1], replacement);
                        }
                    }
                }
                return root_summary;
            }

            var end_path: std.ArrayList(PathEntry) = .empty;
            defer end_path.deinit(self.gpa);
            _ = (try self.locateLeafForStart(end - 1, &end_path)) orelse return error.InvalidIndex;
            var d: usize = 0;
            while (d < @min(path.items.len, end_path.items.len) and
                path.items[d].child == end_path.items[d].child) : (d += 1)
            {}
            if (d == @min(path.items.len, end_path.items.len)) return error.InvalidIndex;
            const lca = path.items[d].node;
            const left = path.items[d].child;
            const right = end_path.items[d].child;
            const siblings = self.node(lca).internal.items;
            var offset: usize = 0;
            for (path.items[0..d]) |step| {
                for (self.node(step.node).internal.items[0..step.child]) |c| offset += c.slab_count;
            }
            for (siblings[0..left]) |c| offset += c.slab_count;
            var combined: std.ArrayList(A) = .empty;
            defer combined.deinit(self.gpa);
            for (siblings[left .. right + 1]) |c| try self.collectInto(c.id, &combined);
            try combined.replaceRange(self.gpa, start - offset, end - start, new);
            var children = try self.plannedChildren(combined.items, self.subtreeHeight(siblings[left].id));
            defer children.deinit(self.gpa);
            var parent = try copyOf(self.gpa, ChildSlot, siblings);
            defer parent.deinit(self.gpa);
            try parent.replaceRange(self.gpa, left, right - left + 1, children.items);
            const replacement = try self.plannedGroups(parent.items, true);
            return self.plannedPropagate(path.items[0..d], replacement);
        }

        // ── Bulk build helpers ───────────────────────────────────────────

        /// One internal-node level over `slots`, each node taking up to
        /// `branch_factor` children.
        fn buildLevel(
            self: *Self,
            gpa: std.mem.Allocator,
            slots: []const ChildSlot,
        ) TreeError!std.ArrayList(ChildSlot) {
            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(gpa);
            var i: usize = 0;
            while (i < slots.len) {
                const chunk = slots[i..][0..@min(branch_factor, slots.len - i)];
                const children = try copyOf(gpa, ChildSlot, chunk);
                const slot = self.makeInternal(children) catch |e| {
                    var owned = children;
                    owned.deinit(self.gpa);
                    return e;
                };
                try out.append(gpa, slot);
                i += chunk.len;
            }
            return out;
        }

        /// Allocates an internal node over `children`, taking ownership of
        /// the list, and returns its slot.
        fn makeInternal(self: *Self, children: std.ArrayList(ChildSlot)) TreeError!ChildSlot {
            // Ownership transfers only after both summary and allocation succeed.
            const summary = try summarizeSlots(children.items);
            const id = try self.alloc(.{ .internal = children });
            return .{ .id = id, .agg = summary.agg, .slab_count = summary.slab_count };
        }

        /// Splits `aggs` into as-evenly-as-possible groups of at most
        /// `branch_factor` and makes a leaf per group (`make_fresh_leaves`,
        /// `btree.rs:806-832`).
        fn makeFreshLeaves(self: *Self, aggs: []const A) TreeError!std.ArrayList(ChildSlot) {
            return self.makeLeaves(aggs, null);
        }

        /// `makeFreshLeaves`, except the first leaf reuses `first_leaf_id`'s
        /// node (`make_leaves_from_aggs`, `btree.rs:1030-1064`).
        fn makeLeaves(
            self: *Self,
            aggs: []const A,
            first_leaf_id: ?NodeId,
        ) TreeError!std.ArrayList(ChildSlot) {
            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);
            if (aggs.len == 0) return out;

            const num_leaves = ceilDiv(aggs.len, branch_factor);
            const base = aggs.len / num_leaves;
            const rem = aggs.len % num_leaves;

            var i: usize = 0;
            for (0..num_leaves) |c| {
                const size = base + @intFromBool(c < rem);
                const chunk = aggs[i..][0..size];
                const summary = try mergeAll(chunk);
                const reuse = if (c == 0) first_leaf_id else null;
                const id: NodeId = if (reuse) |known|
                    known
                else blk: {
                    const leaf = try copyOf(self.gpa, A, chunk);
                    break :blk self.alloc(.{ .leaf = leaf }) catch |e| {
                        var owned = leaf;
                        owned.deinit(self.gpa);
                        return e;
                    };
                };
                if (reuse) |known| {
                    // The node survives; its contents are replaced.
                    switch (self.nodeMut(known).*) {
                        .leaf => |*l| {
                            l.clearRetainingCapacity();
                            try l.appendSlice(self.gpa, chunk);
                        },
                        .internal => return error.InvalidIndex,
                    }
                }
                try out.append(self.gpa, .{
                    .id = id,
                    .agg = summary,
                    .slab_count = size,
                });
                i += size;
            }
            return out;
        }

        /// A child-slot list of `height` internal levels over `aggs`
        /// (`build_children_at_height`, `btree.rs:774-804`).
        fn buildChildrenAtHeight(
            self: *Self,
            aggs: []const A,
            height: usize,
        ) TreeError!std.ArrayList(ChildSlot) {
            if (aggs.len == 0) return .empty;
            if (height == 0) return self.makeFreshLeaves(aggs);

            var below = try self.buildChildrenAtHeight(aggs, height - 1);
            defer below.deinit(self.gpa);

            // Spread the children over as few nodes as possible.
            const num = ceilDiv(below.items.len, branch_factor);
            const base = below.items.len / num;
            const rem = below.items.len % num;

            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);
            var i: usize = 0;
            for (0..num) |c| {
                const size = base + @intFromBool(c < rem);
                const children = try copyOf(self.gpa, ChildSlot, below.items[i..][0..size]);
                i += size;
                const slot = self.makeInternal(children) catch |e| {
                    var owned = children;
                    owned.deinit(self.gpa);
                    return e;
                };
                try out.append(self.gpa, slot);
            }
            return out;
        }

        // ── Splice ───────────────────────────────────────────────────────

        /// Routes the structural part of a splice (`splice_structural`,
        /// `btree.rs:473-482`).
        fn spliceStructural(self: *Self, start: usize, end: usize, new: []const A) TreeError!void {
            if (self.total_slabs == 0) {
                try self.spliceIntoEmpty(new);
            } else if (!try self.trySingleLeafSplice(start, end, new)) {
                try self.spliceViaLca(start, end, new);
            }
            // A large deletion can leave a single-child chain at the top.
            self.collapseRoot();
        }

        /// Splices into an empty tree (`splice_into_empty`,
        /// `btree.rs:879-896`).
        fn spliceIntoEmpty(self: *Self, new: []const A) TreeError!void {
            if (new.len == 0) return;
            if (new.len <= branch_factor) {
                switch (self.nodeMut(self.root).*) {
                    .leaf => |*l| try l.appendSlice(self.gpa, new),
                    .internal => return error.InvalidIndex,
                }
                self.total_slabs = new.len;
                return;
            }
            const fresh = try Self.fromSlice(self.gpa, new);
            self.deinit();
            self.* = fresh;
        }

        /// Handles a range that lies inside one leaf. Returns `false` when
        /// it does not, and the caller falls back to the LCA path
        /// (`try_single_leaf_splice`, `btree.rs:905-967`).
        fn trySingleLeafSplice(self: *Self, start: usize, end: usize, new: []const A) TreeError!bool {
            var path: std.ArrayList(PathEntry) = .empty;
            defer path.deinit(self.gpa);

            const loc = (try self.locateLeafForStart(start, &path)) orelse return false;
            const leaf_len = switch (self.node(loc.leaf).*) {
                .leaf => |l| l.items.len,
                .internal => return error.InvalidIndex,
            };
            if (start < loc.leaf_start or end > loc.leaf_start + leaf_len) return false;

            const local_start = start - loc.leaf_start;
            const local_end = end - loc.leaf_start;
            const new_leaf_len = try std.math.add(usize, leaf_len - (end - start), new.len);

            if (new_leaf_len <= branch_factor) {
                if (new_leaf_len == 0 and loc.leaf != self.root) {
                    // An empty non-root leaf is not allowed: remove it and
                    // cascade. The root, if it is this leaf, is emptied in
                    // place below.
                    try self.removeAndCascade(path.items);
                    self.total_slabs = try std.math.add(usize, self.total_slabs - (end - start), new.len);
                    return true;
                }
                switch (self.nodeMut(loc.leaf).*) {
                    .leaf => |*l| try l.replaceRange(self.gpa, local_start, local_end - local_start, new),
                    .internal => return error.InvalidIndex,
                }
                try self.updateAncestorAggregates(path.items, loc.leaf);
                self.total_slabs = try std.math.add(usize, self.total_slabs - (end - start), new.len);
                if (new.len < end - start) {
                    // The leaf shrank: merge it with a sibling if it went
                    // under a quarter full.
                    try self.maybeMergeLeaf(path.items);
                }
                return true;
            }

            // Overflow: build the combined run, split it into leaves, and
            // cascade the split upward.
            var combined: std.ArrayList(A) = .empty;
            defer combined.deinit(self.gpa);
            {
                const items = switch (self.node(loc.leaf).*) {
                    .leaf => |l| l.items,
                    .internal => return error.InvalidIndex,
                };
                try combined.appendSlice(self.gpa, items[0..local_start]);
                try combined.appendSlice(self.gpa, new);
                try combined.appendSlice(self.gpa, items[local_end..]);
            }

            const children = try self.makeLeaves(combined.items, loc.leaf);
            try self.propagateSplits(path.items, children);
            self.total_slabs = try std.math.add(usize, self.total_slabs - (end - start), new.len);
            return true;
        }

        /// General multi-leaf splice through the lowest common ancestor of
        /// the range's ends (`splice_via_lca`, `btree.rs:490-633`).
        fn spliceViaLca(self: *Self, start: usize, end: usize, new: []const A) TreeError!void {
            var start_path: std.ArrayList(PathEntry) = .empty;
            defer start_path.deinit(self.gpa);
            _ = (try self.locateLeafForStart(start, &start_path)) orelse return;

            var end_path: std.ArrayList(PathEntry) = .empty;
            defer end_path.deinit(self.gpa);
            _ = (try self.locateLeafForStart(if (start == end) start else end - 1, &end_path)) orelse return;

            // The LCA is where the two descents take different children of
            // the same node.
            var diverge: ?usize = null;
            const common_len = @min(start_path.items.len, end_path.items.len);
            for (0..common_len) |i| {
                if (start_path.items[i].child != end_path.items[i].child) {
                    diverge = i;
                    break;
                }
            }

            if (diverge == null) {
                // The range lies inside one leaf, which the single-leaf
                // path handles for every case including a whole-leaf
                // delete. Reaching this is a routing bug upstream too, so
                // rebuild rather than corrupt.
                var all: std.ArrayList(A) = .empty;
                defer all.deinit(self.gpa);
                try self.collectInto(self.root, &all);
                try all.replaceRange(self.gpa, start, end - start, new);
                const fresh = try Self.fromSlice(self.gpa, all.items);
                self.deinit();
                self.* = fresh;
                return;
            }
            const d = diverge.?;

            const lca_id = start_path.items[d].node;
            const left_child = start_path.items[d].child;
            const right_child = end_path.items[d].child;
            const lca_path = start_path.items[0..d];

            // The absolute slab index of lca.children[left_child].
            var lca_offset: usize = 0;
            for (lca_path) |step| {
                const siblings = self.node(step.node).internal.items;
                for (siblings[0..step.child]) |c| lca_offset += c.slab_count;
            }
            const left_offset = blk: {
                const siblings = self.node(lca_id).internal.items;
                var sum: usize = 0;
                for (siblings[0..left_child]) |c| sum += c.slab_count;
                break :blk sum;
            };
            const combined_start = lca_offset + left_offset;
            const child_height = self.subtreeHeight(self.node(lca_id).internal.items[left_child].id);

            // Take the affected subtrees out, apply the splice in local
            // coordinates, and put fresh ones back at the same height.
            var combined: std.ArrayList(A) = .empty;
            defer combined.deinit(self.gpa);
            {
                const siblings = self.node(lca_id).internal.items;
                for (siblings[left_child .. right_child + 1]) |c| {
                    try self.collectInto(c.id, &combined);
                }
                for (siblings[left_child .. right_child + 1]) |c| {
                    self.freeSubtree(c.id);
                }
            }
            const local_start = start - combined_start;
            const local_end = end - combined_start;
            try combined.replaceRange(self.gpa, local_start, local_end - local_start, new);

            const new_lca_len = blk: {
                var children = try self.buildChildrenAtHeight(combined.items, child_height);
                // The slots are copied into the LCA; the list is ours.
                defer children.deinit(self.gpa);
                const siblings = &self.nodeMut(lca_id).internal;
                try siblings.replaceRange(self.gpa, left_child, right_child - left_child + 1, children.items);
                break :blk siblings.items.len;
            };
            self.total_slabs = try std.math.add(usize, self.total_slabs - (end - start), new.len);

            if (new_lca_len == 0) {
                // Every child of the LCA went away. An empty internal node
                // is not allowed: remove the LCA and cascade. A root LCA
                // means the whole tree was deleted, so reset it to an
                // empty leaf in place.
                if (lca_path.len == 0) {
                    self.resetToEmptyLeaf(lca_id);
                } else {
                    try self.removeAndCascade(lca_path);
                }
            } else if (new_lca_len <= branch_factor) {
                const summary = try self.internalSummary(lca_id);
                var replacement: std.ArrayList(ChildSlot) = .empty;
                errdefer replacement.deinit(self.gpa);
                try replacement.append(self.gpa, .{
                    .id = lca_id,
                    .agg = summary.agg,
                    .slab_count = summary.slab_count,
                });
                try self.propagateSplits(lca_path, replacement);
            } else {
                try self.splitAndPropagate(lca_id, lca_path);
            }
        }

        // ── Underflow handling ───────────────────────────────────────────

        /// Frees the subtree at `id` (`btree.rs:635-644`).
        fn freeSubtree(self: *Self, id: NodeId) void {
            switch (self.node(id).*) {
                .leaf => {},
                .internal => |n| for (n.items) |c| self.freeSubtree(c.id),
            }
            self.release(id);
        }

        /// Removes the node at the end of `path` from its parent, freeing
        /// the subtree. An emptied parent cascades upward, and an emptied
        /// root becomes a fresh empty leaf. Surviving ancestors get their
        /// cached aggregate and slab count refreshed
        /// (`remove_and_cascade`, `btree.rs:657-685`).
        fn removeAndCascade(self: *Self, path: []const PathEntry) error{Overflow}!void {
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const parent_id = path[i].node;
                const child_idx = path[i].child;
                const child_id = self.node(parent_id).internal.items[child_idx].id;
                self.freeSubtree(child_id);
                const remaining = blk: {
                    const siblings = &self.nodeMut(parent_id).internal;
                    _ = siblings.orderedRemove(child_idx);
                    break :blk siblings.items.len;
                };
                if (remaining == 0) {
                    if (i == 0) {
                        // The root itself emptied: the tree is back to its
                        // initial state, reusing the root's slot.
                        self.resetToEmptyLeaf(parent_id);
                        return;
                    }
                    continue; // cascade
                }
                try self.updateAncestorAggregates(path[0..i], parent_id);
                return;
            }
        }

        /// Replaces the node at `id` with an empty leaf, reusing the slot.
        /// This is how a deleted tree returns to its initial state
        /// (`btree.rs:669-675`, `:615-618`).
        fn resetToEmptyLeaf(self: *Self, id: NodeId) void {
            const slot = &self.nodes.items[id];
            switch (slot.*.?) {
                .leaf => |*l| l.deinit(self.gpa),
                .internal => |*c| c.deinit(self.gpa),
            }
            slot.* = .{ .leaf = .empty };
        }

        /// Promotes the root's only child until the root is a leaf or has
        /// two children (`collapse_root`, `btree.rs:690-699`).
        fn collapseRoot(self: *Self) void {
            while (true) {
                const child = switch (self.node(self.root).*) {
                    .leaf => return,
                    .internal => |n| if (n.items.len == 1) n.items[0].id else return,
                };
                self.release(self.root);
                self.root = child;
            }
        }

        /// Merges a shrunken leaf into a sibling when it is under a
        /// quarter full and the pair still fits in one node, mirroring the
        /// column's merge policy (`maybe_merge_leaf`, `btree.rs:710-759`).
        ///
        /// Leaf-level only: an internal node loses a child only when a
        /// whole leaf dies, so its fill tracks the leaf count and merging
        /// it would be wasted work.
        fn maybeMergeLeaf(self: *Self, path: []const PathEntry) TreeError!void {
            if (path.len == 0) return; // the leaf is the root
            const last = path[path.len - 1];
            const parent_id = last.node;
            const child_idx = last.child;

            const siblings = self.node(parent_id).internal.items;
            const sibling_count = siblings.len;
            const my_len = siblings[child_idx].slab_count;
            if (my_len >= branch_factor / 4) return;

            // Merge right-into-left so slab order is preserved.
            const dst_idx = if (child_idx > 0)
                child_idx - 1
            else if (child_idx + 1 < sibling_count)
                child_idx
            else
                return; // only child: cascade and collapse handle it
            const src_idx = if (child_idx > 0) child_idx else child_idx + 1;

            const combined = try std.math.add(usize, siblings[dst_idx].slab_count, siblings[src_idx].slab_count);
            if (combined > branch_factor) return;
            const dst_id = siblings[dst_idx].id;
            const src_id = siblings[src_idx].id;

            var moved = self.takeLeafList(src_id) catch |e| return e;
            defer moved.deinit(self.gpa);
            try self.appendLeafList(dst_id, moved.items);
            self.release(src_id);

            const agg = try self.aggOf(dst_id);
            const parent = &self.nodeMut(parent_id).internal;
            parent.items[dst_idx].agg = agg;
            parent.items[dst_idx].slab_count = combined;
            _ = parent.orderedRemove(src_idx);
            try self.updateAncestorAggregates(path[0 .. path.len - 1], parent_id);
        }

        /// Empties the leaf at `id` and hands its aggregate list to the
        /// caller.
        fn takeLeafList(self: *Self, id: NodeId) TreeError!std.ArrayList(A) {
            switch (self.nodeMut(id).*) {
                .leaf => |*l| {
                    const taken = l.*;
                    l.* = .empty;
                    return taken;
                },
                .internal => return error.InvalidIndex,
            }
        }

        /// Appends `items` to the leaf at `id`.
        fn appendLeafList(self: *Self, id: NodeId, items: []const A) TreeError!void {
            switch (self.nodeMut(id).*) {
                .leaf => |*l| try l.appendSlice(self.gpa, items),
                .internal => return error.InvalidIndex,
            }
        }

        /// The number of internal levels below `id`; 0 for a leaf
        /// (`subtree_height`, `btree.rs:761-772`).
        ///
        /// The `1 +` belongs to the else branch, as it does upstream: an
        /// internal node with no children has height 0, not 1
        /// (`btree.rs:764-770`). `else 1 + h` already parses as
        /// `else (1 + h)`, so the value was never in doubt; the
        /// parentheses say so, because the other reading differs from this
        /// one by one on exactly the empty node, and lifting the addend out
        /// of the else branch would read `n.items[0]` on it too.
        fn subtreeHeight(self: *const Self, id: NodeId) usize {
            return switch (self.node(id).*) {
                .leaf => 0,
                .internal => |n| if (n.items.len == 0) 0 else (1 + self.subtreeHeight(n.items[0].id)),
            };
        }

        // ── Splits ───────────────────────────────────────────────────────

        /// Splits `node_id` into `num_chunks` internal nodes and returns
        /// their slots in order. The first chunk stays in `node_id`; the
        /// rest move to fresh nodes (`split_and_propagate` /
        /// `propagate_splits`, `btree.rs:834-875` and `:1094-1129`).
        fn splitInternal(self: *Self, node_id: NodeId, num_chunks: usize) TreeError!std.ArrayList(ChildSlot) {
            const total = self.node(node_id).internal.items.len;
            const base = total / num_chunks;
            const rem = total % num_chunks;
            const first_size = base + @intFromBool(rem > 0);

            var tail: std.ArrayList(ChildSlot) = .empty;
            {
                const siblings = &self.nodeMut(node_id).internal;
                const buf = try self.gpa.dupe(ChildSlot, siblings.items[first_size..]);
                siblings.shrinkAndFree(self.gpa, first_size);
                tail = .{ .items = buf, .capacity = buf.len };
            }
            defer tail.deinit(self.gpa);

            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);

            const first = try self.internalSummary(node_id);
            try out.append(self.gpa, .{
                .id = node_id,
                .agg = first.agg,
                .slab_count = first.slab_count,
            });

            var taken: usize = 0;
            for (1..num_chunks) |c| {
                const size = base + @intFromBool(c < rem);
                const children = try copyOf(self.gpa, ChildSlot, tail.items[taken..][0..size]);
                taken += size;
                const slot = self.makeInternal(children) catch |e| {
                    var owned = children;
                    owned.deinit(self.gpa);
                    return e;
                };
                try out.append(self.gpa, slot);
            }
            return out;
        }

        /// Splits the overfull `node_id` and splices the resulting nodes
        /// into the parent chain.
        fn splitAndPropagate(self: *Self, node_id: NodeId, path: []const PathEntry) TreeError!void {
            const total = self.node(node_id).internal.items.len;
            const replacement = try self.splitInternal(node_id, ceilDiv(total, branch_factor));
            try self.propagateSplits(path, replacement);
        }

        /// Replaces the node at the end of `path` with `replacement`,
        /// splitting the parent when it overflows, until the root is
        /// reached (`propagate_splits`, `btree.rs:1072-1152`).
        ///
        /// Consumes `replacement`: the slots end up in the tree, or are
        /// freed if this returns an error.
        fn propagateSplits(
            self: *Self,
            path: []const PathEntry,
            replacement_in: std.ArrayList(ChildSlot),
        ) TreeError!void {
            var replacement = replacement_in;
            errdefer replacement.deinit(self.gpa);

            var i = path.len;
            while (i > 0) {
                i -= 1;
                const parent_id = path[i].node;
                const child_idx = path[i].child;
                const new_total = blk: {
                    const siblings = &self.nodeMut(parent_id).internal;
                    try siblings.replaceRange(self.gpa, child_idx, 1, replacement.items);
                    break :blk siblings.items.len;
                };
                if (new_total <= branch_factor) {
                    const summary = try self.internalSummary(parent_id);
                    // The slots are now the parent's; the list carries
                    // only the parent itself up to the next level.
                    replacement.clearRetainingCapacity();
                    try replacement.append(self.gpa, .{
                        .id = parent_id,
                        .agg = summary.agg,
                        .slab_count = summary.slab_count,
                    });
                    continue;
                }
                // The parent overflowed: split it and carry the new set up.
                const fresh = try self.splitInternal(parent_id, ceilDiv(new_total, branch_factor));
                replacement.deinit(self.gpa);
                replacement = fresh;
            }

            switch (replacement.items.len) {
                0 => replacement.deinit(self.gpa),
                1 => {
                    const slot = replacement.items[0];
                    if (slot.id != self.root) {
                        self.release(self.root);
                        self.root = slot.id;
                    }
                    replacement.deinit(self.gpa);
                },
                else => {
                    // The root overflowed: grow a new one level up.
                    //
                    // **A bulk replacement can hold more slots than one node
                    // does, and this is where it used to be lost.**
                    // `makeLeaves` makes one slot per leaf, so replacing a
                    // whole tree with more than `branch_factor` slabs arrives
                    // here with more than `branch_factor` slots — 65 for 4097
                    // slabs, 66 for 4167, 128 for 8192. Putting all of them
                    // into one new root made a node that was itself overfull,
                    // and the shape a straight `fromSlice` build can never
                    // produce, because that one adds a level at a time
                    // (`buildLevel`). So the slots are grouped into internal
                    // nodes first, the same way, and the new root holds the
                    // groups. Reached through `trySingleLeafSplice`'s
                    // overflow arm with an empty `path` — the old root was
                    // the leaf being rewritten, and its slot is among the
                    // groups already.
                    while (replacement.items.len > branch_factor) {
                        const groups = try self.buildLevel(self.gpa, replacement.items);
                        replacement.deinit(self.gpa);
                        replacement = groups;
                    }
                    const children = replacement;
                    replacement = .empty;
                    const slot = self.makeInternal(children) catch |e| {
                        var owned = children;
                        owned.deinit(self.gpa);
                        return e;
                    };
                    self.root = slot.id;
                },
            }
        }

        /// Walks toward the leaf holding slab `start`, appending the
        /// ancestor path to `path` and returning the leaf and the slab
        /// index of its first entry. The append case (`start == len()`)
        /// lands in the last leaf (`locate_leaf_for_start`,
        /// `btree.rs:975-1009`).
        fn locateLeafForStart(
            self: *const Self,
            start: usize,
            path: *std.ArrayList(PathEntry),
        ) TreeError!?Location {
            var remaining = start;
            var leaf_start: usize = 0;
            var node_id = self.root;
            while (true) {
                switch (self.node(node_id).*) {
                    .leaf => return .{ .leaf = node_id, .leaf_start = leaf_start },
                    .internal => |n| {
                        if (n.items.len == 0) return null;
                        const last = n.items.len - 1;
                        var descended = false;
                        for (n.items, 0..) |c, i| {
                            // Descend when `remaining` falls strictly inside
                            // the child, or when it sits on the last
                            // child's right boundary (the append case).
                            if (remaining < c.slab_count or (i == last and remaining == c.slab_count)) {
                                try path.append(self.gpa, .{ .node = node_id, .child = i });
                                node_id = c.id;
                                descended = true;
                                break;
                            }
                            remaining -= c.slab_count;
                            leaf_start += c.slab_count;
                        }
                        if (!descended) return null;
                    },
                }
            }
        }

        /// Recomputes each ancestor's cached aggregate and slab count from
        /// the subtree below it (`update_ancestor_aggregates`,
        /// `btree.rs:1014-1025`).
        fn updateAncestorAggregates(self: *Self, path: []const PathEntry, leaf_id: NodeId) error{Overflow}!void {
            var current = leaf_id;
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const summary: Summary = switch (self.node(current).*) {
                    .leaf => |l| .{ .agg = try mergeAll(l.items), .slab_count = l.items.len },
                    .internal => |n| try summarizeSlots(n.items),
                };
                const slot = &self.nodeMut(path[i].node).internal.items[path[i].child];
                slot.agg = summary.agg;
                slot.slab_count = summary.slab_count;
                current = path[i].node;
            }
        }

        // ── Positional lookup ────────────────────────────────────────────

        /// The slab holding the `pos`-th item, and the item count strictly
        /// before it. `null` when `pos` is at or past the end
        /// (`find_by_prefix`, `btree.rs:1192-1227`).
        pub fn findByPrefix(self: *const Self, pos: usize) ?PositionalHit {
            // Checked constructors/mutations bound every nonnegative partial
            // item count by itemCount(root_agg), and slab counts by len().
            var cursor_id = self.root;
            var remaining = pos;
            var slab_base: usize = 0;
            var items_before: usize = 0;
            while (true) {
                switch (self.node(cursor_id).*) {
                    .leaf => |l| {
                        for (l.items, 0..) |a, i| {
                            if (remaining < itemCount(a)) {
                                return .{ .slab = slab_base + i, .items_before = items_before };
                            }
                            remaining -= itemCount(a);
                            items_before += itemCount(a);
                        }
                        return null;
                    },
                    .internal => |n| {
                        var descended = false;
                        for (n.items) |c| {
                            if (remaining < itemCount(c.agg)) {
                                cursor_id = c.id;
                                descended = true;
                                break;
                            }
                            remaining -= itemCount(c.agg);
                            items_before += itemCount(c.agg);
                            slab_base += c.slab_count;
                        }
                        if (!descended) return null;
                    },
                }
            }
        }

        /// Where a prefix-sum search landed: the slab whose running
        /// `incr` reaches `target`, with the running sums and the item
        /// count before it.
        pub const PrefixSumHit = struct {
            /// The slab the running sum reaches `target` in, or
            /// `len()` when the target is past the total.
            slab: usize,
            /// The items in the slabs before it.
            items_before: usize,
            /// The running sum before it.
            prefix_before: i64,
        };

        /// The first slab whose cumulative `incr` reaches or exceeds
        /// `target`, with the running sum and the item count before it
        /// (`find_slab_at_prefix`, `btree.rs:1628-1667`). O(log S): one
        /// comparison per level, against the running sums of the sibling
        /// subtrees the descent passes.
        ///
        /// `incr` is the per-slab running-sum increment, and it is a
        /// parameter because the two weights mean it by different things:
        /// a prefix column's is the sum of its row lengths and a delta
        /// column's is the sum of its differences, which is its realized
        /// value at the slab's end. Upstream reaches the same place
        /// through the index type parameter (`index.rs:43-46`).
        ///
        /// A target at or past the total answers `len()`, the one-past-the-
        /// end position every caller here checks for
        /// (`prefix.rs:615-617`).
        /// `error.Overflow` means an absolute running endpoint did not fit i64;
        /// the tree is unchanged and no partial hit is returned.
        pub fn findByPrefixSum(
            self: *const Self,
            comptime incr: fn (A) i64,
            target: i64,
        ) error{Overflow}!PrefixSumHit {
            var prefix: i64 = 0;
            var items: usize = 0;
            var slab_base: usize = 0;
            var cursor = self.root;
            while (true) {
                switch (self.node(cursor).*) {
                    .leaf => |l| {
                        for (l.items, 0..) |a, i| {
                            const after = try std.math.add(i64, prefix, incr(a));
                            if (target <= after) {
                                return .{
                                    .slab = slab_base + i,
                                    .items_before = items,
                                    .prefix_before = prefix,
                                };
                            }
                            prefix = after;
                            items = try std.math.add(usize, items, itemCount(a));
                        }
                        return .{
                            .slab = slab_base + l.items.len,
                            .items_before = items,
                            .prefix_before = prefix,
                        };
                    },
                    .internal => |n| {
                        var descended = false;
                        for (n.items) |c| {
                            const after = try std.math.add(i64, prefix, incr(c.agg));
                            if (target <= after) {
                                cursor = c.id;
                                descended = true;
                                break;
                            }
                            prefix = after;
                            items = try std.math.add(usize, items, itemCount(c.agg));
                            slab_base = try std.math.add(usize, slab_base, c.slab_count);
                        }
                        if (!descended) {
                            return .{
                                .slab = slab_base,
                                .items_before = items,
                                .prefix_before = prefix,
                            };
                        }
                    },
                }
            }
        }

        /// The number of items in the slabs before `slab_idx`. Accepts
        /// `slab_idx == len()` and answers with the total
        /// (`items_before_slab`, `btree.rs:1232-1265`).
        pub fn itemsBeforeSlab(self: *const Self, slab_idx: usize) usize {
            // Every accumulated row count is a prefix of the checked root's
            // nonnegative item count, so no arithmetic refusal is needed.
            var remaining = slab_idx;
            var items: usize = 0;
            var cursor_id = self.root;
            while (true) {
                switch (self.node(cursor_id).*) {
                    .leaf => |l| {
                        for (l.items) |a| {
                            if (remaining == 0) return items;
                            remaining -= 1;
                            items += itemCount(a);
                        }
                        return items;
                    },
                    .internal => |n| {
                        var descended = false;
                        for (n.items) |c| {
                            if (remaining < c.slab_count) {
                                cursor_id = c.id;
                                descended = true;
                                break;
                            }
                            remaining -= c.slab_count;
                            items += itemCount(c.agg);
                        }
                        if (!descended) return items;
                    },
                }
            }
        }

        // ── Structural invariants ────────────────────────────────────────

        /// Which invariant a failed check found. Mirrors the assertions of
        /// upstream `check_invariants` (`btree.rs:1283-1360`).
        pub const ViolationKind = enum {
            /// The root is internal with a single child, so `collapseRoot`
            /// did not run.
            uncollapsed_root,
            /// The slab count under the root disagrees with `len()`.
            slab_count_mismatch,
            /// A node is reachable twice, or its id names a freed slot.
            node_reachable_twice,
            /// A live node is not reachable from the root.
            unreachable_node,
            /// A live node is on the free list, or a dead one is not.
            free_list_mismatch,
            /// The same node id appears twice on the free list.
            duplicate_free_entry,
            /// A node holds more than `branch_factor` entries.
            node_overfull,
            /// A node that must hold an entry is empty.
            node_empty,
            /// Leaves are not all at the same depth.
            non_uniform_depth,
            /// A cached child/root aggregate or slab count is stale.
            stale_child_summary,
        };

        /// The first invariant violation found, or `null` when the tree is
        /// sound. `describe` renders it for a test message.
        pub const Violation = struct {
            kind: ViolationKind,
            /// The node the violation was found at, when it has one.
            node: ?NodeId = null,
            /// The child slot the violation was found at, when it has one.
            child: ?NodeId = null,
            /// The value the check expected.
            expected: usize = 0,
            /// The value the check found.
            actual: usize = 0,

            /// Renders the violation into `buf`, for a test failure
            /// message. Truncates rather than failing.
            pub fn describe(self: Violation, buf: []u8) []const u8 {
                const at = self.node orelse 0;
                const child = self.child orelse 0;
                return switch (self.kind) {
                    .uncollapsed_root => std.fmt.bufPrint(buf, "node {d}: internal root has {d} child(ren), so the root was not collapsed", .{ at, self.actual }) catch "uncollapsed root",
                    .slab_count_mismatch => std.fmt.bufPrint(buf, "the root holds {d} slabs but len() says {d}", .{ self.actual, self.expected }) catch "slab count mismatch",
                    .node_reachable_twice => std.fmt.bufPrint(buf, "node {d} is reachable twice", .{at}) catch "node reachable twice",
                    .unreachable_node => std.fmt.bufPrint(buf, "node {d} is live but unreachable", .{at}) catch "unreachable node",
                    .free_list_mismatch => std.fmt.bufPrint(buf, "node {d} is live and free-listed, or dead and not", .{at}) catch "free list mismatch",
                    .duplicate_free_entry => std.fmt.bufPrint(buf, "node {d} is on the free list twice", .{at}) catch "duplicate free entry",
                    .node_overfull => std.fmt.bufPrint(buf, "node {d} holds {d} entries, over the branch factor", .{ at, self.actual }) catch "node overfull",
                    .node_empty => std.fmt.bufPrint(buf, "node {d} is empty", .{at}) catch "empty node",
                    .non_uniform_depth => std.fmt.bufPrint(buf, "node {d} sits at depth {d}, not {d}", .{ at, self.actual, self.expected }) catch "non-uniform depth",
                    .stale_child_summary => if (self.child == null)
                        "the root caches the wrong aggregate"
                    else
                        std.fmt.bufPrint(buf, "node {d} caches the wrong summary for child {d}", .{ at, child }) catch "stale child summary",
                };
            }
        };

        /// Verifies every structural invariant and reports the first
        /// violation, or `null` when the tree is sound. `O(nodes)`
        /// (`check_invariants`, `btree.rs:1283-1360`).
        ///
        /// Arena consistency, leaf and internal occupancy, uniform leaf
        /// depth, cached child aggregates and slab counts, and the total
        /// slab count.
        pub fn checkInvariants(self: *const Self) TreeError!?Violation {
            const reachable = try self.gpa.alloc(bool, self.nodes.items.len);
            defer self.gpa.free(reachable);
            @memset(reachable, false);

            switch (self.node(self.root).*) {
                .leaf => {},
                .internal => |n| if (n.items.len < 2) {
                    return Violation{ .kind = .uncollapsed_root, .node = self.root, .actual = n.items.len };
                },
            }

            var leaf_depth: ?usize = null;
            var failure: ?Violation = null;
            const info = try self.checkNode(self.root, 0, &leaf_depth, reachable, &failure);
            if (failure) |v| return v;
            if (info.slabs != self.total_slabs) {
                return Violation{
                    .kind = .slab_count_mismatch,
                    .expected = self.total_slabs,
                    .actual = info.slabs,
                };
            }
            if (!eql(info.agg, self.root_agg)) {
                return Violation{ .kind = .stale_child_summary, .node = self.root };
            }

            // The free list must hold every dead node exactly once and no
            // live node at all.
            var on_free = try self.gpa.alloc(bool, self.nodes.items.len);
            defer self.gpa.free(on_free);
            @memset(on_free, false);
            for (self.free.items) |id| {
                if (on_free[id]) {
                    return Violation{ .kind = .duplicate_free_entry, .node = id };
                }
                on_free[id] = true;
            }
            for (self.nodes.items, 0..) |slot, i| {
                const live = slot != null;
                const reach = reachable[i];
                const freed = on_free[i];
                if (reach and !live) return Violation{ .kind = .node_reachable_twice, .node = @intCast(i) };
                if (live and !reach) return Violation{ .kind = .unreachable_node, .node = @intCast(i) };
                if (live and freed) return Violation{ .kind = .free_list_mismatch, .node = @intCast(i) };
                if (!live and !freed) return Violation{ .kind = .free_list_mismatch, .node = @intCast(i) };
            }
            return null;
        }

        /// [`checkInvariants`](btree.zig) as an assertion: the first
        /// violation is `error.InvariantViolation`, a sound tree returns
        /// void. `O(nodes)`, and this is the port's `-Dslow-path` checker.
        ///
        /// **Off, it checks nothing and says so by returning.** Upstream puts
        /// the equivalent call behind `#[cfg(feature =
        /// "slow_path_assertions")]` at the top of `SequenceTree::insert`
        /// (`sequence_tree.rs:51-53`) and `remove` (`:113-115`), so a build
        /// without the feature never spends the walk — and this method is the
        /// port's version of that "without the feature" build. The gate sits
        /// here rather than on a call site because **the port cannot put it on
        /// a call site**: [`splice`](btree.zig) returns
        /// [`TreeError`](btree.zig), and a check that can fail from there
        /// would have to add `InvariantViolation` to that set, which makes the
        /// exhaustive `switch`es over it in `column.zig:1707`, `:3332`,
        /// `:3361` and `edit.zig:776` stop compiling — and reporting a broken
        /// tree as `error.InvalidIndex` instead would be a lie, because every
        /// caller maps that to "the caller passed a bad position".
        ///
        /// Upstream calls `check()` from `SequenceTree`, which is the old
        /// index and a different structure, not from `SlabBTree`'s own
        /// mutators (`btree.rs:412-438`), and hexane gates nothing of its
        /// own: `rust/hexane/Cargo.toml:17` declares
        /// `slow_path_assertions` and `rust/hexane/src` reads it nowhere.
        /// So there is no upstream call site to copy here, and this method is
        /// the gate P2's gate text names.
        ///
        /// The feature is off in upstream's default set — `rust/automerge/
        /// Cargo.toml:16-17` calls it "should only be enabled when running
        /// tests" — and this port keeps it off because the walk is linear in
        /// the arena and the deep sweeps call this once per mutation. The
        /// checker itself is always compiled and always tested, through
        /// [`checkInvariants`](btree.zig): a checker that is not compiled
        /// cannot be tested at all.
        pub fn assertSound(self: *const Self) (TreeError || error{InvariantViolation})!void {
            if (comptime !build_options.check_slow_paths) return;
            const violation = (try self.checkInvariants()) orelse return;
            var buf: [256]u8 = undefined;
            std.debug.print("invariant violated: {s}\n", .{violation.describe(&buf)});
            return error.InvariantViolation;
        }

        /// What a subtree check computes: the slab count and the merge of
        /// the aggregates under it (`check_node`, `btree.rs:1314-1360`).
        const NodeInfo = struct { slabs: usize, agg: A };

        fn checkNode(
            self: *const Self,
            id: NodeId,
            depth: usize,
            leaf_depth: *?usize,
            reachable: []bool,
            fail: *?Violation,
        ) TreeError!NodeInfo {
            if (reachable[id]) {
                fail.* = .{ .kind = .node_reachable_twice, .node = id };
                return .{ .slabs = 0, .agg = identity };
            }
            reachable[id] = true;

            switch (self.node(id).*) {
                .leaf => |l| {
                    if (l.items.len > branch_factor) {
                        fail.* = .{ .kind = .node_overfull, .node = id, .actual = l.items.len };
                        return .{ .slabs = 0, .agg = identity };
                    }
                    if (id != self.root and l.items.len == 0) {
                        fail.* = .{ .kind = .node_empty, .node = id };
                        return .{ .slabs = 0, .agg = identity };
                    }
                    if (leaf_depth.*) |d| {
                        if (d != depth) {
                            fail.* = .{ .kind = .non_uniform_depth, .node = id, .expected = d, .actual = depth };
                            return .{ .slabs = 0, .agg = identity };
                        }
                    } else {
                        leaf_depth.* = depth;
                    }
                    return .{ .slabs = l.items.len, .agg = try mergeAll(l.items) };
                },
                .internal => |n| {
                    if (n.items.len == 0) {
                        fail.* = .{ .kind = .node_empty, .node = id };
                        return .{ .slabs = 0, .agg = identity };
                    }
                    if (n.items.len > branch_factor) {
                        fail.* = .{ .kind = .node_overfull, .node = id, .actual = n.items.len };
                        return .{ .slabs = 0, .agg = identity };
                    }
                    var slabs: usize = 0;
                    var agg = identity;
                    for (n.items) |c| {
                        const child = try self.checkNode(c.id, depth + 1, leaf_depth, reachable, fail);
                        if (fail.* != null) return .{ .slabs = 0, .agg = identity };
                        // The cached summary must be exactly what the
                        // child recomputes to, not merely agree on the
                        // count: a stale min or total is a silently wrong
                        // value search.
                        if (child.slabs != c.slab_count or !eql(child.agg, c.agg)) {
                            fail.* = .{ .kind = .stale_child_summary, .node = id, .child = c.id };
                            return .{ .slabs = 0, .agg = identity };
                        }
                        slabs = try std.math.add(usize, slabs, child.slabs);
                        agg = try merge(agg, child.agg);
                    }
                    return .{ .slabs = slabs, .agg = agg };
                },
            }
        }
    };
}

/// The slab index used by the value and delta columns: the running
/// min/max of the prefix-sum range.
pub const SlabBTree = Tree(SlabAgg);

/// Where a prefix search landed (`FoundSlab`, `btree.rs:1541-1545`).
///
/// Upstream names the third field `pos`; it is the number of items *before*
/// the slab, not the offset inside it (`btree.rs:1563-1617`).
pub const FoundSlab = struct {
    /// The slab index.
    index: usize,
    /// The prefix sum before the slab.
    prefix: i64,
    /// The number of items before the slab.
    items_before: usize,
};

/// The slab holding the `item_idx`-th item, with the prefix sum and item
/// count before it. An index past the end returns the final position with
/// the full totals (`find_slab_at_item`, `btree.rs:1563-1615`).
///
/// `O(log slabs)`: descends by item count, accumulating the prefix sum and
/// item count of the children passed on the way.
/// Returns `error.Overflow` for an unrepresentable absolute prefix; no mutation.
pub fn findSlabAtItem(tree: *const SlabBTree, item_idx: usize) error{Overflow}!FoundSlab {
    var prefix: i64 = 0;
    var items_before: usize = 0;
    var slab_base: usize = 0;
    var remaining = item_idx;
    var node = tree.root;
    while (true) {
        switch (tree.node(node).*) {
            .leaf => |l| {
                for (l.items, 0..) |a, i| {
                    if (remaining < a.len) {
                        return .{ .index = slab_base + i, .prefix = prefix, .items_before = items_before };
                    }
                    prefix = try std.math.add(i64, prefix, a.total);
                    items_before = try std.math.add(usize, items_before, a.len);
                    remaining -= a.len;
                }
                return .{
                    .index = slab_base + l.items.len,
                    .prefix = prefix,
                    .items_before = items_before,
                };
            },
            .internal => |n| {
                var descended = false;
                for (n.items) |c| {
                    if (remaining < c.agg.len) {
                        node = c.id;
                        descended = true;
                        break;
                    }
                    prefix = try std.math.add(i64, prefix, c.agg.total);
                    items_before = try std.math.add(usize, items_before, c.agg.len);
                    slab_base = try std.math.add(usize, slab_base, c.slab_count);
                    remaining -= c.agg.len;
                }
                if (!descended) {
                    return .{ .index = slab_base, .prefix = prefix, .items_before = items_before };
                }
            },
        }
    }
}

/// The first slab whose prefix sum reaches or exceeds `target`, with the
/// prefix sum and item count before it. A target past the total returns
/// one-past-the-end (`find_slab_at_prefix`, `btree.rs:1628-1667`).
///
/// `O(log slabs)`: descends by comparing `target` with the running prefix
/// sums of the sibling subtrees.
pub fn findSlabAtPrefix(tree: *const SlabBTree, target: i64) error{Overflow}!FoundSlab {
    var prefix: i64 = 0;
    var items_before: usize = 0;
    var slab_base: usize = 0;
    var node = tree.root;
    while (true) {
        switch (tree.node(node).*) {
            .leaf => |l| {
                for (l.items, 0..) |a, i| {
                    const after = try std.math.add(i64, prefix, a.total);
                    if (target <= after) {
                        return .{ .index = slab_base + i, .prefix = prefix, .items_before = items_before };
                    }
                    prefix = after;
                    items_before = try std.math.add(usize, items_before, a.len);
                }
                return .{
                    .index = slab_base + l.items.len,
                    .prefix = prefix,
                    .items_before = items_before,
                };
            },
            .internal => |n| {
                var descended = false;
                for (n.items) |c| {
                    const after = try std.math.add(i64, prefix, c.agg.total);
                    if (target <= after) {
                        node = c.id;
                        descended = true;
                        break;
                    }
                    prefix = after;
                    items_before = try std.math.add(usize, items_before, c.agg.len);
                    slab_base = try std.math.add(usize, slab_base, c.slab_count);
                }
                if (!descended) {
                    return .{ .index = slab_base, .prefix = prefix, .items_before = items_before };
                }
            },
        }
    }
}

// ── Value-range queries ─────────────────────────────────────────────────────

/// One level of a value cursor's explicit stack (`Frame`, `btree.rs:1382-1388`).
const Frame = struct {
    node: NodeId,
    next_child: usize,
    prefix_before: i64,
    slab_base: usize,
    items_before: usize,
};

/// One slab reported by a value cursor: its index, the item count and the
/// prefix sum before it.
pub const ValueHit = struct {
    slab: usize,
    items_before: usize,
    prefix_before: i64,
};

/// Walks the tree and yields the slabs whose value range contains
/// `target` (`FindByValue`, `btree.rs:1375-1458`).
///
/// A subtree is entered only when its merged `SlabAgg` contains the target
/// once shifted by the prefix sum before it, so a search touches only the
/// slabs that can hold it plus their ancestors.
pub const FindByValue = struct {
    tree: *const SlabBTree,
    target: i64,
    stack: std.ArrayList(Frame),

    /// Starts a walk for `target`. The stack is sized to the tree's
    /// height, so `next` never allocates.
    pub fn init(tree: *const SlabBTree, target: i64) TreeError!FindByValue {
        var stack: std.ArrayList(Frame) = .empty;
        errdefer stack.deinit(tree.gpa);
        try stack.ensureTotalCapacity(tree.gpa, tree.subtreeHeight(tree.root) + 1);
        try stack.append(tree.gpa, .{
            .node = tree.root,
            .next_child = 0,
            .prefix_before = 0,
            .slab_base = 0,
            .items_before = 0,
        });
        return .{ .tree = tree, .target = target, .stack = stack };
    }

    /// Frees the cursor's stack. The tree is untouched.
    pub fn deinit(self: *FindByValue) void {
        self.stack.deinit(self.tree.gpa);
        self.* = undefined;
    }

    /// The next slab containing the target, or `null` at the end of the
    /// walk.
    /// On `error.Overflow`, the failing slab is not consumed; earlier progress
    /// remains. The tree is never mutated.
    pub fn next(self: *FindByValue) error{Overflow}!?ValueHit {
        while (self.stack.items.len > 0) {
            const top = self.stack.items.len - 1;
            switch (self.tree.node(self.stack.items[top].node).*) {
                .leaf => |l| {
                    if (self.stack.items[top].next_child >= l.items.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const i = self.stack.items[top].next_child;
                    const agg = l.items[i];
                    const prefix = self.stack.items[top].prefix_before;
                    const hit: ValueHit = .{
                        .slab = self.stack.items[top].slab_base + i,
                        .items_before = self.stack.items[top].items_before,
                        .prefix_before = prefix,
                    };
                    const after = try std.math.add(i64, prefix, agg.total);
                    const items_after = try std.math.add(usize, hit.items_before, agg.len);
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before = after;
                    self.stack.items[top].items_before = items_after;
                    if (agg.contains(self.target, prefix)) return hit;
                },
                .internal => |n| {
                    if (self.stack.items[top].next_child >= n.items.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const child = n.items[self.stack.items[top].next_child];
                    const prefix = self.stack.items[top].prefix_before;
                    const slab_base = self.stack.items[top].slab_base;
                    const items_before = self.stack.items[top].items_before;
                    const after = try std.math.add(i64, prefix, child.agg.total);
                    const slabs_after = try std.math.add(usize, slab_base, child.slab_count);
                    const items_after = try std.math.add(usize, items_before, child.agg.len);
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before = after;
                    self.stack.items[top].slab_base = slabs_after;
                    self.stack.items[top].items_before = items_after;
                    if (child.agg.contains(self.target, prefix)) {
                        // The stack was sized to the tree's height, so
                        // there is always room for one more level.
                        std.debug.assert(self.stack.items.len < self.stack.capacity);
                        self.stack.appendAssumeCapacity(.{
                            .node = child.id,
                            .next_child = 0,
                            .prefix_before = prefix,
                            .slab_base = slab_base,
                            .items_before = items_before,
                        });
                    }
                },
            }
        }
        return null;
    }
};

/// Walks the tree and yields the slabs whose value range overlaps the
/// closed range `[lo, hi]` (`FindByValueRange`, `btree.rs:1460-1536`).
///
/// `FindByValue` with a one-point range, except that a slab overlapping
/// only at one end is still reported.
pub const FindByValueRange = struct {
    tree: *const SlabBTree,
    lo: i64,
    hi: i64,
    stack: std.ArrayList(Frame),

    /// Starts a walk for `[lo, hi]`. The stack is sized to the tree's
    /// height, so `next` never allocates.
    pub fn init(tree: *const SlabBTree, lo: i64, hi: i64) TreeError!FindByValueRange {
        var stack: std.ArrayList(Frame) = .empty;
        errdefer stack.deinit(tree.gpa);
        try stack.ensureTotalCapacity(tree.gpa, tree.subtreeHeight(tree.root) + 1);
        try stack.append(tree.gpa, .{
            .node = tree.root,
            .next_child = 0,
            .prefix_before = 0,
            .slab_base = 0,
            .items_before = 0,
        });
        return .{ .tree = tree, .lo = lo, .hi = hi, .stack = stack };
    }

    /// Frees the cursor's stack. The tree is untouched.
    pub fn deinit(self: *FindByValueRange) void {
        self.stack.deinit(self.tree.gpa);
        self.* = undefined;
    }

    /// The next slab overlapping the range, or `null` at the end of the
    /// walk.
    /// On `error.Overflow`, the failing slab is not consumed; earlier progress
    /// remains. The tree is never mutated.
    pub fn next(self: *FindByValueRange) error{Overflow}!?ValueHit {
        while (self.stack.items.len > 0) {
            const top = self.stack.items.len - 1;
            switch (self.tree.node(self.stack.items[top].node).*) {
                .leaf => |l| {
                    if (self.stack.items[top].next_child >= l.items.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const i = self.stack.items[top].next_child;
                    const agg = l.items[i];
                    const prefix = self.stack.items[top].prefix_before;
                    const hit: ValueHit = .{
                        .slab = self.stack.items[top].slab_base + i,
                        .items_before = self.stack.items[top].items_before,
                        .prefix_before = prefix,
                    };
                    const after = try std.math.add(i64, prefix, agg.total);
                    const items_after = try std.math.add(usize, hit.items_before, agg.len);
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before = after;
                    self.stack.items[top].items_before = items_after;
                    if (agg.overlaps(self.lo, self.hi, prefix)) return hit;
                },
                .internal => |n| {
                    if (self.stack.items[top].next_child >= n.items.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const child = n.items[self.stack.items[top].next_child];
                    const prefix = self.stack.items[top].prefix_before;
                    const slab_base = self.stack.items[top].slab_base;
                    const items_before = self.stack.items[top].items_before;
                    const after = try std.math.add(i64, prefix, child.agg.total);
                    const slabs_after = try std.math.add(usize, slab_base, child.slab_count);
                    const items_after = try std.math.add(usize, items_before, child.agg.len);
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before = after;
                    self.stack.items[top].slab_base = slabs_after;
                    self.stack.items[top].items_before = items_after;
                    if (child.agg.overlaps(self.lo, self.hi, prefix)) {
                        std.debug.assert(self.stack.items.len < self.stack.capacity);
                        self.stack.appendAssumeCapacity(.{
                            .node = child.id,
                            .next_child = 0,
                            .prefix_before = prefix,
                            .slab_base = slab_base,
                            .items_before = items_before,
                        });
                    }
                },
            }
        }
        return null;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "checked composition refuses unrepresentable aggregate endpoints" {
    const hi = std.math.maxInt(i64);
    const lo = std.math.minInt(i64);
    try testing.expectError(error.Overflow, compose(SlabAgg, simple(1, hi), simple(1, 1)));
    try testing.expectError(error.Overflow, compose(SlabAgg, simple(1, lo), simple(1, -1)));
    try testing.expectError(error.Overflow, compose(SlabAgg, .{ .len = std.math.maxInt(usize) }, .{ .len = 1 }));
    try testing.expectError(error.Overflow, compose(SlabAgg, .{ .len = 1, .total = hi }, .{ .len = 1, .total = -1, .max_offset = 1 }));
    try testing.expectError(error.Overflow, compose(SlabAgg, .{ .len = 1, .total = lo }, .{ .len = 1, .total = 1, .min_offset = -1 }));
    try testing.expectEqualDeep(simple(2, hi), try compose(SlabAgg, simple(1, hi), simple(1, 0)));
    try testing.expectEqualDeep(simple(2, lo), try compose(SlabAgg, simple(1, lo), simple(1, 0)));
    if (std.math.cast(i64, std.math.maxInt(usize))) |total| {
        try testing.expectEqual(total, (try SlabAgg.monotone(1, std.math.maxInt(usize))).total);
    } else {
        try testing.expectError(error.Overflow, SlabAgg.monotone(1, std.math.maxInt(usize)));
    }
}

test "arithmetic refusal leaves tree updates and splices unchanged" {
    const hi = std.math.maxInt(i64);
    const initial = [_]SlabAgg{ simple(1, hi - 1), simple(1, 1) };
    var tree = try SlabBTree.fromSlice(testing.allocator, &initial);
    defer tree.deinit();
    const before = tree.rootAgg();
    try testing.expectError(error.Overflow, tree.updateSlab(1, simple(1, 2)));
    try testing.expectEqualDeep(before, tree.rootAgg());
    try testing.expectEqual(FoundSlab{ .index = 1, .prefix = hi - 1, .items_before = 1 }, try findSlabAtItem(&tree, 1));
    try testing.expectError(error.Overflow, tree.splice(1, 2, &.{simple(1, 2)}));
    try testing.expectEqualDeep(before, tree.rootAgg());
    try testing.expectError(error.Overflow, tree.splice(2, 2, &.{simple(1, 1)}));
    try testing.expectEqualDeep(before, tree.rootAgg());
    try testing.expectEqual(@as(usize, 2), tree.len());
    try expectSound(&tree);
    try testing.expectError(error.Overflow, SlabBTree.fromSlice(testing.allocator, &.{ simple(1, hi), simple(1, 1) }));
}

test "range comparisons do not overflow translated endpoints" {
    const hi = std.math.maxInt(i64);
    const lo = std.math.minInt(i64);
    try testing.expect(simple(1, 1).contains(hi, hi));
    try testing.expect(!simple(1, 1).contains(lo, hi));
    try testing.expect(simple(1, -1).overlaps(lo, lo, lo));
    try testing.expect(!simple(1, -1).overlaps(hi, hi, lo));
}

test "a structural split refuses relative overflow without changing source slabs" {
    const hi = std.math.maxInt(i64);
    var aggs = [_]SlabAgg{simple(1, 0)} ** branch_factor;
    aggs[0] = simple(1, -hi);
    aggs[40] = simple(1, hi);
    aggs[41] = simple(1, 1);
    aggs[42] = simple(1, -1);
    var tree = try SlabBTree.fromSlice(testing.allocator, &aggs);
    defer tree.deinit();
    const before = tree.rootAgg();
    try testing.expectError(error.Overflow, tree.splice(0, 0, &.{simple(1, 0)}));
    try testing.expectEqualDeep(before, tree.rootAgg());
    try testing.expectEqual(branch_factor, tree.len());
    var prefix: i64 = 0;
    for (aggs, 0..) |a, i| {
        try testing.expectEqual(FoundSlab{ .index = i, .prefix = prefix, .items_before = i }, try findSlabAtItem(&tree, i));
        prefix = try std.math.add(i64, prefix, a.total);
    }
    try expectSound(&tree);
}

test "a multi-leaf rewrite checks its final summaries instead of partial publication" {
    const hi = std.math.maxInt(i64);
    var aggs = [_]SlabAgg{simple(1, 0)} ** (branch_factor * 2);
    aggs[0] = simple(1, hi);
    aggs[branch_factor] = simple(1, -hi);
    var tree = try SlabBTree.fromSlice(testing.allocator, &aggs);
    defer tree.deinit();
    aggs[0] = simple(1, -hi);
    aggs[branch_factor] = simple(1, hi);
    try tree.splice(0, aggs.len, &aggs);
    try testing.expectEqualDeep(try referenceRoot(&aggs), tree.rootAgg());
    try testing.expectEqual(FoundSlab{ .index = branch_factor, .prefix = -hi, .items_before = branch_factor }, try findSlabAtItem(&tree, branch_factor));
    try expectSound(&tree);
}

test "allocation refusal during structural preflight leaves the source readable" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const initial = [_]SlabAgg{ simple(1, 3), simple(1, -1) };
    var tree = try SlabBTree.fromSlice(failing.allocator(), &initial);
    defer tree.deinit();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, tree.splice(1, 1, &.{simple(1, 4)}));
    try testing.expectEqual(@as(usize, 2), tree.len());
    try testing.expectEqualDeep(try referenceRoot(&initial), tree.rootAgg());
    try testing.expectEqual(FoundSlab{ .index = 1, .prefix = 3, .items_before = 1 }, try findSlabAtItem(&tree, 1));
}

test "the composition adapter preserves infallible aggregate providers" {
    const Maximum = struct {
        value: usize,
        const Weight = @This();
        pub const Aggregate = struct {
            pub const identity: Weight = .{ .value = 0 };
            pub fn merge(left: Weight, right: Weight) Weight {
                return .{ .value = @max(left.value, right.value) };
            }
            pub fn itemCount(_: Weight) usize {
                return 0;
            }
            pub fn eql(left: Weight, right: Weight) bool {
                return left.value == right.value;
            }
        };
    };
    var tree = try Tree(Maximum).fromSlice(testing.allocator, &.{ .{ .value = 4 }, .{ .value = 9 } });
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 9), tree.rootAgg().value);
    try tree.updateSlab(0, .{ .value = 12 });
    try testing.expectEqual(@as(usize, 12), tree.rootAgg().value);
    try tree.splice(1, 2, &.{});
    try testing.expectEqual(@as(usize, 12), tree.rootAgg().value);
}

test "checked row totals retain the full usize boundary" {
    const max = std.math.maxInt(usize);
    var tree = try SlabBTree.fromSlice(testing.allocator, &.{ simple(max - 1, 0), simple(1, 0) });
    defer tree.deinit();
    try testing.expectEqual(max, tree.rootAgg().len);
    try testing.expectEqual(max, tree.itemsBeforeSlab(2));
    try testing.expectEqual(SlabBTree.PositionalHit{ .slab = 1, .items_before = max - 1 }, tree.findByPrefix(max - 1).?);
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(max));
    try testing.expectError(error.Overflow, tree.updateSlab(1, simple(2, 0)));
    try testing.expectEqual(max, tree.rootAgg().len);
    try testing.expectError(error.Overflow, SlabBTree.fromSlice(testing.allocator, &.{ simple(max, 0), simple(1, 0) }));
}

test "prefix-sum queries explicitly refuse overflowing ancestor translations" {
    const Increment = struct {
        fn increment(a: SlabAgg) i64 {
            return if (a.len == 1) std.math.minInt(i64) else -1;
        }
    };
    var tree = try SlabBTree.fromSlice(testing.allocator, &.{ simple(1, 0), simple(2, 0) });
    defer tree.deinit();
    try testing.expectError(error.Overflow, tree.findByPrefixSum(Increment.increment, 0));
    try testing.expectEqual(@as(i64, 0), tree.rootAgg().total);
}

/// A slab whose items all carry the prefix increment `total` (upstream
/// `simple_agg`, `btree.rs:1706-1713`).
fn simple(len: usize, total: i64) SlabAgg {
    return SlabAgg.uniform(len, total);
}

/// The reference answer for `findByValue`: every slab whose value range
/// contains `target` (`btree.rs:1678-1690`).
fn referenceByValue(aggs: []const SlabAgg, target: i64, out: *std.ArrayList(ValueHit)) !void {
    var prefix: i64 = 0;
    var items_before: usize = 0;
    for (aggs, 0..) |a, i| {
        if (a.contains(target, prefix)) {
            try out.append(testing.allocator, .{
                .slab = i,
                .items_before = items_before,
                .prefix_before = prefix,
            });
        }
        prefix = try std.math.add(i64, prefix, a.total);
        items_before = try std.math.add(usize, items_before, a.len);
    }
}

/// The reference answer for `findByValueRange` (`btree.rs:1692-1704`).
fn referenceByRange(aggs: []const SlabAgg, lo: i64, hi: i64, out: *std.ArrayList(ValueHit)) !void {
    var prefix: i64 = 0;
    var items_before: usize = 0;
    for (aggs, 0..) |a, i| {
        if (a.overlaps(lo, hi, prefix)) {
            try out.append(testing.allocator, .{
                .slab = i,
                .items_before = items_before,
                .prefix_before = prefix,
            });
        }
        prefix = try std.math.add(i64, prefix, a.total);
        items_before = try std.math.add(usize, items_before, a.len);
    }
}

/// The reference answer for `findByPrefix`.
fn referenceByPrefix(aggs: []const SlabAgg, pos: usize) ?SlabBTree.PositionalHit {
    var items_before: usize = 0;
    for (aggs, 0..) |a, i| {
        if (pos < items_before + a.len) {
            return .{ .slab = i, .items_before = items_before };
        }
        items_before += a.len;
    }
    return null;
}

/// The reference root aggregate: every slab merged left to right.
fn referenceRoot(aggs: []const SlabAgg) error{Overflow}!SlabAgg {
    var acc = SlabAgg.zero;
    for (aggs) |a| acc = try SlabAgg.Aggregate.merge(acc, a);
    return acc;
}

fn expectSound(tree: anytype) !void {
    if (try tree.checkInvariants()) |v| {
        var buf: [256]u8 = undefined;
        std.debug.print("invariant violated: {s}\n", .{v.describe(&buf)});
        return error.InvariantViolation;
    }
}

test "a fresh tree is empty and finds nothing" {
    const gpa = testing.allocator;
    const init: *const fn (std.mem.Allocator) std.mem.Allocator.Error!SlabBTree = SlabBTree.init;
    var tree = try init(gpa);
    defer tree.deinit();

    try testing.expect(tree.isEmpty());
    try testing.expectEqual(0, tree.len());
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), SlabAgg.zero));
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(0));
    try testing.expectEqual(0, tree.itemsBeforeSlab(0));

    var hit = try FindByValue.init(&tree, 0);
    defer hit.deinit();
    try testing.expectEqual(@as(?ValueHit, null), try hit.next());
    try expectSound(&tree);
}

test "a monotone column's weight spans the offsets zero to total" {
    const w = try SlabAgg.monotone(3, 7);
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqual(@as(i64, 7), w.total);
    try testing.expectEqual(@as(i64, 0), w.min_offset);
    try testing.expectEqual(@as(i64, 7), w.max_offset);

    // Two of them: the right slab's offsets shift by the left's total,
    // which is what the order-sensitive merge is for.
    const two = try SlabAgg.Aggregate.merge(w, w);
    try testing.expectEqual(@as(usize, 6), two.len);
    try testing.expectEqual(@as(i64, 14), two.total);
    try testing.expectEqual(@as(i64, 0), two.min_offset);
    try testing.expectEqual(@as(i64, 14), two.max_offset);
    // And a negative delta is representable, which a `usize` total is not.
    const back = SlabAgg.uniform(2, -4);
    try testing.expect(back.contains(-4, 0));
    try testing.expect(back.contains(0, 0));
    try testing.expect(!back.contains(1, 0));
}

test "fromSlice builds a multi-level tree" {
    const gpa = testing.allocator;
    var aggs: [100]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(3, @intCast(i + 1));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    try testing.expectEqual(100, tree.len());
    try testing.expectEqual(@as(usize, 300), tree.rootAgg().len);
    try testing.expectEqual(@as(i64, 5050), tree.rootAgg().total);
    try expectSound(&tree);

    // 100 slabs is one internal level above the leaves.
    try testing.expectEqual(@as(usize, 1), tree.subtreeHeight(tree.root));
    for (0..aggs.len) |i| {
        try testing.expectEqual(
            SlabBTree.PositionalHit{ .slab = i, .items_before = i * 3 },
            tree.findByPrefix(i * 3).?,
        );
    }
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(300));
}

test "subtree height counts internal levels, and an empty internal node has none" {
    const gpa = testing.allocator;
    // `branch_factor` leaves need one more internal level to hold them, so
    // `branch_factor^2 + 1` slabs is leaves under internals under the root.
    const aggs = try gpa.alloc(SlabAgg, branch_factor * branch_factor + 1);
    defer gpa.free(aggs);
    for (aggs) |*a| a.* = simple(1, 1);
    var tree = try SlabBTree.fromSlice(gpa, aggs);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.subtreeHeight(tree.root));

    // An internal node with no children is 0, not 1 (`subtree_height`,
    // `btree.rs:764-770`). This is the only case where
    // `if … else 1 + h` and `(if … else 1) + h` disagree, and it is what
    // the `1 +` living inside the else branch, rather than around the `if`,
    // is for: the other reading returns 1 here and indexes `n.items[0]` on
    // an empty list. No tree built by the public API holds such a node, so
    // it is made here.
    const empty = try tree.alloc(.{ .internal = .empty });
    try testing.expectEqual(@as(usize, 0), tree.subtreeHeight(empty));

    // A leaf is 0 and an internal node over it is 1, so the count is the
    // first child's plus the one level the node itself is.
    var leaf: std.ArrayList(SlabAgg) = .empty;
    try leaf.append(gpa, simple(1, 1));
    const leaf_id = try tree.alloc(.{ .leaf = leaf });
    try testing.expectEqual(@as(usize, 0), tree.subtreeHeight(leaf_id));

    var children: std.ArrayList(SlabBTree.ChildSlot) = .empty;
    try children.append(gpa, .{ .id = leaf_id, .agg = simple(1, 1), .slab_count = 1 });
    const parent = try tree.alloc(.{ .internal = children });
    try testing.expectEqual(@as(usize, 1), tree.subtreeHeight(parent));
}

test "findByPrefix answers every item boundary" {
    const gpa = testing.allocator;
    const aggs = [_]SlabAgg{simple(5, 10)} ** 10;
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 0, .items_before = 0 },
        tree.findByPrefix(0).?,
    );
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 0, .items_before = 0 },
        tree.findByPrefix(4).?,
    );
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 1, .items_before = 5 },
        tree.findByPrefix(5).?,
    );
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 9, .items_before = 45 },
        tree.findByPrefix(49).?,
    );
    // Past the end.
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(50));
    // `itemsBeforeSlab` is the inverse, and accepts one-past-the-end.
    try testing.expectEqual(@as(usize, 0), tree.itemsBeforeSlab(0));
    try testing.expectEqual(@as(usize, 5), tree.itemsBeforeSlab(1));
    try testing.expectEqual(@as(usize, 50), tree.itemsBeforeSlab(10));
}

test "splice over an equal run is a pure rewrite" {
    const gpa = testing.allocator;
    var aggs: [20]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(1, @intCast(i));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    const before_nodes = tree.nodes.items.len;
    try tree.splice(5, 5, &.{});
    try testing.expectEqual(20, tree.len());
    try testing.expectEqual(before_nodes, tree.nodes.items.len);
    try expectSound(&tree);
}

test "splice replaces a slab in place" {
    const gpa = testing.allocator;
    var aggs: [20]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(2, @intCast(i));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    try tree.splice(10, 11, &.{simple(3, 999)});
    aggs[10] = simple(3, 999);
    try testing.expectEqual(20, tree.len());
    try expectSound(&tree);

    // The item count and the prefix totals followed the rewrite: ten
    // slabs of two items, then the replacement's three.
    try testing.expectEqual(@as(usize, 23), tree.itemsBeforeSlab(11));
    try testing.expectEqual(
        FoundSlab{ .index = 10, .prefix = 45, .items_before = 20 },
        try findSlabAtItem(&tree, 22),
    );
    var want: std.ArrayList(ValueHit) = .empty;
    defer want.deinit(gpa);
    try referenceByValue(&aggs, 10 * 2 + 999, &want);
    var got = try FindByValue.init(&tree, 10 * 2 + 999);
    defer got.deinit();
    for (want.items) |w| try testing.expectEqualDeep(w, (try got.next()).?);
    try testing.expectEqual(@as(?ValueHit, null), try got.next());
}

test "splice grows and then shrinks the tree" {
    const gpa = testing.allocator;
    var aggs: std.ArrayList(SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    for (0..10) |i| try aggs.append(gpa, simple(2, @intCast(i)));
    var tree = try SlabBTree.fromSlice(gpa, aggs.items);
    defer tree.deinit();

    var grown: [5]SlabAgg = undefined;
    for (&grown, 0..) |*a, i| a.* = simple(1, @intCast(100 + i));
    try tree.splice(3, 3, &grown);
    try aggs.replaceRange(gpa, 3, 0, &grown);
    try testing.expectEqual(15, tree.len());
    try expectSound(&tree);

    try tree.splice(7, 11, &.{});
    try aggs.replaceRange(gpa, 7, 4, &.{});
    try testing.expectEqual(11, tree.len());
    try expectSound(&tree);
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), try referenceRoot(aggs.items)));

    // Every value in a wide window must land where a linear scan puts it.
    var target: i64 = -10;
    while (target < 200) : (target += 1) {
        var want: std.ArrayList(ValueHit) = .empty;
        defer want.deinit(gpa);
        try referenceByValue(aggs.items, target, &want);
        var got = try FindByValue.init(&tree, target);
        defer got.deinit();
        var i: usize = 0;
        while (try got.next()) |hit| : (i += 1) {
            try testing.expectEqualDeep(want.items[i], hit);
        }
        try testing.expectEqual(want.items.len, i);
    }
}

test "inserting one slab at a time keeps every invariant" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x51AB);
    const rand = prng.random();

    var aggs: std.ArrayList(SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    var tree = try SlabBTree.init(gpa);
    defer tree.deinit();

    var step: usize = 0;
    while (step < 5000) : (step += 1) {
        const at = rand.intRangeAtMost(usize, 0, aggs.items.len);
        const new_agg = simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100));
        try tree.splice(at, at, &.{new_agg});
        try aggs.insert(gpa, at, new_agg);

        try testing.expectEqual(aggs.items.len, tree.len());
        try expectSound(&tree);
    }

    // The tree is now three levels deep, and every position still resolves
    // to the right slab.
    try testing.expect(tree.subtreeHeight(tree.root) >= 2);
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), try referenceRoot(aggs.items)));
    var items: usize = 0;
    for (aggs.items, 0..) |a, i| {
        const hit = tree.findByPrefix(items).?;
        try testing.expectEqual(i, hit.slab);
        try testing.expectEqual(items, hit.items_before);
        items += a.len;
    }
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(items));
}

test "deleting one slab at a time keeps every invariant" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xD31E7);
    const rand = prng.random();

    var aggs: std.ArrayList(SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    for (0..3000) |_| {
        try aggs.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
    }
    var tree = try SlabBTree.fromSlice(gpa, aggs.items);
    defer tree.deinit();
    const peak_nodes = tree.nodes.items.len;
    try expectSound(&tree);

    // Sequential single deletes: the pattern that used to trigger a full
    // rebuild every 64th delete.
    var left = aggs.items.len;
    while (left > 0) {
        const at = rand.intRangeAtMost(usize, 0, left - 1);
        try tree.splice(at, at + 1, &.{});
        _ = aggs.orderedRemove(at);
        left -= 1;

        try testing.expectEqual(aggs.items.len, tree.len());
        try expectSound(&tree);
    }
    try testing.expectEqual(0, tree.len());
    // Freed nodes go back on the free list rather than leaking: the arena
    // never grew past the bulk-built size.
    try testing.expect(tree.nodes.items.len <= peak_nodes);
    try testing.expect(tree.free.items.len >= peak_nodes - 1);

    // And the emptied tree accepts slabs again.
    try tree.splice(0, 0, &.{simple(5, 5)});
    try testing.expectEqual(1, tree.len());
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 0, .items_before = 0 },
        tree.findByPrefix(0).?,
    );
    try expectSound(&tree);
}

test "point lookup resolves every item of a deep tree" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x9017);
    const rand = prng.random();

    var aggs: std.ArrayList(SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    for (0..700) |_| {
        try aggs.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 8), rand.intRangeAtMost(i64, -50, 50)));
    }
    var tree = try SlabBTree.fromSlice(gpa, aggs.items);
    defer tree.deinit();

    const total_items: usize = blk: {
        var sum: usize = 0;
        for (aggs.items) |a| sum += a.len;
        break :blk sum;
    };
    try testing.expectEqual(total_items, tree.itemsBeforeSlab(aggs.items.len));

    // Every item, including offset 0 and the last one.
    for (0..total_items) |pos| {
        const want = referenceByPrefix(aggs.items, pos).?;
        try testing.expectEqualDeep(want, tree.findByPrefix(pos).?);
        try testing.expect(pos - want.items_before < aggs.items[want.slab].len);

        const found = try findSlabAtItem(&tree, pos);
        try testing.expectEqual(want.slab, found.index);
        try testing.expectEqual(want.items_before, found.items_before);
        var prefix: i64 = 0;
        for (aggs.items[0..want.slab]) |a| prefix += a.total;
        try testing.expectEqual(prefix, found.prefix);
    }
    // One past the end lands after the last slab.
    const past = try findSlabAtItem(&tree, total_items);
    try testing.expectEqual(aggs.items.len, past.index);
    try testing.expectEqual(total_items, past.items_before);
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(total_items));
}

test "findSlabAtPrefix lands on the first slab that reaches the target" {
    const gpa = testing.allocator;
    var aggs: [10]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(5, @intCast((i + 1) * 10));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    // Upstream's cases (btree.rs:1937-1948), with the target a prefix sum.
    try testing.expectEqual(
        FoundSlab{ .index = 0, .prefix = 0, .items_before = 0 },
        try findSlabAtPrefix(&tree, 10),
    );
    try testing.expectEqual(
        FoundSlab{ .index = 1, .prefix = 10, .items_before = 5 },
        try findSlabAtPrefix(&tree, 15),
    );
    try testing.expectEqual(
        FoundSlab{ .index = 3, .prefix = 60, .items_before = 15 },
        try findSlabAtPrefix(&tree, 100),
    );
    // Past the total: one-past-the-end with the full totals.
    try testing.expectEqual(
        FoundSlab{ .index = 10, .prefix = 550, .items_before = 50 },
        try findSlabAtPrefix(&tree, 9999),
    );
}

test "a value range query returns exactly the overlapping slabs" {
    const gpa = testing.allocator;
    // A small tree, so every range of every pair of boundaries is checked.
    const small = [_]SlabAgg{
        simple(1, 10), simple(1, 20), simple(1, -5), simple(1, 7), simple(1, 0),
    };
    var tree = try SlabBTree.fromSlice(gpa, &small);
    defer tree.deinit();

    var lo: i64 = -6;
    while (lo <= 36) : (lo += 1) {
        var hi: i64 = lo;
        while (hi <= 36) : (hi += 1) {
            var want: std.ArrayList(ValueHit) = .empty;
            defer want.deinit(gpa);
            try referenceByRange(&small, lo, hi, &want);

            var got = try FindByValueRange.init(&tree, lo, hi);
            defer got.deinit();
            var i: usize = 0;
            while (try got.next()) |hit| : (i += 1) {
                try testing.expect(i < want.items.len);
                try testing.expectEqualDeep(want.items[i], hit);
            }
            try testing.expectEqual(want.items.len, i);
        }
    }

    // The same query on a deep tree, where whole subtrees must be pruned.
    var prng: std.Random.DefaultPrng = .init(0x1234);
    const rand = prng.random();
    var aggs: [300]SlabAgg = undefined;
    for (&aggs) |*a| a.* = simple(1, rand.intRangeAtMost(i64, -20, 60));
    var deep = try SlabBTree.fromSlice(gpa, &aggs);
    defer deep.deinit();
    try expectSound(&deep);

    for (0..200) |_| {
        const lo_i = rand.intRangeAtMost(i64, -500, 500);
        const hi_i = lo_i + rand.intRangeAtMost(i64, 0, 200);
        var want: std.ArrayList(ValueHit) = .empty;
        defer want.deinit(gpa);
        try referenceByRange(&aggs, lo_i, hi_i, &want);
        var got = try FindByValueRange.init(&deep, lo_i, hi_i);
        defer got.deinit();
        var i: usize = 0;
        while (try got.next()) |hit| : (i += 1) {
            try testing.expect(i < want.items.len);
            try testing.expectEqualDeep(want.items[i], hit);
        }
        try testing.expectEqual(want.items.len, i);
    }
}

test "a value query finds the one slab holding a rare value" {
    const gpa = testing.allocator;
    var aggs: [1000]SlabAgg = undefined;
    for (&aggs) |*a| a.* = simple(1, 1);
    aggs[500] = simple(1, 10_000);
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    var got = try FindByValue.init(&tree, 500 + 10_000);
    defer got.deinit();
    const first = (try got.next()).?;
    try testing.expectEqual(@as(usize, 500), first.slab);
    try testing.expectEqual(@as(usize, 500), first.items_before);
    // The next slab starts exactly where the big one ended, and the
    // comparison is inclusive, so it is reported too — and nothing after.
    const second = (try got.next()).?;
    try testing.expectEqual(@as(usize, 501), second.slab);
    try testing.expectEqual(@as(i64, 10_500), second.prefix_before);
    try testing.expectEqual(@as(?ValueHit, null), try got.next());
}

test "updateSlab rewrites the aggregate and its ancestors" {
    const gpa = testing.allocator;
    var aggs: [200]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(1, @intCast(i + 1));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    var prefix_before: i64 = 0;
    for (aggs[0..100]) |a| prefix_before += a.total;
    try tree.updateSlab(100, simple(1, 999_999));
    try testing.expectEqual(aggs.len, tree.len());
    try expectSound(&tree);

    var got = try FindByValue.init(&tree, prefix_before + 999_999);
    defer got.deinit();
    try testing.expectEqual(@as(usize, 100), (try got.next()).?.slab);

    // A single-slab tree has nothing to refresh above it.
    var one = try SlabBTree.fromSlice(gpa, &.{simple(3, 10)});
    defer one.deinit();
    try one.updateSlab(0, simple(5, 20));
    try testing.expectEqual(@as(i64, 20), one.rootAgg().total);
    try testing.expectError(error.InvalidIndex, one.updateSlab(1, simple(1, 1)));
}

test "deleting a whole tree, then refilling it, stays sound" {
    const gpa = testing.allocator;
    var aggs: [65]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(1, @intCast(i + 1));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    try tree.splice(0, 65, &.{});
    try testing.expectEqual(0, tree.len());
    try expectSound(&tree);

    try tree.splice(0, 0, &.{simple(1, 5)});
    try testing.expectEqual(1, tree.len());
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 0, .items_before = 0 },
        tree.findByPrefix(0).?,
    );
    try expectSound(&tree);
}

test "a bulk splice that replaces the whole tree is sound at every size" {
    // **A replacement can need more leaves than one node holds, and the root
    // it grows has to be grouped rather than filled.** `makeLeaves` makes one
    // slot per leaf, so replacing a whole tree with more than
    // `branch_factor` slabs arrives at the root-overflow arm of
    // `propagateSplits` with more than `branch_factor` slots. Putting them
    // all into one new root produced a node that was itself overfull: at 4097
    // slabs a root of 65 children, at 4167 a root of 66, at 8192 a root of
    // 128. A straight `fromSlice` build cannot reach that shape, because it
    // adds a level at a time, which is why a load-then-edit column was sound
    // and this one was not.
    //
    // The sizes bracket the branch factor and its powers, where a leaf count
    // crosses a node's capacity. Each case is also checked for *answers*, not
    // only for structure: a sound tree that resolved the wrong slabs would
    // pass `expectSound` and be wrong.
    const gpa = testing.allocator;
    const sizes = [_]usize{
        1,   2,   63,  64,  65,  66,   127,  128,  129,  191,  192,  193,
        255, 256, 257, 320, 321, 4095, 4096, 4097, 4167, 8192, 8193,
    };
    for (sizes) |n| {
        const initial = [_]SlabAgg{ simple(1, 0), simple(1, 1) };
        var tree = try SlabBTree.fromSlice(gpa, &initial);
        defer tree.deinit();

        const fresh = try gpa.alloc(SlabAgg, n);
        defer gpa.free(fresh);
        for (fresh, 0..) |*a, i| a.* = simple(1, @intCast(i));

        try tree.splice(0, tree.len(), fresh);
        try testing.expectEqual(n, tree.len());
        try expectSound(&tree);

        // The aggregate survives the regrouping: every slab holds one item,
        // so the root's length is the whole column's item count.
        try testing.expectEqual(n, tree.rootAgg().len);
        // And the index still resolves a position in the middle to the slab
        // that holds it, with the right count of items in front.
        const mid = n / 2;
        const hit = tree.findByPrefix(@intCast(mid)).?;
        try testing.expectEqual(mid, hit.slab);
        try testing.expectEqual(mid, hit.items_before);
    }
}

test "deleting an exact internal span leaves the rest intact" {
    const gpa = testing.allocator;
    const n = branch_factor * branch_factor * 3;
    const aggs = try gpa.alloc(SlabAgg, n);
    defer gpa.free(aggs);
    for (aggs, 0..) |*a, i| a.* = simple(1, @intCast(i));

    var tree = try SlabBTree.fromSlice(gpa, aggs);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.subtreeHeight(tree.root));

    // Exactly one middle internal node's span.
    try tree.splice(4096, 8192, &.{});
    try testing.expectEqual(n - 4096, tree.len());
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 5000, .items_before = 5000 },
        tree.findByPrefix(5000).?,
    );
    try testing.expectEqual(@as(usize, n - 4096), tree.rootAgg().len);
    try expectSound(&tree);
}

test "deleting every slab but one collapses the root onto the leaf" {
    const gpa = testing.allocator;
    var aggs: [65]SlabAgg = undefined;
    for (&aggs, 0..) |*a, i| a.* = simple(1, @intCast(i + 1));
    var tree = try SlabBTree.fromSlice(gpa, &aggs);
    defer tree.deinit();

    try tree.splice(0, 64, &.{});
    try testing.expectEqual(1, tree.len());
    try testing.expectEqual(
        SlabBTree.PositionalHit{ .slab = 0, .items_before = 0 },
        tree.findByPrefix(0).?,
    );
    try testing.expectEqual(@as(usize, 0), tree.subtreeHeight(tree.root));
    try expectSound(&tree);
}

test "a mass deletion collapses the root" {
    const gpa = testing.allocator;
    const n = branch_factor * branch_factor + 5;
    const aggs = try gpa.alloc(SlabAgg, n);
    defer gpa.free(aggs);
    for (aggs, 0..) |*a, i| a.* = simple(1, @intCast(i));
    var tree = try SlabBTree.fromSlice(gpa, aggs);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 2), tree.subtreeHeight(tree.root));

    try tree.splice(5, n, &.{});
    try testing.expectEqual(5, tree.len());
    try testing.expect(tree.subtreeHeight(tree.root) <= 1);
    for (0..5) |i| {
        try testing.expectEqual(
            SlabBTree.PositionalHit{ .slab = i, .items_before = i },
            tree.findByPrefix(i).?,
        );
    }
    try expectSound(&tree);
}

test "a spliced range is applied in slab order" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xFEED);
    const rand = prng.random();

    // The smallest tree that can hold a slab: one item.
    var tree = try SlabBTree.fromSlice(gpa, &.{});
    defer tree.deinit();

    var aggs: std.ArrayList(SlabAgg) = .empty;
    defer aggs.deinit(gpa);
    for (0..3) |_| try aggs.append(gpa, simple(1, rand.intRangeAtMost(i64, -5, 5)));

    // A bulk insert into an empty tree goes through the bulk build, not
    // through the leaf-by-leaf path.
    try tree.splice(0, 0, aggs.items);
    try testing.expectEqual(3, tree.len());
    try expectSound(&tree);
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), try referenceRoot(aggs.items)));
}

/// A tree deep enough for every structural rule to apply: `2 * B²` slabs
/// give 128 leaves, two internal levels, and an internal root whose
/// children are internal nodes themselves.
fn deepTree(gpa: std.mem.Allocator) !SlabBTree {
    const n = branch_factor * branch_factor * 2;
    const aggs = try gpa.alloc(SlabAgg, n);
    defer gpa.free(aggs);
    for (aggs, 0..) |*a, i| a.* = simple(1, @intCast(i));
    return SlabBTree.fromSlice(gpa, aggs);
}

test "the invariant checker accepts a sound tree" {
    const gpa = testing.allocator;
    var tree = try deepTree(gpa);
    defer tree.deinit();

    try expectSound(&tree);
    try testing.expectEqual(@as(usize, 2), tree.subtreeHeight(tree.root));
    // And it still names a violation in words.
    const v = SlabBTree.Violation{ .kind = .node_overfull, .node = 7, .actual = 65 };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("node 7 holds 65 entries, over the branch factor", v.describe(&buf));
}

test "the invariant checker rejects a corrupted tree" {
    const gpa = testing.allocator;
    const Kind = SlabBTree.ViolationKind;

    // (1) A stale cached child aggregate.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        try expectSound(&tree);
        switch (tree.nodeMut(tree.root).*) {
            .internal => |*n| n.items[0].agg.len = 999,
            .leaf => return error.InvalidIndex,
        }
        try testing.expectEqual(Kind.stale_child_summary, (try tree.checkInvariants()).?.kind);
    }

    // (2) A stale cached slab count.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        switch (tree.nodeMut(tree.root).*) {
            .internal => |*n| n.items[0].slab_count = 3,
            .leaf => return error.InvalidIndex,
        }
        try testing.expectEqual(Kind.stale_child_summary, (try tree.checkInvariants()).?.kind);
    }

    // (3) An overfull leaf.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        const mid = tree.node(tree.root).internal.items[0].id;
        const leaf_id = tree.node(mid).internal.items[0].id;
        switch (tree.nodeMut(leaf_id).*) {
            .leaf => |*l| try l.appendSlice(gpa, &([_]SlabAgg{simple(1, 1)} ** 8)),
            .internal => return error.InvalidIndex,
        }
        const v = (try tree.checkInvariants()).?;
        try testing.expectEqual(Kind.node_overfull, v.kind);
        try testing.expectEqual(branch_factor + 8, v.actual);
    }

    // (4) A root that was never collapsed onto its child.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        switch (tree.nodeMut(tree.root).*) {
            .internal => |*n| _ = n.orderedRemove(1),
            .leaf => return error.InvalidIndex,
        }
        const v = (try tree.checkInvariants()).?;
        try testing.expectEqual(Kind.uncollapsed_root, v.kind);
        try testing.expectEqual(1, v.actual);
    }

    // (5) The same node reached twice.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        switch (tree.nodeMut(tree.root).*) {
            .internal => |*n| n.items[1].id = n.items[0].id,
            .leaf => return error.InvalidIndex,
        }
        try testing.expectEqual(Kind.node_reachable_twice, (try tree.checkInvariants()).?.kind);
    }

    // (6) A live node on the free list.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        try tree.free.append(gpa, tree.root);
        try testing.expectEqual(Kind.free_list_mismatch, (try tree.checkInvariants()).?.kind);
    }

    // (7) A node on the free list twice.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        try tree.splice(0, branch_factor, &.{});
        try testing.expect(tree.free.items.len > 0);
        try tree.free.append(gpa, tree.free.items[0]);
        try testing.expectEqual(Kind.duplicate_free_entry, (try tree.checkInvariants()).?.kind);
    }

    // (8) A leaf emptied in place.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        const mid = tree.node(tree.root).internal.items[0].id;
        const leaf_id = tree.node(mid).internal.items[0].id;
        switch (tree.nodeMut(leaf_id).*) {
            .leaf => |*l| l.clearRetainingCapacity(),
            .internal => return error.InvalidIndex,
        }
        try testing.expectEqual(Kind.node_empty, (try tree.checkInvariants()).?.kind);
    }

    // (9) A leaf rewritten without telling the parent: the count and the
    // total both go stale.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        const mid = tree.node(tree.root).internal.items[0].id;
        const leaf_id = tree.node(mid).internal.items[0].id;
        switch (tree.nodeMut(leaf_id).*) {
            .leaf => |*l| l.items[0] = simple(7, 3),
            .internal => return error.InvalidIndex,
        }
        try testing.expectEqual(Kind.stale_child_summary, (try tree.checkInvariants()).?.kind);
    }

    // (10) Leaves at two different depths: graft the second internal node
    // under the first, so its leaves sit one level deeper than the rest.
    {
        var tree = try deepTree(gpa);
        defer tree.deinit();
        const first = tree.node(tree.root).internal.items[0].id;
        const second = tree.node(tree.root).internal.items[1].id;
        // The grafted slot carries the right summary, so the depth is the
        // only thing wrong with it.
        const summary = try tree.internalSummary(second);
        switch (tree.nodeMut(first).*) {
            .internal => |*n| {
                _ = n.orderedRemove(0);
                try n.insert(gpa, 0, .{ .id = second, .agg = summary.agg, .slab_count = summary.slab_count });
            },
            .leaf => return error.InvalidIndex,
        }
        const v = (try tree.checkInvariants()).?;
        try testing.expectEqual(Kind.non_uniform_depth, v.kind);
        try testing.expectEqual(@as(usize, 2), v.actual);
    }
}

test "the option decides whether a corrupted tree is reported" {
    const gpa = testing.allocator;
    const Kind = SlabBTree.ViolationKind;

    var tree = try deepTree(gpa);
    defer tree.deinit();
    const slabs = tree.len();

    // The root's second child is pointed at its first, and nothing else
    // changes: the arena still holds every node once, the free list still
    // agrees with it, and no accessor walks the graph looking for a node
    // reached twice. A duplicated pointer is the corruption that survives
    // everything the tree does besides checking itself.
    switch (tree.nodeMut(tree.root).*) {
        .internal => |*n| n.items[1].id = n.items[0].id,
        .leaf => return error.InvalidIndex,
    }
    try testing.expectEqual(Kind.node_reachable_twice, (try tree.checkInvariants()).?.kind);

    // A mutation over the corrupted tree succeeds and does not repair it.
    // `assertSound`'s note says the mutation path does not consult the
    // checker in either build; this is the observation of that.
    try tree.splice(0, 1, &.{simple(1, 0)});
    try testing.expectEqual(slabs, tree.len());
    try testing.expectEqual(Kind.node_reachable_twice, (try tree.checkInvariants()).?.kind);

    // **The gate, and both halves of it.** With `-Dslow-path` the assertion
    // refuses the tree; without it the same call returns void. Neither half
    // is decorative: an `assertSound` that always checked would fail this
    // test in a build with no option, and one that never checked would fail
    // it in a build with one, so the pair only passes when the option is
    // read here.
    if (build_options.check_slow_paths) {
        try testing.expectError(error.InvariantViolation, tree.assertSound());
    } else {
        try tree.assertSound();
    }
}

test "mixed splices keep the tree equal to a linear reference" {
    try mixedSpliceSweep(testing.allocator, .{
        .seed = 0xB7EE5,
        .trials = 4,
        .steps = 150,
        .max_start = 600,
    }, false);
}

/// How long a [`mixedSpliceSweep`](btree.zig) runs. The default suite gets
/// the small shape and `-Dslow-path` gets upstream's `fuzz_deep_structural`
/// one (`btree.rs:2360-2372`: 25 trials of 300 steps, over 200 to 1500
/// slabs).
const Sweep = struct {
    seed: u64,
    trials: usize,
    steps: usize,
    /// The widest starting slab count, less 200.
    max_start: usize,
};

/// Every mutation `SlabBTree` has, driven against a linear reference: small
/// and bulk inserts, deletes within a leaf and across leaf and internal
/// boundaries, a leaf-aligned exact-span delete, a k-for-m replacement, an
/// in-place `updateSlab`, and a rare full wipe. Every step checks the slab
/// count, the root aggregate, one positional lookup and two value queries
/// (`fuzz_deep_structural`, `btree.rs:2358-2450`).
///
/// **`gated` is which assertion each step is held to.** The default suite
/// holds every step to [`expectSound`](btree.zig), which always checks; the
/// `-Dslow-path` run holds every step to
/// [`SlabBTree.assertSound`](btree.zig), which checks in that build and does
/// not in any other. One body, so the two runs differ in scale and in which
/// assertion they are held to, and in nothing else.
fn mixedSpliceSweep(gpa: std.mem.Allocator, sweep: Sweep, comptime gated: bool) !void {
    var prng: std.Random.DefaultPrng = .init(sweep.seed);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < sweep.trials) : (trial += 1) {
        const n0 = 200 + rand.intRangeAtMost(usize, 0, sweep.max_start);
        var aggs: std.ArrayList(SlabAgg) = .empty;
        defer aggs.deinit(gpa);
        for (0..n0) |_| {
            try aggs.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
        }
        var tree = try SlabBTree.fromSlice(gpa, aggs.items);
        defer tree.deinit();

        var step: usize = 0;
        while (step < sweep.steps) : (step += 1) {
            const len = aggs.items.len;
            const op = rand.intRangeAtMost(usize, 0, 11);
            switch (op) {
                0...2 => {
                    // Small insert.
                    const at = rand.intRangeAtMost(usize, 0, len);
                    const count = 1 + rand.intRangeAtMost(usize, 0, 2);
                    var ins: std.ArrayList(SlabAgg) = .empty;
                    defer ins.deinit(gpa);
                    for (0..count) |_| {
                        try ins.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
                    }
                    try tree.splice(at, at, ins.items);
                    try aggs.insertSlice(gpa, at, ins.items);
                },
                3 => {
                    // Bulk insert: forces splits and root growth.
                    const at = rand.intRangeAtMost(usize, 0, len);
                    const count = 50 + rand.intRangeAtMost(usize, 0, 150);
                    var ins: std.ArrayList(SlabAgg) = .empty;
                    defer ins.deinit(gpa);
                    for (0..count) |_| {
                        try ins.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
                    }
                    try tree.splice(at, at, ins.items);
                    try aggs.insertSlice(gpa, at, ins.items);
                },
                4...6 => if (len > 0) {
                    const at = rand.intRangeAtMost(usize, 0, len - 1);
                    const count = 1 + rand.intRangeAtMost(usize, 0, @min(len - at, 3) - 1);
                    try tree.splice(at, at + count, &.{});
                    try aggs.replaceRange(gpa, at, count, &.{});
                },
                7 => if (len > 8) {
                    // Delete across leaf and internal boundaries.
                    const at = rand.intRangeAtMost(usize, 0, len - 1);
                    const count = 1 + rand.intRangeAtMost(usize, 0, @max(@min(len - at, len / 4), 1) - 1);
                    try tree.splice(at, at + count, &.{});
                    try aggs.replaceRange(gpa, at, count, &.{});
                },
                8 => if (len > 64) {
                    // A leaf-aligned delete: the exact-span shape.
                    const at = rand.intRangeAtMost(usize, 0, len - 1) / 64 * 64;
                    const count = @min(branch_factor, len - at);
                    try tree.splice(at, at + count, &.{});
                    try aggs.replaceRange(gpa, at, count, &.{});
                },
                9 => if (len > 0) {
                    // Replace k slabs with m.
                    const at = rand.intRangeAtMost(usize, 0, len - 1);
                    const del = 1 + rand.intRangeAtMost(usize, 0, @min(len - at, 4) - 1);
                    const ins_count = rand.intRangeAtMost(usize, 0, 4);
                    var ins: std.ArrayList(SlabAgg) = .empty;
                    defer ins.deinit(gpa);
                    for (0..ins_count) |_| {
                        try ins.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
                    }
                    try tree.splice(at, at + del, ins.items);
                    try aggs.replaceRange(gpa, at, del, ins.items);
                },
                10 => if (len > 0) {
                    const at = rand.intRangeAtMost(usize, 0, len - 1);
                    const new_agg = simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100));
                    try tree.updateSlab(at, new_agg);
                    aggs.items[at] = new_agg;
                },
                else => if (len > 0 and rand.intRangeAtMost(usize, 0, 19) == 0) {
                    try tree.splice(0, len, &.{});
                    aggs.clearRetainingCapacity();
                },
            }

            try testing.expectEqual(aggs.items.len, tree.len());
            if (comptime gated) try tree.assertSound() else try expectSound(&tree);
            try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), try referenceRoot(aggs.items)));

            const total_items: usize = blk: {
                var sum: usize = 0;
                for (aggs.items) |a| sum += a.len;
                break :blk sum;
            };
            if (total_items > 0) {
                try testing.expectEqualDeep(
                    referenceByPrefix(aggs.items, total_items - 1).?,
                    tree.findByPrefix(total_items - 1).?,
                );
                try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(total_items));
            }

            // One value query and one range query per step, against the
            // linear reference.
            {
                const target = rand.intRangeAtMost(i64, -400, 400);
                var want: std.ArrayList(ValueHit) = .empty;
                defer want.deinit(gpa);
                try referenceByValue(aggs.items, target, &want);
                var got = try FindByValue.init(&tree, target);
                defer got.deinit();
                var i: usize = 0;
                while (try got.next()) |hit| : (i += 1) {
                    try testing.expect(i < want.items.len);
                    try testing.expectEqualDeep(want.items[i], hit);
                }
                try testing.expectEqual(want.items.len, i);
            }
            {
                const lo = rand.intRangeAtMost(i64, -400, 400);
                const hi = lo + rand.intRangeAtMost(i64, 0, 200);
                var want: std.ArrayList(ValueHit) = .empty;
                defer want.deinit(gpa);
                try referenceByRange(aggs.items, lo, hi, &want);
                var got = try FindByValueRange.init(&tree, lo, hi);
                defer got.deinit();
                var i: usize = 0;
                while (try got.next()) |hit| : (i += 1) {
                    try testing.expect(i < want.items.len);
                    try testing.expectEqualDeep(want.items[i], hit);
                }
                try testing.expectEqual(want.items.len, i);
            }
        }
    }
}

test "the deep structural sweep holds the tree sound at every mutation" {
    // **Skipped without `-Dslow-path`**, and that skip is the price stated
    // the other way round: this is upstream's own deep fuzz
    // (`btree.rs:2358-2450`), twenty-five trials of three hundred steps over
    // 200 to 1500 slabs, which is what `rust/hexane/CHANGELOG.md:45-46` means
    // when it says the feature was added "so that slow path assertions can
    // be disabled by default". `zig build slow-path` runs it; `zig build
    // test` skips it and reports the skip rather than passing quietly.
    if (!build_options.check_slow_paths) return error.SkipZigTest;
    try mixedSpliceSweep(testing.allocator, .{
        .seed = 0xB7EE5,
        .trials = 25,
        .steps = 300,
        .max_start = 1300,
    }, true);
}

test "Splice is rejected for an out-of-range position" {
    const gpa = testing.allocator;
    var tree = try SlabBTree.fromSlice(gpa, &[_]SlabAgg{simple(1, 1)} ** 3);
    defer tree.deinit();

    try testing.expectError(error.InvalidIndex, tree.splice(0, 4, &.{}));
    try testing.expectError(error.InvalidIndex, tree.splice(3, 2, &.{}));
    try testing.expectEqual(3, tree.len());
    try expectSound(&tree);
}

/// A second weight, of the shape the prefix column's index needs: an item
/// count plus the prefix sum through the end of the slab. It lives in the
/// test because the prefix column is a later phase; what this proves is
/// that the structural code never looks inside the weight
/// (`btree.rs:47-54`).
const PrefixWeight = struct {
    len: usize,
    prefix: usize,

    pub const Aggregate = struct {
        pub const identity: PrefixWeight = .{ .len = 0, .prefix = 0 };
        pub fn merge(l: PrefixWeight, r: PrefixWeight) error{Overflow}!PrefixWeight {
            return .{ .len = try std.math.add(usize, l.len, r.len), .prefix = try std.math.add(usize, l.prefix, r.prefix) };
        }
        pub fn itemCount(w: PrefixWeight) usize {
            return w.len;
        }
        pub fn eql(a: PrefixWeight, b: PrefixWeight) bool {
            return a.len == b.len and a.prefix == b.prefix;
        }
    };
};

test "the tree is generic over the per-slab weight" {
    const gpa = testing.allocator;
    const PrefixTree = Tree(PrefixWeight);
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const rand = prng.random();

    var weights: std.ArrayList(PrefixWeight) = .empty;
    defer weights.deinit(gpa);
    for (0..500) |_| {
        try weights.append(gpa, .{
            .len = 1 + rand.intRangeAtMost(usize, 0, 4),
            .prefix = rand.intRangeAtMost(usize, 0, 20),
        });
    }
    var tree = try PrefixTree.fromSlice(gpa, weights.items);
    defer tree.deinit();
    try expectSound(&tree);

    // Positional lookup reads the item count, exactly as for `SlabAgg`.
    var items: usize = 0;
    for (weights.items, 0..) |w, i| {
        try testing.expectEqual(
            PrefixTree.PositionalHit{ .slab = i, .items_before = items },
            tree.findByPrefix(items).?,
        );
        items += w.len;
    }

    var step: usize = 0;
    while (step < 200) : (step += 1) {
        const at = rand.intRangeAtMost(usize, 0, weights.items.len);
        const w = PrefixWeight{
            .len = 1 + rand.intRangeAtMost(usize, 0, 3),
            .prefix = rand.intRangeAtMost(usize, 0, 10),
        };
        try tree.splice(at, at, &.{w});
        try weights.insert(gpa, at, w);
        try expectSound(&tree);
    }

    // With this weight the root aggregate is a plain sum of both fields.
    var total_len: usize = 0;
    var total_prefix: usize = 0;
    for (weights.items) |w| {
        total_len += w.len;
        total_prefix += w.prefix;
    }
    try testing.expectEqual(total_len, tree.rootAgg().len);
    try testing.expectEqual(total_prefix, tree.rootAgg().prefix);
    try testing.expectEqual(total_len, tree.itemsBeforeSlab(weights.items.len));
}

// ── The differential corpus ──────────────────────────────────────────────────

const corpus = @import("codec_golden.zig");

/// The cases the corpus carries for the delta column's index.
///
/// `page_plus_one` and `two_pages` are the ones a branch factor of 64
/// (`btree.rs:194-197`) makes interesting: 65 slabs is a root with one child
/// that has to split, and 129 is two levels. `all_equal_100` and
/// `all_zero_100` are the shapes where every delta after the first is zero,
/// so a slab's `min_offset` equals its `max_offset` and the range test is as
/// tight as it gets; `ascending_200` and `descending_200` are the two
/// one-sided shapes a prefix sum can take.
const btree_boundary_cases = [_][]const u8{
    "empty",
    "one",
    "all_equal_100",
    "all_zero_100",
    "ascending_200",
    "descending_200",
    "page_plus_one",
    "page_plus_one_descending",
    "page_plus_one_constant",
    "two_pages",
    "random_0",
    "random_6",
    "random_11",
};

/// The slab partitions one case is checked under: everything in one slab,
/// one slab per value, three values per slab, and forty.
///
/// **Four, and not one.** Which items a range query returns does not depend
/// on how the column is cut, so every partition has to give the same answer
/// as the reference — and a tree that only ever holds one slab never
/// descends at all.
const partitions = [_]usize{ 0, 1, 3, 40 };

/// A partition of one case's values into slabs, with the tree over it.
const Partition = struct {
    gpa: std.mem.Allocator,
    /// One aggregate per slab, in the order the reference would build them.
    aggs: std.ArrayList(SlabAgg),
    /// How many items each slab holds.
    lens: std.ArrayList(usize),
    tree: SlabBTree,

    fn deinit(self: *Partition) void {
        self.tree.deinit();
        self.aggs.deinit(self.gpa);
        self.lens.deinit(self.gpa);
    }
};

/// The prefix sum before item `at`, which is the realized value there: a
/// delta stream's first delta is measured from zero, so the prefix before
/// item zero is zero (`delta/mod.rs:428-443`).
fn prefixBefore(values: []const i64, at: usize) i64 {
    if (at == 0) return 0;
    return values[at - 1];
}

/// Cuts `values` into slabs of `chunk` items — one slab for the whole column
/// when `chunk` is zero — and builds the tree over their aggregates.
///
/// **The aggregate is the reference's, not this port's.** The reference
/// computes it from the slab's own deltas, tracking the smallest and largest
/// prefix offset any *run boundary* reaches
/// (`delta/indexed.rs:100-137`); for a column of realized values that is the
/// smallest and largest value in the slab, measured from the prefix before
/// it. A run of equal values puts its boundaries at the same realized value,
/// and an arithmetic run spans the whole progression, so the endpoints are
/// the extremes either way. The port computes the same number over its own
/// slabs in `column.zig`; this builds it directly so the tree is tested
/// against the reference's answers rather than against its own.
fn buildPartition(
    gpa: std.mem.Allocator,
    values: []const i64,
    chunk: usize,
) !Partition {
    var p: Partition = .{
        .gpa = gpa,
        .aggs = .empty,
        .lens = .empty,
        .tree = undefined,
    };
    errdefer {
        p.aggs.deinit(gpa);
        p.lens.deinit(gpa);
    }
    var at: usize = 0;
    while (at < values.len) {
        const end = if (chunk == 0) values.len else @min(at + chunk, values.len);
        const before = prefixBefore(values, at);
        var lo: i64 = std.math.maxInt(i64);
        var hi: i64 = std.math.minInt(i64);
        for (values[at..end]) |v| {
            lo = @min(lo, std.math.sub(i64, v, before) catch return error.CorpusValueTooLarge);
            hi = @max(hi, std.math.sub(i64, v, before) catch return error.CorpusValueTooLarge);
        }
        const last = values[end - 1];
        try p.aggs.append(gpa, .{
            .len = end - at,
            .total = std.math.sub(i64, last, before) catch return error.CorpusValueTooLarge,
            .min_offset = lo,
            .max_offset = hi,
        });
        try p.lens.append(gpa, end - at);
        at = end;
    }
    p.tree = try SlabBTree.fromSlice(gpa, p.aggs.items);
    return p;
}

/// Compares one list of item indices with the reference's, naming the first
/// that differs.
fn expectSameItems(rec: corpus.Record, lo_text: []const u8, hi_text: []const u8, want: []const usize, got: []const usize, chunk: usize) !void {
    if (std.mem.eql(usize, want, got)) return;
    const n = @min(want.len, got.len);
    var at: usize = 0;
    while (at < n and want[at] == got[at]) : (at += 1) {}
    std.debug.print(
        \\
        \\--- btree query mismatch ----------------------------------------------
        \\  case       {s}
        \\  seed       {s}
        \\  range      [{s}, {s})
        \\  partition  {d} items per slab
        \\  reference  {d} items, this port {d}
        \\  first difference at index {d}: reference {d}, this port {d}
        \\
    , .{ rec.case, rec.seed, lo_text, hi_text, chunk, want.len, got.len, at, want[at], got[at] });
    return error.BtreeQueryMismatch;
}

/// Holds the tree's value-range search against the reference's
/// `find_by_range` for every range of one case, under one partition.
fn expectQueries(
    gpa: std.mem.Allocator,
    rec: corpus.Record,
    values: []const i64,
    chunk: usize,
    p: *const Partition,
) !void {
    const queries = rec.queries orelse return error.CorpusRecordMissing;
    for (queries) |q| {
        const lo = std.math.cast(i64, std.fmt.parseInt(i128, q.lo, 10) catch return error.CorpusValueTooLarge) orelse return error.CorpusValueTooLarge;
        const hi = std.math.cast(i64, std.fmt.parseInt(i128, q.hi, 10) catch return error.CorpusValueTooLarge) orelse return error.CorpusValueTooLarge;
        // The reference's range is half open and its own walk takes the
        // closed form one below the upper bound
        // (`delta/indexed.rs:151-154`, `:180-186`).
        var walk = try FindByValueRange.init(&p.tree, lo, hi -% 1);
        defer walk.deinit();
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(gpa);
        while (try walk.next()) |hit| {
            if (hit.slab >= p.lens.items.len) return error.BtreeHitOutOfRange;
            // A hit names a slab, not an item, so the items are the slab's
            // and the ones in range among them are the answer.
            const from = hit.items_before;
            const to = from + p.lens.items[hit.slab];
            if (to > values.len or from > to) return error.BtreeHitOutOfRange;
            for (from..to) |i| {
                if (values[i] >= lo and values[i] < hi) try got.append(gpa, i);
            }
        }
        try expectSameItems(rec, q.lo, q.hi, q.items, got.items, chunk);
    }
}

/// Holds `findSlabAtItem` against the values themselves: every item has to
/// land in the slab the partition puts it in, with that slab's prefix sum
/// and item count.
fn expectItemLookup(rec: corpus.Record, values: []const i64, p: *const Partition) !void {
    for (0..values.len) |i| {
        const hit = try findSlabAtItem(&p.tree, i);
        if (hit.index >= p.lens.items.len or
            hit.items_before > i or
            i >= hit.items_before + p.lens.items[hit.index] or
            hit.prefix != prefixBefore(values, hit.items_before))
        {
            std.debug.print(
                \\
                \\--- btree item lookup mismatch -------------------------------------
                \\  case       {s}
                \\  seed       {s}
                \\  item       {d} of {d}
                \\  this port  slab {d} of {d}, items before {d}, sum before {d}
                \\  the slab holding it holds items {d}..{d}, and the sum before them is {d}
                \\
            , .{ rec.case, rec.seed, i, values.len, hit.index, p.lens.items.len, hit.items_before, hit.prefix, hit.items_before, hit.items_before + p.lens.items[hit.index], prefixBefore(values, hit.items_before) });
            return error.BtreeItemLookupMismatch;
        }
    }
}

/// One golden case, under every partition.
fn btreeCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, rec.codec, "btree-i64")) return error.CorpusCodecUnknown;
    const values = try corpus.expandValues(gpa, rec);
    defer gpa.free(values);
    for (partitions) |chunk| {
        var p = try buildPartition(gpa, values, chunk);
        defer p.deinit();
        try expectQueries(gpa, rec, values, chunk, &p);
        try expectItemLookup(rec, values, &p);
    }
}

test "the tree answers the reference's range queries for every golden case" {
    const gpa = testing.allocator;
    var names = corpus.Names.init(gpa);
    defer names.deinit();

    // The btree records are their own kind rather than a `codec` record, so
    // the count is checked by hand and the family is walked by the body
    // rather than by `eachCase`.
    const text = try corpus.readGolden(gpa);
    defer gpa.free(text);
    var cases: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(corpus.Record, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const rec = parsed.value;
        if (!std.mem.eql(u8, rec.kind, "codec-btree")) continue;
        cases += 1;
        try names.add(rec.case);
        try btreeCase(rec, gpa);
    }
    try testing.expectEqual(@as(usize, 22), cases);
    try names.expectRequired(&btree_boundary_cases);
}
