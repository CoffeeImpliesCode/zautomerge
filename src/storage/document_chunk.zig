//! The document chunk: a whole document in the compact columnar form `save`
//! writes and `load` reads.
//!
//! A document chunk body is four regions in this order
//! (`storage/document.rs:71-101`):
//!
//! ```text
//! offset        size  field
//! 0             n     actors: uleb128 count, then per actor uleb byte length
//!                      + raw bytes
//! ...           n     heads: uleb128 count, then per head 32 raw hash bytes
//! ...           n     change metadata: uleb128 column count, then per column
//!                      uleb128 specification and uleb128 byte length
//! ...           n     op metadata: the same shape
//! ...           p     change data: the change columns' bytes, back to back
//! ...           q     op data: the op columns' bytes, back to back
//! ...           r     head indexes: heads.len() uleb128 values  <- OPTIONAL
//! ```
//!
//! Both metadata blocks come before both data blocks, which is why the
//! compressor has to move the data rather than rewrite it in place: a column
//! that shrinks when it is deflated changes the offset of everything after it.
//! The op rows themselves are not this module's business: it moves and
//! validates the two column sets and leaves decoding to `src/columnar`.
//!
//! ## What the reader enforces
//!
//! * **A count is proved against the input before it is believed.** An actor
//!   is at least one byte of length prefix, a head is 32 bytes, a column
//!   descriptor is a specification and a length, so `Input.readCountThen`
//!   bounds each count by what is left before anything is allocated
//!   (`parse.rs:224-236`).
//! * **The order of the checks is upstream's, because the errors are
//!   observable.** `RawColumns::parse` reads the whole metadata block and
//!   only then rejects a set that is not in ascending normalized order
//!   (`raw_column.rs:232-253`), and the data block is located afterwards
//!   (`document.rs:120-129`). A document whose tenth column declares an
//!   absurd length and whose fourth column is out of order is therefore
//!   refused as *out of order*, not as a length that runs past the input —
//!   which is what the reference reports for
//!   `test/fixtures/overflow_in_length.automerge`.
//! * **A data block is the sum of the declared lengths, and it is checked
//!   against what is left before it is taken** (`document.rs:124-129`). The
//!   sum saturates, as it does upstream (`raw_column.rs:235-239`), so a
//!   hostile length costs a comparison rather than a wrapped offset.
//! * **The head-index suffix is optional, and it ends the body.** An input
//!   with nothing left after the op data has no suffix at all, for the output
//!   of an older JS implementation, and the reader yields zero indexes
//!   (`document.rs:131-135`); anything else must hold exactly `heads.len()`
//!   values (`document.rs:133-136`). Bytes after the suffix are leftover data
//!   and are refused, which is what the chunk parser does with whatever
//!   `Document::parse` left behind (`chunk.rs:72-79`).
//! * **A duplicate specification is not an order error.** Upstream's
//!   `are_normal_sorted` rejects a *decrease*, not a repeat
//!   (`raw_column.rs:289-297`), so a set with two columns of the same
//!   specification passes the metadata block and is caught later, by
//!   `Columns::parse2` (`columns.rs:203-210`). This reader keeps that
//!   boundary: the repeat is reported as `error.DuplicateColumn` after the
//!   DEFLATE pass, whichever way that went, because upstream runs the two
//!   checks on the same side of `compression::decompress`
//!   (`document.rs:145-160`).
//! * **Both DEFLATE arms reach the same checks.** Upstream's `decompress`
//!   copies the body when no column is deflated
//!   (`document/compression.rs:51-65`) and rebuilds it when one is, and
//!   `OpSet::validate` runs after either (`document.rs:145-160`), so whether
//!   a column was deflated decides only *where* the columns index and never
//!   *whether* they are checked. Both arms converge on one `validateSets`
//!   call, which is where the two paths used to diverge.
//! * **The logical layout is checked, not only the physical one.**
//!   [`checkColumnLayout`] is the port of `ColumnLayoutParser`
//!   (`storage/columns.rs:153-355`): a value payload has to belong to the
//!   metadata word in front of it. What it deliberately does *not* check is
//!   written on [`layoutFaultOf`]; that is a compatibility decision with the
//!   writer's own output behind it, not an oversight.
//!
//! ## Per-column DEFLATE
//!
//! A document column may carry the DEFLATE bit, in which case its bytes in
//! the data block are a raw DEFLATE stream (`raw_column.rs:89-102`). The
//! reader rebuilds the body with every column inflated and every bit cleared,
//! and the writer deflates each column whose length is at least
//! `CompressConfig.threshold` and clears it again on the way back
//! (`raw_column.rs:62-76`).
//!
//! **The two directions read different inputs, and that is why they are two
//! functions.** The reader is handed bytes it did not build, so it reads the
//! prefix, the two data blocks and the suffix back out of them
//! ([`inflateBody`]); the writer is handed a [`DocumentBlock`], which already
//! holds all four of those regions, so it never assembles the uncompressed
//! body at all ([`compressBody`]). Both directions are one pass that appends
//! to two buffers and then concatenates them, which is what upstream's
//! typestate does with `data_out` and `meta_out`
//! (`document/compression.rs:244-330`).
//!
//! `SaveOptions::deflate` maps to `Threshold(DEFLATE_MIN_SIZE)`, and
//! `DEFLATE_MIN_SIZE` is 256 (`change.rs:17`, `automerge.rs:2337-2345`). The
//! comparison is `len < threshold` keeps the bytes, so a column of exactly
//! 256 bytes *is* deflated and one of 255 is not (`raw_column.rs:63`).
//! `CompressConfig::None`, which `save_nocompress` selects
//! (`automerge.rs:1179-1185`), skips the pass and copies the body.
//!
//! ## What is not here
//!
//! * **Which columns a document has.** The change metadata columns are
//!   `change_graph.rs`'s (`change_graph.rs:1780-1798`) and the sixteen
//!   operation columns are `op_set2/columns.rs`'s
//!   (`op_set2/columns.rs:617-660`); `OpSet::validate` and
//!   `ChangeGraph::validate` check the sets against what they expect
//!   (`document.rs:148-165`), and those live with the columns themselves.
//!   This module reports the sets as they are, and a column it does not know
//!   is not an error.
//! * **Whether the heads are the right ones.** A document's head set is
//!   checked against the heads derived from its own changes
//!   (`document.rs:306-322`), which needs the change collector. The reader
//!   hands the head list on unchanged and `headsAreCurrent` is the
//!   comparison that check performs.
//! * **Whole-chunk compression.** That is a `ChunkType.compressed` chunk and
//!   belongs to `change_chunk.zig`; a document chunk's own framing is
//!   `chunk.writeChunk`, whose checksum covers the body as written.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const parse = @import("parse.zig");
const column_spec = @import("column_spec.zig");
const chunk = @import("chunk.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const hash_size = types.hash_size;
const Input = parse.Input;
const ColumnDesc = column_spec.ColumnDesc;
const ColumnRange = column_spec.ColumnRange;
const ColumnSpec = column_spec.ColumnSpec;
const RawColumns = column_spec.RawColumns;

/// The column length at and above which `save` deflates a column
/// (`change.rs:17`, the constant `SaveOptions::compress` passes as
/// `CompressConfig::Threshold`, `automerge.rs:2337-2345`).
pub const deflate_min_size: usize = 256;

/// Which columns a document chunk's writer deflates (`CompressConfig`,
/// `document.rs:19-22`).
///
/// `none` is what `save_nocompress` selects (`automerge.rs:1179-1185`) and
/// copies the body verbatim; `threshold` deflates every column whose length
/// is at least the value, and is the only variant that reaches
///
/// Copying this is copying a number, so a copy is independent and either may
/// be read from another thread.
pub const CompressConfig = union(enum) {
    /// Every column is written as it stands, with the DEFLATE bit clear.
    none,
    /// Every column of at least this many bytes is deflated.
    threshold: usize,

    /// The configuration `SaveOptions::deflate` selects: the threshold is
    /// `deflate_min_size` (`automerge.rs:2337-2345`).
    pub fn fromSaveDeflate(deflate: bool) CompressConfig {
        return if (deflate) .{ .threshold = deflate_min_size } else .none;
    }
};

/// A document chunk's contents, borrowed: the actor table, the heads, the two
/// column sets with the data blocks they index, and the head indexes.
///
/// This is what the writer takes and what `parseDocumentChunk` hands back
/// inside a `Document`, so a document that was read can be written again
/// unchanged. Nothing here is owned by the value: the actor slices and the
/// head hashes borrow the body, and the two `RawColumns` own only their
/// column lists.
///
/// Copying this is copying a view: the copy shares the two column lists and
/// everything they borrow, so it must not outlive the body those index, and
/// freeing the two lists twice is a double free. Nothing here is mutated by
/// the writer, so a copy may be read from another thread while the original
/// lives.
pub const DocumentBlock = struct {
    /// The actor table, in the order the actor indices name it. A document's
    /// actors are sorted (`document.rs:204-205`), because the indices in the
    /// columns are positions in this list; nothing in the format requires it
    /// and this module neither checks nor sorts it.
    actors: []const []const u8,
    /// The document's heads, in the order the suffix's head indexes refer to
    /// them (`document.rs:214-217`, `:233-235`).
    heads: []const ChangeHash,
    /// The change metadata columns and the data block they index into. The
    /// ranges are relative to that block, not to the body
    /// (`raw_column.rs:24-26`).
    changes: RawColumns,
    /// The operation columns and their data block.
    ops: RawColumns,
    /// One index per head, into the change graph's node array rather than an
    /// op counter (`change_graph.rs:141-144`). Empty for a document written
    /// by an older implementation, which appended no suffix at all
    /// (`document.rs:131-135`).
    head_indexes: []const u64,

    /// The block the five fields above describe.
    pub fn init(
        actors: []const []const u8,
        heads: []const ChangeHash,
        changes: RawColumns,
        ops: RawColumns,
        head_indexes: []const u64,
    ) DocumentBlock {
        return .{
            .actors = actors,
            .heads = heads,
            .changes = changes,
            .ops = ops,
            .head_indexes = head_indexes,
        };
    }

    /// The change data block: the change columns' bytes, contiguous and in
    /// metadata order.
    pub fn changeData(self: DocumentBlock) []const u8 {
        return self.changes.data;
    }

    /// The op data block: the op columns' bytes, contiguous and in metadata
    /// order.
    pub fn opData(self: DocumentBlock) []const u8 {
        return self.ops.data;
    }
};

/// A document chunk, parsed. Every column it holds is uncompressed.
///
/// `deinit` frees the rebuilt body when a column was deflated, the two column
/// lists, and the actor, head and head-index arrays. The slices those arrays
/// hold point into the *caller's* body, so the body must outlive the
/// `Document`; the rebuilt body, when there is one, is owned here and the
/// column data points into it.
///
/// **Copying this copies an owner.** A copy holds the same rebuilt body, the
/// same actor, head and head-index arrays and the same two column lists, so
/// exactly one copy may be torn down. Nothing here is mutated after the parse
/// returns, so the value may be read from another thread while it lives.
pub const Document = struct {
    /// The document's contents, as they are after the DEFLATE pass: no
    /// column carries the DEFLATE bit, whatever the body said.
    block: DocumentBlock,
    /// The body rebuilt with every column inflated, when at least one column
    /// was deflated. Null when the caller's own bytes are the body the
    /// columns index into, which is upstream's `Cow::Borrowed` short-circuit
    /// (`document/compression.rs:51-65`).
    inflated: ?[]u8,
    /// The caller's own bytes, which the actor and head slices point into.
    /// The body has to outlive the `Document` whether or not it was rebuilt.
    borrowed: []const u8,

    /// The actor table, in index order.
    pub fn actors(self: Document) []const []const u8 {
        return self.block.actors;
    }

    /// The document's heads, in the order the head indexes refer to them.
    pub fn heads(self: Document) []const ChangeHash {
        return self.block.heads;
    }

    /// One node index per head, empty when the body carried no suffix.
    pub fn headIndexes(self: Document) []const u64 {
        return self.block.head_indexes;
    }

    /// The change metadata columns and their data block.
    pub fn changeColumns(self: Document) RawColumns {
        return self.block.changes;
    }

    /// The operation columns and their data block.
    pub fn opColumns(self: Document) RawColumns {
        return self.block.ops;
    }

    /// The change data block.
    pub fn changeData(self: Document) []const u8 {
        return self.block.changeData();
    }

    /// The op data block.
    pub fn opData(self: Document) []const u8 {
        return self.block.opData();
    }

    /// The bytes of the change column with this specification, or null when
    /// the document holds no such column. The specification's DEFLATE bit is
    /// ignored, as it is in every other comparison of two specifications
    /// (`column_specification.rs:14-17`); the bytes are inflated either way,
    /// because this reader resolves the DEFLATE pass before handing the
    /// columns on.
    pub fn changeBytes(self: Document, spec: ColumnSpec) ParseError!?[]const u8 {
        return self.block.changes.bytesFor(spec);
    }

    /// The bytes of the op column with this specification, or null when the
    /// document holds no such column.
    pub fn opBytes(self: Document, spec: ColumnSpec) ParseError!?[]const u8 {
        return self.block.ops.bytesFor(spec);
    }

    /// The bytes the columns index into: the rebuilt body when a column was
    /// deflated, and the caller's own bytes otherwise. These are the bytes a
    /// writer reproduces, and for a document with no deflated column they are
    /// the ones `chunk.checksumOf(.document, .)` is taken over.
    ///
    /// **For a document that had a deflated column they are not those.** The
    /// checksum a chunk header carries is taken over the body *as written*,
    /// which for a `CompressConfig.threshold` write is the deflated body
    /// (`writeChunk` frames `rewritten.bytes`, not `body.items`), and
    /// `chunk.parseChunk` verifies the stored checksum against exactly those
    /// deflated bytes. This method hands back the inflated body, so
    /// `checksumOf(.document, doc.body())` matches the header only when
    /// `inflated` is null — that is, only when no column reached the threshold.
    /// A caller that recomputes a document chunk's checksum has to deflate the
    /// body itself, or use the bytes the chunk was read from.
    pub fn body(self: Document) []const u8 {
        return self.inflated orelse self.borrowed;
    }

    /// Whether `derived` is exactly this document's head set: the same number
    /// of hashes, the same hashes, in any order.
    ///
    /// This is the comparison `Document::verify_changes` makes before it
    /// reconstructs a document (`document.rs:306-322`), and the same one
    /// `ChangeGraph.headsAreCurrent` answers (`change_graph.rs:130-139`). It
    /// is a query and not a `ParseError`: the document chunk parsed; what
    /// disagrees is the change graph built from its columns, which is not
    /// this module's to build. The reference reports that disagreement as
    /// "mismatching heads", which is what
    /// `test/fixtures/incorrect_max_op.automerge` is.
    pub fn headsAreCurrent(self: Document, derived: []const ChangeHash) bool {
        if (derived.len != self.block.heads.len) return false;
        var at: usize = 0;
        for (self.block.heads) |head| {
            var found = false;
            while (at < derived.len) : (at += 1) {
                if (derived[at].eql(head)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    /// Frees the rebuilt body, the two column lists and the three arrays. The
    /// caller's own bytes are left alone.
    ///
    /// After this the struct is poisoned, not emptied: `self.*` is set to
    /// undefined, so reading any field afterwards is a use of undefined memory.
    /// One call per value, and — because a copy is a second owner — one call per
    /// copy.
    pub fn deinit(self: *Document, gpa: Allocator) void {
        if (self.inflated) |rebuilt| gpa.free(rebuilt);
        gpa.free(self.block.actors);
        gpa.free(self.block.heads);
        gpa.free(self.block.head_indexes);
        self.block.changes.deinit(gpa);
        self.block.ops.deinit(gpa);
        self.* = undefined;
    }
};

/// Where each region of a body starts. Recorded by the writer and by the
/// reader, because the DEFLATE pass has to find the two data blocks and the
/// suffix inside a body it did not build, and every offset is absolute: the
/// column ranges inside a set are relative to their own data block
/// (`raw_column.rs:24-26`).
const Layout = struct {
    /// Where the change metadata block starts, which is the end of the
    /// actor list and the head list.
    meta_start: usize,
    /// Where the change data block starts.
    change_data_start: usize,
    /// Where the op data block starts, which is the end of the change data.
    op_data_start: usize,
    /// Where the head-index suffix starts, which is the end of the op data.
    suffix_start: usize,

    /// The change data block of `body`.
    fn changeData(self: Layout, body: []const u8) []const u8 {
        return body[self.change_data_start..self.op_data_start];
    }

    /// The op data block of `body`.
    fn opData(self: Layout, body: []const u8) []const u8 {
        return body[self.op_data_start..self.suffix_start];
    }
};

/// The smallest a column descriptor can be on the wire: a one-byte
/// specification and a one-byte length. `readCountThen` needs a floor to
/// divide the remaining input by before it believes a count, and this is the
/// structural one (`raw_column.rs:225-232`).
const min_desc_size: usize = 2;

/// Parses a document chunk body: the actor table, the head list, the two
/// metadata blocks, the two data blocks, and the optional head-index suffix.
///
/// `body` is the body only, with no chunk framing — what `chunk.parseChunk`
/// hands back for a `ChunkType.document` chunk. To go through the framing as
/// well, use `parseFramedChunk`.
///
/// Refused, all `ParseError`:
///
/// * a prefix that runs off the end, which is `error.UnexpectedEnd`;
/// * a count larger than the input could hold, caught before the count sizes
///   anything;
/// * a metadata block whose columns are not in ascending normalized order,
///   which is `error.InvalidColumnSpec` and is upstream's
///   `NotInNormalOrder` (`raw_column.rs:248-253`);
/// * a data block longer than what is left, which is
///   `error.LengthExceedsInput`, checked before the block is taken;
/// * a DEFLATE stream that does not inflate, which is `error.InvalidDeflate`
///   and is upstream's `raw_column::ParseError::Deflate`
///   (`raw_column.rs:214`);
/// * a column repeated within one metadata block, which is
///   `error.DuplicateColumn` (`columns.rs:203-210`);
/// * a value payload with no metadata word in front of it, which is
///   `error.MissingColumn`, or one whose column id is not the metadata
///   word's, which is `error.InvalidColumnSpec`
///   (`storage/columns.rs:216`, `:246`).
///
/// The last three are reported after the DEFLATE pass and whether or not
/// there was one, which is where upstream reports them: `OpSet::validate`
/// and `ChangeGraph::validate` run after `compression::decompress`
/// (`document.rs:145-168`), and a document with both a bad stream and a
/// repeat is refused for the stream.
pub fn parseDocumentChunk(body: []const u8, gpa: Allocator) ParseError!Document {
    var in: Input = .init(body);

    // The prefix: the actor table, then the heads. Upstream reads both with
    // `parse::length_prefixed` (`document.rs:112-113`) and takes an actor as
    // a uleb128 length and that many bytes, of any length including none
    // (`parse.rs:503-510`), and a head as 32 raw bytes (`parse.rs:515-519`).
    var actor_sink: ActorSink = .{ .in = &in, .gpa = gpa };
    try in.readCountThen(&actor_sink, 1, ActorSink.collect);
    errdefer gpa.free(actor_sink.actors);

    var head_sink: HeadSink = .{ .in = &in, .gpa = gpa };
    try in.readCountThen(&head_sink, hash_size, HeadSink.collect);
    errdefer gpa.free(head_sink.heads);

    // Both metadata blocks, in the order upstream reads them, and neither
    // data block until both are in hand: the order of the checks is what
    // decides which error a malformed document gets.
    const meta_start = in.pos;
    const change_descs = try readColumnMeta(&in, gpa);
    defer gpa.free(change_descs);
    const op_descs = try readColumnMeta(&in, gpa);
    defer gpa.free(op_descs);

    // The two data blocks, each the sum of its set's declared lengths and
    // each checked against what is left before it is taken
    // (`document.rs:124-129`). The sums saturate, as upstream's do
    // (`raw_column.rs:235-239`).
    const change_len = totalLenOf(change_descs);
    if (change_len > in.remaining()) return error.LengthExceedsInput;
    const change_data = try in.take(change_len);
    // The change data block ends where the op data block begins, and that is
    // the boundary the two ranges need.
    const change_end = in.pos;
    const op_len = totalLenOf(op_descs);
    if (op_len > in.remaining()) return error.LengthExceedsInput;
    const op_data = try in.take(op_len);

    const layout: Layout = .{
        .meta_start = meta_start,
        .change_data_start = change_end - change_len,
        .op_data_start = change_end,
        .suffix_start = in.pos,
    };

    // The suffix, which is optional: a body with nothing left after the op
    // data has none at all (`document.rs:131-135`), and one with something
    // left must hold exactly `heads.len()` values (`document.rs:133-136`).
    const head_indexes = try readHeadIndexes(&in, gpa, head_sink.heads.len);
    errdefer gpa.free(head_indexes);

    // One DEFLATE decision, one pair of sets, one set of checks. The decision
    // is only *where* the columns index: with nothing deflated the caller's
    // own bytes are the body and no copy is made
    // (`document/compression.rs:51-65`), and otherwise the body is rebuilt
    // with every column inflated. Both arms are checked here, because
    // upstream checks them after `compression::decompress` whichever way
    // that went — `OpSet::validate` at `document.rs:155-160` and
    // `ChangeGraph::validate` at `:162-168` — so a document is refused for
    // the same reason whether or not a column was deflated.
    const sets = if (anyCompressed(change_descs) or anyCompressed(op_descs))
        try decompressSets(gpa, body, layout, change_descs, op_descs, change_data, op_data)
    else
        try borrowSets(gpa, change_descs, op_descs, change_data, op_data);
    errdefer sets.deinit(gpa);
    try validateSets(sets);

    // The suffix ends the body: what follows it is leftover data, which the
    // chunk parser refuses as `LeftoverData` (`chunk.rs:72-79`). Upstream
    // reaches it after the two sets have been validated, so it is checked
    // last and for both arms alike.
    if (!in.isEmpty()) return error.TrailingBytes;
    return .{
        .block = .init(actor_sink.actors, head_sink.heads, sets.changes, sets.ops, head_indexes),
        .inflated = sets.bytes,
        .borrowed = body,
    };
}

/// The two column sets a body hands back, and the rebuilt body they index
/// into when the DEFLATE pass made one. Upstream's
/// `compression::Decompressed` (`document/compression.rs:51-65`), whose
/// `Cow::Borrowed` arm is the whole of the difference between the two.
const Sets = struct {
    /// The change metadata columns and the data block they index into.
    changes: RawColumns,
    /// The operation columns and their data block.
    ops: RawColumns,
    /// The rebuilt body, owned, or null when the columns index the caller's
    /// own bytes — which is upstream's `Cow::Borrowed`
    /// (`document/compression.rs:51-65`).
    bytes: ?[]u8,

    /// Frees the two column lists and the rebuilt body. The two data blocks
    /// are the caller's, and so is the body itself when nothing was
    /// deflated.
    fn deinit(self: Sets, gpa: Allocator) void {
        self.changes.deinit(gpa);
        self.ops.deinit(gpa);
        if (self.bytes) |rebuilt| gpa.free(rebuilt);
    }
};

/// Whether any descriptor of a metadata block carries the DEFLATE bit, which
/// is what decides whether the body has to be rebuilt at all
/// (`document/compression.rs:51-65`).
fn anyCompressed(descs: []const ColumnDesc) bool {
    for (descs) |desc| {
        if (desc.spec.isCompressed()) return true;
    }
    return false;
}

/// The two column sets of a body with nothing deflated, indexing the
/// caller's own bytes.
///
/// This is upstream's `Cow::Borrowed` arm
/// (`document/compression.rs:51-65`), and it copies nothing: the sets own
/// their descriptor lists and borrow the two data blocks out of the caller's
/// body, exactly as the rebuilt sets borrow theirs out of `bytes`.
fn borrowSets(
    gpa: Allocator,
    change_descs: []const ColumnDesc,
    op_descs: []const ColumnDesc,
    change_data: []const u8,
    op_data: []const u8,
) ParseError!Sets {
    const changes = try RawColumns.init(gpa, change_descs, change_data);
    errdefer changes.deinit(gpa);
    const ops = try RawColumns.init(gpa, op_descs, op_data);
    errdefer ops.deinit(gpa);
    return .{ .changes = changes, .ops = ops, .bytes = null };
}

/// The two column sets a body with a deflated column hands back, and the
/// rebuilt body they index into.
///
/// The sets that were read off the wire are built here and given back to the
/// allocator on every path out, because the rebuilt ones replace them: the
/// caller never sees them, so it cannot leak them either.
fn decompressSets(
    gpa: Allocator,
    body: []const u8,
    layout: Layout,
    change_descs: []const ColumnDesc,
    op_descs: []const ColumnDesc,
    change_data: []const u8,
    op_data: []const u8,
) ParseError!Sets {
    const changes = try RawColumns.init(gpa, change_descs, change_data);
    defer changes.deinit(gpa);
    const ops = try RawColumns.init(gpa, op_descs, op_data);
    defer ops.deinit(gpa);

    const rewritten = try inflateBody(gpa, body, layout, changes, ops);
    // `RawColumns.init` copies the descriptors into its own list, so the two
    // arrays go back and only the rebuilt body survives.
    defer gpa.free(rewritten.change_descs);
    defer gpa.free(rewritten.op_descs);
    errdefer gpa.free(rewritten.bytes);

    const new_changes = try RawColumns.init(gpa, rewritten.change_descs, rewritten.changeSlice());
    errdefer new_changes.deinit(gpa);
    const new_ops = try RawColumns.init(gpa, rewritten.op_descs, rewritten.opSlice());
    errdefer new_ops.deinit(gpa);
    return .{ .changes = new_changes, .ops = new_ops, .bytes = rewritten.bytes };
}

/// The checks upstream runs on the two sets once the whole body is in hand,
/// in upstream's order: the operations first (`document.rs:155-160`), then
/// the changes (`:162-168`). One call, both arms.
fn validateSets(sets: Sets) ParseError!void {
    try validateSet(sets.ops);
    try validateSet(sets.changes);
}

/// One set, checked the way `OpSet::validate` and `ChangeGraph::validate`
/// check theirs (`op_set2/columns.rs:219-249`, `change_graph.rs:274-297`):
/// the physical checks over the whole set, then the logical layout over that
/// same whole set. Neither runs over the
/// filtered result, because upstream parses the layout at `columns.rs:224`
/// and filters at `:225-249`.
///
/// Contiguity is not among the physical checks here, because
/// `RawColumns.init` builds the ranges by accumulating the declared lengths
/// in metadata order (`raw_column.rs:232-247`), so they tile the data block
/// by construction. `checkContiguous` in `opset/columns.zig` is the check
/// for a caller that assembles ranges by hand.
fn validateSet(cols: RawColumns) ParseError!void {
    try cols.validate(null);
    try checkColumnLayout(cols);
}

/// Which logical column a set's layout is broken in.
///
/// Upstream's `BadColumnLayout` (`storage/columns.rs:117-132`) has seven
/// variants. Four are the physical checks `RawColumns.validate` makes —
/// `OutOfOrder` and `DuplicateColumnSpecs` at `storage/columns.rs:193-199`,
/// `NonContiguousColumns` and `DataOutOfRange` at `:313-354` — and
/// `NestedGroup` (`:269`) is unreachable behind them, because a second
/// `group` column on an id a group is already open on is a repeated
/// specification and is refused as that first. The two that are left are
/// the value column's.
const LayoutFault = enum {
    /// A payload with no metadata word in front of it, inside a group or not:
    /// `BadColumnLayout::LoneRawValueColumn` (`storage/columns.rs:216`,
    /// `:270`).
    lone_value,
    /// A payload whose column id is not the metadata word's, so the two raw
    /// columns one logical value column is made of (`storage/columns.rs:57-60`)
    /// are two different logical columns:
    /// `BadColumnLayout::MismatchingValueMetadataId` (`:246`).
    mismatched_value_meta,

    /// The refusal this fault is reported as. The error set carries no
    /// payload (`src/error.zig`), so the two upstream variants become the
    /// two existing classes that mean the same thing, and
    /// [`layoutFaultOf`] is what names the group.
    fn parseError(fault: LayoutFault) ParseError {
        return switch (fault) {
            // "raw value column without metadata column"
            // (`storage/columns.rs:124`): a required half of the logical
            // column is not in the block.
            .lone_value => error.MissingColumn,
            // "value metadata followed by value column with different
            // column ID" (`storage/columns.rs:126`): a specification this
            // layout cannot have.
            .mismatched_value_meta => error.InvalidColumnSpec,
        };
    }
};

/// Which logical column `cols` is broken in, or null when its layout is
/// sound. The port of `ColumnLayoutParser` (`storage/columns.rs:153-355`),
/// which `ColumnFormat::parse2` feeds the whole set in metadata order
/// (`storage/columns.rs:77-86`).
///
/// **It does not require a logical column to be complete, because upstream
/// does not require one either.** A metadata word whose payload never comes
/// is finished with an empty range (`storage/columns.rs:253`, and `build` at
/// `:166-169`), and a group whose members stop short is finished as it
/// stands (`:261`, and `GroupBuilder::finish` at `column_builder.rs:155-161`).
/// `BadColumnLayout` has no variant for an incomplete group, and the writer
/// emits them: `key_actor`, `key_ctr` and `key_str` are suppressed one by
/// one, each on its own, when every row of that column is null
/// (`op_set2/columns.rs:152-156`, and hexane's `save_to_unless` at
/// `column.rs:1446-1450`), so a document of nothing but map keys is written
/// with a `key_str` column and no `key_actor` beside it. The corpus says the
/// same: the change block of `test/fixtures/interop-exemplar`, which the
/// reference loads, holds `EXTRA_META_COL_SPEC` (`change_graph.rs:1796`) and
/// no `EXTRA_VAL_COL_SPEC` (`:1797`), so a metadata word with no payload is a
/// document the reference wrote. A completeness rule would refuse documents
/// the reference loads, which is the other direction of the same
/// compatibility gap.
fn layoutFaultOf(cols: RawColumns) ?LayoutFault {
    // Upstream's `LayoutParserState` and `GroupParseState`
    // (`storage/columns.rs:141-151`) with the builders left out: what the
    // builders hold is ranges, and the ranges are `RawColumns`' business.
    // `open_id` is the id of the logical column the state is inside — the
    // group's for the two group states, the metadata word's for the two
    // value states — because a group is identified by column id and not by
    // position (`storage/columns.rs:258-260`).
    const State = enum { ready, awaiting_payload, group_members, group_payload };
    var state: State = .ready;
    var open_id: u32 = 0;
    var it = cols.iterator();
    while (it.next()) |col| {
        // Upstream finishes the half-open logical column and calls
        // `add_column` again with the same column
        // (`storage/columns.rs:252-256`, `:302-305`), so one column can be
        // handled twice. This is the same shape without the recursion, over
        // a set whose length is already known: each retry moves to a state
        // that does not retry the same column in the same state again, so
        // the walk terminates on every input.
        var again = true;
        while (again) {
            again = false;
            switch (state) {
                .ready => switch (col.spec.encoding()) {
                    // A group header opens a group (`storage/columns.rs:202-208`)
                    // and a metadata word opens a value column (`:209-215`).
                    .group => {
                        state = .group_members;
                        open_id = col.spec.id();
                    },
                    .value_metadata => {
                        state = .awaiting_payload;
                        open_id = col.spec.id();
                    },
                    // A payload is never a logical column of its own
                    // (`storage/columns.rs:216`).
                    .value => return .lone_value,
                    else => {},
                },
                .awaiting_payload => switch (col.spec.encoding()) {
                    // The two halves of a value column carry the same id
                    // (`storage/columns.rs:244-251`).
                    .value => {
                        if (col.spec.id() != open_id) return .mismatched_value_meta;
                        state = .ready;
                    },
                    // Anything else ends the value column with an empty
                    // payload and starts over on this column
                    // (`storage/columns.rs:252-256`).
                    else => {
                        state = .ready;
                        again = true;
                    },
                },
                .group_members => {
                    // A different id closes the group and starts over
                    // (`storage/columns.rs:258-265`).
                    if (open_id != col.spec.id()) {
                        state = .ready;
                        again = true;
                    } else switch (col.spec.encoding()) {
                        // A payload is not one of a group's members
                        // (`storage/columns.rs:270`).
                        .value => return .lone_value,
                        // A metadata word on the group's own id opens the
                        // group's value column (`storage/columns.rs:271-275`).
                        .value_metadata => state = .group_payload,
                        else => {},
                    }
                },
                .group_payload => {
                    if (open_id != col.spec.id()) {
                        state = .ready;
                        again = true;
                    } else switch (col.spec.encoding()) {
                        // The payload closes the group's value column
                        // (`storage/columns.rs:298-300`).
                        .value => state = .group_members,
                        // Any other member ends that value column empty and
                        // is then handled as a group member
                        // (`storage/columns.rs:302-305`).
                        else => {
                            state = .group_members;
                            again = true;
                        },
                    }
                },
            }
        }
    }
    // Whatever the last column left open is finished as it stands, which is
    // never an error (`storage/columns.rs:163-183`).
    return null;
}

/// Refuses a set whose logical columns do not form, which is what
/// `ColumnFormat::parse2` (`storage/columns.rs:77-86`) is for. See
/// [`layoutFaultOf`] for what this deliberately does not check.
///
/// It is `pub` because the op set's own `validate`
/// ([`opset/columns.zig`](../opset/columns.zig)) runs the same layout parse
/// over the same kind of set (`op_set2/columns.rs:224`), and there is one
/// walk here rather than two.
pub fn checkColumnLayout(cols: RawColumns) ParseError!void {
    const fault = layoutFaultOf(cols) orelse return;
    return fault.parseError();
}

/// Reads a document chunk out of a framed chunk, which must be a
/// `ChunkType.document` one.
///
/// A `document` chunk's checksum covers its own body, so `chunk.parseChunk`
/// has already verified these bytes (`chunk.rs:267-269`); a body read this
/// way is verified before a single column is taken from it. A `change`,
/// `compressed` or `bundle` chunk is `error.InvalidChunkType`: this reader
/// takes a whole document and nothing smaller.
pub fn parseFramedChunk(c: chunk.Chunk, gpa: Allocator) ParseError!Document {
    if (c.typ != .document) return error.InvalidChunkType;
    return parseDocumentChunk(c.data, gpa);
}

/// Appends a document chunk body to `out`: the actor table, the head list, the
/// two metadata blocks, the two data blocks, and the head indexes.
///
/// The inverse of `parseDocumentChunk` for a block that was written this way:
/// the same actors, the same heads, the same columns in the same order with
/// the same bytes, and the same head indexes.
///
/// `RawColumns.init` has already dropped the columns with no bytes, so
/// `len()` is the count of columns the block will name and a descriptor is
/// written for each of them.
///
/// **Refused, all `ParseError`, and in every optimize mode.** These are real
/// returns rather than `std.debug.assert`s, so a caller that assembles a
/// `DocumentBlock` by hand is told rather than left to write a body no reader
/// accepts:
///
/// * a column carrying the DEFLATE bit, and a specification that is less than
///   the one before it — both `error.InvalidColumnSpec`;
/// * a specification equal to the one before it — `error.DuplicateColumn`;
/// * a head-index list that is neither empty nor one index per head —
///   `error.UnexpectedEnd` when it is short, `error.TrailingBytes` when it is
///   long, which are the two answers [`parseDocumentChunk`] gives for the body
///   each of those would have produced.
///
/// **No head indexes at all is allowed**, whatever the head count. The suffix
/// is optional in the format (`document.rs:131-135`), so an empty list is the
/// older writer's rendering and the reader accepts it back with zero indexes.
pub fn writeBody(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    block: DocumentBlock,
) ParseError!void {
    // **The four regions, in the format's order, and nothing recorded about
    // them.** A caller of this wants the bytes. The offsets a DEFLATE pass
    // needs are the ones [`Layout`] carries on the read side, and on this side
    // they are a function of the block rather than of a pass over it — which
    // is the whole of what [`compressBody`] is built on.
    try writePrefix(out, gpa, block);

    // Both metadata blocks, then both data blocks: the order is the format's,
    // and a reader locates the data from the lengths the metadata declares
    // (`document.rs:223-231`).
    try writeColumnMeta(out, gpa, block.changes);
    try writeColumnMeta(out, gpa, block.ops);
    try out.appendSlice(gpa, block.changes.data);
    try out.appendSlice(gpa, block.ops.data);

    try checkHeadIndexes(block);
    try writeSuffix(out, gpa, block);
}

/// The body a document chunk carries, without the framing. Owned by the
/// caller. See `writeBody`.
///
/// The refusals are the same and arrive in the same order. A body assembled
/// here is discarded when one of them fires, so a failed call returns the error
/// and nothing else; the partial body `writeBody` appends as it goes is the
/// only thing a caller reusing one buffer can be left holding.
pub fn encodeBody(gpa: Allocator, block: DocumentBlock) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeBody(&out, gpa, block);
    return out.toOwnedSlice(gpa);
}

/// Appends a complete document chunk to `out`: the body from `writeBody`,
/// deflated per `config`, then the chunk header over the bytes as written.
///
/// The header is rebuilt over the emitted body rather than copied from the
/// uncompressed one, because a compressed body is a different body and its
/// checksum has to be its own (`document/compression.rs:352-361`). That is
/// also why a compressed `Document` upstream keeps a header which does not
/// describe the bytes it hands out (`document.rs:239`, `:270`, `:286-291`):
/// here the framing is built from the body that is actually written, so
/// `chunk.parseChunk` can verify it.
pub fn writeChunk(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    block: DocumentBlock,
    config: CompressConfig,
) (ParseError || Allocator.Error)!void {
    switch (config) {
        .none => {
            // The body has to exist whole before `chunk.writeChunk` can hash
            // it, so this arm stages it. That is one copy of the block and
            // not two: `chunk.writeChunk` appends into `out`, and the staging
            // buffer is released on the way out.
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(gpa);
            try writeBody(&body, gpa, block);
            try chunk.writeChunk(out, gpa, .document, body.items);
        },
        .threshold => |threshold| {
            // **No staging pass, and that is the whole reason this arm does
            // not go through `writeBody`.** The region offsets a rebuild needs
            // are closed-form functions of the block — the prefix length, the
            // two metadata lengths, the two data lengths and the suffix
            // length — and in this direction every one of the five regions is
            // already in the caller's hands: the prefix is written from
            // `actors` and `heads`, the change and op data blocks *are*
            // `changes.data` and `ops.data`, and the suffix comes from
            // `head_indexes`. The uncompressed body was a carrier for bytes
            // the block already held, and it was the largest allocation on a
            // save: a document whose data deflates well spent the whole
            // uncompressed body to produce a few hundred bytes.
            //
            // `checkBlock` runs the refusals `writeBody` would have run on the
            // way past, in the same order and with the same names, so nothing
            // below this line writes a byte before the block is known to be
            // one this writer emits.
            try checkBlock(block);
            const body = try compressBody(gpa, block, threshold);
            defer gpa.free(body);
            try chunk.writeChunk(out, gpa, .document, body);
        },
    }
}

/// The compressed body of one document chunk, owned by the caller, and
/// nothing else: the prefix, both metadata blocks with the lengths the DEFLATE
/// pass produced, both data blocks, and the suffix.
///
/// This is the inflating direction's shape with the staged body taken out, and
/// the reason it can be is that its input is a [`DocumentBlock`] rather than a
/// body: the four regions that pass reads out of `src` are the prefix, the
/// change data, the op data and the suffix, and a block supplies all four.
/// Two buffers and a concatenation, because a column's length is only known
/// once it has been processed and the metadata block precedes the data it
/// describes — upstream's `meta_out`/`data_out` pair
/// (`document/compression.rs:244-330`).
fn compressBody(
    gpa: Allocator,
    block: DocumentBlock,
    threshold: usize,
) ParseError![]u8 {
    // **`defer`, not `errdefer`, and the difference is the whole of the two
    // buffers.** `meta_out` hands its buffer to `toOwnedSlice` on the way out
    // and is empty afterwards, so its `defer` is a no-op there and the
    // release on every path before it; `data_out` is a pure scratch buffer
    // whose bytes are copied into `meta_out`, and nothing else owns it, so it
    // has to be released on the success path too.
    var meta_out: std.ArrayList(u8) = .empty;
    defer meta_out.deinit(gpa);
    var data_out: std.ArrayList(u8) = .empty;
    defer data_out.deinit(gpa);

    try writePrefix(&meta_out, gpa, block);
    const change_descs = try processColumns(gpa, &data_out, block.changes, block.changes.data, .compress, threshold);
    defer gpa.free(change_descs);
    const op_descs = try processColumns(gpa, &data_out, block.ops, block.ops.data, .compress, threshold);
    defer gpa.free(op_descs);

    try writeColumnDescs(&meta_out, gpa, change_descs);
    try writeColumnDescs(&meta_out, gpa, op_descs);
    try meta_out.appendSlice(gpa, data_out.items);
    try writeSuffix(&meta_out, gpa, block);
    return meta_out.toOwnedSlice(gpa);
}

/// Every refusal `writeBody` raises on its way to the same body, in the order
/// it raises them: the change set, the op set, then the suffix count. The
/// metadata checks allocate nothing, which is why they can run before a single
/// byte of the body exists.
fn checkBlock(block: DocumentBlock) ParseError!void {
    try checkColumnMeta(block.changes);
    try checkColumnMeta(block.ops);
    try checkHeadIndexes(block);
}

/// A complete document chunk, allocated and owned by the caller. See
/// `writeChunk`.
pub fn encode(
    gpa: Allocator,
    block: DocumentBlock,
    config: CompressConfig,
) (ParseError || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeChunk(&out, gpa, block, config);
    return out.toOwnedSlice(gpa);
}

/// Appends the prefix: a count, then per actor a uleb128 length and that many
/// bytes; then a count, then 32 raw bytes per head (`document.rs:208-220`).
///
/// One implementation for both writers, which is what makes the compressing
/// arm's prefix the uncompressed arm's prefix: neither calls the other and
/// neither repeats these lines.
fn writePrefix(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    block: DocumentBlock,
) Allocator.Error!void {
    try leb128.appendUnsigned(out, gpa, block.actors.len);
    for (block.actors) |actor| {
        try leb128.appendUnsigned(out, gpa, actor.len);
        try out.appendSlice(gpa, actor);
    }
    try leb128.appendUnsigned(out, gpa, block.heads.len);
    for (block.heads) |head| {
        try out.appendSlice(gpa, &head.bytes);
    }
}

/// Appends the suffix: one uleb128 per head index (`document.rs:233-235`). A
/// document with no indexes writes none, which is what a body written by an
/// older implementation held (`document.rs:131-135`).
fn writeSuffix(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    block: DocumentBlock,
) Allocator.Error!void {
    for (block.head_indexes) |index| try leb128.appendUnsigned(out, gpa, index);
}

/// **Zero indexes and one index per head are the only two bodies the suffix
/// can spell, and the writer refuses the rest.** The reader reads exactly
/// `heads.len()` values whenever anything is left after the op data, and none
/// at all when nothing is (`document.rs:131-136`), so a partial list is a body
/// this module's own reader refuses — one that stops inside the suffix, and
/// one that leaves bytes past it. The two errors are the ones that reader
/// would have reported for the body this would have emitted, so a caller sees
/// the answer before the bytes exist.
fn checkHeadIndexes(block: DocumentBlock) ParseError!void {
    if (block.head_indexes.len != 0 and block.head_indexes.len != block.heads.len) {
        if (block.head_indexes.len < block.heads.len) return error.UnexpectedEnd;
        return error.TrailingBytes;
    }
}

/// Appends one column metadata block: the column count, then per column its
/// specification and the length of its bytes (`raw_column.rs:258-268`).
///
/// The columns go out in the order `RawColumns` holds them, and that order is
/// checked rather than sorted. It is a property of the caller's set, which is
/// not this function's to rearrange: a descending body is one no reader of
/// this format accepts (`raw_column.rs:248-253`), and a silent wrong document
/// is worse than a failed write.
///
/// **The refusals are real errors, not assertions.** The three names are the
/// ones [`parseDocumentChunk`] reports for the same three blocks, so the writer
/// refuses exactly what this module's reader refuses and says the same thing:
///
/// * `error.InvalidColumnSpec` — a column carrying the DEFLATE bit, which the
///   reader has already inflated (`raw_column.rs:89-102`), so a block that
///   still carries one is not a block this writer can emit;
/// * `error.InvalidColumnSpec` — a specification that is less than the one
///   before it, upstream's `NotInNormalOrder` (`raw_column.rs:289-297`);
/// * `error.DuplicateColumn` — a specification equal to the one before it,
///   upstream's `DuplicateColumnSpecs` (`storage/columns.rs:193-199`), which
///   the reader reports after the DEFLATE pass.
///
/// A non-strict order check would let two columns of one specification through,
/// which is what this writer used to do: `parseDocumentChunk` refuses the body
/// with `error.DuplicateColumn` and no optimize mode turns that assertion into
/// a diagnostic.
fn writeColumnMeta(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    cols: RawColumns,
) ParseError!void {
    try checkColumnMeta(cols);
    var count: std.ArrayList(u8) = .empty;
    defer count.deinit(gpa);
    try leb128.appendUnsigned(&count, gpa, cols.len());
    for (cols.columns) |col| {
        try leb128.appendUnsigned(&count, gpa, col.spec.raw);
        try leb128.appendUnsigned(&count, gpa, col.len());
    }
    try out.appendSlice(gpa, count.items);
}

/// The refusals [`writeColumnMeta`] raises, without writing a byte: the DEFLATE
/// bit, a descent, and a repeat, in that order and column by column.
///
/// **Split out so the compressing writer runs the same checks without the
/// metadata.** `writeColumnMeta` cannot check as it walks, because the count
/// leads the block and is only known once every column has been seen; a
/// writer that never emits the uncompressed block still has to refuse exactly
/// what the one that emits it refuses, and this is the one implementation
/// both call.
fn checkColumnMeta(cols: RawColumns) ParseError!void {
    var previous: ?ColumnSpec = null;
    for (cols.columns) |col| {
        if (col.spec.isCompressed()) return error.InvalidColumnSpec;
        if (previous) |prev| {
            switch (col.spec.compare(prev)) {
                .lt => return error.InvalidColumnSpec,
                .eq => return error.DuplicateColumn,
                .gt => {},
            }
        }
        previous = col.spec;
    }
}

/// Reads one column metadata block: a uleb128 count, then that many
/// `(specification, length)` pairs, and rejects a set that is not in
/// ascending normalized order.
///
/// The order check runs over the block as it was read, before the data is
/// located, which is where upstream puts it (`raw_column.rs:232-253`) and
/// what decides the error a malformed document gets. It compares normalized
/// specifications and rejects only a *decrease*, so a repeat passes here and
/// is caught later (`raw_column.rs:289-297`). The zero-length descriptors
/// take part in the check even though `RawColumns.init` drops them, because
/// upstream's set keeps them (`raw_column.rs:232-247`).
///
/// The caller owns the returned slice and frees it.
fn readColumnMeta(in: *Input, gpa: Allocator) ParseError![]ColumnDesc {
    var sink: DescSink = .{ .in = in, .gpa = gpa };
    try in.readCountThen(&sink, min_desc_size, DescSink.collect);
    const descs = sink.descs;

    var previous: ?ColumnSpec = null;
    for (descs) |desc| {
        if (previous) |prev| {
            if (desc.spec.compare(prev) == .lt) {
                gpa.free(descs);
                return error.InvalidColumnSpec;
            }
        }
        previous = desc.spec;
    }
    return descs;
}

/// The `readCountThen` destination for the actor table. An actor is a uleb128
/// length and that many bytes, so one byte is the smallest it can be
/// (`parse.rs:503-510`).
const ActorSink = struct {
    in: *Input,
    gpa: Allocator,
    /// The actors read. Each borrows the body, so the body must outlive them.
    actors: [][]const u8 = &.{},

    /// The callback `readCountThen` invokes with the count it proved against
    /// the input. The allocation is bounded by that proof.
    fn collect(self: *ActorSink, count: usize) ParseError!void {
        const out = try self.gpa.alloc([]const u8, count);
        errdefer self.gpa.free(out);
        var i: usize = 0;
        while (i < count) : (i += 1) out[i] = try self.in.readStrBytes();
        self.actors = out;
    }
};

/// The `readCountThen` destination for the head list. A head is 32 raw hash
/// bytes and nothing else (`parse.rs:515-519`), so 32 is both the minimum
/// element size and the element itself.
const HeadSink = struct {
    in: *Input,
    gpa: Allocator,
    /// The heads read, in the order the list had them.
    heads: []ChangeHash = &.{},

    /// The callback `readCountThen` invokes. The allocation is bounded by the
    /// count it proved against the input.
    fn collect(self: *HeadSink, count: usize) ParseError!void {
        const out = try self.gpa.alloc(ChangeHash, count);
        errdefer self.gpa.free(out);
        var i: usize = 0;
        while (i < count) : (i += 1) out[i] = .{ .bytes = try self.in.takeArray([hash_size]u8) };
        self.heads = out;
    }
};

/// The `readCountThen` destination for a column metadata block.
const DescSink = struct {
    in: *Input,
    gpa: Allocator,
    /// The descriptors read. Always set by `collect`, empty when the count
    /// was zero.
    descs: []ColumnDesc = &.{},

    /// The callback `readCountThen` invokes. A descriptor is a specification
    /// and a length, both LEB128 (`raw_column.rs:226-228`): the
    /// specification is a u32, because the id is 28 bits and the encoding and
    /// DEFLATE flag three more, and the length is a byte count.
    fn collect(self: *DescSink, count: usize) ParseError!void {
        // `readCountThen` proved `count <= remaining / min_desc_size`, so this
        // allocation is bounded by the input. A zero-length allocation is
        // legal and freeable, and the descriptors hold no pointers.
        const descs = try self.gpa.alloc(ColumnDesc, count);
        errdefer self.gpa.free(descs);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const spec_raw = std.math.cast(u32, try self.in.takeUleb()) orelse return error.Overflow;
            const len_raw = try self.in.takeUleb();
            const len = std.math.cast(usize, len_raw) orelse return error.TooLarge;
            descs[i] = .init(.fromRaw(spec_raw), len);
        }
        self.descs = descs;
    }
};

/// Reads the optional head-index suffix: exactly `heads_len` uleb128 values if
/// the input has anything left, and none at all if it does not
/// (`document.rs:131-136`).
///
/// The count is `heads_len`, which `readCountThen` bounded when it read the
/// head list, so the allocation is bounded by the input a second time. The
/// caller owns the returned slice and frees it.
fn readHeadIndexes(in: *Input, gpa: Allocator, heads_len: usize) ParseError![]u64 {
    if (in.isEmpty()) return gpa.alloc(u64, 0);
    const out = try gpa.alloc(u64, heads_len);
    errdefer gpa.free(out);
    for (out) |*index| index.* = try in.takeUleb();
    return out;
}

/// The length of the data block a set of descriptors describes: the sum of
/// their lengths, saturated. Upstream's `total_column_len`
/// (`raw_column.rs:267-270`) sums the same way, and `RawColumns::parse`
/// accumulates its offsets with a saturating add for the same reason
/// (`raw_column.rs:235-239`): a length came off the wire and can be absurd.
fn totalLenOf(descs: []const ColumnDesc) usize {
    var total: usize = 0;
    for (descs) |desc| total = total +| desc.len;
    return total;
}

/// Which way through a column set the DEFLATE pass is going. Upstream makes
/// this a trait with a witness type parameter so the compiler checks the order
/// of the steps (`document/compression.rs:113-190`); here the two directions
/// differ in one branch and the steps are written out once.
const Direction = enum {
    /// Inflate every column that carries the DEFLATE bit.
    decompress,
    /// Deflate every column at or above the threshold.
    compress,
};

/// A body after a DEFLATE pass, and the two column sets that index into it.
const Rewritten = struct {
    /// The rebuilt body, owned. The prefix is the original's, both metadata
    /// blocks are rewritten with the new lengths and the DEFLATE bit cleared,
    /// both data blocks are the processed columns, and the suffix is the
    /// original's.
    bytes: []u8,
    /// The change columns' new specifications and lengths, owned. Offsets
    /// into `bytes` are in `change_data`.
    change_descs: []ColumnDesc,
    /// The op columns' new specifications and lengths, owned.
    op_descs: []ColumnDesc,
    /// The change data block's range in `bytes`.
    change_data: ColumnRange,
    /// The op data block's range in `bytes`.
    op_data: ColumnRange,

    /// The change data block.
    fn changeSlice(self: Rewritten) []const u8 {
        return self.bytes[self.change_data.start..self.change_data.end];
    }

    /// The op data block.
    fn opSlice(self: Rewritten) []const u8 {
        return self.bytes[self.op_data.start..self.op_data.end];
    }

    /// Frees the body and the two descriptor arrays. The caller owns
    /// everything else, the same way it does for a parsed block.
    fn deinit(self: Rewritten, gpa: Allocator) void {
        gpa.free(self.change_descs);
        gpa.free(self.op_descs);
        gpa.free(self.bytes);
    }
};

/// Runs the inflating half of the DEFLATE pass over a body and returns the
/// rebuilt body with the two column sets that index it.
///
/// **The other direction is [`compressBody`], and the split is not
/// cosmetic.** This one is handed a body it did not build — the caller's own
/// bytes — so it reads its prefix, its two data blocks and its suffix out of
/// `src` through the [`Layout`] the reader recorded. The compressing direction
/// is handed a [`DocumentBlock`] instead, which already holds all four of those
/// regions, so it has no `src` to read and no layout to record: it is a
/// different function over a different input, not a parameter away from this
/// one. Both assemble the metadata in one buffer and the data in another and
/// concatenate them, because a column's new length is only known once it has
/// been processed and the metadata block precedes the data it describes —
/// upstream's `data_out` and `meta_out` (`document/compression.rs:244-330`).
///
/// Upstream also copies a column that already carries the DEFLATE bit, but its
/// compressor is only ever handed an uncompressed set (`Document::new` builds
/// one, `document.rs:199-202`), so that branch is not ported and
/// `checkColumnMeta` refuses a deflated specification instead.
fn inflateBody(
    gpa: Allocator,
    src: []const u8,
    layout: Layout,
    changes: RawColumns,
    ops: RawColumns,
) ParseError!Rewritten {
    var meta_out: std.ArrayList(u8) = .empty;
    defer meta_out.deinit(gpa);
    var data_out: std.ArrayList(u8) = .empty;
    defer data_out.deinit(gpa);

    try meta_out.appendSlice(gpa, src[0..layout.meta_start]);
    const change_descs = try processColumns(gpa, &data_out, changes, layout.changeData(src), .decompress, 0);
    errdefer gpa.free(change_descs);
    const op_descs = try processColumns(gpa, &data_out, ops, layout.opData(src), .decompress, 0);
    errdefer gpa.free(op_descs);

    try writeColumnDescs(&meta_out, gpa, change_descs);
    try writeColumnDescs(&meta_out, gpa, op_descs);
    const change_data_start = meta_out.items.len;
    try meta_out.appendSlice(gpa, data_out.items);
    // Both data blocks were appended in one go, change first, so the op data
    // block starts one change block along and ends where the suffix starts.
    const op_data_start = change_data_start + totalLenOf(change_descs);
    const op_data_end = meta_out.items.len;
    try meta_out.appendSlice(gpa, src[layout.suffix_start..]);
    return .{
        .bytes = try meta_out.toOwnedSlice(gpa),
        .change_descs = change_descs,
        .op_descs = op_descs,
        .change_data = .init(change_data_start, op_data_start),
        .op_data = .init(op_data_start, op_data_end),
    };
}

/// Appends every column of one set to `data_out`, deflated or inflated, and
/// returns the set's new descriptors. The caller owns them and frees them.
fn processColumns(
    gpa: Allocator,
    data_out: *std.ArrayList(u8),
    cols: RawColumns,
    data: []const u8,
    comptime dir: Direction,
    threshold: usize,
) ParseError![]ColumnDesc {
    const descs = try gpa.alloc(ColumnDesc, cols.len());
    errdefer gpa.free(descs);
    for (cols.columns, 0..) |col, i| {
        // A range that does not fit the data block is refused here, before
        // the column is inflated or its bytes are read.
        const bytes = try col.bytes(data);
        switch (dir) {
            .compress => {
                if (bytes.len < threshold) {
                    try data_out.appendSlice(gpa, bytes);
                    descs[i] = .init(col.spec, bytes.len);
                } else {
                    const deflated = try chunk.compressRaw(gpa, bytes);
                    defer gpa.free(deflated);
                    try data_out.appendSlice(gpa, deflated);
                    descs[i] = .init(col.spec.deflated(), deflated.len);
                }
            },
            .decompress => {
                if (!col.spec.isCompressed()) {
                    try data_out.appendSlice(gpa, bytes);
                    descs[i] = .init(col.spec, bytes.len);
                } else {
                    const inflated = try chunk.decompressRaw(gpa, bytes);
                    defer gpa.free(inflated);
                    try data_out.appendSlice(gpa, inflated);
                    descs[i] = .init(col.spec.inflated(), inflated.len);
                }
            },
        }
    }
    return descs;
}

/// Appends a column metadata block from descriptors whose offsets are
/// consecutive from zero, which is how both directions build them: each
/// column appends its bytes to the data buffer in order, so the lengths in
/// the descriptors are also the column offsets.
fn writeColumnDescs(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    descs: []const ColumnDesc,
) Allocator.Error!void {
    try leb128.appendUnsigned(out, gpa, descs.len);
    for (descs) |desc| {
        try leb128.appendUnsigned(out, gpa, desc.spec.raw);
        try leb128.appendUnsigned(out, gpa, desc.len);
    }
}

const testing = std.testing;

// A document chunk body, built byte by byte below, is the smallest thing
// that has every region: two actors of different lengths, one head, both
// metadata blocks, both data blocks, and one head index. The offsets in the
// test are the point of it, so they are written out as literals and a
// reordering of the layout fails loudly rather than quietly.
const hand_built_body = [_]u8{
    0x02, // actor count
    0x01, 0xaa, // actor 0: one byte
    0x02, 0xbb, 0xcc, // actor 1: two bytes
    0x01, // head count
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // head 0: 32 bytes
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, //
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, //
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, //
    0x02, // change metadata: two columns
    0x01, 0x02, // id 0 actor, two bytes
    0x03, 0x01, // id 0 delta, one byte
    0x01, // op metadata: one column
    0x34, 0x01, // id 3 boolean, one byte
    0x7f, 0x00, 0x7f, // change data: a one-value RLE actor column, then a
    // one-value delta column
    0x01, // op data: a boolean column of one true run
    0x00, // the head index
};

test "a hand-built document chunk reads field by field" {
    const gpa = testing.allocator;
    var doc = try parseDocumentChunk(&hand_built_body, gpa);
    defer doc.deinit(gpa);

    // The actor table: two actors, the lengths in the prefix and not a fixed
    // width. An actor of any length is legal, including none
    // (`parse.rs:503-510`), which is why the first element's length is a
    // count of its own and not 32.
    try testing.expectEqual(@as(usize, 2), doc.actors().len);
    try testing.expectEqualSlices(u8, &[_]u8{0xaa}, doc.actors()[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xbb, 0xcc }, doc.actors()[1]);

    // One head, 32 raw bytes, and the head index the suffix carries.
    try testing.expectEqual(@as(usize, 1), doc.heads().len);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    }, &doc.heads()[0].bytes);
    try testing.expectEqualSlices(u64, &[_]u64{0}, doc.headIndexes());

    // The change metadata: two columns, ascending, with the data block
    // following both metadata blocks.
    try testing.expectEqual(@as(usize, 2), doc.changeColumns().len());
    const changes = [_]ColumnBytes{
        .{ .spec = ColumnSpec.make(0, .actor, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
        .{ .spec = ColumnSpec.make(0, .delta, false), .bytes = &[_]u8{0x7f} },
    };
    try expectColumnBytes(doc.changeColumns(), doc.changeData(), &changes);

    // The op metadata: one column, a boolean of one true run.
    try testing.expectEqual(@as(usize, 1), doc.opColumns().len());
    const ops = [_]ColumnBytes{
        .{ .spec = ColumnSpec.make(3, .boolean, false), .bytes = &[_]u8{0x01} },
    };
    try expectColumnBytes(doc.opColumns(), doc.opData(), &ops);

    // The layout, as literal offsets into the body. Every one of them follows
    // from the region order, so a reordering shows up here rather than as a
    // document that reads plausibly wrong.
    const base = @intFromPtr(&hand_built_body);
    // The actor bytes start after the count and the length prefix, so this is
    // the first offset the layout fixes.
    try testing.expectEqual(@as(usize, 2), offsetOf(doc.actors()[0].ptr, base));
    try testing.expectEqual(@as(usize, 47), offsetOf(doc.changeData().ptr, base));
    try testing.expectEqual(@as(usize, 50), offsetOf(doc.opData().ptr, base));
    try testing.expectEqual(@as(usize, 52), hand_built_body.len);
    // The head indexes are read into an array of their own, so they are the
    // one region with no offset into the body: what the body holds is the
    // single uleb128 at the end.
    try testing.expectEqual(@as(u8, 0x00), hand_built_body[51]);
    try testing.expectEqualSlices(u8, &hand_built_body, doc.body());

    // And the head check the reconstruct stage performs, on the one head this
    // document has.
    const same = [_]ChangeHash{doc.heads()[0]};
    try testing.expect(doc.headsAreCurrent(&same));
    const other = [_]ChangeHash{.{ .bytes = @splat(0xff) }};
    try testing.expect(!doc.headsAreCurrent(&other));
    try testing.expect(!doc.headsAreCurrent(&.{}));
}

/// The offset of `ptr` from the start of the body it belongs to, which is how
/// the tests pin the layout: a slice a parser hands back points into the
/// input, so the two addresses differ by the region offset.
fn offsetOf(ptr: [*]const u8, base: usize) usize {
    return @intFromPtr(ptr) - base;
}

/// One column a test expects a set to hold: its specification, and the bytes
/// its range must cover.
const ColumnBytes = struct {
    spec: ColumnSpec,
    bytes: []const u8,
};

/// Asserts that a column set holds exactly `want`, in order, with exactly
/// those bytes, that their ranges tile the data block, and that the bytes
/// concatenate to it.
fn expectColumnBytes(cols: RawColumns, data: []const u8, want: []const ColumnBytes) !void {
    try testing.expectEqual(want.len, cols.len());
    var at: usize = 0;
    var it = cols.iterator();
    for (want) |w| {
        const col = it.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(w.spec.raw, col.spec.raw);
        try testing.expectEqual(at, col.range.start);
        const bytes = try col.bytes(data);
        try testing.expectEqualSlices(u8, w.bytes, bytes);
        at += bytes.len;
    }
    try testing.expect(it.next() == null);
    try testing.expectEqual(at, data.len);
}

// The `save()` bytes of the oracle's scripted document: two actors, two
// changes, eight change columns and fourteen operation columns, and the two
// head indexes automerge appended. Copied out of `test/golden/doc.jsonl`,
// which the Rust reference wrote, so this port's reader and writer are
// pinned against automerge's own bytes and not against each other.
const oracle_document = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x20, 0x0a, 0xee, 0x1f, 0x00, 0xb3, 0x03, 0x02,
    0x0f, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1, 0xa1,
    0xa1, 0xa1, 0xa1, 0xa1, 0x10, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2,
    0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0xb2, 0x02, 0x42, 0xd8,
    0xcc, 0x0a, 0xaa, 0xed, 0xdb, 0xe3, 0x91, 0x9a, 0x88, 0xd2, 0xd9, 0x9f,
    0xb8, 0x56, 0x59, 0x05, 0x2f, 0xd6, 0xb8, 0x71, 0x49, 0xca, 0xce, 0x56,
    0x5b, 0xa2, 0x55, 0x43, 0xc9, 0x5b, 0xe0, 0x69, 0x62, 0xe9, 0xd5, 0xf1,
    0x92, 0x01, 0x5a, 0xf2, 0x98, 0x5c, 0x49, 0x55, 0x18, 0x85, 0x6e, 0xb1,
    0x59, 0x2d, 0xef, 0x42, 0xfa, 0x36, 0x7d, 0x89, 0x78, 0x7d, 0x99, 0xdc,
    0x84, 0xc9, 0x08, 0x01, 0x04, 0x03, 0x04, 0x13, 0x04, 0x23, 0x08, 0x35,
    0x11, 0x40, 0x04, 0x43, 0x02, 0x56, 0x02, 0x0e, 0x01, 0x04, 0x02, 0x08,
    0x11, 0x0a, 0x13, 0x0e, 0x15, 0x3c, 0x21, 0x09, 0x23, 0x14, 0x34, 0x03,
    0x42, 0x0d, 0x56, 0x17, 0x57, 0x40, 0x80, 0x01, 0x07, 0x81, 0x01, 0x02,
    0x83, 0x01, 0x03, 0x02, 0x00, 0x7f, 0x01, 0x02, 0x01, 0x7f, 0x7f, 0x7f,
    0x19, 0x02, 0x01, 0x7f, 0x80, 0xe2, 0xcf, 0xaa, 0x06, 0x02, 0x00, 0x7d,
    0x04, 0x62, 0x61, 0x73, 0x65, 0x04, 0x6c, 0x65, 0x66, 0x74, 0x05, 0x72,
    0x69, 0x67, 0x68, 0x74, 0x7f, 0x00, 0x02, 0x01, 0x02, 0x00, 0x03, 0x07,
    0x00, 0x07, 0x14, 0x00, 0x00, 0x07, 0x05, 0x02, 0x0b, 0x08, 0x04, 0x14,
    0x00, 0x08, 0x04, 0x00, 0x00, 0x01, 0x0a, 0x00, 0x00, 0x04, 0x00, 0x07,
    0x7e, 0x00, 0x03, 0x03, 0x01, 0x7e, 0x7a, 0x09, 0x09, 0x01, 0x00, 0x04,
    0x02, 0x04, 0x66, 0x72, 0x6f, 0x6d, 0x7b, 0x04, 0x6c, 0x69, 0x73, 0x74,
    0x03, 0x6d, 0x61, 0x70, 0x0a, 0x6f, 0x6e, 0x6c, 0x79, 0x5f, 0x72, 0x69,
    0x67, 0x68, 0x74, 0x04, 0x74, 0x65, 0x78, 0x74, 0x05, 0x74, 0x69, 0x74,
    0x6c, 0x65, 0x00, 0x10, 0x02, 0x07, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x65,
    0x72, 0x7e, 0x04, 0x64, 0x72, 0x6f, 0x70, 0x04, 0x6b, 0x65, 0x65, 0x70,
    0x7e, 0x00, 0x01, 0x02, 0x00, 0x7f, 0x01, 0x16, 0x00, 0x78, 0x1a, 0x00,
    0x68, 0x12, 0x07, 0x6d, 0x79, 0x02, 0x04, 0x01, 0x7f, 0x02, 0x0a, 0x01,
    0x7c, 0x03, 0x02, 0x7f, 0x7e, 0x07, 0x10, 0x04, 0x02, 0x01, 0x7c, 0x02,
    0x00, 0x01, 0x04, 0x12, 0x01, 0x7f, 0x05, 0x02, 0x01, 0x7e, 0x46, 0x56,
    0x02, 0x00, 0x78, 0x14, 0x00, 0x96, 0x02, 0x14, 0x36, 0x85, 0x01, 0x02,
    0x13, 0x0b, 0x16, 0x7c, 0x18, 0x14, 0x76, 0x46, 0x6c, 0x65, 0x66, 0x74,
    0x72, 0x69, 0x67, 0x68, 0x74, 0x2a, 0x7a, 0x61, 0x75, 0x74, 0x6f, 0x6d,
    0x65, 0x72, 0x67, 0x65, 0x20, 0x6f, 0x72, 0x61, 0x63, 0x6c, 0x65, 0x7f,
    0x74, 0x77, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x40, 0x07,
    0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x00,
    0x05, 0x64, 0x72, 0x6f, 0x70, 0x70, 0x65, 0x64, 0x6b, 0x65, 0x70, 0x74,
    0x17, 0x00, 0x7c, 0x01, 0x00, 0x01, 0x00, 0x02, 0x00, 0x7e, 0x18, 0x01,
    0x01, 0x02,
};

// The body of each fuzz artifact in `test/fixtures/`, without its chunk
// header. The header is the framing layer's, and three of these files carry
// a checksum the fuzzer wrote rather than one automerge computed — which is
// not an obstacle, because the reference parses a body *before* it checks a
// chunk's checksum (`load.rs:106-109`), so these are exactly the bytes its
// document parser sees. Each comment names the error the Rust reference
// reports for the file, as `test/golden/fixtures.jsonl` records it.

// `overflow_in_length.automerge`. "bad document chunk: columns were not in
// normalized order": one actor of no bytes, no heads, and a change metadata
// block of sixteen columns whose sixth declares a length of
// 8001646522980168163 and whose specifications then descend.
const overflow_body = [_]u8{
    0x01, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0x85, 0x6f,
    0x4a, 0xe3, 0xe3, 0xe3, 0x85, 0x6f, 0x4a, 0x83, 0xe3, 0xe3, 0xe3, 0xe3,
    0xe1, 0xe3, 0xe3, 0x70, 0xd6, 0x70, 0x70, 0x70, 0x70, 0x70, 0x83, 0xe3,
    0x1d, 0x18, 0xe3, 0xe3, 0x2f, 0xe1, 0xe3, 0x4a, 0x83, 0xe3, 0xe3, 0xe3,
    0xe3, 0xe1, 0xe3, 0xd6, 0x70, 0x70, 0x70, 0x70, 0x70, 0x83, 0xe3, 0x1d,
    0x18, 0xe3, 0xe3, 0x2f, 0xe3, 0xe3, 0xe3, 0xff, 0xff, 0xff, 0xff, 0xff,
    0x27, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00,
    0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x02, 0x01, 0x07, 0x5d, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xe3, 0xe3, 0xe3, 0xe3, 0x04, 0x70,
    0x70, 0x70, 0x70, 0x70, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x07,
    0x5d, 0x01, 0x00,
};

// `invalid_deflate_stream.automerge`. "bad document chunk: corrupt deflate
// stream": the actor and head are thirty-two `0x30` bytes, the op metadata
// declares a column at specification 0x39 — the DEFLATE bit set — and that
// column's two bytes are not a DEFLATE stream. The change metadata block also
// repeats specification 0x31, which upstream tolerates at this stage
// (`raw_column.rs:289-297`) and which is why the stream is what the reference
// reports.
const deflate_body = [_]u8{
    0x01, 0x10, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x01, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x06, 0x01, 0x02, 0x03, 0x02, 0x20, 0x02, 0x30, 0x02,
    0x31, 0x02, 0x31, 0x02, 0x08, 0x20, 0x04, 0x21, 0x02, 0x30, 0x02, 0x31,
    0x01, 0x31, 0x02, 0x39, 0x02, 0x57, 0x03, 0x80, 0x01, 0x02, 0x7f, 0x00,
    0x7f, 0x01, 0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x02,
    0x66, 0x7a, 0x7f, 0x00, 0x7f, 0x01, 0x01, 0x7f, 0x01, 0x7f, 0x36, 0xef,
    0xbf, 0xbd, 0x7f, 0x00, 0x00,
};

// `missing_actor.automerge`. "error inflating document chunk ops: invalid
// load length len=0, expected=1": the id actor column holds one row and the
// block has no id counter column at all, so the counter is loaded with a
// required length of one and supplies none
// (`op_set2/columns.rs:259-264`).
const missing_actor_body = [_]u8{
    0x01, 0x10, 0xef, 0xb0, 0xbc, 0x54, 0x89, 0x8b, 0x42, 0xd2, 0x8f, 0x85,
    0xf7, 0x99, 0x96, 0x72, 0x14, 0xe8, 0x01, 0x98, 0x19, 0xd0, 0x2a, 0x7b,
    0x77, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0xfd, 0xc6,
    0xda, 0x19, 0xf9, 0xff, 0xff, 0x00, 0x0b, 0x96, 0x6b, 0x5d, 0x28, 0xf3,
    0x59, 0xc7, 0x9b, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02,
    0x40, 0x02, 0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x24, 0x02, 0x34,
    0x01, 0x42, 0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x02, 0x7f, 0x04,
    0x7f, 0x01, 0x7f, 0x01, 0x7f, 0x00, 0x77, 0x00, 0x7f, 0x07, 0x7f, 0x04,
    0x6f, 0x00, 0x70, 0x73, 0x7f, 0x00, 0x7f, 0x01, 0x01, 0x7f, 0x03, 0x38,
    0x46, 0x6f, 0x6f, 0x70, 0xdb, 0x7f, 0x00, 0x00,
};

// `incorrect_max_op.automerge`. "error inflating document chunk ops:
// mismatching heads": the document declares one head, and the change its
// columns describe does not hash to it. The chunk itself parses; the
// disagreement is found by the reconstruct stage, whose first check is
// `Document::verify_changes` (`document.rs:306-322`).
const max_op_body = [_]u8{
    0x01, 0x10, 0x02, 0x51, 0xa6, 0x70, 0xc0, 0xd1, 0x4f, 0x52, 0x80, 0x6a,
    0x06, 0xcc, 0x23, 0x75, 0x74, 0xa3, 0x01, 0xb7, 0x84, 0x6e, 0x2f, 0x9b,
    0x5c, 0x6c, 0xaa, 0xde, 0xc8, 0xd6, 0x5a, 0xf8, 0x61, 0xcd, 0x29, 0x30,
    0x49, 0x1e, 0x88, 0x65, 0x23, 0x28, 0x90, 0x1d, 0x52, 0xac, 0x7c, 0xa8,
    0xcc, 0xb2, 0x24, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02,
    0x40, 0x02, 0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x23, 0x02, 0x34,
    0x01, 0x42, 0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x02, 0x7f, 0x00,
    0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x04,
    0x6f, 0x01, 0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x01, 0x7f, 0x01, 0x7f,
    0x46, 0x6f, 0x00, 0x70, 0x73, 0x7f, 0x00, 0x00,
};

// `64bit_obj_id_doc.automerge`. "error inflating document chunk ops: invalid
// value: delta value out of domain": the id counter column is a delta column
// whose one value is 2^35 + 2^42, and a `u32` counter column's domain ends
// at 2^32 (`src/hexane/delta.zig` on `domainOf`, upstream
// `delta/mod.rs:99-100`).
const obj_id_body = [_]u8{
    0x01, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x62, 0x75, 0x60, 0xd6, 0xb8,
    0x33, 0x31, 0xbe, 0x8a, 0x9a, 0xa8, 0x81, 0xac, 0x77, 0x48, 0x85, 0x4c,
    0x9a, 0xd6, 0xc9, 0xc7, 0xdf, 0x64, 0xe7, 0x36, 0x75, 0xea, 0x20, 0xf7,
    0x6a, 0x89, 0xca, 0x07, 0x01, 0x02, 0x03, 0x02, 0x13, 0x08, 0x23, 0x07,
    0x35, 0x0a, 0x40, 0x02, 0x56, 0x02, 0x07, 0x15, 0x03, 0x21, 0x02, 0x23,
    0x08, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x80, 0x01, 0x02, 0x7f, 0x00,
    0x7f, 0x01, 0x7f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x7f, 0xc1,
    0xbe, 0xc4, 0x83, 0xe1, 0x30, 0x7f, 0x08, 0x01, 0x68, 0x61, 0x6e, 0x67,
    0x65, 0x20, 0x31, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x01, 0x61, 0x7f, 0x00,
    0x7f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x01, 0x7f, 0x00, 0x7f,
    0x00, 0x7f, 0x00, 0x00,
};

test "a document automerge wrote reads field by field" {
    const gpa = testing.allocator;
    // The chunk framing is the framing layer's, and this is a real chunk: the
    // checksum in its header is the one automerge computed, so `parseChunk`
    // verifies it (`chunk.rs:267-269`) before the body parser sees a byte.
    const c = try chunk.parseChunk(&oracle_document);
    try testing.expectEqual(chunk.ChunkType.document, c.typ);
    try testing.expectEqualSlices(u8, oracle_document[4..8], &c.checksum);
    try testing.expectEqual(@as(usize, 446), oracle_document.len);
    try testing.expectEqual(@as(usize, 435), c.data.len);

    var doc = try parseFramedChunk(c, gpa);
    defer doc.deinit(gpa);

    // The prefix. Two actors of fifteen and sixteen bytes, then two heads of
    // 32 bytes each. The offsets are the ones automerge's own writer put
    // them at: the actors start at body 2, the heads at 35, and the change
    // metadata block at 99.
    const body: []const u8 = c.data;
    const base = @intFromPtr(body.ptr);
    try testing.expectEqual(@as(usize, 2), doc.actors().len);
    try testing.expectEqual(@as(usize, 2), offsetOf(doc.actors()[0].ptr, base));
    try testing.expectEqual(@as(usize, 15), doc.actors()[0].len);
    try testing.expectEqualSlices(u8, body[2..17], doc.actors()[0]);
    try testing.expectEqual(@as(usize, 18), offsetOf(doc.actors()[1].ptr, base));
    try testing.expectEqual(@as(usize, 16), doc.actors()[1].len);
    try testing.expectEqualSlices(u8, body[18..34], doc.actors()[1]);
    try testing.expectEqual(@as(usize, 2), doc.heads().len);
    try testing.expectEqualSlices(u8, body[35..67], &doc.heads()[0].bytes);
    try testing.expectEqualSlices(u8, body[67..99], &doc.heads()[1].bytes);
    // And the suffix: one head index per head, in the same order.
    try testing.expectEqualSlices(u64, &[_]u64{ 1, 2 }, doc.headIndexes());
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, body[433..435]);

    // The change metadata: eight columns, ascending, and the data block
    // starting after both metadata blocks. The ids and encodings are
    // upstream's (`change_graph.rs:1780-1798`): the author, the sequence
    // number, the max op, the time, the message, the dependency count, the
    // dependency indices, and the extra metadata.
    try testing.expectEqual(@as(usize, 8), doc.changeColumns().len());
    const change_cols = [_]ColumnShape{
        .{ .raw = 0x01, .len = 4 }, // id 0 actor: the change's author
        .{ .raw = 0x03, .len = 4 }, // id 0 delta: its sequence number
        .{ .raw = 0x13, .len = 4 }, // id 1 delta: its maximum op counter
        .{ .raw = 0x23, .len = 8 }, // id 2 delta: its timestamp
        .{ .raw = 0x35, .len = 17 }, // id 3 string: its message
        .{ .raw = 0x40, .len = 4 }, // id 4 group: the dependency count
        .{ .raw = 0x43, .len = 2 }, // id 4 delta: the dependency indices
        .{ .raw = 0x56, .len = 2 }, // id 5 value metadata: the extra metadata
    };
    try expectColumnShape(doc.changeColumns(), doc.changeData(), &change_cols);
    try testing.expectEqual(@as(usize, 45), doc.changeData().len);
    try testing.expectEqual(@as(usize, 148), offsetOf(doc.changeData().ptr, base));

    // The op metadata: fourteen columns, the sixteen the op set defines less
    // the mark name and the expand flag, which a document with no marks does
    // not have (`op_set2/columns.rs:617-660`).
    try testing.expectEqual(@as(usize, 14), doc.opColumns().len());
    const op_cols = [_]ColumnShape{
        .{ .raw = 0x01, .len = 4 }, // obj actor
        .{ .raw = 0x02, .len = 8 }, // obj counter
        .{ .raw = 0x11, .len = 10 }, // id actor
        .{ .raw = 0x13, .len = 14 }, // id counter
        .{ .raw = 0x15, .len = 60 }, // key string
        .{ .raw = 0x21, .len = 9 }, // key actor
        .{ .raw = 0x23, .len = 20 }, // key counter
        .{ .raw = 0x34, .len = 3 }, // insert
        .{ .raw = 0x42, .len = 13 }, // action
        .{ .raw = 0x56, .len = 23 }, // value metadata
        .{ .raw = 0x57, .len = 64 }, // value
        .{ .raw = 0x80, .len = 7 }, // successor count
        .{ .raw = 0x81, .len = 2 }, // successor actor
        .{ .raw = 0x83, .len = 3 }, // successor counter
    };
    try expectColumnShape(doc.opColumns(), doc.opData(), &op_cols);
    try testing.expectEqual(@as(usize, 240), doc.opData().len);
    try testing.expectEqual(@as(usize, 193), offsetOf(doc.opData().ptr, base));

    // The three specifications above 0x7f are 128, 129 and 131 on the wire,
    // which is why the successor columns take two LEB128 bytes each: a
    // specification is a u32, not a byte (`raw_column.rs:227`).
    try testing.expectEqual(@as(u32, 8), ColumnSpec.make(8, .group, false).id());
    try testing.expectEqual(@as(u32, 129), ColumnSpec.make(8, .actor, false).raw);
    try testing.expectEqual(@as(u32, 131), ColumnSpec.make(8, .delta, false).raw);

    // The columns come back by specification, and the ones this document does
    // not have are absent rather than an error.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00, 0x7f, 0x01 }, (try doc.changeBytes(ColumnSpec.make(0, .actor, false))).?);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x00, 0x01, 0x02, 0x00, 0x7f, 0x01, 0x16, 0x00 }, (try doc.opBytes(ColumnSpec.make(2, .actor, false))).?);
    try testing.expect((try doc.opBytes(ColumnSpec.make(10, .string, false))) == null);
    try testing.expect((try doc.changeBytes(ColumnSpec.make(4, .actor, false))) == null);
}

test "a written document reads back with the same column specifications and bytes" {
    const gpa = testing.allocator;
    var doc = try parseFramedChunk(try chunk.parseChunk(&oracle_document), gpa);
    defer doc.deinit(gpa);

    // Every specification and every column's bytes, compared one at a time
    // between what was read and what was written.
    const before_changes = doc.changeColumns();
    const before_ops = doc.opColumns();
    const written = try encode(gpa, doc.block, .none);
    defer gpa.free(written);

    var again = try parseFramedChunk(try chunk.parseChunk(written), gpa);
    defer again.deinit(gpa);
    try testing.expectEqual(before_changes.len(), again.changeColumns().len());
    try testing.expectEqual(before_ops.len(), again.opColumns().len());
    var a = before_changes.iterator();
    var b = again.changeColumns().iterator();
    while (a.next()) |want| {
        const got = b.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(want.spec.raw, got.spec.raw);
        try testing.expectEqual(want.range.start, got.range.start);
        try testing.expectEqualSlices(u8, try want.bytes(doc.changeData()), try got.bytes(again.changeData()));
    }
    a = before_ops.iterator();
    b = again.opColumns().iterator();
    while (a.next()) |want| {
        const got = b.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(want.spec.raw, got.spec.raw);
        try testing.expectEqual(want.range.start, got.range.start);
        try testing.expectEqualSlices(u8, try want.bytes(doc.opData()), try got.bytes(again.opData()));
    }

    // And the bytes themselves. Not one of this document's columns reaches
    // the 256-byte threshold, so the compressing writer copies every one of
    // them and emits exactly the body automerge wrote — which is the whole
    // reason `save` is not required to be byte-identical: here it is.
    const compressed = try encode(gpa, doc.block, CompressConfig.fromSaveDeflate(true));
    defer gpa.free(compressed);
    try testing.expectEqualSlices(u8, &oracle_document, compressed);
    try testing.expectEqualSlices(u8, &oracle_document, written);
    try testing.expectEqualSlices(u8, doc.body(), (try chunk.parseChunk(compressed)).data);
}

test "a framed document chunk carries a checksum over the body it wrote" {
    const gpa = testing.allocator;
    var doc = try parseFramedChunk(try chunk.parseChunk(&oracle_document), gpa);
    defer doc.deinit(gpa);

    // The checksum in the header is the first four bytes of the change hash
    // of the body as emitted, and `parseChunk` verifies it — so a body that
    // was altered anywhere fails before a column is read (`chunk.rs:180-185`,
    // `:267-269`).
    const written = try encode(gpa, doc.block, .none);
    defer gpa.free(written);
    try testing.expectEqualSlices(u8, &chunk.checksumOf(.document, doc.body()), written[4..8]);
    try testing.expectEqual(@as(u8, 0), written[8]);

    var tampered = try gpa.dupe(u8, written);
    defer gpa.free(tampered);
    tampered[written.len - 1] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, chunk.parseChunk(tampered));

    // A chunk of any other type holds no document, and a framed chunk with
    // bytes left over is not a chunk.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunk.writeChunk(&framed, gpa, .change, "not a document");
    try testing.expectError(
        error.InvalidChunkType,
        parseFramedChunk(try chunk.parseChunk(framed.items), gpa),
    );
    var extra: std.ArrayList(u8) = .empty;
    defer extra.deinit(gpa);
    try extra.appendSlice(gpa, written);
    try extra.append(gpa, 0x00);
    try testing.expectError(error.TrailingBytes, chunk.parseChunk(extra.items));
}

test "a column of the deflate threshold is deflated and a shorter one is not" {
    const gpa = testing.allocator;
    // The threshold is a number and the comparison is `len < threshold` keeps
    // the bytes (`raw_column.rs:63`), so a column of exactly 256 bytes is
    // deflated and one of 255 is not. It is not rounded and not exclusive.
    try testing.expectEqual(@as(usize, 256), deflate_min_size);
    try testing.expectEqualDeep(CompressConfig{ .threshold = 256 }, CompressConfig.fromSaveDeflate(true));
    try testing.expectEqualDeep(CompressConfig.none, CompressConfig.fromSaveDeflate(false));

    const actors = [_][]const u8{&[_]u8{0xaa}};
    const heads = [_]ChangeHash{.{ .bytes = @splat(0x11) }};
    const indexes = [_]u64{0};
    const no_changes: RawColumns = .{ .columns = &.{}, .data = &.{} };

    // Two columns either side of the threshold, and two small ones to show
    // that a document with any data at all is not a special case.
    const short = @as([255]u8, @splat(0x5a));
    const long = @as([256]u8, @splat(0x5a));
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, &[_]u8{ 0x7f, 0x00 }); // id actor: one row, actor 0
    try data.appendSlice(gpa, &[_]u8{0x7f}); // id counter: one row, counter 0
    try data.appendSlice(gpa, &short);
    try data.appendSlice(gpa, &long);
    const descs = [_]ColumnDesc{
        ColumnDesc.init(ColumnSpec.make(2, .actor, false), 2),
        ColumnDesc.init(ColumnSpec.make(2, .delta, false), 1),
        ColumnDesc.init(ColumnSpec.make(4, .rle_uint, false), short.len),
        ColumnDesc.init(ColumnSpec.make(5, .value_metadata, false), long.len),
    };
    const cols = try RawColumns.init(gpa, &descs, data.items);
    defer cols.deinit(gpa);
    const block = DocumentBlock.init(&actors, &heads, no_changes, cols, &indexes);

    // The body, uncompressed: 36 bytes of prefix (one one-byte actor and one
    // head), the change column count at 36, the op column count at 37, and
    // the four op descriptors from 38.
    const plain = try encodeBody(gpa, block);
    defer gpa.free(plain);
    var in: Input = .init(plain);
    in.skip(36);
    try testing.expectEqual(@as(u64, 0), try in.takeUleb()); // the change column count
    try testing.expectEqual(@as(u64, 4), try in.takeUleb()); // the op column count
    try testing.expectEqual(@as(u64, 0x21), try in.takeUleb()); // id actor
    try testing.expectEqual(@as(u64, 2), try in.takeUleb());
    try testing.expectEqual(@as(u64, 0x23), try in.takeUleb()); // id counter
    try testing.expectEqual(@as(u64, 1), try in.takeUleb());
    try testing.expectEqual(@as(u64, 0x42), try in.takeUleb()); // the 255-byte column
    try testing.expectEqual(@as(u64, 255), try in.takeUleb());
    try testing.expectEqual(@as(u64, 0x56), try in.takeUleb()); // the 256-byte column
    try testing.expectEqual(@as(u64, 256), try in.takeUleb());
    // Then the data, in the same order, and the one head index.
    const data_start: usize = 48;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x00, 0x7f }, plain[data_start..][0..3]);
    try testing.expectEqualSlices(u8, &short, plain[data_start + 3 ..][0..short.len]);
    try testing.expectEqualSlices(u8, &long, plain[data_start + 3 + short.len ..][0..long.len]);
    try testing.expectEqual(@as(u8, 0x00), plain[data_start + 3 + short.len + long.len]);
    try testing.expectEqual(data_start + 4 + short.len + long.len, plain.len);

    // The compressing writer: the 255-byte column keeps its specification and
    // the 256-byte one gains the DEFLATE bit, and the body shrinks.
    const written = try encode(gpa, block, .{ .threshold = deflate_min_size });
    defer gpa.free(written);
    const framed = try chunk.parseChunk(written);
    try testing.expect(written.len < plain.len + 11);
    var cin: Input = .init(framed.data);
    cin.skip(36);
    try testing.expectEqual(@as(u64, 0), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 4), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 0x21), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 2), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 0x23), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 1), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 0x42), try cin.takeUleb());
    try testing.expectEqual(@as(u64, 255), try cin.takeUleb());
    // 0x5e is the value metadata column with the DEFLATE bit set, and its new
    // length is a DEFLATE stream over 256 equal bytes rather than the 256
    // bytes themselves: a run, not a slab.
    try testing.expectEqual(@as(u64, 0x5e), try cin.takeUleb());
    const deflated_len = try cin.takeUleb();
    try testing.expect(deflated_len < 256);

    // Reading it back gives the same four columns, with the same bytes and
    // the DEFLATE bit cleared: this reader resolves the pass before it hands
    // the columns on (`document/compression.rs:51-65`).
    var doc = try parseFramedChunk(framed, gpa);
    defer doc.deinit(gpa);
    try testing.expect(doc.inflated != null);
    try testing.expectEqual(@as(usize, 4), doc.opColumns().len());
    const want = [_]ColumnBytes{
        .{ .spec = ColumnSpec.make(2, .actor, false), .bytes = &[_]u8{ 0x7f, 0x00 } },
        .{ .spec = ColumnSpec.make(2, .delta, false), .bytes = &[_]u8{0x7f} },
        .{ .spec = ColumnSpec.make(4, .rle_uint, false), .bytes = &short },
        .{ .spec = ColumnSpec.make(5, .value_metadata, false), .bytes = &long },
    };
    try expectColumnBytes(doc.opColumns(), doc.opData(), &want);
    try testing.expectEqual(@as(usize, 0), doc.changeColumns().len());
    try testing.expectEqual(@as(usize, 0), doc.changeData().len);
}

test "a document with no head indexes round trips" {
    const gpa = testing.allocator;
    // A document written by an older implementation appended no suffix at all
    // (`document.rs:131-135`), so a body that ends at the op data reads as
    // zero head indexes rather than as a truncated one.
    const no_suffix = hand_built_body[0 .. hand_built_body.len - 1];
    var doc = try parseDocumentChunk(no_suffix, gpa);
    defer doc.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), doc.heads().len);
    try testing.expectEqual(@as(usize, 0), doc.headIndexes().len);
    try testing.expectEqualSlices(u8, no_suffix, doc.body());

    // Written back it is still a body with no suffix, so it reads the same
    // way: the indexes are whatever the block holds, not a count the format
    // fixes.
    const written = try encodeBody(gpa, doc.block);
    defer gpa.free(written);
    try testing.expectEqualSlices(u8, no_suffix, written);

    // A suffix with fewer indexes than heads is a truncated one, not an
    // absent one: `document.rs:133-136` reads exactly `heads.len()` values
    // when there is anything to read, so a body that has one index for two
    // heads stops in the suffix.
    var two: std.ArrayList(u8) = .empty;
    defer two.deinit(gpa);
    try two.append(gpa, 0x00); // no actors
    try two.append(gpa, 0x02); // two heads
    try two.appendNTimes(gpa, 0x5a, 2 * hash_size);
    try two.appendSlice(gpa, &[_]u8{ 0x00, 0x00 }); // no columns at all
    try two.appendSlice(gpa, &[_]u8{ 0x00, 0x01 }); // two head indexes
    var doc2 = try parseDocumentChunk(two.items, gpa);
    defer doc2.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), doc2.heads().len);
    try testing.expectEqualSlices(u64, &[_]u64{ 0, 1 }, doc2.headIndexes());
    // And the same body with its second index cut off is a truncated suffix.
    try testing.expectError(error.UnexpectedEnd, parseDocumentChunk(two.items[0 .. two.items.len - 1], gpa));
}

test "a document chunk body with nothing in it is not enough data" {
    const gpa = testing.allocator;
    // `test/fixtures/crash-da39a3ee5e6b4b0d3255bfef95601890afd80709` is ten
    // bytes: the magic, the checksum of an empty document body, the type byte
    // 0 and a length of 0. The reference reports "unable to parse chunk: not
    // enough data", which is its `ParseError::Incomplete` (`parse.rs:349-353`);
    // the port calls that `error.UnexpectedEnd`, and the body the document
    // parser is handed is empty.
    const empty_chunk = [_]u8{ 0x85, 0x6f, 0x4a, 0x83, 0x96, 0xa2, 0x96, 0xd2, 0x00, 0x00 };
    const c = try chunk.parseChunk(&empty_chunk);
    try testing.expectEqual(chunk.ChunkType.document, c.typ);
    try testing.expectEqual(@as(usize, 0), c.data.len);
    try testing.expectError(error.UnexpectedEnd, parseFramedChunk(c, gpa));
    try testing.expectError(error.UnexpectedEnd, parseDocumentChunk("", gpa));
}

test "a metadata block that is not in normalized order is refused" {
    const gpa = testing.allocator;
    // `test/fixtures/overflow_in_length.automerge`, whose reference error is
    // "bad document chunk: columns were not in normalized order". Not a
    // length error, although the block declares 8001646522980168163 bytes in
    // its sixth column, and not a LEB128 error, although three of its
    // specifications are two bytes wide: the order is checked before the data
    // block is located, and every specification still fits a u32.
    try testing.expectError(error.InvalidColumnSpec, parseDocumentChunk(&overflow_body, gpa));
    // And through the framing, which is the path a load takes.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunk.writeChunk(&framed, gpa, .document, &overflow_body);
    try testing.expectError(
        error.InvalidColumnSpec,
        parseFramedChunk(try chunk.parseChunk(framed.items), gpa),
    );
}

test "a deflate stream that does not inflate is refused" {
    const gpa = testing.allocator;
    // `test/fixtures/invalid_deflate_stream.automerge`, whose reference error
    // is "bad document chunk: corrupt deflate stream" — upstream's
    // `raw_column::ParseError::Deflate` (`raw_column.rs:214`). The body
    // repeats specification 0x31 in both metadata blocks, which this reader
    // does not report: upstream checks the order of a block and leaves a
    // repeat to `Columns::parse2`, and a repeat here must not pre-empt the
    // stream the reference names.
    try testing.expectError(error.InvalidDeflate, parseDocumentChunk(&deflate_body, gpa));
}

/// A set of columns built from a list of specifications, and the data block
/// they index into.
const Shape = struct {
    /// The columns, in the order the specifications were given.
    cols: RawColumns,
    /// The block they index, one distinct byte per column.
    data: []u8,
};

/// Builds a column set out of `specs`, one distinct byte of data per column,
/// so that a test can name the layout it wants without a valid hexane
/// encoding behind it: the layout checks read specifications and ranges and
/// never the bytes.
///
/// `specs` must be in ascending normalized order and free of repeats, because
/// `writeColumnMeta` refuses the order a reader demands
/// (`raw_column.rs:248-253`). A test that wants a repeat hands the reader a
/// body as bytes instead.
fn shapeOf(gpa: Allocator, specs: []const ColumnSpec) !Shape {
    // The block is allocated once and never moved: `cols.data` borrows it
    // for as long as the set lives, and a list that reallocated under it
    // would leave the ranges pointing into a buffer that is gone.
    const data = try gpa.alloc(u8, specs.len);
    errdefer gpa.free(data);
    const descs = try gpa.alloc(ColumnDesc, specs.len);
    defer gpa.free(descs);
    for (specs, 0..) |spec, i| {
        data[i] = @intCast(i);
        descs[i] = ColumnDesc.init(spec, 1);
    }
    return .{ .cols = try RawColumns.init(gpa, descs, data), .data = data };
}

/// A whole document body whose op column set is exactly `specs` and whose
/// every other region is empty: no actors, no heads, no change columns and
/// no suffix. See [`shapeOf`] for the specifications the caller may pass.
fn bodyWithOpColumns(gpa: Allocator, specs: []const ColumnSpec) ![]u8 {
    const shape = try shapeOf(gpa, specs);
    defer gpa.free(shape.data);
    defer shape.cols.deinit(gpa);
    const no_changes: RawColumns = .{ .columns = &.{}, .data = &.{} };
    return encodeBody(gpa, DocumentBlock.init(&.{}, &.{}, no_changes, shape.cols, &.{}));
}

/// The layout fault of an op set built out of `specs`, or null when the walk
/// finds nothing wrong with it. It asks the walk directly, so a test can name
/// the group whether or not the reader refuses the body.
fn faultOfSpecs(gpa: Allocator, specs: []const ColumnSpec) !?LayoutFault {
    const shape = try shapeOf(gpa, specs);
    defer gpa.free(shape.data);
    defer shape.cols.deinit(gpa);
    return layoutFaultOf(shape.cols);
}

test "a repeated column specification is refused whether or not a column was deflated" {
    const gpa = testing.allocator;
    // A repeat is upstream's `DuplicateColumn` (`columns.rs:203-210`), which
    // `OpSet::validate` and `ChangeGraph::validate` report after the body has
    // been decompressed (`document.rs:145-168`). Upstream's decompression is
    // a short-circuit that copies the body when no column is deflated
    // (`document/compression.rs:51-65`) and both validates run after either
    // arm, so one document is one answer. That is what this pins: the two
    // arms of one reader agree on the class.
    const stream = try chunk.compressRaw(gpa, &[_]u8{0x01});
    defer gpa.free(stream);

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    try compressed.appendSlice(gpa, &[_]u8{
        0x00, // no actors
        0x00, // no heads
        0x02, // two change columns, the same specification twice
        0x01, 0x01, // id 0 actor, one byte
        0x01, 0x01, // and itself again
        0x01, // one op column
    });
    try leb128.appendUnsigned(&compressed, gpa, ColumnSpec.make(3, .boolean, true).raw);
    try leb128.appendUnsigned(&compressed, gpa, stream.len);
    try compressed.appendSlice(gpa, &[_]u8{ 0x01, 0x01 }); // the change data
    try compressed.appendSlice(gpa, stream); // the op data, deflated

    // The same document with nothing deflated. Before the two arms were
    // joined this one parsed, and the repeat was visible only to a caller
    // that validated what it had been handed.
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try plain.appendSlice(gpa, &[_]u8{
        0x00, // no actors
        0x00, // no heads
        0x02, // two change columns, the same specification twice
        0x01, 0x01, // id 0 actor, one byte
        0x01, 0x01, // and itself again
        0x01, // one op column
        0x34, 0x01, // id 3 boolean, one byte
        0x01, 0x01, // the change data
        0x01, // the op data
    });
    try testing.expectError(error.DuplicateColumn, parseDocumentChunk(compressed.items, gpa));
    try testing.expectError(error.DuplicateColumn, parseDocumentChunk(plain.items, gpa));

    // A repeat in the op block rather than the change block: the set the
    // metadata names is the set that is checked, whichever block it is in.
    const repeated_ops = [_]u8{
        0x00, 0x00, // no actors, no heads
        0x00, // no change columns
        0x02, 0x34, 0x01, 0x34, 0x01, // id 3 boolean twice, one byte each
        0x01, 0x01, // the op data
    };
    try testing.expectError(error.DuplicateColumn, parseDocumentChunk(&repeated_ops, gpa));

    // The half that keeps the check from being a blanket refusal: the same
    // reader takes a body whose sets are sound. This is the smallest
    // complete document there is.
    var doc = try parseDocumentChunk(&hand_built_body, gpa);
    defer doc.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), doc.changeColumns().len());
    try testing.expectEqual(@as(usize, 1), doc.opColumns().len());

    // And a body with both a bad stream and a repeat is still the stream,
    // because upstream's decompression runs first (`document.rs:145-153`):
    // `test/fixtures/invalid_deflate_stream.automerge` repeats specification
    // 0x31 in both blocks and is reported for the stream.
    try testing.expectError(error.InvalidDeflate, parseDocumentChunk(&deflate_body, gpa));
}

test "a value payload with no metadata word in front of it is refused" {
    const gpa = testing.allocator;
    // Upstream's `LoneRawValueColumn` (`storage/columns.rs:216`): a payload
    // is never a logical column of its own, it is the second half of the
    // value column the metadata word in front of it opens (`:57-60`).
    const lone = [_]ColumnSpec{ColumnSpec.make(5, .value, false)};
    const in_group = [_]ColumnSpec{
        ColumnSpec.make(5, .group, false),
        ColumnSpec.make(5, .value, false),
    };
    for ([_][]const ColumnSpec{ &lone, &in_group }) |specs| {
        const body = try bodyWithOpColumns(gpa, specs);
        defer gpa.free(body);
        try testing.expectError(error.MissingColumn, parseDocumentChunk(body, gpa));
        try testing.expectEqual(LayoutFault.lone_value, try faultOfSpecs(gpa, specs));
    }
}

test "a value payload whose column id is not the metadata word's is refused" {
    const gpa = testing.allocator;
    // `MismatchingValueMetadataId` (`storage/columns.rs:246`): the metadata
    // word opens the value column and the payload that closes it must be that
    // column's, so a payload on another id belongs to no value column at all.
    const specs = [_]ColumnSpec{
        ColumnSpec.make(5, .value_metadata, false),
        ColumnSpec.make(6, .value, false),
    };
    const body = try bodyWithOpColumns(gpa, &specs);
    defer gpa.free(body);
    try testing.expectError(error.InvalidColumnSpec, parseDocumentChunk(body, gpa));
    try testing.expectEqual(LayoutFault.mismatched_value_meta, try faultOfSpecs(gpa, &specs));
}

test "a complete logical column is accepted" {
    const gpa = testing.allocator;
    // The half that matters: a check that refuses a valid document is its own
    // compatibility gap. Each set below is a group of halves the writer emits
    // together (`op_set2/columns.rs:627-642`), and each must read.
    const complete = [_][]const ColumnSpec{
        // The parent of an operation: actor and counter half (`:629-630`).
        &.{ ColumnSpec.make(0, .actor, false), ColumnSpec.make(0, .rle_uint, false) },
        // The key of an operation: actor, counter and string (`:631-633`).
        &.{
            ColumnSpec.make(1, .actor, false),
            ColumnSpec.make(1, .delta, false),
            ColumnSpec.make(1, .string, false),
        },
        // The value column: metadata word and payload (`:639-640`).
        &.{ ColumnSpec.make(5, .value_metadata, false), ColumnSpec.make(5, .value, false) },
        // The successor list: count, actor half, counter half (`:634-636`).
        &.{
            ColumnSpec.make(8, .group, false),
            ColumnSpec.make(8, .actor, false),
            ColumnSpec.make(8, .delta, false),
        },
        // A group that carries its own value column (`:271-275`, `:298-300`).
        &.{
            ColumnSpec.make(5, .group, false),
            ColumnSpec.make(5, .value_metadata, false),
            ColumnSpec.make(5, .value, false),
        },
    };
    for (complete) |specs| {
        const body = try bodyWithOpColumns(gpa, specs);
        defer gpa.free(body);
        var doc = try parseDocumentChunk(body, gpa);
        defer doc.deinit(gpa);
        try testing.expectEqual(specs.len, doc.opColumns().len());
        try testing.expect((try faultOfSpecs(gpa, specs)) == null);
    }
}

test "an incomplete logical column is accepted, because the writer emits one" {
    const gpa = testing.allocator;
    // `key_actor`, `key_ctr` and `key_str` are each suppressed on their own
    // when every row of that column is null (`op_set2/columns.rs:152-156`, and
    // hexane's `save_to_unless` at `column.rs:1446-1450`), so a document of
    // nothing but map keys is written with the string half and no actor
    // half. Upstream's layout parser has no completeness rule to refuse it:
    // a metadata word with no payload is finished with an empty range
    // (`storage/columns.rs:253`) and a group with no members is finished as
    // it stands (`:261`), and `BadColumnLayout` (`:117-132`) has no variant
    // for either. So these read, and a rule that refused them would refuse
    // documents the reference loads.
    const incomplete = [_][]const ColumnSpec{
        // The string half of a map key with neither of the other two.
        &.{ColumnSpec.make(1, .string, false)},
        // The actor and counter halves with no string half.
        &.{ ColumnSpec.make(1, .actor, false), ColumnSpec.make(1, .delta, false) },
        // The parent's actor half with no counter half.
        &.{ColumnSpec.make(0, .actor, false)},
        // A metadata word with no payload.
        &.{ColumnSpec.make(5, .value_metadata, false)},
        // A successor count with neither of its halves.
        &.{ColumnSpec.make(8, .group, false)},
        // A successor count with only the counter half.
        &.{ ColumnSpec.make(8, .group, false), ColumnSpec.make(8, .delta, false) },
        // A group's value column with no payload (`storage/columns.rs:302-305`).
        &.{ ColumnSpec.make(5, .group, false), ColumnSpec.make(5, .value_metadata, false) },
    };
    for (incomplete) |specs| {
        const body = try bodyWithOpColumns(gpa, specs);
        defer gpa.free(body);
        var doc = try parseDocumentChunk(body, gpa);
        defer doc.deinit(gpa);
        try testing.expectEqual(specs.len, doc.opColumns().len());
        try testing.expect((try faultOfSpecs(gpa, specs)) == null);
    }
}

test "a column load length that disagrees with the row count is refused" {
    const gpa = testing.allocator;
    // `test/fixtures/missing_actor.automerge`, whose reference error is
    // "error inflating document chunk ops: invalid load length len=0,
    // expected=1". The op set's id actor column holds one row, so every other
    // column is loaded with a required length of one
    // (`op_set2/columns.rs:259-264`), and the id counter column — absent from
    // this block — supplies none. That is `hexane`'s `InvalidLength`; in the
    // port it is the pair check that reports it, `error.InvalidValue` from
    // `checkLengths` in `src/columnar/columns.zig`, which is the op set
    // layer's. What this reader owes that check is the two column sets as the
    // block has them, and this is what it hands on.
    var doc = try parseDocumentChunk(&missing_actor_body, gpa);
    defer doc.deinit(gpa);

    // The id actor column: one row, actor 0. `0x7f` is the signed LEB128 -1,
    // which is a literal run of one value, and the value after it is 0.
    const id_actor_bytes = (try doc.opBytes(ColumnSpec.make(2, .actor, false))).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x00 }, id_actor_bytes);
    const run = try leb128.readSigned(id_actor_bytes);
    try testing.expectEqual(@as(i64, -1), run.value);
    try testing.expectEqual(@as(usize, 1), run.len);
    const value = try leb128.readUnsigned(id_actor_bytes[run.len..]);
    try testing.expectEqual(@as(u64, 0), value.value);
    try testing.expectEqual(@as(usize, 1), @as(usize, @intCast(-run.value)));

    // The id counter column, which the layout pairs with it, is not in the
    // block at all. That is the disagreement the reference reports: one row
    // on one side, none on the other.
    try testing.expect((try doc.opBytes(ColumnSpec.make(2, .delta, false))) == null);

    // The specification the fuzzer left behind, 0x24, is an id column with a
    // boolean encoding, which the op set's own filter drops
    // (`op_set2/columns.rs:227-247`): the reader hands it on as a column and
    // does not decide what a document may carry.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x01 }, (try doc.opBytes(ColumnSpec.make(2, .boolean, false))).?);
}

test "a head set that disagrees with the document's is not current" {
    const gpa = testing.allocator;
    // `test/fixtures/incorrect_max_op.automerge`, whose reference error is
    // "error inflating document chunk ops: mismatching heads". The chunk
    // parses: the reader hands on the head list and the change metadata, and
    // the reconstruct stage is what finds the disagreement
    // (`document.rs:306-322`).
    var doc = try parseDocumentChunk(&max_op_body, gpa);
    defer doc.deinit(gpa);

    // The one head this document declares, and the one head index that goes
    // with it.
    try testing.expectEqual(@as(usize, 1), doc.heads().len);
    try testing.expectEqualSlices(u8, &[_]u8{
        0xb7, 0x84, 0x6e, 0x2f, 0x9b, 0x5c, 0x6c, 0xaa, //
        0xde, 0xc8, 0xd6, 0x5a, 0xf8, 0x61, 0xcd, 0x29, //
        0x30, 0x49, 0x1e, 0x88, 0x65, 0x23, 0x28, 0x90, //
        0x1d, 0x52, 0xac, 0x7c, 0xa8, 0xcc, 0xb2, 0x24,
    }, &doc.heads()[0].bytes);
    try testing.expectEqualSlices(u64, &[_]u64{0}, doc.headIndexes());

    // The change's maximum op counter, and the counter of the one op it
    // carries: the two values whose disagreement is what the derived head set
    // disagrees with, handed on as the block has them.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x00 }, (try doc.changeBytes(ColumnSpec.make(1, .delta, false))).?);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x00 }, (try doc.opBytes(ColumnSpec.make(2, .delta, false))).?);

    // The check itself: the stored head is current, and anything else is not.
    const stored = [_]ChangeHash{doc.heads()[0]};
    try testing.expect(doc.headsAreCurrent(&stored));
    const elsewhere = [_]ChangeHash{.{ .bytes = @splat(0x00) }};
    try testing.expect(!doc.headsAreCurrent(&elsewhere));
    try testing.expect(!doc.headsAreCurrent(&.{}));
    try testing.expect(!doc.headsAreCurrent(&[_]ChangeHash{ doc.heads()[0], doc.heads()[0] }));
}

test "a delta value out of the column's domain is refused" {
    const gpa = testing.allocator;
    // `test/fixtures/64bit_obj_id_doc.automerge`, whose reference error is
    // "error inflating document chunk ops: invalid value: delta value out of
    // domain". The op id counter column is a delta column of one value, and
    // that value is 2^35 + 2^42; a counter column is a `u32` delta column, so
    // the value is outside its domain (`src/hexane/delta.zig` §`domainOf`,
    // upstream `delta/mod.rs:99-100`) and the port reports it as
    // `error.Overflow` when the column is loaded. The document chunk itself
    // parses: the value is inside the column, and this reader does not decode
    // columns.
    var doc = try parseDocumentChunk(&obj_id_body, gpa);
    defer doc.deinit(gpa);
    const counter_bytes = (try doc.opBytes(ColumnSpec.make(2, .delta, false))).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }, counter_bytes);

    // The run header is again the literal run of one value, and the value
    // after it is the delta the column carries.
    const run = try leb128.readSigned(counter_bytes);
    try testing.expectEqual(@as(i64, -1), run.value);
    try testing.expectEqual(@as(usize, 1), @as(usize, @intCast(-run.value)));
    const delta = try leb128.readSigned(counter_bytes[run.len..]);
    try testing.expectEqual(@as(i64, 1) << 42, delta.value);
    try testing.expectEqual(@as(usize, 7), delta.len);
    // Which is past the end of a u32 counter, by three orders of magnitude.
    try testing.expect(delta.value > std.math.maxInt(u32));
}

test "a column whose declared length runs past the data block is refused" {
    const gpa = testing.allocator;
    // A body whose single change column declares ten bytes and supplies two.
    // The metadata block is well formed, so this is the data-block check and
    // not a parse failure: `error.LengthExceedsInput`, which upstream reaches
    // as `take_n` finding the input short (`document.rs:124-129`).
    const short = [_]u8{
        0x00, // no actors
        0x00, // no heads
        0x01, // one change column
        0x01, 0x0a, // id 0 actor, ten bytes
        0x00, // no op columns
        0x7f, 0x00, // two bytes of change data
    };
    try testing.expectError(error.LengthExceedsInput, parseDocumentChunk(&short, gpa));

    // With the columns out of order the same body is refused for the order
    // instead, because that check runs first (`raw_column.rs:248-253`).
    const unsorted = [_]u8{
        0x00, // no actors
        0x00, // no heads
        0x02, // two change columns
        0x03, 0x00, // id 0 delta, no bytes
        0x01, 0x0a, // id 0 actor, ten bytes: descending
        0x00, // no op columns
        0x7f, 0x00, // two bytes of change data
    };
    try testing.expectError(error.InvalidColumnSpec, parseDocumentChunk(&unsorted, gpa));

    // The largest length a u64 can hold, which a 64-bit target can hold as a
    // byte count: it is the saturating sum and the comparison against what is
    // left that refuse it, and a hostile length costs two comparisons rather
    // than an allocation. On a narrower target the same bytes are
    // `error.TooLarge`, because a length that cannot be a byte count is not
    // one.
    const huge = [_]u8{
        0x00, 0x00, 0x01, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0x01, 0x00,
    };
    try testing.expectError(error.LengthExceedsInput, parseDocumentChunk(&huge, gpa));
    // A specification that does not fit a u32 is an overflow of its own: the
    // id is 28 bits and the encoding and DEFLATE flag three more, so anything
    // wider is not a specification at all (`raw_column.rs:226`).
    const wide_spec = [_]u8{
        0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0x1f, 0x00, 0x00,
    };
    try testing.expectError(error.Overflow, parseDocumentChunk(&wide_spec, gpa));
}

test "a body cut short is refused at the boundary it stops in" {
    const gpa = testing.allocator;
    // Every truncation of the hand-built body, cut one byte at a time. A cut
    // is refused either as an input that ran out under a reader
    // (`error.UnexpectedEnd`) or as a count or a declared length the remaining
    // input could not hold (`error.LengthExceedsInput`, which is what
    // `readCountThen` and the data-block checks report). Those are the only two
    // answers, and none of the 52 may be anything else — or a crash, or a
    // read past the end.
    var cut: usize = 0;
    while (cut < hand_built_body.len) : (cut += 1) {
        // The one cut that is not a truncation: the body without its head
        // index, which is a document written by an older implementation and
        // reads as no suffix at all (`document.rs:131-135`).
        if (cut == hand_built_body.len - 1) continue;
        if (parseDocumentChunk(hand_built_body[0..cut], gpa)) |_| {
            return error.TestUnexpectedResult;
        } else |e| {
            try testing.expect(e == error.UnexpectedEnd or e == error.LengthExceedsInput);
        }
    }
    // Which of the two, at three boundaries. A body with no count in it at
    // all; a head count of one with nothing left to hash; and a data block one
    // byte short of the length its metadata declares.
    try testing.expectError(error.UnexpectedEnd, parseDocumentChunk(hand_built_body[0..0], gpa));
    try testing.expectError(error.LengthExceedsInput, parseDocumentChunk(hand_built_body[0..7], gpa));
    try testing.expectError(error.LengthExceedsInput, parseDocumentChunk(hand_built_body[0..49], gpa));
    // A body that is one byte longer than the format allows: the suffix is
    // one head index, and a second one is data after the chunk, which
    // upstream refuses as leftover (`chunk.rs:72-79`).
    var over: std.ArrayList(u8) = .empty;
    defer over.deinit(gpa);
    try over.appendSlice(gpa, &hand_built_body);
    try over.append(gpa, 0x00);
    try testing.expectError(error.TrailingBytes, parseDocumentChunk(over.items, gpa));
}

test "the document writer refuses the blocks its own reader refuses" {
    const gpa = testing.allocator;
    const no_changes: RawColumns = .{ .columns = &.{}, .data = &.{} };
    const actors = [_][]const u8{&[_]u8{0xaa}};
    const one_head = [_]ChangeHash{.{ .bytes = @splat(0x11) }};
    const two_heads = [_]ChangeHash{
        .{ .bytes = @splat(0x11) },
        .{ .bytes = @splat(0x22) },
    };

    // **A repeated specification.** The order check here used to be
    // non-strict, so two columns of one specification went out and the body
    // this module wrote was the body its reader refuses with
    // `error.DuplicateColumn` (`storage/columns.rs:193-199`) — with no
    // diagnostic in any optimize mode.
    {
        const data = [_]u8{ 0x7f, 0x00 };
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
        };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(
            error.DuplicateColumn,
            encodeBody(gpa, DocumentBlock.init(&actors, &one_head, no_changes, cols, &[_]u64{0})),
        );
    }

    // **A descending specification**, and **a column the reader has already
    // inflated**. Both are `error.InvalidColumnSpec`, which is what
    // `parseDocumentChunk` reports for the same two blocks
    // (`raw_column.rs:248-253`, `:289-297`; `:89-102`).
    {
        const data = [_]u8{ 0x7f, 0x00 };
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(4, .rle_uint, false), 1),
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
        };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(
            error.InvalidColumnSpec,
            encodeBody(gpa, DocumentBlock.init(&actors, &one_head, no_changes, cols, &[_]u64{0})),
        );
    }
    {
        const data = [_]u8{0x7f};
        const descs = [_]ColumnDesc{ColumnDesc.init(ColumnSpec.make(3, .boolean, true), 1)};
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(
            error.InvalidColumnSpec,
            encodeBody(gpa, DocumentBlock.init(&actors, &one_head, no_changes, cols, &[_]u64{0})),
        );
    }

    // **The head-index suffix.** The reader takes exactly `heads.len()` values
    // when anything is left after the op data and none at all when nothing is
    // (`document.rs:131-136`), so a partial list is a body it refuses — one
    // that stops inside the suffix, and one that leaves bytes past it. The
    // writer refuses the same two with the reader's own names.
    const data = [_]u8{0x01};
    const descs = [_]ColumnDesc{ColumnDesc.init(ColumnSpec.make(3, .boolean, false), 1)};
    const cols = try RawColumns.init(gpa, &descs, &data);
    defer cols.deinit(gpa);
    try testing.expectError(
        error.UnexpectedEnd,
        encodeBody(gpa, DocumentBlock.init(&actors, &two_heads, no_changes, cols, &[_]u64{0})),
    );
    try testing.expectError(
        error.TrailingBytes,
        encodeBody(gpa, DocumentBlock.init(&actors, &one_head, no_changes, cols, &[_]u64{ 0, 1 })),
    );

    // **Zero indexes stays allowed, whatever the head count.** The suffix is
    // optional in the format (`document.rs:131-135`), so an empty list is the
    // older writer's rendering and not a mismatch: the body it writes reads
    // back with no suffix at all.
    const absent = try encodeBody(gpa, DocumentBlock.init(&actors, &two_heads, no_changes, cols, &.{}));
    defer gpa.free(absent);
    var doc = try parseDocumentChunk(absent, gpa);
    defer doc.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), doc.heads().len);
    try testing.expectEqual(@as(usize, 0), doc.headIndexes().len);

    // And one index per head is the third shape: emitted, and taken back.
    const matched = try encodeBody(gpa, DocumentBlock.init(
        &actors,
        &two_heads,
        no_changes,
        cols,
        &[_]u64{ 0, 1 },
    ));
    defer gpa.free(matched);
    var doc2 = try parseDocumentChunk(matched, gpa);
    defer doc2.deinit(gpa);
    try testing.expectEqualSlices(u64, &[_]u64{ 0, 1 }, doc2.headIndexes());

    // The half that keeps the refusals from being a blanket: a well-formed
    // block still writes, and re-encoding what the reader handed back
    // reproduces the body.
    const body = try encodeBody(gpa, DocumentBlock.init(
        &actors,
        &one_head,
        no_changes,
        cols,
        &[_]u64{0},
    ));
    defer gpa.free(body);
    var doc3 = try parseDocumentChunk(body, gpa);
    defer doc3.deinit(gpa);
    const again = try encodeBody(gpa, doc3.block);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, body, again);
}

/// One column a test expects a set to hold: the wire word of its
/// specification, and the length its range must cover.
const ColumnShape = struct {
    raw: u32,
    len: usize,
};

/// Asserts that a column set holds exactly `want`, in order, with the
/// specifications and lengths it names, and that the ranges tile the data
/// block.
fn expectColumnShape(cols: RawColumns, data: []const u8, want: []const ColumnShape) !void {
    try testing.expectEqual(want.len, cols.len());
    var at: usize = 0;
    var it = cols.iterator();
    for (want) |w| {
        const col = it.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(w.raw, col.spec.raw);
        try testing.expectEqual(w.len, col.len());
        try testing.expectEqual(at, col.range.start);
        try testing.expectEqualSlices(u8, data[at .. at + w.len], try col.bytes(data));
        at += w.len;
    }
    try testing.expect(it.next() == null);
    try testing.expectEqual(data.len, at);
}

// ── What the two writers hold, and what they refuse ──────────────────────

/// An allocator that records what it hands out, so a test can state a bound on
/// what a write holds at once rather than implying one. The same instrument as
/// `storage/totality_test.zig` §`Meter`, trimmed to the two numbers read here.
const ByteMeter = struct {
    inner: Allocator,
    /// Bytes handed out and not yet returned.
    live: usize = 0,
    /// The high-water mark of `live`.
    peak_live: usize = 0,

    fn allocator(self: *ByteMeter) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ByteMeter = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        self.live += len;
        self.peak_live = @max(self.peak_live, self.live);
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *ByteMeter = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(memory, alignment, new_len, ra)) return false;
        if (new_len > memory.len) {
            self.live += new_len - memory.len;
        } else self.live -= memory.len - new_len;
        self.peak_live = @max(self.peak_live, self.live);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *ByteMeter = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawRemap(memory, alignment, new_len, ra) orelse return null;
        if (new_len > memory.len) {
            self.live += new_len - memory.len;
        } else self.live -= memory.len - new_len;
        self.peak_live = @max(self.peak_live, self.live);
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ByteMeter = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.inner.rawFree(memory, alignment, ra);
    }
};

/// `count` op columns of `per` identical bytes each, so a test can make a
/// block whose data deflates to almost nothing without a hexane encoding
/// behind it. The column ids ascend, so the set is in the order the writer
/// and the reader both require.
///
/// **Many columns rather than one large one**, and the reason is
/// `chunk.compressRaw`: it reserves its output buffer at the length of the
/// column it is given (`outputCapacity`, `chunk.zig:350-352`), so a single
/// column of the whole body would have the compressor holding a buffer as
/// large as the body and the bound below would say nothing.
fn runsOf(gpa: Allocator, fill: u8, count: usize, per: usize) !Shape {
    const data = try gpa.alloc(u8, count * per);
    errdefer gpa.free(data);
    @memset(data, fill);
    const descs = try gpa.alloc(ColumnDesc, count);
    defer gpa.free(descs);
    for (descs, 0..) |*desc, i| {
        desc.* = ColumnDesc.init(ColumnSpec.make(@intCast(2 + i), .rle_uint, false), per);
    }
    return .{ .cols = try RawColumns.init(gpa, descs, data), .data = data };
}

test "the compressing writer refuses what the uncompressed one refuses" {
    const gpa = testing.allocator;
    const actors = [_][]const u8{&[_]u8{0xaa}};
    const one_head = [_]ChangeHash{.{ .bytes = @splat(0x11) }};
    const two_heads = [_]ChangeHash{
        .{ .bytes = @splat(0x11) },
        .{ .bytes = @splat(0x22) },
    };
    const threshold = CompressConfig{ .threshold = deflate_min_size };

    // **Both arms, both refusals, same names.** The compressing writer no
    // longer stages the uncompressed body, and `writeColumnMeta` is the only
    // place the column checks used to run — so this is the test that says the
    // staging pass was not what enforced them.
    {
        const data = [_]u8{ 0x7f, 0x00 };
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
        };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        const block = DocumentBlock.init(&actors, &one_head, empty_changes(), cols, &[_]u64{0});
        try testing.expectError(error.DuplicateColumn, encode(gpa, block, .none));
        try testing.expectError(error.DuplicateColumn, encode(gpa, block, threshold));
    }
    {
        const data = [_]u8{ 0x7f, 0x00 };
        const descs = [_]ColumnDesc{
            ColumnDesc.init(ColumnSpec.make(4, .rle_uint, false), 1),
            ColumnDesc.init(ColumnSpec.make(2, .actor, false), 1),
        };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        const block = DocumentBlock.init(&actors, &one_head, empty_changes(), cols, &[_]u64{0});
        try testing.expectError(error.InvalidColumnSpec, encode(gpa, block, .none));
        try testing.expectError(error.InvalidColumnSpec, encode(gpa, block, threshold));
    }
    {
        const data = [_]u8{0x7f};
        const descs = [_]ColumnDesc{ColumnDesc.init(ColumnSpec.make(3, .boolean, true), 1)};
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        const block = DocumentBlock.init(&actors, &one_head, empty_changes(), cols, &[_]u64{0});
        try testing.expectError(error.InvalidColumnSpec, encode(gpa, block, .none));
        try testing.expectError(error.InvalidColumnSpec, encode(gpa, block, threshold));
    }

    // And the suffix, whose two refusals are the reader's own names.
    {
        const data = [_]u8{0x01};
        const descs = [_]ColumnDesc{ColumnDesc.init(ColumnSpec.make(3, .boolean, false), 1)};
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        const short = DocumentBlock.init(&actors, &two_heads, empty_changes(), cols, &[_]u64{0});
        const long = DocumentBlock.init(&actors, &one_head, empty_changes(), cols, &[_]u64{ 0, 1 });
        try testing.expectError(error.UnexpectedEnd, encode(gpa, short, .none));
        try testing.expectError(error.UnexpectedEnd, encode(gpa, short, threshold));
        try testing.expectError(error.TrailingBytes, encode(gpa, long, .none));
        try testing.expectError(error.TrailingBytes, encode(gpa, long, threshold));
    }

    // The half that keeps the refusals from being a blanket: a block with a
    // column over the threshold still writes through the compressing arm, and
    // reads back with that column's bytes.
    {
        var shape = try runsOf(gpa, 0x5a, 1, deflate_min_size * 4);
        defer gpa.free(shape.data);
        defer shape.cols.deinit(gpa);
        const block = DocumentBlock.init(&actors, &one_head, empty_changes(), shape.cols, &[_]u64{0});
        const framed = try encode(gpa, block, threshold);
        defer gpa.free(framed);
        try testing.expect(framed.len < deflate_min_size * 2);
        var doc = try parseFramedChunk(try chunk.parseChunk(framed), gpa);
        defer doc.deinit(gpa);
        try testing.expect(doc.inflated != null);
        try testing.expectEqualSlices(u8, shape.data, (try shape.cols.bytesFor(shape.cols.columns[0].spec)).?);
    }
}

/// The empty column set, spelled once because the tests above build a block
/// whose change side is empty in every case.
fn empty_changes() RawColumns {
    return .{ .columns = &.{}, .data = &.{} };
}

test "the compressing writer never holds the uncompressed body" {
    const gpa = testing.allocator;
    const actors = [_][]const u8{&[_]u8{0xaa}};
    const heads = [_]ChangeHash{.{ .bytes = @splat(0x11) }};
    const indexes = [_]u64{0};

    // **Sixty-four columns of eight kilobytes, half a megabyte of one byte.**
    // Each column deflates to a few hundred bytes, so the written body is a few
    // kilobytes; the uncompressed body is half a megabyte, which is what the
    // staging buffer this arm used to build would have cost.
    var shape = try runsOf(gpa, 0x5a, 64, 8 * 1024);
    defer gpa.free(shape.data);
    defer shape.cols.deinit(gpa);
    const block = DocumentBlock.init(&actors, &heads, empty_changes(), shape.cols, &indexes);

    // **V, the uncompressed body, computed rather than measured** — which is
    // the claim the whole arrangement rests on, so the test computes it the
    // same way [`prefixLenOf`] and [`suffixLenOf`] do and checks it against a body
    // that was actually written.
    const plain = try encodeBody(gpa, block);
    defer gpa.free(plain);
    const V = prefixLenOf(block) + metaLenOf(block.changes) + metaLenOf(block.ops) +
        block.changes.data.len + block.ops.data.len + suffixLenOf(block);
    try testing.expectEqual(plain.len, V);

    // **The compressing writer's high-water mark is below V, which the staging
    // pass made impossible.** Every allocation it makes is the compressor's
    // 64 KiB window, one column's reserved output buffer (8 KiB plus
    // headroom), the deflated bytes themselves, or the body they are assembled
    // into: eighty kilobytes or so against a half-megabyte body.
    var meter: ByteMeter = .{ .inner = gpa };
    {
        const framed = try encode(meter.allocator(), block, .{ .threshold = deflate_min_size });
        defer meter.allocator().free(framed);
        try testing.expect(framed.len < 32 * 1024);
        try testing.expect(meter.peak_live < V);
    }
    try testing.expectEqual(@as(usize, 0), meter.live);

    // The uncompressed arm is the one that has to hold the body, and it holds
    // it twice: its own staging buffer and the framed output. That is the
    // contrast the claim is about, so it is measured too.
    var other: ByteMeter = .{ .inner = gpa };
    {
        const unframed = try encode(other.allocator(), block, .none);
        defer other.allocator().free(unframed);
        try testing.expect(other.peak_live >= 2 * V);
    }
    try testing.expect(other.peak_live > meter.peak_live);
    try testing.expectEqual(@as(usize, 0), other.live);
}

/// The number of bytes one column metadata block is: a count, then a
/// specification and a length per column.
fn metaLenOf(cols: RawColumns) usize {
    var n: usize = leb128.unsignedSize(cols.len());
    for (cols.columns) |col| n += leb128.unsignedSize(col.spec.raw) + leb128.unsignedSize(col.len());
    return n;
}

/// The number of bytes [`writePrefix`] appends, computed rather than measured:
/// a count, per actor a length prefix and its bytes, a count, and 32 bytes per
/// head.
fn prefixLenOf(block: DocumentBlock) usize {
    var n: usize = leb128.unsignedSize(block.actors.len);
    for (block.actors) |actor| n += leb128.unsignedSize(actor.len) + actor.len;
    n += leb128.unsignedSize(block.heads.len) + hash_size * block.heads.len;
    return n;
}

/// The number of bytes [`writeSuffix`] appends, computed rather than measured:
/// one uleb128 per head index. Its counterpart on the read side is the sum the
/// reader takes, and a suffix of any other length is one the writer refuses.
fn suffixLenOf(block: DocumentBlock) usize {
    var n: usize = 0;
    for (block.head_indexes) |index| n += leb128.unsignedSize(index);
    return n;
}

test "a body's regions sit where the block's own sizes put them" {
    const gpa = testing.allocator;
    // **The offsets are a function of the block, and this is the arithmetic
    // that says so.** Every number below is computed from the block with
    // nothing written; the body is then written and parsed, and every region
    // has to land where the arithmetic said. A writer that needed a staging
    // pass to learn an offset could not satisfy this.
    const actors = [_][]const u8{ &[_]u8{0xaa}, &[_]u8{ 0xbb, 0xcc } };
    const heads = [_]ChangeHash{
        .{ .bytes = @splat(0x11) },
        .{ .bytes = @splat(0x22) },
    };
    const indexes = [_]u64{ 1, 300 };

    const specs = [_]ColumnSpec{
        ColumnSpec.make(0, .actor, false),
        ColumnSpec.make(0, .rle_uint, false),
        ColumnSpec.make(1, .string, false),
        ColumnSpec.make(4, .rle_uint, false),
    };
    var shape = try shapeOf(gpa, &specs);
    defer gpa.free(shape.data);
    defer shape.cols.deinit(gpa);
    const block = DocumentBlock.init(&actors, &heads, empty_changes(), shape.cols, &indexes);

    const meta_start = prefixLenOf(block);
    const change_data_start = meta_start + metaLenOf(block.changes) + metaLenOf(block.ops);
    const op_data_start = change_data_start + block.changes.data.len;
    const suffix_start = op_data_start + block.ops.data.len;
    const body_len = suffix_start + suffixLenOf(block);

    const body = try encodeBody(gpa, block);
    defer gpa.free(body);
    try testing.expectEqual(body_len, body.len);

    // The prefix, read as the reader reads it: two actors of one and two
    // bytes, then two heads.
    var in: Input = .init(body);
    try testing.expectEqual(@as(u64, actors.len), try in.takeUleb());
    for (actors) |actor| {
        try testing.expectEqualSlices(u8, actor, try in.readStrBytes());
    }
    try testing.expectEqual(@as(u64, heads.len), try in.takeUleb());
    for (heads) |head| try testing.expectEqualSlices(u8, head.bytes[0..], try in.take(head.bytes.len));
    try testing.expectEqual(meta_start, in.pos);

    // Both metadata blocks, then the data, then the suffix — each boundary
    // where the arithmetic put it.
    try testing.expectEqual(@as(u64, 0), try in.takeUleb()); // no change columns
    try testing.expectEqual(@as(u64, specs.len), try in.takeUleb());
    for (specs) |spec| {
        try testing.expectEqual(@as(u64, spec.raw), try in.takeUleb());
        try testing.expectEqual(@as(u64, 1), try in.takeUleb());
    }
    try testing.expectEqual(change_data_start, in.pos);
    try testing.expectEqual(op_data_start, in.pos); // the change data block is empty
    try testing.expectEqualSlices(u8, shape.data, (try in.sub(shape.cols.data.len)).rest());
    try testing.expectEqual(suffix_start, in.pos);
    try testing.expectEqual(@as(u64, indexes[0]), try in.takeUleb());
    try testing.expectEqual(@as(u64, indexes[1]), try in.takeUleb());
    try testing.expectEqual(body_len, in.pos);
    try testing.expect(in.isEmpty());

    // **And the same arithmetic through the compressing writer**, whose body
    // is a different length and whose metadata says so: with nothing over the
    // threshold it is the uncompressed body, byte for byte.
    const huge = CompressConfig{ .threshold = std.math.maxInt(usize) };
    const same = try encode(gpa, block, huge);
    defer gpa.free(same);
    const framed_plain = try encode(gpa, block, .none);
    defer gpa.free(framed_plain);
    try testing.expectEqualSlices(u8, framed_plain, same);
}
