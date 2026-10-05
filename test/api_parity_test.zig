//! Native replay of every generated public API parity record. Each owner
//! validates its required scenario/variant set and computes actual public API
//! outcomes. The root rejects unknown records and duplicate ownership.
const std = @import("std");
const common = @import("api_parity_common.zig");
const document = @import("api_parity_document.zig");
const log_sync = @import("api_parity_log_sync.zig");
const values = @import("api_parity_values.zig");
const hydrate = @import("api_parity_hydrate.zig");

const corpus = @embedFile("golden/api-parity.jsonl");

test "all reference API parity records replay through native public APIs" {
    // Source: tools/oracle/src/api_parity.rs. This is an independent native
    // execution, not the Rust-versus-recorded-Rust conformance comparison.
    // Dynamic sync message counts belong to the actual protocol conversation;
    // no fixed top-level count can substitute for each slice's required set.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const records = try common.parseRecords(arena, corpus);
    const seen = try arena.alloc(bool, records.len);
    @memset(seen, false);
    document.verify(gpa, std.testing.io, records, seen) catch |err| {
        std.debug.print("api-parity: document verifier failed: {s}\n", .{@errorName(err)});
        return err;
    };
    log_sync.verify(gpa, std.testing.io, records, seen) catch |err| {
        std.debug.print("api-parity: log/sync verifier failed: {s}\n", .{@errorName(err)});
        return err;
    };
    values.verify(gpa, std.testing.io, records, seen) catch |err| {
        std.debug.print("api-parity: values verifier failed: {s}\n", .{@errorName(err)});
        return err;
    };
    hydrate.verify(gpa, std.testing.io, records, seen) catch |err| {
        std.debug.print("api-parity: hydrate verifier failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try common.requireAllSeen(records, seen);
}

test "API parity corpus rejects unknown envelopes and duplicate ownership" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyCorpus, common.parseRecords(arena.allocator(), ""));
    try std.testing.expectError(error.UnknownRecordKind, common.parseRecords(arena.allocator(),
        \\{"kind":"other","scenario":"probe","source":"source:1","data":null}
    ));
    var seen = [_]bool{false};
    try common.mark(&seen, 0);
    try std.testing.expectError(error.DuplicateRecordOwnership, common.mark(&seen, 0));
    try std.testing.expectError(error.InvalidRecordIndex, common.mark(&seen, 1));
    const records = [_]common.Record{.{
        .kind = "api-parity", .scenario = "not-owned", .source = "source:1", .data = .null,
    }};
    seen[0] = false;
    try std.testing.expectError(error.UnknownOrUnconsumedScenario,
        common.requireAllSeen(&records, &seen));
}

test "API parity JSON compares complete trees and full width integers" {
    const gpa = std.testing.allocator;
    const expected = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"value":18446744073709551615,"items":[1,true,null],"nested":{"a":"x"}}
    , .{ .parse_numbers = false });
    defer expected.deinit();
    try common.expectJsonText(gpa, expected.value,
        \\{"nested":{"a":"x"},"items":[1,true,null],"value":18446744073709551615}
    );
    try std.testing.expectError(error.TestExpectedEqual, common.expectJsonText(gpa, expected.value,
        \\{"value":18446744073709551614,"items":[1,true,null],"nested":{"a":"x"}}
    ));
    try std.testing.expectError(error.TestExpectedEqual, common.expectJsonText(gpa, expected.value,
        \\{"value":18446744073709551615,"items":[true,1,null],"nested":{"a":"x"}}
    ));
}
