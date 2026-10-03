//! `rust/automerge/tests/test.rs`, **the remainder** of it.
//!
//! [`test/upstream_doc_test.zig`](upstream_doc_test.zig) is the first 117
//! cases of that file, ported case for case and in upstream's order. **This
//! file is the other 23**, and it is a second file rather than the tail of the
//! first for two reasons: two agents cannot edit one 4,900-line file without a
//! write-write conflict, and each file's count is then its own.
//!
//! ## Which 23, and how that was established
//!
//! Not by name. The 117 test names in the other file are prose rather than
//! upstream's identifiers, so a name diff answers nothing; the mapping was
//! established from the **`// ── N.` section headers** that file carries, each of
//! which names its upstream test and cites `test.rs:<line>`. Sections 2 to 124
//! name 123 upstream tests one for one and hold 117 `test "` declarations,
//! because six of them are a recorded gap rather than a test and one covers
//! four upstream cases at once. The arithmetic that follows:
//!
//! | | count |
//! | --- | --- |
//! | upstream `#[test]` declarations in `tests/test.rs` | 140 |
//! | covered by a section in `upstream_doc_test.zig` | 127 |
//! | `test "` declarations in that file | 117 |
//! | **upstream cases this file owns** | **13** |
//!
//! 127 + 13 = 140, and 13 + 12 `test "` declarations below = the 25 the other
//! file does not have. Two of the 13 are not `#[test]`s upstream: see case 14.
//!
//! ## The four fixture cases are *not* covered elsewhere
//!
//! `build.zig`'s note on the other file says `test/fixtures_test.zig` already
//! covers `fuzz_crashers`, `overlong_leb`, `load` and `obj_id_64bits`. **It does
//! not.** [`fixtures_test.zig`](fixtures_test.zig) checks that the manifest and
//! the corpus directory hold the same files, that every one of them starts with
//! the four-byte magic, and that the eight crashers are marked `load_err` — and
//! it never calls `Document.load` on any of them. So the manifest's `expect`
//! column, which `manifest.zig` describes as "a load that succeeds where this
//! says `load_err` is a bug", was **unenforced**: no test in the tree loaded a
//! single fixture. Cases 10 to 13 below do, which is why this file's build step
//! sets a working directory and no other test step does.
//!
//! ## What is in here
//!
//! Thirteen `test` declarations, in upstream's order, each pinned to the
//! property its upstream case names:
//!
//! | # | upstream | what it pins |
//! | --- | --- | --- |
//! | 8 | `test_compressed_changes` | a deflated change chunk decodes to the same change bytes and the same hash |
//! | 10 | `fuzz_crashers` | all 8 `tests/fuzz-crashers/` files are refused |
//! | 11 | `overlong_leb` | a wrong length prefix and an overlong LEB are refused; the well-formed counterpart loads |
//! | 12 | `load` | all 3 `two_change_chunks*` files load, and `ROOT.a.a == "b"` in each |
//! | 13 | `obj_id_64bits` | the out-of-range opId files are refused rather than silently truncating to `ROOT` |
//! | 16 | `authorship` | an author's footer is on its actor's first change only, and both directions of the author/actor tables round-trip through a save and load |
//! | 17 | `duplicate_seq_number_in_batch_change_aborts_whole_batch` | one bad `(actor, seq)` in a batch applies **none** of it |
//! | 18 | `duplicate_seq_number_within_incoming_batch_is_rejected` | a `(actor, seq)` repeated *inside* the batch is caught, and neither change lands |
//! | 19 | `duplicate_seq_number_changes_are_rejected` | a second change at an applied `(actor, seq)` is refused |
//! | 20 | `queued_orphan_with_conflicting_actor_seq_rejects_incoming_batch` | the rejection leaves the receiver exactly where the orphan left it |
//! | 22 | `incremental_load_preserves_text_encoding_for_all_change_chunk_types` | two of upstream's three chunk types; the bundle arm is recorded below |
//! | 23 | `queued_change_does_not_collide_with_later_local_change` | the rejected branch is dropped from the queue, so the next local change gets the sequence number back |
//!
//! And **ten cases with no `test` declaration**, each with the reason in place:
//! the four `PatchLogMismatch` cases (1 to 4), `bundle_with_mark_columns` (5),
//! `current_state_diff_with_block` (6 — the port cannot *build* the fixture, and
//! the gap says so), `doc_iter_spans_skip_losing_…` (7),
//! `save_and_load_incremented_counter` (9), `has_our_changes` (15),
//! `round_trip_change_with_extra_bytes` (21), and
//! `conflicting_unicode_text_with_different_widths` (14), which is inside a
//! `/* … */` block upstream and is therefore not a test at all.
//!
//! ## Rules this file keeps
//!
//! * **The leak arbiter is [`gpa`]**, and every owned value comes out of it:
//!  every document, every change list, every chunk buffer, every footer dup, and
//!  every hydrated mirror. Slices borrowed out of a document are asserted
//!  before the next write ([AGENTS.md](../AGENTS.md)).
//! * **Prose about a test goes inside the braces** as `//`, never above the
//!  declaration as `///` — Zig 0.16 analyses test declarations in a non-test
//!  build, so a `///` on a `test` takes the whole module down.
//! * **A test pins a property.** Where upstream asserts an error variant, this
//!  file asserts the error *and* the document state around it, because "it
//!  returned an error" is also what a document that refuses everything would
//!  answer. Where the port's error carries no payload where upstream's does,
//!  the payload assertion is replaced by the state assertion it protects, and
//!  the substitution is written down at the case.
//! * **Upstream's actors are random** ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
//!  and [`mintActor`] names them instead, the same way
//!  [`test/upstream_doc_test.zig`](upstream_doc_test.zig) does: distinct bytes, a
//!  stable order, and the same bytes on every run.

const std = @import("std");
const am = @import("zautomerge");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// **The leak arbiter for the whole file.** One allocator, named once.
const gpa = testing.allocator;

/// The borrowed capability every document constructor below is handed.
///
/// **Explicit, because `Document` keeps it.** The op set draws actors through
/// this value for as long as the document lives, so a constructor cannot
/// reach for an ambient global and no document can outlive its provider. Here
/// that value is `std.testing.io`; an executable passes its own `init.io`. It
/// reads `test/fixtures/` through it too, in [`fixture`].
const io = std.testing.io;

const Document = am.doc.Document;
const Change = am.change_record.Change;
const ExId = am.ExId;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ChangeHash = am.ChangeHash;
const ActorId = am.ActorId;
const TextEncoding = am.TextEncoding;
const Patch = am.patches.Patch;
const Patches = am.patches.Patches;
const Mirror = am.hydrate.Value;
const Tx = am.manual_transaction.Transaction;
const chunkmod = am.storage.chunk;
const changechunk = am.storage.change_chunk;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── Actors ───────────────────────────────────────────────────────────────────

/// Every actor this file mints, in its own static storage.
///
/// Upstream draws an actor at random ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and [`automerge_test::new_doc`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):11-15
/// draws a fresh one per document, which is right for a suite and wrong for a
/// failure nobody can reproduce. The bytes start at one so that no document
/// ever has an **empty** actor, which is a different value from every other one.
var minted_actors: [64][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] hands out. The bytes live in this file's static
/// storage, which is what lets an [`ActorId`] be a borrow: a document
/// **copies** the bytes when it interns the actor ([`doc.zig`](../src/doc.zig),
/// [`Document.insertActor`]).
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

/// The same, with the actor the caller names
/// ([`automerge_test::new_doc_with_actor`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):17-21).
fn newDocWithActor(actor: ActorId) !Document {
    var doc = try Document.init(gpa, io, .auto);
    errdefer doc.deinit();
    doc.setActorId(actor);
    return doc;
}

/// [`Document.fork`] through [`Document.forkAt`] at the document's own heads.
///
/// **A named actor, and not [`Document.fork`]'s random one.** `fork` mints
/// through the source's retained `io` ([`doc.zig`](../src/doc.zig)), so its
/// actor differs on every run and so does every change hash derived from it.
/// [`forkAt`] at the document's own heads is the same document with the same
/// contents. **And this is determinism, not a leak**: `fork` allocates the
/// actor from the **fork's own** arena, which [`Document.deinit`] frees with
/// everything else, so a fork it did not free is not the reason for this door.
fn forkDoc(src: *Document) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    return src.forkAt(gpa, heads, .auto);
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `prop`.
fn scalarAt(doc: *const Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The heads of `doc`. **The caller frees the result**
/// ([`Document.getHeads`](../src/doc.zig) returns a copy, because the graph's
/// own list moves under the next change).
fn headsOf(doc: *const Document) ![]ChangeHash {
    return doc.getHeads(gpa);
}

/// A one-element slice holding `hash`. The caller frees it.
fn oneOf(gpa_: Allocator, hash: ChangeHash) ![]ChangeHash {
    return gpa_.dupe(ChangeHash, &.{hash});
}

/// [`Document.getChanges`](../src/doc.zig)'s list as the `[]Change`
/// [`Document.applyChanges`](../src/doc.zig) takes. **The caller frees the
/// array**; the [`Change`] values borrow the list's bodies, which is why the
/// list has to outlive the apply.
fn changeViews(list: *const am.doc.Changes) ![]Change {
    const out = try gpa.alloc(Change, list.len());
    errdefer gpa.free(out);
    for (0..list.len()) |i| out[i] = list.at(i);
    return out;
}

/// Every change made since `have`, as a `[]Change`. **The caller frees the
/// array**; the [`Change`] values borrow `list`'s bodies, so `list` outlives
/// the answer and `list.deinit(gpa)` frees the bodies.
fn changesSince(doc: *Document, have: []const ChangeHash) !struct { list: am.doc.Changes, views: []Change } {
    var list = try doc.getChanges(gpa, have);
    errdefer list.deinit(gpa);
    const views = try changeViews(&list);
    return .{ .list = list, .views = views };
}

/// The materialized document at `heads`, or at the present when `heads` is
/// null: `Automerge::hydrate`. The port reaches the same mirror through
/// [`hydrate.hydrateMap`](../src/hydrate.zig), which takes the op set and an
/// optional clock rather than a document.
fn hydrateAt(doc: *Document, heads: ?[]const ChangeHash) !Mirror {
    if (heads) |h| {
        var clock = try doc.graph.clockAt(gpa, h);
        defer clock.deinit();
        return am.hydrate.hydrateMap(am.doc.Set, &doc.ops, gpa, root, clock);
    }
    return am.hydrate.hydrateMap(am.doc.Set, &doc.ops, gpa, root, null);
}

/// The materialized root at the present.
fn hydrateNow(doc: *Document) !Mirror {
    return hydrateAt(doc, null);
}

/// Applies a patch stream to a mirror and requires the whole stream to apply
/// ([`hydrate.rs`](../github-automerge-automerge/rust/automerge/src/hydrate.rs):78-87).
/// A refusal is a failure: upstream's is an `Err`, and a port that answered
/// "ignored" would make every patch-stream test pass on a stream of nothing.
fn applyPatches(mirror: *Mirror, enc: TextEncoding, patches: []const Patch) !void {
    switch (try mirror.applyPatches(enc, patches)) {
        .ok => {},
        .refused => |failure| {
            std.debug.print("\npatch stream refused: {s}\n", .{@tagName(failure)});
            return error.PatchStreamRefused;
        },
    }
}

// ── The fixture corpus ───────────────────────────────────────────────────────

/// The corpus, relative to the process working directory, which is the package
/// root for a build-run step ([`fixtures_test.zig`](fixtures_test.zig):16-17).
const fixture_dir = "test/fixtures";

/// Ceiling on one fixture. Upstream's largest is 406 bytes; a runaway file must
/// not be allowed to ask for memory.
const max_fixture_bytes = 1 << 20;

/// One corpus file's bytes. **The caller frees the result.**
fn fixture(name: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, name, gpa, .limited(max_fixture_bytes));
}

// ── A change's author footer ─────────────────────────────────────────────────

/// Upstream's [`Change::extra_bytes`](../../github-automerge-automerge/rust/automerge/src/change.rs):117-126
/// — "the bytes of this change which are not the operations".
///
/// **The port keeps the footer inside `Change.bytes`** ([`change.zig`](../src/change.zig):230-234)
/// rather than decoding it in the header parser. [`Built.body`](../src/doc.zig):474-476
/// is the chunk **body**, header included and framing excluded, so
/// [`parseChangeChunk`](../src/storage/change_chunk.zig):482 — which "opens with
/// `body`" — is the reader for it. That is the same read the C ABI's
/// `AMchangeExtraBytes` does ([`c/doc.zig`](../src/c/doc.zig):620-630), one
/// framing step earlier because that one holds a framed chunk.
///
/// **The caller frees the result.** `ChangeChunk.footer` borrows from
/// `built.body` and the parse's own two lists die with the `ChangeChunk`, so
/// the bytes are copied out rather than handed back as a borrow.
fn extraBytes(built: *const am.doc.Built) ![]u8 {
    var parsed = try changechunk.parseChangeChunk(built.body, gpa);
    defer parsed.deinit(gpa);
    return try gpa.dupe(u8, parsed.footer);
}

/// Two change-hash lists with the same members. **Elementwise, because
/// [`ChangeHash`] is a struct and Zig 0.16 refuses `==` on one**
/// ([AGENTS.md](../AGENTS.md): a 32-byte array has no operator to borrow).
fn sameHashes(a: []const ChangeHash, b: []const ChangeHash) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// `get_change_by_hash(..) == None`, **with the `!` checked**: a reader that
/// failed for some other reason is not a reader that found nothing, and
/// collapsing the two is how a "the change is absent" assertion becomes a test
/// that passes on a document that cannot answer at all.
fn hasNoChange(doc: *Document, hash: ChangeHash) !bool {
    var maybe = try doc.getChangeByHash(gpa, hash);
    defer if (maybe) |*b| b.deinit(gpa);
    return maybe == null;
}

/// Upstream's [`Change::author`](../../github-automerge-automerge/rust/automerge/src/change.rs):48-50
/// — the author its footer names, or none. **It returns an `Option` and cannot
/// fail**, and that signature is what this helper reproduces.
///
/// **The caller frees the result.**
///
/// ## A port deviation, in one line
///
/// Upstream's [`decode_author_footer`](../../github-automerge-automerge/rust/automerge/src/change.rs):395-403
/// reads `leb128::read::unsigned(&mut buff).ok()?` — **`.ok()?`**, so an empty
/// footer is `None`. The port's [`Document.decodeAuthorFooter`](../src/doc.zig):1646-1654
/// reads `try in.takeUleb()`, so an empty footer is `error.UnexpectedEnd`.
/// **An empty footer is the value the port's own encoder writes for an absent
/// author** — [`encodeAuthorFooter`](../src/doc.zig):1659-1664 returns without
/// appending anything when `author` is null, which is
/// [`encode_author_footer`](../../github-automerge-automerge/rust/automerge/src/change.rs):383-385's
/// `Cow::Borrowed(&[])` — so the decoder cannot decode what the encoder writes.
///
/// It is latent: both in-tree callers wrap the call in `catch null`
/// ([`Document.changeAuthor`](../src/doc.zig):2643-2645 and
/// [`Document.addToHistory`](../src/doc.zig):3701), which is upstream's answer,
/// so nothing observable is wrong today. **The one-line fix is
/// `in.takeUleb() catch return null` at [`doc.zig`](../src/doc.zig):1649**, and
/// it is recorded here rather than made because no production file is this
/// file's to change.
fn changeAuthor(gpa_: Allocator, built: *const am.doc.Built) !?[]const u8 {
    const bytes = try extraBytes(built);
    defer gpa_.free(bytes);
    // The empty footer is "no author" (`change.rs`:396), which is the arm this
    // file has to take by hand because the port's decoder raises on it.
    if (bytes.len == 0) return null;
    const named = (am.doc.decodeAuthorFooter(bytes) catch null) orelse return null;
    return try gpa_.dupe(u8, named);
}

/// Upstream's [`Automerge::get_authors`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):410-412
/// over [`Authors::get_authors`](../../github-automerge-automerge/rust/automerge/src/author.rs):54-57,
/// which is `&self.authors` — **a `Vec` kept in lexicographic order**,
/// because `Authors::put_author` finds an author with `binary_search` and
/// inserts at the slot it returns
/// ([`author.rs`:113-127](../../github-automerge-automerge/rust/automerge/src/author.rs):113-127).
///
/// The port has no author table: it keeps `Document.actor_authors`, one entry
/// per actor index
/// ([`doc.zig`](../src/doc.zig):2309-2312), and answers from that. **The
/// distinct author set sorted by bytes is upstream's `Vec` exactly**, and this
/// is where the order comes from rather than from the order actors happen to
/// be interned in.
///
/// **The caller frees the array.** The bytes are the document's own.
fn authorsOf(gpa_: Allocator, doc: *const Document) ![][]const u8 {
    const actors = try doc.getActors(gpa_);
    defer gpa_.free(actors);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa_);
    for (actors) |actor| {
        const have = doc.getAuthorForActor(actor) orelse continue;
        if (outContains(gpa_, out.items, have)) continue;
        try out.append(gpa_, have);
    }
    std.mem.sort([]const u8, out.items, {}, bytesLess);
    return out.toOwnedSlice(gpa_);
}

fn outContains(_: Allocator, have: []const []const u8, want: []const u8) bool {
    for (have) |h| {
        if (std.mem.eql(u8, h, want)) return true;
    }
    return false;
}

fn bytesLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── 1. applying_changes_with_patch_log_from_another_document_returns_error_not_panic
// ── 2. transaction_with_patch_log_from_another_document_does_not_panic
// ── 3. transaction_at_with_patch_log_from_another_document_does_not_panic
// ── 4. owned_transaction_with_patch_log_from_another_document_does_not_panic
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):37-80
//
// **None of the four is ported, and there are two independent reasons.**
//
// **The API.** Upstream's four need `apply_changes_log_patches`,
// `transaction_log_patches`, `transaction_at(patch_log, &heads)` and
// `into_transaction(Some(patch_log), None)` — four ways to hand a document a
// patch log that belongs to another document. This port has **one** document
// with **one** log ([`doc.zig`](../src/doc.zig), `Document.patch_log`), so a
// caller's `PatchLog` never reaches `applyChanges`: there is no
// `apply_changes_log_patches` to hand one in through and no
// `into_transaction(Some(log), None)` to carry one.
// [`error.PatchLogMismatch`](../src/error.zig) is declared and nothing raises
// it. The machinery a mismatch check would sit on is there —
// [`PatchLog.migrateActors`](../src/patches.zig) and
// [`PatchLog.finishTransaction`](../src/patches.zig) — and no caller.
//
// **The assertion, which settles it either way.** All four upstream cases
// assert only `matches!(result, Err(PatchLogMismatch(_)))` — "an error, not a
// panic". A document that refused every apply would answer that too, so
// transcribed literally the assertion pins no behaviour at all, and
// [AGENTS.md](../AGENTS.md)'s rule is that a test pins a property. Even with
// the API, these would need a state assertion around the refusal to be worth
// writing; with it, there is nothing to write.

// ── 5. bundle_with_mark_columns_decodes_from_fuzz_trace
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):134-152
//
// **Not ported: the port has no `Document.bundle`.** [`API.md`](../API.md)
// §Document does not list one and nothing implements it. The bundle *parser* is
// written ([`storage/bundle.zig`](../src/storage/bundle.zig), `Bundle`,
// `Builder`, `ChangeIter`, `OpIter`), but no walk turns a document's op set
// into the `BundleChange` / `BundleOp` stream the `Builder` consumes — the
// same gap [`doc.zig`](../src/doc.zig)'s module header records for a bundle as
// a document's first chunk (`doc.zig`:2938-2960).
//
// The property it pins is the mark columns' **normalized order** in the bundle
// metadata, which is a property of the encoder this port has not written. The
// mark itself *is* exercised: `test/upstream_doc_test.zig`'s case 23
// (`diff_spans_preserve_marks_on_inserted_text`) and case 81
// (`get_marks_at_heads`) both write marks and read their names and spans back.

// ── 6. current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):420-447
//
// **Not ported: the port cannot build the fixture, and the reason is the
// write side rather than the read side.** Upstream writes the block with
//
// ```rust
// doc.update_spans(&text, UpdateSpansConfig::default(),
//     [Span::Block(hydrate_map! { "type" => "paragraph" })])
// ```
//
// so the block arrives **with contents**. The port's [`Span`](../src/iter/spans.zig):491-502
// carries `.block` as a bare `ExId` — "Upstream's payload is a hydrated map;
// the id is the row's own" — and [`transact.updateSpans`](../src/transact.zig):2417
// therefore cannot name what goes inside a block it creates. The only block a
// caller can create is [`splitBlock`](../src/transact.zig):2346, which is empty,
// and an empty block makes the "ignore its nested contents" half of the case
// vacuous.
//
// **This is not the gap the previous round recorded.** That was "the port's
// `Span.block` is an `ExId` and carries no map", which is the *read* side and is
// true. The read side is in fact fine: [`Value.applyOne`](../src/hydrate.zig):560-563
// already treats a text-indexed path step as a no-op, which is upstream's
// `hydrate.rs:107` verbatim, so a patch into a block's contents is ignored
// rather than refused. **The write side is what is missing**, and the fix is a
// `Span.block` that carries a hydrated map.

// ── 7. doc_iter_spans_skip_losing_conflicting_text_overwrites_after_object_shift
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):722-755
//
// **Not ported: there is no document-level `iter()`.** The property is that
// `DocIter`, which **reuses one `SpansDiff` while shifting between objects**,
// does not reuse the root object's fast all-top path for a conflicted text
// object it reaches later. That is a property of the iterator's own state
// machine, so a traversal written in the test would test the test: the port has
// [`iter.doc.Doc`](../src/iter/doc.zig) and [`iter.doc.DiffIter`](../src/iter/doc.zig),
// which are the `OpSet`-generic machinery a document-level `DocItem` walk would
// be built on, and no `Document`-level entry that produces upstream's
// `DocItem`. The conflicting-text half is covered instead by
// `test/upstream_doc_test.zig`'s case 21 (`spans_match_text_after_…`): it
// asserts the visible spans of a merged conflicting overwrite equal
// [`Document.text`](../src/doc.zig), which is the same top-op filtering this
// case is about, reached through the per-object reader.

// ── 8. test_compressed_changes
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2030-2044

test "a deflated change chunk decodes to the same change bytes and the same hash" {
    var doc = try newDoc();
    defer doc.deinit();
    // `crate::storage::DEFLATE_MIN_SIZE` is 250 upstream, so this is what makes
    // `Change::bytes()` compress the change at all (`test.rs`:2033-2035).
    const payload = try gpa.alloc(u8, 300);
    defer gpa.free(payload);
    @memset(payload, 10);
    _ = try am.transaction.put(&doc, root, .{ .key = "bytes" }, .{ .bytes = payload });

    var maybe = try doc.getLastLocalChange(gpa);
    defer if (maybe) |*b| b.deinit(gpa);
    const built = &(maybe orelse return error.NoLocalChange);

    // `Change::raw_bytes`: the whole framed chunk. [`Built.body`](../src/doc.zig):474-476
    // is the same bytes with the framing stripped, so the framing goes back on
    // with [`chunk.writeChunk`](../src/storage/chunk.zig):111-123 — which is
    // exactly what the C ABI's `ownedChangeValue` does
    // ([`c/doc.zig`](../src/c/doc.zig):502-508).
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try chunkmod.writeChunk(&raw, gpa, .change, built.body);
    const uncompressed = raw.items;
    try testing.expect(uncompressed.len > 256);

    // `Change::bytes` is `&mut self` and materialises the deflated body
    // ([`change.rs`](../github-automerge-automerge/rust/automerge/src/change.rs):98-103),
    // reaching `StoredChange::compress`
    // ([`storage/change.rs`](../github-automerge-automerge/rust/automerge/src/storage/change.rs):295-301)
    // — `chunk.compressChunk` is that, and it writes the whole framed
    // `ChunkType.compressed` chunk ([`chunk.zig`](../src/storage/chunk.zig):131-145).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try chunkmod.compressChunk(&out, gpa, built.body);
    const compressed = out.items;
    try testing.expect(compressed.len < uncompressed.len);

    // `Change::try_from(&compressed[..])`, which inflates and re-parses. The
    // pin is the **bytes**, not the length: the inflated body must be the
    // original body, and the hash must be the original change's — which is
    // stronger than upstream's `assert_eq!(raw_bytes, raw_bytes)`, because the
    // hash is `SHA-256` over those bytes and a body that differed could not
    // keep it.
    const framed = try chunkmod.parseChunk(compressed);
    try testing.expectEqual(chunkmod.ChunkType.compressed, framed.typ);
    var owned = try changechunk.parseFramedChunk(framed, gpa);
    defer owned.deinit(gpa);
    const inflated = owned.inflated orelse return error.BodyWasNotInflated;
    try testing.expectEqualSlices(u8, built.body, inflated);
    try testing.expect(owned.parsed.change.hash.eql(built.change.hash));
}

// ── 9. save_and_load_incremented_counter
//    [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2097-2115
//
// **Not ported: no `ExpandedChange`.** The case serializes each change to JSON
// with `serde_json`, reads it back into an `ExpandedChange`, converts that into
// a `Change` and requires the two change lists to be equal
// (`test.rs`:2104-2114). The port's [`autoserde.zig`](../src/autoserde.zig)
// serializes a **document**, not a change: its one entry point is
// `AutoSerde.serialize`, and there is no `ExpandedChange` type and no reader
// for one. The count this case turns on — a counter value survives the
// expanded representation — is checked here instead as the property it is
// about: `test/upstream_doc_test.zig`'s case 54 (`list_counter_del`) and case
// 58 (`test_local_inc_in_map`) both read counter values back out of a document
// that was incremented, and `test/example_test.zig` round-trips a document
// through `save`/`load`.

// ── 10. fuzz_crashers
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2209-2220

test "every upstream fuzz crasher is refused, and the refusal names the file" {
    // Upstream reads the directory and asserts `Automerge::load(&bytes).is_err()`
    // for whatever is in it (`test.rs`:2211-2219`). **The file names are
    // written down here** rather than read from a directory, for two reasons:
    // the corpus is flat and merged with nine wire-format fixtures
    // ([`fixtures_test.zig`](fixtures_test.zig):31-44 already names the eight
    // separately, "so that flipping a `load_err` to `load_ok` fails here"), and
    // a name in a list is an assertion a reader can check, where a directory
    // entry is not.
    const crashers = [_][]const u8{
        "action-is-48.automerge",
        "crash-da39a3ee5e6b4b0d3255bfef95601890afd80709",
        "incorrect_max_op.automerge",
        "invalid_deflate_stream.automerge",
        "missing_actor.automerge",
        "overflow_in_length.automerge",
        "too_many_deps.automerge",
        "too_many_ops.automerge",
    };
    for (crashers) |name| {
        const bytes = fixture(name) catch |e| {
            std.debug.print("\nfixture {s}: {s}\n", .{ name, @errorName(e) });
            return e;
        };
        defer gpa.free(bytes);
        try mustBeRefused(name, bytes);
    }
}
/// **Loads `bytes` and requires the load to be refused, naming the file on
/// success.** Upstream says this three times over four lines with
/// `assert!(Automerge::load(..).is_err())`, and a Zig error union that returns
/// a document has to be captured by value rather than by pointer.
fn mustBeRefused(name: []const u8, bytes: []const u8) !void {
    const outcome = Document.load(gpa, io, bytes, .unicode_code_point, .auto);
    if (outcome) |document_value| {
        var document = document_value;
        document.deinit();
        std.debug.print("\n{s} loaded; it must be refused\n", .{name});
        return error.MustBeRefused;
    } else |_| {}
}

// ── 11. overlong_leb
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2226-2234

test "a wrong length prefix and an overlong LEB are refused, and the well-formed one loads" {
    // "the value metadata says 2, but the LEB is only 1-byte long and there's
    // an extra 0" (`test.rs`:2228-2229), and "the LEB is overlong (using 2
    // bytes where one would have sufficed)" (`test.rs`:2230-2231). **Two files,
    // two different malformations**, so both are named; they are read through
    // the loop below rather than into locals here, because a local read the
    // test then ignores is a file it claims to have checked and did not.
    // The third case is what makes the first two mean anything: a reader that
    // refused all three would pass the first two. **The value is read back
    // out** rather than the load merely being allowed, so this is a decode and
    // not a "did not refuse" — and the value is not guessed. Upstream reads
    // this same fixture in [`current_state.rs`:536-541](../github-automerge-automerge/rust/automerge/src/automerge/current_state.rs):536-541,
    // where `make_patches` over a fresh active log must yield **one** patch:
    // `Put { obj: ROOT, prop: "a", value: Counter(2000), conflict: false }`.
    // So the key is `a`, not `counter`, and the counter reads 2000.
    const malformed = [_][]const u8{
        "counter_value_has_incorrect_meta.automerge",
        "counter_value_is_overlong.automerge",
    };
    // "the LEB is correct" (`test.rs`:2232-2233).
    const ok = try fixture("counter_value_is_ok.automerge");
    defer gpa.free(ok);

    for (malformed) |name| {
        const bytes = try fixture(name);
        defer gpa.free(bytes);
        try mustBeRefused(name, bytes);
    }

    var loaded = try Document.load(gpa, io, ok, .unicode_code_point, .auto);
    defer loaded.deinit();
    const counter = try scalarAt(&loaded, root, .{ .key = "a" });
    try testing.expectEqual(@as(i64, 2000), counter.counter.current);
}

// ── 12. load
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2236-2247

test "each two-change-chunk fixture loads and holds ROOT.a.a == \"b\"" {
    // Upstream's `check_fixture` is two lines and asserts one value
    // (`test.rs`:2238-2242`): the object at `ROOT.a` is an object, and that
    // object's key `a` is the string `"b"`. **Both are asserted here**, and the
    // first is a real check rather than an `unwrap`: the port's
    // `read.get` returns `null` for a missing key and the upstream `.1` is the
    // object id, so a fixture that loaded into an *empty* root would answer
    // `null` rather than naming an object.
    const names = [_][]const u8{
        "two_change_chunks.automerge",
        "two_change_chunks_compressed.automerge",
        "two_change_chunks_out_of_order.automerge",
    };
    for (names) |name| {
        const bytes = try fixture(name);
        defer gpa.free(bytes);
        var loaded = try Document.load(gpa, io, bytes, .unicode_code_point, .auto);
        defer loaded.deinit();

        const outer = (try am.read.get(&loaded, root, .{ .key = "a" })) orelse {
            std.debug.print("\n{s}: ROOT.a is absent\n", .{name});
            return error.NoSuchKey;
        };
        const map_id = switch (outer.value) {
            .object => |t| blk: {
                if (t != .map and t != .table) {
                    std.debug.print("\n{s}: ROOT.a is a {t}, not a map\n", .{ name, t });
                    return error.NotAMap;
                }
                break :blk outer.id;
            },
            .scalar => return error.NotAnObject,
        };
        try testing.expect(map_id.eql(outer.id));
        // The one that is not the root: `ROOT.a` must name a real object, or the
        // two assertions below would be reading the root map twice.
        try testing.expect(!map_id.eql(root));

        const inner = (try am.read.get(&loaded, map_id, .{ .key = "a" })) orelse {
            std.debug.print("\n{s}: ROOT.a.a is absent\n", .{name});
            return error.NoSuchKey;
        };
        switch (inner.value) {
            .scalar => |s| switch (s) {
                .str => |text| try testing.expectEqualStrings("b", text),
                else => return error.NotAString,
            },
            .object => return error.NotAScalar,
        }
    }
}

// ── 13. obj_id_64bits
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2255-2269

test "an opId of 2^42 never truncates to the document root" {
    // "this change has an opId of 2**42, which when cast to a 32-bit int gives
    // 0" (`test.rs`:2257-2258`). Upstream accepts **either** outcome — a load
    // error, or a load in which `ROOT.a` is an object rather than the root —
    // so `if let Ok(doc)` guards both. The dangerous third answer, a load in
    // which the counter has become 0 and `ROOT.a` *is* the root, is what the
    // assertion rules out, and that is the property worth pinning: **the test
    // is about the id, not about the load**.
    //
    // The port refuses both files (`manifest.zig`'s `expect` column says
    // `load_err` for both, with the reference's own refusal as the reason), so
    // the load-error arm is what runs. Both arms are written out anyway: an
    // `if let Ok` that asserted nothing when the load failed would be a test
    // that passes on a loader that refuses everything.
    const names = [_][]const u8{
        "64bit_obj_id_change.automerge",
        "64bit_obj_id_doc.automerge",
    };
    for (names) |name| {
        const bytes = try fixture(name);
        defer gpa.free(bytes);
        var loaded = (Document.load(gpa, io, bytes, .unicode_code_point, .auto)) catch |e| {
            // Arm one: refused, which upstream accepts.
            if (e == error.OutOfMemory) return e;
            continue;
        };
        defer loaded.deinit();
        // Arm two: loaded, so `ROOT.a` must be an object that is not the root.
        const item = (try am.read.get(&loaded, root, .{ .key = "a" })) orelse return error.NoSuchKey;
        const map_id = switch (item.value) {
            .object => item.id,
            .scalar => return error.NotAnObject,
        };
        if (map_id.eql(root)) {
            std.debug.print("\n{s}: ROOT.a resolved to the root\n", .{name});
            return error.ObjIdTruncatedToRoot;
        }
    }
}

// ── 14. conflicting_unicode_text_with_different_widths
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2715-2744
//
// **Not ported, and the reason is upstream's own file: the whole case is inside
// a `/* … */` block.** `test.rs`:2715 opens `/*`, `#[test]` is at `:2716` and
// `fn conflicting_unicode_text_with_different_widths` at `:2717`, and `:2744`
// closes it. **`cargo test` does not run it**, and [AGENTS.md](../AGENTS.md)
// says "do not port upstream dead code".
//
// It is worth recording *why* it is worth nothing, because a name-only diff
// against `#[test]` lines counts it as a live case and then reports a phantom
// gap: the last `/* … */` in the file is this one, so **it is the only reason
// upstream has 140 `#[test]` lines and 139 running cases**. The case itself is a
// `length`/`get` walk over a text object whose index 1 is concurrently `"B"` and
// a bear; the parts it pins are covered by
// `test/upstream_doc_test.zig`'s case 21 (`spans_match_text_after_…`), case 23
// and case 24 (`diff_spans_…`).

// ── 15. has_our_changes
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3074-3108
//
// **Not ported: the port has no `has_our_changes`.** It is a `SyncDoc` method
// (`test.rs`:3085-3107) and this port has no `SyncDoc`: the four sync entry
// points are free functions taking the document and the state
// ([API.md](../API.md) §Sync), because the v1 path is a second pair of the same
// two names in another module. Nothing in `src/sync/` answers "is the peer up
// to date with my heads", and the sync loop it drives would need it.
//
// What the case is actually about — **two peers reach the same state through
/// an exchange of sync messages** — is reachable, and `test/upstream_doc_test.zig`'s
// case 124 (`queued_orphan_need_does_not_block_unrelated_sync_response`)
// exercises a round of it. The termination condition is the missing piece: this
// file could write the `while !has_our_changes { … }` loop with a proxy for the
// predicate (`state.sentHeads ⊇ doc heads`), and a proxy for the thing being
// tested is the definition of a test that pins nothing.

// ── 16. authorship
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3460-3527
//
// ## This test fails on the port, and the failure is a real defect
//
// **It is left failing on purpose.** The diagnosis, with the evidence:
//
// Every per-change assertion passes: the footer is `[1, 3, 1, 1, 1]` on the
// actor's first change, absent on its second, and `[1, 3, 2, 2, 2]` on the
// other document's. What fails is [`expectAuthors`] — **the author table has
// lost one of its two authors**, so `get_authors()` answers one where upstream
// answers two (`test.rs`:3496-3497).
//
// Reduced to four lines: after the author-1 change (seq 1),
// `get_actors_for_author(author1)` returns one actor; after the seq-2 change,
// which carries **no footer at all**, it returns **none**. The author is
// *erased* by the change that does not mention it.
//
// **The cause is an assignment where upstream has a conditional.**
// Upstream's graph adds an author only when the change carries one:
//
// ```rust
// if let Some(author) = change.author() {
//     assert!(change.seq() == 1);
//     authors.assign_author(author.into_owned(), actor)
// }
// ```
//
// ([`change_graph.rs`:563-566](../github-automerge-automerge/rust/automerge/src/change_graph.rs)). The `assert!`
// is the other half of the story: an author footer is only ever legal on an
// actor's first change, so a change that names no author is not evidence that
// the actor has none. [`Authors::assign_author`](../github-automerge-automerge/rust/automerge/src/author.rs):88-91
// only ever writes `Some`, and the sole writer of `None` upstream is
// `Authors::remove_actor` ([`:104-106`](../github-automerge-automerge/rust/automerge/src/author.rs)), which
// fires on an actor leaving the table.
//
// **The port assigns unconditionally, on both of its paths:**
//
// * [`doc.zig`](../src/doc.zig):3921-3924 — the local-commit path:
//   `self.actor_authors.items[args.actor_index] = args.author;`, and
//   `TransactionArgs.author` is `if (seq == 1) self.author else null`
//   ([`doc.zig`](../src/doc.zig):2761). So **every change after an actor's
//   first clears that actor's author**.
// * [`doc.zig`](../src/doc.zig):3698-3703 — the apply path:
//   `self.actor_authors.items[i] = decodeAuthorFooter(self.changeFooterOf(filled)) catch null;`,
//   which clears for the same reason and additionally in a loop over **every**
//   node, so the order of the graph's nodes decides which author survives.
//
// **The fix is a conditional at both sites**, matching `change_graph.rs:563`:
// assign when the footer names an author, and leave the slot alone otherwise.
// No production file is this file's to change, so the test stands as written.
//
// Note that the save/load half ([`expectAuthors`]'s second call, on `doc3`)
// **would fail for the same reason and not another**: the load reads footers
// through the same assignment at [`doc.zig`](../src/doc.zig):3701, so it
// inherits the defect rather than compounding it.

/// The three facts [`authorship`] reads off one change. Every owned piece is
/// freed by [`ChangeFacts.deinit`], because [`extraBytes`] has to copy: the
/// footer it reads borrows from a `ChangeChunk` that dies with the call.
const ChangeFacts = struct {
    seq: u64,
    extra: []u8,
    author: ?[]const u8,

    fn deinit(self: *ChangeFacts, gpa_: Allocator) void {
        gpa_.free(self.extra);
        if (self.author) |a| gpa_.free(a);
        self.* = undefined;
    }
};

/// `get_last_local_change`, read for the three fields `authorship` asserts.
fn lastLocalFacts(doc: *Document) !ChangeFacts {
    var maybe = try doc.getLastLocalChange(gpa);
    defer if (maybe) |*b| b.deinit(gpa);
    const built = &(maybe orelse return error.NoLocalChange);
    return .{
        .seq = built.change.seq,
        .extra = try extraBytes(built),
        .author = try changeAuthor(gpa, built),
    };
}

test "an author's footer rides only its actor's first change, and both directions of the author table round-trip" {
    // Upstream's two authors, as bytes: `Author::from(vec![1,1,1])` and
    // `Author::from(vec![2,2,2])` (`test.rs`:3462-3463). **The port's author is
    // `[]const u8`**, so `Author` is the byte string rather than a newtype over
    // it, and every comparison below is a byte comparison — which is what
    // `Author`'s `Ord` is anyway (`author.rs`:140-141).
    const author1 = "\x01\x01\x01";
    const author2 = "\x02\x02\x02";

    var doc1 = try newDoc();
    defer doc1.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value1" });
    // `assert_eq!(change.seq(), 1); assert_eq!(change.author(), None);
    //  assert!(change.extra_bytes().is_empty());` (`test.rs`:3466-3469`)
    {
        var f = try lastLocalFacts(&doc1);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), f.seq);
        try testing.expectEqualSlices(u8, &.{}, f.extra);
        try testing.expect(f.author == null);
    }

    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();

    // **A change of author mints a new actor** ([`automerge.rs`:389-396](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // which is why both documents' next change is `seq` 1 again and why the two
    // `(actor, seq)` pairs do not collide on merge.
    try doc1.setAuthor(gpa, author1);
    try doc2.setAuthor(gpa, author2);

    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value2" });
    // `seq() == 1`, `author() == Some(author1)` and
    // `extra_bytes() == &[1, 3, 1, 1, 1]` (`test.rs`:3477-3480`).
    //
    // **The three bytes are derived, not copied.** The footer is
    // `uleb128(Footer::Author) ‖ uleb128(len) ‖ bytes`
    // ([`encode_author_footer`](../github-automerge-automerge/rust/automerge/src/change.rs):376-386),
    // `Footer::Author` is `1` ([`:365-368`](../github-automerge-automerge/rust/automerge/src/change.rs)) and the author is three
    // bytes long, so the footer is `[1, 3, 1, 1, 1]`.
    {
        var f = try lastLocalFacts(&doc1);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), f.seq);
        try testing.expectEqualSlices(u8, &.{ 1, 3, 1, 1, 1 }, f.extra);
        try testing.expectEqualStrings(author1, f.author orelse return error.NoAuthor);
    }

    // **The second change by the same actor carries no footer at all**: the
    // author is stamped only on an actor's *first* change
    // ([`automerge.rs`:568](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // because one actor has one author. `test.rs`:3482-3486.
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value3" });
    {
        var f = try lastLocalFacts(&doc1);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(u64, 2), f.seq);
        try testing.expectEqualSlices(u8, &.{}, f.extra);
        try testing.expect(f.author == null);
    }

    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "value4" });
    // `test.rs`:3489-3492`: `seq` 1, `author2`, `[1, 3, 2, 2, 2]`.
    {
        var f = try lastLocalFacts(&doc2);
        defer f.deinit(gpa);
        try testing.expectEqual(@as(u64, 1), f.seq);
        try testing.expectEqualSlices(u8, &.{ 1, 3, 2, 2, 2 }, f.extra);
        try testing.expectEqualStrings(author2, f.author orelse return error.NoAuthor);
    }

    const merged = try doc1.merge(gpa, &doc2);
    gpa.free(merged);

    const before = try expectAuthors(&doc1, author1, author2);

    // "the same table after a save/load, which rebuilds it from the footers"
    // (`test.rs`:3511-3526`).
    const saved = try doc1.save(gpa);
    defer gpa.free(saved);
    var doc3 = try Document.load(gpa, io, saved, .unicode_code_point, .auto);
    defer doc3.deinit();
    const after = try expectAuthors(&doc3, author1, author2);

    // **The round trip is a round trip, and this is the half upstream leaves
    // out.** Upstream reloads and re-asks the same three questions
    // (`test.rs`:3513-3526`), which two *independent* self-consistent tables
    // would pass: a load that built the table from the wrong rows, or rebuilt
    // it from scratch rather than from the footers, would answer the same way
    // on both documents. Comparing the actor ids the two tables map the two
    // authors to is what says the saved bytes named the same actors, which is
    // the property a rebuilt-from-the-wrong-row table cannot hold.
    try testing.expect(before.first.eql(after.first));
    try testing.expect(before.second.eql(after.second));
}

/// The actor each author maps to, so a caller can hold one document's answer
/// against another's.
const AuthorActors = struct { first: ActorId, second: ActorId };

/// `get_authors()` == `[author1, author2]`, and both directions of the actor
/// and author tables agree — `test.rs`:3496-3509` and again at `:3513-3526`.
///
/// **Both directions are asserted, because one alone proves little**: a table
/// that answered `get_author_for_actor` from `get_actors_for_author` and not the
/// other way round would pass the first and fail the second, and a table that
/// answered both from nothing would fail both.
///
/// **The set is asserted by name, and not as a count.** A count passes on a
/// table holding two rows when one of them is the wrong row, and it reports a
/// loss without saying which author was lost — and the port's failure was a
/// *loss*: [`authorsOf`] skips an actor with no author, so a slot an actor's
/// second change had emptied dropped that actor's author out of the set
/// entirely rather than adding a duplicate. Each expected author is therefore
/// looked up on its own, and the diagnostic names the one that is absent
/// rather than printing two lists of three bytes nobody can read.
fn expectAuthors(doc: *const Document, author1: []const u8, author2: []const u8) !AuthorActors {
    const authors = try authorsOf(gpa, doc);
    defer gpa.free(authors);
    const want = [_][]const u8{ author1, author2 };
    for (want) |name| {
        if (outContains(gpa, authors, name)) continue;
        std.debug.print("\nget_authors() is missing {x}; it holds", .{name});
        for (authors) |have| std.debug.print(" {x}", .{have});
        std.debug.print("\n", .{});
        return error.AuthorTableLostAnAuthor;
    }
    // **And nothing beyond the two.** Membership alone would pass a table
    // carrying a third name, and `authorsOf` deduplicates, so the length is a
    // statement about rows rather than about actors.
    try testing.expectEqual(want.len, authors.len);
    // `authorsOf` sorts by bytes, which is upstream's sorted `Vec`
    // (`author.rs:113-127`), so the order is part of what is asserted.
    try testing.expectEqualSlices(u8, author1, authors[0]);
    try testing.expectEqualSlices(u8, author2, authors[1]);

    const actors1 = try doc.getActorForAuthor(gpa, author1);
    defer gpa.free(actors1);
    const actors2 = try doc.getActorForAuthor(gpa, author2);
    defer gpa.free(actors2);
    try testing.expectEqual(@as(usize, 1), actors1.len);
    try testing.expectEqual(@as(usize, 1), actors2.len);

    // The two actors must be *different*, or the table has one row for both
    // authors and the counts above are counting the same actor twice.
    try testing.expect(!actors1[0].eql(actors2[0]));
    try testing.expectEqualSlices(
        u8,
        author1,
        doc.getAuthorForActor(actors1[0]) orelse return error.NoAuthor,
    );
    try testing.expectEqualSlices(
        u8,
        author2,
        doc.getAuthorForActor(actors2[0]) orelse return error.NoAuthor,
    );
    return .{ .first = actors1[0], .second = actors2[0] };
}

// ── 17. duplicate_seq_number_in_batch_change_aborts_whole_batch
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3558-3597

test "one conflicting (actor, seq) in a batch applies none of the batch" {
    // Upstream reaches this through `apply_changes_batch`
    // (`test.rs`:3585` and `:3591`), which the port does not name.
    // [`Document.applyChanges`](../src/doc.zig) **is** it: the port's own
    // [`applyChangesBatch`](../src/opset/batch.zig):2417-2431 is documented as
    // "a merge nobody is watching" and names `automerge.rs:1097-1112` as the
    // route that gets there — so the screen runs the same code in both, and
    // the error is raised from the same two places
    // ([`batch.zig`](../src/opset/batch.zig):2356-2362).
    var base = try newDoc();
    defer base.deinit();
    _ = try am.transaction.put(&base, root, .{ .key = "foo" }, .{ .str = "bar" });
    const base_heads = try headsOf(&base);
    defer gpa.free(base_heads);

    // `middle` forks and writes, so its change is `(M, 1)` with `base`'s heads
    // as dependencies — causally ready, and by an actor of its own.
    //
    // **`seq` 1, not 2, and the first draft of this test said 2.** A fork
    // *mints a new actor id* ([`fork_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):
    // `fork.set_actor(ActorId::random())`), so a forked document's next change
    // is its own actor's first — and the port's [`Document.forkAt`](../src/doc.zig)
    // does the same. Nothing in the case depends on the number; what it needs
    // is that `change1` and `change2` are by *different* actors, so `change1`
    // is causally ready while `change3` collides.
    var middle = try forkDoc(&base);
    defer middle.deinit();
    _ = try am.transaction.put(&middle, root, .{ .key = "foo" }, .{ .str = "baz" });
    var middle_one = try changesSince(&middle, base_heads);
    defer middle_one.list.deinit(gpa);
    defer gpa.free(middle_one.views);
    try testing.expectEqual(@as(usize, 1), middle_one.list.len());
    const change1 = middle_one.list.at(0);
    try testing.expectEqual(@as(u64, 1), change1.seq);
    try testing.expectEqual(@as(usize, 1), base_heads.len);
    // A different actor from `base`'s, which is what the fork minted.
    try testing.expect(!change1.actor.eql(base.getActorId()));

    // `left` writes under the name `aaaaaa`, so its change is `(aaaaaa, 1)`.
    var left = try forkDoc(&base);
    defer left.deinit();
    left.setActorId(.{ .bytes = "aaaaaa" });
    _ = try am.transaction.put(&left, root, .{ .key = "foo" }, .{ .str = "qux" });
    var left_one = try changesSince(&left, base_heads);
    defer left_one.list.deinit(gpa);
    defer gpa.free(left_one.views);
    try testing.expectEqual(@as(usize, 1), left_one.list.len());
    const change2 = left_one.list.at(0);
    try testing.expectEqual(@as(u64, 1), change2.seq);
    try testing.expectEqualStrings("aaaaaa", change2.actor.bytes);

    // `right` forks `middle` and writes **as the same actor `aaaaaa`**, so its
    // change is a *different* change at the *same* `(actor, seq)`. That is the
    // collision.
    var right = try forkDoc(&middle);
    defer right.deinit();
    right.setActorId(.{ .bytes = "aaaaaa" });
    _ = try am.transaction.put(&right, root, .{ .key = "foo" }, .{ .str = "boz" });
    const middle_heads = try headsOf(&middle);
    defer gpa.free(middle_heads);
    var right_one = try changesSince(&right, middle_heads);
    defer right_one.list.deinit(gpa);
    defer gpa.free(right_one.views);
    try testing.expectEqual(@as(usize, 1), right_one.list.len());
    const change3 = right_one.list.at(0);
    try testing.expectEqual(@as(u64, 1), change3.seq);
    // A different change at the same slot, which is what makes this a
    // *duplicate* and not a repeat: upstream asserts nothing here, but the
    // refusal is only meaningful if the two hashes differ.
    try testing.expect(!change3.hash.eql(change2.hash));

    // "First apply the left change." (`test.rs`:3584-3585`)
    const applied = try base.applyChanges(gpa, &.{change2});
    try testing.expectEqual(@as(usize, 1), applied);

    // "Now apply a causally ready change together with a change whose actor/seq
    // conflicts" (`test.rs`:3587-3589`).
    try testing.expectError(
        error.DuplicateSeqNumber,
        base.applyChanges(gpa, &.{ change1, change3 }),
    );

    // "Because the batch apply failed the document should not have change1
    // applied" (`test.rs`:3595-3596`). **The value is asserted as well as the
    // hash**, because a refusal that also dropped the ops would satisfy the
    // hash check alone: `foo` must still read `"qux"`, the value `change2`
    // wrote, and `"baz"` must never have been applied.
    try testing.expect(try hasNoChange(&base, change1.hash));
    try testing.expect(try hasNoChange(&base, change3.hash));
    try testing.expectEqualStrings("qux", (try scalarAt(&base, root, .{ .key = "foo" })).str);
}

// ── 18. duplicate_seq_number_within_incoming_batch_is_rejected
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3599-3632

test "a (actor, seq) repeated inside one batch is refused, and neither change lands" {
    // Upstream matches the error against `DuplicateSeqNumber(1, duplicate_actor)`
    // and then asserts `duplicate_actor == actor` (`test.rs`:3621-3626`).
    // **The port's error carries no payload** —
    // [`error.DuplicateSeqNumber`](../src/opset/batch.zig):2358-2361 is a bare
    // tag where upstream's is `DuplicateSeqNumber(u64, ActorId)`
    // ([`error.rs`](../github-automerge-automerge/rust/automerge/src/error.rs)) — so the payload assertion is
    // replaced by the one it protects: neither change may land, and neither
    // key may exist. A screen that refused the batch for an unrelated reason
    // would also pass the payload check upstream; this one cannot.
    var base = try newDoc();
    defer base.deinit();
    _ = try am.transaction.put(&base, root, .{ .key = "foo" }, .{ .str = "bar" });
    const base_heads = try headsOf(&base);
    defer gpa.free(base_heads);

    const actor: ActorId = .{ .bytes = "aaaaaa" };
    var left = try forkDoc(&base);
    defer left.deinit();
    left.setActorId(actor);
    _ = try am.transaction.put(&left, root, .{ .key = "left" }, .{ .int = 1 });
    var left_one = try changesSince(&left, base_heads);
    defer left_one.list.deinit(gpa);
    defer gpa.free(left_one.views);
    try testing.expectEqual(@as(usize, 1), left_one.list.len());
    const change1 = left_one.list.at(0);

    var right = try forkDoc(&base);
    defer right.deinit();
    right.setActorId(actor);
    _ = try am.transaction.put(&right, root, .{ .key = "right" }, .{ .int = 2 });
    var right_one = try changesSince(&right, base_heads);
    defer right_one.list.deinit(gpa);
    defer gpa.free(right_one.views);
    try testing.expectEqual(@as(usize, 1), right_one.list.len());
    const change2 = right_one.list.at(0);

    // "assert_ne!(change1.hash(), change2.hash())" (`test.rs`:3620`): the two
    // are distinct changes that both claim `(aaaaaa, 1)`.
    try testing.expect(!change1.hash.eql(change2.hash));
    try testing.expectEqual(change1.seq, change2.seq);
    try testing.expect(change1.actor.eql(change2.actor));

    try testing.expectError(
        error.DuplicateSeqNumber,
        base.applyChanges(gpa, &.{ change1, change2 }),
    );

    // `test.rs`:3628-3631`: neither change, and neither key.
    try testing.expect(try hasNoChange(&base, change1.hash));
    try testing.expect(try hasNoChange(&base, change2.hash));
    try testing.expect((try am.read.get(&base, root, .{ .key = "left" })) == null);
    try testing.expect((try am.read.get(&base, root, .{ .key = "right" })) == null);
    // The batch left nothing behind either: `foo` is still the only key, and
    // `base`'s own heads are unchanged.
    try testing.expectEqualStrings("bar", (try scalarAt(&base, root, .{ .key = "foo" })).str);
    const heads_after = try headsOf(&base);
    defer gpa.free(heads_after);
    try testing.expectEqualSlices(ChangeHash, base_heads, heads_after);
}

// ── 19. duplicate_seq_number_changes_are_rejected
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3634-3661

test "a second change at an already-applied (actor, seq) is refused" {
    var base = try newDoc();
    defer base.deinit();
    _ = try am.transaction.put(&base, root, .{ .key = "foo" }, .{ .str = "bar" });
    const base_heads = try headsOf(&base);
    defer gpa.free(base_heads);

    var left = try forkDoc(&base);
    defer left.deinit();
    left.setActorId(.{ .bytes = "aaaaaa" });
    _ = try am.transaction.put(&left, root, .{ .key = "foo" }, .{ .str = "qux" });
    var left_one = try changesSince(&left, base_heads);
    defer left_one.list.deinit(gpa);
    defer gpa.free(left_one.views);
    const change1 = left_one.list.at(0);

    var right = try forkDoc(&base);
    defer right.deinit();
    right.setActorId(.{ .bytes = "aaaaaa" });
    _ = try am.transaction.put(&right, root, .{ .key = "foo" }, .{ .str = "boz" });
    var right_one = try changesSince(&right, base_heads);
    defer right_one.list.deinit(gpa);
    defer gpa.free(right_one.views);
    const change2 = right_one.list.at(0);

    // "First apply the left change." (`test.rs`:1653-1654`)
    try testing.expectEqual(@as(usize, 1), try base.applyChanges(gpa, &.{change1}));

    // "Applying another change with the same actor/seq should throw a duplicate
    // seq number error." (`test.rs`:1656-1657`)
    //
    // **The state is asserted too**, because the refusal is the whole of
    // upstream's case and "it returned an error" is also what a document that
    // refuses every apply would answer. `foo` must still read `"qux"`.
    try testing.expectError(error.DuplicateSeqNumber, base.applyChanges(gpa, &.{change2}));
    try testing.expectEqualStrings("qux", (try scalarAt(&base, root, .{ .key = "foo" })).str);
    try testing.expect(try hasNoChange(&base, change2.hash));
}

// ── 20. queued_orphan_with_conflicting_actor_seq_rejects_incoming_batch
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3663-3719

test "a rejection leaves the receiver exactly where its queued orphan left it" {
    const base_actor: ActorId = .{ .bytes = "aaaaaaaa" };
    const branch_actor: ActorId = .{ .bytes = "bbbbbbbb" };

    var base_doc = try newDocWithActor(base_actor);
    defer base_doc.deinit();
    _ = try am.transaction.put(&base_doc, root, .{ .key = "base" }, .{ .uint = 0 });
    const base_heads = try headsOf(&base_doc);
    defer gpa.free(base_heads);
    const base = try base_doc.save(gpa);
    defer gpa.free(base);

    var receiver = try Document.load(gpa, io, base, .unicode_code_point, .auto);
    defer receiver.deinit();
    receiver.setActorId(base_actor);

    // The stale branch writes twice, so its second change depends on the first:
    // applying the second alone leaves the first queued as an **orphan**, and
    // the receiver must advertise it as missing (`test.rs`:3688-3692`).
    var stale = try Document.load(gpa, io, base, .unicode_code_point, .auto);
    defer stale.deinit();
    stale.setActorId(branch_actor);
    _ = try am.transaction.put(&stale, root, .{ .key = "stale_missing" }, .{ .uint = 1 });
    const stale_heads1 = try headsOf(&stale);
    defer gpa.free(stale_heads1);
    const stale_missing = stale_heads1[0];
    _ = try am.transaction.put(&stale, root, .{ .key = "stale_orphan" }, .{ .uint = 2 });
    const missing_slice = try oneOf(gpa, stale_missing);
    defer gpa.free(missing_slice);
    var orphan = try stale.getChanges(gpa, missing_slice);
    defer orphan.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), orphan.len());
    const orphan_view = try changeViews(&orphan);
    defer gpa.free(orphan_view);
    // **Zero**, and that is upstream's own answer: `apply_changes_batch`
    // returns how many changes it *applied*, and a change whose dependency is
    // absent is queued rather than applied. `test.rs`:3691` writes
    // `receiver.apply_changes_batch(stale_orphan).unwrap();` and discards the
    // count, so the number is asserted here — a receiver that applied the
    // orphan would have a head `stale_missing` never reached, and the
    // `get_missing_deps` check two lines below would then be vacuous.
    try testing.expectEqual(@as(usize, 0), try receiver.applyChanges(gpa, orphan_view));
    const need1 = try receiver.getMissingDeps(gpa, &.{});
    defer gpa.free(need1);
    try testing.expectEqualSlices(ChangeHash, &.{stale_missing}, need1);

    // The live branch writes twice **from the same base**, so its first change
    // is `(bbbbbbbb, 1)` and its second is `(bbbbbbbb, 2)` — and `(bbbbbbbb, 1)`
    // is the change sitting in the receiver's queue under a *stale* hash. The
    // collision is at seq 2, not seq 1, which is what makes this the queued-orphan
    // case rather than case 19 again.
    var live = try Document.load(gpa, io, base, .unicode_code_point, .auto);
    defer live.deinit();
    live.setActorId(branch_actor);
    _ = try am.transaction.put(&live, root, .{ .key = "live_1" }, .{ .uint = 3 });
    _ = try am.transaction.put(&live, root, .{ .key = "live_2" }, .{ .uint = 4 });
    var live_changes = try live.getChanges(gpa, base_heads);
    defer live_changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), live_changes.len());
    // Both come from `branch_actor` and are at seq 1 and 2 in that order, so the
    // refusal is at seq 2 — upstream's `DuplicateSeqNumber(2, branch_actor)`
    // (`test.rs`:3707-3712`). The port's error has no payload, so the sequence
    // number it names is checked here instead.
    const live0 = live_changes.at(0);
    const live1 = live_changes.at(1);
    try testing.expectEqualStrings("bbbbbbbb", live0.actor.bytes);
    try testing.expectEqualStrings("bbbbbbbb", live1.actor.bytes);
    try testing.expectEqual(@as(u64, 1), live0.seq);
    try testing.expectEqual(@as(u64, 2), live1.seq);
    const live_views = try changeViews(&live_changes);
    defer gpa.free(live_views);
    try testing.expectError(error.DuplicateSeqNumber, receiver.applyChanges(gpa, live_views));

    // `test.rs`:3714-3718`: the receiver is where the orphan left it. Three
    // absent keys and an unchanged head set, plus the missing dependency still
    // advertised — the refusal must not have consumed the queue.
    const heads_after = try headsOf(&receiver);
    defer gpa.free(heads_after);
    try testing.expectEqualSlices(ChangeHash, base_heads, heads_after);
    try testing.expect((try am.read.get(&receiver, root, .{ .key = "live_1" })) == null);
    try testing.expect((try am.read.get(&receiver, root, .{ .key = "live_2" })) == null);
    try testing.expect((try am.read.get(&receiver, root, .{ .key = "stale_orphan" })) == null);
    const need2 = try receiver.getMissingDeps(gpa, &.{});
    defer gpa.free(need2);
    try testing.expectEqualSlices(ChangeHash, &.{stale_missing}, need2);
}

// ── 21. round_trip_change_with_extra_bytes
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3782-3846
//
// **Not ported: the port cannot build a change.** The case's whole fixture is
// `Change::from(ExpandedChange { …, extra_bytes })` (`test.rs`:3795-3818`) —
// two hand-built changes at sequence 2 and 3 of the same actor, carrying
// `[0xCA, 0xFE]` and `[0xBA, 0xBE, 0x01]` as footers. The property is a
// prefix-sum offset bug in `change_graph.rs` that only non-empty, adjacent,
// distinct blobs expose, because with empty footers every range is zero-length
// (`test.rs`:3784-3788`).
//
// **There is no public change constructor.** [`Change`](../src/change.zig):91-135
// is a header view over borrowed bytes and nothing builds one from an operation
// list; [`Document.commit`](../src/doc.zig) is the only way to make a change and
// it stamps the *author* footer
// ([`TransactionArgs.author`](../src/doc.zig):2761), not arbitrary bytes. So
// two changes with distinct non-empty footers cannot be produced at all.
//
// What *is* reachable is the other end of the same range arithmetic: the footers
// a document's own author changes produce. Case 16 above reads them back out of
// a live change and checks the exact bytes; this file's `getChangeByHash` path
// — which is what a peer asking for a change by hash exercises, and which
// re-encodes the change from `node_info` — is what would carry them across a
// save. A change-by-hash round trip over an authored document is
// `test/upstream_doc_test.zig`'s case 97 (`test_get_last_local_change_generation`)
// plus the `get_changes` cases 99 and 100.

// ── 22. incremental_load_preserves_text_encoding_for_all_change_chunk_types
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4144-4178
//
// **Ported for two of upstream's three chunk types.** The third is a **bundle**
// (`test.rs`:4160`: `doc.bundle(expected_heads).unwrap().bytes()`), and the port
// has no `Document.bundle` — see case 5. So the loop below runs over `change` and
// `compressed change`, and the bundle arm is a gap, not a test.
//
// The two arms that run are the interesting half: the compressed arm is the one
// that goes through [`Document.loadIncremental`](../src/doc.zig)'s inflate path,
// and it is where an encoding written into the document's *own* state rather than
// read back from the bytes would show.

test "load_incremental preserves the receiver's text encoding for a change and for a compressed change" {
    // ## The writes are one transaction, and that is not cosmetic
    //
    // Upstream's `doc.put_object(..)` then `doc.put(..)` with no `commit()`
    // between them are **one change of two operations**, because `AutoCommit`
    // keeps one transaction open across mutating calls
    // ([`autocommit.rs`:445-462](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    // `ensure_transaction_open` / `ensure_transaction_closed`). So
    // `doc.get_last_local_change()` is the *whole* document — both the text
    // object and the padding — and loading it alone reconstructs everything.
    //
    // **The port's autocommit door commits every mutating call**
    // ([`transact.zig`](../src/transact.zig), every module-level function opens
    // a transaction and commits it), so the same two calls are **two changes**
    // and the second depends on the first. A first draft of this test used the
    // autocommit door and had to be rewritten: `load_incremental` of the second
    // change alone queues it as an orphan, the receiver ends with **no heads at
    // all**, and the assertions below fail on an empty document rather than on
    // an encoding. The manual door is what upstream's own semantics are, so it
    // is what this test uses — [`Document.setMode`](../src/doc.zig) exists for
    // exactly this and the deviation is recorded in
    // [API.md](../API.md) §Write.
    const encoding: TextEncoding = .utf16_code_unit;
    var doc = try Document.initWithEncoding(gpa, io, encoding, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());

    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    const text_obj = try Tx.putObject(&tx, root, .{ .key = "text" }, .text);
    try testing.expect(!text_obj.eql(root));
    // "Make the change large enough for Change::bytes() to compress it"
    // (`test.rs`:4149-4151): `DEFLATE_MIN_SIZE` is 250 upstream, so a 300-byte
    // payload puts the body over it.
    const padding = try gpa.alloc(u8, 300);
    defer gpa.free(padding);
    @memset(padding, 0);
    _ = try Tx.put(&tx, root, .{ .key = "padding" }, .{ .bytes = padding });
    _ = (try Tx.commit(&tx, null, null)) orelse return error.NoCommit;

    const expected_heads = try headsOf(&doc);
    defer gpa.free(expected_heads);
    // One change, so one head — and if this ever became two, the loads below
    // would be loading a fragment and the case would be vacuous rather than
    // wrong. That is the assertion this test needs to stay honest.
    try testing.expectEqual(@as(usize, 1), expected_heads.len);
    var expected = try hydrateNow(&doc);
    defer expected.deinit();

    var maybe = try doc.getLastLocalChange(gpa);
    defer if (maybe) |*b| b.deinit(gpa);
    const built = &(maybe orelse return error.NoLocalChange);
    // The change must actually be a change, not a fragment: `seq` 1 and the
    // two ops it wrote.
    try testing.expectEqual(@as(u64, 1), built.change.seq);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try chunkmod.writeChunk(&raw, gpa, .change, built.body);
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    try chunkmod.compressChunk(&compressed, gpa, built.body);
    // "assert_ne!(compressed_change, uncompressed_change)" (`test.rs`:4159`).
    // **Compressed must also be *smaller***, which is what makes the compressed
    // arm a test of the inflate path at all: equal-length buffers could be two
    // spellings of the same thing, and the port's `compressChunk` skips nothing.
    try testing.expect(compressed.items.len < raw.items.len);

    const arms = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "change", .bytes = raw.items },
        .{ .name = "compressed change", .bytes = compressed.items },
    };
    for (arms) |arm| {
        // **A fresh document in the *same* encoding** every arm: this is the
        // empty-document fast path of [`Document.loadIncremental`](../src/doc.zig):3261-3266,
        // which is the path the case is about. The receiver's encoding is set
        // by the constructor and never written by the load.
        var reconstructed = try Document.initWithEncoding(gpa, io, encoding, .auto);
        defer reconstructed.deinit();
        _ = try reconstructed.loadIncremental(gpa, arm.bytes);

        try testing.expectEqual(encoding, reconstructed.textEncoding());
        const got_heads = try headsOf(&reconstructed);
        defer gpa.free(got_heads);
        if (!sameHashes(expected_heads, got_heads)) {
            std.debug.print(
                "\nloading a {s} produced {d} head(s) where the source has {d}: " ++
                    "the change was queued rather than applied\n",
                .{ arm.name, got_heads.len, expected_heads.len },
            );
            return error.HeadsDiffer;
        }
        // The change is the same change, by the identity the format defines.
        try testing.expect(reconstructed.hasChange(expected_heads[0]));
        var actual = try hydrateNow(&reconstructed);
        defer actual.deinit();
        if (!actual.eql(&expected)) {
            std.debug.print("\nloading a {s} changed the hydrated document\n", .{arm.name});
            return error.HydrateDiffers;
        }
    }
}

// ── 23. queued_change_does_not_collide_with_later_local_change
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4362-4405

test "a rejected branch is dropped from the queue, so the next local change gets the sequence number back" {
    const actor: ActorId = .{ .bytes = "\x7f\x00\x00\x00\x00\x00\x00\x00" };
    var local = try Document.init(gpa, io, .auto);
    defer local.deinit();
    local.setActorId(actor);
    _ = try am.transaction.put(&local, root, .{ .key = "base" }, .{ .int = 0 });
    const base = try headsOf(&local);
    defer gpa.free(base);

    var remote = try forkDoc(&local);
    defer remote.deinit();
    remote.setActorId(actor);

    // "Both branches independently create sequence number 2 for the same actor."
    // (`test.rs`:4372-4376`)
    _ = try am.transaction.put(&local, root, .{ .key = "local-2" }, .{ .int = 2 });
    _ = try am.transaction.put(&remote, root, .{ .key = "remote-2" }, .{ .int = 2 });
    _ = try am.transaction.put(&remote, root, .{ .key = "remote-3" }, .{ .int = 3 });
    remote.setActorId(.{ .bytes = "\x03" });
    _ = try am.transaction.put(&remote, root, .{ .key = "dependent" }, .{ .int = 4 });

    var remote_changes = try remote.getChanges(gpa, base);
    defer remote_changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), remote_changes.len());
    // `test.rs`:4384-4386`: in this order, and the sequence numbers are 2, 3 and
    // 1 — the last change is by a *different* actor, so it restarts at 1.
    const remote_2 = remote_changes.at(0);
    const remote_3 = remote_changes.at(1);
    const dependent = remote_changes.at(2);
    try testing.expectEqual(@as(u64, 2), remote_2.seq);
    try testing.expectEqual(@as(u64, 3), remote_3.seq);
    try testing.expectEqual(@as(u64, 1), dependent.seq);
    try testing.expect(remote_2.actor.eql(actor));
    try testing.expect(remote_3.actor.eql(actor));
    try testing.expect(!dependent.actor.eql(actor));

    // "Sequence 3 and a change which transitively depends on it are queued
    // because the remote sequence-2 dependency is absent." (`test.rs`:4388-4390)
    //
    // The port's screen runs the same two checks in the same order
    // ([`batch.zig`](../src/opset/batch.zig):2354-2375), and the queue
    // acceptance is a *separate* pass after the loop (`:2379-2380`), so the two
    // changes are accepted into the queue and then come back out of
    // `popTopoSortedReady` as nothing: neither is ready. **`0` is the
    // assertion**, and it is what upstream's `.unwrap()` hides.
    try testing.expectEqual(@as(usize, 0), try local.applyChanges(gpa, &.{ remote_3, dependent }));

    // "Sequence 2 conflicts with the local sequence 2." (`test.rs`:4391-4392`)
    //
    // **The payload is checked without the payload.** Upstream matches
    // `DuplicateSeqNumber(2, _)`, and the port's tag carries no sequence number,
    // so what is asserted is the *state* that number protects: the refusal must
    // have taken the queued sequence-3 change with it, which is what the next
    // two steps depend on.
    try testing.expectError(error.DuplicateSeqNumber, local.applyChanges(gpa, &.{remote_2}));
    const need = try local.getMissingDeps(gpa, &.{});
    defer gpa.free(need);
    try testing.expectEqual(@as(usize, 0), need.len);

    // "The next local change also receives sequence 3. If the incompatible
    // queued change was retained, saving includes both sequence-3 changes."
    // (`test.rs`:4399-4404`) — the assertion is the load at the end, and the
    // property is that **the queue no longer holds a `(actor, 3)`**, so the two
    // changes do not collide on apply. That is only visible if a reader can see
    // the queue, and [`Document.save`] writes the queue verbatim
    // ([`doc.zig`](../src/doc.zig):3414-3418), so **the saved bytes are the
    // assertion's instrument**: a retained orphan would be appended and a load
    // of the result would fail.
    _ = try am.transaction.put(&local, root, .{ .key = "local-3" }, .{ .int = 3 });
    const local_heads = try headsOf(&local);
    defer gpa.free(local_heads);

    const saved = try local.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, io, saved, .unicode_code_point, .auto);
    defer reloaded.deinit();

    // The load is upstream's assertion; what makes it mean something is the
    // state behind it. **`local-3` is at sequence 3 and the remote sequence-3
    // change is gone**, so exactly one change claims `(actor, 3)`.
    try testing.expectEqual(@as(i64, 3), (try scalarAt(&reloaded, root, .{ .key = "local-3" })).int);
    try testing.expectEqual(@as(i64, 2), (try scalarAt(&reloaded, root, .{ .key = "local-2" })).int);
    try testing.expectEqual(@as(i64, 0), (try scalarAt(&reloaded, root, .{ .key = "base" })).int);
    try testing.expect((try am.read.get(&reloaded, root, .{ .key = "remote-3" })) == null);
    try testing.expect((try am.read.get(&reloaded, root, .{ .key = "remote-2" })) == null);
    try testing.expect((try am.read.get(&reloaded, root, .{ .key = "dependent" })) == null);
    const reloaded_heads = try headsOf(&reloaded);
    defer gpa.free(reloaded_heads);
    try testing.expectEqualSlices(ChangeHash, local_heads, reloaded_heads);
}
