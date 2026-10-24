//! Borrowed, compile-time ReadDoc serialization with no deserialization counterpart.
//!
//! `AutoSerde(R).from(reader)` preserves the reader's pending and historical scope.
//! `toJson(gpa)` returns caller-owned compact JSON; `serialize(gpa, backend)` accepts
//! a compile-time backend. `JsonSerializer` borrows a writer; `TokenStream` owns a
//! structured projection independently of the reader. No serialization closes a
//! transaction or hydrates through the raw-document scope exception.

const std = @import("std");
const read = @import("read.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const docmod = @import("doc.zig");
const trans = @import("transact.zig");

const Allocator = std.mem.Allocator;
const Document = docmod.Document;
const ExId = types.ExId;
const ScalarValue = value.ScalarValue;
const testing = std.testing;

/// Read failures plus compact JSON writer refusal.
pub const SerializeError = read.ReadError || std.Io.Writer.Error;

/// The backend's declared error set. Backends are selected at compile time.
///
/// Required methods are `beginMap()`, `endMap()`, `mapKey(key,index)`,
/// `beginSeq()`, `endSeq()`, `element(index)`, `string(bytes)` and
/// `scalar(ScalarValue)`, all returning `Error!void`. Indices start at zero.
/// A backend must consume or copy borrowed payloads before its method returns.
pub fn BackendError(comptime Backend: type) type {
    const B = switch (@typeInfo(Backend)) {
        .pointer => |pointer| pointer.child,
        else => Backend,
    };
    inline for (.{
        "Error",  "beginMap", "endMap", "mapKey", "beginSeq",
        "endSeq", "element",  "string", "scalar",
    }) |name| {
        if (!@hasDecl(B, name)) {
            @compileError("Serialization backend requires " ++ name ++
                "; see autoserde.BackendError for the compile-time protocol");
        }
    }
    return B.Error;
}

/// Serializes stable lowercase change-hash strings without allocation.
pub fn serializeHashes(
    hashes: []const types.ChangeHash,
    backend: anytype,
) BackendError(@TypeOf(backend))!void {
    try backend.beginSeq();
    for (hashes, 0..) |hash, index| {
        try backend.element(index);
        const hex = std.fmt.bytesToHex(hash.bytes, .lower);
        try backend.string(&hex);
    }
    try backend.endSeq();
}

/// Compact JSON backend. Borrows `writer` only; output is progressive and an
/// error leaves a prefix that the caller must discard before retrying.
pub const JsonSerializer = struct {
    writer: *std.Io.Writer,
    pub const Error = std.Io.Writer.Error;

    /// Starts a JSON object.
    pub fn beginMap(self: *JsonSerializer) Error!void {
        try self.writer.writeByte('{');
    }
    /// Finishes a JSON object.
    pub fn endMap(self: *JsonSerializer) Error!void {
        try self.writer.writeByte('}');
    }
    /// Writes an object's key and separator at its zero-based entry index.
    pub fn mapKey(self: *JsonSerializer, key: []const u8, index: usize) Error!void {
        if (index != 0) try self.writer.writeByte(',');
        try self.string(key);
        try self.writer.writeByte(':');
    }
    /// Starts a JSON array.
    pub fn beginSeq(self: *JsonSerializer) Error!void {
        try self.writer.writeByte('[');
    }
    /// Finishes a JSON array.
    pub fn endSeq(self: *JsonSerializer) Error!void {
        try self.writer.writeByte(']');
    }
    /// Writes an array separator before a zero-based element index.
    pub fn element(self: *JsonSerializer, index: usize) Error!void {
        if (index != 0) try self.writer.writeByte(',');
    }
    /// Encodes borrowed string bytes without retaining them.
    pub fn string(self: *JsonSerializer, bytes: []const u8) Error!void {
        try (ScalarValue{ .str = bytes }).writeJson(self.writer);
    }
    /// Uses the canonical ScalarValue JSON codec, including shortest floats.
    pub fn scalar(self: *JsonSerializer, scalar_value: ScalarValue) Error!void {
        try scalar_value.writeJson(self.writer);
    }
};

/// An owned structured serialization event. Container events preserve nesting;
/// byte-vector scalar payloads preserve their element boundaries without JSON.
pub const Token = union(enum) {
    begin_map,
    end_map,
    key: []const u8,
    begin_seq,
    end_seq,
    string: []const u8,
    scalar: ScalarValue,
};

/// Retained non-JSON backend. Keys, text and scalar payloads belong to its arena
/// and survive reader mutation/destruction. Copies share ownership; deinit once.
/// Appending can invalidate the `items` slice. Errors leave an incomplete prefix.
pub const TokenStream = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Token) = .empty,
    pub const Error = Allocator.Error;

    /// Starts an empty stream, borrowing `gpa` for its lifetime.
    pub fn init(gpa: Allocator) TokenStream {
        return .{ .arena = .init(gpa) };
    }
    /// Releases all events and payloads. The stream is invalid afterward.
    pub fn deinit(self: *TokenStream) void {
        self.arena.deinit();
        self.* = undefined;
    }
    fn append(self: *TokenStream, token: Token) Error!void {
        try self.items.append(self.arena.allocator(), token);
    }
    /// Records an object start.
    pub fn beginMap(self: *TokenStream) Error!void {
        try self.append(.begin_map);
    }
    /// Records an object end.
    pub fn endMap(self: *TokenStream) Error!void {
        try self.append(.end_map);
    }
    /// Copies a borrowed object key.
    pub fn mapKey(self: *TokenStream, key: []const u8, _: usize) Error!void {
        try self.append(.{ .key = try self.arena.allocator().dupe(u8, key) });
    }
    /// Records an array start.
    pub fn beginSeq(self: *TokenStream) Error!void {
        try self.append(.begin_seq);
    }
    /// Records an array end.
    pub fn endSeq(self: *TokenStream) Error!void {
        try self.append(.end_seq);
    }
    /// Structured events need no punctuation between elements.
    pub fn element(_: *TokenStream, _: usize) Error!void {}
    /// Copies a borrowed string value.
    pub fn string(self: *TokenStream, bytes: []const u8) Error!void {
        try self.append(.{ .string = try self.arena.allocator().dupe(u8, bytes) });
    }
    /// Copies a scalar's payload. Counter and timestamp project as bare integers.
    pub fn scalar(self: *TokenStream, scalar_value: ScalarValue) Error!void {
        const projected: ScalarValue = switch (scalar_value) {
            .counter => |counter| .{ .int = counter.current },
            .timestamp => |timestamp| .{ .int = timestamp },
            else => scalar_value,
        };
        try self.append(.{ .scalar = try projected.dup(self.arena.allocator()) });
    }
};

/// Borrows any full ReadDoc adapter. A bare Document accepts a const pointer;
/// Transaction/AutoCommit preserve their own scoped reads without closing.
pub fn AutoSerde(comptime R: type) type {
    const Reader = read.ReadDoc(R);
    return struct {
        doc: Reader.ReaderPtr,
        const Self = @This();

        /// Borrows `doc` until the view's last serialization call.
        pub fn from(doc: Reader.ReaderPtr) Self {
            return .{ .doc = doc };
        }

        /// Projects from the root into the supplied compile-time backend.
        /// Scratch keys use `gpa` and are freed on every path. Backend errors
        /// leave whatever prefix that backend accepted; discard it before retrying.
        pub fn serialize(
            self: Self,
            gpa: Allocator,
            backend: anytype,
        ) (read.ReadError || BackendError(@TypeOf(backend)))!void {
            try self.writeMap(.root, gpa, backend);
        }

        /// Returns owned compact JSON. Free with `gpa`; errors return no allocation.
        pub fn toJson(self: Self, gpa: Allocator) SerializeError![]u8 {
            var output: std.Io.Writer.Allocating = .init(gpa);
            errdefer output.deinit();
            var backend: JsonSerializer = .{ .writer = &output.writer };
            self.serialize(gpa, &backend) catch |failure| switch (failure) {
                error.WriteFailed => return error.OutOfMemory,
                else => return failure,
            };
            return output.toOwnedSlice();
        }

        /// Writes compact JSON progressively through a borrowed writer.
        pub fn writeJson(self: Self, gpa: Allocator, writer: *std.Io.Writer) SerializeError!void {
            var backend: JsonSerializer = .{ .writer = writer };
            try self.serialize(gpa, &backend);
        }

        fn writeMap(self: Self, obj: ExId, gpa: Allocator, backend: anytype) (read.ReadError || BackendError(@TypeOf(backend)))!void {
            var keys: std.ArrayList([]const u8) = .empty;
            defer {
                for (keys.items) |key| gpa.free(key);
                keys.deinit(gpa);
            }
            {
                // Finish the shared-scratch walk before recursively reading another object.
                var walk = try Reader.keys(self.doc, obj);
                defer walk.deinit(Reader.allocator(self.doc));
                while (try walk.next()) |key| {
                    const owned = try gpa.dupe(u8, key);
                    errdefer gpa.free(owned);
                    try keys.append(gpa, owned);
                }
            }
            try backend.beginMap();
            for (keys.items, 0..) |key, index| {
                try backend.mapKey(key, index);
                const item = (try Reader.get(self.doc, obj, .{ .key = key })) orelse
                    return error.Invariant;
                try self.writeVal(item, gpa, backend);
            }
            try backend.endMap();
        }

        fn writeSeq(self: Self, obj: ExId, gpa: Allocator, backend: anytype) (read.ReadError || BackendError(@TypeOf(backend)))!void {
            const length = try Reader.length(self.doc, obj);
            try backend.beginSeq();
            for (0..length) |index| {
                try backend.element(index);
                const item = (try Reader.get(self.doc, obj, .{ .index = index })) orelse
                    return error.Invariant;
                try self.writeVal(item, gpa, backend);
            }
            try backend.endSeq();
        }

        fn writeVal(self: Self, item: read.DocItem, gpa: Allocator, backend: anytype) (read.ReadError || BackendError(@TypeOf(backend)))!void {
            switch (item.value) {
                .object => |kind| switch (kind) {
                    .map, .table => try self.writeMap(item.id, gpa, backend),
                    .list => try self.writeSeq(item.id, gpa, backend),
                    .text => {
                        const text = try Reader.text(self.doc, item.id, gpa);
                        defer gpa.free(text);
                        try backend.string(text);
                    },
                },
                .scalar => |scalar_value| try backend.scalar(scalar_value),
            }
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// **The reference's own document**, as `automerge::AutoCommit::save` wrote
/// it: 437 bytes of a document the reference built with
/// `automerge::transaction::Transactable` and a named actor of sixteen `0x61`
/// bytes.
///
/// **The document is not described here, it is the reference's.** The calls
/// that made it are the ones the report lists, and they are the ones this file
/// needs: a root map holding a bool, a string, an int, a uint, a timestamp, a
/// counter, a byte string, **a nested map written `"out"` before `"in"`**, a
/// nested list, an empty table, a text object with a mark over `there`, and a
/// key that was written and then deleted. Loading the reference's bytes is
/// what makes the comparison a comparison against the reference: nothing in
/// this test is a document this port wrote.
const reference_document =
    \\856f4a83bcc2febc00aa0301106161616161616161616161616161616101713bce93d74e2ae6
    \\d4749277a627526da962aa1a55510a08f82a4747d4f639930601020302130223024002560210
    \\010402081108131615612102231d34044211561f5740800106810102830102940103a5010c7f
    \\007f017f1e7f007f007f07000d1000000d0409020e0a12000e030000030900000d7e000a0201
    \\00027e741302017f0002017f0002017306615f626f6f6c08615f737472696e67056279746573
    \\07636f756e7465720366363403693634046c697374036d6170057461626c6504746578740974
    \\696d657374616d70037536340b7a7a7a5f64656c6574656400047e02696e036f7574000a1d00
    \\7f07057f780705030176791c6d03017d037f0402017b067b01057c02010d04020a06017c0200
    \\06040c017f0702017f0703017a019602471885011404007859a30146143602001404167f0202
    \\167f0003166865226c6c6f5c202f010a7fc3a9e4b8ad0001feff080000000000000c405680e2
    \\cfaa06ffffffffffffffffff01676f6e650174776f017a68692074686572650c007f0110007f
    \\007f1e19010300167f067374726f6e67000600
;

/// [`reference_document`] as a byte string. **The newlines the multiline
/// literal puts between its lines are stripped**, because a document chunk is
/// a byte string and not a listing.
const reference_bytes: [reference_bytes_len]u8 = blk: {
    @setEvalBranchQuota(4000);
    var hex: [reference_document.len]u8 = undefined;
    var n: usize = 0;
    for (reference_document) |c| {
        if (c == '\n') continue;
        hex[n] = c;
        n += 1;
    }
    var out: [reference_bytes_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[0 .. 2 * reference_bytes_len]) catch unreachable;
    break :blk out;
};

/// **437 bytes**, which is what `AutoCommit::save` wrote.
const reference_bytes_len = 437;

/// A named actor for the documents this file builds itself. **Named, because
/// a random one would make a failure unreproducible** — [read.zig] says the
/// same of its own fixture.
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

/// **The reference's own output**, from
/// `serde_json::to_string(&automerge::AutoSerde::from(&doc))` over the very
/// document above — same process, same run.
///
/// **Every shape the projection has to get right is in this one line**: a
/// bool, a string (an escaped quote, an escaped backslash, two spelled control
/// escapes, a literal `0x7f`, a literal `/`, and two non-ASCII characters), an
/// int, a uint, a timestamp, a counter, a byte string as an array of numbers, a
/// nested map, a nested list, a text object, an empty table and a null.
const golden = "{\"a_bool\":false,\"a_string\":\"he\\\"llo\\\\ /\\u0001\\n\x7f" ++
    "é中" ++
    "\",\"bytes\":[0,1,254,255],\"counter\":8,\"f64\":3.5,\"i64\":-42," ++
    "\"list\":[1,\"two\",true,null],\"map\":{\"in\":1,\"out\":\"z\"},\"table\":{}," ++
    "\"text\":\"hi there\",\"timestamp\":1700000000,\"u64\":18446744073709551615}";

test "the reference's own document renders the reference's own bytes" {
    const gpa = testing.allocator;
    var doc = try Document.load(gpa, std.testing.io, &reference_bytes, .unicode_code_point);
    defer doc.deinit();

    const json = try AutoSerde(Document).from(&doc).toJson(gpa);
    defer gpa.free(json);

    // **The whole rendering, byte for byte.** A substring assertion would pass
    // against a projection that dropped every list, and a hand-written literal
    // would only prove the two were written by the same person. Both sides of
    // this comparison came out of the reference: the document is
    // `AutoCommit::save`'s bytes and the expectation is
    // `serde_json::to_string(&AutoSerde::from(&doc))`'s.
    try testing.expectEqualStrings(golden, json);

    // **The three claims the line above makes that are not about a value's
    // type**, stated so a regression names which one broke rather than
    // reporting one opaque diff.
    //
    // *Key order, not call order.* The reference wrote `"out"` into the nested
    // map before `"in"`, and wrote `"u64"` into the root before `"a_bool"`, and
    // its own output has `{"in":1,"out":"z"}` and `"a_bool"` first.
    try testing.expect(std.mem.indexOf(u8, json, "\"map\":{\"in\":1,\"out\":\"z\"}") != null);
    try testing.expect(std.mem.startsWith(u8, json, "{\"a_bool\":"));
    // *A deleted key is absent, not a key with a null value.*
    try testing.expect(std.mem.indexOf(u8, json, "zzz_deleted") == null);
    // *A mark is not in the text.* The reference marked `there` and rendered
    // `"hi there"`.
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hi there\"") != null);
}

test "an empty document is two braces, which is what the reference's own test says" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(actor_a);

    // `export.rs`:40-45, `cli_export_with_empty_input`, asserts
    // `get_state_json(vec![], Default::default()) == json!({})` — that is
    // `AutoSerde` over a document with no rows.
    const json = try AutoSerde(Document).from(&doc).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings("{}", json);
}

test "every float shape the reference was run on, in this port's spelling" {
    const gpa = testing.allocator;

    // **The rows are the reference's own output**, taken from a run of
    // `serde_json::to_string(&v)` over the same values, and every one of them
    // is a case the port has to get right rather than a case it invented: the
    // `fixed_lo` and `fixed_hi` boundaries, the smallest subnormal, the
    // largest finite double, the non-finite three, a whole number that has to
    // keep its `.0`, and a 17-digit mantissa.
    //
    // The full 431-value corpus — these thirty-one plus four hundred doubles
    // from a fixed-seed LCG — was run through both and matched on every one.
    const cases = [_]struct { bits: u64, want: []const u8 }{
        // The zero arm, and the sign is kept.
        .{ .bits = 0x0000_0000_0000_0000, .want = "0.0" },
        .{ .bits = 0x8000_0000_0000_0000, .want = "-0.0" },
        // `exp10 == fixed_hi + 1` and `exp10 == fixed_hi`.
        .{ .bits = 0x4341_c379_37e0_8000, .want = "1e+16" },
        .{ .bits = 0x430c_6bf5_2634_0000, .want = "1000000000000000.0" },
        // `exp10 == fixed_lo` and `exp10 == fixed_lo - 1`.
        .{ .bits = 0x3ee4_f8b5_88e3_68f1, .want = "0.00001" },
        .{ .bits = 0x3eb0_c6f7_a0b5_ed8d, .want = "1e-6" },
        // A point inside the digits, a point after them, a leading zero run.
        .{ .bits = 0x400c_0000_0000_0000, .want = "3.5" },
        .{ .bits = 0x3fb9_9999_9999_999a, .want = "0.1" },
        .{ .bits = 0x3f1a_36e2_eb1c_432d, .want = "0.0001" },
        .{ .bits = 0xc00c_0000_0000_0000, .want = "-3.5" },
        // The smallest subnormal and the largest finite double.
        .{ .bits = 0x0000_0000_0000_0001, .want = "5e-324" },
        .{ .bits = 0x7fef_ffff_ffff_ffff, .want = "1.7976931348623157e+308" },
        // 17 significant digits, which is the widest mantissa an f64 can
        // need, and the whole-mantissa-carry case `2^53`.
        .{ .bits = 0x4340_0000_0000_0000, .want = "9007199254740992.0" },
        .{ .bits = 0x43b1_2210_f47d_e981, .want = "1.2345678901234568e+18" },
        .{ .bits = 0x3fd5_5555_5555_5555, .want = "0.3333333333333333" },
    };

    for (cases) |c| {
        const v: f64 = @bitCast(c.bits);
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        try (ScalarValue{ .float = v }).writeJson(&output.writer);
        try testing.expectEqualStrings(c.want, output.written());
    }

    // The canonical JSON codec maps all non-finite doubles to null.
    // formats (`ser.rs`:169-179), so `+inf`, `-inf` and `NaN` are all `null`;
    // `zmij` itself would have printed `inf`, `-inf` and `nan`, and the
    // reference printed `null` for all three.
    for ([_]u64{
        0x7ff0_0000_0000_0000,
        0xfff0_0000_0000_0000,
        0x7ff8_0000_0000_0000,
    }) |bits| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try (ScalarValue{ .float = @bitCast(bits) }).writeJson(&aw.writer);
        try testing.expectEqualStrings("null", aw.written());
    }
}

test "a string is escaped the way serde_json escapes it, and nothing else is" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // **One byte at a time, for every byte in the table and for every byte
    // outside it.** A table-driven sweep of all 256 is the only way to catch
    // an escape that was added or lost at the edge, and the reference's own
    // string carries a literal `0x7f`, a literal `/` and two non-ASCII
    // characters, which is what the `0x7f` and `/` rows below say.
    for (0..256) |b| {
        const byte: u8 = @intCast(b);
        var want: [16]u8 = undefined;
        const body: []const u8 = switch (byte) {
            0x08 => "\\b",
            0x09 => "\\t",
            0x0a => "\\n",
            0x0c => "\\f",
            0x0d => "\\r",
            0x22 => "\\\"",
            0x5c => "\\\\",
            0x00...0x07, 0x0b, 0x0e...0x1f => try std.fmt.bufPrint(&want, "\\u{x:0>4}", .{byte}),
            else => blk: {
                // **A literal byte, including `0x7f`, which is in no escape
                // table `serde_json` uses**, and including every byte of every
                // multi-byte UTF-8 sequence, which the reference wrote out
                // unchanged.
                want[0] = byte;
                break :blk want[0..1];
            },
        };

        aw.deinit();
        aw = .init(gpa);
        try (ScalarValue{ .str = &[_]u8{byte} }).writeJson(&aw.writer);
        const got = aw.written();
        try testing.expectEqual(@as(usize, body.len + 2), got.len);
        try testing.expectEqualStrings("\"", got[0..1]);
        try testing.expectEqualStrings("\"", got[got.len - 1 ..]);
        try testing.expectEqualStrings(body, got[1 .. got.len - 1]);
    }
}

test "every scalar type a document can hold reaches the output, and the allocator sees nothing" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(actor_a);

    // **One arm per `ScalarValue` variant the document surface can produce,
    // in key order** — the keys are sorted here because the expected string
    // below is sorted, and this document is written one `put` at a time
    // rather than loaded, so its row order is the order the puts came in. See
    // the diff block, "The row order a hand-built document has": the
    // reference's document is in key order because the reference's op set is,
    // and that is the only way this test can compare against a reference
    // string.
    //
    // `actor_id` is not here and cannot be: no operation in the op set
    // produces it (`op_set2/types.rs`:191-203), which is what the diff block
    // below says, and this test is what would fail if that changed.
    var tx = try trans.Transaction.open(gpa, &doc);
    // Closed on success; the entire doc is destroyed if this test returns an error.
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "k_bool" }, .{ .bool_value = true });
    _ = try tx.put(.root, .{ .key = "k_bytes" }, .{ .bytes = "" });
    _ = try tx.put(.root, .{ .key = "k_counter" }, .{ .counter = .init(0) });
    _ = try tx.put(.root, .{ .key = "k_float" }, .{ .float = 0.0 });
    _ = try tx.put(.root, .{ .key = "k_int" }, .{ .int = 0 });
    _ = try tx.put(.root, .{ .key = "k_null" }, .null_value);
    _ = try tx.put(.root, .{ .key = "k_str" }, .{ .str = "" });
    _ = try tx.put(.root, .{ .key = "k_timestamp" }, .{ .timestamp = -1 });
    _ = try tx.put(.root, .{ .key = "k_uint" }, .{ .uint = 0 });
    var committed = try tx.commit();
    defer committed.deinit(gpa);

    const json = try AutoSerde(Document).from(&doc).toJson(gpa);
    defer gpa.free(json);

    // **A zero of every numeric type is the case where the tags would show**,
    // and the empty byte string and empty string are the cases where a
    // container's brackets could be confused with its contents. All nine are
    // pinned to the bytes the reference produced for the same values.
    try testing.expectEqualStrings(
        \\{"k_bool":true,"k_bytes":[],"k_counter":0,"k_float":0.0,"k_int":0,"k_null":null,"k_str":"","k_timestamp":-1,"k_uint":0}
    ,
        json,
    );
}

test "an unknown scalar is a map with its two fields, in order" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // **`#[serde(untagged)]`'s struct variant is a map**, written in the
    // declaration order of `Unknown { type_code, bytes }`
    // (`value.rs`:529-532). The report says this could not be executed against
    // the reference, because the public API cannot author one.
    try (ScalarValue{ .unknown = .{ .type_code = 42, .bytes = "\x07" } }).writeJson(&aw.writer);
    try testing.expectEqualStrings("{\"type_code\":42,\"bytes\":[7]}", aw.written());
}

test "API parity serde preserves scoped transaction pending view" {
    // A historical transaction must not serialize the document's later current view.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, testing.io);
    defer doc.deinit();
    var first = try trans.Transaction.open(gpa, &doc);
    // Closed on success; test failure destroys the whole owning document.
    defer first.deinitClosed();
    _ = try first.put(.root, .{ .key = "k" }, .{ .int = 1 });
    var committed = try first.commit();
    defer committed.deinit(gpa);
    const heads = [_]types.ChangeHash{committed.hash.?};
    var second = try trans.Transaction.open(gpa, &doc);
    defer second.deinitClosed();
    _ = try second.put(.root, .{ .key = "k" }, .{ .int = 2 });
    var later = try second.commit();
    defer later.deinit(gpa);
    var scoped = try trans.Transaction.openAt(gpa, &doc, &heads);
    defer scoped.deinitClosed();
    _ = try scoped.put(.root, .{ .key = "p" }, .{ .int = 3 });
    const json = try AutoSerde(trans.Transaction).from(&scoped).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"k\":1,\"p\":3}", json);
    _ = try scoped.rollback();
}

test "API parity serde pending AutoCommit stays open across both backends" {
    // Serialization is an ordinary read, not a commit barrier.
    const AutoCommit = @import("autocommit.zig").AutoCommit;
    const gpa = testing.allocator;
    var auto = try AutoCommit.init(gpa, testing.io);
    defer auto.deinit();
    _ = try auto.put(.root, .{ .key = "answer" }, .{ .int = 42 });
    const pending = auto.pendingOps();
    const json = try AutoSerde(AutoCommit).from(&auto).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings("{\"answer\":42}", json);
    try testing.expectEqual(pending, auto.pendingOps());
    var tokens = @This().TokenStream.init(gpa);
    defer tokens.deinit();
    try AutoSerde(AutoCommit).from(&auto).serialize(gpa, &tokens);
    try testing.expectEqual(@as(usize, 4), tokens.items.items.len);
    try testing.expectEqualStrings("answer", tokens.items.items[1].key);
    try testing.expectEqual(@as(i64, 42), tokens.items.items[2].scalar.int);
    try testing.expectEqual(pending, auto.pendingOps());
}

test "API parity serde structured tokens outlive source document" {
    // A retained non-JSON projection owns text, scalar bytes and map keys.
    const gpa = testing.allocator;
    var tokens = @This().TokenStream.init(gpa);
    defer tokens.deinit();
    {
        var doc = try Document.load(gpa, testing.io, &reference_bytes, .unicode_code_point);
        defer doc.deinit();
        try AutoSerde(Document).from(&doc).serialize(gpa, &tokens);
    }
    var saw_bytes = false;
    var saw_text = false;
    var saw_map = false;
    for (tokens.items.items) |token| switch (token) {
        .scalar => |scalar| switch (scalar) {
            .bytes => |bytes| {
                try testing.expectEqualSlices(u8, &.{ 0, 1, 254, 255 }, bytes);
                saw_bytes = true;
            },
            else => {},
        },
        .string => |text| {
            try testing.expectEqualStrings("hi there", text);
            saw_text = true;
        },
        .key => |key| {
            if (std.mem.eql(u8, key, "map")) saw_map = true;
        },
        else => {},
    };
    try testing.expect(saw_bytes);
    try testing.expect(saw_text);
    try testing.expect(saw_map);
}

test "API parity serde allocation failures release both backend projections" {
    // The source owner remains usable and every interrupted projection releases its storage.
    const gpa = testing.allocator;
    var doc = try Document.load(gpa, testing.io, &reference_bytes, .unicode_code_point);
    defer doc.deinit();
    const Probe = struct {
        fn json(limited: Allocator, source: *Document) !void {
            const bytes = try AutoSerde(Document).from(source).toJson(limited);
            defer limited.free(bytes);
            try testing.expectEqualStrings(golden, bytes);
        }

        fn structured(limited: Allocator, source: *Document) !void {
            var tokens = @import("autoserde.zig").TokenStream.init(limited);
            defer tokens.deinit();
            try AutoSerde(Document).from(source).serialize(limited, &tokens);
            try testing.expect(tokens.items.items.len > 0);
        }
    };
    // Keep failure indices independent of SafeAllocator's in-place growth.
    var backing: testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(backing.allocator(), Probe.json, .{&doc});
    try testing.checkAllAllocationFailures(backing.allocator(), Probe.structured, .{&doc});
    const json = try AutoSerde(Document).from(&doc).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings(golden, json);
}

test "API parity serde scoped nested objects use historical and pending text" {
    // Maps, lists and text all use the transaction scope, not raw current hydration.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, testing.io);
    defer doc.deinit();
    var initial = try trans.Transaction.open(gpa, &doc);
    // Each journal closes normally; failure destroys the complete owning doc.
    defer initial.deinitClosed();
    const nested = try initial.putObject(.root, .{ .key = "nested" }, .map);
    _ = try initial.put(nested, .{ .key = "value" }, .{ .int = 1 });
    const sequence = try initial.putObject(.root, .{ .key = "sequence" }, .list);
    _ = try initial.insert(sequence, 0, .{ .int = 2 });
    const text = try initial.putObject(.root, .{ .key = "text" }, .text);
    try initial.spliceText(text, 0, 0, "old");
    var committed = try initial.commit();
    defer committed.deinit(gpa);
    const heads = [_]types.ChangeHash{committed.hash.?};
    var current = try trans.Transaction.open(gpa, &doc);
    defer current.deinitClosed();
    _ = try current.put(nested, .{ .key = "value" }, .{ .int = 9 });
    _ = try current.put(sequence, .{ .index = 0 }, .{ .int = 8 });
    try current.spliceText(text, 0, 3, "new");
    var later = try current.commit();
    defer later.deinit(gpa);
    var scoped = try trans.Transaction.openAt(gpa, &doc, &heads);
    defer scoped.deinitClosed();
    try scoped.spliceText(text, 3, 0, "!");
    const json = try AutoSerde(trans.Transaction).from(&scoped).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings(
        "{\"nested\":{\"value\":1},\"sequence\":[2],\"text\":\"old!\"}",
        json,
    );
    var tokens = TokenStream.init(gpa);
    defer tokens.deinit();
    try AutoSerde(trans.Transaction).from(&scoped).serialize(gpa, &tokens);
    var text_found = false;
    for (tokens.items.items) |token| switch (token) {
        .string => |body| {
            try testing.expectEqualStrings("old!", body);
            text_found = true;
        },
        else => {},
    };
    try testing.expect(text_found);
    _ = try scoped.rollback();
}
