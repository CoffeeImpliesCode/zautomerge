//! Typed comparisons for the public API replay. The oracle owns the corpus;
//! these projections are built only from native public values and readers.
//! Source: tools/oracle/src/api_parity.rs.
const std = @import("std");
const am = @import("zautomerge");
const Allocator = std.mem.Allocator;
const Json = std.json.Value;

pub const Record = struct {
    kind: []const u8,
    scenario: []const u8,
    source: []const u8,
    data: Json,
};

/// Parsed envelopes and their strings belong to the supplied corpus arena.
pub fn parseRecords(arena: Allocator, text: []const u8) ![]const Record {
    var records: std.ArrayList(Record) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = try std.json.parseFromSliceLeaky(Record, arena, line, .{
            .allocate = .alloc_always,
            .parse_numbers = false,
        });
        if (!std.mem.eql(u8, record.kind, "api-parity")) return error.UnknownRecordKind;
        if (record.scenario.len == 0) return error.MissingScenario;
        if (record.source.len == 0) return error.MissingSourceCitation;
        try records.append(arena, record);
    }
    if (records.items.len == 0) return error.EmptyCorpus;
    return records.toOwnedSlice(arena);
}

pub fn mark(seen: []bool, index: usize) !void {
    if (index >= seen.len) return error.InvalidRecordIndex;
    if (seen[index]) return error.DuplicateRecordOwnership;
    seen[index] = true;
}

pub fn requireAllSeen(records: []const Record, seen: []const bool) !void {
    if (records.len != seen.len) return error.InvalidSeenLength;
    for (records, seen) |record, consumed| {
        if (!consumed) {
            std.debug.print("api-parity: unconsumed scenario {s}\n", .{record.scenario});
            return error.UnknownOrUnconsumedScenario;
        }
    }
}

pub fn field(value: Json, name: []const u8) !Json {
    if (value != .object) return error.ExpectedJsonObject;
    return value.object.get(name) orelse error.MissingJsonField;
}
pub fn string(value: Json) ![]const u8 {
    if (value != .string) return error.ExpectedJsonString;
    return value.string;
}
pub fn array(value: Json) ![]const Json {
    if (value != .array) return error.ExpectedJsonArray;
    return value.array.items;
}
pub fn boolean(value: Json) !bool {
    if (value != .bool) return error.ExpectedJsonBoolean;
    return value.bool;
}
pub fn integer(comptime T: type, value: Json) !T {
    return switch (value) {
        .integer => |n| std.math.cast(T, n) orelse error.JsonIntegerOutOfRange,
        .number_string => |n| std.fmt.parseInt(T, n, 10) catch error.InvalidJsonInteger,
        else => error.ExpectedJsonInteger,
    };
}

fn isNumber(value: Json) bool {
    return value == .integer or value == .float or value == .number_string;
}
fn isIntegral(value: Json) bool {
    return switch (value) {
        .integer => true,
        .number_string => |s| std.mem.indexOfAny(u8, s, ".eE") == null,
        else => false,
    };
}
fn floatNumber(value: Json) !f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.InvalidJsonNumber,
        else => error.ExpectedJsonNumber,
    };
}

/// JSON object order is not semantic; sequence order and every member are.
/// Integer equality never converts through f64, including full-u64 probes.
pub fn expectJson(expected: Json, actual: Json) !void {
    try expectJsonDepth(expected, actual, 0);
}
fn expectJsonDepth(expected: Json, actual: Json, depth: usize) !void {
    if (depth > 128) return error.JsonNestingTooDeep;
    if (isNumber(expected) and isNumber(actual)) {
        if (isIntegral(expected) and isIntegral(actual)) {
            try std.testing.expectEqual(try integer(i128, expected), try integer(i128, actual));
        } else if (isIntegral(expected) or isIntegral(actual)) {
            const integral = if (isIntegral(expected)) expected else actual;
            const floating = try floatNumber(if (isIntegral(expected)) actual else expected);
            if (!std.math.isFinite(floating)) return error.TestExpectedEqual;
            if (floating < -0x1p127 or floating >= 0x1p127) return error.TestExpectedEqual;
            if (@trunc(floating) != floating) return error.TestExpectedEqual;
            try std.testing.expectEqual(try integer(i128, integral), @as(i128, @intFromFloat(floating)));
        } else {
            try std.testing.expectEqual(try floatNumber(expected), try floatNumber(actual));
        }
        return;
    }
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .null => {},
        .bool => |b| try std.testing.expectEqual(b, actual.bool),
        .string => |s| try std.testing.expectEqualStrings(s, actual.string),
        .array => |items| {
            try std.testing.expectEqual(items.items.len, actual.array.items.len);
            for (items.items, actual.array.items) |e, a| {
                try expectJsonDepth(e, a, depth + 1);
            }
        },
        .object => |object| {
            try std.testing.expectEqual(object.count(), actual.object.count());
            var entries = object.iterator();
            while (entries.next()) |entry| {
                const found = actual.object.get(entry.key_ptr.*) orelse return error.MissingJsonField;
                try expectJsonDepth(entry.value_ptr.*, found, depth + 1);
            }
        },
        .integer, .float, .number_string => unreachable,
    }
}

pub fn expectJsonText(gpa: Allocator, expected: Json, actual_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Json, gpa, actual_json, .{ .parse_numbers = false });
    defer parsed.deinit();
    try expectJson(expected, parsed.value);
}

/// The caller owns the decoded byte buffer, even for an empty input.
pub fn unhex(gpa: Allocator, text: []const u8) ![]u8 {
    return am.error_types.hexFrom(gpa, text);
}

pub fn expectHeads(gpa: Allocator, expected: Json, actual: []const am.types.ChangeHash) !void {
    // Hash parsing borrows the allocator interface but allocates nothing.
    const heads = try array(expected);
    try std.testing.expectEqual(heads.len, actual.len);
    for (heads, 0..) |head, i| {
        const text = try string(head);
        const parsed = try am.types.ChangeHash.parse(gpa, text);
        for (heads[0..i]) |prior| {
            if (std.mem.eql(u8, text, try string(prior))) return error.DuplicateExpectedHead;
        }
        var count: usize = 0;
        for (actual) |hash| {
            if (hash.eql(parsed)) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

pub fn expectTree(gpa: Allocator, expected: Json, actual: *const am.doc.Document) !void {
    const json = try am.autoserde.AutoSerde(am.doc.Document).from(actual).toJson(gpa);
    defer gpa.free(json);
    try expectJsonText(gpa, expected, json);
}

/// Saves differ only in DEFLATE choice: the reference save is an actual native
/// load input, and both loaded materialization and head identity must agree.
pub fn expectSnapshot(
    gpa: Allocator,
    io: std.Io,
    expected: Json,
    actual: *am.doc.Document,
) !void {
    const value = try field(expected, "value");
    const heads = try field(expected, "heads");
    try expectTree(gpa, value, actual);
    const native_heads = try actual.getHeads(gpa);
    defer gpa.free(native_heads);
    try expectHeads(gpa, heads, native_heads);
    if (expected.object.get("save_hex")) |save_hex| {
        const bytes = try unhex(gpa, try string(save_hex));
        defer gpa.free(bytes);
        var loaded = try am.doc.Document.load(gpa, io, bytes, actual.textEncoding());
        defer loaded.deinit();
        try expectTree(gpa, value, &loaded);
        const loaded_heads = try loaded.getHeads(gpa);
        defer gpa.free(loaded_heads);
        try expectHeads(gpa, heads, loaded_heads);
    }
}

pub fn writeScalarJson(value: am.value.ScalarValue, writer: *std.Io.Writer) !void {
    try value.writeJson(writer);
}
fn writeJson(value: anytype, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(value);
}
pub fn writeExId(id: am.types.ExId, writer: *std.Io.Writer) !void {
    try writeJson(id, writer);
}
pub fn writeProp(prop: am.types.Prop, writer: *std.Io.Writer) !void {
    switch (prop) {
        .key => |key| try writeJson(.{ .key = key }, writer),
        .index => |index| try writeJson(.{ .index = index }, writer),
    }
}
fn scalarDatatype(value: am.value.ScalarValue) []const u8 {
    return switch (value) {
        .null_value => "null",
        .bool_value => "boolean",
        .float => "float64",
        .actor_id => "bytes",
        else => @tagName(value),
    };
}
pub fn writeValueJson(value: anytype, writer: *std.Io.Writer) !void {
    const T = @TypeOf(value);
    if (T != am.value.Value and T != am.opset.types.ValueRef and T != am.patches.Value) {
        @compileError("Parity values require a public Value, ValueRef, or patch Value");
    }
    switch (value) {
        .object => |kind| try writeJson(.{
            .type = "object",
            .object_type = @tagName(kind),
        }, writer),
        .scalar => |scalar| try writeJson(.{
            .type = "scalar",
            .datatype = scalarDatatype(scalar),
            .value = scalar,
        }, writer),
    }
}

pub fn writeValueRefJson(value: am.opset.types.ValueRef, writer: *std.Io.Writer) !void {
    try writeValueJson(value, writer);
}

pub fn expectHash(expected: Json, actual: am.types.ChangeHash) !void {
    const hex = std.fmt.bytesToHex(actual.bytes, .lower);
    try std.testing.expectEqualStrings(try string(expected), &hex);
}

pub fn expectOptionalHash(expected: Json, actual: ?am.types.ChangeHash) !void {
    if (actual) |hash| {
        try expectHash(expected, hash);
    } else {
        try std.testing.expectEqual(std.meta.activeTag(expected), .null);
    }
}

pub fn writeDocItem(actual: am.read.DocItem, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    try writeValueRefJson(actual.value, writer);
    try writer.writeByte(',');
    try writeExId(actual.id, writer);
    try writer.writeByte(']');
}

pub fn expectDocItem(gpa: Allocator, expected: Json, actual: ?am.read.DocItem) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    if (actual) |item| {
        try writeDocItem(item, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try expectJsonText(gpa, expected, out.written());
}

pub fn expectDocItems(gpa: Allocator, expected: Json, actual: []const am.read.DocItem) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (actual, 0..) |item, index| {
        if (index != 0) try out.writer.writeByte(',');
        try writeDocItem(item, &out.writer);
    }
    try out.writer.writeByte(']');
    try expectJsonText(gpa, expected, out.written());
}

pub fn writeMarks(marks: []const am.marks.Mark, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (marks, 0..) |item, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJson(.{
            .name = item.name,
            .value = item.value,
            .start = item.start,
            .end = item.end,
        }, writer);
    }
    try writer.writeByte(']');
}
pub fn writeMarkSet(actual: *const am.marks.MarkSet, writer: *std.Io.Writer) !void {
    try writer.writeByte('{');
    for (actual.entries.items, 0..) |entry, index| {
        if (index != 0) try writer.writeByte(',');
        try writeJson(entry.name, writer);
        try writer.writeByte(':');
        try writeScalarJson(entry.value, writer);
    }
    try writer.writeByte('}');
}

pub fn writeHydrated(gpa: Allocator, actual: *const am.hydrate.Value, writer: *std.Io.Writer) !void {
    try writeHydratedDepth(gpa, actual, writer, 0);
}
const HydratedJsonError = am.Error || std.Io.Writer.Error || error{HydratedNestingTooDeep};

fn writeHydratedDepth(
    gpa: Allocator,
    actual: *const am.hydrate.Value,
    writer: *std.Io.Writer,
    depth: usize,
) HydratedJsonError!void {
    if (depth > 128) return error.HydratedNestingTooDeep;
    if (actual.toScalar()) |scalar| {
        try writeScalarJson(scalar, writer);
        return;
    }
    switch (actual.object) {
        .map => |*map| try writeHydratedMap(gpa, map, writer, depth),
        .list => |*list| {
            try writer.writeByte('[');
            var items = list.items.iter();
            var index: usize = 0;
            while (items.next()) |item| : (index += 1) {
                if (index != 0) try writer.writeByte(',');
                try writeHydratedDepth(gpa, &item.value, writer, depth + 1);
            }
            try writer.writeByte(']');
        },
        .text => |*text| {
            const rendered = try text.makeString(gpa);
            defer gpa.free(rendered);
            try writeJson(rendered, writer);
        },
    }
}
fn writeHydratedMap(
    gpa: Allocator,
    map: *const am.hydrate.Map,
    writer: *std.Io.Writer,
    depth: usize,
) HydratedJsonError!void {
    try writer.writeByte('{');
    var entries = map.entries.iterator();
    var index: usize = 0;
    while (entries.next()) |entry| : (index += 1) {
        if (index != 0) try writer.writeByte(',');
        try writeJson(entry.key_ptr.*, writer);
        try writer.writeByte(':');
        try writeHydratedDepth(gpa, &entry.value_ptr.value, writer, depth + 1);
    }
    try writer.writeByte('}');
}

pub fn writeSpan(gpa: Allocator, span: *const am.iter.spans.Span, writer: *std.Io.Writer) !void {
    switch (span.*) {
        .block => |*block| {
            try writer.writeAll("{\"type\":\"block\",\"value\":");
            try writeHydratedMap(gpa, block, writer, 0);
            try writer.writeByte('}');
        },
        .text => |*text| {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try writeJson(text.text, writer);
            try writer.writeAll(",\"marks\":");
            if (text.marks) |*marks| {
                try writeMarkSet(marks, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        },
    }
}

pub fn writeSpans(gpa: Allocator, spans: []const am.iter.spans.Span, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (spans, 0..) |*span, index| {
        if (index != 0) try writer.writeByte(',');
        try writeSpan(gpa, span, writer);
    }
    try writer.writeByte(']');
}

pub fn expectScalar(gpa: Allocator, expected: Json, actual: am.value.ScalarValue) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeScalarJson(actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectValue(gpa: Allocator, expected: Json, actual: am.value.Value) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeValueJson(actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectExId(gpa: Allocator, expected: Json, actual: am.types.ExId) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeExId(actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectHydrated(gpa: Allocator, expected: Json, actual: *const am.hydrate.Value) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeHydrated(gpa, actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectMarks(gpa: Allocator, expected: Json, actual: []const am.marks.Mark) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMarks(actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectMarkSet(gpa: Allocator, expected: Json, actual: *const am.marks.MarkSet) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeMarkSet(actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
pub fn expectSpans(gpa: Allocator, expected: Json, actual: []const am.iter.spans.Span) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeSpans(gpa, actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}

fn writePatchValue(value: am.patches.Value, id: am.types.ExId, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    try writeValueJson(value, writer);
    try writer.writeByte(',');
    try writeExId(id, writer);
    try writer.writeByte(']');
}
pub fn writeCanonicalPatches(
    gpa: Allocator,
    actual: []const am.patches.Patch,
    writer: *std.Io.Writer,
) !void {
    try writer.writeByte('[');
    for (actual, 0..) |patch, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"obj\":");
        try writeExId(patch.obj, writer);
        try writer.writeAll(",\"path\":[");
        for (patch.path, 0..) |step, i| {
            if (i != 0) try writer.writeByte(',');
            try writer.writeByte('[');
            try writeExId(step.obj, writer);
            try writer.writeByte(',');
            try writeProp(step.prop, writer);
            try writer.writeByte(']');
        }
        try writer.writeAll("],\"action\":{");
        try writer.writeAll("\"type\":");
        try writeJson(@tagName(patch.action), writer);
        switch (patch.action) {
            .put_map => |action| {
                try writer.writeAll(",\"key\":");
                try writeJson(action.key, writer);
                try writer.writeAll(",\"value\":");
                try writePatchValue(action.value, action.obj, writer);
                try writer.print(",\"conflict\":{}", .{action.conflict});
            },
            .put_seq => |action| {
                try writer.print(",\"index\":{d},\"value\":", .{action.index});
                try writePatchValue(action.value, action.obj, writer);
                try writer.print(",\"conflict\":{}", .{action.conflict});
            },
            .insert => |action| {
                try writer.print(",\"index\":{d},\"values\":[", .{action.index});
                var values = action.values.iter();
                var i: usize = 0;
                while (values.next()) |value| : (i += 1) {
                    if (i != 0) try writer.writeByte(',');
                    try writer.writeByte('[');
                    try writeValueJson(value.value, writer);
                    try writer.writeByte(',');
                    try writeExId(value.obj, writer);
                    try writer.print(",{}]", .{value.conflict});
                }
                try writer.writeByte(']');
            },
            .splice_text => |action| {
                try writer.print(",\"index\":{d},\"value\":", .{action.index});
                const text = try action.value.makeString(gpa);
                defer gpa.free(text);
                try writeJson(text, writer);
                try writer.writeAll(",\"marks\":");
                if (action.marks) |*marks| {
                    try writeMarkSet(marks, writer);
                } else {
                    try writer.writeAll("null");
                }
            },
            .increment => |action| {
                try writer.writeAll(",\"prop\":");
                try writeProp(action.prop, writer);
                try writer.print(",\"value\":{d}", .{action.value});
            },
            .conflict => |action| {
                try writer.writeAll(",\"prop\":");
                try writeProp(action.prop, writer);
            },
            .delete_map => |action| {
                try writer.writeAll(",\"key\":");
                try writeJson(action.key, writer);
            },
            .delete_seq => |action| {
                try writer.print(",\"index\":{d},\"length\":{d}", .{
                    action.index, action.length,
                });
            },
            .mark => |action| {
                try writer.writeAll(",\"marks\":");
                try writeMarks(action.marks, writer);
            },
        }
        try writer.writeAll("}}");
    }
    try writer.writeByte(']');
}
pub fn expectCanonicalPatches(
    gpa: Allocator,
    expected: Json,
    actual: []const am.patches.Patch,
) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeCanonicalPatches(gpa, actual, &out.writer);
    try expectJsonText(gpa, expected, out.written());
}
