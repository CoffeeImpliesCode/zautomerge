//! The queue of changes that are not yet ready to be applied
//! (`rust/automerge/src/change_queue.rs`).
//!
//! A peer hands over a set of changes in whatever order the transport
//! produced them. A change cannot be applied before the changes it depends on,
//! so a change whose dependencies have not arrived waits, and the topological
//! sort is the code that turns the waiting set back into an ordered batch
//! (`pop_topo_sorted_ready`, `change_queue.rs:127-176`). Getting that order
//! wrong does not lose data, it produces a corrupt document, which is why the
//! sort is the whole point of this module and the queue itself is bookkeeping.
//!
//! Three structures ride along with the changes:
//!
//! * **the changes**, in the order they arrived minus the ones already
//!   applied (`changes`, `change_queue.rs:47`). Upstream is a `Vec` and this is
//!   an `ArrayList`; the sort removes an arbitrary subset, which upstream does
//!   with `retain` over a `Vec<Option<Change>>` and this port does with one
//!   in-place compaction pass (`change_queue.rs:166-174`).
//! * **the hash index** (`index_by_hash`, `change_queue.rs:48-49`), so a change
//!   that is already waiting is recognised without a linear scan, and so the
//!   sort can answer "is this dependency queued" in constant time. Upstream
//!   stores a `HashSet<ChangeHash>` and rebuilds a `hash -> change` map on
//!   every `missing_deps_from` call (`automerge.rs:2038-2041`); storing the
//!   queue position as the value is the same map, paid for once.
//! * **the actor and sequence number set** (`incoming_actor_seqs`,
//!   `change_queue.rs:50`), so a change that repeats a sequence number for an
//!   actor is refused instead of overwriting that actor's history. Per-actor
//!   sequence numbers are the document's per-actor chain
//!   (`ChangeGraph.addChange`, `change_graph.zig`), so a repeat is a conflict,
//!   not a duplicate to be ignored.
//!
//! ## What the sort does with a change it cannot order
//!
//! Kahn's algorithm runs over the queued changes with the edges that point at
//! a dependency the *document does not have yet* (`change_queue.rs:132-141`).
//! A change whose every dependency is applied, or already emitted, is ready.
//! Two outcomes are not "ready", and they are different failures:
//!
//! * **waiting on an absent change** — a dependency is in neither the graph
//!   nor the queue. Nothing about the queue is wrong; the change simply cannot
//!   be applied yet. It stays queued and the batch names it in `blocked`, so
//!   the caller can advertise it as a missing dependency
//!   (`missingDepsFrom`, `automerge.rs:2037-2062`).
//! * **a cycle** — every dependency of the unorderable changes is in the graph
//!   or in the queue, and they still cannot be ordered. The format cannot
//!   produce this: a change hash covers the change's dependency hashes
//!   (`chunk.changeHashOf`, `change.zig`), so a cycle is a hash preimage. The
//!   sort refuses with `error.ChangeGraph` rather than looping, and leaves the
//!   queue exactly as it found it.
//!
//! Upstream's `pop_topo_sorted_ready` cannot distinguish the two — it returns
//! the ready changes and quietly leaves the rest queued, and neither does the
//! caller look. A port that loops on the second case, or that applies the
//! first, is a document corruption bug, so the distinction is made here.
//!
//! ## Ownership
//!
//! A queue owns every change pushed into it and a batch owns every change it
//! carries: `deinit`, `clear`, `removeActorBranchFrom` and the sort all free
//! the changes they drop, which is what Rust's `Drop for Change` does. The one
//! allocation a change owns is the `other_actors` array `parseChange` makes
//! (`change.zig`), so a change whose actor array belongs to somebody else must
//! not be pushed.
//!
//! The other direction is the same fact read from a caller's side:
//! [`ChangeBatch.at`](ChangeBatch.at), [`ChangeQueue.get`](ChangeQueue.get)
//! and both `slice` methods hand out **aliases** of a container-owned change,
//! not fresh owners. `Change` is one struct with one allocation behind it, so
//! a by-value return reads like a transfer at the call site and is not one —
//! each of those declarations says so, and freeing what one of them returns
//! is a double free against the container's own `deinit`. `push` is the
//! mirror image and says the opposite, because it is the one method that
//! really does take ownership.
//!
//! As everywhere else in this port, the allocator is a parameter and never the
//! page allocator. The queue keeps the one it was built with, for the `deinit`
//! that frees its own memory; every allocating method takes it as an argument
//! as well, so a caller cannot free with a different one by accident.

const std = @import("std");
const error_types = @import("error.zig");
const types = @import("types.zig");
const change_mod = @import("change.zig");
const graph_mod = @import("change_graph.zig");
const author_mod = @import("author.zig");

const Error = error_types.Error;
const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ChangeHash = types.ChangeHash;
const Change = change_mod.Change;
const ChangeGraph = graph_mod.ChangeGraph;
const ChangeMetadata = change_mod.ChangeMetadata;
const Authors = author_mod.Authors;

/// A change hash keyed map. The key is 32 bytes, so it is hashed and compared
/// as bytes rather than through `std.hash.autoHash`, which would walk the
/// struct field by field.
const HashContext = struct {
    pub fn hash(_: @This(), key: ChangeHash) u64 {
        return std.hash.Wyhash.hash(0, &key.bytes);
    }

    pub fn eql(_: @This(), a: ChangeHash, b: ChangeHash) bool {
        return a.eql(b);
    }
};

/// The `hash -> queue position` index (`hashes`, `change_queue.rs:48-49`).
/// The value is the position, so a hash answers both "is it queued" and "which
/// change is it" in one lookup.
const IndexByHash = std.HashMapUnmanaged(ChangeHash, usize, HashContext, 80);

/// An actor paired with the sequence number of one of its changes: the key of
/// the per-actor duplicate check (`incoming_actor_seqs`, `change_queue.rs:50`).
///
/// The actor bytes are borrowed from the change that put the key in the set,
/// and the queue owns that change, so the bytes live at least as long as the
/// key. They are dropped together: the key is removed with the change.
const ActorSeq = struct {
    /// The author of the change.
    actor: ActorId,
    /// Its sequence number: 1 for the actor's first change.
    seq: u64,

    pub fn eql(a: ActorSeq, b: ActorSeq) bool {
        return a.seq == b.seq and a.actor.eql(b.actor);
    }
};

/// Hashes an `(actor, seq)` pair. The actor bytes are hashed as they are
/// rather than through `std.hash.autoHash`, which would walk the `ActorId`
/// slice field by field.
const ActorSeqContext = struct {
    pub fn hash(_: @This(), key: ActorSeq) u64 {
        var hasher = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        hasher.update(std.mem.asBytes(&key.seq));
        hasher.update(key.actor.bytes);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: ActorSeq, b: ActorSeq) bool {
        return a.eql(b);
    }
};

/// The `(actor, seq)` set of every queued change.
const ActorSeqSet = std.HashMapUnmanaged(ActorSeq, void, ActorSeqContext, 80);

/// One entry of the "changes waiting for this dependency" lists: the queue
/// position of the waiting change, and the next entry waiting for the same
/// dependency. A singly linked list hanging off the map, so registering a
/// dependent costs one array append rather than a second map
/// (`waiting_on`, `change_queue.rs:133-141`).
const Waiter = struct {
    /// The queue position of the change that is waiting.
    change: usize,
    /// The next entry waiting for the same dependency, or null at the end.
    next: ?usize,
};

/// The ends of one dependency's list of waiters.
const WaiterList = struct {
    /// The first entry, or null when nothing is waiting on it.
    head: ?usize = null,
    /// The last entry, so that a registration is an append and the waiters are
    /// released in the order they were registered, as upstream's `Vec` is.
    tail: ?usize = null,
};

/// A dependency hash to the list of changes waiting for it.
const WaiterHeads = std.HashMapUnmanaged(ChangeHash, WaiterList, HashContext, 80);

/// A queued change the sort could not order, and the dependency it waits for.
pub const BlockedChange = struct {
    /// The queued change that is not ready to be applied.
    change: ChangeHash,
    /// A dependency of `change` that the document does not have and the queue
    /// does not hold. This is its *first* such dependency, which is the one
    /// `ChangeGraph.firstMissingDep` names when it refuses a change
    /// (`change_graph.rs:1053-1055`).
    dep: ChangeHash,
};

/// A set of changes in dependency order, ready to apply
/// (`ChangeBatch`, `change_queue.rs:5-40`).
///
/// The batch owns its changes: `deinit` frees every one of them, exactly as
/// upstream's `Vec<Change>` frees its elements. What upstream's `ChangeBatch`
/// holds is the *incoming* batch, deduplicated by hash and by actor sequence
/// number before it is handed to the queue; this port keeps those two rules in
/// `ChangeQueue.push` and this type is what the sort produces, which is what
/// the apply step consumes (`BatchApply::new`, `batch.rs:1104-1105`).
pub const ChangeBatch = struct {
    /// The allocator this batch allocates from. Every `gpa` passed to a method
    /// must be it, because `deinit` frees with it.
    gpa: Allocator,
    /// The changes, in dependency order: a change appears after every one of
    /// its dependencies, and a dependency that is not queued is applied by the
    /// document, not by this batch.
    changes: std.ArrayList(Change),
    /// The queued changes this batch does not carry, with the absent
    /// dependency each is waiting for. Empty when every queued change was
    /// ordered; a non-empty list is not an error, it is a peer that has more
    /// to send.
    blocked: std.ArrayList(BlockedChange),
    /// The number of ops in `changes` altogether: the sum over the batch of
    /// `max_op - start_op + 1`, saturating. A change whose op columns have not
    /// been decoded counts zero, because `parseChange` leaves `max_op` at zero
    /// until `Change.withOpCount` fills it in (`change.zig`).
    op_count: u64,

    /// An empty batch that owns nothing.
    pub fn init(gpa: Allocator) ChangeBatch {
        return .{
            .gpa = gpa,
            .changes = .empty,
            .blocked = .empty,
            .op_count = 0,
        };
    }

    /// Frees every change the batch owns, then the two lists.
    pub fn deinit(self: *ChangeBatch) void {
        for (self.changes.items) |*change| change.deinit(self.gpa);
        self.changes.deinit(self.gpa);
        self.blocked.deinit(self.gpa);
        self.* = undefined;
    }

    /// The number of changes in the batch.
    pub fn len(self: *const ChangeBatch) usize {
        return self.changes.items.len;
    }

    /// True when the batch carries no change.
    pub fn isEmpty(self: *const ChangeBatch) bool {
        return self.changes.items.len == 0;
    }

    /// The change at `index`, in dependency order.
    ///
    /// **The returned `Change` is an alias of the one the batch owns, not a
    /// copy and not a new owner.** It borrows the batch's `other_actors`
    /// allocation and its `bytes`, and [`deinit`](ChangeBatch.deinit) frees
    /// both when the batch is released, so the copy must not be deinited:
    /// doing so frees the actor array the batch still holds and the batch's
    /// own `deinit` frees it again. A caller that wants to keep the change
    /// past the batch copies it — `ChangeMetadata.intoOwned` for the fields
    /// the graph keeps, or a `parseChange` of its own bytes for the rest.
    ///
    /// Out of bounds is a panic, as it is for every index into a
    /// `std.ArrayList`; `len` is the bound.
    pub fn at(self: *const ChangeBatch, index: usize) Change {
        return self.changes.items[index];
    }

    /// The changes, in dependency order.
    ///
    /// **Every element aliases the batch's storage**, by the same rule
    /// [`at`](ChangeBatch.at) states: valid until the batch is deinited or
    /// mutated, and nothing reached through the slice may be deinited. The
    /// slice is a borrow for exactly the reason `at` returns by value — it
    /// cannot reach `Change.deinit` at all.
    pub fn slice(self: *const ChangeBatch) []const Change {
        return self.changes.items;
    }

    /// The total number of ops in the batch, saturating at `u64` max.
    pub fn opCount(self: *const ChangeBatch) u64 {
        return self.op_count;
    }
};

/// The number of ops a change holds: `max_op - start_op + 1`, or zero when the
/// change is empty, whose `max_op` is `start_op - 1` (`change.zig`), or when
/// its op columns have not been decoded, which leaves `max_op` at zero.
fn opCountOf(change: Change) u64 {
    if (change.start_op == 0) return 0;
    if (change.max_op < change.start_op) return 0;
    return change.max_op - change.start_op + 1;
}

/// The queue of changes that are waiting for their dependencies
/// (`ChangeQueue`, `change_queue.rs:42-51`).
pub const ChangeQueue = struct {
    /// The allocator this queue allocates from. Every `gpa` passed to a method
    /// must be it, because `deinit` and `clear` free with it.
    gpa: Allocator,
    /// The changes still waiting, in the order they arrived. Removing a change
    /// keeps the order of the rest, so a queue that is mostly blocked stays in
    /// arrival order rather than being reshuffled on every apply.
    changes: std.ArrayList(Change),
    /// Every queued change's hash, to its position in `changes`.
    index_by_hash: IndexByHash,
    /// Every queued change's actor and sequence number, the duplicate check.
    incoming_actor_seqs: ActorSeqSet,

    /// An empty queue.
    pub fn init(gpa: Allocator) ChangeQueue {
        return .{
            .gpa = gpa,
            .changes = .empty,
            .index_by_hash = .empty,
            .incoming_actor_seqs = .empty,
        };
    }

    /// Frees every queued change and the two indexes. The queue is unusable
    /// afterwards.
    pub fn deinit(self: *ChangeQueue) void {
        self.clear();
        self.changes.deinit(self.gpa);
        self.index_by_hash.deinit(self.gpa);
        self.incoming_actor_seqs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Frees every queued change and empties the queue, keeping its capacity.
    pub fn clear(self: *ChangeQueue) void {
        for (self.changes.items) |*change| change.deinit(self.gpa);
        self.changes.clearRetainingCapacity();
        self.index_by_hash.clearRetainingCapacity();
        self.incoming_actor_seqs.clearRetainingCapacity();
    }

    /// The number of changes waiting.
    pub fn len(self: *const ChangeQueue) usize {
        return self.changes.items.len;
    }

    /// True when no change is waiting.
    pub fn isEmpty(self: *const ChangeQueue) bool {
        return self.changes.items.len == 0;
    }

    /// The waiting changes, in arrival order (`iter`, `change_queue.rs:64`).
    ///
    /// **Two invalidations, not one.** A push or a removal renumbers or
    /// extends the list, and the sort compacts it in place and shrinks it, so
    /// the slice is valid only until the next call to
    /// [`push`](ChangeQueue.push),
    /// [`removeActorBranchFrom`](ChangeQueue.removeActorBranchFrom) or
    /// [`popTopoSortedReady`](ChangeQueue.popTopoSortedReady) — the three that
    /// move elements. Nothing reached through the slice may be deinited; the
    /// queue owns every change and frees it in
    /// [`clear`](ChangeQueue.clear) or [`deinit`](ChangeQueue.deinit).
    pub fn slice(self: *const ChangeQueue) []const Change {
        return self.changes.items;
    }

    /// The queued change with this hash, or null.
    ///
    /// **The returned `Change` is an alias of the one the queue owns**, by the
    /// same rule [`ChangeBatch.at`](ChangeBatch.at) states: it borrows the
    /// queue's `other_actors` allocation, so it must not be deinited, and it
    /// is only good until the next call that moves a change. A caller that
    /// needs to keep one — to hand it to a queue that will own it — has to
    /// parse it again or copy its metadata rather than take this value and
    /// free it, which would corrupt a queue that is about to be sorted.
    pub fn get(self: *const ChangeQueue, hash: ChangeHash) ?Change {
        const at = self.index_by_hash.get(hash) orelse return null;
        return self.changes.items[at];
    }

    /// True when a change with this hash is waiting.
    pub fn contains(self: *const ChangeQueue, hash: ChangeHash) bool {
        return self.index_by_hash.contains(hash);
    }

    /// True when a change from this actor at this sequence number is waiting.
    /// The batch apply path asks this before it queues anything
    /// (`batch.rs:1078-1083`).
    pub fn containsActorSeq(self: *const ChangeQueue, actor: ActorId, seq: u64) bool {
        return self.incoming_actor_seqs.contains(.{ .actor = actor, .seq = seq });
    }

    /// Takes a change into the queue.
    ///
    /// A change the queue already holds is dropped and this succeeds, which is
    /// what a peer re-announcing a change looks like
    /// (`ChangeBatch::push`, `change_queue.rs:26-28`). A change that repeats a
    /// sequence number for an actor is refused with
    /// `error.DuplicateSeqNumber` (`change_queue.rs:30-34`): two different
    /// changes cannot own one slot of an actor's history.
    ///
    /// The queue takes ownership of `change` on every path, including both
    /// returns, as upstream's `push` does by taking it by value. Whether the
    /// document already holds the change is not this method's business: that
    /// is the graph's answer, and upstream's caller asks the graph first
    /// (`batch.rs:1069-1071`).
    pub fn push(self: *ChangeQueue, gpa: Allocator, change: Change) Error!void {
        // The queue owns what it is given, so the change is freed here the
        // moment it is refused, and by the queue once it is stored. `deinit`
        // takes a pointer and a parameter is constant, so the value gets a
        // name of its own to free through.
        var owned = change;
        if (self.index_by_hash.contains(owned.hash)) {
            owned.deinit(gpa);
            return;
        }
        if (self.incoming_actor_seqs.contains(.{ .actor = owned.actor, .seq = owned.seq })) {
            owned.deinit(gpa);
            return error.DuplicateSeqNumber;
        }
        const at = self.changes.items.len;
        errdefer owned.deinit(gpa);
        try self.changes.append(gpa, owned);
        errdefer _ = self.changes.pop();
        try self.index_by_hash.put(gpa, owned.hash, at);
        errdefer _ = self.index_by_hash.remove(owned.hash);
        try self.incoming_actor_seqs.put(gpa, .{ .actor = owned.actor, .seq = owned.seq }, {});
    }

    /// Drops every change from this actor at or after `seq`, and everything
    /// that depends on any of them, transitively
    /// (`remove_actor_branch_from`, `change_queue.rs:68-105`).
    ///
    /// This is what a document does when a peer offers a different change for a
    /// sequence number this document has already issued: the branch that
    /// conflicts is not merely refused, the queued part of it is thrown away
    /// so the new change can be applied in its place (`batch.rs:1073-1077`,
    /// `automerge.rs:564`).
    ///
    /// Rust's global allocator cannot fail; this port's can, so this returns
    /// `error.OutOfMemory` rather than dropping changes on the floor.
    pub fn removeActorBranchFrom(
        self: *ChangeQueue,
        gpa: Allocator,
        actor: ActorId,
        seq: u64,
    ) Error!void {
        var removed: IndexByHash = .empty;
        defer removed.deinit(gpa);
        // Dependency hash to the changes waiting for it, so the removal can
        // walk forwards through the dependents.
        var dependents: std.HashMapUnmanaged(ChangeHash, std.ArrayList(ChangeHash), HashContext, 80) = .empty;
        defer {
            var lists = dependents.valueIterator();
            while (lists.next()) |list| list.deinit(gpa);
            dependents.deinit(gpa);
        }

        // The work list starts as the branch itself and grows with everything
        // that transitively depends on it. A cursor instead of a ring buffer:
        // the list only grows, and the cursor never wraps.
        var work: std.ArrayList(ChangeHash) = .empty;
        defer work.deinit(gpa);

        // The queue holds nothing from that actor at or after that sequence
        // number, so there is no branch to remove and nothing to walk.
        var conflicts: usize = 0;
        for (self.changes.items) |change| {
            if (change.actor.eql(actor) and change.seq >= seq) conflicts += 1;
        }
        if (conflicts == 0) return;

        // The work list is at least this big, and usually exactly this big: the
        // walk only adds the changes that depend on the branch.
        try work.ensureTotalCapacity(gpa, conflicts);

        for (self.changes.items) |change| {
            if (change.actor.eql(actor) and change.seq >= seq) {
                try removed.put(gpa, change.hash, 0);
                try work.append(gpa, change.hash);
            }
            for (change.deps) |dep| {
                const entry = try dependents.getOrPut(gpa, dep);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, change.hash);
            }
        }

        var head: usize = 0;
        while (head < work.items.len) : (head += 1) {
            var found = dependents.fetchRemove(work.items[head]) orelse continue;
            for (found.value.items) |child| {
                const entry = try removed.getOrPut(gpa, child);
                if (!entry.found_existing) try work.append(gpa, child);
            }
            found.value.deinit(gpa);
        }

        // Everything that allocates happens before anything is dropped, so a
        // failure here leaves the queue exactly as it was.
        var kept: std.ArrayList(Change) = .empty;
        errdefer kept.deinit(gpa);
        try kept.ensureTotalCapacity(gpa, self.changes.items.len);
        var kept_count: usize = 0;
        for (self.changes.items) |change| {
            if (removed.contains(change.hash)) continue;
            // The survivors move down as the dropped ones come out, so the
            // hash index is rewritten here rather than after the move.
            self.index_by_hash.put(gpa, change.hash, kept_count) catch return error.OutOfMemory;
            kept_count += 1;
        }

        for (self.changes.items) |*change| {
            if (removed.contains(change.hash)) {
                change.deinit(gpa);
                _ = self.index_by_hash.remove(change.hash);
                _ = self.incoming_actor_seqs.remove(.{ .actor = change.actor, .seq = change.seq });
            } else {
                kept.appendAssumeCapacity(change.*);
            }
        }
        self.changes.deinit(gpa);
        self.changes = kept;
    }

    /// Removes and returns every queued change whose dependencies the document
    /// already has, in dependency order
    /// (`pop_topo_sorted_ready`, `change_queue.rs:121-176`).
    ///
    /// This is Kahn's algorithm over the waiting changes. Each change counts the
    /// dependencies the graph does not have; the changes that count zero are
    /// ready, and emitting one decrements the count of every change waiting for
    /// it, which is what makes the output a topological order. A change whose
    /// dependency is nowhere to be found is not ready and never becomes ready,
    /// and a change that is waiting on nothing but other queued changes that
    /// are themselves waiting cannot be emitted either: the first is reported
    /// in `ChangeBatch.blocked`, the second is a cycle and is refused with
    /// `error.ChangeGraph`.
    ///
    /// Everything the sort removes leaves the queue; everything else stays, in
    /// arrival order, with the indexes still describing it. On error the queue
    /// is untouched, because the sort allocates everything it needs before it
    /// moves anything.
    ///
    /// The cost is one pass over the changes and their dependencies plus one
    /// pass over the emitted ones: linear in the size of the queue, which is
    /// what a peer that floods a document with a long history depends on. It is
    /// not a sort by comparison — a change list is compared against nothing.
    pub fn popTopoSortedReady(
        self: *ChangeQueue,
        gpa: Allocator,
        graph: *const ChangeGraph,
    ) Error!ChangeBatch {
        var batch: ChangeBatch = ChangeBatch.init(gpa);
        errdefer batch.deinit();

        const n = self.changes.items.len;
        if (n == 0) return batch;

        // Per change, how many of its dependencies the graph does not have.
        var unsatisfied = try gpa.alloc(u32, n);
        defer gpa.free(unsatisfied);
        // The same array is the ready list and the emitted order: `ready[0..head]`
        // is what was emitted, in order, and `ready[head..tail]` is what is
        // still to come. One allocation instead of two.
        var ready = try gpa.alloc(usize, n);
        defer gpa.free(ready);
        var waiters: std.ArrayList(Waiter) = .empty;
        defer waiters.deinit(gpa);
        var waiting_on: WaiterHeads = .empty;
        defer waiting_on.deinit(gpa);
        var taken: []bool = try gpa.alloc(bool, n);
        defer gpa.free(taken);
        @memset(taken, false);

        var head: usize = 0;
        var tail: usize = 0;

        for (self.changes.items, 0..) |change, at| {
            var count: u32 = 0;
            var absent: ?ChangeHash = null;
            for (change.deps) |dep| {
                // The document has it: the constraint is already met
                // (`change_queue.rs:134`).
                if (graph.hasChange(dep)) continue;
                count += 1;
                if (self.index_by_hash.contains(dep)) {
                    // The queue holds it, so this change becomes ready when
                    // that one is emitted. Appending at the tail is what makes
                    // the waiters come out in the order they went in, the way
                    // upstream's `Vec` does.
                    const entry = try waiting_on.getOrPut(gpa, dep);
                    if (!entry.found_existing) entry.value_ptr.* = .{};
                    const at_entry = waiters.items.len;
                    if (entry.value_ptr.tail) |last| {
                        waiters.items[last].next = at_entry;
                    } else {
                        entry.value_ptr.head = at_entry;
                    }
                    entry.value_ptr.tail = at_entry;
                    try waiters.append(gpa, .{ .change = at, .next = null });
                } else if (absent == null) {
                    // Nobody has it. This change is not ready now and will not
                    // be ready until it arrives.
                    absent = dep;
                }
            }
            unsatisfied[at] = count;
            if (absent) |dep| {
                try batch.blocked.append(gpa, .{ .change = change.hash, .dep = dep });
            } else if (count == 0) {
                ready[tail] = at;
                tail += 1;
            }
        }

        // Every change with a dependency the graph lacks is waiting for it;
        // emitting a change releases the ones waiting for it. The waiter lists
        // are read, not taken, because the pass below walks them again.
        while (head < tail) {
            const at = ready[head];
            head += 1;
            taken[at] = true;
            const list = waiting_on.get(self.changes.items[at].hash) orelse continue;
            var next: ?usize = list.head;
            while (next) |entry_at| {
                const waiter = waiters.items[entry_at];
                // Every decrement answers an increment from the pass above, so
                // this cannot fall below zero.
                unsatisfied[waiter.change] -= 1;
                if (unsatisfied[waiter.change] == 0) {
                    ready[tail] = waiter.change;
                    tail += 1;
                }
                next = waiter.next;
            }
        }

        // A change the sort could not order is either waiting on a change
        // nobody has — which `blocked` names — or waiting on a change that is
        // itself waiting. Mark everything transitively downstream of an absent
        // dependency, and whatever is left unmarked is in, or behind, a cycle.
        // A dependency cycle cannot come out of the format, because a change
        // hash covers its dependency hashes, so this is a document that cannot
        // be built, and the caller is told instead of being spun.
        var downstream: std.ArrayList(usize) = .empty;
        defer downstream.deinit(gpa);
        var waiting: []bool = try gpa.alloc(bool, n);
        defer gpa.free(waiting);
        @memset(waiting, false);
        for (batch.blocked.items) |blocked| {
            // A blocked change is always still queued: it was never emitted.
            const at = self.index_by_hash.get(blocked.change) orelse continue;
            if (waiting[at]) continue;
            waiting[at] = true;
            try downstream.append(gpa, at);
        }
        var cursor: usize = 0;
        while (cursor < downstream.items.len) : (cursor += 1) {
            const list = waiting_on.get(self.changes.items[downstream.items[cursor]].hash) orelse continue;
            var next: ?usize = list.head;
            while (next) |entry_at| {
                const waiter = waiters.items[entry_at];
                // A change waiting on a change that was not emitted is itself
                // not emitted, so the mark never lands on one that left.
                if (!waiting[waiter.change]) {
                    waiting[waiter.change] = true;
                    try downstream.append(gpa, waiter.change);
                }
                next = waiter.next;
            }
        }
        for (taken, 0..) |was_taken, at| {
            if (!was_taken and !waiting[at]) return error.ChangeGraph;
        }

        // Size everything that has to be sized, and correct the index, before
        // a single change moves. That is what makes the queue unchanged when
        // the sort fails: every failure above this point, and the one inside
        // it, happens while the queue still holds all of its changes.
        //
        // Only the batch needs room. The queue's own list never grows here:
        // what stays is compacted over the slots it already occupies and then
        // shrunk, so it neither needs a reservation nor gets a benefit from
        // one — it used to be given one, which cost a reallocation and put an
        // `error.OutOfMemory` on the hot path of a sort that is documented to
        // leave the queue untouched.
        try batch.changes.ensureTotalCapacity(gpa, head);
        if (head != 0) {
            var next_at: usize = 0;
            for (self.changes.items, 0..) |change, at| {
                if (taken[at]) continue;
                self.index_by_hash.put(gpa, change.hash, next_at) catch return error.OutOfMemory;
                next_at += 1;
            }
        }

        // The batch takes the changes in the order they were emitted, which is
        // the dependency order and not the queue order, so it is read out
        // before the queue is compacted over the same slots.
        for (ready[0..head]) |at| {
            const change = self.changes.items[at];
            batch.changes.appendAssumeCapacity(change);
            batch.op_count +|= opCountOf(change);
        }

        // What is left keeps its arrival order, as upstream's `retain` does
        // (`change_queue.rs:174`). `kept` never runs ahead of `at`, so this
        // overwrites only entries already read.
        var kept: usize = 0;
        for (self.changes.items, 0..) |change, at| {
            if (taken[at]) continue;
            self.changes.items[kept] = change;
            kept += 1;
        }
        self.changes.shrinkRetainingCapacity(kept);
        // The changes that left no longer belong to either index
        // (`change_queue.rs:168-171`).
        for (batch.changes.items) |change| {
            _ = self.index_by_hash.remove(change.hash);
            _ = self.incoming_actor_seqs.remove(.{ .actor = change.actor, .seq = change.seq });
        }
        return batch;
    }

    /// The first hash on each path back from `start` that is neither applied
    /// nor queued, descending through the dependencies of queued changes on the
    /// way (`Automerge::missing_deps_from`, `automerge.rs:2034-2062`).
    ///
    /// This is what a peer is told to send (`sync.rs:184`). It is *not*
    /// `get_missing_deps` (`automerge.rs:2289-2292`): a queued orphan whose
    /// dependencies this peer will never have must not block the sync, so only
    /// the paths back from the hashes the peer asked about are walked. Upstream
    /// builds a `hash -> change` map of the queue on every call; the queue keeps
    /// that index, so this walk allocates only its own scratch.
    ///
    /// The result is sorted, deduplicated, and owned by the caller. `start` is
    /// the peer's advertised heads, or the queued hashes themselves when the
    /// caller wants the whole queue's view.
    pub fn missingDepsFrom(
        self: *const ChangeQueue,
        gpa: Allocator,
        graph: *const ChangeGraph,
        start: []const ChangeHash,
    ) Error![]ChangeHash {
        var seen: IndexByHash = .empty;
        defer seen.deinit(gpa);
        var missing: std.ArrayList(ChangeHash) = .empty;
        errdefer missing.deinit(gpa);
        var stack: std.ArrayList(ChangeHash) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, start);

        while (stack.pop()) |hash| {
            // Applied already, so everything it depends on is applied too.
            if (graph.hasChange(hash)) continue;
            if (seen.contains(hash)) continue;
            try seen.put(gpa, hash, 0);
            if (self.index_by_hash.get(hash)) |at| {
                // Queued, so the walk continues through it rather than
                // reporting it.
                try stack.appendSlice(gpa, self.changes.items[at].deps);
            } else {
                try missing.append(gpa, hash);
            }
        }

        std.mem.sort(ChangeHash, missing.items, {}, hashLessThan);
        return missing.toOwnedSlice(gpa);
    }
};

/// Total order over change hashes, which is the order every hash list this
/// module returns is in.
fn hashLessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
    return ChangeHash.order(a, b) == .lt;
}

const testing = std.testing;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A hash nothing else in these tests produces: the counter in the first four
/// bytes, so a failure names the change that was being built.
fn testHash(n: u32) ChangeHash {
    var hash = ChangeHash.zero;
    std.mem.writeInt(u32, hash.bytes[0..4], n, .little);
    return hash;
}

/// A change for a queue to own. The one allocation a `Change` owns is the
/// `other_actors` array, and that is the only one made here: a container that
/// drops a change without freeing it is caught by `std.testing.allocator`
/// rather than passing quietly. Everything else a change points at is
/// borrowed, which is what a parsed change does — the dependency hashes and
/// the actor bytes come out of the chunk the change was read from, and the
/// document owns that. So `deps` must outlive whatever holds the change.
///
/// `num_ops` is how many ops the change claims, which is what the batch's op
/// count is checked against; the op counter of a change is derived from its
/// sequence number so that two changes never claim the same op range.
fn testChange(
    gpa: Allocator,
    hash: ChangeHash,
    actor: []const u8,
    seq: u64,
    num_ops: u64,
    deps: []const ChangeHash,
) Error!Change {
    const others = try gpa.alloc(ActorId, 1);
    errdefer gpa.free(others);
    others[0] = .{ .bytes = actor };
    return .{
        .bytes = &.{},
        .header_len = 0,
        .actor = .{ .bytes = actor },
        .deps = deps,
        .hash = hash,
        .time = 0,
        .message = "",
        .seq = seq,
        .start_op = seq,
        .max_op = if (num_ops == 0) seq - 1 else seq + num_ops - 1,
        .other_actors = others,
    };
}

/// Copies the hashes of a batch into `out`, in dependency order, for
/// comparing against an expected order. A batch is a list of `Change`, and
/// `Change` does not start with its hash, so it cannot be viewed as one.
fn batchHashesInto(batch: ChangeBatch, out: []ChangeHash) void {
    std.debug.assert(out.len == batch.len());
    for (batch.changes.items, out) |change, *slot| slot.* = change.hash;
}

/// A queue and a graph that starts empty, which is the state a document is in
/// before it has applied anything. A change handed to `apply` is freed by it:
/// `addChange` copies the metadata it needs and takes ownership of nothing.
const Fixture = struct {
    queue: ChangeQueue,
    graph: ChangeGraph,
    authors: Authors,

    fn init(gpa: Allocator) Fixture {
        return .{
            .queue = ChangeQueue.init(gpa),
            .graph = ChangeGraph.init(gpa),
            .authors = Authors.init(gpa),
        };
    }

    fn deinit(self: *Fixture) void {
        self.queue.deinit();
        self.graph.deinit();
        self.authors.deinit();
    }

    /// Applies a change to the graph, so a later sort sees its dependencies as
    /// already satisfied.
    fn apply(self: *Fixture, gpa: Allocator, change: Change) Error!void {
        var owned_change = change;
        defer owned_change.deinit(gpa);
        var meta = try ChangeMetadata.fromChange(change).intoOwned(gpa);
        defer meta.deinit(gpa);
        try self.graph.addChange(gpa, &self.authors, meta);
    }
};

test "an empty queue sorts to an empty batch" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    try testing.expect(f.queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), f.queue.len());

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    try testing.expect(batch.isEmpty());
    try testing.expectEqual(@as(usize, 0), batch.opCount());
    try testing.expectEqual(@as(usize, 0), batch.blocked.items.len);
    try testing.expect(f.queue.isEmpty());
}

test "a change with no dependencies is popped" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 3, &.{}));

    try testing.expectEqual(@as(usize, 1), f.queue.len());
    try testing.expect(f.queue.contains(c1));
    try testing.expect(f.queue.get(c1) != null);
    try testing.expect(f.queue.containsActorSeq(.init("a"), 1));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    try testing.expectEqual(@as(usize, 1), batch.len());
    try testing.expect(batch.at(0).hash.eql(c1));
    try testing.expectEqual(@as(u64, 3), batch.opCount());
    try testing.expectEqual(@as(usize, 0), batch.blocked.items.len);

    // It left the queue, and the indexes with it.
    try testing.expect(f.queue.isEmpty());
    try testing.expect(!f.queue.contains(c1));
    try testing.expect(!f.queue.containsActorSeq(.init("a"), 1));
}

test "a chain of three pushed in reverse is popped in dependency order" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    const c2 = testHash(2);
    const c3 = testHash(3);
    // Newest first: nothing here could be applied as it stands.
    try f.queue.push(gpa, try testChange(gpa, c3, "a", 3, 1, &.{c2}));
    try f.queue.push(gpa, try testChange(gpa, c2, "a", 2, 1, &.{c1}));
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    try testing.expectEqual(@as(usize, 3), f.queue.len());

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    var order: [3]ChangeHash = undefined;
    batchHashesInto(batch, &order);
    try testing.expectEqualSlices(ChangeHash, &.{ c1, c2, c3 }, &order);
    try testing.expectEqual(@as(u64, 3), batch.opCount());
    try testing.expect(f.queue.isEmpty());
    try testing.expectEqual(@as(usize, 0), batch.blocked.items.len);
}

test "a chain whose first change is already applied is still ordered" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    const c2 = testHash(2);
    const c3 = testHash(3);
    // The document already holds the root of the chain, so the sort is seeded
    // from `graph.hasChange`, not from the queue.
    try f.apply(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    try f.queue.push(gpa, try testChange(gpa, c3, "a", 3, 1, &.{c2}));
    try f.queue.push(gpa, try testChange(gpa, c2, "a", 2, 1, &.{c1}));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    var order: [2]ChangeHash = undefined;
    batchHashesInto(batch, &order);
    try testing.expectEqualSlices(ChangeHash, &.{ c2, c3 }, &order);
    try testing.expect(f.queue.isEmpty());
}

test "two changes with no dependency between them are both popped" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    // A fork: two changes on top of the same parent, which the graph has.
    const root = testHash(1);
    const left = testHash(2);
    const right = testHash(3);
    try f.apply(gpa, try testChange(gpa, root, "a", 1, 1, &.{}));
    try f.queue.push(gpa, try testChange(gpa, left, "b", 1, 1, &.{root}));
    try f.queue.push(gpa, try testChange(gpa, right, "c", 1, 2, &.{root}));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    // Nothing orders the two against each other; the ready list is seeded in
    // queue order, so they come out the way they went in.
    var order: [2]ChangeHash = undefined;
    batchHashesInto(batch, &order);
    try testing.expectEqualSlices(ChangeHash, &.{ left, right }, &order);
    try testing.expectEqual(@as(u64, 3), batch.opCount());
    try testing.expect(f.queue.isEmpty());
}

test "three queued changes waiting on the same queued change are all released" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    // A merge: one queued change in the middle, and three that wait for it.
    // They hang off one dependency, so releasing them walks one list, and a
    // list that lost an entry would leave that change waiting forever.
    const base = testHash(1);
    const mid = testHash(2);
    const left = testHash(3);
    const right = testHash(4);
    const last = testHash(5);
    try f.apply(gpa, try testChange(gpa, base, "a", 1, 1, &.{}));
    try f.queue.push(gpa, try testChange(gpa, left, "b", 1, 1, &.{mid}));
    try f.queue.push(gpa, try testChange(gpa, mid, "c", 1, 1, &.{base}));
    try f.queue.push(gpa, try testChange(gpa, right, "d", 1, 1, &.{mid}));
    try f.queue.push(gpa, try testChange(gpa, last, "e", 1, 1, &.{mid}));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    // `mid` first, then the three that were waiting for it, in the order they
    // were queued.
    var order: [4]ChangeHash = undefined;
    batchHashesInto(batch, &order);
    try testing.expectEqualSlices(ChangeHash, &.{ mid, left, right, last }, &order);
    try testing.expect(f.queue.isEmpty());
}

test "one sort orders a merge of sixty-four heads and emits all of them" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    // The width every other test here is three at. The queue holds `tips`
    // changes that all wait for one queued merge, plus one that waits for a
    // change nobody has, so the walk has a wide waiter list to release, a
    // blocked change to report and a downstream mark to spread — and every
    // one of those lists is walked once.
    const tips = 64;
    const base = testHash(1);
    const merge = testHash(2);
    const gone = testHash(3);
    const orphan = testHash(4);
    try f.apply(gpa, try testChange(gpa, base, "a", 1, 1, &.{}));

    const deps = try gpa.alloc(ChangeHash, 2);
    defer gpa.free(deps);
    deps[0] = merge;
    deps[1] = base;
    // The merge is queued **before** every change that waits for it, so the
    // sort cannot lean on arrival order: the waiter lists are the only thing
    // that can release the tips. Its own dependency is `base`, which the
    // document already has, so it is ready on the first pass and everything
    // else in this batch waits on it rather than on arrival order.
    try f.queue.push(gpa, try testChange(gpa, merge, "a", 2, 1, &.{base}));
    var n: u32 = 0;
    while (n < tips) : (n += 1) {
        try f.queue.push(gpa, try testChange(gpa, testHash(0x100 + n), "b", n + 1, 1, deps));
    }
    // Waiting for a change nobody has, and one that waits for it in turn.
    try f.queue.push(gpa, try testChange(gpa, orphan, "c", 1, 1, &.{gone}));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    // The merge and every tip, and nothing else.
    try testing.expectEqual(@as(usize, tips + 1), batch.len());
    try testing.expectEqual(@as(usize, 1), batch.blocked.items.len);
    try testing.expect(batch.blocked.items[0].change.eql(orphan));
    try testing.expectEqual(@as(usize, 1), f.queue.len());
    try testing.expect(f.queue.contains(orphan));

    // A topological order: `merge` before every tip, which is the only
    // ordering constraint in this batch.
    var order: [tips + 1]ChangeHash = undefined;
    batchHashesInto(batch, &order);
    try testing.expect(order[0].eql(merge));
    var at: usize = 1;
    while (at < order.len) : (at += 1) {
        try testing.expect(order[at].eql(testHash(@intCast(0x100 + at - 1))));
    }
}

test "a change waiting for a change nobody has stays queued and is reported" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    const c2 = testHash(2);
    const gone = testHash(99);
    try f.queue.push(gpa, try testChange(gpa, c2, "a", 2, 1, &.{c1}));
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{gone}));

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();

    // Neither is ordered: the root of the chain is nowhere, and the child
    // cannot be applied before its parent whatever the parent does.
    try testing.expect(batch.isEmpty());
    try testing.expectEqual(@as(usize, 2), f.queue.len());
    try testing.expectEqual(@as(usize, 1), batch.blocked.items.len);
    try testing.expect(batch.blocked.items[0].change.eql(c1));
    try testing.expect(batch.blocked.items[0].dep.eql(gone));

    // And the hashes the peer has to send for the queue to drain.
    const missing = try f.queue.missingDepsFrom(gpa, &f.graph, &.{c2});
    defer gpa.free(missing);
    try testing.expectEqualSlices(ChangeHash, &.{gone}, missing);
}

test "a dependency cycle is refused and leaves the queue alone" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    // Two changes that name each other. The format cannot produce this — a
    // change hash covers its dependencies — so it is a document that cannot
    // be built, and the sort says so instead of spinning.
    const a = testHash(1);
    const b = testHash(2);
    try f.queue.push(gpa, try testChange(gpa, a, "a", 1, 1, &.{b}));
    try f.queue.push(gpa, try testChange(gpa, b, "b", 1, 1, &.{a}));

    try testing.expectError(error.ChangeGraph, f.queue.popTopoSortedReady(gpa, &f.graph));

    // The failed sort removed nothing and dropped nothing.
    try testing.expectEqual(@as(usize, 2), f.queue.len());
    try testing.expect(f.queue.contains(a));
    try testing.expect(f.queue.contains(b));
    try testing.expect(f.queue.containsActorSeq(.init("a"), 1));
    try testing.expect(f.queue.containsActorSeq(.init("b"), 1));

    // A change that depends on itself is the same case, and must not hang
    // either.
    var single: Fixture = Fixture.init(gpa);
    defer single.deinit();
    const self_dep = testHash(7);
    try single.queue.push(gpa, try testChange(gpa, self_dep, "a", 1, 1, &.{self_dep}));
    try testing.expectError(error.ChangeGraph, single.queue.popTopoSortedReady(gpa, &single.graph));
    try testing.expectEqual(@as(usize, 1), single.queue.len());
}

test "missingDepsFrom walks through queued changes and stops at applied ones" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const root = testHash(1);
    const q1 = testHash(2);
    const q2 = testHash(3);
    const far = testHash(10);
    const nearer = testHash(11);

    try f.apply(gpa, try testChange(gpa, root, "a", 1, 1, &.{}));
    // q1 waits for `far`; q2 waits for q1 and for `nearer`, neither of which
    // the document has.
    try f.queue.push(gpa, try testChange(gpa, q1, "a", 2, 1, &.{ root, far }));
    try f.queue.push(gpa, try testChange(gpa, q2, "a", 3, 1, &.{ q1, nearer }));

    // Starting at the applied change reports nothing: everything below it is
    // applied too.
    const none = try f.queue.missingDepsFrom(gpa, &f.graph, &.{root});
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Starting at the queue's own head descends through the queued changes and
    // stops at the two that nobody has. Sorted, because that is the order the
    // `have` set of a sync message is built in.
    const missing = try f.queue.missingDepsFrom(gpa, &f.graph, &.{q2});
    defer gpa.free(missing);
    try testing.expectEqualSlices(ChangeHash, &.{ far, nearer }, missing);

    // A hash the queue does not hold is itself missing, whatever it is.
    const unknown = try f.queue.missingDepsFrom(gpa, &f.graph, &.{testHash(42)});
    defer gpa.free(unknown);
    try testing.expectEqualSlices(ChangeHash, &.{testHash(42)}, unknown);
}

test "a change the queue already holds is dropped, a repeated sequence number is refused" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    // The same change again: a peer re-announcing it is normal, and the queue
    // takes it and throws it away.
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    try testing.expectEqual(@as(usize, 1), f.queue.len());

    // A different change claiming the same slot of the actor's history is a
    // conflict, not a duplicate.
    try testing.expectError(
        error.DuplicateSeqNumber,
        f.queue.push(gpa, try testChange(gpa, testHash(2), "a", 1, 1, &.{})),
    );
    try testing.expectEqual(@as(usize, 1), f.queue.len());
    try testing.expect(!f.queue.contains(testHash(2)));

    // Another actor may use that sequence number, and a failed push left
    // nothing behind.
    const other = testHash(3);
    try f.queue.push(gpa, try testChange(gpa, other, "b", 1, 1, &.{}));
    try testing.expectEqual(@as(usize, 2), f.queue.len());
    try testing.expect(f.queue.contains(other));
}

test "removeActorBranchFrom drops the branch and everything that depends on it" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const a1 = testHash(1);
    const a2 = testHash(2);
    const a3 = testHash(3);
    const a4 = testHash(4);
    const b1 = testHash(5);
    const c1 = testHash(6);
    const d1 = testHash(7);
    // One actor's chain of four, a second actor's lone change, and two more
    // changes hung off the middle of the chain. Removing the chain from its
    // second change has to reach the fourth — two steps down the chain — and
    // both of the others: `c1` one step sideways, and `d1`, which depends only
    // on `c1`, two steps out.
    try f.queue.push(gpa, try testChange(gpa, a1, "a", 1, 1, &.{}));
    try f.queue.push(gpa, try testChange(gpa, a2, "a", 2, 1, &.{a1}));
    try f.queue.push(gpa, try testChange(gpa, a3, "a", 3, 1, &.{a2}));
    try f.queue.push(gpa, try testChange(gpa, a4, "a", 4, 1, &.{a3}));
    try f.queue.push(gpa, try testChange(gpa, b1, "b", 1, 1, &.{}));
    try f.queue.push(gpa, try testChange(gpa, c1, "c", 1, 1, &.{ a2, b1 }));
    try f.queue.push(gpa, try testChange(gpa, d1, "d", 1, 1, &.{c1}));

    // Everything from `a2` on, plus the change that depends on it.
    try f.queue.removeActorBranchFrom(gpa, .init("a"), 2);

    const left = f.queue.slice();
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expect(left[0].hash.eql(a1));
    try testing.expect(left[1].hash.eql(b1));
    // The indexes describe what is left, so a re-push of a dropped change is
    // accepted and the dropped ones are no longer claimed.
    try testing.expect(f.queue.contains(a1));
    try testing.expect(f.queue.contains(b1));
    try testing.expect(!f.queue.contains(a2));
    try testing.expect(!f.queue.contains(a3));
    try testing.expect(!f.queue.contains(a4));
    // And the change two steps out, which depends only on `c1`.
    try testing.expect(!f.queue.contains(c1));
    try testing.expect(!f.queue.contains(d1));
    try testing.expect(!f.queue.containsActorSeq(.init("c"), 1));
    // And the index points at the change it names, after the move.
    try testing.expect(f.queue.get(b1).?.hash.eql(b1));
    try testing.expect(f.queue.get(b1).?.seq == 1);

    // A sequence number before the conflict, and an actor the queue has never
    // heard of, both leave it as it is.
    try f.queue.removeActorBranchFrom(gpa, .init("a"), 2);
    try f.queue.removeActorBranchFrom(gpa, .init("z"), 1);
    try testing.expectEqual(@as(usize, 2), f.queue.len());
    try testing.expect(f.queue.contains(a1));
    try testing.expect(f.queue.contains(b1));
}

test "clear empties the queue and keeps it usable" {
    const gpa = testing.allocator;
    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();

    const c1 = testHash(1);
    const c2 = testHash(2);
    try f.queue.push(gpa, try testChange(gpa, c2, "a", 2, 1, &.{c1}));
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    try testing.expectEqual(@as(usize, 2), f.queue.len());

    f.queue.clear();
    try testing.expect(f.queue.isEmpty());
    try testing.expect(!f.queue.contains(c1));

    // The change numbers of a cleared queue are free again, so a peer's next
    // batch is not refused for a sequence number nothing is holding.
    try f.queue.push(gpa, try testChange(gpa, c1, "a", 1, 1, &.{}));
    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();
    try testing.expectEqual(@as(usize, 1), batch.len());
}

test "a large reverse-arriving chain is emitted in dependency order" {
    // Wall-clock ratios depend on scheduler load, not only on the sort.
    // Check every dependency instead; the linear-work argument is at the
    // implementation (`change_queue.rs:127-176`).
    const gpa = testing.allocator;
    const n: usize = 8_000;

    // The changes borrow their dependency slices from this array.
    const hashes = try gpa.alloc(ChangeHash, n);
    defer gpa.free(hashes);
    for (hashes, 0..) |*hash, at| {
        hash.* = testHash(@intCast(at + 1));
    }

    var f: Fixture = Fixture.init(gpa);
    defer f.deinit();
    for (hashes, 0..) |hash, at| {
        const rev = n - 1 - at;
        const deps = if (rev == 0) &.{} else hashes[n - rev ..][0..1];
        try f.queue.push(gpa, try testChange(gpa, hash, "a", @intCast(rev + 1), 1, deps));
    }
    try testing.expectEqual(n, f.queue.len());

    var batch = try f.queue.popTopoSortedReady(gpa, &f.graph);
    defer batch.deinit();
    try testing.expectEqual(n, batch.len());
    for (hashes, 0..) |hash, at| {
        try testing.expect(batch.at(n - 1 - at).hash.eql(hash));
    }
    try testing.expect(f.queue.isEmpty());
}
