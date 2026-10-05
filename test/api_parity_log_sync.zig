const std = @import("std");
const am = @import("zautomerge");
const common = @import("api_parity_common.zig");

const Allocator = std.mem.Allocator;
const Document = am.doc.Document;
const PatchLog = am.patches.PatchLog;
const Message = am.sync.message.Message;
const State = am.sync.state.State;
const protocol = am.sync.protocol;
const testing = std.testing;
const actor_a = [_]u8{0xa1} ** 15;
const actor_b = [_]u8{0xb2} ** 16;
const success_names = [_][]const u8{
    "external-log-apply",
    "external-log-incremental",
    "external-log-merge",
    "external-log-sync",
};
const compatible_names = [_][]const u8{
    "external-log-wrong-owner-apply",
    "external-log-wrong-owner-incremental",
    "external-log-wrong-owner-merge",
    "external-log-wrong-owner-sync",
};
const incompatible_names = [_][]const u8{
    "external-log-incompatible-apply",
    "external-log-incompatible-incremental",
    "external-log-incompatible-merge",
    "external-log-incompatible-sync",
};

pub fn verify(gpa: Allocator, io: std.Io, records: []const common.Record, seen: []bool) !void {
    // Replay api_parity.rs::logged_routes and ::sync_serde as whole conversations.
    // Neither an eager log nor a wire message is replaced by a final-state diff.
    try testing.expectEqual(records.len, seen.len);
    var successes: [4]?usize = @splat(null);
    var compatible: [4]?usize = @splat(null);
    var incompatible: [4]?usize = @splat(null);
    var retained: ?usize = null;
    var retained_tail: ?usize = null;
    var rounds: [4]?usize = @splat(null);
    var final: ?usize = null;
    for (records, 0..) |record, index| {
        var owned = false;
        for (success_names, 0..) |name, route| {
            if (std.mem.eql(u8, record.scenario, name)) {
                try assignUnique(&successes[route], index);
                owned = true;
            }
        }
        for (compatible_names, 0..) |name, route| {
            if (std.mem.eql(u8, record.scenario, name)) {
                try assignUnique(&compatible[route], index);
                owned = true;
            }
        }
        for (incompatible_names, 0..) |name, route| {
            if (std.mem.eql(u8, record.scenario, name)) {
                try assignUnique(&incompatible[route], index);
                owned = true;
            }
        }
        if (std.mem.eql(u8, record.scenario, "external-log-owner-retained")) {
            try assignUnique(&retained, index);
            owned = true;
        }
        if (std.mem.eql(u8, record.scenario, "external-log-retained-tail-apply")) {
            try assignUnique(&retained_tail, index);
            owned = true;
        }
        if (std.mem.eql(u8, record.scenario, "sync-message-serde")) {
            const round = try common.integer(usize, try common.field(record.data, "round"));
            if (round >= rounds.len) return error.UnexpectedSyncRound;
            try assignUnique(&rounds[round], index);
            owned = true;
        }
        if (std.mem.eql(u8, record.scenario, "sync-serde-final")) {
            try assignUnique(&final, index);
            owned = true;
        }
        if (owned) {
            try testing.expectEqualStrings("api-parity", record.kind);
        } else if (std.mem.startsWith(u8, record.scenario, "external-log-")) {
            return error.UnknownExternalLogScenario;
        } else if (std.mem.startsWith(u8, record.scenario, "sync-")) {
            return error.UnknownSyncScenario;
        }
    }
    for (successes) |index| if (index == null) return error.MissingExternalLogScenario;
    for (compatible) |index| if (index == null) return error.MissingExternalLogScenario;
    for (incompatible) |index| if (index == null) return error.MissingExternalLogScenario;
    const retained_index = retained orelse return error.MissingExternalLogScenario;
    const tail_index = retained_tail orelse return error.MissingExternalLogScenario;
    const final_index = final orelse return error.MissingSyncFinal;

    var source = try Document.init(gpa, io);
    defer source.deinit();
    source.setActorId(.{ .bytes = &actor_a });
    try populateFixture(gpa, &source);
    var changes = try source.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), changes.len());
    const incoming = [_]am.change_record.Change{changes.at(0)};
    const save = try source.save(gpa);
    defer gpa.free(save);

    for (successes, 0..) |maybe_index, route| {
        const index = maybe_index.?;
        errdefer std.debug.print("API parity log/sync scenario: {s}\n", .{records[index].scenario});
        try verifySuccessfulRoute(gpa, io, route, &source, &incoming, save, records[index].data);
        try common.mark(seen, index);
    }
    try verifyBorrowedReuse(gpa, io, &source, &incoming, save, records, seen, compatible, incompatible, retained_index);
    verifyRetainedTail(gpa, io, records[tail_index].data) catch |failure| {
        std.debug.print("API parity log/sync scenario: {s}\n", .{records[tail_index].scenario});
        return failure;
    };
    try common.mark(seen, tail_index);
    try verifySyncSerde(gpa, io, &source, records, seen, rounds, final_index);
}

fn assignUnique(slot: *?usize, index: usize) !void {
    if (slot.* != null) return error.DuplicateParityRecord;
    slot.* = index;
}

fn populateFixture(gpa: Allocator, doc: *Document) !void {
    // api_parity.rs::fixture: one commit, timestamp zero, exactly this op order.
    var tx = try am.Transaction.open(gpa, doc);
    // On refusal the caller destroys the entire document, not a surviving journal.
    defer tx.deinitClosed();
    const map = try tx.putObject(.root, .{ .key = "map" }, .map);
    _ = try tx.put(map, .{ .key = "k" }, .{ .int = 7 });
    const list = try tx.putObject(.root, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .bool_value = true });
    _ = try tx.insert(list, 1, .{ .str = "two" });
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "a😀b");
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    try testing.expect(committed.hash != null);
}

fn verifySuccessfulRoute(
    gpa: Allocator,
    io: std.Io,
    route: usize,
    source: *Document,
    incoming: []const am.change_record.Change,
    save: []const u8,
    expected: std.json.Value,
) !void {
    var target = try Document.init(gpa, io);
    defer target.deinit();
    target.setActorId(.{ .bytes = &actor_b });
    var log = PatchLog.active(gpa);
    defer log.deinit();
    const messages = try common.array(try common.field(expected, "messages"));
    switch (route) {
        0 => _ = try target.applyChangesWithPatchLog(gpa, incoming, &log),
        1 => _ = try target.loadIncrementalWithPatchLog(gpa, save, &log),
        2 => {
            var clone = try source.clone(gpa);
            defer clone.deinit();
            const heads = try target.mergeWithPatchLog(gpa, &clone, &log);
            defer gpa.free(heads);
            try common.expectHeads(gpa, try common.field(
                try common.field(expected, "state"),
                "heads",
            ), heads);
        },
        3 => try replayLoggedSync(gpa, source, &target, &log, messages),
        else => unreachable,
    }
    if (route != 3) try testing.expectEqual(@as(usize, 0), messages.len);
    try common.expectSnapshot(gpa, io, try common.field(expected, "state"), &target);
    var patches = try target.makePatches(&log);
    defer patches.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(expected, "patches"), patches.slice());
}

fn replayLoggedSync(
    gpa: Allocator,
    source: *Document,
    target: *Document,
    log: *PatchLog,
    expected_messages: []const std.json.Value,
) !void {
    // api_parity.rs::logged_routes sends first, replies second, for six rounds.
    var sender = try source.clone(gpa);
    defer sender.deinit();
    var sender_state = State.new(gpa);
    defer sender_state.deinit();
    var target_state = State.new(gpa);
    defer target_state.deinit();
    var emitted: usize = 0;
    for (0..6) |_| {
        if (try protocol.generateSyncMessage(gpa, &sender, &sender_state)) |message| {
            var owned = message;
            var transferred = false;
            defer if (!transferred) owned.deinit();
            if (emitted >= expected_messages.len) return error.UnexpectedSyncMessage;
            const expected = expected_messages[emitted];
            try testing.expectEqualStrings("send", try common.string(
                try common.field(expected, "direction"),
            ));
            try expectMessage(gpa, expected, owned);
            transferred = true;
            // receiveSyncMessageWithPatchLog consumes even on refusal.
            try protocol.receiveSyncMessageWithPatchLog(gpa, target, &target_state, owned, log);
            emitted += 1;
        }
        if (try protocol.generateSyncMessage(gpa, target, &target_state)) |message| {
            try protocol.receiveSyncMessage(gpa, &sender, &sender_state, message);
        }
    }
    try testing.expectEqual(expected_messages.len, emitted);
}

fn dataMessage(gpa: Allocator, io: std.Io, source: *Document) !Message {
    var peer = try Document.init(gpa, io);
    defer peer.deinit();
    peer.setActorId(.{ .bytes = &actor_b });
    return dataMessageTo(gpa, source, &peer);
}

fn dataMessageTo(gpa: Allocator, source: *Document, peer: *Document) !Message {
    // Stop at the first real data message; it has not been delivered to the peer.
    var sender = try source.clone(gpa);
    defer sender.deinit();
    var sender_state = State.new(gpa);
    defer sender_state.deinit();
    var peer_state = State.new(gpa);
    defer peer_state.deinit();
    for (0..6) |_| {
        if (try protocol.generateSyncMessage(gpa, &sender, &sender_state)) |message| {
            if (!message.changes.isEmpty()) return message;
            try protocol.receiveSyncMessage(gpa, peer, &peer_state, message);
        }
        if (try protocol.generateSyncMessage(gpa, peer, &peer_state)) |message| {
            try protocol.receiveSyncMessage(gpa, &sender, &sender_state, message);
        }
    }
    return error.MissingSyncDataMessage;
}

fn verifyBorrowedReuse(
    gpa: Allocator,
    io: std.Io,
    source: *Document,
    incoming: []const am.change_record.Change,
    save: []const u8,
    records: []const common.Record,
    seen: []bool,
    indices: [4]?usize,
    incompatible_indices: [4]?usize,
    retained_index: usize,
) !void {
    // api_parity.rs::logged_routes binds the log through the owned=true commit.
    var scenario = records[retained_index].scenario;
    errdefer std.debug.print("API parity log/sync scenario: {s}\n", .{scenario});
    var owner = try Document.init(gpa, io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = &actor_a });
    var initial = PatchLog.active(gpa);
    defer initial.deinit();
    var tx = try am.Transaction.openWithPatchLog(gpa, &owner, &initial, null);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    try testing.expect(committed.hash != null);
    var message = try dataMessage(gpa, io, source);
    defer message.deinit();
    const message_bytes = try message.encode(gpa);
    defer gpa.free(message_bytes);

    for (indices, 0..) |maybe_index, route| {
        const index = maybe_index.?;
        scenario = records[index].scenario;
        const expected = records[index].data;
        var foreign = try Document.init(gpa, io);
        defer foreign.deinit();
        foreign.setActorId(.{ .bytes = &actor_b });
        // Clone with the original identity, never rebind to the foreign document.
        var offered = try committed.patch_log.cloneAndRebind(gpa, owner.patchIdentity());
        defer offered.deinit();
        try common.expectSnapshot(gpa, io, try common.field(expected, "before"), &foreign);
        // These legacy wrong-owner labels are actor-compatible successes in Rust.
        try testing.expectEqual(.null, std.meta.activeTag(try common.field(expected, "error")));
        switch (route) {
            0 => _ = try foreign.applyChangesWithPatchLog(gpa, incoming, &offered),
            1 => _ = try foreign.loadIncrementalWithPatchLog(gpa, save, &offered),
            2 => {
                var clone = try source.clone(gpa);
                defer clone.deinit();
                const heads = try foreign.mergeWithPatchLog(gpa, &clone, &offered);
                defer gpa.free(heads);
                try common.expectHeads(gpa, try common.field(
                    try common.field(expected, "after"),
                    "heads",
                ), heads);
            },
            3 => {
                var state = State.new(gpa);
                defer state.deinit();
                const copied = try Message.decode(gpa, message_bytes);
                // This receive owns copied on BOTH success and error paths.
                try protocol.receiveSyncMessageWithPatchLog(gpa, &foreign, &state, copied, &offered);
                try testing.expect(!state.in_flight);
                try common.expectHeads(gpa, try common.field(
                    try common.field(expected, "after"),
                    "heads",
                ), state.shared_heads);
            },
            else => unreachable,
        }
        try common.expectSnapshot(gpa, io, try common.field(expected, "after"), &foreign);
        const retained = try common.field(expected, "retained_log");
        var patches = try owner.makePatches(&offered);
        defer patches.deinit();
        try common.expectCanonicalPatches(gpa, retained, patches.slice());
        try common.mark(seen, index);
    }
    try verifyIncompatibleRoutes(gpa, io, &owner, &committed.patch_log, records, seen, incompatible_indices);
    scenario = records[retained_index].scenario;
    const expected = records[retained_index].data;
    try common.expectTree(gpa, try common.field(expected, "value"), &owner);
    var patches = try owner.makePatches(&committed.patch_log);
    defer patches.deinit();
    try common.expectCanonicalPatches(gpa, try common.field(expected, "patches"), patches.slice());
    try common.mark(seen, retained_index);
}

fn verifyIncompatibleRoutes(
    gpa: Allocator,
    io: std.Io,
    owner: *Document,
    original_log: *const PatchLog,
    records: []const common.Record,
    seen: []bool,
    indices: [4]?usize,
) !void {
    // api_parity.rs:534-583: A-only log against dependent B-only history.
    // The receiver is nonempty, so incremental loading takes the batch path.
    var base = try Document.init(gpa, io);
    defer base.deinit();
    base.setActorId(.{ .bytes = &actor_b });
    {
        var tx = try am.Transaction.open(gpa, &base);
        defer tx.deinitClosed();
        _ = try tx.put(.root, .{ .key = "base" }, .{ .bool_value = true });
        var committed = try tx.commitWith(.{ .time = 0 });
        defer committed.deinit(gpa);
        try testing.expect(committed.hash != null);
    }
    const base_heads = try base.getHeads(gpa);
    defer gpa.free(base_heads);
    var source = try base.clone(gpa);
    defer source.deinit();
    try populateFixture(gpa, &source);
    var delta = try source.getChanges(gpa, base_heads);
    defer delta.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), delta.len());
    const incoming = [_]am.change_record.Change{delta.at(0)};
    const delta_bytes = try incoming[0].rawBytes(gpa);
    defer gpa.free(delta_bytes);
    const source_bytes = try source.save(gpa);
    defer gpa.free(source_bytes);
    var handshake_peer = try base.clone(gpa);
    defer handshake_peer.deinit();
    var message = try dataMessageTo(gpa, &source, &handshake_peer);
    defer message.deinit();
    const message_bytes = try message.encode(gpa);
    defer gpa.free(message_bytes);

    for (indices, 0..) |maybe_index, route| {
        const index = maybe_index.?;
        const record = records[index];
        errdefer std.debug.print("API parity log/sync scenario: {s}\n", .{record.scenario});
        const expected = record.data;
        const input = try common.field(expected, "input");
        try expectSaveInput(gpa, io, try common.field(input, "base_hex"), &base);
        try expectSaveInput(gpa, io, try common.field(input, "source_hex"), &source);
        const changes = try common.array(try common.field(input, "changes_hex"));
        try testing.expectEqual(@as(usize, 1), changes.len);
        const expected_change = try common.unhex(gpa, try common.string(changes[0]));
        defer gpa.free(expected_change);
        try testing.expectEqualSlices(u8, expected_change, delta_bytes);
        const message_input = try common.field(input, "message");
        if (route == 3) {
            try expectMessage(gpa, message_input, message);
        } else {
            try testing.expectEqual(.null, std.meta.activeTag(message_input));
        }

        var foreign = try base.clone(gpa);
        defer foreign.deinit();
        var offered = try original_log.cloneAndRebind(gpa, owner.patchIdentity());
        defer offered.deinit();
        try common.expectSnapshot(gpa, io, try common.field(expected, "before"), &foreign);
        try expectMismatch(try common.field(expected, "error"));
        switch (route) {
            0 => try testing.expectError(error.PatchLogMismatch, foreign.applyChangesWithPatchLog(gpa, &incoming, &offered)),
            1 => try testing.expectError(error.PatchLogMismatch, foreign.loadIncrementalWithPatchLog(gpa, source_bytes, &offered)),
            2 => {
                var clone = try source.clone(gpa);
                defer clone.deinit();
                if (foreign.mergeWithPatchLog(gpa, &clone, &offered)) |heads| {
                    gpa.free(heads);
                    return error.ExpectedPatchLogMismatch;
                } else |failure| {
                    try testing.expectEqual(error.PatchLogMismatch, failure);
                }
            },
            3 => {
                var state = State.new(gpa);
                defer state.deinit();
                const copied = try Message.decode(gpa, message_bytes);
                // Receive consumes the copied message, including the refusal path.
                try testing.expectError(error.PatchLogMismatch, protocol.receiveSyncMessageWithPatchLog(
                    gpa,
                    &foreign,
                    &state,
                    copied,
                    &offered,
                ));
            },
            else => unreachable,
        }
        try common.expectSnapshot(gpa, io, try common.field(expected, "after"), &foreign);
        const retained = try common.field(expected, "retained_log");
        var patches = try owner.makePatches(&offered);
        defer patches.deinit();
        try common.expectCanonicalPatches(gpa, retained, patches.slice());
        try verifyRetainedReuse(gpa, owner, &offered, retained);
        try common.mark(seen, index);
    }
}

fn verifyRetainedTail(gpa: Allocator, io: std.Io, expected: std.json.Value) !void {
    // api_parity.rs:586-604: prefix insertion must retain an existing B tail.
    var owner = try Document.init(gpa, io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = &actor_b });
    var log = PatchLog.active(gpa);
    defer log.deinit();
    var owner_tx = try am.Transaction.openWithPatchLog(gpa, &owner, &log, null);
    defer owner_tx.deinitClosed();
    _ = try owner_tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var committed = try owner_tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    try testing.expect(committed.hash != null);

    var target = try Document.init(gpa, io);
    defer target.deinit();
    target.setActorId(.{ .bytes = &actor_a });
    {
        var tx = try am.Transaction.open(gpa, &target);
        defer tx.deinitClosed();
        _ = try tx.put(.root, .{ .key = "base" }, .{ .bool_value = true });
        var result = try tx.commitWith(.{ .time = 0 });
        defer result.deinit(gpa);
        try testing.expect(result.hash != null);
    }
    const base_heads = try target.getHeads(gpa);
    defer gpa.free(base_heads);
    var source = try target.clone(gpa);
    defer source.deinit();
    {
        var tx = try am.Transaction.open(gpa, &source);
        defer tx.deinitClosed();
        _ = try tx.put(.root, .{ .key = "added" }, .{ .int = 7 });
        var result = try tx.commitWith(.{ .time = 0 });
        defer result.deinit(gpa);
        try testing.expect(result.hash != null);
    }
    var delta = try source.getChanges(gpa, base_heads);
    defer delta.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), delta.len());
    const incoming = [_]am.change_record.Change{delta.at(0)};
    const native_change = try incoming[0].rawBytes(gpa);
    defer gpa.free(native_change);
    const input = try common.field(expected, "input");
    try expectSaveInput(gpa, io, try common.field(input, "base_hex"), &target);
    try expectSaveInput(gpa, io, try common.field(input, "source_hex"), &source);
    const changes = try common.array(try common.field(input, "changes_hex"));
    try testing.expectEqual(@as(usize, 1), changes.len);
    const reference_change = try common.unhex(gpa, try common.string(changes[0]));
    defer gpa.free(reference_change);
    try testing.expectEqualSlices(u8, reference_change, native_change);
    try testing.expectEqual(.null, std.meta.activeTag(try common.field(input, "message")));
    try testing.expectEqual(.null, std.meta.activeTag(try common.field(expected, "error")));
    try common.expectSnapshot(gpa, io, try common.field(expected, "before"), &target);
    // Use the original B owner log, not a re-bound log or a final-state diff.
    _ = try target.applyChangesWithPatchLog(gpa, &incoming, &committed.patch_log);
    try common.expectSnapshot(gpa, io, try common.field(expected, "after"), &target);
    const retained = try common.field(expected, "retained_log");
    if (retained != .object) return error.ExpectedReferenceActorExportPanic;
    try testing.expectEqual(@as(usize, 4), retained.object.count());
    try testing.expectEqualStrings("panic", try common.string(
        try common.field(retained, "outcome"),
    ));
    try testing.expectEqualStrings("IndexOutOfBounds", try common.string(
        try common.field(retained, "class"),
    ));
    try testing.expectEqual(@as(usize, 1), try common.integer(usize, try common.field(retained, "index")));
    try testing.expectEqual(@as(usize, 1), try common.integer(usize, try common.field(retained, "len")));
    // The reference indexes targetA's absent resident actor1 and panics.
    // This exact export boundary is a checked InvalidActorIndex in native code.
    // No log-actor substitution or document-wide compatibility guard is valid.
    try expectMissingResidentActor(&target, &committed.patch_log);
    try common.expectSnapshot(gpa, io, try common.field(expected, "after"), &target);
    var copied = try committed.patch_log.cloneAndRebind(gpa, owner.patchIdentity());
    defer copied.deinit();
    try expectMissingResidentActor(&target, &copied);
    try expectMissingResidentActor(&target, &committed.patch_log);
}

fn expectMissingResidentActor(target: *Document, log: *PatchLog) !void {
    if (target.makePatches(log)) |patches| {
        var unexpected = patches;
        unexpected.deinit();
        return error.ExpectedInvalidActorIndex;
    } else |failure| {
        try testing.expectEqual(error.InvalidActorIndex, failure);
    }
}

fn expectSaveInput(
    gpa: Allocator,
    io: std.Io,
    expected_hex: std.json.Value,
    actual: *Document,
) !void {
    // Document compression is non-normative; load the actual Rust save instead.
    const bytes = try common.unhex(gpa, try common.string(expected_hex));
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, io, bytes, actual.textEncoding());
    defer loaded.deinit();
    const actual_json = try am.autoserde.AutoSerde(Document).from(actual).toJson(gpa);
    defer gpa.free(actual_json);
    const tree = try std.json.parseFromSlice(std.json.Value, gpa, actual_json, .{});
    defer tree.deinit();
    try common.expectTree(gpa, tree.value, &loaded);
    const actual_heads = try actual.getHeads(gpa);
    defer gpa.free(actual_heads);
    const loaded_heads = try loaded.getHeads(gpa);
    defer gpa.free(loaded_heads);
    try testing.expectEqual(actual_heads.len, loaded_heads.len);
    for (actual_heads) |head| {
        var matches: usize = 0;
        for (loaded_heads) |loaded_head| {
            if (head.eql(loaded_head)) matches += 1;
        }
        try testing.expectEqual(@as(usize, 1), matches);
    }
}

fn expectMismatch(expected: std.json.Value) !void {
    try testing.expectEqualStrings("error", try common.string(try common.field(expected, "outcome")));
    try testing.expectEqualStrings("PatchLogMismatch", try common.string(
        try common.field(expected, "class"),
    ));
}

fn verifyRetainedReuse(
    gpa: Allocator,
    owner: *Document,
    log: *PatchLog,
    expected: std.json.Value,
) !void {
    // A genuine actor-table refusal retains the sink for later owner writes.
    // Rollback must preserve the owner's exact committed history and bytes.
    const before_heads = try owner.getHeads(gpa);
    defer gpa.free(before_heads);
    const before_save = try owner.save(gpa);
    defer gpa.free(before_save);
    var tx = try am.Transaction.openWithPatchLog(gpa, owner, log, null);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "later" }, .{ .bool_value = true });
    var pending = try owner.makePatches(&tx.patch_log);
    defer pending.deinit();
    const before_count = (try common.array(expected)).len;
    try testing.expectEqual(before_count + 1, pending.len());
    try common.expectCanonicalPatches(gpa, expected, pending.slice()[0..before_count]);
    const later = pending.slice()[before_count];
    try testing.expect(later.obj == .root);
    try testing.expectEqual(@as(usize, 0), later.path.len);
    try testing.expect(later.action == .put_map);
    try testing.expectEqualStrings("later", later.action.put_map.key);
    try testing.expect(later.action.put_map.value.eql(.{ .scalar = .{ .bool_value = true } }));
    try testing.expect(!later.action.put_map.conflict);
    const later_id = try later.action.put_map.obj.toString(gpa);
    defer gpa.free(later_id);
    try testing.expectEqualStrings("2@a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1", later_id);
    try testing.expectEqual(@as(usize, 1), try tx.rollback());
    var restored = try owner.makePatches(&tx.patch_log);
    defer restored.deinit();
    try common.expectCanonicalPatches(gpa, expected, restored.slice());
    const after_heads = try owner.getHeads(gpa);
    defer gpa.free(after_heads);
    try testing.expectEqual(before_heads.len, after_heads.len);
    for (before_heads, after_heads) |before, after| {
        try testing.expect(before.eql(after));
    }
    const after_save = try owner.save(gpa);
    defer gpa.free(after_save);
    try testing.expectEqualSlices(u8, before_save, after_save);
}

fn expectMessage(gpa: Allocator, expected: std.json.Value, message: Message) !void {
    const json = try common.field(expected, "json");
    if (json != .object) return error.InvalidMessageJson;
    try testing.expectEqual(@as(usize, 4), json.object.count());
    // The public serde projection includes actual Bloom fields/chunks, not flags/version.
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try message.writeJson(&output.writer);
    try common.expectJsonText(gpa, json, output.written());
    const expected_bytes = try common.unhex(gpa, try common.string(
        try common.field(expected, "hex"),
    ));
    defer gpa.free(expected_bytes);
    const actual_bytes = try message.encode(gpa);
    defer gpa.free(actual_bytes);
    try testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

fn verifySyncSerde(
    gpa: Allocator,
    io: std.Io,
    source: *Document,
    records: []const common.Record,
    seen: []bool,
    rounds: [4]?usize,
    final_index: usize,
) !void {
    // api_parity.rs::sync_serde: execute once, compare every emitted round exactly.
    var scenario: []const u8 = "sync-message-serde";
    var current_round: ?usize = null;
    errdefer std.debug.print("API parity log/sync scenario: {s}, round: {?d}\n", .{ scenario, current_round });
    var sender = try source.clone(gpa);
    defer sender.deinit();
    var receiver = try Document.init(gpa, io);
    defer receiver.deinit();
    receiver.setActorId(.{ .bytes = &actor_b });
    var sender_state = State.new(gpa);
    defer sender_state.deinit();
    var receiver_state = State.new(gpa);
    defer receiver_state.deinit();
    var emitted: usize = 0;
    for (0..4) |round| {
        current_round = round;
        if (try protocol.generateSyncMessage(gpa, &sender, &sender_state)) |message| {
            var owned = message;
            var transferred = false;
            defer if (!transferred) owned.deinit();
            const index = rounds[round] orelse return error.UnexpectedSyncRound;
            const expected = records[index].data;
            try testing.expectEqual(round, try common.integer(usize, try common.field(expected, "round")));
            try expectMessage(gpa, expected, owned);
            try common.expectHeads(gpa, try common.field(expected, "heads"), owned.heads);
            try common.expectHeads(gpa, try common.field(expected, "need"), owned.need);
            const chunks = try common.array(try common.field(expected, "changes_hex"));
            try testing.expectEqual(chunks.len, owned.changes.len());
            for (chunks, owned.changes.iter()) |chunk, actual| {
                const bytes = try common.unhex(gpa, try common.string(chunk));
                defer gpa.free(bytes);
                try testing.expectEqualSlices(u8, bytes, actual);
            }
            transferred = true;
            try protocol.receiveSyncMessage(gpa, &receiver, &receiver_state, owned);
            try common.mark(seen, index);
            emitted += 1;
        } else if (rounds[round] != null) {
            return error.MissingSyncRound;
        }
        if (try protocol.generateSyncMessage(gpa, &receiver, &receiver_state)) |message| {
            try protocol.receiveSyncMessage(gpa, &sender, &sender_state, message);
        }
    }
    var expected_count: usize = 0;
    for (rounds) |index| if (index != null) {
        expected_count += 1;
    };
    try testing.expectEqual(expected_count, emitted);
    scenario = records[final_index].scenario;
    current_round = null;
    const final = records[final_index].data;
    try common.expectSnapshot(gpa, io, try common.field(final, "sender"), &sender);
    try common.expectSnapshot(gpa, io, try common.field(final, "receiver"), &receiver);
    try common.mark(seen, final_index);
}
