//! Scalar values, the value metadata word, and operation actions.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");

const ParseError = err.ParseError;
const Error = err.Error;
const ExId = types.ExId;
const ActorId = types.ActorId;

/// The wire tag of a scalar value. The numeric values are format: they are the
/// low four bits of a value metadata word and are read by every other
/// automerge implementation.
pub const ValueType = union(enum) {
    null_value,
    false_value,
    true_value,
    uleb,
    leb,
    float,
    string,
    bytes,
    counter,
    timestamp,
    /// A value from a future version of automerge, preserved verbatim.
    unknown: u8,

    pub fn code(self: ValueType) u8 {
        return switch (self) {
            .null_value => 0,
            .false_value => 1,
            .true_value => 2,
            .uleb => 3,
            .leb => 4,
            .float => 5,
            .string => 6,
            .bytes => 7,
            .counter => 8,
            .timestamp => 9,
            .unknown => |c| c,
        };
    }

    pub fn fromCode(v: u8) ValueType {
        return switch (v & 0x0f) {
            0 => .null_value,
            1 => .false_value,
            2 => .true_value,
            3 => .uleb,
            4 => .leb,
            5 => .float,
            6 => .string,
            7 => .bytes,
            8 => .counter,
            9 => .timestamp,
            else => .{ .unknown = v & 0x0f },
        };
    }
};

/// A value metadata word: the byte length of a value in its low shift, and its
/// type tag in the low nibble. One column of these accompanies the raw value
/// column.
pub const ValueMeta = struct {
    raw: u64,

    pub fn init(typ: ValueType, byte_len: usize) ValueMeta {
        return .{ .raw = (@as(u64, byte_len) << 4) | typ.code() };
    }

    pub fn fromRaw(raw: u64) ValueMeta {
        return .{ .raw = raw };
    }

    pub fn typeCode(self: ValueMeta) ValueType {
        return ValueType.fromCode(@truncate(self.raw));
    }

    /// The length in bytes of the value that follows in the raw value column.
    pub fn length(self: ValueMeta) usize {
        return @intCast(self.raw >> 4);
    }
};

/// A scalar value. String and byte payloads are borrowed from the arena that
/// owns them.
pub const ScalarValue = union(enum) {
    null_value,
    bool_value: bool,
    int: i64,
    uint: u64,
    float: f64,
    str: []const u8,
    bytes: []const u8,
    counter: Counter,
    timestamp: i64,
    actor_id: ActorId,
    /// A value from a future version of automerge, preserved verbatim.
    unknown: UnknownValue,

    pub const UnknownValue = struct {
        type_code: u8,
        bytes: []const u8,
    };

    /// A counter: an integer that merges by addition.
    pub const Counter = struct {
        current: i64,

        pub fn init(v: i64) Counter {
            return .{ .current = v };
        }

        pub fn eql(a: Counter, b: Counter) bool {
            return a.current == b.current;
        }
    };

    pub fn eql(a: ScalarValue, b: ScalarValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null_value => true,
            .bool_value => |x| x == b.bool_value,
            .int => |x| x == b.int,
            .uint => |x| x == b.uint,
            .float => |x| x == b.float,
            .str => |x| std.mem.eql(u8, x, b.str),
            .bytes => |x| std.mem.eql(u8, x, b.bytes),
            .counter => |x| x.eql(b.counter),
            .timestamp => |x| x == b.timestamp,
            .actor_id => |x| x.eql(b.actor_id),
            .unknown => |x| x.type_code == b.unknown.type_code and
                std.mem.eql(u8, x.bytes, b.unknown.bytes),
        };
    }

    /// The value type tag this scalar encodes as. Actor ids encode as `bytes`
    /// in the value column and as an actor reference in the key columns; the
    /// distinction is carried by the op, not by the value.
    pub fn valueType(self: ScalarValue) ValueType {
        return switch (self) {
            .null_value => .null_value,
            .bool_value => |b| if (b) .true_value else .false_value,
            .uint => .uleb,
            .int, .counter, .timestamp => .leb,
            .float => .float,
            .str => .string,
            .bytes, .actor_id => .bytes,
            .unknown => |u| .{ .unknown = u.type_code },
        };
    }

    /// Coerces a value to the requested type, as the load path does when a
    /// stored value does not match its declared type.
    pub fn asDatatype(self: ScalarValue, want: types.ObjType) !ScalarValue {
        return switch (want) {
            .map, .table => error.NotAnObject,
            .list, .text => switch (self) {
                .int => |i| ScalarValue{ .counter = .init(i) },
                .uint => |u| ScalarValue{ .counter = .init(std.math.cast(i64, u) orelse
                    return error.InvalidValueType) },
                else => self,
            },
        };
    }
};

/// A value in the document: a scalar, or a reference to an object.
pub const Value = union(enum) {
    scalar: ScalarValue,
    object: ExId,
};

/// What an operation does. The numeric values are format: they are the
/// contents of the op set's action column and appear in every saved document.
pub const Action = enum(u8) {
    make_map = 0,
    set = 1,
    make_list = 2,
    delete = 3,
    make_text = 4,
    increment = 5,
    /// Retained for backwards compatibility; tables are identical to maps.
    make_table = 6,
    mark = 7,

    pub fn fromCode(code: u8) ParseError!Action {
        return switch (code) {
            0...7 => @enumFromInt(code),
            else => error.InvalidAction,
        };
    }

    /// The object type an action creates, if it creates one.
    pub fn objType(self: Action) ?types.ObjType {
        return switch (self) {
            .make_map => .map,
            .make_list => .list,
            .make_text => .text,
            .make_table => .table,
            else => null,
        };
    }
};

/// A reference to a value stored in the op set: either a scalar that was
/// decoded eagerly, or a slice of the raw value column.
pub const ScalarValueRef = union(enum) {
    value: ScalarValue,
    raw: []const u8,
};

/// The value an operation carries, after the action and value columns have
/// been combined.
pub const OpType = union(enum) {
    make: types.ObjType,
    delete,
    increment: i64,
    put: ScalarValue,
    mark_begin: MarkBegin,
    mark_end: MarkEnd,

    pub const MarkBegin = struct {
        expand: bool,
        name: []const u8,
        value: ?ScalarValue,
    };

    pub const MarkEnd = struct {
        expand: bool,
        name: []const u8,
        value: ?ScalarValue,
    };
};

/// Combines an action, a value, and the mark columns into an op type, the
/// inverse of what the encoder does. Rejects an action and value that cannot
/// occur together, which is a corrupt document rather than a bug.
pub fn opTypeFromActionAndValue(
    action: Action,
    value: ScalarValue,
    mark_name: ?[]const u8,
    expand: bool,
) ParseError!OpType {
    return switch (action) {
        .make_map => .{ .make = .map },
        .make_list => .{ .make = .list },
        .make_text => .{ .make = .text },
        .make_table => .{ .make = .table },
        .delete => .delete,
        .set => .{ .put = value },
        .increment => switch (value) {
            .int => |i| .{ .increment = i },
            .uint => |u| .{ .increment = std.math.cast(i64, u) orelse
                return error.InvalidValueType },
            .counter => |c| .{ .increment = c.current },
            else => error.InvalidValueType,
        },
        .mark => blk: {
            const name = mark_name orelse return error.InvalidValue;
            switch (value) {
                .null_value => break :blk .{
                    .mark_begin = .{ .expand = expand, .name = name, .value = null },
                },
                else => break :blk .{
                    .mark_begin = .{ .expand = expand, .name = name, .value = value },
                },
            }
        },
    };
}

test "ValueMeta packs length and type" {
    const m = ValueMeta.init(.string, 5);
    try std.testing.expectEqual(@as(usize, 5), m.length());
    try std.testing.expectEqual(ValueType.string, m.typeCode());

    const n = ValueMeta.init(.{ .unknown = 12 }, 300);
    try std.testing.expectEqual(@as(usize, 300), n.length());
    try std.testing.expectEqual(ValueType{ .unknown = 12 }, n.typeCode());
}

test "ValueType codes round trip" {
    inline for (.{
        ValueType.null_value, .false_value, .true_value, .uleb,    .leb,
        .float,               .string,      .bytes,      .counter, .timestamp,
    }) |vt| {
        const code = ValueType.code(vt);
        try std.testing.expectEqual(vt, ValueType.fromCode(code));
    }
    try std.testing.expectEqual(ValueType{ .unknown = 11 }, ValueType.fromCode(11));
}

test "Action codes are the format values" {
    try std.testing.expectEqual(Action.make_map, try Action.fromCode(0));
    try std.testing.expectEqual(Action.mark, try Action.fromCode(7));
    try std.testing.expectError(error.InvalidAction, Action.fromCode(8));
    try std.testing.expectEqual(types.ObjType.text, Action.make_text.objType().?);
    try std.testing.expectEqual(@as(?types.ObjType, null), Action.delete.objType());
}

test "ScalarValue equality discriminates type and payload" {
    const a = ScalarValue{ .str = "a" };
    try std.testing.expect(a.eql(ScalarValue{ .str = "a" }));
    try std.testing.expect(!a.eql(ScalarValue{ .str = "b" }));
    // An int and a counter are different types even at the same number.
    const one_int: ScalarValue = .{ .int = 1 };
    const one_counter: ScalarValue = .{ .counter = .init(1) };
    try std.testing.expect(!one_int.eql(one_counter));
    const f: ScalarValue = .{ .bool_value = false };
    const u: ScalarValue = .{ .uint = 3 };
    const i: ScalarValue = .{ .int = -3 };
    try std.testing.expect(f.valueType() == .false_value);
    try std.testing.expect(u.valueType() == .uleb);
    try std.testing.expect(i.valueType() == .leb);
}

test "op type from action and value" {
    const put = try opTypeFromActionAndValue(.set, .{ .str = "x" }, null, false);
    try std.testing.expect(put == .put);

    const inc = try opTypeFromActionAndValue(.increment, .{ .counter = .init(7) }, null, false);
    try std.testing.expectEqual(@as(i64, 7), inc.increment);

    // An increment of a string is a corrupt document, not a crash.
    try std.testing.expectError(
        error.InvalidValueType,
        opTypeFromActionAndValue(.increment, .{ .str = "x" }, null, false),
    );

    // A mark with no name is corrupt.
    try std.testing.expectError(
        error.InvalidValue,
        opTypeFromActionAndValue(.mark, .null_value, null, false),
    );

    const mark = try opTypeFromActionAndValue(.mark, .null_value, "bold", true);
    try std.testing.expectEqualStrings("bold", mark.mark_begin.name);
    try std.testing.expect(mark.mark_begin.expand);
}
