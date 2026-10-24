//! `rust/automerge/tests/rich_text_fuzz_crash.rs`, ported case for case and in
//! upstream's order — **all 9** of its `#[test]` functions.
//!
//! ## What this file is, and why it is the other half of the totality gate
//!
//! Parsers must reject untrusted input without panic, unbounded loops, or unchecked allocation sizes.
//! The separate [`storage totality suite`](../src/storage/totality_test.zig) embeds upstream fuzz-crasher fixtures.
//!
//! **This file is the other half, and it is not a second copy of the first.**
//! `totality_test.zig` is a *mutation* suite: it takes well-formed documents and
//! truncates, flips and replaces bytes, so what it proves is that the **framing
//! and column decoders** are total over hostile bytes. Every one of its inputs
//! is a document whose *semantics* were valid before the mutation.
//!
//! These nine cases are **semantic** failures. Seven of the nine are documents
//! this port *writes itself*, in one of the nine specific operation sequences a
//! fuzzer produced and a human minimised:
//!
//! | what the reference used to do | case |
//! |---|---|
//! | panic in `BatchApply::apply` validating op order, when a zero-width unmark on an **empty** text object is synced | `:64` |
//! | build a document that fails to reload with *"mark end before begin"* from a zero-width mark on an **empty** text object | `:95` |
//! | a zero-width mark on one text object **leaking into a different** text object | `:118` |
//! | `debug_assert_eq!` in the op set: `length` counting a **conflicted** text element twice | `:164` |
//! | a `MarkEnd` spliced **before** its `MarkBegin` when a mark's range falls inside one multi-width element | `:194` |
//!
//! None of those is reachable by mutating bytes of a valid document: the input is
//! a **valid** document whose *operation order* is what is being tested. So the
//! property this file adds is: **the rich-text write, mark, sync and merge paths
//! are total over the operation sequences the fuzzer found**, which
//! `totality_test.zig` cannot reach because it never builds a document.
//!
//! ## A crash here is a worse finding than a wrong answer
//!
//! A wrong answer is a bug report. A **panic** is a crash a C consumer cannot
//! catch, and [`Document.load`](../src/doc.zig) is a library entry point a caller
//! hands bytes from somewhere else. So every case here is written to *name the
//! refusal*, never merely to observe that something went wrong: a totality test
//! asserting only "did not succeed" passes on any failure at all.
//!
//! ## The named variants, and where each comes from
//!
//! * `error.InvalidValueType` — [`transact.joinTextValues`](../src/transact.zig)
//!   for [`Transactable::splice`](../src/transact.zig) on a **text** object,
//!   upstream `AutomergeError::InvalidValueType { expected: "a string",
//!   unexpected: "Scalar(Int(1))" }`. Measured by the oracle's `richfuzz`
//!   subcommand.
//! * `error.InvalidMarkOrder` — [`opset/index.zig`](../src/opset/index.zig),
//!   upstream `ReconstructError::InvalidMarkOrderDoc` /
//!   `::InvalidMarkOrderChanges`, **both of which render the string
//!   `"invalid mark operation order: {message}"`** (`index.zig:194-199` of the
//!   reference, `op_set2/op_set/index.rs:23-75`). Upstream's own assertion is on
//!   that substring ([`:225-228`](../github-automerge-automerge/rust/automerge/tests/rich_text_fuzz_crash.rs));
//!   the port carries the two op ids in a [`MarkOrder`] value instead of a
//!   `String`, so the **named error** is the port's spelling of exactly the same
//!   refusal.
//!
//! ## Every actor in this file is heap-allocated, and that is deliberate
//!
//! Upstream's `commit_as` is `doc.set_actor(ActorId::from(actor.to_vec()))`
//! ([`:10-13`](../github-automerge-automerge/rust/automerge/tests/rich_text_fuzz_crash.rs)):
//! the bytes are a **fresh `Vec` on the heap**, owned by the `ActorId`, and the
//! `Vec`'s allocation outlives the call.
//!
//! String-literal actors cannot expose use-after-free defects in actor storage.
//! [`Actors`] hands out arena-allocated copies of every actor byte, including the two
//! upstream one-byte actors `[0]` and `[1]`, and the arena is freed only when
//! the document is. That is upstream's lifetime, and it is the shape a consumer's
//! bytes have.
//!
//! ## Boundedness: the argument, because no green run proves it
//!
//! Boundedness requires more than a successful test run. The argument for this file:
//!
//! * **The only untrusted bytes in this file are 207.** [`broken_mark_bytes`]
//!   embeds `test/fixtures/broken_zero_width_mark.automerge`, byte-compared
//!   against `$AUTOMERGE_REF/rust/automerge/tests/fixtures/` before this file
//!   was written — **identical, 207 bytes, sha256
//!   `cc486c4bdec7bd5b72710bac36c440fc2f0cabe6cf3fd12b1b6f52d71e2e42c2`**. Its
//!   framing is `4` magic + `4` checksum + `1` type + `2` LEB128 length +
//!   **196** bytes of body, and **the magic appears exactly once in the file**,
//!   so [`parseChunks`](../src/storage/chunk.zig) runs **once**. The general
//!   bound the totality suite argues — a chunk is at least 10 bytes, so at most
//!   `bytes.len / 10` iterations (`chunk.zig:263`, `:287`) — puts a ceiling of
//!   **20** on this one, and the measured answer is **1**.
//! * **The body is not DEFLATE.** The chunk type byte is `0x00`
//!   ([`ChunkType.document`](../src/storage/chunk.zig)), and only `.compressed`
//!   defers to [`decompressRaw`](../src/storage/chunk.zig). **So the one loop
//!   whose trip count is not a function of the input — the DEFLATE decoder, the
//!   loop the totality suite therefore *measures* rather than argues — is never
//!   entered by any case in this file.** Everything downstream of the framing
//!   walks rows decoded from those 196 bytes, so every remaining loop is bounded
//!   by them.
//! * **Cases 1–7 and 9 write their own input.** Their documents hold at most
//!   the ~15 operations the case itself writes, which is a constant in this
//!   file, so every index build, mark fold, span walk and save is bounded by a
//!   compile-time constant.
//!
//! **Distinguishing "slow" from "hung".** None of these nine needs a watchdog:
//! the **whole** binary — all eight cases, in a debug build — measures **0.64 s
//! and 0.78 s wall clock at 12.6 MB and 10.5 MB peak RSS** over two runs
//! (`/usr/bin/time -v`), and the bound above says *why* rather than the timing
//! saying it. Were one of them
//! ever to become slow, the distinction would be made with `perf record` and
//! **RSS**, not with a timeout: a non-terminating loop shows state R at 99 % CPU
//! with **RSS flat**, and an O(n²) shows RSS *and* a quadratic profile, which a
//! timeout alone cannot tell apart from either.
//!
//! ## Change boundaries
//!
//! Each write below opens an explicit raw transaction and commits it. These
//! per-operation boundaries preserve this suite's original change structure:
//! the two mark operations in cases 4 and 7 remain separate changes.
//!
//! Rescue is tested through the public value-only API, alongside the strict
//! snapshot and incremental load refusals for the same historical fixture.
//!
//! The leak arbiter is [`gpa`], and every owned value in this file comes out of
//! it: every head list, every `save()` byte string, every hydrated mirror, every
//! mark list and every text a reader hands back.

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
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ActorId = am.ActorId;
const ExpandMark = am.marks.ExpandMark;
const Mark = am.marks.Mark;
const Mirror = am.hydrate.Value;
const Span = am.iter.spans.Span;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

/// [`rust/automerge/tests/fixtures/broken_zero_width_mark.automerge`](../github-automerge-automerge/rust/automerge/tests/fixtures),
/// embedded with `@embedFile`, matching upstream's `include_bytes!`.
/// Embedding avoids dependence on the test process's working directory.
///
/// **The bytes were checked before they were used.** `cmp` against the reference
/// checkout: identical, 207 bytes on both sides.
const broken_mark_bytes = @embedFile("fixtures/broken_zero_width_mark.automerge");

// ── Actors ───────────────────────────────────────────────────────────────────

/// Upstream's actors, and the one thing about them this file copies on purpose.
///
/// Upstream draws a random actor per `AutoCommit::new`
/// ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and names the other two with a one-byte literal, `[0]` and `[1]`
/// ([`:10-13`](../github-automerge-automerge/rust/automerge/tests/rich_text_fuzz_crash.rs)).
/// A random actor would make a failure unreproducible, so [`mint`] substitutes a
/// counter — distinct bytes, a stable order, the same bytes on every run, for the
/// reason [`test/upstream_doc_test.zig`](upstream_doc_test.zig) gives.
///
/// **Every byte handed out here is a heap allocation**, including the two
/// upstream literals. See the module doc for why that is the interesting choice
/// and not decoration.
const Actors = struct {
    arena: std.heap.ArenaAllocator,
    minted: usize = 0,

    fn init() Actors {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *Actors) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// A copy of `bytes` in this arena, valid until [`deinit`].
    fn intern(self: *Actors, bytes: []const u8) Allocator.Error!ActorId {
        const copy = try self.arena.allocator().dupe(u8, bytes);
        return .{ .bytes = copy };
    }

    /// The next actor: eight bytes counting up from one, so no document ever
    /// holds an **empty** actor, which is a different value from every other one.
    fn mint(self: *Actors) Allocator.Error!ActorId {
        self.minted += 1;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(self.minted), .little);
        return self.intern(&buf);
    }
};

/// Sets the actor for the next explicit transaction; preceding writes have
/// already committed and released their owned commit logs.
fn commitAs(doc: *Document, actors: *Actors, bytes: []const u8) !void {
    doc.setActorId(try actors.intern(bytes));
}

// ── Documents ────────────────────────────────────────────────────────────────

/// A raw document whose writes below use explicit transactions.
fn newDoc(actors: *Actors) !Document {
    var doc = try Document.init(gpa, io);
    errdefer doc.deinit();
    doc.setActorId(try actors.mint());
    return doc;
}

/// Upstream's `doc.fork()`, which is [`Document.forkAt`](../src/doc.zig) at the
/// source's own heads.
///
/// **Not [`Document.fork`](../src/doc.zig)**, because that mints its actor
/// through the source's retained `io` and the fork's actor would differ on
/// every run. **Determinism, not a leak**: `fork` allocates that actor from the
/// **fork's own** arena, which [`Document.deinit`](../src/doc.zig) frees.
fn forkDoc(actors: *Actors, src: *Document) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    var out = try src.forkAt(gpa, heads);
    errdefer out.deinit();
    out.setActorId(try actors.mint());
    return out;
}

const Tx = am.Transaction;

fn WriteResult(comptime method: []const u8) type {
    const return_type = @typeInfo(@TypeOf(@field(Tx, method))).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.payload;
}

/// Each operation retains the suite's original explicit change boundary.
fn committedWrite(
    doc: *Document,
    comptime method: []const u8,
    args: anytype,
) !WriteResult(method) {
    var tx = try Tx.open(gpa, doc);
    defer tx.deinit() catch @panic("testing allocator cannot refuse rollback");
    const value = try @call(.auto, @field(Tx, method), .{&tx} ++ args);
    var committed = try tx.commit();
    defer committed.deinit(gpa);
    return value;
}

fn committedSplice(doc: *Document, obj: ExId, index: usize, del: isize, values: []const Mirror) !void {
    var tx = try Tx.open(gpa, doc);
    defer tx.deinit() catch @panic("testing allocator cannot refuse rollback");
    try tx.splice(obj, index, del, values);
    var committed = try tx.commit();
    defer committed.deinit(gpa);
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// `doc.text(&obj)` as a caller-owned string, which is what [`read.text`](../src/read.zig)
/// hands back ([`read.rs`:181](../github-automerge-automerge/rust/automerge/src/read.rs)).
fn readText(doc: *Document, obj: ExId) ![]u8 {
    return am.read.text(doc, obj, gpa);
}

/// The visible text of `obj` reassembled from [`am.read.spans`](../src/iter/spans.zig),
/// which is upstream's
/// `filter_map(|span| match span { Span::Text { text, .. } => Some(text), Span::Block(_) => None })`
/// ([`test.rs`:710-717](../github-automerge-automerge/rust/automerge/tests/test.rs)).
///
/// **One span's text is not a borrow**: `read.spans` hands each span over and
/// each one owns its text and its mark set, so each span is released before the
/// next `next` overwrites the walk's buffer.
fn spanText(doc: *Document, obj: ExId) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var walk = try am.read.spans(doc, obj, gpa);
    defer walk.deinit();
    while (try walk.next()) |item| {
        var owned = item;
        defer owned.deinit(gpa);
        try out.appendSlice(gpa, owned.asStr());
    }
    return out.toOwnedSlice(gpa);
}

/// The marks over `obj`, as a caller-owned list.
fn readMarks(doc: *Document, obj: ExId) ![]Mark {
    return am.read.marks(doc, obj, gpa);
}

/// The object at `obj.prop`.
fn objectAt(doc: *Document, obj: ExId, prop: Prop) !ExId {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

/// The scalar at `obj.prop`.
fn scalarAt(doc: *Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

// ── The round trip three of the cases take ──────────────────────────────────

/// [`save_load`](https://github.com/automerge/automerge/blob/main/rust/automerge/tests/rich_text_fuzz_crash.rs)
/// `:15-22`: hydrate the root, `save()`, load those bytes into a **fresh**
/// document, hydrate that root, and require the two mirrors to be equal.
///
/// **The returned document is the loaded one**, because upstream ends with
/// `*doc = loaded` and the caller keeps using that one; the document passed in
/// is deinitialised here so exactly one owner ever frees it. A caller that wants
/// both must copy out of `doc` first, which is why no case here does.
fn saveLoad(doc: *Document) !Document {
    var before = try am.hydrate.hydrateMap(am.doc.Set, &doc.ops, gpa, root, null);
    defer before.deinit();

    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, io, bytes, .unicode_code_point);
    errdefer loaded.deinit();

    var after = try am.hydrate.hydrateMap(am.doc.Set, &loaded.ops, gpa, root, null);
    defer after.deinit();

    if (!before.eql(&after)) {
        std.debug.print(
            "\nsave/load round trip: the document does not survive its own bytes\n",
            .{},
        );
        return error.SaveLoadDiffers;
    }

    doc.deinit();
    return loaded;
}

/// `Automerge::load(&doc.save()).unwrap()` — the **strict** reload, asked
/// separately from [`saveLoad`] so a refusal names which of the two refused.
fn expectReloadable(doc: *Document) !void {
    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    var reloaded = try Document.load(gpa, io, bytes, .unicode_code_point);
    reloaded.deinit();
}

/// The number of code points in `s`, which is what
/// `doc.text(&text).unwrap().chars().count()` counts upstream and is **not** the
/// byte length: the object replacement character U+FFFC is three bytes and one
/// character, which is the whole point of the `:182` assertion.
fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch unreachable;
}

// ── 1. splice_scalar_into_marked_text ────────────────────────────────────────
test "splice a scalar into a marked text object is refused by name" {
    // `rich_text_fuzz_crash.rs:25-44`
    //
    // **A named variant, never "it failed".** Upstream asserts
    // `Err(AutomergeError::InvalidValueType { .. })`, and the oracle's
    // `richfuzz` subcommand measured the payload the reference produces today:
    // `InvalidValueType { expected: "a string", unexpected: "Scalar(Int(1))" }`,
    // display *"invalid type of value, expected `a string` but received
    // `Scalar(Int(1))`"*. The port's refusal is [`transact.joinTextValues`](../src/transact.zig),
    // which is upstream's `values_to_splice_text` (`inner.rs:1391-1405`) reached
    // from the text arm of a splice (`inner.rs:620-621`), and it raises the same
    // variant.
    //
    // **The point of the case is the half of it upstream does not assert**: a
    // splice on a text object "must not use list splice semantics"
    // (`:26-27`). A `splice` that fell through to the list arm would have
    // written an `Int` element into the text, so the document would have
    // changed. The oracle measured the document as unchanged — `"abcd"`, length
    // 4, the `m` mark still covering `[0, 4)` — and so does this.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    const text = try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text });
    try committedWrite(&doc, "updateText", .{ text, "abcd" });
    try committedWrite(&doc, "mark", .{ text, 0, 4, "m", ExpandMark.none, ScalarValue{ .bool_value = true } });

    // **A heap-allocated mirror value, not a literal**, so the refusal is
    // reached through the same door a consumer reaches it through.
    const values = try gpa.alloc(Mirror, 1);
    defer gpa.free(values);
    values[0] = .{ .int = 1 };
    try testing.expectError(
        error.InvalidValueType,
        committedSplice(&doc, text, 2, 0, values),
    );

    const after = try readText(&doc, text);
    defer gpa.free(after);
    try testing.expectEqualStrings("abcd", after);
    try testing.expectEqual(@as(usize, 4), try am.read.length(&doc, text));

    const marks = try readMarks(&doc, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqual(@as(usize, 0), marks[0].start);
    try testing.expectEqual(@as(usize, 4), marks[0].end);
}

// ── 2. splice_string_into_marked_text ────────────────────────────────────────
test "splice a string into a marked text object rewrites the text" {
    // `rich_text_fuzz_crash.rs:47-61`
    //
    // The same operation with a string in place of the scalar must **succeed**,
    // and the mark must still be there afterwards. The oracle measured the mark
    // the reference reads back as `[Mark { start: 0, end: 5, name: "m", value:
    // Boolean(true) }]` — grown by the one inserted character, which is what a
    // non-expanding mark over a spliced run does.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    var text = try (try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text })).dup(gpa);
    defer text.deinitOwned(gpa);
    try committedWrite(&doc, "updateText", .{ text, "abcd" });
    try committedWrite(&doc, "mark", .{ text, 0, 4, "m", ExpandMark.none, ScalarValue{ .bool_value = true } });

    const values = try gpa.alloc(Mirror, 1);
    defer gpa.free(values);
    values[0] = .{ .str = "x" };
    try committedSplice(&doc, text, 2, 0, values);

    const after = try readText(&doc, text);
    defer gpa.free(after);
    try testing.expectEqualStrings("abxcd", after);
    try testing.expectEqual(@as(usize, 5), try am.read.length(&doc, text));

    const marks = try readMarks(&doc, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 1), marks.len);
    try testing.expectEqualStrings("m", marks[0].name);
    try testing.expectEqual(@as(usize, 0), marks[0].start);
    try testing.expectEqual(@as(usize, 5), marks[0].end);

    // **And it survives its own bytes**, which upstream does not ask for here
    // and which is free to add: a document that reloads is the property the
    // mark-order validator exists to protect.
    doc = try saveLoad(&doc);
    const reloaded = try readText(&doc, text);
    defer gpa.free(reloaded);
    try testing.expectEqualStrings("abxcd", reloaded);
}

// ── 3. zero_width_unmark_on_empty_text_sync_from_fuzz_trace ──────────────────
test "a zero width unmark on an empty text object survives a sync both ways" {
    // `rich_text_fuzz_crash.rs:64-92`
    //
    // Minimised from `fuzz/corpus/trace/crashes/crash-00000000.amtrace`.
    // Syncing a new change into a document containing a zero-width unmark on an
    // empty text object used to **panic** in `BatchApply::apply` while
    // validating op order (`:66-67`). Upstream's assertion is the absence of the
    // panic; the oracle measured what the reference does instead, and this case
    // asserts that as well, because a crash test that cannot see convergence
    // would also pass on a sync that silently dropped the change.
    var actors = Actors.init();
    defer actors.deinit();
    var left = try newDoc(&actors);
    defer left.deinit();

    const text = try committedWrite(&left, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text });
    try committedWrite(&left, "unmark", .{ text, 0, 0, ExpandMark.after, "color", null });

    var right = try forkDoc(&actors, &left);
    defer right.deinit();
    _ = try committedWrite(&right, "put", .{ root, Prop{ .key = "x" }, ScalarValue{ .int = 1 } });

    // **One exchange, in upstream's direction order**: left generates and right
    // receives, then right generates and left receives. Upstream asserts nothing
    // about the messages; the port's sync states are real
    // ([`State.new`](../src/sync/state.zig)) and the messages are the ones the
    // reference's own protocol produces, so this is the same two calls.
    // **The states own their allocations** — the shared heads, the sent heads,
    // the peer's head hashes, its capability list and its bloom filter
    // ([`State.deinit`](../src/sync/state.zig)) — so each is deinitialised with
    // the test. A `State` that is never deinitialised leaks several allocations
    // and the test binary reports them at exit.
    var left_state = am.sync.state.State.new(gpa);
    defer left_state.deinit();
    var right_state = am.sync.state.State.new(gpa);
    defer right_state.deinit();
    if (try am.sync.protocol.generateSyncMessage(gpa, &left, &left_state)) |msg| {
        // `receiveSyncMessage` **takes the message and frees it**
        // ([`protocol.zig`](../src/sync/protocol.zig):546-550), so there is
        // nothing here to free and nothing here to leak.
        try am.sync.protocol.receiveSyncMessage(gpa, &right, &right_state, msg);
    } else return error.NoMessageFromLeft;
    if (try am.sync.protocol.generateSyncMessage(gpa, &right, &right_state)) |msg| {
        try am.sync.protocol.receiveSyncMessage(gpa, &left, &left_state, msg);
    } else return error.NoMessageFromRight;

    // **Convergence.** The oracle measured both peers holding `x = 1`, both
    // texts empty, and one head each.
    try testing.expectEqual(ScalarValue{ .int = 1 }, try scalarAt(&left, root, .{ .key = "x" }));
    try testing.expectEqual(ScalarValue{ .int = 1 }, try scalarAt(&right, root, .{ .key = "x" }));

    const left_text = try readText(&left, text);
    defer gpa.free(left_text);
    try testing.expectEqualStrings("", left_text);
    const right_text = try readText(&right, text);
    defer gpa.free(right_text);
    try testing.expectEqualStrings("", right_text);

    // **Same heads on both sides**, which is what "the sync worked" means.
    const lh = try left.getHeads(gpa);
    defer gpa.free(lh);
    const rh = try right.getHeads(gpa);
    defer gpa.free(rh);
    try testing.expectEqual(@as(usize, 1), lh.len);
    try testing.expectEqualSlices(am.ChangeHash, lh, rh);

    // **And the merged document is still valid**: saving and loading it is what
    // proves the mark operations survived the exchange in an order
    // `MarkOrderValidator` accepts, which is exactly what used to panic.
    const saved = try left.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, io, saved, .unicode_code_point);
    reloaded.deinit();
}

// ── 4. zero_width_mark_on_empty_text_from_fuzz_trace ─────────────────────────
test "a zero width mark on an empty text object round trips through save and load" {
    // `rich_text_fuzz_crash.rs:95-115`
    //
    // "This needs two committed changes: a zero-width unmark on an empty text
    // object, then a zero-width mark on the same text" (`:96-97`). The explicit
    // transactions below keep those operations in separate changes.
    // Upstream's assertion is save_load: hydrate, save, load, hydrate, equal.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    var text = try (try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text })).dup(gpa);
    defer text.deinitOwned(gpa);
    try committedWrite(&doc, "unmark", .{ text, 0, 0, ExpandMark.after, "italic", null });
    try commitAs(&doc, &actors, &.{1});
    try committedWrite(&doc, "mark", .{ text, 0, 0, "link", ExpandMark.before, ScalarValue{ .bool_value = true } });
    try commitAs(&doc, &actors, &.{1});

    // The oracle measured the reference reading this document back as two
    // changes, an empty text, length zero, no spans and no marks — **a
    // zero-width mark covers nothing**, so it is not visible in the span list.
    doc = try saveLoad(&doc);

    const after = try readText(&doc, text);
    defer gpa.free(after);
    try testing.expectEqualStrings("", after);
    try testing.expectEqual(@as(usize, 0), try am.read.length(&doc, text));

    const spans = try spanText(&doc, text);
    defer gpa.free(spans);
    try testing.expectEqualStrings("", spans);

    const marks = try readMarks(&doc, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 0), marks.len);
}

// ── 5. zero_width_mark_does_not_leak_to_later_text_object_from_fuzz_trace ────
test "a zero width mark does not leak into a later text object" {
    // `rich_text_fuzz_crash.rs:118-150`
    //
    // Minimised from the same trace: a zero-width expanding mark on one empty
    // text object, then an insert into the middle of a **different** text
    // object. Upstream asserts the whole span list of the second object, and so
    // does this: one span, its text, and **no marks** — the leak would show up
    // as `marks: Some(..)` on that span, which is the whole assertion.
    //
    // **The oracle measured the reference's answer exactly**:
    // `[Text { text: "tsbbqiolafxs", marks: None }]`, one span, length 12.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    const text = try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text });
    try commitAs(&doc, &actors, &.{0});
    try committedWrite(&doc, "mark", .{ text, 0, 0, "italic", ExpandMark.after, ScalarValue{ .bool_value = true } });
    try commitAs(&doc, &actors, &.{0});
    const other = try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "o1" }, ObjType.text });
    try commitAs(&doc, &actors, &.{0});
    try committedWrite(&doc, "spliceText", .{ other, 0, 0, "tsxs" });
    try commitAs(&doc, &actors, &.{1});
    try committedWrite(&doc, "spliceText", .{ other, 2, 0, "bbqiolaf" });

    // **The span list, element by element**, not the reassembled text: a leak
    // that added a mark would leave the text identical and only the marks
    // different, so comparing the text alone would pass on the defect.
    var walk = try am.read.spans(&doc, other, gpa);
    defer walk.deinit();
    var spans: usize = 0;
    while (try walk.next()) |item| {
        var owned = item;
        defer owned.deinit(gpa);
        spans += 1;
        switch (owned) {
            .text => |t| try testing.expect(t.marks == null),
            .block => return error.ExpectedATextSpan,
        }
        try testing.expectEqualStrings("tsbbqiolafxs", owned.asStr());
    }
    try testing.expectEqual(@as(usize, 1), spans);

    // **And the first object really is untouched**: no spans, no marks, empty.
    const first_spans = try spanText(&doc, text);
    defer gpa.free(first_spans);
    try testing.expectEqualStrings("", first_spans);
    const first_marks = try readMarks(&doc, text);
    defer gpa.free(first_marks);
    try testing.expectEqual(@as(usize, 0), first_marks.len);
}

// ── 6. splice_text_at_length_over_conflicted_element_from_fuzz_trace ─────────
test "splice text at the object's own length over a conflicted element" {
    // `rich_text_fuzz_crash.rs:164-191`
    //
    // A text object holds one character, which two **concurrent** `put`s — from
    // a fork and its parent — then overwrite at the same element. The `text`
    // index used to carry a width per *visible* op, so it counted the conflicted
    // position twice: `length` returned 2 while the index-based fast insert
    // query disagreed with the per-element reference query, tripping a
    // `debug_assert_eq!` in the op set (`:155-162`). Upstream asserts all three
    // numbers and then appends **at the object's own reported length**, which
    // must never be out of bounds.
    //
    // **The oracle measured the reference**: `length` 1, `get_all` 2, and the
    // text `"\u{FFFC}"` — one character, **three bytes**, which is why the
    // `:182` assertion is a character count and not a byte length.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    var text = try (try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text })).dup(gpa);
    defer text.deinitOwned(gpa);
    try committedWrite(&doc, "spliceText", .{ text, 0, 0, "a" });
    try commitAs(&doc, &actors, &.{0});

    var fork = try forkDoc(&actors, &doc);
    defer fork.deinit();
    _ = try committedWrite(&fork, "put", .{ text, Prop{ .index = 0 }, ScalarValue{ .int = 1 } });
    try commitAs(&fork, &actors, &.{1});

    _ = try committedWrite(&doc, "put", .{ text, Prop{ .index = 0 }, ScalarValue{ .int = 2 } });
    try commitAs(&doc, &actors, &.{0});

    const heads = try doc.merge(gpa, &fork);
    gpa.free(heads);

    // **One character position carrying two conflicting values.**
    const length = try am.read.length(&doc, text);
    try testing.expectEqual(@as(usize, 1), length);
    const all = try am.read.getAll(&doc, text, .{ .index = 0 }, gpa);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);

    const before = try readText(&doc, text);
    defer gpa.free(before);
    try testing.expectEqual(length, charCount(before));
    // **The count is a character count and not a byte count**, which the
    // reference makes measurable: U+FFFC is three bytes and one character, and
    // the oracle measured both (`text_bytes` 3, `text_chars` 1). A byte count
    // would read 3 here and the `:182` check would be satisfied by the wrong
    // number.
    try testing.expectEqual(@as(usize, 1), charCount(before));
    try testing.expectEqual(@as(usize, 3), before.len);

    // **Appending at the object's own reported length must not be out of
    // bounds.** `:185-186`.
    try committedWrite(&doc, "spliceText", .{ text, length, 0, "b" });
    try commitAs(&doc, &actors, &.{0});
    try testing.expectEqual(@as(usize, 2), try am.read.length(&doc, text));

    doc = try saveLoad(&doc);
    const after = try readText(&doc, text);
    defer gpa.free(after);
    try testing.expectEqualStrings("\u{FFFC}b", after);
}

// ── 7. mark_within_single_multi_width_element_from_fuzz_trace ────────────────
test "a mark inside one multi width element round trips through save and load" {
    // `rich_text_fuzz_crash.rs:194-219`
    //
    // A string inserted into a text object as a **single op** is one element of
    // text width 11 (`"hello world"`). A mark whose `[start, end)` falls
    // entirely inside that one element has both its anchors resolve to the same
    // op-set position; the `MarkEnd` used to be spliced **before** its
    // `MarkBegin`, which inverted the mark index and produced a document that
    // failed to reload with *"mark end before begin"* (`:195-202`).
    //
    // **`insert`, not `spliceText`, and the distinction is the case.**
    // [`Transaction.insert`](../src/transact.zig) is upstream's `do_insert`
    // (`inner.rs:331-347`), which writes **one** operation whatever the string's
    // length; `splice_text` writes one operation per code point. Only the first
    // produces the single multi-width element this case is about.
    var actors = Actors.init();
    defer actors.deinit();
    var doc = try newDoc(&actors);
    defer doc.deinit();

    var text = try (try committedWrite(&doc, "putObject", .{ root, Prop{ .key = "text" }, ObjType.text })).dup(gpa);
    defer text.deinitOwned(gpa);
    _ = try committedWrite(&doc, "insert", .{ text, 0, ScalarValue{ .str = "hello world" } });
    try commitAs(&doc, &actors, &.{0});
    try committedWrite(&doc, "mark", .{ text, 3, 8, "bold", ExpandMark.none, ScalarValue{ .bool_value = true } });
    try commitAs(&doc, &actors, &.{0});

    // **The element really is one element of width 11.** The oracle measured
    // `[Text { text: "hello world", marks: None }]` — a single span — and
    // `length` 11.
    try testing.expectEqual(@as(usize, 11), try am.read.length(&doc, text));
    var walk = try am.read.spans(&doc, text, gpa);
    defer walk.deinit();
    var spans: usize = 0;
    while (try walk.next()) |item| {
        var owned = item;
        defer owned.deinit(gpa);
        spans += 1;
        try testing.expectEqualStrings("hello world", owned.asStr());
    }
    try testing.expectEqual(@as(usize, 1), spans);

    // **A mark that opens and closes at the same position covers nothing**, so
    // the oracle measured no visible marks. This is not upstream's assertion; it
    // is the reference's own answer, and it is what "the mark index was not
    // inverted" looks like from the outside.
    const marks = try readMarks(&doc, text);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 0), marks.len);

    // **Must round-trip through save/load rather than being rejected as
    // corrupt** (`:216-217`) — twice, because upstream asks for both the strict
    // reload and its own [`save_load`].
    try expectReloadable(&doc);
    doc = try saveLoad(&doc);
    const after = try readText(&doc, text);
    defer gpa.free(after);
    try testing.expectEqualStrings("hello world", after);
}

// ── 8. load_rejects_historical_zero_width_mark_end_before_begin ──────────────
test "load refuses the historical zero width mark end before begin fixture" {
    // `rich_text_fuzz_crash.rs:222-229`
    //
    // Upstream asserts the error **string** contains `"invalid mark operation
    // order"`. The port carries no string: [`MarkOrderError`](../src/opset/index.zig)
    // declares `error.InvalidMarkOrder` for exactly this refusal, and
    // `op_set.zig` says the class is upstream's `ReconstructError::
    // InvalidMarkOrderDoc` / `::InvalidMarkOrderChanges`, **both of which render
    // that same string** (`index.zig:194-199` of this port). So the **named
    // variant** is the port's spelling of the substring upstream matches on.
    //
    // The oracle measured the reference's message in full:
    // *"error inflating document chunk ops: invalid mark operation order: mark
    // end OpId(3, 0) occurs before mark begin OpId(2, 0)"*.
    //
    // **This is a totality assertion and it is the sharpest one in the file**:
    // the input is 207 untrusted bytes, and the assertion is the *named*
    // refusal rather than "it did not load", so a panic, a truncation, a
    // checksum failure or any other refusal fails here.
    const result = Document.load(
        gpa,
        io,
        broken_mark_bytes[0..],
        .unicode_code_point,
    );
    if (result) |doc| {
        // **Leak-safe on the unexpected path**: the load *succeeded*, so the
        // document is freed before the failure is reported.
        var unexpected = doc;
        unexpected.deinit();
        std.debug.print(
            "\nload accepted broken_zero_width_mark.automerge; the fixture is " ++
                "{d} bytes and was byte-compared against the reference\n",
            .{broken_mark_bytes.len},
        );
        return error.ExpectedRefusal;
    } else |err| {
        try testing.expectEqual(error.InvalidMarkOrder, err);
    }

    // **And the same bytes are refused on the way into an existing document**,
    // which is the door a C consumer reaches (`AMdocLoadIncremental` is
    // `loadIncremental`, `c/doc.zig:356-359`, and the strict path is
    // `Document.load`). A loader that refused the snapshot but accepted the
    // same bytes as an incremental stream would be half a fix.
    var doc = try Document.init(gpa, io);
    defer doc.deinit();
    const incremental = doc.loadIncremental(gpa, broken_mark_bytes[0..]);
    try testing.expectError(error.InvalidMarkOrder, incremental);
}

// ── 9. rescue_recovers_snapshot_from_historical_zero_width_mark_order ────────
//
// `rich_text_fuzz_crash.rs:232-243` expects a detached hydrated root with
// text = "" and o1 = "tsxs". The public rescue regression below checks that
// content, deep ownership and refusal of corruption unrelated to mark order.

// ── Zig 0.16.0 / upstream / Rust / port ───────────────────────────────────────
//
// What this file changed about upstream's, and why, in one place.
//
// ## The counts, established by diffing rather than by counting
//
// All nine upstream cases are represented, including value-only rescue.
// Writes use raw transactions and release each named CommitResult's log.
// Per-operation boundaries retain this suite's original mark/change structure.
//
// ## Every actor is a heap allocation, on purpose
//
// Upstream's `ActorId::from(actor.to_vec())` allocates. A Zig string literal
// does not, and **a literal never dies**, so a suite built only from literals
// never reaches the path a consumer's bytes reach — which is how the C ABI's
// actor turned out to be freed memory today, found only through the C gate.
// [`Actors`] hands out arena-allocated copies of every actor byte, the two
// upstream one-byte actors `[0]` and `[1]` included, and frees the arena with
// the document.
//
// `ActorId.init(&.{1})` would have been shorter and would have tested less: the
// [`Document.setActorId`](../src/doc.zig) path stores the caller's bytes **as a
// borrow** when the actor is not already interned (`:2514-2520`), and the copy
// happens when the actor is interned. Heap bytes with an arena behind them are
// the only shape in which that borrow is sound *and* the bytes can die.
//
//
// ## `insert`, not `splice_text`, in case 7 — and it is the case
//
// Upstream's `doc.insert(&text, 0, "hello world")` (`transactable.rs:48-54`) is
// `TransactionInner::insert` (`inner.rs:331-347`) → `do_insert`, which writes
// **one** operation whatever the string's length. `splice_text` writes one
// operation per code point. **Only `insert` produces the single multi-width
// element** whose interior is where the `MarkEnd`-before-`MarkBegin` inversion
// appeared, so substituting `spliceText` here would have quietly deleted the
// case rather than ported it.
//
// ## The error string upstream matches on is a named variant here
//
// Upstream asserts `err.to_string().contains("invalid mark operation order")`
// (`:225-228`). The port builds no string on this path:
// [`MarkOrderError`](../src/opset/index.zig) is one tag,
// `error.InvalidMarkOrder`, and the same file records that it *is* upstream's
// `ReconstructError::InvalidMarkOrderDoc` / `::InvalidMarkOrderChanges`, **both
// of which render that substring** (`:194-207`). So case 8 asserts
// `error.InvalidMarkOrder` **by name**, which is stronger than the substring:
// any other refusal, and any panic, fails it.
//
// ## `InvalidValueType` loses its payload, the variant does not
//
// Upstream's case 1 asserts
// `InvalidValueType { expected: "a string", unexpected: "Scalar(Int(1))" }`.
// [`error.zig`](../src/error.zig) has one `error.InvalidValueType` and nothing
// attaches those two strings to it, so the assertion is on the variant. The
// oracle recorded the payload in the comment above, which is where it is
// checkable.
//
// ## Two assertions here are the reference's answer and not upstream's
//
// * Case 5 asserts `marks: None` **on the span**, not just the span list's
//   contents. Upstream compares the whole `Vec<Span>`, so this is the same
//   assertion; it is spelled out because a text-only comparison would pass on
//   the exact defect the case is about.
// * Case 7 asserts [`readMarks`] is **empty** and that there is exactly **one**
//   span. Upstream asserts only that the document reloads. The oracle measured
//   `marks: []` and one span, and "a mark that opens and closes at the same
//   position covers nothing" is what an un-inverted mark index looks like from
//   the outside — so this is a strengthening against the reference, not a
//   rewrite of the case.
//
// ## `fork()` is `forkAt` at the document's own heads, under a minted actor
//
// [`Document.fork`](../src/doc.zig) mints its actor through the source's
// retained `io`, so it differs on every run; [`forkDoc`] forks at the current
// heads — which is what `fork` means — and names the actor. **Determinism, not
// a leak**: `fork` allocates that actor from the **fork's own** arena, which
// [`Document.deinit`](../src/doc.zig) frees.
//
// ## Owned values, and who frees each
//
// * `Document.getHeads` hands back a **copy** and every case frees it
//   ([`doc.zig`:4507](../src/doc.zig)).
// * `Document.save` and [`Document.merge`](../src/doc.zig) return owned slices;
//   both are freed here.
// * [`am.read.text`](../src/read.zig), [`am.read.marks`](../src/read.zig) and
//   [`am.read.getAll`](../src/read.zig) return caller-owned arrays.
// * [`am.read.spans`](../src/iter/spans.zig) hands **each span over**, and each
//   span owns its text and its mark set, so every span is released before the
//   next `next` overwrites the walk's buffer. A walk whose spans were never
//   released leaks per span, and a released twice is a double free — either
//   ends the binary with an `ABRT` and hides every case after it.
// * [`sync.receiveSyncMessage`](../src/sync/protocol.zig) takes the message
//   **and frees it** (`:546-550`), so the two sync messages in case 3 are not
//   freed by the caller and must not be.

fn expectRescuedSnapshot(value: *const Mirror) !void {
    try testing.expect(value.* == .object and value.object == .map);
    const map = &value.object.map;
    try testing.expectEqual(@as(usize, 2), map.count());
    const fields = [_]struct { key: []const u8, text: []const u8 }{
        .{ .key = "text", .text = "" },
        .{ .key = "o1", .text = "tsxs" },
    };
    for (fields) |field| {
        const item = map.get(field.key) orelse return error.NoSuchKey;
        try testing.expect(item.* == .object and item.object == .text);
        const rendered = try item.object.text.makeString(gpa);
        defer gpa.free(rendered);
        try testing.expectEqualStrings(field.text, rendered);
    }
}

test "rescue returns detached value for invalid mark order only" {
    var copied = blk: {
        var rescued = try Document.rescue(gpa, io, broken_mark_bytes[0..]);
        defer rescued.deinit();
        // The temporary reconstruction document has already been destroyed.
        try expectRescuedSnapshot(&rescued.value);
        break :blk try rescued.value.dup(gpa);
    };
    defer copied.deinit();
    // A deep copy remains readable after the original rescued value is freed.
    try expectRescuedSnapshot(&copied.value);

    var damaged = broken_mark_bytes.*;
    damaged[damaged.len - 1] ^= 0x01;
    const result = Document.rescue(gpa, io, damaged[0..]);
    if (result) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedRefusal;
    } else |err| {
        try testing.expect(err != error.InvalidMarkOrder);
    }
}
