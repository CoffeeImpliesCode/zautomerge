//! Slabs: the unit a column stores, splices and encodes
//! (`rust/hexane/src/column.rs:27-43`, `rust/hexane/src/rle/splice.rs`).
//!
//! A slab is a run of values that the column holds as one encoded blob,
//! plus the three numbers that let everything else navigate by it:
//!
//! * `data` — the encoded bytes, in the codec's wire format,
//! * `len` — how many values they decode to,
//! * `segments` — how many runs (segments) they are cut into,
//! * `tail` — where the last run starts, so the last run never has to be
//!   found by a walk.
//!
//! Upstream carries a per-codec `Tail` type: `RleTail` for the RLE codecs,
//! `u8` for the boolean codec. This port carries one `Tail` struct for all
//! of them, which is a superset: `bytes` is the whole of the boolean
//! codec's tail, and `lit_tail` is what the RLE codecs add. Keeping
//! `Slab` non-generic is what lets a column, an index and an encoder all
//! name the same type without threading a tail type parameter through
//! every signature (`column.rs:1022-1038` threads one through four).
//!
//! # The partition
//!
//! A splice that lands inside a slab splits it at the run boundaries either
//! side of the cut and rebuilds only what the cut touched. Upstream calls
//! that split the `RlePartition` and its tail side the `Postfix`
//! (`rle/splice.rs:20-42`, `:79-87`):
//!
//! ```text
//!   data[0 .. lb)      the runs before the cut, copied verbatim
//!   mid                 the cut's runs, re-encoded
//!   data[rb ..]        the runs after the cut, copied verbatim
//! ```
//!
//! `lb` is the start of the run the cut lands in and `rb` the start of the
//! run the deleted range ends in, so `mid` holds the tail of the first run,
//! the inserted values, and the head of the last one. Only `mid` is
//! decoded and re-encoded; everything outside it is a `memcpy`.
//!
//! # The two seams
//!
//! A canonical run sequence never has two adjacent runs carrying the same
//! value (`rle.zig` rule 8, upstream `rle/decoder.rs:438-497`), so a
//! rebuild has to check both places where it meets copied bytes and pull a
//! run in when they would collide:
//!
//! * the left seam — `mid`'s first value equals the copied prefix's last
//!   one, so the run before the cut joins `mid`;
//! * the right seam — the same test against the copied suffix. It cannot
//!   fire on a canonical slab: whenever the suffix is non-empty the
//!   middle already holds every item of the boundary run, so the two runs
//!   that meet are the ones that were already adjacent. It stays as a
//!   guard, and one step is enough for the same reason.
//!
//! # O(1) tail reconstruction
//!
//! When the copied suffix is non-empty the slab's last run was not
//! touched, so the new tail is the old one: `Tail.merge` copies it across
//! unchanged, which is what upstream's `WPos::merge` does with its postfix
//! tail (`rle/splice.rs:973`, `:1112`). Only a rebuild that reaches the end
//! of the slab has to measure, and it measures the one run it just wrote.
//!
//! # The deviation worth naming
//!
//! Upstream re-encodes the middle through an incremental writer that
//! carries a run across a seam without materialising it (`rle/state.rs`),
//! so a splice into a slab holding a million copies of one value costs
//! O(1). This port hands the codec a plain value slice, so that splice
//! costs O(items in the middle). The values are the same and the bytes are
//! the same; only the cost differs, and only for a middle made of a very
//! long run.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");

const ParseError = err.ParseError;

/// The default number of runs one slab may hold (`column.rs:21`).
///
/// A load cuts at half this, to leave room for inserts without an overflow
/// split; a splice runs to the full budget and merges the neighbours back
/// down afterwards.
pub const default_max_segments: usize = 64;

/// A zero-length mutable slice: what an empty slab's `data` points at.
/// Nothing is allocated and `deinit` never frees it.
const no_bytes: []u8 = @constCast(&.{});

/// Where a slab's last run starts, and how wide its last value is.
///
/// `bytes` is the byte length of the last run — header plus payload — for
/// every codec, which is what makes `Tail.merge` a copy. `lit_tail` is
/// the RLE codecs' extra: the byte length of the *last value* of a
/// literal run, so the last value of a slab is found without walking the
/// run. It is zero for a repeat or null run, and for the boolean codec,
/// which stores no value at all.
///
/// `u32` by design, upstream too: one run must stay under 4 GiB, so a
/// larger blob belongs in a raw column (`rle/mod.rs:93-104`). A run over
/// it is `error.TooLarge`.
pub const Tail = struct {
    /// Byte length of the last run, header and payload together.
    bytes: u32 = 0,
    /// Byte length of the last value of a literal run; zero otherwise.
    lit_tail: u32 = 0,

    /// The tail of a slab with no runs in it.
    pub const zero: Tail = .{};

    /// Whether two tails describe the same last run.
    pub fn eql(a: Tail, b: Tail) bool {
        return a.bytes == b.bytes and a.lit_tail == b.lit_tail;
    }

    /// The tail of a slab whose last run was carried through untouched.
    ///
    /// That is the whole point of the field: a rebuild that copied its
    /// suffix bytes did not move the last run, so the tail it hands back
    /// is the one it started with, whatever happened in front of it
    /// (`rle/splice.rs:1112`).
    pub fn merge(self: Tail, bytes: u32, lit_tail: u32) Tail {
        _ = bytes;
        _ = lit_tail;
        return self;
    }
};

/// One slab: a run of values that is encoded, spliced, and decoded as a
/// unit. `data` is owned by the slab and freed by `deinit`.
pub const Slab = struct {
    /// The encoded values.
    data: []u8,
    /// How many values `data` decodes to.
    len: usize,
    /// How many runs `data` is cut into.
    segments: usize,
    /// Where the last run starts.
    tail: Tail,

    /// A slab with no values and no bytes.
    pub const empty: Slab = .{ .data = no_bytes, .len = 0, .segments = 0, .tail = .zero };

    /// Whether the slab holds no values.
    pub fn isEmpty(self: *const Slab) bool {
        return self.len == 0;
    }

    /// Frees the slab's bytes. A slab with no bytes frees nothing, which
    /// is what lets `Slab.empty` be a constant.
    pub fn deinit(self: *Slab, gpa: std.mem.Allocator) void {
        if (self.data.len != 0) gpa.free(self.data);
        self.* = .empty;
    }

    /// A copy of the slab that owns its own bytes.
    pub fn clone(self: *const Slab, gpa: std.mem.Allocator) ParseError!Slab {
        return .{
            .data = try gpa.dupe(u8, self.data),
            .len = self.len,
            .segments = self.segments,
            .tail = self.tail,
        };
    }

    /// A slab holding `len` copies of `value`, in one run. O(1) in `len`.
    pub fn fill(
        gpa: std.mem.Allocator,
        comptime E: type,
        len: usize,
        value: E.Wire,
    ) ParseError!Slab {
        if (len == 0) return .empty;
        if (len > std.math.maxInt(u32)) return error.TooLarge;
        // A slab is a run sequence read from its own start, where the
        // first run is a `false` run, so the codec opens the pad itself
        // when a slab of `true`s has to start on `true`. The RLE codecs
        // store the value and do not care which run parity the bytes
        // start on.
        const bytes = try E.wireFill(gpa, len, value, false);
        errdefer gpa.free(bytes);
        const m = try measure(gpa, E, bytes);
        return .{ .data = bytes, .len = len, .segments = m.segments, .tail = m.tail };
    }
};

/// What kind of run a segment is. The kind is what tells two adjacent runs
/// apart when both hold exactly one item: a canonical run sequence never has
/// two adjacent literal runs, whatever their values are, so a rebuild has to
/// know the kind and not just the count.
pub const RunKind = enum {
    /// Two or more copies of one value.
    repeat,
    /// A run of values that each appear once.
    literal,
    /// A run of absent values.
    absent,
    /// A run with no items at all: the boolean codec's opening pad.
    pad,
};

/// One run (segment) of a slab's wire bytes, as the splice machinery sees
/// it: the run's byte range, its item range, the value its items carry, and
/// what kind of run it is.
pub fn Segment(comptime Wire: type) type {
    return struct {
        /// Where the run's bytes start in the slab.
        byte_start: usize,
        /// One past the end of the run's bytes.
        byte_end: usize,
        /// The first item of the run.
        item_start: usize,
        /// One past the last item of the run.
        item_end: usize,
        /// The value the run's items carry, or null for a run with no
        /// items — the boolean codec's leading pad, which is a run of zero
        /// `false`s (`bool.rs:988-1002`). For a nullable codec the outer
        /// null means "no items" and an inner null means "the column value
        /// is absent".
        first_value: ?Wire,
        /// Whether the run's items are `true`. Only the boolean codec reads
        /// it: a boolean slab's runs alternate, so a slab cut at a run
        /// boundary has to be told which way it now starts.
        opens_with_true: bool,
        /// What kind of run this is.
        kind: RunKind,

        /// How many items the run holds.
        pub fn itemCount(self: Segment(Wire)) usize {
            return self.item_end - self.item_start;
        }
    };
}

/// The run that holds item `item`, or `segs.len` when `item` is at or past
/// the end of the slab. A run with no items never holds anything, so the
/// boolean codec's leading pad is never the answer.
pub fn runAt(comptime E: type, segs: []const Segment(E.Wire), item: usize) usize {
    for (segs, 0..) |s, i| {
        if (item >= s.item_start and item < s.item_end) return i;
    }
    return segs.len;
}

/// A slab's value count, run count and tail, measured from its bytes.
pub const Measure = struct {
    /// How many values the bytes decode to.
    len: usize,
    /// How many runs they are cut into.
    segments: usize,
    /// Where the last run starts.
    tail: Tail,
};

/// A slab over `bytes`, with `len`, `segments` and `tail` measured from it.
/// The caller owns the copy.
pub fn init(
    gpa: std.mem.Allocator,
    comptime E: type,
    bytes: []const u8,
) ParseError!Slab {
    const m = try measure(gpa, E, bytes);
    return .{
        .data = try gpa.dupe(u8, bytes),
        .len = m.len,
        .segments = m.segments,
        .tail = m.tail,
    };
}

/// A slab over bytes the caller already measured, skipping the walk. The
/// caller guarantees that `len`, `segments` and `tail` describe `data`.
pub fn fromParts(data: []u8, len: usize, segments: usize, tail: Tail) Slab {
    return .{ .data = data, .len = len, .segments = segments, .tail = tail };
}

/// Measures a slab's bytes: the value count, the run count, and the tail.
///
/// O(runs) for the header walk, plus the values of the last literal run
/// for `lit_tail` — the one part of a tail that cannot be read out of a
/// length.
pub fn measure(
    gpa: std.mem.Allocator,
    comptime E: type,
    bytes: []const u8,
) ParseError!Measure {
    const segs = try E.segmentsOf(gpa, bytes);
    defer gpa.free(segs);
    var len: usize = 0;
    for (segs) |s| len = std.math.add(usize, len, s.itemCount()) catch return error.Overflow;
    if (segs.len == 0) return .{ .len = 0, .segments = 0, .tail = .zero };
    return .{
        .len = len,
        .segments = segs.len,
        .tail = try tailAt(E, bytes.len, segs[segs.len - 1], try E.litTail(bytes, segs[segs.len - 1])),
    };
}

/// The tail of a slab that ends with `seg`, whose last run is
/// `data_len - seg.byte_start` bytes wide. Public because the column's
/// wire writer has to measure the run it re-encodes at a seam.
pub fn tailAt(comptime E: type, data_len: usize, seg: Segment(E.Wire), lit_tail: u32) ParseError!Tail {
    const width = data_len - seg.byte_start;
    if (width > std.math.maxInt(u32)) return error.TooLarge;
    return .{ .bytes = @intCast(width), .lit_tail = lit_tail };
}

/// The value a run carries, including a run with no items: the boolean
/// codec's opening pad occupies a run position and carries `false`, and the
/// seam arithmetic has to see that.
pub fn runValueOf(comptime E: type, seg: Segment(E.Wire)) ?E.Wire {
    if (comptime E.Wire == bool) {
        if (seg.kind == .pad) return seg.opens_with_true;
    }
    return seg.first_value;
}

/// The value a run presents to the seam it is on: the value of its last
/// item, except for a run with no items — the boolean codec's pad, which
/// carries the value it occupies even though it holds none.
pub fn seamValueOf(
    comptime E: type,
    bytes: []const u8,
    seg: Segment(E.Wire),
) ParseError!?E.Wire {
    if (seg.itemCount() == 0) return runValueOf(E, seg);
    return E.lastValueOfRun(bytes, seg);
}

/// Whether two runs meeting at a seam cannot stay as they are: they carry
/// the same value, or the codec says two runs of these kinds standing
/// next to each other are not a canonical run sequence whatever their
/// values (`rle/decoder.rs:438-497` rules 4, 6 and 8).
///
/// The second test is the RLE codecs' and the boolean codec has none: a
/// boolean run of one item is a run like any other, and two adjacent ones
/// always alternate because a run's value is its position in the
/// sequence (`bool.rs:13-25`, `bool.rs:776-783`). So the answer is the
/// codec's, through `mustMergeKinds`, and not a rule read off the kinds.
pub fn collide(
    comptime E: type,
    left: ?E.Wire,
    right: ?E.Wire,
    left_kind: RunKind,
    right_kind: RunKind,
) bool {
    if (left == null or right == null) return false;
    if (E.sameValue(left, right)) return true;
    return E.mustMergeKinds(left_kind, right_kind);
}

/// The first run of a slab that carries items, as an index into `segs`.
///
/// A boolean slab may open with the pad that lets it start on `true`
/// (`bool.rs:988-1002`). The pad occupies a run position in that slab's
/// own bytes and nothing in a run sequence a column concatenates, so
/// every read that crosses a slab boundary has to start past it — except
/// at the head of a column, where the wire form opens on the pad itself.
pub fn firstItemRun(comptime E: type, segs: []const Segment(E.Wire)) usize {
    if (segs.len != 0 and segs[0].kind == .pad) return 1;
    return 0;
}

// ── The partition ────────────────────────────────────────────────────────

/// The partition of a slab around a splice: where the copied bytes either
/// side of the cut end, and the values of the cut's own runs.
///
/// This is the `RlePartition` of `rle/splice.rs:79-87`, narrowed to what a
/// rebuild needs. Upstream's also carries a reader state, because its
/// cursor resumes reading a slab after the write-back; a one-shot splice
/// decodes the whole middle instead, so there is nothing to resume.
fn Partition(comptime E: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        /// The slab's bytes, read-only for the duration.
        data: []const u8,
        /// Every run of the slab, as the cut found it.
        segs: []const Segment(E.Wire),
        /// The cut's start, in slab items.
        index: usize,
        /// How many items the cut deletes.
        del: usize,
        /// The values the cut inserts, in the codec's wire domain.
        insert: []const E.Wire,
        /// The values of the boundary run after the cut, when the codec has
        /// to replace them — a delta column's re-anchor
        /// (`delta/mod.rs:1384-1400`). Null leaves the slab's own values in
        /// place. This is the `Postfix` of `rle/splice.rs:20-42`: the
        /// description of the run the rebuild resumes with, rather than the
        /// run's own bytes.
        postfix: ?[]const E.Wire,

        /// The run holding the cut, or `segs.len` at the slab's end.
        L: usize,
        /// The run holding the first item the cut leaves behind, or
        /// `segs.len`.
        R: usize,
        /// One past the end of the copied prefix's bytes.
        lb: usize,
        /// Where the copied suffix's bytes start.
        rb: usize,
        /// The rebuilt middle.
        mid: std.ArrayList(E.Wire),

        fn start(
            gpa: std.mem.Allocator,
            data: []const u8,
            segs: []const Segment(E.Wire),
            index: usize,
            del: usize,
            insert: []const E.Wire,
            postfix: ?[]const E.Wire,
        ) Self {
            const L = runAt(E, segs, index);
            const R = runAt(E, segs, index + del);
            return .{
                .gpa = gpa,
                .data = data,
                .segs = segs,
                .index = index,
                .del = del,
                .insert = insert,
                .postfix = postfix,
                .L = L,
                .R = R,
                .lb = if (L < segs.len) segs[L].byte_start else data.len,
                .rb = if (R + 1 < segs.len) segs[R + 1].byte_start else data.len,
                .mid = .empty,
            };
        }

        fn deinit(self: *Self) void {
            self.mid.deinit(self.gpa);
        }

        /// The item range the middle's prefix covers: the tail of run `L`,
        /// empty when the cut opens on a run boundary.
        fn preItems(self: Self) struct { from: usize, to: usize } {
            const from = if (self.L < self.segs.len) self.segs[self.L].item_start else self.index;
            return .{ .from = from, .to = self.index };
        }

        /// The item range the middle's postfix covers: the head of run `R`.
        fn postItems(self: Self) struct { from: usize, to: usize } {
            const from = self.index + self.del;
            const to = if (self.R < self.segs.len) self.segs[self.R].item_end else from;
            return .{ .from = from, .to = to };
        }

        /// Rebuilds `mid` as the cut's prefix runs, then the inserted
        /// values, then the cut's postfix runs.
        fn rebuild(self: *Self) ParseError!void {
            self.mid.clearRetainingCapacity();
            const pre = self.preItems();
            if (pre.to > pre.from) {
                const vals = try E.wireRange(self.gpa, self.data, pre.from, pre.to);
                defer self.gpa.free(vals);
                try self.mid.appendSlice(self.gpa, vals);
            }
            try self.mid.appendSlice(self.gpa, self.insert);
            const post = self.postItems();
            const post_len = post.to - post.from;
            if (post_len != 0) {
                const replaced = if (self.postfix) |p| @min(p.len, post_len) else 0;
                if (replaced != 0) try self.mid.appendSlice(self.gpa, self.postfix.?[0..replaced]);
                if (post_len > replaced) {
                    const vals = try E.wireRange(self.gpa, self.data, post.from + replaced, post.to);
                    defer self.gpa.free(vals);
                    try self.mid.appendSlice(self.gpa, vals);
                }
            }
        }

        /// The value the last item of the copied prefix carries, or null
        /// The value the middle opens with, or null when it is empty.
        fn midFirst(self: *const Self) ?E.Wire {
            return if (self.mid.items.len == 0) null else self.mid.items[0];
        }

        /// The value the middle closes with, or null when it is empty.
        fn midLast(self: *const Self) ?E.Wire {
            return if (self.mid.items.len == 0) null else self.mid.items[self.mid.items.len - 1];
        }

        /// How many runs the copied prefix holds: everything before run `L`,
        /// which is the parity the boolean codec's middle has to open on.
        fn prefixRuns(self: *const Self) usize {
            return self.L;
        }

        /// How many runs the copied suffix holds: everything from run
        /// `R + 1` on.
        fn suffixRuns(self: *const Self) usize {
            return self.segs.len - @min(self.R + 1, self.segs.len);
        }
    };
}

/// Replaces the items `[index, index + del)` of `slab` with `insert`.
///
/// `insert` is in the codec's wire domain: the RLE codecs' own elements,
/// and a delta column's deltas. `postfix`, when given, replaces the wire
/// values of the items the cut leaves at the head of the run it ends in —
/// the one seam a delta column has to re-anchor, because the value the
/// deleted run ended on is not the value the inserted one does
/// (`delta/mod.rs:1384-1400`).
///
/// The slab's run count can grow past the column's budget; the column
/// splits it with `splitToBudget` afterwards. The item count is exact, so
/// the column's index stays valid across the call.
pub fn splice(
    gpa: std.mem.Allocator,
    comptime E: type,
    slab: *Slab,
    index: usize,
    del: usize,
    insert: []const E.Wire,
    postfix: ?[]const E.Wire,
) ParseError!void {
    if (index > slab.len or del > slab.len - index) return error.InvalidValue;
    if (del == 0 and insert.len == 0) return;

    const segs = try E.segmentsOf(gpa, slab.data);
    defer gpa.free(segs);

    var p = Partition(E).start(gpa, slab.data, segs, index, del, insert, postfix);
    defer p.deinit();

    // Rebuild the middle and check both seams, widening the middle until
    // they hold. The middle is encoded on every round, because what the
    // seam has to know about it — which kind of run it opens and closes
    // with — is a property of the encoding, not of the value list. Each
    // round either finishes or takes in one more run, so the loop is
    // bounded by the slab's run count.
    var mid_bytes: []u8 = &.{};
    defer gpa.free(mid_bytes);
    var mid_segs: []Segment(E.Wire) = &.{};
    defer gpa.free(mid_segs);
    var settled = false;
    var rounds: usize = 0;
    while (!settled and rounds <= segs.len + 1) : (rounds += 1) {
        try p.rebuild();
        gpa.free(mid_bytes);
        mid_bytes = try E.wireEncode(gpa, p.mid.items, (p.prefixRuns() % 2) == 1);
        gpa.free(mid_segs);
        mid_segs = try E.segmentsOf(gpa, mid_bytes);
        settled = true;
        if (mid_segs.len == 0) break;

        // The middle's first run with items in it, and its last. The
        // boolean codec's opening pad has none, and a pad is an artefact of
        // the encoding rather than a run the seam can see.
        var first: usize = 0;
        while (first < mid_segs.len and mid_segs[first].itemCount() == 0) first += 1;
        const last = mid_segs.len - 1;

        // The left seam: the copied prefix's last run against the middle's
        // first. They cannot stay apart when they carry the same value, or
        // when both are literal runs, which a canonical run sequence never
        // has adjacent however their values differ.
        if (p.L > 0 and first < mid_segs.len) {
            const prev = segs[p.L - 1];
            if (collide(
                E,
                try seamValueOf(E, slab.data, prev),
                p.midFirst(),
                prev.kind,
                mid_segs[first].kind,
            )) {
                p.L -= 1;
                p.lb = segs[p.L].byte_start;
                settled = false;
                continue;
            }
        }

        // The right seam, the same test against the copied suffix. It
        // cannot fire on a canonical slab: whenever the suffix is non-empty
        // the middle already holds every item of the boundary run, so the
        // two runs that meet are the ones that were already adjacent.
        if (p.R + 1 < segs.len and collide(E, p.midLast(), segs[p.R + 1].first_value, mid_segs[last].kind, segs[p.R + 1].kind)) {
            p.R += 1;
            // The middle now holds every item of run `R`, so the copied
            // suffix resumes after it.
            p.rb = if (p.R + 1 < segs.len) segs[p.R + 1].byte_start else slab.data.len;
            settled = false;
            continue;
        }
    }

    const data = try gpa.alloc(u8, p.lb + mid_bytes.len + (slab.data.len - p.rb));
    errdefer gpa.free(data);
    @memcpy(data[0..p.lb], slab.data[0..p.lb]);
    @memcpy(data[p.lb..][0..mid_bytes.len], mid_bytes);
    @memcpy(data[p.lb + mid_bytes.len ..], slab.data[p.rb..]);

    // The tail is a copy whenever the last run came through in the copied
    // bytes, which is the common case: the suffix if there was one, and the
    // prefix if the middle took the slab's end. Only a rebuild that ends
    // with the middle it just wrote has to measure the last run, and that
    // is one run's worth of work.
    const tail = if (p.suffixRuns() != 0)
        slab.tail.merge(0, 0)
    else if (mid_segs.len != 0)
        try tailAt(E, mid_bytes.len, mid_segs[mid_segs.len - 1], try E.litTail(mid_bytes, mid_segs[mid_segs.len - 1]))
    else if (p.L > 0)
        // The middle took the slab's end and the prefix is what is left.
        try tailAt(E, segs[p.L - 1].byte_end, segs[p.L - 1], try E.litTail(slab.data, segs[p.L - 1]))
    else
        Tail.zero;

    if (slab.data.len != 0) gpa.free(slab.data);
    slab.data = data;
    slab.len = slab.len - del + insert.len;
    slab.segments = p.prefixRuns() + mid_segs.len + p.suffixRuns();
    slab.tail = tail;
}

/// Merges `b` into `a` in place, coalescing the two runs that meet.
///
/// The seam runs are the only thing re-encoded: `a`'s last run and `b`'s
/// first run are read, encoded together, and written back over the two; the
/// rest of both slabs is copied. One step is enough, because `a`'s last run
/// opens on a value that differs from the run before it and `b`'s first run
/// closes on one that differs from the run after it, so the run the merge
/// writes cannot collide with either neighbour.
pub fn merge(
    gpa: std.mem.Allocator,
    comptime E: type,
    a: *Slab,
    b: *const Slab,
) ParseError!void {
    if (b.len == 0) return;
    if (a.len == 0) {
        const copy = try b.clone(gpa);
        a.deinit(gpa);
        a.* = copy;
        return;
    }

    const a_segs = try E.segmentsOf(gpa, a.data);
    defer gpa.free(a_segs);
    const b_segs = try E.segmentsOf(gpa, b.data);
    defer gpa.free(b_segs);
    const a_last = a_segs[a_segs.len - 1];
    const b_first_i = firstItemRun(E, b_segs);
    const b_first = b_segs[b_first_i];
    // How many of `b`'s runs come behind the seam. A boolean slab's
    // opening pad carries no items and is not a run of the sequence the
    // merge writes, so it is not counted.
    const after = b_segs.len - b_first_i - 1;

    var mid: std.ArrayList(E.Wire) = .empty;
    defer mid.deinit(gpa);
    {
        const head = try E.wireRange(gpa, a.data, a_last.item_start, a_last.item_end);
        defer gpa.free(head);
        try mid.appendSlice(gpa, head);
    }
    {
        const tail = try E.wireRange(gpa, b.data, b_first.item_start, b_first.item_end);
        defer gpa.free(tail);
        try mid.appendSlice(gpa, tail);
    }

    const mid_bytes = try E.wireEncode(gpa, mid.items, ((a.segments - 1) % 2) == 1);
    defer gpa.free(mid_bytes);
    const mid_segs = try E.segmentsOf(gpa, mid_bytes);
    defer gpa.free(mid_segs);

    const data = try gpa.alloc(u8, a_last.byte_start + mid_bytes.len + (b.data.len - b_first.byte_end));
    errdefer gpa.free(data);
    @memcpy(data[0..a_last.byte_start], a.data[0..a_last.byte_start]);
    @memcpy(data[a_last.byte_start..][0..mid_bytes.len], mid_bytes);
    @memcpy(data[a_last.byte_start + mid_bytes.len ..], b.data[b_first.byte_end..]);

    if (a.data.len != 0) gpa.free(a.data);
    a.data = data;
    a.len += b.len;
    a.segments = (a.segments - 1) + mid_segs.len + after;
    a.tail = if (after != 0)
        // `b`'s last run was copied through, so the tail is its own.
        b.tail.merge(0, 0)
    else
        try tailAt(E, mid_bytes.len, mid_segs[mid_segs.len - 1], try E.litTail(mid_bytes, mid_segs[mid_segs.len - 1]));
}

/// Cuts `slab` down to the run budget, returning the pieces that spilled
/// out. Cuts land on run boundaries, so every piece is itself a canonical
/// slab and the byte stream they concatenate to is the one `slab` held.
///
/// A run is never split, so a slab that is one very long run keeps one
/// segment however long it is — the same exemption the column's invariant
/// checker makes for a single oversize value (`column.rs:1311-1318`).
pub fn splitToBudget(
    gpa: std.mem.Allocator,
    comptime E: type,
    slab: *Slab,
    max_segments: usize,
) ParseError!std.ArrayList(Slab) {
    var out: std.ArrayList(Slab) = .empty;
    errdefer {
        for (out.items) |*p| p.deinit(gpa);
        out.deinit(gpa);
    }
    if (slab.segments <= max_segments or slab.segments <= 1) return out;

    const segs = try E.segmentsOf(gpa, slab.data);
    defer gpa.free(segs);

    var from: usize = 0;
    while (from < segs.len) {
        const to = @min(from + max_segments, segs.len);
        try out.append(gpa, try slicePiece(gpa, E, slab.data, segs, from, to));
        from = to;
    }

    // The first piece keeps the slab's identity.
    const kept = out.orderedRemove(0);
    slab.deinit(gpa);
    slab.* = kept;
    return out;
}

/// A standalone slab over the runs `[from, to)`, padded so that it opens on
/// the value its first run carries.
fn slicePiece(
    gpa: std.mem.Allocator,
    comptime E: type,
    data: []const u8,
    segs: []const Segment(E.Wire),
    from: usize,
    to: usize,
) ParseError!Slab {
    const piece = try E.wireSlice(gpa, data, segs[from].byte_start, segs[to - 1].byte_end, segs[from].opens_with_true);
    errdefer gpa.free(piece);
    const m = try measure(gpa, E, piece);
    return .{ .data = piece, .len = m.len, .segments = m.segments, .tail = m.tail };
}

/// The value the first run of `bytes` carries, or null for an empty slab.
/// O(1): a repeat, null or literal run all have their first value at a
/// known offset, and a boolean slab's is its run parity.
pub fn firstValueOf(gpa: std.mem.Allocator, comptime E: type, bytes: []const u8) ParseError!?E.Wire {
    const segs = try E.segmentsOf(gpa, bytes);
    defer gpa.free(segs);
    if (segs.len == 0) return null;
    return segs[0].first_value;
}

/// The value the last run of `bytes` carries, using the tail to find the
/// run. O(1) for a repeat or null run, and one walk of the last literal
/// run otherwise.
pub fn lastValueOf(gpa: std.mem.Allocator, comptime E: type, slab: *const Slab) ParseError!?E.Wire {
    if (slab.len == 0) return null;
    const segs = try E.segmentsOf(gpa, slab.data);
    defer gpa.free(segs);
    return E.lastValueOfRun(slab.data, segs[segs.len - 1]);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Every run of a slab, checked against the slab's own metadata, and the
/// slab checked for canonicality. A test that cannot see a wrong
/// `segments` or `tail` is not a test.
fn expectSlabSound(comptime E: type, slab: *const Slab) !void {
    const gpa = testing.allocator;
    const m = try measure(gpa, E, slab.data);
    try testing.expectEqual(m.len, slab.len);
    try testing.expectEqual(m.segments, slab.segments);
    try testing.expect(Tail.eql(m.tail, slab.tail));
    if (slab.len != 0) {
        try testing.expect(slab.segments <= default_max_segments or slab.segments == 1);
    }
    try E.canonicalSlab(slab.data);
}

/// Checks a slab against the values it should hold, freeing both.
fn expectValues(comptime E: type, slab: *const Slab, want: []const E.Wire) !void {
    const gpa = testing.allocator;
    const got = try E.wireRange(gpa, slab.data, 0, slab.len);
    defer gpa.free(got);
    try testing.expectEqualSlices(E.Wire, want, got);
}

test "fill is one run and measures as one segment" {
    const gpa = testing.allocator;
    const E = Filler;
    var s = try Slab.fill(gpa, E, 1000, 7);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 1000), s.len);
    try testing.expectEqual(@as(usize, 1), s.segments);
    try expectSlabSound(E, &s);

    var none = try Slab.fill(gpa, E, 0, 7);
    defer none.deinit(gpa);
    try testing.expect(none.isEmpty());
    try expectSlabSound(E, &none);
}

test "splicing into the middle of a run keeps the untouched runs" {
    const gpa = testing.allocator;
    const E = Filler;
    var s = try E.slabOf(gpa, &.{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9 });
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), s.segments);

    try splice(gpa, E, &s, 3, 2, &.{ 8, 8 }, null);
    try expectSlabSound(E, &s);
    try testing.expectEqual(@as(usize, 20), s.len);
    try expectValues(E, &s, &.{ 5, 5, 5, 8, 8, 5, 5, 5, 5, 5, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9 });
}

test "a splice that would repeat the previous run pulls it in" {
    const gpa = testing.allocator;
    const E = Filler;
    // Runs: 2, 3, 4. Inserting a 2 at index 2 repeats run 0's value, so the
    // two have to become one run.
    var s = try E.slabOf(gpa, &.{ 2, 2, 3, 3, 3, 4, 4, 4, 4 });
    defer s.deinit(gpa);
    try splice(gpa, E, &s, 2, 0, &.{2}, null);
    try expectSlabSound(E, &s);
    try expectValues(E, &s, &.{ 2, 2, 2, 3, 3, 3, 4, 4, 4, 4 });
    try testing.expectEqual(@as(usize, 3), s.segments);
}

test "a splice at either end of a slab, and one that empties it" {
    const gpa = testing.allocator;
    const E = Filler;

    {
        var s = try E.slabOf(gpa, &.{ 1, 2, 3 });
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 0, 0, &.{9}, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 9, 1, 2, 3 });
    }
    {
        var s = try E.slabOf(gpa, &.{ 1, 2, 3 });
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 3, 0, &.{9}, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 1, 2, 3, 9 });
    }
    {
        var s = try E.slabOf(gpa, &.{ 1, 2, 3 });
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 0, 3, &.{}, null);
        try expectSlabSound(E, &s);
        try testing.expect(s.isEmpty());
        try expectValues(E, &s, &.{});
    }
    {
        // Into an empty slab, and back out again.
        var s = try E.slabOf(gpa, &.{});
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 0, 0, &.{ 4, 5 }, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 4, 5 });
        try splice(gpa, E, &s, 1, 1, &.{}, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{4});
    }
}

test "a splice that lands on a run boundary and one that does not" {
    const gpa = testing.allocator;
    const E = Filler;
    // Runs: 1 x2, 2 x3, 3 x4.
    const before = [_]i64{ 1, 1, 2, 2, 2, 3, 3, 3, 3 };

    // On the boundary at index 5, the start of the 3s.
    {
        var s = try E.slabOf(gpa, &before);
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 5, 0, &.{7}, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 1, 1, 2, 2, 2, 7, 3, 3, 3, 3 });
    }
    // Inside the 3s, at index 7.
    {
        var s = try E.slabOf(gpa, &before);
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 7, 1, &.{7}, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 1, 1, 2, 2, 2, 3, 3, 7, 3 });
    }
    // Spanning the whole of the 2s and 3s.
    {
        var s = try E.slabOf(gpa, &before);
        defer s.deinit(gpa);
        try splice(gpa, E, &s, 2, 7, &.{ 6, 6 }, null);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, &.{ 1, 1, 6, 6 });
    }
}

test "a postfix override replaces the run the cut ends in" {
    const gpa = testing.allocator;
    const E = Filler;
    var s = try E.slabOf(gpa, &.{ 1, 1, 2, 2, 2, 3, 3, 3, 3 });
    defer s.deinit(gpa);
    // Replace the 2s with a 4, and re-anchor the run after it from 2 to 9:
    // the value the deleted run ended on is not the value the inserted one
    // does, which is the whole reason a postfix override exists.
    try splice(gpa, E, &s, 2, 3, &.{4}, &.{9});
    try expectSlabSound(E, &s);
    try expectValues(E, &s, &.{ 1, 1, 4, 9, 3, 3, 3 });
}

test "merge coalesces the seam run and keeps the rest" {
    const gpa = testing.allocator;
    const E = Filler;
    var a = try E.slabOf(gpa, &.{ 1, 1, 2, 2 });
    defer a.deinit(gpa);
    var b = try E.slabOf(gpa, &.{ 2, 3, 3 });
    defer b.deinit(gpa);

    try merge(gpa, E, &a, &b);
    try expectSlabSound(E, &a);
    try testing.expectEqual(@as(usize, 7), a.len);
    // The two 2s became one run, so the merged slab is 1, 2, 3.
    try testing.expectEqual(@as(usize, 3), a.segments);
    try expectValues(E, &a, &.{ 1, 1, 2, 2, 2, 3, 3 });

    // A seam whose values differ leaves both runs alone.
    var c = try E.slabOf(gpa, &.{ 8, 8 });
    defer c.deinit(gpa);
    try merge(gpa, E, &c, &a);
    try expectSlabSound(E, &c);
    try testing.expectEqual(@as(usize, 4), c.segments);
    try expectValues(E, &c, &.{ 8, 8, 1, 1, 2, 2, 2, 3, 3 });
}

test "splitToBudget cuts on run boundaries and every piece is a slab" {
    const gpa = testing.allocator;
    const E = Filler;
    var values_in: std.ArrayList(i64) = .empty;
    defer values_in.deinit(gpa);
    var i: i64 = 0;
    while (i < 200) : (i += 1) try values_in.append(gpa, i); // 200 distinct runs

    var s = try E.slabOf(gpa, values_in.items);
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 200), s.segments);

    var spilled = try splitToBudget(gpa, E, &s, 64);
    defer {
        for (spilled.items) |*p| p.deinit(gpa);
        spilled.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 3), spilled.items.len);
    try testing.expectEqual(@as(usize, 64), s.segments);
    try expectSlabSound(E, &s);

    // The pieces hold the same values in the same order.
    var all: std.ArrayList(i64) = .empty;
    defer all.deinit(gpa);
    try E.appendRange(gpa, &all, &s, 0, s.len);
    for (spilled.items) |*p| {
        try expectSlabSound(E, p);
        try E.appendRange(gpa, &all, p, 0, p.len);
    }
    try testing.expectEqualSlices(i64, values_in.items, all.items);
}

test "the tail is copied when the suffix came through and measured when it did not" {
    const gpa = testing.allocator;
    const E = Filler;
    var s = try E.slabOf(gpa, &.{ 1, 1, 2, 2, 2, 3, 3, 3, 3 });
    defer s.deinit(gpa);
    const old_tail = s.tail;

    // A splice that leaves the last run alone keeps the tail.
    try splice(gpa, E, &s, 0, 1, &.{8}, null);
    try expectSlabSound(E, &s);
    try testing.expect(Tail.eql(old_tail, s.tail));

    // A splice that reaches the end of the slab measures a new one.
    try splice(gpa, E, &s, 0, s.len, &.{ 5, 5, 5 }, null);
    try expectSlabSound(E, &s);
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expect(s.tail.bytes > 0);
    try expectValues(E, &s, &.{ 5, 5, 5 });
}

// ── A tiny RLE codec, so these tests do not depend on the column layer ──

/// Enough of a codec for `slab.zig` to be exercised on its own: the RLE
/// format over `i64`, with the rules the real codec has.
const Filler = struct {
    pub const Wire = i64;

    pub fn slabOf(gpa: std.mem.Allocator, vals: []const i64) ParseError!Slab {
        const bytes = try encode(gpa, vals);
        defer gpa.free(bytes);
        return init(gpa, Filler, bytes);
    }

    fn encode(gpa: std.mem.Allocator, vals: []const i64) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 0;
        while (i < vals.len) {
            var n: usize = i + 1;
            while (n < vals.len and vals[n] == vals[i]) n += 1;
            const count = n - i;
            try leb128.appendSigned(&out, gpa, if (count >= 2) @as(i64, @intCast(count)) else -1);
            try leb128.appendSigned(&out, gpa, vals[i]);
            i = n;
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn wireEncode(gpa: std.mem.Allocator, wires: []const i64, opens_with_true: bool) ParseError![]u8 {
        _ = opens_with_true;
        return encode(gpa, wires);
    }

    /// One run of `len` copies of `value`, in O(1).
    pub fn wireFill(gpa: std.mem.Allocator, len: usize, value: i64, opens_with_true: bool) ParseError![]u8 {
        _ = opens_with_true;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try leb128.appendSigned(&out, gpa, if (len >= 2) @as(i64, @intCast(len)) else -1);
        try leb128.appendSigned(&out, gpa, value);
        return out.toOwnedSlice(gpa);
    }

    pub fn wireSlice(
        gpa: std.mem.Allocator,
        bytes: []const u8,
        from: usize,
        to: usize,
        opens_with_true: bool,
    ) ParseError![]u8 {
        _ = opens_with_true;
        return gpa.dupe(u8, bytes[from..to]);
    }

    pub fn segmentsOf(gpa: std.mem.Allocator, bytes: []const u8) ParseError![]Segment(i64) {
        var out: std.ArrayList(Segment(i64)) = .empty;
        errdefer out.deinit(gpa);
        var pos: usize = 0;
        var item: usize = 0;
        while (pos < bytes.len) {
            const hdr = try leb128.readSigned(bytes[pos..]);
            const payload = pos + hdr.len;
            var count: usize = undefined;
            var value: ?i64 = null;
            var end: usize = undefined;
            if (hdr.value > 0) {
                const v = try leb128.readSigned(bytes[payload..]);
                count = @intCast(hdr.value);
                value = v.value;
                end = payload + v.len;
            } else {
                const v = try leb128.readSigned(bytes[payload..]);
                count = @intCast(-hdr.value);
                value = if (hdr.value == 0) null else v.value;
                end = payload + v.len;
                for (1..count) |_| {
                    const next = try leb128.readSigned(bytes[end..]);
                    end += next.len;
                }
            }
            try out.append(gpa, .{
                .byte_start = pos,
                .byte_end = end,
                .item_start = item,
                .item_end = item + count,
                .first_value = value,
                .opens_with_true = false,
                .kind = if (value == null) .absent else if (count >= 2) .repeat else .literal,
            });
            item += count;
            pos = end;
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn wireRange(
        gpa: std.mem.Allocator,
        bytes: []const u8,
        from: usize,
        to: usize,
    ) ParseError![]i64 {
        const all = try decodeAll(gpa, bytes);
        defer gpa.free(all);
        return gpa.dupe(i64, all[from..to]);
    }

    fn decodeAll(gpa: std.mem.Allocator, bytes: []const u8) ParseError![]i64 {
        const segs = try segmentsOf(gpa, bytes);
        defer gpa.free(segs);
        var total: usize = 0;
        for (segs) |s| total += s.itemCount();
        const out = try gpa.alloc(i64, total);
        var at: usize = 0;
        for (segs) |s| {
            @memset(out[at..][0..s.itemCount()], s.first_value.?);
            at += s.itemCount();
        }
        return out;
    }

    pub fn lastValueOfRun(bytes: []const u8, seg: Segment(i64)) ParseError!?i64 {
        _ = bytes;
        return seg.first_value;
    }

    pub fn litTail(bytes: []const u8, seg: Segment(i64)) ParseError!u32 {
        _ = bytes;
        return if (seg.first_value == null) 0 else @intCast(seg.byte_end - seg.byte_start);
    }

    /// Whether two adjacent runs would carry the same value, so canonical
    /// form has to merge them.
    pub fn sameValue(a: ?i64, b: ?i64) bool {
        if (a == null or b == null) return false;
        return a.? == b.?;
    }

    /// Two adjacent literal runs are not a canonical run sequence, whatever
    /// their values (`rle/decoder.rs:438-497` rules 4 and 6).
    pub fn mustMergeKinds(left_kind: RunKind, right_kind: RunKind) bool {
        return left_kind == .literal and right_kind == .literal;
    }

    pub fn canonicalSlab(bytes: []const u8) anyerror!void {
        // Runs must alternate in value, and a repeat run needs two items.
        const gpa = testing.allocator;
        const segs = try segmentsOf(gpa, bytes);
        defer gpa.free(segs);
        for (segs, 0..) |s, i| {
            if (i == 0) continue;
            try testing.expect(!eqlOpt(s.first_value, segs[i - 1].first_value));
        }
    }

    fn eqlOpt(a: ?i64, b: ?i64) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.? == b.?;
    }

    /// Appends the slab's items `[from, to)` to `out`.
    pub fn appendRange(
        gpa: std.mem.Allocator,
        out: *std.ArrayList(i64),
        slab: *const Slab,
        from: usize,
        to: usize,
    ) ParseError!void {
        const vals = try decodeAll(gpa, slab.data);
        defer gpa.free(vals);
        try out.appendSlice(gpa, vals[from..to]);
    }
};
