//! The sequence B-tree (`rust/automerge/src/sequence_tree.rs`).
//!
//! A sequence is an ordered container of opaque elements indexed by position.
//! Insertion and removal are `O(log n)`, which is what makes it the right
//! structure for the payloads a patch carries and for the mirrors a hydrate
//! pass builds: `PatchAction::Insert.values` and `hydrate::List` both store a
//! `SequenceTree` rather than a `Vec` (`patches/patch.rs:57`, `hydrate/list.rs:11`).
//!
//! The tree is a 2-3 B-tree in the CLRS shape: every node holds up to `2 * B`
//! elements, splits at `2 * B - 1`, and keeps a running `length` for its whole
//! subtree so a descent is one comparison per level (`sequence_tree.rs:16-20`,
//! `:147-158`). Upstream stores children by value in a `Vec`; a `std.ArrayList`
//! header is a slice plus a length, so moving a node costs the same three
//! words here as it does there and every move in the port is the same move.
//!
//! Two properties of the upstream code are load-bearing and are kept as they
//! are. First, deletion does not rebalance the root: when the root runs out of
//! elements it is replaced by its first child, which keeps the tree one level
//! shallower than a strict B-tree would (`sequence_tree.rs:117-124`). Second,
//! a node that ends a delete may hold `B - 1` elements, and a node that starts
//! one may hold `B`; the split and merge rules are written against those
//! numbers, not against `2 * B - 1`.
//!
//! Upstream panics on an out-of-range index (`sequence_tree.rs:46-48`,
//! `:109-111`). The port returns `error.InvalidIndex` instead, which is the
//! variant the document API already uses for a bad index
//! (`automerge.rs:1754`), and it checks the index *before* touching the tree so
//! a rejected call leaves the sequence exactly as it was.
//!
//! A cursor is deliberately not here. Upstream resolves one through the op
//! set, which holds the operation ids this tree never sees, so `Cursor` and
//! `MoveCursor` belong to the op set and its cursor module, not to the
//! container (`automerge.rs:1732-1754`, `:1760-1806`, `cursor.rs:33-81`).
//!
const std = @import("std");
const err = @import("error.zig");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const Error = err.Error;

/// The node order. A node splits once it holds `2 * B - 1` elements; the split
/// leaves `B - 1` on each side and lifts the middle element into the parent
/// (`sequence_tree.rs:7`, `:156-158`, `:198-239`).
pub const B: usize = 16;

/// A child slot, and the index within it (`sequence_tree.rs:159-171`).
const ChildPos = struct {
    child_index: usize,
    sub_index: usize,
};

/// The element type of a slice, of a pointer to an array, or of an array.
fn ElemOf(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .pointer => |p| ElemOf(p.child),
        .array => |a| a.child,
        else => V,
    };
}

/// One node of the tree (`sequence_tree.rs:16-20`).
fn Node(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// The elements this node holds, in sequence order.
        elements: std.ArrayList(T) = .empty,
        /// The subtrees sitting between and after `elements`. A leaf has none;
        /// an internal node has exactly `elements.items.len + 1`.
        children: std.ArrayList(Self) = .empty,
        /// The number of elements in this subtree, `elements` included.
        length: usize = 0,

        fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        fn deinit(self: *Self) void {
            for (self.children.items) |*child| child.deinit();
            self.elements.deinit(self.gpa);
            self.children.deinit(self.gpa);
            self.* = undefined;
        }

        fn isLeaf(self: *const Self) bool {
            return self.children.items.len == 0;
        }

        fn isFull(self: *const Self) bool {
            return self.elements.items.len >= 2 * B - 1;
        }

        /// The number of elements in a subtree, counted by walking it. Only
        /// used to re-derive `length` after a split, where the child pointers
        /// are already to hand (`sequence_tree.rs:217-225`).
        fn measure(self: *const Self) usize {
            var total: usize = self.elements.items.len;
            for (self.children.items) |child| total += child.length;
            return total;
        }

        /// The child that holds `index`, and `index` relative to it
        /// (`sequence_tree.rs:161-171`). Upstream panics when the index falls
        /// past the last child, which only a caller bug can cause because the
        /// tree validates the index on the way in.
        fn findChildIndex(self: *const Self, index: usize) Error!ChildPos {
            var cumulative_len: usize = 0;
            for (self.children.items, 0..) |child, child_index| {
                const end = cumulative_len + child.length;
                if (end >= index) {
                    return .{ .child_index = child_index, .sub_index = index - cumulative_len };
                }
                cumulative_len = end + 1;
            }
            return error.InvalidIndex;
        }

        /// The number of elements that precede child `child_index`, separators
        /// included (`sequence_tree.rs:270-275`).
        fn cumulativeIndex(self: *const Self, child_index: usize) usize {
            var total: usize = 0;
            for (self.children.items[0..child_index]) |child| total += child.length + 1;
            return total;
        }

        /// Inserts into a node that is known not to be full
        /// (`sequence_tree.rs:173-194`).
        fn insertIntoNonFullNode(self: *Self, index: usize, element: T) Error!void {
            std.debug.assert(!self.isFull());
            if (self.isLeaf()) {
                // The list is grown before anything is counted, so a failed
                // allocation leaves the subtree exactly as it was.
                try self.elements.insert(self.gpa, index, element);
                self.length += 1;
                return;
            }

            const slot = try self.findChildIndex(index);
            if (self.children.items[slot.child_index].isFull()) {
                try self.splitChild(slot.child_index);
                // The split moved an element up into this node, so the element
                // index of the target changed underneath us (`sequence_tree.rs:183-186`).
                const again = try self.findChildIndex(index);
                try self.children.items[again.child_index].insertIntoNonFullNode(again.sub_index, element);
            } else {
                try self.children.items[slot.child_index].insertIntoNonFullNode(slot.sub_index, element);
            }
            self.length += 1;
        }

        /// Splits the full child at `full_child_index`, lifting its middle
        /// element into this node and its upper half into a new sibling
        /// (`sequence_tree.rs:198-239`).
        fn splitChild(self: *Self, full_child_index: usize) Error!void {
            // The two slots this split fills are reserved, and both upper
            // halves are copied out, before anything moves. From there on
            // nothing can fail, so a split is never left half applied.
            try self.elements.ensureUnusedCapacity(self.gpa, 1);
            try self.children.ensureUnusedCapacity(self.gpa, 1);

            const full = &self.children.items[full_child_index];
            std.debug.assert(full.isFull());

            // `Vec::split_off` upstream (`:209`, `:212`): the upper half gets
            // a buffer of its own, because a list may only be freed through
            // the pointer it was allocated with.
            var upper = try std.ArrayList(T).initCapacity(self.gpa, full.elements.items.len - B);
            errdefer upper.deinit(self.gpa);
            upper.appendSliceAssumeCapacity(full.elements.items[B..]);

            var upper_children: std.ArrayList(Self) = .empty;
            if (!full.isLeaf()) {
                upper_children = try std.ArrayList(Self).initCapacity(self.gpa, full.children.items.len - B);
                errdefer upper_children.deinit(self.gpa);
                upper_children.appendSliceAssumeCapacity(full.children.items[B..]);
            }

            // The head keeps the `B - 1` elements below the split and the `B`
            // children below the split's boundary; the element between them
            // is the one that goes up into this node.
            const middle = full.elements.orderedRemove(B - 1);
            full.elements.items.len = B - 1;
            if (!full.isLeaf()) full.children.items.len = B;

            var successor = Self.init(self.gpa);
            successor.elements = upper;
            successor.children = upper_children;
            full.length = full.measure();
            successor.length = successor.measure();

            self.children.insertAssumeCapacity(full_child_index + 1, successor);
            self.elements.insertAssumeCapacity(full_child_index, middle);
            // `self.length` is deliberately untouched: the split only moved
            // elements around inside the subtree.
        }

        /// Reserves the room `mergeAssumeCapacity` needs, so that the merge
        /// itself cannot fail. Called before the caller gives up the elements
        /// it is about to hand over.
        fn reserveMerge(self: *Self, gpa: Allocator, other: *const Self) Error!void {
            try self.elements.ensureUnusedCapacity(gpa, 1 + other.elements.items.len);
            try self.children.ensureUnusedCapacity(gpa, other.children.items.len);
        }

        /// Absorbs `other` around `middle`: this node's elements, then the
        /// separator, then the sibling's (`sequence_tree.rs:413-419`). The
        /// room is already reserved by `reserveMerge`, and `other`'s two
        /// buffers are freed here because their contents now belong to this
        /// node.
        fn mergeAssumeCapacity(self: *Self, middle: T, other: *Self) void {
            self.elements.appendAssumeCapacity(middle);
            self.elements.appendSliceAssumeCapacity(other.elements.items);
            self.children.appendSliceAssumeCapacity(other.children.items);
            self.length += other.length + 1;
            std.debug.assert(self.isFull());

            other.elements.deinit(other.gpa);
            other.children.deinit(other.gpa);
            other.* = undefined;
        }

        fn removeFromLeaf(self: *Self, index: usize) Error!T {
            if (index >= self.elements.items.len) return error.InvalidIndex;
            self.length -= 1;
            return self.elements.orderedRemove(index);
        }

        /// Removes the element at `index`, which the caller has found to be
        /// this node's own at `element_index` (`sequence_tree.rs:246-268`).
        fn removeElementFromNonLeaf(self: *Self, index: usize, element_index: usize) Error!T {
            if (self.children.items[element_index].elements.items.len >= B) {
                // Borrow a replacement from the left neighbour.
                const total_index = self.cumulativeIndex(element_index);
                const predecessor = try self.children.items[element_index].remove(index - 1 - total_index);
                self.length -= 1;
                const removed = self.elements.items[element_index];
                self.elements.items[element_index] = predecessor;
                return removed;
            } else if (self.children.items[element_index + 1].elements.items.len >= B) {
                // Or from the right one.
                const total_index = self.cumulativeIndex(element_index + 1);
                const successor = try self.children.items[element_index + 1].remove(index + 1 - total_index);
                self.length -= 1;
                const removed = self.elements.items[element_index];
                self.elements.items[element_index] = successor;
                return removed;
            } else {
                // Both neighbours are underfull: pull this node's element and
                // the right child into the left one, then remove from the
                // wider subtree.
                self.length -= 1;
                const middle = self.elements.orderedRemove(element_index);
                var successor = self.children.orderedRemove(element_index + 1);
                const left = &self.children.items[element_index];
                try left.reserveMerge(self.gpa, &successor);
                left.mergeAssumeCapacity(middle, &successor);

                const total_index = self.cumulativeIndex(element_index);
                return self.children.items[element_index].remove(index - total_index);
            }
        }

        /// Removes `index` from a child that is underfull, first making that
        /// child big enough by merging or borrowing from a neighbour
        /// (`sequence_tree.rs:277-361`).
        fn removeFromInternalChild(self: *Self, index: usize, child_slot: usize) Error!T {
            // The merge below pulls the child into its left neighbour, and
            // the removal then has to come out of that neighbour
            // (`sequence_tree.rs:299`).
            var child_index = child_slot;
            if (self.children.items[child_index].elements.items.len < B and
                (child_index == 0 or self.children.items[child_index - 1].elements.items.len < B) and
                (child_index + 1 == self.children.items.len or
                    self.children.items[child_index + 1].elements.items.len < B))
            {
                // The child and both neighbours are underfull, so the child is
                // merged with one of them and this node's element between them
                // becomes the median of the new node.
                if (child_index > 0) {
                    const middle = self.elements.orderedRemove(child_index - 1);
                    var successor = self.children.orderedRemove(child_index);
                    child_index -= 1;
                    const left = &self.children.items[child_index];
                    try left.reserveMerge(self.gpa, &successor);
                    left.mergeAssumeCapacity(middle, &successor);
                } else {
                    const middle = self.elements.orderedRemove(child_index);
                    var successor = self.children.orderedRemove(child_index + 1);
                    const left = &self.children.items[child_index];
                    try left.reserveMerge(self.gpa, &successor);
                    left.mergeAssumeCapacity(middle, &successor);
                }
            } else if (self.children.items[child_index].elements.items.len < B) {
                if (child_index > 0 and self.children.items[child_index - 1].elements.items.len >= B) {
                    // Move the left neighbour's last element up into this node
                    // and the element it replaces down into the child, and its
                    // last child along with them.
                    const last = &self.children.items[child_index - 1];
                    const last_element = last.elements.orderedRemove(last.elements.items.len - 1);
                    last.length -= 1;
                    const parent_element = self.elements.items[child_index - 1];
                    self.elements.items[child_index - 1] = last_element;

                    const child = &self.children.items[child_index];
                    try child.elements.insert(self.gpa, 0, parent_element);
                    child.length += 1;

                    if (last.children.items.len > 0) {
                        const last_child = last.children.orderedRemove(last.children.items.len - 1);
                        last.length -= last_child.length;
                        try child.children.insert(self.gpa, 0, last_child);
                        child.length += last_child.length;
                    }
                } else if (child_index + 1 < self.children.items.len and
                    self.children.items[child_index + 1].elements.items.len >= B)
                {
                    // The mirror image: the right neighbour's first element
                    // comes down, and its first child with it.
                    const right = &self.children.items[child_index + 1];
                    const first_element = right.elements.orderedRemove(0);
                    right.length -= 1;
                    const parent_element = self.elements.items[child_index];
                    self.elements.items[child_index] = first_element;

                    const child = &self.children.items[child_index];
                    try child.elements.append(self.gpa, parent_element);
                    child.length += 1;

                    if (right.children.items.len > 0) {
                        const first_child = right.children.orderedRemove(0);
                        right.length -= first_child.length;
                        try child.children.append(self.gpa, first_child);
                        child.length += first_child.length;
                    }
                }
            }

            self.length -= 1;
            const total_index = self.cumulativeIndex(child_index);
            return self.children.items[child_index].remove(index - total_index);
        }

        /// Removes the element at `index` in this subtree
        /// (`sequence_tree.rs:370-411`).
        fn remove(self: *Self, index: usize) Error!T {
            if (self.isLeaf()) return self.removeFromLeaf(index);

            var total_index: usize = 0;
            for (0..self.children.items.len) |child_index| {
                const end = total_index + self.children.items[child_index].length;
                if (end < index) {
                    // The element is further on in the loop.
                    total_index = end + 1;
                    continue;
                }
                if (end == index) {
                    // It is the separator after this child, or — for the last
                    // child, which has none after it — the last separator.
                    const element_index = @min(child_index, self.elements.items.len -| 1);
                    return self.removeElementFromNonLeaf(index, element_index);
                }
                return self.removeFromInternalChild(index, child_index);
            }
            return error.InvalidIndex;
        }

        fn get(self: *const Self, index: usize) ?*const T {
            if (self.isLeaf()) {
                if (index >= self.elements.items.len) return null;
                return &self.elements.items[index];
            }
            var cumulative_len: usize = 0;
            for (self.children.items, 0..) |child, child_index| {
                const end = cumulative_len + child.length;
                switch (std.math.order(end, index)) {
                    .lt => cumulative_len = end + 1,
                    .eq => {
                        if (child_index >= self.elements.items.len) return null;
                        return &self.elements.items[child_index];
                    },
                    .gt => return child.get(index - cumulative_len),
                }
            }
            return null;
        }

        fn getMut(self: *Self, index: usize) ?*T {
            if (self.isLeaf()) {
                if (index >= self.elements.items.len) return null;
                return &self.elements.items[index];
            }
            var cumulative_len: usize = 0;
            for (self.children.items, 0..) |*child, child_index| {
                const end = cumulative_len + child.length;
                switch (std.math.order(end, index)) {
                    .lt => cumulative_len = end + 1,
                    .eq => {
                        if (child_index >= self.elements.items.len) return null;
                        return &self.elements.items[child_index];
                    },
                    .gt => return child.getMut(index - cumulative_len),
                }
            }
            return null;
        }

        /// The shape invariants: `length` counts what the node holds, a leaf
        /// has no children, an internal node has one more child than elements,
        /// and no node is overfull. Upstream's `check` verifies the first of
        /// these (`sequence_tree.rs:363-368`); the rest are what every
        /// descend, split and merge in this file depends on.
        fn checkShape(self: *const Self) err.InternalError!void {
            if (self.elements.items.len > 2 * B - 1) return error.Invariant;
            if (self.children.items.len != 0 and
                self.children.items.len != self.elements.items.len + 1) return error.Invariant;
            var counted: usize = 0;
            for (self.children.items) |child| {
                try child.checkShape();
                counted += child.length;
            }
            if (self.length != self.elements.items.len + counted) return error.Invariant;
        }
    };
}

/// A sequence of `T`, indexed by position, with `O(log n)` insertion and
/// removal (`sequence_tree.rs:8-133`).
pub fn SequenceTree(comptime T: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        root: ?Node(T) = null,

        /// A new, empty sequence.
        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |*root| root.deinit();
            self.root = null;
        }

        /// The number of elements in the sequence.
        pub fn len(self: *const Self) usize {
            return if (self.root) |*root| root.length else 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// An iterator over every element, in sequence order.
        pub fn iter(self: *const Self) Iter(T) {
            return .{ .tree = self, .index = 0, .stop = self.len() };
        }

        /// An iterator over the elements at `[start, end)`, both bounds
        /// clamped to the sequence. A walk of a range costs one tree descent
        /// per element, so it is the same work as a slice of the whole
        /// sequence.
        pub fn iterRange(self: *const Self, start: usize, end: usize) Iter(T) {
            const stop = @min(end, self.len());
            return .{ .tree = self, .index = @min(start, stop), .stop = stop };
        }

        /// Inserts `element` at `index`, shifting the rest right. Returns
        /// `error.InvalidIndex` when `index > len()`, which upstream rejects
        /// with a panic (`sequence_tree.rs:46-48`).
        pub fn insert(self: *Self, index: usize, element: T) Error!void {
            if (index > self.len()) return error.InvalidIndex;

            if (self.root == null) {
                var fresh = Node(T).init(self.gpa);
                errdefer fresh.deinit();
                try fresh.elements.append(self.gpa, element);
                fresh.length = 1;
                self.root = fresh;
                return;
            }

            const root = &self.root.?;
            if (!root.isFull()) {
                try root.insertIntoNonFullNode(index, element);
                return;
            }

            // Grow a level: the full root becomes the first child of a fresh
            // one, the split then lifts its middle element into the new root,
            // and the element goes into whichever half the index falls in
            // (`sequence_tree.rs:55-77`). `old_root` is the three-word header
            // copy `mem::replace` makes upstream, and installing the fresh
            // node first is what keeps the two from sharing a buffer: the old
            // root's lists and the new root's child list must not be the same
            // allocation, or the split below would cut the new root's own
            // child list in half.
            const old_root = root.*;
            root.* = Node(T).init(self.gpa);
            root.length = old_root.length;
            root.children.append(self.gpa, old_root) catch |e| {
                // Nothing was allocated, so the original root goes back whole.
                root.* = old_root;
                return e;
            };
            try root.splitChild(0);

            const first_child_len = root.children.items[0].length;
            if (first_child_len < index) {
                try root.children.items[1].insertIntoNonFullNode(index - (first_child_len + 1), element);
            } else {
                try root.children.items[0].insertIntoNonFullNode(index, element);
            }
            root.length += 1;
        }

        /// Appends `element`.
        pub fn push(self: *Self, element: T) Error!void {
            return self.insert(self.len(), element);
        }

        /// The element at `index`, or null when the index is past the end.
        pub fn get(self: *const Self, index: usize) ?*const T {
            const root: *const Node(T) = if (self.root) |*r| r else return null;
            return root.get(index);
        }

        /// The element at `index` for writing, or null when the index is past
        /// the end. The pointer is invalidated by the next mutation.
        pub fn getMut(self: *Self, index: usize) ?*T {
            const root: *Node(T) = if (self.root) |*r| r else return null;
            return root.getMut(index);
        }

        /// Removes and returns the element at `index`. Returns
        /// `error.InvalidIndex` when the sequence is empty or the index is past
        /// the end (`sequence_tree.rs:109-111`).
        pub fn remove(self: *Self, index: usize) Error!T {
            if (self.root == null or index >= self.len()) return error.InvalidIndex;
            const root = &self.root.?;
            const removed = try root.remove(index);

            // Upstream does not rebalance the root: an element-less root is
            // replaced by its first child, or dropped when it has none
            // (`sequence_tree.rs:117-124`).
            if (root.elements.items.len == 0) {
                if (root.isLeaf()) {
                    root.deinit();
                    self.root = null;
                } else {
                    const child = root.children.orderedRemove(0);
                    root.deinit();
                    self.root = child;
                }
            }
            return removed;
        }

        /// Two sequences are equal when they hold the same elements in the
        /// same order (`sequence_tree.rs:471-478`). The shape of the two trees
        /// is not compared: it is an implementation detail, and a delete leaves
        /// different shapes behind for the same sequence.
        pub fn eql(a: *const Self, b: *const Self) bool {
            if (a.len() != b.len()) return false;
            var ai = a.iter();
            var bi = b.iter();
            while (true) {
                const x = ai.next() orelse return true;
                const y = bi.next() orelse return false;
                if (!std.meta.eql(x.*, y.*)) return false;
            }
        }

        /// Checks the shape invariants of every node. This is upstream's
        /// `check` (`sequence_tree.rs:363-368`) plus the occupancy and arity
        /// rules the mutation code relies on, and it is what the property tests
        /// call after every step.
        pub fn checkInvariants(self: *const Self) err.InternalError!void {
            // A tree with no root holds nothing, which is consistent.
            const root = if (self.root) |*r| r else return;
            try root.checkShape();
            if (root.length != self.len()) return error.Invariant;
        }
    };
}

/// An iterator over the elements of a `SequenceTree` (`sequence_tree.rs:507-527`).
///
/// Each step is a tree descent, so walking `n` elements costs `O(n log n)`,
/// which is upstream's behaviour and the reason a caller that wants a slice
/// copies it rather than walking the tree.
pub fn Iter(comptime T: type) type {
    return struct {
        const Self = @This();

        tree: *const SequenceTree(T),
        /// The next index to read.
        index: usize,
        /// The end of the walk, exclusive.
        stop: usize,

        /// The next element, or null at the end of the walk.
        pub fn next(self: *Self) ?*const T {
            if (self.index >= self.stop) return null;
            const at = self.index;
            self.index += 1;
            return self.tree.get(at);
        }

        /// The element `n` positions on, skipping the ones before it
        /// (`sequence_tree.rs:523-526`).
        pub fn nth(self: *Self, n: usize) ?*const T {
            self.index +|= n;
            return self.next();
        }
    };
}

/// The test element: an id and the `[start, start + length)` range the
/// element covers, the shape an element of a document sequence has. Two
/// elements may overlap, and one may cover nothing at all; the tree stores
/// them in insertion order and knows nothing about either fact.
const Span = struct {
    id: u32,
    start: u32,
    length: u32,

    fn end(self: Span) u32 {
        return self.start + self.length;
    }

    /// True when `position` lies in this span. An empty span covers nothing.
    fn covers(self: Span, position: u32) bool {
        return self.start <= position and position < self.end();
    }
};

/// Every element of `tree` equals the one at the same index of `model`, and
/// the tree's own invariants hold. The element type comes from `model`,
/// because Zig will not infer a type parameter from a `SequenceTree(T)`.
fn expectMatches(tree: anytype, model: anytype) !void {
    const Elem = ElemOf(@TypeOf(model));
    const seq: *const SequenceTree(Elem) = tree;
    const items: []const Elem = model;
    try testing.expectEqual(items.len, seq.len());
    try seq.checkInvariants();
    var i: usize = 0;
    var it = seq.iter();
    while (it.next()) |element| : (i += 1) {
        try testing.expectEqual(items[i], element.*);
    }
    try testing.expectEqual(items.len, i);
}

/// A SplitMix64 generator. The property tests need the index stream proptest
/// generates from its shrinking seeds, reproduced exactly and without taking a
/// dependency on a property-testing framework.
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// A value in `[0, n)`, unbiased enough for a test.
    fn below(self: *Rng, n: usize) usize {
        std.debug.assert(n > 0);
        return @intCast(self.next() % @as(u64, @intCast(n)));
    }
};

/// The base seed of the property tests. Upstream lets proptest pick a fresh
/// random seed per run; the port fixes it so a failure is reproducible, which
/// is what `docs/plan.md` §3 asks for.
const base_seed: u64 = 0x5EED_5EED_0BAD_C0DE;
/// The number of generated cases per property test.
const cases: usize = 5;
/// The number of operations in one case.
const steps: usize = 256;

test "an empty tree" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 0), tree.len());
    try testing.expect(tree.isEmpty());
    try testing.expect(tree.get(0) == null);
    try testing.expect(tree.getMut(0) == null);
    var empty_it = tree.iter();
    try testing.expect(empty_it.next() == null);
    var empty_range = tree.iterRange(0, 10);
    try testing.expect(empty_range.next() == null);
    try tree.checkInvariants();

    // Every mutation that needs an element rejects an empty tree, and the
    // rejection leaves it empty.
    try testing.expectError(error.InvalidIndex, tree.remove(0));
    try testing.expectError(error.InvalidIndex, tree.insert(1, 7));
    try testing.expectEqual(@as(usize, 0), tree.len());
}

test "one element" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    try tree.push(42);
    try testing.expectEqual(@as(usize, 1), tree.len());
    try testing.expect(!tree.isEmpty());
    try testing.expectEqual(@as(u32, 42), tree.get(0).?.*);
    try testing.expect(tree.get(1) == null);

    const slot = tree.getMut(0).?;
    slot.* = 43;
    try testing.expectEqual(@as(u32, 43), tree.get(0).?.*);

    try testing.expectEqual(@as(u32, 43), try tree.remove(0));
    try testing.expectEqual(@as(usize, 0), tree.len());
    try testing.expect(tree.get(0) == null);
}

test "elements that overlap a position are kept in order" {
    const gpa = testing.allocator;
    var tree = SequenceTree(Span).init(gpa);
    defer tree.deinit();

    const spans = [_]Span{
        .{ .id = 1, .start = 0, .length = 5 },
        .{ .id = 2, .start = 3, .length = 4 },
        .{ .id = 3, .start = 6, .length = 1 },
        .{ .id = 4, .start = 2, .length = 2 },
    };
    for (spans) |span| try tree.push(span);
    try expectMatches(&tree, &spans);

    // Three of the four cover position 3, two cover position 6, and one covers
    // position 1. The walk finds exactly those, so an overlapping element
    // neither hides nor displaces its neighbours.
    for ([_]struct { position: u32, count: usize }{
        .{ .position = 3, .count = 3 },
        .{ .position = 6, .count = 2 },
        .{ .position = 1, .count = 1 },
    }) |probe| {
        var covering: usize = 0;
        var it = tree.iter();
        while (it.next()) |span| {
            if (span.covers(probe.position)) covering += 1;
        }
        try testing.expectEqual(probe.count, covering);
    }

    // A range walk returns that range, in order, and nothing outside it.
    var middle: std.ArrayList(Span) = .empty;
    defer middle.deinit(gpa);
    var range_it = tree.iterRange(1, 3);
    while (range_it.next()) |span| try middle.append(gpa, span.*);
    try expectMatches(&tree, &spans);
    try testing.expectEqualSlices(Span, spans[1..3], middle.items);
}

test "an element of zero length" {
    const gpa = testing.allocator;
    var tree = SequenceTree(Span).init(gpa);
    defer tree.deinit();

    const spans = [_]Span{
        .{ .id = 1, .start = 0, .length = 4 },
        .{ .id = 2, .start = 4, .length = 0 },
        .{ .id = 3, .start = 4, .length = 3 },
    };
    for (spans) |span| try tree.push(span);
    try expectMatches(&tree, &spans);

    // An empty element is still an element: it keeps its place in the
    // sequence and it covers no position at all.
    try testing.expect(!spans[1].covers(4));
    try testing.expectEqual(@as(usize, 3), tree.len());

    // Removing it leaves the two that overlap at 4 exactly as they were.
    const empty = try tree.remove(1);
    try testing.expectEqual(@as(u32, 0), empty.length);
    try expectMatches(&tree, spans[0..1] ++ spans[2..3]);
}

test "deleting a middle element" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    var model: std.ArrayList(u32) = .empty;
    defer model.deinit(gpa);
    for (0..100) |i| {
        try tree.push(@intCast(i));
        try model.append(gpa, @intCast(i));
    }
    try expectMatches(&tree, model.items);

    const middle = model.items.len / 2;
    try testing.expectEqual(model.items[middle], try tree.remove(middle));
    _ = model.orderedRemove(middle);
    try expectMatches(&tree, model.items);

    // The rest of the sequence is untouched, from both ends.
    for (model.items, 0..) |value, i| {
        try testing.expectEqual(value, tree.get(i).?.*);
    }
    try testing.expectError(error.InvalidIndex, tree.remove(model.items.len));
}

test "inserting before and after" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    var model: std.ArrayList(u32) = .empty;
    defer model.deinit(gpa);

    // 100 elements at the front, then 100 at the back, alternating so that
    // both ends grow past a node split.
    for (0..100) |i| {
        try tree.insert(0, @intCast(i));
        try model.insert(gpa, 0, @intCast(i));
        try expectMatches(&tree, model.items);
    }
    for (0..100) |i| {
        try tree.push(@intCast(100 + i));
        try model.append(gpa, @intCast(100 + i));
        try expectMatches(&tree, model.items);
    }
    try testing.expectEqual(@as(usize, 200), tree.len());
    try testing.expectEqual(@as(u32, 99), tree.get(0).?.*);
    try testing.expectEqual(@as(u32, 199), tree.get(199).?.*);
}

// The cases below are upstream's own tests, `sequence_tree.rs:545-592`. They
// assert the contents, where upstream only asserts that nothing panics.

test "push_back" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    const model = [_]u32{ 1, 2, 3, 4, 5, 6, 8, 100 };
    for (model) |value| try tree.push(value);
    try expectMatches(&tree, &model);
}

test "insert" {
    const gpa = testing.allocator;
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    var model: std.ArrayList(u32) = .empty;
    defer model.deinit(gpa);
    for ([_]usize{ 0, 1, 0, 0, 0, 3, 4 }) |index| {
        try tree.insert(index, 1);
        try model.insert(gpa, index, 1);
        try expectMatches(&tree, model.items);
    }
    try testing.expectEqual(@as(usize, 7), tree.len());
}

test "insert_book" {
    const gpa = testing.allocator;
    var tree = SequenceTree(void).init(gpa);
    defer tree.deinit();

    for (0..100) |i| {
        try tree.insert(i % 2, {});
        try testing.expectEqual(@as(usize, i + 1), tree.len());
    }
    try tree.checkInvariants();
}

test "insert_book_vec" {
    const gpa = testing.allocator;
    var tree = SequenceTree(void).init(gpa);
    defer tree.deinit();
    var model: std.ArrayList(void) = .empty;
    defer model.deinit(gpa);

    for (0..100) |i| {
        try tree.insert(i % 3, {});
        try model.insert(gpa, i % 3, {});
        try testing.expectEqual(model.items.len, tree.len());
        try tree.checkInvariants();
    }
    try testing.expectEqual(@as(usize, 100), model.items.len);
}

test "two trees are equal when they hold the same elements" {
    const gpa = testing.allocator;
    var a = SequenceTree(u32).init(gpa);
    defer a.deinit();
    var b = SequenceTree(u32).init(gpa);
    defer b.deinit();

    try testing.expect(a.eql(&b));
    for (0..40) |i| try a.push(@intCast(i));
    try testing.expect(!a.eql(&b));
    // The same elements reached by a different route are still equal: the
    // shape of the two trees is not part of the value.
    for (0..40) |i| try b.insert(0, @intCast(39 - i));
    try testing.expect(a.eql(&b));
    _ = try b.remove(19);
    try b.insert(19, 19);
    try testing.expect(a.eql(&b));

    try b.push(1);
    try testing.expect(!a.eql(&b));
    _ = try b.remove(b.len() - 1);
    try testing.expect(a.eql(&b));
}

// Upstream's property tests (`sequence_tree.rs:594-661`). `arb_indices` draws
// a run of `usize` and maps each through `i % len` for the running `len`, so
// every index is in range by construction; a raw index that falls out of range
// rejects the whole case, and the port simply skips that step. The generator
// here is a fixed-seed SplitMix64 rather than proptest, so a failing case is
// reproducible from the seed alone.

test "property: the tree matches a Vec after every insert" {
    const gpa = testing.allocator;
    for (0..cases) |case| {
        var rng = Rng{ .state = base_seed +% @as(u64, @intCast(case)) };
        var tree = SequenceTree(usize).init(gpa);
        defer tree.deinit();
        var model: std.ArrayList(usize) = .empty;
        defer model.deinit(gpa);

        for (0..steps) |step| {
            const index = rng.below(step + 1);
            try tree.insert(index, step);
            try model.insert(gpa, index, step);
            try expectMatches(&tree, model.items);
        }
        try testing.expectEqual(@as(usize, steps), tree.len());
    }
}

test "property: the tree matches a Vec through inserts and removes" {
    const gpa = testing.allocator;
    for (0..cases) |case| {
        var rng = Rng{ .state = base_seed +% @as(u64, @intCast(case)) };
        var tree = SequenceTree(usize).init(gpa);
        defer tree.deinit();
        var model: std.ArrayList(usize) = .empty;
        defer model.deinit(gpa);

        for (0..steps) |step| {
            const index = rng.below(step + 1);
            try tree.insert(index, step);
            try model.insert(gpa, index, step);
            try expectMatches(&tree, model.items);
        }
        // Upstream draws as many removes as inserts and rejects the case when
        // an index falls out of range; half as many keeps the sequence non
        // empty for the whole run, which is what exercises the merges.
        for (0..steps / 2) |_| {
            if (model.items.len == 0) break;
            const index = rng.below(model.items.len);
            try testing.expectEqual(model.items[index], try tree.remove(index));
            _ = model.orderedRemove(index);
            try expectMatches(&tree, model.items);
        }
        try testing.expectEqual(model.items.len, tree.len());
    }
}

test "property: interleaved inserts and removes keep the tree in step" {
    const gpa = testing.allocator;
    for (0..cases) |case| {
        var rng = Rng{ .state = base_seed +% @as(u64, @intCast(case)) };
        var tree = SequenceTree(usize).init(gpa);
        defer tree.deinit();
        var model: std.ArrayList(usize) = .empty;
        defer model.deinit(gpa);

        for (0..steps) |step| {
            // One draw picks the operation and the next the index, so a run
            // alternates between the two in a way neither of the phased
            // tests above ever reaches.
            if ((rng.next() & 1) == 0 or model.items.len == 0) {
                const index = rng.below(model.items.len + 1);
                try tree.insert(index, step);
                try model.insert(gpa, index, step);
            } else {
                const index = rng.below(model.items.len);
                try testing.expectEqual(model.items[index], try tree.remove(index));
                _ = model.orderedRemove(index);
            }
            try expectMatches(&tree, model.items);
        }
    }
}
