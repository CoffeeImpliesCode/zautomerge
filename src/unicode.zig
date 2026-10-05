//! Text measurement and segmentation.
//!
//! `automerge` counts positions in a text object in the units named by its
//! `TextEncoding`. Three of the four need more than `std` provides: Zig's
//! standard library counts code points and nothing else, so UTF-16 code units
//! and grapheme clusters are implemented here.
//!
//! Grapheme clustering follows the UAX #29 extended grapheme cluster rules.
//! The implementation is a left-to-right state machine over the class of each
//! code point; the rules carry the numbers used in the UAX #29 annex, and the
//! property tables below hold the class data.
//!
//! **Classifying a code point costs a fixed number of comparisons.** The
//! inline tests are a fixed list of range checks, and the four property
//! tables are searched and not walked: seven comparisons for `ext_pict`,
//! eight for `combining`, seven for `spacing`, four for `format_controls`,
//! and none at all for a code point below U+00A9, which is in none of them.
//! A segmentation is therefore a bounded number of comparisons per code
//! point rather than one per range per table.

const std = @import("std");
/// The errors the text helpers return. Zig's UTF-8 decoder does not publish
/// its error set, so the helpers infer theirs; the variants a caller sees are
/// the `Utf8*` names from `std.unicode` plus `InvalidUtf8` for a truncated
/// tail found by this module's own byte walks.
pub const UnicodeError = anyerror;

/// The number of code points in `s`.
pub fn countCodepoints(s: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(s);
}

/// The number of UTF-16 code units in `s`: one per code point, plus one more
/// for every code point above U+FFFF.
pub fn countUtf16CodeUnits(s: []const u8) !usize {
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        n += if (cp > 0xffff) 2 else 1;
    }
    return n;
}

/// The number of extended grapheme clusters in `s`.
pub fn countGraphemes(s: []const u8) !usize {
    if (s.len == 0) return 0;
    // The first code point opens the first cluster; every later break adds one.
    var n: usize = 1;
    var st = Scanner{};
    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| {
        if (st.step(cp)) n += 1;
    }
    return n;
}

/// Whether an extended grapheme cluster opens immediately before the code
/// point `cp`: for the first code point of a string always, because there is
/// nothing in front of it to break from, and for every later one exactly when
/// the UAX #29 break rules fire.
///
/// **The scanner is fed before `started` is read, and that order is the whole
/// point.** [`Scanner.step`] is what sets `started`, so the expression
/// `!st.started or st.step(cp)` short-circuits on the first code point:
/// `step` never runs, `started` is still false when the second code point
/// arrives, and every position in the string then looks like a cluster start.
/// That is why [`countGraphemes`] — which calls `step` for every code point
/// and never reads `started` — was the only correct primitive in this file,
/// and why `textdiff.graphemes` had to ask it about every prefix in turn to
/// place one boundary (`textdiff.zig`, before its single-pass rewrite).
/// Nothing here reads `started` after calling `step`.
fn opensCluster(st: *Scanner, cp: u21) bool {
    const was_started = st.started;
    const brk = st.step(cp);
    return !was_started or brk;
}

/// The byte offsets at which the extended grapheme clusters of `s` **after
/// the first** begin, ascending. A null ends the walk.
///
/// **The first cluster is not repeated**, because its start is 0 and every
/// caller already knows it: a walk starts at 0, takes `text[at..start]` for
/// each answer, and closes the last cluster at `s.len`.
///
/// **The scanner is carried across calls**, so the string is decoded exactly
/// once however many clusters it has. That is the whole difference from
/// asking [`countGraphemes`] about every prefix, which is `O(n^2)` and is
/// what this type replaced: for a 210 000-character ASCII string the count
/// walks 2.2e10 code points, this walks 210 000.
///
/// **The walk terminates on any input.** Every step advances `cursor` by at
/// least one byte — `utf8ByteSequenceLength` answers one to four or an error —
/// and a truncated sequence or a bad start byte ends the walk with
/// `error.InvalidUtf8` rather than being skipped, so untrusted bytes are an
/// error and never a spin.
pub const GraphemeBoundaryIter = struct {
    /// The string being walked, **borrowed for the walk's whole life**: the
    /// caller must keep it alive and must not change its bytes while the
    /// iterator lives, because `cursor` is a byte position in it and every
    /// answer is an offset into it.
    s: []const u8,
    /// The cluster-break scanner, carried across calls so the string is
    /// decoded exactly once however many clusters it has.
    st: Scanner = .{},
    /// The offset the next code point to feed the scanner starts at.
    cursor: usize = 0,
    /// Whether the first code point has been fed.
    seeded: bool = false,

    /// The offset the next cluster starts at, or null once the string is
    /// exhausted. The first cluster is not reported: it starts at 0 and
    /// every caller already knows it.
    ///
    /// **`error.InvalidUtf8` is the only error reachable**, and a bad start
    /// byte and a truncated tail both name it. **An error ends the walk and
    /// the iterator is not resumable**: the seeding block has already set
    /// `seeded`, and `cursor` still stands on the byte that failed, so every
    /// later call reads the same byte and returns the same error. A caller
    /// that wants to go on builds a fresh iterator and starts again.
    pub fn next(self: *GraphemeBoundaryIter) !?usize {
        if (!self.seeded) {
            // The first code point opens the first cluster and closes none. It
            // is fed here rather than in the loop because it is what makes
            // `opensCluster` mean "a rule fired" rather than "nothing is
            // behind this yet" from the second code point on, and because a
            // loop that fed it would report a break before the first code
            // point and hand back an empty first cluster.
            self.seeded = true;
            if (self.s.len == 0) return null;
            const len = std.unicode.utf8ByteSequenceLength(self.s[0]) catch
                return error.InvalidUtf8;
            if (len > self.s.len) return error.InvalidUtf8;
            const cp = std.unicode.utf8Decode(self.s[0..len]) catch
                return error.InvalidUtf8;
            _ = self.st.step(cp);
            self.cursor = len;
        }
        var i = self.cursor;
        while (i < self.s.len) {
            const len = std.unicode.utf8ByteSequenceLength(self.s[i]) catch
                return error.InvalidUtf8;
            if (i + len > self.s.len) return error.InvalidUtf8;
            const cp = std.unicode.utf8Decode(self.s[i .. i + len]) catch
                return error.InvalidUtf8;
            // **Every code point is fed exactly once.** `opensCluster` both
            // reports the break and advances the scanner, so the cursor moves
            // past the code point that reported it; a cursor left at the break
            // would feed that code point again and close the next cluster at
            // its own first byte.
            if (opensCluster(&self.st, cp)) {
                self.cursor = i + len;
                return i;
            }
            i += len;
        }
        self.cursor = self.s.len;
        return null;
    }
};

/// The boundary walk over `s`. **The iterator borrows `s`**: the buffer must
/// stay alive and unmodified until the walk ends, and every offset `next`
/// answers is an offset into it.
pub fn graphemeBoundaries(s: []const u8) GraphemeBoundaryIter {
    return .{ .s = s };
}

/// The byte offset of the grapheme cluster boundary at or after `byte_index`,
/// or `s.len` at the end. `byte_index` must be a codepoint boundary.
pub fn nextGraphemeBoundary(s: []const u8, byte_index: usize) !usize {
    if (byte_index >= s.len) return s.len;
    if (byte_index == 0) return 0;
    var walk = graphemeBoundaries(s);
    while (try walk.next()) |start| {
        if (start >= byte_index) return start;
    }
    return s.len;
}

/// The byte offset of the last grapheme cluster boundary at or before
/// `byte_index`, or `s.len` once the walk reaches the end. An index past the
/// end answers as the end itself does.
///
/// A code point that runs past the end of `s` — a truncated tail, which a
/// text object can end on — is `error.InvalidUtf8`, checked before the code
/// point is sliced out of the string.
pub fn prevGraphemeBoundary(s: []const u8, byte_index: usize) !usize {
    if (byte_index == 0) return 0;
    var best: usize = 0;
    var st = Scanner{};
    var i: usize = 0;
    while (i < byte_index and i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.InvalidUtf8;
        // The walk decodes a whole code point, so the sequence has to fit
        // inside `s` before it is sliced out of it. `GraphemeBoundaryIter`
        // draws the same line at `i + len > self.s.len`: a truncated tail is
        // an error, never a slice past the end of the buffer.
        if (i + len > s.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(s[i .. i + len]) catch return error.InvalidUtf8;
        if (opensCluster(&st, cp) and i < byte_index) best = i;
        i += len;
    }
    return best;
}

/// The byte offset of grapheme cluster `index`, counting from the start. An
/// index past the end gives `s.len`.
pub fn graphemeOffset(s: []const u8, index: usize) !usize {
    if (index == 0) return 0;
    var walk = graphemeBoundaries(s);
    var seen: usize = 1;
    while (try walk.next()) |start| {
        if (seen == index) return start;
        seen += 1;
    }
    return s.len;
}

/// The grapheme class of a code point, as UAX #29 defines it.
const Class = enum {
    other,
    control,
    cr,
    lf,
    extend,
    spacing_mark,
    zwj,
    prepend,
    regional_indicator,
    hangul_l,
    hangul_v,
    hangul_t,
    hangul_lv,
    hangul_lvt,
    /// An extended pictographic code point. ExtPict is a separate property
    /// from the grapheme break classes, and GB11 needs both.
    ext_pict,
};

/// Walks a string one code point at a time and reports, for each code point,
/// whether a cluster boundary falls immediately before it. The first code
/// point never reports a break.
const Scanner = struct {
    started: bool = false,
    /// The class of the previous code point, used by the Hangul and
    /// regional-indicator rules.
    prev: Class = .other,
    /// The length of the run of regional indicators ending at `prev`.
    ri_run: usize = 0,
    /// True when the run so far is `ExtPict Extend*`, which GB11 needs.
    pict_run: bool = false,

    /// Feeds one code point. Returns true when a boundary falls before it.
    fn step(self: *Scanner, cp: u21) bool {
        const c = classOf(cp);
        var brk: bool = true;
        if (!self.started) {
            brk = false;
        } else switch (self.prev) {
            // GB3: CR × LF.
            .cr => brk = c != .lf,
            // GB4: (Control | CR | LF) ÷.
            .lf, .control => brk = true,
            else => brk = switch (c) {
                // GB9: × (Extend | ZWJ). GB9a: × SpacingMark.
                .extend, .zwj, .spacing_mark => false,
                // GB9b: Prepend ×.
                else => if (self.prev == .prepend) false else switch (c) {
                    // GB11: ExtPict Extend* ZWJ × ExtPict, so no break
                    // only when the previous code point was a ZWJ and an
                    // extended pictograph was seen before it.
                    .ext_pict => self.prev != .zwj or !self.pict_run,
                    // GB12, GB13: pair up regional indicators.
                    .regional_indicator => self.ri_run % 2 == 0,
                    else => !hangulJoins(self.prev, c),
                },
            },
        }

        if (brk) self.ri_run = 0;
        if (c == .regional_indicator) {
            self.ri_run = if (self.prev == .regional_indicator and !brk)
                self.ri_run + 1
            else
                1;
        }
        if (c == .ext_pict) {
            self.pict_run = true;
        } else if (c == .extend) {
            // Extend keeps an existing ExtPict run alive.
        } else if (c != .zwj) {
            self.pict_run = false;
        }

        self.started = true;
        self.prev = c;
        return brk;
    }
};

/// GB6, GB7, GB8: the Hangul syllable sequences.
fn hangulJoins(prev: Class, cur: Class) bool {
    return switch (prev) {
        .hangul_l => switch (cur) {
            .hangul_l, .hangul_v, .hangul_lv, .hangul_lvt => true,
            else => false,
        },
        .hangul_lv, .hangul_v => switch (cur) {
            .hangul_v, .hangul_t => true,
            else => false,
        },
        .hangul_lvt, .hangul_t => cur == .hangul_t,
        else => false,
    };
}

/// The UAX #29 grapheme class of `cp`.
///
/// **Every code point is classified by a bounded number of comparisons**, and
/// the four property tables are the reason it used not to be: they were
/// walked one range at a time, so a code point that reached them paid 348
/// comparisons to be told it was in none of them. They are searched now — see
/// [`inRanges`] — and a code point below [`first_property_cp`] skips them
/// altogether, which is the whole cost of classifying ASCII.
fn classOf(cp: u21) Class {
    switch (cp) {
        '\r' => return .cr,
        '\n' => return .lf,
        0x200d => return .zwj,
        else => {},
    }
    if (cp >= 0x1f1e6 and cp <= 0x1f1ff) return .regional_indicator;
    if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return .control;
    // Hangul.
    if (cp >= 0x1100 and cp <= 0x115f) return .hangul_l;
    if (cp >= 0x1160 and cp <= 0x11a7) return .hangul_v;
    if (cp >= 0x11a8 and cp <= 0x11ff) return .hangul_t;
    if (cp >= 0xa960 and cp <= 0xa97c) return .hangul_l;
    if (cp >= 0xd7b0 and cp <= 0xd7c6) return .hangul_v;
    if (cp >= 0xd7cb and cp <= 0xd7fb) return .hangul_t;
    if (cp >= 0xac00 and cp <= 0xd7a3) {
        return if ((cp - 0xac00) % 28 == 0) .hangul_lv else .hangul_lvt;
    }
    // Variation selectors and emoji modifiers extend.
    if (cp >= 0xfe00 and cp <= 0xfe0f) return .extend;
    if (cp >= 0xe0100 and cp <= 0xe01ef) return .extend;
    if (cp >= 0x1f3fb and cp <= 0x1f3ff) return .extend;
    // Prepended concatenation marks.
    switch (cp) {
        0x0600...0x0605, 0x06dd, 0x070f, 0x0890, 0x0891, 0x08e2, 0x0d4e, 0x110bd, 0x110cd, 0x111c2, 0x111c3, 0x1193f, 0x11941, 0x11a3a, 0x11a84...0x11a89, 0x11d46, 0x11f02 => return .prepend,
        else => {},
    }
    // Nothing below the first code point any of the four tables names is in
    // one of them, so such a code point is `.other` and none of the four is
    // searched. That is 348 comparisons dropped for every ASCII code point,
    // which on most text is most of them.
    if (cp < first_property_cp) return .other;
    if (inRanges(cp, &ext_pict)) return .ext_pict;
    if (inRanges(cp, &combining)) return .extend;
    if (inRanges(cp, &spacing)) return .spacing_mark;
    if (inRanges(cp, &format_controls)) return .control;
    return .other;
}

/// Whether `cp` falls inside one of `ranges`.
///
/// **A binary search, and only a correct one because `ranges` is sorted by
/// start and holds no two overlapping ranges** — both checked at compile time
/// by the block below the tables. The search ends on the last range that
/// starts at or below `cp`, and that is the only range that can hold `cp`:
/// every range sorted after it starts later, and because the two do not
/// overlap it has to start above `cp`, which the search has already ruled
/// out. A one-code-point range `[x, x]` is the same case with the two ends
/// equal, and the largest code point any table names fits a `u21` with three
/// bits to spare, so the comparisons are plain integer ones.
///
/// Seven comparisons for [`ext_pict`], eight for [`combining`], seven for
/// [`spacing`] and four for [`format_controls`], where the walk this replaced
/// cost one per range: 78, 172, 87 and 11, and 348 for a code point in none of
/// them.
///
/// **The four tables are deliberately not merged into one.** A merged table
/// would answer all four questions in 9 comparisons, against the 26 these
/// four cost for a code point that is in none of them. But a code point that
/// *is* in `ext_pict`, which is what an emoji is, would pay 9 where it pays 7
/// to reach its own class, and ASCII and emoji are the two classes the
/// segmentation oracle in `textdiff.zig` walks. Merging would also move the
/// order of the four calls out of the code and into the data: `combining` and
/// `spacing` both hold U+1A19 and U+1A1A, `combining` and `format_controls`
/// both hold U+200C, and all three are `.extend` today, because `combining`
/// is asked first.
fn inRanges(cp: u21, ranges: []const [2]u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ranges[mid][0] <= cp) lo = mid + 1 else hi = mid;
    }
    return lo != 0 and cp <= ranges[lo - 1][1];
}

/// [`classOf`] as it was before the tables were searched and the code points
/// below [`first_property_cp`] short-circuited: the same four tables, walked
/// in the same order, all four of them. **Kept as the oracle for the test at
/// the foot of this file**, the way `textdiff.byPerPrefixCount` keeps the
/// segmentation it replaced, so that a code point the two answer differently
/// is a failing test rather than a segmentation nobody notices is wrong.
fn classOfLinear(cp: u21) Class {
    switch (cp) {
        '\r' => return .cr,
        '\n' => return .lf,
        0x200d => return .zwj,
        else => {},
    }
    if (cp >= 0x1f1e6 and cp <= 0x1f1ff) return .regional_indicator;
    if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return .control;
    // Hangul.
    if (cp >= 0x1100 and cp <= 0x115f) return .hangul_l;
    if (cp >= 0x1160 and cp <= 0x11a7) return .hangul_v;
    if (cp >= 0x11a8 and cp <= 0x11ff) return .hangul_t;
    if (cp >= 0xa960 and cp <= 0xa97c) return .hangul_l;
    if (cp >= 0xd7b0 and cp <= 0xd7c6) return .hangul_v;
    if (cp >= 0xd7cb and cp <= 0xd7fb) return .hangul_t;
    if (cp >= 0xac00 and cp <= 0xd7a3) {
        return if ((cp - 0xac00) % 28 == 0) .hangul_lv else .hangul_lvt;
    }
    // Variation selectors and emoji modifiers extend.
    if (cp >= 0xfe00 and cp <= 0xfe0f) return .extend;
    if (cp >= 0xe0100 and cp <= 0xe01ef) return .extend;
    if (cp >= 0x1f3fb and cp <= 0x1f3ff) return .extend;
    // Prepended concatenation marks.
    switch (cp) {
        0x0600...0x0605, 0x06dd, 0x070f, 0x0890, 0x0891, 0x08e2, 0x0d4e, 0x110bd, 0x110cd, 0x111c2, 0x111c3, 0x1193f, 0x11941, 0x11a3a, 0x11a84...0x11a89, 0x11d46, 0x11f02 => return .prepend,
        else => {},
    }
    if (inRangesLinear(cp, &ext_pict)) return .ext_pict;
    if (inRangesLinear(cp, &combining)) return .extend;
    if (inRangesLinear(cp, &spacing)) return .spacing_mark;
    if (inRangesLinear(cp, &format_controls)) return .control;
    return .other;
}

fn inRangesLinear(cp: u21, ranges: []const [2]u21) bool {
    for (ranges) |r| {
        if (cp >= r[0] and cp <= r[1]) return true;
    }
    return false;
}

/// General_Category=Extend, minus the ranges handled inline above.
const combining = [_][2]u21{
    .{ 0x0300, 0x036f },   .{ 0x0483, 0x0489 },   .{ 0x0591, 0x05bd },
    .{ 0x05bf, 0x05bf },   .{ 0x05c1, 0x05c2 },   .{ 0x05c4, 0x05c5 },
    .{ 0x05c7, 0x05c7 },   .{ 0x0610, 0x061a },   .{ 0x064b, 0x065f },
    .{ 0x0670, 0x0670 },   .{ 0x06d6, 0x06dc },   .{ 0x06df, 0x06e4 },
    .{ 0x06e7, 0x06e8 },   .{ 0x06ea, 0x06ed },   .{ 0x0711, 0x0711 },
    .{ 0x0730, 0x074a },   .{ 0x07a6, 0x07b0 },   .{ 0x07eb, 0x07f3 },
    .{ 0x0816, 0x0819 },   .{ 0x081b, 0x0823 },   .{ 0x0825, 0x0827 },
    .{ 0x0829, 0x082d },   .{ 0x0859, 0x085b },   .{ 0x08d3, 0x08e1 },
    .{ 0x08e3, 0x0902 },   .{ 0x093a, 0x093a },   .{ 0x093c, 0x093c },
    .{ 0x0941, 0x0948 },   .{ 0x094d, 0x094d },   .{ 0x0951, 0x0957 },
    .{ 0x0962, 0x0963 },   .{ 0x0981, 0x0981 },   .{ 0x09bc, 0x09bc },
    .{ 0x09c1, 0x09c4 },   .{ 0x09cd, 0x09cd },   .{ 0x09e2, 0x09e3 },
    .{ 0x0a01, 0x0a02 },   .{ 0x0a3c, 0x0a3c },   .{ 0x0a41, 0x0a42 },
    .{ 0x0a47, 0x0a48 },   .{ 0x0a4b, 0x0a4d },   .{ 0x0a51, 0x0a51 },
    .{ 0x0a70, 0x0a71 },   .{ 0x0a75, 0x0a75 },   .{ 0x0abc, 0x0abc },
    .{ 0x0ac1, 0x0ac5 },   .{ 0x0ac7, 0x0ac8 },   .{ 0x0acd, 0x0acd },
    .{ 0x0b01, 0x0b01 },   .{ 0x0b3c, 0x0b3c },   .{ 0x0b3f, 0x0b3f },
    .{ 0x0b41, 0x0b44 },   .{ 0x0b4d, 0x0b4d },   .{ 0x0b82, 0x0b82 },
    .{ 0x0bc0, 0x0bc0 },   .{ 0x0bcd, 0x0bcd },   .{ 0x0c00, 0x0c00 },
    .{ 0x0c3e, 0x0c40 },   .{ 0x0c46, 0x0c48 },   .{ 0x0c4a, 0x0c4d },
    .{ 0x0cbc, 0x0cbc },   .{ 0x0ccc, 0x0ccd },   .{ 0x0d41, 0x0d44 },
    .{ 0x0d4d, 0x0d4d },   .{ 0x0dca, 0x0dca },   .{ 0x0e31, 0x0e31 },
    .{ 0x0e34, 0x0e3a },   .{ 0x0e47, 0x0e4e },   .{ 0x0eb1, 0x0eb1 },
    .{ 0x0eb4, 0x0ebc },   .{ 0x0ec8, 0x0ecd },   .{ 0x0f18, 0x0f19 },
    .{ 0x0f35, 0x0f35 },   .{ 0x0f37, 0x0f37 },   .{ 0x0f39, 0x0f39 },
    .{ 0x0f71, 0x0f7e },   .{ 0x0f80, 0x0f84 },   .{ 0x0f86, 0x0f87 },
    .{ 0x102d, 0x1030 },   .{ 0x1032, 0x1037 },   .{ 0x1039, 0x103a },
    .{ 0x1058, 0x1059 },   .{ 0x135d, 0x135f },   .{ 0x1712, 0x1714 },
    .{ 0x1732, 0x1734 },   .{ 0x17b4, 0x17b5 },   .{ 0x17b7, 0x17bd },
    .{ 0x17c6, 0x17c6 },   .{ 0x17c9, 0x17d3 },   .{ 0x180b, 0x180d },
    .{ 0x18a9, 0x18a9 },   .{ 0x1a17, 0x1a1b },   .{ 0x1ab0, 0x1aff },
    .{ 0x1dc0, 0x1dff },   .{ 0x200c, 0x200c },   .{ 0x20d0, 0x20f0 },
    .{ 0x2cef, 0x2cf1 },   .{ 0x302a, 0x302f },   .{ 0x3099, 0x309a },
    .{ 0xa66f, 0xa672 },   .{ 0xa674, 0xa67d },   .{ 0xa69e, 0xa69f },
    .{ 0xa6f0, 0xa6f1 },   .{ 0xa806, 0xa806 },   .{ 0xa8c4, 0xa8c5 },
    .{ 0xa8e0, 0xa8f1 },   .{ 0xa92b, 0xa92d },   .{ 0xa9b3, 0xa9b3 },
    .{ 0xaab0, 0xaab0 },   .{ 0xaab2, 0xaab4 },   .{ 0xaab7, 0xaab8 },
    .{ 0xaabe, 0xaabf },   .{ 0xfb1e, 0xfb1e },   .{ 0xfe20, 0xfe2f },
    .{ 0x101fd, 0x101fd }, .{ 0x102e0, 0x102e0 }, .{ 0x10376, 0x1037a },
    .{ 0x10a01, 0x10a03 }, .{ 0x10a05, 0x10a06 }, .{ 0x10a0c, 0x10a0f },
    .{ 0x10a38, 0x10a3a }, .{ 0x10a3f, 0x10a3f }, .{ 0x10ae5, 0x10ae6 },
    .{ 0x11046, 0x11046 }, .{ 0x1107f, 0x11081 }, .{ 0x110b3, 0x110b6 },
    .{ 0x110b9, 0x110ba }, .{ 0x11100, 0x11102 }, .{ 0x11173, 0x11173 },
    .{ 0x111b6, 0x111be }, .{ 0x1122f, 0x11231 }, .{ 0x11234, 0x11234 },
    .{ 0x11236, 0x11237 }, .{ 0x112df, 0x112df }, .{ 0x112e3, 0x112ea },
    .{ 0x11301, 0x11301 }, .{ 0x1133c, 0x1133c }, .{ 0x11340, 0x11340 },
    .{ 0x11366, 0x1136c }, .{ 0x11370, 0x11374 }, .{ 0x114b3, 0x114b8 },
    .{ 0x114ba, 0x114ba }, .{ 0x114bf, 0x114c0 }, .{ 0x114c2, 0x114c3 },
    .{ 0x115b2, 0x115b5 }, .{ 0x115bc, 0x115bd }, .{ 0x115bf, 0x115c0 },
    .{ 0x11630, 0x11640 }, .{ 0x116ab, 0x116b7 }, .{ 0x1171d, 0x1171f },
    .{ 0x11722, 0x11725 }, .{ 0x11727, 0x1172b }, .{ 0x16af0, 0x16af4 },
    .{ 0x16b30, 0x16b36 }, .{ 0x1bc9d, 0x1bc9e }, .{ 0x1d165, 0x1d169 },
    .{ 0x1d16d, 0x1d172 }, .{ 0x1d17b, 0x1d182 }, .{ 0x1d185, 0x1d18b },
    .{ 0x1d1aa, 0x1d1ad }, .{ 0x1d242, 0x1d244 }, .{ 0x1da00, 0x1da36 },
    .{ 0x1da3b, 0x1da6c }, .{ 0x1da75, 0x1da75 }, .{ 0x1da84, 0x1da84 },
    .{ 0x1da9b, 0x1da9f }, .{ 0x1daa1, 0x1daaf }, .{ 0x1e000, 0x1e02a },
    .{ 0x1e130, 0x1e136 }, .{ 0x1e2ec, 0x1e2ef }, .{ 0x1e8d0, 0x1e8d6 },
    .{ 0x1e944, 0x1e94a },
};

/// General_Category=Spacing_Mark.
const spacing = [_][2]u21{
    .{ 0x0903, 0x0903 }, .{ 0x093b, 0x093b }, .{ 0x093e, 0x0940 },
    .{ 0x0949, 0x094c }, .{ 0x094e, 0x094f }, .{ 0x0982, 0x0983 },
    .{ 0x09be, 0x09c0 }, .{ 0x09c7, 0x09c8 }, .{ 0x09cb, 0x09cc },
    .{ 0x0a03, 0x0a03 }, .{ 0x0a3e, 0x0a40 }, .{ 0x0a83, 0x0a83 },
    .{ 0x0abe, 0x0ac0 }, .{ 0x0ac9, 0x0ac9 }, .{ 0x0acb, 0x0acc },
    .{ 0x0b02, 0x0b03 }, .{ 0x0b3e, 0x0b3e }, .{ 0x0b40, 0x0b40 },
    .{ 0x0b47, 0x0b48 }, .{ 0x0b4b, 0x0b4c }, .{ 0x0b57, 0x0b57 },
    .{ 0x0bbe, 0x0bbf }, .{ 0x0bc1, 0x0bc2 }, .{ 0x0bc6, 0x0bc8 },
    .{ 0x0bca, 0x0bcc }, .{ 0x0c01, 0x0c03 }, .{ 0x0c41, 0x0c44 },
    .{ 0x0c82, 0x0c83 }, .{ 0x0cbe, 0x0cbe }, .{ 0x0cc0, 0x0cc4 },
    .{ 0x0cc7, 0x0cc8 }, .{ 0x0cca, 0x0ccb }, .{ 0x0d02, 0x0d03 },
    .{ 0x0d3e, 0x0d40 }, .{ 0x0d46, 0x0d48 }, .{ 0x0d4a, 0x0d4c },
    .{ 0x0d82, 0x0d83 }, .{ 0x0dcf, 0x0dd1 }, .{ 0x0dd8, 0x0ddf },
    .{ 0x0df2, 0x0df3 }, .{ 0x0e33, 0x0e33 }, .{ 0x0eb3, 0x0eb3 },
    .{ 0x0f3e, 0x0f3f }, .{ 0x0f7f, 0x0f7f }, .{ 0x1031, 0x1031 },
    .{ 0x103b, 0x103c }, .{ 0x1056, 0x1057 }, .{ 0x1084, 0x1084 },
    .{ 0x17b6, 0x17b6 }, .{ 0x17be, 0x17c5 }, .{ 0x17c7, 0x17c8 },
    .{ 0x1923, 0x1926 }, .{ 0x1929, 0x192b }, .{ 0x1930, 0x1938 },
    .{ 0x1a19, 0x1a1a }, .{ 0x1b04, 0x1b04 }, .{ 0x1b35, 0x1b35 },
    .{ 0x1b3b, 0x1b3b }, .{ 0x1b3d, 0x1b41 }, .{ 0x1b43, 0x1b44 },
    .{ 0x1b82, 0x1b82 }, .{ 0x1ba1, 0x1ba1 }, .{ 0x1ba6, 0x1ba7 },
    .{ 0x1bea, 0x1bea }, .{ 0x1bee, 0x1bee }, .{ 0x1bf2, 0x1bf3 },
    .{ 0x1c24, 0x1c2b }, .{ 0x1c34, 0x1c36 }, .{ 0xa823, 0xa824 },
    .{ 0xa827, 0xa827 }, .{ 0xa880, 0xa881 }, .{ 0xa8b4, 0xa8c3 },
    .{ 0xa952, 0xa953 }, .{ 0xa983, 0xa983 }, .{ 0xa9b4, 0xa9b5 },
    .{ 0xa9ba, 0xa9ba }, .{ 0xa9bb, 0xa9bb }, .{ 0xaa2f, 0xaa30 },
    .{ 0xaa33, 0xaa34 }, .{ 0xaa4d, 0xaa4d }, .{ 0xaaeb, 0xaaeb },
    .{ 0xaaee, 0xaaef }, .{ 0xaaf5, 0xaaf5 }, .{ 0xabe3, 0xabe4 },
    .{ 0xabe6, 0xabe7 }, .{ 0xabe9, 0xabea }, .{ 0xabec, 0xabed },
};

/// Format characters that force a break.
const format_controls = [_][2]u21{
    .{ 0x00ad, 0x00ad },   .{ 0x061c, 0x061c },   .{ 0x180e, 0x180e },
    .{ 0x200b, 0x200f },   .{ 0x2028, 0x202e },   .{ 0x2060, 0x206f },
    .{ 0xfeff, 0xfeff },   .{ 0xfff0, 0xfffb },   .{ 0x1bca0, 0x1bca3 },
    .{ 0x1d173, 0x1d17a }, .{ 0xe0000, 0xe0fff },
};

/// The Extended_Pictographic property.
const ext_pict = [_][2]u21{
    .{ 0x00a9, 0x00a9 },   .{ 0x00ae, 0x00ae },   .{ 0x203c, 0x203c },
    .{ 0x2049, 0x2049 },   .{ 0x2122, 0x2122 },   .{ 0x2139, 0x2139 },
    .{ 0x2194, 0x2199 },   .{ 0x21a9, 0x21aa },   .{ 0x231a, 0x231b },
    .{ 0x2328, 0x2328 },   .{ 0x2388, 0x2388 },   .{ 0x23cf, 0x23cf },
    .{ 0x23e9, 0x23f3 },   .{ 0x23f8, 0x23fa },   .{ 0x24c2, 0x24c2 },
    .{ 0x25aa, 0x25ab },   .{ 0x25b6, 0x25b6 },   .{ 0x25c0, 0x25c0 },
    .{ 0x25fb, 0x25fe },   .{ 0x2600, 0x2605 },   .{ 0x2607, 0x2612 },
    .{ 0x2614, 0x2685 },   .{ 0x2690, 0x2705 },   .{ 0x2708, 0x2712 },
    .{ 0x2714, 0x2714 },   .{ 0x2716, 0x2716 },   .{ 0x271d, 0x271d },
    .{ 0x2721, 0x2721 },   .{ 0x2728, 0x2728 },   .{ 0x2733, 0x2734 },
    .{ 0x2744, 0x2744 },   .{ 0x2747, 0x2747 },   .{ 0x274c, 0x274c },
    .{ 0x274e, 0x274e },   .{ 0x2753, 0x2755 },   .{ 0x2757, 0x2757 },
    .{ 0x2763, 0x2767 },   .{ 0x2795, 0x2797 },   .{ 0x27a1, 0x27a1 },
    .{ 0x27b0, 0x27b0 },   .{ 0x27bf, 0x27bf },   .{ 0x2934, 0x2935 },
    .{ 0x2b05, 0x2b07 },   .{ 0x2b1b, 0x2b1c },   .{ 0x2b50, 0x2b50 },
    .{ 0x2b55, 0x2b55 },   .{ 0x3030, 0x3030 },   .{ 0x303d, 0x303d },
    .{ 0x3297, 0x3297 },   .{ 0x3299, 0x3299 },   .{ 0x1f000, 0x1f0ff },
    .{ 0x1f10d, 0x1f10f }, .{ 0x1f12f, 0x1f12f }, .{ 0x1f16c, 0x1f171 },
    .{ 0x1f17e, 0x1f17f }, .{ 0x1f18e, 0x1f18e }, .{ 0x1f191, 0x1f19a },
    .{ 0x1f1ad, 0x1f1e5 }, .{ 0x1f201, 0x1f20f }, .{ 0x1f21a, 0x1f21a },
    .{ 0x1f22f, 0x1f22f }, .{ 0x1f232, 0x1f23a }, .{ 0x1f23c, 0x1f23f },
    .{ 0x1f249, 0x1f3fa }, .{ 0x1f400, 0x1f53d }, .{ 0x1f546, 0x1f64f },
    .{ 0x1f680, 0x1f6ff }, .{ 0x1f774, 0x1f77f }, .{ 0x1f7d5, 0x1f7ff },
    .{ 0x1f80c, 0x1f80f }, .{ 0x1f848, 0x1f84f }, .{ 0x1f85a, 0x1f85f },
    .{ 0x1f888, 0x1f88f }, .{ 0x1f8ae, 0x1f8ff }, .{ 0x1f90c, 0x1f93a },
    .{ 0x1f93c, 0x1f945 }, .{ 0x1f947, 0x1faff }, .{ 0x1fc00, 0x1fffd },
};

/// The lowest code point any of the four tables above names: U+00A9, out of
/// [`ext_pict`]. Every code point below it is in none of the four, so
/// [`classOf`] answers `.other` for it without searching any of them, and that
/// is where the 348 comparisons an ASCII code point used to cost went.
///
/// It is checked against the tables at compile time, because a table that
/// grew an entry below it would make that answer wrong, and wrong silently —
/// in a way no test over a corpus would notice.
const first_property_cp: u21 = 0xa9;

const PropertyTable = struct {
    name: []const u8,
    ranges: []const [2]u21,
};

/// Every property table, named, so the check below reaches all four through
/// one type and can name the one that failed.
const property_tables = [_]PropertyTable{
    .{ .name = "ext_pict", .ranges = &ext_pict },
    .{ .name = "combining", .ranges = &combining },
    .{ .name = "spacing", .ranges = &spacing },
    .{ .name = "format_controls", .ranges = &format_controls },
};

comptime {
    // **A searched table has to be sorted and has to hold no overlap, and
    // neither is visible at the call site.** [`inRanges`] reads its answer
    // off the range the search lands on, so a table that grew an entry out of
    // order, or two ranges that came to overlap, would be searched into a
    // wrong answer rather than refused. Checking here makes that a build
    // failure naming the table, instead of a misclassified code point found
    // much later; a walk would have needed neither property, which is why
    // nothing checked them until the search did.
    for (property_tables) |t| {
        for (t.ranges, 0..) |r, i| {
            if (r[0] > r[1]) @compileError(t.name ++ " has a range that ends before it starts");
            if (r[0] < first_property_cp) {
                @compileError(t.name ++ " has a range below first_property_cp, which" ++
                    " classOf answers .other without searching");
            }
            if (i == 0) continue;
            const prev = t.ranges[i - 1];
            if (r[0] <= prev[0]) @compileError(t.name ++ " has ranges that are not sorted by start");
            if (r[0] <= prev[1]) @compileError(t.name ++ " has two ranges that overlap");
        }
    }
}

test "codepoint and utf16 counting" {
    try std.testing.expectEqual(@as(usize, 2), try countCodepoints("aé"));
    // "aé" is 3 UTF-8 bytes and 2 UTF-16 units.
    try std.testing.expectEqual(@as(usize, 2), try countUtf16CodeUnits("aé"));
    // An emoji above the BMP takes two UTF-16 units.
    try std.testing.expectEqual(@as(usize, 1), try countCodepoints("😀"));
    try std.testing.expectEqual(@as(usize, 2), try countUtf16CodeUnits("😀"));
    try std.testing.expectEqual(@as(usize, 0), try countUtf16CodeUnits(""));
}

test "grapheme clustering" {
    // A base character followed by a combining acute is one cluster.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("é"));
    // A base, a combining mark, and a variation selector are still one.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("a\u{0301}"));
    // A ZWJ emoji sequence is one cluster.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("👨‍👩‍👦"));
    // A flag is two regional indicators in one cluster.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("🇩🇪"));
    // Two flags are two clusters.
    try std.testing.expectEqual(@as(usize, 2), try countGraphemes("🇩🇪🇫🇷"));
    // Three regional indicators are two clusters: the odd one stands alone.
    try std.testing.expectEqual(@as(usize, 2), try countGraphemes("🇩🇪🇫"));
    // A CR LF pair is one cluster.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("\r\n"));
    // CRLF followed by text: the pair is one cluster, the text another.
    try std.testing.expectEqual(@as(usize, 2), try countGraphemes("\r\na"));
    // A skin-tone modifier extends the preceding emoji.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("👍🏽"));
    // Plain ASCII is one cluster per byte.
    try std.testing.expectEqual(@as(usize, 4), try countGraphemes("abcd"));
    try std.testing.expectEqual(@as(usize, 0), try countGraphemes(""));
}

test "grapheme boundaries" {
    const s = "añb";
    // Cluster 0 is "a".
    try std.testing.expectEqual(@as(usize, 0), try graphemeOffset(s, 0));
    // Cluster 1 is the two-byte "ñ": offset 1 opens it, so it is its own
    // next boundary, and an offset inside it advances to 3.
    try std.testing.expectEqual(@as(usize, 1), try graphemeOffset(s, 1));
    try std.testing.expectEqual(@as(usize, 1), try nextGraphemeBoundary(s, 1));
    try std.testing.expectEqual(@as(usize, 3), try nextGraphemeBoundary(s, 2));
    try std.testing.expectEqual(@as(usize, 3), try graphemeOffset(s, 2));
    try std.testing.expectEqual(@as(usize, s.len), try graphemeOffset(s, 3));
    // Offset 2 is inside the ñ, so the previous boundary is 1.
    try std.testing.expectEqual(@as(usize, 1), try prevGraphemeBoundary(s, 2));
    // Offset 3 opens the b, so the boundary before it is 3 itself minus
    // the ñ that precedes it: the last boundary strictly before 3 is 1.
    try std.testing.expectEqual(@as(usize, 1), try prevGraphemeBoundary(s, 3));
    try std.testing.expectEqual(@as(usize, 3), try nextGraphemeBoundary(s, 3));
}

/// The byte ranges [`graphemeBoundaries`] hands out, as `[start, end)` pairs.
/// The test below is its only caller, and it is where the two ends of a walk
/// are pinned.
fn clusters(s: []const u8) !std.ArrayList([2]usize) {
    var out: std.ArrayList([2]usize) = .empty;
    errdefer out.deinit(std.testing.allocator);
    var walk = graphemeBoundaries(s);
    var at: usize = 0;
    while (try walk.next()) |start| {
        try out.append(std.testing.allocator, .{ at, start });
        at = start;
    }
    // The last cluster is closed by the end of the string, not by a break.
    if (at < s.len) try out.append(std.testing.allocator, .{ at, s.len });
    return out;
}

test "the cluster walk and the cluster count answer one question" {
    // **Every case the UAX #29 rules name**, and both ends with them: the
    // empty string, one ASCII cluster, a CRLF pair, a base plus a combining
    // mark, a ZWJ sequence, a flag, three regional indicators, a skin-tone
    // modifier, Hangul syllables, and — the two a rule cannot catch — a lone
    // combining mark with nothing in front of it and a lone ZWJ with nothing
    // behind it.
    const corpus = [_][]const u8{
        "",                      "a",        "abcd",
        "añb",
        "\r\n",                  "\r\na",
        "👨‍👩‍👦",
        "a\u{0301}",
        "🇩🇪",
        "🇩🇪🇫🇷",
        "🇩🇪🇫",
        "👍🏽",
        "한글",
        "the quick brown fox. ", "\u{0301}", "\u{200d}x",
        "\u{0d}x",
    };
    for (corpus) |s| {
        var got = try clusters(s);
        defer got.deinit(std.testing.allocator);

        // **One cluster per [`countGraphemes`].** The walk and the count are
        // two ways of answering one question, and this is the only place they
        // are held to each other.
        try std.testing.expectEqual(try countGraphemes(s), got.items.len);

        if (got.items.len == 0) {
            // Nothing to close, and an empty string is the only input for
            // which zero clusters is the right answer.
            try std.testing.expectEqual(@as(usize, 0), s.len);
            continue;
        }
        // **The first cluster starts at 0 and the last one ends at `s.len`,
        // asserted rather than derived.** Every other cluster is closed by a
        // break one of the rules fired on, and these two are not — they are
        // closed by the ends of the string. A walk that reports a break
        // before the first code point hands back an empty first cluster, and
        // a walk that never closes the last one drops it; both tile the middle
        // of the string correctly and fail only here.
        try std.testing.expectEqual(@as(usize, 0), got.items[0][0]);
        try std.testing.expectEqual(s.len, got.items[got.items.len - 1][1]);

        // **They tile the string, in order, none of them empty**, and their
        // bytes joined are the input's own.
        var tiled: usize = 0;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(std.testing.allocator);
        for (got.items) |c| {
            try std.testing.expect(c[1] > c[0]);
            try std.testing.expectEqual(tiled, c[0]);
            try joined.appendSlice(std.testing.allocator, s[c[0]..c[1]]);
            tiled = c[1];
        }
        try std.testing.expectEqual(s.len, tiled);
        try std.testing.expectEqualStrings(s, joined.items);
    }
}

test "a long text is segmented in one pass" {
    // **210 000 clusters, the text `tests/text.rs`:1125 splices.** Under the
    // per-prefix count this is 2.2e10 code-point visits and the test does not
    // finish; under the walk it is one decode per code point. **There is no
    // clock here on purpose**: a timing assertion is flaky, and this is not —
    // the old implementation hangs on this input and this one answers it, so
    // the input itself is the regression guard.
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (0..10_000) |_| try body.appendSlice(gpa, "the quick brown fox. ");
    var got = try clusters(body.items);
    defer got.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 210_000), got.items.len);
    try std.testing.expectEqual(@as(usize, 210_000), try countGraphemes(body.items));
}

test "hangul syllables cluster" {
    // A precomposed syllable plus a jamo trailing vowel is one cluster.
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("각"));
    try std.testing.expectEqual(@as(usize, 1), try countGraphemes("한"));
    // Two complete syllables are two clusters.
    try std.testing.expectEqual(@as(usize, 2), try countGraphemes("한글"));
}

test "invalid utf8 is rejected" {
    try std.testing.expectError(error.Utf8InvalidStartByte, countCodepoints(&[_]u8{0xff}));
    try std.testing.expectError(error.InvalidUtf8, countUtf16CodeUnits(&[_]u8{0xff}));
    try std.testing.expectError(error.InvalidUtf8, countGraphemes(&[_]u8{0x80}));
    try std.testing.expectError(error.InvalidUtf8, nextGraphemeBoundary(&[_]u8{ 0xe2, 0x28 }, 1));
}

test "a code point cut off by the end of the string is refused" {
    // **The last code point declares more bytes than the buffer holds.** A
    // text object can end on a truncated sequence, so every entry point that
    // decodes a code point has to check that the sequence fits before it
    // slices it out. `prevGraphemeBoundary` walked past the end here: the
    // loop tested only `i < s.len`, so `s[1..4]` was taken out of a three
    // byte slice.
    const truncated = "a\xe2\x82"; // "a" and two of the three bytes of "€".
    try std.testing.expectError(error.InvalidUtf8, prevGraphemeBoundary(truncated, truncated.len));
    try std.testing.expectError(error.InvalidUtf8, nextGraphemeBoundary(truncated, 1));
    try std.testing.expectError(error.InvalidUtf8, graphemeOffset(truncated, 2));
    // A four-byte sequence missing its last byte is the same refusal.
    const quad = "\xf0\x9f\x91";
    try std.testing.expectError(error.InvalidUtf8, graphemeOffset(quad, 1));
    // **The iterator is at the same place**, whichever end of the string the
    // truncation is at: the seeding code point is truncated here.
    var walk = graphemeBoundaries(quad);
    try std.testing.expectError(error.InvalidUtf8, walk.next());
    // A bad start byte is refused by name on the same paths.
    try std.testing.expectError(error.InvalidUtf8, prevGraphemeBoundary("a\xff", 2));
    try std.testing.expectError(error.InvalidUtf8, graphemeOffset("a\x80", 2));
    // **A whole code point is still answered, not refused**: the check is on
    // the sequence that runs off the end, not on every multi-byte cluster.
    // "a€b" is three clusters, so its boundaries are 0, 1 and 4.
    try std.testing.expectEqual(@as(usize, 1), try prevGraphemeBoundary("a€b", 2));
    try std.testing.expectEqual(@as(usize, 4), try prevGraphemeBoundary("a€b", 5));
}

test "the searched tables classify exactly what the walked ones did" {
    // **`classOfLinear` is the implementation this one replaced**, kept whole:
    // the same inline tests, then the same four tables walked in the same
    // order. Every code point the two answer differently is a segmentation
    // that changed, so the sweep below is what makes "same answer, fewer
    // comparisons" a checked claim rather than an argued one.
    //
    // It covers **every code point of the Basic Multilingual Plane** — which
    // is every code point below `first_property_cp`, every one the inline
    // tests decide, and every BMP entry of all four tables — and then, above
    // the BMP, **every range of all four tables from one code point below its
    // start to one above its end**. That last part is every code point a table
    // holds above the BMP and both ends of every such range, which is where a
    // search that landed one range too low would show.
    for (0..0x10000) |raw| {
        const cp: u21 = @intCast(raw);
        try std.testing.expectEqual(classOfLinear(cp), classOf(cp));
    }
    for (property_tables) |t| {
        for (t.ranges) |r| {
            const lo: u21 = r[0];
            const hi: u21 = r[1];
            if (hi < 0x10000) continue;
            var cp: u21 = lo - 1;
            while (cp <= hi + 1) : (cp += 1) {
                try std.testing.expectEqual(classOfLinear(cp), classOf(cp));
            }
        }
    }
    // **A stride over what the two sweeps leave**, so a range that had moved
    // out of their reach would still be caught. It re-decides nothing: a code
    // point that is in no table and stands beside none is `.other` by both
    // versions, for the same reason.
    var probe: u21 = 0x10000;
    while (probe <= 0x10ffff) : (probe += 64) {
        try std.testing.expectEqual(classOfLinear(probe), classOf(probe));
    }
}
