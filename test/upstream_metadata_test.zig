//! Owned native metadata queries against Rust-produced encoded changes.
const std = @import("std");
const am = @import("zautomerge");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Record = struct {
    kind: []const u8,
    label: []const u8,
    bytes: []const u8 = "",
    hash: []const u8 = "",
    actor: []const u8 = "",
    author: ?[]const u8 = null,
    seq: u64 = 0,
    start_op: u64 = 0,
    max_op: u64 = 0,
    timestamp: i64 = 0,
    message: ?[]const u8 = null,
    deps: []const []const u8 = &.{},
    extra: []const u8 = "",
    have: []const []const u8 = &.{},
    hashes: []const []const u8 = &.{},
};
fn records(arena: Allocator) ![]Record {
    var result: std.ArrayList(Record) = .empty;
    var lines = std.mem.splitScalar(u8, @embedFile("golden/metadata.jsonl"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try result.append(arena, try std.json.parseFromSliceLeaky(Record, arena, line, .{}));
    }
    return result.toOwnedSlice(arena);
}
fn unhex(gpa: Allocator, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, text.len / 2);
    errdefer gpa.free(out);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}
fn hash(text: []const u8) !am.ChangeHash {
    var result: am.ChangeHash = undefined;
    _ = try std.fmt.hexToBytes(&result.bytes, text);
    return result;
}
fn optionalBytes(expected: ?[]const u8, actual: ?[]const u8) !void {
    try testing.expectEqual(expected == null, actual == null);
    if (expected) |bytes| try testing.expectEqualStrings(bytes, actual.?);
}
fn expectRecord(arena: Allocator, row: Record, meta: am.doc.ChangeMetadata) !void {
    try testing.expectEqualSlices(u8, try unhex(arena, row.actor), meta.actor.bytes);
    try optionalBytes(row.author, meta.author);
    try testing.expectEqual(row.seq, meta.seq);
    try testing.expectEqual(row.start_op, meta.start_op);
    try testing.expectEqual(row.max_op, meta.max_op);
    try testing.expectEqual(row.timestamp, meta.timestamp);
    try optionalBytes(row.message, meta.message);
    try testing.expect((try hash(row.hash)).eql(meta.hash));
    try testing.expectEqualSlices(u8, try unhex(arena, row.extra), meta.extra);
    try testing.expectEqual(row.deps.len, meta.deps.len);
    for (row.deps) |dep| {
        const expected = try hash(dep);
        var found = false;
        for (meta.deps) |actual| if (actual.eql(expected)) {
            found = true;
        };
        try testing.expect(found);
    }
}
fn applyRows(gpa: Allocator, doc: *am.doc.Document, rows: []const Record) !void {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.kind, "change")) continue;
        const bytes = try unhex(gpa, row.bytes);
        defer gpa.free(bytes);
        // change.rs:118-120 raw_bytes() includes framing; parseChange accepts only the body.
        const chunks = try am.storage.chunk.parseChunks(bytes, gpa);
        defer gpa.free(chunks);
        try testing.expectEqual(@as(usize, 1), chunks.len);
        try testing.expectEqual(am.storage.chunk.ChunkType.change, chunks[0].typ);
        var change = try am.change_record.parseChangeWithHash(chunks[0].data, gpa, chunks[0].hash);
        defer change.deinit(gpa);
        _ = try doc.applyChanges(gpa, &.{change});
    }
}
test "Rust metadata fields and frontier query sets agree" {
    // collector.rs:665-720 uses actor author mappings, including later changes without footers.
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try records(arena.allocator());
    var doc = try am.doc.Document.init(gpa, testing.io);
    defer doc.deinit();
    try applyRows(gpa, &doc, rows);
    var change_count: usize = 0;
    var query_count: usize = 0;
    var empty_count: usize = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, row.kind, "change")) {
            change_count += 1;
            var meta = (try doc.getChangeMetaByHash(gpa, try hash(row.hash))).?;
            defer meta.deinit(gpa);
            try expectRecord(arena.allocator(), row, meta);
            if (std.mem.eql(u8, row.label, "empty")) {
                empty_count += 1;
                try testing.expectEqual(meta.start_op - 1, meta.max_op);
            }
        } else {
            try testing.expectEqualStrings("query", row.kind);
            query_count += 1;
            const have = try arena.allocator().alloc(am.ChangeHash, row.have.len);
            for (row.have, 0..) |text, i| have[i] = try hash(text);
            var metas = try doc.getChangesMeta(gpa, have);
            defer metas.deinit(gpa);
            try testing.expectEqual(row.hashes.len, metas.items.items.len);
            for (row.hashes) |text| {
                const expected = try hash(text);
                var found = false;
                for (metas.items.items) |meta| if (meta.hash.eql(expected)) {
                    found = true;
                };
                try testing.expect(found);
            }
            for (metas.items.items) |meta| {
                var found = false;
                for (rows) |change_row| {
                    if (!std.mem.eql(u8, change_row.kind, "change")) continue;
                    if (!(try hash(change_row.hash)).eql(meta.hash)) continue;
                    try expectRecord(arena.allocator(), change_row, meta);
                    found = true;
                }
                try testing.expect(found);
            }
        }
    }
    try testing.expectEqual(@as(usize, 6), change_count);
    try testing.expectEqual(@as(usize, 7), query_count);
    try testing.expectEqual(@as(usize, 1), empty_count);
    try testing.expect(try doc.getChangeMetaByHash(gpa, .{ .bytes = @as([32]u8, @splat(0xff)) }) == null);
}
test "metadata results are independent owners across mutation and document teardown" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try records(arena.allocator());
    var doc = try am.doc.Document.init(gpa, testing.io);
    var live = true;
    defer if (live) doc.deinit();
    try applyRows(gpa, &doc, rows);
    var first = try doc.getChangesMeta(gpa, &.{});
    defer first.deinit(gpa);
    var second = try doc.getChangesMeta(gpa, &.{});
    defer second.deinit(gpa);
    var right: ?Record = null;
    for (rows) |row| {
        if (std.mem.eql(u8, row.label, "right")) right = row;
    }
    var singular = (try doc.getChangeMetaByHash(gpa, try hash(right.?.hash))).?;
    defer singular.deinit(gpa);
    _ = try doc.emptyCommit(gpa, "later", 71);
    doc.deinit();
    live = false;
    first.deinit(gpa);
    first = .{};
    try expectRecord(arena.allocator(), right.?, singular);
    for (rows) |row| {
        if (!std.mem.eql(u8, row.kind, "change")) continue;
        const expected = try hash(row.hash);
        var found = false;
        for (second.items.items) |meta| {
            if (!meta.hash.eql(expected)) continue;
            try expectRecord(arena.allocator(), row, meta);
            found = true;
        }
        try testing.expect(found);
    }
}
fn allocationReads(gpa: Allocator, doc: *const am.doc.Document, known: am.ChangeHash) !void {
    var one = (try doc.getChangeMetaByHash(gpa, known)).?;
    defer one.deinit(gpa);
    var all = try doc.getChangesMeta(gpa, &.{});
    defer all.deinit(gpa);
    var later = try doc.getChangesMeta(gpa, &.{known});
    defer later.deinit(gpa);
}
test "metadata readers clean up each partial allocation failure" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try records(arena.allocator());
    var doc = try am.doc.Document.init(gpa, testing.io);
    defer doc.deinit();
    try applyRows(gpa, &doc, rows);
    // The right row carries actor, UTF8 author, message, dependencies and opaque extra bytes.
    var known: ?am.ChangeHash = null;
    for (rows) |row| if (std.mem.eql(u8, row.label, "right")) {
        known = try hash(row.hash);
    };
    try testing.checkAllAllocationFailures(gpa, allocationReads, .{ &doc, known.? });
    var all = try doc.getChangesMeta(gpa, &.{});
    defer all.deinit(gpa);
    try testing.expectEqual(@as(usize, 6), all.items.items.len);
}
test "document op lookup covers pending committed deleted and unknown operations" {
    // automerge.rs:1554-1567: lookup is historical, not a current visibility check.
    const gpa = testing.allocator;
    var doc = try am.doc.Document.init(gpa, testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "metadata-actor" });
    var tx = try am.Transaction.open(gpa, &doc);
    // Failed writes destroy the whole document; successful writes commit first.
    defer tx.deinitClosed();
    const first = try tx.putObject(.root, .{ .key = "first" }, .map);
    const last = try tx.putObject(.root, .{ .key = "last" }, .list);
    try testing.expect(doc.hashForOpid(.root) == null);
    try testing.expect(doc.hashForOpid(first) == null);
    try testing.expect(doc.hashForOpid(last) == null);
    var commit_result = try tx.commitWith(.none);
    defer commit_result.deinit(gpa);
    const committed = commit_result.hash.?;
    try testing.expect(doc.hashForOpid(first).?.eql(committed));
    try testing.expect(doc.hashForOpid(last).?.eql(committed));
    var edit = try am.Transaction.open(gpa, &doc);
    defer edit.deinitClosed();
    try testing.expectEqual(@as(usize, 1), try edit.delete(.root, .{ .key = "first" }));
    const pending = try edit.putObject(.root, .{ .key = "pending" }, .map);
    try testing.expect(doc.hashForOpid(pending) == null);
    try testing.expect(doc.hashForOpid(first).?.eql(committed));
    var edit_result = try edit.commitWith(.none);
    defer edit_result.deinit(gpa);
    const next = edit_result.hash.?;
    try testing.expect(doc.hashForOpid(first).?.eql(committed));
    try testing.expect(doc.hashForOpid(pending).?.eql(next));
    const actor = doc.getActorIndex().?;
    try testing.expect(doc.hashForOpid(am.ExId.fromParts(0, actor).?) == null);
    try testing.expect(doc.hashForOpid(am.ExId.fromParts(9999, actor).?) == null);
    try testing.expect(doc.hashForOpid(am.ExId.fromParts(1, actor + 1).?) == null);
}
test "named operation hash lookup repairs an actor slot after insertion" {
    // automerge.rs:744-758,1559-1567 resolves actor bytes before graph lookup.
    const gpa = testing.allocator;
    var doc = try am.doc.Document.init(gpa, testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "z" });
    var tx = try am.Transaction.open(gpa, &doc);
    defer tx.deinitClosed();
    const retained = try tx.putObject(.root, .{ .key = "retained" }, .map);
    try testing.expectEqual(@as(am.types.ActorIdx, 0), retained.opId().?.actor);
    try testing.expectEqualStrings("z", retained.actorBytes().?.bytes);
    var result = try tx.commitWith(.none);
    defer result.deinit(gpa);
    const committed = result.hash.?;
    try testing.expect(doc.hashForOpid(retained).?.eql(committed));
    try testing.expectEqual(@as(am.types.ActorIdx, 0), try doc.putActorRef(gpa, .{ .bytes = "a" }));
    try testing.expectEqual(@as(am.types.ActorIdx, 1), doc.resolve(retained).?.opId().?.actor);
    try testing.expect(doc.hashForOpid(retained).?.eql(committed));
    try testing.expect(am.transaction.hashForOpid(&tx, retained).?.eql(committed));
    // Compact ids have no actor bytes and remain document-local.
    try testing.expect(doc.hashForOpid(am.ExId.fromParts(1, 0).?) == null);
    try testing.expect(doc.hashForOpid(am.ExId.fromParts(1, 1).?).?.eql(committed));
}
