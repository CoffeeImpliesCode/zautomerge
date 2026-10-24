//! Myers' diff over grapheme clusters, and the two document-facing hooks that
//! apply it.
//!
//! Provenance: vendored from `mitsuhiko/similar` at commit
//! `2b31f65445df9093ba007ca5a5ae6a71b899d491`, the same vendored copy
//! `automerge` carries (`text_diff/myers.rs:1-8`, `text_diff/replace.rs:1-6`,
//! `text_diff/utils.rs:1-7`). Those files are **Apache-2.0**; the notice is
//! `src/textdiff/LICENSE`, beside this file. Upstream `automerge` is MIT and the
//! two notices are kept separate.
//!
//! | this module | upstream |
//! | --- | --- |
//! | `Range`, `commonPrefixLen`, `commonSuffixLen` | `text_diff/utils.rs` |
//! | `diff`, `V`, `maxD`, `findMiddleSnake`, `conquer` | `text_diff/myers.rs` |
//! | `Replace` | `text_diff/replace.rs` |
//! | `myersDiff`, `TxHook` | `text_diff.rs:15-134` |
//! | `myersBlockDiff`, `BlockDiffHook`, `BlockOrGrapheme`, `splitBlock`, `updateBlock`, `spanAsGrapheme` | `text_diff.rs:136-515` |
//!
//! The unit the algorithm compares is a **grapheme cluster**, not a byte and
//! not a code point. `myers_diff` segments both sides with
//! `unicode_segmentation` (`text_diff.rs:24-25`) and so does `span_as_grapheme`
//! (`text_diff.rs:481-484`); this port segments with its own UAX #29
//! segmenter, `src/unicode.zig`, through `graphemes`. There is one segmenter in
//! the port, not two.
//!
//! # The hook is the only coupling point
//!
//! Upstream's `DiffHook` (`text_diff/myers.rs:29-52`) lets the caller react as
//! the diff is produced. The port keeps the trait's shape, the same five
//! methods with the same arguments called in the same order, and binds the
//! hook by `anytype` instead of through a vtable: one static call per event, no
//! indirection, and `Replace` is a generic struct rather than a generic over a
//! trait object. Each instantiation resolves its hook at compile time.
//!
//! The associated `Error` type of the Rust trait exists only so `TxHook` and
//! `BlockDiffHook` can share one driver. Zig infers one error set
//! per instantiation instead, and every hook here returns `err.Error`.
//!
//! Unused upstream helpers are not ported:
//! `UniqueItem`, `IdentifyDistinct` and `unique`, which `automerge` removed
//! from its copy of `similar` as unused (`text_diff/utils.rs:5-7`);
//! `Replace::into_inner` and its `AsRef`/`AsMut` impls
//! (`text_diff/replace.rs:35-39`, `:63-73`), which upstream marks
//! `#[allow(dead_code)]` and never calls; and `apply_marks_diff`
//! (`text_diff.rs:165-248`), which needs the `marks` and `iter` types this
//! module does not own.

const std = @import("std");

const err = @import("error.zig");
const types = @import("types.zig");
const unicode = @import("unicode.zig");

const Allocator = std.mem.Allocator;
const ExId = types.ExId;
const TextEncoding = types.TextEncoding;

// ── text_diff/utils.rs ─────────────────────────────────────────────────────

/// A half-open range of elements: `Range<usize>` upstream
/// (`text_diff/myers.rs:57-63`). Zig 0.16 has no `Range` in `std`, so the two
/// fields carry upstream's names.
pub const Range = struct {
    /// The first element of the range.
    start: usize,
    /// One past the last element.
    end: usize,

    /// `Range::len`. Upstream panics on an inverted range, but every call site
    /// passes ranges it has already checked
    /// (`text_diff/utils.rs:29-31`, `text_diff/myers.rs:271-293`); this
    /// returns 0, so a range a hook or a caller got wrong cannot panic the
    /// diff.
    pub fn len(self: Range) usize {
        return if (self.end <= self.start) 0 else self.end - self.start;
    }

    /// `is_empty_range` (`text_diff/utils.rs:11-15`), which is
    /// `!(range.start < range.end)`.
    pub fn isEmpty(self: Range) bool {
        return !(self.start < self.end);
    }
};

/// Element equality for a diff over grapheme slices, where an element is a
/// byte slice: two graphemes are equal when their bytes are, which is the
/// comparison `text_diff/myers.rs:68` makes on `&str` output.
pub fn graphemeEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `common_prefix_len` (`text_diff/utils.rs:17-39`): the length of the longest
/// common prefix of `old[old_range]` and `new[new_range]`, zero when either
/// range is empty.
pub fn commonPrefixLen(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    old: []const T,
    old_range: Range,
    new: []const T,
    new_range: Range,
) usize {
    if (old_range.isEmpty() or new_range.isEmpty()) return 0;
    // Upstream zips the two ranges, so the shorter one bounds the answer
    // (`text_diff/utils.rs:32-38`).
    const n = @min(old_range.len(), new_range.len());
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!eql(old[old_range.start + i], new[new_range.start + i])) break;
    }
    return i;
}

/// `common_suffix_len` (`text_diff/utils.rs:41-64`): the length of the longest
/// common suffix of `old[old_range]` and `new[new_range]`, zero when either
/// range is empty.
pub fn commonSuffixLen(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    old: []const T,
    old_range: Range,
    new: []const T,
    new_range: Range,
) usize {
    if (old_range.isEmpty() or new_range.isEmpty()) return 0;
    const n = @min(old_range.len(), new_range.len());
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!eql(old[old_range.end - 1 - i], new[new_range.end - 1 - i])) break;
    }
    return i;
}

/// Splits `text` into its extended grapheme clusters, borrowed from `text`:
/// `str::graphemes(true).collect()` (`text_diff.rs:24-25`, `:481-484`). The
/// caller frees the slice with the same allocator; the bytes belong to
/// `text`.
///
/// A cluster is the unit the diff compares, so this is where "one change"
/// comes from: changing a byte inside a cluster changes one element here, not
/// one byte in the middle of two elements.
///
/// **One pass, and the segmentation is `src/unicode.zig`.** There is one
/// segmenter in the port and this is it; a second one here would be a second
/// answer to the UAX #29 rules, and this port has already had one wrong
/// implementation of them (`opensCluster` in `unicode.zig`, and the paragraph
/// below).
///
/// **The walk below is not a library call that could have been left in, and
/// this comment is here so that nobody puts one back.** It used to be:
///
/// ```text
///     while (i < text.len) {
///         const stop = i + len;                              // one codepoint
///         const seen = unicode.countGraphemes(text[0..stop]) // the WHOLE prefix
///         if (seen > before) { ...close a cluster... }
///         i = stop;
///     }
/// ```
///
/// That is the boundary rule "a cluster boundary falls at a codepoint
/// position exactly when the number of clusters in the prefix grows there",
/// which is true, and it asks [`unicode.countGraphemes`] about **every
/// prefix**, so it walks `n²/2` code points: `O(n²)` for a segmentation that
/// is `O(n)`. It was written that way because
/// [`unicode.nextGraphemeBoundary`] and
/// [`unicode.prevGraphemeBoundary`] computed their break decision as
/// `!st.started or st.step(cp)`, the `or` short-circuited, `step` never ran,
/// `started` never became true, and every position in a string then looked
/// like a cluster start — so those two answered "the next *codepoint*
/// boundary" instead of "the next *cluster* boundary". Fixing the
/// short-circuit made them correct, and this function uses
/// [`unicode.graphemeBoundaries`] instead.
///
/// **What it cost, measured on this tree, `-OReleaseSafe`, the same inputs
/// before and after.** The body is `"the quick brown fox. "` repeated, so it
/// is pure ASCII and every byte is its own cluster.
///
/// | bytes | clusters | before | after |
/// | --- | --- | --- | --- |
/// | 13 125 | 13 125 | **35 550 ms** | **13 ms** |
/// | 26 250 | 26 250 | **130 696 ms** | **14 ms** |
/// | 52 500 | 52 500 | — | **20 ms** |
/// | 105 000 | 105 000 | — | **49 ms** |
/// | 210 000 | 210 000 | ~2.5 h (extrapolated) | **89 ms** |
///
/// **Before, doubling the input took 3.68x as long** — the `n²` signature and
/// not a constant factor, and the shape it extrapolates to on the 210 000
/// characters the test below actually splices is about **two and a half
/// hours**. After, the curve is flat and linear: doubling the input roughly
/// doubles the time.
///
/// That is why `read.zig`'s `a mark at the end of a long text is found at the
/// end (text.rs:1121-1154)` did not finish: its fixture is spliced under
/// `.grapheme_cluster`, and **97.1% of a `perf record` of the stuck process
/// was `unicode.countGraphemes`** — 5 950 samples over 60 s with none lost,
/// state R at 99% CPU with RSS flat at 4.4 MB, which is a spinning loop and
/// not a blocked one. Every other mark test is green because every other
/// fixture is short enough for an `O(n²)` walk to look instant.
///
/// Text that is not text is `error.InvalidCharacter`, the only failure
/// segmentation can report. `src/unicode.zig` publishes its error set as
/// `anyerror` because Zig's UTF-8 decoder does not, so the mapping happens
/// here and the diff keeps the `err.Error` set.
pub fn graphemes(gpa: Allocator, text: []const u8) err.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var walk = unicode.graphemeBoundaries(text);
    // Where the cluster being collected starts. It is 0 for the first, and
    // every answer after it is where the cluster that opened there ends.
    var at: usize = 0;
    while (walk.next() catch return error.InvalidCharacter) |start| {
        try out.append(gpa, text[at..start]);
        at = start;
    }
    // **The last cluster is closed by the end of the text**, not by a break:
    // `unicode.GraphemeBoundaryIter` answers every start after the first, and
    // there is no rule to fire on after the last code point.
    if (at < text.len) try out.append(gpa, text[at..]);
    return out.toOwnedSlice(gpa);
}

// ── text_diff/myers.rs ─────────────────────────────────────────────────────

/// The point `conquer` splits at, in absolute indices: `Option<(usize, usize)>`
/// upstream (`text_diff/myers.rs:145-152`). The forward search returns the
/// start of the middle snake (`text_diff/myers.rs:210`) and the backward
/// search its end (`:243`); both are the point the range pair divides at.
const Point = struct {
    x: usize,
    y: usize,
};

/// `V` (`text_diff/myers.rs:92-108`): the endpoints of the furthest reaching
/// D-paths. For a recorded endpoint `(x, y)` on diagonal `k` only `x` is kept,
/// because `y` is `x - k`.
///
/// `k` runs negative, so the buffer is a flat slice plus the `offset` that maps
/// `k` back to an index (`text_diff/myers.rs:86-90`). Zig has no indexing
/// operators, so the two `Index`/`IndexMut` impls
/// (`text_diff/myers.rs:110-122`) are `get` and `set`.
const V = struct {
    offset: isize,
    v: []usize,

    /// `V::new` (`text_diff/myers.rs:98-103`): `2 * max_d` slots, zeroed, with
    /// `offset = max_d`.
    fn init(gpa: Allocator, max_d: usize) !V {
        return .{
            .offset = @intCast(max_d),
            .v = try gpa.alloc(usize, 2 * max_d),
        };
    }

    fn deinit(self: *V, gpa: Allocator) void {
        gpa.free(self.v);
        self.* = undefined;
    }

    /// `Index<isize>` (`text_diff/myers.rs:110-116`).
    fn get(self: *const V, k: isize) usize {
        return self.v[@intCast(k + self.offset)];
    }

    /// `IndexMut<isize>` (`text_diff/myers.rs:118-122`).
    fn set(self: *V, k: isize, x: usize) void {
        self.v[@intCast(k + self.offset)] = x;
    }
};

/// The width `maxD` computes the midpoint in: twice `usize`, so the sum of
/// two lengths and the two `+ 1`s after the division all fit with room to
/// spare however large the two lengths are.
const MidpointWidth = @Int(.unsigned, 2 * @bitSizeOf(usize));

/// `max_d` (`text_diff/myers.rs:124-127`): the number of edit-distance rounds
/// the middle-snake search explores, `ceil((N + M) / 2) + 1`.
///
/// This is the bound that makes the search finite. `find_middle_snake` loops
/// `d` from 0 to `d_max` and then gives up (`text_diff/myers.rs:176`,
/// `:251-252`), and the vendored copy deliberately has no deadline and no
/// heuristics (`text_diff/myers.rs:5-6`, `:19-23`), so this bound and the `V`
/// capacity it implies are the whole of the algorithm's cost control.
///
/// The bound also bounds the `V` index range, so `2 * max_d` slots are enough:
/// `find_middle_snake` reads `k + 1` only when `k != d` and `k - 1` only when
/// `k != -d` (`text_diff/myers.rs:179-183`), and the mirrored diagonals it
/// reads are guarded by `|k - delta| <= d`, so `|k| <= d_max - 1` throughout and
/// the largest index is `2 * max_d - 1`, the last slot `V::init` allocates.
fn maxD(len1: usize, len2: usize) usize {
    // `div_ceil(len1 + len2, 2)` is `(len1 + len2 + 1) / 2`; the divisor is the
    // constant 2, so there is no division error to handle. The `+ 1` outside
    // is upstream's, with its own note that it may be removable
    // (`text_diff/myers.rs:125-126`).
    //
    // The sum is taken in `MidpointWidth` rather than in `usize`, because
    // nothing about the operands keeps it inside `usize`: `len1` and `len2`
    // are the lengths of the two sub-ranges the divide step was handed
    // (`text_diff/myers.rs:158-159`, `:172`), and two `usize` lengths can
    // sum past `maxInt(usize)`. A width that wide cannot wrap, so the sum,
    // the division and both `+ 1`s are exact, and only the answer comes back
    // to `usize` — the width of the `V` buffers it sizes (`V::new`,
    // `text_diff/myers.rs:98-103`).
    const total: MidpointWidth = @as(MidpointWidth, len1) + @as(MidpointWidth, len2);
    const d_max: MidpointWidth = total / 2 + @intFromBool(total % 2 != 0) + 1;
    // Unreachable, because two live slices cannot sum to more than the
    // address space they are cut from; spelled out so the narrowing below
    // carries a bound rather than an assumption.
    return @intCast(@min(d_max, @as(MidpointWidth, std.math.maxInt(usize))));
}

/// `split_at` (`text_diff/myers.rs:129-132`).
fn splitAt(range: Range, at: usize) [2]Range {
    return .{
        .{ .start = range.start, .end = at },
        .{ .start = at, .end = range.end },
    };
}

/// `find_middle_snake` (`text_diff/myers.rs:145-253`): the divide step of the
/// divide-and-conquer strategy. It runs the basic search forward and backward
/// at once until the furthest reaching paths from opposing corners overlap,
/// and returns the point to split at in absolute indices: the start of the
/// middle snake when the forward search found the overlap, its end when the
/// backward search did. Null when the bound is reached with no overlap.
fn findMiddleSnake(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    old: []const T,
    old_range: Range,
    new: []const T,
    new_range: Range,
    vf: *V,
    vb: *V,
) ?Point {
    const n = old_range.len();
    const m = new_range.len();

    // By Lemma 1 in the paper, the optimal edit script length is odd or even
    // as `delta` is odd or even (`text_diff/myers.rs:161-164`).
    const delta: isize = @as(isize, @intCast(n)) - @as(isize, @intCast(m));
    const odd = delta & 1 == 1;

    // The initial point at (0, -1), and the initial point at (N, M+1)
    // (`text_diff/myers.rs:166-169`).
    vf.set(1, 0);
    vb.set(1, 0);

    // We only need to explore ceil(D/2) + 1
    // (`text_diff/myers.rs:171-174`).
    const d_max = maxD(n, m);
    std.debug.assert(vf.v.len >= d_max and vb.v.len >= d_max);
    const d_end: isize = @intCast(d_max);

    var d: isize = 0;
    while (d < d_end) : (d += 1) {
        // Forward path: k runs d, d-2, ..., -d, which is
        // `(-d..=d).rev().step_by(2)` (`text_diff/myers.rs:178`).
        var k: isize = d;
        while (k >= -d) : (k -= 2) {
            var x: usize = if (k == -d or (k != d and vf.get(k - 1) < vf.get(k + 1)))
                vf.get(k + 1)
            else
                vf.get(k - 1) + 1;
            // Upstream casts `x - k` to `usize` (`text_diff/myers.rs:184`), and
            // a path that has left the grid wraps to a value large enough that
            // the `y < new_range.len()` guard rejects it. Comparing as `isize`
            // says the same thing without the wrap.
            const y: isize = @as(isize, @intCast(x)) - k;

            // The coordinate of the start of a snake
            // (`text_diff/myers.rs:186-187`).
            const x0 = x;
            const y0: usize = if (y < 0) 0 else @intCast(y);

            // While these sequences are identical, keep moving through the
            // graph with no cost (`text_diff/myers.rs:188-198`).
            //
            // The bound is compared as a `usize` length, not as an `isize`
            // copy of one: `y` is signed because a path that has left the
            // grid is negative, and `y >= 0` above is what makes casting it
            // back safe, so no length is ever narrowed to fit the
            // comparison. The `new_range.start + …` below reads the same `y`
            // as a `usize` for the same reason.
            if (x < old_range.len() and y >= 0 and @as(usize, @intCast(y)) < new_range.len()) {
                x += commonPrefixLen(T, eql, old, .{
                    .start = old_range.start + x,
                    .end = old_range.end,
                }, new, .{
                    .start = new_range.start + @as(usize, @intCast(y)),
                    .end = new_range.end,
                });
            }

            // This is the new best x value (`text_diff/myers.rs:200-201`).
            vf.set(k, x);

            // Only check for connections from the forward search when N - M is
            // odd and when there is a reciprocal k line coming from the other
            // direction (`text_diff/myers.rs:203-212`).
            if (odd and @abs(k - delta) <= d - 1) {
                if (x + vb.get(-(k - delta)) >= n) {
                    return .{ .x = x0 + old_range.start, .y = y0 + new_range.start };
                }
            }
        }

        // Backward path (`text_diff/myers.rs:215-246`).
        k = d;
        while (k >= -d) : (k -= 2) {
            var x: usize = if (k == -d or (k != d and vb.get(k - 1) < vb.get(k + 1)))
                vb.get(k + 1)
            else
                vb.get(k - 1) + 1;
            var y: isize = @as(isize, @intCast(x)) - k;

            // The coordinate of the start of a snake (`text_diff/myers.rs:224`).
            if (x < n and y >= 0 and y < @as(isize, @intCast(m))) {
                const advance = commonSuffixLen(T, eql, old, .{
                    .start = old_range.start,
                    .end = old_range.start + n - x,
                }, new, .{
                    .start = new_range.start,
                    .end = new_range.start + m - @as(usize, @intCast(y)),
                });
                x += advance;
                y += @intCast(advance);
            }

            // This is the new best x value (`text_diff/myers.rs:236-237`).
            vb.set(k, x);

            if (!odd and @abs(k - delta) <= d) {
                if (x + vf.get(-(k - delta)) >= n) {
                    const yu: usize = if (y < 0) 0 else @intCast(y);
                    return .{ .x = n - x + old_range.start, .y = m - yu + new_range.start };
                }
            }
        }
    }

    // deadline reached (`text_diff/myers.rs:251-252`)
    return null;
}

/// `conquer` (`text_diff/myers.rs:256-319`): emit the events for one range
/// pair, recursing around the middle snake.
fn conquer(
    comptime T: type,
    comptime eql: fn (T, T) bool,
    hook: anytype,
    old: []const T,
    old_range: Range,
    new: []const T,
    new_range: Range,
    vf: *V,
    vb: *V,
) !void {
    // Check for common prefix (`text_diff/myers.rs:271-277`).
    const prefix = commonPrefixLen(T, eql, old, old_range, new, new_range);
    if (prefix > 0) try hook.equal(old_range.start, new_range.start, prefix);
    const old_from = old_range.start + prefix;
    const new_from = new_range.start + prefix;

    // Check for common suffix (`text_diff/myers.rs:279-286`).
    const suffix = commonSuffixLen(T, eql, old, .{
        .start = old_from,
        .end = old_range.end,
    }, new, .{
        .start = new_from,
        .end = new_range.end,
    });
    const old_to = old_range.end - suffix;
    const new_to = new_range.end - suffix;
    const rest = Range{ .start = old_from, .end = old_to };
    const rest_new = Range{ .start = new_from, .end = new_to };

    if (rest.isEmpty() and rest_new.isEmpty()) {
        // Do nothing (`text_diff/myers.rs:288-289`).
    } else if (rest_new.isEmpty()) {
        try hook.delete(rest.start, rest.len(), rest_new.start);
    } else if (rest.isEmpty()) {
        try hook.insert(rest.start, rest_new.start, rest_new.len());
    } else if (findMiddleSnake(T, eql, old, rest, new, rest_new, vf, vb)) |snake| {
        if (snake.x == rest.start and snake.y == rest_new.start) {
            // The split would hand both children the range they came from.
            // `find_middle_snake` cannot return this: the two ranges differ at
            // their first element, because the common prefix is already
            // stripped, so no overlap is found before `d = 1`, and at `d = 1`
            // the snake starts one step in. It is checked rather than assumed,
            // because this is the test that decides the recursion terminates,
            // and the whole-range delete and insert below is the answer
            // upstream gives when the search finds nothing
            // (`text_diff/myers.rs:301-312`).
            try hook.delete(rest.start, rest.len(), rest_new.start);
            try hook.insert(rest.start, rest_new.start, rest_new.len());
        } else {
            const old_halves = splitAt(rest, snake.x);
            const new_halves = splitAt(rest_new, snake.y);
            try conquer(T, eql, hook, old, old_halves[0], new, new_halves[0], vf, vb);
            try conquer(T, eql, hook, old, old_halves[1], new, new_halves[1], vf, vb);
        }
    } else {
        try hook.delete(rest.start, rest.len(), rest_new.start);
        try hook.insert(rest.start, rest_new.start, rest_new.len());
    }

    if (suffix > 0) try hook.equal(old_to, new_to, suffix);
}

/// Myers' diff algorithm (`text_diff/myers.rs:57-75`): diff `old` between
/// `old_range` against `new` between `new_range`, reporting every step to
/// `hook` as it is found.
///
/// The hook must provide `equal`, `delete`, `insert`, `replace` and `finish`,
/// each returning an error set, and the events must be contiguous and
/// increasing in both sequences: the `old_index` and `new_index` of an event
/// are the positions the previous events stopped at. `Replace` asserts that
/// contract as it merges runs (`text_diff/replace.rs:98-103`, `:114-117`).
///
/// `T` is the element type and `eql` its equality, so one driver serves a diff
/// over grapheme clusters and a diff over blocks. Upstream's two sequences
/// have separate types with a cross-type `PartialEq` bound
/// (`text_diff/myers.rs:64-69`); both callers here pass the same type, so the
/// port has one.
///
/// The search is bounded by `maxD`; the two `V` buffers are allocated once and
/// reused by every recursion, as upstream does (`text_diff/myers.rs:70-73`).
pub fn diff(
    gpa: Allocator,
    comptime T: type,
    comptime eql: fn (T, T) bool,
    hook: anytype,
    old: []const T,
    old_range: Range,
    new: []const T,
    new_range: Range,
) !void {
    const max_d = maxD(old_range.len(), new_range.len());
    var vb = try V.init(gpa, max_d);
    defer vb.deinit(gpa);
    var vf = try V.init(gpa, max_d);
    defer vf.deinit(gpa);
    try conquer(T, eql, hook, old, old_range, new, new_range, &vf, &vb);
    try hook.finish();
}

// ── text_diff/replace.rs ───────────────────────────────────────────────────

/// A run of consecutive events the decorator is accumulating
/// (`text_diff/replace.rs:20-22`). Upstream keeps three
/// `Option<(usize, usize, usize)>` tuples whose positions mean something
/// different in each, so the port names all four positions; the position a run
/// does not use is left at zero.
const Run = struct {
    /// The first old-sequence index the run covers.
    old_index: usize,
    /// The deleted length. A delete run only.
    old_len: usize = 0,
    /// The first new-sequence index the run covers.
    new_index: usize = 0,
    /// The inserted length, and the length of an equal run, where it is the
    /// length on both sides.
    new_len: usize = 0,
};

/// A hook that combines deletions and insertions into blocks of maximal
/// length, and replacements when appropriate (`text_diff/replace.rs:17`).
///
/// It replaces `delete` and `insert` events where it can with `replace`
/// events. The text diff does not need them, because `myersDiff` runs the raw
/// hook, but the block diff does, and running the decorator everywhere keeps
/// the order of inserts and deletes consistent
/// (`text_diff/replace.rs:8-16`; `text_diff.rs:150-159` wraps,
/// `text_diff.rs:37-43` does not).
pub fn Replace(comptime D: type) type {
    return struct {
        const Self = @This();

        /// The wrapped hook.
        d: D,
        /// The delete run being accumulated.
        del: ?Run = null,
        /// The insert run being accumulated.
        ins: ?Run = null,
        /// The equal run being accumulated.
        eq: ?Run = null,

        /// Emits the buffered equal run (`text_diff/replace.rs:41-46`).
        fn flushEq(self: *Self) !void {
            if (self.eq) |e| {
                self.eq = null;
                try self.d.equal(e.old_index, e.new_index, e.new_len);
            }
        }

        /// Emits the buffered delete and insert runs, as one `replace` when
        /// both are there (`text_diff/replace.rs:48-60`).
        fn flushDelIns(self: *Self) !void {
            if (self.del) |del| {
                self.del = null;
                if (self.ins) |ins| {
                    self.ins = null;
                    try self.d.replace(del.old_index, del.old_len, ins.new_index, ins.new_len);
                } else {
                    try self.d.delete(del.old_index, del.old_len, del.new_index);
                }
            } else if (self.ins) |ins| {
                self.ins = null;
                try self.d.insert(ins.old_index, ins.new_index, ins.new_len);
            }
        }

        /// Buffers the equal run and flushes any buffered delete and insert
        /// first, so a consumer sees `equal` events in the order the diff
        /// produced them. Adjacent `equal` events coalesce into one
        /// (`text_diff/replace.rs:41-46`, `:34-39`).
        pub fn equal(self: *Self, old_index: usize, new_index: usize, len: usize) !void {
            try self.flushDelIns();
            self.eq = if (self.eq) |e|
                .{ .old_index = e.old_index, .new_index = e.new_index, .new_len = e.new_len + len }
            else
                .{ .old_index = old_index, .new_index = new_index, .new_len = len };
        }

        /// Buffers the deleted run, flushing any equal run first
        /// (`text_diff/replace.rs:28-32`).
        ///
        /// **The contiguity precondition is asserted, not validated**
        /// (`text_diff/replace.rs:98-103`): `old_index` must be the position
        /// the buffered delete stopped at, which [`diff`] guarantees by
        /// producing contiguous, increasing events. `std.debug.assert` is a
        /// programmer precondition — it is compiled out in `ReleaseFast` and
        /// `ReleaseSmall`, where a violated contract folds two runs into one
        /// instead of trapping.
        pub fn delete(self: *Self, old_index: usize, old_len: usize, new_index: usize) !void {
            try self.flushEq();
            if (self.del) |del| {
                std.debug.assert(old_index == del.old_index + del.old_len);
                self.del = .{
                    .old_index = del.old_index,
                    .old_len = del.old_len + old_len,
                    .new_index = del.new_index,
                };
            } else {
                self.del = .{ .old_index = old_index, .old_len = old_len, .new_index = new_index };
            }
        }

        /// Buffers the inserted run, flushing any equal run first
        /// (`text_diff/replace.rs:33-35`).
        ///
        /// **The contiguity precondition is asserted, not validated**, on the
        /// new side this time (`text_diff/replace.rs:114-117`): `new_index`
        /// must be where the buffered insert stopped, with the same
        /// `std.debug.assert` caveat as [`delete`].
        pub fn insert(self: *Self, old_index: usize, new_index: usize, new_len: usize) !void {
            try self.flushEq();
            self.ins = if (self.ins) |ins| run: {
                std.debug.assert(ins.new_index + ins.new_len == new_index);
                break :run .{
                    .old_index = ins.old_index,
                    .new_index = ins.new_index,
                    .new_len = ins.new_len + new_len,
                };
            } else .{ .old_index = old_index, .new_index = new_index, .new_len = new_len };
        }

        /// Forwards one replacement immediately
        /// (`text_diff/replace.rs:36-37`). **This is the event a consumer's own
        /// hook sees for an adjacent delete and insert**: the two are folded
        /// into one `replace` by the buffered runs, not by two calls here.
        pub fn replace(self: *Self, old_index: usize, old_len: usize, new_index: usize, new_len: usize) !void {
            try self.flushEq();
            try self.d.replace(old_index, old_len, new_index, new_len);
        }

        /// Flushes every buffered run, in the order `equal`, then the combined
        /// delete-and-insert, then the wrapped hook's own `finish`
        /// (`text_diff/replace.rs:40`). **A diff that returns without this has
        /// emitted nothing**, because the last runs are still buffered.
        pub fn finish(self: *Self) !void {
            try self.flushEq();
            try self.flushDelIns();
            try self.d.finish();
        }
    };
}

// ── text_diff.rs, the caller-facing half ───────────────────────────────────

/// One element of a block diff: a block, or one grapheme cluster
/// (`BlockOrGrapheme`, `text_diff.rs:261-264`). A block is one element and text
/// is per grapheme, which is what makes a block diff and a text diff the same
/// algorithm over two element types.
///
/// `Block` is the hydrated block map (`text_diff.rs:262`). It must expose
/// `pub fn eql(a: Block, b: Block) bool`, the equality convention
/// `src/types.zig` already uses (`ExId.eql`, `types.zig:232`), because
/// upstream's derived `PartialEq` compares block contents rather than block
/// identity (`text_diff.rs:260`, `text_diff.rs:401`).
pub fn BlockOrGrapheme(comptime Block: type) type {
    return union(enum) {
        /// A block, which occupies one position in the text
        /// (`text_diff.rs:262`).
        block: Block,
        /// One grapheme cluster (`text_diff.rs:263`).
        grapheme: []const u8,

        /// `BlockOrGrapheme::width` (`text_diff.rs:267-272`): a block is one
        /// position, text is as wide as the document's encoding makes it.
        pub fn width(self: @This(), encoding: TextEncoding) usize {
            return switch (self) {
                .block => 1,
                .grapheme => |g| encoding.width(g),
            };
        }

        /// Upstream's derived `PartialEq` (`text_diff.rs:260`). A block never
        /// equals a grapheme.
        pub fn eql(a: @This(), b: @This()) bool {
            return switch (a) {
                .block => |x| switch (b) {
                    .block => |y| Block.eql(x, y),
                    .grapheme => false,
                },
                .grapheme => |x| switch (b) {
                    .block => false,
                    .grapheme => |y| std.mem.eql(u8, x, y),
                },
            };
        }
    };
}

/// One span of a text object, projected onto what a block diff compares: a
/// block, or a run of text (`iter::Span`, `text_diff.rs:475-488`).
///
/// The marks a `Text` span carries (`text_diff.rs:181`) are not here, because
/// the diff drops them (`text_diff.rs:478-485`); they are the subject of the
/// mark pass, which is **not** in this module. See [`myersBlockDiff`] for
/// where a consumer runs it.
pub fn BlockOrText(comptime Block: type) type {
    return union(enum) {
        /// `Span::Block` (`text_diff.rs:479`).
        block: Block,
        /// The text of a `Span::Text` (`text_diff.rs:480-485`).
        text: []const u8,
    };
}

/// `span_as_grapheme` (`text_diff.rs:475-488`): expands spans into blocks and
/// grapheme clusters, which is the new side of a block diff.
///
/// The returned list owns its array, not its payloads. Graphemes are subslices
/// of the input text; block entries copy the `Block` descriptor without
/// duplicating its map or other referenced payloads. Keep all source payloads
/// live and unchanged while reading the list, then deinit its array with `gpa`.
pub fn spanAsGrapheme(
    gpa: Allocator,
    comptime Block: type,
    comptime Span: type,
    spans: []const Span,
) err.Error!std.ArrayList(BlockOrGrapheme(Block)) {
    var out: std.ArrayList(BlockOrGrapheme(Block)) = .empty;
    errdefer out.deinit(gpa);
    for (spans) |span| switch (span) {
        .block => |b| try out.append(gpa, .{ .block = b }),
        .text => |text| {
            const gs = try graphemes(gpa, text);
            defer gpa.free(gs);
            for (gs) |g| try out.append(gpa, .{ .grapheme = g });
        },
    };
    return out;
}

/// The hook `myers_diff` drives (`text_diff.rs:46-134`): it turns the diff
/// events into splices on a text object, tracking the position in the
/// document's own encoding as it goes.
///
/// It reaches the document through `Sink`, which carries the operations
/// upstream splits between `&mut Automerge` and `&mut TransactionInner`
/// (`text_diff.rs:47-48`). This port's transaction owns its document and its
/// patch log, so one pointer carries both. `Sink` must
/// provide:
///
/// | method | upstream |
/// | --- | --- |
/// | `textFor(obj) ![]const u8` | `doc.text_for` (`text_diff.rs:22`) |
/// | `textEncoding() TextEncoding` | `doc.text_encoding` (`text_diff.rs:26`) |
/// | `spliceText(obj, index, del, insert) !void` | `tx.splice_text` (`text_diff.rs:85-92`) |
///
/// **What a `Sink` owes this hook, all four obligations in one place.**
///
/// | | |
/// |---|---|
/// | **arguments** | `obj` is the object every call in one run names; `index` and `del` are in the object's own encoding, the one `textEncoding()` reports; `insert` is the text to add, already counted in that encoding. |
/// | **validity window** | the slice `textFor` returns stays valid for the whole of [`myersDiff`], not for one call — the grapheme array is cut from it — and **the `insert` slice dies when `spliceText` returns.** [`TxHook.insert`] and [`TxHook.replace`] build it with `gpa` and free it in the same statement, and [`BlockDiffHook.insert`] passes a buffer it frees on return, so a sink that queues the slice for later reads freed memory. Copy it if it has to outlive the call. |
/// | **thread** | every method is called on the thread that called [`myersDiff`] or [`myersBlockDiff`], inside that call, before it returns. Nothing here hops threads and no callback is deferred. |
/// | **reentry** | the callee may call back into the hook or the sink, but not into the diff currently running: the hook's `idx` is a running position and a second walk over the same object would interleave splices at the wrong offsets. Reentering the *sink's own* document with a different object is what a sink that dispatches on `obj` already does. |
///
/// The two slice obligations are the ones a caller gets wrong: `textFor`'s
/// result is read long after the call that produced it, and `insert`'s is dead
/// the moment the call returns.
pub fn TxHook(comptime Sink: type) type {
    return struct {
        const Self = @This();

        sink: *Sink,
        /// The old text, as graphemes (`text_diff.rs:50`).
        old: []const []const u8,
        /// The new text, as graphemes (`text_diff.rs:51`).
        new: []const []const u8,
        /// The text object being updated (`text_diff.rs:52`).
        obj: ExId,
        /// The position in the text object, in the document's encoding, that
        /// the next splice addresses (`text_diff.rs:53`).
        idx: usize,
        /// The document's text encoding, read once (`text_diff.rs:54`, `:26`).
        encoding: TextEncoding,
        /// Upstream concatenates the new graphemes with `String::concat`
        /// (`text_diff.rs:80`, `:128`), which allocates; the port takes the
        /// allocator from its caller.
        gpa: Allocator,

        /// `TxHook::equal` (`text_diff.rs:60-71`): advance past text that did
        /// not change, counting in the document's encoding.
        pub fn equal(self: *Self, old_index: usize, _: usize, len: usize) err.Error!void {
            for (self.old[old_index..][0..len]) |c| self.idx += self.encoding.width(c);
        }

        /// `TxHook::delete` (`text_diff.rs:101-120`): one splice that removes
        /// the deleted graphemes, leaving `idx` where it was.
        pub fn delete(self: *Self, old_index: usize, old_len: usize, _: usize) err.Error!void {
            const deleted = self.widthOf(self.old[old_index..][0..old_len]);
            try self.sink.spliceText(self.obj, self.idx, @intCast(deleted), "");
        }

        /// `TxHook::insert` (`text_diff.rs:122-133`): one splice that adds the
        /// new graphemes at the current position.
        pub fn insert(self: *Self, _: usize, new_index: usize, new_len: usize) err.Error!void {
            const new_chars = try self.join(self.new[new_index..][0..new_len]);
            defer self.gpa.free(new_chars);
            try self.sink.spliceText(self.obj, self.idx, 0, new_chars);
            self.idx += self.encoding.width(new_chars);
        }

        /// `TxHook::replace` (`text_diff.rs:73-95`): one splice that swaps the
        /// deleted graphemes for the new ones.
        pub fn replace(self: *Self, old_index: usize, old_len: usize, new_index: usize, new_len: usize) err.Error!void {
            const new_chars = try self.join(self.new[new_index..][0..new_len]);
            defer self.gpa.free(new_chars);
            const deleted = self.widthOf(self.old[old_index..][0..old_len]);
            try self.sink.spliceText(self.obj, self.idx, @intCast(deleted), new_chars);
            self.idx += self.encoding.width(new_chars);
        }

        /// `TxHook::finish` (`text_diff.rs:97-99`): nothing.
        pub fn finish(_: *Self) err.Error!void {}

        /// `self.text_encoding.width(..).sum()` over a run of graphemes
        /// (`text_diff.rs:66-69`, `:81-84`, `:107-110`).
        fn widthOf(self: *const Self, items: []const []const u8) usize {
            var total: usize = 0;
            for (items) |g| total += self.encoding.width(g);
            return total;
        }

        /// `[..].concat()` (`text_diff.rs:80`, `:128`).
        fn join(self: *const Self, items: []const []const u8) err.Error![]u8 {
            return std.mem.concat(self.gpa, u8, items);
        }
    };
}

/// `myers_diff` (`text_diff.rs:15-44`): make a text object hold `new_text`.
///
/// The old text is read at the transaction's scope, both sides are split into
/// grapheme clusters, and the raw hook is driven with no `Replace`, because a
/// text diff splices each event on its own (`text_diff.rs:37-43`).
pub fn myersDiff(
    gpa: Allocator,
    comptime Sink: type,
    sink: *Sink,
    obj: ExId,
    new_text: []const u8,
) err.Error!void {
    const old_text = try sink.textFor(obj);
    const old = try graphemes(gpa, old_text);
    defer gpa.free(old);
    const new = try graphemes(gpa, new_text);
    defer gpa.free(new);

    var hook: TxHook(Sink) = .{
        .sink = sink,
        .old = old,
        .new = new,
        .obj = obj,
        .idx = 0,
        .encoding = sink.textEncoding(),
        .gpa = gpa,
    };
    try diff(gpa, []const u8, graphemeEql, &hook, old, .{
        .start = 0,
        .end = old.len,
    }, new, .{
        .start = 0,
        .end = new.len,
    });
}

/// `split_block` (`text_diff.rs:490-500`): cut a block out of the text at
/// `index` and give it the contents of `block`.
pub fn splitBlock(
    comptime Sink: type,
    comptime Block: type,
    sink: *Sink,
    obj: ExId,
    index: usize,
    block: Block,
) err.Error!void {
    const new_block = try sink.splitBlock(obj, index);
    try sink.updateMap(new_block, block);
}

/// `update_block` (`text_diff.rs:502-515`): give the block at `index` the
/// contents of `new_block`. A position that does not hold a map object is
/// `error.InvalidIndex`, the variant upstream returns
/// (`text_diff.rs:511`).
pub fn updateBlock(
    comptime Sink: type,
    comptime Block: type,
    sink: *Sink,
    obj: ExId,
    index: usize,
    new_block: Block,
) err.Error!void {
    const block_id = (try sink.blockAt(obj, index)) orelse return error.InvalidIndex;
    try sink.updateMap(block_id, new_block);
}

/// The hook `myers_block_diff` drives (`text_diff.rs:275-444`), wrapped in
/// `Replace` so that an adjacent delete and insert arrive as one `replace`
/// event (`text_diff.rs:150-159`).
///
/// It reaches the document through `Sink`, as `TxHook` does, and needs three
/// operations more: `blockAt(obj, index) ExId!?ExId`, which is the
/// `doc.get(obj, index)` `update_block` needs to find the block it updates
/// (`text_diff.rs:510-512`), plus `joinBlock` and `splitBlock`
/// (`text_diff.rs:299-300`, `:498`).
pub fn BlockDiffHook(comptime Sink: type, comptime Block: type) type {
    return struct {
        const Self = @This();
        /// One element of either side.
        pub const Item = BlockOrGrapheme(Block);

        sink: *Sink,
        /// The current contents of the text object (`text_diff.rs:254`).
        old: []const Item,
        /// The contents the object should end up with (`text_diff.rs:255`).
        new: []const Item,
        /// The text object being updated (`text_diff.rs:256`).
        obj: ExId,
        /// The position in the text object that the next operation addresses
        /// (`text_diff.rs:257`).
        idx: usize,
        /// Upstream accumulates a run of text in a `String`
        /// (`text_diff.rs:318`); the port takes the allocator from its caller.
        gpa: Allocator,

        /// `BlockDiffHook::equal` (`text_diff.rs:278-288`): advance past
        /// unchanged elements, a block counting as one position.
        pub fn equal(self: *Self, old_index: usize, _: usize, len: usize) err.Error!void {
            const encoding = self.sink.textEncoding();
            for (self.old[old_index..][0..len]) |item| self.idx += item.width(encoding);
        }

        /// `BlockDiffHook::delete` (`text_diff.rs:290-309`): a block is joined
        /// back into the text around it, a grapheme is deleted.
        pub fn delete(self: *Self, old_index: usize, old_len: usize, _: usize) err.Error!void {
            for (self.old[old_index..][0..old_len]) |item| switch (item) {
                .block => try self.sink.joinBlock(self.obj, self.idx),
                .grapheme => try self.sink.delete(self.obj, self.idx),
            };
        }

        /// `BlockDiffHook::insert` (`text_diff.rs:311-348`): accumulate runs
        /// of text and insert them, but insert each block as it comes, flushing
        /// the run before every block so a block never lands inside a run.
        pub fn insert(self: *Self, _: usize, new_index: usize, new_len: usize) err.Error!void {
            var run: std.ArrayList(u8) = .empty;
            defer run.deinit(self.gpa);
            for (self.new[new_index..][0..new_len]) |item| switch (item) {
                .block => |b| {
                    if (run.items.len != 0) {
                        try self.sink.spliceText(self.obj, self.idx, 0, run.items);
                        self.idx += self.sink.textEncoding().width(run.items);
                        run.clearRetainingCapacity();
                    }
                    try splitBlock(Sink, Block, self.sink, self.obj, self.idx, b);
                    self.idx += 1;
                },
                .grapheme => |g| try run.appendSlice(self.gpa, g),
            };
            if (run.items.len != 0) {
                try self.sink.spliceText(self.obj, self.idx, 0, run.items);
                self.idx += self.sink.textEncoding().width(run.items);
            }
        }

        /// `BlockDiffHook::replace` (`text_diff.rs:350-439`): walk the old and
        /// new elements together and dispatch on the pair.
        pub fn replace(self: *Self, old_index: usize, old_len: usize, new_index: usize, new_len: usize) err.Error!void {
            const encoding = self.sink.textEncoding();
            var old_idx = old_index;
            var new_idx = new_index;
            // The loop condition makes `(null, null)` unreachable, so the `?`
            // below is proved rather than hoped for.
            while (old_idx < old_index + old_len or new_idx < new_index + new_len) {
                const old_item: ?Item = if (old_idx < old_index + old_len) self.old[old_idx] else null;
                const new_item: ?Item = if (new_idx < new_index + new_len) self.new[new_idx] else null;

                if (old_item == null) {
                    // Only the new side has anything left
                    // (`text_diff.rs:374-386`).
                    switch (new_item.?) {
                        .block => |b| {
                            try splitBlock(Sink, Block, self.sink, self.obj, self.idx, b);
                            self.idx += 1;
                        },
                        .grapheme => |g| {
                            try self.sink.spliceText(self.obj, self.idx, 0, g);
                            self.idx += encoding.width(g);
                        },
                    }
                    new_idx += 1;
                } else if (new_item == null) {
                    // Only the old side has anything left
                    // (`text_diff.rs:387-398`).
                    switch (old_item.?) {
                        .block => try self.sink.joinBlock(self.obj, self.idx),
                        .grapheme => try self.sink.delete(self.obj, self.idx),
                    }
                    old_idx += 1;
                } else {
                    // The pair of elements the two sides are looking at
                    // (`text_diff.rs:361-371`). Zig cannot switch on two
                    // unions at once, so the four combinations are a switch
                    // on the old element with a switch on the new inside it
                    // (`text_diff.rs:399-434`).
                    switch (old_item.?) {
                        .block => |b1| switch (new_item.?) {
                            // Two blocks: update in place, and only when the
                            // contents differ (`text_diff.rs:400-407`).
                            .block => |b2| {
                                if (!Block.eql(b1, b2)) {
                                    try updateBlock(Sink, Block, self.sink, self.obj, self.idx, b2);
                                }
                                self.idx += 1;
                                old_idx += 1;
                                new_idx += 1;
                            },
                            // A block becoming text: join the block, then
                            // splice (`text_diff.rs:417-425`).
                            .grapheme => |g| {
                                try self.sink.joinBlock(self.obj, self.idx);
                                try self.sink.spliceText(self.obj, self.idx, 0, g);
                                self.idx += encoding.width(g);
                                old_idx += 1;
                                new_idx += 1;
                            },
                        },
                        .grapheme => switch (new_item.?) {
                            // Two graphemes: delete, then insert
                            // (`text_diff.rs:408-416`).
                            .grapheme => |g| {
                                try self.sink.delete(self.obj, self.idx);
                                try self.sink.spliceText(self.obj, self.idx, 0, g);
                                self.idx += encoding.width(g);
                                old_idx += 1;
                                new_idx += 1;
                            },
                            // Text becoming a block: delete, then split
                            // (`text_diff.rs:426-433`).
                            .block => |b| {
                                try self.sink.delete(self.obj, self.idx);
                                try splitBlock(Sink, Block, self.sink, self.obj, self.idx, b);
                                self.idx += 1;
                                old_idx += 1;
                                new_idx += 1;
                            },
                        },
                    }
                }
            }
        }

        /// `BlockDiffHook::finish` (`text_diff.rs:441-443`): nothing.
        pub fn finish(_: *Self) err.Error!void {}
    };
}

/// `myers_block_diff` (`text_diff.rs:136-163`), first pass: bring a text
/// object in line with `new_spans`, one block or grapheme at a time.
///
/// `old` is the object's current contents as blocks and grapheme clusters,
/// which is `spans_as_grapheme` (`text_diff.rs:446-473`) reading the object
/// through `iter::SpansInternal`; that walk is the caller's, because it needs
/// the `iter` types this module does not own. `new_spans` is the target, and
/// this function expands it (`text_diff.rs:147`).
///
/// `old` and `new_spans` are **borrowed for the whole call and for everything
/// it emits**: the hook's events hand `old`'s graphemes straight to the sink,
/// and the new side is expanded from `new_spans` into graphemes that borrow the
/// spans' own text, so both must outlive this call.
///
/// **The mark pass is not here.** Upstream runs a second pass over the marks
/// after this one (`apply_marks_diff`, `text_diff.rs:165-248`), and this module
/// does not publish it — it needs the `marks` and `iter` types this module does
/// not own. The held transaction's `updateSpansWithConfig` runs this first
/// pass and then applies the mark diff. The automatic owner delegates to
/// that same transaction, so callers never sequence the two passes manually.
pub fn myersBlockDiff(
    gpa: Allocator,
    comptime Sink: type,
    comptime Block: type,
    sink: *Sink,
    obj: ExId,
    old: []const BlockOrGrapheme(Block),
    new_spans: []const BlockOrText(Block),
) err.Error!void {
    const Item = BlockOrGrapheme(Block);
    var new = try spanAsGrapheme(gpa, Block, BlockOrText(Block), new_spans);
    defer new.deinit(gpa);

    var hook: Replace(BlockDiffHook(Sink, Block)) = .{ .d = .{
        .sink = sink,
        .old = old,
        .new = new.items,
        .obj = obj,
        .idx = 0,
        .gpa = gpa,
    } };
    try diff(gpa, Item, Item.eql, &hook, old, .{
        .start = 0,
        .end = old.len,
    }, new.items, .{
        .start = 0,
        .end = new.items.len,
    });
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Element equality for the tests that treat one byte as one element.
fn byteEql(a: u8, b: u8) bool {
    return a == b;
}

/// Byte-wise comparison of two sequences of graphemes. Zig's `==` on slices
/// compares the slice header, not the bytes.
fn expectSameGraphemes(a: []const []const u8, b: []const []const u8) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expect(graphemeEql(x, y));
}

/// What a diff did, counted over its events: how many elements are unchanged,
/// how many old elements and how many new elements a change removes and adds,
/// and how many separate runs of changes there are. These are the properties
/// the enumeration of cases below is really about, so they are what the tests
/// assert; which events the recursion happens to emit is not.
const Coverage = struct {
    equal: usize,
    old_changed: usize,
    new_changed: usize,
    /// A run is a maximal group of consecutive non-equal events, so a delete
    /// followed by an insert counts as one run.
    runs: usize,
};

fn coverage(rec: *const Recorder) Coverage {
    var out: Coverage = .{ .equal = 0, .old_changed = 0, .new_changed = 0, .runs = 0 };
    var in_run = false;
    for (rec.events.items) |ev| switch (ev) {
        .equal => |e| {
            out.equal += e.len;
            in_run = false;
        },
        .delete => |e| {
            out.old_changed += e.old_len;
            if (!in_run) {
                out.runs += 1;
                in_run = true;
            }
        },
        .insert => |e| {
            out.new_changed += e.new_len;
            if (!in_run) {
                out.runs += 1;
                in_run = true;
            }
        },
        .replace => |e| {
            out.old_changed += e.old_len;
            out.new_changed += e.new_len;
            if (!in_run) {
                out.runs += 1;
                in_run = true;
            }
        },
    };
    return out;
}

/// One recorded hook event, and the arguments it carried.
const Event = union(enum) {
    equal: struct { old_index: usize, new_index: usize, len: usize },
    delete: struct { old_index: usize, old_len: usize, new_index: usize },
    insert: struct { old_index: usize, new_index: usize, new_len: usize },
    replace: struct { old_index: usize, old_len: usize, new_index: usize, new_len: usize },
};

/// A hook that records the diff instead of applying it, and checks the
/// contract the diff owes its caller as it goes: every event continues where
/// the last one stopped, in both sequences
/// (`text_diff/replace.rs:98-103`, `:114-117`).
const Recorder = struct {
    gpa: Allocator,
    /// The old sequence, as elements.
    old: []const []const u8,
    /// The new sequence, as elements.
    new: []const []const u8,
    events: std.ArrayList(Event) = .empty,
    /// The position the next event addresses in the old sequence.
    consumed: usize = 0,
    /// The position the next event addresses in the new sequence.
    produced: usize = 0,
    finished: bool = false,

    fn deinit(self: *Recorder) void {
        self.events.deinit(self.gpa);
    }

    fn equal(self: *Recorder, old_index: usize, new_index: usize, len: usize) !void {
        try testing.expectEqual(self.consumed, old_index);
        try testing.expectEqual(self.produced, new_index);
        try expectSameGraphemes(
            self.old[old_index..][0..len],
            self.new[new_index..][0..len],
        );
        try self.events.append(self.gpa, .{ .equal = .{
            .old_index = old_index,
            .new_index = new_index,
            .len = len,
        } });
        self.consumed += len;
        self.produced += len;
    }

    fn delete(self: *Recorder, old_index: usize, old_len: usize, new_index: usize) !void {
        try testing.expectEqual(self.consumed, old_index);
        try testing.expectEqual(self.produced, new_index);
        try self.events.append(self.gpa, .{ .delete = .{
            .old_index = old_index,
            .old_len = old_len,
            .new_index = new_index,
        } });
        self.consumed += old_len;
    }

    fn insert(self: *Recorder, old_index: usize, new_index: usize, new_len: usize) !void {
        try testing.expectEqual(self.consumed, old_index);
        try testing.expectEqual(self.produced, new_index);
        try self.events.append(self.gpa, .{ .insert = .{
            .old_index = old_index,
            .new_index = new_index,
            .new_len = new_len,
        } });
        self.produced += new_len;
    }

    fn replace(self: *Recorder, old_index: usize, old_len: usize, new_index: usize, new_len: usize) !void {
        try testing.expectEqual(self.consumed, old_index);
        try testing.expectEqual(self.produced, new_index);
        try self.events.append(self.gpa, .{ .replace = .{
            .old_index = old_index,
            .old_len = old_len,
            .new_index = new_index,
            .new_len = new_len,
        } });
        self.consumed += old_len;
        self.produced += new_len;
    }

    fn finish(self: *Recorder) !void {
        // Every element of both sequences is accounted for by some event.
        try testing.expectEqual(self.old.len, self.consumed);
        try testing.expectEqual(self.new.len, self.produced);
        self.finished = true;
    }

    /// The property the diff owes its caller: walking the events in order and
    /// taking the new side of each one rebuilds the new sequence exactly, while
    /// the old-side indices consume the old sequence exactly once.
    fn checkTransform(self: *Recorder) !void {
        try testing.expect(self.finished);
        var out: std.ArrayList([]const u8) = .empty;
        defer out.deinit(self.gpa);
        var old_pos: usize = 0;
        for (self.events.items) |ev| switch (ev) {
            .equal => |e| {
                try testing.expectEqual(old_pos, e.old_index);
                try out.appendSlice(self.gpa, self.new[e.new_index..][0..e.len]);
                old_pos += e.len;
            },
            .delete => |e| {
                try testing.expectEqual(old_pos, e.old_index);
                old_pos += e.old_len;
            },
            .insert => |e| try out.appendSlice(self.gpa, self.new[e.new_index..][0..e.new_len]),
            .replace => |e| {
                try testing.expectEqual(old_pos, e.old_index);
                try out.appendSlice(self.gpa, self.new[e.new_index..][0..e.new_len]);
                old_pos += e.old_len;
            },
        };
        try testing.expectEqual(self.old.len, old_pos);
        try expectSameGraphemes(self.new, out.items);
    }
};

/// A hook that only records. It does not check the diff's index contract, so
/// `Replace` can be driven by hand with a stream that is not a diff's output.
const Tally = struct {
    gpa: Allocator,
    events: std.ArrayList(Event) = .empty,

    fn deinit(self: *Tally) void {
        self.events.deinit(self.gpa);
    }

    fn equal(self: *Tally, old_index: usize, new_index: usize, len: usize) !void {
        try self.events.append(self.gpa, .{ .equal = .{
            .old_index = old_index,
            .new_index = new_index,
            .len = len,
        } });
    }

    fn delete(self: *Tally, old_index: usize, old_len: usize, new_index: usize) !void {
        try self.events.append(self.gpa, .{ .delete = .{
            .old_index = old_index,
            .old_len = old_len,
            .new_index = new_index,
        } });
    }

    fn insert(self: *Tally, old_index: usize, new_index: usize, new_len: usize) !void {
        try self.events.append(self.gpa, .{ .insert = .{
            .old_index = old_index,
            .new_index = new_index,
            .new_len = new_len,
        } });
    }

    fn replace(self: *Tally, old_index: usize, old_len: usize, new_index: usize, new_len: usize) !void {
        try self.events.append(self.gpa, .{ .replace = .{
            .old_index = old_index,
            .old_len = old_len,
            .new_index = new_index,
            .new_len = new_len,
        } });
    }

    fn finish(_: *Tally) !void {}
};

/// Runs a diff of `old_text` against `new_text` and checks the transform
/// property. With `merge`, the events pass through `Replace` first.
fn expectTransform(comptime merge: bool, old_text: []const u8, new_text: []const u8) !Recorder {
    const gpa = testing.allocator;
    const old = try graphemes(gpa, old_text);
    defer gpa.free(old);
    const new = try graphemes(gpa, new_text);
    defer gpa.free(new);

    var rec: Recorder = .{ .gpa = gpa, .old = old, .new = new };
    if (merge) {
        var hook: Replace(Recorder) = .{ .d = rec };
        try diff(gpa, []const u8, graphemeEql, &hook, old, .{
            .start = 0,
            .end = old.len,
        }, new, .{
            .start = 0,
            .end = new.len,
        });
        rec = hook.d;
    } else {
        try diff(gpa, []const u8, graphemeEql, &rec, old, .{
            .start = 0,
            .end = old.len,
        }, new, .{
            .start = 0,
            .end = new.len,
        });
    }
    try rec.checkTransform();
    return rec;
}

test "diff of two empty sequences is empty" {
    var rec = try expectTransform(false, "", "");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 0), rec.events.items.len);
}

test "diff of an empty and a non-empty sequence is one insert or one delete" {
    var rec = try expectTransform(false, "", "abc");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try testing.expectEqual(@as(usize, 3), rec.events.items[0].insert.new_len);

    var other = try expectTransform(false, "abc", "");
    defer other.deinit();
    try testing.expectEqual(@as(usize, 1), other.events.items.len);
    try testing.expectEqual(@as(usize, 3), other.events.items[0].delete.old_len);
}

test "diff of identical sequences is all equal" {
    var rec = try expectTransform(false, "the quick brown fox", "the quick brown fox");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try testing.expectEqual(@as(usize, 19), rec.events.items[0].equal.len);
}

test "a one-element insertion is one insert" {
    // "abXcd" is "ab" and "cd" with one element between them, and both common
    // runs are stripped before the search runs
    // (`text_diff/myers.rs:271-286`), so the middle is an insertion with no
    // deletion in it at all: one event, not a merged pair.
    var rec = try expectTransform(true, "abcd", "abXcd");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 3), rec.events.items.len);
    try testing.expectEqual(@as(usize, 2), rec.events.items[0].equal.len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[1].insert.new_len);
    try testing.expectEqual(@as(usize, 2), rec.events.items[1].insert.new_index);
    try testing.expectEqual(@as(usize, 2), rec.events.items[1].insert.old_index);
    try testing.expectEqual(@as(usize, 2), rec.events.items[2].equal.len);
    try testing.expectEqual(@as(usize, 2), rec.events.items[2].equal.old_index);
}

test "a one-element deletion is one delete" {
    // The mirror of the case above: the middle is a deletion with nothing
    // inserted into it.
    var rec = try expectTransform(false, "abXcd", "abcd");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 3), rec.events.items.len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[1].delete.old_len);
    try testing.expectEqual(@as(usize, 2), rec.events.items[1].delete.old_index);
    try testing.expectEqual(@as(usize, 4), coverage(&rec).equal);
}

test "replacing the whole sequence is one change over everything" {
    var rec = try expectTransform(true, "abcd", "wxyz");
    defer rec.deinit();
    const got = coverage(&rec);
    // No element is shared, so every element is in the one change.
    try testing.expectEqual(@as(usize, 0), got.equal);
    try testing.expectEqual(@as(usize, 4), got.old_changed);
    try testing.expectEqual(@as(usize, 4), got.new_changed);
    try testing.expectEqual(@as(usize, 1), got.runs);
}

test "two disjoint changes are two separate changes" {
    var rec = try expectTransform(true, "one two three", "ONE two THREE");
    defer rec.deinit();
    const got = coverage(&rec);
    // The two changes are held apart by the run they share, so no script can
    // do it in one run of changes.
    try testing.expectEqual(@as(usize, 2), got.runs);
    try testing.expectEqual(@as(usize, 5), got.equal);
    try testing.expectEqual(@as(usize, 8), got.old_changed);
    try testing.expectEqual(@as(usize, 8), got.new_changed);
}

test "many interleaved changes each get their own event" {
    var rec = try expectTransform(true, "aaa bbb ccc ddd", "xxx yyy zzz www");
    defer rec.deinit();
    const got = coverage(&rec);
    // The four words share nothing, and the three spaces between them are the
    // only thing left equal.
    try testing.expectEqual(@as(usize, 4), got.runs);
    try testing.expectEqual(@as(usize, 3), got.equal);
    try testing.expectEqual(@as(usize, 12), got.old_changed);
    try testing.expectEqual(@as(usize, 12), got.new_changed);
}

test "a common prefix and a common suffix both survive" {
    var rec = try expectTransform(true, "keep-before-X-keep-after", "keep-before-Y-keep-after");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 3), rec.events.items.len);
    // The prefix equal is emitted before the search and the suffix equal after
    // it (`text_diff/myers.rs:272-274`, `:314-316`), so they are the first and
    // last events whatever the middle does. The prefix is "keep-before-" and
    // the suffix is "-keep-after": both share them, which is why the X and
    // the Y are the only elements between the two runs.
    try testing.expectEqual(@as(usize, 12), rec.events.items[0].equal.len);
    try testing.expectEqual(@as(usize, 0), rec.events.items[0].equal.old_index);
    try testing.expectEqual(@as(usize, 11), rec.events.items[2].equal.len);
    try testing.expectEqual(@as(usize, 13), rec.events.items[2].equal.old_index);
    try testing.expectEqual(@as(usize, 1), rec.events.items[1].replace.old_len);
}

test "a combining sequence is one cluster, so a change inside it is one change" {
    const gpa = testing.allocator;
    // "e" plus a combining acute is one cluster of three bytes, then "f".
    const g = try graphemes(gpa, "e\u{0301}f");
    defer gpa.free(g);
    try testing.expectEqual(@as(usize, 2), g.len);
    try testing.expectEqualStrings("e\u{0301}", g[0]);
    try testing.expectEqualStrings("f", g[1]);
    const h = try graphemes(gpa, "e\u{0300}f");
    defer gpa.free(h);
    try testing.expectEqual(@as(usize, 2), h.len);
    try testing.expectEqualStrings("e\u{0300}", h[0]);

    // The cluster's mark changes from an acute to a grave. A byte diff would
    // report the two bytes of one mark leaving and two of another arriving; the
    // answer the caller needs is that one element is replaced by one element,
    // with the "f" after it untouched.
    var rec = try expectTransform(true, "e\u{0301}f", "e\u{0300}f");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 2), rec.events.items.len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[0].replace.old_len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[0].replace.new_len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[1].equal.len);
}

test "a zero width joiner sequence is one cluster" {
    // A woman, a ZWJ, another woman: one cluster by GB11.
    const g = try graphemes(testing.allocator, "\u{1f469}\u{200d}\u{1f469}");
    defer testing.allocator.free(g);
    try testing.expectEqual(@as(usize, 1), g.len);

    // Dropping the joiner turns the one cluster into two, so the diff replaces
    // one element with two. A byte diff would have inserted the three bytes of
    // the joiner and a woman as three separate changes.
    var rec = try expectTransform(true, "\u{1f469}\u{200d}\u{1f469}", "\u{1f469}\u{1f469}");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[0].replace.old_len);
    try testing.expectEqual(@as(usize, 2), rec.events.items[0].replace.new_len);
}

test "a change inside a cluster is one change" {
    // Two regional indicators are one flag by GB12, so these are one cluster
    // each and the change is a change of the whole cluster.
    const g = try graphemes(testing.allocator, "\u{1f1e6}\u{1f1e7}");
    defer testing.allocator.free(g);
    try testing.expectEqual(@as(usize, 1), g.len);

    var rec = try expectTransform(true, "\u{1f1e6}\u{1f1e7}", "\u{1f1e6}\u{1f1e8}");
    defer rec.deinit();
    try testing.expectEqual(@as(usize, 1), rec.events.items.len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[0].replace.old_len);
    try testing.expectEqual(@as(usize, 1), rec.events.items[0].replace.new_len);
}

test "the transform property holds for random pairs" {
    // The property is the one the enumeration above illustrates, over pairs
    // nobody wrote down. The alphabet holds clusters of one, two and three
    // code points, so a byte diff would fail most of these rounds.
    const gpa = testing.allocator;
    const alphabet = [_][]const u8{
        "a",
        "b",
        "c",
        "e\u{0301}",
        "\u{1f469}\u{200d}\u{1f469}",
        "\u{1f1e6}\u{1f1e7}",
    };
    var prng: std.Random.DefaultPrng = .init(0x5EED_1234);
    const rand = prng.random();
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var old_text: std.ArrayList(u8) = .empty;
        defer old_text.deinit(gpa);
        var new_text: std.ArrayList(u8) = .empty;
        defer new_text.deinit(gpa);
        for (0..rand.intRangeAtMost(usize, 0, 8)) |_| {
            try old_text.appendSlice(gpa, alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)]);
        }
        for (0..rand.intRangeAtMost(usize, 0, 8)) |_| {
            try new_text.appendSlice(gpa, alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)]);
        }
        // Both the raw stream and the merged one, because the decorator is
        // what the block diff runs and the raw stream is what the text diff
        // runs (`text_diff.rs:37-43`, `:150-159`).
        var rec = try expectTransform(false, old_text.items, new_text.items);
        defer rec.deinit();
        var merged = try expectTransform(true, old_text.items, new_text.items);
        defer merged.deinit();
    }
}

test "segmentation agrees with the port's grapheme count" {
    // `graphemes` places its boundaries through
    // `unicode.GraphemeBoundaryIter` (`unicode.zig`) and
    // `unicode.countGraphemes` counts them by its own left-to-right pass, so
    // the two are two implementations of the UAX #29 rules and they have to
    // agree on how many clusters a string has, and the clusters have to tile
    // the string exactly. If they disagree, a document whose encoding is
    // `grapheme_cluster` counts positions one way and the diff walks them
    // another.
    const gpa = testing.allocator;
    const cases = [_][]const u8{
        "",
        "a",
        "e\u{0301}f",
        "\u{1f1e6}\u{1f1e7}\u{1f1e8}",
        "\u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}",
        "\u{1100}\u{1161}\u{11a8}",
        "a\r\nb",
        "\u{0600}a\u{0301}\u{200d}\u{1f469}",
        "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
    };
    for (cases) |text| {
        const gs = try graphemes(gpa, text);
        defer gpa.free(gs);
        try testing.expectEqual(try unicode.countGraphemes(text), gs.len);
        var tiled: usize = 0;
        for (gs) |g| tiled += g.len;
        try testing.expectEqual(text.len, tiled);
    }
}

/// The segmentation [`graphemes`] used to produce, kept as its oracle: a
/// cluster boundary falls at a code point position exactly when the number of
/// clusters in the prefix grows there, so one [`unicode.countGraphemes`] per
/// code point finds every one of them. It asks about **every prefix**, so it
/// walks `n²/2` code points, and `out` collects the slices it would have
/// returned.
fn byPerPrefixCount(
    gpa: Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) err.Error!void {
    var before: usize = 0;
    // Where the cluster being collected starts.
    var at: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidCharacter;
        if (i + len > text.len) return error.InvalidCharacter;
        const stop = i + len;
        const seen = unicode.countGraphemes(text[0..stop]) catch return error.InvalidCharacter;
        if (seen > before) {
            // A boundary falls before the code point at `i`. `i == at` is the
            // first code point, which opens the first cluster rather than
            // closing one.
            if (i > at) try out.append(gpa, text[at..i]);
            at = i;
            before = seen;
        }
        i = stop;
    }
    if (at < text.len) try out.append(gpa, text[at..]);
}

test "the single-pass segmentation is the per-prefix count it replaced" {
    // **The rewrite is a speedup, and a speedup with nothing to compare
    // against is a claim rather than a measurement.** [`byPerPrefixCount`] is
    // the implementation `graphemes` had before it became a single pass, so
    // the two are held to each other here, cluster for cluster.
    const gpa = testing.allocator;
    var cases: std.ArrayList([]const u8) = .empty;
    defer cases.deinit(gpa);
    for ([_][]const u8{
        "",
        "a",
        "e\u{0301}f",
        "\u{1f1e6}\u{1f1e7}\u{1f1e8}",
        "\u{1f469}\u{200d}\u{1f469}\u{200d}\u{1f467}",
        "\u{1100}\u{1161}\u{11a8}",
        "a\r\nb",
        "\u{0600}a\u{0301}\u{200d}\u{1f469}",
        "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
    }) |case| try cases.append(gpa, case);
    // **A long body as well, ASCII and one ZWJ sequence a line**, so the
    // comparison runs over 10 000 clusters and not over the handful of
    // characters above. The oracle is `O(n²)`, so this is sized to stay in the
    // tens of milliseconds; `unicode.zig` carries the 210 000-cluster one, the
    // length `tests/text.rs`:1125 splices.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..500) |_| try body.appendSlice(gpa, "the quick brown fox. 👩‍👩‍👧‍👦 ");
    try cases.append(gpa, body.items);

    for (cases.items) |text| {
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(gpa);
        try byPerPrefixCount(gpa, text, &want);
        const got = try graphemes(gpa, text);
        defer gpa.free(got);
        try testing.expectEqual(want.items.len, got.len);
        for (want.items, got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "the middle snake of two sequences is found" {
    // The reference case from upstream's own test
    // (`text_diff/myers.rs:321-332`).
    const gpa = testing.allocator;
    const a = "ABCABBA";
    const b = "CBABAC";
    var vf = try V.init(gpa, maxD(a.len, b.len));
    defer vf.deinit(gpa);
    var vb = try V.init(gpa, maxD(a.len, b.len));
    defer vb.deinit(gpa);
    const snake = findMiddleSnake(u8, byteEql, a, .{ .start = 0, .end = a.len }, b, .{
        .start = 0,
        .end = b.len,
    }, &vf, &vb).?;
    try testing.expectEqual(@as(usize, 4), snake.x);
    try testing.expectEqual(@as(usize, 1), snake.y);
}

test "the search bound is upstream's max_d" {
    try testing.expectEqual(@as(usize, 1), maxD(0, 0));
    try testing.expectEqual(@as(usize, 2), maxD(1, 1));
    try testing.expectEqual(@as(usize, 5), maxD(3, 4));
    try testing.expectEqual(@as(usize, 8), maxD(7, 6));
    // The sum is taken in a width that cannot wrap. `bit + bit` is the
    // first pair of lengths whose `usize` sum overflows, and the formula's
    // answer for it is `bit + 1`; no pair of live slices is that long, and
    // that is the whole reason the width is there.
    const bit = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    try testing.expectEqual(@as(usize, bit + 1), maxD(bit, bit));
    // And the one past it saturates rather than wrapping, because the
    // answer no longer fits `usize` either.
    try testing.expectEqual(std.math.maxInt(usize), maxD(std.math.maxInt(usize), std.math.maxInt(usize)));
}

test "two completely distinct sequences terminate" {
    // The case the vendored copy's own header warns about
    // (`text_diff/myers.rs:19-23`): two large disjoint inputs with nothing in
    // common. The bound holds, so this returns; the result is one change over
    // the whole pair.
    const gpa = testing.allocator;
    const n = 300;
    const old = try gpa.alloc([]const u8, n);
    defer gpa.free(old);
    const new = try gpa.alloc([]const u8, n);
    defer gpa.free(new);
    const a = try gpa.dupe(u8, "a");
    defer gpa.free(a);
    const b = try gpa.dupe(u8, "b");
    defer gpa.free(b);
    for (old) |*g| g.* = a;
    for (new) |*g| g.* = b;
    var rec: Recorder = .{ .gpa = gpa, .old = old, .new = new };
    defer rec.deinit();
    try diff(gpa, []const u8, graphemeEql, &rec, old, .{ .start = 0, .end = old.len }, new, .{
        .start = 0,
        .end = new.len,
    });
    try rec.checkTransform();
    const got = coverage(&rec);
    try testing.expectEqual(@as(usize, 0), got.equal);
    try testing.expectEqual(@as(usize, n), got.old_changed);
    try testing.expectEqual(@as(usize, n), got.new_changed);
}

test "common prefix and suffix at their boundaries" {
    // `test_common_prefix_len` and `test_common_suffix_len`
    // (`text_diff/utils.rs:82-99`, `:102-119`), one element per byte as
    // upstream's byte slices do.
    const foobarbaz = "foobarbaz";
    const foobarblah = "foobarblah";
    const blablabla = "blablabla";
    const digits = "1234";
    const xdigits = "X0001234";
    const xxxx = "Xxxx";
    const zero1234 = "01234";

    try testing.expectEqual(
        @as(usize, 0),
        commonPrefixLen(u8, byteEql, "", .{ .start = 0, .end = 0 }, "", .{ .start = 0, .end = 0 }),
    );
    try testing.expectEqual(
        @as(usize, 7),
        commonPrefixLen(u8, byteEql, foobarbaz, .{ .start = 0, .end = 9 }, foobarblah, .{ .start = 0, .end = 10 }),
    );
    try testing.expectEqual(
        @as(usize, 0),
        commonPrefixLen(u8, byteEql, foobarbaz, .{ .start = 0, .end = 9 }, blablabla, .{ .start = 0, .end = 9 }),
    );
    try testing.expectEqual(
        @as(usize, 4),
        commonPrefixLen(u8, byteEql, foobarbaz, .{ .start = 3, .end = 9 }, foobarblah, .{ .start = 3, .end = 10 }),
    );
    // An inverted range is empty, so it has no common prefix at all.
    try testing.expectEqual(
        @as(usize, 0),
        commonPrefixLen(u8, byteEql, foobarbaz, .{ .start = 9, .end = 3 }, foobarblah, .{ .start = 0, .end = 10 }),
    );

    try testing.expectEqual(
        @as(usize, 0),
        commonSuffixLen(u8, byteEql, "", .{ .start = 0, .end = 0 }, "", .{ .start = 0, .end = 0 }),
    );
    try testing.expectEqual(
        @as(usize, 4),
        commonSuffixLen(u8, byteEql, digits, .{ .start = 0, .end = 4 }, xdigits, .{ .start = 0, .end = 8 }),
    );
    try testing.expectEqual(
        @as(usize, 0),
        commonSuffixLen(u8, byteEql, digits, .{ .start = 0, .end = 4 }, xxxx, .{ .start = 0, .end = 4 }),
    );
    try testing.expectEqual(
        @as(usize, 2),
        commonSuffixLen(u8, byteEql, digits, .{ .start = 2, .end = 4 }, zero1234, .{ .start = 2, .end = 5 }),
    );
    try testing.expectEqual(
        @as(usize, 0),
        commonSuffixLen(u8, byteEql, digits, .{ .start = 4, .end = 0 }, xdigits, .{ .start = 0, .end = 8 }),
    );
}

test "Replace merges an adjacent delete and insert into one replace" {
    const gpa = testing.allocator;
    var tally: Tally = .{ .gpa = gpa };
    var hook: Replace(Tally) = .{ .d = tally };
    // Two deletes and two inserts in a row: the first delete merges with both
    // inserts, and the second delete has no insert to merge with.
    try hook.delete(0, 1, 0);
    try hook.delete(1, 2, 1);
    try hook.insert(3, 0, 1);
    try hook.insert(3, 1, 2);
    try hook.equal(3, 3, 1);
    try hook.delete(4, 1, 4);
    try hook.finish();
    tally = hook.d;
    defer tally.deinit();

    try testing.expectEqual(@as(usize, 3), tally.events.items.len);
    // The delete run starts at the first delete and spans both, and the
    // replace reports the insert run, not the delete's new index
    // (`text_diff/replace.rs:50-53`).
    try testing.expectEqual(@as(usize, 0), tally.events.items[0].replace.old_index);
    try testing.expectEqual(@as(usize, 3), tally.events.items[0].replace.old_len);
    try testing.expectEqual(@as(usize, 0), tally.events.items[0].replace.new_index);
    try testing.expectEqual(@as(usize, 3), tally.events.items[0].replace.new_len);
    // The equal run is buffered, and the equal run after it is emitted before
    // the second delete is (`text_diff/replace.rs:96`, `:97-102`).
    try testing.expectEqual(@as(usize, 1), tally.events.items[1].equal.len);
    try testing.expectEqual(@as(usize, 4), tally.events.items[2].delete.old_index);
    try testing.expectEqual(@as(usize, 1), tally.events.items[2].delete.old_len);
}

test "Replace passes a replace event straight through" {
    const gpa = testing.allocator;
    var tally: Tally = .{ .gpa = gpa };
    var hook: Replace(Tally) = .{ .d = tally };
    try hook.equal(0, 0, 1);
    try hook.replace(1, 1, 1, 1);
    try hook.finish();
    tally = hook.d;
    defer tally.deinit();
    try testing.expectEqual(@as(usize, 2), tally.events.items.len);
    try testing.expectEqual(@as(usize, 1), tally.events.items[1].replace.old_index);
    try testing.expectEqual(@as(usize, 1), tally.events.items[1].replace.new_len);
}

test "a block is one position and a grapheme is as wide as the encoding" {
    const Item = BlockOrGrapheme(TestBlock);
    const block: Item = .{ .block = .{ .bytes = "{}" } };
    const grapheme: Item = .{ .grapheme = "\u{1f469}" };
    try testing.expectEqual(@as(usize, 1), block.width(.utf8_code_unit));
    try testing.expectEqual(@as(usize, 4), grapheme.width(.utf8_code_unit));
    try testing.expectEqual(@as(usize, 2), grapheme.width(.utf16_code_unit));
    try testing.expectEqual(@as(usize, 1), grapheme.width(.grapheme_cluster));
    try testing.expect(Item.eql(block, .{ .block = .{ .bytes = "{}" } }));
    try testing.expect(!Item.eql(block, .{ .block = .{ .bytes = "[]" } }));
    try testing.expect(!Item.eql(block, grapheme));
    try testing.expect(Item.eql(grapheme, .{ .grapheme = "\u{1f469}" }));
}

/// The block payload of the hook tests: upstream's is a hydrated map
/// (`text_diff.rs:262`), and only its equality and its bytes are observable
/// here.
const TestBlock = struct {
    bytes: []const u8,

    pub fn eql(a: TestBlock, b: TestBlock) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

/// One call the hooks made on the sink, recorded in order. The bytes a call
/// carries are copied out of the argument, because `TxHook` frees the
/// concatenated graphemes as soon as the splice returns
/// (`text_diff.rs:80-93`).
const Call = union(enum) {
    splice: struct { index: usize, del: isize, insert: []const u8 },
    delete: usize,
    join_block: usize,
    split_block: struct { index: usize, id: ExId },
    update_map: struct { block: ExId, map: []const u8 },
};

/// A sink that records what it was asked to do instead of doing it. It is the
/// whole document side of both hooks, reduced to the calls they make.
const FakeSink = struct {
    gpa: Allocator,
    encoding: TextEncoding = .unicode_code_point,
    /// The text `textFor` reports (`text_diff.rs:22`).
    text: []const u8 = "",
    /// The block ids `blockAt` reports, one per position (`text_diff.rs:510`).
    blocks: []const ExId = &.{},
    calls: std.ArrayList(Call) = .empty,
    /// The id handed out by the next `splitBlock` (`text_diff.rs:498`).
    next_id: u32 = 1,

    fn deinit(self: *FakeSink) void {
        for (self.calls.items) |call| switch (call) {
            .splice => |s| self.gpa.free(s.insert),
            .update_map => |u| self.gpa.free(u.map),
            else => {},
        };
        self.calls.deinit(self.gpa);
    }

    pub fn textFor(self: *FakeSink, _: ExId) err.Error![]const u8 {
        return self.text;
    }

    pub fn textEncoding(self: *FakeSink) TextEncoding {
        return self.encoding;
    }

    pub fn spliceText(self: *FakeSink, _: ExId, index: usize, del: isize, insert: []const u8) err.Error!void {
        const owned = try self.gpa.dupe(u8, insert);
        errdefer self.gpa.free(owned);
        try self.calls.append(self.gpa, .{ .splice = .{
            .index = index,
            .del = del,
            .insert = owned,
        } });
    }

    pub fn delete(self: *FakeSink, _: ExId, index: usize) err.Error!void {
        try self.calls.append(self.gpa, .{ .delete = index });
    }

    pub fn joinBlock(self: *FakeSink, _: ExId, index: usize) err.Error!void {
        try self.calls.append(self.gpa, .{ .join_block = index });
    }

    pub fn splitBlock(self: *FakeSink, _: ExId, index: usize) err.Error!ExId {
        const id: ExId = .{ .id = .{ .counter = self.next_id, .actor = 0 } };
        self.next_id += 1;
        try self.calls.append(self.gpa, .{ .split_block = .{ .index = index, .id = id } });
        return id;
    }

    pub fn updateMap(self: *FakeSink, block: ExId, map: TestBlock) err.Error!void {
        const owned = try self.gpa.dupe(u8, map.bytes);
        errdefer self.gpa.free(owned);
        try self.calls.append(self.gpa, .{ .update_map = .{ .block = block, .map = owned } });
    }

    pub fn blockAt(self: *FakeSink, _: ExId, index: usize) err.Error!?ExId {
        if (index >= self.blocks.len) return null;
        return self.blocks[index];
    }
};

/// The object id every hook test works on.
const text_obj: ExId = .{ .id = .{ .counter = 7, .actor = 0 } };

/// Applies the recorded splices to `text` and returns the result. Splices are
/// byte offsets, so the sink must be in `utf8_code_unit` encoding.
fn applySplices(gpa: Allocator, text: []const u8, calls: []const Call) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text);
    for (calls) |call| switch (call) {
        .splice => |s| {
            try out.replaceRange(gpa, s.index, @intCast(@max(s.del, 0)), s.insert);
        },
        else => return error.TestUnexpectedCall,
    };
    return out.toOwnedSlice(gpa);
}

test "the text hook splices the new text in place" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .utf8_code_unit, .text = "hello world" };
    defer sink.deinit();
    try myersDiff(gpa, FakeSink, &sink, text_obj, "hello brave world");
    const got = try applySplices(gpa, sink.text, sink.calls.items);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello brave world", got);
}

test "the text hook measures the document's encoding, not bytes" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .utf16_code_unit, .text = "\u{1f469}a" };
    defer sink.deinit();
    // The change is one inserted cluster, so the whole diff is one splice. Its
    // index is the width of the two clusters before it in UTF-16 units: the
    // emoji is two, "a" is one. Counting code points would have spliced at 2.
    try myersDiff(gpa, FakeSink, &sink, text_obj, "\u{1f469}a\u{1f469}");
    try testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try testing.expectEqual(@as(usize, 3), sink.calls.items[0].splice.index);
    try testing.expectEqual(@as(isize, 0), sink.calls.items[0].splice.del);
    try testing.expectEqualStrings("\u{1f469}", sink.calls.items[0].splice.insert);
}

test "the text hook deletes a whole grapheme cluster" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .grapheme_cluster, .text = "e\u{0301}x" };
    defer sink.deinit();
    try myersDiff(gpa, FakeSink, &sink, text_obj, "x");
    try testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    // The whole two-byte cluster goes in one splice. It is one position under
    // this encoding, so the splice removes one unit at position 0; under
    // `utf8_code_unit` it would remove two, and a byte diff would have split
    // the two bytes across two changes.
    try testing.expectEqual(@as(usize, 0), sink.calls.items[0].splice.index);
    try testing.expectEqual(@as(isize, 1), sink.calls.items[0].splice.del);
}

test "spanAsGrapheme expands text into clusters and keeps blocks whole" {
    const gpa = testing.allocator;
    const spans = [_]BlockOrText(TestBlock){
        .{ .text = "e\u{0301}" },
        .{ .block = .{ .bytes = "{}" } },
        .{ .text = "z" },
    };
    var out = try spanAsGrapheme(gpa, TestBlock, BlockOrText(TestBlock), &spans);
    defer out.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("e\u{0301}", out.items[0].grapheme);
    try testing.expectEqualStrings("{}", out.items[1].block.bytes);
    try testing.expectEqualStrings("z", out.items[2].grapheme);
}

test "the block diff replaces one grapheme with another" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .utf8_code_unit, .text = "ab" };
    defer sink.deinit();
    const old = [_]BlockOrGrapheme(TestBlock){
        .{ .grapheme = "a" },
        .{ .grapheme = "b" },
    };
    const new_spans = [_]BlockOrText(TestBlock){
        .{ .text = "a" },
        .{ .text = "c" },
    };
    try myersBlockDiff(gpa, FakeSink, TestBlock, &sink, text_obj, &old, &new_spans);
    // One `replace` event, and a grapheme replaced by a grapheme deletes then
    // splices at the same position (`text_diff.rs:408-416`).
    try testing.expectEqual(@as(usize, 2), sink.calls.items.len);
    try testing.expectEqual(@as(usize, 1), sink.calls.items[0].delete);
    try testing.expectEqual(@as(usize, 1), sink.calls.items[1].splice.index);
    try testing.expectEqualStrings("c", sink.calls.items[1].splice.insert);
}

test "the block hook flushes a text run before every block" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .unicode_code_point };
    defer sink.deinit();
    const old = [_]BlockOrGrapheme(TestBlock){};
    const new = [_]BlockOrGrapheme(TestBlock){
        .{ .grapheme = "x" },
        .{ .grapheme = "y" },
        .{ .block = .{ .bytes = "{}" } },
        .{ .grapheme = "z" },
    };
    var hook: BlockDiffHook(FakeSink, TestBlock) = .{
        .sink = &sink,
        .old = &old,
        .new = &new,
        .obj = text_obj,
        .idx = 0,
        .gpa = gpa,
    };
    try hook.insert(0, 0, new.len);

    // The run of two graphemes, then the block at position 2, which is also
    // given its contents in that order, then the trailing grapheme at
    // position 3.
    try testing.expectEqual(@as(usize, 4), sink.calls.items.len);
    try testing.expectEqualStrings("xy", sink.calls.items[0].splice.insert);
    try testing.expectEqual(@as(usize, 0), sink.calls.items[0].splice.index);
    try testing.expectEqual(@as(usize, 2), sink.calls.items[1].split_block.index);
    try testing.expect(sink.calls.items[2].update_map.block.eql(sink.calls.items[1].split_block.id));
    try testing.expectEqualStrings("{}", sink.calls.items[2].update_map.map);
    try testing.expectEqual(@as(usize, 3), sink.calls.items[3].splice.index);
    try testing.expectEqualStrings("z", sink.calls.items[3].splice.insert);
    // Two graphemes, the block, then one more: four positions.
    try testing.expectEqual(@as(usize, 4), hook.idx);
}

test "the block hook deletes a block by joining it and text by deleting" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .encoding = .unicode_code_point };
    defer sink.deinit();
    const old = [_]BlockOrGrapheme(TestBlock){
        .{ .block = .{ .bytes = "{}" } },
        .{ .grapheme = "q" },
    };
    var hook: BlockDiffHook(FakeSink, TestBlock) = .{
        .sink = &sink,
        .old = &old,
        .new = &.{},
        .obj = text_obj,
        .idx = 0,
        .gpa = gpa,
    };
    try hook.delete(0, old.len, 0);
    try testing.expectEqual(@as(usize, 2), sink.calls.items.len);
    try testing.expectEqual(@as(usize, 0), sink.calls.items[0].join_block);
    try testing.expectEqual(@as(usize, 0), sink.calls.items[1].delete);
}

/// The block `blockReplace` reports at position 0, which is the block
/// `update_block` updates (`text_diff.rs:510-512`).
const known_block: ExId = .{ .id = .{ .counter = 42, .actor = 0 } };

/// Runs one `replace` event through a fresh hook over `sink`.
fn blockReplace(
    gpa: Allocator,
    sink: *FakeSink,
    old: []const BlockOrGrapheme(TestBlock),
    new: []const BlockOrGrapheme(TestBlock),
) !void {
    var hook: BlockDiffHook(FakeSink, TestBlock) = .{
        .sink = sink,
        .old = old,
        .new = new,
        .obj = text_obj,
        .idx = 0,
        .gpa = gpa,
    };
    try hook.replace(0, old.len, 0, new.len);
}

/// A sink that reports `known_block` at position 0, for the cases that need
/// `update_block` to find a block.
fn blockSink(gpa: Allocator) FakeSink {
    return .{ .gpa = gpa, .encoding = .unicode_code_point, .blocks = &.{known_block} };
}

test "the block hook pairs the old and new elements" {
    const gpa = testing.allocator;
    const block = BlockOrGrapheme(TestBlock){ .block = .{ .bytes = "{}" } };
    const other_block = BlockOrGrapheme(TestBlock){ .block = .{ .bytes = "[]" } };
    const text = BlockOrGrapheme(TestBlock){ .grapheme = "q" };

    // Two blocks with the same contents: no call at all, but the position
    // still moves past the block (`text_diff.rs:400-407`).
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{block}, &.{block});
        try testing.expectEqual(@as(usize, 0), sink.calls.items.len);
    }

    // Two blocks with different contents: the block found at the position is
    // updated in place.
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{block}, &.{other_block});
        try testing.expectEqual(@as(usize, 1), sink.calls.items.len);
        try testing.expect(sink.calls.items[0].update_map.block.eql(known_block));
        try testing.expectEqualStrings("[]", sink.calls.items[0].update_map.map);
    }

    // A block becoming text: join the block, then splice
    // (`text_diff.rs:417-425`).
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{block}, &.{text});
        try testing.expectEqual(@as(usize, 2), sink.calls.items.len);
        try testing.expectEqual(@as(usize, 0), sink.calls.items[0].join_block);
        try testing.expectEqualStrings("q", sink.calls.items[1].splice.insert);
    }

    // Text becoming a block: delete, then split the block out
    // (`text_diff.rs:426-433`).
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{text}, &.{other_block});
        try testing.expectEqual(@as(usize, 3), sink.calls.items.len);
        try testing.expectEqual(@as(usize, 0), sink.calls.items[0].delete);
        try testing.expectEqual(@as(usize, 0), sink.calls.items[1].split_block.index);
        try testing.expectEqualStrings("[]", sink.calls.items[2].update_map.map);
    }

    // Only the new side has anything: splice the text, or split the block out
    // (`text_diff.rs:374-386`).
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{}, &.{text});
        try testing.expectEqual(@as(usize, 1), sink.calls.items.len);
        try testing.expectEqualStrings("q", sink.calls.items[0].splice.insert);
    }
    {
        var sink = blockSink(gpa);
        defer sink.deinit();
        try blockReplace(gpa, &sink, &.{}, &.{other_block});
        try testing.expectEqual(@as(usize, 2), sink.calls.items.len);
        try testing.expectEqual(@as(usize, 0), sink.calls.items[0].split_block.index);
        try testing.expectEqualStrings("[]", sink.calls.items[1].update_map.map);
    }
}

test "updateBlock reports a position that holds no block" {
    const gpa = testing.allocator;
    var sink: FakeSink = .{ .gpa = gpa, .blocks = &.{} };
    defer sink.deinit();
    try testing.expectError(
        error.InvalidIndex,
        updateBlock(FakeSink, TestBlock, &sink, text_obj, 0, .{ .bytes = "{}" }),
    );

    const block: ExId = .{ .id = .{ .counter = 3, .actor = 1 } };
    sink.blocks = &.{block};
    try updateBlock(FakeSink, TestBlock, &sink, text_obj, 0, .{ .bytes = "{}" });
    try testing.expectEqual(@as(usize, 1), sink.calls.items.len);
    try testing.expect(sink.calls.items[0].update_map.block.eql(block));
    try testing.expectEqualStrings("{}", sink.calls.items[0].update_map.map);
}
