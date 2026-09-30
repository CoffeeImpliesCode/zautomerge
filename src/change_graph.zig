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
//! ancestors alone. A `SeqClock` is indexed by actor, so the *fragment*
//! clocks are rewritten with the rest: `fragment_top` and every
//! `FragmentNode.clock` (`change_graph.rs:162-165`, `:182-185`). Leaving one
//! of them behind does not make a fragment wrong, it makes the *next*
//! `cacheFragment` compare a folded clock against an actor that has since
//! moved, so a fragment that should have been superseded is not.
//!
//! ## Fragments
//!
//! A *fragment* is a section of the graph named by one change hash
//! ([`Fragment`](Fragment), `change_graph.rs:1763-1775`). Its **level** is
//! how many leading zero bytes that hash has
//! ([`ChangeHash.fragmentLevel`](types.zig):58-63), so a level is a property
//! of the hash and not a choice this graph makes: roughly one change in 256
//! is a fragment head, and a document of a thousand changes holds a handful.
//!
//! Two kinds of fragment exist and both are answered by the same two calls.
//! A **loose** fragment is a level-0 head on its own: one member, itself, and
//! a boundary of its change's own dependencies (`loose_commit`,
//! `change_graph.rs:598-612`). There is one for every level-0 head that no
//! cached fragment already covers. A **cached** fragment is a level-1-or-more
//! head together with the level-1-or-more heads it depends on, and its
//! members are everything between them (`FragmentNode::export`,
//! `change_graph.rs:1737-1760`). `getFragment` answers for any change hash
//! and `fragments` for a level range over a head set.
//!
//! The cache behind them is a **frontier**, not a partition. `fragment_top`
//! is the merge of every cached fragment's clock, so it names the deepest
//! point the cached frontier has reached, and a walk that meets it stops
//! there (`bfs_until_clock`, `change_graph.rs:650-675`): everything below it
//! is already a member of some cached fragment. A change may therefore be a
//! member of more than one fragment, and `fragments_cover_all_changes`
//! upstream says so (`change_graph.rs:1247`).
//!
//! A cached fragment **supersedes** the cached fragments it covers whose
//! level is lower than its own (`cache_fragment`, `change_graph.rs:692-703`):
//! the new one reaches at least as far, so the shallower one would name the
//! same changes again. They are dropped from the cache, which is why
//! `getFragment` on a *superseded* level-1 head is null, and why the cache is
//! not the set of every hash that was ever a fragment head.

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

/// The first edge count that does not fit in `NodeIdx`. An edge is
/// addressed by the same width a node is: upstream's edge index is a
/// `NonZeroU32` over the same 32 bits (`EdgeIdx`, `change_graph.rs:64-74`).
const max_edge_count: usize = std.math.maxInt(NodeIdx);

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

/// A cached fragment, kept as node indices rather than hashes
/// (`FragmentNode`, `change_graph.rs:1731-1735`).
///
/// `clock` is the fold over `deps` *including the deps themselves*, which is
/// what makes `members` stop just above the boundary: `fragmentContent` keeps
/// descending while `clock` does not already reach a node's sequence number,
/// so a dep is reached from `head` and never appears in `members` itself.
/// The clock is indexed by actor, so it moves with `insertActor` and
/// `removeActor` like `ChangeGraph.clock_cache` does.
const FragmentNode = struct {
    /// The node the fragment is named by. Its hash's level is non-zero:
    /// `cacheFragment` does not cache a level-0 head.
    head: NodeIdx,
    /// The heads of the cached fragments this one depends on, newest first.
    deps: []NodeIdx,
    /// The clock the fold over `deps` produced.
    clock: SeqClock,

    fn deinit(self: *FragmentNode, gpa: Allocator) void {
        gpa.free(self.deps);
        self.clock.deinit();
        self.* = undefined;
    }
};

/// The cache entries one added change leaves behind, with every allocation
/// already made.
///
/// Both are optional because the cache is sparse: the node clock is kept for
/// one node in [`cache_step`], and a fragment only for a hash with a
/// non-zero level. Neither is a half-built one, because the commit that
/// installs them ([`commitCache`](ChangeGraph.commitCache)) cannot fail.
const StagedCache = struct {
    /// The clock at the new change, when its index is a `cache_step` point.
    clock: ?SeqClock,
    /// The fragment the new change names, when its hash has a non-zero level.
    fragment: ?StagedFragment,

    fn deinit(self: *StagedCache, gpa: Allocator) void {
        if (self.clock) |*clock| clock.deinit();
        if (self.fragment) |*fragment| fragment.deinit(gpa);
        self.* = undefined;
    }
};

/// One new cached fragment, with the arrays and the clock it needs already
/// allocated (`FragmentNode`, `change_graph.rs:1731-1735`).
///
/// Staged against the cache as it was when the fragment was worked out, so
/// nothing here depends on a commit that has not happened yet.
const StagedFragment = struct {
    /// The heads of the cached fragments this one depends on, newest first.
    deps: []NodeIdx,
    /// The cache entries this one supersedes, in descending index order.
    /// Positions in the cache as it was, and the one array the cache does not
    /// keep: [`commitFragment`](ChangeGraph.commitFragment) frees this list
    /// as it walks it, because walking it is what consumes it.
    supersede: []usize,
    /// The clock the fold over `deps` produced.
    clock: SeqClock,

    fn deinit(self: *StagedFragment, gpa: Allocator) void {
        gpa.free(self.deps);
        gpa.free(self.supersede);
        self.clock.deinit();
        self.* = undefined;
    }
};

/// The queue `ChangeGraph.bfsUntilClock` walks (`bfs_until_clock`,
/// `change_graph.rs:650-675`).
///
/// A FIFO queue seeded with the start nodes, every one of which is marked
/// seen before the walk begins: a seed that is also reached later as a
/// dependency is still yielded exactly once, from its seed position. A node
/// is yielded *before* its parents are considered, so the order is
/// breadth-first from the seeds, and a parent is only queued when `clock`
/// does not already reach it.
///
/// The queue is read through `head` rather than popped from the front: a
/// `VecDeque` upstream, a growing list here, because removing element zero
/// once per node would make the walk quadratic in the number of changes.
const ClockBfs = struct {
    graph: *const ChangeGraph,
    /// The clock a node is already covered by. Read by value: it is a slice,
    /// a length and an allocator, and the graph owns the memory.
    clock: SeqClock,
    queue: std.ArrayList(NodeIdx),
    /// The next node to yield.
    head: usize,
    seen: std.AutoHashMapUnmanaged(NodeIdx, void),

    fn init(
        gpa: Allocator,
        graph: *const ChangeGraph,
        seed: []const NodeIdx,
        clock: SeqClock,
    ) Error!ClockBfs {
        var self: ClockBfs = .{
            .graph = graph,
            .clock = clock,
            .queue = .empty,
            .head = 0,
            .seen = .empty,
        };
        errdefer self.deinit(gpa);
        try self.queue.appendSlice(gpa, seed);
        for (seed) |node| try self.seen.put(gpa, node, {});
        return self;
    }

    fn deinit(self: *ClockBfs, gpa: Allocator) void {
        self.queue.deinit(gpa);
        self.seen.deinit(gpa);
        self.* = undefined;
    }

    /// The next node of the walk, or null when there is none left.
    fn next(self: *ClockBfs, gpa: Allocator) Error!?NodeIdx {
        if (self.head >= self.queue.items.len) return null;
        const idx = self.queue.items[self.head];
        self.head += 1;
        var it = self.graph.parents(idx);
        while (it.next()) |parent| {
            if (self.seen.contains(parent)) continue;
            const node = self.graph.nodes.items[parent];
            // `get_for_actor(..) < NonZeroU32::new(seq)`: an actor the clock
            // has not heard of is at zero, and a sequence number is never
            // zero, so an unseen actor is covered by nothing.
            const have = self.clock.get(node.actor) orelse 0;
            if (have < node.meta.seq) {
                try self.seen.put(gpa, parent, {});
                try self.queue.append(gpa, parent);
            }
        }
        return idx;
    }
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

/// A section of the change graph identified by its head hash (`Fragment`,
/// `change_graph.rs:1763-1775`).
///
/// Every array is owned by the fragment and was allocated from the `gpa`
/// `getFragment` and `fragments` were given; `deinit` frees all three. A
/// caller that got a list of them frees it with
/// `deinitFragments`, which does the same for each one first.
pub const Fragment = struct {
    /// The change the fragment is named by. `level` is this hash's
    /// [`fragmentLevel`](types.zig):58-63.
    head: ChangeHash,
    /// How many leading zero bytes `head` has. Fragments are grouped and
    /// filtered by it, and it is a property of the hash rather than a choice
    /// this graph makes.
    level: usize,
    /// What the fragment stands on: for a cached fragment the heads of the
    /// cached fragments its clock covers, and for a loose one the change's
    /// own dependencies. Never contains `head`.
    boundary: []ChangeHash,
    /// The non-zero-level members of the fragment other than `head`, in
    /// `members` order. A change that is a boundary and not a member is not
    /// a checkpoint either, which is what keeps a fragment and what it
    /// depends on disjoint.
    checkpoints: []ChangeHash,
    /// The changes the fragment covers, newest first, in the breadth-first
    /// order `fragmentContent` walks them in.
    members: []ChangeHash,

    /// Frees the three owned arrays. The hashes themselves are the graph's.
    pub fn deinit(self: *Fragment, gpa: Allocator) void {
        gpa.free(self.boundary);
        gpa.free(self.checkpoints);
        gpa.free(self.members);
        self.* = undefined;
    }
};

/// Which fragment levels a query covers: the half-open range
/// `[start, end)`, with an absent `end` meaning no upper bound
/// (`RangeBounds<usize>`, `change_graph.rs:614-627`).
///
/// The upstream spellings map over as `..` is `.{ .end = null }`, `0..=0`
/// is `.{ .start = 0, .end = 1 }`, `1..` is `.{ .start = 1 }` and the empty
/// `0..0` is `.{ .start = 0, .end = 0 }`. An inclusive range and a
/// half-open one cannot both be the spelling here, and half-open is the one
/// the rest of this port's ranges use.
pub const LevelRange = struct {
    /// The lowest level included, inclusive.
    start: usize = 0,
    /// The level one past the last included, exclusive; null for no bound.
    end: ?usize = null,

    /// True when `level` is in the range.
    pub fn contains(self: LevelRange, level: usize) bool {
        if (level < self.start) return false;
        const end = self.end orelse return true;
        return level < end;
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
    /// The clock of the deepest point the cached fragment frontier has
    /// reached: the merge of every `FragmentNode.clock`
    /// (`fragment_top`, `change_graph.rs:45`). A walk stops where this clock
    /// says the history is already covered, so it has one entry per actor
    /// slot and moves with the actors like every other clock in this struct.
    fragment_top: SeqClock,
    /// The cached fragments, sorted by head node so a lookup is a binary
    /// search. `cacheFragment` appends in node order and drops the entries it
    /// supersedes, so the order holds (`change_graph.rs:590`).
    fragment_cache: std.ArrayList(FragmentNode),
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
            .fragment_top = SeqClock.initEmpty(gpa),
            .fragment_cache = .empty,
            .max_op = 0,
            .stamp = 0,
            .visit_stamp = .empty,
        };
    }

    /// Releases every node's metadata, every edge, both caches and the
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
        for (self.fragment_cache.items) |*f| f.deinit(self.gpa);
        self.fragment_cache.deinit(self.gpa);
        self.fragment_top.deinit();
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
    /// one lookup. A change refused part-way through them may still have left
    /// the actors it had already interned in the table: the table is the
    /// document's, interning is monotone, and each of those internings brought
    /// its own slot with it, so what the table holds is what the graph has
    /// slots for.
    ///
    /// ## This is a second actor-insertion route, and it reaches two of five
    ///
    /// `OpSet.actors` is the authoritative table and every stored `ActorIdx`
    /// means an index into it. `authors`, `seq_index` and `Actor::Cached` are
    /// mirrors, and upstream fans one insertion out to all of them from a
    /// single site ([`Automerge::insert_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1301-1306).
    /// Upstream's graph has **no** second route: `add_change` is handed an
    /// `actor_index` its caller resolved against `ops.actors`
    /// (`binary_search(...).expect(...)`,
    /// [`automerge.rs:1290-1294`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// and it never interns. `seq_index` is sized from the actor count instead
    /// (`seq_index: vec![vec![]; num_actors]`,
    /// [`change_graph.rs:102`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
    ///
    /// **So an actor interned here reaches `authors` and `seq_index` and
    /// nothing else**, and if `authors` is behind `ops.actors` the remap
    /// `applyActorInsert` writes renumbers an actor that did not move — which
    /// is not a wrong number, it is a change attributed to another actor.
    /// [`Document.putActorRef`](doc.zig) is the fan-out and
    /// [`Document.adoptActorMirrors`](doc.zig) seeds both mirrors from the
    /// adopted table on the load path; **a caller that reaches here without
    /// having interned first has grown two mirrors alone.** The regression
    /// test is `test "a load sizes every actor index from the actor table, not
    /// from the changes"` (`doc.zig`).
    ///
    /// ## Nothing here is half-added
    ///
    /// Every fallible step is taken before the move it belongs to: the actor
    /// remap, the node, the head set and both cache entries are allocated
    /// before the first of them happens, and each of them is then a move that
    /// cannot fail. So a caller that retries the change gets the change it
    /// asked for, and a caller that does not is left with a document whose
    /// graph is whole — rather than with a change whose node is linked but
    /// whose cached clock and fragment were refused, which is a graph whose
    /// cached frontier stops short of its own history.
    ///
    /// **Whole is not always "as it was"**: the actors are interned one at a
    /// time, so a refusal between two of them leaves the first in the table —
    /// with the slot its renumbering needed, which is why every index above it
    /// moved and no answer changed which actor it was about. That is all a
    /// refusal leaves behind, and the actor table is the one part of it that
    /// takes an ordering rather than an allocation to keep.
    ///
    /// Keeping it that way is the ordering, not an allocation: a new actor is
    /// not in the table until the graph has already reserved the slot it is
    /// going to need ([`internActors`](ChangeGraph.internActors)), so a refusal
    /// from the table itself leaves the graph's room reserved and no length
    /// moved. The order is the guarantee rather than a consequence of it:
    /// interning is idempotent, so a table that had grown without its slot
    /// could only be caught up by appending — right for an actor that sorts
    /// last, and every later index off by the shift — and a retry would skip
    /// the insertion altogether rather than make it.
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

        // The cache the change leaves behind is folded and allocated before
        // the change is linked rather than after. Both entries are the fold
        // over the cone at this change, and that fold is the one thing the
        // commit needs a graph to compute — which is what `pendingConeClock`
        // answers without linking anything.
        var staged = try self.stageCache(gpa, meta, actor);
        errdefer staged.deinit(gpa);

        const idx = try self.pushNode(gpa, meta, actor);
        // From here nothing can fail: `pushNode` had the room its own commit
        // needs, and `staged` holds every allocation the cache commit makes.
        self.commitCache(staged, idx);
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

    /// The cached clock for `node`, or null. The value borrows the cache.
    fn cachedClock(self: *const ChangeGraph, node: NodeIdx) ?SeqClock {
        const at = self.cacheIndex(node) orelse return null;
        return self.clock_cache.items[at].clock;
    }

    /// Stores the clock at `node` in the cache, replacing any entry for it
    /// (`cache_clock`, `change_graph.rs:729-743`).
    ///
    /// Infallible: the caller folded the clock first and reserved the room
    /// for one more entry with it.
    ///
    /// Upstream stops its walk after `2 * cache_step` nodes and finishes the
    /// job by recursing into the frontier, caching every node it meets on the
    /// way. [`pendingConeClock`](ChangeGraph.pendingConeClock) walks to the
    /// end of the cone instead. The clock is the same either way, and the
    /// walk is still short: the cache holds every sixteenth node, so it meets
    /// one within `cache_step` steps. The difference is that this needs no
    /// recursion, and a document with a million changes would give the
    /// recursive form a stack depth of tens of thousands of frames.
    fn commitCachedClock(self: *ChangeGraph, node: NodeIdx, clock: SeqClock) void {
        if (self.cacheIndex(node)) |at| {
            self.clock_cache.items[at].clock.deinit();
            self.clock_cache.items[at].clock = clock;
            return;
        }
        self.clock_cache.appendAssumeCapacity(.{ .node = node, .clock = clock });
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

    /// The fragment `head` names, or null (`get_fragment`,
    /// `change_graph.rs:585-596`).
    ///
    /// A level-0 hash is answered by `looseCommit` and a level-1-or-more one
    /// out of the cache, and both are the same answer the same call gives for
    /// a fragment that [`fragments`](ChangeGraph.fragments) returned. The null
    /// cases are the two upstream's `Option` has: a hash the graph does not
    /// have, and a level-1-or-more head that a deeper fragment has since
    /// superseded.
    pub fn getFragment(
        self: *const ChangeGraph,
        gpa: Allocator,
        head: ChangeHash,
    ) Error!?Fragment {
        const n = self.by_hash.get(head) orelse return null;
        if (head.fragmentLevel() == 0) return try self.looseCommit(gpa, n);
        const at = self.fragmentIndex(n) orelse return null;
        return try self.exportFragment(gpa, &self.fragment_cache.items[at]);
    }

    /// The fragments `heads` reaches, newest first (`fragments`,
    /// `change_graph.rs:614-627`).
    ///
    /// The order is the one the graph walks in and not one a caller has to
    /// sort: the loose fragments first, in breadth-first order out of the
    /// level-0 heads, then the cached fragments from the newest head to the
    /// oldest. `levels` picks which are in scope, and a range that excludes
    /// level 0 drops the loose ones entirely rather than computing and
    /// discarding them.
    ///
    /// A head the graph does not have is dropped, as upstream's `filter_map`
    /// drops it (`change_graph.rs:636`). The result is owned by the caller:
    /// free it with `deinitFragments`, which frees each fragment's own arrays
    /// before the list.
    pub fn fragments(
        self: *const ChangeGraph,
        gpa: Allocator,
        heads: []const ChangeHash,
        levels: LevelRange,
    ) Error![]Fragment {
        var out: std.ArrayList(Fragment) = .empty;
        errdefer deinitFragments(gpa, out.items);

        if (levels.contains(0)) try self.appendLooseFragments(gpa, heads, &out);

        var i = self.fragment_cache.items.len;
        while (i > 0) {
            i -= 1;
            const cached = &self.fragment_cache.items[i];
            const head = self.nodes.items[cached.head].meta.hash;
            if (!levels.contains(head.fragmentLevel())) continue;
            try out.append(gpa, try self.exportFragment(gpa, cached));
        }
        return out.toOwnedSlice(gpa);
    }

    /// The one-change fragment at a level-0 node (`loose_commit`,
    /// `change_graph.rs:598-612`).
    ///
    /// It is a change on its own: one member, which is the change itself, and
    /// a boundary of the dependencies the change wrote, in the order it wrote
    /// them. Upstream asserts the level is 0 and its only other failure is an
    /// index out of range, which cannot happen here because every caller has
    /// already filtered on `fragmentLevel` or on the cache.
    fn looseCommit(self: *const ChangeGraph, gpa: Allocator, n: NodeIdx) Error!Fragment {
        const head = self.nodes.items[n].meta.hash;
        var boundary: std.ArrayList(ChangeHash) = .empty;
        errdefer boundary.deinit(gpa);
        var it = self.parents(n);
        while (it.next()) |parent| try boundary.append(gpa, self.nodes.items[parent].meta.hash);
        const members = try gpa.alloc(ChangeHash, 1);
        errdefer gpa.free(members);
        members[0] = head;
        const owned_boundary = try boundary.toOwnedSlice(gpa);
        return .{
            .head = head,
            .level = head.fragmentLevel(),
            .boundary = owned_boundary,
            .checkpoints = try gpa.alloc(ChangeHash, 0),
            .members = members,
        };
    }

    /// Appends the loose fragments the level-0 heads of `heads` reach
    /// (`loose_fragments`, `change_graph.rs:629-639`).
    ///
    /// The walk is seeded with those heads and stops where `fragment_top`
    /// says the cached frontier already reaches, so a head that a cached
    /// fragment covers contributes nothing: the changes below it are that
    /// fragment's members, not loose fragments of their own.
    ///
    /// They go straight into the caller's list rather than through one of
    /// their own, because a fragment owns its three arrays and copying one
    /// into a list and then freeing the original would leave the copy
    /// pointing at freed memory.
    fn appendLooseFragments(
        self: *const ChangeGraph,
        gpa: Allocator,
        heads: []const ChangeHash,
        out: *std.ArrayList(Fragment),
    ) Error!void {
        var seed: std.ArrayList(NodeIdx) = .empty;
        defer seed.deinit(gpa);
        for (heads) |hash| {
            if (hash.fragmentLevel() != 0) continue;
            if (self.by_hash.get(hash)) |n| try seed.append(gpa, n);
        }
        var walk = try ClockBfs.init(gpa, self, seed.items, self.fragment_top);
        defer walk.deinit(gpa);
        while (try walk.next(gpa)) |n| {
            try out.append(gpa, try self.looseCommit(gpa, n));
        }
    }

    /// The changes a cached fragment covers (`fragment_content`,
    /// `change_graph.rs:641-648`): everything reachable from `node` that
    /// `clock` does not already reach, breadth-first and newest first.
    fn fragmentContent(
        self: *const ChangeGraph,
        gpa: Allocator,
        node: NodeIdx,
        clock: SeqClock,
    ) Error![]ChangeHash {
        var walk = try ClockBfs.init(gpa, self, &.{node}, clock);
        defer walk.deinit(gpa);
        var out: std.ArrayList(ChangeHash) = .empty;
        errdefer out.deinit(gpa);
        while (try walk.next(gpa)) |n| try out.append(gpa, self.nodes.items[n].meta.hash);
        return out.toOwnedSlice(gpa);
    }

    /// The hash-keyed form of the cache `getFragment` reads
    /// (`FragmentNode::export`, `change_graph.rs:1737-1760`).
    ///
    /// The clock is folded from `deps` and *includes* them, which is what
    /// keeps a boundary change out of the members: the walk stops just above
    /// the point `deps` reach. A member is a checkpoint when its hash has a
    /// non-zero level and it is not the head, so the head is excluded from
    /// its own checkpoints and a boundary that is not a member cannot be one.
    fn exportFragment(
        self: *const ChangeGraph,
        gpa: Allocator,
        cached: *const FragmentNode,
    ) Error!Fragment {
        const head = self.nodes.items[cached.head].meta.hash;
        var boundary: std.ArrayList(ChangeHash) = .empty;
        defer boundary.deinit(gpa);
        for (cached.deps) |dep| try boundary.append(gpa, self.nodes.items[dep].meta.hash);

        var clock = try self.mutable().calculateClock(gpa, cached.deps);
        defer clock.deinit();
        const members = try self.fragmentContent(gpa, cached.head, clock);
        errdefer gpa.free(members);

        var checkpoints: std.ArrayList(ChangeHash) = .empty;
        defer checkpoints.deinit(gpa);
        for (members) |member| {
            if (member.eql(head)) continue;
            if (member.fragmentLevel() == 0) continue;
            try checkpoints.append(gpa, member);
        }

        const owned_boundary = try boundary.toOwnedSlice(gpa);
        errdefer gpa.free(owned_boundary);
        const owned_checkpoints = try checkpoints.toOwnedSlice(gpa);
        return .{
            .head = head,
            .level = head.fragmentLevel(),
            .boundary = owned_boundary,
            .checkpoints = owned_checkpoints,
            .members = members,
        };
    }

    /// The position of `head`'s entry in the cache, or null. The list is
    /// sorted by node, which `cacheFragment` keeps it by appending in node
    /// order and dropping whole entries.
    fn fragmentIndex(self: *const ChangeGraph, head: NodeIdx) ?usize {
        var lo: usize = 0;
        var hi: usize = self.fragment_cache.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.fragment_cache.items[mid].head < head) lo = mid + 1 else hi = mid;
        }
        if (lo < self.fragment_cache.items.len and self.fragment_cache.items[lo].head == head) {
            return lo;
        }
        return null;
    }

    /// The graph as a mutable pointer, for the walks that mark the nodes they
    /// visit.
    ///
    /// Sound and narrow, and the same trade the rest of this file makes:
    /// `stamp` and `visit_stamp` are walk scratch and not graph state, which
    /// is what upstream gets from a local `BTreeSet` under an `&self`
    /// receiver (`change_graph.rs:833`). A fragment export reads the graph
    /// and only marks it, so the receiver stays `*const` and a caller holding
    /// a `*const Document` can ask for a fragment.
    fn mutable(self: *const ChangeGraph) *ChangeGraph {
        return @constCast(self);
    }

    /// Works out and allocates everything the cache needs for a change that is
    /// about to be linked, without touching the cache.
    ///
    /// Both entries are the fold over the cone at the new change, so that fold
    /// is computed once and shared; and both are optional, because the cache
    /// is sparse — the node clock is kept for one node in `cache_step`, and a
    /// fragment only for a hash with a non-zero level.
    fn stageCache(
        self: *ChangeGraph,
        gpa: Allocator,
        meta: ChangeMetadata,
        actor: ActorIdx,
    ) Error!StagedCache {
        const level = meta.hash.fragmentLevel();
        // The index the change is about to take, so whether it lands on a
        // cache point is known before it is linked.
        const cache_point = (self.nodes.items.len + 1) % cache_step == 0;
        if (level == 0 and !cache_point) return .{ .clock = null, .fragment = null };

        var cone = try self.pendingConeClock(gpa, actor, meta);
        defer cone.deinit();

        var staged: StagedCache = .{ .clock = null, .fragment = null };
        errdefer staged.deinit(gpa);
        if (cache_point) {
            try self.clock_cache.ensureUnusedCapacity(gpa, 1);
            staged.clock = try cone.clone();
        }
        if (level != 0) staged.fragment = try self.stageFragment(gpa, level, cone);
        return staged;
    }

    /// Puts the staged cache entries for the node at `idx` into the graph and
    /// takes ownership of them.
    ///
    /// Infallible: every array and every clock it moves was allocated by
    /// [`stageCache`](ChangeGraph.stageCache), and the room for one more entry
    /// in each list was reserved with it.
    fn commitCache(self: *ChangeGraph, staged: StagedCache, idx: NodeIdx) void {
        if (staged.clock) |clock| self.commitCachedClock(idx, clock);
        if (staged.fragment) |fragment| self.commitFragment(idx, fragment);
    }

    /// The clock of the cone at a change that is **not linked yet**: its own
    /// entry merged with the cones of the dependencies it named.
    ///
    /// This is the fold [`walkClock`](ChangeGraph.walkClock) performs from a
    /// node that *is* in the graph, taken one step earlier. A node contributes
    /// its own `(actor, seq)` and then the cones of its parents
    /// (`change_graph.rs:813-815`), and for a change that is not linked those
    /// parents are `meta.deps` — which `addChange` has already proved are all
    /// here. The seed is inserted sorted, so the walk takes the newest first
    /// exactly as it does over the parents it reaches itself.
    ///
    /// Folding before the commit is what lets `addChange` refuse an add
    /// without stranding the change: a walk that ran out of memory with the
    /// node already linked is a change whose cached frontier stops short of
    /// its own history, and nothing outside this file can tell that from a
    /// correct graph.
    fn pendingConeClock(
        self: *ChangeGraph,
        gpa: Allocator,
        actor: ActorIdx,
        meta: ChangeMetadata,
    ) Error!SeqClock {
        var clock = try SeqClock.init(gpa, self.numActors());
        errdefer clock.deinit();
        if (meta.clockEntry()) |seq| _ = clock.include(actor, seq);

        var frontier: std.ArrayList(NodeIdx) = .empty;
        defer frontier.deinit(gpa);
        try frontier.ensureTotalCapacity(gpa, meta.deps.len);
        for (meta.deps) |dep| {
            try insertNodeIdxSorted(&frontier, gpa, self.by_hash.get(dep).?);
        }
        try self.walkClock(gpa, &clock, &frontier);
        return clock;
    }

    /// Works out the cached fragment a change of level `level` names, and
    /// allocates everything committing it needs.
    ///
    /// The new fragment depends on every cached fragment the cone clock covers
    /// whose level is at least its own, and **supersedes** every one it covers
    /// whose level is lower: the new one reaches at least as far, so keeping
    /// the shallower one would name the same changes twice. The superseded
    /// entries are collected in descending index order and removed in that
    /// order, which is the only order in which removing one does not move
    /// another.
    ///
    /// `.iter().enumerate().rev()` upstream: the dependencies come out newest
    /// first, and so does the removal list. The cache is not read again after
    /// this, which is what lets the scan and the commit sit either side of the
    /// link of the change they describe.
    ///
    /// What comes back is owned by the caller in the ordinary way: a refusal
    /// path frees all three arrays through `StagedFragment.deinit`, and the
    /// commit keeps the two the cache stores. The removal list belongs to
    /// neither the cache nor the fragment, so the commit frees that one —
    /// exactly once, on the path that consumes it.
    fn stageFragment(
        self: *ChangeGraph,
        gpa: Allocator,
        level: usize,
        cone: SeqClock,
    ) Error!StagedFragment {
        var deps: std.ArrayList(NodeIdx) = .empty;
        errdefer deps.deinit(gpa);
        var supersede: std.ArrayList(usize) = .empty;
        errdefer supersede.deinit(gpa);

        var i = self.fragment_cache.items.len;
        while (i > 0) {
            i -= 1;
            const cached = self.fragment_cache.items[i];
            if (!cone.covers(cached.clock)) continue;
            const covered_level = self.nodes.items[cached.head].meta.hash.fragmentLevel();
            if (covered_level >= level) {
                try deps.append(gpa, cached.head);
            } else {
                try supersede.append(gpa, i);
            }
        }

        const owned_deps = try deps.toOwnedSlice(gpa);
        errdefer gpa.free(owned_deps);
        const owned_supersede = try supersede.toOwnedSlice(gpa);
        errdefer gpa.free(owned_supersede);
        var owned_clock = try cone.clone();
        errdefer owned_clock.deinit();
        try self.fragment_cache.ensureUnusedCapacity(gpa, 1);
        return .{
            .deps = owned_deps,
            .supersede = owned_supersede,
            .clock = owned_clock,
        };
    }

    /// Drops the cached fragments `staged` supersedes, merges the new one's
    /// clock into `fragment_top` and appends it, taking ownership of
    /// `staged`. Infallible, and only after
    /// [`stageFragment`](ChangeGraph.stageFragment).
    ///
    /// Every allocation this needs was made by the stage: the room in the
    /// cache was reserved there, and the removal list — which names positions
    /// in the cache as it was and is worth nothing afterwards — is freed
    /// here, because walking it is what consumes it. A commit that had to
    /// allocate would be the one way to leave a linked change with a cache
    /// half written, so it does not: the loop walks the list the stage built
    /// out of the cache, and neither `orderedRemove` nor `merge` allocates.
    fn commitFragment(self: *ChangeGraph, head: NodeIdx, staged: StagedFragment) void {
        for (staged.supersede) |at| {
            var gone = self.fragment_cache.orderedRemove(at);
            gone.deinit(self.gpa);
        }
        self.gpa.free(staged.supersede);
        self.fragment_top.merge(staged.clock);
        self.fragment_cache.appendAssumeCapacity(.{
            .head = head,
            .deps = staged.deps,
            .clock = staged.clock,
        });
    }

    /// Caches the fragment at `head`, or does nothing when its hash has level
    /// zero (`cache_fragment`, `change_graph.rs:683-706`).
    ///
    /// The one-shot form, for the rebuild in
    /// [`cacheFragments`](ChangeGraph.cacheFragments): it folds the cone and
    /// commits in one call. That is affordable there and not in `addChange`
    /// because a rebuild may fail — it is discarding a cache that is already
    /// there, and there is no linked change left half-described when it does.
    fn cacheFragment(self: *ChangeGraph, gpa: Allocator, head: NodeIdx) Error!void {
        const level = self.nodes.items[head].meta.hash.fragmentLevel();
        if (level == 0) return;
        var cone = try self.calculateClock(gpa, &.{head});
        defer cone.deinit();
        self.commitFragment(head, try self.stageFragment(gpa, level, cone));
    }

    /// Re-derives the whole fragment cache from the nodes, in node order
    /// (`cache_fragments`, `change_graph.rs:677-681`).
    ///
    /// Upstream runs this once over a graph its columnar loader built without
    /// going through `add_change`, which leaves nothing cached to throw away;
    /// here `addChange` caches as it goes, so this is the *rebuild* form and
    /// discards what is there first. That makes it the way to compare the two
    /// paths: a graph cached one change at a time and the same graph rebuilt
    /// in node order have to answer identically.
    fn cacheFragments(self: *ChangeGraph, gpa: Allocator) Error!void {
        for (self.fragment_cache.items) |*cached| cached.deinit(gpa);
        self.fragment_cache.clearRetainingCapacity();
        self.fragment_top.deinit();
        self.fragment_top = SeqClock.initEmpty(gpa);
        // Sized here, not grown by `cacheFragment`: `SeqClock.merge` folds
        // only over the entries both clocks have, so a zero-length
        // `fragment_top` would merge nothing and the loose walk would then
        // run to the root instead of stopping at the cached frontier. Every
        // other route sizes it in step with `seq_index` — `growActorSlots`,
        // `insertActor`, `removeActor` and `applyActorInsert` — and this is
        // the one that starts from nothing.
        try self.fragment_top.ensureSize(self.numActors());
        for (self.nodes.items, 0..) |_, n| try self.cacheFragment(gpa, @intCast(n));
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
    /// one, and every clock keyed by actor has to shift with them: the node
    /// clock cache, every cached fragment and `fragment_top`
    /// (`insert_actor`, `change_graph.rs:151-167`). Upstream writes all three
    /// in the same loop, and so does this, because a fragment clock left
    /// behind does not fail where it is stale: it fails at the next
    /// `cacheFragment`, which reads it to decide what the new fragment
    /// supersedes.
    ///
    /// `addChange` does this for itself when it interns an actor the table did
    /// not have. A caller that interns an actor without adding a change — a
    /// transaction that has an actor index but has not committed yet — must
    /// call this, or the graph's clocks stay shorter than the document's actor
    /// table and `Clock.covers` refuses to compare them.
    ///
    /// ## A refusal renumbers nothing
    ///
    /// Everything the insertion allocates is allocated first
    /// ([`stageActorInsert`](ChangeGraph.stageActorInsert)) and the rewrite
    /// itself cannot fail ([`commitActorInsert`](ChangeGraph.commitActorInsert)),
    /// so the nodes, the three clocks, `seq_index` and the op counters all
    /// move together or none of them does. A clock left naming the old slot
    /// is not a smaller wrong answer: it is a clock that reads as covering a
    /// different actor, which is the whole of what `AGENTS.md`'s actor-mirror
    /// rule is about.
    ///
    pub fn insertActor(self: *ChangeGraph, gpa: Allocator, idx: ActorIdx) Error!void {
        const at: usize = idx;
        if (at > self.seq_index.items.len) return error.InvalidIndex;
        try self.stageActorInsert(gpa);

        // From here nothing can fail.
        for (self.nodes.items) |*node| {
            if (node.actor >= idx) node.actor += 1;
        }
        self.commitActorInsert(idx);
    }

    /// Reserves everything opening an actor slot can need: one more entry in
    /// `seq_index`, and one more in each of the clocks keyed by actor — the
    /// node clock cache, every cached fragment and `fragment_top`.
    ///
    /// This is the whole fallible part of an actor insertion, and it is one
    /// function because [`insertActor`](ChangeGraph.insertActor) and
    /// [`applyActorInsert`](ChangeGraph.applyActorInsert) renumber the same
    /// clocks: a reservation one of them forgot is a rewrite that stops half
    /// way through the cache. Reserving it is also what makes the interning
    /// route atomic — [`internActor`](ChangeGraph.internActor) runs this
    /// before the actor table is told about the actor, so the table is never
    /// ahead of the graph.
    fn stageActorInsert(self: *ChangeGraph, gpa: Allocator) Error!void {
        try self.seq_index.ensureUnusedCapacity(gpa, 1);
        for (self.clock_cache.items) |*entry| try entry.clock.reserveNewActor();
        for (self.fragment_cache.items) |*cached| try cached.clock.reserveNewActor();
        try self.fragment_top.reserveNewActor();
    }

    /// Opens an empty actor slot at `idx` in every structure keyed by actor.
    /// Infallible, and only after
    /// [`stageActorInsert`](ChangeGraph.stageActorInsert) reserved the room it
    /// needs — nothing between the two may add or remove an actor, because
    /// this consumes exactly the one slot that call was made for.
    fn commitActorInsert(self: *ChangeGraph, idx: ActorIdx) void {
        for (self.clock_cache.items) |*entry| entry.clock.rewriteWithNewActor(idx);
        for (self.fragment_cache.items) |*cached| cached.clock.rewriteWithNewActor(idx);
        self.fragment_top.rewriteWithNewActor(idx);
        self.seq_index.insertAssumeCapacity(idx, .empty);
    }

    /// Removes the actor slot at `idx`, shifting every higher index down and
    /// dropping the slot from every clock keyed by actor: the node clock
    /// cache, every cached fragment and `fragment_top` (`remove_actor`,
    /// `change_graph.rs:169-186`).
    ///
    /// The actor must have no changes in the graph. Upstream asserts it
    /// (`change_graph.rs:175-177`) and panics, because an actor whose changes
    /// are still here would have them retarget another actor. A rollback of a
    /// first change is the only caller that should ever get here, and it passes
    /// an actor the graph has just emptied.
    ///
    /// Nothing here allocates, so there is no half-removed state to be in: the
    /// two refusals above are the whole of what can go wrong, and both are
    /// decided before the first index moves.
    pub fn removeActor(self: *ChangeGraph, idx: ActorIdx) Error!void {
        const at: usize = idx;
        if (at >= self.seq_index.items.len) return error.InvalidIndex;
        if (self.seq_index.items[at].items.len != 0) return error.InvalidIndex;
        for (self.nodes.items) |*node| {
            if (node.actor > idx) node.actor -= 1;
        }
        for (self.clock_cache.items) |*entry| entry.clock.removeActor(idx);
        for (self.fragment_cache.items) |*cached| cached.clock.removeActor(idx);
        self.fragment_top.removeActor(idx);
        var list = self.seq_index.orderedRemove(at);
        list.deinit(self.gpa);
    }

    /// Interns the author and every referenced actor of `meta`, opening a slot
    /// for each actor the table did not have, and catching up with actors
    /// interned by someone else.
    ///
    /// Each actor is interned on its own, so a change naming three actors the
    /// table has never seen is three transactions rather than one: the ones
    /// before a refusal have landed and the rest have not, and every one of
    /// them left the table and the graph agreeing about which index names
    /// which actor.
    fn internActors(
        self: *ChangeGraph,
        gpa: Allocator,
        authors: *Authors,
        meta: ChangeMetadata,
    ) Error!ActorIdx {
        _ = try self.internActor(gpa, authors, meta.actor);
        for (meta.other_actors) |other| _ = try self.internActor(gpa, authors, other);

        if (self.seq_index.items.len < authors.count()) {
            try self.growActorSlots(gpa, authors.count());
        }
        // Read the author's index last: a later actor may have sorted before
        // it and shifted it up, and every shift above has already been applied
        // to the nodes the graph holds.
        return authors.lookup(meta.actor).?;
    }

    /// Interns one actor into `authors`, opening its slot in every structure
    /// the graph keys by actor when the table did not have it.
    ///
    /// **The graph's room is reserved before the table is told about the
    /// actor**, and that order is the whole of the atomicity across the two.
    /// The reservation is the insertion's only fallible step
    /// ([`stageActorInsert`](ChangeGraph.stageActorInsert)) and
    /// [`applyActorInsert`](ChangeGraph.applyActorInsert) cannot fail, so the
    /// one step left that can still be refused — `authors.intern` — runs with
    /// the whole insertion already paid for. A refusal from the table leaves
    /// the graph's room reserved and nothing else changed, because a
    /// reservation moves no length; a refusal from anything later leaves both
    /// halves exactly as they were.
    ///
    /// The lookup is what the ordering costs: the table is the only thing that
    /// knows whether the actor is new, and `intern` hands back the index rather
    /// than whether it inserted, so that answer has to be had before the
    /// reservation rather than after it.
    ///
    /// The other order cannot be repaired afterwards, which is why this is not
    /// a preference. Publishing the actor first leaves a table holding an
    /// actor the graph has no slot for, and a retry does not mend that:
    /// interning is idempotent, so the retry takes the "already there" path,
    /// skips the insertion, and grows slots at the tail — the right slot only
    /// for an actor that sorts last. Nothing reports it, because
    /// `numActors()` still equals `authors.count()`; every answer keyed by
    /// actor index is then about an actor other than the one whose bytes named
    /// it. The regression test is `test "a refused change whose author and
    /// other actors are new leaves the author table and every mirror where
    /// they were"`.
    fn internActor(
        self: *ChangeGraph,
        gpa: Allocator,
        authors: *Authors,
        actor: ActorId,
    ) Error!ActorIdx {
        const known = authors.lookup(actor) != null;
        if (!known) try self.stageActorInsert(gpa);
        const idx = try authors.intern(gpa, actor);
        if (!known) self.applyActorInsert(authors, idx);
        return idx;
    }

    /// Applies the remap the actor table just produced: every stored actor
    /// index moves, every clock keyed by actor shifts, and an empty slot
    /// appears for the actor that was inserted. This is the only thing that
    /// can invalidate a cached clock, and it has to happen in the same breath
    /// as the insertion — which is why it cannot fail: the room it opens was
    /// reserved by [`stageActorInsert`](ChangeGraph.stageActorInsert) before
    /// the table was told about the actor
    /// ([`internActor`](ChangeGraph.internActor)).
    ///
    /// `inserted` is the index `intern` gave the actor it added. An insertion
    /// writes one remap entry per old actor plus one for the new actor, and
    /// that last entry is the new actor's index (`author.zig:229-233`), so
    /// the index the caller already holds is the one the remap's last entry
    /// would give. Reading it out of the remap instead would mean trusting
    /// that a remap this fresh has an entry to read.
    fn applyActorInsert(self: *ChangeGraph, authors: *const Authors, inserted: ActorIdx) void {
        const remap = authors.remap();
        for (self.nodes.items) |*node| node.actor = remap[node.actor];
        self.commitActorInsert(inserted);
    }

    /// Appends empty actor slots up to `count`, growing the clocks that are
    /// indexed by actor to match: the node clock cache, `fragment_top` and
    /// every cached fragment.
    ///
    /// Staged the way an insertion is: the slots and every clock are reserved
    /// before either of them moves, so a refusal leaves the actor count and
    /// the clocks that count long together.
    ///
    /// **Appending is the whole of what this can do**, so it is right only for
    /// actors that sort after every slot the graph already has. That is what
    /// the routes that reach it produce — a caller that interned straight into
    /// `authors` without a change to go with it, ahead of the graph — and it
    /// is what an actor interned into the middle of the table gets wrong,
    /// which is why [`insertActor`](ChangeGraph.insertActor) is the documented
    /// way to intern one. Nothing here can tell the two apart: the graph does
    /// not hold the bytes of the slots it has, so it has no way to notice that
    /// the table shifted underneath it, and a slot in the wrong place is an
    /// actor's changes counted under another actor's name. The refusal path
    /// cannot produce that state, because
    /// [`internActor`](ChangeGraph.internActor) never leaves the table ahead
    /// of the graph for this to catch up with.
    fn growActorSlots(self: *ChangeGraph, gpa: Allocator, count: usize) Error!void {
        try self.seq_index.ensureUnusedCapacity(gpa, count -| self.seq_index.items.len);
        try self.stageClockGrowth(count);

        // From here nothing can fail.
        while (self.seq_index.items.len < count) self.seq_index.appendAssumeCapacity(.empty);
        for (self.clock_cache.items) |*entry| entry.clock.resizeNoFail(count);
        for (self.fragment_cache.items) |*cached| cached.clock.resizeNoFail(count);
        self.fragment_top.resizeNoFail(count);
    }

    /// Reserves room for `count` entries in every clock keyed by actor.
    fn stageClockGrowth(self: *ChangeGraph, count: usize) Error!void {
        for (self.clock_cache.items) |*entry| try entry.clock.reserve(count);
        for (self.fragment_cache.items) |*cached| try cached.clock.reserve(count);
        try self.fragment_top.reserve(count);
    }

    /// Links a validated change into the graph. Every fallible step happens
    /// first, so a failure here leaves the graph exactly as it was.
    ///
    /// Refuses with `error.Fail` when the graph has no index left for what
    /// the change adds: a node past `max_node_count`, or edges past
    /// `max_edge_count`. Upstream mints both indices unchecked and lets the
    /// 32 bits wrap (`NodeIdx`, `change_graph.rs:550`; `EdgeIdx::new`,
    /// `change_graph.rs:68-70`), and a wrapped edge index would splice this
    /// change's edges into another change's list, so this port refuses the
    /// change rather than mislink the graph.
    fn pushNode(
        self: *ChangeGraph,
        gpa: Allocator,
        meta: ChangeMetadata,
        actor: ActorIdx,
    ) Error!NodeIdx {
        if (self.nodes.items.len >= max_node_count) return error.Fail;
        // Each dependency appends one edge to each adjacency list, so what
        // the two lists have left is what the change needs of them. The room
        // is computed saturating so the check stays total: a list already
        // past the bound reports none rather than an underflowed amount.
        if (meta.deps.len > max_edge_count -| self.parent_edges.items.len) return error.Fail;
        if (meta.deps.len > max_edge_count -| self.child_edges.items.len) return error.Fail;
        // Re-checked here so the loops below cannot fail: `addChange` proved
        // it, and this is where the proof is used.
        for (meta.deps) |dep| {
            if (!self.by_hash.contains(dep)) return error.MissingDeps;
        }

        // The index of the node being added, and of the first edge this
        // change contributes to each adjacency list. The checks above bound
        // all three, so these restate the bound where the index is minted
        // instead of adding a failure mode: none of them can fail here.
        const idx = try nextIndex(self.nodes.items.len);
        var parent_edge = try nextIndex(self.parent_edges.items.len);
        var child_edge = try nextIndex(self.child_edges.items.len);

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

        // The dependency edges hang off the new node, and every dependency is
        // already in the graph, so every parent index is below `idx`. Each
        // list is built in the order the change named its dependencies, the
        // way `add_parent` appends to the tail of the child's list upstream
        // (`change_graph.rs:754-763`), so a walk yields the dependencies in the
        // order the change wrote them.
        var parent_head: ?NodeIdx = null;
        var parent_tail: ?NodeIdx = null;
        // The edge indices below are counted rather than read back off the
        // list, so the bound checked above covers every one of them: a list
        // with room for `deps.len` more edges takes exactly that many, and
        // the last one it takes is still an index the list can hold.
        for (owned.deps) |dep| {
            const parent = self.by_hash.get(dep).?;
            self.parent_edges.appendAssumeCapacity(.{ .target = parent, .next = null });
            if (parent_tail) |tail| {
                self.parent_edges.items[tail].next = parent_edge;
            } else {
                parent_head = parent_edge;
            }
            parent_tail = parent_edge;
            parent_edge += 1;
        }
        // The child edges are the same list seen from the other end: a
        // parent's children, in the order they were added.
        for (owned.deps) |dep| {
            const parent = self.by_hash.get(dep).?;
            const old_head = self.nodes.items[parent].children;
            self.child_edges.appendAssumeCapacity(.{ .target = idx, .next = old_head });
            self.nodes.items[parent].children = child_edge;
            child_edge += 1;
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

/// The index the item appended to a list of `len` items takes, or
/// `error.Fail` when the list has no index left to give.
///
/// Every list the graph addresses — nodes, parent edges, child edges — is
/// indexed by `NodeIdx`, the `u32` upstream uses for a node (`NodeIdx`,
/// `change_graph.rs:53-54`) and, over the same 32 bits, for an edge
/// (`EdgeIdx(NonZeroU32)`, `change_graph.rs:64-65`). A caller that has
/// already refused a change with more items than that cannot get
/// `error.Fail` here: the conversion is what makes the bound checkable
/// where the index is minted, not a second way to fail.
fn nextIndex(len: usize) Error!NodeIdx {
    return std.math.cast(NodeIdx, len) orelse error.Fail;
}

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

/// Frees a fragment list and, first, every fragment in it. This is what a
/// caller of `ChangeGraph.fragments` owes it: the list and each fragment's
/// three arrays came from the same allocator.
pub fn deinitFragments(gpa: Allocator, fragments: []Fragment) void {
    for (fragments) |*fragment| fragment.deinit(gpa);
    gpa.free(fragments);
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

/// A hash whose fragment level is exactly `level`, with the counter `n` in
/// its last four bytes.
///
/// Upstream's fragment tests get a fragment head by chance, one hash in 256,
/// and build a thousand changes to make it likely (`change_graph.rs:1231-1232`)
/// or ten thousand small graphs until it happens (`change_graph.rs:1496`).
/// Spelling the level out gives a fixture that is the same on every run, and
/// an assertion that names the node it meant.
fn levelHash(n: u32, level: usize) ChangeHash {
    std.debug.assert(level < 32);
    var hash = ChangeHash.zero;
    // The counter goes in the last four bytes so the zero run in front of it
    // is the only thing the level reads.
    std.mem.writeInt(u32, hash.bytes[28..32], n, .big);
    hash.bytes[level] = 1;
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

/// The number of nodes the last walk stamped.
///
/// A walk marks every node it reaches (`stamp` and `visit_stamp` are the
/// walk's scratch, `change_graph.rs:833`), so this is how far the last one
/// went: a walk that merges the clock cached at the nearest `cache_step` point
/// stamps a handful of nodes, and one that descended the whole history stamps
/// all of them. Only meaningful straight after the walk in question, since the
/// stamps are reused by the next one.
fn lastWalkVisited(graph: *const ChangeGraph) usize {
    var n: usize = 0;
    for (graph.visit_stamp.items) |seen| {
        if (seen == graph.stamp) n += 1;
    }
    return n;
}

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
    // The walk from the tip merges the clock cached at node 15 rather than
    // descending the twenty changes, which is what makes a stale entry there
    // a wrong answer rather than only a slow one. Every node a walk reaches is
    // stamped, so the stamps are how far it went.
    var at_tip = try graph.clockAt(gpa, &.{hashes[19]});
    defer at_tip.deinit();
    try testing.expectEqualSlices(u32, &.{20}, at_tip.values());
    try testing.expect(lastWalkVisited(graph) <= cache_step);

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

    var at_cache_point = try graph.clockAt(gpa, &.{hashes[31]});
    defer at_cache_point.deinit();
    try testing.expectEqualSlices(u32, &.{ 17, 1 }, at_cache_point.values());
    // Every node a walk reaches is stamped, so the stamps it leaves are the
    // nodes it did *not* merge away. The two cache points are nodes 15 and
    // 31, and a walk that descended all thirty-three changes instead would
    // leave thirty-three of them.
    try testing.expect(lastWalkVisited(graph) <= cache_step);

    // The tip reads that cache entry on the way down.
    var at_tip = try graph.clockAt(gpa, &.{hashes[32]});
    defer at_tip.deinit();
    try testing.expectEqualSlices(u32, &.{ 18, 1 }, at_tip.values());
    try testing.expect(lastWalkVisited(graph) <= cache_step);

    // A caller that interns an actor of its own grows the graph too, and the
    // cached clocks shift with the actor indices.
    try graph.insertActor(gpa, 0);
    var after_insert = try graph.clockAt(gpa, &.{hashes[32]});
    defer after_insert.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 18, 1 }, after_insert.values());
    // The rewritten clock still stops the walk, under the new actor index.
    try testing.expect(lastWalkVisited(graph) <= cache_step);
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

test "an index the graph cannot name is refused, not truncated" {
    // The conversion every index in the graph goes through, at the two
    // lengths that matter: an empty list, and the last index `u32` has.
    try testing.expectEqual(@as(NodeIdx, 0), try nextIndex(0));
    try testing.expectEqual(@as(NodeIdx, max_node_count), try nextIndex(max_edge_count));
    // One more edge than an index can name, which `pushNode` refuses with
    // rather than wrapping into another change's edge list.
    try testing.expectError(error.Fail, nextIndex(max_edge_count + 1));
}

// ---------------------------------------------------------------------------
// Fragment tests
// ---------------------------------------------------------------------------

/// True when `haystack` holds `needle`. A fragment's arrays are short, so a
/// linear scan is the whole membership test.
fn containsHash(haystack: []const ChangeHash, needle: ChangeHash) bool {
    for (haystack) |h| {
        if (h.eql(needle)) return true;
    }
    return false;
}

/// Every hash any fragment of `fragments` covers as a member. A hash may be
/// in more than one fragment; upstream says so and the test that uses this
/// is `fragments_cover_all_changes` (`change_graph.rs:1247-1248`).
fn memberSet(gpa: Allocator, fragments: []const Fragment) Error!HashSet {
    var set: HashSet = .empty;
    errdefer set.deinit(gpa);
    for (fragments) |fragment| {
        for (fragment.members) |member| try set.put(gpa, member, {});
    }
    return set;
}

fn expectSameFragment(expected: Fragment, got: Fragment) !void {
    try testing.expect(expected.head.eql(got.head));
    try testing.expectEqual(expected.level, got.level);
    try testing.expectEqualSlices(ChangeHash, expected.boundary, got.boundary);
    try testing.expectEqualSlices(ChangeHash, expected.checkpoints, got.checkpoints);
    try testing.expectEqualSlices(ChangeHash, expected.members, got.members);
}

/// The shape every fragment has to hold (`assert_fragment_invariants`,
/// `change_graph.rs:1264-1315`), plus the one that only a loose fragment can
/// be checked against: its boundary is the change's own dependency list, in
/// the order the change wrote it (`change_graph.rs:601`).
fn expectFragmentInvariants(gpa: Allocator, graph: *const ChangeGraph, fragments: []const Fragment) !void {
    for (fragments) |fragment| {
        try testing.expectEqual(fragment.head.fragmentLevel(), fragment.level);
        try testing.expect(containsHash(fragment.members, fragment.head));

        try testing.expect(!containsHash(fragment.checkpoints, fragment.head));
        for (fragment.boundary) |dep| {
            try testing.expect(!containsHash(fragment.checkpoints, dep));
        }
        for (fragment.checkpoints) |checkpoint| {
            try testing.expect(containsHash(fragment.members, checkpoint));
            try testing.expect(checkpoint.fragmentLevel() > 0);
        }

        for (fragment.boundary) |dep| {
            try testing.expect(dep.fragmentLevel() >= fragment.level);
        }
        for (fragment.members) |member| {
            try testing.expect(member.fragmentLevel() <= fragment.level);
        }

        if (fragment.level != 0) continue;
        var deps: std.ArrayList(ChangeHash) = .empty;
        defer deps.deinit(gpa);
        var it = graph.parents(graph.hashToIndex(fragment.head).?);
        while (it.next()) |parent| try deps.append(gpa, graph.indexToHash(parent).?);
        try testing.expectEqualSlices(ChangeHash, deps.items, fragment.boundary);
    }
}

test "fragments cover every change, and come out newest first" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // A thousand changes by one actor, with fragment heads at the four nodes
    // spelled out below. Nodes 200, 700 and 900 are level 1 and node 500 is
    // level 2, so: 500 supersedes 200, 700 and 900 both depend on 500, and
    // 900 depends on 700 as well as on 500.
    var hashes: [1000]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..1000) |i| {
        const level: usize = switch (i) {
            200, 700, 900 => 1,
            500 => 2,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }
    // Four fragment heads were built in and three of them are cached; the
    // level-1 head at node 200 is covered by the level-2 head at 500 and
    // dropped, which is why the answer below is 99 loose fragments and three
    // cached ones rather than four.

    const all = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, all);

    // Ninety-nine loose fragments, walking down from the head while
    // `fragment_top` does not reach, and then the three cached ones newest
    // head first.
    try testing.expectEqual(@as(usize, 102), all.len);
    try testing.expect(all[0].head.eql(hashes[999]));
    try testing.expect(all[98].head.eql(hashes[901]));
    try testing.expect(all[99].head.eql(hashes[900]));
    try testing.expect(all[100].head.eql(hashes[700]));
    try testing.expect(all[101].head.eql(hashes[500]));

    // The level-2 fragment reaches the root: it depends on nothing, so its
    // clock is empty and the walk has no floor to stop at.
    try testing.expectEqual(@as(usize, 2), all[101].level);
    try testing.expectEqualSlices(ChangeHash, &.{}, all[101].boundary);
    try testing.expectEqual(@as(usize, 501), all[101].members.len);
    try testing.expect(all[101].members[0].eql(hashes[500]));
    try testing.expect(all[101].members[500].eql(hashes[0]));
    // Every other level-1 head it passes on the way down is a checkpoint,
    // newest first, and the head is never one of its own.
    try testing.expectEqualSlices(
        ChangeHash,
        &.{hashes[200]},
        all[101].checkpoints,
    );

    // A level-1 fragment stops just above what its dependencies reach, so a
    // dependency is a boundary and is not a member or a checkpoint.
    try testing.expectEqual(@as(usize, 1), all[99].level);
    try testing.expectEqualSlices(
        ChangeHash,
        &.{ hashes[700], hashes[500] },
        all[99].boundary,
    );
    try testing.expectEqual(@as(usize, 200), all[99].members.len);
    try testing.expect(all[99].members[0].eql(hashes[900]));
    try testing.expect(all[99].members[199].eql(hashes[701]));
    try testing.expectEqualSlices(ChangeHash, &.{}, all[99].checkpoints);

    try testing.expectEqual(@as(usize, 1), all[100].level);
    try testing.expectEqualSlices(ChangeHash, &.{hashes[500]}, all[100].boundary);
    try testing.expectEqual(@as(usize, 200), all[100].members.len);
    try testing.expect(all[100].members[0].eql(hashes[700]));
    try testing.expect(all[100].members[199].eql(hashes[501]));

    // Between them the fragments cover the whole history, with nothing left
    // over: 99 + 901..900 + 700..501 + 500..0.
    var covered = try memberSet(gpa, all);
    defer covered.deinit(gpa);
    try testing.expectEqual(@as(usize, 1000), covered.count());
    for (hashes) |hash| try testing.expect(covered.contains(hash));
    try expectFragmentInvariants(gpa, graph, all);
}

test "a deeper fragment supersedes every shallower one it covers" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Nodes 100 and 300 are level 2, nodes 200 and 400 are level 1 and node
    // 500 is level 3. Every one of the earlier fragments is covered by a
    // later one and none of them is as deep, so 500 supersedes all four and
    // the cache is left holding one entry.
    var hashes: [600]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..600) |i| {
        const level: usize = switch (i) {
            100, 300 => 2,
            200, 400 => 1,
            500 => 3,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }
    // Five fragment heads were built in and every one of them is covered by
    // the level-3 head at node 500, which is deeper than all of them, so the
    // four shallower ones are dropped and answer nothing at all.
    try testing.expect((try graph.getFragment(gpa, hashes[100])) == null);
    try testing.expect((try graph.getFragment(gpa, hashes[200])) == null);
    try testing.expect((try graph.getFragment(gpa, hashes[300])) == null);
    try testing.expect((try graph.getFragment(gpa, hashes[400])) == null);

    const all = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, all);

    // Ninety-nine loose fragments, from the head down to just above the
    // cached fragment at node 500, and then that one.
    try testing.expectEqual(@as(usize, 100), all.len);
    try testing.expect(all[0].head.eql(hashes[599]));
    try testing.expect(all[98].head.eql(hashes[501]));
    try testing.expect(all[99].head.eql(hashes[500]));
    try testing.expectEqual(@as(usize, 3), all[99].level);
    try testing.expectEqualSlices(ChangeHash, &.{}, all[99].boundary);

    // It reaches the root, so every shallower fragment head it passed is one
    // of its checkpoints, newest first.
    try testing.expectEqual(@as(usize, 501), all[99].members.len);
    try testing.expectEqualSlices(
        ChangeHash,
        &.{ hashes[400], hashes[300], hashes[200], hashes[100] },
        all[99].checkpoints,
    );
    try expectFragmentInvariants(gpa, graph, all);
}

test "a fragment's checkpoints exclude its head and its boundary" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Two level-1 fragment heads, one behind the other, so the newer one has
    // a boundary and the older one does not.
    var hashes: [100]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..100) |i| {
        const level: usize = if (i == 50 or i == 80) 1 else 0;
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }

    const cached = try graph.fragments(gpa, graph.getHeads(), .{ .start = 1 });
    defer deinitFragments(gpa, cached);
    try testing.expectEqual(@as(usize, 2), cached.len);
    try testing.expect(cached[0].head.eql(hashes[80]));
    try testing.expect(cached[1].head.eql(hashes[50]));
    // The newer fragment stands on the older one, so this is the case the
    // exclusion is about.
    try testing.expectEqualSlices(ChangeHash, &.{hashes[50]}, cached[0].boundary);
    try testing.expectEqualSlices(ChangeHash, &.{}, cached[1].boundary);
    try testing.expectEqual(@as(usize, 30), cached[0].members.len);
    try testing.expect(cached[0].members[0].eql(hashes[80]));
    try testing.expect(cached[0].members[29].eql(hashes[51]));

    for (cached) |fragment| {
        try testing.expect(containsHash(fragment.members, fragment.head));
        try testing.expect(!containsHash(fragment.checkpoints, fragment.head));
        for (fragment.boundary) |dep| {
            try testing.expect(!containsHash(fragment.checkpoints, dep));
        }
        // `getFragment` on a fragment head answers with that fragment, so a
        // caller can name one and get it back without holding the list.
        var got = (try graph.getFragment(gpa, fragment.head)).?;
        defer got.deinit(gpa);
        try expectSameFragment(fragment, got);
    }

    // The loose fragments stop where the cached frontier reaches: nineteen
    // of them, from the head down to node 81.
    const loose = try graph.fragments(gpa, graph.getHeads(), .{ .start = 0, .end = 1 });
    defer deinitFragments(gpa, loose);
    try testing.expectEqual(@as(usize, 19), loose.len);
    try testing.expect(loose[0].head.eql(hashes[99]));
    try testing.expect(loose[18].head.eql(hashes[81]));
    try expectFragmentInvariants(gpa, graph, loose);
}

test "fragments work with concurrent actors" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Two chains that start at one root and merge every fifty changes, the
    // shape upstream builds (`change_graph.rs:1368-1386`). Four of the
    // changes are named as fragment heads so the cache has something to say.
    var all_hashes: std.ArrayList(ChangeHash) = .empty;
    defer all_hashes.deinit(gpa);
    var counter: u32 = 0;
    var start_op: u64 = 1;

    const root = try b.changeAt(levelHash(counter, 0), "a", start_op, 1, &.{});
    counter += 1;
    start_op += 1;
    try all_hashes.append(gpa, root);

    var tip1 = root;
    var tip2 = root;
    for (0..500) |i| {
        tip1 = try b.changeAt(levelHash(counter, 0), "a", start_op, 1, &.{tip1});
        counter += 1;
        start_op += 1;
        try all_hashes.append(gpa, tip1);
        tip2 = try b.changeAt(levelHash(counter, 0), "b", start_op, 1, &.{tip2});
        counter += 1;
        start_op += 1;
        try all_hashes.append(gpa, tip2);
        if (i % 50 != 49) continue;
        const level: usize = if (i == 249) 1 else 0;
        tip1 = try b.changeAt(levelHash(counter, level), "a", start_op, 1, &.{ tip1, tip2 });
        counter += 1;
        start_op += 1;
        try all_hashes.append(gpa, tip1);
        tip2 = tip1;
    }

    const fragments = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, fragments);

    var covered = try memberSet(gpa, fragments);
    defer covered.deinit(gpa);
    try testing.expectEqual(all_hashes.items.len, covered.count());
    for (all_hashes.items) |hash| try testing.expect(covered.contains(hash));
    try expectFragmentInvariants(gpa, graph, fragments);

    // The merge at i == 249 is the deepest history point named, and the
    // concurrent chain that runs alongside it has to appear in its members.
    var saw_merge = false;
    for (fragments) |fragment| {
        if (fragment.level == 0) continue;
        saw_merge = true;
        try testing.expect(graph.hasChange(fragment.head));
        for (fragment.members) |member| try testing.expect(graph.hasChange(member));
    }
    try testing.expect(saw_merge);

    // The cached half is newest head first, which is the order `fragments`
    // walks the cache in.
    var previous: ?NodeIdx = null;
    for (fragments) |fragment| {
        if (fragment.level == 0) continue;
        const node = graph.hashToIndex(fragment.head).?;
        if (previous) |before| try testing.expect(before > node);
        previous = node;
    }
}

test "a fragment's boundary names changes the graph has" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Four level-1 fragment heads in a row on a chain, so each one depends on
    // every one before it: 400 stands on 300, 200 and 100, newest first.
    var hashes: [1000]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..1000) |i| {
        const level: usize = switch (i) {
            100, 200, 300, 400 => 1,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }

    const fragments = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, fragments);
    try testing.expectEqual(@as(usize, 603), fragments.len);

    const cached = fragments[599..];
    try testing.expectEqual(@as(usize, 4), cached.len);
    try testing.expect(cached[0].head.eql(hashes[400]));
    try testing.expect(cached[1].head.eql(hashes[300]));
    try testing.expect(cached[2].head.eql(hashes[200]));
    try testing.expect(cached[3].head.eql(hashes[100]));
    try testing.expectEqualSlices(
        ChangeHash,
        &.{ hashes[300], hashes[200], hashes[100] },
        cached[0].boundary,
    );
    try testing.expectEqualSlices(ChangeHash, &.{ hashes[200], hashes[100] }, cached[1].boundary);
    try testing.expectEqualSlices(ChangeHash, &.{hashes[100]}, cached[2].boundary);
    try testing.expectEqualSlices(ChangeHash, &.{}, cached[3].boundary);

    // Every boundary is a change this graph has, and a cached fragment's is
    // the head of another cached fragment rather than a change that merely
    // happens to be in the history (`change_graph.rs:1424-1442`).
    var heads: HashSet = .empty;
    defer heads.deinit(gpa);
    for (cached) |fragment| try heads.put(gpa, fragment.head, {});
    for (cached) |fragment| {
        for (fragment.boundary) |dep| {
            try testing.expect(graph.hasChange(dep));
            try testing.expect(dep.fragmentLevel() > 0);
            try testing.expect(heads.contains(dep));
        }
    }

    // Between them: 599 loose, then 400..301, 300..201, 200..101 and 100..0.
    var covered = try memberSet(gpa, fragments);
    defer covered.deinit(gpa);
    try testing.expectEqual(@as(usize, 1000), covered.count());
    for (hashes) |hash| try testing.expect(covered.contains(hash));
    try expectFragmentInvariants(gpa, graph, fragments);
}

test "fragments can be asked for by level alone" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    var hashes: [1000]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..1000) |i| {
        const level: usize = switch (i) {
            200, 700, 900 => 1,
            500 => 2,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }

    const all = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, all);
    const loose = try graph.fragments(gpa, graph.getHeads(), .{ .start = 0, .end = 1 });
    defer deinitFragments(gpa, loose);
    const cached = try graph.fragments(gpa, graph.getHeads(), .{ .start = 1 });
    defer deinitFragments(gpa, cached);
    const deepest = try graph.fragments(gpa, graph.getHeads(), .{ .start = 2 });
    defer deinitFragments(gpa, deepest);
    const none = try graph.fragments(gpa, graph.getHeads(), .{ .start = 0, .end = 0 });
    defer deinitFragments(gpa, none);

    // The two halves partition the whole range, which is the property the
    // level filter exists to have (`change_graph.rs:1465`).
    try testing.expectEqual(all.len, loose.len + cached.len);
    try testing.expectEqual(@as(usize, 102), all.len);
    try testing.expectEqual(@as(usize, 99), loose.len);
    try testing.expectEqual(@as(usize, 3), cached.len);
    for (loose) |fragment| try testing.expectEqual(@as(usize, 0), fragment.level);
    for (cached) |fragment| try testing.expect(fragment.level >= 1);

    // Only one fragment is deeper than level 1, and a range that excludes
    // everything yields nothing at all rather than everything.
    try testing.expectEqual(@as(usize, 1), deepest.len);
    try testing.expect(deepest[0].head.eql(hashes[500]));
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "a head that is itself a fragment head leaves no loose fragments" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Upstream reaches this case by rebuilding small graphs until the head
    // hash has a leading zero byte (`change_graph.rs:1490-1523`). Spelling
    // the level out reaches it on the first run.
    var hashes: [8]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..8) |i| {
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), if (i == 7) 1 else 0),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }

    const all = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, all);
    const loose = try graph.fragments(gpa, graph.getHeads(), .{ .start = 0, .end = 1 });
    defer deinitFragments(gpa, loose);

    // A cached head covers everything, so there is nothing loose at all.
    try testing.expectEqual(@as(usize, 0), loose.len);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expect(all[0].head.eql(hashes[7]));
    try testing.expectEqualSlices(ChangeHash, &.{}, all[0].boundary);
    try testing.expectEqualSlices(ChangeHash, &.{}, all[0].checkpoints);

    // And that one fragment covers the whole history.
    try testing.expectEqual(@as(usize, 8), all[0].members.len);
    var covered = try memberSet(gpa, all);
    defer covered.deinit(gpa);
    try testing.expectEqual(@as(usize, 8), covered.count());
    for (hashes) |hash| try testing.expect(covered.contains(hash));
    try expectFragmentInvariants(gpa, graph, all);
}

test "getFragment answers for a loose head, a cached head, and nothing else" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    var hashes: [1000]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..1000) |i| {
        const level: usize = switch (i) {
            200, 700, 900 => 1,
            500 => 2,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        hashes[i] = prev;
    }

    const all = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, all);

    // The head itself is loose, and naming it answers with that fragment.
    var loose_head = (try graph.getFragment(gpa, hashes[999])).?;
    defer loose_head.deinit(gpa);
    try expectSameFragment(all[0], loose_head);
    try testing.expectEqualSlices(ChangeHash, &.{hashes[998]}, loose_head.boundary);

    // The newest cached fragment answers the same way.
    var cached_head = (try graph.getFragment(gpa, hashes[900])).?;
    defer cached_head.deinit(gpa);
    try expectSameFragment(all[99], cached_head);

    // A hash the graph has never seen is not a fragment.
    try testing.expect((try graph.getFragment(gpa, testHash(0xff_ffff))) == null);

    // And a fragment head a deeper fragment superseded is not one either: it
    // was dropped from the cache, so there is nothing left to answer with.
    try testing.expect(graph.hasChange(hashes[200]));
    try testing.expect((try graph.getFragment(gpa, hashes[200])) == null);
    // A level-0 head is always answerable: a loose fragment is derived from
    // the change rather than read out of the cache.
    var never_cached = (try graph.getFragment(gpa, hashes[201])).?;
    defer never_cached.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), never_cached.members.len);
}

test "renumbering an actor keeps every fragment clock in step" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Four hundred changes by "b" with a level-1 fragment head at node 200.
    var first: [400]ChangeHash = undefined;
    var prev: ChangeHash = undefined;
    for (0..400) |i| {
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), if (i == 200) 1 else 0),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
        first[i] = prev;
    }

    // A hundred and ninety-nine loose fragments down to node 201, then the
    // cached one at node 200.
    const before = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, before);
    try testing.expectEqual(@as(usize, 200), before.len);
    try testing.expect(before[0].head.eql(first[399]));
    try testing.expect(before[198].head.eql(first[201]));
    try testing.expect(before[199].head.eql(first[200]));

    // "a" sorts before "b", so interning it moves every "b" node up a slot.
    // `fragment_top` moves with them, and the way to see that it did is that
    // the loose walk still stops where the cached frontier reaches: a clock
    // left naming the old slot reads as covering nothing, and the walk runs
    // to the root.
    const forked = try b.changeAt(levelHash(900_001, 0), "a", 401, 1, &.{first[399]});
    try testing.expectEqual(@as(usize, 2), graph.numActors());
    try testing.expectEqual(@as(ActorIdx, 1), graph.nodeFor(first[0]).?.actor);
    try testing.expectEqual(@as(ActorIdx, 0), graph.nodeFor(forked).?.actor);

    const after = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, after);
    try testing.expectEqual(@as(usize, 201), after.len);
    try testing.expect(after[0].head.eql(forked));
    try testing.expect(after[199].head.eql(first[201]));
    try testing.expect(after[200].head.eql(first[200]));

    // A level-2 fragment head behind it supersedes the level-1 one. That
    // comparison reads the *cached* fragment's own clock, so this is the test
    // for the rewrite on the fragment side: a clock left naming the old slot
    // covers nothing, the fragment is not superseded, and the cache ends up
    // with two entries where it should hold one.
    var rest: [100]ChangeHash = undefined;
    var tip: ChangeHash = forked;
    for (0..100) |i| {
        tip = try b.changeAt(
            levelHash(@intCast(5000 + i + 1), if (i == 79) 2 else 0),
            "b",
            @intCast(402 + i),
            1,
            &.{tip},
        );
        rest[i] = tip;
    }
    try testing.expect((try graph.getFragment(gpa, first[200])) == null);

    const deepest = try graph.fragments(gpa, graph.getHeads(), .{ .start = 1 });
    defer deinitFragments(gpa, deepest);
    try testing.expectEqual(@as(usize, 1), deepest.len);
    try testing.expect(deepest[0].head.eql(rest[79]));
    try testing.expectEqual(@as(usize, 2), deepest[0].level);
    try testing.expectEqualSlices(ChangeHash, &.{}, deepest[0].boundary);
    // It supersedes everything below it and depends on nothing, so it reaches
    // the root of both actors, and the level-1 head it replaced is a
    // checkpoint rather than a boundary.
    try testing.expectEqual(@as(usize, 481), deepest[0].members.len);
    try testing.expectEqualSlices(ChangeHash, &.{first[200]}, deepest[0].checkpoints);

    // A caller that interns an actor of its own grows the graph in the middle
    // and takes the empty slot away again. The fragments come back exactly as
    // they were, because `fragment_top` moved with the actors on the way in
    // and with them again on the way out.
    const stable = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, stable);
    try graph.insertActor(gpa, 1);
    try testing.expectEqual(@as(usize, 3), graph.numActors());
    try graph.removeActor(1);
    try testing.expectEqual(@as(usize, 2), graph.numActors());

    const moved = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, moved);
    try testing.expectEqual(stable.len, moved.len);
    for (stable, moved) |want, got| try expectSameFragment(want, got);
}

test "the cache one change at a time and a rebuild in node order agree" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();
    const graph = &b.graph;

    // Upstream's loader does not go through `add_change`, so it caches the
    // whole frontier in one pass over the nodes at the end
    // (`ChangeGraphCols::finalize`, `change_graph.rs:915-923`). Here
    // `addChange` caches as it goes and `cacheFragments` is that same pass,
    // so a graph built change by change and the same graph rebuilt have to
    // answer identically.
    var prev: ChangeHash = undefined;
    for (0..700) |i| {
        const level: usize = switch (i) {
            90, 330, 600 => 1,
            250, 400 => 2,
            else => 0,
        };
        prev = try b.changeAt(
            levelHash(@intCast(i + 1), level),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else &.{prev},
        );
    }

    const incremental = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, incremental);

    // Five fragment heads were built in — level 1 at nodes 90, 330 and 600,
    // level 2 at 250 and 400 — and three survive. The two level-2 heads stand
    // on each other and the level-1 head at 600 depends on both; the two
    // shallower ones are covered by a deeper fragment, so they are dropped
    // from the cache and answer nothing.
    var cached: [3]ChangeHash = undefined;
    var n: usize = 0;
    for (incremental) |fragment| {
        if (fragment.level == 0) continue;
        try testing.expect(n < cached.len);
        cached[n] = fragment.head;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expect(cached[0].eql(levelHash(601, 1)));
    try testing.expect(cached[1].eql(levelHash(401, 2)));
    try testing.expect(cached[2].eql(levelHash(251, 2)));
    try testing.expect(graph.hasChange(levelHash(91, 1)));
    try testing.expect(graph.hasChange(levelHash(331, 1)));
    try testing.expect((try graph.getFragment(gpa, levelHash(91, 1))) == null);
    try testing.expect((try graph.getFragment(gpa, levelHash(331, 1))) == null);

    try graph.cacheFragments(gpa);

    const rebuilt = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, rebuilt);
    try testing.expectEqual(incremental.len, rebuilt.len);
    for (incremental, rebuilt) |want, got| try expectSameFragment(want, got);

    // And the second rebuild changes nothing either, so rebuilding is not a
    // way to grow the cache.
    try graph.cacheFragments(gpa);
    const again = try graph.fragments(gpa, graph.getHeads(), .{});
    defer deinitFragments(gpa, again);
    for (rebuilt, again) |want, got| try expectSameFragment(want, got);
}

// ---------------------------------------------------------------------------
// Allocation-failure regressions
// ---------------------------------------------------------------------------
//
// A refused `insertActor`, `removeActor` or `addChange` has to leave the graph
// exactly as it was, and the only way to know that is to ask the graph the
// same questions afterwards and compare the answers. The instrument is
// `std.testing.FailingAllocator` and its `fail_index`, which counts successful
// allocations: arming it at `alloc_index + skip` lets `skip` of a mutation's
// own allocations through and refuses the next one, so walking `skip` upwards
// refuses every allocation the mutation makes in turn, and the attempt that
// refuses the last of them is the one that lands. [`storage/bundle.zig`](storage/bundle.zig)
// and [`hexane/slab.zig`](hexane/slab.zig) drive it the same way.
//
// Every one of these runs against a graph whose three caches have something
// in them, because a graph with empty caches cannot fail in a way that
// matters: there is nothing to renumber and nothing to supersede.

/// Everything a caller can read off a graph: the head set, the op clock at
/// those heads, every fragment they reach, and each node's hash and actor
/// next to the per-actor sequence numbers and op counters.
///
/// This is the whole of what a refused mutation must leave alone, and it is
/// read back through the public calls rather than out of the fields, so a
/// half-renumbered clock or a `fragment_top` that did not move shows up as a
/// different answer instead of as the same length.
const Snapshot = struct {
    heads: []ChangeHash,
    clock: Clock,
    fragments: []Fragment,
    hashes: []ChangeHash,
    actors: []ActorIdx,
    seqs: []u64,
    max_ops: []u64,
    max_op: u64,

    fn take(gpa: Allocator, graph: *ChangeGraph) Error!Snapshot {
        const heads = try gpa.dupe(ChangeHash, graph.getHeads());
        errdefer gpa.free(heads);
        var clock = try graph.clockAt(gpa, heads);
        errdefer clock.deinit();
        const fragments = try graph.fragments(gpa, heads, .{});
        errdefer deinitFragments(gpa, fragments);
        const hashes = try gpa.alloc(ChangeHash, graph.len());
        errdefer gpa.free(hashes);
        const actors = try gpa.alloc(ActorIdx, graph.len());
        errdefer gpa.free(actors);
        for (graph.nodes.items, 0..) |node, i| {
            hashes[i] = node.meta.hash;
            actors[i] = node.actor;
        }
        const seqs = try gpa.alloc(u64, graph.numActors());
        errdefer gpa.free(seqs);
        const max_ops = try gpa.alloc(u64, graph.numActors());
        errdefer gpa.free(max_ops);
        for (0..graph.numActors()) |slot| {
            const actor: ActorIdx = @intCast(slot);
            seqs[slot] = graph.seqForActor(actor);
            max_ops[slot] = graph.maxOpForActor(actor);
        }
        return .{
            .heads = heads,
            .clock = clock,
            .fragments = fragments,
            .hashes = hashes,
            .actors = actors,
            .seqs = seqs,
            .max_ops = max_ops,
            .max_op = graph.maxOp(),
        };
    }

    fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.hashes);
        gpa.free(self.actors);
        gpa.free(self.seqs);
        gpa.free(self.max_ops);
        self.clock.deinit();
        deinitFragments(gpa, self.fragments);
        gpa.free(self.heads);
        self.* = undefined;
    }
};

/// Two snapshots agree in every answer, not only in how much they hold.
fn expectSameSnapshot(want: Snapshot, got: Snapshot) !void {
    try testing.expectEqual(want.max_op, got.max_op);
    try testing.expectEqualSlices(ChangeHash, want.hashes, got.hashes);
    try testing.expectEqualSlices(ActorIdx, want.actors, got.actors);
    try testing.expectEqualSlices(ChangeHash, want.heads, got.heads);
    try testing.expectEqualSlices(u64, want.seqs, got.seqs);
    try testing.expectEqualSlices(u64, want.max_ops, got.max_ops);
    try testing.expectEqualSlices(u32, want.clock.values(), got.clock.values());
    try testing.expectEqual(want.fragments.len, got.fragments.len);
    for (want.fragments, got.fragments) |a, b| try expectSameFragment(a, b);
}

/// What a graph has to know about each actor slot, recomputed from the
/// changes it holds.
///
/// A slot's three numbers — how many changes are in it, the highest op
/// counter among them, and what [`clockAt`](ChangeGraph.clockAt) reports for
/// it — are all defined by the changes the slot contains, so this derives
/// them from `node.actor` and the metadata every node owns and reads none of
/// the graph's own per-slot tables.
///
/// That is what makes it a model rather than a second copy of the answer.
/// `seq_index` counts a slot's changes, `maxOpForActor` reads the last of
/// them, and the op clock is folded out of the node clock cache and
/// `fragment_top` by a walk: three routes to one answer that share no state.
/// A renumbering that moved the nodes without moving `seq_index`, or moved
/// the fragment clocks without moving the node clock cache, is perfectly
/// self-consistent and disagrees here.
const ActorTotals = struct {
    /// How many changes each slot holds, which is its next sequence number.
    seqs: []u64,
    /// The highest `max_op` among them, and zero for a slot holding none.
    max_ops: []u64,
    /// What `clockAt` has to report for each slot.
    clock: []u32,

    fn take(gpa: Allocator, graph: *const ChangeGraph) Error!ActorTotals {
        // A node's actor index is inside the slot table by construction: the
        // nodes and every table keyed by actor move in one breath, so an index
        // past the end is not a state a committed graph is in.
        const slots = graph.numActors();
        const seqs = try gpa.alloc(u64, slots);
        errdefer gpa.free(seqs);
        @memset(seqs, 0);
        const max_ops = try gpa.alloc(u64, slots);
        errdefer gpa.free(max_ops);
        @memset(max_ops, 0);
        const clock = try gpa.alloc(u32, slots);
        errdefer gpa.free(clock);
        @memset(clock, 0);
        for (graph.nodes.items) |node| {
            const slot: usize = node.actor;
            seqs[slot] += 1;
            max_ops[slot] = @max(max_ops[slot], node.meta.max_op);
            // Narrowed the way `clockAt` narrows. A counter a `u32` clock
            // cannot hold is one the document cannot clock at all.
            clock[slot] = @intCast(max_ops[slot]);
        }
        return .{ .seqs = seqs, .max_ops = max_ops, .clock = clock };
    }

    fn deinit(self: *ActorTotals, gpa: Allocator) void {
        gpa.free(self.seqs);
        gpa.free(self.max_ops);
        gpa.free(self.clock);
        self.* = undefined;
    }
};

/// Runs `mutate` with each of its allocations refused in turn, leaving the
/// last attempt — the one that allocates the whole way through — applied.
///
/// `check` is a value with a `check` method ([`SameGraphCheck`],
/// [`ActorMirrorCheck`]), run after every refusal and given what the check
/// needs to know. It allocates, so it runs with `fail_index` disarmed: a
/// check refused by the very failure it is reporting on would report nothing.
fn sweepRefusals(
    failing: *testing.FailingAllocator,
    b: *Builder,
    before: Snapshot,
    mutate: anytype,
    check: anytype,
) !void {
    const gpa = failing.allocator();
    var skip: usize = 0;
    while (true) {
        failing.fail_index = failing.alloc_index + skip;
        const outcome = @call(.auto, mutate, .{ b, gpa });
        // The check below allocates, and it has to be able to.
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try @call(.auto, @TypeOf(check).check, .{ b, gpa, before, check });
            skip += 1;
            // A mutation that never lands is a test that never ends. The
            // widest one here — adding a change that supersedes a cached
            // fragment — makes fewer allocations than this bound allows.
            if (skip > 256) return error.Fail;
        }
    }
    // A mutation that allocated nothing could not have been refused, and the
    // sweep would not have proved anything.
    try testing.expect(skip > 0);
}

/// The check the two refusals that need nothing more than "the graph is the
/// graph it was" run: every answer the snapshot takes, compared with the one
/// taken before the mutation.
const SameGraphCheck = struct {
    fn check(b: *Builder, gpa: Allocator, before: Snapshot, self: SameGraphCheck) !void {
        _ = self;
        var after = try Snapshot.take(gpa, &b.graph);
        defer after.deinit(gpa);
        try expectSameSnapshot(before, after);
    }
};

/// The check the interning sweep runs, which cannot be "the graph it was":
/// interning is monotone and a refusal part-way through two new actors leaves
/// the graph renumbered — but never wrong, because every actor's changes are
/// under the slot the table gives its bytes.
const ActorMirrorCheck = struct {
    /// A fragment head the fixture put in the cache, so the insertion had to
    /// renumber a cached fragment's clock and not only the node clock cache.
    cached_head: ChangeHash,

    fn check(
        b: *Builder,
        gpa: Allocator,
        before: Snapshot,
        self: ActorMirrorCheck,
    ) !void {
        _ = before;
        try expectActorMirrors(gpa, &b.graph, &b.authors, b.graph.getHeads(), self.cached_head);
    }
};

/// Every change `heads` reaches, as node indices, walked from the graph's own
/// edges.
///
/// Public calls only, and the point is to be a second opinion: the check below
/// asks the graph's per-actor tables and its clocks what they hold and
/// compares that against what its *nodes* say, and this is how the nodes in
/// scope are found without reading an index out of a table keyed by actor —
/// which is the thing under test.
fn coneNodes(
    gpa: Allocator,
    graph: *const ChangeGraph,
    heads: []const ChangeHash,
) Error!std.AutoHashMapUnmanaged(NodeIdx, void) {
    var seen: std.AutoHashMapUnmanaged(NodeIdx, void) = .empty;
    errdefer seen.deinit(gpa);
    var queue: std.ArrayList(NodeIdx) = .empty;
    defer queue.deinit(gpa);
    for (heads) |hash| {
        const idx = graph.hashToIndex(hash) orelse continue;
        if (seen.contains(idx)) continue;
        try seen.put(gpa, idx, {});
        try queue.append(gpa, idx);
    }
    // Indexed rather than iterated: the queue grows as it is walked, and a
    // `for` over its slice would keep reading the one it started with.
    var at: usize = 0;
    while (at < queue.items.len) : (at += 1) {
        // `parents` yields node indices, not hashes, so there is no lookup
        // to do here: the edge already names the node.
        var it = graph.parents(queue.items[at]);
        while (it.next()) |parent| {
            if (seen.contains(parent)) continue;
            try seen.put(gpa, parent, {});
            try queue.append(gpa, parent);
        }
    }
    return seen;
}

/// Every association a caller reaches by an actor's **bytes**, checked against
/// what the graph's own nodes say about that actor.
///
/// The graph stores actor *indices*; the actor table stores bytes. Every
/// answer below is per index, so every claim below is spelled with the bytes
/// and resolved through [`Authors.lookup`](author.zig) — a slot that moved, or
/// a slot that opened at the tail rather than where its actor sorts, is then a
/// claim about the wrong actor rather than a right number in the wrong place
/// that nothing notices.
///
/// Five answers, each read through the public surface and each compared with a
/// model that shares no state with it:
///
/// * every node's `actor` index is the one the table gives its own author
///   bytes, and every author is in the table;
/// * [`seqForActor`](ChangeGraph.seqForActor) and
///   [`maxOpForActor`](ChangeGraph.maxOpForActor) are the count and the
///   highest counter among that actor's changes;
/// * [`clockAt`](ChangeGraph.clockAt) reports the highest counter among the
///   changes of that actor *in the cone the heads reach*, and
///   [`Clock.contains`](clock.zig) agrees — this is the answer folded out of
///   the node clock cache and `fragment_top`, so it is what a rewrite that
///   missed a clock cannot give;
/// * [`opidToHash`](ChangeGraph.opidToHash) names that actor's own change for
///   every counter the change spans, and nothing for a counter past it;
/// * [`getFragment`](ChangeGraph.getFragment) still resolves a cached
///   fragment head, and every member of it is filed under the slot its author
///   bytes resolve to.
///
/// The graph and the table are the same length, which is the check that a
/// mirror has not drifted: an interning route that grew one without the other
/// reports the same count from `numActors()` as from `authors.count()` only
/// while both are still short.
fn expectActorMirrors(
    gpa: Allocator,
    graph: *ChangeGraph,
    authors: *const Authors,
    heads: []const ChangeHash,
    cached_head: ChangeHash,
) !void {
    const slots = authors.count();
    try testing.expectEqual(slots, graph.numActors());

    for (graph.nodes.items) |node| {
        const named = authors.lookup(node.meta.actor) orelse {
            std.debug.print("a change names an actor the table does not hold\n", .{});
            return error.Fail;
        };
        try testing.expectEqual(named, node.actor);
    }

    const seqs = try gpa.alloc(u64, slots);
    defer gpa.free(seqs);
    @memset(seqs, 0);
    const all_max = try gpa.alloc(u64, slots);
    defer gpa.free(all_max);
    @memset(all_max, 0);
    const cone_max = try gpa.alloc(u64, slots);
    defer gpa.free(cone_max);
    @memset(cone_max, 0);

    var cone = try coneNodes(gpa, graph, heads);
    defer cone.deinit(gpa);
    // The model, per slot, over the whole graph and over the cone the heads
    // reach. `coneNodes` answers a set of node indices, so what is looked up
    // is a node's own position and not its actor.
    var in_cone = try gpa.alloc(bool, graph.nodes.items.len);
    defer gpa.free(in_cone);
    @memset(in_cone, false);
    var nodes_in_cone = cone.iterator();
    while (nodes_in_cone.next()) |entry| in_cone[entry.key_ptr.*] = true;
    for (graph.nodes.items, 0..) |node, i| {
        seqs[node.actor] += 1;
        all_max[node.actor] = @max(all_max[node.actor], node.meta.max_op);
        if (in_cone[i]) cone_max[node.actor] = @max(cone_max[node.actor], node.meta.max_op);
    }

    var clock = try graph.clockAt(gpa, heads);
    defer clock.deinit();
    for (authors.values(), 0..) |actor, at| {
        const idx: ActorIdx = @intCast(at);
        try testing.expectEqual(seqs[at], graph.seqForActor(idx));
        try testing.expectEqual(all_max[at], graph.maxOpForActor(idx));
        try testing.expectEqual(@as(u32, @intCast(cone_max[at])), clock.slots[at]);
        if (cone_max[at] == 0) {
            // An actor the heads do not reach owns no counters, so the first
            // counter a change of its own could have written is not in it.
            try testing.expect(!clock.contains(.{ .actor = idx, .counter = 1 }));
        } else {
            try testing.expect(clock.contains(.{ .actor = idx, .counter = @as(u32, @intCast(cone_max[at])) }));
        }
        // Every op this actor wrote is found under this actor's index, and the
        // counter one past its last change is found under no change at all.
        for (graph.nodes.items) |node| {
            if (!node.meta.actor.eql(actor)) continue;
            try testing.expectEqual(idx, node.actor);
            var counter: u64 = node.meta.start_op;
            while (counter <= node.meta.max_op) : (counter += 1) {
                const owner = graph.opidToHash(.{
                    .actor = idx,
                    .counter = @as(u32, @intCast(counter)),
                }) orelse {
                    std.debug.print("op {d} of \"{s}\" names no change\n", .{ counter, actor.bytes });
                    return error.Fail;
                };
                try testing.expect(owner.eql(node.meta.hash));
            }
            if (node.meta.max_op == all_max[at]) {
                try testing.expect(graph.opidToHash(.{
                    .actor = idx,
                    .counter = @as(u32, @intCast(node.meta.max_op + 1)),
                }) == null);
            }
        }
    }

    // The cached fragment: its own clock is keyed by actor like the rest, so a
    // rewrite that left it behind shows up as a fragment cut by the wrong slot
    // rather than as a missing one. It still resolves, it is still a fragment
    // of this graph, and every change it lists is filed under the slot its
    // author bytes resolve to.
    var cached = (try graph.getFragment(gpa, cached_head)) orelse {
        std.debug.print("the cached fragment head no longer resolves\n", .{});
        return error.Fail;
    };
    defer cached.deinit(gpa);
    try expectFragmentInvariants(gpa, graph, &.{cached});
    for (cached.members) |hash| {
        const node = graph.nodeFor(hash) orelse return error.Fail;
        const named = authors.lookup(node.meta.actor) orelse return error.Fail;
        try testing.expectEqual(named, node.actor);
    }
}

/// The history the refusal tests run against: forty changes in one chain by
/// "b" with a level-1 fragment head at node 30, then one change by "z" on
/// top of it.
///
/// Forty is past two `cache_step` points, so the node clock cache holds two
/// entries for the rewrite to renumber. The level-1 head gives the fragment
/// cache an entry with a clock of its own and gives `fragment_top` something
/// to reach, so the loose-fragment walk stops at node 31 instead of running
/// to the root — a `fragment_top` left behind turns into a hundred extra
/// loose fragments rather than into a wrong count. And the second actor is
/// what makes an inserted slot land *between* two actors, which is the case
/// where a rewrite moves indices instead of only appending one.
fn buildRefusalFixture(b: *Builder) Error!struct {
    tip: ChangeHash,
    level_one: ChangeHash,
    /// The forty changes "b" wrote, in sequence order, so a check can name
    /// them by hash rather than only counting them.
    hashes: [40]ChangeHash,
} {
    var hashes: [40]ChangeHash = undefined;
    for (&hashes, 0..) |*slot, i| {
        slot.* = try b.changeAt(
            levelHash(@intCast(i + 1), if (i == 30) 1 else 0),
            "b",
            @intCast(i + 1),
            1,
            if (i == 0) &.{} else hashes[i - 1 .. i].ptr[0..1],
        );
    }
    const tip = try b.changeAt(levelHash(500_001, 0), "z", 1, 1, &.{hashes[39]});
    return .{ .tip = tip, .level_one = hashes[30], .hashes = hashes };
}

/// The mutation the insertion test refuses: an empty actor slot at index 1,
/// which the fixture has between "b" and "z", so every "z" index moves up.
fn insertMiddleActor(b: *Builder, gpa: Allocator) Error!void {
    try b.graph.insertActor(gpa, 1);
}

/// The mutation the change test refuses: a level-2 fragment head on the tip,
/// written by an actor the table already holds, so the only thing that can
/// refuse it is the graph's own bookkeeping. The hash is spelled out so that
/// every attempt is the same change, and the sequence number is read from the
/// graph so that a refused attempt asks for it again.
fn addLevelTwoHead(b: *Builder, gpa: Allocator) Error!void {
    const z = b.authors.lookup(.{ .bytes = "z" }) orelse return error.Fail;
    const meta: ChangeMetadata = .{
        .actor = .{ .bytes = "z" },
        .deps = b.graph.getHeads(),
        .hash = levelHash(500_002, 2),
        .time = 0,
        .message = "",
        .seq = b.graph.seqForActor(z) + 1,
        .start_op = 2,
        .max_op = 2,
        .other_actors = &.{},
    };
    try b.graph.addChange(gpa, &b.authors, meta);
}

/// The mutation the interning test refuses: a change whose author **and**
/// whose one other actor are both new, and both sort *inside* the fixture's
/// range — `"a"` before `"b"`, `"c"` between `"b"` and `"z"`.
///
/// That is the shape a retry cannot survive if the graph's slot is opened
/// after the table has been told. On the retry, interning is idempotent, so
/// the author is taken to be there already, no slot is opened for it, and the
/// remap the *second* insertion produces is indexed against a table whose
/// earlier entries the graph never applied: `"b"`'s forty changes stay filed
/// under the index `"a"` now owns. Nothing notices — `numActors()` still
/// equals `authors.count()` — so every answer keyed by actor index is about
/// the wrong actor.
///
/// Both new actors are spelled out rather than discovered from the graph, so
/// every attempt is byte for byte the same change and a refusal never leaves
/// the attempt after it asking for something else.
fn addNewAuthorHead(b: *Builder, gpa: Allocator) Error!void {
    const meta: ChangeMetadata = .{
        .actor = .{ .bytes = "a" },
        .deps = b.graph.getHeads(),
        .hash = levelHash(600_001, 0),
        .time = 0,
        .message = "",
        .seq = 1,
        .start_op = 41,
        .max_op = 41,
        .other_actors = &.{.{ .bytes = "c" }},
    };
    try b.graph.addChange(gpa, &b.authors, meta);
}

test "a refused actor insertion leaves every clock, mirror and fragment where it was" {
    // A real allocator through a counter: `fail_index` is never armed until
    // the sweep, and the graph is built with the same allocator it is asked
    // to allocate from, as `deinit` requires.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var b = Builder.init(gpa);
    defer b.deinit();

    const fixture = try buildRefusalFixture(&b);
    var before = try Snapshot.take(gpa, &b.graph);
    defer before.deinit(gpa);

    try sweepRefusals(&failing, &b, before, insertMiddleActor, SameGraphCheck{});

    // The slot that landed is empty and every "z" index moved up one, so the
    // actors are "b" at 0, the new one at 1 and "z" at 2. That is a claim
    // about the changes and not about an array of indices, so it is asked of
    // the changes: the one "z" wrote is now in slot 2, the change it sits on
    // — written by "b" — is still in slot 0, and the level-one fragment head
    // further down the chain has not moved either. An index the rewrite moved
    // without the change behind it fails all three.
    const tip_idx = b.graph.hashToIndex(fixture.tip).?;
    const tip = b.graph.nodeAt(tip_idx).?;
    try testing.expect(tip.meta.actor.eql(.{ .bytes = "z" }));
    try testing.expectEqual(@as(ActorIdx, 2), tip.actor);
    var under_tip = b.graph.parents(tip_idx);
    const under = b.graph.nodeAt(under_tip.next().?).?;
    try testing.expect(under.meta.actor.eql(.{ .bytes = "b" }));
    try testing.expectEqual(@as(ActorIdx, 0), under.actor);
    try testing.expectEqual(@as(ActorIdx, 0), b.graph.nodeFor(fixture.level_one).?.actor);

    var after = try Snapshot.take(gpa, &b.graph);
    defer after.deinit(gpa);

    // Nothing is in the slot that opened, and every number the graph keeps per
    // slot is the one the changes in that slot imply: the forty changes "b"
    // wrote still count forty, "z"'s one change still counts one, and the
    // empty slot between them counts nothing. The op clock is folded out of
    // the node clock cache and `fragment_top`, so it is the answer only a
    // rewrite of every clock keyed by actor can give.
    try testing.expectEqual(@as(usize, 3), b.graph.numActors());
    try testing.expectEqual(@as(u64, 0), b.graph.seqForActor(1));
    try testing.expectEqual(@as(u64, 0), b.graph.maxOpForActor(1));
    for (b.graph.nodes.items) |node| {
        const slot: ActorIdx = if (node.meta.actor.eql(.{ .bytes = "b" })) 0 else 2;
        try testing.expectEqual(slot, node.actor);
    }
    var totals = try ActorTotals.take(gpa, &b.graph);
    defer totals.deinit(gpa);
    try testing.expectEqualSlices(u32, totals.clock, after.clock.values());
    try testing.expectEqualSlices(u64, totals.seqs, after.seqs);
    try testing.expectEqualSlices(u64, totals.max_ops, after.max_ops);
    try testing.expectEqualSlices(ChangeHash, before.hashes, after.hashes);
    try testing.expectEqualSlices(ChangeHash, before.heads, after.heads);
    try testing.expectEqual(before.max_op, after.max_op);
    // A fragment is named by hashes and cut by clocks, so the fragments
    // themselves are the same list: the loose ones still stop at the cached
    // frontier, and the cached one still reaches node 30.
    try testing.expectEqual(before.fragments.len, after.fragments.len);
    for (before.fragments, after.fragments) |want, got| try expectSameFragment(want, got);

    // And taking the slot away again brings every answer back, which is the
    // other half of the claim: the rewrite moved the clocks rather than
    // leaving a second copy of the truth behind.
    try b.graph.removeActor(1);
    var restored = try Snapshot.take(gpa, &b.graph);
    defer restored.deinit(gpa);
    try expectSameSnapshot(before, restored);
}

test "a refused actor removal changes nothing either" {
    const gpa = testing.allocator;
    var b = Builder.init(gpa);
    defer b.deinit();

    _ = try buildRefusalFixture(&b);
    var fixture = try Snapshot.take(gpa, &b.graph);
    defer fixture.deinit(gpa);

    try b.graph.insertActor(gpa, 1);
    var before = try Snapshot.take(gpa, &b.graph);
    defer before.deinit(gpa);

    // Neither refusal may have moved an index: a slot past the end, and a slot
    // that still holds changes. Both are decided before the first index moves,
    // which is all `removeActor` can refuse — it allocates nothing.
    try testing.expectError(error.InvalidIndex, b.graph.removeActor(3));
    try testing.expectError(error.InvalidIndex, b.graph.removeActor(2));
    var refused = try Snapshot.take(gpa, &b.graph);
    defer refused.deinit(gpa);
    try expectSameSnapshot(before, refused);

    // The empty slot is the one that goes, and every answer comes back to the
    // one the fixture had before the insertion.
    try b.graph.removeActor(1);
    var taken = try Snapshot.take(gpa, &b.graph);
    defer taken.deinit(gpa);
    try expectSameSnapshot(fixture, taken);
}

test "a refused change leaves the graph, its heads and its fragments where they were" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var b = Builder.init(gpa);
    defer b.deinit();

    const fixture = try buildRefusalFixture(&b);
    var before = try Snapshot.take(gpa, &b.graph);
    defer before.deinit(gpa);
    // The fragment the change below supersedes is in the cache to be
    // superseded, and the snapshot holds it for as long as it is.
    var level_one = (try b.graph.getFragment(gpa, fixture.level_one)).?;
    defer level_one.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), level_one.level);

    try sweepRefusals(&failing, &b, before, addLevelTwoHead, SameGraphCheck{});

    var after = try Snapshot.take(gpa, &b.graph);
    defer after.deinit(gpa);

    // The attempt that landed is the deeper fragment: it supersedes the
    // level-1 head, which now answers nothing, and it stands on nothing
    // because the level-1 head it covers was its only cached dependency.
    try testing.expect((try b.graph.getFragment(gpa, fixture.level_one)) == null);
    var deepest = (try b.graph.getFragment(gpa, levelHash(500_002, 2))).?;
    defer deepest.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), deepest.level);
    try testing.expectEqualSlices(ChangeHash, &.{}, deepest.boundary);
    try testing.expectEqualSlices(ChangeHash, &.{fixture.level_one}, deepest.checkpoints);

    // Its members are every change the graph holds, the head that was just
    // added included, compared hash by hash rather than counted. Nothing
    // stopped the walk below the level-1 head: it was superseded rather than
    // depended on, so the new fragment has no boundary to stop at and no
    // cached fragment to stand on. A member list of this length holding any
    // hash other than these is the same number and not the same fragment.
    var members = try memberSet(gpa, &.{deepest});
    defer members.deinit(gpa);
    try testing.expectEqual(before.hashes.len + 1, members.count());
    for (before.hashes) |hash| try testing.expect(members.contains(hash));
    try testing.expect(members.contains(levelHash(500_002, 2)));
    try expectFragmentInvariants(gpa, &b.graph, &.{deepest});

    // The graph is the fixture's history with exactly one change on top of
    // it, and that change is the only head.
    try testing.expectEqualSlices(ChangeHash, before.hashes, after.hashes[0..before.hashes.len]);
    try testing.expect(after.hashes[after.hashes.len - 1].eql(levelHash(500_002, 2)));
    try testing.expectEqualSlices(ChangeHash, &.{levelHash(500_002, 2)}, after.heads);
    try testing.expectEqual(before.max_op, after.max_op);

    // Every per-slot number is the one the changes in that slot imply: forty
    // changes by "b" ending at op 40, and two by "z" ending at the op this
    // change wrote. The op clock is folded out of the node clock cache and
    // `fragment_top` over the heads, so it has to name both.
    var totals = try ActorTotals.take(gpa, &b.graph);
    defer totals.deinit(gpa);
    try testing.expectEqualSlices(u64, totals.seqs, after.seqs);
    try testing.expectEqualSlices(u64, totals.max_ops, after.max_ops);
    try testing.expectEqualSlices(u32, totals.clock, after.clock.values());
    try testing.expect(after.clock.contains(.{ .actor = 0, .counter = 40 }));
    try testing.expect(after.clock.contains(.{ .actor = 1, .counter = 2 }));

    // Nothing is loose any more: the head is a cached fragment, so the whole
    // history is its members and the frontier has moved up with it.
    try testing.expectEqual(@as(usize, 1), after.fragments.len);
    try expectSameFragment(deepest, after.fragments[0]);
    try testing.expectEqual(@as(ActorIdx, 1), b.graph.nodeFor(fixture.tip).?.actor);
}

test "a refused change whose author and other actors are new leaves the author table and every mirror where they were" {
    // A real allocator through a counter, as the two refusals above: never armed
    // until the sweep, and the same allocator the graph is built with.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var b = Builder.init(gpa);
    defer b.deinit();

    const fixture = try buildRefusalFixture(&b);
    var before = try Snapshot.take(gpa, &b.graph);
    defer before.deinit(gpa);
    // The fragment the two insertions have to renumber the clock of, held
    // across the sweep so the fragment that comes out the far side is compared
    // with the one that went in rather than only counted.
    const level_one = fixture.level_one;
    var held_level_one = (try b.graph.getFragment(gpa, level_one)).?;
    defer held_level_one.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), held_level_one.level);

    // The two actors are new **and** both sort inside the fixture's range, so
    // neither insertion appends: the author's slot belongs before "b" and the
    // other's between "b" and "z", and every existing index moves.
    try sweepRefusals(
        &failing,
        &b,
        before,
        addNewAuthorHead,
        ActorMirrorCheck{ .cached_head = level_one },
    );

    const new_hash = levelHash(600_001, 0);

    // The attempt that landed wrote the change, and the table is the one order
    // four actors can be in: "a" sorted ahead of "b", "c" between "b" and "z".
    try testing.expectEqual(@as(usize, 4), b.authors.count());
    try testing.expectEqual(@as(usize, 4), b.graph.numActors());
    const order = [_][]const u8{ "a", "b", "c", "z" };
    for (order, 0..) |bytes, at| {
        const slot: ActorIdx = @intCast(at);
        const in_table = b.authors.at(slot) orelse {
            std.debug.print("no actor at index {d}\n", .{at});
            return error.Fail;
        };
        try testing.expectEqualStrings(bytes, in_table.bytes);
        try testing.expectEqual(slot, b.authors.lookup(.{ .bytes = bytes }).?);
    }
    const a = b.authors.lookup(.{ .bytes = "a" }).?;
    const bee = b.authors.lookup(.{ .bytes = "b" }).?;
    const c = b.authors.lookup(.{ .bytes = "c" }).?;
    const z = b.authors.lookup(.{ .bytes = "z" }).?;
    try testing.expectEqualSlices(ActorIdx, &.{ 0, 1, 2, 3 }, &.{ a, bee, c, z });

    // Per-slot numbers, asked by the actor's bytes rather than by the slot: the
    // forty changes "b" wrote still count forty under **its** index, the one
    // change "z" wrote still counts one under **its** index, the new actor has
    // its one change, and "c" — referenced by the change and written by nobody
    // — holds nothing.
    try testing.expectEqual(@as(u64, 1), b.graph.seqForActor(a));
    try testing.expectEqual(@as(u64, 40), b.graph.seqForActor(bee));
    try testing.expectEqual(@as(u64, 0), b.graph.seqForActor(c));
    try testing.expectEqual(@as(u64, 1), b.graph.seqForActor(z));
    try testing.expectEqual(@as(u64, 41), b.graph.maxOpForActor(a));
    try testing.expectEqual(@as(u64, 40), b.graph.maxOpForActor(bee));
    try testing.expectEqual(@as(u64, 0), b.graph.maxOpForActor(c));
    try testing.expectEqual(@as(u64, 1), b.graph.maxOpForActor(z));

    // The op clock at the new head, which is folded out of the node clock cache
    // and `fragment_top` — two of the structures the insertions renumbered — and
    // so answers about the old actors only if all of them did.
    var clock = try b.graph.clockAt(gpa, b.graph.getHeads());
    defer clock.deinit();
    try testing.expectEqualSlices(u32, &.{ 41, 40, 0, 1 }, clock.values());
    try testing.expect(clock.contains(.{ .actor = a, .counter = 41 }));
    try testing.expect(clock.contains(.{ .actor = bee, .counter = 40 }));
    try testing.expect(clock.contains(.{ .actor = z, .counter = 1 }));
    try testing.expect(!clock.contains(.{ .actor = c, .counter = 1 }));

    // `opidToHash` names the exact change that owns each op, asked through the
    // index the actor's bytes resolve to. A slot opened at the tail rather than
    // where its actor sorts answers with another actor's changes here.
    const own = b.graph.opidToHash(.{ .actor = a, .counter = 41 }) orelse return error.Fail;
    try testing.expect(own.eql(new_hash));
    const last_of_b = b.graph.opidToHash(.{ .actor = bee, .counter = 40 }) orelse return error.Fail;
    try testing.expect(last_of_b.eql(fixture.hashes[39]));
    const first_of_b = b.graph.opidToHash(.{ .actor = bee, .counter = 1 }) orelse return error.Fail;
    try testing.expect(first_of_b.eql(fixture.hashes[0]));
    const of_z = b.graph.opidToHash(.{ .actor = z, .counter = 1 }) orelse return error.Fail;
    try testing.expect(of_z.eql(fixture.tip));
    // An actor the graph has no change from owns no ops at all.
    try testing.expect(b.graph.opidToHash(.{ .actor = c, .counter = 1 }) == null);

    // And the changes themselves are filed under the index their own author
    // bytes resolve to, which is the invariant every number above rests on.
    try testing.expectEqual(a, b.graph.nodeFor(new_hash).?.actor);
    try testing.expectEqual(bee, b.graph.nodeFor(fixture.hashes[0]).?.actor);
    try testing.expectEqual(bee, b.graph.nodeFor(fixture.hashes[39]).?.actor);
    try testing.expectEqual(z, b.graph.nodeFor(fixture.tip).?.actor);

    // The cached fragment survived both insertions: a level-1 head still
    // resolves out of the cache, and its own clock — keyed by actor, rewritten
    // twice — still cuts it where the history does.
    var cached = (try b.graph.getFragment(gpa, level_one)) orelse {
        std.debug.print("the level-1 fragment head no longer resolves\n", .{});
        return error.Fail;
    };
    defer cached.deinit(gpa);
    try expectSameFragment(held_level_one, cached);

    // Every change the level-1 fragment still names is filed under the slot its
    // author bytes resolve to, which is the same claim the sweep made after
    // each refusal and now holds for the state that landed.
    for (cached.members) |hash| {
        const node = b.graph.nodeFor(hash) orelse return error.Fail;
        try testing.expectEqual(bee, node.actor);
        try testing.expect(node.meta.actor.eql(.{ .bytes = "b" }));
    }

    // The whole history is the new head's fragment list, one member per change
    // and every member under its own author's slot: the fixture's forty-one
    // changes plus this one.
    const landed = try b.graph.fragments(gpa, b.graph.getHeads(), .{});
    defer deinitFragments(gpa, landed);
    var members = try memberSet(gpa, landed);
    defer members.deinit(gpa);
    try testing.expectEqual(before.hashes.len + 1, members.count());
    try testing.expect(members.contains(new_hash));
    for (before.hashes) |hash| try testing.expect(members.contains(hash));
}

// ── Diff against the reference, for the actor-insertion route ───────────────
//
// | Zig 0.16.0 | upstream | Rust | port | does not / is / this |
// | --- | --- | --- | --- | --- |
// | `addChange(gpa, authors, meta)` resolves the change's actor by interning it | `ChangeGraph::add_change`, `change_graph.rs:545-583` | `fn add_changes<'a, I: Iterator<Item = (&'a Change, usize)> + ExactSizeIterator + Clone>(&mut self, iter: I, authors: &mut Authors) -> Result<(), MissingDep>` | `pub fn addChange(self: *ChangeGraph, gpa: Allocator, authors: *Authors, meta: ChangeMetadata) Error!void` | **does not** take the `actor_index` its caller resolved. Upstream's `usize` is the `binary_search(...).expect(...)` over `ops.actors` (`automerge.rs:1290-1294`), so upstream's graph has **one** actor-insertion route and this file has **two** |
// | `internActors` + `internActor` + `applyActorInsert` | — | — | — | **are** that second route, and **do** reach two of the five mirrors: `authors` and `seq_index`. `OpSet.actors`, `actor_authors` and `Actor::Cached` **are not** in scope here, so an actor interned on this path grows two tables alone — but it grows both or neither, because `internActor` reserves the graph's slot **before** `authors.intern` is allowed to publish the actor, which is the ordering a retry depends on and the only thing that makes the retry's idempotent path harmless |
// | `growActorSlots(gpa, count)` | `seq_index: vec![vec![]; num_actors]`, `change_graph.rs:102` | sized from `doc.actors().len()` (`:929`) before a change is linked | appends empty slots until `seq_index.items.len == authors.count()` | **is** sized from another mirror rather than from the authoritative table, which upstream never does: a table whose length **is** the actor count **does not** have to catch up with one that is not. It can only append, so it is right for actors interned ahead of the graph that sort after its slots and wrong for one that sorts between them; a refusal can no longer leave the table ahead of the graph, so this route is reached only by a caller that interned without a change |
// | `insertActor` / `removeActor` | `insert_actor` / `remove_actor`, `change_graph.rs:151-186` | rewrite `self.actors`, every cached clock, every fragment clock and `fragment_top`, then `seq_index.insert(idx, vec![])` | rewrite `node.actor`, every cached clock, every `FragmentNode.clock` and `fragment_top`, then `seq_index.insert` at `idx`; `removeActor` refuses a slot that still holds a node, where upstream `assert!`s | **are** one mirror each. The fan-out is [`Document.insertActor`](doc.zig) and [`Document.removeActor`](doc.zig), which **do** reach all five |
// | `Fragment`, `LevelRange`, `getFragment`, `fragments`, `looseCommit`, `looseFragments`, `fragmentContent`, `ClockBfs`, `cacheFragment`, `cacheFragments`, `FragmentNode`, `fragment_top` | `change_graph.rs:45-46`, `:162-165`, `:580`, `:585-706`, `:1731-1775` | the fragment cache and `fragment_top`, which ten of upstream's twelve `#[test]`s exercise (`change_graph.rs:1230-1648`) | `pub fn getFragment(self: *const ChangeGraph, gpa, head) Error!?Fragment`, `pub fn fragments(self: *const ChangeGraph, gpa, heads, levels: LevelRange) Error![]Fragment`, the rest private | **are** ported, with three deliberate differences. (1) `LevelRange` is `[start, end)` because upstream's `RangeBounds` has an inclusive spelling this port's ranges do not: `0..=0` is `.{ .end = 1 }` and `1..` is `.{ .start = 1 }`. (2) `fragments` returns an owned slice rather than an iterator, and `Fragment` owns its three arrays, because every call allocates and a lazy iterator over a borrowed graph cannot own them. (3) `getFragment` and `fragments` take `*const`; the only mutation they cause is the walk scratch, which upstream also reaches through an `&self` receiver and a local `BTreeSet` (`change_graph.rs:833`), so [`mutable`](ChangeGraph.mutable) casts exactly that and nothing else |
// | `cacheFragments(gpa)` | `cache_fragments`, `change_graph.rs:677-681` | one pass over `0..len`, called once by `ChangeGraphCols::finalize` over a graph the columnar loader built **without** `add_change`, so the cache is empty when it runs | discards the cache and re-runs the same pass | **is** the rebuild form rather than the fill form. Every node in this port arrives through `addChange`, which caches as it goes (`change_graph.rs:580`), so upstream's call site has no equivalent here; what the call site guaranteed is that the load path's frontier is the one the add path would have built, and the test `the cache one change at a time and a rebuild in node order agree` is what holds this port to it |
// | `Automerge::bundle(hashes)` | `automerge.rs:1141` | the change bytes for a hash list, which is what a `Fragment` exists to carve up | — | **is not** in this file. Upstream's last two fragment tests (`change_graph.rs:1560-1641`) go through `bundle`, so they belong with [`Document.bundle`](doc.zig) rather than with the graph: they are a test of the bundle codec's input ordering, not of a fragment |
// | `stageActorInsert` / `commitActorInsert`, `stageClockGrowth`, `stageCache` / `commitCache`, `stageFragment` / `commitFragment`, `pendingConeClock` | — | — | the `rewrite_with_new_actor` loop of `change_graph.rs:153-165`, the `clock_cache.insert(node_idx, clock.clone())` of `:740`, the `fragments.remove` / `fragments.push` of `:701-705` and the `calculate_clock` of `:817-825`, each of which upstream runs in one breath with the state it rewrites | the same rewrites, with every allocation they need made first and the rewrite itself infallible | **are** the port's, and the difference is not a preference: upstream's allocator cannot refuse, so an insertion stopped half way through that loop is not a state it can reach. Here it is, and a graph whose nodes are renumbered while two of its four clocks still name the old actors answers `clock_at`, `get_fragment` and `fragments` differently without any error anywhere — which is why the cone a change needs is folded (`pendingConeClock`) before the change is linked and installed after it |
