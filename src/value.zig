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

    /// The four wire bits this tag stands for. An `.unknown` above `0x0f` has
    /// no place in a value metadata word, and [`ValueMeta.init`](value.zig)
    /// asserts against it.
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

    /// The tag named by `v`'s low four bits; the high four bits are ignored.
    /// Codes 10 through 15 remain `.unknown` values with their nibble intact.
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

/// A value metadata word: the byte length of a value in its high 60 bits, and
/// its type tag in the low nibble. One column of these accompanies the raw
/// value column.
///
/// **The word is the wire format**, not this crate's packing: upstream writes
/// `(length << 4) | type` and reads the length back as `(raw >> 4) as usize`
/// ([`meta.rs:20-43`, `:36`](../../github-automerge-automerge/rust/automerge/src/op_set2/meta.rs)).
pub const ValueMeta = struct {
    /// The wire word, `(byte_length << 4) | type_code`. Read it through
    /// [`length`](ValueMeta.length) and [`typeCode`](ValueMeta.typeCode)
    /// rather than shifting it yourself: `length` is the checked reader and
    /// the raw shift is not.
    raw: u64,

    /// The largest byte length the word's 60-bit length field can carry. No
    /// `usize` on a supported target reaches it, which is why
    /// [`init`](ValueMeta.init) only asserts the bound: a word that arrived
    /// over the wire was not written from a `usize`, so its length still has
    /// to be checked.
    pub const max_length: u64 = (@as(u64, 1) << 60) - 1;

    /// The word for a value of `byte_len` bytes of type `typ`, for a length
    /// this port computed from a value it holds.
    ///
    /// `byte_len` must not exceed [`max_length`](ValueMeta.max_length) and
    /// `typ`'s code must fit the low nibble. Both are `std.debug.assert`s:
    /// Debug and ReleaseSafe diagnose a violation, ReleaseFast and
    /// ReleaseSmall do not check them, and a length at or above 2^60 would be
    /// truncated into the word without a diagnostic in those modes. A length
    /// that did not come from a value in hand goes through
    /// [`initChecked`](ValueMeta.initChecked), which refuses instead.
    pub fn init(typ: ValueType, byte_len: usize) ValueMeta {
        std.debug.assert(byte_len <= max_length);
        std.debug.assert(typ.code() <= 0x0f);
        return .{ .raw = (@as(u64, byte_len) << 4) | typ.code() };
    }

    /// The word for a value of `byte_len` bytes, or `error.Overflow` when that
    /// length does not fit the word's 60-bit field. This is the constructor
    /// for a length this port did not measure; [`init`](ValueMeta.init) is
    /// for one it did.
    ///
    /// `ValueMeta` is a value, so there is nothing to unwind on the refusal:
    /// the caller simply has no word. `typ` still has to satisfy
    /// [`init`](ValueMeta.init)'s nibble precondition, which is a programmer
    /// error and not checked here either.
    pub fn initChecked(typ: ValueType, byte_len: usize) ParseError!ValueMeta {
        if (byte_len > max_length) return error.Overflow;
        std.debug.assert(typ.code() <= 0x0f);
        return .{ .raw = (@as(u64, byte_len) << 4) | typ.code() };
    }

    /// The word as it was read, without inspecting it. A word this port wrote
    /// is always well formed; one off the wire is not, and
    /// [`length`](ValueMeta.length) is what checks it.
    pub fn fromRaw(raw: u64) ValueMeta {
        return .{ .raw = raw };
    }

    /// The tag the low nibble names.
    pub fn typeCode(self: ValueMeta) ValueType {
        return ValueType.fromCode(@truncate(self.raw));
    }

    /// The length in bytes of the value that follows in the raw value column.
    ///
    /// `error.Overflow` when the declared length is wider than a `usize` on
    /// this target, which is what a corrupt or hostile word can ask for on a
    /// 32-bit build. Upstream narrows the same shift with `as usize`
    /// ([`meta.rs:36`](../../github-automerge-automerge/rust/automerge/src/op_set2/meta.rs))
    /// and turns the overflow into a short read; this crate's parser promise
    /// is a refusal and never a trap, so the cast is checked.
    pub fn length(self: ValueMeta) ParseError!usize {
        return std.math.cast(usize, self.raw >> 4) orelse error.Overflow;
    }
};

/// A scalar value.
///
/// **Every slice this type carries is a borrow.** `str` and `bytes` point
/// into the arena that owns the value column, `actor_id` borrows the actor
/// table's bytes the way every [`ActorId`](types.zig) does, and
/// `unknown.bytes` points into that same value column. None of them is copied
/// here and none is released here.
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
    /// Borrows the actor table's bytes; see [`ActorId`](types.zig).
    actor_id: ActorId,
    /// A value from a future version of automerge, preserved verbatim.
    unknown: UnknownValue,

    /// A value whose wire tag this build does not know, kept exactly as it
    /// was read so that a document written by a newer automerge survives a
    /// round trip through this one.
    pub const UnknownValue = struct {
        /// The wire tag the bytes arrived under.
        type_code: u8,
        /// Borrows the raw value column; see [`ScalarValue`](value.zig).
        bytes: []const u8,
    };

    /// A counter: an integer that merges by addition.
    ///
    /// **The addition is modular and reports nothing.** `current` is an
    /// `i64` and every fold adds with wrapping arithmetic — `+%` in the op
    /// set's counter fixups ([`op.zig:2065`](opset/op.zig)) — so a total that
    /// leaves the `i64` range wraps modulo 2^64 instead of trapping. Upstream
    /// adds with a plain `i64` `+`
    /// ([`op_set2/op.rs:993`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    /// which is checked in a debug build and wraps in a release one; this
    /// wraps in every mode, because a document whose increments overflow
    /// `i64` is corrupt and there is no value to report.
    ///
    /// A caller that adds to a counter adds it the same way, with `+%`.
    pub const Counter = struct {
        /// The count as of the state being read.
        current: i64,

        /// The counter holding `v`.
        pub fn init(v: i64) Counter {
            return .{ .current = v };
        }

        /// Whether the two counters hold the same count.
        pub fn eql(a: Counter, b: Counter) bool {
            return a.current == b.current;
        }
    };

    /// Whether the two values are the same value of the same type. Two
    /// scalars of different tags are never equal, and slices are compared by
    /// content rather than by pointer.
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
    ///
    /// A map or table is `error.NotAnObject`, because a scalar is never one.
    /// A list or a text object turns an integer into a counter and leaves
    /// every other value as it is; a `uint` that does not fit an `i64` is
    /// `error.InvalidValueType` and the value is returned unchanged.
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
    /// The value itself, with the borrows [`ScalarValue`](value.zig) states.
    scalar: ScalarValue,
    /// An object id, whose actor bytes borrow the document that minted it.
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

    /// The action a wire code names. A code outside the eight the format
    /// defines is `error.InvalidAction`.
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
    /// The value itself, with the borrows [`ScalarValue`](value.zig) states.
    value: ScalarValue,
    /// Borrows the raw value column of the op set this reference came from,
    /// and dies with it. Nothing copies these bytes.
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

    /// A mark opening with a borrowed name and scalar payload.
    pub const MarkBegin = struct {
        /// Whether the rows the mark covers stay hidden from a read.
        expand: bool,
        /// Borrows the op set's mark-name column, like
        /// [`ScalarValueRef.raw`](value.zig).
        name: []const u8,
        /// Never absent: a mark begin with no value of its own carries
        /// `null_value` (`op_set2/types.rs:59-60`).
        value: ScalarValue,
    };

    /// A mark end carries the expand flag and nothing else. Upstream's
    /// `MarkEnd(bool)` (`op_set2/types.rs:135`) has no name and no value,
    /// because the end row's `mark_name` column is null and the name is read
    /// back from the begin it closes.
    pub const MarkEnd = struct {
        /// Whether the rows the mark covers stay hidden from a read.
        expand: bool,
    };
};

/// Combines an action, a value, and the mark columns into an op type, the
/// inverse of what the encoder does. Rejects an action and value that cannot
/// occur together, which is a corrupt document rather than a bug.
///
/// `error.InvalidValueType` is the only refusal: an `increment` whose value
/// is not a number, or is a `uint` too wide for an `i64`. `mark_name` and the
/// slices inside `value` are borrowed into the result, not copied.
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
        // A mark row is a begin when its `mark_name` column holds a name and
        // an end when that column is null, so the name alone decides which.
        // The mark_name column is nullable (`op_set2/columns.rs:32`) and the
        // op's mark name is passed straight through
        // (`op_set2/op.rs:1015-1017`), so `null` is an end and not a
        // corrupt document (`op_set2/types.rs:177-186`).
        .mark => if (mark_name) |name| .{
            .mark_begin = .{ .expand = expand, .name = name, .value = value },
        } else .{ .mark_end = .{ .expand = expand } },
    };
}

test "ValueMeta packs length and type" {
    const m = ValueMeta.init(.string, 5);
    try std.testing.expectEqual(@as(usize, 5), try m.length());
    try std.testing.expectEqual(ValueType.string, m.typeCode());

    const n = ValueMeta.init(.{ .unknown = 12 }, 300);
    try std.testing.expectEqual(@as(usize, 300), try n.length());
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

    // A mark row with a name is a begin, and it carries the mark's value.
    const begin = try opTypeFromActionAndValue(.mark, .{ .int = 1 }, "bold", true);
    try std.testing.expectEqualStrings("bold", begin.mark_begin.name);
    try std.testing.expect(begin.mark_begin.expand);
    try std.testing.expect(begin.mark_begin.value.eql(.{ .int = 1 }));

    // A mark begin with no value of its own is not an absent value; it
    // carries null.
    const bare = try opTypeFromActionAndValue(.mark, .null_value, "bold", false);
    try std.testing.expect(bare.mark_begin.value == .null_value);
    try std.testing.expect(!bare.mark_begin.expand);

    // No name is a mark end, not a corrupt document: the mark_name column is
    // nullable and an end row leaves it null
    // (`op_set2/columns.rs:32`, `op_set2/types.rs:177-186`).
    const end = try opTypeFromActionAndValue(.mark, .null_value, null, true);
    try std.testing.expect(end == .mark_end);
    try std.testing.expect(end.mark_end.expand);
}

test "metadata lengths preserve the field boundary or refuse target-width overflow" {
    const string_type: ValueType = .string;
    const string_code = string_type.code();
    const widest = ValueMeta.fromRaw((ValueMeta.max_length << 4) | string_code);
    if (std.math.cast(usize, ValueMeta.max_length)) |widest_len| {
        try std.testing.expectEqual(widest_len, try widest.length());
    } else {
        try std.testing.expectError(error.Overflow, widest.length());
    }

    // `initChecked` refuses a length the field cannot carry. Only a target
    // with a 64-bit `usize` has such a length: a 32-bit one's widest value
    // is 2^32 - 1, which the field always carries.
    if (@bitSizeOf(usize) > 32) {
        try std.testing.expectError(
            error.Overflow,
            ValueMeta.initChecked(.string, @as(usize, 1) << 60),
        );
    }

    const checked = try ValueMeta.initChecked(.string, 4096);
    try std.testing.expectEqual(@as(usize, 4096), try checked.length());
}

test "counters merge by wrapping addition" {
    // The op set's counter fixups add with `+%`, so a document whose
    // increments overflow i64 wraps rather than trapping or refusing.
    const high = ScalarValue.Counter.init(std.math.maxInt(i64));
    const one = ScalarValue.Counter.init(1);
    try std.testing.expectEqual(
        ScalarValue.Counter.init(std.math.minInt(i64)),
        ScalarValue.Counter{ .current = high.current +% one.current },
    );
    try std.testing.expectEqual(
        ScalarValue.Counter.init(3),
        ScalarValue.Counter{ .current = one.current +% one.current +% one.current },
    );
}
