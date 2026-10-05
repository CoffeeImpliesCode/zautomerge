//! The change record: one change's metadata plus the bytes it was decoded from.
//!
//! A change is the unit of causality. It names the changes it depends on, the
//! actor that authored it, where its op counters start, and its ops. The ops
//! are columnar; the borrowed header view and independent expanded records
//! share the existing document column encoder/decoder rather than a second codec.
//!
//! A change chunk is `[4 magic][4 checksum][1 type][uleb len][body]`, and the
//! change hash is `SHA-256(type || uleb(len) || body)`
//! (`storage/chunk.zig`), and a chunk's checksum field is the first four
//! bytes of that hash. So the hash covers the body, the body covers the
//! header, and a change's identity cannot be known without its bytes — which
//! is why `Change` keeps the two together instead of storing the header twice.
//!
//! ## The change chunk body
//!
//! ```text
//! offset  size  field
//! 0       n     deps: uleb128 count, then count * 32 raw hash bytes
//! ...     n     actor: uleb128 byte count + raw bytes
//! ...     n     seq: uleb128
//! ...     n     start_op: nonzero uleb128
//! ...     n     time: sleb128, seconds since the epoch
//! ...     n     message: uleb128 byte count + UTF-8 bytes
//! ...     n     other_actors: uleb128 count, then per actor uleb128 length + bytes
//! ...     m     the op columns, and after them the author footer
//! ```
//!
//! Every one of those is FORMAT. Upstream's reader is
//! `storage/change.rs:100-156` and its writer is
//! `ChangeBuilder::build` (`storage/change.rs:453-522`); the two agree
//! field for field, and this port is checked against both.
//!
//! Three details are easy to get wrong and each is pinned by a test below:
//!
//! * A dependency is 32 raw bytes with **no** length prefix. Only the count is
//!   length-prefixed (`storage/change.rs:470-473`).
//! * `start_op` must not be zero. Upstream reads it as a `NonZeroU64`
//!   (`parse/leb128.rs:87-96`) and treats a zero as `UnexpectedZero`; this
//!   port has no `NonZeroU64`, so the check is explicit and reports
//!   `error.InvalidLeb128`.
//! * `time` is **signed**. A timestamp before 1970 is a negative sleb128, and
//!   writing it as uleb128 changes the change hash.
//!
//! ## Borrowed parsing and owned decoding
//!
//! `parseChange` reads the header and leaves the op columns where they are.
//! The op count is not in the header — it is the row count of the columns —
//! so a header-only parse leaves `max_op` at 0 until `withOpCount` is called.
//! `Change.decode` builds an independent ExpandedChange, while `fromBytes`
//! validates all operations and returns an owned body with its count filled in.
//!
//! The complete author footer remains in the borrowed body; `extraBytes` locates
//! it without retaining decoded ops. ExpandedChange owns these opaque bytes and
//! preserves them verbatim; its parsed `author` is informational, as in Rust.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const leb128 = @import("leb128.zig");
const parse = @import("storage/parse.zig");
const chunk = @import("storage/chunk.zig");
const changechunk = @import("storage/change_chunk.zig");
const doccodec = @import("doc.zig");
const opmod = @import("opset/op.zig");
const value = @import("value.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ChangeHash = types.ChangeHash;
const hash_size = types.hash_size;
const Input = parse.Input;

comptime {
    // A run of dependencies is borrowed straight out of the input as a slice
    // of `ChangeHash`, which is only a re-interpretation when the hash is
    // exactly 32 bytes at alignment one. If a future `ChangeHash` grows a tag
    // or a length, this stops the port instead of misreading the body.
    if (@sizeOf(ChangeHash) != hash_size) @compileError("ChangeHash must stay 32 bytes wide");
    if (@alignOf(ChangeHash) != 1) @compileError("ChangeHash must stay alignment 1 to be borrowed from the input");
}

/// One change: its metadata, and the bytes it was decoded from.
///
/// `bytes` is the whole chunk body — header included — and every other field
/// either borrows from it or is a copy of a value read out of it. A `Change`
/// is therefore only valid while its `bytes` are, and it owns exactly one
/// allocation: the `other_actors` array `parseChange` makes. `deinit` frees
/// that and nothing else.
///
/// **"Owns one allocation" is a property of the value, not a promise that a
/// function returning a `Change` handed the caller a new one.** Where a
/// method returns a `Change` it says on the declaration whether the result is
/// a fresh owner or an alias of the receiver's
/// ([`withOpCount`](Change.withOpCount) is the one that aliases), because the
/// two shapes read identically at the call site and only one of them may be
/// deinited.
///
/// Use `parseChange` to get one. Building one by hand is fine and is what the
/// future change encoder does, but then `other_actors` is whatever slice the
/// caller put there and `deinit` must not be called on it.
pub const Change = struct {
    /// The change chunk body: the header this change was parsed from,
    /// followed by its op columns and the author footer. The change hash
    /// covers exactly these bytes, framed as a `ChunkType.change` chunk.
    bytes: []const u8,
    /// The length of the header: the op columns start here, and
    /// `bytes[0..header_len]` is the header, byte for byte as it was read.
    header_len: usize,
    /// The actor that authored the change. It is not in `other_actors`: a
    /// change names its author once, and the op columns number every actor
    /// from it (`change_actors.rs:10-14`).
    actor: ActorId,
    /// The changes that must be applied before this one. On the wire this is
    /// a count followed by fixed-width hashes, so the slice borrows
    /// `bytes`; in a stored change it is sorted, because the writer sorts
    /// before encoding (`ChangeBuilder::with_dependencies`,
    /// `storage/change.rs:343-344`).
    deps: []const ChangeHash,
    /// `SHA-256(0x01 || uleb128(len(bytes)) || bytes)`, the identity the sync
    /// protocol and the change graph compare.
    hash: ChangeHash,
    /// Commit time in seconds since the epoch. Upstream calls it
    /// `timestamp`; it is a wall clock, not a logical clock, and the document
    /// never depends on it.
    time: i64,
    /// The commit message. An absent message and an empty one are the same
    /// thing here: upstream decodes an empty message to `None`, not to
    /// `Some("")` (`storage/change.rs:144-147`), and an empty byte string
    /// re-encodes to the same zero length.
    message: []const u8,
    /// The actor's sequence number: 1 for an actor's first change. Per-actor
    /// changes are strictly sequential, which is what `SeqClock` compares
    /// (`change_graph.rs:571-573`).
    seq: u64,
    /// The counter of this change's first op, never zero
    /// (`parse/leb128.rs:87-96`).
    start_op: u64,
    /// The counter of this change's last op, which is `start_op - 1` for a
    /// change with no ops. `parseChange` cannot know it, so this is 0 until
    /// `withOpCount` is called. Do not read it on a freshly parsed change.
    max_op: u64,
    /// The actors this change references but does not own, in the lexicographic
    /// order the writer emits them in (`change_actors.rs:10-14`). They are
    /// interned into the document's actor table in that order.
    other_actors: []const ActorId,

    /// The op columns and the author footer: `bytes` from the end of the
    /// header on. The columnar layer owns the decoding; this is its input.
    pub fn opsBytes(self: Change) []const u8 {
        return self.bytes[self.header_len..];
    }

    /// True when `other` is one of this change's dependencies.
    pub fn hasDependency(self: Change, other: ChangeHash) bool {
        for (self.deps) |dep| {
            if (dep.eql(other)) return true;
        }
        return false;
    }

    /// The same change with `max_op` filled in from the op count the columns
    /// yielded: the last op id it owns is `start_op + num_ops - 1`
    /// (`change.rs:74-76`). A change with no ops therefore has
    /// `max_op = start_op - 1`, which is a value the format permits — an
    /// empty transaction still commits a change.
    ///
    /// Rejects a `start_op` past `u32::MAX`. Op counters are `u32` in this
    /// port, and upstream refuses the same change when it walks the ops
    /// (`ReadChangeOpError::CounterTooLarge`, `storage/change.rs:182-184`).
    /// Here the check waits for the op count, because the columns that would
    /// supply it are not decoded in this module.
    ///
    /// **The result aliases the receiver's `other_actors`; it is not a
    /// transfer.** The body copies the struct and fills in one field, so both
    /// values name one actor array and `deinit` frees it. Exactly one of the
    /// two may be deinited: deinit both and the array is freed twice, deinit
    /// neither and it leaks. A caller that reads the result owes nothing and
    /// must not free it — which is the shape the in-tree callers use, since
    /// they go straight to [`ChangeMetadata.fromChange`](ChangeMetadata.fromChange),
    /// which borrows rather than copies.
    pub fn withOpCount(self: Change, num_ops: u64) ParseError!Change {
        if (self.start_op == 0 or self.start_op > std.math.maxInt(u32))
            return error.Overflow;
        var next = self;
        next.max_op = if (num_ops == 0) self.start_op - 1 else std.math.add(u64, self.start_op, num_ops - 1) catch return error.Overflow;
        if (next.max_op > std.math.maxInt(u32)) return error.Overflow;
        return next;
    }

    /// Writes the change header, in the order and widths the format fixes, to
    /// the end of `out`. **`out` is the caller's buffer and is appended to,
    /// not replaced**: whatever it already holds is kept, and the nine appends
    /// below land after it, so a caller writes its framing first. It is not
    /// truncated, cleared or reserved.
    ///
    /// **A refused append leaves `out` holding the prefix that did fit.** The
    /// header is written field by field and each field can need a grow, so
    /// `error.OutOfMemory` can arrive with a dependency count and half a
    /// dependency list already appended. That is not a usable buffer and not
    /// a silent truncation: `out`'s length is exactly what was written, and
    /// the caller — which owns `out` and knows what else was in it — has to
    /// drop it. There is no rollback here because there is nothing to roll
    /// back to: a partial header is not shorter than the prefix, it is a
    /// different string.
    ///
    /// This is the inverse of the header half of `parseChange`: a change
    /// parsed from a body and written back with it produces the original
    /// bytes. Dependencies keep the order the caller gave them, so a parsed
    /// change round trips; upstream sorts them in the *builder*
    /// (`storage/change.rs:343-344`), which is where a new change's order is
    /// decided, not here.
    pub fn encodeHeader(self: Change, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        try leb128.appendUnsigned(out, gpa, self.deps.len);
        for (self.deps) |dep| try out.appendSlice(gpa, &dep.bytes);
        try appendLengthPrefixed(out, gpa, self.actor.bytes);
        try leb128.appendUnsigned(out, gpa, self.seq);
        try leb128.appendUnsigned(out, gpa, self.start_op);
        try leb128.appendSigned(out, gpa, self.time);
        try appendLengthPrefixed(out, gpa, self.message);
        try leb128.appendUnsigned(out, gpa, self.other_actors.len);
        for (self.other_actors) |actor| try appendLengthPrefixed(out, gpa, actor.bytes);
    }

    /// The whole change chunk, framed and ready to concatenate into a
    /// document. The body is `bytes` as it stands: it is already the exact
    /// body the hash was taken over, so nothing is re-serialised here.
    ///
    /// **The returned slice is a fresh allocation the caller owns and must
    /// free with `gpa`.** It borrows nothing: the chunk framing is copied out
    /// and the body is copied in, so the result outlives `bytes` and survives
    /// a [`deinit`](Change.deinit) of the change it came from. An
    /// `error.OutOfMemory` returns no slice and nothing is leaked.
    pub fn encode(self: Change, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try chunk.writeChunk(&out, gpa, .change, self.bytes);
        return out.toOwnedSlice(gpa);
    }

    /// Display allocation and checked hexadecimal output-size failures.
    pub const DisplayError = Allocator.Error || error{Overflow};

    /// A short form for an error message: the hash prefix, the author, the
    /// sequence number, the op range, and the message.
    ///
    /// **The returned slice is a fresh allocation the caller owns and must
    /// free with `gpa`,** the same rule as [`encode`](Change.encode): the text
    /// is formatted into a new buffer and borrows nothing from the change.
    /// The intermediate actor hex the format needs is freed here, so the one
    /// allocation that reaches the caller is the string itself.
    pub fn debugString(self: Change, gpa: Allocator) DisplayError![]u8 {
        // Eight hex digits is enough to find the change in a hash set and
        // short enough to keep an error readable.
        var hash_prefix: [16]u8 = undefined;
        err.hexInto(self.hash.bytes[0..8], &hash_prefix);
        const actor_hex = try types.ActorId.toHex(gpa, self.actor);
        defer gpa.free(actor_hex);
        return std.fmt.allocPrint(gpa, "change {s} by {s} seq {d} ops {d}-{d} at {d}: {s}", .{
            hash_prefix[0..8], actor_hex, self.seq, self.start_op, self.max_op, self.time, self.message,
        });
    }

    /// The individual footer's author bytes, borrowed from `bytes`. Malformed,
    /// unknown and absent footers return null, as Rust's accessor does.
    /// Column parsing errors and allocation failure remain typed errors.
    pub fn author(self: Change, gpa: Allocator) ParseError!?[]const u8 {
        return doccodec.decodeAuthorFooter(try self.extraBytes(gpa)) catch null;
    }

    /// The complete opaque footer, borrowed from the original body.
    pub fn extraBytes(self: Change, gpa: Allocator) ParseError![]const u8 {
        var parsed = try changechunk.parseChangeChunkWithHash(self.bytes, gpa, self.hash);
        defer parsed.deinit(gpa);
        return parsed.footer;
    }

    /// Number of operation rows, not columns. No decoded operations are cached.
    pub fn len(self: Change, gpa: Allocator) ParseError!usize {
        var parsed = try changechunk.parseChangeChunkWithHash(self.bytes, gpa, self.hash);
        defer parsed.deinit(gpa);
        return parsed.opCount();
    }

    /// Whether the change contains no operations.
    pub fn isEmpty(self: Change, gpa: Allocator) ParseError!bool {
        return (try self.len(gpa)) == 0;
    }

    /// An independent uncompressed, framed byte buffer. Release with `gpa.free`.
    pub fn rawBytes(self: Change, gpa: Allocator) Allocator.Error![]u8 {
        return self.encode(gpa);
    }

    /// An independent framed buffer, compressed above Rust's 256-byte cutoff.
    /// Release with `gpa.free`; no cache mutates this borrowed header view.
    pub fn compressedBytes(self: Change, gpa: Allocator) Allocator.Error![]u8 {
        const raw_len = 9 + leb128.unsignedSize(self.bytes.len) + self.bytes.len;
        // storage/change.rs:17,295-301 tests the complete uncompressed chunk size.
        if (raw_len <= 256) return self.encode(gpa);
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(gpa);
        try chunk.compressChunk(&compressed, gpa, self.bytes);
        return compressed.toOwnedSlice(gpa);
    }

    /// Independent actor bytes, author first, then referenced actors in wire order.
    /// Release each `actor.bytes` and then the array with `gpa.free`.
    pub fn actorsOwned(self: Change, gpa: Allocator) Allocator.Error![]ActorId {
        const actors = try gpa.alloc(ActorId, self.other_actors.len + 1);
        errdefer gpa.free(actors);
        var filled: usize = 0;
        errdefer for (actors[0..filled]) |actor_id| gpa.free(actor_id.bytes);
        actors[0] = .{ .bytes = try gpa.dupe(u8, self.actor.bytes) };
        filled = 1;
        for (self.other_actors, 1..) |actor_id, i| {
            actors[i] = .{ .bytes = try gpa.dupe(u8, actor_id.bytes) };
            filled += 1;
        }
        return actors;
    }

    /// Parses exactly one framed raw/compressed change into an independent owner.
    /// The returned `Built` must be released once with `deinit(gpa)`.
    pub fn fromBytes(gpa: Allocator, bytes: []const u8) ParseError!doccodec.Built {
        const framed = try chunk.parseChunk(bytes);
        const owned: chunk.Inflated = switch (framed.typ) {
            .change => blk: {
                const hash = framed.hash orelse return error.InvalidChecksum;
                break :blk .{ .body = try gpa.dupe(u8, framed.data), .hash = hash };
            },
            .compressed => try chunk.decompressChunkWithHash(gpa, framed),
            else => return error.InvalidChunkType,
        };
        errdefer gpa.free(owned.body);
        var parsed = try parseChangeWithHash(owned.body, gpa, owned.hash);
        errdefer parsed.deinit(gpa);
        const decoded = try decodeOps(gpa, parsed);
        defer {
            for (decoded) |*op| op.deinit(gpa);
            gpa.free(decoded);
        }
        parsed = try parsed.withOpCount(decoded.len);
        return .{ .body = owned.body, .change = parsed };
    }

    /// Decodes using the document's existing column codec. The result owns every
    /// payload and actor byte and survives this view and its source bytes.
    pub fn decode(self: Change, gpa: Allocator) ParseError!ExpandedChange {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const actors = try alloc.alloc(ActorId, self.other_actors.len + 1);
        actors[0] = .{ .bytes = try alloc.dupe(u8, self.actor.bytes) };
        for (self.other_actors, 1..) |actor_id, i|
            actors[i] = .{ .bytes = try alloc.dupe(u8, actor_id.bytes) };
        const decoded = try decodeOps(gpa, self);
        defer {
            for (decoded) |*op| op.deinit(gpa);
            gpa.free(decoded);
        }
        _ = try self.withOpCount(decoded.len);
        const ops = try alloc.alloc(ExpandedOp, decoded.len);
        for (decoded, ops) |*op, *expanded| {
            const preds = try alloc.alloc(ExpandedOpId, op.pred().len);
            for (op.pred(), preds) |pred, *target|
                target.* = try expandId(pred, actors);
            expanded.* = .{
                .action = try cloneAction(alloc, try value.opTypeFromActionAndValue(
                    op.action(),
                    op.value(),
                    op.markName(),
                    op.expand(),
                )),
                .obj = if (op.obj()) |id| .{ .id = try expandId(id, actors) } else .root,
                .key = switch (op.key()) {
                    .map => |key| .{ .map = try alloc.dupe(u8, key) },
                    .seq => |element| .{ .seq = if (element.id.counter == 0)
                        .head
                    else
                        .{ .id = try expandId(element.id, actors) } },
                },
                .pred = preds,
                .insert = op.insert(),
            };
        }
        const footer = try self.extraBytes(gpa);
        const extra = try alloc.dupe(u8, footer);
        const message = if (self.message.len == 0) null else try alloc.dupe(u8, self.message);
        const deps = try alloc.dupe(ChangeHash, self.deps);
        const owner = try gpa.create(std.heap.ArenaAllocator);
        owner.* = arena;
        return .{
            .ops = ops,
            .actor = actors[0],
            .hash = self.hash,
            .seq = self.seq,
            .start_op = self.start_op,
            .time = self.time,
            .message = message,
            .deps = deps,
            .extra_bytes = extra,
            .author = doccodec.decodeAuthorFooter(extra) catch null,
            .storage = owner,
        };
    }

    /// Frees the actor array `parseChange` allocated. Everything else in the
    /// change borrows `bytes` and is left alone.
    ///
    /// Only call this on a `Change` that came from `parseChange`; a hand-built
    /// one has no allocation behind `other_actors`.
    pub fn deinit(self: *Change, gpa: Allocator) void {
        gpa.free(self.other_actors);
        self.other_actors = &.{};
    }
};

/// An actor-byte operation identity, independent of any document actor table.
/// Byte slices borrow the containing ExpandedChange or standalone owned operation.
pub const ExpandedOpId = struct {
    counter: u64,
    actor: ActorId,

    /// Serializes a stable counter@actor identity, independent of actor indices.
    pub fn jsonStringify(self: ExpandedOpId, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.print("\"{d}@", .{self.counter});
        for (self.actor.bytes) |byte| try jws.writer.print("{x:0>2}", .{byte});
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }
};

/// A structured legacy operation. `dup` creates a standalone independent owner;
/// decoded operations are owned together by ExpandedChange. Literal inputs borrow
/// their payloads. Shallow copies never create an additional disposal obligation.
pub const ExpandedOp = struct {
    action: value.OpType,
    obj: ObjectId,
    key: Key,
    pred: []const ExpandedOpId,
    insert: bool = false,
    /// Null for literals and operations owned by a parent change.
    storage: ?*std.heap.ArenaAllocator = null,

    pub const ObjectId = union(enum) { root, id: ExpandedOpId };
    pub const ElementId = union(enum) { head, id: ExpandedOpId };
    pub const Key = union(enum) { map: []const u8, seq: ElementId };

    /// Deep independent copy. Release once with `deinit` using the same allocator.
    pub fn dup(self: ExpandedOp, gpa: Allocator) Allocator.Error!ExpandedOp {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var result = try cloneExpandedOp(arena.allocator(), self);
        const storage = try gpa.create(std.heap.ArenaAllocator);
        storage.* = arena;
        result.storage = storage;
        return result;
    }

    /// Releases only this standalone owner; parent-owned/literal views own nothing.
    pub fn deinit(self: *ExpandedOp, gpa: Allocator) void {
        if (self.storage) |storage| {
            storage.deinit();
            gpa.destroy(storage);
        }
        self.* = undefined;
    }

    /// Rust legacy Operation JSON fields, including datatype and elemId.
    pub fn jsonStringify(self: ExpandedOp, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("action");
        try jws.write(actionName(self.action));
        try jws.objectField("obj");
        switch (self.obj) {
            .root => try jws.write("_root"),
            .id => |id| try id.jsonStringify(jws),
        }
        switch (self.key) {
            .map => |key| {
                try jws.objectField("key");
                try jws.write(key);
            },
            .seq => |element| {
                try jws.objectField("elemId");
                switch (element) {
                    .head => try jws.write("_head"),
                    .id => |id| try id.jsonStringify(jws),
                }
            },
        }
        if (self.insert) {
            try jws.objectField("insert");
            try jws.write(true);
        }
        switch (self.action) {
            .put => |scalar| {
                const datatype: ?[]const u8 = switch (scalar) {
                    .int => "int",
                    .uint => "uint",
                    .float => "float64",
                    .counter => "counter",
                    .timestamp => "timestamp",
                    else => null,
                };
                if (datatype) |name| {
                    try jws.objectField("datatype");
                    try jws.write(name);
                }
                try jws.objectField("value");
                try jws.write(scalar);
            },
            .increment => |amount| {
                try jws.objectField("value");
                try jws.write(amount);
            },
            .mark_begin => |mark| {
                try jws.objectField("name");
                try jws.write(mark.name);
                try jws.objectField("value");
                try jws.write(mark.value);
                try jws.objectField("expand");
                try jws.write(mark.expand);
            },
            .mark_end => |mark| {
                try jws.objectField("expand");
                try jws.write(mark.expand);
            },
            else => {},
        }
        try jws.objectField("pred");
        try jws.beginArray();
        for (self.pred) |id| try id.jsonStringify(jws);
        try jws.endArray();
        try jws.endObject();
    }

    /// JSON parser allocations belong to the std.json Parsed owner, not this view.
    pub fn jsonParse(gpa: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!ExpandedOp {
        var raw_options = options;
        raw_options.parse_numbers = false;
        return jsonParseFromValue(
            gpa,
            try std.json.innerParse(std.json.Value, gpa, source, raw_options),
            options,
        );
    }

    /// Parses the exact legacy field names and validates action/datatype combinations.
    pub fn jsonParseFromValue(gpa: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!ExpandedOp {
        if (source != .object) return error.UnexpectedToken;
        var fields = source.object.iterator();
        while (fields.next()) |field| {
            const name = field.key_ptr.*;
            const known = [_][]const u8{
                "action",   "obj",   "key",  "elemId", "pred", "insert",
                "datatype", "value", "name", "expand", "ref",
            };
            var found = false;
            for (known) |candidate| {
                if (std.mem.eql(u8, name, candidate)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownField;
        }
        const action = try jsonString(try jsonRequired(source, "action"));
        const object = try jsonString(try jsonRequired(source, "obj"));
        const obj: ObjectId = if (std.mem.eql(u8, object, "_root")) .root else .{ .id = try parseExpandedId(gpa, object) };
        if (source.object.get("ref")) |reference|
            _ = try parseExpandedId(gpa, try jsonString(reference));
        const map_key = source.object.get("key");
        const seq_key = source.object.get("elemId");
        if (map_key != null and seq_key != null) return error.DuplicateField;
        const key: Key = if (map_key) |map| .{ .map = try gpa.dupe(u8, try jsonString(map)) } else if (seq_key) |seq| blk: {
            const text = try jsonString(seq);
            break :blk .{ .seq = if (std.mem.eql(u8, text, "_head"))
                .head
            else
                .{ .id = try parseExpandedId(gpa, text) } };
        } else return error.MissingField;
        const predecessor_values = try jsonRequired(source, "pred");
        if (predecessor_values != .array) return error.UnexpectedToken;
        const preds = try gpa.alloc(ExpandedOpId, predecessor_values.array.items.len);
        for (predecessor_values.array.items, preds) |item, *id|
            id.* = try parseExpandedId(gpa, try jsonString(item));
        // Rust SortedVec deserialization sorts by counter, then actor bytes.
        std.mem.sort(ExpandedOpId, preds, {}, expandedIdLessThan);
        const insert = if (source.object.get("insert")) |flag|
            try jsonBool(flag)
        else
            false;
        const expand = if (source.object.get("expand")) |flag|
            try jsonBool(flag)
        else
            false;
        const resolved: value.OpType = if (std.mem.eql(u8, action, "makeMap"))
            .{ .make = .map }
        else if (std.mem.eql(u8, action, "makeTable")) .{ .make = .table } else if (std.mem.eql(u8, action, "makeList")) .{ .make = .list } else if (std.mem.eql(u8, action, "makeText")) .{ .make = .text } else if (std.mem.eql(u8, action, "del")) .delete else if (std.mem.eql(u8, action, "set"))
            .{ .put = try jsonOpScalar(gpa, source, options) }
        else if (std.mem.eql(u8, action, "inc")) blk: {
            const scalar = try value.ScalarValue.jsonParseFromValue(
                gpa,
                try jsonRequired(source, "value"),
                options,
            );
            break :blk .{ .increment = scalar.asI64() orelse
                return error.UnexpectedToken };
        } else if (std.mem.eql(u8, action, "markBegin")) .{ .mark_begin = .{
            .name = try gpa.dupe(u8, try jsonString(try jsonRequired(source, "name"))),
            .value = try jsonOpScalar(gpa, source, options),
            .expand = expand,
        } } else if (std.mem.eql(u8, action, "markEnd"))
            .{ .mark_end = .{ .expand = expand } }
        else
            return error.InvalidEnumTag;
        return .{ .action = resolved, .obj = obj, .key = key, .pred = preds, .insert = insert };
    }
};

/// Owned structured legacy change, with no document or persistent decoded op set.
/// `decode`/`dup` own their arena and are released once with `deinit(gpa)`.
/// Literals borrow inputs. std.json parsing instead borrows its Parsed arena:
/// release the Parsed wrapper, not its value. Assignment is not a deep copy.
pub const ExpandedChange = struct {
    ops: []const ExpandedOp,
    actor: ActorId,
    /// Informational computed hash. Encoding always recomputes identity.
    hash: ?ChangeHash = null,
    seq: u64,
    start_op: u64,
    time: i64,
    /// Null and empty messages encode identically.
    message: ?[]const u8,
    deps: []const ChangeHash,
    /// Authoritative complete footer, including unknown/trailing bytes.
    extra_bytes: []const u8 = &.{},
    /// Informational parsed author; ignored when encoding, exactly as Rust.
    author: ?[]const u8 = null,
    /// Null for borrowed literals and std.json Parsed arena views.
    storage: ?*std.heap.ArenaAllocator = null,

    /// Releases this independent decode/dup owner and invalidates every payload.
    pub fn deinit(self: *ExpandedChange, gpa: Allocator) void {
        if (self.storage) |storage| {
            storage.deinit();
            gpa.destroy(storage);
        }
        self.* = undefined;
    }

    /// Deep independent copy, including operation IDs, scalar and footer bytes.
    pub fn dup(self: ExpandedChange, gpa: Allocator) Allocator.Error!ExpandedChange {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var result = self;
        const ops = try alloc.alloc(ExpandedOp, self.ops.len);
        for (self.ops, ops) |op, *target| target.* = try cloneExpandedOp(alloc, op);
        result.ops = ops;
        result.actor = .{ .bytes = try alloc.dupe(u8, self.actor.bytes) };
        result.message = if (self.message) |message| try alloc.dupe(u8, message) else null;
        result.deps = try alloc.dupe(ChangeHash, self.deps);
        result.extra_bytes = try alloc.dupe(u8, self.extra_bytes);
        result.author = if (self.author) |author_bytes|
            try alloc.dupe(u8, author_bytes)
        else
            null;
        const storage = try gpa.create(std.heap.ArenaAllocator);
        storage.* = arena;
        result.storage = storage;
        return result;
    }

    /// Encodes through the same column codec used by Document commits. Inputs
    /// remain borrowed; the returned body/header pair owns its storage.
    /// Footer bytes are authoritative; hash and author never alter encoding.
    pub fn encode(self: ExpandedChange, gpa: Allocator) doccodec.DocumentError!doccodec.Built {
        if (self.start_op == 0 or self.start_op > std.math.maxInt(u32))
            return error.Overflow;
        const max_op = if (self.ops.len == 0) self.start_op - 1 else std.math.add(u64, self.start_op, self.ops.len - 1) catch return error.Overflow;
        if (max_op > std.math.maxInt(u32)) return error.Overflow;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        var actors: std.ArrayList(ActorId) = .empty;
        try actors.append(scratch, self.actor);
        for (self.ops) |op| {
            switch (op.obj) {
                .root => {},
                .id => |id| try addActor(scratch, &actors, id.actor),
            }
            switch (op.key) {
                .map => {},
                .seq => |element| switch (element) {
                    .head => {},
                    .id => |id| try addActor(scratch, &actors, id.actor),
                },
            }
            for (op.pred) |id| try addActor(scratch, &actors, id.actor);
        }
        std.mem.sort(ActorId, actors.items, {}, actorLessThan);
        const author_index = try actorIndex(actors.items, self.actor);
        const ops = try scratch.alloc(opmod.ChangeOp, self.ops.len);
        for (self.ops, ops, 0..) |op, *target, i| {
            const decomposed = opmod.decompose(op.action);
            const preds = try scratch.alloc(types.OpId, op.pred.len);
            for (op.pred, preds, 0..) |id, *pred, j| {
                if (j > 0 and expandedIdLessThan({}, id, op.pred[j - 1]))
                    return error.InvalidValue;
                pred.* = try compactId(id, actors.items);
            }
            target.* = try opmod.ChangeOp.init(
                scratch,
                types.OpId.init(@intCast(self.start_op + i), author_index),
                switch (op.obj) {
                    .root => .root,
                    .id => |id| .{ .id = try compactId(id, actors.items) },
                },
                decomposed.action,
                switch (op.key) {
                    .map => |key| .{ .map = key },
                    .seq => |element| .{ .seq = switch (element) {
                        .head => types.ElemId.head(),
                        .id => |id| types.ElemId.fromOpId(try compactId(id, actors.items)),
                    } },
                },
                decomposed.value,
                op.insert,
                decomposed.expand,
                decomposed.mark_name,
                preds,
            );
        }
        const deps = try scratch.dupe(ChangeHash, self.deps);
        std.mem.sort(ChangeHash, deps, {}, hashLessThan);
        return doccodec.encodeOneChange(gpa, actors.items, .{
            .actor = author_index,
            .seq = self.seq,
            .start_op = self.start_op,
            .max_op = max_op,
            .time = self.time,
            .message = self.message orelse "",
            .deps = deps,
            .footer = self.extra_bytes,
        }, ops);
    }

    /// Rust legacy Change JSON, not a serialization of implementation storage.
    pub fn jsonStringify(self: ExpandedChange, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("ops");
        try jws.write(self.ops);
        try jws.objectField("actor");
        try jws.write(self.actor);
        if (self.hash) |hash| {
            try jws.objectField("hash");
            try jws.write(hash);
        }
        try jws.objectField("seq");
        try jws.write(self.seq);
        try jws.objectField("startOp");
        try jws.write(self.start_op);
        try jws.objectField("time");
        try jws.write(self.time);
        try jws.objectField("message");
        try jws.write(self.message);
        try jws.objectField("deps");
        try jws.write(self.deps);
        if (self.extra_bytes.len != 0) {
            try jws.objectField("extra_bytes");
            try jws.beginArray();
            for (self.extra_bytes) |byte| try jws.write(byte);
            try jws.endArray();
        }
        if (self.author) |author_bytes| {
            try jws.objectField("author");
            try jws.beginWriteRaw();
            try jws.writer.writeByte('"');
            for (author_bytes) |byte| try jws.writer.print("{x:0>2}", .{byte});
            try jws.writer.writeByte('"');
            jws.endWriteRaw();
        }
        try jws.endObject();
    }

    /// Token parser using the standard Parsed arena ownership convention.
    pub fn jsonParse(gpa: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!ExpandedChange {
        var raw_options = options;
        raw_options.parse_numbers = false;
        return jsonParseFromValue(
            gpa,
            try std.json.innerParse(std.json.Value, gpa, source, raw_options),
            options,
        );
    }

    /// Parses legacy field names. Unknown change fields are ignored as Rust does.
    pub fn jsonParseFromValue(gpa: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!ExpandedChange {
        if (source != .object) return error.UnexpectedToken;
        const start_op = try std.json.innerParseFromValue(
            u64,
            gpa,
            try jsonRequired(source, "startOp"),
            options,
        );
        if (start_op == 0) return error.InvalidNumber;
        const actor_bytes = err.hexFrom(gpa, try jsonString(
            try jsonRequired(source, "actor"),
        )) catch |e| return jsonCodecError(e);
        const operation_values = try jsonRequired(source, "ops");
        if (operation_values != .array) return error.UnexpectedToken;
        const ops = try gpa.alloc(ExpandedOp, operation_values.array.items.len);
        for (operation_values.array.items, ops) |item, *op|
            op.* = try ExpandedOp.jsonParseFromValue(gpa, item, options);
        const deps = try std.json.innerParseFromValue(
            []const ChangeHash,
            gpa,
            try jsonRequired(source, "deps"),
            options,
        );
        const message_value = source.object.get("message") orelse .null;
        const message = if (message_value == .null) null else try gpa.dupe(u8, try jsonString(message_value));
        return .{
            .ops = ops,
            .actor = .{ .bytes = actor_bytes },
            .start_op = start_op,
            .seq = try std.json.innerParseFromValue(
                u64,
                gpa,
                try jsonRequired(source, "seq"),
                options,
            ),
            .time = try std.json.innerParseFromValue(
                i64,
                gpa,
                try jsonRequired(source, "time"),
                options,
            ),
            .message = message,
            .deps = deps,
            .hash = if (source.object.get("hash")) |hash|
                try std.json.innerParseFromValue(?ChangeHash, gpa, hash, options)
            else
                null,
            .extra_bytes = if (source.object.get("extra_bytes")) |extra|
                try jsonByteArray(gpa, extra, options)
            else
                &.{},
            .author = if (source.object.get("author")) |author_bytes|
                if (author_bytes == .null) null else err.hexFrom(gpa, try jsonString(author_bytes)) catch |e|
                    return jsonCodecError(e)
            else
                null,
        };
    }
};

fn decodeOps(gpa: Allocator, change: Change) ParseError![]opmod.ChangeOp {
    const indices = try gpa.alloc(types.ActorIdx, change.other_actors.len + 1);
    defer gpa.free(indices);
    for (indices, 0..) |*index, i|
        index.* = std.math.cast(types.ActorIdx, i) orelse return error.Overflow;
    return doccodec.decodeChangeOps(gpa, change, indices);
}

fn jsonByteArray(gpa: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError![]const u8 {
    if (source != .array) return error.UnexpectedToken;
    for (source.array.items) |item| {
        if (item != .integer and item != .number_string) return error.UnexpectedToken;
    }
    return std.json.innerParseFromValue([]const u8, gpa, source, options);
}

fn jsonCodecError(e: anyerror) std.json.ParseFromValueError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.UnexpectedToken;
}

fn jsonRequired(source: std.json.Value, name: []const u8) std.json.ParseFromValueError!std.json.Value {
    return source.object.get(name) orelse error.MissingField;
}

fn jsonString(source: std.json.Value) std.json.ParseFromValueError![]const u8 {
    return if (source == .string) source.string else error.UnexpectedToken;
}

fn jsonBool(source: std.json.Value) std.json.ParseFromValueError!bool {
    return if (source == .bool) source.bool else error.UnexpectedToken;
}

fn parseExpandedId(gpa: Allocator, text: []const u8) std.json.ParseFromValueError!ExpandedOpId {
    const separator = std.mem.indexOfScalar(u8, text, '@') orelse
        return error.UnexpectedToken;
    const counter = std.fmt.parseInt(u64, text[0..separator], 10) catch
        return error.UnexpectedToken;
    const actor = err.hexFrom(gpa, text[separator + 1 ..]) catch |e|
        return jsonCodecError(e);
    return .{ .counter = counter, .actor = .{ .bytes = actor } };
}

fn jsonOpScalar(gpa: Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!value.ScalarValue {
    const scalar = try value.ScalarValue.jsonParseFromValue(
        gpa,
        try jsonRequired(source, "value"),
        options,
    );
    const datatype = source.object.get("datatype") orelse return scalar;
    const want = std.meta.stringToEnum(value.ScalarValue.DataType, try jsonString(datatype)) orelse return error.InvalidEnumTag;
    return scalar.asDatatype(want) catch |e|
        return jsonCodecError(e);
}

fn actionName(action: value.OpType) []const u8 {
    return switch (action) {
        .make => |kind| switch (kind) {
            .map => "makeMap",
            .table => "makeTable",
            .list => "makeList",
            .text => "makeText",
        },
        .delete => "del",
        .increment => "inc",
        .put => "set",
        .mark_begin => "markBegin",
        .mark_end => "markEnd",
    };
}

fn expandedIdLessThan(_: void, a: ExpandedOpId, b: ExpandedOpId) bool {
    if (a.counter != b.counter) return a.counter < b.counter;
    return std.mem.order(u8, a.actor.bytes, b.actor.bytes) == .lt;
}

fn actorLessThan(_: void, a: ActorId, b: ActorId) bool {
    return std.mem.order(u8, a.bytes, b.bytes) == .lt;
}

fn hashLessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
}

fn addActor(gpa: Allocator, actors: *std.ArrayList(ActorId), actor: ActorId) Allocator.Error!void {
    for (actors.items) |item| if (item.eql(actor)) return;
    try actors.append(gpa, actor);
}

fn actorIndex(actors: []const ActorId, actor: ActorId) ParseError!types.ActorIdx {
    for (actors, 0..) |item, i| if (item.eql(actor))
        return std.math.cast(types.ActorIdx, i) orelse error.Overflow;
    return error.MissingActor;
}

fn compactId(id: ExpandedOpId, actors: []const ActorId) ParseError!types.OpId {
    const counter = std.math.cast(u32, id.counter) orelse return error.Overflow;
    return types.OpId.init(counter, try actorIndex(actors, id.actor));
}

fn expandId(id: types.OpId, actors: []const ActorId) ParseError!ExpandedOpId {
    if (id.actor >= actors.len) return error.MissingActor;
    return .{ .counter = id.counter, .actor = actors[id.actor] };
}

fn cloneExpandedId(gpa: Allocator, id: ExpandedOpId) Allocator.Error!ExpandedOpId {
    return .{ .counter = id.counter, .actor = .{ .bytes = try gpa.dupe(u8, id.actor.bytes) } };
}

fn cloneScalar(gpa: Allocator, scalar: value.ScalarValue) Allocator.Error!value.ScalarValue {
    return scalar.dup(gpa);
}

fn cloneAction(gpa: Allocator, action: value.OpType) Allocator.Error!value.OpType {
    return switch (action) {
        .put => |scalar| .{ .put = try cloneScalar(gpa, scalar) },
        .mark_begin => |mark| .{ .mark_begin = .{
            .expand = mark.expand,
            .name = try gpa.dupe(u8, mark.name),
            .value = try cloneScalar(gpa, mark.value),
        } },
        else => action,
    };
}

fn cloneExpandedOp(gpa: Allocator, op: ExpandedOp) Allocator.Error!ExpandedOp {
    const preds = try gpa.alloc(ExpandedOpId, op.pred.len);
    for (op.pred, preds) |pred, *target| target.* = try cloneExpandedId(gpa, pred);
    return .{
        .action = try cloneAction(gpa, op.action),
        .obj = switch (op.obj) {
            .root => .root,
            .id => |id| .{ .id = try cloneExpandedId(gpa, id) },
        },
        .key = switch (op.key) {
            .map => |key| .{ .map = try gpa.dupe(u8, key) },
            .seq => |element| .{ .seq = switch (element) {
                .head => .head,
                .id => |id| .{ .id = try cloneExpandedId(gpa, id) },
            } },
        },
        .pred = preds,
        .insert = op.insert,
    };
}

/// The change graph's view of a change: the same fields, without the bytes.
///
/// The graph keeps one of these per node for the life of the document, where
/// the encoded change is usually gone, so a metadata value outlives the chunk
/// it came from only if it was copied — see `intoOwned`. Upstream stores
/// `actor, author, seq, start_op, max_op, timestamp, message, deps, hash, extra`
/// (`op_set2/types.rs:748-760`). This low-level record's author is from the
/// individual footer, not the document's inherited actor-author association.
pub const ChangeMetadata = struct {
    /// The actor that authored the change.
    actor: ActorId,
    /// The changes that must be applied before this one, sorted.
    deps: []const ChangeHash,
    /// The change's identity.
    hash: ChangeHash,
    /// Commit time in seconds since the epoch.
    time: i64,
    /// The commit message, empty when there was none.
    message: []const u8,
    /// The actor's sequence number, 1 for its first change.
    seq: u64,
    /// The counter of the change's first op.
    start_op: u64,
    /// The counter of the change's last op.
    max_op: u64,
    /// The actors this change references but does not own.
    other_actors: []const ActorId,
    /// Individual arbitrary-byte author, null for absent/unknown/malformed footer.
    author: ?[]const u8 = null,
    /// Complete opaque individual footer, including unknown/trailing bytes.
    extra: []const u8 = &.{},

    /// The metadata for a change, borrowing everything from it: the actor
    /// bytes, the dependency hashes, the message and the referenced actor
    /// bytes are the change's own, and the result shares their lifetime. It
    /// is valid while `change.bytes` is and no longer, and it owns nothing —
    /// **so [`deinit`](ChangeMetadata.deinit) must not be called on it.** A
    /// function that takes `ChangeMetadata` by value therefore does not take
    /// ownership of it unless it says so, and the ones that do not say so
    /// copy it instead.
    /// Footer-location parsing uses temporary allocations only; errors return no owner.
    pub fn fromChange(gpa: Allocator, change: Change) ParseError!ChangeMetadata {
        const footer = try change.extraBytes(gpa);
        return .{
            .actor = change.actor,
            .deps = change.deps,
            .hash = change.hash,
            .time = change.time,
            .message = change.message,
            .seq = change.seq,
            .start_op = change.start_op,
            .max_op = change.max_op,
            .other_actors = change.other_actors,
            .author = doccodec.decodeAuthorFooter(footer) catch null,
            .extra = footer,
        };
    }

    /// A deep copy that owns its bytes, for a graph node that outlives the
    /// change it was read from. Upstream's `into_owned`
    /// (`op_set2/types.rs:762-777`) is the same move, for the same reason.
    ///
    /// **The result is owned by the caller** and must be released with
    /// [`deinit`](ChangeMetadata.deinit). Actor, dependency, message, other-actor,
    /// author and opaque footer storage are independent of the source record.
    /// Passing this value does not transfer ownership unless a callee says so.
    pub fn intoOwned(self: ChangeMetadata, gpa: Allocator) Allocator.Error!ChangeMetadata {
        const actor = try gpa.dupe(u8, self.actor.bytes);
        errdefer gpa.free(actor);
        const deps = try gpa.dupe(ChangeHash, self.deps);
        errdefer gpa.free(deps);
        const message = try gpa.dupe(u8, self.message);
        errdefer gpa.free(message);
        const author_bytes = if (self.author) |bytes| try gpa.dupe(u8, bytes) else null;
        errdefer if (author_bytes) |bytes| gpa.free(bytes);
        const extra = try gpa.dupe(u8, self.extra);
        errdefer gpa.free(extra);

        const others = try gpa.alloc(ActorId, self.other_actors.len);
        var filled: usize = 0;
        errdefer {
            for (others[0..filled]) |a| gpa.free(a.bytes);
            gpa.free(others);
        }
        for (self.other_actors) |src| {
            others[filled] = .{ .bytes = try gpa.dupe(u8, src.bytes) };
            filled += 1;
        }

        return .{
            .actor = .{ .bytes = actor },
            .deps = deps,
            .hash = self.hash,
            .time = self.time,
            .message = message,
            .seq = self.seq,
            .start_op = self.start_op,
            .max_op = self.max_op,
            .other_actors = others,
            .author = author_bytes,
            .extra = extra,
        };
    }

    /// Frees everything `intoOwned` allocated, and nothing a borrowed value
    /// points at. Only valid on metadata that came from `intoOwned`.
    pub fn deinit(self: *ChangeMetadata, gpa: Allocator) void {
        gpa.free(self.actor.bytes);
        gpa.free(self.deps);
        gpa.free(self.message);
        for (self.other_actors) |a| gpa.free(a.bytes);
        gpa.free(self.other_actors);
        if (self.author) |bytes| gpa.free(bytes);
        gpa.free(self.extra);
        self.* = undefined;
    }

    /// True when `other` is one of this change's dependencies.
    pub fn hasDependency(self: ChangeMetadata, other: ChangeHash) bool {
        for (self.deps) |dep| {
            if (dep.eql(other)) return true;
        }
        return false;
    }

    /// The entry this change contributes to a sequence clock: its sequence
    /// number, because a clock entry counts an actor's changes
    /// (`clock.zig`) and `seq` is that count
    /// (`change_graph.rs:812-816`). Null when `seq` is past `u32::MAX`, which
    /// a clock entry cannot hold.
    pub fn clockEntry(self: ChangeMetadata) ?u32 {
        return std.math.cast(u32, self.seq);
    }
};

/// Reads the header of a change chunk body. `bytes` is the body only, with no
/// chunk framing, which is what `chunk.parseChunk` hands back and what
/// `decompressChunk` produces for a compressed change.
///
/// Everything borrowed out of the result points into `bytes`, so `bytes` must
/// outlive the change. The one allocation is the `other_actors` array; free it
/// with `Change.deinit`.
///
/// Refused, all of them `ParseError`:
///
/// * a header that runs off the end of the input, or a length inside it that
///   the remaining bytes could not hold;
/// * a dependency or other-actor count larger than the input could hold, which
///   is caught before anything is sized or indexed;
/// * a `start_op` of zero;
/// * a commit message that is not UTF-8.
///
/// The change hash is taken over the whole of `bytes` here, once, and only
/// after the header has parsed — so a body that is refused never pays for it.
/// A caller that already holds that hash hands it to [`parseChangeWithHash`]
/// and this one pass is not taken at all.
pub fn parseChange(bytes: []const u8, gpa: Allocator) ParseError!Change {
    return parseChangeWithHash(bytes, gpa, null);
}

/// [`parseChange`] with the change hash the caller already holds, which is the
/// seam between the chunk layer's one SHA-256 and this header reader.
///
/// `hash` must be `chunk.changeHashOf(.change, bytes)` — the whole thirty-two
/// bytes over `bytes` framed as a `change` chunk. That is exactly what
/// [`Chunk`](storage/chunk.zig)'s `hash` field carries for a chunk of this
/// type, which is where a chunk-path caller gets it without hashing again,
/// and what [`parseChange`] would have computed for itself. The change records
/// it verbatim.
///
/// **A null `hash` is not a different answer, it is no answer**: the hash is
/// taken here instead, in the same place [`parseChange`] takes it. That is
/// what makes a refused body cost no SHA-256 whichever spelling called this.
///
/// **Nothing here compares `hash` against `bytes`.** That check has already
/// been made, by the checksum comparison in `chunk.readChunk` over these very
/// bytes before it handed the chunk over (`chunk.rs:293-295` is upstream's
/// `checksum_valid`), and upstream's `parse_following_header` trusts the
/// `Header` it is given for the same reason
/// (`../github-automerge-automerge/rust/automerge/src/storage/change.rs:100-103`).
/// A caller that hands over the hash of some other body gets a change whose
/// `hash` is that other hash.
pub fn parseChangeWithHash(bytes: []const u8, gpa: Allocator, hash: ?ChangeHash) ParseError!Change {
    var in: Input = .init(bytes);

    var dep_sink: DepSink = .{ .in = &in };
    try in.readCountThen(&dep_sink, hash_size, DepSink.collect);

    const actor_bytes = try in.readStrBytes();
    const seq = try in.takeUleb();
    const start_op = try in.takeUleb();
    // Upstream's `NonZeroU64` (`parse/leb128.rs:87-96`); the port has no
    // non-optional integer, so the invariant is checked here.
    if (start_op == 0) return error.InvalidLeb128;
    const time = try in.takeLeb();
    const message = try in.readStr();

    var actor_sink: ActorSink = .{ .in = &in, .gpa = gpa };
    try in.readCountThen(&actor_sink, 1, ActorSink.collect);

    return .{
        .bytes = bytes,
        .header_len = in.pos,
        .actor = .{ .bytes = actor_bytes },
        .deps = dep_sink.deps,
        // The seam. The hash the caller had, or this one — taken here, after
        // the header parsed, which is where `parseChange` has always taken it,
        // so a refused body still costs no SHA-256.
        .hash = hash orelse chunk.changeHashOf(.change, bytes),
        .time = time,
        .message = message,
        .seq = seq,
        .start_op = start_op,
        // The op count lives in the columns, not in the header. Whoever
        // decodes them calls `withOpCount`.
        .max_op = 0,
        .other_actors = actor_sink.list,
    };
}

/// The `readCountThen` destination for the dependency list. A dependency is
/// 32 raw bytes with no length prefix, so a run of them is already a
/// `[]const ChangeHash` over the input and nothing is copied.
const DepSink = struct {
    in: *Input,
    deps: []const ChangeHash = &.{},

    fn collect(self: *DepSink, count: usize) ParseError!void {
        if (count == 0) return;
        // `readCountThen` proved `count <= remaining / hash_size`, so the
        // multiplication cannot overflow and the take cannot run out.
        const raw = try self.in.take(count * hash_size);
        self.deps = @as([*]const ChangeHash, @ptrCast(raw.ptr))[0..count];
    }
};

/// The `readCountThen` destination for the other actors. An actor is
/// length-prefixed, so the actors are not contiguous and the array of them
/// does have to be built.
const ActorSink = struct {
    in: *Input,
    gpa: Allocator,
    list: []const ActorId = &.{},

    fn collect(self: *ActorSink, count: usize) ParseError!void {
        // The common case: a change that only ever refers to its own actor.
        if (count == 0) return;
        const actors = try self.gpa.alloc(ActorId, count);
        errdefer self.gpa.free(actors);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            actors[i] = .{ .bytes = try self.in.readStrBytes() };
        }
        self.list = actors;
    }
};

/// A uleb128 byte count followed by the bytes. Upstream
/// `length_prefixed_bytes` (`storage/change.rs:304-308`), which is how the
/// writer emits the actor, the commit message, and each other actor.
fn appendLengthPrefixed(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8) Allocator.Error!void {
    try leb128.appendUnsigned(out, gpa, bytes.len);
    try out.appendSlice(gpa, bytes);
}

const testing = std.testing;

// The body of the first chunk of `test/fixtures/two_change_chunks.automerge`:
// the 57 bytes after its 10-byte header. Copied in so this port's header
// reader is pinned to bytes automerge wrote, not to bytes this port wrote.
const two_change_chunks_body = [_]u8{
    0x00, 0x10, 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00,
    0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d, 0x01, 0x01, 0xc1, 0xbe, 0xc4, 0x83,
    0xe1, 0x30, 0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x31, 0x00,
    0x05, 0x15, 0x03, 0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x70, 0x02, 0x7f,
    0x01, 0x61, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00,
};

// A body with one of every field shape, written out by hand: two
// dependencies, a three-byte actor, a two-byte sequence number, a three-byte
// start op, a negative timestamp, a message, and two other actors of
// different lengths. The tail stands in for the op columns and must survive
// untouched. Every byte is a literal, so a parser that reads the wrong field
// order fails here rather than agreeing with itself.

/// The dependency count and the two dependencies: 32 raw bytes each, with no
/// per-dependency length.
const built_deps = [_]u8{
    0x02, // 2 dependencies
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, // dep 0, bytes 0x00..0x1f
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, // dep 1, bytes 0xc0..0xdf
    0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf,
    0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7,
    0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf,
};

/// Every header field after the dependencies, as the writer emits it.
const built_header_tail = [_]u8{
    0x03, 0xaa, 0xbb, 0xcc, // actor
    0xac, 0x02, // seq = 300
    0x80, 0x80, 0x01, // start_op = 16384
    0x98, 0x78, // time = -1000
    0x08, 0x63, 0x68, 0x61, 0x6e, 0x67, 0x65, 0x20, 0x32, // message
    0x02, // 2 other actors
    0x01, 0x11, // first
    0x02, 0x22, 0x33, // second
};

/// The op columns, which this module must not touch.
const built_columns = [_]u8{ 0x05, 0x15, 0x03, 0x34 };

/// The header of `built_body`, as a literal, so the round trip is checked
/// against the bytes that were read and not against the writer.
const built_header = built_deps ++ built_header_tail;

const built_body = built_header ++ built_columns;

test "a hand-built header parses field by field" {
    const gpa = testing.allocator;
    // The literal header is the fixture: if this ever stops being true the
    // fixture and the expectations below have drifted apart.
    try testing.expectEqualSlices(u8, &built_header, built_body[0..built_header.len]);
    try testing.expectEqualSlices(u8, built_body[0..built_header.len], built_body[0..91]);

    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    try testing.expectEqual(built_header.len, change.header_len);
    try testing.expectEqual(@as(usize, 2), change.deps.len);
    // A dependency is 32 raw bytes: the first is 0x00..0x1f, the second
    // 0xc0..0xdf, and there is no per-dependency length.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 }, change.deps[0].bytes[0..8]);
    try testing.expectEqual(@as(u8, 0x1f), change.deps[0].bytes[31]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7 }, change.deps[1].bytes[0..8]);
    try testing.expectEqual(@as(u8, 0xdf), change.deps[1].bytes[31]);

    try testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0xcc }, change.actor.bytes);
    try testing.expectEqual(@as(u64, 300), change.seq);
    try testing.expectEqual(@as(u64, 16384), change.start_op);
    try testing.expectEqual(@as(i64, -1000), change.time);
    try testing.expectEqualStrings("change 2", change.message);

    try testing.expectEqual(@as(usize, 2), change.other_actors.len);
    try testing.expectEqualSlices(u8, &[_]u8{0x11}, change.other_actors[0].bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x22, 0x33 }, change.other_actors[1].bytes);

    // The op columns are left exactly as they were.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x15, 0x03, 0x34 }, change.opsBytes());
    // The op count is not in the header, so `max_op` stays 0 until the
    // columns are decoded.
    try testing.expectEqual(@as(u64, 0), change.max_op);
}

test "a parsed change re-encodes to the bytes it came from" {
    const gpa = testing.allocator;
    for ([_][]const u8{ &built_body, &two_change_chunks_body }) |body| {
        var change = try parseChange(body, gpa);
        defer change.deinit(gpa);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try change.encodeHeader(&out, gpa);

        // The header, written back from the fields, is the header that was
        // read.
        try testing.expectEqualSlices(u8, body[0..change.header_len], out.items);
        // And the whole body, header plus the columns left untouched.
        var whole: std.ArrayList(u8) = .empty;
        defer whole.deinit(gpa);
        try whole.appendSlice(gpa, out.items);
        try whole.appendSlice(gpa, change.opsBytes());
        try testing.expectEqualSlices(u8, body, whole.items);
    }
}

test "a change automerge wrote parses to the fields and hash it has" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), change.deps.len);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xda, 0x0a, 0x54, 0x54, 0x42, 0x43, 0x49, 0x84, 0x85, 0x00, 0xa5, 0xeb, 0xe1, 0xac, 0xd9, 0x4d },
        change.actor.bytes,
    );
    try testing.expectEqual(@as(u64, 1), change.seq);
    try testing.expectEqual(@as(u64, 1), change.start_op);
    try testing.expectEqual(@as(i64, 1675313094465), change.time);
    try testing.expectEqualStrings("change 1", change.message);
    try testing.expectEqual(@as(usize, 0), change.other_actors.len);
    // 1 + 17 + 1 + 1 + 6 + 9 + 1 bytes of header; the rest is the columns.
    try testing.expectEqual(@as(usize, 36), change.header_len);

    // The hash of the body framed as a change chunk. The expected value was
    // computed with an independent SHA-256 over `0x01 0x39 || body`, and the
    // first four of its bytes are the checksum the fixture's own chunk header
    // carries.
    const expected = try types.ChangeHash.parse(gpa, "9ac3d730f262da35e71db591b9e8150de9b02826daf75006f2298916adec6e0b");
    try testing.expectEqual(expected.bytes, change.hash.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x9a, 0xc3, 0xd7, 0x30 }, &change.hash.checksum());
    try testing.expect(change.hash.eql(chunk.changeHashOf(.change, &two_change_chunks_body)));
}

test "a hash the chunk already had is the hash the change records" {
    const gpa = testing.allocator;

    // The chunk path, which is where the body was hashed once to check the
    // four checksum bytes in the header and the rest was kept. The change is
    // handed those same thirty-two bytes.
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunk.writeChunk(&framed, gpa, .change, &two_change_chunks_body);
    const c = try chunk.parseChunk(framed.items);
    try testing.expectEqual(chunk.ChunkType.change, c.typ);
    const known = c.hash orelse return error.TestUnexpectedResult;

    var parsed = try parseChangeWithHash(c.data, gpa, known);
    defer parsed.deinit(gpa);
    try testing.expectEqual(known.bytes, parsed.hash.bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x9a, 0xc3, 0xd7, 0x30 }, &parsed.hash.checksum());
    try testing.expect(parsed.hash.eql(chunk.changeHashOf(.change, c.data)));

    // The self-hashing parse reaches the same change from the same body, so
    // supplying the hash changed the hash and nothing else.
    var computed = try parseChange(c.data, gpa);
    defer computed.deinit(gpa);
    try testing.expectEqual(computed.hash.bytes, parsed.hash.bytes);
    try testing.expectEqual(computed.header_len, parsed.header_len);
    try testing.expectEqualSlices(u8, computed.actor.bytes, parsed.actor.bytes);
    try testing.expectEqual(computed.deps.len, parsed.deps.len);
    try testing.expectEqual(computed.seq, parsed.seq);
    try testing.expectEqual(computed.start_op, parsed.start_op);
    try testing.expectEqual(computed.time, parsed.time);
    try testing.expectEqualStrings(computed.message, parsed.message);
    try testing.expectEqual(computed.other_actors.len, parsed.other_actors.len);
    for (computed.deps, parsed.deps) |a, b| try testing.expect(a.eql(b));

    // A null hash is "take it here", so all three spellings agree.
    var absent = try parseChangeWithHash(c.data, gpa, null);
    defer absent.deinit(gpa);
    try testing.expectEqual(computed.hash.bytes, absent.hash.bytes);
}

test "a supplied hash moves no refusal" {
    const gpa = testing.allocator;
    // The hash of a body that is not this one. It must not turn a refusal into
    // a parse, and it must not move one either.
    const bogus = types.ChangeHash.zero;

    // Every truncation of a valid header, both spellings. Which tag a
    // truncation gets depends on where it falls — a dependency count the
    // input cannot back is `LengthExceedsInput`, a missing byte is
    // `UnexpectedEnd` — so this pins that neither spelling parses it.
    for (0..built_header.len) |cut| {
        const body = built_body[0..cut];
        for ([_]?ChangeHash{ bogus, null }) |hash| {
            if (parseChangeWithHash(body, gpa, hash)) |change| {
                var owned = change;
                owned.deinit(gpa);
                return error.TestUnexpectedResult;
            } else |_| {}
        }
    }

    // Where a tag is known it is the same one either way.
    const too_many_deps = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00 };
    const bad_utf8 = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x02, 0xff, 0xfe, // message, not UTF-8
        0x00, // 0 other actors
    };
    const no_other_actors = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x04, // 4 other actors, and no bytes for them
    };
    const cases = [_]struct { body: []const u8, tag: ParseError }{
        .{ .body = &too_many_deps, .tag = error.LengthExceedsInput },
        .{ .body = &bad_utf8, .tag = error.InvalidUtf8 },
        .{ .body = &no_other_actors, .tag = error.LengthExceedsInput },
    };
    for (cases) |c| {
        try testing.expectError(c.tag, parseChangeWithHash(c.body, gpa, bogus));
        try testing.expectError(c.tag, parseChangeWithHash(c.body, gpa, null));
    }

    // And one that fails late in the header, after the dependencies, the actor
    // and the sequence number have all been read: a zero `start_op` is refused
    // with the hash in hand too, so a supplied hash neither short-circuits the
    // walk nor is walked to the end first.
    var zero_start_op: [built_body.len]u8 = built_body;
    var in: Input = .init(&zero_start_op);
    var dep_sink: DepSink = .{ .in = &in };
    try in.readCountThen(&dep_sink, hash_size, DepSink.collect);
    _ = try in.readStrBytes(); // actor
    _ = try in.takeUleb(); // seq
    zero_start_op[in.pos] = 0x00;
    try testing.expectError(error.InvalidLeb128, parseChangeWithHash(&zero_start_op, gpa, bogus));
    try testing.expectError(error.InvalidLeb128, parseChangeWithHash(&zero_start_op, gpa, null));
}

test "an encoded change is a chunk that reads back as the same body" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    const encoded = try change.encode(gpa);
    defer gpa.free(encoded);

    // The framing is the standard one, and the body is the change's bytes.
    try testing.expectEqualSlices(u8, &chunk.magic, encoded[0..4]);
    try testing.expectEqual(@as(u8, 0x01), encoded[8]);
    try testing.expectEqual(@as(u8, two_change_chunks_body.len), encoded[9]);
    try testing.expectEqualSlices(u8, &two_change_chunks_body, encoded[10..]);

    const read_back = try chunk.parseChunk(encoded);
    try testing.expectEqual(chunk.ChunkType.change, read_back.typ);
    try testing.expectEqualSlices(u8, &two_change_chunks_body, read_back.data);
}

test "a header that runs off the end is refused at every prefix" {
    const gpa = testing.allocator;
    // Every truncation of a valid header is a ParseError. The parser must
    // never believe a length the rest of the input cannot back.
    for (0..built_header.len) |cut| {
        if (parseChange(built_body[0..cut], gpa)) |change| {
            var owned = change;
            owned.deinit(gpa);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a zero start op is refused" {
    const gpa = testing.allocator;
    // The fixture with its start op zeroed. The byte is found by walking the
    // header the same way the parser does, not by hard-coding an offset.
    var bytes: [built_body.len]u8 = built_body;
    var in: Input = .init(&bytes);
    var dep_sink: DepSink = .{ .in = &in };
    try in.readCountThen(&dep_sink, hash_size, DepSink.collect);
    _ = try in.readStrBytes(); // actor
    _ = try in.takeUleb(); // seq
    const at = in.pos;
    bytes[at] = 0x00;

    try testing.expectError(error.InvalidLeb128, parseChange(&bytes, gpa));

    // The same body unaltered is fine, so the failure above is the zero and
    // not the edit.
    var good = try parseChange(&built_body, gpa);
    defer good.deinit(gpa);
    try testing.expectEqual(@as(u64, 16384), good.start_op);
}

test "a dependency count past the end of the input is refused" {
    const gpa = testing.allocator;
    // A ten-byte LEB128 claiming 2^64-1 dependencies, with one byte of input.
    const bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00 };
    try testing.expectError(error.LengthExceedsInput, parseChange(&bytes, gpa));

    // A count that is small but still larger than the input can hold: two
    // dependencies need 64 bytes and there are 40.
    var many: [41]u8 = @splat(0xaa);
    many[0] = 0x02;
    try testing.expectError(error.LengthExceedsInput, parseChange(many[0..41], gpa));
}

test "an other-actor count past the end of the input is refused" {
    const gpa = testing.allocator;
    // A header that is complete except that it claims 4 other actors and
    // carries none. The actor count is the last header field before the
    // columns.
    const none = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x04, // 4 other actors, and no bytes for them
    };
    try testing.expectError(error.LengthExceedsInput, parseChange(&none, gpa));

    // One actor's bytes is still not four.
    const one = [_]u8{ 0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x00, 0x04, 0x01, 0x42 };
    try testing.expectError(error.LengthExceedsInput, parseChange(&one, gpa));
}

test "a commit message that is not UTF-8 is refused" {
    const gpa = testing.allocator;
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x02, 0xff, 0xfe, // message, not UTF-8
        0x00, // 0 other actors
    };
    try testing.expectError(error.InvalidUtf8, parseChange(&bytes, gpa));

    // A lone continuation byte is the smallest such message.
    const lone = [_]u8{ 0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x01, 0x80, 0x00 };
    try testing.expectError(error.InvalidUtf8, parseChange(&lone, gpa));
}

test "an empty message and an absent one are the same" {
    const gpa = testing.allocator;
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x00, // 0 other actors
    };
    var change = try parseChange(&bytes, gpa);
    defer change.deinit(gpa);
    try testing.expectEqualStrings("", change.message);

    // Written back it is still a zero length, not a missing field.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try change.encodeHeader(&out, gpa);
    try testing.expectEqualSlices(u8, &bytes, out.items);
}

test "an other actor costs as little as one byte" {
    const gpa = testing.allocator;
    // The smallest an actor can be on the wire is a one-byte zero length, so
    // the bound the count is checked against is one byte per actor and not
    // two. A change carrying exactly one empty actor id is legal here and
    // must parse.
    const bytes = [_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x01, // start_op 1
        0x00, // time 0
        0x00, // empty message
        0x01, // 1 other actor
        0x00, // of length zero
    };
    var change = try parseChange(&bytes, gpa);
    defer change.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), change.other_actors.len);
    try testing.expectEqualSlices(u8, "", change.other_actors[0].bytes);

    // A count of two with one byte left is refused, which is the same bound
    // seen from the other side.
    const short = [_]u8{
        0x00, 0x01, 0x41, 0x01, 0x01, 0x00, 0x00, 0x02, 0x00,
    };
    try testing.expectError(error.LengthExceedsInput, parseChange(&short, gpa));
}

test "hasDependency finds a dependency and misses anything else" {
    const gpa = testing.allocator;
    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    try testing.expect(change.hasDependency(change.deps[0]));
    try testing.expect(change.hasDependency(change.deps[1]));
    // A hash that differs from a dependency in its last byte, and one that
    // differs in its first, are both absent: a stride or length off by one
    // would turn one of them into a hit.
    var flipped_last: [hash_size]u8 = change.deps[0].bytes;
    flipped_last[hash_size - 1] = 0x00;
    try testing.expect(!change.hasDependency(.{ .bytes = flipped_last }));
    var flipped_first: [hash_size]u8 = change.deps[1].bytes;
    flipped_first[0] = 0x00;
    try testing.expect(!change.hasDependency(.{ .bytes = flipped_first }));
    try testing.expect(!change.hasDependency(ChangeHash.zero));
    // A change with no dependencies has none.
    var empty = try parseChange(&two_change_chunks_body, gpa);
    defer empty.deinit(gpa);
    try testing.expect(!empty.hasDependency(change.deps[0]));
}

test "withOpCount derives max_op and refuses a counter that does not fit" {
    const gpa = testing.allocator;
    var change = try parseChange(&built_body, gpa);
    defer change.deinit(gpa);

    const verified = try change.withOpCount(3);
    try testing.expectEqual(@as(u64, 16386), verified.max_op);
    try testing.expectEqual(@as(u64, 16384), verified.start_op);

    // A change with no ops ends just before it starts.
    const none = try change.withOpCount(0);
    try testing.expectEqual(@as(u64, 16383), none.max_op);

    // One op at `start_op` is the degenerate case.
    const one = try change.withOpCount(1);
    try testing.expectEqual(one.start_op, one.max_op);

    // Op counters are u32, so a start op past that is a change this port
    // cannot represent. Upstream refuses it when it verifies the ops.
    var huge = try parseChange(&[_]u8{
        0x00, // 0 dependencies
        0x01, 0x41, // actor "A"
        0x01, // seq 1
        0x80, 0x80, 0x80, 0x80, 0x10, // start_op = 2^32
        0x00, // time 0
        0x00, // empty message
        0x00, // 0 other actors
    }, gpa);
    defer huge.deinit(gpa);
    try testing.expectEqual(@as(u64, 1 << 32), huge.start_op);
    try testing.expectError(error.Overflow, huge.withOpCount(1));
}

test "change metadata copies the change and can own its bytes" {
    const gpa = testing.allocator;
    const body = built_header ++ [_]u8{0};
    var change = try parseChange(&body, gpa);
    defer change.deinit(gpa);
    const verified = try change.withOpCount(0);

    const borrowed = try ChangeMetadata.fromChange(gpa, verified);
    try testing.expectEqual(change.hash.bytes, borrowed.hash.bytes);
    try testing.expectEqual(@as(u64, 300), borrowed.seq);
    try testing.expectEqual(@as(u64, 16384), borrowed.start_op);
    try testing.expectEqual(@as(u64, 16383), borrowed.max_op);
    try testing.expectEqual(@as(i64, -1000), borrowed.time);
    try testing.expectEqualStrings("change 2", borrowed.message);
    try testing.expectEqual(@as(u32, 300), borrowed.clockEntry().?);
    try testing.expect(borrowed.hasDependency(change.deps[1]));
    try testing.expect(!borrowed.hasDependency(ChangeHash.zero));

    // The owned copy does not point into the change's bytes.
    var owned = try borrowed.intoOwned(gpa);
    defer owned.deinit(gpa);
    try testing.expectEqual(borrowed.hash.bytes, owned.hash.bytes);
    try testing.expectEqualStrings(borrowed.message, owned.message);
    try testing.expectEqualSlices(u8, borrowed.actor.bytes, owned.actor.bytes);
    try testing.expectEqual(borrowed.deps.len, owned.deps.len);
    try testing.expectEqualSlices(u8, &borrowed.deps[1].bytes, &owned.deps[1].bytes);
    try testing.expectEqual(borrowed.other_actors.len, owned.other_actors.len);
    try testing.expectEqualSlices(u8, borrowed.other_actors[1].bytes, owned.other_actors[1].bytes);
    // Every owned slice is a distinct allocation.
    try testing.expect(owned.message.ptr != borrowed.message.ptr);
    try testing.expect(owned.deps.ptr != borrowed.deps.ptr);

    // Freeing the change leaves the metadata standing.
    change.deinit(gpa);
    try testing.expectEqualStrings("change 2", owned.message);
    try testing.expectEqual(@as(u64, 300), owned.seq);
}

test "debugString names the change" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);

    const text = try change.debugString(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "change 9ac3d730 by da0a5454424349848500a5ebe1acd94d seq 1 ops 1-0 at 1675313094465: change 1",
        text,
    );
}

// ── The hole that made a class of assertion vacuous ────────────────────────

// Every change a document hands out names the counter of its own last op row.
//
// **Why this test exists.** `max_op` is not in the change header — it is the
// row count of the op columns — so `parseChange` writes `.max_op = 0` and
// someone has to call [`Change.withOpCount`] once the columns are decoded
// (`change.zig:45-55`, `:380-382`). **A path that forgets is silent**: the
// change still parses, still hashes to the same thirty-two bytes, and still
// hands its peer every operation; only the range is wrong. Nothing about the
// shape of the old code made the omission fail, so in this tree two assertions
// that compared a re-parsed `max_op` against another re-parsed `max_op` were
// comparing zero with zero and could not fail. This test is the one that would
// have caught that class: it derives the answer from the change's own bytes,
// so the value under test cannot be the value that is wrong.
//
// Upstream cannot have the hole: `Change::new_from_unverified` counts the ops
// as it decodes them — `stored.verify_ops(|_| len += 1)`
// ([`change.rs:30-46`](../../github-automerge-automerge/rust/automerge/src/change.rs))
// — so `Change::max_op()` is `start_op + len - 1` for every `Change` that
// exists at all ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs)).
//
// The document is built by this test's own transactions, so the ranges below
// are the operation counts the test wrote and nothing else. Three routes out
// of the document are walked — [`doc.Document.getChanges`],
// [`doc.Document.getChangeByHash`] and [`doc.Document.getLastLocalChange`] —
// plus one change that arrived from a peer, because a change that was only
// ever applied never passed through the local commit path.
test "every change a document hands out names the counter its own last op row carries" {
    const docmod = @import("doc.zig");
    const transact = @import("transact.zig");

    const gpa = testing.allocator;
    var doc = try docmod.Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = &([_]u8{0xa1} ** 16) });

    // The rows the test writes: three operations in one change, then a merge
    // commit with none, then one more. **The empty change is the interesting
    // shape**: `start_op` is `graph.max_op() + 1` and its own `max_op` is one
    // below that, so the next change reuses the counter — which is the one
    // arrangement where a range read from the wrong end still looks plausible.
    {
        var t1 = try transact.Transaction.open(gpa, &doc);
        // On error the owning document is destroyed; on success the journal is closed.
        defer t1.deinitClosed();
        _ = try t1.put(.root, .{ .key = "a" }, .{ .int = 1 });
        const inner = try t1.putObject(.root, .{ .key = "m" }, .map);
        _ = try t1.put(inner, .{ .key = "deep" }, .{ .str = "v" });
        var committed1 = try t1.commitWith(.{ .message = null, .time = 1 });
        defer committed1.deinit(gpa);
        try testing.expect(committed1.hash != null);
    }

    _ = try doc.emptyCommit(gpa, null, 2);

    {
        var t2 = try transact.Transaction.open(gpa, &doc);
        defer t2.deinitClosed();
        _ = try t2.put(.root, .{ .key = "z" }, .{ .uint = 9 });
        var committed2 = try t2.commitWith(.{ .message = null, .time = 3 });
        defer committed2.deinit(gpa);
        try testing.expect(committed2.hash != null);
    }

    try testing.expectEqual(@as(u64, 4), doc.graph.maxOp());
    const actor = doc.getActorIndex().?;

    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), changes.len());

    // `start_op` and the row count, both written by the test above.
    const want = [_]struct { start: u64, rows: usize }{
        .{ .start = 1, .rows = 3 },
        .{ .start = 4, .rows = 0 },
        .{ .start = 4, .rows = 1 },
    };
    var rows_total: u64 = 0;
    for (changes.slice(), want) |built, w| {
        try testing.expectEqual(w.start, built.change.start_op);

        // **What the change's own columns say.** `opCount` walks the
        // run-length-encoded action column of the body the document just
        // handed out ([`storage/change_chunk.zig:399-410`](storage/change_chunk.zig)),
        // which is a count of rows and not a header field. It is the same
        // number `src/c/doc.zig`'s `AMchange.size` falls back to when a change
        // carries no `max_op`, and the same number upstream's `verify_ops`
        // counts.
        const rows = blk: {
            var block = try changechunk.parseChangeChunk(built.body, gpa);
            defer block.deinit(gpa);
            break :blk try block.opCount();
        };
        try testing.expectEqual(w.rows, rows);
        rows_total += rows;

        // **The assertion this test is for.** On the old code `max_op` came
        // back `0` from the re-parse and this compares `start_op + rows - 1`
        // against `0`, so it fails the moment the fill-in is dropped — which
        // is what `withOpCount` does and what a bare `parseChange` does not.
        try testing.expectEqual(
            (try built.change.withOpCount(rows)).max_op,
            built.change.max_op,
        );

        // **And the graph's interval query agrees.** `opidToHash` is the
        // function a wrong range breaks: it answers the change whose
        // `[start_op, max_op]` contains a counter
        // ([`change_graph.rs:300-320`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
        // A `max_op` of zero makes every counter the change owns belong to no
        // change at all, which is what a peer's `start_op` then collides with.
        if (rows == 0) {
            // An empty change owns no counter: `max_op` is one below
            // `start_op`, and the counter at `max_op` still belongs to the
            // change before it.
            try testing.expectEqual(built.change.start_op - 1, built.change.max_op);
            const below = doc.graph.opidToHash(.init(@intCast(built.change.max_op), actor));
            try testing.expect(below != null and !below.?.eql(built.change.hash));
        } else {
            const owned = doc.graph.opidToHash(.init(@intCast(built.change.max_op), actor));
            try testing.expect(owned != null and owned.?.eql(built.change.hash));
        }
    }
    // The ranges the changes claim partition the document's counters, with the
    // empty change's gap counted as the gap it is.
    try testing.expectEqual(doc.graph.maxOp(), rows_total);

    // **A peer is the consumer of the number.** [`change_queue.zig`](change_queue.zig)
    // counts a change's ops as `max_op - start_op + 1`, so a change whose
    // `max_op` was never filled in lands *no rows and no error*: the peer keeps
    // the header and none of the operations. The row counts above are what each
    // application has to land, so this is the same number observed at the far
    // end of the wire.
    var peer = try docmod.Document.init(gpa, std.testing.io);
    defer peer.deinit();
    for (changes.slice(), want) |built, w| {
        const framed = try built.change.encode(gpa);
        defer gpa.free(framed);
        try testing.expectEqual(w.rows, try peer.loadIncremental(gpa, framed));
    }
    try testing.expectEqual(@as(u64, 4), peer.graph.maxOp());

    // **The other direction: a change this document never wrote.** A change
    // that arrived over sync is decoded on the way in (`Document.applyChanges`
    // fills its range from the decoded rows), and has to come back out of
    // `getChangeByHash` carrying the same one.
    var other = try docmod.Document.init(gpa, std.testing.io);
    defer other.deinit();
    other.setActorId(.{ .bytes = &([_]u8{0xb2} ** 16) });
    {
        var t3 = try transact.Transaction.open(gpa, &other);
        defer t3.deinitClosed();
        _ = try t3.put(.root, .{ .key = "p" }, .{ .int = 4 });
        _ = try t3.put(.root, .{ .key = "q" }, .{ .int = 5 });
        var committed3 = try t3.commitWith(.{ .message = null, .time = 4 });
        defer committed3.deinit(gpa);
        try testing.expect(committed3.hash != null);
    }

    var theirs = try other.getChanges(gpa, &.{});
    defer theirs.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), theirs.len());
    const theirs_hash = theirs.slice()[0].change.hash;
    const theirs_framed = try theirs.slice()[0].change.encode(gpa);
    defer gpa.free(theirs_framed);
    try testing.expectEqual(@as(usize, 2), try doc.loadIncremental(gpa, theirs_framed));

    var back = (try doc.getChangeByHash(gpa, theirs_hash)).?;
    defer back.deinit(gpa);
    const back_rows = blk: {
        var block = try changechunk.parseChangeChunk(back.body, gpa);
        defer block.deinit(gpa);
        break :blk try block.opCount();
    };
    try testing.expectEqual(@as(usize, 2), back_rows);
    try testing.expectEqual(
        (try back.change.withOpCount(back_rows)).max_op,
        back.change.max_op,
    );
    try testing.expectEqual(@as(u64, 1), back.change.start_op);
    try testing.expectEqual(@as(u64, 2), back.change.max_op);

    // **The third route out**, which is the one the C ABI's
    // `AMgetLastLocalChange` takes. It is the local actor's last change, so it
    // is the one-op change written above and not the peer's.
    var last = (try doc.getLastLocalChange(gpa)).?;
    defer last.deinit(gpa);
    try testing.expectEqual(@as(u64, 4), last.change.start_op);
    try testing.expectEqual(@as(u64, 4), last.change.max_op);
    try testing.expectEqual(
        (try last.change.withOpCount(1)).max_op,
        last.change.max_op,
    );
}

test "change author reads individual empty arbitrary and opaque footers" {
    // A zero-column change separates footer semantics from document inheritance.
    const header = [_]u8{ 0, 1, 0xaa, 1, 17, 0, 0, 0, 0 };
    inline for (.{
        .{ .footer = "", .author = @as(?[]const u8, null) },
        .{ .footer = "\x01\x03\xff\x00\x80", .author = @as(?[]const u8, "\xff\x00\x80") },
        .{ .footer = "\x7f\x00\xfe", .author = @as(?[]const u8, null) },
    }) |case| {
        const body = header ++ case.footer;
        var change = try parseChange(body, testing.allocator);
        defer change.deinit(testing.allocator);
        const author = try change.author(testing.allocator);
        if (case.author) |expected| {
            try testing.expectEqualSlices(u8, expected, author.?);
        } else {
            try testing.expect(author == null);
        }
    }
}

test "change author ignores malformed individual footer like Rust" {
    const body = [_]u8{ 0, 1, 0xaa, 1, 17, 0, 0, 0, 0, 1, 3, 0xff };
    var change = try parseChange(&body, testing.allocator);
    defer change.deinit(testing.allocator);
    try testing.expect((try change.author(testing.allocator)) == null);
}

test "expanded change owns decoded operations and preserves binary identity" {
    const gpa = testing.allocator;
    var source = try gpa.dupe(u8, &two_change_chunks_body);
    var change = try parseChange(source, gpa);
    var expanded = try change.decode(gpa);
    defer expanded.deinit(gpa);
    const original_hash = change.hash;
    change.deinit(gpa);
    gpa.free(source);
    source = &.{};
    try testing.expectEqualStrings("change 1", expanded.message.?);
    try testing.expectEqual(@as(usize, 1), expanded.ops.len);
    var rebuilt = try expanded.encode(gpa);
    defer rebuilt.deinit(gpa);
    try testing.expect(original_hash.eql(rebuilt.change.hash));
    try testing.expectEqual(@as(u64, 1), rebuilt.change.max_op);
}

test "expanded authored operation preserves reference bytes through JSON and opaque footer" {
    // tools/oracle/src/api_parity.rs:792-797 writes this one-op reference.
    // Rust change.rs:206-216 ignores informational author/hash on conversion;
    // the complete footer, including its unknown suffix, determines identity.
    const gpa = testing.allocator;
    const reference_hex =
        "856f4a83f46c71c5013b000fa1a1a1a1a1a1a1a1a1a1a1a1a1a1a10101000000" ++
        "05150a34014202560270027f08617574686f726564017f017f027f000103ff008000ff8042";
    var reference: [reference_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&reference, reference_hex);
    var reference_hash: [hash_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &reference_hash,
        "f46c71c52cf27a837e54ae553224aebe1d7be42d2ef2a361849a0f896ac0f98c",
    );
    const json =
        \\{"ops":[{"action":"set","obj":"_root","key":"authored","value":true,"pred":[]}],
        \\"actor":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","seq":1,"startOp":1,"time":0,
        \\"message":null,"deps":[],"extra_bytes":[1,3,255,0,128,0,255,128,66],
        \\"author":"00","hash":"0000000000000000000000000000000000000000000000000000000000000000"}
    ;
    var parsed = try std.json.parseFromSlice(ExpandedChange, gpa, json, .{});
    defer parsed.deinit();
    var built = try parsed.value.encode(gpa);
    defer built.deinit(gpa);
    try testing.expectEqualSlices(u8, &reference_hash, &built.change.hash.bytes);
    const encoded = try built.change.rawBytes(gpa);
    defer gpa.free(encoded);
    try testing.expectEqualSlices(u8, &reference, encoded);
    try testing.expectEqual(@as(u64, 1), built.change.max_op);

    var loaded = try Change.fromBytes(gpa, &reference);
    defer loaded.deinit(gpa);
    var decoded = try loaded.change.decode(gpa);
    defer decoded.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), decoded.ops.len);
    try testing.expect(decoded.ops[0].action.put.bool_value);
    try testing.expectEqualSlices(u8, "\xff\x00\x80", decoded.author.?);
    try testing.expectEqualSlices(u8, "\x01\x03\xff\x00\x80\x00\xff\x80B", decoded.extra_bytes);
    const serialized = try std.json.Stringify.valueAlloc(gpa, decoded, .{});
    defer gpa.free(serialized);
    var reparsed = try std.json.parseFromSlice(ExpandedChange, gpa, serialized, .{});
    defer reparsed.deinit();
    var rebuilt = try reparsed.value.encode(gpa);
    defer rebuilt.deinit(gpa);
    try testing.expectEqualSlices(u8, &reference_hash, &rebuilt.change.hash.bytes);
    const rebuilt_bytes = try rebuilt.change.rawBytes(gpa);
    defer gpa.free(rebuilt_bytes);
    try testing.expectEqualSlices(u8, &reference, rebuilt_bytes);
}

test "expanded empty change JSON preserves author opaque bytes and empty interval" {
    const gpa = testing.allocator;
    const Expanded = @import("change.zig").ExpandedChange;
    const json =
        \\{"ops":[],"actor":"aa","seq":1,"startOp":17,"time":-1,"message":null,"deps":[],"extra_bytes":[1,3,255,0,128,127,0,254],"author":"ff0080"}
    ;
    var parsed = try std.json.parseFromSlice(Expanded, gpa, json, .{});
    defer parsed.deinit();
    var built = try parsed.value.encode(gpa);
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u64, 16), built.change.max_op);
    var expanded = try built.change.decode(gpa);
    defer expanded.deinit(gpa);
    try testing.expectEqualSlices(u8, "\xff\x00\x80", expanded.author.?);
    try testing.expectEqualSlices(u8, "\x01\x03\xff\x00\x80\x7f\x00\xfe", expanded.extra_bytes);
    const output_json = try std.json.Stringify.valueAlloc(gpa, expanded, .{});
    defer gpa.free(output_json);
    var roundtrip = try std.json.parseFromSlice(Expanded, gpa, output_json, .{});
    defer roundtrip.deinit();
    var rebuilt = try roundtrip.value.encode(gpa);
    defer rebuilt.deinit(gpa);
    try testing.expect(built.change.hash.eql(rebuilt.change.hash));
}

test "expanded operation variants retain ordered predecessors and typed values" {
    const gpa = testing.allocator;
    const Expanded = @import("change.zig").ExpandedChange;
    const json =
        \\{"ops":[
        \\{"action":"makeMap","obj":"_root","key":"map","pred":[]},
        \\{"action":"makeTable","obj":"_root","key":"table","pred":[]},
        \\{"action":"makeList","obj":"_root","key":"list","pred":[]},
        \\{"action":"makeText","obj":"_root","key":"text","pred":[]},
        \\{"action":"set","obj":"_root","key":"int","datatype":"int","value":-2,"pred":["1@bb","2@aa"]},
        \\{"action":"set","obj":"_root","key":"uint","datatype":"uint","value":18446744073709551615,"pred":[]},
        \\{"action":"set","obj":"_root","key":"float","datatype":"float64","value":1.5,"pred":[]},
        \\{"action":"set","obj":"_root","key":"counter","datatype":"counter","value":8,"pred":[]},
        \\{"action":"set","obj":"_root","key":"timestamp","datatype":"timestamp","value":-4,"pred":[]},
        \\{"action":"set","obj":"_root","key":"null","value":null,"pred":[]},
        \\{"action":"set","obj":"_root","key":"bool","value":true,"pred":[]},
        \\{"action":"set","obj":"3@aa","elemId":"_head","insert":true,"value":"hello","pred":[]},
        \\{"action":"inc","obj":"_root","key":"counter","value":-3,"pred":["8@aa"]},
        \\{"action":"del","obj":"3@aa","elemId":"12@aa","pred":["12@aa"]},
        \\{"action":"markBegin","obj":"4@aa","elemId":"_head","insert":true,"name":"bold","value":true,"expand":true,"pred":[]},
        \\{"action":"markEnd","obj":"4@aa","elemId":"15@aa","insert":true,"expand":false,"pred":[]}
        \\],"actor":"aa","seq":1,"startOp":1,"time":0,"message":"variants","deps":[]}
    ;
    var parsed = try std.json.parseFromSlice(Expanded, gpa, json, .{});
    defer parsed.deinit();
    var built = try parsed.value.encode(gpa);
    defer built.deinit(gpa);
    var expanded = try built.change.decode(gpa);
    defer expanded.deinit(gpa);
    try testing.expectEqual(@as(usize, 16), expanded.ops.len);
    const serialized = try std.json.Stringify.valueAlloc(gpa, expanded, .{});
    defer gpa.free(serialized);
    var reparsed = try std.json.parseFromSlice(Expanded, gpa, serialized, .{});
    defer reparsed.deinit();
    var rebuilt = try reparsed.value.encode(gpa);
    defer rebuilt.deinit(gpa);
    try testing.expect(built.change.hash.eql(rebuilt.change.hash));
}

test "expanded operation datatype validation rejects incompatible scalars" {
    const Expanded = @import("change.zig").ExpandedChange;
    const json =
        \\{"ops":[{"action":"set","obj":"_root","key":"bad","datatype":"counter","value":true,"pred":[]}],"actor":"aa","seq":1,"startOp":1,"time":0,"message":null,"deps":[]}
    ;
    try testing.expectError(
        error.UnexpectedToken,
        std.json.parseFromSlice(Expanded, testing.allocator, json, .{}),
    );
}

test "expanded binary conversion preserves bytes unknown values and unknown footer" {
    const gpa = testing.allocator;
    const Expanded = @import("change.zig").ExpandedChange;
    const Op = @import("change.zig").ExpandedOp;
    const ops = [_]Op{
        .{
            .action = .{ .put = .{ .bytes = "\x00\xff\x80" } },
            .obj = .root,
            .key = .{ .map = "bytes" },
            .pred = &.{},
            .insert = false,
        },
        .{
            .action = .{ .put = .{ .unknown = .{ .type_code = 15, .bytes = "\xfe\x00" } } },
            .obj = .root,
            .key = .{ .map = "unknown" },
            .pred = &.{},
            .insert = false,
        },
    };
    const expanded: Expanded = .{
        .ops = &ops,
        .actor = .{ .bytes = "\xaa" },
        .seq = 1,
        .start_op = 1,
        .time = 0,
        .message = null,
        .deps = &.{},
        .extra_bytes = "\x7f\x00\xfe",
    };
    var built = try expanded.encode(gpa);
    defer built.deinit(gpa);
    var decoded = try built.change.decode(gpa);
    defer decoded.deinit(gpa);
    try testing.expectEqualSlices(u8, "\x00\xff\x80", decoded.ops[0].action.put.bytes);
    try testing.expectEqual(@as(u8, 15), decoded.ops[1].action.put.unknown.type_code);
    try testing.expectEqualSlices(u8, "\xfe\x00", decoded.ops[1].action.put.unknown.bytes);
    try testing.expectEqualSlices(u8, expanded.extra_bytes, decoded.extra_bytes);
    try testing.expect(decoded.author == null);
    var rebuilt = try decoded.encode(gpa);
    defer rebuilt.deinit(gpa);
    try testing.expect(built.change.hash.eql(rebuilt.change.hash));
}

test "change byte helpers return independent framed and compressed owners" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try change.len(gpa));
    try testing.expect(!(try change.isEmpty(gpa)));
    const raw = try change.rawBytes(gpa);
    defer gpa.free(raw);
    const compressed = try change.compressedBytes(gpa);
    defer gpa.free(compressed);
    var reparsed = try Change.fromBytes(gpa, compressed);
    defer reparsed.deinit(gpa);
    try testing.expect(change.hash.eql(reparsed.change.hash));
    try testing.expectEqual(@as(u64, 1), reparsed.change.max_op);
    const raw_chunk = try chunk.parseChunk(raw);
    try testing.expectEqualSlices(u8, change.bytes, raw_chunk.data);
    const actors = try change.actorsOwned(gpa);
    defer {
        for (actors) |actor| gpa.free(actor.bytes);
        gpa.free(actors);
    }
    try testing.expectEqual(@as(usize, 1), actors.len);
    try testing.expectEqualSlices(u8, change.actor.bytes, actors[0].bytes);
}

test "expanded decoding and reencoding release partial allocation failures" {
    const Probe = struct {
        fn run(gpa: Allocator) !void {
            var change = try parseChange(&two_change_chunks_body, gpa);
            defer change.deinit(gpa);
            var expanded = try change.decode(gpa);
            defer expanded.deinit(gpa);
            var built = try expanded.encode(gpa);
            defer built.deinit(gpa);
            try testing.expect(change.hash.eql(built.change.hash));
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Probe.run, .{});
}

test "expanded encoding rejects overflowing counter intervals" {
    const Expanded = @import("change.zig").ExpandedChange;
    const Op = @import("change.zig").ExpandedOp;
    const ops = [_]Op{
        .{
            .action = .{ .put = .null_value },
            .obj = .root,
            .key = .{ .map = "a" },
            .pred = &.{},
            .insert = false,
        },
        .{
            .action = .{ .put = .null_value },
            .obj = .root,
            .key = .{ .map = "b" },
            .pred = &.{},
            .insert = false,
        },
    };
    const expanded: Expanded = .{
        .ops = &ops,
        .actor = .{ .bytes = "\xaa" },
        .seq = 1,
        .start_op = std.math.maxInt(u32),
        .time = 0,
        .message = null,
        .deps = &.{},
    };
    try testing.expectError(error.Overflow, expanded.encode(testing.allocator));
}

test "change framed parsing rejects trailing bytes and non change chunks" {
    const gpa = testing.allocator;
    var change = try parseChange(&two_change_chunks_body, gpa);
    defer change.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const encoded = try change.encode(gpa);
    defer gpa.free(encoded);
    try out.appendSlice(gpa, encoded);
    try out.append(gpa, 0);
    try testing.expectError(error.TrailingBytes, Change.fromBytes(gpa, out.items));
    out.clearRetainingCapacity();
    try chunk.writeChunk(&out, gpa, .document, "");
    try testing.expectError(error.InvalidChunkType, Change.fromBytes(gpa, out.items));
}

test "change operation count rejects oversized intervals without arithmetic panic" {
    var change = try parseChange(&two_change_chunks_body, testing.allocator);
    defer change.deinit(testing.allocator);
    try testing.expectError(error.Overflow, change.withOpCount(std.math.maxInt(u64)));
    change.start_op = std.math.maxInt(u32);
    try testing.expectError(error.Overflow, change.withOpCount(2));
    const empty = try change.withOpCount(0);
    try testing.expectEqual(@as(u64, std.math.maxInt(u32) - 1), empty.max_op);
}

test "expanded operation standalone copy survives its parent and source bytes" {
    const gpa = testing.allocator;
    const source = try gpa.dupe(u8, &two_change_chunks_body);
    var change = try parseChange(source, gpa);
    var expanded = try change.decode(gpa);
    const expected_json = try std.json.Stringify.valueAlloc(gpa, expanded.ops[0], .{});
    defer gpa.free(expected_json);
    var op = try expanded.ops[0].dup(gpa);
    defer op.deinit(gpa);
    expanded.deinit(gpa);
    change.deinit(gpa);
    gpa.free(source);
    const actual_json = try std.json.Stringify.valueAlloc(gpa, op, .{});
    defer gpa.free(actual_json);
    try testing.expectEqualStrings(expected_json, actual_json);
}

test "expanded structured JSON rejects bytes and unknown values like Rust" {
    const gpa = testing.allocator;
    inline for (.{
        value.ScalarValue{ .bytes = "\x00\xff" },
        value.ScalarValue{ .unknown = .{ .type_code = 15, .bytes = "\x80" } },
    }) |scalar| {
        const ops = [_]ExpandedOp{.{
            .action = .{ .put = scalar },
            .obj = .root,
            .key = .{ .map = "value" },
            .pred = &.{},
        }};
        const expanded: ExpandedChange = .{
            .ops = &ops,
            .actor = .{ .bytes = "\xaa" },
            .seq = 1,
            .start_op = 1,
            .time = 0,
            .message = null,
            .deps = &.{},
        };
        const json = try std.json.Stringify.valueAlloc(gpa, expanded, .{});
        defer gpa.free(json);
        try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(ExpandedChange, gpa, json, .{}));
    }
}

test "expanded informational author and hash never replace authoritative extra bytes" {
    const gpa = testing.allocator;
    const expanded: ExpandedChange = .{
        .ops = &.{},
        .actor = .{ .bytes = "\xaa" },
        .seq = 1,
        .start_op = 17,
        .time = 0,
        .message = null,
        .deps = &.{},
        .author = "\xff\x80",
        .hash = ChangeHash.zero,
    };
    var built = try expanded.encode(gpa);
    defer built.deinit(gpa);
    try testing.expect((try built.change.author(gpa)) == null);
    try testing.expect(!built.change.hash.eql(ChangeHash.zero));
    var decoded = try built.change.decode(gpa);
    defer decoded.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), decoded.extra_bytes.len);
    try testing.expect(decoded.author == null);
}

test "change compression helper uses framed cutoff and preserves decompressed identity" {
    const gpa = testing.allocator;
    const ops = [_]ExpandedOp{.{
        .action = .{ .put = .{ .str = "repeated payload " ** 40 } },
        .obj = .root,
        .key = .{ .map = "payload" },
        .pred = &.{},
    }};
    const expanded: ExpandedChange = .{
        .ops = &ops,
        .actor = .{ .bytes = "\xaa" },
        .seq = 1,
        .start_op = 1,
        .time = 0,
        .message = null,
        .deps = &.{},
    };
    var built = try expanded.encode(gpa);
    defer built.deinit(gpa);
    const bytes = try built.change.compressedBytes(gpa);
    defer gpa.free(bytes);
    const framed = try chunk.parseChunk(bytes);
    try testing.expectEqual(chunk.ChunkType.compressed, framed.typ);
    var restored = try Change.fromBytes(gpa, bytes);
    defer restored.deinit(gpa);
    try testing.expect(built.change.hash.eql(restored.change.hash));
    try testing.expectEqualSlices(u8, built.body, restored.body);
}

test "change metadata owns individual author and complete opaque footer" {
    const gpa = testing.allocator;
    const source = try gpa.dupe(u8, &[_]u8{ 0, 1, 0xaa, 1, 17, 0, 0, 0, 0, 1, 3, 0xff, 0, 0x80, 0xfe });
    var change = try parseChange(source, gpa);
    const borrowed = try ChangeMetadata.fromChange(gpa, try change.withOpCount(0));
    var owned = try borrowed.intoOwned(gpa);
    defer owned.deinit(gpa);
    change.deinit(gpa);
    gpa.free(source);
    try testing.expectEqualSlices(u8, "\xff\x00\x80", owned.author.?);
    try testing.expectEqualSlices(u8, "\x01\x03\xff\x00\x80\xfe", owned.extra);
    try testing.expectEqual(@as(u64, 16), owned.max_op);
}

test "change metadata allocation failures never leak author or opaque footer" {
    const Probe = struct {
        fn run(gpa: Allocator) !void {
            const body = [_]u8{
                0, 1, 0xaa, 1, 17, 0, 0, 0, 0, 1, 3, 0xff, 0, 0x80, 0xfe,
            };
            var change = try parseChange(&body, gpa);
            defer change.deinit(gpa);
            const borrowed = try ChangeMetadata.fromChange(gpa, try change.withOpCount(0));
            var owned = try borrowed.intoOwned(gpa);
            defer owned.deinit(gpa);
            try testing.expectEqualSlices(u8, "\xff\x00\x80", owned.author.?);
            try testing.expectEqualSlices(u8, "\x01\x03\xff\x00\x80\xfe", owned.extra);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Probe.run, .{});
}
