//! Column metadata: the `ColumnSpec` bitfield, the byte range one column
//! occupies, and `RawColumns`, a set of columns indexed into one data block.
//!
//! # The bitfield
//!
//! A column specification is a 32-bit value, `uLEB128`-encoded on the wire,
//! laid out as
//!
//! ```text
//! bits 31 .. 4 : column id
//! bit  3       : 1 when the column's bytes are DEFLATE compressed
//! bits  2 .. 0 : column encoding
//! ```
//!
//! Upstream builds it as `raw = id << 4 | encoding;` and then sets
//! `raw |= 0b0000_1000` for a compressed column
//! (`storage/columns/column_specification.rs:21-29`), and reads the encoding
//! back with `val & 0b0000_0111` (`:142-143`), so the encoding is three bits
//! and the DEFLATE flag is the fourth least significant bit. The two never
//! overlap. The published format specification says the same: "The least
//! significant three bits encode the column type. The 4th least significant
//! bit is 1 if the column is DEFLATE compressed. The remaining bits are the
//! column ID" (<https://automerge.org/automerge-binary-format-spec/#_column_specification>).
//!
//! Nothing here may be "tidied": the numbers are the format. Upstream's own
//! test vectors (`column_specification.rs:227-268`), the specification's
//! change and operation column tables, and the reference corpus all agree,
//! and the tests below pin them as literals. For a second, independent
//! witness, the operations metadata block of
//! `rust/benchmark-battery/data/moby-dick.automerge` decodes to
//!
//! ```text
//! 0x01 0x02 0x11 0x13 0x15 0x21 0x23 0x34 0x42 0x5e 0x5f 0x80 0x81 0x83
//! ```
//!
//! where `0x5e` is value metadata (`5 << 4 | 6`) with the DEFLATE bit set and
//! `0x80` is the successor group column.
//!
//! # Ordering and equality ignore the DEFLATE bit
//!
//! A deflated column and its inflated twin are the same column, so `eql` and
//! `compare` — and every sort, search, and duplicate check built on them —
//! work on `normalize()`, the spec with the DEFLATE bit masked off
//! (`column_specification.rs:14-17`, `:84-86`). This is not optional: the
//! format forbids a document from carrying both an inflated and a deflated
//! column with the same id and encoding, so a set that distinguished them
//! could describe a document that cannot exist. Upstream's `RawColumns::parse`
//! rejects an unsorted set (`raw_column.rs:248-253`, `:289-297`) and its
//! `bytes` lookup binary-searches on the normalized comparison
//! (`:275-282`); the same two rules are `RawColumns.validate` and
//! `RawColumns.findSpec` here.
//!
//! Zig has no operator overloading, and a struct has no `==` at all: two
//! specs are the same 32 bits when `a.raw == b.raw`, and the same column when
//! `eql(a, b)` holds. A caller that writes `a == b` gets a compile error
//! rather than a wrong answer, which is one reason `eql` exists; a hash map
//! keyed by `ColumnSpec` must normalize first, because `eql` ignores the bit
//! that `raw` keeps.

const std = @import("std");
const err = @import("../error.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;

/// The encoding of a column: what the bytes in the column's range decode to.
///
/// The tag is the low three bits of a `ColumnSpec`, and every value in that
/// field is one of these eight. Upstream calls the same eight values
/// `ColumnType` (`column_specification.rs:129-138`); the specification calls
/// them the column types, and both are listed below with the codec each one
/// selects.
///
/// There is no richer tag space. The field is three bits wide, so the fourth
/// low-nibble bit of a whole spec belongs to the DEFLATE flag rather than to
/// a ninth encoding, and upstream reads the field with `val & 0b0000_0111`
/// (`column_specification.rs:142-143`). In particular there is no separate
/// spec for a run-length column over absent values, over signed or unsigned
/// values, nor for raw bytes: a field that may be absent is one column whose
/// RLE stream carries nulls (`columnar/column_range/key.rs:250-266` writes a
/// string key as a null actor and a null counter), and an opaque payload is a
/// value column.
pub const Encoding = enum(u8) {
    /// Tag 0. A group column: one run-length encoded count per row, counting
    /// the members of the group. Specification: Group Column. Upstream:
    /// `ColumnType::Group`.
    group = 0,
    /// Tag 1. A run-length encoded column of uLEB values indexing the actor
    /// table. Specification: Actor Column. Upstream: `ColumnType::Actor`.
    actor = 1,
    /// Tag 2. A run-length encoded column of uLEB values.
    /// Specification: uLEB Column. Upstream: `ColumnType::Integer`.
    rle_uint = 2,
    /// Tag 3. A run-length encoded column of signed deltas, each the
    /// difference from the previous value. Specification: Delta Column.
    /// Upstream: `ColumnType::DeltaInteger`.
    delta = 3,
    /// Tag 4. A bit-packed column of booleans, least significant bit first.
    /// Specification: Boolean Column. Upstream: `ColumnType::Boolean`.
    boolean = 4,
    /// Tag 5. A run-length encoded column of length-prefixed UTF-8 strings.
    /// Specification: String Column. Upstream: `ColumnType::String`.
    string = 5,
    /// Tag 6. The metadata word of a value column: type code, length
    /// bookkeeping, and the run headers. Specification: Value Metadata
    /// Column. Upstream: `ColumnType::ValueMetadata`.
    value_metadata = 6,
    /// Tag 7. The payload of a value column, read according to the sibling
    /// metadata column with the same id. Specification: Value Column.
    /// Upstream: `ColumnType::Value`.
    value = 7,

    /// The encoding with the tag `t`, or `error.InvalidEncoding` when `t` is
    /// not one of the eight defined tags. Nothing is consumed and nothing is
    /// allocated; `t` is a value, so a caller reading it off the wire keeps
    /// the cursor where it was.
    ///
    /// This reads a bare tag byte. A caller holding a whole specification
    /// reads its tag with [`ColumnSpec.encoding`], which masks the bit out and
    /// cannot fail. A bare tag wider than three bits is refused here rather
    /// than masked, so `fromTag(8)` is `error.InvalidEncoding` while
    /// `ColumnSpec.fromRaw(8).encoding()` is `.group`.
    pub fn fromTag(t: u8) ParseError!Encoding {
        return switch (t) {
            0 => .group,
            1 => .actor,
            2 => .rle_uint,
            3 => .delta,
            4 => .boolean,
            5 => .string,
            6 => .value_metadata,
            7 => .value,
            else => error.InvalidEncoding,
        };
    }
};

/// A packed column specification: an id, an encoding, and a DEFLATE flag.
///
/// `raw` is the 32-bit value as it stands before the `uLEB128` encoding
/// applied on the wire. Build one with [`ColumnSpec.make`] for a value the
/// caller checked, or with [`ColumnSpec.fromRaw`] for one just read off the
/// wire.
///
/// The struct is two fields by value, so it is freely copyable and owns
/// nothing: a copy is the same column, not a second owner of anything. The
/// id an unchecked build can hold is bounded by construction — `raw` is 32
/// bits and the id is its top 28 — so [`ColumnSpec.id`] cannot exceed
/// [`ColumnSpec.max_id`] for any `raw` at all, including one read from a
/// hostile document. Only [`ColumnSpec.make`] takes an id as a separate
/// argument, and that is where the precondition lives.
pub const ColumnSpec = struct {
    /// The packed bitfield, exactly as it appears before `uLEB128` encoding:
    /// bits 31..4 the column id, bit 3 the DEFLATE flag, bits 2..0 the
    /// encoding. Every accessor below reads it rather than the fields, so
    /// two specs are the same column when [`ColumnSpec.normalize`] gives them
    /// the same `raw`.
    raw: u32,

    /// Bits 0..2: the column encoding. Three bits, per
    /// `column_specification.rs:142-143`.
    pub const encoding_mask: u32 = 0b0000_0111;
    /// Bit 3: the column's bytes are a raw DEFLATE stream, per
    /// `column_specification.rs:25-27`.
    pub const deflate_mask: u32 = 0b0000_1000;
    /// Every bit but bit 3, so a spec with the DEFLATE bit cleared.
    ///
    /// Upstream writes this mask as the eight-bit literal `0b11110111`
    /// (`column_specification.rs:27-28` and `:84-86`), which Rust widens to
    /// `0x0000_00f7`. For every column this format defines — ids 0 to 10, so
    /// a spec below `0x800` — that is the same value as clearing bit 3 alone,
    /// and this port agrees with it there. It is not the same for a column id
    /// of 128 or more, where the eight-bit literal would discard the high
    /// bits of the id: `0x813` would normalize to `0x013`, that is, to a
    /// different column's id. The rule the format states is "the 4th least
    /// significant bit is 1 if the column is DEFLATE compressed", so this
    /// port masks the whole word and keeps ids that upstream would mangle.
    pub const normalize_mask: u32 = 0b1111_1111_1111_1111_1111_1111_1111_0111;
    /// The largest column id that fits: the 28 bits above the low nibble.
    pub const max_id: u32 = 0x0fff_ffff;

    /// A specification for the column `col_id` with encoding `enc`, flagged
    /// compressed when `compressed` is true.
    ///
    /// `col_id` must fit the 28 id bits, that is, be at most [`max_id`]. This
    /// is a caller precondition, not something the function checks for you:
    /// `std.debug.assert` is compiled out in `ReleaseFast` and `ReleaseSmall`,
    /// and `col_id << 4` there is an unsigned shift that discards the high
    /// bits. An unchecked build therefore does not report an over-range id at
    /// all — it silently packs a **different** column, one whose id is
    /// `col_id & max_id`, so the column is looked up under a name the caller
    /// never wrote.
    ///
    /// A caller holding an id that came off the wire cannot use
    /// [`ColumnSpec.fromRaw`] to be safe instead, because it cannot be unsafe:
    /// `ColumnSpec.id` is `raw >> 4`, so the largest id any `u32` can carry is
    /// exactly [`max_id`] and no value read off the wire is ever out of range.
    /// The check belongs at the point the id is produced — before the cast to
    /// `u32` where the wire value is wider, and before this call where it is
    /// not.
    ///
    /// The parameter is not named `id` because Zig rejects a parameter that
    /// shadows the `id` declaration in this struct, and the call site is
    /// unaffected.
    pub fn make(col_id: u32, enc: Encoding, compressed: bool) ColumnSpec {
        std.debug.assert(col_id <= max_id);
        var raw: u32 = (col_id << 4) | @as(u32, @backingInt(enc));
        // Upstream clears the bit explicitly rather than leaving it alone
        // (`:27-28`), so `make` is a function of its three arguments only.
        raw = if (compressed) raw | deflate_mask else raw & normalize_mask;
        return .{ .raw = raw };
    }

    /// The specification exactly as it was read, DEFLATE flag and all. The
    /// port of `impl From<u32> for ColumnSpec` (`column_specification.rs:197-201`).
    pub fn fromRaw(raw: u32) ColumnSpec {
        return .{ .raw = raw };
    }

    /// The column id: the 28 bits above the low nibble
    /// (`column_specification.rs:68-70`).
    pub fn id(self: ColumnSpec) u32 {
        return self.raw >> 4;
    }

    /// The encoding tag.
    ///
    /// The mask leaves one of the eight values `Encoding` declares, so this
    /// cannot fail: the `?` is how that is checked. If the mask ever stopped
    /// guaranteeing a declared tag, a safe build would trap here instead of
    /// inventing an encoding.
    pub fn encoding(self: ColumnSpec) Encoding {
        return std.enums.fromInt(Encoding, @as(u8, @truncate(self.raw & encoding_mask))).?;
    }

    /// Whether the column's bytes are a DEFLATE stream that must be inflated
    /// before decoding (`column_specification.rs:72-74`).
    pub fn isCompressed(self: ColumnSpec) bool {
        return self.raw & deflate_mask != 0;
    }

    /// The same column with the DEFLATE bit cleared
    /// (`column_specification.rs:84-86`). Two specifications that normalize
    /// to the same value are the same column.
    pub fn normalize(self: ColumnSpec) ColumnSpec {
        return .{ .raw = self.raw & normalize_mask };
    }

    /// Whether two specifications name the same column: same id, same
    /// encoding, with the DEFLATE bit ignored.
    ///
    /// This is the comparison upstream's `Ord` uses
    /// (`column_specification.rs:14-17`) and the one a lookup needs. It is not
    /// a comparison of the raw bitfields: `a.raw == b.raw` is "the same 32
    /// bits", which is a different and much stricter question.
    pub fn eql(a: ColumnSpec, b: ColumnSpec) bool {
        return (a.raw & normalize_mask) == (b.raw & normalize_mask);
    }

    /// Orders two specifications by their normalized form. Because the id
    /// occupies the high 28 bits this is primarily an ordering by id, and a
    /// set is sorted when it is ascending under this comparison.
    pub fn compare(a: ColumnSpec, b: ColumnSpec) std.math.Order {
        return std.math.order(a.raw & normalize_mask, b.raw & normalize_mask);
    }

    /// `compare(a, b) == .lt`. The predicate a sort needs.
    pub fn lessThan(a: ColumnSpec, b: ColumnSpec) bool {
        return a.compare(b) == .lt;
    }

    /// The same column, marked compressed (`column_specification.rs:76-78`).
    /// The id came out of an existing spec, so it is in range and
    /// [`ColumnSpec.make`]'s precondition holds.
    pub fn deflated(self: ColumnSpec) ColumnSpec {
        return make(self.id(), self.encoding(), true);
    }

    /// The same column, marked uncompressed (`column_specification.rs:80-82`).
    /// The id came out of an existing spec, so it is in range and
    /// [`ColumnSpec.make`]'s precondition holds.
    pub fn inflated(self: ColumnSpec) ColumnSpec {
        return make(self.id(), self.encoding(), false);
    }
};

/// A half-open byte range `[start, end)` inside a column data block.
///
/// The range is relative to the start of the data block, not to the start of
/// the chunk: the first column of a set starts at 0
/// (`raw_column.rs:24-26`).
///
/// Two fields by value, so a range is freely copyable and owns nothing: it
/// names bytes in a buffer somebody else holds, and outlives neither a
/// mutation of that buffer nor the set that indexed it. A range read off the
/// wire can be nonsense — `end` below `start`, or past the block — and every
/// accessor here treats that as empty or out of bounds rather than
/// trapping, so a caller may build one from input and check it afterwards
/// with [`ColumnRange.fitsIn`] or [`ColumnRange.slice`].
pub const ColumnRange = struct {
    /// The first byte of the column within the data block.
    start: usize,
    /// One past the last byte of the column within the data block. Nothing
    /// requires `end >= start`: a range with `end` below `start` is empty,
    /// which is how an unvalidated caller-supplied pair is treated.
    end: usize,

    /// The range `[start, end)`.
    pub fn init(start: usize, end: usize) ColumnRange {
        return .{ .start = start, .end = end };
    }

    /// The empty range at the start of the data block.
    pub fn empty() ColumnRange {
        return init(0, 0);
    }

    /// The number of bytes the range covers. A range whose end is not past
    /// its start is empty, which is how a caller-supplied pair is treated
    /// before it has been validated. Never wraps, because the subtraction
    /// only runs when the end is larger.
    pub fn len(self: ColumnRange) usize {
        return if (self.end <= self.start) 0 else self.end - self.start;
    }

    /// Whether the range covers no bytes. Upstream's `Range::is_empty`
    /// (`raw_column.rs:41`), the test that drops a column from a set.
    pub fn isEmpty(self: ColumnRange) bool {
        return self.len() == 0;
    }

    /// Whether the range is a well-formed `[start, end)` inside a data block
    /// of `total` bytes: `start <= end <= total`. This is the check
    /// [`RawColumns.validate`] makes per column.
    pub fn fitsIn(self: ColumnRange, total: usize) bool {
        return self.start <= self.end and self.end <= total;
    }

    /// The bytes of `data` this range covers, or `error.ColumnOutOfBounds`
    /// when the range does not fit. Never panics on a range from input,
    /// because the bounds are checked before the slice is taken. The result
    /// borrows `data`, so it is valid exactly as long as that buffer is.
    pub fn slice(self: ColumnRange, data: []const u8) ParseError![]const u8 {
        if (!self.fitsIn(data.len)) return error.ColumnOutOfBounds;
        return data[self.start..self.end];
    }

    /// Whether two ranges cover the same bytes. Unlike [`ColumnSpec.eql`],
    /// this compares the raw offsets, so a deflated column and its inflated
    /// twin are the same range either way — the DEFLATE bit is not in here.
    pub fn eql(a: ColumnRange, b: ColumnRange) bool {
        return a.start == b.start and a.end == b.end;
    }
};

/// One column: its specification, and the bytes it occupies in the data
/// block.
///
/// This is upstream's `RawColumn` (`raw_column.rs:21-29`) without the
/// typestate parameter that tracks whether a column is known to be
/// uncompressed; here the DEFLATE flag lives in the spec, and it is up to the
/// caller to inflate a compressed column before reading it.
///
/// Two fields by value, so a column is freely copyable and owns nothing. It
/// names bytes in a data block somebody else holds: the bytes themselves come
/// from [`RawColumn.bytes`] against that block, and a copy does not outlive
/// it.
pub const RawColumn = struct {
    /// What the column is and how its bytes are encoded. The spec carries the
    /// DEFLATE flag, so a compressed column is identified here rather than
    /// by a separate flag on the column.
    spec: ColumnSpec,
    /// Where the column's bytes are, within the data block. Offsets, not
    /// bytes: nothing is held until a caller asks for them with
    /// [`RawColumn.bytes`].
    range: ColumnRange,

    /// The column `spec`, whose bytes are `range` of the data block.
    pub fn init(spec: ColumnSpec, range: ColumnRange) RawColumn {
        return .{ .spec = spec, .range = range };
    }

    /// The column `spec` only if it carries bytes, and null when it does
    /// not.
    ///
    /// A column with an empty range is not part of a set at all: upstream
    /// drops it in `try_new` (`raw_column.rs:40-50`) and in both
    /// `FromIterator` implementations (`:183`, `:187-205`), so an absent
    /// column costs no bytes and appears nowhere in the metadata. A `null`
    /// here is not an error: it means the caller asked for a column that
    /// carries nothing.
    pub fn tryInit(spec: ColumnSpec, range: ColumnRange) ?RawColumn {
        if (range.isEmpty()) return null;
        return init(spec, range);
    }

    /// The column id. Shorthand for `spec.id()`.
    pub fn id(self: RawColumn) u32 {
        return self.spec.id();
    }

    /// Whether the column's bytes are a DEFLATE stream.
    pub fn isCompressed(self: RawColumn) bool {
        return self.spec.isCompressed();
    }

    /// The number of bytes the column occupies.
    pub fn len(self: RawColumn) usize {
        return self.range.len();
    }

    /// Whether the column occupies no bytes.
    pub fn isEmpty(self: RawColumn) bool {
        return self.range.isEmpty();
    }

    /// The column's bytes, or `error.ColumnOutOfBounds` when its range does
    /// not fit `data`. The result borrows `data`, and for a compressed column
    /// it is still the raw DEFLATE stream — inflating it is the caller's
    /// step, and `decompressRaw` in `chunk.zig` is what this crate uses.
    pub fn bytes(self: RawColumn, data: []const u8) ParseError![]const u8 {
        return self.range.slice(data);
    }
};

/// One entry of a column metadata block: a specification and the length in
/// bytes of that column's data.
///
/// This is the `(ColumnSpec, usize)` pair the format stores for each column
/// and that upstream's `FromIterator` consumes
/// (`raw_column.rs:187-205`).
///
/// A descriptor is a value, not a view: it names a length and a spec and
/// holds no bytes, so a caller may build a list of them and hand it to
/// [`RawColumns.init`] without anything to keep alive. `len` is exactly the
/// kind of number that came off the wire, and [`RawColumns.init`] sums them
/// with a saturating add for that reason.
pub const ColumnDesc = struct {
    /// What the column is and how its bytes are encoded.
    spec: ColumnSpec,
    /// The length in bytes of the column's data. From the wire, so a hostile
    /// document can make this absurd; nothing here trusts it.
    len: usize,

    /// The metadata entry for column `spec` whose data is `len` bytes long.
    /// `len` is not checked here; it is bounded by
    /// [`RawColumns.validate`] and by the data block it is measured against.
    pub fn init(spec: ColumnSpec, len: usize) ColumnDesc {
        return .{ .spec = spec, .len = len };
    }
};

/// A set of columns: what each one is, where its bytes are, and the block
/// those bytes live in.
///
/// The set is the unit the format calls column metadata plus column data
/// ([specification](https://automerge.org/automerge-binary-format-spec/#_column_metadata)):
/// a count, then one `(spec, length)` pair per column, then the columns'
/// bytes back to back. The ranges here are cumulative offsets from zero into
/// that data block, computed from the lengths in that order, exactly as
/// `RawColumns::parse` computes them (`raw_column.rs:232-247`).
///
/// Invariants, all of which `validate` checks:
///
/// * every column's spec is unique, ignoring the DEFLATE bit;
/// * the columns are in ascending order by normalized spec, so primarily by
///   id and then by encoding within one id;
/// * every range fits the data block;
/// * no column is empty, because an empty one is dropped at construction.
///
/// Two columns sharing an id is *not* a violation: one logical group column
/// is several columns with the same id and different encodings — the
/// predecessor group is a `group`, an `actor` and a `delta` column, all with
/// id 7. What may not repeat is the pair of id and encoding.
///
/// The caller owns `columns` and releases it with
/// [`RawColumns.deinit`], exactly once; `data` is borrowed and stays with
/// whoever allocated it. The set is a plain struct, so a copy duplicates the
/// `columns` pointer: deinitializing both copies frees the same bytes twice.
/// Copy a `RawColumns` only to hand it around, never to give two owners of
/// the list, and deinitialize exactly one of them.
pub const RawColumns = struct {
    /// The columns, in ascending order by normalized spec, none of them
    /// empty. `columns[i].range.start` is the cumulative offset of the
    /// column into `data`.
    ///
    /// This slice is owned by the `RawColumns` and freed by
    /// [`RawColumns.deinit`]; a caller must not free it separately or append
    /// to it. The [`RawColumn`]s inside hold specs and ranges by value, so
    /// the list owns no pointers into anything else.
    columns: []RawColumn,
    /// The block the ranges index into. Borrowed, never copied, and not
    /// released by [`RawColumns.deinit`]: the buffer outlives the set, and
    /// every byte a caller reads through [`RawColumns.bytesFor`] points into
    /// it.
    data: []const u8,

    /// The metadata entries `descs` describe as the columns of the data block
    /// `data`, which the caller owns.
    ///
    /// Offsets are cumulative from zero and advance by each entry's length
    /// (`raw_column.rs:232-247`); the sum is computed with a saturating add
    /// because the lengths came off the wire, so a hostile length cannot wrap
    /// into a small offset that would then pass the bounds check
    /// (`raw_column.rs:235-239`). An entry of length zero is dropped and
    /// contributes no bytes, as in `FromIterator`
    /// (`raw_column.rs:183`, `:187-205`).
    ///
    /// The caller owns the returned set and releases it with
    /// [`RawColumns.deinit`] exactly once. The only error is
    /// `error.OutOfMemory`, from the list; nothing in `descs` can be refused
    /// here, because a length off the wire is only summed here and judged by
    /// `validate`. On that error the list is freed and nothing is returned.
    ///
    /// The set is not validated here: order, uniqueness, and the bounds of
    /// the ranges are `validate`'s job, and a caller that has just built a
    /// set from a document chunk should call it before reading anything.
    /// Nothing is copied out of `data`, and `descs` is only read.
    pub fn init(gpa: Allocator, descs: []const ColumnDesc, data: []const u8) ParseError!RawColumns {
        var list: std.ArrayList(RawColumn) = .empty;
        errdefer list.deinit(gpa);
        try list.ensureTotalCapacity(gpa, descs.len);
        var offset: usize = 0;
        for (descs) |desc| {
            const end = offset +| desc.len;
            if (desc.len != 0) {
                try list.append(gpa, .init(desc.spec, .init(offset, end)));
            }
            offset = end;
        }
        return .{ .columns = try list.toOwnedSlice(gpa), .data = data };
    }

    /// Releases the column list. The data block belongs to the caller.
    ///
    /// Called once. The receiver is by value and `columns` is a plain pointer,
    /// so a copied `RawColumns` reaches the same allocation through
    /// [`RawColumns.deinit`] twice and frees it twice. After it runs, this
    /// value and every copy of it are spent: `len`, `iterator`, `find` and
    /// `bytesFor` all read through the freed slice, and `data` is left as it
    /// was — still borrowed, still the caller's to release.
    pub fn deinit(self: RawColumns, gpa: Allocator) void {
        gpa.free(self.columns);
    }

    /// The number of columns in the set.
    pub fn len(self: RawColumns) usize {
        return self.columns.len;
    }

    /// Whether the set holds no columns. A set whose every column was empty
    /// is empty, and its data block is then unread.
    pub fn isEmpty(self: RawColumns) bool {
        return self.columns.len == 0;
    }

    /// The total number of bytes the columns occupy. Upstream's
    /// `total_column_len` (`raw_column.rs:267-270`), which is the length of
    /// the data block this set is expected to index.
    ///
    /// The sum saturates, so a set built from hostile lengths can report a
    /// total larger than `data.len` rather than wrapping into a small one.
    /// [`RawColumns.totalLen`] is a measurement, not a bound: whether the
    /// columns really fit is [`RawColumns.validate`]'s answer.
    pub fn totalLen(self: RawColumns) usize {
        var total: usize = 0;
        for (self.columns) |col| total = total +| col.len();
        return total;
    }

    /// Whether no column is compressed, so the data block can be decoded
    /// without inflating anything. Upstream's `uncompressed`
    /// (`raw_column.rs:110-120`).
    pub fn allUncompressed(self: RawColumns) bool {
        for (self.columns) |col| {
            if (col.isCompressed()) return false;
        }
        return true;
    }

    /// The first column with the given id, or null when the set holds none.
    ///
    /// A binary search over the ids, which is sound because
    /// [`RawColumns.validate`] requires them to be in ascending order. A set
    /// that has not been validated may answer arbitrarily, but never traps.
    ///
    /// **The pointer borrows the set's own `columns` slice**, so it is
    /// invalid the moment [`RawColumns.deinit`] runs, and it is not stable
    /// across a reallocation of that list — which no method here performs,
    /// so within one set's lifetime the pointer stays put.
    pub fn find(self: RawColumns, id: u32) ?*const RawColumn {
        var lo: usize = 0;
        var hi: usize = self.columns.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.columns[mid].id() < id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.columns.len and self.columns[lo].id() == id) return &self.columns[lo];
        return null;
    }

    /// The column with the given specification, or null when the set holds
    /// none. A compressed column is found by its uncompressed specification
    /// and the other way round, because the comparison is on the normalized
    /// forms — upstream's `RawColumns::bytes` lookup
    /// (`raw_column.rs:275-282`).
    ///
    /// The same lifetime rules as [`RawColumns.find`]: the pointer borrows
    /// `columns`, so [`RawColumns.deinit`] invalidates it. A lookup on an
    /// unvalidated set may answer arbitrarily, but never traps.
    pub fn findSpec(self: RawColumns, spec: ColumnSpec) ?*const RawColumn {
        var lo: usize = 0;
        var hi: usize = self.columns.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.columns[mid].spec.compare(spec) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.columns.len and self.columns[lo].spec.eql(spec)) return &self.columns[lo];
        return null;
    }

    /// The bytes of the column with the given specification, `null` when the
    /// set holds no such column, and `error.ColumnOutOfBounds` when the
    /// column's range does not fit the data block.
    ///
    /// The two empty answers are different questions: `null` is "this set has
    /// no such column", which is not a defect in the document, while
    /// `error.ColumnOutOfBounds` is a declared range the block cannot
    /// honour. The returned bytes borrow `data` — not `columns` — so they
    /// stay valid after [`RawColumns.deinit`] for as long as the caller
    /// keeps the data block.
    pub fn bytesFor(self: RawColumns, spec: ColumnSpec) ParseError!?[]const u8 {
        const col = self.findSpec(spec) orelse return null;
        return try col.bytes(self.data);
    }

    /// Every column, in the order the metadata block listed them. The
    /// iterator borrows `columns`, so it is spent by
    /// [`RawColumns.deinit`] like the pointer [`RawColumns.find`] returns.
    pub fn iterator(self: RawColumns) Iterator {
        return .{ .columns = self.columns, .index = 0 };
    }

    /// Walks the columns of a set in metadata order.
    ///
    /// A cursor by value over a borrowed slice: it owns nothing and has no
    /// `deinit`. What it hands out are `*const RawColumn` pointers into the
    /// set's own list, valid until [`RawColumns.deinit`]. An iterator left
    /// unfinished simply drops on the floor; there is nothing to release.
    pub const Iterator = struct {
        columns: []const RawColumn,
        index: usize,

        /// The next column, or null once the set is exhausted. Calling it
        /// again after a null keeps returning null, and the pointer it
        /// returns borrows the set's `columns` slice.
        pub fn next(self: *Iterator) ?*const RawColumn {
            if (self.index >= self.columns.len) return null;
            defer self.index += 1;
            return &self.columns[self.index];
        }
    };

    /// Checks a set against the block it indexes and the columns the caller
    /// expects to find, and reports the first problem as a distinct error:
    ///
    /// * `error.Overflow` — the set holds more columns than the data block has
    ///   bytes. An empty column is dropped, so every column of a set occupies
    ///   at least one byte and a larger set is not one this format could have
    ///   written. This is the cheapest check and runs first, before any range
    ///   is indexed.
    /// * `error.ColumnOutOfBounds` — a range is not a `[start, end)` inside
    ///   the data block. Upstream checks this where the layout is built
    ///   (`columns.rs:351-355`).
    /// * `error.DuplicateColumn` — two columns have the same id and encoding.
    ///   Upstream rejects a duplicate spec in `add_column`
    ///   (`columns.rs:203-210`); the DEFLATE bit is ignored, so a document
    ///   that carries the same column both compressed and uncompressed is
    ///   rejected, as the specification requires.
    /// * `error.InvalidColumnSpec` — the specs are not in ascending order.
    ///   Upstream's `NotInNormalOrder` (`raw_column.rs:248-253`, `:289-297`).
    /// * `error.MissingColumn` — `declared` is not null and the column's spec
    ///   is none of it: the column the caller expects is not in the block
    ///   under the encoding it must have. A null `declared` skips this check
    ///   and leaves only the structural ones.
    ///
    /// Contiguity of the ranges is not checked: `init` produces ranges that
    /// cover the block exactly, and a caller that assembles ranges by hand is
    /// responsible for the gaps. The layer above this one does check
    /// contiguity, for the logical columns rather than the raw ones
    /// (`columns.rs:322-350`).
    ///
    /// What `validate` deliberately cannot report is an out-of-range column
    /// id: an id is `raw >> 4`, so a spec read off the wire is in range by
    /// construction and no `u32` can name a column beyond
    /// [`ColumnSpec.max_id`]. The check that matters is at the point an id
    /// becomes a `u32` — [`ColumnSpec.make`]'s precondition — and a caller
    /// that skipped it in a release build has already lost the id, not a
    /// validation this function could recover.
    ///
    /// `declared` is only read, and on any error the set is unchanged: this
    /// validates, it does not repair or reorder.
    pub fn validate(self: RawColumns, declared: ?[]const ColumnSpec) ParseError!void {
        if (self.columns.len > self.data.len) return error.Overflow;
        var previous: ?ColumnSpec = null;
        for (self.columns) |col| {
            if (!col.range.fitsIn(self.data.len)) return error.ColumnOutOfBounds;
            if (previous) |prev| {
                if (col.spec.eql(prev)) return error.DuplicateColumn;
                if (col.spec.compare(prev) == .lt) return error.InvalidColumnSpec;
            }
            if (declared) |expected| {
                if (!containsSpec(expected, col.spec)) return error.MissingColumn;
            }
            previous = col.spec;
        }
    }
};

/// Whether `spec` is one of `declared`, comparing normalized forms. The
/// declared set is a handful of entries, so a scan beats a map and keeps the
/// comparison rule in one place.
fn containsSpec(declared: []const ColumnSpec, spec: ColumnSpec) bool {
    for (declared) |candidate| {
        if (candidate.eql(spec)) return true;
    }
    return false;
}

const testing = std.testing;

test "a spec packs the id, the encoding and the deflate bit into one u32" {
    // Upstream's own vectors (`column_specification.rs:227-268`) plus every
    // integer in the specification's change and operation column tables.
    const vectors = [_]struct { id: u32, enc: Encoding, raw: u32 }{
        // change: dependencies group, dependencies index, actor
        .{ .id = 4, .enc = .group, .raw = 64 },
        .{ .id = 4, .enc = .delta, .raw = 67 },
        .{ .id = 0, .enc = .actor, .raw = 1 },
        // change: sequence number, maxOp, time, message
        .{ .id = 0, .enc = .delta, .raw = 3 },
        .{ .id = 1, .enc = .delta, .raw = 19 },
        .{ .id = 2, .enc = .delta, .raw = 35 },
        .{ .id = 3, .enc = .string, .raw = 53 },
        // ops: obj actor, obj counter
        .{ .id = 0, .enc = .actor, .raw = 1 },
        .{ .id = 0, .enc = .rle_uint, .raw = 2 },
        // ops: key actor, key counter, key string
        .{ .id = 1, .enc = .actor, .raw = 17 },
        .{ .id = 1, .enc = .delta, .raw = 19 },
        .{ .id = 1, .enc = .string, .raw = 21 },
        // ops: id actor, id counter
        .{ .id = 2, .enc = .actor, .raw = 33 },
        .{ .id = 2, .enc = .delta, .raw = 35 },
        // ops: insert, action, value metadata, value
        .{ .id = 3, .enc = .boolean, .raw = 52 },
        .{ .id = 4, .enc = .rle_uint, .raw = 66 },
        .{ .id = 5, .enc = .value_metadata, .raw = 86 },
        .{ .id = 5, .enc = .value, .raw = 87 },
        // ops: predecessor group, predecessor actor, predecessor counter
        .{ .id = 7, .enc = .group, .raw = 112 },
        .{ .id = 7, .enc = .actor, .raw = 113 },
        .{ .id = 7, .enc = .delta, .raw = 115 },
        // ops: successor group, successor actor, successor counter
        .{ .id = 8, .enc = .group, .raw = 128 },
        .{ .id = 8, .enc = .actor, .raw = 129 },
        .{ .id = 8, .enc = .delta, .raw = 131 },
        // ops: mark expand, mark name
        .{ .id = 9, .enc = .boolean, .raw = 148 },
        .{ .id = 10, .enc = .string, .raw = 165 },
    };
    for (vectors) |v| {
        const spec = ColumnSpec.make(v.id, v.enc, false);
        try testing.expectEqual(v.raw, spec.raw);
        try testing.expectEqual(v.id, spec.id());
        try testing.expectEqual(v.enc, spec.encoding());
        try testing.expect(!spec.isCompressed());

        // The DEFLATE bit is bit 3 and nothing else: setting it adds 8 and
        // changes no other bit (`column_specification.rs:325-333`).
        const compressed = spec.deflated();
        try testing.expectEqual(v.raw | ColumnSpec.deflate_mask, compressed.raw);
        try testing.expect(compressed.isCompressed());
        try testing.expectEqual(spec.id(), compressed.id());
        try testing.expectEqual(spec.encoding(), compressed.encoding());
        try testing.expectEqual(spec, compressed.inflated());

        // And the same three parts read back out of the whole wire word.
        const wire = ColumnSpec.fromRaw(compressed.raw);
        try testing.expectEqual(v.id, wire.id());
        try testing.expectEqual(v.enc, wire.encoding());
        try testing.expect(wire.isCompressed());
    }
}

test "the encoding field is three bits wide and the deflate bit is the fourth" {
    try testing.expectEqual(@as(u32, 0b0000_0111), ColumnSpec.encoding_mask);
    try testing.expectEqual(@as(u32, 0b0000_1000), ColumnSpec.deflate_mask);
    try testing.expectEqual(@as(u32, 0xffff_fff7), ColumnSpec.normalize_mask);

    // A spec read off the wire decodes without a mask of its own: 0x5e is
    // value metadata with the DEFLATE bit, 0x5f is the value column with the
    // DEFLATE bit, and 0x80 is the successor group column. Those are the
    // bytes in the operations metadata of
    // rust/benchmark-battery/data/moby-dick.automerge.
    const value_meta = ColumnSpec.fromRaw(0x5e);
    try testing.expectEqual(@as(u32, 5), value_meta.id());
    try testing.expectEqual(Encoding.value_metadata, value_meta.encoding());
    try testing.expect(value_meta.isCompressed());
    try testing.expectEqual(@as(u32, 0x56), value_meta.normalize().raw);

    const value = ColumnSpec.fromRaw(0x5f);
    try testing.expectEqual(@as(u32, 5), value.id());
    try testing.expectEqual(Encoding.value, value.encoding());
    try testing.expect(value.isCompressed());

    const succ_group = ColumnSpec.fromRaw(0x80);
    try testing.expectEqual(@as(u32, 8), succ_group.id());
    try testing.expectEqual(Encoding.group, succ_group.encoding());
    try testing.expect(!succ_group.isCompressed());

    // The id is the 28 bits above the low nibble, so it survives the mask and
    // the largest id round trips. It also survives an id of 128 or more, where
    // upstream's eight-bit mask literal would cut the id down to its low
    // byte.
    const top = ColumnSpec.make(ColumnSpec.max_id, .value, false);
    try testing.expectEqual(ColumnSpec.max_id, top.id());
    try testing.expectEqual(Encoding.value, top.encoding());
    try testing.expectEqual(@as(u32, 0xffff_ffff), top.deflated().raw);
    try testing.expectEqual(@as(u32, 0xffff_fff7), top.normalize().raw);

    const high = ColumnSpec.fromRaw(0x80b);
    try testing.expectEqual(@as(u32, 128), high.id());
    try testing.expectEqual(Encoding.delta, high.encoding());
    try testing.expect(high.isCompressed());
    try testing.expectEqual(@as(u32, 0x803), high.normalize().raw);
    try testing.expectEqual(@as(u32, 128), high.normalize().id());
    // The inflated twin of that spec is one bit lower and still the same
    // column; upstream's eight-bit mask literal would reduce both to 0x03,
    // which is a group column with no id.
    try testing.expectEqual(@as(u32, 0x803), high.inflated().raw);
    try testing.expect(ColumnSpec.eql(high, high.inflated()));
    try testing.expect(high.compare(high.inflated()) == .eq);
    try testing.expectEqual(@as(u32, 0x03), high.raw & 0b1111_0111);
}

test "every encoding tag is one of eight and no two share a tag" {
    const expected = [_]Encoding{
        .group,   .actor,  .rle_uint,       .delta,
        .boolean, .string, .value_metadata, .value,
    };
    for (expected, 0..) |enc, tag| {
        try testing.expectEqual(enc, try Encoding.fromTag(@intCast(tag)));
        try testing.expectEqual(enc, std.enums.fromInt(Encoding, @as(u8, @intCast(tag))).?);
    }
    // The field cannot hold anything else, and the reader says so rather than
    // trapping: a byte with the DEFLATE bit or the id bits set is not a tag.
    try testing.expectError(error.InvalidEncoding, Encoding.fromTag(8));
    try testing.expectError(error.InvalidEncoding, Encoding.fromTag(0x5e));
    try testing.expectError(error.InvalidEncoding, Encoding.fromTag(0xff));
    try testing.expectEqual(@as(usize, 8), @typeInfo(Encoding).@"enum".field_names.len);
}

test "a deflated spec and its inflated twin are the same column" {
    const plain = ColumnSpec.make(1, .delta, false);
    const compressed = plain.deflated();

    // Before normalizing, the two are different 32-bit values ...
    try testing.expect(compressed.raw != plain.raw);
    // After normalizing they are one value, and `eql` says they are the same
    // column.
    try testing.expectEqual(plain.normalize().raw, compressed.normalize().raw);
    try testing.expectEqual(plain.raw, compressed.normalize().raw);
    try testing.expect(ColumnSpec.eql(plain, compressed));
    try testing.expect(ColumnSpec.eql(compressed, plain));
    try testing.expectEqual(std.math.Order.eq, plain.compare(compressed));
    try testing.expect(!ColumnSpec.lessThan(plain, compressed));
    try testing.expect(!ColumnSpec.lessThan(compressed, plain));

    // Ordering is by the normalized form, so a deflate flag cannot reorder a
    // set: the value column of id 5 sorts after the value metadata column of
    // id 5 whether or not either is compressed.
    const meta = ColumnSpec.make(5, .value_metadata, false);
    const val = ColumnSpec.make(5, .value, true);
    try testing.expect(meta.compare(val) == .lt);
    try testing.expect(val.compare(meta) == .gt);
    try testing.expect(ColumnSpec.make(5, .value, false).compare(val) == .eq);
}

test "a set is built from a spec list with cumulative offsets from zero" {
    const gpa = testing.allocator;
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), 3),
        ColumnDesc.init(ColumnSpec.make(5, .value, false), 3),
    };
    const data = "abcdefgh";

    const set = try RawColumns.init(gpa, &descs, data);
    defer set.deinit(gpa);

    try testing.expectEqual(@as(usize, 3), set.len());
    try testing.expect(!set.isEmpty());
    try testing.expectEqual(@as(usize, 8), set.totalLen());
    try testing.expect(set.allUncompressed());

    // Offsets are cumulative from zero, not from the start of the chunk.
    try testing.expect(ColumnRange.init(0, 2).eql(set.columns[0].range));
    try testing.expect(ColumnRange.init(2, 5).eql(set.columns[1].range));
    try testing.expect(ColumnRange.init(5, 8).eql(set.columns[2].range));
    try testing.expectEqual(@as(usize, 2), set.columns[0].len());
    try testing.expectEqual(@as(usize, 3), set.columns[2].len());

    // Each column's bytes are its own slice of the block.
    try testing.expectEqualStrings("ab", try set.columns[0].bytes(data));
    try testing.expectEqualStrings("cde", try set.columns[1].bytes(data));
    try testing.expectEqualStrings("fgh", try set.columns[2].bytes(data));
    try testing.expectEqualStrings("cde", (try set.bytesFor(ColumnSpec.make(1, .delta, false))).?);
    try testing.expectEqual(@as(?[]const u8, null), try set.bytesFor(ColumnSpec.make(3, .boolean, false)));

    // Iteration walks the metadata order.
    var it = set.iterator();
    var seen: usize = 0;
    while (it.next()) |col| : (seen += 1) {
        try testing.expectEqual(descs[seen].spec.raw, col.spec.raw);
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expectEqual(@as(?*const RawColumn, null), it.next());

    // A set that agrees with the columns it declares is valid.
    try set.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .delta, false),
        ColumnSpec.make(5, .value, false),
    });
}

test "an empty column is dropped and contributes no bytes" {
    const gpa = testing.allocator;
    // The middle column has no bytes at all, and the one after it still
    // starts where the one before it ended: a dropped column shifts nothing.
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 1),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), 0),
        ColumnDesc.init(ColumnSpec.make(2, .rle_uint, false), 3),
    };
    const set = try RawColumns.init(gpa, &descs, "abcd");
    defer set.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), set.len());
    try testing.expectEqual(@as(usize, 0), set.columns[0].id());
    try testing.expectEqual(@as(usize, 2), set.columns[1].id());
    try testing.expect(ColumnRange.init(0, 1).eql(set.columns[0].range));
    try testing.expect(ColumnRange.init(1, 4).eql(set.columns[1].range));
    try testing.expectEqualStrings("bcd", try set.columns[1].bytes("abcd"));
    // The dropped column is nowhere in the set, so it cannot be found.
    try testing.expectEqual(@as(?*const RawColumn, null), set.find(1));
    try testing.expectEqual(@as(?[]const u8, null), try set.bytesFor(ColumnSpec.make(1, .delta, false)));
    try testing.expectEqual(@as(usize, 4), set.totalLen());
    try set.validate(&.{ ColumnSpec.make(0, .actor, false), ColumnSpec.make(2, .rle_uint, false) });

    // A set whose every column is empty holds no columns and reads no bytes.
    const nothing = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 0),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), 0),
    };
    const empty = try RawColumns.init(gpa, &nothing, "wxyz");
    defer empty.deinit(gpa);
    try testing.expect(empty.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty.totalLen());
    try testing.expectEqual(@as(?*const RawColumn, null), empty.find(0));
    // No schema to check against, so only the structural checks run.
    try empty.validate(null);

    // `RawColumn.tryInit` is the same rule for a single column.
    try testing.expectEqual(@as(?RawColumn, null), RawColumn.tryInit(
        ColumnSpec.make(0, .actor, false),
        ColumnRange.init(4, 4),
    ));
    try testing.expect(RawColumn.tryInit(
        ColumnSpec.make(0, .actor, false),
        ColumnRange.init(4, 5),
    ) != null);
}

test "lookup finds a present column and refuses an absent one" {
    const gpa = testing.allocator;
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
        ColumnDesc.init(ColumnSpec.make(2, .rle_uint, false), 1),
        ColumnDesc.init(ColumnSpec.make(7, .delta, false), 1),
    };
    const set = try RawColumns.init(gpa, &descs, "xyz");
    defer set.deinit(gpa);

    // Two columns may share an id: one group column is several raw columns.
    // `find` answers with the first of them, so the second is reached by spec.
    try testing.expectEqual(@as(usize, 3), set.len());
    const actor = set.find(2).?;
    try testing.expectEqual(Encoding.actor, actor.spec.encoding());
    try testing.expectEqualStrings("x", try actor.bytes("xyz"));
    const counter = set.findSpec(ColumnSpec.make(2, .rle_uint, false)).?;
    try testing.expectEqual(Encoding.rle_uint, counter.spec.encoding());
    try testing.expectEqualStrings("y", try counter.bytes("xyz"));
    try testing.expectEqualStrings("z", try set.find(7).?.bytes("xyz"));

    // An id that is not in the set is absent, not a panic and not a
    // neighbouring column.
    for ([_]u32{ 0, 1, 3, 8, 0x0fff_ffff }) |id| {
        try testing.expectEqual(@as(?*const RawColumn, null), set.find(id));
    }

    // A compressed column is found by its uncompressed spec and the other way
    // round, because the search compares normalized specs.
    const deflated = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(5, .value_metadata, true), 1),
        ColumnDesc.init(ColumnSpec.make(5, .value, true), 1),
    };
    const compressed = try RawColumns.init(gpa, &deflated, "mn");
    defer compressed.deinit(gpa);
    try testing.expect(!compressed.allUncompressed());
    try testing.expectEqualStrings("n", (try compressed.bytesFor(ColumnSpec.make(5, .value, false))).?);
    try testing.expectEqualStrings("m", (try compressed.bytesFor(ColumnSpec.make(5, .value_metadata, true))).?);
    try testing.expectEqual(
        @as(Encoding, .value),
        compressed.findSpec(ColumnSpec.make(5, .value, false)).?.spec.encoding(),
    );
    try testing.expect(compressed.findSpec(ColumnSpec.make(5, .value, true)) != null);
}

test "validate rejects a duplicate column" {
    const gpa = testing.allocator;
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
    };
    const set = try RawColumns.init(gpa, &descs, "abcd");
    defer set.deinit(gpa);

    // Construction keeps both: dropping one would hide the fault, and the
    // format forbids the document rather than the reader.
    try testing.expectEqual(@as(usize, 2), set.len());
    try testing.expectError(error.DuplicateColumn, set.validate(&.{ColumnSpec.make(0, .actor, false)}));
}

test "validate rejects specs that are out of order" {
    const gpa = testing.allocator;
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(2, .rle_uint, false), 2),
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
    };
    const set = try RawColumns.init(gpa, &descs, "abcd");
    defer set.deinit(gpa);

    // Both specs are declared, so the ordering is the only fault left.
    try testing.expectError(error.InvalidColumnSpec, set.validate(&.{
        ColumnSpec.make(2, .rle_uint, false),
        ColumnSpec.make(0, .actor, false),
    }));
    // Without a schema the structural checks still run.
    try testing.expectError(error.InvalidColumnSpec, set.validate(null));

    // The same two columns in ascending order validate, which is what makes
    // the error about order and not about the specs themselves.
    const sorted = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(2, .rle_uint, false), 2),
    };
    const ok = try RawColumns.init(gpa, &sorted, "abcd");
    defer ok.deinit(gpa);
    try ok.validate(&.{ ColumnSpec.make(0, .actor, false), ColumnSpec.make(2, .rle_uint, false) });
    try ok.validate(null);
}

test "validate rejects a range that runs past the data block" {
    const gpa = testing.allocator;
    // The lengths come off the wire, so they may overstate the block: the
    // second column ends at 6 in a block of 4 bytes.
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 3),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), 3),
    };
    const set = try RawColumns.init(gpa, &descs, "abcd");
    defer set.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), set.len());
    try testing.expectError(error.ColumnOutOfBounds, set.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .delta, false),
    }));
    // Reading the column that does not fit is an error, not a slice panic.
    try testing.expectError(error.ColumnOutOfBounds, set.columns[1].bytes("abcd"));
    try testing.expectError(error.ColumnOutOfBounds, set.bytesFor(ColumnSpec.make(1, .delta, false)));
    // A length so large it would wrap the running offset still fails the
    // bounds check rather than indexing somewhere else.
    const overflow = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), std.math.maxInt(usize)),
    };
    const wrapped = try RawColumns.init(gpa, &overflow, "ab");
    defer wrapped.deinit(gpa);
    try testing.expectError(error.ColumnOutOfBounds, wrapped.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .delta, false),
    }));
}

test "validate rejects a column whose spec is not declared" {
    const gpa = testing.allocator;
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(1, .delta, false), 2),
    };
    const set = try RawColumns.init(gpa, &descs, "abcd");
    defer set.deinit(gpa);

    // The block holds a key counter the caller did not declare.
    try testing.expectError(error.MissingColumn, set.validate(&.{ColumnSpec.make(0, .actor, false)}));
    // Declaring it under the compressed flag is enough: the comparison ignores
    // the DEFLATE bit.
    try set.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .delta, true),
    });
    // A spec that differs in the encoding is a different column.
    try testing.expectError(error.MissingColumn, set.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .string, false),
    }));
}

test "validate rejects a column count larger than the data block" {
    // Every column of a set holds at least one byte, so more columns than
    // bytes cannot be a set this format wrote. The set is assembled by hand
    // because `init` cannot build one: the constructor drops empty columns
    // and this is the check that says a caller must not smuggle them in.
    var columns = [_]RawColumn{
        RawColumn.init(ColumnSpec.make(0, .actor, false), ColumnRange.init(0, 1)),
        RawColumn.init(ColumnSpec.make(1, .delta, false), ColumnRange.init(1, 2)),
    };
    const set: RawColumns = .{ .columns = &columns, .data = "a" };
    try testing.expectEqual(@as(usize, 2), set.len());
    try testing.expectError(error.Overflow, set.validate(&.{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(1, .delta, false),
    }));

    // One column in one byte is the boundary, and it validates.
    var one = [_]RawColumn{
        RawColumn.init(ColumnSpec.make(0, .actor, false), ColumnRange.init(0, 1)),
    };
    const fits: RawColumns = .{ .columns = &one, .data = "a" };
    try fits.validate(&.{ColumnSpec.make(0, .actor, false)});
}

test "each validation failure is its own error" {
    const gpa = testing.allocator;
    var found: [5]ParseError = undefined;
    var n: usize = 0;

    {
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
            ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        };
        const set = try RawColumns.init(gpa, &descs, "abcd");
        defer set.deinit(gpa);
        set.validate(&.{ColumnSpec.make(0, .actor, false)}) catch |failure| {
            found[n] = failure;
            n += 1;
        };
    }
    {
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(2, .rle_uint, false), 2),
            ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
        };
        const set = try RawColumns.init(gpa, &descs, "abcd");
        defer set.deinit(gpa);
        set.validate(&.{
            ColumnSpec.make(2, .rle_uint, false),
            ColumnSpec.make(0, .actor, false),
        }) catch |failure| {
            found[n] = failure;
            n += 1;
        };
    }
    {
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(0, .actor, false), 3),
            ColumnDesc.init(ColumnSpec.make(1, .delta, false), 3),
        };
        const set = try RawColumns.init(gpa, &descs, "abcd");
        defer set.deinit(gpa);
        set.validate(&.{
            ColumnSpec.make(0, .actor, false),
            ColumnSpec.make(1, .delta, false),
        }) catch |failure| {
            found[n] = failure;
            n += 1;
        };
    }
    {
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(0, .actor, false), 2),
            ColumnDesc.init(ColumnSpec.make(1, .delta, false), 2),
        };
        const set = try RawColumns.init(gpa, &descs, "abcd");
        defer set.deinit(gpa);
        set.validate(&.{ColumnSpec.make(0, .actor, false)}) catch |failure| {
            found[n] = failure;
            n += 1;
        };
    }
    {
        var columns = [_]RawColumn{
            RawColumn.init(ColumnSpec.make(0, .actor, false), ColumnRange.init(0, 1)),
            RawColumn.init(ColumnSpec.make(1, .delta, false), ColumnRange.init(1, 2)),
        };
        const set: RawColumns = .{ .columns = &columns, .data = "a" };
        set.validate(&.{
            ColumnSpec.make(0, .actor, false),
            ColumnSpec.make(1, .delta, false),
        }) catch |failure| {
            found[n] = failure;
            n += 1;
        };
    }

    try testing.expectEqual(@as(usize, 5), n);
    for (found, 0..) |e, i| {
        for (found[i + 1 ..]) |other| try testing.expect(e != other);
    }
}
