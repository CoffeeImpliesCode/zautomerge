//! The graph of changes (`rust/automerge/src/change_graph.rs`).
//!
//! A document is a DAG of changes. A change names the changes it depends on,
//! and one may only be added once all of them are present, so the graph is
//! append-only and a lower node index always means an older change
//! (`add_change`, `change_graph.rs:708-727`). That one fact does most of the
//! work: a topological order is just node order, and the answer to "what has
//! this document seen" is a fold over the ancestors of a set of heads.
//!
//! Three structures ride on the DAG:
//!
//! * **nodes** — one owned `ChangeMetadata` per change (`change.zig`) plus the
//!   two edge lists that make the graph navigable in both directions. Upstream
//!   keeps only an `ActorIdx` per node and splits the per-change scalars into
//!   nine `hexane` columns, because that is what the document format stores
//!   (`change_graph.rs:29-47`, `:236-272`, `:1778-1798`); this port keeps the
//!   metadata whole and leaves the projection to the storage layer. Every
//!   column upstream writes is derivable from it: `seq` and `max_op` are the
//!   columns of those names, `num_ops` is `max_op - start_op + 1` (zero for an
//!   empty change, whose `max_op` is `start_op - 1`), and the dependency
//!   stream is the parent edge list.
//! * **the per-actor sequence index** — `seq_index[actor]` holds that actor's
//!   changes in sequence order, so its length is the actor's next sequence
//!   number (`seq_for_actor`, `change_graph.rs:216-221`) and element `n` is
//!   the actor's `(n+1)`th change. Per-actor changes are strictly sequential:
//!   an actor's `seq` is one more than the number of its changes already in
//!   the graph, which upstream asserts on the add path
//!   (`change_graph.rs:568-570`) and this port reports as an error.
//! * **the clock cache** — a `SeqClock` for every sixteenth node, holding the
//!   folded state at that node, so a walk that reaches one merges instead of
//!   descending (`cache_clock`, `change_graph.rs:729-743`).
//!
//! ## Two clocks
//!
//! `SeqClock` counts *changes*: entry `i` is the highest sequence number seen
//! from actor `i`, and null means the actor has not been seen. `Clock` counts
//! *op counters*: entry `i` is the highest counter seen from actor `i`
//! (`clock.zig`). The graph computes the first and maps it to the second by
//! looking up the `max_op` of the change at that sequence number
//! (`clock_at`, `change_graph.rs:794-806`); getting that substitution wrong
//! turns every clock into a sequence number, and `Clock.covers` then reports
//! coverage the document does not have.
//!
//! ## Heads
//!
//! A head is a change with no child, maintained incrementally: adding a
//! change removes each of its dependencies from the head set and inserts the
//! change itself (`update_heads`, `change_graph.rs:513-518`). The set is kept
//! sorted by hash, which is what the `BTreeSet<ChangeHash>` upstream gives.
//! `recomputeHeads` derives the same set from the child edges, and is what a
//! graph loaded from a stored document should be checked against.
//!
//! ## Actor indices
//!
//! Every stored actor reference is an index into the document's actor table
//! (`author.zig`). A change that names an actor the table has not seen makes
//! the table grow, and an actor that sorts before an existing one shifts every
//! index above it, so adding a change rewrites the actor index of every node
//! and every cached clock (`insert_actor`, `change_graph.rs:151-167`). That
//! rewrite is the only way a cached clock can go stale: a change only ever
//! adds a *child*, and the clock at a node depends on that node and its
//! ancestors alone.

const std = @import("std");
const error_types = @import("error.zig");
const types = @import("types.zig");
const clock_mod = @import("clock.zig");
const change_mod = @import("change.zig");
const author_mod = @import("author.zig");

const Error = error_types.Error;
const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const OpId = types.OpId;
const ChangeHash = types.ChangeHash;
const Clock = clock_mod.Clock;
const SeqClock = clock_mod.SeqClock;
const ChangeMetadata = change_mod.ChangeMetadata;
const Authors = author_mod.Authors;

/// How often a node's clock is cached: one entry per `cache_step` nodes
/// (`CACHE_STEP`, `change_graph.rs:51`). Every sixteenth node means a walk
/// over `n` changes merges `n / 16` cached clocks instead of descending, at
/// the cost of `n / 16` clocks of `num_actors` slots.
pub const cache_step: u32 = 16;

/// A change's index. Bounded by the heap, so `u32` is the width upstream
/// chose (`NodeIdx`, `change_graph.rs:53-54`).
pub const NodeIdx = u32;

/// The first node count that does not fit in `NodeIdx`.
const max_node_count: usize = std.math.maxInt(NodeIdx);

/// One edge of an adjacency list: the node at the far end, and the next edge
/// from the same node (`Edge`, `change_graph.rs:76-82`).
///
/// The list is singly linked and the node it hangs off is implicit, which is
/// why there is one array for `child -> parent` edges and one for the
/// reverse. Upstream only ever walks parents and a change's own metadata
/// already carries the dependency hashes; the reverse edges are what let a
/// historical head be asked directly instead of by a search.
const Edge = struct {
    /// The node at the far end of the edge.
    target: NodeIdx,
    /// The next edge from the same node, or null at the end of the list.
    next: ?NodeIdx,
};

/// One change in the graph.
pub const Node = struct {
    /// The change's metadata, owned: the actor bytes, the dependency hashes,
    /// the message and the referenced actor bytes are all copies, so a node
    /// outlives the chunk it was parsed from. Free it with `deinit`.
    meta: ChangeMetadata,
    /// The change author as an index into the document's actor table. This is
    /// the `ActorIdx` upstream stores in its `actor` column
    /// (`change_graph.rs:31`), and the index every clock entry is keyed by.
    actor: ActorIdx,
    /// The first edge of this node's dependency (child -> parent) list, or
    /// null when the change has no dependencies.
    parents: ?NodeIdx,
    /// The first edge of this node's child (parent -> child) list, or null.
    children: ?NodeIdx,
};

/// A cached clock: the state at `node`, i.e. the merge of the clocks of every
/// change `node` depends on, transitively.
const ClockEntry = struct {
    node: NodeIdx,
    clock: SeqClock,
};

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

/// The `hash -> node` index (`nodes_by_hash`, `change_graph.rs:42`).
const NodeMap = std.HashMapUnmanaged(ChangeHash, NodeIdx, HashContext, 80);

/// A set of change hashes, for the walks that must not visit a hash twice.
const HashSet = std.HashMapUnmanaged(ChangeHash, void, HashContext, 80);

/// Walks one node's edge list. A value, not a heap object: an iterator
/// allocates nothing, and the slice it holds belongs to the graph and is only
/// valid until the next change is added (`parents`, `change_graph.rs:774-782`).
pub const NodeIter = struct {
    edges: []const Edge,
    edge: ?NodeIdx,

    /// The next node on the list, or null at the end.
    pub fn next(self: *NodeIter) ?NodeIdx {
        const at = self.edge orelse return null;
        const edge = self.edges[at];
        self.edge = edge.next;
        return edge.target;
    }
};

/// The graph of changes.
pub const ChangeGraph = struct {
    /// The allocator this graph allocates from. As with `std.ArrayList`,
    /// every `gpa` argument passed to a method must be this allocator,
    /// because `deinit` frees with it.
    gpa: Allocator,
    /// The changes, in the order they were added. Every dependency of a node
    /// has a smaller index, because a change is only added once its
    /// dependencies are, so index order is a topological order.
    nodes: std.ArrayList(Node),
    /// The `child -> parent` edges. A node's own list hangs off
    /// `Node.parents`; the child is implicit in the node holding the list.
    parent_edges: std.ArrayList(Edge),
    /// The `parent -> child` edges, the reverse walk.
    child_edges: std.ArrayList(Edge),
    /// Every change's hash, to its node.
    by_hash: NodeMap,
    /// The heads: the changes with no child, sorted ascending by hash. This is
    /// the `BTreeSet<ChangeHash>` of `change_graph.rs:41`.
    heads: std.ArrayList(ChangeHash),
    /// `seq_index[actor]` is that actor's changes in sequence order. Its
    /// length is the actor's next sequence number, and it is empty for an
    /// actor the graph has no change from.
    seq_index: std.ArrayList(std.ArrayList(NodeIdx)),
    /// Cached clocks, sorted by node so a lookup is a binary search. Upstream
    /// uses a `HashMap<NodeIdx, SeqClock>` (`change_graph.rs:43`); a sorted
    /// list is the map this port uses, and an entry is only ever added for a
    /// node that has none, so the common case is an append.
    clock_cache: std.ArrayList(ClockEntry),
    /// The highest op counter any change in the graph owns. A new local
    /// change starts at `max_op + 1` (`automerge.rs:566-567`).
    max_op: u64,
    /// The walk generation a node must carry to count as visited in the walk
    /// that is running. Reused across walks so no walk allocates a visited
    /// set.
    stamp: u32,
    /// One stamp per node, parallel to `nodes`.
    visit_stamp: std.ArrayList(u32),

    /// An empty graph. `gpa` must be the allocator every later call passes.
    pub fn init(gpa: Allocator) ChangeGraph {
        return .{
            .gpa = gpa,
            .nodes = .empty,
            .parent_edges = .empty,
            .child_edges = .empty,
            .by_hash = .empty,
            .heads = .empty,
            .seq_index = .empty,
            .clock_cache = .empty,
            .max_op = 0,
            .stamp = 0,
            .visit_stamp = .empty,
        };
    }

    /// Releases every node's metadata, every edge, the clock cache and the
    /// per-actor index in one call.
    pub fn deinit(self: *ChangeGraph) void {
        for (self.nodes.items) |*node| node.meta.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.parent_edges.deinit(self.gpa);
        self.child_edges.deinit(self.gpa);
        self.by_hash.deinit(self.gpa);
        self.heads.deinit(self.gpa);
        for (self.seq_index.items) |*list| list.deinit(self.gpa);
        self.seq_index.deinit(self.gpa);
        for (self.clock_cache.items) |*entry| entry.clock.deinit();
        self.clock_cache.deinit(self.gpa);
        self.visit_stamp.deinit(self.gpa);
        self.* = undefined;
    }

    /// The number of changes in the graph (`len`, `change_graph.rs:188-190`).
    pub fn len(self: *const ChangeGraph) usize {
        return self.nodes.items.len;
    }

    /// True when the graph holds no change.
    pub fn isEmpty(self: *const ChangeGraph) bool {
        return self.nodes.items.len == 0;
    }

    /// The number of actor slots the graph has: one per actor of the document
    /// it belongs to. Every clock this graph computes has exactly this many
    /// entries, so a caller whose actor table is larger must have told the
    /// graph about the extra actors with `insertActor`.
    pub fn numActors(self: *const ChangeGraph) usize {
        return self.seq_index.items.len;
    }

    /// The highest op counter any change owns (`max_op`,
    /// `change_graph.rs:204-206`).
    pub fn maxOp(self: *const ChangeGraph) u64 {
        return self.max_op;
    }

    /// The `max_op` of `actor`'s last change, or zero when it has none
    /// (`max_op_for_actor`, `change_graph.rs:208-214`).
    pub fn maxOpForActor(self: *const ChangeGraph, actor: ActorIdx) u64 {
        const list = self.actorChanges(actor) orelse return 0;
        if (list.items.len == 0) return 0;
        return self.nodes.items[list.items[list.items.len - 1]].meta.max_op;
    }

    /// `actor`'s next sequence number: one more than the number of its changes
    /// in the graph (`seq_for_actor`, `change_graph.rs:216-221`).
    pub fn seqForActor(self: *const ChangeGraph, actor: ActorIdx) u64 {
        const list = self.actorChanges(actor) orelse return 0;
        return list.items.len;
    }

    /// The hash of `actor`'s `seq`th change, one-based. Fails with
    /// `error.InvalidSeq` when the actor has no such change, which is what
    /// upstream reports (`get_hash_for_actor_seq`, `change_graph.rs:500-511`).
    pub fn hashForActorSeq(self: *const ChangeGraph, actor: ActorIdx, seq: u64) Error!ChangeHash {
        if (seq == 0) return error.InvalidSeq;
        const list = self.actorChanges(actor) orelse return error.InvalidSeq;
        if (seq > list.items.len) return error.InvalidSeq;
        return self.nodes.items[list.items[@intCast(seq - 1)]].meta.hash;
    }

    /// True when the graph holds `hash` (`has_change`,
    /// `change_graph.rs:334-336`).
    pub fn hasChange(self: *const ChangeGraph, hash: ChangeHash) bool {
        return self.by_hash.contains(hash);
    }

    /// The node index of `hash`, or null.
    pub fn hashToIndex(self: *const ChangeGraph, hash: ChangeHash) ?NodeIdx {
        return self.by_hash.get(hash);
    }

    /// The hash of node `idx`, or null when `idx` is out of range
    /// (`index_to_hash`, `change_graph.rs:200-202`).
    pub fn indexToHash(self: *const ChangeGraph, idx: NodeIdx) ?ChangeHash {
        const node = self.nodeAt(idx) orelse return null;
        return node.meta.hash;
    }

    /// Node `idx`, or null when `idx` is out of range. The node borrows the
    /// graph and is invalidated by the next `addChange`.
    pub fn nodeAt(self: *const ChangeGraph, idx: NodeIdx) ?*const Node {
        const i: usize = idx;
        if (i >= self.nodes.items.len) return null;
        return &self.nodes.items[i];
    }

    /// The node for `hash`, or null. Borrows the graph, as `nodeAt` does.
    pub fn nodeFor(self: *const ChangeGraph, hash: ChangeHash) ?*const Node {
        const idx = self.by_hash.get(hash) orelse return null;
        return self.nodeAt(idx);
    }

    /// `actor`'s changes in sequence order, or null when `actor` has no slot.
    fn actorChanges(self: *const ChangeGraph, actor: ActorIdx) ?std.ArrayList(NodeIdx) {
        const i: usize = actor;
        if (i >= self.seq_index.items.len) return null;
        return self.seq_index.items[i];
    }

    /// The current heads, sorted ascending by hash (`heads`,
    /// `change_graph.rs:126-128`). Borrows the graph, and is invalidated by the
    /// next `addChange`.
    pub fn getHeads(self: *const ChangeGraph) []const ChangeHash {
        return self.heads.items;
    }

    /// Whether `list` is exactly the set of current heads, order and
    /// duplicates ignored (`heads_are_current`, `change_graph.rs:130-139`).
    ///
    /// Upstream short-circuits on a shorter list and then compares two sets.
    /// This is the same answer without building a set: consume `list` in
    /// lockstep with the head list, so a repeated hash in `list` leaves a real
    /// head unmatched.
    pub fn headsAreCurrent(self: *const ChangeGraph, list: []const ChangeHash) bool {
        if (list.len != self.heads.items.len) return false;
        var at: usize = 0;
        for (self.heads.items) |head| {
            var found = false;
            while (at < list.len) : (at += 1) {
                if (list[at].eql(head)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// The heads recomputed from the child edges: every change that no other
    /// change depends on. This is the definition the incremental head set has
    /// to agree with, and it is what a graph loaded from a stored document
    /// should be checked against — a stored document carries its own head set
    /// (`ChangeGraphCols::load`, `change_graph.rs:1017`).
    ///
    /// The result is sorted ascending, like `heads`.
    pub fn recomputeHeads(self: *const ChangeGraph, gpa: Allocator) Error![]ChangeHash {
        var out: std.ArrayList(ChangeHash) = .empty;
        errdefer out.deinit(gpa);
        for (self.nodes.items) |node| {
            if (node.children == null) try out.append(gpa, node.meta.hash);
        }
        std.mem.sort(ChangeHash, out.items, {}, hashLessThan);
        return out.toOwnedSlice(gpa);
    }

    /// Adds a change, and every actor it references, to the graph.
    ///
    /// Refused:
    ///
    /// * `error.MissingDeps` when a dependency is not in the graph. Upstream
    ///   reports the offending hash in a `MissingDep` payload
    ///   (`change_graph.rs:720-724`, `:1053-1055`); `Error` carries no
    ///   payload, so `firstMissingDep` names it. A change that depends on
    ///   itself lands here too, because it is not in the graph yet.
    /// * `error.DuplicateSeqNumber` when the change's actor already has a
    ///   change at that sequence number or beyond. This is `has_actor_seq`
    ///   (`automerge.rs:1089-1091`), the check `BatchApply::new` makes before
    ///   a change reaches the graph (`op_set2/change/batch.rs:1073-1076`) and
    ///   the change queue makes within one batch (`change_queue.rs:28-31`).
    /// * `error.InvalidSeq` when the sequence number is zero, past `u32::MAX`
    ///   (a `SeqClock` entry is a `u32`, and upstream's `seq` column is a
    ///   `u32` too, `change_graph.rs:242`), or greater than the actor's next
    ///   sequence number. Upstream asserts the last one
    ///   (`change_graph.rs:569`) and panics; a change that skips a sequence
    ///   number belongs to a history this document has not seen, so it is an
    ///   error here rather than a corrupt graph.
    ///
    /// Adding a change the graph already holds is a no-op
    /// (`change_graph.rs:716-718`): a peer re-announcing a change is normal.
    ///
    /// Every actor the change names — its author, and every actor in
    /// `other_actors` — is interned into `authors` first, and the remap that
    /// produces is applied to every stored actor index and to every cached
    /// clock. Interning is idempotent, so an actor the table already has costs
    /// one lookup. A change refused after that point may still have left its
    /// actors in the table, which is harmless: the table is the document's, and
    /// interning is monotone.
    ///
    /// `meta.max_op` must be filled in by whoever decoded the change's op
    /// columns (`Change.withOpCount`, `change.zig`); the header alone does not
    /// carry the op count.
    pub fn addChange(
        self: *ChangeGraph,
        gpa: Allocator,
        authors: *Authors,
        meta: ChangeMetadata,
    ) Error!void {
        if (self.by_hash.contains(meta.hash)) return;
        for (meta.deps) |dep| {
            if (!self.by_hash.contains(dep)) return error.MissingDeps;
        }

        const actor = try self.internActors(gpa, authors, meta);
        if (meta.seq == 0 or std.math.cast(u32, meta.seq) == null) return error.InvalidSeq;
        const have = self.seqForActor(actor);
        if (meta.seq <= have) return error.DuplicateSeqNumber;
        if (meta.seq > have + 1) return error.InvalidSeq;

        const idx = try self.pushNode(gpa, meta, actor);
        if ((@as(u64, idx) + 1) % cache_step == 0) try self.cacheClock(gpa, idx);
    }

    /// The first dependency of `meta` this graph does not have, or null when
    /// it has them all. This is what `addChange` refuses a change for, and it
    /// is the `MissingDep(ChangeHash)` payload (`change_graph.rs:1053-1055`)
    /// as a query: a caller that has just been refused a change still holds
    /// it, and this names the change it is waiting for.
    pub fn firstMissingDep(self: *const ChangeGraph, meta: ChangeMetadata) ?ChangeHash {
        for (meta.deps) |dep| {
            if (!self.by_hash.contains(dep)) return dep;
        }
        return null;
    }

    /// The clock at `heads`: for every actor, the highest op counter this
    /// document has seen from it, counting only the changes `heads` depends on
    /// (`clock_at`, `change_graph.rs:794-806`).
    ///
    /// A head the graph does not have is dropped, as upstream's `filter_map`
    /// drops it (`change_graph.rs:784-792`), so a head from another document
    /// yields a clock that silently omits its history. Callers that care ask
    /// `getMissingDeps` first.
    ///
    /// The result is owned by the caller. The receiver is mutable because the
    /// walk marks the nodes it visits in the graph's own scratch array, the
    /// same interior mutability upstream gets from `&self` plus its interior
    /// `BTreeSet` (`change_graph.rs:833`).
    pub fn clockAt(self: *ChangeGraph, gpa: Allocator, heads: []const ChangeHash) Error!Clock {
        var clock = try Clock.init(gpa, self.numActors());
        errdefer clock.deinit();
        var seq_clock = try self.seqClockForHeads(gpa, heads);
        defer seq_clock.deinit();
        for (seq_clock.values(), 0..) |seq, actor| {
            const s = seq orelse continue;
            clock.slots[actor] = @intCast(self.maxOpAtSeq(@intCast(actor), s));
        }
        return clock;
    }

    /// The sequence clock at `heads`: for every actor, the highest change
    /// sequence number reachable from `heads` (`seq_clock_for_heads`,
    /// `change_graph.rs:808-811`).
    pub fn seqClockForHeads(
        self: *ChangeGraph,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error!SeqClock {
        var to_visit: std.ArrayList(NodeIdx) = .empty;
        defer to_visit.deinit(gpa);
        for (heads) |hash| {
            if (self.by_hash.get(hash)) |idx| try to_visit.append(gpa, idx);
        }
        return self.calculateClock(gpa, to_visit.items);
    }

    /// The `max_op` of `actor`'s change at sequence number `seq`, or zero when
    /// the graph has no such change. This is the step that turns a sequence
    /// clock into an op-counter clock (`change_graph.rs:798-804`).
    fn maxOpAtSeq(self: *const ChangeGraph, actor: ActorIdx, seq: u32) u64 {
        if (seq == 0) return 0;
        const list = self.actorChanges(actor) orelse return 0;
        if (seq > list.items.len) return 0;
        return self.nodes.items[list.items[@intCast(seq - 1)]].meta.max_op;
    }

    /// Folds the clock of every change reachable from `to_visit` into a fresh
    /// clock (`calculate_clock`, `change_graph.rs:817-825`).
    fn calculateClock(
        self: *ChangeGraph,
        gpa: Allocator,
        to_visit: []const NodeIdx,
    ) Error!SeqClock {
        var clock = try SeqClock.init(gpa, self.numActors());
        errdefer clock.deinit();
        var frontier: std.ArrayList(NodeIdx) = .empty;
        defer frontier.deinit(gpa);
        try frontier.appendSlice(gpa, to_visit);
        try self.walkClock(gpa, &clock, &frontier);
        return clock;
    }

    /// Depth-first fold of the reachable clocks into `clock`
    /// (`calculate_clock_inner`, `change_graph.rs:827-853`).
    ///
    /// The frontier is a sorted set and the *largest* node is taken first, so
    /// a history is walked newest first and a node with a cached clock stands
    /// in for its whole ancestor cone. Because `addChange` caches every
    /// sixteenth node, a walk stops within `cache_step` steps of where it
    /// started.
    fn walkClock(
        self: *ChangeGraph,
        gpa: Allocator,
        clock: *SeqClock,
        frontier: *std.ArrayList(NodeIdx),
    ) Error!void {
        const stamp = self.nextStamp();
        while (frontier.pop()) |idx| {
            if (self.isVisited(idx, stamp)) continue;
            self.markVisited(idx, stamp);

            const node = self.nodes.items[idx];
            // A node contributes its own sequence number for its actor
            // (`clock_data_for`, `change_graph.rs:813-815`).
            if (node.meta.clockEntry()) |seq| _ = clock.include(node.actor, seq);

            if (self.cachedClock(idx)) |sub| {
                clock.merge(sub);
                continue;
            }

            var it = self.parents(idx);
            while (it.next()) |parent| {
                if (!self.isVisited(parent, stamp)) {
                    try insertNodeIdxSorted(frontier, gpa, parent);
                }
            }
        }
    }

    /// The clock at `node`, computed by the walk and then cached
    /// (`cache_clock`, `change_graph.rs:729-743`).
    ///
    /// Upstream stops the walk after `2 * cache_step` nodes and finishes the
    /// job by recursing into the frontier, caching every node it meets on the
    /// way. This walks to the end of the cone instead. The clock is the same
    /// either way, and the walk is still short: the cache holds every
    /// sixteenth node, so it meets one within `cache_step` steps. The
    /// difference is that this needs no recursion, and a document with a
    /// million changes would give the recursive form a stack depth of tens of
    /// thousands of frames.
    fn cacheClock(self: *ChangeGraph, gpa: Allocator, node: NodeIdx) Error!void {
        var clock = try SeqClock.init(gpa, self.numActors());
        defer clock.deinit();
        var frontier: std.ArrayList(NodeIdx) = .empty;
        defer frontier.deinit(gpa);
        try frontier.append(gpa, node);
        try self.walkClock(gpa, &clock, &frontier);

        var stored = try clock.clone();
        errdefer stored.deinit();
        try self.putCachedClock(gpa, node, stored);
    }

    /// The cached clock for `node`, or null. The value borrows the cache.
    fn cachedClock(self: *const ChangeGraph, node: NodeIdx) ?SeqClock {
        const at = self.cacheIndex(node) orelse return null;
        return self.clock_cache.items[at].clock;
    }

    /// How many clocks are cached. A walk over `n` changes caches at least
    /// `n / cache_step` of them, so this is how a caller can see that the
    /// cache is being filled at all.
    pub fn cachedClockCount(self: *const ChangeGraph) usize {
        return self.clock_cache.items.len;
    }

    /// Stores `clock` as the clock at `node`, replacing any entry for it.
    fn putCachedClock(self: *ChangeGraph, gpa: Allocator, node: NodeIdx, clock: SeqClock) Error!void {
        if (self.cacheIndex(node)) |at| {
            self.clock_cache.items[at].clock.deinit();
            self.clock_cache.items[at].clock = clock;
            return;
        }
        try self.clock_cache.insert(gpa, cacheInsertIndex(self.clock_cache.items, node), .{
            .node = node,
            .clock = clock,
        });
    }

    /// The index of `node`'s cache entry, or null. The list is sorted by node.
    fn cacheIndex(self: *const ChangeGraph, node: NodeIdx) ?usize {
        var lo: usize = 0;
        var hi: usize = self.clock_cache.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.math.order(self.clock_cache.items[mid].node, node)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    /// The walk generation the current walk stamps nodes with. Wrapping is
    /// astronomically unlikely, and the reset makes it correct rather than
    /// merely unlikely.
    fn nextStamp(self: *ChangeGraph) u32 {
        self.stamp +%= 1;
        if (self.stamp == 0) {
            @memset(self.visit_stamp.items, 0);
            self.stamp = 1;
        }
        return self.stamp;
    }

    fn isVisited(self: *const ChangeGraph, node: NodeIdx, stamp: u32) bool {
        const i: usize = node;
        if (i >= self.visit_stamp.items.len) return false;
        return self.visit_stamp.items[i] == stamp;
    }

    fn markVisited(self: *ChangeGraph, node: NodeIdx, stamp: u32) void {
        self.visit_stamp.items[node] = stamp;
    }

    /// The changes this document has that a peer at `have_deps` has not, as
    /// node indices, each dependency before the change that needs it
    /// (`get_build_indexes`, `change_graph.rs:457-474`).
    ///
    /// Per actor the walk takes the changes after the sequence number the
    /// peer's clock records, and the result is sorted by node index — which,
    /// because a dependency always has the smaller index, is a valid
    /// application order. Upstream sorts for the same reason and notes that
    /// the order only groups by actor when the history was built locally.
    ///
    /// `have_deps` empty means "every change", as upstream short-circuits it
    /// (`change_graph.rs:476-479`).
    pub fn getChangeIndexes(
        self: *ChangeGraph,
        gpa: Allocator,
        have_deps: []const ChangeHash,
    ) Error![]NodeIdx {
        var out: std.ArrayList(NodeIdx) = .empty;
        errdefer out.deinit(gpa);
        if (have_deps.len == 0) {
            try out.ensureTotalCapacity(gpa, self.nodes.items.len);
            var i: NodeIdx = 0;
            while (i < self.nodes.items.len) : (i += 1) try out.append(gpa, i);
            return out.toOwnedSlice(gpa);
        }

        var clock = try self.seqClockForHeads(gpa, have_deps);
        defer clock.deinit();
        for (self.seq_index.items, 0..) |list, actor| {
            const have = clock.get(@intCast(actor)) orelse 0;
            // `have` cannot exceed the actor's change count, because the clock
            // was folded out of this graph; the clamp keeps a corrupt state
            // from slicing out of range.
            const from: u32 = @intCast(@min(have, list.items.len));
            try out.appendSlice(gpa, list.items[from..]);
        }
        std.mem.sortUnstable(NodeIdx, out.items, {}, std.sort.asc(NodeIdx));
        return out.toOwnedSlice(gpa);
    }

    /// The changes a peer at `have_deps` has not seen, as hashes, each
    /// dependency before the change that needs it.
    ///
    /// Turning these hashes into change bytes is the change collector's job,
    /// not the graph's: the bytes live in the op set, not here. The metadata
    /// for a node is `nodeAt` / `nodeFor`.
    pub fn getChanges(
        self: *ChangeGraph,
        gpa: Allocator,
        have_deps: []const ChangeHash,
    ) Error![]ChangeHash {
        const indexes = try self.getChangeIndexes(gpa, have_deps);
        defer gpa.free(indexes);
        const out = try gpa.alloc(ChangeHash, indexes.len);
        for (indexes, 0..) |idx, i| out[i] = self.nodes.items[idx].meta.hash;
        return out;
    }

    /// The changes in `other` that this graph does not have, each dependency
    /// before the change that needs it (`Automerge::get_changes_added`,
    /// `automerge.rs:1531-1552`).
    ///
    /// The walk starts at `their_heads` in `other` and descends into `other`'s
    /// dependencies, stopping wherever this graph already holds the change. The
    /// result is the reverse of the depth-first order, which upstream notes is
    /// not a topological sort but is usually close; here it is exactly one,
    /// because a change is only added to a graph after its dependencies.
    ///
    /// There is no `our_heads` argument because upstream has none: the test is
    /// whether this graph holds the hash at all (`automerge.rs:1540`), which is
    /// at least as strong as testing against a head list, and is the only test
    /// that is right once the two documents have diverged.
    pub fn getChangesAdded(
        self: *const ChangeGraph,
        other: *const ChangeGraph,
        gpa: Allocator,
        their_heads: []const ChangeHash,
    ) Error![]ChangeHash {
        var seen: HashSet = .empty;
        defer seen.deinit(gpa);
        var out: std.ArrayList(ChangeHash) = .empty;
        errdefer out.deinit(gpa);
        var stack: std.ArrayList(ChangeHash) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, their_heads);

        while (stack.pop()) |hash| {
            if (self.by_hash.contains(hash)) continue;
            if (seen.contains(hash)) continue;
            try seen.put(gpa, hash, {});
            try out.append(gpa, hash);
            var it = other.depsForHash(hash);
            while (it.next()) |dep| try stack.append(gpa, other.indexToHash(dep).?);
        }
        std.mem.reverse(ChangeHash, out.items);
        return out.toOwnedSlice(gpa);
    }

    /// The first hash on each path back from `start` that this graph does not
    /// have (`missing_deps_from`, `automerge.rs:2037-2066`).
    ///
    /// A hash the graph holds contributes its own dependencies, which are
    /// therefore covered as well, so only absent hashes can be missing.
    /// `pending` lets the walk continue *through* changes the caller has
    /// received but not applied: the change queue is what a sync waits on, and
    /// upstream chains the queue in front of the heads
    /// (`automerge.rs:2289-2292`). With no pending changes this is the heads
    /// the graph does not have, deduplicated and sorted.
    ///
    /// The result is owned by the caller.
    pub fn missingDepsFrom(
        self: *const ChangeGraph,
        gpa: Allocator,
        start: []const ChangeHash,
        pending: []const PendingChange,
    ) Error![]ChangeHash {
        var seen: HashSet = .empty;
        defer seen.deinit(gpa);
        var missing: std.ArrayList(ChangeHash) = .empty;
        errdefer missing.deinit(gpa);
        var stack: std.ArrayList(ChangeHash) = .empty;
        defer stack.deinit(gpa);
        try stack.appendSlice(gpa, start);

        while (stack.pop()) |hash| {
            if (self.by_hash.contains(hash)) continue;
            if (seen.contains(hash)) continue;
            try seen.put(gpa, hash, {});
            if (findPending(pending, hash)) |p| {
                try stack.appendSlice(gpa, p.deps);
                continue;
            }
            try missing.append(gpa, hash);
        }
        std.mem.sort(ChangeHash, missing.items, {}, hashLessThan);
        return missing.toOwnedSlice(gpa);
    }

    /// The changes of `heads` this graph does not have, with no pending
    /// changes to walk through: the graph's share of
    /// `ReadDoc::get_missing_deps`.
    pub fn getMissingDeps(
        self: *const ChangeGraph,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error![]ChangeHash {
        return self.missingDepsFrom(gpa, heads, &.{});
    }

    /// The changes in `candidates` that `heads` does not already depend on
    /// (`remove_ancestors`, `change_graph.rs:855-881`, reached from
    /// `Automerge::filter_changes`, `automerge.rs:1203-1220`).
    ///
    /// Upstream prunes a `BTreeSet` in place; here the result is a new owned
    /// slice in the caller's order, so the input needs no ordering and is not
    /// modified. A head the graph does not have is dropped, as upstream filters
    /// it out first (`automerge.rs:1213-1215`).
    pub fn filterChanges(
        self: *ChangeGraph,
        gpa: Allocator,
        candidates: []const ChangeHash,
        heads: []const ChangeHash,
    ) Error![]ChangeHash {
        const stamp = self.nextStamp();
        var stack: std.ArrayList(NodeIdx) = .empty;
        defer stack.deinit(gpa);
        for (heads) |hash| {
            if (self.by_hash.get(hash)) |idx| try stack.append(gpa, idx);
        }
        while (stack.pop()) |idx| {
            if (self.isVisited(idx, stamp)) continue;
            self.markVisited(idx, stamp);
            var it = self.parents(idx);
            while (it.next()) |parent| try stack.append(gpa, parent);
        }

        var out: std.ArrayList(ChangeHash) = .empty;
        errdefer out.deinit(gpa);
        for (candidates) |hash| {
            const idx = self.by_hash.get(hash) orelse {
                // Not a change of this graph, so not an ancestor of anything
                // here: it survives.
                try out.append(gpa, hash);
                continue;
            };
            if (self.isVisited(idx, stamp)) continue;
            try out.append(gpa, hash);
        }
        return out.toOwnedSlice(gpa);
    }

    /// The changes that were the heads when the document was at `heads`: the
    /// changes `heads` covers that no *covered* change depends on.
    ///
    /// There is no upstream function for this. Upstream's `historical_heads` is
    /// a local in `commit_transaction` that captures the transaction's
    /// dependencies when the transaction is scoped (`transaction.rs:24`), and
    /// the closest thing in the graph is `heads_are_current`. The reverse walk
    /// it would need is why this graph keeps the parent -> child edges: with
    /// them the answer is one pass over the nodes, and it is the exact head set
    /// of the document at that point in history, which is what a fork or a
    /// diff wants.
    ///
    /// A head the graph does not have is dropped, as in `clockAt`.
    pub fn historicalHeadsAt(
        self: *ChangeGraph,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error![]ChangeHash {
        var clock = try self.seqClockForHeads(gpa, heads);
        defer clock.deinit();

        // A covered node is a historical head unless one of its children is
        // also covered, so mark the covered nodes that have a covered child.
        const stamp = self.nextStamp();
        for (self.nodes.items, 0..) |node, i| {
            if (!isCovered(clock, node)) continue;
            var it = self.nodeChildren(node);
            while (it.next()) |child| {
                if (!isCovered(clock, self.nodes.items[child])) continue;
                self.markVisited(@intCast(i), stamp);
                break;
            }
        }

        var out: std.ArrayList(ChangeHash) = .empty;
        errdefer out.deinit(gpa);
        for (self.nodes.items, 0..) |node, i| {
            if (!isCovered(clock, node)) continue;
            if (self.isVisited(@intCast(i), stamp)) continue;
            try out.append(gpa, node.meta.hash);
        }
        std.mem.sort(ChangeHash, out.items, {}, hashLessThan);
        return out.toOwnedSlice(gpa);
    }

    /// Node `idx`'s dependencies, in the order the change listed them
    /// (`parents`, `change_graph.rs:774-782`).
    pub fn parents(self: *const ChangeGraph, idx: NodeIdx) NodeIter {
        const node = self.nodeAt(idx) orelse return emptyIter();
        return .{ .edges = self.parent_edges.items, .edge = node.parents };
    }

    /// The changes that depend on node `idx`, most recently added first. A new
    /// child goes to the head of the list, so no per-node tail is needed; the
    /// order carries no meaning here, unlike the dependency list, which is
    /// walked in the order the change wrote it.
    pub fn children(self: *const ChangeGraph, idx: NodeIdx) NodeIter {
        const node = self.nodeAt(idx) orelse return emptyIter();
        return .{ .edges = self.child_edges.items, .edge = node.children };
    }

    /// `hash`'s dependencies, as node indices (`deps_for_hash`,
    /// `change_graph.rs:322-331`). Empty when the graph does not have `hash`.
    pub fn depsForHash(self: *const ChangeGraph, hash: ChangeHash) NodeIter {
        const idx = self.by_hash.get(hash) orelse return emptyIter();
        return self.parents(idx);
    }

    /// The change that owns the operation `id`, or null when no change in the
    /// graph does (`opid_to_hash`, `change_graph.rs:300-320`).
    ///
    /// A change owns the counters in `[start_op, max_op]`. Upstream binary
    /// searches the actor's changes for the interval containing the counter,
    /// which is the same as searching for the last change that starts at or
    /// below it. A counter inside no change's interval belongs to no change:
    /// that is the gap an empty change leaves, and the counters below an
    /// actor's first change.
    pub fn opidToHash(self: *const ChangeGraph, id: OpId) ?ChangeHash {
        const list = self.actorChanges(id.actor) orelse return null;
        // The last change whose start_op is at or below the counter.
        var lo: usize = 0;
        var hi: usize = list.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const node = self.nodes.items[list.items[mid]];
            if (node.meta.start_op <= id.counter) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const node = self.nodes.items[list.items[lo - 1]];
        if (id.counter > node.meta.max_op) return null;
        return node.meta.hash;
    }

    /// Grows the graph to hold `count` actor slots, inserting empty slots in
    /// the middle where an actor sorted before an existing one.
    ///
    /// Every stored actor index at or above the insertion point shifts up by
    /// one, and every cached clock has to shift with them, because a
    /// `SeqClock` is indexed by actor (`insert_actor`,
    /// `change_graph.rs:151-167`).
    ///
    /// `addChange` does this for itself when it interns an actor the table did
    /// not have. A caller that interns an actor without adding a change — a
    /// transaction that has an actor index but has not committed yet — must
    /// call this, or the graph's clocks stay shorter than the document's actor
    /// table and `Clock.covers` refuses to compare them.
    pub fn insertActor(self: *ChangeGraph, gpa: Allocator, idx: ActorIdx) Error!void {
        const at: usize = idx;
        if (at > self.seq_index.items.len) return error.InvalidIndex;
        for (self.nodes.items) |*node| {
            if (node.actor >= idx) node.actor += 1;
        }
        for (self.clock_cache.items) |*entry| try entry.clock.rewriteWithNewActor(idx);
        try self.seq_index.insert(gpa, at, .empty);
    }

    /// Removes the actor slot at `idx`, shifting every higher index down and
    /// dropping the slot from every cached clock (`remove_actor`,
    /// `change_graph.rs:169-186`).
    ///
    /// The actor must have no changes in the graph. Upstream asserts it
    /// (`change_graph.rs:175-177`) and panics, because an actor whose changes
    /// are still here would have them retarget another actor. A rollback of a
    /// first change is the only caller that should ever get here, and it passes
    /// an actor the graph has just emptied.
    pub fn removeActor(self: *ChangeGraph, idx: ActorIdx) Error!void {
        const at: usize = idx;
        if (at >= self.seq_index.items.len) return error.InvalidIndex;
        if (self.seq_index.items[at].items.len != 0) return error.InvalidIndex;
        for (self.nodes.items) |*node| {
            if (node.actor > idx) node.actor -= 1;
        }
        for (self.clock_cache.items) |*entry| entry.clock.removeActor(idx);
        var list = self.seq_index.orderedRemove(at);
        list.deinit(self.gpa);
    }

    /// Interns the author and every referenced actor of `meta`, applying the
    /// actor table's remap to everything the graph stores whenever the table
    /// grows, and catching up with actors interned by someone else.
    fn internActors(
        self: *ChangeGraph,
        gpa: Allocator,
        authors: *Authors,
        meta: ChangeMetadata,
    ) Error!ActorIdx {
        const before = authors.count();
        _ = try authors.intern(gpa, meta.actor);
        if (authors.count() != before) try self.applyActorInsert(gpa, authors);

        for (meta.other_actors) |other| {
            const count = authors.count();
            _ = try authors.intern(gpa, other);
            if (authors.count() != count) try self.applyActorInsert(gpa, authors);
        }

        if (self.seq_index.items.len < authors.count()) {
            try self.growActorSlots(gpa, authors.count());
        }
        // Read the author's index last: a later actor may have sorted before
        // it and shifted it up, and every shift above has already been applied
        // to the nodes the graph holds.
        return authors.lookup(meta.actor).?;
    }

    /// Applies the remap the actor table just produced: every stored actor
    /// index moves, every cached clock shifts, and an empty slot appears for
    /// the actor that was inserted. This is the only thing that can invalidate
    /// a cached clock, and it has to happen in the same breath as the
    /// insertion.
    fn applyActorInsert(self: *ChangeGraph, gpa: Allocator, authors: *const Authors) Error!void {
        const remap = authors.remap();
        // An insertion writes one entry per old actor plus one for the actor it
        // inserted, which is the last.
        const inserted: ActorIdx = remap[remap.len - 1];
        for (self.nodes.items) |*node| node.actor = remap[node.actor];
        for (self.clock_cache.items) |*entry| try entry.clock.rewriteWithNewActor(inserted);
        try self.seq_index.insert(gpa, inserted, .empty);
    }

    /// Appends empty actor slots up to `count`, growing the cached clocks to
    /// match.
    fn growActorSlots(self: *ChangeGraph, gpa: Allocator, count: usize) Error!void {
        while (self.seq_index.items.len < count) try self.seq_index.append(gpa, .empty);
        for (self.clock_cache.items) |*entry| try entry.clock.ensureSize(count);
    }

    /// Links a validated change into the graph. Every fallible step happens
    /// first, so a failure here leaves the graph exactly as it was.
    fn pushNode(
        self: *ChangeGraph,
        gpa: Allocator,
        meta: ChangeMetadata,
        actor: ActorIdx,
    ) Error!NodeIdx {
        if (self.nodes.items.len >= max_node_count) return error.Fail;
        // Re-checked here so the loops below cannot fail: `addChange` proved
        // it, and this is where the proof is used.
        for (meta.deps) |dep| {
            if (!self.by_hash.contains(dep)) return error.MissingDeps;
        }

        var owned = try meta.intoOwned(gpa);
        errdefer owned.deinit(gpa);

        try self.nodes.ensureUnusedCapacity(gpa, 1);
        try self.by_hash.ensureUnusedCapacity(gpa, 1);
        try self.visit_stamp.ensureUnusedCapacity(gpa, 1);
        try self.seq_index.items[actor].ensureUnusedCapacity(gpa, 1);
        try self.heads.ensureUnusedCapacity(gpa, 1);
        try self.parent_edges.ensureUnusedCapacity(gpa, meta.deps.len);
        try self.child_edges.ensureUnusedCapacity(gpa, meta.deps.len);

        // From here nothing can fail.
        const idx: NodeIdx = @intCast(self.nodes.items.len);

        // The dependency edges hang off the new node, and every dependency is
        // already in the graph, so every parent index is below `idx`. Each
        // list is built in the order the change named its dependencies, the
        // way `add_parent` appends to the tail of the child's list upstream
        // (`change_graph.rs:754-763`), so a walk yields the dependencies in the
        // order the change wrote them.
        var parent_head: ?NodeIdx = null;
        var parent_tail: ?NodeIdx = null;
        for (owned.deps) |dep| {
            const parent = self.by_hash.get(dep).?;
            const at: NodeIdx = @intCast(self.parent_edges.items.len);
            self.parent_edges.appendAssumeCapacity(.{ .target = parent, .next = null });
            if (parent_tail) |tail| {
                self.parent_edges.items[tail].next = at;
            } else {
                parent_head = at;
            }
            parent_tail = at;
        }
        // The child edges are the same list seen from the other end: a
        // parent's children, in the order they were added.
        for (owned.deps) |dep| {
            const parent = self.by_hash.get(dep).?;
            const at: NodeIdx = @intCast(self.child_edges.items.len);
            const old_head = self.nodes.items[parent].children;
            self.child_edges.appendAssumeCapacity(.{ .target = idx, .next = old_head });
            self.nodes.items[parent].children = at;
        }

        self.nodes.appendAssumeCapacity(.{
            .meta = owned,
            .actor = actor,
            .parents = parent_head,
            .children = null,
        });
        self.by_hash.putAssumeCapacityNoClobber(owned.hash, idx);
        self.visit_stamp.appendAssumeCapacity(0);
        self.seq_index.items[actor].appendAssumeCapacity(idx);
        self.max_op = @max(self.max_op, owned.max_op);
        self.updateHeads(owned.hash, owned.deps);
        return idx;
    }

    /// Removes every dependency of the new change from the head set and puts
    /// the change in its place (`update_heads`, `change_graph.rs:513-518`). A
    /// dependency is removed whether or not it has other children, because it
    /// now has this one.
    ///
    /// The head set has room reserved by `pushNode`, so this cannot fail.
    fn updateHeads(self: *ChangeGraph, hash: ChangeHash, deps: []const ChangeHash) void {
        for (deps) |dep| {
            const at = hashSearch(self.heads.items, dep) orelse continue;
            _ = self.heads.orderedRemove(at);
        }
        self.heads.insertAssumeCapacity(hashInsertIndex(self.heads.items, hash), hash);
    }

    /// The child edges of `node`, as a node iterator.
    fn nodeChildren(self: *const ChangeGraph, node: Node) NodeIter {
        return .{ .edges = self.child_edges.items, .edge = node.children };
    }
};

/// A change the caller holds but has not added to the graph: one entry of the
/// change queue, reduced to what `missingDepsFrom` needs.
pub const PendingChange = struct {
    /// The change's hash.
    hash: ChangeHash,
    /// The changes it depends on.
    deps: []const ChangeHash,
};

/// The position `hash` occupies in a sorted hash list, or null when it is
/// already there. One binary search, used by the head set and by the
/// dependency walk.
fn hashSearch(items: []const ChangeHash, hash: ChangeHash) ?usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (ChangeHash.order(items[mid], hash)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return mid,
        }
    }
    return null;
}

/// The position `hash` would occupy in a sorted hash list.
fn hashInsertIndex(items: []const ChangeHash, hash: ChangeHash) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (ChangeHash.order(items[mid], hash)) {
            .lt => lo = mid + 1,
            .eq, .gt => hi = mid,
        }
    }
    return lo;
}

/// Total order over change hashes: the order the head set, and every list this
/// module returns hashes in, is in.
fn hashLessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
    return ChangeHash.order(a, b) == .lt;
}

/// The position `node` would occupy in a sorted node-index list.
fn nodeInsertIndex(items: []const NodeIdx, node: NodeIdx) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < node) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// The position `node` would occupy in the sorted clock cache.
fn cacheInsertIndex(items: []const ClockEntry, node: NodeIdx) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].node < node) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Inserts `node` into a sorted node-index list, keeping the list a set.
fn insertNodeIdxSorted(
    list: *std.ArrayList(NodeIdx),
    gpa: Allocator,
    node: NodeIdx,
) Error!void {
    try list.insert(gpa, nodeInsertIndex(list.items, node), node);
}

/// True when `clock` covers `node`: the actor's sequence number has reached
/// this change's.
fn isCovered(clock: SeqClock, node: Node) bool {
    const seq = clock.get(node.actor) orelse return false;
    return @as(u64, seq) >= node.meta.seq;
}

/// The pending change with this hash, or null.
fn findPending(pending: []const PendingChange, hash: ChangeHash) ?PendingChange {
    for (pending) |p| {
        if (p.hash.eql(hash)) return p;
    }
    return null;
}

/// An iterator that has already ended.
fn emptyIter() NodeIter {
    return .{ .edges = &.{}, .edge = null };
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

/// Builds a graph change by change, interning actors as it goes. `base` gives
/// a builder its own hash space, so two builders can hold disjoint histories
/// and still share the changes they are given explicitly.
const Builder = struct {
    gpa: Allocator,
    authors: Authors,
    graph: ChangeGraph,
    base: u32,
    next: u32,

    fn init(gpa: Allocator) Builder {
        return initBase(gpa, 0);
    }

    fn initBase(gpa: Allocator, base: u32) Builder {
        return .{
            .gpa = gpa,
            .authors = Authors.init(gpa),
            .graph = ChangeGraph.init(gpa),
            .base = base,
            .next = 1,
        };
    }

    fn deinit(self: *Builder) void {
        self.graph.deinit();
        self.authors.deinit();
    }

    /// The hash the next change will be given.
    fn peek(self: *Builder) ChangeHash {
        return testHash(self.base + self.next);
    }

    /// Adds a change with the next sequence number for `actor`.
    fn change(
        self: *Builder,
        actor: []const u8,
        start_op: u64,
        num_ops: u64,
        deps: []const ChangeHash,
    ) Error!ChangeHash {
        return self.changeAt(self.peek(), actor, start_op, num_ops, deps);
    }

    /// `change` with the hash spelled out, for a change two documents share.
    fn changeAt(
        self: *Builder,
        hash: ChangeHash,
        actor: []const u8,
        start_op: u64,
        num_ops: u64,
        deps: []const ChangeHash,
    ) Error!ChangeHash {
        return self.changeFull(hash, actor, self.nextSeq(actor), start_op, num_ops, deps, &.{});
    }

    /// `changeAt` with the sequence number and the referenced actors spelled
    /// out.
    fn changeFull(
        self: *Builder,
        hash: ChangeHash,
        actor: []const u8,
        seq: u64,
        start_op: u64,
        num_ops: u64,
        deps: []const ChangeHash,
        others: []const ActorId,
    ) Error!ChangeHash {
        const meta: ChangeMetadata = .{
            .actor = .{ .bytes = actor },
            .deps = deps,
            .hash = hash,
            .time = 0,
            .message = "",
            .seq = seq,
            .start_op = start_op,
            .max_op = if (num_ops == 0) start_op - 1 else start_op + num_ops - 1,
            .other_actors = others,
        };
        self.next += 1;
        try self.graph.addChange(self.gpa, &self.authors, meta);
        return hash;
    }

    /// The sequence number the next change by `actor` must have. An actor the
    /// table has not seen is at zero, so its first change is number one.
    fn nextSeq(self: *Builder, actor: []const u8) u64 {
        const idx = self.authors.lookup(.{ .bytes = actor }) orelse return 1;
        return self.graph.seqForActor(idx) + 1;
    }

    /// `actor`'s index in the document's actor table, which the graph and the
    /// table agree on.
    fn indexOf(self: *Builder, actor: []const u8) ActorIdx {
        return self.authors.lookup(.{ .bytes = actor }).?;
    }
};

test "a linear history of three changes has one head at each step" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    try testing.expect(graph.isEmpty());

    const c1 = try b.change("a", 1, 1, &.{});
    try testing.expectEqual(@as(usize, 1), graph.len());
    try testing.expectEqualSlices(ChangeHash, &.{c1}, graph.getHeads());
    try testing.expect(graph.headsAreCurrent(&.{c1}));
    try testing.expect(!graph.headsAreCurrent(&.{}));
    try testing.expect(!graph.headsAreCurrent(&.{ c1, c1 }));

    const c2 = try b.change("a", 2, 1, &.{c1});
    try testing.expectEqualSlices(ChangeHash, &.{c2}, graph.getHeads());
    try testing.expect(graph.hasChange(c1));
    try testing.expect(!graph.headsAreCurrent(&.{c1}));

    const c3 = try b.change("a", 3, 1, &.{c2});
    try testing.expectEqualSlices(ChangeHash, &.{c3}, graph.getHeads());
    try testing.expectEqual(@as(u64, 3), graph.seqForActor(0));
    try testing.expectEqual(@as(u64, 3), graph.maxOp());

    // The incremental head set is the one the child edges describe.
    const recomputed = try graph.recomputeHeads(gpa);
    defer gpa.free(recomputed);
    try testing.expectEqualSlices(ChangeHash, graph.getHeads(), recomputed);

    // Dependencies walk back the way the history went, and children forward.
    var deps = graph.depsForHash(c3);
    try testing.expectEqual(graph.hashToIndex(c2).?, deps.next().?);
    try testing.expect(deps.next() == null);
    var kids = graph.children(graph.hashToIndex(c1).?);
    try testing.expectEqual(graph.hashToIndex(c2).?, kids.next().?);
    try testing.expect(kids.next() == null);
}

test "a fork of two concurrent changes has two heads, merging gives one" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("b", 2, 1, &.{c1});
    const c3 = try b.change("a", 3, 1, &.{c1});
    try testing.expectEqual(@as(usize, 2), graph.getHeads().len);
    try testing.expect(c2.eql(graph.indexToHash(1).?) and c3.eql(graph.indexToHash(2).?));
    // A fork's heads are its two ends, and nothing before them.
    try testing.expect(!graph.headsAreCurrent(&.{c1}));
    var fork = [_]ChangeHash{ c2, c3 };
    std.mem.sort(ChangeHash, &fork, {}, hashLessThan);
    try testing.expectEqualSlices(ChangeHash, &fork, graph.getHeads());

    // A change that depends on both ends the fork. Its dependencies are walked
    // in the order it named them, and each of them lists it as a child.
    const c4 = try b.change("b", 4, 1, &.{ c2, c3 });
    try testing.expectEqualSlices(ChangeHash, &.{c4}, graph.getHeads());
    try testing.expectEqual(@as(usize, 2), graph.seqForActor(1));
    try testing.expectEqual(@as(u64, 2), graph.seqForActor(0));
    try testing.expectEqual(@as(usize, 4), graph.len());

    var merge_deps = graph.depsForHash(c4);
    try testing.expectEqual(graph.hashToIndex(c2).?, merge_deps.next().?);
    try testing.expectEqual(graph.hashToIndex(c3).?, merge_deps.next().?);
    try testing.expect(merge_deps.next() == null);
    // c1 is the parent of both ends of the fork, listed most recent first.
    var fork_kids = graph.children(graph.hashToIndex(c1).?);
    try testing.expectEqual(graph.hashToIndex(c3).?, fork_kids.next().?);
    try testing.expectEqual(graph.hashToIndex(c2).?, fork_kids.next().?);
    try testing.expect(fork_kids.next() == null);
    var kids = graph.children(graph.hashToIndex(c2).?);
    try testing.expectEqual(graph.hashToIndex(c4).?, kids.next().?);
    try testing.expect(kids.next() == null);
}

test "getMissingDeps reports the hashes the graph does not have" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("a", 2, 1, &.{c1});

    // Everything the graph holds is not missing.
    const none = try graph.getMissingDeps(gpa, &.{ c1, c2 });
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // An unknown hash is missing, and is reported once however often it is
    // named. A hash this graph holds contributes nothing: its dependencies
    // are in the graph too.
    const unknown = testHash(0xfeed);
    const missing = try graph.getMissingDeps(gpa, &.{ unknown, c2, unknown });
    defer gpa.free(missing);
    try testing.expectEqualSlices(ChangeHash, &.{unknown}, missing);

    // Two unknown hashes come back in hash order.
    const later = testHash(0xbeef);
    const both = try graph.getMissingDeps(gpa, &.{ later, unknown });
    defer gpa.free(both);
    try testing.expectEqualSlices(ChangeHash, &.{ unknown, later }, both);
}

test "a change with a missing dependency is rejected and names it" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const absent = testHash(0xabc);

    const refused: ChangeMetadata = .{
        .actor = .{ .bytes = "a" },
        .deps = &.{ c1, absent },
        .hash = testHash(99),
        .time = 0,
        .message = "",
        .seq = 2,
        .start_op = 2,
        .max_op = 2,
        .other_actors = &.{},
    };
    try testing.expect(absent.eql(graph.firstMissingDep(refused).?));
    try testing.expectError(error.MissingDeps, graph.addChange(gpa, &b.authors, refused));

    // Nothing about the graph moved.
    try testing.expectEqual(@as(usize, 1), graph.len());
    try testing.expectEqualSlices(ChangeHash, &.{c1}, graph.getHeads());
    try testing.expect(!graph.hasChange(absent));
    try testing.expect(!graph.hasChange(refused.hash));

    // A change that depends on itself is refused for the same reason.
    const selfish: ChangeMetadata = .{
        .actor = refused.actor,
        .deps = &.{refused.hash},
        .hash = refused.hash,
        .time = 0,
        .message = "",
        .seq = 2,
        .start_op = 3,
        .max_op = 3,
        .other_actors = &.{},
    };
    try testing.expectError(error.MissingDeps, graph.addChange(gpa, &b.authors, selfish));
    try testing.expectEqual(@as(usize, 1), graph.len());
}

test "a repeated sequence number for one actor is rejected" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("a", 2, 1, &.{c1});
    try testing.expectEqual(@as(u64, 2), graph.seqForActor(0));

    // Sequence 1 again, for an actor that is already at 2.
    try testing.expectError(error.DuplicateSeqNumber, b.changeFull(b.peek(), "a", 1, 5, 1, &.{c2}, &.{}));
    // Sequence 4 skips 3: the change is well formed, the history is not.
    try testing.expectError(error.InvalidSeq, b.changeFull(b.peek(), "a", 4, 7, 1, &.{c2}, &.{}));
    // Zero is not a sequence number.
    try testing.expectError(error.InvalidSeq, b.changeFull(b.peek(), "a", 0, 7, 1, &.{c2}, &.{}));
    try testing.expectEqual(@as(usize, 2), graph.len());

    // Another actor has its own sequence space, and its own first change may
    // start at any counter.
    const d1 = try b.change("b", 50, 1, &.{c2});
    const b_idx = b.indexOf("b");
    try testing.expectEqual(@as(u64, 1), graph.seqForActor(b_idx));
    try testing.expectEqual(d1, try graph.hashForActorSeq(b_idx, 1));
    try testing.expectError(error.InvalidSeq, graph.hashForActorSeq(b_idx, 2));
    try testing.expectError(error.InvalidSeq, graph.hashForActorSeq(b_idx, 0));
    try testing.expectEqual(@as(u64, 50), graph.maxOpForActor(b_idx));

    // Adding a change the graph already holds is a no-op, not a duplicate.
    try graph.addChange(gpa, &b.authors, graph.nodeFor(c1).?.meta);
    try testing.expectEqual(@as(usize, 3), graph.len());
}

test "clockAt reports per-actor op counters and merges its parents' clocks" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // The shape of upstream's `clock_by_heads` test (`change_graph.rs:1072-1092`):
    // a1 -> a2 and a1 -> a3, then a1 again depending on both.
    const c1 = try b.change("a1", 1, 10, &.{});
    const c2 = try b.change("a2", 11, 10, &.{c1});
    const c3 = try b.change("a3", 11, 10, &.{c1});
    const c4 = try b.change("a1", 21, 10, &.{ c2, c3 });

    const a1 = b.indexOf("a1");
    const a2 = b.indexOf("a2");
    const a3 = b.indexOf("a3");

    // The sequence clock counts changes: a1 twice, the others once.
    var seq_clock = try graph.seqClockForHeads(gpa, &.{c4});
    defer seq_clock.deinit();
    try testing.expectEqual(@as(?u32, 2), seq_clock.get(a1));
    try testing.expectEqual(@as(?u32, 1), seq_clock.get(a2));
    try testing.expectEqual(@as(?u32, 1), seq_clock.get(a3));

    // The op clock counts counters, which is not the same number: a1 has seen
    // its own second change up to counter 30, the other two up to 20.
    var at_merge = try graph.clockAt(gpa, &.{c4});
    defer at_merge.deinit();
    try testing.expectEqualSlices(u32, &.{ 30, 20, 20 }, at_merge.values());

    var at_c2 = try graph.clockAt(gpa, &.{c2});
    defer at_c2.deinit();
    var at_c3 = try graph.clockAt(gpa, &.{c3});
    defer at_c3.deinit();
    try testing.expectEqualSlices(u32, &.{ 10, 20, 0 }, at_c2.values());
    try testing.expectEqualSlices(u32, &.{ 10, 0, 20 }, at_c3.values());

    // The clock at the merge is its parents' clocks merged, plus the merge
    // change's own entry.
    var merged = try at_c2.clone();
    defer merged.deinit();
    merged.merge(at_c3);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 20 }, merged.values());
    try testing.expect(merged.include(a1, 30));
    try testing.expectEqualSlices(u32, at_merge.values(), merged.values());

    // The first change alone.
    var at_c1 = try graph.clockAt(gpa, &.{c1});
    defer at_c1.deinit();
    try testing.expectEqualSlices(u32, &.{ 10, 0, 0 }, at_c1.values());

    // An unknown head is dropped, as upstream's `filter_map` drops it, and a
    // clock of nothing is all zeroes.
    var at_unknown = try graph.clockAt(gpa, &.{testHash(0xdead)});
    defer at_unknown.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, at_unknown.values());
}

test "a cached clock is rewritten when a later change inserts an actor" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Twenty changes by one actor: node 15 is the first cache point, one entry
    // per sixteen nodes, and every walk from the tip runs into it.
    var hashes: [20]ChangeHash = undefined;
    for (&hashes, 0..) |*slot, i| {
        slot.* = try b.change("b", @intCast(i + 1), 1, if (i == 0) &.{} else hashes[i - 1 .. i].ptr[0..1]);
    }
    try testing.expectEqual(@as(usize, 1), graph.cachedClockCount());

    var at_tip = try graph.clockAt(gpa, &.{hashes[19]});
    defer at_tip.deinit();
    try testing.expectEqualSlices(u32, &.{20}, at_tip.values());

    // "a" sorts before "b", so the actor that was index 0 becomes index 1 and
    // the cached clock has to shift with it. The new change's counter is 5,
    // below the 16 the cached clock holds for the old index 0, so a cache that
    // was not rewritten answers 16 there instead of 5.
    const forked = try b.change("a", 5, 1, &.{hashes[19]});
    try testing.expectEqual(@as(usize, 2), graph.numActors());
    try testing.expectEqual(@as(ActorIdx, 1), graph.nodeFor(hashes[0]).?.actor);
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(forked).?.actor);

    var at_fork = try graph.clockAt(gpa, &.{forked});
    defer at_fork.deinit();
    try testing.expectEqualSlices(u32, &.{ 5, 20 }, at_fork.values());

    var seq_fork = try graph.seqClockForHeads(gpa, &.{forked});
    defer seq_fork.deinit();
    try testing.expectEqual(@as(?u32, 1), seq_fork.get(0));
    try testing.expectEqual(@as(?u32, 20), seq_fork.get(1));

    // The old tip is unchanged by the child that was added to it.
    var at_tip_again = try graph.clockAt(gpa, &.{hashes[19]});
    defer at_tip_again.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 20 }, at_tip_again.values());
}

test "the clock cache holds one clock every sixteen nodes" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Thirty changes by "a", then one by "b", then two more by "a". Nodes 15
    // and 31 are the cache points, and the clock at node 31 covers both
    // actors, so a walk that stops there takes "b" from the cache.
    var hashes: [33]ChangeHash = undefined;
    for (hashes[0..30], 0..) |*slot, i| {
        slot.* = try b.change("a", @intCast(i + 1), 1, if (i == 0) &.{} else hashes[i - 1 .. i].ptr[0..1]);
    }
    hashes[30] = try b.change("b", 1, 1, &.{hashes[29]});
    hashes[31] = try b.change("a", 17, 1, &.{hashes[30]});
    hashes[32] = try b.change("a", 18, 1, &.{hashes[31]});
    try testing.expectEqual(@as(usize, 2), graph.cachedClockCount());

    var at_cache_point = try graph.clockAt(gpa, &.{hashes[31]});
    defer at_cache_point.deinit();
    try testing.expectEqualSlices(u32, &.{ 17, 1 }, at_cache_point.values());

    // The tip reads that cache entry on the way down.
    var at_tip = try graph.clockAt(gpa, &.{hashes[32]});
    defer at_tip.deinit();
    try testing.expectEqualSlices(u32, &.{ 18, 1 }, at_tip.values());

    // A caller that interns an actor of its own grows the graph too, and the
    // cached clocks shift with the actor indices.
    try graph.insertActor(gpa, 0);
    try testing.expectEqual(@as(usize, 2), graph.cachedClockCount());
    var after_insert = try graph.clockAt(gpa, &.{hashes[32]});
    defer after_insert.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 18, 1 }, after_insert.values());
}

test "interning an actor that sorts first keeps every stored index correct" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const by_z = try b.change("z", 30, 1, &.{});
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(by_z).?.actor);
    const by_z2 = try b.change("z", 31, 1, &.{by_z});
    try testing.expectEqual(@as(u64, 2), graph.seqForActor(0));

    // "a" sorts before "z": the table grows in the middle and both old nodes
    // have to move with it.
    const by_a = try b.change("a", 40, 1, &.{by_z2});
    try testing.expectEqualStrings("a", (b.authors.at(0).?).bytes);
    try testing.expectEqualStrings("z", (b.authors.at(1).?).bytes);
    try testing.expectEqual(@as(ActorIdx, 1), graph.nodeFor(by_z).?.actor);
    try testing.expectEqual(@as(ActorIdx, 1), graph.nodeFor(by_z2).?.actor);
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(by_a).?.actor);
    try testing.expectEqual(@as(u64, 2), graph.seqForActor(1));
    try testing.expectEqual(@as(u64, 1), graph.seqForActor(0));
    try testing.expectEqual(@as(u64, 31), graph.maxOpForActor(1));
    try testing.expectEqual(@as(u64, 40), graph.maxOpForActor(0));

    // The clock follows the actors, not the slots they used to occupy.
    var clock = try graph.clockAt(gpa, &.{by_a});
    defer clock.deinit();
    try testing.expectEqualSlices(u32, &.{ 40, 31 }, clock.values());

    // An actor the change references but does not own is interned too, and one
    // that sorts before "c" and "z" moves both of them again. The table ends
    // up as a, b, c, z.
    const others = [_]ActorId{.{ .bytes = "b" }};
    const by_c = try b.changeFull(b.peek(), "c", 1, 50, 1, &.{by_a}, &others);
    try testing.expectEqual(@as(ActorIdx, 2), graph.nodeFor(by_c).?.actor);
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(by_a).?.actor);
    try testing.expectEqual(@as(ActorIdx, 3), graph.nodeFor(by_z2).?.actor);
    try testing.expectEqual(b.authors.lookup(.{ .bytes = "b" }).?, @as(ActorIdx, 1));
    try testing.expectEqual(@as(usize, 4), graph.numActors());
    try testing.expectEqual(@as(u64, 1), graph.seqForActor(0));
    try testing.expectEqual(@as(u64, 1), graph.seqForActor(2));
    try testing.expectEqual(@as(u64, 2), graph.seqForActor(3));

    var clock2 = try graph.clockAt(gpa, &.{by_c});
    defer clock2.deinit();
    try testing.expectEqualSlices(u32, &.{ 40, 0, 50, 31 }, clock2.values());
}

test "getChanges returns the changes a peer has not seen, parents first" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("b", 2, 1, &.{c1});
    const c3 = try b.change("a", 3, 1, &.{c1});
    const c4 = try b.change("b", 4, 1, &.{ c2, c3 });

    // Nothing known: every change, each dependency before what needs it.
    const all = try graph.getChanges(gpa, &.{});
    defer gpa.free(all);
    try testing.expectEqualSlices(ChangeHash, &.{ c1, c2, c3, c4 }, all);

    // A peer at c1 needs everything else.
    const after_c1 = try graph.getChanges(gpa, &.{c1});
    defer gpa.free(after_c1);
    try testing.expectEqualSlices(ChangeHash, &.{ c2, c3, c4 }, after_c1);

    // A peer at the two ends of the fork needs only the merge.
    const after_fork = try graph.getChanges(gpa, &.{ c2, c3 });
    defer gpa.free(after_fork);
    try testing.expectEqualSlices(ChangeHash, &.{c4}, after_fork);

    // A peer that is current needs nothing.
    const none = try graph.getChanges(gpa, graph.getHeads());
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "getChangesAdded walks the peer's graph past what we already have" {
    const gpa = testing.allocator;
    var ours = Builder.initBase(gpa, 0);
    defer ours.deinit();
    var theirs = Builder.initBase(gpa, 1000);
    defer theirs.deinit();

    const c1 = try ours.change("a", 1, 1, &.{});
    const c2 = try ours.change("a", 2, 1, &.{c1});
    const c3 = try ours.change("a", 3, 1, &.{c2});

    // The peer shares the first two changes and has two more of its own.
    _ = try theirs.changeAt(c1, "a", 1, 1, &.{});
    _ = try theirs.changeAt(c2, "a", 2, 1, &.{c1});
    const their_c2 = try theirs.change("b", 2, 1, &.{c1});
    const their_c3 = try theirs.change("b", 3, 1, &.{their_c2});

    const added = try ours.graph.getChangesAdded(&theirs.graph, gpa, theirs.graph.getHeads());
    defer gpa.free(added);
    try testing.expectEqualSlices(ChangeHash, &.{ their_c2, their_c3 }, added);

    // The peer merges our third change, so it holds everything we do and two
    // changes we have never seen.
    _ = try theirs.changeAt(c3, "a", 3, 1, &.{c2});
    const their_c4 = try theirs.change("c", 4, 1, &.{ their_c3, c3 });
    const more = try ours.graph.getChangesAdded(&theirs.graph, gpa, theirs.graph.getHeads());
    defer gpa.free(more);
    try testing.expectEqualSlices(ChangeHash, &.{ their_c2, their_c3, their_c4 }, more);

    // A document that holds all but the peer's last two changes gets exactly
    // those two, in dependency order.
    var b2 = Builder.initBase(gpa, 0);
    defer b2.deinit();
    _ = try b2.changeAt(c1, "a", 1, 1, &.{});
    _ = try b2.changeAt(c2, "a", 2, 1, &.{c1});
    _ = try b2.changeAt(c3, "a", 3, 1, &.{c2});
    _ = try b2.changeAt(their_c2, "b", 2, 1, &.{c1});
    const fewer = try b2.graph.getChangesAdded(&theirs.graph, gpa, theirs.graph.getHeads());
    defer gpa.free(fewer);
    try testing.expectEqualSlices(ChangeHash, &.{ their_c3, their_c4 }, fewer);
}

test "historicalHeadsAt reports the heads at that point in history" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("b", 2, 1, &.{c1});
    const c3 = try b.change("a", 3, 1, &.{c1});
    _ = try b.change("b", 4, 1, &.{ c2, c3 });

    // The heads of the current history are the heads of the current state.
    const now = try graph.historicalHeadsAt(gpa, graph.getHeads());
    defer gpa.free(now);
    try testing.expectEqualSlices(ChangeHash, graph.getHeads(), now);

    // At c1 the only head was c1: what came after it is not covered.
    const at_c1 = try graph.historicalHeadsAt(gpa, &.{c1});
    defer gpa.free(at_c1);
    try testing.expectEqualSlices(ChangeHash, &.{c1}, at_c1);

    // The fork had two heads, and c1 was not one of them: it is covered, but
    // two covered changes depend on it.
    const at_fork = try graph.historicalHeadsAt(gpa, &.{ c2, c3 });
    defer gpa.free(at_fork);
    var sorted = [_]ChangeHash{ c2, c3 };
    std.mem.sort(ChangeHash, &sorted, {}, hashLessThan);
    try testing.expectEqualSlices(ChangeHash, &sorted, at_fork);

    // At c2 alone, c3 was not written yet, so c2 was the only head.
    const at_c2 = try graph.historicalHeadsAt(gpa, &.{c2});
    defer gpa.free(at_c2);
    try testing.expectEqualSlices(ChangeHash, &.{c2}, at_c2);
}

test "insertActor and removeActor keep the per-actor slots in step" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    try testing.expectEqual(@as(usize, 1), graph.numActors());

    // An actor the caller interned without adding a change: the change that is
    // already here moves up a slot.
    try graph.insertActor(gpa, 0);
    try testing.expectEqual(@as(usize, 2), graph.numActors());
    try testing.expectEqual(@as(ActorIdx, 1), graph.nodeFor(c1).?.actor);
    var clock = try graph.clockAt(gpa, &.{c1});
    defer clock.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, clock.values());

    // An actor with changes cannot be dropped: its changes would retarget
    // whatever moved into its slot.
    try testing.expectError(error.InvalidIndex, graph.removeActor(1));
    try testing.expectError(error.InvalidIndex, graph.removeActor(5));

    // The empty slot goes away again and the indices close up.
    try graph.removeActor(0);
    try testing.expectEqual(@as(usize, 1), graph.numActors());
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(c1).?.actor);
    var clock2 = try graph.clockAt(gpa, &.{c1});
    defer clock2.deinit();
    try testing.expectEqualSlices(u32, &.{1}, clock2.values());
}

test "filterChanges drops what the heads already cover" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    const c1 = try b.change("a", 1, 1, &.{});
    const c2 = try b.change("b", 2, 1, &.{c1});
    const c3 = try b.change("a", 3, 1, &.{c1});
    const c4 = try b.change("b", 4, 1, &.{ c2, c3 });

    // A head covers itself and its ancestors, as upstream's `remove_ancestors`
    // does when it prunes the set the heads are looked up in.
    const candidates = [_]ChangeHash{ c1, c2, c3, c4 };
    const kept = try graph.filterChanges(gpa, &candidates, &.{c2});
    defer gpa.free(kept);
    try testing.expectEqualSlices(ChangeHash, &.{ c3, c4 }, kept);

    // A head the graph does not have covers nothing.
    const kept_all = try graph.filterChanges(gpa, &candidates, &.{testHash(0x99)});
    defer gpa.free(kept_all);
    try testing.expectEqualSlices(ChangeHash, &candidates, kept_all);
}

test "missingDepsFrom walks through changes the graph has not applied" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    _ = try b.change("a", 1, 1, &.{});
    // A queued change whose own dependency this document has not got: the
    // missing hash is the one behind it, not the queued change itself.
    const queued = testHash(0x1111);
    const wanted = testHash(0x2222);
    const pending = [_]PendingChange{.{ .hash = queued, .deps = &.{wanted} }};

    const missing = try graph.missingDepsFrom(gpa, &.{queued}, &pending);
    defer gpa.free(missing);
    try testing.expectEqualSlices(ChangeHash, &.{wanted}, missing);

    // Without the queue the walk stops at the queued change itself.
    const shallow = try graph.getMissingDeps(gpa, &.{queued});
    defer gpa.free(shallow);
    try testing.expectEqualSlices(ChangeHash, &.{queued}, shallow);
}

test "opidToHash finds the change that owns an operation" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Two changes of ten ops each, then an empty change, which is the gap a
    // committed transaction with no operations leaves.
    const c1 = try b.change("a", 1, 10, &.{});
    const c2 = try b.change("a", 11, 10, &.{c1});
    const c3 = try b.change("a", 31, 0, &.{c2});
    const a = b.indexOf("a");

    try testing.expectEqual(c1, graph.opidToHash(.{ .counter = 1, .actor = a }).?);
    try testing.expectEqual(c1, graph.opidToHash(.{ .counter = 10, .actor = a }).?);
    try testing.expectEqual(c2, graph.opidToHash(.{ .counter = 11, .actor = a }).?);
    try testing.expectEqual(c2, graph.opidToHash(.{ .counter = 20, .actor = a }).?);
    // The empty change owns no counter, so 21 to 30 belong to no change.
    try testing.expect(graph.opidToHash(.{ .counter = 21, .actor = a }) == null);
    try testing.expect(graph.opidToHash(.{ .counter = 30, .actor = a }) == null);
    // A counter below an actor's first change belongs to no change either.
    try testing.expect(graph.opidToHash(.{ .counter = 0, .actor = a }) == null);
    try testing.expect(graph.opidToHash(.{ .counter = 1, .actor = 7 }) == null);
    try testing.expect(c3.eql(graph.indexToHash(2).?));
}
