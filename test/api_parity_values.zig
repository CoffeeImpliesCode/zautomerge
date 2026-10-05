const std = @import("std");
const am = @import("zautomerge");
const common = @import("api_parity_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
const actor_a = am.ActorId.init(&([_]u8{0xa1} ** 15));
const actor_b = am.ActorId.init(&([_]u8{0xb2} ** 16));

// Every assertion is against a reference observation, not a native self-roundtrip.
// The scripts are tools/oracle/src/api_parity.rs:546-674. Rust Debug and the
// compressed wrapper's DEFLATE representation are deliberately not equality keys.
pub fn verify(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    var fixture = try makeFixture(gpa, io);
    defer fixture.deinit();
    var all = try makeExpanded(gpa, &fixture);
    defer all.deinit(gpa);
    var authored = try makeAuthored(gpa, io);
    defer authored.deinit(gpa);
    var empty = authored;
    empty.ops = &.{};
    empty.seq = 2;
    empty.start_op = 17;
    empty.extra_bytes = &.{};
    empty.author = null;
    empty.hash = null;

    var variants = [_]bool{false} ** 22;
    var scalars = [_]bool{false} ** 12;
    var exids = [_]bool{false} ** 4;
    var invalid_exids = [_]bool{false} ** 7;
    var footers = [_]bool{false} ** 5;
    var authors = [_]bool{false} ** 2;
    var hex_inputs = [_]bool{false} ** 4;
    var object_types = [_]bool{false} ** 4;
    var imports = [_]bool{false} ** 5;
    var singletons = [_]bool{false} ** 6;
    for (records, 0..) |record, index| {
        const name = record.scenario;
        errdefer std.debug.print("API parity values scenario: {s}\n", .{name});
        const data = record.data;
        if (std.mem.eql(u8, name, "expanded-all-variants")) {
            try once(&singletons, 0);
            try verifyAll(gpa, data, all);
        } else if (std.mem.startsWith(u8, name, "expanded-variant-")) {
            const variant = try suffixIndex(name, "expanded-variant-", variants.len);
            try once(&variants, variant);
            var single = all;
            single.ops = all.ops[variant .. variant + 1];
            single.hash = null;
            try verifyExpanded(gpa, data, single, "hex");
        } else if (std.mem.eql(u8, name, "expanded-author-opaque-footer")) {
            try once(&singletons, 1);
            try verifyExpanded(gpa, data, authored, "raw_hex");
            try expectAuthor(gpa, try common.field(data, "author"), authored.author);
            try expectHex(gpa, try common.field(data, "extra_hex"), authored.extra_bytes);
        } else if (std.mem.eql(u8, name, "expanded-empty")) {
            try once(&singletons, 2);
            try verifyExpanded(gpa, data, empty, "hex");
            var built = try empty.encode(gpa);
            defer built.deinit(gpa);
            try equal(try common.integer(usize, try common.field(data, "len")), try built.change.len(gpa));
            try equal(try common.integer(u64, try common.field(data, "max_op")), built.change.max_op);
            try expectAuthor(gpa, try common.field(data, "author"), try built.change.author(gpa));
        } else if (std.mem.eql(u8, name, "change-author-footer-total")) {
            const footer_hex = try common.string(try common.field(data, "extra_hex"));
            const footer_index = try member(footer_hex, &.{ "", "0200", "01", "0103ff", "80" });
            try once(&footers, footer_index);
            const footer = try common.unhex(gpa, footer_hex);
            defer gpa.free(footer);
            var input = empty;
            input.extra_bytes = footer;
            var built = try input.encode(gpa);
            defer built.deinit(gpa);
            try expectChange(gpa, data, built.change, "hex");
            try expectAuthor(gpa, try common.field(data, "author"), try built.change.author(gpa));
            try expectHex(gpa, try common.field(data, "extra_hex"), try built.change.extraBytes(gpa));
        } else if (std.mem.startsWith(u8, name, "scalar-")) {
            const scalar_index = try suffixIndex(name, "scalar-", scalars.len);
            try once(&scalars, scalar_index);
            try verifyScalar(gpa, data, scalarCases()[scalar_index]);
        } else if (std.mem.startsWith(u8, name, "exid-") and
            !std.mem.eql(u8, name, "exid-invalid"))
        {
            const id_index = try suffixIndex(name, "exid-", exids.len);
            try once(&exids, id_index);
            const id: am.ExId = switch (id_index) {
                0 => .root,
                1 => namedId(1, 7),
                2 => namedId(std.math.maxInt(u64), 7),
                3 => namedId(0, 0),
                else => unreachable,
            };
            try verifyExId(gpa, data, id, true);
        } else if (std.mem.eql(u8, name, "exid-invalid")) {
            const hex = try common.string(try common.field(data, "hex"));
            const invalid_index = try member(hex, &.{ "", "01", "20", "1080", "100300", "100080", "10000080" });
            try once(&invalid_exids, invalid_index);
            try verifyInvalidExId(gpa, data, invalid_index);
        } else if (std.mem.eql(u8, name, "author-codec")) {
            const hex = try common.string(try common.field(data, "hex"));
            const author_index = try member(hex, &.{ "", "00ff80" });
            try once(&authors, author_index);
            const bytes: []const u8 = if (author_index == 0) "" else "\x00\xff\x80";
            const author = am.Author.init(bytes);
            try expectByteArray(try common.field(data, "bytes"), author.asBytes());
            const encoded = try author.toHex(gpa);
            defer gpa.free(encoded);
            try strings(hex, encoded);
            try expectSerialized(gpa, try common.field(data, "json"), author);
            var decoded = try am.Author.fromHex(gpa, encoded);
            defer decoded.deinitOwned(gpa);
            try equal(try common.boolean(try common.field(data, "roundtrip")), author.eql(decoded));
        } else if (std.mem.eql(u8, name, "actor-hash-codec")) {
            try once(&singletons, 3);
            try verifyActorHash(gpa, data);
        } else if (std.mem.eql(u8, name, "hex-codec-input")) {
            const input = try common.string(try common.field(data, "input"));
            const input_index = try member(input, &.{ "", "0", "gg", "00FF80" });
            try once(&hex_inputs, input_index);
            try verifyHexInput(gpa, data, input_index);
        } else if (std.mem.eql(u8, name, "value-object")) {
            const kind = try common.string(try common.field(data, "kind"));
            const kind_index = try member(kind, &.{ "map", "list", "text", "table" });
            try once(&object_types, kind_index);
            const native_kind = [_]am.ObjType{ .map, .list, .text, .table };
            const object = am.value.Value{ .object = native_kind[kind_index] };
            try equal(try common.boolean(try common.field(data, "object")), object.isObject());
            try equal(try common.boolean(try common.field(data, "scalar")), object.isScalar());
            try strings(try common.string(try common.field(data, "to_objtype")), @tagName(object.asObject().?));
        } else if (std.mem.eql(u8, name, "object-import")) {
            try once(&singletons, 4);
            try verifyImport(gpa, data, &fixture);
        } else if (std.mem.eql(u8, name, "object-import-invalid")) {
            const input = try common.string(try common.field(data, "input"));
            const import_index = try member(input, &.{ "missing", "-1@a1", "1@", "1@ff", "1@xyz" });
            try once(&imports, import_index);
            try verifyInvalidImport(gpa, data, &fixture, import_index);
        } else if (std.mem.eql(u8, name, "init-from-hydrate")) {
            try once(&singletons, 5);
            try verifyInit(gpa, io, data, &fixture);
        } else {
            continue;
        }
        try expectRecordFields(name, data);
        try common.mark(seen, index);
    }
    inline for (.{ variants, scalars, exids, invalid_exids, footers, authors, hex_inputs, object_types, imports, singletons }) |required| {
        for (required) |found| try expect(found);
    }
}

fn once(set: []bool, index: usize) !void {
    try expect(index < set.len);
    try expect(!set[index]);
    set[index] = true;
}

fn suffixIndex(name: []const u8, prefix: []const u8, count: usize) !usize {
    const suffix = name[prefix.len..];
    const index = try std.fmt.parseInt(usize, suffix, 10);
    try expect(index < count);
    var buffer: [24]u8 = undefined;
    try strings(suffix, try std.fmt.bufPrint(&buffer, "{d}", .{index}));
    return index;
}

fn member(value: []const u8, choices: []const []const u8) !usize {
    for (choices, 0..) |choice, index| {
        if (std.mem.eql(u8, choice, value)) return index;
    }
    return error.UnexpectedParityInput;
}

fn expectRecordFields(name: []const u8, data: Value) !void {
    const fields: []const []const u8 = if (std.mem.eql(u8, name, "expanded-all-variants"))
        &.{ "input", "decoded", "raw_hex", "wire_hex", "hash", "rebuilt_hash", "json_roundtrip", "len", "start_op", "max_op", "actors", "other_actors", "author" }
    else if (std.mem.startsWith(u8, name, "expanded-variant-"))
        &.{ "json", "hash", "hex", "json_roundtrip" }
    else if (std.mem.eql(u8, name, "expanded-author-opaque-footer"))
        &.{ "json", "hash", "author", "extra_hex", "raw_hex" }
    else if (std.mem.eql(u8, name, "expanded-empty"))
        &.{ "json", "hash", "len", "max_op", "author", "hex" }
    else if (std.mem.eql(u8, name, "change-author-footer-total"))
        &.{ "extra_hex", "author", "hash", "hex" }
    else if (std.mem.startsWith(u8, name, "scalar-"))
        &.{ "datatype", "json", "display", "i64", "u64", "f64", "hydrate_i64", "scalar_debug" }
    else if (std.mem.eql(u8, name, "exid-invalid"))
        &.{ "hex", "result" }
    else if (std.mem.startsWith(u8, name, "exid-"))
        &.{ "display", "json", "hex", "bytes", "parsed", "equal", "trailing" }
    else if (std.mem.eql(u8, name, "author-codec"))
        &.{ "bytes", "hex", "json", "roundtrip" }
    else if (std.mem.eql(u8, name, "actor-hash-codec"))
        &.{ "actor", "actor_hex", "actor_bytes", "hash", "hash_display", "hash_parse", "wide32", "counter_overflow" }
    else if (std.mem.eql(u8, name, "hex-codec-input"))
        &.{ "input", "author", "actor", "hash" }
    else if (std.mem.eql(u8, name, "value-object"))
        &.{ "kind", "value_debug", "object", "scalar", "to_objtype" }
    else if (std.mem.eql(u8, name, "object-import"))
        &.{ "id", "import", "import_obj", "root" }
    else if (std.mem.eql(u8, name, "object-import-invalid"))
        &.{ "input", "observation" }
    else if (std.mem.eql(u8, name, "init-from-hydrate"))
        &.{ "state", "change_count" }
    else
        return error.UnexpectedParityScenario;
    try expectFields(data, fields);
}

fn expectFields(data: Value, fields: []const []const u8) !void {
    try expect(data == .object);
    try equal(fields.len, data.object.count());
    for (fields) |field| _ = try common.field(data, field);
}

fn expectSerialized(gpa: Allocator, expected: Value, actual: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, actual, .{});
    defer gpa.free(json);
    try common.expectJsonText(gpa, expected, json);
}

fn expectHex(gpa: Allocator, expected: Value, actual: []const u8) !void {
    const bytes = try common.unhex(gpa, try common.string(expected));
    defer gpa.free(bytes);
    try std.testing.expectEqualSlices(u8, bytes, actual);
}

fn expectByteArray(expected: Value, actual: []const u8) !void {
    const values = try common.array(expected);
    try equal(values.len, actual.len);
    for (values, actual) |value, byte| try equal(try common.integer(u8, value), byte);
}

fn expectAuthor(gpa: Allocator, expected: Value, actual: ?[]const u8) !void {
    if (actual) |bytes| {
        try expectSerialized(gpa, expected, am.Author.init(bytes));
    } else {
        try expect(expected == .null);
    }
}

fn scalarCases() [12]am.value.ScalarValue {
    return .{ .null_value, .{ .bool_value = true }, .{ .int = -7 }, .{ .uint = std.math.maxInt(i64) }, .{ .uint = @as(u64, 1) << 63 }, .{ .uint = std.math.maxInt(u64) }, .{ .float = 1.25 }, .{ .str = "é" }, .{ .bytes = "\x00\xff\x80" }, .{ .counter = .init(5) }, .{ .timestamp = -123 }, .{ .unknown = .{ .type_code = 15, .bytes = "\x00\xff" } } };
}

fn makeFixture(gpa: Allocator, io: std.Io) !am.doc.Document {
    var doc = try am.doc.Document.init(gpa, io);
    errdefer doc.deinit();
    doc.setActorId(actor_a);
    var tx = try am.Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("parity transaction rollback refused");
    const map = try tx.putObject(.root, .{ .key = "map" }, .map);
    _ = try tx.put(map, .{ .key = "k" }, .{ .int = 7 });
    const list = try tx.putObject(.root, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .bool_value = true });
    _ = try tx.insert(list, 1, .{ .str = "two" });
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "a😀b");
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    return doc;
}

fn makeExpanded(gpa: Allocator, fixture: *am.doc.Document) !am.ExpandedChange {
    const heads = try fixture.getHeads(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    defer gpa.free(heads);
    var operations: [22]am.ExpandedOp = undefined;
    const scalars = scalarCases();
    const pred = [_]am.ExpandedOpId{
        .{ .counter = 1, .actor = actor_a }, .{ .counter = 2, .actor = actor_b },
    };
    for (&operations, 0..) |*operation, index| {
        operation.* = .{
            .action = switch (index) {
                0 => .{ .make = .map },
                1 => .{ .make = .list },
                2 => .{ .make = .text },
                3 => .{ .make = .table },
                4 => .delete,
                5 => .{ .increment = -3 },
                6...17 => .{ .put = scalars[index - 6] },
                18, 20 => .{ .mark_begin = .{
                    .name = "bold",
                    .value = .{ .bool_value = true },
                    .expand = index == 20,
                } },
                19, 21 => .{ .mark_end = .{ .expand = index == 21 } },
                else => unreachable,
            },
            .obj = if (index % 2 == 0) .root else .{ .id = .{ .counter = 1, .actor = actor_a } },
            .key = switch (index % 3) {
                0 => .{ .map = try std.fmt.allocPrint(arena.allocator(), "k{d}", .{index}) },
                1 => .{ .seq = .head },
                2 => .{ .seq = .{ .id = .{ .counter = 2, .actor = actor_b } } },
                else => unreachable,
            },
            .pred = &pred,
            .insert = index % 2 != 0,
        };
    }
    const input = am.ExpandedChange{
        .ops = &operations,
        .actor = actor_a,
        .seq = 1,
        .start_op = 17,
        .time = 0,
        .message = "all-variants",
        .deps = heads,
        .extra_bytes = "\x00\xff\x80",
    };
    return input.dup(gpa);
}

fn makeAuthored(gpa: Allocator, io: std.Io) !am.ExpandedChange {
    var doc = try am.doc.Document.init(gpa, io);
    defer doc.deinit();
    // Rust api_parity.rs:792 sets the author before overriding its fresh actor.
    // setAuthor intentionally mints a new actor (automerge.rs:389-394).
    try doc.setAuthor(gpa, "\xff\x00\x80");
    doc.setActorId(actor_a);
    var tx = try am.Transaction.open(gpa, &doc);
    defer tx.deinit() catch @panic("parity transaction rollback refused");
    _ = try tx.put(.root, .{ .key = "authored" }, .{ .bool_value = true });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    var change = (try doc.getChangeByHash(gpa, committed.hash.?)) orelse
        return error.MissingChange;
    defer change.deinit(gpa);
    var decoded = try change.change.decode(gpa);
    defer decoded.deinit(gpa);
    const extra = try std.mem.concat(gpa, u8, &.{ decoded.extra_bytes, "\x00\xff\x80B" });
    defer gpa.free(extra);
    decoded.extra_bytes = extra;
    return decoded.dup(gpa);
}

fn expectChange(gpa: Allocator, data: Value, change: am.change_record.Change, hex_field: []const u8) !void {
    try expectSerialized(gpa, try common.field(data, "hash"), change.hash);
    const raw = try change.rawBytes(gpa);
    defer gpa.free(raw);
    try expectHex(gpa, try common.field(data, hex_field), raw);
    const reference = try common.unhex(gpa, try common.string(try common.field(data, hex_field)));
    defer gpa.free(reference);
    var parsed = try am.change_record.Change.fromBytes(gpa, reference);
    defer parsed.deinit(gpa);
    try expectSerialized(gpa, try common.field(data, "hash"), parsed.change.hash);
}

fn verifyAll(gpa: Allocator, data: Value, input: am.ExpandedChange) !void {
    try expectSerialized(gpa, try common.field(data, "input"), input);
    var built = try input.encode(gpa);
    defer built.deinit(gpa);
    try expectChange(gpa, data, built.change, "raw_hex");
    var decoded = try built.change.decode(gpa);
    defer decoded.deinit(gpa);
    try expectSerialized(gpa, try common.field(data, "decoded"), decoded);
    var copied = try decoded.dup(gpa);
    defer copied.deinit(gpa);
    var rebuilt = try copied.encode(gpa);
    defer rebuilt.deinit(gpa);
    try expectSerialized(gpa, try common.field(data, "rebuilt_hash"), rebuilt.change.hash);
    try verifySerde(gpa, try common.field(data, "json_roundtrip"), decoded);
    try equal(try common.integer(usize, try common.field(data, "len")), try built.change.len(gpa));
    try equal(try common.integer(u64, try common.field(data, "start_op")), built.change.start_op);
    try equal(try common.integer(u64, try common.field(data, "max_op")), built.change.max_op);
    const actors = try built.change.actorsOwned(gpa);
    defer {
        for (actors) |actor| gpa.free(actor.bytes);
        gpa.free(actors);
    }
    try expectSerialized(gpa, try common.field(data, "actors"), actors);
    try expectSerialized(gpa, try common.field(data, "other_actors"), built.change.other_actors);
    try expectAuthor(gpa, try common.field(data, "author"), try built.change.author(gpa));
    const wire = try common.unhex(gpa, try common.string(try common.field(data, "wire_hex")));
    defer gpa.free(wire);
    var loaded = try am.change_record.Change.fromBytes(gpa, wire);
    defer loaded.deinit(gpa);
    try expectChange(gpa, data, loaded.change, "raw_hex");
    var wire_decoded = try loaded.change.decode(gpa);
    defer wire_decoded.deinit(gpa);
    try expectSerialized(gpa, try common.field(data, "decoded"), wire_decoded);
}

fn verifyExpanded(gpa: Allocator, data: Value, input: am.ExpandedChange, hex_field: []const u8) !void {
    var detached = blk: {
        var owned = inner: {
            var built = try input.encode(gpa);
            defer built.deinit(gpa);
            try expectChange(gpa, data, built.change, hex_field);
            break :inner try built.change.decode(gpa);
        };
        defer owned.deinit(gpa);
        // Source encoded storage is gone before reading decoded payloads.
        try expectSerialized(gpa, try common.field(data, "json"), owned);
        if (data.object.get("json_roundtrip")) |roundtrip|
            try verifySerde(gpa, roundtrip, owned);
        break :blk try owned.dup(gpa);
    };
    defer detached.deinit(gpa);
    // Both decode and its source have died; this copy must still encode exactly.
    var rebuilt = try detached.encode(gpa);
    defer rebuilt.deinit(gpa);
    try expectChange(gpa, data, rebuilt.change, hex_field);
}

fn verifySerde(gpa: Allocator, expected: Value, expanded: am.ExpandedChange) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, expanded, .{});
    defer gpa.free(json);
    if (std.json.parseFromSlice(am.ExpandedChange, gpa, json, .{})) |parsed| {
        defer parsed.deinit();
        try expectFields(expected, &.{ "outcome", "hash" });
        try strings("ok", try common.string(try common.field(expected, "outcome")));
        var built = try parsed.value.encode(gpa);
        defer built.deinit(gpa);
        try expectSerialized(gpa, try common.field(expected, "hash"), built.change.hash);
        // Serde's unknown-field rule must survive arbitrary nested data. This
        // extension changes no operation and therefore retains the oracle hash.
        const extended = try std.mem.concat(gpa, u8, &.{
            json[0 .. json.len - 1], ",\"foo\":{\"bytes\":[0,255],\"unknown\":null}}",
        });
        defer gpa.free(extended);
        var with_foo = try std.json.parseFromSlice(am.ExpandedChange, gpa, extended, .{});
        defer with_foo.deinit();
        var rebuilt = try with_foo.value.encode(gpa);
        defer rebuilt.deinit(gpa);
        try expectSerialized(gpa, try common.field(expected, "hash"), rebuilt.change.hash);
    } else |failure| {
        try expect(failure == error.UnexpectedToken);
        try expectErrorClass(expected, "InvalidScalarValue");
    }
}

fn verifyScalar(gpa: Allocator, data: Value, scalar: am.value.ScalarValue) !void {
    const datatype: []const u8 = switch (scalar) {
        .null_value => "null",
        .bool_value => "boolean",
        .int => "int",
        .uint => "uint",
        .float => "float64",
        .str => "str",
        .bytes => "bytes",
        .counter => "counter",
        .timestamp => "timestamp",
        .unknown => "unknown",
        .actor_id => return error.UnexpectedScalar,
    };
    try strings(try common.string(try common.field(data, "datatype")), datatype);
    try expectSerialized(gpa, try common.field(data, "json"), scalar);
    const display = try std.fmt.allocPrint(gpa, "{f}", .{scalar});
    defer gpa.free(display);
    try strings(try common.string(try common.field(data, "display")), display);
    try expectSerialized(gpa, try common.field(data, "i64"), scalar.asI64());
    try expectSerialized(gpa, try common.field(data, "u64"), scalar.asU64());
    try expectOptionalF64(gpa, try common.field(data, "f64"), scalar.asF64());
    try expectSerialized(gpa, try common.field(data, "hydrate_i64"), am.hydrate.Value.fromScalar(scalar).asI64());
    var owned = try scalar.intoOwned(gpa);
    defer owned.deinit(gpa);
    try expectSerialized(gpa, try common.field(data, "json"), owned.value);
}

fn expectOptionalF64(gpa: Allocator, expected: Value, actual: ?f64) !void {
    // This field is a float conversion, not an integer-valued JSON contract.
    // Different shortest decimal spellings must decode to the identical IEEE value.
    const expected_json = try std.json.Stringify.valueAlloc(gpa, expected, .{});
    defer gpa.free(expected_json);
    const reference = try std.json.parseFromSlice(?f64, gpa, expected_json, .{});
    defer reference.deinit();
    try expect((reference.value == null) == (actual == null));
    if (reference.value) |reference_float| {
        try equal(@as(u64, @bitCast(reference_float)), @as(u64, @bitCast(actual.?)));
    }

    const actual_json = try std.json.Stringify.valueAlloc(gpa, actual, .{});
    defer gpa.free(actual_json);
    const serialized = try std.json.parseFromSlice(?f64, gpa, actual_json, .{});
    defer serialized.deinit();
    try expect((reference.value == null) == (serialized.value == null));
    if (reference.value) |reference_float| {
        try equal(@as(u64, @bitCast(reference_float)), @as(u64, @bitCast(serialized.value.?)));
    }
}

fn namedId(counter: u64, hint: u32) am.ExId {
    return .{ .named = .{
        .op = .{ .counter = counter, .actor = hint },
        .actor = .init("\x00\xff\x80"),
    } };
}

fn verifyExId(gpa: Allocator, data: Value, id: am.ExId, trailing: bool) !void {
    if (!trailing) try expectFields(data, &.{ "id", "display", "bytes", "hex", "parsed", "equal" });
    const display = try id.toString(gpa);
    defer gpa.free(display);
    try strings(try common.string(try common.field(data, "display")), display);
    try expectSerialized(gpa, try common.field(data, if (trailing) "json" else "id"), id);
    const bytes = try id.toBytes(gpa);
    defer gpa.free(bytes);
    try expectHex(gpa, try common.field(data, "hex"), bytes);
    try expectByteArray(try common.field(data, "bytes"), bytes);
    var parsed = try am.ExId.fromBytes(gpa, bytes);
    defer parsed.deinitOwned(gpa);
    try expectSerialized(gpa, try common.field(data, "parsed"), parsed);
    try equal(try common.boolean(try common.field(data, "equal")), id.eql(parsed));
    if (trailing) {
        const extended = try std.mem.concat(gpa, u8, &.{ bytes, "\xff" });
        defer gpa.free(extended);
        var extended_id = try am.ExId.fromBytes(gpa, extended);
        defer extended_id.deinitOwned(gpa);
        const outcome = try common.field(data, "trailing");
        try expectFields(outcome, &.{ "outcome", "value" });
        try strings("ok", try common.string(try common.field(outcome, "outcome")));
        try expectSerialized(gpa, try common.field(outcome, "value"), extended_id);
    }
}

fn expectErrorClass(expected: Value, class: []const u8) !void {
    try expectFields(expected, &.{ "outcome", "class" });
    try strings("error", try common.string(try common.field(expected, "outcome")));
    try strings(class, try common.string(try common.field(expected, "class")));
}

fn verifyInvalidExId(gpa: Allocator, data: Value, index: usize) !void {
    const bytes = try common.unhex(gpa, try common.string(try common.field(data, "hex")));
    defer gpa.free(bytes);
    const classes = [_][]const u8{ "NoVersion", "InvalidVersion", "InvalidType", "ParseActorLen", "ParseActor", "ParseCounter", "ParseActorIdxHint" };
    try expectErrorClass(try common.field(data, "result"), classes[index]);
    const errors = [_]anyerror{ error.UnexpectedEnd, error.InvalidObjIdFormat, error.InvalidObjIdFormat, error.UnexpectedEnd, error.UnexpectedEnd, error.UnexpectedEnd, error.UnexpectedEnd };
    try std.testing.expectError(errors[index], am.ExId.fromBytes(gpa, bytes));
}

fn verifyActorHash(gpa: Allocator, data: Value) !void {
    const actor = am.ActorId.init("\x00\xff\x80");
    try expectSerialized(gpa, try common.field(data, "actor"), actor);
    try expectHex(gpa, try common.field(data, "actor_hex"), actor.bytes);
    try expectByteArray(try common.field(data, "actor_bytes"), actor.bytes);
    var hash: am.ChangeHash = undefined;
    for (&hash.bytes, 0..) |*byte, index| byte.* = @intCast(index);
    try expectSerialized(gpa, try common.field(data, "hash"), hash);
    const display = try std.fmt.allocPrint(gpa, "{f}", .{hash});
    defer gpa.free(display);
    try strings(try common.string(try common.field(data, "hash_display")), display);
    try expectSerialized(gpa, try common.field(data, "hash_parse"), try am.ChangeHash.parse(gpa, display));
    try verifyExId(gpa, try common.field(data, "wide32"), namedId(@as(u64, 1) << 32, 7), false);
    const overflow = try common.field(data, "counter_overflow");
    try expectFields(overflow, &.{ "bytes", "result" });
    const bytes = try namedId(std.math.maxInt(u64), 7).toBytes(gpa);
    defer gpa.free(bytes);
    bytes[bytes.len - 1] = 2;
    try expectByteArray(try common.field(overflow, "bytes"), bytes);
    try expectErrorClass(try common.field(overflow, "result"), "ParseActorIdxHint");
    try std.testing.expectError(error.Overflow, am.ExId.fromBytes(gpa, bytes));
}

fn verifyHexInput(gpa: Allocator, data: Value, index: usize) !void {
    const input = try common.string(try common.field(data, "input"));
    if (index == 0 or index == 3) {
        var author = try am.Author.fromHex(gpa, input);
        defer author.deinitOwned(gpa);
        const actor = try am.ActorId.fromHex(gpa, input);
        defer gpa.free(actor.bytes);
        try expectOkSerialized(gpa, try common.field(data, "author"), author);
        try expectOkSerialized(gpa, try common.field(data, "actor"), actor);
    } else {
        try std.testing.expectError(error.InvalidHex, am.Author.fromHex(gpa, input));
        try std.testing.expectError(error.InvalidActorId, am.ActorId.fromHex(gpa, input));
        try expectErrorClass(try common.field(data, "author"), "InvalidAuthor");
        try expectErrorClass(try common.field(data, "actor"), "InvalidActorId");
    }
    const hash_error: anyerror = if (index == 0 or index == 3)
        error.InvalidChangeHashBytes
    else
        error.InvalidHex;
    try std.testing.expectError(hash_error, am.ChangeHash.parse(gpa, input));
    try expectErrorClass(try common.field(data, "hash"), if (index == 0 or index == 3) "IncorrectLength" else "HexDecode");
}

fn expectOkSerialized(gpa: Allocator, expected: Value, actual: anytype) !void {
    try expectFields(expected, &.{ "outcome", "value" });
    try strings("ok", try common.string(try common.field(expected, "outcome")));
    try expectSerialized(gpa, try common.field(expected, "value"), actual);
}

fn verifyImport(gpa: Allocator, data: Value, doc: *am.doc.Document) !void {
    const item = (try am.read.get(doc, .root, .{ .key = "map" })).?;
    const id = try item.id.toString(gpa);
    defer gpa.free(id);
    try strings(try common.string(try common.field(data, "id")), id);
    const imported = try doc.import(gpa, id);
    try expectImported(gpa, try common.field(data, "import"), imported);
    try expectSerialized(gpa, try common.field(data, "import_obj"), try doc.importObj(gpa, id));
    try expectImported(gpa, try common.field(data, "root"), try doc.import(gpa, "_root"));
    // A resident scalar ID and a syntactically valid missing operation remain
    // distinguishable from successful object imports without unsafe narrowing.
    const scalar = (try am.read.get(doc, item.id, .{ .key = "k" })).?;
    const scalar_id = try scalar.id.toString(gpa);
    defer gpa.free(scalar_id);
    try std.testing.expectError(error.InvalidObjId, doc.import(gpa, scalar_id));
    const missing = "4294967296@a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    try std.testing.expectError(error.InvalidObjId, doc.import(gpa, missing));
    const unresolved = namedId(std.math.maxInt(u64), 7);
    try std.testing.expectError(error.NotAnObject, doc.objectType(unresolved));
}

fn expectImported(gpa: Allocator, expected: Value, actual: am.doc.ImportedObject) !void {
    try expectFields(expected, &.{ "id", "object_type" });
    try expectSerialized(gpa, try common.field(expected, "id"), actual.id);
    try strings(try common.string(try common.field(expected, "object_type")), @tagName(actual.object_type));
}

fn verifyInvalidImport(gpa: Allocator, data: Value, doc: *am.doc.Document, index: usize) !void {
    const input = try common.string(try common.field(data, "input"));
    const expected = try common.field(data, "observation");
    if (index == 4) {
        // Rust import_obj unwraps the odd actor hex; native total parsers refuse
        // exactly this input with InvalidObjIdFormat rather than reproducing panic.
        try expectFields(expected, &.{ "outcome", "panic_debug" });
        try strings("panic", try common.string(try common.field(expected, "outcome")));
        try std.testing.expectError(error.InvalidObjIdFormat, doc.import(gpa, input));
    } else {
        const class: []const u8 = if (index < 2) "InvalidObjIdFormat" else "InvalidObjId";
        try expectErrorClass(expected, class);
        const failure: anyerror = if (index < 2) error.InvalidObjIdFormat else error.InvalidObjId;
        try std.testing.expectError(failure, doc.import(gpa, input));
    }
}

fn verifyInit(gpa: Allocator, io: std.Io, data: Value, fixture: *am.doc.Document) !void {
    var hydrated = try am.read.hydrate(fixture, .root, null, gpa);
    defer hydrated.deinit();
    const map = hydrated.asMap() orelse return error.ExpectedHydratedMap;
    var initialized = try am.doc.Document.init(gpa, io);
    defer initialized.deinit();
    initialized.setActorId(actor_a);
    var outcome = try initialized.initFromHydrate(gpa, map);
    switch (outcome) {
        .success => |*success| {
            defer success.patch_log.deinit();
            try expect(success.hash != null);
        },
        .failure => |*failure| {
            failure.patch_log.deinit();
            if (failure.transaction) |*tx| {
                // The document is destroyed immediately after this failure, so
                // releasing the retained closed resources cannot abandon a live doc.
                tx.deinitClosed();
            }
            return failure.err;
        },
    }
    try common.expectSnapshot(gpa, io, try common.field(data, "state"), &initialized);
    var changes = try initialized.getChangesMeta(gpa, &.{});
    defer changes.deinit(gpa);
    try equal(try common.integer(usize, try common.field(data, "change_count")), changes.items.items.len);
}
