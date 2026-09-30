//! Vector clocks.
//!
//! A clock is one `u32` per actor, indexed by the actor's position in the
//! document's actor table: entry `i` is the highest op counter this document
//! has seen from actor `i`. Two clocks compare elementwise, which is what
//! decides whether a change is already applied, whether a peer has seen a
//! change, and what to send next.
//!
//! Both clock types keep the whole allocation in one field and the live length
//! in another. Shrinking a clock is a decrement, and `deinit` frees exactly
//! what was allocated.
//!
//! ## `include`, `merge`, `covers` — and the fourth name
//!
//! These three are **three operations, not two names for one**.
//!
//! * [`Clock.include`] and [`SeqClock.include`] are a *mutation*: they raise
//!   one actor's high-water mark and answer whether it moved. Upstream's is
//!   `SeqClock::include` (`clock.rs:38-54`), and the dense `Clock` has no such
//!   method outside its own test module (`clock.rs:175-182`) — this port keeps
//!   one because the tests and [`Clock.merge`] both need to build a clock.
//! * [`Clock.merge`] and [`SeqClock.merge`] are a *mutation*: the elementwise
//!   maximum, upstream `SeqClock::merge` (`clock.rs:56-62`).
//! * [`Clock.covers`] and [`SeqClock.covers`] are a *predicate*: is every entry
//!   of the other clock at or below this one. Upstream's is
//!   `SeqClock::covers` (`clock.rs:64-71`).
//!
//! So `include` and `covers` are not the same relation under two names, and the
//! port should not pretend they are: including an op into a clock and asking
//! whether a clock contains it are a write and a read, and only the second one
//! is reflexive.
//!
//! **The one place two names do cover the same relation** is
//! [`Clock.contains`], which is upstream's `Clock::covers(&OpId)`
//! (`clock.rs:134-136`) under this port's name, because the port's
//! `Clock.covers` is a clock covering another clock. There is one predicate
//! there and not two; `opset/op.zig:494-497` says so where it is used.
//!
//! ## What `covers` answers when the clocks are different lengths
//!
//! An entry past the end of a clock is zero, or null for [`SeqClock`], because
//! that is what [`Clock.get`] and [`SeqClock.get`] already answer for an actor
//! a clock has never heard of. Upstream's `SeqClock::covers` instead asserts the
//! two clocks are the same length and panics when they are not
//! (`clock.rs:65`); its dense counterpart exists only inside the test module,
//! where `is_greater` truncates to the shorter clock (`clock.rs:184-186`). This
//! port answers instead of panicking, and reads the missing entries as the
//! unknown actor they are, so `covers` cannot disagree with `contains` about the
//! same actor. For the equal-length case — the only one upstream admits — the
//! answer is identical either way.

const std = @import("std");
const types = @import("types.zig");

const ActorIdx = types.ActorIdx;
const OpId = types.OpId;

/// A vector clock: the highest op counter seen from each actor.
pub const Clock = struct {
    /// The whole allocation. The live entries are `[0..len]`.
    slots: []u32,
    len: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, size: usize) !Clock {
        const slots = try gpa.alloc(u32, size);
        @memset(slots, 0);
        return .{ .slots = slots, .len = size, .gpa = gpa };
    }

    pub fn initEmpty(gpa: std.mem.Allocator) Clock {
        return .{ .slots = &.{}, .len = 0, .gpa = gpa };
    }

    pub fn deinit(self: *Clock) void {
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn clone(self: Clock) !Clock {
        const slots = try self.gpa.dupe(u32, self.slots);
        return .{ .slots = slots, .len = self.len, .gpa = self.gpa };
    }

    pub fn values(self: Clock) []const u32 {
        return self.slots[0..self.len];
    }

    /// Grows the clock to `size`, filling new entries with zero.
    pub fn ensureSize(self: *Clock, size: usize) !void {
        if (size <= self.len) return;
        if (size <= self.slots.len) {
            @memset(self.slots[self.len..size], 0);
            self.len = size;
            return;
        }
        const grown = try self.gpa.alloc(u32, size);
        @memset(grown, 0);
        @memcpy(grown[0..self.len], self.slots[0..self.len]);
        self.gpa.free(self.slots);
        self.slots = grown;
        self.len = size;
    }

    /// The counter recorded for `actor`, or zero when the actor is unknown.
    pub fn get(self: Clock, actor: ActorIdx) u32 {
        if (actor >= self.len) return 0;
        return self.slots[actor];
    }

    /// Marks `actor` as covered to its end, so every operation that actor has
    /// made is inside the clock however high its counter is
    /// ([`Clock::isolate`](../../github-automerge-automerge/rust/automerge/src/clock.rs):120-122,
    /// `self.set_counter_of(actor_index, u32::MAX)`).
    ///
    /// **This is what makes an isolation writable, and it is not a detail.**
    /// `Automerge::isolate_actor` marks the clock it hands the transaction
    /// ([`automerge.rs:1266`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    /// so that the operations the isolated transaction is about to write —
    /// which are in no change at `heads`, and so in no clock at `heads` — are
    /// in scope for the transaction that writes them. `isolate(&[])` is the
    /// case that needs it most: its clock is empty, and without the mark every
    /// object in the isolated document is out of scope from the **second**
    /// transaction onwards.
    ///
    /// The clock grows to hold `actor` first, which is upstream's
    /// `resize(actor + 1, 0)` behind `set_counter_of`.
    pub fn isolate(self: *Clock, actor: ActorIdx) !void {
        try self.ensureSize(@as(usize, actor) + 1);
        self.slots[actor] = std.math.maxInt(u32);
    }

    /// Records `counter` for `actor`. Returns true when the clock advanced.
    ///
    /// Counter zero never advances a clock, and an actor outside the clock
    /// cannot be advanced at all: both are the head sentinel and the actor
    /// table saying so, and upstream stores the counter in a `NonZeroU32`
    /// (`clock.rs:42`) that cannot hold zero in the first place.
    pub fn include(self: *Clock, actor: ActorIdx, counter: u32) bool {
        if (actor >= self.len) return false;
        // Counter zero is the head sentinel and never advances a clock.
        if (counter == 0) return false;
        if (self.slots[actor] < counter) {
            self.slots[actor] = counter;
            return true;
        }
        return false;
    }

    /// `a.merge(b)` makes `a` the elementwise maximum. Aliasing is allowed.
    ///
    /// **Only the actors both clocks have.** Upstream zips
    /// (`clock.rs:57`), so a receiver keeps its own length and its own tail,
    /// and an actor past the end of the operand contributes nothing. That is
    /// the same truncation the other clock types rely on, and a port that grew
    /// the receiver instead would make the length of a clock mean something
    /// different from the actor table it indexes.
    pub fn merge(a: *Clock, b: Clock) void {
        const n = @min(a.len, b.len);
        for (a.slots[0..n], b.slots[0..n]) |*x, y| {
            if (x.* < y) x.* = y;
        }
    }

    /// True when every entry of `other` is at or below `self`. A clock covers
    /// itself, which is the smallest case and the one a strict or an off-by-one
    /// reading of the comparison gets wrong first.
    ///
    /// **An entry past the end of either clock is zero**, which is the answer
    /// [`get`](Clock.get) already gives for an actor the clock has never heard
    /// of, and the answer [`contains`](Clock.contains) reads it through. The
    /// alternative — refusing a comparison of two clocks of different lengths —
    /// would make `covers` disagree with both of those on the same actor, which
    /// is the one thing a clock comparison must not do.
    pub fn covers(self: Clock, other: Clock) bool {
        const n = @max(self.len, other.len);
        for (0..n) |i| {
            const mine: u32 = if (i < self.len) self.slots[i] else 0;
            const theirs: u32 = if (i < other.len) other.slots[i] else 0;
            if (mine < theirs) return false;
        }
        return true;
    }

    pub fn eql(a: Clock, b: Clock) bool {
        return a.len == b.len and std.mem.eql(u32, a.slots, b.slots);
    }

    /// True when `id` is at or below the clock's entry for its actor, meaning
    /// the document already contains it.
    pub fn contains(self: Clock, id: OpId) bool {
        return self.get(id.actor) >= id.counter;
    }
};

/// A sparse vector clock: null means "this actor has not been seen", which
/// lets a clock be built before the actor table is complete.
pub const SeqClock = struct {
    /// The whole allocation. The live entries are `[0..len]`.
    slots: []?u32,
    len: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, size: usize) !SeqClock {
        const slots = try gpa.alloc(?u32, size);
        @memset(slots, null);
        return .{ .slots = slots, .len = size, .gpa = gpa };
    }

    pub fn initEmpty(gpa: std.mem.Allocator) SeqClock {
        return .{ .slots = &.{}, .len = 0, .gpa = gpa };
    }

    pub fn deinit(self: *SeqClock) void {
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn clone(self: SeqClock) !SeqClock {
        const slots = try self.gpa.dupe(?u32, self.slots);
        return .{ .slots = slots, .len = self.len, .gpa = self.gpa };
    }

    pub fn values(self: SeqClock) []const ?u32 {
        return self.slots[0..self.len];
    }

    /// Grows the clock to `size`, filling the new entries with null.
    pub fn ensureSize(self: *SeqClock, size: usize) !void {
        if (size <= self.len) return;
        try self.reserve(size);
        self.resizeNoFail(size);
    }

    /// Reserves room for `size` entries, so that an
    /// [`ensureSize`](SeqClock.ensureSize) to `size` after it cannot fail.
    /// Nothing live moves and no entry past the end is initialized: the
    /// resize that follows is what writes those.
    ///
    /// This is the staging half of a rewrite that has to move several clocks
    /// together — a graph renaming an actor rewrites its whole clock cache,
    /// every cached fragment and `fragment_top` in one breath. Reserve on all
    /// of them and only then resize them, and the one allocation a refusal
    /// can come from leaves every one of them as it was. The dense
    /// [`Clock`] has no such pair because no caller of it rewrites more than
    /// one clock per allocation.
    pub fn reserve(self: *SeqClock, size: usize) !void {
        if (size <= self.slots.len) return;
        const grown = try self.gpa.alloc(?u32, size);
        @memcpy(grown[0..self.len], self.slots[0..self.len]);
        self.gpa.free(self.slots);
        self.slots = grown;
    }

    /// Grows the live length to `size`, filling the new entries with null.
    /// Entries below `len` do not move. The caller must have reserved room
    /// for `size` entries, so this cannot fail.
    pub fn resizeNoFail(self: *SeqClock, size: usize) void {
        if (size <= self.len) return;
        std.debug.assert(size <= self.slots.len);
        @memset(self.slots[self.len..size], null);
        self.len = size;
    }

    pub fn get(self: SeqClock, actor: ActorIdx) ?u32 {
        if (actor >= self.len) return null;
        return self.slots[actor];
    }

    /// Records `counter` for `actor` when it advances the clock.
    pub fn include(self: *SeqClock, actor: ActorIdx, counter: u32) bool {
        if (actor >= self.len) return false;
        if (counter == 0) return false;
        if (self.slots[actor]) |old| {
            if (old >= counter) return false;
        }
        self.slots[actor] = counter;
        return true;
    }

    /// Drops an actor, shifting the indices above it down.
    pub fn removeActor(self: *SeqClock, idx: ActorIdx) void {
        if (idx >= self.len) return;
        std.mem.copyForwards(?u32, self.slots[idx .. self.len - 1], self.slots[idx + 1 .. self.len]);
        self.len -= 1;
        self.slots[self.len] = null;
    }

    /// Reserves room for the empty entry
    /// [`rewriteWithNewActor`](SeqClock.rewriteWithNewActor) inserts.
    ///
    /// Reserve on every clock a rewrite touches and only then rewrite them:
    /// an insert that had to allocate half way through a rewrite of several
    /// clocks is what leaves half of them renumbered and the other half
    /// naming the old actors.
    pub fn reserveNewActor(self: *SeqClock) !void {
        try self.reserve(self.len + 1);
    }

    /// Inserts an empty entry at `idx`, shifting indices at or above it up.
    ///
    /// This is upstream's `rewrite_with_new_actor`, a `Vec::insert` of
    /// `None` (`clock.rs:26-28`), where `idx == self.len` is the
    /// `Vec::insert` that appends. **It cannot fail, and that is why it is
    /// separate from [`reserveNewActor`](SeqClock.reserveNewActor)**: the
    /// entry an append lands on is written here rather than read, so spare
    /// capacity needs nothing prepared, and the shift that is not an append
    /// moves only live entries.
    pub fn rewriteWithNewActor(self: *SeqClock, idx: ActorIdx) void {
        std.debug.assert(self.len < self.slots.len);
        self.slots[self.len] = null;
        self.len += 1;
        if (idx >= self.len) return;
        std.mem.copyBackwards(?u32, self.slots[idx + 1 ..], self.slots[idx .. self.len - 1]);
        self.slots[idx] = null;
    }

    pub fn merge(a: *SeqClock, b: SeqClock) void {
        const n = @min(a.len, b.len);
        for (a.slots[0..n], b.slots[0..n]) |*x, y| {
            if (y) |v| {
                if (x.* == null or x.*.? < v) x.* = v;
            }
        }
    }

    /// True when every entry of `other` is covered by `self`. Unlike `Clock`, a
    /// null in `other` is always covered and a null in `self` covers nothing.
    ///
    /// **An entry past the end of either clock is null**, for the same reason
    /// [`get`](SeqClock.get) answers null there: the actor is outside the
    /// clock, and upstream's `get_for_actor` is a `get` that flattens
    /// (`clock.rs:30-32`), so an out-of-range index and a `None` entry are one
    /// case and not two.
    ///
    /// Upstream asserts the two clocks are the same length before comparing
    /// them (`clock.rs:65`) and panics when they are not. This returns an
    /// answer instead, because a parser that panics on a length is a parser
    /// that can be made to panic. For the equal-length case — the only one
    /// upstream admits — the answer is identical.
    pub fn covers(self: SeqClock, other: SeqClock) bool {
        const n = @max(self.len, other.len);
        for (0..n) |i| {
            const theirs: ?u32 = if (i < other.len) other.slots[i] else null;
            const want = theirs orelse continue; // upstream's `(_, None)`
            const mine: ?u32 = if (i < self.len) self.slots[i] else null;
            const have = mine orelse return false; // upstream's `(None, Some(_))`
            if (have < want) return false; // upstream's `(Some, Some) => s1 >= s2`
        }
        return true;
    }
};

/// Which view of history a read sees.
pub const ClockRange = union(enum) {
    /// No heads: the document's current state.
    current: ?Clock,
    /// A past state: `before` is the state, `after` is the clock it was
    /// computed against.
    diff: struct { before: Clock, after: Clock },

    pub fn now() ClockRange {
        return .{ .current = null };
    }

    pub fn at(clock: Clock) ClockRange {
        return .{ .current = clock };
    }
};

test "Clock records and covers" {
    const gpa = std.testing.allocator;
    var c = try Clock.init(gpa, 3);
    defer c.deinit();

    try std.testing.expect(c.include(1, 5));
    try std.testing.expect(!c.include(1, 3));
    try std.testing.expectEqual(@as(u32, 5), c.get(1));
    // An unknown actor reads as zero and cannot be advanced.
    try std.testing.expectEqual(@as(u32, 0), c.get(9));
    try std.testing.expect(!c.include(9, 1));
    // Zero never advances a clock: counter zero is the head sentinel.
    try std.testing.expect(!c.include(0, 0));

    try std.testing.expect(c.contains(.{ .counter = 5, .actor = 1 }));
    try std.testing.expect(!c.contains(.{ .counter = 6, .actor = 1 }));
}

test "Clock merge and covers" {
    const gpa = std.testing.allocator;
    var a = try Clock.init(gpa, 2);
    defer a.deinit();
    var b = try Clock.init(gpa, 2);
    defer b.deinit();

    _ = a.include(0, 3);
    _ = b.include(1, 7);
    a.merge(b);
    try std.testing.expectEqual(@as(u32, 3), a.get(0));
    try std.testing.expectEqual(@as(u32, 7), a.get(1));
    try std.testing.expect(a.covers(b));
    try std.testing.expect(!b.covers(a));
}

test "Clock grow and clone" {
    const gpa = std.testing.allocator;
    var c = try Clock.init(gpa, 1);
    defer c.deinit();
    _ = c.include(0, 2);
    try c.ensureSize(4);
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqual(@as(u32, 2), c.get(0));
    try std.testing.expectEqual(@as(u32, 0), c.get(3));

    var d = try c.clone();
    defer d.deinit();
    try std.testing.expect(c.eql(d));
    try c.ensureSize(9);
    try std.testing.expectEqual(@as(usize, 9), c.len);
}

test "SeqClock treats zero as absent" {
    const gpa = std.testing.allocator;
    var c = try SeqClock.init(gpa, 3);
    defer c.deinit();

    try std.testing.expect(c.get(0) == null);
    try std.testing.expect(c.include(2, 4));
    try std.testing.expectEqual(@as(?u32, 4), c.get(2));
    try std.testing.expect(!c.include(2, 1));
    try std.testing.expect(c.include(2, 9));

    // An empty clock covers nothing but itself.
    var empty = try SeqClock.init(gpa, 3);
    defer empty.deinit();
    try std.testing.expect(!empty.covers(c));
    try std.testing.expect(c.covers(empty));
}

test "SeqClock actor insert and removal" {
    const gpa = std.testing.allocator;
    var c = try SeqClock.init(gpa, 2);
    defer c.deinit();
    _ = c.include(0, 1);
    _ = c.include(1, 2);

    try c.reserveNewActor();
    c.rewriteWithNewActor(0);
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expect(c.get(0) == null);
    try std.testing.expectEqual(@as(?u32, 1), c.get(1));
    try std.testing.expectEqual(@as(?u32, 2), c.get(2));

    c.removeActor(0);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqual(@as(?u32, 1), c.get(0));
    try std.testing.expectEqual(@as(?u32, 2), c.get(1));
}

test "SeqClock insert at the end and clone" {
    const gpa = std.testing.allocator;
    var c = try SeqClock.init(gpa, 1);
    defer c.deinit();
    _ = c.include(0, 5);
    try c.reserveNewActor();
    c.rewriteWithNewActor(1);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqual(@as(?u32, 5), c.get(0));
    try std.testing.expect(c.get(1) == null);

    var d = try c.clone();
    defer d.deinit();
    _ = d.include(0, 9);
    try std.testing.expectEqual(@as(?u32, 5), c.get(0));
    try std.testing.expectEqual(@as(?u32, 9), d.get(0));
}

test "SeqClock inserts into a clock that owns nothing yet" {
    const gpa = std.testing.allocator;
    // A zero-length clock has no spare capacity at all, so this is the
    // realloc path of `reserveNewActor` and the entry the insert lands on is
    // the one `rewriteWithNewActor` wrote.
    var c = try SeqClock.init(gpa, 0);
    defer c.deinit();
    try c.reserveNewActor();
    c.rewriteWithNewActor(0);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expect(c.get(0) == null);
    try c.reserveNewActor();
    c.rewriteWithNewActor(1);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expect(c.get(1) == null);
}

// ── the three operations, as properties ─────────────────────────────────────
//
// The tests above answer questions about single calls. The ones below answer
// questions about the operations as a whole, which is where a clock is wrong in
// a way no single call shows: `merge` that is not commutative still merges two
// clocks correctly, `covers` that is not reflexive still covers everything
// below it, and neither defect appears in a test that checks one actor at a
// time.

/// The seed the merge and cover sweeps read. Printed in every failure message,
/// because a law that failed on round 3187 and cannot be re-run is a law that
/// cannot be fixed.
const merge_seed: u64 = 0x5EED_C10C_1E;

/// A [`Clock`] with these entries, in actor order. A zero entry is not "no
/// actor": it is an actor the document has never heard of.
fn clockOf(gpa: std.mem.Allocator, entries: []const u32) !Clock {
    var c = try Clock.init(gpa, entries.len);
    errdefer c.deinit();
    for (entries, 0..) |v, i| _ = c.include(@intCast(i), v);
    return c;
}

/// The [`SeqClock`] counterpart of [`clockOf`]. A null entry is written through
/// a zero counter, which `include` refuses, so it stays empty — which is what a
/// null means.
fn seqClockOf(gpa: std.mem.Allocator, entries: []const ?u32) !SeqClock {
    var c = try SeqClock.init(gpa, entries.len);
    errdefer c.deinit();
    for (entries, 0..) |v, i| _ = c.include(@intCast(i), v orelse 0);
    return c;
}

/// A counter from the generator: zero often enough that the sweeps meet clocks
/// with gaps in them, small values often enough that two clocks collide, and
/// large values often enough that the maximum is sometimes already in place.
fn randomCounter(rand: std.Random) u32 {
    return switch (rand.int(u8) % 4) {
        0 => 0,
        1 => rand.intRangeAtMost(u32, 1, 8),
        2 => rand.int(u32),
        else => rand.intRangeAtMost(u32, 1, 100_000),
    };
}

/// Report a merge law that did not hold, with everything needed to replay it.
fn reportMergeLaw(
    what: []const u8,
    seed: u64,
    a: []const u32,
    b: []const u32,
    c: []const u32,
    left: []const u32,
    right: []const u32,
) void {
    std.debug.print(
        \\
        \\--- clock merge law broken ----------------------------------------------
        \\  law      {s}
        \\  seed     0x{x:0>16}
        \\  a        {any}
        \\  b        {any}
        \\  c        {any}
        \\  left     {any}
        \\  right    {any}
        \\
        \\The comparison is over whole clocks, not over one actor. A reader who
        \\re-runs with this seed sees the same three clocks.
        \\
    , .{ what, seed, a, b, c, left, right });
}

// Reflexive, first and on its own. `covers` is a subset, and every set contains
// itself; an implementation that starts the walk at one, or that compares with
// `<`, passes every test about distinct clocks and fails this one.
test "a clock covers itself, at every size and every fill" {
    const gpa = std.testing.allocator;
    const shapes = [_][]const u32{
        &.{},
        &.{0},
        &.{9},
        &.{ 0, 0, 0 },
        &.{ 1, 2, 3, 4 },
        &.{ 0, 7, 0, 2, 0 },
    };
    for (shapes) |entries| {
        var c = try clockOf(gpa, entries);
        defer c.deinit();
        // The same value, twice: `covers` compares contents and not addresses,
        // so a distinct allocation with the same entries compares equal too.
        var again = try c.clone();
        defer again.deinit();
        try std.testing.expect(c.covers(c));
        try std.testing.expect(again.covers(again));
        try std.testing.expect(c.covers(again));
        try std.testing.expect(again.covers(c));
        try std.testing.expect(c.eql(again));

        // The same shapes on the sparse clock, where a zero is not a counter of
        // zero but an actor nobody has heard of.
        var sparse: [8]?u32 = undefined;
        for (entries, 0..) |v, i| sparse[i] = if (v == 0) null else v;
        var s = try seqClockOf(gpa, sparse[0..entries.len]);
        defer s.deinit();
        var s_again = try s.clone();
        defer s_again.deinit();
        try std.testing.expect(s.covers(s));
        try std.testing.expect(s_again.covers(s_again));
        try std.testing.expect(s.covers(s_again));
        try std.testing.expect(s_again.covers(s));
    }
}

// The partial overlaps, one case each. The two easy ends — equal clocks and
// clearly ordered clocks — are in the test above and in `Clock merge and covers`
// respectively, so what is left is where a subset relation is actually hard.
test "covers is a subset relation, on every partial overlap" {
    const gpa = std.testing.allocator;

    // Same actors, one ahead. Directional, and not symmetric: the clock that is
    // ahead is the one that covers.
    var base = try clockOf(gpa, &.{ 5, 3, 0, 0 });
    defer base.deinit();
    var ahead = try clockOf(gpa, &.{ 5, 4, 0, 0 });
    defer ahead.deinit();
    try std.testing.expect(ahead.covers(base));
    try std.testing.expect(!base.covers(ahead));

    // Crossed: behind on one actor, ahead on another. Neither covers the other,
    // and the merge of the two covers both.
    var crossed = try clockOf(gpa, &.{ 1, 9, 0, 0 });
    defer crossed.deinit();
    try std.testing.expect(!crossed.covers(base));
    try std.testing.expect(!base.covers(crossed));
    var joined = try base.clone();
    defer joined.deinit();
    joined.merge(crossed);
    try std.testing.expect(joined.covers(base));
    try std.testing.expect(joined.covers(crossed));
    try std.testing.expectEqualSlices(u32, &.{ 5, 9, 0, 0 }, joined.values());

    // An actor the other has never heard of. `base` has seen nothing from actor
    // two, so anything at all for actor two is outside it.
    var heard = try clockOf(gpa, &.{ 5, 3, 1, 0 });
    defer heard.deinit();
    try std.testing.expect(!base.covers(heard));
    try std.testing.expect(heard.covers(base));

    // A subset of actors: fewer of them, so the extra slots are zero in both
    // readings and the two cover each other. Give the longer clock an actor the
    // shorter one has never heard of, and the relation turns one way — the
    // longer one still covers the shorter, because the shorter does not know
    // enough to be behind.
    var narrow = try clockOf(gpa, &.{ 5, 3 });
    defer narrow.deinit();
    try std.testing.expect(base.covers(narrow));
    try std.testing.expect(narrow.covers(base));
    _ = base.include(3, 1);
    try std.testing.expect(base.covers(narrow));
    try std.testing.expect(!narrow.covers(base));

    // Disjoint: every actor one knows, the other does not.
    var left = try clockOf(gpa, &.{ 4, 0 });
    defer left.deinit();
    var right = try clockOf(gpa, &.{ 0, 6 });
    defer right.deinit();
    try std.testing.expect(!left.covers(right));
    try std.testing.expect(!right.covers(left));

    // A clock of zeroes covers nothing but other clocks of zeroes, and is
    // covered by anything. "Empty" here means "no actor has been heard from",
    // not "no entries" — a zero-length clock is the same thing and says so.
    var empty = try clockOf(gpa, &.{ 0, 0 });
    defer empty.deinit();
    try std.testing.expect(empty.covers(empty));
    try std.testing.expect(!empty.covers(left));
    try std.testing.expect(left.covers(empty));
    // ...including one of a different length, where the actors past its end are
    // the ones nobody has heard of, so the longer clock still covers the shorter
    // and not the other way round.
    var tiny = try Clock.init(gpa, 0);
    defer tiny.deinit();
    try std.testing.expect(tiny.covers(empty));
    try std.testing.expect(empty.covers(tiny));
    try std.testing.expect(left.covers(tiny));
    try std.testing.expect(!tiny.covers(left));

    // The same matrix on the sparse clock, where "has not heard of" is a null
    // rather than a zero — and the two are not interchangeable, because a null
    // covers nothing while a zero covers every zero.
    var sbase = try seqClockOf(gpa, &.{ 5, 3, null, null });
    defer sbase.deinit();
    var sahead = try seqClockOf(gpa, &.{ 5, 4, null, null });
    defer sahead.deinit();
    try std.testing.expect(sahead.covers(sbase));
    try std.testing.expect(!sbase.covers(sahead));

    var sheard = try seqClockOf(gpa, &.{ 5, 3, 1, null });
    defer sheard.deinit();
    try std.testing.expect(!sbase.covers(sheard));
    try std.testing.expect(sheard.covers(sbase));

    var scrossed = try seqClockOf(gpa, &.{ 1, 9, null, null });
    defer scrossed.deinit();
    try std.testing.expect(!scrossed.covers(sbase));
    try std.testing.expect(!sbase.covers(scrossed));

    var sjoined = try sbase.clone();
    defer sjoined.deinit();
    sjoined.merge(scrossed);
    try std.testing.expect(sjoined.covers(sbase));
    try std.testing.expect(sjoined.covers(scrossed));

    var snarrow = try seqClockOf(gpa, &.{ 5, 3 });
    defer snarrow.deinit();
    try std.testing.expect(sbase.covers(snarrow));
    try std.testing.expect(snarrow.covers(sbase));

    var sleft = try seqClockOf(gpa, &.{ 4, null });
    defer sleft.deinit();
    var sright = try seqClockOf(gpa, &.{ null, 6 });
    defer sright.deinit();
    try std.testing.expect(!sleft.covers(sright));
    try std.testing.expect(!sright.covers(sleft));
    try std.testing.expect(sleft.covers(sleft));

    // A null covers a null and nothing else: a clock of nulls is covered by
    // another clock of nulls and by no clock that has heard from anybody.
    var sempty = try seqClockOf(gpa, &.{ null, null });
    defer sempty.deinit();
    var sempty_again = try sempty.clone();
    defer sempty_again.deinit();
    try std.testing.expect(sempty.covers(sempty_again));
    try std.testing.expect(!sempty.covers(snarrow));
    try std.testing.expect(snarrow.covers(sempty));
}

// `merge` is a join in a partial order, and a join has three laws. None of them
// is implied by taking a maximum: a merge that compared the wrong way round
// would be commutative and wrong, and one that stopped at the first difference
// would be commutative and idempotent and the only thing it broke would be
// associativity, which is the law nothing else here would catch.
test "merge is commutative, associative and idempotent over whole clocks" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(merge_seed);
    const rand = prng.random();

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = 1 + rand.intRangeAtMost(usize, 0, 6);
        var a = try Clock.init(gpa, n);
        defer a.deinit();
        var b = try Clock.init(gpa, n);
        defer b.deinit();
        var c = try Clock.init(gpa, n);
        defer c.deinit();
        for (0..n) |i| {
            _ = a.include(@intCast(i), randomCounter(rand));
            _ = b.include(@intCast(i), randomCounter(rand));
            _ = c.include(@intCast(i), randomCounter(rand));
        }

        var ab = try a.clone();
        defer ab.deinit();
        var ba = try b.clone();
        defer ba.deinit();
        ab.merge(b);
        ba.merge(a);
        if (!std.mem.eql(u32, ab.values(), ba.values())) {
            reportMergeLaw("commutative", merge_seed, a.values(), b.values(), c.values(), ab.values(), ba.values());
            return error.TestExpectedEqual;
        }

        // merge(merge(a, b), c) against merge(a, merge(b, c)).
        var left = try a.clone();
        defer left.deinit();
        var right = try a.clone();
        defer right.deinit();
        var bc = try b.clone();
        defer bc.deinit();
        var b_join_c = try b.clone();
        defer b_join_c.deinit();
        bc.merge(c);
        left.merge(bc);
        b_join_c.merge(c);
        right.merge(b_join_c);
        if (!std.mem.eql(u32, left.values(), right.values())) {
            reportMergeLaw("associative", merge_seed, a.values(), b.values(), c.values(), left.values(), right.values());
            return error.TestExpectedEqual;
        }

        // merge(x, x) is x.
        var twice = try ab.clone();
        defer twice.deinit();
        twice.merge(ab);
        if (!std.mem.eql(u32, twice.values(), ab.values())) {
            reportMergeLaw("idempotent", merge_seed, a.values(), b.values(), c.values(), twice.values(), ab.values());
            return error.TestExpectedEqual;
        }
    }
}

// The same three laws on the sparse clock, where an absent actor is not the
// same thing as an actor whose counter is zero. `None < Some(_)` is what makes
// them hold there, and it is a comparison the dense clock does not make.
test "SeqClock merge is commutative, associative and idempotent" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(merge_seed ^ 0x9e37_79b9);
    const rand = prng.random();

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = 1 + rand.intRangeAtMost(usize, 0, 6);
        var a = try SeqClock.init(gpa, n);
        defer a.deinit();
        var b = try SeqClock.init(gpa, n);
        defer b.deinit();
        var c = try SeqClock.init(gpa, n);
        defer c.deinit();
        for (0..n) |i| {
            const actor: ActorIdx = @intCast(i);
            _ = a.include(actor, sparseCounter(rand));
            _ = b.include(actor, sparseCounter(rand));
            _ = c.include(actor, sparseCounter(rand));
        }

        var ab = try a.clone();
        defer ab.deinit();
        var ba = try b.clone();
        defer ba.deinit();
        ab.merge(b);
        ba.merge(a);
        if (!std.mem.eql(?u32, ab.values(), ba.values())) {
            reportSparseLaw("commutative", merge_seed ^ 0x9e37_79b9, a.values(), b.values(), c.values(), ab.values(), ba.values());
            return error.TestExpectedEqual;
        }

        var left = try a.clone();
        defer left.deinit();
        var right = try a.clone();
        defer right.deinit();
        var bc = try b.clone();
        defer bc.deinit();
        var b_join_c = try b.clone();
        defer b_join_c.deinit();
        bc.merge(c);
        left.merge(bc);
        b_join_c.merge(c);
        right.merge(b_join_c);
        if (!std.mem.eql(?u32, left.values(), right.values())) {
            reportSparseLaw("associative", merge_seed ^ 0x9e37_79b9, a.values(), b.values(), c.values(), left.values(), right.values());
            return error.TestExpectedEqual;
        }

        var twice = try ab.clone();
        defer twice.deinit();
        twice.merge(ab);
        if (!std.mem.eql(?u32, twice.values(), ab.values())) {
            reportSparseLaw("idempotent", merge_seed ^ 0x9e37_79b9, a.values(), b.values(), c.values(), twice.values(), ab.values());
            return error.TestExpectedEqual;
        }
    }
}

/// A counter for the sparse sweep: zero in one round out of four, so a third of
/// the actors in a generated clock are actors nobody has heard of.
fn sparseCounter(rand: std.Random) u32 {
    return if (rand.int(u8) % 4 == 0) 0 else randomCounter(rand);
}

/// The sparse counterpart of [`reportMergeLaw`].
fn reportSparseLaw(
    what: []const u8,
    seed: u64,
    a: []const ?u32,
    b: []const ?u32,
    c: []const ?u32,
    left: []const ?u32,
    right: []const ?u32,
) void {
    std.debug.print(
        \\
        \\--- sparse merge law broken ----------------------------------------------
        \\  law      {s}
        \\  seed     0x{x:0>16}
        \\  a        {any}
        \\  b        {any}
        \\  c        {any}
        \\  left     {any}
        \\  right    {any}
        \\
    , .{ what, seed, a, b, c, left, right });
}

// `covers` and `contains` are the same comparison asked two ways: once for a
// whole clock and once for a single op id. If they ever disagree, a document is
// read through two different views of the same history, and which view is right
// is settled by which one is more specific — which is a question no per-actor
// test can answer.
test "covers is exactly the pointwise relation contains states" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(merge_seed ^ 0x0051);
    const rand = prng.random();

    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const n = 1 + rand.intRangeAtMost(usize, 0, 6);
        var a = try Clock.init(gpa, n);
        defer a.deinit();
        var b = try Clock.init(gpa, n);
        defer b.deinit();
        for (0..n) |i| {
            _ = a.include(@intCast(i), randomCounter(rand));
            _ = b.include(@intCast(i), randomCounter(rand));
        }
        // Everything `b` holds, `a` holds — asked one op id at a time. The
        // decisive counter is the highest one `b` holds: below it both contain
        // it, at it only the covering clock does, and above it `b` does not
        // contain it at all. A sweep of small counters would pass on every pair
        // this one catches, which is the whole reason it is the boundary value
        // and not a loop.
        var pointwise = true;
        for (0..n) |actor| {
            const at: OpId = .{ .counter = b.get(@intCast(actor)), .actor = @intCast(actor) };
            if (b.contains(at) and !a.contains(at)) pointwise = false;
        }
        // And outside the clock entirely, where `contains` reads zero. An actor
        // neither clock holds is covered by anybody, and both must say so.
        for (0..2) |past| {
            const at: OpId = .{ .counter = 0, .actor = @intCast(n + past) };
            if (b.contains(at) != a.contains(at)) pointwise = false;
        }
        if (pointwise != a.covers(b)) {
            std.debug.print(
                \\
                \\--- clock covers and contains disagree ---------------------------------
                \\  seed     0x{x:0>16}
                \\  round    {d}
                \\  a        {any}
                \\  b        {any}
                \\  covers   {}
                \\  per-op   {}
                \\
            , .{ merge_seed ^ 0x0051, round, a.values(), b.values(), a.covers(b), pointwise });
            return error.TestExpectedEqual;
        }
    }
}

// `merge` zips, so it folds only the actors both clocks have (`clock.rs:57`).
// That is not a detail: it is why a receiver keeps its own length, and a port
// that "fixed" it by growing the receiver would make the two clock types
// disagree about the actor table they index.
test "merge folds only the actors both clocks have" {
    const gpa = std.testing.allocator;
    var wide = try clockOf(gpa, &.{ 1, 2, 3, 4 });
    defer wide.deinit();
    var narrow = try clockOf(gpa, &.{ 9, 9 });
    defer narrow.deinit();

    var into_wide = try wide.clone();
    defer into_wide.deinit();
    into_wide.merge(narrow);
    try std.testing.expectEqualSlices(u32, &.{ 9, 9, 3, 4 }, into_wide.values());

    var into_narrow = try narrow.clone();
    defer into_narrow.deinit();
    into_narrow.merge(wide);
    try std.testing.expectEqualSlices(u32, &.{ 9, 9 }, into_narrow.values());
    try std.testing.expectEqual(@as(usize, 2), into_narrow.len);
    // A receiver still covers what it merged, and still does not cover a clock
    // that has heard from actors past its end.
    try std.testing.expect(into_narrow.covers(narrow));
    try std.testing.expect(!narrow.covers(into_wide));

    // Aliasing: merging a clock into itself leaves it alone.
    var self = try clockOf(gpa, &.{ 3, 1, 4, 1 });
    defer self.deinit();
    self.merge(self);
    try std.testing.expectEqualSlices(u32, &.{ 3, 1, 4, 1 }, self.values());

    var s_wide = try seqClockOf(gpa, &.{ 1, 2, 3, 4 });
    defer s_wide.deinit();
    var s_narrow = try seqClockOf(gpa, &.{ 9, 9 });
    defer s_narrow.deinit();
    var s_into = try s_wide.clone();
    defer s_into.deinit();
    s_into.merge(s_narrow);
    try std.testing.expectEqualSlices(?u32, &.{ 9, 9, 3, 4 }, s_into.values());
    // A null in the operand is not a value and overwrites nothing.
    var s_partial = try seqClockOf(gpa, &.{ null, 7 });
    defer s_partial.deinit();
    var s_merged = try s_wide.clone();
    defer s_merged.deinit();
    s_merged.merge(s_partial);
    try std.testing.expectEqualSlices(?u32, &.{ 1, 7, 3, 4 }, s_merged.values());
}

// `include` is the only mutator, and its contract is one line: the entry goes up
// or it does not move. Everything `merge` and `covers` rely on follows from
// that. Counter zero is the case that makes the line worth writing down — it is
// the head sentinel, and upstream stores it in a `NonZeroU32` (`clock.rs:42`),
// which cannot hold it at all.
test "include advances only forwards, and never on a zero counter" {
    const gpa = std.testing.allocator;

    var c = try clockOf(gpa, &.{ 0, 0, 0 });
    defer c.deinit();
    try std.testing.expect(!c.include(1, 0));
    try std.testing.expectEqual(@as(u32, 0), c.get(1));
    try std.testing.expect(c.include(1, 4));
    // The same counter again is not an advance, and a smaller one is not either.
    try std.testing.expect(!c.include(1, 4));
    try std.testing.expect(!c.include(1, 3));
    try std.testing.expectEqual(@as(u32, 4), c.get(1));
    // An actor outside the clock cannot be advanced at all, however large.
    try std.testing.expect(!c.include(9, 1));
    try std.testing.expect(!c.include(9, std.math.maxInt(u32)));

    // A run of ascending counters leaves the last one standing.
    var run = try Clock.init(gpa, 1);
    defer run.deinit();
    var want: u32 = 0;
    for (1..32) |k| {
        try std.testing.expect(run.include(0, @intCast(k)));
        want = @intCast(k);
    }
    try std.testing.expectEqual(want, run.get(0));
    try std.testing.expect(!run.include(0, want));

    var s = try seqClockOf(gpa, &.{ null, null });
    defer s.deinit();
    try std.testing.expect(s.get(0) == null);
    try std.testing.expect(!s.include(0, 0));
    try std.testing.expect(s.get(0) == null);
    try std.testing.expect(s.include(0, 4));
    try std.testing.expect(!s.include(0, 4));
    try std.testing.expect(!s.include(0, 3));
    try std.testing.expectEqual(@as(?u32, 4), s.get(0));
    try std.testing.expect(!s.include(9, 1));
}

// A clock hands out a slice into its own storage and that slice is valid until
// the next mutation. `ensureSize` is the mutation that moves it, so this is
// where the rule is worth a test. The first grow stays inside the allocation,
// so a slice taken before it would still read; the second one reallocates. That
// is exactly why reading an old slice is a mistake rather than a crash, and why
// only `values()` is a thing to call again.
test "a slice into a clock's own storage dies with the next mutation" {
    const gpa = std.testing.allocator;
    var c = try Clock.init(gpa, 1);
    defer c.deinit();
    _ = c.include(0, 2);
    try c.ensureSize(2);
    try std.testing.expectEqual(@as(usize, 2), c.values().len);
    try std.testing.expectEqual(@as(u32, 2), c.get(0));
    try c.ensureSize(64);
    try std.testing.expectEqual(@as(usize, 64), c.values().len);
    try std.testing.expectEqual(@as(u32, 2), c.get(0));
    try std.testing.expectEqual(@as(u32, 0), c.get(63));

    var s = try SeqClock.init(gpa, 1);
    defer s.deinit();
    _ = s.include(0, 2);
    try s.ensureSize(64);
    try std.testing.expectEqual(@as(usize, 64), s.values().len);
    try std.testing.expectEqual(@as(?u32, 2), s.get(0));
    try std.testing.expect(s.get(63) == null);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`covers` returns an answer where upstream panics, and the answer is the
//   same.** `SeqClock::covers` opens with `assert_eq!(self.0.len(),
//   other.0.len())` (`clock.rs:65`) — a panic on two clocks of different
//   lengths, which is a way to make a parser abort on a document. This port
////   reads the entries past the end as the unknown actors they are, which is
//   what `get` already answered for them (`clock.rs:30-32` for the sparse
//   clock, [`Clock.get`] for the dense one), so `covers` and `contains` cannot
//   disagree about the same actor. The equal-length case — the only one
//   upstream admits — is unchanged. The alternative, the dense clock's
//   test-only `is_greater` (`clock.rs:184-186`), truncates to the shorter clock
////   instead, which would make a two-entry clock cover a four-entry one that
//   has heard from actors it knows nothing about. Neither upstream answer is
//   reachable from the port's own callers, so this is a total-function choice
//   and not a behaviour change anyone depends on.
//
// * **`merge` and `include` are upstream's, unchanged.** `merge` is the zip at
//   `clock.rs:56-62` and keeps the receiver's length. `include` is
//   `clock.rs:38-54` with one return value changed: upstream returns `true`
//   for `include(actor, Some(0))` on an empty slot — it stores
//     `NonZeroU32::try_from(0).ok()`, which is `None`, and returns `true`
//   anyway, so it reports a change it did not make. This port returns `false`,
//     because the value it stores is the same either way and the only call site
//   discards the answer (`change_graph.zig:540`). No clock differs on the
//   strength of that return value.
//
// * **The dense `Clock.include` and `Clock.merge` are the port's, not
//   upstream's.** Upstream has no `Clock::merge` at all and its `Clock::include`
//     exists only inside `#[cfg(test)]` (`clock.rs:175-182`). The port needs a
//   way to build a dense clock and to fold one into another, and the tests need
//   to state `merge`'s laws over whole clocks, which a type with no mutators
//   cannot be asked about. Both are documented as what they are rather than
//   dressed as transcriptions.
//
// * **`reserveNewActor` and `rewriteWithNewActor` are one upstream method split
//   in two.** `rewrite_with_new_actor` is a `Vec::insert` of `None`
//   (`clock.rs:26-28`), which allocates through Rust's infallible allocator and
//   cannot be refused; this port's can be, and a graph renaming an actor
//   rewrites every clock it holds in one breath
//   ([`ChangeGraph.insertActor`](change_graph.zig)), so a refusal in the middle
//   would leave some clocks renumbered and the rest naming the old actors. The
//   insert is therefore infallible and takes its room from a reservation the
//   caller makes first, exactly as `ensureUnusedCapacity` precedes
//   `appendAssumeCapacity`. `reserve` and `resizeNoFail` are `ensureSize`'s own
//   two halves for the same reason, and the dense [`Clock`] keeps neither: no
//   caller rewrites more than one dense clock per allocation.
//
// * **The laws are asserted over whole clocks, not over one actor.** `merge` is
//   a join in a partial order, so it is commutative, associative and idempotent
//   (`OpId` ordering aside). None of the three is implied by taking a maximum:
//     a merge that compared the wrong way round would be commutative and wrong,
//     and one that stopped at the first difference would be commutative and
//   idempotent while breaking only associativity — the law nothing else here
//   catches. Every failure prints the seed and all three operands, so a law
//   that failed on round 3187 can be re-run rather than guessed at.
