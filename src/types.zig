//! Identity, object, and value types.
//!
//! These are the types every other module speaks in. Two facts drive the whole
//! design:
//!
//! * An actor is stored in a per-document table and referenced everywhere by
//!   its `u32` index into that table, never by its bytes. The index is the
//!   actor column of the op set, and the change encoder, so it is not an
//!   implementation detail.
//! * `OpId` orders by counter first, then actor. `OpId` order is the document's
//!   total order over operations and is relied on by the op set, the iterators,
//!   and the change encoder. Do not change it.

const std = @import("std");
const err = @import("error.zig");

pub const Error = err.Error;
pub const ParseError = err.ParseError;

/// An index into a document's sorted actor table.
pub const ActorIdx = u32;

/// The number of bytes in a change hash.
pub const hash_size = 32;

/// The number of bytes in the per-chunk checksum.
pub const checksum_size = 4;

/// A change hash: SHA-256 over an encoded change.
pub const ChangeHash = struct {
    bytes: [hash_size]u8,

    pub const zero: ChangeHash = .{ .bytes = @splat(0) };

    pub fn eql(a: ChangeHash, b: ChangeHash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Total order, by the underlying bytes. This is the order the change
    /// graph and the sync `have` set depend on.
    pub fn order(a: ChangeHash, b: ChangeHash) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// The first four bytes, stored in every chunk header.
    pub fn checksum(self: ChangeHash) [checksum_size]u8 {
        return .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] };
    }

    pub fn fromChecksum(sum: [checksum_size]u8) ChangeHash {
        var h: ChangeHash = .zero;
        @memcpy(h.bytes[0..checksum_size], &sum);
        return h;
    }

    /// The number of leading zero bytes. Automerge's fragment encoding uses
    /// this to compress sparse hash sets.
    pub fn fragmentLevel(self: ChangeHash) usize {
        var n: usize = 0;
        for (self.bytes) |b| {
            if (b != 0) break;
            n += 1;
        }
        return n;
    }

    pub fn lessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
        return a.order(b) == .lt;
    }

    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !ChangeHash {
        const decoded = try err.hexFrom(gpa, text);
        defer gpa.free(decoded);
        if (decoded.len != hash_size) return error.InvalidChangeHashBytes;
        return .{ .bytes = decoded[0..hash_size].* };
    }
};

/// An actor: a byte string, unique within a document, ordered lexicographically.
///
/// The bytes are borrowed. An `ActorId` created by a document borrows the
/// document's intern arena; one created by a caller borrows the caller's
/// buffer, which must outlive it.
pub const ActorId = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) ActorId {
        return .{ .bytes = bytes };
    }

    /// A 16-byte actor id copied into `gpa`. Use this when the actor must own
    /// its bytes, such as a randomly generated one.
    pub fn initCopy(gpa: std.mem.Allocator, bytes: []const u8) !ActorId {
        return .{ .bytes = try gpa.dupe(u8, bytes) };
    }

    pub fn random(gpa: std.mem.Allocator) !ActorId {
        const bytes = try gpa.alloc(u8, 16);
        std.crypto.random.bytes(bytes);
        return .{ .bytes = bytes };
    }

    pub fn eql(a: ActorId, b: ActorId) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }

    /// Change encoding orders actors by the lexicographic order of their
    /// bytes. Every ordered comparison of actors must go through this.
    pub fn order(a: ActorId, b: ActorId) std.math.Order {
        return std.mem.order(u8, a.bytes, b.bytes);
    }

    pub fn lessThan(_: void, a: ActorId, b: ActorId) bool {
        return a.order(b) == .lt;
    }

    pub fn toHex(gpa: std.mem.Allocator, self: ActorId) ![]u8 {
        const out = try gpa.alloc(u8, self.bytes.len * 2);
        err.hexInto(self.bytes, out);
        return out;
    }

    pub fn fromHex(gpa: std.mem.Allocator, text: []const u8) !ActorId {
        return .{ .bytes = try err.hexFrom(gpa, text) };
    }

    /// The actor id an `automerged`-style concurrency level expands to:
    /// four magic bytes, the level as LEB128, then the original bytes. This
    /// actor id is longer than the original, which is why the magic bytes are
    /// 0x13 0xb2 0x23 0x09 and not arbitrary.
    pub fn withConcurrency(gpa: std.mem.Allocator, self: ActorId, level: usize) !ActorId {
        const leb = try @import("leb128.zig").unsignedSize(level);
        const out = try gpa.alloc(u8, 4 + leb + self.bytes.len);
        @memcpy(out[0..4], &concurrency_magic_bytes);
        const n = try @import("leb128.zig").writeUnsigned(out[4..], level);
        @memcpy(out[4 + n ..], self.bytes);
        return .{ .bytes = out };
    }
};

/// Random bytes prefixed to a concurrency-derived actor id.
pub const concurrency_magic_bytes = [4]u8{ 0x13, 0xb2, 0x23, 0x09 };

/// An operation id: a per-actor counter plus the actor index.
pub const OpId = struct {
    counter: u32,
    actor: ActorIdx,

    pub const root: OpId = .{ .counter = 0, .actor = 0 };
    /// The head of a sequence: the element id that means "inserted at the
    /// front".
    pub const head: OpId = root;

    pub fn init(counter: u32, actor: ActorIdx) OpId {
        return .{ .counter = counter, .actor = actor };
    }

    pub fn eql(a: OpId, b: OpId) bool {
        return a.counter == b.counter and a.actor == b.actor;
    }

    /// Counter first, then actor. The document's total order over operations.
    pub fn order(a: OpId, b: OpId) std.math.Order {
        if (a.counter != b.counter) return std.math.order(a.counter, b.counter);
        return std.math.order(a.actor, b.actor);
    }

    pub fn lessThan(_: void, a: OpId, b: OpId) bool {
        return a.order(b) == .lt;
    }

    pub fn prev(self: OpId) OpId {
        return .{ .counter = self.counter - 1, .actor = self.actor };
    }

    pub fn next(self: OpId) OpId {
        return .{ .counter = self.counter + 1, .actor = self.actor };
    }

    /// Removes actor index `idx`, shifting the indices above it down. Returns
    /// null when the id itself was the removed actor.
    pub fn withoutActor(self: OpId, idx: ActorIdx) ?OpId {
        if (self.actor > idx) return .{ .counter = self.counter, .actor = self.actor - 1 };
        if (self.actor == idx) return null;
        return self;
    }

    /// Inserts a new actor at index `idx`, shifting indices at or above it up.
    pub fn withNewActor(self: OpId, idx: ActorIdx) OpId {
        if (self.actor >= idx) return .{ .counter = self.counter, .actor = self.actor + 1 };
        return self;
    }

    pub fn toU64(self: OpId) u64 {
        return (@as(u64, self.counter) << 32) | self.actor;
    }
};

/// An object id: either the document root or an operation id.
pub const ExId = union(enum) {
    id: OpId,
    root,

    pub fn fromParts(ctr: ?u64, act: ?ActorIdx) ?ExId {
        if (ctr == null and act == null) return .root;
        if (ctr == null or act == null) return null;
        const c = ctr.?;
        if (c > std.math.maxInt(u32)) return null;
        return .{ .id = .{ .counter = @intCast(c), .actor = act.? } };
    }

    pub fn isRoot(self: ExId) bool {
        return self == .root;
    }

    /// The operation id, or null for the root.
    pub fn opId(self: ExId) ?OpId {
        return switch (self) {
            .root => null,
            .id => |i| i,
        };
    }

    pub fn counter(self: ExId) ?u32 {
        return if (self.opId()) |i| i.counter else null;
    }

    pub fn actor(self: ExId) ?ActorIdx {
        return if (self.opId()) |i| i.actor else null;
    }

    pub fn eql(a: ExId, b: ExId) bool {
        return switch (a) {
            .root => b == .root,
            .id => |x| switch (b) {
                .root => false,
                .id => |y| x.eql(y),
            },
        };
    }

    pub fn order(a: ExId, b: ExId) std.math.Order {
        const ai = a.opId() orelse return if (b.isRoot()) .eq else .lt;
        const bi = b.opId() orelse return .gt;
        return ai.order(bi);
    }

    pub fn withoutActor(self: ExId, idx: ActorIdx) ?ExId {
        const i = self.opId() orelse return self;
        const n = i.withoutActor(idx) orelse return null;
        return .{ .id = n };
    }

    pub fn withNewActor(self: ExId, idx: ActorIdx) ExId {
        const i = self.opId() orelse return self;
        return .{ .id = i.withNewActor(idx) };
    }
};

/// The element id a sequence op is anchored to. `_head` is `OpId{0, 0}`.
pub const ElemId = OpId;

/// What kind of object an id names.
pub const ObjType = enum {
    map,
    /// Retained for backwards compatibility. Tables are identical to maps.
    table,
    list,
    text,

    pub fn isSequence(self: ObjType) bool {
        return self == .list or self == .text;
    }

    pub fn asSequenceType(self: ObjType) ?SequenceType {
        return switch (self) {
            .list => .list,
            .text => .text,
            else => null,
        };
    }

    pub fn order(a: ObjType, b: ObjType) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
};

/// A property of an object: a map key, or a sequence index.
pub const Prop = union(enum) {
    key: []const u8,
    index: usize,

    pub fn asStr(self: Prop) ?[]const u8 {
        return switch (self) {
            .key => |k| k,
            .index => null,
        };
    }

    pub fn asIndex(self: Prop) ?usize {
        return switch (self) {
            .key => null,
            .index => |i| i,
        };
    }

    pub fn eql(a: Prop, b: Prop) bool {
        return switch (a) {
            .key => |x| switch (b) {
                .key => |y| std.mem.eql(u8, x, y),
                .index => false,
            },
            .index => |x| switch (b) {
                .key => false,
                .index => |y| x == y,
            },
        };
    }
};

/// Whether a sequence holds arbitrary values or characters.
pub const SequenceType = enum {
    list,
    text,
};

/// How text is measured. Every index into a text object is in these units.
pub const TextEncoding = enum {
    unicode_code_point,
    utf8_code_unit,
    utf16_code_unit,
    grapheme_cluster,

    /// The number of units in `s` under this encoding.
    pub fn width(self: TextEncoding, s: []const u8) usize {
        return switch (self) {
            .unicode_code_point => std.unicode.utf8CountCodepoints(s) catch s.len,
            .utf8_code_unit => s.len,
            .utf16_code_unit => @import("unicode.zig").countUtf16CodeUnits(s) catch s.len,
            .grapheme_cluster => @import("unicode.zig").countGraphemes(s) catch s.len,
        };
    }

    /// The `TEXT_ENCODING_TAG` byte written into a change.
    pub fn tag(self: TextEncoding) u8 {
        return switch (self) {
            .unicode_code_point => 0,
            .utf8_code_unit => 1,
            .utf16_code_unit => 2,
            .grapheme_cluster => 3,
        };
    }

    pub fn fromTag(t: u8) !TextEncoding {
        return switch (t) {
            0 => .unicode_code_point,
            1 => .utf8_code_unit,
            2 => .utf16_code_unit,
            3 => .grapheme_cluster,
            else => error.InvalidTextEncoding,
        };
    }
};

/// An object id plus its type.
pub const ObjMeta = struct {
    id: ExId,
    typ: ObjType,

    pub fn root() ObjMeta {
        return .{ .id = .root, .typ = .map };
    }
};

test "OpId orders by counter then actor" {
    try std.testing.expect(OpId.init(1, 0).order(OpId.init(2, 0)) == .lt);
    try std.testing.expect(OpId.init(2, 0).order(OpId.init(1, 9)) == .gt);
    try std.testing.expect(OpId.init(1, 0).order(OpId.init(1, 1)) == .lt);
    try std.testing.expect(OpId.init(1, 1).order(OpId.init(1, 1)) == .eq);
}

test "ExId root and remapping" {
    try std.testing.expect(ExId.isRoot(ExId.root));
    try std.testing.expect(ExId.counter(ExId.root) == null);
    const a: ExId = .{ .id = .init(3, 1) };
    try std.testing.expectEqual(@as(?u32, 3), ExId.counter(a));
    // Removing actor 0 shifts actor 1 down to 0; removing actor 1 removes the
    // id itself.
    try std.testing.expect(ExId.actor(a.withoutActor(0).?) == 0);
    try std.testing.expect(a.withoutActor(1) == null);
    // Inserting a new actor 0 shifts actor 1 up.
    try std.testing.expect(ExId.actor(a.withNewActor(0)) == 2);
    // The root is never affected.
    try std.testing.expect(ExId.isRoot(ExId.withoutActor(ExId.root, 0).?));
}

test "ExId from parts rejects half a pair" {
    try std.testing.expect(ExId.fromParts(null, null).? == .root);
    try std.testing.expect(ExId.fromParts(1, null) == null);
    try std.testing.expect(ExId.fromParts(null, 0) == null);
    try std.testing.expect(ExId.counter(ExId.fromParts(5, 2).?) == 5);
    try std.testing.expect(ExId.fromParts(std.math.maxInt(u32) + 1, 0) == null);
}

test "ChangeHash ordering, checksum, and fragment level" {
    const gpa = std.testing.allocator;
    var a: ChangeHash = .zero;
    a.bytes = [_]u8{0x01} ** 32;
    var b: ChangeHash = .zero;
    b.bytes = [_]u8{0x02} ** 32;
    try std.testing.expect(a.order(b) == .lt);
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, a.checksum());
    // Only the first four bytes survive a checksum round trip.
    const from_sum = ChangeHash.fromChecksum(a.checksum());
    try std.testing.expectEqualSlices(u8, a.bytes[0..4], from_sum.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 28, from_sum.bytes[4..]);
    try std.testing.expectEqual(@as(usize, 0), a.fragmentLevel());

    var c: ChangeHash = .zero;
    c.bytes = [_]u8{0} ** 32;
    c.bytes[31] = 1;
    try std.testing.expectEqual(@as(usize, 31), c.fragmentLevel());

    const parsed = try ChangeHash.parse(gpa, "00" ** 32);
    try std.testing.expect(parsed.eql(ChangeHash.zero));
}

test "ActorId equality and ordering" {
    const gpa = std.testing.allocator;
    const a = try ActorId.initCopy(gpa, &[_]u8{ 0xaa, 0xbb });
    defer gpa.free(a.bytes);
    const b = try ActorId.initCopy(gpa, &[_]u8{ 0xaa, 0xcc });
    defer gpa.free(b.bytes);

    try std.testing.expect(a.order(b) == .lt);
    try std.testing.expect(a.eql(a));

    const hex = try ActorId.toHex(gpa, a);
    defer gpa.free(hex);
    try std.testing.expectEqualStrings("aabb", hex);

    const back = try ActorId.fromHex(gpa, "aabb");
    defer gpa.free(back.bytes);
    try std.testing.expect(back.eql(a));
}

test "TextEncoding widths" {
    // "aé" is two code points, three UTF-8 bytes, two UTF-16 units, and two
    // grapheme clusters.
    const s = "aé";
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.unicode_code_point.width(s));
    try std.testing.expectEqual(@as(usize, 3), TextEncoding.utf8_code_unit.width(s));
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.utf16_code_unit.width(s));
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.grapheme_cluster.width(s));
    try std.testing.expect((try TextEncoding.fromTag(2)) == .utf16_code_unit);
    try std.testing.expectError(error.InvalidTextEncoding, TextEncoding.fromTag(9));
}
