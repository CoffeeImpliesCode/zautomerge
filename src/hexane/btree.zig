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

/// The errors the slab index produces. Both variants are drawn from the
/// crate-wide sets in `error.zig`: `Error.InvalidIndex` for a slab
/// position outside the tree, and `OutOfMemory` for the arena.
pub const TreeError = error{ InvalidIndex, OutOfMemory };

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
        pub const identity: SlabAgg = .zero;
        pub fn merge(l: SlabAgg, r: SlabAgg) SlabAgg {
            if (l.len == 0) return r;
            if (r.len == 0) return l;
            return .{
                .len = l.len + r.len,
                .total = l.total + r.total,
                // Order-sensitive on purpose (btree.rs:110-122): the right
                // slab's offsets are relative to the left slab's end.
                .min_offset = @min(l.min_offset, l.total + r.min_offset),
                .max_offset = @max(l.max_offset, l.total + r.max_offset),
            };
        }
        pub fn itemCount(a: SlabAgg) usize {
            return a.len;
        }
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
    pub fn monotone(len: usize, total: usize) SlabAgg {
        return uniform(len, @intCast(total));
    }

    /// Whether the slab's value range, shifted to `prefix_before`, contains
    /// `target` (`btree.rs:138-142`).
    pub fn contains(self: SlabAgg, target: i64, prefix_before: i64) bool {
        return self.len > 0 and
            target >= prefix_before + self.min_offset and
            target <= prefix_before + self.max_offset;
    }

    /// Whether the slab's value range, shifted to `prefix_before`,
    /// overlaps the closed range `[lo, hi]` (`btree.rs:144-148`).
    pub fn overlaps(self: SlabAgg, lo: i64, hi: i64, prefix_before: i64) bool {
        return self.len > 0 and
            prefix_before + self.max_offset >= lo and
            prefix_before + self.min_offset <= hi;
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
/// `A` must declare a namespace `Aggregate` with `identity: A`,
/// `merge(A, A) A`, `itemCount(A) usize` and `eql(A, A) bool`. This is
/// upstream's `SlabAggregate` trait (`btree.rs:47-54`), and the second
/// weight the port needs — the prefix column's `(len, prefix)` — is one
/// more instantiation of it.
pub fn Tree(comptime A: type) type {
    return struct {
        const Self = @This();

        const merge = A.Aggregate.merge;
        const itemCount = A.Aggregate.itemCount;
        const eql = A.Aggregate.eql;
        const identity = A.Aggregate.identity;

        /// One entry of an internal node: a child subtree plus that
        /// subtree's cached aggregate and slab count. The cache is an
        /// algorithmic dependency, not a micro-optimisation: every
        /// top-down walk reads it instead of descending first
        /// (`btree.rs:226-230`).
        const ChildSlot = struct {
            id: NodeId,
            agg: A,
            slab_count: usize,
        };

        /// An aggregate plus a slab count, for a node summarised without
        /// naming it.
        const Summary = struct {
            agg: A,
            slab_count: usize,
        };

        const Node = union(enum) {
            leaf: std.ArrayList(A),
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
            slab: usize,
            items_before: usize,
        };

        /// How far a walk may have to go. Only used to report.
        const max_depth: usize = 32;

        gpa: std.mem.Allocator,
        /// The arena. A `null` slot is a freed node, which is also on
        /// `free`.
        nodes: std.ArrayList(?Node),
        free: std.ArrayList(NodeId),
        root: NodeId,
        total_slabs: usize,

        /// A tree with one empty leaf root and no slabs. The root leaf is
        /// the only node, so a fresh tree holds zero slabs.
        pub fn init(gpa: std.mem.Allocator) TreeError!Self {
            var nodes: std.ArrayList(?Node) = .empty;
            errdefer nodes.deinit(gpa);
            try nodes.append(gpa, .{ .leaf = .empty });
            return .{ .gpa = gpa, .nodes = nodes, .free = .empty, .root = 0, .total_slabs = 0 };
        }

        /// Frees every node still held and the arena itself.
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
            return self.aggOf(self.root);
        }

        /// Bulk-builds a tree over `aggs`: leaves of `branch_factor` slabs,
        /// then one level of internals at a time. This is the shape the
        /// tree has after a column is loaded, so a later incremental edit
        /// starts from the same tree a straight build would have made
        /// (`btree.rs:317-362`).
        pub fn fromSlice(gpa: std.mem.Allocator, aggs: []const A) TreeError!Self {
            var tree = try Self.init(gpa);
            errdefer tree.deinit();
            if (aggs.len == 0) return tree;
            tree.total_slabs = aggs.len;

            var level: std.ArrayList(ChildSlot) = .empty;
            defer level.deinit(gpa);

            var i: usize = 0;
            while (i < aggs.len) : (i += branch_factor) {
                const chunk = aggs[i..@min(i + branch_factor, aggs.len)];
                const leaf = try copyOf(gpa, A, chunk);
                const id = tree.alloc(.{ .leaf = leaf }) catch |e| {
                    var owned = leaf;
                    owned.deinit(gpa);
                    return e;
                };
                try level.append(gpa, .{ .id = id, .agg = mergeAll(chunk), .slab_count = chunk.len });
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
            return tree;
        }

        /// Replaces the aggregate of the slab at `slab_idx`
        /// (`btree.rs:366-410`).
        pub fn updateSlab(self: *Self, slab_idx: usize, new_agg: A) TreeError!void {
            if (slab_idx >= self.total_slabs) return error.InvalidIndex;

            var path: std.ArrayList(PathEntry) = .empty;
            defer path.deinit(self.gpa);

            var remaining = slab_idx;
            var node_id = self.root;
            while (true) {
                switch (self.node(node_id).*) {
                    .leaf => break,
                    .internal => |n| {
                        var picked: ?struct { index: usize, id: NodeId } = null;
                        for (n.items, 0..) |c, i| {
                            if (remaining < c.slab_count) {
                                picked = .{ .index = i, .id = c.id };
                                break;
                            }
                            remaining -= c.slab_count;
                        }
                        // Unreachable while the cached slab counts are
                        // correct, and the bounds check above already
                        // proved the position is inside the tree.
                        const p = picked orelse return error.InvalidIndex;
                        try path.append(self.gpa, .{ .node = node_id, .child = p.index });
                        node_id = p.id;
                    },
                }
            }

            switch (self.nodeMut(node_id).*) {
                .leaf => |l| l.items[remaining] = new_agg,
                .internal => return error.InvalidIndex,
            }

            // The slab count is unchanged, so only the aggregate needs
            // refreshing on the way back up.
            var i = path.items.len;
            while (i > 0) {
                i -= 1;
                const entry = path.items[i];
                const child = self.node(entry.node).internal.items[entry.child].id;
                const agg = self.aggOf(child);
                self.nodeMut(entry.node).internal.items[entry.child].agg = agg;
            }
        }

        /// Replaces the slabs in `[start, end)` with `new` (upstream
        /// `splice`, `btree.rs:412-438`).
        pub fn splice(self: *Self, start: usize, end: usize, new: []const A) TreeError!void {
            if (start > end or end > self.total_slabs) return error.InvalidIndex;
            if (start == end and new.len == 0) return;

            // The common prefix of the removed and inserted runs is a pure
            // in-place rewrite: no structure changes, and the delta below
            // is usually empty.
            const common = @min(end - start, new.len);
            if (common > 0) try self.overwriteRange(start, new[0..common]);

            const delta_start = start + common;
            const delta_new = new[common..];
            if (delta_start == end and delta_new.len == 0) return;
            try self.spliceStructural(delta_start, end, delta_new);
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
            try self.free.ensureTotalCapacity(self.gpa, self.nodes.items.len + 1);
            const id: NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.gpa, new_node);
            return id;
        }

        /// Marks `id` dead and puts it on the free list. Cannot fail: the
        /// free list is kept large enough for one entry per arena slot.
        fn release(self: *Self, id: NodeId) void {
            self.nodes.items[id] = null;
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
        fn aggOf(self: *const Self, id: NodeId) A {
            return switch (self.node(id).*) {
                .leaf => |l| mergeAll(l.items),
                .internal => |n| summarizeSlots(n.items).agg,
            };
        }

        /// The number of slabs under `id` (`btree.rs:1165-1170`).
        fn slabCountOf(self: *const Self, id: NodeId) usize {
            return switch (self.node(id).*) {
                .leaf => |l| l.items.len,
                .internal => |n| summarizeSlots(n.items).slab_count,
            };
        }

        /// The aggregate and slab count of an internal node
        /// (`btree.rs:1154-1163`).
        fn internalSummary(self: *const Self, id: NodeId) Summary {
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
        fn mergeAll(items: []const A) A {
            var acc = identity;
            for (items) |x| acc = merge(acc, x);
            return acc;
        }

        /// Folds the cached child aggregates of an internal node.
        fn summarizeSlots(slots: []const ChildSlot) Summary {
            var acc = identity;
            var slab_count: usize = 0;
            for (slots) |s| {
                acc = merge(acc, s.agg);
                slab_count += s.slab_count;
            }
            return .{ .agg = acc, .slab_count = slab_count };
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
            while (i < slots.len) : (i += branch_factor) {
                const chunk = slots[i..@min(i + branch_factor, slots.len)];
                const children = try copyOf(gpa, ChildSlot, chunk);
                const slot = self.makeInternal(children) catch |e| {
                    var owned = children;
                    owned.deinit(self.gpa);
                    return e;
                };
                try out.append(gpa, slot);
            }
            return out;
        }

        /// Allocates an internal node over `children`, taking ownership of
        /// the list, and returns its slot.
        fn makeInternal(self: *Self, children: std.ArrayList(ChildSlot)) TreeError!ChildSlot {
            const summary = summarizeSlots(children.items);
            const id = self.alloc(.{ .internal = children }) catch |e| {
                var owned = children;
                owned.deinit(self.gpa);
                return e;
            };
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
                const reuse = if (c == 0) first_leaf_id else null;
                const id: NodeId = if (reuse) |known|
                    known
                else
                    blk: {
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
                    .agg = mergeAll(chunk),
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

        /// Rewrites `new` over the slabs starting at `start` without
        /// touching the structure (`overwrite_range`, `btree.rs:442-469`).
        fn overwriteRange(self: *Self, start: usize, new: []const A) TreeError!void {
            var path: std.ArrayList(PathEntry) = .empty;
            defer path.deinit(self.gpa);

            var cursor = start;
            var i: usize = 0;
            while (i < new.len) {
                path.clearRetainingCapacity();
                const loc = (try self.locateLeafForStart(cursor, &path)) orelse return;
                const leaf_len = switch (self.node(loc.leaf).*) {
                    .leaf => |l| l.items.len,
                    .internal => return error.InvalidIndex,
                };
                const local_start = cursor - loc.leaf_start;
                const count = @min(leaf_len - local_start, new.len - i);
                // Only reachable if the cached slab counts are stale;
                // bail rather than spin.
                if (count == 0) return;
                switch (self.nodeMut(loc.leaf).*) {
                    .leaf => |l| @memcpy(l.items[local_start..][0..count], new[i..][0..count]),
                    .internal => return error.InvalidIndex,
                }
                self.updateAncestorAggregates(path.items, loc.leaf);
                cursor += count;
                i += count;
            }
        }

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
            const new_leaf_len = leaf_len + new.len - (end - start);

            if (new_leaf_len <= branch_factor) {
                if (new_leaf_len == 0 and loc.leaf != self.root) {
                    // An empty non-root leaf is not allowed: remove it and
                    // cascade. The root, if it is this leaf, is emptied in
                    // place below.
                    self.removeAndCascade(path.items);
                    self.total_slabs = self.total_slabs + new.len - (end - start);
                    return true;
                }
                switch (self.nodeMut(loc.leaf).*) {
                    .leaf => |*l| try l.replaceRange(self.gpa, local_start, local_end - local_start, new),
                    .internal => return error.InvalidIndex,
                }
                self.updateAncestorAggregates(path.items, loc.leaf);
                self.total_slabs = self.total_slabs + new.len - (end - start);
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
            self.total_slabs = self.total_slabs + new.len - (end - start);
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
            self.total_slabs = self.total_slabs + new.len - (end - start);

            if (new_lca_len == 0) {
                // Every child of the LCA went away. An empty internal node
                // is not allowed: remove the LCA and cascade. A root LCA
                // means the whole tree was deleted, so reset it to an
                // empty leaf in place.
                if (lca_path.len == 0) {
                    self.resetToEmptyLeaf(lca_id);
                } else {
                    self.removeAndCascade(lca_path);
                }
            } else if (new_lca_len <= branch_factor) {
                const summary = self.internalSummary(lca_id);
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
        fn removeAndCascade(self: *Self, path: []const PathEntry) void {
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
                self.updateAncestorAggregates(path[0..i], parent_id);
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

            const combined = siblings[dst_idx].slab_count + siblings[src_idx].slab_count;
            if (combined > branch_factor) return;
            const dst_id = siblings[dst_idx].id;
            const src_id = siblings[src_idx].id;

            var moved = self.takeLeafList(src_id) catch |e| return e;
            defer moved.deinit(self.gpa);
            try self.appendLeafList(dst_id, moved.items);
            self.release(src_id);

            const agg = self.aggOf(dst_id);
            const parent = &self.nodeMut(parent_id).internal;
            parent.items[dst_idx].agg = agg;
            parent.items[dst_idx].slab_count = combined;
            _ = parent.orderedRemove(src_idx);
            self.updateAncestorAggregates(path[0 .. path.len - 1], parent_id);
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
        fn subtreeHeight(self: *const Self, id: NodeId) usize {
            return switch (self.node(id).*) {
                .leaf => 0,
                .internal => |n| if (n.items.len == 0) 0 else 1 + self.subtreeHeight(n.items[0].id),
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
            errdefer tail.deinit(self.gpa);
            {
                const siblings = &self.nodeMut(node_id).internal;
                const buf = try self.gpa.dupe(ChildSlot, siblings.items[first_size..]);
                siblings.shrinkAndFree(self.gpa, first_size);
                tail = .{ .items = buf, .capacity = buf.len };
            }
            defer tail.deinit(self.gpa);

            var out: std.ArrayList(ChildSlot) = .empty;
            errdefer out.deinit(self.gpa);

            const first = self.internalSummary(node_id);
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
                    const summary = self.internalSummary(parent_id);
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
                    const children = replacement;
                    replacement = .empty;
                    const id = self.alloc(.{ .internal = children }) catch |e| {
                        var owned = children;
                        owned.deinit(self.gpa);
                        return e;
                    };
                    self.root = id;
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
        fn updateAncestorAggregates(self: *Self, path: []const PathEntry, leaf_id: NodeId) void {
            var current = leaf_id;
            var i = path.len;
            while (i > 0) {
                i -= 1;
                const agg = self.aggOf(current);
                const count = self.slabCountOf(current);
                const slot = &self.nodeMut(path[i].node).internal.items[path[i].child];
                slot.agg = agg;
                slot.slab_count = count;
                current = path[i].node;
            }
        }

        // ── Positional lookup ────────────────────────────────────────────

        /// The slab holding the `pos`-th item, and the item count strictly
        /// before it. `null` when `pos` is at or past the end
        /// (`find_by_prefix`, `btree.rs:1192-1227`).
        pub fn findByPrefix(self: *const Self, pos: usize) ?PositionalHit {
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

        /// The number of items in the slabs before `slab_idx`. Accepts
        /// `slab_idx == len()` and answers with the total
        /// (`items_before_slab`, `btree.rs:1232-1265`).
        pub fn itemsBeforeSlab(self: *const Self, slab_idx: usize) usize {
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
            /// A cached child aggregate or slab count is stale.
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
                    .stale_child_summary => std.fmt.bufPrint(buf, "node {d} caches the wrong summary for child {d}", .{ at, child }) catch "stale child summary",
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
                    return .{ .slabs = l.items.len, .agg = mergeAll(l.items) };
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
                        slabs += child.slabs;
                        agg = merge(agg, child.agg);
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
pub fn findSlabAtItem(tree: *const SlabBTree, item_idx: usize) FoundSlab {
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
                    prefix += a.total;
                    items_before += a.len;
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
                    prefix += c.agg.total;
                    items_before += c.agg.len;
                    slab_base += c.slab_count;
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
pub fn findSlabAtPrefix(tree: *const SlabBTree, target: i64) FoundSlab {
    var prefix: i64 = 0;
    var items_before: usize = 0;
    var slab_base: usize = 0;
    var node = tree.root;
    while (true) {
        switch (tree.node(node).*) {
            .leaf => |l| {
                for (l.items, 0..) |a, i| {
                    if (target <= prefix + a.total) {
                        return .{ .index = slab_base + i, .prefix = prefix, .items_before = items_before };
                    }
                    prefix += a.total;
                    items_before += a.len;
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
                    if (target <= prefix + c.agg.total) {
                        node = c.id;
                        descended = true;
                        break;
                    }
                    prefix += c.agg.total;
                    items_before += c.agg.len;
                    slab_base += c.slab_count;
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
    pub fn next(self: *FindByValue) ?ValueHit {
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
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before += agg.total;
                    self.stack.items[top].items_before += agg.len;
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
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before += child.agg.total;
                    self.stack.items[top].slab_base += child.slab_count;
                    self.stack.items[top].items_before += child.agg.len;
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
    pub fn next(self: *FindByValueRange) ?ValueHit {
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
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before += agg.total;
                    self.stack.items[top].items_before += agg.len;
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
                    self.stack.items[top].next_child += 1;
                    self.stack.items[top].prefix_before += child.agg.total;
                    self.stack.items[top].slab_base += child.slab_count;
                    self.stack.items[top].items_before += child.agg.len;
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
        prefix += a.total;
        items_before += a.len;
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
        prefix += a.total;
        items_before += a.len;
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
fn referenceRoot(aggs: []const SlabAgg) SlabAgg {
    var acc = SlabAgg.zero;
    for (aggs) |a| acc = SlabAgg.Aggregate.merge(acc, a);
    return acc;
}

fn expectSound(tree: *const SlabBTree) !void {
    if (try tree.checkInvariants()) |v| {
        var buf: [256]u8 = undefined;
        std.debug.print("invariant violated: {s}\n", .{v.describe(&buf)});
        return error.InvariantViolation;
    }
}

test "a fresh tree is empty and finds nothing" {
    const gpa = testing.allocator;
    var tree = try SlabBTree.init(gpa);
    defer tree.deinit();

    try testing.expect(tree.isEmpty());
    try testing.expectEqual(0, tree.len());
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), SlabAgg.zero));
    try testing.expectEqual(@as(?SlabBTree.PositionalHit, null), tree.findByPrefix(0));
    try testing.expectEqual(0, tree.itemsBeforeSlab(0));

    var hit = try FindByValue.init(&tree, 0);
    defer hit.deinit();
    try testing.expectEqual(@as(?ValueHit, null), hit.next());
    try expectSound(&tree);
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
        findSlabAtItem(&tree, 22),
    );
    var want: std.ArrayList(ValueHit) = .empty;
    defer want.deinit(gpa);
    try referenceByValue(&aggs, 10 * 2 + 999, &want);
    var got = try FindByValue.init(&tree, 10 * 2 + 999);
    defer got.deinit();
    for (want.items) |w| try testing.expectEqualDeep(w, got.next().?);
    try testing.expectEqual(@as(?ValueHit, null), got.next());
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
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), referenceRoot(aggs.items)));

    // Every value in a wide window must land where a linear scan puts it.
    var target: i64 = -10;
    while (target < 200) : (target += 1) {
        var want: std.ArrayList(ValueHit) = .empty;
        defer want.deinit(gpa);
        try referenceByValue(aggs.items, target, &want);
        var got = try FindByValue.init(&tree, target);
        defer got.deinit();
        var i: usize = 0;
        while (got.next()) |hit| : (i += 1) {
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
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), referenceRoot(aggs.items)));
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

        const found = findSlabAtItem(&tree, pos);
        try testing.expectEqual(want.slab, found.index);
        try testing.expectEqual(want.items_before, found.items_before);
        var prefix: i64 = 0;
        for (aggs.items[0..want.slab]) |a| prefix += a.total;
        try testing.expectEqual(prefix, found.prefix);
    }
    // One past the end lands after the last slab.
    const past = findSlabAtItem(&tree, total_items);
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
        findSlabAtPrefix(&tree, 10),
    );
    try testing.expectEqual(
        FoundSlab{ .index = 1, .prefix = 10, .items_before = 5 },
        findSlabAtPrefix(&tree, 15),
    );
    try testing.expectEqual(
        FoundSlab{ .index = 3, .prefix = 60, .items_before = 15 },
        findSlabAtPrefix(&tree, 100),
    );
    // Past the total: one-past-the-end with the full totals.
    try testing.expectEqual(
        FoundSlab{ .index = 10, .prefix = 550, .items_before = 50 },
        findSlabAtPrefix(&tree, 9999),
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
            while (got.next()) |hit| : (i += 1) {
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
        while (got.next()) |hit| : (i += 1) {
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
    const first = got.next().?;
    try testing.expectEqual(@as(usize, 500), first.slab);
    try testing.expectEqual(@as(usize, 500), first.items_before);
    // No other slab reaches that value.
    try testing.expectEqual(@as(?ValueHit, null), got.next());
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
    try testing.expectEqual(@as(usize, 100), got.next().?.slab);

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
    try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), referenceRoot(aggs.items)));
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
        switch (tree.nodeMut(first).*) {
            .internal => |*n| {
                _ = n.orderedRemove(0);
                try n.insert(gpa, 0, .{ .id = second, .agg = simple(1, 1), .slab_count = 1 });
            },
            .leaf => return error.InvalidIndex,
        }
        const v = (try tree.checkInvariants()).?;
        try testing.expectEqual(Kind.non_uniform_depth, v.kind);
        try testing.expectEqual(@as(usize, 2), v.actual);
    }
}

test "mixed splices keep the tree equal to a linear reference" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xB7EE5);
    const rand = prng.random();

    var trial: usize = 0;
    while (trial < 4) : (trial += 1) {
        const n0 = 200 + rand.intRangeAtMost(usize, 0, 600);
        var aggs: std.ArrayList(SlabAgg) = .empty;
        defer aggs.deinit(gpa);
        for (0..n0) |_| {
            try aggs.append(gpa, simple(1 + rand.intRangeAtMost(usize, 0, 3), rand.intRangeAtMost(i64, -100, 100)));
        }
        var tree = try SlabBTree.fromSlice(gpa, aggs.items);
        defer tree.deinit();

        var step: usize = 0;
        while (step < 150) : (step += 1) {
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
            try expectSound(&tree);
            try testing.expect(SlabAgg.Aggregate.eql(tree.rootAgg(), referenceRoot(aggs.items)));

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
                while (got.next()) |hit| : (i += 1) {
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
                while (got.next()) |hit| : (i += 1) {
                    try testing.expect(i < want.items.len);
                    try testing.expectEqualDeep(want.items[i], hit);
                }
                try testing.expectEqual(want.items.len, i);
            }
        }
    }
}

test "Splice is rejected for an out-of-range position" {
    const gpa = testing.allocator;
    var tree = try SlabBTree.fromSlice(gpa, &[_]SlabAgg{ simple(1, 1) } ** 3);
    defer tree.deinit();

    try testing.expectError(error.InvalidIndex, tree.splice(0, 4, &.{}));
    try testing.expectError(error.InvalidIndex, tree.splice(3, 2, &.{}));
    try testing.expectEqual(3, tree.len());
    try expectSound(&tree);
}
