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
//! object columns are an empty range, and so absent, for an all-root change
//! (`change_op_columns.rs:296-306`, dropped at `:183`), and the value, expand,
//! mark-name and predecessor-value columns are omitted when empty
//! (`:332-365`). So the set is a vocabulary, not a template, and a reader must
//! treat an absent column as absent rather than as an error. A column a change
//! has never heard of is likewise not an error: the reader keeps it and the op
//! decoder parks it in `other` (`:548-551`).
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
//! defers exactly that case.
//! `parseFramedChunk` is the only way in from a framed chunk, and it routes
//! every compressed body through `chunk.decompressChunkWithHash`, which
//! inflates it, verifies it against the header, and hands back the change hash
//! it had to compute for that comparison — so the change built from it records
//! that hash instead of hashing the same inflated bytes again. A body read from
//! a `change` chunk gets the same treatment from the other end:
//! `chunk.readChunk` already hashed it to check its checksum, and that hash
//! travels on [`Chunk`](chunk.zig)'s `hash` field.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const rle = @import("../hexane/rle.zig");
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
///
/// Copying this is copying a value with no allocation and no borrow in it, so
/// a copy is independent and either may be read from another thread.
pub const OpColumn = enum(u8) {
    /// The actor index of the object the op acts on. `OBJ_COL_ID` is 0
    /// (`change_op_columns.rs:29`), and the decoder pairs it with
    /// `ColumnType::Actor` (`:496`).
    obj_actor = 0,
    /// The op counter of the object the op acts on, run-length encoded: the
    /// same id with `ColumnType::Integer` (`:497`).
    obj_counter = 1,
    /// The actor half of the op's key, null for a string key.
    /// `KEY_COL_ID` is 1 (`change_op_columns.rs:30`), paired with
    /// `ColumnType::Actor` (`:498`).
    key_actor = 2,
    /// The counter half of the op's key, delta-encoded (`:499`).
    key_counter = 3,
    /// The string half of the op's key, null for an object key (`:500`).
    key_string = 4,
    /// Whether the op inserts rather than overwrites. `INSERT_COL_ID` is 3
    /// (`change_op_columns.rs:31`), paired with `ColumnType::Boolean` (`:501`).
    insert = 5,
    /// The op's action, run-length encoded: an action is a code, not a
    /// counter, so it is `ColumnType::Integer` and not a delta. `ACTION_COL_ID`
    /// is 4 (`change_op_columns.rs:32`, `:502`).
    action = 6,
    /// The metadata word of the op's value, with the value's own type code and
    /// length bookkeeping. `VAL_COL_ID` is 5 (`change_op_columns.rs:33`),
    /// paired with `ColumnType::ValueMetadata` (`:503-508`).
    value_metadata = 7,
    /// The op's value payload, read according to the sibling metadata column.
    /// The writer emits it as the same id with `ColumnType::Value` (`:334`)
    /// and only when the payload is not empty (`:332-337`); the decoder has no
    /// arm for it and parks it as an unrecognised column (`:548-551`).
    value = 8,
    /// One count per op: how many predecessors that op has, as a group
    /// column. `PRED_COL_ID` is 7 (`change_op_columns.rs:34`), paired with
    /// `ColumnType::Group` (`:509-512`).
    pred_group = 9,
    /// The actor indices of the predecessors of every op, flattened across the
    /// group, run-length encoded: the actor half of the group member pair
    /// (`:523-525`).
    pred_actor = 10,
    /// The counters of the predecessors of every op, flattened and
    /// delta-encoded, which is why the writer requires the predecessors of an
    /// op in ascending order (`change_actors.rs:79-81`). The counter half of
    /// the group member pair (`change_op_columns.rs:526-527`).
    pred_counter = 11,
    /// Whether the op is an expanded mark, bit-packed. `EXPAND_COL_ID` is 9
    /// (`change_op_columns.rs:35`), paired with `ColumnType::Boolean` (`:546`).
    expand = 12,
    /// The name of the mark the op creates, as a string column.
    /// `MARK_NAME_COL_ID` is 10 (`change_op_columns.rs:36`), paired with
    /// `ColumnType::String` (`:547`).
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
        const op_row = self.row();
        return ColumnSpec.make(op_row.col_id, op_row.enc, false);
    }

    /// The column's name, which is the name upstream gives the value it holds.
    pub fn name(self: OpColumn) []const u8 {
        return @tagName(self);
    }

    /// The column with this name, or null when no column of a change chunk
    /// carries it. Names are the enum tags, so a lookup is a compile-time
    /// string comparison rather than a scan of the table.
    pub fn fromName(col_name: []const u8) ?OpColumn {
        return std.meta.stringToEnum(OpColumn, col_name);
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
    pub fn fromSpec(col_spec: ColumnSpec) ?OpColumn {
        const want = col_spec.normalize();
        for (op_column_table) |entry| {
            if (ColumnSpec.make(entry.col_id, entry.enc, false).eql(want)) return entry.tag;
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
/// read and written with (`:496-547` and `:291-367`). Nothing here is
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
///
/// Copying this is copying a view: the copy shares the column list and the data
/// block, so neither may outlive the body the list indexes. Neither field is
/// mutable, so the copy may be read from another thread while the original
/// lives.
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
///
/// **Copying this copies an owner.** A copy holds the same `other_actors` array
/// and the same column list, and `deinit` on both frees each a second time, so
/// exactly one copy may be torn down. Nothing here is mutated after the parse
/// returns, so the value may be read from another thread while it lives.
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
    ///
    /// After this the struct is poisoned, not emptied: `self.*` is set to
    /// undefined, so reading any field afterwards is a use of undefined memory.
    /// One call per value, and — because a copy is a second owner — one call per
    /// copy.
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

    /// How many operations the change carries: the **row** count of the op
    /// columns, which is the number upstream's `StoredChange::len()` reports
    /// and the number `Change::max_op()` is derived from — `start_op + len - 1`
    /// ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs)).
    ///
    /// **Rows, not columns.** The two are not the same number and the
    /// difference is not visible on a one-op change: a one-op change on the
    /// root map carries five columns and one operation
    /// ([`change_op_columns.rs:291-331`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)),
    /// so a reader that answers with `ops.len()` is right by accident for a
    /// large op and wrong for every other one. Upstream cannot be wrong this
    /// way: a `Change` counts its ops as they are decoded —
    /// `stored.verify_ops(|_| len += 1)` ([`change.rs:34-35`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    /// so `len` is a row count by construction — and `AMchangeSize` returns
    /// exactly that ([`automerge-c/src/change.rs:294-299`](../../github-automerge-automerge/rust/automerge-c/src/change.rs)).
    ///
    /// The row count is the length of the **action column**, which every
    /// written change carries ([`change_op_columns.rs:323-326`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs))
    /// and which is what ends the op walk upstream —
    /// `self.action.done()` ([`change_op_columns.rs:396-397`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)).
    /// It is run-length encoded, so the count walks the runs rather than the
    /// values: a hostile column claiming `maxSlabLen` rows costs one pass over
    /// its runs, not `maxSlabLen` steps. A change with no ops carries no
    /// columns at all — an empty range is dropped from a column set
    /// ([`raw_column.rs:40-50`](../../github-automerge-automerge/rust/automerge/src/columnar/columns/raw_column.rs)) —
    /// and so counts zero, which is also the answer for a change whose action
    /// column is absent.
    ///
    /// What this is for: `Change.withOpCount` ([`change.zig:151-170`](../../change.zig))
    /// is how `max_op` is filled in, and the change carries no op count
    /// anywhere in its header ([`storage/change.rs:104-111`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs)).
    pub fn opCount(self: ChangeChunk) ParseError!usize {
        const spec = OpColumn.action.spec();
        const bytes = (try self.ops.bytesFor(spec)) orelse return 0;
        return rle.RleOption(u64).countEntries(bytes);
    }
};

/// A parsed change chunk that owns the body it was read from, for the case
/// where the chunk arrived deflated and had to be inflated before it could be
/// parsed. `chunk.decompressChunk` returns a buffer the caller owns, and every
/// slice a `ChangeChunk` holds points into it, so the two have the same
/// lifetime.
///
/// **Copying this copies an owner** — the inflated body and, through `parsed`,
/// the `other_actors` array and the column list — so exactly one copy may be
/// torn down. Nothing here is mutated after the parse returns.
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
    ///
    /// After this the struct is poisoned, not emptied, for the reason
    /// [`ChangeChunk.deinit`] gives. One call per value, and one call per copy.
    pub fn deinit(self: *OwnedChangeChunk, gpa: Allocator) void {
        if (self.inflated) |body| gpa.free(body);
        self.parsed.deinit(gpa);
        self.* = undefined;
    }
};

/// A change chunk body as written, with the identity the framing stores.
///
/// **Copying this copies an owner**: the copy holds the same body and one
/// `deinit` per copy is one free, so exactly one copy may be torn down.
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

    /// Frees the body and leaves `body` an empty slice, which is why a second
    /// call frees nothing: `hash` and `checksum` are values rather than views
    /// and stay readable afterwards. The rest of the value is untouched, so this
    /// is a release rather than a poison — the difference from the two teardowns
    /// beside it, which set their structs to undefined.
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
///   (`columns.rs:193-198`). **The order is judged over the descriptors as
///   they were read**, zero-length ones included, which is the set upstream
///   compares; the duplicate is judged over the columns that survived
///   construction, so a block that repeats an *empty* specification is not a
///   duplicate and is accepted, as upstream accepts it.
pub fn parseChangeChunk(body: []const u8, gpa: Allocator) ParseError!ChangeChunk {
    return parseChangeChunkWithHash(body, gpa, null);
}

/// [`parseChangeChunk`] with the change hash the caller already holds, which is
/// the seam between the chunk layer's one SHA-256 and the header reader below.
///
/// `hash` must be `chunk.changeHashOf(.change, body)` — the whole thirty-two
/// bytes over `body` framed as a `change` chunk. That is what
/// [`Chunk`](chunk.zig)'s `hash` field carries for a chunk of that type, and
/// what [`decompressChunkWithHash`](chunk.zig) hands back for a compressed
/// one, which is how a caller reading a framed chunk gets it without hashing
/// the body a second time.
///
/// **A null `hash` is not a different answer, it is no answer**: the hash is
/// taken where [`parseChange`] has always taken it, after the header has
/// parsed, so a refused body costs no SHA-256 under either spelling.
///
/// **Nothing here compares `hash` against `body`,** and that is the same
/// bargain [`change.parseChangeWithHash`] documents: the checksum comparison in
/// `chunk.readChunk` — or, for a compressed chunk, in
/// [`decompressChunkWithHash`](chunk.zig) — has already been made over these
/// very bytes, so a hash supplied here can only be the right one or a caller
/// error. This function is unchanged in every other respect: the same header
/// read, the same column metadata block, the same refusals in the same order.
pub fn parseChangeChunkWithHash(
    body: []const u8,
    gpa: Allocator,
    hash: ?ChangeHash,
) ParseError!ChangeChunk {
    // The header reader owns the fields; this module needs only where it
    // ended. `header_len` is where the op metadata block starts, and the whole
    // body is what the change hash was taken over.
    var change = try change_mod.parseChangeWithHash(body, gpa, hash);
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

    // Order over the descriptors as they were read, *before* `RawColumns.init`
    // drops the zero-length ones (`column_spec.zig:432-437`). Upstream's set
    // keeps every descriptor the block listed, empty ones included, and
    // `are_normal_sorted` runs over that whole set (`raw_column.rs:232-253`,
    // `:289-297`), so a block whose first column is empty still has to be
    // ascending from there. Checking the set that comes back instead would let
    // `{0x42 len 0, 0x15 len 3}` through: 0x42 is gone by then and 0x15 is the
    // only column left to be in order. This is where upstream puts the check
    // too — inside the metadata block's own parse, before the data block is
    // located — so it runs before the length bound below and the error a
    // malformed change chunk carries is the one the reference reports.
    try descsInNormalOrder(descs);

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

/// The block's descriptors, in ascending normalized order, or
/// `error.InvalidColumnSpec`.
///
/// The whole set takes part, zero-length descriptors included, because upstream
/// compares the columns the metadata block listed rather than the columns that
/// survived construction (`raw_column.rs:232-253`, `:289-297`). A repeat is not
/// a decrease and so passes here; `RawColumns.validate` is what reports one, as
/// `error.DuplicateColumn`, after the empty columns are gone.
fn descsInNormalOrder(descs: []const ColumnDesc) ParseError!void {
    var previous: ?ColumnSpec = null;
    for (descs) |desc| {
        if (previous) |prev| {
            if (desc.spec.compare(prev) == .lt) return error.InvalidColumnSpec;
        }
        previous = desc.spec;
    }
}

/// Reads a change chunk out of a framed chunk, inflating first if the chunk is
/// a `ChunkType.compressed` one.
///
/// A `change` chunk is read in place, from the caller's bytes. A `compressed`
/// chunk is inflated through `chunk.decompressChunkWithHash`, which is the only
/// place a compressed chunk's checksum can be checked: the stored checksum is
/// the checksum of the inflated body hashed as a change chunk
/// (`chunk.rs:118-122`), and `chunk.parseChunk` deliberately does not verify
/// that case. So a body read this way has been verified, and a body read from
/// a `change` chunk was verified when the chunk was parsed.
///
/// **Either way the change is handed the hash of the body it was read from,
/// and neither body is hashed twice.** For a `change` chunk that hash is
/// `Chunk.hash`, taken by `chunk.readChunk` for the comparison it had to make;
/// for a compressed one it is the hash `decompressChunkWithHash` took over the
/// inflated bytes for the comparison it had to make. Both are handed to
/// [`parseChangeChunkWithHash`], which records them verbatim, so the change this
/// returns carries the same identity as the one the old spelling reached by
/// hashing for itself — and the difference between the two is one SHA-256 pass
/// over the body rather than two.
///
/// A `document` or `bundle` chunk is `error.InvalidChunkType`: those hold no
/// single change.
pub fn parseFramedChunk(c: chunk.Chunk, gpa: Allocator) ParseError!OwnedChangeChunk {
    switch (c.typ) {
        .change => {
            // **`c.hash` is the hash `readChunk` already took over `c.data`.**
            // It is passed through rather than unwrapped with `.?`: null here
            // means a caller handed over a hand-built chunk, and null is what
            // `parseChangeChunk` has always passed, so that caller gets the
            // answer it got before rather than a trap.
            const parsed = try parseChangeChunkWithHash(c.data, gpa, c.hash);
            return .{ .inflated = null, .parsed = parsed };
        },
        .compressed => {
            // The checksum is verified here, before the inflated bytes are
            // handed to a body parser, which is the whole reason this path
            // goes through `decompressChunkWithHash` and not `decompressRaw`.
            //
            // **The hash rides out with the body.** This is the only place the
            // inflated bytes are ever hashed — the stored checksum covers
            // exactly them — so handing that hash to the body parser is what
            // keeps a compressed change from hashing itself twice.
            const inflated = try chunk.decompressChunkWithHash(gpa, c);
            errdefer gpa.free(inflated.body);
            const parsed = try parseChangeChunkWithHash(inflated.body, gpa, inflated.hash);
            return .{ .inflated = inflated.body, .parsed = parsed };
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
/// which names a deflated column, has a bug the format cannot express, and the
/// writer checks it with `std.debug.assert` because a silently wrong body would
/// be a change with the wrong hash and no reader would notice.
///
/// **Those two checks are programmer preconditions on a caller's own set, not
/// checks on untrusted input, and `std.debug.assert` is compiled out in
/// `ReleaseFast` and `ReleaseSmall`.** In those modes a descending or repeated
/// specification and a deflated column are written out unchecked, and the body
/// this function produces is one [`parseChangeChunk`] then refuses as
/// `error.InvalidColumnSpec` or `error.DuplicateColumn`. The document chunk
/// writer checks the same two things with real errors that survive every
/// optimize mode (`document_chunk.writeColumnMeta`); this one does not, and a
/// caller that builds change op sets by hand is the only one that can tell.
///
/// The order check is strict (`prev < col`), so it catches a repeat as well as
/// a descent.
pub fn writeOpsBlock(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    ops: OpsBlock,
) Allocator.Error!void {
    // The count leads the metadata block, so it cannot be known until every
    // column that will be written has been counted. One pass counts; a second
    // writes. Upstream writes the count from `self.0.len()` directly
    // (`raw_column.rs:259`) because it drops empty columns at construction;
    // here a column is dropped at write time, so the count is computed from
    // the same filter the write uses.
    var written: usize = 0;
    for (ops.cols.columns) |col| {
        if (col.isEmpty()) continue;
        written += 1;
    }
    try leb128.appendUnsigned(out, gpa, written);

    // The last specification actually written, so the order check below
    // compares two written columns rather than indexing back into the set.
    var previous: ?ColumnSpec = null;
    for (ops.cols.columns) |col| {
        if (col.isEmpty()) continue;
        // A deflated column in a change chunk is not a thing this writer can
        // produce: the bytes would be a raw DEFLATE stream the reader has just
        // been told not to expect. Refuse it here rather than write a body no
        // reader of this format accepts.
        std.debug.assert(!col.spec.isCompressed());
        // Order is not checked by the reader of this set before it is written —
        // it is a property of the caller's set, and the writer emits what it
        // is given — but a descending specification would be a body
        // `parseChangeChunk` rejects, so it is worth catching at the source. A
        // set of one column is trivially ordered.
        if (previous) |prev| {
            const prev_spec = ColumnSpec.make(prev.id(), prev.encoding(), false);
            std.debug.assert(prev_spec.lessThan(col.spec));
        }
        try leb128.appendUnsigned(out, gpa, col.spec.raw);
        try leb128.appendUnsigned(out, gpa, col.len());
        previous = col.spec;
    }

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
/// byte, then the body's length as LEB128, then the body (`chunk.rs:302-312`).
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
            // A zero-length allocation is legal and freeable, and it keeps
            // `descs` non-null once the block has been read, so the caller
            // never has to tell "no columns" from "not read yet". It can still
            // fail, and `ParseError` carries `OutOfMemory` for that.
            self.descs = try self.gpa.alloc(ColumnDesc, 0);
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
// predecessor group with no predecessors — and 57 bytes of body: a 36-byte
// header, 11 bytes of metadata (a count of five plus five two-byte
// descriptors), 10 of data, and no footer. It is here so this port's reader is
// pinned to bytes automerge wrote, not to bytes this port wrote.
const fixture_first_body = [_]u8{
    0x00, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83,
    0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00,
    0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f,
    0x01, 0x61, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00,
};

// The body of the second change chunk in the same fixture: the same author at
// seq 2, depending on the first change, with one operation. The op block is
// eight columns, including the object columns a root change does not have and
// a value payload — a `set` of the key "a" to the one-byte string "b" on the
// object at counter 1 — so this is a pair of numbers the row count and the
// column count do not agree on.
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
    // `ColumnType` each is read and written with (`:496-547`); the raw word is
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

test "each column's wire word decodes to the column the table names" {
    // The same fourteen pairs as the test above, from the reader's direction.
    // The literal here is the word as it stands in the metadata block, before
    // uLEB128 encoding, and the column has to be recovered from it — the table
    // test starts from the table and builds the word, this one starts from the
    // word and decodes it, so a decoder that read the wrong field fails here
    // even when the writer would have produced the right bytes.
    //
    // The packing is `id << 4 | encoding` with the DEFLATE bit clear
    // (`column_specification.rs:21-29`), and the id is the 28 bits above the
    // low nibble (`:68-70`) with the encoding the low three (`:142-143`).
    const words = [_]struct { word: u32, id: u32, enc: Encoding, col: OpColumn }{
        // obj: the object the op acts on, as an actor index and a counter
        // (`change_op_columns.rs:29`, `:496-497`).
        .{ .word = 0x01, .id = 0, .enc = .actor, .col = .obj_actor },
        .{ .word = 0x02, .id = 0, .enc = .rle_uint, .col = .obj_counter },
        // key: the op's key, one of three columns chosen by its variant
        // (`change_op_columns.rs:30`, `:498-500`).
        .{ .word = 0x11, .id = 1, .enc = .actor, .col = .key_actor },
        .{ .word = 0x13, .id = 1, .enc = .delta, .col = .key_counter },
        .{ .word = 0x15, .id = 1, .enc = .string, .col = .key_string },
        // insert: `change_op_columns.rs:31`, `:501`.
        .{ .word = 0x34, .id = 3, .enc = .boolean, .col = .insert },
        // action: a code rather than a counter, so run-length. `:32`, `:502`.
        .{ .word = 0x42, .id = 4, .enc = .rle_uint, .col = .action },
        // val: a metadata word and its payload, which share one id and are
        // read as one column. `:33`, `:503-508` and `:334`.
        .{ .word = 0x56, .id = 5, .enc = .value_metadata, .col = .value_metadata },
        .{ .word = 0x57, .id = 5, .enc = .value, .col = .value },
        // pred: a group count and the flattened actor/counter pairs it
        // indexes. `:34`, `:509-527`.
        .{ .word = 0x70, .id = 7, .enc = .group, .col = .pred_group },
        .{ .word = 0x71, .id = 7, .enc = .actor, .col = .pred_actor },
        .{ .word = 0x73, .id = 7, .enc = .delta, .col = .pred_counter },
        // expand: `change_op_columns.rs:35`, `:546`.
        .{ .word = 0x94, .id = 9, .enc = .boolean, .col = .expand },
        // mark_name: `change_op_columns.rs:36`, `:547`.
        .{ .word = 0xa5, .id = 10, .enc = .string, .col = .mark_name },
    };
    try testing.expectEqual(op_columns.len, words.len);
    for (words) |w| {
        const spec = ColumnSpec.fromRaw(w.word);
        try testing.expectEqual(w.id, spec.id());
        try testing.expectEqual(w.enc, spec.encoding());
        // A change chunk's columns are never deflated
        // (`storage/change.rs:129-131`), so the word has bit 3 clear.
        try testing.expect(!spec.isCompressed());
        // The word names the column the table names, in both directions.
        try testing.expectEqual(w.col, OpColumn.fromSpec(spec) orelse error.TestUnexpectedResult);
        try testing.expectEqual(w.word, w.col.spec().raw);
        try testing.expectEqual(w.id, w.col.id());
        try testing.expectEqual(w.enc, w.col.encoding());
    }

    // `op_columns` is the order the writer emits, and it is ascending by
    // normalized specification, which is the order `RawColumns::parse` requires
    // of a change (`raw_column.rs:248-253`). A writer that emitted them in any
    // other order would produce a body every reader of this format refuses.
    for (op_columns, 0..) |col, i| {
        try testing.expectEqual(words[i].word, col.spec().raw);
        if (i > 0) try testing.expect(op_columns[i - 1].spec().lessThan(col.spec()));
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

    // The op block is 11 bytes of metadata and 10 of data, and the header ends
    // where the metadata begins. The metadata is a count of five and five
    // descriptors of a one-byte spec and a one-byte length each
    // (`raw_column.rs:258-263`), which is what the data block's offset pins.
    try testing.expectEqual(@as(usize, 36), parsed.change.header_len);
    try testing.expectEqual(@as(usize, 36 + 11), parsed.ops.data.ptr - fixture_first_body[0..].ptr);
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
    // **One operation in five columns.** `opCount` is a row count, so this is
    // the length of the action column and not the length of `expected`; the
    // two agree only for a change where every column holds one op, which is
    // the coincidence that hid the defect.
    try testing.expectEqual(@as(usize, 1), try parsed.opCount());
    try testing.expectEqual(expected.len, parsed.ops.len());
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
    // **One operation in eight columns**, which is the same distinction as the
    // first fixture's with a different pair of numbers.
    try testing.expectEqual(@as(usize, 1), try parsed.opCount());
    try testing.expectEqual(expected.len, parsed.ops.len());
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
    try testing.expectEqual(parsed.opData().len, at);
    try testing.expectEqualSlices(u8, &expect_data, parsed.opData());
    try testing.expect(it.next() == null);

    // A one-op change on a non-root object still has no expand or mark_name
    // column, and no predecessor value columns: the group says its one op has
    // no predecessors.
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
        var encoded = try encode(gpa, parsed.change, ops);
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
    var header = try change_mod.parseChange(&[_]u8{
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
    var encoded = try encode(gpa, header, OpsBlock.empty());
    defer encoded.deinit(gpa);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x01, 0xaa, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00,
    }, encoded.body);

    // Read it back: the same change, with an empty op block.
    var parsed = try parseChangeChunk(encoded.body, gpa);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), try parsed.opCount());
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
    try testing.expectEqual(@as(usize, 1), try parsed.opCount());
    try testing.expectEqualSlices(u8, &data, parsed.opData());
    try testing.expectEqualSlices(u8, &footer, parsed.footer);

    // Write it back: the same footer, after the same columns.
    var encoded = try encode(gpa, parsed.change, OpsBlock.init(parsed.ops, parsed.footer));
    defer encoded.deinit(gpa);
    try testing.expectEqualSlices(u8, body.items, encoded.body);
    try testing.expectEqualSlices(u8, &footer, encoded.body[encoded.body.len - footer.len ..]);

    // Change the footer's bytes and only the footer changes: it is the last
    // thing in the body, and nothing in the header or the columns depends on
    // it. The body is a runtime-sized list, so the copy comes from the
    // allocator rather than from a comptime-known array.
    const other = try gpa.dupe(u8, body.items);
    defer gpa.free(other);
    other[other.len - footer.len + 3] = 'J';
    try testing.expectEqualSlices(u8, body.items[0 .. body.items.len - footer.len], other[0 .. other.len - footer.len]);
    var re_parsed = try parseChangeChunk(other, gpa);
    defer re_parsed.deinit(gpa);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x05, 'j', 'J', 'n', 'i', 's' }, re_parsed.footer);
    try testing.expectEqualSlices(u8, &data, re_parsed.opData());
    // The change hash covers the footer, so a different footer is a different
    // change: same columns, different hash.
    try testing.expect(!encoded.hash.eql(chunk.changeHashOf(.change, other)));
}

test "a truncated metadata block is refused" {
    const gpa = testing.allocator;
    // The op block of the first fixture, cut short. The header is intact, so
    // the count is read, and then the block runs out.
    const head: []const u8 = fixture_first_body[0..36];

    // The count says five columns but only two descriptors are there — the
    // body stops at 41, five bytes into the metadata block. The count is
    // larger than the remaining input could hold at two bytes a descriptor, so
    // it is refused before the count sizes anything.
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunk(fixture_first_body[0..41], gpa),
    );

    // All five descriptors, and then the fifth descriptor's length is cut off
    // mid-LEB128: the descriptor itself is truncated, so `takeUleb` reports the
    // end of the input rather than a length that is short of the data block.
    var cut: [head.len + 11]u8 = undefined;
    @memcpy(cut[0..head.len], head);
    @memcpy(cut[head.len..], &[_]u8{ 0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x80 });
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

    // Zero of the ten data bytes present: the body ends where the metadata
    // block ends, and the declared total is ten.
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunk(fixture_first_body[0..47], gpa),
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

    // A length of ten with three bytes of data: the body is the header and
    // count, the one-column spec, the one-byte length, and the three bytes the
    // column claims to have. Ten of them are not there, so the sum of the
    // declared lengths is larger than what is left.
    var body: [head.len + 4]u8 = undefined;
    @memcpy(body[0..head.len], &head);
    body[head.len] = 0x0a; // the column's declared length
    @memcpy(body[head.len + 1 ..], &[_]u8{ 0x7f, 0x00, 0x7f });
    try testing.expectError(error.LengthExceedsInput, parseChangeChunk(&body, gpa));

    // A length of zero with a byte of data. The declared block is empty, so
    // what follows is the footer, and the reader does not reach into it for
    // the column — it takes the zero bytes the column declares and the one
    // byte after them is the footer (`storage/change.rs:120-125`).
    var zero: [head.len + 2]u8 = undefined;
    @memcpy(zero[0..head.len], &head);
    zero[head.len] = 0x00; // the column's declared length
    zero[head.len + 1] = 0xaa; // the one byte, which is the footer
    var parsed = try parseChangeChunk(&zero, gpa);
    defer parsed.deinit(gpa);
    // A zero-length column is dropped, as upstream drops it
    // (`raw_column.rs:40-50`), so the block is empty and the byte after the
    // declared data block is the footer.
    try testing.expectEqual(@as(usize, 0), try parsed.opCount());
    try testing.expectEqual(@as(usize, 0), parsed.opData().len);
    try testing.expectEqualSlices(u8, &[_]u8{0xaa}, parsed.footer);
    // With nothing to index, the column is not findable.
    try testing.expect((try parsed.bytesFor(ColumnSpec.make(4, .rle_uint, false))) == null);

    // And a length that is absurd — the ten-byte LEB128 encoding of the
    // largest `u64`, which is the most a length field can hold
    // (`parse/leb128.rs:15-40`) — is still refused as too large for the input,
    // not treated as a number to allocate or a sum to take.
    var huge: [head.len + 10]u8 = undefined;
    @memcpy(huge[0..head.len], &head);
    @memset(huge[head.len .. head.len + 9], 0xff);
    huge[head.len + 9] = 0x01; // the tenth byte carries the one bit that is left
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
    // One column whose two declared bytes are all there, so the DEFLATE bit is
    // the only thing wrong with the body.
    var body: [head.len + 4]u8 = undefined;
    @memcpy(body[0..head.len], &head);
    // 0x4a is the action column with the DEFLATE bit set
    // (`column_specification.rs:25-27`).
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
    // (`columns.rs:193-198`); the DEFLATE bit is ignored when comparing, so a
    // document that carries the same column both ways is refused too. Both
    // columns declare two bytes and both bytes are there, so a duplicate is
    // the only thing wrong with the body.
    var duplicated: [head.len + 9]u8 = undefined;
    @memcpy(duplicated[0..head.len], head);
    @memcpy(duplicated[head.len..][0..5], &[_]u8{
        0x02, // two columns
        0x42, 0x02, // the action column
        0x42, 0x02, // and itself again
    });
    @memcpy(duplicated[head.len + 5 ..], &[_]u8{ 0x7f, 0x00, 0x7f, 0x00 });
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
    // The op data block is automerge's, at offset 47 of the inflated body, and
    // it points into the buffer the reader owns rather than into a copy of it.
    const inflated = owned.inflated.?;
    try testing.expectEqual(@as(usize, 1), try owned.parsed.opCount());
    try testing.expectEqualSlices(u8, fixture_first_body[47..], owned.parsed.opData());
    try testing.expect(owned.parsed.opData().ptr == inflated.ptr + 47);
    try testing.expectEqualSlices(u8, &fixture_first_body, inflated);
    try testing.expect(owned.parsed.change.bytes.ptr == inflated.ptr);
    // The column the fixture names reads as the fixture wrote it.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x01, 0x61 }, (try owned.parsed.opBytes(.key_string)).?);
    try testing.expectEqual(@as(u64, 1), owned.parsed.change.seq);
    try testing.expectEqualSlices(u8, "change 1", owned.parsed.change.message);

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

test "a framed chunk's hash reaches the change instead of being taken again" {
    const gpa = testing.allocator;

    // **The uncompressed path.** `readChunk` hashed the body to check it
    // against the header and kept all thirty-two bytes, so the change this
    // walk builds records that hash rather than a second one over the same
    // bytes — and it is the hash over the body's own bytes.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try chunk.writeChunk(&plain, gpa, .change, &fixture_first_body);
    const c = try chunk.parseChunk(plain.items);
    try testing.expect(c.hash != null);
    var borrowed = try parseFramedChunk(c, gpa);
    defer borrowed.deinit(gpa);
    try testing.expect(borrowed.parsed.change.hash.eql(chunk.changeHashOf(.change, c.data)));
    try testing.expect(borrowed.parsed.change.hash.eql(c.hash.?));

    // **The compressed path.** `readChunk` publishes no hash here — it never
    // inflates, which is why `c.hash` is null for this type — so the hash
    // comes out of the decompression instead, and the change records it.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunk.compressChunk(&framed, gpa, &fixture_first_body);
    const cc = try chunk.parseChunk(framed.items);
    try testing.expect(cc.hash == null);
    var owned = try parseFramedChunk(cc, gpa);
    defer owned.deinit(gpa);
    const inflated = owned.inflated.?;
    try testing.expect(owned.parsed.change.hash.eql(chunk.changeHashOf(.change, inflated)));
    // The inflated bytes are the fixture's own, so the two agree.
    try testing.expect(owned.parsed.change.hash.eql(chunk.changeHashOf(.change, &fixture_first_body)));

    // **Handing the hash over and letting it be taken are the same answer.**
    // That is the whole of what this seam changes: the parse, the columns and
    // the change are identical, and only the number of SHA-256 passes over the
    // body differs.
    var taken = try parseChangeChunkWithHash(inflated, gpa, null);
    defer taken.deinit(gpa);
    try testing.expect(taken.change.hash.eql(owned.parsed.change.hash));
    try testing.expectEqual(taken.change.seq, owned.parsed.change.seq);
    try testing.expectEqual(taken.change.start_op, owned.parsed.change.start_op);
    try testing.expectEqual(taken.change.time, owned.parsed.change.time);
    try testing.expectEqualStrings(taken.change.message, owned.parsed.change.message);
    try testing.expectEqual(try taken.opCount(), try owned.parsed.opCount());
    try testing.expectEqualSlices(u8, taken.opData(), owned.parsed.opData());
    try testing.expectEqualSlices(u8, taken.footer, owned.parsed.footer);
    try testing.expectEqual(taken.change.header_len, owned.parsed.change.header_len);

    // **A chunk handed over with no hash still reads.** `parseFramedChunk`
    // passes `c.hash` through instead of unwrapping it, so a caller with a
    // hand-built chunk gets the hash taken here — which is the answer it got
    // before the seam existed — rather than a trap on a null.
    const hand_built: chunk.Chunk = .{
        .typ = .change,
        .checksum = c.checksum,
        .hash = null,
        .data = c.data,
        .frame = c.frame,
    };
    var from_hand = try parseFramedChunk(hand_built, gpa);
    defer from_hand.deinit(gpa);
    try testing.expect(from_hand.parsed.change.hash.eql(chunk.changeHashOf(.change, c.data)));
    try testing.expect(from_hand.parsed.change.hash.eql(borrowed.parsed.change.hash));

    // **A refused body is refused the same way with and without a hash.** The
    // hash is taken after the header parses, so a body that never gets that
    // far must not reach one on either spelling.
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunkWithHash(fixture_first_body[0..41], gpa, null),
    );
    try testing.expectError(
        error.LengthExceedsInput,
        parseChangeChunkWithHash(
            fixture_first_body[0..41],
            gpa,
            chunk.changeHashOf(.change, &fixture_first_body),
        ),
    );
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

test "opCount is the row count of the action column and not the column count" {
    const gpa = testing.allocator;
    // One change chunk, one column, and as many rows as the case asks for.
    // **One column and N rows is the shape on which the two answers cannot be
    // confused**, which is why this builds the action column directly instead
    // of borrowing a fixture: every fixture in this file has one row per
    // column's worth of luck, and the second fixture's eight columns hold one
    // operation.
    const header = [_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x03, // start_op 3
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
    };
    const spec = ColumnSpec.make(4, .rle_uint, false);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    // **Three rows in one column**, written as a literal run so the count
    // cannot come from a run header's repeat length by accident either.
    const three = [_]?u64{ 1, 2, 3 };
    var scratch: [32]u8 = undefined;
    rle.RleOption(u64).write(&scratch, &three);
    const len3 = rle.RleOption(u64).encodedSize(&three);
    try body.appendSlice(gpa, &header);
    {
        const descs = [_]ColumnDesc{ColumnDesc.init(spec, len3)};
        const cols = try RawColumns.init(gpa, &descs, scratch[0..len3]);
        defer cols.deinit(gpa);
        try writeOpsBlock(&body, gpa, OpsBlock.init(cols, &.{}));
    }

    var parsed = try parseChangeChunk(body.items, gpa);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), parsed.ops.len());
    try testing.expectEqual(@as(usize, 3), try parsed.opCount());
    // **`max_op` is the counter of the last row**, which is what the count is
    // for: `start_op + num_ops - 1` (`change.rs:74-76`).
    try testing.expectEqual(@as(u64, 3), parsed.change.start_op);
    try testing.expectEqual(@as(u64, 5), (try parsed.change.withOpCount(try parsed.opCount())).max_op);

    // **A thousand identical rows, which is one run.** A count that walked the
    // values would be right here and a count that walked the *runs* would say
    // one; the answer is a thousand only if the run's declared length is what
    // gets charged, which is what makes the count cheap on a hostile column
    // as well.
    body.clearRetainingCapacity();
    try body.appendSlice(gpa, &header);
    const many = [_]?u64{7} ** 1000;
    var wide: [32]u8 = undefined;
    rle.RleOption(u64).write(&wide, &many);
    const len_many = rle.RleOption(u64).encodedSize(&many);
    {
        const descs = [_]ColumnDesc{ColumnDesc.init(spec, len_many)};
        const cols = try RawColumns.init(gpa, &descs, wide[0..len_many]);
        defer cols.deinit(gpa);
        try writeOpsBlock(&body, gpa, OpsBlock.init(cols, &.{}));
    }

    var parsed2 = try parseChangeChunk(body.items, gpa);
    defer parsed2.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), parsed2.ops.len());
    try testing.expectEqual(@as(usize, 1000), try parsed2.opCount());
    try testing.expectEqual(@as(u64, 1002), (try parsed2.change.withOpCount(try parsed2.opCount())).max_op);
}

test "a metadata block that decreases across an empty column is refused" {
    const gpa = testing.allocator;
    // `RawColumns.init` drops every zero-length descriptor
    // (`column_spec.zig:432-437`), so an order check run over the set it returns
    // never sees this block's first column at all. Upstream's set keeps it —
    // `RawColumns::parse` builds one `RawColumn` per descriptor, empty ones
    // included (`raw_column.rs:232-247`) — and `are_normal_sorted` walks that
    // whole list (`raw_column.rs:289-297`), so the same block is
    // `NotInNormalOrder` there and in this port's own document reader
    // (`document_chunk.readColumnMeta`).
    const head = [_]u8{
        0x00, // no dependencies
        0x01, 0xaa, // actor
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // no message
        0x00, // no other actors
    };
    const data = [_]u8{ 0x7f, 0x00, 0x5a };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &head);
    try body.appendSlice(gpa, &[_]u8{
        0x02, // two op columns
        0x42, 0x00, // id 4 rle_uint, no bytes
        0x15, 0x03, // id 1 string, three bytes — less than the column above
    });
    try body.appendSlice(gpa, &data);
    try testing.expectError(error.InvalidColumnSpec, parseChangeChunk(body.items, gpa));

    // The same two columns the other way round is in order and reads: an empty
    // column simply is not a column (`raw_column.rs:183`), so the set has one
    // member and the three bytes are all of the op data.
    var ascending: std.ArrayList(u8) = .empty;
    defer ascending.deinit(gpa);
    try ascending.appendSlice(gpa, &head);
    try ascending.appendSlice(gpa, &[_]u8{
        0x02, // two op columns
        0x15, 0x03, // id 1 string, three bytes
        0x42, 0x00, // id 4 rle_uint, no bytes
    });
    try ascending.appendSlice(gpa, &data);
    var parsed = try parseChangeChunk(ascending.items, gpa);
    defer parsed.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), parsed.ops.len());
    try testing.expectEqualSlices(u8, &data, parsed.opData());

    // And a decrease between two columns that both have bytes was always
    // refused; this is the same check, one column further out. The order is by
    // normalized specification (`raw_column.rs:289-297`), so "less than the
    // column above" means a smaller id, not fewer bytes: `0x21` is id 2 and
    // `0x15` is id 1, and the three bytes after each are that column's length.
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, &head);
    try full.appendSlice(gpa, &[_]u8{
        0x02, // two op columns
        0x21, 0x03, // id 2 actor, three bytes
        0x15, 0x03, // id 1 string, three bytes — less than the column above
    });
    try full.appendSlice(gpa, &(data ++ data));
    try testing.expectError(error.InvalidColumnSpec, parseChangeChunk(full.items, gpa));
}

// ── Differences from upstream, in one place ─────────────────────────────────

// | here | upstream | why |
// | --- | --- | --- |
// | [`ChangeChunk.opCount`] answers a row count by walking the **runs** of the action column, allocating nothing and materialising no value | [`StoredChange::len`] is a field ([`storage/change.rs:205-207`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs)) that [`Change::new_from_unverified`] filled by counting as it decoded — `stored.verify_ops` ([`change.rs:30-46`](../../github-automerge-automerge/rust/automerge/src/change.rs)) — and [`Change::max_op`] is `start_op + len - 1` off it ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs)) | the port's [`Change`] is a header view over borrowed bytes ([`change.zig:99-141`](../../change.zig)) and holds **no decoded op set at all**, so there is no `num_ops` field to read and the count has to come out of the columnar layer. It has to come out of the *runs* and not the values: a run may declare up to `maxSlabLen` rows, so a value-at-a-time walk of a hostile column is an unbounded loop where a run-at-a-time walk is one pass over the bytes |
// | a change leaves this module with `max_op` **unset**, and the consumer that decoded the columns fills it in with [`Change.withOpCount`](../../change.zig) | a `Change` is materialised **with** its op count on every path, so no consumer ever sees an unset one | upstream counts while decoding and has no half-built change to leak; the port parses a header without touching the columns, so the field is not knowable at the parse. The consequence is a rule rather than a shape — and the rule has been missed at five encode-then-reparse sites so far ([`encodeOneChange`](../../doc.zig), [`applySpec`](../../anonymize.zig), [`Document.adoptChange`](../../doc.zig), `AMchangeFromBytes` and `reparseChange`), which is why [`opCount`] is public and why every consumer of a change this module parsed calls `withOpCount` rather than reading `max_op`. **The two kinds of count are not interchangeable:** a count taken from an array that was *just encoded* (`ops.len` at [`encodeOneChange`](../../doc.zig)) is a row count by construction and costs nothing, while a count *recovered from a column* has to walk runs for the reason above — passing a number of runs, or a number of bytes, to `withOpCount` is the same defect in a different costume |
