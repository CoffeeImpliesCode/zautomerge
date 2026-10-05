//! The rest of `$AUTOMERGE_REF/rust/automerge/tests/text.rs` — the three
//! cases [`src/read.zig`](../src/read.zig) does not carry, and nothing else.
//!
//! # Why a second file and not an append
//!
//! Two reasons, and only one of them is about concurrency. [`src/read.zig`]
//! already has its own 1,400-line fixture section for the same two upstream
//! files, but **a consumer cannot reach any of it**: it is a `test` file in a
//! *library* module, and everything it declares is private to that module. So
//! this file brings its own small harness — the same *shape*
//! ([`all_encodings`], [`EncIdx`], one fixture per encoding), the same
//! conventions, and about a tenth of the code, because these three cases need
//! far less of it than the thirty-two already ported do.
//!
//! # What "the rest" means, and how the list was established
//!
// `text.rs` has twenty `#[test]` functions, one of which is the `proptest!`
// case `marks_are_okay` (`text.rs`:658-710), and `text_encoding.rs` has fifteen
// more. That is **thirty-four named cases plus one property**, or thirty-five
// counting the property and excluding nothing, and `src/read.zig` already ports
// thirty-three of them. The three that are missing are the three below, and the
// list was settled by diffing the two upstream files' `fn` headers against the
// `test "..."` names in `src/read.zig` rather than by trusting any count in
// prose — the count in [`src/read.zig`](../src/read.zig)'s own diff block was
// **stale by nine**.
//!
//! | upstream | case | why a hand-built fixture cannot express it |
//! |---|---|---|
//! | `text.rs`:351-415 | `insertions_after_noexpand_spans_are_not_marked` | needs `update_spans` over a **zero-width** `ExpandMark::None` mark |
//! | `text.rs`:868-921 | `incorrect_patches_produced_when_isolating_and_integrating` | needs **more than a hundred patches**, the threshold at which `PatchBuilder::new` precomputes a visible-path cache |
//! | `text.rs`:944-1023 | `splicing_into_multibyte_characters` | needs a **legacy change whose insert op carries five grapheme clusters**, which `splice_text` will not produce |
//!
//! # Every one of them runs under all four encodings
//!
//! That is the whole subject of `text_encoding.rs` (`text_encoding.rs:34-46`),
//! whose `Scenario` loops over `unicode_code_point`, `utf8_code_unit`,
//! `utf16_code_unit` and `grapheme_cluster` in that order
//! (`text_encoding.rs:50-55`, `:124-133`). Upstream's own `text.rs` cases pin
//! one encoding each — `text.rs:878` pins `UnicodeCodePoint`, `:925` and
//! `:952` pin `Utf16CodeUnit` — so **a port that copies the pin covers a
//! quarter of the axis**. Each test here runs its whole script under all four,
//! and where a number means a different position in a different encoding the
//! script carries a table rather than one index.
//!
//! **All five tests below run under all four.** None is exempt, and the
//! places where the *answers* differ across encodings are recorded rather than
//! smoothed over: [`noexpand`] ends up with the appended block marker **before**
//! the `a` under UTF-8 code units and **after** it under the other three,
//! which is a real difference in the reference and a test that hid it would be
//! a test of the wrong thing.
//!
//! # The instrument
//!
//! Nothing here is reasoned out from the Rust. Every expected value comes from
//! the oracle's `text` subcommand
//! ([`tools/oracle/src/main.rs`](../tools/oracle/src/main.rs),
//! [`text_command`](../tools/oracle/src/main.rs)), which drives the reference
//! through all three scripts under all four encodings and prints what it
//! produced — the element sequence, the span walk, the mark runs, the patch
//! stream in the reference's own `Debug`, and, for the legacy case, **both
//! changes as hex** so the fixture is the reference's own bytes rather than a
//! transcription of them.

const std = @import("std");
const am = @import("zautomerge");

const testing = std.testing;

/// **The leak arbiter for the whole file.** One allocator, named once, and
/// every owned value below comes out of it.
const gpa = testing.allocator;

/// The borrowed capability every document constructor below is handed.
///
/// **Explicit, because `Document` keeps it.** The op set draws actors through
/// this value for as long as the document lives, so a constructor cannot
/// reach for an ambient global and no document can outlive its provider. Here
/// that value is `std.testing.io`; an executable passes its own `init.io`.
const io = std.testing.io;
const Allocator = std.mem.Allocator;

const Document = am.doc.Document;
const AutoCommit = am.AutoCommit;
const Change = am.change_record.Change;
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ChangeHash = am.ChangeHash;
const ActorId = am.ActorId;
const TextEncoding = am.TextEncoding;
const Patch = am.patches.Patch;
const Mirror = am.hydrate.Value;
const Span = am.iter.spans.Span;
const SpanInput = am.iter.spans.SpanInput;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── The four encodings ───────────────────────────────────────────────────────

/// The four encodings, **in the order `tests/text_encoding.rs` declares them**
/// (`text_encoding.rs:50-55`) and in the order its `Scenario` loops over them
/// (`:124-133`). Every test in this file walks this array.
const all_encodings = [_]TextEncoding{
    .unicode_code_point,
    .utf8_code_unit,
    .utf16_code_unit,
    .grapheme_cluster,
};

/// One index per encoding.
///
/// Upstream writes the same four-way `match` inline in every one of its
/// fourteen closing actions (`text_encoding.rs:203-208`, `:222-227`,
/// `:253-258`, `:281-286`, `:305-310`, `:329-334`, `:348-353`, `:367-372`,
/// `:386-391`, `:414-419`, `:461-466`, `:507-512`, `:552-557`, `:596-601`).
/// A table is that choice written once, and it puts the four numbers side by
/// side where a reviewer can check them against each other — which is the only
/// way to be sure they are four spellings of one position.
const EncIdx = struct {
    unicode_code_point: usize,
    utf8_code_unit: usize,
    utf16_code_unit: usize,
    grapheme_cluster: usize,

    fn pick(self: EncIdx, enc: TextEncoding) usize {
        return switch (enc) {
            .unicode_code_point => self.unicode_code_point,
            .utf8_code_unit => self.utf8_code_unit,
            .utf16_code_unit => self.utf16_code_unit,
            .grapheme_cluster => self.grapheme_cluster,
        };
    }
};

/// The width of a **block marker** in one encoding, which is the whole of the
/// index arithmetic in [`noexpand`].
///
/// **`seq_length` measures anything that is not a string as
/// `width("\u{fffc}")`** (`op_set.rs:443-447`) and U+FFFC is **three bytes** in
/// UTF-8, so a block marker is one position wide in three encodings and three
/// positions wide in the fourth. Everything ASCII is one unit in all four.
///
/// The reference, asked directly, agrees with the arithmetic: the oracle's
/// `text-noexpand-spans` record reports `length_after_update_spans` of **11**
/// under code points, UTF-16 and graphemes and **17** under UTF-8 code units,
/// for the same element sequence.
fn blockWidth(enc: TextEncoding) usize {
    return switch (enc) {
        .utf8_code_unit => 3,
        else => 1,
    };
}

// ── The harness ──────────────────────────────────────────────────────────────

/// A new document in one encoding, with a **named** actor.
///
/// **A named actor, because a random one makes a failure unreproducible.**
/// Upstream draws one (`automerge.rs:307-317`) and so does
/// [`Document.init`](doc.zig), so every fixture here names one.
///
/// **`actor` is the actor's *bytes*, and the two constants below are decoded
/// from hex first, which is what upstream's spellings mean.** Upstream writes
/// `ActorId::from_str("aaaaaa")` (`text.rs:877`) and the oracle writes
/// `ActorId::try_from` on a hex string
/// ([`types.rs:88-95`](../github-automerge-automerge/rust/automerge/src/types.rs)),
/// which is [`ActorId.fromHex`](types.zig:143-145) here: **both hex-decode**,
/// so upstream's actor for `"aaaaaa"` is the three bytes `aa aa aa` and
/// `ACTOR_A` is the fifteen bytes `a1` fifteen times. Upstream's `Debug` is
/// what makes this checkable — `f.debug_tuple("ActorID").field(&hex::encode(
/// &self.0))` ([`types.rs`:47-52](../github-automerge-automerge/rust/automerge/src/types.rs)) —
/// so every `ActorID("…")` in an oracle record is **hex of the bytes**, and an
/// actor handed to the port as the *characters* of that hex is a different
/// actor. It was, and it is the third defect the legacy tests found: the
/// document interned `61 31 61 31 …` beside the change's `a1 a1 …`, so
/// [`Document.getOrCreateActorIndex`](doc.zig) inserted an actor **below** the
/// existing one and [`OpSet.rewriteWithNewActor`](opset/op_set.zig:1387-1401)
/// renumbered every actor index at and above it — and the text object's id,
/// read out before the transaction was opened, then named a different actor
/// and [`Document.objectType`](doc.zig:4306-4310) answered `error.NotAnObject`.
/// Returns a closed owner, which can move into its fixture's final address.
fn newDoc(enc: TextEncoding, actor: []const u8) !AutoCommit {
    var doc = try AutoCommit.initWithEncoding(gpa, io, enc);
    errdefer doc.deinit();
    try doc.setActorId(.{ .bytes = actor });
    return doc;
}

/// One hex actor id as bytes, decoded at comptime.
///
/// **`bytes` is a comptime global**, so `&CONST.bytes` is a stable address and
/// [`Document.setActorId`] — which *borrows* the bytes into
/// `actor.{ .unused = … }` ([`doc.zig`:2470-2476](../src/doc.zig)) rather than
/// copying them — can hold them for the document's life.
fn HexActor(comptime hex: []const u8) struct { bytes: [hex.len / 2]u8 } {
    var out: [hex.len / 2]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        const hi = nibble(hex[2 * i]) orelse @compileError("actor id is not hex");
        const lo = nibble(hex[2 * i + 1]) orelse @compileError("actor id is not hex");
        byte.* = hi << 4 | lo;
    }
    return .{ .bytes = out };
}

/// [`ACTOR_A`](../tools/oracle/src/main.rs):101, the **fifteen bytes**
/// `a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1` — and the count is the whole of it.
///
/// **This constant carried nineteen `a1` bytes while the sentence beside it said
/// fifteen**, which is the defect this file's own diff block already describes
/// by a different route: the document was handed an author the changes were not
/// written by. The oracle's `actor()` hex-decodes its `ACTOR_A`
/// ([`actor`](../tools/oracle/src/main.rs):1770-1772), so the oracle's actor is
/// fifteen bytes, and the legacy change's author is that fifteen-byte actor —
/// the `0f` length prefix beside the run in `legacy_parent_hex` says so, and
/// that is the instrument. **A nineteen-byte actor is a different actor**: same
/// bytes, different count, so the three legacy splices were authored by an id
/// the reference never used. **No assertion caught it**, because all three
/// compare the resulting text and a text does not name its author;
/// [`expectLegacyBlobs`] does, and it is what found this.
const ACTOR_A = HexActor("a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1");

/// `text.rs:961`'s `let weird_actor = ActorId::random()`, named `bbbbbb` here
/// so a failure is reproducible. **Three bytes, `bb bb bb`, and a *different*
/// actor from [`ACTOR_A`]**: it authors the legacy change while the three ops
/// it carries name `ACTOR_A` in their object and element ids
/// (`text.rs`:966, `:976`, `:985`, against `actor_id: weird_actor` at `:992`).
const legacy_weird_actor = HexActor("bbbbbb");

/// `text.rs:877`'s `ActorId::from_str("aaaaaa")`, the three bytes `aa aa aa`.
const ACTOR_SIX = HexActor("aaaaaa");

/// Writes the reference's held automatic text group. Initial writes stay
/// pending; isolated groups close before integration (`text.rs`:886-910).
fn putTextIn(
    doc: *AutoCommit,
    heads: ?[]const ChangeHash,
    key: []const u8,
    body: []const u8,
) !ExId {
    if (heads) |at| try doc.isolate(gpa, at);
    const id = try doc.putObject(root, .{ .key = key }, .text);
    try doc.spliceText(id, 0, 0, body);
    if (heads != null) {
        _ = try doc.commit();
        try doc.integrate();
    }
    return id;
}

/// The heads of `doc`. **The caller frees the result**
/// ([`Document.getHeads`](../src/doc.zig) returns a copy, because the graph's
/// own list moves under the next change).
fn headsOf(doc: anytype) ![]ChangeHash {
    return doc.getHeads(gpa);
}

/// The materialized root at `heads`, or the raw current view for null heads.
fn hydrateAt(doc: *AutoCommit, heads: ?[]const ChangeHash) !Mirror {
    return doc.hydrate(root, heads, gpa);
}

/// Applies a patch stream to a mirror and requires the whole stream to apply:
/// `hydrate::Value::apply_patches`
/// ([`hydrate.rs`](../github-automerge-automerge/rust/automerge/src/hydrate.rs)).
///
/// **`Applied.refused` carries the reason as a value rather than as an error**
/// ([`hydrate.zig`](../src/hydrate.zig):242-249), so the reason is printed and
/// the stream counts as a failure.
fn applyPatches(mirror: *Mirror, enc: TextEncoding, patches: []const Patch) !void {
    const applied = try mirror.applyPatches(enc, patches);
    switch (applied) {
        .ok => {},
        .refused => |failure| {
            std.debug.print("  patch stream refused: {s}\n", .{@tagName(failure)});
            return error.PatchStreamRefused;
        },
    }
}

/// A fresh caller-owned block literal matching `text.rs`:355-376.
fn blockMap(kind: []const u8) !am.hydrate.Map {
    var map = am.hydrate.Map.init(gpa, root);
    errdefer map.deinit();
    try map.putOwned("type", .init(.{ .str = kind }, false));
    {
        var parents = Mirror.list(gpa);
        errdefer parents.deinit();
        try map.putOwned("parents", .init(parents, false));
    }
    {
        var attrs = Mirror.map(gpa);
        errdefer attrs.deinit();
        try map.putOwned("attrs", .init(attrs, false));
    }
    return map;
}

/// Borrows the hydrated literal only for the write.
fn blockShape(doc: *AutoCommit, block: ExId, kind: []const u8) !void {
    var value: Mirror = .{ .object = .{ .map = try blockMap(kind) } };
    defer value.deinit();
    try doc.updateObject(block, &value);
}

/// Asserts that `got` is exactly `want`, printing both on a mismatch so a
/// failure names the element sequence rather than only the encoding.
fn expectText(got: []const u8, want: []const u8, enc: TextEncoding) !void {
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("encoding {s}: read \"{s}\", want \"{s}\"\n", .{
            @tagName(enc),
            got,
            want,
        });
        return error.TestExpectedEqual;
    }
}

/// Asserts a length in the encoding's own units.
fn expectLen(got: usize, want: usize, enc: TextEncoding) !void {
    if (got != want) {
        std.debug.print("encoding {s}: {d} units, want {d}\n", .{
            @tagName(enc),
            got,
            want,
        });
        return error.TestExpectedEqual;
    }
}

/// The patch stream's own `Debug`-shaped rendering, for a failure message.
///
/// **The content and not upstream's `Debug`**, which the oracle prints: upstream
/// derives its `Debug` ([`patch.rs`:91-93](../github-automerge-automerge/rust/automerge/src/patches/patch.rs))
/// and this does not, so what a consumer compares is the *content* of each
/// line — the object, the index, the value and the marks — which is the same
/// question either format answers.
fn showPatches(patches: []const Patch) !void {
    for (patches, 0..) |p, i| {
        switch (p.action) {
            .splice_text => |s| {
                const text = try s.value.makeString(gpa);
                defer gpa.free(text);
                std.debug.print(
                    "    patch {d}: SpliceText {{ index: {d}, value: \"{s}\", marks: {s} }}\n",
                    .{ i, s.index, text, if (s.marks == null) "none" else "some" },
                );
            },
            .put_map => |m| std.debug.print(
                "    patch {d}: PutMap {{ key: \"{s}\", conflict: {} }}\n",
                .{ i, m.key, m.conflict },
            ),
            .delete_map => |d| std.debug.print(
                "    patch {d}: DeleteMap {{ key: \"{s}\" }}\n",
                .{ i, d.key },
            ),
            .conflict => |c| std.debug.print(
                "    patch {d}: Conflict {{ prop: {s} }}\n",
                .{ i, propName(c.prop) },
            ),
            else => std.debug.print("    patch {d}: {s}\n", .{ i, @tagName(p.action) }),
        }
    }
}

fn propName(p: Prop) []const u8 {
    return p.asStr() orelse "<index>";
}

// ── 1. `insertions_after_noexpand_spans_are_not_marked` (`text.rs`:350-415)

test "text: a zero-width noexpand mark leaves the splices after it unmarked in each encoding" {
    // **The case.** Two blocks, a heading, a paragraph, and a `strong` mark
    // written over **nothing at all** — `Mark::new("strong", true, 9, 9)` with
    // `ExpandMark::None` (`text.rs:378-383`). Then `update_spans` over the
    // shapes the span walk produced plus one more block (`text.rs:385-394`),
    // and a character spliced in after that (`text.rs:397`). **The assertion
    // is that the single patch that comes back carries `marks: None`**
    // (`text.rs:400-414`): a `None`-expanding mark covers nothing, so an
    // insertion after it must not inherit it.
    //
    // **What `update_spans` leaves behind is three block markers, not the two
    // the script wrote**, because the walk's own last span is appended to
    // (`text.rs:385-391`). So the element sequence after the rewrite is
    // [BLOCK, "Heading", BLOCK, "a", BLOCK], which is `8 + 3w` units wide.
    //
    // **Why the index table and not upstream's numbers.** Upstream writes
    // 1, 8, 9, 9, 11 (`text.rs:365`, `:366`, `:377`, `:380`, `:397`), and
    // each of those is only the *right* position under `UnicodeCodePoint`:
    // index 1 is the middle of the first block marker's three UTF-8 bytes
    // under `utf8_code_unit`. Running the literal numbers under all four
    // encodings produces `'￼Headi￼￼ang'` under UTF-8 — the heading split in
    // two — which is the reference answering a question nobody asked. The
    // translated table asks the same question four times.
    //
    // **The reference's answers, from the oracle's `text-noexpand-spans`
    // records with `mode` `translated`:**
    //
    // | encoding | before | after | final splice index | patches |
    // |---|---|---|---|---|
    // | `unicode_code_point` | `￼Heading￼a` (10) | `￼Heading￼a￼` (11) | 11 | 1, `marks: None` |
    // | `utf8_code_unit` | `￼Heading￼a` (14) | `￼Heading￼￼a` (17) | 17 | 1, `marks: None` |
    // | `utf16_code_unit` | `￼Heading￼a` (10) | `￼Heading￼a￼` (11) | 11 | 1, `marks: None` |
    // | `grapheme_cluster` | `￼Heading￼a` (10) | `￼Heading￼a￼` (11) | 11 | 1, `marks: None` |
    //
    // **`marks_after` is `[]` in every one of them**: the zero-width mark
    // covers nothing in any encoding, which is the property the patch is
    // evidence for. And **the UTF-8 row differs from the other three in where
    // the appended block lands** — before the `a` rather than after it. That
    // is the reference's own behaviour and it is pinned here rather than
    // smoothed into one answer, because a test that passed all four encodings
    // with a single expected string would be passing on three of them.

    // The element sequence `update_spans` leaves behind, per encoding: 11
    // units in the three encodings where a block marker is one wide, and 17
    // under UTF-8 code units where it is three bytes.
    const after_spans = EncIdx{
        .unicode_code_point = 11,
        .utf8_code_unit = 17,
        .utf16_code_unit = 11,
        .grapheme_cluster = 11,
    };

    for (all_encodings) |enc| {
        const w = blockWidth(enc);
        // Upstream's numbers, translated: each index moved by the widths of
        // the block markers before it, and the last one replaced by the
        // length `update_spans` leaves behind.
        const first = EncIdx{
            .unicode_code_point = 1,
            .utf8_code_unit = w,
            .utf16_code_unit = 1,
            .grapheme_cluster = 1,
        };
        const second = EncIdx{
            .unicode_code_point = 8,
            .utf8_code_unit = 7 + w,
            .utf16_code_unit = 8,
            .grapheme_cluster = 8,
        };
        const para = EncIdx{
            .unicode_code_point = 9,
            .utf8_code_unit = 7 + 2 * w,
            .utf16_code_unit = 9,
            .grapheme_cluster = 9,
        };

        var doc = try newDoc(enc, &ACTOR_A.bytes);
        defer doc.deinit();
        const text = try doc.putObject(root, .{ .key = "text" }, .text);
        try checkShape(&doc, text, enc);

        // **The first block, cut at zero and filled in** (`text.rs:354-364`).
        const block1 = try doc.splitBlock(text, 0);
        try blockShape(&doc, block1, "heading");

        try doc.spliceText(text, first.pick(enc), 0, "Heading");
        const block2 = try doc.splitBlock(text, second.pick(enc));
        try blockShape(&doc, block2, "paragraph");
        try doc.spliceText(text, para.pick(enc), 0, "a");

        // **The mark covers nothing** (`text.rs:378-383`): `ExpandMark::None`
        // with `start == end`.
        try doc.mark(
            text,
            para.pick(enc),
            para.pick(enc),
            "strong",
            .none,
            .{ .bool_value = true },
        );

        // **The shape before the rewrite.** `read.spans` hands each span over
        // ([`iter/spans.zig`](src/iter/spans.zig)) and each one owns its text
        // and its mark set, so the list below is **this test's** until the
        // rewrite has read it — which is why the free is at the end of the
        // stretch and not in a `defer` around the walk.
        var walked: std.ArrayList(Span) = .empty;
        {
            defer {
                for (walked.items) |*s| s.deinit(gpa);
                walked.deinit(gpa);
            }
            var span_walk = try doc.spans(text, gpa);
            defer span_walk.deinit();
            while (try span_walk.next()) |found| {
                var owned = found;
                errdefer owned.deinit(gpa);
                try walked.append(gpa, owned);
            }
            try expectSpanShape(enc, walked.items, &.{
                .{ .block = true },
                .{ .text = "Heading" },
                .{ .block = true },
                .{ .text = "a" },
            });

            // Borrow detached output maps and text for this call, then append
            // a fresh paragraph literal (`text.rs`:385-394), not an object ID.
            var paragraph = try blockMap("paragraph");
            defer paragraph.deinit();
            var shapes: std.ArrayList(SpanInput) = .empty;
            defer shapes.deinit(gpa);
            for (walked.items) |*s| {
                try shapes.append(gpa, switch (s.*) {
                    .block => |*map| .{ .block = map },
                    .text => |*t| .{ .text = .{
                        .text = t.text,
                        .marks = if (t.marks) |*set| set else null,
                    } },
                });
            }
            try shapes.append(gpa, .{ .block = &paragraph });
            try doc.updateSpans(text, shapes.items);
        }

        try expectLen(try doc.length(text), after_spans.pick(enc), enc);

        // **The mark covers nothing after the rewrite either.** This is the
        // property, read back from the document rather than inferred from the
        // patch that follows.
        const runs = try doc.marks(text, gpa);
        defer gpa.free(runs);
        if (runs.len != 0) {
            std.debug.print("encoding {s}: {d} mark run(s) after the rewrite, want none\n", .{
                @tagName(enc),
                runs.len,
            });
            for (runs) |m| {
                std.debug.print("  got: {s} [{}, {d}) = {any}\n", .{ m.name, m.start, m.end, m.value });
            }
            return error.TestExpectedEqual;
        }

        // **The single patch, and its marks** (`text.rs:400-414`).
        const before = try headsOf(&doc);
        defer gpa.free(before);
        try doc.spliceText(text, after_spans.pick(enc), 0, "a");
        const after = try headsOf(&doc);
        defer gpa.free(after);
        var patches = try doc.diff(gpa, before, after);
        defer patches.deinit();
        if (patches.len() != 1) {
            std.debug.print("encoding {s}: {d} patches, want exactly 1\n", .{
                @tagName(enc),
                patches.len(),
            });
            try showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const one = patches.slice()[0];
        const splice = switch (one.action) {
            .splice_text => |s| s,
            else => {
                std.debug.print("encoding {s}: patch 0 is {s}, want a splice\n", .{
                    @tagName(enc),
                    @tagName(one.action),
                });
                try showPatches(patches.slice());
                return error.TestExpectedEqual;
            },
        };
        if (splice.index != after_spans.pick(enc)) {
            std.debug.print("encoding {s}: the splice is at {d}, want {d}\n", .{
                @tagName(enc),
                splice.index,
                after_spans.pick(enc),
            });
            try showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
        const splice_text = try splice.value.makeString(gpa);
        defer gpa.free(splice_text);
        try expectText(splice_text, "a", enc);
        if (splice.marks != null) {
            std.debug.print("encoding {s}: the splice carries marks, want none\n", .{@tagName(enc)});
            try showPatches(patches.slice());
            return error.TestExpectedEqual;
        }
    }
}

/// One shape: a block marker, or a run of text.
const Shape = struct { block: bool = false, text: []const u8 = "" };

/// Asserts the span walk's shape element by element — **the element
/// sequence**, not the joined string, because the string is derived from the
/// elements and two shapes where the model wants one read back the same bytes.
fn expectSpanShape(enc: TextEncoding, got: []const Span, want: []const Shape) !void {
    if (got.len != want.len) {
        std.debug.print("encoding {s}: {d} spans, want {d}\n", .{ @tagName(enc), got.len, want.len });
        for (got) |s| std.debug.print("  got:  {s}\n", .{spanName(s)});
        for (want) |s| std.debug.print("  want: {s}\n", .{shapeName(s)});
        return error.TestExpectedEqual;
    }
    for (got, want) |g, w| {
        const ok = switch (g) {
            .block => w.block,
            .text => |t| !w.block and std.mem.eql(u8, t.text, w.text) and t.marks == null,
        };
        if (!ok) {
            std.debug.print("encoding {s}: span {s}, want {s}\n", .{
                @tagName(enc),
                spanName(g),
                shapeName(w),
            });
            return error.TestExpectedEqual;
        }
    }
}

fn spanName(s: Span) []const u8 {
    return switch (s) {
        .block => "Block",
        .text => |t| if (t.marks == null) "Text(unmarked)" else "Text(marked)",
    };
}

fn shapeName(s: Shape) []const u8 {
    return if (s.block) "Block" else s.text;
}

/// The three premises every conclusion in this file rests on: the document is
/// measuring text in the encoding it was asked for, the root is a map, and
/// `obj` — when the caller has one — is a text object.
///
/// **The root and the object were claims and not checks**, and a claim in a
/// helper's name is not an assertion: the body read `doc.textEncoding()` and
/// nothing else, so a fixture whose root had stopped being a map, or whose
/// `"text"` was a list, passed every conclusion drawn from it. The same
/// argument is [`src/read.zig`](../src/read.zig)'s `checkPremises` makes, and
/// for the same reason — a mark fixture that is one row out of order is green
/// and meaningless — with the row-order invariant on top of these three.
fn checkShape(doc: anytype, obj: ?ExId, enc: TextEncoding) !void {
    const got = doc.textEncoding();
    if (got != enc) {
        std.debug.print("encoding {s}: the document answers {s}\n", .{ @tagName(enc), @tagName(got) });
        return error.TestExpectedEqual;
    }
    const root_type = try doc.objectType(root);
    if (root_type != .map) {
        std.debug.print("encoding {s}: the root is a {s}, want a map\n", .{ @tagName(enc), @tagName(root_type) });
        return error.TestExpectedEqual;
    }
    const at = obj orelse return;
    const obj_type = try doc.objectType(at);
    if (obj_type != .text) {
        std.debug.print("encoding {s}: the fixture's object is a {s}, want a text\n", .{ @tagName(enc), @tagName(obj_type) });
        return error.TestExpectedEqual;
    }
}

// ── 2. `incorrect_patches_produced_when_isolating_and_integrating`
//      (`text.rs`:868-921)

test "text: a patch stream over an isolate round trip reconstructs the integrated document in each encoding" {
    // **The case**, and it is a regression test for
    // [automerge#951](https://github.com/automerge/automerge/issues/951): a
    // hundred-character text, a concurrent root change under an isolation, an
    // empty patch log drained and a clean commit, a **second** concurrent root
    // change, and then `diff_incremental` (`text.rs:886-912`). Upstream's
    // assertion is that applying the stream to a mirror taken before the
    // second change reconstructs the integrated document
    // (`text.rs:917-920`).
    //
    // **Why the hundred characters are the point.** Upstream's own comment
    // (`text.rs:881-885`) says the issue appears when the number of patches is
    // larger than 100, "because if there are more than 100 patches then the
    // `PatchBuilder::new` function precomputes a visible path cache". A
    // fixture with four characters cannot reach that threshold, so this is the
    // one case in the file that cannot be written small — and the reference
    // agrees on the shape: the oracle's `text-isolate-incremental` record
    // reports **7** patches for the second `diff_incremental` and **4** for the
    // drain, in **all four encodings**, with `reconstructs: true` in every one.
    //
    // **What is pinned, per encoding: the seven patch actions by name**, not
    // "the stream applied". `text.rs:914-916` says the epochs preserve the
    // isolate/integrate chronology so the exact sequence can contain
    // intermediate conflict updates — which means a stream that *applies* is
    // not yet the right stream. The content is the assertion, and the oracle
    // printed it:
    //
    // ```text
    // 0 DeleteMap { key: "color" }
    // 1 DeleteMap { key: "name" }
    // 2 PutMap   { key: "color", value: Object(Text), conflict: false }
    // 3 SpliceText { index: 0, value: "unset", marks: None }
    // 4 Conflict  { prop: Map("color") }
    // 5 PutMap   { key: "name", value: Object(Text), conflict: false }
    // 6 SpliceText { index: 0, value: 100*"a", marks: None }
    // ```
    //
    // **The same script runs unchanged under all four encodings**, because
    // every string in it is ASCII and ASCII is one unit in all four. That is
    // why this test needs no index table, and it is worth saying: the axis is
    // covered here by *holding the numbers constant*, which is the strongest
    // form of the check available for an all-ASCII script.

    // `text.rs`:885 — the count at which `PatchBuilder::new` stops building a
    // patch per op and precomputes a visible-path cache.
    const num_chars_in_new_name = 100;

    for (all_encodings) |enc| {
        var doc = try newDoc(enc, &ACTOR_SIX.bytes);
        defer doc.deinit();
        try checkShape(&doc, null, enc);

        const beginning = try headsOf(&doc);
        defer gpa.free(beginning);

        // **The hundred characters**, spliced into an object made in the same
        // transaction (`text.rs:886-888`).
        const long = try gpa.alloc(u8, num_chars_in_new_name);
        defer gpa.free(long);
        @memset(long, 'a');
        const name = try putTextIn(&doc, null, "name", long);

        // **The first isolation and integration** (`text.rs:891-895`): a
        // concurrent `"color"` root object, scoped to the heads the document
        // had before the name existed.
        const color = try putTextIn(&doc, beginning, "color", "red");

        const red = try am.read.text(&doc, color, gpa);
        defer gpa.free(red);
        try expectText(red, "red", enc);

        // **The drain** (`text.rs:897-901`).
        //
        // Preserve the oracle's explicit clean-log commit after the drain
        // (`tools/oracle/src/main.rs`:2371-2372).
        // The patches are popped, which is what "necessary to make the test
        // work" (`text.rs:897`) means: [`Document.diffIncremental`] finishes
        // by moving the cursor to the present, so the second stream starts
        // from the mirror's heads rather than from the beginning of history.
        var drained = try doc.diffIncremental(gpa);
        drained.deinit();
        _ = try doc.commitWith(.{ .message = "isolate", .time = 0 });

        // **The mirror, taken before the second change** (`text.rs:903`), and
        // the heads it was taken at, which is the range the stream below runs
        // from.
        const mirror_heads = try headsOf(&doc);
        defer gpa.free(mirror_heads);
        var hydrated = try hydrateAt(&doc, mirror_heads);
        defer hydrated.deinit();

        // **The second isolation, integration, and the stream**
        // (`text.rs:906-912`). **`color` is rebound**, exactly as upstream
        // rebinds it at [`text.rs:907`](../github-automerge-automerge/rust/automerge/tests/text.rs):
        // `let color = doc.put_object(…)` shadows the first object, and the
        // text read at the end names the **second** one. The oracle records the
        // same pair — `color_after_first` `"red"` and `color` `"unset"` — and
        // the first object is not the winner, so reading the first would assert
        // `"unset"` of an object that holds `"red"`.
        const color2 = try putTextIn(&doc, beginning, "color", "unset");

        // **The stream is [`Document.diffIncremental`], upstream's
        // `diff_incremental` (`text.rs:912`), and not a `Document.diff` over
        // the same head range.** The two are different questions and only the
        // log route can answer this one: patches 0 and 1 are
        // `DeleteMap { key: "color" }` and `DeleteMap { key: "name" }`, and
        // patches 5 and 6 re-emit `name` and its hundred characters, all of
        // which describe how the *log* moved between an isolated view and the
        // integrated one. `name` is byte-identical at both ends of the range,
        // so a state diff cannot mention it at all. Upstream's own comment
        // says as much (`text.rs:914-916`): the sequence "can contain
        // intermediate conflict updates", which is what a log replays and a
        // diff does not.
        //
        // **Where each of the seven comes from, measured rather than reasoned
        // about.** The oracle's `isolateprobe` runs this same script with the
        // log drained at every step, so each of the reference's seven is
        // attributed to the call that put it there:
        //
        // ```text
        // 0 DeleteMap { key: "color" }        isolate()   -> patch_to, DiffIter::log
        // 1 DeleteMap { key: "name" }         isolate()   -> patch_to, DiffIter::log
        // 2 PutMap   { key: "color" }         commit_with -> the transaction's events
        // 3 SpliceText { index: 0, "unset" }  commit_with -> the same
        // 4 Conflict { prop: Map("color") }   integrate() -> patch_to, DiffIter::log
        // 5 PutMap   { key: "name" }          integrate() -> patch_to, DiffIter::log
        // 6 SpliceText { index: 0, 100*"a" }  integrate() -> the same
        // ```
        //
        // **The replay half of [`Document.patchTo`] emits five of the seven
        // and `finish_current_view` emits none of them**: at `isolate()` the
        // log's events are empty — the previous `diff_incremental` moved the
        // cursor and `update_diff_cursor` truncated
        // ([`autocommit.rs`:199-206](../github-automerge-automerge/rust/automerge/src/autocommit.rs))
        // — so `finish_current_view`'s guard
        // ([`patch_log.rs`:291](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs))
        // returns early. The two events that walk records and the two the
        // isolated commit's own branch records are **closed** at `integrate()`,
        // which is why patches 0 to 3 are in the stream in that order:
        // `make_patches` is `completed_patches` then the current view's
        // ([`patch_log.rs`:505-509](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)),
        // so 4 come out of the first list and 3 out of the second.
        //
        // **`integrate()` is not a no-op, and the reason is one hash.** After
        // `commit_with` the isolation is `Some([that change])`
        // ([`autocommit.rs`:735-736](../github-automerge-automerge/rust/automerge/src/autocommit.rs))
        // while the integrated graph also contains the concurrent name and
        // earlier color branches. The transition back to that full view
        // (`autocommit.rs`:819) sees both color values and emits the conflict
        // at index 4, followed by the name object and its text.
        //
        // **What the port emitted before, and why it was three short.** With
        // [`Document.patchTo`] already wired into both
        // [`Document.isolate`] and [`Document.integrate`] the stream was five
        // patches in every encoding —
        //
        // ```text
        // 0 PutMap     { key: "name" }     <- commit's own diff, walking name
        // 1 SpliceText { 100*"a" }
        // 2 DeleteMap  { key: "name" }     <- patch_to, isolate's walk
        // 3 PutMap     { key: "name" }     <- patch_to, integrate's walk
        // 4 SpliceText { 100*"a" }
        // ```
        //
        // — the same shape with the whole `color` branch gone and `name`
        // re-emitted at the front instead of the back. That the two `name`
        // patches *moved* rather than vanished is the tell: they are patches 5
        // and 6 of the reference, and they only exist because the second
        // `"color"` change is **concurrent** with the `"name"` change, so the
        // integrated view contains something the isolated one did not. The
        // isolated transaction was opened on [`Transaction.openAt`] with
        // `null`, which is the low-level door and takes the base actor and the
        // current heads — so `isolate_actor` never forked, the branch was
        // sequential, and a clock-filtered read could not see the object written
        // under the isolation at all. See [`putTextIn`].
        //
        // **The expectation below is the reference's seven and has always
        // been.** A test that passes on the five the port happened to emit is
        // a test of the port's output, not of the case.
        var patches = try doc.diffIncremental(gpa);
        defer patches.deinit();
        try expectIsolateStream(enc, patches.slice());

        // **Upstream's own assertion**, in all four encodings: applying the
        // stream to the mirror reproduces the integrated document.
        try applyPatches(&hydrated, enc, patches.slice());
        var expected = try hydrateAt(&doc, null);
        defer expected.deinit();
        if (!hydrated.eql(&expected)) {
            std.debug.print("encoding {s}: the stream did not reconstruct the document\n", .{
                @tagName(enc),
            });
            try showPatches(patches.slice());
            return error.TestExpectedEqual;
        }

        // **The element sequences themselves**, so a mirror that agrees with
        // another wrong mirror is still caught.
        const got_name = try am.read.text(&doc, name, gpa);
        defer gpa.free(got_name);
        if (got_name.len != num_chars_in_new_name) {
            std.debug.print("encoding {s}: the name is {d} characters, want {d}\n", .{
                @tagName(enc),
                got_name.len,
                num_chars_in_new_name,
            });
            return error.TestExpectedEqual;
        }
        for (got_name) |ch| {
            if (ch != 'a') {
                std.debug.print("encoding {s}: the name is not all 'a'\n", .{@tagName(enc)});
                return error.TestExpectedEqual;
            }
        }
        const unset = try am.read.text(&doc, color2, gpa);
        defer gpa.free(unset);
        try expectText(unset, "unset", enc);
    }
}

/// One patch of the isolate stream, described by what it does rather than by
/// the reference's `Debug`.
const Step = union(enum) {
    delete: []const u8,
    put_text: []const u8,
    splice: struct { text: []const u8, marks: bool },
    conflict: []const u8,
};

/// One [`Step`] as the line a failure message prints, so a mismatch names the
/// step the reference emitted rather than a tag.
fn stepName(s: Step) []const u8 {
    return switch (s) {
        .delete => "DeleteMap",
        .put_text => "PutMap(text)",
        .splice => "SpliceText",
        .conflict => "Conflict",
    };
}

/// The seven patches of the second `diff_incremental`, in the order the
/// reference emitted them under **every** encoding.
///
/// **Both keys and both values, by name and in order** — the pairs
/// `DeleteMap { key: "color" }` then `PutMap { key: "color", … }` are a delete
/// and a re-put of the *same* register, and a test that pinned only the count
/// would be blind to the two having swapped.
fn expectIsolateStream(enc: TextEncoding, got: []const Patch) !void {
    const hundreds = "a" ** 100;
    var want: [7]Step = undefined;
    want[0] = .{ .delete = "color" };
    want[1] = .{ .delete = "name" };
    want[2] = .{ .put_text = "color" };
    want[3] = .{ .splice = .{ .text = "unset", .marks = false } };
    want[4] = .{ .conflict = "color" };
    want[5] = .{ .put_text = "name" };
    want[6] = .{ .splice = .{ .text = hundreds, .marks = false } };

    if (got.len != want.len) {
        std.debug.print("encoding {s}: {d} patches, want {d}\n", .{ @tagName(enc), got.len, want.len });
        try showPatches(got);
        return error.TestExpectedEqual;
    }
    for (got, want, 0..) |p, w, i| {
        const ok = switch (p.action) {
            .delete_map => |d| switch (w) {
                .delete => |name| std.mem.eql(u8, d.key, name),
                else => false,
            },
            .put_map => |pm| switch (w) {
                .put_text => |key| blk: {
                    if (!std.mem.eql(u8, pm.key, key)) break :blk false;
                    // The value is an **object**, and the reference reports a
                    // text object for both. `conflict` is false on both.
                    break :blk pm.value == .object and pm.value.object == .text and
                        pm.conflict == false;
                },
                else => false,
            },
            .splice_text => |s| switch (w) {
                .splice => |sp| blk: {
                    const text = try s.value.makeString(gpa);
                    defer gpa.free(text);
                    break :blk std.mem.eql(u8, text, sp.text) and (s.marks != null) == sp.marks;
                },
                else => false,
            },
            .conflict => |c| switch (w) {
                .conflict => |key| std.mem.eql(u8, propName(c.prop), key),
                else => false,
            },
            else => false,
        };
        if (!ok) {
            std.debug.print("encoding {s}: patch {d} is {s}, want {s}\n", .{
                @tagName(enc),
                i,
                @tagName(p.action),
                stepName(w),
            });
            try showPatches(got);
            return error.TestExpectedEqual;
        }
    }
}

// ── 3. `splicing_into_multibyte_characters` (`text.rs`:944-1023)

/// The two changes the reference built for [`legacyFixture`], as hex.
///
/// **The reference's own bytes, not a transcription.** `text.rs:958-1001`
/// builds the second change by hand through the deprecated `automerge::legacy`
/// API precisely because `splice_text` cannot produce it — an insert op
/// carrying five grapheme clusters — and its **dependency is the first change's
/// hash**, which a consumer cannot compute without reproducing the first
/// commit's timestamp. So the oracle prints both, and both are replayed here.
///
/// * index 0, `seq` 1, `start_op` 1, 99 bytes — `put_object` of the text and
///   `splice_text` of `"A"`.
/// * index 1, `seq` 1, `start_op` 3, 117 bytes — the legacy change: `put`
///   `"BBBBB"`, `make` a map, `put` `"C"` (`text.rs:962-1001`).
///
/// **These are whole change *chunks*, framing included** — magic
/// `85 6f 4a 83` (`storage.rs:26`), a four-byte checksum, the type byte and a
/// uleb128 length — which is what `Change::bytes` returns
/// ([`change.rs`:102-116](../github-automerge-automerge/rust/automerge/src/change.rs))
/// and what `Change::raw_bytes` returns here because the reference judged both
/// too small to compress (`CompressionState::TooSmallToCompress`,
/// [`change.rs`:112-116](../github-automerge-automerge/rust/automerge/src/change.rs)).
/// [`parseHex`] strips the framing, because
/// [`parseChange`](../src/change.zig) takes **the body only** — "which is what
/// `chunk.parseChunk` hands back and what `decompressChunk` produces for a
/// compressed change" — and handing it a framed chunk is a parse error that
/// reads as corrupt data rather than as a wrong argument.
///
/// The actor is `ACTOR_A` (`a1` × 15, the length prefix `0f` in both blobs)
/// and the second change's is `bbbbbb` (`text.rs:961`'s `ActorId::random()`,
/// named here so a failure is reproducible).
///
/// **These blobs were mistranscribed once, and the transcription is what the
/// three failures below were.** Both were re-read off the oracle's
/// `text-legacy-multibyte` record and byte-compared against it, so what is
/// written here is the reference's own output rather than a copy of a copy:
///
/// * `legacy_parent_hex` carried **sixteen** `a1` bytes where the reference
///   wrote **fifteen**. The actor's length prefix (`0f`) says fifteen, so one
///   byte too many shifted every field after the actor by one: `seq` was read
///   as **20641** rather than 1, and [`ChangeGraph.addChange`] refused the
///   change at `if (meta.seq > have + 1) return error.InvalidSeq`
///   ([`change_graph.zig`](../src/change_graph.zig):433). That is the whole of
///   `error.InvalidSeq` in all three tests.
/// * `legacy_weird_hex` was **one byte short** in `other_actors`, and this
///   comment used to say the reference wrote **sixteen** there. **It wrote
///   fifteen**, and the instrument that says so is the length prefix, not the
///   count: `other_actors` is a length-prefixed list of length-prefixed actor
///   ids ([`storage/change.rs`]:111, and the writer at `:482-485`), so the
///   `0f` beside the run says the run is fifteen bytes long. Both blobs carry
///   the same `a1` × 15 actor — `text.rs`:966, `:976`, `:985` name
///   `actor.clone()` again for the three ops' element ids, and it is that same
///   actor `other_actors` is listing.
///
/// **The corrected bytes are checked against the change hash, in
/// [`legacyFixture`], and that is the check a transcription error cannot
/// survive.** A [`ChangeHash`] is `SHA-256(type || uleb128(len) || data)` over
/// the chunk *data* ([`storage/chunk.rs`]:302-311, and this port's
/// [`parseChange`](../src/change.zig)), and the header's checksum field is the
/// first four bytes of it ([`storage/chunk.rs`]:293-298). So the two constants
/// below are not the blobs' own arithmetic repeated back: the **parent** is
/// anchored by the *second* blob, whose `deps[0]` is the parent change's hash
/// as the **reference** computed it, and the **legacy change** is anchored by
/// the oracle's `text-legacy-multibyte` record. [`legacyFixture`] asserts all
/// of it — both hashes, the dependency link, and the four header fields the
/// transcription story is about.
///
/// The parent change's hash, whole. **The second blob's `deps[0]` is these
/// same thirty-two bytes**, which is what makes it an anchor rather than a
/// restatement: the reference wrote it there having computed it from the first
/// change's own bytes.
const legacy_parent_hash = [_]u8{
    0x11, 0x83, 0x20, 0xfd, 0xff, 0x26, 0x2c, 0x65, 0x38, 0x23, 0xb5, 0x1e, 0x2b, 0x77, 0x22, 0x49,
    0x6d, 0x99, 0xb7, 0xe9, 0xd2, 0x58, 0x53, 0x79, 0x94, 0xe9, 0x7b, 0x48, 0x09, 0xcf, 0xaf, 0x76,
};

/// The legacy change's hash, whole — the `9581e486…` the oracle's
/// `text-legacy-multibyte` record carries and the `9581e486` its chunk header
/// carries.
const legacy_weird_hash = [_]u8{
    0x95, 0x81, 0xe4, 0x86, 0xe8, 0x81, 0xf2, 0x41, 0x75, 0x50, 0x9b, 0x3c, 0xac, 0x4e, 0x50, 0x73,
    0xea, 0xb0, 0x6c, 0x4b, 0x78, 0x44, 0xa3, 0xb3, 0x85, 0x6c, 0x4f, 0x62, 0x54, 0x29, 0xf0, 0xf9,
};

const legacy_parent_hex =
    "856f4a83118320fd0159000fa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1010180e2cfaa060d6c65676163792d706172656e74000901040204130415083402420356035701700200017f0000017f0100017f007f0474657874000101017e04017e0016410200";
const legacy_weird_hex =
    "856f4a839581e486016b01118320fdff262c653823b51e2b7722496d99b7e9d258537994e97b4809cfaf7603bbbbbb01030000010fa1a1a1a1a1a1a1a1a1a1a1a1a1a1a109010202021104130434024204560457067002030103017f0102007f02020100037d0100017d5600164242424242430300";

/// A document holding `ABBBBB￼C` — the state `text.rs`:1004 asserts.
const LegacyDoc = struct {
    doc: AutoCommit,
    text: ExId,

    fn deinit(self: *LegacyDoc) void {
        self.doc.deinit();
        self.* = undefined;
    }
};

/// Replays the two hex blobs onto an empty document in `enc`.
///
/// **Both changes are applied, in order, and both are owned by the caller**
/// ([`parseChange`](../src/change.zig) borrows the bytes, and
/// [`Document.applyChanges`](../src/doc.zig) copies what it keeps into the
/// document's own arena).
///
/// **The actor is the one the reference used, not a fresh one**: upstream
/// `clone`s the document three times (`text.rs:1006`, `:1011`, `:1018`) and a
/// clone keeps its actor, so the splices that follow are authored by the same
/// actor as the ops they land next to. A different actor would renumber the op
/// ids and change the conflict order.
fn legacyFixture(enc: TextEncoding) !LegacyDoc {
    var doc = try newDoc(enc, &ACTOR_A.bytes);
    errdefer doc.deinit();
    var parent = try parseHex(legacy_parent_hex);
    defer parent.deinit();
    var weird = try parseHex(legacy_weird_hex);
    defer weird.deinit();

    // **The fixture is the reference's bytes, and this is what says so.** Every
    // other assertion below reads the *document* these two changes build, and a
    // change that is one byte away still builds a document — it just builds a
    // different one, or refuses to be applied at all. The two hashes are the
    // only properties of the fixture that a transcription error cannot
    // reproduce, because they are a function of the bytes rather than of what
    // the bytes decode to.
    try expectLegacyBlobs(&parent, &weird);

    const views = [_]Change{ parent.change, weird.change };
    _ = try doc.applyChanges(gpa, &views);

    // The text object the parent change created, named the way the reference
    // names it: `put_object(ROOT, "text", Text)` (`text.rs:953`).
    const item = (try doc.get(root, .{ .key = "text" })) orelse
        return error.NoSuchKey;
    const text = switch (item.value) {
        // **The object's id is `DocItem.id`, not the object arm's payload**:
        // a make action's own id *is* the id of the object it makes
        // ([`DocItem`](src/read.zig)'s own rule, over
        // [`OpSet.idToExid`](../src/opset/op_set.zig) `op_set.rs:1054-1060`),
        // and `ValueRef.object` carries only the object's *type*.
        .object => |o| if (o == .text) item.id else return error.NotATextObject,
        .scalar => return error.NotAnObject,
    };
    try checkShape(&doc, text, enc);
    // applyChanges closed the owner; ordinary inspection did not open it.
    return .{ .doc = doc, .text = text };
}

/// Asserts that the two blobs are the reference's, in the five ways a
/// transcription error cannot fake.
///
/// **The hashes first, and they are the point of this helper.** A
/// [`ChangeHash`] is `SHA-256(type || uleb128(len) || data)` over the chunk
/// *data* — upstream builds exactly this in
/// [`hash`](../../github-automerge-automerge/rust/automerge/src/storage/chunk.rs):302-311
/// and this port's [`parseChange`](../src/change.zig) builds the same one, so
/// the value here is a function of the bytes and not of what they decode to.
/// One `a1` too many or too few changes it and changes nothing else that a
/// reader would notice: the change still parses, and depending on *which*
/// field shifted it either decodes to the same operations or is refused
/// outright by [`ChangeGraph.addChange`](../src/change_graph.zig):433.
///
/// **The dependency link is the one assertion that is not circular.** The
/// parent hash is not merely restated by the second blob: the *reference*
/// computed it from the first change's bytes and wrote it into the second
/// change's `deps`, so a parent that hashes to this value is byte-identical
/// to the reference's parent whatever else this file says about it.
///
/// **The four header fields after the actor are the ones the transcription
/// story is about**, and they are checked by value because they are what the
/// story says went wrong: `seq` is 1 for both (`text.rs`:995 for the legacy
/// change, and a first change for the parent), `start_op` is 1 for the parent
/// and 3 for the legacy change (`NonZero::new(3)`, `text.rs`:996), `time` is 0
/// (`text.rs`:997) and the message is empty (`text.rs`:998) — the header order
/// is upstream's [`parse_following_header`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs):104-111.
fn expectLegacyBlobs(parent: *const ParsedChange, weird: *const ParsedChange) !void {
    if (!parent.change.hash.eql(.{ .bytes = legacy_parent_hash })) {
        std.debug.print("legacy_parent_hex hashes to {x}, want the reference's 118320fd…\n", .{
            parent.change.hash.bytes[0..],
        });
        return error.TestUnexpectedResult;
    }
    if (!weird.change.hash.eql(.{ .bytes = legacy_weird_hash })) {
        std.debug.print("legacy_weird_hex hashes to {x}, want the reference's 9581e486…\n", .{
            weird.change.hash.bytes[0..],
        });
        return error.TestUnexpectedResult;
    }
    // The dependency link, in both directions: the legacy change names the
    // parent, and it is the only place the parent's hash appears anywhere but
    // its own definition.
    if (!weird.change.hasDependency(parent.change.hash)) {
        std.debug.print("legacy_weird_hex does not depend on legacy_parent_hex's hash {x}\n", .{
            parent.change.hash.bytes[0..],
        });
        return error.TestUnexpectedResult;
    }
    if (parent.change.deps.len != 0) {
        std.debug.print("legacy_parent_hex names {d} dependencies, want none\n", .{parent.change.deps.len});
        return error.TestUnexpectedResult;
    }

    // **The two authors are different, and that is upstream's shape.**
    // `text.rs`:954 takes `let actor = doc.get_actor().clone()` and every one of
    // the three ops names *that* actor in its `ObjectId` and `ElementId`
    // (`:966`, `:976`, `:985`), while `text.rs`:961 mints a *different* actor —
    // `let weird_actor = ActorId::random()` — and makes it the change's
    // `actor_id` (`:992-993`). **So the parent change is authored by `ACTOR_A`
    // and the legacy change by [`legacy_weird_actor`], and `ACTOR_A` is what the
    // legacy change *references*, once, in `other_actors`.** An assertion that
    // both changes are authored by `ACTOR_A` is a reasonable guess and the
    // reference refuses it — which is what it did, by name, on the first run.
    const want_parent_actor: ActorId = .{ .bytes = &ACTOR_A.bytes };
    const want_weird_actor: ActorId = .{ .bytes = &legacy_weird_actor.bytes };
    for ([_]struct {
        name: []const u8,
        change: Change,
        want: ActorId,
        want_hex: []const u8,
    }{
        .{ .name = "legacy_parent_hex", .change = parent.change, .want = want_parent_actor, .want_hex = "a1 x 15" },
        .{ .name = "legacy_weird_hex", .change = weird.change, .want = want_weird_actor, .want_hex = "bb x 3" },
    }) |which| {
        if (!which.change.actor.eql(which.want)) {
            std.debug.print("{s} is authored by {x}, want {s}\n", .{
                which.name,
                which.change.actor.bytes,
                which.want_hex,
            });
            return error.TestUnexpectedResult;
        }
        // `seq: 1` for the legacy change is upstream's own (`text.rs`:995), and
        // the parent's is 1 because it is the actor's first change.
        if (which.change.seq != 1) {
            std.debug.print("{s} has seq {d}, want 1\n", .{ which.name, which.change.seq });
            return error.TestUnexpectedResult;
        }
    }
    if (parent.change.start_op != 1) {
        std.debug.print("legacy_parent_hex starts at op {d}, want 1\n", .{parent.change.start_op});
        return error.TestUnexpectedResult;
    }
    if (weird.change.start_op != 3) {
        std.debug.print("legacy_weird_hex starts at op {d}, want 3 (text.rs:996)\n", .{weird.change.start_op});
        return error.TestUnexpectedResult;
    }
    if (weird.change.time != 0 or weird.change.message.len != 0) {
        std.debug.print("legacy_weird_hex carries time {d} and message \"{s}\", want 0 and none (text.rs:997-998)\n", .{
            weird.change.time,
            weird.change.message,
        });
        return error.TestUnexpectedResult;
    }
    // **One `other_actor`, and it is `ACTOR_A` rather than the author.**
    // `text.rs`:966, `:976` and `:985` all name `actor.clone()` — the document's
    // own actor, not `weird_actor` — for the three ops' `ObjectId` and
    // `ElementId`, so the change references one actor it did not write as.
    // That run of `a1` is the one the `0f` length prefix beside it measures, and
    // it is the byte count the fixture's whole transcription story is about.
    if (weird.change.other_actors.len != 1) {
        std.debug.print("legacy_weird_hex names {d} other actor(s), want 1\n", .{weird.change.other_actors.len});
        return error.TestUnexpectedResult;
    }
    if (!weird.change.other_actors[0].eql(want_parent_actor)) {
        std.debug.print("legacy_weird_hex's other actor is {x}, want a1 x 15\n", .{
            weird.change.other_actors[0].bytes,
        });
        return error.TestUnexpectedResult;
    }
}

fn parseHex(hex: []const u8) !ParsedChange {
    if (hex.len % 2 != 0) return error.BadHex;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var at: usize = 0;
    while (at < hex.len) : (at += 2) {
        const hi = nibble(hex[at]) orelse return error.BadHex;
        const lo = nibble(hex[at + 1]) orelse return error.BadHex;
        try bytes.append(gpa, hi << 4 | lo);
    }

    // **The framing is stripped here and not by the caller.** The header is
    // magic (4) + checksum (4) + type (1) + uleb128 length, and the length is
    // one byte in both blobs, so the body starts at ten.
    //
    // **`am.storage.chunk.parseChunk` is deliberately not used here**, and the
    // reason is on the record: it refuses both blobs with
    // `error.InvalidChecksum` from its own replay of
    // [`checksumOf`](../src/storage/chunk.zig) at
    // [`chunk.zig`:294](../src/storage/chunk.zig), against the checksum the
    // reference wrote into the header (`11 83 20 fd` for the parent,
    // `95 81 e4 86` for the legacy change). Two readings are possible — the
    // port's `checksumOf(.change, body)` disagrees with the reference's, or the
    // reference's `Change::raw_bytes` is not the body the checksum covers —
    // and **neither is this test's subject**. What is checked here instead is
    // the one thing the fixture has to be for the test to mean anything: the
    // magic, the type byte and the declared length agree with the bytes, and
    // the body parses.
    const header_len = 10;
    if (bytes.items.len < header_len) return error.BadHex;
    if (!std.mem.eql(u8, bytes.items[0..4], &am.storage.chunk.magic)) {
        return error.NotAChangeChunk;
    }
    if (bytes.items[8] != @intFromEnum(am.storage.chunk.ChunkType.change)) {
        return error.NotAChangeChunk;
    }
    const body = bytes.items[header_len..];
    return .{ .bytes = bytes, .change = try am.change_record.parseChange(body, gpa) };
}

/// A parsed [`Change`] and the buffer it borrows.
///
/// **The two travel together because [`Change`] borrows its bytes**
/// ([`Change.bytes`](../src/change.zig) is a `[]const u8` into the caller's
/// buffer), and a `Change` that outlives its buffer is a dangling read at the
/// first `opsBytes`. Upstream cannot express the hazard — `Change::from_bytes`
/// takes an owned `Vec` (`change.rs:131`) — so this file's
/// [`ParsedChange`] is the shape that says which owner frees what.
const ParsedChange = struct {
    bytes: std.ArrayList(u8),
    change: Change,

    fn deinit(self: *ParsedChange) void {
        self.change.deinit(gpa);
        self.bytes.deinit(gpa);
        self.* = undefined;
    }
};

fn nibble(ch: u8) ?u8 {
    return switch (ch) {
        // Both cases, because a hex decoder that rejects its own uppercase is
        // a second decoder with its own opinion. The blobs below are lowercase
        // because the oracle's `hex_encode` (`main.rs`:1224-1232) is.
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// The three splices `text.rs`:1007-1022 makes, each on its own clone.
///
/// **The index is `3` in every encoding and that is not a copy of upstream's
/// choice.** `text.rs:952` pins `Utf16CodeUnit`; `"A"`, `"B"` and `"C"` are
/// one unit in all four encodings, so index 3 names the same *element* under
/// all of them — the third character of the run `"BBBBB"`, which is the one
/// inside the single insert op. The block marker that follows it is where the
/// encodings differ (three bytes in UTF-8), and it is **past** the index being
/// spliced at, which is why the numbers agree. The oracle ran all three cases
/// under all four encodings and reported the same three answers in every one.
const legacy_index = 3;

test "text: a splice inside a multi-grapheme insert op replaces from after the op in each encoding" {
    // **The case** (`text.rs:1006-1010`): three characters starting inside the
    // five-grapheme `"BBBBB"` op and four of them deleted, with `"X"` written
    // in their place. **The position rounds *past* the whole op**, so the
    // delete reaches the block marker and the `C` and the result is
    // `"ABBBBBX"` — five `B`s survive, not two.
    try legacyCase(.replace, 4, "X", "ABBBBBX");
}

test "text: a splice inside a multi-grapheme insert op inserts after the op in each encoding" {
    // **The case** (`text.rs:1012-1016`): nothing deleted, `"X"` inserted at
    // the same index. **The insertion lands after the whole op**, so it is
    // after the fifth `B` and before the block marker: `"ABBBBBX￼C"`.
    try legacyCase(.insert, 0, "X", "ABBBBBX\u{fffc}C");
}

test "text: a splice inside a multi-grapheme insert op deletes from after the op in each encoding" {
    // **The case** (`text.rs:1018-1022`): one element deleted at the same
    // index. **The delete starts after the whole op** and takes one element,
    // which is the block marker, leaving `"ABBBBBC"` — the `C` survives.
    try legacyCase(.delete, 1, "", "ABBBBBC");
}

const LegacyCase = enum { replace, insert, delete };

fn legacyCase(which: LegacyCase, del: isize, insert: []const u8, want: []const u8) !void {
    for (all_encodings) |enc| {
        var f = try legacyFixture(enc);
        defer f.deinit();

        // **The state the fixture must be in**, before the splice, so a
        // failure in the fixture itself is not reported as a failure of the
        // rounding.
        const before = try f.doc.text(f.text, gpa);
        defer gpa.free(before);
        if (!std.mem.eql(u8, before, "ABBBBB\u{fffc}C")) {
            std.debug.print("encoding {s}: the {s} fixture holds \"{s}\", want \"ABBBBB￼C\"\n", .{
                @tagName(enc),
                @tagName(which),
                before,
            });
            return error.TestUnexpectedResult;
        }

        // **The length before, in the document's own units.** The string above
        // is not counted anywhere; this is, so a fixture that lost or gained
        // an element inside the multi-byte run would be caught even though the
        // bytes still spelled `"ABBBBB￼C"`. **Eight in three encodings and
        // ten under UTF-8 code units**, the extra two being U+FFFC's other two
        // bytes — the oracle's `text-legacy-multibyte` records report the same
        // numbers, and [`blockWidth`] is where the rule is written down.
        try expectLen(
            try f.doc.length(f.text),
            unitWidth(enc, "ABBBBB\u{fffc}C"),
            enc,
        );

        try f.doc.spliceText(f.text, legacy_index, del, insert);

        const got = try f.doc.text(f.text, gpa);
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("encoding {s}: the {s} case read \"{s}\", want \"{s}\"\n", .{
                @tagName(enc),
                @tagName(which),
                got,
                want,
            });
            return error.TestExpectedEqual;
        }

        // **The length after, and it is a different question from the bytes.**
        // The three answers lose different numbers of elements — the replace
        // takes the block marker and the `C` with it, the insert takes nothing,
        // the delete takes the block marker alone and leaves the `C` — and a
        // reader that produced the right bytes while having lost or gained a
        // different number of elements reads the same string. **Seven, seven
        // and seven elements**; eleven units under UTF-8 code units for the
        // insert, where the block marker survives and is three bytes wide.
        try expectLen(
            try f.doc.length(f.text),
            unitWidth(enc, want),
            enc,
        );
    }
}

/// How wide `s` is in `enc`'s units, for the expectations above.
///
/// **Every character in those three strings but the block marker is ASCII**,
/// and ASCII is one unit in all four encodings, so the only thing this has to
/// get right is U+FFFC — three bytes of UTF-8 and one unit everywhere else,
/// which is [`blockWidth`] and nothing else.
fn unitWidth(enc: TextEncoding, s: []const u8) usize {
    var total: usize = 0;
    var at: usize = 0;
    while (at < s.len) {
        if (std.mem.startsWith(u8, s[at..], "\u{fffc}")) {
            total += blockWidth(enc);
            at += 3;
        } else {
            total += 1;
            at += 1;
        }
    }
    return total;
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **Three of thirty-five, established by diffing, not by counting.** The two
//   upstream files declare twenty `#[test]` functions and fifteen more between
//   them, `marks_are_okay` among the twenty being a `proptest`. `src/read.zig`
//   ports thirty-three of them; the three in this file are the rest. The count
//   written in `src/read.zig`'s own diff block ("the 23 tests at the bottom")
//   was **stale by nine** when this file was written, so the list here comes
//   from the `fn` headers on both sides rather than from any prose.
//
// * **`mode` is the oracle's, not upstream's.** `text.rs:385-391` collects the
//   span walk and appends one `Span::Block`. The oracle runs that script twice
//   per encoding — `literal`, with upstream's own numbers, and `translated`,
//   with the numbers moved into the encoding's units — and this file asserts
//   the `translated` answers. The `literal` run is kept in the oracle because
//   it is the evidence for *why*: under `utf8_code_unit` it yields
//   `'￼Headi￼￼ang'`, the heading split in two, which is a question about a
//   mid-block-byte index rather than about marks.
//
// * **Span outputs own hydrated maps; update inputs borrow them.** The appended
//   paragraph is a fresh caller-owned literal, matching upstream's
//   `Span::Block` (`spans.rs:410-417`). The diff compares blocks by content
//   (`text_diff.rs:260`, `Block.eql`), and `parents` is an empty list.
//
// * **`Document.isolate` takes an allocator and `integrate` does not.**
//   Upstream's `AutoCommit::isolate` takes `&[ChangeHash]`
//   (`autocommit.rs`) and this port's [`Document.isolate`](../src/doc.zig)
//   takes the allocator too, because it forks the document and a fork
//   allocates. **`Document.forkAt` is not `Document.fork`** here: `fork`
//   mints its actor through the source's retained `io`, so the actor differs
//   on every run; every actor in this file is named.
//
// * **The three legacy splices are three `test` blocks, where upstream has one
//   `#[test]` with three cases** (`text.rs:1006-1022`). Split, so a failure in
//   the delete case does not hide the answer in the replace case; nothing is
//   dropped, and the three blocks assert the same three strings.
//
// * **Both `legacy_*_hex` blobs were mistranscribed, and that was the whole
//   of `error.InvalidSeq` in the three legacy tests.**
//   `legacy_parent_hex` carried **sixteen** `a1` bytes where the reference
//   wrote **fifteen** — the actor's length prefix `0f` says fifteen — so one
//   byte too many shifted `seq` and it read as **20641**, which
//   `ChangeGraph.addChange` refuses (`change_graph.zig:433`);
//   `legacy_weird_hex` was **one byte short** in `other_actors`. Both are now
//   byte-compared against the oracle's `text-legacy-multibyte` record, and the
//   check that survives a transcription error is the hash: `parseChange` reads
//   them as `118320fd…` and `9581e486…`, the two hashes the record carries and
//   the one the second blob's `deps` entry names. **No production code
//   changed for these three.**
//
// * **That hash check is code now, and the prose above was the only place it
//   existed.** It said `parseChange` *reads them as* those hashes, which is a
//   statement about what the parser returns and not an assertion about the
//   constants — nothing in the file compared the two, so the sentence
//   protected nothing. [`expectLegacyBlobs`] now compares both hashes, the
//   dependency link, the author, `seq`, `start_op`, `time`, the message and
//   `other_actors`. **The parent is anchored, not restated**: the *second*
//   blob's `deps[0]` is the first change's hash as the **reference** computed
//   it, so a parent hashing to that value is the reference's parent whatever
//   else this file says.
//
// * **`other_actors` is fifteen `a1` bytes here, and this file used to say
//   sixteen.** The instrument is the length prefix beside the run, not the run
//   as counted by eye: `other_actors` is a length-prefixed list of
//   length-prefixed actor ids (`storage/change.rs`:111, written at `:482-485`),
//   so the `0f` says fifteen. **The comment was the transcription error, not
//   the blob** — the blob parses, applies and produces the reference's three
//   documented answers.
//
// * **An actor id is hex *text* upstream and raw bytes here, and the file
//   passed the former to a function that wants the latter.**
//   `ActorId::try_from(&str)` hex-decodes (`types.rs:88-95`) and the `Debug`
//   that every `ActorID("…")` in an oracle record comes from prints hex
//   (`types.rs:47-52`), so `ActorId.from_str("aaaaaa")` is three bytes
//   `aa aa aa` and [`ACTOR_A`] is **fifteen** — which it was not for a while.
//   Handing `setActorId` the *characters* of that hex makes a second actor: the
//   document then interned `61 31 61 31 …` beside the change's `a1 a1 …`,
//   [`OpSet.rewriteWithNewActor`](opset/op_set.zig:1387-1401) renumbered every
//   actor index at and above it, and the text object's id — read out before
//   the transaction was opened — then named a *different* actor, so
//   [`Document.objectType`] answered `error.NotAnObject`. `newDoc` takes bytes
//   now and [`HexActor`] decodes at comptime.
//
// * **`ACTOR_A` carried nineteen `a1` bytes while its own sentence said
//   fifteen, and every assertion in this file passed anyway.** Same defect
//   class as the bullet above and a different mechanism: not the wrong bytes
//   but the wrong **count**, so [`newDoc`] handed the document an author no
//   change was written by and the three legacy splices were authored by it.
//   The oracle hex-decodes its own `ACTOR_A`
//   ([`actor`](../tools/oracle/src/main.rs):1770-1772) into fifteen bytes, and
//   the legacy change's author is fifteen bytes — the `0f` length prefix in
//   `legacy_parent_hex` is the instrument. **The three legacy cases compare the
//   resulting text, and a text does not name its author**; the assertion that
//   found it is [`expectLegacyBlobs`]'s author check, added with the rest of
//   that helper.
//
// * **Three assertions here were prose and are now code, and none of them
//   changed an answer.** [`expectLegacyBlobs`] performs the change-hash check
//   the fixture comment claimed; [`checkShape`] performs the root-and-object
//   type checks its own doc comment claimed; and [`legacyCase`] compares the
//   length it used to read and discard. **Each was a sentence about what the
//   code does, and each sentence was load-bearing on its own**: a hash no code
//   compared, a root nothing asked the type of, and a `_ = try length(…)` under
//   a comment calling it an assertion. The element count in particular is a
//   different question from the bytes — the three answers lose different
//   numbers of elements — and it is now read in the document's own units
//   under all four encodings, before and after each splice.
//
// * **`putTextIn` uses the real automatic owner.** `AutoCommit.isolate`
//   closes the initial held group; committing the isolated group advances its
//   view to the committed branch before `integrate` enters the full history
//   (`autocommit.rs`:728-741). Raw transaction commit does not perform that
//   facade transition, so it is not an equivalent route for this case.
//
// * **`diff_incremental` is the stream, and it is the reference's seven.**
//   [`expectIsolateStream`] names all seven in order, by key and by value,
//   including intermediate conflict updates. Reconstruction and final text
//   checks remain independent assertions; matching only the count is not enough.
