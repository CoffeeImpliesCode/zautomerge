//! Deterministic consumer benchmark matched to Automerge 0.12.0.
const std = @import("std");
const am = @import("zautomerge");
const Allocator = std.mem.Allocator;
const Document = am.doc.Document;
const Transaction = am.Transaction;
const Hash = am.ChangeHash;
const Phase = enum { setup, mutation, commit, read, save, load, merge, generate, receive, diff, verify };
const Workload = enum {
    @"insert-growth",
    @"list-range-seq",
    @"list-range-batch",
    @"text-edits",
    @"map-updates",
    save,
    load,
    merge,
    @"sync-roundtrip",
    @"diff-first",
    @"diff-repeat",
    @"diff-rotate",
    @"diff-subtree",
};
const Result = struct {
    phases: [@typeInfo(Phase).@"enum".field_names.len]?u64 = @splat(null),
    checksum: u64 = 0,
    heads: []Hash = &.{},

    fn add(self: *Result, phase: Phase, ns: u64) void {
        const slot = &self.phases[@backingInt(phase)];
        slot.* = (slot.* orelse 0) + ns;
    }
    fn mix(self: *Result, value: u64) void {
        self.checksum = self.checksum *% 0x9E3779B97F4A7C15 +% value;
    }
    fn mixBytes(self: *Result, bytes: []const u8) void {
        self.mix(bytes.len);
        for (bytes) |byte| self.mix(byte);
    }
};
const Timer = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Timestamp.now(io, .awake) };
    }
    fn elapsed(self: Timer) u64 {
        return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - self.start.nanoseconds);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    if (args.len != 1 and args.len != 3) return error.ExpectedWorkloadAndSize;
    const workload_name = if (args.len == 1) "insert-growth" else args[1];
    const size = if (args.len == 1) "small" else args[2];
    const workload = std.meta.stringToEnum(Workload, workload_name) orelse return error.UnknownWorkload;
    const large = if (std.mem.eql(u8, size, "large")) true else if (std.mem.eql(u8, size, "small")) false else return error.UnknownSize;
    const n: usize = switch (workload) {
        .@"text-edits", .merge, .@"diff-first", .@"diff-repeat", .@"diff-rotate", .@"diff-subtree" => if (large) 4096 else 1024,
        .@"sync-roundtrip" => if (large) 400 else 200,
        else => if (large) 10000 else 2500,
    };
    var result: Result = .{};
    defer gpa.free(result.heads);
    switch (workload) {
        .@"insert-growth", .@"list-range-seq", .@"list-range-batch" => try runList(gpa, init.io, workload, n, &result),
        .@"text-edits" => try runText(gpa, init.io, n, &result),
        .@"map-updates", .save, .load => try runMap(gpa, init.io, workload, n, &result),
        .merge => try runMerge(gpa, init.io, n, &result),
        .@"sync-roundtrip" => try runSync(gpa, init.io, n, if (large) 48 else 24, &result),
        .@"diff-first", .@"diff-repeat", .@"diff-rotate", .@"diff-subtree" => try runDiff(gpa, init.io, workload, n, &result),
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.print("{{\"implementation\":\"zig\",\"workload\":\"{s}\",\"size\":\"{s}\",\"n\":{d},\"phases_ns\":{{", .{ @tagName(workload), size, n });
    var separator: []const u8 = "";
    const phases = @typeInfo(Phase).@"enum";
    inline for (phases.field_names, phases.field_values) |name, value| {
        if (result.phases[value]) |ns| {
            try writer.print("{s}\"{s}\":{d}", .{ separator, name, ns });
            separator = ",";
        }
    }
    try writer.print("}},\"checksum\":\"{x:0>16}\",\"heads\":[", .{result.checksum});
    separator = "";
    for (result.heads) |hash| {
        try writer.print("{s}\"{s}\"", .{ separator, std.fmt.bytesToHex(hash.bytes, .lower) });
        separator = ",";
    }
    try writer.writeAll("],\"verified\":true}\n");
    try writer.flush();
}

fn newDoc(gpa: Allocator, io: std.Io, actor: []const u8) !Document {
    var doc = try Document.init(gpa, io);
    doc.setActorId(.{ .bytes = actor });
    return doc;
}

fn commit(tx: *Transaction, live: *bool) !Hash {
    var published = try tx.commitWith(.{ .message = null, .time = 0 });
    const hash = published.hash;
    published.deinit(tx.gpa);
    tx.deinitClosed();
    live.* = false;
    return hash orelse error.EmptyCommit;
}

fn intValue(value: am.opset.types.ValueRef) !i64 {
    return switch (value) {
        .object => error.ExpectedInteger,
        .scalar => |scalar| switch (scalar) {
            .int => |integer| integer,
            else => error.ExpectedInteger,
        },
    };
}

fn object(doc: *Document, gpa: Allocator, key: []const u8, kind: am.ObjType) !am.ExId {
    if (try am.read.length(doc, am.root) != 1) return error.UnexpectedRootShape;
    const values = try am.read.getAll(doc, am.root, .{ .key = key }, gpa);
    defer gpa.free(values);
    if (values.len != 1) return error.RootConflictOrMissing;
    switch (values[0].value) {
        .object => |got| if (got != kind) return error.UnexpectedObjectType,
        .scalar => return error.ExpectedObject,
    }
    return values[0].id;
}

fn verifyList(doc: *Document, gpa: Allocator, n: usize, result: *Result) !void {
    const list = try object(doc, gpa, "l", .list);
    if (try am.read.length(doc, list) != n) return error.ListLengthMismatch;
    var walk = try am.read.listRange(doc, list, am.read.IndexRange.all());
    var seen: usize = 0;
    while (try walk.next()) |item| {
        if (seen >= n or item.index != seen) return error.ListIndexMismatch;
        if (item.width != 1 or item.conflict) return error.ListWidthOrConflict;
        const integer = try intValue(item.value);
        if (integer != @as(i64, @intCast(seen))) return error.ListValueMismatch;
        result.mix(item.index);
        result.mix(@intCast(integer));
        seen += 1;
    }
    if (seen != n) return error.ListCountMismatch;
    result.mix(seen);
}

fn hashLess(_: void, a: Hash, b: Hash) bool {
    return Hash.order(a, b) == .lt;
}

fn captureHeads(doc: *Document, gpa: Allocator, count: usize, result: *Result) !void {
    result.heads = try doc.getHeads(gpa);
    std.mem.sort(Hash, result.heads, {}, hashLess);
    if (result.heads.len != count) return error.HeadCountMismatch;
    for (result.heads, 0..) |hash, i| {
        if (i > 0 and !hashLess({}, result.heads[i - 1], hash)) return error.DuplicateHeads;
    }
}

// These checks describe the independently specified transaction boundaries, not
// just the aggregate graph size. Every history row is consumed and checked.
fn verifyLinear(doc: *Document, gpa: Allocator, actor: []const u8, first_ops: usize, subsequent_ops: usize, changes: usize) !void {
    var metas = try doc.getChangesMeta(gpa, &.{});
    defer metas.deinit(gpa);
    if (metas.items.items.len != changes) return error.ChangeCountMismatch;
    var start: u64 = 1;
    for (metas.items.items, 0..) |meta, i| {
        const ops = if (i == 0) first_ops else subsequent_ops;
        try verifyMeta(meta, actor, i + 1, start, ops);
        if (i == 0) {
            if (meta.deps.len != 0) return error.InitialDependenciesMismatch;
        } else {
            if (meta.deps.len != 1) return error.DependenciesMismatch;
            if (!meta.deps[0].eql(metas.items.items[i - 1].hash)) return error.DependenciesMismatch;
        }
        start += ops;
    }
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    if (heads.len != 1 or !heads[0].eql(metas.items.items[changes - 1].hash)) {
        return error.HistoryHeadMismatch;
    }
}

fn verifyMeta(meta: am.doc.ChangeMetadata, actor: []const u8, seq: usize, start: u64, ops: usize) !void {
    if (!std.mem.eql(u8, meta.actor.bytes, actor)) return error.ActorMismatch;
    if (meta.seq != seq or meta.start_op != start or meta.max_op != start + ops - 1) {
        return error.ChangeBoundaryMismatch;
    }
    if (meta.timestamp != 0 or meta.message != null or meta.author != null or meta.extra.len != 0) {
        return error.ChangeMetadataMismatch;
    }
}

fn runList(gpa: Allocator, io: std.Io, workload: Workload, n: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    const actor = if (workload == .@"insert-growth") "bench-insert-loop" else "bench-list-width-fixture";
    var doc = try newDoc(gpa, io, actor);
    defer doc.deinit();
    var tx = try Transaction.open(gpa, &doc);
    var tx_live = true;
    defer if (tx_live) tx.deinitClosed();
    const list = try tx.putObject(am.root, .{ .key = "l" }, .list);
    const values = if (workload == .@"list-range-batch") try gpa.alloc(am.hydrate.Value, n) else try gpa.alloc(am.hydrate.Value, 0);
    defer gpa.free(values);
    for (values, 0..) |*value, i| value.* = .{ .int = @intCast(i) };
    result.add(.setup, timer.elapsed());
    timer = Timer.begin(io);
    if (workload == .@"list-range-batch") {
        try tx.splice(list, 0, 0, values);
    } else {
        for (0..n) |i| _ = try tx.insert(list, i, .{ .int = @intCast(i) });
    }
    result.add(.mutation, timer.elapsed());
    timer = Timer.begin(io);
    const committed = try commit(&tx, &tx_live);
    result.add(.commit, timer.elapsed());
    std.mem.doNotOptimizeAway(committed);
    if (workload != .@"insert-growth") {
        timer = Timer.begin(io);
        var walk = try am.read.listRange(&doc, list, am.read.IndexRange.all());
        while (try walk.next()) |item| std.mem.doNotOptimizeAway(item);
        result.add(.read, timer.elapsed());
    }
    timer = Timer.begin(io);
    try verifyLinear(&doc, gpa, actor, n + 1, 0, 1);
    if (workload == .@"insert-growth") {
        const bytes = try doc.save(gpa);
        defer gpa.free(bytes);
        var loaded = try Document.load(gpa, io, bytes, am.read.textEncoding(&doc));
        defer loaded.deinit();
        try verifyLinear(&loaded, gpa, actor, n + 1, 0, 1);
        try verifyList(&loaded, gpa, n, result);
        const heads = try loaded.getHeads(gpa);
        defer gpa.free(heads);
        if (heads.len != 1 or !heads[0].eql(committed)) return error.ReloadHeadsMismatch;
        var independent: Result = .{};
        try verifyList(&doc, gpa, n, &independent);
        if (independent.checksum != result.checksum) return error.ReloadStateMismatch;
    } else {
        try verifyList(&doc, gpa, n, result);
    }
    try captureHeads(&doc, gpa, 1, result);
    result.add(.verify, timer.elapsed());
}

fn nextRandom(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

fn runText(gpa: Allocator, io: std.Io, n: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    var doc = try newDoc(gpa, io, "bench-text-edits");
    defer doc.deinit();
    const initial: [4096]u8 = @splat('a');
    {
        var tx = try Transaction.open(gpa, &doc);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        const text = try tx.putObject(am.root, .{ .key = "t" }, .text);
        try tx.spliceText(text, 0, 0, &initial);
        _ = try commit(&tx, &tx_live);
    }
    const positions = try gpa.alloc(usize, n);
    defer gpa.free(positions);
    var state: u64 = 98765;
    for (positions, 0..) |*position, i| position.* = @intCast(nextRandom(&state) % (4096 + i));
    const text = try object(&doc, gpa, "t", .text);
    result.add(.setup, timer.elapsed());
    for (positions) |position| {
        timer = Timer.begin(io);
        var tx = try Transaction.open(gpa, &doc);
        result.add(.setup, timer.elapsed());
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        timer = Timer.begin(io);
        try tx.spliceText(text, position, 0, ".");
        result.add(.mutation, timer.elapsed());
        timer = Timer.begin(io);
        _ = try commit(&tx, &tx_live);
        result.add(.commit, timer.elapsed());
    }
    timer = Timer.begin(io);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try expected.ensureTotalCapacity(gpa, 4096 + n);
    try expected.appendSlice(gpa, &initial);
    state = 98765;
    for (0..n) |_| {
        const position: usize = @intCast(nextRandom(&state) % expected.items.len);
        try expected.insert(gpa, position, '.');
    }
    const verified_text = try object(&doc, gpa, "t", .text);
    const actual = try am.read.text(&doc, verified_text, gpa);
    defer gpa.free(actual);
    if (!std.mem.eql(u8, actual, expected.items)) return error.TextMismatch;
    if (try am.read.length(&doc, verified_text) != expected.items.len) return error.TextLengthMismatch;
    var walk = try am.read.listRange(&doc, verified_text, am.read.IndexRange.all());
    var seen: usize = 0;
    while (try walk.next()) |item| {
        if (seen >= expected.items.len or item.index != seen or item.width != 1 or item.conflict) {
            return error.TextShapeMismatch;
        }
        switch (item.value) {
            .scalar => |scalar| switch (scalar) {
                .str => |bytes| if (bytes.len != 1 or bytes[0] != expected.items[seen]) return error.TextValueMismatch,
                else => return error.TextValueMismatch,
            },
            .object => return error.TextValueMismatch,
        }
        seen += 1;
    }
    if (seen != expected.items.len) return error.TextCountMismatch;
    result.mixBytes(actual);
    try verifyLinear(&doc, gpa, "bench-text-edits", 4097, 1, n + 1);
    try captureHeads(&doc, gpa, 1, result);
    result.add(.verify, timer.elapsed());
}

fn keys(gpa: Allocator, prefix: u8, n: usize) ![][6]u8 {
    const out = try gpa.alloc([6]u8, n);
    errdefer gpa.free(out);
    for (out, 0..) |*key, i| {
        const printed = try std.fmt.bufPrint(key, "{c}{d:0>5}", .{ prefix, i });
        if (printed.len != 6) return error.InvalidKeyLength;
    }
    return out;
}

fn putKeys(tx: *Transaction, names: []const [6]u8, zero: bool, offset: usize) !void {
    for (names, 0..) |*key, i| {
        _ = try tx.put(am.root, .{ .key = key }, .{ .int = @intCast(if (zero) 0 else i + offset) });
    }
}

fn verifyMap(doc: *Document, names: []const [6]u8, offset: usize, result: *Result) !void {
    if (try am.read.length(doc, am.root) != names.len) return error.MapLengthMismatch;
    var walk = try am.read.mapRange(doc, am.root, am.read.KeyRange.all());
    var seen: usize = 0;
    while (try walk.next()) |item| {
        if (seen >= names.len or !std.mem.eql(u8, item.key, &names[seen])) return error.MapKeyMismatch;
        if (item.conflict) return error.MapConflict;
        const integer = try intValue(item.value);
        if (integer != @as(i64, @intCast(seen + offset))) return error.MapValueMismatch;
        result.mixBytes(item.key);
        result.mix(@intCast(integer));
        seen += 1;
    }
    if (seen != names.len) return error.MapCountMismatch;
    result.mix(seen);
}

fn runMap(gpa: Allocator, io: std.Io, workload: Workload, n: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    const updating = workload == .@"map-updates";
    const actor = if (updating) "bench-map-updates" else "bench-save-load";
    var doc = try newDoc(gpa, io, actor);
    defer doc.deinit();
    const names = try keys(gpa, 'k', n);
    defer gpa.free(names);
    {
        var tx = try Transaction.open(gpa, &doc);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        try putKeys(&tx, names, updating, 0);
        _ = try commit(&tx, &tx_live);
    }
    result.add(.setup, timer.elapsed());
    if (updating) {
        timer = Timer.begin(io);
        var tx = try Transaction.open(gpa, &doc);
        result.add(.setup, timer.elapsed());
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        timer = Timer.begin(io);
        try putKeys(&tx, names, false, 1);
        result.add(.mutation, timer.elapsed());
        timer = Timer.begin(io);
        _ = try commit(&tx, &tx_live);
        result.add(.commit, timer.elapsed());
        timer = Timer.begin(io);
        try verifyMap(&doc, names, 1, result);
        try verifyLinear(&doc, gpa, actor, n, n, 2);
        try captureHeads(&doc, gpa, 1, result);
        result.add(.verify, timer.elapsed());
    } else {
        timer = Timer.begin(io);
        const bytes = try doc.save(gpa);
        result.add(if (workload == .save) .save else .setup, timer.elapsed());
        defer gpa.free(bytes);
        timer = Timer.begin(io);
        var loaded = try Document.load(gpa, io, bytes, am.read.textEncoding(&doc));
        result.add(if (workload == .load) .load else .verify, timer.elapsed());
        defer loaded.deinit();
        timer = Timer.begin(io);
        try verifyMap(&loaded, names, 0, result);
        try verifyLinear(&loaded, gpa, actor, n, 0, 1);
        try verifyLinear(&doc, gpa, actor, n, 0, 1);
        var independent: Result = .{};
        try verifyMap(&doc, names, 0, &independent);
        if (independent.checksum != result.checksum) return error.ReloadStateMismatch;
        try captureHeads(&loaded, gpa, 1, result);
        const original_heads = try doc.getHeads(gpa);
        defer gpa.free(original_heads);
        if (original_heads.len != 1 or !original_heads[0].eql(result.heads[0])) return error.ReloadHeadsMismatch;
        result.add(.verify, timer.elapsed());
    }
}

fn verifyMergeFixture(doc: *Document, names: []const [6]u8) !void {
    if (try am.read.length(doc, am.root) != names.len + 1) return error.FixtureLengthMismatch;
    var walk = try am.read.mapRange(doc, am.root, am.read.KeyRange.all());
    const base = (try walk.next()) orelse return error.MissingBase;
    if (!std.mem.eql(u8, base.key, "base") or base.conflict or
        try intValue(base.value) != 0) return error.BaseValueMismatch;
    for (names, 0..) |*name, i| {
        const row = (try walk.next()) orelse return error.MissingBranchKey;
        if (!std.mem.eql(u8, row.key, name) or row.conflict or
            try intValue(row.value) != @as(i64, @intCast(i))) return error.BranchValueMismatch;
    }
    if (try walk.next() != null) return error.ExtraBranchKey;
}

fn runMerge(gpa: Allocator, io: std.Io, n: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    var base = try newDoc(gpa, io, "bench-merge-base");
    defer base.deinit();
    {
        var tx = try Transaction.open(gpa, &base);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        _ = try tx.put(am.root, .{ .key = "base" }, .{ .int = 0 });
        _ = try commit(&tx, &tx_live);
    }
    const bytes = try base.save(gpa);
    defer gpa.free(bytes);
    var left = try Document.load(gpa, io, bytes, am.read.textEncoding(&base));
    defer left.deinit();
    var right = try Document.load(gpa, io, bytes, am.read.textEncoding(&base));
    defer right.deinit();
    left.setActorId(.{ .bytes = "bench-merge-left" });
    right.setActorId(.{ .bytes = "bench-merge-right" });
    const left_names = try keys(gpa, 'l', n);
    defer gpa.free(left_names);
    const right_names = try keys(gpa, 'r', n);
    defer gpa.free(right_names);
    var branch_heads: [2]Hash = undefined;
    {
        var tx = try Transaction.open(gpa, &left);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        try putKeys(&tx, left_names, false, 0);
        branch_heads[0] = try commit(&tx, &tx_live);
    }
    {
        var tx = try Transaction.open(gpa, &right);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        try putKeys(&tx, right_names, false, 0);
        branch_heads[1] = try commit(&tx, &tx_live);
    }
    result.add(.setup, timer.elapsed());
    timer = Timer.begin(io);
    const merged_heads = try left.merge(gpa, &right);
    result.add(.merge, timer.elapsed());
    defer gpa.free(merged_heads);
    timer = Timer.begin(io);
    if (try am.read.length(&left, am.root) != 2 * n + 1) return error.MergeLengthMismatch;
    var walk = try am.read.mapRange(&left, am.root, am.read.KeyRange.all());
    var seen: usize = 0;
    while (try walk.next()) |item| {
        if (seen > 2 * n or item.conflict) return error.MergeShapeMismatch;
        const expected_key: []const u8 = if (seen == 0) "base" else if (seen <= n) &left_names[seen - 1] else &right_names[seen - n - 1];
        const expected_value: usize = if (seen == 0) 0 else if (seen <= n) seen - 1 else seen - n - 1;
        if (!std.mem.eql(u8, item.key, expected_key)) return error.MergeKeyMismatch;
        const integer = try intValue(item.value);
        if (integer != @as(i64, @intCast(expected_value))) return error.MergeValueMismatch;
        result.mixBytes(item.key);
        result.mix(@intCast(integer));
        seen += 1;
    }
    if (seen != 2 * n + 1) return error.MergeCountMismatch;
    result.mix(seen);
    try verifyMergeFixture(&base, &.{});
    try verifyMergeFixture(&right, right_names);
    try verifyLinear(&base, gpa, "bench-merge-base", 1, 0, 1);
    var metas = try left.getChangesMeta(gpa, &.{});
    defer metas.deinit(gpa);
    if (metas.items.items.len != 3) return error.MergeChangeCountMismatch;
    const base_heads = try base.getHeads(gpa);
    defer gpa.free(base_heads);
    if (base_heads.len != 1) return error.BaseHeadMismatch;
    var found: [3]bool = @splat(false);
    for (metas.items.items) |meta| {
        if (std.mem.eql(u8, meta.actor.bytes, "bench-merge-base")) {
            if (found[0]) return error.DuplicateMergeActor;
            found[0] = true;
            try verifyMeta(meta, "bench-merge-base", 1, 1, 1);
            if (meta.deps.len != 0 or !meta.hash.eql(base_heads[0])) return error.BaseHistoryMismatch;
        } else {
            const side: usize = if (std.mem.eql(u8, meta.actor.bytes, "bench-merge-left")) 0 else if (std.mem.eql(u8, meta.actor.bytes, "bench-merge-right")) 1 else return error.MergeActorMismatch;
            if (found[side + 1]) return error.DuplicateMergeActor;
            found[side + 1] = true;
            try verifyMeta(meta, if (side == 0) "bench-merge-left" else "bench-merge-right", 1, 2, n);
            if (meta.deps.len != 1 or !meta.deps[0].eql(base_heads[0]) or
                !meta.hash.eql(branch_heads[side])) return error.BranchHistoryMismatch;
        }
    }
    for (found) |present| if (!present) return error.MissingMergeActor;
    try captureHeads(&left, gpa, 2, result);
    std.mem.sort(Hash, &branch_heads, {}, hashLess);
    if (merged_heads.len != 2) return error.MergeReturnedHeadMismatch;
    std.mem.sort(Hash, merged_heads, {}, hashLess);
    for (result.heads, branch_heads, merged_heads) |actual, expected, returned| {
        if (!actual.eql(expected) or !actual.eql(returned)) return error.MergeHeadMismatch;
    }
    result.add(.verify, timer.elapsed());
}

fn exchange(gpa: Allocator, source: *Document, source_state: *am.sync.state.State, target: *Document, target_state: *am.sync.state.State) !void {
    const message = (try am.sync.protocol.generateSyncMessage(gpa, source, source_state)) orelse return error.ExpectedSyncMessage;
    try am.sync.protocol.receiveSyncMessage(gpa, target, target_state, message);
}

fn runSync(gpa: Allocator, io: std.Io, n: usize, rounds: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    var local = try newDoc(gpa, io, "bench-sync-roundtrip-local");
    defer local.deinit();
    var peer = try newDoc(gpa, io, "bench-sync-roundtrip-peer");
    defer peer.deinit();
    var local_state = am.sync.state.State.new(gpa);
    defer local_state.deinit();
    var peer_state = am.sync.state.State.new(gpa);
    defer peer_state.deinit();
    const list = blk: {
        var tx = try Transaction.open(gpa, &local);
        var tx_live = true;
        defer if (tx_live) tx.deinitClosed();
        const id = try tx.putObject(am.root, .{ .key = "l" }, .list);
        _ = try commit(&tx, &tx_live);
        break :blk id;
    };
    try exchange(gpa, &peer, &peer_state, &local, &local_state);
    try exchange(gpa, &local, &local_state, &peer, &peer_state);
    try exchange(gpa, &peer, &peer_state, &local, &local_state);
    result.add(.setup, timer.elapsed());
    timer = Timer.begin(io);
    if (local_state.sent_hashes.items.len != 0) return error.HandshakeDidNotPrune;
    result.add(.verify, timer.elapsed());
    var written: usize = 0;
    var sent_before: usize = 0;
    for (0..rounds) |round| {
        for (0..n) |_| {
            timer = Timer.begin(io);
            var tx = try Transaction.open(gpa, &local);
            result.add(.setup, timer.elapsed());
            var tx_live = true;
            defer if (tx_live) tx.deinitClosed();
            timer = Timer.begin(io);
            _ = try tx.insert(list, written, .{ .int = @intCast(written) });
            result.add(.mutation, timer.elapsed());
            timer = Timer.begin(io);
            _ = try commit(&tx, &tx_live);
            result.add(.commit, timer.elapsed());
            written += 1;
        }
        timer = Timer.begin(io);
        const generated = try am.sync.protocol.generateSyncMessage(gpa, &local, &local_state);
        result.add(.generate, timer.elapsed());
        if (generated) |message| {
            timer = Timer.begin(io);
            try am.sync.protocol.receiveSyncMessage(gpa, &peer, &peer_state, message);
            result.add(.receive, timer.elapsed());
        } else return error.ExpectedRoundMessage;
        timer = Timer.begin(io);
        const expected_growth = if (round == 0) n + 1 else n;
        if (local_state.sent_hashes.items.len != sent_before + expected_growth) {
            return error.SentHashGrowthMismatch;
        }
        sent_before = local_state.sent_hashes.items.len;
        if (local.graph.len() != written + 1 or peer.graph.len() != written + 1) {
            return error.RoundChangeCountMismatch;
        }
        result.add(.verify, timer.elapsed());
    }
    timer = Timer.begin(io);
    const sent = local_state.sent_hashes.items;
    if (sent.len != n * rounds + 1) return error.SentHashCountMismatch;
    for (sent, 0..) |hash, i| {
        if (i > 0 and !hashLess({}, sent[i - 1], hash)) return error.SentHashesUnsorted;
        if (!local.graph.hasChange(hash)) return error.UnknownSentHash;
    }
    result.add(.verify, timer.elapsed());
    timer = Timer.begin(io);
    const final_message = try am.sync.protocol.generateSyncMessage(gpa, &peer, &peer_state);
    result.add(.generate, timer.elapsed());
    if (final_message) |message| {
        timer = Timer.begin(io);
        try am.sync.protocol.receiveSyncMessage(gpa, &local, &local_state, message);
        result.add(.receive, timer.elapsed());
    } else return error.ExpectedFinalAcknowledgement;
    timer = Timer.begin(io);
    if (local_state.sent_hashes.items.len != 0) return error.FinalAckDidNotPrune;
    var quiet = try am.sync.protocol.generateSyncMessage(gpa, &local, &local_state);
    if (quiet) |*message| {
        message.deinit();
        return error.SyncNotQuiet;
    }
    try verifyList(&peer, gpa, n * rounds, result);
    var independent: Result = .{};
    try verifyList(&local, gpa, n * rounds, &independent);
    if (independent.checksum != result.checksum) return error.SyncStateMismatch;
    try verifyLinear(&local, gpa, "bench-sync-roundtrip-local", 1, 1, n * rounds + 1);
    try verifyLinear(&peer, gpa, "bench-sync-roundtrip-local", 1, 1, n * rounds + 1);
    try captureHeads(&local, gpa, 1, result);
    const peer_heads = try peer.getHeads(gpa);
    defer gpa.free(peer_heads);
    if (peer_heads.len != 1 or !peer_heads[0].eql(result.heads[0])) return error.SyncHeadsMismatch;
    result.add(.verify, timer.elapsed());
}

fn verifyDiffId(doc: *const Document, id: am.ExId, counter: usize) !void {
    if (id.counter() != @as(u32, @intCast(counter))) return error.PatchCounterMismatch;
    const actor = if (id.actorBytes()) |bytes| bytes else doc.getActor(id.actor() orelse return error.PatchActorMissing) orelse
        return error.PatchActorMissing;
    if (!std.mem.eql(u8, actor.bytes, "bench-diff-matrix")) return error.PatchActorMismatch;
}

fn verifyDiffPatches(doc: *const Document, patches: *const am.patches.Patches, names: []const [6]u8, forward: bool) !u64 {
    if (patches.items.items.len != names.len) return error.PatchCountMismatch;
    var folded: Result = .{};
    folded.mix(names.len);
    for (patches.items.items, 0..) |patch, i| {
        try verifyDiffId(doc, patch.obj, 1);
        // Upstream patch_builder.rs:143-164 walks all the way to ROOT even
        // when diff_obj selected only a nonrecursive subtree.
        if (patch.path.len != 1 or patch.path[0].obj != .root) {
            return error.PatchPathMismatch;
        }
        switch (patch.path[0].prop) {
            .key => |key| if (!std.mem.eql(u8, key, "m")) return error.PatchPathMismatch,
            .index => return error.PatchPathMismatch,
        }
        const action = switch (patch.action) {
            .put_map => |put| put,
            else => return error.UnexpectedPatchAction,
        };
        if (action.conflict or !std.mem.eql(u8, action.key, &names[i])) {
            return error.PatchKeyOrConflictMismatch;
        }
        const integer = switch (action.value) {
            .scalar => |scalar| switch (scalar) {
                .int => |value| value,
                else => return error.PatchValueTypeMismatch,
            },
            .object => return error.PatchValueTypeMismatch,
        };
        const expected: i64 = if (forward) @intCast(i + 1) else 0;
        if (integer != expected) return error.PatchValueMismatch;
        try verifyDiffId(doc, action.obj, if (forward) names.len + 2 + i else 2 + i);
        folded.mixBytes(action.key);
        folded.mix(@bitCast(integer));
    }
    folded.mix(names.len);
    return folded.checksum;
}

fn runDiff(gpa: Allocator, io: std.Io, workload: Workload, n: usize, result: *Result) !void {
    var timer = Timer.begin(io);
    var owner = try am.AutoCommit.init(gpa, io);
    defer owner.deinit();
    try owner.setActorId(.{ .bytes = "bench-diff-matrix" });
    const names = try keys(gpa, 'k', n);
    defer gpa.free(names);
    const map = try owner.putObject(am.root, .{ .key = "m" }, .map);
    for (names) |*key| {
        _ = try owner.put(map, .{ .key = key }, .{ .int = 0 });
    }
    const first_hash = (try owner.commitWith(.{ .message = null, .time = 0 })) orelse return error.EmptyCommit;
    const before = try owner.getHeads(gpa);
    defer gpa.free(before);
    for (names, 0..) |*key, i| {
        _ = try owner.put(map, .{ .key = key }, .{ .int = @intCast(i + 1) });
    }
    const second_hash = (try owner.commitWith(.{ .message = null, .time = 0 })) orelse return error.EmptyCommit;
    const after = try owner.getHeads(gpa);
    defer gpa.free(after);
    if (workload == .@"diff-repeat" or workload == .@"diff-subtree") {
        var prime = if (workload == .@"diff-subtree")
            try owner.diffObj(gpa, map, before, after, false)
        else
            try owner.diff(gpa, before, after);
        prime.deinit();
    }
    result.add(.setup, timer.elapsed());
    const calls: usize = if (workload == .@"diff-first") 1 else 32;
    for (0..calls) |call| {
        const forward = workload != .@"diff-rotate" or call % 2 == 0;
        const from = if (forward) before else after;
        const to = if (forward) after else before;
        timer = Timer.begin(io);
        var patches = if (workload == .@"diff-subtree")
            try owner.diffObj(gpa, map, from, to, false)
        else
            try owner.diff(gpa, from, to);
        result.add(.diff, timer.elapsed());
        var patches_live = true;
        defer if (patches_live) patches.deinit();
        timer = Timer.begin(io);
        result.mix(try verifyDiffPatches(&owner.doc, &patches, names, forward));
        patches.deinit();
        patches_live = false;
        result.add(.verify, timer.elapsed());
    }
    timer = Timer.begin(io);
    result.mix(calls);
    if (owner.pendingOps() != 0) return error.UncommittedDiffFixture;
    const verified_map = try object(&owner.doc, gpa, "m", .map);
    try verifyDiffId(&owner.doc, verified_map, 1);
    if (try am.read.length(&owner.doc, verified_map) != n) return error.DiffMapLengthMismatch;
    var walk = try am.read.mapRange(&owner.doc, verified_map, am.read.KeyRange.all());
    var seen: usize = 0;
    while (try walk.next()) |row| {
        if (seen >= n or row.conflict or !std.mem.eql(u8, row.key, &names[seen])) {
            return error.DiffMapKeyMismatch;
        }
        if (try intValue(row.value) != @as(i64, @intCast(seen + 1))) {
            return error.DiffMapValueMismatch;
        }
        seen += 1;
    }
    if (seen != n) return error.DiffMapCountMismatch;
    try verifyLinear(&owner.doc, gpa, "bench-diff-matrix", n + 1, n, 2);
    if (before.len != 1 or after.len != 1 or !before[0].eql(first_hash) or
        !after[0].eql(second_hash) or first_hash.eql(second_hash)) return error.DiffRangeHeadsMismatch;
    try captureHeads(&owner.doc, gpa, 1, result);
    if (!result.heads[0].eql(second_hash)) return error.DiffFinalHeadsMismatch;
    result.add(.verify, timer.elapsed());
}
