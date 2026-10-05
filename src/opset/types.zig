//! The types an op set row is assembled from, and the column codecs the two
//! of them that are stored numerically are kept in.
//!
//! Upstream `op_set2/types.rs` (777 lines) and `op_set2/meta.rs` (176 lines)
//! between them hold every type a row of the op set is built from. Most of
//! them the port already had — the value and action types in `value.zig`, the
//! identity types in `types.zig` — so this module holds what was missing and
//! re-exports the rest under the names `op_set2.rs:12-15` gives them, so the
//! op set's own code reads like upstream's.
//!
//! Three things here are FORMAT and are pinned by tests rather than derived:
//!
//! * the action codes (`op_set2/types.rs:99-112`), which are not upstream's
//!   declaration order for the enum (`op_set2/types.rs:64-82`);
//! * the bytes a scalar occupies in the value column, which its type tag
//!   decides (`op_set2/types.rs:315-394`, `op_set2/meta.rs:73-93`);
//! * `KeyRef`'s partial order (`op_set2/types.rs:584-592`), the second half
//!   of the row-order invariant (`op_set2/op.rs:1040-1073`);
//! * what a sequence key's two columns hold: the anchor's actor and counter
//!   for an element, an absent actor and a zero counter for the head
//!   (`op_set2/types.rs:616-628`, `op_set2/op_set/op_iter.rs:239-247`).

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const value = @import("../value.zig");
const leb128 = @import("../leb128.zig");
const change = @import("../change.zig");
// The column codec, which names a column's wire format, its encoder and its
// per-slab weight. `rle` is the same codec one level down, without a column:
// the tests use its `encodedSize` to pin a slab's byte count.
const column = @import("../hexane/column.zig");
const rle = @import("../hexane/rle.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;

/// The element a sequence row is anchored to (`op_set2/types.rs:578-582`,
/// declared at `types.rs:652-683`). It is a struct over an `OpId` and not the
/// `OpId` itself, because the head is `OpId{0, 0}` and only the wrapper knows
/// that (`types.rs:668-678`).
const ElemId = types.ElemId;

// ── Types the port already had ─────────────────────────────────────────────

/// An index into the document's actor table (`op_set2/types.rs:16-18`).
/// Upstream wraps a `u32` in a newtype; the port's `types.ActorIdx` is the
/// `u32` itself, which is what the hexane codecs want.
pub const ActorIdx = types.ActorIdx;

/// What an operation does, and the code it occupies in the action column
/// (`op_set2/types.rs:62-112`).
pub const Action = value.Action;

/// What an operation is, once its action, value and mark columns have been
/// combined (`op_set2/types.rs:148-189`).
pub const OpType = value.OpType;

/// A scalar value, as the op set stores it (`op_set2/types.rs:191-203`).
pub const ScalarValue = value.ScalarValue;

/// The word that carries a value's byte length and its type tag
/// (`op_set2/meta.rs:19-43`).
///
/// A `u64` in two fields: the low four bits are the type tag and the high
/// sixty are the value's width in the value arena (`op_set2/meta.rs:19-43`).
/// It is declared once, in `value.zig`, and aliased here so the op set's code
/// reads like upstream's `op_set2.rs:12-15`.
///
/// # Constructing one is trusted; decoding one is checked
///
/// The two halves of this word are not the same kind of thing.
///
/// * [`value.ValueMeta.init`] is **infallible and trusted**. It takes a
///   `usize` length and a `ValueType` and packs them, which is right for a
///   writer that already knows the payload's width — [`metaOf`] is the only
///   such writer here, and it measures a value it is holding. Its
///   precondition is that the length fits in sixty bits and the type's code
///   fits in the low four; `value.zig` states and asserts it. A length that
///   did not fit would shift bits out of the word, so this is a programmer
///   precondition and not a silent truncation.
/// * A word that came **out of a column** is untrusted: `ValueMeta.fromRaw`
///   is total and `ValueMeta.length` reads the sixty bits back through a
///   checked cast, so a column that declares a width nothing can hold is
///   `error.Overflow` rather than a truncated length. That is the path every
///   reader of a stored value takes — [`op_iter.ValueIter`] reads the word
///   and then takes exactly `meta.length()` bytes from the raw column.
///
/// So: `init` for a width this code just measured, `fromRaw` plus `length`
/// for a width that arrived in bytes. There is no third spelling, and a
/// parser that wants to *build* a word from untrusted bytes has to check the
/// width against sixty bits itself rather than call `init`.
pub const ValueMeta = value.ValueMeta;

/// The type tag in a value metadata word (`op_set2/meta.rs:4-17`).
pub const ValueType = value.ValueType;

/// Low-level encoded-change metadata, including decoded author and the
/// complete opaque extra footer. Payloads borrow from the encoded change.
/// For a document-independent owner, use the high-level `doc.ChangeMetadata`.
pub const ChangeMetadata = change.ChangeMetadata;

// ── Marks ──────────────────────────────────────────────────────────────────

/// A mark's name and the value it puts on the span
/// (`op_set2/types.rs:56-60`).
///
/// The name is a borrowed slice, as every payload in the port's `ScalarValue`
/// is: a `MarkData` is only valid while the mark name column, or the change
/// it was read out of, is.
///
/// Upstream declares this in `op_set2/types.rs:52-55` and re-exports it at
/// `op_set2.rs:12`. The port declares it once, in `marks.zig`, because the
/// mark fold there is what consumes it and that file was here first; a second
/// definition would let the two drift.
pub const MarkData = @import("../marks.zig").MarkData;

// ── Keys and properties ────────────────────────────────────────────────────

/// A property of an object, borrowed: a map key, or an index into a sequence
/// (`op_set2/types.rs:572-576`).
///
/// Upstream has two spellings of this shape — the owned `crate::types::Prop`
/// (`types.rs:389-394`) and the op set's borrowed `PropRef` — and the port has
/// one borrowed form, `types.Prop` (`types.zig:288-319`). This alias gives it
/// the name the op set uses.
pub const PropRef = types.Prop;

/// What a row of the op set hangs by: a map key, or the element a sequence
/// row is anchored to (`op_set2/types.rs:578-582`).
///
/// This is the second component of the row-order invariant. Within one
/// object, rows group by `KeyRef`: map groups ascend by key, sequence groups
/// ascend by element id, and a map row and a sequence row are never adjacent
/// (`op_set2/op.rs:1055-1069`). There is therefore no total order over
/// `KeyRef`, and `order` is a partial one.
pub const KeyRef = union(enum) {
    /// A map key.
    map: []const u8,
    /// The element a sequence row is anchored to: for an insert, the element
    /// it was inserted after, or the head of the sequence when there is no such
    /// element; for anything else, the element it updates
    /// (`op_set2/types.rs:574-582`). Upstream's payload is an `ElemId` and so
    /// is this one (`types.rs:652-653`), which is what lets it say the head.
    seq: ElemId,

    /// A key from a sequence element id (`From<ElemId> for KeyRef`,
    /// `op_set2/types.rs:594-598`).
    ///
    /// `fromElemId(ElemId.head())` is how a row says "the front of the
    /// sequence" (`op_set2/op_set.rs:1984`), and there is no second spelling
    /// for it: upstream's construction is the wrapper around the id, and the
    /// head is the id at the origin.
    pub fn fromElemId(e: ElemId) KeyRef {
        return .{ .seq = e };
    }

    /// A key from a map key (`op_set2/types.rs:600-604`).
    pub fn fromStr(key: []const u8) KeyRef {
        return .{ .map = key };
    }

    /// Upstream derives `PartialEq` (`op_set2/types.rs:578`). The port's
    /// `map` payload is a slice, which Zig does not compare by content, so
    /// the comparison is spelled out.
    pub fn eql(a: KeyRef, b: KeyRef) bool {
        return switch (a) {
            .map => |x| switch (b) {
                .map => |y| std.mem.eql(u8, x, y),
                .seq => false,
            },
            .seq => |x| switch (b) {
                .map => false,
                .seq => |y| x.eql(y),
            },
        };
    }

    /// The row-order invariant's key comparison (`op_set2/types.rs:584-592`):
    /// map keys compare as byte strings, sequence anchors as element ids, and
    /// the two never compare at all — which is the arm that keeps a map row
    /// and a sequence row from being adjacent in one object.
    pub fn order(a: KeyRef, b: KeyRef) ?std.math.Order {
        return switch (a) {
            .map => |x| switch (b) {
                .map => |y| std.mem.order(u8, x, y),
                .seq => null,
            },
            .seq => |x| switch (b) {
                .map => null,
                .seq => |y| x.compare(y),
            },
        };
    }

    /// The actor the anchor was made by, or null for a map key **and for the
    /// head** (`KeyRef::actor`, `op_set2/types.rs:616-621`).
    ///
    /// This is upstream's `KeyRef::Seq(e) => e.actor()` and nothing more, so
    /// the head — which has no actor, because it is not an operation
    /// (`types.rs:668-674`) — answers null here too. That null is what leaves
    /// the actor column of a head anchor absent
    /// (`op_set2/change/collector.rs:406`); the port read it back as a map key
    /// before `ElemId` was a type, so no row could anchor at the front of a
    /// sequence.
    pub fn actor(self: KeyRef) ?ActorIdx {
        return switch (self) {
            .map => null,
            .seq => |e| e.actor(),
        };
    }

    /// The counter the anchor was made at, or null for a map key
    /// (`KeyRef::icounter`, `op_set2/types.rs:623-628`).
    ///
    /// Upstream wraps `e.icounter()` in a `Some` **without asking whether the
    /// element is the head** (`op_set2/types.rs:626`), so the head's counter
    /// is a `Some(0)` and not a null. That is what tells a head anchor apart
    /// from a map key on the way back in
    /// (`op_set2/op_set/op_iter.rs:239-247`, where `(None, None)` is a map key
    /// and `(Some(0), None)` is the head), and it is why this is not
    /// `ElemId::actor`'s answer to the same question.
    pub fn icounter(self: KeyRef) ?i64 {
        return switch (self) {
            .map => null,
            .seq => |e| e.icounter(),
        };
    }

    /// The map key, or null for a sequence anchor
    /// (`op_set2/types.rs:630-635`).
    pub fn keyStr(self: KeyRef) ?[]const u8 {
        return switch (self) {
            .map => |s| s,
            .seq => null,
        };
    }

    /// The sequence anchor, or null for a map key
    /// (`op_set2/types.rs:637-642`).
    pub fn elemid(self: KeyRef) ?ElemId {
        return switch (self) {
            .map => null,
            .seq => |e| e,
        };
    }
};

/// An element id from a counter and an actor (`ElemId(opid)`, `types.rs:653`).
///
/// `ElemId` is a type and not the `OpId` itself (`types.rs:652-653`), so the
/// two steps are separate here as they are upstream: an id is built, and then
/// it is wrapped. The head is the same id at the origin
/// ([`ElemId.head`]).
fn at(ctr: u32, actor: ActorIdx) ElemId {
    return ElemId.fromOpId(types.OpId.init(ctr, actor));
}

// ── Values an op carries ───────────────────────────────────────────────────

/// The value an operation carries: an object it makes, or a scalar it puts
/// (`op_set2/types.rs:654-658`).
pub const ValueRef = union(enum) {
    /// The object this op makes, and of what type.
    object: types.ObjType,
    /// The value this op puts.
    scalar: ScalarValue,

    /// An object a make action produces, and the value every other action
    /// carries (`op_set2/types.rs:667-675`).
    pub fn fromActionValue(action: Action, v: ScalarValue) ValueRef {
        return switch (action) {
            .make_map => .{ .object = .map },
            .make_list => .{ .object = .list },
            .make_text => .{ .object = .text },
            .make_table => .{ .object = .table },
            .set, .delete, .increment, .mark => .{ .scalar = v },
        };
    }

    /// A value that is a string (`op_set2/types.rs:708-710`).
    pub fn str(s: []const u8) ValueRef {
        return .{ .scalar = .{ .str = s } };
    }

    /// Whether this value is an object the op makes
    /// (`op_set2/types.rs:712-714`).
    pub fn isObject(self: ValueRef) bool {
        return self == .object;
    }

    /// A copy that owns its bytes, for a value that has to outlive the column
    /// or the change it was read out of. Upstream's `into_owned`
    /// (`op_set2/types.rs:687-692`) is the same move, and it takes the shape
    /// the port gives every owned copy: duplicate into a named allocator, and
    /// a `deinit` that gives the bytes back (`change.zig:275,309`).
    pub fn intoOwned(self: ValueRef, gpa: Allocator) !OwnedValueRef {
        return .{
            .value = switch (self) {
                .object => |o| ValueRef{ .object = o },
                .scalar => |s| ValueRef{ .scalar = try s.dup(gpa) },
            },
        };
    }

    /// Converts to the public object-kind/scalar value with independently
    /// owned scalar bytes (`op_set2/types.rs:697-705`).
    pub fn intoValue(self: ValueRef, gpa: Allocator) !value.OwnedValue {
        return (switch (self) {
            .object => |o| value.Value{ .object = o },
            .scalar => |s| value.Value{ .scalar = s },
        }).intoOwned(gpa);
    }
};

/// A `ValueRef` whose borrowed payloads were copied into an allocator the
/// caller named. Upstream's `into_owned` returns a `ValueRef<'static>`
/// (`op_set2/types.rs:687-692`) and Rust frees the `Cow`s by dropping them;
/// a borrowed slice type has to be told what to free, so the copy and the
/// free travel together here, as they do for `ChangeMetadata`
/// (`change.zig:275,309`).
pub const OwnedValueRef = struct {
    /// The copy.
    value: ValueRef,

    /// Gives back every byte `intoOwned` allocated, and nothing this value
    /// borrowed (`op_set2/types.rs:687-692`).
    pub fn deinit(self: *OwnedValueRef, gpa: Allocator) void {
        switch (self.value) {
            .object => {},
            .scalar => |s| {
                var owned = s;
                owned.deinitOwned(gpa);
            },
        }
        self.* = undefined;
    }
};

// ── A scalar's raw form ────────────────────────────────────────────────────
//
// `ScalarValue` is declared in `value.zig`, so the raw encoding is free
// functions here rather than methods on it.

/// The payload `appendRaw` writes for `v`, in bytes. Null and a boolean
/// occupy none: their whole value is in the metadata word
/// (`op_set2/meta.rs:78-82`, `column_range/value.rs:222-225`).
///
/// This is the length half of the metadata word, which is what upstream's
/// `to_raw` and `ValueMeta::from` together answer
/// (`op_set2/types.rs:343-367`, `op_set2/meta.rs:73-93`).
pub fn rawLen(v: ScalarValue) usize {
    return switch (v) {
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

/// Appends the bytes `v` occupies in the raw value column, which is what
/// upstream's `to_raw` and `as_raw` return
/// (`op_set2/types.rs:343-367,369-394`).
///
/// The two differ upstream only in whether the varint forms come back owned
/// or borrowed, a distinction the `Cow` in the return type carries and a
/// borrowed slice type does not. An integer's bytes are written straight into
/// the buffer rather than into a temporary first, which is the FIXME
/// upstream leaves at `op_set2/types.rs:401-403`.
pub fn appendRaw(gpa: Allocator, out: *std.ArrayList(u8), v: ScalarValue) Allocator.Error!void {
    switch (v) {
        .null_value, .bool_value => {},
        .uint => |u| try leb128.appendUnsigned(out, gpa, u),
        .int => |i| try leb128.appendSigned(out, gpa, i),
        .counter => |c| try leb128.appendSigned(out, gpa, c.current),
        .timestamp => |t| try leb128.appendSigned(out, gpa, t),
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

/// The bytes `v` already holds, or null when it has none of its own and
/// `appendRaw` would have to build them. Upstream's `as_raw`
/// (`op_set2/types.rs:369-394`) always has an answer, because it can return a
/// `Cow::Owned`; this is the half of it that is a borrow.
pub fn asRaw(v: ScalarValue) ?[]const u8 {
    return switch (v) {
        .str => |s| s,
        .bytes => |b| b,
        .actor_id => |a| a.bytes,
        .unknown => |u| u.bytes,
        .null_value, .bool_value, .uint, .int, .float, .counter, .timestamp => null,
    };
}

/// The metadata word `v` encodes as: its payload length shifted up, with its
/// wire type tag in the low nibble (`op_set2/meta.rs:73-93`, reached through
/// `ScalarValue::meta` at `op_set2/types.rs:396-398`).
///
/// The tag is the *wire* tag and not `ScalarValue.valueType`
/// (`value.zig:141-151`): a counter is tag 8 and a timestamp is tag 9 here,
/// where the logical type folds both into `leb`. An `unknown` keeps the type
/// code its writer gave it (`op_set2/meta.rs:88-90`), even a code below 10
/// that a reader will see as the defined tag it collides with.
///
/// **This is the trusted construction path**, and the only one in the op
/// set: the length it packs is [`rawLen`] of a `ScalarValue` this code is
/// already holding, so it is measured rather than declared and the sixty-bit
/// precondition [`ValueMeta`] states holds by construction. It is infallible
/// for that reason. A word built out of bytes someone else wrote is *not*
/// built here — it comes back through [`ValueMeta.fromRaw`] and is read with
/// the checked `length`.
pub fn metaOf(v: ScalarValue) ValueMeta {
    return ValueMeta.init(switch (v) {
        .null_value => .null_value,
        .bool_value => |b| if (b) .true_value else .false_value,
        .uint => .uleb,
        .int => .leb,
        .float => .float,
        .str => .string,
        // An actor id in the value column is an opaque byte payload; the
        // reference to an actor is the key columns' business
        // (`column_range/value.rs:421-424`).
        .bytes, .actor_id => .bytes,
        .counter => .counter,
        .timestamp => .timestamp,
        .unknown => |u| ValueType{ .unknown = u.type_code },
    }, rawLen(v));
}

/// The scalar a metadata word and its payload describe
/// (`op_set2/types.rs:314-341`).
///
/// `raw` is exactly the bytes the word declares — `try meta.length()` of
/// them, a checked read, because a word that arrived in bytes can declare a
/// width no target can hold — and nothing else. Upstream's
/// `parse_uleb128`/`parse_leb128`
/// (`op_set2/types.rs:471-481`) take the first number in the slice and ignore
/// whatever follows; this refuses a payload that is not one whole number,
/// because the load path already refuses it (`column_range/value.rs:288-311`)
/// and two readers of one document must not disagree about whether it is
/// valid.
///
/// Upstream reports the failures as a four-variant `ReadScalarError`
/// (`op_set2/types.rs:453-463`); the port has one error set for anything
/// reachable from untrusted bytes, so each lands on the member the same
/// failure already has:
///
/// | upstream  | port                                              | from |
/// |-----------|---------------------------------------------------|------|
/// | `Leb`     | `InvalidLeb128`, `UnexpectedEnd`, `Overflow`      | `leb128.zig:108-140` |
/// | `Uleb`    | as `Leb`                                          | `op_set2/types.rs:465-469`, unreachable from here |
/// | `Float`   | `InvalidValueMeta`                                | a float payload that is not eight bytes |
/// | `Str`     | `InvalidUtf8`                                     | `std.unicode.utf8ValidateSlice` |
///
/// Null and the two booleans read the word alone and never look at `raw`
/// (`op_set2/types.rs:320-322`).
pub fn fromRaw(meta: ValueMeta, raw: []const u8) ParseError!ScalarValue {
    return switch (meta.typeCode()) {
        .null_value => ScalarValue.null_value,
        .false_value => ScalarValue{ .bool_value = false },
        .true_value => ScalarValue{ .bool_value = true },
        .uleb => ScalarValue{ .uint = try wholeUnsigned(raw) },
        .leb => ScalarValue{ .int = try wholeSigned(raw) },
        .counter => ScalarValue{ .counter = .init(try wholeSigned(raw)) },
        .timestamp => ScalarValue{ .timestamp = try wholeSigned(raw) },
        .float => ScalarValue{ .float = try floatOf(raw) },
        .string => blk: {
            if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
            break :blk ScalarValue{ .str = raw };
        },
        .bytes => ScalarValue{ .bytes = raw },
        .unknown => |code| ScalarValue{ .unknown = .{ .type_code = code, .bytes = raw } },
    };
}

/// One unsigned LEB128 that fills `bytes` exactly, or the bytes and the
/// metadata word disagree (`column_range/value.rs:293-309`).
fn wholeUnsigned(bytes: []const u8) ParseError!u64 {
    const v = try leb128.readUnsigned(bytes);
    if (v.len != bytes.len) return error.InvalidValue;
    return v.value;
}

/// One signed LEB128 that fills `bytes` exactly
/// (`column_range/value.rs:288-311`).
fn wholeSigned(bytes: []const u8) ParseError!i64 {
    const v = try leb128.readSigned(bytes);
    if (v.len != bytes.len) return error.InvalidValue;
    return v.value;
}

/// An `f64` from eight little-endian bytes. Upstream treats any other length
/// as a hard error (`op_set2/types.rs:325-328`).
fn floatOf(bytes: []const u8) ParseError!f64 {
    if (bytes.len != 8) return error.InvalidValueMeta;
    var buf: [8]u8 = undefined;
    @memcpy(&buf, bytes);
    return @bitCast(std.mem.readInt(u64, &buf, .little));
}

// ── The codec glue ─────────────────────────────────────────────────────────
//
// Upstream gives an `ActorIdx` and an `Action` their place in a column with
// two impls each: `ColumnValue` names the encoding, which for both is the
// run-length one (`op_set2/types.rs:717-719,732-734`), and `RleValue` reads
// and writes the payload, which for both is one unsigned LEB128
// (`op_set2/types.rs:721-730,736-746`; `u64`'s is the same body,
// `hexane/src/lib.rs:566-579`, and `Leb128::encode_unsigned` is unsigned
// LEB128, `hexane/src/codec.rs:228-246`).
//
// The port's seam splits that in two: a column's codec is a type parameter
// whose payload must be an integer (`column.zig:1148`, `column.zig:588`), and
// the value half of the conversion is a function. So the encoding half is
// the aliases below and the value half is `actionCode`, `actionFromCode` and
// `validateActions`.

/// The op set's `id_actor` and `succ_actor` columns: a run-length column of
/// actor indices with no nulls (`op_set2/columns.rs:18,26`).
pub const ActorColumn = column.Column(ActorIdx, column.Rle(ActorIdx));

/// The op set's `obj_actor` and `key_actor` columns
/// (`op_set2/columns.rs:20,22`): the same column with nulls, for the root
/// object and for a map key, which name no actor.
pub const ActorColumnOption = column.Column(?ActorIdx, column.RleOption(ActorIdx));

/// The op set's `action` column (`op_set2/columns.rs:29`).
///
/// It holds *codes*, not actions, and `u64` rather than `u8` so that the
/// column's value range is the one `Codec::read_unsigned` gives upstream
/// (`op_set2/types.rs:738`) rather than a narrower one that would report a
/// corrupt document as an overflow. `actionFromCode` turns a code into an
/// action and refuses the codes that are not ones.
pub const ActionColumn = column.Column(u64, column.Rle(u64));

/// The code an action occupies in the action column. Upstream's
/// `From<Action> for u64` (`op_set2/types.rs:99-112`) is this table, and it
/// is FORMAT: it is written into every document, and it is not the order the
/// variants are declared in. Transcribed, not derived.
pub fn actionCode(a: Action) u64 {
    return @intFromEnum(a);
}

/// The action the code `code` stands for, or `error.InvalidAction` for
/// anything outside 0..=7. Upstream's `Action::try_from`
/// (`op_set2/types.rs:114-133`) refuses it as `PackError::InvalidValue`, as
/// each entry is unpacked; `value.zig`'s `Action.fromCode` is the same check
/// on a `u8`, repeated here only because a column entry is a `u64`.
pub fn actionFromCode(code: u64) ParseError!Action {
    return Action.fromCode(std.math.cast(u8, code) orelse return error.InvalidAction);
}

/// Refuses an action column holding a code no action names, which is the
/// check upstream makes as it unpacks (`op_set2/columns.rs:288` into
/// `op_set2/types.rs:114-133`). A load that runs it rejects the same
/// documents at the same point; a read that does not rejects them when the
/// row is read.
pub fn validateActions(col: *const ActionColumn) ParseError!void {
    var it = try col.iterator();
    while (try it.next()) |code| _ = try actionFromCode(code);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the action codes are the format table" {
    // op_set2/types.rs:99-112, one line per variant, in the order that table
    // lists them rather than the order the enum declares them.
    const table = .{
        .{ Action.make_map, 0 },
        .{ Action.set, 1 },
        .{ Action.make_list, 2 },
        .{ Action.delete, 3 },
        .{ Action.make_text, 4 },
        .{ Action.increment, 5 },
        .{ Action.make_table, 6 },
        .{ Action.mark, 7 },
    };
    inline for (table) |pair| {
        try testing.expectEqual(@as(u8, pair[1]), @intFromEnum(pair[0]));
        try testing.expectEqual(@as(u64, pair[1]), actionCode(pair[0]));
        try testing.expectEqual(pair[0], try actionFromCode(pair[1]));
    }
    // And nothing else is an action.
    try testing.expectError(error.InvalidAction, actionFromCode(8));
    try testing.expectError(error.InvalidAction, actionFromCode(255));
    // A code too wide for a byte is refused, not truncated.
    try testing.expectError(error.InvalidAction, actionFromCode(256));
    try testing.expectError(error.InvalidAction, actionFromCode(std.math.maxInt(u64)));
}

test "an action's tag value is its wire code, not its declaration order" {
    // Upstream's declaration order (op_set2/types.rs:64-82) is not its code
    // order (op_set2/types.rs:99-112): `make_list` is the second variant and
    // carries code 2, `set` is the fourth and carries code 1. The port has
    // one number per variant and it is the code, so the port's enum order is
    // the code order and *not* upstream's declaration order.
    try testing.expectEqual(@as(u8, 2), @intFromEnum(Action.make_list));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Action.set));
    try testing.expect(actionCode(Action.make_list) > actionCode(Action.set));
    try testing.expect(actionCode(Action.set) < actionCode(Action.make_text));

    // So iterating the enum yields the code order, which is the order a
    // `switch` over `Action` is written against.
    const by_code = std.enums.values(Action);
    try testing.expectEqual(@as(usize, 8), by_code.len);
    for (by_code, 0..) |a, i| {
        try testing.expectEqual(a, try actionFromCode(@intCast(i)));
    }

    // Upstream compares actions for equality and never for order
    // (`op_set2/columns.rs:165,365,423`), so nothing may come to depend on
    // this order. What must hold is the table above.
}

test "KeyRef orders map keys and sequence anchors and refuses the cross case" {
    const Case = struct { a: KeyRef, b: KeyRef, want: ?std.math.Order };
    // op_set2/types.rs:584-592, every arm, both directions.
    const cases = [_]Case{
        // Map against map: `str::cmp`, a byte comparison, so a two-byte
        // character sorts after every ASCII letter.
        .{ .a = KeyRef.fromStr(""), .b = KeyRef.fromStr(""), .want = .eq },
        .{ .a = KeyRef.fromStr(""), .b = KeyRef.fromStr("a"), .want = .lt },
        .{ .a = KeyRef.fromStr("a"), .b = KeyRef.fromStr(""), .want = .gt },
        .{ .a = KeyRef.fromStr("a"), .b = KeyRef.fromStr("a"), .want = .eq },
        .{ .a = KeyRef.fromStr("a"), .b = KeyRef.fromStr("b"), .want = .lt },
        .{ .a = KeyRef.fromStr("b"), .b = KeyRef.fromStr("a"), .want = .gt },
        .{ .a = KeyRef.fromStr("a"), .b = KeyRef.fromStr("ab"), .want = .lt },
        .{ .a = KeyRef.fromStr("z"), .b = KeyRef.fromStr("é"), .want = .lt },
        .{ .a = KeyRef.fromStr("é"), .b = KeyRef.fromStr("z"), .want = .gt },
        // Seq against seq: `ElemId`, which is an `OpId`: counter, then actor.
        .{
            .a = KeyRef.fromElemId(at(1, 0)),
            .b = KeyRef.fromElemId(at(1, 0)),
            .want = .eq,
        },
        .{
            .a = KeyRef.fromElemId(at(1, 0)),
            .b = KeyRef.fromElemId(at(2, 0)),
            .want = .lt,
        },
        .{
            .a = KeyRef.fromElemId(at(2, 0)),
            .b = KeyRef.fromElemId(at(1, 9)),
            .want = .gt,
        },
        .{
            .a = KeyRef.fromElemId(at(1, 0)),
            .b = KeyRef.fromElemId(at(1, 1)),
            .want = .lt,
        },
        .{
            .a = KeyRef.fromElemId(at(1, 1)),
            .b = KeyRef.fromElemId(at(1, 0)),
            .want = .gt,
        },
        // Map against seq, both ways: the arm that keeps a map row and a
        // sequence row from being adjacent in one object.
        .{
            .a = KeyRef.fromStr("a"),
            .b = KeyRef.fromElemId(at(1, 0)),
            .want = null,
        },
        .{
            .a = KeyRef.fromElemId(at(1, 0)),
            .b = KeyRef.fromStr("a"),
            .want = null,
        },
    };
    for (cases) |c| try testing.expectEqual(c.want, KeyRef.order(c.a, c.b));

    // An element id with a large counter still orders by counter first and
    // not by actor, which is the order the row-order invariant relies on.
    try testing.expect(KeyRef.order(
        KeyRef.fromElemId(at(std.math.maxInt(u32), 0)),
        KeyRef.fromElemId(at(0, 0)),
    ) == .gt);
}

test "KeyRef equality and its four accessors" {
    const map: KeyRef = .fromStr("k");
    const seq: KeyRef = .fromElemId(at(7, 2));

    try testing.expect(KeyRef.eql(map, KeyRef.fromStr("k")));
    try testing.expect(!KeyRef.eql(map, KeyRef.fromStr("j")));
    try testing.expect(KeyRef.eql(seq, KeyRef.fromElemId(at(7, 2))));
    try testing.expect(!KeyRef.eql(seq, KeyRef.fromElemId(at(7, 3))));
    // A map key and a sequence anchor are never equal.
    try testing.expect(!KeyRef.eql(map, seq));
    try testing.expect(!KeyRef.eql(seq, map));

    try testing.expectEqualStrings("k", map.keyStr().?);
    try testing.expectEqual(@as(?ActorIdx, null), map.actor());
    try testing.expectEqual(@as(?i64, null), map.icounter());
    try testing.expectEqual(@as(?ElemId, null), map.elemid());

    try testing.expectEqual(@as(?[]const u8, null), seq.keyStr());
    try testing.expectEqual(@as(ActorIdx, 2), seq.actor().?);
    try testing.expectEqual(@as(i64, 7), seq.icounter().?);
    try testing.expectEqual(at(7, 2), seq.elemid().?);
}

test "a sequence key anchored at the head has no actor and a counter of zero" {
    // The one spelling of the head, and the pair it has to answer with:
    // `KeyRef::actor` is `ElemId::actor` and so is null
    // (`op_set2/types.rs:616-621`, `types.rs:668-674`), while
    // `KeyRef::icounter` wraps `ElemId::icounter` in a `Some` without asking
    // whether the element is the head (`op_set2/types.rs:623-628`,
    // `types.rs:663-666`). The two disagree on purpose: it is the disagreement
    // that tells a head apart from a map key on the wire
    // (`op_set2/op_set/op_iter.rs:239-247`).
    const head = KeyRef.fromElemId(ElemId.head());
    try testing.expectEqual(@as(?ActorIdx, null), head.actor());
    try testing.expectEqual(@as(?i64, 0), head.icounter().?);
    try testing.expect(head.keyStr() == null);
    try testing.expect(head.elemid().?.isHead());

    // A map key's two answers are both null, so the head's zero counter is
    // the only thing that separates the two shapes.
    const map = KeyRef.fromStr("k");
    try testing.expectEqual(@as(?ActorIdx, null), map.actor());
    try testing.expectEqual(@as(?i64, null), map.icounter());

    // The head is the minimum under `KeyRef`'s order, which is what makes "the
    // front of the list" the first position in it and rule R4's "its own id
    // sorts before the register" arm reach the head
    // (`op_set2/op.rs:1061-1063`, `types.rs:440-444`).
    const first = KeyRef.fromElemId(at(1, 0));
    try testing.expectEqual(.lt, KeyRef.order(head, first).?);
    try testing.expectEqual(.gt, KeyRef.order(first, head).?);
    try testing.expectEqual(.eq, KeyRef.order(head, KeyRef.fromElemId(ElemId.head())).?);
    // The cross arm is still the arm that refuses, head or not: a document
    // opens on the root map and never on a sequence (`op_set2/op.rs:1049-1054`).
    try testing.expect(KeyRef.order(head, map) == null);
    try testing.expect(KeyRef.order(map, head) == null);
}

test "MarkData carries a name and a value" {
    const md: MarkData = .{ .name = "bold", .value = .{ .uint = 3 } };
    try testing.expectEqualStrings("bold", md.name);
    try testing.expectEqual(@as(u64, 3), md.value.uint);

    // A mark end has a name column entry that is not a begin, but a
    // `MarkData` is only ever built for a begin; the value it carries is
    // `null_value` when the mark has none of its own
    // (op_set2/types.rs:177-186).
    const from_column: MarkData = .{ .name = "emphasis", .value = .null_value };
    try testing.expectEqualStrings("emphasis", from_column.name);
    try testing.expect(from_column.value == .null_value);
}

test "PropRef is the borrowed property" {
    try testing.expectEqualStrings("k", (PropRef{ .key = "k" }).asStr().?);
    try testing.expectEqual(@as(?[]const u8, null), (PropRef{ .index = 4 }).asStr());
    try testing.expectEqual(@as(usize, 4), (PropRef{ .index = 4 }).asIndex().?);
    try testing.expectEqual(@as(?usize, null), (PropRef{ .key = "k" }).asIndex());
}

test "a value ref is the object a make action produces, or the value" {
    try testing.expectEqual(
        ValueRef{ .object = .map },
        ValueRef.fromActionValue(.make_map, .null_value),
    );
    try testing.expectEqual(
        ValueRef{ .object = .list },
        ValueRef.fromActionValue(.make_list, .null_value),
    );
    try testing.expectEqual(
        ValueRef{ .object = .text },
        ValueRef.fromActionValue(.make_text, .null_value),
    );
    try testing.expectEqual(
        ValueRef{ .object = .table },
        ValueRef.fromActionValue(.make_table, .null_value),
    );

    const put: ScalarValue = .{ .str = "v" };
    // Every other action carries its value through unchanged, whatever the
    // value is (op_set2/types.rs:673).
    const others = [_]Action{ .set, .delete, .increment, .mark };
    inline for (others) |a| {
        const got = ValueRef.fromActionValue(a, put);
        try testing.expectEqual(@as(bool, false), got.isObject());
        try testing.expect(got.scalar.eql(put));
    }
    const makes = [_]Action{ .make_map, .make_list, .make_text, .make_table };
    inline for (makes) |a| {
        try testing.expect(ValueRef.fromActionValue(a, put).isObject());
    }

    const s = ValueRef.str("plain");
    try testing.expect(!s.isObject());
    try testing.expectEqualStrings("plain", s.scalar.str);
}

test "a value ref can be copied out of the storage it was read from" {
    const gpa = testing.allocator;
    const borrowed: ValueRef = .{ .scalar = .{ .unknown = .{
        .type_code = 12,
        .bytes = &[_]u8{ 1, 2, 3 },
    } } };

    var owned = try borrowed.intoOwned(gpa);
    defer owned.deinit(gpa);

    try testing.expect(owned.value.scalar.eql(borrowed.scalar));
    // The copy's bytes are its own, so the borrow may go.
    try testing.expect(owned.value.scalar.unknown.bytes.ptr != borrowed.scalar.unknown.bytes.ptr);
    try testing.expectEqual(@as(u8, 12), owned.value.scalar.unknown.type_code);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, owned.value.scalar.unknown.bytes);

    // A value with no slice in it allocates nothing.
    var num = try ValueRef.fromActionValue(.increment, .{ .int = 5 }).intoOwned(gpa);
    defer num.deinit(gpa);
    try testing.expectEqual(@as(i64, 5), num.value.scalar.int);

    // An object is not a scalar and has nothing to copy.
    var obj = try ValueRef.fromActionValue(.make_map, .null_value).intoOwned(gpa);
    defer obj.deinit(gpa);
    try testing.expectEqual(@as(bool, true), obj.value.isObject());
}

test "a scalar's raw form is the wire bytes of its type tag" {
    const gpa = testing.allocator;
    const Case = struct {
        v: ScalarValue,
        /// The bytes `v` occupies in the raw value column.
        want: []const u8,
        /// What the bytes read back as, which is `v` itself for every variant
        /// except an actor id: in the value column an actor id is an opaque
        /// byte payload and reads back as those bytes (`value.zig:148-149`).
        back: ScalarValue,
        /// The bytes `v` already holds, or null when it has none of its own.
        held: ?[]const u8,
    };
    const cases = [_]Case{
        .{
            .v = .null_value,
            .want = &.{},
            .back = .null_value,
            .held = null,
        },
        .{
            .v = .{ .bool_value = false },
            .want = &.{},
            .back = .{ .bool_value = false },
            .held = null,
        },
        .{
            .v = .{ .bool_value = true },
            .want = &.{},
            .back = .{ .bool_value = true },
            .held = null,
        },
        .{ .v = .{ .uint = 0 }, .want = &.{0x00}, .back = .{ .uint = 0 }, .held = null },
        .{ .v = .{ .uint = 127 }, .want = &.{0x7f}, .back = .{ .uint = 127 }, .held = null },
        .{
            .v = .{ .uint = 300 },
            .want = &.{ 0xac, 0x02 },
            .back = .{ .uint = 300 },
            .held = null,
        },
        .{ .v = .{ .int = 0 }, .want = &.{0x00}, .back = .{ .int = 0 }, .held = null },
        .{ .v = .{ .int = -1 }, .want = &.{0x7f}, .back = .{ .int = -1 }, .held = null },
        .{
            .v = .{ .int = 64 },
            .want = &.{ 0xc0, 0x00 },
            .back = .{ .int = 64 },
            .held = null,
        },
        .{ .v = .{ .int = -64 }, .want = &.{0x40}, .back = .{ .int = -64 }, .held = null },
        .{
            .v = .{ .int = -65 },
            .want = &.{ 0xbf, 0x7f },
            .back = .{ .int = -65 },
            .held = null,
        },
        .{
            .v = .{ .counter = .init(1000) },
            .want = &.{ 0xe8, 0x07 },
            .back = .{ .counter = .init(1000) },
            .held = null,
        },
        .{
            .v = .{ .timestamp = -1000 },
            .want = &.{ 0x98, 0x78 },
            .back = .{ .timestamp = -1000 },
            .held = null,
        },
        .{
            .v = .{ .float = 1.0 },
            .want = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f },
            .back = .{ .float = 1.0 },
            .held = null,
        },
        .{
            .v = .{ .float = -0.5 },
            .want = &.{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0xbf },
            .back = .{ .float = -0.5 },
            .held = null,
        },
        .{
            .v = .{ .str = "hi" },
            .want = "hi",
            .back = .{ .str = "hi" },
            .held = "hi",
        },
        .{
            .v = .{ .str = "" },
            .want = "",
            .back = .{ .str = "" },
            .held = "",
        },
        .{
            .v = .{ .bytes = &[_]u8{ 0, 255 } },
            .want = &[_]u8{ 0, 255 },
            .back = .{ .bytes = &[_]u8{ 0, 255 } },
            .held = &[_]u8{ 0, 255 },
        },
        .{
            .v = .{ .actor_id = .{ .bytes = "act" } },
            .want = "act",
            .back = .{ .bytes = "act" },
            .held = "act",
        },
        // An unknown value's bytes are preserved verbatim.
        .{
            .v = .{ .unknown = .{ .type_code = 12, .bytes = &[_]u8{ 0xde, 0xad } } },
            .want = &[_]u8{ 0xde, 0xad },
            .back = .{ .unknown = .{ .type_code = 12, .bytes = &[_]u8{ 0xde, 0xad } } },
            .held = &[_]u8{ 0xde, 0xad },
        },
    };

    for (cases) |c| {
        try testing.expectEqual(c.want.len, rawLen(c.v));

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try appendRaw(gpa, &out, c.v);
        try testing.expectEqualSlices(u8, c.want, out.items);

        if (c.held) |h| {
            // A value that already holds its bytes hands them back as they
            // are, and they are the payload.
            try testing.expectEqualSlices(u8, c.want, asRaw(c.v).?);
            try testing.expectEqualSlices(u8, h, asRaw(c.v).?);
        } else {
            try testing.expectEqual(@as(?[]const u8, null), asRaw(c.v));
        }

        const got = try fromRaw(metaOf(c.v), out.items);
        try testing.expect(got.eql(c.back));
    }
}

test "a null and a boolean read their metadata word alone" {
    // op_set2/types.rs:320-322: the payload is not consulted, so bytes in
    // the raw column past a null or a boolean are stepped over by the column
    // reader and never looked at here.
    try testing.expect(try fromRaw(ValueMeta.init(.null_value, 0), "") == .null_value);
    try testing.expect(try fromRaw(ValueMeta.init(.null_value, 0), &[_]u8{9}) == .null_value);
    try testing.expect(!(try fromRaw(ValueMeta.init(.false_value, 0), &[_]u8{0xff})).bool_value);
    try testing.expect((try fromRaw(ValueMeta.init(.true_value, 0), &[_]u8{0xff})).bool_value);
    // And the metadata word itself says what they are.
    try testing.expectEqual(@as(u64, 0), metaOf(.null_value).raw);
    try testing.expectEqual(@as(u64, 1), metaOf(.{ .bool_value = false }).raw);
    try testing.expectEqual(@as(u64, 2), metaOf(.{ .bool_value = true }).raw);
}

test "an unknown type code below ten reads back as the tag it collides with" {
    // op_set2/meta.rs:88-90 writes the writer's code as it stands, and
    // op_set2/meta.rs:23-38 reads the low nibble as a defined tag whenever it
    // names one. Both are deliberate; the port keeps both.
    const v: ScalarValue = .{ .unknown = .{ .type_code = 3, .bytes = &[_]u8{0x05} } };
    try testing.expectEqual(@as(u64, (1 << 4) | 3), metaOf(v).raw);
    // One payload byte, which as an unsigned LEB128 is 5, not an unknown.
    const back = try fromRaw(metaOf(v), &[_]u8{0x05});
    try testing.expectEqual(@as(u64, 5), back.uint);

    // A code the format does not define survives.
    const future: ScalarValue = .{ .unknown = .{ .type_code = 12, .bytes = &[_]u8{ 1, 2 } } };
    const kept = try fromRaw(metaOf(future), &[_]u8{ 1, 2 });
    try testing.expectEqual(@as(u8, 12), kept.unknown.type_code);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2 }, kept.unknown.bytes);
}

test "reading a malformed payload is an error, not a value" {
    // A varint payload that is cut short.
    try testing.expectError(
        error.UnexpectedEnd,
        fromRaw(ValueMeta.init(.uleb, 2), &[_]u8{0x80}),
    );
    // A varint payload with a second number in it: the metadata word and the
    // raw column disagree, which the load path already refuses.
    try testing.expectError(
        error.InvalidValue,
        fromRaw(ValueMeta.init(.uleb, 2), &[_]u8{ 0x01, 0x02 }),
    );
    // A float that is not eight bytes.
    try testing.expectError(
        error.InvalidValueMeta,
        fromRaw(ValueMeta.init(.float, 4), &[_]u8{ 1, 2, 3, 4 }),
    );
    // A string that is not text.
    try testing.expectError(
        error.InvalidUtf8,
        fromRaw(ValueMeta.init(.string, 2), &[_]u8{ 0xff, 0xfe }),
    );
    // A counter and a timestamp are signed, and a truncated one is refused.
    try testing.expectError(
        error.UnexpectedEnd,
        fromRaw(ValueMeta.init(.counter, 4), &[_]u8{ 0x80, 0x80 }),
    );
    try testing.expectError(
        error.UnexpectedEnd,
        fromRaw(ValueMeta.init(.timestamp, 1), &[_]u8{0x80}),
    );
}

test "the actor column stores actor indices, with and without nulls" {
    const gpa = testing.allocator;
    const actors_in = [_]ActorIdx{ 0, 0, 0, 3, 1, 1, 7 };

    var actors = try ActorColumn.init(gpa);
    defer actors.deinit();
    try actors.extend(gpa, &actors_in);

    const bytes = try actors.encode(gpa);
    defer gpa.free(bytes);

    var back = try ActorColumn.load(gpa, bytes);
    defer back.deinit();
    const got = try back.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(ActorIdx, &actors_in, got);
    try testing.expectEqual(try actors.get(3), try back.get(3));
    try testing.expectEqual(@as(?ActorIdx, null), try back.get(got.len));

    // The nullable form: a null run rides in the run header and never in a
    // payload (`hexane/src/lib.rs:406-437`).
    const with_gaps = [_]?ActorIdx{ 2, null, null, 0, 4, null };
    var opt = try ActorColumnOption.init(gpa);
    defer opt.deinit();
    try opt.extend(gpa, &with_gaps);
    const opt_bytes = try opt.encode(gpa);
    defer gpa.free(opt_bytes);
    var opt_back = try ActorColumnOption.load(gpa, opt_bytes);
    defer opt_back.deinit();
    const opt_got = try opt_back.toSlice(gpa);
    defer gpa.free(opt_got);
    try testing.expectEqualSlices(?ActorIdx, &with_gaps, opt_got);
}

test "the action column stores action codes and refuses the rest" {
    const gpa = testing.allocator;
    const all = std.enums.values(Action);
    const codes = blk: {
        var buf: [all.len]u64 = undefined;
        for (all, 0..) |a, i| buf[i] = actionCode(a);
        break :blk buf;
    };

    var col = try ActionColumn.init(gpa);
    defer col.deinit();
    try col.extend(gpa, &codes);
    try validateActions(&col);

    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    var back = try ActionColumn.load(gpa, bytes);
    defer back.deinit();
    const got = try back.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &codes, got);
    for (got, all) |code, a| try testing.expectEqual(a, try actionFromCode(code));

    // The action column and an actor column are the same bytes for the same
    // numbers: both are one unsigned LEB128 per run, which is what makes
    // holding codes rather than actions lossless.
    const as_actors = blk: {
        var buf: [codes.len]ActorIdx = undefined;
        for (codes, 0..) |c, i| buf[i] = @intCast(c);
        break :blk buf;
    };
    var actors = try ActorColumn.init(gpa);
    defer actors.deinit();
    try actors.extend(gpa, &as_actors);
    const actor_bytes = try actors.encode(gpa);
    defer gpa.free(actor_bytes);
    try testing.expectEqualSlices(u8, bytes, actor_bytes);

    // A code no action names is refused when the column is checked and again
    // when the row is read, both as a ParseError.
    var bad = try ActionColumn.init(gpa);
    defer bad.deinit();
    try bad.extend(gpa, &[_]u64{ 1, 8, 1 });
    try testing.expectError(error.InvalidAction, validateActions(&bad));
    try testing.expectEqual(Action.set, try actionFromCode((try bad.get(0)).?));
    try testing.expectError(error.InvalidAction, actionFromCode((try bad.get(1)).?));
}

test "a run header is three bytes whatever the count says" {
    const gpa = testing.allocator;
    // A repeat run's count is a signed LEB128, and a three-byte header is the
    // most it ever costs, so a run can claim far more values than the slab
    // has bytes (rle.zig:59-68).
    const n1 = [_]ActorIdx{7} ** 1;
    const n2 = [_]ActorIdx{7} ** 2;
    const n63 = [_]ActorIdx{7} ** 63;
    const n64 = [_]ActorIdx{7} ** 64;
    const n8191 = [_]ActorIdx{7} ** 8191;
    const n8192 = [_]ActorIdx{7} ** 8192;
    try testing.expectEqual(@as(usize, 2), rle.Rle(ActorIdx).encodedSize(&n1));
    try testing.expectEqual(@as(usize, 2), rle.Rle(ActorIdx).encodedSize(&n2));
    try testing.expectEqual(@as(usize, 2), rle.Rle(ActorIdx).encodedSize(&n63));
    try testing.expectEqual(@as(usize, 3), rle.Rle(ActorIdx).encodedSize(&n64));
    try testing.expectEqual(@as(usize, 3), rle.Rle(ActorIdx).encodedSize(&n8191));
    try testing.expectEqual(@as(usize, 4), rle.Rle(ActorIdx).encodedSize(&n8192));
    try testing.expectEqual(@as(usize, 4), rle.Rle(ActorIdx).encodedSize(&n1 ** 16384));

    // 16384 copies of one action are four bytes: a three-byte header and a
    // one-byte payload, and the count is honoured.
    const many = [_]u64{actionCode(.mark)} ** 16384;
    try testing.expectEqual(@as(usize, 4), rle.Rle(u64).encodedSize(&many));

    var col = try ActionColumn.init(gpa);
    defer col.deinit();
    try col.extend(gpa, &many);
    const bytes = try col.encode(gpa);
    defer gpa.free(bytes);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x80, 0x80, 0x01, @intCast(actionCode(.mark)) },
        bytes,
    );

    var back = try ActionColumn.load(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 16384), back.len());
    const got = try back.toSlice(gpa);
    defer gpa.free(got);
    try testing.expectEqualSlices(u64, &many, got);

    // The other end of a run: one value is a one-element literal run, never
    // a repeat run (rle.zig:14-20).
    var one = try ActorColumn.init(gpa);
    defer one.deinit();
    try one.extend(gpa, &n1);
    const one_bytes = try one.encode(gpa);
    defer gpa.free(one_bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x07 }, one_bytes);

    // Two distinct values are a literal run of two.
    var two = try ActorColumn.init(gpa);
    defer two.deinit();
    try two.extend(gpa, &[_]ActorIdx{ 0, 1 });
    const two_bytes = try two.encode(gpa);
    defer gpa.free(two_bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x00, 0x01 }, two_bytes);
}

test "a counter round trips through the delta and prefix codecs" {
    // The op set stores counters, not actors, in its delta and prefix columns
    // (op_set2/columns.rs:19,23,25,27), and its per-successor increment is a
    // nullable delta (op_set2/op_set/op_iter.rs), so the three codec families
    // are checked on the same integer the actor column stores.
    const gpa = testing.allocator;
    const counters = [_]u32{ 0, 1, 1, 2, 9, 9, 9, 40, std.math.maxInt(u32) };

    var delta = try column.Column(u32, column.Delta(u32)).init(gpa);
    defer delta.deinit();
    try delta.extend(gpa, &counters);
    const delta_bytes = try delta.encode(gpa);
    defer gpa.free(delta_bytes);
    var delta_back = try column.Column(u32, column.Delta(u32)).load(gpa, delta_bytes);
    defer delta_back.deinit();
    const delta_got = try delta_back.toSlice(gpa);
    defer gpa.free(delta_got);
    try testing.expectEqualSlices(u32, &counters, delta_got);

    const lengths = [_]u32{ 0, 1, 1, 2, 9, 9, 9, 40, 1 };
    var prefix = try column.Column(u32, column.Prefix(u32)).init(gpa);
    defer prefix.deinit();
    try prefix.extend(gpa, &lengths);
    const prefix_bytes = try prefix.encode(gpa);
    defer gpa.free(prefix_bytes);
    var prefix_back = try column.Column(u32, column.Prefix(u32)).load(gpa, prefix_bytes);
    defer prefix_back.deinit();
    const prefix_got = try prefix_back.toSlice(gpa);
    defer gpa.free(prefix_got);
    try testing.expectEqualSlices(u32, &lengths, prefix_got);
    // A prefix column's index carries the sum as well as the count, which is
    // what makes a row's offset one lookup away.
    try testing.expectEqual(@as(i64, 0), try prefix_back.runningAt(0));
    try testing.expectEqual(@as(i64, 1), try prefix_back.runningAt(2));
    try testing.expectEqual(@as(i64, 72), try prefix_back.runningAt(lengths.len));

    // The nullable delta the op set's counter column uses (column.zig:944),
    // where an absent value leaves the running value alone.
    const with_gaps = [_]?u32{ 5, null, null, 7, null, 7 };
    var opt = try column.Column(?u32, column.DeltaOption).init(gpa);
    defer opt.deinit();
    try opt.extend(gpa, &with_gaps);
    const opt_bytes = try opt.encode(gpa);
    defer gpa.free(opt_bytes);
    var opt_back = try column.Column(?u32, column.DeltaOption).load(gpa, opt_bytes);
    defer opt_back.deinit();
    const opt_got = try opt_back.toSlice(gpa);
    defer gpa.free(opt_got);
    try testing.expectEqualSlices(?u32, &with_gaps, opt_got);
}

test "API parity value reference owned conversion survives source release" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.dupe(u8, &.{ 0, 255, 128 });
    var owned = try (ValueRef{ .scalar = .{ .bytes = bytes } }).intoValue(gpa);
    defer owned.deinit(gpa);
    gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 128 }, owned.value.scalar.bytes);
    var object = try (ValueRef{ .object = .text }).intoValue(gpa);
    defer object.deinit(gpa);
    try std.testing.expectEqual(types.ObjType.text, object.value.object);
}
