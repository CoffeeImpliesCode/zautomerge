//! The codec differential corpus: what the Rust reference encoded, and the
//! machinery to hold this port to it.
//!
//! `docs/plan.md` §P2 asks for "every codec round-trips bytes for random
//! inputs against the Rust". Half of that is a round trip and half of a round
//! trip is a tautology: an encoder and a decoder that agree with each other
//! say nothing about whether the reference reads the same bytes, and the
//! reference is what the compatibility contract is written against. So this
//! module carries the reference's own bytes, and the tests beside it compare
//! the port's bytes to those.
//!
//! # The corpus
//!
//! `test/golden/codec.jsonl` is written by `tools/oracle`'s `codec`
//! subcommand (`tools/oracle/src/codec.rs`), which drives the reference's own
//! encoders — `RleEncoder`, `BoolEncoder`, `DeltaEncoder`, `PrefixColumn` and
//! the load-time slab cutter — over a corpus of values and prints what came
//! out. One JSON record per case:
//!
//! * `kind: "codec-lcg"` — the generator's multiplier, increment, base seed
//!   and its first sixteen states, so the two implementations of the
//!   generator can be held to each other.
//! * `kind: "codec"` — one case of one codec: its name, its seed, its input
//!   as maximal runs, **the reference's bytes**, and the reference's own
//!   metadata for them (item count, run count, tail, and where its loader
//!   would cut them). A prefix column's record also carries the reference's
//!   `get_prefix` for every index and its `get_index_for_prefix` answers.
//! * `kind: "codec-btree"` — one case of the delta column's B-tree: the
//!   values, and for each range the reference's `find_by_range` answer.
//!
//! **The values are printed as runs, not as a list.** A 16 385-value repeat
//! run is 16 385 numbers in a file and about twenty bytes as `[[16385, "1"]]`,
//! and the form is lossless: [`expand`] turns it back into the exact input
//! both sides encoded.
//!
//! # What a test here asserts, and what it does not
//!
//! Every comparison is against bytes the **reference** produced. Nothing in
//! this file re-derives an answer the port could agree with by
//! construction, and no test here asserts a round trip. The one thing
//! asserted that is not a byte comparison is the LCG: the corpus came out of
//! a generator, and a test that replays a corpus without being able to
//! reproduce the generator cannot say which corpus it replayed.
//!
//! # The two fields that are in the reference's units
//!
//! `segments` and `split` are the reference's own answers about its own
//! loader, and neither is in a unit this port counts in. Upstream's
//! `Slab.segments` costs a literal run its number of values and a repeat
//! or null run one (`rle/load.rs:38-39`, `:43-45`, `:50-52`), which is
//! also what its `check_invariants` asserts a slab's own count equals
//! (`column.rs:1316-1319`); this port costs every run one, in `measure`
//! and `Slab.segments`. So the load cuts at 32 of *its own* runs where
//! the reference cut at 32 of *its own* segments, and on a slab of literal
//! values those are different places.
//!
//! **Neither field is in the compatibility contract.** The change encoding
//! is written by a fresh `RleEncoder` over the range's values
//! (`columnar/column_range/rle.rs:102-113`), never from slab bytes, and
//! `SlabInfo` — where both fields come from — is what
//! `ColumnEncoding::validate_encoding` returns, which its own
//! documentation calls "intended for testing and debugging"
//! (`encoding.rs:36-40`, `:369-377`). `slab.zig`'s gate pins both numbers
//! and checks every read of every record against the reference's own
//! values; the diff block at the foot of that file has the citations.

const std = @import("std");
const err = @import("../error.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The corpus, relative to the process working directory. A unit test binary
/// inherits the directory it was started in, which is the package root under
/// `zig build test` and this file's own directory under a direct `zig test`,
/// so the path is probed rather than assumed.
const golden_paths = [_][]const u8{
    "test/golden/codec.jsonl",
    "../test/golden/codec.jsonl",
    "../../test/golden/codec.jsonl",
};

/// The corpus's own size limit, four times the file as generated. The
/// corpus is a few megabytes of records; a limit rather than a bare read is
/// what keeps a wrong path from reading a directory tree.
const golden_limit: usize = 1 << 24;

/// Reads the codec corpus, or returns `error.GoldenVectorsNotFound` naming
/// the paths that were tried.
pub fn readGolden(gpa: Allocator) ![]u8 {
    for (golden_paths) |path| {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(golden_limit)) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
    }
    std.debug.print("codec.jsonl not found; tried", .{});
    for (golden_paths) |path| std.debug.print(" {s}", .{path});
    std.debug.print("\n", .{});
    return error.GoldenVectorsNotFound;
}

/// One range query of a btree record, as the oracle recorded it.
pub const Query = struct {
    /// The half-open lower bound, a decimal string.
    lo: []const u8,
    /// The half-open upper bound, a decimal string.
    hi: []const u8,
    /// Every index whose realized value lies in `[lo, hi)`, in index order.
    items: []const usize,
};

/// Where the reference's **loader** cuts a slab, as the oracle recorded it.
///
/// Its own object rather than two loose fields on the record, so the item
/// counts and the budget that produced them cannot be read apart.
pub const Split = struct {
    /// The item count of each slab the loader produced, in order.
    ///
    /// **Every slab but the last.** The reference's loader cuts a slab as
    /// its segment count reaches the target and flushes the trailing one in
    /// `finalize` (`rle/load.rs:220-222`, `:259-261`); the oracle drains
    /// with `try_next_run` and never calls `finalize`
    /// (`tools/oracle/src/codec.rs:1146-1156`), so the trailing slab is not
    /// in the record. Whatever these do not add up to is that one slab, and
    /// a comparison has to say so rather than expect one entry per slab.
    lens: []const usize = &.{},
    /// The budget the loader was given. It cuts at half of it.
    loader_max_segments: usize = 0,
};

/// One line of `test/golden/codec.jsonl`.
///
/// **Every field has a default and unknown fields are ignored**, because the
/// three record kinds share one struct and the oracle is free to grow a
/// field: a new one must not stop this file from reading the corpus, and a
/// missing one must not stop a record from being read at all.
pub const Record = struct {
    /// `codec-lcg`, `codec` or `codec-btree`.
    kind: []const u8 = "",
    /// The column type, e.g. `rle-i64`, `bool`, `delta-u32`, `prefix-u64`.
    codec: []const u8 = "",
    /// `rle`, `bool`, `delta`, `prefix` or `btree`.
    family: []const u8 = "",
    /// The case's name, unique within its family.
    case: []const u8 = "",
    /// The seed its values came from, sixteen hex digits. Zero for the
    /// hand-built boundary cases, which have no stream.
    seed: []const u8 = "",
    /// How many values `runs` holds once expanded.
    len: usize = 0,
    /// The input, as maximal runs: `[count, value]`, where the value is a
    /// decimal string or `null` for an absent one. A boolean value is `"0"`
    /// or `"1"`.
    runs: []const []const std.json.Value = &.{},
    /// **The reference's bytes for that input**, lowercase hex.
    hex: []const u8 = "",
    /// The item count the reference's `validate_encoding` reported.
    slab_len: usize = 0,
    /// The **segment** count the reference's `validate_encoding` reported,
    /// in the reference's own unit: a literal run costs its number of
    /// values and a repeat or null run costs one (`rle/load.rs:38-39`,
    /// `:43-45`, `:50-52`). It is not this port's run count, which costs
    /// every run one, and the two part company on every literal run of more
    /// than one value.
    segments: usize = 0,
    /// The byte width of the last run, in the reference's tail metadata.
    tail_bytes: u64 = 0,
    /// The width of the last value of a literal run, or `null` when the last
    /// run is not a literal one. The reference's `None` (`rle/mod.rs:101-103`),
    /// which is `0` in this port's `Tail.lit_tail`, so the two are compared
    /// exactly and a `null` is a zero rather than an absence.
    tail_lit_tail: ?u64 = null,
    /// Where the reference's **loader** cuts the bytes, at its own budget.
    /// Every slab but the last; see [`Split`].
    split: ?Split = null,
    /// Prefix columns: the reference's `get_prefix(i)` for `i` in
    /// `0..=len`, so `len + 1` decimal strings.
    prefixes: ?[]const []const u8 = null,
    /// Prefix columns: the targets `indexes` answers, as decimal strings.
    index_targets: ?[]const []const u8 = null,
    /// Prefix columns: the reference's `get_index_for_prefix` for each
    /// target, or `null` where the reference has no such method.
    indexes: ?[]const []const u8 = null,
    /// Btree cases: the range queries and the reference's answers.
    queries: ?[]const Query = null,
    // The `codec-lcg` record, and only that one.
    mul: []const u8 = "",
    add: []const u8 = "",
    states: ?[]const []const u8 = null,
};

/// Whether `rec` is a `codec` record of `family`.
pub fn isFamily(rec: Record, family: []const u8) bool {
    return std.mem.eql(u8, rec.kind, "codec") and std.mem.eql(u8, rec.family, family);
}

/// Runs `body` for the entry of `table` whose `name` equals `rec.codec`, and
/// fails when the corpus names a type this port does not have.
///
/// **A comptime table rather than a `switch` on the name.** Zig will not
/// switch on a `[]const u8`, and a runtime `if` chain cannot name a type at
/// the far end — the codec type has to be known at compile time for
/// `checkOne` to instantiate it. A table of `(name, tag)` pairs and an
/// `inline for` gives every arm a comptime-known tag, and the tag is what
/// each arm switches on.
///
/// A name in the corpus with no entry here is an error rather than a skip: a
/// codec added to the corpus and not to this table would otherwise be a
/// silently shrinking test.
pub fn dispatch(
    comptime table: anytype,
    comptime body: fn (@TypeOf(table[0].tag), Record, Allocator) anyerror!void,
    gpa: Allocator,
    rec: Record,
) !void {
    var matched = false;
    inline for (table) |entry| {
        // A block rather than a `continue`: control flow out of an
        // `inline for` is comptime control flow, which a runtime `if` may
        // not do.
        if (std.mem.eql(u8, rec.codec, entry.name)) {
            try body(entry.tag, rec, gpa);
            matched = true;
        }
    }
    if (matched) return;
    std.debug.print("the corpus carries an unknown codec `{s}`\n", .{rec.codec});
    return error.CorpusCodecUnknown;
}

/// Runs `body` over every `codec` record of `family` in the corpus, and
/// returns how many records it saw.
///
/// The whole file is read once and split, and each line is parsed and freed
/// in turn: a few thousand records need not be resident at once, and a
/// parsed record borrows the file text, which outlives every use of it.
pub fn eachCase(
    gpa: Allocator,
    family: []const u8,
    names: *Names,
    comptime body: fn (Record, Allocator) anyerror!void,
) !usize {
    const text = try readGolden(gpa);
    defer gpa.free(text);
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const rec = parsed.value;
        if (!isFamily(rec, family)) continue;
        seen += 1;
        try names.add(rec.case);
        try body(rec, gpa);
    }
    return seen;
}

/// Runs `body` for every `codec` record in the corpus, whichever family it
/// names, and returns how many records there were.
///
/// `eachCase` filters by family; this one does not, so a caller can ask which
/// family owns which codec without walking the file once per family. That is
/// the question a family answering for a codec it does not own turns on, and
/// a count of the families it does own does not answer it.
pub fn eachCodecRecord(
    gpa: Allocator,
    comptime body: fn (Record, Allocator) anyerror!void,
) !usize {
    const text = try readGolden(gpa);
    defer gpa.free(text);
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const rec = parsed.value;
        if (!std.mem.eql(u8, rec.kind, "codec")) continue;
        seen += 1;
        try body(rec, gpa);
    }
    return seen;
}

/// Checks this port's generator against the corpus's `codec-lcg` record, and
/// returns how many such records the corpus carried.
///
/// **Run before any comparison, and it is its own test.** The corpus is a
/// table of answers whose provenance is the claim that one generator wrote
/// them; without this, a test replaying the corpus cannot say which corpus
/// it replayed, and a corpus regenerated by a different generator would
/// still pass every byte comparison against values neither side chose.
pub fn checkGenerator(gpa: Allocator) !usize {
    const text = try readGolden(gpa);
    defer gpa.free(text);
    var seen: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const rec = parsed.value;
        if (!std.mem.eql(u8, rec.kind, "codec-lcg")) continue;
        seen += 1;
        try Lcg.checkAgainst(rec);
    }
    return seen;
}

/// One run's value, narrowed to `T`.
///
/// A value is a decimal **string** in the corpus, so a `u64::MAX` row length
/// survives the round trip through JSON exactly; `null` is an absent value,
/// and a boolean is `"0"` or `"1"`.
fn valueOf(comptime T: type, jv: std.json.Value) !T {
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (jv == .null) return null;
            return try valueOf(o.child, jv);
        },
        .bool => return !std.mem.eql(u8, jv.string, "0"),
        .int => return std.fmt.parseInt(T, jv.string, 10),
        else => @compileError("a codec element is an integer, a bool, or an optional of one"),
    }
}

/// `rec`'s input, expanded into a freshly allocated slice of `T`. The
/// caller owns the result.
///
/// **`rec.len` is checked against the expansion**, because a run list whose
/// counts do not add up would silently encode a different input than the one
/// the reference saw, and every comparison after that would be against the
/// wrong question.
pub fn expand(gpa: Allocator, comptime T: type, rec: Record) ![]T {
    var total: usize = 0;
    for (rec.runs) |run| {
        const count = std.math.cast(usize, run[0].integer) orelse return error.CorpusValueTooLarge;
        total = std.math.add(usize, total, count) catch return error.CorpusValueTooLarge;
    }
    if (total != rec.len) return error.CorpusRunCountMismatch;
    const out = try gpa.alloc(T, total);
    errdefer gpa.free(out);
    var at: usize = 0;
    for (rec.runs) |run| {
        const count: usize = @intCast(run[0].integer);
        const v = try valueOf(T, run[1]);
        for (0..count) |_| {
            out[at] = v;
            at += 1;
        }
    }
    return out;
}

/// `rec`'s input as realized `i64` values, for the btree cases. A `null`
/// row is skipped: the reference's btree records carry no nulls, because
/// `DeltaColumn<i64>` is not a nullable type.
pub fn expandValues(gpa: Allocator, rec: Record) ![]i64 {
    return expand(gpa, i64, rec);
}

/// The reference's bytes for `rec`. The caller owns the result.
pub fn referenceBytes(gpa: Allocator, rec: Record) ![]u8 {
    return err.hexFrom(gpa, rec.hex);
}

/// The first index at which two byte slices differ, or `null` when they are
/// equal. A length difference is a difference at the shorter length.
pub fn firstDiff(want: []const u8, got: []const u8) ?usize {
    const n = @min(want.len, got.len);
    for (0..n) |i| {
        if (want[i] != got[i]) return i;
    }
    if (want.len == got.len) return null;
    return n;
}

/// What a mismatch says.
///
/// The whole point of the corpus is that a difference here is a
/// compatibility break and not a test artefact, so the report carries
/// everything needed to reproduce it: the case, the seed, the input, both
/// encodings, and the first byte that differs.
fn reportMismatch(rec: Record, want: []const u8, got: []const u8, what: []const u8) void {
    std.debug.print(
        \\
        \\--- codec differential mismatch ---------------------------------------
        \\  what      {s}
        \\  codec     {s}
        \\  case      {s}
        \\  seed      {s}
        \\  input     {d} values, as runs:
        \\
    , .{ what, rec.codec, rec.case, rec.seed, rec.len });
    for (rec.runs) |run| {
        const count = run[0].integer;
        if (run[1] == .null) {
            std.debug.print("    {d} x null\n", .{count});
        } else {
            std.debug.print("    {d} x {s}\n", .{ count, run[1].string });
        }
    }
    if (firstDiff(want, got)) |at| {
        std.debug.print(
            \\  first difference at byte {d}
            \\    reference  {x:0>2}
            \\    this port  {x:0>2}
            \\
        , .{ at, want[at], got[at] });
    } else {
        std.debug.print("  the bytes agree; the difference is in a length ({d} against {d})\n", .{ want.len, got.len });
    }
    std.debug.print("  reference  {s}\n  this port  {s}\n", .{ want, got });
    std.debug.print(
        \\
        \\A byte difference here is a compatibility break, not a test failure:
        \\the change hash is SHA-256 over the encoded change, so every hash and
        \\every document automerge has already written depends on these bytes.
        \\----------------------------------------------------------------------
        \\
    , .{});
}

/// Asserts that the port's `got` is the reference's `want` for `rec`'s
/// input. Prints [`reportMismatch`] and fails when they differ.
pub fn checkBytes(rec: Record, want: []const u8, got: []const u8) !void {
    if (std.mem.eql(u8, want, got)) return;
    reportMismatch(rec, want, got, "encoded bytes");
    return error.CodecBytesDiffer;
}

/// Encodes `rec`'s input with `Codec` and compares the bytes with the
/// reference's.
///
/// `Element` is the codec's element type, named here because the four codecs
/// spell it differently — `Rle(T)` and `Prefix(T)` have `Element`, `Delta(T)`
/// has `Value` and the boolean codec has none.
pub fn checkOne(
    comptime Codec: type,
    comptime Element: type,
    gpa: Allocator,
    rec: Record,
) !void {
    const values = try expand(gpa, Element, rec);
    defer gpa.free(values);
    const out = try gpa.alloc(u8, Codec.encodedSize(values));
    defer gpa.free(out);
    Codec.write(out, values);
    const want = try referenceBytes(gpa, rec);
    defer gpa.free(want);
    try checkBytes(rec, want, out);
}

// ── The generator ────────────────────────────────────────────────────────────

/// The corpus's 64-bit LCG, `state = state * mul + add`, both wrapping.
///
/// **The same three constants as `tools/oracle/src/codec.rs`**, and the
/// `codec-lcg` record publishes the reference's first sixteen states, so
/// [`Lcg.checkAgainst`] can prove the two implementations are one generator
/// rather than two that happen to have been written down twice.
pub const Lcg = struct {
    state: u64,

    pub fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    /// The next state, which is also the next output.
    pub fn next(self: *Lcg) u64 {
        self.state = self.state *% mul +% add;
        return self.state;
    }

    /// A value in `0..n`, or `0` when `n` is zero.
    pub fn below(self: *Lcg, n: u64) u64 {
        if (n == 0) return 0;
        return self.next() % n;
    }

    /// The multiplier `tools/oracle`'s `Lcg` uses.
    pub const mul: u64 = 0x5851_F42D_4C957_F2D;

    /// The increment `tools/oracle`'s `Lcg` uses.
    pub const add: u64 = 0x1405_7B7E_F767_814F;

    /// Asserts that this generator, seeded with `rec.seed`, produces exactly
    /// the states the reference's generator produced.
    ///
    /// Without this the corpus is a table of answers whose provenance the
    /// test cannot check: the seed in each record is only as good as the
    /// claim that the same constants produced it.
    pub fn checkAgainst(rec: Record) !void {
        const states = rec.states orelse return error.CorpusRecordMissing;
        try testing.expectEqualStrings("codec-lcg", rec.kind);
        try testing.expectEqualStrings("5851f42d4c957f2d", rec.mul);
        try testing.expectEqualStrings("14057b7ef767814f", rec.add);
        const seed = try std.fmt.parseInt(u64, rec.seed, 16);
        var rng = Lcg.init(seed);
        for (states) |want| {
            const got = rng.next();
            const want_state = try std.fmt.parseInt(u64, want, 16);
            if (got != want_state) {
                std.debug.print(
                    \\
                    \\--- corpus generator mismatch ---------------------------------------
                    \\  seed      {s}
                    \\  state     reference {s}
                    \\            this port {x:0>16}
                    \\
                    \\The corpus was generated by a different generator than this one, so a
                    \\codec comparison over it is not comparing the same inputs.
                    \\----------------------------------------------------------------------
                    \\
                , .{ rec.seed, want, got });
                return error.CorpusGeneratorMismatch;
            }
        }
    }
};

/// The names of the cases a corpus has to carry, checked by [`Names`].
///
/// **A coverage list, not a test of behaviour.** A corpus that quietly loses
/// a boundary case is a weaker test than it looks and nothing else says so,
/// so the case names the boundary cases are built from are pinned here.
pub const Names = struct {
    gpa: Allocator,
    seen: std.ArrayList([]const u8),

    pub fn init(gpa: Allocator) Names {
        return .{ .gpa = gpa, .seen = .empty };
    }

    pub fn deinit(self: *Names) void {
        for (self.seen.items) |name| self.gpa.free(name);
        self.seen.deinit(self.gpa);
    }

    /// Records a case name, **copied**.
    ///
    /// A parsed record's strings live in the parse arena, which is freed the
    /// moment the record is done with, and the corpus outlives every one of
    /// those records — so a name borrowed from a record is a dangling slice
    /// by the time the coverage list asks about it.
    pub fn add(self: *Names, name: []const u8) !void {
        if (self.has(name)) return;
        try self.seen.append(self.gpa, try self.gpa.dupe(u8, name));
    }

    pub fn has(self: *const Names, name: []const u8) bool {
        for (self.seen.items) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    /// Fails, naming every case in `required` the corpus did not carry.
    pub fn expectRequired(self: *const Names, required: []const []const u8) !void {
        var missing: usize = 0;
        for (required) |name| {
            if (self.has(name)) continue;
            missing += 1;
            std.debug.print("  missing boundary case `{s}`\n", .{name});
        }
        if (missing == 0) return;
        std.debug.print("--- the codec corpus is missing {d} boundary case(s)\n", .{missing});
        return error.BoundaryCaseMissing;
    }
};
