//! Scalar values, the value metadata word, and operation actions.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");

const ParseError = err.ParseError;
const Error = err.Error;
const ObjType = types.ObjType;
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

/// A scalar whose slices borrow their source unless obtained through `dup`.
/// Release explicitly duplicated payloads with `deinitOwned`; ordinary copies
/// are not independent owners (`value.rs:517-534`).
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

    /// The numerical datatype used by change serde (`value.rs:429-445`).
    pub const DataType = enum { counter, timestamp, bytes, uint, int, float64, undefined };

    /// Constructs a borrowed scalar from an idiomatic primitive.
    /// Strings and byte slices remain borrowed; use `dup` for independent storage.
    pub fn from(v: anytype) ScalarValue {
        const T = @TypeOf(v);
        if (T == ScalarValue) return v;
        if (T == Counter) return .{ .counter = v };
        return switch (@typeInfo(T)) {
            .void, .null => .null_value,
            .bool => .{ .bool_value = v },
            .int => |i| if (i.signedness == .signed) .{ .int = @intCast(v) } else .{ .uint = @intCast(v) },
            .comptime_int => if (v < 0) .{ .int = v } else .{ .uint = v },
            .float, .comptime_float => .{ .float = @floatCast(v) },
            .pointer => .{ .str = v },
            else => @compileError("ScalarValue.from requires a scalar, number, bool, string, or void"),
        };
    }

    /// Constructs a borrowed arbitrary byte scalar.
    pub fn fromBytes(v: []const u8) ScalarValue {
        return .{ .bytes = v };
    }

    /// Constructs an owned UTF-8 scalar from one Unicode scalar value.
    pub fn fromCodepoint(gpa: std.mem.Allocator, cp: u21) !OwnedScalarValue {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidCharacter;
        return (ScalarValue{ .str = buf[0..len] }).intoOwned(gpa);
    }

    /// Whether this scalar carries the indicated exact tag.
    pub fn isBytes(self: ScalarValue) bool {
        return self == .bytes;
    }
    /// Whether this scalar is a string.
    pub fn isStr(self: ScalarValue) bool {
        return self == .str;
    }
    /// Whether this scalar is a signed integer.
    pub fn isInt(self: ScalarValue) bool {
        return self == .int;
    }
    /// Whether this scalar is an unsigned integer.
    pub fn isUint(self: ScalarValue) bool {
        return self == .uint;
    }
    /// Whether this scalar is a floating-point number.
    pub fn isF64(self: ScalarValue) bool {
        return self == .float;
    }
    /// Whether this scalar is a counter.
    pub fn isCounter(self: ScalarValue) bool {
        return self == .counter;
    }
    /// Whether this scalar is a timestamp.
    pub fn isTimestamp(self: ScalarValue) bool {
        return self == .timestamp;
    }
    /// Whether this scalar is a boolean.
    pub fn isBoolean(self: ScalarValue) bool {
        return self == .bool_value;
    }
    /// Whether this scalar is null.
    pub fn isNull(self: ScalarValue) bool {
        return self == .null_value;
    }
    /// Borrows the byte payload, or returns null for another tag.
    pub fn asBytes(self: ScalarValue) ?[]const u8 {
        return if (self == .bytes) self.bytes else null;
    }
    /// Borrows the string payload, or returns null for another tag.
    pub fn asStr(self: ScalarValue) ?[]const u8 {
        return if (self == .str) self.str else null;
    }
    /// Returns the boolean payload, or null for another tag.
    pub fn asBool(self: ScalarValue) ?bool {
        return if (self == .bool_value) self.bool_value else null;
    }

    /// Rust's lossy numeric cast: integer casts wrap; float casts saturate,
    /// truncate fractions and map NaN to zero (`value.rs:725-779`).
    pub fn asI64(self: ScalarValue) ?i64 {
        return switch (self) {
            .int, .timestamp => |i| i,
            .uint => |u| @bitCast(u),
            .counter => |c| c.current,
            .float => |f| if (std.math.isNan(f)) 0 else if (f >= 0x1p63) std.math.maxInt(i64) else if (f <= -0x1p63) std.math.minInt(i64) else @intFromFloat(f),
            else => null,
        };
    }
    /// Rust's unsigned numeric cast, with wrapping signed integers and
    /// saturating floats (`value.rs:752-759`).
    pub fn asU64(self: ScalarValue) ?u64 {
        return switch (self) {
            .int, .timestamp => |i| @bitCast(i),
            .uint => |u| u,
            .counter => |c| @bitCast(c.current),
            .float => |f| if (std.math.isNan(f) or f <= 0) 0 else if (f >= 0x1p64) std.math.maxInt(u64) else @intFromFloat(f),
            else => null,
        };
    }
    /// Casts numeric tags to floating point, or returns null.
    pub fn asF64(self: ScalarValue) ?f64 {
        return switch (self) {
            .int, .timestamp => |i| @floatFromInt(i),
            .uint => |u| @floatFromInt(u),
            .counter => |c| @floatFromInt(c.current),
            .float => |f| f,
            else => null,
        };
    }
    /// Returns integer-like tags with wrapping Uint conversion; floats and
    /// nonnumeric tags return zero (`value.rs:807-813`).
    pub fn asI64OrDefault(self: ScalarValue) i64 {
        return if (self == .float) 0 else self.asI64() orelse 0;
    }
    /// Copies every borrowed payload. The caller releases with `deinitOwned`.
    /// OOM leaves the source untouched and transfers no allocation.
    pub fn dup(self: ScalarValue, gpa: std.mem.Allocator) !ScalarValue {
        return switch (self) {
            .str => |s| .{ .str = try gpa.dupe(u8, s) },
            .bytes => |s| .{ .bytes = try gpa.dupe(u8, s) },
            .actor_id => |a| .{ .actor_id = try ActorId.initCopy(gpa, a.bytes) },
            .unknown => |u| .{ .unknown = .{ .type_code = u.type_code, .bytes = try gpa.dupe(u8, u.bytes) } },
            else => self,
        };
    }
    /// Releases only a scalar obtained from `dup`, invalidating it.
    pub fn deinitOwned(self: *ScalarValue, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .str, .bytes => |s| gpa.free(s),
            .actor_id => |a| gpa.free(a.bytes),
            .unknown => |u| gpa.free(u.bytes),
            else => {},
        }
        self.* = undefined;
    }
    /// Returns an independent, single-owner scalar.
    pub fn intoOwned(self: ScalarValue, gpa: std.mem.Allocator) !OwnedScalarValue {
        return .{ .value = try self.dup(gpa) };
    }
    /// Copies the byte payload into caller-owned storage, refusing other tags.
    pub fn intoBytes(self: ScalarValue, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, self.asBytes() orelse return error.InvalidValueType);
    }
    /// Copies the string into caller-owned storage, refusing other tags.
    pub fn intoString(self: ScalarValue, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, self.asStr() orelse return error.InvalidValueType);
    }
    /// Formats using Rust Display syntax (`value.rs:889-903`).
    pub fn format(self: ScalarValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null_value => try w.writeAll("null"),
            .bool_value => |b| try w.writeAll(if (b) "true" else "false"),
            .int, .timestamp => |i| {
                if (self == .timestamp) try w.writeAll("Timestamp: ");
                try w.print("{d}", .{i});
            },
            .uint => |u| try w.print("{d}", .{u}),
            .float => |f| try w.print("{d:.324}", .{f}),
            .str => |s| try w.print("\"{s}\"", .{s}),
            .counter => |c| try w.print("Counter: {d}", .{c.current}),
            .bytes, .actor_id => {
                const bytes = if (self == .bytes) self.bytes else self.actor_id.bytes;
                try w.writeAll("\"[");
                for (bytes, 0..) |b, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.print("{d}", .{b});
                }
                try w.writeAll("]\"");
            },
            .unknown => |u| try w.print("unknown type {d}", .{u.type_code}),
        }
    }
    /// Writes an untagged Rust-compatible scalar JSON value.
    pub fn writeJson(self: ScalarValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return writeScalar(w, self);
    }
    /// Integrates scalar JSON with Zig's nested container/separator tracking.
    pub fn jsonStringify(self: ScalarValue, jws: *std.json.Stringify) !void {
        try jws.beginWriteRaw();
        try self.writeJson(jws.writer);
        jws.endWriteRaw();
    }
    /// Parses Rust's scalar JSON input domain; arrays and objects are rejected
    /// even though Bytes/Unknown serialize to them (legacy serde scalar:6-62).
    /// String storage belongs to the JSON parser's allocator/arena.
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !ScalarValue {
        return switch (source) {
            .null => .null_value,
            .bool => |b| .{ .bool_value = b },
            .integer => |i| if (i >= 0) .{ .uint = @intCast(i) } else .{ .int = i },
            .float => |f| .{ .float = f },
            .number_string => |s| blk: {
                if (!std.mem.eql(u8, s, "-0")) {
                    if (std.fmt.parseInt(u64, s, 10)) |u| break :blk .{ .uint = u } else |_| {}
                    if (std.fmt.parseInt(i64, s, 10)) |i| break :blk .{ .int = i } else |_| {}
                }
                const f = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
                if (!std.math.isFinite(f)) return error.Overflow;
                break :blk .{ .float = f };
            },
            .string => |s| .{ .str = try gpa.dupe(u8, s) },
            else => error.UnexpectedToken,
        };
    }
    /// Reads JSON through the same value parser as `jsonParseFromValue`.
    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ScalarValue {
        var raw_options = options;
        raw_options.parse_numbers = false;
        const parsed = try std.json.innerParse(std.json.Value, gpa, source, raw_options);
        return jsonParseFromValue(gpa, parsed, options);
    }

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

    /// Coerces to a numeric/bytes datatype (`value.rs:543-613`), borrowing
    /// unchanged byte payloads. Refusal leaves the original value untouched.
    pub fn asDatatype(self: ScalarValue, want: DataType) error{InvalidValueType}!ScalarValue {
        return switch (want) {
            .counter, .timestamp => blk: {
                const i = switch (self) {
                    .int => |v| v,
                    .uint => |v| std.math.cast(i64, v) orelse return error.InvalidValueType,
                    else => return error.InvalidValueType,
                };
                break :blk if (want == .counter) .{ .counter = .init(i) } else .{ .timestamp = i };
            },
            .bytes => if (self == .bytes) self else error.InvalidValueType,
            .int => .{ .int = self.asI64() orelse return error.InvalidValueType },
            .uint => .{ .uint = self.asU64() orelse return error.InvalidValueType },
            .float64 => .{ .float = self.asF64() orelse return error.InvalidValueType },
            .undefined => self,
        };
    }
};

/// A public value: its object kind or a scalar, never an object identity
/// (`value.rs:10-16`). Scalar payloads borrow their source.
pub const Value = union(enum) {
    scalar: ScalarValue,
    object: ObjType,

    /// Constructs the corresponding object-kind value.
    pub fn map() Value {
        return .{ .object = .map };
    }
    /// Constructs a list-kind value.
    pub fn list() Value {
        return .{ .object = .list };
    }
    /// Constructs a text-kind value.
    pub fn text() Value {
        return .{ .object = .text };
    }
    /// Constructs a legacy table-kind value.
    pub fn table() Value {
        return .{ .object = .table };
    }
    /// Constructs a scalar value from a primitive or an object kind.
    pub fn from(v: anytype) Value {
        if (@TypeOf(v) == Value) return v;
        if (@TypeOf(v) == ObjType) return .{ .object = v };
        return .{ .scalar = ScalarValue.from(v) };
    }
    /// Constructs a borrowed string value.
    pub fn str(v: []const u8) Value {
        return .{ .scalar = .{ .str = v } };
    }
    /// Constructs an integer value.
    pub fn int(v: i64) Value {
        return .{ .scalar = .{ .int = v } };
    }
    /// Constructs an unsigned integer value.
    pub fn uint(v: u64) Value {
        return .{ .scalar = .{ .uint = v } };
    }
    /// Constructs a floating point value.
    pub fn float(v: f64) Value {
        return .{ .scalar = .{ .float = v } };
    }
    /// Constructs a counter value.
    pub fn counter(v: i64) Value {
        return .{ .scalar = .{ .counter = .init(v) } };
    }
    /// Constructs a timestamp value.
    pub fn timestamp(v: i64) Value {
        return .{ .scalar = .{ .timestamp = v } };
    }
    /// Constructs a borrowed byte value.
    pub fn bytes(v: []const u8) Value {
        return .{ .scalar = .{ .bytes = v } };
    }
    /// Constructs an owned string value from one Unicode scalar value.
    pub fn fromCodepoint(gpa: std.mem.Allocator, cp: u21) !OwnedValue {
        const owned = try ScalarValue.fromCodepoint(gpa, cp);
        return .{ .value = .{ .scalar = owned.value } };
    }
    /// Whether this is an object kind.
    pub fn isObject(self: Value) bool {
        return self == .object;
    }
    /// Whether this is a scalar.
    pub fn isScalar(self: Value) bool {
        return self == .scalar;
    }
    /// The object kind, or null for scalars.
    pub fn asObject(self: Value) ?ObjType {
        return if (self == .object) self.object else null;
    }
    /// The borrowed scalar, or null for objects.
    pub fn asScalar(self: Value) ?ScalarValue {
        return if (self == .scalar) self.scalar else null;
    }
    /// Whether this scalar has the indicated tag; objects return false.
    pub fn isBytes(self: Value) bool {
        return if (self.asScalar()) |s| s.isBytes() else false;
    }
    /// Whether this scalar is a string.
    pub fn isStr(self: Value) bool {
        return if (self.asScalar()) |s| s.isStr() else false;
    }
    /// Whether this scalar is an integer.
    pub fn isInt(self: Value) bool {
        return if (self.asScalar()) |s| s.isInt() else false;
    }
    /// Whether this scalar is an unsigned integer.
    pub fn isUint(self: Value) bool {
        return if (self.asScalar()) |s| s.isUint() else false;
    }
    /// Whether this scalar is a float.
    pub fn isF64(self: Value) bool {
        return if (self.asScalar()) |s| s.isF64() else false;
    }
    /// Whether this scalar is a counter.
    pub fn isCounter(self: Value) bool {
        return if (self.asScalar()) |s| s.isCounter() else false;
    }
    /// Whether this scalar is a timestamp.
    pub fn isTimestamp(self: Value) bool {
        return if (self.asScalar()) |s| s.isTimestamp() else false;
    }
    /// Whether this scalar is a boolean.
    pub fn isBoolean(self: Value) bool {
        return if (self.asScalar()) |s| s.isBoolean() else false;
    }
    /// Whether this scalar is null.
    pub fn isNull(self: Value) bool {
        return if (self.asScalar()) |s| s.isNull() else false;
    }
    /// Borrows bytes, or returns null.
    pub fn asBytes(self: Value) ?[]const u8 {
        return if (self.asScalar()) |s| s.asBytes() else null;
    }
    /// Borrows a string, or returns null.
    pub fn asStr(self: Value) ?[]const u8 {
        return if (self.asScalar()) |s| s.asStr() else null;
    }
    /// Returns a lossy numeric conversion, or null.
    pub fn asI64(self: Value) ?i64 {
        return if (self.asScalar()) |s| s.asI64() else null;
    }
    /// Returns an unsigned numeric conversion, or null.
    pub fn asU64(self: Value) ?u64 {
        return if (self.asScalar()) |s| s.asU64() else null;
    }
    /// Returns a floating numeric conversion, or null.
    pub fn asF64(self: Value) ?f64 {
        return if (self.asScalar()) |s| s.asF64() else null;
    }
    /// Returns a boolean, or null.
    pub fn asBool(self: Value) ?bool {
        return if (self.asScalar()) |s| s.asBool() else null;
    }
    /// Copies a scalar into an independent owner, refusing objects.
    pub fn intoScalar(self: Value, gpa: std.mem.Allocator) !OwnedScalarValue {
        return (self.asScalar() orelse return error.InvalidValueType).intoOwned(gpa);
    }
    /// Copies byte storage, refusing other values.
    pub fn intoBytes(self: Value, gpa: std.mem.Allocator) ![]u8 {
        return (self.asScalar() orelse return error.InvalidValueType).intoBytes(gpa);
    }
    /// Copies string storage, refusing other values.
    pub fn intoString(self: Value, gpa: std.mem.Allocator) ![]u8 {
        return (self.asScalar() orelse return error.InvalidValueType).intoString(gpa);
    }
    /// Copies every scalar payload; objects own no allocation.
    pub fn intoOwned(self: Value, gpa: std.mem.Allocator) !OwnedValue {
        return .{ .value = switch (self) {
            .object => self,
            .scalar => |s| .{ .scalar = try s.dup(gpa) },
        } };
    }
    /// Compares object kinds or scalars by content.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .object => |o| o == b.object,
            .scalar => |s| s.eql(b.scalar),
        };
    }
    /// Writes Rust's object/scalar Display form.
    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .scalar => |s| try s.format(w),
            .object => |o| try w.writeAll(switch (o) {
                .map => "map",
                .list => "list",
                .text => "text",
                .table => "table",
            }),
        }
    }
};

/// Independently owned scalar storage. Copies share ownership; deinit once.
pub const OwnedScalarValue = struct {
    value: ScalarValue,
    /// Releases copied payloads with the allocator used to construct them.
    pub fn deinit(self: *OwnedScalarValue, gpa: std.mem.Allocator) void {
        self.value.deinitOwned(gpa);
        self.* = undefined;
    }
};

/// Independently owned public value storage. Copies are not new owners.
pub const OwnedValue = struct {
    value: Value,
    /// Releases scalar storage with the allocator used for `intoOwned`.
    pub fn deinit(self: *OwnedValue, gpa: std.mem.Allocator) void {
        if (self.value == .scalar) self.value.scalar.deinitOwned(gpa);
        self.* = undefined;
    }
};

// Canonical scalar JSON renderer, moved from AutoSerde. Rust untagged serde
// writes counter/timestamp as integers and byte scalars as number arrays.
fn writeScalar(w: *std.Io.Writer, s: ScalarValue) std.Io.Writer.Error!void {
    switch (s) {
        .null_value => try w.writeAll("null"),
        .bool_value => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .uint => |u| try w.print("{d}", .{u}),
        .counter => |c| try w.print("{d}", .{c.current}),
        .timestamp => |t| try w.print("{d}", .{t}),
        .float => |f| try writeJsonFloat(f, w),
        .str => |s1| try writeJsonString(s1, w),
        .bytes => |b| try writeJsonBytes(b, w),
        .actor_id => |a| try writeJsonBytes(a.bytes, w),
        .unknown => |u| {
            try w.writeAll("{\"type_code\":");
            try w.print("{d}", .{u.type_code});
            try w.writeAll(",\"bytes\":");
            try writeJsonBytes(u.bytes, w);
            try w.writeAll("}");
        },
    }
}

fn writeJsonString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var run: usize = 0;
    for (s, 0..) |b, i| {
        if (shortEscape(b)) |esc| {
            try w.writeAll(s[run..i]);
            try w.writeAll(esc);
            run = i + 1;
        } else if (b < 0x20) {
            try w.writeAll(s[run..i]);
            try w.print("\\u{x:0>4}", .{b});
            run = i + 1;
        }
    }
    try w.writeAll(s[run..]);
    try w.writeByte('"');
}

fn shortEscape(b: u8) ?[]const u8 {
    return switch (b) {
        0x08 => "\\b",
        0x09 => "\\t",
        0x0a => "\\n",
        0x0c => "\\f",
        0x0d => "\\r",
        0x22 => "\\\"",
        0x5c => "\\\\",
        else => null,
    };
}

fn writeJsonBytes(b: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (b, 0..) |x, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{x});
    }
    try w.writeByte(']');
}

// zmij-1.0.23 chooses fixed notation in this exponent interval, with a
// decimal suffix on whole-valued floats and explicit positive exponent signs.
const fixed_lo: i32 = -5;
const fixed_hi: i32 = 15;

fn writeJsonFloat(v: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!std.math.isFinite(v)) {
        try w.writeAll("null");
        return;
    }
    var buf: [24]u8 = undefined;
    try w.writeAll(renderF64(&buf, v));
}

fn renderF64(buf: []u8, v: f64) []const u8 {
    std.debug.assert(std.math.isFinite(v));
    const d = std.fmt.float.binaryToDecimal(
        u64,
        @bitCast(v),
        std.math.floatMantissaBits(f64),
        std.math.floatExponentBits(f64),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );
    var at: usize = 0;
    if (d.sign) {
        buf[at] = '-';
        at += 1;
    }
    if (d.mantissa == 0) {
        @memcpy(buf[at..][0..3], "0.0");
        return buf[0 .. at + 3];
    }
    const width = decimalWidth(d.mantissa);
    const exp10: i32 = d.exponent + @as(i32, @intCast(width)) - 1;
    var digits: [17]u8 = undefined;
    writeDigits(&digits, d.mantissa, width);
    const w: i32 = @intCast(width);
    if (exp10 >= fixed_lo and exp10 <= fixed_hi) {
        if (w - 1 <= exp10) {
            @memcpy(buf[at..][0..width], digits[0..width]);
            const zeros: usize = @intCast(exp10 + 3 - w);
            @memset(buf[at + width ..][0..zeros], '0');
            buf[at + @as(usize, @intCast(exp10 + 1))] = '.';
            return buf[0 .. at + @as(usize, @intCast(exp10 + 3))];
        }
        if (exp10 >= 0) {
            const point: usize = @intCast(exp10 + 1);
            @memcpy(buf[at..][0..point], digits[0..point]);
            buf[at + point] = '.';
            @memcpy(buf[at + point + 1 ..][0 .. width - point], digits[point..width]);
            return buf[0 .. at + width + 1];
        }
        const lead: usize = @intCast(1 - exp10);
        @memcpy(buf[at..][0..2], "0.");
        @memset(buf[at + 2 ..][0 .. lead - 2], '0');
        @memcpy(buf[at + lead ..][0..width], digits[0..width]);
        return buf[0 .. at + lead + width];
    }
    buf[at] = digits[0];
    at += 1;
    if (w > 1) {
        buf[at] = '.';
        @memcpy(buf[at + 1 ..][0 .. width - 1], digits[1..width]);
        at += width;
    }
    buf[at] = 'e';
    at += 1;
    buf[at] = if (exp10 >= 0) '+' else '-';
    at += 1;
    var nbuf: [4]u8 = undefined;
    const digits_of_exp = std.fmt.bufPrint(&nbuf, "{d}", .{
        @as(u32, @intCast(@abs(exp10))),
    }) catch unreachable;
    @memcpy(buf[at..][0..digits_of_exp.len], digits_of_exp);
    return buf[0 .. at + digits_of_exp.len];
}

fn decimalWidth(v: u64) usize {
    var n = v;
    var width: usize = 1;
    while (n >= 10) : (width += 1) n /= 10;
    return width;
}

fn writeDigits(buf: []u8, v: u64, width: usize) void {
    var n = v;
    var i = width;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

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

test "API parity public values preserve object kinds and numeric coercions" {
    const gpa = std.testing.allocator;
    inline for (.{ types.ObjType.map, types.ObjType.list, types.ObjType.text, types.ObjType.table }) |kind| {
        const v: Value = .{ .object = kind };
        try std.testing.expectEqual(kind, v.asObject().?);
        try std.testing.expect(v.isObject());
        try std.testing.expect(!v.isScalar());
    }
    const high: ScalarValue = .{ .uint = @as(u64, 1) << 63 };
    const maximum: ScalarValue = .{ .uint = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.minInt(i64), high.asI64().?);
    try std.testing.expectEqual(@as(i64, -1), maximum.asI64().?);
    const original = try gpa.dupe(u8, "consumer");
    var owned = try (ScalarValue{ .str = original }).intoOwned(gpa);
    defer owned.deinit(gpa);
    gpa.free(original);
    try std.testing.expectEqualStrings("consumer", owned.value.asStr().?);
}

test "API parity scalar formatter and JSON preserve unknown bytes" {
    const gpa = std.testing.allocator;
    const v: ScalarValue = .{ .unknown = .{ .type_code = 12, .bytes = &.{ 0, 255 } } };
    const json = try std.json.Stringify.valueAlloc(gpa, v, .{});
    defer gpa.free(json);
    try std.testing.expectEqualStrings("{\"type_code\":12,\"bytes\":[0,255]}", json);
    const rendered = try std.fmt.allocPrint(gpa, "{f}", .{ScalarValue{ .int = -7 }});
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("-7", rendered);
}

test "API parity scalar numeric casts match Rust saturation and wrapping" {
    const nan: ScalarValue = .{ .float = std.math.nan(f64) };
    const inf: ScalarValue = .{ .float = std.math.inf(f64) };
    const neg_inf: ScalarValue = .{ .float = -std.math.inf(f64) };
    const negative: ScalarValue = .{ .int = -1 };
    try std.testing.expectEqual(@as(?i64, 0), nan.asI64());
    try std.testing.expectEqual(@as(?u64, 0), nan.asU64());
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), inf.asI64());
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), neg_inf.asI64());
    try std.testing.expectEqual(@as(?u64, 0), neg_inf.asU64());
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), negative.asU64());
    try std.testing.expectEqual(@as(?i64, -7), (ScalarValue{ .float = -7.9 }).asI64());
    try std.testing.expect((ScalarValue{ .str = "7" }).asI64() == null);
}

test "API parity nested scalar JSON preserves unsigned limits and rejects unsupported shapes" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(ScalarValue, gpa, "18446744073709551615", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), parsed.value.uint);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(ScalarValue, gpa, "[0,255]", .{}));
    const values = [_]ScalarValue{ .{ .counter = .init(7) }, .{ .str = "a\nb" }, .{ .float = 1e21 } };
    const json = try std.json.Stringify.valueAlloc(gpa, values, .{});
    defer gpa.free(json);
    try std.testing.expectEqualStrings("[7,\"a\\nb\",1e+21]", json);
    const refused: ScalarValue = .{ .uint = std.math.maxInt(u64) };
    try std.testing.expectError(error.InvalidValueType, refused.asDatatype(.counter));
    try std.testing.expectEqual(@as(i64, -1), (try refused.asDatatype(.int)).int);
}

test "API parity owned scalar and codepoint copies clean up allocation failures" {
    const scenario = struct {
        fn exercise(gpa: std.mem.Allocator) !void {
            const borrowed: ScalarValue = .{ .unknown = .{ .type_code = 15, .bytes = &.{ 0, 255, 128 } } };
            var owned = try borrowed.intoOwned(gpa);
            defer owned.deinit(gpa);
            var codepoint = try Value.fromCodepoint(gpa, 0x1f600);
            defer codepoint.deinit(gpa);
            try std.testing.expectEqualStrings("\xf0\x9f\x98\x80", codepoint.value.asStr().?);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario.exercise, .{});
}
