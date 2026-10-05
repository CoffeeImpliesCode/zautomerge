//! `rust/automerge/tests/block_tests.rs`, all nineteen cases in upstream order.
//! Each case retains its upstream line citation and complete payload assertions.
//! AutoCommit holds writes until a barrier. SpanInput borrows fresh Map payloads
//! and text/marks for the call; returned Span values own their complete payloads.
//! Replay checks compare operation rows and the materialized root independently.

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

const Document = am.autocommit.AutoCommit;
const Change = am.change_record.Change;
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const MarkSet = am.marks.MarkSet;
const ExpandMark = am.marks.ExpandMark;
const UpdateSpansConfig = am.marks.UpdateSpansConfig;
const hyd = am.hydrate;
const Mirror = hyd.Value;
const Patch = am.patches.Patch;
const Span = am.iter.spans.Span;
const SpanInput = am.iter.spans.SpanInput;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── Actors ───────────────────────────────────────────────────────────────────

/// Upstream draws an actor at random (`AutoCommit::new`,
/// [`automerge.rs`:314](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
/// This file mints them from a counter instead — distinct bytes, a stable order,
/// the same bytes on every run — for the reason
/// [`test/upstream_doc_test.zig`](upstream_doc_test.zig) gives: a failure nobody
/// can reproduce is not a finding.
///
/// The bytes start at one so that no document ever has an **empty** actor,
/// which is a different value from every other one.
var minted_actors: [512][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] hands out. The bytes live in this file's static
/// storage, which is what lets the returned [`ActorId`] be a borrow: a document
/// copies the bytes when it interns the actor.
fn mintActor() am.ActorId {
    std.debug.assert(minted_count < minted_actors.len);
    const slot = minted_count;
    minted_count += 1;
    const v: u64 = slot + 1;
    for (&minted_actors[slot], 0..) |*b, i| {
        b.* = @truncate(v >> (@as(u6, @intCast(i)) * 8));
    }
    return .{ .bytes = &minted_actors[slot] };
}

// ── Documents ────────────────────────────────────────────────────────────────

/// A document in the autocommit flavour, which is upstream's `AutoCommit`.
fn newDoc() !Document {
    var doc = try Document.init(gpa, io);
    errdefer doc.deinit();
    try doc.setActorId(mintActor());
    return doc;
}

/// Fork at the committed source heads, then assign a deterministic actor.
fn forkDoc(src: *Document) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    var out = try src.forkAt(gpa, heads);
    errdefer out.deinit();
    try out.setActorId(mintActor());
    return out;
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// [`Document.getHeads`](../src/doc.zig). **Owned**: every call in this file
/// binds it and frees it, because a leak in a test is an `ABRT` that kills the
/// binary and hides every test after it.
fn headsOf(doc: *Document) ![]am.ChangeHash {
    return doc.getHeads(gpa);
}

/// The object type at `obj.prop`, and the object itself, which is what
/// upstream's `doc.get(&block1, "type").unwrap().unwrap()` destructures into a
/// `(Value, ObjId)` pair.
fn objectAndType(doc: *Document, obj: ExId, prop: Prop) !struct { id: ExId, typ: ObjType } {
    const item = (try doc.get(obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => |t| .{ .id = item.id, .typ = t },
        .scalar => error.NotAnObject,
    };
}

/// `doc.text(&id)`. **The reader hands back a caller-owned string**
/// ([`read.rs`:181](../../github-automerge-automerge/rust/automerge/src/read.rs)),
/// which is why this frees it and why the assertion comes on the next line.
fn expectText(doc: *Document, obj: ExId, want: []const u8) !void {
    const got = try doc.text(obj, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The materialized root at the present, through
/// [`hydrate.hydrateMap`](../src/hydrate.zig).
fn hydrateNow(doc: *Document) !Mirror {
    return doc.hydrate(root, null, gpa);
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

/// **Every case below builds its document through the port's write path and this
/// replays the same operations through the read path,
/// [`Document.applyChanges`](../src/doc.zig), and requires the two documents to
/// be the same document.**
///
/// **Why this file and not another.** These cases are about **map-valued block
/// markers**, so what they write is maps of `type` / `parents` / `attrs` keys
/// into objects the text names. `TransactionInner::commit` builds each
/// operation's row from the ones before it
/// ([`inner.rs`:1460-1462](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// and `finish` is one splice of the whole batch, and a map reader does
/// **not** sort ([`iter/map_range.zig`:1486-1490](../src/iter/map_range.zig)) —
/// so rows written in the wrong order read back as a different map and a
/// contents-only assertion passes on it. [`Document.debugCmp`] is "row for row
/// and byte for byte" ([`op_set.rs`:69-71](../../github-automerge-automerge/rust/automerge/src/op_set.rs)),
/// so the row-order divergence fails there first, with a diagnostic naming the
/// fault, before the content comparison can paper over it. The mirror
/// comparison is second and is there to catch a divergence the op set does not
/// show.
///
/// [`Document.debugCmp`]: ../src/doc.zig
fn expectSameThroughApplyChanges(doc: *Document) !void {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    // A case that wrote nothing cannot carry both shapes, and `applyChanges`
    // on an empty list is a no-op that would pass for the wrong reason.
    if (all.len() == 0) return;

    const view = try changeViews(&all);
    defer gpa.free(view);

    var applied = try Document.init(gpa, io);
    defer applied.deinit();
    try applied.setActorId(mintActor());
    _ = try applied.applyChanges(gpa, view);

    // **First the rows, then the content.**
    try (try applied.document()).debugCmp(try doc.document());

    var written = try hydrateNow(doc);
    defer written.deinit();
    var replayed = try hydrateNow(&applied);
    defer replayed.deinit();
    if (!written.eql(&replayed)) {
        std.debug.print(
            "\nblock replay: the write path and applyChanges materialize differently\n",
            .{},
        );
        return error.ReplayDiffers;
    }
}

// ── Hydrate builders ─────────────────────────────────────────────────────────

/// `hydrate_map!{}` as a builder: an empty map over the root id
/// ([`hydrate::Map::new`](../src/hydrate.zig)).
fn hmap() hyd.Map {
    return hyd.Map.init(gpa, .root);
}

/// `hydrate_list![]` as a builder.
fn hlist() hyd.List {
    return hyd.List.init(gpa, .root);
}

/// `hydrate_text!{"…"}` as a builder ([`hydrate::Text::new`](../src/hydrate.zig)).
fn htext(s: []const u8) !hyd.Text {
    return hyd.Text.init(gpa, .root, .unicode_code_point, s);
}

/// `hydrate::Value::Map(m)`.
fn vmap(m: hyd.Map) Mirror {
    return .{ .object = .{ .map = m } };
}

/// `hydrate::Value::List(l)`.
fn vlist(l: hyd.List) Mirror {
    return .{ .object = .{ .list = l } };
}

/// `hydrate::Value::Text(t)`.
fn vtext(t: hyd.Text) Mirror {
    return .{ .object = .{ .text = t } };
}

/// Puts `v` at `key`. **This takes `v` over: do not `deinit` it afterwards,
/// and do not `defer` the `deinit` of a container you have already handed over.**
///
/// That is not a convention of this file, it is what the port says.
/// [`hydrate.Map.putOwned`] copies **the key and the value's bytes** and then
/// calls [`hydrate.ownValue`](../src/hydrate.zig), which begins
/// `v.toScalar() orelse return null` — so for an **object** value it returns
/// null and leaves `v` as it was, and the register holds **this very
/// container**, including its `entries` allocation. `hydrate.Map.deinit`'s own
/// doc puts the rule as "**exactly one owner may run it** … a by-value copy is a
/// move and not a share", and this helper is where the move happens.
fn mapPut(m: *hyd.Map, key: []const u8, v: Mirror) !void {
    try m.putOwned(key, hyd.MapValue.init(v, false));
}

/// Appends `v`. **Takes `v` over**, for the same reason and by the same door
/// ([`hydrate.List.push`] → [`hydrate.ownValue`]).
fn listPut(l: *hyd.List, v: Mirror) !void {
    try l.push(v, false);
}

/// A short string value.
fn vstr(s: []const u8) Mirror {
    return .{ .str = s };
}

/// A signed integer value.
fn vint(i: i64) Mirror {
    return .{ .int = i };
}

// ── Spans ────────────────────────────────────────────────────────────────────

/// What a span is expected to read as. **Either `block` is set, or `text` is**;
/// a `Want` with both unset is a text span with empty text and no marks, which
/// is a real shape and is written out rather than defaulted into.
const Want = struct {
    /// Non-null ⇒ a block marker whose map must hold exactly these contents.
    block: ?*const hyd.Map = null,
    /// The text of a text span.
    text: []const u8 = "",
    /// The marks a text span must carry, **in name order** — which is the order
    /// [`MarkSet`] keeps them in ([`marks.zig`:327-329](../src/marks.zig)), so
    /// this is a pairwise walk against a sorted list and not a set comparison
    /// against an unordered one. Upstream's is a `BTreeMap` compared by
    /// content ([`marks.rs`:106](../../github-automerge-automerge/rust/automerge/src/marks.rs)),
    /// which is the same thing.
    marks: []const MarkSet.Entry = &.{},
};

/// The one mark this file's cases name, as a name-sorted singleton.
const bold: MarkSet.Entry = .{ .name = "bold", .value = .{ .bool_value = true } };
const italic: MarkSet.Entry = .{ .name = "italic", .value = .{ .bool_value = true } };
/// `"some_expanding_mark_type"` sorts before `"some_nonexpanding_mark_type"`:
/// `e` is `0x65` and `n` is `0x6e`, and the shared prefix is
/// `"some_"` — so **name order is not upstream's declaration order**, and case
/// 19 writes its pairs in this order for that reason.
const some_expanding: MarkSet.Entry = .{
    .name = "some_expanding_mark_type",
    .value = .{ .str = "marked" },
};
const some_nonexpanding: MarkSet.Entry = .{
    .name = "some_nonexpanding_mark_type",
    .value = .{ .str = "marked" },
};

/// `hydrate_map!{}` as a constant a [`Want`] can point at, which is what
/// upstream's `Span::Block(hydrate_map! {})` is: a block with no keys.
/// **Never freed** — a zero-valued [`std.ArrayList`] owns no allocation, so a
/// `deinit` on this would be a `free` of nothing and the const cannot take one.
const empty_map: hyd.Map = .{ .gpa = gpa, .id = .root, .entries = .empty };

/// Every span of `obj`, in order, **owned by the caller** — each carries its own
/// text bytes and its own mark set
/// ([`Spans.next`](../src/iter/spans.zig) hands the span over).
fn collectSpans(doc: *Document, obj: ExId) !std.ArrayList(Span) {
    var out: std.ArrayList(Span) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(gpa);
        out.deinit(gpa);
    }
    var walk = try doc.spans(obj, gpa);
    defer walk.deinit();
    while (try walk.next()) |found| try out.append(gpa, found);
    return out;
}

/// Gives back a list from [`collectSpans`].
fn freeSpans(list: *std.ArrayList(Span)) void {
    for (list.items) |*s| s.deinit(gpa);
    list.deinit(gpa);
}

/// Lexicographic byte order, which is what "sorted" means for a map key
/// everywhere in this port ([`transact.zig`:2257-2262](../src/transact.zig)).
fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The visible keys of `obj`, **in the order the reader yields them**, against
/// `want` in the order given. The key strings are the document's and are only
/// copied so the diagnostic outlives the walk.
///
/// **This is the row-order assertion, and it is separate from the content
/// comparison on purpose.** [`hydrate.Map.eql`](../src/hydrate.zig) walks the
/// registers and looks each one up **by key**, so it cannot see the order the
/// rows are in — and [`am.read.keys`] yields them in row order because the map
/// reader does **not** sort
/// ([`iter/map_range.zig`:1486-1490](../src/iter/map_range.zig), upstream's own
/// comment: "the reader does not sort, so this order is the answer order"). A
/// document whose block wrote `type` before `parents` reads back as the same
/// map by content and as a **different map** by iteration, so a file of
/// contents-only assertions can be entirely green on a wrong row order.
///
/// This is [`test/upstream_batch_insert.zig`](upstream_batch_insert.zig)'s
/// `expectKeys`, brought over with its reasoning: commenting out the sort in
/// `Batch.bfs` gave five failures there where **every** content assertion still
/// passed.
fn expectKeys(doc: *Document, obj: ExId, want: []const []const u8) !void {
    var keys = try doc.keys(obj);
    defer keys.deinit(gpa);
    var got: std.ArrayList([]const u8) = .empty;
    defer {
        for (got.items) |k| gpa.free(k);
        got.deinit(gpa);
    }
    while (try keys.next()) |key| try got.append(gpa, try gpa.dupe(u8, key));
    if (got.items.len != want.len) {
        std.debug.print("\nobject has {d} visible key(s), want {d}:\n", .{
            got.items.len, want.len,
        });
        for (got.items) |k| std.debug.print("  got \"{s}\"\n", .{k});
        return error.KeySetMismatch;
    }
    for (got.items, want, 0..) |g, w, i| {
        if (!std.mem.eql(u8, g, w)) {
            std.debug.print(
                "\nkey {d} is \"{s}\" in row order, want \"{s}\"\n",
                .{ i, g, w },
            );
            return error.KeysOutOfRowOrder;
        }
    }
}

/// **The assertion every case in this file that reads spans makes**, and it is
/// upstream's `assert_eq!(spans, vec![…])` with the block payload resolved.
///
/// Three things it checks that a contents-only check would not:
///
/// 1. **The count, and the order.** Upstream compares two `Vec<Span>`s, so a
///    block where a text run belongs fails here. A block marker is a `make Map`
///    row at one index of the text object
///    ([`text_diff.rs`:490-500](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)),
///    so "the blocks are all there" is not the same claim as "the blocks are
///    where they were and the text runs between them are unbroken".
/// 2. **The kind of each span** — `.block` against `.text` — which is the union
///    tag upstream's `Span` carries
///    ([`spans.rs`:409-427](../../github-automerge-automerge/rust/automerge/src/iter/spans.rs)).
/// 3. **A block's contents, hydrated.** [`hydrate.Map.eql`](../src/hydrate.zig)
///    compares registers and **not** ids, which is what makes this upstream's
///    `#[derive(PartialEq)]` on `hydrate::Map`
///    ([`hydrate/map.rs`:13](../../github-automerge-automerge/rust/automerge/src/hydrate/map.rs)):
///    two blocks with the same contents are equal whatever they are called.
///
/// Returned block Maps are compared directly, without rehydrating object ids.
fn expectSpans(doc: *Document, obj: ExId, wants: []const Want) !void {
    var got = try collectSpans(doc, obj);
    defer freeSpans(&got);

    if (got.items.len != wants.len) {
        std.debug.print("\n{d} span(s), want {d}:\n", .{ got.items.len, wants.len });
        for (got.items, 0..) |s, i| std.debug.print(
            "  {d}: {s}\n",
            .{ i, switch (s) {
                .text => |t| t.text,
                .block => "<block>",
            } },
        );
        return error.SpanCountDiffers;
    }

    for (got.items, wants, 0..) |s, want, i| {
        switch (s) {
            .block => |have| {
                const expected = want.block orelse {
                    std.debug.print(
                        "\nspan {d} is a block, want text \"{s}\"\n",
                        .{ i, want.text },
                    );
                    return error.SpanKindDiffers;
                };
                if (!have.eql(expected)) {
                    std.debug.print("\nspan {d}: block contents differ\n", .{i});
                    return error.BlockContentsDiffer;
                }
                // **And the block's keys in row order**, which is the half
                // `hydrate.Map.eql` cannot see: it looks each register up by
                // key, so it is content-only. [`expectKeys`] walks
                // [`am.read.keys`] one key at a time in iteration order, and a
                // map reader does **not** sort
                // ([`iter/map_range.zig`:1486-1490](../src/iter/map_range.zig)),
                // so rows written in the wrong order read back as a different
                // map while this comparison still passes. A block with fewer
                // than two keys has no order to be wrong about.
                if (expected.entries.count() >= 2) {
                    var keys: std.ArrayList([]const u8) = .empty;
                    defer keys.deinit(gpa);
                    var wit = expected.entries.iterator();
                    while (wit.next()) |entry| try keys.append(gpa, entry.key_ptr.*);
                    // **`updateMapValue` writes additions in sorted key order**
                    // ([`transact.zig`:1721-1723](../src/transact.zig),
                    // `inner.rs:1132-1139`), so the row order the reader yields
                    // is the sorted one — which is what this expects.
                    std.mem.sort([]const u8, keys.items, {}, strLess);
                    try expectKeys(doc, have.id, keys.items);
                }
            },
            .text => |t| {
                if (want.block != null) {
                    std.debug.print("\nspan {d} is text \"{s}\", want a block\n", .{ i, t.text });
                    return error.SpanKindDiffers;
                }
                if (!std.mem.eql(u8, want.text, t.text)) {
                    std.debug.print(
                        "\nspan {d}: text \"{s}\", want \"{s}\"\n",
                        .{ i, t.text, want.text },
                    );
                    return error.SpanTextDiffers;
                }
                // **No marks is `null`, not an empty set.**
                // [`SpanState.runMarks`](../src/iter/spans.zig) returns null when
                // the fold's view is empty, and upstream's
                // `marks: Default::default()` on an `Option<Arc<MarkSet>>` is
                // `None` — so a span that came back carrying an *empty* set
                // where upstream says `None` fails here rather than passing.
                if (want.marks.len == 0) {
                    if (t.marks != null) {
                        std.debug.print(
                            "\nspan {d} \"{s}\": carries marks, want none\n",
                            .{ i, t.text },
                        );
                        return error.SpanMarksDiffer;
                    }
                } else {
                    const marks = t.marks orelse {
                        std.debug.print(
                            "\nspan {d} \"{s}\": carries no marks, want {d}\n",
                            .{ i, t.text, want.marks.len },
                        );
                        return error.SpanMarksDiffer;
                    };
                    if (marks.len() != want.marks.len) {
                        std.debug.print(
                            "\nspan {d} \"{s}\": {d} mark(s), want {d}\n",
                            .{ i, t.text, marks.len(), want.marks.len },
                        );
                        return error.SpanMarksDiffer;
                    }
                    // **The walk is `next()`, not a `for`**:
                    // [`MarkSetIter`](../src/marks.zig) wraps upstream's
                    // `Option<btree_map::Iter>` (`marks.rs`:112-134) and is a
                    // struct, not a range. Both sides are **name-sorted**, so
                    // this is a pairwise walk and not a lookup.
                    var have_it = marks.iter();
                    for (want.marks) |expected| {
                        const have = have_it.next() orelse {
                            std.debug.print(
                                "\nspan {d} \"{s}\": no mark {s}, want it\n",
                                .{ i, t.text, expected.name },
                            );
                            return error.SpanMarksDiffer;
                        };
                        if (!std.mem.eql(u8, have.name, expected.name) or
                            !have.value.eql(expected.value))
                        {
                            std.debug.print(
                                "\nspan {d} \"{s}\": mark {s}, want {s}\n",
                                .{ i, t.text, have.name, expected.name },
                            );
                            return error.SpanMarksDiffer;
                        }
                    }
                }
            },
        }
    }
}

/// Read historical spans through an isolated AutoCommit view. Integration is
/// deferred so an assertion failure cannot leave the replay in that view.
fn expectSpansAt(
    doc: *Document,
    obj: ExId,
    heads: []const am.ChangeHash,
    wants: []const Want,
) !void {
    try doc.isolate(gpa, heads);
    defer doc.integrate() catch |e| {
        std.debug.print("leaving the isolation failed: {s}\n", .{@errorName(e)});
    };
    return expectSpans(doc, obj, wants);
}

// ── Patches ──────────────────────────────────────────────────────────────────

fn propName(p: Prop) []const u8 {
    return p.asStr() orelse "<index>";
}

/// An [`ExId`] as something a diagnostic can print. **`{any}` cannot do
/// this**: [`ExId`] is a union whose `named` arm borrows the actor's bytes
/// ([`types.zig`:273-288](../src/types.zig)), and Zig refuses to format a slice
/// with no specifier. So the id is printed as `@<actor bytes>:<counter>` — which
/// is enough to tell two ids apart in a diff.
fn idName(buf: []u8, id: ExId) []const u8 {
    const op = id.opId() orelse return std.fmt.bufPrint(buf, "ROOT", .{}) catch "ROOT";
    if (id.actorBytes()) |who| {
        return std.fmt.bufPrint(buf, "@{x}:{d}", .{ who.bytes, op.counter }) catch "<id>";
    }
    return std.fmt.bufPrint(buf, "?{d}:{d}", .{ op.actor, op.counter }) catch "<id>";
}

/// A [`patches.Value`] as its kind. **Not its contents**, because the scalar arm
/// holds a `[]const u8` and the object arm is an [`ObjType`]
/// ([`patches.zig`:245-250](../src/patches.zig)) — which is the whole of what a
/// diff diagnostic needs to say.
fn valueKind(v: am.patches.Value) []const u8 {
    return switch (v) {
        .object => |o| @tagName(o),
        .scalar => |s| @tagName(s),
    };
}

/// Prints a patch stream the way upstream's `println!("{:?}", patch)` would,
/// because a diff assertion that cannot print the diff is a diff assertion
/// whose failure nobody can read.
fn showPatches(patches: []const Patch) void {
    var buf: [96]u8 = undefined;
    for (patches, 0..) |p, i| {
        std.debug.print("    patch {d}: obj={s} path={d} action={s}\n", .{
            i, idName(&buf, p.obj), p.path.len, @tagName(p.action),
        });
        for (p.path) |step| std.debug.print(
            "      path: obj={s} prop={s}\n",
            .{ idName(&buf, step.obj), propName(step.prop) },
        );
        switch (p.action) {
            .put_map => |m| std.debug.print(
                "      PutMap {{ key: \"{s}\", value: {s}, obj: {s}, conflict: {} }}\n",
                .{ m.key, valueKind(m.value), idName(&buf, m.obj), m.conflict },
            ),
            .put_seq => |s| std.debug.print(
                "      PutSeq {{ index: {d}, value: {s}, obj: {s}, conflict: {} }}\n",
                .{ s.index, valueKind(s.value), idName(&buf, s.obj), s.conflict },
            ),
            .insert => |s| {
                std.debug.print("      Insert {{ index: {d}, values: {d} }}\n", .{
                    s.index, s.values.len(),
                });
                for (0..s.values.len()) |n| {
                    const v = s.values.get(n).?;
                    std.debug.print("        [{d}] {s} obj={s} conflict={}\n", .{
                        n, valueKind(v.value), idName(&buf, v.obj), v.conflict,
                    });
                }
            },
            .splice_text => |s| {
                const rendered = s.value.makeString(gpa) catch |err| {
                    std.debug.print("      SpliceText rendering failed: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer gpa.free(rendered);
                std.debug.print(
                    "      SpliceText {{ index: {d}, value: \"{s}\", marks: {s} }}\n",
                    .{ s.index, rendered, if (s.marks == null) "none" else "some" },
                );
            },
            .increment => |s| std.debug.print(
                "      Increment {{ prop: {s}, value: {d} }}\n",
                .{ propName(s.prop), s.value },
            ),
            .conflict => |c| std.debug.print(
                "      Conflict {{ prop: {s} }}\n",
                .{propName(c.prop)},
            ),
            .delete_map => |d| std.debug.print("      DeleteMap {{ key: \"{s}\" }}\n", .{d.key}),
            .delete_seq => |d| std.debug.print(
                "      DeleteSeq {{ index: {d}, length: {d} }}\n",
                .{ d.index, d.length },
            ),
            .mark => |m| std.debug.print("      Mark {{ {d} run(s) }}\n", .{m.marks.len}),
        }
    }
}

/// Two patch streams, by content — upstream's derived `PartialEq` on `Patch`
/// ([`patch.rs`:27](../../github-automerge-automerge/rust/automerge/src/patch.rs)).
/// **`Patch` has no `eql` of its own**, so this spells the comparison out:
/// the object, the path step by step, and the action, for which
/// [`PatchAction.eql`](../src/patches.zig) does exist.
fn patchesEql(a: []const Patch, b: []const Patch) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.obj.eql(y.obj)) return false;
        if (x.path.len != y.path.len) return false;
        for (x.path, y.path) |sx, sy| {
            if (!sx.obj.eql(sy.obj)) return false;
            if (!sx.prop.eql(sy.prop)) return false;
        }
        if (!x.action.eql(y.action)) return false;
    }
    return true;
}

// ── 1. update_blocks_change_block_properties (`block_tests.rs`:22-104) ───────
test "block: update blocks changes a block's properties" {
    // `block_tests.rs:22-104`. **The case.** Two blocks, both
    // `ordered-list-item`, each holding "item N", and then an `update_spans`
    // that turns the first into a `paragraph` and the second into an
    // `unordered-list-item` **nested one level** — `parents` is a list holding
    // `"ordered-list-item"` and `attrs` is a map holding `1`.
    //
    // **The assertion is that all four of that survives the rewrite**
    // (`block_tests.rs:81-103`), including all nested containers.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    const block1 = try doc.splitBlock(text, 0);
    var one = hmap();
    defer one.deinit();
    try mapPut(&one, "parents", vlist(hlist()));
    try mapPut(&one, "type", vstr("ordered-list-item"));
    try mapPut(&one, "attrs", vmap(hmap()));
    const one_value = vmap(one);
    try doc.updateObject(block1, &one_value);
    try doc.spliceText(text, 1, 0, "item 1");

    const block2 = try doc.splitBlock(text, 7);
    var two = hmap();
    defer two.deinit();
    try mapPut(&two, "parents", vlist(hlist()));
    try mapPut(&two, "type", vstr("ordered-list-item"));
    try mapPut(&two, "attrs", vmap(hmap()));
    const two_value = vmap(two);
    try doc.updateObject(block2, &two_value);
    try doc.spliceText(text, 8, 0, "item 2");

    try doc.updateDiffCursor();

    // Fresh borrowed payloads retain the exact nested containers.
    var para = hmap();
    defer para.deinit();
    try mapPut(&para, "type", vstr("paragraph"));
    try mapPut(&para, "parents", vlist(hlist()));
    try mapPut(&para, "attrs", vmap(hmap()));

    var ul_parents = hlist();
    try listPut(&ul_parents, vstr("ordered-list-item"));
    var ul_attrs = hmap();
    try mapPut(&ul_attrs, "key", vint(1));
    var unordered = hmap();
    defer unordered.deinit();
    try mapPut(&unordered, "type", vstr("unordered-list-item"));
    try mapPut(&unordered, "parents", vlist(ul_parents));
    try mapPut(&unordered, "attrs", vmap(ul_attrs));

    const want = [_]SpanInput{
        .{ .block = &para },
        .{ .text = .{ .text = "item 1" } },
        .{ .block = &unordered },
        .{ .text = .{ .text = "item 2" } },
    };
    try doc.updateSpans(text, &want);
    try expectKeys(&doc, root, &.{"text"});

    // **Upstream's expected value, `block_tests.rs:83-102`, rebuilt.**
    var want_para = hmap();
    defer want_para.deinit();
    try mapPut(&want_para, "type", vstr("paragraph"));
    try mapPut(&want_para, "parents", vlist(hlist()));
    try mapPut(&want_para, "attrs", vmap(hmap()));

    var want_ul_parents = hlist();
    try listPut(&want_ul_parents, vstr("ordered-list-item"));
    var want_ul_attrs = hmap();
    try mapPut(&want_ul_attrs, "key", vint(1));
    var want_unordered = hmap();
    defer want_unordered.deinit();
    try mapPut(&want_unordered, "type", vstr("unordered-list-item"));
    try mapPut(&want_unordered, "parents", vlist(want_ul_parents));
    try mapPut(&want_unordered, "attrs", vmap(want_ul_attrs));

    try expectSpans(&doc, text, &.{
        .{ .block = &want_para },
        .{ .text = "item 1" },
        .{ .block = &want_unordered },
        .{ .text = "item 2" },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 2. update_blocks_updates_text (`block_tests.rs`:107-168) ─────────────────
test "block: update blocks updates the text around them" {
    // `block_tests.rs:107-168`. **The case.** Two *empty* blocks
    // (`split_block` and nothing else) holding "first thing" and "second
    // thing", and then an `update_spans` that gives each block a `type` and
    // **rewrites both runs of text at once** — "first thing" becomes "the first
    // thing" and "second thing" becomes "the things are done".
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    _ = try doc.splitBlock(text, 0);
    try doc.spliceText(text, 1, 0, "first thing");
    _ = try doc.splitBlock(text, 12);
    try doc.spliceText(text, 13, 0, "second thing");

    try doc.updateDiffCursor();

    var ordered = hmap();
    defer ordered.deinit();
    try mapPut(&ordered, "type", vstr("ordered-list-item"));
    try mapPut(&ordered, "parents", vlist(hlist()));
    try mapPut(&ordered, "attrs", vmap(hmap()));

    var para = hmap();
    defer para.deinit();
    try mapPut(&para, "type", vstr("paragraph"));
    try mapPut(&para, "parents", vlist(hlist()));
    try mapPut(&para, "attrs", vmap(hmap()));

    const want = [_]SpanInput{
        .{ .block = &ordered },
        .{ .text = .{ .text = "the first thing" } },
        .{ .block = &para },
        .{ .text = .{ .text = "the things are done" } },
    };
    try doc.updateSpans(text, &want);
    try expectKeys(&doc, root, &.{"text"});

    var want_ordered = hmap();
    defer want_ordered.deinit();
    try mapPut(&want_ordered, "type", vstr("ordered-list-item"));
    try mapPut(&want_ordered, "parents", vlist(hlist()));
    try mapPut(&want_ordered, "attrs", vmap(hmap()));

    var want_para = hmap();
    defer want_para.deinit();
    try mapPut(&want_para, "type", vstr("paragraph"));
    try mapPut(&want_para, "parents", vlist(hlist()));
    try mapPut(&want_para, "attrs", vmap(hmap()));

    // **Upstream's expected value, `block_tests.rs:147-166`.**
    try expectSpans(&doc, text, &.{
        .{ .block = &want_ordered },
        .{ .text = "the first thing" },
        .{ .block = &want_para },
        .{ .text = "the things are done" },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 3. update_blocks_updates_marks (`block_tests.rs`:171-231) ───────────────
test "block: update blocks updates the marks around them" {
    // `block_tests.rs:171-231`. **The case.** "onetwo" and "threefour" split
    // by one block marker, and an `update_spans` that breaks the first run in
    // two, **marks the second half of each run `bold`**, and appends a **second
    // empty block** at the end. So the rewrite writes text, marks and block
    // structure in one call, which is the whole point of the case.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "onetwo");
    _ = try doc.splitBlock(text, 6);
    try doc.spliceText(text, 7, 0, "threefour");

    try doc.updateDiffCursor();

    var bold_marks = try MarkSet.fromPairs(gpa, &.{bold});
    defer bold_marks.deinit();
    const want = [_]SpanInput{
        .{ .text = .{ .text = "one" } },
        .{ .text = .{ .text = "two", .marks = &bold_marks } },
        .{ .block = &empty_map },
        .{ .text = .{ .text = "three", .marks = &bold_marks } },
        .{ .text = .{ .text = "four" } },
        .{ .block = &empty_map },
    };
    try doc.updateSpans(text, &want);

    // **Upstream's expected value, `block_tests.rs:210-229`.**
    try expectSpans(&doc, text, &.{
        .{ .text = "one" },
        .{ .text = "two", .marks = &.{bold} },
        .{ .block = &empty_map },
        .{ .text = "three", .marks = &.{bold} },
        .{ .text = "four" },
        .{ .block = &empty_map },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 4. update_blocks_noop (`block_tests.rs`:234-271) ────────────────────────
test "block: update blocks with what is already there writes nothing" {
    // `block_tests.rs:234-271`. **The case.** One `ordered-list-item` block
    // holding "item 1", an `update_diff_cursor()`, and an `update_spans` whose
    // spans are **exactly what the document already reads as**. The assertion
    // is `patches.len() == 0` (`block_tests.rs:270`) — the rewrite must write
    // **no operation at all**, not merely produce the right shape afterwards.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    const block1 = try doc.splitBlock(text, 0);
    var one = hmap();
    defer one.deinit();
    try mapPut(&one, "parents", vlist(hlist()));
    try mapPut(&one, "type", vstr("ordered-list-item"));
    try mapPut(&one, "attrs", vmap(hmap()));
    const one_value = vmap(one);
    try doc.updateObject(block1, &one_value);
    try doc.spliceText(text, 1, 0, "item 1");

    try doc.updateDiffCursor();

    const want = [_]SpanInput{
        .{ .block = &one },
        .{ .text = .{ .text = "item 1" } },
    };
    try doc.updateSpans(text, &want);

    // **`diff_incremental`**, which is upstream's `diff_incremental`
    // (`autocommit.rs`:216-220): the patch stream since the cursor
    // ([`doc.zig`:5057](../src/doc.zig)).
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    if (patches.len() != 0) {
        std.debug.print("\n{} patch(es) for a no-op update_spans:\n", .{patches.len()});
        showPatches(patches.slice());
        return error.ExpectedNoPatches;
    }

    try expectSameThroughApplyChanges(&doc);
}

// ── 5. update_blocks_updates_text_and_blocks_at_once (`block_tests.rs`:274-323)
test "block: update blocks rewrites text and block type in one call" {
    // `block_tests.rs:274-323`. **The case.** One `paragraph` block holding
    // "hello world", and an `update_spans` that changes the block's `type` to
    // `unordered-list-item` **and** rewrites the text to "goodbye world" in
    // the same call. There is no `update_diff_cursor` here, which is upstream's
    // choice and is not this case's subject.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    const block1 = try doc.splitBlock(text, 0);
    var para = hmap();
    defer para.deinit();
    try mapPut(&para, "parents", vlist(hlist()));
    try mapPut(&para, "type", vstr("paragraph"));
    try mapPut(&para, "attrs", vmap(hmap()));
    const para_value = vmap(para);
    try doc.updateObject(block1, &para_value);
    try doc.spliceText(text, 1, 0, "hello world");

    var unordered = hmap();
    defer unordered.deinit();
    try mapPut(&unordered, "type", vstr("unordered-list-item"));
    try mapPut(&unordered, "parents", vlist(hlist()));
    try mapPut(&unordered, "attrs", vmap(hmap()));

    const want = [_]SpanInput{
        .{ .block = &unordered },
        .{ .text = .{ .text = "goodbye world" } },
    };
    try doc.updateSpans(text, &want);
    try expectKeys(&doc, root, &.{"text"});

    var want_unordered = hmap();
    defer want_unordered.deinit();
    try mapPut(&want_unordered, "type", vstr("unordered-list-item"));
    try mapPut(&want_unordered, "parents", vlist(hlist()));
    try mapPut(&want_unordered, "attrs", vmap(hmap()));

    // **Upstream's expected value, `block_tests.rs:311-321`.**
    try expectSpans(&doc, text, &.{
        .{ .block = &want_unordered },
        .{ .text = "goodbye world" },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 6. text_complex_block_properties (`block_tests.rs`:326-355) ─────────────
test "block: a block's type and parents can be text objects" {
    // `block_tests.rs:326-355`. **The case.** `update_object` on a block whose
    // `type` is a **text object** holding `"ordered-list-item"` and whose
    // `parents` is a **list of one text object** holding `"div"`. The
    // assertions read each level back: the value's *type* is `Object(Text)`,
    // its contents, the parent's type `Object(List)`, its length, and the
    // element's type and contents (`block_tests.rs:342-354`).
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    const block1 = try doc.splitBlock(text, 0);

    // **`update_object`'s three-way dispatch** (`inner.rs`:1213-1245) has to
    // make the nested text objects and then fill them, and a nested **text**
    // is filled by splicing the whole string in at zero rather than by a diff
    // (`transact.zig`:1849-1852), which is a different line from a nested map.
    var parents = hlist();
    try listPut(&parents, vtext(try htext("div")));
    var props = hmap();
    defer props.deinit();
    try mapPut(&props, "type", vtext(try htext("ordered-list-item")));
    try mapPut(&props, "parents", vlist(parents));
    const props_value = vmap(props);
    try doc.updateObject(block1, &props_value);

    const type_item = try objectAndType(&doc, block1, .{ .key = "type" });
    try testing.expectEqual(ObjType.text, type_item.typ);
    try expectText(&doc, type_item.id, "ordered-list-item");

    const parents_item = try objectAndType(&doc, block1, .{ .key = "parents" });
    try testing.expectEqual(ObjType.list, parents_item.typ);
    try testing.expectEqual(@as(usize, 1), try doc.length(parents_item.id));
    const elem = try objectAndType(&doc, parents_item.id, .{ .index = 0 });
    try testing.expectEqual(ObjType.text, elem.typ);
    try expectText(&doc, elem.id, "div");

    try expectSameThroughApplyChanges(&doc);
}

// ── 7. update_spans_delete_attribute (`block_tests.rs`:358-392) ─────────────
test "block: update spans deletes an attribute the new block does not name" {
    // `block_tests.rs:358-392`. **The case.** A block whose `type` is a
    // **text object** and whose `parents` is a **list of one text object**,
    // and then an `update_spans` whose single block names only `type` (as a
    // plain string) and an **empty** `parents`. The assertion is that the
    // block afterwards reads as *just those two keys* (`block_tests.rs:385-391`):
    // `parents` is gone and `type` is a **string**, not a text object any more.
    //
    // **That last half is the one that could pass for the wrong reason.** The
    // port's [`updateMapValue`](../src/transact.zig) deletes the registers the
    // new map does not name (`transact.zig`:1706-1708`, `:1725-1729`), and a
    // comparison that only counted keys would not notice a `type` that stayed
    // a text object — [`hydrate.Map.eql`](../src/hydrate.zig) compares the
    // union tag, so it does.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    const block1 = try doc.splitBlock(text, 0);
    var parents = hlist();
    try listPut(&parents, vtext(try htext("div")));
    var props = hmap();
    defer props.deinit();
    try mapPut(&props, "type", vtext(try htext("ordered-list-item")));
    try mapPut(&props, "parents", vlist(parents));
    const props_value = vmap(props);
    try doc.updateObject(block1, &props_value);

    var want_block = hmap();
    defer want_block.deinit();
    try mapPut(&want_block, "type", vstr("ordered-list-item"));
    try mapPut(&want_block, "parents", vlist(hlist()));

    const want = [_]SpanInput{.{ .block = &want_block }};
    try doc.updateSpans(text, &want);
    try expectKeys(&doc, root, &.{"text"});

    // **Upstream's expected value, `block_tests.rs:387-390`.**
    var expected = hmap();
    defer expected.deinit();
    try mapPut(&expected, "type", vstr("ordered-list-item"));
    try mapPut(&expected, "parents", vlist(hlist()));
    try expectSpans(&doc, text, &.{.{ .block = &expected }});

    try expectSameThroughApplyChanges(&doc);
}

// ── 8. marks_on_spans_respect_heads (`block_tests.rs`:395-430) ──────────────
test "block: marks on spans respect heads" {
    // `block_tests.rs:395-430`. **The case.** "hello world" with `bold` over
    // `[0, 5)`, then **`get_heads`**, then `italic` over `[5, 11)` — and the
    // assertion is read **at the earlier heads**
    // (`doc.spans_at(&text, &heads)`, `block_tests.rs:416`), where the `italic`
    // mark does not exist. So the span read is scoped by a clock and reports the
    // marks that clock has, not the ones the document holds now.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello world");
    try doc.mark(text, 0, 5, "bold", .after, .{ .bool_value = true });

    // **Owned and freed.** A leak here is an `ABRT` that kills the binary and
    // hides every test after this one.
    const heads = try headsOf(&doc);
    defer gpa.free(heads);

    try doc.mark(text, 5, 11, "italic", .after, .{ .bool_value = true });

    // **Upstream's expected value, `block_tests.rs:419-428`.**
    try expectSpansAt(&doc, text, heads, &.{
        .{ .text = "hello", .marks = &.{bold} },
        .{ .text = " world" },
    });

    try expectSameThroughApplyChanges(&doc);
}

// ── 9. marks_in_spans_cross_block_markers (`block_tests.rs`:433-461) ────────
test "block: a mark in the spans crosses a block marker" {
    // `block_tests.rs:433-461`. **The case.** "lix" with `bold` over all of it,
    // and a block marker cut at index **1** — inside the mark. The assertion is
    // that the span walk reports **three** spans, `l` bold, the block, and `ix`
    // bold (`block_tests.rs:449-459`): the mark does not stop at the marker and
    // the marker does not end the mark.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "lix");
    try doc.mark(text, 0, 3, "bold", .after, .{ .bool_value = true });
    _ = try doc.splitBlock(text, 1);

    try expectSpans(&doc, text, &.{
        .{ .text = "l", .marks = &.{bold} },
        .{ .block = &empty_map },
        .{ .text = "ix", .marks = &.{bold} },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 10. test_mark_behavior_on_delete_insert (`block_tests.rs`:464-493) ──────
test "block: a mark does not survive the deletion of the text it covered" {
    // `block_tests.rs:464-493`. **The case.** "hello" marked `bold` over all of
    // it with `ExpandMark::Both`, then the text **deleted** and "hi" spliced in
    // at the same position. The assertion is that the only span carries **no**
    // marks (`block_tests.rs:486-492`), with upstream's own comment as the
    // claim: "the bold mark should not apply to the new text".
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello");
    try doc.mark(text, 0, 5, "bold", .both, .{ .bool_value = true });
    try doc.spliceText(text, 0, 5, "");
    try doc.spliceText(text, 0, 0, "hi");

    try expectSpans(&doc, text, &.{.{ .text = "hi" }});
    try expectSameThroughApplyChanges(&doc);
}

// ── 11. spans_consolidates_marks_which_are_empty_due_to_deleted_marks
//      (`block_tests.rs`:496-552) ───────────────────────────────────────────
test "block: spans consolidate the marks a deleted mark left empty" {
    // `block_tests.rs:496-552`. **The case.** "hello middle world" with
    // `bold` over `[0, 9)` and `italic` over `[9, 18)`, both
    // `ExpandMark::None`, and then **`bold` removed over `[6, 9)` and `italic`
    // removed over `[9, 12)`** — which is exactly the middle. The assertion is
    // three spans (`block_tests.rs:537-550`): "hello " still bold, "middle"
    // with no marks at all, " world" still italic.
    //
    // **The middle is the property.** Two removed marks leave a run that
    // carries nothing, and the walk must report it as *one* span rather than
    // splitting it at each tombstone — which is what
    // [`NextText.canExtend`](../src/iter/spans.zig) compares marks *by content*
    // to get right (`spans.rs:496`, `MarkDiff::eq` at `:299-314`).
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello middle world");
    try doc.mark(text, 0, 9, "bold", .none, .{ .bool_value = true });
    try doc.mark(text, 9, 18, "italic", .none, .{ .bool_value = true });
    try doc.mark(text, 6, 9, "bold", .none, .null_value);
    try doc.mark(text, 9, 12, "italic", .none, .null_value);

    // **Upstream's expected value, `block_tests.rs:538-549`.**
    try expectSpans(&doc, text, &.{
        .{ .text = "hello ", .marks = &.{bold} },
        .{ .text = "middle" },
        .{ .text = " world", .marks = &.{italic} },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 12. spans_consolidates_marks_with_deleted_marks_followed_by_empty_marks
//      (`block_tests.rs`:555-585) ───────────────────────────────────────────
test "block: spans consolidate a mark removed over the text it covered" {
    // `block_tests.rs:555-585`. **The case.** "hello world" with `bold` over
    // `[0, 6)`, then `bold` **removed over the same range**, and the assertion
    // is **one** span with no marks (`block_tests.rs:579-583`). A mark that
    // opens and closes over the same text leaves the text unmarked, and the walk
    // must coalesce it rather than report a boundary.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello world");
    try doc.mark(text, 0, 6, "bold", .none, .{ .bool_value = true });
    try doc.mark(text, 0, 6, "bold", .none, .null_value);

    try expectSpans(&doc, text, &.{.{ .text = "hello world" }});
    try expectSameThroughApplyChanges(&doc);
}

// ── 13. spans_consolidates_marks_with_empty_marks_followed_by_deleted_marks
//      (`block_tests.rs`:588-618) ───────────────────────────────────────────
test "block: spans consolidate a mark removed over the tail it covered" {
    // `block_tests.rs:588-618`. **The case.** The same as case 12 with the mark
    // over `[6, 11)` instead of `[0, 6)` (`block_tests.rs:597`), so the run that
    // carries nothing is the **tail** and the run that is untouched is the
    // front. Same expected value: one span, no marks
    // (`block_tests.rs:612-616`). It is a separate upstream case and it is here
    // separately because "the marked run was first" and "the marked run was
    // last" are different folds.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello world");
    try doc.mark(text, 6, 11, "bold", .none, .{ .bool_value = true });
    try doc.mark(text, 6, 11, "bold", .none, .null_value);

    try expectSpans(&doc, text, &.{.{ .text = "hello world" }});
    try expectSameThroughApplyChanges(&doc);
}

// ── 14. update_spans_diffs_marks (`block_tests.rs`:621-673) ─────────────────
test "block: update spans diffs the marks as well as the text" {
    // `block_tests.rs:621-673`. **The case.** "hello world" with `bold` over
    // `[0, 5)` written with `ExpandMark::Both`, and an `update_spans` that
    // splits the text into three runs carrying **`italic`**, nothing, and
    // **`bold` and `italic` together** (`block_tests.rs:639-651`). The assertion
    // is those three spans back (`block_tests.rs:658-671`).
    //
    // **The two-mark span is the part that could pass for the wrong reason.**
    // [`MarkSet.eql`](../src/marks.zig) is a pairwise walk over two
    // **name-sorted** lists (`marks.rs:106` is a `BTreeMap`), and this file
    // compares positionally against name-sorted expectations — so a set holding
    // `italic` alone fails here, and one holding `bold, italic` in the wrong
    // order cannot be written by mistake.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.spliceText(text, 0, 0, "hello world");
    try doc.mark(text, 0, 5, "bold", .both, .{ .bool_value = true });

    var italic_marks = try MarkSet.fromPairs(gpa, &.{italic});
    defer italic_marks.deinit();
    var both_marks = try MarkSet.fromPairs(gpa, &.{ bold, italic });
    defer both_marks.deinit();
    const want = [_]SpanInput{
        .{ .text = .{ .text = "hello", .marks = &italic_marks } },
        .{ .text = .{ .text = " " } },
        .{ .text = .{ .text = "world", .marks = &both_marks } },
    };
    try doc.updateSpans(text, &want);

    try expectSpans(&doc, text, &.{
        .{ .text = "hello", .marks = &.{italic} },
        .{ .text = " " },
        .{ .text = "world", .marks = &.{ bold, italic } },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 15. update_spans_uses_expand_config (`block_tests.rs`:676-726) ───────────
test "block: update spans takes the expand flags from its config" {
    // `block_tests.rs:676-726`. **The case.** An empty text object, an
    // `update_spans` over `["hello" (bold), " world"]` written with
    // `UpdateSpansConfig::default().with_default_expand(ExpandMark::None)
    // .with_mark_expand("bold", ExpandMark::After)`
    // (`block_tests.rs`:681-683`), and then two inserts on either side of the
    // mark: `"!"` at 5 and `"Oh "` at 0.
    //
    // **The assertion is that only the first of them is marked**
    // (`block_tests.rs:711-724`): `"Oh "` unmarked, `"hello!"` bold, `" world"`
    // unmarked. `After` grows the mark forwards and not backwards, so the
    // second insert lands outside it — and **the default is `None`, so nothing
    // else in the document grows at all.** Calling `mark` with `.after` would
    // test a different method, so this case uses AutoCommit.updateSpansWithConfig.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);

    // **The config, built the way upstream builds it.** [`init`] is upstream's
    // `UpdateSpansConfig::default()` (`marks.rs`:467-473) and
    // [`withDefaultExpand`] is its `with_default_expand`
    // (`marks.rs`:476-479); [`setMarkExpand`] is the port's statement form of
    // `with_mark_expand` (`marks.rs`:481-485`) and **copies the name**, so the
    // literal below is fine and `deinit` frees the copy.
    var config = UpdateSpansConfig.init(gpa);
    defer config.deinit();
    _ = config.withDefaultExpand(.none);
    try config.setMarkExpand("bold", .after);

    var bold_marks = try MarkSet.fromPairs(gpa, &.{bold});
    defer bold_marks.deinit();
    const want = [_]SpanInput{
        .{ .text = .{ .text = "hello", .marks = &bold_marks } },
        .{ .text = .{ .text = " world" } },
    };
    try doc.updateSpansWithConfig(text, &config, &want);

    // **Insert after the mark — should be marked, `block_tests.rs:702`.**
    try doc.spliceText(text, 5, 0, "!");
    // **Insert before the mark — should NOT be marked, `block_tests.rs:705`.**
    try doc.spliceText(text, 0, 0, "Oh ");

    // **Upstream's expected value, `block_tests.rs:711-724`.**
    try expectSpans(&doc, text, &.{
        .{ .text = "Oh " },
        .{ .text = "hello!", .marks = &.{bold} },
        .{ .text = " world" },
    });
    try expectSameThroughApplyChanges(&doc);
}

// ── 16. diff_emits_block_updates (`block_tests.rs`:729-782) ─────────────────
test "block: diff emits the block update and the block's own contents" {
    // `block_tests.rs:729-782`. **The case.** `reset_diff_cursor()` so the
    // answer comes from `diff` and not from the patch log, a block cut at zero,
    // a `parents` list put on the block, and `diff(&[], &heads)`. The expected
    // stream is **three** patches (`block_tests.rs:740-772`):
    //
    //   0. `PutMap { key: "text", (Text, text) }`, `path: []`, `obj: ROOT`
    //   1. `Insert { index: 0, [(Map, block, false)] }`,
    //      `path: [(ROOT, Map("text"))]`, `obj: text`
    //   2. `PutMap { key: "parents", (List, parents) }`,
    //      `path: [(ROOT, Map("text")), (text, Seq(0))]`, `obj: block`
    //
    // **and then the same three again** after a further `splice_text`
    // (`block_tests.rs:776-781`), "which exercises a different code path" —
    // that is a second `diff` over the same heads with a document that has moved
    // on, and a contents-only check would not tell the two runs apart.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    try doc.resetDiffCursor();
    const block = try doc.splitBlock(text, 0);
    const parents = try doc.putObject(block, .{ .key = "parents" }, .list);

    const heads = try headsOf(&doc);
    defer gpa.free(heads);

    var first = try doc.diff(gpa, &.{}, heads);
    defer first.deinit();
    try expectBlockUpdatePatches(first.slice(), text, block, parents);

    try doc.spliceText(text, 0, 0, "hello world");
    var second = try doc.diff(gpa, &.{}, heads);
    defer second.deinit();
    try expectBlockUpdatePatches(second.slice(), text, block, parents);
    try testing.expect(patchesEql(first.slice(), second.slice()));

    try expectSameThroughApplyChanges(&doc);
}

/// The three patches of case 16, read one field at a time, which is what
/// upstream's `assert_eq!(patches, expected_patches)` does over a derived
/// `PartialEq` ([`patch.rs`:27](../../github-automerge-automerge/rust/automerge/src/patch.rs)).
/// **Every field is compared, including `obj` and the whole `path`** — a patch
/// stream with the right actions and the wrong objects is a different stream,
/// and `PatchAction.eql` alone would not see it.
fn expectBlockUpdatePatches(
    got: []const Patch,
    text: ExId,
    block: ExId,
    parents: ExId,
) !void {
    if (got.len != 3) {
        std.debug.print("\n{d} patch(es), want exactly 3:\n", .{got.len});
        showPatches(got);
        return error.PatchCountDiffers;
    }

    // 0: PutMap "text" on the root.
    try testing.expect(got[0].obj.eql(root));
    try testing.expectEqual(@as(usize, 0), got[0].path.len);
    try testing.expect(got[0].action == .put_map);
    try testing.expectEqualStrings("text", got[0].action.put_map.key);
    try testing.expectEqual(ObjType.text, got[0].action.put_map.value.object);
    try testing.expect(got[0].action.put_map.obj.eql(text));
    try testing.expect(!got[0].action.put_map.conflict);

    // 1: the block marker itself, as an Insert at index 0.
    try testing.expect(got[1].obj.eql(text));
    try testing.expectEqual(@as(usize, 1), got[1].path.len);
    try testing.expect(got[1].path[0].obj.eql(root));
    try testing.expect(got[1].path[0].prop.eql(.{ .key = "text" }));
    try testing.expect(got[1].action == .insert);
    try testing.expectEqual(@as(usize, 0), got[1].action.insert.index);
    try testing.expectEqual(@as(usize, 1), got[1].action.insert.values.len());
    const inserted = got[1].action.insert.values.get(0).?;
    try testing.expectEqual(ObjType.map, inserted.value.object);
    try testing.expect(inserted.obj.eql(block));
    try testing.expect(!inserted.conflict);

    // 2: the `parents` list on the block, whose path steps *through* the
    //    block's index in the text — `Seq(0)`, not `Map("…")`.
    try testing.expect(got[2].obj.eql(block));
    try testing.expectEqual(@as(usize, 2), got[2].path.len);
    try testing.expect(got[2].path[0].obj.eql(root));
    try testing.expect(got[2].path[0].prop.eql(.{ .key = "text" }));
    try testing.expect(got[2].path[1].obj.eql(text));
    try testing.expect(got[2].path[1].prop.eql(.{ .index = 0 }));
    try testing.expect(got[2].action == .put_map);
    try testing.expectEqualStrings("parents", got[2].action.put_map.key);
    try testing.expectEqual(ObjType.list, got[2].action.put_map.value.object);
    try testing.expect(got[2].action.put_map.obj.eql(parents));
    try testing.expect(!got[2].action.put_map.conflict);
}

// ── 17. diff_exposes_rich_text_when_reversing_deletion (`block_tests.rs`:823-841)
test "block: diff exposes rich text when a deletion is reversed" {
    // `block_tests.rs:823-841`, with `rich_text_with_two_blocks`
    // (`block_tests.rs`:784-820`) as its document. **The case.** A
    // `paragraph` block holding "Hello" and a `heading` block holding "World",
    // a `bold` mark over `[1, 6)`, the patch stream for the whole document at
    // those heads — and then the text object **deleted** from the root, and the
    // diff from the heads after the deletion back to the heads before it.
    //
    // **The assertion is that the two streams are the same**
    // (`block_tests.rs:840`), and upstream says why at `:837-838`: "the text's
    // contents exist at both heads, only its visibility changes, so the expose
    // queue must emit its blocks, their contents, and marks". A contents check
    // on the text object would pass for a stream that emitted nothing, which is
    // why the size of `expected` is checked too.
    var doc = try newDoc();
    defer doc.deinit();

    const text = try richTextWithTwoBlocks(&doc);
    try doc.mark(text, 1, 6, "bold", .none, .{ .bool_value = true });

    const visible = try headsOf(&doc);
    defer gpa.free(visible);
    var expected = try doc.diff(gpa, &.{}, visible);
    defer expected.deinit();
    if (expected.len() == 0) {
        std.debug.print(
            "\nthe diff from the empty state to {d} head(s) is empty\n",
            .{visible.len},
        );
        return error.DiffIsEmpty;
    }

    _ = try doc.delete(root, .{ .key = "text" });
    const hidden = try headsOf(&doc);
    defer gpa.free(hidden);

    var patches = try doc.diff(gpa, hidden, visible);
    defer patches.deinit();
    if (!patchesEql(patches.slice(), expected.slice())) {
        std.debug.print("\nthe reverse-deletion diff differs from the whole-document diff\n", .{});
        std.debug.print("expected ({d} patch(es)):\n", .{expected.len()});
        showPatches(expected.slice());
        std.debug.print("got ({d} patch(es)):\n", .{patches.len()});
        showPatches(patches.slice());
        return error.DiffDiffers;
    }

    try expectSameThroughApplyChanges(&doc);
}

/// Upstream's `rich_text_with_two_blocks` (`block_tests.rs`:784-820), which
/// returns the document, the text object and `second_index`. **This port's
/// caller owns the document**, so only the text object comes back; `second_index`
/// is not used by the one case that calls this (`block_tests.rs:824` binds it to
/// `_`).
fn richTextWithTwoBlocks(doc: *Document) !ExId {
    const text = try doc.putObject(root, .{ .key = "text" }, .text);

    // **Every index below is `doc.length(&text)` read at that moment**, which is
    // upstream's line (`block_tests.rs`:799`, `:803`, `:815`) and is what makes
    // the second block land *after* "Hello" rather than at a hard-coded 5.
    const first = try doc.splitBlock(text, try doc.length(text));
    var first_props = hmap();
    defer first_props.deinit();
    try mapPut(&first_props, "type", vstr("paragraph"));
    try mapPut(&first_props, "parents", vlist(hlist()));
    try mapPut(&first_props, "attrs", vmap(hmap()));
    const first_props_value = vmap(first_props);
    try doc.updateObject(first, &first_props_value);

    const first_text_index = try doc.length(text);
    try doc.spliceText(text, first_text_index, 0, "Hello");

    const second_index = try doc.length(text);
    const second = try doc.splitBlock(text, second_index);
    var second_parents = hlist();
    try listPut(&second_parents, vstr("blockquote"));
    var second_attrs = hmap();
    try mapPut(&second_attrs, "level", vint(2));
    var second_props = hmap();
    defer second_props.deinit();
    try mapPut(&second_props, "type", vstr("heading"));
    try mapPut(&second_props, "parents", vlist(second_parents));
    try mapPut(&second_props, "attrs", vmap(second_attrs));
    const second_props_value = vmap(second_props);
    try doc.updateObject(second, &second_props_value);

    const second_text_index = try doc.length(text);
    try doc.spliceText(text, second_text_index, 0, "World");
    return text;
}

// ── 18. merge_produces_block_insertion_diffs (`block_tests.rs`:844-872) ─────
test "block: a merge produces an insertion diff for the block" {
    // `block_tests.rs:844-872`. **The case.** A text object, a **fork** taken
    // before anything else happens, a block cut on the original afterwards, and
    // then the original merged into the fork. The assertion is that the **first**
    // patch of `diff(heads_before, heads_after)` on the fork is about the text
    // object and is an `Insert { index: 0, [(Map, block, false)] }`
    // (`block_tests.rs:861-871`).
    var doc = try newDoc();
    defer doc.deinit();

    const text = try doc.putObject(root, .{ .key = "text" }, .text);
    var fork = try forkDoc(&doc);
    defer fork.deinit();

    const block1 = try doc.splitBlock(text, 0);

    try fork.updateDiffCursor();
    const heads_before = try headsOf(&fork);
    defer gpa.free(heads_before);
    const merged = try fork.merge(gpa, &doc);
    gpa.free(merged);
    const heads_after = try headsOf(&fork);
    defer gpa.free(heads_after);

    var patches = try fork.diff(gpa, heads_before, heads_after);
    defer patches.deinit();
    if (patches.len() == 0) {
        std.debug.print("\nthe merge diff is empty\n", .{});
        return error.DiffIsEmpty;
    }
    // **Only patch 0 is upstream's subject**, and this asserts it is about
    // `text` and not about the root — upstream's `assert_eq!(patch.obj, text)`
    // at `block_tests.rs:862` is a separate claim from the action's.
    const patch = patches.slice()[0];
    try testing.expect(patch.obj.eql(text));
    try testing.expect(patch.action == .insert);
    try testing.expectEqual(@as(usize, 0), patch.action.insert.index);
    try testing.expectEqual(@as(usize, 1), patch.action.insert.values.len());
    const inserted = patch.action.insert.values.get(0).?;
    try testing.expectEqual(ObjType.map, inserted.value.object);
    try testing.expect(inserted.obj.eql(block1));
    try testing.expect(!inserted.conflict);

    try expectSameThroughApplyChanges(&fork);
}

// ── 19. test_splice_with_mark (`block_tests.rs`:875-946) ────────────────────
test "block: a splice preserves the marks around what it replaced" {
    // `block_tests.rs:875-946`, upstream's regression for
    // <https://github.com/automerge/automerge/issues/935>. **The case.** "abc"
    // with a **non-expanding** mark over `[1, 2)` and an **expanding** mark over
    // the same range, then `splice_text(1, 1, "d")` — replacing the one
    // character both marks cover.
    //
    // **The two `spans_before` / `spans_after` reads are the whole case**
    // (`block_tests.rs:904-945`). Before: `a` unmarked, `b` carrying **both**
    // marks, `c` unmarked. After: `a` unmarked, `d` carrying **only the
    // expanding mark**, `c` unmarked. The non-expanding mark is *supposed* to
    // vanish with the text it covered, and the expanding one is *supposed* to
    // have grown over `d`.
    //
    // **The expected pairs are name-sorted, and that is a transcription rule
    // here**: upstream writes `("some_nonexpanding_mark_type", …)` before
    // `("some_expanding_mark_type", …)` (`block_tests.rs:915-916`) because
    // `HashSet` does not care, while [`MarkSet`] here is a `BTreeMap`
    // (`marks.rs:105-108`) that keeps names in order — and
    // `"some_expanding_mark_type"` sorts **first**, `e` being `0x65` against
    // `n`'s `0x6e` over the shared `"some_"` prefix.
    var doc = try newDoc();
    defer doc.deinit();

    const txt = try doc.putObject(root, .{ .key = "txt" }, .text);
    try doc.spliceText(txt, 0, 0, "abc");
    try doc.mark(
        txt,
        1,
        2,
        "some_nonexpanding_mark_type",
        .none,
        .{ .str = "marked" },
    );
    try doc.mark(
        txt,
        1,
        2,
        "some_expanding_mark_type",
        .both,
        .{ .str = "marked" },
    );

    // **Upstream's expected value, `block_tests.rs:907-923`.**
    try expectSpans(&doc, txt, &.{
        .{ .text = "a" },
        .{ .text = "b", .marks = &.{ some_expanding, some_nonexpanding } },
        .{ .text = "c" },
    });

    try doc.spliceText(txt, 1, 1, "d");

    // **Upstream's expected value, `block_tests.rs:929-944`.**
    try expectSpans(&doc, txt, &.{
        .{ .text = "a" },
        .{ .text = "d", .marks = &.{some_expanding} },
        .{ .text = "c" },
    });
    try expectSameThroughApplyChanges(&doc);
}

test "parity rich fresh nested blocks own output after document teardown" {
    // Source inputs and the document can die before the owning output is inspected.
    var expected = hmap();
    defer expected.deinit();
    var expected_parents = hlist();
    try listPut(&expected_parents, vtext(try htext("div")));
    try mapPut(&expected, "type", vtext(try htext("paragraph")));
    try mapPut(&expected, "parents", vlist(expected_parents));
    var output: std.ArrayList(Span) = .empty;
    defer freeSpans(&output);
    {
        var doc = try newDoc();
        defer doc.deinit();
        const text = try doc.putObject(root, .{ .key = "text" }, .text);
        {
            var block = hmap();
            defer block.deinit();
            var parents = hlist();
            try listPut(&parents, vtext(try htext("div")));
            try mapPut(&block, "type", vtext(try htext("paragraph")));
            try mapPut(&block, "parents", vlist(parents));
            const input = [_]SpanInput{
                .{ .block = &block },
                .{ .text = .{ .text = "body" } },
            };
            try doc.updateSpans(text, &input);
        }
        try expectKeys(&doc, root, &.{"text"});
        output = try collectSpans(&doc, text);
    }
    try testing.expectEqual(@as(usize, 2), output.items.len);
    try testing.expect(output.items[0] == .block);
    try testing.expect(output.items[1] == .text);
    const got = &output.items[0].block;
    try testing.expect(got.eql(&expected));
    const got_type = got.get("type").?;
    const rendered = try got_type.object.text.makeString(gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("paragraph", rendered);
    const got_parent = got.get("parents").?.object.list.get(0).?;
    const parent_string = try got_parent.object.text.makeString(gpa);
    defer gpa.free(parent_string);
    try testing.expectEqualStrings("div", parent_string);
    try testing.expectEqualStrings("body", output.items[1].text.text);
}
