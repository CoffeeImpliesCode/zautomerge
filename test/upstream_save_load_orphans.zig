//! `$AUTOMERGE_REF/rust/automerge/tests/test_save_load_orphans.rs` — **all 3
//! `#[test]` cases, ported case for case and in upstream's order**, and
//! nothing else. Before this file the upstream file had **no** ported case.
//!
//! It is a **consumer test**: it imports `zautomerge` by name, sets no working
//! directory and reads no fixture, and `build.zig` builds it as its own module
//! with its own `addTest`. That is the shape
//! [`upstream_batch_test.zig`](upstream_batch_test.zig) and
//! [`upstream_batch_insert.zig`](upstream_batch_insert.zig) have, and it is a
//! file of its own because it is a *subject*: three cases is not enough to
//! share a file with anything.
//!
//! # The subject: an orphan
//!
//! A change the document cannot **apply** because a change it depends on has
//! not arrived is **queued**, not refused — `OpSet.applyChanges` pushes it and
//! `BatchApply` drains the queue as soon as the dependency lands
//! ([`op_set2/change/batch.rs`:1103-1105](../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
//! Three upstream behaviours turn on that queue and none of them is reachable
//! from a document that holds no orphans:
//!
//! 1. **`save` writes the queue out.** [`Document.saveWithOptions`](../src/doc.zig)
//!    appends **each queued change's raw bytes after the document chunk** when
//!    `retain_orphans` is set ([`automerge.rs`:1155-1159](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//!    so `save` → `load` → "now hand over the dependency" reaches a state the
//!    original document never had. With `retain_orphans: false` the same save
//!    loses the orphan and the same apply lands somewhere else. **The two saves
//!    differ by more than a flag** and the oracle measured the difference:
//!    **253 bytes against 139**, with the retained save's queue naming the
//!    missing dependency before the apply and the discarded one's naming
//!    nothing. Both records are in `tools/oracle`'s `orphans` subcommand.
//! 2. **`load` refuses an orphan stream unless it starts with a document
//!    chunk.** The rule is
//!    `!am.queue.is_empty() && !first_chunk_was_doc && on_partial_load == Error
//!    → AutomergeError::MissingDeps`
//!    ([`automerge.rs`:976-982](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//!    which is why `save_incremental` output — bare change chunks — cannot be
//!    loaded on its own. **This port now implements that rule**, on the
//!    citation and the shape below; it did not when this file was written, the
//!    case was left red for the gap, and the diff block at the foot of this
//!    file records both.
//! 3. **The actor table is sorted and an insertion renumbers it.**
//!    [`Document.actorSlot`](../src/doc.zig) is a binary search over the
//!    sorted table ([`automerge.rs`:1310-1320](../github-automerge-automerge/rust/automerge/src/automerge.rs))
//!    and [`OpSet.insertActor`](../src/opset/op_set.zig) then rewrites every
//!    actor index at or above that slot ([`op_set.rs`:1400-1405](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//!    which is why `ExId` carries the actor's **bytes**
//!    ([`exid.rs`:15-18](../github-automerge-automerge/rust/automerge/src/exid.rs))
//!    and `Document.resolve` re-resolves a stale index the way `exid_to_opid`
//!    does ([`automerge.rs`:744-758](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
//!    **Nothing below reaches the renumbering**, and the reason is the minting
//!    order rather than luck: [`mintActor`] hands out `01 00 …` then
//!    `02 00 …`, the fork's actor sorts **after** the base's, so it is appended
//!    and every index already in the table keeps its value. A second actor
//!    whose bytes sorted *before* the first would shift the base actor's index,
//!    and then the `ExId` rule above is what keeps a stale id readable. That
//!    arm is not this file's subject and is not asserted here.
//!
//! # The two ways the fixture has to be careful
//!
//! **The missing change is a borrowed view.** Upstream's `Orphans` struct holds
//! a `Change` by value because a Rust `Change` owns its bytes. This port's
//! [`Change`] is a **header view over borrowed bytes**, and the bytes belong to
//! the [`am.doc.Changes`] list [`Document.getChanges`] returned — so
//! [`Orphans`] carries the list next to the view, and [`Orphans.deinit`] frees
//! it. A view whose owner has been freed is a use-after-free, and
//! `std.testing.allocator` reports a double free rather than the bug.
//!
//! **Every owned value comes out of [`gpa`]**, which is
//! `std.testing.allocator` and is therefore the leak arbiter: every document,
//! every saved byte string, every head list, every change list, and the
//! `Document.getHeads` copies that [`Document.forkAt`] takes as its input.
//!
//! # The replay every case that carries both shapes also takes
//!
//! [`expectSameThroughApplyChanges`] rebuilds a document from its own changes
//! through `Document.applyChanges` and requires it to be the same document, row
//! for row. Every case below calls it on the document the case ends with, which
//! is the one whose op set the case's own assertion depends on.

const std = @import("std");
const am = @import("zautomerge");

const testing = std.testing;

/// **The leak arbiter for the whole file.** One allocator, named once.
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

const Document = am.doc.Document;
const Change = am.change_record.Change;
const ChangeHash = am.ChangeHash;
const ExId = am.ExId;
const ScalarValue = am.ScalarValue;
const ActorId = am.ActorId;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── Actors ───────────────────────────────────────────────────────────────────

/// Upstream draws an actor at random (`AutoCommit::new`,
/// [`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and `Automerge::fork` draws another ([`:316`](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// so a port that minted actors the same way would hash differently on every
/// run and a failure nobody can reproduce is not a finding. This file mints
/// them from a counter instead: distinct bytes, a stable order, the same bytes
/// on every run.
///
/// The bytes start at one, so no document ever has an **empty** actor, which is
/// a different value from every other one. This is the rule
/// [`test/upstream_batch_test.zig`](upstream_batch_test.zig) sets and the
/// reason it gives.
///
/// **The static storage is what makes the returned [`ActorId`] a borrow**: a
/// document copies the bytes when it interns the actor
/// ([`Document.setActorId`](../src/doc.zig)), so the array outliving the call
/// is the whole ownership story.
var minted_actors: [32][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] and [`forkDoc`] hand out.
fn mintActor() ActorId {
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

/// A document in the flavour upstream's `AutoCommit` is.
fn newDoc() !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

/// `doc.fork()` ([`test_save_load_orphans.rs`:14](../github-automerge-automerge/rust/automerge/tests/test_save_load_orphans.rs)),
/// through [`Document.forkAt`](../src/doc.zig) at the source's own heads.
///
/// **Not [`Document.fork`]**, and the reason is recorded where the shape file
/// records it: `fork` stores `ActorId.random`'s bytes in `actor.unused` and
/// `Document.deinit` frees no actor bytes, so it leaks under the arbiter. The
/// fork's actor is minted here instead, which is what `fork` draws anyway.
fn forkDoc(src: *Document) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    var out = try src.forkAt(gpa, heads, .auto);
    out.setActorId(mintActor());
    return out;
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `obj.prop`, or `error.NotAnObject` / `error.NoSuchKey`.
///
/// **`ReadDoc::get`** ([`read.rs`:259](../github-automerge-automerge/rust/automerge/src/read.rs)).
fn scalarAt(doc: *const Document, obj: ExId, prop: am.Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

// ── The replay every case below also takes ───────────────────────────────────

/// Rebuild `doc` from its own changes through `Document.applyChanges` and
/// require the result to be the same document.
///
/// **Why the row comparison comes first.** [`Document.debugCmp`] is "row for
/// row and byte for byte" ([`op_set.rs`:69-71](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
/// so a row-order or row-count divergence fires there, with a diagnostic that
/// names the fault, before any contents comparison could paper over it. **A
/// divergence in this file's rows therefore reports as `FAIL (Invariant)`, not
/// as a value mismatch** — which is a different diagnostic from the one the
/// falsification at the foot of the file produced, because that one perturbed
/// the *value* assertion and not the rows.
///
/// **The replayed document is given no actor of its own**, deliberately. It
/// never writes, and [`Document.setActorId`] on an actor the table does not
/// hold stores it as `actor.unused` **without interning it**
/// ([`Document.setActorId`](../src/doc.zig)), so the actor table `debugCmp`
/// compares is the one the incoming changes built — which is the comparison
/// worth making. [`mintActor`] is therefore not called here, and the minted
/// counter is not advanced.
///
/// **It returns without a check when the document holds no changes**, because
/// `applyChanges` over an empty list is a no-op that would pass for the wrong
/// reason.
///
/// **A queued orphan is not in `getChanges`' answer**, and that is correct
/// rather than a hole: the queue is what the document *cannot* apply, and the
/// replay is about the op set. Every call site below therefore also asserts
/// the queue state separately, which is where an orphan is observable at all.
fn expectSameThroughApplyChanges(doc: *Document) !void {
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    if (all.len() == 0) return;

    const views = try gpa.alloc(Change, all.len());
    defer gpa.free(views);
    for (0..all.len()) |i| views[i] = all.at(i);

    var replayed = try Document.init(gpa, .auto);
    defer replayed.deinit();
    _ = try replayed.applyChanges(gpa, views);

    try replayed.debugCmp(doc);
}

// ── The fixture both of the first two cases build ────────────────────────────

/// `doc_with_orphans` ([`test_save_load_orphans.rs`:9-27](../github-automerge-automerge/rust/automerge/tests/test_save_load_orphans.rs)),
/// with the port's borrowing rules.
///
/// Upstream's two steps that have no direct spelling:
///
/// * **`doc2.get_last_local_change()`** ([`:16`, `:18`](../github-automerge-automerge/rust/automerge/tests/test_save_load_orphans.rs))
///   becomes [`Document.getChanges`] over **the heads as they stood before the
///   write**. `getLastLocalChange` is a *different* function
///   ([`automerge.rs`:1223-1228](../github-automerge-automerge/rust/automerge/src/automerge.rs))
///   that walks the actor's sequence number; the heads form is used because it
///   also proves the change is **new**, which `getLastLocalChange` cannot: it
///   answers the same change whether or not the last write was this one.
///   **The `have` list has to be the heads from immediately before the write
///   and not the fork's base** — `get_changes` asks what the *peer* lacks
///   ([`automerge.rs`:1512-1514](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
///   so asking from the base names both fork changes, not one. That was the
///   first version of this file and the port answered it correctly.
/// * **`doc1.apply_changes(vec![change2])`** becomes [`Document.applyChanges`],
///   whose answer is a **count of changes it applied**
///   ([`Document.applyChanges`](../src/doc.zig)). **Zero is the assertion**: a change
///   whose dependency is absent is queued rather than applied, so a non-zero
///   answer would mean there is no orphan and the rest of the file is testing
///   nothing.
const Orphans = struct {
    /// `doc1`: one change of its own, and the queued orphan.
    doc: Document,
    /// Owns `missing`'s bytes. **It must outlive `missing`** — see the file
    /// header.
    changes: am.doc.Changes,
    /// `change1`: the change `doc1` never saw, which both cases hand over
    /// after the save.
    missing: Change,

    fn deinit(self: *Orphans) void {
        self.changes.deinit(gpa);
        self.doc.deinit();
        self.* = undefined;
    }
};

/// Builds the fixture. Upstream's lines 9-27, with the transaction shape noted
/// below.
fn docWithOrphans() !Orphans {
    var doc1 = try newDoc();
    errdefer doc1.deinit();
    // "Create a document with an orphan change" (`:10-11`).
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value" });

    const base_heads = try doc1.getHeads(gpa);
    defer gpa.free(base_heads);

    // "Create two changes remotely" (`:13-18`). `fork` copies the history and
    // nothing else, so both changes descend from `base_heads`.
    var doc2 = try forkDoc(&doc1);
    // **`defer`, not `errdefer`**: the fork goes out of scope at the end of this
    // function and nothing else holds it, and `errdefer` would cancel on the
    // successful return and leak the whole fork — which the arbiter then
    // reports as a hundred-odd allocations with three-file-deep stacks, over
    // the fault. **Freeing it here is safe although [`Orphans`] hands back a
    // view into `first`**: `Document.getChanges` rebuilds each change's bytes
    // into fresh storage owned by the [`am.doc.Changes`] list
    // ([`Document.getChanges`](../src/doc.zig)), so nothing in `missing` points
    // into `doc2`.
    defer doc2.deinit();

    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "value2" });
    var first = try doc2.getChanges(gpa, base_heads);
    errdefer first.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), first.len());
    const change1 = first.at(0);

    // **`Document.getChanges`' argument is what the peer already has, not what
    // this document had before the write** ([`Automerge::get_changes`](../github-automerge-automerge/rust/automerge/src/automerge.rs):1512-1514,
    // over [`ChangeGraph.getChangeIndexes`](../src/change_graph.zig),
    // which folds a clock out of `have` and then yields every actor's changes
    // **after** the sequence that clock records). So `base_heads` names the
    // fork's own base and **both** fork changes are things a peer at
    // `base_heads` does not have — the first version of this file asked for
    // them by `base_heads` twice and asserted one, and the port was right and
    // the assertion was wrong: it got `expected 1, found 2`.
    //
    // The `have` list that names **only** the second write is therefore the
    // fork's own heads **after** the first write, which is the exact analogue
    // of upstream's `get_last_local_change`
    // ([`:1223-1228`](../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // the change that write produced, with a count to say it was one.
    const after_first = try doc2.getHeads(gpa);
    defer gpa.free(after_first);
    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "value3" });
    var second = try doc2.getChanges(gpa, after_first);
    defer second.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), second.len());
    const change2 = second.at(0);

    // "Apply the second change, which means it will be orphaned because doc1
    // doesn't have the first change" (`:20-22`).
    //
    // **`Document.applyChanges` copies the incoming bytes** — the queue owns
    // them and the next `save` would otherwise read a dangling pointer
    // ([`Document.applyChanges`](../src/doc.zig)) — so `second` is freed at the end
    // of this function while `change1`, still owned by `first`, goes back to
    // the caller.
    try testing.expectEqual(@as(usize, 0), try doc1.applyChanges(gpa, &.{change2}));

    // **The queue, asserted, not assumed.** `getMissingDeps` chains every
    // queued change in front of its argument
    // ([`automerge.rs`:2290-2291](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so this names `change1` — the dependency the orphan is waiting for — and
    // nothing else. `change1` is exactly that dependency because `second`'s
    // only dep is `first`'s.
    const waiting = try doc1.getMissingDeps(gpa, &.{});
    defer gpa.free(waiting);
    try testing.expectEqualSlices(ChangeHash, &.{change1.hash}, waiting);

    return .{ .doc = doc1, .changes = first, .missing = change1 };
}

// ── 1. save_orphaned_changes ─────────────────────────────────────────────────

test "save keeps an orphaned change, and the dependency later drains it" {
    // `test_save_load_orphans.rs`:29-46
    var orphans = try docWithOrphans();
    defer orphans.deinit();

    // `let saved = doc.save();` (`:36`). **`Document.save` is upstream's
    // `AutoCommit::save`**, and the port's `Document` is upstream's
    // `Automerge` underneath one `AutoCommit`. **The merge is recorded in
    // [`Document.saveWithOptions`](../src/doc.zig)'s own doc comment**, and the
    // only difference between the two layers is the save cursor, which moves to
    // the document's heads — a side effect this case does not read, because
    // `orphans.doc` is freed at the end of the test.
    const saved = try orphans.doc.save(gpa);
    defer gpa.free(saved);

    // `let mut loaded = AutoCommit::load(&saved).unwrap();` (`:37`).
    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();

    // **An addition, not a gap.** Upstream asserts only the value at `:42-45`,
    // and the oracle (`tools/oracle`, subcommand `orphans`) reports both of
    // these for this exact case, so they are upstream's own answers and not the
    // port's reading of them:
    //
    // * the saved stream is 253 bytes and its first chunk is a **document**
    //   chunk (type byte `0` at offset 8), against 139 bytes for
    //   `discard_orphans` below;
    // * before the dependency arrives the loaded document is **missing
    //   exactly `change1`'s hash** — the orphan survived the round trip, still
    //   queued.
    //
    // The second one is what makes a failure attributable. A save that
    // dropped the orphan would still fail the value assertion below, and both
    // failures would look the same; here the queue state says *which half of
    // the round trip* lost it.
    const waiting = try loaded.getMissingDeps(gpa, &.{});
    defer gpa.free(waiting);
    try testing.expectEqualSlices(ChangeHash, &.{orphans.missing.hash}, waiting);

    // `loaded.apply_changes(vec![missing_change]).unwrap();` (`:39`).
    //
    // **The count is 2, and it is the assertion that matters.** Upstream writes
    // `.unwrap()` and throws the number away; this port's `applyChanges`
    // returns how many changes it *applied*
    // ([`Document.applyChanges`](../src/doc.zig)), and the answer here is the
    // dependency **plus the orphan it unblocked**. `BatchApply` pops the queue
    // after every insert and applies whatever became ready
    // ([`op_set2/change/batch.rs`:1103-1105](../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)),
    // so a document that applied the dependency and left `change2` queued
    // would answer 1 and read `"value2"`. **The first version of this file
    // asserted 1** — "one change was handed in, so one is applied" — and the
    // port answered 2, correctly.
    try testing.expectEqual(@as(usize, 2), try loaded.applyChanges(gpa, &.{orphans.missing}));

    // The queue is empty now, which the value assertion alone would not say.
    const drained = try loaded.getMissingDeps(gpa, &.{});
    defer gpa.free(drained);
    try testing.expectEqual(@as(usize, 0), drained.len);

    // "Both changes should now have been applied so the end result should be
    // value3" (`:41-45`).
    try testing.expectEqualStrings("value3", (try scalarAt(&loaded, root, .{ .key = "key" })).str);

    try expectSameThroughApplyChanges(&loaded);
}

// ── 2. discard_orphans ───────────────────────────────────────────────────────

test "save discards the orphan when retain_orphans is false" {
    // `test_save_load_orphans.rs`:48-69
    //
    // **The same fixture as case 1, saved differently.** Everything above the
    // `save` is the same code path, which is what makes the difference in the
    // answer attributable to the one option.
    var orphans = try docWithOrphans();
    defer orphans.deinit();

    // `doc.save_with_options(SaveOptions { retain_orphans: false, ..Default::default() })`
    // (`:55-58`). **`deflate` is left at its default of `true`**, which is
    // upstream's (`automerge.rs`:2348-2352), and it does not affect the queue:
    // the orphan's bytes are appended *after* the document chunk and are never
    // deflated.
    const saved = try orphans.doc.saveWithOptions(gpa, .{ .deflate = true, .retain_orphans = false });
    defer gpa.free(saved);

    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();

    // **An addition, not a gap.** The oracle reports this case's save as 139
    // bytes against case 1's 253, and `missing_before_apply` as `[]`. This is
    // upstream's own observable for "the dependent change should never have
    // been included" (`:63`), stated as a check rather than left to the value.
    const waiting = try loaded.getMissingDeps(gpa, &.{});
    defer gpa.free(waiting);
    try testing.expectEqual(@as(usize, 0), waiting.len);

    _ = try loaded.applyChanges(gpa, &.{orphans.missing});

    // "The depeendent change should never have been included and so we should
    // only see the value from the second change" (`:63-68`). Upstream's
    // `change1` is the `"value2"` write; the naming is upstream's, and the
    // transcript keeps it.
    try testing.expectEqualStrings("value2", (try scalarAt(&loaded, root, .{ .key = "key" })).str);

    try expectSameThroughApplyChanges(&loaded);
}

// ── 3. load_incremental_change_without_deps_throws ───────────────────────────

test "loading an orphan change stream without a document chunk first is refused" {
    // `test_save_load_orphans.rs`:71-83
    //
    // **This case is the file's whole claim to be here.** It is the only one of
    // the three that exercises a rule no other ported test reaches, and the
    // rule is
    //
    // ```text
    // if !am.queue.is_empty() && !first_chunk_was_doc
    //        && options.on_partial_load == OnPartialLoad::Error
    // { return Err(AutomergeError::MissingDeps); }
    // ```
    //
    // ([`automerge.rs`:976-982](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // — "Only allow missing deps if the first chunk was a document chunk",
    // citing [automerge PR 599](https://github.com/automerge/automerge/pull/599#issuecomment-1549667472).
    // Upstream's own comment above it is the case: "loading an orphan change
    // without a document chunk as first chunk should fail" (`:82`).
    var doc = try newDoc();
    defer doc.deinit();

    _ = try am.transaction.put(&doc, root, .{ .key = "key" }, .{ .str = "value" });
    // "let _ = doc.save_incremental();" (`:75`). **Discarded on purpose**,
    // exactly as upstream discards it: it exists to move the save cursor past
    // the first change, so the second save carries the second change alone.
    const first = try doc.saveIncremental(gpa);
    defer gpa.free(first);

    // The heads after the first change, so the second change can be named. The
    // port needs the change itself and upstream does not — upstream reloads
    // nothing — so this is the port's extra step and it is why
    // [`am.doc.Changes`] is in the allocator's ledger twice over.
    const heads1 = try doc.getHeads(gpa);
    defer gpa.free(heads1);

    _ = try am.transaction.put(&doc, root, .{ .key = "key" }, .{ .str = "value2" });
    var second = try doc.getChanges(gpa, heads1);
    defer second.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), second.len());

    // "let orphan = doc.save_incremental();" (`:78`).
    const orphan = try doc.saveIncremental(gpa);
    defer gpa.free(orphan);

    // **This is a stream of change chunks and nothing else.** Oracle check, not
    // an assumption: `save_incremental` is
    // `save_after(&save_cursor)` ([`autocommit.rs`:590-597](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // which emits concatenated change chunks ([`automerge.rs`:1194-1201](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and the oracle prints the chunk type byte at offset 8 as `1` for both
    // this case's saves — `0` is a document chunk
    // ([`storage/chunk.rs`](../github-automerge-automerge/rust/automerge/src/storage/chunk.rs),
    // `readChunk` in [`src/storage/chunk.zig`](../src/storage/chunk.zig)).
    // So `first_chunk_was_doc` is false and the refusal is the branch that
    // fires.
    try testing.expect(orphan.len > 0);
    try testing.expectEqual(@as(u8, 1), orphan[8]);

    // And the same stream *is* loadable when its dependency is present, which
    // is the shape the rule carves out: the first save is one change with no
    // dependency of its own, so `load` accepts it, and a follow-up apply of the
    // second change brings it to `"value2"`. That is upstream's own
    // `load_incremental` on a document that already holds the base
    // ([`automerge.rs`:1038-1045](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and the oracle's `loadinc` subcommand reports that load as `ok`.
    //
    // **This is an addition**: it is what distinguishes "this stream is bad"
    // from "this stream cannot be read", and without it a port that refused
    // *every* change-chunk stream would pass this case. **It is placed before
    // the refusal assertion on purpose**, so it is still exercised while the
    // refusal below is failing — a case whose last statement is the failing one
    // reports nothing about the assertions before it.
    var known = try Document.load(gpa, first, .unicode_code_point, .auto);
    defer known.deinit();
    try testing.expectEqual(@as(usize, 1), try known.applyChanges(gpa, &.{second.at(0)}));
    try testing.expectEqualStrings("value2", (try scalarAt(&known, root, .{ .key = "key" })).str);

    // `if let Err(e) = AutoCommit::load(&orphan) { assert_eq!(e,
    // automerge::AutomergeError::MissingDeps) } else { panic!(...) }` (`:79-83`).
    //
    // Upstream writes the `else` arm as a `panic!` and the `Err` arm as an
    // equality on the variant; this port asserts the same thing without the
    // `else`, because a `load` that returns a document must fail here.
    //
    // **Not `testing.expectError`, and the reason is a leak rather than a
    // taste.** `expectError` drops the `Document` it was handed on the passing
    // path without a `deinit`, so a port that wrongly accepts the stream
    // buries this one fault under the allocator's report of every allocation
    // the document made — thirty-odd stack traces naming `src/`, and the fault
    // one line down. The result is matched by hand, **the document is freed
    // before the failure is raised**, and the diagnostic names the rule.
    //
    // **The measured answer is `MissingDeps`.** The oracle's third record for
    // this case is
    // `"result": "err", "debug": "MissingDeps", "display": "change's deps
    // should already be in the document"` ([`error.rs`:66](../github-automerge-automerge/rust/automerge/src/error.rs),
    // [`automerge.rs`:976-982](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    //
    // **This assertion was failing when the file was written, and that was the
    // finding.** The rule above was absent from the port, the case was left red
    // rather than relaxed — relaxing it would have deleted the only record that
    // the rule was missing — and it now passes against the fix recorded in the
    // diff block at the foot of this file.
    if (Document.load(gpa, orphan, .unicode_code_point, .auto)) |accepted| {
        var wrongly = accepted;
        wrongly.deinit();
        std.debug.print(
            "\nload accepted a change-chunk stream that leaves an orphan queued.\n" ++
                "upstream refuses this at automerge.rs:976-982 with AutomergeError::MissingDeps\n",
            .{},
        );
        return error.OrphanStreamAccepted;
    } else |e| {
        try testing.expectEqual(error.MissingDeps, e);
    }
}

// ── Zig 0.16.0 / upstream / Rust / port ───────────────────────────────────────
//
// ## The one gap this file found, and what closed it
//
// **`load_incremental_change_without_deps_throws` was failing, and the port was
// wrong.** Upstream refuses to load a change-chunk stream that leaves anything
// queued when its first chunk was not a document chunk:
//
// ```text
// if !am.queue.is_empty()
//     && !first_chunk_was_doc
//     && options.on_partial_load == OnPartialLoad::Error
// { return Err(AutomergeError::MissingDeps); }
// ```
//
// ([`automerge.rs`:976-982](../github-automerge-automerge/rust/automerge/src/automerge.rs);
// `first_chunk_was_doc` is set at [`:923`](../github-automerge-automerge/rust/automerge/src/automerge.rs)
// and [`:927`](../github-automerge-automerge/rust/automerge/src/automerge.rs).
// The comment above it names the reason: "Only allow missing deps if the first
// chunk was a document chunk", citing automerge PR 599.)
//
// **The port had no such rule.** [`Document.loadIntoWith`](../src/doc.zig)
// applied every chunk after the first and then consulted only `on_partial`, and
// the string `first_chunk_was_doc` appeared nowhere in `src/`. So
// `Document.load` on an orphan change stream returned a document that held
// nothing and a queue holding one change, and case 3's refusal assertion saw
// success.
//
// **The oracle agrees with upstream.** `tools/oracle`'s `orphans` subcommand
// runs all three cases against the reference. Its third record is
//
// ```json
// {"case":"load_incremental_change_without_deps_throws","orphan_first_chunk_type":1,
//  "result":"err","detail":{"debug":"MissingDeps",
//  "display":"change's deps should already be in the document"}}
// ```
//
// and its first two records are the two `save` options:
//
// ```json
// {"case":"save_orphaned_changes","saved_bytes":253,"saved_first_chunk_type":0,
//  "missing_before_apply":["27aa4f…db0a"],"value_before_apply":{"type":"str","value":"value"},
//  "applied":"ok","value_after_apply":{"type":"str","value":"value3"},"missing_after_apply":[]}
// {"case":"discard_orphans","saved_bytes":139,"saved_first_chunk_type":0,
//  "missing_before_apply":[],"value_before_apply":{"type":"str","value":"value"},
//  "applied":"ok","value_after_apply":{"type":"str","value":"value2"}}
// ```
//
// which are the numbers asserted in cases 1 and 2 above.
//
// **The case was left red on purpose while the gap was open.**
// [`src/doc.zig`](../src/doc.zig) is not this file's, and the change is to a
// document load path four gates already agree on. Relaxing the assertion would
// have deleted the only record that the rule was missing, which is the one
// thing a red case is for; so the brief was to report the defect with its
// citation and let the suite say so.
//
// **It is closed.** [`Document.loadIntoWith`](../src/doc.zig) now binds
// `const first_chunk_was_doc = chunks[0].typ == .document;` once, **reuses
// the same binding in the `rest` block** that already decided where the change
// chunks start, and after the apply loop refuses:
//
// ```zig
// if (on_partial == .refuse and !first_chunk_was_doc and !self.queue.isEmpty()) {
//     return error.MissingDeps;
// }
// ```
//
// — which is upstream's three conditions in upstream's order, with
// `on_partial_load == OnPartialLoad::Error` spelled as `.refuse`. Binding the
// flag once and reading it twice is the part worth keeping: the branch that
// decides where changes start and the branch that decides whether a stream is
// admissible were answering the same question separately, and two answers to
// one question drift.
//
// **The rule is "refuse a change-first stream that _ends_ with something
// queued", and it takes two controls to say that.** One control is not enough,
// and the pair is why the wording above is safe to assert.
//
// * **Document-chunk-first with a NON-EMPTY queue is admissible** — case 1 of
//   this file. A save with `retain_orphans` set is a **document chunk followed
//   by** the orphan's raw change chunk
//   ([`automerge.rs`:1155-1159](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   so the stream loads with something queued and still answers `"value3"`.
//   This half is this file's.
// * **Change-chunk-first with an EMPTY queue is also admissible**, and that
//   half is not this file's: `test/fixtures/two_change_chunks_out_of_order.automerge`
//   is a change-chunk stream — **type byte `1` at offset 8**, read off the
//   file — whose first change queues and whose second drains it, and the
//   manifest records it `.expect = .load_ok`
//   ([`manifest.zig`](../test/fixtures/manifest.zig), citing upstream
//   [`test.rs`:2246](../github-automerge-automerge/rust/automerge/tests/test.rs));
//   [`test/upstream_doc_more.zig`](../test/upstream_doc_more.zig) loads it and
//   asserts the object materialises. Upstream reads `am.queue.is_empty()`
//   **after** `apply_changes`, not after each change, so the queue having been
//   non-empty mid-stream does not refuse the stream.
//
// A rule written as "refuse change-first streams" passes the refusal in case 3
// and fails both of those. A rule written as above is what upstream's three
// conditions actually say.
//
// **The position of the check is pinned executably, not only argued.** The
// refusal sits **after** the `truncated` branch because upstream's condition is
// inside the **`Complete` arm** of the `load_changes` match
// ([`automerge.rs`:974-984](../github-automerge-automerge/rust/automerge/src/automerge.rs))
// while the `Partial` arm returns without ever reaching `apply_changes`
// ([`:975`](../github-automerge-automerge/rust/automerge/src/automerge.rs)) — so
// a stream that both queues a change and stops early is the truncation error and
// never `MissingDeps`. **A test in [`src/doc.zig`](../src/doc.zig) pins it**,
// building a stream whose first chunk is the orphan and whose tail stops
// mid-chunk, so both halves of the refusal condition are true of the prefix at
// once; a check placed before the truncation branch answers `MissingDeps` for
// that stream and fails it. The ordering is therefore a property of the code
// and not of the argument, which is the only kind worth relying on.
//
// ## Two of the three failures in the first run were this file's, not the port's
//
// Both are recorded because the *port answered correctly and the assertion
// did not*, which is the outcome worth being able to recognise.
//
// * **`expectEqual(1, doc2.getChanges(gpa, base_heads).len())` got 2.**
//   `get_changes` asks what the **peer** lacks, not what this document had
//   before the write ([`automerge.rs`:1512-1514](../github-automerge-automerge/rust/automerge/src/automerge.rs),
//   over [`ChangeGraph.getChangeIndexes`](../src/change_graph.zig),
//   which folds a clock out of `have` and then yields every actor's changes
//   **after** that clock's sequence). A peer at `base_heads` has the fork's
//   base and neither of the fork's two changes, so **two** is the right answer
//   and one was the wrong question. The `have` list has to be the heads from
//   immediately **before** each write; the assertion is in the fixture now and
//   names the citation.
// * **`expectEqual(1, loaded.applyChanges(gpa, &.{missing}).len())` got 2.**
//   `applyChanges` returns the changes it **applied**
//   ([`Document.applyChanges`](../src/doc.zig)), and the call applies the dependency
//   **and the orphan it unblocks** — `BatchApply` pops the queue after every
//   insert ([`op_set2/change/batch.rs`:1103-1105](../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
//   Upstream writes `.unwrap()` and discards the number, so this is an added
//   assertion; it is the one that distinguishes "the orphan drained" from "the
//   orphan is still queued", which the value assertion alone also distinguishes
//   but only indirectly.
//
// ## The mappings the fixture needed
//
// 1. **`get_last_local_change` is spelled as heads, and that is a
//    strengthening.** Upstream takes the change it just made with
//    `doc2.get_last_local_change().clone()`
//    ([`:16`, `:18`](../github-automerge-automerge/rust/automerge/tests/test_save_load_orphans.rs));
//    the port takes it with `Document.getChanges` over the heads from before
//    the write. `Document.getLastLocalChange` does exist
//    ([`automerge.rs`:1223-1228](../github-automerge-automerge/rust/automerge/src/automerge.rs),
//    [`Document.getLastLocalChange`](../src/doc.zig)) and walks the actor's sequence number,
//    which answers the same change whether or not the last write was this one;
//    the heads form also fails when a write produced nothing, which upstream
//    would reach as a `None` and `.unwrap()`.
// 2. **The change boundaries are the same, and it is worth saying why.**
//    Upstream's `AutoCommit` opens one lazily-opened transaction
//    ([`autocommit.rs`:445-457](../github-automerge-automerge/rust/automerge/src/autocommit.rs))
//    and `get_last_local_change` closes it
//    ([`:615-618`](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
//    so `put` → `get_last_local_change` → `put` is **two** changes upstream. The
//    port's `am.transaction.put` opens, applies and commits each time, so it is
//    two as well: the fork makes two, `doc1` makes one, and every assertion
//    here depends on nothing else.
// 3. **A `Change` is a borrow here.** See the file header; the consequence is
//    [`Orphans`] carrying its [`am.doc.Changes`] list, and the fork being freed
//    with `defer` rather than `errdefer` because the view does not point into
//    it ([`Document.getChanges`](../src/doc.zig)).
// 4. **`Document.fork` is not used; `Document.forkAt` is**, because `fork`
//    stores `ActorId.random`'s bytes in `actor.unused` and `Document.deinit`
//    frees no actor bytes. Upstream's `AutoCommit::fork`
//    ([`autocommit.rs`:356-367](../github-automerge-automerge/rust/automerge/src/autocommit.rs))
//    is a clone plus a fresh actor, which is what `forkAt` at the source's own
//    heads plus a minted actor is.
//
// ## The one strengthening, named
//
// [`expectSameThroughApplyChanges`] is in none of the three upstream cases. It
// is here because a **save → load → apply** round trip is the only place in
// this file where a document's op set is built by the *read* path rather than
// the *write* path, and `Document.debugCmp` is "row for row and byte for byte"
// ([`op_set.rs`:69-71](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
// Cases 1 and 2 both call it on the document they end with. **It is not a
// substitute for the value assertion**, which is upstream's and which stands
// on its own: `debugCmp` compares op sets, and two different op sets can
// materialize the same value.
//
// ## How this file was falsified, and the check that rules out a compile error
//
// An exit code is not a falsification: it says something went wrong and not
// what, and a *compile* error in a perturbed source produces **zero** `FAIL`
// lines where a real failure produces one per affected test. So the perturbed
// run below is only evidence because all three held:
//
// 1. exit non-zero;
// 2. `grep -cE '\.zig:[0-9]+:[0-9]+: error:'` is **0** — nothing failed to
//    compile;
// 3. the count of `FAIL` lines is non-zero, and the diagnostic names the fault.
//
// **The perturbation**: case 1's `expectEqualStrings("value3", …)` became
// `"value4"` — a string the port is never asked to produce, so the run cannot
// pass — and was reverted immediately afterwards.
//
// **What the perturbed run printed**: exit **1**, compile errors **0**, `FAIL`
// lines **2** (one from the perturbation, one the defect above, which is
// already red), `leaked` **0**, and
//
// ```text
// 1/3 …save keeps an orphaned change, and the dependency later drains it...
// expected this output:  value4
// instead found this:    value3
// First difference occurs on line 1: expected 'x34' found 'x33'
// FAIL (TestExpectedEqual)   at test/upstream_save_load_orphans.zig:377
// ```
//
// **What the reverted run printed**: `sha256sum -c` **OK** against the hash
// taken before the perturbation, then `3` tests, exit 1, compile errors **0**,
// `FAIL` lines **1** (the defect above), `leaked` **0**, and
// `2 passed; 0 skipped; 1 failed`.
//
// **What the final run printed**, once the gap above was closed: **3 tests,
// exit 0, compile errors 0, `FAIL` 0, `leaked` 0**, and
//
// ```text
// 1/3 …save keeps an orphaned change, and the dependency later drains it...OK
// 2/3 …save discards the orphan when retain_orphans is false...OK
// 3/3 …loading an orphan change stream without a document chunk first is refused...OK
// ```
//
// **Between those two runs the tree stopped compiling twice**, both times in
// [`src/read.zig`](../src/read.zig) and not in this file: once for four
// shadowing errors and once for a two-function dependency loop among a
// sibling's new test helpers. **The diagnostic that separates "my slice failed"
// from "the run never started" is the `FAIL` count, not the exit code** — a
// compile-blocked run prints `FAIL=0` with `OK=0`, which is neither a pass nor
// a failure, and an exit code of 1 is compatible with both states.
//
// ## Why every citation into `src/**` in this file names a function
//
// It is this file's own lesson, not a general preference. Those citations were
// all `path:line` when it was written, and twenty of them were **verified**
// — every one landed on the function it named — because at that moment nothing
// was editing those files. Then the fix to the gap above landed in
// [`src/doc.zig`](../src/doc.zig) and **eight of them went stale within the
// hour**, among them `doc.zig:3768-3779`, which had pointed at
// `Document.saveWithOptions` and afterwards pointed at the middle of
// `loadIncremental`. So they are now cited by name:
// [`Document.applyChanges`](../src/doc.zig),
// [`Document.getChanges`](../src/doc.zig),
// [`Document.setActorId`](../src/doc.zig),
// [`Document.getLastLocalChange`](../src/doc.zig),
// [`Document.saveWithOptions`](../src/doc.zig),
// [`ChangeGraph.getChangeIndexes`](../src/change_graph.zig),
// [`Columns.rewriteWithoutActor`](../src/opset/columns.zig) and
// `readChunk` in [`src/storage/chunk.zig`](../src/storage/chunk.zig).
//
// **The `path:line` form is kept for the reference checkout**, which is frozen
// by construction — `AUTOMERGE_REF` is read-only and nothing in this session
// writes to it — so `automerge.rs:976-982`, `read.rs:302` and
// `exid.rs:15-18` cannot drift. The distinction is not care, it is whether the
// file is being edited.
//
// ## What was not reached
//
// **All three upstream cases are here and all three pass**, and the `orphans`
// subcommand in `tools/oracle` covers all three against the reference too. The
// subcommand is deliberately **not** in `golden_vectors` in
// [`build.zig`](../build.zig): per the rule stated there, a subcommand that
// owns no vector prints to stdout and is left alone, and recording a golden no
// check compares would be a file that only looks like a gate.
//
// **`Document.removeUnusedActors` was not reached**, and the reason is
// measured rather than hoped for. Upstream's `AutoCommit::save_with_options`
// calls `remove_unused_actors(true)` before saving
// ([`autocommit.rs`:534-542](../github-automerge-automerge/rust/automerge/src/autocommit.rs));
// this port's [`Document.saveWithOptions`](../src/doc.zig) does not, so the save
// path cannot reach
// `OpSet.remove_actor` → `Columns::rewrite_without_actor`, and the branch that
// upstream panics on ([`columns.rs`:355-357](../github-automerge-automerge/rust/automerge/src/hexane/columns.rs))
// is one the port refuses ([`Columns.rewriteWithoutActor`](../src/opset/columns.zig)).
// **This fixture is not the one that reaches it either**: the fork's actor
// interns and writes in the same call, so by the time `doc1` holds the queued
// orphan every actor in the table has a change the graph names. No case here
// panics, and no case here aborts the binary.
