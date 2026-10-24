//! Native public-consumer replay of document lifecycle, loader and transaction records.
//! Every story uses the oracle's actors, operation order and commit boundaries.
const std = @import("std");
const am = @import("zautomerge");
const common = @import("api_parity_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ROOT = am.types.ExId.root;
const tx_scenarios = [_][]const u8{
    "transaction-scoped-read-doc",
    "owned-transaction-terminal",
    "closure-user-error",
    "closure-logged-success",
    "autoserde-nested-transaction-scope",
    "transaction-explicit-equal-heads",
    "transaction-unscoped-equal-heads-hydrate",
};

pub fn verify(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    try verifyLifecycle(gpa, io, records, seen);
    try verifyLoads(gpa, io, records, seen);
    try verifyTransactions(gpa, io, records, seen);
}

fn documentFailure(scenario: []const u8, failure: anyerror) void {
    std.debug.print("api-parity kind=api-parity scenario={s} error={s}\n", .{ scenario, @errorName(failure) });
}

fn documentResult(scenario: []const u8, result: anytype) @TypeOf(result) {
    return result catch |failure| {
        documentFailure(scenario, failure);
        return failure;
    };
}

fn txRecord(records: []const common.Record, name: []const u8) !usize {
    var found: ?usize = null;
    for (records, 0..) |record, index| {
        if (!std.mem.eql(u8, record.scenario, name)) continue;
        if (found != null) return error.DuplicateScenario;
        try std.testing.expectEqualStrings("api-parity", record.kind);
        found = index;
    }
    return found orelse error.MissingScenario;
}

fn txExpectField(gpa: Allocator, data: Value, name: []const u8, actual: anytype) !void {
    errdefer std.debug.print("api-parity document field={s}\n", .{name});
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try std.json.Stringify.value(actual, .{}, &output.writer);
    try common.expectJsonText(gpa, try common.field(data, name), output.written());
}

fn txExpectTree(gpa: Allocator, expected: Value, reader: anytype) !void {
    const json = try am.autoserde.AutoSerde(@TypeOf(reader)).from(reader).toJson(gpa);
    defer gpa.free(json);
    try common.expectJsonText(gpa, expected, json);
}

fn txExpectHash(gpa: Allocator, expected: Value, actual: ?am.types.ChangeHash) !void {
    _ = gpa;
    try common.expectOptionalHash(expected, actual);
}

fn txNewDocument(gpa: Allocator, io: std.Io) !am.doc.Document {
    var doc = try am.doc.Document.init(gpa, io);
    errdefer doc.deinit();
    doc.setActorId(am.types.ActorId.init(&@as([15]u8, @splat(0xa1))));
    return doc;
}

fn txCommit(tx: *am.Transaction, gpa: Allocator) !am.types.ChangeHash {
    var result = try tx.commitWith(.{ .time = 0 });
    defer result.deinit(gpa);
    return result.hash orelse error.ExpectedChange;
}

fn txExpectPatches(gpa: Allocator, expected: Value, doc: *am.doc.Document, log: *am.patches.PatchLog) !void {
    errdefer std.debug.print("api-parity document field=patches\n", .{});
    var patches = try doc.makePatches(log);
    defer patches.deinit();
    try common.expectCanonicalPatches(gpa, expected, patches.slice());
}

fn verifyTransactions(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    var indexes: [tx_scenarios.len]usize = undefined;
    const field_counts = [_]usize{ 7, 6, 7, 3, 5, 8, 5 };
    for (tx_scenarios, field_counts, 0..) |name, count, index| {
        indexes[index] = try documentResult(name, txCheckRecord(records, name, count));
    }
    var doc = try txNewDocument(gpa, io);
    defer doc.deinit();
    // api_parity.rs:transactions; transaction.rs:impl_read_doc_for_tx.
    var list: am.types.ExId = undefined;
    var text: am.types.ExId = undefined;
    const base = try documentResult(tx_scenarios[0], txScopedBase(gpa, &doc, &list, &text));
    try documentResult(tx_scenarios[0], txScopedUpdate(gpa, &doc, text));
    const full_heads = try doc.getHeads(gpa);
    defer gpa.free(full_heads);
    try documentResult(tx_scenarios[0], txScopedCheck(gpa, io, records[indexes[0]].data, &doc, list, text, base, full_heads, seen, indexes[0]));
    try txOwnedStory(gpa, io, records[indexes[1]].data, &doc);
    try common.mark(seen, indexes[1]);
    try txClosureStories(gpa, io, records[indexes[2]].data, records[indexes[3]].data, &doc);
    try common.mark(seen, indexes[2]);
    try common.mark(seen, indexes[3]);
    try txNestedStory(gpa, io, records[indexes[4]].data);
    try common.mark(seen, indexes[4]);
    try txEqualHeadsStories(gpa, io, records[indexes[5]].data, records[indexes[6]].data);
    try common.mark(seen, indexes[5]);
    try common.mark(seen, indexes[6]);
}

fn txCheckRecord(records: []const common.Record, name: []const u8, count: usize) !usize {
    const index = try txRecord(records, name);
    const data = records[index].data;
    try std.testing.expect(data == .object);
    try std.testing.expectEqual(count, data.object.count());
    return index;
}

fn txScopedBase(gpa: Allocator, doc: *am.doc.Document, list: *am.types.ExId, text: *am.types.ExId) !am.types.ChangeHash {
    var tx = try am.Transaction.open(gpa, doc);
    defer tx.deinitClosed();
    _ = try tx.put(ROOT, .{ .key = "k" }, .{ .int = 1 });
    list.* = try tx.putObject(ROOT, .{ .key = "list" }, .list);
    _ = try tx.insert(list.*, 0, .{ .int = 1 });
    text.* = try tx.putObject(ROOT, .{ .key = "text" }, .text);
    try tx.spliceText(text.*, 0, 0, "old");
    return try txCommit(&tx, gpa);
}

fn txScopedUpdate(gpa: Allocator, doc: *am.doc.Document, text: am.types.ExId) !void {
    var tx = try am.Transaction.open(gpa, doc);
    defer tx.deinitClosed();
    _ = try tx.put(ROOT, .{ .key = "k" }, .{ .int = 2 });
    try tx.spliceText(text, 0, 3, "new");
    _ = try txCommit(&tx, gpa);
}

fn txScopedCheck(gpa: Allocator, io: std.Io, data: Value, doc: *am.doc.Document, list: am.types.ExId, text: am.types.ExId, base: am.types.ChangeHash, full_heads: []const am.types.ChangeHash, seen: []bool, index: usize) !void {
    var log = am.patches.PatchLog.active(gpa);
    defer log.deinit();
    var tx = try am.Transaction.openWithPatchLog(gpa, doc, &log, &.{base});
    defer tx.deinitClosed();
    _ = try tx.put(ROOT, .{ .key = "p" }, .{ .int = 3 });
    _ = try tx.insert(list, 1, .{ .int = 4 });
    try txExpectHash(gpa, try common.field(data, "base"), base);
    try common.expectHeads(gpa, try common.field(data, "full_heads"), full_heads);
    try txExpectField(gpa, data, "pending", tx.count());
    try txExpectScopedReaders(gpa, try common.field(data, "reads"), &tx, list, text, base, full_heads);
    var result = try tx.commitWith(.{ .time = 0 });
    defer result.deinit(gpa);
    try txExpectHash(gpa, try common.field(data, "hash"), result.hash);
    try common.expectSnapshot(gpa, io, try common.field(data, "committed"), doc);
    try txExpectPatches(gpa, try common.field(data, "patches"), doc, &result.patch_log);
    try common.mark(seen, index);
}

fn txOwnedStory(gpa: Allocator, io: std.Io, data: Value, doc: *am.doc.Document) !void {
    txOwnedStoryInner(gpa, io, data, doc) catch |failure| {
        documentFailure(tx_scenarios[1], failure);
        return failure;
    };
}

fn txOwnedStoryInner(gpa: Allocator, io: std.Io, data: Value, doc: *am.doc.Document) !void {
    // owned_transaction.rs:70-95; the open journal requires a stable final address.
    var copied = try doc.clone(gpa);
    var copied_live = true;
    defer if (copied_live) copied.deinit();
    var log = am.patches.PatchLog.active(gpa);
    defer log.deinit();
    var owned: am.transaction.OwnedTransaction = undefined;
    try owned.initWithPatchLog(gpa, &copied, &log, null);
    copied_live = false;
    defer owned.deinitClosed();
    _ = try owned.transaction.put(ROOT, .{ .key = "owned" }, .{ .bool_value = true });
    try txExpectTree(gpa, try common.field(data, "pending_read"), &owned.transaction);
    var committed = try owned.commit(.{ .time = 0 });
    defer committed.document.deinit();
    defer committed.result.deinit(gpa);
    try txExpectHash(gpa, try common.field(data, "hash"), committed.result.hash);
    try common.expectSnapshot(gpa, io, try common.field(data, "state"), &committed.document);
    try txExpectPatches(gpa, try common.field(data, "patches"), &committed.document, &committed.result.patch_log);
    var rollback_doc = try committed.document.clone(gpa);
    var rollback_doc_live = true;
    defer if (rollback_doc_live) rollback_doc.deinit();
    var rollback: am.transaction.OwnedTransaction = undefined;
    try rollback.init(gpa, &rollback_doc, null);
    rollback_doc_live = false;
    defer rollback.deinitClosed();
    _ = try rollback.transaction.put(ROOT, .{ .key = "discard" }, .{ .bool_value = true });
    var rolled = try rollback.rollback();
    defer rolled.document.deinit();
    defer rolled.patch_log.deinit();
    try txExpectField(gpa, data, "cancelled", rolled.cancelled);
    try common.expectSnapshot(gpa, io, try common.field(data, "rollback"), &rolled.document);
}

const TxClosure = struct {
    message: [64]u8 = undefined,
    observed_result: ?usize = null,

    fn rejected(_: void, tx: *am.Transaction) (am.transaction.TransactionError || error{ConsumerError})!void {
        _ = try tx.put(ROOT, .{ .key = "reject" }, .{ .bool_value = true });
        return error.ConsumerError;
    }

    fn accepted(_: *TxClosure, tx: *am.Transaction) am.transaction.TransactionError!usize {
        _ = try tx.put(ROOT, .{ .key = "accepted" }, .{ .bool_value = true });
        return 17;
    }

    fn options(ctx: *TxClosure, result: *const usize) am.transaction.CommitOptions {
        ctx.observed_result = result.*;
        const message = std.fmt.bufPrint(&ctx.message, "result:{d}", .{result.*}) catch unreachable;
        return .{ .time = 0, .message = message };
    }

    fn logged(_: void, tx: *am.Transaction) am.transaction.TransactionError!void {
        _ = try tx.put(ROOT, .{ .key = "logged" }, .{ .bool_value = true });
    }

    fn loggedOptions(_: void, _: *const void) am.transaction.CommitOptions {
        return .{ .time = 0 };
    }
};

fn txDisposeOutcome(outcome: anytype) void {
    switch (outcome.*) {
        .success => |*success| success.patch_log.deinit(),
        .failure => |*failure| {
            if (failure.transaction) |*tx| tx.deinitClosed();
            failure.patch_log.deinit();
        },
    }
}

fn txClosureStories(gpa: Allocator, io: std.Io, failed: Value, logged: Value, doc: *am.doc.Document) !void {
    var scenario = tx_scenarios[2];
    txClosureStoriesInner(gpa, io, failed, logged, doc, &scenario) catch |failure| {
        documentFailure(scenario, failure);
        return failure;
    };
}

fn txClosureStoriesInner(gpa: Allocator, io: std.Io, failed: Value, logged: Value, doc: *am.doc.Document, scenario: *[]const u8) !void {
    // automerge.rs:586-666; typed application errors retain their primary identity.
    try common.expectSnapshot(gpa, io, try common.field(failed, "before"), doc);
    var failure = try am.transaction.enclose(void, gpa, doc, {}, TxClosure.rejected);
    defer txDisposeOutcome(&failure);
    switch (failure) {
        .success => return error.ExpectedConsumerFailure,
        .failure => |*f| {
            try std.testing.expectEqual(error.ConsumerError, f.err);
            try std.testing.expect(f.rollback_error == null);
            try std.testing.expect(f.transaction == null);
            try std.testing.expect(f.result == null);
            try txExpectField(gpa, failed, "cancelled", f.cancelled);
            try std.testing.expectEqualStrings("consumer-error", try common.string(try common.field(failed, "error")));
        },
    }
    try common.expectSnapshot(gpa, io, try common.field(failed, "after_failure"), doc);
    var ctx: TxClosure = .{};
    var outcome = try am.transaction.encloseWith(usize, gpa, doc, &ctx, TxClosure.accepted, TxClosure.options);
    defer txDisposeOutcome(&outcome);
    switch (outcome) {
        .failure => return error.ExpectedClosureSuccess,
        .success => |*success| {
            try std.testing.expectEqual(success.result, ctx.observed_result.?);
            try txExpectField(gpa, failed, "result", success.result);
            try txExpectHash(gpa, try common.field(failed, "hash"), success.hash);
        },
    }
    try common.expectSnapshot(gpa, io, try common.field(failed, "state"), doc);
    scenario.* = tx_scenarios[3];
    var sink = am.patches.PatchLog.active(gpa);
    defer sink.deinit();
    var published = try am.transaction.encloseWithPatchLog(void, gpa, doc, &sink, {}, TxClosure.logged, TxClosure.loggedOptions);
    defer txDisposeOutcome(&published);
    switch (published) {
        .failure => return error.ExpectedLoggedSuccess,
        .success => |*success| {
            try std.testing.expect(!sink.recording);
            try std.testing.expect(success.patch_log.recording);
            try txExpectHash(gpa, try common.field(logged, "hash"), success.hash);
            try txExpectPatches(gpa, try common.field(logged, "patches"), doc, &success.patch_log);
        },
    }
    try common.expectSnapshot(gpa, io, try common.field(logged, "state"), doc);
}

fn txNestedStory(gpa: Allocator, io: std.Io, data: Value) !void {
    txNestedStoryInner(gpa, io, data) catch |failure| {
        documentFailure(tx_scenarios[4], failure);
        return failure;
    };
}

fn txNestedStoryInner(gpa: Allocator, io: std.Io, data: Value) !void {
    var doc = try txNewDocument(gpa, io);
    defer doc.deinit();
    var map: am.types.ExId = undefined;
    var list: am.types.ExId = undefined;
    var text: am.types.ExId = undefined;
    {
        var tx = try am.Transaction.open(gpa, &doc);
        defer tx.deinitClosed();
        map = try tx.putObject(ROOT, .{ .key = "nested" }, .map);
        _ = try tx.put(map, .{ .key = "value" }, .{ .int = 1 });
        list = try tx.putObject(ROOT, .{ .key = "sequence" }, .list);
        _ = try tx.insert(list, 0, .{ .int = 2 });
        text = try tx.putObject(ROOT, .{ .key = "text" }, .text);
        try tx.spliceText(text, 0, 0, "old");
        _ = try txCommit(&tx, gpa);
    }
    const historical = try doc.getHeads(gpa);
    defer gpa.free(historical);
    try common.expectHeads(gpa, try common.field(data, "heads"), historical);
    {
        var tx = try am.Transaction.open(gpa, &doc);
        defer tx.deinitClosed();
        _ = try tx.put(map, .{ .key = "value" }, .{ .int = 9 });
        _ = try tx.put(list, .{ .index = 0 }, .{ .int = 8 });
        try tx.spliceText(text, 0, 3, "new");
        _ = try txCommit(&tx, gpa);
    }
    try txExpectTree(gpa, try common.field(data, "full"), &doc);
    var tx = try am.Transaction.openAt(gpa, &doc, historical);
    defer tx.deinitClosed();
    try tx.spliceText(text, 3, 0, "!");
    try txExpectField(gpa, data, "pending_before", tx.count());
    try txExpectTree(gpa, try common.field(data, "projected"), &tx);
    try txExpectField(gpa, data, "pending_after", tx.count());
    _ = try tx.rollback();
}

fn txEqualHeadsStories(gpa: Allocator, io: std.Io, scoped: Value, unscoped: Value) !void {
    var scenario = tx_scenarios[5];
    txEqualHeadsStoriesInner(gpa, io, scoped, unscoped, &scenario) catch |failure| {
        documentFailure(scenario, failure);
        return failure;
    };
}

fn txEqualHeadsStoriesInner(gpa: Allocator, io: std.Io, scoped: Value, unscoped: Value, scenario: *[]const u8) !void {
    // Ordinary historical reads exclude pending rows, including at current heads.
    // Hydrate's matching-current-head optimization is a distinct upstream contract.
    var doc = try txNewDocument(gpa, io);
    defer doc.deinit();
    {
        var tx = try am.Transaction.open(gpa, &doc);
        defer tx.deinitClosed();
        _ = try tx.put(ROOT, .{ .key = "old" }, .{ .int = 1 });
        _ = try txCommit(&tx, gpa);
    }
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    {
        var tx = try am.Transaction.openAt(gpa, &doc, heads);
        defer tx.deinitClosed();
        _ = try tx.put(ROOT, .{ .key = "pending" }, .{ .int = 2 });
        var keys = try tx.keysAt(ROOT, heads);
        defer keys.deinit(gpa);
        const historical = try tx.getAt(ROOT, .{ .key = "pending" }, heads);
        const empty = try tx.getAt(ROOT, .{ .key = "old" }, &.{});
        try txReadExpectOptional(gpa, try common.field(scoped, "historical_pending"), historical);
        try txReadExpectOptional(gpa, try common.field(scoped, "empty_heads"), empty);
        try txReadExpectKeys(gpa, try common.field(scoped, "retained_historical_keys"), &keys);
        try common.expectHeads(gpa, try common.field(scoped, "heads"), heads);
        try txExpectTree(gpa, try common.field(scoped, "current"), &tx);
        try txExpectField(gpa, scoped, "pending", tx.count());
        var hydrated = try tx.hydrate(ROOT, null, gpa);
        defer hydrated.deinit();
        var at = try tx.hydrate(ROOT, heads, gpa);
        defer at.deinit();
        try common.expectHydrated(gpa, try common.field(scoped, "hydrate_null"), &hydrated);
        try common.expectHydrated(gpa, try common.field(scoped, "hydrate_historical"), &at);
        _ = try tx.rollback();
    }
    {
        scenario.* = tx_scenarios[6];
        var tx = try am.Transaction.open(gpa, &doc);
        defer tx.deinitClosed();
        _ = try tx.put(ROOT, .{ .key = "pending" }, .{ .int = 2 });
        try common.expectHeads(gpa, try common.field(unscoped, "heads"), heads);
        try txExpectTree(gpa, try common.field(unscoped, "current"), &tx);
        try txReadExpectOptional(gpa, try common.field(unscoped, "get_at_pending"), try tx.getAt(ROOT, .{ .key = "pending" }, heads));
        var hydrated = try tx.hydrate(ROOT, null, gpa);
        defer hydrated.deinit();
        var at = try tx.hydrate(ROOT, heads, gpa);
        defer at.deinit();
        try common.expectHydrated(gpa, try common.field(unscoped, "hydrate_null"), &hydrated);
        try common.expectHydrated(gpa, try common.field(unscoped, "pending_hydrate_same_heads"), &at);
        _ = try tx.rollback();
    }
}

// tools/oracle/src/api_parity.rs:378 (loads); upstream automerge.rs:855-1030,
// 1973-2020. All input bytes below are loaded by the native public surface.
const loadCanonicalActorBytes: [16]u8 = @splat(0xb2);

fn loadRefusal(expected: Value, result: am.doc.LoadError!am.doc.Document, expected_native: am.doc.LoadError) !void {
    errdefer std.debug.print("api-parity load refusal expected-native={s}\n", .{@errorName(expected_native)});
    if (result) |loaded| {
        var unexpected = loaded;
        defer unexpected.deinit();
        return error.ExpectedLoadRefusal;
    } else |actual| {
        try std.testing.expectEqual(expected_native, actual);
    }
    // api_parity.rs:109-125,346-347 projects only the public error variant.
    // Upstream error.rs:57-58 wraps the private loader error in AutomergeError::Load.
    // There is no error_debug member in this semantic envelope.
    try loadFields(expected, &.{ "outcome", "class" });
    try std.testing.expectEqualStrings("error", try common.string(try common.field(expected, "outcome")));
    try std.testing.expectEqualStrings("Load", try common.string(try common.field(expected, "class")));
    // Public Rust AutomergeError::Load wraps private storage error variants.
    // Exact native MissingHash/LengthExceedsInput/InvalidChecksum/InvalidMarkOrder
    // above remain mandatory independently for the four actual malformed inputs.
    // Native private causes are still compared exactly, not normalized to Load.
}

pub fn verifyLoads(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    const scenarios = [_][]const u8{
        "load-unverified-mismatching-heads", "load-partial-checksum",
        "load-string-migration-author",      "load-rescue-broken-mark",
    };
    var found: [scenarios.len]bool = @splat(false);
    for (records, 0..) |record, record_index| {
        if (!std.mem.startsWith(u8, record.scenario, "load-")) continue;
        try documentResult(record.scenario, verifyLoadRecord(gpa, io, record, record_index, &scenarios, &found, seen));
    }
    for (found) |present| try std.testing.expect(present);
}

fn verifyLoadRecord(gpa: Allocator, io: std.Io, record: common.Record, record_index: usize, scenarios: []const []const u8, found: []bool, seen: []bool) !void {
    try std.testing.expectEqualStrings("api-parity", record.kind);
    const scenario_index = for (scenarios, 0..) |scenario, index| {
        if (std.mem.eql(u8, scenario, record.scenario)) break index;
    } else return error.UnknownLoadScenario;
    try std.testing.expect(!found[scenario_index]);
    switch (scenario_index) {
        0 => try loadUnverified(gpa, io, record.data),
        1 => try loadPartial(gpa, io, record.data),
        2 => try loadMigration(gpa, io, record.data),
        3 => try loadRescue(gpa, io, record.data),
        else => unreachable,
    }
    found[scenario_index] = true;
    try common.mark(seen, record_index);
}

fn loadFields(value: Value, names: []const []const u8) !void {
    if (value != .object) return error.ExpectedObject;
    errdefer {
        std.debug.print("api-parity load fields expected={d} actual={d}\n", .{ names.len, value.object.count() });
        var entries = value.object.iterator();
        while (entries.next()) |entry| {
            std.debug.print("api-parity load field present={s}\n", .{entry.key_ptr.*});
        }
        for (names) |name| {
            if (value.object.get(name) == null)
                std.debug.print("api-parity load field missing={s}\n", .{name});
        }
    }
    try std.testing.expectEqual(names.len, value.object.count());
    for (names) |name| _ = try common.field(value, name);
}

fn loadTree(gpa: Allocator, expected: Value, doc: *const am.doc.Document) !void {
    const json = try am.autoserde.AutoSerde(am.doc.Document).from(doc).toJson(gpa);
    defer gpa.free(json);
    try common.expectJsonText(gpa, expected, json);
}

fn loadUncheckedState(gpa: Allocator, expected: Value, doc: *am.doc.Document) !void {
    try loadFields(expected, &.{"ok"});
    const state = try common.field(expected, "ok");
    try loadFields(state, &.{ "value", "heads" });
    try loadTree(gpa, try common.field(state, "value"), doc);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try common.expectHeads(gpa, try common.field(state, "heads"), heads);
    // Intentional exception: unchecked stored heads do not necessarily name a
    // graph node. Rust change_graph.rs:141-144 unwraps those names during save.
    // Observe tree and heads directly; never call save/expectSnapshot here.
}

fn loadOk(gpa: Allocator, io: std.Io, expected: Value, doc: *am.doc.Document) !void {
    try loadFields(expected, &.{"ok"});
    try common.expectSnapshot(gpa, io, try common.field(expected, "ok"), doc);
}

fn loadAuthor(expected: Value, actual: ?[]const u8) !void {
    if (actual) |bytes| {
        const encoded = try common.string(expected);
        try std.testing.expectEqual(bytes.len * 2, encoded.len);
        for (bytes, 0..) |byte, index| {
            const want = try std.fmt.parseInt(u8, encoded[index * 2 ..][0..2], 16);
            try std.testing.expectEqual(want, byte);
        }
    } else try std.testing.expect(expected == .null);
}

fn loadUnverified(gpa: Allocator, io: std.Io, data: Value) !void {
    try loadFields(data, &.{ "input_hex", "check", "unverified", "dont_check" });
    const bytes = try common.unhex(gpa, try common.string(try common.field(data, "input_hex")));
    defer gpa.free(bytes);
    try loadRefusal(try common.field(data, "check"), am.doc.Document.load(gpa, io, bytes, .unicode_code_point), error.MissingHash);
    var unverified = try am.doc.Document.loadUnverifiedHeads(gpa, io, bytes, .{});
    defer unverified.deinit();
    try loadUncheckedState(gpa, try common.field(data, "unverified"), &unverified);
    var dont_check = try am.doc.Document.loadWithOptions(gpa, io, bytes, .{
        .verification_mode = .dont_check,
    });
    defer dont_check.deinit();
    try loadUncheckedState(gpa, try common.field(data, "dont_check"), &dont_check);
}

fn loadPartial(gpa: Allocator, io: std.Io, data: Value) !void {
    try loadFields(data, &.{ "input_hex", "change_first_hex", "refuse", "ignore", "change_first_ignore", "unverified_valid", "checksum_hex", "checksum_unverified", "active_load_patches", "incremental_count", "incremental" });
    const stream = try common.unhex(gpa, try common.string(try common.field(data, "input_hex")));
    defer gpa.free(stream);
    const change_first = try common.unhex(gpa, try common.string(try common.field(data, "change_first_hex")));
    defer gpa.free(change_first);
    try loadRefusal(try common.field(data, "refuse"), am.doc.Document.load(gpa, io, stream, .unicode_code_point), error.LengthExceedsInput);
    var ignored = try am.doc.Document.loadWithOptions(gpa, io, stream, .{ .on_partial_load = .ignore });
    defer ignored.deinit();
    try loadOk(gpa, io, try common.field(data, "ignore"), &ignored);
    // Ignore discards the WHOLE decoded tail, including its complete changes,
    // unlike incremental loading below (automerge.rs:974-999).
    try std.testing.expect((try am.read.get(&ignored, ROOT, .{ .key = "tail" })) == null);
    try std.testing.expect((try am.read.get(&ignored, ROOT, .{ .key = "partial" })) == null);
    var empty = try am.doc.Document.loadWithOptions(gpa, io, change_first, .{ .on_partial_load = .ignore });
    defer empty.deinit();
    try loadOk(gpa, io, try common.field(data, "change_first_ignore"), &empty);
    try std.testing.expect(empty.isEmpty());

    const valid_result = try common.field(data, "unverified_valid");
    try loadFields(valid_result, &.{"ok"});
    const valid = try common.field(valid_result, "ok");
    const base = try common.unhex(gpa, try common.string(try common.field(valid, "save_hex")));
    defer gpa.free(base);
    var unverified_valid = try am.doc.Document.loadUnverifiedHeads(gpa, io, base, .{});
    defer unverified_valid.deinit();
    try loadOk(gpa, io, valid_result, &unverified_valid);
    // Reference saves are semantic inputs: DEFLATE byte identity is excluded.
    try common.expectSnapshot(gpa, io, valid, &ignored);
    const checksum = try common.unhex(gpa, try common.string(try common.field(data, "checksum_hex")));
    defer gpa.free(checksum);
    try loadRefusal(try common.field(data, "checksum_unverified"), am.doc.Document.loadUnverifiedHeads(gpa, io, checksum, .{}), error.InvalidChecksum);
    var log = am.patches.PatchLog.active(gpa);
    defer log.deinit();
    var logged = try am.doc.Document.loadWithOptions(gpa, io, base, .{ .patch_log = &log });
    defer logged.deinit();
    try common.expectSnapshot(gpa, io, valid, &logged);
    var patches = try logged.makePatches(&log);
    defer patches.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(data, "active_load_patches"), patches.slice());
    var incremental = try am.doc.Document.load(gpa, io, base, .unicode_code_point);
    defer incremental.deinit();
    try std.testing.expectEqual(try common.integer(usize, try common.field(data, "incremental_count")), try incremental.loadIncremental(gpa, stream));
    try common.expectSnapshot(gpa, io, try common.field(data, "incremental"), &incremental);
}

fn loadReplaceId(id: *am.change_record.ExpandedOpId, old: am.types.ActorId, replacement: am.types.ActorId) void {
    if (id.actor.eql(old)) id.actor = replacement;
}

fn loadIdLess(_: void, left: am.change_record.ExpandedOpId, right: am.change_record.ExpandedOpId) bool {
    if (left.counter != right.counter) return left.counter < right.counter;
    return std.mem.order(u8, left.actor.bytes, right.actor.bytes) == .lt;
}

fn loadReplaceActor(change: *am.change_record.ExpandedChange) void {
    // Exact public legacy conversion from api_parity.rs:337 (replace_actor). The random
    // migration actor is normalized only after actual native migration/decode.
    const replacement: am.types.ActorId = .{ .bytes = &loadCanonicalActorBytes };
    const old = change.actor;
    change.actor = replacement;
    for (@constCast(change.ops)) |*op| {
        switch (op.obj) {
            .root => {},
            .id => |*id| loadReplaceId(id, old, replacement),
        }
        switch (op.key) {
            .map => {},
            .seq => |*element| switch (element.*) {
                .head => {},
                .id => |*id| loadReplaceId(id, old, replacement),
            },
        }
        const predecessors = @constCast(op.pred);
        for (predecessors) |*id| loadReplaceId(id, old, replacement);
        std.mem.sort(am.change_record.ExpandedOpId, predecessors, {}, loadIdLess);
    }
    change.hash = null;
}

fn loadMigration(gpa: Allocator, io: std.Io, data: Value) !void {
    try loadFields(data, &.{ "input_hex", "value", "author", "base_change_count", "migration_author", "migration_op_count", "normalized_equal", "canonical_migration", "canonical_hex", "canonical_hash", "next", "next_author", "object_type" });
    const input = try common.unhex(gpa, try common.string(try common.field(data, "input_hex")));
    defer gpa.free(input);
    var source = try am.doc.Document.load(gpa, io, input, .unicode_code_point);
    defer source.deinit();
    var base_changes = try source.getChanges(gpa, &.{});
    defer base_changes.deinit(gpa);
    try std.testing.expectEqual(try common.integer(usize, try common.field(data, "base_change_count")), base_changes.len());
    const author = [_]u8{ 0xff, 0x00, 0x80 };
    var migrated = try am.doc.Document.loadWithOptions(gpa, io, input, .{
        .string_migration = .convert_to_text,
        .author = &author,
    });
    defer migrated.deinit();
    try loadTree(gpa, try common.field(data, "value"), &migrated);
    try loadAuthor(try common.field(data, "author"), migrated.getAuthor());
    var all = try migrated.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    try std.testing.expectEqual(base_changes.len() + 1, all.len());
    const migration = all.at(all.len() - 1);
    try loadAuthor(try common.field(data, "migration_author"), try migration.author(gpa));
    // Author assignment occurs after migration; the actual migration footer is
    // absent, while the next committed change must carry ff0080.
    try std.testing.expect((try migration.author(gpa)) == null);
    try std.testing.expectEqual(try common.integer(usize, try common.field(data, "migration_op_count")), try migration.len(gpa));
    var expanded = try migration.decode(gpa);
    defer expanded.deinit(gpa);
    loadReplaceActor(&expanded);
    var canonical = try expanded.encode(gpa);
    defer canonical.deinit(gpa);
    var decoded = try canonical.change.decode(gpa);
    defer decoded.deinit(gpa);
    const canonical_json = try std.json.Stringify.valueAlloc(gpa, decoded, .{});
    defer gpa.free(canonical_json);
    try common.expectJsonText(gpa, try common.field(data, "canonical_migration"), canonical_json);
    const canonical_expected = try common.unhex(gpa, try common.string(try common.field(data, "canonical_hex")));
    defer gpa.free(canonical_expected);
    const canonical_bytes = try canonical.change.rawBytes(gpa);
    defer gpa.free(canonical_bytes);
    try std.testing.expectEqualSlices(u8, canonical_expected, canonical_bytes);
    const hash_json = try std.json.Stringify.valueAlloc(gpa, canonical.change.hash, .{});
    defer gpa.free(hash_json);
    try common.expectJsonText(gpa, try common.field(data, "canonical_hash"), hash_json);
    var normalized = try am.doc.Document.load(gpa, io, input, .unicode_code_point);
    defer normalized.deinit();
    _ = try normalized.applyChanges(gpa, &.{canonical.change});
    const migrated_json = try am.autoserde.AutoSerde(am.doc.Document).from(&migrated).toJson(gpa);
    defer gpa.free(migrated_json);
    const normalized_json = try am.autoserde.AutoSerde(am.doc.Document).from(&normalized).toJson(gpa);
    defer gpa.free(normalized_json);
    var migrated_value = try std.json.parseFromSlice(Value, gpa, migrated_json, .{});
    defer migrated_value.deinit();
    try common.expectJsonText(gpa, migrated_value.value, normalized_json);
    try std.testing.expect(try common.boolean(try common.field(data, "normalized_equal")));
    const nested = (try am.read.get(&migrated, ROOT, .{ .key = "nested" })) orelse return error.MissingNested;
    const text = (try am.read.get(&migrated, nested.id, .{ .key = "s" })) orelse return error.MissingText;
    try std.testing.expectEqual(am.types.ObjType.text, try am.read.objectType(&migrated, text.id));
    try std.testing.expectEqualStrings("text", try common.string(try common.field(data, "object_type")));
    try normalized.setAuthor(gpa, &author);
    normalized.setActorId(.{ .bytes = &.{ 0xc3, 0xc3 } });
    {
        var tx = try am.Transaction.open(gpa, &normalized);
        // On a failed assertion/mutation this fresh local document dies directly
        // after journal cleanup, so no rollback-recovery owner can escape.
        defer tx.deinitClosed();
        _ = try tx.put(ROOT, .{ .key = "next" }, .{ .bool_value = true });
        var committed = try tx.commitWith(.{ .time = 0 });
        defer committed.deinit(gpa);
    }
    try common.expectSnapshot(gpa, io, try common.field(data, "next"), &normalized);
    var next_changes = try normalized.getChanges(gpa, &.{});
    defer next_changes.deinit(gpa);
    try loadAuthor(try common.field(data, "next_author"), try next_changes.at(next_changes.len() - 1).author(gpa));
}

fn loadRescue(gpa: Allocator, io: std.Io, data: Value) !void {
    try loadFields(data, &.{ "fixture", "input_hex", "strict", "rescue" });
    try std.testing.expectEqualStrings("broken_zero_width_mark.automerge", try common.string(try common.field(data, "fixture")));
    const bytes = try common.unhex(gpa, try common.string(try common.field(data, "input_hex")));
    defer gpa.free(bytes);
    try loadRefusal(try common.field(data, "strict"), am.doc.Document.load(gpa, io, bytes, .unicode_code_point), error.InvalidMarkOrder);
    var rescued = try am.doc.Document.rescue(gpa, io, bytes);
    defer rescued.deinit();
    const expected = try common.field(data, "rescue");
    try loadFields(expected, &.{"ok"});
    try common.expectHydrated(gpa, try common.field(expected, "ok"), &rescued.value);
}

// Lifecycle scripts mirror tools/oracle/src/api_parity.rs::lifecycle (Rust 0.12.0).
// Source strings are provenance, not native behavior assertions.
const life_actor_a: [15]u8 = @splat(0xa1);
const life_actor_b: [16]u8 = @splat(0xb2);
const life_scenarios = [_][]const u8{
    "held-clone-rollback",     "empty-change-closes-pending", "isolation-hydrate-null",
    "barrier-map",             "diff-owned-repeat",           "isolated-ordered-patches",
    "has-our-changes-ordered", "isolated-list-boundary",
};
const life_routes = [_][]const u8{
    "read",            "hydrate",          "trait-missing", "inherent-missing", "trait-change",
    "inherent-change", "heads",            "history",       "save",             "save-incremental",
    "save-after",      "save-verify",      "fork",          "actor",            "author",
    "diff",            "diff-incremental", "reset-diff",    "update-diff",      "apply",
    "merge",           "load-incremental", "isolate",       "integrate",        "sync",
    "has-our-changes",
};

pub fn verifyLifecycle(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    var indices: [life_scenarios.len]usize = undefined;
    for (life_scenarios, 0..) |scenario, slot| {
        var found: ?usize = null;
        for (records, 0..) |row, index| {
            if (!std.mem.eql(u8, row.scenario, scenario)) continue;
            try std.testing.expectEqualStrings("api-parity", row.kind);
            try std.testing.expect(found == null);
            found = index;
        }
        indices[slot] = found orelse return error.MissingLifecycleScenario;
    }
    try lifeHeld(gpa, io, records[indices[0]].data, records[indices[1]].data);
    try common.mark(seen, indices[0]);
    try common.mark(seen, indices[1]);
    try lifeIsolation(gpa, io, records[indices[2]].data);
    try common.mark(seen, indices[2]);
    try lifeBarriersAndDiff(gpa, io, records[indices[3]].data, records[indices[4]].data);
    try common.mark(seen, indices[3]);
    try common.mark(seen, indices[4]);
    try lifeOrderedPatches(gpa, io, records[indices[5]].data);
    try common.mark(seen, indices[5]);
    try lifeHasOurChanges(gpa, io, records[indices[6]].data);
    try common.mark(seen, indices[6]);
    try lifeListBoundary(gpa, io, records[indices[7]].data);
    try common.mark(seen, indices[7]);
}

fn lifeFields(value: Value, names: []const []const u8) !void {
    if (value != .object) return error.ExpectedLifecycleObject;
    try std.testing.expectEqual(names.len, value.object.count());
    for (names) |name| _ = try common.field(value, name);
}

fn lifeNumber(data: Value, name: []const u8, actual: usize) !void {
    errdefer std.debug.print("api-parity lifecycle field={s} actual={d}\n", .{ name, actual });
    try std.testing.expectEqual(try common.integer(usize, try common.field(data, name)), actual);
}

fn lifeBool(data: Value, name: []const u8, actual: bool) !void {
    try std.testing.expectEqual(try common.boolean(try common.field(data, name)), actual);
}

fn lifeHash(expected: Value, actual: am.types.ChangeHash) !void {
    const text = try common.string(expected);
    try std.testing.expectEqual(@as(usize, 64), text.len);
    var bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, text);
    try std.testing.expectEqualSlices(u8, &bytes, &actual.bytes);
}

fn lifeOptionalHash(expected: Value, actual: ?am.types.ChangeHash) !void {
    if (expected == .null) {
        try std.testing.expect(actual == null);
    } else {
        try lifeHash(expected, actual orelse return error.MissingLifecycleHash);
    }
}

fn lifeAuto(gpa: Allocator, io: std.Io) !am.AutoCommit {
    var doc = try am.AutoCommit.initWithEncoding(gpa, io, .unicode_code_point);
    errdefer doc.deinit();
    try doc.setActorId(.{ .bytes = &life_actor_a });
    return doc;
}

fn lifeTree(gpa: Allocator, expected: Value, doc: *am.AutoCommit) !void {
    const json = try am.autoserde.AutoSerde(am.AutoCommit).from(doc).toJson(gpa);
    defer gpa.free(json);
    try common.expectJsonText(gpa, expected, json);
}

fn lifeHeads(gpa: Allocator, expected: Value, doc: *am.AutoCommit) !void {
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try lifeOrderedHeads(gpa, expected, heads);
}

fn lifeOrderedHeads(gpa: Allocator, expected: Value, actual: []const am.types.ChangeHash) !void {
    try common.expectHeads(gpa, expected, actual);
    const ordered = try common.array(expected);
    try std.testing.expectEqual(ordered.len, actual.len);
    for (ordered, actual) |hash, native_hash| try lifeHash(hash, native_hash);
}

fn lifeItem(gpa: Allocator, expected: Value, actual: ?am.read.DocItem) !void {
    try common.expectDocItem(gpa, expected, actual);
}

fn lifeHeld(gpa: Allocator, io: std.Io, held: Value, empty: Value) !void {
    var scenario = life_scenarios[0];
    lifeHeldInner(gpa, io, held, empty, &scenario) catch |failure| {
        documentFailure(scenario, failure);
        return failure;
    };
}

fn lifeHeldInner(gpa: Allocator, io: std.Io, held: Value, empty: Value, scenario: *[]const u8) !void {
    // autocommit.rs:63-70,704-772: pending clones keep two independent journals.
    try lifeFields(held, &.{ "pending", "read", "clone_pending", "source_pending_after_clone", "clone_cancelled", "clone_value", "source_value", "hash", "empty_commit", "history_len", "change_hex" });
    try lifeFields(empty, &.{ "hash", "history_len", "op_counts", "value" });
    var doc = try lifeAuto(gpa, io);
    defer doc.deinit();
    _ = try doc.put(ROOT, .{ .key = "a" }, .{ .int = 1 });
    _ = try doc.put(ROOT, .{ .key = "b" }, .{ .int = 2 });
    try lifeNumber(held, "pending", doc.pendingOps());
    try lifeTree(gpa, try common.field(held, "read"), &doc);
    var copy: am.AutoCommit = undefined;
    try doc.cloneInto(gpa, &copy);
    defer copy.deinit();
    // cloneInto initializes the held journal at this address; never move copy afterward.
    try lifeNumber(held, "clone_pending", copy.pendingOps());
    try lifeNumber(held, "source_pending_after_clone", doc.pendingOps());
    try lifeNumber(held, "clone_cancelled", try copy.rollback());
    try lifeOptionalHash(try common.field(held, "hash"), try doc.commitWith(.{ .time = 0 }));
    try lifeOptionalHash(try common.field(held, "empty_commit"), try doc.commitWith(.{ .time = 0 }));
    var history = try doc.getChanges(gpa, &.{});
    defer history.deinit(gpa);
    try lifeNumber(held, "history_len", history.len());
    const raw_changes = try common.array(try common.field(held, "change_hex"));
    try std.testing.expectEqual(raw_changes.len, history.len());
    for (raw_changes, history.slice()) |expected, change| {
        // change.rs:118-120 raw_bytes includes framing, Built.body does not.
        var framed: std.ArrayList(u8) = .empty;
        defer framed.deinit(gpa);
        try am.storage.chunk.writeChunk(&framed, gpa, .change, change.body);
        const bytes = try common.unhex(gpa, try common.string(expected));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, bytes, framed.items);
    }
    try lifeTree(gpa, try common.field(held, "clone_value"), &copy);
    try lifeTree(gpa, try common.field(held, "source_value"), &doc);
    scenario.* = life_scenarios[1];
    _ = try doc.put(ROOT, .{ .key = "c" }, .{ .int = 3 });
    try lifeHash(try common.field(empty, "hash"), try doc.emptyChange(.{ .time = 0 }));
    var all = try doc.getChangesMeta(gpa, &.{});
    defer all.deinit(gpa);
    try lifeNumber(empty, "history_len", all.items.items.len);
    const counts = try common.array(try common.field(empty, "op_counts"));
    try std.testing.expectEqual(counts.len, all.items.items.len);
    for (counts, all.items.items) |count, meta| {
        errdefer std.debug.print("api-parity lifecycle field=op_counts\n", .{});
        try std.testing.expectEqual(try common.integer(u64, count), meta.max_op + 1 - meta.start_op);
    }
    try lifeTree(gpa, try common.field(empty, "value"), &doc);
}

fn lifeIsolation(gpa: Allocator, io: std.Io, data: Value) !void {
    lifeIsolationInner(gpa, io, data) catch |failure| {
        documentFailure(life_scenarios[2], failure);
        return failure;
    };
}

fn lifeIsolationInner(gpa: Allocator, io: std.Io, data: Value) !void {
    // autocommit.rs:433-443,827-829: hydrate(None) bypasses isolation without closing.
    try lifeFields(data, &.{ "h1", "h2", "isolated_heads", "has_full_changes", "scoped_serde", "explicit_pending", "hydrate_null", "hydrate_historical", "pending_before_integrate", "pending_after_integrate", "value", "heads" });
    var doc = try lifeAuto(gpa, io);
    defer doc.deinit();
    _ = try doc.put(ROOT, .{ .key = "k" }, .{ .int = 1 });
    const h1 = (try doc.commitWith(.{ .time = 0 })) orelse return error.MissingLifecycleHash;
    _ = try doc.put(ROOT, .{ .key = "k" }, .{ .int = 2 });
    const h2 = (try doc.commitWith(.{ .time = 0 })) orelse return error.MissingLifecycleHash;
    try lifeHash(try common.field(data, "h1"), h1);
    try lifeHash(try common.field(data, "h2"), h2);
    try doc.isolate(gpa, &.{h1});
    try lifeHeads(gpa, try common.field(data, "isolated_heads"), &doc);
    var state = am.sync.state.State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(am.types.ChangeHash, &.{h2});
    try lifeBool(data, "has_full_changes", try doc.hasOurChanges(&state));
    _ = try doc.put(ROOT, .{ .key = "p" }, .{ .int = 3 });
    try lifeTree(gpa, try common.field(data, "scoped_serde"), &doc);
    try lifeItem(gpa, try common.field(data, "explicit_pending"), try doc.getAt(ROOT, .{ .key = "p" }, &.{h1}));
    var current = try doc.hydrate(ROOT, null, gpa);
    defer current.deinit();
    var historical = try doc.hydrate(ROOT, &.{h1}, gpa);
    defer historical.deinit();
    try common.expectHydrated(gpa, try common.field(data, "hydrate_null"), &current);
    try common.expectHydrated(gpa, try common.field(data, "hydrate_historical"), &historical);
    try lifeNumber(data, "pending_before_integrate", doc.pendingOps());
    try doc.integrate();
    try lifeNumber(data, "pending_after_integrate", doc.pendingOps());
    try lifeTree(gpa, try common.field(data, "value"), &doc);
    try lifeHeads(gpa, try common.field(data, "heads"), &doc);
}

fn lifeBarrier(gpa: Allocator, io: std.Io, route: usize, doc: *am.AutoCommit) !void {
    const Reader = am.read.ReadDoc(am.AutoCommit);
    switch (route) {
        0 => {
            _ = try doc.get(ROOT, .{ .key = "pending" });
        },
        1 => {
            var value = try doc.hydrate(ROOT, null, gpa);
            defer value.deinit();
        },
        2 => {
            const deps = try Reader.getMissingDeps(doc, &.{}, gpa);
            defer gpa.free(deps);
        },
        3 => {
            const deps = try doc.getMissingDeps(gpa, &.{});
            defer gpa.free(deps);
        },
        4 => {
            if (try Reader.getChangeByHash(doc, .zero, gpa)) |owned| {
                var change = owned;
                defer change.deinit(gpa);
            }
        },
        5 => {
            if (try doc.getChangeByHash(gpa, .zero)) |owned| {
                var change = owned;
                defer change.deinit(gpa);
            }
        },
        6 => {
            const heads = try doc.getHeads(gpa);
            defer gpa.free(heads);
        },
        7 => {
            var changes = try doc.getChanges(gpa, &.{});
            defer changes.deinit(gpa);
        },
        8, 9, 10, 11 => {
            const bytes = switch (route) {
                8 => try doc.save(gpa),
                9 => try doc.saveIncremental(gpa),
                10 => try doc.saveAfter(gpa, &.{}),
                11 => try doc.saveAndVerify(gpa),
                else => unreachable,
            };
            defer gpa.free(bytes);
        },
        12 => {
            var fork = try doc.fork(gpa);
            defer fork.deinit();
        },
        13 => try doc.setActorId(.{ .bytes = &life_actor_b }),
        14 => try doc.setAuthor(gpa, &.{ 0, 255, 128 }),
        15 => {
            var patches = try doc.diff(gpa, &.{}, &.{});
            defer patches.deinit();
        },
        16 => {
            var patches = try doc.diffIncremental(gpa);
            defer patches.deinit();
        },
        17 => try doc.resetDiffCursor(),
        18 => try doc.updateDiffCursor(),
        19 => {
            _ = try doc.applyChanges(gpa, &.{});
        },
        20 => {
            var other = try lifeAuto(gpa, io);
            defer other.deinit();
            const heads = try doc.merge(gpa, &other);
            defer gpa.free(heads);
        },
        21 => {
            _ = try doc.loadIncremental(gpa, &.{});
        },
        22 => try doc.isolate(gpa, &.{}),
        23 => try doc.integrate(),
        24 => {
            var state = am.sync.state.State.new(gpa);
            defer state.deinit();
            const sync = try doc.sync();
            if (try sync.generateSyncMessage(gpa, &state)) |owned| {
                var message = owned;
                defer message.deinit();
            }
        },
        25 => {
            var state = am.sync.state.State.new(gpa);
            defer state.deinit();
            _ = try doc.hasOurChanges(&state);
        },
        else => unreachable,
    }
}

fn lifeBarriersAndDiff(gpa: Allocator, io: std.Io, barriers: Value, repeated: Value) !void {
    var scenario = life_scenarios[3];
    lifeBarriersAndDiffInner(gpa, io, barriers, repeated, &scenario) catch |failure| {
        documentFailure(scenario, failure);
        return failure;
    };
}

fn lifeBarriersAndDiffInner(gpa: Allocator, io: std.Io, barriers: Value, repeated: Value, scenario: *[]const u8) !void {
    // autocommit.rs:184-215,254,356-411,609-632,827-829: trait reads are nonclosing.
    const cases = try common.array(barriers);
    try std.testing.expectEqual(life_routes.len, cases.len);
    try lifeFields(repeated, &.{ "hash", "same", "second_len_after_first_clear", "patches" });
    var source = try lifeAuto(gpa, io);
    defer source.deinit();
    _ = try source.put(ROOT, .{ .key = "pending" }, .{ .bool_value = true });
    for (cases, life_routes, 0..) |data, name, route| {
        errdefer std.debug.print("api-parity barrier route={s}\n", .{name});
        try lifeFields(data, &.{ "route", "pending", "value", "changes" });
        try std.testing.expectEqualStrings(name, try common.string(try common.field(data, "route")));
        var doc: am.AutoCommit = undefined;
        try source.cloneInto(gpa, &doc);
        defer doc.deinit();
        try lifeBarrier(gpa, io, route, &doc);
        try lifeNumber(data, "pending", doc.pendingOps());
        try lifeTree(gpa, try common.field(data, "value"), &doc);
        // Read the value before history: this intentionally closes nonclosing cases only now.
        var history = try doc.getChangesMeta(gpa, &.{});
        defer history.deinit(gpa);
        const changes = try common.array(try common.field(data, "changes"));
        {
            errdefer std.debug.print("api-parity barrier field=changes.length\n", .{});
            try std.testing.expectEqual(changes.len, history.items.items.len);
        }
        for (changes, history.items.items) |expected, meta| {
            try lifeFields(expected, &.{ "hash", "actor", "time" });
            try lifeHash(try common.field(expected, "hash"), meta.hash);
            const actor = try common.unhex(gpa, try common.string(try common.field(expected, "actor")));
            defer gpa.free(actor);
            try std.testing.expectEqualSlices(u8, actor, meta.actor.bytes);
            try std.testing.expectEqual(try common.integer(i64, try common.field(expected, "time")), meta.timestamp);
        }
    }
    scenario.* = life_scenarios[4];
    const hash = (try source.commitWith(.{ .time = 0 })) orelse
        return error.MissingLifecycleHash;
    try lifeHash(try common.field(repeated, "hash"), hash);
    var first = try source.diff(gpa, &.{}, &.{hash});
    defer first.deinit();
    var second = try source.diff(gpa, &.{}, &.{hash});
    defer second.deinit();
    const expected = try common.field(repeated, "patches");
    try common.expectCanonicalPatches(gpa, expected, first.slice());
    try common.expectCanonicalPatches(gpa, expected, second.slice());
    try lifeBool(repeated, "same", lifePatchesEqual(first.slice(), second.slice()));
    first.clear();
    try std.testing.expectEqual(@as(usize, 0), first.len());
    try lifeNumber(repeated, "second_len_after_first_clear", second.len());
    // Clearing one caller-owned batch cannot invalidate another or the cached getter.
    try common.expectCanonicalPatches(gpa, expected, second.slice());
    var third = try source.diff(gpa, &.{}, &.{hash});
    defer third.deinit();
    try common.expectCanonicalPatches(gpa, expected, third.slice());
}

fn lifePatchesEqual(left: []const am.patches.Patch, right: []const am.patches.Patch) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!a.obj.eql(b.obj)) return false;
        if (!a.action.eql(b.action)) return false;
        if (a.path.len != b.path.len) return false;
        for (a.path, b.path) |x, y| {
            if (!x.obj.eql(y.obj)) return false;
            if (!x.prop.eql(y.prop)) return false;
        }
    }
    return true;
}

fn lifeOrderedPatches(gpa: Allocator, io: std.Io, data: Value) !void {
    lifeOrderedPatchesInner(gpa, io, data) catch |failure| {
        documentFailure(life_scenarios[5], failure);
        return failure;
    };
}

fn lifeOrderedPatchesInner(gpa: Allocator, io: std.Io, data: Value) !void {
    // autocommit.rs:433-443; patch_log.rs:276-301: ordered rollback/isolate/integrate batches.
    try lifeFields(data, &.{ "forward", "backward", "isolated", "integrated", "state", "heads" });
    var doc = try lifeAuto(gpa, io);
    defer doc.deinit();
    _ = try doc.put(ROOT, .{ .key = "v" }, .{ .str = "first" });
    const first = (try doc.commitWith(.{ .time = 0 })) orelse return error.MissingLifecycleHash;
    try doc.updateDiffCursor();
    _ = try doc.put(ROOT, .{ .key = "v" }, .{ .str = "second" });
    _ = try doc.commitWith(.{ .time = 0 });
    var forward = try doc.diffIncremental(gpa);
    defer forward.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(data, "forward"), forward.slice());
    try doc.isolate(gpa, &.{first});
    var backward = try doc.diffIncremental(gpa);
    defer backward.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(data, "backward"), backward.slice());
    _ = try doc.put(ROOT, .{ .key = "isolated" }, .{ .bool_value = true });
    _ = try doc.commitWith(.{ .time = 0 });
    var isolated = try doc.diffIncremental(gpa);
    defer isolated.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(data, "isolated"), isolated.slice());
    try doc.integrate();
    var integrated = try doc.diffIncremental(gpa);
    defer integrated.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(data, "integrated"), integrated.slice());
    // All four returned batches remain valid after further owner mutations and getters.
    try common.expectCanonicalPatches(gpa, try common.field(data, "forward"), forward.slice());
    try common.expectCanonicalPatches(gpa, try common.field(data, "backward"), backward.slice());
    try common.expectCanonicalPatches(gpa, try common.field(data, "isolated"), isolated.slice());
    try lifeTree(gpa, try common.field(data, "state"), &doc);
    try lifeHeads(gpa, try common.field(data, "heads"), &doc);
}

fn lifeFixture(gpa: Allocator, io: std.Io) !am.doc.Document {
    // tools/oracle/src/api_parity.rs::fixture: exact op order, text and one commit.
    var doc = try am.doc.Document.initWithEncoding(gpa, io, .unicode_code_point);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = &life_actor_a });
    var tx = try am.Transaction.open(gpa, &doc);
    defer tx.deinitClosed();
    const map = try tx.putObject(ROOT, .{ .key = "map" }, .map);
    _ = try tx.put(map, .{ .key = "k" }, .{ .int = 7 });
    const list = try tx.putObject(ROOT, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .bool_value = true });
    _ = try tx.insert(list, 1, .{ .str = "two" });
    const text = try tx.putObject(ROOT, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "a😀b");
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    return doc;
}

fn lifeRawWrite(gpa: Allocator, doc: *am.doc.Document, key: []const u8) !void {
    var tx = try am.Transaction.open(gpa, doc);
    defer tx.deinitClosed();
    _ = try tx.put(ROOT, .{ .key = key }, .{ .bool_value = true });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
}

fn lifeHasOurChanges(gpa: Allocator, io: std.Io, data: Value) !void {
    lifeHasOurChangesInner(gpa, io, data) catch |failure| {
        documentFailure(life_scenarios[6], failure);
        return failure;
    };
}

fn lifeHasOurChangesInner(gpa: Allocator, io: std.Io, data: Value) !void {
    // automerge.rs:2027-2029 compares ordered full heads, not set containment.
    try lifeFields(data, &.{ "heads", "exact", "reversed", "subset", "state" });
    var left = try lifeFixture(gpa, io);
    defer left.deinit();
    var right = try left.fork(gpa);
    defer right.deinit();
    right.setActorId(.{ .bytes = &life_actor_b });
    try lifeRawWrite(gpa, &left, "left");
    try lifeRawWrite(gpa, &right, "right");
    const merged = try left.merge(gpa, &right);
    defer gpa.free(merged);
    const heads = try left.getHeads(gpa);
    defer gpa.free(heads);
    try lifeOrderedHeads(gpa, try common.field(data, "heads"), heads);
    var state = am.sync.state.State.new(gpa);
    defer state.deinit();
    state.shared_heads = try gpa.dupe(am.types.ChangeHash, heads);
    try lifeBool(data, "exact", left.hasOurChanges(&state));
    std.mem.reverse(am.types.ChangeHash, state.shared_heads);
    try lifeBool(data, "reversed", left.hasOurChanges(&state));
    const subset = try gpa.dupe(am.types.ChangeHash, state.shared_heads[0 .. state.shared_heads.len - 1]);
    gpa.free(state.shared_heads);
    state.shared_heads = subset;
    try lifeBool(data, "subset", left.hasOurChanges(&state));
    try common.expectSnapshot(gpa, io, try common.field(data, "state"), &left);
}

fn lifeListBoundary(gpa: Allocator, io: std.Io, data: Value) !void {
    lifeListBoundaryInner(gpa, io, data) catch |failure| {
        documentFailure(life_scenarios[7], failure);
        return failure;
    };
}

fn lifeListBoundaryInner(gpa: Allocator, io: std.Io, data: Value) !void {
    // ReadDoc scope; automerge-c/src/doc/list.rs:83-99,124-140 uses scoped append length.
    try lifeFields(data, &.{ "old_heads", "full_heads", "scoped_length", "scoped_get", "scoped_get_all", "explicit_new_get", "appended", "pending", "cancelled", "rolled_back" });
    var doc = try lifeAuto(gpa, io);
    defer doc.deinit();
    const list = try doc.putObject(ROOT, .{ .key = "list" }, .list);
    _ = try doc.insert(list, 0, .{ .int = 1 });
    _ = try doc.insert(list, 1, .{ .int = 2 });
    const old = (try doc.commitWith(.{ .time = 0 })) orelse return error.MissingLifecycleHash;
    _ = try doc.delete(list, .{ .index = 1 });
    const new = (try doc.commitWith(.{ .time = 0 })) orelse return error.MissingLifecycleHash;
    try lifeOrderedHeads(gpa, try common.field(data, "old_heads"), &.{old});
    try lifeOrderedHeads(gpa, try common.field(data, "full_heads"), &.{new});
    try doc.isolate(gpa, &.{old});
    const length = try doc.length(list);
    try lifeNumber(data, "scoped_length", length);
    try lifeItem(gpa, try common.field(data, "scoped_get"), try doc.get(list, .{ .index = 1 }));
    const all = try doc.getAll(list, .{ .index = 1 }, gpa);
    defer gpa.free(all);
    const expected = try common.array(try common.field(data, "scoped_get_all"));
    try std.testing.expectEqual(expected.len, all.len);
    for (expected, all) |item, actual| try lifeItem(gpa, item, actual);
    try lifeItem(gpa, try common.field(data, "explicit_new_get"), try doc.getAt(list, .{ .index = 1 }, &.{new}));
    _ = try doc.insert(list, length, .{ .int = 3 });
    try lifeTree(gpa, try common.field(data, "appended"), &doc);
    try lifeNumber(data, "pending", doc.pendingOps());
    try lifeNumber(data, "cancelled", try doc.rollback());
    try lifeTree(gpa, try common.field(data, "rolled_back"), &doc);
}

// Reference: tools/oracle/src/api_parity.rs:556-585, transactions/read projection;
// rust/automerge/src/transaction.rs:39-309 and transaction/manual_transaction.rs:113-121.
// Current transaction readers include their scoped pending rows. Explicit historical
// readers use graph clocks, even when supplied the raw document's current heads.
fn txExpectScopedReaders(
    gpa: Allocator,
    expected: Value,
    tx: *am.Transaction,
    list: am.types.ExId,
    text: am.types.ExId,
    base: am.types.ChangeHash,
    full_heads: []const am.types.ChangeHash,
) !void {
    // Require the complete semantic projection plus its one excluded diagnostic.
    const fields = [_][]const u8{
        "serde",              "get",          "get_at",       "keys",               "map_range", "list_range",      "length",
        "text",               "text_at",      "marks",        "spans",              "parents",   "keys_at_held",    "empty_heads_read",
        "get_all",            "get_all_at",   "map_range_at", "list_range_at",      "values",    "values_at",       "length_at",
        "object_type",        "marks_at",     "spans_at",     "parents_at",         "cursor",    "cursor_position", "cursor_moving",
        "cursor_position_at", "iter",         "iter_at",      "change_hash_lookup", "stats",     "stats_debug",     "missing_deps",
        "text_encoding",      "hydrate_null", "hydrate_at",
    };
    for (fields) |name| _ = try common.field(expected, name);
    try std.testing.expectEqual(fields.len, expected.object.count());

    const R = am.read.ReadDoc(*am.Transaction);
    const historical = &.{base};
    const owner_gpa = R.allocator(tx);

    // Keep this real iterator alive across the empty-head read, then consume it.
    // This detects replacement of its borrowed historical clock by the next read.
    var held_keys = try R.keysAt(tx, ROOT, historical);
    defer held_keys.deinit(owner_gpa);
    const empty_read = try R.getAt(tx, ROOT, .{ .key = "k" }, &.{});
    try txReadExpectKeys(gpa, try common.field(expected, "keys_at_held"), &held_keys);
    const cursor = try R.getCursor(tx, text, .{ .index = 1 }, null, gpa);

    try txExpectTree(gpa, try common.field(expected, "serde"), tx);
    try txReadExpectOptional(gpa, try common.field(expected, "get"), try R.get(tx, ROOT, .{ .key = "k" }));
    try txReadExpectOptional(gpa, try common.field(expected, "get_at"), try R.getAt(tx, ROOT, .{ .key = "p" }, full_heads));
    {
        var walk = try R.keys(tx, ROOT);
        defer walk.deinit(owner_gpa);
        try txReadExpectKeys(gpa, try common.field(expected, "keys"), &walk);
    }
    {
        var walk = try R.mapRange(tx, ROOT, .all());
        try txReadExpectMapRange(gpa, try common.field(expected, "map_range"), &walk);
    }
    {
        var walk = try R.listRange(tx, list, .all());
        try txReadExpectListRange(gpa, try common.field(expected, "list_range"), &walk);
    }
    try txExpectField(gpa, expected, "length", try R.length(tx, list));
    {
        const rendered = try R.text(tx, text, gpa);
        defer gpa.free(rendered);
        try txExpectField(gpa, expected, "text", rendered);
    }
    {
        const rendered = try R.textAt(tx, text, full_heads, gpa);
        defer gpa.free(rendered);
        try txExpectField(gpa, expected, "text_at", rendered);
    }
    {
        const runs = try R.marks(tx, text, gpa);
        defer gpa.free(runs);
        try common.expectMarks(gpa, try common.field(expected, "marks"), runs);
    }
    {
        var walk = try R.spans(tx, text, gpa);
        defer walk.deinit();
        try txReadExpectSpans(gpa, try common.field(expected, "spans"), &walk);
    }
    {
        var walk = try R.parents(tx, text);
        try txReadExpectParents(gpa, try common.field(expected, "parents"), &walk);
    }
    try txReadExpectOptional(gpa, try common.field(expected, "empty_heads_read"), empty_read);
    {
        const items = try R.getAll(tx, ROOT, .{ .key = "k" }, gpa);
        defer gpa.free(items);
        try common.expectDocItems(gpa, try common.field(expected, "get_all"), items);
    }
    {
        const items = try R.getAllAt(tx, ROOT, .{ .key = "p" }, historical, gpa);
        defer gpa.free(items);
        try common.expectDocItems(gpa, try common.field(expected, "get_all_at"), items);
    }
    {
        var walk = try R.mapRangeAt(tx, ROOT, .all(), historical);
        try txReadExpectMapRange(gpa, try common.field(expected, "map_range_at"), &walk);
    }
    {
        var walk = try R.listRangeAt(tx, list, .all(), historical);
        try txReadExpectListRange(gpa, try common.field(expected, "list_range_at"), &walk);
    }
    {
        var term: am.read.ValueTerm = undefined;
        var walk = try R.values(tx, ROOT, &term);
        defer term.deinit(owner_gpa);
        try txReadExpectValues(gpa, try common.field(expected, "values"), &walk);
    }
    {
        var term: am.read.ValueTerm = undefined;
        var walk = try R.valuesAt(tx, ROOT, historical, &term);
        defer term.deinit(owner_gpa);
        try txReadExpectValues(gpa, try common.field(expected, "values_at"), &walk);
    }
    try txExpectField(gpa, expected, "length_at", try R.lengthAt(tx, list, historical));
    try txExpectField(gpa, expected, "object_type", @tagName(try R.objectType(tx, list)));
    {
        const runs = try R.marksAt(tx, text, historical, gpa);
        defer gpa.free(runs);
        try common.expectMarks(gpa, try common.field(expected, "marks_at"), runs);
    }
    {
        var walk = try R.spansAt(tx, text, historical, gpa);
        defer walk.deinit();
        try txReadExpectSpans(gpa, try common.field(expected, "spans_at"), &walk);
    }
    {
        var walk = try R.parentsAt(tx, text, historical);
        try txReadExpectParents(gpa, try common.field(expected, "parents_at"), &walk);
    }
    {
        // Cursor actor bytes borrow the document (cursor.zig:getCursor); the
        // public string conversion is owned and must be released separately.
        const token = try am.cursor.toStr(gpa, cursor);
        defer gpa.free(token);
        try txExpectField(gpa, expected, "cursor", token);
    }
    try txExpectField(gpa, expected, "cursor_position", try R.getCursorPosition(tx, text, cursor, null));
    {
        const moving = try R.getCursorMoving(tx, text, .{ .index = 1 }, historical, .before, gpa);
        const token = try am.cursor.toStr(gpa, moving);
        defer gpa.free(token);
        try txExpectField(gpa, expected, "cursor_moving", token);
    }
    try txExpectField(gpa, expected, "cursor_position_at", try R.getCursorPosition(tx, text, cursor, historical));
    {
        var walk = try R.iter(tx, gpa);
        defer walk.deinit();
        try txReadExpectIter(gpa, try common.field(expected, "iter"), &walk);
    }
    {
        var walk = try R.iterAt(tx, ROOT, historical, gpa);
        defer walk.deinit();
        try txReadExpectIter(gpa, try common.field(expected, "iter_at"), &walk);
    }
    {
        var change = try R.getChangeByHash(tx, base, gpa);
        if (change) |*built| {
            defer built.deinit(gpa);
            const wanted = try common.field(expected, "change_hash_lookup");
            try common.expectHash(try common.field(wanted, "hash"), built.hash());
            const bytes = try common.unhex(gpa, try common.string(try common.field(wanted, "hex")));
            defer gpa.free(bytes);
            const native_bytes = try built.change.rawBytes(gpa);
            defer gpa.free(native_bytes);
            try std.testing.expectEqualSlices(u8, bytes, native_bytes);
        } else {
            try std.testing.expect((try common.field(expected, "change_hash_lookup")) == .null);
        }
    }
    {
        // Only cross-language document facts are compared. stats_debug contains
        // Rust package/compiler provenance, explicitly diagnostic-only.
        const facts = R.stats(tx);
        try txExpectField(gpa, expected, "stats", .{
            .num_ops = facts.num_ops,
            .num_changes = facts.num_changes,
            .num_actors = facts.num_actors,
        });
    }
    {
        const missing = try R.getMissingDeps(tx, full_heads, gpa);
        defer gpa.free(missing);
        try common.expectHeads(gpa, try common.field(expected, "missing_deps"), missing);
    }
    const encoding: []const u8 = switch (R.textEncoding(tx)) {
        .utf8_code_unit => "utf8",
        .utf16_code_unit => "utf16",
        .unicode_code_point => "codepoint",
        .grapheme_cluster => "grapheme",
    };
    try txExpectField(gpa, expected, "text_encoding", encoding);
    {
        // Hydrate bypasses the transaction scope (transaction.rs:223-229).
        var hydrated = try R.hydrate(tx, ROOT, null, gpa);
        defer hydrated.deinit();
        try common.expectHydrated(gpa, try common.field(expected, "hydrate_null"), &hydrated);
    }
    {
        var hydrated = try R.hydrate(tx, ROOT, historical, gpa);
        defer hydrated.deinit();
        try common.expectHydrated(gpa, try common.field(expected, "hydrate_at"), &hydrated);
    }
    {
        // Unlike ordinary transaction *At readers, hydrate uses the raw
        // current-head shortcut and therefore retains pending rows here.
        // Reference: automerge.rs:1236-1247,2228; transaction.rs:228.
        var hydrated = try R.hydrate(tx, ROOT, full_heads, gpa);
        defer hydrated.deinit();
        try common.expectHydrated(gpa, try common.field(expected, "hydrate_null"), &hydrated);
    }
}

fn txReadExpectOptional(gpa: Allocator, expected: Value, actual: ?am.read.DocItem) !void {
    try common.expectDocItem(gpa, expected, actual);
}

fn txReadExpectKeys(gpa: Allocator, expected: Value, walk: *am.read.Keys) !void {
    _ = gpa;
    for (try common.array(expected)) |wanted| {
        const actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        try std.testing.expectEqualStrings(try common.string(wanted), actual);
    }
    try std.testing.expect((try walk.next()) == null);
}

fn txReadWriteJson(actual: anytype, writer: *std.Io.Writer) !void {
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(actual);
}

// No row offsets or Zig-only text widths are projected: these are the public
// Rust range fields, including winner IDs and conflict flags in iterator order.
// Reference: iter/map_range.rs:13-20; iter/list_range.rs:14-20.
fn txReadWriteMapItem(actual: *const am.read.MapRangeItem, writer: *std.Io.Writer) !void {
    try writer.writeAll("\"key\":");
    try txReadWriteJson(actual.key, writer);
    try writer.writeAll(",\"value\":");
    try common.writeValueRefJson(actual.value, writer);
    try writer.writeAll(",\"id\":");
    try common.writeExId(actual.id(), writer);
    try writer.writeAll(",\"conflict\":");
    try txReadWriteJson(actual.conflict, writer);
}

fn txReadWriteListItem(actual: *const am.read.ListRangeItem, writer: *std.Io.Writer) !void {
    try writer.writeAll("\"index\":");
    try txReadWriteJson(actual.index, writer);
    try writer.writeAll(",\"value\":");
    try common.writeValueRefJson(actual.value, writer);
    try writer.writeAll(",\"id\":");
    try common.writeExId(actual.id(), writer);
    try writer.writeAll(",\"conflict\":");
    try txReadWriteJson(actual.conflict, writer);
}

fn txReadExpectMapRange(gpa: Allocator, expected: Value, walk: *am.read.MapRange) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        const actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeByte('{');
        try txReadWriteMapItem(&actual, &out.writer);
        try out.writer.writeByte('}');
    }
    try std.testing.expect((try walk.next()) == null);
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}

fn txReadExpectListRange(gpa: Allocator, expected: Value, walk: *am.read.ListRange) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        const actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeByte('{');
        try txReadWriteListItem(&actual, &out.writer);
        try out.writer.writeByte('}');
    }
    try std.testing.expect((try walk.next()) == null);
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}

fn txReadExpectValues(gpa: Allocator, expected: Value, walk: *am.read.Values) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        const actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        if (index != 0) try out.writer.writeByte(',');
        try common.writeDocItem(.{ .value = actual.value, .id = actual.id }, &out.writer);
    }
    try std.testing.expect((try walk.next()) == null);
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}

// Parent arrays retain leaf-to-root order, typed properties and visibility.
// Reference: op_set2/op_set/parents.rs:80-91; transaction.rs:279-292.
fn txReadExpectParents(gpa: Allocator, expected: Value, walk: *am.read.Parents) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        const actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"obj\":");
        try common.writeExId(actual.obj, &out.writer);
        try out.writer.writeAll(",\"typ\":");
        try txReadWriteJson(@tagName(actual.typ), &out.writer);
        try out.writer.writeAll(",\"prop\":");
        try common.writeProp(actual.prop, &out.writer);
        try out.writer.writeAll(",\"visible\":");
        try txReadWriteJson(actual.visible, &out.writer);
        try out.writer.writeByte('}');
    }
    try std.testing.expect((try walk.next()) == null);
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}

fn txReadExpectSpans(gpa: Allocator, expected: Value, walk: *am.read.Spans) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        var actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        defer actual.deinit(gpa);
        if (index != 0) try out.writer.writeByte(',');
        try common.writeSpan(gpa, &actual, &out.writer);
    }
    if (try walk.next()) |extra| {
        var actual = extra;
        defer actual.deinit(gpa);
        return error.UnexpectedIteratorItem;
    }
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}

// Read actual public DocObjItem variants instead of reconstructing a walk from
// map/list queries. Text variants own their spans and must be released per item.
// Reference: iter/doc.rs:337-386; native iter/doc.zig:1245-1312,1566-1574.
fn txReadExpectIter(gpa: Allocator, expected: Value, walk: *am.read.DocIter) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeByte('[');
    for (try common.array(expected), 0..) |_, index| {
        var actual = (try walk.next()) orelse return error.ExpectedIteratorItem;
        defer actual.deinit(gpa);
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"obj\":");
        try common.writeExId(actual.obj, &out.writer);
        try out.writer.writeAll(",\"item\":{");
        switch (actual.item) {
            .map => |*item| {
                try out.writer.writeAll("\"type\":\"map\",");
                try txReadWriteMapItem(item, &out.writer);
            },
            .list => |*item| {
                try out.writer.writeAll("\"type\":\"list\",");
                try txReadWriteListItem(item, &out.writer);
            },
            .text => |*item| {
                try out.writer.writeAll("\"type\":\"text\",\"span\":");
                try common.writeSpan(gpa, item, &out.writer);
            },
        }
        try out.writer.writeAll("}}");
    }
    if (try walk.next()) |extra| {
        var actual = extra;
        defer actual.deinit(gpa);
        return error.UnexpectedIteratorItem;
    }
    try out.writer.writeByte(']');
    try common.expectJsonText(gpa, expected, out.written());
}
