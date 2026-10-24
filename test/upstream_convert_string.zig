//! Public loader coverage for all three cases in
//! `$AUTOMERGE_REF/rust/automerge/tests/convert_string_to_text.rs`:7-71.
//!
//! Each case calls `Document.loadWithOptions` with
//! `.string_migration = .convert_to_text`; conversion is production loader work,
//! not a test-side transaction. Upstream selects the same option at
//! `convert_string_to_text.rs`:13-17, :40-44, :63-66 and performs migration in
//! `rust/automerge/src/automerge.rs`:991-993, :1973-2024.
//!
//! All cases run under all four text encodings. Assertions retain text object
//! types, element sequence, text units, marks, joined text, change counts,
//! save/reload, and replay through `applyChanges`. Every owned result uses
//! `std.testing.allocator` and is released by its caller.

const std = @import("std");
const am = @import("zautomerge");

const testing = std.testing;

/// **The leak arbiter for the whole file.** One allocator, named once.
const gpa = testing.allocator;

/// The borrowed capability every document constructor below is handed.
///
/// **Explicit, because `Document` keeps it.** The op set draws actors through
/// this value for as long as the document lives, so a constructor cannot
/// reach for an ambient global and no document can outlive its provider. Here
/// that value is `std.testing.io`; an executable passes its own `init.io`.
const io = std.testing.io;

const Document = am.doc.Document;
const Change = am.change_record.Change;
const ExId = am.ExId;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ActorId = am.ActorId;
const TextEncoding = am.TextEncoding;
const Tx = am.Transaction;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

/// The four encodings every case below runs under, in the order
/// [`TextEncoding`] declares them ([`types.zig`:558-563](../src/types.zig)).
const all_encodings = [_]TextEncoding{
    .unicode_code_point,
    .utf8_code_unit,
    .utf16_code_unit,
    .grapheme_cluster,
};

// ── Actors ───────────────────────────────────────────────────────────────────

/// Upstream draws an actor at random ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs));
/// this file mints them from a counter instead — distinct bytes, a stable
/// order, the same bytes on every run — for the reason
/// [`test/upstream_batch_insert.zig`](upstream_batch_insert.zig) gives: a
/// failure nobody can reproduce is not a finding.
///
/// The bytes start at one so that no document ever has an **empty** actor,
/// which is a different value from every other one.
var minted_actors: [64][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] hands out. The bytes live in this file's static
/// storage, which is what lets the returned [`ActorId`] be a borrow: a document
/// copies the bytes when it interns the actor.
fn mintActor() ActorId {
    std.debug.assert(minted_count < minted_actors.len);
    const slot = minted_count;
    minted_count += 1;
    var v: u64 = slot + 1;
    var i: usize = minted_actors[slot].len;
    while (i > 0) {
        i -= 1;
        minted_actors[slot][i] = @truncate(v);
        v >>= 8;
    }
    return .{ .bytes = minted_actors[slot][0..] };
}

/// A raw document with a deterministic actor for each test setup.
fn newDoc(encoding: TextEncoding) !Document {
    var doc = try Document.initWithEncoding(gpa, io, encoding);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `obj.prop`, or `error.NoSuchKey` when nothing is there and
/// `error.NotAnObject` when an object is.
fn scalarAt(doc: *Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// Upstream's three refusals in [`convert_string_to_text.rs`:19-28](../github-automerge-automerge/rust/automerge/tests/convert_string_to_text.rs)
/// and its twin at `:46-55`, kept as three refusals because upstream keeps
/// three:
///
/// 1. `let Some((val, obj_id)) = val else { panic!("no value found …") }`
/// 2. `let Value::Object(obj) = val else { panic!("expected an object …") }`
/// 3. `let ObjType::Text = obj else { panic!("expected a text object …") }`
///
/// Both upstream and the public reader carry the object's type in the value;
/// `item.id` separately identifies the object.
fn expectTextObject(doc: *Document, obj: ExId, prop: Prop) !ExId {
    const item = (try am.read.get(doc, obj, prop)) orelse {
        std.debug.print("no value found at {s}\n", .{@tagName(prop)});
        return error.NoSuchKey;
    };
    switch (item.value) {
        .object => |t| {
            if (t != .text) {
                std.debug.print(
                    "expected a text object at {s}, found a {t}\n",
                    .{ @tagName(prop), t },
                );
                return error.UnexpectedObjType;
            }
        },
        .scalar => |s| {
            std.debug.print(
                "expected an object at {s}, found a {t}\n",
                .{ @tagName(prop), s },
            );
            return error.NotAnObject;
        },
    }
    return item.id;
}

/// Compare indexing-unit length, each stored element, live marks, and joined text.
/// UTF-8 and UTF-16 operations contain code points but may span multiple units;
/// grapheme indexing stores a whole cluster per element.
fn expectTextObjectContents(
    doc: *Document,
    text_id: ExId,
    want: []const u8,
    enc: TextEncoding,
) !void {
    // **The length, in this case's own units.** `.utf16_code_unit` counts a
    // surrogate pair as two and `.grapheme_cluster` counts a cluster as one, so
    // `want.len` would be wrong for two of the four.
    const expected_length = enc.width(want);
    const actual_length = try am.read.length(doc, text_id);
    try testing.expectEqual(expected_length, actual_length);

    // **The element sequence**, one element at a time.
    //
    // `index` is a position in `enc`'s units and `at` a byte offset into
    // `want`; under three of the four they advance together, and under
    // `.utf16_code_unit` `index` advances by **two** for a code point above
    // U+FFFF while `at` advances by its four bytes — that gap is the whole
    // reason an element sequence and a length are not the same assertion.
    var index: usize = 0;
    var at: usize = 0;
    while (at < want.len) {
        const span: []const u8 = switch (enc) {
            // **One operation per code point under all three of these**, and the
            // element is the whole code point — `Op::as_str` reads the op's own
            // value ([`op.zig`]:1882-1886](../src/opset/op.zig)). `.utf8_code_unit`
            // is in this arm **on the strength of the measurement above**: it
            // indexes by byte, and each of its operations is that many bytes
            // wide, which is a different question from how many operations a
            // string is worth.
            .unicode_code_point, .utf8_code_unit, .utf16_code_unit => blk: {
                const n: usize = std.unicode.utf8ByteSequenceLength(want[at]) catch
                    return error.BadUtf8;
                if (at + n > want.len) return error.BadUtf8;
                break :blk want[at .. at + n];
            },
            // One operation per cluster, and the element is the whole cluster.
            //
            // **`graphemeOffset`, not `nextGraphemeBoundary`, and that is
            // measured.** `nextGraphemeBoundary` answers **0** for
            // `byte_index == 0` ([`unicode.zig`:144-146](../src/unicode.zig)) —
            // upstream's "no cluster consumed yet" marker — so the first span
            // comes out **empty** and the comparison fails with
            // `expected <empty>, found <h>`. `graphemeOffset(s, index)` is
            // "the byte offset of cluster `index`"
            // ([`unicode.zig`:170-181](../src/unicode.zig)): 0 at index 0 and
            // `s.len` one past the last, which is exactly the pair this needs.
            .grapheme_cluster => blk: {
                const lo = am.unicode.graphemeOffset(want, index) catch
                    return error.BadUtf8;
                const hi = am.unicode.graphemeOffset(want, index + 1) catch
                    return error.BadUtf8;
                if (hi <= lo or hi > want.len) return error.BadWalk;
                break :blk want[lo..hi];
            },
        };

        // **How wide this element is in `enc`'s units.** A four-byte UTF-8
        // sequence is a code point at U+10000 or above, so it is the only shape
        // that is a surrogate pair: `.utf16_code_unit` is two for it and one for
        // everything else, and `.utf8_code_unit` is the code point's own byte
        // length — which is one for `"hello"` under **every** encoding, and is
        // why the upstream payload cannot tell the four apart.
        const width: usize = switch (enc) {
            .utf8_code_unit => span.len,
            .utf16_code_unit => if (span.len == 4) 2 else 1,
            else => 1,
        };

        const got = try scalarAt(doc, text_id, .{ .index = index });
        if (got != .str) {
            std.debug.print(
                "element {d} of the {s} text object is a {t}, want a str\n",
                .{ index, @tagName(enc), got },
            );
            return error.UnexpectedScalarType;
        }
        try testing.expectEqualStrings(span, got.str);
        at += span.len;
        index += width;
    }
    // **The walk consumed exactly the length**, which is the second number and
    // the one a count cannot stand in for.
    try testing.expectEqual(enc.width(want), index);

    // **The marks, by name and by span.** The conversion splices unmark-marked
    // text (`automerge.rs:2018` is a bare `splice_text`), so there are none —
    // and [`read.marks`](../src/read.zig) drops an unmark (a mark whose value
    // is null) as a tombstone rather than a mark, so this asserts "no *live*
    // mark" rather than "no mark operation". A diagnostic names each mark's
    // name and both ends of its span, so a wrong one is identified rather than
    // merely counted.
    const ms = try am.read.marks(doc, text_id, gpa);
    defer gpa.free(ms);
    for (ms) |m| {
        std.debug.print(
            "unexpected mark {s} over [{d}, {d}) on the {s} text object\n",
            .{ m.name, m.start, m.end, @tagName(enc) },
        );
    }
    try testing.expectEqual(@as(usize, 0), ms.len);

    // **The joined text**, last, because it is the one that says nothing about
    // which units the elements were written in.
    const joined = try am.read.text(doc, text_id, gpa);
    defer gpa.free(joined);
    try testing.expectEqualStrings(want, joined);
}

/// The number of changes the document holds. [`Document.getChanges`](../src/doc.zig)
/// re-encodes the rows, so it takes a **mutable** document even though it
/// changes nothing ([`doc.zig`:4630](../src/doc.zig)).
fn changeCount(doc: *Document) !usize {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    return all.len();
}

// ── The round trip every case below also takes ───────────────────────────────

/// [`Document.getChanges`](../src/doc.zig)'s list as the `[]Change`
/// [`Document.applyChanges`](../src/doc.zig) takes. **The caller frees the
/// array**; the [`Change`] values borrow the list's bodies, so the list outlives
/// the call.
fn changeViews(list: *const am.doc.Changes) ![]Change {
    const out = try gpa.alloc(Change, list.len());
    errdefer gpa.free(out);
    for (0..list.len()) |i| out[i] = list.at(i);
    return out;
}

/// The document's changes replayed into a fresh document through
/// [`Document.applyChanges`](../src/doc.zig), and the two compared.
///
/// **The rows are compared first, and structurally.**
/// [`Document.debugCmp`](../src/doc.zig) is "row for row and byte for byte", so
/// a row-order divergence fails there with a diagnostic naming the fault. The
/// mirror comparison is second and catches a divergence the op set does not
/// show — a case where two documents hold the same rows and read back
/// differently.
///
/// Setup uses one transaction; migration runs inside the production loader.
/// Replaying the resulting changes covers the apply path as well as loading.
/// The replay uses the source's encoding so row and materialized comparisons
/// use the same text indexing units.
fn expectSameThroughApplyChanges(doc: *Document) !void {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    // A document that wrote nothing cannot carry both shapes, and `applyChanges`
    // on an empty list is a no-op that would pass for the wrong reason.
    if (all.len() == 0) return;

    const view = try changeViews(&all);
    defer gpa.free(view);

    var applied = try Document.initWithEncoding(gpa, io, doc.textEncoding());
    defer applied.deinit();
    _ = try applied.applyChanges(gpa, view);

    try applied.debugCmp(doc);

    var written = try am.hydrate.hydrateMap(am.doc.Set, &doc.ops, gpa, root, null);
    defer written.deinit();
    var replayed = try am.hydrate.hydrateMap(am.doc.Set, &applied.ops, gpa, root, null);
    defer replayed.deinit();
    if (!written.eql(&replayed)) {
        std.debug.print(
            "\nstring conversion: the write path and applyChanges materialise differently\n",
            .{},
        );
        return error.ReplayDiffers;
    }
}

// ── 1. test_strings_in_maps_are_converted_to_text ────────────────────────────

test "strings in maps are converted to text" {
    // Upstream `convert_string_to_text.rs`:7-31. The ASCII payload has the same
    // units in every encoding; the sweep exercises every loader indexing path.
    for (all_encodings) |enc| {
        var doc = try newDoc(enc);
        defer doc.deinit();

        // Upstream's setup at `convert_string_to_text.rs`:10 writes one change.
        {
            var tx = try Tx.open(gpa, &doc);
            defer tx.deinit() catch @panic("testing allocator cannot refuse rollback");
            _ = try tx.put(root, .{ .key = "somestring" }, .{ .str = "hello" });
            var committed = try tx.commit();
            defer committed.deinit(gpa);
            try testing.expect(committed.hash != null);
        }

        // **One change before the migration**, which is what makes case 3's
        // "no change added" a statement about the migration and not about the
        // document.
        try testing.expectEqual(@as(usize, 1), try changeCount(&doc));

        const saved = try doc.save(gpa);
        defer gpa.free(saved);

        // Public loading performs the migration selected upstream at
        // `convert_string_to_text.rs`:13-17 (`automerge.rs`:991-993).
        var loaded = try Document.loadWithOptions(gpa, io, saved, .{
            .text_encoding = enc,
            .string_migration = .convert_to_text,
        });
        defer loaded.deinit();

        // `let Some((val, obj_id)) = val else …` /
        // `let Value::Object(obj) = val else …` / `let ObjType::Text = obj else …`
        // (`convert_string_to_text.rs:19-28`).
        const text_id = try expectTextObject(&loaded, root, .{ .key = "somestring" });

        // `let text = loaded.text(obj_id).unwrap(); assert_eq!(text, "hello");`
        // (`convert_string_to_text.rs:29-30`), plus the element sequence and the
        // marks that upstream does not check.
        try expectTextObjectContents(&loaded, text_id, "hello", enc);

        // Migration commits both object creation and text insertion together
        // (`automerge.rs`:2015-2020), adding exactly one change.
        try testing.expectEqual(@as(usize, 2), try changeCount(&loaded));

        try expectSameThroughApplyChanges(&loaded);
    }
}

// ── 2. test_strings_in_lists_are_converted_to_text ───────────────────────────

test "strings in lists are converted to text" {
    // `convert_string_to_text.rs:33-58`
    // Sequence register migration (`automerge.rs`:1991-2000) must replace the
    // element, not append to it. Map-only migration cannot satisfy this case.
    for (all_encodings) |enc| {
        var doc = try newDoc(enc);
        defer doc.deinit();

        // **`doc.put_object(ROOT, "list", ObjType::List)` then
        // `doc.insert(&list, 0, "hello")`** (`convert_string_to_text.rs:36-37`),
        // **in one `Tx` and so in one change of two operations** — the same
        // single `AutoCommit` transaction as case 1.
        const list_id = blk: {
            var tx = try Tx.open(gpa, &doc);
            defer tx.deinit() catch @panic("testing allocator cannot refuse rollback");
            const l = try tx.putObject(root, .{ .key = "list" }, .list);
            _ = try tx.insert(l, 0, .{ .str = "hello" });
            var committed = try tx.commit();
            defer committed.deinit(gpa);
            try testing.expect(committed.hash != null);
            break :blk l;
        };
        try testing.expectEqual(@as(usize, 1), try changeCount(&doc));

        const saved = try doc.save(gpa);
        defer gpa.free(saved);

        var loaded = try Document.loadWithOptions(gpa, io, saved, .{
            .text_encoding = enc,
            .string_migration = .convert_to_text,
        });
        defer loaded.deinit();

        // **Upstream reads the element through the `ExId` it got *before* the
        // save** — `loaded.get(&list, 0)` at `convert_string_to_text.rs:46`,
        // where `list` is the id the pre-save document handed out. That is kept
        // rather than re-read, because it is a stronger claim: the id survives
        // a save and a load. It does, because [`ExId`] carries the actor's
        // **bytes** ([`exid.zig`:15-18](../src/exid.rs)) and its `PartialEq`
        // ignores the index (`:126-138`), so [`Document.resolve`](../src/doc.zig)
        // finds it in a document whose actor table is numbered differently.
        const text_id = try expectTextObject(&loaded, list_id, .{ .index = 0 });

        // `assert_eq!(text, "hello")` (`convert_string_to_text.rs:56-57`), plus
        // the element sequence and the marks.
        try expectTextObjectContents(&loaded, text_id, "hello", enc);

        // **The list is still a list of one**, and that is not a count: the
        // conversion *replaced* the element's register rather than appending to
        // it, so a conversion that inserted a text object would leave two
        // elements and this is where that shows.
        try testing.expectEqual(@as(usize, 1), try am.read.length(&loaded, list_id));

        // **One change more**, as in case 1.
        try testing.expectEqual(@as(usize, 2), try changeCount(&loaded));

        try expectSameThroughApplyChanges(&loaded);
    }
}

// ── 3. test_does_not_add_size_when_strings_are_not_converted ────────────────

test "conversion adds no size when there is nothing to convert" {
    // `convert_string_to_text.rs:60-71`
    //
    // **Encoding-dependent: no, and it cannot be.** There is no text object and
    // no string in the document, so no encoding is ever consulted: the four
    // runs differ only in which `TextEncoding` the two empty documents were
    // built and re-saved under. This case is the **control** for cases 1 and 2
    // — the length comparison it makes is the same comparison those two would
    // fail if the conversion wrote anything when it had nothing to do, which is
    // exactly what the `if !to_convert.is_empty()` guard
    // ([`automerge.rs`:2014](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // is for.
    for (all_encodings) |enc| {
        // `let empty_document = AutoCommit::new().save();`
        // (`convert_string_to_text.rs:62`) — a document that has never been
        // written to.
        var src = try newDoc(enc);
        defer src.deinit();
        const empty_document = try src.save(gpa);
        defer gpa.free(empty_document);

        var loaded = try Document.loadWithOptions(gpa, io, empty_document, .{
            .text_encoding = enc,
            .string_migration = .convert_to_text,
        });
        defer loaded.deinit();

        // `let saved_again = loaded.save();` (`convert_string_to_text.rs:69`).
        const saved_again = try loaded.save(gpa);
        defer gpa.free(saved_again);

        // **`assert_eq!(empty_document.len(), saved_again.len());`**
        // (`convert_string_to_text.rs:71`). Upstream compares the two saved
        // documents' byte lengths, and so does this — **and the byte length is
        // the only place the two implementations may not agree**, because
        // `save()` is not required to be byte-identical across implementations.
        // Both lengths here come from the
        // **same** encoder over the **same** empty document, so the comparison
        // is exact rather than approximate.
        try testing.expectEqual(empty_document.len, saved_again.len);

        // **And the two stronger statements behind it**, because a length can be
        // equal for two different documents. A conversion that opened a
        // transaction and committed it empty would leave the byte length alone
        // only if the empty change compressed away, and it would leave a change
        // behind, so these are what actually pin "nothing was written".
        try testing.expectEqual(@as(usize, 0), try changeCount(&loaded));
        const heads = try loaded.getHeads(gpa);
        defer gpa.free(heads);
        try testing.expectEqual(@as(usize, 0), heads.len);

        // **The document is still loadable**, so "the same bytes" is a claim
        // about a document and not about a buffer.
        var round = try Document.load(gpa, io, saved_again, enc);
        defer round.deinit();
        try testing.expectEqual(@as(usize, 0), try changeCount(&round));
    }
}
