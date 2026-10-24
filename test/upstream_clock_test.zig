const std = @import("std");
const am = @import("zautomerge");
const testing = std.testing;
const gpa = testing.allocator;
const Document = am.doc.Document;
const Tx = am.Transaction;
const ChangeHash = am.ChangeHash;
const Change = am.change_record.Change;
const root = am.root;
const actor_a = am.ActorId{ .bytes = &(@as([15]u8, @splat(0xa1))) };
const actor_b = am.ActorId{ .bytes = &(@as([16]u8, @splat(0xb2))) };

fn commit(tx: *Tx, message: []const u8) !ChangeHash {
    var result = try tx.commitWith(.{ .message = message, .time = 1_700_000_000 });
    defer result.deinit(testing.allocator);
    return result.hash orelse error.NoCommit;
}

fn history() !Document {
    // tools/oracle/src/main.rs:287-313,1866-1886. Save the base before either
    // branch is written; the B third change must not depend on A's second.
    var base = try Document.init(gpa, testing.io);
    defer base.deinit();
    base.setActorId(actor_a);
    var tx = try Tx.open(gpa, &base);
    // All error exits destroy the owning document; successful exits commit first.
    defer tx.deinitClosed();
    _ = try tx.put(root, .{ .key = "title" }, .{ .str = "zautomerge oracle" });
    const list = try tx.putObject(root, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .int = -1 });
    _ = try tx.insert(list, 1, .{ .str = "two" });
    _ = try tx.insert(list, 2, .{ .float = 3.5 });
    _ = try tx.insert(list, 3, .{ .bool_value = true });
    _ = try tx.insert(list, 4, .{ .uint = 7 });
    const text = try tx.putObject(root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "hello ");
    try tx.spliceText(text, 6, 0, "world");
    const map = try tx.putObject(root, .{ .key = "map" }, .map);
    _ = try tx.put(map, .{ .key = "keep" }, .{ .str = "kept" });
    _ = try tx.put(map, .{ .key = "counter" }, .{ .counter = .init(0) });
    _ = try tx.put(map, .{ .key = "drop" }, .{ .str = "dropped" });
    try tx.increment(map, .{ .key = "counter" }, 5);
    _ = try tx.delete(map, .{ .key = "drop" });
    _ = try commit(&tx, "base");
    const heads = try base.getHeads(gpa);
    defer gpa.free(heads);
    var a = try base.forkAt(gpa, heads);
    defer a.deinit();
    a.setActorId(actor_a);
    var a_tx = try Tx.open(gpa, &a);
    defer a_tx.deinitClosed();
    _ = try a_tx.put(root, .{ .key = "second" }, .{ .int = 2 });
    _ = try commit(&a_tx, "second");
    var b = try base.forkAt(gpa, heads);
    errdefer b.deinit();
    b.setActorId(actor_b);
    var b_tx = try Tx.open(gpa, &b);
    defer b_tx.deinitClosed();
    _ = try b_tx.put(root, .{ .key = "from_b" }, .{ .int = 1 });
    _ = try commit(&b_tx, "from b");
    var third_tx = try Tx.open(gpa, &b);
    defer third_tx.deinitClosed();
    _ = try third_tx.put(root, .{ .key = "third" }, .{ .int = 3 });
    _ = try commit(&third_tx, "third");
    const merged = try b.merge(gpa, &a);
    gpa.free(merged);
    return b;
}

const Row = struct {
    kind: []const u8,
    changes: ?std.json.Value = null,
    index: ?usize = null,
    hash: ?[]const u8 = null,
    deps: []const []const u8 = &.{},
    heads: []const []const u8 = &.{},
    missing: []const []const u8 = &.{},
    left: ?usize = null,
    right: ?usize = null,
};

fn mappedHash(text: []const u8, reference: *const [4]ChangeHash, local: *const [4]Change) !ChangeHash {
    var hash: ChangeHash = undefined;
    _ = try std.fmt.hexToBytes(&hash.bytes, text);
    for (reference, 0..) |known, index| {
        if (known.eql(hash)) return local[index].hash;
    }
    return error.UnknownReferenceHash;
}

fn expectSet(expected: []const ChangeHash, actual: []const ChangeHash) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected) |want| {
        var matches: usize = 0;
        for (actual) |got| {
            if (want.eql(got)) matches += 1;
        }
        try testing.expectEqual(@as(usize, 1), matches);
    }
}

fn expectMappedSet(
    expected: []const []const u8,
    actual: []const ChangeHash,
    reference: *const [4]ChangeHash,
    local: *const [4]Change,
) !void {
    var hashes: [4]ChangeHash = undefined;
    try testing.expect(expected.len <= hashes.len);
    for (expected, 0..) |hash, i| hashes[i] = try mappedHash(hash, reference, local);
    try expectSet(hashes[0..expected.len], actual);
}

test "clock corpus gates all dependency-closed subsets and every covers and merge pair" {
    // clock.jsonl is produced by the pinned Rust public Document API, not a
    // clock reimplementation. Map identities by fixture labels: encoder byte
    // differences must not silently turn this into an encoder compatibility test.
    var complete = try history();
    defer complete.deinit();
    var changes = try complete.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), changes.items.items.len);
    const labels = [_][]const u8{ "base", "from b", "third", "second" };
    var local: [4]Change = undefined;
    for (labels, 0..) |label, i| {
        var found: usize = 0;
        for (changes.items.items) |built| {
            if (std.mem.eql(u8, built.change.message, label)) {
                local[i] = built.change;
                found += 1;
            }
        }
        try testing.expectEqual(@as(usize, 1), found);
    }
    var reference: [4]ChangeHash = @splat(.{ .bytes = @splat(0) });
    var docs: [7]Document = undefined;
    var doc_count: usize = 0;
    defer for (docs[0..doc_count]) |*doc| doc.deinit();
    var change_count: usize = 0;
    var covers_seen = @as([7][7]bool, @splat(@as([7]bool, @splat(false))));
    var merges_seen = @as([7][7]bool, @splat(@as([7]bool, @splat(false))));
    var lines = std.mem.splitScalar(u8, @embedFile("golden/clock.jsonl"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Row, gpa, line, .{});
        defer parsed.deinit();
        const row = parsed.value;
        if (std.mem.eql(u8, row.kind, "clock-history")) {
            try testing.expectEqual(@as(i64, 4), row.changes.?.integer);
        } else if (std.mem.eql(u8, row.kind, "clock-change")) {
            const index = row.index.?;
            try testing.expectEqual(change_count, index);
            try testing.expect(index < reference.len);
            _ = try std.fmt.hexToBytes(&reference[index].bytes, row.hash.?);
            try expectMappedSet(row.deps, local[index].deps, &reference, &local);
            change_count += 1;
        } else if (std.mem.eql(u8, row.kind, "clock-doc")) {
            try testing.expectEqual(@as(usize, 4), change_count);
            try testing.expect(doc_count < docs.len);
            var subset = try Document.init(gpa, testing.io);
            errdefer subset.deinit();
            var selected: [4]Change = undefined;
            const indices = row.changes.?.array.items;
            try testing.expect(indices.len <= selected.len);
            for (indices, 0..) |index, i| {
                try testing.expect(index.integer >= 0 and index.integer < 4);
                selected[i] = local[@intCast(index.integer)];
            }
            _ = try subset.applyChanges(gpa, selected[0..indices.len]);
            const heads = try subset.getHeads(gpa);
            defer gpa.free(heads);
            try expectMappedSet(row.heads, heads, &reference, &local);
            const missing = try subset.getMissingDeps(gpa, &.{});
            defer gpa.free(missing);
            try expectSet(&.{}, missing);
            docs[doc_count] = subset;
            doc_count += 1;
        } else {
            try testing.expectEqual(docs.len, doc_count);
            const left = row.left.?;
            const right = row.right.?;
            try testing.expect(left < docs.len and right < docs.len);
            if (std.mem.eql(u8, row.kind, "clock-covers")) {
                try testing.expect(!covers_seen[left][right]);
                covers_seen[left][right] = true;
                const heads = try docs[right].getHeads(gpa);
                defer gpa.free(heads);
                const missing = try docs[left].getMissingDeps(gpa, heads);
                defer gpa.free(missing);
                try expectMappedSet(row.missing, missing, &reference, &local);
            } else if (std.mem.eql(u8, row.kind, "clock-merge")) {
                try testing.expect(!merges_seen[left][right]);
                merges_seen[left][right] = true;
                const heads = try docs[left].getHeads(gpa);
                defer gpa.free(heads);
                var probe = try docs[left].forkAt(gpa, heads);
                defer probe.deinit();
                const merged = try probe.merge(gpa, &docs[right]);
                defer gpa.free(merged);
                try expectMappedSet(row.heads, merged, &reference, &local);
                const actual = try probe.getHeads(gpa);
                defer gpa.free(actual);
                try expectMappedSet(row.heads, actual, &reference, &local);
            } else return error.UnknownClockRecord;
        }
    }
    try testing.expectEqual(docs.len, doc_count);
    for (covers_seen, merges_seen) |covers, merges| {
        for (covers, merges) |covered, merged| {
            try testing.expect(covered);
            try testing.expect(merged);
        }
    }
}
