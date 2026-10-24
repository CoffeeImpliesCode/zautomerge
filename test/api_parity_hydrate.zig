const std = @import("std");
const am = @import("zautomerge");
const common = @import("api_parity_common.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Encoding = am.types.TextEncoding;
const Unit = am.patches.ConcreteTextValue.Unit;

pub fn verify(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    // Replay the public scripts in api_parity.rs:native_text, rich, and marks.
    const text_names = [_][]const u8{
        "native-text-utf8", "native-text-utf16", "native-text-codepoint", "native-text-grapheme",
    };
    const encodings = [_]Encoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    };
    for (text_names, encodings) |name, encoding| {
        const index = try unique(records, name);
        try nativeText(gpa, records[index].data, encoding);
        try common.mark(seen, index);
    }
    try rich(gpa, io, records, seen);
    try marks(gpa, io, records, seen);
}

fn unique(records: []const common.Record, name: []const u8) !usize {
    var found: ?usize = null;
    for (records, 0..) |record, index| {
        if (!std.mem.eql(u8, record.scenario, name)) continue;
        try testing.expectEqualStrings("api-parity", record.kind);
        try testing.expect(found == null);
        found = index;
    }
    return found orelse error.MissingParityRecord;
}

fn expectText(gpa: Allocator, data: Json, name: []const u8, value: *const am.hydrate.Value) !void {
    try common.expectHydrated(gpa, try common.field(data, name), value);
}

fn expectUnits(value: *const am.patches.ConcreteTextValue, expected: []const Unit) !void {
    try testing.expectEqual(expected.len, value.len());
    for (expected, 0..) |unit, index| {
        const actual = value.get(index) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(std.meta.activeTag(unit), std.meta.activeTag(actual));
        switch (unit) {
            .utf8_code_unit => |v| try testing.expectEqual(v, actual.utf8_code_unit),
            .utf16_code_unit => |v| try testing.expectEqual(v, actual.utf16_code_unit),
            .unicode_code_point => |v| try testing.expectEqual(v, actual.unicode_code_point),
            .grapheme_cluster => |v| try testing.expectEqualStrings(v, actual.grapheme_cluster),
        }
    }
    try testing.expect(value.get(expected.len) == null);
}

fn apply(value: *am.hydrate.Value, encoding: Encoding, action: am.patches.PatchAction) !void {
    const batch = [_]am.patches.Patch{.{ .obj = .root, .path = &.{}, .action = action }};
    try testing.expect((try value.applyPatches(encoding, &batch)) == .ok);
}

fn nativeText(gpa: Allocator, data: Json, encoding: Encoding) !void {
    // text_value.rs:244-268 is reached through hydrate/text.rs:29-55.
    // Rendering alone loses information: also inspect every native stored unit.
    const initial: []const u8 = switch (encoding) {
        .utf8_code_unit => "é",
        .utf16_code_unit => "😀",
        .unicode_code_point, .grapheme_cluster => "a",
    };
    const inserted: []const u8 = switch (encoding) {
        .utf8_code_unit, .utf16_code_unit => "X",
        .unicode_code_point, .grapheme_cluster => "\u{301}",
    };
    const original_units: []const Unit = switch (encoding) {
        .utf8_code_unit => &.{ .{ .utf8_code_unit = 0xc3 }, .{ .utf8_code_unit = 0xa9 } },
        .utf16_code_unit => &.{ .{ .utf16_code_unit = 0xd83d }, .{ .utf16_code_unit = 0xde00 } },
        .unicode_code_point => &.{.{ .unicode_code_point = 'a' }},
        .grapheme_cluster => &.{.{ .grapheme_cluster = "a" }},
    };
    const insert_unit: Unit = switch (encoding) {
        .utf8_code_unit => .{ .utf8_code_unit = 'X' },
        .utf16_code_unit => .{ .utf16_code_unit = 'X' },
        .unicode_code_point => .{ .unicode_code_point = 0x301 },
        .grapheme_cluster => .{ .grapheme_cluster = "\u{301}" },
    };
    var value = try am.hydrate.Value.text(gpa, encoding, initial);
    defer value.deinit();
    var second = try am.hydrate.Value.text(gpa, encoding, initial);
    defer second.deinit();
    var original = try am.hydrate.Value.text(gpa, encoding, initial);
    defer original.deinit();
    var input = try am.hydrate.Value.text(gpa, encoding, inserted);
    defer input.deinit();
    var patch_text = try am.patches.ConcreteTextValue.init(gpa, inserted, encoding);
    defer patch_text.deinit();
    try expectText(gpa, data, "initial", &value);
    try expectText(gpa, data, "insert", &input);
    try expectUnits(&value.object.text.value, original_units);
    try expectUnits(&patch_text, &.{insert_unit});
    var expected: std.ArrayList(Unit) = .empty;
    defer expected.deinit(gpa);
    try expected.appendSlice(gpa, original_units);
    try expected.insert(gpa, 1, insert_unit);
    const splice: am.patches.PatchAction = .{ .splice_text = .{
        .index = 1,
        .value = patch_text,
        .marks = null,
    } };
    try apply(&value, encoding, splice);
    try apply(&second, encoding, splice);
    try expectText(gpa, data, "after_insert", &value);
    try expectUnits(&value.object.text.value, expected.items);
    try expectUnits(&second.object.text.value, expected.items);
    try apply(&value, encoding, .{ .delete_seq = .{ .index = 0, .length = 1 } });
    _ = expected.orderedRemove(0);
    try expectText(gpa, data, "after_remove_first", &value);
    try expectUnits(&value.object.text.value, expected.items);
    try apply(&second, encoding, .{ .delete_seq = .{ .index = 1, .length = 1 } });
    try expectText(gpa, data, "remove_inserted_unit", &second);
    try expectUnits(&second.object.text.value, original_units);
    try apply(&value, encoding, .{ .delete_seq = .{
        .index = 0,
        .length = if (original_units.len == 2) 2 else 1,
    } });
    try expectText(gpa, data, "remove_remaining", &value);
    try expectUnits(&value.object.text.value, &.{});
    try apply(&original, encoding, .{ .delete_seq = .{ .index = 0, .length = 1 } });
    try expectText(gpa, data, "remove_original_first", &original);
    try expectUnits(&original.object.text.value, original_units[1..]);
    // *_native_debug are reference diagnostics, not cross-language contracts.
}

fn setActor(doc: *am.AutoCommit) !void {
    const actor = @as([15]u8, @splat(0xa1));
    try doc.setActorId(am.types.ActorId.init(&actor));
}

fn commit(doc: *am.AutoCommit) !void {
    try testing.expect((try doc.commitWith(.{ .time = 0 })) != null);
}

fn expectTree(gpa: Allocator, expected: Json, doc: *am.AutoCommit) !void {
    const bytes = try am.autoserde.AutoSerde(am.AutoCommit).from(doc).toJson(gpa);
    defer gpa.free(bytes);
    try common.expectJsonText(gpa, expected, bytes);
}

fn expectSave(gpa: Allocator, io: std.Io, expected: Json, doc: *am.AutoCommit) !void {
    // save() DEFLATE bytes need not match. Native-load the actual reference save.
    const bytes = try common.unhex(gpa, try common.string(expected));
    defer gpa.free(bytes);
    var loaded = try am.doc.Document.load(gpa, io, bytes, .unicode_code_point);
    defer loaded.deinit();
    const reference_tree = try am.autoserde.AutoSerde(am.doc.Document).from(&loaded).toJson(gpa);
    defer gpa.free(reference_tree);
    const native_tree = try am.autoserde.AutoSerde(am.AutoCommit).from(doc).toJson(gpa);
    defer gpa.free(native_tree);
    const parsed = try std.json.parseFromSlice(Json, gpa, reference_tree, .{});
    defer parsed.deinit();
    try common.expectJsonText(gpa, parsed.value, native_tree);
    const reference_heads = try loaded.getHeads(gpa);
    defer gpa.free(reference_heads);
    const native_heads = try doc.getHeads(gpa);
    defer gpa.free(native_heads);
    try testing.expectEqual(reference_heads.len, native_heads.len);
    for (reference_heads) |head| {
        var matches: usize = 0;
        for (native_heads) |actual| {
            if (head.eql(actual)) matches += 1;
        }
        try testing.expectEqual(@as(usize, 1), matches);
    }
}

fn expectHeads(gpa: Allocator, expected: Json, doc: *am.AutoCommit) !void {
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try common.expectHeads(gpa, expected, heads);
}

fn collectSpans(gpa: Allocator, doc: *am.AutoCommit, text: am.types.ExId) ![]am.iter.spans.Span {
    var iterator = try doc.spans(text, gpa);
    defer iterator.deinit();
    var spans: std.ArrayList(am.iter.spans.Span) = .empty;
    errdefer {
        for (spans.items) |*span| span.deinit(gpa);
        spans.deinit(gpa);
    }
    while (try iterator.next()) |item| {
        var span = item;
        errdefer span.deinit(gpa);
        try spans.append(gpa, span);
    }
    return spans.toOwnedSlice(gpa);
}

fn freeSpans(gpa: Allocator, spans: []am.iter.spans.Span) void {
    for (spans) |*span| span.deinit(gpa);
    gpa.free(spans);
}

fn expectSpans(gpa: Allocator, expected: Json, doc: *am.AutoCommit, text: am.types.ExId) !void {
    const spans = try collectSpans(gpa, doc, text);
    defer freeSpans(gpa, spans);
    try common.expectSpans(gpa, expected, spans);
}

fn rich(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    // api_parity.rs:rich constructs fresh nested maps through public hydration.
    const fresh_index = try unique(records, "fresh-nested-block-spans");
    const reconcile_index = try unique(records, "nested-block-reconcile");
    const update_index = try unique(records, "update-object-list-text");
    const empty_index = try unique(records, "update-object-list-empty");
    const portable_index = try unique(records, "hydrate-patch-portable-path");
    const oversize_index = try unique(records, "hydrate-oversized-delete");
    var payload = try am.AutoCommit.initWithEncoding(gpa, io, .unicode_code_point);
    defer payload.deinit();
    try setActor(&payload);
    const typ = try payload.putObject(.root, .{ .key = "type" }, .text);
    try payload.spliceText(typ, 0, 0, "paragraph");
    const parents = try payload.putObject(.root, .{ .key = "parents" }, .list);
    const div = try payload.insertObject(parents, 0, .text);
    try payload.spliceText(div, 0, 0, "div");
    const attrs = try payload.putObject(.root, .{ .key = "attrs" }, .map);
    _ = try payload.put(attrs, .{ .key = "bytes" }, .{ .bytes = &.{ 0, 255 } });
    try commit(&payload);
    var block = try payload.hydrate(.root, null, gpa);
    defer block.deinit();
    var target = try am.AutoCommit.initWithEncoding(gpa, io, .unicode_code_point);
    defer target.deinit();
    try setActor(&target);
    const text = try target.putObject(.root, .{ .key = "text" }, .text);
    try target.updateSpans(text, &.{
        .{ .block = &block.object.map },
        .{ .text = .{ .text = "hello", .marks = null } },
    });
    try commit(&target);
    const fresh = records[fresh_index].data;
    try common.expectHydrated(gpa, try common.field(fresh, "payload"), &block);
    try expectTree(gpa, try common.field(fresh, "value"), &target);
    const retained = try collectSpans(gpa, &target, text);
    defer freeSpans(gpa, retained);
    try common.expectSpans(gpa, try common.field(fresh, "spans"), retained);
    try expectSave(gpa, io, try common.field(fresh, "save_hex"), &target);
    try common.mark(seen, fresh_index);
    _ = try payload.put(attrs, .{ .key = "changed" }, .{ .bool_value = true });
    try commit(&payload);
    var changed_block = try payload.hydrate(.root, null, gpa);
    defer changed_block.deinit();
    try target.updateSpans(text, &.{
        .{ .block = &changed_block.object.map },
        .{ .text = .{ .text = "changed", .marks = null } },
    });
    try commit(&target);
    const reconcile = records[reconcile_index].data;
    try expectSpans(gpa, try common.field(reconcile, "spans"), &target, text);
    try expectSave(gpa, io, try common.field(reconcile, "save_hex"), &target);
    try expectHeads(gpa, try common.field(reconcile, "heads"), &target);
    // Returned spans own the entire nested block, not a live document view.
    try common.expectSpans(gpa, try common.field(fresh, "spans"), retained);
    try common.expectHydrated(gpa, try common.field(fresh, "payload"), &block);
    try common.mark(seen, reconcile_index);
    const list = try target.putObject(.root, .{ .key = "list" }, .list);
    var list_doc = try am.AutoCommit.initWithEncoding(gpa, io, .unicode_code_point);
    defer list_doc.deinit();
    try setActor(&list_doc);
    const lv = try list_doc.putObject(.root, .{ .key = "l" }, .list);
    _ = try list_doc.insert(lv, 0, .{ .int = 7 });
    _ = try list_doc.insert(lv, 1, .{ .bool_value = true });
    var new_list = try list_doc.hydrate(lv, null, gpa);
    defer new_list.deinit();
    try target.updateObject(list, &new_list);
    var replacement = try am.hydrate.Value.text(gpa, .unicode_code_point, "replacement");
    defer replacement.deinit();
    try target.updateObject(text, &replacement);
    var wrong = am.hydrate.Value.map(gpa);
    defer wrong.deinit();
    try testing.expectError(error.ChangeType, target.updateObject(list, &wrong));
    try commit(&target);
    const update = records[update_index].data;
    try testing.expectEqualStrings("ChangeType", try common.string(try common.field(update, "wrong_type")));
    try expectTree(gpa, try common.field(update, "value"), &target);
    try expectSave(gpa, io, try common.field(update, "save_hex"), &target);
    try common.mark(seen, update_index);
    var empty_list = am.hydrate.Value.list(gpa);
    defer empty_list.deinit();
    try target.updateObject(list, &empty_list);
    try commit(&target);
    const empty = records[empty_index].data;
    try expectTree(gpa, try common.field(empty, "value"), &target);
    try testing.expectEqual(try common.integer(usize, try common.field(empty, "length")), try target.length(list));
    try expectHeads(gpa, try common.field(empty, "heads"), &target);
    try common.mark(seen, empty_index);
    var hydrated = try target.hydrate(.root, null, gpa);
    defer hydrated.deinit();
    var foreign = try am.types.ExId.parse(gpa, "999@b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2");
    defer foreign.deinitOwned(gpa);
    const portable = [_]am.patches.Patch{.{ .obj = foreign, .path = &.{}, .action = .{
        .put_map = .{ .key = "portable", .value = .{ .scalar = .{ .bool_value = true } }, .obj = foreign, .conflict = false },
    } }};
    try testing.expect((try hydrated.applyPatches(.unicode_code_point, &portable)) == .ok);
    try common.expectHydrated(gpa, try common.field(records[portable_index].data, "value"), &hydrated);
    // hydrate.rs:89-113 selects nested properties, not foreign ID metadata.
    var nested = try changed_block.dup(gpa);
    defer nested.deinit();
    const path = [_]am.patches.PathElem{
        .{ .obj = foreign, .prop = .{ .key = "attrs" } },
    };
    const nested_patch = [_]am.patches.Patch{.{
        .obj = foreign,
        .path = &path,
        .action = portable[0].action,
    }};
    try testing.expect((try nested.value.applyPatches(.unicode_code_point, &nested_patch)) == .ok);
    const nested_attrs = &nested.value.object.map.get("attrs").?.object.map;
    try testing.expect(nested_attrs.get("portable").?.bool_value);
    try testing.expect(changed_block.object.map.get("attrs").?.object.map.get("portable") == null);
    try common.mark(seen, portable_index);
    var oversized = try new_list.dup(gpa);
    defer oversized.deinit();
    const deletion = [_]am.patches.Patch{.{ .obj = .root, .path = &.{}, .action = .{
        .delete_seq = .{ .index = 1, .length = 3 },
    } }};
    const refused = try oversized.value.applyPatches(.unicode_code_point, &deletion);
    try testing.expect(refused == .refused);
    try testing.expect(refused.refused == .invalid_index);
    try testing.expectEqual(@as(usize, 1), refused.refused.invalid_index);
    const oversize = records[oversize_index].data;
    // hydrate/list.rs:63-67 panics after its valid prefix; native is total.
    // This single documented safety difference does not waive partial state.
    try testing.expectEqualStrings("panic", try common.string(try common.field(try common.field(oversize, "result"), "outcome")));
    try common.expectHydrated(gpa, try common.field(oversize, "remaining"), &oversized.value);
    try testing.expectEqual(@as(usize, 1), oversized.value.object.list.count());
    try testing.expectEqual(@as(i64, 7), oversized.value.object.list.get(0).?.int);
    try common.mark(seen, oversize_index);
}

fn markSetFromSpans(gpa: Allocator, doc: *am.AutoCommit, text: am.types.ExId) !am.marks.MarkSet {
    const spans = try collectSpans(gpa, doc, text);
    defer freeSpans(gpa, spans);
    for (spans) |*span| {
        if (span.* == .text) {
            if (span.text.marks) |*set| return set.dup(gpa);
        }
    }
    return error.MissingMarkSet;
}

fn expectPairs(gpa: Allocator, expected: Json, set: *const am.marks.MarkSet) !void {
    const pairs = try common.array(expected);
    try testing.expectEqual(pairs.len, set.len());
    var iterator = set.iter();
    for (pairs) |pair_json| {
        const pair = try common.array(pair_json);
        try testing.expectEqual(@as(usize, 2), pair.len);
        const entry = iterator.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(try common.string(pair[0]), entry.name);
        try common.expectScalar(gpa, pair[1], entry.value);
    }
    try testing.expect(iterator.next() == null);
}

fn marks(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    // marks.rs:434-463: the no-allocator view ignores only Null tombstones.
    const visible_index = try unique(records, "non-deleted-marks");
    const empty_index = try unique(records, "non-deleted-marks-empty");
    var doc = try am.AutoCommit.initWithEncoding(gpa, io, .unicode_code_point);
    defer doc.deinit();
    try setActor(&doc);
    const text = try doc.putObject(.root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "abc");
    try doc.mark(text, 0, 3, "bold", .both, .{ .bool_value = true });
    try commit(&doc);
    var visible = try markSetFromSpans(gpa, &doc, text);
    defer visible.deinit();
    try doc.unmark(text, 0, 3, .both, "deleted", null);
    try commit(&doc);
    var after = try markSetFromSpans(gpa, &doc, text);
    defer after.deinit();
    const data = records[visible_index].data;
    const before_view = visible.nonDeletedMarks();
    const after_view = after.nonDeletedMarks();
    try testing.expectEqual(try common.integer(usize, try common.field(data, "visible_len")), before_view.len());
    try testing.expectEqual(try common.boolean(try common.field(data, "visible_empty")), before_view.isEmpty());
    try testing.expectEqual(try common.integer(usize, try common.field(data, "after_len")), after_view.len());
    try testing.expectEqual(try common.boolean(try common.field(data, "equal")), before_view.eql(after_view));
    try expectPairs(gpa, try common.field(data, "visible"), &visible);
    try expectPairs(gpa, try common.field(data, "after"), &after);
    try expectHeads(gpa, try common.field(data, "hashes"), &doc);
    try common.mark(seen, visible_index);
    try doc.unmark(text, 0, 3, .both, "bold", null);
    try commit(&doc);
    var no_marks = am.marks.MarkSet.init(gpa);
    defer no_marks.deinit();
    const no_marks_view = no_marks.nonDeletedMarks();
    const empty = records[empty_index].data;
    try testing.expectEqual(try common.integer(usize, try common.field(empty, "empty_len")), no_marks_view.len());
    try testing.expectEqual(try common.boolean(try common.field(empty, "empty")), no_marks_view.isEmpty());
    try testing.expectEqual(try common.boolean(try common.field(empty, "equal_bold_empty")), before_view.eql(no_marks_view));
    const actual_marks = try doc.marks(text, gpa);
    defer gpa.free(actual_marks);
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try common.writeMarks(actual_marks, &json.writer);
    try common.expectJsonText(gpa, try common.field(empty, "marks_after_unmark"), json.written());
    try expectHeads(gpa, try common.field(empty, "heads"), &doc);
    try common.mark(seen, empty_index);
}
