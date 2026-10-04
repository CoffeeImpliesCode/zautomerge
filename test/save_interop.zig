//! The live half of the save interop: this port's own saves, and the
//! reference's answer to them.
//!
//! Two modes, and between them they close the loop in **both** directions:
//!
//! * **dump** (the default, and `dump` spelled out) builds all six scenarios
//!   through [`save_interop_scenarios`] and writes one
//!   `{"kind":"port-save","scenario":…,"hex":…}` NDJSON record each to stdout,
//!   where `hex` is this port's **default compressed `save()`**. That is the
//!   request `tools/oracle`'s `verify-save-interop` reads on stdin.
//! * **`verify <response-file>`** reads the `{"kind":"cross-loaded", …}` records
//!   that command wrote and, for each of the six, **rebuilds the scenario
//!   independently** and checks the reference's re-save against that rebuild:
//!   the head set, every change by hash identity with its `seq`, `start_op` and
//!   whole framed chunk, the reference's bytes loading through this port's
//!   reader with `debugCmp` and hydration equality behind it, and the two
//!   default saves normalizing to the same body.
//!
//! **Nothing in a record is taken on trust.** The only fields read are the ones
//! the comparison needs, and the document they are compared against is built
//! here from the same script the oracle builds its own from — which is what
//! makes a passing run evidence about the two implementations rather than a
//! tautology about the file.
//!
//! This is a **smoke proof with a process exit code**, not an assert-only
//! library of helpers: `zig build save-interop` runs this in dump mode, feeds its
//! stdout to the oracle's verifier, and runs this again in `verify` mode over the
//! oracle's answer. A mismatch is a nonzero exit and a named case on stderr.

const std = @import("std");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

/// The scripts, and the comparisons both directions of the interop make.
const scenarios = @import("save_interop_scenarios.zig");

const Allocator = std.mem.Allocator;

/// Ceiling on the response file, four times what six records of this shape need:
/// each carries a whole document in hex.
const max_response_bytes = 1 << 23;

/// The buffer stdout is written through. A record is written in a few `writeAll`
/// calls, so this bounds the syscall count rather than the size of a write.
const stdout_buffer_len = 64 * 1024;

/// How many bytes of a save are hexed at a time. [`writeHex`] renders each chunk
/// into a stack buffer, so a document's hex never becomes one heap allocation.
const hex_chunk_bytes: usize = 2048;

/// What `zig build save-interop` runs, and what a person can run by hand.
const usage =
    \\usage: save-interop [dump]
    \\       save-interop verify <response-file>
    \\
    \\  dump            build the six scenarios and write one
    \\                  {"kind":"port-save","scenario":…,"hex":…} record each to stdout
    \\  verify <file>   read the oracle's cross-loaded records from <file> and check
    \\                  each against a scenario rebuilt here
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len <= 1) return dump(gpa, io);
    const command = args[1];

    if (std.mem.eql(u8, command, "dump")) {
        if (args.len != 2) return usageError("`dump` takes no further arguments");
        return dump(gpa, io);
    }

    if (std.mem.eql(u8, command, "verify")) {
        if (args.len != 3) return usageError("`verify` takes exactly one response file");
        return verify(gpa, io, args[2]);
    }

    return usageError("unknown command");
}

fn usageError(comptime message: []const u8) !u8 {
    std.debug.print("save-interop: {s}\n\n{s}", .{ message, usage });
    return 2;
}

/// Builds all six scenarios and writes one request record each to stdout, **in
/// [`scenarios.ids`] order** — the order the oracle reads them in and the order
/// its answer comes back in, so the two ends of the pipe can be lined up by eye
/// when something fails.
fn dump(gpa: Allocator, io: std.Io) !u8 {
    var stdout_buffer: [stdout_buffer_len]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    for (scenarios.ids) |id| {
        var doc = try scenarios.build(gpa, io, id);
        defer doc.deinit();

        // **The default save, and not a no-compression one.** This is the
        // request the oracle's own reader takes as the thing it must load and
        // check, so a `save_nocompress` here would check a document shape the
        // interop claim is not about.
        const saved = try doc.save(gpa);
        defer gpa.free(saved);

        try out.print(
            "{{\"kind\":\"{s}\",\"scenario\":\"{s}\",\"hex\":\"",
            .{ scenarios.request_kind, id.name() },
        );
        try writeHex(out, saved);
        try out.writeAll("\"}\n");
    }

    try out.flush();
    return 0;
}

/// `bytes` as lowercase hex, written through `out` in [`hex_chunk_bytes`] pieces.
/// Each chunk starts on a byte boundary and every byte becomes two characters,
/// so the concatenation is the hex of the whole.
fn writeHex(out: *std.Io.Writer, bytes: []const u8) !void {
    var scratch: [hex_chunk_bytes * 2]u8 = undefined;
    var rest = bytes;
    while (rest.len != 0) {
        const take = @min(rest.len, hex_chunk_bytes);
        am.error_types.hexInto(rest[0..take], scratch[0 .. take * 2]);
        try out.writeAll(scratch[0 .. take * 2]);
        rest = rest[take..];
    }
}

/// Checks the oracle's `cross-loaded` records against a rebuild of each
/// scenario.
///
/// **All six are attempted even when one fails**, so a single run says how much
/// is broken rather than only naming the first thing that was; the exit code is
/// nonzero if any of them failed.
fn verify(gpa: Allocator, io: std.Io, path: []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // **Straight into the arena**: every string in every record borrows out of
    // this text, so one release covers the file and the parse together.
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_response_bytes)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => {
            std.debug.print("save-interop: {s}: no such file\n", .{path});
            return 2;
        },
        else => return e,
    };

    const records = scenarios.parseRecords(arena, text) catch |e| {
        std.debug.print("save-interop: {s}: {s}\n", .{ path, @errorName(e) });
        return 2;
    };

    // **Cardinality and uniqueness before anything is checked.** A response file
    // that names five of the six scenarios, or names one twice, would otherwise
    // let this report five checked cases and exit zero.
    var failed: usize = 0;
    for (scenarios.ids) |id| {
        const record = scenarios.requireEveryScenario(records, id, path) catch |e| {
            std.debug.print("save-interop: {s}: {s}\n", .{ path, @errorName(e) });
            return 2;
        };
        // The kind is checked inside `checkCase`, so a response file carrying
        // the other corpus's records fails the comparison rather than a
        // separate loop here.
        scenarios.checkCase(gpa, io, id, record, scenarios.cross_loaded_kind) catch {
            failed += 1;
        };
    }

    const checked = scenarios.id_count - failed;
    if (failed != 0) {
        std.debug.print(
            "save-interop: {d} of {d} cases verified from {s}; {d} failed\n",
            .{ checked, scenarios.id_count, path, failed },
        );
        return 1;
    }

    std.debug.print(
        "save-interop: {d} of {d} cases verified from {s}\n",
        .{ checked, scenarios.id_count, path },
    );
    return 0;
}
