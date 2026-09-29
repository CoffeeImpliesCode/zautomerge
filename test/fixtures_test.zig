//! Checks that the corpus and its manifest agree.
//!
//! The corpus is 18 files copied verbatim from the upstream Rust
//! implementation, and the manifest states what loading each one must do. A
//! file with no manifest entry is a fixture no test can reach; a manifest
//! entry with no file is a fixture that has gone missing. Both are silent
//! losses otherwise, because the loader is driven from the manifest.

const std = @import("std");
const manifest = @import("fixtures/manifest.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// The corpus, relative to the process working directory. Tests run from the
/// build root, which is the package root.
const fixture_dir = "test/fixtures";

/// The manifest is a Zig source file that lives inside the corpus it
/// describes, so it is not itself a fixture.
const manifest_name = "manifest.zig";

/// Every file in the corpus is an automerge document or change, and every
/// one of them starts with the 4-byte magic.
const magic = [_]u8{ 0x85, 0x6f, 0x4a, 0x83 };

/// Ceiling on a single fixture, so a runaway file cannot exhaust memory. The
/// largest file upstream is 406 bytes.
const max_fixture_bytes = 1 << 20;

/// The 8 files upstream commits under `rust/automerge/tests/fuzz-crashers/`.
/// `tests/test.rs:2210-2219` asserts that loading each one is an error. They
/// are named here independently of the manifest, so that flipping a
/// `load_err` to `load_ok` fails here.
const fuzz_crashers = [_][]const u8{
    "action-is-48.automerge",
    "crash-da39a3ee5e6b4b0d3255bfef95601890afd80709",
    "incorrect_max_op.automerge",
    "invalid_deflate_stream.automerge",
    "missing_actor.automerge",
    "overflow_in_length.automerge",
    "too_many_deps.automerge",
    "too_many_ops.automerge",
};

/// The manifest entry for `name`, or null when the manifest does not name it.
fn entryFor(name: []const u8) ?manifest.Fixture {
    for (manifest.fixtures) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// Reports `msg` and fails the test. Kept in one place so every failure here
/// names the file and the reason.
fn fail(comptime fmt: []const u8, args: anytype) error{ManifestOutOfSync} {
    std.debug.print("fixtures_test: " ++ fmt ++ "\n", args);
    return error.ManifestOutOfSync;
}

test "the manifest and the corpus directory hold the same files" {
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{ .iterate = true });
    defer dir.close(io);

    // Every file on disk must be in the manifest, and the manifest must not
    // be the only place a name appears.
    var on_disk: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, manifest_name)) continue;
        if (entry.kind != .file) {
            std.debug.print("fixtures_test: {s}/{s} is not a plain file\n", .{ fixture_dir, entry.name });
            return error.ManifestOutOfSync;
        }
        if (entryFor(entry.name) == null) {
            return fail("{s}/{s} is on disk but has no manifest entry", .{ fixture_dir, entry.name });
        }
        on_disk += 1;
    }

    // Every manifest entry must be on disk. Reading it is the check, so a
    // truncated or unreadable copy fails here rather than in a loader test.
    for (manifest.fixtures) |f| {
        const bytes = dir.readFileAlloc(io, f.name, gpa, .limited(max_fixture_bytes)) catch |err| switch (err) {
            error.FileNotFound => return fail("manifest names {s}, which is not in {s}/", .{ f.name, fixture_dir }),
            else => return err,
        };
        defer gpa.free(bytes);
        on_disk -= 1;
    }

    try std.testing.expectEqual(@as(usize, 0), on_disk);
    try std.testing.expect(manifest.fixtures.len > 0);
}

test "every fixture is readable, non-empty, and starts with the document magic" {
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{ .iterate = true });
    defer dir.close(io);

    for (manifest.fixtures) |f| {
        const bytes = try dir.readFileAlloc(io, f.name, gpa, .limited(max_fixture_bytes));
        defer gpa.free(bytes);

        if (bytes.len == 0) return fail("{s} is empty", .{f.name});
        if (bytes.len < magic.len) return fail("{s} is {d} bytes, too short for the magic", .{ f.name, bytes.len });
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) {
            std.debug.print("fixtures_test: {s} starts with {x}\n", .{ f.name, bytes[0..magic.len] });
            return error.NotAnAutomergeDocument;
        }
    }
}

test "the manifest names no file twice" {
    for (manifest.fixtures, 0..) |f, i| {
        for (manifest.fixtures[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, f.name, other.name));
        }
    }
}

test "the 8 upstream fuzz crashers are load_err" {
    try std.testing.expectEqual(@as(usize, 8), fuzz_crashers.len);
    for (fuzz_crashers) |name| {
        const f = entryFor(name) orelse return fail("{s} is an upstream crasher but has no manifest entry", .{name});
        try std.testing.expectEqual(manifest.Fixture.Expect.load_err, f.expect);
    }
}

test "the manifest says load_err for every fixture whose name starts with crash-" {
    for (manifest.fixtures) |f| {
        if (!std.mem.startsWith(u8, f.name, "crash-")) continue;
        try std.testing.expectEqual(manifest.Fixture.Expect.load_err, f.expect);
    }
}
