//! Peak-RSS gate for `am.anonymize`'s per-change arena.
//!
//! WHY THIS IS NOT A `BENCH` WORKLOAD
//!
//! The other three gates the audit asked for are instruction counts, and
//! `zautomerge_bench.zig` reports those. This one is not: the question
//! `src/anonymize.zig:440` answers is what the rewrite's **arena** costs, and
//! an arena's cost is peak resident bytes, which no nanosecond figure says
//! anything about. So this is a separate, small executable that builds a
//! document, anonymizes it, and gets out of the way so that `time -v` can read
//! its peak. `bench/README.md` §8 has the exact command line, the
//! `build_options` stub it needs, and the two sizes to compare.
//!
//! WHAT IS BEING GATED
//!
//! `Anonymize.run` builds each rewritten change in `self.arena` and resets it
//! at the end of every change (`src/anonymize.zig:395-440`), which is what
//! makes the arena's peak **one change** rather than the whole document. If a
//! change moved that line, or dropped it, the arena would accumulate every
//! change's rewritten strings, column payloads and footer, and peak RSS would
//! roughly **double**: once for the source document, once for the arena's copy
//! of all of it.
//!
//! So the gate is a **ratio**, not a number: build the same shape at two
//! change counts and check the peak does not grow with the count. That is why
//! every count here is a command-line argument.
//!
//! THE CHECKS ARE DELIBERATELY CHEAP
//!
//! A program that measures peak RSS must not itself allocate in proportion to
//! the document, or it measures itself. Everything asserted below is a point
//! read or a prefix count. `am.anonymize.checkPrivateDataChanged` — the port's
//! own thorough oracle — allocates both documents' worth of re-encoded
//! changes and therefore dominates peak RSS; it is behind `--check` and the
//! README says it is not for the gate run.
//!
//! Everything goes to **stderr** through `std.debug.print`, which is this
//! repository's idiom (`test/save_interop.zig:85`), so `time -v`'s report and
//! this program's narration arrive together and neither pollutes the other's
//! parsing.

const std = @import("std");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

const Io = std.Io;
const Document = am.doc.Document;

/// The source actor. One, because the rewrite's actor map is a separate
/// question and a second actor would only make the fixture noisier.
const source_actor = "anonymize-rss-source";

/// The register the hand-written value check reads back. It is `k0-0`, the
/// first key the fixture below writes, spelled out so the check does not
/// depend on the fixture's format string staying the same shape.
const first_key = "k0-0";
const first_value = "v0-0";

const usage =
    \\usage: anonymize_rss [--changes N] [--ops N] [--check]
    \\
    \\  --changes N  committed changes in the source document (default 4000)
    \\  --ops N      map puts committed per change (default 20)
    \\  --check      also run am.anonymize.checkPrivateDataChanged, which
    \\               dominates peak RSS and is NOT part of the gate run
    \\
;

/// A machine-readable summary line, so the number can be paired with the
/// `Maximum resident set size` line beside it.
const marker = "# ANONYMIZE_RSS";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    // Parsed out of `init.arena`, which `std.start` frees after `main`
    // returns, so nothing here outlives the program.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var changes: usize = 4000;
    var ops_per_change: usize = 20;
    var deep_check = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            deep_check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--changes") or std.mem.eql(u8, arg, "--ops")) {
            const is_changes = std.mem.eql(u8, arg, "--changes");
            if (i + 1 >= args.len) {
                std.debug.print("anonymize_rss: {s} wants a count\n", .{arg});
                return 2;
            }
            const n = std.fmt.parseUnsigned(usize, args[i + 1], 10) catch {
                std.debug.print("anonymize_rss: {s} wants a count, got '{s}'\n", .{ arg, args[i + 1] });
                return 2;
            };
            if (is_changes) changes = n else ops_per_change = n;
            i += 1;
            continue;
        }
        std.debug.print("anonymize_rss: unknown option '{s}'\n\n{s}", .{ arg, usage });
        return 2;
    }
    if (changes == 0 or ops_per_change == 0) {
        std.debug.print("anonymize_rss: both counts must be at least 1\n", .{});
        return 2;
    }

    // ── the fixture ──
    //
    // A `.manual` document, one transaction and one commit per change, so the
    // change count is exactly `changes` (plus the one that makes the list).
    // **Committed changes and not one transaction**: the arena under test is
    // reset once per *change*, so a fixture that packed every operation into
    // one change would never enter the loop this program is measuring.
    var src = try Document.init(gpa, init.io, .manual);
    defer src.deinit();
    src.setActorId(.{ .bytes = source_actor });

    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    {
        var setup = try am.manual_transaction.Transaction.open(gpa, &src);
        defer setup.deinit();
        _ = try setup.putObject(am.root, .{ .key = "items" }, .list);
        _ = try am.manual_transaction.commitWith(
            &setup,
            am.manual_transaction.CommitOptions.none,
        );
    }

    for (0..changes) |c| {
        var tx = try am.manual_transaction.Transaction.open(gpa, &src);
        defer tx.deinit();
        for (0..ops_per_change) |k| {
            const key = try std.fmt.bufPrint(&key_buf, "k{d}-{d}", .{ c, k });
            const value = try std.fmt.bufPrint(&val_buf, "v{d}-{d}", .{ c, k });
            _ = try tx.put(am.root, .{ .key = key }, .{ .str = value });
        }
        _ = try am.manual_transaction.commitWith(&tx, am.manual_transaction.CommitOptions.none);
    }

    const registers = changes * ops_per_change;
    std.debug.print("# fixture: {d} changes x {d} puts = {d} root registers\n", .{
        changes,
        ops_per_change,
        registers,
    });

    // Any seed will do: the question is how much memory the rewrite holds, not
    // which bytes it picks. A fixed one keeps two runs byte-for-byte
    // comparable.
    var seed: [am.anonymize.seed_length]u8 = undefined;
    @memset(&seed, 0xA5);

    // ── the measured call ──
    const started = Io.Clock.Timestamp.now(init.io, .awake);
    var anon = try am.anonymize.anonymize(gpa, &src, seed);
    const ns: u64 = @intCast(started.untilNow(init.io).raw.nanoseconds);
    defer anon.deinit();

    // ── correctness, at a cost that does not scale with the document ──
    //
    // `am.read.length` on the root map is a prefix count, so both of these
    // cost the same on eight thousand changes as on one. A rewrite that
    // dropped or duplicated a register fails here rather than quietly making
    // the program cheaper.
    const src_registers = try am.read.length(&src, am.root);
    if (src_registers != registers) return error.SourceShapeDiffers;
    const anon_registers = try am.read.length(&anon, am.root);
    if (anon_registers != src_registers) return error.AnonymizedShapeDiffers;

    // And the one register by hand: it held `first_value` before, and holds
    // something that is neither that nor the source's bytes now. A "cheaper"
    // rewrite that skipped the replacement fails on both counts.
    const before = (try am.read.get(&src, am.root, .{ .key = first_key })) orelse
        return error.NoFirstRegisterOnTheSource;
    const after = (try am.read.get(&anon, am.root, .{ .key = first_key })) orelse
        return error.NoFirstRegisterOnTheAnonymized;
    const before_text: []const u8 = switch (before.value) {
        .object => return error.FirstRegisterIsAnObject,
        .scalar => |v| switch (v) {
            .str => |s| s,
            else => return error.FirstRegisterIsNotAString,
        },
    };
    const after_text: []const u8 = switch (after.value) {
        .object => return error.FirstRegisterIsAnObject,
        .scalar => |v| switch (v) {
            .str => |s| s,
            else => return error.FirstRegisterIsNotAString,
        },
    };
    if (!std.mem.eql(u8, before_text, first_value)) return error.SourceRegisterHoldsSomethingElse;
    if (std.mem.eql(u8, after_text, before_text)) return error.AnonymizeCopiedTheValue;
    if (std.mem.eql(u8, after_text, first_value)) return error.AnonymizeKeptTheValue;

    if (deep_check) {
        std.debug.print("# running checkPrivateDataChanged; its own peak RSS dominates\n", .{});
        try am.anonymize.checkPrivateDataChanged(gpa, &src, &anon);
    }

    std.debug.print("{s} changes={d} ops={d} ns={d}\n", .{ marker, changes, ops_per_change, ns });
    std.debug.print(
        "# peak resident bytes are the `Maximum resident set size (kbytes)` line above; run this at two change counts and compare\n",
        .{},
    );
    return 0;
}
