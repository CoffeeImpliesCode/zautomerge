//! `$AUTOMERGE_REF/rust/automerge/tests/batch_insert.rs` — **all 46
//! `#[test]` cases, ported case for case and in upstream's order**.
//!
//! # What this file is
//!
//! Upstream's `batch_insert.rs` is 1,066 lines and 46 cases, and **none of
//! them was ported** before this file. An audit that counted the port's
//! upstream test names found 286 `hexane` names with one ported and this file
//! at zero of forty-six, and named it the weakest gate in the port — a
//! **phase gate**, not a test-file gap, which is why it matters more than its
//! size suggests.
//!
//! The file is a **consumer test**: it imports `zautomerge` by name, sets no
//! working directory and reads no fixture, and it is built as its own module
//! with its own `addTest` in [`build.zig`](../build.zig). That is the same
//! shape [`upstream_doc_test.zig`](upstream_doc_test.zig) and
//! [`upstream_text_more.zig`](upstream_text_more.zig) have, and it is a second
//! file rather than the tail of `upstream_doc_test.zig` for two reasons: that
//! file is large and owned, and "the batch suite" is honest about being the
//! batch suite.
//!
//! # Why the cases exist: row order and contiguity
//!
//! [`BatchInsertion::next_pos`]
//! ([`inner.rs`:1460-1462](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
//! **computes each operation's row from the ones before it**, and
//! [`BatchInsertion::finish`] ([`inner.rs`:1514-1519]) writes the whole batch
//! with **one** [`OpSet.splice`](../src/opset/op_set.zig). So every case below
//! is about where rows land, not about which values read back.
//!
//! Two upstream rules decide that, and the port reproduces both:
//!
//! * **A map's keys are sorted before anything is written** —
//!   [`batch_bfs`] ([`inner.rs`:1546-1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
//!   collects `map.iter()` into a vector and sorts it. The port's
//!   [`Batch.bfs`](../src/transact.zig) sorts the same way. A **list** is not
//!   sorted by anything: `batch_bfs` walks it by index
//!   ([`inner.rs`:1573-1592](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//!   so the order written is the order held.
//! * **A map reader does not sort.** "The reader does not sort, so this order
//!   is the answer order" ([`map_range.zig`:1486-1490](../src/iter/map_range.zig))
//!   — which is upstream's rule **R2** ([`op.rs`:1059-1060](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
//!
//! **So a wrong row order reads back as a different map**, and a test that
//! checks contents rather than order passes on it. That is why
//! [`expectKeys`] exists here and is called from every case that batch-writes
//! a multi-register map: it compares the key walk **in row order**, one key at
//! a time, and a count would pass on two wrong things.
//!
//! **And a second assertion, which is not a restatement of it.**
//! [`expectKeys`] catches a wrong order *in one document*.
//! [`expectSameThroughApplyChanges`] catches a document whose **local route and
//! applied route disagree**, by replaying the same operations through
//! `Document.applyChanges` and requiring the two documents to be the same one.
//! A wrong order **both** routes agree on is the case neither can catch, which is
//! why both are here rather than one. It is called from **45 sites across 43 of
//! the 47 cases**.
//!
//! # The API narrowing, stated once
//!
//! Upstream's [`batch_create_object`]
//! ([`inner.rs`:1269-1331](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
//! takes a whole `hydrate::Value` and fills it. `API.md` narrows the port's
//! [`batchCreateObject`](../src/transact.zig) to an `ObjType`, so it makes an
//! object and leaves it empty, and [`batchCreateValue`](../src/transact.zig) —
//! documented there as **not in `API.md`, and not optional** — is upstream's
//! method. Every upstream `batch_create_object(…, &value, …)` below is
//! `batchCreateValue`; upstream's type-only form is not exercised by this file
//! and [`transact.zig`'s own test](../src/transact.zig) covers it.
//!
//! # The leak arbiter, and the one ownership rule that is a move
//!
//! [`gpa`] is [`std.testing.allocator`] and **every owned value below comes
//! out of it**: every document, every saved byte string, every head list
//! ([`Document.getHeads`](../src/doc.zig) returns a copy the caller frees),
//! every patch batch, and **every mirror value** this file builds.
//!
//! [`MirrorMap.putOwned`] ([`hydrate.zig`](../src/hydrate.zig):981-993) and
//! [`MirrorList.push`] ([`:1200-1204`](../src/hydrate.zig)) **take the value
//! over** — the container owns it, structure and bytes — which is what
//! upstream's `entries.insert(key, value)` and `vec.push(value)` do. A
//! `Mirror` handed to one of them must **not** be deinit'd, and a `Mirror`
//! that has not been handed to one must be. [`putChild`] and [`pushChild`]
//! exist so that a nested mirror is built **inside** the call and is never
//! named by the caller:
//!
//! ```zig
//! try putChild(&user, "scores", try listScalars(&.{ .{ .int = 10 } }));
//! ```
//!
//! The mirror a **document** is handed is the other way round:
//! [`batchCreateValue`](../src/transact.zig), [`splice`](../src/transact.zig)
//! and [`initRootFromHydrate`](../src/transact.zig) take their value by value
//! and [`Queue.push`](../src/transact.zig) stores a `*const hydmod.Value`, so
//! the batch **borrows** it and copies out of it. The local keeps ownership
//! and `defer value.deinit()` is correct.

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
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ChangeHash = am.ChangeHash;
const ActorId = am.ActorId;
const Patch = am.patches.Patch;
const Mirror = am.hydrate.Value;
const MirrorMap = am.hydrate.Map;
const MirrorList = am.hydrate.List;
const Tx = am.manual_transaction.Transaction;
const trans = am.transaction;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── Actors ───────────────────────────────────────────────────────────────────

/// **Upstream draws an actor at random and this file names every one of them.**
///
/// `AutoCommit::new` takes its actor from `ActorId::random`
/// ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// which is right for a test suite and wrong for a failure that cannot be
/// reproduced. [`test/upstream_doc_test.zig`](upstream_doc_test.zig) says the
/// same thing and does the same thing, so this file mints its actors from a
/// counter: distinct bytes, a stable order, the same bytes on every run.
///
/// The bytes start at one so that no document ever has an **empty** actor,
/// which is a different value from every other one.
var minted_actors: [512][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] and [`newManualDoc`] hand out.
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

/// A new document in the autocommit flavour ([`AutoCommit::new`](../src/doc.zig)).
fn newDoc() !Document {
    var doc = try Document.init(gpa, io, .auto);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

/// The same in the manual flavour ([`Automerge::new`](../src/doc.zig)), which
/// is what a transaction and a rollback need: the autocommit door commits
/// every call.
fn newManualDoc() !Document {
    var doc = try Document.init(gpa, io, .manual);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `prop`, or `error.NoSuchKey` when nothing is there and
/// `error.NotAnObject` when an object is — upstream's
/// `doc.get(&obj, prop).unwrap().unwrap().0` narrowed to the scalar case.
fn scalarAt(doc: *const Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The id of the object at `prop`, or `error.NoSuchKey`. Upstream's
/// `doc.get(&obj, prop).unwrap().unwrap().1`.
fn objectAt(doc: *const Document, obj: ExId, prop: Prop) !ExId {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

/// `doc.get(&obj, prop).unwrap().unwrap().0 == Value::Object(t)`: the value at
/// `prop` is an object, and it is of type `want`.
///
/// **The type is read from the object, not from the property.** Upstream's
/// `Value::Object(ObjType::Map)` is one value carrying both facts, and the
/// port's [`DocItem`](../src/read.zig) splits them: the tag says *object*, and
/// [`Document.objectType`](../src/doc.zig) says which.
fn expectObjType(doc: *const Document, obj: ExId, prop: Prop, want: ObjType) !void {
    const id = try objectAt(doc, obj, prop);
    const got = try doc.objectType(id);
    if (got != want) {
        std.debug.print("object at {s} is a {t}, want a {t}\n", .{ @tagName(prop), got, want });
        return error.UnexpectedObjType;
    }
}

/// `Value::str(s)` at `prop`, compared **by content**.
///
/// **Not `expectEqual` on a [`ScalarValue`]:** that helper uses `std.meta.eql`,
/// which for a slice is the pointer and the length, so a `str` read out of the
/// document would never equal a literal.
fn expectStr(doc: *const Document, obj: ExId, prop: Prop, want: []const u8) !void {
    const got = try scalarAt(doc, obj, prop);
    if (got != .str) {
        std.debug.print("value at {s} is a {t}, want a str\n", .{ @tagName(prop), got });
        return error.UnexpectedScalarType;
    }
    try testing.expectEqualStrings(want, got.str);
}

/// `Value::int(i)` at `prop`. The tag is checked, so an `i64` and a `u64` of
/// the same value are not one value.
fn expectInt(doc: *const Document, obj: ExId, prop: Prop, want: i64) !void {
    const got = try scalarAt(doc, obj, prop);
    if (got != .int) {
        std.debug.print("value at {s} is a {t}, want an int\n", .{ @tagName(prop), got });
        return error.UnexpectedScalarType;
    }
    try testing.expectEqual(want, got.int);
}

/// `ScalarValue::Boolean(b)` at `prop` — upstream's `vbool`.
fn expectBool(doc: *const Document, obj: ExId, prop: Prop, want: bool) !void {
    const got = try scalarAt(doc, obj, prop);
    if (got != .bool_value) {
        std.debug.print("value at {s} is a {t}, want a bool\n", .{ @tagName(prop), got });
        return error.UnexpectedScalarType;
    }
    try testing.expectEqual(want, got.bool_value);
}

/// The text of `obj`, compared with `want` and freed.
///
/// **A helper and not a `defer` at every call site**, because
/// [`am.read.text`](../src/read.zig) returns a **caller-owned** string.
fn expectText(doc: *const Document, obj: ExId, want: []const u8) !void {
    const got = try am.read.text(doc, obj, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// `doc.length(&obj)`.
fn expectLength(doc: *const Document, obj: ExId, want: usize) !void {
    try testing.expectEqual(want, try am.read.length(doc, obj));
}

/// The text of the text object at `index`.
fn expectTextAt(doc: *const Document, list: ExId, index: usize, want: []const u8) !void {
    const id = try objectAt(doc, list, .{ .index = index });
    try expectText(doc, id, want);
}

/// The string at `index`.
fn expectStrAt(doc: *const Document, list: ExId, index: usize, want: []const u8) !void {
    const prop: Prop = .{ .index = index };
    const got = try scalarAt(doc, list, prop);
    if (got != .str) {
        std.debug.print("element {d} is a {t}, want a str\n", .{ index, got });
        return error.UnexpectedScalarType;
    }
    try testing.expectEqualStrings(want, got.str);
}

/// The integer at `index`.
fn expectIntAt(doc: *const Document, list: ExId, index: usize, want: i64) !void {
    const prop: Prop = .{ .index = index };
    const got = try scalarAt(doc, list, prop);
    if (got != .int) {
        std.debug.print("element {d} is a {t}, want an int\n", .{ index, got });
        return error.UnexpectedScalarType;
    }
    try testing.expectEqual(want, got.int);
}

/// The object's keys **in row order**, compared one at a time
/// ([`read.keys`](../src/read.zig), `read.rs:50`).
///
/// **This is the assertion these cases exist to make, and it is not a count.**
/// [`batch_bfs`] sorts a map's keys before it writes them
/// ([`inner.rs`:1546-1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// so a batch that wrote them in another order, or at the wrong rows, produces
/// a document whose map reader answers **in that order** — "the reader does
/// not sort, so this order is the answer order"
/// ([`map_range.zig`:1486-1490](../src/iter/map_range.zig)). Every lookup
/// beside it would still find its key; only the order would be wrong, and a
/// contents-only check would not see it.
///
/// **The keys are copied, not borrowed.** [`Keys.next`](../src/iter/keys.zig)
/// renders a sequence anchor into a buffer the walk owns and overwrites, and a
/// map key borrows the op set's string table
/// ([`keys.zig`](../src/iter/keys.zig) *The key is borrowed, not owned*).
fn expectKeys(doc: *const Document, obj: ExId, want: []const []const u8) !void {
    var keys = try am.read.keys(doc, obj);
    defer keys.deinit(gpa);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |k| gpa.free(k);
        got.deinit(gpa);
    }
    while (try keys.next()) |key| try got.append(gpa, try gpa.dupe(u8, key));
    if (got.items.len != want.len) {
        std.debug.print("object has {d} visible key(s) {any}, want {d}\n", .{
            got.items.len, got.items, want.len,
        });
        return error.KeySetMismatch;
    }
    for (got.items, want, 0..) |g, w, i| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print("key {d} is \"{s}\" in row order, want \"{s}\"\n", .{ i, g, w });
            return error.KeysOutOfRowOrder;
        }
    }
}

/// Upstream's `doc.get_heads()` on an `AutoCommit`: the isolation first, then
/// the graph's heads ([`autocommit.rs`:695-700](../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
/// The caller frees the result.
fn headsOf(doc: *const Document) ![]ChangeHash {
    if (doc.isolationHeads()) |at| return gpa.dupe(ChangeHash, at);
    return doc.getHeads(gpa);
}

/// [`Document.fork`](../src/doc.zig) through [`Document.forkAt`](../src/doc.zig)
/// at the document's own heads, which is what `fork` means.
///
/// **A named actor, not [`Document.fork`](../src/doc.zig)'s random one.** That
/// call mints through the source's retained `io`, so its actor differs on
/// every run. **And this is determinism, not a leak**: `fork` allocates the
/// actor from the **fork's own** arena, which [`Document.deinit`] frees.
fn forkDoc(src: *Document) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    return src.forkAt(gpa, heads, .auto);
}

/// `doc.hydrate(&obj, None)`: the mirror of `obj` at the present. The port
/// reaches the same mirror through [`hydrate.hydrateMap`](../src/hydrate.zig),
/// which takes the op set and an optional clock rather than a document.
fn hydrateObj(doc: *Document, obj: ExId) !Mirror {
    return am.hydrate.hydrateMap(am.doc.Set, &doc.ops, gpa, obj, null);
}

/// `doc.hydrate(ROOT, None)`.
fn hydrateNow(doc: *Document) !Mirror {
    return hydrateObj(doc, root);
}

// ── The second assertion: the write path against the read path ───────────────

/// [`Document.getChanges`](../src/doc.zig)'s list as the `[]Change`
/// [`Document.applyChanges`](../src/doc.zig) takes. **The caller frees the
/// array**; the [`Change`] values borrow the list's bodies, so the list outlives
/// the call.
fn changeViews(list: *const am.doc.Changes) ![]am.change_record.Change {
    const out = try gpa.alloc(am.change_record.Change, list.len());
    errdefer gpa.free(out);
    for (0..list.len()) |i| out[i] = list.at(i);
    return out;
}

/// **The other half of what [`expectKeys`] is for, and neither half subsumes
/// the other.**
///
/// A case above builds its document through the port's **write path** — the
/// free functions or a [`Tx`] — and this replays the same operations through the
/// **read path**, `Document.applyChanges`, and requires the two documents to be
/// the same document.
///
/// [`BatchInsertion::next_pos`] ([`inner.rs`:1460-1462](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// computes each operation's row from the ones before it and
/// [`BatchInsertion::finish`] ([`inner.rs`:1514-1519](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// writes the whole batch with one splice, while `Document.applyChanges` screens
/// and applies the same operations **per change**. **Two different routes to the
/// same rows.**
///
/// **What each assertion catches, and why both are needed:**
///
/// * [`expectKeys`] catches **a wrong order** — the document's own rows are in
///   the wrong place, so the map reader answers in the wrong order.
/// * this catches **a divergence between the two paths** — a document whose
///   local route and whose applied route disagree, which a same-document
///   [`expectKeys`] call cannot see at all because it only ever looks at one
///   document.
///
/// A perturbation to `Batch.bfs`'s key sort is caught by both, for the same
/// reason: a wrong order is also a divergence. **The case neither catches is a
/// wrong order both paths agree on**, and that is what makes this one worth its
/// own assertion rather than being read as a restatement of [`expectKeys`].
///
/// **The row order is compared first, and structurally.**
/// [`Document.debugCmp`] is "row for row and byte for byte"
/// ([`op_set.rs`:69-71](../github-automerge-automerge/rust/automerge/src/op_set.rs)),
/// so a row-order divergence fails there with a diagnostic naming the fault,
/// before a content comparison can paper over it. The mirror comparison is
/// second and is there to catch a divergence the op set does not show.
fn expectSameThroughApplyChanges(doc: *Document) !void {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    // A document that holds no change cannot carry both shapes, and
    // `applyChanges` on an empty list is a no-op that would pass for the wrong
    // reason.
    if (all.len() == 0) return;

    const view = try changeViews(&all);
    defer gpa.free(view);

    var applied = try Document.init(gpa, io, .auto);
    defer applied.deinit();
    applied.setActorId(mintActor());
    _ = try applied.applyChanges(gpa, view);

    // **First the rows, then the content.**
    try applied.debugCmp(doc);

    var written = try hydrateNow(doc);
    defer written.deinit();
    var replayed = try hydrateNow(&applied);
    defer replayed.deinit();
    if (!written.eql(&replayed)) {
        std.debug.print(
            "\nthe write path and applyChanges materialise differently\n",
            .{},
        );
        return error.ReplayDiffers;
    }
}

// ── Mirror builders ──────────────────────────────────────────────────────────

/// One map register, built from a [`ScalarValue`].
const Reg = struct { key: []const u8, value: ScalarValue };

/// `hydrate_map!{…}` over **scalar** registers, in the order written. The
/// returned [`Mirror`] is owned by the caller.
///
/// **The order here is the order the registers are *asked for*, not the order
/// the document will hold them**: [`batch_bfs`] sorts
/// ([`inner.rs`:1546-1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// which is exactly what the [`expectKeys`] assertions below check. Writing
/// them out of sorted order on purpose is the stronger transcription — the
/// test then fails if the sort is gone.
fn mapScalars(regs: []const Reg) !Mirror {
    var m = MirrorMap.init(gpa, .root);
    errdefer m.deinit();
    for (regs) |r| try m.putOwned(r.key, .{ .value = .scalar(r.value), .conflict = false });
    return .{ .object = .{ .map = m } };
}

/// `hydrate_list![…]` over scalars, **in the order written**. A list is not
/// sorted by anything: [`batch_bfs`] walks it by index
/// ([`inner.rs`:1573-1592](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
/// so this order is the order the document holds.
fn listScalars(vals: []const ScalarValue) !Mirror {
    var l = MirrorList.init(gpa, .root);
    errdefer l.deinit();
    for (vals) |v| try l.push(.scalar(v), false);
    return .{ .object = .{ .list = l } };
}

/// `hydrate::Value::Text(Text::new(TextEncoding::UnicodeCodePoint, s))`
/// ([`hydrate/text.rs`:64-69](../github-automerge-automerge/rust/automerge/src/hydrate/text.rs)).
/// The returned [`Mirror`] is owned by the caller.
fn textMirror(s: []const u8) !Mirror {
    return Mirror.text(gpa, .unicode_code_point, s);
}

/// Puts `value` at `key` and **takes it over** — after this line `value` must
/// not be deinit'd ([`MirrorMap.putOwned`](../src/hydrate.zig):965-993).
///
/// **A helper so a nested mirror is never named.** `try putChild(&m, "k", try
/// listScalars(…))` builds the nested value inside the call and hands it
/// straight over; the alternative, `var scores = …; defer scores.deinit(); try
/// putChild(&m, "k", scores);`, is a double free.
fn putChild(m: *MirrorMap, key: []const u8, value: Mirror) !void {
    try m.putOwned(key, .{ .value = value, .conflict = false });
}

/// The list counterpart of [`putChild`] ([`MirrorList.push`](../src/hydrate.zig):1195-1204).
fn pushChild(l: *MirrorList, value: Mirror) !void {
    try l.push(value, false);
}

/// Every named register of a hydrated map, compared with `want` by key and by
/// content — upstream's `assert_eq!(map.get("name"), Some(&hydrate::Value::from("test")))`
/// over the arms it has a literal for.
///
/// **No count is compared, and that is upstream's shape rather than a
/// concession.** `batch_insert_matches_hydrate_output` is three independent
/// lookups (`batch_insert.rs`:447-452): `map.get("name")`, `map.get("count")`
/// and a `match map.get("tags")`. Upstream never asks how many registers the
/// map holds, and **a count passes on two wrong things** — a map that dropped
/// a register and a map that gained one both have the wrong total while every
/// key upstream names reads back correctly.
///
/// **The `tags` register is deliberately absent from `want`.** Upstream checks
/// it with a `match` that accepts a list and refuses anything else, and the
/// caller below does exactly that.
fn expectMirrorMapKeys(m: *const MirrorMap, want: []const Reg) !void {
    for (want) |r| {
        const got = m.get(r.key) orelse {
            std.debug.print("mirror has no register \"{s}\"\n", .{r.key});
            return error.MirrorShapeMismatch;
        };
        if (!got.eql(&.scalar(r.value))) {
            std.debug.print("mirror[\"{s}\"] is {any}, want {any}\n", .{ r.key, got.*, r.value });
            return error.MirrorValueMismatch;
        }
    }
}

// ── Patch-stream helpers ────────────────────────────────────────────────────

/// Whether any patch is a `PutMap` for `key` — upstream's
/// `matches!(p.action, PatchAction::PutMap { key, .. } if key == "data")`.
fn hasPutMapFor(stream: []const Patch, key: []const u8) bool {
    for (stream) |p| switch (p.action) {
        .put_map => |a| if (std.mem.eql(u8, a.key, key)) return true,
        else => {},
    };
    return false;
}

/// Whether any patch is a `SpliceText` — upstream's
/// `matches!(p.action, PatchAction::SpliceText { .. })`.
fn hasSpliceText(stream: []const Patch) bool {
    for (stream) |p| switch (p.action) {
        .splice_text => return true,
        else => {},
    };
    return false;
}

// ── 1-5. `batch_create_object` over a flat map, nested maps, an overwrite ────

test "batch: batch_insert_flat_map" {
    var doc = try newDoc();
    defer doc.deinit();
    // **Written out of sorted order on purpose**: `batch_bfs` sorts
    // (`inner.rs`:1546-1547), and a literal already in sorted order would pass
    // a document whose rows were in the literal's order too.
    var value = try mapScalars(&.{
        .{ .key = "c", .value = .{ .bool_value = true } },
        .{ .key = "a", .value = .{ .str = "hello" } },
        .{ .key = "b", .value = .{ .int = 42 } },
    });
    defer value.deinit();
    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, value, false);

    try expectObjType(&doc, root, .{ .key = "data" }, .map);
    try expectStr(&doc, obj_id, .{ .key = "a" }, "hello");
    try expectInt(&doc, obj_id, .{ .key = "b" }, 42);
    try expectBool(&doc, obj_id, .{ .key = "c" }, true);
    try expectKeys(&doc, obj_id, &.{ "a", "b", "c" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_nested_maps" {
    var doc = try newDoc();
    defer doc.deinit();
    var outer = MirrorMap.init(gpa, .root);
    try outer.putOwned("inner_a", .{ .value = .scalar(.{ .str = "deep" }), .conflict = false });
    try outer.putOwned("inner_b", .{ .value = .scalar(.{ .int = 99 }), .conflict = false });
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();
    // **Upstream's literal is already in sorted order** — `{ "outer" => {…},
    // "top_level" => "flat" }`, and `o` < `t` — so there is nothing to prove
    // about the sort here. What the two [`expectKeys`] calls at the end of
    // this case pin is that **two levels of it** come out in that order, the
    // outer object's and the nested one's, which a batch that wrote a child
    // before its parent would break.
    try putChild(&value, "outer", .{ .object = .{ .map = outer } });
    try value.putOwned("top_level", .{ .value = .scalar(.{ .str = "flat" }), .conflict = false });

    const root_obj = try trans.batchCreateValue(&doc, root, .{ .key = "nested" }, .{ .object = .{ .map = value } }, false);

    try expectObjType(&doc, root_obj, .{ .key = "outer" }, .map);
    const outer_id = try objectAt(&doc, root_obj, .{ .key = "outer" });
    try expectStr(&doc, outer_id, .{ .key = "inner_a" }, "deep");
    try expectInt(&doc, outer_id, .{ .key = "inner_b" }, 99);
    try expectStr(&doc, root_obj, .{ .key = "top_level" }, "flat");
    try expectKeys(&doc, root_obj, &.{ "outer", "top_level" });
    try expectKeys(&doc, outer_id, &.{ "inner_a", "inner_b" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_map_overwrites_existing_key" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try trans.put(&doc, root, .{ .key = "key" }, .{ .str = "old_value" });
    try expectStr(&doc, root, .{ .key = "key" }, "old_value");

    var value = try mapScalars(&.{.{ .key = "child", .value = .{ .str = "new" } }});
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "key" }, value, false);

    try expectObjType(&doc, root, .{ .key = "key" }, .map);
    try expectKeys(&doc, root, &.{"key"});
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_flat_list" {
    var doc = try newDoc();
    defer doc.deinit();
    var value = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
    defer value.deinit();
    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "nums" }, value, false);

    try expectLength(&doc, obj_id, 3);
    try expectIntAt(&doc, obj_id, 0, 1);
    try expectIntAt(&doc, obj_id, 1, 2);
    try expectIntAt(&doc, obj_id, 2, 3);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_list_with_nested_objects" {
    var doc = try newDoc();
    defer doc.deinit();
    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    var bob = MirrorMap.init(gpa, .root);
    try bob.putOwned("name", .{ .value = .scalar(.{ .str = "bob" }), .conflict = false });
    var users = MirrorList.init(gpa, .root);
    defer users.deinit();
    try pushChild(&users, .{ .object = .{ .map = alice } });
    try pushChild(&users, .{ .object = .{ .map = bob } });

    const list_id = try trans.batchCreateValue(&doc, root, .{ .key = "users" }, .{ .object = .{ .list = users } }, false);

    try expectLength(&doc, list_id, 2);
    try expectObjType(&doc, list_id, .{ .index = 0 }, .map);
    const alice_id = try objectAt(&doc, list_id, .{ .index = 0 });
    try expectStr(&doc, alice_id, .{ .key = "name" }, "alice");
    try expectObjType(&doc, list_id, .{ .index = 1 }, .map);
    const bob_id = try objectAt(&doc, list_id, .{ .index = 1 });
    try expectStr(&doc, bob_id, .{ .key = "name" }, "bob");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 6-9. a scalar, and three list positions ──────────────────────────────────

test "batch: batch_insert_scalar_fails" {
    var doc = try newDoc();
    defer doc.deinit();
    // **The error is named rather than only refused.** Upstream writes
    // `let Err(_) = … else { panic!(…) }` and stops there
    // (`batch_insert.rs`:130-136), but `inner.rs`:1288-1293 says which arm
    // this is — `hydrate::Value::Scalar(_) => return Err(NotAnObject)` — so
    // the port asserts the arm instead of a bare `Err(_)`.
    try testing.expectError(
        error.NotAnObject,
        trans.batchCreateValue(&doc, root, .{ .key = "foo" }, .scalar(.{ .int = 1 }), false),
    );
}

test "batch: batch_insert_into_list_at_end" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "first" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "second" });

    var value = try mapScalars(&.{.{ .key = "key", .value = .{ .str = "third" } }});
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, list_id, .{ .index = 2 }, value, true);

    try expectLength(&doc, list_id, 3);
    try expectStrAt(&doc, list_id, 0, "first");
    try expectStrAt(&doc, list_id, 1, "second");
    try expectObjType(&doc, list_id, .{ .index = 2 }, .map);
    const third_id = try objectAt(&doc, list_id, .{ .index = 2 });
    try expectStr(&doc, third_id, .{ .key = "key" }, "third");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_into_list_at_middle" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "a" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "c" });

    // **Insert at index 1 with insert=true, shifting "c" to index 2** — the
    // comment upstream carries (`batch_insert.rs`:172-173), and the assertion
    // that makes it mean something.
    var value = try mapScalars(&.{.{ .key = "val", .value = .{ .str = "b" } }});
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, list_id, .{ .index = 1 }, value, true);

    try expectLength(&doc, list_id, 3);
    try expectStrAt(&doc, list_id, 0, "a");
    try expectObjType(&doc, list_id, .{ .index = 1 }, .map);
    try expectStrAt(&doc, list_id, 2, "c");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_put_overwrites_existing_list_element" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "old_a" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "old_b" });
    _ = try trans.insert(&doc, list_id, 2, .{ .str = "old_c" });

    // Overwrite element at index 1 with a map using insert=false
    var value = try mapScalars(&.{.{ .key = "replaced", .value = .{ .bool_value = true } }});
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, list_id, .{ .index = 1 }, value, false);

    // Length should stay the same (overwrite, not insert)
    try expectLength(&doc, list_id, 3);
    try expectStrAt(&doc, list_id, 0, "old_a");
    try expectObjType(&doc, list_id, .{ .index = 1 }, .map);
    const replaced_id = try objectAt(&doc, list_id, .{ .index = 1 });
    try expectBool(&doc, replaced_id, .{ .key = "replaced" }, true);
    try expectStrAt(&doc, list_id, 2, "old_c");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 10-13. text, and three depths of nesting ─────────────────────────────────

test "batch: batch_insert_with_text" {
    var doc = try newDoc();
    defer doc.deinit();
    const greeting = try textMirror("hello world");
    var data = MirrorMap.init(gpa, .root);
    defer data.deinit();
    try putChild(&data, "greeting", greeting);

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = data } }, false);

    try expectObjType(&doc, obj_id, .{ .key = "greeting" }, .text);
    const text_id = try objectAt(&doc, obj_id, .{ .key = "greeting" });
    try expectText(&doc, text_id, "hello world");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_text_in_list" {
    var doc = try newDoc();
    defer doc.deinit();
    const one = try textMirror("one");
    const two = try textMirror("two");
    var texts = MirrorList.init(gpa, .root);
    defer texts.deinit();
    try pushChild(&texts, one);
    try pushChild(&texts, two);

    const list_id = try trans.batchCreateValue(&doc, root, .{ .key = "texts" }, .{ .object = .{ .list = texts } }, false);

    try expectLength(&doc, list_id, 2);
    try expectTextAt(&doc, list_id, 0, "one");
    try expectTextAt(&doc, list_id, 1, "two");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_deeply_nested" {
    var doc = try newDoc();
    defer doc.deinit();
    var l4 = MirrorMap.init(gpa, .root);
    try l4.putOwned("level4", .{ .value = .scalar(.{ .str = "deep_value" }), .conflict = false });
    var l3 = MirrorMap.init(gpa, .root);
    try putChild(&l3, "level3", .{ .object = .{ .map = l4 } });
    var l2 = MirrorMap.init(gpa, .root);
    try putChild(&l2, "level2", .{ .object = .{ .map = l3 } });
    var l1 = MirrorMap.init(gpa, .root);
    defer l1.deinit();
    try putChild(&l1, "level1", .{ .object = .{ .map = l2 } });

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "deep" }, .{ .object = .{ .map = l1 } }, false);

    // **Every level is read through its own id**, which is what makes this a
    // depth assertion and not a lookup: a batch that wrote the deepest object
    // at the wrong row would leave `l3` naming something else.
    const id1 = try objectAt(&doc, obj_id, .{ .key = "level1" });
    const id2 = try objectAt(&doc, id1, .{ .key = "level2" });
    const id3 = try objectAt(&doc, id2, .{ .key = "level3" });
    try expectStr(&doc, id3, .{ .key = "level4" }, "deep_value");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_mixed_nesting" {
    var doc = try newDoc();
    defer doc.deinit();
    const alice_scores = try listScalars(&.{ .{ .int = 10 }, .{ .int = 20 }, .{ .int = 30 } });
    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    try putChild(&alice, "scores", alice_scores);
    const bob_scores = try listScalars(&.{ .{ .int = 40 }, .{ .int = 50 } });
    var bob = MirrorMap.init(gpa, .root);
    try bob.putOwned("name", .{ .value = .scalar(.{ .str = "bob" }), .conflict = false });
    try putChild(&bob, "scores", bob_scores);
    var users = MirrorList.init(gpa, .root);
    try pushChild(&users, .{ .object = .{ .map = alice } });
    try pushChild(&users, .{ .object = .{ .map = bob } });
    var data = MirrorMap.init(gpa, .root);
    defer data.deinit();
    try data.putOwned("count", .{ .value = .scalar(.{ .int = 2 }), .conflict = false });
    try putChild(&data, "users", .{ .object = .{ .list = users } });

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = data } }, false);

    try expectInt(&doc, obj_id, .{ .key = "count" }, 2);
    try expectKeys(&doc, obj_id, &.{ "count", "users" });

    const users_id = try objectAt(&doc, obj_id, .{ .key = "users" });
    try expectLength(&doc, users_id, 2);
    const alice_id = try objectAt(&doc, users_id, .{ .index = 0 });
    try expectStr(&doc, alice_id, .{ .key = "name" }, "alice");
    const as_scores = try objectAt(&doc, alice_id, .{ .key = "scores" });
    try expectLength(&doc, as_scores, 3);
    try expectIntAt(&doc, as_scores, 0, 10);
    try expectIntAt(&doc, as_scores, 2, 30);
    const bob_id = try objectAt(&doc, users_id, .{ .index = 1 });
    try expectStr(&doc, bob_id, .{ .key = "name" }, "bob");
    const bs_scores = try objectAt(&doc, bob_id, .{ .key = "scores" });
    try expectLength(&doc, bs_scores, 2);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 14-18. a round trip, a merge, and two existing containers ───────────────

test "batch: batch_insert_survives_save_load" {
    var doc = try newDoc();
    defer doc.deinit();
    const items = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
    var nested = MirrorMap.init(gpa, .root);
    try nested.putOwned("deep", .{ .value = .scalar(.{ .bool_value = true }), .conflict = false });
    var data = MirrorMap.init(gpa, .root);
    defer data.deinit();
    try data.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try putChild(&data, "items", items);
    try putChild(&data, "nested", .{ .object = .{ .map = nested } });

    _ = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = data } }, false);

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var doc2 = try Document.load(gpa, io, saved, .unicode_code_point, .auto);
    defer doc2.deinit();

    const data_id = try objectAt(&doc2, root, .{ .key = "data" });
    try expectStr(&doc2, data_id, .{ .key = "name" }, "test");
    const items_id = try objectAt(&doc2, data_id, .{ .key = "items" });
    try expectLength(&doc2, items_id, 3);
    const nested_id = try objectAt(&doc2, data_id, .{ .key = "nested" });
    try expectBool(&doc2, nested_id, .{ .key = "deep" }, true);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_merges_correctly" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();

    var v1 = try mapScalars(&.{.{ .key = "from", .value = .{ .str = "doc1" } }});
    defer v1.deinit();
    _ = try trans.batchCreateValue(&doc1, root, .{ .key = "obj1" }, v1, false);

    var v2 = try mapScalars(&.{.{ .key = "from", .value = .{ .str = "doc2" } }});
    defer v2.deinit();
    _ = try trans.batchCreateValue(&doc2, root, .{ .key = "obj2" }, v2, false);

    const heads = try doc1.merge(gpa, &doc2);
    gpa.free(heads);

    const obj1_id = try objectAt(&doc1, root, .{ .key = "obj1" });
    try expectStr(&doc1, obj1_id, .{ .key = "from" }, "doc1");
    const obj2_id = try objectAt(&doc1, root, .{ .key = "obj2" });
    try expectStr(&doc1, obj2_id, .{ .key = "from" }, "doc2");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc1);
}

test "batch: multiple_batch_inserts" {
    var doc = try newDoc();
    defer doc.deinit();

    var v1 = try mapScalars(&.{.{ .key = "a", .value = .{ .int = 1 } }});
    defer v1.deinit();
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "first" }, v1, false);

    var v2 = try mapScalars(&.{.{ .key = "b", .value = .{ .int = 2 } }});
    defer v2.deinit();
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "second" }, v2, false);

    var v3 = try mapScalars(&.{.{ .key = "c", .value = .{ .int = 3 } }});
    defer v3.deinit();
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "third" }, v3, false);

    const first_id = try objectAt(&doc, root, .{ .key = "first" });
    try expectInt(&doc, first_id, .{ .key = "a" }, 1);
    const second_id = try objectAt(&doc, root, .{ .key = "second" });
    try expectInt(&doc, second_id, .{ .key = "b" }, 2);
    const third_id = try objectAt(&doc, root, .{ .key = "third" });
    try expectInt(&doc, third_id, .{ .key = "c" }, 3);
    // Three separate batches, three separate `localOp` roots, and **one
    // sorted run** — `first` < `second` < `third` both by the order they were
    // asked for and by sort order, so the row walk is the only thing that
    // could tell them apart.
    try expectKeys(&doc, root, &.{ "first", "second", "third" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_into_existing_map" {
    var doc = try newDoc();
    defer doc.deinit();
    const parent = try trans.putObject(&doc, root, .{ .key = "parent" }, .map);
    _ = try trans.put(&doc, parent, .{ .key = "existing" }, .{ .str = "value" });

    var value = try mapScalars(&.{
        .{ .key = "y", .value = .{ .int = 2 } },
        .{ .key = "x", .value = .{ .int = 1 } },
    });
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, parent, .{ .key = "child" }, value, false);

    try expectStr(&doc, parent, .{ .key = "existing" }, "value");
    const child_id = try objectAt(&doc, parent, .{ .key = "child" });
    try expectInt(&doc, child_id, .{ .key = "x" }, 1);
    try expectInt(&doc, child_id, .{ .key = "y" }, 2);
    try expectKeys(&doc, child_id, &.{ "x", "y" });
    // **`child` sorts before `existing`, and its row must land before the
    // `existing` row, not at the object's end.** A map reader does not sort
    // ([`map_range.zig`:1486-1490](../src/iter/map_range.zig)) — "the reader
    // does not sort, so this order is the answer order" — so a new row at the
    // object's end would make this walk answer `existing, child` and the
    // document would read back as a different map while every lookup above
    // still succeeded.
    //
    // **The position comes from the map-key query's `end_pos`, not from
    // [`mapKeyRow`](../src/transact.zig)'s walk, and that was measured rather
    // than assumed.** Instrumenting `mapKeyRow` for this shape prints
    // `key=child rows=1..2 end_pos=1`: the walk reads the one row the object
    // has, `child` does not sort above `existing`, and the function falls
    // through to `return end_pos`
    // ([`transact.zig`](../src/transact.zig):762-763) — which is row 1, in
    // front of `existing`. So this assertion pins the **result**, and the rule
    // it pins is upstream's: a map's rows ascend by key string, rule **R2**
    // ([`op.rs`:1059-1060](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
    try expectKeys(&doc, parent, &.{ "child", "existing" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_into_existing_list" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "existing" });

    var value = try mapScalars(&.{.{ .key = "appended", .value = .{ .bool_value = true } }});
    defer value.deinit();
    _ = try trans.batchCreateValue(&doc, list_id, .{ .index = 1 }, value, true);

    try expectLength(&doc, list_id, 2);
    try expectStrAt(&doc, list_id, 0, "existing");
    const appended_id = try objectAt(&doc, list_id, .{ .index = 1 });
    try expectBool(&doc, appended_id, .{ .key = "appended" }, true);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 19-24. the mirror, a transaction, a rollback, three empties ──────────────

test "batch: batch_insert_matches_hydrate_output" {
    var doc = try newDoc();
    defer doc.deinit();
    const tags = try listScalars(&.{ .{ .str = "alpha" }, .{ .str = "beta" } });
    var input = MirrorMap.init(gpa, .root);
    defer input.deinit();
    try input.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try input.putOwned("count", .{ .value = .scalar(.{ .int = 42 }), .conflict = false });
    try putChild(&input, "tags", tags);

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = input } }, false);

    var hydrated = try hydrateObj(&doc, obj_id);
    defer hydrated.deinit();
    const map = switch (hydrated) {
        .object => |o| switch (o) {
            .map => |m| m,
            else => return error.UnexpectedMirrorShape,
        },
        else => return error.UnexpectedMirrorShape,
    };
    try expectMirrorMapKeys(&map, &.{
        .{ .key = "name", .value = .{ .str = "test" } },
        .{ .key = "count", .value = .{ .int = 42 } },
    });
    const tags_value = map.get("tags") orelse return error.MirrorShapeMismatch;
    switch (tags_value.*) {
        .object => |o| switch (o) {
            .list => |l| try testing.expectEqual(@as(usize, 2), l.count()),
            else => return error.UnexpectedMirrorShape,
        },
        else => return error.UnexpectedMirrorShape,
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_with_transaction" {
    // **`Automerge::new` and `doc.transaction()`**, so a `.manual` document
    // and [`Tx.open`] — the autocommit door commits every call
    // ([`transact.zig`](../src/transact.zig):2581-2596), and upstream's second
    // half of this case is the commit.
    var doc = try newManualDoc();
    defer doc.deinit();
    var value = try mapScalars(&.{.{ .key = "key", .value = .{ .str = "from_tx" } }});
    defer value.deinit();

    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    const obj_id = try tx.batchCreateValue(root, .{ .key = "data" }, value, false);
    // **`tx.get`, not `doc.get`**: a transaction resolves its scope through
    // its own clock, and this is upstream's read *inside* the transaction.
    const in_tx = (try tx.get(obj_id, .{ .key = "key" })) orelse return error.NoSuchKey;
    try testing.expectEqualStrings("from_tx", in_tx.value.scalar.str);
    _ = try tx.commit(null, null);

    try expectObjType(&doc, root, .{ .key = "data" }, .map);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_transaction_rollback" {
    var doc = try newManualDoc();
    defer doc.deinit();
    var value = try mapScalars(&.{.{ .key = "key", .value = .{ .str = "should_be_gone" } }});
    defer value.deinit();
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.batchCreateValue(root, .{ .key = "data" }, value, false);
        _ = try tx.rollback();
    }

    try testing.expect((try am.read.get(&doc, root, .{ .key = "data" })) == null);
}

test "batch: batch_insert_empty_map" {
    var doc = try newDoc();
    defer doc.deinit();
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "empty" }, .{ .object = .{ .map = value } }, false);

    try expectObjType(&doc, root, .{ .key = "empty" }, .map);
    try expectKeys(&doc, obj_id, &.{});
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_empty_list" {
    var doc = try newDoc();
    defer doc.deinit();
    var value = MirrorList.init(gpa, .root);
    defer value.deinit();

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "empty" }, .{ .object = .{ .list = value } }, false);

    try expectObjType(&doc, root, .{ .key = "empty" }, .list);
    try expectLength(&doc, obj_id, 0);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_empty_text" {
    var doc = try newDoc();
    defer doc.deinit();
    var value = try textMirror("");
    defer value.deinit();

    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "empty" }, value, false);

    try expectObjType(&doc, root, .{ .key = "empty" }, .text);
    try expectText(&doc, obj_id, "");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 25-30. seven scalar types, equivalence, two patch streams, a matrix ──────

test "batch: batch_insert_various_scalar_types" {
    var doc = try newDoc();
    defer doc.deinit();
    var value = try mapScalars(&.{
        .{ .key = "bool_false", .value = .{ .bool_value = false } },
        .{ .key = "str_val", .value = .{ .str = "hello" } },
        .{ .key = "bool_true", .value = .{ .bool_value = true } },
        .{ .key = "null_val", .value = .null_value },
        .{ .key = "int_val", .value = .{ .int = 42 } },
        .{ .key = "uint_val", .value = .{ .uint = 100 } },
        .{ .key = "float_val", .value = .{ .float = 5.14 } },
    });
    defer value.deinit();
    const obj_id = try trans.batchCreateValue(&doc, root, .{ .key = "scalars" }, value, false);

    try expectStr(&doc, obj_id, .{ .key = "str_val" }, "hello");
    try expectInt(&doc, obj_id, .{ .key = "int_val" }, 42);
    {
        const got = try scalarAt(&doc, obj_id, .{ .key = "uint_val" });
        if (got != .uint) return error.UnexpectedScalarType;
        try testing.expectEqual(@as(u64, 100), got.uint);
    }
    {
        // **Bit-for-bit, because upstream writes `Value::f64(5.14)` against
        // the same literal** — and the mirror keeps an `f64`, not a decimal.
        const got = try scalarAt(&doc, obj_id, .{ .key = "float_val" });
        if (got != .float) return error.UnexpectedScalarType;
        try testing.expectEqual(@as(f64, 5.14), got.float);
    }
    try expectBool(&doc, obj_id, .{ .key = "bool_true" }, true);
    try expectBool(&doc, obj_id, .{ .key = "bool_false" }, false);
    {
        const got = try scalarAt(&doc, obj_id, .{ .key = "null_val" });
        try testing.expect(got == .null_value);
    }
    try expectKeys(&doc, obj_id, &.{
        "bool_false", "bool_true", "float_val", "int_val", "null_val", "str_val", "uint_val",
    });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_equivalent_to_individual_ops" {
    var doc_batch = try newDoc();
    defer doc_batch.deinit();
    const items = try listScalars(&.{ .{ .str = "a" }, .{ .str = "b" }, .{ .str = "c" } });
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();
    try value.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try value.putOwned("count", .{ .value = .scalar(.{ .int = 5 }), .conflict = false });
    try putChild(&value, "items", items);
    _ = try trans.batchCreateValue(&doc_batch, root, .{ .key = "data" }, .{ .object = .{ .map = value } }, false);

    var doc_individual = try newDoc();
    defer doc_individual.deinit();
    const data = try trans.putObject(&doc_individual, root, .{ .key = "data" }, .map);
    _ = try trans.put(&doc_individual, data, .{ .key = "name" }, .{ .str = "test" });
    _ = try trans.put(&doc_individual, data, .{ .key = "count" }, .{ .int = 5 });
    const list = try trans.putObject(&doc_individual, data, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc_individual, list, 0, .{ .str = "a" });
    _ = try trans.insert(&doc_individual, list, 1, .{ .str = "b" });
    _ = try trans.insert(&doc_individual, list, 2, .{ .str = "c" });

    var hydrated_batch = try hydrateNow(&doc_batch);
    defer hydrated_batch.deinit();
    var hydrated_individual = try hydrateNow(&doc_individual);
    defer hydrated_individual.deinit();
    // **The two documents hold the same rows in a different order** — the
    // batch writes `count, items, name` (sorted) and the individual writes put
    // `name, count` and then makes `items`, so the change graph differs and
    // only the *materialization* is equal. That is upstream's assertion
    // (`doc.hydrate(ROOT, None) == doc.hydrate(ROOT, None)`), and it is an
    // assertion about content, not about row order — which is why
    // [`expectKeys`] exists separately.
    if (!hydrated_batch.eql(&hydrated_individual)) {
        std.debug.print("batch and individual documents materialise differently\n", .{});
        return error.DocumentsDoNotMatch;
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc_batch);

    // **And the individually-built side**, which is the comparison this case is about.
    try expectSameThroughApplyChanges(&doc_individual);
}

test "batch: batch_insert_generates_patches" {
    var doc = try newDoc();
    defer doc.deinit();
    try doc.updateDiffCursor();

    const items = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 } });
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();
    try value.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try putChild(&value, "items", items);
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = value } }, false);

    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    const stream = patches.slice();
    if (stream.len == 0) {
        std.debug.print("batch insert produced no patches\n", .{});
        return error.NoPatches;
    }
    if (!hasPutMapFor(stream, "data")) {
        std.debug.print("no PutMap patch for \"data\" in {any}\n", .{stream.len});
        return error.MissingPutMapPatch;
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_text_generates_splice_patch" {
    var doc = try newDoc();
    defer doc.deinit();
    try doc.updateDiffCursor();

    const greeting = try textMirror("hi");
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();
    try putChild(&value, "greeting", greeting);
    _ = try trans.batchCreateValue(&doc, root, .{ .key = "data" }, .{ .object = .{ .map = value } }, false);

    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    const stream = patches.slice();
    if (!hasSpliceText(stream)) {
        std.debug.print("no SpliceText patch in {d} patch(es)\n", .{stream.len});
        return error.MissingSpliceTextPatch;
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_insert_list_of_lists" {
    var doc = try newDoc();
    defer doc.deinit();
    const inner0 = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 } });
    const inner1 = try listScalars(&.{ .{ .int = 3 }, .{ .int = 4 } });
    var matrix = MirrorList.init(gpa, .root);
    defer matrix.deinit();
    try pushChild(&matrix, inner0);
    try pushChild(&matrix, inner1);

    const outer = try trans.batchCreateValue(&doc, root, .{ .key = "matrix" }, .{ .object = .{ .list = matrix } }, false);

    try expectLength(&doc, outer, 2);
    const row0 = try objectAt(&doc, outer, .{ .index = 0 });
    try expectLength(&doc, row0, 2);
    try expectIntAt(&doc, row0, 0, 1);
    try expectIntAt(&doc, row0, 1, 2);
    const row1 = try objectAt(&doc, outer, .{ .index = 1 });
    try expectLength(&doc, row1, 2);
    try expectIntAt(&doc, row1, 0, 3);
    try expectIntAt(&doc, row1, 1, 4);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_put_overwrite_with_nested_structure" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "placeholder" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "keep" });

    // Overwrite index 0 with a complex nested structure
    var child0 = MirrorMap.init(gpa, .root);
    try child0.putOwned("id", .{ .value = .scalar(.{ .int = 1 }), .conflict = false });
    var child1 = MirrorMap.init(gpa, .root);
    try child1.putOwned("id", .{ .value = .scalar(.{ .int = 2 }), .conflict = false });
    var children = MirrorList.init(gpa, .root);
    try pushChild(&children, .{ .object = .{ .map = child0 } });
    try pushChild(&children, .{ .object = .{ .map = child1 } });
    var value = MirrorMap.init(gpa, .root);
    defer value.deinit();
    try value.putOwned("name", .{ .value = .scalar(.{ .str = "complex" }), .conflict = false });
    try putChild(&value, "children", .{ .object = .{ .list = children } });

    _ = try trans.batchCreateValue(&doc, list_id, .{ .index = 0 }, .{ .object = .{ .map = value } }, false);

    try expectLength(&doc, list_id, 2);
    const obj_id = try objectAt(&doc, list_id, .{ .index = 0 });
    try expectStr(&doc, obj_id, .{ .key = "name" }, "complex");
    const children_id = try objectAt(&doc, obj_id, .{ .key = "children" });
    try expectLength(&doc, children_id, 2);
    const c0 = try objectAt(&doc, children_id, .{ .index = 0 });
    try expectInt(&doc, c0, .{ .key = "id" }, 1);
    try expectStrAt(&doc, list_id, 1, "keep");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 31-36. `init_root_from_hydrate` ─────────────────────────────────────────

test "batch: batch_init_map_flat" {
    var doc = try newDoc();
    defer doc.deinit();
    // **`initRootFromHydrate` takes its `hydmod.Map` by value**
    // ([`hydrate.zig`](../src/hydrate.zig):929-932), so the call copies the
    // caller's map into the parameter and frees nothing: the caller keeps
    // ownership and must deinit its own map.
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try map.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try map.putOwned("count", .{ .value = .scalar(.{ .int = 42 }), .conflict = false });
    try trans.initRootFromHydrate(&doc, map);

    try expectStr(&doc, root, .{ .key = "name" }, "test");
    try expectInt(&doc, root, .{ .key = "count" }, 42);
    // `batch_init_root_map` sorts before it writes (`inner.rs`:1350), so the
    // root's registers are `count` then `name` whatever order they were asked
    // for in.
    try expectKeys(&doc, root, &.{ "count", "name" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_init_map_nested" {
    var doc = try newDoc();
    defer doc.deinit();
    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    var bob = MirrorMap.init(gpa, .root);
    try bob.putOwned("name", .{ .value = .scalar(.{ .str = "bob" }), .conflict = false });
    var users = MirrorList.init(gpa, .root);
    try pushChild(&users, .{ .object = .{ .map = alice } });
    try pushChild(&users, .{ .object = .{ .map = bob } });
    var meta = MirrorMap.init(gpa, .root);
    try meta.putOwned("version", .{ .value = .scalar(.{ .int = 1 }), .conflict = false });
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try putChild(&map, "meta", .{ .object = .{ .map = meta } });
    try putChild(&map, "users", .{ .object = .{ .list = users } });
    try trans.initRootFromHydrate(&doc, map);

    const users_id = try objectAt(&doc, root, .{ .key = "users" });
    try expectLength(&doc, users_id, 2);
    const alice_id = try objectAt(&doc, users_id, .{ .index = 0 });
    try expectStr(&doc, alice_id, .{ .key = "name" }, "alice");
    const meta_id = try objectAt(&doc, root, .{ .key = "meta" });
    try expectInt(&doc, meta_id, .{ .key = "version" }, 1);
    try expectKeys(&doc, root, &.{ "meta", "users" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_init_map_with_text" {
    var doc = try newDoc();
    defer doc.deinit();
    const greeting = try textMirror("hello world");
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try putChild(&map, "greeting", greeting);
    try trans.initRootFromHydrate(&doc, map);

    try expectObjType(&doc, root, .{ .key = "greeting" }, .text);
    const text_id = try objectAt(&doc, root, .{ .key = "greeting" });
    try expectText(&doc, text_id, "hello world");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_init_map_survives_save_load" {
    var doc = try newDoc();
    defer doc.deinit();
    const items = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } });
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try map.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try putChild(&map, "items", items);
    try trans.initRootFromHydrate(&doc, map);

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var doc2 = try Document.load(gpa, io, saved, .unicode_code_point, .auto);
    defer doc2.deinit();

    try expectStr(&doc2, root, .{ .key = "name" }, "test");
    const items_id = try objectAt(&doc2, root, .{ .key = "items" });
    try expectLength(&doc2, items_id, 3);
    // **The key order survives the round trip**, which is the point: a
    // reloaded document rebuilds its index from the rows, and a document whose
    // rows were out of order would come back reading in that order.
    try expectKeys(&doc2, root, &.{ "items", "name" });
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: batch_init_map_equivalent_to_individual_ops" {
    var doc_batch = try newDoc();
    defer doc_batch.deinit();
    const items = try listScalars(&.{ .{ .str = "a" }, .{ .str = "b" }, .{ .str = "c" } });
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try map.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try map.putOwned("count", .{ .value = .scalar(.{ .int = 5 }), .conflict = false });
    try putChild(&map, "items", items);
    try trans.initRootFromHydrate(&doc_batch, map);

    var doc_individual = try newDoc();
    defer doc_individual.deinit();
    _ = try trans.put(&doc_individual, root, .{ .key = "name" }, .{ .str = "test" });
    _ = try trans.put(&doc_individual, root, .{ .key = "count" }, .{ .int = 5 });
    const list = try trans.putObject(&doc_individual, root, .{ .key = "items" }, .list);
    _ = try trans.insert(&doc_individual, list, 0, .{ .str = "a" });
    _ = try trans.insert(&doc_individual, list, 1, .{ .str = "b" });
    _ = try trans.insert(&doc_individual, list, 2, .{ .str = "c" });

    var hydrated_batch = try hydrateNow(&doc_batch);
    defer hydrated_batch.deinit();
    var hydrated_individual = try hydrateNow(&doc_individual);
    defer hydrated_individual.deinit();
    if (!hydrated_batch.eql(&hydrated_individual)) {
        std.debug.print("init_root and individual documents materialise differently\n", .{});
        return error.DocumentsDoNotMatch;
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc_batch);
    // **And the individually-built side**, which is the comparison this case is about.
    try expectSameThroughApplyChanges(&doc_individual);
}

test "batch: batch_init_map_generates_patches" {
    var doc = try newDoc();
    defer doc.deinit();
    const items = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 } });
    var map = MirrorMap.init(gpa, .root);
    defer map.deinit();
    try map.putOwned("name", .{ .value = .scalar(.{ .str = "test" }), .conflict = false });
    try putChild(&map, "items", items);
    try trans.initRootFromHydrate(&doc, map);

    // **`doc.diff(&[], &heads)`, not `diff_incremental`.** Upstream's case
    // takes no cursor update at all (`batch_insert.rs`:823-824) — the whole
    // document is the delta — and the port's [`Document.diff`](../src/doc.zig)
    // is that call.
    const heads = try headsOf(&doc);
    defer gpa.free(heads);
    var patches = try doc.diff(gpa, &.{}, heads);
    defer patches.deinit();
    const stream = patches.slice();
    if (stream.len == 0) {
        std.debug.print("init_root_from_hydrate produced no patches\n", .{});
        return error.NoPatches;
    }
    if (!hasPutMapFor(stream, "name")) {
        std.debug.print("no PutMap patch for \"name\" in {d} patch(es)\n", .{stream.len});
        return error.MissingPutMapPatch;
    }
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

// ── 37-45. `Transactable::splice` ────────────────────────────────────────────

test "batch: splice_insert_scalars" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "a" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "d" });

    const values = [_]ScalarValue{ .{ .str = "b" }, .{ .str = "c" } };
    try spliceScalars(&doc, list_id, 1, 0, &values);

    try expectLength(&doc, list_id, 4);
    try expectStrAt(&doc, list_id, 0, "a");
    try expectStrAt(&doc, list_id, 1, "b");
    try expectStrAt(&doc, list_id, 2, "c");
    try expectStrAt(&doc, list_id, 3, "d");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_insert_objects" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);

    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    var bob = MirrorMap.init(gpa, .root);
    try bob.putOwned("name", .{ .value = .scalar(.{ .str = "bob" }), .conflict = false });
    var values: [2]Mirror = undefined;
    defer for (&values) |*v| v.deinit();
    values[0] = .{ .object = .{ .map = alice } };
    values[1] = .{ .object = .{ .map = bob } };

    try trans.splice(&doc, list_id, 0, 0, gpa, &values);

    try expectLength(&doc, list_id, 2);
    const alice_id = try objectAt(&doc, list_id, .{ .index = 0 });
    try expectStr(&doc, alice_id, .{ .key = "name" }, "alice");
    const bob_id = try objectAt(&doc, list_id, .{ .index = 1 });
    try expectStr(&doc, bob_id, .{ .key = "name" }, "bob");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_insert_mixed" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);

    var nested = MirrorMap.init(gpa, .root);
    try nested.putOwned("nested", .{ .value = .scalar(.{ .bool_value = true }), .conflict = false });
    // **`values` owns these three, and the array's own `defer` is their only
    // free.** The map is handed straight over at `values[1]`, and the list at
    // `values[2]`, so neither `nested` nor `inner_list` may be deinit'd here.
    var values: [3]Mirror = undefined;
    defer for (&values) |*v| v.deinit();
    values[0] = .scalar(.{ .str = "hello" });
    values[1] = .{ .object = .{ .map = nested } };
    values[2] = try listScalars(&.{ .{ .int = 1 }, .{ .int = 2 } });

    try trans.splice(&doc, list_id, 0, 0, gpa, &values);

    try expectLength(&doc, list_id, 3);
    try expectStrAt(&doc, list_id, 0, "hello");
    const map_id = try objectAt(&doc, list_id, .{ .index = 1 });
    try expectBool(&doc, map_id, .{ .key = "nested" }, true);
    const list2 = try objectAt(&doc, list_id, .{ .index = 2 });
    try expectLength(&doc, list2, 2);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_delete_and_insert" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "a" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "b" });
    _ = try trans.insert(&doc, list_id, 2, .{ .str = "c" });

    // Delete "b", insert "x" and "y" in its place
    const values = [_]ScalarValue{ .{ .str = "x" }, .{ .str = "y" } };
    try spliceScalars(&doc, list_id, 1, 1, &values);

    try expectLength(&doc, list_id, 4);
    try expectStrAt(&doc, list_id, 0, "a");
    try expectStrAt(&doc, list_id, 1, "x");
    try expectStrAt(&doc, list_id, 2, "y");
    try expectStrAt(&doc, list_id, 3, "c");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_delete_only" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&doc, list_id, 0, .{ .str = "a" });
    _ = try trans.insert(&doc, list_id, 1, .{ .str = "b" });
    _ = try trans.insert(&doc, list_id, 2, .{ .str = "c" });

    try trans.splice(&doc, list_id, 1, 1, gpa, &.{});

    try expectLength(&doc, list_id, 2);
    try expectStrAt(&doc, list_id, 0, "a");
    try expectStrAt(&doc, list_id, 1, "c");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_with_text" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);

    // **The array owns the two text mirrors** — they are moved into it and the
    // array's `defer` is the one free, so a `defer hello.deinit()` beside it
    // would be a double free. This is upstream's `vec![…]` ownership, and the
    // port has no move to express it with.
    var values: [2]Mirror = undefined;
    defer for (&values) |*v| v.deinit();
    values[0] = try textMirror("hello");
    values[1] = try textMirror("world");

    try trans.splice(&doc, list_id, 0, 0, gpa, &values);

    try expectLength(&doc, list_id, 2);
    try expectTextAt(&doc, list_id, 0, "hello");
    try expectTextAt(&doc, list_id, 1, "world");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_deeply_nested" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);

    const scores = try listScalars(&.{ .{ .int = 10 }, .{ .int = 20 } });
    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    try putChild(&alice, "scores", scores);
    var users = MirrorList.init(gpa, .root);
    try pushChild(&users, .{ .object = .{ .map = alice } });
    var top = MirrorMap.init(gpa, .root);
    try putChild(&top, "users", .{ .object = .{ .list = users } });

    var values: [1]Mirror = undefined;
    defer for (&values) |*v| v.deinit();
    values[0] = .{ .object = .{ .map = top } };

    try trans.splice(&doc, list_id, 0, 0, gpa, &values);

    const map_id = try objectAt(&doc, list_id, .{ .index = 0 });
    const users_id = try objectAt(&doc, map_id, .{ .key = "users" });
    const alice_id = try objectAt(&doc, users_id, .{ .index = 0 });
    try expectStr(&doc, alice_id, .{ .key = "name" }, "alice");
    const scores_id = try objectAt(&doc, alice_id, .{ .key = "scores" });
    try expectLength(&doc, scores_id, 2);
    try expectIntAt(&doc, scores_id, 0, 10);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_survives_save_load" {
    var doc = try newDoc();
    defer doc.deinit();
    const list_id = try trans.putObject(&doc, root, .{ .key = "list" }, .list);

    var entry = MirrorMap.init(gpa, .root);
    try entry.putOwned("key", .{ .value = .scalar(.{ .str = "val" }), .conflict = false });
    var values: [2]Mirror = undefined;
    defer for (&values) |*v| v.deinit();
    values[0] = .{ .object = .{ .map = entry } };
    values[1] = .scalar(.{ .int = 42 });

    try trans.splice(&doc, list_id, 0, 0, gpa, &values);

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var doc2 = try Document.load(gpa, io, saved, .unicode_code_point, .auto);
    defer doc2.deinit();

    const list_id2 = try objectAt(&doc2, root, .{ .key = "list" });
    try expectLength(&doc2, list_id2, 2);
    const map_id = try objectAt(&doc2, list_id2, .{ .index = 0 });
    try expectStr(&doc2, map_id, .{ .key = "key" }, "val");
    try expectIntAt(&doc2, list_id2, 1, 42);
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc);
}

test "batch: splice_merges_correctly" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    const list_id = try trans.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&doc1, list_id, 0, .{ .str = "shared" });

    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();

    var from1 = MirrorMap.init(gpa, .root);
    try from1.putOwned("from", .{ .value = .scalar(.{ .str = "doc1" }), .conflict = false });
    var v1: [1]Mirror = undefined;
    defer for (&v1) |*v| v.deinit();
    v1[0] = .{ .object = .{ .map = from1 } };
    try trans.splice(&doc1, list_id, 1, 0, gpa, &v1);

    const list_id2 = try objectAt(&doc2, root, .{ .key = "list" });
    var from2 = MirrorMap.init(gpa, .root);
    try from2.putOwned("from", .{ .value = .scalar(.{ .str = "doc2" }), .conflict = false });
    var v2: [1]Mirror = undefined;
    defer for (&v2) |*v| v.deinit();
    v2[0] = .{ .object = .{ .map = from2 } };
    try trans.splice(&doc2, list_id2, 1, 0, gpa, &v2);

    const heads = try doc1.merge(gpa, &doc2);
    gpa.free(heads);

    // **Only the length and the first element are asserted, because that is
    // all upstream asserts** (`batch_insert.rs`:1029-1035). Two concurrent
    // appends at index one is a conflict the reader resolves, and the
    // reference does not pin which of them wins; the port does not either.
    try expectLength(&doc1, list_id, 3);
    try expectStrAt(&doc1, list_id, 0, "shared");
    // **The write path against the read path** — see the helper's doc above.
    try expectSameThroughApplyChanges(&doc1);
}

// ── 46. a map key in a text object ───────────────────────────────────────────

test "batch: batch_create_object_rejects_map_key_in_text" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try trans.putObject(&doc, root, .{ .key = "k0" }, .text);

    // **`Mark::new("bold", Null, 0, 0)` with `ExpandMark::After`** — a
    // zero-width mark, which is a begin and an end at the same anchor
    // ([`marks.rs`](../src/marks.zig)). Upstream writes it in its own
    // transaction (`doc.commit()` before and after); the port's autocommit
    // door opens, writes and commits on every call
    // ([`transact.zig`](../src/transact.zig):2581-2596), so the same three
    // changes come out and the `commit()` lines have no separate spelling.
    try trans.mark(&doc, text, 0, 0, "bold", .after, null);

    var value = try mapScalars(&.{.{ .key = "m0", .value = .{ .int = -128 } }});
    defer value.deinit();
    // **This used to create a map-key operation inside a text object, leaving
    // the document op set in an invalid order that later panicked during
    // merge/sync** — upstream's own comment, and the regression it is here for.
    //
    // **The error is asserted as `error.InvalidOp` and upstream's payload is
    // not**, and the gap is the API: upstream's
    // `AutomergeError::InvalidOp(ObjType::Text)` carries the parent's type
    // (`inner.rs`:1284) and [`error.zig`](../src/error.zig) has one
    // `error.InvalidOp` with no payload, so the port can say *that* the
    // operation was refused and not *what* the parent was. The arm is the
    // same one: `(Prop::Map(_), _, ObjType::Text)` falls through to `_`
    // (`inner.rs`:1280-1285), and the port's check is
    // `.text => if (prop != .index or !as_insert) return error.InvalidOp`
    // ([`transact.zig`](../src/transact.zig):1920).
    try testing.expectError(
        error.InvalidOp,
        trans.batchCreateValue(&doc, text, .{ .key = "k0" }, value, false),
    );
}

// ── Not an upstream case: the write path against the apply path ──────────────

test "batch: a batch written locally and the same changes applied elsewhere materialise the same" {
    // **Not one of upstream's 46 cases, and it is here for one reason.**
    // A batch computes each row from the ones before it
    // ([`inner.rs`:1460-1462](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
    // and writes the whole run with **one** splice
    // ([`inner.rs`:1514-1519](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    // while [`Document.applyChanges`](../src/doc.zig) screens and applies the
    // same operations **per change**. Two different routes to the same rows;
    // a document whose batch put a row in the wrong place would still read
    // back correctly on the local route and come out different here.
    var built = try newDoc();
    defer built.deinit();
    const alice_scores = try listScalars(&.{ .{ .int = 10 }, .{ .int = 20 }, .{ .int = 30 } });
    var alice = MirrorMap.init(gpa, .root);
    try alice.putOwned("name", .{ .value = .scalar(.{ .str = "alice" }), .conflict = false });
    try putChild(&alice, "scores", alice_scores);
    var bob = MirrorMap.init(gpa, .root);
    try bob.putOwned("name", .{ .value = .scalar(.{ .str = "bob" }), .conflict = false });
    var users = MirrorList.init(gpa, .root);
    try pushChild(&users, .{ .object = .{ .map = alice } });
    try pushChild(&users, .{ .object = .{ .map = bob } });
    const hello = try textMirror("hi");
    var data = MirrorMap.init(gpa, .root);
    defer data.deinit();
    try data.putOwned("count", .{ .value = .scalar(.{ .int = 2 }), .conflict = false });
    try putChild(&data, "greeting", hello);
    try putChild(&data, "users", .{ .object = .{ .list = users } });
    _ = try trans.batchCreateValue(&built, root, .{ .key = "data" }, .{ .object = .{ .map = data } }, false);

    // **A second batch into an existing list**, so the second document's own
    // op set has a sequence splice as well as a map sort.
    const list_id = try trans.putObject(&built, root, .{ .key = "list" }, .list);
    _ = try trans.insert(&built, list_id, 0, .{ .str = "keep" });
    var tail = MirrorMap.init(gpa, .root);
    try tail.putOwned("z", .{ .value = .scalar(.{ .int = 1 }), .conflict = false });
    try tail.putOwned("a", .{ .value = .scalar(.{ .int = 2 }), .conflict = false });
    var tails: [1]Mirror = undefined;
    defer for (&tails) |*v| v.deinit();
    tails[0] = .{ .object = .{ .map = tail } };
    try trans.splice(&built, list_id, 1, 0, gpa, &tails);

    var changes = try built.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    const views = try gpa.alloc(am.change_record.Change, changes.len());
    defer gpa.free(views);
    for (0..changes.len()) |i| views[i] = changes.at(i);

    var applied = try Document.init(gpa, io, .auto);
    defer applied.deinit();
    _ = try applied.applyChanges(gpa, views);

    var from_built = try hydrateNow(&built);
    defer from_built.deinit();
    var from_applied = try hydrateNow(&applied);
    defer from_applied.deinit();
    if (!from_built.eql(&from_applied)) {
        std.debug.print("local batch and applied changes materialise differently\n", .{});
        return error.DocumentsDoNotMatch;
    }
    // **And the key order, which the content comparison above cannot see.**
    // Each document resolves its **own** object ids: an [`ExId`] read from one
    // carries an actor *index* into that document's actor table, and a reader
    // applies it to the table it belongs to
    // ([`types.zig`](../src/types.zig)).
    const data_built = try objectAt(&built, root, .{ .key = "data" });
    const data_applied = try objectAt(&applied, root, .{ .key = "data" });
    try expectKeys(&built, data_built, &.{ "count", "greeting", "users" });
    try expectKeys(&applied, data_applied, &.{ "count", "greeting", "users" });
    const list_applied = try objectAt(&applied, root, .{ .key = "list" });
    const tail_built = try objectAt(&built, list_id, .{ .index = 1 });
    const tail_applied = try objectAt(&applied, list_applied, .{ .index = 1 });
    try expectKeys(&built, tail_built, &.{ "a", "z" });
    try expectKeys(&applied, tail_applied, &.{ "a", "z" });
}

/// `doc.splice(&list, pos, del, vec![…])` over scalars, which is what eight of
/// upstream's nine `splice` cases build: a `hydrate::Value::Scalar` vector
/// rather than a nested structure. **A helper and not a repeated
/// `listScalars`** so that the *borrowing* rule stays visible: the slice
/// [`trans.splice`] takes is [`trans.splice`]'s to read only, so the
/// mirrors can be temporaries.
fn spliceScalars(
    doc: *Document,
    list: ExId,
    pos: usize,
    del: isize,
    vals: []const ScalarValue,
) !void {
    const values = try gpa.alloc(Mirror, vals.len);
    defer gpa.free(values);
    for (vals, values) |v, *slot| slot.* = .scalar(v);
    try trans.splice(doc, list, pos, del, gpa, values);
}

// ── Zig 0.16.0 / upstream / Rust / port ───────────────────────────────────────
//
// What this file changed about upstream's, and why, in one place.
//
// ## `batch_create_object` is `batchCreateValue`, and that is the port's API
//
// Upstream's [`batch_create_object`]
// ([`inner.rs`:1269-1331](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
// takes the whole `hydrate::Value` and fills it. The port's
// [`batchCreateObject`](../src/transact.zig) takes an `ObjType` and leaves the
// object empty, because `API.md` narrows it; [`batchCreateValue`](../src/transact.zig)
// is upstream's method and is documented in that file as **not in `API.md`, and
// not optional**. Every `batch_create_object(…, &value, …)` above is
// `batchCreateValue`, and `as_insert` is upstream's `insert`.
//
// ## `AutoCommit::new` is a `.auto` document, and `Automerge::new` a `.manual` one
//
// Upstream has two document types and one transaction type; the port has one
// document type with a [`Mode`](../src/doc.zig) flag, so the two flavours are a
// constructor argument. `AutoCommit::new` is [`newDoc`] and
// `Automerge::new` is [`newManualDoc`]. **Two of upstream's cases need the
// second** — `batch_insert_with_transaction` and
// `batch_insert_transaction_rollback`, which open a `Transaction` and commit
// or roll it back — and the autocommit door commits every call
// ([`transact.zig`](../src/transact.zig):2581-2596), so a rollback is only
// expressible through [`Tx.open`] on a `.manual` document.
//
// ## `hydrate_map!` and `hydrate_list!` are builders, not macros
//
// Upstream's `hydrate_map!` collects into a `HashMap`
// ([`hydrate.rs`:306-313](../github-automerge-automerge/rust/automerge/src/hydrate.rs),
// `Map(HashMap<String, MapValue>)` at [`hydrate/map.rs`:11](../github-automerge-automerge/rust/automerge/src/hydrate/map.rs))
// and `hydrate_list!` into a `Vec` ([`hydrate.rs`:316-320](../github-automerge-automerge/rust/automerge/src/hydrate.rs)).
// **The port's mirror has the same two shapes** — a hash map
// ([`hydrate.Map`](../src/hydrate.zig)) and a sequence tree — so
// [`mapScalars`] and [`listScalars`] are the same two containers filled in
// the order written, and the sort that decides the order they are *read* in is
// upstream's, in `batch_bfs`, not the container's.
//
// **Four literals above are written out of sorted order on purpose**
// (`batch_insert_flat_map` asks for `c, a, b`; `batch_insert_various_scalar_types`
// for `bool_false, str_val, bool_true, null_val, int_val, uint_val, float_val`;
// `batch_insert_into_existing_map` for `y, x`; `batch_init_map_flat` for
// `name, count`): [`batch_bfs`] sorts a map's keys before writing
// ([`inner.rs`:1546-1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
// so a literal already in sorted order would pass a document whose rows were
// in the literal's order instead. **This is also why a `HashMap` in the
// reference is not a problem for determinism there** — the sort is the only
// thing that decides the row order, and it is the same on every run.
//
// ## A mirror value is a move, and `batchCreateValue` does not take it
//
// [`MirrorMap.putOwned`] ([`hydrate.zig`](../src/hydrate.zig):965-993) and
// [`MirrorList.push`] ([`:1195-1204`](../src/hydrate.zig)) **take the value
// over**, because upstream's `entries.insert(key, value)` and `vec.push(value)`
// do. The value a **document** is handed is the other way round:
// [`batchCreateValue`](../src/transact.zig) takes its value by value and
// [`Queue.push`](../src/transact.zig) stores a `*const hydmod.Value`, so the
// batch **borrows** it and the local keeps ownership. [`putChild`] and
// [`pushChild`] exist so a nested mirror is built inside the call and is never
// named by the caller, which is what makes "taken over" and "still mine"
// distinguishable in the source.
//
// ## `init_root_from_hydrate` takes its map by value
//
// [`initRootFromHydrate`](../src/transact.zig) takes a `hydmod.Map` **by
// value** ([`hydrate.zig`](../src/hydrate.zig):929-932), so the call copies
// the caller's map into the parameter and frees nothing: the caller keeps
// ownership and must deinit its own map, and handing it a temporary would
// leak. **That is upstream's shape and not a port decision** — Rust moves,
// Zig copies.
//
// ## `Value::Object(t)` is a tag plus an object id
//
// Upstream's `doc.get(&obj, prop).unwrap().unwrap()` is a `(Value, ObjId)`
// pair and `Value::Object(ObjType::Map)` is one value carrying both facts. The
// port's [`DocItem`](../src/read.zig) splits them: `.value == .object` says
// *object* and `item.id` is the id, and the type is a second read
// ([`Document.objectType`](../src/doc.zig)). [`objectAt`] and
// [`expectObjType`] name the two reads.
//
// ## A scalar is compared by tag and by content
//
// Upstream compares `Value` values, which are enums, so `Value::str("a")` and
// `Value::int(1)` are different values by construction. A Zig `ScalarValue` is
// a union holding slices, and `std.testing.expectEqual` uses `std.meta.eql`,
// which for a slice is the **pointer** and the length — so a `str` read out of
// the document would never equal a literal. [`expectStr`], [`expectInt`],
// [`expectBool`] and their list counterparts check the tag and then the
// payload, and the float is compared bit-for-bit because upstream writes
// `Value::f64(5.14)` against the same literal.
//
// ## `doc.hydrate` is `hydrateMap` over the op set
//
// Upstream's `ReadDoc::hydrate(&self, obj, heads)` is a method; the port reaches
// the same mirror through [`hydrate.hydrateMap`](../src/hydrate.zig), which
// takes the op set and an optional clock rather than a document, so
// [`hydrateObj`] and [`hydrateNow`] name the pair once. `Document.ops` is
// public, so nothing here reaches into a private.
//
// ## `merge` returns the heads and they are freed
//
// [`Document.merge`](../src/doc.zig) returns the document's heads
// ([`automerge.rs`:1115-1131](../github-automerge-automerge/rust/automerge/src/automerge.rs));
// upstream's `AutoCommit::merge` returns them too and every test here frees
// them, because [`Document.getHeads`](../src/doc.zig) hands back a copy.
//
// ## A fork goes through `forkAt`, under a named actor
//
// Upstream's `doc.fork()` is [`Document.forkAt`](../src/doc.zig) at the
// document's own heads here, and that is determinism rather than a leak:
// [`Document.fork`](../src/doc.zig) mints its actor through the source's
// retained `io`, so the actor and every change hash below it differ on every
// run. `fork` allocates that actor from the **fork's own** arena, which
// [`Document.deinit`](../src/doc.zig) frees, so nothing is leaked either way.
//
// ## `doc.commit()` has no separate spelling
//
// Upstream's two `AutoCommit` cases here call `doc.commit()` between writes to
// bound a change. The port's autocommit door opens, writes and commits on
// every call ([`transact.zig`](../src/transact.zig):2581-2596), so the same
// three changes come out with no `commit` to call. **The change boundaries are
// the same and nothing observable in either case reads them.**
//
// ## Two gaps, both named at their place above
//
// * `batch_create_object_rejects_map_key_in_text` asserts
//   `error.InvalidOp` where upstream asserts
//   `AutomergeError::InvalidOp(ObjType::Text)`. **The gap is the error's
//   payload**: [`error.zig`](../src/error.zig) has one `error.InvalidOp` and
//   nothing raises it with an `ObjType` attached. The arm is the same one
//   (`inner.rs`:1280-1285).
// * `batch_insert_scalar_fails` asserts `error.NotAnObject` where upstream
//   writes `let Err(_) = … else { panic!(…) }`. **This is a strengthening, not
//   a gap**: `inner.rs`:1288-1293 names the arm, so the port asserts it rather
//   than a bare `Err(_)`.
//
// ## And one assertion upstream does not make
//
// [`expectKeys`] is not in any of the 46 cases. It is here because a map reader
// does not sort ([`map_range.zig`:1486-1490](../src/iter/map_range.zig)) and
// **a contents-only assertion passes on a document whose rows are in the wrong
// order** — the values read back the same and the map is a different map. It is
// called from every case above that batch-writes a map, with the key list
// upstream's own sorted-key write order implies, and the derivation is
// [`batch_bfs`]'s sort ([`inner.rs`:1546-1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
// plus upstream's rule **R2** ([`op.rs`:1059-1060](../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
// The one case that pins an **interleaved** order is
// `batch_insert_into_existing_map`, where `child` sorts before the
// `existing` register the document already held, so the batch's root row must
// land *before* it. That row's position comes from the map-key query's
// `end_pos` rather than from [`mapKeyRow`](../src/transact.zig)'s walk — the
// walk does not fire for this shape, which was **measured**, not assumed, by
// instrumenting it; the comment at that call site says so.
//
// ## It has teeth, and that was shown rather than claimed
//
// Two perturbations of [`src/transact.zig`](../src/transact.zig), each
// reverted immediately afterwards (`src/transact.zig` verified byte-identical
// by `sha256sum` against the copy taken before the first one):
//
// * **The key sort in [`Batch.bfs`] removed** — one line commented out at
//   `transact.zig`:2506, which is upstream's
//   `keys.sort_by(|(a, _), (b, _)| a.cmp(b))`
//   ([`inner.rs`:1547](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
//   **Five cases fail and every content assertion in them still passes**:
//   `batch_insert_flat_map` reports `key 0 is "b" in row order, want "a"`,
//   `batch_insert_nested_maps` `key 0 is "inner_b" …`,
//   `batch_insert_mixed_nesting` `key 0 is "users" …`,
//   `batch_insert_various_scalar_types` `key 0 is "int_val" …`, and the
//   write-path-against-apply-path case `key 0 is "users" …`. 42 pass, 5 fail.
//   **That is the whole point of [`expectKeys`]: the values read back
//   correctly and the map is a different map.**
// * **`mapKeyRow`'s comparison inverted** (`.lt` → `.gt` at
//   `transact.zig`:751). `multiple_batch_inserts` fails with `key 0 is
//   "third" in row order, want "first"`. **`batch_insert_into_existing_map`
//   does not**, and the comment at that call site says why: that shape's
//   position comes from `end_pos` and the walk never fires. Recorded here
//   because the second perturbation is the more informative of the two — it
//   is what established where that row's position actually comes from.
//
// ## The second assertion, folded in: the write path against the read path
//
// [`expectSameThroughApplyChanges`] is called from **45 sites across 43 of the
// 47 cases** — every case that writes, plus the individually-built side of both
// `*_equivalent_to_individual_ops` cases, whose whole point is the comparison.
// It is excluded from exactly four: `batch_insert_scalar_fails` and
// `batch_create_object_rejects_map_key_in_text` (both **refused**, so nothing
// was written), `batch_insert_transaction_rollback` (rolled back, so nothing
// was written), and the write-path-against-apply-path case above, which is that
// assertion already.
//
// **It is not a restatement of [`expectKeys`]**, and the two together are the
// point: `expectKeys` catches a wrong order in one document, and this catches a
// document whose **local route and applied route disagree**. The case neither
// can catch is a wrong order **both** routes agree on. The sort perturbation
// above is caught by both, for that reason.
//
// **It was falsified, not assumed, and the falsification was re-run on this
// file.** Giving the replayed document one operation the write path never made
// produced **exit 1, 0 compile errors, and 43 `...FAIL (Invariant)`** —
// `error.Invariant` being what [`Document.debugCmp`] raises, so the
// **row-order** comparison fired first. The rule that makes such a run
// trustworthy is in [`docs/plan.md` §1.1](../docs/plan.md): **an exit code says
// something went wrong, it does not say what**, so a falsification counts only
// when the exit code is non-zero **and** there are no compile errors **and** the
// count of `...FAIL` is non-zero with a diagnostic naming the fault.
//
// ## What it detects, and what it cannot, measured
//
// **Three more perturbations, each reverted and `src/` verified byte-identical
// afterwards, establish the boundary — and the boundary is the useful part.**
//
// * **A value that diverges *between* the two routes: DETECTED.** Writing a
//   different integer into the **encoded bytes** than the op set row holds
//   ([`encodeChangeOps`](../src/doc.zig):892-897) gives **exit 1, 0 compile
//   errors, 20 `FAIL (Invariant)`** with `OpSet: value_meta differs at row N`
//   naming the column and the row, plus the write-path-against-apply-path
//   case's own `DocumentsDoNotMatch`.
// * **A value that is wrong in *both* routes: NOT DETECTED.** Adding one to
//   every integer in [`changeOpOf`](../src/transact.zig):284-297 leaves the op
//   set row and the change bytes
//   **agreeing**, so the replay fires **zero** times (`Invariant` 0,
//   `materialise differently` 0) while 14 cases fail on their own content
//   assertions. **This is the class that matters most and the helper is blind to
//   it**, because it compares the two routes *to each other* and a defect both
//   routes share is invisible to a comparison between them. What catches it is
//   [`expectInt`]/[`expectStr`]/the mirror assertions, which is why every case
//   carries those too.
// * **The historical wrong-actor-index defect: caught, but not here.** Making
//   an isolated write's rows carry the base actor's index
//   ([`Transaction.nextId`](../src/transact.zig):498-503) is refused loudly by
//   [`Document.checkCoverage`](../src/doc.zig):1254 at merge time — `change seq
//   1 of actor 1 claims ops 3..4 and holds none` — **before this helper runs**, and
//   forcing the change *header* to name actor 0 is refused by
//   `addChange`'s `error.DuplicateSeqNumber`. So the worst defect this port
//   produced is caught, but by the graph's own invariants, not by the replay.
//
// **So: trust it for route disagreement — row order, row count, column
// contents, shape — and do not trust it for correctness.** A wrong value that
// reaches the op set consistently is invisible to it, and no perturbation of
// this helper will ever show otherwise.
//
// ## Running this file from a bare CLI: the `build_options` stub
//
// **`zig build test` is the command that runs this file, and it is the one
// that works.** `src/opset/op_set.zig` reads `@import("build_options")`, and
// that import is supplied by `build.zig` on the **`zautomerge` module**
// (`mod.addImport`). A bare `zig test -Mroot=test/upstream_batch_insert.zig
// -Mzautomerge=src/root.zig` therefore fails with
// `no module named 'build_options' available within module 'zautomerge'` — and
// **that failure is the harness's, not the tree's.** It is a third instance of
// the rule above: a non-zero exit that does not mean what it appears to mean.
//
// The dep has to be attached to the module that needs it, which a bare CLI can
// express only by ordering `--dep` before the `-M` it belongs to:
//
// ```text
// printf 'pub const check_slow_paths = false;\n' > $SCRATCH/bo.zig
// zig test -ODebug --dep zautomerge -Mroot=test/upstream_batch_insert.zig \
//   --dep build_options -Mzautomerge=src/root.zig \
//   --dep build_options -Mbuild_options=$SCRATCH/bo.zig
// ```
//
// **A large local volume, not a small system volume.** `/tmp` and `/var/tmp` are
// small local filesystems on these machines and are not for large data: they are
// kept bounded, so a build cache must not land on them. Put scratch on a large
// local volume of your own instead, and check what a machine actually provides
// with `df -hT`, and how much is left, before pointing a build cache at one.
//
// (Putting `--dep build_options` before `-Mroot=`, which is the obvious thing to
// write, attaches it to the **root** module instead and produces the same error,
// which is how it was first mistaken for a broken tree.)
