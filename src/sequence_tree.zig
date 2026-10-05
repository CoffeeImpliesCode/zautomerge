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
//! **A removal that cannot allocate is refused the same way.** Rust's global
//! allocator cannot fail, so upstream has no second failure to answer for: it
//! rebalances and descends in one breath, with the borrow checker already
//! satisfied (`sequence_tree.rs:246-361`). This port allocates, so the two
//! halves are separated — every rebalance reserves what it needs before its
//! first structural write, and takes the element out before it applies the
//! rebalance. Either way the descent is the only fallible step and it runs
//! while every node above it is still untouched, so a refusal leaves the
//! sequence exactly as it was found: the same elements in the same order, the
//! same `length`, the same shape, and no subtree orphaned by a merge that was
//! half applied. [`remove`](SequenceTree) states it on the declaration and
//! [`checkInvariants`](SequenceTree) lets a caller assert it.
//!
//! An insertion that cannot allocate keeps the same elements in the same order
//! and the same `length`, but it is *not* shape-preserving: a split that has
//! already been paid for stays, because a node that split and did not take the
//! element is still a valid tree. Shape is not part of the value — [`eql`](SequenceTree.eql)
//! does not compare it — so this costs a walk that is slightly better
//! balanced, never an answer that differs.
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
        reserved: bool = false,
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

        fn initWithPolicy(gpa: Allocator, reserved: bool, internal: bool) Error!Self {
            var node = Self.init(gpa);
            errdefer node.deinit();
            node.reserved = reserved;
            if (reserved) {
                node.elements = try std.ArrayList(T).initCapacity(gpa, 2 * B - 1);
                if (internal) {
                    node.children = try std.ArrayList(Self).initCapacity(gpa, 2 * B);
                }
            }
            return node;
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
            const element_capacity = if (self.reserved)
                2 * B - 1
            else
                full.elements.items.len - B;
            var upper = try std.ArrayList(T).initCapacity(self.gpa, element_capacity);
            errdefer upper.deinit(self.gpa);
            upper.appendSliceAssumeCapacity(full.elements.items[B..]);

            var upper_children: std.ArrayList(Self) = .empty;
            if (!full.isLeaf()) {
                const child_capacity = if (self.reserved)
                    2 * B
                else
                    full.children.items.len - B;
                upper_children = try std.ArrayList(Self).initCapacity(self.gpa, child_capacity);
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
            successor.reserved = self.reserved;
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
        /// it is about to hand over. The element slot covers the separator
        /// even in the case where the merge does not carry one across: the
        /// reservation is made before the caller knows which case it is in,
        /// and one unused slot costs nothing.
        fn reserveMerge(self: *Self, gpa: Allocator, other: *const Self) Error!void {
            if (self.reserved) {
                std.debug.assert(self.elements.capacity >=
                    self.elements.items.len + 1 + other.elements.items.len);
                std.debug.assert(self.children.capacity >=
                    self.children.items.len + other.children.items.len);
                return;
            }
            try self.elements.ensureUnusedCapacity(gpa, 1 + other.elements.items.len);
            try self.children.ensureUnusedCapacity(gpa, other.children.items.len);
        }

        /// Absorbs `other` after this node's own elements: the separator, when
        /// there is one, then the sibling's (`sequence_tree.rs:413-419`). The
        /// room is already reserved by `reserveMerge`, and `other`'s two
        /// buffers are freed here because their contents now belong to this
        /// node.
        ///
        /// **`middle` is null where the caller's separator is the element that
        /// came out and the merged node does not need one in its place** —
        /// `removeFromMergedPair` says when that is. This node then gains
        /// `other.length` and no separator, so `other`'s children are exactly
        /// the ones this node was short of. Upstream merges the separator in
        /// unconditionally and takes it back out again from the merged child
        /// (`sequence_tree.rs:260-267`); a port that cannot descend into a
        /// subtree it has already merged has to say which of the two it is
        /// doing, because carrying the separator across would put back the
        /// element that was just removed and count it twice — in the child's
        /// `length` and in the `length` the merge adds for it.
        ///
        /// The result is one element below full, where upstream's would be
        /// full, because the caller takes the element out of one of the two
        /// children before merging them — which is what keeps a refused
        /// descent from leaving this node half merged. Without the separator
        /// it is two below. So what is asserted here is *not overfull*, not
        /// *full*.
        fn mergeAssumeCapacity(self: *Self, middle: ?T, other: *Self) void {
            if (middle) |separator| self.elements.appendAssumeCapacity(separator);
            self.elements.appendSliceAssumeCapacity(other.elements.items);
            self.children.appendSliceAssumeCapacity(other.children.items);
            self.length += other.length + @as(usize, if (middle != null) 1 else 0);
            std.debug.assert(self.elements.items.len <= 2 * B - 1);

            other.elements.deinit(other.gpa);
            other.children.deinit(other.gpa);
            other.* = undefined;
        }

        fn removeFromLeaf(self: *Self, index: usize) Error!T {
            if (index >= self.elements.items.len) return error.InvalidIndex;
            self.length -= 1;
            return self.elements.orderedRemove(index);
        }

        /// Reserves the room a borrow needs: one element and one child, taken
        /// at the front or the back of the two lists.
        fn reserveBorrow(self: *Self) Error!void {
            if (self.reserved) {
                std.debug.assert(self.elements.capacity > self.elements.items.len);
                if (!self.isLeaf()) {
                    std.debug.assert(self.children.capacity > self.children.items.len);
                }
                return;
            }
            try self.elements.ensureUnusedCapacity(self.gpa, 1);
            try self.children.ensureUnusedCapacity(self.gpa, 1);
        }

        /// Removes the element at `offset` of the three-part sequence
        /// `left ++ [middle] ++ right`, then merges `right` into `left`
        /// around `middle`. `element_index` is the separator's index and the
        /// left child's index at once, and `offset` is the target measured
        /// from the start of `left`.
        ///
        /// **The offset counts elements of the pair, so it is measured against
        /// the whole of `left` — its `length`, which is its own elements *and*
        /// the subtrees between them — and not against `left.elements`, which
        /// is the same number only while `left` is a leaf.** Upstream removes
        /// from the merged child it has just built (`sequence_tree.rs:265-266`)
        /// and an index into that child is an index into its whole subtree;
        /// measuring against the elements alone aims the removal at the wrong
        /// element whenever `left` has children of its own.
        ///
        /// **The element comes out of whichever of the three holds it, before
        /// the merge, and the merge's room was reserved by the caller while
        /// both children were still in place.** So the descent is the only
        /// fallible step and it happens before this node has moved at all: a
        /// refusal leaves the node exactly as it was, with both children and
        /// the separator still where they were. Upstream merges first and
        /// descends into the wider subtree, which is the same answer in one
        /// breath — and is not expressible in a port whose descent can be
        /// refused halfway.
        ///
        /// **What the merged child gets in place of the separator depends on
        /// the shape of the two.** Upstream merges the separator in and then
        /// removes it again from the merged child in a second pass
        /// (`:261-266`); this port removes first, so the separator is gone by
        /// the time the merge runs and a replacement has to stand in for it
        /// wherever the merged node's arity needs one. See the body.
        ///
        /// The reservation survives the descent because a removal never grows
        /// the two lists of the node it is called on: it only shrinks them,
        /// or borrows into a *descendant*, which reserves its own room.
        fn removeFromMergedPair(self: *Self, element_index: usize, offset: usize) Error!T {
            const left = &self.children.items[element_index];
            const right = &self.children.items[element_index + 1];
            // The whole of `left`, elements and subtrees alike, because the
            // offset indexes the sequence the pair spells out and not the
            // elements `left` holds on its own.
            const left_len = left.length;

            // The target is whichever of the three holds that offset: an
            // element of `left` before the separator, the separator itself on
            // it, and an element of `right` past it. A caller in
            // `removeElementFromNonLeaf` always wants the separator.
            const removed: T = if (offset < left_len)
                try left.remove(offset)
            else if (offset == left_len)
                self.elements.items[element_index]
            else
                try right.remove(offset - left_len - 1);

            // **A separator between two internal children has to be replaced,
            // not dropped.** Without one the merged node would hold
            // `(Le + 1) + (Re + 1)` children for `Le + Re` elements, and arity
            // wants one more child than elements (`checkShape`). Upstream
            // keeps the separator in place and removes it from the merged
            // child in a second pass (`sequence_tree.rs:260-267`), which this
            // port cannot do — that pass would be a fallible step after the
            // merge was published — so a replacement comes out of `left`
            // *before* the publication instead. It is still the last fallible
            // step, the room it lands in is `left`'s own reservation, and the
            // caller is handed the old separator all the same.
            //
            // A pair of leaves needs no replacement when its separator comes
            // out. A target inside either child instead leaves the separator
            // intact, so that value must still be carried into the merge.
            const replacement: ?T = if (offset == left_len and !left.isLeaf() and !right.isLeaf())
                try left.remove(left.length - 1)
            else
                null;

            const middle = self.elements.orderedRemove(element_index);
            var successor = self.children.orderedRemove(element_index + 1);
            left.mergeAssumeCapacity(if (offset == left_len) replacement else middle, &successor);
            self.length -= 1;
            return removed;
        }

        /// Removes the element at `index`, which the caller has found to be
        /// this node's own at `element_index` (`sequence_tree.rs:246-268`).
        ///
        /// A removal here is failure-atomic: each branch reserves the room it
        /// needs before it moves anything, and the one fallible step is the
        /// descent into a child, which happens while this node is still
        /// whole. See `removeFromMergedPair`.
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
                // the right child into the left one, and take the target out
                // of the pair. The target is this node's own element — `index`
                // is where the separator sits, the separator sits where `left`
                // ends, so the offset below is exactly its position in
                // `left ++ [middle] ++ right` (`sequence_tree.rs:260-267`).
                try self.children.items[element_index].reserveMerge(
                    self.gpa,
                    &self.children.items[element_index + 1],
                );
                return self.removeFromMergedPair(element_index, index - self.cumulativeIndex(element_index));
            }
        }

        /// Removes `index` from a child, rebalancing that child first when it
        /// is underfull (`sequence_tree.rs:277-361`).
        ///
        /// **Every branch reserves what the rebalance needs, then takes the
        /// element out, and only then moves anything.** Upstream rebalances
        /// first and descends into the widened child; this port descends
        /// first and applies the rebalance to the result, which is the same
        /// sequence at the end and the only order a refusal survives: the
        /// descent is the one fallible step, it runs while this node is
        /// untouched, and the rebalance after it is already paid for. So a
        /// refusal leaves the node exactly as it was, and a node never has an
        /// element lifted out from under a half-applied rebalance.
        fn removeFromInternalChild(self: *Self, index: usize, child_slot: usize) Error!T {
            const child_index = child_slot;
            if (self.children.items[child_index].elements.items.len < B and
                (child_index == 0 or self.children.items[child_index - 1].elements.items.len < B) and
                (child_index + 1 == self.children.items.len or
                    self.children.items[child_index + 1].elements.items.len < B))
            {
                // The child and both neighbours are underfull, so the child is
                // merged with one of them and this node's element between them
                // becomes the median of the new node (`sequence_tree.rs:299`).
                // Upstream pulls the child into its left neighbour where there
                // is one, and into its right one otherwise.
                const element_index = if (child_index > 0) child_index - 1 else 0;
                try self.children.items[element_index].reserveMerge(
                    self.gpa,
                    &self.children.items[element_index + 1],
                );
                return self.removeFromMergedPair(element_index, index - self.cumulativeIndex(element_index));
            } else if (self.children.items[child_index].elements.items.len < B) {
                if (child_index > 0 and self.children.items[child_index - 1].elements.items.len >= B) {
                    // Move the left neighbour's last element up into this node
                    // and the element it replaces down into the child, and its
                    // last child along with them.
                    const child = &self.children.items[child_index];
                    try child.reserveBorrow();
                    const removed = try child.remove(index - self.cumulativeIndex(child_index));

                    const last = &self.children.items[child_index - 1];
                    const last_element = last.elements.orderedRemove(last.elements.items.len - 1);
                    last.length -= 1;
                    const parent_element = self.elements.items[child_index - 1];
                    self.elements.items[child_index - 1] = last_element;
                    child.elements.insertAssumeCapacity(0, parent_element);
                    child.length += 1;
                    if (last.children.items.len > 0) {
                        const last_child = last.children.orderedRemove(last.children.items.len - 1);
                        last.length -= last_child.length;
                        child.children.insertAssumeCapacity(0, last_child);
                        child.length += last_child.length;
                    }
                    self.length -= 1;
                    return removed;
                } else if (child_index + 1 < self.children.items.len and
                    self.children.items[child_index + 1].elements.items.len >= B)
                {
                    // The mirror image: the right neighbour's first element
                    // comes down, and its first child with it.
                    const child = &self.children.items[child_index];
                    try child.reserveBorrow();
                    const removed = try child.remove(index - self.cumulativeIndex(child_index));

                    const right = &self.children.items[child_index + 1];
                    const first_element = right.elements.orderedRemove(0);
                    right.length -= 1;
                    const parent_element = self.elements.items[child_index];
                    self.elements.items[child_index] = first_element;
                    child.elements.appendAssumeCapacity(parent_element);
                    child.length += 1;
                    if (right.children.items.len > 0) {
                        const first_child = right.children.orderedRemove(0);
                        right.length -= first_child.length;
                        child.children.appendAssumeCapacity(first_child);
                        child.length += first_child.length;
                    }
                    self.length -= 1;
                    return removed;
                }
            }

            // The child is already wide enough, so the removal goes straight
            // into it and this node only shortens by one — after the descent,
            // because the descent is the fallible step and this node must not
            // have moved when that step is refused.
            const total_index = self.cumulativeIndex(child_index);
            const removed = try self.children.items[child_index].remove(index - total_index);
            self.length -= 1;
            return removed;
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
            if (self.reserved) {
                if (self.elements.capacity < 2 * B - 1) return error.Invariant;
                if (self.isLeaf()) {
                    if (self.children.capacity != 0) return error.Invariant;
                } else {
                    if (self.children.capacity < 2 * B) return error.Invariant;
                }
                for (self.children.items) |child| {
                    if (!child.reserved) return error.Invariant;
                }
            }
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
///
/// **The value is a handle, not the storage.** It owns its nodes, and the only
/// release is [`deinit`](SequenceTree.deinit); copying the struct copies that
/// handle, so two copies point at one set of node buffers and deiniting both
/// frees them twice. Move it, or keep one.
///
/// The elements are stored by value and the tree never looks inside them, so
/// `T` may be anything — but [`eql`](SequenceTree.eql) compares them with
/// `std.meta.eql`, which is only defined for a comparable type. That is the
/// one constraint the signature does not express, and it is a constraint only
/// on the comparison, not on the container.
pub fn SequenceTree(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The allocator every node of this tree was allocated from, and the
        /// one [`deinit`](SequenceTree.deinit) frees them into. It is taken
        /// once, here, and never passed again: a tree that allocated from one
        /// allocator and freed into another is undefined behaviour, and no
        /// per-call `gpa` parameter can make that unrepresentable without
        /// giving up the stored one.
        gpa: Allocator,
        /// The root node, or null while the sequence is empty. A tree with no
        /// root is the state `init` returns and the state a removal that
        /// empties the root returns to; it holds no buffer of its own, so it
        /// needs no `deinit` beyond the one every tree gets.
        root: ?Node(T) = null,
        reserved: bool = false,

        /// A new, empty sequence.
        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        /// A new, empty sequence whose nodes reserve the maximum rebalance
        /// capacity on insertion. Initialization does not allocate. Every valid
        /// removal is allocation-free, even after an insertion refuses memory.
        pub fn initReserved(gpa: Allocator) Self {
            return .{ .gpa = gpa, .reserved = true };
        }

        /// Releases every node of the tree, recursively: both of each node's
        /// lists and, through the root, every node below it. **The allocator
        /// is not released** — `gpa` is a handle this file does not own — and
        /// the elements are not freed either, because they were never copied:
        /// they are the caller's own values, stored by value in the nodes.
        ///
        /// The tree is unusable afterwards. `deinit` leaves `root` null, which
        /// reads as a valid empty tree, so a second call is a harmless no-op
        /// rather than a double free; but nothing may be read from a value
        /// whose elements are gone, and a tree that was moved rather than
        /// deinited must not be deinited twice.
        pub fn deinit(self: *Self) void {
            if (self.root) |*root| root.deinit();
            self.root = null;
        }

        /// The number of elements in the sequence.
        pub fn len(self: *const Self) usize {
            return if (self.root) |*root| root.length else 0;
        }

        /// True when the sequence holds nothing, which is the state a tree is
        /// in before its first `push` and after a removal that emptied it.
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
                var fresh = try Node(T).initWithPolicy(self.gpa, self.reserved, false);
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
            // (`sequence_tree.rs:55-77`). The provisional root borrows the old
            // root until the split succeeds. On refusal, detach that child and
            // release the provisional buffers: publishing an unsplit root with
            // no elements and one child would break the removal descent.
            var fresh = try Node(T).initWithPolicy(self.gpa, self.reserved, true);
            fresh.length = root.length;
            fresh.children.append(self.gpa, root.*) catch |failure| {
                fresh.deinit();
                return failure;
            };
            fresh.splitChild(0) catch |failure| {
                // The failed split has not changed its child. Detach that
                // borrowed root before releasing only the provisional buffers.
                fresh.children.items.len = 0;
                fresh.deinit();
                return failure;
            };
            root.* = fresh;

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
        ///
        /// The pointer borrows a node's own element list, so **it is
        /// invalidated by the next mutation** — an `insert`, a `push` or a
        /// `remove` may split, merge or shrink the very list it points into,
        /// and the read after that is a use-after-free rather than a stale
        /// value. It is not invalidated by a read, by `iter`, or by
        /// `checkInvariants`, none of which writes.
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
        ///
        /// **Failure leaves the sequence exactly as it was** — and that covers
        /// `error.OutOfMemory`, not only the index check. A removal reserves
        /// every rebalance's room before its first structural write and takes
        /// the element out before it applies one, so the only fallible step is
        /// the descent, which runs while every node above it is still whole.
        /// The residue on a refusal is therefore nothing at all: same elements,
        /// same order, same `length`, same shape, no orphaned subtree and no
        /// leaked node. See the module doc for why the order is the other way
        /// round from upstream's.
        /// Trees created with `initReserved` never allocate during removal.
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
            if (root.elements.items.len == 0) return error.Invariant;
            if (root.reserved != self.reserved) return error.Invariant;
            // `checkShape` re-derives every node's `length` from its children
            // (`:423`), so the root's is checked with the rest. It used to be
            // checked a second time here, against `len()` — which is
            // `root.length` (`seq-448`), so the branch could not fire and a
            // reader could believe it was the length check the property tests
            // lean on.
            try root.checkShape();
        }
    };
}

/// An iterator over the elements of a `SequenceTree` (`sequence_tree.rs:507-527`).
///
/// Each step is a tree descent, so walking `n` elements costs `O(n log n)`,
/// which is upstream's behaviour and the reason a caller that wants a slice
/// copies it rather than walking the tree.
///
/// **The iterator borrows the tree and nothing keeps it alive.** `tree` is a
/// raw `*const`, so a walk held across a [`deinit`](SequenceTree.deinit)
/// reads freed memory, and one held across an `insert`, `push` or `remove`
/// reads whatever the rebalancing left in the nodes — which is not a stale
/// value but a use-after-free, because those operations move the very
/// element lists the walk descends into. A caller that wants to mutate while
/// walking therefore copies out what it needs first
/// ([`SequenceTree.get`](SequenceTree.get) has the same rule); the cost of
/// doing so is the `O(n log n)` the walk already charges.
pub fn Iter(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The tree being walked. A borrow, not an owning handle: nothing
        /// here keeps it alive, and the pointer is invalidated by the next
        /// mutation or by `deinit`.
        tree: *const SequenceTree(T),
        /// The next index to read.
        index: usize,
        /// The end of the walk, exclusive. Fixed when the iterator is built,
        /// so it is not re-read from the tree — which is why a walk is only
        /// as long as the sequence was when the iterator was made.
        stop: usize,

        /// The next element, or null at the end of the walk. The returned
        /// pointer borrows the tree and is invalidated by exactly what this
        /// iterator is invalidated by; it is **not** invalidated by the next
        /// call to `next`, which only advances this iterator's own index.
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

/// A node of `width - 1` separators over `width` single-element leaves, the
/// subtree spelling `base, base + 1, ...` in sequence order, measured and
/// ready to be wired in as a child.
fn wiredNode(gpa: Allocator, base: u32, width: usize) !Node(u32) {
    var node = Node(u32).init(gpa);
    errdefer node.deinit();
    var next = base;
    for (0..width) |i| {
        {
            var leaf = Node(u32).init(gpa);
            errdefer leaf.deinit();
            try leaf.elements.append(gpa, next);
            leaf.length = 1;
            try node.children.append(gpa, leaf);
        }
        next += 1;
        if (i + 1 < width) {
            try node.elements.append(gpa, next);
            next += 1;
        }
    }
    node.length = node.measure();
    return node;
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
        // **Upstream compares the model against `t.iter().copied().collect()`
        // after every step** (`sequence_tree.rs:590`), and that walk is what
        // the assertion is for. A length is not the same assertion: an
        // iterator that stops early, or visits one element twice and misses
        // another, still has the right length. The elements are `void` here
        // and upstream's are `()`, so the count is the only thing the
        // comparison can say — but it must be said by walking.
        var walked: usize = 0;
        var it = tree.iter();
        while (it.next()) |_| walked += 1;
        try testing.expectEqual(model.items.len, walked);
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

// ── Failure-atomicity of a removal ───────────────────────────────────────────
//
// A removal rebalances, and it rebalances by allocating, because Rust's
// global allocator cannot be refused and this port's can. The sweep below
// pins the promise the module doc makes, and both halves of it are
// consumer-visible: an element lost to a half-applied merge shows up as a
// shorter sequence and a different answer from `get`, and a subtree orphaned
// by one shows up as a leak in the testing allocator.
//
// The removal is always from the middle of a tree several levels deep, so it
// descends to a leaf and comes back up through a borrow or a merge at every
// level — which is the only shape in which the reserve-then-descent order is
// observable at all. `expectMatches` after a *successful* removal is there to
// say the reordering did not change the answer; the same call after a
// *refused* one is there to say the refusal changed nothing at all.
fn removeUnderFailure(gpa: Allocator) !void {
    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    var model: std.ArrayList(u32) = .empty;
    defer model.deinit(gpa);

    for (0..96) |i| {
        try tree.push(@intCast(i));
        try model.append(gpa, @intCast(i));
    }
    try expectMatches(&tree, model.items);

    while (model.items.len > 0) {
        const index = model.items.len / 2;
        const removed = tree.remove(index) catch |e| switch (e) {
            error.OutOfMemory => {
                try expectMatches(&tree, model.items);
                return e;
            },
            else => |rest| return rest,
        };
        try testing.expectEqual(model.items[index], removed);
        _ = model.orderedRemove(index);
        try expectMatches(&tree, model.items);
    }
    try testing.expect(tree.isEmpty());
}

test "a removal refused for want of memory leaves the sequence whole" {
    try testing.checkAllAllocationFailures(testing.allocator, removeUnderFailure, .{});
}

test "a refused full-root split leaves a removable original root" {
    // Sweep the root's provisional buffers and split buffers in default mode.
    for (0..6) |skip| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var tree = SequenceTree(u32).init(failing.allocator());
        defer tree.deinit();
        var model: [2 * B - 1]u32 = undefined;
        for (&model, 0..) |*value, index| {
            value.* = @intCast(index);
            try tree.push(value.*);
        }
        failing.fail_index = failing.alloc_index + skip;
        failing.resize_fail_index = failing.resize_index;
        tree.push(9999) catch |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            try expectMatches(&tree, &model);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(@as(u32, 0), try tree.remove(0));
            try expectMatches(&tree, model[1..]);
            continue;
        };
        try tree.checkInvariants();
        try testing.expectEqual(model.len + 1, tree.len());
    }
}

test "reserved leaf nodes allocate no child storage" {
    // One leaf pays only for its bounded element buffer. Splitting it creates
    // child storage in the internal root, not in either resulting leaf.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var tree = SequenceTree(u32).initReserved(failing.allocator());
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try tree.push(0);
    try testing.expectEqual(@as(usize, 1), failing.alloc_index);
    try testing.expectEqual((2 * B - 1) * @sizeOf(u32), failing.allocated_bytes);
    try testing.expectEqual(@as(usize, 0), tree.root.?.children.capacity);
    for (1..2 * B) |i| try tree.push(@intCast(i));
    try testing.expectEqual(@as(usize, 2 * B), tree.root.?.children.capacity);
    for (tree.root.?.children.items) |child| {
        try testing.expect(child.isLeaf());
        try testing.expectEqual(@as(usize, 0), child.children.capacity);
    }
    try tree.checkInvariants();
}

test "reserved trees roll back inserted prefixes while allocation remains refused" {
    // Refuse each allocation around leaf and multi-level root splits, then
    // remove the published prefix without disarming the allocator.
    for ([_]usize{ 2 * B - 1, 1024 }) |count| {
        for (0..12) |skip| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var tree = SequenceTree(u32).initReserved(failing.allocator());
            defer tree.deinit();
            var model: [1024]u32 = undefined;
            for (0..count) |i| {
                model[i] = @intCast(i);
                try tree.push(model[i]);
            }
            failing.fail_index = failing.alloc_index + skip;
            failing.resize_fail_index = failing.resize_index;
            const at = count / 2;
            var inserted: usize = 0;
            while (inserted < 128) : (inserted += 1) {
                tree.insert(at + inserted, 9999) catch |failure| {
                    try testing.expectEqual(error.OutOfMemory, failure);
                    try tree.checkInvariants();
                    break;
                };
            }
            while (inserted > 0) : (inserted -= 1) {
                try testing.expectEqual(@as(u32, 9999), tree.remove(at) catch unreachable);
            }
            try expectMatches(&tree, model[0..count]);
            // Also prune every remaining node, including internal separators.
            failing.fail_index = failing.alloc_index;
            while (!tree.isEmpty()) {
                const index = tree.len() / 2;
                _ = tree.remove(index) catch unreachable;
                try tree.checkInvariants();
            }
        }
    }
}

test "leaf pair removals preserve the separator only when it survives" {
    const gpa = testing.allocator;
    for ([_]usize{ 2 * B, 3 * B }) |count| {
        for ([_]usize{ 0, B - 1, B }) |at| {
            var tree = SequenceTree(u32).init(gpa);
            defer tree.deinit();
            var model: std.ArrayList(u32) = .empty;
            defer model.deinit(gpa);

            // Append-built leaves hold B - 1 elements except the last one.
            // Shorten that leaf so all siblings need a merge, then remove
            // before, at, or after the first separator. With two leaves the
            // root collapses; with three it remains above the merged pair.
            for (0..count) |value| {
                try tree.push(@intCast(value));
                try model.append(gpa, @intCast(value));
                try expectMatches(&tree, model.items);
            }
            try testing.expectEqual(model.items[count - 1], try tree.remove(count - 1));
            _ = model.orderedRemove(count - 1);
            try expectMatches(&tree, model.items);

            try testing.expectEqual(model.items[at], try tree.remove(at));
            _ = model.orderedRemove(at);
            try expectMatches(&tree, model.items);
        }
    }
}

test "a separator between two internal children" {
    const gpa = testing.allocator;

    // A node is never left with a child under `B` once a removal has
    // rebalanced it, so two *adjacent* children that are both internal and
    // both underfull — the one shape where a merged pair cannot close up
    // around the gap, since the merged node's children would then outnumber
    // its elements by two (`checkShape`) — only turns up in a subtree of some
    // hundreds of elements after a long pruning history. The shape is wired
    // up here instead and the removal itself is the public one, through
    // `removeElementFromNonLeaf`'s merge branch.
    //
    // Every element is distinct, so a removal that kept the separator, took
    // its value out of the wrong subtree, or shifted the rest along is an
    // answer the walk cannot mistake for the right one. The widths pair a
    // left child wide enough to rebalance internally with one so narrow it
    // cannot, and both are under `B`, which is the pair the rule is about.
    for ([_][2]usize{ .{ 2, 4 }, .{ 3, 3 }, .{ 4, 2 }, .{ 5, 6 } }) |widths| {
        var tree = SequenceTree(u32).init(gpa);
        defer tree.deinit();

        var root = Node(u32).init(gpa);
        var adopted = false;
        errdefer if (!adopted) root.deinit();
        var next: u32 = 0;
        for (widths, 0..) |width, child_index| {
            var child = try wiredNode(gpa, next, width);
            root.children.append(gpa, child) catch |e| {
                // Not adopted yet, so it is still this scope's to free.
                child.deinit();
                return e;
            };
            next += @intCast(2 * width - 1);
            if (child_index == 0) {
                try root.elements.append(gpa, next);
                next += 1;
            }
        }
        root.length = root.measure();
        adopted = true;
        tree.root = root;

        var model: std.ArrayList(u32) = .empty;
        defer model.deinit(gpa);
        for (0..next) |value| try model.append(gpa, @intCast(value));
        try expectMatches(&tree, model.items);

        // The separator is the one value the two children step over: the
        // whole tree spells `0..<next`, so every other element is somewhere
        // around it and has to be exactly where it was afterwards.
        const at = 2 * widths[0] - 1;
        try testing.expectEqual(model.items[at], try tree.remove(at));
        _ = model.orderedRemove(at);
        try expectMatches(&tree, model.items);
    }
}

// ── The fan-out bound, which is the whole of the O(log n) ────────────────────
//
// Every descent in this file costs a linear scan of one node's children:
// `findChildIndex` (`:128-138`), `cumulativeIndex` (`:142-146`), `get`
// (`:514-532`), `getMut` (`:534-552`) and the child loop in `remove`
// (`:496-510`). So an insert or a remove costs *fan-out times depth*, and only
// the fan-out rule makes that logarithmic. A node splits at `2 * B - 1`
// elements (`isFull`, `:111-113`) and lifts its middle element into the parent
// (`splitChild`, `:176-217`), so **nothing in the tree ever holds more than
// `2 * B` children** — 32, and 31 elements.
//
// **Nothing asserted that until now.** `checkShape` (`:559-569`) checks the
// occupancy rule and the arity rule, so a violation would surface — but only
// on a tree small enough for the bug to be plausible. The largest tree any
// test above builds is 256 elements (`:929`), which is two levels deep, and
// this module's two holders are `hydrate::List` (`hydrate.zig:1271`) and
// `patches::InsertValues` (`patches.zig:746`), neither of which sizes its
// lists by anything to do with the tree's depth. The bound is what the
// insertion cost is being claimed to rest on, and it is claimed for their
// trees.

/// What a walk of every node measured.
const Shape = struct {
    /// How many nodes the tree holds.
    nodes: usize = 0,
    /// How many levels lie between the root and the deepest leaf, the root
    /// counting as one.
    levels: usize = 0,
    /// The widest node's child count — the fan-out, which is the number the
    /// cost argument is about.
    widest: usize = 0,
    /// The narrowest internal node **below the root**. Two is the floor: an
    /// internal node holds at least one element and `checkShape`'s arity rule
    /// gives it one more child than elements.
    narrowest_internal: usize = 0,
};

/// Walk every node, asserting the fan-out rule node by node rather than
/// stating it once, and recording what it found.
fn measureShape(comptime T: type, node: *const Node(T), level: usize, out: *Shape) !void {
    out.nodes += 1;
    out.levels = @max(out.levels, level);
    out.widest = @max(out.widest, node.children.items.len);
    // **The bound, as a value at every node.** A child count above `2 * B` is
    // the regression this section exists to catch, and it is checked where it
    // lives rather than inferred from the tree's depth afterwards.
    try testing.expect(node.elements.items.len <= 2 * B - 1);
    try testing.expect(node.children.items.len <= 2 * B);
    // Arity: a leaf has no children, an internal node has exactly one more
    // child than elements. `2 * B` children follows from `2 * B - 1` elements
    // through this rule, which is why both are asserted.
    try testing.expect(node.children.items.len == 0 or
        node.children.items.len == node.elements.items.len + 1);
    // The root is excluded: a delete may leave it with anything from one
    // element to a full node, and it is a node below the root whose occupancy
    // the depth bound leans on.
    if (level > 1 and node.children.items.len != 0) {
        out.narrowest_internal = if (out.narrowest_internal == 0)
            node.children.items.len
        else
            @min(out.narrowest_internal, node.children.items.len);
    }
    for (node.children.items) |*child| try measureShape(T, child, level + 1, out);
}

/// The deepest a tree of `n` elements may be under the fan-out rule, the root
/// counting as one level.
///
/// **It walks `B` upward, which is one level looser than the tightest bound
/// the rules support, and the slack is deliberate.** The tight form is
/// `1 + floor(log_B(n / (2 * B)))`, which needs the module doc's claim at
/// `:19-22` — "a node that ends a delete may hold `B - 1` elements" — to be a
/// floor rather than an observation. This form uses neither that floor nor the
/// root's fan-out, so it survives a rebalance that leaves a node one element
/// lighter than the doc says. It is still three orders of magnitude below the
/// depth a tree with no fan-out rule reaches: `n` levels for a chain, against
/// this bound's `log_B(n) + 2`.
fn maxLevels(n: usize) usize {
    var span = B;
    var levels: usize = 2;
    while (span < n) : (levels += 1) span *= B;
    return levels;
}

test "the fan-out bound is what keeps a descent logarithmic" {
    const gpa = testing.allocator;
    const n = 20_000;

    var tree = SequenceTree(u32).init(gpa);
    defer tree.deinit();

    // ── Built by appending ────────────────────────────────────────────────
    for (0..n) |i| try tree.push(@intCast(i));

    var shape: Shape = .{};
    try measureShape(u32, &tree.root.?, 1, &shape);
    try tree.checkInvariants();

    try testing.expectEqual(n, tree.len());
    try testing.expect(shape.nodes > 1);
    // The fan-out: the claim this whole section is about.
    try testing.expect(shape.widest <= 2 * B);
    try testing.expect(shape.narrowest_internal >= 2);
    // And the depth that follows from it.
    try testing.expect(shape.levels <= maxLevels(n));
    // The two ends and the middle, so a walk that had found nothing at all
    // cannot be what satisfied the shape assertions above.
    try testing.expectEqual(@as(u32, 0), tree.get(0).?.*);
    try testing.expectEqual(@as(u32, @intCast(n / 2)), tree.get(n / 2).?.*);
    try testing.expectEqual(@as(u32, @intCast(n - 1)), tree.get(n - 1).?.*);

    // ── Pruned ────────────────────────────────────────────────────────────
    //
    // **A removal is where the fan-out could widen, and it is the one place the
    // split rule does not answer.** A merge adds the right neighbour's
    // children to the left one (`:254-264`), and `mergeAssumeCapacity`
    // (`:254-259`) asserts only `elements.len <= 2 * B - 1` — the element
    // rule, from which the child rule follows by arity. So the bound has to be
    // checked on a pruned tree and not only on a fresh one, or a merge could
    // widen a node and nothing here would say so.
    //
    // Every third index is removed, which interleaves the removes with
    // rebalances at every level instead of running down one side of the tree,
    // and `at` advances while the tree is shrinking so the walk stops on the
    // length rather than on a fixed count.
    var at: usize = 0;
    while (at < tree.len()) : (at += 3) _ = try tree.remove(at);

    var pruned: Shape = .{};
    try measureShape(u32, &tree.root.?, 1, &pruned);
    try tree.checkInvariants();

    try testing.expect(pruned.widest <= 2 * B);
    try testing.expect(pruned.narrowest_internal >= 2);
    try testing.expect(pruned.levels <= maxLevels(tree.len()));
    // Four survives for every three removed, and index zero is one of the
    // removed ones — so the first element is 1 and the last is untouched.
    try testing.expectEqual(n - n / 4, tree.len());
    var it = tree.iter();
    try testing.expectEqual(@as(u32, 1), it.next().?.*);
    try testing.expectEqual(@as(u32, @intCast(n - 1)), tree.get(tree.len() - 1).?.*);
    var walked: usize = 1;
    while (it.next()) |_| walked += 1;
    try testing.expectEqual(tree.len(), walked);
}

// ── Diff against the reference, for the test assertions and the invariant walk
// ────────────────────────────────────────────────────────────────────────────
//
// | Zig 0.16.0 | upstream | Rust | port | does not / is / this |
// | --- | --- | --- | --- | --- |
// | `test "insert_book_vec"` walks the iterator every step | `sequence_tree.rs:582-592` | `assert_eq!(v, t.iter().copied().collect::<Vec<_>>())` inside `for i in 0..100` | `var walked: usize = 0; var it = tree.iter(); while (it.next()) \|_\| walked += 1; try testing.expectEqual(model.items.len, walked);` | **is** upstream's assertion rather than a length check standing in for it: an iterator that stops early, or visits one element twice and misses another, **still** has the right `len()`, which **is** `root.length` |
// | `checkInvariants()` ends at `try root.checkShape()` | `fn check`, `sequence_tree.rs:363-368` | re-derives every node's `length` by summing its children's lengths | the same recursive re-derivation, plus the occupancy and arity rules every split and merge in this file relies on | **does not** repeat the root's length against `len()` — that branch **was** here and could never fire, because `len()` **is** `root.length` |
// | `SequenceTree.eql(a, b)` | `impl PartialEq`, `sequence_tree.rs:471-478` | `self.len() == other.len() && self.iter().zip(other.iter()).all(\|(a, b)\| a == b)` | the same length-then-lockstep comparison over `iter()`, with `std.meta.eql` for the element | **is** upstream's, and **does not** compare the shape: a delete leaves different shapes behind for the same sequence, and upstream's `hydrate::List` derives `PartialEq` from it |
