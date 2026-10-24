//! The six scripted documents the port and the reference must agree on, and
//! the comparisons both directions of the save interop make.
//!
//! `tools/oracle/src/save_interop.rs` builds the same six histories through the
//! reference's `Automerge`. Both sides commit the same operations in the same
//! order, under the same two actors, at the same time, with the same commit
//! messages — so every change hash is pinned before the encoder is reached,
//! because an operation's identity is `(actor, counter)` and the counter is
//! handed out in the order the operations were written.
//!
//! Test-only: imported by `test/save_interop_test.zig` and by the
//! `test/save_interop.zig` executable, and by nothing else. It reaches the
//! library through the named `zautomerge` import only, so nothing here can
//! reach into a private to make a case easier.
//!
//! Actors: A is fifteen bytes of `0xa1` and B is sixteen of `0xb2`, the same
//! bytes `tools/oracle/src/main.rs` spells `ACTOR_A = "a1a1…a1"` and
//! `ACTOR_B = "b2b2…b2"`. They are static arrays, not the ASCII of those hex
//! literals: the actor on the wire is the decoded byte string, and a document
//! built over thirty-two characters is a different document. The array is also
//! what keeps them alive, since `setActorId` borrows the bytes and every commit
//! reads them again.

const std = @import("std");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

const Allocator = std.mem.Allocator;
const Document = am.doc.Document;
const Changes = am.doc.Changes;
const Change = am.change_record.Change;
const ChangeHash = am.ChangeHash;
const ExId = am.ExId;
const TextEncoding = am.TextEncoding;
const Tx = am.Transaction;

const chunkmod = am.storage.chunk;
const docchunk = am.storage.document_chunk;
const columnspec = am.storage.column_spec;
const parse = am.storage.parse;

const ParseError = am.ParseError;

/// A change hash is `types.hash_size` bytes, so its hex is twice that and fits
/// on the stack.
const hash_hex_len = am.types.hash_size * 2;

/// The smallest a column descriptor is on the wire: a one-byte specification
/// and a one-byte length (`document_chunk.zig:391-395`). `parse.Input`
/// divides what is left by it to bound the count before believing it.
const min_desc_size: usize = 2;

/// The refusal every comparison here ends in, after printing what disagreed.
/// One error, because six different ones would let a caller tell a mismatch
/// from a malformed record and quietly check less than it believes it did.
pub const Mismatch = error.SaveInteropMismatch;

// ── The corpus ───────────────────────────────────────────────────────────────

/// The six scenario ids, in the order both oracle commands emit records in.
/// **The id is the whole contract between the two sides**: this side refuses a
/// record naming an id it does not know, and the oracle refuses one that is not
/// one of its six.
pub const Id = enum {
    map,
    list,
    text,
    marks,
    conflicts,
    merge,

    /// The id as a record's `scenario` field spells it.
    pub fn name(self: Id) []const u8 {
        return @tagName(self);
    }
};

/// The six ids, in record order. Every consumer walks this.
pub const ids = [_]Id{ .map, .list, .text, .marks, .conflicts, .merge };

/// How many scenarios there are.
pub const id_count = ids.len;

/// The `kind` of a record `tools/oracle`'s `save-interop` writes, and the kind
/// `test/golden/save-interop.jsonl` holds: the reference's own `save()` of a
/// document it built from the same script.
pub const golden_kind = "save-interop";

/// The `kind` of a record `verify-save-interop` writes: the reference's re-save
/// of the document **the port's bytes** loaded into. Different provenance from
/// [`golden_kind`], so the two corpora are not interchangeable and every
/// comparison names the kind it was handed.
pub const cross_loaded_kind = "cross-loaded";

/// The `kind` this port writes into a record it asks the oracle to check. The
/// oracle refuses any other, which is what stops a request being read as an
/// answer.
pub const request_kind = "port-save";

// ── The fixed history ────────────────────────────────────────────────────────

/// Actor A: fifteen bytes of `0xa1`.
pub const actor_a = @as([15]u8, @splat(0xa1));

/// Actor B: sixteen bytes of `0xb2`.
pub const actor_b = @as([16]u8, @splat(0xb2));

/// The timestamp every commit in every scenario carries.
pub const commit_time: i64 = 1_700_000_000;

/// The encoding both sides index text in, so a splice position means the same
/// unit on both sides.
pub const encoding: TextEncoding = .unicode_code_point;

/// What `map` writes under `bytes`, named because a `ScalarValue.bytes` borrows
/// it and the change is encoded after the `put` that wrote it has returned.
const three_bytes = [_]u8{ 0, 1, 255 };

/// How many elements `list/base` writes. `list/update`'s arithmetic on that
/// length is written against this constant rather than a literal.
pub const base_elements: usize = 200;

/// The scenario named by `id`, built from scratch.
///
/// The document is **owned by the caller**, and `io` is borrowed for as long
/// as it lives: the op set draws actors through it, so a document may not
/// outlive the provider it was handed.
///
/// Every document here is raw. Each transaction is committed explicitly, with
/// its message and timestamp, so the change's extras column carries what the
/// oracle's records carry. On script failure the caller destroys the complete
/// document, so journal disposal need not attempt a fallible rollback.
pub fn build(gpa: Allocator, io: std.Io, id: Id) !Document {
    return switch (id) {
        .map => scripted(gpa, io, mapScript),
        .list => scripted(gpa, io, listScript),
        .text => scripted(gpa, io, textScript),
        .marks => scripted(gpa, io, marksScript),
        .conflicts => forkedApplied(gpa, io),
        .merge => forkedMerged(gpa, io),
    };
}

/// An empty document under actor A, plus one script run against it.
fn scripted(
    gpa: Allocator,
    io: std.Io,
    script: fn (Allocator, *Document) anyerror!void,
) !Document {
    var doc = try newDoc(gpa, io);
    errdefer doc.deinit();
    try script(gpa, &doc);
    return doc;
}

fn newDoc(gpa: Allocator, io: std.Io) !Document {
    var doc = try Document.init(gpa, io);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = &actor_a });
    return doc;
}

/// `conflicts`: the peer's change applied **without a merge call** —
/// `getChangesAdded` plus `applyChanges`, which is upstream's
/// `Automerge::merge` with the merge call removed (`automerge.rs:1115-1131`).
fn forkedApplied(gpa: Allocator, io: std.Io) !Document {
    var pair = try forked(gpa, io);
    defer pair.right.deinit();
    var added = try pair.left.getChangesAdded(gpa, &pair.right);
    defer added.deinit(gpa);
    const view = try changeView(gpa, &added);
    defer gpa.free(view);
    _ = try pair.left.applyChanges(gpa, view);
    return pair.left;
}

/// `merge`: both merges, and no change of its own. `left` is the document
/// returned, and `right`'s own merge is what leaves both sides holding the
/// document `left` already had.
fn forkedMerged(gpa: Allocator, io: std.Io) !Document {
    var pair = try forked(gpa, io);
    defer pair.right.deinit();
    const after_left = try pair.left.merge(gpa, &pair.right);
    gpa.free(after_left);
    const after_right = try pair.right.merge(gpa, &pair.left);
    gpa.free(after_right);
    return pair.left;
}

/// `map`: every scalar type the format has, a counter written four times, a
/// delete, and a nested map written twice. Two commits, so the second change
/// has a dependency and the op counters continue across the boundary.
fn mapScript(gpa: Allocator, doc: *Document) !void {
    {
        var tx = try Tx.open(gpa, doc);
        defer tx.deinitClosed();

        _ = try tx.put(.root, .{ .key = "title" }, .{ .str = "title" });
        _ = try tx.put(.root, .{ .key = "int" }, .{ .int = -7 });
        _ = try tx.put(.root, .{ .key = "uint" }, .{ .uint = std.math.maxInt(u64) });
        _ = try tx.put(.root, .{ .key = "bool" }, .{ .bool_value = true });
        _ = try tx.put(.root, .{ .key = "null" }, .null_value);
        _ = try tx.put(.root, .{ .key = "str" }, .{ .str = "na\u{00ef}ve🦊" });
        _ = try tx.put(.root, .{ .key = "bytes" }, .{ .bytes = &three_bytes });
        _ = try tx.put(.root, .{ .key = "timestamp" }, .{ .timestamp = commit_time });
        _ = try tx.put(.root, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
        _ = try tx.put(.root, .{ .key = "removed" }, .{ .str = "gone" });
        const nested = try tx.putObject(.root, .{ .key = "nested" }, .map);
        _ = try tx.put(nested, .{ .key = "value" }, .{ .int = 1 });
        _ = try tx.put(nested, .{ .key = "value" }, .{ .int = 2 });
        _ = try tx.delete(.root, .{ .key = "removed" });
        var base_result = try tx.commitWith(.{ .message = "map/base", .time = commit_time });
        base_result.deinit(gpa);
    }

    var update = try Tx.open(gpa, doc);
    defer update.deinitClosed();
    _ = try update.increment(.root, .{ .key = "counter" }, 3);
    _ = try update.increment(.root, .{ .key = "counter" }, -1);
    _ = try update.increment(.root, .{ .key = "counter" }, 10);
    _ = try update.put(.root, .{ .key = "title" }, .{ .str = "updated" });
    var result = try update.commitWith(.{ .message = "map/update", .time = commit_time });
    result.deinit(gpa);
}

/// `list`: two hundred elements, then a commit that splices strings and whole
/// objects into the middle and deletes three times from the front.
///
/// This is the corpus that has to make the save format work: two hundred rows
/// push columns past [`docchunk.deflate_min_size`], so a default `save()`
/// deflates at least one of them and the normalized comparison is a comparison
/// of inflated content rather than of two identical uncompressed bodies.
fn listScript(gpa: Allocator, doc: *Document) !void {
    const list = blk: {
        var base = try Tx.open(gpa, doc);
        defer base.deinitClosed();

        const made = try base.putObject(.root, .{ .key = "list" }, .list);
        for (0..base_elements) |index| {
            _ = try base.insert(made, index, .{ .int = @intCast(index) });
        }
        var base_result = try base.commitWith(.{ .message = "list/base", .time = commit_time });
        base_result.deinit(gpa);
        break :blk made;
    };

    // **Read after the base commit, not through the transaction.** The
    // reference reads the length with `tx.length(&list)`, which counts its own
    // pending inserts, while this port's `read.length` reads the document. The
    // assertion is what stops the arithmetic below from silently describing a
    // different document if the base script ever changes.
    const committed = try am.read.length(doc, list);
    if (committed != base_elements) return error.ScriptDrift;

    var update = try Tx.open(gpa, doc);
    defer update.deinitClosed();

    _ = try update.insert(list, 0, .{ .str = "head" });
    _ = try update.insert(list, 100, .{ .str = "middle" });
    // **`base_elements + 2`, not `base_elements`**: the reference's
    // `tx.length(&list)` here counts the two inserts above, and that is what
    // "append at the current length" means on that side.
    _ = try update.insert(list, base_elements + 2, .{ .str = "tail" });
    const inserted_map = try update.insertObject(list, 100, .map);
    _ = try update.put(inserted_map, .{ .key = "ok" }, .{ .bool_value = true });
    const inserted_list = try update.insertObject(list, 101, .list);
    _ = try update.insert(inserted_list, 0, .{ .str = "inner" });
    _ = try update.delete(list, .{ .index = 7 });
    _ = try update.delete(list, .{ .index = 7 });
    _ = try update.delete(list, .{ .index = 7 });
    var result = try update.commitWith(.{ .message = "list/update", .time = commit_time });
    result.deinit(gpa);
}

/// `text`: a spliced text object, a delete that leaves a hole, a prepend, and a
/// second text object. Three transactions, so each one's operations land at the
/// offsets the ones before it left behind.
fn textScript(gpa: Allocator, doc: *Document) !void {
    {
        var base = try Tx.open(gpa, doc);
        defer base.deinitClosed();

        const text = try base.putObject(.root, .{ .key = "text" }, .text);
        try base.spliceText(text, 0, 0, "hello world");
        var base_result = try base.commitWith(.{ .message = "text/base", .time = commit_time });
        base_result.deinit(gpa);
    }

    // Read through the document, not through a transaction: the reference
    // reads the child id between transactions, and a later transaction
    // resolves the same object from the same id.
    const text_id = try childId(doc, "text");

    {
        var hole = try Tx.open(gpa, doc);
        defer hole.deinitClosed();
        try hole.spliceText(text_id, 5, 6, "");
        var hole_result = try hole.commitWith(.{ .message = "text/delete", .time = commit_time });
        hole_result.deinit(gpa);
    }

    var prepend = try Tx.open(gpa, doc);
    defer prepend.deinitClosed();
    try prepend.spliceText(text_id, 0, 0, "αβγ");
    const second = try prepend.putObject(.root, .{ .key = "second" }, .text);
    try prepend.spliceText(second, 0, 0, "second");
    var result = try prepend.commitWith(.{ .message = "text/prepend", .time = commit_time });
    result.deinit(gpa);
}

/// `marks`: every expansion there is, on one text object and on a second one
/// written only to carry the four expansion flags.
///
/// The unmark shares a commit with the marks it removes, so the mark fold has
/// to read the whole change rather than the visible state at its end. The four
/// marks over `[0, 1)` of `mark_modes` differ **only** in expansion, which is
/// what separates an implementation that stores the flag from one that applies
/// it and drops it.
fn marksScript(gpa: Allocator, doc: *Document) !void {
    {
        var base = try Tx.open(gpa, doc);
        defer base.deinitClosed();

        const text = try base.putObject(.root, .{ .key = "text" }, .text);
        try base.spliceText(text, 0, 0, "abcdefghij");
        var base_result = try base.commitWith(.{ .message = "marks/base", .time = commit_time });
        base_result.deinit(gpa);
    }

    const text_id = try childId(doc, "text");

    var edit = try Tx.open(gpa, doc);
    defer edit.deinitClosed();

    try edit.mark(text_id, 3, 6, "bold", .after, .{ .int = 0 });
    try edit.mark(text_id, 0, 1, "italic", .none, .{ .bool_value = true });
    try edit.mark(text_id, 6, 9, "label", .both, .{ .str = "name" });
    try edit.unmark(text_id, 0, 1, .none, "italic", null);
    const modes = try edit.putObject(.root, .{ .key = "mark_modes" }, .text);
    try edit.spliceText(modes, 0, 0, "xyz");
    try edit.mark(modes, 0, 1, "none", .none, .{ .str = "active" });
    try edit.mark(modes, 0, 1, "before", .before, .{ .str = "active" });
    try edit.mark(modes, 0, 1, "after", .after, .{ .str = "active" });
    try edit.mark(modes, 0, 1, "both", .both, .{ .str = "active" });
    var result = try edit.commitWith(.{ .message = "marks/edit", .time = commit_time });
    result.deinit(gpa);
}

/// The two documents the forked scenarios return. **A pair of owners**: the
/// caller releases `right` and hands `left` on, so a copy of either would be a
/// second owner of the same document.
const Pair = struct {
    left: Document,
    right: Document,
};

/// The history `conflicts` and `merge` both begin with: a base committed by
/// actor A, its saved bytes loaded twice, and each side writing its own change
/// concurrently.
///
/// **Load, not fork.** The reference loads the base's saved bytes twice
/// (`save_interop.rs`'s `forked`), and loading is the comparison's subject: a
/// fork would rebuild the document through a different door, and a difference
/// between the two would be this file's rather than the wire format's.
///
/// `left` keeps actor A, `right` selects actor B. Both changes depend on the
/// base alone, so the document they reach has two heads, one conflicted scalar,
/// a counter that adds up to three, and two concurrent sequence insertions.
fn forked(gpa: Allocator, io: std.Io) !Pair {
    var base = try newDoc(gpa, io);
    defer base.deinit();

    {
        var base_tx = try Tx.open(gpa, &base);
        defer base_tx.deinitClosed();
        _ = try base_tx.put(.root, .{ .key = "value" }, .{ .str = "base" });
        _ = try base_tx.put(.root, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
        _ = try base_tx.put(.root, .{ .key = "doomed" }, .{ .str = "x" });
        const base_list = try base_tx.putObject(.root, .{ .key = "list" }, .list);
        _ = try base_tx.insert(base_list, 0, .{ .int = 11 });
        _ = try base_tx.insert(base_list, 1, .{ .int = 22 });
        _ = try base_tx.insert(base_list, 2, .{ .int = 33 });
        var base_result = try base_tx.commitWith(.{ .message = "branch/base", .time = commit_time });
        base_result.deinit(gpa);
    }

    const base_bytes = try base.save(gpa);
    defer gpa.free(base_bytes);

    var left = try Document.load(gpa, io, base_bytes, encoding);
    errdefer left.deinit();
    var right = try Document.load(gpa, io, base_bytes, encoding);
    errdefer right.deinit();

    left.setActorId(.{ .bytes = &actor_a });
    right.setActorId(.{ .bytes = &actor_b });

    const left_list = try childId(&left, "list");
    const right_list = try childId(&right, "list");

    {
        var left_tx = try Tx.open(gpa, &left);
        defer left_tx.deinitClosed();
        _ = try left_tx.put(.root, .{ .key = "value" }, .{ .str = "left" });
        _ = try left_tx.increment(.root, .{ .key = "counter" }, 1);
        _ = try left_tx.delete(.root, .{ .key = "doomed" });
        _ = try left_tx.insert(left_list, 1, .{ .str = "left" });
        var left_result = try left_tx.commitWith(.{ .message = "branch/left", .time = commit_time });
        left_result.deinit(gpa);
    }

    var right_tx = try Tx.open(gpa, &right);
    defer right_tx.deinitClosed();
    _ = try right_tx.put(.root, .{ .key = "value" }, .{ .str = "right" });
    _ = try right_tx.increment(.root, .{ .key = "counter" }, 2);
    _ = try right_tx.delete(.root, .{ .key = "doomed" });
    _ = try right_tx.insert(right_list, 1, .{ .str = "right" });
    var result = try right_tx.commitWith(.{ .message = "branch/right", .time = commit_time });
    result.deinit(gpa);

    return .{ .left = left, .right = right };
}

/// The object at `key` under the root, read through the document's own read
/// surface. Its id is stable for the life of the object, which is why the
/// reference reads it once between transactions and keeps it.
fn childId(doc: *const Document, key: []const u8) !ExId {
    const item = (try am.read.get(doc, .root, .{ .key = key })) orelse
        return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

/// `changes` as the flat `[]Change` [`Document.applyChanges`] takes.
///
/// **A view, not a copy of the bytes.** Each [`Change`] borrows the body the
/// [`Changes`] list owns, so the list must outlive the slice.
fn changeView(gpa: Allocator, changes: *const Changes) ![]Change {
    const view = try gpa.alloc(Change, changes.len());
    errdefer gpa.free(view);
    for (view, 0..) |*slot, index| slot.* = changes.at(index);
    return view;
}

// ── Records ──────────────────────────────────────────────────────────────────

/// One change as a record names it.
pub const ChangeRecord = struct {
    hash: []const u8,
    seq: u64 = 0,
    start_op: u64 = 0,
    /// The **whole change chunk as it goes on the wire**: magic, checksum,
    /// type byte, length, body. Upstream's `Change::raw_bytes`, deliberately
    /// not `Change::bytes` — the latter deflates a big change, which is a
    /// property of the encoder's mood rather than of the change.
    raw_hex: []const u8,
};

/// One NDJSON line of a save-interop record.
///
/// The shared comparison fields are required. A live `cross-loaded` response
/// also requires `reference_hex`, the independently built Rust save; golden
/// records already put that save in `hex`. The reference's `root` field is
/// deliberately absent — this side compares materialized state with
/// [`am.read.hydrate`] and [`am.hydrate.Value.eql`] instead, which is the same
/// claim about the same state made by a comparison this side can actually make.
/// Unknown fields are ignored, so the same struct reads the golden vector and
/// the live records alike.
pub const Record = struct {
    kind: []const u8,
    scenario: []const u8,
    hex: []const u8,
    heads: []const []const u8,
    hashes: []const []const u8,
    changes: []const ChangeRecord,
    reference_hex: ?[]const u8 = null,
};

/// The records [`parseRecords`] returns, allocated from the arena it was given.
pub const RecordList = std.ArrayList(Record);

/// Every record in `text`, with every string in every record allocated from
/// `arena`.
///
/// **`parseFromSliceLeaky`, so nothing has to be released field by field.** The
/// caller owns the arena and drops it when it is done with the records; the
/// list itself comes from the same arena, so there is one release for the whole
/// parse and nothing a caller can forget half of. There is deliberately no
/// `errdefer`: a partial list is released by that same one release.
pub fn parseRecords(arena: Allocator, text: []const u8) !RecordList {
    var out: RecordList = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const record = std.json.parseFromSliceLeaky(Record, arena, line, .{
            .ignore_unknown_fields = true,
        }) catch |e| {
            std.debug.print(
                "save-interop: record {d} is not a usable record: {s}\n",
                .{ out.items.len + 1, @errorName(e) },
            );
            return error.BadRecord;
        };
        try out.append(arena, record);
    }
    return out;
}

/// Requires that `records` names **every** scenario exactly once, and returns
/// the record for `id`.
///
/// **Cardinality is checked before anything is looked up.** A corpus missing a
/// scenario, or naming one twice, would otherwise let a caller check five of six
/// and report success — the failure mode the oracle's own reader refuses
/// (`save_interop.rs`'s `read_requests`), stated here for the same reason.
pub fn requireEveryScenario(records: RecordList, id: Id, label: []const u8) !Record {
    if (records.items.len != id_count) {
        std.debug.print(
            "save-interop: {s} holds {d} records, expected {d}\n",
            .{ label, records.items.len, id_count },
        );
        return error.BadRecord;
    }
    for (ids) |wanted| {
        var seen: usize = 0;
        for (records.items) |record| {
            if (std.mem.eql(u8, record.scenario, wanted.name())) seen += 1;
        }
        if (seen != 1) {
            std.debug.print(
                "save-interop: {s} names scenario `{s}` {d} times, expected once\n",
                .{ label, wanted.name(), seen },
            );
            return error.BadRecord;
        }
    }
    for (records.items) |record| {
        if (std.mem.eql(u8, record.scenario, id.name())) return record;
    }
    std.debug.print("save-interop: {s} has no record for `{s}`\n", .{ label, id.name() });
    return error.BadRecord;
}

// ── Normalizing a default save ───────────────────────────────────────────────

/// A default `save()`, reduced to the bytes both implementations must agree on.
///
/// **What normalization removes is exactly what physical compression changes**
/// and nothing else: the DEFLATE streams and the chunk framing over them. Every
/// actor, every head, every column descriptor in its order, every column's
/// encoding and data bytes, and the head-index suffix are kept, so a difference
/// in any of them is a difference in `body`.
pub const Normalized = struct {
    /// The document chunk's body with every column inflated: what
    /// [`docchunk.encodeBody`] writes for the parsed block.
    body: []u8,
    /// How many column descriptors in the **framed body as stored** carry the
    /// DEFLATE bit (`raw_column.rs:62-76`), counted before anything is
    /// inflated. This is the writer's own statement rather than a
    /// re-derivation of this port's threshold, which is exactly the difference
    /// that matters for the reference: its writer deflates the columns it
    /// chooses to, and the two are not required to choose the same ones.
    deflated_columns: usize,
    /// Whether the parse rebuilt the body. `parseDocumentChunk` rebuilds
    /// **exactly** when at least one descriptor carried the DEFLATE bit
    /// (`document/compression.rs:51-65`), so this is the evidence that a
    /// deflated column really was on the wire rather than one that merely would
    /// have been.
    inflated: bool,

    pub fn deinit(self: *Normalized, gpa: Allocator) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// `saved`, normalized.
///
/// **Refuses a stream that is not exactly one document chunk.** `parseChunk`
/// refuses trailing bytes, so an orphan change chunk appended after the
/// document chunk — which is what a save with queued changes looks like — is
/// refused here rather than silently normalized away, and `parseFramedChunk`
/// refuses any type but `.document`.
pub fn normalize(gpa: Allocator, saved: []const u8) !Normalized {
    const framed = try chunkmod.parseChunk(saved);
    // Counted off the body **as stored**, before the parse inflates anything:
    // `parseDocumentChunk` clears every DEFLATE bit as it rebuilds
    // (`document_chunk.zig:489-492`), so afterwards the flags are simply gone.
    const deflated = try countWireDeflated(framed.data);

    var parsed = try docchunk.parseFramedChunk(framed, gpa);
    defer parsed.deinit(gpa);

    return .{
        .body = try docchunk.encodeBody(gpa, parsed.block),
        .deflated_columns = deflated,
        .inflated = parsed.inflated != null,
    };
}

/// The number of DEFLATE descriptors in the framed body `body`, read where they
/// are actually stored.
///
/// The body layout is the one `parseDocumentChunk` walks
/// (`document_chunk.zig:436-451`): a uleb128 actor count and that many
/// length-prefixed byte strings, a uleb128 head count and `hash_size` raw bytes
/// per head, then the change and op metadata blocks back to back. This reads
/// those four sections with the crate's public cursor — `parse.Input`, with
/// `readCountThen` bounding each count against what is left — and reads each
/// specification with `column_spec.ColumnSpec`, so every byte is bounds-checked
/// by the same primitives the real reader uses and nothing here re-implements a
/// wire format.
fn countWireDeflated(body: []const u8) ParseError!usize {
    var in: parse.Input = .init(body);

    const actors: ActorSkip = .{ .in = &in };
    try in.readCountThen(&actors, 1, ActorSkip.collect);
    const heads: HeadSkip = .{ .in = &in };
    try in.readCountThen(&heads, am.types.hash_size, HeadSkip.collect);

    var deflated: usize = 0;
    for (0..2) |_| {
        const set: DeflateCount = .{ .in = &in, .into = &deflated };
        try in.readCountThen(&set, min_desc_size, DeflateCount.collect);
    }
    return deflated;
}

/// Reads past the actor table. An actor is a uleb128 length and that many
/// bytes, of any length including none (`parse.rs:503-510`), so one byte is the
/// smallest it can be.
const ActorSkip = struct {
    in: *parse.Input,

    fn collect(self: *const ActorSkip, count: usize) ParseError!void {
        for (0..count) |_| _ = try self.in.readStrBytes();
    }
};

/// Reads past the head list. A head is `hash_size` raw hash bytes and nothing
/// else (`parse.rs:515-519`), so thirty-two is both the minimum element size and
/// the element itself.
const HeadSkip = struct {
    in: *parse.Input,

    fn collect(self: *const HeadSkip, count: usize) ParseError!void {
        for (0..count) |_| _ = try self.in.takeArray([am.types.hash_size]u8);
    }
};

/// Reads one column metadata block, counting the specifications that carry the
/// DEFLATE bit. A descriptor is a specification and a length, both LEB128
/// (`raw_column.rs:226-228`); the length is read to step over it and is
/// otherwise unused, because a deflated column's declared length is its
/// *compressed* size and says nothing about whether it was deflated.
const DeflateCount = struct {
    in: *parse.Input,
    into: *usize,

    fn collect(self: *const DeflateCount, count: usize) ParseError!void {
        for (0..count) |_| {
            const raw = std.math.cast(u32, try self.in.takeUleb()) orelse return error.Overflow;
            _ = try self.in.takeUleb();
            if (columnspec.ColumnSpec.fromRaw(raw).isCompressed()) self.into.* += 1;
        }
    }
};

// ── The comparison both directions make ──────────────────────────────────────

/// Checks the document [`build`] produces for `id` against the reference's
/// record for it: the record's own provenance, the head **set**, every change
/// **by hash identity** with its `seq`, `start_op` and whole framed chunk, the
/// reference's save **loading** here with [`Document.debugCmp`] and hydration
/// equality together, and this port's own **default** `save()` normalizing to
/// the same bytes as the reference's default save.
///
/// `record` must be a full record: a request this side wrote itself carries only
/// `kind`, `scenario` and `hex`, and is not an input here. `kind` names the
/// corpus the record came from — the reference's own build of the script, or its
/// re-save of the port's bytes — because the two are different provenance and a
/// comparison must say which one it was handed.
pub fn checkCase(gpa: Allocator, io: std.Io, id: Id, record: Record, kind: []const u8) !void {
    if (!std.mem.eql(u8, record.kind, kind)) {
        std.debug.print(
            "save-interop: `{s}`: the record's kind is `{s}`, expected `{s}`\n",
            .{ id.name(), record.kind, kind },
        );
        return Mismatch;
    }
    if (!std.mem.eql(u8, record.scenario, id.name())) {
        std.debug.print(
            "save-interop: `{s}`: the record names scenario `{s}`\n",
            .{ id.name(), record.scenario },
        );
        return Mismatch;
    }

    var doc = try build(gpa, io, id);
    defer doc.deinit();

    const reference_bytes = try am.error_types.hexFrom(gpa, record.hex);
    defer gpa.free(reference_bytes);

    var reference = try Document.load(gpa, io, reference_bytes, encoding);
    defer reference.deinit();

    try compareHeads(gpa, id, &doc, record);
    try compareChanges(gpa, id, &doc, record);
    try compareDocuments(id, &doc, &reference);
    const independent_bytes = if (std.mem.eql(u8, kind, cross_loaded_kind))
        try am.error_types.hexFrom(gpa, record.reference_hex orelse return error.MissingIndependentSave)
    else
        null;
    defer if (independent_bytes) |bytes| gpa.free(bytes);
    try compareBodies(gpa, id, &doc, reference_bytes, independent_bytes);
}

/// `hash` in lowercase hex, on the stack.
fn hexOf(hash: *const ChangeHash) [hash_hex_len]u8 {
    var out: [hash_hex_len]u8 = undefined;
    am.error_types.hexInto(&hash.bytes, &out);
    return out;
}

/// The head **sets**, as an unordered comparison: neither an order nor a
/// missing head can hide a difference.
fn compareHeads(gpa: Allocator, id: Id, doc: *const Document, record: Record) !void {
    const mine = try doc.getHeads(gpa);
    defer gpa.free(mine);

    if (mine.len != record.heads.len) {
        std.debug.print(
            "save-interop: `{s}`: {d} heads here, {d} in the record\n",
            .{ id.name(), mine.len, record.heads.len },
        );
        return Mismatch;
    }
    for (mine) |*head| {
        const text = hexOf(head);
        var found = false;
        for (record.heads) |want| {
            if (std.mem.eql(u8, want, &text)) found = true;
        }
        if (!found) {
            std.debug.print(
                "save-interop: `{s}`: head {s} is not among the record's heads\n",
                .{ id.name(), &text },
            );
            return Mismatch;
        }
    }
}

/// Every change, **by hash identity**: the same hashes, and under each of them
/// the same `seq`, the same `start_op`, and the same whole framed chunk.
///
/// The record's bytes are compared as hex text against this port's own hex, out
/// of one scratch buffer sized from the record: both sides are the oracle's
/// lowercase hex (`hex_encode`, `main.rs:1820-1828`), so decoding the record
/// would only buy a second copy of every change.
fn compareChanges(gpa: Allocator, id: Id, doc: *Document, record: Record) !void {
    var mine = try doc.getChanges(gpa, &[_]ChangeHash{});
    defer mine.deinit(gpa);

    if (mine.len() != record.changes.len or mine.len() != record.hashes.len) {
        std.debug.print(
            "save-interop: `{s}`: {d} changes here, {d} in the record's change list and {d} in its hash list\n",
            .{ id.name(), mine.len(), record.changes.len, record.hashes.len },
        );
        return Mismatch;
    }

    var widest: usize = 0;
    for (record.changes) |entry| widest = @max(widest, entry.raw_hex.len);
    const scratch = try gpa.alloc(u8, widest);
    defer gpa.free(scratch);

    for (mine.slice()) |*built| {
        const hash_hex = hexOf(&built.change.hash);
        var listed = false;
        for (record.hashes) |want| {
            if (std.mem.eql(u8, want, &hash_hex)) listed = true;
        }
        if (!listed) {
            std.debug.print(
                "save-interop: `{s}`: change {s} is not in the record's hash list\n",
                .{ id.name(), hash_hex },
            );
            return Mismatch;
        }

        const entry = findChange(record.changes, &hash_hex) orelse {
            std.debug.print(
                "save-interop: `{s}`: the record's change list has no entry for {s}\n",
                .{ id.name(), &hash_hex },
            );
            return Mismatch;
        };
        if (entry.seq != built.change.seq or entry.start_op != built.change.start_op) {
            std.debug.print(
                "save-interop: `{s}`: change {s} is seq {d} start_op {d} here and seq {d} start_op {d} in the record\n",
                .{ id.name(), &hash_hex, built.change.seq, built.change.start_op, entry.seq, entry.start_op },
            );
            return Mismatch;
        }

        const framed = try built.change.encode(gpa);
        defer gpa.free(framed);
        // The length is checked before anything is written, so `scratch` — which
        // is at least `entry.raw_hex.len` bytes by construction — cannot be
        // overrun even in `ReleaseFast`.
        if (entry.raw_hex.len != framed.len * 2) {
            std.debug.print(
                "save-interop: `{s}`: change {s} is {d} bytes here and {d} in the record\n",
                .{ id.name(), &hash_hex, framed.len, entry.raw_hex.len / 2 },
            );
            return Mismatch;
        }
        const got = scratch[0..entry.raw_hex.len];
        am.error_types.hexInto(framed, got);
        if (!std.mem.eql(u8, got, entry.raw_hex)) {
            std.debug.print(
                "save-interop: `{s}`: change {s} differs at byte {d}\n",
                .{ id.name(), &hash_hex, firstDifference(got, entry.raw_hex) / 2 },
            );
            return Mismatch;
        }
    }
}

/// The record's entry for `hash_hex`, or null when it names none.
fn findChange(theirs: []const ChangeRecord, hash_hex: []const u8) ?ChangeRecord {
    for (theirs) |record| {
        if (std.mem.eql(u8, record.hash, hash_hex)) return record;
    }
    return null;
}

/// Where two byte strings stop agreeing, or the length of the shorter one when
/// one is a prefix of the other.
fn firstDifference(a: []const u8, b: []const u8) usize {
    const shared = @min(a.len, b.len);
    for (a[0..shared], b[0..shared], 0..) |mine, theirs, at| {
        if (mine != theirs) return at;
    }
    return shared;
}

/// The reference's save loaded here **is** this port's document: the op sets
/// compare with [`Document.debugCmp`], and the materialized state compares
/// through the read surface with hydration equality.
///
/// **Both, and not either.** `debugCmp` checks soundness on both sides before
/// it compares anything, so two equally broken documents cannot pass it; the
/// hydration comparison reads the same state through a different surface, so a
/// difference the column walk cannot see and a difference the materialization
/// cannot see are both caught.
fn compareDocuments(id: Id, mine: *const Document, theirs: *const Document) !void {
    const my_stats = mine.stats();
    const their_stats = theirs.stats();
    if (my_stats.num_changes != their_stats.num_changes or
        my_stats.num_ops != their_stats.num_ops or
        my_stats.num_actors != their_stats.num_actors)
    {
        std.debug.print(
            "save-interop: `{s}`: {d}/{d}/{d} changes/ops/actors here and {d}/{d}/{d} in the reference save\n",
            .{
                id.name(),               my_stats.num_changes, my_stats.num_ops,       my_stats.num_actors,
                their_stats.num_changes, their_stats.num_ops,  their_stats.num_actors,
            },
        );
        return Mismatch;
    }

    mine.debugCmp(theirs) catch |e| {
        std.debug.print(
            "save-interop: `{s}`: the reference save does not debugCmp against this build: {s}\n",
            .{ id.name(), @errorName(e) },
        );
        return Mismatch;
    };

    const gpa = mine.allocator();
    var my_value = try am.read.hydrate(mine, .root, null, gpa);
    defer my_value.deinit();
    var their_value = try am.read.hydrate(theirs, .root, null, gpa);
    defer their_value.deinit();
    if (!my_value.eql(&their_value)) {
        std.debug.print(
            "save-interop: `{s}`: the reference save materializes a different root\n",
            .{id.name()},
        );
        return Mismatch;
    }
}

/// Whether the parse rebuilt the body or left the caller's own bytes as it:
/// upstream's `compression::Decompressed` `Cow::Owned` and `Cow::Borrowed` arms
/// (`document/compression.rs:51-65`).
fn rebuiltOrBorrowed(inflated: bool) []const u8 {
    return if (inflated) "rebuilt" else "borrowed";
}

/// Compare the default save body with both reference provenances. Save the
/// native document once; a Rust re-save alone can retain incorrect input tags.
fn compareBodies(gpa: Allocator, id: Id, mine: *Document, reference_bytes: []const u8, independent_bytes: ?[]const u8) !void {
    const saved = try mine.save(gpa);
    defer gpa.free(saved);
    var my_body = try normalize(gpa, saved);
    defer my_body.deinit(gpa);

    if (id == .list and (my_body.deflated_columns == 0 or !my_body.inflated)) {
        std.debug.print(
            "save-interop: `list`: this port's save carries {d} deflated descriptors on the wire, and its parse {s} the body\n",
            .{ my_body.deflated_columns, rebuiltOrBorrowed(my_body.inflated) },
        );
        return Mismatch;
    }

    for ([_]?[]const u8{ reference_bytes, independent_bytes }, 0..) |maybe_bytes, i| {
        const bytes = maybe_bytes orelse continue;
        var their_body = try normalize(gpa, bytes);
        defer their_body.deinit(gpa);
        const label = if (i == 0) "record save" else "independent Rust save";
        // Check the descriptors as stored, not the inflated column lengths.
        if (id == .list and (their_body.deflated_columns == 0 or !their_body.inflated)) {
            std.debug.print(
                "save-interop: `list`: {s} carries {d} deflated descriptors on the wire, and its parse {s} the body\n",
                .{ label, their_body.deflated_columns, rebuiltOrBorrowed(their_body.inflated) },
            );
            return Mismatch;
        }
        if (!std.mem.eql(u8, my_body.body, their_body.body)) {
            std.debug.print(
                "save-interop: `{s}`: normalized save differs from {s}: {d} bytes here, {d} there, first difference at byte {d}\n",
                .{ id.name(), label, my_body.body.len, their_body.body.len, firstDifference(my_body.body, their_body.body) },
            );
            return Mismatch;
        }
    }
}
