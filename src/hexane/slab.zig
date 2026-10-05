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
//!
//! `merge` is the exception. Where the two runs it meets are both literal
//! runs, it rewrites the count header of `a`'s run and copies the runs'
//! bytes, which is what `do_merge` does (`rle/splice.rs:1093-1110`) and
//! what `rewrite_lit_header` is for. Every other pair still goes through
//! the codec, because there is no header there to rewrite: a repeat run's
//! count is the run, and a pair that has to merge is a run only the codec
//! can find.
//!
//! # The unit `segments` is in
//!
//! Upstream's `Slab.segments` counts a literal run as its number of values
//! and a repeat or null run as one (`rle/load.rs:38-39`, `:43-45`,
//! `:50-52`, and the loader's own copy of the same bookkeeping at
//! `:132-153`), and its `check_invariants` asserts a slab's cached count is
//! that number (`column.rs:1316-1319`). This port counts wire runs, every
//! run one. So a slab whose every literal run holds a single value counts
//! the same on both sides and any other slab does not, and the budget
//! below is spent in runs here and in segments there.
//!
//! Nothing in the compatibility contract depends on it — a change's column
//! bytes come from a fresh encoder over the range's values
//! (`columnar/column_range/rle.rs:102-113`), never from slab bytes — and
//! no read depends on it either, which the differential gate at the foot of
//! this file checks over the whole corpus. What it does change is where a
//! load cuts and how much a slab can hold; the diff block there has the
//! citations and the numbers.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");

const rle = @import("rle.zig");
const ParseError = err.ParseError;

/// The packing a codec's wire uses, taken from the codec itself so the
/// literal-header rewrite and the two header reads beside it cannot disagree
/// with it — and LEB128 for a codec that predates the parameter and publishes
/// no `Pack`, which is what `opset/columns.zig`'s two hand-written codecs do.
/// Those are the default wire by construction, so the fallback is a fact about
/// them and not a guess.
fn packOf(comptime E: type) type {
    return if (@hasDecl(E, "Pack")) E.Pack else rle.Leb128;
}

/// [`E.wireRange`](column.zig) over a run table the caller already holds,
/// for a codec that publishes [`wireRangeFromSegs`](column.zig); and
/// `E.wireRange` itself for one that does not.
///
/// `opset/columns.zig`'s two codecs alias one of the column layer's field
/// for field rather than wrapping it, so they publish no such seam — and
/// `splice` is written over them.
///
/// **The seam the splice machinery is written against.**
/// [`Partition.rebuild`](Partition) stands on a run table it built once for
/// the whole slab and asks for the items of two of its runs; `wireRange`
/// would hand each question a fresh table of the same bytes, which is one
/// allocation and one walk of every run in front of the row for nothing.
///
/// The fallback is the same question asked the same way, so the values and
/// the refusals — and the order they come back in — are `wireRange`'s own.
fn wireRangeWithSegs(
    comptime E: type,
    gpa: std.mem.Allocator,
    bytes: []const u8,
    segs: []const Segment(E.Wire),
    from: usize,
    to: usize,
) ParseError![]E.Wire {
    if (comptime @hasDecl(E, "wireRangeFromSegs")) {
        return E.wireRangeFromSegs(gpa, bytes, segs, from, to);
    }
    return E.wireRange(gpa, bytes, from, to);
}

/// The default number of runs one slab may hold (`column.rs:21`).
///
/// A load cuts at half this, to leave room for inserts without an overflow
/// split; a splice runs to the full budget and merges the neighbours back
/// down afterwards.
///
/// **Counted in wire runs, and upstream counts segments** — see the module
/// comment below and `Slab.segments`. The two budgets are the same number
/// over different things, so they buy different sizes.
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
    ///
    /// **Wire runs, and not upstream's segments**: a literal run of `n`
    /// values is one here and `n` there (`rle/load.rs:38-39`). The module
    /// comment names what that changes; the differential gate at the foot
    /// of this file pins the number of records the two disagree about.
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
///
/// **The slab takes ownership of `data`**: the returned slab stores the
/// slice itself and its `deinit` releases those bytes, so the caller's own
/// copy is invalidated by this call and must not be freed or used
/// afterwards. There is no allocator parameter here, so `data` must come
/// from whatever allocator the slab will later be released with — the one
/// the caller's column was built with.
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
        ///
        /// **Out of `self.segs`, which the partition is already standing
        /// in.** Both ranges here are inside one run each — the tail of run
        /// `L` and the head of run `R` — and `E.wireRange` reaches them by
        /// building a fresh run table of the whole slab first, once per
        /// range per round. The seam asks the same question over the table
        /// the partition was started with.
        fn rebuild(self: *Self) ParseError!void {
            self.mid.clearRetainingCapacity();
            const pre = self.preItems();
            if (pre.to > pre.from) {
                const vals = try wireRangeWithSegs(E, self.gpa, self.data, self.segs, pre.from, pre.to);
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
                    const vals = try wireRangeWithSegs(E, self.gpa, self.data, self.segs, post.from + replaced, post.to);
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
    //
    // `mid_bytes` and `mid_segs` are the loop's only heap state and the two
    // `defer`s are their only owners, so every path out of this function
    // frees each of them exactly once. That is why a round allocates the
    // buffer that replaces one while the buffer it replaces is still owned
    // here, and releases the old one only afterwards: releasing first and
    // assigning the replacement through `try` leaves the field dangling
    // whenever the allocation fails, and the `defer` then frees it a second
    // time. Each round's two allocations are made before either old buffer
    // is let go, so a failure between them still leaves both fields live.
    var mid_bytes: []u8 = &.{};
    defer gpa.free(mid_bytes);
    var mid_segs: []Segment(E.Wire) = &.{};
    defer gpa.free(mid_segs);
    var settled = false;
    var rounds: usize = 0;
    while (!settled and rounds <= segs.len + 1) : (rounds += 1) {
        try p.rebuild();
        const next_bytes = try E.wireEncode(gpa, p.mid.items, (p.prefixRuns() % 2) == 1);
        gpa.free(mid_bytes);
        mid_bytes = next_bytes;
        const next_segs = try E.segmentsOf(gpa, mid_bytes);
        gpa.free(mid_segs);
        mid_segs = next_segs;
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

/// Rewrites the count header of the literal run at `header_pos` so that it
/// covers `total` values, and returns the change in `buf`'s length.
///
/// Upstream's `Codec::rewrite_lit_header` (`codec.rs:207-219`), under the
/// upstream name because it writes wire bytes and those are the
/// compatibility contract. Every upstream call site is a place where a
/// run's length changed while its values did not: the splice seams
/// (`rle/splice.rs:493`, `:613`, `:659`, `:969`), the merge seam (`:1106`),
/// the incremental writer (`rle/state.rs:384`, `:420`, `:610`, `:661`)
/// and the load cut (`rle/load.rs:314`).
///
/// The new header is not the width of the old one. A literal run crossing
/// the 63/64 boundary of a signed LEB128 byte is the case upstream's
/// `splice_lit_crosses_leb128_boundary` is about (`rle/tests.rs:80-83`),
/// so the count is spliced over the old header and the buffer's length
/// moves with it. A literal run's header holds the negated count
/// (`rle/decoder.rs:251-257`), which is why what is written is `-total`;
/// a `total` of zero is upstream's answer for a run with no values left,
/// and the header goes while the bytes behind it stay.
///
/// The header is written in the codec's own packing, which is what this
/// function's `P` names: upstream puts it on the `Codec` trait
/// (`codec.rs:207-219`) for exactly the reason a caller here cannot hard-code
/// it — a literal run's header is the one header whose *width* the merge seam
/// has to know in advance, and on any packing but the default the width is not
/// the one LEB128 would have chosen. Every caller inside this module has the
/// codec in hand and passes `E.Pack`; `column.zig`'s encode seam does the same.
/// The boolean codec has no literal run to call it on at all (`litRunHeaders`).
pub fn rewrite_lit_header(
    comptime P: type,
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    header_pos: usize,
    total: usize,
) ParseError!i64 {
    if (header_pos > buf.items.len) return error.InvalidValue;
    const old = try P.readSigned(buf.items[header_pos..]);
    if (old.len > buf.items.len - header_pos) return error.InvalidValue;
    if (total > std.math.maxInt(i64)) return error.TooLarge;
    const before: usize = buf.items.len;
    if (total == 0) {
        try buf.replaceRange(gpa, header_pos, old.len, &.{});
    } else {
        var hdr: [P.max_signed_size]u8 = undefined;
        const n = P.writeSigned(&hdr, -@as(i64, @intCast(total)));
        try buf.replaceRange(gpa, header_pos, old.len, hdr[0..n]);
    }
    // The two lengths differ by at most the two header widths, so the
    // difference is a small number whichever way it went.
    const grew = buf.items.len >= before;
    const delta: usize = if (grew) buf.items.len - before else before - buf.items.len;
    if (grew) return @intCast(delta);
    return -@as(i64, @intCast(delta));
}

/// Whether the codec's literal runs carry the signed count header
/// `rewrite_lit_header` writes. Every codec but the boolean one does: a
/// boolean run is a length in the byte stream and its value is the run's
/// position in the sequence, so there is no header behind it at all
/// (`bool.rs:13-25`) — not even for the one-item run the port gives the
/// literal kind (`column.zig:978`).
fn litRunHeaders(comptime E: type) bool {
    return E.Wire != bool;
}

/// The seam for two literal runs that meet, built the way `do_merge` builds
/// it (`rle/splice.rs:1093-1110`): `a`'s trailing run keeps its own bytes
/// and only its count header is rewritten, and `b`'s first run's bytes
/// follow behind it. No value is decoded and re-encoded.
///
/// Two shapes, and which one applies is decided by whether the two runs
/// agree on the value they meet on. They do not: two adjacent literal
/// runs are not a canonical run sequence (`rle/decoder.rs:444-451`), so
/// the two are one run and `a`'s header is rewritten to cover every value
/// of both. They do: the agreeing pair is a repeat run, so `a`'s run gives
/// up its last value, `b`'s run gives up its first, and the pair stands
/// between what is left of them (`rle/state.rs:376-396` truncates the run
/// it was handed, `:616-622` writes the pair).
fn litSeam(
    gpa: std.mem.Allocator,
    comptime E: type,
    out: *std.ArrayList(u8),
    a: *const Slab,
    a_last: Segment(E.Wire),
    b: *const Slab,
    b_first: Segment(E.Wire),
) ParseError!void {
    const n = a_last.itemCount();
    const m = b_first.itemCount();
    const meet = try E.lastValueOfRun(a.data, a_last);

    // **The packing, taken once.** Every header width below is this seam's
    // own `P`, so the header it measures and the header it rewrites are the
    // same width by construction rather than by two independent lookups that
    // have to agree.
    const P = packOf(E);
    if (!E.sameValue(meet, b_first.first_value)) {
        // One run: `a`'s header, then every value of both runs.
        const pos = out.items.len;
        try out.appendSlice(gpa, a.data[a_last.byte_start..a_last.byte_end]);
        const hdr = try P.readSigned(b.data[b_first.byte_start..]);
        if (hdr.len > b_first.byte_end - b_first.byte_start) return error.InvalidValue;
        try out.appendSlice(gpa, b.data[b_first.byte_start + hdr.len .. b_first.byte_end]);
        _ = try rewrite_lit_header(P, gpa, out, pos, n + m);
        return;
    }

    // The two values the runs agree on. `sameValue` is false for a null on
    // either side, so a collision means a value both runs carry.
    const shared = meet orelse return error.InvalidValue;
    if (n >= 2) {
        // `a`'s run keeps every value but the one the pair repeats. The
        // width of that value is what the tail records, which is how
        // upstream's `tail` finds it (`rle/splice.rs:1057-1062`).
        const last: usize = try E.litTail(a.data, a_last);
        if (last >= a_last.byte_end - a_last.byte_start) return error.InvalidValue;
        const pos = out.items.len;
        try out.appendSlice(gpa, a.data[a_last.byte_start .. a_last.byte_end - last]);
        _ = try rewrite_lit_header(P, gpa, out, pos, n - 1);
    }
    // The parity of the run the pair lands on. Only the boolean codec reads
    // it, and the boolean codec has no header to rewrite, so it never
    // reaches this line.
    const truncated: usize = if (n >= 2) 1 else 0;
    const parity = (a.segments - 1 + truncated) % 2 == 1;
    const pair = try E.wireFill(gpa, 2, shared, parity);
    defer gpa.free(pair);
    try out.appendSlice(gpa, pair);
    if (m >= 2) {
        // `b`'s run gives up its FIRST value — the one the pair repeats — and
        // keeps the rest, so what is left is the run's tail under a header
        // that no longer counts the value that left. Upstream's `do_merge`
        // truncates the run it was handed from the front and calls
        // `rewrite_lit_header` over what is left (`rle/splice.rs:1104-1107`);
        // the width of the value that goes is what `litHead` records, the
        // mirror of the `litTail` the `a` side reads.
        const hdr = try P.readSigned(b.data[b_first.byte_start..]);
        const head: usize = try E.litHead(b.data, b_first);
        const body = std.math.add(usize, b_first.byte_start + hdr.len, head) catch
            return error.TooLarge;
        if (body > b_first.byte_end) return error.InvalidValue;
        // The header is copied alone so `rewrite_lit_header` has one to
        // rewrite in place; the values behind it are appended after.
        const pos = out.items.len;
        try out.appendSlice(gpa, b.data[b_first.byte_start .. b_first.byte_start + hdr.len]);
        _ = try rewrite_lit_header(P, gpa, out, pos, m - 1);
        try out.appendSlice(gpa, b.data[body..b_first.byte_end]);
    }
}

/// The seam for every other pair of runs, and the deviation the module
/// comment names: the two runs' items are decoded and handed to the codec,
/// which regroups them. O(items in the two runs), where the literal path
/// above is O(bytes in them) plus the one walk it takes to read `a`'s last
/// value, which upstream reads off the tail in O(1).
fn itemSeam(
    gpa: std.mem.Allocator,
    comptime E: type,
    out: *std.ArrayList(u8),
    a: *const Slab,
    a_last: Segment(E.Wire),
    a_segs: []const Segment(E.Wire),
    b: *const Slab,
    b_first: Segment(E.Wire),
    b_segs: []const Segment(E.Wire),
    opens_with_true: bool,
) ParseError!void {
    var items: std.ArrayList(E.Wire) = .empty;
    defer items.deinit(gpa);
    // **Out of the run tables the caller built for this merge**
    // (`merge`'s `a_segs` and `b_segs`), which is what the two ranges are
    // read from; `E.wireRange` would rebuild each slab's whole table to
    // answer a range that lies inside one run of it.
    const head = try wireRangeWithSegs(E, gpa, a.data, a_segs, a_last.item_start, a_last.item_end);
    defer gpa.free(head);
    try items.appendSlice(gpa, head);
    const tail = try wireRangeWithSegs(E, gpa, b.data, b_segs, b_first.item_start, b_first.item_end);
    defer gpa.free(tail);
    try items.appendSlice(gpa, tail);
    const bytes = try E.wireEncode(gpa, items.items, opens_with_true);
    defer gpa.free(bytes);
    try out.appendSlice(gpa, bytes);
}

/// Merges `b` into `a` in place, coalescing the two runs that meet.
///
/// The seam runs are the only thing re-encoded: `a`'s last run and `b`'s
/// first run are written back as one run sequence between the two copied
/// halves, and the rest of both slabs is copied. Where both are literal
/// runs the seam is built from their bytes and a rewritten count header,
/// which is `do_merge`'s way (`rle/splice.rs:1093-1110`); for every other
/// pair the two runs' items go through the codec, which is the deviation
/// the module comment names. One step is enough, because `a`'s last run
/// opens on a value that differs from the run before it and `b`'s first run
/// closes on one that differs from the run after it, so the run the merge
/// writes cannot collide with either neighbour.
///
/// The merged slab's run count is measured from the seam, never clamped.
/// It can be one more than the two counts a caller added up: two literal
/// runs that meet on the value they share cannot be one run, so the seam
/// that replaces two runs is three. Upstream's count is additive there
/// because a literal run costs its number of values and not one
/// (`rle/load.rs:131-138`, `rle/state.rs:394-424`) while this port costs one
/// run, so `Column.tryMerge`'s pre-check (`column.zig:1898`) is a weaker
/// rule here than upstream's `sa + sb <= max_segments` is there.
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
    // Both slabs hold values, so both cut into at least one run, and the
    // seam starts on `a`'s last one. In a canonical slab every run carries
    // items — a null run of no items is not a canonical run
    // (`rle/decoder.rs:438-497` rule 2) — and the one run that carries none
    // is the boolean codec's opening pad (`bool.rs:988-1002`), which is a
    // slab's first run and never its last. Stated here because the index
    // below needs the bound: a slab whose `len` says it has values and whose
    // bytes hold no run is a caller that broke the invariant, not a shape
    // the bytes have.
    if (a_segs.len == 0) return error.InvalidValue;
    const a_last = a_segs[a_segs.len - 1];
    const b_first_i = firstItemRun(E, b_segs);
    const b_first = b_segs[b_first_i];
    // How many of `b`'s runs come behind the seam. A boolean slab's
    // opening pad carries no items and is not a run of the sequence the
    // merge writes, so it is not counted.
    const after = b_segs.len - b_first_i - 1;

    var seam: std.ArrayList(u8) = .empty;
    defer seam.deinit(gpa);
    if (litRunHeaders(E) and a_last.kind == .literal and b_first.kind == .literal) {
        try litSeam(gpa, E, &seam, a, a_last, b, b_first);
    } else {
        try itemSeam(gpa, E, &seam, a, a_last, a_segs, b, b_first, b_segs, (a.segments - 1) % 2 == 1);
    }
    const mid_bytes = try seam.toOwnedSlice(gpa);
    defer gpa.free(mid_bytes);
    const mid_segs = try E.segmentsOf(gpa, mid_bytes);
    defer gpa.free(mid_segs);
    // The seam encodes `a`'s last run followed by `b`'s first, and both
    // carry at least one item by the argument above, so the seam's bytes
    // are at least one run — the same bound the tail's index below needs.
    if (mid_segs.len == 0) return error.InvalidValue;

    // The tail is measured before `a` takes the new bytes, because a `try`
    // after `a.data = data` would run the `errdefer` below on bytes `a`
    // then owns: `a` would be left holding a freed buffer for its own
    // `deinit` to free a second time, and with a length it had already been
    // given and a tail it had not. Nothing the tail is read from is touched
    // by the copy, so measuring it here reads the same values the old order
    // read.
    const tail = if (after != 0)
        // `b`'s last run was copied through, so the tail is its own.
        b.tail.merge(0, 0)
    else
        try tailAt(E, mid_bytes.len, mid_segs[mid_segs.len - 1], try E.litTail(mid_bytes, mid_segs[mid_segs.len - 1]));

    const data = try gpa.alloc(u8, a_last.byte_start + mid_bytes.len + (b.data.len - b_first.byte_end));
    errdefer gpa.free(data);
    @memcpy(data[0..a_last.byte_start], a.data[0..a_last.byte_start]);
    @memcpy(data[a_last.byte_start..][0..mid_bytes.len], mid_bytes);
    @memcpy(data[a_last.byte_start + mid_bytes.len ..], b.data[b_first.byte_end..]);

    if (a.data.len != 0) gpa.free(a.data);
    a.data = data;
    a.len += b.len;
    a.segments = (a.segments - 1) + mid_segs.len + after;
    a.tail = tail;
}

/// Whether a piece cut out of a slab can pick up a run the slab itself did
/// not hold.
///
/// **The boolean wire, and only it.** A boolean run carries its value by its
/// position in the run sequence (`bool.rs:13-25`), so a piece that has to
/// open on a `true` run writes the zero-count `false` run in front of it
/// (`bool.rs:988-1002`, `column.zig:2691-2707`) — and `measure` counts that
/// pad as a run (`column.zig:2584`), so the pad spends budget the cut has
/// to leave for it. Upstream spends it the same way and says so: the pad it
/// writes behind a cut "counts as a segment" (`bool.rs:312-317`), the suffix
/// it would put behind the cut is measured with `suffix.padding`
/// (`bool.rs:322-326`), and the loader rounds its cut target down to even
/// precisely to leave room for one (`bool.rs:970`). Every other codec's
/// `wireSlice` copies the bytes it is handed (`column.zig:1090-1101`) and its
/// run table publishes `opens_with_true = false` for every run
/// (`column.zig:793`, `:975`), so its pieces hold exactly the runs they were
/// cut at.
fn piecePadsRuns(comptime E: type) bool {
    return E.Wire == bool;
}

/// The runs a piece cut at `from` out of `segs` may hold and still fit the
/// budget: the budget less the pad the piece has to write in front of it.
///
/// **`from == 0` pays nothing.** The first piece carries the slab's own pad
/// inside `[0, to)` when the slab had one (`splitToBudget` below), so there
/// is nothing to add; every piece behind it is a standalone slab and needs
/// the pad the parity asks for.
///
/// `from` is a `from < segs.len` loop cursor, so `segs[from]` is a run. The
/// budget is at least two — `Column.initWithBudget` and `Column.loadIter`
/// both refuse one below it (`column.zig:3151`, `:5274`) — so the pad can
/// never spend the whole cut and the cursor always advances.
pub fn pieceRuns(
    comptime E: type,
    segs: []const Segment(E.Wire),
    from: usize,
    max_segments: usize,
) usize {
    const pad: usize = if (piecePadsRuns(E) and from != 0 and segs[from].opens_with_true) 1 else 0;
    return max_segments - pad;
}

/// How many slabs a slab of `segments` runs leaves behind when it is cut at
/// the budget: the room a caller has to have in its list before the cut puts
/// them there (`Column.settle`, `Column.spliceOneSlab`,
/// `Column.spliceAcrossSlabs`, `Column.tryMerge`).
///
/// The first piece keeps the slab's own identity (`splitToBudget` below), so
/// this counts the pieces that spill and not the pieces the cut makes.
///
/// **A codec whose pieces cannot gain a pad is bound by the budget alone**,
/// and `segments / max_segments` is the bound this file already reserved
/// with — a conservative one, since the cut makes `ceil` pieces. One whose
/// pieces can has every piece behind the first hold `max_segments - 1`
/// runs, which is the bound here and the whole difference between the two.
pub fn splitSpillCount(comptime E: type, segments: usize, max_segments: usize) usize {
    if (!piecePadsRuns(E)) return segments / max_segments;
    if (segments <= max_segments) return 0;
    const behind: usize = max_segments - 1;
    return (segments - max_segments + behind - 1) / behind;
}

/// Cuts `slab` down to the run budget, returning the pieces that spilled
/// out. Cuts land on run boundaries, so every piece is itself a canonical
/// slab and the byte stream they concatenate to is the one `slab` held.
///
/// A run is never split, so a slab that is one very long run keeps one
/// segment however long it is — the same exemption the column's invariant
/// checker makes for a single oversize value (`column.rs:1311-1318`).
///
/// **A piece is cut one run short when it has to open on a `true` run**, and
/// that is the whole difference between a boolean column and the rest
/// ([`pieceRuns`](pieceRuns) above). The pad the piece writes is a run the
/// wire spends and `measure` counts, so a piece cut at the full budget behind
/// a `true` run lands one run over it — which is the arm the column's
/// invariant checker refuses (`column.zig:6881-6882`), stated upstream at the
/// same bound (`column.rs:1310-1315`). Upstream never has to make the
/// correction because it cuts the run out of the rebuild rather than out of
/// a finished slab, and the cut it makes is already against the pad
/// (`bool.rs:312-317`, `:322-326`).
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
        const to = @min(from + pieceRuns(E, segs, from, max_segments), segs.len);
        // Reserve before the new piece owns bytes. A refused append must not
        // abandon a finished slab outside `out`'s cleanup guard.
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try slicePiece(gpa, E, slab.data, segs, from, to));
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
    // The range is a run range, `from < to <= segs.len`, which is what
    // `splitToBudget`'s loop hands over and what puts the last run of the
    // piece at `to - 1`. Stated here so the subtraction below has a bound
    // the reader and the analyser can both see. A caller that passed
    // anything else has a bug of its own: `from < segs.len` is the loop's
    // condition and `to` is `min(from + max_segments, segs.len)`.
    if (to == 0 or from >= to or to > segs.len) return error.InvalidValue;
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
    // The slab holds values — the branch above returned for an empty one —
    // so its bytes cut into at least one run, and the last of them is the
    // one the tail describes. In a canonical slab every run carries items
    // (`rle/decoder.rs:438-497` rule 2) and the one that carries none is
    // the boolean codec's opening pad (`bool.rs:988-1002`), which is the
    // slab's first run, so a slab with values in it cannot be left holding
    // nothing but the pad.
    if (segs.len == 0) return error.InvalidValue;
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

/// A splice whose seam widens once, so the middle is encoded more than
/// once: the second round is where the loop replaces the buffers the first
/// round allocated. That is the path the allocation-failure test below
/// exercises.
fn splicePullsRunIn(gpa: std.mem.Allocator) !void {
    const E = Filler;
    var s = try E.slabOf(gpa, &.{ 2, 2, 3, 3, 3, 4, 4, 4, 4 });
    defer s.deinit(gpa);
    try splice(gpa, E, &s, 2, 0, &.{2}, null);
    const got = try E.wireRange(gpa, s.data, 0, s.len);
    defer gpa.free(got);
    try testing.expectEqualSlices(i64, &.{ 2, 2, 2, 3, 3, 3, 4, 4, 4, 4 }, got);
}

test "a splice that widens its middle survives every allocation failure" {
    // The loop encodes the middle once per round, so a splice that pulls a
    // run in allocates the middle's bytes and runs twice. Failing the
    // allocation that replaces them must leave the slab whole and every
    // buffer freed once: releasing the old buffer before the replacement
    // arrives left the field dangling, and the `defer` freed it again.
    try testing.checkAllAllocationFailures(testing.allocator, splicePullsRunIn, .{});
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

test "a merge at the segment budget stays inside it" {
    const gpa = testing.allocator;
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u32);

    var a_vals: std.ArrayList(?u32) = .empty;
    defer a_vals.deinit(gpa);
    // 11 runs, the last of them the literal run [11, 12].
    for ([_][2]u32{ .{ 1, 3 }, .{ 2, 1 }, .{ 3, 2 }, .{ 4, 1 }, .{ 5, 2 }, .{ 6, 1 }, .{ 7, 2 }, .{ 8, 1 }, .{ 9, 2 }, .{ 10, 2 }, .{ 11, 1 } }) |r| {
        var k: u32 = 0;
        while (k < r[1]) : (k += 1) try a_vals.append(gpa, r[0]);
    }
    try a_vals.append(gpa, 12);

    var b_vals: std.ArrayList(?u32) = .empty;
    defer b_vals.deinit(gpa);
    // 52 runs, the first of them the literal run [12, 13]. The seam is a's
    // last run followed by b's first, and the two meet on 12, so the seam is
    // three runs where the caller counted two: [11], the pair 12, 12 and
    // [13]. Upstream writes those same three runs — `do_merge` truncates a's
    // run to the values the pair does not repeat and rewrites the header,
    // writes the pair, and truncates b's run the same way
    // (`rle/splice.rs:1093-1110`).
    try b_vals.appendSlice(gpa, &.{ 12, 13 });
    var j: usize = 0;
    while (j < 25) : (j += 1) {
        const v: u32 = 30 + 2 * @as(u32, @intCast(j));
        try b_vals.appendSlice(gpa, &.{ v, v, v + 1 });
    }
    try b_vals.appendSlice(gpa, &.{ 99, 99 });

    const a_bytes = try E.wireEncode(gpa, a_vals.items, false);
    defer gpa.free(a_bytes);
    var a = try init(gpa, E, a_bytes);
    defer a.deinit(gpa);
    const b_bytes = try E.wireEncode(gpa, b_vals.items, false);
    defer gpa.free(b_bytes);
    var b = try init(gpa, E, b_bytes);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 11), a.segments);
    try testing.expectEqual(@as(usize, 52), b.segments);

    // The caller's pre-check (`column.zig:1898`, upstream `column.rs:1789`):
    // the two counts add up inside the budget, so the merge is the only
    // thing left that can hold the line.
    try testing.expect(a.segments + b.segments <= default_max_segments);

    try merge(gpa, E, &a, &b);
    // The count, the tail and the values all come out of the bytes, and the
    // budget holds: the 10 runs before the seam, the 3 in it and b's other
    // 51.
    try expectSlabSound(E, &a);
    try testing.expectEqual(@as(usize, 64), a.segments);
    try testing.expect(a.segments <= default_max_segments);

    var want: std.ArrayList(?u32) = .empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, a_vals.items);
    try want.appendSlice(gpa, b_vals.items);
    try expectValues(E, &a, want.items);

    // The same values through a column, built and then edited, must leave
    // the column inside its own budget at every step.
    var col = try colmod.Column(?u32, E).init(gpa);
    defer col.deinit();
    try col.extend(gpa, a_vals.items);
    try col.extend(gpa, b_vals.items);
    try testing.expect((try col.checkInvariants()) == null);
    const segs = try col.slabSegments(gpa);
    defer gpa.free(segs);
    for (segs) |n| try testing.expect(n <= default_max_segments);

    // Deleting the head of the first slab is what exposed the range bug in
    // the merge policy: the pair left behind is not the pair the splice
    // touched.
    try col.splice(gpa, 0, 3, &.{});
    try testing.expect((try col.checkInvariants()) == null);
    const segs3 = try col.slabSegments(gpa);
    defer gpa.free(segs3);
    for (segs3) |n| try testing.expect(n <= default_max_segments);
}

test "a merge whose seam values meet costs one run more than the two it replaces" {
    const gpa = testing.allocator;
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u32);

    // The shapes of the test above with one more run behind b's first, so
    // the two segment counts add up to exactly the budget and the caller
    // still merges. The seam collision is the one thing that pre-check
    // cannot see: two literal runs that meet on the value they share cannot
    // be one run, so the seam is three runs where the caller counted two and
    // the merged slab holds 65.
    //
    // 65 is what the bytes hold, which is what `Slab.segments` is in this
    // port and what the column's invariant checker compares it against
    // (`column.zig:2032-2035`); clamping it to 64 here would be a lie the
    // next walk of the bytes undoes. Upstream's own count is additive across
    // the seam, and so never needs the clamp, because a literal run costs its
    // number of values there and not one (`rle/load.rs:131-138`,
    // `rle/state.rs:394-424`).
    var a_vals: std.ArrayList(?u32) = .empty;
    defer a_vals.deinit(gpa);
    for ([_][2]u32{ .{ 1, 3 }, .{ 2, 1 }, .{ 3, 2 }, .{ 4, 1 }, .{ 5, 2 }, .{ 6, 1 }, .{ 7, 2 }, .{ 8, 1 }, .{ 9, 2 }, .{ 10, 2 }, .{ 11, 1 } }) |r| {
        var k: u32 = 0;
        while (k < r[1]) : (k += 1) try a_vals.append(gpa, r[0]);
    }
    try a_vals.append(gpa, 12);

    var b_vals: std.ArrayList(?u32) = .empty;
    defer b_vals.deinit(gpa);
    try b_vals.appendSlice(gpa, &.{ 12, 13 });
    var j: usize = 0;
    while (j < 26) : (j += 1) {
        const v: u32 = 30 + 2 * @as(u32, @intCast(j));
        try b_vals.appendSlice(gpa, &.{ v, v, v + 1 });
    }

    const a_bytes = try E.wireEncode(gpa, a_vals.items, false);
    defer gpa.free(a_bytes);
    var a = try init(gpa, E, a_bytes);
    defer a.deinit(gpa);
    const b_bytes = try E.wireEncode(gpa, b_vals.items, false);
    defer gpa.free(b_bytes);
    var b = try init(gpa, E, b_bytes);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 11), a.segments);
    try testing.expectEqual(@as(usize, 53), b.segments);
    try testing.expectEqual(@as(usize, 64), a.segments + b.segments);

    try merge(gpa, E, &a, &b);
    try testing.expectEqual(@as(usize, 65), a.segments);

    // Everything else about the slab is what the bytes say, which is the
    // only account of the count there is.
    const m = try measure(gpa, E, a.data);
    try testing.expectEqual(m.len, a.len);
    try testing.expectEqual(m.segments, a.segments);
    try testing.expect(Tail.eql(m.tail, a.tail));
    try E.canonicalSlab(a.data);
    try testing.expectEqual(a_vals.items.len + b_vals.items.len, m.len);

    var want: std.ArrayList(?u32) = .empty;
    defer want.deinit(gpa);
    try want.appendSlice(gpa, a_vals.items);
    try want.appendSlice(gpa, b_vals.items);
    try expectValues(E, &a, want.items);
}

test "rewrite_lit_header rewrites a count header in place" {
    const gpa = testing.allocator;
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u32);

    // 65 distinct values: one literal run whose count header needs two
    // bytes, because 65 does not fit in the seven bits a signed LEB128 byte
    // carries beside its sign. This is the boundary upstream's
    // `splice_lit_crosses_leb128_boundary` is about (`rle/tests.rs:80-83`).
    var values: [65]?u32 = undefined;
    for (&values, 0..) |*v, i| {
        const n: u32 = @intCast(i + 1);
        v.* = n;
    }
    const bytes = try E.wireEncode(gpa, &values, false);
    defer gpa.free(bytes);
    const wide = (try leb128.readSigned(bytes)).len;
    try testing.expectEqual(@as(usize, 2), wide);
    const payload = bytes[wide..];
    try testing.expectEqual(@as(usize, 65), payload.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, bytes);

    // One value fewer is a narrower header. The rewrite is the header's
    // alone: the values behind it are the caller's to add or remove, which is
    // why every upstream call site pairs it with a splice
    // (`rle/splice.rs:1104-1107`). So the payload comes back whole and only
    // the header shrank.
    try testing.expectEqual(@as(i64, -1), try rewrite_lit_header(rle.Leb128, gpa, &buf, 0, 64));
    const narrow = try leb128.readSigned(buf.items);
    try testing.expectEqual(@as(i64, -64), narrow.value);
    try testing.expectEqual(@as(usize, 1), narrow.len);
    try testing.expectEqualSlices(u8, payload, buf.items[1..]);

    // One value more is a wider header, the other way round, and the same
    // bytes come back.
    try testing.expectEqual(@as(i64, 1), try rewrite_lit_header(rle.Leb128, gpa, &buf, 0, 65));
    try testing.expectEqualSlices(u8, bytes, buf.items);

    // A run with no values left loses its header and keeps its bytes.
    try testing.expectEqual(@as(i64, -2), try rewrite_lit_header(rle.Leb128, gpa, &buf, 0, 0));
    try testing.expectEqualSlices(u8, payload, buf.items);
}

test "two literal runs meeting at a merge seam" {
    const gpa = testing.allocator;
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u32);

    // Every shape the seam can take with both runs literal, and the two it
    // takes with only one of them: the runs meet on a value or they do not,
    // either of them can be a run of one value, and `b`'s first run can be a
    // repeat run or an absent one, which is the item path.
    const cases = .{
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{ 4, 5 }, .want = [_]?u32{ 1, 1, 2, 3, 4, 5 }, .segments = 2 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{4}, .want = [_]?u32{ 1, 1, 2, 3, 4 }, .segments = 2 },
        .{ .a = [_]?u32{ 1, 1, 2 }, .b = [_]?u32{ 3, 4 }, .want = [_]?u32{ 1, 1, 2, 3, 4 }, .segments = 2 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{ 3, 4 }, .want = [_]?u32{ 1, 1, 2, 3, 3, 4 }, .segments = 4 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{3}, .want = [_]?u32{ 1, 1, 2, 3, 3 }, .segments = 3 },
        .{ .a = [_]?u32{ 1, 1, 2 }, .b = [_]?u32{ 2, 3 }, .want = [_]?u32{ 1, 1, 2, 2, 3 }, .segments = 3 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{ 3, 4, 5, 5 }, .want = [_]?u32{ 1, 1, 2, 3, 3, 4, 5, 5 }, .segments = 5 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{ 4, 4, 5, 5 }, .want = [_]?u32{ 1, 1, 2, 3, 4, 4, 5, 5 }, .segments = 4 },
        .{ .a = [_]?u32{ 1, 1, 2, 3 }, .b = [_]?u32{ null, 4 }, .want = [_]?u32{ 1, 1, 2, 3, null, 4 }, .segments = 4 },
    };
    // `inline for`, because the cases are a tuple of distinct types — each
    // carries arrays of a different length — so a runtime loop cannot resolve
    // a field of one. Copying each case into `var` locals gives the body
    // runtime addresses to hand to the encoder; the address of a comptime
    // field would be a pointer into the comptime value, which the encoder
    // cannot read from at runtime.
    inline for (cases) |c| {
        var a_vals = c.a;
        var b_vals = c.b;
        var want = c.want;
        const a_bytes = try E.wireEncode(gpa, &a_vals, false);
        defer gpa.free(a_bytes);
        var a = try init(gpa, E, a_bytes);
        defer a.deinit(gpa);
        const b_bytes = try E.wireEncode(gpa, &b_vals, false);
        defer gpa.free(b_bytes);
        var b = try init(gpa, E, b_bytes);
        defer b.deinit(gpa);

        try merge(gpa, E, &a, &b);
        try expectSlabSound(E, &a);
        try testing.expectEqual(c.segments, a.segments);
        try expectValues(E, &a, &want);
    }
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

test "a boolean piece cut behind a true run is cut one run short, so every piece is inside the budget" {
    const colmod = @import("column.zig");
    const E = colmod.Bool;
    const gpa = testing.allocator;

    // **The shape the column's invariant checker refused**: a boolean prefix
    // column built from sixteen alternating values and a budget of three or
    // four. Eleven runs carry the values and the pad a slab opening on `true`
    // writes in front of them (`bool.rs:988-1002`) is a twelfth, so every
    // other piece of a cut has to open on a `true` run.
    const opens_true = [_]bool{ true, false, true, true, false, true, false, true, true, true, false, false, true, false, true, true };
    // **And the same values opening on `false`** (`bool.rs:988-1002`: a slab
    // opens on a `false` run, so a leading `false` needs no pad), where no
    // piece pays one and the cut is the budget itself.
    const opens_false = [_]bool{ false, true, false, false, true, false, true, false, false, false, true, true, false, true, false, false };

    for ([_]struct { budget: usize, values: []const bool, segments: usize }{
        .{ .budget = 3, .values = &opens_true, .segments = 12 },
        .{ .budget = 4, .values = &opens_true, .segments = 12 },
        .{ .budget = 3, .values = &opens_false, .segments = 11 },
        .{ .budget = 4, .values = &opens_false, .segments = 11 },
    }) |c| {
        const bytes = try E.wireEncode(gpa, c.values, false);
        defer gpa.free(bytes);
        var s = try init(gpa, E, bytes);
        defer s.deinit(gpa);
        try testing.expectEqual(c.segments, s.segments);
        // The budget is crossed, which is the whole reason the cut runs.
        try testing.expect(s.segments > c.budget);

        var spilled = try splitToBudget(gpa, E, &s, c.budget);
        defer {
            for (spilled.items) |*p| p.deinit(gpa);
            spilled.deinit(gpa);
        }

        // **Every piece is inside the budget, and the first one kept the
        // slab's own identity** — so what spilled is what `splitSpillCount`
        // bounds, which is the room a column reserves before it cuts
        // (`column.zig:6291`, `:6387`, `:6541`, `:6608`). The arm that used to
        // stand one run over is `column.zig:6881-6882`, upstream's is
        // `column.rs:1310-1315`.
        try testing.expect(spilled.items.len <= splitSpillCount(E, c.segments, c.budget));
        try expectSlabSound(E, &s);
        try testing.expect(s.segments <= c.budget);

        // **The pieces hold the same values in the same order**, which is what
        // says the shorter cut lost nothing: every piece is the run range it
        // was cut at, and those ranges still tile the slab.
        var all: std.ArrayList(bool) = .empty;
        defer all.deinit(gpa);
        const head = try E.wireRange(gpa, s.data, 0, s.len);
        defer gpa.free(head);
        try all.appendSlice(gpa, head);
        for (spilled.items) |*p| {
            try expectSlabSound(E, p);
            try testing.expect(p.segments <= c.budget);
            const piece = try E.wireRange(gpa, p.data, 0, p.len);
            defer gpa.free(piece);
            try all.appendSlice(gpa, piece);
        }
        try testing.expectEqualSlices(bool, c.values, all.items);
    }
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
///
/// `encode` writes a run per maximal group of equal values, so it never
/// writes a literal run of two or more values the way the real codec does.
/// The read side still has to cope with one, because the merge seam builds
/// a literal run out of two runs' values where the real codec is exercised
/// with `RleOption`.
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
                // A literal or absent run's header holds the negated count
                // (`rle/decoder.rs:251-257`), so the count is the magnitude
                // of the header, and the branch above has already proved
                // `hdr.value` is not positive. The magnitude is taken with
                // `@abs` rather than by negating, because `readSigned` can
                // decode `minInt(i64)` — the tenth byte's all-ones payload
                // sets bit 63 (`src/leb128.zig:119-126`) — and negating
                // that overflows where its magnitude does not. What the
                // conversion cannot hold is then refused: `usize` is the
                // count's own width on every target this port builds for,
                // and the check is what keeps a count that does not fit
                // from being one a narrower target would truncate.
                const magnitude: u64 = @abs(hdr.value);
                if (magnitude > std.math.maxInt(usize)) return error.InvalidValue;
                count = @intCast(magnitude);
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
            switch (s.kind) {
                // A repeat or absent run's items are all one value.
                .repeat, .absent => @memset(out[at..][0..s.itemCount()], s.first_value.?),
                // A literal run's items are one value each and they are only
                // in the bytes.
                .literal => {
                    const hdr = try leb128.readSigned(bytes[s.byte_start..]);
                    var pos = s.byte_start + hdr.len;
                    for (0..s.itemCount()) |i| {
                        const v = try leb128.readSigned(bytes[pos..]);
                        out[at + i] = v.value;
                        pos += v.len;
                    }
                },
                .pad => return error.InvalidValue,
            }
            at += s.itemCount();
        }
        return out;
    }

    pub fn lastValueOfRun(bytes: []const u8, seg: Segment(i64)) ParseError!?i64 {
        _ = bytes;
        return seg.first_value;
    }

    /// The byte width of the last value of the run, and zero for a repeat or
    /// absent run — the contract every caller reads this under, and the one
    /// `Tail.lit_tail` is built to serve.
    pub fn litTail(bytes: []const u8, seg: Segment(i64)) ParseError!u32 {
        const hdr = try leb128.readSigned(bytes[seg.byte_start..]);
        if (hdr.value >= 0) return 0;
        const width = (seg.byte_end - seg.byte_start) - hdr.len;
        if (width > std.math.maxInt(u32)) return error.TooLarge;
        return @intCast(width);
    }

    /// The byte width of the first value of the run, under the same contract
    /// as `litTail`. `Filler.encode` writes one run per maximal group of
    /// equal values, so a literal run holds exactly one value and the head
    /// and the tail are the same width.
    pub fn litHead(bytes: []const u8, seg: Segment(i64)) ParseError!u32 {
        return litTail(bytes, seg);
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

// ── Upstream `hexane/src/tests.rs` ────────────────────────────────────────────
//
// **Why a `Column`-typed case is transcribed here against a slab.** Upstream's
// column is one or more slabs, and at these sizes it is **one** slab: the
// biggest input below is twenty-six values and the run budget is
// `default_max_segments = 64` (`slab.zig:114`). So a column built and edited
// as upstream builds and edits one *is* a slab, and every operation it
// performs is this file's `splice` or `merge` — the column machinery on both
// sides of the port calls down to them. The port drives those directly.
//
// **What is therefore not covered here, stated plainly.** A `Column<u64>` cut
// across *several* slabs is `column.zig`'s, and its transcription is there.
// These cases are evidence about `slab.zig`'s own operations. The codec
// descriptor `colmod.Rle` / `colmod.RleOption` / `colmod.Bool` is **named** as
// a type parameter — no `Column` is constructed and nothing in `column.zig`
// is touched, exactly as this file's corpus checks already do.

/// A slab holding `values`, measured by the validating walk.
fn slabOf(comptime E: type, gpa: std.mem.Allocator, values: []const E.Wire) !Slab {
    const bytes = try E.wireEncode(gpa, values, false);
    defer gpa.free(bytes);
    return try init(gpa, E, bytes);
}

/// One upstream merge case: two encoded slabs merged, the result held to
/// every postcondition this file has, and its values compared one by one.
fn expectMerged(
    comptime E: type,
    gpa: std.mem.Allocator,
    a_vals: []const E.Wire,
    b_vals: []const E.Wire,
    want: []const E.Wire,
) !void {
    var a = try slabOf(E, gpa, a_vals);
    defer a.deinit(gpa);
    var b = try slabOf(E, gpa, b_vals);
    defer b.deinit(gpa);

    try merge(gpa, E, &a, &b);
    try expectSlabSound(E, &a);
    try expectValues(E, &a, want);
}

test "merge_slab_literal_to_literal_same_value" {
    // **`tests.rs:3389-3402`.** `[1,2,5]` meets `[5,3,4]` on the shared `5`.
    //
    // **The seam is literal against literal**, so the encoder has to emit one
    // literal run carrying both 5s rather than two runs that canonical form
    // forbids sitting next to each other. The expected values hold both, and
    // that is the only place the join shows.
    const colmod = @import("column.zig");
    try expectMerged(
        colmod.Rle(u64),
        testing.allocator,
        &.{ 1, 2, 5 },
        &.{ 5, 3, 4 },
        &.{ 1, 2, 5, 5, 3, 4 },
    );
}

test "merge_slab_literal_to_same_value_start" {
    // **`tests.rs:3355-3371`.** `[1,2,3,4,5]` meets `[5,5,5,6,7]`.
    //
    // **Both inputs are validated first**, as upstream does here and not in
    // its two sibling cases: the case is about the seam, and a broken input
    // would make a green merge meaningless. The seam is a literal run meeting
    // a repeat run on the shared `5`, which is the branch that drops one
    // value and rewrites the count header instead of re-encoding
    // (`slab.zig:765-777`, `rewrite_lit_header` at `:692`).
    const colmod = @import("column.zig");
    try expectMerged(
        colmod.Rle(u64),
        testing.allocator,
        &.{ 1, 2, 3, 4, 5 },
        &.{ 5, 5, 5, 6, 7 },
        &.{ 1, 2, 3, 4, 5, 5, 5, 5, 6, 7 },
    );
}

test "merge_slab_repeat_to_literal_same_value" {
    // **`tests.rs:3373-3387`.** `[1,2,3,3,3]` meets `[3,4,5]`: a repeat run
    // against a literal one, which takes the other seam branch
    // (`slab.zig:812-855`).
    const colmod = @import("column.zig");
    try expectMerged(
        colmod.Rle(u64),
        testing.allocator,
        &.{ 1, 2, 3, 3, 3 },
        &.{ 3, 4, 5 },
        &.{ 1, 2, 3, 3, 3, 3, 4, 5 },
    );
}

test "lit1_before_repeat_same_value" {
    // **`tests.rs:1578-1597`.** Nine inserts and removes at fixed positions,
    // against a `Vec` mirror.
    //
    // **Compared after every step, not only at the end.** A slab that came
    // out right after a hundred wrong intermediate states is the shape of bug
    // this op list was written for: a one-element literal ending up in front
    // of a repeat run carrying the same value is a canonical-form violation,
    // and it is only visible while the history is being replayed.
    const Ops = struct { ins: bool, v: ?u64, at: usize };
    const ops = [_]Ops{
        .{ .ins = true, .v = 1, .at = 0 },
        .{ .ins = true, .v = 1, .at = 1 },
        .{ .ins = true, .v = null, .at = 0 },
        .{ .ins = true, .v = 3, .at = 2 },
        .{ .ins = true, .v = 1, .at = 2 },
        .{ .ins = true, .v = 2, .at = 4 },
        .{ .ins = false, .v = null, .at = 4 },
        .{ .ins = true, .v = 1, .at = 0 },
        .{ .ins = false, .v = null, .at = 1 },
    };

    const colmod = @import("column.zig");
    const E = colmod.RleOption(u64);
    const gpa = testing.allocator;
    var s: Slab = .empty;
    defer s.deinit(gpa);
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);

    for (ops, 0..) |op, step| {
        if (op.ins) {
            const one = [_]?u64{op.v};
            try splice(gpa, E, &s, op.at, 0, &one, null);
            try mirror.insert(gpa, op.at, op.v);
        } else {
            try splice(gpa, E, &s, op.at, 1, &.{}, null);
            _ = mirror.orderedRemove(op.at);
        }
        try expectSlabSound(E, &s);
        if (s.len != mirror.items.len) {
            std.debug.print("step {d}: the slab holds {d} value(s), the mirror {d}\n", .{
                step,
                s.len,
                mirror.items.len,
            });
            return error.TestExpectedEqual;
        }
        try expectValues(E, &s, mirror.items);
    }
}

test "split_repeat2_adjacent_literal_regression" {
    // **`tests.rs:1607-1655`.** Twenty-six values inserted one at a time at
    // the tail, then thirteen removed one at a time from the front.
    //
    // **The name is the point**: a two-item repeat run sitting next to a
    // literal run of the same values is where a splitter loses an item. Both
    // `min` guards upstream writes are kept, because they are what makes
    // `start_pos` and `del_pos` safe to move if the op list changes.
    const values = [_]?u64{
        null, null, 2,    null, 2, null, 2, 1, 1, 1,
        1,    3,    2,    2,    1, 2,    3, 2, 2, 2,
        2,    1,    null, null, 3, null,
    };
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u64);
    const gpa = testing.allocator;
    var s: Slab = .empty;
    defer s.deinit(gpa);
    var mirror: std.ArrayList(?u64) = .empty;
    defer mirror.deinit(gpa);

    for (values, 0..) |v, i| {
        const idx = @min(i, mirror.items.len);
        const one = [_]?u64{v};
        try splice(gpa, E, &s, idx, 0, &one, null);
        try mirror.insert(gpa, idx, v);
    }
    try expectSlabSound(E, &s);
    try expectValues(E, &s, mirror.items);

    const del_pos = @min(@as(usize, 0), mirror.items.len -| 1);
    const del_count = @min(values.len / 2, mirror.items.len - del_pos);
    for (0..del_count) |_| {
        if (mirror.items.len == 0) break;
        const idx = @min(del_pos, mirror.items.len - 1);
        try splice(gpa, E, &s, idx, 1, &.{}, null);
        _ = mirror.orderedRemove(idx);
        try expectSlabSound(E, &s);
        try expectValues(E, &s, mirror.items);
    }
}

test "splice_runs_matches_per_item_splice" {
    // **`tests.rs:1159-1181`.** For four `(at, del)` pairs, splicing a window
    // in one call holds the same values as splicing them one at a time.
    //
    // **The assertion is bulk against incremental, and it stays that
    // assertion in the port.** Upstream contrasts `splice_runs` (runs in one
    // call) with `splice` (values one at a time); the port has one splice, so
    // what is contrasted here is *one call carrying five values* against
    // *five calls carrying one each*. **What that cannot catch is a bug in a
    // run-pair deserialiser the port does not have** — upstream's, which
    // `column.rs:1563` folds into the same `splice_inner` this port's `splice`
    // implements.
    const colmod = @import("column.zig");
    const E = colmod.RleOption(u64);
    const window = [_]?u64{ null, 5, 5, 5, null };
    const base = [_]?u64{ 1, 2, 3, 4 };
    const combos = [_][2]usize{ .{ 0, 0 }, .{ 2, 1 }, .{ 1, 3 }, .{ 4, 0 } };
    const gpa = testing.allocator;

    for (combos) |combo| {
        const at = combo[0];
        const del = combo[1];

        var bulk = try slabOf(E, gpa, &base);
        defer bulk.deinit(gpa);
        try splice(gpa, E, &bulk, at, del, &window, null);

        var one_at_a_time = try slabOf(E, gpa, &base);
        defer one_at_a_time.deinit(gpa);
        for (window, 0..) |v, i| {
            // **The first item carries the whole delete and the rest carry
            // none.** Deleting one item per step is what would run off the
            // end at `(at, del) = (4, 0)`, where there is nothing to delete:
            // the window is a replacement of `del` items by five, and
            // decomposing that into five calls means exactly one call
            // removes something.
            const single = [_]?u64{v};
            try splice(gpa, E, &one_at_a_time, at + i, if (i == 0) del else 0, &single, null);
        }

        try expectSlabSound(E, &bulk);
        const incremental = try E.wireRange(gpa, one_at_a_time.data, 0, one_at_a_time.len);
        defer gpa.free(incremental);
        try expectValues(E, &bulk, incremental);
    }
}

test "bool_into_slab_tail_multibyte_leb" {
    // **`tests.rs:4671-4681`.** Two hundred false then two hundred true: the
    // last run's count is 200, which needs a two-byte LEB128, and the tail a
    // writer records has to equal the tail a validating walk derives.
    //
    // **Two derivations, and that is the whole case.** Upstream contrasts
    // `Encoder::encode_slab`'s tail with `BoolEncoding::validate_encoding`'s.
    // The port's equivalents are the two paths this file already has: a
    // rebuild derives its tail from the run it just wrote (`tailAt`,
    // `slab.zig:643-657`) and `init` derives one by walking the bytes
    // (`measure`, `slab.zig:317`). Tails that disagreed would make every
    // later splice cut in the wrong place.
    const colmod = @import("column.zig");
    const E = colmod.Bool;
    const gpa = testing.allocator;

    var falses: [200]bool = undefined;
    @memset(&falses, false);
    var trues: [200]bool = undefined;
    @memset(&trues, true);

    var s: Slab = .empty;
    defer s.deinit(gpa);
    try splice(gpa, E, &s, 0, 0, &falses, null);
    try splice(gpa, E, &s, 200, 0, &trues, null);

    // The last run really is one whose count does not fit in a byte, so the
    // case is testing what it says it is.
    try testing.expectEqual(@as(u32, 2), s.tail.bytes);

    var walked = try init(gpa, E, s.data);
    defer walked.deinit(gpa);
    try testing.expect(Tail.eql(s.tail, walked.tail));
    try testing.expectEqual(s.len, walked.len);
    try testing.expectEqual(@as(usize, 400), s.len);

    const back = try E.wireRange(gpa, s.data, 0, s.len);
    defer gpa.free(back);
    try testing.expectEqualSlices(bool, (&falses ++ &trues), back);
}

// ── The differential corpus ──────────────────────────────────────────────────

const corpus = @import("codec_golden.zig");
const column = @import("column.zig");

/// The column types a slab can hold, and the corpus names they answer for.
///
/// **A slab is an encoding, not a format of its own**: its `data` is an RLE
/// or a boolean slab, so the same records the RLE and boolean families use
/// are the ones a slab has answers for. What a slab adds is the three
/// numbers beside the bytes, and those are what this family checks.
///
/// One descriptor per case, and it is the *column* codec descriptor: the run
/// walk, the tail and the slice belong to the column layer that owns them
/// (`column.zig:360-367`), and `measure` and `Column.load` take it. The
/// bytes themselves are the corpus's, so this family needs no codec of its
/// own and dispatches on nothing but the value type.
const SlabKind = enum { u64, i64, u32, i32, opt_u64, opt_i64, opt_u32, opt_i32, boolean };

const slab_kinds = [_]struct { name: []const u8, tag: SlabKind }{
    .{ .name = "rle-u64", .tag = .u64 },
    .{ .name = "rle-i64", .tag = .i64 },
    .{ .name = "rle-u32", .tag = .u32 },
    .{ .name = "rle-i32", .tag = .i32 },
    .{ .name = "rle-opt-u64", .tag = .opt_u64 },
    .{ .name = "rle-opt-i64", .tag = .opt_i64 },
    .{ .name = "rle-opt-u32", .tag = .opt_u32 },
    .{ .name = "rle-opt-i32", .tag = .opt_i32 },
    .{ .name = "bool", .tag = .boolean },
};

/// The cases whose boundary is the slab's own rather than a run's: the
/// empty slab, a slab that is one run, a slab over the run budget, and a
/// slab whose last run is a literal one.
const slab_boundary_cases = [_][]const u8{
    "empty",
    "one",
    "two_equal",
    "two_differ",
    "repeat_2",
    "repeat_128",
    "repeat_16384",
    "null_128",
    "pair_0",
    "boundary_literal",
    "all_equal_300",
    "alternating",
    "random_0",
    "random_12",
    "random_23",
};

/// Every record the two families carry between them. A slab is an encoding
/// and not a format of its own, so it adds no case of its own and its count
/// is the sum of the two families' — 890 is `rle.zig`'s and 71 is
/// `bool.zig`'s, each asserted there over the same corpus.
const slab_cases: usize = 890 + 71;

/// How many of those records count runs where the reference counts
/// segments.
///
/// **Pinned, not asserted zero, and the pin is the test.** The two counts
/// are in different units and neither is a mistake: upstream's
/// `Slab.segments` costs a literal run its number of values and a repeat
/// or null run one (`rle/load.rs:38-39`, `:43-45`, `:50-52`, and the
/// loader's own copy of the same bookkeeping at `:132-153`), and this port
/// costs every run one — `measure` and `Slab.segments` in this file. So
/// the two agree on a slab whose every literal run holds exactly one value
/// and part company on every other one, and the number of those is a fact
/// about the layout rather than a failure. Every other number in this
/// family is compared exactly; see the diff block at the foot of this file.
const pinned_run_count: usize = 670;

/// How many of those records this port cuts where the reference's loader
/// does not, in the units above.
const pinned_cut: usize = 140;

/// How many item indices land in a different slab under this port's cut
/// than under the reference's.
///
/// **Deliberately not zero.** The cut really does differ, so a lookup for the
/// same key really does land in a different slab, and this is how many of
/// the corpus's items that happens to. The harmless half is checked in the
/// same pass rather than claimed here: every value of every record is read
/// back and compared with the reference's own, and every one of these indices
/// is read again through `get`, which is the path the cut can reach.
const pinned_slab_choice: usize = 4297;

/// One record that disagrees with the reference, kept so that a pin which
/// has moved names the case instead of only counting it.
///
/// **The three names are owned copies and not the record's own strings.** A
/// record is parsed into an arena that `eachCase` frees the moment the case
/// is done with, so a name borrowed from one is dangling by the time the
/// tally is read — which is the same rule every slice in a document obeys,
/// one arena in place of a document.
const Example = struct {
    codec: []u8,
    case: []u8,
    seed: []u8,
    /// What the reference said, and what this port said.
    reference: usize,
    port: usize,

    fn deinit(self: *Example, gpa: std.mem.Allocator) void {
        gpa.free(self.codec);
        gpa.free(self.case);
        gpa.free(self.seed);
        self.* = undefined;
    }
};

/// The numbers this pass counts.
///
/// Test-run state: Zig runs a file's tests one at a time in one thread, and
/// `eachCase`'s callback has no room to carry a pointer, so the count lives
/// here and the test that reads it resets it first. Counting is also the
/// only way to see *every* disagreement — a check that returned on the
/// first of 961 records would say nothing about the other 960, and the byte
/// comparison the compatibility contract depends on runs in the same pass.
const Divergence = struct {
    /// How many records the two families carried.
    cases: usize = 0,
    /// Records where the run count is not the reference's segment count.
    run_count: usize = 0,
    run_count_first: ?Example = null,
    /// Records where this port's cut is not the cut the corpus recorded.
    cut: usize = 0,
    cut_first: ?Example = null,
    /// Item indices whose slab this port's cut and the reference's cut do
    /// not agree on.
    slab_choice: usize = 0,
};

var divergence: Divergence = .{};

/// Records the first disagreement of a kind, and only that one.
fn noteExample(
    into: *?Example,
    rec: corpus.Record,
    reference: usize,
    port: usize,
    gpa: std.mem.Allocator,
) !void {
    if (into.* != null) return;
    into.* = .{
        .codec = try gpa.dupe(u8, rec.codec),
        .case = try gpa.dupe(u8, rec.case),
        .seed = try gpa.dupe(u8, rec.seed),
        .reference = reference,
        .port = port,
    };
}

/// Gives an example's copies back, for the test that reads the tally.
fn freeExample(into: *?Example, gpa: std.mem.Allocator) void {
    var e = into.* orelse return;
    e.deinit(gpa);
    into.* = null;
}

/// How many items a partition covers.
fn totalOf(lens: []const usize) !usize {
    var total: usize = 0;
    for (lens) |n| total = std.math.add(usize, total, n) catch return error.Overflow;
    return total;
}

/// Whether this port's cut is the reference's cut, as far as the corpus is
/// able to say.
///
/// **The corpus cannot say more than this, and a gate that pretends
/// otherwise is measuring its own bug.** The reference's loader cuts a slab
/// the moment its segment count reaches the target and flushes the trailing
/// one in `finalize` (`rle/load.rs:220-222`, `:259-261`); the oracle drains
/// with `try_next_run` and never calls `finalize`
/// (`tools/oracle/src/codec.rs:1146-1156`), so `split.lens` is every slab
/// the reference made **but the last**. So the claim is that the port's
/// partition starts with the recorded one and is at most one slab longer.
fn cutAgrees(recorded: []const usize, port: []const usize) bool {
    if (port.len < recorded.len or port.len > recorded.len + 1) return false;
    for (recorded, 0..) |want, i| {
        if (port[i] != want) return false;
    }
    return true;
}

/// One golden case, read as a slab: the metadata beside the bytes, the cut
/// the reference's loader made, and every read of the result.
///
/// `E` is the *column* codec descriptor the slab functions walk the bytes
/// with and `Element` the column's value type — which is also what
/// `Column(Element, E)` is named by, so the read path below is the one an
/// op set takes.
///
/// **The bytes are the reference's own, and nothing of this port stands in
/// for them.** Re-encoding the record's input first would make every answer
/// below a statement about this port's encoder as much as about the
/// reference, and comparing the two encodings is `rle.zig`'s and
/// `column.zig`'s job rather than this one's.
fn checkSlab(
    comptime E: type,
    comptime Element: type,
    rec: corpus.Record,
    gpa: std.mem.Allocator,
) !void {
    divergence.cases += 1;
    const values = try corpus.expand(gpa, Element, rec);
    defer gpa.free(values);
    const bytes = try corpus.referenceBytes(gpa, rec);
    defer gpa.free(bytes);

    // The reference's own metadata for those bytes, from its
    // `validate_encoding`. This is what a slab is beyond its data.
    const m = try measure(gpa, E, bytes);

    // **The item count, the tail's byte width and the literal-tail width are
    // the same number on both sides**, and they are what every consumer of a
    // slab reads first: the count is the length of the item range the slab
    // covers, and the width is the byte length of the slab's last run,
    // header and payload together (`rle/load.rs:33-36`, `:52-55`). The
    // literal-tail width is upstream's `None` for a repeat or null run
    // (`rle/mod.rs:101-103`), which is `0` in `Tail.lit_tail` here, so
    // there is no allowance anywhere in the comparison: a missing width
    // and a zero are the same zero, and a width is compared exactly.
    const want_lit_tail = rec.tail_lit_tail orelse 0;
    if (m.len != rec.slab_len or m.tail.bytes != rec.tail_bytes or m.tail.lit_tail != want_lit_tail) {
        std.debug.print(
            \\
            \\--- slab metadata mismatch ------------------------------------------
            \\  codec      {s}
            \\  case       {s}
            \\  seed       {s}
            \\                 reference     this port
            \\  len                 {d:>8}     {d:>8}
            \\  tail bytes          {d:>8}     {d:>8}
            \\  tail lit tail       {d:>8}     {d:>8}
            \\
        , .{ rec.codec, rec.case, rec.seed, rec.slab_len, m.len, rec.tail_bytes, m.tail.bytes, want_lit_tail, m.tail.lit_tail });
        return error.SlabMetadataMismatch;
    }

    // The run count, counted and not raised. See [`pinned_run_count`].
    if (m.segments != rec.segments) {
        divergence.run_count += 1;
        try noteExample(&divergence.run_count_first, rec, rec.segments, m.segments, gpa);
    }

    // ── The cut ───────────────────────────────────────────────────────────
    //
    // The column is loaded from the same reference bytes, so what is
    // checked here is the reference's own data read through this port's
    // loader and this port's index. And the two cuts are only comparable
    // because both loaders were given the same budget: the oracle's is the
    // record's, this port's is `default_max_segments`, which is what
    // `Column.load` cuts at half of (`column.zig:2709-2724`). A corpus
    // regenerated under another budget would make every count below
    // meaningless, so the budget is checked rather than assumed.
    const split = rec.split orelse return error.CorpusRecordMissing;
    try testing.expectEqual(@as(usize, default_max_segments), split.loader_max_segments);

    var col = try column.Column(Element, E).load(gpa, bytes);
    defer col.deinit();

    // This port's partition, item count by item count.
    var port: std.ArrayList(usize) = .empty;
    defer port.deinit(gpa);
    for (0..col.slabCount()) |i| {
        try port.append(gpa, col.slabAt(i).?.len);
    }

    // The reference's partition, with the slab its loader never recorded put
    // back: whatever the recorded slabs do not cover is the trailing one
    // `finalize` would have flushed (`rle/load.rs:259-261`).
    var ref: std.ArrayList(usize) = .empty;
    defer ref.deinit(gpa);
    try ref.appendSlice(gpa, split.lens);
    var trailing = values.len;
    for (split.lens) |n| trailing = std.math.sub(usize, trailing, n) catch return error.CorpusRecordMissing;
    if (trailing != 0) try ref.append(gpa, trailing);

    // Both partitions cover every value, so the cursors below always have a
    // slab to stand on: the sum of what is left is the number of items left,
    // so at least one remaining slab is non-empty. Asserted rather than
    // inferred, because the alternative is a subtraction that underflows.
    try testing.expectEqual(values.len, col.len());
    try testing.expectEqual(values.len, try totalOf(port.items));
    try testing.expectEqual(values.len, try totalOf(ref.items));

    if (!cutAgrees(split.lens, port.items)) {
        divergence.cut += 1;
        try noteExample(&divergence.cut_first, rec, split.lens.len, port.items.len, gpa);
    }

    // ── The reads ─────────────────────────────────────────────────────────
    //
    // This is the question the byte comparison cannot answer. The cut above
    // is known to differ on a large share of the corpus, a different cut
    // does put a lookup for the same key in a different slab, and what a
    // reader sees must not be what that changes.
    //
    // **Every value, through the column's own sequential read.** That walk
    // crosses every slab boundary the layout has, so it is the path a
    // document-wide read takes, and it costs one decoder per slab.
    const all = try col.toSlice(gpa);
    defer gpa.free(all);
    try testing.expectEqualSlices(Element, values, all);

    // **And every index the two cuts disagree about, plus every slab
    // boundary, through `get`** — the index-driven read, which is the only
    // path on which the cut can decide anything at all: `get` finds a slab
    // with the tree and walks to the row inside it (`column.zig:1764-1780`),
    // and the tree is keyed by item offset, so the cut moves the slab and
    // nothing else. Those two sets are the whole of what a differing cut
    // can reach, which is why the index is not walked row by row: on a
    // 32 769-value column that is a walk of the slab per row, and it would
    // say the same thing 32 769 times over.
    try expectReadsAt(Element, E, rec, &col, values, port.items, ref.items, gpa);
}

/// Reads through `Column.get` every index the two cuts disagree about and
/// every slab boundary of this port's partition, and fails naming the one
/// that answered differently.
fn expectReadsAt(
    comptime Element: type,
    comptime E: type,
    rec: corpus.Record,
    col: *const column.Column(Element, E),
    values: []const Element,
    port: []const usize,
    ref: []const usize,
    gpa: std.mem.Allocator,
) !void {
    // The indices the two partitions disagree about, in order: the walk is
    // the same two cursors the count would otherwise need, so the set is
    // exact rather than sampled and the count falls out of building it.
    var rows: std.ArrayList(usize) = .empty;
    defer rows.deinit(gpa);
    var at: usize = 0;
    var pi: usize = 0;
    var ri: usize = 0;
    var p_left: usize = if (port.len == 0) 0 else port[0];
    var r_left: usize = if (ref.len == 0) 0 else ref[0];
    while (at < values.len) : (at += 1) {
        while (pi + 1 < port.len and p_left == 0) : (pi += 1) p_left = port[pi];
        while (ri + 1 < ref.len and r_left == 0) : (ri += 1) r_left = ref[ri];
        if (pi != ri) {
            try rows.append(gpa, at);
            divergence.slab_choice += 1;
        }
        p_left -= 1;
        r_left -= 1;
    }
    // Every boundary this port's own partition puts in, and the row before
    // it: the first row of a slab is where the index sends a lookup, and the
    // row in front of it is the one a decoder is left sitting on across it.
    var before: usize = 0;
    for (port) |n| {
        try rows.append(gpa, before);
        if (n != 0) try rows.append(gpa, before + n - 1);
        before += n;
    }
    // The sort brought the two sets together, so one pass drops the rows
    // both of them named: `dedup` is a walk of its own, and this is the
    // same thing without the second one.
    var uniq: usize = 0;
    for (rows.items, 0..) |row, i| {
        if (i == 0 or row != rows.items[uniq - 1]) {
            rows.items[uniq] = row;
            uniq += 1;
        }
    }
    rows.items.len = uniq;

    for (rows.items) |i| {
        const want = values[i];
        const read = (try col.get(i)) orelse {
            std.debug.print(
                \\--- a slab read found nothing ----------------------------------------
                \\  codec  {s}
                \\  case   {s}
                \\  index  {d} of {d}
                \\
            , .{ rec.codec, rec.case, i, values.len });
            return error.SlabReadMisses;
        };
        if (read != want) {
            std.debug.print(
                \\--- a slab read answers differently ----------------------------------
                \\  codec      {s}
                \\  case       {s}
                \\  seed       {s}
                \\  index      {d} of {d}
                \\  reference  {any}
                \\  this port  {any}
                \\
                \\The bytes are the reference's, so a read cannot answer differently unless
                \\the cut changed which slab the index landed in. It did: this is that.
                \\
            , .{ rec.codec, rec.case, rec.seed, i, values.len, want, read });
            return error.SlabReadDiverges;
        }
    }
    try testing.expect((try col.get(values.len)) == null);
}

fn slabCaseFor(kind: SlabKind, rec: corpus.Record, gpa: std.mem.Allocator) !void {
    switch (kind) {
        .u64 => try checkSlab(column.Rle(u64), u64, rec, gpa),
        .i64 => try checkSlab(column.Rle(i64), i64, rec, gpa),
        .u32 => try checkSlab(column.Rle(u32), u32, rec, gpa),
        .i32 => try checkSlab(column.Rle(i32), i32, rec, gpa),
        .opt_u64 => try checkSlab(column.RleOption(u64), ?u64, rec, gpa),
        .opt_i64 => try checkSlab(column.RleOption(i64), ?i64, rec, gpa),
        .opt_u32 => try checkSlab(column.RleOption(u32), ?u32, rec, gpa),
        .opt_i32 => try checkSlab(column.RleOption(i32), ?i32, rec, gpa),
        .boolean => try checkSlab(column.Bool, bool, rec, gpa),
    }
}

/// One golden case, dispatched by the column type its name carries. A
/// boolean record is the one an RLE record is not, so the family is walked
/// twice and the counts are the corpus's own, split by family.
fn slabCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    try corpus.dispatch(slab_kinds, slabCaseFor, gpa, rec);
}

test "a slab's metadata and reads are the reference's, and its run count and cut are a pinned divergence" {
    const gpa = testing.allocator;
    var names = corpus.Names.init(gpa);
    defer names.deinit();
    // The tally is this test's own, and the two examples in it own their
    // names: the tally outlives the arena every record was parsed in, so
    // the `defer` has to be here rather than at the point of the first
    // disagreement.
    divergence = .{};
    defer {
        freeExample(&divergence.run_count_first, gpa);
        freeExample(&divergence.cut_first, gpa);
    }

    var cases: usize = 0;
    cases += try corpus.eachCase(gpa, "rle", &names, slabCase);
    cases += try corpus.eachCase(gpa, "bool", &names, slabCase);
    // Every RLE and boolean record, and not one more: a slab adds no cases
    // of its own, so a count above the two families' total would mean the
    // family was answering for something it does not own. The other half
    // of that claim is the test below, which checks the pairing itself.
    try testing.expectEqual(slab_cases, cases);
    try testing.expectEqual(slab_cases, divergence.cases);
    try names.expectRequired(&slab_boundary_cases);

    if (divergence.run_count == pinned_run_count and
        divergence.cut == pinned_cut and
        divergence.slab_choice == pinned_slab_choice) return;

    std.debug.print(
        \\
        \\--- the slab layout pin moved ---------------------------------------------
        \\  the bytes are the reference's in all {d} of them, and so are the item
        \\  count, the tail's byte width and the literal-tail width. These three
        \\  counts are the layout, and they are pinned rather than asserted equal
        \\  because upstream and this port count a run in different units:
        \\
        \\                   this port     pinned
        \\  run count              {d:>8}     {d:>8}
        \\  cut                    {d:>8}     {d:>8}
        \\  items in another slab  {d:>8}     {d:>8}
        \\
    , .{
        cases,
        divergence.run_count,
        pinned_run_count,
        divergence.cut,
        pinned_cut,
        divergence.slab_choice,
        pinned_slab_choice,
    });
    printExample("run count", divergence.run_count_first);
    printExample("cut", divergence.cut_first);
    std.debug.print(
        \\
        \\Upstream's `Slab.segments` costs a literal run its number of values
        \\(`rle/load.rs:38-39`) and this port costs every run one, so the two
        \\counts and the two cuts part company on every literal run of more than
        \\one value. The diff block at the foot of `slab.zig` says what that does
        \\and does not change.
        \\
    , .{});
    return error.SlabLayoutPinMoved;
}

fn printExample(what: []const u8, ex: ?Example) void {
    const e = ex orelse return;
    std.debug.print(
        \\
        \\--- {s} first differs ---------------------------------------------
        \\  codec      {s}
        \\  case       {s}
        \\  seed       {s}
        \\  reference  {d}
        \\  this port  {d}
        \\
    , .{ what, e.codec, e.case, e.seed, e.reference, e.port });
}

/// Whether `codec` is one of the names `slabCase` dispatches on.
fn isSlabCodec(name: []const u8) bool {
    for (slab_kinds) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return true;
    }
    return false;
}

/// Fails when a record's `codec` and `family` disagree about which family
/// owns it, in either direction.
fn ownershipCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    _ = gpa;
    const family_owns = std.mem.eql(u8, rec.family, "rle") or std.mem.eql(u8, rec.family, "bool");
    if (family_owns == isSlabCodec(rec.codec)) return;
    std.debug.print(
        \\
        \\--- a codec is not in the family that dispatches on it --------------------
        \\  codec   {s}
        \\  family  {s}
        \\
        \\A slab is an encoding, so this family answers for the RLE and boolean
        \\records and for nothing else. The table above names the codecs it
        \\dispatches on and the walk above covers `rle` and `bool`, and the two
        \\have to be the same set. A codec added to the table without a family,
        \\or a family given a codec the table does not name, lands here.
        \\
    , .{ rec.codec, rec.family });
    return error.SlabCodecOutsideItsFamily;
}

test "a slab answers for the RLE and boolean families and for nothing else" {
    const gpa = testing.allocator;
    // **The count in the test above does not say this on its own.** 890 + 71
    // is also the total of a family that had grown a codec this one answers
    // for and lost one it does not, so the pairing is checked here rather
    // than argued. The four families' totals are 890 RLE, 71 boolean, 540
    // delta and 465 prefix, all from the same file.
    try testing.expectEqual(@as(usize, 890 + 71 + 540 + 465), try corpus.eachCodecRecord(gpa, ownershipCase));
}

// ── The diff ─────────────────────────────────────────────────────────────────
//
// Upstream is Rust and this is Zig 0.16.0, and on the three numbers beside a
// slab's bytes the two do not agree. None of it is in the compatibility
// contract — the document format, the change encoding, the column ids, the
// column order and the sync message bytes are — and the corpus says so with
// the bytes: every codec's wire bytes are the reference's, for all of the
// 1,966 records `test/golden/codec.jsonl` carries.
//
// * `Slab.segments` counts wire runs here. Upstream counts a literal run as
//   its number of values and a repeat or null run as one
//   (`rle/load.rs:38-39`, `:43-45`, `:50-52`), and its loader's own copy of
//   that bookkeeping is at `rle/load.rs:132-153`. `check_invariants`
//   asserts the two are the same number there (`column.rs:1316-1319`), so
//   upstream has one count and this port has another. 670 of the 961 RLE
//   and boolean records differ; the pin is `pinned_run_count`.
//
// * A load therefore cuts at 32 wire runs where upstream cuts at 32
//   segments, and on a slab of literal values that is a different place.
//   `boundary_literal` is 44 distinct values in one literal run, so
//   upstream cuts it 32 + 12 and this port leaves it whole. The count of
//   those is the pin `pinned_cut`, and `cutAgrees` is what says how far the
//   corpus is able to check either cut at all.
//
// * The cut is not free to differ. A lookup does land in a different slab —
//   `pinned_slab_choice` is how many items — and the index is keyed by item
//   offset and not by `segments` (`column.zig:1764-1780`), so the slab it
//   selects is the only thing the cut changes. That is checked, not argued:
//   every value of every record is read through the column's own walk and
//   compared with the reference's own value, and every index the two cuts
//   disagree about is read again through `get`.
//
// What the difference does cost is size and time: a slab here can hold as
// many literal runs as the budget names, each of any length, where upstream
// holds at most 64 segments. A splice into such a slab decodes the whole
// middle (`Partition.rebuild`), which is the deviation the module comment
// above already names for a long repeat run.
//
// Three things do **not** differ, and are compared exactly rather than
// pinned: the item count (`rle/load.rs:38`, `:44-45`), the tail's byte width
// (`rle/load.rs:33-36`, `:52-55`), and the literal-tail width. That last one
// is upstream's `None` for a repeat or null run (`rle/mod.rs:101-103`), which
// is `0` in `Tail` here — and now also in the descriptor that fills it
// (`column.zig:694-721`), which used to hand back the repeated value's width
// and put 136 of the 961 records out. The descriptor contradicted its own
// documentation there, and nothing read the field, so the fix is free.

// Zig 0.16.0 / upstream / Rust / port
//
// The block above records the run-count and cut divergences. This one records
// what the nine upstream-named cases added on 2026-10-01 changed, and what
// they did not.
//
// * **Nine `Column`-typed upstream cases are transcribed here against a slab,
//   and at these sizes the column *is* a slab.** The largest input is
//   twenty-six values and the run budget is `default_max_segments = 64`
//   (`slab.zig:114`), so upstream's column holds exactly one slab and every
//   operation it performs is this file's `splice` or `merge` — the column
//   machinery on both sides of the port calls down to them. **What is not
//   covered is a `Column<u64>` cut across *several* slabs**, which is
//   `column.zig`'s and is transcribed there.
//
// * **`colmod.Rle`, `colmod.RleOption` and `colmod.Bool` are named as codec
//   *types*.** No `Column` is constructed and nothing in `column.zig` is
//   touched; `E` is a comptime parameter and the tests below build, splice,
//   merge and measure slabs directly. This is the shape this file's corpus
//   checks above already use (`slab.zig:2144`), and `slab.splice`'s own
//   contract is stated in terms of `E.Wire` alone (`slab.zig:549-557`).
//
// * **`splice_runs_matches_per_item_splice` keeps upstream's shape but not its
//   contrast.** Upstream contrasts `splice_runs` (runs in one call) with
//   `splice` (values one at a time) over a `Column`; the port has one splice,
//   so what is contrasted here is *one call carrying five values* against *five
//   calls carrying one each*. **A bug in a run-pair deserialiser the port does
//   not have is therefore not caught here** — upstream's is folded into the
//   same `splice_inner` this port's `splice` implements (`column.rs:1563`).
//   The delete count is the first item's and the rest carry none: deleting one
//   item per step runs off the end at `(at, del) = (4, 0)`, where there is
//   nothing to delete.
//
// * **`splice_runs_with_ranges` and `splice_runs_from_another_columns_iter`
//   were deleted from this file, not weakened in it.** Both asserted the
//   *answer* rather than the derivation: one concatenated three windows by
//   hand, the other wrote out the four values a clipped window holds. **Both
//   names are held elsewhere and by the adapter that has to carry the case** —
//   `hexane_test.zig` builds a real `Column`, walks `iter().runs().ranges([…])`
//   and `iterRange(1..5).runs()`, and splices what those cursors collected into
//   `Column.spliceRuns`. `Shiftable::ranges` (`shift.rs:87`, `:107`) is
//   `column.zig`'s `Ranges(I)`, over any cursor with `pos`, `setMax` and
//   `shift` (`column.zig:7289`), and it was driven at the time those cases
//   were here — the claim that no file under `src/hexane` defines a `ranges`
//   combinator was false. **A slab holds no `iterRange`, no `runs()` and no
//   `ranges`**, so a case about an adapter chain is a case about `Column`, and
//   keeping a by-hand version here would have been a second, weaker
//   declaration of the same upstream name.
//
// * **`bool_into_slab_tail_multibyte_leb` is a two-derivation case and both
//   derivations are this file's.** Upstream contrasts
//   `Encoder::encode_slab`'s tail with `BoolEncoding::validate_encoding`'s
//   (`tests.rs:4671-4681`); here the writer's tail comes from `tailAt` on the
//   run a rebuild just wrote (`slab.zig:643-657`) and the reader's from
//   `measure`'s walk (`slab.zig:317`). A tail that disagreed would make every
//   later splice cut in the wrong place, which is why the case compares them
//   and not just the values.
//
// * **`merge_slab_string_literal_boundary` is transcribed in `column.zig`, and
//   the codec it wanted exists.** Its two slabs are `["x","y","hello"]` and
//   `["hello","hello","world"]`, and the payload they need is the
//   length-prefixed byte string upstream's `ColumnValueRef for String` packs
//   (`lib.rs:694-731`): `RleUtf8` over `[]const u8`, which adds the UTF-8 check
//   and is an accepted payload for `checkPayload` (`rle.zig:127-131`). **It is
//   instantiated as `E` for `merge` there**, over the `slab.merge` this file
//   exports, so the literal-against-literal seam runs for a byte payload and not
//   only for an integer. The other three `merge_slab_*` cases stay here because
//   their values are integers, and this file is where the merge is.
//
// * **Per-case occurrence status, module-qualified ids and exclusion kinds are
//   owned by `docs/hexane-cases.json`**, and not by a second list here. A
//   ledger that appears in two files is a ledger that can drift, and the one
//   this block replaced counted names rather than declarations.
