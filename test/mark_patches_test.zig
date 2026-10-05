//! `rust/automerge/tests/test_mark_patches.rs` — the whole file, which holds
//! **exactly one** `#[test]` — ported case for case, and in upstream's order.
//!
//! The upstream case is [`mark_patches_at_end_of_text`], and the phase gate it
//! belongs to counts **one** ported case, so what follows is that case and one
//! hydrate clause on top of it.
//!
//! ## What the upstream case asserts, and what it does not
//!
//! Upstream builds one text object, marks its last character, loads the second
//! document from a save, feeds it the mark change, and asserts that the
//! resulting patch stream is **one patch**, that it is on the text object, that
//! its path is `[(ROOT, "text")]`, and that its action is a `PatchAction::Mark`
//! carrying **one** mark named `"bold"`
//! ([`test_mark_patches.rs`:29-40](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)).
//! That is what the first test below asserts, and the mark's `start` and `end`
//! are pinned as well, because upstream's `Mark::new("bold", true, 5, 6)` names
//! the run and a mark patch naming the right mark over the wrong run would pass
//! every assertion upstream makes.
//!
//! ## The hydrate clause, and why it is here
//!
//! Upstream's case never builds a mirror, so this file adds one. **A patch
//! stream nobody replays is a patch stream whose payload is untested**, and the
//! payload of a mark patch is exactly what a splice patch does not carry: the
//! mark's **name** and **value**, over a **run**. The second test materialises
//! the second document, applies the patch stream to that mirror, and requires
//! the result to equal a **fresh** materialisation of the same document — the
//! shape thirty-odd tests in
//! [`test/upstream_doc_test.zig`](upstream_doc_test.zig) use.
//!
//! **The marks are compared by hand and not through `Mirror.eql`.** Upstream's
//! `hydrate::Text` derives `PartialEq`
//! ([`hydrate/text.rs`:7](../github-automerge-automerge/rust/automerge/src/hydrate/text.rs)), so its two
//! halves are `value` and `marks` — but a name-to-value mark set says what each
//! name last held and nothing about *where*, so the port's
//! `hydrate.Text.eql` ([`src/hydrate.zig`](../src/hydrate.zig)) compares the
//! text and not the marks, with that reasoning written down at the function.
//! Comparing two mirrors through it here would be a test that passes when the
//! mark is never applied at all, which is the failure this clause exists to
//! catch.
//!
//! ## The ownership clause, and why it is the same test
//!
//! [`src/hydrate.zig`](../src/hydrate.zig) says a mirror **owns everything**:
//! its map keys, its text buffers, its actor ids, its mark names and its mark
//! payloads. Upstream cannot express that distinction because
//! `hydrate::Value` carries **no lifetime parameter**
//! ([`hydrate.rs`:22-27](../github-automerge-automerge/rust/automerge/src/hydrate.rs)) and its byte cases are
//! `Bytes(Vec<u8>)` and `Str(SmolStr)`
//! ([`value.rs`:519-522](../github-automerge-automerge/rust/automerge/src/value.rs)) — **owned** — so upstream
//! copies once, at the boundary, and a mirror there cannot be read across a
//! mutation of the op set because there is nothing in it the op set owns.
//!
//! **The port's old rule was the opposite and was a port-only invention**: a
//! mirror borrowed, and every caller had to finish with it before the next
//! write ([AGENTS.md](../AGENTS.md)). So "a mirror outlives the document it was
//! read from" is a **property with a consumer-visible consequence**, and the
//! second test states it rather than leaving it in a module doc: the mirror is
//! read **after** the document has been mutated again, and must still say what
//! it said. A mirror that borrowed its scalars from the op set reads storage
//! that has been freed and reused, which is what the concrete assertions after
//! the mutation are for.
//!
//! ## What is **not** claimed here
//!
//! **No byte comparison.** `Document.save` output is not byte-identical to the
//! reference — DEFLATE is not reproducible across implementations
//! ([AGENTS.md](../AGENTS.md)) — and nothing in this file compares a save to
//! anything. The round trip asserted here is the one the port promises: **the
//! same document, materialised**.
//!
//! **No claim on the size or the count of the first `diff_incremental`.**
//! Upstream writes `doc2.diff_incremental();` and discards it
//! ([`test_mark_patches.rs`:24](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)), and so does
//! this port: the read is what moves the cursor, and the cursor's starting
//! point is a property of `Document.load`, not of this gate.

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

const Document = am.AutoCommit;
const ExId = am.ExId;
const ScalarValue = am.ScalarValue;
const Mirror = am.hydrate.Value;
const MarkSet = am.marks.MarkSet;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

/// The actor every document below is written by.
///
/// **`AutoCommit::new` draws its actor at random**
/// ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs)) and that is
/// right for the reference and wrong for a failure nobody can reproduce, so it
/// is written down here. The **same** bytes on both documents, because the case
/// is about what the second document learns, and an actor difference would put
/// a second change in the stream.
const actor: am.ActorId = .{ .bytes = "markpatches00" };

// ── 1. mark_patches_at_end_of_text ────────────────────────────────────────────
//    [`test_mark_patches.rs`:8-41](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)

test "mark_patches_at_end_of_text" {
    var doc1 = try Document.init(gpa, io);
    defer doc1.deinit();
    try doc1.setActorId(actor);

    const text = try doc1.putObject(root, .{ .key = "text" }, .text);
    try doc1.spliceText(text, 0, 0, "sample");
    const heads_before_mark = try doc1.getHeads(gpa);
    defer gpa.free(heads_before_mark);

    const saved = try doc1.save(gpa);
    defer gpa.free(saved);
    var doc2 = try Document.load(gpa, io, saved, doc1.textEncoding());
    defer doc2.deinit();

    // `Mark::new("bold".to_string(), true, 5, 6)` with `ExpandMark::After`
    // ([`test_mark_patches.rs`:16-21](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)): the run is the
    // **last** character, `"e"`, and `After` is upstream's
    // `Default for ExpandMark` ([`marks.rs`:379-383](../github-automerge-automerge/rust/automerge/src/marks.rs)).
    try doc1.mark(text, 5, 6, "bold", .after, .{ .bool_value = true });

    // "Pop the patches" upstream
    // ([`test_mark_patches.rs`:24](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)). **The first
    // read is what moves the cursor**, so it is not a no-op; nothing is
    // asserted about it, because upstream asserts nothing about it either.
    var popped = try doc2.diffIncremental(gpa);
    defer popped.deinit();

    const changes_after_mark = try doc1.saveAfter(gpa, heads_before_mark);
    defer gpa.free(changes_after_mark);
    // Upstream asserts nothing about the load here, and neither does this:
    // `loadIncremental` answers **rows added**, and a `Mark` is two ops
    // ([`transact.zig`](../src/transact.zig)), so a row count would be a second
    // spelling of the patch count asserted below rather than a fact about the
    // load.
    _ = try doc2.loadIncremental(gpa, changes_after_mark);

    var patches = try doc2.diffIncremental(gpa);
    defer patches.deinit();

    // "no patches generated" upstream
    // ([`test_mark_patches.rs`:31](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)). **One patch,
    // not one-or-more**: a stream that carried the mark *and* the text it was
    // written into would pass `len() >= 1` and fail this.
    try testing.expectEqual(@as(usize, 1), patches.len());
    const patch = patches.slice()[0];

    try testing.expect(patch.obj.eql(text));
    try testing.expectEqual(@as(usize, 1), patch.path.len);
    try testing.expect(patch.path[0].obj.eql(root));
    try testing.expect(patch.path[0].prop == .key);
    try testing.expectEqualStrings("text", patch.path[0].prop.key);

    // `let PatchAction::Mark { mut marks } = patch.action else { panic! }`
    // ([`test_mark_patches.rs`:35-37](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs)): a patch of
    // any other action is a failure here, not a fallthrough.
    switch (patch.action) {
        .mark => |action| {
            try testing.expectEqual(@as(usize, 1), action.marks.len);
            const mark = action.marks[0];
            try testing.expectEqualStrings("bold", mark.name);
            try testing.expectEqual(@as(usize, 5), mark.start);
            try testing.expectEqual(@as(usize, 6), mark.end);
            try testing.expect(mark.value.eql(.{ .bool_value = true }));
        },
        else => {
            std.debug.print("expected a mark patch, got {s}\n", .{@tagName(patch.action)});
            return error.TestUnexpectedResult;
        },
    }
}

// ── 2. The hydrate clause ─────────────────────────────────────────────────────

test "a mark patch hydrates: the replay reproduces the document and the mirror outlives a mutation" {
    var doc1 = try Document.init(gpa, io);
    defer doc1.deinit();
    try doc1.setActorId(actor);

    const text = try doc1.putObject(root, .{ .key = "text" }, .text);
    try doc1.spliceText(text, 0, 0, "sample");
    // **A byte-bearing scalar beside the object.** The ownership claim below is
    // about bytes a mirror copies, and a `str` in a register is the smallest
    // thing in this document that exercises it: nothing else here owns a
    // payload a later write can move.
    _ = try doc1.put(root, .{ .key = "label" }, .{ .str = "sample" });
    const heads_before_mark = try doc1.getHeads(gpa);
    defer gpa.free(heads_before_mark);

    const saved = try doc1.save(gpa);
    defer gpa.free(saved);
    const enc = doc1.textEncoding();
    var doc2 = try Document.load(gpa, io, saved, enc);
    defer doc2.deinit();

    // **The mirror as it stood before the mark**, which is what the stream is
    // replayed onto. It is taken here rather than reconstructed from a clock
    // because the point of this test is the replay, and a mirror rebuilt from a
    // clock would be testing the clock.
    var replayed = try hydrateNow(&doc2);
    defer replayed.deinit();
    try expectText(&replayed, "sample", 0);

    var popped = try doc2.diffIncremental(gpa);
    defer popped.deinit();

    try doc1.mark(text, 5, 6, "bold", .after, .{ .bool_value = true });
    const changes_after_mark = try doc1.saveAfter(gpa, heads_before_mark);
    defer gpa.free(changes_after_mark);
    _ = try doc2.loadIncremental(gpa, changes_after_mark);

    var patches = try doc2.diffIncremental(gpa);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 1), patches.len());

    // The replay itself. **A refusal counts as a failure**: `applyPatches`
    // answers `Applied.refused` as a value rather than as an error
    // ([`src/hydrate.zig`](../src/hydrate.zig)), so a stream that stopped early
    // would otherwise leave the mirror half-updated and the comparison below
    // would have nothing to say about the part that did not apply.
    switch (try replayed.applyPatches(enc, patches.slice())) {
        .ok => {},
        .refused => |failure| {
            std.debug.print("\npatch stream refused: {s}\n", .{@tagName(failure)});
            return error.PatchStreamRefused;
        },
    }

    // **Element by element, against a fresh materialisation of the same
    // document** — not against a length, and not against a shared head count.
    var fresh = try hydrateNow(&doc2);
    defer fresh.deinit();
    try expectSameMirror(&replayed, &fresh);
    // And the mark is named here, where a failure is readable, rather than
    // only implied by the equality above.
    try expectText(&replayed, "sample", 1);
    try expectBoldMark(&replayed);

    // **The ownership claim.** The document is written again — enough times to
    // make the op set's storage move, which is what a mirror that borrowed from
    // it would be reading — and the mirror is read again afterwards. Nothing
    // about the mirror changes, because nothing in it belongs to the document.
    for (0..64) |i| {
        try doc2.spliceText(text, 0, 0, "x");
        _ = try doc2.put(
            root,
            .{ .key = "filler" },
            .{ .str = if (i == 63) "the last one, and a different length" else "filler" },
        );
    }
    try doc2.unmark(text, 0, 5, .none, "bold", null);

    try expectText(&replayed, "sample", 1);
    try expectBoldMark(&replayed);
    try expectLabel(&replayed, "sample");
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Materialises an owned mirror using the public reader. Hydrate observes the
/// current document without introducing a publication barrier.
fn hydrateNow(doc: *Document) !Mirror {
    return doc.hydrate(root, null, gpa);
}

/// `v`'s root map, or a failure that says what `v` holds instead.
///
/// **One function rather than a switch at each of the call sites.** Each of
/// those switches was the same twenty lines, and a copy of a check is a check
/// one site can drift away from.
///
/// **`std.meta.activeTag` and not a `switch` capture, and that is the whole
/// difference.** A `switch (v.*) { .object => |o| .map => return &o.map }`
/// returns a pointer into `o`, and `o` is a **by-value copy** of the union
/// that dies with the switch — so the pointer dangles and the first thing the
/// caller does with it reads freed stack.
fn rootMap(v: *const Mirror) !*const am.hydrate.Map {
    if (std.meta.activeTag(v.*) != .object or std.meta.activeTag(v.object) != .map) {
        return wrongShape(outerTag(v));
    }
    return &v.object.map;
}

fn outerTag(v: *const Mirror) []const u8 {
    return switch (v.*) {
        .object => |o| @tagName(o),
        else => @tagName(v.*),
    };
}

fn wrongShape(tag: []const u8) error{TestUnexpectedResult} {
    std.debug.print("the mirror's root is a {s}, want a map\n", .{tag});
    return error.TestUnexpectedResult;
}

/// The value the mirror holds under `key`, or a failure naming `key`.
fn childOf(v: *const Mirror, key: []const u8) !*const Mirror {
    const m = try rootMap(v);
    return m.get(key) orelse {
        std.debug.print("the mirror has no \"{s}\"\n", .{key});
        return error.TestExpectedEqual;
    };
}

/// `v` itself as a text object, or a failure naming `what` it is instead.
///
/// **Separate from [`textOf`] because the two are not the same question.**
/// `textOf` answers "what does the root map hold under this key"; this one
/// answers "is this value a text", and the mark comparison in
/// [`expectSameValue`] holds a *child* of two maps rather than a root.
///
/// **`activeTag` rather than a capture, for the reason [`rootMap`] gives.**
fn asText(v: *const Mirror, what: []const u8) !*const am.hydrate.Text {
    if (std.meta.activeTag(v.*) != .object or std.meta.activeTag(v.object) != .text) {
        std.debug.print("\"{s}\" is a {s}, want a text object\n", .{ what, outerTag(v) });
        return error.TestUnexpectedResult;
    }
    return &v.object.text;
}

/// The text object the mirror holds under `key`, or a failure naming `key`.
fn textOf(v: *const Mirror, key: []const u8) !*const am.hydrate.Text {
    return asText(try childOf(v, key), key);
}

/// The text the mirror holds under `"text"`, with `want_marks` names on it.
///
/// **Three assertions and not one**: a `null` on either side is a failure of
/// its own, and collapsing them into one comparison is how a test ends up green
/// because the thing it should have found was never there.
fn expectText(v: *const Mirror, want: []const u8, want_marks: usize) !void {
    const t = try textOf(v, "text");
    const rendered = try t.makeString(gpa);
    defer gpa.free(rendered);
    if (!std.mem.eql(u8, want, rendered)) {
        std.debug.print("the mirror's text is \"{s}\", want \"{s}\"\n", .{ rendered, want });
        return error.TestExpectedEqual;
    }
    if (t.marks.len() != want_marks) {
        std.debug.print("the mirror's text carries {d} mark name(s), want {d}\n", .{
            t.marks.len(),
            want_marks,
        });
        return error.TestExpectedEqual;
    }
}

/// The single entry `set` holds, with the name and value this test writes.
///
/// **The set is sorted by name** ([`src/marks.zig`](../src/marks.zig)), so a
/// count plus a whole walk is "is there exactly this one" — a lookup that
/// returned null would sail past a count-only check whenever the set held
/// something else.
fn expectMarkSet(set: *const MarkSet, name: []const u8, want: ScalarValue) !void {
    if (set.len() != 1) {
        std.debug.print("the mirror holds {d} mark name(s), want exactly \"{s}\"\n", .{ set.len(), name });
        return error.TestExpectedEqual;
    }
    var it = set.iter();
    const entry = it.next() orelse return error.TestUnexpectedResult;
    try testing.expect(it.next() == null);
    try testing.expectEqualStrings(name, entry.name);
    try testing.expect(entry.value.eql(want));
}

/// The `bold = true` mark on the mirror's `"text"`, by name.
fn expectBoldMark(v: *const Mirror) !void {
    const t = try textOf(v, "text");
    try expectMarkSet(&t.marks, "bold", .{ .bool_value = true });
}

/// The `"label"` register's string, compared with `want`.
fn expectLabel(v: *const Mirror, want: []const u8) !void {
    const child = try childOf(v, "label");
    switch (child.*) {
        .str => |s| {
            if (!std.mem.eql(u8, want, s)) {
                std.debug.print("\"label\" is \"{s}\", want \"{s}\"\n", .{ s, want });
                return error.TestExpectedEqual;
            }
        },
        else => {
            std.debug.print("\"label\" is a {s}, want a str\n", .{@tagName(child.*)});
            return error.TestUnexpectedResult;
        },
    }
}

/// Two mirrors, element by element: every register by key, every scalar by
/// value, and every text's characters **and** its mark set.
///
/// **The register count is checked too, and it is additional rather than a
/// substitute.** The walk below starts from the first side's keys, so a
/// register one side has and the other does not is a difference it cannot
/// reach.
fn expectSameMirror(a: *const Mirror, b: *const Mirror) !void {
    const left = try rootMap(a);
    const right = try rootMap(b);
    if (left.count() != right.count()) {
        std.debug.print("one mirror has {d} register(s), the other {d}\n", .{
            left.count(),
            right.count(),
        });
        return error.TestExpectedEqual;
    }
    var it = left.entries.iterator();
    while (it.next()) |entry| {
        try expectSameValue(entry.key_ptr.*, &entry.value_ptr.value, try childOf(b, entry.key_ptr.*));
    }
}

fn expectSameValue(where: []const u8, a: *const Mirror, b: *const Mirror) !void {
    if (!a.eql(b)) {
        std.debug.print("\"{s}\" holds a {s}, want a {s}\n", .{ where, @tagName(a.*), @tagName(b.*) });
        return error.TestExpectedEqual;
    }
    // `Value.eql` has already said the two have the same shape, so the only
    // arm that can carry something `eql` drops is a text.
    switch (a.*) {
        .object => |o| switch (o) {
            .text => {
                // **The marks, which `Text.eql` deliberately leaves out.**
                const bt = try asText(b, where);
                if (!o.text.marks.eql(&bt.marks)) {
                    std.debug.print("\"{s}\" carries different marks\n", .{where});
                    return error.TestExpectedEqual;
                }
            },
            else => {},
        },
        else => {},
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **Upstream's file holds one test and this one holds that test plus one
//   clause.** The gate counts upstream cases, so the ported case is
//   `mark_patches_at_end_of_text`, named for upstream's `#[test]` and asserting
//   the same five things (`tests/test_mark_patches.rs`:29-40`). The second test
//   is an addition and is named for what it states.
//
// * **`Mark::new("bold", true, 5, 6)` is `mark(.., 5, 6, "bold", .after,
//   .{ .bool_value = true })`** ([`transact.zig`](../src/transact.zig)), because
//   the port's `Mark` is not a type: a mark is a name, a value and a range, and
//   `Mark::new`'s five arguments are exactly those. `ExpandMark::After` is
//   `marks.ExpandMark.after` and is upstream's `Default`
//   ([`marks.rs`:379-383](../github-automerge-automerge/rust/automerge/src/marks.rs)).
//
// * **The upstream `dump()` calls only print diagnostics.** Upstream calls it
//   twice ([`test_mark_patches.rs`:26, :30](../github-automerge-automerge/rust/automerge/tests/test_mark_patches.rs))
//   and discards the output; neither call contributes an assertion here.
//
// * **`AutoCommit::save_after` is `Document.saveAfter`** ([`doc.zig`](../src/doc.zig))
//   and it returns the change chunks a peer missing `heads` needs, which is
//   what `load_incremental` then takes.
//
// * **The actor is written down rather than drawn.** `AutoCommit::new` takes
//   `ActorId::random` ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs)) and
//   `test/upstream_doc_test.zig` says why a port pins it. **Both documents get
//   the same one here**, which upstream also gets by accident: `load` of a save
//   resolves the actor against the loaded document's table.
//
// * **The hydrate clause compares marks by hand, because `hydrate.Text.eql`
//   does not.** Upstream's `Text` derives `PartialEq` over `value` *and*
//   `marks` ([`hydrate/text.rs`:7-11](../github-automerge-automerge/rust/automerge/src/hydrate/text.rs)); the
//   port's `Text.eql` compares native text units only:
//   name-to-value set records what each name last held and not where, so
//   comparing it would let two texts that are not equal look equal. **The
//   clause therefore reads `Text.marks` directly**, and `expectSameMirror`
//   zips the two sets after `Value.eql` rather than relying on it.
//
// * **The document is written 128 more times after the replay, on purpose.**
//   The claim under test is that a mirror owns its bytes and not merely that
//   `hydrate.zig` says so; a mirror that borrowed its scalars from the op set
//   would be reading storage the next writes have moved. `std.testing.allocator`
//   poisons a freed block, so a borrowing mirror reads garbage here rather than
//   agreeing by luck.
