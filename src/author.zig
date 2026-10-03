//! The per-document actor table.
//!
//! Every actor id a document has ever seen is stored once, in this table,
//! sorted by the lexicographic order of its bytes. Everything else in the
//! engine names an actor by its `ActorIdx` into this table and never by its
//! bytes: the op set's actor columns, the change graph's per-actor columns,
//! the patch log, and the change encoder. The order is not an implementation
//! detail, it is the format. The change encoder writes the actor list in table
//! order and refers to later operations by index, so a table ordered by
//! anything but byte-lexicographic order produces different change hashes and
//! unreadable documents (`docs/survey/01-core-api.md:1637-1642`; upstream
//! `types.rs:39-45` derives `Ord` over the bytes and warns about exactly this,
//! upstream `automerge.rs:1309-1321` binary-searches the table).
//!
//! Three consequences shape this file:
//!
//! * Inserting an actor shifts every index above it, so every stored index in
//!   the document has to be rewritten. `insertAt` and `removeAt` therefore
//!   hand back a remap; the table never reorders itself behind the caller's
//!   back. Upstream does the same rewrite in each per-actor column
//!   (`op_set2/op_set.rs:1400-1428`, `change_graph.rs:151-186`,
//!   `clock.rs:22-33`) and `Automerge::insert_actor` fans one insertion out to
//!   all four of them (`automerge.rs:1301-1306`).
//! * The bytes are copied into the table's arena, so an actor interned from a
//!   scratch buffer outlives that buffer and the whole table is released by one
//!   `deinit`.
//! * Upstream's `put_actor_ref` returns the index of an actor that is already
//!   in the table rather than failing (`automerge.rs:1309-1314`), so
//!   interning is idempotent here too. Interning twice is not an error, it is
//!   how a peer re-announces an actor this document already has.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;

/// A document's actors, kept sorted by their bytes so an actor's index is
/// stable and the change encoder can order actors without a lookup. Every
/// stored reference to an actor is its index into this table, never its bytes.
pub const Authors = struct {
    /// The allocator this table allocates from. As with `std.ArrayList`, every
    /// `gpa` argument passed to a method must be this allocator, because
    /// `deinit` frees with it.
    gpa: Allocator,
    /// The actors' bytes. `intern` copies an actor here, so a caller may pass
    /// bytes it frees immediately afterwards. Nothing is ever reclaimed
    /// individually: a removed actor's bytes stay in the arena until `deinit`.
    arena: std.heap.ArenaAllocator,
    /// The actors, strictly ascending by `ActorId.order`. Every lookup is a
    /// binary search over this slice, so the invariant is load-bearing.
    items: std.ArrayList(ActorId),
    /// The mapping produced by the last `insertAt` or `removeAt`, owned by the
    /// table. See `remap`.
    remap_buf: std.ArrayList(ActorIdx),

    /// The `remap` entry for an actor that no longer exists. Only a removal
    /// produces one, and only for the actor that was removed.
    pub const no_index: ActorIdx = std.math.maxInt(ActorIdx);

    /// An empty table. `gpa` must be the allocator every later call passes.
    pub fn init(gpa: Allocator) Authors {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .items = .empty,
            .remap_buf = .empty,
        };
    }

    /// Releases the actor bytes, the table, and the last remap in one call.
    ///
    /// The allocator passed to [`init`](Authors.init) is not released here.
    /// The table and every [`ActorId`](types.zig) it handed out are unusable
    /// afterwards; the value is poisoned, so a second call — including one
    /// through a copy — is a double free with no diagnostic in any mode.
    pub fn deinit(self: *Authors) void {
        self.items.deinit(self.gpa);
        self.remap_buf.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Adds `actor` to the table if it is not there, and returns its index.
    ///
    /// An actor already in the table yields its existing index and the table
    /// is left untouched, which is what `put_actor_ref` does upstream
    /// (`automerge.rs:1309-1314`). A new actor is inserted at the position
    /// the binary search gives, so the order holds, and `remap` is set for
    /// the rewrite of every stored index above it.
    pub fn intern(self: *Authors, gpa: Allocator, actor: ActorId) Error!ActorIdx {
        const slot = self.search(actor);
        if (slot.found) return @intCast(slot.idx);
        const idx = try self.insert(gpa, slot.idx, actor);
        return @intCast(idx);
    }

    /// The index of `actor`, or null when the table does not have it.
    pub fn lookup(self: Authors, actor: ActorId) ?ActorIdx {
        const slot = self.search(actor);
        if (!slot.found) return null;
        return @intCast(slot.idx);
    }

    /// The bytes for an index, or null when the index is out of range. The
    /// returned id borrows the table's arena, not the caller's buffer.
    pub fn at(self: Authors, idx: ActorIdx) ?ActorId {
        const i: usize = idx;
        if (i >= self.items.items.len) return null;
        return self.items.items[i];
    }

    /// The number of actors. Indices are `ActorIdx`, so a caller comparing an
    /// index against the count must cast.
    pub fn count(self: Authors) usize {
        return self.items.items.len;
    }

    /// Every actor, in index order. The slice is a copy the caller owns and
    /// frees; the bytes it points at belong to the table and die with it.
    pub fn list(self: Authors, gpa: Allocator) Error![]ActorId {
        const out = try gpa.alloc(ActorId, self.items.items.len);
        errdefer gpa.free(out);
        @memcpy(out, self.items.items);
        return out;
    }

    /// Every actor, in index order, borrowed from the table. Valid until the
    /// next mutating call, which may reallocate or reorder the slice.
    pub fn values(self: Authors) []const ActorId {
        return self.items.items;
    }

    /// Inserts a new actor at `idx`, shifting indices at or above it up, and
    /// records the mapping old index -> new index so stored references can be
    /// rewritten. Required when a remote change introduces an actor that
    /// sorts before an existing one.
    ///
    /// `idx` must be the position the binary search gives for `actor`; a
    /// position that would leave the table unsorted is rejected rather than
    /// silently accepted, because the order is the format. Returns
    /// `error.DuplicateActorId` if the actor is already in the table and
    /// `error.InvalidIndex` if `idx` is past the end or out of order.
    pub fn insertAt(self: *Authors, gpa: Allocator, idx: ActorIdx, actor: ActorId) Error!void {
        const i: usize = idx;
        _ = try self.insert(gpa, i, actor);
    }

    /// Reserves room in the remap buffer for one entry per actor in the table
    /// as it stands, so a following [`removeAt`](Authors.removeAt) at any
    /// valid index allocates nothing.
    ///
    /// **Call this before mutating anything that must be rolled back.** A
    /// caller that removes an actor from the change graph and the op set and
    /// only then removes it from this table has to unwind both when the third
    /// step fails, and an unwind that cannot itself allocate is the only one
    /// that is safe to write. This is the staging half of that sequence, and
    /// it pairs with [`removeAt`](Authors.removeAt) the way
    /// [`SeqClock.reserveNewActor`](clock.zig) pairs with
    /// [`SeqClock.rewriteWithNewActor`](clock.zig). It is the only fallible
    /// step, and it leaves the table unchanged.
    pub fn reserveRemap(self: *Authors, gpa: Allocator) !void {
        try self.remap_buf.ensureTotalCapacity(gpa, self.items.items.len);
    }

    /// Removes the actor at `idx`, shifting indices above it down, and records
    /// the mapping old index -> new index. The caller must not have any stored
    /// reference to `idx`: upstream asserts the same thing when it drops an
    /// actor from the op set (`op_set2/op_set.rs:1419-1428`), because an op
    /// that still named the actor would silently retarget another actor.
    ///
    /// Returns `error.InvalidIndex` when `idx` is not an index of the table.
    ///
    /// **After [`reserveRemap`](Authors.reserveRemap) this call allocates
    /// nothing and its only remaining refusal is `error.InvalidIndex`**, so a
    /// caller that validated the index may treat that tag as unreachable. A
    /// removal that has already renamed indices elsewhere in the document
    /// should reserve first; see [`reserveRemap`](Authors.reserveRemap).
    ///
    /// The table is unchanged on either refusal.
    pub fn removeAt(self: *Authors, gpa: Allocator, idx: ActorIdx) Error!void {
        const i: usize = idx;
        const n = self.items.items.len;
        if (i >= n) return error.InvalidIndex;

        try self.remap_buf.ensureTotalCapacity(gpa, n);
        self.remap_buf.clearRetainingCapacity();
        for (0..n) |old| {
            const to: ActorIdx = if (old < i)
                @intCast(old)
            else if (old == i)
                no_index
            else
                @intCast(old - 1);
            try self.remap_buf.append(gpa, to);
        }
        _ = self.items.orderedRemove(i);
    }

    /// The mapping from old to new index produced by the last `insertAt` or
    /// `removeAt`, as a slice owned by the table. It is empty until the first
    /// such call and is replaced by the next one.
    ///
    /// After an insertion at `idx` of a table that held `n` actors, the slice
    /// has `n + 1` entries: entry `old` is the new index of the actor that was
    /// at `old`, and the last entry, `remap(n)`, is the index of the actor
    /// that was just inserted. After a removal at `idx`, the slice has one
    /// entry per former actor, and `remap(idx)` is `no_index` because that
    /// actor is gone.
    pub fn remap(self: Authors) []const ActorIdx {
        return self.remap_buf.items;
    }

    /// Where `actor` is, or where it would go. This is the shape upstream
    /// consumes: `Ok(idx) => idx, Err(idx) => insert_actor(idx, actor)`
    /// (`automerge.rs:1309-1321`).
    fn search(self: Authors, actor: ActorId) struct { idx: usize, found: bool } {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (ActorId.order(self.items.items[mid], actor)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .idx = mid, .found = true },
            }
        }
        return .{ .idx = lo, .found = false };
    }

    /// The shared body of `intern` and `insertAt`: check the position, copy
    /// the bytes, record the remap, insert.
    ///
    /// The remap is filled before the table changes, so a table and its remap
    /// never disagree, and the only fallible step after that is the insert
    /// itself, which cannot fail once the capacity is reserved.
    fn insert(self: *Authors, gpa: Allocator, idx: usize, actor: ActorId) Error!usize {
        const n = self.items.items.len;
        if (idx > n or idx > std.math.maxInt(ActorIdx)) return error.InvalidIndex;
        if (self.search(actor).found) return error.DuplicateActorId;
        // Sorted strictly ascending, so a position is valid exactly when the
        // actor fits strictly between its neighbours.
        if (idx > 0 and ActorId.order(self.items.items[idx - 1], actor) != .lt) {
            return error.InvalidIndex;
        }
        if (idx < n and ActorId.order(actor, self.items.items[idx]) != .lt) {
            return error.InvalidIndex;
        }

        const arena_alloc = self.arena.allocator();
        const bytes = try arena_alloc.dupe(u8, actor.bytes);

        try self.items.ensureUnusedCapacity(gpa, 1);
        try self.remap_buf.ensureTotalCapacity(gpa, n + 1);
        self.remap_buf.clearRetainingCapacity();
        for (0..n) |old| {
            const to: ActorIdx = if (old < idx) @intCast(old) else @intCast(old + 1);
            try self.remap_buf.append(gpa, to);
        }
        try self.remap_buf.append(gpa, @intCast(idx));

        try self.items.insert(gpa, idx, .{ .bytes = bytes });
        return idx;
    }
};

/// The actors a test uses. Deliberately includes the empty id and ids that are
/// prefixes of one another, so the expected order pins down byte-lexicographic
/// comparison rather than length-first or insertion-order comparison.
const test_actors = [_][]const u8{
    "", "\x00\x00", "00", "0f", "0f00", "a", "a0", "aa", "aab", "ab", "b", "ff",
};

/// `test_actors` in the order a byte-lexicographic table must hold them.
const sorted_actors = [_][]const u8{
    "",   "\x00\x00", "00", "0f", "0f00", "a", "a0",
    "aa", "aab",      "ab", "b",  "ff",
};

fn expectSortedTable(table: Authors) !void {
    const v = table.values();
    for (v, 0..) |actor, i| {
        if (i == 0) continue;
        try std.testing.expect(ActorId.order(v[i - 1], actor) == .lt);
    }
}

/// The table holds `bytes` at `idx`. Reports the index rather than unwrapping
/// a null, so a failure names the index that is wrong.
fn expectActorAt(table: Authors, idx: ActorIdx, bytes: []const u8) !void {
    const actor = table.at(idx) orelse {
        std.debug.print("no actor at index {d}\n", .{idx});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings(bytes, actor.bytes);
}

/// The table holds `expected` at `idx`.
fn expectActorIs(table: Authors, idx: ActorIdx, expected: ActorId) !void {
    try expectActorAt(table, idx, expected.bytes);
}

test "intern keeps the table sorted whatever order actors arrive in" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const rand = prng.random();

    // A fixed shuffle, so a failure is reproducible.
    var order: [test_actors.len]usize = undefined;
    for (&order, 0..) |*slot, i| slot.* = i;
    for (1..order.len) |i| {
        const j = rand.uintLessThan(usize, i + 1);
        const tmp = order[i];
        order[i] = order[j];
        order[j] = tmp;
    }
    // The shuffle must actually reorder, or the test proves nothing.
    try std.testing.expect(!std.mem.eql(usize, &order, &order_init()));

    for (order) |i| {
        const bytes = test_actors[i];
        const idx = try table.intern(gpa, .{ .bytes = bytes });
        // The actor just interned sits at the index intern returned, and the
        // table is sorted after every single insertion. The full order is
        // checked once every actor is in.
        try expectSortedTable(table);
        try expectActorIs(table, idx, .{ .bytes = bytes });
        try std.testing.expect(table.lookup(.{ .bytes = bytes }).? == idx);
    }

    try std.testing.expectEqual(test_actors.len, table.count());
    for (sorted_actors, 0..) |bytes, i| {
        try expectActorAt(table, @intCast(i), bytes);
        try std.testing.expectEqual(@as(ActorIdx, @intCast(i)), table.lookup(.{ .bytes = bytes }).?);
    }
    // Everything is in the table, so every lookup above found the one entry.
    for (test_actors) |bytes| {
        try std.testing.expect(table.lookup(.{ .bytes = bytes }) != null);
    }
}

fn order_init() [test_actors.len]usize {
    var init: [test_actors.len]usize = undefined;
    for (&init, 0..) |*slot, i| slot.* = i;
    return init;
}

test "interning a known actor returns its index and adds no entry" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    const b = try table.intern(gpa, .{ .bytes = "0f" });
    const c = try table.intern(gpa, .{ .bytes = "a" });
    // "0f" sorts before "a", so the first actor interned is not the first.
    try std.testing.expectEqual(@as(ActorIdx, 0), b);
    try std.testing.expectEqual(@as(ActorIdx, 1), c);
    const before = table.count();

    const again = try table.intern(gpa, .{ .bytes = "0f" });
    try std.testing.expectEqual(b, again);
    try std.testing.expectEqual(before, table.count());
    try expectSortedTable(table);
    try expectActorAt(table, again, "0f");

    // insertAt refuses to add the same actor a second time, which is the bug
    // the idempotent interning above is there to prevent.
    try std.testing.expectError(
        error.DuplicateActorId,
        table.insertAt(gpa, 2, .{ .bytes = "0f" }),
    );
    try std.testing.expectEqual(before, table.count());
}

test "lookup misses an unknown actor and at is out of range safe" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    try std.testing.expectEqual(@as(?ActorIdx, null), table.lookup(.{ .bytes = "a" }));
    try std.testing.expect(table.at(0) == null);

    _ = try table.intern(gpa, .{ .bytes = "a" });
    _ = try table.intern(gpa, .{ .bytes = "c" });
    try std.testing.expect(table.at(0) != null);
    try std.testing.expect(table.at(1) != null);
    try std.testing.expect(table.at(2) == null);
    try std.testing.expect(table.at(std.math.maxInt(ActorIdx)) == null);
    // Sorts between "a" and "c", and after "c", so none of these are known.
    try std.testing.expect(table.lookup(.{ .bytes = "b" }) == null);
    try std.testing.expect(table.lookup(.{ .bytes = "d" }) == null);
    try std.testing.expect(table.lookup(.{ .bytes = "aa" }) == null);
    try std.testing.expect(table.lookup(.{ .bytes = "A" }) == null);
    try std.testing.expect(table.lookup(.{ .bytes = "" }) == null);
}

test "interned bytes are copied out of the caller's buffer" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    var scratch = [_]u8{ 'a', 'b' };
    const idx = try table.intern(gpa, .{ .bytes = &scratch });
    scratch = .{ 'z', 'z' };
    // The table owns the bytes it interned; it does not borrow the scratch
    // buffer the caller happened to have.
    try expectActorAt(table, idx, "ab");
    try std.testing.expectEqual(@as(ActorIdx, idx), table.lookup(.{ .bytes = "ab" }).?);
    try std.testing.expect(table.lookup(.{ .bytes = "zz" }) == null);
}

test "insertAt in the middle shifts the indices above it" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    _ = try table.intern(gpa, .{ .bytes = "a" });
    _ = try table.intern(gpa, .{ .bytes = "c" });
    _ = try table.intern(gpa, .{ .bytes = "d" });
    const before = try table.list(gpa);
    defer gpa.free(before);

    try table.insertAt(gpa, 1, .{ .bytes = "b" });
    try expectSortedTable(table);
    try std.testing.expectEqual(@as(usize, 4), table.count());
    try expectActorAt(table, 0, "a");
    try expectActorAt(table, 1, "b");
    try expectActorAt(table, 2, "c");
    try expectActorAt(table, 3, "d");

    // Every stored reference follows its actor: the remap sends old index 0 to
    // 0, and old indices 1 and 2 up by one, and names the new actor.
    const remap = table.remap();
    try std.testing.expectEqual(before.len + 1, remap.len);
    for (before, 0..) |actor, old| {
        const to: usize = remap[old];
        try expectActorIs(table, @intCast(to), actor);
    }
    try std.testing.expectEqual(@as(ActorIdx, 1), remap[before.len]);
    try expectActorAt(table, remap[before.len], "b");
}

test "insertAt at the end appends and moves nothing" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    _ = try table.intern(gpa, .{ .bytes = "a" });
    _ = try table.intern(gpa, .{ .bytes = "b" });
    try table.insertAt(gpa, 2, .{ .bytes = "c" });

    try expectSortedTable(table);
    try std.testing.expectEqual(@as(usize, 3), table.count());
    const remap = table.remap();
    try std.testing.expectEqual(@as(usize, 3), remap.len);
    try std.testing.expectEqual(@as(ActorIdx, 0), remap[0]);
    try std.testing.expectEqual(@as(ActorIdx, 1), remap[1]);
    try std.testing.expectEqual(@as(ActorIdx, 2), remap[2]);

    // A table with room for an insertion is the same code path.
    var empty_table = Authors.init(gpa);
    defer empty_table.deinit();
    try empty_table.insertAt(gpa, 0, .{ .bytes = "z" });
    try std.testing.expectEqual(@as(usize, 1), empty_table.count());
    try expectActorAt(empty_table, 0, "z");
}

test "insertAt rejects a position that would break the order" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    _ = try table.intern(gpa, .{ .bytes = "b" });
    _ = try table.intern(gpa, .{ .bytes = "d" });
    const before = table.count();

    // Past the end of the table.
    try std.testing.expectError(error.InvalidIndex, table.insertAt(gpa, 3, .{ .bytes = "c" }));
    try std.testing.expectError(error.InvalidIndex, table.insertAt(gpa, 9, .{ .bytes = "c" }));
    // "c" belongs at 1. Anywhere else leaves the table unsorted, which would
    // break every later binary search.
    try std.testing.expectError(error.InvalidIndex, table.insertAt(gpa, 0, .{ .bytes = "c" }));
    try std.testing.expectError(error.InvalidIndex, table.insertAt(gpa, 2, .{ .bytes = "c" }));
    try std.testing.expectEqual(before, table.count());
    try expectSortedTable(table);
}

test "removeAt shifts the indices above it down" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    _ = try table.intern(gpa, .{ .bytes = "a" });
    _ = try table.intern(gpa, .{ .bytes = "b" });
    _ = try table.intern(gpa, .{ .bytes = "c" });
    _ = try table.intern(gpa, .{ .bytes = "d" });
    const before = try table.list(gpa);
    defer gpa.free(before);

    try table.removeAt(gpa, 1);
    try expectSortedTable(table);
    try std.testing.expectEqual(@as(usize, 3), table.count());
    try expectActorAt(table, 0, "a");
    try expectActorAt(table, 1, "c");
    try expectActorAt(table, 2, "d");
    try std.testing.expect(table.lookup(.{ .bytes = "b" }) == null);

    const remap = table.remap();
    try std.testing.expectEqual(before.len, remap.len);
    for (before, 0..) |actor, old| {
        if (old == 1) {
            // The removed actor has no new index.
            try std.testing.expectEqual(Authors.no_index, remap[old]);
            continue;
        }
        const to: usize = remap[old];
        try expectActorIs(table, @intCast(to), actor);
    }

    try std.testing.expectError(error.InvalidIndex, table.removeAt(gpa, 3));
    try std.testing.expectError(error.InvalidIndex, table.removeAt(gpa, std.math.maxInt(ActorIdx)));
    try std.testing.expectEqual(@as(usize, 3), table.count());
}

test "random inserts and removals keep the order, the remap, and the lookups" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    var prng = std.Random.DefaultPrng.init(0x00c0ffee);
    const rand = prng.random();

    var insertions: usize = 0;
    var removals: usize = 0;
    var repeats: usize = 0;
    for (0..400) |_| {
        const before = try table.list(gpa);
        defer gpa.free(before);
        try expectSortedTable(table);

        if (before.len > 0 and rand.boolean()) {
            const victim = rand.uintLessThan(usize, before.len);
            try table.removeAt(gpa, @intCast(victim));
            removals += 1;

            const remap = table.remap();
            try std.testing.expectEqual(before.len, remap.len);
            try std.testing.expectEqual(before.len - 1, table.count());
            for (before, 0..) |actor, old| {
                if (old == victim) {
                    try std.testing.expectEqual(Authors.no_index, remap[old]);
                    continue;
                }
                const to: usize = remap[old];
                try expectActorIs(table, @intCast(to), actor);
            }
            try std.testing.expect(table.lookup(before[victim]) == null);
            continue;
        }

        // An actor id built on the stack, so the table cannot be borrowing it.
        var scratch: [2]u8 = .{ 0, 0 };
        const key = rand.uintLessThan(u32, 64);
        scratch[0] = @truncate(key >> 3);
        scratch[1] = @truncate(key);
        const len: usize = if (rand.boolean()) 1 else 2;
        const actor = ActorId.init(scratch[0..len]);
        const known = table.lookup(actor);
        const idx = try table.intern(gpa, actor);

        if (known) |was| {
            repeats += 1;
            try std.testing.expectEqual(was, idx);
            try std.testing.expectEqual(before.len, table.count());
            continue;
        }
        insertions += 1;
        try std.testing.expectEqual(before.len + 1, table.count());

        const remap = table.remap();
        try std.testing.expectEqual(before.len + 1, remap.len);
        for (before, 0..) |old_actor, old| {
            const to: usize = remap[old];
            try expectActorIs(table, @intCast(to), old_actor);
        }
        // The new actor took the slot between its neighbours, and the table
        // still holds every actor it had.
        try std.testing.expectEqual(idx, remap[before.len]);
        try expectActorIs(table, idx, actor);
        for (before) |old_actor| {
            try std.testing.expect(table.lookup(old_actor) != null);
        }
    }

    try std.testing.expect(insertions > 0);
    try std.testing.expect(removals > 0);
    try std.testing.expect(repeats > 0);
    try expectSortedTable(table);
}

test "list returns an owned copy the caller frees" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    const empty_list = try table.list(gpa);
    defer gpa.free(empty_list);
    try std.testing.expectEqual(@as(usize, 0), empty_list.len);

    _ = try table.intern(gpa, .{ .bytes = "b" });
    _ = try table.intern(gpa, .{ .bytes = "a" });
    const listed = try table.list(gpa);
    defer gpa.free(listed);
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqualStrings("a", listed[0].bytes);
    try std.testing.expectEqualStrings("b", listed[1].bytes);

    // The list is the caller's: freeing it does not disturb the table, and the
    // table's actor bytes outlive any list taken from it.
    try std.testing.expectEqual(@as(usize, 2), table.count());
    try expectActorAt(table, 0, "a");
}

test "a removal after reserveRemap allocates nothing" {
    const gpa = std.testing.allocator;
    var table = Authors.init(gpa);
    defer table.deinit();

    _ = try table.intern(gpa, .{ .bytes = "a" });
    _ = try table.intern(gpa, .{ .bytes = "b" });
    _ = try table.intern(gpa, .{ .bytes = "c" });

    // The caller removes an actor from the change graph and the op set before
    // it removes it here, and the unwind of those two must not be able to
    // fail. `failing_allocator` refuses every allocation, so the removal
    // below can only succeed if `reserveRemap` left the room it needed.
    try table.reserveRemap(gpa);
    try table.removeAt(std.testing.failing_allocator, 1);

    try expectActorAt(table, 0, "a");
    try expectActorAt(table, 1, "c");
    try expectSortedTable(table);
    const remap = table.remap();
    try std.testing.expectEqual(@as(usize, 3), remap.len);
    try std.testing.expectEqual(@as(ActorIdx, 0), remap[0]);
    try std.testing.expectEqual(Authors.no_index, remap[1]);
    try std.testing.expectEqual(@as(ActorIdx, 1), remap[2]);
}
