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

    /// Records `counter` for `actor`. Returns true when the clock advanced.
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
    pub fn merge(a: *Clock, b: Clock) void {
        const n = @min(a.len, b.len);
        for (a.slots[0..n], b.slots[0..n]) |*x, y| {
            if (x.* < y) x.* = y;
        }
    }

    /// True when every entry of `other` is at or below `self`.
    pub fn covers(self: Clock, other: Clock) bool {
        if (self.len != other.len) return false;
        for (self.slots[0..self.len], other.slots[0..other.len]) |x, y| {
            if (x < y) return false;
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

    pub fn ensureSize(self: *SeqClock, size: usize) !void {
        if (size <= self.len) return;
        if (size <= self.slots.len) {
            @memset(self.slots[self.len..size], null);
            self.len = size;
            return;
        }
        const grown = try self.gpa.alloc(?u32, size);
        @memset(grown, null);
        @memcpy(grown[0..self.len], self.slots[0..self.len]);
        self.gpa.free(self.slots);
        self.slots = grown;
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

    /// Inserts an empty entry at `idx`, shifting indices at or above it up.
    pub fn rewriteWithNewActor(self: *SeqClock, idx: ActorIdx) !void {
        try self.ensureSize(self.len + 1);
        if (idx >= self.len) {
            self.slots[self.len - 1] = null;
            return;
        }
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

    /// True when every entry of `other` is covered by `self`. Unlike `Clock`,
    /// a null in `other` is always covered.
    pub fn covers(self: SeqClock, other: SeqClock) bool {
        if (self.len != other.len) return false;
        for (self.slots[0..self.len], other.slots[0..other.len]) |x, y| {
            if (y) |v| {
                const have = x orelse return false;
                if (have < v) return false;
            }
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

    try c.rewriteWithNewActor(0);
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
    try c.rewriteWithNewActor(1);
    try std.testing.expectEqual(@as(usize, 2), c.len);
    try std.testing.expectEqual(@as(?u32, 5), c.get(0));
    try std.testing.expect(c.get(1) == null);

    var d = try c.clone();
    defer d.deinit();
    _ = d.include(0, 9);
    try std.testing.expectEqual(@as(?u32, 5), c.get(0));
    try std.testing.expectEqual(@as(?u32, 9), d.get(0));
}
