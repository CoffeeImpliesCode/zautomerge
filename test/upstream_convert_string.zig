//! `$AUTOMERGE_REF/rust/automerge/tests/convert_string_to_text.rs` — **all
//! three** `#[test]` cases, ported case for case and in upstream's order.
//!
//! # What the file is
//!
//! Upstream's file is 72 lines and three cases, and **none of them was ported**
//! before this file. All three are behaviour cases, so none is dropped: what
//! upstream asserts is asserted here.
//!
//! It is a **consumer test**: it imports `zautomerge` by name, sets no working
//! directory and reads no fixture — the same shape
//! [`upstream_batch_insert.zig`](upstream_batch_insert.zig) has.
//!
//! # The gap, at its own upstream line, and what these cases therefore drive
//!
//! All three cases go through
//! `AutoCommit::load_with_options(&saved, LoadOptions::new().migrate_strings(StringMigration::ConvertToText))`
//! (`convert_string_to_text.rs`:13-17, `:40-44`, `:63-66`).
//!
//! **The port has no `LoadOptions` at all.** `Document.load` is
//! `load(gpa, bytes, encoding: TextEncoding, mode: Mode)`
//! ([`doc.zig`:3221-3233](../src/doc.zig)) — there is no options parameter, no
//! `StringMigration` (`automerge.rs`:83-88), and no `migrate_strings`
//! (`automerge.rs`:152-157) anywhere in `src/`, and [API.md](../API.md) § Known
//! gaps lists neither. **So the load-with-options door is not exercised here,
//! and that is the gap, recorded here rather than at a call site that does not
//! exist.**
//!
//! What *is* exercised is the thing the option turns on:
//! [`Automerge::convert_scalar_strings_to_text`]
//! ([`automerge.rs`:1973-2024](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//! reached from the load path at `automerge.rs:991-993`. It is a **private**
//! method on the inner `Automerge`, and it runs *before* `AutoCommit` is
//! wrapped around it, so the conversion belongs to the **manual** flavour —
//! which is why every document below is loaded with `Mode.manual` and the
//! conversion opens one [`Tx`].
//!
//! [`convertScalarStringsToText`] is that method transcribed onto the port's
//! own door, line for line, and the diff block at the bottom of this file says
//! which line each piece is.
//!
//! # The four encodings
//!
//! Every case runs under **all four** [`TextEncoding`]s, because an index means
//! something different in each and a conversion that is right in one can be
//! wrong in another. **Upstream's file does not loop over encodings at all** —
//! `LoadOptions::new()` sets `text_encoding: TextEncoding::platform_default()`
//! ([`automerge.rs`:181](../github-automerge-automerge/rust/automerge/src/automerge.rs))
//! and upstream runs its tests on one platform, so the sweep is this file's and
//! **is a finding about the upstream file**: the conversion's one encoding-
//! dependent step is `tx.splice_text`, and a case that only ever runs under
//! `UnicodeCodePoint` never exercises [`countUtf16CodeUnits`] or
//! [`countGraphemes`]. On this host the port's default is
//! `.unicode_code_point` ([`doc.zig`:5580-5582](../src/doc.zig)), so upstream's
//! single encoding is the first of the four here.
//!
//! Which of the three are encoding-dependent is recorded per case at the case,
//! and the answer is measured by [`expectTextObjectContents`], which asserts
//! the **element sequence** and not a length: the text object's length is
//! `TextEncoding.width(want)` under the case's own encoding, so a conversion
//! that wrote one operation per *byte* under `.utf16_code_unit` would answer
//! the wrong element sequence and not merely the wrong count.
//!
//! # The leak arbiter
//!
//! [`gpa`] is [`std.testing.allocator`] and **every owned value below comes out
//! of it**: every document, every saved byte string, every head list
//! ([`Document.getHeads`](../src/doc.zig) hands back a copy the caller frees),
//! every change list, every key walk, every mark list, and every copied key and
//! string [`collectConversions`] holds.

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
const Allocator = std.mem.Allocator;

const Document = am.doc.Document;
const Change = am.change_record.Change;
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ActorId = am.ActorId;
const TextEncoding = am.TextEncoding;
const Tx = am.manual_transaction.Transaction;
const Mirror = am.hydrate.Value;

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

/// A document in the **manual** flavour, which is upstream's `Automerge` and the
/// only door a [`Tx`] is expressible through — and the flavour the conversion
/// below needs, because upstream's runs on the inner `Automerge` before
/// `AutoCommit` wraps it (`automerge.rs:991-993`, `:2015`).
fn newDoc(encoding: TextEncoding) !Document {
    var doc = try Document.initWithEncoding(gpa, io, encoding, .manual);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `obj.prop`, or `error.NoSuchKey` when nothing is there and
/// `error.NotAnObject` when an object is.
fn scalarAt(doc: *const Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The id of the object at `obj.prop`, or `error.NoSuchKey`.
fn objectAt(doc: *const Document, obj: ExId, prop: Prop) !ExId {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
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
/// **Upstream's `Value::Object` carries the type and the port's does not.**
/// [`read.DocItem`](../src/read.zig) splits them: `.value == .object` says
/// *object*, [`ValueRef.object`](../src/opset/types.zig) carries the
/// [`ObjType`], and `item.id` is the object's id. So arm 2 and arm 3 are two
/// reads of one item rather than two patterns on one value, and the type is
/// read off the item rather than through [`Document.objectType`](../src/doc.zig).
fn expectTextObject(doc: *const Document, obj: ExId, prop: Prop) !ExId {
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

/// The text object at `obj.prop` holds exactly `want`: **the element sequence,
/// the marks, and the joined text**, in that order.
///
/// **This is not a length assertion and that is the point of it.** All three
/// encodings that do not index by code point disagree with `want.len`, and
/// **two of them also disagree with the operation count**, so a length-only
/// assertion would pass on a document whose elements were spliced in the wrong
/// units. The rule, **measured** on `"a👩b"` against this port (three
/// operations, six bytes, four UTF-16 units, three clusters — and the same three
/// operations under the first, second and fourth encodings):
///
/// | encoding | one operation per | that operation is `w` units wide, `w` = | `read.length` counts |
/// | --- | --- | --- | --- |
/// | `.unicode_code_point` | code point | 1 | code points |
/// | `.utf8_code_unit` | code point | **its byte length** | bytes |
/// | `.utf16_code_unit` | code point | **1 or 2** (2 above U+FFFF) | UTF-16 code units |
/// | `.grapheme_cluster` | grapheme cluster | 1 | clusters |
///
/// So `"a👩b"` is **three operations** and **6 / 4 / 3 / 3 units**, and
/// `read.get` at any index *inside* a wide operation answers that operation
/// again. Both numbers are asserted below, and the sequence is walked one
/// element at a time at each element's **first** index; then the marks, by name
/// **and** span; then the joined text, because those three disagree on
/// different defects.
///
/// `.utf8_code_unit` is the row this file got wrong first and the measurement
/// is what corrected it: an earlier version treated it as **one operation per
/// byte**, from [`TextEncoding.width`](../src/types.zig):568 and
/// [`read.zig`]:3719-3721, and a throwaway run with a discriminating payload
/// failed `expected <one byte 0xf0>, found <four bytes 👩>`. The reference
/// spells the same rule for UTF-16 at [`read.zig`:3890-3894](../src/read.zig) —
/// "its operations are still one code point each, and they are merely two units
/// wide" — and the UTF-8 row is the same sentence with the byte count.
fn expectTextObjectContents(
    doc: *const Document,
    text_id: ExId,
    want: []const u8,
    enc: TextEncoding,
) !void {
    // **The length, in this case's own units.** `.utf16_code_unit` counts a
    // surrogate pair as two and `.grapheme_cluster` counts a cluster as one, so
    // `want.len` would be wrong for two of the four.
    try testing.expectEqual(enc.width(want), try am.read.length(doc, text_id));

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
/// **Why this file needs it.** Every case below writes its setup through a
/// [`Tx`] and its conversion through a [`Tx`], and the load path in between
/// goes through the chunk parser rather than the change applier. So the write
/// path and the apply path both produce the document under assertion, from the
/// same bytes, and they are required to be the same document.
///
/// **The replay is built in the source's own encoding, and that is not
/// tidiness.** [`OpSet.debugDiff`](../src/opset/op_set.zig) compares
/// `text_encoding` among the five faults it reports **silently**
/// ([`op_set.zig`:1235](../src/opset/op_set.zig) is the arm that prints
/// nothing), and [`Document.init`](../src/doc.zig) defaults to
/// `.unicode_code_point` ([`doc.zig`]:5580-5582), so a replay document built
/// with it answers `error.Invariant` with **no diagnostic at all** for three of
/// the four encodings this file sweeps. Measured: a first run of case 1 failed
/// in `expectSameThroughApplyChanges` with a bare `error.Invariant` and no
/// printed fault, which is what identified the encoding and not the document.
fn expectSameThroughApplyChanges(doc: *Document) !void {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    // A document that wrote nothing cannot carry both shapes, and `applyChanges`
    // on an empty list is a no-op that would pass for the wrong reason.
    if (all.len() == 0) return;

    const view = try changeViews(&all);
    defer gpa.free(view);

    var applied = try Document.initWithEncoding(gpa, io, doc.textEncoding(), .auto);
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

// ── The migration, transcribed ───────────────────────────────────────────────

/// One register whose winner is a string, held still so the transaction can be
/// opened after the walk that found it.
///
/// **Both payloads are owned copies, and that is upstream's shape and not
/// caution.** `Prop::Map(prop.into())` ([`automerge.rs`:1989](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// turns a borrowed `KeyRef::Map` into an owned `SmolStr`, and
/// `text: smol_str::SmolStr::from(s)` (`:2005`) copies the string out of the
/// op set. Both are needed **independently of the borrow rules**, because
/// upstream's list is built before the transaction is opened
/// ([`automerge.rs`:1979](../github-automerge-automerge/rust/automerge/src/automerge.rs),
/// `:2014-2015`) and a slice borrowed out of the op set is valid only until the
/// next mutation — which the very first `put_object` is.
const Conversion = struct {
    /// `obj_id: self.ops.id_to_exid(obj.id.0)`
    /// ([`automerge.rs`:2003](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// **and that call is load-bearing rather than ceremonial** — see
    /// [`withActorBytes`] below, which is where it is transcribed and why it
    /// cannot be dropped.
    obj_id: ExId,
    /// `Prop::Map(prop)` (`:1989`), owned. Null when this is a sequence
    /// register and `index` is set instead.
    key: ?[]u8,
    /// `Prop::Seq(found.index)` (`:1999`), read only when `key` is null.
    index: usize,
    /// `text: smol_str::SmolStr::from(s)` (`:2005`), owned.
    text: []u8,

    fn prop(self: Conversion) Prop {
        return if (self.key) |k| .{ .key = k } else .{ .index = self.index };
    }

    fn deinit(self: Conversion, alloc: Allocator) void {
        if (self.key) |k| alloc.free(k);
        alloc.free(self.text);
    }
};

/// `self.ops.id_to_exid(obj.id.0)`
/// ([`automerge.rs`:2003](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// transcribed onto [`OpSet.idToExid`](../src/opset/op_set.zig) — **and it is
/// the one line of this transcription that cannot be dropped.**
///
/// **Measured, not assumed.** [`IterObjIds.next`](../src/opset/op_set.zig):511-514
/// builds a boundary's id with [`ExId.fromParts`](../src/types.zig):296-302,
/// which carries **an actor index and no actor bytes**. [`ExId.actorBytes`](../src/types.zig):326-331
/// says in its own doc that the bytes are "the one thing that decides whether
/// an id can be re-resolved", and [`Document.resolve`](../src/doc.zig):4924-4925
/// returns an id with no bytes unchanged. So a boundary id is an index that is
/// only true until the actor table is renumbered — **and [`Tx.open`] opens by
/// interning an actor** ([`doc.transactionArgs`](../src/doc.zig) → [`isolatedActorIndex`](../src/doc.zig)),
/// which inserts into a **sorted** table ([`op_set.zig`:766-768](../src/opset/op_set.zig))
/// and therefore shifts every index after the new actor.
///
/// The first version of this file took `iterObjs`'s id directly and case 2
/// failed with `error.NotAnObject` from
/// [`Transaction.putObject`](../src/transact.zig):931-948 on **three of the
/// four encodings** — `exit=1`, `compile_errors=0`, `FAIL=2`, and the trace
/// named `objectType → resolve → putObject`, which is this. Upstream cannot be
/// wrong this way because upstream writes the bytes: `id_to_exid` is
/// `ExId::withActor(id, who)` ([`op_set.zig`]:2499-2503). The root has no
/// operation and so no call.
fn withActorBytes(doc: *Document, id: ExId) ExId {
    const op = id.opId() orelse return id;
    return doc.ops.idToExid(op);
}

/// Every register in the document whose winner is a string, in map-row order
/// for a map and in index order for a list.
///
/// **This is upstream's `for (obj, ops) in self.ops.iter_objs()` over
/// `ops.visible_slow(None)` ([`automerge.rs`:1980-2012](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// walked through the port's public reader instead of the op set's visible-op
/// walk.** The two see the same set and the diff block says why.
///
/// `doc` is mutable because [`OpSet.iterObjs`](../src/opset/op_set.zig) takes a
/// mutable op set; the walk itself mutates nothing.
fn collectConversions(doc: *Document) !std.ArrayList(Conversion) {
    var out: std.ArrayList(Conversion) = .empty;
    errdefer {
        for (out.items) |c| c.deinit(gpa);
        out.deinit(gpa);
    }

    const objs = try doc.ops.iterObjs(gpa);
    defer gpa.free(objs);

    for (objs) |o| {
        // **`id_to_exid`, once per object** (`:2003`), and the root stays the
        // root because it has no operation to attach bytes to.
        const obj_id = withActorBytes(doc, o.meta.id);
        // `ObjType::Map | ObjType::List` at `automerge.rs:1982`; **`.text` and
        // `.table` fall into the `_ => {}` arm at `:2010`** and are not walked,
        // so a string inside a text object is left alone — it is already text.
        switch (o.meta.typ) {
            .map => {
                // **The keys are copied before the second walk, and that is a
                // rule rather than a style.** A [`Keys`] walk
                // ([`read.keys`](../src/read.zig)) borrows the op set's shared
                // successor buffer, which is one buffer per op set
                // ([`op_set.zig`]:40-49), and `am.read.get` walks the same one.
                // So the keys are taken out and the walk is freed **before** the
                // first `get`, not inside the loop.
                var keybuf: std.ArrayList([]u8) = .empty;
                defer {
                    for (keybuf.items) |k| gpa.free(k);
                    keybuf.deinit(gpa);
                }
                {
                    var it = try am.read.keys(doc, obj_id);
                    defer it.deinit(gpa);
                    while (try it.next()) |key| {
                        try keybuf.append(gpa, try gpa.dupe(u8, key));
                    }
                }
                for (keybuf.items) |key| {
                    const item = (try am.read.get(doc, obj_id, .{ .key = key })) orelse
                        return error.NoSuchKey;
                    switch (item.value) {
                        .object => {},
                        .scalar => |s| switch (s) {
                            .str => |bytes| try out.append(gpa, .{
                                .obj_id = obj_id,
                                .key = try gpa.dupe(u8, key),
                                .index = 0,
                                .text = try gpa.dupe(u8, bytes),
                            }),
                            else => {},
                        },
                    }
                }
            },
            .list => {
                // **`Prop::Seq(found.index)` is the element's own index**
                // (`automerge.rs`:1991-2000), and that is what walking
                // `0..length` and asking for `.{ .index = i }` produces.
                const n = try am.read.length(doc, obj_id);
                for (0..n) |i| {
                    const item = (try am.read.get(doc, obj_id, .{ .index = i })) orelse
                        return error.NoSuchKey;
                    switch (item.value) {
                        .object => {},
                        .scalar => |s| switch (s) {
                            .str => |bytes| try out.append(gpa, .{
                                .obj_id = obj_id,
                                .key = null,
                                .index = i,
                                .text = try gpa.dupe(u8, bytes),
                            }),
                            else => {},
                        },
                    }
                }
            },
            .text, .table => {},
        }
    }
    return out;
}

/// [`Automerge::convert_scalar_strings_to_text`]
/// ([`automerge.rs`:1973-2024](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// on the port's door.
///
/// **One [`Tx`], one commit, for every conversion** — `let mut tx =
/// self.transaction(); … tx.commit();` at [`automerge.rs`:2015-2020](../github-automerge-automerge/rust/automerge/src/automerge.rs).
/// The port's autocommit free functions commit on every call
/// ([`transact.zig`](../src/transact.zig):2781-2788), so a document with *n*
/// strings would gain *2n* changes here where upstream gains one. Case 1 and
/// case 2 each assert the change count, so that difference cannot pass.
///
/// **`doc` must be `.manual`.** [`Tx.open`](../src/transact.zig):462-466 refuses
/// any other mode with `error.InvalidOp`, and upstream's conversion is on the
/// inner `Automerge` rather than on an `AutoCommit` — so a `.auto` document is
/// not upstream's shape and is not accepted here either.
fn convertScalarStringsToText(doc: *Document) !void {
    var todo = try collectConversions(doc);
    defer {
        for (todo.items) |c| c.deinit(gpa);
        todo.deinit(gpa);
    }

    // **`if !to_convert.is_empty()` at `automerge.rs:2014`**, and it is the whole
    // of case 3: nothing to convert opens **no transaction**, writes **no
    // operation** and commits **nothing**. Returning before [`Tx.open`] is what
    // makes that so; opening a transaction and committing an empty one would
    // add a change and fail the case.
    if (todo.items.len == 0) return;

    var tx = try Tx.open(gpa, doc);
    defer tx.deinit();
    for (todo.items) |c| {
        const text_id = try tx.putObject(c.obj_id, c.prop(), .text);
        try tx.spliceText(text_id, 0, 0, c.text);
    }
    _ = try tx.commit(null, null);
}

// ── 1. test_strings_in_maps_are_converted_to_text ────────────────────────────

test "strings in maps are converted to text" {
    // `convert_string_to_text.rs:7-31`
    //
    // **Encoding-dependent: not in its answer, yes in its path — and that is
    // measured, not assumed.** `want` is five ASCII bytes, and **all four
    // encodings measure that as five units *and* five operations**
    // ([`TextEncoding.width`](../src/types.zig):565-572 and the run logged in
    // the diff block), so the upstream payload cannot tell the four apart. The
    // path is different: `spliceText` writes **one operation per code point**
    // under the first three encodings and **one per grapheme cluster** under the
    // fourth, and each operation is then `w` units wide in that encoding's own
    // units. **A sweep over an ASCII payload cannot distinguish "one operation
    // per code point" from "one operation per unit", because for ASCII the two
    // agree** — so the sweep here proves the four paths agree on this payload
    // and does not claim they agree on a non-ASCII one. See
    // [`expectTextObjectContents`], whose rule was taken from a measurement of
    // `"a👩b"` and not from [`TextEncoding.width`].
    for (all_encodings) |enc| {
        var doc = try newDoc(enc);
        defer doc.deinit();

        // **`doc.put(ROOT, "somestring", "hello")`**
        // (`convert_string_to_text.rs:10`). **One `Tx`, one change**, because
        // upstream's `AutoCommit` opens one transaction lazily and holds it
        // across the rest ([`autocommit.rs`:445-457](../github-automerge-automerge/rust/automerge/src/autocommit.rs));
        // the port's autocommit door commits every call, so the same call
        // through it would be a different document.
        {
            var tx = try Tx.open(gpa, &doc);
            defer tx.deinit();
            _ = try tx.put(root, .{ .key = "somestring" }, .{ .str = "hello" });
            _ = try tx.commit(null, null);
        }

        // **One change before the migration**, which is what makes case 3's
        // "no change added" a statement about the migration and not about the
        // document.
        try testing.expectEqual(@as(usize, 1), try changeCount(&doc));

        const saved = try doc.save(gpa);
        defer gpa.free(saved);

        // `AutoCommit::load_with_options(&saved, …ConvertToText)`
        // (`convert_string_to_text.rs:13-17`) with the gap recorded at the top
        // of this file: the port has no `LoadOptions`, so this is the load and
        // then the conversion, which is the whole of what the option does
        // (`automerge.rs:991-993`).
        var loaded = try Document.load(gpa, io, saved, enc, .manual);
        defer loaded.deinit();

        try convertScalarStringsToText(&loaded);

        // `let Some((val, obj_id)) = val else …` /
        // `let Value::Object(obj) = val else …` / `let ObjType::Text = obj else …`
        // (`convert_string_to_text.rs:19-28`).
        const text_id = try expectTextObject(&loaded, root, .{ .key = "somestring" });

        // `let text = loaded.text(obj_id).unwrap(); assert_eq!(text, "hello");`
        // (`convert_string_to_text.rs:29-30`), plus the element sequence and the
        // marks that upstream does not check.
        try expectTextObjectContents(&loaded, text_id, "hello", enc);

        // **Exactly one change more**, which is `tx.put_object` and
        // `tx.splice_text` in the single transaction of `automerge.rs:2015-2020`.
        // A conversion written through the port's autocommit door would add two.
        try testing.expectEqual(@as(usize, 2), try changeCount(&loaded));

        try expectSameThroughApplyChanges(&loaded);
    }
}

// ── 2. test_strings_in_lists_are_converted_to_text ───────────────────────────

test "strings in lists are converted to text" {
    // `convert_string_to_text.rs:33-58`
    //
    // **Encoding-dependent: the same answer as case 1, for the same measured
    // reason** — `want` is five ASCII bytes and every encoding gives five units
    // and five operations. What differs from case 1 is **which door the
    // register is found through**: `Prop::Seq(found.index)`
    // ([`automerge.rs`:1991-2000](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // rather than `Prop::Map` (`:1989`), and that door is found by walking
    // `0..length` rather than a key walk. **A conversion that only ever read a
    // map's keys would find nothing here and case 1 would still pass** — which
    // is why the falsification that drops the sequence register fails this case
    // and only this case.
    for (all_encodings) |enc| {
        var doc = try newDoc(enc);
        defer doc.deinit();

        // **`doc.put_object(ROOT, "list", ObjType::List)` then
        // `doc.insert(&list, 0, "hello")`** (`convert_string_to_text.rs:36-37`),
        // **in one `Tx` and so in one change of two operations** — the same
        // single `AutoCommit` transaction as case 1.
        const list_id = blk: {
            var tx = try Tx.open(gpa, &doc);
            defer tx.deinit();
            const l = try tx.putObject(root, .{ .key = "list" }, .list);
            _ = try tx.insert(l, 0, .{ .str = "hello" });
            _ = try tx.commit(null, null);
            break :blk l;
        };
        try testing.expectEqual(@as(usize, 1), try changeCount(&doc));

        const saved = try doc.save(gpa);
        defer gpa.free(saved);

        var loaded = try Document.load(gpa, io, saved, enc, .manual);
        defer loaded.deinit();

        try convertScalarStringsToText(&loaded);

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

        var loaded = try Document.load(gpa, io, empty_document, enc, .manual);
        defer loaded.deinit();

        try convertScalarStringsToText(&loaded);

        // `let saved_again = loaded.save();` (`convert_string_to_text.rs:69`).
        const saved_again = try loaded.save(gpa);
        defer gpa.free(saved_again);

        // **`assert_eq!(empty_document.len(), saved_again.len());`**
        // (`convert_string_to_text.rs:71`). Upstream compares the two saved
        // documents' byte lengths, and so does this — **and the byte length is
        // the only place the two implementations may not agree**, because
        // `save()` is not required to be byte-identical across implementations
        // ([AGENTS.md](../AGENTS.md): *`save()` output is not required to be
        // byte-identical to the reference*). Both lengths here come from the
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
        var round = try Document.load(gpa, io, saved_again, enc, .manual);
        defer round.deinit();
        try testing.expectEqual(@as(usize, 0), try changeCount(&round));
    }
}

// ── Zig 0.16.0 / upstream / Rust / port ───────────────────────────────────────

// What this file changed about upstream's, and why, in one place.
//
// ## The gap: `LoadOptions` and `StringMigration` are not in the port
//
// All three cases call
// `AutoCommit::load_with_options(bytes, LoadOptions::new().migrate_strings(StringMigration::ConvertToText))`
// (`convert_string_to_text.rs`:13-17, `:40-44`, `:63-66`). **The port has no
// `LoadOptions`.** [`Document.load`](../src/doc.zig):3221-3233 is
// `load(gpa, bytes, encoding: TextEncoding, mode: Mode)` — the encoding is an
// argument because it is not in the file (`doc.zig`:3218-3220) and there is no
// options parameter beside it. `StringMigration` (`automerge.rs`:83-88) and
// `migrate_strings` (`automerge.rs`:152-157) appear nowhere in `src/`, and
// [API.md](../API.md) § Known gaps lists neither.
//
// **So what is not exercised is the load-with-options door and nothing else.**
// The option's whole effect is one line at `automerge.rs:991-993`:
//
// ```text
// if let StringMigration::ConvertToText = options.string_migration {
//     am.convert_scalar_strings_to_text()?;
// }
// ```
//
// and [`convertScalarStringsToText`] is
// [`Automerge::convert_scalar_strings_to_text`]
// ([`automerge.rs`:1973-2024](../github-automerge-automerge/rust/automerge/src/automerge.rs))
// transcribed onto [`Tx`]. **Each case therefore drives the migration
// explicitly, between the load and the assertions, and the load it drives is
// the port's.** A port that grew `LoadOptions` would make these three cases
// one call shorter each and change no assertion.
//
// ## The conversion runs on the *manual* flavour, and that is upstream's shape
//
// `convert_scalar_strings_to_text` is a method on the inner `Automerge` and is
// called from `load_with_options` **before** `AutoCommit` is wrapped around it
// (`automerge.rs`:991-993`), and it opens `self.transaction()` (`:2015`) — the
// manual door. So `AutoCommit::load_with_options` returns a document whose
// conversion was already done by a non-`AutoCommit` transaction, and every
// document below is loaded with `Mode.manual`. **[`Tx.open`](../src/transact.zig):462-466
// refuses any other mode**, so this is the mode upstream's own code path
// requires and not a port convenience.
//
// ## `AutoCommit`'s one transaction is `Tx`
//
// Upstream's `AutoCommit` opens a transaction lazily and holds it until a read,
// a save or an explicit commit ([`autocommit.rs`:445-457](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
// `:728-739`), so `put_object` then `insert` is **one change of two operations**.
// The port's autocommit free functions open, write and commit on every call
// ([`transact.zig`](../src/transact.zig):2781-2788), which [API.md](../API.md)
// § Write records as a **documented deviation** and notes it was *executed
// against the reference*. Every setup below therefore opens one [`Tx`], and
// **cases 1 and 2 assert the resulting change count**, which is what makes the
// choice load-bearing rather than cosmetic.
//
// ## `visible_slow` is the reader here
//
// Upstream's walk is `for (obj, ops) in self.ops.iter_objs()` over
// `ops.visible_slow(None)` ([`automerge.rs`:1980-2012](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
// **This file walks the same set through [`read.keys`](../src/read.zig) and
// [`read.get`](../src/read.zig)**, because
// [`vis.VisibleOpIter`](../src/opset/visible.zig) — upstream's
// `OpQuery::visible_slow` — **has no production caller in the port**, and
// [`op_set.zig`]:738-752 says so and says why: the port spells the same
// per-row rule directly instead, through [`OpSet.Grouped`](../src/opset/op_set.zig),
// and that module's own comment **names `automerge.rs:1983` as upstream's
// caller of the walk this file is reproducing**. So the set is the same by the
// port's own account:
//
// * **a register has exactly one visible op** — its winner — so a map's
//   visible ops and its winners are the same list, and a list's are the same
//   list as its indices;
// * **`Prop::Map` is a key walk and `Prop::Seq(index)` is an index walk**
//   (`:1989`, `:1999`), which is what [`collectConversions`] does;
// * **`.text` and `.table` are not walked** — the `_ => {}` arm at `:2010`.
//
// The one structural difference is the object list: [`OpSet.iterObjs`](../src/opset/op_set.zig)
// hands out boundary objects in row order and skips one the index does not
// hold (`op_set.zig`:2528-2533), which is upstream's `filter_map`
// (`op_set.rs`:1079).
//
// ## A `Keys` walk and `read.get` share one buffer
//
// [`read.keys`](../src/read.zig):771-774 warns that **only one `Keys` per
// document at a time**, and the op set has **one** shared successor buffer
// ([`op_set.zig`]:40-49) which `read.get` walks as well. [`collectConversions`]
// therefore **copies the keys out and frees the walk before the first `get`**,
// rather than calling `get` inside the key loop. Doing it the other way is a
// use-after-free dressed as a plausible-looking test.
//
// ## A sequence anchor is not a key and does not outlive a `next()`
//
// [`Keys.next`](../src/iter/keys.zig):181-184 renders a sequence anchor into the
// walk's **own** buffer, valid only until the next `next()`. A map key is the
// document's interned bytes instead ([`read.zig`]:760-764). Both are copied in
// [`collectConversions`], which is also what upstream does — `Prop::Map` takes
// an owned `SmolStr` (`:1989`) — and copying is **load-bearing rather than
// cautious** here, because the list is built before the transaction is opened
// (`:1979`, `:2014`) and the first `put_object` is a mutation that invalidates
// every slice borrowed out of the op set.
//
// ## `Value::Object(ObjType::Text)` is two reads here
//
// Upstream's `Value::Object(obj)` is one value carrying the object's **type**
// (`read.rs`:263, [`types.rs`:667-675](../github-automerge-automerge/rust/automerge/src/op_set2/types.rs)),
// so `let Value::Object(obj) = val` and `let ObjType::Text = obj` are two
// patterns on one value. The port's [`read.DocItem`](../src/read.zig):279-294
// splits them: `.value == .object` carries the [`ObjType`]
// ([`ValueRef`](../src/opset/types.zig):235-241) and `item.id` is the object's
// id. [`expectTextObject`] keeps upstream's **three** refusals as three, because
// upstream keeps three, and reads the type off the item rather than through
// [`Document.objectType`](../src/doc.zig).
//
// ## Upstream's `loaded.get(&list, 0)` uses the *pre-save* `ExId`
//
// `convert_string_to_text.rs`:46 reads the element through the id the
// **pre-save** document handed out, and case 2 does the same here rather than
// re-reading it from `root`. That is upstream's line and a stronger claim than
// the alternative: the id has to survive a save and a load. It does, because
// [`ExId`] carries the actor's **bytes** ([`exid.zig`]:15-18) and its
// `PartialEq` ignores the index (`:126-138`), so
// [`Document.resolve`](../src/doc.zig) finds it in the loaded document even
// though the actor table is numbered afresh.
//
// ## Four encodings, and upstream runs one
//
// Every case loops over [`all_encodings`]. **Upstream's file does not**: its
// `LoadOptions::new()` sets `text_encoding: TextEncoding::platform_default()`
// ([`automerge.rs`:181](../github-automerge-automerge/rust/automerge/src/automerge.rs))
// and its tests run on one platform. **This is a finding about the upstream
// file, not a divergence**: the conversion's only encoding-dependent step is
// `tx.splice_text` (`automerge.rs`:2018), and a case that runs only under
// `UnicodeCodePoint` never reaches [`countUtf16CodeUnits`] or
// [`countGraphemes`]. On this host the port's default is `.unicode_code_point`
// ([`doc.zig`]:5580-5582), so upstream's single encoding is the first of the
// four here.
//
// **Which of the three are encoding-dependent, measured rather than argued.**
// A throwaway probe against this port, `"a👩b"` through `spliceText`:
//
// ```text
// unicode_code_point: len=3   elements 1, 4, 1 bytes at index 0, 1, 2
// utf8_code_unit:     len=6   elements 1, 4, 4, 4, 4, 1 bytes at index 0..5
// utf16_code_unit:    len=4   elements 1, 4, 4, 1 bytes at index 0..3
// grapheme_cluster:   len=3   elements 1, 4, 1 bytes at index 0, 1, 2
// ```
//
// So the rule is **one operation per code point** under the first three and
// **one per grapheme cluster** under the fourth, each operation `w` units wide
// in its own encoding — and `read.get` at any index *inside* a wide operation
// answers that operation again. That is the same sentence the port writes for
// UTF-16 at [`read.zig`]:3890-3894, and **this file got `.utf8_code_unit`
// wrong first**, treating it as one operation per *byte* on the strength of
// [`TextEncoding.width`](../src/types.zig):568 and [`read.zig`]:3719-3721. The
// measurement is what caught it: a run with `"a👩b"` failed
// `expected <one byte 0xf0>, found <four bytes 👩>` under `.utf8_code_unit`
// only. **A unit count is not an operation count, and the difference is
// invisible for ASCII.**
//
// **Against the upstream payload**, `"hello"` is five units and five operations
// under **all four** — measured, not inferred — so **cases 1 and 2 are
// encoding-independent in their answers and encoding-dependent only in the path
// they walk**, and **case 3 is encoding-independent outright** (no text and no
// string in it, so no encoding is consulted). The sweep proves the four paths
// agree on `"hello"`; it does **not** claim they agree on a non-ASCII payload,
// and that claim would need upstream's own file to carry one. Re-running cases
// 1 and 2 with `"a👩b"` substituted for `"hello"` passes under all four, so
// [`expectTextObjectContents`] is not itself ASCII-only — but that run is a
// throwaway measurement and **is not one of the three upstream cases.**
//
// ## The assertions are the element sequence, not the length
//
// [`expectTextObjectContents`] compares the length, then **every element one at
// a time** at each element's first index, then the marks **by name and by
// span**, then the joined text. The length is checked against
// `enc.width(want)` rather than `want.len`, and the walk's own total is checked
// against the same number — which is the *unit* count, while the elements
// compared are *operations*, and the two differ under three of the four
// encodings for any non-ASCII payload. The marks are empty because
// [`read.marks`](../src/read.zig):888-890 **drops an unmark** — a mark whose
// value is `null` — as a tombstone, so the assertion is "no *live* mark", and
// the diagnostic names each mark and both ends of its span.
//
// ## `merge`, `getHeads` and every owned result
//
// [`Document.getHeads`](../src/doc.zig):4507-4510 hands back a **copy**, and
// case 3 binds and frees it; every saved byte string, every change list, every
// `[]Change` view, every mark list and every copied key and string comes out of
// [`gpa`]. An unfreed owned result is an `ABRT` in the leak arbiter, which kills
// the binary and hides every test after it — so the free is not hygiene, it is
// what makes the rest of the file's output readable.
//
// ## It has teeth: two falsifications, both reverted
//
// Each perturbation was made to **this file**, run against the **real tree**
// (`-Mzautomerge=src/root.zig`, not a copy), and reverted immediately;
// `sha256sum` of the file before and after is identical
// (`675290e20d89cad16d9296d7ddec46a9b504e5cedad2a1fbdf53360787e410b8`).
//
// **The check, and why the exit code is not it.** Each run was measured with all
// three of [plan.md §1.1](../docs/plan.md): a non-zero exit, **zero** lines
// matching `<file>.zig:<line>:<col>: error:`, and a **non-zero** count of
// `FAIL`. **The `FAIL` count is the signal** — a compile error produces *zero*
// failures, not many, so an `exit=1` read on its own would have been read here
// as three failing tests when nothing had run at all. Three earlier runs in
// this file's own history show why: two were compile errors in this file
// (`unattached documentation comment`, then a `*const Document` handed to
// `getChanges`) and **both reported `exit=1` with `FAIL=0`** — which is exactly
// the shape §1.1 warns about, arrived at from the other direction.
//
// | perturbation | exit | compile errors | `FAIL` | which tests, and the diagnostic |
// | --- | --- | --- | --- | --- |
// | `spliceText(text_id, 0, 0, "")` — the conversion writes no characters | 1 | **0** | **2** | cases 1 and 2, both `expected 5, found 0` |
// | [`withActorBytes`] returns its argument — upstream's `id_to_exid` dropped | 1 | **0** | **1** | case 2 **only**, `error.NotAnObject` |
// | none (the file as committed) | 0 | 0 | 0 | all three `OK` |
//
// **The gated build was run too, and it is green.** Every run above used the
// **default** value of `check_slow_paths`
// ([`op_set.zig`:4198-4230](../src/opset/op_set.zig)) — `false` unless
// `-Dslow-path` is passed — and that constant is what gates the fast/slow seek
// cross-check at [`op_set.zig`]:2844-2852. **Re-run with
// `check_slow_paths = true`** and the result is identical: `exit=0`, zero
// compile errors, zero `FAIL`, zero leaks, 3/3 `OK`. **The cross-check is
// reachable from this file** — the per-element reads in
// [`expectTextObjectContents`] go through the seek — **so none of these three
// cases' green rests on the gate being off.**
//
// The first is the one that matters most: **a length assertion catches it, and
// an *upstream-only* assertion does not.** Splicing nothing leaves the text
// object with **zero** elements where [`expectTextObjectContents`] expects five
// — and `assert_eq!(text, "hello")` ([`convert_string_to_text.rs`:29-30](../github-automerge-automerge/rust/automerge/tests/convert_string_to_text.rs))
// would catch it too. What the **element sequence** adds is that the failure is
// located: the diagnostic names the encoding, the index and the bytes, so a
// splice that wrote the right number of elements in the wrong units is a
// different failure from a splice that wrote none.
//
// The second is narrow on purpose and says something the first cannot: it fails
// **case 2 and only case 2**, because the map door and the sequence door are
// different walks and only the sequence door reaches its object through an
// index-only [`ExId`].
