//! Composite logical columns: `Key`, `ObjId`, `OpIdList`, `Group`, `Value`.
//!
//! A document's operation set is stored as *low-level* columns — one per
//! integer, per boolean, per string — and a composite column presents
//! several of them as one logical value. The composite owns nothing: it is
//! a view over columns the caller holds, and its splice rewrites those
//! columns in place. That is the whole difference from upstream, where a
//! "range" is a pair of byte offsets into one flat buffer
//! (`column_range/rle.rs:15-19`, `raw.rs:8-9`); here the same range is a set
//! of pointers, and `Column.splice` is what a splice drives
//! (`hexane/src/column.rs:1773`).
//!
//! # The invariant
//!
//! A composite has no rows of its own, so its row count *is* the row count
//! of its underlying columns, and every write has to leave them all in
//! step. Two rules keep that true:
//!
//! * a view is built by `init`, which refuses columns that disagree, and
//!   `checkLengths` re-checks it — the columns come from bytes a peer sent,
//!   so a disagreement is a `ParseError` and never a trap;
//! * a splice builds every replacement *value* before it rewrites a
//!   column, so the only way it can fail on a well-formed column is an
//!   allocation, and it fails before anything has changed. A composite's
//!   columns therefore cannot be left out of step by a failed splice; a
//!   group, whose payload columns are rewritten one after another, is the
//!   one exception, and a group out of step is still a value a
//!   `checkLengths` reports rather than a value a cursor reads.
//!
//! # What each composite is a view over
//!
//! | composite | columns | upstream |
//! | --- | --- | --- |
//! | [`KeyColumn`] | actor, delta counter, string | `KeyRange`, `key.rs:31-35` |
//! | [`ObjIdColumn`] | actor, counter | `ObjIdRange`, `obj_id.rs:14-17` |
//! | [`OpIdList`] | count, flat actor, flat counter | `OpIdListRange`, `opid_list.rs:18-22` |
//! | [`Group`] | count, plus grouped columns | `GroupRange`, `generic/group.rs:16-19` |
//! | [`Value`] | metadata, raw bytes | `ValueRange`, `value.rs:25-28` |
//!
//! # Strings
//!
//! Upstream's key, mark-name and string columns carry the string itself
//! (`RleRange<SmolStr>`). This port's codecs are integer-only —
//! `hexane::Rle` and friends refuse a non-integer payload
//! (`src/hexane/column.zig:587-589`) — so those columns hold a counter into
//! the document's string table instead, which is what plan §5.3 calls
//! `Column(?Interned)`. The composite is the same view either way: what
//! changes is what the caller does with the counter, and turning a counter
//! back into bytes is the string table's job, not the column's.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const scalar = @import("../value.zig");
const leb128 = @import("../leb128.zig");
const hexane = @import("../hexane/column.zig");

const ParseError = err.ParseError;
const Column = hexane.Column;
const OpId = types.OpId;
const ExId = types.ExId;
const ActorIdx = types.ActorIdx;
const ScalarValue = scalar.ScalarValue;

/// The slab codecs, which live beside `Column` in the hexane layer rather
/// than inside it: `Column` is a function of a value type and a codec
/// (`src/hexane/column.zig:1148-1156`), and the codecs are its siblings
/// (`column.zig:587`, `:656`, `:721`, `:802`, `:944`, `:950`).
const RleOption = hexane.RleOption;
const Delta = hexane.Delta;
const DeltaOption = hexane.DeltaOption;
const ValueMeta = scalar.ValueMeta;
const ValueType = scalar.ValueType;

/// An actor index, or a counter into the string table, nullable. On the wire
/// an RLE run sequence of unsigned LEB128 values with null runs, which is
/// `hexane::Column<Option<ActorIdx>>` (`op_set2/columns.rs:19-27`).
pub const IndexCol = Column(?u32, RleOption(u32));

/// A counter that is delta coded, nullable: an operation's counter, a key's
/// counter, a predecessor's counter (`op_set2/columns.rs:26, :28`).
///
/// The counter is a `u32` rather than upstream's `i64`, so a negative one
/// is refused by the codec rather than by the composite
/// (`column_range/key.rs:170-176`, `opid_list.rs:219-233`).
pub const CounterCol = Column(?u32, DeltaOption);

/// A nullable unsigned integer on an RLE column, read as `u64` because that
/// is the width upstream reads it at (`column_range/obj_id.rs:14-17`,
/// `opid_list.rs:18-22`, `value.rs:25-28`).
pub const UintCol = Column(?u64, RleOption(u64));

/// A nullable signed integer on a delta column: the generic "delta" simple
/// column of a group (`column_range/generic/simple.rs:12-20`).
pub const SignedCol = Column(?i64, Delta(?i64));

/// A boolean column: alternating run counts and no value bytes
/// (`column_range/boolean.rs:9-10`). A boolean has no absent row, so its
/// value type is `bool` and not `?bool`.
pub const BoolCol = Column(bool, hexane.Bool);

/// How many ids an op-id list row is allowed to reserve room for before the
/// first read (`opid_list.rs:201-206`): the count is bytes a peer sent, and
/// upstream caps its `Vec::with_capacity` for that reason.
const opid_list_reserve_cap: usize = 100;

// ── The raw value column ───────────────────────────────────────────────────

/// The raw value column: the bytes the metadata words describe, with no run
/// structure of its own (`column_range/raw.rs:8-13`, `hexane::RawColumn`).
///
/// It is an owned buffer rather than a `Column` because the format gives it
/// nothing to index: a row's payload starts where the previous row's ended,
/// and only the metadata column knows how long that is. A splice rebuilds
/// the whole buffer, which is why replacing it whole is the natural
/// operation.
pub const Raw = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    /// An empty raw column.
    pub fn init(gpa: std.mem.Allocator) Raw {
        return .{ .gpa = gpa };
    }

    /// Frees the buffer.
    pub fn deinit(self: *Raw) void {
        self.bytes.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many bytes the column holds. Not a row count: the row count is
    /// the metadata column's.
    pub fn len(self: *const Raw) usize {
        return self.bytes.items.len;
    }

    /// The column's bytes, in row order and without separators.
    pub fn items(self: *const Raw) []const u8 {
        return self.bytes.items;
    }

    /// Appends one row's payload.
    pub fn append(self: *Raw, gpa: std.mem.Allocator, payload: []const u8) ParseError!void {
        try self.bytes.appendSlice(gpa, payload);
    }

    /// A fresh column holding exactly `payload`, for a splice to move in
    /// once every other column of its composite is built.
    pub fn rebuilt(gpa: std.mem.Allocator, payload: []const u8) ParseError!Raw {
        var fresh: Raw = .init(gpa);
        errdefer fresh.deinit();
        try fresh.bytes.appendSlice(gpa, payload);
        return fresh;
    }

    /// A read cursor over the column's bytes.
    pub fn cursor(self: *const Raw) Cursor {
        return .{ .bytes = self.bytes.items };
    }

    /// A read cursor positioned at the column's first byte.
    pub const Cursor = struct {
        bytes: []const u8,
        at: usize = 0,

        /// The next `n` bytes, or `error.LengthExceedsInput` when the column
        /// holds fewer — which is what a value whose metadata word claims
        /// more bytes than remain decodes as
        /// (`column_range/value.rs:265-283`).
        pub fn take(self: *Cursor, n: usize) ParseError![]const u8 {
            const end = std.math.add(usize, self.at, n) catch return error.Overflow;
            if (end > self.bytes.len) return error.LengthExceedsInput;
            const out = self.bytes[self.at..end];
            self.at = end;
            return out;
        }
    };
};

// ── Column cursors ─────────────────────────────────────────────────────────

/// A column cursor that knows how many rows it has left.
///
/// `Column.Iterator` answers with null at the end of a column but does not
/// say *why* it stopped, and every composite here has to tell "the column
/// ran out" from "this row spells nothing out in it". So the count travels
/// beside the iterator, and `next` keeps the two apart exactly the way
/// upstream's decoders do: the outer null is an exhausted column, the inner
/// one an absent row — upstream's `Option<Option<T>>`
/// (`column_range/key.rs:145-183`, `obj_id.rs:127-143`).
pub fn Counted(comptime Col: type) type {
    return struct {
        const Self = @This();

        it: Col.Iterator,
        left: usize,

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: *const Col) ParseError!Self {
            return .{ .it = try col.iterator(), .left = col.len() };
        }

        /// The next row, or null when the column has no rows left.
        pub fn next(self: *Self) ParseError!?Col.Value {
            if (self.left == 0) return null;
            self.left -= 1;
            return (try self.it.next()) orelse error.InvalidValue;
        }

        /// Steps over one row, for a caller that knows the row is there and
        /// does not want its value. A column that has run out is a
        /// malformed one.
        pub fn skip(self: *Self) ParseError!void {
            if (self.left == 0) return error.InvalidValue;
            self.left -= 1;
            _ = (try self.it.next()) orelse return error.InvalidValue;
        }

        /// Whether every row has been read.
        pub fn done(self: *const Self) bool {
            return self.left == 0;
        }
    };
}

/// The `Vec::splice` range check, reported rather than asserted: the columns
/// a composite reads were built from bytes a peer sent, and every one of
/// these entry points is reachable from a document. Upstream panics here
/// (`column_range/rle.rs:66`, `delta.rs:36`).
fn checkRange(len: usize, index: usize, del: usize) ParseError!void {
    if (index > len or del > len - index) return error.InvalidValue;
}

/// Whether a cell is one of upstream's `None | Some(None)` — the column ran
/// out, or the row spells nothing out in it (`column_range/key.rs:145-183`,
/// `obj_id.rs:127-143`). The argument is a cell of a nullable column, so
/// the outer null is an exhausted column and the inner one an absent row.
fn absent(cell: anytype) bool {
    if (cell == null) return true;
    return cell.? == null;
}

/// A column holding exactly `all`.
fn rebuilt(comptime Col: type, gpa: std.mem.Allocator, all: []const Col.Value) ParseError!Col {
    var fresh = try Col.init(gpa);
    errdefer fresh.deinit();
    try fresh.extend(gpa, all);
    return fresh;
}

/// A fresh column holding `col` with the rows `[index, index + del)`
/// replaced by `added`.
///
/// Building the whole replacement first is what makes a composite's splice
/// all-or-nothing: the only way this fails is an allocation, and it fails
/// before anything has moved. It decodes, skips and re-encodes, so it costs
/// what upstream's `RleRange::splice` costs (`column_range/rle.rs:40-93`,
/// `delta.rs:31-70`).
fn replacement(
    comptime Col: type,
    gpa: std.mem.Allocator,
    col: *const Col,
    index: usize,
    del: usize,
    added: []const Col.Value,
) ParseError!Col {
    try checkRange(col.len(), index, del);
    var fresh = try Col.init(gpa);
    errdefer fresh.deinit();
    var it = try col.iterator();
    var i: usize = 0;
    while (i < index) : (i += 1) {
        try fresh.append(gpa, (try it.next()) orelse return error.InvalidValue);
    }
    i = 0;
    while (i < del) : (i += 1) {
        _ = (try it.next()) orelse return error.InvalidValue;
    }
    try fresh.extend(gpa, added);
    while (try it.next()) |row| try fresh.append(gpa, row);
    return fresh;
}

/// Moves `fresh` into `dest` and frees what was there. Both types must be
/// the same; a composite commits its columns only once every replacement has
/// been built, so this never runs on a half-built set.
fn commit(dest: anytype, fresh: anytype) void {
    std.debug.assert(@TypeOf(dest.*) == @TypeOf(fresh));
    dest.deinit();
    dest.* = fresh;
}

/// One row's count as a row count. A count that does not fit a `usize` names
/// more rows than the buffer could hold.
fn asCount(v: u64) ParseError!usize {
    return std.math.cast(usize, v) orelse error.TooLarge;
}

// ── Value ──────────────────────────────────────────────────────────────────

/// The metadata word and the payload of one scalar value
/// (`column_range/value.rs:382-463`). The word is `(byte_length << 4) |
/// type_code`, and the payload is that many bytes of the raw column.
pub const Value = struct {
    /// One metadata word per row.
    meta: *UintCol,
    /// The payloads, in row order and without separators.
    raw: *Raw,

    /// A value column over `meta` and `raw`.
    ///
    /// The two are not in step by construction and must not be: `meta` is a
    /// row count, `raw` a byte count, and a row with no payload (a null, a
    /// boolean) adds a word and no bytes. What must hold is that the words
    /// describe the bytes — which is what reading a value checks.
    pub fn init(meta: *UintCol, raw: *Raw) Value {
        return .{ .meta = meta, .raw = raw };
    }

    /// The number of rows.
    pub fn len(self: Value) usize {
        return self.meta.len();
    }

    /// Whether the column holds no rows.
    pub fn isEmpty(self: Value) bool {
        return self.meta.len() == 0;
    }

    /// How many bytes the payloads take. Not a row count.
    pub fn rawLen(self: Value) usize {
        return self.raw.len();
    }

    /// The value at `index`, or null past the end.
    ///
    /// O(index): the raw payloads are a single sequential stream, so a
    /// random read has to walk the rows before it to find where the row
    /// starts. [`Value.iterator`] is the cheap path, and the op-set loader
    /// always takes it.
    pub fn get(self: Value, index: usize) ParseError!?ScalarValue {
        if (index >= self.len()) return null;
        var it = try self.iterator();
        var i: usize = 0;
        while (i < index) : (i += 1) {
            _ = (try it.next()) orelse return error.InvalidValue;
        }
        return try it.next();
    }

    /// A cursor over every value, in order. The values borrow the raw
    /// buffer, so they are valid until that buffer is spliced.
    pub fn iterator(self: Value) ParseError!Cursor {
        return try Value.Cursor.init(self);
    }

    /// Replaces the rows `[index, index + del)` with `values`, rewriting the
    /// metadata column and the raw buffer together
    /// (`column_range/value.rs:87-196`).
    pub fn splice(
        self: Value,
        gpa: std.mem.Allocator,
        index: usize,
        del: usize,
        values: []const ScalarValue,
    ) ParseError!void {
        try checkRange(self.len(), index, del);
        var metas: std.ArrayList(?u64) = .empty;
        defer metas.deinit(gpa);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);

        var it = try self.iterator();
        var i: usize = 0;
        while (i < index) : (i += 1) {
            try keep(gpa, &metas, &payload, (try it.next()) orelse return error.InvalidValue);
        }
        i = 0;
        while (i < del) : (i += 1) try it.skip();
        for (values) |row| try keep(gpa, &metas, &payload, row);
        while (try it.next()) |row| try keep(gpa, &metas, &payload, row);
        try self.replaceAll(gpa, metas.items, payload.items);
    }

    /// Replaces the whole column with `metas` and the payloads they
    /// describe: what [`Value.splice`] builds, split out for a caller that
    /// has both already.
    ///
    /// A group splice needs it, because it has to gather the payloads of the
    /// rows it keeps — whose values borrow a raw buffer it does not own —
    /// before it can rewrite anything, so it cannot splice the column it is
    /// reading.
    pub fn replaceAll(
        self: Value,
        gpa: std.mem.Allocator,
        metas: []const ?u64,
        payload: []const u8,
    ) ParseError!void {
        var fresh_meta = try rebuilt(UintCol, gpa, metas);
        errdefer fresh_meta.deinit();
        var fresh_raw = try Raw.rebuilt(gpa, payload);
        errdefer fresh_raw.deinit();
        commit(self.meta, fresh_meta);
        commit(self.raw, fresh_raw);
    }

    /// Appends one row.
    pub fn append(self: Value, gpa: std.mem.Allocator, row: ScalarValue) ParseError!void {
        try self.splice(gpa, self.len(), 0, &[_]ScalarValue{row});
    }

    /// Appends `values`, in order.
    pub fn extend(self: Value, gpa: std.mem.Allocator, values: []const ScalarValue) ParseError!void {
        try self.splice(gpa, self.len(), 0, values);
    }

    /// A cursor over the values of a value column.
    pub const Cursor = struct {
        metas: Counted(UintCol),
        payload: Raw.Cursor,

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: Value) ParseError!Cursor {
            return .{
                .metas = try Counted(UintCol).init(col.meta),
                .payload = col.raw.cursor(),
            };
        }

        /// The next value, or null at the end of the column.
        pub fn next(self: *Cursor) ParseError!?ScalarValue {
            const raw_word = (try self.metas.next()) orelse return null;
            // A row with no metadata word is a row whose value nothing
            // describes (`column_range/value.rs:298-300`).
            const word = raw_word orelse return error.UnexpectedNull;
            return try decode(ValueMeta.fromRaw(word), &self.payload);
        }

        /// Steps over one row. The payload has to be stepped over too, or
        /// the next row would start in the middle of this one.
        pub fn skip(self: *Cursor) ParseError!void {
            const raw_word = (try self.metas.next()) orelse return error.InvalidValue;
            const word = raw_word orelse return error.UnexpectedNull;
            _ = try self.payload.take(ValueMeta.fromRaw(word).length());
        }

        /// Whether every row has been read.
        pub fn done(self: *const Cursor) bool {
            return self.metas.done();
        }
    };
};

/// Adds one row to the replacement a [`Value`] splice is building: the
/// metadata word, then the payload the word describes.
fn keep(
    gpa: std.mem.Allocator,
    metas: *std.ArrayList(?u64),
    payload: *std.ArrayList(u8),
    row: ScalarValue,
) ParseError!void {
    try metas.append(gpa, metaOf(row).raw);
    try appendPayload(gpa, payload, row);
}

/// The metadata word a value encodes as (`column_range/value.rs:415-432`).
///
/// This is deliberately not `ScalarValue.valueType`: that is the *logical*
/// type the document API sees, and it folds a counter and a timestamp into
/// `leb`, while the wire has a code for each of them
/// (`value.zig:141-151`, `value.rs:415-432`).
fn metaOf(row: ScalarValue) ValueMeta {
    return ValueMeta.init(switch (row) {
        .null_value => .null_value,
        .bool_value => |b| if (b) .true_value else .false_value,
        .uint => .uleb,
        .int => .leb,
        .float => .float,
        .str => .string,
        .bytes, .actor_id => .bytes,
        .counter => .counter,
        .timestamp => .timestamp,
        .unknown => |u| ValueType{ .unknown = u.type_code },
    }, payloadLen(row));
}

/// The payload a value's metadata word counts: its bytes on the wire, which
/// for the varint forms is the *sizing* function's answer rather than what
/// `encode_val` happens to write (`value.rs:367-381`, `encoding/leb128.rs:1-20`).
fn payloadLen(row: ScalarValue) usize {
    return switch (row) {
        .null_value, .bool_value => 0,
        .uint => |u| leb128.unsignedSize(u),
        .int => |i| leb128.signedSize(i),
        .float => 8,
        .str => |s| s.len,
        .bytes => |b| b.len,
        .actor_id => |a| a.bytes.len,
        .counter => |c| leb128.signedSize(c.current),
        .timestamp => |t| leb128.signedSize(t),
        .unknown => |u| u.bytes.len,
    };
}

/// The bytes one value contributes to the raw column
/// (`column_range/value.rs:367-381`).
fn appendPayload(gpa: std.mem.Allocator, out: *std.ArrayList(u8), row: ScalarValue) ParseError!void {
    switch (row) {
        .null_value, .bool_value => {},
        .uint => |u| try leb128.appendUnsigned(out, gpa, u),
        .int => |i| try leb128.appendSigned(out, gpa, i),
        .timestamp => |t| try leb128.appendSigned(out, gpa, t),
        .counter => |c| try leb128.appendSigned(out, gpa, c.current),
        .float => |f| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(f), .little);
            try out.appendSlice(gpa, &buf);
        },
        .str => |s| try out.appendSlice(gpa, s),
        .bytes => |b| try out.appendSlice(gpa, b),
        .actor_id => |a| try out.appendSlice(gpa, a.bytes),
        .unknown => |u| try out.appendSlice(gpa, u.bytes),
    }
}

/// The value a metadata word and its payload describe
/// (`column_range/value.rs:203-311`).
fn decode(word: ValueMeta, payload: *Raw.Cursor) ParseError!ScalarValue {
    const bytes = try payload.take(word.length());
    return switch (word.typeCode()) {
        .null_value => ScalarValue.null_value,
        .false_value => ScalarValue{ .bool_value = false },
        .true_value => ScalarValue{ .bool_value = true },
        .uleb => ScalarValue{ .uint = try wholeUnsigned(bytes) },
        .leb => ScalarValue{ .int = try wholeSigned(bytes) },
        .string => ScalarValue{ .str = if (std.unicode.utf8ValidateSlice(bytes))
            bytes
        else
            return error.InvalidUtf8 },
        .float => ScalarValue{ .float = try floatOf(bytes) },
        .counter => ScalarValue{ .counter = .init(try wholeSigned(bytes)) },
        .timestamp => ScalarValue{ .timestamp = try wholeSigned(bytes) },
        .bytes => ScalarValue{ .bytes = bytes },
        .unknown => |code| ScalarValue{ .unknown = .{ .type_code = code, .bytes = bytes } },
    };
}

/// One unsigned LEB128 value that fills `bytes` exactly. A payload the value
/// does not fill is a metadata word and a raw column that disagree
/// (`column_range/value.rs:288-311`).
fn wholeUnsigned(bytes: []const u8) ParseError!u64 {
    const v = try leb128.readUnsigned(bytes);
    if (v.len != bytes.len) return error.InvalidValue;
    return v.value;
}

/// One signed LEB128 value that fills `bytes` exactly
/// (`column_range/value.rs:288-311`).
fn wholeSigned(bytes: []const u8) ParseError!i64 {
    const v = try leb128.readSigned(bytes);
    if (v.len != bytes.len) return error.InvalidValue;
    return v.value;
}

/// An `f64` from eight little-endian bytes. Any other length is a malformed
/// metadata word (`column_range/value.rs:240-252`).
fn floatOf(bytes: []const u8) ParseError!f64 {
    if (bytes.len != 8) return error.InvalidValueMeta;
    var buf: [8]u8 = undefined;
    @memcpy(&buf, bytes);
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

// ── Key ────────────────────────────────────────────────────────────────────

/// A map key: the name of a map property, or the element id a sequence
/// operation is anchored to (`column_range/key.rs:16-19`).
pub const Key = union(enum) {
    /// A property name, as the counter of its bytes in the document's
    /// string table. Upstream carries the string itself
    /// (`RleRange<SmolStr>`, `key.rs:33`); this port's columns hold the
    /// counter, and the op set interns it (plan §5.3).
    prop: u32,
    /// An element id. `OpId{0, 0}` is the head of a sequence, which is what
    /// a first insert anchors to (`key.rs:114-124`).
    elem: OpId,

    /// Whether two keys are the same.
    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .prop => |x| switch (b) {
                .prop => |y| x == y,
                .elem => false,
            },
            .elem => |x| switch (b) {
                .prop => false,
                .elem => |y| x.eql(y),
            },
        };
    }
};

/// The three columns one logical key column is a view over
/// (`column_range/key.rs:31-35`).
///
/// How a row is spelled is carried by *which* of the three columns holds a
/// value, exactly as upstream writes it: a property sets the string alone,
/// the head of a sequence sets the counter alone to zero, and any other
/// element id sets the actor and the counter (`key.rs:92-147`). There is no
/// flag column, and adding one would change the bytes; a decoder also
/// accepts a column that has run out where a value would be, because a
/// change that never uses one of the three omits that column entirely
/// (`key.rs:145-183`).
pub const KeyColumn = struct {
    /// The actor of the operation whose value is the key string.
    actor: *IndexCol,
    /// That operation's counter, delta coded.
    counter: *CounterCol,
    /// The key string, as a counter into the string table.
    string: *IndexCol,

    /// A key column over the three columns, which must already agree on
    /// their row count.
    pub fn init(actor: *IndexCol, counter: *CounterCol, string: *IndexCol) ParseError!KeyColumn {
        const view: KeyColumn = .{ .actor = actor, .counter = counter, .string = string };
        try view.checkLengths();
        return view;
    }

    /// The number of rows.
    pub fn len(self: KeyColumn) usize {
        return self.actor.len();
    }

    /// Whether the column holds no rows.
    pub fn isEmpty(self: KeyColumn) bool {
        return self.actor.len() == 0;
    }

    /// The three columns' row counts must be the same, or the view would
    /// have to invent rows one of them does not have.
    pub fn checkLengths(self: KeyColumn) ParseError!void {
        if (self.counter.len() != self.len() or self.string.len() != self.len()) {
            return error.InvalidValue;
        }
    }

    /// The key at `index`, or null past the end.
    pub fn get(self: KeyColumn, index: usize) ParseError!?Key {
        if (index >= self.len()) return null;
        const a = try self.actor.get(index);
        const c = try self.counter.get(index);
        const s = try self.string.get(index);
        return try readKey(a, c, s);
    }

    /// A cursor over every key, in order.
    pub fn iterator(self: KeyColumn) ParseError!Cursor {
        return try KeyColumn.Cursor.init(self);
    }

    /// Replaces the rows `[index, index + del)` with `keys`, rewriting all
    /// three columns in one step (`column_range/key.rs:92-147`).
    pub fn splice(self: KeyColumn, gpa: std.mem.Allocator, index: usize, del: usize, keys: []const Key) ParseError!void {
        try self.checkLengths();
        try checkRange(self.len(), index, del);
        var actors: std.ArrayList(?u32) = .empty;
        defer actors.deinit(gpa);
        var counters: std.ArrayList(?u32) = .empty;
        defer counters.deinit(gpa);
        var strings: std.ArrayList(?u32) = .empty;
        defer strings.deinit(gpa);
        for (keys) |k| {
            const cells = cellsOf(k);
            try actors.append(gpa, cells.actor);
            try counters.append(gpa, cells.counter);
            try strings.append(gpa, cells.string);
        }

        var fresh_actor = try replacement(IndexCol, gpa, self.actor, index, del, actors.items);
        errdefer fresh_actor.deinit();
        var fresh_counter = try replacement(CounterCol, gpa, self.counter, index, del, counters.items);
        errdefer fresh_counter.deinit();
        var fresh_string = try replacement(IndexCol, gpa, self.string, index, del, strings.items);
        errdefer fresh_string.deinit();
        commit(self.actor, fresh_actor);
        commit(self.counter, fresh_counter);
        commit(self.string, fresh_string);
    }

    /// Appends one key.
    pub fn append(self: KeyColumn, gpa: std.mem.Allocator, k: Key) ParseError!void {
        try self.splice(gpa, self.len(), 0, &[_]Key{k});
    }

    /// Appends `keys`, in order.
    pub fn extend(self: KeyColumn, gpa: std.mem.Allocator, keys: []const Key) ParseError!void {
        try self.splice(gpa, self.len(), 0, keys);
    }

    /// A cursor over the keys of a key column.
    pub const Cursor = struct {
        actor: Counted(IndexCol),
        counter: Counted(CounterCol),
        string: Counted(IndexCol),

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: KeyColumn) ParseError!Cursor {
            return .{
                .actor = try Counted(IndexCol).init(col.actor),
                .counter = try Counted(CounterCol).init(col.counter),
                .string = try Counted(IndexCol).init(col.string),
            };
        }

        /// The next key, or null at the end of the column.
        pub fn next(self: *Cursor) ParseError!?Key {
            const a = try self.actor.next();
            const c = try self.counter.next();
            const s = try self.string.next();
            return try readKey(a, c, s);
        }

        /// Whether every row has been read.
        pub fn done(self: *const Cursor) bool {
            return self.actor.done() and self.counter.done() and self.string.done();
        }
    };
};

/// The three cells one key writes to (`column_range/key.rs:104-125`).
///
/// The head of a sequence is written as an absent actor and a zero counter
/// rather than as the operation id `{0, 0}`, because that is what the
/// decoder recognises and what every other implementation writes
/// (`key.rs:114-124`).
fn cellsOf(k: Key) struct { actor: ?u32, counter: ?u32, string: ?u32 } {
    return switch (k) {
        .prop => |p| .{ .actor = null, .counter = null, .string = p },
        .elem => |id| if (id.eql(OpId.root))
            .{ .actor = null, .counter = 0, .string = null }
        else
            .{ .actor = id.actor, .counter = id.counter, .string = null },
    };
}

/// The key one row spells out, from the three cells it holds
/// (`column_range/key.rs:145-183`).
///
/// The arms are upstream's match in its order, because the order is what
/// makes "too many values" a refusal distinct from "an unexpected null":
/// a row may name a string or an operation id, never both and never
/// neither. A null where a value is required is a malformed row, not a
/// missing one — upstream reports which column (`key.rs:176-182`) and the
/// error set here carries no payload, so both are `error.UnexpectedNull`.
fn readKey(actor: ??u32, counter: ??u32, string: ??u32) ParseError!?Key {
    if (!absent(actor) and !absent(counter) and !absent(string)) {
        // A string and an operation id in one row: the row is a name and an
        // anchor at once.
        return error.InvalidValue;
    }
    if (absent(actor) and absent(counter)) {
        if (!absent(string)) return .{ .prop = string.?.? };
        // Nothing spelled out anywhere: the end of the column, which the
        // three columns reach at their own lengths.
        return null;
    }
    if (absent(actor)) {
        // A counter with no actor and no string: the head of a sequence, or
        // a row whose actor column is missing.
        if (absent(string) and !absent(counter) and counter.?.? == 0) {
            return .{ .elem = OpId.root };
        }
        return error.UnexpectedNull;
    }
    if (absent(counter)) return error.UnexpectedNull;
    if (!absent(string)) return error.InvalidValue;
    return .{ .elem = OpId.init(counter.?.?, actor.?.?) };
}

// ── ObjId ──────────────────────────────────────────────────────────────────

/// The two columns one logical object-id column is a view over
/// (`column_range/obj_id.rs:14-17`).
///
/// Both parts may be absent, and both being absent is the document root. A
/// zero counter is the root as well, whatever the actor column says — the
/// rule the decoder needs because a change that never leaves the root map
/// writes a zero counter against no actor (`obj_id.rs:127-143`).
pub const ObjIdColumn = struct {
    /// The actor of the operation that made the object, or absent.
    actor: *IndexCol,
    /// That operation's counter, or absent.
    counter: *UintCol,

    /// An object-id column over the two columns, which must already agree on
    /// their row count.
    pub fn init(actor: *IndexCol, counter: *UintCol) ParseError!ObjIdColumn {
        const view: ObjIdColumn = .{ .actor = actor, .counter = counter };
        try view.checkLengths();
        return view;
    }

    /// The number of rows.
    pub fn len(self: ObjIdColumn) usize {
        return self.actor.len();
    }

    /// Whether the column holds no rows.
    pub fn isEmpty(self: ObjIdColumn) bool {
        return self.actor.len() == 0;
    }

    /// The two columns' row counts must be the same.
    pub fn checkLengths(self: ObjIdColumn) ParseError!void {
        if (self.counter.len() != self.len()) return error.InvalidValue;
    }

    /// The object at `index`, or null past the end.
    pub fn get(self: ObjIdColumn, index: usize) ParseError!?ExId {
        if (index >= self.len()) return null;
        const a = try self.actor.get(index);
        const c = try self.counter.get(index);
        return try readObjId(a, c);
    }

    /// A cursor over every object id, in order.
    pub fn iterator(self: ObjIdColumn) ParseError!Cursor {
        return try ObjIdColumn.Cursor.init(self);
    }

    /// Replaces the rows `[index, index + del)` with `ids`, rewriting both
    /// columns in one step (`column_range/obj_id.rs:56-100`).
    pub fn splice(self: ObjIdColumn, gpa: std.mem.Allocator, index: usize, del: usize, ids: []const ExId) ParseError!void {
        try self.checkLengths();
        try checkRange(self.len(), index, del);
        var actors: std.ArrayList(?u32) = .empty;
        defer actors.deinit(gpa);
        var counters: std.ArrayList(?u64) = .empty;
        defer counters.deinit(gpa);
        for (ids) |id| {
            const cells = objIdCells(id);
            try actors.append(gpa, cells.actor);
            try counters.append(gpa, cells.counter);
        }

        var fresh_actor = try replacement(IndexCol, gpa, self.actor, index, del, actors.items);
        errdefer fresh_actor.deinit();
        var fresh_counter = try replacement(UintCol, gpa, self.counter, index, del, counters.items);
        errdefer fresh_counter.deinit();
        commit(self.actor, fresh_actor);
        commit(self.counter, fresh_counter);
    }

    /// Appends one object id.
    pub fn append(self: ObjIdColumn, gpa: std.mem.Allocator, id: ExId) ParseError!void {
        try self.splice(gpa, self.len(), 0, &[_]ExId{id});
    }

    /// Appends `ids`, in order.
    pub fn extend(self: ObjIdColumn, gpa: std.mem.Allocator, ids: []const ExId) ParseError!void {
        try self.splice(gpa, self.len(), 0, ids);
    }

    /// A cursor over the object ids of an object-id column.
    pub const Cursor = struct {
        actor: Counted(IndexCol),
        counter: Counted(UintCol),

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: ObjIdColumn) ParseError!Cursor {
            return .{
                .actor = try Counted(IndexCol).init(col.actor),
                .counter = try Counted(UintCol).init(col.counter),
            };
        }

        /// The next object id, or null at the end of the column.
        pub fn next(self: *Cursor) ParseError!?ExId {
            // A row whose two parts are both absent is the root, and so is
            // a column that has run out — upstream tells the two apart with
            // the decoder's own `done()` (`obj_id.rs:127-136`), so the end
            // of the column is reported here instead.
            if (self.actor.done() and self.counter.done()) return null;
            const a = try self.actor.next();
            const c = try self.counter.next();
            return try readObjId(a, c);
        }

        /// Whether every row has been read.
        pub fn done(self: *const Cursor) bool {
            return self.actor.done() and self.counter.done();
        }
    };
};

/// The two cells one object id writes to (`column_range/obj_id.rs:112-120`,
/// `:168-176`): the root spells out neither, an operation id spells out
/// both.
fn objIdCells(id: ExId) struct { actor: ?u32, counter: ?u64 } {
    return switch (id) {
        .root => .{ .actor = null, .counter = null },
        .id => |o| .{ .actor = o.actor, .counter = o.counter },
    };
}

/// The object one row names (`column_range/obj_id.rs:127-143`).
///
/// Upstream's arms, in its order: both parts absent is the root, both
/// present is an operation id, a zero counter is the root whatever the actor
/// column holds, and one part without the other is malformed.
fn readObjId(actor: ??u32, counter: ??u64) ParseError!ExId {
    if (absent(actor) and absent(counter)) return .root;
    if (!absent(actor) and !absent(counter)) {
        const ctr = counter.?.?;
        if (ctr > std.math.maxInt(u32)) return error.InvalidValue;
        return .{ .id = OpId.init(@intCast(ctr), actor.?.?) };
    }
    if (!absent(counter) and counter.?.? == 0) return .root;
    if (absent(actor)) return error.UnexpectedNull;
    if (absent(counter)) return error.UnexpectedNull;
    return error.InvalidValue;
}

// ── OpIdList ───────────────────────────────────────────────────────────────

/// A run of operation ids per row: the group column a change writes its
/// predecessors as (`column_range/opid_list.rs:18-22`).
///
/// The actor and counter columns are flat: row `i` of `num` says how many
/// values to read from each, in row order, and the two together spell one
/// list per row. The counter column is delta coded, which is only sound
/// because a change's predecessors are emitted in ascending order
/// (`opid_list.rs:61-86`, `change/change_actors.rs:66-113`).
pub const OpIdList = struct {
    /// How many ids each row holds.
    num: *UintCol,
    /// The actor of every id, flattened across the rows.
    actor: *UintCol,
    /// The counter of every id, flattened across the rows, delta coded.
    counter: *CounterCol,

    /// An op-id list over the three columns. Only the two flat columns have
    /// to agree here; the `num` column holds a *different* number of rows
    /// from them unless the group is empty, so [`OpIdList.checkLengths`]
    /// sums the counts instead of comparing lengths.
    pub fn init(num: *UintCol, actor: *UintCol, counter: *CounterCol) ParseError!OpIdList {
        const view: OpIdList = .{ .num = num, .actor = actor, .counter = counter };
        try view.checkLengths();
        return view;
    }

    /// The number of rows, which is the `num` column's length.
    pub fn len(self: OpIdList) usize {
        return self.num.len();
    }

    /// Whether the column holds no rows.
    pub fn isEmpty(self: OpIdList) bool {
        return self.num.len() == 0;
    }

    /// How many ids the rows hold in total, which is the length the two flat
    /// columns must have.
    pub fn flatLen(self: OpIdList) ParseError!usize {
        var total: usize = 0;
        var counts = try self.num.iterator();
        while (try counts.next()) |maybe_count| {
            const n = maybe_count orelse return error.UnexpectedNull;
            total = std.math.add(usize, total, try asCount(n)) catch return error.Overflow;
        }
        return total;
    }

    /// The counts must add up to both flat columns' length, and the flat
    /// columns must agree with each other.
    pub fn checkLengths(self: OpIdList) ParseError!void {
        if (self.counter.len() != self.actor.len()) return error.InvalidValue;
        if (try self.flatLen() != self.actor.len()) return error.InvalidValue;
    }

    /// The ids of the row at `index`, or null past the end. The slice is
    /// owned by the call.
    pub fn get(self: OpIdList, gpa: std.mem.Allocator, index: usize) ParseError!?[]OpId {
        if (index >= self.len()) return null;
        var it = try self.iterator(gpa);
        defer it.deinit();
        var i: usize = 0;
        while (i < index) : (i += 1) {
            _ = (try it.next()) orelse return error.InvalidValue;
        }
        const row = (try it.next()) orelse return error.InvalidValue;
        const copy = try gpa.dupe(OpId, row);
        return copy;
    }

    /// A cursor over every row's ids, in order.
    pub fn iterator(self: OpIdList, gpa: std.mem.Allocator) ParseError!Cursor {
        return try OpIdList.Cursor.init(self, gpa);
    }

    /// The range of ids the rows `[index, index + del)` hold, flattened
    /// across the two flat columns (`column_range/opid_list.rs:163-180`).
    /// This is the translation a splice of the flat columns needs, and it
    /// is why a row range and an id range are not the same thing.
    pub fn flatRange(self: OpIdList, index: usize, del: usize) ParseError!struct { start: usize, count: usize } {
        try checkRange(self.len(), index, del);
        var counts = try self.num.iterator();
        var start: usize = 0;
        var i: usize = 0;
        while (i < index) : (i += 1) {
            const maybe_count = (try counts.next()) orelse return error.InvalidValue;
            if (maybe_count) |n| start = std.math.add(usize, start, try asCount(n)) catch return error.Overflow;
        }
        var count: usize = 0;
        i = 0;
        while (i < del) : (i += 1) {
            const maybe_count = (try counts.next()) orelse return error.InvalidValue;
            if (maybe_count) |n| count = std.math.add(usize, count, try asCount(n)) catch return error.Overflow;
        }
        return .{ .start = start, .count = count };
    }

    /// Replaces the rows `[index, index + del)` with `rows`, translating the
    /// row range into a range of each flat column's rows on the way
    /// (`column_range/opid_list.rs:88-136`).
    pub fn splice(
        self: OpIdList,
        gpa: std.mem.Allocator,
        index: usize,
        del: usize,
        rows: []const []const OpId,
    ) ParseError!void {
        try self.checkLengths();
        const flat = try self.flatRange(index, del);
        var counts: std.ArrayList(?u64) = .empty;
        defer counts.deinit(gpa);
        var actors: std.ArrayList(?u64) = .empty;
        defer actors.deinit(gpa);
        var counters: std.ArrayList(?u32) = .empty;
        defer counters.deinit(gpa);
        for (rows) |row| {
            try counts.append(gpa, @as(?u64, @intCast(row.len)));
            for (row) |id| {
                try actors.append(gpa, id.actor);
                try counters.append(gpa, id.counter);
            }
        }

        var fresh_num = try replacement(UintCol, gpa, self.num, index, del, counts.items);
        errdefer fresh_num.deinit();
        var fresh_actor = try replacement(UintCol, gpa, self.actor, flat.start, flat.count, actors.items);
        errdefer fresh_actor.deinit();
        var fresh_counter = try replacement(CounterCol, gpa, self.counter, flat.start, flat.count, counters.items);
        errdefer fresh_counter.deinit();
        commit(self.num, fresh_num);
        commit(self.actor, fresh_actor);
        commit(self.counter, fresh_counter);
    }

    /// Appends one row's ids.
    pub fn append(self: OpIdList, gpa: std.mem.Allocator, row: []const OpId) ParseError!void {
        try self.splice(gpa, self.len(), 0, &[_][]const OpId{row});
    }

    /// Appends `rows`, in order.
    pub fn extend(self: OpIdList, gpa: std.mem.Allocator, rows: []const []const OpId) ParseError!void {
        try self.splice(gpa, self.len(), 0, rows);
    }

    /// A cursor over the rows of an op-id list.
    pub const Cursor = struct {
        gpa: std.mem.Allocator,
        num: Counted(UintCol),
        actor: Counted(UintCol),
        counter: Counted(CounterCol),
        /// The ids of the row being read. It is cleared per row, so the
        /// slice `next` hands back is valid until the next call — upstream
        /// allocates a `Vec` per row instead (`opid_list.rs:196-206`).
        row: std.ArrayList(OpId) = .empty,

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: OpIdList, gpa: std.mem.Allocator) ParseError!Cursor {
            return .{
                .gpa = gpa,
                .num = try Counted(UintCol).init(col.num),
                .actor = try Counted(UintCol).init(col.actor),
                .counter = try Counted(CounterCol).init(col.counter),
            };
        }

        /// Frees the row buffer.
        pub fn deinit(self: *Cursor) void {
            self.row.deinit(self.gpa);
            self.* = undefined;
        }

        /// The next row's ids, or null at the end of the column.
        pub fn next(self: *Cursor) ParseError!?[]const OpId {
            const raw_count = (try self.num.next()) orelse return null;
            // A row with no count says nothing about how many ids it has.
            const count = try asCount(raw_count orelse return error.UnexpectedNull);
            self.row.clearRetainingCapacity();
            // Nothing is reserved from the count: it is bytes a peer sent,
            // and the ids are appended as they are read, so a count larger
            // than the flat columns hold runs this cursor dry instead of
            // allocating (`opid_list.rs:201-206`).
            if (count <= opid_list_reserve_cap) {
                try self.row.ensureTotalCapacity(self.gpa, count);
            }
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const maybe_actor = (try self.actor.next()) orelse return error.InvalidValue;
                const maybe_counter = (try self.counter.next()) orelse return error.InvalidValue;
                const actor = maybe_actor orelse return error.UnexpectedNull;
                const ctr = maybe_counter orelse return error.UnexpectedNull;
                // The actor is read as `u64` because that is the width
                // upstream reads it at, and an index past the actor table's
                // reach is not one (`opid_list.rs:219-233`).
                const idx = std.math.cast(ActorIdx, actor) orelse return error.InvalidValue;
                try self.row.append(self.gpa, OpId.init(ctr, idx));
            }
            return self.row.items;
        }

        /// Whether every row has been read.
        pub fn done(self: *const Cursor) bool {
            return self.num.done();
        }
    };
};

// ── Group ──────────────────────────────────────────────────────────────────

/// The value one grouped column holds (`column_range/generic.rs:52-59`).
pub const SimpleValue = union(enum) {
    /// A nullable unsigned integer (`SimpleColRange::RleInt`).
    uint: ?u64,
    /// A nullable counter into the string table (`RleRange<SmolStr>` on the
    /// wire, `SimpleColRange::RleString` here).
    index: ?u32,
    /// A nullable signed integer (`SimpleColRange::Delta`).
    int: ?i64,
    /// A boolean (`SimpleColRange::Boolean`). Never absent: a boolean column
    /// has no null run.
    boolean: bool,
    /// A scalar value: a metadata word and the bytes it describes.
    value: ScalarValue,

    /// Whether two cells hold the same value.
    pub fn eql(a: SimpleValue, b: SimpleValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .uint => |x| x == b.uint,
            .index => |x| x == b.index,
            .int => |x| x == b.int,
            .boolean => |x| x == b.boolean,
            .value => |x| x.eql(b.value),
        };
    }
};

/// One column a group carries its rows in (`column_range/generic/group.rs:45-48`).
///
/// A grouped column is a view like every other composite: it points at
/// columns somebody else holds, and a rebuild puts fresh ones in its place.
pub const GroupedColumn = union(enum) {
    /// A scalar value, metadata word and raw bytes.
    value: Value,
    /// A nullable unsigned integer.
    uint: *UintCol,
    /// A nullable counter into the string table.
    index: *IndexCol,
    /// A nullable signed integer.
    int: *SignedCol,
    /// A boolean.
    boolean: *BoolCol,

    /// How many values the column holds, which is the group's flattened
    /// row count rather than its row count.
    pub fn len(self: *const GroupedColumn) usize {
        return switch (self.*) {
            .value => |c| c.len(),
            .uint => |c| c.len(),
            .index => |c| c.len(),
            .int => |c| c.len(),
            .boolean => |c| c.len(),
        };
    }

    /// A cursor over this column's values, positioned at its first.
    pub fn cursor(self: *const GroupedColumn) ParseError!GroupedCursor {
        return switch (self.*) {
            .value => |c| .{ .value = try c.iterator() },
            .uint => |c| .{ .uint = try Counted(UintCol).init(c) },
            .index => |c| .{ .index = try Counted(IndexCol).init(c) },
            .int => |c| .{ .int = try Counted(SignedCol).init(c) },
            .boolean => |c| .{ .boolean = try Counted(BoolCol).init(c) },
        };
    }

    /// Replaces this column's values `[start, start + dropped)` with
    /// `added` — the values a group splice has for payload column `i` of a
    /// group with `cols` columns. In place, so the view keeps pointing at
    /// the storage it was built over and a group owns nothing.
    fn replacement(
        self: *GroupedColumn,
        gpa: std.mem.Allocator,
        start: usize,
        dropped: usize,
        added: []const SimpleValue,
        i: usize,
        cols: usize,
    ) ParseError!void {
        switch (self.*) {
            .value => |c| try rebuildValue(gpa, c, start, dropped, added, i, cols),
            .uint => |c| try rebuildSimple(UintCol, gpa, c, start, dropped, added, i, cols, .uint),
            .index => |c| try rebuildSimple(IndexCol, gpa, c, start, dropped, added, i, cols, .index),
            .int => |c| try rebuildSimple(SignedCol, gpa, c, start, dropped, added, i, cols, .int),
            .boolean => |c| try rebuildSimple(BoolCol, gpa, c, start, dropped, added, i, cols, .boolean),
        }
    }
};

/// A cursor over one grouped column: a union of the five cursors a group
/// can carry (`column_range/generic/group.rs:111-138`).
pub const GroupedCursor = union(enum) {
    value: Value.Cursor,
    uint: Counted(UintCol),
    index: Counted(IndexCol),
    int: Counted(SignedCol),
    boolean: Counted(BoolCol),

    /// The next value, or null when the column has none left.
    pub fn next(self: *GroupedCursor) ParseError!?SimpleValue {
        return switch (self.*) {
            .value => |*c| cell: {
                const v = (try c.next()) orelse break :cell null;
                break :cell SimpleValue{ .value = v };
            },
            .uint => |*c| cell: {
                const v = (try c.next()) orelse break :cell null;
                break :cell SimpleValue{ .uint = v };
            },
            .index => |*c| cell: {
                const v = (try c.next()) orelse break :cell null;
                break :cell SimpleValue{ .index = v };
            },
            .int => |*c| cell: {
                const v = (try c.next()) orelse break :cell null;
                break :cell SimpleValue{ .int = v };
            },
            .boolean => |*c| cell: {
                const v = (try c.next()) orelse break :cell null;
                break :cell SimpleValue{ .boolean = v };
            },
        };
    }

    /// Steps over one value. A value column's cursor has to step over the
    /// payload as well, or the next value would start in the middle of it.
    pub fn skip(self: *GroupedCursor) ParseError!void {
        switch (self.*) {
            .value => |*c| try c.skip(),
            .uint => |*c| try c.skip(),
            .index => |*c| try c.skip(),
            .int => |*c| try c.skip(),
            .boolean => |*c| try c.skip(),
        }
    }

    /// Whether every value has been read.
    pub fn done(self: *const GroupedCursor) bool {
        return switch (self) {
            .value => |c| c.done(),
            .uint => |c| c.done(),
            .index => |c| c.done(),
            .int => |c| c.done(),
            .boolean => |c| c.done(),
        };
    }
};

/// One row of a group: `count` values from each grouped column, in
/// column-major order within each inner row — the first value of column 0,
/// the first value of column 1, and so on, then the second of each
/// (`column_range/generic/group.rs:70-97`).
pub const GroupRow = struct {
    /// The row's values: `count * columns` of them.
    values: []const SimpleValue,
    /// How many inner rows the row holds.
    count: usize,
    /// How many grouped columns the group has.
    columns: usize,

    /// The value inner row `r` takes from grouped column `c`.
    pub fn at(self: GroupRow, r: usize, c: usize) ParseError!SimpleValue {
        if (r >= self.count or c >= self.columns) return error.InvalidValue;
        return self.values[r * self.columns + c];
    }
};

/// One row a group splice writes: a count, and the values the row takes from
/// each grouped column.
pub const GroupInput = struct {
    /// How many inner rows the row holds.
    count: usize,
    /// The row's values: `count` from each grouped column, in the order
    /// [`GroupRow`] yields them.
    values: []const SimpleValue,
};

/// A group column: a `num` column and zero or more grouped columns, where
/// `num[i]` says how many values to read from each grouped column to make
/// row `i` (`column_range/generic/group.rs:12-19`).
///
/// The `num` column is row-parallel with the group; the grouped columns are
/// not, they are flat. So the group's row count is `num`'s length and the
/// grouped columns' lengths are the sum of the counts, which is what
/// [`Group.checkLengths`] holds them to.
pub const Group = struct {
    /// How many values each row holds, one per grouped column.
    num: *UintCol,
    /// The grouped columns, read in lockstep.
    columns: []GroupedColumn,

    /// A group over a count column and its grouped columns, whose flattened
    /// lengths must already add up.
    pub fn init(num: *UintCol, columns: []GroupedColumn) ParseError!Group {
        const view: Group = .{ .num = num, .columns = columns };
        try view.checkLengths();
        return view;
    }

    /// The number of rows.
    pub fn len(self: Group) usize {
        return self.num.len();
    }

    /// Whether the group holds no rows.
    pub fn isEmpty(self: Group) bool {
        return self.num.len() == 0;
    }

    /// How many grouped columns the group has.
    pub fn columnCount(self: Group) usize {
        return self.columns.len;
    }

    /// How many values every grouped column must hold: the sum of the counts
    /// (`column_range/generic/group.rs:35-42`).
    pub fn flatLen(self: Group) ParseError!usize {
        var total: usize = 0;
        var counts = try self.num.iterator();
        while (try counts.next()) |maybe_count| {
            const n = maybe_count orelse return error.UnexpectedNull;
            total = std.math.add(usize, total, try asCount(n)) catch return error.Overflow;
        }
        return total;
    }

    /// Every grouped column must hold exactly the sum of the counts.
    pub fn checkLengths(self: Group) ParseError!void {
        const total = try self.flatLen();
        for (self.columns) |*col| {
            if (col.len() != total) return error.InvalidValue;
        }
    }

    /// A cursor over every row, in order.
    pub fn iterator(self: Group, gpa: std.mem.Allocator) ParseError!Cursor {
        return try Group.Cursor.init(self, gpa);
    }

    /// Replaces the rows `[index, index + del)` with `rows`.
    ///
    /// The count column is row-parallel and the grouped columns are flat, so
    /// the row range has to be translated into a range of each grouped
    /// column's own rows before it can be spliced — the same translation a
    /// predecessor list does (`column_range/opid_list.rs:163-180`).
    pub fn splice(
        self: Group,
        gpa: std.mem.Allocator,
        index: usize,
        del: usize,
        rows: []const GroupInput,
    ) ParseError!void {
        try self.checkLengths();
        try checkRange(self.len(), index, del);
        const cols = self.columns.len;
        var counts: std.ArrayList(?u64) = .empty;
        defer counts.deinit(gpa);
        var added: std.ArrayList(SimpleValue) = .empty;
        defer added.deinit(gpa);
        for (rows) |row| {
            // A count is a row count a peer sent, so the product is checked
            // rather than trusted: a wrapped one would compare equal to a
            // short value list and the group would read past it.
            const want = std.math.mul(usize, row.count, cols) catch return error.Overflow;
            if (row.values.len != want) return error.InvalidValue;
            try counts.append(gpa, @as(?u64, @intCast(row.count)));
            try added.appendSlice(gpa, row.values);
        }

        // The flat range the replaced rows occupy, which every grouped
        // column has to be spliced at.
        var start: usize = 0;
        var counts_it = try self.num.iterator();
        var i: usize = 0;
        while (i < index) : (i += 1) {
            const maybe_count = (try counts_it.next()) orelse return error.InvalidValue;
            if (maybe_count) |n| start = std.math.add(usize, start, try asCount(n)) catch return error.Overflow;
        }
        var removed: usize = 0;
        i = 0;
        while (i < del) : (i += 1) {
            const maybe_count = (try counts_it.next()) orelse return error.InvalidValue;
            if (maybe_count) |n| removed = std.math.add(usize, removed, try asCount(n)) catch return error.Overflow;
        }

        // Every value is in hand, so the columns are rewritten one after
        // another. The count column goes last: it is the row count the
        // group reports, and until it agrees with the payloads a
        // `checkLengths` failure names a payload rather than the count.
        for (self.columns, 0..) |*col, c| {
            try col.replacement(gpa, start, removed, added.items, c, cols);
        }
        var fresh_num = try replacement(UintCol, gpa, self.num, index, del, counts.items);
        errdefer fresh_num.deinit();
        commit(self.num, fresh_num);
    }

    /// Appends one row.
    pub fn append(self: Group, gpa: std.mem.Allocator, row: GroupInput) ParseError!void {
        try self.splice(gpa, self.len(), 0, &[_]GroupInput{row});
    }

    /// Appends `rows`, in order.
    pub fn extend(self: Group, gpa: std.mem.Allocator, rows: []const GroupInput) ParseError!void {
        try self.splice(gpa, self.len(), 0, rows);
    }

    /// A cursor over the rows of a group.
    pub const Cursor = struct {
        gpa: std.mem.Allocator,
        num: Counted(UintCol),
        columns: std.ArrayList(GroupedCursor) = .empty,
        /// The values of the row being read. Cleared per row, so the slice
        /// `next` hands back is valid until the next call.
        row: std.ArrayList(SimpleValue) = .empty,

        /// A cursor over `col`, positioned at its first row.
        pub fn init(col: Group, gpa: std.mem.Allocator) ParseError!Cursor {
            var self: Cursor = .{ .gpa = gpa, .num = try Counted(UintCol).init(col.num) };
            errdefer self.deinit();
            for (col.columns) |*grouped| {
                try self.columns.append(gpa, try grouped.cursor());
            }
            return self;
        }

        /// Frees the per-column cursors and the row buffer.
        pub fn deinit(self: *Cursor) void {
            self.columns.deinit(self.gpa);
            self.row.deinit(self.gpa);
            self.* = undefined;
        }

        /// The next row, or null at the end of the group.
        pub fn next(self: *Cursor) ParseError!?GroupRow {
            const raw_count = (try self.num.next()) orelse return null;
            // A row with no count says nothing about how long it is.
            const count = try asCount(raw_count orelse return error.UnexpectedNull);
            self.row.clearRetainingCapacity();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                for (self.columns.items) |*grouped| {
                    const cell = (try grouped.next()) orelse return error.InvalidValue;
                    try self.row.append(self.gpa, cell);
                }
            }
            return .{
                .values = self.row.items,
                .count = count,
                .columns = self.columns.items.len,
            };
        }

        /// Whether every row has been read.
        pub fn done(self: *const Cursor) bool {
            return self.num.done();
        }
    };
};

/// One simple grouped column's replacement, in place.
fn rebuildSimple(
    comptime Col: type,
    gpa: std.mem.Allocator,
    col: *Col,
    start: usize,
    dropped: usize,
    added: []const SimpleValue,
    i: usize,
    cols: usize,
    comptime tag: std.meta.Tag(SimpleValue),
) ParseError!void {
    const vals = try addedFor(Col.Value, tag, gpa, added, i, cols);
    defer gpa.free(vals);
    try col.splice(gpa, start, dropped, vals);
}

/// One value grouped column's replacement: the metadata words of the rows
/// that stay and of the rows that land, and the payloads they describe
/// (`column_range/value.rs:87-196`).
fn rebuildValue(
    gpa: std.mem.Allocator,
    col: Value,
    start: usize,
    dropped: usize,
    added: []const SimpleValue,
    i: usize,
    cols: usize,
) ParseError!void {
    const vals = try addedFor(ScalarValue, .value, gpa, added, i, cols);
    defer gpa.free(vals);
    var metas: std.ArrayList(?u64) = .empty;
    defer metas.deinit(gpa);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);

    var it = try col.iterator();
    var n: usize = 0;
    while (n < start) : (n += 1) {
        try keep(gpa, &metas, &payload, (try it.next()) orelse return error.InvalidValue);
    }
    n = 0;
    while (n < dropped) : (n += 1) try it.skip();
    for (vals) |row| try keep(gpa, &metas, &payload, row);
    while (try it.next()) |row| try keep(gpa, &metas, &payload, row);

    try col.replaceAll(gpa, metas.items, payload.items);
}

/// The values `added` carries for grouped column `i` of a group with `cols`
/// columns, as that column's own value type. A row holds one value per
/// grouped column, so this is every `cols`-th value of `added`, and a value
/// of another kind is a row that does not spell this column out.
fn addedFor(
    comptime T: type,
    comptime tag: std.meta.Tag(SimpleValue),
    gpa: std.mem.Allocator,
    added: []const SimpleValue,
    i: usize,
    cols: usize,
) ParseError![]T {
    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(gpa);
    if (cols == 0) return out.toOwnedSlice(gpa);
    var at: usize = i;
    while (at < added.len) : (at += cols) {
        const cell = added[at];
        if (std.meta.activeTag(cell) != tag) return error.InvalidValue;
        try out.append(gpa, @field(cell, @tagName(tag)));
    }
    return out.toOwnedSlice(gpa);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A key column and the three columns it is a view over, for a test that
/// owns them.
const KeyFixture = struct {
    actor: IndexCol,
    counter: CounterCol,
    string: IndexCol,

    fn init(gpa: std.mem.Allocator) ParseError!KeyFixture {
        return .{
            .actor = try IndexCol.init(gpa),
            .counter = try CounterCol.init(gpa),
            .string = try IndexCol.init(gpa),
        };
    }

    fn deinit(self: *KeyFixture) void {
        self.actor.deinit();
        self.counter.deinit();
        self.string.deinit();
    }

    fn view(self: *KeyFixture) ParseError!KeyColumn {
        return KeyColumn.init(&self.actor, &self.counter, &self.string);
    }
};

/// A key column's three columns must hold the same number of rows: the view
/// has no rows of its own, so a splice that left them out of step would
/// hand the cursor two different row counts to read.
fn expectKeyInStep(key: KeyColumn, want: usize) !void {
    try testing.expectEqual(want, key.len());
    try testing.expectEqual(want, key.actor.len());
    try testing.expectEqual(want, key.counter.len());
    try testing.expectEqual(want, key.string.len());
    try key.checkLengths();
}

fn expectKeys(key: KeyColumn, want: []const Key) !void {
    try expectKeyInStep(key, want.len);
    var it = try key.iterator();
    var i: usize = 0;
    while (try it.next()) |got| {
        if (i >= want.len) return error.TestUnexpectedResult;
        try testing.expect(want[i].eql(got));
        i += 1;
    }
    try testing.expectEqual(want.len, i);
    try testing.expect(it.done());
    for (want, 0..) |expected, j| {
        const got = (try key.get(j)) orelse return error.TestUnexpectedResult;
        try testing.expect(expected.eql(got));
    }
    try testing.expect((try key.get(want.len)) == null);
}

/// Applies one splice to the columns through the view and to the model
/// directly, then holds both to the model.
fn keyStep(
    key: KeyColumn,
    model: *std.ArrayList(Key),
    index: usize,
    del: usize,
    added: []const Key,
) !void {
    const gpa = testing.allocator;
    try key.splice(gpa, index, del, added);
    try model.replaceRange(gpa, index, del, added);
    try expectKeys(key, model.items);
}

test "a key column decodes both spellings" {
    const gpa = testing.allocator;
    var cols = try KeyFixture.init(gpa);
    defer cols.deinit();
    // prop 3, elem(5, actor 1), prop 7, the head of a sequence, elem(2, 0)
    try cols.actor.extend(gpa, &.{ null, 1, null, null, 0 });
    try cols.counter.extend(gpa, &.{ null, 5, null, 0, 2 });
    try cols.string.extend(gpa, &.{ 3, null, 7, null, null });
    const key = try cols.view();

    try expectKeys(key, &.{
        .{ .prop = 3 },
        .{ .elem = OpId.init(5, 1) },
        .{ .prop = 7 },
        .{ .elem = OpId.root },
        .{ .elem = OpId.init(2, 0) },
    });

    // Appending is a splice at the end, and it spells the same keys.
    var model: std.ArrayList(Key) = .empty;
    defer model.deinit(gpa);
    try model.appendSlice(gpa, &.{
        .{ .prop = 3 },
        .{ .elem = OpId.init(5, 1) },
        .{ .prop = 7 },
        .{ .elem = OpId.root },
        .{ .elem = OpId.init(2, 0) },
    });
    try keyStep(key, &model, 0, 0, &.{ .{ .prop = 9 }, .{ .elem = OpId.init(1, 4) } });
    try keyStep(key, &model, 4, 2, &.{.{ .elem = OpId.root }});
    try keyStep(key, &model, model.items.len, 0, &.{.{ .prop = 0 }});
    try expectKeyInStep(key, model.items.len);
}

test "a key column splices at the start, the middle and the end" {
    const gpa = testing.allocator;
    var cols = try KeyFixture.init(gpa);
    defer cols.deinit();
    var model: std.ArrayList(Key) = .empty;
    defer model.deinit(gpa);
    for ([_]Key{
        .{ .prop = 1 },
        .{ .elem = OpId.init(1, 0) },
        .{ .prop = 2 },
        .{ .elem = OpId.init(2, 0) },
        .{ .prop = 3 },
    }) |k| {
        const cells = cellsOf(k);
        try cols.actor.append(gpa, cells.actor);
        try cols.counter.append(gpa, cells.counter);
        try cols.string.append(gpa, cells.string);
        try model.append(gpa, k);
    }
    const key = try cols.view();
    try expectKeys(key, model.items);

    // At the start: two rows for one.
    try keyStep(key, &model, 0, 1, &.{ .{ .prop = 10 }, .{ .prop = 11 } });
    // In the middle: two rows for two.
    try keyStep(key, &model, 3, 2, &.{ .{ .prop = 12 }, .{ .elem = OpId.init(3, 1) } });
    // At the end: one row for none.
    try keyStep(key, &model, model.items.len - 1, 1, &.{});
    // And a removal down to nothing, which is the boundary a document load
    // can reach with a truncated column.
    try keyStep(key, &model, 0, model.items.len, &.{});
    try testing.expect(key.isEmpty());
}

test "a key row that names an actor without a counter is rejected" {
    const gpa = testing.allocator;
    var cols = try KeyFixture.init(gpa);
    defer cols.deinit();
    try cols.actor.extend(gpa, &.{1});
    try cols.counter.extend(gpa, &.{null});
    try cols.string.extend(gpa, &.{null});
    const key = try cols.view();

    var it = try key.iterator();
    try testing.expectError(error.UnexpectedNull, it.next());
    try testing.expectError(error.UnexpectedNull, key.get(0));
}

test "a key row that names a string and an operation id is rejected" {
    const gpa = testing.allocator;
    var cols = try KeyFixture.init(gpa);
    defer cols.deinit();
    try cols.actor.extend(gpa, &.{1});
    try cols.counter.extend(gpa, &.{4});
    try cols.string.extend(gpa, &.{7});
    const key = try cols.view();

    var it = try key.iterator();
    try testing.expectError(error.InvalidValue, it.next());
}

/// An object-id column and the two columns it is a view over.
const ObjIdFixture = struct {
    actor: IndexCol,
    counter: UintCol,

    fn init(gpa: std.mem.Allocator) ParseError!ObjIdFixture {
        return .{
            .actor = try IndexCol.init(gpa),
            .counter = try UintCol.init(gpa),
        };
    }

    fn deinit(self: *ObjIdFixture) void {
        self.actor.deinit();
        self.counter.deinit();
    }

    fn view(self: *ObjIdFixture) ParseError!ObjIdColumn {
        return ObjIdColumn.init(&self.actor, &self.counter);
    }
};

/// An object-id column's two columns must hold the same number of rows.
fn expectObjIdInStep(col: ObjIdColumn, want: usize) !void {
    try testing.expectEqual(want, col.len());
    try testing.expectEqual(want, col.actor.len());
    try testing.expectEqual(want, col.counter.len());
    try col.checkLengths();
}

fn expectObjIds(col: ObjIdColumn, want: []const ExId) !void {
    try expectObjIdInStep(col, want.len);
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |got| {
        if (i >= want.len) return error.TestUnexpectedResult;
        try testing.expect(want[i].eql(got));
        i += 1;
    }
    try testing.expectEqual(want.len, i);
    try testing.expect(it.done());
    for (want, 0..) |expected, j| {
        const got = (try col.get(j)) orelse return error.TestUnexpectedResult;
        try testing.expect(expected.eql(got));
    }
}

test "an object id column decodes the root and an operation id" {
    const gpa = testing.allocator;
    var cols = try ObjIdFixture.init(gpa);
    defer cols.deinit();
    // Both parts absent is the root; both present is an operation id; a zero
    // counter is the root whatever the actor column says.
    try cols.actor.extend(gpa, &.{ null, 1, null, 2, 3, null });
    try cols.counter.extend(gpa, &.{ null, 7, 0, 4, 5, null });
    const col = try cols.view();

    try expectObjIds(col, &.{
        .root,
        .{ .id = OpId.init(7, 1) },
        .root,
        .{ .id = OpId.init(4, 2) },
        .{ .id = OpId.init(5, 3) },
        .root,
    });
}

test "an object id column splices at the start, the middle and the end" {
    const gpa = testing.allocator;
    var cols = try ObjIdFixture.init(gpa);
    defer cols.deinit();
    var model: std.ArrayList(ExId) = .empty;
    defer model.deinit(gpa);
    const col = try cols.view();
    for ([_]ExId{
        .{ .id = OpId.init(1, 0) },
        .root,
        .{ .id = OpId.init(3, 0) },
    }) |id| {
        try col.append(gpa, id);
        try model.append(gpa, id);
    }
    try expectObjIds(col, model.items);

    for ([_]struct { index: usize, del: usize, added: []const ExId }{
        .{ .index = 0, .del = 0, .added = &.{.{ .id = OpId.init(9, 1) }} },
        .{ .index = 1, .del = 2, .added = &.{ .root, .{ .id = OpId.init(2, 0) } } },
        .{ .index = col.len(), .del = 0, .added = &.{} },
        .{ .index = 0, .del = col.len(), .added = &.{.root} },
    }) |step| {
        try col.splice(gpa, step.index, step.del, step.added);
        try model.replaceRange(gpa, step.index, step.del, step.added);
        try expectObjIds(col, model.items);
    }
}

test "an object id row that names an actor without a counter is rejected" {
    const gpa = testing.allocator;
    var cols = try ObjIdFixture.init(gpa);
    defer cols.deinit();
    try cols.actor.extend(gpa, &.{2});
    try cols.counter.extend(gpa, &.{null});
    const col = try cols.view();

    var it = try col.iterator();
    try testing.expectError(error.UnexpectedNull, it.next());
}

/// A value column and the two columns it is a view over, for a test that
/// owns them.
const ValueFixture = struct {
    meta: UintCol,
    raw: Raw,

    fn init(gpa: std.mem.Allocator) ParseError!ValueFixture {
        return .{ .meta = try UintCol.init(gpa), .raw = Raw.init(gpa) };
    }

    fn deinit(self: *ValueFixture) void {
        self.meta.deinit();
        self.raw.deinit();
    }

    fn view(self: *ValueFixture) Value {
        return Value.init(&self.meta, &self.raw);
    }
};

/// A value column's metadata column is its row count; the raw buffer is a
/// byte count and is not in step with it, so the check is that the words
/// still describe the bytes.
fn expectValues(col: Value, want: []const ScalarValue) !void {
    try testing.expectEqual(want.len, col.len());
    try testing.expectEqual(want.len == 0, col.isEmpty());
    var it = try col.iterator();
    var i: usize = 0;
    while (try it.next()) |got| {
        if (i >= want.len) return error.TestUnexpectedResult;
        try testing.expect(want[i].eql(got));
        i += 1;
    }
    try testing.expectEqual(want.len, i);
    try testing.expect(it.done());
    for (want, 0..) |expected, j| {
        const got = (try col.get(j)) orelse return error.TestUnexpectedResult;
        try testing.expect(expected.eql(got));
    }
    try testing.expect((try col.get(want.len)) == null);
}

/// The row holding `want`, or null. Finding a row by value keeps a test from
/// depending on the order of the list below.
fn findRow(col: Value, want: ScalarValue) ParseError!?ScalarValue {
    var i: usize = 0;
    while (i < col.len()) : (i += 1) {
        const got = (try col.get(i)) orelse return null;
        if (got.eql(want)) return got;
    }
    return null;
}

/// [`findRow`] as an assertion.
fn expectRow(col: Value, want: ScalarValue) !void {
    if (try findRow(col, want) == null) {
        std.debug.print("no row holds {any}\n", .{want});
        return error.TestUnexpectedResult;
    }
}

/// Every value type the wire defines, once each. The strings and byte
/// strings borrow `static_bytes`, which outlives the test.
const static_bytes = "a string value";

const every_value = [_]ScalarValue{
    .null_value,
    .{ .bool_value = true },
    .{ .bool_value = false },
    .{ .uint = 0 },
    .{ .uint = 127 },
    .{ .uint = 183 },
    .{ .uint = std.math.maxInt(u64) },
    .{ .int = 0 },
    .{ .int = -1 },
    .{ .int = std.math.minInt(i64) },
    .{ .float = 0.0 },
    .{ .float = -1.5 },
    .{ .float = std.math.floatMax(f64) },
    .{ .str = static_bytes },
    .{ .bytes = static_bytes },
    .{ .counter = .init(0) },
    .{ .counter = .init(-7) },
    .{ .timestamp = 1_700_000_000 },
    .{ .unknown = .{ .type_code = 12, .bytes = static_bytes } },
};

test "a value column decodes every value type" {
    const gpa = testing.allocator;
    var cols = try ValueFixture.init(gpa);
    defer cols.deinit();
    const col = cols.view();
    try col.extend(gpa, &every_value);

    // Every row's metadata word survives the round trip, and every payload
    // is exactly as wide as its word says.
    try testing.expectEqual(every_value.len, col.len());
    for (every_value, 0..) |want, i| {
        const got = (try col.get(i)).?;
        try testing.expect(want.eql(got));
    }

    // A counter, a string, a byte string and a float are the four whose
    // payload is not a plain varint, so each is found by value rather than
    // by line number and then read out of the raw column.
    try expectRow(col, ScalarValue{ .counter = .init(-7) });
    const str = (try findRow(col, ScalarValue{ .str = static_bytes })).?;
    try testing.expectEqualStrings(static_bytes, str.str);
    const bytes = (try findRow(col, ScalarValue{ .bytes = static_bytes })).?;
    try testing.expectEqualSlices(u8, static_bytes, bytes.bytes);
    const float = (try findRow(col, ScalarValue{ .float = -1.5 })).?;
    try testing.expectEqual(@as(f64, -1.5), float.float);
}

test "a value column splices at the start, the middle and the end" {
    const gpa = testing.allocator;
    var cols = try ValueFixture.init(gpa);
    defer cols.deinit();
    const col = cols.view();
    var model: std.ArrayList(ScalarValue) = .empty;
    defer model.deinit(gpa);
    for ([_]ScalarValue{
        .{ .uint = 1 },
        .{ .str = "keep" },
        .{ .float = 2.5 },
        .null_value,
    }) |row| {
        try col.append(gpa, row);
        try model.append(gpa, row);
    }
    try expectValues(col, model.items);

    for ([_]struct { index: usize, del: usize, added: []const ScalarValue }{
        .{ .index = 0, .del = 0, .added = &.{.{ .uint = 2 }} },
        .{ .index = 1, .del = 2, .added = &.{ .{ .str = "new" }, .{ .counter = .init(3) } } },
        .{ .index = col.len(), .del = 0, .added = &.{.{ .bytes = "tail" }} },
        .{ .index = 0, .del = col.len(), .added = &.{} },
    }) |step| {
        try col.splice(gpa, step.index, step.del, step.added);
        try model.replaceRange(gpa, step.index, step.del, step.added);
        try expectValues(col, model.items);
        // The raw buffer holds exactly the payloads the words describe, so
        // a row that is not deleted takes its bytes with it.
        var total: usize = 0;
        for (model.items) |row| total += payloadLen(row);
        try testing.expectEqual(total, col.rawLen());
    }
}

test "a value whose declared length runs past the end is rejected" {
    const gpa = testing.allocator;
    var cols = try ValueFixture.init(gpa);
    defer cols.deinit();
    // A string that claims eight bytes and has three.
    try cols.meta.extend(gpa, &.{ValueMeta.init(.string, 8).raw});
    try cols.raw.append(gpa, "abc");
    const col = cols.view();

    var it = try col.iterator();
    try testing.expectError(error.LengthExceedsInput, it.next());

    // A float whose word does not say eight bytes is a malformed word
    // rather than a short read.
    try cols.meta.splice(gpa, 0, 1, &.{ValueMeta.init(.float, 4).raw});
    try cols.raw.append(gpa, &.{ 1, 2, 3, 4 });
    try testing.expectError(error.InvalidValueMeta, col.get(0));
}

test "a value column round trips through its wire form" {
    const gpa = testing.allocator;
    var cols = try ValueFixture.init(gpa);
    defer cols.deinit();
    const col = cols.view();
    try col.extend(gpa, every_value[3..]);

    const bytes = try col.meta.encode(gpa);
    defer gpa.free(bytes);
    var back = try UintCol.load(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(col.len(), back.len());
    const reloaded = Value.init(&back, col.raw);
    try expectValues(reloaded, every_value[3..]);
}

test "an op id list column decodes runs of ids" {
    const gpa = testing.allocator;
    var num = try UintCol.init(gpa);
    defer num.deinit();
    var actor = try UintCol.init(gpa);
    defer actor.deinit();
    var counter = try CounterCol.init(gpa);
    defer counter.deinit();
    try num.extend(gpa, &.{ 0, 2, 3, 1 });
    try actor.extend(gpa, &.{ 1, 1, 2, 2, 2, 3 });
    try counter.extend(gpa, &.{ 1, 1, 4, 5, 6, 2 });
    const list = try OpIdList.init(&num, &actor, &counter);

    const want = [_][]const OpId{
        &.{},
        &.{ OpId.init(1, 1), OpId.init(1, 1) },
        &.{ OpId.init(4, 2), OpId.init(5, 2), OpId.init(6, 2) },
        &.{OpId.init(2, 3)},
    };
    try expectOpIdList(list, &want);

    // The row range and the id range are different ranges, and the
    // translation between them is the sum of the counts.
    const first = try list.flatRange(0, 1);
    try testing.expectEqual(@as(usize, 0), first.start);
    try testing.expectEqual(@as(usize, 0), first.count);
    const second = try list.flatRange(1, 1);
    try testing.expectEqual(@as(usize, 0), second.start);
    try testing.expectEqual(@as(usize, 2), second.count);
    const third = try list.flatRange(2, 2);
    try testing.expectEqual(@as(usize, 2), third.start);
    try testing.expectEqual(@as(usize, 4), third.count);
}

fn expectOpIdInStep(list: OpIdList, want: usize) !void {
    try testing.expectEqual(want, list.len());
    try testing.expectEqual(want, list.num.len());
    try list.checkLengths();
    // The two flat columns are one value per id, so their lengths are the
    // sum of the counts and not the row count.
    var total: usize = 0;
    var counts = try list.num.iterator();
    while (try counts.next()) |maybe_count| total += @intCast(maybe_count.?);
    try testing.expectEqual(total, list.actor.len());
    try testing.expectEqual(total, list.counter.len());
}

fn expectOpIdList(list: OpIdList, want: []const []const OpId) !void {
    try expectOpIdInStep(list, want.len);
    var it = try list.iterator(testing.allocator);
    defer it.deinit();
    var i: usize = 0;
    while (try it.next()) |got| {
        if (i >= want.len) return error.TestUnexpectedResult;
        try testing.expectEqualSlices(OpId, want[i], got);
        i += 1;
    }
    try testing.expectEqual(want.len, i);
    try testing.expect(it.done());
    for (want, 0..) |expected, j| {
        const got = (try list.get(testing.allocator, j)) orelse return error.TestUnexpectedResult;
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(OpId, expected, got);
    }
}

test "an op id list column splices at the start, the middle and the end" {
    const gpa = testing.allocator;
    var num = try UintCol.init(gpa);
    defer num.deinit();
    var actor = try UintCol.init(gpa);
    defer actor.deinit();
    var counter = try CounterCol.init(gpa);
    defer counter.deinit();
    var list = try OpIdList.init(&num, &actor, &counter);
    var model: std.ArrayList([]const OpId) = .empty;
    defer model.deinit(gpa);
    for ([_][]const OpId{
        &.{OpId.init(1, 0)},
        &.{ OpId.init(2, 0), OpId.init(3, 0) },
        &.{},
    }) |row| {
        try list.append(gpa, row);
        try model.append(gpa, row);
    }
    try expectOpIdList(list, model.items);

    for ([_]struct { index: usize, del: usize, added: []const []const OpId }{
        .{ .index = 0, .del = 0, .added = &.{&.{ OpId.init(9, 0), OpId.init(10, 0) }} },
        .{ .index = 2, .del = 1, .added = &.{&.{ OpId.init(11, 0), OpId.init(12, 0), OpId.init(13, 0) }} },
        .{ .index = list.len(), .del = 0, .added = &.{&.{OpId.init(14, 0)}} },
        .{ .index = 0, .del = list.len(), .added = &.{&.{OpId.init(1, 0)}} },
    }) |step| {
        try list.splice(gpa, step.index, step.del, step.added);
        try model.replaceRange(gpa, step.index, step.del, step.added);
        try expectOpIdList(list, model.items);
    }
}

test "an op id list row whose count runs past the flat columns is rejected" {
    const gpa = testing.allocator;
    var num = try UintCol.init(gpa);
    defer num.deinit();
    var actor = try UintCol.init(gpa);
    defer actor.deinit();
    var counter = try CounterCol.init(gpa);
    defer counter.deinit();
    try num.extend(gpa, &.{9});
    try actor.extend(gpa, &.{1});
    try counter.extend(gpa, &.{1});
    // The columns do not add up, so the view refuses to exist at all.
    try testing.expectError(error.InvalidValue, OpIdList.init(&num, &actor, &counter));
}

/// A group and the columns it is a view over, for a test that owns them.
const GroupFixture = struct {
    num: UintCol,
    meta: UintCol,
    raw: Raw,
    wide: UintCol,
    signed: SignedCol,
    index: IndexCol,
    flag: BoolCol,
    columns: []GroupedColumn,

    /// One column of every kind a group can carry, in the order a group
    /// reads them, so a test's flat value list is one value per column.
    fn init(gpa: std.mem.Allocator) ParseError!*GroupFixture {
        const self = try gpa.create(GroupFixture);
        errdefer gpa.destroy(self);
        self.* = .{
            .num = try UintCol.init(gpa),
            .meta = try UintCol.init(gpa),
            .raw = Raw.init(gpa),
            .wide = try UintCol.init(gpa),
            .signed = try SignedCol.init(gpa),
            .index = try IndexCol.init(gpa),
            .flag = try BoolCol.init(gpa),
            .columns = try gpa.alloc(GroupedColumn, 4),
        };
        self.columns[0] = .{ .value = Value.init(&self.meta, &self.raw) };
        self.columns[1] = .{ .uint = &self.wide };
        self.columns[2] = .{ .int = &self.signed };
        self.columns[3] = .{ .boolean = &self.flag };
        return self;
    }

    fn deinit(self: *GroupFixture, gpa: std.mem.Allocator) void {
        gpa.free(self.columns);
        self.flag.deinit();
        self.index.deinit();
        self.signed.deinit();
        self.wide.deinit();
        self.raw.deinit();
        self.meta.deinit();
        self.num.deinit();
        gpa.destroy(self);
    }

    fn view(self: *GroupFixture) ParseError!Group {
        return Group.init(&self.num, self.columns);
    }
};

/// A group's count column holds one row per group row; its grouped columns
/// hold one value per count, so their lengths are the sum of the counts.
fn expectGroupInStep(group: Group, want: usize) !void {
    try testing.expectEqual(want, group.len());
    try testing.expectEqual(want, group.num.len());
    try group.checkLengths();
    const total = try group.flatLen();
    for (group.columns) |*col| try testing.expectEqual(total, col.len());
}

/// A row a group is expected to decode to: a count and the flat values, the
/// same shape a splice takes, so a test states an expectation once.
const WantRow = struct { count: usize, values: []const SimpleValue };

fn expectGroup(group: Group, want: []const WantRow) !void {
    try expectGroupInStep(group, want.len);
    var it = try group.iterator(testing.allocator);
    defer it.deinit();
    var i: usize = 0;
    while (try it.next()) |row| {
        if (i >= want.len) return error.TestUnexpectedResult;
        const expected = want[i];
        try testing.expectEqual(expected.count, row.count);
        try testing.expectEqual(expected.values.len, row.values.len);
        for (expected.values, 0..) |cell, at| {
            try testing.expect(cell.eql(row.values[at]));
            // The same cell, read the way a caller reads a group: inner row
            // and payload column rather than a flat offset.
            const r = at / row.columns;
            const c = at % row.columns;
            try testing.expect(cell.eql(try row.at(r, c)));
        }
        try testing.expectError(error.InvalidValue, row.at(row.count, 0));
        try testing.expectError(error.InvalidValue, row.at(0, row.columns));
        i += 1;
    }
    try testing.expectEqual(want.len, i);
    try testing.expect(it.done());
}

test "a group column decodes rows of several values" {
    const gpa = testing.allocator;
    var cols = try GroupFixture.init(gpa);
    defer cols.deinit(gpa);
    const group = try cols.view();
    // Three rows of two, one and three values. Every inner row holds one
    // value in each of the four payload columns: a scalar value, an unsigned
    // integer, a signed integer, and a boolean.
    try group.splice(gpa, 0, 0, &.{
        .{ .count = 2, .values = &.{
            .{ .value = .{ .uint = 1 } },
            .{ .uint = 10 },
            .{ .int = -1 },
            .{ .boolean = true },
            .{ .value = .{ .str = "a" } },
            .{ .uint = 11 },
            .{ .int = -2 },
            .{ .boolean = false },
        } },
        .{ .count = 1, .values = &.{
            .{ .value = .null_value },
            .{ .uint = 12 },
            .{ .int = null },
            .{ .boolean = true },
        } },
        .{ .count = 3, .values = &.{
            .{ .value = .{ .float = 1.5 } },
            .{ .uint = 13 },
            .{ .int = -4 },
            .{ .boolean = false },
            .{ .value = .{ .counter = .init(2) } },
            .{ .uint = null },
            .{ .int = -5 },
            .{ .boolean = true },
            .{ .value = .{ .bool_value = true } },
            .{ .uint = 15 },
            .{ .int = -6 },
            .{ .boolean = false },
        } },
    });
    try expectGroup(group, &.{
        .{ .count = 2, .values = &.{
            .{ .value = .{ .uint = 1 } },
            .{ .uint = 10 },
            .{ .int = -1 },
            .{ .boolean = true },
            .{ .value = .{ .str = "a" } },
            .{ .uint = 11 },
            .{ .int = -2 },
            .{ .boolean = false },
        } },
        .{ .count = 1, .values = &.{
            .{ .value = .null_value },
            .{ .uint = 12 },
            .{ .int = null },
            .{ .boolean = true },
        } },
        .{ .count = 3, .values = &.{
            .{ .value = .{ .float = 1.5 } },
            .{ .uint = 13 },
            .{ .int = -4 },
            .{ .boolean = false },
            .{ .value = .{ .counter = .init(2) } },
            .{ .uint = null },
            .{ .int = -5 },
            .{ .boolean = true },
            .{ .value = .{ .bool_value = true } },
            .{ .uint = 15 },
            .{ .int = -6 },
            .{ .boolean = false },
        } },
    });
}

test "a group column splices at the start, the middle and the end" {
    const gpa = testing.allocator;
    var cols = try GroupFixture.init(gpa);
    defer cols.deinit(gpa);
    const group = try cols.view();
    try group.splice(gpa, 0, 0, &.{
        .{ .count = 1, .values = &.{
            .{ .value = .{ .uint = 1 } },
            .{ .uint = 1 },
            .{ .int = 1 },
            .{ .boolean = true },
        } },
        .{ .count = 2, .values = &.{
            .{ .value = .{ .uint = 2 } },
            .{ .uint = 2 },
            .{ .int = 2 },
            .{ .boolean = false },
            .{ .value = .{ .uint = 3 } },
            .{ .uint = 3 },
            .{ .int = 3 },
            .{ .boolean = true },
        } },
        .{ .count = 1, .values = &.{
            .{ .value = .{ .uint = 4 } },
            .{ .uint = 4 },
            .{ .int = 4 },
            .{ .boolean = false },
        } },
    });
    try expectGroupInStep(group, 3);

    // At the start: one row for two. The rows it replaces held three values
    // between them, so the flat range it splices is wider than the row range.
    try group.splice(gpa, 0, 2, &.{.{ .count = 1, .values = &.{
        .{ .value = .{ .uint = 9 } },
        .{ .uint = 9 },
        .{ .int = 9 },
        .{ .boolean = true },
    } }});
    try expectGroup(group, &.{
        .{ .count = 1, .values = &.{
            .{ .value = .{ .uint = 9 } },
            .{ .uint = 9 },
            .{ .int = 9 },
            .{ .boolean = true },
        } },
        .{ .count = 1, .values = &.{
            .{ .value = .{ .uint = 4 } },
            .{ .uint = 4 },
            .{ .int = 4 },
            .{ .boolean = false },
        } },
    });

    // In the middle: a row of three values for a row of one.
    try group.splice(gpa, 1, 1, &.{.{ .count = 3, .values = &.{
        .{ .value = .{ .uint = 5 } },
        .{ .uint = 5 },
        .{ .int = 5 },
        .{ .boolean = false },
        .{ .value = .{ .uint = 6 } },
        .{ .uint = 6 },
        .{ .int = 6 },
        .{ .boolean = true },
        .{ .value = .{ .uint = 7 } },
        .{ .uint = 7 },
        .{ .int = 7 },
        .{ .boolean = false },
    } }});
    try expectGroup(group, &.{
        .{ .count = 1, .values = &.{
            .{ .value = .{ .uint = 9 } },
            .{ .uint = 9 },
            .{ .int = 9 },
            .{ .boolean = true },
        } },
        .{ .count = 3, .values = &.{
            .{ .value = .{ .uint = 5 } },
            .{ .uint = 5 },
            .{ .int = 5 },
            .{ .boolean = false },
            .{ .value = .{ .uint = 6 } },
            .{ .uint = 6 },
            .{ .int = 6 },
            .{ .boolean = true },
            .{ .value = .{ .uint = 7 } },
            .{ .uint = 7 },
            .{ .int = 7 },
            .{ .boolean = false },
        } },
    });

    // At the end: two rows for none, and then everything for nothing.
    try group.splice(gpa, group.len(), 0, &.{
        .{ .count = 1, .values = &.{
            .{ .value = .{ .str = "tail" } },
            .{ .uint = 8 },
            .{ .int = 8 },
            .{ .boolean = true },
        } },
        .{ .count = 1, .values = &.{
            .{ .value = .null_value },
            .{ .uint = null },
            .{ .int = null },
            .{ .boolean = false },
        } },
    });
    try expectGroupInStep(group, 4);
    try group.splice(gpa, 0, group.len(), &.{});
    try expectGroupInStep(group, 0);
    try testing.expect(group.isEmpty());
}

test "a group row that does not spell out every column is rejected" {
    const gpa = testing.allocator;
    var cols = try GroupFixture.init(gpa);
    defer cols.deinit(gpa);
    const group = try cols.view();
    // Two values for a count of one, with four columns.
    try testing.expectError(error.InvalidValue, group.splice(gpa, 0, 0, &.{.{ .count = 1, .values = &.{
        .{ .value = .{ .uint = 1 } },
        .{ .uint = 1 },
        .{ .value = .{ .uint = 2 } },
    } }}));
    try expectGroupInStep(group, 0);
}
