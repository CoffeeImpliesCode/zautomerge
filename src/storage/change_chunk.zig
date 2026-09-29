//! The change chunk: one change in the columnar form a sync message carries
//! and `save` writes into a document's history.
//!
//! A change chunk body is a fixed header followed by one metadata block, one
//! data block of operation columns, and an author footer whose length is
//! whatever is left over:
//!
//! ```text
//! offset        size  field
//! 0             n     deps: uleb128 count, then count * 32 raw hash bytes
//! ...           n     actor: uleb128 byte count + raw bytes
//! ...           n     seq: uleb128
//! ...           n     start_op: nonzero uleb128
//! ...           n     time: sleb128, seconds since the epoch
//! ...           n     message: uleb128 byte count + UTF-8 bytes
//! ...           n     other_actors: uleb128 count, then per actor uleb128 length + bytes
//! ...           m     ops metadata: uleb128 column count, then per column
//!                        uleb128 specification and uleb128 byte length
//! ...           p     ops data: the columns' bytes back to back
//! ...           q     extra bytes: the remainder, which is the author footer
//! ```
//!
//! The header half is `change.zig`'s: `parseChange` reads it and records where
//! it ended in `header_len`, and `Change.encodeHeader` writes it back. This
//! module owns everything after that point — the column set, the reader, and
//! the writer — and leaves the op rows themselves to the columnar layer.
//!
//! ## The operation columns
//!
//! Fourteen named columns make up an operation row. Their ids and encodings are
//! FORMAT, not choices: they are what the change hash covers, so a change
//! written with `insert` under any other id is a different change. They come
//! from `ChangeOpsColumns::raw_columns`
//! (`storage/change/change_op_columns.rs:291-367`), which is also the order the
//! writer emits them, and that order is ascending by normalized specification
//! — the order `RawColumns::parse` requires
//! ([survey 03](../docs/survey/03-storage-columnar.md) §Change op column
//! layout).
//!
//! Which of the fourteen a change actually carries depends on its ops: the
//! object columns are absent from an all-root change, and the value, expand,
//! mark-name and predecessor-value columns are omitted when empty
//! (`change_op_columns.rs:332-365`). So the set is a vocabulary, not a
//! template, and a reader must treat an absent column as absent rather than as
//! an error. A column a change has never heard of is likewise not an error: the
//! reader keeps it and the op decoder parks it
//! (`change_op_columns.rs:536-539`).
//!
//! ## Two rules the reader enforces
//!
//! * **No per-column DEFLATE.** A change chunk's columns are never deflated;
//!   `RawColumns::uncompressed()` returning `None` is
//!   `ParseError::CompressedChangeCols` (`storage/change.rs:129-131`). Whole
//!   chunk compression is a different thing and is a chunk type, not a column
//!   bit — see below.
//! * **The data block is exactly the sum of the declared column lengths**
//!   (`storage/change.rs:113-118`), and the footer is everything after it
//!   (`:120-125`). So a column whose declared length runs past the data block
//!   is caught as `error.LengthExceedsInput` before any byte of the block is
//!   taken, and never as a range that pokes into the footer.
//!
//! ## Compressed change chunks
//!
//! A compressed change chunk is a `ChunkType.compressed` chunk whose body is a
//! raw DEFLATE stream over a change chunk body. Its stored checksum is the
//! checksum of the **inflated** body hashed as a `change` chunk
//! (`change/compressed.rs:18-34`), so `chunk.parseChunk` cannot check it — it
//! defers exactly that case. `parseFramedChunk` is the only way in from a
//! framed chunk, and it routes every compressed body through
//! `chunk.decompressChunk`, which inflates it and verifies it against the
//! header before a single column is read.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const parse = @import("parse.zig");
const column_spec = @import("column_spec.zig");
const chunk = @import("chunk.zig");
const change_mod = @import("../change.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const checksum_size = types.checksum_size;
const Input = parse.Input;
const Change = change_mod.Change;
const ColumnDesc = column_spec.ColumnDesc;
const ColumnSpec = column_spec.ColumnSpec;
const Encoding = column_spec.Encoding;
const RawColumns = column_spec.RawColumns;

/// One named column of an operation row.
///
/// The name is the field name upstream gives the column's contents
/// (`ObjIdRange.actor_range`, `KeyRange.counter_range`, and so on,
/// `change_op_columns.rs:291-365`); the id and encoding are the column id
/// constants and `ColumnType` values at `change_op_columns.rs:29-36` and
/// `:496-547`. They are the two halves of the wire specification, so both are
/// fixed for the life of the format.
pub const OpColumn = enum(u8) {
    /// The actor index of the object the op acts on. Ids 0 and 1 are `obj`
    /// (`change_op_columns.rs:29-30`, `:496-497`).
    obj_actor = 0,
    /// The op counter of the object the op acts on, run-length encoded
    /// (`:498`).
    obj_counter = 1,
    /// The actor half of the op's key, null for a string key (`:499`).
    key_actor = 2,
    /// The counter half of the op's key, delta-encoded (`:500`).
    key_counter = 3,
    /// The string half of the op's key, null for an object key (`:501`).
    key_string = 4,
    /// Whether the op inserts rather than overwrites (`:502`).
    insert = 5,
    /// The op's action, run-length encoded (`:503-504`).
    action = 6,
    /// The metadata word of the op's value, with the value's own type code and
    /// length bookkeeping (`:505-508`).
    value_metadata = 7,
    /// The op's value payload, read according to the sibling metadata column
    /// (`:509-517`).
    value = 8,
    /// One count per op: how many predecessors that op has, as a group
    /// column (`:518-522`).
    pred_group = 9,
    /// The actor indices of the predecessors of every op, flattened across the
    /// group, run-length encoded (`:523-527`).
    pred_actor = 10,
    /// The counters of the predecessors of every op, flattened and
    /// delta-encoded, which is why the writer requires the predecessors of an
    /// op in ascending order (`change_actors.rs:79-82`).
    pred_counter = 11,
    /// Whether the op is an expanded mark, bit-packed
    /// (`change_op_columns.rs:528-529`).
    expand = 12,
    /// The name of the mark the op creates, as a string column
    /// (`:530-531`).
    mark_name = 13,

    /// The column id, the low-order part of the specification above bit 3.
    pub fn id(self: OpColumn) u32 {
        return self.row().col_id;
    }

    /// The column encoding, the three bits below the id. There is no
    /// `ColumnType` for a run-length column over nullable values or over
    /// signed values, and none for raw bytes: a value's own type code lives
    /// in the metadata word, not here
    /// ([column_spec.zig](column_spec.zig) §`Encoding`).
    pub fn encoding(self: OpColumn) Encoding {
        return self.row().enc;
    }

    /// The wire specification, uncompressed, which is the only form a change
    /// chunk ever carries.
    pub fn spec(self: OpColumn) ColumnSpec {
        const row = self.row();
        return ColumnSpec.make(row.col_id, row.enc, false);
    }

    /// The column's name, which is the name upstream gives the value it holds.
    pub fn name(self: OpColumn) []const u8 {
        return @tagName(self);
    }

    /// The column with this name, or null when no column of a change chunk
    /// carries it. Names are the enum tags, so a lookup is a compile-time
    /// string comparison rather than a scan of the table.
    pub fn fromName(name: []const u8) ?OpColumn {
        return std.meta.stringToEnum(OpColumn, name);
    }

    /// The operation column with this specification, or null when the block
    /// holds a column that is not one of the fourteen: a successor column of
    /// id 8, an id 2 or 6 that a change chunk never uses
    /// ([survey 03](../docs/survey/03-storage-columnar.md) §Change op column
    /// layout), or an id past the fourteen.
    ///
    /// The DEFLATE bit is ignored, as it is in every other comparison of two
    /// specifications (`column_specification.rs:14-17`), so this identifies a
    /// column rather than a column in a particular storage form. A change chunk
    /// reader rejects a deflated column outright, so in practice the bit is
    /// always clear here.
    pub fn fromSpec(spec: ColumnSpec) ?OpColumn {
        const want = spec.normalize();
        for (op_column_table) |row| {
            if (ColumnSpec.make(row.col_id, row.enc, false).eql(want)) return row.tag;
        }
        return null;
    }

    /// The table row for this column. The table is in tag order and the
    /// comptime block below checks it, so this is an index, not a scan.
    fn row(self: OpColumn) TableRow {
        return op_column_table[@intFromEnum(self)];
    }
};

/// One row of the operation column table: a name, the column id upstream
/// assigns it, and the encoding upstream encodes it with.
const TableRow = struct {
    tag: OpColumn,
    col_id: u32,
    enc: Encoding,
};

/// The fourteen operation columns of a change chunk, keyed by id and encoding.
///
/// The ids are upstream's eight `ColumnId` constants
/// (`change_op_columns.rs:29-36`); the encodings are the `ColumnType` each is
/// read and written with (`:496-531` and `:291-367`). Nothing here is
/// negotiable: the change hash is taken over these bytes, so moving a column
/// or re-encoding it changes the hash and the change stops being the same
/// change.
const op_column_table = [_]TableRow{
    .{ .tag = .obj_actor, .col_id = 0, .enc = .actor },
    .{ .tag = .obj_counter, .col_id = 0, .enc = .rle_uint },
    .{ .tag = .key_actor, .col_id = 1, .enc = .actor },
    .{ .tag = .key_counter, .col_id = 1, .enc = .delta },
    .{ .tag = .key_string, .col_id = 1, .enc = .string },
    .{ .tag = .insert, .col_id = 3, .enc = .boolean },
    .{ .tag = .action, .col_id = 4, .enc = .rle_uint },
    .{ .tag = .value_metadata, .col_id = 5, .enc = .value_metadata },
    .{ .tag = .value, .col_id = 5, .enc = .value },
    .{ .tag = .pred_group, .col_id = 7, .enc = .group },
    .{ .tag = .pred_actor, .col_id = 7, .enc = .actor },
    .{ .tag = .pred_counter, .col_id = 7, .enc = .delta },
    .{ .tag = .expand, .col_id = 9, .enc = .boolean },
    .{ .tag = .mark_name, .col_id = 10, .enc = .string },
};

comptime {
    // `OpColumn.row` indexes this table by tag, so the table must be in tag
    // order and must cover every tag. Both are checked here rather than
    // discovered by a lookup that returns the wrong column.
    if (op_column_table.len != @typeInfo(OpColumn).@"enum".fields.len) {
        @compileError("every OpColumn needs a row in op_column_table");
    }
    for (op_column_table, 0..) |row, i| {
        if (@intFromEnum(row.tag) != i) {
            @compileError("op_column_table must be in OpColumn tag order");
        }
    }
}

/// Every operation column of a change chunk, in the order the writer emits
/// them. That order is ascending by normalized specification, so the set a
/// writer produces is already in the order `RawColumns::parse` demands
/// (`raw_column.rs:248-253`).
pub const op_columns: [op_column_table.len]OpColumn = blk: {
    var list: [op_column_table.len]OpColumn = undefined;
    for (op_column_table, 0..) |row, i| list[i] = row.tag;
    break :blk list;
};

/// The op columns of a change chunk, and the author footer that follows them.
///
/// This is everything in a change chunk body after the header `Change` writes,
/// and it is what a reader hands back as the second half of a parsed chunk.
pub const OpsBlock = struct {
    /// The operation columns and the data block their ranges index into. The
    /// ranges are relative to the data block, not to the chunk
    /// (`raw_column.rs:24-26`).
    cols: RawColumns,
    /// The author footer: every byte after the op data, with no length prefix
    /// of its own (`storage/change.rs:120-125`). The only payload the format
    /// defines here is `uleb(1) || uleb(len) || bytes` (`change.rs:365-403`),
    /// but a reader must not require that: anything after the op data is
    /// extra, and a change written by a newer implementation may carry more.
    footer: []const u8,

    /// The op columns `cols` with the author footer `footer`. Neither is
    /// copied: the block borrows the data it describes, and the caller keeps
    /// both alive.
    pub fn init(cols: RawColumns, footer: []const u8) OpsBlock {
        return .{ .cols = cols, .footer = footer };
    }

    /// A change with no operations: no columns, no data, no footer. An empty
    /// transaction still commits a change, and its op block is exactly this
    /// (`raw_column.rs:183`, `:187-205` drop the empty columns, and a change
    /// with none writes a count of zero).
    pub fn empty() OpsBlock {
        const no_columns: RawColumns = .{ .columns = &.{}, .data = &.{} };
        return init(no_columns, &.{});
    }

    /// The op data block: the columns' bytes, contiguous and in metadata order.
    pub fn data(self: OpsBlock) []const u8 {
        return self.cols.data;
    }
};

/// A change chunk body, parsed: the header, the op columns, and the footer.
///
/// Everything here borrows the body it was parsed from, so the body must
/// outlive the chunk. The one allocation `parseChange` made — the
/// `other_actors` array — is freed by `deinit`, and `RawColumns`'s column list
/// with it.
pub const ChangeChunk = struct {
    /// The change header, as `parseChange` read it. Its `bytes` field is this
    /// body, and its `opsBytes` runs from the end of the header to the end of
    /// the body, which is the op metadata block, the op data block, and the
    /// footer together.
    change: Change,
    /// The op columns. The set is validated on the way in: ascending by
    /// normalized specification, no duplicate, every range inside the data
    /// block, and no column carrying the DEFLATE bit.
    ops: RawColumns,
    /// The author footer: the bytes of the body after the op data block.
    footer: []const u8,

    /// Frees the `other_actors` array and the column list. The body, the op
    /// data, and the footer all belong to the caller and are left alone.
    pub fn deinit(self: *ChangeChunk, gpa: Allocator) void {
        self.ops.deinit(gpa);
        self.change.deinit(gpa);
        self.* = undefined;
    }

    /// The bytes of one named operation column, or null when this change
    /// carries no such column. A change with no object column has no
    /// `obj_actor`, and a change with no value payload has no `value`
    /// (`change_op_columns.rs:332-336`); neither is an error.
    pub fn opBytes(self: ChangeChunk, col: OpColumn) ParseError!?[]const u8 {
        return self.ops.bytesFor(col.spec());
    }

    /// The bytes of a column of any specification, or null when the block holds
    /// no such column. This is the lookup a column decoder makes, and it also
    /// finds a column the fourteen do not name, which is how a change written
    /// by a newer implementation still reads.
    pub fn bytesFor(self: ChangeChunk, spec: ColumnSpec) ParseError!?[]const u8 {
        return self.ops.bytesFor(spec);
    }

    /// The name of the operation column with this specification, or null when
    /// the specification is not one of the fourteen. A reader that wants to
    /// say what a block holds walks it with this; it does not have to know the
    /// ids by heart.
    pub fn nameOf(spec: ColumnSpec) ?[]const u8 {
        const col = OpColumn.fromSpec(spec) orelse return null;
        return col.name();
    }

    /// The op data block: the columns' bytes, contiguous and in metadata
    /// order. Distinct from `Change.opsBytes`, which also covers the metadata
    /// block and the footer.
    pub fn opData(self: ChangeChunk) []const u8 {
        return self.ops.data;
    }

    /// The op metadata block's own bytes: from the end of the header to the
    /// start of the op data block. It is not a slice of the body, because the
    /// body's bytes hold the data block immediately after the metadata; the
    /// block is reproducible from the column set and the writer that wrote it.
    pub fn opCount(self: ChangeChunk) usize {
        return self.ops.len();
    }
};

/// A parsed change chunk that owns the body it was read from, for the case
/// where the chunk arrived deflated and had to be inflated before it could be
/// parsed. `chunk.decompressChunk` returns a buffer the caller owns, and every
/// slice a `ChangeChunk` holds points into it, so the two have the same
/// lifetime.
pub const OwnedChangeChunk = struct {
    /// The inflated body, when the chunk arrived deflated. Null when the body
    /// was borrowed from the caller's own bytes, in which case nothing here
    /// owns anything but the two lists.
    inflated: ?[]u8,
    /// The parsed chunk. Its slices point into `inflated` when that is
    /// present, and into the caller's chunk data otherwise.
    parsed: ChangeChunk,

    /// Frees the inflated body, if this chunk has one, and the parsed chunk's
    /// own two allocations. A borrowed body is never freed.
    pub fn deinit(self: *OwnedChangeChunk, gpa: Allocator) void {
        if (self.inflated) |body| gpa.free(body);
        self.parsed.deinit(gpa);
        self.* = undefined;
    }
};

/// A change chunk body as written, with the identity the framing stores.
pub const Encoded = struct {
    /// The whole body: header, op metadata, op data, footer. Owned by the
    /// caller.
    body: []u8,
    /// `SHA-256(0x01 || uleb128(body.len) || body)`: the change's identity, and
    /// what a sync peer compares. The length is encoded with its own LEB128
    /// width, so two changes with the same body and different declared lengths
    /// would differ — but there are none, because the length is the body's.
    hash: ChangeHash,
    /// The first four bytes of `hash`, which is what a chunk header stores in
    /// its checksum field (`chunk.rs:180-185`).
    checksum: [checksum_size]u8,

    /// Frees the body. The hash and the checksum are values, not views.
    pub fn deinit(self: *Encoded, gpa: Allocator) void {
        gpa.free(self.body);
        self.body = &.{};
    }
};

/// The smallest a column descriptor can be on the wire: a one-byte
/// specification and a one-byte length. `readCountThen` needs a floor to
/// divide the remaining input by before it believes a count, and this is the
/// structural one (`raw_column.rs:225-232`).
const min_desc_size: usize = 2;

/// Parses a change chunk body: the header `change.zig` owns, then the op
/// column metadata block, the op data block those columns describe, and the
/// author footer.
///
/// `body` is the body only, with no chunk framing — what `chunk.parseChunk`
/// hands back for a `ChunkType.change` chunk, and what `chunk.decompressChunk`
/// produces for a compressed one. To go through the framing as well, use
/// `parseFramedChunk`; it is the only path that inflates.
///
/// Refused, all `ParseError`:
///
/// * a header that runs off the end, which is `parseChange`'s to report;
/// * a column count larger than the input could hold, caught before the count
///   sizes anything;
/// * a column whose declared length runs past the data block, which is
///   `error.LengthExceedsInput`, and is checked before the data block is
///   taken, so a hostile length costs a comparison;
/// * a column carrying the DEFLATE bit, because a change chunk's columns are
///   never deflated — upstream's `CompressedChangeCols`
///   (`storage/change.rs:129-131`), reported here as
///   `error.InvalidColumnSpec` because a deflated column is a specification
///   this chunk type does not define;
/// * a block whose specifications are not in ascending normalized order, or
///   which repeats one — upstream's `NotInNormalOrder`
///   (`raw_column.rs:248-253`) and the duplicate check
///   (`columns.rs:203-210`).
pub fn parseChangeChunk(body: []const u8, gpa: Allocator) ParseError!ChangeChunk {
    // The header reader owns the fields; this module needs only where it
    // ended. `header_len` is where the op metadata block starts, and the whole
    // body is what the change hash was taken over.
    var change = try change_mod.parseChange(body, gpa);
    errdefer change.deinit(gpa);

    var in: Input = .init(body);
    in.skip(change.header_len);

    var sink: DescSink = .{ .in = &in, .gpa = gpa };
    try in.readCountThen(&sink, min_desc_size, DescSink.collect);
    const descs = sink.descs orelse &[_]ColumnDesc{};
    defer gpa.free(sink.descs orelse &.{});

    // A deflated column in a change chunk is refused before its bytes are even
    // located, so the block is never half-read: this chunk type has no
    // per-column compression, and a column that claims some is not a column
    // this format writes.
    for (descs) |desc| {
        if (desc.spec.isCompressed()) return error.InvalidColumnSpec;
    }

    // The data block is exactly the sum of the declared lengths, so a sum past
    // what is left means a column's length runs past the data block. Checked
    // against `remaining()` before `take`, which is what turns a hostile
    // length into a comparison rather than a read.
    if (sink.total > in.remaining()) return error.LengthExceedsInput;
    const data = try in.take(sink.total);

    const ops = try RawColumns.init(gpa, descs, data);
    errdefer ops.deinit(gpa);
    // Order and uniqueness, and that every range is inside the data block.
    // `descs` is not the change's own column set: a change may carry a column
    // the fourteen do not name, so there is no declared set to check against.
    try ops.validate(null);

    // Whatever is left is the author footer. Upstream takes the rest of the
    // chunk with `parse::take_rest` (`storage/change.rs:120-125`), and the
    // footer has no length prefix of its own.
    return .{ .change = change, .ops = ops, .footer = in.rest() };
}

/// Reads a change chunk out of a framed chunk, inflating first if the chunk is
/// a `ChunkType.compressed` one.
///
/// A `change` chunk is read in place, from the caller's bytes. A `compressed`
/// chunk is inflated through `chunk.decompressChunk`, which is the only place
/// a compressed chunk's checksum can be checked: the stored checksum is the
/// checksum of the inflated body hashed as a change chunk
/// (`chunk.rs:118-122`), and `chunk.parseChunk` deliberately does not verify
/// that case. So a body read this way has been verified, and a body read from
/// a `change` chunk was verified when the chunk was parsed.
///
/// A `document` or `bundle` chunk is `error.InvalidChunkType`: those hold no
/// single change.
pub fn parseFramedChunk(c: chunk.Chunk, gpa: Allocator) ParseError!OwnedChangeChunk {
    switch (c.typ) {
        .change => {
            const parsed = try parseChangeChunk(c.data, gpa);
            return .{ .inflated = null, .parsed = parsed };
        },
        .compressed => {
            // The checksum is verified here, before the inflated bytes are
            // handed to a body parser, which is the whole reason this path
            // goes through `decompressChunk` and not `decompressRaw`.
            const body = try chunk.decompressChunk(gpa, c);
            errdefer gpa.free(body);
            const parsed = try parseChangeChunk(body, gpa);
            return .{ .inflated = body, .parsed = parsed };
        },
        .document, .bundle => return error.InvalidChunkType,
    }
}

/// Appends a change chunk body to `out`: the header from `change.encodeHeader`,
/// then the op metadata block, the op data block, and the author footer.
///
/// The inverse of `parseChangeChunk` for a body that was written this way: the
/// same change, the same columns in the same order, the same bytes. The header
/// is written from the `Change`'s own fields, so a `Change` parsed from a body
/// and re-encoded with the same op block reproduces that body exactly.
pub fn writeBody(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    change: Change,
    ops: OpsBlock,
) Allocator.Error!void {
    try change.encodeHeader(out, gpa);
    try writeOpsBlock(out, gpa, ops);
}

/// Appends an op block to `out`: the metadata block, then the data block, then
/// the author footer.
///
/// The metadata block is the column count and, per column, its specification
/// and the length of its bytes (`raw_column.rs:258-268`). The columns are
/// written in the order `RawColumns` holds them, which the parser requires to
/// be ascending by normalized specification.
///
/// A column whose range is empty is not written and does not count: a column
/// with no bytes is not a column, upstream drops it at construction
/// (`raw_column.rs:40-50`, `:183`) and a count that included it would name a
/// column no reader could find. A caller whose columns are out of order, or
/// which names a deflated column, has a bug the format cannot express: the
/// writer asserts, because a silently wrong body would be a change with the
/// wrong hash, and no reader would notice.
pub fn writeOpsBlock(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    ops: OpsBlock,
) Allocator.Error!void {
    var written: usize = 0;
    for (ops.cols.columns) |col| {
        if (col.isEmpty()) continue;
        // A deflated column in a change chunk is not a thing this writer can
        // produce: the bytes would be a raw DEFLATE stream the reader has just
        // been told not to expect. Refuse it here rather than write a body no
        // reader of this format accepts.
        std.debug.assert(!col.spec.isCompressed());
        // Order is not checked here — it is a property of the caller's set, and
        // the writer emits what it is given — but a descending specification
        // would be a body `parseChangeChunk` rejects, so it is worth catching
        // at the source. A set of one column is trivially ordered.
        std.debug.assert(written == 0 or
            ColumnSpec.make(ops.cols.columns[written - 1].spec.id(), ops.cols.columns[written - 1].spec.encoding(), false)
                .lessThan(col.spec));
        try leb128.appendUnsigned(out, gpa, col.spec.raw);
        try leb128.appendUnsigned(out, gpa, col.len());
        written += 1;
    }
    // The count is written first, so the descriptors are counted in a pass
    // before any of them goes out.
    var count: std.ArrayList(u8) = .empty;
    defer count.deinit(gpa);
    try leb128.appendUnsigned(&count, gpa, written);
    try out.appendSlice(gpa, count.items);

    try out.appendSlice(gpa, ops.cols.data);
    try out.appendSlice(gpa, ops.footer);
}

/// The body of a change chunk, allocated. See `writeBody`; the result is the
/// bytes a `ChunkType.change` chunk carries, without the framing.
pub fn encodeBody(
    gpa: Allocator,
    change: Change,
    ops: OpsBlock,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeBody(&out, gpa, change, ops);
    return out.toOwnedSlice(gpa);
}

/// The body of a change chunk together with the change hash and the checksum
/// the framing stores for it.
///
/// The checksum is the first four bytes of the change hash, and the change
/// hash is taken over the body framed as a `ChunkType.change` chunk — the type
/// byte, then the body's length as LEB128, then the body (`chunk.rs:300-312`).
/// Both are values, not views: they survive the body being freed.
pub fn encode(
    gpa: Allocator,
    change: Change,
    ops: OpsBlock,
) Allocator.Error!Encoded {
    const body = try encodeBody(gpa, change, ops);
    errdefer gpa.free(body);
    const hash = chunk.changeHashOf(.change, body);
    return .{ .body = body, .hash = hash, .checksum = hash.checksum() };
}

/// The `readCountThen` destination for a column metadata block. A descriptor
/// is a specification and a length, both LEB128, and the block is a count of
/// them followed by the data they describe.
const DescSink = struct {
    in: *Input,
    gpa: Allocator,
    /// The descriptors read, once the whole block has been read. Null while
    /// the block is still being read, and empty when the count was zero.
    descs: ?[]ColumnDesc = null,
    /// The sum of the descriptor lengths: the length of the data block they
    /// describe. Saturated, because a length came off the wire and can be
    /// absurd; a saturated sum is larger than any real input and so is caught
    /// by the comparison that follows, where upstream saturates for the same
    /// reason (`raw_column.rs:235-239`).
    total: usize = 0,

    fn collect(self: *DescSink, count: usize) ParseError!void {
        if (count == 0) {
            self.descs = self.gpa.alloc(ColumnDesc, 0);
            return;
        }
        // `readCountThen` proved `count <= remaining / min_desc_size`, so this
        // allocation is bounded by the input. A zero-length allocation is
        // legal and freeable, and the descriptors hold no pointers, so a
        // failure part way through frees them all.
        const descs = try self.gpa.alloc(ColumnDesc, count);
        errdefer self.gpa.free(descs);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // The specification is a LEB128 u32 (`raw_column.rs:226`): the id
            // is 28 bits and the encoding and DEFLATE flag are three more, so
            // anything wider is not a specification.
            const raw = try self.in.takeUleb();
            const spec_raw = std.math.cast(u32, raw) orelse return error.Overflow;
            // The length is a LEB128 u64, saturated to a byte count. On a
            // 64-bit target the cast is total; on a narrower one an absurd
            // length is refused rather than wrapped.
            const len_raw = try self.in.takeUleb();
            const len = std.math.cast(usize, len_raw) orelse return error.TooLarge;
            descs[i] = ColumnDesc.init(ColumnSpec.fromRaw(spec_raw), len);
            self.total = self.total +| len;
        }
        self.descs = descs;
    }
};

const testing = std.testing;

// The body of the first change chunk in
// `test/fixtures/two_change_chunks.automerge`, byte for byte: a change by the
// author `da0a…d94d`, seq 1, start op 1, message "change 1", no dependencies
// and no other actors, and one operation. The op block is five columns — the
// string key "a", insert, the `set` action, a value metadata word, and a
// predecessor group with no predecessors — 17 bytes of metadata and 10 of
// data, and no footer. It is here so this port's reader is pinned to bytes
// automerge wrote, not to bytes this port wrote.
const fixture_first_body = [_]u8{
    0x00, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83,
    0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00,
    0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f,
    0x01, 0x61, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00,
};

// The body of the second change chunk in the same fixture: the same author at
// seq 2, depending on the first change, with two operations. The op block is
// eight columns, including the object columns a root change does not have, a
// value payload, and a one-byte-per-op predecessor group.
const fixture_second_body = [_]u8{
    0x01, 0x9a, 0xc3, 0xd7, 0x30, 0xf2, 0x62, 0xda, 0x35, 0xe7, 0x1d, 0xb5,
    0x91, 0xb9, 0xe8, 0x15, 0x0d, 0xe9, 0xb0, 0x28, 0x26, 0xda, 0xf7, 0x50,
    0x06, 0xf2, 0x29, 0x89, 0x16, 0xad, 0xec, 0x6e, 0x0b, 0x10, 0xda, 0x0a,
    0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5, 0xeb, 0xe1, 0xac,
    0xd9, 0x4d, 0x02, 0x02, 0xc1, 0xbe, 0xc4, 0x83, 0xe1, 0x30, 0x08, 0x63,
    0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x32, 0x00, 0x08, 0x01, 0x02, 0x02,
    0x02, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x57, 0x01, 0x70,
    0x02, 0x7f, 0x00, 0x7f, 0x01, 0x7f, 0x01, 0x61, 0x01, 0x7f, 0x01, 0x7f,
    0x16, 0x62, 0x7f, 0x00,
};

test "the operation columns are fourteen fixed ids and encodings" {
    // The format, one assertion per column. Ids and encodings come from
    // upstream's eight id constants (`change_op_columns.rs:29-36`) and the
    // `ColumnType` each is read and written with (`:496-531`); the raw word is
    // `id << 4 | encoding` with the DEFLATE bit clear, the packing
    // `column_specification.rs:21-29` and the specification both describe.
    const expected = [_]struct { col: OpColumn, id: u32, enc: Encoding, raw: u32 }{
        // obj: the object the op acts on, as an actor index and a counter.
        // Ids 0 and 1 upstream (`OBJ_COL_ID`, `KEY_COL_ID`).
        .{ .col = .obj_actor, .id = 0, .enc = .actor, .raw = 0x01 },
        .{ .col = .obj_counter, .id = 0, .enc = .rle_uint, .raw = 0x02 },
        // key: the op's key, one of three columns chosen by its variant. Id 1
        // (`KEY_COL_ID`).
        .{ .col = .key_actor, .id = 1, .enc = .actor, .raw = 0x11 },
        .{ .col = .key_counter, .id = 1, .enc = .delta, .raw = 0x13 },
        .{ .col = .key_string, .id = 1, .enc = .string, .raw = 0x15 },
        // insert: id 3 (`INSERT_COL_ID`).
        .{ .col = .insert, .id = 3, .enc = .boolean, .raw = 0x34 },
        // action: id 4 (`ACTION_COL_ID`), run-length, not delta: an action is a
        // code, not a counter.
        .{ .col = .action, .id = 4, .enc = .rle_uint, .raw = 0x42 },
        // val: id 5 (`VAL_COL_ID`), a metadata word and a payload, which share
        // the id because they are read as one column.
        .{ .col = .value_metadata, .id = 5, .enc = .value_metadata, .raw = 0x56 },
        .{ .col = .value, .id = 5, .enc = .value, .raw = 0x57 },
        // pred: id 7 (`PRED_COL_ID`), a group count and the flattened
        // actor/counter pairs it indexes.
        .{ .col = .pred_group, .id = 7, .enc = .group, .raw = 0x70 },
        .{ .col = .pred_actor, .id = 7, .enc = .actor, .raw = 0x71 },
        .{ .col = .pred_counter, .id = 7, .enc = .delta, .raw = 0x73 },
        // expand: id 9 (`EXPAND_COL_ID`).
        .{ .col = .expand, .id = 9, .enc = .boolean, .raw = 0x94 },
        // mark_name: id 10 (`MARK_NAME_COL_ID`).
        .{ .col = .mark_name, .id = 10, .enc = .string, .raw = 0xa5 },
    };
    try testing.expectEqual(expected.len, op_columns.len);
    for (expected, op_columns) |want, col| {
        try testing.expectEqual(want.col, col);
        try testing.expectEqual(want.id, col.id());
        try testing.expectEqual(want.enc, col.encoding());
        try testing.expectEqual(want.raw, col.spec().raw);
        // A change chunk never deflates a column, so the specification is the
        // same word as one read off the wire with the DEFLATE bit clear.
        try testing.expect(!col.spec().isCompressed());
    }

    // Ids 2, 6 and 8 are unused in a change chunk upstream, and none of the
    // fourteen claims them: id 8 is the successor group a document chunk has,
    // not a change (`change_op_columns.rs:29-36`, and the successor columns
    // are in `op_set2/columns.rs`).
    for ([_]u32{ 2, 6, 8 }) |unused| {
        for (op_columns) |col| {
            try testing.expect(col.id() != unused);
        }
        try testing.expect(OpColumn.fromSpec(ColumnSpec.make(unused, .group, false)) == null);
    }
}

test "the operation column set looks up by name and by specification" {
    // By name, in both directions.
    for (op_columns) |col| {
        try testing.expectEqual(col, OpColumn.fromName(col.name()) orelse error.TestUnexpectedResult);
    }
    try testing.expectEqualStrings("pred_group", OpColumn.fromName("pred_group").?.name());
    try testing.expect(OpColumn.fromName("obj") == null);
    try testing.expect(OpColumn.fromName("PRED_GROUP") == null);
    try testing.expect(OpColumn.fromName("") == null);

    // By specification. A deflated word is the same column, as everywhere else.
    for (op_columns) |col| {
        try testing.expectEqual(col, OpColumn.fromSpec(col.spec()) orelse error.TestUnexpectedResult);
        try testing.expectEqual(col, OpColumn.fromSpec(col.spec().deflated()) orelse error.TestUnexpectedResult);
    }
    // A name for each of the fourteen, from the reader's side.
    try testing.expectEqualStrings("value_metadata", ChangeChunk.nameOf(ColumnSpec.make(5, .value_metadata, false)).?);
    try testing.expectEqualStrings("key_counter", ChangeChunk.nameOf(ColumnSpec.make(1, .delta, false)).?);
    // A successor group column is not one of a change chunk's columns, and a
    // document-only spec has no name here.
    try testing.expect(ChangeChunk.nameOf(ColumnSpec.make(8, .group, false)) == null);
    try testing.expect(ChangeChunk.nameOf(ColumnSpec.make(2, .delta, false)) == null);
    try testing.expect(ChangeChunk.nameOf(ColumnSpec.make(11, .rle_uint, false)) == null);
}

test "a change automerge wrote reads column by column" {
    const gpa = testing.allocator;
    var parsed = try parseChangeChunk(&fixture_first_body, gpa);
    defer parsed.deinit(gpa);

    // The header came through `parseChange`, so the change is the one the
    // fixture's chunk header names.
    try testing.expectEqual(@as(usize, 0), parsed.change.deps.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d },
        parsed.change.actor.bytes,
    );
    try testing.expectEqual(@as(u64, 1), parsed.change.seq);
    try testing.expectEqual(@as(u64, 1), parsed.change.start_op);
    try testing.expectEqualStrings("change 1", parsed.change.message);
    try testing.expectEqual(@as(usize, 0), parsed.change.other_actors.len);

    // The op block is 17 bytes of metadata and 10 of data, and the header ends
    // where the metadata begins.
    try testing.expectEqual(@as(usize, 36), parsed.change.header_len);
    try testing.expectEqual(@as(usize, 36 + 17), parsed.ops.data.ptr - fixture_first_body[0..].ptr);
    try testing.expectEqual(@as(usize, 10), parsed.opData().len);
    try testing.expectEqual(@as(usize, 0), parsed.footer.len);

    // Five columns, the ones a one-op change on the root map has: a string
    // key, insert, the action, the value metadata, and an empty predecessor
    // group. Read them by name.
    const expected = [_]struct { col: OpColumn, spec: ColumnSpec, bytes: []const u8 }{
        .{ .col = .key_string, .spec = ColumnSpec.make(1, .string, false), .bytes = &[_]u8{ 0x7f, 0x01, 0x61 } },
        .{ .col = .insert, .spec = ColumnSpec.make(3, .boolean, false), .bytes = &[_]u8{0x01} },
        .{ .col = .action, .spec = ColumnSpec.make(4, .rle_uint, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
        .{ .col = .value_metadata, .spec = ColumnSpec.make(5, .value_metadata, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
        .{ .col = .pred_group, .spec = ColumnSpec.make(7, .group, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
    };
    try testing.expectEqual(expected.len, parsed.opCount());
    var it = parsed.ops.iterator();
    for (expected) |want| {
        const col = it.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(want.spec.raw, col.spec.raw);
        try testing.expectEqualSlices(u8, want.bytes, try col.bytes(parsed.opData()));
        // The same column, found by name and by specification.
        try testing.expectEqualSlices(u8, want.bytes, (try parsed.opBytes(want.col)).?);
        try testing.expectEqualSlices(u8, want.bytes, (try parsed.bytesFor(want.spec)).?);
    }
    try testing.expect(it.next() == null);

    // The columns a one-op root change does not have are absent, and absent is
    // not an error.
    try testing.expect((try parsed.opBytes(.obj_actor)) == null);
    try testing.expect((try parsed.opBytes(.obj_counter)) == null);
    try testing.expect((try parsed.opBytes(.pred_actor)) == null);
    try testing.expect((try parsed.opBytes(.pred_counter)) == null);
    // The value payload is absent because the value is empty
    // (`change_op_columns.rs:332-336`).
    try testing.expect((try parsed.opBytes(.value)) == null);
}

test "a change with an object column and a value payload reads every column" {
    const gpa = testing.allocator;
    var parsed = try parseChangeChunk(&fixture_second_body, gpa);
    defer parsed.deinit(gpa);

    // The second fixture chunk depends on the first.
    try testing.expectEqual(@as(usize, 1), parsed.change.deps.len);
    try testing.expectEqual(@as(u64, 2), parsed.change.seq);
    try testing.expectEqual(@as(u64, 2), parsed.change.start_op);
    try testing.expectEqualStrings("change 2", parsed.change.message);
    try testing.expectEqual(@as(usize, 68), parsed.change.header_len);

    // Eight columns, in ascending specification order, with the data block
    // exactly as automerge laid it out.
    const expected = [_]struct { col: OpColumn, spec: ColumnSpec, bytes: []const u8 }{
        .{ .col = .obj_actor, .spec = ColumnSpec.make(0, .actor, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
        .{ .col = .obj_counter, .spec = ColumnSpec.make(0, .rle_uint, false), .bytes = &[_]u8{ 0x7f, 0x01 } },
        .{ .col = .key_string, .spec = ColumnSpec.make(1, .string, false), .bytes = &[_]u8{ 0x7f, 0x01, 0x61 } },
        .{ .col = .insert, .spec = ColumnSpec.make(3, .boolean, false), .bytes = &[_]u8{0x01} },
        .{ .col = .action, .spec = ColumnSpec.make(4, .rle_uint, false), .bytes = &[_]u8{ 0x7f, 0x01 } },
        .{ .col = .value_metadata, .spec = ColumnSpec.make(5, .value_metadata, false), .bytes = &[_]u8{ 0x7f, 0x16 } },
        .{ .col = .value, .spec = ColumnSpec.make(5, .value, false), .bytes = &[_]u8{0x62} },
        .{ .col = .pred_group, .spec = ColumnSpec.make(7, .group, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
    };
    try testing.expectEqual(expected.len, parsed.opCount());
    try testing.expectEqual(@as(usize, 15), parsed.opData().len);
    try testing.expectEqual(@as(usize, 0), parsed.footer.len);

    // The data block is the columns' bytes back to back, in order, so the
    // expected columns concatenate to exactly it.
    var expect_data: [15]u8 = undefined;
    var at: usize = 0;
    var it = parsed.ops.iterator();
    for (expected) |want| {
        const col = it.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(want.col, OpColumn.fromSpec(col.spec) orelse error.TestUnexpectedResult);
        try testing.expectEqual(want.spec.raw, col.spec.raw);
        const bytes = try col.bytes(parsed.opData());
        @memcpy(expect_data[at .. at + bytes.len], bytes);
        at += bytes.len;
    }
    try testing.expect(at);
    try testing.expectEqualSlices(u8, &expect_data, parsed.opData());
    try testing.expect(it.next() == null);

    // A two-op change still has no expand or mark_name column, and no
    // predecessor value columns: the group says every op has no predecessors.
    try testing.expect((try parsed.opBytes(.expand)) == null);
    try testing.expect((try parsed.opBytes(.mark_name)) == null);
    try testing.expect((try parsed.opBytes(.pred_actor)) == null);
}

test "a written body reads back with the same column specifications and bytes" {
    const gpa = testing.allocator;
    // Both fixture bodies, in both roles. The written body is compared to the
    // bytes automerge wrote, so the writer is pinned against the reference
    // implementation and not merely against the reader that shares its
    // assumptions.
    for ([_][]const u8{ &fixture_first_body, &fixture_second_body }) |body| {
        var parsed = try parseChangeChunk(body, gpa);
        defer parsed.deinit(gpa);

        // The values the writer takes: the change's own fields, the op
        // columns, and the footer.
        const ops = OpsBlock.init(parsed.ops, parsed.footer);
        const encoded = try encode(gpa, parsed.change, ops);
        defer encoded.deinit(gpa);

        // The body is the bytes it came from: header, metadata, data, footer.
        try testing.expectEqualSlices(u8, body, encoded.body);

        // And the hash and checksum are the ones the fixture's chunk header
        // stores, computed independently of the writer.
        try testing.expectEqual(chunk.changeHashOf(.change, body), encoded.hash);
        try testing.expectEqualSlices(u8, &encoded.hash.checksum(), &encoded.checksum);
    }
}

test "an empty change round trips with no columns and no footer" {
    const gpa = testing.allocator;
    // A change with no operations: a commit that touched nothing. Upstream
    // writes a column count of zero and no data (`raw_column.rs:183`), and the
    // reader must read that back as an empty, valid op block.
    const actor = [_]u8{0xaa};
    const header = try change_mod.parseChange(&[_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x05, // start_op 5
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
        0x00, // no op columns
    }, gpa);
    defer header.deinit(gpa);

    // Write it: header, a column count of zero, no data, no footer.
    const encoded = try encode(gpa, header, OpsBlock.empty());
    defer encoded.deinit(gpa);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x01, 0xaa, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00,
    }, encoded.body);

    // Read it back: the same change, with an empty op block.
    var parsed = try parseChangeChunk(encoded.body, gpa);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), parsed.opCount());
    try testing.expect(parsed.ops.isEmpty());
    try testing.expectEqual(@as(usize, 0), parsed.opData().len);
    try testing.expectEqual(@as(usize, 0), parsed.footer.len);
    try testing.expectEqualSlices(u8, &actor, parsed.change.actor.bytes);
    try testing.expectEqual(@as(u64, 1), parsed.change.seq);
    try testing.expectEqual(@as(u64, 5), parsed.change.start_op);
    // The op count is zero, so `max_op` is `start_op - 1` — a value the format
    // permits for a change with no ops.
    try testing.expectEqual(@as(u64, 4), (try parsed.change.withOpCount(0)).max_op);

    // And re-encoding it is the same body.
    const again = try encodeBody(gpa, parsed.change, OpsBlock.init(parsed.ops, parsed.footer));
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, encoded.body, again);
}

test "the author footer survives a round trip byte for byte" {
    const gpa = testing.allocator;
    // The footer is whatever is left after the op data, and the only payload
    // the format defines in it is the author footer
    // `uleb(id=1) || uleb(len) || bytes` (`change.rs:365-403`). A reader
    // returns those bytes untouched and a writer puts them back untouched, so
    // a footer automerge wrote is a footer this port writes.
    const footer = [_]u8{ 0x01, 0x05, 'j', 'a', 'n', 'i', 's' };

    // A change with one column and this footer. The op block is the metadata
    // block for one action column, the column's two bytes, then the footer.
    const head = [_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
    };
    const descs = [_]ColumnDesc{ColumnDesc.init(ColumnSpec.make(4, .rle_uint, false), 2)};
    const data = [_]u8{ 0x7f, 0x00 };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &head);
    const cols = try RawColumns.init(gpa, &descs, &data);
    defer cols.deinit(gpa);
    try writeOpsBlock(&body, gpa, OpsBlock.init(cols, &footer));

    // Read it: the footer is there, exactly.
    var parsed = try parseChangeChunk(body.items, gpa);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), parsed.opCount());
    try testing.expectEqualSlices(u8, &data, parsed.opData());
    try testing.expectEqualSlices(u8, &footer, parsed.footer);

    // Write it back: the same footer, after the same columns.
    const encoded = try encode(gpa, parsed.change, OpsBlock.init(parsed.ops, parsed.footer));
    defer encoded.deinit(gpa);
    try testing.expectEqualSlices(u8, body.items, encoded.body);
    try testing.expectEqualSlices(u8, &footer, encoded.body[encoded.body.len - footer.len ..]);

    // Change the footer's bytes and only the footer changes: it is the last
    // thing in the body, and nothing in the header or the columns depends on
    // it.
    var other: [body.items.len]u8 = body.items;
    const at = other.len - footer.len;
    other[at + 3] = 'J';
    var re_parsed = try parseChangeChunk(&other, gpa);
    defer re_parsed.deinit(gpa);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x05, 'j', 'a', 'J', 'i', 's' }, re_parsed.footer);
    try testing.expectEqualSlices(u8, &data, re_parsed.opData());
    // The change hash covers the footer, so a different footer is a different
    // change: same columns, different hash.
    try testing.expect(!encoded.hash.eql(chunk.changeHashOf(.change, &other)));
}

test "a truncated metadata block is refused" {
    const gpa = testing.allocator;
    // The op block of the first fixture, cut short. The header is intact, so
    // the count is read, and then the block runs out.
    const head: []const u8 = fixture_first_body[0..36];

    // The count says five columns but only two descriptors are there. The
    // count is larger than the remaining input could hold, so it is refused
    // before the count sizes anything.
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunk(head[0..41], gpa),
    );

    // All five descriptors, then a data block that starts but does not
    // complete is a data-block failure, not a metadata one; here instead the
    // fifth descriptor's length is cut off mid-LEB128, so the descriptor
    // itself is truncated and `takeUleb` reports the end of the input.
    var cut = [_]u8{ head.*, 0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x80 };
    try testing.expectError(error.UnexpectedEnd, parseChangeChunk(&cut, gpa));

    // A metadata block cut off before its count is a header failure, and the
    // count byte is not there at all.
    try testing.expectError(error.UnexpectedEnd, parseChangeChunk(head[0..35], gpa));
}

test "a truncated data block is refused" {
    const gpa = testing.allocator;
    // The first fixture's op block, with the data block cut short. The
    // metadata block is complete: five columns declaring ten bytes of data.
    const head: []const u8 = fixture_first_body[0..36];
    const meta: []const u8 = fixture_first_body[36..47];

    // Zero of the ten data bytes present.
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunk(head[0..47], gpa),
    );

    // Some of them: nine declared bytes, ten present. Still short, still
    // refused before the data is taken.
    var nine: [head.len + 9]u8 = undefined;
    @memcpy(nine[0..head.len], head);
    @memcpy(nine[head.len..], meta[0..9]);
    try testing.expectError(error.LengthExceedsInput, parseChangeChunk(&nine, gpa));

    // The last byte of the data block is missing, so the body ends one byte
    // early. The declared total is larger than what is left.
    var ten: [fixture_first_body.len - 1]u8 = undefined;
    @memcpy(&ten, fixture_first_body[0 .. fixture_first_body.len - 1]);
    try testing.expectError(error.LengthExceedsInput, parseChangeChunk(&ten, gpa));
}

test "a column whose declared length runs past the data block is refused" {
    const gpa = testing.allocator;
    // A change chunk whose single column declares more bytes than the data
    // block has. The data block is the sum of the declared lengths, so a
    // length past the end of the block is a length past the end of the body:
    // it is caught as `LengthExceedsInput` before the block is taken, and a
    // hostile length costs a comparison rather than a read.
    const head = [_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
        0x01, // one column
        0x42, // the action column
    };

    // A length of ten with three bytes of data.
    var body: [head.len + 11]u8 = undefined;
    @memcpy(body[0..head.len], &head);
    body[head.len] = 0x0a; // the column's declared length
    @memcpy(body[head.len + 1 ..], &[_]u8{ 0x7f, 0x00, 0x7f });
    try testing.expectError(error.LengthExceedsInput, parseChangeChunk(&body, gpa));

    // A length of zero with a byte of data. The declared block is empty, so
    // what follows is the footer, and the reader does not reach into it for
    // the column — it takes the zero bytes the column declares and the one
    // byte is the footer.
    var zero: [head.len + 1]u8 = undefined;
    @memcpy(zero[0..head.len], &head);
    zero[head.len] = 0x00;
    var parsed = try parseChangeChunk(&zero, gpa);
    defer parsed.deinit(gpa);
    // A zero-length column is dropped, as upstream drops it
    // (`raw_column.rs:40-50`), so the block is empty and the trailing byte is
    // the footer.
    try testing.expectEqual(@as(usize, 0), parsed.opCount());
    try testing.expectEqual(@as(usize, 0), parsed.opData().len);
    try testing.expectEqualSlices(u8, &[_]u8{}, parsed.footer);
    // With nothing to index, the column is not findable.
    try testing.expect((try parsed.bytesFor(ColumnSpec.make(4, .rle_uint, false))) == null);

    // And a length that is absurd — every bit set, the maximum a u64 length
    // can hold — is still refused as too large for the input, not treated as a
    // number to allocate.
    var huge: [head.len + 11]u8 = undefined;
    @memcpy(huge[0..head.len], &head);
    huge[head.len] = 0xff;
    @memset(huge[head.len + 1 ..], 0xff);
    try testing.expectError(error.LengthExceedsInput, parseChangeChunk(&huge, gpa));
}

test "a change with a compressed column is refused" {
    const gpa = testing.allocator;
    // A change chunk's columns are never deflated. Upstream refuses the whole
    // chunk with `CompressedChangeCols` (`storage/change.rs:129-131`); this
    // port reports `InvalidColumnSpec`, because a deflated column is a
    // specification a change chunk does not define.
    const head = [_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
        0x01, // one column
    };
    var body: [head.len + 3]u8 = undefined;
    @memcpy(body[0..head.len], &head);
    // 0x4a is the action column with the DEFLATE bit set.
    body[head.len] = 0x4a;
    body[head.len + 1] = 0x02;
    @memcpy(body[head.len + 2 ..], &[_]u8{ 0x7f, 0x00 });
    try testing.expectError(error.InvalidColumnSpec, parseChangeChunk(&body, gpa));
}

test "columns out of order or repeated are refused" {
    const gpa = testing.allocator;
    const head: []const u8 = fixture_first_body[0..36];

    // The action column before the key column: descending by specification.
    // Upstream refuses a set that is not in ascending normalized order
    // (`raw_column.rs:248-253`).
    var unsorted: [fixture_first_body.len]u8 = fixture_first_body;
    // Positions 37 and 38 are the first descriptor (key string, length 3);
    // positions 41 and 42 are the third (action, length 2). Swap the two
    // descriptors and their data so the set is well formed except for its
    // order.
    @memcpy(unsorted[37..40], &[_]u8{ 0x42, 0x02, 0x56 });
    @memcpy(unsorted[41..44], &[_]u8{ 0x15, 0x03, 0x34 });
    // The data block: the two swapped columns' bytes follow the descriptors.
    @memcpy(unsorted[47..50], &[_]u8{ 0x7f, 0x00, 0x01 });
    @memcpy(unsorted[51..54], &[_]u8{ 0x7f, 0x01, 0x61 });
    try testing.expectError(error.InvalidColumnSpec, parseChangeChunk(&unsorted, gpa));

    // The same column twice. Upstream rejects a duplicate specification
    // (`columns.rs:203-210`); the DEFLATE bit is ignored when comparing, so a
    // document that carries the same column both ways is refused too.
    var duplicated: [head.len + 4]u8 = undefined;
    @memcpy(duplicated[0..head.len], head);
    @memcpy(duplicated[head.len..], &[_]u8{
        0x02, // two columns
        0x42, 0x02, // the action column
        0x42, 0x02, // and itself again
    });
    @memcpy(duplicated[head.len + 4 ..], &[_]u8{ 0x7f, 0x00, 0x7f, 0x00 });
    try testing.expectError(error.DuplicateColumn, parseChangeChunk(&duplicated, gpa));
}

test "a compressed change chunk is inflated and checked before it is read" {
    const gpa = testing.allocator;

    // Compress the first fixture's change chunk. The stored checksum is the
    // checksum of the inflated body hashed as a change chunk, and only the
    // data is deflated (`change/compressed.rs:18-34`).
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunk.compressChunk(&framed, gpa, &fixture_first_body);
    try testing.expectEqual(@as(u8, 0x02), framed.items[8]);

    // `parseChunk` does not verify a compressed chunk's checksum, because it
    // cannot without inflating; it hands the deflated data back as it stands.
    const c = try chunk.parseChunk(framed.items);
    try testing.expectEqual(chunk.ChunkType.compressed, c.typ);

    // The compressed path: the body is inflated, the checksum verified against
    // the header, and then the columns read are the ones automerge wrote.
    var owned = try parseFramedChunk(c, gpa);
    defer owned.deinit(gpa);
    try testing.expect(owned.inflated != null);
    try testing.expectEqualSlices(u8, &fixture_first_body, owned.parsed.opData()[0..0][0..0][0..0]); // no-op
    try testing.expectEqual(@as(usize, 5), owned.parsed.opCount());
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x01, 0x61 }, (try owned.parsed.opBytes(.key_string)).?);
    try testing.expectEqual(@as(u64, 1), owned.parsed.change.seq);
    try testing.expectEqualSlices(u8, "change 1", owned.parsed.change.message);

    // The inflated body is owned and freed by `deinit`; the columns point into
    // it, so a column's bytes are the fixture's bytes.
    const inflated = owned.inflated.?;
    try testing.expectEqualSlices(u8, &fixture_first_body, inflated);
    try testing.expect(owned.parsed.change.bytes.ptr == inflated.ptr);

    // A compressed chunk whose body has been altered fails the checksum check
    // in `decompressChunk`, before any column is read. `parseChunk` alone would
    // not have caught it: that is the whole reason the compressed path goes
    // through `decompressChunk`.
    var tampered: [fixture_first_body.len]u8 = fixture_first_body;
    tampered[fixture_first_body.len - 1] ^= 0x01;
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(gpa);
    try chunk.compressChunk(&bad, gpa, &tampered);
    // Restore the checksum the framing expects for the untampered body, so
    // the only thing wrong is the body the checksum covers.
    @memcpy(bad.items[4..8], &chunk.checksumOf(.change, &fixture_first_body));
    const bad_chunk = try chunk.parseChunk(bad.items);
    try testing.expectError(error.InvalidChecksum, parseFramedChunk(bad_chunk, gpa));

    // A change chunk of the plain kind borrows its body and owns only its two
    // lists.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try chunk.writeChunk(&plain, gpa, .change, &fixture_first_body);
    var borrowed = try parseFramedChunk(try chunk.parseChunk(plain.items), gpa);
    defer borrowed.deinit(gpa);
    try testing.expect(borrowed.inflated == null);
    try testing.expect(borrowed.parsed.change.bytes.ptr == plain.items.ptr + 10);
}

test "a chunk that is not a change is refused" {
    const gpa = testing.allocator;
    // A document chunk holds no single change, and neither does a bundle's
    // framing from this reader's point of view: both are `InvalidChunkType`.
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    try chunk.writeChunk(&doc, gpa, .document, &fixture_first_body);
    try testing.expectError(
        error.InvalidChunkType,
        parseFramedChunk(try chunk.parseChunk(doc.items), gpa),
    );

    var bundle: std.ArrayList(u8) = .empty;
    defer bundle.deinit(gpa);
    try chunk.writeChunk(&bundle, gpa, .bundle, &fixture_first_body);
    try testing.expectError(
        error.InvalidChunkType,
        parseFramedChunk(try chunk.parseChunk(bundle.items), gpa),
    );
}
