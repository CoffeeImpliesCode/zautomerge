//! Anonymization: a whole document replayed into a fresh one with every actor
//! id, key string, commit message and scalar replaced, and its **shape** kept.
//!
//! Upstream `anonymize.rs` (558 lines) plus `anonymize/shape.rs` (464) and
//! `anonymize/fuzz.rs` (200). The two rules it states are the two this file
//! exists to keep, and they are stated as promises rather than as hope:
//!
//! * **The shape survives.** Actor ids, change hashes, op ids and structural
//!   characters become canonical indices; private scalar data is reduced to its
//!   type and encoded width ([`Shape`]). Two documents with the same
//!   [`Shape`] are the same document with the data taken out.
//! * **The data does not.** Every actor, key, message and scalar is replaced,
//!   and [`checkPrivateDataChanged`] is the instrument that says so on the
//!   pair of documents rather than on a count.
//!
//! The second rule is why [`Shape`] exists as a separate case list rather than
//! as one "compare the documents" function: the naive rewrite — replace every
//! string, replace every number, leave everything else alone — is wrong for
//! most of the shapes, and each of them is a way it is wrong. The list is
//! enumerated in [`Shape`]'s own documentation and each entry is a test.
//!
//! # Why this file rewrites **columns** and not operations
//!
//! Upstream expands a change into [`legacy::Op`] rows, rewrites each row, and
//! rebuilds the change ([`anonymize.rs:60-101`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
//! This port's equivalent of that expansion is `doc.zig`'s `decodeChangeOps`
//! and `encodeChangeOps`, and **both are private to `doc.zig`**
//! ([`doc.zig:733`](doc.zig), [`:1017`](doc.zig)). So this file does the same
//! work one level down, on the fourteen change-op columns
//! ([`change_op_columns.rs:291-367`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)):
//! decode a column, rewrite its cells, re-encode it with the **same column id
//! and encoding**, and keep the column set exactly as the source had it.
//!
//! Two properties make that a faithful rewrite rather than a different one:
//!
//! * **The columns that carry no private data are copied verbatim.** An op's
//!   object, key anchor, predecessors, insert flag, action code and expand flag
//!   are all structural, and the actor columns are indices into the change's
//!   own actor list, which is rewritten **position for position** (below).
//! * **The actor columns need no rewriting at all.** A change chunk's columns
//!   number actors by *position* in `[author] ++ other_actors`
//!   ([`change_actors.rs:10-14`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_actors.rs),
//!   [`change.rs:56-60`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
//!   so writing the mapped actors in the source's order keeps every index
//!   meaning what it meant. An op id is `(counter, actor)`
//!   ([`types.rs:423`](../../github-automerge-automerge/rust/automerge/src/types.rs)):
//!   the counters are unchanged and the actors are replaced, so the op ids are
//!   new values and the document is internally consistent — which is exactly
//!   what upstream's row rewrite produces, since it also keeps every counter.
//!
//! The one column the writer emits in two halves — the value pair, metadata
//! then payload, both column id 5
//! ([`change_op_columns.rs:327-336`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs))
//! — is rewritten as a pair, because a replacement scalar need not have the
//! source's byte length.
//!
//! # The replacement is a substitution cipher and not more
//!
//! Characters are replaced through a **derangement per encoding class**
//! ([`Permutations`]): a character of one UTF-8 width is replaced by a
//! character of the same width, and never by itself. That is what keeps a text
//! object's length — measured in graphemes, in UTF-16 units, and in bytes —
//! the same, which is what keeps every index into that text meaning the same
//! thing afterwards. Upstream says the same of its own tables
//! ([`anonymize.rs:258-263`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
//! "This deliberately preserves character equality patterns and is
//! consequently a substitution cipher, not cryptographic protection."
//! **This file is not a privacy tool.** It removes the obvious content of a
//! document so it can be filed as a bug; it does not resist anyone who knows
//! the seed.
//!
//! # What a key is and a text run is not
//!
//! Both are strings on the wire and they are replaced by **two different
//! rules**, and the difference is the whole reason this file has two string
//! functions:
//!
//! * A **map key and a mark name** are *structural*. Whitespace, control
//!   characters and every other character go through the structural
//!   permutation ([`anonymize.rs:216-224`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
//!   and a key is a fixed point of the permutation, so **the same key becomes
//!   the same replacement everywhere in the document**. Without that the
//!   document's key set stops being a function of its content: `"name"` in one
//!   object and `"name"` in another would answer to two different keys.
//! * A **commit message and a string value** are *content*. Whitespace and
//!   ASCII control characters are **retained verbatim** so words and lines
//!   survive, ASCII letters and digits are replaced from a shuffled synthetic
//!   alphabet, and everything else goes through a second, independent
//!   permutation ([`anonymize.rs:226-238`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
//!
//! # The seed is a parameter
//!
//! Upstream's entry point draws its own seed ([`anonymize.rs:27-29`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs))
//! because `rand::make_rng()` is infallible. **Zig 0.16 has no source of
//! randomness in `std`** — the same finding [`types.zig:99-112`](types.zig)
//! records for actor ids — so [`anonymize`] takes the 32 seed bytes as a
//! parameter instead of pretending to have entropy it does not have. A caller
//! that wants a fresh seed draws 32 bytes itself; a caller that wants a
//! reproducible document passes a fixed seed, which is what the tests do.
//!
//! # What this file does not do
//!
//! * **It does not resolve, merge, or reorder anything.** Every op survives,
//!   in its change, in its place. A delete is still a delete and a conflict is
//!   still a conflict with the same number of predecessors.
//! * **It does not touch the document format.** The bytes it writes are a
//!   change chunk body laid out by [`storage/change_chunk.zig`]'s
//!   `encodeBody`, which is the port's writer, and the result is re-parsed
//!   before it is applied — so a body this file produced is a body the
//!   port's own reader accepted.
//! * **It does not anonymize the string intern table directly.** A document
//!   chunk interns its strings, and the keys arrive renamed because the op
//!   rows that carry them are renamed.
//!
//! # Ownership rules
//!
//! * These values have one owner. Do not shallow-copy them.
//!   Move them only when no caller retains their address.
//! * Every [`Anonymize`]'s arenas and permutation tables are released by
//!   `Anonymize.deinit`; every [`Shape`]'s by `Shape.deinit`.
//! * **`Anonymize` owns two arenas because it has two lifetimes.** One change's
//!   rewritten bytes die at the end of that change and go back to the allocator;
//!   the actor map outlives every change in the document and does not. A
//!   borrow from the first is good until the next change; a borrow from the
//!   second is good until `deinit`. Which is which is stated on each field and
//!   is not to be guessed at a call site.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const valuemod = @import("value.zig");
const changerec = @import("change.zig");
const changechunk = @import("storage/change_chunk.zig");
const colspec = @import("storage/column_spec.zig");
const columnarenc = @import("columnar/encoding.zig");
const docmod = @import("doc.zig");
const opitermod = @import("opset/op_iter.zig");
const optypes = @import("opset/types.zig");

const Allocator = std.mem.Allocator;
const Action = valuemod.Action;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Built = docmod.Built;
const Cell = columnarenc.Cell;
const Change = changerec.Change;
const ChangeHash = types.ChangeHash;
const ColumnDesc = colspec.ColumnDesc;
const ColumnSpec = colspec.ColumnSpec;
const Document = docmod.Document;
const Error = err.Error;
const ElemId = types.ElemId;
const ExId = types.ExId;
const KeyRef = optypes.KeyRef;
const InternalError = err.InternalError;
const ObjType = types.ObjType;
const OpColumn = changechunk.OpColumn;
const OpId = types.OpId;
const ParseError = err.ParseError;
const RawColumns = colspec.RawColumns;
const ScalarValue = valuemod.ScalarValue;
const TextEncoding = types.TextEncoding;

/// The alphabet a content string's ASCII letters are replaced from
/// ([`SYNTHETIC_TEXT`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
/// at [`anonymize.rs:8`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
/// shuffled with the seed). Forty-nine distinct letters, so a byte always has
/// a replacement that differs from it in at most two draws.
const SYNTHETIC_TEXT = "loremipsumdolorsitametconsecteturadipiscingelit";

/// The seed [`anonymize`] takes: thirty-two bytes, exactly upstream's
/// `Anonymization::from_seed([u8; 32])` argument
/// ([`anonymize.rs:53-58`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
pub const seed_length = 32;

/// What [`anonymize`] and [`Anonymize.run`] can raise.
///
/// Upstream's `AnonymizeError` ([`anonymize.rs:10-24`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs))
/// has two variants. This set is [`docmod.DocumentError`] plus one variant of
/// its own, because Zig has one error namespace and [`error.zig`](error.zig)
/// splits it three ways, and because a rewrite has to *read* a document before
/// it can write one. The mapping:
///
/// | upstream | here | why |
/// | --- | --- | --- |
/// | `Apply(AutomergeError)` | [`docmod.DocumentError`] | the document API's own set, reached both by reading the source and by applying the rewritten changes |
/// | `MissingDependency { change, dependency }` | `error.MissingDependency` | a document read out of dependency order, not untrusted bytes |
/// | — | [`ParseError`] | decoding and re-encoding a change's columns ([`storage/change_chunk.zig`](storage/change_chunk.zig), [`columnar/encoding.zig`](columnar/encoding.zig)) |
/// | — | [`InternalError`] | the checks upstream reaches with `expect`, which this port reports instead of trapping |
///
/// [`docmod.DocumentError`] is [`doc.zig`](doc.zig)'s own union of
/// `ParseError`, [`Error`], [`InternalError`] and the op set's load errors, so
/// nothing is added here beyond `MissingDependency`.
pub const AnonymizeError = docmod.DocumentError || error{MissingDependency};

/// A new document with `document`'s history replayed into it, every actor id,
/// key string, commit message and scalar replaced, and its shape kept.
///
/// `seed` is thirty-two bytes; see the module documentation for why it is a
/// parameter. Two calls with the same seed and the same document produce the
/// same document, which is upstream's own property
/// ([`anonymize.rs:474-475`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs))
/// and what makes the tests below possible.
///
/// `document` is taken by pointer because this port's `getChanges`
/// **re-encodes** every change from the op set rather than handing back stored
/// bytes ([`doc.zig:3377-3389`](doc.zig)); upstream's `get_changes(&[])`
/// returns the stored chunks and takes `&Automerge`
/// ([`anonymize.rs:61`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
///
/// The returned document must be freed by the caller with
/// [`Document.deinit`], and it is a *fresh* document: the source is untouched.
pub fn anonymize(
    gpa: Allocator,
    document: *Document,
    seed: [seed_length]u8,
) AnonymizeError!Document {
    var anon = try Anonymize.init(gpa, seed);
    defer anon.deinit();
    return try anon.run(document);
}

/// The two arenas an [`Anonymize`] owns, created together or not at all.
///
/// **This exists so that exactly one owner is armed at a time.** `init` can
/// fail twice over — once while creating the arenas, once at
/// `ensureTotalCapacity` — and each failure has to release the arenas. If the
/// per-`create` `errdefer`s were still armed when `Anonymize.deinit` took over,
/// the arena *structs* would be destroyed twice on that second path, which is
/// the double free this file's own [`ActorMap.deinit`] note warns about. Here
/// the two cleanups are on disjoint paths: before `Arenas.create` returns,
/// `Arenas.deinit` owns them; after, `Anonymize.deinit` does.
const Arenas = struct {
    /// One change's rewritten strings, byte runs and scalar rows. Reset at the
    /// end of every change by [`Anonymize.run`].
    scratch: *std.heap.ArenaAllocator,
    /// The [`ActorMap`], and nothing else. Never reset.
    actors: *std.heap.ArenaAllocator,

    /// Both arenas, or neither. The first `create` failing has nothing else to
    /// release; the second failing releases the first and itself.
    fn create(gpa: Allocator) Allocator.Error!Arenas {
        const scratch = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(scratch);
        scratch.* = .init(gpa);
        const actors = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(actors);
        actors.* = .init(gpa);
        return .{ .scratch = scratch, .actors = actors };
    }

    /// Releases both arenas' contents and the two structs themselves.
    fn deinit(self: Arenas, gpa: Allocator) void {
        self.scratch.deinit();
        self.actors.deinit();
        gpa.destroy(self.scratch);
        gpa.destroy(self.actors);
    }
};

/// One seeded anonymization: the permutations, the synthetic alphabet, the
/// actor map, the hash map, and the two arenas the rewritten bytes belong to.
///
/// Upstream's `Anonymization` ([`anonymize.rs:31-51`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
/// Owns the arenas and tables. A shallow copy is not a second owner.
/// The allocator must remain live through `deinit`.
pub const Anonymize = struct {
    /// The allocator every buffer in this struct belongs to, except the arena's
    /// own bookkeeping.
    gpa: Allocator,
    /// The seeded generator. ChaCha8, which is what `rand`'s `StdRng` is
    /// ([`anonymize.rs:3`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
    /// so the port's numbers come from the same family and the same 32-byte
    /// seed argument.
    prng: std.Random.ChaCha,
    /// The permutation for structural strings: map keys and mark names.
    structural: Permutations = .{},
    /// The permutation for the non-ASCII half of a content string: commit
    /// messages and string values. Independent of `structural`, so the same
    /// character in a key and in a value does not become the same replacement.
    content: Permutations = .{},
    /// `SYNTHETIC_TEXT`, shuffled by the seed
    /// ([`anonymize.rs:41-43`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    synthetic_text: [SYNTHETIC_TEXT.len]u8 = SYNTHETIC_TEXT.*,
    /// Where the next synthetic byte comes from, wrapping. A **cursor**, not a
    /// per-character draw: two identical original bytes therefore get two
    /// different replacements, and a run of letters does not collapse onto one
    /// letter.
    synthetic_position: usize = 0,
    /// Owned, heap-allocated arena for the rewritten strings, byte runs and
    /// scalar rows of **one change**. [`run`](run) resets it at the end of
    /// every change, so its high-water mark is one change and not every change
    /// the document has.
    ///
    /// **A borrow from here is good until the end of the change that made it,
    /// and not one moment longer.** [`mapActor`] is the exception and it is
    /// not in here: it answers out of `actor_arena`, which no reset touches.
    arena: *std.heap.ArenaAllocator,
    /// Owned, heap-allocated arena for the [`ActorMap`] and nothing else.
    ///
    /// **This one is never reset, and being a second arena is the whole reason
    /// the reset above is sound.** The map is built once, before the first
    /// change ([`buildActorMap`](buildActorMap)), and `mapActor` reads it on
    /// every change and on every actor of it — so a map that lived in `arena`
    /// would be freed by the first reset, and every actor after it would be
    /// answered out of memory the next column had already reused. It is
    /// `O(distinct actors)`, which is tens of sixteen-byte entries, so keeping
    /// it for the whole run costs nothing beside the per-change bytes the
    /// reset gives back.
    actor_arena: *std.heap.ArenaAllocator,
    /// The source actor set, sorted, mapped to fresh ids. An empty map is a
    /// document with no changes.
    actors: ActorMap = .{ .entries = &.{} },
    /// Old change hash to new change hash, filled as the changes are applied.
    /// A dependency is a hash, and the hash it becomes is only known once the
    /// dependency has been rewritten, so this is what turns the source's
    /// dependency edges into the result's
    /// ([`anonymize.rs:70-81`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    hashes: std.AutoHashMapUnmanaged(ChangeHash, ChangeHash) = .empty,

    /// A fresh anonymization from a 32-byte seed. Allocates the arenas and the
    /// hash map, so it can fail; free the result with `deinit`.
    ///
    /// **The two failure paths release the arenas from two different places
    /// and neither runs twice.** `Arenas.create` failing leaves `self` unbuilt
    /// and disposes of whatever it had made; `ensureTotalCapacity` failing
    /// leaves `self` built, and disposes through `Arenas.deinit` rather than
    /// `Anonymize.deinit`, because the caller has not received `self` and so
    /// will never call the latter.
    pub fn init(gpa: Allocator, seed: [seed_length]u8) Allocator.Error!Anonymize {
        const arenas = try Arenas.create(gpa);
        var self: Anonymize = .{
            .gpa = gpa,
            .prng = std.Random.ChaCha.init(seed),
            .arena = arenas.scratch,
            .actor_arena = arenas.actors,
        };
        errdefer arenas.deinit(gpa);
        try self.hashes.ensureTotalCapacity(gpa, 16);
        self.shuffleSyntheticText();
        return self;
    }

    /// Releases both arenas, the permutation tables, the actor map and the
    /// hash map. Everything a run allocated goes with one of the two arenas.
    /// The value is `undefined` afterward. Dispose exactly once.
    pub fn deinit(self: *Anonymize) void {
        self.structural.deinit(self.gpa);
        self.content.deinit(self.gpa);
        self.actors.deinit();
        self.hashes.deinit(self.gpa);
        self.arena.deinit();
        self.actor_arena.deinit();
        self.gpa.destroy(self.arena);
        self.gpa.destroy(self.actor_arena);
        self.* = undefined;
    }

    /// The document's history, rewritten, as a new document.
    ///
    /// Changes go in dependency order — `getChanges` promises it
    /// ([`doc.zig:3373-3389`](doc.zig)) — which is what lets a dependency be
    /// mapped through `hashes` before the change that needs it. A change whose
    /// dependency is not in the map is `error.MissingDependency`
    /// ([`anonymize.rs:74-79`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
    /// which for a document that came out of `getChanges` means the document is
    /// inconsistent with itself.
    ///
    /// The result measures text the way the source does
    /// ([`anonymize.rs:64`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
    /// because the changes being applied index text in that encoding.
    pub fn run(self: *Anonymize, document: *Document) AnonymizeError!Document {
        var changes = try document.getChanges(self.gpa, &.{});
        defer changes.deinit(self.gpa);
        try self.buildActorMap(changes.slice());

        var out = try Document.initWithEncoding(self.gpa, document.io, document.textEncoding(), document.documentMode());
        // **On failure nothing has moved into `out` that `out` does not own**:
        // every change is applied, and a failure inside `applyChanges` frees
        // what it copied. So this one `errdefer` is right and needs no second
        // path.
        errdefer out.deinit();

        for (changes.slice()) |built| {
            var next = try self.rewriteChange(built.change);
            // `applyChanges` **copies** the change into the document's arena
            // before screening it — `adoptChange` dupes `change.bytes` and
            // re-parses from the copy ([`doc.zig:4882-4884`](doc.zig)) — so the
            // body and the actor list this owns are dead the moment it
            // returns, and it is the copy the document keeps.
            defer next.deinit(self.gpa);
            _ = try out.applyChanges(self.gpa, &.{next.change});
            try self.hashes.put(self.gpa, built.change.hash, next.change.hash);

            // ── The reset boundary ──────────────────────────────────────────
            //
            // Everything this change put in `self.arena` is dead here, and
            // this is where that is said instead of being left to `deinit`.
            // `rewriteChange` builds its result in the arena — the commit
            // message, the column payloads, the footer — and **every one of
            // those is copied out of the arena before this line**, which is the
            // property the reset depends on:
            //
            // * `encodeHeader` copies the message into the body
            //   ([`change.zig:218`](change.zig)), and `parseChange` reads it
            //   back out of *that* body, so the returned `Built` borrows
            //   `gpa` memory and not the arena
            //   ([`change.zig:396-398`](change.zig));
            // * `writeOpsBlock` copies the footer
            //   ([`change_chunk.zig:712`](storage/change_chunk.zig));
            // * `encodeColumn` and `encodeValuePair` serialize string and
            //   scalar payloads into their own `gpa` buffers, and say so —
            //   "`values` is borrowed and the result is not"
            //   ([`encoding.zig:1275-1282`](columnar/encoding.zig)).
            //
            // So the peak is **one change** rather than every change the
            // document has, and on a long history that is the difference
            // between a bounded arena and one that grows with the document.
            //
            // **`.retain_capacity` and not `.free_all`, because the next change
            // wants an arena too**: handing the memory back and asking for it
            // again once per change is an allocation per change to no end.
            // What is retained is the high-water of the change just finished,
            // so the peak is still one change.
            //
            // **The `false` is discarded, and that is not a suppressed
            // failure.** `reset` answers `false` when a child reallocation did
            // not fit, and the arena is fully usable afterwards either way: it
            // has released everything, and the next allocation grows a buffer.
            // Nothing that runs after this line reads the arena, so there is no
            // correctness question for the answer to decide, and turning it
            // into an error would refuse a rewrite that is already correct.
            //
            // **`error.OutOfMemory` never reaches here and needs no path.** The
            // three statements above it return through `errdefer out.deinit()`
            // and the caller's `Anonymize.deinit`, and `rewriteChange`'s own
            // `errdefer`s return the partial body to `gpa`; nothing survives
            // into a later change, and nothing is owed to this line. A retry
            // from the caller therefore starts from a whole `Anonymize`.
            _ = self.arena.reset(.retain_capacity);
        }
        return out;
    }

    // ── The actor map ──────────────────────────────────────────────────────

    /// The source's distinct actors, in lexicographic order, each mapped to a
    /// fresh sixteen-byte id
    /// ([`anonymize.rs:103-126`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// **The rank goes in the low eight bytes and a random prefix in the high
    /// eight, and that is not decoration.** Two documents must agree about
    /// *which* actor is first, because [`Shape`] identifies a change by the
    /// rank of its author ([`shape.rs:313-323`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    /// A prefix that is the same for every actor preserves the source's
    /// lexicographic order in the result, so the rank of an actor is the same
    /// on both sides of the rewrite.
    ///
    /// The loop retries while a mapped id **collides with a source actor**,
    /// which is the case that matters: a collision would leave an actor
    /// unreplaced, and a test that counts actors would not see it. Mapped ids
    /// cannot collide with each other, because the rank is in the id.
    fn buildActorMap(self: *Anonymize, changes: []const Built) Allocator.Error!void {
        var actors: std.ArrayList(ActorId) = .empty;
        defer actors.deinit(self.gpa);
        for (changes) |built| {
            try actors.append(self.gpa, built.change.actor);
            try actors.appendSlice(self.gpa, built.change.other_actors);
        }
        // The source set is a sorted set (`BTreeSet` at `anonymize.rs:108`).
        std.mem.sort(ActorId, actors.items, {}, ActorId.lessThan);
        var unique: std.ArrayList(ActorId) = .empty;
        defer unique.deinit(self.gpa);
        for (actors.items) |actor| {
            if (unique.items.len != 0 and unique.items[unique.items.len - 1].eql(actor)) continue;
            try unique.append(self.gpa, actor);
        }

        var trial: std.ArrayList([16]u8) = .empty;
        defer trial.deinit(self.gpa);
        while (true) {
            var prefix: [8]u8 = undefined;
            self.random().bytes(&prefix);
            trial.clearRetainingCapacity();
            var collides = false;
            for (unique.items, 0..) |_, rank| {
                var id: [16]u8 = undefined;
                @memcpy(id[0..8], &prefix);
                std.mem.writeInt(u64, id[8..16], @intCast(rank), .big);
                if (findActor(unique.items, id[0..]) != null) collides = true;
                try trial.append(self.gpa, id);
            }
            if (collides) continue;

            // **The actor arena, never the reset one.** This is the value that
            // outlives every change, so it is the value a per-change reset
            // would take away from `mapActor` mid-run.
            const arena = self.actor_arena.allocator();
            const entries = try arena.alloc(ActorMap.Entry, trial.items.len);
            for (trial.items, 0..) |id, rank| {
                entries[rank] = .{
                    .from = try arena.dupe(u8, unique.items[rank].bytes),
                    .to = .{ .bytes = try arena.dupe(u8, id[0..]) },
                };
            }
            // The source set was sorted, and the prefix is shared, so the
            // entries come out in the same order and `lookup`'s binary search
            // is on a sorted table.
            self.actors.deinit();
            self.actors = .{ .entries = entries };
            return;
        }
    }

    /// Fresh borrowed id for `actor`, or `error.MissingActor` if absent.
    ///
    /// Upstream panics here ([`anonymize.rs:365-370`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs));
    /// the port's rule is a named error, and this is the honest name: a column
    /// or a header named an actor the change's own actor list does not carry
    /// ([`error.MissingActor`](error.zig)).
    pub fn mapActor(self: *const Anonymize, actor: ActorId) ParseError!ActorId {
        return self.actors.lookup(actor) orelse error.MissingActor;
    }

    // ── One change ─────────────────────────────────────────────────────────

    /// One change, rewritten: the header's actor, dependencies, time, message
    /// and extra bytes, and the three columns that carry private data.
    ///
    /// The change is **re-parsed** from the bytes this wrote, which does two
    /// things at once: it gives the caller a [`Built`] whose `Change` borrows a
    /// body with a real `header_len` and an owned `other_actors` array — what
    /// every downstream reader expects — and it makes the re-parse a check that
    /// the bytes are bytes the port's own reader accepts
    /// ([`doc.zig:2006-2047`](doc.zig) does the same for the same reason).
    fn rewriteChange(self: *Anonymize, change: Change) AnonymizeError!Built {
        var block = try changechunk.parseChangeChunk(change.bytes, self.gpa);
        defer block.deinit(self.gpa);
        var cols = try OpColumns.init(self.gpa, block.ops);
        defer cols.deinit(self.gpa);

        var descs: std.ArrayList(ColumnDesc) = .empty;
        defer descs.deinit(self.gpa);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.gpa);

        // **The source's column set is the result's column set.** The columns
        // are in ascending normalized order (`parseChangeChunk` proved it) and
        // the writer demands that order
        // ([`change_chunk.zig:564-608`](storage/change_chunk.zig)), so
        // appending in iteration order keeps it. A column this file does not
        // rewrite is copied byte for byte, which is what keeps a column the
        // fourteen do not name — a successor column, or an id this version
        // does not know — from being silently dropped the way a row-level
        // rebuild would drop it.
        var pair_written = false;
        for (block.ops.columns) |col| {
            const bytes = try col.bytes(block.ops.data);
            const op = OpColumn.fromSpec(col.spec);
            if (op == null) {
                try pushColumn(self.gpa, &descs, &data, col.spec, bytes);
                continue;
            }
            switch (op.?) {
                .key_string => try self.rewriteStringColumn(.key_string, col.spec, bytes, &descs, &data),
                .mark_name => try self.rewriteStringColumn(.mark_name, col.spec, bytes, &descs, &data),
                .value_metadata => {
                    const pair = try self.rewriteValuePair(cols.values orelse return error.UnexpectedEnd);
                    defer pair.deinit(self.gpa);
                    // **The payload half is written only when it has bytes**,
                    // which is the writer's rule: a column with no bytes is not
                    // a column ([`change_op_columns.rs:332-337`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)).
                    try pushColumn(self.gpa, &descs, &data, pair.meta.spec, pair.meta.bytes);
                    if (pair.raw.bytes.len != 0) {
                        try pushColumn(self.gpa, &descs, &data, pair.raw.spec, pair.raw.bytes);
                    }
                    pair_written = true;
                },
                // A payload half with no metadata half beside it is not a shape
                // any writer produces; copying it is the only answer that keeps
                // the document's column set unchanged.
                .value => if (!pair_written) try pushColumn(self.gpa, &descs, &data, col.spec, bytes),
                else => try pushColumn(self.gpa, &descs, &data, col.spec, bytes),
            }
        }

        // The actor list **position for position**: the author's replacement
        // first, then each named actor's replacement in the source's order, so
        // every actor index a column holds still names the same actor's
        // replacement.
        var others: std.ArrayList(ActorId) = .empty;
        defer others.deinit(self.gpa);
        for (change.other_actors) |other| {
            try others.append(self.gpa, try self.mapActor(other));
        }

        var deps: std.ArrayList(ChangeHash) = .empty;
        defer deps.deinit(self.gpa);
        for (change.deps) |dep| {
            const mapped = self.hashes.get(dep) orelse return error.MissingDependency;
            try deps.append(self.gpa, mapped);
        }

        const header = Change{
            .bytes = &.{},
            .header_len = 0,
            .actor = try self.mapActor(change.actor),
            .deps = deps.items,
            .hash = ChangeHash.zero,
            .time = self.randomI64OtherThan(change.time),
            // An absent message and an empty one are one value here
            // ([`change.zig:116-120`](change.zig)), and a content string of
            // nothing is nothing, so there is no branch.
            .message = try self.anonymizeContentString(change.message),
            .seq = change.seq,
            .start_op = change.start_op,
            .max_op = change.max_op,
            .other_actors = others.items,
        };
        const raw_cols = try RawColumns.init(self.gpa, descs.items, data.items);
        defer raw_cols.deinit(self.gpa);

        // The extra bytes are anonymized **as bytes, structure and all**
        // ([`anonymize.rs:88`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
        // the author footer is `uleb(1) || uleb(len) || bytes`
        // ([`change.rs:365-403`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
        // and replacing those two length bytes destroys the framing. **That is
        // upstream's rule and it is correct here**: the author name is private
        // data, the result is the same byte count, and a reader that finds the
        // footer id is not `1` reports no author rather than failing
        // ([`doc.zig:1571-1579`](doc.zig)).
        const footer = try self.anonymizeBytes(block.footer);
        const body = try changechunk.encodeBody(self.gpa, header, .{
            .cols = raw_cols,
            .footer = footer,
        });
        errdefer self.gpa.free(body);
        const rewritten = changerec.parseChange(body, self.gpa) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return e,
        };
        return .{ .body = body, .change = rewritten };
    }

    /// One string column, rewritten through the **structural** permutation,
    /// and appended to the new column set.
    ///
    /// Absent rows stay absent: a key that is not a string key and a mark row
    /// that is not a mark begin are `null` in this column, and there is no
    /// third case.
    fn rewriteStringColumn(
        self: *Anonymize,
        which: StringColumn,
        spec: ColumnSpec,
        bytes: []const u8,
        descs: *std.ArrayList(ColumnDesc),
        data: *std.ArrayList(u8),
    ) (ParseError || InternalError)!void {
        const cells = try columnarenc.decodeAll(self.gpa, spec, bytes);
        defer self.gpa.free(cells);
        const out = try self.gpa.alloc(Cell, cells.len);
        defer self.gpa.free(out);
        for (cells, 0..) |cell, i| {
            out[i] = switch (cell) {
                .string => |name| .{ .string = try self.anonymizeStructuralString(name) },
                else => cell,
            };
        }
        const encoded = try columnarenc.encodeColumn(self.gpa, spec.id(), spec.encoding(), out);
        defer encoded.deinit(self.gpa);
        try pushColumn(self.gpa, descs, data, spec, encoded.bytes);
        _ = which;
    }

    /// The value pair, rewritten scalar by scalar and re-encoded as a pair.
    ///
    /// **The pair is the unit, not the value.** A replacement scalar need not
    /// have the source's byte length — a string's length is fixed by the
    /// permutation's class, but an `Int` drawn from the `i32` domain
    /// ([`anonymize.rs:184-194`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs))
    /// has a different LEB128 width than the original — so the payload column
    /// and the metadata column that describes it have to be written together.
    fn rewriteValuePair(self: *Anonymize, values: []const ScalarValue) AnonymizeError!columnarenc.ValuePair {
        const arena = self.arena.allocator();
        const out = try arena.alloc(ScalarValue, values.len);
        for (values, 0..) |v, i| out[i] = try self.anonymizeScalar(v);
        return columnarenc.encodeValuePair(self.gpa, OpColumn.value_metadata.id(), out);
    }

    // ── The scalars ────────────────────────────────────────────────────────

    /// One scalar, replaced with another of the same type
    /// ([`anonymize.rs:160-182`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// **The type is never changed**, which is what makes the rewrite invisible
    /// to the reader: an `Int` stays an `Int`, a `Counter` stays a `Counter`,
    /// and `Null` stays `Null` because `Null` has no other value of its own
    /// type. A `Boolean` is the one case that may come back unchanged, and
    /// upstream says so ([`shape.rs:428-430`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)):
    /// half the draws are the same bit.
    ///
    /// The result borrows the [`Anonymize`]'s per-change arena, so it is valid
    /// until the end of the change being rewritten — which is where [`run`]
    /// resets that arena — and not merely until `Anonymize.deinit`. A caller
    /// that needs it longer has to copy it out.
    pub fn anonymizeScalar(self: *Anonymize, v: ScalarValue) AnonymizeError!ScalarValue {
        return switch (v) {
            .null_value => .null_value,
            .bool_value => .{ .bool_value = self.random().boolean() },
            .int => |x| .{ .int = self.randomI64OtherThan(x) },
            .uint => |x| .{ .uint = self.randomU64OtherThan(x) },
            .float => |x| .{ .float = self.randomF64OtherThan(x) },
            .counter => |c| .{ .counter = .init(self.randomI64OtherThan(c.current)) },
            .timestamp => |x| .{ .timestamp = self.randomI64OtherThan(x) },
            .str => |s| .{ .str = try self.anonymizeContentString(s) },
            .bytes => |b| .{ .bytes = try self.anonymizeBytes(b) },
            .unknown => |u| .{ .unknown = .{
                .type_code = u.type_code,
                .bytes = try self.anonymizeBytes(u.bytes),
            } },
            // **A port-only case.** The port's `ScalarValue` has an
            // `actor_id` variant that upstream's does not, and an actor id is
            // private data, so it is mapped through the actor table rather than
            // byte-replaced. It cannot arrive from a change chunk: the wire
            // carries an actor reference as an opaque byte payload and reads
            // back as `bytes` ([`encoding.zig:1406-1416`](columnar/encoding.zig)).
            .actor_id => |a| blk: {
                const mapped = try self.mapActor(a);
                break :blk ScalarValue{ .actor_id = .{ .bytes = mapped.bytes } };
            },
        };
    }

    /// A signed integer that is not `original`
    /// ([`anonymize.rs:184-194`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// **The `i32` domain is upstream's and it is not incidental**: signed
    /// integer columns are delta encoded, so a change whose counters swing
    /// across the whole `i64` range would need deltas that do not fit. Upstream
    /// says so at [`anonymize.rs:186-189`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
    /// and this file keeps the same domain for the same reason.
    pub fn randomI64OtherThan(self: *Anonymize, original: i64) i64 {
        while (true) {
            const replacement: i64 = @intCast(self.random().int(i32));
            if (replacement != original) return replacement;
        }
    }

    /// An unsigned integer that is not `original`
    /// ([`anonymize.rs:196-203`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    pub fn randomU64OtherThan(self: *Anonymize, original: u64) u64 {
        while (true) {
            const replacement = self.random().int(u64);
            if (replacement != original) return replacement;
        }
    }

    /// A float whose **bit pattern** is not `original`'s
    /// ([`anonymize.rs:205-214`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// The comparison is on the bits rather than on `==` because `0.0` and
    /// `-0.0` compare equal and are different encodings, and because `NaN !=
    /// NaN` would let a draw through that did not change the bytes.
    pub fn randomF64OtherThan(self: *Anonymize, original: f64) f64 {
        while (true) {
            const replacement: f64 = self.random().float(f64);
            if (@as(u64, @bitCast(replacement)) != @as(u64, @bitCast(original))) return replacement;
        }
    }

    // ── The strings ────────────────────────────────────────────────────────

    /// A **structural** string — a map key or a mark name — with every
    /// character replaced through the structural permutation
    /// ([`anonymize.rs:216-224`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// Every character goes through the permutation, **including whitespace
    /// and control characters**, which is what distinguishes it from
    /// [`anonymizeContentString`]. The permutation is a derangement per
    /// encoding class, so no character maps to itself and a character's width is
    /// the same in the result: the result has the same byte length and the same
    /// UTF-16 length as the source, character for character.
    ///
    /// **Consistency across the document is a property of the permutation, not
    /// of a lookup table**: the same character always maps to the same
    /// replacement because the table is one table for the whole run, so the
    /// same key is the same replacement in every object it appears in.
    ///
    /// The result borrows the [`Anonymize`]'s per-change arena, so it is valid
    /// until the end of the change being rewritten and not longer.
    pub fn anonymizeStructuralString(self: *Anonymize, value: []const u8) (ParseError || InternalError)![]const u8 {
        return self.mapCodepoints(value, &self.structural);
    }

    /// A **content** string — a commit message or a `Str` value — with
    /// whitespace and ASCII control characters kept, ASCII letters replaced
    /// from the shuffled synthetic alphabet, and everything else replaced
    /// through the content permutation
    /// ([`anonymize.rs:226-238`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// **Retaining whitespace and control characters is the point**: a message
    /// stays a message with the same words' worth of words and the same line
    /// structure, and only the letters change. It is also the one rule a test
    /// has to know about, because it means a one-character value of a space
    /// comes back unchanged by design.
    ///
    /// The result borrows the [`Anonymize`]'s per-change arena, so it is valid
    /// until the end of the change being rewritten and not longer. The commit
    /// message this makes for a change is copied into the body before the
    /// change is returned, so the caller does not have to.
    pub fn anonymizeContentString(self: *Anonymize, value: []const u8) (ParseError || InternalError)![]const u8 {
        if (value.len == 0) return &.{};
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.arena.allocator());
        var view = try std.unicode.Utf8View.init(value);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
            if (isUnicodeWhitespace(cp) or isAsciiControl(cp)) {
                try out.appendSlice(self.arena.allocator(), slice);
            } else if (cp < 0x80) {
                try out.append(self.arena.allocator(), self.randomSyntheticByte(@intCast(cp)));
            } else {
                try appendCodepoint(
                    self.arena.allocator(),
                    &out,
                    try self.content.replace(self.gpa, self.random(), cp),
                );
            }
        }
        return out.toOwnedSlice(self.arena.allocator());
    }

    /// Every byte replaced from the shuffled synthetic alphabet
    /// ([`anonymize.rs:240-245`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    /// The length never changes, which is what keeps a `Bytes` value's shape.
    ///
    /// The result borrows the [`Anonymize`]'s per-change arena, so it is valid
    /// until the end of the change being rewritten and not longer.
    pub fn anonymizeBytes(self: *Anonymize, value: []const u8) ParseError![]const u8 {
        if (value.len == 0) return &.{};
        const arena = self.arena.allocator();
        const out = try arena.alloc(u8, value.len);
        for (value, 0..) |byte, i| out[i] = self.randomSyntheticByte(byte);
        return out;
    }

    /// The next byte of the shuffled synthetic alphabet, skipping a draw that
    /// would leave the byte unchanged ([`anonymize.rs:247-255`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    ///
    /// The alphabet has forty-nine distinct letters and the cursor advances on
    /// every draw, so the loop runs at most twice: the only way the second draw
    /// also matches is if it wrapped all the way round, which a full lap of
    /// forty-nine draws on a one-byte value cannot do inside two.
    fn randomSyntheticByte(self: *Anonymize, original: u8) u8 {
        while (true) {
            const replacement = self.synthetic_text[self.synthetic_position];
            self.synthetic_position = (self.synthetic_position + 1) % self.synthetic_text.len;
            if (replacement != original) return replacement;
        }
    }

    /// Every character of `value` through `table`, into the arena.
    fn mapCodepoints(self: *Anonymize, value: []const u8, table: *Permutations) (ParseError || InternalError)![]const u8 {
        if (value.len == 0) return &.{};
        const arena = self.arena.allocator();
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(arena);
        var view = try std.unicode.Utf8View.init(value);
        var it = view.iterator();
        while (it.nextCodepointSlice()) |slice| {
            const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
            try appendCodepoint(arena, &out, try table.replace(self.gpa, self.random(), cp));
        }
        return out.toOwnedSlice(arena);
    }

    /// A `Random` over this struct's generator. Taken fresh at each call site
    /// because it borrows the generator, and the generator lives in a struct
    /// that is moved when it is built.
    fn random(self: *Anonymize) std.Random {
        return self.prng.random();
    }

    /// Shuffles `synthetic_text` with the seed and picks the starting cursor
    /// ([`anonymize.rs:40-50`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    fn shuffleSyntheticText(self: *Anonymize) void {
        var rng = self.random();
        var i = self.synthetic_text.len;
        while (i > 1) {
            i -= 1;
            const j = rng.uintLessThan(usize, i + 1);
            std.mem.swap(u8, &self.synthetic_text[i], &self.synthetic_text[j]);
        }
        self.synthetic_position = rng.uintLessThan(usize, self.synthetic_text.len);
    }
    /// [`Anonymize.run`] with the reset line deleted and nothing else changed.
    ///
    /// **It is here to be the other side of a differential, and its value is that
    /// it is a copy.** The arena consumes no randomness — every draw comes from
    /// the generator, and an allocation draws nothing — so two runs over the same
    /// document from the same seed take the same numbers however the arena is
    /// managed, and their outputs can differ only if a reset handed back memory
    /// that a later change was still reading. Comparing this against `run` is
    /// therefore a test of the escape analysis the reset rests on, rather than
    /// another statement of it.
    fn runWithoutReset(self: *Anonymize, document: *Document) AnonymizeError!Document {
        var changes = try document.getChanges(self.gpa, &.{});
        defer changes.deinit(self.gpa);
        try self.buildActorMap(changes.slice());

        var out = try Document.initWithEncoding(self.gpa, document.io, document.textEncoding(), document.documentMode());
        errdefer out.deinit();

        for (changes.slice()) |built| {
            var next = try self.rewriteChange(built.change);
            defer next.deinit(self.gpa);
            _ = try out.applyChanges(self.gpa, &.{next.change});
            try self.hashes.put(self.gpa, built.change.hash, next.change.hash);
        }
        return out;
    }
};

/// Which of the two string columns a rewrite is for. The value is not read —
/// both are rewritten by the same code — and **it is a parameter rather than a
/// guess so that adding a third string column is a change to this enum** and
/// not a change to a call site that happens to be right.
const StringColumn = enum { key_string, mark_name };

/// Appends one column to the new set: its bytes to the data block and its
/// descriptor to the metadata list, in that order.
fn pushColumn(
    gpa: Allocator,
    descs: *std.ArrayList(ColumnDesc),
    data: *std.ArrayList(u8),
    spec: ColumnSpec,
    bytes: []const u8,
) Allocator.Error!void {
    try data.appendSlice(gpa, bytes);
    try descs.append(gpa, .init(spec, bytes.len));
}

/// One actor's place in the map, and where it goes.
const ActorMap = struct {
    /// The source actors and their replacements, in the source's
    /// lexicographic order.
    entries: []Entry,

    const Entry = struct {
        /// The source actor's bytes, copied into the **actor arena** so the map
        /// outlives every change that reads it. `arena` would be reset out from
        /// under it.
        from: []const u8,
        /// The replacement's bytes, in the actor arena for the same reason.
        to: ActorId,
    };

    /// The replacement for `actor`, or null.
    ///
    /// A binary search over a sorted table, because a document has tens of
    /// actors and this is the innermost call in the rewrite.
    fn lookup(self: ActorMap, actor: ActorId) ?ActorId {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].from, actor.bytes)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.entries[mid].to,
            }
        }
        return null;
    }

    /// The entries belong to the [`Anonymize`]'s **actor arena**, which no reset
    /// touches, so this **clears the reference and frees nothing**. An earlier
    /// version freed them with `gpa` and that is a double free: the arena frees
    /// them too, and freeing arena memory with the allocator that owns the arena
    /// is an invalid free even when it happens only once.
    fn deinit(self: *ActorMap) void {
        self.entries = &.{};
    }
};

/// Whether `actor` is in the sorted list `actors`.
fn findActor(actors: []const ActorId, actor: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = actors.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, actors[mid].bytes, actor)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return mid,
        }
    }
    return null;
}

/// The five alphabets a character can belong to, one per UTF-8 width and the
/// ASCII split at the printable boundary
/// ([`anonymize.rs:289-296`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
///
/// **The split at `0x20` is what keeps a key printable.** `A`, `B` and `\n` are
/// three different alphabets as far as this file is concerned, so a key made of
/// letters comes back made of letters and a control character in a key comes
/// back a control character. A single alphabet for all one-byte characters
/// would turn a key into something with punctuation in it.
const Alphabet = enum(u3) {
    printable_ascii,
    ascii_control,
    two_byte,
    three_byte,
    four_byte,
};

/// Where a character sits in its alphabet
/// ([`structural_character_rank`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
/// at [`anonymize.rs:315-343`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
const Rank = struct {
    alphabet: Alphabet,
    /// The character's index in its alphabet, always less than `count`.
    index: u32,
    /// How many characters the alphabet has.
    count: u32,
};

/// The class of `cp` and its index in it.
///
/// The three-byte case is the awkward one: a three-byte character's code point
/// is in `[0x800, 0x10000)`, which **contains the surrogate range**
/// `[0xD800, 0xDFFF)`, and a surrogate is not a character. Upstream closes
/// the hole by numbering the two sides of the range as one alphabet
/// ([`anonymize.rs:326-335`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
/// `[0x800, 0xD800)` first, then `[0xE000, 0x10000)`, and the alphabet is
/// `0xD800 - 0x800 + 0x2000` wide. So a replacement from that table can never
/// be a surrogate, and `characterFromRank` needs no further check.
fn characterRank(cp: u21) Rank {
    const width = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
    return switch (width) {
        1 => if (cp >= 0x20 and cp <= 0x7e)
            .{ .alphabet = .printable_ascii, .index = @intCast(cp - 0x20), .count = 0x7e - 0x20 + 1 }
        else if (cp < 0x20)
            .{ .alphabet = .ascii_control, .index = @intCast(cp), .count = 0x21 }
        else
            // 0x7f is the only one-byte scalar that is neither printable nor
            // below 0x20, and it shares the control alphabet at rank 0x20.
            .{ .alphabet = .ascii_control, .index = 0x20, .count = 0x21 },
        2 => .{ .alphabet = .two_byte, .index = @intCast(cp - 0x80), .count = 0x800 - 0x80 },
        3 => if (cp < 0xd800)
            .{ .alphabet = .three_byte, .index = @intCast(cp - 0x800), .count = 0xd800 - 0x800 + 0x2000 }
        else
            .{
                .alphabet = .three_byte,
                .index = @intCast(0xd800 - 0x800 + cp - 0xe000),
                .count = 0xd800 - 0x800 + 0x2000,
            },
        4 => .{ .alphabet = .four_byte, .index = @intCast(cp - 0x10000), .count = 0x110000 - 0x10000 },
        // `utf8CodepointSequenceLength` answers 1 to 4 for every valid scalar
        // value, and `cp` is a scalar value, so this is unreachable rather than
        // a case.
        else => unreachable,
    };
}

/// The character at `rank` in the alphabet `original` belongs to
/// ([`structural_character_from_rank`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
/// at [`anonymize.rs:345-363`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
///
/// Null for a rank the alphabet cannot answer, which is [`error.Invariant`]
/// where it is called: the ranks come out of this file's own derangement over
/// this file's own alphabet sizes, so a rank outside the range is a bug here
/// and not a property of the input. Upstream `expect`s the same
/// ([`anonymize.rs:362`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
fn characterFromRank(original: u21, rank: u32) ?u21 {
    const width = std.unicode.utf8CodepointSequenceLength(original) catch return null;
    const cp: u32 = switch (width) {
        1 => if (original >= 0x20 and original <= 0x7e)
            0x20 + rank
        else if (original < 0x20)
            rank
        else if (rank < 0x20)
            // 0x7f at rank 0x20. A derangement never maps rank 0x20 to itself,
            // so the `else` branch is unreachable while the table is a
            // derangement; it is here because upstream has it.
            rank
        else
            0x7f,
        2 => 0x80 + rank,
        3 => if (rank < 0xd800 - 0x800)
            0x800 + rank
        else
            0xe000 + rank - (0xd800 - 0x800),
        4 => 0x10000 + rank,
        else => return null,
    };
    if (cp > 0x10ffff) return null;
    if (cp >= 0xd800 and cp <= 0xdfff) return null;
    return @intCast(cp);
}

/// Lazily built, seeded substitution tables, one per encoding class
/// ([`StructuralPermutations`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
/// at [`anonymize.rs:258-287`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
///
/// **Each table is a derangement**: a permutation in which no element maps to
/// itself ([`random_derangement`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
/// at [`anonymize.rs:298-311`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
/// That is what turns "every key is replaced" from a probability into a
/// guarantee, and it is why a table is built per class and not per string: the
/// same character must reach the same replacement on every occurrence, or a
/// key would stop being a function of the document's content.
///
/// The tables are built on first use, so a document with no non-ASCII key never
/// pays for the four-byte alphabet, which is `0x100000` entries.
const Permutations = struct {
    /// One table per [`Alphabet`], in tag order, null until the class is met.
    tables: [5]?[]u32 = .{ null, null, null, null, null },

    /// The replacement for `cp`, built the first time its class is met.
    fn replace(
        self: *Permutations,
        gpa: Allocator,
        rng: std.Random,
        cp: u21,
    ) (ParseError || InternalError)!u21 {
        const rank = characterRank(cp);
        const slot = &self.tables[@intFromEnum(rank.alphabet)];
        if (slot.* == null) slot.* = try derangement(gpa, rng, rank.count);
        return characterFromRank(cp, slot.*.?[rank.index]) orelse error.Invariant;
    }

    fn deinit(self: *Permutations, gpa: Allocator) void {
        for (&self.tables) |*maybe| {
            if (maybe.*) |table| gpa.free(table);
            maybe.* = null;
        }
    }
};

/// A shuffled permutation of `0..count` with no fixed point
/// ([`anonymize.rs:298-311`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
///
/// **The retry is not a bug and not a hang.** A random permutation of `n`
/// elements is a derangement with probability `1/e`, so the expected number of
/// shuffles is `e` and the loop is bounded in practice by a small constant. It
/// is not bounded in theory, and neither is upstream's: this is the one place
/// where a caller who does not trust the generator can substitute a
/// construction with a proof, at the cost of a different distribution over
/// derangements.
///
/// The caller owns the table; it is `count` `u32`s, so the four-byte alphabet
/// is four megabytes and the two-byte alphabet is under eight.
fn derangement(gpa: Allocator, rng: std.Random, count: u32) Allocator.Error![]u32 {
    // A one-element alphabet has no derangement. Every alphabet here is at
    // least 33 wide, and a caller that reaches this with a smaller one has a
    // bug in `characterRank`; the assertion is the port's answer to a
    // `debug_assert!` upstream can also only check in a debug build
    // ([`anonymize.rs:299`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    std.debug.assert(count > 1);
    const table = try gpa.alloc(u32, count);
    errdefer gpa.free(table);
    for (table, 0..) |*slot, i| slot.* = @intCast(i);
    // One shuffle per attempt. The first fixed point found abandons the whole
    // permutation, because a permutation with one fixed point is not a
    // derangement, and repairing that one pair instead would not be random.
    shuffle: while (true) {
        var i = count;
        while (i > 1) {
            i -= 1;
            const j = rng.uintLessThan(u32, i + 1);
            std.mem.swap(u32, &table[i], &table[j]);
        }
        for (table, 0..) |replacement, index| {
            if (replacement == index) continue :shuffle;
        }
        return table;
    }
}

/// Appends `cp` as UTF-8.
fn appendCodepoint(gpa: Allocator, out: *std.ArrayList(u8), cp: u21) (ParseError || InternalError)!void {
    // Both refusals are unreachable for a `u21`: a scalar value is one to four
    // bytes and is not a surrogate. They are reported rather than asserted
    // because the caller is a string rewrite and a trap there would be a trap
    // on a document's content.
    const width = std.unicode.utf8CodepointSequenceLength(cp) catch return error.Invariant;
    var buf: [4]u8 = undefined;
    const written = std.unicode.utf8Encode(cp, &buf) catch return error.Invariant;
    std.debug.assert(written == width);
    try out.appendSlice(gpa, buf[0..written]);
}

/// Whether `cp` is whitespace in the sense Rust's `char::is_whitespace` is:
/// the twenty-five code points carrying the Unicode `White_Space` property
/// (`https://www.unicode.org/Public/UCD/latest/ucd/PropList.txt`, and
/// `core::char::method::is_whitespace`).
///
/// **The list is spelled out rather than left to `std.ascii.isWhitespace`**
/// because that one answers for one-byte characters only, and upstream's
/// predicate is the Unicode one: a `U+00A0` in a commit message is retained by
/// the reference and would be replaced here if the ASCII predicate were used.
/// A table that answered differently for the same character would make the two
/// documents' shapes disagree for a reason that has nothing to do with the
/// shape.
fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// Whether `cp` is an ASCII control character, which is Rust's
/// `char::is_ascii_control`: `'\0'..='\x1F'` or `'\x7F'`, and **not** anything
/// above one byte. `std.ascii.isControl` has the same definition but takes a
/// `u8`, so narrowing before the call would answer a different question for a
/// code point above `0x7f`.
fn isAsciiControl(cp: u21) bool {
    return cp < 0x80 and (cp < 0x20 or cp == 0x7f);
}

// ── Reading a change's columns ──────────────────────────────────────────────

/// The fourteen change-op columns of one change, decoded.
///
/// **Which columns a change carries depends on its ops**
/// ([`change_op_columns.rs:296-365`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)),
/// so every column here is optional and a missing one is missing rather than
/// an error. This is `doc.zig`'s `cellsOf` ([`doc.zig:936-939`](doc.zig)) and
/// its value-pair read ([`:1059-1063`](doc.zig)), reached through a struct
/// instead of through thirteen locals, because this file needs the same
/// columns twice — once to rewrite them and once to measure their shape.
const OpColumns = struct {
    /// The op count, read from the action column's row count. Every other
    /// column is read at most this far.
    num_ops: usize = 0,
    /// The action code per op. Always present: it is the only column with no
    /// canonical empty form.
    action: ?[]Cell = null,
    obj_actor: ?[]Cell = null,
    obj_counter: ?[]Cell = null,
    key_actor: ?[]Cell = null,
    key_counter: ?[]Cell = null,
    key_string: ?[]Cell = null,
    insert: ?[]Cell = null,
    pred_group: ?[]Cell = null,
    pred_actor: ?[]Cell = null,
    pred_counter: ?[]Cell = null,
    expand: ?[]Cell = null,
    mark_name: ?[]Cell = null,
    /// One value per op, borrowed from the two value columns' bytes. Null
    /// when the change carries no metadata column, which is a change whose no
    /// op has a value at all.
    values: ?[]ScalarValue = null,

    /// Decodes every column `cols` holds. The caller owns the result and frees
    /// it with `deinit`; the `values` borrow `cols`'s data block, so the block
    /// must outlive this struct.
    fn init(gpa: Allocator, cols: RawColumns) ParseError!OpColumns {
        var self: OpColumns = .{};
        errdefer self.deinit(gpa);
        self.action = try cellsOf(gpa, cols, .action);
        self.num_ops = if (self.action) |cells| cells.len else 0;
        self.obj_actor = try cellsOf(gpa, cols, .obj_actor);
        self.obj_counter = try cellsOf(gpa, cols, .obj_counter);
        self.key_actor = try cellsOf(gpa, cols, .key_actor);
        self.key_counter = try cellsOf(gpa, cols, .key_counter);
        self.key_string = try cellsOf(gpa, cols, .key_string);
        self.insert = try cellsOf(gpa, cols, .insert);
        self.pred_group = try cellsOf(gpa, cols, .pred_group);
        self.pred_actor = try cellsOf(gpa, cols, .pred_actor);
        self.pred_counter = try cellsOf(gpa, cols, .pred_counter);
        self.expand = try cellsOf(gpa, cols, .expand);
        self.mark_name = try cellsOf(gpa, cols, .mark_name);
        // The payload half is optional even when the metadata half is present:
        // every value may have its whole value in the metadata word
        // ([`encoding.zig:1384-1386`](columnar/encoding.zig)).
        if (try cols.bytesFor(OpColumn.value_metadata.spec())) |meta_bytes| {
            const raw_bytes = (try cols.bytesFor(OpColumn.value.spec())) orelse &.{};
            self.values = try columnarenc.decodeValuePair(gpa, meta_bytes, raw_bytes);
        }
        return self;
    }

    /// Frees the decoded columns. The values are not freed row by row: they
    /// borrow the source bytes, and `ScalarValue`'s `deinit` would free those.
    fn deinit(self: *OpColumns, gpa: Allocator) void {
        // **An explicit list of pointers rather than `@field` over a name
        // tuple**: a field added to this struct and not to this list would be
        // a leak, and `@field` would have made the omission a silent one.
        const lists = .{
            &self.action,      &self.obj_actor,    &self.obj_counter, &self.key_actor,
            &self.key_counter, &self.key_string,   &self.insert,      &self.pred_group,
            &self.pred_actor,  &self.pred_counter, &self.expand,      &self.mark_name,
        };
        inline for (lists) |slot| {
            if (slot.*) |cells| gpa.free(cells);
        }
        if (self.values) |values| gpa.free(values);
        self.* = undefined;
    }
};

/// One column's cells, or null when the change did not carry it
/// ([`doc.zig:936-939`](doc.zig)).
fn cellsOf(gpa: Allocator, cols: RawColumns, col: OpColumn) ParseError!?[]Cell {
    const bytes = (try cols.bytesFor(col.spec())) orelse return null;
    return try columnarenc.decodeAll(gpa, col.spec(), bytes);
}

/// Row `i` of a decoded column, or `fallback` when the column is absent.
///
/// **A column shorter than the change has ops is `error.UnexpectedEnd`, and
/// that is the rule this copy exists to keep identical to the writer's
/// reader.** These six accessors mirror [`doc.zig:941-1003`](doc.zig) — which
/// is the port's own copy of the same rules — because `doc.zig` does not
/// export them. A copy that drifted here would be **a reader more permissive
/// than its writer**: it would read past a truncated column and produce a
/// document from bytes the port's own load path refuses. The test
/// `the column readers refuse a column shorter than the change's op count`
/// pins the rules on this side.
fn cellAt(list: ?[]const Cell, i: usize, fallback: Cell) ParseError!Cell {
    const cells = list orelse return fallback;
    if (i >= cells.len) return error.UnexpectedEnd;
    return cells[i];
}

/// The unsigned row `i` of a decoded column, or null
/// ([`doc.zig:962-969`](doc.zig)).
fn uintAt(list: ?[]const Cell, i: usize) ParseError!?u64 {
    return switch (try cellAt(list, i, .null_value)) {
        .uint => |u| u,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The signed row `i` of a decoded column, or null
/// ([`doc.zig:971-977`](doc.zig)).
fn intAt(list: ?[]const Cell, i: usize) ParseError!?i64 {
    return switch (try cellAt(list, i, .null_value)) {
        .int => |v| v,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The boolean row `i` of a decoded column, or null. An absent `expand`
/// column means nothing expands
/// ([`change.rs:240`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs)).
fn boolAt(list: ?[]const Cell, i: usize) ParseError!?bool {
    return switch (try cellAt(list, i, .null_value)) {
        .boolean => |b| b,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The string row `i` of a decoded column, or null
/// ([`doc.zig:988-995`](doc.zig)).
fn strAt(list: ?[]const Cell, i: usize) ParseError!?[]const u8 {
    return switch (try cellAt(list, i, .null_value)) {
        .string => |s| s,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The unsigned row `i` of a *group count* column, which may not be absent
/// ([`doc.zig:997-1003`](doc.zig)).
fn countAt(list: ?[]const Cell, i: usize) ParseError!u64 {
    return switch (try cellAt(list, i, .null_value)) {
        .uint => |u| u,
        else => error.UnexpectedNull,
    };
}

/// Row `i` of the value column, or null
/// ([`doc.zig:954-959`](doc.zig)).
fn valueAt(list: ?[]const ScalarValue, i: usize) ParseError!ScalarValue {
    const values = list orelse return .null_value;
    if (i >= values.len) return error.UnexpectedEnd;
    return values[i];
}

// ── The shape ───────────────────────────────────────────────────────────────

/// A canonical description of the parts of a document anonymization promises
/// to keep ([`ShapeSignature`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:6-22`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// Actor ids, change hashes, op ids and structural characters become canonical
/// **indices**; private scalar data is reduced to its **type and encoded
/// width**. Two documents with equal shapes are the same document with the
/// data taken out, which is the property that says an anonymization preserved
/// the document rather than merely producing another document.
///
/// # What a shape is, and why it is a case list
///
/// A shape is **one of the ways an operation can be built**, and the naive
/// rewrite is wrong for most of them. Each of the following is a case, and the
/// reason it is a separate case is what the naive rewrite would do to it:
///
/// | shape | the naive rewrite, and what it gets wrong |
/// | --- | --- |
/// | [`ObjectShape.root`] | replacing the root is not possible; a document's identity is the root |
/// | [`ObjectShape.id`] | an object id is `(counter, actor)`; replacing the counter renames an object every later reference disagrees with |
/// | [`KeyShape.map`] | the string **is** the property. Replacing it per occurrence splits one key into two, and the key set stops being a function of the content |
/// | [`KeyShape.head`] | the head carries no key at all; a rewrite that treats it as an empty string writes a fourth key shape the format does not have |
/// | [`KeyShape.element`] | an element anchor is an op id, and renaming its actor renames the element it points at |
/// | [`ActionShape.make`] | the object type is the payload; there is nothing private in it and nothing to replace |
/// | [`ActionShape.delete`] | **a delete is not a value.** A rewrite that "replaces" it turns a removal into a write |
/// | [`ActionShape.increment`] | the number is private, and the op is still an increment — replacing it with a put would change the merge |
/// | [`ActionShape.put`] | a put's scalar is private, and its **type** is not: `Int` must stay `Int` or the register's merge behaviour changes |
/// | [`ActionShape.mark_begin`] | a mark has a **name** (structural) and a **value** (content), and conflating the two renames either the document's vocabulary or the mark's payload |
/// | [`ActionShape.mark_end`] | a mark end carries only the expand flag; there is no name and no value to replace |
/// | [`ScalarShape.bytes`] | the **length** is the shape; a replacement of a different length changes what every later index means |
/// | [`ScalarShape.string`] | a content string: whitespace is retained and every other character is replaced |
/// | [`ScalarShape.int`], [`ScalarShape.uint`] | a number is replaced, and a same-value replacement is a leak |
/// | [`ScalarShape.float`] | compared **by bits**: `0.0` and `-0.0` compare equal and are different encodings |
/// | [`ScalarShape.counter`] | a counter's *value* is private and its *kind* is what makes a list a counter |
/// | [`ScalarShape.timestamp`] | a timestamp is a number; it is a distinct wire type and must stay one |
/// | [`ScalarShape.boolean`] | **the one shape with no different value of its own type**: half the draws are the same bit, and the shape is the whole of it |
/// | [`ScalarShape.unknown`] | the type code is the shape and the bytes are the data; dropping the code would change the type |
/// | [`ScalarShape.null_value`] | `Null` has no other value of its own type, so there is nothing to replace |
/// | [`ContentCharacterShape.retained`] | whitespace and control are **kept**, so a "replace every character" rewrite is wrong here |
/// | [`CharacterClass.printable_ascii`] | printable ASCII is its own alphabet, so a key stays printable |
/// | [`CharacterClass.ascii_control`] | control characters are their own alphabet, so a control character in a key stays a control character |
/// | [`CharacterClass.unicode`] | a non-ASCII character's **UTF-8 and UTF-16 widths** are the shape, and they are what keeps a text object's length |
/// | [`StructuralStringShape`] | two characters that were equal must still be equal and two that differed must still differ — the equality pattern, not the letters |
///
/// Every row above is a test in this file. A test that could not fail for a
/// broken document would be worse than useless, so each one asserts on the
/// document and not on a count.
///
/// # Ownership
///
/// Owns all shape slices through a heap-allocated arena. Call `deinit` exactly
/// once. A shallow copy shares ownership and must not be disposed separately.
/// The allocator must remain live through disposal.
pub const Shape = struct {
    /// The allocator the arena was built on. Everything this struct owns is
    /// freed with it.
    gpa: Allocator,
    /// Owned, address-stable arena for all shape slices; freed by `deinit`.
    arena: *std.heap.ArenaAllocator,
    /// How the document measures text, which is part of its shape: the same
    /// history in two encodings is two different documents.
    text_encoding: TextEncoding,
    /// How many distinct actors the document has. **The count, not the ids**:
    /// a document with one actor and a document with one other actor have the
    /// same shape.
    actor_count: usize,
    /// The document's heads, as canonical change ids, sorted.
    heads: []ChangeId,
    /// One entry per change, **sorted by canonical change id** so that two
    /// documents with the same history in different orders compare equal.
    changes: []ChangeShape,

    /// The shape of `document`.
    pub fn init(gpa: Allocator, document: *Document) ShapeError!Shape {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        var self: Shape = .{
            .gpa = gpa,
            .arena = arena,
            .text_encoding = document.textEncoding(),
            .actor_count = 0,
            .heads = &.{},
            .changes = &.{},
        };
        errdefer self.deinit();

        var changes = try document.getChanges(gpa, &.{});
        defer changes.deinit(gpa);
        const list = changes.slice();
        const a = self.arena.allocator();

        var ranks = try ActorRanks.init(gpa, list);
        defer ranks.deinit(gpa);

        // The hash beside each change's canonical id, for the dependency and
        // head lookups below. Built before the shapes because a change's
        // dependencies are resolved while it is being measured.
        const table = try ChangeIds.build(a, list, &ranks);

        // **The structural characters, document-wide.** A map keyed by code
        // point whose value is the character's first-appearance index; the
        // assignments happen while the shapes are built, in the same order on
        // both sides of a rewrite because both walk the changes in canonical
        // order. Its deinit is the arena's business, so there is nothing to
        // unwind here.
        var characters: std.AutoHashMapUnmanaged(u32, u32) = .empty;

        const ids = try a.alloc(ChangeId, list.len);
        for (list, 0..) |built, i| {
            ids[i] = .{ .actor = try ranks.rank(built.change.actor), .seq = built.change.seq };
        }
        const order = try a.alloc(usize, list.len);
        for (order, 0..) |*slot, i| slot.* = i;
        std.mem.sort(usize, order, ids, orderByChangeId);

        const shapes = try a.alloc(ChangeShape, list.len);
        for (order, 0..) |index, i| {
            shapes[i] = try changeShape(gpa, a, list[index], ids[index], &ranks, &table, &characters);
        }
        self.actor_count = ranks.count();
        self.changes = shapes;

        // A head is named by hash on the wire and by canonical id in the shape,
        // so the lookup goes through the table that pairs them. **A head the
        // document does not hold is `error.MissingHash` and not a null**: the
        // heads come from the document's own graph, so a hash it does not know
        // is a document that contradicts itself.
        const raw_heads = try document.getHeads(gpa);
        defer gpa.free(raw_heads);
        const heads = try a.alloc(ChangeId, raw_heads.len);
        for (raw_heads, 0..) |hash, i| {
            heads[i] = table.get(hash) orelse return error.MissingHash;
        }
        std.mem.sort(ChangeId, heads, {}, changeIdLessThan);
        self.heads = heads;
        return self;
    }

    /// Releases every slice in the tree, the arena's state, and the arena.
    /// The value is `undefined` afterward. A second disposal is invalid.
    pub fn deinit(self: *Shape) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Whether two documents have the same shape.
    pub fn eql(a: Shape, b: Shape) bool {
        if (a.text_encoding != b.text_encoding) return false;
        if (a.actor_count != b.actor_count) return false;
        if (a.heads.len != b.heads.len) return false;
        if (a.changes.len != b.changes.len) return false;
        for (a.heads, b.heads) |x, y| {
            if (x.order(y) != .eq) return false;
        }
        for (a.changes, b.changes) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }
};

/// What [`Shape.init`] can raise. [`docmod.DocumentError`] because it reads a
/// document's changes, plus [`InternalError`] for the two places a shape walk
/// could meet something the document layer should have refused.
pub const ShapeError = docmod.DocumentError || InternalError;

/// A change's identity without its hash: which actor wrote it, in the
/// document's actor order, and which number in that actor's sequence
/// ([`shape.rs:24-28`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **This is what makes a hash-addressed thing comparable across a rewrite.**
/// The hash is over the bytes, and every byte is about to change; the actor
/// rank and the sequence number are the two things the rewrite keeps.
pub const ChangeId = struct {
    /// The rank of the change's author in the document's actor order.
    actor: usize,
    /// The author's sequence number.
    seq: u64,

    /// Upstream derives `PartialOrd, Ord` over `(actor, seq)`, so this is that
    /// order and no other ([`shape.rs:24`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    pub fn order(a: ChangeId, b: ChangeId) std.math.Order {
        return switch (std.math.order(a.actor, b.actor)) {
            .eq => std.math.order(a.seq, b.seq),
            else => |o| o,
        };
    }

    fn eql(a: ChangeId, b: ChangeId) bool {
        return a.actor == b.actor and a.seq == b.seq;
    }
};

/// One change's shape ([`shape.rs:30-38`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const ChangeShape = struct {
    /// Actor rank and sequence, independent of the original actor bytes.
    id: ChangeId,
    /// The counter of the change's first op. **Kept, not canonicalised**: the
    /// counters are what the rewrite leaves alone, so a change that moved
    /// would show up here.
    start_op: u64,
    /// The change's dependencies as canonical ids, sorted. Sorted because two
    /// documents may list the same dependencies in different orders.
    dependencies: []ChangeId,
    /// The commit message reduced to its character classes, or null for a
    /// change with no message.
    message: ?ContentStringShape,
    /// How many extra bytes the change carries. **The length is the shape**:
    /// the bytes themselves are data, and this file replaces them with
    /// characters of the same count.
    extra_bytes: usize,
    /// The change's operations, in the order the columns hold them.
    operations: []OperationShape,

    fn eql(a: ChangeShape, b: ChangeShape) bool {
        if (!a.id.eql(b.id)) return false;
        if (a.start_op != b.start_op) return false;
        if (a.extra_bytes != b.extra_bytes) return false;
        if (a.dependencies.len != b.dependencies.len) return false;
        if (a.operations.len != b.operations.len) return false;
        for (a.dependencies, b.dependencies) |x, y| {
            if (!x.eql(y)) return false;
        }
        for (a.operations, b.operations) |x, y| {
            if (!x.eql(y)) return false;
        }
        // The message is a content string, so its shape is its character
        // classes. `Option.eql` cannot be used: the payload is a slice.
        if ((a.message == null) != (b.message == null)) return false;
        if (a.message) |x| {
            if (!x.eql(b.message.?)) return false;
        }
        return true;
    }
};

/// One operation's shape ([`shape.rs:40-47`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const OperationShape = struct {
    /// Object targeted by this operation.
    object: ObjectShape,
    /// Map property or sequence element targeted by this operation.
    key: KeyShape,
    /// The op's predecessors as canonical op ids, **sorted**. The order is
    /// normalised because the wire requires ascending counters for the delta
    /// column ([`change_actors.rs:79-81`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/change_actors.rs))
    /// and sorting is what makes two documents' predecessor lists comparable.
    predecessors: []CanonicalOpId,
    /// Whether the op inserts rather than overwrites.
    insert: bool,
    /// Operation kind with private scalar content removed.
    action: ActionShape,

    fn eql(a: OperationShape, b: OperationShape) bool {
        if (!a.object.eql(b.object)) return false;
        if (!a.key.eql(b.key)) return false;
        if (a.insert != b.insert) return false;
        if (a.predecessors.len != b.predecessors.len) return false;
        for (a.predecessors, b.predecessors) |x, y| {
            if (!x.eql(y)) return false;
        }
        return a.action.eql(b.action);
    }
};

/// The object an operation acts on: the root, or an op id
/// ([`shape.rs:49-53`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const ObjectShape = union(enum) {
    /// The document root.
    root,
    /// Canonical id of an object-creation operation.
    id: CanonicalOpId,

    fn eql(a: ObjectShape, b: ObjectShape) bool {
        return switch (a) {
            .root => b == .root,
            .id => |x| switch (b) {
                .root => false,
                .id => |y| x.eql(y),
            },
        };
    }
};

/// What an operation addresses: a map key, the head of a sequence, or an
/// element ([`shape.rs:55-60`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **Three shapes over two columns**, and the rule that separates them is
/// which of the three is present ([`doc.zig:1195-1215`](doc.zig)):
/// `(string, absent, absent)` is a map key, `(absent, actor, counter)` is an
/// element, and `(absent, absent, zero)` is the head. **A present key string
/// decides**, because the other two both have it absent.
pub const KeyShape = union(enum) {
    /// Map key reduced to structural character classes.
    map: StructuralStringShape,
    /// Position before the first sequence element.
    head,
    /// Canonical id of the addressed sequence element.
    element: CanonicalOpId,

    fn eql(a: KeyShape, b: KeyShape) bool {
        return switch (a) {
            .map => |x| switch (b) {
                .map => |y| x.eql(y),
                else => false,
            },
            .head => b == .head,
            .element => |x| switch (b) {
                .element => |y| x.eql(y),
                else => false,
            },
        };
    }
};

/// What an operation does, without the private part of what it carries
/// ([`shape.rs:62-74`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const ActionShape = union(enum) {
    /// The object type made. **There is nothing private here**: the type is
    /// the whole of the operation, and it is the document's structure.
    make: ObjType,
    /// A removal. **Not a value**: an operation with no payload, and a
    /// rewrite that gave it one would turn a removal into a write.
    delete,
    /// An increment, with its private amount erased. The *kind* is kept: an
    /// increment on a counter and a put of an integer merge differently.
    increment,
    /// A put, with the scalar reduced to its type and encoded shape.
    put: ScalarShape,
    /// Mark begin retaining its structural name and expansion policy.
    mark_begin: MarkBeginShape,
    /// A mark end, with its expand flag. **No name and no value**, because an
    /// end row's name column is null and the name is read back from the begin
    /// it closes ([`value.zig:236-238`](value.zig)).
    mark_end: bool,

    /// A mark's beginning: a structural name, a content value, and the expand
    /// flag ([`shape.rs:68-72`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    pub const MarkBeginShape = struct {
        /// Mark name reduced to structural character classes.
        name: StructuralStringShape,
        /// Mark value reduced to scalar shape.
        value: ScalarShape,
        /// Whether an adjacent insertion extends this endpoint.
        expand: bool,

        fn eql(a: MarkBeginShape, b: MarkBeginShape) bool {
            return a.expand == b.expand and a.name.eql(b.name) and a.value.eql(b.value);
        }
    };

    fn eql(a: ActionShape, b: ActionShape) bool {
        return switch (a) {
            .make => |x| switch (b) {
                .make => |y| x == y,
                else => false,
            },
            .delete => b == .delete,
            .increment => b == .increment,
            .put => |x| switch (b) {
                .put => |y| x.eql(y),
                else => false,
            },
            .mark_begin => |x| switch (b) {
                .mark_begin => |y| x.eql(y),
                else => false,
            },
            .mark_end => |x| switch (b) {
                .mark_end => |y| x == y,
                else => false,
            },
        };
    }
};

/// A scalar reduced to its type and encoded shape
/// ([`shape.rs:76-88`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **Ten cases, and the type is nine tenths of the shape.** A number of any
/// value is `Int`; a `Bytes` of any content is `Bytes(len)`. That reduction is
/// what makes the shape comparable while the data is not.
pub const ScalarShape = union(enum) {
    /// A byte string. The **length** is the shape.
    bytes: usize,
    /// A string, reduced to its content character classes.
    string: ContentStringShape,
    /// Signed integer, without its value.
    int,
    /// Unsigned integer, without its value.
    uint,
    /// Floating-point value, without its bits.
    float,
    /// Counter, without its initial or current value.
    counter,
    /// Timestamp, without its time value.
    timestamp,
    /// A boolean. **Nothing else about it is the shape**, and there is no
    /// different value of this type to compare against.
    boolean,
    /// A value from a future version: the type code is the shape, the byte
    /// count is the encoded shape, and the bytes are data.
    unknown: UnknownShape,
    /// Null. No other value of this type exists, so there is nothing to
    /// compare.
    null_value,

    /// A future value's type code and byte count
    /// ([`shape.rs:86`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    pub const UnknownShape = struct {
        /// Unknown four-bit wire scalar code.
        type_code: u8,
        /// Encoded payload byte count, without the payload.
        bytes: usize,

        fn eql(a: UnknownShape, b: UnknownShape) bool {
            return a.type_code == b.type_code and a.bytes == b.bytes;
        }
    };

    fn eql(a: ScalarShape, b: ScalarShape) bool {
        return switch (a) {
            .bytes => |x| switch (b) {
                .bytes => |y| x == y,
                else => false,
            },
            .string => |x| switch (b) {
                .string => |y| x.eql(y),
                else => false,
            },
            .int => b == .int,
            .uint => b == .uint,
            .float => b == .float,
            .counter => b == .counter,
            .timestamp => b == .timestamp,
            .boolean => b == .boolean,
            .unknown => |x| switch (b) {
                .unknown => |y| x.eql(y),
                else => false,
            },
            .null_value => b == .null_value,
        };
    }
};

/// A structural string as an **equality pattern** plus the class of each
/// character ([`shape.rs:90-97`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// The letters are gone; what is left is which positions held the same
/// character. **This is the shape that pins key consistency**: two keys that
/// were the same key have the same pattern, and a key and a different key do
/// not. A rewrite that renamed the same key two ways would still produce equal
/// shapes, which is why the *identity* is document-wide and assigned on first
/// appearance rather than per string.
pub const StructuralStringShape = struct {
    characters: []StructuralCharacterShape,

    fn eql(a: StructuralStringShape, b: StructuralStringShape) bool {
        if (a.characters.len != b.characters.len) return false;
        for (a.characters, b.characters) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }
};

/// One character of a structural string: which character it was, and of what
/// class ([`shape.rs:93-97`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const StructuralCharacterShape = struct {
    /// The index of this character's **first appearance in the whole
    /// document**. The same character in two places has the same identity,
    /// which is what says the rewrite was consistent.
    identity: usize,
    class: CharacterClass,

    fn eql(a: StructuralCharacterShape, b: StructuralCharacterShape) bool {
        return a.identity == b.identity and a.class.eql(b.class);
    }
};

/// A content string as its character classes
/// ([`shape.rs:99-107`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const ContentStringShape = struct {
    characters: []ContentCharacterShape,

    fn eql(a: ContentStringShape, b: ContentStringShape) bool {
        if (a.characters.len != b.characters.len) return false;
        // **Position by position, and the tag decides how.** A retained
        // character is compared by value because it is *not* replaced and so
        // survives into the shape; a replaced one is compared by class because
        // the class is all that survives. Comparing a retained character by its
        // class, or a replaced one by its value, would make the comparison
        // either too weak or too strong.
        for (a.characters, b.characters) |x, y| {
            if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
            switch (x) {
                .retained => |cp| if (cp != y.retained) return false,
                .replaced => |class| if (!class.eql(y.replaced)) return false,
            }
        }
        return true;
    }
};

/// One character of a content string: kept or replaced
/// ([`shape.rs:102-107`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const ContentCharacterShape = union(enum) {
    /// Whitespace and ASCII control characters, **retained verbatim**
    /// ([`anonymize.rs:229-231`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    /// The code point is kept in the shape rather than its class precisely
    /// because it survives the rewrite unchanged.
    retained: u21,
    /// Everything else, which is replaced. The **class** is what survives.
    replaced: CharacterClass,
};

/// A character's encoding class ([`shape.rs:109-114`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **This is the shape that keeps a text object's length.** A replacement
/// character is drawn from the same class, so it has the same UTF-8 width and
/// the same UTF-16 width, and a text object measured in either has the same
/// length afterwards.
pub const CharacterClass = union(enum) {
    /// Printable seven-bit ASCII character.
    printable_ascii,
    /// ASCII control character.
    ascii_control,
    /// Non-ASCII character classified by encoding widths.
    unicode: UnicodeWidths,

    /// A non-ASCII character's UTF-8 and UTF-16 widths
    /// ([`shape.rs:112`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    pub const UnicodeWidths = struct {
        /// UTF-8 byte count of this character.
        utf8: u8,
        /// UTF-16 code-unit count of this character.
        utf16: u8,

        fn eql(a: UnicodeWidths, b: UnicodeWidths) bool {
            return a.utf8 == b.utf8 and a.utf16 == b.utf16;
        }
    };

    fn eql(a: CharacterClass, b: CharacterClass) bool {
        return switch (a) {
            .printable_ascii => b == .printable_ascii,
            .ascii_control => b == .ascii_control,
            .unicode => |x| switch (b) {
                .unicode => |y| x.eql(y),
                else => false,
            },
        };
    }
};

/// An op id with its actor reduced to a rank
/// ([`shape.rs:116-120`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
pub const CanonicalOpId = struct {
    /// The op counter. **Kept exactly**: it is the part of an op id the
    /// rewrite does not touch.
    counter: u64,
    /// The rank of the actor in the document's actor order.
    actor: usize,

    /// Upstream derives `PartialOrd, Ord` over `(counter, actor)`, in that
    /// field order ([`shape.rs:116`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    pub fn order(a: CanonicalOpId, b: CanonicalOpId) std.math.Order {
        return switch (std.math.order(a.counter, b.counter)) {
            .eq => std.math.order(a.actor, b.actor),
            else => |o| o,
        };
    }

    fn eql(a: CanonicalOpId, b: CanonicalOpId) bool {
        return a.counter == b.counter and a.actor == b.actor;
    }
};

/// The document's distinct actors, in lexicographic order, and each one's
/// rank in that order ([`actor_ranks`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:313-323`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **The rank is the whole point, and it survives the rewrite.** The rewrite
/// replaces each actor with a fresh id built as a shared random prefix plus
/// the rank ([`Anonymize.buildActorMap`]), so an actor that sorted first still
/// sorts first, and the two documents' ranks line up value for value. A map
/// built any other way would make every change identity in a rewritten
/// document wrong, and the shape comparison would fail for a reason that has
/// nothing to do with the shape.
const ActorRanks = struct {
    /// Sorted and deduplicated, so an actor's index **is** its rank.
    actors: []ActorId,

    fn init(gpa: Allocator, changes: []const Built) Allocator.Error!ActorRanks {
        var actors: std.ArrayList(ActorId) = .empty;
        errdefer actors.deinit(gpa);
        for (changes) |built| {
            try actors.append(gpa, built.change.actor);
            try actors.appendSlice(gpa, built.change.other_actors);
        }
        // The same `BTreeSet` upstream collects into (`shape.rs:318`): sorted,
        // deduplicated, one entry per actor no matter how many changes name it.
        std.mem.sort(ActorId, actors.items, {}, ActorId.lessThan);
        var unique: usize = 0;
        for (actors.items) |actor| {
            if (unique != 0 and actors.items[unique - 1].eql(actor)) continue;
            actors.items[unique] = actor;
            unique += 1;
        }
        return .{ .actors = try actors.toOwnedSlice(gpa) };
    }

    fn deinit(self: *ActorRanks, gpa: Allocator) void {
        gpa.free(self.actors);
        self.* = undefined;
    }

    fn count(self: ActorRanks) usize {
        return self.actors.len;
    }

    /// The rank of `actor`.
    ///
    /// **`error.Invariant`, not a lookup that returns a default**: every actor
    /// this is asked about came out of one of the same changes the table was
    /// built from, so a miss is a bug in this file rather than a property of
    /// the document.
    fn rank(self: ActorRanks, actor: ActorId) InternalError!usize {
        return findActor(self.actors, actor.bytes) orelse error.Invariant;
    }
};

/// Every change's hash beside the canonical id a shape names it by, sorted by
/// hash so the lookup is a binary search.
///
/// A change's **hash is the one thing the rewrite always changes** — it is
/// SHA-256 over the bytes and every byte moves — so a shape that named a
/// change by hash could never match, and a check that walked two documents in
/// hash order would pair unrelated changes.
const ChangeIds = struct {
    entries: []Entry,

    const Entry = struct { hash: ChangeHash, id: ChangeId };

    fn build(a: Allocator, list: []const Built, ranks: *const ActorRanks) InternalError!ChangeIds {
        const entries = try a.alloc(Entry, list.len);
        for (list, 0..) |built, i| {
            entries[i] = .{
                .hash = built.change.hash,
                .id = .{ .actor = try ranks.rank(built.change.actor), .seq = built.change.seq },
            };
        }
        std.mem.sort(Entry, entries, {}, entryLessThan);
        return .{ .entries = entries };
    }

    fn get(self: ChangeIds, hash: ChangeHash) ?ChangeId {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (self.entries[mid].hash.order(hash)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return self.entries[mid].id,
            }
        }
        return null;
    }

    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        return a.hash.order(b.hash) == .lt;
    }
};

/// The comparator `std.mem.sort` needs to order change indices by the change
/// id each index names. Upstream sorts the changes themselves
/// ([`shape.rs:153`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)); an
/// index sort is the same order without moving the changes, which have to stay
/// where the document put them.
fn orderByChangeId(ids: []const ChangeId, a: usize, b: usize) bool {
    return ids[a].order(ids[b]) == .lt;
}

fn changeIdLessThan(_: void, a: ChangeId, b: ChangeId) bool {
    return a.order(b) == .lt;
}

/// One change, decoded and measured ([`ShapeBuilder::change`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:171-192`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn changeShape(
    gpa: Allocator,
    a: Allocator,
    built: Built,
    id: ChangeId,
    ranks: *const ActorRanks,
    table: *const ChangeIds,
    characters: *std.AutoHashMapUnmanaged(u32, u32),
) ShapeError!ChangeShape {
    var decoded = try Decoded.init(gpa, built.change.bytes);
    defer decoded.deinit(gpa);

    // The change-local actor list a column's actor index refers to: the
    // change's own actor at zero, then its other actors in change order
    // ([`change_actors.rs:10-14`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_actors.rs)).
    const local_ranks = try a.alloc(usize, built.change.other_actors.len + 1);
    local_ranks[0] = try ranks.rank(built.change.actor);
    for (built.change.other_actors, 0..) |other, i| {
        local_ranks[i + 1] = try ranks.rank(other);
    }

    var deps: std.ArrayList(ChangeId) = .empty;
    for (built.change.deps) |dep| {
        // A dependency the document does not hold is `error.MissingHash` and
        // not a null: the change came out of this document's own graph.
        try deps.append(a, table.get(dep) orelse return error.MissingHash);
    }
    std.mem.sort(ChangeId, deps.items, {}, changeIdLessThan);

    var operations: std.ArrayList(OperationShape) = .empty;
    var pred_cursor: usize = 0;
    for (0..decoded.cols.num_ops) |i| {
        try operations.append(a, try operationShape(a, &decoded.cols, local_ranks, characters, i, &pred_cursor));
    }

    return .{
        .id = id,
        .start_op = built.change.start_op,
        .dependencies = try deps.toOwnedSlice(a),
        // An empty message is an absent message ([`change.zig:116-120`](change.zig)),
        // and this is the one place the two must not be told apart: a
        // document with no message and a document with an empty one are the
        // same document, so the shape has one case for both.
        .message = if (built.change.message.len == 0)
            null
        else
            try contentStringShape(a, built.change.message),
        // The extra bytes are the author footer, and **the length is the shape**:
        // the bytes themselves are the author's name, which is data.
        .extra_bytes = decoded.block.footer.len,
        .operations = try operations.toOwnedSlice(a),
    };
}

/// One operation, measured ([`ShapeBuilder::operation`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:194-216`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// `pred_cursor` is threaded through the change's operations because the
/// predecessor columns are **one flattened pair across the whole group
/// column** ([`change_op_columns.rs:342-353`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)),
/// not one list per op: op `i`'s predecessors start where op `i - 1`'s ended.
/// A per-op read that started at zero every time would read the first op's
/// predecessors for every op, and the shape would match a document whose
/// predecessors were wrong.
fn operationShape(
    a: Allocator,
    cols: *const OpColumns,
    local_ranks: []const usize,
    characters: *std.AutoHashMapUnmanaged(u32, u32),
    i: usize,
    pred_cursor: *usize,
) ShapeError!OperationShape {
    const object: ObjectShape = if (try uintAt(cols.obj_actor, i)) |local|
        .{ .id = try canonicalOpId(local_ranks, local, try uintAt(cols.obj_counter, i) orelse
            return error.UnexpectedEnd) }
    else
        .root;

    const key: KeyShape = if (try strAt(cols.key_string, i)) |name|
        .{ .map = try structuralStringShape(a, name, characters) }
    else if (try uintAt(cols.key_actor, i)) |local|
        .{ .element = try canonicalOpId(local_ranks, local, @intCast(try intAt(cols.key_counter, i) orelse
            return error.UnexpectedEnd)) }
    else
        .head;

    const count = std.math.cast(usize, try countAt(cols.pred_group, i)) orelse return error.TooManyDeps;
    const predecessors = try a.alloc(CanonicalOpId, count);
    for (predecessors, 0..) |*slot, k| {
        const at = pred_cursor.* + k;
        const local = try uintAt(cols.pred_actor, at) orelse return error.UnexpectedEnd;
        const ctr = try intAt(cols.pred_counter, at) orelse return error.UnexpectedEnd;
        slot.* = try canonicalOpId(local_ranks, local, @bitCast(@as(u64, @bitCast(ctr))));
    }
    pred_cursor.* += count;
    // Sorted, because the wire only requires ascending **counters** for the
    // delta column and the shape compares actor ranks as well.
    std.mem.sort(CanonicalOpId, predecessors, {}, canonicalOpIdLessThan);

    return .{
        .object = object,
        .key = key,
        .predecessors = predecessors,
        .insert = (try boolAt(cols.insert, i)) orelse false,
        .action = try actionShape(a, cols, characters, i),
    };
}

/// An operation's action, with the private part of what it carries replaced by
/// its shape ([`ShapeBuilder::action`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:218-235`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn actionShape(
    a: Allocator,
    cols: *const OpColumns,
    characters: *std.AutoHashMapUnmanaged(u32, u32),
    i: usize,
) ShapeError!ActionShape {
    const raw = switch (try cellAt(cols.action, i, .null_value)) {
        .uint => |u| u,
        else => return error.InvalidAction,
    };
    const action = try Action.fromCode(std.math.cast(u8, raw) orelse return error.InvalidAction);
    // The name is what decides begin from end, exactly as it decides it in the
    // op type ([`value.zig:270-272`](value.zig)).
    const mark = try strAt(cols.mark_name, i);
    const expand = (try boolAt(cols.expand, i)) orelse false;
    const value = try valueAt(cols.values, i);
    return switch (action) {
        .make_map => .{ .make = .map },
        .make_list => .{ .make = .list },
        .make_text => .{ .make = .text },
        .make_table => .{ .make = .table },
        .delete => .delete,
        .set => .{ .put = try scalarShape(a, value) },
        .increment => .increment,
        .mark => if (mark) |name| .{ .mark_begin = .{
            .name = try structuralStringShape(a, name, characters),
            .value = try scalarShape(a, value),
            .expand = expand,
        } } else .{ .mark_end = expand },
    };
}

/// A scalar reduced to its type and encoded shape
/// ([`scalar_shape`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:267-283`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn scalarShape(a: Allocator, v: ScalarValue) ParseError!ScalarShape {
    return switch (v) {
        .null_value => .null_value,
        .bool_value => .boolean,
        .int => .int,
        .uint => .uint,
        .float => .float,
        .counter => .counter,
        .timestamp => .timestamp,
        .str => |s| .{ .string = try contentStringShape(a, s) },
        .bytes => |b| .{ .bytes = b.len },
        .unknown => |u| .{ .unknown = .{ .type_code = u.type_code, .bytes = u.bytes.len } },
        // **A port-only case, and it has the same shape as `bytes`.** An actor
        // id in a value encodes as an opaque byte payload and reads back as
        // `bytes` ([`encoding.zig:1406-1416`](columnar/encoding.zig)), so a
        // document that stored one and a document that stored a byte string of
        // the same length are the same shape — which is what the port's own
        // value encoder already says they are.
        .actor_id => |id| .{ .bytes = id.bytes.len },
    };
}

/// A structural string reduced to its equality pattern and its characters'
/// classes ([`ShapeBuilder::structural_string`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:237-257`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **`characters` is document-wide and that is the whole mechanism.** A
/// character's identity is the index of its first appearance anywhere in the
/// document, so two occurrences of the same character carry the same identity
/// and two different characters do not. The rewrite replaces a character
/// through a table that is also document-wide, so the pattern is preserved;
/// this is where that is *measured*, and it is measured on the document rather
/// than on the rewrite because the pattern is a property of the document.
fn structuralStringShape(
    a: Allocator,
    text: []const u8,
    characters: *std.AutoHashMapUnmanaged(u32, u32),
) ParseError!StructuralStringShape {
    var out: std.ArrayList(StructuralCharacterShape) = .empty;
    errdefer out.deinit(a);
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        const gop = try characters.getOrPut(a, cp);
        // The count is read **after** the insert, so the new entry's own index
        // is the count less one.
        if (!gop.found_existing) gop.value_ptr.* = @intCast(characters.count() - 1);
        try out.append(a, .{ .identity = gop.value_ptr.*, .class = characterClass(cp) });
    }
    return .{ .characters = try out.toOwnedSlice(a) };
}

/// The canonical form of an op id named by a change-local actor index.
fn canonicalOpId(local_ranks: []const usize, local: u64, counter: u64) ShapeError!CanonicalOpId {
    const i = std.math.cast(usize, local) orelse return error.MissingActor;
    if (i >= local_ranks.len) return error.MissingActor;
    return .{ .counter = counter, .actor = local_ranks[i] };
}

fn canonicalOpIdLessThan(_: void, a: CanonicalOpId, b: CanonicalOpId) bool {
    return a.order(b) == .lt;
}

/// A change's parsed body and its decoded op columns, both owning their
/// allocations. **The values borrow the block's data**, so the block must
/// outlive them and one `deinit` releases both.
const Decoded = struct {
    block: changechunk.ChangeChunk,
    cols: OpColumns,

    fn init(gpa: Allocator, bytes: []const u8) ParseError!Decoded {
        var block = try changechunk.parseChangeChunk(bytes, gpa);
        errdefer block.deinit(gpa);
        const cols = try OpColumns.init(gpa, block.ops);
        return .{ .block = block, .cols = cols };
    }

    fn deinit(self: *Decoded, gpa: Allocator) void {
        self.cols.deinit(gpa);
        self.block.deinit(gpa);
    }
};

/// The class of `cp`, which is what a replaced character keeps
/// ([`character_class`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:300-311`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn characterClass(cp: u21) CharacterClass {
    if (isAsciiControl(cp)) return .ascii_control;
    if (cp < 0x80) return .printable_ascii;
    return .{ .unicode = .{
        .utf8 = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable,
        .utf16 = std.unicode.utf16CodepointSequenceLength(cp) catch unreachable,
    } };
}

/// A content string reduced to its character classes
/// ([`content_string_shape`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:285-298`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// It needs no document state, which is the difference from a structural
/// string: **a content string's characters are all replaced independently**,
/// so there is no equality pattern to record. That is also why a content
/// string's shape is its classes and a structural string's shape is its
/// pattern.
fn contentStringShape(a: Allocator, text: []const u8) ParseError!ContentStringShape {
    var out: std.ArrayList(ContentCharacterShape) = .empty;
    errdefer out.deinit(a);
    var view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        try out.append(a, if (isUnicodeWhitespace(cp) or isAsciiControl(cp))
            .{ .retained = cp }
        else
            .{ .replaced = characterClass(cp) });
    }
    return .{ .characters = try out.toOwnedSlice(a) };
}

// ── The other half of the promise ───────────────────────────────────────────

/// Why [`checkPrivateDataChanged`] refused. One variant per `assert_` in
/// upstream's [`assert_private_data_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:326-386`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs).
///
/// **Upstream panics and this returns**, which is the port's rule
/// ([`AGENTS.md`](../../AGENTS.md)): a checker that cannot be run as a value is
/// a checker that cannot be run in a test that continues. Each variant names
/// the assertion it replaces so a failing test says which promise broke.
pub const CheckError = error{
    /// The two documents hold different numbers of changes.
    ChangeCount,
    /// A change kept its hash, so it kept its bytes.
    Hash,
    /// A change kept its author, so the author was not replaced.
    Actor,
    /// A change kept its timestamp.
    Timestamp,
    /// A commit message kept a character that must be replaced
    /// ([`shape.rs:344-346`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    Message,
    /// A change's extra bytes kept a byte
    /// ([`shape.rs:347-351`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    ExtraBytes,
    /// Two changes hold different numbers of operations.
    OpCount,
    /// Two paired operations have different actions, so the pairing is wrong
    /// or the document's meaning changed
    /// ([`shape.rs:382`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    Action,
    /// A map key kept a character
    /// ([`shape.rs:362-364`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    MapKey,
    /// A mark name kept a character
    /// ([`shape.rs:375-378`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    MarkName,
    /// An increment kept its value
    /// ([`shape.rs:369-374`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    Increment,
    /// A scalar changed type, or a scalar of the same type kept its value
    /// ([`shape.rs:405-439`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    Scalar,
    /// A byte value kept a byte.
    Byte,
    /// A content string kept a character that must be replaced.
    Content,
    /// **A character the rewrite retains came back changed**
    /// ([`shape.rs:451-452`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    /// This is the assertion the naive rewrite fails, and it is why the
    /// retained characters are checked rather than skipped.
    Retained,
};

/// Checks that every piece of private data in `source` was replaced in
/// `anonymized`, and that nothing which had to be kept was changed
/// ([`assert_private_data_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:325-386`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **It is the other half of [`Shape`] and neither half is enough alone.** A
/// shape says the structure is the same; this says the data is not. A rewrite
/// that copies a document satisfies one and fails the other, and a rewrite
/// that replaces everything with random bytes satisfies neither.
///
/// The two documents are paired **by canonical change id, not by hash and not
/// by position**: the rewrite changes every hash, and the two documents may
/// list their changes in different orders. The pairing is therefore the only
/// thing that decides which change is compared with which, and a shape
/// disagreement elsewhere is what says the pairing is wrong.
///
/// Upstream's two deliberate gaps are kept, and they are not gaps in the
/// checker but statements about the data: **a boolean may come back equal**
/// ([`shape.rs:428-430`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)),
/// because a random bit is sometimes the same bit, and **`Null` has no
/// alternative of its own type**, so there is nothing to compare.
pub fn checkPrivateDataChanged(
    gpa: Allocator,
    source: *Document,
    anonymized: *Document,
) (CheckError || ShapeError)!void {
    var src_changes = try source.getChanges(gpa, &.{});
    defer src_changes.deinit(gpa);
    var anon_changes = try anonymized.getChanges(gpa, &.{});
    defer anon_changes.deinit(gpa);
    const src = src_changes.slice();
    const anon = anon_changes.slice();
    if (src.len != anon.len) return error.ChangeCount;

    var src_ranks = try ActorRanks.init(gpa, src);
    defer src_ranks.deinit(gpa);
    var anon_ranks = try ActorRanks.init(gpa, anon);
    defer anon_ranks.deinit(gpa);
    const arena = gpa;
    const src_order = try canonicalOrder(arena, src, &src_ranks);
    defer gpa.free(src_order);
    const anon_order = try canonicalOrder(arena, anon, &anon_ranks);
    defer gpa.free(anon_order);

    for (src_order, anon_order) |si, ai| {
        const before = src[si];
        const after = anon[ai];
        // The hash covers the bytes, and the bytes are what was replaced, so an
        // unchanged hash means the change was copied rather than rewritten.
        if (before.change.hash.eql(after.change.hash)) return error.Hash;
        if (before.change.actor.eql(after.change.actor)) return error.Actor;
        if (before.change.time == after.change.time) return error.Timestamp;
        if (before.change.message.len != 0 and after.change.message.len != 0) {
            try checkContentChanged(before.change.message, after.change.message, error.Message);
        }
        var a = try Decoded.init(gpa, before.change.bytes);
        defer a.deinit(gpa);
        var b = try Decoded.init(gpa, after.change.bytes);
        defer b.deinit(gpa);
        try checkBytesChanged(a.block.footer, b.block.footer, error.ExtraBytes);
        if (a.cols.num_ops != b.cols.num_ops) return error.OpCount;
        for (0..a.cols.num_ops) |i| try checkOperationChanged(&a, &b, i);
    }
}

/// The indices of `list` in canonical change-id order.
fn canonicalOrder(gpa: Allocator, list: []const Built, ranks: *const ActorRanks) InternalError![]usize {
    const order = try gpa.alloc(usize, list.len);
    errdefer gpa.free(order);
    const ids = try gpa.alloc(ChangeId, list.len);
    defer gpa.free(ids);
    for (list, 0..) |built, i| {
        order[i] = i;
        ids[i] = .{ .actor = try ranks.rank(built.change.actor), .seq = built.change.seq };
    }
    std.mem.sort(usize, order, ids, orderByChangeId);
    return order;
}

/// One paired operation, checked ([`shape.rs:356-384`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn checkOperationChanged(a: *const Decoded, b: *const Decoded, i: usize) (CheckError || ParseError)!void {
    // A map key is a structural string on both sides. **Only a map key is
    // compared here**, because a sequence anchor is an op id and the actor
    // behind it is a rank, not a string.
    if (try strAt(a.cols.key_string, i)) |key| {
        const renamed = try strAt(b.cols.key_string, i) orelse return error.MapKey;
        try checkStructuralStringChanged(key, renamed, error.MapKey);
    }

    const before = try actionCode(&a.cols, i);
    const after = try actionCode(&b.cols, i);
    if (before != after) return error.Action;
    switch (before) {
        .set => try checkScalarChanged(
            try valueAt(a.cols.values, i),
            try valueAt(b.cols.values, i),
        ),
        .increment => {
            const x = try incrementOf(&a.cols, i);
            const y = try incrementOf(&b.cols, i);
            if (x == y) return error.Increment;
        },
        .mark => {
            if (try strAt(a.cols.mark_name, i)) |name| {
                const renamed = try strAt(b.cols.mark_name, i) orelse return error.MarkName;
                try checkStructuralStringChanged(name, renamed, error.MarkName);
                try checkScalarChanged(try valueAt(a.cols.values, i), try valueAt(b.cols.values, i));
            }
        },
        // A make, a delete and a mark end carry nothing private, and a delete
        // that is still a delete is the whole of what has to be true about it.
        .make_map, .make_list, .make_text, .make_table, .delete => {},
    }
}

/// The op's action code, as the enum rather than the wire number, so the two
/// sides can be compared as what they are.
fn actionCode(cols: *const OpColumns, i: usize) ParseError!Action {
    const raw = switch (try cellAt(cols.action, i, .null_value)) {
        .uint => |u| u,
        else => return error.InvalidAction,
    };
    return Action.fromCode(std.math.cast(u8, raw) orelse return error.InvalidAction);
}

/// The amount an increment carries, in whichever of the three integer types it
/// arrived as ([`value.zig:257-263`](value.zig)).
fn incrementOf(cols: *const OpColumns, i: usize) ParseError!i64 {
    return switch (try valueAt(cols.values, i)) {
        .int => |v| v,
        .uint => |v| std.math.cast(i64, v) orelse return error.Overflow,
        .counter => |c| c.current,
        else => error.InvalidValueType,
    };
}

/// Two scalars of the same type, checked ([`assert_scalar_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:405-439`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn checkScalarChanged(before: ScalarValue, after: ScalarValue) (CheckError || ParseError)!void {
    if (std.meta.activeTag(before) != std.meta.activeTag(after)) return error.Scalar;
    switch (before) {
        .null_value => {},
        // **A boolean may be unchanged**, so there is nothing to check here.
        // The assertion is on the type, and a random bit is a boolean either
        // way.
        .bool_value => {},
        .int => |x| if (x == after.int) return error.Scalar,
        .uint => |x| if (x == after.uint) return error.Scalar,
        // **Compared by bits, not by `==`.** `0.0` and `-0.0` are equal as
        // numbers and different as encodings, and a rewrite that returned
        // `-0.0` for `0.0` would have changed the bytes.
        .float => |x| if (@as(u64, @bitCast(x)) == @as(u64, @bitCast(after.float))) return error.Scalar,
        .counter => |x| if (x.current == after.counter.current) return error.Scalar,
        .timestamp => |x| if (x == after.timestamp) return error.Scalar,
        .str => |x| try checkContentChanged(x, after.str, error.Content),
        .bytes => |x| try checkBytesChanged(x, after.bytes, error.Byte),
        .unknown => |x| try checkBytesChanged(x.bytes, after.unknown.bytes, error.Byte),
        .actor_id => |x| try checkBytesChanged(x.bytes, after.actor_id.bytes, error.Byte),
    }
}

/// A structural string, checked character by character
/// ([`assert_structural_string_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:441-446`](../../github-automerge-automerge/src/anonymize/shape.rs)).
///
/// **Same character count, and no character the same.** A shorter or longer
/// result is [`error.Character`] rather than a per-character loop that would
/// compare a prefix and pass.
fn checkStructuralStringChanged(
    before: []const u8,
    after: []const u8,
    which: CheckError,
) (CheckError || ParseError)!void {
    var a = try std.unicode.Utf8View.init(before);
    var b = try std.unicode.Utf8View.init(after);
    var ia = a.iterator();
    var ib = b.iterator();
    while (true) {
        const x = ia.nextCodepointSlice() orelse return if (ib.nextCodepointSlice() == null) {} else which;
        const y = ib.nextCodepointSlice() orelse return which;
        const cx = std.unicode.utf8Decode(x) catch return error.InvalidUtf8;
        const cy = std.unicode.utf8Decode(y) catch return error.InvalidUtf8;
        if (cx == cy) return which;
    }
}

/// A content string, checked character by character
/// ([`assert_content_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:448-457`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **Two rules, and the second is the one a naive rewrite breaks**: a retained
/// character must be *equal* and a replaced one must be *different*.
fn checkContentChanged(before: []const u8, after: []const u8, which: CheckError) (CheckError || ParseError)!void {
    var a = try std.unicode.Utf8View.init(before);
    var b = try std.unicode.Utf8View.init(after);
    var ia = a.iterator();
    var ib = b.iterator();
    while (true) {
        const x = ia.nextCodepointSlice() orelse return if (ib.nextCodepointSlice() == null) {} else which;
        const y = ib.nextCodepointSlice() orelse return which;
        const cx = std.unicode.utf8Decode(x) catch return error.InvalidUtf8;
        const cy = std.unicode.utf8Decode(y) catch return error.InvalidUtf8;
        if (isUnicodeWhitespace(cx) or isAsciiControl(cx)) {
            if (cx != cy) return error.Retained;
        } else if (cx == cy) {
            return which;
        }
    }
}

/// Two byte runs, checked byte by byte
/// ([`assert_bytes_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:459-464`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **Same length, and no byte the same.** The length is the shape and the
/// bytes are the data, so a length change is the shape failing and a repeated
/// byte is the data surviving.
fn checkBytesChanged(before: []const u8, after: []const u8, which: CheckError) CheckError!void {
    if (before.len != after.len) return which;
    for (before, after) |x, y| {
        if (x == y) return which;
    }
}

// ── Test fixtures ────────────────────────────────────────────────────────────

/// The three actor ids the fixtures use. They sort in this order, which is what
/// makes actor index zero the first of them and the ranks in a [`Shape`] line
/// up between a document and its rewrite.
const actor_a = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const actor_b = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const actor_c = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3";

/// One operation to build, before it becomes a change's columns. The mirror of
/// `doc.zig`'s own `OpSpec` ([`doc.zig:4076-4095`](doc.zig)), which is private,
/// and the same fields for the same reason: the transaction slice does not
/// exist, so a test document is built by encoding changes by hand.
const OpSpec = struct {
    /// The op counter. Consecutive within one change, ascending.
    ctr: u32,
    /// The object the op acts on; the root unless a change made one.
    obj: ExId = .root,
    /// What the op does.
    action: Action = .set,
    /// The property it addresses.
    key: KeyRef,
    /// The value it carries. An op that carries none says so by leaving this
    /// at `.null_value`.
    value: ScalarValue = .null_value,
    /// Whether it inserts into a sequence rather than overwriting.
    insert: bool = false,
    /// Whether a mark expands before its span.
    expand: bool = false,
    /// The mark's name, or null for a mark end. **The name alone decides begin
    /// from end** ([`value.zig:270-272`](value.zig)), which is why there is no
    /// separate action for the two.
    mark: ?[]const u8 = null,
    /// The ops it overwrites or deletes.
    pred: []const OpId = &.{},
};

/// One change to build and apply.
const ChangeSpec = struct {
    /// The author's actor id. The document interns it.
    actor: []const u8,
    seq: u64,
    /// The counter of the first op, never zero.
    start_op: u64,
    deps: []const ChangeHash = &.{},
    /// The author name in the change's footer.
    author: ?[]const u8 = null,
    message: []const u8 = &.{},
    time: i64 = 1_700_000_000,
    ops: []const OpSpec,
};

/// Encodes `spec` as one change and applies it, returning its hash
/// ([`doc.zig`'s `applyHandChange`](doc.zig), with the encoder spelled out
/// because the port's own is private).
///
/// The column set is written exactly as [`Anonymize.rewriteChange`] reads it,
/// which is the point: **the fixture is built with the same rules the rewriter
/// assumes**, so a fixture that the rules did not anticipate is a fixture this
/// test would be wrong about rather than a passing test.
fn applySpec(gpa: Allocator, doc: *Document, spec: ChangeSpec) !ChangeHash {
    const actor_index = try doc.putActorRef(gpa, .{ .bytes = spec.actor });

    // The actors the change names after its own, ascending by document index,
    // which is the lexicographic order a document's actor table is sorted in
    // ([`ActorMapper`](doc.zig)).
    const actors = doc.ops.actors.items;
    const seen = try gpa.alloc(bool, actors.len);
    defer gpa.free(seen);
    @memset(seen, false);
    for (spec.ops) |op| {
        if (op.obj.actor()) |a| seen[a] = true;
        if (op.key == .seq) {
            if (op.key.seq.actor()) |a| seen[a] = true;
        }
        for (op.pred) |p| seen[p.actor] = true;
    }
    // The change's own actor is at index zero already, so it is not also
    // listed here ([`ActorMapper.buildMapping`](doc.zig)).
    seen[actor_index] = false;

    var others: std.ArrayList(ActorIdx) = .empty;
    defer others.deinit(gpa);
    for (0..actors.len) |i| {
        if (seen[i]) try others.append(gpa, @intCast(i));
    }
    // The document actor index each change-local index names, in change order.
    const local = try gpa.alloc(ActorIdx, others.items.len + 1);
    defer gpa.free(local);
    local[0] = actor_index;
    for (others.items, 1..) |a, i| local[i] = a;
    // The same actors as ids, for the change's header: **the header names the
    // actors and the columns number them by position**, and it is that pairing
    // that the rewrite preserves.
    var other_actors: std.ArrayList(ActorId) = .empty;
    defer other_actors.deinit(gpa);
    for (others.items) |a| try other_actors.append(gpa, actors[a]);

    var set: ColumnSet = .{};
    defer set.deinit(gpa);
    var scratch: std.ArrayList(Cell) = .empty;
    defer scratch.deinit(gpa);
    var preds: std.ArrayList(OpId) = .empty;
    defer preds.deinit(gpa);
    const ops = spec.ops;

    for (changechunk.op_columns) |col| switch (col) {
        .obj_actor => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, if (op.obj.actor()) |a|
                    .{ .uint = try remapActor(local, a) }
                else
                    .null_value);
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
        .obj_counter => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, if (op.obj.counter()) |c|
                    .{ .uint = c }
                else
                    .null_value);
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
        .key_actor => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, switch (op.key) {
                    .map => Cell.null_value,
                    .seq => |e| if (e.actor()) |a|
                        .{ .uint = try remapActor(local, a) }
                    else
                        .null_value,
                });
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
        .key_counter => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, switch (op.key) {
                    .map => Cell.null_value,
                    // **The head's counter is a zero, not an absent row**
                    // ([`types.zig:317-325`](types.zig)): the third key shape.
                    .seq => |e| .{ .int = e.icounter() },
                });
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
        .key_string => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, switch (op.key) {
                    .map => |k| .{ .string = k },
                    .seq => Cell.null_value,
                });
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
        .insert => {
            scratch.clearRetainingCapacity();
            for (ops) |op| try scratch.append(gpa, .{ .boolean = op.insert });
            try set.push(gpa, col, scratch.items);
        },
        .action => {
            scratch.clearRetainingCapacity();
            for (ops) |op| try scratch.append(gpa, .{ .uint = @intFromEnum(op.action) });
            try set.push(gpa, col, scratch.items);
        },
        .value_metadata => {
            const values = try gpa.alloc(ScalarValue, ops.len);
            defer gpa.free(values);
            for (ops, 0..) |op, i| values[i] = opValue(op);
            // **Both halves, together and in order.** A replacement scalar need
            // not have the source's byte length, so the payload and the
            // metadata that describes it cannot be written separately.
            const pair = try columnarenc.encodeValuePair(gpa, col.id(), values);
            defer pair.deinit(gpa);
            try set.pushRaw(gpa, pair.meta.spec, pair.meta.bytes);
            if (pair.raw.bytes.len != 0) try set.pushRaw(gpa, pair.raw.spec, pair.raw.bytes);
        },
        // **The payload half is written with its metadata half** and this arm
        // must not write it a second time: the two halves are one pair, and a
        // second payload would be a second column of the same id in one block.
        .value => {},
        .pred_group => {
            scratch.clearRetainingCapacity();
            for (ops) |op| try scratch.append(gpa, .{ .uint = op.pred.len });
            try set.push(gpa, col, scratch.items);
        },
        .pred_actor => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                for (try sortedPreds(&preds, gpa, op.pred)) |p| {
                    try scratch.append(gpa, .{ .uint = try remapActor(local, p.actor) });
                }
            }
            // The flattened pair is dropped when no op has a predecessor
            // ([`change_op_columns.rs:342-353`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)).
            if (scratch.items.len != 0) try set.push(gpa, col, scratch.items);
        },
        .pred_counter => {
            scratch.clearRetainingCapacity();
            // **Sorted the same way as the actor half**: the two halves are one
            // flattened pair, and a reader that walked them in different orders
            // would pair one op's actor with another op's counter.
            for (ops) |op| {
                for (try sortedPreds(&preds, gpa, op.pred)) |p| {
                    try scratch.append(gpa, .{ .int = @intCast(p.counter) });
                }
            }
            if (scratch.items.len != 0) try set.push(gpa, col, scratch.items);
        },
        .expand => {
            scratch.clearRetainingCapacity();
            for (ops) |op| try scratch.append(gpa, .{ .boolean = op.expand });
            // Omitted unless something expands ([`change.rs:240`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs)).
            const encoded = try columnarenc.encodeMaybeBoolean(gpa, col.id(), scratch.items);
            defer encoded.deinit(gpa);
            if (encoded.bytes.len != 0) try set.pushRaw(gpa, col.spec(), encoded.bytes);
        },
        .mark_name => {
            scratch.clearRetainingCapacity();
            for (ops) |op| {
                try scratch.append(gpa, if (op.mark) |name|
                    .{ .string = name }
                else
                    Cell.null_value);
            }
            try set.pushNullable(gpa, col, scratch.items);
        },
    };
    const cols = try RawColumns.init(gpa, set.descs.items, set.data.items);
    defer cols.deinit(gpa);
    var footer: std.ArrayList(u8) = .empty;
    defer footer.deinit(gpa);
    try docmod.encodeAuthorFooter(gpa, &footer, spec.author);

    const header = Change{
        .bytes = &.{},
        .header_len = 0,
        .actor = actors[actor_index],
        .deps = spec.deps,
        .hash = ChangeHash.zero,
        .time = spec.time,
        .message = spec.message,
        .seq = spec.seq,
        .start_op = spec.start_op,
        .max_op = 0,
        .other_actors = other_actors.items,
    };
    const body = try changechunk.encodeBody(gpa, header, .{
        .cols = cols,
        .footer = footer.items,
    });
    defer gpa.free(body);
    var change = try changerec.parseChange(body, gpa);
    defer change.deinit(gpa);
    // **The third encode-then-reparse, and the same hole as the other two.**
    // A parse leaves `max_op` at zero (`change.zig:48-52`, `:380-382`), so a
    // change built here and handed straight to `applyChanges` arrives at the
    // change queue with no op count at all — `opCountOf` answers zero for a
    // change whose `max_op < start_op` (`change_queue.zig:247-254`). Upstream
    // counts the ops as it decodes them, so `Change::max_op()` is never a
    // guess there (`change.rs:30-46`, `:74-76`). `ops.len` is the list the
    // columns on line 2674 were written from, so this is the same number the
    // body already carries.
    change = change.withOpCount(ops.len) catch |e| return e;
    _ = try doc.applyChanges(gpa, &.{change});
    return change.hash;
}

/// The value an op's row carries in the value column pair. **An op that carries
/// no value says `.null_value`**, so a `make` and a `delete` and a mark end all
/// share one value shape.
fn opValue(op: OpSpec) ScalarValue {
    return switch (op.action) {
        .make_map, .make_list, .make_text, .make_table, .delete => .null_value,
        .set, .increment => op.value,
        .mark => if (op.mark != null) op.value else .null_value,
    };
}

/// An op's predecessors in ascending counter order, into `out`, which the
/// delta-encoded predecessor column requires
/// ([`change_actors.rs:79-81`](../../github-automerge-automerge/rust/automerge/src/op_set2/change_actors.rs)).
///
/// **Sorted into a buffer the caller owns**, not into a global: a global
/// scratch list would outlive the test, would allocate from an allocator
/// `testing.allocator` would then report as a leak, and two calls in one test
/// would share it.
fn sortedPreds(out: *std.ArrayList(OpId), gpa: Allocator, pred: []const OpId) ![]OpId {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, pred);
    std.mem.sort(OpId, out.items, {}, opIdLessThan);
    return out.items;
}

fn opIdLessThan(_: void, a: OpId, b: OpId) bool {
    return a.order(b) == .lt;
}

/// The change-local index of a document actor index.
fn remapActor(local: []const ActorIdx, actor: ActorIdx) !ActorIdx {
    for (local, 0..) |candidate, i| {
        if (candidate == actor) return @intCast(i);
    }
    return error.WrongActorTable;
}

/// The columns a hand-built change carries, in the order the writer emits them.
const ColumnSet = struct {
    descs: std.ArrayList(ColumnDesc) = .empty,
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *ColumnSet, gpa: Allocator) void {
        self.descs.deinit(gpa);
        self.data.deinit(gpa);
    }

    fn pushRaw(self: *ColumnSet, gpa: Allocator, spec: ColumnSpec, bytes: []const u8) !void {
        try self.data.appendSlice(gpa, bytes);
        try self.descs.append(gpa, .init(spec, bytes.len));
    }

    /// Encodes `cells` and appends them, always.
    fn push(self: *ColumnSet, gpa: Allocator, col: OpColumn, cells: []const Cell) !void {
        const encoded = try columnarenc.encodeColumn(gpa, col.id(), col.encoding(), cells);
        defer encoded.deinit(gpa);
        try self.pushRaw(gpa, col.spec(), encoded.bytes);
    }

    /// Encodes `cells` and appends them **unless every row is absent**, which is
    /// the writer's rule for a nullable column
    /// ([`encodeNullableCol`](doc.zig), from `change.rs:206-224`).
    fn pushNullable(self: *ColumnSet, gpa: Allocator, col: OpColumn, cells: []const Cell) !void {
        for (cells) |cell| {
            if (cell != .null_value) return self.push(gpa, col, cells);
        }
    }
};

const testing = std.testing;

/// The four root keys the program-driven fixture cycles through
/// ([`ROOT_KEYS`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)
/// at [`fuzz.rs:12`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
const root_keys = [_][]const u8{ "alpha", "beta", "gamma", "delta" };

/// The four keys the program makes objects under
/// ([`fuzz.rs:165`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
const object_keys = [_][]const u8{ "object-0", "object-1", "object-2", "object-3" };

/// The four mark names the program uses
/// ([`fuzz.rs:151`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
const mark_names = [_][]const u8{ "mark-0", "mark-1", "mark-2", "mark-3" };

/// The words a program-written string value is built from.
const program_words = [_][]const u8{ "private-", "alpha", "gamma" };

/// The commit messages the program writes when it writes one at all
/// ([`fuzz.rs:174`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
const messages = [_][]const u8{ "private-message", "second private message", "third private message" };

/// The document the program-driven fixture starts from
/// ([`document_from_program`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)
/// at [`fuzz.rs:34-64`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)):
/// a list, a text object and a counter, and a commit that carries a message.
fn buildFuzzBase(gpa: Allocator, actor: []const u8) !struct { doc: Document, head: ChangeHash, list: ExId, text: ExId } {
    var doc = try Document.init(gpa, std.testing.io, .auto);
    errdefer doc.deinit();
    const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
    const list = ExId{ .id = OpId.init(1, idx) };
    const text = ExId{ .id = OpId.init(2, idx) };
    const head = try applySpec(gpa, &doc, .{
        .actor = actor,
        .seq = 1,
        .start_op = 1,
        .message = "initial private data",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr("items") },
            .{ .ctr = 2, .action = .make_text, .key = KeyRef.fromStr("notes") },
            .{ .ctr = 3, .key = KeyRef.fromStr("counter"), .value = .{ .counter = .init(0) } },
        },
    });
    return .{ .doc = doc, .head = head, .list = list, .text = text };
}

/// A document built by running a byte program, over three replicas that are
/// merged at the end ([`fuzz.rs:34-64`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
///
/// **The program is data, not a fuzzer.** Upstream's target is a `proptest!`
/// over 64 random programs; this takes the eleven opcodes and the instruction
/// layout as they are and runs one fixed program, because the property under
/// test is that each opcode's shape survives a rewrite and a property that
/// needs sixty-four random draws to fail is a property nobody is waiting for.
/// The eleven opcodes are each a test in their own right below.
/// A second copy of a document, loaded from its own saved bytes.
///
/// **Through `save` and [`Document.load`] and not [`Document.fork`].** A fork
/// mints a fresh actor id from the allocator and hands the bytes to the new
/// document as an opaque actor the document never frees
/// ([`doc.zig:3796-3801`](doc.zig)), so every fork is a leak — and a fixture
/// that wants three replicas wants two of them. A reload is what a peer does,
/// and it costs this fixture nothing the fork would have given it.
fn loadCopy(gpa: Allocator, source: *Document) !Document {
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    return Document.load(gpa, std.testing.io, bytes, source.textEncoding(), .auto);
}

fn documentFromProgram(gpa: Allocator, program: []const u8) !Document {
    const base = try buildFuzzBase(gpa, actor_a);
    var doc = base.doc;
    errdefer doc.deinit();
    var one = try loadCopy(gpa, &doc);
    defer one.deinit();
    var two = try loadCopy(gpa, &doc);
    defer two.deinit();
    const replicas = [_]*Document{ &doc, &one, &two };
    const actors = [_][]const u8{ actor_a, actor_b, actor_c };

    // One change per replica for the program's own edits, each depending on
    // what the replica already has. The counter starts after the base change's
    // three ops.
    //
    // **The sequence numbers are per author, and only one of the three
    // replicas' actors has written anything.** The base change is actor
    // [`actor_a`]'s first, so `who = 0` continues at two; the other two actors
    // hold no change of their own and their first is sequence **one**. Seeding
    // all three at one — the value the sequence takes *after* a change — is
    // what made every replica but the first write a change claiming a sequence
    // number it had skipped, and `ChangeGraph.addChange` refused the whole
    // program with `InvalidSeq`.
    var seq: [3]u64 = .{ 1, 0, 0 };
    var next_op: [3]u64 = .{ 4, 4, 4 };
    var heads: [3]?ChangeHash = .{ base.head, base.head, base.head };

    var chunk: [6]u8 = undefined;
    var at: usize = 0;
    while (at < program.len) : (at += 6) {
        const n = @min(6, program.len - at);
        @memcpy(chunk[0..n], program[at..][0..n]);
        @memset(chunk[n..], 0);
        try runInstruction(gpa, &replicas, &seq, &next_op, &heads, actors, base.list, base.text, &chunk);
    }

    // Merge the replicas into the first, the way `fuzz.rs:58-61` does, so the
    // document under test holds concurrent edits from three actors.
    for (replicas[1..]) |other| {
        var incoming = try other.clone(gpa, .auto);
        defer incoming.deinit();
        const merged = try doc.merge(gpa, &incoming);
        defer gpa.free(merged);
    }
    return doc;
}

/// One six-byte instruction ([`apply_instruction`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)
/// at [`fuzz.rs:66-178`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)).
fn runInstruction(
    gpa: Allocator,
    replicas: []const *Document,
    seq: *[3]u64,
    next_op: *[3]u64,
    heads: *[3]?ChangeHash,
    actors: [3][]const u8,
    list: ExId,
    text: ExId,
    ins: *[6]u8,
) !void {
    const opcode = ins[0] % 11;
    const who = @as(usize, ins[1]) % replicas.len;
    const a = ins[2];
    const b = ins[3];
    const c = ins[4];
    const d = ins[5];

    // Opcode 9 is a merge rather than an edit, and it commits nothing.
    if (opcode == 9) {
        const from = @as(usize, a) % replicas.len;
        if (from == who) return;
        var incoming = try replicas[from].clone(gpa, .auto);
        defer incoming.deinit();
        // **The merged document's heads are returned to the caller to free**,
        // and discarding them is a leak, not a style question.
        const merged = try replicas[who].merge(gpa, &incoming);
        defer gpa.free(merged);
        // **A merge brings changes this replica has not counted for, and the
        // two numbers it has to catch up are not the same number.** A change's
        // sequence number counts *that author's* changes
        // ([`types.zig`](types.zig)'s `(actor, seq)` identity), so it is the
        // highest sequence `who` itself has written — zero if it has written
        // none. An operation counter is document-wide, so it is one past the
        // largest counter anywhere in the document.
        //
        // **Taking either from "the last change in dependency order" is the bug
        // this paragraph replaces**, and it is not a small one: the last change
        // belongs to whichever actor happened to write last, so a replica that
        // merged and then committed again claimed a sequence number another
        // actor had already used, and `Document.applyChanges` refused the whole
        // program with `InvalidSeq`.
        var changes = try replicas[who].getChanges(gpa, &.{});
        defer changes.deinit(gpa);
        if (changes.len() != 0) {
            var own_seq: u64 = 0;
            var next_counter: u64 = 1;
            for (changes.slice()) |built| {
                // **The last counter a change holds, read off its operations**
                // rather than off `Change.max_op`: a change handed back by
                // [`Document.getChanges`] carries `max_op = 0`, because the
                // collector rebuilds the header from the graph and the op
                // columns rather than from the value the writer put there. A
                // counter of `0 + 1` is what a merge that trusted it computed,
                // and the next change then reused a counter the document had
                // been using since its first op.
                var decoded = try Decoded.init(gpa, built.change.bytes);
                defer decoded.deinit(gpa);
                next_counter = @max(next_counter, built.change.start_op + decoded.cols.num_ops);
                if (std.mem.eql(u8, built.change.actor.bytes, actors[who])) {
                    own_seq = @max(own_seq, built.change.seq);
                }
            }
            seq[who] = own_seq;
            next_op[who] = next_counter;
        }
        // **The new head is the replica's own head list, not the last change.**
        // The last change in dependency order may well be a dependency of
        // another change, and a change that names a dependency as its only
        // dependency is not a head afterwards.
        const now = try replicas[who].getHeads(gpa);
        defer gpa.free(now);
        if (now.len != 0) heads[who] = now[0];
        return;
    }

    const doc = replicas[who];
    const list_len = listLength(doc, gpa, list);
    const text_len = textLength(doc, gpa, text);
    var specs: [2]OpSpec = undefined;
    var count: usize = 0;
    const key = KeyRef.fromStr(root_keys[a % root_keys.len]);
    switch (opcode) {
        0 => specs[count] = .{ .ctr = 0, .key = key, .value = programScalar(b, c, d) },
        1 => {
            // **A delete names what it deletes.** A delete with an empty
            // predecessor list is not "delete whatever is under this key": the
            // document layer stores it as no row at all, and the change that
            // claimed it is then a change that holds none — which is what the
            // program hit before this arm named an operation
            // ([`assert_private_data_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
            // refuses the same way for the same kind of hole).
            //
            // **The newest non-delete row under the key**, because a register
            // with history is deleted by naming its current value and an older
            // one is already gone.
            var rows = try opsOf(gpa, doc);
            defer rows.deinit(gpa);
            var target: ?OpId = null;
            for (rows.rows) |row| {
                if (row.obj != .root) continue;
                if (row.action == .delete) continue;
                const name = row.key_string orelse continue;
                if (!std.mem.eql(u8, name, root_keys[a % root_keys.len])) continue;
                if (target == null or row.ctr > target.?.counter) target = row.id;
            }
            const doomed = target orelse return;
            specs[count] = .{
                .ctr = 0,
                .key = key,
                .action = .delete,
                .value = .null_value,
                .pred = try gpa.dupe(OpId, &.{doomed}),
            };
        },
        2 => {
            // **At the end, and not at a chosen position.** [`elementAt`] numbers
            // elements by *insertion* order, because the operations it reads
            // come back in change order and not in document order. Appending is
            // what makes the two agree, and every position this fixture asks
            // for is then the element it means.
            const anchor = anchorBefore(doc, gpa, list, list_len);
            specs[count] = .{
                .ctr = 0,
                .obj = list,
                .key = KeyRef.fromElemId(anchor),
                .insert = true,
                .value = programScalar(b, c, d),
            };
        },
        3 => {
            if (list_len == 0) return;
            const at_index = @as(usize, a) % list_len;
            specs[count] = .{
                .ctr = 0,
                .obj = list,
                .key = KeyRef.fromElemId(elementAt(doc, gpa, list, at_index)),
                .value = programScalar(b, c, d),
            };
        },
        4 => {
            if (list_len == 0) return;
            const at_index = @as(usize, a) % list_len;
            const target = elementAt(doc, gpa, list, at_index);
            specs[count] = .{
                .ctr = 0,
                .obj = list,
                .key = KeyRef.fromElemId(target),
                .action = .delete,
                .value = .null_value,
                .pred = try gpa.dupe(OpId, &.{target.id}),
            };
        },
        5 => {
            // **At the end, for the reason opcode 2 gives**: an insert at a
            // chosen position would put insertion order and document order out
            // of step, and a mark built on the two disagreeing orders is a mark
            // whose end precedes its begin.
            const anchor = anchorBefore(doc, gpa, text, text_len);
            const letters = [_][]const u8{ "a", "Z", " ", "\n" };
            const letter = letters[b % letters.len];
            specs[count] = .{
                .ctr = 0,
                .obj = text,
                .key = KeyRef.fromElemId(anchor),
                .insert = true,
                .value = .{ .str = letter },
            };
        },
        6 => {
            if (text_len == 0) return;
            const at_index = @as(usize, a) % text_len;
            const target = elementAt(doc, gpa, text, at_index);
            specs[count] = .{
                .ctr = 0,
                .obj = text,
                .key = KeyRef.fromElemId(target),
                .action = .delete,
                .value = .null_value,
                .pred = try gpa.dupe(OpId, &.{target.id}),
            };
        },
        7 => {
            const amount: i64 = @as(i16, @bitCast(@as(u16, a)));
            specs[count] = .{ .ctr = 0, .key = KeyRef.fromStr("counter"), .action = .increment, .value = .{ .int = amount } };
        },
        8 => {
            if (text_len == 0) return;
            const start = @as(usize, a) % text_len;
            const end = start + 1 + @as(usize, b) % (text_len - start);
            // **The end has to hang by a later element.** A begin and an end on
            // the same element is a mark that spans nothing, and the mark index
            // refuses it with `InvalidMarkOrder` when the document is merged —
            // the same trap [`buildRich`] records for its own fixture.
            if (end >= text_len) return;
            const target = elementAt(doc, gpa, text, start);
            const after = elementAt(doc, gpa, text, end);
            specs[count] = .{
                .ctr = 0,
                .obj = text,
                .key = KeyRef.fromElemId(target),
                .action = .mark,
                .mark = mark_names[d % mark_names.len],
                .value = programScalar(b, c, d),
                .expand = c % 4 != 3,
            };
            // The end is a second op in the same change, anchored after the
            // begin, which is the only shape that spans anything
            // ([`doc.zig:4258-4267`](doc.zig)).
            specs[count + 1] = .{
                .ctr = 0,
                .obj = text,
                .key = KeyRef.fromElemId(after),
                .action = .mark,
                .value = .null_value,
                .expand = c % 4 != 3,
            };
            count = 1;
        },
        10 => {
            const object_type: Action = switch (b % 4) {
                0 => .make_map,
                1 => .make_table,
                2 => .make_list,
                else => .make_text,
            };
            specs[count] = .{
                .ctr = 0,
                .key = KeyRef.fromStr(object_keys[a % object_keys.len]),
                .action = object_type,
            };
        },
        else => unreachable, // `opcode` is taken modulo eleven
    }
    count += 1;

    // The op counters must be consecutive within one change, which is what
    // "one change" means ([`encodeChangeOps`](doc.zig)).
    for (specs[0..count], 0..) |*spec, k| spec.ctr = @intCast(next_op[who] + k);
    const deps: []const ChangeHash = if (heads[who]) |h| &.{h} else &.{};
    const head = try applySpec(gpa, doc, .{
        .actor = actors[who],
        .seq = seq[who] + 1,
        .start_op = next_op[who],
        .deps = deps,
        .message = if (a % 2 == 0) messages[(a / 2) % messages.len] else "",
        .time = @as(i16, @bitCast(@as(u16, c) << 8 | @as(u16, d))),
        .ops = specs[0..count],
    });
    // A delete's predecessor list was allocated for this call.
    for (specs[0..count]) |spec| {
        if (spec.pred.len != 0) gpa.free(spec.pred);
    }
    seq[who] += 1;
    next_op[who] += count;
    heads[who] = head;
}

/// The ten scalar shapes the program can produce
/// ([`scalar`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)
/// at [`fuzz.rs:180-196`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)):
/// **one of each of [`ScalarShape`]'s ten cases, chosen by `kind % 10`.**
fn programScalar(kind: u8, x: u8, y: u8) ScalarValue {
    const pair: i16 = @bitCast(@as(u16, x) << 8 | @as(u16, y));
    return switch (kind % 10) {
        0 => .{ .str = program_words[x % program_words.len] },
        1 => .{ .bytes = &[_]u8{ x, y, kind } },
        2 => .{ .int = pair },
        3 => .{ .uint = @as(u16, @bitCast(@as(u16, x) << 8 | @as(u16, y))) },
        4 => .{ .float = @as(f64, @floatFromInt(pair)) / 10.0 },
        5 => .{ .counter = .init(pair) },
        6 => .{ .timestamp = pair },
        7 => .{ .bool_value = x % 2 == 0 },
        8 => .{ .unknown = .{ .type_code = 10 + x % 6, .bytes = &[_]u8{ x, y } } },
        else => .null_value,
    };
}

/// How many elements a list object has, read through the document's own text
/// reader is not available for a list, so it is counted from the operations.
fn listLength(doc: *Document, gpa: Allocator, list: ExId) usize {
    return sequenceLength(doc, gpa, list);
}

fn textLength(doc: *Document, gpa: Allocator, text: ExId) usize {
    return sequenceLength(doc, gpa, text);
}

/// Appends the live elements of a sequence object to `out`, in insertion
/// order: an insert adds one and a delete removes the element it is anchored
/// to.
///
/// **Deleted elements are removed rather than skipped**, so the result is the
/// sequence the reader would report and not the sequence it once contained. A
/// program that deletes an element and then indexes past it depends on this:
/// counting a deleted element shifts every position after it by one, and the
/// operation the program then builds is anchored to the wrong element.
///
/// **Insertion order, and not document order.** The rows this reads come back
/// in change order and then column order ([`opsOf`]), while a sequence's
/// document order is the order its inserts hang in the skip list. The two agree
/// while every insert goes to the end, and they stop agreeing the moment one
/// goes to the head. A fixture that wants a position to mean a *document*
/// position keeps its inserts appending — which is what
/// [`runInstruction`]'s opcodes 2 and 5 do, and the reason is written there.
fn appendLiveElements(
    gpa: Allocator,
    rows: *const OpRows,
    obj: ExId,
    out: *std.ArrayList(OpId),
) !void {
    for (rows.rows) |row| {
        if (row.obj != .id) continue;
        if (row.obj.id.counter != obj.id.counter or row.obj.id.actor != obj.id.actor) continue;
        switch (row.action) {
            .set => if (row.insert) try out.append(gpa, row.id),
            .delete => {
                var at: usize = 0;
                while (at < out.items.len) : (at += 1) {
                    if (!out.items[at].eql(row.idOfAnchor())) continue;
                    _ = out.orderedRemove(at);
                    break;
                }
            },
            else => {},
        }
    }
}

/// The number of live elements of a sequence object.
///
/// **Counted from the operations rather than from a reader**, because the
/// document layer's list reader is not part of this port yet
/// ([`docs/STATUS.md`](../../docs/STATUS.md) §"Where the document slice
/// stands").
fn sequenceLength(doc: *Document, gpa: Allocator, obj: ExId) usize {
    var ops = opsOf(gpa, doc) catch return 0;
    defer ops.deinit(gpa);
    var live: std.ArrayList(OpId) = .empty;
    defer live.deinit(gpa);
    appendLiveElements(gpa, &ops, obj, &live) catch return 0;
    return live.items.len;
}

fn indexOfOpId(list: []const OpId, id: OpId) usize {
    for (list, 0..) |candidate, i| {
        if (candidate.eql(id)) return i;
    }
    return list.len;
}

/// **The element at zero-based position `index`**, or the head when the object
/// is empty.
///
/// **Position zero is the first element and not the head**, and the difference
/// is the whole of this function: an overwrite or a delete at position zero
/// names the first element, and an insert *before* position zero names the head.
/// Conflating the two makes an overwrite of the first element a write over the
/// head, which the document layer stores as no operation at all — and the
/// change that claimed the operation is then a change that "holds none".
fn elementAt(doc: *Document, gpa: Allocator, obj: ExId, index: usize) ElemId {
    var ops = opsOf(gpa, doc) catch return ElemId.head();
    defer ops.deinit(gpa);
    var live: std.ArrayList(OpId) = .empty;
    defer live.deinit(gpa);
    appendLiveElements(gpa, &ops, obj, &live) catch return ElemId.head();
    if (live.items.len == 0) return ElemId.head();
    return ElemId.fromOpId(live.items[@min(index, live.items.len - 1)]);
}

/// What an insert at sequence position `position` hangs by: the head before the
/// first element, and the element before it everywhere else.
fn anchorBefore(doc: *Document, gpa: Allocator, obj: ExId, position: usize) ElemId {
    if (position == 0) return ElemId.head();
    return elementAt(doc, gpa, obj, position - 1);
}

// ── Reading a document's operations back ────────────────────────────────────

/// Every operation of every change a document holds, in change order then
/// column order.
///
/// **The strings and the values are copies.** They arrive borrowed from a
/// change body that the next iteration of the walk releases, and a row that
/// pointed into it would be a dangling slice by the time the caller looked at
/// it — a test that segfaults instead of failing, which is the worst possible
/// outcome for an instrument.
const OpRows = struct {
    gpa: Allocator,
    /// Every copied string and value payload lives here, so one call releases
    /// them all.
    arena: *std.heap.ArenaAllocator,
    rows: []OpRow,
    preds: []OpId,

    fn deinit(self: *OpRows, gpa: Allocator) void {
        gpa.free(self.rows);
        gpa.free(self.preds);
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

/// One operation as a test needs to see it, with the local actor indices the
/// change chunk used.
const OpRow = struct {
    /// Which change of the document it came from, in `getChanges` order.
    change: usize,
    /// Its index within that change's op columns.
    index: usize,
    /// The op's own counter. **The counter is the part of an op id the rewrite
    /// keeps**, so it is the same on both sides of a rewrite and it is what
    /// identifies an operation across one.
    ctr: u32,
    /// **The document actor index of the change's author**, which is the other
    /// half of every operation this change made. **The change chunk numbers its
    /// author at local index zero**
    /// ([`change_actors.rs:10-14`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/change_actors.rs)),
    /// and a document index is not a local index: three replicas writing in one
    /// document have their authors at document indexes zero, one and two, so a
    /// row that assumed author zero would name the wrong actor for two changes
    /// out of three.
    author: ActorIdx,
    /// This row's own op id, which the two halves above make.
    id: OpId,
    obj: ExId,
    key_string: ?[]const u8,
    key_actor: u64,
    key_counter: i64,
    action: Action,
    insert: bool,
    expand: bool,
    mark: ?[]const u8,
    value: ScalarValue,
    /// Where this row's predecessors start in [`OpRows.preds`]. **An offset and
    /// not a slice**: the array is filled while the rows are built, and a slice
    /// taken into it before the last append would dangle when the append
    /// reallocated. `predsOf` is the accessor.
    pred_start: usize,
    pred_count: usize,

    /// This row's predecessors in `all`, which is the one shared allocation
    /// [`OpRows`] owns.
    fn predsOf(row: OpRow, all: []const OpId) []const OpId {
        return all[row.pred_start..][0..row.pred_count];
    }

    /// The object this row made, which is the row's own op id. It is only a
    /// made object for a `make_*` action.
    fn idOfMade(row: OpRow) ExId {
        return .{ .id = row.id };
    }

    /// The op this row is anchored to, from its key columns. A head anchor is
    /// `(absent, zero)` ([`types.zig:317-325`](types.zig)), so this is the
    /// zero id for the head.
    fn idOfAnchor(row: OpRow) OpId {
        if (row.key_actor == 0) return OpId.root;
        return OpId.init(@intCast(@max(row.key_counter, 0)), @intCast(row.key_actor));
    }
};

/// Reads a document's operations back out of the changes it hands a peer.
///
/// **This is the instrument, and it is deliberately the same surface the sync
/// protocol uses** — the change chunks — rather than a reader, because a
/// reader would be testing a second implementation of the same document and a
/// disagreement between the two would be a fact about the fixture rather than
/// about the rewrite. What it is for is a test that says *this op is still
/// there, still a delete, and still succeeds that other op* — a question about
/// the operations themselves, which is what anonymization claims to preserve.
fn opsOf(gpa: Allocator, doc: *Document) !OpRows {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    const list = changes.slice();
    var rows: std.ArrayList(OpRow) = .empty;
    errdefer rows.deinit(gpa);
    var preds: std.ArrayList(OpId) = .empty;
    errdefer preds.deinit(gpa);

    for (list, 0..) |built, change_index| {
        var decoded = try Decoded.init(gpa, built.change.bytes);
        defer decoded.deinit(gpa);
        const cols = &decoded.cols;
        // **The document index of this change's author**, read once per change.
        // Every operation in the change has this actor, and it is the other half
        // of each of their op ids.
        const author: ActorIdx = @intCast(
            doc.ops.lookupActor(built.change.actor) orelse return error.MissingActor,
        );
        var pred_cursor: usize = 0;
        for (0..cols.num_ops) |i| {
            const count = std.math.cast(usize, try countAt(cols.pred_group, i)) orelse return error.TooManyDeps;
            const start = preds.items.len;
            for (0..count) |k| {
                const at = pred_cursor + k;
                const local = try uintAt(cols.pred_actor, at) orelse return error.UnexpectedEnd;
                const ctr = try intAt(cols.pred_counter, at) orelse return error.UnexpectedEnd;
                try preds.append(gpa, OpId.init(@intCast(@max(ctr, 0)), @intCast(local)));
            }
            pred_cursor += count;
            try rows.append(gpa, .{
                .change = change_index,
                .index = i,
                .ctr = @intCast(built.change.start_op + i),
                .author = author,
                .id = OpId.init(@intCast(built.change.start_op + i), author),
                .obj = if (try uintAt(cols.obj_actor, i)) |local|
                    .{ .id = OpId.init(@intCast(try uintAt(cols.obj_counter, i) orelse
                        return error.UnexpectedEnd), @intCast(local)) }
                else
                    .root,
                .key_string = if (try strAt(cols.key_string, i)) |k| try a.dupe(u8, k) else null,
                .key_actor = (try uintAt(cols.key_actor, i)) orelse 0,
                .key_counter = (try intAt(cols.key_counter, i)) orelse 0,
                .action = try actionCode(cols, i),
                .insert = (try boolAt(cols.insert, i)) orelse false,
                .expand = (try boolAt(cols.expand, i)) orelse false,
                .mark = if (try strAt(cols.mark_name, i)) |k| try a.dupe(u8, k) else null,
                .value = try keepValue(a, try valueAt(cols.values, i)),
                .pred_start = start,
                .pred_count = count,
            });
        }
    }
    return .{
        .gpa = gpa,
        .arena = arena,
        .rows = try rows.toOwnedSlice(gpa),
        .preds = try preds.toOwnedSlice(gpa),
    };
}

/// The first row of `doc` with this action and this map key, or null.
fn findRow(ops: *const OpRows, action: Action, key: []const u8) ?OpRow {
    for (ops.rows) |row| {
        if (row.action != action) continue;
        const name = row.key_string orelse continue;
        if (std.mem.eql(u8, name, key)) return row;
    }
    return null;
}

/// The first row of `ops` with this action and this op counter, or null.
///
/// **The counter is the identity a rewrite preserves**, so this is how a row in
/// a result is paired with a row in its source. The pairing is by counter and
/// not by key, because the key is one of the things that changed.
fn findRowByCtr(ops: *const OpRows, action: Action, ctr: u32) ?OpRow {
    for (ops.rows) |row| {
        if (row.ctr != ctr) continue;
        if (row.action != action) continue;
        return row;
    }
    return null;
}

/// The first `set` row over `key` in change `change` with exactly `pred_count`
/// predecessors, or null.
///
/// **The predecessor count is part of the selection, and it is the half of a
/// conflict that tells the two puts apart.** A register with two puts over it
/// has more than one row with that key, and the one that is *concurrent* is the
/// one that succeeds nothing.
fn findPutInChange(ops: *const OpRows, change: usize, key: []const u8, pred_count: usize) ?OpRow {
    for (ops.rows) |row| {
        if (row.change != change) continue;
        if (row.action != .set) continue;
        if (row.pred_count != pred_count) continue;
        const name = row.key_string orelse continue;
        if (std.mem.eql(u8, name, key)) return row;
    }
    return null;
}

/// The object the operation at `ctr` made, in `doc`.
///
/// **The author is local index zero, and that is not a guess**: the operation
/// that makes an object is always the change's own first operation, and a
/// change chunk numbers its author at index zero
/// ([`change_actors.rs:10-14`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_actors.rs)).
/// So the same `ctr` names the same object in a document and in its rewrite,
/// with a different actor behind it.
fn objectMadeAt(gpa: Allocator, doc: *Document, ctr: u32) !ExId {
    var ops = try opsOf(gpa, doc);
    defer ops.deinit(gpa);
    for (ops.rows) |row| {
        if (row.ctr != ctr) continue;
        switch (row.action) {
            .make_map, .make_list, .make_text, .make_table => return row.idOfMade(),
            else => {},
        }
    }
    return error.MissingKey;
}

/// A scalar with its payload copied into `a`, so a row outlives the change body
/// its payload was borrowed from.
fn keepValue(a: Allocator, v: ScalarValue) !ScalarValue {
    return switch (v) {
        .null_value, .bool_value, .int, .uint, .float, .counter, .timestamp => v,
        .str => |s| ScalarValue{ .str = try a.dupe(u8, s) },
        .bytes => |b| ScalarValue{ .bytes = try a.dupe(u8, b) },
        .actor_id => |id| ScalarValue{ .actor_id = .{ .bytes = try a.dupe(u8, id.bytes) } },
        .unknown => |u| ScalarValue{ .unknown = .{
            .type_code = u.type_code,
            .bytes = try a.dupe(u8, u.bytes),
        } },
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// The document nearly every test here starts from: **a map, a nested map, a
/// list, a text object, a counter, a delete and a mark**, and a conflict, and a
/// second actor that writes into both the first actor's list and its map.
///
/// The op layout, and why each op is there:
///
/// | op | what it is | which rule it pins |
/// | --- | --- | --- |
/// | 1-3 | a list, a text object and a map made on the root | [`ActionShape.make`], all four object types across the two changes |
/// | 4-12 | one put of each of the nine scalar types | [`ScalarShape`]'s ten cases |
/// | 13-15 | three list inserts, one a counter | [`KeyShape.head`], [`KeyShape.element`], [`ScalarShape.counter`] in a list |
/// | 16-17 | two text inserts, the second a four-byte character | the text length rule, and the four-byte alphabet |
/// | 18-19 | a mark begin and a mark end | [`ActionShape.mark_begin`], [`ActionShape.mark_end`] |
/// | 20-22 | the same key in two objects, and a put in each | **key consistency** |
/// | 23 | a delete of op 5 | a delete stays a delete |
/// | 24 | a second put of op 4's key, succeeding op 4 | a register with history |
/// | 25 | a put of a `Uint` | the tenth scalar type |
/// | 26 | the **second actor's** put of op 24's key, with no predecessor | **the conflict** |
/// | 27 | the second actor inserting into the first actor's list | a change with an `other_actors` entry |
/// | 28 | the second actor writing the shared key into the map | key consistency across actors too |
fn buildRich(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io, .auto);
    errdefer doc.deinit();
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const b = try doc.putActorRef(gpa, .{ .bytes = actor_b });
    // Sorted, so actor index zero is the first of them, which is what the
    // ranks in a shape are measured against.
    try testing.expectEqual(@as(ActorIdx, 0), a);
    try testing.expectEqual(@as(ActorIdx, 1), b);

    const list = ExId{ .id = OpId.init(1, a) };
    const text = ExId{ .id = OpId.init(2, a) };
    const map = ExId{ .id = OpId.init(3, a) };
    const first = OpId.init(13, a);
    const second = OpId.init(14, a);
    const glyph = OpId.init(16, a);
    const wave = OpId.init(17, a);
    const put_key = OpId.init(4, a);
    const put_bytes = OpId.init(5, a);

    const head = try applySpec(gpa, &doc, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .author = "private author name",
        .message = "private commit message",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr("private-list") },
            .{ .ctr = 2, .action = .make_text, .key = KeyRef.fromStr("private-text") },
            .{ .ctr = 3, .action = .make_map, .key = KeyRef.fromStr("private-map") },
            .{ .ctr = 4, .key = KeyRef.fromStr("private-key"), .value = .{ .str = "secret value" } },
            .{ .ctr = 5, .key = KeyRef.fromStr("private-bytes"), .value = .{ .bytes = &[_]u8{ 1, 2, 3, 4 } } },
            .{ .ctr = 6, .key = KeyRef.fromStr("private-number"), .value = .{ .int = 42 } },
            .{ .ctr = 7, .key = KeyRef.fromStr("private-counter"), .value = .{ .counter = .init(10) } },
            .{ .ctr = 8, .key = KeyRef.fromStr("private-timestamp"), .value = .{ .timestamp = 1_700_000_000 } },
            .{ .ctr = 9, .key = KeyRef.fromStr("private-bool"), .value = .{ .bool_value = true } },
            .{ .ctr = 10, .key = KeyRef.fromStr("private-unknown"), .value = .{ .unknown = .{ .type_code = 12, .bytes = &[_]u8{ 7, 8 } } } },
            .{ .ctr = 11, .key = KeyRef.fromStr("private-null"), .value = .null_value },
            .{ .ctr = 12, .key = KeyRef.fromStr("private-float"), .value = .{ .float = 1.5 } },
            .{ .ctr = 13, .obj = list, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = "alpha" } },
            .{ .ctr = 14, .obj = list, .key = KeyRef.fromElemId(ElemId.fromOpId(first)), .insert = true, .value = .{ .str = "beta" } },
            .{ .ctr = 15, .obj = list, .key = KeyRef.fromElemId(ElemId.fromOpId(second)), .insert = true, .value = .{ .counter = .init(7) } },
            .{ .ctr = 16, .obj = text, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = "hi" } },
            .{ .ctr = 17, .obj = text, .key = KeyRef.fromElemId(ElemId.fromOpId(glyph)), .insert = true, .value = .{ .str = "\u{1F44B}" } },
            // **The mark's end is anchored after the text, not on the same
            // element as its begin.** Both on `glyph` they sit at one sequence
            // position and the mark spans nothing, which is a mark the
            // reference does not report ([`doc.zig:4258-4267`](doc.zig)).
            .{ .ctr = 18, .obj = text, .key = KeyRef.fromElemId(ElemId.fromOpId(glyph)), .action = .mark, .mark = "private-bold", .value = .{ .bool_value = true }, .expand = true },
            .{ .ctr = 19, .obj = text, .key = KeyRef.fromElemId(ElemId.fromOpId(wave)), .action = .mark, .value = .null_value, .expand = true },
            .{ .ctr = 20, .obj = map, .key = KeyRef.fromStr("private-nested"), .value = .{ .str = "nested secret" } },
            .{ .ctr = 21, .obj = map, .key = KeyRef.fromStr("private-shared"), .value = .{ .str = "shared in the map" } },
            .{ .ctr = 22, .key = KeyRef.fromStr("private-shared"), .value = .{ .str = "shared at the root" } },
            .{ .ctr = 23, .key = KeyRef.fromStr("private-bytes"), .action = .delete, .value = .null_value, .pred = &.{put_bytes} },
            .{ .ctr = 24, .key = KeyRef.fromStr("private-key"), .value = .{ .str = "another secret" }, .pred = &.{put_key} },
            .{ .ctr = 25, .key = KeyRef.fromStr("private-uint"), .value = .{ .uint = 7 } },
            // **An increment on the counter, not a put of one.** The two merge
            // differently, so a rewrite that turned this into a put would
            // change what the document means while every other assertion here
            // still passed.
            .{ .ctr = 26, .key = KeyRef.fromStr("private-counter"), .action = .increment, .value = .{ .int = 5 }, .pred = &.{OpId.init(7, a)} },
        },
    });
    _ = try applySpec(gpa, &doc, .{
        .actor = actor_b,
        .seq = 1,
        .start_op = 27,
        .deps = &.{head},
        .author = "private author two",
        .message = "second private message",
        .ops = &.{
            // **No predecessor**, and a different author: this put is
            // concurrent with op 24, so the register ends up with two values.
            // That is the conflict, and a rewrite that resolved it would have
            // to drop one of the two operations.
            .{ .ctr = 27, .key = KeyRef.fromStr("private-key"), .value = .{ .str = "bob secret" } },
            .{ .ctr = 28, .obj = list, .key = KeyRef.fromElemId(ElemId.fromOpId(second)), .insert = true, .value = .{ .str = "gamma" } },
            .{ .ctr = 29, .obj = map, .key = KeyRef.fromStr("private-shared"), .value = .{ .str = "bob shared" } },
        },
    });
    return doc;
}

/// A document that is one scalar and nothing else: one change, one operation,
/// one put at the root.
///
/// **"A bare scalar" is the smallest non-empty document there is**, and it is
/// the case where the naive rewrite is most likely to produce something that
/// is a document but not *this* document: there is no second operation to
/// cross-check the shape against, and no object to carry a key's consistency.
fn buildBareScalar(gpa: Allocator, value: ScalarValue) !Document {
    var doc = try Document.init(gpa, std.testing.io, .auto);
    errdefer doc.deinit();
    _ = try applySpec(gpa, &doc, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .ops = &.{.{ .ctr = 1, .key = KeyRef.fromStr("private-only"), .value = value }},
    });
    return doc;
}

/// The two documents of a rewrite, plus their saved bytes, so a test can
/// assert on the bytes rather than on a count.
const Pair = struct {
    source: Document,
    anonymized: Document,
    source_bytes: []u8,
    anonymized_bytes: []u8,

    fn deinit(self: *Pair, gpa: Allocator) void {
        self.source.deinit();
        self.anonymized.deinit();
        gpa.free(self.source_bytes);
        gpa.free(self.anonymized_bytes);
        self.* = undefined;
    }
};

/// Builds the rich document, round-trips it through its own bytes, rewrites
/// what came back, and saves both.
///
/// **Through `save` and a reload, not straight from memory**, because the
/// acceptance criterion is about bytes: a rewrite that produced a document the
/// in-memory reader accepts and the stored format refuses would pass every
/// other test in this file. The source the rewrite sees is a document that came
/// out of the format, so its actor table, its interned strings and its op
/// columns are the ones a reader sees.
fn richPair(gpa: Allocator, seed: [seed_length]u8) !Pair {
    var built = try buildRich(gpa);
    defer built.deinit();
    const built_bytes = try built.save(gpa);
    defer gpa.free(built_bytes);

    var source = try Document.load(gpa, std.testing.io, built_bytes, built.textEncoding(), .auto);
    errdefer source.deinit();
    const source_bytes = try source.save(gpa);
    errdefer gpa.free(source_bytes);

    var anonymized = try anonymize(gpa, &source, seed);
    errdefer anonymized.deinit();
    const anonymized_bytes = try anonymized.save(gpa);
    errdefer gpa.free(anonymized_bytes);
    return .{
        .source = source,
        .anonymized = anonymized,
        .source_bytes = source_bytes,
        .anonymized_bytes = anonymized_bytes,
    };
}

//  **The acceptance test.** A document with a map, a nested map, a list, a
//  text object, a counter, a delete and a mark is anonymized, and **the result
//  loads** — through `save` and a fresh `Document.load`, which is the reader
//  the port and the reference both go through.
//
//  The three assertions in order, because they are the three promises and a
//  failure of any one of them is a different defect:
//
//  1. **It loads.** A rewriter that produced bytes the reader refuses is a
//     rewriter that does not work, and this is the first thing to check.
//  2. **The shape survived.** The same history, the same objects, the same
//     keys' equality patterns, the same operations, the same conflicts.
//  3. **The data did not.** Every actor, key, message and scalar replaced.
test "an anonymized document with a map, a nested map, a list, text, a counter, a delete and a mark loads" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(7));
    defer pair.deinit(gpa);

    var loaded = try Document.load(gpa, std.testing.io, pair.anonymized_bytes, pair.anonymized.textEncoding(), .auto);
    defer loaded.deinit();
    try testing.expect(!loaded.isEmpty());
    // The reloaded document is the same document the rewrite produced, which is
    // the round trip upstream's test asserts
    // ([`anonymize.rs:477`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    var reloaded_shape = try Shape.init(gpa, &loaded);
    defer reloaded_shape.deinit();
    var written_shape = try Shape.init(gpa, &pair.anonymized);
    defer written_shape.deinit();
    try testing.expect(written_shape.eql(reloaded_shape));

    var source_shape = try Shape.init(gpa, &pair.source);
    defer source_shape.deinit();
    try testing.expect(source_shape.eql(written_shape));
    try checkPrivateDataChanged(gpa, &pair.source, &pair.anonymized);
}

//  **Every actor id is replaced, and the originals appear nowhere in the
//  result — asserted on the bytes.**
//
//  The bytes are the point: a count of distinct actors would be satisfied by a
//  rewrite that replaced one actor and left three, and the whole reason to
//  assert on the bytes is that the saved document is what a reader will see.
test "every actor id is replaced, and the source's actor bytes appear nowhere in the result" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(11));
    defer pair.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, pair.anonymized_bytes, actor_a) == null);
    try testing.expect(std.mem.indexOf(u8, pair.anonymized_bytes, actor_b) == null);
    // The source's own bytes and the result's are different documents, not the
    // same one saved twice.
    try testing.expect(!std.mem.eql(u8, pair.source_bytes, pair.anonymized_bytes));

    // The replacement ids are sixteen bytes each, they are distinct, and they
    // are not either source id — read from the result's own actor table.
    const actors = try pair.anonymized.getActors(gpa);
    defer gpa.free(actors);
    try testing.expectEqual(@as(usize, 2), actors.len);
    for (actors, 0..) |a, i| {
        try testing.expectEqual(@as(usize, 16), a.bytes.len);
        try testing.expect(!a.eql(ActorId.init(actor_a)));
        try testing.expect(!a.eql(ActorId.init(actor_b)));
        for (actors[i + 1 ..]) |b| try testing.expect(!a.eql(b));
    }
}

//  **Every key string and every commit message is replaced, and the same
//  original key becomes the same replacement in every object it appears in.**
//
//  The second half is the one the naive rewrite gets wrong, and it is the one
//  that changes what the document *means*: if `"private-shared"` is renamed one
//  way in the root map and another way in the nested map, the two objects have
//  stopped sharing a key, and the document's key set is no longer a function of
//  its content. The assertion is on the three operations' key bytes, read back
//  out of the result, because that is where a split would show.
test "every key and message is replaced, and one key in two objects is one replacement" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(13));
    defer pair.deinit(gpa);

    for ([_][]const u8{
        "private-key",            "private-bytes",          "private-number",      "private-counter",
        "private-timestamp",      "private-bool",           "private-unknown",     "private-null",
        "private-float",          "private-uint",           "private-list",        "private-text",
        "private-map",            "private-nested",         "private-shared",      "private-bold",
        "private commit message", "second private message", "private author name",
    }) |private| {
        try testing.expect(std.mem.indexOf(u8, pair.source_bytes, private) != null);
        try testing.expect(std.mem.indexOf(u8, pair.anonymized_bytes, private) == null);
    }

    // The three operations that wrote "private-shared" — one at the root and
    // two in the nested map, one of them by the second actor — must all carry
    // the same replacement.
    var before = try opsOf(gpa, &pair.source);
    defer before.deinit(gpa);
    var after = try opsOf(gpa, &pair.anonymized);
    defer after.deinit(gpa);
    try testing.expectEqual(before.rows.len, after.rows.len);

    var shared: usize = 0;
    var replacement: ?[]const u8 = null;
    for (after.rows, before.rows) |a, b| {
        const was = b.key_string orelse continue;
        if (!std.mem.eql(u8, was, "private-shared")) continue;
        shared += 1;
        const now = a.key_string orelse return error.MapKey;
        try testing.expect(!std.mem.eql(u8, now, "private-shared"));
        if (replacement) |first| {
            try testing.expectEqualStrings(first, now);
        } else replacement = now;
    }
    // Three operations wrote it: the fixture says so, and a count of two or
    // four would mean the fixture is not the one this test is about.
    try testing.expectEqual(@as(usize, 3), shared);
}

//  **A delete stays a delete, and a conflict stays a conflict.**
//
//  Both are read back out of the result's own operations, positioned by
//  `[change, index]`, which is legitimate **because the shapes have just been
//  shown equal** — equal shapes mean the same number of changes with the same
//  number of operations in the same order, so the positions correspond.
//
//  A rewrite that quietly resolved the conflict would have to delete one of the
//  two puts, and a rewrite that turned the delete into a put would have to
//  change its action. Both change something this test reads.
test "a deleted key stays deleted, and a conflicted register's conflict is preserved" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(17));
    defer pair.deinit(gpa);
    var before_shape = try Shape.init(gpa, &pair.source);
    defer before_shape.deinit();
    var after_shape = try Shape.init(gpa, &pair.anonymized);
    defer after_shape.deinit();
    try testing.expect(before_shape.eql(after_shape));

    var before = try opsOf(gpa, &pair.source);
    defer before.deinit(gpa);
    var after = try opsOf(gpa, &pair.anonymized);
    defer after.deinit(gpa);

    // **Located by what the row is, not by where it sits.** A positional index
    // into the operation stream is a fixture detail, and the collector re-encodes
    // a document's operations in the op set's row order — so an index that is
    // right today is a test that silently measures a different operation after
    // a fixture change. What each row *is* is what the rewrite claims to
    // preserve.
    const deleteBefore = findRow(&before, .delete, "private-bytes") orelse return error.MissingKey;
    const deleteAfter = findRowByCtr(&after, .delete, deleteBefore.ctr) orelse return error.MissingKey;
    try testing.expectEqual(Action.delete, deleteBefore.action);
    try testing.expectEqual(Action.delete, deleteAfter.action);
    try testing.expectEqual(@as(usize, 1), deleteBefore.pred_count);
    try testing.expectEqual(@as(usize, 1), deleteAfter.pred_count);
    // It still succeeds the operation that wrote the key, and that operation is
    // still the one it named: **the counter is the part of an op id the rewrite
    // keeps**, so it is the same counter on both sides.
    try testing.expectEqual(@as(u32, 5), deleteBefore.predsOf(before.preds)[0].counter);
    // It is the *same* operation: its own counter is the same too.
    try testing.expectEqual(deleteBefore.ctr, deleteAfter.ctr);
    try testing.expectEqual(
        deleteBefore.predsOf(before.preds)[0].counter,
        deleteAfter.predsOf(after.preds)[0].counter,
    );

    // The conflict: two puts of the same key, one succeeding the first put and
    // one with no predecessor at all, and **neither naming the other**.
    // The two puts of the conflicted register: one in each change.
    const first_put = findPutInChange(&before, 0, "private-key", 1) orelse return error.MissingKey;
    const first_put_after = findRowByCtr(&after, .set, first_put.ctr) orelse return error.MissingKey;
    const second_put = findPutInChange(&before, 1, "private-key", 0) orelse return error.MissingKey;
    const second_put_after = findRowByCtr(&after, .set, second_put.ctr) orelse return error.MissingKey;
    try testing.expectEqual(Action.set, first_put.action);
    try testing.expectEqual(Action.set, first_put_after.action);
    try testing.expectEqual(Action.set, second_put.action);
    try testing.expectEqual(Action.set, second_put_after.action);
    // The first succeeds the put that created the register; the second
    // succeeds nothing, and **that is the half of the conflict a rewrite is
    // most likely to "fix"**, and the one that makes the two concurrent.
    try testing.expectEqual(@as(usize, 1), first_put.pred_count);
    try testing.expectEqual(@as(usize, 0), second_put.pred_count);
    try testing.expectEqual(@as(usize, 1), first_put_after.pred_count);
    try testing.expectEqual(@as(usize, 0), second_put_after.pred_count);
    // The two puts are by different changes, which is the other half: two
    // changes by two authors is what makes them concurrent rather than
    // sequential.
    try testing.expect(first_put.change != second_put.change);
    try testing.expect(first_put_after.change != second_put_after.change);
    // And the two values are both still there and still different from each
    // other, so nothing merged them.
    try testing.expect(!first_put_after.value.eql(second_put_after.value));
}

// ── Instruments for the matrix ───────────────────────────────────────────────

/// One change, in one fresh document, from `spec`.
///
/// **One change and not the rich fixture**, because a check-error test is a
/// claim about *one* rule and a fixture with twenty-nine operations gives every
/// other rule a chance to fire first. The two documents the matrix pairs are
/// the same length, hold the same actions in the same order, and differ in
/// every field a rule looks at, so a test that puts one field back is the only
/// thing wrong.
fn oneChange(gpa: Allocator, spec: ChangeSpec) !Document {
    var doc = try Document.init(gpa, std.testing.io, .auto);
    errdefer doc.deinit();
    _ = try applySpec(gpa, &doc, spec);
    return doc;
}

/// Asserts that `checkPrivateDataChanged` refuses these two documents, and
/// that it refuses them for `which` and not for some other rule.
fn expectCheckError(gpa: Allocator, before: *Document, after: *Document, which: CheckError) !void {
    try testing.expectError(which, checkPrivateDataChanged(gpa, before, after));
}

/// The matrix's map keys, and the one replacement they all take.
///
/// **Built by concatenation and checked at compile time, because the widths
/// are the contract.** A structural string is compared character for character
/// and a width mismatch is itself a failure
/// ([`assert_structural_string_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:441-446`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)),
/// so "thirteen characters" has to be a fact about this file rather than about
/// how many letters any one line of it happens to hold.
const matrix_key_make = "private" ++ "-key00";
const matrix_key_put = "private" ++ "-value";
/// Thirteen `x`s, and **not one letter that appears in either source key**, so
/// every character is replaced and the reader does not have to check that by
/// eye.
const matrix_key_after = "xxxx" ++ "xxxx" ++ "xxxx" ++ "x";

comptime {
    if (matrix_key_make.len != matrix_key_after.len) {
        @compileError("the made-object key and its replacement must be the same width");
    }
    if (matrix_key_put.len != matrix_key_after.len) {
        @compileError("the put key and its replacement must be the same width");
    }
}

/// The `before` side of the matrix: one change by [`actor_a`] whose author,
/// timestamp, commit message, keys and values are all private data.
///
/// **Every field is private data on purpose.** A fixture with an empty message
/// would leave [`error.Message`] untested by any test that changes an
/// unrelated field, because a change with no message skips the check
/// ([`shape.rs:344`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
///
/// **No author name, and that is a constraint rather than an omission.** The
/// extra bytes are compared byte for byte
/// ([`assert_bytes_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
/// at [`shape.rs:459-464`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs))
/// and an author footer is `uleb(1) ‖ uleb(len) ‖ bytes`
/// ([`change.rs:376-386`](../../github-automerge-automerge/rust/automerge/src/change.rs)):
/// **the framing bytes are the same for every footer**, so two changes that
/// carry author names of the same length always share their first two bytes
/// and can never satisfy the rule. A real rewrite does satisfy it, because it
/// replaces the framing bytes as well
/// ([`anonymize.rs:88`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs))
/// — which is why a well-formed author name cannot be built as the "after"
/// side of a clean pair here, and why the [`error.ExtraBytes`] test gives both
/// sides the same name instead.
const matrix_before: ChangeSpec = .{
    .actor = actor_a,
    .seq = 1,
    .start_op = 1,
    .message = "private commit message",
    .time = 1_700_000_000,
    .ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_make) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .value = .{ .str = "secret value" } },
    },
};

/// The `after` side that breaks no rule. Two details in it are load-bearing:
///
/// * **Every key is one repeated letter that appears nowhere in the source's
///   keys**, so "no character the same" is a property of the fixture rather
///   than something a reader has to check by eye.
/// * **The value keeps its space and changes every letter**, because a content
///   string is compared with the whitespace kept and the rest replaced
///   ([`shape.rs:448-457`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
const matrix_after: ChangeSpec = .{
    .actor = actor_b,
    .seq = 1,
    .start_op = 1,
    .message = "zzzzzzz yyyyyy zzzzzzz",
    .time = 1_700_000_001,
    .ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .value = .{ .str = "qqqqqq qqqqq" } },
    },
};

/// Asserts that a content string was rewritten by the port's rule: **the same
/// byte length, whitespace and ASCII control kept, every other character
/// replaced** ([`anonymize.rs:226-238`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
fn expectContentReplaced(before: []const u8, after: []const u8) !void {
    try testing.expectEqual(before.len, after.len);
    var a = try std.unicode.Utf8View.init(before);
    var b = try std.unicode.Utf8View.init(after);
    var ia = a.iterator();
    var ib = b.iterator();
    while (true) {
        const x = ia.nextCodepointSlice() orelse {
            try testing.expect(ib.nextCodepointSlice() == null);
            return;
        };
        const y = ib.nextCodepointSlice() orelse return error.UnexpectedEnd;
        const cx = std.unicode.utf8Decode(x) catch return error.InvalidUtf8;
        const cy = std.unicode.utf8Decode(y) catch return error.InvalidUtf8;
        if (isUnicodeWhitespace(cx) or isAsciiControl(cx)) {
            try testing.expectEqual(cx, cy);
        } else {
            try testing.expect(cx != cy);
        }
    }
}

/// Asserts that a structural string was rewritten by the port's rule: **the
/// same byte length and no character the same**, whitespace and control
/// characters included ([`anonymize.rs:216-224`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
fn expectStructuralReplaced(before: []const u8, after: []const u8) !void {
    try testing.expectEqual(before.len, after.len);
    var a = try std.unicode.Utf8View.init(before);
    var b = try std.unicode.Utf8View.init(after);
    var ia = a.iterator();
    var ib = b.iterator();
    while (true) {
        const x = ia.nextCodepointSlice() orelse {
            try testing.expect(ib.nextCodepointSlice() == null);
            return;
        };
        const y = ib.nextCodepointSlice() orelse return error.UnexpectedEnd;
        const cx = std.unicode.utf8Decode(x) catch return error.InvalidUtf8;
        const cy = std.unicode.utf8Decode(y) catch return error.InvalidUtf8;
        try testing.expect(cx != cy);
    }
}

/// How many code units `s` takes in UTF-16, which is what a text object is
/// measured in on some platforms and therefore what a rewrite must preserve.
fn utf16Len(s: []const u8) !usize {
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        n += if (cp >= 0x10000) 2 else 1;
    }
    return n;
}

// ── The check-error matrix, one test per variant ────────────────────────────

//  **The fixture breaks no rule.** Every other test in this section puts one
//  field back and names the rule that notices, and this is what says the other
//  eleven rules stayed silent while it did — without it a test that trips
//  [`error.Hash`] proves nothing, because the pair would trip it anyway.
test "the check-error matrix's clean pair satisfies every rule" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var after = try oneChange(gpa, matrix_after);
    defer after.deinit();
    try checkPrivateDataChanged(gpa, &before, &after);
}

//  **A change the rewrite did not write, or one it invented.** This is the
//  only rule checked before any pairing happens, because with two different
//  change counts there is no pairing to do
//  ([`shape.rs:327-329`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)):
//  a rewrite that dropped one change would otherwise be reported as "this
//  change's actor was not replaced", which is a true statement about the wrong
//  change.
test "a rewrite with an extra change trips ChangeCount" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();

    // The clean rewrite, plus one more change by the same author at the next
    // sequence number. The extra change is itself clean, so the count is the
    // only thing wrong.
    var after = try oneChange(gpa, matrix_after);
    defer after.deinit();
    const heads = try after.getHeads(gpa);
    defer gpa.free(heads);
    const head = heads[0];
    var spec = matrix_after;
    spec.seq = 2;
    spec.start_op = 3;
    spec.deps = &.{head};
    spec.ops = &.{.{ .ctr = 3, .key = KeyRef.fromStr(matrix_key_after), .value = .{ .str = "qqqqqq qqqqq" } }};
    _ = try applySpec(gpa, &after, spec);

    try expectCheckError(gpa, &before, &after, error.ChangeCount);
}

//  **A change that came back with its own hash.** The whole document handed
//  back unchanged is the naive rewrite, and it is caught here first because the
//  hash covers the bytes ([`shape.rs:333`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
test "a change that kept its own hash trips Hash" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var after = try oneChange(gpa, matrix_before);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Hash);
}

//  **A change that kept its author, with every other field replaced.** The
//  timestamp and the message differ here on purpose: [`error.Hash`] and
//  [`error.Actor`] are checked in that order
//  ([`shape.rs:333-338`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)),
//  so a fixture that also kept its timestamp would say nothing about which of
//  the two fired.
test "a change that kept its author trips Actor" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var spec = matrix_after;
    spec.actor = actor_a;
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Actor);
}

//  **A change that kept its timestamp, with a different author and a
//  different message.**
test "a change that kept its timestamp trips Timestamp" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var spec = matrix_after;
    spec.time = matrix_before.time;
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Timestamp);
}

//  **A commit message that came back unchanged.**
test "a commit message that came back unchanged trips Message" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var spec = matrix_after;
    spec.message = matrix_before.message;
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Message);
}

//  **A change's author name, which travels as the chunk's extra bytes.** It
//  is the one piece of a change's *header* that is private, and it is checked
//  byte for byte, so the same name comes back as [`error.ExtraBytes`].
//
//  **Both sides carry the same name, and that is the only way to reach this
//  variant through a document.** A footer is `uleb(1) ‖ uleb(len) ‖ bytes`, so
//  two different well-formed author names of equal length share their two
//  framing bytes and [`checkBytesChanged`] would call them equal — which is
//  what the [`matrix_before`] comment records. The real rewrite has no such
//  difficulty: it replaces the framing bytes too
//  ([`anonymize.rs:88`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
//  so a rewritten footer shares nothing at all with its source.
test "a change whose author name came back unchanged trips ExtraBytes" {
    const gpa = testing.allocator;
    var before_spec = matrix_before;
    before_spec.author = "alice";
    var before = try oneChange(gpa, before_spec);
    defer before.deinit();
    var spec = matrix_after;
    spec.author = before_spec.author;
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.ExtraBytes);
}

//  **A change that gained or lost an operation.** Fewer and more are the same
//  defect from the checker's side: the pairing by position is no longer a
//  pairing.
test "a change that gained an operation trips OpCount" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .value = .{ .str = "qqqqqq qqqqq" } },
        .{ .ctr = 3, .key = KeyRef.fromStr(matrix_key_after), .value = .{ .str = "qqqqqq qqqqq" } },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.OpCount);
}

//  **An operation that became a different operation.** A `delete` that came
//  back as a `put` is the half of [`ActionShape.delete`] that matters: the
//  document is still a document and every string in it was still replaced.
test "an operation whose action changed trips Action" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, matrix_before);
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .action = .delete, .value = .null_value, .pred = &.{OpId.init(1, 0)} },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Action);
}

//  **A map key that kept a character, and a map key that came back as
//  something that is not a map key at all.** The second is the pairing half:
//  a source operation over a map key paired with a result operation anchored
//  to a sequence element means the rewrite changed what the operation *does*,
//  and the string comparison has nothing to compare.
test "a map key that kept a character, and a key that came back as an anchor, trip MapKey" {
    const gpa = testing.allocator;
    {
        var before = try oneChange(gpa, matrix_before);
        defer before.deinit();
        var spec = matrix_after;
        spec.ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
            .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .value = .{ .str = "qqqqqq qqqqq" } },
        };
        var after = try oneChange(gpa, spec);
        defer after.deinit();
        try expectCheckError(gpa, &before, &after, error.MapKey);
    }
    {
        // The second operation becomes an insert at the head of the list the
        // first one made, so the source's map key has no counterpart at all.
        const list = ExId{ .id = OpId.init(1, 0) };
        var before = try oneChange(gpa, matrix_before);
        defer before.deinit();
        var spec = matrix_after;
        spec.ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
            .{
                .ctr = 2,
                .obj = list,
                .key = KeyRef.fromElemId(ElemId.head()),
                .insert = true,
                .value = .{ .str = "qqqqqq qqqqq" },
            },
        };
        var after = try oneChange(gpa, spec);
        defer after.deinit();
        try expectCheckError(gpa, &before, &after, error.MapKey);
    }
}

/// The mark fixture's five operations: a text object, two inserts into it, a
/// mark begin over the first and a mark end after it.
///
/// **The same shape [`buildRich`] uses, and for the same reason.** Both halves
/// of a mark are inserts into a text object
/// ([`op_set.zig:4021-4025`](opset/op_set.zig)) and the end hangs *after* the
/// marked run, so a lone mark begin over an empty object is not a shape this
/// document layer stores — a fixture that used one is refused by
/// [`Document.applyChanges`] before the checker ever sees it, and the test would
/// then be asserting the refusal rather than the rule.
fn markOps(key: []const u8, first: []const u8, second: []const u8, name: ?[]const u8) [5]OpSpec {
    const text = ExId{ .id = OpId.init(1, 0) };
    const one = ElemId.fromOpId(OpId.init(2, 0));
    const two = ElemId.fromOpId(OpId.init(3, 0));
    return .{
        .{ .ctr = 1, .action = .make_text, .key = KeyRef.fromStr(key) },
        .{ .ctr = 2, .obj = text, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = first } },
        .{ .ctr = 3, .obj = text, .key = KeyRef.fromElemId(one), .insert = true, .value = .{ .str = second } },
        .{
            .ctr = 4,
            .obj = text,
            .key = KeyRef.fromElemId(one),
            .action = .mark,
            .mark = name,
            .value = if (name != null) ScalarValue{ .bool_value = true } else .null_value,
            .expand = true,
        },
        .{ .ctr = 5, .obj = text, .key = KeyRef.fromElemId(two), .action = .mark, .value = .null_value, .expand = true },
    };
}

//  **A mark whose name came back unchanged, and a mark whose name came back
//  absent.** A mark's name is structural and its value is content, so the two
//  halves are checked by different rules and a mark end has a name of no value
//  ([`shape.rs:375-378`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
//
//  **Both documents hold five operations with the same actions**, so the mark
//  is the only thing under test: a pairing that did not line up would be
//  reported as [`error.OpCount`], and an operation count is not what this test
//  is about.
test "a mark name that came back unchanged, and a mark end where a begin was, trip MarkName" {
    const gpa = testing.allocator;
    const before_ops = markOps(matrix_key_make, "a", "b", "private-bold");
    var before = try oneChange(gpa, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .message = "private commit message",
        .ops = &before_ops,
    });
    defer before.deinit();

    // **The same mark, renamed everywhere else and not renamed here.** The mark
    // name is a *structural* string, so it is the one string in the document a
    // rewrite cannot leave alone.
    const kept_ops = markOps(matrix_key_after, "x", "y", "private-bold");
    var kept = try oneChange(gpa, .{
        .actor = actor_b,
        .seq = 1,
        .start_op = 1,
        .message = "zzzzzzz yyyyyy zzzzzzz",
        .time = matrix_after.time,
        .ops = &kept_ops,
    });
    defer kept.deinit();
    try expectCheckError(gpa, &before, &kept, error.MarkName);

    // **The same change with the name dropped**, so operation four is a mark end
    // where the source had a mark begin: the mark's vocabulary is gone, and the
    // checker says so rather than comparing two absent names and finding them
    // equal.
    const dropped_ops = markOps(matrix_key_after, "x", "y", null);
    var dropped = try oneChange(gpa, .{
        .actor = actor_b,
        .seq = 1,
        .start_op = 1,
        .message = "zzzzzzz yyyyyy zzzzzzz",
        .time = matrix_after.time,
        .ops = &dropped_ops,
    });
    defer dropped.deinit();
    try expectCheckError(gpa, &before, &dropped, error.MarkName);
}

//  **An increment that kept its amount.** The op is still an increment and
//  everything else in the document was still replaced, which is exactly the
//  rewrite that would leave the counter's value readable while changing
//  nothing an operation-counting check can see.
test "an increment that kept its amount trips Increment" {
    const gpa = testing.allocator;
    var before = try oneChange(gpa, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .message = "private commit message",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_make) },
            .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .action = .increment, .value = .{ .int = 5 } },
        },
    });
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .action = .increment, .value = .{ .int = 5 } },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, error.Increment);
}

/// Two one-change documents whose only difference is the `set` value of their
/// second operation, for the [`error.Scalar`], [`error.Byte`],
/// [`error.Content`] and [`error.Retained`] rows.
///
/// **The expected error is a parameter because the check names it.** A `Bytes`
/// and an `Unknown` are compared byte for byte and report [`error.Byte`], a
/// `Str` is compared as a content string and reports [`error.Content`] or
/// [`error.Retained`], and the five numeric shapes report [`error.Scalar`]
/// ([`shape.rs:405-439`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
fn expectScalarRejected(
    gpa: Allocator,
    before_value: ScalarValue,
    after_value: ScalarValue,
    which: CheckError,
) !void {
    var before = try oneChange(gpa, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .message = "private commit message",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_make) },
            .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .value = before_value },
        },
    });
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .value = after_value },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try expectCheckError(gpa, &before, &after, which);
}

//  **A scalar that changed type, and a scalar that came back with its own
//  value** — for each of the five numeric shapes and for the type swap.
//
//  The float row is the one that is not obvious: `0.0` and `-0.0` compare equal
//  as numbers and are different encodings, so a check written on `==` would let
//  a sign flip through. The second half of this test is that such a pair is
//  **accepted**, which is what says the check is on the bits
//  ([`shape.rs:419-420`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
test "a scalar that kept its value, or changed its type, trips Scalar" {
    const gpa = testing.allocator;
    // The type is the shape: an `Int` that came back as a `Str` is a different
    // document, not a less private one.
    try expectScalarRejected(gpa, .{ .int = 42 }, .{ .str = "qqqqqq qqqqq" }, error.Scalar);
    try expectScalarRejected(gpa, .{ .int = 42 }, .{ .int = 42 }, error.Scalar);
    try expectScalarRejected(gpa, .{ .uint = 7 }, .{ .uint = 7 }, error.Scalar);
    try expectScalarRejected(gpa, .{ .float = 0.0 }, .{ .float = 0.0 }, error.Scalar);
    try expectScalarRejected(gpa, .{ .counter = .init(10) }, .{ .counter = .init(10) }, error.Scalar);
    try expectScalarRejected(gpa, .{ .timestamp = 1_700_000_000 }, .{ .timestamp = 1_700_000_000 }, error.Scalar);
    // The same bits with a different value type is still a type change.
    try expectScalarRejected(gpa, .{ .uint = 7 }, .{ .int = 7 }, error.Scalar);

    // **A sign flip is accepted**, because the bits differ. If this stopped
    // passing, the check would have become a comparison of numbers and would be
    // reading `0.0` and `-0.0` as the same value, which they are not on the wire.
    var before = try oneChange(gpa, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .message = "private commit message",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_make) },
            .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .value = .{ .float = 0.0 } },
        },
    });
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .value = .{ .float = -0.0 } },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try checkPrivateDataChanged(gpa, &before, &after);
}

//  **A byte run that kept a byte, a byte run that changed length, and a future
//  value's bytes that came back unchanged.**
//
//  The length rule is the first half of
//  [`assert_bytes_changed`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
//  and it is what makes a byte run's *length* the shape
//  ([`ScalarShape.bytes`]): a replacement of a different length would move
//  every later index that refers into it.
test "a byte run that kept a byte, changed length, or kept an unknown payload trips Byte" {
    const gpa = testing.allocator;
    try expectScalarRejected(gpa, .{ .bytes = &.{ 1, 2, 3, 4 } }, .{ .bytes = &.{ 1, 2, 3, 4 } }, error.Byte);
    try expectScalarRejected(gpa, .{ .bytes = &.{ 1, 2, 3, 4 } }, .{ .bytes = &.{ 1, 2, 3 } }, error.Byte);
    try expectScalarRejected(gpa, .{ .unknown = .{ .type_code = 12, .bytes = &.{ 7, 8 } } }, .{ .unknown = .{ .type_code = 12, .bytes = &.{ 7, 8 } } }, error.Byte);
}

//  **A string value that came back unchanged.**
test "a string value that came back unchanged trips Content" {
    const gpa = testing.allocator;
    try expectScalarRejected(gpa, .{ .str = "secret value" }, .{ .str = "secret value" }, error.Content);
}

//  **A character the rewrite is supposed to keep, changed.**
//
//  This is the assertion the naive rewrite fails and the reason the retained
//  characters are compared rather than skipped
//  ([`shape.rs:451-452`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
//  "secret value" and "bdfghjk" replace **all six** letters before the space
//  and then lose the space itself, so the document is still private, the words
//  are gone, and the only thing wrong is a character the rewrite promised to
//  keep — which is what a "replace every character" rewrite does.
test "a retained space that came back changed trips Retained" {
    const gpa = testing.allocator;
    try expectScalarRejected(gpa, .{ .str = "secret value" }, .{ .str = "bdfghjk" }, error.Retained);
}

/// The same pair as [`expectScalarRejected`], asserted to **pass** instead: the
/// two shapes upstream deliberately leaves alone, and the sign flip a
/// bit-comparing check has to let through.
fn expectScalarAccepted(gpa: Allocator, before_value: ScalarValue, after_value: ScalarValue) !void {
    var before = try oneChange(gpa, .{
        .actor = actor_a,
        .seq = 1,
        .start_op = 1,
        .message = "private commit message",
        .ops = &.{
            .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_make) },
            .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_put), .value = before_value },
        },
    });
    defer before.deinit();
    var spec = matrix_after;
    spec.ops = &.{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr(matrix_key_after) },
        .{ .ctr = 2, .key = KeyRef.fromStr(matrix_key_after), .value = after_value },
    };
    var after = try oneChange(gpa, spec);
    defer after.deinit();
    try checkPrivateDataChanged(gpa, &before, &after);
}

//  **The two scalars that are allowed to come back as they were.** A boolean
//  has no different value it is forbidden to draw and `Null` has no other
//  value of its own type, so upstream checks only that the type survived
//  ([`shape.rs:428-430`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
//  A checker that rejected these would be rejecting a correct rewrite.
test "a boolean and a null that came back unchanged are accepted" {
    const gpa = testing.allocator;
    try expectScalarAccepted(gpa, .{ .bool_value = true }, .{ .bool_value = true });
    try expectScalarAccepted(gpa, .null_value, .null_value);
    // **A boolean that came back flipped is accepted too**, because a boolean
    // that came back unchanged is accepted: the check is on the type alone.
    try expectScalarAccepted(gpa, .{ .bool_value = true }, .{ .bool_value = false });
}

// ── Shapes, across two documents ─────────────────────────────────────────────

/// One change, one put of a string, with the actor and the two strings as the
/// only things a caller chooses.
///
/// **The smallest document a shape can be compared on**, and every part of it
/// that could make two documents differ is a parameter: the actor id, the map
/// key and the string value. A fixture with a fixed key would answer "do two
/// documents with the same shape agree" with a yes whether or not the shape
/// code looks at keys at all.
fn buildPut(gpa: Allocator, actor: []const u8, key: []const u8, value: []const u8) !Document {
    return oneChange(gpa, .{
        .actor = actor,
        .seq = 1,
        .start_op = 1,
        .ops = &.{.{ .ctr = 1, .key = KeyRef.fromStr(key), .value = .{ .str = value } }},
    });
}

/// The two keys the equal-shape test uses: **eleven characters each, all
/// distinct in both.**
///
/// The count and the distinctness are the whole claim. [`StructuralStringShape`]
/// records, per character, its *first-appearance index in the whole document*
/// and its [`CharacterClass`], so two keys are the same shape exactly when they
/// have the same number of characters, the same classes and the same repeats.
/// Two runs of eleven distinct letters have no repeats and one class each, so
/// they are the same shape whatever the letters are.
const shape_key_plain = "abcdefghijk";
const shape_key_renamed = "lmnopqrstuv";

comptime {
    if (shape_key_plain.len != shape_key_renamed.len) {
        @compileError("the shape test's two keys must be the same width");
    }
}

/// The two values the equal-shape test uses: **twelve characters each, with the
/// space in the same place.** A content string's shape is its characters'
/// classes plus the retained characters themselves
/// ([`ContentStringShape`]), so the replacement has to be as long as the source
/// and has to keep its whitespace in the same position.
const shape_value_plain = "secret value";
const shape_value_renamed = "bdfghj bdfgh";

comptime {
    if (shape_value_plain.len != shape_value_renamed.len) {
        @compileError("the shape test's two values must be the same width");
    }
}

/// Eleven characters of a different encoding class than ASCII, **checked at
/// compile time**: the test's claim is that a key of the same *character count*
/// and a different *class* is a different shape, and that claim is only made if
/// the two keys really do have the same number of characters.
const eleven_two_byte = "ééééééééééé";

comptime {
    if (eleven_two_byte.len != 22) {
        @compileError("eleven_two_byte must be eleven two-byte characters");
    }
}

/// How many code points `s` holds, which is what a document's text length means
/// when the document measures in graphemes.
fn codepointCount(s: []const u8) !usize {
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        _ = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        n += 1;
    }
    return n;
}

//  **The same shape detected across two documents that share nothing but their
//  structure.**
//
//  The two documents have different actor ids, a different map key and a
//  different string value, and the keys are chosen so that their *equality
//  patterns* match as well as their widths: "abcdefghijk" has eleven distinct
//  characters and so does its replacement, which is what
//  [`StructuralStringShape`] records. The values match on the same terms — the
//  same number of characters, with the space in the same place
//  ([`ContentStringShape`]).
//
//  **No literal signature is asserted anywhere in this file.** What a shape is
//  encodes is derived data, and the contract is the comparison, not the bytes.
test "two documents that differ in their actors and their strings have the same shape" {
    const gpa = testing.allocator;
    var one = try buildPut(gpa, actor_a, shape_key_plain, shape_value_plain);
    defer one.deinit();
    var two = try buildPut(gpa, actor_b, shape_key_renamed, shape_value_renamed);
    defer two.deinit();

    // **The actors really are different**, so an equal shape is a statement
    // about the shape rather than an accident of comparing a document with
    // itself. A shape records an actor *count*, never the ids
    // ([`ActorRanks`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)
    // at [`shape.rs:313-323`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)).
    const actors_one = try one.getActors(gpa);
    defer gpa.free(actors_one);
    const actors_two = try two.getActors(gpa);
    defer gpa.free(actors_two);
    try testing.expectEqual(@as(usize, 1), actors_one.len);
    try testing.expectEqual(@as(usize, 1), actors_two.len);
    try testing.expect(!actors_one[0].eql(actors_two[0]));

    var a = try Shape.init(gpa, &one);
    defer a.deinit();
    var b = try Shape.init(gpa, &two);
    defer b.deinit();
    try testing.expect(a.eql(b));
}

//  **A structural string that is not the same shape is not measured as one.**
//
//  Two ways a key can differ without changing its length, which is why a
//  character count alone would be too weak a shape:
//
//  * a key whose characters are two-byte UTF-8 rather than printable ASCII —
//    same eleven characters, different [`CharacterClass`], and the UTF-16 width
//    is what a text object's length depends on;
//  * a key with ten characters rather than eleven — same class throughout, a
//    different [`StructuralStringShape`] length.
test "a key of a different class, and a key of a different width, are different shapes" {
    const gpa = testing.allocator;
    var plain = try buildPut(gpa, actor_a, shape_key_plain, shape_value_plain);
    defer plain.deinit();
    var wide = try buildPut(gpa, actor_a, eleven_two_byte, shape_value_plain);
    defer wide.deinit();
    var narrow = try buildPut(gpa, actor_a, shape_key_plain[0..10], shape_value_plain);
    defer narrow.deinit();

    // **Same character count, different class.** The two-byte key really does
    // have eleven characters, so the only thing that differs is the class.
    try testing.expectEqual(
        try codepointCount(shape_key_plain),
        try codepointCount(eleven_two_byte),
    );

    var a = try Shape.init(gpa, &plain);
    defer a.deinit();
    var b = try Shape.init(gpa, &wide);
    defer b.deinit();
    var c = try Shape.init(gpa, &narrow);
    defer c.deinit();
    try testing.expect(!a.eql(b));
    try testing.expect(!a.eql(c));
    // And the two that must be equal are, so the three `eql` results above are
    // about the documents rather than about a comparison that always says no.
    try testing.expect(a.eql(a));
    try testing.expect(b.eql(b));
}

// ── The scalars, one variant at a time ───────────────────────────────────────

//  **Every scalar keeps its type, and every scalar that has a different value
//  of its own type is given one.**
//
//  The ten [`ScalarShape`] cases are the contract, so this walks all ten plus
//  the port's own `actor_id` case. `Null` and `Boolean` are the two that are
//  allowed to come back unchanged
//  ([`shape.rs:428-430`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs));
//  the other nine must not.
test "anonymizeScalar keeps every scalar's type and replaces every value that has an alternative" {
    const gpa = testing.allocator;
    var anon = try Anonymize.init(gpa, @splat(3));
    defer anon.deinit();

    // **The two shapes with no alternative of their own type.**
    try testing.expect((try anon.anonymizeScalar(.null_value)) == .null_value);
    try testing.expect((try anon.anonymizeScalar(.{ .bool_value = true })) == .bool_value);

    const int_value = try anon.anonymizeScalar(.{ .int = 42 });
    try testing.expect(int_value == .int);
    try testing.expect(int_value.int != 42);
    // **And in the `i32` domain, which is upstream's and is not incidental**:
    // signed integer columns are delta encoded, so a change whose counters
    // swung across the whole `i64` range would need deltas that do not fit
    // ([`anonymize.rs:186-189`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
    try testing.expect(int_value.int >= std.math.minInt(i32));
    try testing.expect(int_value.int <= std.math.maxInt(i32));

    const uint_value = try anon.anonymizeScalar(.{ .uint = 7 });
    try testing.expect(uint_value == .uint);
    try testing.expect(uint_value.uint != 7);

    // **A float is replaced on its bits**, so a sign flip counts as a
    // replacement and `0.0` is never drawn for `0.0`.
    const float_value = try anon.anonymizeScalar(.{ .float = 0.0 });
    try testing.expect(float_value == .float);
    try testing.expect(@as(u64, @bitCast(float_value.float)) != @as(u64, @bitCast(@as(f64, 0.0))));

    const counter_value = try anon.anonymizeScalar(.{ .counter = .init(10) });
    try testing.expect(counter_value == .counter);
    try testing.expect(counter_value.counter.current != 10);

    const timestamp_value = try anon.anonymizeScalar(.{ .timestamp = 1_700_000_000 });
    try testing.expect(timestamp_value == .timestamp);
    try testing.expect(timestamp_value.timestamp != 1_700_000_000);

    // **A byte run keeps its length, which is its shape, and loses every byte.**
    const bytes_value = try anon.anonymizeScalar(.{ .bytes = &.{ 1, 2, 3, 4 } });
    try testing.expect(bytes_value == .bytes);
    try testing.expectEqual(@as(usize, 4), bytes_value.bytes.len);
    for (bytes_value.bytes, &[_]u8{ 1, 2, 3, 4 }) |got, want| try testing.expect(got != want);

    // **A future value keeps its type code, which is its shape, and loses every
    // byte.**
    const unknown_value = try anon.anonymizeScalar(.{ .unknown = .{ .type_code = 12, .bytes = &.{ 7, 8 } } });
    try testing.expect(unknown_value == .unknown);
    try testing.expectEqual(@as(u8, 12), unknown_value.unknown.type_code);
    try testing.expectEqual(@as(usize, 2), unknown_value.unknown.bytes.len);
    for (unknown_value.unknown.bytes, &[_]u8{ 7, 8 }) |got, want| try testing.expect(got != want);

    // **A string is a content string**: whitespace kept, everything else
    // replaced, and the byte length the same.
    const str_value = try anon.anonymizeScalar(.{ .str = "secret value" });
    try testing.expect(str_value == .str);
    try expectContentReplaced("secret value", str_value.str);
}

//  **An actor id is mapped, not byte-replaced.**
//
//  The port's [`ScalarValue`] has an `actor_id` case upstream's does not, and an
//  actor id is private data. It goes through the actor table rather than the
//  synthetic alphabet ([`Anonymize.anonymizeScalar`]'s `actor_id` arm), so the
//  test needs an [`Anonymize`] that has seen a document — and it is the only
//  way to reach that arm at all.
test "an actor id scalar comes back as a different, known actor" {
    const gpa = testing.allocator;
    var doc = try buildRich(gpa);
    defer doc.deinit();
    var anon = try Anonymize.init(gpa, @splat(5));
    defer anon.deinit();
    var rewritten = try anon.run(&doc);
    defer rewritten.deinit();

    const mapped = try anon.anonymizeScalar(.{ .actor_id = .{ .bytes = actor_a } });
    try testing.expect(mapped == .actor_id);
    try testing.expect(mapped.actor_id.bytes.len != 0);
    try testing.expect(!std.mem.eql(u8, mapped.actor_id.bytes, actor_a));
    // **The same source actor maps to the same replacement**, which is the
    // key-consistency rule for actor ids.
    const again = try anon.anonymizeScalar(.{ .actor_id = .{ .bytes = actor_a } });
    try testing.expectEqualStrings(mapped.actor_id.bytes, again.actor_id.bytes);
}

// ── The "other than" contract ────────────────────────────────────────────────

/// How many draws the replacement tests make, and why that many is enough.
///
/// **The draw count is the argument, so it is written down.** The excluded value
/// is one draw out of a whole domain, so a test that let `n` draws through
/// would pass a *broken* exclusion with probability `(1 - 1/D)^n`:
///
/// | replacement | domain | hit probability | `n` | chance of missing a leak |
/// | --- | --- | --- | --- | --- |
/// | [`randomI64OtherThan`] | `i32`, `D = 2^32` | `2^-32` | 4096 | `2^-20` |
/// | [`randomU64OtherThan`] | `u64`, `D = 2^64` | `2^-64` | 4096 | `2^-52` |
/// | [`randomF64OtherThan`] | see below | **`1/2`** | 4096 | `2^-4096` |
///
/// The float row is the one that is not obvious, and it is the reason the
/// excluded value is `0.5` and not the `42.0` upstream's own test uses:
/// `std.Random.float` builds the pattern as `(1022 - @clz(draw)) << 52 | mantissa`,
/// so **the largest exponent field it ever produces is `1022`**, which is the
/// encoding of `0.5`, and `42.0` needs `1028` and can never be drawn at all.
/// With `0.5` excluded, **half of all draws are rejected and redrawn**, and a
/// replacement that compared with `==` instead of on the bits, or that forgot
/// the redraw, would fail within a handful of draws.
const exclusion_draws = 4096;

test "an integer replacement never comes back as the integer it replaced" {
    const gpa = testing.allocator;
    var anon = try Anonymize.init(gpa, @splat(2));
    defer anon.deinit();

    var signed: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer signed.deinit(gpa);
    var unsigned: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer unsigned.deinit(gpa);
    var any_negative = false;
    var any_above_i64 = false;

    for (0..exclusion_draws) |_| {
        const signed_draw = anon.randomI64OtherThan(42);
        try testing.expect(signed_draw != 42);
        // **The domain is `i32`, not `i64`**, and the reason is upstream's
        // ([`anonymize.rs:186-189`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
        // signed integer columns are delta encoded.
        try testing.expect(signed_draw >= std.math.minInt(i32));
        try testing.expect(signed_draw <= std.math.maxInt(i32));
        if (signed_draw < 0) any_negative = true;
        try signed.put(gpa, signed_draw, {});

        const unsigned_draw = anon.randomU64OtherThan(42);
        try testing.expect(unsigned_draw != 42);
        // **The whole `u64` range is drawn**, not a small part of it: a
        // generator that returned `42 + 1` every time would satisfy the
        // exclusion and nothing else.
        if (unsigned_draw > std.math.maxInt(i64)) any_above_i64 = true;
        try unsigned.put(gpa, unsigned_draw, {});
    }
    try testing.expect(any_negative);
    try testing.expect(any_above_i64);
    // **Nearly all of them are distinct.** A birthday collision over `n` draws
    // from `D` values has probability about `n² / 2D`, which here is `2^-12`,
    // so "more than half are distinct" cannot flake.
    try testing.expect(signed.count() > exclusion_draws / 2);
    try testing.expect(unsigned.count() > exclusion_draws / 2);
}

test "a float replacement never comes back as the bits it replaced, including a NaN's" {
    const gpa = testing.allocator;
    var anon = try Anonymize.init(gpa, @splat(2));
    defer anon.deinit();

    // **Half of these draws are `0.5` and are redrawn**, because `0.5` is the
    // largest value the generator can produce and is therefore the value whose
    // exclusion actually costs something. See [`exclusion_draws`].
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    for (0..exclusion_draws) |_| {
        const replacement = anon.randomF64OtherThan(0.5);
        try testing.expect(@as(u64, @bitCast(replacement)) != @as(u64, @bitCast(@as(f64, 0.5))));
        try seen.put(gpa, @bitCast(replacement), {});
    }
    try testing.expect(seen.count() > 64);

    // **A NaN is excluded by its bits and not by a comparison.** `NaN != NaN`
    // for every NaN, so a replacement compared with `==` would hand back a
    // different NaN's bit pattern and call it changed; the checker and the
    // replacement both work on the pattern, which is what is on the wire.
    const nan_bits: u64 = 0x7ff8000000000000;
    const original: f64 = @bitCast(nan_bits);
    for (0..exclusion_draws) |_| {
        const replacement = anon.randomF64OtherThan(original);
        try testing.expect(@as(u64, @bitCast(replacement)) != nan_bits);
    }

    // **And a sign flip counts as a replacement**, because `0.0 == -0.0` and the
    // two are different encodings. Asking for anything other than `0.0`'s own
    // bit pattern must therefore succeed on the first draw.
    for (0..exclusion_draws) |_| {
        const replacement = anon.randomF64OtherThan(0.0);
        try testing.expect(@as(u64, @bitCast(replacement)) != 0);
    }
}

// ── The two string rules, on their own ──────────────────────────────────────

//  **A structural string is seeded, consistent, and the same width.**
//
//  Upstream's own coverage
//  ([`anonymize.rs:413-437`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
//  two seeds give two different rewrites, the replacements are distinct from
//  one another, every source character changes, and the result is the same
//  width in bytes and in UTF-16 units. The consistency half is the property
//  that makes a key's replacement a function of the key
//  ([`anonymize.rs:216-224`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
//
//  **Distinctness is asserted across the whole set and not per string**: a
//  single printable ASCII character is replaced by a random derangement of
//  ninety-five members, so one seed pair agreeing on one character has
//  probability about `1/95` and asserting it per string would be a test that
//  fails about one run in ten. Upstream compares the arrays for the same reason.
test "a structural string is seeded, consistent, and the same width in bytes and in UTF-16" {
    const gpa = testing.allocator;
    var first = try Anonymize.init(gpa, @splat(3));
    defer first.deinit();
    var second = try Anonymize.init(gpa, @splat(4));
    defer second.deinit();
    const source = [_][]const u8{ "name", "email", "a", "b", "é", "界", "😀" };

    var rewritten: [source.len][]const u8 = undefined;
    var differently: [source.len][]const u8 = undefined;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (source, 0..) |value, i| {
        rewritten[i] = try first.anonymizeStructuralString(value);
        differently[i] = try second.anonymizeStructuralString(value);
        try expectStructuralReplaced(value, rewritten[i]);
        // **The same width in UTF-16 units as well as in bytes**, which is what
        // upstream asserts separately
        // ([`anonymize.rs:432-436`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
        // an index into a text object counts code points, UTF-16 units or bytes
        // depending on the platform, and all three have to survive.
        try testing.expectEqual(try utf16Len(value), try utf16Len(rewritten[i]));
        try testing.expectEqual(try codepointCount(value), try codepointCount(rewritten[i]));
        // **The same source string is the same replacement every time.** This is
        // the whole of key consistency, stated without a document: the
        // permutation is one table for the run, so `"name"` in one object and
        // `"name"` in another answer to the same key.
        try testing.expectEqualStrings(rewritten[i], try first.anonymizeStructuralString(value));
        // **Two different source strings do not collide**, or one key would
        // answer to another key's value.
        try testing.expect(seen.get(rewritten[i]) == null);
        try seen.put(gpa, rewritten[i], {});
    }
    try testing.expectEqual(source.len, seen.count());
    var differs = false;
    for (rewritten, differently) |a, b| {
        if (!std.mem.eql(u8, a, b)) differs = true;
    }
    try testing.expect(differs);
}

//  **A content string keeps what it must keep and replaces what it must
//  replace**, over whitespace, control characters, the ASCII alphabet and the
//  multi-byte classes
//  ([`anonymize.rs:226-238`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)).
test "a content string keeps its whitespace and control characters and replaces everything else" {
    const gpa = testing.allocator;
    var anon = try Anonymize.init(gpa, @splat(9));
    defer anon.deinit();
    for ([_][]const u8{
        "a",
        "Meeting with Alice \u{1F44B}\nTomorrow",
        "  leading and trailing  ",
        "tab\there",
        "é界\u{1F44B}",
        "\n\n\r\n",
        "",
    }) |value| {
        const rewritten = try anon.anonymizeContentString(value);
        try expectContentReplaced(value, rewritten);
    }
}

// ── Determinism ──────────────────────────────────────────────────────────────

/// The position of the change with this hash in `list`, or null. A linear scan
/// because a list of changes is three long and a map would need `ChangeHash` to
/// be a hash-map key for no gain.
fn indexOfHash(list: []const Built, hash: ChangeHash) ?usize {
    for (list, 0..) |built, i| {
        if (built.change.hash.eql(hash)) return i;
    }
    return null;
}

//  **The same seed rewrites the same document the same way, and a different
//  seed does not.** Upstream's own property
//  ([`anonymize.rs:474-475`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)),
//  and the reason the tests in this file can say anything about a particular
//  rewrite.
//
//  **Compared on the change hashes, not on `save`.** The hash is SHA-256 over
//  the change body, and the body is exactly what the seed decides; `save` wraps
//  it in a DEFLATE stream whose framing is not something anonymization promises
//  ([`AGENTS.md`](../../AGENTS.md) §"Invariants"). The saved bytes are asserted
//  equal as well, because within one process they are, and a difference there
//  would mean the rewrite was not reproducible at all.
test "the same seed rewrites the same document the same way, and a different seed does not" {
    const gpa = testing.allocator;
    var built = try buildRich(gpa);
    defer built.deinit();
    const built_bytes = try built.save(gpa);
    defer gpa.free(built_bytes);
    var source = try Document.load(gpa, std.testing.io, built_bytes, built.textEncoding(), .auto);
    defer source.deinit();

    var first = try anonymize(gpa, &source, @splat(7));
    defer first.deinit();
    var again = try anonymize(gpa, &source, @splat(7));
    defer again.deinit();
    var other = try anonymize(gpa, &source, @splat(8));
    defer other.deinit();

    var first_changes = try first.getChanges(gpa, &.{});
    defer first_changes.deinit(gpa);
    var again_changes = try again.getChanges(gpa, &.{});
    defer again_changes.deinit(gpa);
    var other_changes = try other.getChanges(gpa, &.{});
    defer other_changes.deinit(gpa);
    try testing.expectEqual(first_changes.len(), again_changes.len());
    try testing.expectEqual(first_changes.len(), other_changes.len());

    var any_different = false;
    for (first_changes.slice(), again_changes.slice(), other_changes.slice()) |x, y, z| {
        // **The same seed, byte for byte.** Two rewrites of one document that
        // disagree here would make every seeded assertion in this file a claim
        // about a coin flip.
        try testing.expect(x.change.hash.eql(y.change.hash));
        if (!x.change.hash.eql(z.change.hash)) any_different = true;
    }
    try testing.expect(any_different);

    const first_bytes = try first.save(gpa);
    defer gpa.free(first_bytes);
    const again_bytes = try again.save(gpa);
    defer gpa.free(again_bytes);
    const other_bytes = try other.save(gpa);
    defer gpa.free(other_bytes);
    try testing.expectEqualStrings(first_bytes, again_bytes);
    try testing.expect(!std.mem.eql(u8, first_bytes, other_bytes));

    // **And the shape does not notice the seed at all**, which is the whole
    // claim: two rewrites of one document, two different sets of hashes, one
    // shape.
    var first_shape = try Shape.init(gpa, &first);
    defer first_shape.deinit();
    var other_shape = try Shape.init(gpa, &other);
    defer other_shape.deinit();
    try testing.expect(first_shape.eql(other_shape));
    try checkPrivateDataChanged(gpa, &source, &other);
}

// ── The history, kept ────────────────────────────────────────────────────────

//  **Every change kept its place in the history and lost its identity.**
//
//  Ported from upstream's per-change comparison
//  ([`anonymize.rs:483-518`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
//  the sequence number, the first counter and the last one are the same on both
//  sides; the author, the timestamp and the message are different; and the
//  dependencies point at **the same positions**, which is how a history whose
//  every hash is new can still have the shape of the same DAG.
test "the rewrite keeps every change's position and dependencies and replaces its author, time and message" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(23));
    defer pair.deinit(gpa);

    var before = try pair.source.getChanges(gpa, &.{});
    defer before.deinit(gpa);
    var after = try pair.anonymized.getChanges(gpa, &.{});
    defer after.deinit(gpa);
    const source_changes = before.slice();
    const result_changes = after.slice();
    try testing.expectEqual(source_changes.len, result_changes.len);
    try testing.expect(source_changes.len >= 2);

    for (source_changes, result_changes) |x, y| {
        try testing.expectEqual(x.change.seq, y.change.seq);
        try testing.expectEqual(x.change.start_op, y.change.start_op);
        try testing.expectEqual(x.change.max_op, y.change.max_op);
        try testing.expect(!x.change.actor.eql(y.change.actor));
        try testing.expect(x.change.time != y.change.time);
        try testing.expect(x.change.message.len != 0);
        try testing.expect(!std.mem.eql(u8, x.change.message, y.change.message));

        // **The dependency edges, compared as positions rather than as hashes.**
        // Every hash is new on the far side, so comparing them would compare two
        // sets of unrelated values; what has to survive is which change
        // depended on which.
        try testing.expectEqual(x.change.deps.len, y.change.deps.len);
        for (x.change.deps, y.change.deps) |a, b| {
            const i = indexOfHash(source_changes, a) orelse return error.MissingKey;
            const j = indexOfHash(result_changes, b) orelse return error.MissingKey;
            try testing.expectEqual(i, j);
        }
    }
}

/// The next `Str` value inserted into `obj`, advancing `cursor` past it.
fn nextTextValue(rows: *const OpRows, obj: ExId, cursor: *usize) !?[]const u8 {
    while (cursor.* < rows.rows.len) {
        const row = rows.rows[cursor.*];
        cursor.* += 1;
        if (row.obj != .id) continue;
        if (row.obj.id.counter != obj.id.counter or row.obj.id.actor != obj.id.actor) continue;
        if (!row.insert) continue;
        return switch (row.value) {
            .str => |s| s,
            else => error.InvalidValueType,
        };
    }
    return null;
}

/// Asserts that `text` and `replacement` hold the same text: **the same
/// elements, the same characters in each, the same width in UTF-16 units, and
/// no character the rewrite was supposed to replace still in place.**
///
/// **Paired by position in the element list, which is legitimate because the
/// shapes have just been shown equal** — equal shapes mean the same operations
/// in the same order, so element `n` on one side is element `n` on the other.
fn expectSameText(
    gpa: Allocator,
    source: *Document,
    text: ExId,
    rewritten: *Document,
    replacement: ExId,
) !void {
    var before = try opsOf(gpa, source);
    defer before.deinit(gpa);
    var after = try opsOf(gpa, rewritten);
    defer after.deinit(gpa);

    var left: usize = 0;
    var right: usize = 0;
    var elements: usize = 0;
    var source_units: usize = 0;
    var result_units: usize = 0;
    while (true) {
        const x = try nextTextValue(&before, text, &left) orelse {
            try testing.expect((try nextTextValue(&after, replacement, &right)) == null);
            break;
        };
        const y = try nextTextValue(&after, replacement, &right) orelse return error.UnexpectedEnd;
        try expectContentReplaced(x, y);
        source_units += try utf16Len(x);
        result_units += try utf16Len(y);
        elements += 1;
    }
    // **A text object with nothing in it would make every assertion above
    // vacuous**, so the fixture is checked rather than assumed.
    try testing.expect(elements > 0);
    try testing.expectEqual(source_units, result_units);
}

//  **A text object is the same length after a rewrite, and none of its
//  characters survived.**
//
//  This is upstream's text half of
//  [`anonymizes_data_while_preserving_history_and_shape`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)
//  ([`anonymize.rs:522-536`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)):
//  the same element count, the same length in UTF-16 units, and a different
//  string. **Measured through the change chunks**, which is the instrument the
//  rest of this file uses, rather than through a reader the port does not have
//  ([`sequenceLength`](sequenceLength)'s comment says so).
test "a text object is the same length after a rewrite and none of its characters survived" {
    const gpa = testing.allocator;
    var pair = try richPair(gpa, @splat(29));
    defer pair.deinit(gpa);
    // **The text object is the one the second operation made**
    // ([`buildRich`]'s table), and the counter is what a rewrite keeps, so the
    // same counter names the same object on both sides.
    const source_text = try objectMadeAt(gpa, &pair.source, 2);
    const result_text = try objectMadeAt(gpa, &pair.anonymized, 2);
    try expectSameText(gpa, &pair.source, source_text, &pair.anonymized, result_text);
    try testing.expectEqual(
        textLength(&pair.source, gpa, source_text),
        textLength(&pair.anonymized, gpa, result_text),
    );
}

// ── A document a program built ──────────────────────────────────────────────

/// One fixed program in [`runInstruction`]'s six-byte instruction layout
/// ([`fuzz.rs:54-56`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)):
/// opcode, replica, then four operands.
///
/// **Every one of the eleven opcodes, across all three replicas.** A program
/// that left an opcode out would leave that opcode's column untested while the
/// list still looked thorough, which is the failure mode a fixture has.
///
/// Three things about the ordering are load-bearing rather than arbitrary:
///
/// * **The list is a counter list** ([`buildFuzzBase`] makes it with
///   `make_list`), and its three inserts are counters
///   ([`runInstruction`]'s opcode 2). The scalar shapes a list cannot hold are
///   exercised at the root instead.
/// * **The mark that spans something is the last edit** and the mark at line
///   twelve is the "text is empty, do nothing" branch: replica 2 has no text
///   element yet at that point. Both halves of opcode 8 are covered, one as an
///   operation and one as a refusal to build one.
/// * **The merge is last.** A change written after a merge has to continue the
///   counter its actor was using across the merge
///   ([`runInstruction`]'s opcode 9), and that bookkeeping is exercised by
///   `documentFromProgram`'s own final merge instead, which is the same code
///   with none of the hand-rolled counters in the way.
const fuzz_program = [_][6]u8{
    .{ 0, 0, 0, 0, 0, 0 }, // put a string at "alpha"
    .{ 0, 1, 1, 4, 0, 0 }, // put a float at "beta"
    .{ 10, 0, 0, 0, 0, 0 }, // make a map under "object-0"
    .{ 2, 0, 0, 5, 0, 0 }, // insert a counter into the list
    .{ 2, 1, 1, 5, 0, 0 }, // insert another counter, on another replica
    .{ 3, 0, 1, 5, 0, 0 }, // overwrite a list element with a counter
    .{ 4, 0, 0, 0, 0, 0 }, // delete a list element
    .{ 5, 0, 0, 0, 0, 0 }, // insert into the text
    .{ 5, 1, 2, 0, 0, 0 }, // insert into the text, on another replica
    .{ 6, 0, 0, 0, 0, 0 }, // delete from the text
    .{ 7, 0, 0, 0, 0, 0 }, // increment the counter
    .{ 8, 2, 0, 0, 0, 0 }, // mark begin and end, over an empty text
    .{ 0, 2, 2, 6, 0, 0 }, // put a timestamp at "gamma"
    .{ 10, 1, 3, 1, 0, 0 }, // make a table under "object-3"
    .{ 1, 2, 0, 0, 0, 0 }, // delete "alpha"
    .{ 0, 0, 0, 9, 0, 0 }, // put an unknown value at "alpha"
    .{ 2, 2, 0, 5, 0, 0 }, // insert a counter into the list, third replica
    .{ 5, 0, 0, 1, 0, 0 }, // insert into the text
    .{ 5, 0, 0, 0, 0, 0 }, // insert into the text again, so the mark has a span
    .{ 8, 0, 0, 0, 3, 3 }, // mark begin and end, not expanding
    .{ 9, 1, 0, 0, 0, 0 }, // merge replica 0 into replica 1
};

//  **A document built by a program that touches every opcode keeps its shape
//  and loses its data.**
//
//  This is the port's answer to upstream's `proptest!`
//  ([`randomized_documents_retain_their_shape`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)
//  at [`fuzz.rs:17-31`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)):
//  three replicas, a merge, concurrent edits, every opcode and every scalar
//  shape, and then the same two assertions the fuzz test makes — the shape
//  survived and nothing private did.
test "a document a program built with every opcode keeps its shape and loses its data" {
    const gpa = testing.allocator;
    var program: [fuzz_program.len * 6]u8 = undefined;
    for (fuzz_program, 0..) |instruction, i| {
        @memcpy(program[i * 6 ..][0..6], &instruction);
    }
    var source = try documentFromProgram(gpa, &program);
    defer source.deinit();
    var rewritten = try anonymize(gpa, &source, @splat(19));
    defer rewritten.deinit();

    // **The program really did what it claims**, or the two assertions below are
    // about a smaller document than the one they are written for: every action
    // the change-op action column can carry, three actors, and more operations
    // than the base change alone.
    var rows = try opsOf(gpa, &source);
    defer rows.deinit(gpa);
    try testing.expect(rows.rows.len > 20);
    var actions: [8]bool = @splat(false);
    for (rows.rows) |row| actions[@intFromEnum(row.action)] = true;
    for (actions) |seen| try testing.expect(seen);
    const actors = try source.getActors(gpa);
    defer gpa.free(actors);
    try testing.expectEqual(@as(usize, 3), actors.len);

    var source_shape = try Shape.init(gpa, &source);
    defer source_shape.deinit();
    var result_shape = try Shape.init(gpa, &rewritten);
    defer result_shape.deinit();
    try testing.expect(source_shape.eql(result_shape));
    try checkPrivateDataChanged(gpa, &source, &rewritten);
}

// ── The per-change arena reset ──────────────────────────────────────────────

/// The longest payload [`buildManyChanges`] will build a change around.
const many_payload_max = 4096;

/// The author names [`buildManyChanges`] gives its two actors, **one each** —
/// the same two names [`buildRich`] uses, so a footer in this fixture is the
/// same shape as a footer anywhere else in this file.
const many_author_a = "private author name";
const many_author_b = "private author two";

/// A document of `count` changes, each carrying one string value of
/// `payload_len` bytes, alternating between two actors and each depending on
/// the one before it.
///
/// **Every change is the same width as every other, and that is the fixture's
/// whole purpose.** The measurement below compares the arena bytes one change
/// costs against the arena bytes `count` changes cost, and that comparison only
/// means something if a change is the same size wherever it sits. So the keys
/// and the messages are zero-padded to a fixed width, and the payload is
/// filled with one repeated character that changes with the index: same
/// length, different content. **The two changes carrying an author footer are
/// the widest**, and the yardstick the measurement builds with
/// `buildManyChanges(gpa, 1, payload_len)` is change zero, footer and all, so
/// the widest change in the document and the yardstick are the same width.
///
/// **Two actors and a dependency chain, not one of each**, so the run exercises
/// both `mapActor` calls — the header's own actor and each named
/// `other_actor` — and the `hashes` map, which are the three things in the
/// loop that are not per-change arena work and so must survive the reset.
///
/// **One author per actor, and each rides only that actor's first change.**
/// An actor has one author, and the format says which change carries it:
/// upstream stamps the author at `seq == 1`
/// ([`automerge.rs:568`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and asserts that no other change carries one
/// ([`change_graph.rs:563-566`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
/// which is the rule this port's own writer follows
/// ([`authorFooter`](transaction.zig)). A second footer for an actor is
/// refused by the screen in front of a merge as `error.DuplicateAuthor`
/// ([`batch.rs:1084-1090`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
///
/// **That refusal is the author table answering and not the actor table.** The
/// hypothesis it invites — that an actor id repeated across the fixture needs
/// a per-change index out of [`applySpec`], or that the actors have to be
/// interleaved differently — is wrong on this file's own evidence:
/// [`Document.putActorRef`](doc.zig) interns an actor once and is a lookup on
/// every change after that, so the same actor across `count` changes is what
/// the fixture wants and never what is refused. What the screen reads is
/// [`Document.getAuthorForActor`](doc.zig), which holds one name per actor, and
/// an actor that has one already is a duplicate the moment a second footer
/// arrives.
fn buildManyChanges(gpa: Allocator, count: usize, payload_len: usize) !Document {
    std.debug.assert(payload_len <= many_payload_max);
    var doc = try Document.init(gpa, std.testing.io, .auto);
    errdefer doc.deinit();

    var key_buf: [12]u8 = @splat(0);
    var message_buf: [24]u8 = @splat(0);
    var payload: [many_payload_max]u8 = undefined;

    var previous: ChangeHash = ChangeHash.zero;
    // **The type is spelled out, not inferred.** `= ExId.root` alone infers
    // the union's enum tag type, because `.root` is a void field, and the
    // first assignment into it would not coerce.
    var previous_map: ExId = .root;
    var have_previous = false;
    for (0..count) |i| {
        const second = i % 2 == 1;
        const actor = if (second) actor_b else actor_a;
        const seq: u64 = @intCast(i / 2 + 1);
        const actor_index = try doc.putActorRef(gpa, .{ .bytes = actor });
        const ctr = 2 * i + 1;
        const name: []const u8 = if (second) many_author_b else many_author_a;

        const key = try std.fmt.bufPrint(&key_buf, "private-{d:0>4}", .{i});
        const message = try std.fmt.bufPrint(&message_buf, "private message {d:0>4}", .{i});
        @memset(payload[0..payload_len], @truncate('a' + @as(u8, @intCast(i % 26))));

        // The map this change makes on the root...
        const made = ExId{ .id = OpId.init(@intCast(ctr), actor_index) };
        // **...and the map this change writes into, which from the second
        // change on is the previous change's.** That is the point of the
        // fixture's two actors: the object belongs to the *other* actor, so
        // the change's header carries a real `other_actors` entry and the run
        // has to map it as well as its own author. A fixture where every
        // change only ever touches its own objects would leave that whole
        // `mapActor` call untested, and it is one of the two the actor arena
        // exists for.
        const target = if (have_previous) previous_map else made;
        const deps: []const ChangeHash = if (have_previous) &.{previous} else &.{};
        const this_change = try applySpec(gpa, &doc, .{
            .actor = actor,
            .seq = seq,
            .start_op = @intCast(ctr),
            .deps = deps,
            // **Only the actor's first change carries the footer**; every change
            // after it would be a second author for an actor that has one.
            .author = if (seq == 1) name else null,
            .message = message,
            .ops = &.{
                .{ .ctr = @intCast(ctr), .action = .make_map, .key = KeyRef.fromStr(key) },
                .{
                    .ctr = @intCast(ctr + 1),
                    .obj = target,
                    .key = KeyRef.fromStr("private-payload"),
                    .value = .{ .str = payload[0..payload_len] },
                },
            },
        });
        previous = this_change;
        previous_map = made;
        have_previous = true;
    }
    return doc;
}

test "a run that resets the arena between changes writes the same bytes as a run that does not" {
    const gpa = testing.allocator;
    var source = try buildManyChanges(gpa, 8, 512);
    defer source.deinit();

    var reset_anon = try Anonymize.init(gpa, @splat(41));
    defer reset_anon.deinit();
    var reset_doc = try reset_anon.run(&source);
    defer reset_doc.deinit();
    const reset_bytes = try reset_doc.save(gpa);
    defer gpa.free(reset_bytes);

    var flat_anon = try Anonymize.init(gpa, @splat(41));
    defer flat_anon.deinit();
    var flat_doc = try flat_anon.runWithoutReset(&source);
    defer flat_doc.deinit();
    const flat_bytes = try flat_doc.save(gpa);
    // **The escape test.** A run that resets the arena between changes writes
    // byte-for-byte what a run that does not writes.
    //
    // The reset is only sound because nothing derived from the per-change arena
    // outlives the change that made it, and that is not a thing a reading of this
    // file can settle — it took reading three callees' ownership contracts
    // ([`change.zig:396-398`](change.zig), [`encoding.zig:1275-1282`](columnar/encoding.zig),
    // [`doc.zig:4882-4884`](doc.zig)) to be sure of. This is the assertion that
    // would stop being true the moment one of them changed: an escaped slice
    // would be read back out of a buffer the next change has already been handed,
    // and the change hashes would stop matching.
    //
    // **Both sides are compared twice, and the second comparison is the one that
    // localizes a failure.** A difference in `save` bytes says the documents
    // differ somewhere; a difference in one change's `body` says which change,
    // and a change's hash is taken over exactly those bytes.

    defer gpa.free(flat_bytes);

    try testing.expect(flat_bytes.len > 0);
    try testing.expectEqualSlices(u8, flat_bytes, reset_bytes);

    var reset_changes = try reset_doc.getChanges(gpa, &.{});
    defer reset_changes.deinit(gpa);
    var flat_changes = try flat_doc.getChanges(gpa, &.{});
    defer flat_changes.deinit(gpa);
    try testing.expectEqual(flat_changes.slice().len, reset_changes.slice().len);
    for (flat_changes.slice(), reset_changes.slice()) |flat, reset| {
        try testing.expectEqual(flat.change.hash, reset.change.hash);
        try testing.expectEqualSlices(u8, flat.body, reset.body);
    }

    // **And it is a real anonymization**, so the comparison above is not two
    // runs agreeing on a rewrite that copied the private data through.
    try checkPrivateDataChanged(gpa, &source, &reset_doc);
}

test "the per-change arena is bounded by one change, and without the reset it would not be" {
    // **The retained-bytes claim.** The per-change arena's high-water is one
    // change, not the whole document.
    //
    // This is the assertion the peak-RSS gate measures, stated about the thing
    // that causes it. Before the reset the arena's capacity was the sum of every
    // change's rewritten bytes; after, it is the largest single change's, which
    // is what `bounded` is compared against.
    //
    // **The second half of the test is what keeps the first half honest.** An
    // upper bound on its own is satisfied by an arena that allocates nothing, so
    // the test also measures the same document the same way *without* the reset
    // and requires that figure to be genuinely larger — both a multiple of the
    // one-change yardstick and a multiple of the bounded one. If a future change
    // made the per-change cost so small that the two figures converged, this
    // would fail rather than pass quietly on a workload that no longer has
    // anything to bound.

    const gpa = testing.allocator;
    const count = 24;
    const payload_len = 1024;

    // The yardstick: what one change costs, measured with the same code.
    var one_doc = try buildManyChanges(gpa, 1, payload_len);
    defer one_doc.deinit();
    var one = try Anonymize.init(gpa, @splat(43));
    defer one.deinit();
    var one_out = try one.run(&one_doc);
    defer one_out.deinit();
    const per_change = one.arena.*.queryCapacity();
    try testing.expect(per_change > 0);

    var many_doc = try buildManyChanges(gpa, count, payload_len);
    defer many_doc.deinit();

    var bounded = try Anonymize.init(gpa, @splat(43));
    defer bounded.deinit();
    var bounded_out = try bounded.run(&many_doc);
    defer bounded_out.deinit();
    const bounded_bytes = bounded.arena.*.queryCapacity();

    var flat = try Anonymize.init(gpa, @splat(43));
    defer flat.deinit();
    var flat_out = try flat.runWithoutReset(&many_doc);
    defer flat_out.deinit();
    const flat_bytes = flat.arena.*.queryCapacity();

    // **The peak is one change.** Two changes' worth is the slack: the last
    // change is not the first, and the arena's own growth is not its
    // high-water exactly.
    try testing.expect(bounded_bytes <= per_change * 2);
    // **And that is a real bound, not a small workload.** Without the reset the
    // same twenty-four changes cost an arena each.
    try testing.expect(flat_bytes > per_change * (count / 2));
    try testing.expect(flat_bytes > bounded_bytes * 4);
}

test "the actor map still answers for every actor after every change's reset" {
    // **The countercondition, pinned.** The actor map still answers for every
    // actor after a run has reset the arena once per change.
    //
    // This is the one escape the audit turned up: the map is built once, before
    // the first change, and `mapActor` reads it for every change's author and for
    // every `other_actor` a change names. In the reset arena it would be handed
    // back after the first change and every lookup afterwards would be a binary
    // search over memory the next column had already been given, which is why it
    // lives in `actor_arena` instead.
    //
    // **The assertions are about the shape of the answer rather than its exact
    // bytes, because the prefix is drawn from the seed and pinning it would only
    // pin the generator.** What must hold is that every actor still maps, that the
    // two are still two, and that each id still carries its own rank in the low
    // eight bytes — the invariant `buildActorMap` states and the one reused bytes
    // would not reproduce.

    const gpa = testing.allocator;
    var source = try buildManyChanges(gpa, 6, 128);
    defer source.deinit();

    var anon = try Anonymize.init(gpa, @splat(47));
    defer anon.deinit();
    var out = try anon.run(&source);
    defer out.deinit();

    // Six resets have happened by now.
    const map_a = try anon.mapActor(.{ .bytes = actor_a });
    const map_b = try anon.mapActor(.{ .bytes = actor_b });

    try testing.expectEqual(@as(usize, 16), map_a.bytes.len);
    try testing.expectEqual(@as(usize, 16), map_b.bytes.len);
    try testing.expect(!std.mem.eql(u8, map_a.bytes, map_b.bytes));
    // `actor_a` sorts before `actor_b`, so the ranks are zero and one.
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), map_a.bytes[8..16]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 7 ++ [_]u8{1}), map_b.bytes[8..16]);
    // **And an actor the document never had is still refused**, which is the
    // other half: a map that had been overwritten would answer for anything.
    try testing.expectError(error.MissingActor, anon.mapActor(.{ .bytes = actor_c }));
}

// ── Differences from upstream, in one place ─────────────────────────────────

// | here | upstream | why |
// | --- | --- | --- |
// | `checkPrivateDataChanged` returns one of fifteen [`CheckError`]s | `assert_private_data_changed` panics ([`shape.rs:326-386`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)) | a checker that cannot be run as a value cannot be run in a test that continues; the port's rule ([`AGENTS.md`](../../AGENTS.md)) |
// | one variant per `assert_`, plus [`error.ExtraBytes`] for `assert_bytes_changed` over a change's footer | the same assertions without names | a failing test has to say which promise broke |
// | `anonymize` takes thirty-two seed bytes | `anonymize` draws its own ([`anonymize.rs:27-29`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)) | Zig 0.16 has no source of randomness in `std` ([`types.zig:99-112`](types.zig)) |
// | [`Shape`] and [`Shape.eql`] are public | `ShapeSignature` is `pub(super)` ([`shape.rs:11`](../../github-automerge-automerge/rust/automerge/src/anonymize/shape.rs)) | the shape is half the contract this file exports, and a comparison nothing can call is a comparison nothing can test |
// | [`ScalarValue.actor_id`] is a scalar case and is mapped through the actor table | upstream's `ScalarValue` has no such case | the port's `ScalarValue` has one, and an actor id is private data |
// | the test matrix asserts two documents **agree or differ**, never a signature's bytes | upstream compares `ShapeSignature` values ([`anonymize.rs:479-481`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)) | a signature's encoding is derived data; the contract is the comparison, and a pinned literal breaks on any upstream change while proving nothing |
// | the "other than" draws exclude `0.5` | upstream's test excludes `42.0` ([`anonymize.rs:399-410`](../../github-automerge-automerge/rust/automerge/src/anonymize.rs)) | `std.Random.float` builds the exponent field as `1022 - @clz(draw)`, so `1022` is the largest field it produces and `42.0` — which needs `1028` — **can never be drawn at all**. Excluding `0.5` makes half of all draws redraw; excluding `42.0` exercises nothing |
// | [`fuzz_program`] is one fixed 21-instruction program | a `proptest!` over sixty-four random programs ([`fuzz.rs:17-31`](../../github-automerge-automerge/rust/automerge/src/anonymize/fuzz.rs)) | the property under test is that each opcode's shape survives a rewrite, and a property that needs sixty-four random draws to fail is a property nobody is waiting for |
// | [`applySpec`] encodes the change and then **re-parses it**, because a `Change` in this port is a header view over borrowed bytes ([`change.zig:99-141`](doc.zig)) rather than an owned, decoded change | a `Change` is built once by [`StoredChange::builder`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs) and comes out of `BuildChangeMetadata` already counted ([`automerge.rs:1287-1298`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) | the re-parse gives the change a real `header_len` and an owned `other_actors` array, and it loses everything a header does not carry — so `applySpec` has to put the op count back with [`Change.withOpCount`](change.zig) before `applyChanges` sees it. **This was the third site that had been missed**, after `Document.commit` and `AMchangeFromBytes`, and all three had the same shape |
