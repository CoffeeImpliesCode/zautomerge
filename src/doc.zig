//! The document: the actor table, the change graph, the change queue, the op
//! set, and the load / save / commit / merge surface around them.
//!
//! Upstream `automerge.rs` owns the raw state and `autocommit.rs` wraps it with
//! one held transaction. `Document` is the raw owner; `autocommit.AutoCommit`
//! owns the separate automatic lifecycle over the same transaction kernel.
//!
//! # The five fields upstream keeps, and the three this adds
//!
//! | field | upstream | here |
//! | --- | --- | --- |
//! | `ops` | `OpSet` | `Set` = [`opsetmod.OpSet`](opset/op_set.zig)**(opmod.ChangeOp)**, never generic |
//! | `change_graph` | `ChangeGraph` | `graph` |
//! | `queue` | `ChangeQueue` | `queue` |
//! | `authors` | `Authors` | `authors`, which this port makes the *actor* table ([`author.zig`](author.zig)) |
//! | `actor` | `Actor` | `actor`, [`Actor`] |
//!
//! Three more are forced by the port. **The allocator**, because every entry
//! point here takes one and a document is a value, not a global. **The string
//! table**, because the two string columns hold interned ids and every walk
//! reads them through it ([`opset/columns.zig`](opset/columns.zig) §`StringTable`).
//! **The arena**, because [`opsetmod.OpSet.insertActor`] stores an `ActorId`
//! whose bytes belong to whoever interned it, and the actor a batch interns is
//! the actor on a change the queue frees once it has applied it — see
//! [`Document.ownActorBytes`].
//!
//! # The op set is not generic, and that is forced
//!
//! [`batchmod.BatchApply`] splices `ChangeOp`s and `Columns(O).splice` is
//! typed to `O`, so a document that applies a remote change must hold
//! `OpSet(ChangeOp)`. Upstream's `OpSet` is concrete and only its `splice` is
//! generic over `OpLike` (`op_set.rs:60`, `:1291-1341`); this names the one
//! instantiation that matters.
//!
//! # What this file owns that nothing upstream's `automerge.rs` owns
//!
//! Three decoders and two encoders have no home in this port yet, and a
//! document cannot be loaded, merged, committed or exported without them:
//!
//! * **the change-op columns** — [`decodeChangeOps`] and [`encodeChangeOps`]
//!   are `ChangeOpsColumns` ([change_op_columns.rs:463-577](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)
//!   and [`change.rs:291-367`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs));
//! * **the change-graph columns** of a document chunk — [`decodeGraphCols`] and
//!   [`encodeGraphCols`] are
//!   [`ChangeGraphCols::load`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):926-1050
//!   and [`encode`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):236-272;
//! * **the change collector** — [`collectChanges`] is `ChangeCollector`
//!   ([collector.rs](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs)),
//!   which turns op-set rows back into change chunks. It is what `getChanges`,
//!   `getChangeByHash`, `getChangesAdded` and every document-chunk load go
//!   through, and it is the only way the document can answer a peer with a
//!   change it holds.
//!
//! **A change's hash is SHA-256 over its encoded bytes**, so everything in
//! those three is a compatibility boundary. `test/golden/change.jsonl` holds
//! two change chunks the Rust reference wrote together with the hashes it
//! computed for them, and the tests at the bottom of this file re-encode both
//! and check that the bytes and the hashes come back identical.
//!
//! # What this file does not declare
//!
//! * **`split`.** `API.md` lists `split(doc, gpa, heads)`, and there is no such
//!   method upstream: `grep "fn split"` over `automerge.rs` and
//!   `autocommit.rs` finds only `split_block`
//!   ([autocommit.rs:1200](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
//!   which splits a *text block* and belongs to the transaction slice. Nothing
//!   here approximates it.
//! * **A bundle as a document's first chunk** is **ported**, and it is
//!   [`collectBundleChanges`] that does it: upstream's
//!   `Bundle::to_changes` ([`automerge.rs`:945-954](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//!   is [`collectChanges`] fed the bundle's two column walks instead of the op
//!   set's rows, over the same [`Builder`]s and the same [`encodeOneChange`].
//!   The other direction — [`Document.bundle`] — is upstream's
//!   `Bundle::for_hashes` ([`automerge.rs`:1141-1146](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//!   and the two agree because they are the same conversion read backwards.
//! * **The patch log.** [`batchmod.applyChangesBatchToSink`] takes one, and
//!   [`Document.applyChanges`] passes [`patchesmod.PatchLog`] when
//!   [`Document.patch_log`] is **active** and [`batchmod.NullLog`] when it is
//!   not — which is upstream's own branch (`autocommit.rs:495-499`) and the
//!   whole of what recording costs a document nobody is diffing.
//!
//! # Two rules this file learned by breaking them
//!
//! **An `errdefer` written before a value moves into a longer-lived owner is a
//! double free waiting for the first failure.** This file did it three times:
//! once deinitialising a `ChangeOp` array whose unbuilt slots hold undefined
//! memory, once freeing an op set that a `Reconstructed` was about to own, and
//! once freeing a set of changes the change queue had already taken. Every one of
//! them passed while nothing failed. When a resource is handed to a new owner,
//! the old owner's `errdefer` has to be deleted, not left to fire.
//!
//! **A reader that is more permissive than its writer hides the writer's bug.**
//! [`decodeGraphCols`] reads a delta column as either sign, because the
//! reference's data needs that; and that leniency is exactly what let
//! [`encodeGraphCols`] write `.uint` cells into a `.delta` column for a whole
//! round without the load path noticing. The two halves have to agree on what
//! cells a column is made of, and where one side is deliberately forgiving the
//! other side's contract has to be written down next to it.
//!
//! # Ownership rules a caller must keep
//!
//! * `Document` is a single owner. Move it only when no transaction, iterator,
//!   callback, or caller holds its address; invalidate the source after a move.
//!   A shallow copy is not an independent document. Use `clone` or `fork`.
//!   The string table is heap allocated so returning a document by value does
//!   not invalidate the op set's table pointer.
//! * Every [`Changes`] this file hands out is owned by the caller:
//!   `Changes.deinit` frees the encoded bodies, and `Change.deinit` frees the
//!   `other_actors` array `parseChange` made.
//! * [`Document.applyChanges`] **copies** every change into the document's own
//!   arena before screening it, so a change the queue keeps stays valid after
//!   the caller's buffer is gone.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const marksmod = @import("marks.zig");
const opitermod = @import("opset/op_iter.zig");
const authorsmod = @import("author.zig");
const changerec = @import("change.zig");
const graphmod = @import("change_graph.zig");
const queuemod = @import("change_queue.zig");
const leb128 = @import("leb128.zig");
const columnarenc = @import("columnar/encoding.zig");
const colspec = @import("storage/column_spec.zig");
const chunkmod = @import("storage/chunk.zig");
const changechunk = @import("storage/change_chunk.zig");
const docchunk = @import("storage/document_chunk.zig");
const parse = @import("storage/parse.zig");
const bundlem = @import("storage/bundle.zig");
const opsetmod = @import("opset/op_set.zig");
const opmod = @import("opset/op.zig");
const optypes = @import("opset/types.zig");
const opcols = @import("opset/columns.zig");
const batchmod = @import("opset/batch.zig");
const clockmod = @import("clock.zig");
const patchesmod = @import("patches.zig");
const iterdoc = @import("iter/doc.zig");
const itermap = @import("iter/map_range.zig");
const iterlist = @import("iter/list_range.zig");
const iterspans = @import("iter/spans.zig");

const Allocator = std.mem.Allocator;
const Action = value.Action;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Bundle = bundlem.Bundle;
const Change = changerec.Change;
const ChangeGraph = graphmod.ChangeGraph;
const ChangeHash = types.ChangeHash;
const ChangeOp = opmod.ChangeOp;
const ChangeQueue = queuemod.ChangeQueue;
const Cell = columnarenc.Cell;
const ColumnDesc = colspec.ColumnDesc;
const ColumnSpec = colspec.ColumnSpec;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const Input = parse.Input;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const NodeIdx = graphmod.NodeIdx;
const Fragment = graphmod.Fragment;
const LevelRange = graphmod.LevelRange;
const ObjId = types.ExId;
const ObjMeta = types.ObjMeta;
const ObjType = types.ObjType;
const OpId = types.OpId;
const OpColumn = changechunk.OpColumn;
const ParseError = err.ParseError;
const RawColumns = colspec.RawColumns;
const ScalarValue = optypes.ScalarValue;
const StringTable = opcols.StringTable;
const TextEncoding = types.TextEncoding;
const TxOp = opmod.TxOp;
const ValueMeta = optypes.ValueMeta;

const testing = std.testing;

/// The op set a document holds, and never anything else.
///
/// **This is not a comptime parameter.** [`batchmod.BatchApply`] splices
/// `ChangeOp`s and [`opsetmod.OpSet.splice`] is typed to its own `O`, so a
/// document that applies a remote change must be this one instantiation
/// ([`op_set.rs:60`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
pub const Set = opsetmod.OpSet(ChangeOp);

/// What a read over the op set can raise: a walk's own four refusals
/// ([`opitermod.ReadOpError`](opset/op_iter.zig)), the document [`Error`], and
/// the checks upstream treats as impossible.
pub const OpError = opitermod.ReadOpError || Error || InternalError;

/// What [`Document.marks`] can raise — which is [`OpError`], and **not** the
/// indexed arm's [`opsetmod.MarksError`](opset/op_set.zig) that it used to be.
///
/// **The alias moved because the method was scoped, not because a check was
/// added.** With no isolation the fold answers from two indexes and raises
/// `MarksError`; at one it walks the object's winners, and a winner walk
/// answers in `OpError` — the same widening [`OpSet.calculateMarksAt`]
/// (opset/op_set.zig) makes and [`readmod.ReadError`](read.zig:143) already
/// publishes. `MarkError` therefore names [`OpError`] rather than repeating it,
/// so a reader who finds it in `sync/v1.zig`'s [`CompareError`] or
/// `sync/protocol.zig`'s convergence set knows the union it is part of is
/// unchanged: both already contain `ReadError`, which is `OpError`.
pub const MarkError = OpError;

/// What [`Document.load`] can raise.
///
/// [`ParseError`] because a document arrives from disk or from a peer;
/// [`opsetmod.LoadError`] because loading an op set rebuilds its index and
/// checks its mark order and migration reads operation rows; [`Error`] because the screen
/// refuses a duplicate; [`InternalError`] because a check upstream treats as
/// impossible is one here too. Optional scalar-string migration uses the native
/// transaction's complete write-error basis below. Naming TransactionError here
/// would create a cycle because WriteError already includes LoadError.
pub const LoadError = ParseError || opsetmod.LoadError || Error || InternalError ||
    opitermod.ReadOpError || opsetmod.SearchError || iterdoc.DiffError ||
    @import("hydrate.zig").OpHydrateError || error{ChangeType};

/// Constructor refusal: allocation, entropy unavailability, or cancellation.
pub const InitError = Allocator.Error || std.Io.RandomSecureError;

/// What the change-graph and collector surface can raise.
///
/// [`LoadError`] plus a walk's own four refusals, which are in neither the
/// parser's set nor the document's and are named by the walk that raises them.
pub const DocumentError = LoadError || opitermod.ReadOpError;

/// The document's string table: the interned map keys and mark names its two
/// string columns hold ([`StringTable`]).
///
/// **It interns, and interning copies.** The mark index's cache holds what
/// `resolve` answers for as long as the op set lives, so a table that resolved
/// an id to a borrow of the change it was read out of would dangle there;
/// copying in is what makes an id stable across a save and a load.
pub const Strings = struct {
    /// The allocator every call is given and every owned buffer belongs to.
    gpa: Allocator,
    /// The bytes themselves. One arena, so the table is released by one call.
    arena: std.heap.ArenaAllocator,
    /// The only ordered key storage. IDs are insertion indices, so entries
    /// are never removed or reordered. The map borrows immutable arena bytes;
    /// its index replaces a vocabulary-wide scan without a second key table.
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    /// An empty table. `gpa` must be the allocator every later call passes.
    pub fn init(gpa: Allocator) Strings {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    /// Releases the ordered map and all its owned key bytes in one call.
    pub fn deinit(self: *Strings) void {
        self.map.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The [`StringTable`] the op set and every walk read through. The context
    /// is this table, so the table must outlive every walk it handed out.
    pub fn table(self: *Strings) StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }

    /// How many strings the table holds, which is the number of ids it can
    /// name.
    pub fn count(self: *const Strings) usize {
        return self.map.count();
    }

    /// The bytes of the string `id` names, or the empty string for an id the
    /// table never handed out. Never traps: a walk over a row whose id is out
    /// of range is reading a corrupt column, and an empty key is a better
    /// answer than a panic.
    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Strings = @ptrCast(@alignCast(ctx));
        const i: usize = id;
        const keys = self.map.keys();
        if (i >= keys.len) return &.{};
        return keys[i];
    }

    /// The id of `bytes`, interning it if the table has not seen it.
    /// `error.Overflow` once the table holds more strings than an id can name,
    /// which is `ParseError` because that is where a save fails too.
    /// Duplicates allocate nothing. A refusal publishes no key and consumes no
    /// ID; earlier resolved byte borrows remain valid until `deinit`.
    fn intern(ctx: *const anyopaque, bytes: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Strings = @ptrCast(@alignCast(@constCast(ctx)));
        if (self.map.getIndex(bytes)) |i| {
            return std.math.cast(u32, i) orelse error.Overflow;
        }
        const len = self.map.count();
        const id = std.math.cast(u32, len) orelse return error.Overflow;
        const next_len = std.math.add(usize, len, 1) catch return error.Overflow;
        // Reserve before copying, and publish only once no fallible work remains.
        // A refused copy leaves capacity but no key or ID behind.
        try self.map.ensureTotalCapacity(gpa, next_len);
        const owned = try self.arena.allocator().dupe(u8, bytes);
        self.map.putAssumeCapacityNoClobber(owned, {});
        return id;
    }
};

/// The document's current actor: either bytes this document has not interned,
/// or the index it has ([`Automerge::set_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):367-373).
///
/// Upstream's `Actor::Unused` / `Actor::Cached` split, kept because the two
/// answers differ in one way that matters: a cached index survives an actor
/// insertion only because the port's [`opsetmod.OpSet`] rewrites indices
/// rather than invalidating them.
pub const Actor = union(enum) {
    /// An actor this document has not interned. `bytes` belong to the caller
    /// that set them, and the document copies them when it interns the actor.
    unused: ActorId,
    /// The index of an actor already in the table.
    cached: ActorIdx,

    /// The actor's index, when it is cached — exactly upstream's
    /// `get_actor_index`
    /// ([`automerge.rs:468-473`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    pub fn index(self: Actor) ?ActorIdx {
        return switch (self) {
            .cached => |i| i,
            .unused => null,
        };
    }

    /// **THE INVARIANT.** A cached index names a slot in the document's actor
    /// table, so it is only ever valid while the table has the same shape it
    /// had when the index was minted. `Document` has four tables that must
    /// stay in step — `ops.actors` ([`opsetmod.OpSet`], **the authoritative
    /// one**: it is what `put_actor_ref` binary-searches and what every stored
    /// `ActorIdx` means, `automerge.rs:1309-1314`), `authors` ([`authorsmod.Authors`]),
    /// the change graph's per-actor columns, and this cached index — and
    /// `Document.insertActor` and `Document.removeActor` are the **only two
    /// places that fan a change of shape out to all four**, and the only two
    /// that rewrite this cache. Two other routes change the table and are
    /// **not** a third fan: the load path replaces the table wholesale and
    /// rebuilds every index with it ([`Document.reconstruct`]'s
    /// [`Document.adoptActorMirrors`]), and [`Document.applyChanges`] interns
    /// each incoming change's actors through [`Document.putActorRef`] before
    /// the batch runs, so [`batchmod.BatchApply.insertNewActors`]'s own
    /// insertion into the op set finds every actor already there. Upstream has
    /// the same two fan-outs
    /// (`Automerge::insert_actor` and `remove_actor`,
    /// [`automerge.rs:1301-1306`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
    /// and `:427-432`), and keeps this cache in step from them through the two
    /// methods below.
    ///
    /// These are upstream's `Actor::rewrite_with_new_actor` and
    /// `Actor::remove_actor`
    /// ([`automerge.rs:52-69`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// transcribed rather than inlined at the two callers: **the omission of
    /// `remove_actor` from `Document.removeActor` is what let a cached index
    /// outlive the slot it named**, and a rule that lives in one place is a
    /// rule the next reader can check.
    pub fn rewriteWithNewActor(self: *Actor, slot: ActorIdx) void {
        switch (self.*) {
            .unused => {},
            .cached => |cached| {
                if (cached >= slot) self.* = .{ .cached = cached + 1 };
            },
        }
    }

    /// Rewrites a cached index for the removal of the actor `dropped` from
    /// `slot`.
    ///
    /// **The three cases are three different answers** (`automerge.rs:53-61`):
    /// a slot below the cached one is none of its business; a slot above it
    /// moves it down by one; and the cached actor's *own* slot going away
    /// cannot leave the index alone, because the slot it named is about to be
    /// occupied by the actor that sorted after it. Upstream answers that last
    /// case by going back to `Unused` with the bytes it read out of the table
    /// first — **the actor stays the same actor, the index does not stay the
    /// same number** — which is the whole of the bug this method exists to
    /// prevent: a cached index left in place silently renames the document's
    /// current actor to whoever moved into the freed slot.
    ///
    /// **`dropped` is the actor the slot named, not the slot.** Upstream reads
    /// it here (`actors[index].clone()`, [`automerge.rs:56`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    /// because its caller's four lines cannot fail, so the table is intact for
    /// the whole call. The port's caller cannot promise that — it rewrites
    /// this union **last**, after the two fallible steps, so that a refusal
    /// leaves every table as it found it ([`Document.removeActor`]) — and by
    /// then the fan has already dropped the slot. So the caller reads the
    /// bytes out before it starts and hands them in.
    ///
    /// **That also removes the out-of-range fallback this method used to
    /// carry.** It read `actors[slot]` behind a bounds test and substituted an
    /// empty id, on the argument that the only caller bounds-checks the slot
    /// first — which it did not: `OpSet.removeActor`'s own bound is
    /// `ArrayList.orderedRemove`'s `assert`
    /// ([`opset/op_set.zig:1442`](opset/op_set.zig)), so an index past the end
    /// took the process down rather than returning an error. [`Document.removeActor`]
    /// now checks the bound itself, which is where a `Document` is not allowed
    /// to abort, and the fallback has no caller left.
    pub fn removeActor(self: *Actor, slot: ActorIdx, dropped: ActorId) void {
        const cached = switch (self.*) {
            .unused => return,
            .cached => |i| i,
        };
        if (cached < slot) return;
        if (cached > slot) {
            self.* = .{ .cached = cached - 1 };
            return;
        }
        self.* = .{ .unused = dropped };
    }
};

/// Policy for an unreadable tail after the first valid chunk.
pub const OnPartialLoad = enum { refuse, ignore };
/// Unchecked loading preserves stored heads without comparing them to derived heads.
pub const VerificationMode = enum { check, dont_check };
/// Optional migration of visible scalar strings in maps and lists.
pub const StringMigration = enum { no_migration, convert_to_text };
/// Load inputs are borrowed during the call; author bytes are copied into the owner.
pub const LoadOptions = struct {
    on_partial_load: OnPartialLoad = .refuse,
    verification_mode: VerificationMode = .check,
    string_migration: StringMigration = .no_migration,
    patch_log: ?*patchesmod.PatchLog = null,
    text_encoding: TextEncoding = TextEncoding.platformDefault(),
    author: ?[]const u8 = null,
};

/// What [`Document.stats`] reports
/// ([`ReadDoc::stats`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2300-2315).
///
/// Package and compiler provenance names this Zig build, not Rust's toolchain.
pub const Stats = struct {
    /// How many changes the graph holds.
    num_changes: u64,
    /// How many rows the op set holds.
    num_ops: u64,
    /// How many actors the table holds.
    num_actors: u64,
    /// Static package name from the package manifest.
    package_name: []const u8,
    /// Static package version from the package manifest.
    package_version: []const u8,
    /// Static version of the Zig compiler that built this module.
    compiler_version: []const u8,
};

/// An imported object identity and its live type. Actor bytes borrow the document.
pub const ImportedObject = struct {
    id: ExId,
    object_type: ObjType,
};

/// Change reconstruction details kept beside each graph node.
///
/// Upstream stores both in the change columns beside the graph
/// ([`ChangeGraphCols::load`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):926-1050).
/// The graph's internal [`changerec.ChangeMetadata`] has no `extra` field.
/// The owned public metadata combines that graph record with this sidecar;
/// the collector also needs it to reproduce the bytes covered by the hash.
/// Keeping the original `start_op` beside the footer lets every collector
/// path use the same reconstruction record, including empty changes.
pub const NodeInfo = struct {
    /// The counter of the change's first op, never zero.
    start_op: u64,
    /// The bytes after the op data: the author footer, or nothing. Copied into
    /// the document's arena, so it outlives the chunk it was read from.
    extra: []const u8,
};

/// A hash as lowercase hex, for a diagnostic. The caller owns the result.
fn fmtHash(hash: ChangeHash) [64]u8 {
    var out: [64]u8 = undefined;
    err.hexInto(&hash.bytes, &out);
    return out;
}

/// What a document chunk yields before anything is linked into the graph: its
/// op rows, its actor table, its change block, and the changes those rows
/// encode.
const Reconstructed = struct {
    /// The rows, with their index rebuilt and their mark order checked.
    ops: Set,
    /// The chunk's actor table, copied into the document's arena.
    actors: []ActorId,
    /// One entry per change the chunk holds, borrowing the chunk body.
    nodes: []GraphNode,
    /// The collector's view of those changes, in the same order.
    metas: []BuildMeta,
    /// The encoded changes, each dependency before the change that needs it.
    changes: Changes = .{},
    /// Set once the op set has been handed to a document, so `deinit` does not
    /// free it twice.
    installed: bool = false,

    fn deinit(self: *Reconstructed, gpa: Allocator) void {
        if (!self.installed) self.ops.deinit();
        gpa.free(self.actors);
        freeGraphNodes(gpa, self.nodes);
        freeMetas(gpa, self.metas);
        self.changes.deinit(gpa);
        self.* = undefined;
    }
};

/// One encoded change: its body, and the change that borrows it.
///
/// The port's `Change` borrows its bytes and owns one allocation
/// (`other_actors`), so the two cannot be separated: a caller that wants the
/// bytes must keep the pair.
pub const Built = struct {
    /// The change chunk body, header included: exactly what the hash was taken
    /// over. Owned here.
    body: []u8,
    /// The change, borrowing `body`.
    change: Change,

    /// The change's hash, `SHA-256(0x01 ‖ uleb128(body.len) ‖ body)`.
    pub fn hash(self: *const Built) ChangeHash {
        return self.change.hash;
    }

    /// Frees the body and the change's `other_actors` array.
    pub fn deinit(self: *Built, gpa: Allocator) void {
        self.change.deinit(gpa);
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// Caller-owned change metadata matching Rust `op_set2/types.rs:749-774`.
///
/// `actor.bytes`, `author`, `message`, `deps` and `extra` are independent copies:
/// no field borrows the document. One value has one owner, released exactly once
/// with `deinit(gpa)` using the allocator passed to the reader. Assignment copies
/// the ownership handle, not the storage; copies must not be released separately.
pub const ChangeMetadata = struct {
    actor: ActorId,
    /// UTF8 author associated with the actor, or `null` when none is known.
    author: ?[]const u8,
    seq: u64,
    /// Inclusive operation interval; an empty change has `max_op = start_op - 1`.
    start_op: u64,
    max_op: u64,
    /// Signed Unix timestamp in seconds, as stored in the change.
    timestamp: i64,
    /// Stored UTF8 message, or `null` for an absent/empty encoded message.
    message: ?[]const u8,
    deps: []const ChangeHash,
    hash: ChangeHash,
    /// Complete opaque footer bytes, including any encoded author.
    extra: []const u8,

    /// Releases every owned field. The value and its views are invalid afterward.
    pub fn deinit(self: *ChangeMetadata, gpa: Allocator) void {
        gpa.free(self.actor.bytes);
        if (self.author) |bytes| gpa.free(bytes);
        if (self.message) |bytes| gpa.free(bytes);
        gpa.free(self.deps);
        gpa.free(self.extra);
        self.* = undefined;
    }
};

/// Single-owner metadata collection; neither the list nor its fields borrow a document.
/// Release once with `deinit(gpa)`, using the reader's allocator. Copies share ownership.
pub const ChangeMetas = struct {
    /// Metadata in dependency order. Views remain valid until this collection is released.
    items: std.ArrayList(ChangeMetadata) = .empty,

    /// Releases the metadata fields and the list; the value is invalid afterward.
    pub fn deinit(self: *ChangeMetas, gpa: Allocator) void {
        for (self.items.items) |*meta| meta.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }
};

/// A caller-owned list of [`Built`] changes in the producing reader's order.
pub const Changes = struct {
    /// The changes, in selection order; hash-batch requests need not be causal.
    items: std.ArrayList(Built) = .empty,

    /// How many changes the list holds.
    pub fn len(self: *const Changes) usize {
        return self.items.items.len;
    }

    /// Whether the list is empty, which is what a peer at the current heads
    /// gets.
    pub fn isEmpty(self: *const Changes) bool {
        return self.items.items.len == 0;
    }

    /// The changes, each paired with the body it borrows. The list must
    /// outlive every use of the slice.
    pub fn slice(self: *const Changes) []const Built {
        return self.items.items[0..];
    }

    /// The change at `index`, in selection order.
    pub fn at(self: *const Changes, index: usize) Change {
        return self.items.items[index].change;
    }

    /// Frees every change and the list.
    pub fn deinit(self: *Changes, gpa: Allocator) void {
        for (self.items.items) |*item| item.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }
};

// ── Owned column sets ───────────────────────────────────────────────────────

/// One encoded column, before it is concatenated into a data block.
const PendingColumn = struct {
    spec: ColumnSpec,
    bytes: []u8,
};

/// The operation columns of a change, and the actors the change named after
/// its own.
///
/// The second half is not decoration: a change chunk's header lists the actors
/// the op columns index, and a change whose two halves disagree is a change
/// whose reader resolves every actor index to the wrong actor.
pub const EncodedOps = struct {
    /// The fourteen columns, minus the ones this change does not carry.
    cols: OwnedColumns,
    /// The actors the change names after its own, in the order the actor
    /// mapping assigned them, which is ascending document index order.
    others: []ActorId,

    /// Frees the columns and the actor list.
    pub fn deinit(self: *EncodedOps, gpa: Allocator) void {
        self.cols.deinit(gpa);
        gpa.free(self.others);
        self.* = undefined;
    }
};

/// A column set and the data block its ranges index, both owned.
pub const OwnedColumns = struct {
    /// The columns, ascending by normalized specification.
    cols: RawColumns,
    /// The block the ranges index. Owned here.
    data: []u8,

    /// Frees the column list and the block.
    pub fn deinit(self: *OwnedColumns, gpa: Allocator) void {
        self.cols.deinit(gpa);
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// Appends `enc` to `pending` when it carries bytes, and frees it when it does
/// not. A column with no bytes is not a column: upstream drops it at
/// construction ([raw_column.rs:40-50](../../github-automerge-automerge/rust/automerge/src/columns/raw_column.rs), `:183`)
/// and a metadata count that included it would name a column no reader could
/// find.
///
/// **The bytes have exactly one owner at every point.** They are the caller's
/// `enc` before the call and `pending`'s after it — or freed here, once, when
/// the append is refused. A column with no bytes owns no allocation, but it is
/// released like any other so the contract is the same on every path and does
/// not depend on which branch a caller happened to take.
fn keepColumn(
    gpa: Allocator,
    pending: *std.ArrayList(PendingColumn),
    enc: columnarenc.Encoded,
) Allocator.Error!void {
    errdefer enc.deinit(gpa);
    if (!enc.isPresent()) {
        enc.deinit(gpa);
        return;
    }
    try pending.append(gpa, .{ .spec = enc.spec, .bytes = enc.bytes });
}

/// Appends both halves of a value column pair, in the pair's order, or frees
/// both.
///
/// **The pair is one value with two byte blocks, and the blocks arrive
/// together.** [`keepColumn`]'s contract applies to each half separately, so
/// staging them as two calls would leave the payload half with no owner for
/// exactly as long as the metadata half's append can be refused — which is the
/// whole of the window between the two calls.
fn keepPair(
    gpa: Allocator,
    pending: *std.ArrayList(PendingColumn),
    pair: columnarenc.ValuePair,
) Allocator.Error!void {
    keepColumn(gpa, pending, pair.meta) catch |e| {
        pair.raw.deinit(gpa);
        return e;
    };
    try keepColumn(gpa, pending, pair.raw);
}

/// Frees the staged column bytes and empties the list, which is what a caller
/// does once [`finishColumns`] has copied them into its data block.
fn freePending(gpa: Allocator, pending: *std.ArrayList(PendingColumn)) void {
    for (pending.items) |col| gpa.free(col.bytes);
    pending.clearRetainingCapacity();
}

/// Concatenates the pending columns into one data block and builds the
/// descriptor list.
///
/// **The order is the order they were appended in**, which for every set this
/// file writes is ascending by normalized specification — `OpColumn`'s table
/// order is ([change_chunk.zig](storage/change_chunk.zig) §`op_column_table`),
/// and so is the change-graph column order
/// ([`change_graph.rs:259-269`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)) —
/// because `RawColumns::parse` refuses anything else
/// ([raw_column.rs:248-253](../../github-automerge-automerge/rust/automerge/src/columns/raw_column.rs)).
///
/// **`pending` is borrowed and stays the caller's on every path.** It is read
/// here and copied into the block below; the caller frees the staged bytes
/// itself, through the `defer` that owns them on a refusal and through the
/// `freePending` it runs once the block owns its copies. Releasing them here
/// as well freed the same allocations twice on both paths, and the crash was
/// in the second of the two.
fn finishColumns(gpa: Allocator, pending: []const PendingColumn) ParseError!OwnedColumns {
    var total: usize = 0;
    for (pending) |col| total += col.bytes.len;

    const data = try gpa.alloc(u8, total);
    errdefer gpa.free(data);
    const descs = try gpa.alloc(ColumnDesc, pending.len);
    errdefer gpa.free(descs);

    var at: usize = 0;
    for (pending, 0..) |col, i| {
        @memcpy(data[at .. at + col.bytes.len], col.bytes);
        descs[i] = .init(col.spec, col.bytes.len);
        at += col.bytes.len;
    }
    // `RawColumns.init` copies the descriptors into a list of its own, so this
    // array is spent the moment it returns. The `errdefer` above is what gives
    // it back when the refusal is the allocation inside `init`; freeing it in a
    // `catch` as well would release it a second time on that path.
    const cols = try RawColumns.init(gpa, descs, data);
    gpa.free(descs);
    return .{ .cols = cols, .data = data };
}

/// The actor mapping a change chunk uses: its own actor at index zero, and every
/// other actor the change references after it, in document actor order.
///
/// This is
/// [`ActorMapper`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):273-353.
/// [`change_actors.rs:10-22`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_actors.rs)
/// states the order, and it is the order the change's `other_actors` list is
/// written in. Because a document's actor table is sorted by byte-lexicographic
/// order ([`author.zig`](author.zig)), ascending document index is exactly the
/// "lexicographic order" upstream means.
const ActorMapper = struct {
    /// The document's actors, indexed by actor index.
    actors: []const ActorId,
    /// One flag per document actor: has anything mentioned it.
    seen: []bool,
    /// The change-local index of each document actor, or null for one nothing
    /// mentioned.
    mapping: []?ActorIdx,
    /// The document indices of the actors the change names after its own, in
    /// ascending order.
    others: std.ArrayList(ActorIdx) = .empty,

    fn init(gpa: Allocator, actors: []const ActorId) Allocator.Error!ActorMapper {
        const seen = try gpa.alloc(bool, actors.len);
        errdefer gpa.free(seen);
        @memset(seen, false);
        const mapping = try gpa.alloc(?ActorIdx, actors.len);
        errdefer gpa.free(mapping);
        @memset(mapping, null);
        return .{ .actors = actors, .seen = seen, .mapping = mapping };
    }

    fn deinit(self: *ActorMapper, gpa: Allocator) void {
        self.others.deinit(gpa);
        gpa.free(self.seen);
        gpa.free(self.mapping);
        self.* = undefined;
    }

    /// Clears the per-change state and sizes it back to the actor count.
    /// Upstream's `reset`
    /// ([change.rs:295-303](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs)),
    /// which truncates and re-resizes rather than freeing, so a large document
    /// does not allocate per change.
    fn reset(self: *ActorMapper, gpa: Allocator) Allocator.Error!void {
        @memset(self.seen, false);
        @memset(self.mapping, null);
        self.others.clearRetainingCapacity();
        try self.others.ensureUnusedCapacity(gpa, self.actors.len);
    }

    /// Marks an actor as referenced. An index past the table is
    /// `error.WrongActorTable`, the [`InternalError`] variant that says exactly
    /// that.
    fn processActor(self: *ActorMapper, actor: ActorIdx) InternalError!void {
        const i: usize = actor;
        if (i >= self.seen.len) return error.WrongActorTable;
        self.seen[i] = true;
    }

    /// Marks every actor `op` mentions: its object's, its key's and every
    /// predecessor's
    /// ([`ActorMapper::process_op`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):309-322).
    fn processOp(self: *ActorMapper, op: anytype) InternalError!void {
        if (op.objActor()) |a| try self.processActor(a);
        if (op.keyActor()) |a| try self.processActor(a);
        for (op.pred()) |p| try self.processActor(p.actor);
    }

    /// Assigns change-local indices: the change's own actor at zero, then every
    /// actor it mentioned in ascending document index order
    /// ([`build_mapping`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):324-340).
    ///
    /// The default actor's flag is cleared first, so it is not also listed in
    /// `others` — which is what makes `others` exactly the change's
    /// `other_actors`.
    fn buildMapping(
        self: *ActorMapper,
        gpa: Allocator,
        default_actor: ActorIdx,
    ) (Allocator.Error || InternalError)!void {
        const at: usize = default_actor;
        if (at >= self.seen.len) return error.WrongActorTable;
        self.seen[at] = false;
        self.mapping[at] = 0;

        var next: ActorIdx = 1;
        for (self.seen, 0..) |flag, i| {
            if (!flag) continue;
            self.others.appendAssumeCapacity(@intCast(i));
            self.mapping[i] = next;
            next += 1;
        }
        _ = gpa;
    }

    /// The change-local index of a document actor, or the [`InternalError`]
    /// that says the mapper never saw it — upstream's `mapping[i].unwrap()`
    /// ([change.rs:116](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs), `:203`).
    fn remap(self: *const ActorMapper, actor: ActorIdx) InternalError!ActorIdx {
        const i: usize = actor;
        if (i >= self.mapping.len) return error.WrongActorTable;
        return self.mapping[i] orelse error.WrongActorTable;
    }

    /// The actor the change-local index names, or the document's table being
    /// too short.
    fn actorFor(self: *const ActorMapper, local: ActorIdx) ParseError!ActorId {
        const i: usize = local;
        if (i >= self.actors.len) return error.MissingActor;
        return self.actors[i];
    }
};

/// Builds the `Cell` list for one nullable column and, when at least one row
/// is present, encodes and keeps it.
///
/// **A column whose every row is absent is not written.** Upstream says this
/// with `encode_to_unless(data, rows, None)`
/// ([change.rs:206-224](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs)),
/// [`:241-245`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):
/// the encoder is handed the value to suppress and writes nothing when every
/// row equals it. The port's encoder always produces a buffer, so the rule is
/// applied here.
fn encodeNullableCol(
    comptime O: type,
    gpa: Allocator,
    pending: *std.ArrayList(PendingColumn),
    scratch: *std.ArrayList(Cell),
    col: OpColumn,
    ops: []const O,
    mapper: *const ActorMapper,
    comptime cellOf: fn (O, *const ActorMapper) InternalError!?Cell,
) (ParseError || InternalError)!void {
    scratch.clearRetainingCapacity();
    var any_present = false;
    for (ops) |op| {
        const maybe = try cellOf(op, mapper);
        if (maybe) |cell| {
            any_present = true;
            try scratch.append(gpa, cell);
        } else {
            try scratch.append(gpa, .null_value);
        }
    }
    if (!any_present) return;
    try keepColumn(gpa, pending, try columnarenc.encodeColumn(
        gpa,
        col.id(),
        col.encoding(),
        scratch.items,
    ));
}

/// Writes `ops` as the fourteen operation columns of a change chunk
/// ([`write_change_ops`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):185-265).
///
/// `O` is anything with the accessors [`opmod.OpBuilder`] publishes, which is
/// both a decoded [`ChangeOp`] and a transaction's own [`TxOp`] — upstream's
/// one `AsChangeOp` trait
/// ([op.rs:1274-1321](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
/// covers both. `ops` must be consecutive counters from `change_actor`, which
/// is what "one change" means.
///
/// **Every `mapping[...]` is checked** rather than unwrapped: upstream's
/// `mapping[usize::from(a)].unwrap()`
/// ([change.rs:203](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs))
/// traps on an op naming an actor the mapper never saw, and here that is
/// `error.WrongActorTable`.
fn encodeChangeOps(
    comptime O: type,
    gpa: Allocator,
    ops: []const O,
    change_actor: ActorIdx,
    actors: []const ActorId,
    footer: []const u8,
) (ParseError || InternalError)!EncodedOps {
    if (ops.len == 0) {
        // `write_change_ops` returns the default column set for an empty
        // change (`change.rs:194-196`), and every range in it is `0..0`, so
        // the metadata block is a count of zero.
        //
        // **Three allocations, taken one at a time**, because they were three
        // `try`s inside one struct literal and a refusal from the second or
        // the third abandoned the first. The two zero-length allocations own
        // nothing a `free` can act on, but the column list is a real one and
        // the sequence is what keeps the rule true rather than incidentally
        // true for these sizes.
        const cols = try RawColumns.init(gpa, &.{}, &.{});
        errdefer cols.deinit(gpa);
        const data = try gpa.alloc(u8, 0);
        errdefer gpa.free(data);
        const others = try gpa.alloc(ActorId, 0);
        return .{ .cols = .{ .cols = cols, .data = data }, .others = others };
    }

    var pending: std.ArrayList(PendingColumn) = .empty;
    defer {
        freePending(gpa, &pending);
        pending.deinit(gpa);
    }
    var scratch: std.ArrayList(Cell) = .empty;
    defer scratch.deinit(gpa);

    var mapper = try ActorMapper.init(gpa, actors);
    defer mapper.deinit(gpa);
    try mapper.reset(gpa);
    for (ops) |op| try mapper.processOp(op);
    try mapper.buildMapping(gpa, change_actor);

    try encodeNullableCol(O, gpa, &pending, &scratch, .obj_actor, ops, &mapper, struct {
        fn f(op: O, m: *const ActorMapper) InternalError!?Cell {
            const actor = op.objActor() orelse return null;
            return .{ .uint = try m.remap(actor) };
        }
    }.f);

    try encodeNullableCol(O, gpa, &pending, &scratch, .obj_counter, ops, &mapper, struct {
        fn f(op: O, _: *const ActorMapper) InternalError!?Cell {
            const counter = op.objCtr() orelse return null;
            return .{ .uint = counter };
        }
    }.f);

    try encodeNullableCol(O, gpa, &pending, &scratch, .key_actor, ops, &mapper, struct {
        fn f(op: O, m: *const ActorMapper) InternalError!?Cell {
            const actor = op.keyActor() orelse return null;
            return .{ .uint = try m.remap(actor) };
        }
    }.f);

    try encodeNullableCol(O, gpa, &pending, &scratch, .key_counter, ops, &mapper, struct {
        fn f(op: O, _: *const ActorMapper) InternalError!?Cell {
            const counter = op.key().icounter() orelse return null;
            return .{ .int = counter };
        }
    }.f);

    try encodeNullableCol(O, gpa, &pending, &scratch, .key_string, ops, &mapper, struct {
        fn f(op: O, _: *const ActorMapper) InternalError!?Cell {
            const key = op.key().keyStr() orelse return null;
            return .{ .string = key };
        }
    }.f);

    try keepColumn(gpa, &pending, try encodeInsert(O, gpa, &scratch, ops));
    try keepColumn(gpa, &pending, try encodeAction(O, gpa, &scratch, ops));

    var values = try gpa.alloc(ScalarValue, ops.len);
    defer gpa.free(values);
    for (ops, 0..) |op, i| values[i] = op.value();
    const pair = try columnarenc.encodeValuePair(gpa, OpColumn.value_metadata.id(), values);
    try keepPair(gpa, &pending, pair);

    try encodePreds(O, gpa, &pending, &scratch, ops, &mapper);

    // `encode_to_unless(data, rows, false)`: the expand column is omitted
    // unless something expands (`change.rs:240`).
    scratch.clearRetainingCapacity();
    for (ops) |op| try scratch.append(gpa, .{ .boolean = op.expand() });
    try keepColumn(gpa, &pending, try columnarenc.encodeMaybeBoolean(
        gpa,
        OpColumn.expand.id(),
        scratch.items,
    ));

    try encodeNullableCol(O, gpa, &pending, &scratch, .mark_name, ops, &mapper, struct {
        fn f(op: O, _: *const ActorMapper) InternalError!?Cell {
            const name = op.markName() orelse return null;
            return .{ .string = name };
        }
    }.f);

    std.debug.assert(pending.items.len <= 14);
    // **The data block owns copies from here, so the staged bytes are spent
    // and `pending` is left empty for the `defer` above** — which is what makes
    // the release below the one release rather than the second of two. The
    // columns are this function's from the moment `finishColumns` answers, so
    // every step after it needs them given back; `others` is allocated from
    // the same allocator and its refusal is one of those steps.
    var owned = try finishColumns(gpa, pending.items);
    errdefer owned.deinit(gpa);
    freePending(gpa, &pending);
    const others = try gpa.alloc(ActorId, mapper.others.items.len);
    errdefer gpa.free(others);
    for (mapper.others.items, 0..) |index, i| others[i] = actors[index];
    _ = footer;
    return .{ .cols = owned, .others = others };
}

/// The `insert` column, always written.
fn encodeInsert(
    comptime O: type,
    gpa: Allocator,
    scratch: *std.ArrayList(Cell),
    ops: []const O,
) ParseError!columnarenc.Encoded {
    scratch.clearRetainingCapacity();
    for (ops) |op| try scratch.append(gpa, .{ .boolean = op.insert() });
    return columnarenc.encodeColumn(gpa, OpColumn.insert.id(), .boolean, scratch.items);
}

/// The `action` column, always written, holding action *codes*
/// ([`hex.Encoder::<Action>::encode_to`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):226).
fn encodeAction(
    comptime O: type,
    gpa: Allocator,
    scratch: *std.ArrayList(Cell),
    ops: []const O,
) ParseError!columnarenc.Encoded {
    scratch.clearRetainingCapacity();
    for (ops) |op| try scratch.append(gpa, .{ .uint = @backingInt(op.action()) });
    return columnarenc.encodeColumn(gpa, OpColumn.action.id(), .rle_uint, scratch.items);
}

/// The three predecessor columns: a count per op, then the actors and the
/// counters flattened across the group
/// ([`change.rs:233-239`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs)).
///
/// **The flattened pair is dropped when it is empty**
/// ([change_op_columns.rs:342-353](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)):
/// a change whose no operation has a predecessor has a group column of zeroes
/// and no actor or counter column at all. The delta encoding is why an op's
/// predecessors must be in ascending order
/// ([change_actors.rs:79-81](../../github-automerge-automerge/rust/automerge/src/storage/change/change_actors.rs)).
fn encodePreds(
    comptime O: type,
    gpa: Allocator,
    pending: *std.ArrayList(PendingColumn),
    scratch: *std.ArrayList(Cell),
    ops: []const O,
    mapper: *const ActorMapper,
) (ParseError || InternalError)!void {
    scratch.clearRetainingCapacity();
    var total: usize = 0;
    for (ops) |op| {
        const count: usize = op.pred().len;
        total += count;
        try scratch.append(gpa, .{ .uint = count });
    }
    try keepColumn(gpa, pending, try columnarenc.encodeColumn(
        gpa,
        OpColumn.pred_group.id(),
        .group,
        scratch.items,
    ));
    if (total == 0) return;

    var actors = try gpa.alloc(Cell, total);
    defer gpa.free(actors);
    var counters = try gpa.alloc(Cell, total);
    defer gpa.free(counters);

    var at: usize = 0;
    for (ops) |op| {
        for (op.pred()) |p| {
            actors[at] = .{ .uint = try mapper.remap(p.actor) };
            counters[at] = .{ .int = @intCast(p.counter) };
            at += 1;
        }
    }
    try keepColumn(gpa, pending, try columnarenc.encodeColumn(
        gpa,
        OpColumn.pred_actor.id(),
        .actor,
        actors,
    ));
    try keepColumn(gpa, pending, try columnarenc.encodeColumn(
        gpa,
        OpColumn.pred_counter.id(),
        .delta,
        counters,
    ));
}

// ── Decoding the change-op columns ──────────────────────────────────────────

/// The `[]Cell` of one column, or null when the change does not carry it.
///
/// **A missing column is missing, not an error**: which of the fourteen a
/// change carries depends on its ops
/// ([change_op_columns.rs:296-365](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)),
/// and a column the fourteen do not name is parked rather than refused
/// ([`:548-551`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)).
fn cellsOf(gpa: Allocator, cols: RawColumns, col: OpColumn) ParseError!?[]Cell {
    const bytes = (try cols.bytesFor(col.spec())) orelse return null;
    return try columnarenc.decodeAll(gpa, col.spec(), bytes);
}

/// Row `i` of a decoded column, or `fallback` when the column is absent.
///
/// A column **shorter** than the change has ops is `error.UnexpectedEnd`: the
/// row that cannot be read is the boundary, and reporting it there is what
/// makes the parser total. A column *longer* than the action column is not
/// consulted past the last op, which is upstream's `self.action.done()`
/// ([`change_op_columns.rs:396-397`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs)).
fn cellAt(list: ?[]const Cell, i: usize, fallback: Cell) ParseError!Cell {
    const cells = list orelse return fallback;
    if (i >= cells.len) return error.UnexpectedEnd;
    return cells[i];
}

/// Row `i` of a decoded value column, or `null_value` when it is absent.
fn valueAt(list: ?[]const ScalarValue, i: usize) ParseError!ScalarValue {
    const values = list orelse return .null_value;
    if (i >= values.len) return error.UnexpectedEnd;
    return values[i];
}

/// The unsigned row `i` of a decoded column, or null.
fn uintAt(list: ?[]const Cell, i: usize) ParseError!?u64 {
    return switch (try cellAt(list, i, .null_value)) {
        .uint => |u| u,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The signed row `i` of a decoded column, or null.
fn intAt(list: ?[]const Cell, i: usize) ParseError!?i64 {
    return switch (try cellAt(list, i, .null_value)) {
        .int => |v| v,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The boolean row `i` of a decoded column, or null.
fn boolAt(list: ?[]const Cell, i: usize) ParseError!?bool {
    return switch (try cellAt(list, i, .null_value)) {
        .boolean => |b| b,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The string row `i` of a decoded column, or null.
fn strAt(list: ?[]const Cell, i: usize) ParseError!?[]const u8 {
    return switch (try cellAt(list, i, .null_value)) {
        .string => |s| s,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The unsigned row `i` of a *group count* column, which may not be absent
/// ([column_range/generic/group.rs:76-79](../../github-automerge-automerge/rust/automerge/src/columnar/column_range/generic/group.rs)).
fn countAt(list: ?[]const Cell, i: usize) ParseError!u64 {
    return switch (try cellAt(list, i, .null_value)) {
        .uint => |u| u,
        else => error.UnexpectedNull,
    };
}

/// Decodes `change`'s operation columns into [`ChangeOp`]s in change order
/// ([`ChangeOpsIter::try_next`](../../github-automerge-automerge/rust/automerge/src/storage/change/change_op_columns.rs):399-431,
/// over [`Automerge::import_ops`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1118-1157).
///
/// `actors` is the change's own actor followed by its `other_actors`, in
/// change order — upstream's `change.actors()`
/// ([change.rs:56-60](../../github-automerge-automerge/rust/automerge/src/change.rs)).
/// Every actor index a column names is a position in it, so an index past its
/// end is `error.MissingActor`.
///
/// The caller owns the result: each op owns a copy of its predecessor list.
pub fn decodeChangeOps(
    gpa: Allocator,
    change: Change,
    actors: []const ActorIdx,
) ParseError![]ChangeOp {
    // The op block is parsed from the body the change already holds, so the
    // header is read twice. That is the price of not duplicating the metadata
    // block reader, and it is a read of already-validated bytes.
    var block = try changechunk.parseChangeChunkWithHash(change.bytes, gpa, change.hash);
    defer block.deinit(gpa);
    const cols = block.ops;

    const action = try cellsOf(gpa, cols, .action);
    defer freeCells(gpa, action);
    const num_ops = if (action) |cells| cells.len else 0;
    if (num_ops == 0) return gpa.alloc(ChangeOp, 0);

    const obj_actor = try cellsOf(gpa, cols, .obj_actor);
    defer freeCells(gpa, obj_actor);
    const obj_counter = try cellsOf(gpa, cols, .obj_counter);
    defer freeCells(gpa, obj_counter);
    const key_actor = try cellsOf(gpa, cols, .key_actor);
    defer freeCells(gpa, key_actor);
    const key_counter = try cellsOf(gpa, cols, .key_counter);
    defer freeCells(gpa, key_counter);
    const key_string = try cellsOf(gpa, cols, .key_string);
    defer freeCells(gpa, key_string);
    const insert = try cellsOf(gpa, cols, .insert);
    defer freeCells(gpa, insert);
    const value_meta = try cellsOf(gpa, cols, .value_metadata);
    defer freeCells(gpa, value_meta);
    const pred_group = try cellsOf(gpa, cols, .pred_group);
    defer freeCells(gpa, pred_group);
    const pred_actor = try cellsOf(gpa, cols, .pred_actor);
    defer freeCells(gpa, pred_actor);
    const pred_counter = try cellsOf(gpa, cols, .pred_counter);
    defer freeCells(gpa, pred_counter);
    const expand = try cellsOf(gpa, cols, .expand);
    defer freeCells(gpa, expand);
    const mark_name = try cellsOf(gpa, cols, .mark_name);
    defer freeCells(gpa, mark_name);

    const values: ?[]ScalarValue = if (value_meta) |_| blk: {
        const meta_bytes = (try cols.bytesFor(OpColumn.value_metadata.spec())).?;
        const raw_bytes = (try cols.bytesFor(OpColumn.value.spec())) orelse &.{};
        break :blk try columnarenc.decodeValuePair(gpa, meta_bytes, raw_bytes);
    } else null;
    defer if (values) |v| gpa.free(v);

    // `alloc` returns undefined memory, so **only the slots `filled` names may
    // be deinitialised** — walking the whole array frees the `succs` list of a
    // slot that was never built, which is a wild free rather than a leak.
    var ops = try gpa.alloc(ChangeOp, num_ops);
    errdefer gpa.free(ops);
    var filled: usize = 0;
    errdefer for (ops[0..filled]) |*op| op.deinit(gpa);

    var pred_cursor: usize = 0;
    for (0..num_ops) |i| {
        // `OpType::validate_action_and_value` is the check upstream calls
        // "necessary to ensure that `OpType::from_action_and_value` cannot
        // panic later in the process" (`:416-418`).
        const raw_action = switch (try cellAt(action, i, .null_value)) {
            .uint => |u| u,
            else => return error.InvalidAction,
        };
        const act = try Action.fromCode(std.math.cast(u8, raw_action) orelse
            return error.InvalidAction);
        const scalar = try valueAt(values, i);
        const mark = try strAt(mark_name, i);
        const expands = (try boolAt(expand, i)) orelse false;
        _ = value.opTypeFromActionAndValue(act, scalar, mark, expands) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return e,
        };

        const counter = std.math.add(u64, change.start_op, i) catch return error.Overflow;
        const own_counter = std.math.cast(u32, counter) orelse return error.Overflow;
        const id = OpId.init(own_counter, try actorAt(actors, 0));

        const obj: ObjId = if (try uintAt(obj_actor, i)) |local| blk: {
            const ctr = std.math.cast(u32, (try uintAt(obj_counter, i)) orelse
                return error.UnexpectedEnd) orelse return error.Overflow;
            break :blk .{ .id = OpId.init(ctr, try actorAt(actors, local)) };
        } else .root;

        const key = try decodeKey(actors, key_string, key_actor, key_counter, i);

        const count = std.math.cast(usize, try countAt(pred_group, i)) orelse
            return error.TooManyDeps;
        // **The list is released on every exit from the iteration**, because
        // every step between here and `ChangeOp.init` can refuse: the two
        // column reads and the actor lookup name three errors of their own, and
        // the copy `ChangeOp.init` makes is an allocation like any other. The
        // `gpa.free` on the success line is that same release taken back, not a
        // second one.
        const preds = try gpa.alloc(OpId, count);
        errdefer gpa.free(preds);
        for (preds, 0..) |*p, k| {
            const local = try uintAt(pred_actor, pred_cursor + k) orelse return error.UnexpectedEnd;
            // A predecessor counter is a `.delta` cell, so it arrives as a
            // plain `i64` and nothing earlier refuses it. Upstream refuses a
            // negative one by name — `invalid_value("counter", "negative
            // value for counter")` (`column_range/opid_list.rs:210-218`) —
            // and a counter above `u32::MAX` panics inside `OpId::new`,
            // which `unwrap()`s both conversions (`types.rs:463-464`). This
            // port does not panic: it refuses the oversize one the way it
            // already refuses an oversize `obj_counter` (`:1239-1240`) or
            // `key_counter`. The `@mod`/`@intCast` this replaced turned the
            // negative into a huge positive and then aborted the process
            // inside `load`, `applyChanges` and the sync receive path.
            const raw_ctr = try intAt(pred_counter, pred_cursor + k) orelse
                return error.UnexpectedEnd;
            if (raw_ctr < 0) return error.InvalidValue;
            const ctr = std.math.cast(u32, raw_ctr) orelse return error.Overflow;
            p.* = OpId.init(ctr, try actorAt(actors, local));
        }
        pred_cursor += count;

        ops[i] = try ChangeOp.init(
            gpa,
            id,
            obj,
            act,
            key,
            scalar,
            (try boolAt(insert, i)) orelse false,
            expands,
            mark,
            preds,
        );
        filled += 1;
        gpa.free(preds);
    }
    return ops;
}

/// The **document** actor index the change-local index `local` names.
///
/// **The mapping is the whole point, and returning the local index instead is
/// invisible with one actor.** `OpId::map` is `actor_map[self.actor]`
/// ([`types.rs:467-471`](../../github-automerge-automerge/rust/automerge/src/types.rs)),
/// and upstream's `import_ops` maps every id, object, key and predecessor
/// through it ([`batch.rs:1126-1135`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
/// A change's actor list is its own actor at index 0 and the rest after it, so
/// `actors[0]` is the author and `actors[1..]` are its references; when those
/// are not already in the author's order the table is a permutation and a
/// decoder that skips the lookup writes another actor's ops.
fn actorAt(actors: []const ActorIdx, local: u64) ParseError!ActorIdx {
    const idx = std.math.cast(u32, local) orelse return error.MissingActor;
    const i: usize = idx;
    if (i >= actors.len) return error.MissingActor;
    return actors[i];
}

/// Refuses a per-change counter range that does not match the rows it holds.
///
/// **A hole in the middle of a claimed range is a wrong `max_op`** and a range
/// with no claims at all is a wrong range or a change whose rows are somewhere
/// else. Upstream reports the first as `Error::MissingOps`
/// ([`VecEncoder::finish`, `collector.rs:308-312`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs))
/// and neither as an error, because the ops a change's range is derived from
/// are the same rows it is about to encode. Here the range comes from a stored
/// `max_op` and the rows come from the op set, and the two can disagree — which
/// is `test/fixtures/incorrect_max_op.automerge` and it must be an error rather
/// than a change with a hole in it.
///
/// A **leading** gap is legal and is not checked: upstream's `start_pos`
/// ([`:308`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs))
/// is exactly that, and it is how a change whose first op is above its
/// inferred `start_op` is written.
fn checkCoverage(builders: []const Builder) Error!void {
    for (builders) |builder| {
        if (builder.ops.items.len == 0) continue; // an empty change has no rows
        var first: usize = 0;
        while (first < builder.ops.items.len and builder.ops.items[first] == null) : (first += 1) {}
        if (first == builder.ops.items.len) {
            std.debug.print(
                "doc: change seq {d} of actor {d} claims ops {d}..{d} and holds none\n",
                .{ builder.seq, builder.actor, builder.start_op, builder.max_op },
            );
            return error.Fail;
        }
        for (builder.ops.items[first..], 0..) |maybe, i| {
            if (maybe == null) {
                std.debug.print(
                    "doc: change seq {d} of actor {d} is missing op {d} of {d}..{d}\n",
                    .{
                        builder.seq,      builder.actor,  builder.start_op + first + i,
                        builder.start_op, builder.max_op,
                    },
                );
                return error.Fail;
            }
        }
    }
}

/// One row's property: a map key, or the sequence anchor it hangs by
/// ([`KeyIter::next_in_col`](../../github-automerge-automerge/rust/automerge/src/columnar/column_range/key.rs)).
///
/// **A present key string decides**, because a map key is
/// `(null actor, null counter, string)` and a sequence anchor is
/// `(actor, counter, null string)` — three shapes over two columns, and the
/// head is the `(null actor, zero counter)` third one
/// ([types.zig:284-295](types.zig)).
fn decodeKey(
    actors: []const ActorIdx,
    key_string: ?[]const Cell,
    key_actor: ?[]const Cell,
    key_counter: ?[]const Cell,
    i: usize,
) ParseError!KeyRef {
    if (try strAt(key_string, i)) |name| return .{ .map = name };
    const local = (try uintAt(key_actor, i)) orelse return .{ .seq = ElemId.head() };
    const ctr = std.math.cast(u32, (try intAt(key_counter, i)) orelse
        return error.UnexpectedEnd) orelse return error.Overflow;
    return .{ .seq = ElemId.fromOpId(OpId.init(ctr, try actorAt(actors, local))) };
}

/// Frees a decoded column, or nothing when the change did not carry it.
fn freeCells(gpa: Allocator, cells: ?[]Cell) void {
    if (cells) |c| gpa.free(c);
}

/// Frees the decoded ops and the array.
pub fn freeChangeOps(gpa: Allocator, ops: []ChangeOp) void {
    for (ops) |*op| op.deinit(gpa);
    gpa.free(ops);
}

// ── The change-graph columns of a document chunk ────────────────────────────

/// The column ids and encodings of a document chunk's change block
/// ([`change_graph::ids`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):1777-1798).
///
/// **They are FORMAT.** Every column here is inside the body the document
/// chunk's checksum covers, and the graph a load rebuilds from them is the
/// document's history.
pub const GraphColumn = struct {
    /// The change's author, as an index into the actor table.
    pub const actor_id: u32 = 0;
    /// The author's sequence number.
    pub const seq_id: u32 = 0;
    /// The counter of the change's last op.
    pub const max_op_id: u32 = 1;
    /// The commit time, as a signed delta.
    pub const time_id: u32 = 2;
    /// The commit message.
    pub const message_id: u32 = 3;
    /// The change's dependencies: a count column and the node indices they
    /// name, delta coded.
    pub const deps_id: u32 = 4;
    /// The bytes after a change's op data — the author footer.
    pub const extra_id: u32 = 5;

    /// The change's author, run-length encoded.
    pub fn actorSpec() ColumnSpec {
        return .make(actor_id, .actor, false);
    }
    /// The author's sequence number, delta coded.
    pub fn seqSpec() ColumnSpec {
        return .make(seq_id, .delta, false);
    }
    /// The change's last op counter, delta coded.
    pub fn maxOpSpec() ColumnSpec {
        return .make(max_op_id, .delta, false);
    }
    /// The commit time, delta coded and **signed**: a timestamp before 1970 is
    /// a negative delta, and writing it unsigned changes the document's bytes.
    pub fn timeSpec() ColumnSpec {
        return .make(time_id, .delta, false);
    }
    /// The commit message, run-length encoded, absent when empty.
    pub fn messageSpec() ColumnSpec {
        return .make(message_id, .string, false);
    }
    /// How many dependencies each change has.
    pub fn depsCountSpec() ColumnSpec {
        return .make(deps_id, .group, false);
    }
    /// The node indices the dependencies name, delta coded.
    pub fn depsValueSpec() ColumnSpec {
        return .make(deps_id, .delta, false);
    }
    /// The author footer's metadata words.
    pub fn extraMetaSpec() ColumnSpec {
        return .make(extra_id, .value_metadata, false);
    }
    /// The author footer's bytes.
    pub fn extraValueSpec() ColumnSpec {
        return .make(extra_id, .value, false);
    }

    /// Every one of the nine, in the order the writer emits them — ascending
    /// by normalized specification, which `RawColumns::parse` requires.
    pub const all = [_]ColumnSpec{
        actorSpec(),     seqSpec(),       maxOpSpec(),     timeSpec(),       messageSpec(),
        depsCountSpec(), depsValueSpec(), extraMetaSpec(), extraValueSpec(),
    };
};

/// One change, as a document chunk's change block describes it.
pub const GraphNode = struct {
    /// The author, as an index into the document's actor table.
    actor: ActorIdx,
    /// The author's sequence number: 1 for an actor's first change.
    seq: u64,
    /// The counter of the change's last op. **Not its first**: `start_op` is
    /// `max_op - num_ops + 1`, and `num_ops` is what the collector establishes
    /// ([`ChangeIter::next`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):1669).
    max_op: u64,
    /// The commit time in seconds since the epoch.
    time: i64,
    /// The commit message, empty when there was none.
    message: []const u8,
    /// The change's dependencies, as indices into the change block.
    deps: []const NodeIdx,
    /// The bytes after the change's op data, borrowed from the chunk body.
    extra: []const u8,
};

/// Decodes a document chunk's change block
/// ([`ChangeGraphCols::load`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):926-1050).
///
/// `num_actors` bounds the actor column: an author index past the table is
/// `error.MissingActor`, which is upstream's `LoadError::InvalidActorId`
/// ([`:949-953`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
///
/// The caller owns the result; `freeGraphNodes` releases it. Every slice in it
/// borrows `cols`' data block, so that block must outlive the nodes.
fn decodeGraphCols(
    gpa: Allocator,
    cols: RawColumns,
    num_actors: usize,
) ParseError![]GraphNode {
    const actor_cells = (try cols.bytesFor(GraphColumn.actorSpec())) orelse
        return gpa.alloc(GraphNode, 0);
    const actor = try columnarenc.decodeAll(gpa, GraphColumn.actorSpec(), actor_cells);
    defer gpa.free(actor);
    const len = actor.len;
    if (len == 0) return gpa.alloc(GraphNode, 0);

    const seq = try decodeColumn(gpa, cols, GraphColumn.seqSpec(), len, "seq", .null_value);
    defer gpa.free(seq);
    const max_op = try decodeColumn(gpa, cols, GraphColumn.maxOpSpec(), len, "max_op", .null_value);
    defer gpa.free(max_op);
    // **A column the chunk does not carry is a column of fills, not an empty
    // one.** Upstream reads both of these through `LoadOpts`
    // ([`change_graph.rs:944-945`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)):
    // `DeltaColumn::<i64>::load_with(time_bytes, opts.with_fill(0i64))` and
    // `Column::<Option<String>>::load_with(message_bytes, opts.with_fill(None))`.
    // `with_fill` applies **only when the data is empty**
    // ([`load_opts.rs:59-70`](../../github-automerge-automerge/rust/hexane/src/load_opts.rs)),
    // so a writer may omit a column every row would have held the fill for —
    // and `ChangeGraphCols::encode` does exactly that for the message column,
    // `save_to_unless(out, None)`
    // ([`column.rs:1447-1453`](../../github-automerge-automerge/rust/hexane/src/column.rs)).
    // Reading an omitted message column as *zero rows* is what made the
    // reference's own `test/fixtures/interop-exemplar` a load error here: its
    // changes carry no message, so it carries no message column, and
    // `graphStr` ran off the end of what the reader handed back.
    const time = try decodeColumn(gpa, cols, GraphColumn.timeSpec(), len, "time", .{ .int = 0 });
    defer gpa.free(time);
    const message = try decodeColumn(
        gpa,
        cols,
        GraphColumn.messageSpec(),
        len,
        "message",
        .null_value,
    );
    defer gpa.free(message);
    const deps_count = try decodeColumn(
        gpa,
        cols,
        GraphColumn.depsCountSpec(),
        len,
        "deps_count",
        .null_value,
    );
    // `deps_count` is read by upstream's plain `decoder::<u32>` with no fill
    // ([`change_graph.rs:983`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    // so an absent one is still a refusal.
    defer gpa.free(deps_count);
    // The dependency column is **flattened across the group**: one row per
    // dependency of every change, not one per change
    // ([`change_graph.rs:997-1003`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
    // Its length is the sum of the counts, and the walk below is what checks it.
    const deps_value = try decodeColumn(
        gpa,
        cols,
        GraphColumn.depsValueSpec(),
        null,
        "deps_value",
        .null_value,
    );
    defer gpa.free(deps_value);

    const extra_meta = try decodeColumn(
        gpa,
        cols,
        GraphColumn.extraMetaSpec(),
        len,
        "extra_meta",
        .null_value,
    );
    defer gpa.free(extra_meta);
    const extra_value = (try cols.bytesFor(GraphColumn.extraValueSpec())) orelse &.{};

    for (actor) |cell| switch (cell) {
        .uint => |a| if (a >= num_actors) return error.MissingActor,
        else => return error.InvalidValue,
    };

    var nodes = try gpa.alloc(GraphNode, len);
    errdefer gpa.free(nodes);
    // **The rows read so far, and only those.** Each row's `deps` is its own
    // allocation, and the `errdefer gpa.free(deps)` below owns the current
    // row's until `nodes[i]` is written — a `try` inside that struct literal
    // leaves the slot unwritten, so the two guards are never both live. A
    // refusal from row `i` therefore abandons rows `0..i-1`, and this is what
    // gives them back. `filled` must not advance until the assignment has
    // happened: a slot counted here but not yet written is undefined memory,
    // and freeing `node.deps` out of it is a wild free.
    //
    // **`freeGraphNodes` is not reusable here**, and the reason is its last
    // line: it ends in `gpa.free(nodes)`, so it would free this prefix with the
    // whole array's length — a wrong-extent free on every refusal. The prefix
    // needs the per-row walk and the array needs its own free, and only the
    // array's owner knows which is which.
    var filled: usize = 0;
    errdefer for (nodes[0..filled]) |node| gpa.free(node.deps);

    var deps_at: usize = 0;
    var extra_at: usize = 0;
    for (0..len) |i| {
        const author_idx = try graphActor(actor[i]);

        const count = std.math.cast(usize, try graphUint(deps_count, i, "deps_count")) orelse
            return error.TooManyDeps;
        // **A subtraction, not a sum, and it is totality rather than taste.**
        // `deps_count` is a raw `u64` off the wire and `cast` is lossless on a
        // 64-bit target, so a cell of `usize.MAX` reaches this line; row zero
        // cannot wrap (`deps_at == 0`) but every row after it can, and a wrapped
        // sum passes the check and reaches `gpa.alloc` asking for 2^66 bytes.
        // The subtraction cannot underflow either: `deps_at` starts at zero and
        // only advances by a count this same check already proved fits.
        if (count > deps_value.len - deps_at) return error.UnexpectedEnd;
        const deps = try gpa.alloc(NodeIdx, count);
        errdefer gpa.free(deps);
        for (deps, 0..) |*d, k| {
            d.* = try graphNode(deps_value[deps_at + k]);
        }
        deps_at += count;

        const meta_word = try graphUint(extra_meta, i, "extra_meta");
        const meta_len = std.math.cast(usize, meta_word >> 4) orelse return error.Overflow;
        // **The same bound, for the same reason.** `meta_word >> 4` is up to
        // 2^60, and `cast` is the only guard on it — it refuses on a 32-bit
        // target rather than refusing the value, so on 64-bit the sum below is
        // the one that can wrap. This also bounds the slice on the next line:
        // once `meta_len <= extra_value.len - extra_at`, `extra_at + meta_len`
        // is provably in range and cannot overflow.
        if (meta_len > extra_value.len - extra_at) return error.UnexpectedEnd;
        const extra = extra_value[extra_at .. extra_at + meta_len];
        extra_at += meta_len;

        nodes[i] = .{
            .actor = author_idx,
            .seq = try graphUint(seq, i, "seq"),
            .max_op = try graphUint(max_op, i, "max_op"),
            .time = try graphSigned(time, i, "time"),
            .message = (try graphStr(message, i)) orelse &.{},
            .deps = deps,
            .extra = extra,
        };
        filled += 1;
    }
    return nodes;
}

/// Frees the nodes and the dependency arrays they own.
fn freeGraphNodes(gpa: Allocator, nodes: []GraphNode) void {
    for (nodes) |node| gpa.free(node.deps);
    gpa.free(nodes);
}

/// Decodes one whole column and checks its length, which is upstream's four
/// `InvalidColumnLength` checks ([`change_graph.rs:964-972`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
///
/// **An absent column is `len` copies of `fill`, and a present one that
/// decodes to another length is a refusal.** That is upstream's rule exactly: a
/// fill replaces *empty* data
/// ([`load_opts.rs:59-70`](../../github-automerge-automerge/rust/hexane/src/load_opts.rs))
/// and a present column of the wrong length is `PackError::InvalidLength`
/// ([`load_opts.rs:88-92`](../../github-automerge-automerge/rust/hexane/src/load_opts.rs)).
/// A column upstream reads with no fill — `seq`, `max_op`, `deps_count` and
/// `extra_meta` are all read without one — is given `.null_value` here, which
/// no reader accepts, so an absent one is still a refusal at the walk.
fn decodeColumn(
    gpa: Allocator,
    cols: RawColumns,
    spec: ColumnSpec,
    len: ?usize,
    name: []const u8,
    fill: Cell,
) ParseError![]Cell {
    const bytes = (try cols.bytesFor(spec)) orelse return filledColumn(gpa, len, fill);
    const cells = try columnarenc.decodeAll(gpa, spec, bytes);
    const want = len orelse return cells;
    if (cells.len != want) {
        gpa.free(cells);
        std.debug.print("doc: change column {s} has {d} rows, expected {d}\n", .{
            name, cells.len, want,
        });
        return error.UnexpectedEnd;
    }
    return cells;
}

/// `len` copies of `fill`, which is what a chunk that omitted a column reads
/// as. Zero rows when the caller has no length to fill to.
fn filledColumn(gpa: Allocator, len: ?usize, fill: Cell) ParseError![]Cell {
    const want = len orelse return gpa.alloc(Cell, 0);
    const out = try gpa.alloc(Cell, want);
    @memset(out, fill);
    return out;
}

fn graphActor(cell: Cell) ParseError!ActorIdx {
    return switch (cell) {
        .uint => |a| std.math.cast(ActorIdx, a) orelse return error.Overflow,
        else => error.InvalidValue,
    };
}

/// A dependency's node index, which is a delta-coded row like every other
/// unsigned change column.
fn graphNode(cell: Cell) ParseError!NodeIdx {
    return switch (cell) {
        .uint => |n| std.math.cast(NodeIdx, n) orelse error.Overflow,
        .int => |v| std.math.cast(NodeIdx, v) orelse error.InvalidValue,
        else => error.InvalidValue,
    };
}

/// One row of a change column, as an unsigned integer.
///
/// **A delta column arrives signed.** `seq`, `max_op` and the dependency
/// indices are all `DeltaInteger` columns
/// ([`change_graph.rs:1789-1796`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
/// and upstream reads them with `DeltaDecoder::<u32>`, so the port's decoder
/// hands back signed cells and a negative one is a corrupt column rather than
/// a large unsigned value.
fn graphUint(cells: []const Cell, i: usize, name: []const u8) ParseError!u64 {
    return switch (cells[i]) {
        .uint => |u| u,
        .int => |v| std.math.cast(u64, v) orelse blk: {
            std.debug.print("doc: change column {s} row {d} is negative\n", .{ name, i });
            break :blk error.InvalidValue;
        },
        else => blk: {
            std.debug.print("doc: change column {s} row {d} is not an integer\n", .{ name, i });
            break :blk error.InvalidValue;
        },
    };
}

fn graphSigned(cells: []const Cell, i: usize, name: []const u8) ParseError!i64 {
    return switch (cells[i]) {
        .int => |v| v,
        .uint => |u| std.math.cast(i64, u) orelse return error.Overflow,
        else => blk: {
            std.debug.print("doc: change column {s} row {d} is not an integer\n", .{ name, i });
            break :blk error.InvalidValue;
        },
    };
}

/// Row `i` of a string column, or null when it is absent.
///
/// **Bounded like the other two readers here.** A document chunk's change block
/// is attacker-controlled, and a decoded column whose length disagrees with the
/// actor column's is a refusal rather than an index past the end.
fn graphStr(cells: []const Cell, i: usize) ParseError!?[]const u8 {
    if (i >= cells.len) return error.UnexpectedEnd;
    return switch (cells[i]) {
        .string => |s| s,
        .null_value => null,
        else => error.InvalidValue,
    };
}

/// The author a change's footer carries
/// ([`decode_author_footer`](../../github-automerge-automerge/rust/automerge/src/change.rs):395-403).
///
/// A footer whose first word is not [`Footer::Author`] is not an author, which
/// is upstream's `None`: the only footer tag defined is 1
/// ([`change.rs:365-368`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
/// and a change written by a newer implementation may carry something else.
pub const footer_author_id: u64 = 1;

/// Decodes a footer into the author it names, or null when it names none.
pub fn decodeAuthorFooter(footer: ?[]const u8) ParseError!?[]const u8 {
    const bytes = footer orelse return null;
    if (bytes.len == 0) return null;
    var in: Input = .init(bytes);
    const id = try in.takeUleb();
    if (id != footer_author_id) return null;
    const len = std.math.cast(usize, try in.takeUleb()) orelse return error.TooLarge;
    if (in.remaining() < len) return null;
    return in.rest()[0..len];
}

/// The footer an author is written as
/// ([`encode_author_footer`](../../github-automerge-automerge/rust/automerge/src/change.rs):376-386).
/// An absent author is no footer at all.
pub fn encodeAuthorFooter(gpa: Allocator, out: *std.ArrayList(u8), author: ?[]const u8) Allocator.Error!void {
    const bytes = author orelse return;
    try leb128.appendUnsigned(out, gpa, footer_author_id);
    try leb128.appendUnsigned(out, gpa, bytes.len);
    try out.appendSlice(gpa, bytes);
}

// ── The collector ───────────────────────────────────────────────────────────

/// One change's metadata as the collector needs it: everything that decides
/// which rows belong to the change and everything its header carries except the
/// dependencies, which are node indices until the change is finished.
pub const BuildMeta = struct {
    /// The author, as an index into the document's actor table.
    actor: ActorIdx,
    /// The author's sequence number: 1 for an actor's first change.
    seq: u64,
    /// The counter of the change's first op, never zero.
    start_op: u64,
    /// The counter of the change's last op, which is `start_op - 1` for a
    /// change with no ops.
    max_op: u64,
    /// The commit time in seconds since the epoch.
    time: i64,
    /// The commit message, empty when there was none.
    message: []const u8,
    /// The change's dependencies, as indices into the node list the caller is
    /// resolving them against.
    deps: []const NodeIdx,
    /// The bytes after the change's op data: the author footer, or nothing.
    footer: []const u8,
};

/// Where a dependency's hash comes from.
pub const DepResolver = struct {
    /// A graph that already holds every dependency, or null.
    graph: ?*const ChangeGraph = null,
    /// The changes finished so far, indexed by node index, or null.
    built: ?*const Changes = null,
    /// A bundle's dependency index space, or null
    /// ([`BundleDeps`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):961-985).
    ///
    /// **A bundle names dependencies in two spaces at once**, and this is the
    /// join: an index below `num_changes` is a change already finished in
    /// `built`, and an index at or above it is the `[k]`th hash in the chunk
    /// prefix — which is where a change the bundle depends on but does not
    /// carry lives.
    bundle: ?struct {
        num_changes: usize,
        deps: []const ChangeHash,
    } = null,

    /// The hash node `idx` names, or `error.MissingDeps` when this resolver
    /// has no such node. Upstream's `GetHash::get_hash` returns an `Option` and
    /// the caller unwraps it ([`change.rs:77`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs));
    /// a change whose dependency is absent is a graph this document cannot
    /// reconstruct, and answering with the wrong header would change the hash.
    fn get(self: DepResolver, idx: NodeIdx) Error!ChangeHash {
        if (self.bundle) |b| {
            if (idx >= b.num_changes) {
                const at: usize = idx - b.num_changes;
                if (at >= b.deps.len) return error.MissingDeps;
                return b.deps[at];
            }
            const list = self.built orelse return error.MissingDeps;
            if (idx >= list.items.items.len) return error.MissingDeps;
            return list.items.items[idx].change.hash;
        }
        if (self.built) |list| {
            if (idx >= list.items.items.len) return error.MissingDeps;
            return list.items.items[idx].change.hash;
        }
        const graph = self.graph orelse return error.MissingDeps;
        return graph.indexToHash(idx) orelse error.MissingDeps;
    }
};

/// One change's slots: the op each counter holds, or null for a counter no row
/// claimed.
const Builder = struct {
    /// The author, as an index into the document's actor table.
    actor: ActorIdx,
    /// The author's sequence number, which orders the builders.
    seq: u64,
    /// Which [`BuildMeta`] this builder is.
    meta: usize,
    /// The counter of the change's first op.
    start_op: u64,
    /// The counter of the change's last op.
    max_op: u64,
    /// One slot per counter from `start_op` to `max_op`, in that order.
    ops: std.ArrayList(?ChangeOp) = .empty,

    fn deinit(self: *Builder, gpa: Allocator) void {
        for (self.ops.items) |*maybe| {
            if (maybe.*) |*op| op.deinit(gpa);
        }
        self.ops.deinit(gpa);
    }

    /// How many counters the change spans.
    fn slots(self: Builder) usize {
        if (self.max_op < self.start_op) return 0;
        return @intCast(self.max_op - self.start_op + 1);
    }

    /// Sizes the slot array to the change's counter range, empty.
    ///
    /// **A range that is not a range is refused here**, before any op is
    /// walked: `start_op` of zero is a value the change format does not permit
    /// ([`parse/leb128.rs:87-96`](../../github-automerge-automerge/rust/automerge/src/parse/leb128.rs)),
    /// and a `max_op` below `start_op` is the empty change, which has no slots
    /// and is legal.
    fn reserve(self: *Builder, gpa: Allocator) (Error || ParseError)!void {
        if (self.start_op == 0) return error.Fail;
        const n = self.slots();
        if (n == 0) return;
        if (n > max_slots_per_change) return error.TooManyOps;
        try self.ops.appendNTimes(gpa, null, n);
    }
};

/// Builders ordered by `(actor, seq)`, which is the order an op counter falls
/// into ([`try_from_change_meta`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):613-647)).
fn builderLessThan(_: void, a: Builder, b: Builder) bool {
    if (a.actor != b.actor) return a.actor < b.actor;
    return a.seq < b.seq;
}

/// Predecessors discovered through successor edges, and the register they
/// belong to.
///
/// **An op set stores no predecessors.** They are the successor edges on the
/// ops that op replaced, so the collector reverses them as it walks
/// ([`process_succ`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):791-793)).
/// An edge whose target is not in the block being built is a **delete**, and it
/// is placed at the end of the register the walk was last in
/// ([`flush_deletes`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):839-850) —
/// which is why the walk flushes when the `(obj, elemid-or-key)` pair changes.
///
/// The predecessors of every op the walk has seen an edge into but has not
/// placed yet: a row's successors are recorded as the row goes by, and a row
/// that arrives later claims them.
///
/// **The map holds the lists. There is no second array and no position to keep
/// in step with one.** This was an `ArrayList` of entries beside an
/// `index: OpId → position` table, and `take` removed an entry with
/// `orderedRemove`, which renumbers every entry behind the one it removed while
/// `index` keeps handing out the old positions. The next `take` for any id past
/// the removal read `items` one past its end — `index out of bounds: index 1,
/// len 1`, reached from `Document.getChangeByHash` on a document that had
/// applied a peer's changes, which is what
/// `sync.generateSyncMessage` does on every message. A map of lists has no
/// invariant to fall out of step: `record` and `take` are the only two
/// operations, neither moves anything, and `flushDeletes` resets both halves in
/// one step because there is only one thing to reset.
const Preds = struct {
    by_op: std.AutoHashMapUnmanaged(OpId, std.ArrayList(OpId)) = .empty,

    fn deinit(self: *Preds, gpa: Allocator) void {
        var it = self.by_op.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        self.by_op.deinit(gpa);
        self.* = undefined;
    }

    /// Notes that `op` is a predecessor of `succ`.
    fn record(self: *Preds, gpa: Allocator, succ: OpId, op: OpId) Allocator.Error!void {
        const gop = try self.by_op.getOrPut(gpa, succ);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(gpa, op);
    }

    /// Takes the predecessors recorded for `id` and removes them.
    ///
    /// **An id that was never recorded has no predecessors, and that is an
    /// answer rather than a gap.** `take` is called for every row the walk
    /// reaches, and a row no earlier row points at as a successor is an op
    /// nothing overwrites — which is what an insert is. So the empty list was
    /// the answer before the list moved into the map and it is the answer now;
    /// what changed is that a *recorded* id can no longer name a position that
    /// is not there.
    fn take(self: *Preds, gpa: Allocator, id: OpId) Allocator.Error![]OpId {
        var kv = self.by_op.fetchRemove(id) orelse return gpa.alloc(OpId, 0);
        // `toOwnedSlice` shrinks the list's buffer to its length and that
        // realloc is fallible. The entry is already out of the map by the
        // time it runs, so if the shrink is refused the local `kv` is the only
        // thing that still names the buffer and `Preds.deinit` can never find
        // it again — a leak of the whole predecessor list, on exactly the
        // allocation-refusal path this collector is swept for. Releasing it
        // here is the same release the success path hands to the caller.
        return kv.value.toOwnedSlice(gpa) catch |e| {
            kv.value.deinit(gpa);
            return e;
        };
    }
};

/// Rebuilds the change chunks of `metas` from the rows of `set`
/// ([`ChangeCollector`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):90-96).
///
/// Every meta is a change the document is known to hold, in an order where a
/// dependency precedes the change that needs it — which is what
/// [`DepResolver.built`] needs and what the graph itself guarantees by only
/// accepting a change whose dependencies are present
/// ([`change_graph.rs:718-727`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
///
/// **The row order is the whole argument.** A walk emits rows in
/// `(obj, elemid-or-key, id)` order, so a delete op — which has no row of its
/// own — can only belong to the register the walk was in when the edge was
/// found. The collector therefore flushes the previous register's pending
/// deletes before it places anything from the next one.
fn collectChanges(
    gpa: Allocator,
    set: *Set,
    actors: []const ActorId,
    metas: []const BuildMeta,
    resolve: DepResolver,
    out: *Changes,
) DocumentError!void {
    out.* = .{};

    const builder_of = try gpa.alloc(usize, metas.len);
    defer gpa.free(builder_of);

    var builders = try gpa.alloc(Builder, metas.len);
    defer {
        for (builders) |*b| b.deinit(gpa);
        gpa.free(builders);
    }
    for (metas, 0..) |meta, i| {
        builders[i] = .{
            .actor = meta.actor,
            .seq = meta.seq,
            .meta = i,
            .start_op = meta.start_op,
            .max_op = meta.max_op,
        };
    }
    std.mem.sort(Builder, builders, {}, builderLessThan);
    // **The builder a change finishes from is recorded, not searched for.**
    // Upstream writes it back into the metadata right after the sort
    // (`changes[b.change].builder = index`, `collector.rs:635-637`) and reads
    // it there at the end (`self.builders[change.builder].finish(…)`,
    // `collector.rs:875`). Searching is what `ChangeCollector::add` does for an
    // *op* ([`builders_index`, `collector.rs:808-822`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs))
    // and the two searches are not the same search: a builder with no ops has
    // `max_op < start_op`, so the comparison that looks for an enclosing range
    // skips it — `c < start_op` gives `Greater` and `c > max_op` gives `Less`,
    // and a counter between the two does not exist. **A search therefore cannot
    // find an empty change, and the empty change is the merge commit**
    // ([`Automerge::empty_commit`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // `Builder.meta` already carries the metadata index each builder came
    // from, so the record is that field written the other way round.
    for (builders, 0..) |*builder, i| {
        builder_of[builder.meta] = i;
    }

    // **Every builder gets its slots before the walk starts.** Without this the
    // bounds test in `place` rejects every op — the change's counter is never
    // inside an empty range — and every op in the document is dropped, which is
    // silent: the change then encodes with no ops at all and comes out with the
    // wrong hash, three steps downstream of where it went wrong.
    for (builders) |*builder| {
        try builder.reserve(gpa);
    }

    var preds: Preds = .{};
    defer preds.deinit(gpa);
    var last: ?Register = null;

    var walk = try set.iter();
    while (try walk.next()) |op| {
        const op_id = op.id();
        const register: Register = .{ .obj = op.objId(), .key = op.elemidOrKey() };
        const flush = !sameRegister(last, register);
        if (flush) try flushDeletes(gpa, builders, &preds, last);
        last = register;

        const owned = try preds.take(gpa, op_id);
        defer gpa.free(owned);
        const bld = try opmod.OpBuilder.init(
            gpa,
            op_id,
            op.objId(),
            op.action(),
            op.key(),
            op.value(),
            op.insert(),
            op.expand(),
            op.markName(),
            owned,
        );
        try place(gpa, builders, bld);

        var succ = op.succ();
        while (succ.next()) |s| try preds.record(gpa, s, op_id);
    }
    try flushDeletes(gpa, builders, &preds, last);
    try checkCoverage(builders);

    // Upstream iterates the **metadata** order and reads the builder the
    // metadata names, not the other way round (`finish_inner`,
    // `collector.rs:869-879`): the caller asked for changes in that order and a
    // hash list the caller gave must come back in it.
    for (metas, 0..) |meta, i| {
        const builder_index = builder_of[i];
        // The `Built` is released if the append cannot take it, for the same
        // reason `place` releases a dropped builder: `try` on a nested
        // fallible expression has no `errdefer` of its own.
        var built = try finishOne(gpa, actors, &builders[builder_index], meta, resolve);
        errdefer built.deinit(gpa);
        try out.items.append(gpa, built);
    }
}

/// Rebuilds the change chunks a bundle holds
/// ([`Bundle::to_changes`](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs):99-103,
/// over [`BundleStorage::to_changes`](../../github-automerge-automerge/rust/automerge/src/storage/bundle/storage.rs):309-319).
///
/// **The same collector, over a different op vocabulary.** Upstream's
/// `ChangeCollector` is one type with one `add`, and `to_changes` feeds it
/// [`OpIter`](storage/bundle.zig)'s rows where [`collectChanges`] feeds the op
/// set's. That is upstream's own split
/// ([`from_bundle_changes`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):605-611
/// is [`from_change_meta`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):613-654
/// with a conversion), so this is [`collectChanges`] over the bundle's rows and
/// **not a second encoder**.
///
/// **Two things the op-set path does not do, and both are upstream's shape.**
/// There is no predecessor reconstruction — [`Preds`] and
/// [`flushDeletes`] are the op set's answer to "an op set stores no
/// predecessors" and a bundle's columns carry them — and there is no
/// `flush_deletes` before finishing, which is [`ChangeCollector::unbundle`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):884-906
/// against [`ChangeCollector::collect`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):908-909.
/// A delete in a bundle is a row.
///
/// **The dependency resolver is the bundle's own index space**, which is
/// [`BundleDeps`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):961-985:
/// an index below the change count is a change already finished, and one above
/// it is the `[k]`th hash in the chunk prefix.
fn collectBundleChanges(
    gpa: Allocator,
    b: *const Bundle,
    out: *Changes,
) DocumentError!void {
    out.* = .{};

    var change_iter = try bundlem.ChangeIter.init(b.changes_cols, gpa);
    defer change_iter.deinit();
    var ops_iter = try bundlem.OpIter.init(b.ops_cols, b.id_ctr, gpa);
    defer ops_iter.deinit();

    // **The actor table is the bundle's own.** A bundle's actor column is a
    // position in [`Bundle.actorList`] — the writer remapped through
    // [`ActorMapper`](storage/bundle.zig) — so every `actor`, `obj`, `key` and
    // `id` index in the columns means what it means in *that* list, and the
    // encoder writes the change against the same list.
    const actors = b.actorList();

    // **One pass over the change block into a list that grows**, which is
    // upstream's `self.iter_change_meta().collect()`
    // ([`storage.rs`:310](../../github-automerge-automerge/rust/automerge/src/storage/bundle/storage.rs)):
    // the actor column is what ends the walk ([`ChangeIter.next`](storage/bundle.zig)),
    // so the length is not knowable before it.
    var metas: std.ArrayList(BuildMeta) = .empty;
    // **ONE cleanup, armed before the loop.** This arm was an `errdefer` and
    // the identical block after the loop a `defer`, so every error return from
    // the second one on — `gpa.alloc(usize, count)`, `ops_iter.next()`,
    // `place` (`error.Fail`), `checkCoverage` (`error.Fail`), `finishOne`
    // (`error.MissingDeps`/`error.OutOfMemory`) and `out.items.append` — ran
    // both and freed every `meta.deps` window and the list twice. Zig runs a
    // `defer` on every scope exit and an `errdefer` *in addition* on an error
    // exit, so hoisting is not merely tidier: it is the only shape here that
    // frees once. Untrusted input reaches this on every bundle chunk
    // ([`Document.applyChunk`], [`Document.loadIntoWith`]) and over the
    // mutated-fixture sweep in `storage/totality_test.zig`, and ordinary OOM
    // while loading a large bundle reaches it too.
    //
    // **Hoisting is safe because the in-loop `catch` arms below free the
    // not-yet-appended `deps` themselves.** A window that is already in the
    // list belongs to `metas` and this block frees it exactly once.
    defer {
        for (metas.items) |meta| gpa.free(meta.deps);
        metas.deinit(gpa);
    }
    while (try change_iter.next()) |row| {
        const deps = gpa.alloc(NodeIdx, row.deps.len) catch return error.OutOfMemory;
        for (row.deps, 0..) |d, k| {
            deps[k] = std.math.cast(NodeIdx, d) orelse {
                gpa.free(deps);
                return error.Fail;
            };
        }
        metas.append(gpa, .{
            .actor = row.actor,
            .seq = row.seq,
            .start_op = row.start_op,
            .max_op = row.max_op,
            .time = row.timestamp,
            .message = row.message orelse &.{},
            .deps = deps,
            .footer = row.extra,
        }) catch {
            gpa.free(deps);
            return error.OutOfMemory;
        };
    }
    const count = metas.items.len;

    const resolve: DepResolver = .{ .built = out, .bundle = .{
        .num_changes = count,
        .deps = b.depsList(),
    } };

    var builder_of = try gpa.alloc(usize, count);
    defer gpa.free(builder_of);
    var builders = try gpa.alloc(Builder, count);
    defer {
        for (builders) |*bld| bld.deinit(gpa);
        gpa.free(builders);
    }
    for (metas.items, 0..) |meta, i| {
        builders[i] = .{
            .actor = meta.actor,
            .seq = meta.seq,
            .meta = i,
            .start_op = meta.start_op,
            .max_op = meta.max_op,
        };
    }
    std.mem.sort(Builder, builders, {}, builderLessThan);
    for (builders, 0..) |*bld, i| builder_of[bld.meta] = i;
    for (builders) |*bld| try bld.reserve(gpa);

    while (try ops_iter.next()) |op| {
        // `place` releases a builder it drops, so the ownership moves here.
        const owned = try opmod.OpBuilder.init(
            gpa,
            op.id,
            op.obj,
            op.action,
            keyRefOf(op.key),
            op.value,
            op.insert,
            op.expand,
            op.mark_name,
            op.pred,
        );
        try place(gpa, builders, owned);
    }
    try checkCoverage(builders);

    for (metas.items, 0..) |meta, i| {
        var built = try finishOne(gpa, actors, &builders[builder_of[i]], meta, resolve);
        errdefer built.deinit(gpa);
        try out.items.append(gpa, built);
    }
}

/// A bundle key as the collector spells it — the same two shapes, and the
/// sequence arm is the element id the anchor names.
fn keyRefOf(key: bundlem.KeyRef) KeyRef {
    return switch (key) {
        .map => |k| .{ .map = k },
        .seq => |e| .{ .seq = ElemId.fromOpId(e) },
    };
}

/// The `(obj, elemid-or-key)` pair a row hangs by, which is what the collector
/// groups on.
const Register = struct {
    obj: ObjId,
    key: KeyRef,
};

/// Whether two rows belong to the same register. The root's key is the empty
/// string, which is a real value and not "no key"
/// ([`OpStepper::initial`](opset/op.zig)).
fn sameRegister(a: ?Register, b: Register) bool {
    const left = a orelse return false;
    if (!left.obj.eql(b.obj)) return false;
    return left.key.eql(b.key);
}

/// Places an op in the builder that claims its counter
/// ([`ChangeCollector::add`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):818-822,
/// over [`VecEncoder::add`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):298-301)).
///
/// Upstream asserts the slot is free; a second op for one counter is a
/// corrupt op set, and it is `error.Fail` here rather than a silent overwrite.
fn place(
    gpa: Allocator,
    builders: []Builder,
    bld: opmod.OpBuilder,
) (Error || InternalError)!void {
    var owned = bld;
    const id = owned.id();
    errdefer owned.deinit(gpa);
    // Upstream's `ChangeCollector::add` drops an op no builder claims
    // ([`collector.rs:818-822`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs)),
    // and that is right: the builders hold only the changes that were asked for,
    // so a row belonging to any other change is simply not in this batch. It
    // would be **wrong** for an op belonging to a change that *is* in the batch
    // whose range does not reach it, because an emptied change still encodes and
    // still gets a hash and the failure surfaces three steps later. That case
    // is not decidable per op — a range the caller did not ask for looks exactly
    // the same — so it is caught by `checkCoverage` after the walk, where the
    // change it empties is known.
    // **A drop releases the builder.** `errdefer` fires only on an *error*
    // return, so a plain `return` past here would leak the predecessor list
    // `OpBuilder.init` allocated — and dropping ops is the common case, not the
    // rare one, so that leak is the collector's normal path rather than an edge.
    const at = builderIndexOf(builders, id.actor, id.counter) orelse {
        owned.deinit(gpa);
        return;
    };
    const builder = &builders[at];
    if (id.counter < builder.start_op or id.counter > builder.max_op) {
        owned.deinit(gpa);
        return;
    }
    const index: usize = @intCast(id.counter - builder.start_op);
    if (index >= builder.ops.items.len) {
        owned.deinit(gpa);
        return;
    }
    // A second op for one counter is a corrupt op set. Upstream asserts
    // ([`VecEncoder::add`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):298-301);
    // here it is `error.Fail`, because a silent overwrite would produce a
    // change with the wrong hash.
    if (builder.ops.items[index] != null) return error.Fail;
    builder.ops.items[index] = try ChangeOp.init(
        gpa,
        id,
        owned.objId(),
        owned.action(),
        owned.key(),
        owned.value(),
        owned.insert(),
        owned.expand(),
        owned.markName(),
        owned.pred(),
    );
    // `ChangeOp.init` copies the predecessor list out of the builder, so the
    // builder's own list is ours to release here. The `errdefer` above does it
    // on every failure path, so this line is the success path's half of the
    // same release and not a second one.
    owned.deinit(gpa);
}

/// The largest op count one change may claim, so a hostile document cannot make
/// the slot array allocate from a number it wrote. Upstream sizes the array
/// from `max_op` too (`VecEncoder::try_new`, `collector.rs:286-291`) and relies
/// on the op rows existing; here the rows are the op set, which is already
/// bounded, and this bound is the same idea stated.
const max_slots_per_change: usize = 1 << 24;

fn builderIndexOf(
    builders: []const Builder,
    actor: ActorIdx,
    counter: u64,
) ?usize {
    var lo: usize = 0;
    var hi: usize = builders.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const builder = builders[mid];
        if (builder.actor != actor) {
            if (builder.actor < actor) lo = mid + 1 else hi = mid;
            continue;
        }
        if (counter < builder.start_op) {
            hi = mid;
            continue;
        }
        if (counter > builder.max_op) {
            lo = mid + 1;
            continue;
        }
        return mid;
    }
    return null;
}

/// Turns every successor edge whose target no row claimed into a delete op at
/// the register the walk was last in
/// ([`flush_deletes`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):839-850).
fn flushDeletes(
    gpa: Allocator,
    builders: []Builder,
    preds: *Preds,
    last: ?Register,
) (Error || InternalError)!void {
    const register = last orelse return;
    // Hash order, not the insertion order the array had: `place` writes each
    // op into the slot its own counter names, so the order these come out in
    // cannot reach the bytes the changes encode to.
    var it = preds.by_op.iterator();
    while (it.next()) |kv| {
        const bld = try opmod.OpBuilder.init(
            gpa,
            kv.key_ptr.*,
            register.obj,
            .delete,
            register.key,
            .null_value,
            false,
            false,
            null,
            kv.value_ptr.items,
        );
        try place(gpa, builders, bld);
    }
    preds.deinit(gpa);
    preds.* = .{};
}

/// Encodes one change
/// ([`OpEncoderStrategy::finish`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):189-271).
///
/// The ops are the builder's slots from the first claimed counter on, and
/// **every slot from there to the end must be claimed**: a hole is
/// `max_op` disagreeing with the rows, which is upstream's `Error::MissingOps`
/// ([`VecEncoder::finish`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):303-316)).
/// The first gap is where a change's `start_op` comes from, because that field
/// is not stored anywhere.
fn finishOne(
    gpa: Allocator,
    actors: []const ActorId,
    builder: *Builder,
    meta: BuildMeta,
    resolve: DepResolver,
) DocumentError!Built {
    var first: usize = 0;
    while (first < builder.ops.items.len and builder.ops.items[first] == null) : (first += 1) {}
    for (builder.ops.items[first..]) |maybe| {
        if (maybe == null) return error.Fail;
    }

    const count = builder.ops.items.len - first;
    var deps = try gpa.alloc(ChangeHash, meta.deps.len);
    defer gpa.free(deps);
    for (meta.deps, 0..) |dep, i| deps[i] = try resolve.get(dep);

    // **The array, and every op in it, is ours from here.** The slots were
    // nulled out of the builder above, so the builder's `deinit` will not free
    // them and nobody else will either: the encoder below only *reads* them.
    // That makes the release unconditional, which is the opposite of the
    // `errdefer` that belongs everywhere else in this file.
    const owned_ops = try gpa.alloc(ChangeOp, count);
    defer {
        for (owned_ops) |*op| op.deinit(gpa);
        gpa.free(owned_ops);
    }
    for (owned_ops, 0..) |*slot, k| {
        slot.* = builder.ops.items[first + k].?;
        builder.ops.items[first + k] = null;
    }
    for (builder.ops.items[0..first]) |*maybe| {
        maybe.* = null;
    }

    const start_op = if (count == 0) meta.max_op + 1 else builder.start_op + first;
    return encodeOneChange(
        gpa,
        actors,
        .{
            .actor = meta.actor,
            .seq = meta.seq,
            .start_op = start_op,
            .max_op = meta.max_op,
            .time = meta.time,
            .message = meta.message,
            .deps = deps,
            .footer = meta.footer,
        },
        owned_ops,
    );
}

/// Everything a change's header carries, resolved.
///
/// [`BuildMeta`] names a change's dependencies by **node index**, because the
/// collector runs before the graph exists; the header needs them by **hash**,
/// because that is what the bytes carry. Splitting them is what lets one
/// change be built from a document chunk that has no hashes yet and from a
/// commit that has no nodes yet.
pub const ChangeHeader = struct {
    /// The author, as an index into the document's actor table.
    actor: ActorIdx,
    /// The author's sequence number.
    seq: u64,
    /// The counter of the change's first op, never zero.
    start_op: u64,
    /// The counter of the change's last op.
    max_op: u64,
    /// The commit time in seconds since the epoch.
    time: i64,
    /// The commit message, empty when there was none.
    message: []const u8,
    /// The changes this one depends on, in the order the header writes them.
    deps: []const ChangeHash,
    /// The bytes after the op data: the author footer, or nothing.
    footer: []const u8,
};

/// Encodes one change from its ops
/// ([`build_change_inner`](../../github-automerge-automerge/rust/automerge/src/op_set2/change.rs):50-135).
///
/// The header order is FORMAT and is `Change.encodeHeader`'s; the op block
/// follows it, then the footer. The result is re-parsed so that the `Change`
/// borrows a body with a real `header_len` and an owned `other_actors` array,
/// which is what every downstream reader expects — and which makes the
/// re-parse a check that the bytes this produced are bytes the reader accepts.
///
/// **What the re-parse hands back is the `Change` every consumer sees**, so
/// everything the caller knew that a parse cannot read has to be filled in
/// again on the way out. There is exactly one such field, and it is
/// `max_op`; see the `withOpCount` below for why it is not optional.
pub fn encodeOneChange(
    gpa: Allocator,
    actors: []const ActorId,
    meta: ChangeHeader,
    ops: []const ChangeOp,
) DocumentError!Built {
    const actor_index = meta.actor;
    if (actor_index >= actors.len) return error.MissingActor;
    var encoded = try encodeChangeOps(ChangeOp, gpa, ops, actor_index, actors, meta.footer);
    defer encoded.deinit(gpa);

    var others: std.ArrayList(ActorId) = .empty;
    defer others.deinit(gpa);
    for (encoded.others) |other| try others.append(gpa, other);

    const header = Change{
        .bytes = &.{},
        .header_len = 0,
        .actor = actors[actor_index],
        .deps = meta.deps,
        .hash = ChangeHash.zero,
        .time = meta.time,
        .message = meta.message,
        .seq = meta.seq,
        .start_op = meta.start_op,
        .max_op = meta.max_op,
        .other_actors = others.items,
    };
    if (header.start_op == 0 or header.start_op > std.math.maxInt(u32)) return error.Overflow;

    const body = try changechunk.encodeBody(gpa, header, .{
        .cols = encoded.cols.cols,
        .footer = meta.footer,
    });
    errdefer gpa.free(body);
    var change = changerec.parseChange(body, gpa) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return e,
    };
    errdefer change.deinit(gpa);
    // **A parse cannot know how many ops the columns hold, so it does not
    // pretend to.** `Change.max_op` "is not knowable here and stays 0 until
    // `withOpCount` is called" ([`change.zig:48-52`](change.zig)) and the
    // parser writes `.max_op = 0` for that reason ([`:380-382`](change.zig)).
    // Upstream has no such hole: `Change::new_from_unverified` counts the ops
    // as it decodes them — `stored.verify_ops(|_| len += 1)`
    // ([`change.rs:30-46`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    // so `Change::max_op()` is `start_op + len - 1` for every `Change` that
    // exists at all ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    // and `ChangeGraph::get_bundle_metadata` reads `max_op` straight out of
    // the graph's `max_ops` column rather than leaving it unset
    // ([`change_graph.rs:354-374`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
    //
    // **The count is `ops.len` — the very list the columns were written from
    // — and not a re-decode of the columns that came back.** That makes the
    // filled-in `max_op` agree with the `meta.max_op` the caller computed: the
    // two are `start_op + ops.len - 1` by construction on every path in this
    // file, including the empty change, whose `start_op` is `max_op + 1` and
    // whose `max_op` therefore comes back as `start_op - 1`
    // ([`automerge.rs:693-697`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    //
    // **This moves no byte and so no hash.** `max_op` is not a header field —
    // `encodeHeader` writes deps, actor, seq, start_op, time, message and the
    // other actors ([`change.zig:181-191`](change.zig)) — so the value is a
    // decoded field the change hash was never taken over.
    change = change.withOpCount(ops.len) catch |e| return e;
    return .{ .body = body, .change = change };
}

// ── The document ────────────────────────────────────────────────────────────

/// A document: an actor table, a change graph, a change queue, an op set, and
/// the text encoding the whole thing is measured in.
///
/// Raw committed state corresponding to upstream `Automerge`
/// (`automerge.rs:248-263`). The separate `autocommit.AutoCommit` owns automatic
/// transaction boundaries; this owner never opens an automatic transaction.
///
/// Single owner: call `deinit` exactly once. Do not shallow-copy an owning
/// document. Move it only when no borrow of its address remains. `clone` and
/// `fork` produce independent owners. The allocator and `io` provider must
/// remain live until disposal; do not replace ownership-bearing fields.
/// All access requires caller synchronization. Readers can update shared scratch
/// and caches. Do not mutate through another entry point while a walk is live.
pub const Document = struct {
    /// Historical head keys and clock buffers survive selection of another scope.
    pub const HistoricalScope = struct {
        heads: []ChangeHash,
        clock: *clockmod.Clock,
    };
    /// Allocator for retained document state. Mutators must use this allocator.
    /// Methods that return independent output buffers may use another allocator.
    gpa: Allocator,
    /// Borrowed randomness capability. Its provider must outlive this document.
    io: std.Io,
    /// Owned, address-stable table of interned map keys and mark names.
    strings: *Strings,
    /// The rows, and the actor table the columns index.
    ops: Set,
    /// The change graph's copy of the actor table. **The same table as
    /// `ops.actors`**: upstream keeps one table and fans every insertion out
    /// to four places
    /// ([`insert_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1301-1306),
    /// [`remove_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):427-432)),
    /// and this port's [`ChangeGraph.addChange`](change_graph.zig) grows this
    /// one by itself while [`batchmod.BatchApply.insertNewActors`](opset/batch.zig)
    /// grows the op set's. Keeping both, and keeping them equal, is this
    /// file's job.
    authors: authorsmod.Authors,
    /// The graph of changes: what the document has seen and in what order.
    graph: ChangeGraph,
    /// The changes that arrived before their dependencies did.
    queue: ChangeQueue,
    /// Current actor: unused bytes borrow the arena or `setActorId` input;
    /// cached indices refer to `ops.actors`.
    actor: Actor,
    /// Author stamped on local changes, borrowed from the arena, or null.
    author: ?[]const u8 = null,
    /// `ops.actors` bytes, queued change bodies, and each node's author
    /// footer: the three things the document outlives.
    arena: std.heap.ArenaAllocator,
    /// What the graph cannot remember about each of its own nodes, in node
    /// order.
    node_info: std.ArrayList(NodeInfo) = .empty,
    /// The author each actor already has, by actor index; null for an actor
    /// that has none. Upstream's `actor_to_author`
    /// ([author.rs:19-38](../../github-automerge-automerge/rust/automerge/src/author.rs)).
    actor_authors: std.ArrayList(?[]const u8) = .empty,
    /// Every author name this document has ever recorded, **sorted by bytes and
    /// without repeats** — upstream's `Authors.authors`
    /// ([`author.rs`:18, :118-126](../../github-automerge-automerge/rust/automerge/src/author.rs)),
    /// which [`Authors::put_author`](../../github-automerge-automerge/rust/automerge/src/author.rs):117-132
    /// keeps that way with a binary search and an insert.
    ///
    /// **It is its own table and not a walk over [`Document.actor_authors`],
    /// and the difference is what a removal does.** Upstream's
    /// [`remove_actor`](../../github-automerge-automerge/rust/automerge/src/author.rs):93-97
    /// drops the *mapping* and says so: "this may leave a dangling `Author` in
    /// the set of authors" — the set only grows. A scan of the mapping would
    /// lose an author the moment [`Document.removeActor`] took its actor away,
    /// which is a different answer for the same history.
    ///
    /// **The bytes are the arena's** (see [`Document.arena`]), and
    /// [`Document.stageAuthor`] and [`Document.linkAuthor`] between them are
    /// the only writer.
    author_names: std.ArrayList([]const u8) = .empty,
    /// The heads a transaction is scoped to, while `isolate` has one.
    /// Upstream's `AutoCommit::isolation`
    /// ([autocommit.rs:433-441](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
    /// Owned copied heads; null disables isolation. Released with `self.gpa`.
    isolation: ?[]ChangeHash = null,

    historical_scopes: std.ArrayList(HistoricalScope) = .empty,
    /// Internal clone/render metadata; moves preserve it, but actor tables decide compatibility.
    patch_identity: u64,

    /// Internal facade log storage, inactive until explicitly enabled.
    /// Raw transactions return their own logs; commit does not synthesize a diff.
    patch_log: patchesmod.PatchLog,
    /// The heads the next incremental diff starts from
    /// ([`AutoCommit::diff_cursor`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:68`), and empty until a cursor is set.
    ///
    /// **An owned list and not a borrowed view of `graph.heads`**, because a
    /// cursor is the heads *at a moment*: [`Document.updateDiffCursor`] takes
    /// a copy of the graph's heads and every later apply moves the graph on.
    diff_cursor: std.ArrayList(ChangeHash) = .empty,

    /// The heads the last full save wrote, and the base the next incremental
    /// save is measured from
    /// ([`AutoCommit::save_cursor`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:70`).
    ///
    /// **A set of change hashes.** Upstream declares it `Vec<ChangeHash>`
    /// (`:70`), fills it with `get_heads()` (`:539`, `:594`) and hands it
    /// straight to `save_after` (`:592`) — so it is neither a byte offset into
    /// a chunk nor a change index into the graph. **Empty until a save
    /// happens**, in every constructor (`:85`, `:108`, `:122`, `:135`, `:148`,
    /// `:178`) and in `fork`/`fork_at` (`:364`, `:377`), and a document that
    /// has never been saved therefore answers
    /// [`Document.saveIncremental`] with its whole history.
    save_cursor: std.ArrayList(ChangeHash) = .empty,

    /// New empty document with a secure random 16-byte actor.
    /// `io` is borrowed for later actor draws. Entropy refusal or cancellation
    /// returns an error and no document. Use `setActorId` for deterministic ids.
    /// Upstream also draws a fresh actor (`automerge.rs:307-317`).
    pub fn init(gpa: Allocator, io: std.Io) InitError!Document {
        return initWithEncoding(gpa, io, defaultTextEncoding());
    }

    /// A new, empty document measuring text in `encoding`. The encoding is a
    /// document-level field and cannot change later, because every text-width
    /// entry in the op set is measured in it
    /// ([op_set.rs:64](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
    pub fn initWithEncoding(
        gpa: Allocator,
        io: std.Io,
        encoding: TextEncoding,
    ) InitError!Document {
        return initOwned(gpa, io, encoding, null);
    }

    fn initOwned(gpa: Allocator, io: std.Io, encoding: TextEncoding, actor_id: ?ActorId) InitError!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const id = if (actor_id) |actor|
            ActorId.init(try arena.allocator().dupe(u8, actor.bytes))
        else
            try ActorId.random(arena.allocator(), io);
        var identity_bytes: [8]u8 = undefined;
        try io.randomSecure(&identity_bytes);
        const patch_identity = std.mem.readInt(u64, &identity_bytes, .little);
        // The table is **heap allocated**, because the op set keeps a pointer
        // to it: `StringTable.ctx` is `&self.strings`, and returning a Document
        // by value relocates the field, so a table stored inline would leave
        // every walk reading freed memory.
        const strings = try gpa.create(Strings);
        errdefer gpa.destroy(strings);
        // `create` returns uninitialised memory: the table has to be *built*,
        // not merely allocated, or every field in it is whatever was in the
        // allocator's free list.
        strings.* = Strings.init(gpa);
        errdefer strings.deinit();
        const ops = Set.init(gpa, encoding, strings.table()) catch return error.OutOfMemory;
        errdefer ops.deinit();
        return .{
            .gpa = gpa,
            .io = io,
            .patch_identity = patch_identity,
            .strings = strings,
            .ops = ops,
            .authors = authorsmod.Authors.init(gpa),
            .graph = ChangeGraph.init(gpa),
            .queue = ChangeQueue.init(gpa),
            .actor = .{ .unused = id },
            .arena = arena,
            // **Inactive**, exactly as every `AutoCommit` constructor is
            // (`autocommit.rs:82,105,119,132,145,175`): recording costs an
            // allocation per applied row, and a caller that never diffs pays
            // none.
            .patch_log = .inactive(gpa),
        };
    }

    /// Releases everything: the op set, the graph, the queue, both actor
    /// tables, the string table, the arena, the node table, the patch log,
    /// both cursors and retained historical read clocks.
    /// The document is `undefined` afterward. A second disposal is invalid.
    pub fn deinit(self: *Document) void {
        self.diff_cursor.deinit(self.gpa);
        self.save_cursor.deinit(self.gpa);
        self.patch_log.deinit();
        if (self.isolation) |heads| self.gpa.free(heads);
        self.invalidateHistoricalScopes();
        self.historical_scopes.deinit(self.gpa);
        self.node_info.deinit(self.gpa);
        self.actor_authors.deinit(self.gpa);
        // **The list, not the names in it**: those are arena bytes, released
        // two lines down with everything else the document borrowed.
        self.author_names.deinit(self.gpa);
        self.arena.deinit();
        self.queue.deinit();
        self.graph.deinit();
        self.authors.deinit();
        self.ops.deinit();
        self.strings.deinit();
        self.gpa.destroy(self.strings);
        self.* = undefined;
    }

    /// The allocator this document allocates from.
    pub fn allocator(self: *const Document) Allocator {
        return self.gpa;
    }

    /// Stable clone/render metadata, not an external patch-log compatibility token.
    pub fn patchIdentity(self: *const Document) u64 {
        return self.patch_identity;
    }

    /// Releases historical iterator clocks after a mutation invalidates their borrows.
    pub fn invalidateHistoricalScopes(self: *Document) void {
        for (self.historical_scopes.items) |*scope| {
            self.gpa.free(scope.heads);
            scope.clock.deinit();
            self.gpa.destroy(scope.clock);
        }
        self.historical_scopes.clearRetainingCapacity();
    }

    // ── The actor table ────────────────────────────────────────────────────

    /// The document's current actor id
    /// ([`Automerge::get_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):420-425).
    ///
    /// **A cached index that no longer names an actor falls back to the empty
    /// id** rather than trapping. Upstream's `self.ops.get_actor(*index)`
    /// returns a reference into the table, so the case cannot arise there; here
    /// the table and the cache are separate fields and a bug in one would
    /// otherwise be a panic on a read.
    pub fn getActorId(self: *const Document) ActorId {
        return switch (self.actor) {
            .unused => |a| a,
            .cached => |idx| self.ops.getActor(idx) orelse ActorId.init(&.{}),
        };
    }

    /// Sets the document's current actor
    /// ([`Automerge::set_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):367-373).
    ///
    /// An actor already in the table is **cached by index** rather than copied,
    /// which is upstream's whole point of the split: a document that has seen
    /// an actor does not keep a second copy of its bytes.
    pub fn setActorId(self: *Document, actor: ActorId) void {
        if (self.ops.lookupActor(actor)) |idx| {
            self.actor = .{ .cached = @intCast(idx) };
        } else {
            self.actor = .{ .unused = actor };
        }
    }

    /// The index of the current actor, when it is interned
    /// ([`get_actor_index`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):468-473).
    pub fn getActorIndex(self: *const Document) ?ActorIdx {
        return self.actor.index();
    }

    /// The bytes of the actor at `idx`, or null when the index is out of range
    /// ([`OpSet::get_actor_safe`](opset/op_set.zig)).
    pub fn getActor(self: *const Document, idx: ActorIdx) ?ActorId {
        return self.ops.getActor(idx);
    }

    /// The number of actors the document knows.
    pub fn numActors(self: *const Document) usize {
        return self.ops.actors.items.len;
    }

    /// Interns `actor` if the table does not have it, and returns its index
    /// ([`Automerge::put_actor_ref`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1309-1314).
    ///
    /// **This is the fan-out.** Upstream's `insert_actor` touches four places
    /// ([`:1301-1306`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)) — the op
    /// set, the change graph, the cached actor and the author table — because
    /// every stored reference to an actor is its index into one sorted table
    /// and an insertion in the middle shifts every index above it. The port
    /// splits the op set's copy from the graph's, so this is where the two are
    /// kept equal.
    pub fn putActorRef(self: *Document, gpa: Allocator, actor: ActorId) Error!ActorIdx {
        if (self.ops.lookupActor(actor)) |idx| return @intCast(idx);
        const slot = self.actorSlot(actor);
        try self.insertActor(gpa, slot, actor);
        return @intCast(slot);
    }

    /// Where `actor` belongs in the sorted actor table
    /// ([`binary_search`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1310-1320)).
    ///
    /// **A lower bound, and the equality test is at it.** The port's
    /// [`opsetmod.OpSet.insertActor`] takes a *sorted index*, so the search must
    /// stop on `.eq` as well as on `.gt`: an upper bound would report an actor
    /// that is already there as absent, intern it a second time, and renumber
    /// every actor index above it. This is the same search
    /// [`batchmod.BatchApply.actorSlot`](opset/batch.zig) runs.
    fn actorSlot(self: *const Document, actor: ActorId) usize {
        var lo: usize = 0;
        var hi: usize = self.ops.actors.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (actor.order(self.ops.actors.items[mid]) == .gt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    const PreparedActorInsert = struct {
        idx: ActorIdx,
        ops: Set.PreparedActorInsert,
        authors: authorsmod.Authors.PreparedInsert,

        fn deinit(self: *PreparedActorInsert) void {
            self.ops.deinit();
            self.authors.deinit();
        }

        fn publish(self: *PreparedActorInsert, doc: *Document) void {
            self.ops.publish(&doc.ops);
            self.authors.publish(&doc.authors);
            doc.graph.publishActorInsert(self.idx);
            doc.actor_authors.insertAssumeCapacity(self.idx, null);
            doc.actor.rewriteWithNewActor(self.idx);
            doc.invalidateHistoricalScopes();
        }
    };

    /// Copies and reserves every actor mirror before any index becomes visible.
    /// Aborted actor copies remain arena-owned scratch until document teardown.
    fn prepareActorInsert(
        self: *Document,
        gpa: Allocator,
        slot: usize,
        actor: ActorId,
    ) Error!PreparedActorInsert {
        const idx = std.math.cast(ActorIdx, slot) orelse return error.InvalidIndex;
        if (slot > self.ops.actors.items.len) return error.InvalidIndex;
        const owned = try self.arena.allocator().dupe(u8, actor.bytes);
        var ops = self.ops.prepareActorInsert(slot, .{ .bytes = owned }) catch |e|
            return opError(e);
        errdefer ops.deinit();
        var authors = try self.authors.prepareInsertAt(gpa, idx, .{ .bytes = owned });
        errdefer authors.deinit();
        try self.graph.reserveActorInsert(gpa);
        try self.actor_authors.ensureUnusedCapacity(gpa, 1);
        return .{ .idx = idx, .ops = ops, .authors = authors };
    }

    /// Publishes one sorted insertion across all mirrors without a fallible tail.
    fn insertActor(self: *Document, gpa: Allocator, slot: usize, actor: ActorId) Error!void {
        var prepared = try self.prepareActorInsert(gpa, slot, actor);
        defer prepared.deinit();
        prepared.publish(self);
    }

    /// The author an actor already has, or null
    /// ([`get_author_for_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):414-417).
    pub fn getAuthorForActor(self: *const Document, actor: ActorId) ?[]const u8 {
        const idx = self.ops.lookupActor(actor) orelse return null;
        const i: usize = idx;
        if (i >= self.actor_authors.items.len) return null;
        return self.actor_authors.items[i];
    }

    /// Every actor that already has the author `author`
    /// ([`get_actors_for_author`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):403-408).
    pub fn getActorForAuthor(self: *const Document, gpa: Allocator, author: []const u8) Error![]ActorId {
        var out: std.ArrayList(ActorId) = .empty;
        errdefer out.deinit(gpa);
        for (self.actor_authors.items, 0..) |maybe, i| {
            const have = maybe orelse continue;
            if (!std.mem.eql(u8, have, author)) continue;
            try out.append(gpa, self.ops.actors.items[i]);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every actor in the document, in index order. The caller owns the array;
    /// the bytes belong to the document.
    pub fn getActors(self: *const Document, gpa: Allocator) Error![]ActorId {
        const out = try gpa.alloc(ActorId, self.ops.actors.items.len);
        errdefer gpa.free(out);
        @memcpy(out, self.ops.actors.items);
        return out;
    }

    /// Every author name this document holds, **sorted by bytes and without
    /// repeats** ([`Automerge::get_authors`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):410-412,
    /// over [`Authors::get_authors`](../../github-automerge-automerge/rust/automerge/src/author.rs):55-56).
    ///
    /// **Names, not actor ids.** Upstream's answer is `&[Author<'static>]`
    /// and `API.md` renamed it to `getAuthors(doc, gpa) []ActorId`, which is a
    /// different question: an actor id is sixteen bytes of hash and a name is
    /// the bytes a person wrote. [`Document.getActors`] is that surface and
    /// already exists.
    ///
    /// **The set is historical, and that is the whole of the semantics.** A
    /// name enters it when a change footer carries it
    /// ([`Document.stageAuthor`]) and never leaves: upstream's
    /// [`remove_actor`](../../github-automerge-automerge/rust/automerge/src/author.rs):93-97
    /// drops the actor-to-author *mapping* and documents that this "may leave
    /// a dangling `Author` in the set of authors". So a document that has
    /// rolled an actor away still reports the name that actor used — which is
    /// what a caller asking "who has written in this document" wants.
    ///
    /// **A name the document has not stamped on a change is not in it.** The
    /// only writer is the [`Document.stageAuthor`] / [`Document.linkAuthor`]
    /// pair, which upstream reaches from inside `if let Some(author) =
    /// change.author()`
    /// ([`change_graph.rs`:563-566](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    /// so [`Document.setAuthor`] alone does not put a name here — the first
    /// *commit* under that name does.
    ///
    /// **The array is the caller's**; the names are the arena's and are valid
    /// until the document is dropped.
    pub fn getAuthors(self: *const Document, gpa: Allocator) Error![]const []const u8 {
        const out = try gpa.alloc([]const u8, self.author_names.items.len);
        errdefer gpa.free(out);
        @memcpy(out, self.author_names.items);
        return out;
    }

    /// Where `name` belongs in [`Document.author_names`], or **null when it is
    /// already there** — which is upstream's `put_author` answering
    /// `Ok(index)` rather than `Err(index)`
    /// ([`author.rs`:117-132](../../github-automerge-automerge/rust/automerge/src/author.rs)):
    /// a binary search for the name, and an insert at the answer only when the
    /// search missed. Two actors that chose the same name are one author, so
    /// the second stamp grows nothing.
    ///
    /// The search itself cannot fail, which is what lets
    /// [`Document.stageAuthor`] do it before the one allocation it makes.
    fn authorNameSlot(self: *const Document, name: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = self.author_names.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.author_names.items[mid], name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return null,
            }
        }
        return lo;
    }

    /// Inserts into capacity reserved before publication. Recompute the position
    /// at publication because a batch can contain several new author names.
    fn insertAuthorName(self: *Document, at: usize, name: []const u8) void {
        self.author_names.insertAssumeCapacity(at, name);
    }

    /// The author this document stamps on its changes, or null
    /// ([`Automerge::get_author`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):399-401).
    pub fn getAuthor(self: *const Document) ?[]const u8 {
        return self.author;
    }

    /// Sets the author this document stamps on its changes
    /// ([`Automerge::set_author`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):389-396).
    ///
    /// **A change of author mints a new actor id** in upstream, and so here: two
    /// different authors must not share one actor's sequence numbers, because a
    /// sequence number means "the n-th change this actor made" and the two
    /// histories would collide. The id comes from the retained `io` capability;
    /// entropy refusal leaves both actor and author unchanged.
    pub fn setAuthor(self: *Document, gpa: Allocator, author: ?[]const u8) Error!void {
        // Stateless allocator contexts are undefined; never compare their ptr.
        std.debug.assert(gpa.vtable == self.gpa.vtable);
        // An `if` rather than a `switch`: this body had never been analysed,
        // because nothing in the tree called `setAuthor`, and it is the lazy
        // analysis that hid it (STATUS.md defect 10).
        const same = if (self.author) |have|
            if (author) |want| std.mem.eql(u8, have, want) else false
        else
            author == null;
        if (same) return;
        // Stage both values before publishing either (`automerge.rs:392-394`).
        const name: ?[]const u8 = if (author) |bytes|
            try self.arena.allocator().dupe(u8, bytes)
        else
            null;
        const owned = try ActorId.random(self.arena.allocator(), self.io);
        self.author = name;
        self.actor = .{ .unused = owned };
    }

    /// The author a change carries: the one its footer names, not the
    /// document's own ([`Change::author`](../../github-automerge-automerge/rust/automerge/src/change.rs)).
    ///
    /// **A footer this cannot read is no author, not an error.** The screen uses
    /// this to *refuse* a change, and a change whose footer is malformed is not
    /// evidence that it has one.
    fn changeAuthor(_: ?*anyopaque, change: *const Change) ?[]const u8 {
        return decodeAuthorFooter(changeFooter(change.*)) catch null;
    }

    /// The author an actor already has in the document
    /// ([`get_author_for_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):414-417).
    fn actorAuthor(ctx: ?*anyopaque, actor: ActorId) ?[]const u8 {
        const self: *Document = @ptrCast(@alignCast(ctx.?));
        return self.getAuthorForActor(actor);
    }

    /// Records the author `footer` names for the actor at `idx` — the port's
    /// [`Authors::assign_author`](../github-automerge-automerge/rust/automerge/src/author.rs):88-91,
    /// which is `authors.assign_author(author.into_owned(), actor)` and
    /// **which upstream calls for one change out of an actor's many**: the
    /// call sits inside `if let Some(author) = change.author()`
    /// ([`change_graph.rs`:563-566](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    /// so a change whose footer names nothing does not call it at all. Upstream
    /// then asserts `change.seq() == 1` on that branch, because an actor has
    /// one author and it rides that actor's first change
    /// ([`automerge.rs`:568](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    ///
    /// **So the check is on the change's own footer, and that is the whole
    /// mechanism: there is no flag to remember to set and no lookup in the
    /// table to consult.** Every route that links a change into this document
    /// — the local commit, an applied change, a document chunk read back —
    /// hands its footer here and this decides.
    ///
    /// **The `None` branch does nothing, and that is the whole fix.** Writing
    /// `null` over an entry an earlier change had already filled takes that
    /// author out of the document's set of authors, because the set is the
    /// distinct non-null entries of this table — so an actor's second change,
    /// carrying no footer, erased the author its first change had just
    /// recorded. It is a **loss and not a duplicate**, which is why the
    /// symptom was a count one short rather than a count one over. Measured
    /// on `an author's footer rides only its actor's first change`: the
    /// surviving name was `020202` and `010101` was gone, because the actor
    /// whose footer was `010101` then committed a second change.
    ///
    /// **The name is copied into the arena, as upstream's `into_owned` does.**
    /// Two of the three callers hand bytes that die with the buffer they were
    /// read from — a change body the caller frees, and a `footer` list a
    /// `defer` empties — so a borrow here would be a dangling read on the next
    /// `save`.
    ///
    /// **The work is split in two, and the split is what makes the pair
    /// atomic.** Every allocation this association needs is taken by
    /// [`Document.stageAuthor`]; the two writes it stands for —
    /// `author_names.insert` and `actor_authors[i] = name` — are infallible and
    /// happen together in [`Document.linkAuthor`]. Upstream's
    /// [`assign_author`](../../github-automerge-automerge/rust/automerge/src/author.rs):88-91
    /// is `let author_id = self.put_author(author); self.actor_to_author[actor]
    /// = Some(author_id);` — the name first, the slot second, and neither can
    /// fail — and this is that order with the fallible half pulled forward.
    fn stageAuthor(
        self: *Document,
        gpa: Allocator,
        idx: ActorIdx,
        footer: ?[]const u8,
    ) Allocator.Error!?StagedAuthor {
        // `catch return`: a footer this cannot read names no author, the same
        // answer [`decodeAuthorFooter`] gives a footer whose first word is not
        // `Footer::Author`, and the same one [`Document.changeAuthor`] gives
        // the screen in front of a merge.
        const author = (decodeAuthorFooter(footer) catch return null) orelse return null;
        try self.growActorAuthors(gpa);
        const i: usize = idx;
        // A slot the actor table does not have records the **name only**. That
        // is upstream's shape — `put_author` runs before the
        // `actor_to_author[actor] = …` write and the write would panic on a
        // short table, which upstream cannot have because
        // `Authors::with_actors` sizes it from the actor count
        // (`author.rs`:46-52) — and the port's bound check is what keeps the
        // write below from being one.
        const slot: ?usize = if (i < self.actor_authors.items.len) i else null;
        const name = self.arena.allocator().dupe(u8, author) catch
            return error.OutOfMemory;
        if (self.authorNameSlot(name) != null) {
            try self.author_names.ensureUnusedCapacity(gpa, 1);
        }
        return .{ .name = name, .slot = slot };
    }

    /// Finishes an association [`Document.stageAuthor`] prepared. **Writes the
    /// name into the set first and the actor's slot second**, one name and one
    /// arena copy with both tables pointing at it, and cannot fail — so a
    /// caller that stages before its last fallible step leaves the document
    /// exactly as it found it on every refusal.
    fn linkAuthor(self: *Document, staged: StagedAuthor) void {
        if (self.authorNameSlot(staged.name)) |at| self.insertAuthorName(at, staged.name);
        if (staged.slot) |slot| self.actor_authors.items[slot] = staged.name;
    }

    /// An author association whose allocations are all taken and whose two
    /// writes are not yet made.
    ///
    /// **What it exists for.** An author is recorded because a change carried
    /// it, and the change's own linking is fallible: `graph.addChange` and
    /// `node_info.append` both allocate. Writing the association before them
    /// and refusing afterwards would leave a name in the set for a change that
    /// was never applied; writing it after them and refusing there would leave
    /// a linked change with no author at all, which **cannot heal** — the
    /// change is in the graph at `seq == 1`, so no later change from that
    /// actor ever stamps a footer, and the caller is also told the commit
    /// failed on a document whose change is already in. Staging the
    /// allocations and writing both tables in one infallible step closes the
    /// window from both sides: a refusal anywhere leaves neither table changed,
    /// and the two tables are never seen disagreeing.
    const StagedAuthor = struct {
        /// The name, already copied into the arena, and what both tables are
        /// given.
        name: []const u8,
        /// The actor's slot in `actor_authors`, or null when the actor table
        /// has no slot for this actor.
        slot: ?usize,
    };

    /// Grows `actor_authors` to the actor table's length, **filling every new
    /// slot with `null`**.
    ///
    /// **`ArrayList.resize` is not a way to grow this list, and using it here
    /// is a use-after-free dressed as an author.** `resize` is
    /// `ensureTotalCapacity` then `items.len = new_len`, with nothing written
    /// into the slots past the old length
    /// (`std.array_list.ArrayList.resize`),
    /// and a `?[]const u8` is a pointer and a length, so an undefined slot is
    /// garbage rather than a null. [`Document.getAuthorForActor`] bounds-checks
    /// the *index* and not the *value*, so it hands that garbage to a caller
    /// as an author. Measured on `an author's footer rides only its actor's
    /// first change`: after the save/load the empty actor — the one no change
    /// names, and so the one no footer ever fills — answered an author of
    /// length 12297829382473034410 at `0xaaaaaaaaaaaaaaaa`, and sorting the
    /// three-byte author `010101` against it faulted inside
    /// `std.mem.order`.
    ///
    /// Upstream's table is `vec![None; actors]` (`author.rs`:46-52) and grows
    /// with `insert(actor, None)` (`:95-97`), so a slot is null until a footer
    /// fills it, and only a footer does.
    fn growActorAuthors(self: *Document, gpa: Allocator) Allocator.Error!void {
        const want = self.ops.actors.items.len;
        if (self.actor_authors.items.len >= want) return;
        try self.actor_authors.appendNTimes(gpa, null, want - self.actor_authors.items.len);
    }

    /// The [`batchmod.AuthorLookup`] the screen in front of a merge asks
    /// ([`batch.rs:1084-1090`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
    ///
    /// Upstream's two functions are `change.author()` and
    /// `get_author_for_actor(change.actor_id())` ([`:1085-1086`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs));
    /// both facts live in this file, so both are here.
    /// Callbacks run synchronously on the invoking thread and borrow this
    /// document at its current address. They do not mutate or reenter it.
    /// Returned author bytes are document borrows, invalidated by mutation.
    pub fn authorLookup(self: *Document) batchmod.AuthorLookup {
        return .{ .ctx = self, .changeAuthor = changeAuthor, .actorAuthor = actorAuthor };
    }

    // ── Transactions ───────────────────────────────────────────────────────

    /// What a transaction needs to open
    /// ([`TransactionArgs`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):49-65,
    /// built by [`Automerge::transaction_args`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):533-577).
    ///
    /// This is the seam the transaction slice opens through, and it is here
    /// rather than there because every one of its fields is read from the actor
    /// table, the change graph or the queue.
    pub const TransactionArgs = struct {
        /// The actor index this transaction will create ops for.
        actor_index: ActorIdx,
        /// The sequence number the change it commits will carry: one past the
        /// last this actor has issued.
        seq: u64,
        /// The counter of the change's first op. **Global, not per actor**
        /// ([`automerge.rs:567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
        /// `change_graph.max_op() + 1`, because op counters are a document-wide
        /// namespace.
        start_op: u64,
        /// The changes the change it commits will depend on, sorted. The caller
        /// owns the array.
        deps: []ChangeHash,
        /// The heads the transaction reads at, when it is isolated. Null is an
        /// unscoped read of the present document, which is what takes the
        /// indexed fast paths.
        scope: ?[]const ChangeHash,
        /// The author the change carries. Upstream sets it only for an actor's
        /// *first* change ([`automerge.rs:568`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
        /// because one actor has one author.
        author: ?[]const u8,

        /// Frees `deps` and nothing else.
        pub fn deinit(self: TransactionArgs, gpa: Allocator) void {
            gpa.free(self.deps);
        }
    };

    /// Owns unpublished transaction arguments and their actor/queue preflight.
    /// Keep the token at a stable address until publication or disposal.
    pub const PreparedTransactionArgs = struct {
        gpa: Allocator,
        owner: *Document,
        args: TransactionArgs,
        actors: []const ActorId,
        actor_insert: ?PreparedActorInsert,
        queue_removal: queuemod.PreparedActorBranchRemoval,
        cache_actor: ?ActorIdx,
        published: bool = false,

        /// Releases scratch, and dependencies only if publication did not move them.
        pub fn deinit(self: *PreparedTransactionArgs) void {
            if (!self.published) self.args.deinit(self.gpa);
            if (self.actor_insert) |*actor_insert| actor_insert.deinit();
            self.queue_removal.deinit();
            self.* = undefined;
        }
    };

    /// Reserves all transaction state without publishing actor or queue changes.
    /// This lets a logged constructor bind its branch before document mutation.
    pub fn prepareTransactionArgs(
        self: *Document,
        gpa: Allocator,
        heads: ?[]const ChangeHash,
    ) DocumentError!PreparedTransactionArgs {
        const choice = if (heads) |at|
            try self.isolatedActorIndex(gpa, at)
        else
            ActorChoice{
                .actor = self.getActorId(),
                .index = if (self.ops.lookupActor(self.getActorId())) |idx|
                    @intCast(idx)
                else
                    null,
                .owned = false,
            };
        defer if (choice.owned) gpa.free(choice.actor.bytes);
        const actor_index = choice.index orelse
            (std.math.cast(ActorIdx, self.actorSlot(choice.actor)) orelse
                return error.InvalidIndex);
        // A new slot still names the old actor until publication; its sequence is one.
        const seq = if (choice.index) |idx| self.graph.seqForActor(idx) + 1 else 1;
        var deps: std.ArrayList(ChangeHash) = .empty;
        errdefer deps.deinit(gpa);
        try deps.appendSlice(gpa, heads orelse self.graph.getHeads());
        if (heads == null and seq > 1) {
            // Resolve this dependency before actor insertion renumbers graph indices.
            const last = try self.graph.hashForActorSeq(actor_index, seq - 1);
            if (indexOfHash(deps.items, last) == null) try deps.append(gpa, last);
        }
        std.mem.sort(ChangeHash, deps.items, {}, ChangeHash.lessThan);

        var actor_insert: ?PreparedActorInsert = null;
        errdefer if (actor_insert) |*insert| insert.deinit();
        if (choice.index == null) {
            actor_insert = try self.prepareActorInsert(gpa, actor_index, choice.actor);
        }
        const actors = if (actor_insert) |insert|
            insert.ops.actors.items
        else
            self.ops.actors.items;
        var cache_actor: ?ActorIdx = null;
        if (self.actor == .unused) {
            const base = self.getActorId();
            for (actors, 0..) |actor, idx| {
                if (actor.eql(base)) {
                    cache_actor = @intCast(idx);
                    break;
                }
            }
            std.debug.assert(cache_actor != null);
        }
        var queue_removal = try self.queue.prepareRemoveActorBranchFrom(
            gpa,
            actors[actor_index],
            seq,
        );
        errdefer queue_removal.deinit();
        const owned_deps = try deps.toOwnedSlice(gpa);
        return .{
            .gpa = gpa,
            .owner = self,
            .args = .{
                .actor_index = actor_index,
                .seq = seq,
                .start_op = self.graph.maxOp() + 1,
                .deps = owned_deps,
                .scope = heads,
                .author = if (seq == 1) self.author else null,
            },
            .actors = actors,
            .actor_insert = actor_insert,
            .queue_removal = queue_removal,
            .cache_actor = cache_actor,
        };
    }

    /// Publishes a successful preflight without allocating and moves its arguments.
    pub fn publishTransactionArgs(
        self: *Document,
        prepared: *PreparedTransactionArgs,
    ) TransactionArgs {
        std.debug.assert(prepared.owner == self);
        std.debug.assert(!prepared.published);
        if (prepared.actor_insert) |*insert| insert.publish(self);
        if (prepared.cache_actor) |idx| self.actor = .{ .cached = idx };
        prepared.queue_removal.publish(&self.queue);
        prepared.published = true;
        return prepared.args;
    }

    /// Builds and publishes arguments for current or explicitly scoped transactions.
    pub fn transactionArgs(
        self: *Document,
        gpa: Allocator,
        heads: ?[]const ChangeHash,
    ) DocumentError!TransactionArgs {
        var prepared = try self.prepareTransactionArgs(gpa, heads);
        defer prepared.deinit();
        return self.publishTransactionArgs(&prepared);
    }

    const ActorChoice = struct {
        actor: ActorId,
        index: ?ActorIdx,
        owned: bool,
    };

    /// Selects a covered actor or the first absent concurrency actor using the
    /// original clock and indices; only the chosen absent actor will be staged.
    fn isolatedActorIndex(
        self: *Document,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) DocumentError!ActorChoice {
        var clock = try self.graph.clockAt(gpa, heads);
        defer clock.deinit();
        const base = self.getActorId();
        if (self.ops.lookupActor(base)) |idx| {
            const index: ActorIdx = @intCast(idx);
            const max_op = self.graph.maxOpForActor(index);
            if (max_op == 0 or clock.contains(OpId.init(@intCast(max_op), index))) {
                return .{ .actor = base, .index = index, .owned = false };
            }
        } else {
            return .{ .actor = base, .index = null, .owned = false };
        }
        // At most every existing actor can occupy a concurrency level.
        for (0..self.ops.actors.items.len + 1) |offset| {
            const candidate = try ActorId.withConcurrency(gpa, base, offset + 1);
            errdefer gpa.free(candidate.bytes);
            if (self.ops.lookupActor(candidate)) |idx| {
                const index: ActorIdx = @intCast(idx);
                const max_op = self.graph.maxOpForActor(index);
                if (max_op == 0 or clock.contains(OpId.init(@intCast(max_op), index))) {
                    return .{ .actor = candidate, .index = index, .owned = true };
                }
                gpa.free(candidate.bytes);
            } else {
                return .{ .actor = candidate, .index = null, .owned = true };
            }
        }
        unreachable;
    }

    /// The current actor's index, interning the actor if the table does not
    /// have it yet
    /// ([`get_or_create_actor_index`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):457-466).
    fn getOrCreateActorIndex(self: *Document, gpa: Allocator) (Error || ParseError)!ActorIdx {
        return switch (self.actor) {
            .cached => |i| i,
            .unused => |actor| blk: {
                const idx = try self.putActorRef(gpa, actor);
                self.actor = .{ .cached = idx };
                break :blk idx;
            },
        };
    }

    /// The heads a transaction is scoped to, or null
    /// ([`AutoCommit::isolation`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):433-437).
    pub fn isolationHeads(self: *const Document) ?[]const ChangeHash {
        return self.isolation;
    }

    /// Where the document is **as a view**, which is the isolation when there
    /// is one and the graph's heads otherwise
    /// ([`AutoCommit::get_heads`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):695-700).
    ///
    /// **Every diff-side call site reads this and not the graph.** Upstream's
    /// `diff_incremental` (`:340-355`) and `update_diff_cursor` (`:199-206`)
    /// both call `self.get_heads()`, and `get_heads` answers the isolation
    /// first — so an isolated document diffs to *the isolated view*, not to
    /// the present. Reading `graph.getHeads()` there instead makes
    /// [`Document.diffInner`]'s first branch (`after` is the present and the
    /// cursor is on it, `autocommit.rs:276-286`) fire when it should not: the
    /// recorded log is answered where upstream walks, and a stream that
    /// replays the isolation's transitions comes out where a single walk
    /// patch belongs. [`Document.patchTo`] reads it for the same reason.
    pub fn viewHeads(self: *const Document) []const ChangeHash {
        return self.isolation orelse self.graph.getHeads();
    }

    /// Closes the view the document is leaving and replays the one it is
    /// entering ([`AutoCommit::patch_to`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):816-824).
    ///
    /// **Both [`Document.isolate`] and [`Document.integrate`] call this, and
    /// it is not a logging nicety.** `AutoCommit::isolate` is `patch_to` plus
    /// one assignment (`:435-436`) and `AutoCommit::integrate` is `patch_to`
    /// plus one assignment (`:441-442`): the *state* is one line and the
    /// view transition is the method. `finish_current_view`
    /// ([`patch_log.rs`:290-303](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs))
    /// is what turns the current view's events into patches while their paths
    /// still resolve, and the walk is what records the view being entered.
    /// An incremental diff over an isolated write reports the write and
    /// nothing else without both.
    ///
    /// **`before` is the isolation when there is one and the graph's heads
    /// otherwise** — `get_heads`, `autocommit.rs`:695-700 — because upstream
    /// reads "where the document is" from the isolation first and falls back to
    /// the heads.
    ///
    /// **Both halves are load-bearing, and the oracle's `isolateprobe` says
    /// which.** The upstream case of
    /// `incorrect_patches_produced_when_isolating_and_integrating`
    /// ([`text.rs:868-921`](../../github-automerge-automerge/rust/automerge/tests/text.rs))
    /// emits **seven** patches, and draining the reference's log at every step
    /// attributes five of them to the walk below and **none** to
    /// `finish_current_view`: the close half is a no-op at that case's
    /// `isolate()`, because the previous `diff_incremental` left the log empty.
    /// What the close half does is *finalise* the four events the walk and the
    /// isolated commit recorded, which is what puts them in the stream ahead of
    /// the three the `integrate()` walk records. See the diff block at the foot
    /// of this file.
    fn patchTo(self: *Document, gpa: Allocator, after: []const ChangeHash) DiffError!void {
        const before = self.viewHeads();
        // `autocommit.rs:819` — the walk is only worth doing when the document
        // is moving, and a transition to where it already is must not finish a
        // view, because finishing one moves its events into `completed`.
        if (sameHashList(before, after)) return;
        // `automerge.rs:1230-1234` over the pair, and **built before the view
        // is finished**, because closing a view resolves its patches against
        // the state that view is of the document.
        var before_clock = try self.clockAtHeads(gpa, before);
        defer before_clock.deinit();
        var after_clock = try self.clockAtHeads(gpa, after);
        defer after_clock.deinit();
        {
            // **The view is the one being closed, and it is what upstream
            // resolves against**: `finish_current_view` does
            // `self.heads.replace(heads.to_vec())` and then
            // `make_current_patches(doc)` ([`patch_log.rs`:294-296](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)),
            // so the log's `heads` **is** the view being left behind, and
            // `PatchDoc.clockAt` answers with the clock the caller built for
            // exactly those heads. Handing this view a **null** clock instead
            // resolves every path against `Clock.initEmpty`, which is how a
            // patch about a list ends up naming the element after the one the
            // reference names.
            var view = PatchDoc.init(gpa, self, before_clock);
            defer view.deinit();
            try self.patch_log.finishCurrentView(PatchDoc, &view, before);
        }
        // **The view is built over `after_clock`**, so the events the walk
        // records resolve their paths against the view being entered — the
        // same thing [`Document.diffObj`] does (`doc.zig`:4583).
        var view = PatchDoc.init(gpa, self, after_clock);
        defer view.deinit();
        const handle = view.handle();
        const typ = try self.objectType(.root);
        var iter = try iterdoc.DiffIter(ChangeOp).init(
            gpa,
            &handle,
            .root,
            typ,
            .{ .diff = .{ .before = before_clock, .after = after_clock } },
            true,
        );
        defer iter.deinit();
        // Upstream drops the returned map (`autocommit.rs:822`).
        // Here it owns an allocation, so dispose it with the walk's allocator.
        var paths = try iter.log(&self.patch_log);
        defer paths.deinit(gpa);
    }

    /// Scopes the next transaction to `heads`
    /// ([`AutoCommit::isolate`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):433-437).
    ///
    /// **The transition comes first and the state second**, which is upstream's
    /// order (`:435` before `:436`): `patch_to` reads the isolation to learn
    /// where the document is now, so it has to run while the old one is still
    /// in place.
    ///
    /// **The other half of the effect is at the next transaction *open*, not
    /// at the next commit**, and that is a fact a caller has to know.
    /// [`Document.transactionArgs`] is where the stored heads turn into the
    /// next change's **dependencies**, its **scope** and its **actor** — the
    /// last of those through [`Document.isolatedActorIndex`], which mints a
    /// `withConcurrency` fork of the actor whenever the clock at `heads` does
    /// not cover what that actor has already written
    /// ([`automerge.rs`:1259-1281](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    /// The separate `AutoCommit` opens its held transaction at these isolation
    /// heads (`autocommit.rs:445-457`). Raw `Transaction.open` is unscoped;
    /// `Transaction.openAt` uses its explicit heads (`automerge.rs:476-509`).
    /// Raw commit never advances the facade isolation.
    pub fn isolate(self: *Document, gpa: Allocator, heads: []const ChangeHash) DiffError!void {
        // Prepare the owned head slice before patch publication. A refused copy
        // must not advance the log/cursor while leaving the old isolation in place.
        const next = try self.gpa.dupe(ChangeHash, heads);
        errdefer self.gpa.free(next);
        try self.patchTo(gpa, heads);
        self.installIsolationOwned(next);
    }

    /// Consumes heads allocated by this document's allocator without allocating.
    /// Used after the facade has preflighted an isolated commit's new heads.
    pub fn installIsolationOwned(self: *Document, heads: []ChangeHash) void {
        if (self.isolation) |old| self.gpa.free(old);
        self.isolation = heads;
        self.invalidateHistoricalScopes();
    }

    /// Undoes [`Document.isolate`]
    /// ([`AutoCommit::integrate`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):439-443).
    ///
    /// **Fallible, where it was not.** Upstream's `integrate` returns `()`
    /// because upstream's `PatchLog` reports failure by panicking:
    /// `finish_current_view` carries `.expect("AutoCommit's patch log always
    /// belongs to its document")` ([`patch_log.rs`:293](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs))
    /// on the one operation in it that can fail, and Rust's `Vec`s cannot
    /// refuse an allocation. **The reference is therefore not total here, and
    /// making this total would be a divergence rather than a fix** — so the
    /// error is reported instead of absorbed.
    ///
    /// **There is no place to swallow it.** The alternative — catching a
    /// refusal here and carrying on — leaves `patch_log` short of a view's
    /// events with nothing to say so, and the next
    /// [`Document.diffIncremental`] answers with a stream that is silently
    /// missing a transition. That is the defect this method exists to fix.
    pub fn integrate(self: *Document) DiffError!void {
        try self.patchTo(self.gpa, self.graph.getHeads());
        self.dropIsolation();
    }

    /// Clears the isolation **without replaying a view transition**
    /// ([`dropIsolation`](../../github-automerge-automerge/rust/autocommit.rs):735-736).
    ///
    /// **Upstream runs this line on both ends of a commit** —
    /// `AutoCommit::ensure_transaction_closed` (`:464-466`) and
    /// `AutoCommit::commit_with` (`:735-736`) — and on neither is it a view
    /// transition: it is `self.isolation = hash.map(|h| vec![h])`, a field
    /// write beside the commit. It is split out from [`Document.integrate`]
    /// for the same reason upstream keeps the two apart.
    ///
    /// **It is here for [`transaction.commitWith`](../src/transaction.zig)**
    /// (`:582-586`), which parks the document's isolation, puts a
    /// transaction's own scope in place for the duration of a commit and
    /// restores it afterwards. That is a scope swap, not a caller's
    /// isolate/integrate round trip — upstream has no such dance, because
    /// `AutoCommit` scopes a transaction when it opens it rather than
    /// rewinding the document to do it — and routing it through
    /// [`Document.integrate`] would put a spurious transition in the log of
    /// every isolated commit.
    pub fn dropIsolation(self: *Document) void {
        if (self.isolation) |old| self.gpa.free(old);
        self.isolation = null;
    }

    /// Drops the actor at `idx` from the op set, the author table, the change
    /// graph, the author's cache and the document's current actor
    /// ([`Automerge::remove_actor`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):427-432).
    ///
    /// **The fan is all-or-nothing, and the ordering is what makes it so.**
    /// Every step that can fail is armed with an undo for the steps before it,
    /// and the one step with no way back — the rewrite of [`Actor.cached`] —
    /// runs **last**, after both fallible steps have succeeded. The order this
    /// replaces rewrote the cache *first*, so a refusal out of either of them
    /// returned a document whose current actor had been renumbered while the
    /// other three tables stood still. Leaving the rewrite out
    /// altogether is not the fix either — a cached index nobody rewrites is
    /// the silent rename this method's own [`Actor.removeActor`] exists to
    /// prevent.
    ///
    /// **Why the cache is last when upstream has it first.** Upstream's middle
    /// cannot fail. `OpSet::remove_actor` drops the actor and panics if a
    /// column still names it
    /// ([`op_set2/op_set.rs:1419-1429`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)
    /// over [`columns.rs:355-357`](../../github-automerge-automerge/rust/automerge/src/op_set2/columns.rs)),
    /// and `ChangeGraph::remove_actor` `assert!`s on a slot that still holds a
    /// change ([`change_graph.rs:176`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)) —
    /// so upstream reads the actor's bytes out of the table it is about to drop
    /// a slot from and rewrites the cache in the same breath. **This port
    /// refuses both instead of aborting** ([`OpSet.removeActor`](opset/op_set.zig)
    /// "rewrites first, because the port's rewrite *refuses*";
    /// [`ChangeGraph.removeActor`](change_graph.zig)), which gives this
    /// function an exit in the middle that upstream does not have. Hence the
    /// undo per step and the cache last — and hence [`Actor.removeActor`]
    /// taking the dropped actor's bytes as an argument, because by the time it
    /// runs the slot they came from is gone.
    ///
    /// **The graph goes first because its refusal is the reachable one.** An
    /// actor the graph still holds a change for is upstream's `assert!`, and
    /// it is the answer a caller gets for handing over an actor it did not
    /// check — while the op set's refusal (a column that still names the
    /// actor) needs the same actor to own a row, and every row comes from a
    /// change the graph therefore holds, so reaching it means the two tables
    /// already disagree. Putting the graph first reports the disagreement
    /// where it is and leaves the op set's own refusal as the belt to that
    /// braces.
    ///
    /// **What a refusal still leaves: nothing, but for the allocator.** If the
    /// op set runs out of memory between its four column rewrites
    /// ([`OpSet.removeActor`](opset/op_set.zig) rewrites before it drops, so
    /// its refusal is a refusal — but the four rewrites are four separate
    /// allocations) then the op set's columns are half-renumbered while every
    /// table around it is whole. That is inside the op set, it predates this
    /// function, and it is the allocator's failure rather than a decision any
    /// line here makes.
    ///
    /// **An index the table does not have is refused, not trapped.**
    /// `OpSet.removeActor`'s own bound is `ArrayList.orderedRemove`'s `assert`
    /// ([`opset/op_set.zig:1442`](opset/op_set.zig)), so an index past the end
    /// took the process down, and a document that aborts on a read is not one
    /// a caller can recover from. `error.InvalidActorIndex` is the document's
    /// word for it (`error.zig:32-33`) and it is the check that makes reading
    /// `dropped` below safe.
    pub fn removeActor(self: *Document, gpa: Allocator, idx: ActorIdx) Error!void {
        // **Two reads, and both have to happen before the fan runs.** The
        // bound, because the op set's is an assert rather than a check — and
        // because `dropped` reads the slot at all. And the bytes the freed slot
        // names, because the fan drops that slot before [`Actor.removeActor`]
        // gets to look at it.
        const at: usize = idx;
        if (at >= self.ops.actors.items.len) return error.InvalidActorIndex;
        const dropped = self.ops.actors.items[at];

        // Stage all allocation before changing the actor tables. Graph
        // removal is infallible after these checks (`change_graph.rs:169-190`).
        if (at >= self.graph.numActors() or self.graph.seqForActor(idx) != 0)
            return error.InvalidActorIndex;
        if (at >= self.authors.count()) return error.InvalidActorIndex;
        try self.authors.reserveRemap(gpa);
        self.ops.removeActor(idx) catch |e| return opError(e);
        self.graph.removeActor(idx) catch unreachable;
        self.authors.removeAt(gpa, idx) catch unreachable;
        if (idx < self.actor_authors.items.len)
            _ = self.actor_authors.orderedRemove(idx);
        self.actor.removeActor(idx, dropped);
        self.invalidateHistoricalScopes();
    }

    /// Drops every actor the change graph holds no change for
    /// ([`Automerge::remove_unused_actors`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):446-455).
    ///
    /// Upstream loops `while let Some(idx) = self.change_graph.unused_actors().last()`,
    /// removing the **highest** index first so that the renumbering does not
    /// move a lower one, and the renumbering itself belongs entirely to
    /// `remove_actor` (`:427-432`). **The cached actor is not adjusted here**:
    /// it used to be, and doing it in both places decrements twice for a
    /// cached index two or more slots above the one being dropped.
    pub fn removeUnusedActors(self: *Document, gpa: Allocator) Error!void {
        while (self.highestUnusedActor()) |idx| {
            try self.removeActor(gpa, idx);
        }
    }

    /// The highest actor index the graph holds no change for, or null.
    fn highestUnusedActor(self: *const Document) ?ActorIdx {
        var best: ?ActorIdx = null;
        for (self.ops.actors.items, 0..) |_, i| {
            // A sequence number of zero means the graph holds no change for
            // that actor, which is exactly `unused_actors`
            // (`change_graph.rs:151-159`).
            if (self.graph.seqForActor(@intCast(i)) == 0) best = @intCast(i);
        }
        return best;
    }

    // ── Loading ────────────────────────────────────────────────────────────

    /// Loads a new raw document. The encoding is not stored in the file.
    pub fn load(gpa: Allocator, io: std.Io, bytes: []const u8, encoding: TextEncoding) LoadError!Document {
        return loadWithOptions(gpa, io, bytes, .{ .text_encoding = encoding });
    }

    /// Loads with strict framing, column and checksum checks.
    /// Ignore discards every tail change after a partial decode, never allocator failures
    /// (`automerge.rs:974-999`). Migration runs before the supplied author is assigned.
    pub fn loadWithOptions(gpa: Allocator, io: std.Io, bytes: []const u8, options: LoadOptions) LoadError!Document {
        return loadConfigured(gpa, io, bytes, options, .check, null);
    }

    /// Skips only stored-versus-derived head equality, for inspecting damaged metadata.
    /// Preserves the stored head set, including unknown hashes; other checks remain active.
    pub fn loadUnverifiedHeads(gpa: Allocator, io: std.Io, bytes: []const u8, options: LoadOptions) LoadError!Document {
        var unverified = options;
        unverified.verification_mode = .dont_check;
        return loadWithOptions(gpa, io, bytes, unverified);
    }

    /// Best-effort current value rescue. Only MARK order validation is relaxed;
    /// the returned hydration owns its bytes and no original history is returned
    /// (`automerge.rs:897-903`).
    pub fn rescue(gpa: Allocator, io: std.Io, bytes: []const u8) LoadError!@import("hydrate.zig").OwnedValue {
        var rescued = try loadConfigured(gpa, io, bytes, .{}, .allow_invalid, null);
        defer rescued.deinit();
        return .{
            .gpa = gpa,
            .value = try @import("hydrate.zig").hydrateMap(Set, &rescued.ops, gpa, .root, null),
        };
    }

    /// Replaces this owner only after all loading work succeeds.
    pub fn loadInto(self: *Document, gpa: Allocator, bytes: []const u8, encoding: TextEncoding) LoadError!void {
        return self.loadIntoWithOptions(gpa, bytes, .{ .text_encoding = encoding });
    }

    /// On refusal the existing owner is unchanged. Caller logs are borrowed.
    pub fn loadIntoWithOptions(self: *Document, gpa: Allocator, bytes: []const u8, options: LoadOptions) LoadError!void {
        var fresh = try loadConfigured(gpa, self.io, bytes, options, .check, self.patch_identity);
        errdefer fresh.deinit();
        if (options.patch_log) |log| {
            if (log == &self.patch_log) {
                std.mem.swap(patchesmod.PatchLog, &fresh.patch_log, &self.patch_log);
            }
        }
        self.deinit();
        self.* = fresh;
    }

    /// Checks actor compatibility without allocating, binding or modifying the sink.
    /// Incoming routes instead check the projected table before interning new actors.
    pub fn validatePatchLog(self: *const Document, log: *const patchesmod.PatchLog) Error!void {
        try log.validateActors(self.ops.actors.items);
    }

    fn logCurrentState(
        self: *Document,
        gpa: Allocator,
        log: *patchesmod.PatchLog,
    ) LoadError!void {
        if (!log.isActive()) return;
        var staged = try log.beginBatch();
        defer staged.deinit();
        // Current-state logging intentionally bypasses actor migration, as Rust's
        // automerge.rs:1077-1079 / iter/doc.rs:79-91 does. Only metadata is rebound.
        staged.identity = self.patch_identity;
        var view = PatchDoc.init(gpa, self, null);
        defer view.deinit();
        const handle = view.handle();
        var iter = try iterdoc.DiffIter(ChangeOp).init(
            staged.gpa,
            &handle,
            .root,
            .map,
            .now(),
            true,
        );
        defer iter.deinit();
        staged.pathHint(try iter.log(&staged));
        try staged.preparePublish(log);
        // Ordinary batch publication invalidates path hints. A snapshot instead
        // preserves the paths it just walked (automerge.rs:1078-1079,
        // patch_log.rs:667-670): another rendering owner need not contain these
        // objects. Move their owned storage only after every allocation succeeds.
        const path_map = staged.path_map;
        const path_storage = staged.path_storage;
        staged.path_map = .{};
        staged.path_storage = .init(staged.gpa);
        staged.publish(log);
        log.path_storage.deinit();
        log.path_map = path_map;
        log.path_storage = path_storage;
        log.path_hint = log.events.items.len;
    }

    // Loader-only migration: refusal discards the entire fresh document owner.
    // Enumerate every visible string, including conflicts, before changing any row
    // (`automerge.rs:1973-2023`). Text and table objects are deliberately excluded.
    fn convertScalarStringsToText(self: *Document, gpa: Allocator) LoadError!void {
        const Conversion = struct {
            obj: ExId,
            prop: types.Prop,
            text: []u8,
            op: OpId,
            sequence: bool,
        };
        var conversions: std.ArrayList(Conversion) = .empty;
        defer {
            for (conversions.items) |conversion| gpa.free(conversion.text);
            conversions.deinit(gpa);
        }
        var rows = try self.ops.iter();
        while (try rows.next()) |op| {
            if (!op.visible() or op.action() != .set) continue;
            const scalar_text = switch (op.value()) {
                .str => |bytes| bytes,
                else => continue,
            };
            const typ = try self.objectType(op.objId());
            if (typ != .map and typ != .list) continue;
            const obj = if (op.objId() == .root)
                ExId.root
            else
                self.idToExid(op.objId().opId().?);
            const prop: types.Prop = switch (op.key()) {
                .map => |key| .{ .key = key },
                .seq => .{ .index = 0 },
            };
            const copied = try gpa.dupe(u8, scalar_text);
            conversions.append(gpa, .{
                .obj = obj,
                .prop = prop,
                .text = copied,
                .op = op.id(),
                .sequence = typ == .list,
            }) catch |failure| {
                gpa.free(copied);
                return failure;
            };
        }
        for (conversions.items) |*conversion| {
            if (conversion.sequence) {
                const found = (try self.ops.seekListOpid(
                    self.resolve(conversion.obj) orelse return error.InvalidObjId,
                    conversion.op,
                    .list,
                    null,
                )) orelse return error.InvalidOp;
                conversion.prop = .{ .index = found.index };
            }
        }
        if (conversions.items.len == 0) return;
        var tx = try @import("transact.zig").Transaction.open(gpa, self);
        // No borrowed transaction escapes this private fresh-owner loader path.
        // Resource-only cleanup is safe because loadConfigured destroys all rows
        // on every refusal, rather than retaining a partially migrated document.
        defer tx.deinitClosed();
        for (conversions.items) |conversion| {
            const text_object = tx.putObject(conversion.obj, conversion.prop, .text) catch |failure| {
                return switch (failure) {
                    error.ChangeType => error.InvalidValueType,
                    else => failure,
                };
            };
            tx.spliceText(text_object, 0, 0, conversion.text) catch |failure| {
                return switch (failure) {
                    error.ChangeType => error.InvalidValueType,
                    else => failure,
                };
            };
        }
        var committed = tx.commit() catch |failure| {
            return switch (failure) {
                error.ChangeType => error.InvalidValueType,
                else => failure,
            };
        };
        defer committed.deinit(gpa);
    }

    fn loadConfigured(
        gpa: Allocator,
        io: std.Io,
        bytes: []const u8,
        options: LoadOptions,
        mark_validation: opsetmod.MarkOrderValidation,
        identity: ?u64,
    ) LoadError!Document {
        var loaded = try initWithEncoding(gpa, io, options.text_encoding);
        errdefer loaded.deinit();
        if (identity) |owner| loaded.patch_identity = owner;
        try loaded.loadIntoWith(gpa, bytes, options, mark_validation);
        if (bytes.len != 0 and options.string_migration == .convert_to_text) {
            try loaded.convertScalarStringsToText(gpa);
        }
        // Prepare the author before publishing into a borrowed log: allocator
        // refusal must not leave logged state for a document that was discarded.
        if (options.author) |author| try loaded.setAuthor(gpa, author);
        if (bytes.len != 0) {
            if (options.patch_log) |log| try loaded.logCurrentState(gpa, log);
        }
        return loaded;
    }

    fn loadIntoWith(
        self: *Document,
        gpa: Allocator,
        bytes: []const u8,
        options: LoadOptions,
        mark_validation: opsetmod.MarkOrderValidation,
    ) LoadError!void {
        if (bytes.len == 0) return;
        var stream = chunkmod.ChunkStream.init(bytes);
        // The first chunk is strict under both policies (`automerge.rs:916-967`).
        const first = (try stream.next()) orelse return error.UnexpectedEnd;
        const snapshot = first.typ == .document;
        var changes: Changes = .{};
        defer changes.deinit(gpa);
        if (snapshot) {
            try self.reconstruct(gpa, first, options.text_encoding, options.verification_mode, mark_validation);
        } else {
            try self.decodeChunkChanges(gpa, first, &changes, mark_validation);
        }
        while (true) {
            const next = stream.next() catch |failure| {
                if (options.on_partial_load == .ignore) return;
                return failure;
            };
            const chunk = next orelse break;
            self.decodeChunkChanges(gpa, chunk, &changes, mark_validation) catch |failure| {
                if (failure == error.OutOfMemory) return error.OutOfMemory;
                if (options.on_partial_load == .ignore) return;
                return failure;
            };
        }
        // No tail change is applied until every tail chunk decoded successfully.
        if (changes.len() != 0) {
            const incoming = try asChanges(gpa, changes.slice());
            defer gpa.free(incoming);
            _ = try self.applyChanges(gpa, incoming);
        }
        if (options.on_partial_load == .refuse and !snapshot and !self.queue.isEmpty()) {
            return error.MissingDeps;
        }
    }

    fn decodeChunkChanges(
        self: *Document,
        gpa: Allocator,
        chunk: chunkmod.Chunk,
        out: *Changes,
        mark_validation: opsetmod.MarkOrderValidation,
    ) LoadError!void {
        var decoded: Changes = .{};
        defer decoded.deinit(gpa);
        switch (chunk.typ) {
            .document => {
                var parsed = try docchunk.parseDocumentChunk(chunk.data, gpa);
                defer parsed.deinit(gpa);
                var all_present = true;
                for (parsed.heads()) |head| {
                    if (!self.graph.hasChange(head)) all_present = false;
                }
                if (all_present) return;
                var read = try self.readDocChunk(gpa, &parsed, self.textEncoding(), mark_validation);
                defer read.deinit(gpa);
                decoded = read.changes;
                read.changes = .{};
            },
            .change, .compressed => decoded = try parseOneChange(gpa, chunk),
            .bundle => {
                var stored = try bundlem.parseFramedChunk(chunk, gpa);
                defer stored.deinit(gpa);
                try collectBundleChanges(gpa, &stored, &decoded);
            },
        }
        // Header parsing alone cannot classify a partial operation-column decode.
        for (decoded.slice()) |built| {
            const actor_count = built.change.other_actors.len + 1;
            const actors = try gpa.alloc(ActorIdx, actor_count);
            defer gpa.free(actors);
            for (actors, 0..) |*actor, index| actor.* = std.math.cast(ActorIdx, index) orelse return error.TooLarge;
            const ops = try decodeChangeOps(gpa, built.change, actors);
            defer freeChangeOps(gpa, ops);
        }
        try out.items.appendSlice(gpa, decoded.items.items);
        decoded.items.clearRetainingCapacity();
    }

    /// Seeds `authors`, the change graph's per-actor columns and the author's
    /// cache from the actor table the op set holds, so every stored
    /// `ActorIdx` means the same actor in all of them
    /// ([`Document.insertActor`](src/doc.zig)'s other half; the citations for
    /// why this is a separate step are on its caller).
    ///
    /// **One pass, in table order, and no actor is inserted twice.** The
    /// adopted table is sorted, and slot `i` is appended to all three mirrors
    /// as the loop reaches it, so `Authors.insertAt`, `ChangeGraph.insertActor`
    /// and the author's cache always take the end — which is what makes the
    /// `remap` this writes agree with `ops.actors` rather than with a partial
    /// view of it. Upstream writes the two sizes in one expression instead
    /// (`seq_index: vec![vec![]; num_actors]`, `change_graph.rs:102`, and
    /// `vec![None; actors]`, `author.rs:46-52`) because it has no loop to
    /// write: a `Vec` of empties is the same table this loop builds one entry
    /// at a time.
    ///
    /// **Every route that can change the shape of the actor table, and what
    /// each one does to the mirrors.** A fix on one route and not the others is
    /// the shape of defect this function exists to close, and the routes are
    /// not the ones a reader would guess: two of the five never mention a
    /// document chunk at all.
    ///
    /// | route | how the table changes | mirrors |
    /// | --- | --- | --- |
    /// | [`Document.load`], [`Document.loadInto`], [`Document.clone`], [`Document.fork`], [`Document.forkAt`], [`Document.loadIncremental`] on an empty document, [`Document.loadIntoWith`]'s document-chunk arm | a document chunk is adopted **whole** — `self.ops = read.ops` in [`Document.reconstruct`] — so the table arrives already holding actors no change in the chunk names | **this function**, called before any change is linked |
    /// | [`Document.loadIncremental`] again, on a document chunk it does **not** install | the chunk's table is read for its changes and released with the rest of `read` (`read.installed` is left false, so `read.deinit` frees that op set); the live document's own table grows per change instead | [`Document.applyChanges`]'s `putActorRef`, once per change actor and once per `other_actors` entry |
    /// | every change-chunk arm of both loaders, [`Document.merge`], [`Document.applyChanges`] itself, and every commit that opens its transaction | one actor interned at a time | [`Document.putActorRef`] → [`Document.insertActor`], the fan — and `applyChanges` interns **before** the screen runs, so [`batchmod.BatchApply.insertNewActors`]'s own insertion into the op set finds every actor already there |
    /// | [`Document.removeActor`], and [`Document.removeUnusedActors`] through it | a slot dropped | the same fan, read backwards |
    ///
    /// **So there is exactly one caller of this function** —
    /// [`Document.reconstruct`], from one call site in
    /// [`Document.loadIntoWith`] — and every other route either comes through
    /// it or comes through the fan. The route that reads most like an omission
    /// is the incremental document chunk, and it is not one: it adopts no table
    /// at all, so an actor its chunk named and its changes did not is dropped
    /// from `ops.actors` and from the mirrors together. That is upstream's
    /// answer as well — `load::load_changes` hands a document chunk to
    /// `reconstruct_changes` and applies the changes it yields
    /// (`storage/load.rs:113-120`), so the actors nothing names never reach
    /// the live table there either.
    ///
    /// **What this leaves open, and it is the allocator's.** A refusal from
    /// `try` inside the loop leaves a document whose `ops.actors` is the
    /// adopted table and whose mirrors are the entries the loop reached — the
    /// same half-adopted state this function exists to prevent, reachable only
    /// when an allocation fails (the only other refusal is the `cast` on a
    /// table longer than an `ActorIdx` can index). Closing it means building
    /// the three mirrors in locals and moving them in on success, which is a
    /// rewrite of ownership this function does not do — and
    /// [`Document.insertActor`] has the same window, answering it the way this
    /// file already answers a half-applied fan: an `errdefer` per step, holding
    /// the undo for the steps before it.
    fn adoptActorMirrors(self: *Document, gpa: Allocator) LoadError!void {
        for (self.ops.actors.items, 0..) |actor, i| {
            const idx = std.math.cast(ActorIdx, i) orelse return error.InvalidIndex;
            try self.authors.insertAt(gpa, idx, .{ .bytes = actor.bytes });
            try self.graph.insertActor(gpa, idx);
            try self.actor_authors.insert(gpa, idx, null);
        }
    }

    /// Rebuilds a document from a document chunk
    /// ([`storage::Document::reconstruct`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs):324-363).
    ///
    /// **The order is upstream's and each step depends on the last.** The op set
    /// and the change block are read first; the collector then walks the op rows
    /// and encodes one change per change-block row, which is where the hashes
    /// come from; the heads the chunk recorded are checked against the heads
    /// those changes imply; and only then is the graph linked, because a graph
    /// node's hash is its change's.
    ///
    /// The head check is what makes
    /// `test/fixtures/incorrect_max_op.automerge` a load error rather than a
    /// document whose `max_op` disagrees with its history
    /// ([`verify_changes`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs):306-322)).
    fn reconstruct(
        self: *Document,
        gpa: Allocator,
        c: chunkmod.Chunk,
        encoding: TextEncoding,
        verification: VerificationMode,
        mark_validation: opsetmod.MarkOrderValidation,
    ) LoadError!void {
        var parsed = try docchunk.parseDocumentChunk(c.data, gpa);
        defer parsed.deinit(gpa);
        var read = try self.readDocChunk(gpa, &parsed, encoding, mark_validation);
        defer read.deinit(gpa);
        const derived = try derivedHeads(gpa, &read.changes);
        defer gpa.free(derived);
        // **The head check is upstream's `verify_changes`**
        // ([`storage/document.rs:306-322`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
        // and it is what makes `test/fixtures/incorrect_max_op.automerge` a load
        // error rather than a document whose `max_op` disagrees with its
        // history. `headIndexes` are not consulted: the heads are names here, and
        // the indexes are the document's cache of where each sits in the graph.
        if (verification == .check and !parsed.headsAreCurrent(derived)) return error.MissingHash;

        self.ops.deinit();
        self.ops = read.ops;
        read.installed = true;

        // **Both actor mirrors are sized from the adopted table, before any
        // change is linked.** `ops.actors` is authoritative and it is adopted
        // whole here, so the actor column can name an actor **no change in the
        // chunk names** — anything the table held when the document was saved
        // that was later rolled back, or an actor a caller interned and never
        // committed ([`Document.saveChunk`](src/doc.zig) writes
        // `self.ops.actors.items` in full). Leaving the mirrors
        // to be grown by [`ChangeGraph.addChange`](change_graph.zig)'s own
        // interning would leave `authors` and the graph's `seq_index` **short**,
        // and the first later [`Document.putActorRef`] that inserts above the
        // gap would renumber through a table that is not the authoritative
        // one: `applyActorInsert` rewrites every node's actor through
        // `authors.remap()`, which renumbers an actor that did not move.
        // Upstream has no such route — `ChangeGraph::new` sizes `seq_index`
        // from the actor count (`seq_index: vec![vec![]; num_actors]`,
        // `change_graph.rs:102`, called with `doc.actors().len()` at
        // [`change_graph.rs:929`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
        // and `Authors::with_actors` sizes `actor_to_author` the same way
        // (`author.rs:46-52`); neither is grown from the changes.
        try self.adoptActorMirrors(gpa);

        for (read.changes.items.items, 0..) |*built, i| {
            const node = read.nodes[i];
            const owned_extra = self.arena.allocator().dupe(u8, node.extra) catch return error.OutOfMemory;
            // Reserve the sidecar before publishing history, then append it
            // without a fallible tail. A refusal must not leave an extra
            // sidecar that could shift every later node's footer.
            const staged = try self.stageAuthor(gpa, node.actor, node.extra);
            try self.node_info.ensureUnusedCapacity(gpa, 1);
            try self.graph.addChange(
                gpa,
                &self.authors,
                try .fromChange(gpa, built.change),
            );
            self.node_info.appendAssumeCapacity(.{
                .start_op = read.metas[i].start_op,
                .extra = owned_extra,
            });
            if (staged) |association| self.linkAuthor(association);
            // **The table grows in one place.** The old code appended `null`
            // entries up to `node.actor` here and then overwrote the one at
            // `node.actor`; [`Document.stageAuthor`] grows to the actor
            // table's length itself, which is at least `node.actor + 1`.
        }
        // **And it settles the length for the actors no change named.** The
        // empty actor is one: nothing ever writes a change under it, so on a
        // document whose every change has an author this is the slot that
        // decides whether its answer is `null` or whatever was in the buffer
        // before (`Document.growActorAuthors`).
        try self.growActorAuthors(gpa);
        // Rust's unchecked loader preserves the stored head set, including
        // unknown hashes, rather than substituting the reconstructed graph heads.
        if (verification == .dont_check) {
            try self.graph.installStoredHeads(gpa, parsed.heads());
        }
    }

    /// A document chunk read into op rows and the changes it implies, with no
    /// graph linked and no head check
    /// ([`storage::Document::reconstruct_changes`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs):365-383).
    ///
    /// **The order is upstream's and each step depends on the last.** The op set
    /// and the change block are read first; the collector then walks the op rows
    /// and encodes one change per change-block row, which is where the hashes
    /// come from. A document that has nothing to link yet — an incremental
    /// load — needs exactly this much.
    fn readDocChunk(
        self: *Document,
        gpa: Allocator,
        parsed: *docchunk.Document,
        encoding: TextEncoding,
        mark_validation: opsetmod.MarkOrderValidation,
    ) LoadError!Reconstructed {
        // Ownership is taken in one step at a time and handed to `out`, whose
        // `deinit` is the only thing that frees it: an `errdefer` per step
        // would double-free on any failure after the struct exists.
        const actors = try self.adoptActors(gpa, parsed.actors());
        var ops = Set.loadWithMarkValidation(gpa, parsed.block.ops, actors, encoding, self.strings.table(), mark_validation) catch |e| {
            gpa.free(actors);
            return e;
        };
        // The two `catch` arms below release `ops` and the actors themselves,
        // because both return before `out` exists. From the line after it they
        // do not: `out` owns all four, and its `deinit` is the only release.
        const nodes = decodeGraphCols(gpa, parsed.block.changes, actors.len) catch |e| {
            ops.deinit();
            gpa.free(actors);
            return e;
        };
        const metas = self.buildMetas(gpa, nodes) catch |e| {
            freeGraphNodes(gpa, nodes);
            ops.deinit();
            gpa.free(actors);
            return e;
        };
        var out: Reconstructed = .{ .ops = ops, .actors = actors, .nodes = nodes, .metas = metas };
        // **The one release this function did not have, and the one a refused
        // load needs.** `collectChanges` is the first fallible step after `out`
        // exists, and it is the step that refuses the documents these rows
        // cannot rebuild: `error.Fail` out of `checkCoverage` for a `max_op` the
        // rows do not reach, and out of `place` for two rows claiming one
        // counter ([`VecEncoder::add`, collector.rs:298-301](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs)).
        // `return out` hands the ownership over, so this fires on the failure
        // paths only, and there is nothing to double free: the arms above
        // returned before `out` was built.
        //
        // **What leaked without it, and why the trace named the column
        // loader.** `out.ops` is the whole op set, read by
        // [`Set.load`](opset/op_set.zig) — `OpSet::load`, upstream
        // (`op_set.rs:1200-1205`) — so an abandoned `out` leaked every block
        // that allocated: `Ops.load` → `loadFilled`/`loadInterned` →
        // `hexane.Column.load` → `Slab.splice`. It is not `fromParts`'s release
        // and not the loader's: `fromParts` loads **before** it frees
        // ([op_set.zig:855-857](opset/op_set.zig)) and `Ops.load` has an
        // `errdefer` per column
        // ([columns.zig:783-820](opset/columns.zig)), so both unwind their own.
        // The half-built owner that was being torn down was this one. The actor
        // table, the change block and every change the collector had already
        // encoded went with it, and `std.testing.allocator` reports the lot as a
        // leak and aborts — which hides whatever the next test was going to
        // say, so this is worth more than the rebuild that reaches it.
        errdefer out.deinit(gpa);
        try collectChanges(gpa, &ops, actors, metas, .{ .built = &out.changes }, &out.changes);
        return out;
    }

    /// Copies a document chunk's actor bytes into this document's arena and
    /// returns them as the table the op set will hold.
    ///
    /// **The bytes are copied, never borrowed.** [`opsetmod.OpSet.fromActors`]
    /// takes `[]const ActorId` and stores the values, so a table pointing into
    /// the chunk would dangle the moment the caller freed it.
    fn adoptActors(
        self: *Document,
        gpa: Allocator,
        bytes: []const []const u8,
    ) LoadError![]ActorId {
        const out = try gpa.alloc(ActorId, bytes.len);
        errdefer gpa.free(out);
        for (bytes, 0..) |raw, i| {
            out[i] = .{ .bytes = self.arena.allocator().dupe(u8, raw) catch return error.OutOfMemory };
        }
        return out;
    }

    /// The collector's metadata for every row of a document chunk's change
    /// block.
    ///
    /// **This is where `start_op` comes from**, and it is the one part of the
    /// load that is arithmetic rather than decoding: the change block stores a
    /// change's *last* op counter and not its first, so the op count is
    /// inferred from the dependencies
    /// ([`ChangeGraphCols::load`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):986-1014).
    /// A change with no dependencies has as many ops as its `max_op`, so it
    /// starts at 1; a change with dependencies has as many as its `max_op` less
    /// the largest `max_op` among them, so it starts one past that. A
    /// dependency whose `max_op` is *larger* than this change's is
    /// `error.InvalidHash`: it is the fixture
    /// `test/fixtures/incorrect_max_op.automerge` and upstream's
    /// `LoadError::InvalidMaxOp`.
    fn buildMetas(self: *Document, gpa: Allocator, nodes: []const GraphNode) LoadError![]BuildMeta {
        _ = self;
        const out = try gpa.alloc(BuildMeta, nodes.len);
        errdefer gpa.free(out);
        for (nodes, 0..) |node, i| {
            var last_max_op: u64 = 0;
            for (node.deps) |dep| {
                if (dep >= nodes.len) return error.MissingDeps;
                last_max_op = @max(last_max_op, nodes[dep].max_op);
            }
            if (last_max_op > node.max_op) {
                std.debug.print("doc: change {d} has max_op below one of its dependencies\n", .{i});
                return error.InvalidHash;
            }
            const num_ops = if (node.deps.len == 0)
                node.max_op
            else
                node.max_op - last_max_op;
            out[i] = .{
                .actor = node.actor,
                .seq = node.seq,
                .start_op = node.max_op - num_ops + 1,
                .max_op = node.max_op,
                .time = node.time,
                .message = node.message,
                .deps = node.deps,
                .footer = node.extra,
            };
        }
        return out;
    }

    /// Appends a fully decoded prefix and ignores a malformed tail. Allocation
    /// failures and application failures remain errors (`automerge.rs:1027-1069`).
    pub fn loadIncremental(self: *Document, gpa: Allocator, bytes: []const u8) LoadError!usize {
        return self.loadIncrementalToLog(gpa, bytes, null);
    }

    /// Borrows the log. Nonempty targets preflight the decoded projected actor table;
    /// empty targets log the loaded snapshot directly (`automerge.rs:1038-1051`).
    pub fn loadIncrementalWithPatchLog(self: *Document, gpa: Allocator, bytes: []const u8, log: *patchesmod.PatchLog) LoadError!usize {
        return self.loadIncrementalToLog(gpa, bytes, log);
    }

    fn loadIncrementalToLog(self: *Document, gpa: Allocator, bytes: []const u8, log: ?*patchesmod.PatchLog) LoadError!usize {
        if (self.isEmpty()) {
            // Prepare the actor in the replacement arena before releasing the old
            // owner; failure cannot leave a dangling actor or destroy the old state.
            var fresh = try loadConfigured(gpa, self.io, bytes, .{
                .on_partial_load = .ignore,
                .text_encoding = self.textEncoding(),
            }, .check, self.patch_identity);
            errdefer fresh.deinit();
            const actor_bytes = try fresh.arena.allocator().dupe(u8, self.getActorId().bytes);
            fresh.setActorId(.{ .bytes = actor_bytes });
            const target_log = log orelse &self.patch_log;
            try fresh.logCurrentState(gpa, target_log);
            if (target_log == &self.patch_log) {
                std.mem.swap(patchesmod.PatchLog, &fresh.patch_log, &self.patch_log);
            }
            const added = fresh.ops.len();
            self.deinit();
            self.* = fresh;
            return added;
        }
        var changes: Changes = .{};
        defer changes.deinit(gpa);
        var stream = chunkmod.ChunkStream.init(bytes);
        while (true) {
            const next = stream.next() catch break;
            const chunk = next orelse break;
            self.decodeChunkChanges(gpa, chunk, &changes, .check) catch |failure| {
                if (failure == error.OutOfMemory) return error.OutOfMemory;
                break;
            };
        }
        const start = self.ops.len();
        if (changes.len() != 0 or log != null) {
            const incoming = try asChanges(gpa, changes.slice());
            defer gpa.free(incoming);
            if (log) |borrowed| {
                _ = try self.applyChangesWithPatchLog(gpa, incoming, borrowed);
            } else {
                _ = try self.applyChanges(gpa, incoming);
            }
        }
        return self.ops.len() - start;
    }

    // ── Saving ─────────────────────────────────────────────────────────────

    /// The whole document as one chunk, deflated
    /// ([`Automerge::save`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1169-1171,
    /// over [`save_with_options`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1149-1161).
    ///
    /// **The bytes are not byte-identical to the reference's**, and must not
    /// be: DEFLATE is not reproducible across implementations. Everything
    /// except the DEFLATE stream is byte-exact, and equivalence is checked by
    /// loading the output and comparing the materialized document.
    ///
    /// Changes the document holds but cannot apply — the ones still waiting for
    /// a dependency — are **appended verbatim** when `retain_orphans` is set
    /// ([`automerge.rs:1155-1159`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// because dropping them would make the next `load_incremental` lose them.
    /// Caller owns the returned bytes and frees them with the supplied `gpa`.
    pub fn save(self: *Document, gpa: Allocator) LoadError![]u8 {
        return self.saveWithOptions(gpa, .{ .deflate = true, .retain_orphans = true });
    }

    /// What [`Document.save`] writes, spelled out
    /// ([`SaveOptions`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2329-2334).
    pub const SaveOptions = struct {
        /// Whether a column of at least
        /// [`docchunk.deflate_min_size`](storage/document_chunk.zig) bytes is
        /// deflated.
        deflate: bool = true,
        /// Whether the changes still waiting for a dependency are appended.
        retain_orphans: bool = true,
    };

    /// The whole document, with the options spelled out
    /// ([`save_with_options`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1149-1161,
    /// over [`saveChunk`](Document.saveChunk), which is this file's spelling
    /// of that function).
    ///
    /// **This is [`AutoCommit::save_with_options`], not `Automerge`'s**
    /// ([`autocommit.rs:534-542`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    /// and the difference is the last four lines: the reference's wrapper
    /// takes the same bytes and then **moves the save cursor**
    /// (`if !bytes.is_empty() { self.save_cursor = self.doc.get_heads() }`,
    /// `:538-540`). This port has one `Document` where upstream has
    /// `Automerge` under `AutoCommit`, so the cursor lives here and the two
    /// layers are two functions. A caller that wants the bytes *without* the
    /// side effect — a clone reading its own input, for one — calls
    /// [`Document.saveChunk`].
    /// Caller owns the returned bytes and frees them with the supplied `gpa`.
    pub fn saveWithOptions(
        self: *Document,
        gpa: Allocator,
        options: SaveOptions,
    ) LoadError![]u8 {
        const out = try self.saveChunk(gpa, options);
        errdefer gpa.free(out);
        // **Only a non-empty save moves the cursor** (`:538`). The guard is
        // upstream's, and dropping it would advance the cursor past changes
        // no caller was ever handed.
        if (out.len != 0) try self.setSaveCursor(gpa);
        return out;
    }

    /// The document chunk, and nothing else: what `Automerge::save_with_options`
    /// writes, with no cursor to move
    /// ([`automerge.rs:1149-1161`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    ///
    /// **The public [`Document.saveWithOptions`] is the wrapper, not this.**
    /// [`Document.clone`] is upstream's `#[derive(Clone)]` on `Automerge`
    /// ([`:248`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// which has no save cursor to move — `AutoCommit` is the type that has
    /// one — so a clone that went through the wrapper would silently advance
    /// the *source* document's cursor and make its next
    /// [`Document.saveIncremental`] skip everything the clone just read.
    fn saveChunk(
        self: *Document,
        gpa: Allocator,
        options: SaveOptions,
    ) LoadError![]u8 {
        var ops = try self.ops.exportColumns(gpa);
        defer ops.deinit(gpa);
        var changes = try encodeGraphCols(self, gpa);
        defer changes.deinit(gpa);

        const actors = try gpa.alloc([]const u8, self.ops.actors.items.len);
        defer gpa.free(actors);
        for (self.ops.actors.items, 0..) |actor, i| actors[i] = actor.bytes;

        const heads = self.graph.getHeads();
        const indexes = try gpa.alloc(u64, heads.len);
        defer gpa.free(indexes);
        for (heads, 0..) |head, i| {
            indexes[i] = self.graph.hashToIndex(head) orelse return error.MissingHash;
        }

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try docchunk.writeChunk(
            &bytes,
            gpa,
            docchunk.DocumentBlock.init(
                actors,
                heads,
                changes.cols,
                ops.cols,
                indexes,
            ),
            .fromSaveDeflate(options.deflate),
        );
        if (options.retain_orphans) {
            for (self.queue.slice()) |orphaned| {
                try appendFramed(gpa, &bytes, orphaned);
            }
        }
        return bytes.toOwnedSlice(gpa);
    }

    /// The changes made since `heads`, as concatenated change chunks
    /// ([`Automerge::save_after`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1194-1201).
    ///
    /// This is what [`Document.loadIncremental`] reads, and it is **not** a
    /// document chunk: there is no snapshot, only the changes a peer is missing.
    /// Caller owns the returned bytes and frees them with the supplied `gpa`.
    pub fn saveAfter(self: *Document, gpa: Allocator, heads: []const ChangeHash) LoadError![]u8 {
        var changes = try self.getChanges(gpa, heads);
        defer changes.deinit(gpa);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        for (changes.items.items) |*built| {
            try appendFramed(gpa, &bytes, built.change);
        }
        return bytes.toOwnedSlice(gpa);
    }

    /// The changes made since the last full save
    /// ([`AutoCommit::save_incremental`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs):584-597).
    ///
    /// **The cursor is a set of change hashes, not a byte offset and not a
    /// change index.** Upstream declares it `save_cursor: Vec<ChangeHash>`
    /// (`:70`) and fills it with `self.doc.get_heads()` (`:539`, `:594`) — the
    /// same `Vec<ChangeHash>` [`Automerge::get_heads`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1505-1509
    /// returns — and hands it straight to `save_after(&self.save_cursor)`
    /// (`:592`). So the base is a *set of change hashes*, the collector
    /// excludes everything reachable from it, and **no document framing and no
    /// change index is involved**: the output is a bare list of framed change
    /// chunks, which is what [`Document.loadIncremental`] reads.
    ///
    /// **An empty cursor means "everything"**, because a document that has
    /// never been saved has no base: `ChangeCollector::exclude_hashes` with
    /// nothing to exclude walks from the heads and yields the whole history.
    /// Caller owns the returned bytes and frees them with the supplied `gpa`.
    pub fn saveIncremental(self: *Document, gpa: Allocator) LoadError![]u8 {
        const out = try self.saveAfter(gpa, self.save_cursor.items);
        errdefer gpa.free(out);
        // **And only a non-empty save advances it** (`:593-595`). The guard
        // is load-bearing in the other direction too: advancing on an empty
        // answer would move the cursor over changes the caller never
        // received, and they would never be sent.
        if (out.len != 0) try self.setSaveCursor(gpa);
        return out;
    }

    /// `self.save_cursor = self.doc.get_heads()`
    /// ([`autocommit.rs:539`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `:594`): a **copy** of the document's heads at this moment.
    ///
    /// An owned list and not a borrowed view of the graph's heads, for the
    /// reason [`Document.diff_cursor`] gives: a cursor is the heads *as of
    /// the last save*, and the next change moves them.
    fn setSaveCursor(self: *Document, gpa: Allocator) Allocator.Error!void {
        _ = gpa;
        const heads = self.graph.getHeads();
        try self.save_cursor.ensureTotalCapacity(self.gpa, heads.len);
        self.save_cursor.clearRetainingCapacity();
        self.save_cursor.appendSliceAssumeCapacity(heads);
    }

    // ── Applying changes ───────────────────────────────────────────────────

    /// Applies `incoming` and returns how many changes were applied
    /// ([`Automerge::apply_changes`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1097-1102).
    ///
    /// **Idempotent for a change already applied**, and **refusing for one that
    /// repeats a sequence number or an author**: a second change claiming
    /// `(actor, seq)` is a *different* change, not a repeat, and applying it
    /// would give one actor two changes at one counter
    /// ([`apply_changes_batch_log_patches`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1067-1101).
    /// On any refusal **nothing is applied and the queue is untouched**, which
    /// is upstream's property too: the checks run entirely inside the loop over
    /// `changes`, and `queue.extend` is after it.
    ///
    /// **Every incoming change is copied into this document's arena** before it
    /// is screened. The queue takes ownership of the changes it keeps, and a
    /// queued change is one whose bytes must outlive the caller's buffer —
    /// otherwise the orphan a queue holds would be a dangling pointer the next
    /// `save` would read.
    pub fn applyChanges(self: *Document, gpa: Allocator, incoming: []const Change) LoadError!usize {
        if (self.patch_log.isActive()) {
            return self.applyChangesWithPatchLog(gpa, incoming, &self.patch_log);
        }
        var log: batchmod.NullLog = .{};
        return self.applyChangesToSink(batchmod.NullLog, gpa, incoming, &log, null);
    }

    /// Borrows a compatible log, including this document's own log.
    /// Actor mismatch preserves the entire document and log; other refusals preserve
    /// history, operation rows, author associations and log events. Canonical actor
    /// interning may leave a usable prefix on allocation refusal.
    pub fn applyChangesWithPatchLog(
        self: *Document,
        gpa: Allocator,
        incoming: []const Change,
        log: *patchesmod.PatchLog,
    ) LoadError!usize {
        // Even inactive Rust logs migrate their actor table (batch.rs:870-872).
        return self.applyChangesToSink(patchesmod.PatchLog, gpa, incoming, log, null);
    }

    // Borrow actor bytes from the parsed changes for this call only. No target
    // actor/mirror or log changes before the exact Rust prefix comparison.
    fn validateProjectedPatchLog(
        self: *const Document,
        gpa: Allocator,
        incoming: []const Change,
        log: *const patchesmod.PatchLog,
    ) LoadError!void {
        if (log.actors.items.len == 0) return;
        var has_new_actor = false;
        for (incoming) |change| {
            if (self.ops.lookupActor(change.actor) == null) has_new_actor = true;
            for (change.other_actors) |actor| {
                if (self.ops.lookupActor(actor) == null) has_new_actor = true;
            }
        }
        if (!has_new_actor) return self.validatePatchLog(log);
        var projected: std.ArrayList(ActorId) = .empty;
        defer projected.deinit(gpa);
        try projected.appendSlice(gpa, self.ops.actors.items);
        for (incoming) |change| {
            if (self.ops.lookupActor(change.actor) == null) {
                try projected.append(gpa, change.actor);
            }
            for (change.other_actors) |actor| {
                if (self.ops.lookupActor(actor) == null) try projected.append(gpa, actor);
            }
        }
        const Sort = struct {
            fn lessThan(_: void, a: ActorId, b: ActorId) bool {
                return ActorId.order(a, b) == .lt;
            }
        };
        std.mem.sort(ActorId, projected.items, {}, Sort.lessThan);
        var count: usize = 0;
        for (projected.items) |actor| {
            if (count == 0 or !ActorId.eql(projected.items[count - 1], actor)) {
                projected.items[count] = actor;
                count += 1;
            }
        }
        try log.validateActors(projected.items[0..count]);
    }

    fn applyChangesToSink(
        self: *Document,
        comptime L: type,
        gpa: Allocator,
        incoming: []const Change,
        log: *L,
        output_heads: ?*[]ChangeHash,
    ) LoadError!usize {
        if (L == patchesmod.PatchLog) {
            try self.validateProjectedPatchLog(gpa, incoming, log);
        }
        if (incoming.len == 0) {
            const heads = if (output_heads != null) try self.getHeads(gpa) else null;
            errdefer if (heads) |owned_heads| gpa.free(owned_heads);
            if (L == patchesmod.PatchLog) {
                // Rust runs BatchApply even without changes (batch.rs:1103-1105).
                // bind's actor insertion is failure-atomic; there is no fallible
                // work afterward, and existing path hints stay intact.
                try log.bind(self.patch_identity, self.ops.actors.items);
            }
            if (output_heads) |out| out.* = heads.?;
            return 0;
        }
        const owned = try gpa.alloc(Change, incoming.len);
        defer gpa.free(owned);
        var consumed = false;
        var adopted: usize = 0;
        defer if (!consumed) {
            for (owned[0..adopted]) |*change| change.deinit(gpa);
        };
        for (incoming) |change| {
            owned[adopted] = try self.adoptChange(gpa, change);
            adopted += 1;
        }
        for (owned) |change| {
            if (self.ops.lookupActor(change.actor) == null) {
                _ = try self.putActorRef(gpa, change.actor);
            }
            for (change.other_actors) |actor| {
                if (self.ops.lookupActor(actor) == null) {
                    _ = try self.putActorRef(gpa, actor);
                }
            }
        }

        // Project only queue metadata. Unchanged orphan bodies remain borrowed
        // until nofail publication transfers their original arena owner.
        var queue = try self.queue.prepareProjection(gpa);
        defer queue.deinit(gpa);
        consumed = true;
        var batch = batchmod.applyChangesBatchLogPatches(
            gpa,
            &self.ops,
            &self.graph,
            &queue.view,
            self.authorLookup(),
            owned,
        ) catch |failure| {
            // Upstream batch.rs:1074-1075 deliberately prunes a queued actor's
            // later branch on DuplicateSeqNumber. Other refusals preserve it.
            if (failure == error.DuplicateSeqNumber) {
                queue.publish(&self.queue);
            }
            return failure;
        };
        defer batch.deinit();
        var ops: std.ArrayList(ChangeOp) = .empty;
        defer {
            for (ops.items) |*op| op.deinit(gpa);
            ops.deinit(gpa);
        }
        const metas = try gpa.alloc(changerec.ChangeMetadata, batch.len());
        defer gpa.free(metas);
        const sidecars = try gpa.alloc(NodeInfo, batch.len());
        defer gpa.free(sidecars);
        const associations = try gpa.alloc(?StagedAuthor, batch.len());
        defer gpa.free(associations);
        try self.node_info.ensureUnusedCapacity(gpa, batch.len());
        try self.author_names.ensureUnusedCapacity(gpa, batch.len());
        for (batch.slice(), 0..) |change, index| {
            const decoded = try self.importOps(gpa, change);
            const filled = change.withOpCount(decoded.len) catch |failure| {
                freeChangeOps(gpa, decoded);
                return failure;
            };
            ops.appendSlice(gpa, decoded) catch |failure| {
                freeChangeOps(gpa, decoded);
                return failure;
            };
            gpa.free(decoded);
            metas[index] = try .fromChange(gpa, filled);
            const footer = self.changeFooterOf(filled) orelse &.{};
            sidecars[index] = .{
                .start_op = filled.start_op,
                .extra = try self.arena.allocator().dupe(u8, footer),
            };
            const actor = self.ops.lookupActor(filled.actor) orelse return error.MissingActor;
            associations[index] = try self.stageAuthor(gpa, @intCast(actor), footer);
        }
        const heads = if (output_heads != null)
            try self.projectBatchHeads(gpa, metas)
        else
            null;
        errdefer if (heads) |owned_heads| gpa.free(owned_heads);
        var graph = try self.graph.prepareChanges(gpa, &self.authors, metas);
        defer graph.deinit();
        var staged_log = try log.beginBatch();
        defer staged_log.deinit();
        if (L == patchesmod.PatchLog) {
            try staged_log.bind(self.patch_identity, self.ops.actors.items);
        }
        var prepared: Set.PreparedBatch = undefined;
        try batchmod.prepareChangesBatchToSink(
            L,
            gpa,
            &staged_log,
            &self.ops,
            batch.slice(),
            ops.items,
            &prepared,
        );
        defer prepared.deinit();
        try staged_log.preparePublish(log);

        // No allocation or refusal is permitted after this publication boundary.
        prepared.publish(&self.ops);
        graph.publish(&self.graph);
        self.node_info.appendSliceAssumeCapacity(sidecars);
        for (associations) |association| {
            if (association) |author| self.linkAuthor(author);
        }
        queue.publish(&self.queue);
        staged_log.publish(log);
        self.invalidateHistoricalScopes();
        if (output_heads) |out| out.* = heads.?;
        return batch.len();
    }

    fn projectBatchHeads(
        self: *const Document,
        gpa: Allocator,
        metas: []const changerec.ChangeMetadata,
    ) Allocator.Error![]ChangeHash {
        var heads: std.ArrayList(ChangeHash) = .empty;
        defer heads.deinit(gpa);
        try heads.appendSlice(gpa, self.graph.getHeads());
        for (metas) |meta| {
            for (meta.deps) |dep| {
                for (heads.items, 0..) |head, index| {
                    if (head.eql(dep)) {
                        _ = heads.swapRemove(index);
                        break;
                    }
                }
            }
            try heads.append(gpa, meta.hash);
        }
        const Sort = struct {
            fn lessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
                return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
            }
        };
        std.mem.sort(ChangeHash, heads.items, {}, Sort.lessThan);
        return heads.toOwnedSlice(gpa);
    }

    /// Copies a change into this document's arena and re-parses it, so every
    /// field of the copy points at bytes the document owns.
    ///
    /// **`max_op` is the one field the re-parse does not give back.** The copy
    /// exists because a `Change` borrows its bytes and a change that lives in
    /// this document's graph must borrow bytes the document owns for as long
    /// as it is there; a parse reads only the header, and the header carries
    /// no op count ([`storage/change.rs:104-111`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs)).
    /// Every other field is recovered from those bytes, so this one is carried
    /// across from the change handed in — it was computed by whoever decoded
    /// that change's columns ([`Change.withOpCount`](change.zig)), and it is
    /// the only record of the range this document has not counted for itself
    /// yet. The screen below it reads the actor and the sequence number only
    /// ([`batch.zig:2354-2375`](opset/batch.zig)) and `importOps` numbers the
    /// rows off `start_op`, so nothing downstream changes today; this is the
    /// value being kept rather than a value being fixed.
    fn adoptChange(self: *Document, gpa: Allocator, change: Change) LoadError!Change {
        const body = self.arena.allocator().dupe(u8, change.bytes) catch return error.OutOfMemory;
        var adopted = try changerec.parseChange(body, gpa);
        adopted.max_op = change.max_op;
        return adopted;
    }

    /// Decodes `change` into op-set rows
    /// ([`Automerge::import_ops`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1118-1157).
    ///
    /// Every actor the change names is looked up in the document's table first:
    /// a change-local actor index is a position in the change's own actor list,
    /// and the op set only ever stores document indices
    /// ([change.rs:1119-1122](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
    /// An actor the document does not have is `error.MissingActor`, which is
    /// upstream's `map(&actors)` unwrapping on a missing index.
    fn importOps(self: *Document, gpa: Allocator, change: Change) ParseError![]ChangeOp {
        const names = try gpa.alloc(ActorId, 1 + change.other_actors.len);
        defer gpa.free(names);
        names[0] = change.actor;
        for (change.other_actors, 0..) |other, i| names[i + 1] = other;

        const actors = try gpa.alloc(ActorIdx, names.len);
        defer gpa.free(actors);
        for (names, 0..) |name, i| {
            const idx = self.ops.lookupActor(name) orelse {
                std.debug.print("doc: change names actor {x} the document does not have\n", .{name.bytes});
                return error.MissingActor;
            };
            actors[i] = @intCast(idx);
        }
        return decodeChangeOps(gpa, change, actors);
    }

    /// Every change in `other` this document does not have
    /// ([`Automerge::get_changes_added`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1532-1552).
    ///
    /// The walk starts at `other`'s heads and descends into its dependencies,
    /// stopping wherever **this** graph already holds the change. The result is
    /// the reverse of the depth-first order, which is a dependency order here
    /// because a change only enters a graph after its dependencies.
    pub fn getChangesAdded(
        self: *Document,
        gpa: Allocator,
        other: *Document,
    ) DocumentError!Changes {
        const hashes = try self.graph.getChangesAdded(&other.graph, gpa, other.graph.getHeads());
        defer gpa.free(hashes);
        return other.getChangesByHashes(gpa, hashes);
    }

    /// Takes every change in `other` this document does not have, and returns
    /// the document's heads afterwards
    /// ([`Automerge::merge`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1115-1131).
    ///
    /// The heads are returned rather than nothing because upstream returns them
    /// and a caller that merges for the sync protocol needs them.
    /// Caller owns the returned heads and frees the array with `gpa`.
    pub fn merge(
        self: *Document,
        gpa: Allocator,
        other: *Document,
    ) DocumentError![]ChangeHash {
        return self.mergeToLog(gpa, other, null);
    }

    /// Borrows a compatible patch log and preflights the returned head array.
    pub fn mergeWithPatchLog(
        self: *Document,
        gpa: Allocator,
        other: *Document,
        log: *patchesmod.PatchLog,
    ) DocumentError![]ChangeHash {
        return self.mergeToLog(gpa, other, log);
    }

    fn mergeToLog(
        self: *Document,
        gpa: Allocator,
        other: *Document,
        external: ?*patchesmod.PatchLog,
    ) DocumentError![]ChangeHash {
        var changes = try self.getChangesAdded(gpa, other);
        defer changes.deinit(gpa);
        const incoming = try asChanges(gpa, changes.slice());
        defer gpa.free(incoming);
        var heads: []ChangeHash = undefined;
        const log = external orelse &self.patch_log;
        if (external != null or log.isActive()) {
            _ = try self.applyChangesToSink(
                patchesmod.PatchLog,
                gpa,
                incoming,
                log,
                &heads,
            );
        } else {
            var inactive: batchmod.NullLog = .{};
            _ = try self.applyChangesToSink(
                batchmod.NullLog,
                gpa,
                incoming,
                &inactive,
                &heads,
            );
        }
        return heads;
    }

    // ── Committing ─────────────────────────────────────────────────────────

    /// Commits `ops` as one change and returns its hash.
    ///
    /// Upstream has no `Automerge::commit`: the commit belongs to
    /// `TransactionInner::commit_impl`
    /// ([`inner.rs:146-172`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
    /// which exports the pending ops into a change and hands it to
    /// `update_history`. **This is the second half of that**, with the ops
    /// supplied by the transaction slice: a local commit is a change with a
    /// hash, and the hash is SHA-256 over the bytes
    /// [`encodeOneChange`] produced, so the encoder is a compatibility boundary
    /// and nothing in it may move.
    ///
    /// **`args` are the transaction's, and they are given rather than derived.**
    /// Upstream builds them **once per transaction**, inside
    /// [`AutoCommit::ensure_transaction_open`]
    /// ([`autocommit.rs`:445-457](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
    /// `let args = self.doc.transaction_args(self.isolation.as_deref());`
    /// opens the [`TransactionInner`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):49-65
    /// that holds them, and `commit_impl` reads that same struct
    /// (`:146-172`) — the document never re-derives them, because the actor
    /// index in them is **the one every op of the transaction was already
    /// written against** by `TransactionInner::next_id` (`:295-297`).
    ///
    /// **Re-deriving them here is what broke the isolate round trip, and it is
    /// worth writing down because the symptom was three missing patches and
    /// the cause was a document that lied about itself.**
    /// [`transactionArgs`] calls [`Document.isolatedActorIndex`], which mints
    /// a `withConcurrency` fork of the actor
    /// ([`types.rs:78-85`](../../github-automerge-automerge/rust/automerge/src/types.rs))
    /// and interns it ([`automerge.rs`:1301-1307](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// and interning **renumbers every actor index above the slot**
    /// ([`automerge.rs`:428](../../github-automerge-automerge/rust/automerge/src/automerge.rs) fans the insertion out to
    /// `ops`, `change_graph`, `actor` and `authors`). Re-deriving at commit
    /// time does that **after the transaction's rows are already in the op
    /// set**, so the rows were left carrying the actor they were written with
    /// while the change's header named the fork — `ChangeGraph.clockAt` reads
    /// the header, so a clock-filtered read saw the fork's `max_op` in the
    /// fork's slot and the document's own rows in another, and
    /// [`Document.patchTo`]'s walk found nothing where the isolated branch was.
    /// Measured: the oracle's `text-isolate-incremental` answers `patch_count:
    /// 7` in all four encodings and the port answered 5, and every one of the
    /// missing patches mentioned `color` — the object written under the
    /// isolation.
    ///
    /// **`deps` is borrowed, not taken.** The caller keeps ownership, so
    /// [`Document.emptyCommit`] can build a [`TransactionArgs`] with
    /// `deinit` armed and still hand it here. `scope` and `author` are not
    /// read: `scope` is the transaction's private read clock, and `author` is a
    /// function of `seq` alone
    /// ([`automerge.rs`:568](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// which is why it is derived below rather than carried across.
    /// Refusal publishes no history node, author association, local patch
    /// batch, or isolation advance. Pending operation rows remain the
    /// transaction's responsibility. Arena scratch may be retained until
    /// document disposal; graph and output capacities may grow.
    pub fn commit(
        self: *Document,
        gpa: Allocator,
        args: TransactionArgs,
        ops: []const ChangeOp,
        message: ?[]const u8,
        time: ?i64,
    ) LoadError!ChangeHash {
        if (args.start_op == 0 or args.start_op > std.math.maxInt(u32)) return error.Overflow;
        // `automerge.rs:568` — one actor has one author, and it rides that
        // actor's *first* change and no other.
        const author: ?[]const u8 = if (args.seq == 1) self.author else null;

        var footer: std.ArrayList(u8) = .empty;
        defer footer.deinit(gpa);
        try encodeAuthorFooter(gpa, &footer, author);

        var built = try encodeOneChange(gpa, self.ops.actors.items, .{
            .actor = args.actor_index,
            .seq = args.seq,
            .start_op = args.start_op,
            .max_op = if (ops.len == 0) args.start_op -| 1 else args.start_op + ops.len - 1,
            .time = time orelse 0,
            .message = message orelse &.{},
            .deps = args.deps,
            .footer = footer.items,
        }, ops);
        defer built.deinit(gpa);

        // **The ops are rows before this runs, and this does not write them.**
        // Upstream's `commit_impl` is `TransactionInner::export(doc.ops(), …)`
        // followed by `doc.update_history(&change)`
        // ([`inner.rs:157-170`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)):
        // by then the transaction's ops are *already rows*, because
        // `insert_local_op` wrote each one as the transaction went
        // ([`inner.rs:308-328`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
        // which is why `export` takes `doc.ops()` and not a list of ops. So
        // the caller writes them — a `splice` onto the end of `self.ops` — and
        // this encodes the change and links it.
        //
        // **A document that has only been committed holds hashes and no rows**,
        // and that is a state upstream cannot reach. Every reader that rebuilds
        // a change from the op set ([`Document.getChangeByHash`],
        // [`Document.getChanges`], and [`Document.save`] through them) then
        // answers `error.Fail` from [`checkCoverage`], not with wrong bytes —
        // the check is there precisely because a hash with nothing behind it is
        // a document nobody can answer a peer from.

        // **The change carries its own op count before the graph sees it.**
        // `encodeOneChange` re-parses the body it just encoded, and a parse
        // cannot know how many ops the columns hold — `Change.max_op` "is not
        // knowable here and stays 0 until `withOpCount` is called"
        // ([`change.zig:48-52`](change.zig)). `ChangeGraph.addChange` states
        // the requirement in its own words: "`meta.max_op` must be filled in
        // by whoever decoded the change's op columns"
        // ([`change_graph.zig:415-417`](change_graph.zig)). **Without this the
        // graph's `max_op` never advances, `TransactionArgs.start_op =
        // graph.maxOp() + 1` ([`doc.zig:2585`](doc.zig), upstream
        // `automerge.rs:566-567`) mints counter 1 again on every commit, and
        // every local operation after the first lands on an id that is already
        // taken** — which `OpSet.validateOpOrder` answers `false` to, from
        // the second local write on.
        //
        // **Two readers make the field load-bearing, and the second is the
        // quiet one.** The loud one is the paragraph above: op-id allocation,
        // where a zero shows up as a counter that is already taken. The quiet
        // one is a **diff's clock** — `ChangeGraph.clockAt` turns a sequence
        // clock into an op-counter clock through `maxOpAtSeq`
        // ([`change_graph.zig:494-500`](change_graph.zig)), which reads
        // `meta.max_op` off the node. A change recorded with `max_op = 0`
        // therefore also scopes the `after` clock of `Document.diff` and
        // [`Document.diffIncremental`] short and **under-reports**, with no id
        // collision to announce it. Neither symptom points at the other.
        //
        // **`encodeOneChange` now fills the field itself, so the call below is
        // a no-op that agrees with it** — `start_op + ops.len - 1` on both
        // sides, by construction, because both count the same `ops` list. It
        // stays anyway: it is idempotent, and it keeps a field the change graph
        // requires set by a call in the function that hands the change over
        // rather than by the encoder's internals. Deleting it would make the
        // local-commit path's correctness rest on a field `encodeOneChange`
        // happens to fill today.
        //
        // Upstream sets the same field on the same path:
        // `TransactionInner::change_meta` computes
        // `max_op: self.start_op.get() + self.pending.len() as u64 - 1`
        // ([`inner.rs:174-189`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
        // on the `Change` it hands `update_history`. The apply path already
        // did this — `const filled = c.withOpCount(decoded.len)` at
        // [`doc.zig:3269`](doc.zig) — so it is the local-commit path that
        // skipped it. `withOpCount` handles the empty change as
        // `max_op = start_op - 1`, which is the merge commit
        // ([`automerge.rs:693-697`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        // **Staged above the two fallible steps and written below them.** The
        // order matters in both directions here and only this one has no bad
        // case: an association written before them survives their refusal as a
        // name in the set for a change this commit never linked, and one
        // written after them cannot be recorded at all, because `addChange`
        // has already put the change in the graph at `seq == 1` and no later
        // change from that actor ever stamps a footer — so the caller is told
        // the commit failed and left a document whose author it can no longer
        // learn. See [`Document.StagedAuthor`].
        const staged = try self.stageAuthor(gpa, args.actor_index, footer.items);
        const counted = try built.change.withOpCount(ops.len);
        try self.node_info.ensureUnusedCapacity(gpa, 1);
        const extra = try self.arena.allocator().dupe(u8, footer.items);
        // Last fallible step. All publication below is infallible; a refused
        // commit still has an intact transaction undo path.
        try self.graph.addChange(gpa, &self.authors, try .fromChange(gpa, counted));
        self.node_info.appendAssumeCapacity(.{ .start_op = args.start_op, .extra = extra });
        if (staged) |association| self.linkAuthor(association);
        self.invalidateHistoricalScopes();
        return built.change.hash;
    }

    /// A change with no operations, and the document's current heads as its
    /// dependencies
    /// ([`Automerge::empty_commit`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):693-697,
    /// over [`TransactionInner::empty`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs):94-101).
    ///
    /// The reason it exists is a merge commit: a change that has all the current
    /// heads as dependencies and adds nothing.
    ///
    /// **It builds its own [`TransactionArgs`], and from `self.isolation`.**
    /// `TransactionInner::empty` is reached through a transaction, and a
    /// transaction's arguments are `transaction_args(self.isolation)`
    /// ([`autocommit.rs`:446-447](../../github-automerge-automerge/rust/automerge/src/autocommit.rs));
    /// an empty change made under an isolation is scoped and forked exactly as
    /// an op-carrying one is. `deps` is owned here and `deinit` is armed before
    /// the call, which is safe because [`Document.commit`] borrows it.
    pub fn emptyCommit(
        self: *Document,
        gpa: Allocator,
        message: ?[]const u8,
        time: ?i64,
    ) LoadError!ChangeHash {
        const args = try self.transactionArgs(gpa, self.isolation);
        defer args.deinit(gpa);
        return self.commit(gpa, args, &.{}, message, time);
    }

    // ── Heads and changes ──────────────────────────────────────────────────

    /// The document's current heads, sorted ascending by hash
    /// ([`Automerge::get_heads`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1506-1510).
    ///
    /// Upstream keeps a separate `deps: HashSet<ChangeHash>` and sorts a copy
    /// of it on every call; the change graph already maintains exactly that set
    /// (`change_graph.rs:126-128`), so this is a sorted copy of the graph's own
    /// head list rather than a second source of truth.
    /// Caller owns the copied array and frees it with `gpa`.
    pub fn getHeads(self: *const Document, gpa: Allocator) Error![]ChangeHash {
        const heads = self.graph.getHeads();
        const out = try gpa.alloc(ChangeHash, heads.len);
        errdefer gpa.free(out);
        @memcpy(out, heads);
        std.mem.sort(ChangeHash, out, {}, ChangeHash.lessThan);
        return out;
    }

    /// Whether the document holds the change with this hash
    /// ([`Automerge::has_change`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2031-2033).
    pub fn hasChange(self: *const Document, hash: ChangeHash) bool {
        return self.graph.hasChange(hash);
    }

    /// The changes of `heads` this document does not have
    /// ([`ReadDoc::get_missing_deps`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2289-2292,
    /// over [`missing_deps_from`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2037-2066).
    ///
    /// **The queue is chained in front of `heads`**, which is upstream's whole
    /// line: a change that arrived early is not missing, it is waiting, and the
    /// answer a sync peer needs is the first hash on each path back that is
    /// neither applied nor queued. The result is sorted and deduplicated.
    /// Caller owns the returned hashes and frees the array with `gpa`.
    pub fn getMissingDeps(
        self: *const Document,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error![]ChangeHash {
        var start: std.ArrayList(ChangeHash) = .empty;
        defer start.deinit(gpa);
        var pending: std.ArrayList(graphmod.PendingChange) = .empty;
        defer pending.deinit(gpa);
        for (self.queue.slice()) |c| {
            try start.append(gpa, c.hash);
            try pending.append(gpa, .{ .hash = c.hash, .deps = c.deps });
        }
        try start.appendSlice(gpa, heads);
        return self.graph.missingDepsFrom(gpa, start.items, pending.items);
    }

    /// The changes a peer at `have` has not seen, each dependency before the
    /// change that needs it
    /// ([`Automerge::get_changes`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1512-1514).
    ///
    /// **Each change is re-encoded from the op set.** A document chunk stores
    /// the graph's metadata and the op set's rows, not the change chunks, so
    /// producing a change means walking the rows it came from. The caller owns
    /// the result: `Changes.deinit` frees the bodies.
    pub fn getChanges(
        self: *Document,
        gpa: Allocator,
        have: []const ChangeHash,
    ) DocumentError!Changes {
        const hashes = try self.graph.getChanges(gpa, have);
        defer gpa.free(hashes);
        return self.getChangesByHashes(gpa, hashes);
    }

    /// The change with this hash, or null when the document does not hold it
    /// ([`ReadDoc::get_change_by_hash`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2294-2298).
    ///
    /// A hash the graph does not hold is **absent, not an error** — that is
    /// upstream's `Option` — but a change the graph *does* hold and the op set
    /// cannot rebuild is an error, because the alternative is an answer with the
    /// wrong bytes in it.
    /// Null means absent. Otherwise the caller owns `Built`; call `deinit(gpa)`.
    pub fn getChangeByHash(
        self: *Document,
        gpa: Allocator,
        hash: ChangeHash,
    ) DocumentError!?Built {
        if (!self.graph.hasChange(hash)) return null;
        var changes = try self.getChangesByHashes(gpa, &.{hash});
        defer changes.deinit(gpa);
        if (changes.items.items.len != 1) return error.Fail;
        return changes.items.orderedRemove(0);
    }

    /// Metadata for changes not covered by `have`, each dependency before its dependents
    /// (`automerge.rs:1516-1522`, `change/collector.rs:665-690`).
    ///
    /// Unknown hashes are ignored; empty `have` selects all committed changes.
    /// Reads history without mutating the document or rebuilding operation bytes.
    /// The caller owns the result and releases it once with `deinit(gpa)`.
    /// Allocation refusal releases every partial copy and leaves history unchanged.
    pub fn getChangesMeta(
        self: *const Document,
        gpa: Allocator,
        have: []const ChangeHash,
    ) Error!ChangeMetas {
        var result: ChangeMetas = .{};
        errdefer result.deinit(gpa);
        if (have.len == 0) {
            try result.items.ensureTotalCapacity(gpa, self.graph.nodes.items.len);
            for (self.graph.nodes.items, 0..) |_, i| {
                result.items.appendAssumeCapacity(try self.copyChangeMeta(gpa, @intCast(i)));
            }
            return result;
        }

        // Walk the immutable, topologically stored graph into caller scratch.
        // Graph clock helpers stamp/cache the graph, which a const reader must not do.
        const covered = try gpa.alloc(bool, self.graph.nodes.items.len);
        defer gpa.free(covered);
        @memset(covered, false);
        const seqs = try gpa.alloc(u64, self.ops.actors.items.len);
        defer gpa.free(seqs);
        @memset(seqs, 0);
        for (have) |known| {
            if (self.graph.hashToIndex(known)) |index| covered[index] = true;
        }
        var remaining = covered.len;
        while (remaining > 0) {
            remaining -= 1;
            if (!covered[remaining]) continue;
            const node = self.graph.nodes.items[remaining];
            seqs[node.actor] = @max(seqs[node.actor], node.meta.seq);
            for (node.meta.deps) |dep| {
                if (self.graph.hashToIndex(dep)) |index| covered[index] = true;
            }
        }
        for (self.graph.nodes.items, 0..) |node, i| {
            if (node.meta.seq <= seqs[node.actor]) continue;
            try result.items.ensureUnusedCapacity(gpa, 1);
            result.items.appendAssumeCapacity(try self.copyChangeMeta(gpa, @intCast(i)));
        }
        return result;
    }

    /// Owned metadata for `hash`, or `null` when it is not committed in this document
    /// (`automerge.rs:1525-1528`, `change/collector.rs:693-720`).
    ///
    /// No field borrows the document; release a non-null result once with `deinit(gpa)`.
    /// Allocation refusal releases every partial copy and leaves history unchanged.
    pub fn getChangeMetaByHash(
        self: *const Document,
        gpa: Allocator,
        hash: ChangeHash,
    ) Error!?ChangeMetadata {
        const index = self.graph.hashToIndex(hash) orelse return null;
        return try self.copyChangeMeta(gpa, index);
    }

    fn copyChangeMeta(self: *const Document, gpa: Allocator, index: NodeIdx) Allocator.Error!ChangeMetadata {
        const node = self.graph.nodes.items[index];
        const info = self.nodeInfo(index);
        const actor = try gpa.dupe(u8, self.ops.actors.items[node.actor].bytes);
        errdefer gpa.free(actor);
        // Metadata's author comes from the actor mapping, not this change's footer.
        // A later change omits its footer but retains its actor's author (:707).
        const mapped_author = if (node.actor < self.actor_authors.items.len)
            self.actor_authors.items[node.actor]
        else
            null;
        const author = if (mapped_author) |bytes|
            try gpa.dupe(u8, bytes)
        else
            null;
        errdefer if (author) |bytes| gpa.free(bytes);
        const message = if (node.meta.message.len != 0)
            try gpa.dupe(u8, node.meta.message)
        else
            null;
        errdefer if (message) |bytes| gpa.free(bytes);
        const deps = try gpa.dupe(ChangeHash, node.meta.deps);
        errdefer gpa.free(deps);
        const extra = try gpa.dupe(u8, info.extra);
        errdefer gpa.free(extra);
        return .{
            .actor = .{ .bytes = actor },
            .author = author,
            .seq = node.meta.seq,
            .start_op = info.start_op,
            .max_op = node.meta.max_op,
            .timestamp = node.meta.time,
            .message = message,
            .deps = deps,
            .hash = node.meta.hash,
            .extra = extra,
        };
    }

    /// Hash of the committed change containing `id` (`automerge.rs:1554-1567`).
    /// Allocates nothing. Root, unknown actors/counters and pending operations return
    /// `null`; deleting an operation does not erase its originating change.
    /// Compact `ExId` actor indices are document-local. Named ids resolve actor
    /// bytes to repair cached slots after insertion (`automerge.rs:744-758`).
    pub fn hashForOpid(self: *const Document, id: ExId) ?ChangeHash {
        const resolved = self.resolve(id) orelse return null;
        const op = resolved.opId() orelse return null;
        if (op.actor >= self.ops.actors.items.len) return null;
        return self.graph.opidToHash(op);
    }

    // ── Bundles and fragments ─────────────────────────────────────────────

    /// The metadata for one bundle, and the one block every `deps` window in
    /// it points into.
    ///
    /// **The two are one lifetime because they are one piece of state.** A
    /// meta's `deps` is a window into `deps`, so neither may be released
    /// while the other is still being read, and [`Builder.init`]
    /// (storage/bundle.zig) reads every window — resolving each dependency to
    /// a bundle index — after the metadata has come back here. Returning the
    /// two separately is what made that a dangling read.
    const BundleMetas = struct {
        /// One meta per requested hash, in the order they were given.
        items: std.ArrayList(bundlem.BundleMetadata),
        /// Every dependency of every meta, concatenated. Owned here.
        deps: []ChangeHash,

        /// Releases both allocations.
        fn deinit(self: *BundleMetas, gpa: Allocator) void {
            // **The array alone**: every `deps` window is interior to `deps`,
            // so releasing the windows here would be a free of an interior
            // pointer.
            self.items.deinit(gpa);
            gpa.free(self.deps);
            self.* = undefined;
        }
    };

    /// The changes named by `hashes`, encoded as a bundle
    /// ([`Automerge::bundle`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1141-1146,
    /// over [`Bundle::for_hashes`](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs):41-50
    /// and [`Bundle::from_meta`](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs):52-73).
    ///
    /// **A bundle is a second encoding of a *subset* of the history, and the
    /// subset is `hashes` and not the closure of it.** A change the bundle does
    /// not carry becomes an **external dependency**: its hash goes into the
    /// chunk prefix ([`ChangeWriter.add`](storage/bundle.zig), `bundle/builder.rs:274-300`)
    /// and its row is not written. So `bundle(gpa, heads)` of a three-change
    /// history whose head depends on the other two carries **one** change and
    /// names the other two — which is what
    /// [`Document.loadIncremental`] queues until a peer supplies them, and what
    /// upstream's own `bundle(hashes)` does.
    ///
    /// **Only the op rows in the counter range are fed to the writer.**
    /// Upstream walks [`iter_ctr_range`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs):1254-1266,
    /// whose range is `min(start_op)..=max(max_op)` over the selected changes
    /// (`bundle.rs:53-56`), and it visits a row when **the row's own counter is
    /// in the range or one of its successor edges points into it**. That
    /// second half is the load-bearing one: a delete inside the bundle whose
    /// *overwriting* op is outside it still has to be written, or the receiver
    /// resurrects the row. [`bundleRowIsVisited`] is that test.
    ///
    /// **An unknown hash is an error, and an empty list is a bundle with no
    /// changes in it.** Upstream's `get_bundle_metadata`
    /// ([`change_graph.rs`:338-382](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
    /// answers `MissingDep` for a hash the graph does not hold, which
    /// [`Automerge::bundle`] propagates as [`error.MissingDeps`]. An empty list
    /// reaches [`Bundle.from_meta`](storage/bundle.zig) with nothing to write,
    /// and the range is empty, so the result is a bundle that parses, names no
    /// dependency and reconstructs no change. A **repeated** hash is not
    /// deduplicated either: upstream maps over the caller's iterator, so the
    /// same change is written twice and the dependency index a later row
    /// resolves to is the second one ([`ChangeWriter.add`](storage/bundle.zig)
    /// overwrites its `seen` entry). This method does not deduplicate, because
    /// upstream does not and a bundle that quietly lost a row would be a
    /// different document.
    ///
    /// **The bundle is the caller's** and is freed with
    /// [`Bundle.deinit`](storage/bundle.zig); [`Bundle.bytes`] is the on-disk
    /// form.
    ///
    /// **The receiver is taken mutably, and nothing here writes through it.**
    /// The one walk — [`OpSet::iter`](opset/op_set.zig) — takes the op set by
    /// mutable pointer because the walk reads a successor scratch buffer the
    /// set owns ([`op_set.zig:2173-2175`](opset/op_set.zig)), so a `*const`
    /// receiver would have to be copied to be walked. Every other step reads
    /// the graph, which is already reachable from a `*const` receiver
    /// ([`bundleMetas`]).
    pub fn bundle(
        self: *Document,
        gpa: Allocator,
        hashes: []const ChangeHash,
    ) DocumentError!Bundle {
        // **The dependency block outlives the builder**, because every
        // `deps` window is interior to it and `Builder.init` reads them all
        // while it resolves them to bundle indices. The two are therefore
        // released together, after `finish` has copied everything it keeps.
        var metas = try self.bundleMetas(gpa, hashes);
        defer metas.deinit(gpa);

        var builder = try bundlem.Builder.init(gpa, metas.items.items, self.ops.actors.items);
        defer builder.deinit(gpa);

        // **`0..1` for nothing, which walks no rows**: upstream's
        // `unwrap_or(0)` on both ends of `min` and `max`
        // ([`bundle.rs`:53-56](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs)),
        // and a counter of zero names no operation.
        var lo: ?u64 = null;
        var hi: u64 = 0;
        for (metas.items.items) |meta| {
            lo = if (lo) |have| @min(have, meta.start_op) else meta.start_op;
            hi = @max(hi, meta.max_op);
        }
        const first = lo orelse 0;
        const past_last = hi +| 1;

        var walk = try self.ops.iter();
        while (try walk.next()) |op| {
            if (!bundleRowIsVisited(op, first, past_last)) continue;
            try builder.processOp(bundleOpOf(op));
            var succ = op.succ();
            while (succ.next()) |s| try builder.processSucc(op.id(), s);
        }
        return builder.finish(gpa);
    }

    /// Whether `iter_ctr_range(lo..hi)` visits this row: its own counter is in
    /// the range, or one of the operations it overwrites is.
    ///
    /// **This is the whole of upstream's [`SkipIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs):174-185
    /// over [`MergeIter`](../../github-automerge-automerge/rust/automerge/src/iter/tools.rs):277-304,
    /// and both halves are needed.** The left walker is the row's own counter
    /// and the right one its successor edges'
    /// ([`op_iter.rs`:293-339](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/op_iter.rs));
    /// the merge is the union of the two position streams and the skip turns
    /// that into "advance to this row". A filter on the row's own counter
    /// alone drops every delete whose overwriting op is outside the bundle,
    /// and the receiver then materialises an operation the sender had already
    /// removed.
    fn bundleRowIsVisited(op: opmod.Op, lo: u64, hi: u64) bool {
        const ctr = op.id().counter;
        if (ctr >= lo and ctr < hi) return true;
        var succ = op.succ();
        while (succ.next()) |s| {
            if (s.counter >= lo and s.counter < hi) return true;
        }
        return false;
    }

    /// One row of the op set as the bundle writer consumes it.
    ///
    /// **`key` is the row's own anchor, `op.key()`, and not the register it
    /// hangs by.** The two differ for exactly one shape, and it is the shape
    /// every sequence operation has: `Op::elemid_or_key` answers an insert's
    /// **own** element id, because an insert opens a register of its own
    /// ([`op.rs`:1040-1046](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    /// while `Op::build` hands the writer the row's `key` field unchanged
    /// ([`op.rs`:1134-1146](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)) and
    /// that is what `BundleOpWriter::add` puts in the key columns
    /// ([`builder.rs`:375-377](../../github-automerge-automerge/rust/automerge/src/storage/bundle/builder.rs)).
    /// The anchor is what an insert was placed *after*, and it is the only
    /// thing that says where in the sequence it went — the op set's own
    /// register key has already thrown that away.
    ///
    /// **The two answers produce two different bundles, and only this one
    /// reconstructs the changes.** An insert written with its own id as its
    /// key comes back as an op *anchored at itself*, and
    /// [`Untangler.init`](opset/batch.zig) then files it in `entry` under an
    /// element no document row has — the insert is the row that would make
    /// that element — so nothing ever drains the entry and
    /// [`Untangler.finish`](opset/batch.zig) refuses the batch as
    /// `error.Invariant` (upstream's `assert!(self.entry.is_empty())`,
    /// [`batch.rs`:136](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
    /// And before that refusal the change hashes differ, because the key
    /// column of a change op is the anchor: a change re-encoded from a bundle
    /// that stored the register hashed differently from the change the bundle
    /// was written from, and a receiver that saw both then had two changes
    /// claiming one `(actor, seq)`.
    ///
    /// **`pred` is discarded**, which is upstream's
    /// `BundleOp<'a>` carrying no predecessor list at all
    /// ([`bundle/builder.rs`:354-380](../../github-automerge-automerge/rust/automerge/src/storage/bundle/builder.rs)):
    /// the writer builds it from the successor map it collects as the walk
    /// passes, and [`Builder.processOp`](storage/bundle.zig) replaces whatever
    /// a caller supplies.
    fn bundleOpOf(op: opmod.Op) bundlem.BundleOp {
        return .{
            .id = op.id(),
            .obj = op.objId(),
            .key = switch (op.key()) {
                .map => |k| .{ .map = k },
                .seq => |e| .{ .seq = e.id },
            },
            .action = op.action(),
            .value = op.value(),
            .insert = op.insert(),
            .expand = op.expand(),
            .mark_name = op.markName(),
            .pred = &.{},
        };
    }

    /// The bundle metadata for each of `hashes`, in the order given
    /// ([`ChangeGraph::get_bundle_metadata`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):338-382).
    ///
    /// **Every field comes from the graph and the node table, and `start_op`
    /// from the node table alone.** Upstream computes it as
    /// `max_op - num_ops + 1` from a `num_ops` column; this port keeps the same
    /// number in [`NodeInfo.start_op`], which is where every other route that
    /// re-encodes a change reads it from ([`Document.getChangesByHashes`]) — so
    /// there is one answer and not two derivations of it.
    ///
    /// The result is the metadata **and** the block its `deps` windows point
    /// into ([`BundleMetas`]), because the builder reads those windows after
    /// this has returned.
    fn bundleMetas(
        self: *const Document,
        gpa: Allocator,
        hashes: []const ChangeHash,
    ) DocumentError!BundleMetas {
        // **One allocation for every dependency of every change**, because each
        // meta borrows its own window of it for as long as the builder runs.
        var deps_total: usize = 0;
        for (hashes) |hash| {
            const index = self.graph.hashToIndex(hash) orelse return error.MissingDeps;
            var parents = self.graph.parents(index);
            while (parents.next()) |_| deps_total += 1;
        }
        const deps_all = try gpa.alloc(ChangeHash, deps_total);
        // **Two allocations, and they are released together.** The windows
        // below are interior to `deps_all`, so the caller has to hold both,
        // and every failure past this line gives both back.
        errdefer gpa.free(deps_all);
        var out: std.ArrayList(bundlem.BundleMetadata) = .empty;
        errdefer out.deinit(gpa);

        var at: usize = 0;
        for (hashes, 0..) |hash, i| {
            const index = self.graph.hashToIndex(hash) orelse return error.MissingDeps;
            const node = self.graph.nodeAt(index) orelse return error.MissingDeps;
            var parents = self.graph.parents(index);
            var written: usize = 0;
            while (parents.next()) |p| : (written += 1) {
                deps_all[at + written] = self.graph.indexToHash(p) orelse
                    return error.MissingDeps;
            }
            const info = self.nodeInfo(index);
            out.append(gpa, .{
                .hash = hash,
                .actor = node.actor,
                .seq = node.meta.seq,
                .start_op = info.start_op,
                .max_op = node.meta.max_op,
                .timestamp = node.meta.time,
                // **An empty message is no message**, which is upstream's
                // `self.messages.get(i).flatten()`
                // ([`change_graph.rs`:356](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)):
                // the column stores an absent run, so a present-but-empty
                // string would write a cell the reference never writes.
                .message = if (node.meta.message.len == 0) null else node.meta.message,
                .deps = deps_all[at..][0..written],
                .extra = info.extra,
                // **Topological order**, which is what upstream's `builder`
                // field carries and what [`bundlem.Builder.init`] sorts on
                // ([`bundle/builder.rs`:57-59](../../github-automerge-automerge/rust/automerge/src/storage/bundle/builder.rs)).
                .builder = i,
            }) catch return error.OutOfMemory;
            at += written;
        }
        return .{ .items = out, .deps = deps_all };
    }

    /// The fragments covering the history at `levels`, **oldest first**
    /// ([`Automerge::fragments`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1465-1478).
    ///
    /// **The reversal is upstream's and it is the whole of this method.**
    /// [`ChangeGraph.fragments`](change_graph.zig) walks newest to oldest
    /// (`change_graph.rs:614-627`) and `fragments.reverse()` turns that around
    /// before returning, so a caller that wants to ship history in order sends
    /// the oldest fragment first. The caller owns the array **and each
    /// fragment's three arrays**; free it with
    /// [`deinitFragments`](change_graph.zig).
    pub fn fragments(
        self: *const Document,
        gpa: Allocator,
        levels: LevelRange,
    ) Error![]Fragment {
        const heads = self.graph.getHeads();
        const out = try self.graph.fragments(gpa, heads, levels);
        std.mem.reverse(Fragment, out);
        return out;
    }

    /// The fragment named by `head`, or null when the document holds no such
    /// fragment ([`Automerge::get_fragment`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1486-1488).
    pub fn getFragment(self: *const Document, gpa: Allocator, head: ChangeHash) Error!?Fragment {
        return self.graph.getFragment(gpa, head);
    }

    /// Each fragment as bytes: a bare change for a level-0 fragment with one
    /// member, and a bundle otherwise
    /// ([`Automerge::bundle_fragments`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1496-1510).
    ///
    /// **A level-0 fragment with one member is that member's change chunk and
    /// not a one-change bundle**, because a receiver loads a change chunk
    /// without needing the bundle's prefix, and it is upstream's `if
    /// f.head.fragment_level() == 0 && f.members.len() == 1` arm.
    ///
    /// **A fragment the document cannot rebuild is dropped, not an error, on
    /// both arms.** The change arm is upstream's `filter_map` over
    /// `self.get_change_by_hash(&f.head)?` and the bundle arm is its
    /// `self.bundle(f.members).ok()?` ([`automerge.rs`:1494-1501](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    /// such a fragment produces no entry and does not fail the call, and the
    /// caller keeps every encoding built for the fragments before it. Every
    /// other fragment contributes one buffer.
    ///
    /// **`error.OutOfMemory` is the one thing a drop must not swallow**, and
    /// that is a deliberate departure from the shape of upstream's `.ok()?`:
    /// upstream cannot express the case, because a Rust allocation failure is
    /// not an error value at all — `alloc::alloc` reaches
    /// `alloc::alloc::handle_alloc_error` on failure and that diverges, so
    /// there is nothing for `?` to convert. Here it is a recoverable
    /// `error.OutOfMemory`, and dropping it would make a caller believe it had
    /// asked for fragments the document cannot encode when the truth is that
    /// memory ran out, and would make `testing.checkAllAllocationFailures` see
    /// a success at every induced failure. The bundle arm below is the only one
    /// that has to say so; the change arm reaches `getChangeByHash` with `try`
    /// for the same reason.
    ///
    /// **The two arms own their buffers differently, and neither copies a
    /// whole encoded change.** A change chunk is **framed here**, because
    /// upstream's `Change::bytes()` is the framed chunk and `body_bytes()` is
    /// the part inside it ([`change.rs`:260-266](../../github-automerge-automerge/rust/automerge/src/storage/change.rs)),
    /// while this port's [`Change.bytes`] is the body alone — the bytes the
    /// hash was taken over — so a receiver could not parse what the body is.
    /// [`Change.encode`] writes the frame straight around that body in one
    /// allocation, with no second copy of it behind the result. A bundle's
    /// buffer is **moved out of the writer** ([`Bundle.intoOwnedBytes`]),
    /// which already owns the chunk it produced.
    /// The caller owns the outer array and each buffer in it.
    pub fn bundleFragments(
        self: *Document,
        gpa: Allocator,
        wanted: []const Fragment,
    ) DocumentError![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |buffer| gpa.free(buffer);
            out.deinit(gpa);
        }
        for (wanted) |fragment| {
            if (fragment.head.fragmentLevel() == 0 and fragment.members.len == 1) {
                var built = (try self.getChangeByHash(gpa, fragment.head)) orelse continue;
                defer built.deinit(gpa);
                const framed = try built.change.encode(gpa);
                // **A growth failure here frees the frame** rather than leaking
                // it: `out` holds everything appended before this fragment and
                // nothing after it, so the two cleanups do not overlap.
                errdefer gpa.free(framed);
                try out.append(gpa, framed);
            } else {
                // **A bundle that fails is a dropped fragment; an allocator
                // that fails is an error.** Upstream's bundle arm is
                // `Some(self.bundle(f.members).ok()?.bytes().to_vec())`
                // ([`automerge.rs`:1499](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
                // inside the `filter_map`, so a fragment the document cannot
                // rebuild contributes no entry and does not fail the call —
                // the caller keeps the encodings built for every fragment
                // before it. `.ok()?` cannot swallow an allocation failure
                // there because **Rust's allocator is not recoverable**: a
                // failed `alloc::alloc` reaches `handle_alloc_error`, which
                // diverges rather than returning, so there is no `Result` for
                // this `?` to see. Zig's is, so the same `.ok()?` written here
                // would silently turn "the allocator ran out" into "this
                // fragment does not exist" — and
                // `testing.checkAllAllocationFailures` would report a clean
                // call on every induced failure, which is the one signal it
                // exists to give. **So the allocator error is the one error
                // that propagates**, and only it.
                var written = self.bundle(gpa, fragment.members) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                // **Same for a bundle**: a written bundle owns the chunk it
                // hands back, and `intoOwnedBytes` gives that ownership up
                // rather than this method duplicating it.
                const owned = written.intoOwnedBytes();
                written.deinit(gpa);
                errdefer gpa.free(owned);
                try out.append(gpa, owned);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// The footer of a change the document holds, or null.
    fn changeFooterOf(self: *Document, change: Change) ?[]const u8 {
        _ = self;
        return changeFooter(change);
    }

    /// The last change this document's own actor made
    /// ([`Automerge::get_last_local_change`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1223-1228).
    ///
    /// Null when this document's actor has made nothing — which is every
    /// document that has only ever been loaded, and a document whose actor was
    /// never interned.
    /// Null means no local change. Otherwise call the result's `deinit(gpa)`.
    pub fn getLastLocalChange(
        self: *Document,
        gpa: Allocator,
    ) DocumentError!?Built {
        const actor = self.getActorIndex() orelse return null;
        const seq = self.graph.seqForActor(actor);
        if (seq == 0) return null;
        const hash = self.graph.hashForActorSeq(actor, seq) catch return null;
        return self.getChangeByHash(gpa, hash);
    }

    /// Rebuilds the changes named by `hashes`, in that order
    /// ([`ChangeCollector::for_hashes`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):724-734).
    ///
    /// Preserves every requested occurrence, including repeated and empty
    /// changes, with independently owned bodies and actor metadata. Each unique
    /// change is reconstructed once from the authoritative op set. An empty
    /// request returns an empty owned list.
    /// This mutable reader reuses shared successor scratch and invalidates
    /// outstanding borrowed successor views; it does not mutate history.
    /// An unknown hash returns `error.MissingDeps`; reconstruction and allocation
    /// failures release every partial result and leave history unchanged.
    /// The result borrows nothing from the document or `hashes` and survives
    /// source mutation or teardown. Release it once with `Changes.deinit(gpa)`.
    pub fn getChangesByHashes(
        self: *Document,
        gpa: Allocator,
        hashes: []const ChangeHash,
    ) DocumentError!Changes {
        if (hashes.len == 0) return .{};
        const Selection = struct { meta: usize, first: usize };
        var selected: std.AutoHashMapUnmanaged(NodeIdx, Selection) = .empty;
        defer selected.deinit(gpa);
        var unique_len: usize = 0;
        var deps_total: usize = 0;
        for (hashes, 0..) |hash, i| {
            const index = self.graph.hashToIndex(hash) orelse return error.MissingDeps;
            const node = self.graph.nodeAt(index) orelse return error.MissingDeps;
            // A singleton needs no selection map. Larger batches preserve the
            // first occurrence while avoiding competing builders for one range.
            if (hashes.len > 1) {
                const entry = try selected.getOrPut(gpa, index);
                if (entry.found_existing) continue;
                entry.value_ptr.* = .{ .meta = unique_len, .first = i };
            }
            unique_len += 1;
            deps_total += node.meta.deps.len;
        }
        const metas = try gpa.alloc(BuildMeta, unique_len);
        defer freeMetas(gpa, metas);
        // One backing allocation keeps every unique change's dependencies live
        // until the collector has finished reading its metadata.
        const deps_all = try gpa.alloc(NodeIdx, deps_total);
        defer gpa.free(deps_all);
        var at: usize = 0;
        for (hashes, 0..) |hash, i| {
            const index = self.graph.hashToIndex(hash) orelse return error.MissingDeps;
            const selection: Selection = if (hashes.len == 1)
                .{ .meta = 0, .first = 0 }
            else
                selected.get(index).?;
            if (selection.first != i) continue;
            const node = self.graph.nodeAt(index) orelse return error.MissingDeps;
            const info = self.nodeInfo(index);
            const deps = deps_all[at..][0..node.meta.deps.len];
            at += node.meta.deps.len;
            for (node.meta.deps, 0..) |dep, k| {
                deps[k] = self.graph.hashToIndex(dep) orelse return error.MissingDeps;
            }
            const start_op = info.start_op;
            const num_ops = if (node.meta.max_op < start_op)
                0
            else
                node.meta.max_op - start_op + 1;
            metas[selection.meta] = .{
                .actor = node.actor,
                .seq = node.meta.seq,
                .start_op = start_op,
                .max_op = start_op + num_ops -| 1,
                .time = node.meta.time,
                .message = node.meta.message,
                .deps = deps,
                .footer = info.extra,
            };
        }
        var changes = blk: {
            var collected: Changes = .{};
            errdefer collected.deinit(gpa);
            try collectChanges(gpa, &self.ops, self.ops.actors.items, metas, .{ .graph = &self.graph }, &collected);
            break :blk collected;
        };
        // The unique hot path returns the collector's owners without another
        // output vector, parse or body copy.
        if (unique_len == hashes.len) return changes;

        var moved: usize = 0;
        defer {
            // First occurrences move in metadata order. Only this suffix still
            // belongs to the collector if an output allocation is refused.
            for (changes.items.items[moved..]) |*built| built.deinit(gpa);
            changes.items.deinit(gpa);
        }
        var out: Changes = .{};
        errdefer out.deinit(gpa);
        try out.items.ensureTotalCapacity(gpa, hashes.len);
        for (hashes, 0..) |hash, i| {
            const index = self.graph.hashToIndex(hash) orelse return error.MissingDeps;
            const selection = selected.get(index).?;
            if (selection.first == i) {
                out.items.appendAssumeCapacity(changes.items.items[selection.meta]);
                moved += 1;
            } else {
                const original = out.items.items[selection.first];
                const body = try gpa.dupe(u8, original.body);
                errdefer gpa.free(body);
                var change = try changerec.parseChangeWithHash(body, gpa, original.change.hash);
                errdefer change.deinit(gpa);
                const num_ops = if (original.change.max_op < original.change.start_op)
                    0
                else
                    original.change.max_op - original.change.start_op + 1;
                change = try change.withOpCount(num_ops);
                out.items.appendAssumeCapacity(.{ .body = body, .change = change });
            }
        }
        return out;
    }

    /// What the document recorded about the node at `index`.
    fn nodeInfo(self: *const Document, index: NodeIdx) NodeInfo {
        const i: usize = index;
        std.debug.assert(i < self.node_info.items.len);
        return self.node_info.items[i];
    }

    // ── The document algebra ───────────────────────────────────────────────

    /// Deep independent copy, including pending op rows, actor, author and queue.
    /// This does not close a transaction or publish pending rows into history.
    /// The caller owns the result and releases it with `deinit`; errors leave
    /// the source unchanged (upstream's derived `Clone`, `automerge.rs:248`).
    pub fn clone(self: *Document, gpa: Allocator) LoadError!Document {
        return self.cloneImpl(gpa, true);
    }

    /// Copies pending document state without closing its source transaction.
    /// This copies rows, not the transaction journal; the transaction owner
    /// must clone its journal into the result's final stable address.
    /// Ownership and error behaviour are the same as `clone`.
    pub fn clonePending(self: *Document, gpa: Allocator) LoadError!Document {
        return self.cloneImpl(gpa, true);
    }

    fn cloneImpl(self: *Document, gpa: Allocator, preserve_actor: bool) LoadError!Document {
        var out = try initOwned(gpa, self.io, self.textEncoding(), if (preserve_actor) self.getActorId() else null);
        errdefer out.deinit();
        const arena = out.arena.allocator();
        // Preserve every actor slot, including actors present only in pending
        // rows. The op set borrows bytes, so the destination arena owns them.
        const actors = try arena.alloc(ActorId, self.ops.actors.items.len);
        for (self.ops.actors.items, actors) |actor, *copied| {
            copied.* = .{ .bytes = try arena.dupe(u8, actor.bytes) };
        }
        // Keep string ids stable for a pending transaction's cloned journal,
        // even when column traversal interns keys in a different order.
        for (self.strings.map.keys()) |bytes| {
            _ = try Strings.intern(out.strings, bytes, gpa);
        }
        var exported = try self.ops.exportColumns(gpa);
        defer exported.deinit(gpa);
        const ops = try Set.load(gpa, exported.cols, actors, self.textEncoding(), out.strings.table());
        out.ops.deinit();
        out.ops = ops;
        const graph = try self.graph.clone(gpa);
        out.graph.deinit();
        out.graph = graph;
        const queue = try self.queue.clone(gpa);
        out.queue.deinit();
        out.queue = queue;
        try out.authors.items.appendSlice(gpa, actors);
        try out.authors.remap_buf.appendSlice(gpa, self.authors.remap_buf.items);
        try out.node_info.ensureTotalCapacity(gpa, self.node_info.items.len);
        for (self.node_info.items) |info| {
            out.node_info.appendAssumeCapacity(.{
                .start_op = info.start_op,
                .extra = try arena.dupe(u8, info.extra),
            });
        }
        try out.actor_authors.ensureTotalCapacity(gpa, self.actor_authors.items.len);
        for (self.actor_authors.items) |author| {
            out.actor_authors.appendAssumeCapacity(if (author) |bytes| try arena.dupe(u8, bytes) else null);
        }
        try out.author_names.ensureTotalCapacity(gpa, self.author_names.items.len);
        for (self.author_names.items) |author| {
            out.author_names.appendAssumeCapacity(try arena.dupe(u8, author));
        }
        if (preserve_actor) switch (self.actor) {
            .unused => {},
            .cached => |idx| out.actor = .{ .cached = idx },
        };
        out.author = if (self.author) |bytes| try arena.dupe(u8, bytes) else null;
        out.isolation = if (self.isolation) |heads| try gpa.dupe(ChangeHash, heads) else null;
        if (preserve_actor) {
            try out.diff_cursor.appendSlice(gpa, self.diff_cursor.items);
            try out.save_cursor.appendSlice(gpa, self.save_cursor.items);
            const patch_log = try self.patch_log.cloneAndRebind(gpa, out.patch_identity);
            out.patch_log.deinit();
            out.patch_log = patch_log;
        }
        // Read clocks are derived caches. Rebuilding them on demand avoids
        // borrowing the source's clocks or its historical iterator storage.
        return out;
    }

    /// A copy of this document for a different actor
    /// ([`Automerge::fork`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):702-706).
    ///
    /// A clone with a secure random actor from the retained `io` provider.
    /// Refusal returns no fork and preserves the source. The new actor lives
    /// in the fork's arena (`automerge.rs:702-706`).
    pub fn fork(self: *Document, gpa: Allocator) LoadError!Document {
        return self.cloneImpl(gpa, false);
    }

    /// A new document that holds exactly the changes `heads` reaches
    /// ([`Automerge::fork_at`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):711-735).
    ///
    /// **A head the document does not hold is `error.InvalidHash`**, not an
    /// empty document: upstream returns `AutomergeError::InvalidHash` from
    /// inside the walk ([`:720-722`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)), and a
    /// fork at an unknown head that silently produced an empty document would
    /// lose work without saying so.
    pub fn forkAt(
        self: *Document,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) LoadError!Document {
        var seen: std.AutoHashMapUnmanaged(ChangeHash, void) = .empty;
        defer seen.deinit(gpa);
        var stack: std.ArrayList(ChangeHash) = .empty;
        defer stack.deinit(gpa);
        var hashes: std.ArrayList(ChangeHash) = .empty;
        defer hashes.deinit(gpa);

        for (heads) |head| {
            if (seen.contains(head)) continue;
            try seen.put(gpa, head, {});
            try stack.append(gpa, head);
        }
        while (stack.pop()) |hash| {
            if (!self.graph.hasChange(hash)) return error.InvalidHash;
            var deps = self.graph.depsForHash(hash);
            while (deps.next()) |dep| {
                const dep_hash = self.graph.indexToHash(dep) orelse continue;
                if (seen.contains(dep_hash)) continue;
                try seen.put(gpa, dep_hash, {});
                try stack.append(gpa, dep_hash);
            }
            try hashes.append(gpa, hash);
        }
        std.mem.reverse(ChangeHash, hashes.items);

        var changes = try self.getChangesByHashes(gpa, hashes.items);
        defer changes.deinit(gpa);

        // The fork measures text the way the document it was forked from does,
        // because the changes it is about to apply index text in it.
        var out = try Document.initWithEncoding(gpa, self.io, self.textEncoding());
        errdefer out.deinit();
        const view = try asChanges(gpa, changes.slice());
        defer gpa.free(view);
        _ = try out.applyChanges(gpa, view);
        return out;
    }

    // ── The small readers ──────────────────────────────────────────────────

    /// What the document holds
    /// ([`ReadDoc::stats`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2300-2315).
    pub fn stats(self: *const Document) Stats {
        return .{
            .num_changes = @intCast(self.graph.len()),
            .num_ops = @intCast(self.ops.len()),
            .num_actors = @intCast(self.ops.actors.items.len),
            .package_name = @import("build_options").package_name,
            .package_version = @import("build_options").package_version,
            .compiler_version = @import("builtin").zig_version_string,
        };
    }

    /// Initializes root keys in one transaction and commits one batch.
    /// Existing keys absent from `map` remain unchanged (`automerge.rs:297-304`).
    /// Opening errors return directly. Later failures preserve the primary error
    /// in the outcome; a refused rollback also returns the live transaction.
    /// Release the outcome's patch log once. A returned recovery transaction
    /// borrows this document, which must remain address-stable until recovery closes.
    pub fn initFromHydrate(
        self: *Document,
        gpa: Allocator,
        map: *const @import("hydrate.zig").Map,
    ) @import("transaction.zig").TransactionError!@import("transaction.zig").Outcome(
        void,
        @import("transaction.zig").TransactionError,
    ) {
        const transaction = @import("transaction.zig");
        const Body = struct {
            fn run(
                input_map: *const @import("hydrate.zig").Map,
                tx: *@import("transact.zig").Transaction,
            ) transaction.TransactionError!void {
                try tx.initRootFromHydrate(input_map);
            }
        };
        return transaction.enclose(void, gpa, self, map, Body.run);
    }

    /// Whether the peer shares exactly the ordered, full committed heads.
    /// This ignores isolation and neither allocates nor changes the document.
    pub fn hasOurChanges(self: *const Document, state: *const @import("sync/state.zig").State) bool {
        return sameHashList(state.shared_heads, self.graph.getHeads());
    }

    /// Parses a stable object ID and resolves its actor against this document.
    /// Syntax failures are `InvalidObjIdFormat`; unknown actors are `InvalidObjId`.
    /// The result borrows actor bytes until the next document mutation.
    pub fn importObj(self: *const Document, gpa: Allocator, spelling: []const u8) DocumentError!ExId {
        var parsed = ExId.parse(gpa, spelling) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidObjIdFormat,
        };
        defer parsed.deinitOwned(gpa);
        if (parsed == .root) return .root;
        const actor = parsed.actorBytes() orelse return error.InvalidObjId;
        const index = self.ops.lookupActor(actor) orelse return error.InvalidObjId;
        const live_actor = self.ops.getActor(@intCast(index)) orelse return error.InvalidObjId;
        const counter = std.math.cast(u32, parsed.counter() orelse return error.InvalidObjId) orelse
            return error.InvalidObjId;
        return ExId.withActor(.{
            .counter = counter,
            .actor = @intCast(index),
        }, live_actor);
    }

    /// Imports a live object, rejecting scalar-operation and nonexistent IDs.
    /// The returned identity has the same borrowed lifetime as `importObj`.
    pub fn import(self: *const Document, gpa: Allocator, spelling: []const u8) DocumentError!ImportedObject {
        const id = try self.importObj(gpa, spelling);
        const object_type = self.objectType(id) catch return error.InvalidObjId;
        return .{ .id = id, .object_type = object_type };
    }

    /// Writes the complete exported op columns and actor table for inspection.
    /// The document is unchanged; a writer failure may leave a diagnostic prefix.
    pub fn dump(
        self: *const Document,
        gpa: Allocator,
        writer: *std.Io.Writer,
    ) (ParseError || std.Io.Writer.Error)!void {
        var exported = try self.ops.exportColumns(gpa);
        defer exported.deinit(gpa);
        try writer.print("OpSet\n  len: {d}\n  actors: {d}\n", .{
            self.ops.len(), self.ops.actors.items.len,
        });
        for (self.ops.actors.items, 0..) |actor, index| {
            try writer.print("actor {d}: {x}\n", .{ index, actor.bytes });
        }
        for (exported.cols.columns) |column| {
            try writer.print("column {x}: {x}\n", .{
                column.spec.raw, try column.range.slice(exported.data),
            });
        }
    }

    /// Writes differing exported op columns, including columns absent on either side.
    /// Equal column payloads produce no output. Neither document is changed.
    /// This is the writer equivalent of upstream `automerge.rs:798-830`.
    pub fn diffOpSet(
        self: *const Document,
        gpa: Allocator,
        other: *const Document,
        writer: *std.Io.Writer,
    ) (ParseError || std.Io.Writer.Error)!void {
        var left = try self.ops.exportColumns(gpa);
        defer left.deinit(gpa);
        var right = try other.ops.exportColumns(gpa);
        defer right.deinit(gpa);
        var left_index: usize = 0;
        var right_index: usize = 0;
        while (left_index < left.cols.columns.len or right_index < right.cols.columns.len) {
            const left_column = if (left_index < left.cols.columns.len)
                left.cols.columns[left_index]
            else
                null;
            const right_column = if (right_index < right.cols.columns.len)
                right.cols.columns[right_index]
            else
                null;
            const order: std.math.Order = if (left_column) |column|
                if (right_column) |other_column|
                    column.spec.compare(other_column.spec)
                else
                    .lt
            else
                .gt;
            const spec = if (order == .gt) right_column.?.spec else left_column.?.spec;
            const left_bytes = if (order != .gt)
                try left_column.?.range.slice(left.data)
            else
                &.{};
            const right_bytes = if (order != .lt)
                try right_column.?.range.slice(right.data)
            else
                &.{};
            if (!std.mem.eql(u8, left_bytes, right_bytes)) {
                try writer.print("column {x}\n  left: {x}\n  right: {x}\n", .{
                    spec.raw, left_bytes, right_bytes,
                });
            }
            if (order != .gt) left_index += 1;
            if (order != .lt) right_index += 1;
        }
    }

    /// How every text width in this document is measured
    /// ([`OpSet::text_encoding`](opset/op_set.zig)).
    pub fn textEncoding(self: *const Document) TextEncoding {
        return self.ops.textEncoding();
    }

    /// What kind of object `obj` is
    /// ([`ReadDoc::object_type`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2282-2287).
    ///
    /// The root is a map and always answers; anything else is
    /// `error.NotAnObject` when no op made it, which is upstream's
    /// `InvalidObjId` with a payload this error set does not carry.
    ///
    /// **Goes through [`Document.resolve`] first**, exactly as upstream's
    /// `object_type_for` reaches `exid_to_obj`
    /// ([`automerge.rs:788-792`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// so an id minted before an `isolate` that forked the actor still names
    /// the object it named then.
    pub fn objectType(self: *const Document, obj: ObjId) Error!ObjType {
        const live = self.resolve(obj) orelse return error.NotAnObject;
        if (live == .root) return .map;
        return self.ops.objectType(live) orelse error.NotAnObject;
    }

    /// `ex` with its actor index resolved against the current actor table, or
    /// null when it names nothing here
    /// ([`Automerge::exid_to_opid`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):744-758).
    ///
    /// **This is the port's copy of upstream's three-field `ExId`
    /// ([`exid.rs:15-18`](../../github-automerge-automerge/rust/automerge/src/exid.rs)),
    /// and it exists because an interned actor can move.** The table is kept
    /// sorted, so interning an actor that sorts before the others renumbers
    /// every index at or above it
    /// ([`op_set.rs:1400-1405`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// and an `ExId` records only an index. Upstream records the actor's
    /// **bytes** beside it and repairs the index on every use: the recorded
    /// one if the table still holds that actor there (`:748-749`), and
    /// `lookup_actor` if it does not (`:750-751`).
    ///
    /// **An id with no bytes is returned unchanged**, because there is
    /// nothing to check it against. Every id the document hands out carries
    /// them — [`Document.idToExid`] is the only way one is made — so this is
    /// the path for an id built by [`ExId.fromParts`] from a caller that has
    /// only an actor index, and the reference is exactly the old behaviour.
    /// Public named counters wider than resident OpId storage are unresolved.
    pub fn resolve(self: *const Document, ex: ExId) ?ExId {
        if (ex == .root) return .root;
        const op = ex.opId() orelse return null;
        const who = ex.actorBytes() orelse return ex;
        if (self.ops.getActor(op.actor)) |here| {
            if (here.eql(who)) return ex;
        }
        const found = self.ops.lookupActor(who) orelse return null;
        if (found == op.actor) return ex;
        return ExId.withActor(.{ .counter = op.counter, .actor = @intCast(found) }, who);
    }

    /// The object `obj` hangs by, or null for the root and for an id that
    /// names no object ([`OpSet::object_parent`](opset/op_set.zig)).
    pub fn objectParent(self: *const Document, obj: ObjId) ?ObjId {
        return self.ops.objectParent(obj);
    }

    /// How many rows the op set holds
    /// ([`OpSet::len`](opset/op_set.zig), reached through `automerge.rs:2302`).
    pub fn len(self: *const Document) usize {
        return self.ops.len();
    }

    /// The public form of an op id
    /// ([`Automerge::id_to_exid`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):794-796).
    ///
    /// **This is where an `ExId` gets the actor's bytes**
    /// ([`op_set.rs:1057-1059`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs):
    /// `ExId::Id(id.counter(), self.actors[id.actor()].clone(), id.actor())`),
    /// and that is the whole reason [`Document.resolve`] can repair one later.
    /// The op set's own [`OpSet.idToExid`](opset/op_set.zig) has no document to
    /// ask and so answers the bare operation, which is all the storage needs.
    pub fn idToExid(self: *const Document, id: OpId) ExId {
        const base = self.ops.idToExid(id);
        if (base == .root) return base;
        const op = base.opId().?;
        const who = self.ops.getActor(op.actor) orelse return base;
        return ExId.withActor(op, who);
    }

    /// The text of a text object
    /// ([`ReadDoc::text`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):2152-2154,
    /// over [`OpSet::text`](opset/op_set.zig)). The caller owns the bytes.
    pub fn text(
        self: *Document,
        gpa: Allocator,
        obj: ObjId,
    ) OpError![]u8 {
        return self.ops.text(gpa, obj, null);
    }

    /// Every mark on `obj`, coalesced into runs and with the unmarks dropped,
    /// **at the document's own scope**. The caller owns the list; each mark's
    /// bytes are the document's, valid until the next mutation.
    ///
    /// **This method is the port's and not upstream's**, and that is the whole
    /// reason it takes a scope. Upstream has no `Document.marks`: it has
    /// [`Automerge::marks_for`],
    /// `automerge.rs:1851-1857`, and every reader of it passes a clock —
    /// `marks_for(obj, self.get_scope(None))`,
    /// [`autocommit.rs`:919-921](../github-automerge-automerge/rust/automerge/src/autocommit.rs).
    /// So upstream's shape is *a fold parameterised by a clock*, and a document
    /// that carries an isolation always has one. [`read.marks`](read.zig) is
    /// the port's translation of that; this one sits beside it for a caller
    /// already holding a `*Document`.
    ///
    /// **So it resolves in upstream's order — the id first, then the clock** —
    /// because building a clock can intern an actor and renumber the very table
    /// the id was resolved against (`automerge.rs`:1574, then `:1242-1249`), and
    /// because `calculate_marks` resolves before it dispatches (`:1574`).
    /// [`read.marks`](read.zig:891-905) does the same two steps in the same
    /// order and says why.
    ///
    /// **It used to call [`OpSet.calculateMarks`] and answer the present under
    /// an isolation**, on the strength of a comment that said the fold had no
    /// clock to take. That was false once [`OpSet.calculateMarksAt`] existed —
    /// it holds upstream's whole dispatch (`automerge.rs`:1569-1596) — and the
    /// answer it gave was the one a scoped reader must never give: a
    /// historical read reported as the current one. The walk arm is now
    /// reached, and an id that names nothing is `error.NotAnObject`, upstream's
    /// `exid_to_obj` (`:1574`).
    pub fn marks(self: *Document, gpa: Allocator, obj: ObjId) MarkError![]marksmod.Mark {
        const live = self.resolve(obj) orelse return error.NotAnObject; // `:1574`
        const scope: ?clockmod.Clock = if (try self.readScope(gpa)) |c| c.* else null;
        return self.ops.calculateMarksAt(gpa, live, scope); // `:1582-1595`
    }

    /// Whether the change graph and pending dependency queue are empty.
    /// Uncommitted transaction rows do not affect this result (`automerge.rs:349-351`).
    pub fn isEmpty(self: *const Document) bool {
        return self.graph.isEmpty() and self.queue.isEmpty();
    }

    /// Compares two documents row for row and actor for actor
    /// ([`Automerge::debug_cmp`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1164-1166).
    ///
    /// This is the port's main equivalence check: a document that saves and
    /// reloads must compare equal, and a document that differs by one row must
    /// not.
    pub fn debugCmp(self: *const Document, other: *const Document) (ParseError || InternalError)!void {
        return self.ops.debugCmp(&other.ops);
    }

    // ── Diffing ─────────────────────────────────────────────────────────────
    //
    // The four methods below are the whole of `Automerge`'s and `AutoCommit`'s
    // patch surface (`automerge.rs:1419-1457`, `autocommit.rs:183-216`,
    // `:255-305`, `:347-354`). They are **not** a reader: every one of them
    // builds a fresh [`patchesmod.PatchLog`], walks the document with
    // [`iterdoc.DiffIter`] and asks the log for its patches, so the answer is a
    // function of two points in history and nothing else.
    //
    // **The returned patches are owned by the caller** — `Patches.deinit` is
    // the one free — because a patch outlives the log and the document it was
    // taken from. Upstream's `Vec<Patch>` frees itself by dropping; here the
    // bytes live in a [`patchesmod.Patches`] arena and the contract has to be
    // written down, since **Rust's ownership does not survive the crossing** to
    // a C ABI or to a caller that never saw `Vec`.

    /// The patches that carry the document from `before` to `after`
    /// ([`AutoCommit::diff`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:255-257`, over `automerge.rs`:1419-1426`).
    ///
    /// **A document-wide diff is `diffObj` on the root** — `autocommit.rs:257`
    /// passes `ObjMeta::root()` and `true` — so this is that call and not a
    /// second implementation.
    ///
    /// `before` and `after` need not be chronological; document state can move
    /// backward (`automerge.rs:1420-1421`). The caller owns the result; see
    /// this section's note on ownership.
    pub fn diff(
        self: *Document,
        gpa: Allocator,
        before: []const ChangeHash,
        after: []const ChangeHash,
    ) DiffError!patchesmod.Patches {
        return self.diffObj(gpa, .root, before, after, true);
    }

    /// The patches that carry one object from `before` to `after`
    /// ([`Automerge::diff_obj`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
    /// `automerge.rs:1442-1457`).
    ///
    /// `recursive` false stops at `obj`: the object's own patches are built,
    /// and the paths of the children are still recorded — which is
    /// [`iterdoc.DiffIter.processItem`]'s job, not `recursive`'s
    /// (`iter/doc.rs:125-128`). The caller owns the result.
    pub fn diffObj(
        self: *Document,
        gpa: Allocator,
        obj: ExId,
        before: []const ChangeHash,
        after: []const ChangeHash,
        recursive: bool,
    ) DiffError!patchesmod.Patches {
        // Both clocks are owned here; the diff walk borrows them.
        var before_clock = try self.clockAtHeads(gpa, before);
        defer before_clock.deinit();
        var after_clock = try self.clockAtHeads(gpa, after);
        defer after_clock.deinit();
        return self.diffClocks(gpa, obj, before_clock, after_clock, after, recursive);
    }

    /// The walk [`diffObj`](Self.diffObj) and [`commit`](Self.commit) share: a
    /// [`DiffIter`](iter/doc.zig) over one `ClockRange`, and the patches its
    /// events make.
    ///
    /// **`after` is the point in history the patches resolve against**, and it
    /// is not only what [`PatchDoc`] is built over: [`PatchLog.makePatches`]
    /// reads it back through `doc.clockAt(heads)` (`patches.zig`:2965`) and
    /// answers **null** — an unscoped read of the present — when the log names
    /// no heads. Every read the patch layer makes on an exposed object's
    /// behalf goes through that clock ([`ExposeQueue.flushObj`],
    /// `patches.zig`:2164-2204), so a log without heads answers with the
    /// document's *present* rather than with the state the diff is asking for.
    /// Upstream sets the field on both routes (`automerge.rs`:1424`, `:1455`).
    ///
    /// The case that shows what is at stake is upstream's
    /// `reverse_diff_of_replaced_lists_applies_to_hydrated_value`
    /// (`test.rs`:449-474`), and its own comment names the invariant: "A
    /// reverse diff must not emit a deletion against the empty replacement list
    /// in the hydrated value." Going backwards over a change that replaced two
    /// lists, both replacements are put with `expose`, and the `ExposeQueue`
    /// answers each with its whole content **at `after`** — empty at both —
    /// and skips the per-row events the walk recorded underneath
    /// (`patches.zig`:2079-2082`). Answer with the *present* instead and the
    /// queue supplies whatever the hidden old objects hold since, which is
    /// exactly the extra patch that test's `apply` then puts into a mirror that
    /// is not supposed to have it.
    fn diffClocks(self: *Document, gpa: Allocator, obj: ExId, before_clock: clockmod.Clock, after_clock: clockmod.Clock, after: []const ChangeHash, recursive: bool) DiffError!patchesmod.Patches {
        const typ = try self.objectType(obj);
        var view = PatchDoc.init(gpa, self, after_clock);
        defer view.deinit();
        var log: patchesmod.PatchLog = .active(gpa);
        defer log.deinit();
        const handle = view.handle();
        var iter = try iterdoc.DiffIter(ChangeOp).init(
            gpa,
            &handle,
            obj,
            typ,
            .{ .diff = .{ .before = before_clock, .after = after_clock } },
            recursive,
        );
        defer iter.deinit();
        // Reuse the map this walk already built instead of dropping its owner.
        log.pathHint(try iter.log(&log));
        // **After the walk and before the build, which is upstream's order**
        // (`automerge.rs`:1423-1425`, `:1454-1456`). The copy is the log's own:
        // [`PatchLog.deinit`](patches.zig) frees `heads` with the allocator the
        // log was made with, which is this `gpa`.
        log.heads = try gpa.dupe(ChangeHash, after);
        return log.makePatches(PatchDoc, &view);
    }

    /// The patches this document has recorded since its cursor was last moved,
    /// and then moves the cursor
    /// ([`AutoCommit::diff_incremental`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:340-355`).
    ///
    /// **This is the method the cursor exists for.** [`Document.diff`] walks the
    /// whole op set between two heads; this one reads the events
    /// [`Document.applyChanges`] recorded into `patch_log` as the document
    /// moved, so its cost is the size of what changed rather than the size of
    /// the history. The cursor move is not an optimisation afterwards — it is
    /// half of what makes the *next* call answer "nothing changed", which is
    /// what the second half of the method's own contract is
    /// (`autocommit.rs:354`).
    ///
    /// The caller owns the result.
    pub fn diffIncremental(self: *Document, gpa: Allocator) DiffError!patchesmod.Patches {
        var patches = try self.diffInner(
            gpa,
            .root,
            self.diff_cursor.items,
            // **`viewHeads`, not the graph's heads** — `diff_incremental`
            // ends in `self.get_heads()` (`autocommit.rs:340-355`), and on an
            // isolated document that is the isolation. See
            // [`Document.viewHeads`].
            self.viewHeads(),
            true,
        );
        errdefer patches.deinit();
        try self.updateDiffCursor();
        return patches;
    }

    /// The heads the next incremental diff starts from
    /// ([`AutoCommit::diff_cursor`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:209-212`). The caller owns the result.
    pub fn diffCursor(self: *const Document, gpa: Allocator) Error![]ChangeHash {
        const out = try gpa.alloc(ChangeHash, self.diff_cursor.items.len);
        errdefer gpa.free(out);
        @memcpy(out, self.diff_cursor.items);
        return out;
    }

    /// Starts recording, drops whatever was recorded, and puts the cursor at
    /// the document's present
    /// ([`AutoCommit::update_diff_cursor`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:199-206`).
    ///
    /// **A document with no changes is left alone**, which is upstream's
    /// `if !heads.is_empty()` (`autocommit.rs:202`): a cursor at "nothing" is
    /// not a cursor, and setting one would make the next incremental diff
    /// report the empty state as an addition.
    pub fn updateDiffCursor(self: *Document) Error!void {
        // **`viewHeads` for the same reason**, `autocommit.rs:202`.
        const heads = self.viewHeads();
        if (heads.len == 0) return;
        try self.diff_cursor.ensureTotalCapacity(self.gpa, heads.len);
        // `autocommit.rs:203-205`, in order: the log is turned **on** first, and
        // `truncate` clears what was there and leaves it on. Upstream does both
        // because `truncate` sets the flag itself; keeping the pair means the
        // intent survives a change to either.
        self.patch_log.setActive(true);
        self.patch_log.truncate();
        self.diff_cursor.clearRetainingCapacity();
        self.diff_cursor.appendSliceAssumeCapacity(heads);
    }

    /// Forgets the cursor and stops recording
    /// ([`AutoCommit::reset_diff_cursor`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:185-189`).
    ///
    /// **Worth calling when the caller is done**, and that is upstream's own
    /// advice (`autocommit.rs:191-198`): recording costs an allocation per
    /// applied row for as long as the log is active.
    pub fn resetDiffCursor(self: *Document) void {
        self.patch_log.deinit();
        self.patch_log = .inactive(self.gpa);
        self.diff_cursor.clearRetainingCapacity();
    }

    /// The patches a caller's own log has recorded
    /// ([`AutoCommit::make_patches`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:214-217`, over `automerge.rs:1005-1007`).
    ///
    /// **`log` is the caller's and not `self.patch_log`**, exactly as upstream:
    /// this is the escape hatch for a log fed by
    /// [`batchmod.applyChangesBatchToSink`] directly. The caller owns the
    /// result. Rendering does not migrate or reject the actor table, matching
    /// Rust `patch_log.rs:505-529`; indexed IDs are exported through this document.
    pub fn makePatches(self: *const Document, log: *patchesmod.PatchLog) patchesmod.MakeError!patchesmod.Patches {
        var view = PatchDoc.init(log.gpa, self, null);
        defer view.deinit();
        return log.makePatches(PatchDoc, &view);
    }

    /// Materializes the borrowed log's current view through the private patch
    /// reader before the log begins recording at another head set.
    pub fn finishCurrentPatchView(
        self: *const Document,
        log: *patchesmod.PatchLog,
        heads: []const ChangeHash,
    ) patchesmod.MakeError!void {
        var view = PatchDoc.init(log.gpa, self, null);
        defer view.deinit();
        try log.finishCurrentView(PatchDoc, &view, heads);
    }

    /// The clock a set of heads names ([`Automerge::clock_range`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
    /// `automerge.rs:1230-1234`, one half of it).
    ///
    /// **Not `@constCast` for its own sake**: [`ChangeGraph.clockAt`] is
    /// `&mut self` upstream and here because it grows a clock as it walks, and
    /// a diff reads the graph without changing the document.
    fn clockAtHeads(self: *const Document, gpa: Allocator, heads: []const ChangeHash) Error!clockmod.Clock {
        return @constCast(&self.graph).clockAt(gpa, heads);
    }

    /// The facade's isolated read cone, or null for the unscoped present
    /// (`autocommit.rs:794-814`). Transaction reads use their own write clock.
    /// Clock buffers are document-owned and remain valid until mutation; selecting
    /// a different historical cone does not release a previously returned walk.
    pub fn readScope(self: *Document, gpa: Allocator) Error!?*const clockmod.Clock {
        const at = self.isolation orelse return null;
        if (self.graph.headsAreCurrent(at)) return null;
        return try self.clockAtScope(gpa, at);
    }

    /// The committed cone at explicit `heads`, even when they equal current heads.
    /// Keys and clock buffers are document-owned and reused without allocation on
    /// repeated reads. Selecting other heads preserves previously returned walks;
    /// mutation invalidates both clocks and walks. Pool growth preserves pointers.
    pub fn clockAtScope(
        self: *Document,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error!*const clockmod.Clock {
        _ = gpa;
        for (self.historical_scopes.items) |*scope| {
            if (sameHashList(scope.heads, heads)) return scope.clock;
        }
        const copied = try self.gpa.dupe(ChangeHash, heads);
        errdefer self.gpa.free(copied);
        const clock = try self.gpa.create(clockmod.Clock);
        errdefer self.gpa.destroy(clock);
        clock.* = try self.clockAtHeads(self.gpa, heads);
        errdefer clock.deinit();
        try self.historical_scopes.append(self.gpa, .{ .heads = copied, .clock = clock });
        return clock;
    }

    /// The three cases [`diffIncremental`] and [`diff`] resolve between
    /// ([`AutoCommit::diff_inner`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    /// `autocommit.rs:259-305`).
    ///
    /// The facade owns its separate single-entry diff cache. This shared helper
    /// resolves the remaining patch sources without creating another cache:
    ///
    /// 1. **the recorded log** — `after` is the present, `before` is the cursor
    ///    and the log is active (`autocommit.rs:276-286`);
    /// 2. **the whole current state** — `before` is empty and `after` is the
    ///    present (`autocommit.rs:288-296`), which reads **unscoped** because
    ///    `patch_log.heads` is left `None` (`autocommit.rs:293`);
    /// 3. **the general walk** — [`diffObj`] (`autocommit.rs:297-302`).
    pub fn diffInner(
        self: *Document,
        gpa: Allocator,
        obj: ExId,
        before: []const ChangeHash,
        after: []const ChangeHash,
        recursive: bool,
    ) DiffError!patchesmod.Patches {
        if (self.graph.headsAreCurrent(after) and
            sameHashList(before, self.diff_cursor.items) and
            self.patch_log.isActive())
        {
            var view = PatchDoc.init(gpa, self, null);
            defer view.deinit();
            return self.patch_log.makePatches(PatchDoc, &view);
        }
        if (before.len == 0 and self.graph.headsAreCurrent(after)) {
            var view = PatchDoc.init(gpa, self, null);
            defer view.deinit();
            const typ = try self.objectType(obj);
            var log: patchesmod.PatchLog = .active(gpa);
            defer log.deinit();
            const handle = view.handle();
            // `ClockRange::default()` is `autocommit.rs:291`'s
            // `ClockRange::default()`: **no heads, so the present**, which is
            // what makes every row an addition.
            var iter = try iterdoc.DiffIter(ChangeOp).init(gpa, &handle, obj, typ, .now(), recursive);
            defer iter.deinit();
            log.pathHint(try iter.log(&log));
            return log.makePatches(PatchDoc, &view);
        }
        return self.diffObj(gpa, obj, before, after, recursive);
    }
};

/// What a diff can raise ([`iterdoc.DiffError`]).
///
/// **The union the three leaf readers and the patch layer already agree on**,
/// so one diff has one error set: a column refusal, a walk refusal, a document
/// refusal and an invariant check.
pub const DiffError = iterdoc.DiffError;

/// Two head lists are the same list of hashes.
fn sameHashList(a: []const ChangeHash, b: []const ChangeHash) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!ChangeHash.eql(x, y)) return false;
    }
    return true;
}

/// A value the patch layer records, from a value a reader saw
/// ([`ValueRef::hydrate`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs),
/// `op_set2/types.rs:694-705`).
fn patchValueOf(v: optypes.ValueRef) batchmod.PatchValue {
    return switch (v) {
        .object => |o| .{ .object = o },
        .scalar => |s| .{ .scalar = s },
    };
}

/// A walk's refusal, as the patch layer's narrower one.
///
/// [`patchesmod.PatchLog`]'s readers return [`Error`] and nothing else, so a
/// refusal that arrives from a column has to be named as one of them. **The
/// mapping is a narrowing and loses the distinction**, which is the honest cost
/// of `patches.zig`'s `try it.next()` sitting inside an `Error!`-returning
/// function; each arm keeps a name a caller can act on and everything else
/// becomes [`Error.Fail`], upstream's `AutomergeError::Fail` and the port's
/// "a generic failure with no more specific variant".
fn patchReadError(e: itermap.ReadError) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // A row's identity or its key does not name one (`op_iter.rs:69-75`).
        error.InvalidOpId, error.InvalidKey, error.MissingKey => error.InvalidOp,
        // A column ran out before the walk did, or a value's bytes do not
        // decode to its declared type.
        error.MissingValue, error.InvalidValue => error.InvalidValueType,
        else => error.Fail,
    };
}

/// The private patch-reader adapter over a raw Document.
///
/// Supplies indexed patch walks without adding patch-specific getters to the
/// public ReadDoc interface. Object type resolution remains Error!ObjType; the
/// expose queue may treat only NotAnObject as absent and propagates other errors.
///
/// **The arena is the whole of the lifetime story.** Every payload the patch
/// layer reads is *borrowed* here and *owned* by the reader that produced it:
/// a text span's buffer belongs to the spans fold
/// ([`iterspans.SpanInternal`](iter/spans.zig)) and a clock belongs to the
/// change graph. Upstream's readers hand out `String`s and `Vec<u32>`s that
/// drop themselves; here they are heap blocks, and the patch layer **has no
/// hook to release them** — it writes `var it = doc.spans(id, clock)` and
/// iterates the value it gets back (`patches.zig`:1895-1908`). So the readers
/// this adapter builds are given the **arena** as their allocator and
/// [`deinit`](PatchDoc.deinit) — which every caller runs around
/// `makePatches` — releases all of it at once. Nothing is copied and nothing
/// leaks.
const PatchDoc = struct {
    /// The allocator the arena is taken with.
    gpa: Allocator,
    /// The document these nine names read.
    doc: *const Document,
    /// Every borrowed payload the patch layer reads lives here, and dies in
    /// [`deinit`](PatchDoc.deinit).
    arena: std.heap.ArenaAllocator,
    /// Borrowed cone supplied by a diff caller. Its buffers outlive this adapter.
    /// With no supplied cone, explicit heads resolve through the document's
    /// stable historical pool; the adapter never invents an empty clock.
    clock: ?clockmod.Clock,

    fn init(gpa: Allocator, doc: *const Document, clock: ?clockmod.Clock) PatchDoc {
        return .{ .gpa = gpa, .doc = doc, .arena = .init(gpa), .clock = clock };
    }

    fn deinit(self: *PatchDoc) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The handle the walks are built over ([`Doc.iter/doc.rs`:44`).
    fn handle(self: *const PatchDoc) iterdoc.Doc(ChangeOp) {
        return .init(@constCast(&self.doc.ops), self.doc.textEncoding());
    }

    pub fn textEncoding(self: *const PatchDoc) TextEncoding {
        return self.doc.textEncoding();
    }

    /// Exports through the document's actor table. Retained log suffixes can
    /// name a missing slot; report it at rendering rather than inventing an actor
    /// or rejecting the successful application (`op_set2/op_set.rs:1054-1060`).
    pub fn exportPatchId(self: *const PatchDoc, id: OpId) Error!ExId {
        if (id.eql(OpId.root)) return .root;
        if (id.actor >= self.doc.ops.actors.items.len) return error.InvalidActorIndex;
        return self.doc.idToExid(id);
    }

    /// Uses the raw document's typed, byte-authoritative object resolution.
    pub fn objectType(self: *const PatchDoc, id: ExId) Error!ObjType {
        return self.doc.objectType(id);
    }

    pub fn objectParent(self: *const PatchDoc, id: ExId) ?ExId {
        return self.doc.objectParent(id);
    }

    /// Borrows the caller's resolved cone or a stable document-owned head clock.
    pub fn clockAtScope(
        self: *const PatchDoc,
        gpa: Allocator,
        heads: []const ChangeHash,
    ) Error!*const clockmod.Clock {
        if (self.clock) |*clock| return clock;
        return @constCast(self.doc).clockAtScope(gpa, heads);
    }

    pub fn actorList(self: *const PatchDoc) []const ActorId {
        return self.doc.ops.actors.items;
    }

    pub fn mapRangeFor(self: *const PatchDoc, id: ExId, clock: ?clockmod.Clock) MapSlice {
        const set = @constCast(&self.doc.ops);
        const rows = set.mapRange(id, null, null) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        const iter = itermap.MapRange(ChangeOp).init(set, rows, clock) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        return .{ .iter = iter, .failure = null };
    }

    pub fn listRangeFor(self: *const PatchDoc, id: ExId, clock: ?clockmod.Clock) ListSlice {
        const set = @constCast(&self.doc.ops);
        const rows = set.listRange(id) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        // **`.{}` is the whole object**: `IndexRange` defaults to `start = 0` and
        // `end = null`, which is "the end of the object"
        // (`list_range.zig`:136-140`), and it is what upstream's `flush_obj`
        // asks for — `doc.list_range_for` takes no range (`patch_log.rs`:754`).
        const iter = iterlist.ListRange(ChangeOp).init(set, rows, clock, .{}) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        return .{ .iter = iter, .failure = null };
    }

    /// **The reader is built with the arena, and that is not a shortcut**: see
    /// this type's doc comment on the lifetime.
    /// [`iterspans.SpansInternal`] is the internal reader and not
    /// [`iterspans.Spans`] because the patch layer needs the run's **index**
    /// ([`patchesmod.Span`](patches.zig), `patches.zig`:179-183`), and
    /// upstream's `flush_obj` reads the index off `SpanInternal` too
    /// (`patch_log.rs`:736-740`).
    pub fn spans(self: *const PatchDoc, id: ExId, clock: ?clockmod.Clock) SpanSlice {
        const set = @constCast(&self.doc.ops);
        const arena = @constCast(&self.arena).allocator();
        const rows = set.spans(id) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        const iter = iterspans.SpansInternal(ChangeOp).init(
            arena,
            set,
            rows,
            clock,
            self.doc.textEncoding(),
        ) catch |e| {
            return .{ .iter = undefined, .failure = patchReadError(e) };
        };
        return .{ .iter = iter, .failure = null };
    }

    /// One visible map register, as the patch layer reads it
    /// ([`patchesmod.MapItem`](patches.zig), `patch_log.rs:767-775`).
    ///
    /// **The key and the value are borrowed from the document** and are valid
    /// until the next mutation, which is upstream's `MapRangeItem<'a>`; the
    /// patch layer copies before it keeps anything.
    const MapSlice = struct {
        iter: itermap.MapRange(ChangeOp),
        /// The first refusal this walk saw, kept so that the walk can hand
        /// back an [`Error`] **without a fallible constructor**: the patch layer
        /// writes `var it = doc.mapRangeFor(id, clock)` and reads it as a value
        /// (`patches.zig`:1928`), so there is nowhere to put an error but here.
        failure: ?Error,

        pub fn next(self: *MapSlice) Error!?patchesmod.MapItem {
            if (self.failure) |e| return e;
            const got = (self.iter.next()) catch |e| {
                self.failure = patchReadError(e);
                return self.failure.?;
            };
            const item = got orelse return null;
            return .{
                .key = item.key,
                .value = patchValueOf(item.value),
                .id = item.maybe_exid.id,
                .conflict = item.conflict,
            };
        }
    };

    /// One visible list element, as the patch layer reads it
    /// ([`patchesmod.ListItem`](patches.zig), `patch_log.rs:754-765`).
    const ListSlice = struct {
        iter: iterlist.ListRange(ChangeOp),
        failure: ?Error,

        pub fn next(self: *ListSlice) Error!?patchesmod.ListItem {
            if (self.failure) |e| return e;
            const got = (self.iter.next()) catch |e| {
                self.failure = patchReadError(e);
                return self.failure.?;
            };
            const item = got orelse return null;
            return .{
                .index = item.index,
                .value = patchValueOf(item.value),
                .id = item.maybe_exid.id,
                .conflict = item.conflict,
            };
        }
    };

    /// One text span, as the patch layer reads it
    /// ([`patchesmod.Span`](patches.zig), `patch_log.rs:736-748`).
    ///
    /// **`held` is kept and costs nothing.** The mark set is handed out as a
    /// `?*const MarkSet` — a **pointer** into the span the fold is building
    /// (`patches.zig`:188-188`) — so the span itself has to outlive the call it
    /// is read in. Every byte it owns is arena memory, so holding the last one
    /// until the walk ends is free and needs no `deinit` hook the patch layer
    /// does not have.
    const SpanSlice = struct {
        iter: iterspans.SpansInternal(ChangeOp),
        failure: ?Error,
        held: ?iterspans.SpanInternal(ChangeOp) = null,

        pub fn next(self: *SpanSlice) Error!?patchesmod.Span {
            if (self.failure) |e| return e;
            self.held = (self.iter.next()) catch |e| {
                self.failure = patchReadError(e);
                return self.failure.?;
            };
            if (self.held) |*span| {
                return switch (span.*) {
                    .text => |*t| .{ .text = .{
                        .text = t.text,
                        .index = t.index,
                        .marks = if (t.marks) |*m| m else null,
                    } },
                    // **`conflict` is false**, because a text span reports no
                    // register conflict and upstream's `flush_obj` ignores the
                    // flag it carries (`patch_log.rs`:742`).
                    .obj => |o| .{ .obj = .{
                        .id = o.id.id,
                        .index = o.index,
                        .conflict = false,
                    } },
                };
            }
            return null;
        }
    };
};

/// The encoding a document gets when the caller does not choose one:
/// [`TextEncoding.unicode_code_point`].
///
/// That is upstream's `TextEncoding::platform_default()`
/// ([`text_value.rs:12-22`](../../github-automerge-automerge/rust/automerge/src/text_value.rs))
/// with **neither** indexing feature enabled — the third arm of its `cfg_if!`
/// at `:18-20`, documented at `:11` as "Unicode code points if neither feature
/// is enabled". It is **not** what the `utf8-indexing` feature selects: that
/// arm answers `Utf8CodeUnit` (`:14-15`). **This doc comment said the
/// opposite until the C suite's text cases were run, and the mistake is what
/// put `automerge-c`'s indices in the wrong unit**; see
/// [`c.doc.cTextEncoding`](../c/doc.zig), which is what the C ABI uses.
pub fn defaultTextEncoding() TextEncoding {
    return TextEncoding.platformDefault();
}

/// Turns a parser's refusal into the document API's, so an entry point whose
/// error set is [`Error`] can report what a column reader found.
///
/// [`Error.Load`] is the class upstream gives "the input could not be loaded"
/// ([`error.rs`](../../github-automerge-automerge/rust/automerge/src/error.rs)), and
/// the survey's four places where upstream *silently* drops an unknown
/// dependency are the reason this is a conversion and not a suppression: a
/// dependency a document cannot resolve must be an error, not a document that
/// answers without it.
fn opError(e: ParseError) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // `MissingActor` is the parser's word for it; the document's is an
        // actor index that names nothing (`InvalidActorIndex`).
        error.MissingActor => error.InvalidActorIndex,
        error.MissingColumn => error.Load,
        error.UnexpectedEnd => error.Load,
        error.Truncated => error.Load,
        else => error.Load,
    };
}

/// The first slot of `list` that equals `hash`, or null.
fn indexOfHash(list: []const ChangeHash, hash: ChangeHash) ?usize {
    for (list, 0..) |have, i| {
        if (have.eql(hash)) return i;
    }
    return null;
}

/// Frees the collector's metadata array.
///
/// **The dependency slices inside it are not freed here.** A `BuildMeta`'s
/// `deps` borrows from whoever built the meta: for a document chunk it is the
/// same slice the [`GraphNode`] holds, and for a graph walk it is an array the
/// caller frees where it made it. One owner, not two.
fn freeMetas(gpa: Allocator, metas: []BuildMeta) void {
    gpa.free(metas);
}

/// Parses one framed change chunk into a [`Changes`] list
/// ([`storage::Chunk::Change`](../../github-automerge-automerge/rust/automerge/src/storage/chunk.rs) read in
/// [`load::load_changes`](../../github-automerge-automerge/rust/automerge/src/storage/load.rs)).
///
/// A `compressed` chunk is inflated here, because a compressed chunk's checksum
/// covers the **inflated** body and only
/// [`changechunk.parseFramedChunk`](storage/change_chunk.zig) checks it.
///
/// **The change borrows the copy, not the source.** For a plain chunk the
/// source is `c.data`, which points into the caller's bytes and outlives the
/// call; for a compressed chunk it is the buffer `decompressChunk` just
/// allocated, and the `defer` below releases that the moment this function
/// returns. Parsing `source` directly therefore left `Change.bytes` pointing
/// into freed memory, and `test/fixtures/two_change_chunks_compressed.automerge`
/// read it back in `Document.adoptChange` — where the released bytes failed the
/// first LEB128 of the dependency count with `error.Overflow`, which is a
/// refusal with no cause rather than the bug it was.
fn parseOneChange(gpa: Allocator, c: chunkmod.Chunk) ParseError!Changes {
    var out: Changes = .{};
    errdefer out.deinit(gpa);
    var inflated: ?[]u8 = null;
    defer if (inflated) |b| gpa.free(b);
    const source = switch (c.typ) {
        .compressed => blk: {
            inflated = try chunkmod.decompressChunk(gpa, c);
            break :blk inflated.?;
        },
        else => c.data,
    };

    // `Built.body` is the copy the caller frees, so it is also what the change
    // is parsed from: one buffer, owned once, and it lives exactly as long as
    // the `Built` that holds it.
    const body = try gpa.dupe(u8, source);
    errdefer gpa.free(body);
    var change = try changerec.parseChange(body, gpa);
    errdefer change.deinit(gpa);
    try out.items.append(gpa, .{ .body = body, .change = change });
    return out;
}

/// The changes in `list` as plain values, so a caller that owns the bodies can
/// hand them to [`Document.applyChanges`]. The caller owns the returned array;
/// each element borrows its [`Built`]'s body.
fn asChanges(gpa: Allocator, list: []const Built) LoadError![]Change {
    const out = try gpa.alloc(Change, list.len);
    for (list, 0..) |*built, i| out[i] = built.change;
    return out;
}

/// Appends a change as a framed chunk, which is what a saved document stream is
/// made of and exactly what [`Document.loadIncremental`] reads
/// ([`save_after`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1194-1201).
///
/// **It appends rather than returns a buffer**, because the returned buffer is
/// the caller's to free and there were two callers that did not: the framed
/// chunk is copied into the output and nothing else references it, so an owned
/// return here is one ownership the caller has to remember and a leak on every
/// change it forgets.
fn appendFramed(gpa: Allocator, out: *std.ArrayList(u8), change: Change) Allocator.Error!void {
    const framed = try change.encode(gpa);
    defer gpa.free(framed);
    try out.appendSlice(gpa, framed);
}

/// The heads a list of changes implies: every change that no other one in the
/// list depends on
/// ([`CollectedChanges`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs):908-952).
///
/// **Built in the same order the changes were produced**, which is why the
/// result is the head set rather than a guess: a change's dependencies are all
/// earlier in the list, so a single pass is enough.
fn derivedHeads(gpa: Allocator, changes: *const Changes) ParseError![]ChangeHash {
    var set: std.AutoHashMapUnmanaged(ChangeHash, void) = .empty;
    defer set.deinit(gpa);
    for (changes.items.items) |*built| {
        for (built.change.deps) |dep| _ = set.remove(dep);
        try set.put(gpa, built.change.hash, {});
    }
    var heads = gpa.alloc(ChangeHash, set.count()) catch return error.OutOfMemory;
    errdefer gpa.free(heads);
    var at: usize = 0;
    var it = set.iterator();
    while (it.next()) |entry| {
        heads[at] = entry.key_ptr.*;
        at += 1;
    }
    std.mem.sort(ChangeHash, heads, {}, ChangeHash.lessThan);
    return heads;
}

/// The bytes after a change's op data, or null when it carries none
/// ([`parse_following_header`](../../github-automerge-automerge/rust/automerge/src/storage/change.rs):119-125).
///
/// **A footer this cannot read is no footer.** The author screen uses it to
/// refuse a change, and a footer that cannot be read is not evidence of an
/// author; answering "unknown" rather than "malformed" is what keeps a
/// truncated tail from refusing an otherwise good change.
fn changeFooter(change: Change) ?[]const u8 {
    var in: Input = .init(change.opsBytes());
    const count = in.takeUleb() catch return null;
    // A count larger than the input could hold is caught before the loop, so a
    // hostile header costs one division rather than one iteration per count.
    if (count > in.remaining() / 2) return null;
    var data_len: usize = 0;
    var i: u64 = 0;
    while (i < count) : (i += 1) {
        _ = in.takeUleb() catch return null; // the column's specification
        const len = in.takeUleb() catch return null;
        data_len += std.math.cast(usize, len) orelse return null;
    }
    in.skip(data_len);
    const rest = in.rest();
    if (rest.len == 0) return null;
    return rest;
}

/// Encodes the change graph as the change block of a document chunk
/// ([`ChangeGraphCols::encode`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs):236-272).
///
/// **The time column is signed.** A timestamp before 1970 is a negative delta,
/// and writing it unsigned would change every byte of the document.
fn encodeGraphCols(doc: *const Document, gpa: Allocator) LoadError!OwnedColumns {
    const count = doc.graph.len();
    var pending: std.ArrayList(PendingColumn) = .empty;
    defer {
        freePending(gpa, &pending);
        pending.deinit(gpa);
    }
    var scratch: std.ArrayList(Cell) = .empty;
    defer scratch.deinit(gpa);

    var actors = try gpa.alloc(Cell, count);
    defer gpa.free(actors);
    var seq = try gpa.alloc(Cell, count);
    defer gpa.free(seq);
    var max_op = try gpa.alloc(Cell, count);
    defer gpa.free(max_op);
    var time = try gpa.alloc(Cell, count);
    defer gpa.free(time);
    var messages = try gpa.alloc(Cell, count);
    defer gpa.free(messages);

    var dep_total: usize = 0;
    for (0..count) |i| {
        const node = doc.graph.nodeAt(@intCast(i)) orelse return error.MissingDeps;
        actors[i] = .{ .uint = node.actor };
        // **A `.delta` column is written from signed cells.** `appendDelta`
        // (`encoding.zig:1304-1318`) takes `.int` and `.null_value` and refuses
        // anything else, so `.uint` here is `error.InvalidValue` at save time —
        // and because `graphUint` below reads a delta column as either sign,
        // the reader's leniency is exactly what let this sit. The two halves
        // have to agree on which cells a delta column is made of.
        seq[i] = .{ .int = std.math.cast(i64, node.meta.seq) orelse
            return error.Overflow };
        max_op[i] = .{ .int = std.math.cast(i64, node.meta.max_op) orelse
            return error.Overflow };
        time[i] = .{ .int = node.meta.time };
        messages[i] = if (node.meta.message.len == 0)
            .null_value
        else
            .{ .string = node.meta.message };
        dep_total += node.meta.deps.len;
    }
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.actor_id,
        .actor,
        actors,
    ));
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.seq_id,
        .delta,
        seq,
    ));
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.max_op_id,
        .delta,
        max_op,
    ));
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.time_id,
        .delta,
        time,
    ));
    // **A document whose changes all carry no message writes no message
    // column.** `ChangeGraphCols::encode` says
    // `self.messages.save_to_unless(out, None)`
    // ([`change_graph.rs:246`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    // and `save_to_unless` writes nothing when the column is only that value
    // ([`column.rs:1447-1453`](../../github-automerge-automerge/rust/hexane/src/column.rs)):
    // `if self.is_only(value) { out.len()..out.len() } else { self.save_to(out) }`.
    // An empty range is still a column in the layout, and [`decodeGraphCols`]
    // fills it back in, so the reader needs the rule and the writer needs it.
    var any_message = false;
    for (messages) |cell| {
        if (cell != .null_value) any_message = true;
    }
    if (any_message) {
        try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
            gpa,
            GraphColumn.message_id,
            .string,
            messages,
        ));
    }

    scratch.clearRetainingCapacity();
    for (0..count) |i| {
        const node = doc.graph.nodeAt(@intCast(i)).?;
        try scratch.append(gpa, .{ .uint = node.meta.deps.len });
    }
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.deps_id,
        .group,
        scratch.items,
    ));

    var dep_actors = try gpa.alloc(Cell, dep_total);
    defer gpa.free(dep_actors);
    var at: usize = 0;
    for (0..count) |i| {
        const node = doc.graph.nodeAt(@intCast(i)).?;
        for (node.meta.deps) |dep| {
            const index = doc.graph.hashToIndex(dep) orelse return error.MissingHash;
            dep_actors[at] = .{ .int = std.math.cast(i64, index) orelse return error.Overflow };
            at += 1;
        }
    }
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.deps_id,
        .delta,
        dep_actors,
    ));

    // Change extras are bytes, including an empty footer: metadata tag 7,
    // not Null (change_graph.rs:537-541; op_set2/meta.rs:95-98). Upstream
    // retains the metadata column even when all footers are empty (:254-255).
    var words = try gpa.alloc(Cell, count);
    defer gpa.free(words);
    var footers: std.ArrayList(u8) = .empty;
    defer footers.deinit(gpa);
    for (0..count) |i| {
        const extra = doc.nodeInfo(@intCast(i)).extra;
        words[i] = .{ .uint = value.ValueMeta.init(.bytes, extra.len).raw };
        try footers.appendSlice(gpa, extra);
    }
    try keepColumn(gpa, &pending, try columnarenc.encodeColumn(
        gpa,
        GraphColumn.extra_id,
        .value_metadata,
        words,
    ));
    // **The copy is taken before the append, and given back if it is
    // refused.** Both halves of this column were one `try` inside a struct
    // literal, so an allocator that refused the append leaked the duplicate
    // the literal had already made — the failure the sweep reaches is exactly
    // that one.
    if (footers.items.len != 0) {
        const bytes = try gpa.dupe(u8, footers.items);
        errdefer gpa.free(bytes);
        try pending.append(gpa, .{
            .spec = GraphColumn.extraValueSpec(),
            .bytes = bytes,
        });
    }

    const owned = try finishColumns(gpa, pending.items);
    freePending(gpa, &pending);
    return owned;
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Every test here checks a **behaviour against something else**: a change the
// Rust reference wrote, a hash the reference computed, a document reloaded from
// its own bytes, a second document that reached the same state by a different
// path. Nothing asserts a value the implementation happens to produce.

/// The three actor ids the fixtures and the hand-built document use. They sort
/// in this order, which is what makes actor index 0 the first of them.
const actor_a = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const actor_b = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const actor_c = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3";

/// The corpus directory, relative to the process working directory. Tests run
/// from the build root, which is the package root — the same convention
/// `test/fixtures_test.zig` uses.
const fixture_dir = "test/fixtures";

/// A ceiling on one fixture, so a runaway file cannot exhaust memory.
const max_fixture_bytes = 1 << 20;

/// One operation to build, before it becomes a [`ChangeOp`].
const OpSpec = struct {
    /// The op counter: consecutive within one change, ascending.
    ctr: u32,
    /// The object the op acts on; the root unless a change made one.
    obj: ExId = .root,
    /// What the op does.
    action: Action = .set,
    /// The property it addresses.
    key: KeyRef,
    /// The value it carries.
    value: ScalarValue = .null_value,
    /// Whether it inserts into a sequence rather than overwriting.
    insert: bool = false,
    /// Whether a mark expands before its span.
    expand: bool = false,
    /// The mark's name, or null for a mark end.
    mark: ?[]const u8 = null,
    /// The ops it overwrites or deletes.
    pred: []const OpId = &.{},
};

/// The change chunks the Rust reference wrote for `test/golden/doc.jsonl`, with
/// the hashes it computed for them. **These are the compatibility vectors**:
/// every byte and every hash below came out of the reference implementation.
const reference_change_0 = "856f4a83108741df02d50155cc3152c2401487f1ff7bbb2f089b19710868c9211c0a2bc7c223681dc91b6158dc982cc2" ++ "a4d8d878057b5b2fe31d3c89831dbfee6b3e9c7f9d227afffdf9ceec53d92a72ca39bf184dc6d39b6bb91b3f148f8bda" ++ "be726bc002900348001606b93390143016e0119081138c2150ea8643429624aea357ebd76d84f436ea21c275665bd676" ++ "a35a0f9661f712b5b155134e83855c9688857aeba887a124e6f0c928161fc413b85987fbabb7025db98b61abcdb3ce43" ++ "532ebdf6711ff02fbf1dacd4fb30df87c6571bad238eeb5a2bb9041323cde80f";
const reference_change_0_hash = "108741df42e454f28b539956f88a914977740e6e05305b4d6bd4a06564e88a3a";
const reference_change_1 = "856f4a83a368e225015b01108741df42e454f28b539956f88a914977740e6e05305b4d6bd4a06564e88a3a0fa1a1a1a1" ++ "a1a1a1a1a1a1a1a1a1a1a1021a80e2cfaa0605657874726100061507340142025602570170027f056578747261017f01" ++ "7f14017f00";
const reference_change_1_hash = "a368e2256d347ffcdc03acd9bc96900a0e8031067a7f1d6e1adb5ff82c851c42";

/// The 446-byte document the reference wrote for `test/golden/doc.jsonl`: the
/// document whose two changes are the two above.
const reference_document = "856f4a83200aee1f00b303020fa1a1a1a1a1a1a1a1a1a1a1a1a1a1a110b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b20242d8" ++ "cc0aaaeddbe3919a88d2d99fb85659052fd6b87149cace565ba25543c95be06962e9d5f192015af2985c495518856eb1" ++ "592def42fa367d89787d99dc84c908010403041304230835114004430256020e01040208110a130e153c210923143403" ++ "420d5617574080010781010283010302007f0102017f7f7f1902017f80e2cfaa0602007d0462617365046c6566740572" ++ "696768747f0002010200030700071400000705020b0804140008040000010a00000400077e000303017e7a0909010004" ++ "020466726f6d7b046c697374036d61700a6f6e6c795f72696768740474657874057469746c6500100207636f756e7465" ++ "727e0464726f70046b6565707e000102007f011600781a006812076d790204017f020a017c03027f7e07100402017c02" ++ "00010412017f0502017e4656020078140096021436850102130b167c181476466c65667472696768742a7a6175746f6d" ++ "65726765206f7261636c657f74776f0000000000000c400768656c6c6f20776f726c64000564726f707065646b657074" ++ "17007c0100010002007e18010102";

/// One corpus file and what loading it through a [`Document`] must do.
///
/// **Spelled out here rather than read from `test/fixtures/manifest.zig`**
/// because a library file may not import from `test/`: `src/doc.zig` is part of
/// the published module, and reaching out of `src/` would make every consumer of
/// `zautomerge` need the test corpus. The names and the outcomes are the
/// manifest's, and `zig build test` runs `test/fixtures_test.zig` alongside,
/// which checks the corpus and its manifest agree.
const CorpusCase = struct {
    name: []const u8,
    must_load: bool,
};

const corpus = [_]CorpusCase{
    .{ .name = "64bit_obj_id_change.automerge", .must_load = false },
    .{ .name = "64bit_obj_id_doc.automerge", .must_load = false },
    .{ .name = "action-is-48.automerge", .must_load = false },
    .{ .name = "broken_zero_width_mark.automerge", .must_load = false },
    .{ .name = "counter_value_has_incorrect_meta.automerge", .must_load = false },
    .{ .name = "counter_value_is_ok.automerge", .must_load = true },
    .{ .name = "counter_value_is_overlong.automerge", .must_load = false },
    .{ .name = "crash-da39a3ee5e6b4b0d3255bfef95601890afd80709", .must_load = false },
    .{ .name = "incorrect_max_op.automerge", .must_load = false },
    .{ .name = "interop-exemplar", .must_load = true },
    .{ .name = "invalid_deflate_stream.automerge", .must_load = false },
    .{ .name = "missing_actor.automerge", .must_load = false },
    .{ .name = "overflow_in_length.automerge", .must_load = false },
    .{ .name = "too_many_deps.automerge", .must_load = false },
    .{ .name = "too_many_ops.automerge", .must_load = false },
    .{ .name = "two_change_chunks.automerge", .must_load = true },
    .{ .name = "two_change_chunks_compressed.automerge", .must_load = true },
    .{ .name = "two_change_chunks_out_of_order.automerge", .must_load = true },
};

/// `specs` as [`ChangeOp`]s for the actor at `actor`.
fn buildOps(gpa: Allocator, actor: ActorIdx, specs: []const OpSpec) ![]ChangeOp {
    const ops = try gpa.alloc(ChangeOp, specs.len);
    var made: usize = 0;
    errdefer {
        for (ops[0..made]) |*op| op.deinit(gpa);
        gpa.free(ops);
    }
    for (specs, 0..) |spec, i| {
        ops[i] = try ChangeOp.init(
            gpa,
            OpId.init(spec.ctr, actor),
            spec.obj,
            spec.action,
            spec.key,
            spec.value,
            spec.insert,
            spec.expand,
            spec.mark,
            spec.pred,
        );
        made += 1;
    }
    return ops;
}

/// Interns `actor` and encodes `ops` as one change, **without applying it**.
///
/// This is the path a peer's change and a local commit both take: encode to
/// bytes, then hash the bytes. It is the only way to build a document before the
/// transaction slice exists.
fn handChange(
    doc: *Document,
    gpa: Allocator,
    actor: []const u8,
    seq: u64,
    start_op: u64,
    deps: []const ChangeHash,
    author: ?[]const u8,
    ops: []const ChangeOp,
) !Built {
    const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
    var footer: std.ArrayList(u8) = .empty;
    defer footer.deinit(gpa);
    try encodeAuthorFooter(gpa, &footer, author);
    return encodeOneChange(gpa, doc.ops.actors.items, .{
        .actor = idx,
        .seq = seq,
        .start_op = start_op,
        .max_op = start_op + ops.len - 1,
        .time = 1_700_000_000,
        .message = &.{},
        .deps = deps,
        .footer = footer.items,
    }, ops);
}

/// [`handChange`] followed by the apply, which is what a peer does with it.
fn applyHandChange(
    doc: *Document,
    gpa: Allocator,
    actor: []const u8,
    seq: u64,
    start_op: u64,
    deps: []const ChangeHash,
    author: ?[]const u8,
    ops: []const ChangeOp,
) !ChangeHash {
    var built = try handChange(doc, gpa, actor, seq, start_op, deps, author, ops);
    defer built.deinit(gpa);
    _ = try doc.applyChanges(gpa, &.{built.change});
    return built.change.hash;
}

/// One more key on the root map, by `actor`, as a change of its own.
fn addKeyChange(
    doc: *Document,
    gpa: Allocator,
    actor: []const u8,
    seq: u64,
    ctr: u32,
    key: []const u8,
    deps: []const ChangeHash,
) !ChangeHash {
    const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
    const specs = [_]OpSpec{
        .{ .ctr = ctr, .key = KeyRef.fromStr(key), .value = .{ .str = "x" } },
    };
    const ops = try buildOps(gpa, idx, &specs);
    defer freeChangeOps(gpa, ops);
    return applyHandChange(doc, gpa, actor, seq, ctr, deps, null, ops);
}

/// A document with a map, a list, a text object, a delete, a mark, and a second
/// actor that inserts into the first actor's list and writes into its map — so
/// the change-op columns carry more than one actor.
fn buildSample(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const b = try doc.putActorRef(gpa, .{ .bytes = actor_b });
    try testing.expectEqual(@as(ActorIdx, 0), a);
    try testing.expectEqual(@as(ActorIdx, 1), b);

    const list_id = ExId{ .id = OpId.init(1, a) };
    const text_id = ExId{ .id = OpId.init(2, a) };
    const map_id = ExId{ .id = OpId.init(3, a) };
    const fourth = OpId.init(4, a);
    const fifth = OpId.init(5, a);
    const sixth = OpId.init(6, a);
    const seventh = OpId.init(7, a);
    const eighth = OpId.init(8, a);

    const specs_a = [_]OpSpec{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr("list") },
        .{ .ctr = 2, .action = .make_text, .key = KeyRef.fromStr("text") },
        .{ .ctr = 3, .action = .make_map, .key = KeyRef.fromStr("map") },
        .{ .ctr = 4, .key = KeyRef.fromStr("hello"), .value = .{ .str = "world" } },
        .{ .ctr = 5, .obj = list_id, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = "a" } },
        .{ .ctr = 6, .obj = list_id, .key = KeyRef.fromElemId(ElemId.fromOpId(fifth)), .insert = true, .value = .{ .str = "b" } },
        .{ .ctr = 7, .obj = text_id, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = "hi" } },
        .{ .ctr = 8, .obj = text_id, .key = KeyRef.fromElemId(ElemId.fromOpId(seventh)), .insert = true, .value = .{ .str = "!" } },
        // **Both mark anchors are inserts, and that is the reference's own
        // spelling.** `Transaction.mark` reaches `do_insert`
        // ([`transact.zig:837-868`](transact.zig)), which builds a
        // `TxOp.insertOp` — upstream's `TxOp::insert`, the one constructor
        // that hard-codes `insert: true` (`op_set2/op.rs:330-357`). The only
        // constructor that pairs `insert: false` with a `Seq` key is
        // `TxOp::list` (`op.rs:261-292`), reached from `local_list_op`
        // ([`inner.rs:495-558`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
        // which resolves a put or a delete on a sequence **index** and is
        // never given a mark. So `insert = false` on a `mark` is a shape the
        // reference cannot write, and it is not a harmless one: an insert's
        // register key is its *own* element (`elemid_or_key`,
        // `op.rs:1040-1046`), so an insert opens a register of its own, while
        // a non-insert keeps the element it was placed after. A `mark` written
        // the second way lands **inside the register of the insert it
        // annotates**, which puts two rows in one register where the
        // reference puts one — and the index then disagrees with itself:
        // `Columns::splice` writes `top = visible` for every row it is handed
        // (`columns.rs:478-482`), so both are top, while the rebuild on load
        // marks only the **last** visible row of a register
        // (`IndexBuilder::flush`, `op_set2/op_set/index.rs:159-176`). The
        // round trip then reports `group_mismatch`, which is the fixture
        // failing to say what the reference says, not the index failing.
        // Measured against the reference rather than reasoned about: the
        // oracle's `sample` subcommand builds the same operation sequence
        // through the reference's **own public writer** — `put_object` ×3,
        // two list inserts, two text splices, `mark(text, {2, 3}, None,
        // "bold", 0u64)`, a delete, two puts, committed by `ACTOR_A`, then
        // three more by `ACTOR_B` — and answers the same document: text
        // `"hi!"`, one `bold` mark over `[2, 3)` with value `0`, `hello` =
        // `"again"`, `only_b` = `"b"`, `list` = `["b", "c"]`, `map` =
        // `{in_map: "yes"}`. The oracle's `loadhex` subcommand then reads the
        // bytes **this fixture encodes** and reports that same document, so
        // the fixture is a document the reference accepts and agrees with.
        //
        // **The mark's end carries a null value, and that is upstream's
        // spelling**: `OpType::MarkEnd` decomposes to
        // `(Action::Mark, ScalarValue::Null, expand, None)`
        // ([`types.rs:428`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs)),
        // and only `MarkBegin` carries a value (`types.rs:422-427`). The end's
        // `MarkIndexBuilder` is `End(self.id.prev())` and reads no value
        // (`op.rs:199`), so this changes the fixture's bytes and nothing a
        // caller can observe.
        //
        // **The mark's end is anchored after the text, not on the same element
        // as its begin.** Both anchored to `seventh` they sit at one sequence
        // position and the mark spans zero graphemes, which is a mark the
        // reference does not report: `calculate_marks_fast` only adds a run
        // when `seq > start` (`op_set2/op_set.rs:997`). Measured on the
        // reference, `mark(obj, {start:0, end:0})` over a 2-grapheme text
        // answers `marks() == 0`, before and after a save and reload, and
        // `mark(0, 2)` answers one mark over `[0, 2)`. So the fixture has to
        // express a mark that *covers* text for one to be the right answer.
        .{ .ctr = 9, .obj = text_id, .key = KeyRef.fromElemId(ElemId.fromOpId(seventh)), .insert = true, .action = .mark, .mark = "bold", .value = .{ .uint = 0 } },
        .{ .ctr = 10, .obj = text_id, .key = KeyRef.fromElemId(ElemId.fromOpId(eighth)), .insert = true, .action = .mark, .value = .null_value },
        .{ .ctr = 11, .obj = list_id, .key = KeyRef.fromElemId(ElemId.fromOpId(fifth)), .action = .delete, .pred = &.{fifth} },
        .{ .ctr = 12, .key = KeyRef.fromStr("hello"), .value = .{ .str = "again" }, .pred = &.{fourth} },
    };
    const ops_a = try buildOps(gpa, a, &specs_a);
    defer freeChangeOps(gpa, ops_a);
    const h1 = try applyHandChange(&doc, gpa, actor_a, 1, 1, &.{}, null, ops_a);

    const specs_b = [_]OpSpec{
        .{ .ctr = 13, .obj = list_id, .key = KeyRef.fromElemId(ElemId.fromOpId(sixth)), .insert = true, .value = .{ .str = "c" } },
        .{ .ctr = 14, .obj = map_id, .key = KeyRef.fromStr("in_map"), .value = .{ .str = "yes" } },
        .{ .ctr = 15, .key = KeyRef.fromStr("only_b"), .value = .{ .str = "b" } },
    };
    const ops_b = try buildOps(gpa, b, &specs_b);
    defer freeChangeOps(gpa, ops_b);
    _ = try applyHandChange(&doc, gpa, actor_b, 1, 13, &.{h1}, null, ops_b);
    return doc;
}

/// A document with one change and nothing else: the common head three documents
/// fork from, in upstream's `make_sure_load_incremental_doesnt_skip_a_load_with_a_common_head`
/// (`tests/test.rs:3159-3192`).
fn buildBase(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("string"), .value = .{ .str = "hello" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    _ = try applyHandChange(&doc, gpa, actor_a, 1, 1, &.{}, null, ops);
    return doc;
}

/// The one head a freshly built base document has.
fn onlyHead(doc: *const Document, gpa: Allocator) !ChangeHash {
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    return heads[0];
}

/// Whether `hash` is one of `list` — upstream's `heads.contains(&hash)`
/// ([`tests/test.rs:3186-3187`](../../github-automerge-automerge/rust/automerge/tests/test.rs)).
fn containsHash(list: []const ChangeHash, hash: ChangeHash) bool {
    for (list) |candidate| {
        if (candidate.eql(hash)) return true;
    }
    return false;
}

/// Checks that `doc`, read from `bytes`, ends up with the head set its own
/// chunk recorded, and names every disagreement if it does not.
///
/// **This is the assertion [`Document.reconstruct`] used to print.** The load
/// path refuses a document whose derived heads disagree with the stored ones
/// (`storage/document.rs:306-322`), which is `test/fixtures/incorrect_max_op.automerge`
/// arriving on purpose — so for that fixture the mismatch *is* the answer, and
/// printing it there is correct. But a print only says something to whoever is
/// already looking, and a mismatch that fires on a fixture which is *supposed*
/// to load — the reference's own `interop/exemplar` — is a defect that a test
/// nobody reads will not catch. So the same comparison runs here as well, from
/// the outside: the heads are read back off the change graph the load
/// installed, against the heads the chunk carries, and a disagreement fails
/// the test that names the file.
fn expectHeadsRecorded(
    gpa: Allocator,
    doc: *const Document,
    name: []const u8,
    bytes: []const u8,
) !void {
    // **The first chunk and nothing else**, which is what this is about: the
    // stream is not walked past a chunk the check has no use for.
    var stream = chunkmod.ChunkStream.init(bytes);
    const first = (try stream.next()) orelse return;
    // A change-chunk document records no heads at all: its head set is
    // whatever its changes imply, and `applyChanges` is what checks that.
    if (first.typ != .document) return;

    var parsed = try docchunk.parseDocumentChunk(first.data, gpa);
    defer parsed.deinit(gpa);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    if (parsed.headsAreCurrent(heads)) return;

    // The two lists can differ in length, which is one of the ways
    // `headsAreCurrent` answers false, so they are walked separately rather
    // than zipped.
    std.debug.print("doc: {s} loaded with a head set its chunk does not record\n", .{name});
    const stored = parsed.heads();
    for (stored, 0..) |h, i| {
        if (i < heads.len) {
            std.debug.print("doc: head {d} stored {s} derived {s}\n", .{ i, fmtHash(h), fmtHash(heads[i]) });
        } else {
            std.debug.print("doc: head {d} stored {s} derived none\n", .{ i, fmtHash(h) });
        }
    }
    if (heads.len > stored.len) {
        for (heads[stored.len..], stored.len..) |h, i| {
            std.debug.print("doc: head {d} stored none derived {s}\n", .{ i, fmtHash(h) });
        }
    }
    return error.MissingHash;
}

test "every corpus fixture loads or is refused exactly as the manifest records" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{});
    defer dir.close(io);

    var checked: usize = 0;
    var must_load: usize = 0;
    for (corpus) |case| {
        const bytes = try dir.readFileAlloc(io, case.name, gpa, .limited(max_fixture_bytes));
        defer gpa.free(bytes);
        if (Document.load(gpa, std.testing.io, bytes, defaultTextEncoding())) |loaded| {
            var doc = loaded;
            defer doc.deinit();
            if (!case.must_load) {
                std.debug.print("doc: {s} loaded but the manifest says it must not\n", .{case.name});
                return error.UnexpectedLoad;
            }
            // A file that loads is a document, not a crash: the two invariant
            // checkers have to agree with that.
            try testing.expect(try doc.ops.validateOpOrder());
            try testing.expect((try doc.ops.validateTopIndex()) == null);
            // …and it is the document the chunk says it is, whose head set is
            // the one the chunk recorded.
            try expectHeadsRecorded(gpa, &doc, case.name, bytes);
        } else |e| {
            if (case.must_load) {
                std.debug.print("doc: {s} was refused with {s} but the manifest says it must load\n", .{
                    case.name,
                    @errorName(e),
                });
                return error.UnexpectedRefusal;
            }
        }
        checked += 1;
        if (case.must_load) must_load += 1;
    }
    try testing.expectEqual(@as(usize, 18), checked);
    try testing.expectEqual(@as(usize, 5), must_load);
}

/// Loads `bytes`, releases whatever it made, and answers the op count. A
/// refusal comes back as the error itself, never as a trap — which is the
/// whole point of the helper: the loop that calls it has to survive a cut to
/// reach the next one.
fn loadAndRelease(gpa: Allocator, bytes: []const u8) LoadError!usize {
    var doc = try Document.load(gpa, std.testing.io, bytes, defaultTextEncoding());
    defer doc.deinit();
    return doc.ops.len();
}

// **The error path of the load is the part that was never exercised.** Every
// fixture the corpus loads also loads when it is handed whole, so a defect
// that only a *failed* load can reach — a half-built structure freed on the
// way out, a count read from bytes that are not there, a slab left dangling
// where a pointer to it used to be — survives the happy path and the whole
// suite with it. `test/fixtures/missing_actor.automerge` is what that looks
// like: it refuses, correctly, and the refusal freed `0xAA` bytes and killed
// the process with a `General protection exception`.
//
// So this cuts every fixture at every length, twice over.
//
// **The first cut is the file.** That is the framing layer's own error path:
// a cut inside the magic, inside the checksum, inside the length LEB, inside
// the body, and between two chunks of a multi-chunk document.
//
// **The second cut is the body, re-framed with a correct checksum.** Without
// the re-framing every cut dies at the checksum and the body parsers never
// see anything, which is the shallow half of the answer. [`chunkmod.writeChunk`]
// recomputes the checksum over whatever body it is handed
// ([`chunk.rs:300-312`](../../github-automerge-automerge/rust/automerge/src/storage/chunk.rs)),
// so a body cut at any length reaches the metadata block, the op columns, the
// change block and [`collectChanges`] exactly as a whole document would.
test "every fixture, cut at every length, is refused cleanly and never leaks" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{});
    defer dir.close(io);

    var cuts: usize = 0;
    var refusals: usize = 0;
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);

    for (corpus) |case| {
        const bytes = try dir.readFileAlloc(io, case.name, gpa, .limited(max_fixture_bytes));
        defer gpa.free(bytes);

        // Zero bytes is not part of this loop: empty input is an empty
        // document, not a refusal (`automerge.rs:911-914`).
        for (1..bytes.len) |n| {
            cuts += 1;
            if (loadAndRelease(gpa, bytes[0..n])) |_| {
                // A file cut short may still be a shorter document — a
                // one-chunk file cut inside its own body is exactly that —
                // so a load here is not a failure. What must not happen is a
                // crash, and `testing.allocator` reports a leak as a failure
                // of the test rather than of the cut.
            } else |_| {
                refusals += 1;
            }
        }

        // A fixture the framing layer refuses has no body to cut —
        // `test/fixtures/invalid_deflate_stream.automerge` is one, and the
        // raw-file cuts above are already its whole error surface.
        // **The whole stream has to frame**, exactly as `parseChunks` needed,
        // and for the same reason: a fixture with an unreadable tail has no
        // body to cut, and every cut below re-frames the *first* chunk alone.
        var stream = chunkmod.ChunkStream.init(bytes);
        _ = stream.verify() catch continue;
        const first = (stream.next() catch continue) orelse continue;
        const body = first.data;
        const is_document = first.typ == .document;

        // The row count of the fixture whole, so a cut that loads can be held
        // to it. **The op block is a prefix of the body**, so a body cut short
        // cannot hold more ops than the whole one did; a cut that loads with
        // *more* rows than the fixture itself would be reading past the data
        // it was given.
        framed.clearRetainingCapacity();
        try chunkmod.writeChunk(&framed, gpa, first.typ, body);
        var whole_rows: ?usize = null;
        if (loadAndRelease(gpa, framed.items)) |rows| {
            whole_rows = rows;
        } else |_| {}

        for (0..body.len + 1) |n| {
            framed.clearRetainingCapacity();
            try chunkmod.writeChunk(&framed, gpa, first.typ, body[0..n]);
            cuts += 1;
            const loaded = loadAndRelease(gpa, framed.items);
            if (loaded) |rows| {
                if (n == body.len) continue; // the fixture whole, not a cut
                if (!is_document) continue; // a change chunk records no rows to compare
                // **A document body with nothing in it is never a document.**
                // It is the 10-byte
                // `crash-da39a3ee5e6b4b0d3255bfef95601890afd80709` fixture —
                // magic, checksum, type 0, length 0 — which has no metadata
                // block in it at all, and upstream's `tests/test.rs:2210-2219`
                // asserts it is an error. Every document fixture cut to zero
                // is that fixture, so every one of them must be refused.
                if (n == 0) {
                    std.debug.print("doc: {s} loaded an empty document body as {d} rows\n", .{ case.name, rows });
                    return error.EmptyBodyLoaded;
                }
                const full = whole_rows orelse continue;
                if (rows > full) {
                    std.debug.print("doc: {s} cut to {d} bytes loaded {d} rows, the whole one has {d}\n", .{
                        case.name, n, rows, full,
                    });
                    return error.TruncatedLoadGrew;
                }
            } else |_| {
                refusals += 1;
            }
        }
    }
    try testing.expect(cuts > 1000);
    try testing.expect(refusals > 0);
    try testing.expect(framed.items.len > 0);
}

test "a change chunk the reference wrote re-encodes to the reference's own bytes and hash" {
    // Upstream's `interop/exemplar` change 1, a plain `change` chunk with one
    // dependency, a message and five ops. The point is not that this decodes;
    // it is that decoding it and encoding it again produces the **same bytes**,
    // which is the only statement that says the change-op encoder and the
    // reference implementation agree.
    const gpa = testing.allocator;
    const framed = try err.hexFrom(gpa, reference_change_1);
    defer gpa.free(framed);
    const expected = try err.hexFrom(gpa, reference_change_1_hash);
    defer gpa.free(expected);

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    try expectRoundTripped(&doc, gpa, framed, expected);
}

test "a compressed change chunk the reference wrote re-encodes to the same bytes and hash" {
    // The same vector as a `compressed` chunk, which is the framing a peer
    // sends and the one whose checksum covers the inflated body.
    const gpa = testing.allocator;
    const framed = try err.hexFrom(gpa, reference_change_0);
    defer gpa.free(framed);
    const expected = try err.hexFrom(gpa, reference_change_0_hash);
    defer gpa.free(expected);

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    try expectRoundTripped(&doc, gpa, framed, expected);
}

/// Decodes `framed` and re-encodes it, and requires the body and the hash to
/// come back identical to the reference's.
fn expectRoundTripped(
    doc: *Document,
    gpa: Allocator,
    framed: []const u8,
    expected_hash: []const u8,
) !void {
    const chunk = try chunkmod.parseChunk(framed);
    var owned = try changechunk.parseFramedChunk(chunk, gpa);
    defer owned.deinit(gpa);
    const change = owned.parsed.change;

    // Every actor the change names has to be in a table for the encoder to
    // remap through, and that table is sorted, so interning them in the change's
    // own order reproduces the document order the reference wrote them in.
    const names = try gpa.alloc(ActorId, 1 + change.other_actors.len);
    defer gpa.free(names);
    names[0] = change.actor;
    for (change.other_actors, 0..) |other, i| names[i + 1] = other;
    const actors = try gpa.alloc(ActorIdx, names.len);
    defer gpa.free(actors);
    for (names, 0..) |name, i| actors[i] = try doc.putActorRef(gpa, name);

    const ops = try decodeChangeOps(gpa, change, actors);
    defer freeChangeOps(gpa, ops);
    try testing.expect(ops.len > 0);

    var rebuilt = try encodeOneChange(gpa, doc.ops.actors.items, .{
        .actor = actors[0],
        .seq = change.seq,
        .start_op = change.start_op,
        .max_op = change.start_op + ops.len - 1,
        .time = change.time,
        .message = change.message,
        .deps = change.deps,
        .footer = owned.parsed.footer,
    }, ops);
    defer rebuilt.deinit(gpa);

    try testing.expectEqualSlices(u8, change.bytes, rebuilt.body);
    try testing.expectEqualSlices(u8, expected_hash, &rebuilt.change.hash.bytes);
}

test "the reference document's changes come back with the reference's hashes" {
    // The 446-byte document `tools/oracle`'s `doc` subcommand recorded, loaded
    // whole and then asked for the changes it holds. This is the whole load
    // path in one assertion: the document chunk's change block is decoded, the
    // op rows are walked, and every change is **re-encoded and hashed** — and
    // the hashes come back as the ones the reference wrote into that chunk.
    //
    // **The oracle's two subcommands build two different documents**, which is
    // why only one of the two recorded change chunks can ever appear here.
    // `doc` takes `base_document()`, forks it into two actors and has the left
    // one `put(ROOT, "from", "left")` committed with the message `"left"`
    // ([main.rs:181-198](../../tools/oracle/src/main.rs)); `change` takes the
    // same base and gives it a *second* commit, `put(ROOT, "extra", 1i64)`
    // with the message `"extra"`
    // ([:214-217](../../tools/oracle/src/main.rs)).
    // So `reference_change_0` — the base commit both scripts start from — is a
    // change of this document and must come back **byte for byte**, and
    // `reference_change_1` — `extra`, message `extra` — is a change of neither
    // script's second commit and is not in this document at all.
    const gpa = testing.allocator;
    const bytes = try err.hexFrom(gpa, reference_document);
    defer gpa.free(bytes);
    const base_recorded = try err.hexFrom(gpa, reference_change_0);
    defer gpa.free(base_recorded);
    // **The oracle's `get_changes` hands back DEFLATE when the reference chose
    // to compress**, so the recorded chunk is a `compressed` one and its bytes
    // are a deflate stream. The change itself is what that inflates to, and
    // the change hash covers the inflated body.
    const base_chunk = try chunkmod.parseChunk(base_recorded);
    var inflated_base: ?[]u8 = null;
    defer if (inflated_base) |b| gpa.free(b);
    const base_body = switch (base_chunk.typ) {
        .compressed => blk: {
            inflated_base = try chunkmod.decompressChunk(gpa, base_chunk);
            break :blk inflated_base.?;
        },
        else => base_chunk.data,
    };

    var doc = try Document.load(gpa, std.testing.io, bytes, defaultTextEncoding());
    defer doc.deinit();
    // The base change, and two concurrent changes the fork made.
    try testing.expectEqual(@as(usize, 3), doc.graph.len());

    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), changes.len());

    // **The base commit, byte for byte.** It is the one change here whose bytes
    // the oracle also recorded standalone, so it is the one that says the
    // collector's encoding is the reference's encoding and not merely
    // self-consistent: a header field the collector fills in differently, or a
    // predecessor list it reverses wrongly, shows up here as a hash that
    // matches nothing.
    var saw_base = false;
    for (changes.items.items) |*built| {
        const hash_hex = try std.fmt.allocPrint(gpa, "{x}", .{&built.change.hash.bytes});
        defer gpa.free(hash_hex);
        if (!std.mem.eql(u8, reference_change_0_hash, hash_hex)) continue;
        saw_base = true;
        try testing.expectEqualSlices(u8, base_body, built.change.bytes);
    }
    try testing.expect(saw_base);

    // **The heads the chunk recorded are hashes of changes this port rebuilt out
    // of rows.** `Document.load` has already refused the chunk if they are not
    // — that is `verify_changes` — so this restates it against `getChanges`,
    // where a divergence between the load path and the rebuild path would show
    // up as two different answers to the same question.
    var parsed = try docchunk.parseDocumentChunk((try chunkmod.parseChunk(bytes)).data, gpa);
    defer parsed.deinit(gpa);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 2), heads.len);
    try testing.expect(parsed.headsAreCurrent(heads));

    // A save and a reload of it is the same document, which is how `save()`
    // equivalence is measured: not byte for byte, but materialized.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer reloaded.deinit();
    try doc.debugCmp(&reloaded);
}

test "a document built here saves, reloads, and compares equal; one more row does not" {
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();

    // **Twelve ops in the first change and three in the second, and fourteen
    // rows**: one op is a delete, and a delete is not materialised as a row —
    // it is a successor edge on the op it removes
    // ([`columns.rs:426-427`](opset/columns.zig)). Fifteen would be a count that
    // confuses a delete with a tombstone row.
    try testing.expectEqual(@as(usize, 14), doc.len());
    try testing.expectEqual(@as(usize, 2), doc.stats().num_changes);
    try testing.expectEqual(@as(usize, 14), doc.stats().num_ops);
    try testing.expectEqual(@as(usize, 2), doc.stats().num_actors);
    try testing.expectEqual(ObjType.text, try doc.objectType(.{ .id = OpId.init(2, 0) }));
    try testing.expectEqual(ObjType.list, try doc.objectType(.{ .id = OpId.init(1, 0) }));
    try testing.expectEqual(ObjType.map, try doc.objectType(.root));
    try testing.expectEqual(ExId.root, doc.idToExid(OpId.root));
    try testing.expect(
        doc.objectParent(.{ .id = OpId.init(1, 0) }).?.eql(.root),
    );

    const text = try doc.text(gpa, .{ .id = OpId.init(2, 0) });
    defer gpa.free(text);
    try testing.expectEqualStrings("hi!", text);
    // **The mark index is in op-counter space, and is derived from the op id
    // rather than stored** ([`OpBuilder.markIndex`](opset/op.zig)): a begin is
    // `markIdxWord(self._id)` and an end is
    // `-markIdxWord(prevSaturating(self._id))` (`op_set2/op.rs:191-202`). An
    // earlier version of this fixture had both ends on one element, so the mark
    // spanned zero graphemes — and the reference reports no mark for that,
    // because `calculate_marks_fast` only adds a run when `seq > start`
    // (`op_set2/op_set.rs:997`). Measured on the reference, `mark(obj,
    // {start:0, end:0})` over a 2-grapheme text answers `marks() == 0`, and
    // `mark(0, 2)` answers one mark over `[0, 2)`. The fixture is anchored so
    // the mark covers the text, and one is the right answer; see
    // `buildSample`.
    const marks = try doc.marks(gpa, .{ .id = OpId.init(2, 0) });
    defer gpa.free(marks);
    try testing.expect(doc.ops.cols.index.mark.hasAnyMarks());
    try testing.expectEqual(@as(usize, 1), marks.len);

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer reloaded.deinit();
    try doc.debugCmp(&reloaded);

    // **One more row, and the comparison must fail.** A checker that cannot
    // fail is not a checker, so this is the assertion that makes the one above
    // mean something.
    const heads = try reloaded.getHeads(gpa);
    defer gpa.free(heads);
    _ = try addKeyChange(&reloaded, gpa, actor_c, 1, 15, "zzz", heads);
    try testing.expectError(error.Invariant, doc.debugCmp(&reloaded));
}

test "a document is still readable after the bytes it was loaded from are gone" {
    // **The ownership rule, checked.** A document chunk hands its body back
    // borrowed, and the op set's strings and the actor table both point into
    // storage the document has to own. If either still pointed at `saved`, the
    // reads below would be reading freed memory — and `std.testing.allocator`
    // poisons freed memory, so `debugCmp` would report a difference rather than
    // quietly pass.
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();
    const saved = try doc.save(gpa);

    var loaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer loaded.deinit();
    // **The buffer the document was read from is gone before every read below.**
    gpa.free(saved);

    const text = try loaded.text(gpa, .{ .id = OpId.init(2, 0) });
    defer gpa.free(text);
    try testing.expectEqualStrings("hi!", text);
    try testing.expectEqual(@as(usize, 14), loaded.len());
    try loaded.debugCmp(&doc);

    // The reloaded document saves back to the same bytes, which is the same
    // claim in the other direction.
    const again = try loaded.save(gpa);
    defer gpa.free(again);
    const from_source = try doc.save(gpa);
    defer gpa.free(from_source);
    try testing.expectEqualSlices(u8, from_source, again);
}

test "an encoded change and the collector's re-encoding of it are the same bytes" {
    // The encoder that wrote a change and the collector that reads the op set
    // back must agree, or `getChangeByHash` would hand a peer bytes with a
    // different hash from the one it asked for.
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 15, .key = KeyRef.fromStr("later"), .value = .{ .str = "z" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    var built = try handChange(&doc, gpa, actor_a, 2, 15, heads, null, ops);
    defer built.deinit(gpa);
    const hash = built.change.hash;
    _ = try doc.applyChanges(gpa, &.{built.change});

    var got = (try doc.getChangeByHash(gpa, hash)).?;
    defer got.deinit(gpa);
    try testing.expectEqualSlices(u8, built.body, got.body);
    try testing.expectEqualSlices(u8, &hash.bytes, &got.change.hash.bytes);
}

test "loadIncremental into a non-empty document equals loading the same bytes whole" {
    const gpa = testing.allocator;
    var whole = try buildSample(gpa);
    defer whole.deinit();
    const bytes = try whole.save(gpa);
    defer gpa.free(bytes);

    // A document that already holds some of `whole`'s history, so the load
    // takes the "append" path rather than the "this is empty, read it all"
    // one. **`buildBase` cannot be that document.** `buildBase` and
    // `buildSample` both open with a change by `actor_a` at sequence 1, and
    // they are *different* changes — so a document built from one and a save
    // taken from the other are two different changes claiming one slot of one
    // actor's history, and the reference refuses that pair with
    // `duplicate seq 1 found for actor a1a1...`. Measured, not reasoned
    // about: the `loadinc` oracle subcommand's `fork` and `into-descendant`
    // cases both answer `err` with that message, where the `descendant` case —
    // a save that *descends* from the document it is loaded into — answers
    // `ok` with the rows it added. The check the port is making is
    // `has_actor_seq` (`automerge.rs:1089-1091`), reached from
    // `BatchApply::new` (`op_set2/change/batch.rs:1073-1076`), and it is right.
    //
    // So the base is a **prefix** of `whole`: actor_a's first change, forked
    // at, which `buildSample` applies before actor_b's.
    const mid = try whole.graph.hashForActorSeq(0, 1);
    var base = try whole.forkAt(gpa, &.{mid});
    defer base.deinit();
    const added = try base.loadIncremental(gpa, bytes);
    try testing.expect(added > 0);

    // The same bytes, loaded whole into an empty document. This is the one
    // document the incremental result has to be equal to — the *materialised*
    // op set, not the heads, because two documents can share heads and still
    // read differently.
    var direct = try Document.load(gpa, std.testing.io, bytes, defaultTextEncoding());
    defer direct.deinit();
    try base.debugCmp(&direct);
}

test "a snapshot followed by change chunks loads as the snapshot plus those changes" {
    // **The stream `save()` and then `saveIncremental()` produce**, and the
    // shape `test/c/suite/ported_wasm/basic_tests.c:767-783` builds as
    // `saveB`. `load_with_options` matches the *first* chunk to build the
    // document and then applies the rest whatever that first chunk was, with
    // `changes` empty in the document case
    // ([`automerge.rs:924-975`](../../github-automerge-automerge/rust/automerge/src/automerge.rs));
    // returning after the snapshot threw the tail away, so a document that was
    // saved and then written to again loaded as the earlier state.
    //
    // **This is also the empty-document arm of `loadIncremental`**, which
    // delegates here and then returns
    // (`Automerge::load_incremental`'s own empty arm, `automerge.rs:1038-1051`,
    // is the same whole-load path). One fix, two doors.
    const gpa = testing.allocator;
    const readonly = @import("read.zig");
    var doc = try buildSample(gpa);
    defer doc.deinit();
    const snapshot = try doc.save(gpa);
    defer gpa.free(snapshot);

    // Two more changes, each taken by its own incremental save, so the stream
    // is **one document chunk and two change chunks**.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, snapshot);
    for ([_][]const u8{ "third", "fourth" }, [_]u64{ 2, 3 }, [_]u32{ 16, 17 }) |key, seq, ctr| {
        const heads = try doc.getHeads(gpa);
        defer gpa.free(heads);
        _ = try addKeyChange(&doc, gpa, actor_a, seq, ctr, key, heads);
        const part = try doc.saveIncremental(gpa);
        defer gpa.free(part);
        // A part that is empty would make this test pass for the wrong reason,
        // which is the defect it exists to catch.
        try testing.expect(part.len > 0);
        try stream.appendSlice(gpa, part);
    }
    try testing.expectEqual(@as(usize, 4), doc.graph.len());

    var loaded = try Document.load(gpa, std.testing.io, stream.items, defaultTextEncoding());
    defer loaded.deinit();
    // **All four changes, not the snapshot's two.**
    try testing.expectEqual(@as(usize, 4), loaded.graph.len());
    // And the two keys the snapshot cannot have written. A change count alone
    // would be satisfied by a document holding the wrong two, so the register
    // is read: neither key exists in the snapshot, so finding it here means
    // the tail was applied and not merely counted.
    for ([_][]const u8{ "third", "fourth" }) |key| {
        if ((try readonly.get(&loaded, ExId.root, .{ .key = key })) == null) {
            return error.Unexpected;
        }
    }
}

test "load refuses a change stream that leaves a change queued, and loadIncremental queues it" {
    // **The two halves of upstream's rule, and they disagree on purpose.**
    //
    // `load` refuses a change-chunk stream that leaves anything queued —
    // "Only allow missing deps if the first chunk was a document chunk"
    // ([`automerge.rs`:976-982](../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // citing
    // [automerge PR 599](https://github.com/automerge/automerge/pull/599#issuecomment-1549667472).
    // `loadIncremental` does not, and **no spelling of it can**: the
    // empty-document arm reaches the same condition only through
    // `LoadOptions::new().on_partial_load(OnPartialLoad::Ignore)`
    // (`:1038-1045`) and the non-empty arm never consults the rule at all
    // (`:1053-1068` — `load_changes`, `apply_changes_log_patches`, `Ok(delta)`).
    // **Making the two agree would break every peer that sends a change before
    // the one it depends on**, which is the one thing an incremental load is
    // for.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    // **Two changes of one actor, the second naming the first as a
    // dependency**, each handed over as its own framed change chunk. That is
    // `save_after`'s output
    // ([`automerge.rs`:1194-1201](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // and therefore exactly what a peer sends.
    const h1 = try doc.getHeads(gpa);
    defer gpa.free(h1);
    _ = try addKeyChange(&doc, gpa, actor_a, 1, 1, "first", h1);
    const first = try doc.saveIncremental(gpa);
    defer gpa.free(first);

    const h2 = try doc.getHeads(gpa);
    defer gpa.free(h2);
    _ = try addKeyChange(&doc, gpa, actor_a, 2, 2, "second", h2);
    const second = try doc.saveIncremental(gpa);
    defer gpa.free(second);

    // **The type byte is measured, not assumed**: `0` is a document chunk and
    // `1` is a change chunk
    // ([`storage/chunk.rs`](../github-automerge-automerge/rust/automerge/src/storage/chunk.rs),
    // `readChunk` in [`src/storage/chunk.zig`:323-327](storage/chunk.zig)). Both
    // streams below are change-first, so the *only* thing separating the
    // accepted one from the refused one is the queue.
    try testing.expect(first.len > 8 and second.len > 8);
    try testing.expectEqual(@as(u8, 1), first[8]);
    try testing.expectEqual(@as(u8, 1), second[8]);

    // **The negative control, and it comes first on purpose.** `first` is a
    // change chunk whose change depends on nothing, so it loads and leaves an
    // empty queue. A rule that refused *every* change-first stream would pass
    // the refusal assertion below and fail here — and that is not upstream's
    // rule, because the condition is `!am.queue.is_empty() && …`: an empty
    // queue is half of it and the chunk type is the other half.
    var alone = try Document.load(gpa, std.testing.io, first, defaultTextEncoding());
    defer alone.deinit();
    try testing.expectEqual(@as(usize, 1), alone.graph.len());
    try testing.expectEqual(@as(usize, 0), alone.queue.len());

    // **The refusal.** `second` is the same shape of stream naming a
    // dependency this new document does not hold, so the load queues the
    // change and upstream turns that queue into `MissingDeps`
    // ([`error.rs`:66](../github-automerge-automerge/rust/automerge/src/error.rs) —
    // "change's deps should already be in the document", which is true of
    // every change in a snapshot and false of the **first** chunk of a
    // change-only stream).
    //
    // **Matched by hand and the document freed first**, because
    // `expectError` drops the `Document` it was handed on the passing path
    // without a `deinit`, so a port that wrongly accepts the stream buries
    // the one line naming the fault under the allocator's report of every
    // allocation it made.
    if (Document.load(gpa, std.testing.io, second, defaultTextEncoding())) |accepted| {
        var wrongly = accepted;
        wrongly.deinit();
        return error.OrphanStreamAccepted;
    } else |e| {
        try testing.expectEqual(error.MissingDeps, e);
    }

    // **The other half, on the same bytes: a peer is not refused.** Zero rows
    // and no error, with the change **queued** — the queue is the observable
    // that matters, because an empty queue here would mean the change was
    // *dropped* and a nonzero row count would mean it was not an orphan at
    // all. Either of those is a document that is not the one the bytes
    // describe.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 0), try peer.loadIncremental(gpa, second));
    try testing.expectEqual(@as(usize, 0), peer.graph.len());
    try testing.expectEqual(@as(usize, 1), peer.queue.len());

    // **And the dependency drains it**, which is what queueing rather than
    // refusing buys: a peer handed the change it was missing is now in step.
    try testing.expect(try peer.loadIncremental(gpa, first) > 0);
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try testing.expectEqual(@as(usize, 2), peer.graph.len());
}

test "a truncated change stream is a parse error under load, and is tolerated under loadIncremental" {
    // **The other direction, and the one a misplaced check breaks.** Upstream's
    // condition sits **inside the `Complete` arm** of the `load_changes` match
    // ([`automerge.rs`:974-984](../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // while the `Partial` arm returns at `:985-989` without ever reaching
    // `apply_changes` (`:975`). So a stream that **both queues a change and
    // stops early** is the truncation error and never `MissingDeps`, and under
    // `OnPartialLoad::Ignore` it is not an error at all.
    //
    // **Checking the refusal before the partial-load branch turns a tolerance
    // into a refusal**, which is the same wrong answer with the opposite sign:
    // a peer that sent a good change and then a truncated one would be told it
    // sent a stream that was fine to send. This test is the half that pins the
    // position; the test above pins the rule.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    const h1 = try doc.getHeads(gpa);
    defer gpa.free(h1);
    _ = try addKeyChange(&doc, gpa, actor_a, 1, 1, "first", h1);
    const first = try doc.saveIncremental(gpa);
    defer gpa.free(first);

    const h2 = try doc.getHeads(gpa);
    defer gpa.free(h2);
    _ = try addKeyChange(&doc, gpa, actor_a, 2, 2, "second", h2);
    const second = try doc.saveIncremental(gpa);
    defer gpa.free(second);

    // **The orphan first, then a tail that stops mid-chunk.** Both halves of
    // the refusal are true of the *prefix* — the first chunk is a change and
    // its change is queued — and the stream is truncated besides, so a check
    // ahead of the truncation branch would answer `MissingDeps` for input
    // upstream answers with a parse error.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, second);
    try stream.appendSlice(gpa, first);
    try testing.expect(stream.items.len > 12);
    stream.shrinkRetainingCapacity(stream.items.len - 4);
    try testing.expectEqual(@as(u8, 1), stream.items[8]);

    // **`Document.load` is all-or-nothing** — `ChunkStream.verify` rather than
    // `ChunkStream.verifyPartial`, because upstream's default is
    // `OnPartialLoad::Error`
    // ([`automerge.rs`:107-110](../github-automerge-automerge/rust/automerge/src/automerge.rs)) —
    // so the truncation is a parse error and the rule is never reached at all.
    // **What is asserted is what the error is *not*.** Naming the variant
    // would pin the framing helper's answer rather than this function's
    // position, and the position is the thing under test.
    if (Document.load(gpa, std.testing.io, stream.items, defaultTextEncoding())) |accepted| {
        var wrongly = accepted;
        wrongly.deinit();
        return error.TruncatedStreamAccepted;
    } else |e| {
        try testing.expect(e != error.MissingDeps);
    }

    // Empty receivers use the full-load Ignore policy, which discards the
    // entire change stream on a partial tail (`automerge.rs:985-989,1038-1045`).
    // No prefix is applied or queued, unlike a nonempty incremental receiver.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 0), try peer.loadIncremental(gpa, stream.items));
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try testing.expectEqual(@as(usize, 0), peer.graph.len());

    // A real nonempty baseline takes the incremental Partial prefix instead
    // (`automerge.rs:1053-1064`), so the orphan is queued rather than discarded.
    var existing = try Document.init(gpa, std.testing.io);
    defer existing.deinit();
    _ = try addKeyChange(&existing, gpa, actor_b, 1, 1, "baseline", &.{});
    try testing.expectEqual(@as(usize, 0), try existing.loadIncremental(gpa, stream.items));
    try testing.expectEqual(@as(usize, 1), existing.graph.len());
    try testing.expectEqual(@as(usize, 1), existing.queue.len());
    try testing.expectEqual(@as(usize, 2), try existing.loadIncremental(gpa, first));
    try testing.expectEqual(@as(usize, 3), existing.graph.len());
    try testing.expectEqual(@as(usize, 0), existing.queue.len());
}

test "a corrupt tail refuses the load before it touches the caller's document" {
    const gpa = testing.allocator;
    // **A stream that reads whole until its second chunk.** One document chunk
    // and then a change chunk, so the refusal lands on a chunk that is not the
    // first and there is a snapshot ready to apply in front of it. A walk that
    // applied as it read would rebuild the document from that snapshot before
    // it refused; the list this path used to build was what ordered those two
    // the other way round.
    var source = try buildSample(gpa);
    defer source.deinit();
    const snapshot = try source.save(gpa);
    defer gpa.free(snapshot);
    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);
    _ = try addKeyChange(&source, gpa, actor_a, 2, 16, "third", heads);
    const third = try source.saveIncremental(gpa);
    defer gpa.free(third);
    try testing.expect(third.len > 0);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, snapshot);
    try stream.appendSlice(gpa, third);
    try testing.expect(stream.items.len > 12);
    // **The body is altered and the recorded checksum is not**, so this is
    // corruption and the refusal is `error.InvalidChecksum` at that chunk's
    // own header — not a truncation, and not anything a body parser says.
    stream.items[stream.items.len - 1] ^= 0x01;

    // **The control: a fresh document refuses, and for the framing reason.**
    // This is the same walk a caller who only wants a document back takes, and
    // it is what says the tail's checksum was the refusal taken.
    if (Document.load(gpa, std.testing.io, stream.items, defaultTextEncoding())) |accepted| {
        var wrongly = accepted;
        wrongly.deinit();
        return error.CorruptTailAccepted;
    } else |e| {
        try testing.expectEqual(error.InvalidChecksum, e);
    }

    // **The caller's own document is the other half**, because
    // [`Document.loadInto`] reads into a document somebody else owns and
    // `replace` resets it. Everything asserted below is what a reset-then-
    // refuse would have destroyed: the rows, the change graph, the actor and
    // the key. The counts alone would not catch it — the snapshot holds
    // exactly the rows this document already had, being a save of a document
    // built the same way — so the key is read back through the read path.
    var target = try Document.init(gpa, std.testing.io);
    defer target.deinit();
    const none = try target.getHeads(gpa);
    defer gpa.free(none);
    _ = try addKeyChange(&target, gpa, actor_b, 1, 99, "mine", none);
    const before_ops = target.ops.len();
    const before_graph = target.graph.len();
    try testing.expectEqual(@as(usize, 1), before_graph);
    const actor_before = try gpa.dupe(u8, target.getActorId().bytes);
    defer gpa.free(actor_before);

    try testing.expectError(
        error.InvalidChecksum,
        target.loadInto(gpa, stream.items, defaultTextEncoding()),
    );

    try testing.expectEqual(before_ops, target.ops.len());
    try testing.expectEqual(before_graph, target.graph.len());
    try testing.expectEqual(@as(usize, 0), target.queue.len());
    // Empty-owner replacement preserves the caller's actor rather than keeping
    // the fresh loader's randomly minted actor.
    try testing.expectEqualStrings(actor_before, target.getActorId().bytes);
    const readonly = @import("read.zig");
    if ((try readonly.get(&target, ExId.root, .{ .key = "mine" })) == null) {
        return error.DocumentWasReset;
    }
}

test "an incremental load applies the prefix of a stream that stops mid-chunk" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    const h1 = try doc.getHeads(gpa);
    defer gpa.free(h1);
    _ = try addKeyChange(&doc, gpa, actor_a, 1, 1, "first", h1);
    const first = try doc.saveIncremental(gpa);
    defer gpa.free(first);

    const h2 = try doc.getHeads(gpa);
    defer gpa.free(h2);
    _ = try addKeyChange(&doc, gpa, actor_a, 2, 2, "second", h2);
    const second = try doc.saveIncremental(gpa);
    defer gpa.free(second);

    // **One good chunk and then a tail that stops inside the next chunk's
    // body.** The refusal is `error.LengthExceedsInput` — the declared length
    // runs off the end — and the change in front of it is one this peer can
    // apply, so a walk that stops at the bad chunk and a list that held the
    // good prefix come to the same document.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, second);
    try stream.appendSlice(gpa, first);
    try testing.expect(stream.items.len > 12);
    stream.shrinkRetainingCapacity(stream.items.len - 4);

    // **The incremental walk.** One change applied, nothing refused, nothing
    // queued — the truncation is swallowed and the prefix is not lost with it,
    // which is what the chunk list this path used to build first existed to
    // get right.
    var peer = try Document.load(gpa, std.testing.io, first, defaultTextEncoding());
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 1), peer.graph.len());
    try testing.expectEqual(@as(usize, 1), try peer.loadIncremental(gpa, stream.items));
    try testing.expectEqual(@as(usize, 2), peer.graph.len());
    try testing.expectEqual(@as(usize, 0), peer.queue.len());

    // Empty receivers use full-load Ignore, not the nonempty prefix walk.
    // The Partial arm discards both the first chunk and the decoded tail
    // (`automerge.rs:985-989,1038-1045`), even when the prefix is an orphan.
    var fresh = try Document.init(gpa, std.testing.io);
    defer fresh.deinit();
    try testing.expectEqual(@as(usize, 0), try fresh.loadIncremental(gpa, stream.items));
    try testing.expectEqual(@as(usize, 0), fresh.graph.len());
    try testing.expectEqual(@as(usize, 0), fresh.queue.len());
    // Ignore only discards partial streams: the complete orphan is queued.
    try testing.expectEqual(@as(usize, 0), try fresh.loadIncremental(gpa, second));
    try testing.expectEqual(@as(usize, 1), fresh.queue.len());
    try testing.expectEqual(@as(usize, 2), try fresh.loadIncremental(gpa, first));
    try testing.expectEqual(@as(usize, 2), fresh.graph.len());
    try testing.expectEqual(@as(usize, 0), fresh.queue.len());

    // **And the whole load refuses the very same bytes**, which is the other
    // half of the same walk: the prefix is dropped with the tail and the
    // truncation is the answer. Matched by hand and the document freed first,
    // because `expectError` drops a `Document` on the passing path and the
    // allocator would then bury the assertion under its report.
    if (Document.load(gpa, std.testing.io, stream.items, defaultTextEncoding())) |accepted| {
        var wrongly = accepted;
        wrongly.deinit();
        return error.TruncatedStreamAccepted;
    } else |e| {
        try testing.expectEqual(error.LengthExceedsInput, e);
    }
}

test "the same bytes, three ways, materialise one document" {
    const gpa = testing.allocator;
    var whole = try buildSample(gpa);
    defer whole.deinit();
    const bytes = try whole.save(gpa);
    defer gpa.free(bytes);

    // A **strict prefix** of `whole` — actor_a's first change, which
    // `buildSample` applies before actor_b's. All three routes below start
    // from this history, so only the last leg differs and the three documents
    // have to come out equal.
    const mid = try whole.graph.hashForActorSeq(0, 1);

    // 1. **Whole.** The bytes read into an empty document, which is what
    //    [`Document.load`] does and the path every fixture in the corpus takes.
    var via_load = try Document.load(gpa, std.testing.io, bytes, defaultTextEncoding());
    defer via_load.deinit();

    // 2. **Incremental.** A document that already holds a prefix, told to read
    //    the rest ([`Automerge::load_incremental`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1027-1069),
    //    and so every peer that receives a document chunk.
    // 3. **Direct.** The same document handed the changes one at a time
    //    ([`Automerge::apply_changes`](../../github-automerge-automerge/rust/automerge/src/automerge.rs):1090-1106),
    //    which is the route a sync message's change list takes.
    var via_load_incremental = try whole.forkAt(gpa, &.{mid});
    defer via_load_incremental.deinit();
    const added = try via_load_incremental.loadIncremental(gpa, bytes);
    try testing.expect(added > 0);

    var via_changes = try whole.forkAt(gpa, &.{mid});
    defer via_changes.deinit();
    var tail = try whole.getChanges(gpa, &.{mid});
    defer tail.deinit(gpa);
    const tail_view = try asChanges(gpa, tail.slice());
    defer gpa.free(tail_view);
    try testing.expect(tail_view.len > 0);
    for (tail_view) |change| _ = try via_changes.applyChanges(gpa, &.{change});

    // **The materialised document, not the heads.** Two documents can share a
    // head set and still read differently, and this port has already had a
    // row-order defect whose only symptom was that. `debugCmp` checks
    // soundness on *both* sides before it compares anything
    // ([`OpSet.debugDiff`](opset/op_set.zig):1057-1086), so a document whose
    // `index.top` is inconsistent cannot pass here by being equal to another
    // broken one.
    try via_load.debugCmp(&via_load_incremental);
    try via_load.debugCmp(&via_changes);
    try via_load_incremental.debugCmp(&via_changes);
}

test "the index a document is built with is the index its bytes rebuild" {
    // **The invariant, and why it needs its own test.** A document is written
    // twice over on its way here and the two writers do not share a rule: the
    // change path gives `Columns::splice` rows and it records `top = visible`
    // for each one it is handed (`columns.rs:478-482`), while a load rebuilds
    // the columns from scratch and marks **only the last visible row of every
    // register** ([`IndexBuilder.flush`](opset/index.zig), `op_set2/op_set/index.rs:159-176`).
    // The two agree only when every register ends up with one visible row, and
    // a register with two is what `OpSet.validateTopIndex` names a
    // `group_mismatch`. The five round-trip tests around this one all reach
    // that answer through `debugCmp`; this one states it, and then says what
    // the document **reads** — because a save and a reload that agree on the
    // bytes and disagree on the answer is the failure this whole cluster of
    // tests exists to catch.
    //
    // `buildSample` is the fixture that makes the case, not an arbitrary one:
    // its text object holds a set and a mark over the same element, which is
    // the shape that puts a mark row next to the insert it annotates.
    const gpa = testing.allocator;
    const readonly = @import("read.zig");
    const list_id = ExId{ .id = OpId.init(1, 0) };
    const text_id = ExId{ .id = OpId.init(2, 0) };
    const map_id = ExId{ .id = OpId.init(3, 0) };

    var built = try buildSample(gpa);
    defer built.deinit();
    const saved = try built.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer reloaded.deinit();

    // **Soundness first, on both sides, and separately.** `debugCmp` computes
    // this too, but a test that says "these two documents are equal" and a test
    // that says "each of them is internally consistent" are different claims,
    // and two equally broken documents satisfy the first.
    for ([_]*const Document{ &built, &reloaded }) |doc| {
        try testing.expectEqual(@as(usize, 14), doc.ops.len());
        try testing.expect(try @constCast(&doc.ops).validateOpOrder());
        try testing.expectEqual(@as(?opsetmod.TopIndexFault, null), try @constCast(&doc.ops).validateTopIndex());
        try testing.expectEqual(doc.ops.cols.index.top.len(), doc.ops.cols.index.visible.len());
    }
    // And the two indexes are the *same* index, cell for cell. A checker that
    // both documents pass is not enough: the claim under test is that the
    // write path and the rebuild agree, and that is a comparison.
    try testing.expectEqual(
        built.ops.cols.index.top.len(),
        reloaded.ops.cols.index.top.len(),
    );
    try built.debugCmp(&reloaded);

    // **The materialised document, read through the read surface.** Every line
    // below is an answer a caller gets, and the point is that the reloaded
    // document answers every one of them the same way. The mark is the one
    // that matters: a wrong `top` in the text object's registers is exactly
    // what a text read walks.
    for ([_]*const Document{ &built, &reloaded }) |doc| {
        const text = try readonly.text(doc, text_id, gpa);
        defer gpa.free(text);
        try testing.expectEqualStrings("hi!", text);
        const marks = try readonly.getMarks(doc, text_id, 0, 3, gpa);
        defer gpa.free(marks);
        try testing.expectEqual(@as(usize, 1), marks.len);
        try testing.expectEqualStrings("bold", marks[0].name);
        try testing.expectEqual(@as(usize, 2), marks[0].start);
        try testing.expectEqual(@as(usize, 3), marks[0].end);

        try testing.expectEqualStrings("again", try scalarOf(doc, "hello"));
        try testing.expectEqualStrings("b", try scalarOf(doc, "only_b"));
        try testing.expectEqual(ObjType.map, try doc.objectType(.root));
        try testing.expectEqual(ObjType.list, try doc.objectType(.{ .id = list_id.id }));
        try testing.expectEqual(ObjType.text, try doc.objectType(.{ .id = text_id.id }));
        try testing.expectEqual(ObjType.map, try doc.objectType(.{ .id = map_id.id }));

        // The list the second actor appended to, read by index, and the map
        // the first actor made.
        try testing.expectEqual(@as(usize, 2), try readonly.length(doc, list_id));
        try testing.expectEqualStrings("b", try scalarAt(doc, list_id, 0));
        try testing.expectEqualStrings("c", try scalarAt(doc, list_id, 1));
        try testing.expectEqualStrings("yes", try scalarOfKey(doc, map_id, "in_map"));

        const heads = try doc.getHeads(gpa);
        defer gpa.free(heads);
        try testing.expectEqual(@as(usize, 1), heads.len);
        try testing.expectEqual(@as(usize, 2), doc.stats().num_changes);
        try testing.expectEqual(@as(usize, 14), doc.stats().num_ops);
        try testing.expectEqual(@as(usize, 2), doc.stats().num_actors);
    }
}

/// A root map key's value as the string the document holds.
///
/// **Borrowed, not copied** ([`read.zig` §The ownership rule](../read.zig)):
/// the bytes are the op set's interned value, so the slice dies with the next
/// mutation. Nothing here mutates.
fn scalarOf(doc: *const Document, key: []const u8) ![]const u8 {
    return scalarOfKey(doc, ExId.root, key);
}

/// `key`'s value in the map at `obj`, as a string.
fn scalarOfKey(doc: *const Document, obj: ExId, key: []const u8) ![]const u8 {
    const item = (try @import("read.zig").get(doc, obj, .{ .key = key })) orelse
        return error.TestUnexpectedResult;
    return item.value.scalar.str;
}

/// The value at `index` in the list at `obj`, as a string.
fn scalarAt(doc: *const Document, obj: ExId, index: usize) ![]const u8 {
    const item = (try @import("read.zig").get(doc, obj, .{ .index = index })) orelse
        return error.TestUnexpectedResult;
    return item.value.scalar.str;
}

test "loadIncremental learns a change from a save taken after a common head" {
    // Upstream `make_sure_load_incremental_doesnt_skip_a_load_with_a_common_head`
    // (`tests/test.rs:3159-3192`), ported case for case. The case is where a
    // reader that **skipped** every document chunk it did not already hold whole
    // would leave `doc3` at the common head and never learn anything.
    const gpa = testing.allocator;

    var doc1 = try buildBase(gpa);
    defer doc1.deinit();
    const common = try onlyHead(&doc1, gpa);

    var doc2 = try buildBase(gpa);
    defer doc2.deinit();
    var doc3 = try buildBase(gpa);
    defer doc3.deinit();

    const hash_b = try addKeyChange(&doc1, gpa, actor_a, 2, 2, "concurrent1", &.{common});
    const heads1 = try doc1.getHeads(gpa);
    defer gpa.free(heads1);
    try testing.expectEqual(@as(usize, 1), heads1.len);

    const saved1 = try doc1.save(gpa);
    defer gpa.free(saved1);
    _ = try doc3.loadIncremental(gpa, saved1);
    var heads3 = try doc3.getHeads(gpa);
    defer gpa.free(heads3);
    try testing.expectEqual(@as(usize, 1), heads3.len);
    // **The same head, not the common one.**
    try testing.expectEqualSlices(u8, &hash_b.bytes, &heads3[0].bytes);
    try doc3.debugCmp(&doc1);

    const hash_d = try addKeyChange(&doc2, gpa, actor_b, 1, 2, "concurrent2", &.{common});
    const merged = try doc2.merge(gpa, &doc1);
    defer gpa.free(merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    // **Membership, not position.** Upstream writes `heads.contains(&hash_d)`
    // and `heads.contains(&hash_b)` (`tests/test.rs:3186-3187`) and pins no
    // order, because there is none to pin: the reference holds its heads in a
    // `BTreeSet<ChangeHash>` (`change_graph.rs:41`) and `ChangeHash` derives
    // `Ord` over its 32 bytes (`types.rs:689-690`), so `heads()` yields them in
    // **ascending byte order** — which hash lands first is a property of the
    // bytes, not of which document the change came from. Measured: the
    // `loadinc` oracle's `getchangesadded` record runs `left.merge(&mut right)`
    // and prints `[left's own head, right's head]` for a pair whose left head
    // is `b11c13…` and right head is `d5a682…` — ascending, and left's own
    // change first only because its bytes happen to be lower. The port keeps
    // the same order (`change_graph.zig:191-193`, `updateHeads`'s
    // `hashInsertIndex` at `:1133-1139`).
    try testing.expect(containsHash(merged, hash_d));
    try testing.expect(containsHash(merged, hash_b));

    const saved2 = try doc2.save(gpa);
    defer gpa.free(saved2);
    _ = try doc3.loadIncremental(gpa, saved2);
    var heads3b = try doc3.getHeads(gpa);
    defer gpa.free(heads3b);
    const heads2 = try doc2.getHeads(gpa);
    defer gpa.free(heads2);
    try testing.expectEqual(heads2.len, heads3b.len);
    for (heads2, 0..) |want, i| {
        try testing.expectEqualSlices(u8, &want.bytes, &heads3b[i].bytes);
    }
    try doc3.debugCmp(&doc2);
}

test "the same operations committed the same way produce the same hash" {
    // Determinism is the property. The reference's own hash for a locally
    // committed change cannot be compared without running the reference, so
    // what is checked here is that the hash is a function of the bytes, that
    // the bytes are a function of the change, and that the document can later
    // re-derive the very same change from its own op set.
    const gpa = testing.allocator;

    var d1 = try Document.init(gpa, std.testing.io);
    defer d1.deinit();
    d1.setActorId(.{ .bytes = actor_a });
    var d2 = try d1.clone(gpa);
    defer d2.deinit();
    var d3 = try d1.clone(gpa);
    defer d3.deinit();

    const a = try d1.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .str = "v" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);

    // **Each document builds its own arguments**, which is the point of the
    // signature: `Document.commit` no longer reaches for `self.isolation` and
    // mints an actor index of its own, so a test that committed the same ops
    // through two documents would otherwise be comparing two different
    // transactions' headers rather than two encodings of one transaction.
    const args1 = try d1.transactionArgs(gpa, null);
    defer args1.deinit(gpa);
    const args2 = try d2.transactionArgs(gpa, null);
    defer args2.deinit(gpa);
    const args3 = try d3.transactionArgs(gpa, null);
    defer args3.deinit(gpa);

    const h1 = try d1.commit(gpa, args1, ops, "message", 42);
    const h2 = try d2.commit(gpa, args2, ops, "message", 42);
    try testing.expectEqualSlices(u8, &h1.bytes, &h2.bytes);
    try testing.expect(d1.hasChange(h1));
    try testing.expect(d2.hasChange(h2));

    // A different message is a different change: the message is in the header,
    // and the header is inside the hash.
    const h3 = try d3.commit(gpa, args3, ops, "other", 42);
    try testing.expect(!h3.eql(h1));

    // The head set is the committed change, because a local change always
    // depends on this actor's own previous change
    // (`transaction_args`, `automerge.rs:551-556`).
    var heads = try d1.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, &h1.bytes, &heads[0].bytes);
}

test "an empty commit is a change the document can hand back unchanged" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = actor_a });

    const h1 = try doc.emptyCommit(gpa, "merge", 7);
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, &h1.bytes, &heads[0].bytes);

    // **The change has no rows, and the collector still rebuilds it byte for
    // byte** — which is the only way `getChangeByHash` can be trusted to
    // answer a peer with what the document recorded.
    var got = (try doc.getChangeByHash(gpa, h1)).?;
    defer got.deinit(gpa);
    try testing.expectEqualSlices(u8, &h1.bytes, &got.change.hash.bytes);

    // A second empty commit depends on the first, so the two are different
    // changes and the document has one head again.
    const h2 = try doc.emptyCommit(gpa, "merge", 7);
    try testing.expect(!h2.eql(h1));
    var heads2 = try doc.getHeads(gpa);
    defer gpa.free(heads2);
    try testing.expectEqual(@as(usize, 1), heads2.len);
    try testing.expectEqualSlices(u8, &h2.bytes, &heads2[0].bytes);
}

test "a merge equals the same changes applied to this document directly" {
    const gpa = testing.allocator;
    var base = try buildBase(gpa);
    defer base.deinit();
    const common = try onlyHead(&base, gpa);

    var left = try base.clone(gpa);
    defer left.deinit();
    var right = try base.clone(gpa);
    defer right.deinit();
    _ = try addKeyChange(&left, gpa, actor_b, 1, 2, "from_b", &.{common});
    _ = try addKeyChange(&right, gpa, actor_c, 1, 2, "from_c", &.{common});

    // Through the merge: the changes are re-derived from the *other* document's
    // op set, decoded, and merged as a batch.
    var merged = try left.clone(gpa);
    defer merged.deinit();
    const heads = try merged.merge(gpa, &right);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 2), heads.len);

    // Directly: the same changes, handed over one at a time.
    var direct = try left.clone(gpa);
    defer direct.deinit();
    // **`getChangesAdded` answers "the changes in the argument that `self`
    // does not have"** — upstream's "Get changes in `other` that are not in
    // `self` (`automerge.rs:1531-1552`, `autocommit.rs:640-644`), and measured:
    // the `loadinc` oracle's `getchangesadded` record runs it both ways round
    // over one forked pair and each call answers with the *argument's* change.
    // Asking `right` for what `direct` lacks is the other direction, and it
    // answers with `left`'s own change — which `direct` already holds, so
    // `applyChanges` skips it on the hash check and `direct` never learns
    // anything. That is a silently empty comparison, not a failing merge.
    var added = try direct.getChangesAdded(gpa, &right);
    defer added.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), added.len());
    const added_view = try asChanges(gpa, added.slice());
    defer gpa.free(added_view);
    _ = try direct.applyChanges(gpa, added_view);

    try merged.debugCmp(&direct);
    var merged_heads = try merged.getHeads(gpa);
    defer gpa.free(merged_heads);
    const direct_heads = try direct.getHeads(gpa);
    defer gpa.free(direct_heads);
    try testing.expectEqual(direct_heads.len, merged_heads.len);
    for (direct_heads, 0..) |want, i| {
        try testing.expectEqualSlices(u8, &want.bytes, &merged_heads[i].bytes);
    }
}

test "a change that repeats a sequence number is refused through applyChanges and through merge" {
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();

    const before = try doc.save(gpa);
    defer gpa.free(before);
    const heads_before = try doc.getHeads(gpa);
    defer gpa.free(heads_before);
    const queued_before = doc.queue.len();

    // Actor a already has a change at sequence 1, so **a different** change at
    // (actor a, 1) is a second claim on one slot, not a repeat
    // (`batch.rs:1073-1077`). It is refused on the sequence number, and its
    // different contents are what stop the hash check from skipping it first.
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("hijack"), .value = .{ .str = "no" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    var clash = try handChange(&doc, gpa, actor_a, 1, 1, &.{}, null, ops);
    defer clash.deinit(gpa);
    try testing.expect(!clash.change.hash.eql(heads_before[0]));

    try testing.expectError(
        error.DuplicateSeqNumber,
        doc.applyChanges(gpa, &.{clash.change}),
    );

    // **Nothing moved**: the same bytes, the same heads, the same queue.
    const after = try doc.save(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    const heads_after = try doc.getHeads(gpa);
    defer gpa.free(heads_after);
    try testing.expectEqual(heads_before.len, heads_after.len);
    for (heads_before, 0..) |want, i| {
        try testing.expectEqualSlices(u8, &want.bytes, &heads_after[i].bytes);
    }
    try testing.expectEqual(queued_before, doc.queue.len());

    // **The same refusal through a merge**, which is how a caller reaches it:
    // `other` holds a *different* change at (actor a, 1), and `doc` holds its
    // own, so the screen sees a second claim on one slot.
    var other = try Document.init(gpa, std.testing.io);
    defer other.deinit();
    const oa = try other.putActorRef(gpa, .{ .bytes = actor_a });
    const ops2 = try buildOps(gpa, oa, &specs);
    defer freeChangeOps(gpa, ops2);
    var merged_clash = try handChange(&other, gpa, actor_a, 1, 1, &.{}, null, ops2);
    defer merged_clash.deinit(gpa);
    _ = try other.applyChanges(gpa, &.{merged_clash.change});

    try testing.expectError(error.DuplicateSeqNumber, doc.merge(gpa, &other));
    const after_merge = try doc.save(gpa);
    defer gpa.free(after_merge);
    try testing.expectEqualSlices(u8, before, after_merge);
    const heads_final = try doc.getHeads(gpa);
    defer gpa.free(heads_final);
    try testing.expectEqual(heads_before.len, heads_final.len);
    for (heads_before, 0..) |want, i| {
        try testing.expectEqualSlices(u8, &want.bytes, &heads_final[i].bytes);
    }
    try testing.expectEqual(queued_before, doc.queue.len());
}

test "two changes claiming one author are refused, through applyChanges and through merge" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    const c = try doc.putActorRef(gpa, .{ .bytes = actor_c });

    const first_specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("one"), .value = .{ .str = "1" } },
    };
    const second_specs = [_]OpSpec{
        .{ .ctr = 2, .key = KeyRef.fromStr("two"), .value = .{ .str = "2" } },
    };
    const ops_one = try buildOps(gpa, c, &first_specs);
    defer freeChangeOps(gpa, ops_one);
    const ops_two = try buildOps(gpa, c, &second_specs);
    defer freeChangeOps(gpa, ops_two);

    // **One actor has one author, and the refusal has two arms**
    // ([`apply_changes_batch_log_patches`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs):1084-1090):
    // a change that carries an author is refused when the **document** already
    // has one for that actor (`get_author_for_actor`) or when an **earlier
    // change in the same batch** gave it one (`actor_author`).
    //
    // **A first author is accepted.** The check asks whether the actor already
    // has one, and a document that has never applied a change by this actor has
    // nothing to conflict with — so an earlier version of this fixture, which
    // handed a single authored change to a document holding no changes and
    // expected a refusal, asserted a rule the reference does not have. The
    // fixture below applies the first change first, which is the state the rule
    // is about.
    var first = try handChange(&doc, gpa, actor_c, 1, 1, &.{}, "alice", ops_one);
    defer first.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try doc.applyChanges(gpa, &.{first.change}));
    try testing.expectEqualStrings("alice", doc.getAuthorForActor(.{ .bytes = actor_c }).?);

    // The second change is by the same actor and carries the same author.
    var second = try handChange(&doc, gpa, actor_c, 2, 2, &.{first.change.hash}, "alice", ops_two);
    defer second.deinit(gpa);
    try testing.expectError(
        error.DuplicateAuthor,
        doc.applyChanges(gpa, &.{second.change}),
    );
    try testing.expect(!doc.hasChange(second.change.hash));
    // **A refusal applies nothing and queues nothing**: `queue.extend` is after
    // the loop the checks run in (`batch.rs:1100`).
    try testing.expectEqual(@as(usize, 1), doc.graph.len());
    try testing.expectEqual(@as(usize, 0), doc.queue.len());

    // **The second arm: two changes in one batch, by one actor, with two
    // authors.** `actor_author` is the set of actors an earlier change in this
    // batch has already given an author
    // ([`batch.rs:1054-1064`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)
    // fills it, [`:1084-1090`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)
    // reads it), so the second change of the batch is refused even though the
    // document itself has no author for the actor yet.
    //
    // **The merge route is not a second case of this rule and is not tested as
    // one.** `merge` hands over exactly the changes the target lacks, by hash,
    // so any peer change that could reach the author check for an actor the
    // target has already authored must sit at a later sequence than the
    // target's — and a peer change at sequence N needs that actor's sequence 1
    // to exist, which is the `(actor, seq)` the target already holds. The
    // sequence check ([`:1073-1077`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs))
    // fires first, and that is a different rule with its own test above.
    var fresh = try Document.init(gpa, std.testing.io);
    defer fresh.deinit();
    const fc = try fresh.putActorRef(gpa, .{ .bytes = actor_c });
    const f1 = try buildOps(gpa, fc, &first_specs);
    defer freeChangeOps(gpa, f1);
    const f2 = try buildOps(gpa, fc, &second_specs);
    defer freeChangeOps(gpa, f2);
    var bob1 = try handChange(&fresh, gpa, actor_c, 1, 1, &.{}, "bob", f1);
    defer bob1.deinit(gpa);
    var carol2 = try handChange(&fresh, gpa, actor_c, 2, 2, &.{bob1.change.hash}, "carol", f2);
    defer carol2.deinit(gpa);
    try testing.expectError(
        error.DuplicateAuthor,
        fresh.applyChanges(gpa, &.{ bob1.change, carol2.change }),
    );
    // **Nothing landed**: `queue.extend` is after the loop the checks run in
    // ([`batch.rs:1100`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)).
    try testing.expectEqual(@as(usize, 0), fresh.graph.len());
    try testing.expectEqual(@as(usize, 0), fresh.queue.len());
    try testing.expectEqual(@as(?[]const u8, null), fresh.getAuthorForActor(.{ .bytes = actor_c }));
    // The author's own document keeps the author it had.
    try testing.expectEqualStrings("alice", doc.getAuthorForActor(.{ .bytes = actor_c }).?);
}

test "a clone shares nothing mutable with the document it was cloned from" {
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();
    var copy = try doc.clone(gpa);
    defer copy.deinit();

    // The clone starts equal, carries the same actor, and answers every reader
    // the same way.
    try doc.debugCmp(&copy);
    try testing.expectEqualStrings(doc.getActorId().bytes, copy.getActorId().bytes);
    try testing.expectEqual(doc.stats(), copy.stats());

    // **Mutate the clone.** A clone that shared the op set's columns or the
    // graph's nodes would show it here.
    const heads = try copy.getHeads(gpa);
    defer gpa.free(heads);
    _ = try addKeyChange(&copy, gpa, actor_c, 1, 15, "only_in_the_clone", heads);

    try testing.expectError(error.Invariant, doc.debugCmp(&copy));
    const text = try doc.text(gpa, .{ .id = OpId.init(2, 0) });
    defer gpa.free(text);
    try testing.expectEqualStrings("hi!", text);
    try testing.expectEqual(@as(usize, 14), doc.len());
    try testing.expectEqual(@as(usize, 2), doc.graph.len());
    try testing.expectEqual(@as(usize, 3), copy.graph.len());
}

test "forkAt reads back the state at the heads it was given, and refuses a head it does not hold" {
    const gpa = testing.allocator;
    var doc = try buildBase(gpa);
    defer doc.deinit();
    const common = try onlyHead(&doc, gpa);
    const later = try addKeyChange(&doc, gpa, actor_a, 2, 2, "later", &.{common});

    var at_common = try doc.forkAt(gpa, &.{common});
    defer at_common.deinit();
    try testing.expectEqual(@as(usize, 1), at_common.len());
    var common_heads = try at_common.getHeads(gpa);
    defer gpa.free(common_heads);
    try testing.expectEqualSlices(u8, &common.bytes, &common_heads[0].bytes);

    var at_later = try doc.forkAt(gpa, &.{later});
    defer at_later.deinit();
    try testing.expectEqual(@as(usize, 2), at_later.len());
    var later_heads = try at_later.getHeads(gpa);
    defer gpa.free(later_heads);
    try testing.expectEqualSlices(u8, &later.bytes, &later_heads[0].bytes);
    // A fresh actor, so the fork does not share a sequence counter with the
    // document it came from.
    try testing.expect(!std.mem.eql(u8, doc.getActorId().bytes, at_later.getActorId().bytes));

    // **An unknown head is an error, not an empty document.**
    const unknown = ChangeHash.fromChecksum(.{ 0xde, 0xad, 0xbe, 0xef });
    try testing.expectError(
        error.InvalidHash,
        doc.forkAt(gpa, &.{unknown}),
    );
}

test "an empty document answers every entry point rather than trapping" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    try testing.expect(doc.isEmpty());
    try testing.expectEqual(@as(usize, 0), doc.len());
    try testing.expectEqual(defaultTextEncoding(), doc.textEncoding());
    try testing.expectEqual(ObjType.map, try doc.objectType(.root));
    try testing.expectEqual(@as(?ObjId, null), doc.objectParent(.{ .id = OpId.init(1, 0) }));
    try testing.expectEqual(ExId.root, doc.idToExid(OpId.root));
    try testing.expectEqual(@as(usize, 0), doc.numActors());
    try testing.expectEqual(@as(?ActorIdx, null), doc.getActorIndex());
    try testing.expectEqual(@as(?[]const u8, null), doc.getAuthor());
    try testing.expectEqual(@as(?[]const u8, null), doc.getAuthorForActor(.{ .bytes = actor_a }));
    try testing.expectEqual(@as(?[]ChangeHash, null), doc.isolationHeads());
    try testing.expect(!doc.hasChange(ChangeHash.zero));

    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 0), heads.len);

    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expect(changes.isEmpty());

    try testing.expectEqual(@as(?Built, null), try doc.getChangeByHash(gpa, ChangeHash.zero));
    try testing.expectEqual(@as(?Built, null), try doc.getLastLocalChange(gpa));

    // A head the document does not have is missing, which is what a peer that
    // asks for nothing gets told.
    const wanted = ChangeHash.fromChecksum(.{ 1, 2, 3, 4 });
    const missing = try doc.getMissingDeps(gpa, &.{wanted});
    defer gpa.free(missing);
    try testing.expect(missing.len >= 1);
    try testing.expectEqualSlices(u8, &wanted.bytes, &missing[0].bytes);

    const actors = try doc.getActors(gpa);
    defer gpa.free(actors);
    try testing.expectEqual(@as(usize, 0), actors.len);
    const none = try doc.getActorForAuthor(gpa, "nobody");
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    const text = try doc.text(gpa, .root);
    defer gpa.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);

    // An empty document saves, and what it saves loads back as an empty
    // document.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer reloaded.deinit();
    try reloaded.debugCmp(&doc);
    try testing.expect(reloaded.isEmpty());

    // An *uncommitted* document — one with changes but nothing of its own —
    // reports no last local change, because its actor has issued nothing.
    var with_changes = try buildSample(gpa);
    defer with_changes.deinit();
    try testing.expectEqual(@as(?Built, null), try with_changes.getLastLocalChange(gpa));
}

test "a change's actor list is mapped, not copied: a second actor that sorts first" {
    // **The mapping is invisible with one actor, and with a second actor that
    // sorts after the first.** A change's own actor is local index 0 and the
    // actors it references come after, so `actors[0]` is the author only by
    // accident of ordering. Here the second actor sorts *before* the first, so
    // the change's actor list is the permutation [1, 0] and a decoder that
    // returned the local index instead of the document one would write the
    // first actor's rows against the second actor's id.
    const gpa = testing.allocator;
    const first = "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0";
    const second = "1111111111111111111111111111111111";

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    _ = try doc.putActorRef(gpa, .{ .bytes = first });
    const b = try doc.putActorRef(gpa, .{ .bytes = second });
    // The point of the fixture: the *later* actor sorts first.
    try testing.expectEqual(@as(ActorIdx, 0), b);
    // **And `a` is re-read, not remembered.** Interning `second` at index 0
    // renumbered the table: `insert_actor` rewrites every index at or above the
    // insertion point ([`automerge.rs:1301-1307`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so the value `putActorRef` returned a moment ago names the other actor
    // now. An index captured before the insert is exactly the trap this
    // fixture exists to catch.
    const a = try doc.putActorRef(gpa, .{ .bytes = first });
    try testing.expectEqual(@as(ActorIdx, 1), a);

    const list_id = ExId{ .id = OpId.init(1, a) };
    const specs_a = [_]OpSpec{
        .{ .ctr = 1, .action = .make_list, .key = KeyRef.fromStr("list") },
        .{ .ctr = 2, .obj = list_id, .key = KeyRef.fromElemId(ElemId.head()), .insert = true, .value = .{ .str = "x" } },
    };
    const ops_a = try buildOps(gpa, a, &specs_a);
    defer freeChangeOps(gpa, ops_a);
    const h1 = try applyHandChange(&doc, gpa, first, 1, 1, &.{}, null, ops_a);

    // The second change's author sorts *first*, and it writes into the first
    // actor's list, so every id in it needs the mapping.
    const specs_b = [_]OpSpec{
        .{ .ctr = 3, .obj = list_id, .key = KeyRef.fromElemId(ElemId.fromOpId(OpId.init(2, a))), .insert = true, .value = .{ .str = "y" } },
    };
    const ops_b = try buildOps(gpa, b, &specs_b);
    defer freeChangeOps(gpa, ops_b);
    _ = try applyHandChange(&doc, gpa, second, 1, 3, &.{h1}, null, ops_b);

    // The object the second change wrote into is the one the first made, and
    // it is a list, not a missing object.
    try testing.expectEqual(ObjType.list, try doc.objectType(list_id));
    try testing.expectEqual(@as(usize, 3), doc.len());

    const text = try doc.text(gpa, list_id);
    defer gpa.free(text);
    try testing.expectEqualStrings("xy", text);
}

test "an uncommitted document's last local change is the commit it just made" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = actor_a });
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .str = "v" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    // **The rows are written before the commit, because that is the order
    // upstream commits in**: `insert_local_op` splices each op as the
    // transaction goes (`inner.rs:308-328`) and `commit_impl` exports
    // `doc.ops()` (`inner.rs:157-170`). `Document.commit` encodes and links,
    // so a document that has only been committed holds a hash with nothing
    // behind it — a state upstream cannot reach, and one
    // [`Document.getLastLocalChange`] answers `error.Fail` on.
    try testing.expectEqual(@as(usize, 1), doc.ops.splice(0, ops));
    const args = try doc.transactionArgs(gpa, null);
    defer args.deinit(gpa);
    const hash = try doc.commit(gpa, args, ops, "m", 1);

    var last = (try doc.getLastLocalChange(gpa)).?;
    defer last.deinit(gpa);
    try testing.expectEqualSlices(u8, &hash.bytes, &last.change.hash.bytes);
}

test "a local commit's message and author footer survive the collector's re-encoding" {
    // **The bytes a change is hashed over include its message and its footer.**
    // `node_info` is the only record of either, and the collector rebuilds the
    // change from it, so dropping either produced a document that loaded, held
    // the right hash, and handed a peer different bytes under it.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setAuthor(gpa, "a person") catch |e| return e;
    doc.setActorId(.{ .bytes = actor_a });
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .str = "v" } },
    };
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);

    // **The transaction writes the rows; `commit` only encodes and links** —
    // [`insert_local_op`, `inner.rs:308-328`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)
    // against [`commit_impl`, `inner.rs:157-170`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
    // which is why upstream's `export` takes `doc.ops()`. A document that has
    // only been committed holds hashes and no rows, so this fixture does what
    // the transaction does before it commits. **One row**, because
    // `OpSet.splice` returns "how many **rows** were written"
    // ([`op_set.zig:1453-1454`](opset/op_set.zig)) and this op is a write, not a
    // delete.
    try testing.expectEqual(@as(usize, 1), doc.ops.splice(0, ops));
    const args = try doc.transactionArgs(gpa, null);
    defer args.deinit(gpa);
    const hash = try doc.commit(gpa, args, ops, "a message", 1_700_000_000);
    try testing.expectEqual(@as(usize, 1), doc.len());

    var got = (try doc.getChangeByHash(gpa, hash)).?;
    defer got.deinit(gpa);
    try testing.expectEqualSlices(u8, &hash.bytes, &got.change.hash.bytes);
    try testing.expectEqualStrings("a message", got.change.message);
    try testing.expectEqualStrings("a person", (try decodeAuthorFooter(changeFooter(got.change))).?);
    // **The graph knows the document's highest op counter.** Every symptom of a
    // graph that does not is somewhere else — a conflict flag that reads as an
    // overwrite, a counter that doubles, an object whose type is the last one
    // written, `pendingOps` that never reaches zero — because the number itself
    // is only read by `TransactionArgs.start_op`.
    try testing.expectEqual(@as(u64, 1), doc.graph.maxOp());
    // The rebuilt bytes are the committed bytes, not merely a change that hashes
    // the same.
    try testing.expectEqualSlices(u8, got.change.bytes, got.body);
}

/// One change's worth of `n` operations on `n` distinct map keys, with `n`
/// distinct values, numbered from `first_ctr`.
///
/// **Every column that can be a literal run is one here**, and that is the
/// whole reason for the fixture. A run of equal values costs three bytes
/// however long it is, so an encoder handed the same key and the same value
/// `n` times is measured on its bookkeeping and not on its work. Distinct
/// keys, counters and values put `key_str`, `obj_ctr`, `value_meta` and
/// `value` into literal runs of `n` rows — the most work per row
/// [`encodeChangeOps`] can be asked for, and therefore the shape in which a
/// superlinear cost shows soonest rather than late.
///
/// The keys are written into one buffer and the specs borrow slices of it,
/// which is the lifetime [`OpBuilder.init`] asks of its caller
/// ([`op.zig`:703](opset/op.zig)).
fn changeSpecs(
    gpa: Allocator,
    first_ctr: u32,
    n: usize,
) !struct { keys: []u8, specs: []OpSpec } {
    // Twelve bytes a key, of which the printed form takes eight: `k` and
    // seven digits. The slack is what lets the one `bufPrint` below answer a
    // width it cannot meet with an error rather than with a trap.
    const keys = try gpa.alloc(u8, n * 12);
    errdefer gpa.free(keys);
    const specs = try gpa.alloc(OpSpec, n);
    errdefer gpa.free(specs);
    for (specs, 0..) |*spec, i| {
        const key = std.fmt.bufPrint(keys[i * 12 ..][0..8], "k{d:0>7}", .{i}) catch
            return error.Overflow;
        spec.* = .{
            .ctr = first_ctr + @as(u32, @intCast(i)),
            .key = KeyRef.fromStr(key),
            .value = .{ .int = @intCast(i) },
        };
    }
    return .{ .keys = keys, .specs = specs };
}

/// The bytes [`Document.commit`] allocates for one change of `n` operations,
/// on a document that already holds `prior` operations in one earlier change.
///
/// **The counter is read around the commit and around nothing else.** The
/// document, its actors, the operations, the rows they name and the
/// transaction's own arguments are all built first, so what the difference
/// measures is the encoder, the body's SHA-256 and the graph's one node —
/// everything a commit does — and none of the cost of arriving at it.
///
/// `prior` is what makes the second test below possible: it puts rows the
/// commit has no business reading underneath it, and the question is whether
/// they move the number.
fn commitAllocBytes(gpa: Allocator, n: usize, prior: usize) !usize {
    // **`FailingAllocator` with no `fail_index` never fails**, so it is a real
    // allocator and a byte counter at once
    // ([`values.zig`:1225-1228](iter/values.zig)), and `allocated_bytes` is
    // cumulative — a free adds to `freed_bytes` and takes nothing off it
    // ([`marks.zig`:1013-1017](marks.zig)), which is exactly what a difference
    // of two readings wants.
    var failing: testing.FailingAllocator = .init(gpa, .{});
    const inner = failing.allocator();
    var doc = try Document.init(inner, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = actor_a });
    const a = try doc.putActorRef(inner, .{ .bytes = actor_a });

    // The earlier change, when there is one. It goes through the same door and
    // through the same counter, and it runs entirely before the snapshot.
    if (prior != 0) {
        const earlier = try changeSpecs(gpa, 1, prior);
        defer gpa.free(earlier.keys);
        defer gpa.free(earlier.specs);
        const ops = try buildOps(inner, a, earlier.specs);
        defer freeChangeOps(inner, ops);
        // One row per op, because every one of them is a write and not a
        // delete (`op_set.zig:1453-1454`, said at `doc.zig:9219-9222`).
        try testing.expectEqual(prior, doc.ops.splice(0, ops));
        const args = try doc.transactionArgs(inner, null);
        defer args.deinit(inner);
        _ = try doc.commit(inner, args, ops, null, 1);
    }

    // The transaction's own arguments come first because they carry the
    // counter the change starts at (`doc.zig:3398`), and the operations have
    // to be numbered from it.
    const args = try doc.transactionArgs(inner, null);
    defer args.deinit(inner);
    const made = try changeSpecs(gpa, std.math.cast(u32, args.start_op) orelse
        return error.Overflow, n);
    defer gpa.free(made.keys);
    defer gpa.free(made.specs);
    const ops = try buildOps(inner, a, made.specs);
    defer freeChangeOps(inner, ops);
    try testing.expectEqual(n, doc.ops.splice(0, ops));

    const before = failing.allocated_bytes;
    _ = try doc.commit(inner, args, ops, null, 2);
    return failing.allocated_bytes - before;
}

test "a commit costs what its own operations cost, and not their square" {
    const gpa = testing.allocator;
    const small = 256;
    const large = 4 * small;
    const at_small = try commitAllocBytes(gpa, small, 0);
    const at_large = try commitAllocBytes(gpa, large, 0);
    std.debug.print(
        "#   commit: {d} ops allocate {d} bytes, {d} ops allocate {d}\n",
        .{ small, at_small, large, at_large },
    );

    // **The ratio, and why eight.** Bytes and not nanoseconds, so the number
    // is the same on every run and does not move with the host's load. A
    // linear encoder allocates `c * n` and reads 4.0 across a 4x size change;
    // a quadratic one allocates `c * n * n` and reads 16.0. Eight sits
    // between the two with room either way.
    //
    // **What this does and does not prove.** It pins the allocation shape,
    // which is what a quadratic copy or a quadratic re-encode shows up as. A
    // cost quadratic in comparisons alone would allocate nothing extra and
    // pass here; that claim belongs to `insert-loop` in
    // `bench/zautomerge_bench.zig`, which measures it instead of arguing it.
    try testing.expect(at_small > 0);
    try testing.expect(at_large <= 8 * at_small);
}

test "a commit does not read the rows the document already holds" {
    const gpa = testing.allocator;
    const n = 256;
    const prior = 8 * n;
    const on_empty = try commitAllocBytes(gpa, n, 0);
    const on_loaded = try commitAllocBytes(gpa, n, prior);
    std.debug.print(
        "#   commit: {d} ops over 0 rows allocate {d} bytes, over {d} rows {d}\n",
        .{ n, on_empty, prior, on_loaded },
    );

    // **The rows underneath are the document's, and the change's are not.**
    // `Document.commit` encodes the `ops` it was handed and links one graph
    // node (`doc.zig:5207-5216`); the op set is not read at all, so rows under
    // it cannot move the number. An encoder that walked the document instead
    // would read every one of the eight-times-larger set where this reads
    // none, and the ratio would be near nine rather than near one.
    //
    // The arms differ in one more thing, because a change must: the loaded
    // document's second change names the first as a dependency, so its header
    // carries thirty-two more bytes. Three leaves that and the graph's own
    // per-node growth room a long way below the ceiling.
    try testing.expect(on_empty > 0);
    try testing.expect(on_loaded <= 3 * on_empty);
}

test "an actor that sorts before one already in the table lands in the middle" {
    // **The insertion point is `binary_search`'s `Err` arm, not the end**
    // ([`automerge.rs:1309-1315`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and every stored actor index at or above it is renumbered
    // ([`:1301-1307`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // The property is the *table*, because the renumbering is invisible in a
    // single document with one actor.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    const high = "ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00";
    const low = "0011001100110011001100110011001100110011001100110011";

    const high0 = try doc.putActorRef(gpa, .{ .bytes = high });
    try testing.expectEqual(@as(ActorIdx, 0), high0);
    const low0 = try doc.putActorRef(gpa, .{ .bytes = low });
    try testing.expectEqual(@as(ActorIdx, 0), low0);
    // **`high` moved**, and the lookup says so from either side.
    const high1 = try doc.putActorRef(gpa, .{ .bytes = high });
    try testing.expectEqual(@as(ActorIdx, 1), high1);
    try testing.expectEqual(@as(ActorIdx, 0), doc.ops.lookupActor(.{ .bytes = low }).?);
    try testing.expectEqual(@as(ActorIdx, 1), doc.ops.lookupActor(.{ .bytes = high }).?);
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    // A third in the middle again, and the two below it are untouched.
    const mid = "7788";
    _ = try doc.putActorRef(gpa, .{ .bytes = mid });
    try testing.expectEqual(@as(ActorIdx, 1), doc.ops.lookupActor(.{ .bytes = mid }).?);
    try testing.expectEqual(@as(ActorIdx, 2), doc.ops.lookupActor(.{ .bytes = high }).?);
}

test "a no-op commit survives a merge: the cached actor index is rewritten with the table" {
    // **Upstream's `rollback_with_no_ops`, with its actor order pinned.**
    // [`test.rs:2746-2772`](../../github-automerge-automerge/rust/automerge/tests/test.rs)
    // forks, opens a transaction, commits it with no operations, forks again,
    // writes, merges, and opens a transaction on the merged document. The
    // commit of an **empty** transaction is not the degenerate case it looks
    // like: `TransactionInner::commit` drops the actor the transaction created
    // and returns no change (`[`inner.rs:136-143`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)`),
    // so the actor table **shrinks** between the transaction and the merge.
    //
    // Upstream keeps that shrink honest from one line —
    // `self.actor.remove_actor(actor, &self.ops.actors)`
    // ([`automerge.rs:428`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
    // [`Actor::remove_actor`](doc.zig):52-61 of the same file) — and the port
    // did not, so the cached index outlived the slot it named. That is a
    // **silent rename, not an off-by-one**: the actor below the freed slot
    // moves into it, and the cached index comes to name a different actor. The
    // merge below is what turns it into a panic: interning an actor that sorts
    // first shifts the stale index up one more, and the next transaction reads
    // it past the end of the table.
    //
    // The actors are named rather than drawn, because the whole defect is an
    // ordering: `actor_c` sorts after `actor_b` (the `Equal` case of the
    // removal, and the case that captures stale-ness) and `actor_a` sorts
    // before it (the insertion that renumbers and detonates).
    const gpa = testing.allocator;
    const trans = @import("transact.zig");
    const readonly = @import("read.zig");

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = actor_b });
    {
        var tx = try trans.Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "a" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    try testing.expectEqual(@as(usize, 1), doc.numActors());

    const forkHeads = try doc.getHeads(gpa);
    defer gpa.free(forkHeads);

    // Step 2: fork, open, commit with no operations. **`actor_c` is set on the
    // fork** so the commit's actor slots *after* the document's: the removal
    // then hits the cached index exactly, which is the case that used to
    // rename the document's actor.
    var doc2 = try doc.forkAt(gpa, forkHeads);
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = actor_c });
    const actor_before = doc2.getActorId();
    try testing.expectEqualStrings(actor_c, actor_before.bytes);
    {
        var tx = try trans.Transaction.open(gpa, &doc2);
        defer tx.deinit() catch unreachable;
        // The transaction interned `actor_c` at the end of the table.
        try testing.expectEqual(@as(ActorIdx, 1), tx.actor);
        try testing.expectEqual(@as(u64, 1), tx.seq);
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        try testing.expectEqual(@as(?ChangeHash, null), committed.hash);
    }
    // **The table is back to one actor and the document's actor is the same
    // actor it was.** The index is *not* the same number — that is the point —
    // and checking the bytes is what distinguishes a rewrite from a rename.
    try testing.expectEqual(@as(usize, 1), doc2.numActors());
    try testing.expectEqualStrings(actor_c, doc2.getActorId().bytes);

    // Step 3: a second fork writes into the document `doc` did not have.
    var doc3 = try doc.forkAt(gpa, forkHeads);
    defer doc3.deinit();
    doc3.setActorId(.{ .bytes = actor_a });
    {
        var tx = try trans.Transaction.open(gpa, &doc3);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "b" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }

    // Step 4: the merge interns `actor_a`, which sorts **first**, so every
    // index in `doc2` moves and the cached one moves with them.
    {
        const heads = try doc2.merge(gpa, &doc3);
        gpa.free(heads);
    }

    // **The invariant, asserted as the invariant.** Four tables and one cached
    // index are all views of one numbering ([`Actor`]), and the four are equal
    // byte for byte, not merely equal in length. A merge is the operation that
    // grows the actor table from the outside, so it is the one that has to
    // leave them in step.
    try testing.expectEqual(@as(usize, 2), doc2.numActors());
    try testing.expectEqual(doc2.numActors(), doc2.authors.count());
    try testing.expectEqual(doc2.numActors(), doc2.graph.numActors());
    try testing.expectEqual(doc2.numActors(), doc2.actor_authors.items.len);
    for (doc2.ops.actors.items, 0..) |actor, i| {
        const mirror = (doc2.authors.at(@intCast(i))).?;
        try testing.expectEqualStrings(actor.bytes, mirror.bytes);
    }
    // The cached index is in range **and names the document's actor**, which is
    // stronger than in-range: an index that survived the renumber by accident
    // still fails this line if it landed on the other actor's slot.
    if (doc2.getActorIndex()) |idx| {
        try testing.expect(idx < doc2.numActors());
        try testing.expectEqualStrings(
            doc2.getActorId().bytes,
            doc2.ops.actors.items[idx].bytes,
        );
    }
    try testing.expectEqualStrings(actor_c, doc2.getActorId().bytes);

    // Step 5: the transaction that used to panic. It opens, and the merged
    // value is on the document behind it. **The read is unscoped because the
    // port has no transaction-scoped `get`** — [`am.read.get`](read.zig) takes
    // the document — so what the open proves is the actor index, and what the
    // reads prove is that the merge delivered `doc3`'s change rather than a
    // document that merely has more actors in it.
    {
        var tx = try trans.Transaction.open(gpa, &doc2);
        defer tx.deinit() catch unreachable;
        const b = (try readonly.get(&doc2, ExId.root, .{ .key = "b" })).?;
        try testing.expectEqual(@as(i64, 2), b.value.scalar.int);
        const a = (try readonly.get(&doc2, ExId.root, .{ .key = "a" })).?;
        try testing.expectEqual(@as(i64, 1), a.value.scalar.int);
        _ = try tx.rollback();
    }
    // A rollback of a transaction that wrote nothing leaves the table alone.
    try testing.expectEqual(@as(usize, 2), doc2.numActors());
    try testing.expectEqual(doc2.numActors(), doc2.authors.count());
    try testing.expectEqual(doc2.numActors(), doc2.graph.numActors());
}

test "a load sizes every actor index from the actor table, not from the changes" {
    // **The chunk's actor column is the document's whole table**, not the set
    // of actors its changes name: [`Document.saveChunk`] writes
    // `self.ops.actors.items` in full, so a load can adopt an actor no change
    // in the chunk names — here `z`, interned by [`Document.putActorRef`] and
    // never committed. Upstream sizes both mirrors from that count and never
    // grows either from a change:
    // `ChangeGraph::new` is `seq_index: vec![vec![]; num_actors]`
    // ([`change_graph.rs:102`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
    // with `num_actors = doc.actors().len()` (`:929`), and `Authors::with_actors`
    // is `vec![None; actors]` ([`author.rs:46-52`](../../github-automerge-automerge/rust/automerge/src/author.rs)).
    //
    // Leaving the mirrors to [`ChangeGraph.addChange`](change_graph.zig)'s own
    // interning leaves them **short**, and the second half of this test is what
    // a short mirror does: the next insertion renumbers through a table that
    // is not the authoritative one, and `applyActorInsert` rewrites every
    // node's actor through `authors.remap()`, so a node that did not move is
    // moved anyway and a change written by one actor is attributed to another.
    const gpa = testing.allocator;
    const trans = @import("transact.zig");

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "m" });
    {
        var tx = try trans.Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "a" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    // An actor the table holds and no change ever names.
    _ = try doc.putActorRef(gpa, .{ .bytes = "z" });
    try testing.expectEqual(@as(usize, 2), doc.numActors());

    // A peer whose actor is `z`, so a change from `z` can arrive later.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    peer.setActorId(.{ .bytes = "z" });
    {
        var tx = try trans.Transaction.open(gpa, &peer);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "b" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, std.testing.io, saved, .unicode_code_point);
    defer loaded.deinit();

    // **Every table holds both actors.** The first line is the invariant the
    // rest of this test leans on; the other three are the three mirrors.
    try testing.expectEqual(@as(usize, 2), loaded.numActors());
    try testing.expectEqual(loaded.numActors(), loaded.authors.count());
    try testing.expectEqual(loaded.numActors(), loaded.graph.numActors());
    try testing.expectEqual(loaded.numActors(), loaded.actor_authors.items.len);
    try testing.expectEqualStrings("m", (loaded.authors.at(0).?).bytes);
    try testing.expectEqualStrings("z", (loaded.authors.at(1).?).bytes);

    // **The second index is the one that moves.** "a" sorts before both, so
    // every index at or above zero is renumbered and `m` — the actor the graph
    // already holds a change for — goes from slot 1 to slot 2. The
    // renumbered index is not the one that
    // was inserted, so reading only the new actor back proves nothing.
    _ = try loaded.putActorRef(gpa, .{ .bytes = "a" });
    try testing.expectEqual(@as(usize, 3), loaded.numActors());
    try testing.expectEqual(@as(ActorIdx, 0), loaded.ops.lookupActor(.{ .bytes = "a" }).?);
    try testing.expectEqual(@as(ActorIdx, 1), loaded.ops.lookupActor(.{ .bytes = "m" }).?);
    try testing.expectEqual(@as(ActorIdx, 2), loaded.ops.lookupActor(.{ .bytes = "z" }).?);
    try testing.expectEqual(loaded.numActors(), loaded.authors.count());
    try testing.expectEqual(loaded.numActors(), loaded.graph.numActors());

    // **And a change from the actor that was renumbered into a higher slot
    // still finds its own place.** Before the fix `authors` held only `a` and
    // `m`, so interning `z` produced a remap of `[1, 2, 2]` and every node at
    // or above index 1 moved up one — including `m`'s, which never moved.
    const merged = try loaded.merge(gpa, &peer);
    gpa.free(merged);
    try testing.expectEqual(loaded.numActors(), loaded.authors.count());
    try testing.expectEqual(loaded.numActors(), loaded.graph.numActors());

    // **Every node still names the actor that wrote its change**, read through
    // the authoritative table. This is the whole defect: an index that names a
    // different actor is not a wrong number, it is a different history.
    const heads = try loaded.getHeads(gpa);
    defer gpa.free(heads);
    for (loaded.graph.nodes.items, 0..) |node, at| {
        const who = loaded.getActor(node.actor) orelse {
            std.debug.print("node {d} names actor {d}, which the table does not have\n", .{
                at,
                node.actor,
            });
            return error.TestUnexpectedResult;
        };
        // `a` wrote nothing at all, so no node may name it; the two that did
        // write are `m` and `z`.
        if (!std.mem.eql(u8, who.bytes, "m") and !std.mem.eql(u8, who.bytes, "z")) {
            std.debug.print("node {d} is attributed to actor {s}\n", .{ at, who.bytes });
            return error.TestUnexpectedResult;
        }
    }
    // The clock reads the same table the graph does: `a` has no change, `m`
    // has one and `z` has one.
    var clock = try loaded.graph.clockAt(gpa, heads);
    defer clock.deinit();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1 }, clock.values());
}

test "removing an actor renumbers the cached index without renaming the actor" {
    // The three cases of upstream's `Actor::remove_actor`
    // ([`automerge.rs:52-61`](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
    // read out of the table directly, because each one is a different answer
    // and only the middle one is an arithmetic step. `Ordering::Equal` is the
    // one that cannot be: the slot named is going away, so the index has to
    // become `Unused` and keep the bytes it was pointing at.
    const gpa = testing.allocator;
    const low = "1111";
    const mid = "2222";
    const high = "3333";
    const fmt = [_][]const u8{ low, mid, high };

    // Below the cached index: untouched.
    {
        var doc = try Document.init(gpa, std.testing.io);
        defer doc.deinit();
        _ = try doc.putActorRef(gpa, .{ .bytes = low });
        _ = try doc.putActorRef(gpa, .{ .bytes = mid });
        _ = try doc.putActorRef(gpa, .{ .bytes = high });
        doc.actor = .{ .cached = 2 };
        try doc.removeActor(gpa, 0);
        try testing.expectEqual(@as(ActorIdx, 1), doc.actor.cached);
        try testing.expectEqualStrings(high, doc.getActorId().bytes);
        try testing.expectEqualStrings(mid, doc.authors.values()[0].bytes);
        try testing.expectEqualStrings(high, doc.authors.values()[1].bytes);
    }

    // Above the cached index: no rewrite owed.
    {
        var doc = try Document.init(gpa, std.testing.io);
        defer doc.deinit();
        _ = try doc.putActorRef(gpa, .{ .bytes = low });
        _ = try doc.putActorRef(gpa, .{ .bytes = mid });
        _ = try doc.putActorRef(gpa, .{ .bytes = high });
        doc.actor = .{ .cached = 0 };
        try doc.removeActor(gpa, 2);
        try testing.expectEqual(@as(ActorIdx, 0), doc.actor.cached);
        try testing.expectEqualStrings(low, doc.getActorId().bytes);
    }

    // The cached index's own slot: the actor survives, the index does not.
    {
        var doc = try Document.init(gpa, std.testing.io);
        defer doc.deinit();
        _ = try doc.putActorRef(gpa, .{ .bytes = low });
        _ = try doc.putActorRef(gpa, .{ .bytes = mid });
        _ = try doc.putActorRef(gpa, .{ .bytes = high });
        doc.actor = .{ .cached = 1 };
        try doc.removeActor(gpa, 1);
        try testing.expectEqual(@as(usize, 2), doc.numActors());
        try testing.expectEqual(@as(?ActorIdx, null), doc.getActorIndex());
        try testing.expectEqualStrings(mid, doc.getActorId().bytes);
        // The index it comes back with is the *other* actor's slot now, which
        // is exactly the rename this case exists to prevent: `low` is at 0 and
        // is a different actor.
        try testing.expectEqualStrings(low, doc.ops.actors.items[0].bytes);
        try testing.expectEqualStrings(high, doc.ops.actors.items[1].bytes);
        // Interning it again lands it back where it sorts, and the mirrors
        // follow it there.
        const again = try doc.putActorRef(gpa, .{ .bytes = mid });
        try testing.expectEqual(@as(ActorIdx, 1), again);
        try testing.expectEqual(doc.numActors(), doc.authors.count());
        try testing.expectEqual(doc.numActors(), doc.graph.numActors());
        try testing.expectEqual(doc.numActors(), doc.actor_authors.items.len);
        for (fmt, 0..) |bytes, i| {
            try testing.expectEqualStrings(bytes, doc.ops.actors.items[i].bytes);
            try testing.expectEqualStrings(bytes, doc.authors.values()[i].bytes);
        }
    }
}

test "a refused removeActor leaves every actor table as it found it" {
    // **The order is the thing under test, and an order is only observable
    // through a refusal.** [`Document.removeActor`] rewrites the cached actor
    // **last**, after the two steps that can fail. Rewritten first — as it was
    // — the cached index moves down by one and *then* the call returns an
    // error, so the document's current actor is whichever actor moved into the
    // freed slot while the other tables stand still.
    //
    // **The refusal is reachable through this entry point**, which is what
    // makes the assertions below a test of the fan rather than of the happy
    // path. It is *not* reachable from either of the method's own callers —
    // [`transact.zig`'s rollback of a first change, and
    // [`Document.removeUnusedActors`], which by construction only offers the
    // graph an actor it holds no change for — because both hand over an actor
    // no change wrote, and an actor no change wrote is neither the graph's
    // `assert!` nor a name in a column. So the first half of this test drives
    // [`Document.removeActor`] itself, which is a `pub` method and the only
    // thing a caller outside this repository can call.
    const gpa = testing.allocator;
    const trans = @import("transact.zig");
    const readonly = @import("read.zig");

    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "m" });
    {
        var tx = try trans.Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "a" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    // **Two actors, one change.** `z` is the shape [`Document.putActorRef`]
    // makes on its own — interned and never committed, so a save writes it
    // into the chunk's actor column with no change naming it
    // ([`Document.saveChunk`]) — and `m` is the actor the graph
    // still holds a change for, which is what the graph's refusal is about.
    _ = try doc.putActorRef(gpa, .{ .bytes = "z" });
    // **The cached index is set by hand** rather than left to the commit's
    // bookkeeping: the state under test is the fan, and the index has to name
    // `z` for a rename to be visible as a rename.
    doc.actor = .{ .cached = 1 };

    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try testing.expectEqual(@as(usize, 2), doc.authors.count());
    try testing.expectEqual(@as(usize, 2), doc.graph.numActors());
    try testing.expectEqual(@as(usize, 2), doc.actor_authors.items.len);
    try testing.expectEqual(@as(u64, 1), doc.graph.seqForActor(0));

    // **The refusal.** Slot 0 is `m` and the graph holds `m`'s one change, so
    // the fan refuses it — upstream's
    // `assert!(self.seq_index[idx].is_empty())` (`change_graph.rs:176`),
    // reported rather than asserted, and checked here **before** the op set
    // is touched at all ([`Document.removeActor`] stages every check first).
    //
    // **`error.InvalidActorIndex`, not the graph's own `error.InvalidIndex`**,
    // and the reason is that the document's guard answers before
    // [`ChangeGraph.removeActor`] is reached at all: the check *is* the graph's
    // condition (`seqForActor(idx) != 0`, `doc.zig`:3690-3691`) read through
    // the document's own vocabulary, so the graph's arm is unreachable from
    // here and naming it would pin a tag no caller of this entry point can
    // observe. Both refusals below are therefore the same tag, and what
    // separates them is **which precondition failed** — stated in each
    // comment below — not the error.
    try testing.expectError(error.InvalidActorIndex, doc.removeActor(gpa, 0));

    // **Every table, by name rather than by length.** Four lengths agreeing
    // would also pass on a fan that dropped the slot everywhere and took the
    // actor's change with it; what is pinned here is what is *in* them.
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try testing.expectEqualStrings("m", doc.ops.actors.items[0].bytes);
    try testing.expectEqualStrings("z", doc.ops.actors.items[1].bytes);
    try testing.expectEqual(@as(usize, 2), doc.authors.count());
    try testing.expectEqualStrings("m", doc.authors.values()[0].bytes);
    try testing.expectEqualStrings("z", doc.authors.values()[1].bytes);
    try testing.expectEqual(@as(usize, 2), doc.graph.numActors());
    try testing.expectEqual(@as(usize, 2), doc.actor_authors.items.len);
    // **The change is still the graph's, on the actor that wrote it.** Under
    // the old order this table alone still looked right while the two above it
    // had already lost the slot, which is why it is asserted rather than
    // assumed.
    try testing.expectEqual(@as(u64, 1), doc.graph.seqForActor(0));
    // **And the cached index is the index it was, still naming `z`.** Renumbered
    // to 0 it would name `m` — a different actor, so the number would be in
    // range and the history would be somebody else's.
    try testing.expectEqual(@as(ActorIdx, 1), doc.actor.cached);
    try testing.expectEqualStrings("z", doc.getActorId().bytes);

    // **The second refusal, and it is a different precondition**: slot 2 is
    // past the end of every table, which is the check at `doc.zig`:3685 — the
    // one that makes reading `dropped` below it safe. `OpSet.removeActor`'s own
    // bound is `ArrayList.orderedRemove`'s assert (`opset/op_set.zig:1442`), so
    // before that check existed this trapped — and a trap stops the binary
    // rather than failing an assertion, which is how one defect hides every
    // test after it in the run.
    try testing.expectError(error.InvalidActorIndex, doc.removeActor(gpa, 2));
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try testing.expectEqual(@as(ActorIdx, 1), doc.actor.cached);

    // **The document still works**, which is what "unchanged" has to mean
    // rather than "the numbers are the numbers". The one actor the graph holds
    // no change for is still removable, so the renumbering runs on a coherent
    // set of tables; and `m`'s row is still readable, which is the op set's
    // half of the invariant and the half a length cannot see.
    try doc.removeUnusedActors(gpa);
    try testing.expectEqual(@as(usize, 1), doc.numActors());
    try testing.expectEqual(@as(usize, 1), doc.authors.count());
    try testing.expectEqual(@as(usize, 1), doc.graph.numActors());
    try testing.expectEqual(@as(u64, 1), doc.graph.seqForActor(0));
    try testing.expectEqual(@as(?ActorIdx, null), doc.getActorIndex());
    // The cached index was the slot being dropped, so the actor survives as
    // bytes: upstream's `Ordering::Equal` arm, reached through the same call
    // the two refusals came out of.
    try testing.expectEqualStrings("z", doc.getActorId().bytes);
    const a = (try readonly.get(&doc, ExId.root, .{ .key = "a" })).?;
    try testing.expectEqual(@as(i64, 1), a.value.scalar.int);
}

test "an actor's author survives the changes that carry no footer" {
    // The rule is `change_graph.rs:563-566`: `assign_author` is called under
    // `if let Some(author) = change.author()`, so of an actor's many changes
    // only the one carrying a footer records anything.
    //
    // **Writing the absent author over the slot instead loses the author from
    // the table rather than duplicating it**, because the table's set of
    // authors is its distinct non-null entries. `get_authors()` then answers
    // one name where upstream answers two.
    const gpa = testing.allocator;
    const trans = @import("transact.zig");

    // **A missing author fails this test with a message rather than a panic.**
    // `.?` on the optional would abort the whole run, and the rest of the
    // suite would never execute — which is the one thing a regression test
    // must not do.
    const expectAuthor = struct {
        fn check(d: *const Document, a: ActorId, want: ?[]const u8) !void {
            // **The offending author is named by its actor, never printed.**
            // An unexpected author here can be an undefined slot, and reading
            // its bytes to print it is a fault rather than a diagnosis.
            const got = d.getAuthorForActor(a);
            if (want == null) {
                if (got != null) {
                    std.debug.print("actor {x} has an author, expected none\n", .{a.bytes});
                    return error.UnexpectedAuthor;
                }
                return;
            }
            if (got == null or !std.mem.eql(u8, got.?, want.?)) {
                std.debug.print("actor {x} has the wrong author, expected {x}\n", .{ a.bytes, want.? });
                return error.WrongAuthor;
            }
        }
    }.check;

    const author = "a person";
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    // `setAuthor` mints a fresh actor (`automerge.rs:389-396`), and this one
    // is the actor whose footer is written.
    try doc.setAuthor(gpa, author);
    const actor = doc.getActorId();

    {
        var tx = try trans.Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "a" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    // `seq == 1`, so this change carries the footer (`automerge.rs:568`).
    try expectAuthor(&doc, actor, author);

    {
        var tx = try trans.Transaction.open(gpa, &doc);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(ExId.root, .{ .key = "a" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    // **`seq == 2`, so this change carries none — and an absent footer records
    // nothing rather than clearing what the first change recorded.**
    try expectAuthor(&doc, actor, author);

    // **And the other direction still answers.** One actor, one author.
    const actors = try doc.getActorForAuthor(gpa, author);
    defer gpa.free(actors);
    try testing.expectEqual(@as(usize, 1), actors.len);
    try testing.expect(actors[0].eql(actor));

    // **And a save/load rebuilds the same table from the footers**
    // (`test.rs`:3511-3526), with the empty actor — which no change names, and
    // so which no footer ever fills — answering null rather than whatever was
    // in the buffer the list grew into (`Document.growActorAuthors`). **The
    // empty actor is the one that proves it**: it is the only slot no footer
    // ever writes, so a list grown with `ArrayList.resize` leaves it undefined
    // and `getAuthorForActor` hands the caller a garbage length.
    // **Every slot is asserted, not just the ones a footer filled.** The one
    // actor no change names is the one that proves it: it is the only slot no
    // footer ever writes, so a table grown with `ArrayList.resize` leaves that
    // slot undefined and `getAuthorForActor` hands the caller whatever was
    // there. **The count below is what keeps this honest** — a table that
    // answered `null` for an actor it had never heard of, and nothing else,
    // would pass a spot check.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, std.testing.io, saved, .unicode_code_point);
    defer loaded.deinit();
    try expectAuthor(&loaded, actor, author);
    var named_by_a_footer: usize = 0;
    for (loaded.ops.actors.items) |candidate| {
        if (candidate.bytes.len == 0) {
            try expectAuthor(&loaded, candidate, null);
            continue;
        }
        try expectAuthor(&loaded, candidate, author);
        named_by_a_footer += 1;
    }
    try testing.expectEqual(@as(usize, 1), named_by_a_footer);
}

test "growing the author table fills every new slot with null" {
    // **This is the invariant the save/load case above can only reach by
    // luck.** A freshly mapped page reads as zero, and a zeroed `?[]const u8`
    // is a null slice, so a table grown with `ArrayList.resize` answers `null`
    // correctly the first time and is caught nowhere. The slots here already
    // hold a non-null author when the growth runs, which is the state a reused
    // buffer is in, and `resize` would leave that author standing in a slot
    // that no footer ever filled.
    //
    // **The length is shrunk first rather than the list freed**, because
    // `shrinkRetainingCapacity` keeps the buffer and its contents while
    // `deinit` would hand the block back to the allocator — and whether the
    // next allocation reads zeros or leftovers is exactly the thing this test
    // must not depend on.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    _ = try doc.putActorRef(gpa, .{ .bytes = "a" });
    _ = try doc.putActorRef(gpa, .{ .bytes = "b" });
    try testing.expectEqual(@as(usize, 2), doc.ops.actors.items.len);

    try doc.actor_authors.appendNTimes(gpa, "an author from an earlier change", 2);
    doc.actor_authors.shrinkRetainingCapacity(0);
    try testing.expectEqual(@as(usize, 0), doc.actor_authors.items.len);

    try doc.growActorAuthors(gpa);

    try testing.expectEqual(doc.ops.actors.items.len, doc.actor_authors.items.len);
    for (doc.actor_authors.items, 0..) |maybe, i| {
        // **The slot is reported by index, and its length is not read.**
        // Printing the bytes of an undefined slot is what turned this
        // regression into a general protection fault instead of a failed
        // assertion, and a diagnostic that crashes on the bug it names is
        // worse than none.
        if (maybe == null) continue;
        std.debug.print("slot {d} of the author table is not null\n", .{i});
        return error.SlotNotNull;
    }

    // **And growing again changes nothing.** Upstream's `insert_actor` inserts
    // a `None` at one index and leaves every other entry as it was
    // (`author.rs`:95-97), so a second call must not disturb the first.
    doc.actor_authors.items[0] = "a person";
    try doc.growActorAuthors(gpa);
    try testing.expectEqualSlices(u8, "a person", doc.actor_authors.items[0].?);
}

test "an incremental save writes every framed chunk it owes and frees each one" {
    // **A leak in the incremental-save path is a leak per change for the life of
    // a document.** `saveAfter` frames each change into a buffer it owns, copies
    // it into the output and owes the caller nothing else — an owned return the
    // caller has to remember is one ownership too many, and both call sites
    // forgot it.
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    const after = try doc.saveAfter(gpa, heads);
    defer gpa.free(after);
    // A peer at the current heads gets nothing, and that is the empty case.
    try testing.expectEqual(@as(usize, 0), after.len);
    const all = try doc.saveAfter(gpa, &.{});
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 2), doc.graph.len());
    try testing.expect(all.len > 0);

    // And the stream round-trips into a document that holds the same changes.
    var peer = try Document.load(gpa, std.testing.io, all, defaultTextEncoding());
    defer peer.deinit();
    try testing.expectEqual(@as(usize, doc.graph.len()), peer.graph.len());
}

test "an incremental save owes what the last save did not, and then nothing" {
    // **What the cursor is.** `save_cursor: Vec<ChangeHash>`
    // ([`autocommit.rs:70`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // filled with `self.doc.get_heads()` (`:539`, `:594`) and handed straight
    // to `save_after` (`:592`) — **a set of change hashes**. Not a byte offset
    // into a chunk and not a change index into the graph: `save_after` is
    // `get_changes(have_deps)` ([`automerge.rs:1194-1195`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
    // `:1512-1514`), which collects the changes *not reachable* from those
    // hashes and writes them as bare change chunks.
    //
    // Three properties, and the third is the one a cursor that is set but
    // never read fails.
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.graph.len());

    // (1) An empty cursor owes **everything**: a document that has never been
    // saved has no base, so the collector walks from the heads and yields the
    // whole history. This is the half the missing cursor got wrong — it
    // answered with the *current* heads, which is a base of "nothing owed".
    const first = try doc.saveIncremental(gpa);
    defer gpa.free(first);
    const everything = try doc.saveAfter(gpa, &.{});
    defer gpa.free(everything);
    try testing.expect(first.len > 0);
    try testing.expectEqual(everything.len, first.len);

    // (2) `save()` sets the cursor, so an incremental save right after a full
    // one owes **nothing** (`autocommit.rs:538-540`).
    const whole = try doc.save(gpa);
    defer gpa.free(whole);
    const owed = try doc.saveIncremental(gpa);
    defer gpa.free(owed);
    try testing.expectEqual(@as(usize, 0), owed.len);

    // **And again, with nothing in between.** A cursor that was set once and
    // then never advanced would answer this with the whole history; a cursor
    // that is checked at all answers it with nothing.
    const still = try doc.saveIncremental(gpa);
    defer gpa.free(still);
    try testing.expectEqual(@as(usize, 0), still.len);

    // (3) A change made after the cursor was set **is** owed, and is owed
    // exactly once (`:592-595`). The counter is past everything
    // `buildSample` used, so this op cannot be mistaken for one of its two.
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    _ = try addKeyChange(&doc, gpa, actor_a, 2, 16, "third", heads);
    try testing.expectEqual(@as(usize, 3), doc.graph.len());

    const third = try doc.saveIncremental(gpa);
    defer gpa.free(third);
    try testing.expect(third.len > 0);
    // **One change chunk, not three.** A cursor that did not move resends the
    // history; a cursor that moved twice sends nothing. The count says which,
    // and a byte comparison could not: the same three changes framed twice
    // load into the same document.
    // **Counted by walking, not by materializing.** The seam the load path
    // uses now is the one this count is taken with.
    var counted: usize = 0;
    var stream = chunkmod.ChunkStream.init(third);
    while (try stream.next()) |_| counted += 1;
    try testing.expectEqual(@as(usize, 1), counted);

    // **And it is a loadable change, not merely a framed one.** The peer is
    // built from the *earlier* full save, so it holds exactly what this
    // cursor excluded; an empty peer would have got nothing and said nothing,
    // because a change whose dependencies are missing is queued rather than
    // applied (`Document.queue`).
    var peer = try Document.load(gpa, std.testing.io, whole, defaultTextEncoding());
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 2), peer.graph.len());
    _ = try peer.loadIncremental(gpa, third);
    try testing.expectEqual(@as(usize, 3), peer.graph.len());

    // And the cursor moved with it, so a fourth call is empty again.
    const fourth = try doc.saveIncremental(gpa);
    defer gpa.free(fourth);
    try testing.expectEqual(@as(usize, 0), fourth.len);
}

test "a fork's save cursor starts empty, and a clone leaves the source's where it was" {
    // **`fork` and `fork_at` build `save_cursor: vec![]`**
    // ([`autocommit.rs:364`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    // `:377`) **even though the fork inherits every change the parent holds.**
    // So a fork's first incremental save re-sends the history it was given,
    // and the reference says so. A cursor carried across would contradict
    // that, and nothing downstream could tell: the bytes load into the same
    // document either way, so only the count says which happened.
    const gpa = testing.allocator;
    var doc = try buildSample(gpa);
    defer doc.deinit();

    const whole = try doc.save(gpa);
    defer gpa.free(whole);
    const quiet = try doc.saveIncremental(gpa);
    defer gpa.free(quiet);
    try testing.expectEqual(@as(usize, 0), quiet.len);

    // **A clone must not move the source's cursor.** A clone is upstream's
    // `#[derive(Clone)]` on `Automerge`
    // ([`automerge.rs:248`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and `Automerge` has no save cursor — `AutoCommit` is the type that
    // does. A clone that saved through the cursor-setting wrapper would mark
    // the whole history as delivered to a caller that never saw it, and the
    // source's next incremental save would be empty for the rest of its life.
    var copy = try doc.clone(gpa);
    defer copy.deinit();
    const after_clone = try doc.saveIncremental(gpa);
    defer gpa.free(after_clone);
    try testing.expectEqual(@as(usize, 0), after_clone.len);

    // **The fork, by contrast, owes everything**, because its cursor is empty
    // even though its parent's is not.
    var forked = try doc.fork(gpa);
    defer forked.deinit();
    const inherited = try forked.saveIncremental(gpa);
    defer gpa.free(inherited);
    try testing.expect(inherited.len > 0);
    const all = try forked.saveAfter(gpa, &.{});
    defer gpa.free(all);
    try testing.expectEqual(all.len, inherited.len);
}

// ── Authors ──────────────────────────────────────────────────────────────────

/// One document with three changes by three actors, each carrying an author
/// footer, and the hashes of the two that come before.
///
/// **The footers are written through [`applyHandChange`], not
/// [`Document.setAuthor`]**, because the footer rides an actor's *first*
/// change and only that one ([`Document.commit`],
/// `automerge.rs`:568), and a hand-built change is the only way to give the
/// same name to two different actors.
fn namedAuthors(gpa: Allocator, names: [3][]const u8) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    const actors = [3][]const u8{ actor_a, actor_b, actor_c };
    var hashes: [3]ChangeHash = undefined;
    var deps: [2]ChangeHash = undefined;
    for (actors, names, 0..) |actor, name, i| {
        // **The dependency list is filled in before the change that reads it.**
        // Writing `deps[i - 1]` after the apply handed the second and third
        // changes a window of hashes nothing had ever written: `applyChanges`
        // screens a change whose dependencies the graph lacks, so both were
        // queued instead of linked and the document answered one author for
        // three names. A queued change is linked by nothing, so the defect
        // looked like a lost footer rather than an uninitialised slice.
        if (i > 0) deps[i - 1] = hashes[i - 1];
        // **Sorted, because every change's dependency list is sorted on the
        // wire.** Upstream's `with_dependencies` sorts whatever it is handed
        // ([`change.rs`:343-349](../../github-automerge-automerge/rust/automerge/src/storage/change.rs))
        // and nothing between here and [`applyHandChange`] sorts it: the
        // hashes arrive in the order the actors committed, which is causal
        // order and not hash order. Each appears once — a prefix of distinct
        // hashes — so the list is what upstream would have written.
        std.mem.sort(ChangeHash, deps[0..i], {}, ChangeHash.lessThan);
        const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
        const key = try std.fmt.allocPrint(gpa, "k{d}", .{i});
        defer gpa.free(key);
        const ctr: u32 = @intCast(i + 1);
        const specs = [_]OpSpec{
            .{ .ctr = ctr, .key = KeyRef.fromStr(key), .value = .{ .str = "x" } },
        };
        const ops = try buildOps(gpa, idx, &specs);
        defer freeChangeOps(gpa, ops);
        hashes[i] = try applyHandChange(&doc, gpa, actor, 1, ctr, deps[0..i], name, ops);
    }
    return doc;
}

test "the author set is a set of names, and a name joins it on the change that carries it" {
    const gpa = testing.allocator;
    const trans = @import("transact.zig");

    // **A name set on the document is not yet an author.** Upstream records
    // one only under `if let Some(author) = change.author()`
    // ([`change_graph.rs`:563-566](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    // so a document that has named itself and has committed nothing reports
    // no authors at all.
    var quiet = try Document.init(gpa, std.testing.io);
    defer quiet.deinit();
    try quiet.setAuthor(gpa, "uncommitted");
    {
        const empty = try quiet.getAuthors(gpa);
        defer gpa.free(empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
    }
    {
        var tx = try trans.Transaction.open(gpa, &quiet);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    {
        const named_here = try quiet.getAuthors(gpa);
        defer gpa.free(named_here);
        try testing.expectEqual(@as(usize, 1), named_here.len);
        try testing.expectEqualStrings("uncommitted", named_here[0]);
    }

    // **Two actors that chose the same name are one author, and the names are
    // in byte order rather than in the order the changes arrived.** This is
    // upstream's `binary_search` plus `insert` over a `Vec<Author>`
    // ([`author.rs`:117-132](../../github-automerge-automerge/rust/automerge/src/author.rs)),
    // which is why `"zeta"` precedes `"alpha"` here even though `alpha` was
    // written first — and why the shared name appears once and not twice.
    var three = try namedAuthors(gpa, .{ "zeta", "alpha", "alpha" });
    defer three.deinit();
    const names = try three.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha", names[0]);
    try testing.expectEqualStrings("zeta", names[1]);

    // **And the set survives a save and load**, because the footers do.
    const saved = try three.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, .unicode_code_point);
    defer reloaded.deinit();
    const again = try reloaded.getAuthors(gpa);
    defer gpa.free(again);
    try testing.expectEqual(@as(usize, 2), again.len);
    try testing.expectEqualStrings("alpha", again[0]);
    try testing.expectEqualStrings("zeta", again[1]);
}

test "an actor removed from the table does not withdraw a name from the set" {
    const gpa = testing.allocator;
    // Upstream's `remove_actor` drops the actor-to-author *mapping* and says
    // so: "this may leave a dangling `Author` in the set of authors"
    // ([`author.rs`:93-97](../../github-automerge-automerge/rust/automerge/src/author.rs)).
    // A set derived from the mapping would lose a name the moment the actor
    // behind it went, and the answer for "who has written in this document"
    // would change with a rollback.
    var one = try namedAuthors(gpa, .{ "gone-soon", "other", "other" });
    defer one.deinit();
    const before = try one.getAuthors(gpa);
    defer gpa.free(before);
    try testing.expectEqual(@as(usize, 2), before.len);
    try testing.expectEqualStrings("gone-soon", before[0]);
    try testing.expectEqualStrings("other", before[1]);
    // **Both halves of the state the removal is about to disturb**: the set by
    // name, and each of the three actors by the name it carries. The two
    // actors that chose one name are the reason a set derived from the
    // mapping would already have lost one of them.
    try testing.expectEqualStrings("gone-soon", one.getAuthorForActor(.{ .bytes = actor_a }).?);
    try testing.expectEqualStrings("other", one.getAuthorForActor(.{ .bytes = actor_b }).?);
    try testing.expectEqualStrings("other", one.getAuthorForActor(.{ .bytes = actor_c }).?);

    // **An actor the change graph holds no change for**, which is the only
    // actor the removal will take. Upstream `assert!`s a slot that still has
    // one ([`change_graph.rs`:175-177](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
    // because its changes would be retargeted, and a rollback of a first
    // change is the caller that empties it first; here the port answers
    // `error.InvalidIndex` where upstream panics. **The actor sorts before all
    // three**, so the removal renumbers every named actor's slot — which is
    // what makes the set's survival and the mapping's renumbering one
    // observation rather than two.
    const idle = "0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e";
    const slot = try one.putActorRef(gpa, .{ .bytes = idle });
    try testing.expectEqual(@as(ActorIdx, 0), slot);
    try testing.expectEqual(@as(usize, 4), one.numActors());
    try one.removeActor(gpa, slot);

    try testing.expectEqual(@as(usize, 3), one.numActors());
    // **The set is what it was, name for name and in the same order.** Not a
    // count: a set that lost a name and one that grew one would both be the
    // wrong count, and only the names say which.
    const after = try one.getAuthors(gpa);
    defer gpa.free(after);
    try testing.expectEqual(@as(usize, 2), after.len);
    try testing.expectEqualStrings("gone-soon", after[0]);
    try testing.expectEqualStrings("other", after[1]);
    // **And the names are still with their actors rather than with their old
    // slots.** The removal shifted every entry at or above 0 down by one, so a
    // table keyed by slot would answer the next actor's name for each.
    try testing.expectEqualSlices(u8, actor_a, one.ops.actors.items[0].bytes);
    try testing.expectEqualSlices(u8, actor_b, one.ops.actors.items[1].bytes);
    try testing.expectEqualSlices(u8, actor_c, one.ops.actors.items[2].bytes);
    try testing.expectEqualStrings("gone-soon", one.getAuthorForActor(.{ .bytes = actor_a }).?);
    try testing.expectEqualStrings("other", one.getAuthorForActor(.{ .bytes = actor_b }).?);
    try testing.expectEqualStrings("other", one.getAuthorForActor(.{ .bytes = actor_c }).?);
    // **The two tables still agree**, which is the whole of the claim: every
    // name has an actor behind it and every actor's name is in the set.
    try expectAuthorTablesAgree(gpa, &one);
}

/// Writes one key on the root map and commits, for the author tests below.
///
/// **A transaction rather than a hand-built commit**, because
/// [`Document.commit`] is given rows the caller has already spliced into the
/// op set, and the point of these tests is what the document *says* about an
/// author rather than how a change is encoded.
fn commitRootPut(gpa: Allocator, doc: *Document, key: []const u8) !ChangeHash {
    const trans = @import("transact.zig");
    var tx = try trans.Transaction.open(gpa, doc);
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = key }, .{ .int = 1 });
    var committed = try tx.commit();
    defer committed.deinit(gpa);
    return committed.hash.?;
}

/// The two author tables agree, read through the public surface.
///
/// **Both directions, because a refusal can strand either one.**
/// [`Document.getAuthorForActor`] answering a name
/// [`Document.getAuthors`] does not list is the first half, and it is what the
/// slot-before-name order produced: the change carrying the footer was
/// already linked at `seq == 1`, so no later change from that actor ever
/// stamps one and the document could not heal itself. A name in the set that
/// no actor carries is the second half — a name is written only beside its
/// actor's slot, so a set that grew alone would be a name recorded for a
/// change this document never linked.
///
/// **The second half is not a general invariant** and is only asserted where
/// no removal happens: [`Document.removeActor`] deliberately leaves a name
/// behind ([`author.rs`:93-97](../../github-automerge-automerge/rust/automerge/src/author.rs)).
/// A set derived from the mapping could not fail the first half, and a
/// mapping written before the set could not pass it, which is why the shape
/// is read back and compared rather than counted.
fn expectAuthorTablesAgree(gpa: Allocator, doc: *const Document) !void {
    const actors = try doc.getActors(gpa);
    defer gpa.free(actors);
    const names = try doc.getAuthors(gpa);
    defer gpa.free(names);
    for (actors) |a| {
        const name = doc.getAuthorForActor(a) orelse continue;
        for (names) |recorded| {
            if (std.mem.eql(u8, recorded, name)) break;
        } else return error.NameMissingFromSet;
    }
    for (names) |name| {
        const carriers = try doc.getActorForAuthor(gpa, name);
        gpa.free(carriers);
        if (carriers.len == 0) return error.NameWithNoActor;
    }
}

test "a clone's author and actor are its own after the source is dropped" {
    const gpa = testing.allocator;
    var src = try Document.init(gpa, std.testing.io);
    try src.setAuthor(gpa, "ada");
    // **The actor is one this document has not interned**, so it is the
    // `.unused` arm: bytes the document borrowed rather than a slot in a
    // table, and the arm a clone has to copy like the author.
    try testing.expectEqual(@as(?ActorIdx, null), src.getActorIndex());

    var copy = try src.clone(gpa);
    defer copy.deinit();
    var forked = try src.fork(gpa);
    defer forked.deinit();
    // **`ActorId.bytes` is a slice over the source's arena**, so the bytes are
    // taken before it goes.
    const src_actor = try gpa.dupe(u8, src.getActorId().bytes);
    defer gpa.free(src_actor);

    // **The source goes, and with it the arena the clone was reading.**
    src.deinit();

    try testing.expectEqualStrings("ada", copy.getAuthor().?);
    try testing.expectEqualStrings(src_actor, copy.getActorId().bytes);
    // **The fork has its own actor and the same author**, which is the whole
    // difference between the two.
    try testing.expectEqualStrings("ada", forked.getAuthor().?);
    try testing.expect(!std.mem.eql(u8, src_actor, forked.getActorId().bytes));

    // **And the bytes that reach the wire are the ones the source carried.**
    // `testing.allocator` fills a freed block with `0xaa`, so a borrowed name
    // or actor would answer that rather than "ada".
    _ = try commitRootPut(gpa, &copy, "k");
    try testing.expectEqualStrings("ada", copy.getAuthorForActor(copy.getActorId()).?);
    const names = try copy.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("ada", names[0]);
    // **And a reload still knows**, which is the footer on the change rather
    // than the fields of the document that wrote it.
    const saved = try copy.save(gpa);
    defer gpa.free(saved);
    var peer = try Document.load(gpa, std.testing.io, saved, copy.textEncoding());
    defer peer.deinit();
    const peer_names = try peer.getAuthors(gpa);
    defer gpa.free(peer_names);
    try testing.expectEqual(@as(usize, 1), peer_names.len);
    try testing.expectEqualStrings("ada", peer_names[0]);
}

test "a document's second name joins the set on the change that carries it" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    try doc.setAuthor(gpa, "alpha");
    const first_actor = doc.getActorId().bytes;
    _ = try commitRootPut(gpa, &doc, "a");
    {
        const names = try doc.getAuthors(gpa);
        defer gpa.free(names);
        try testing.expectEqual(@as(usize, 1), names.len);
        try testing.expectEqualStrings("alpha", names[0]);
    }

    // **A change of author mints a new actor, and the name rides that actor's
    // first change and no other** ([`automerge.rs`:568](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try doc.setAuthor(gpa, "beta");
    try testing.expect(!std.mem.eql(u8, first_actor, doc.getActorId().bytes));
    _ = try commitRootPut(gpa, &doc, "b");
    {
        const names = try doc.getAuthors(gpa);
        defer gpa.free(names);
        try testing.expectEqual(@as(usize, 2), names.len);
        try testing.expectEqualStrings("alpha", names[0]);
        try testing.expectEqualStrings("beta", names[1]);
    }
    // **Both actors keep their own name**, which is the parity the two tables
    // owe: the new actor's footer filled the new slot and did not disturb the
    // old one.
    try testing.expectEqualStrings("alpha", doc.getAuthorForActor(.{ .bytes = first_actor }).?);
    try testing.expectEqualStrings("beta", doc.getAuthorForActor(doc.getActorId()).?);

    // **A third change under the second name grows nothing.** The footer rides
    // `seq == 1` only, and a name already in the set is not inserted twice
    // ([`author.rs`:117-132](../../github-automerge-automerge/rust/automerge/src/author.rs)).
    _ = try commitRootPut(gpa, &doc, "c");
    const names = try doc.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("alpha", names[0]);
    try testing.expectEqualStrings("beta", names[1]);
}

test "a queued change's footer is recorded only when the change is applied" {
    const gpa = testing.allocator;
    // Two explicitly committed raw transactions establish the dependency pair.
    var src = try Document.init(gpa, std.testing.io);
    defer src.deinit();
    try src.setAuthor(gpa, "the-author");
    const first = try commitRootPut(gpa, &src, "a");
    const second = try commitRootPut(gpa, &src, "b");
    const author_actor = src.getActorId().bytes;

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    // **The later change first.** It depends on the earlier one, so the screen
    // queues it — and a queued change is in no graph, so nothing has stamped
    // its footer. Recording it here would put a name in the set for a change
    // this document has not applied.
    var later = (try src.getChangeByHash(gpa, second)).?;
    defer later.deinit(gpa);
    _ = try peer.applyChanges(gpa, &.{later.change});
    try testing.expectEqual(@as(usize, 0), peer.graph.len());
    try testing.expectEqual(@as(usize, 1), peer.queue.len());
    try testing.expectEqual(@as(?[]const u8, null), peer.getAuthorForActor(.{ .bytes = author_actor }));
    {
        const names = try peer.getAuthors(gpa);
        defer gpa.free(names);
        try testing.expectEqual(@as(usize, 0), names.len);
    }

    // **And the dependency drains it**, which is the point at which the footer
    // reaches a graph and the name joins the set.
    var earlier = (try src.getChangeByHash(gpa, first)).?;
    defer earlier.deinit(gpa);
    _ = try peer.applyChanges(gpa, &.{earlier.change});
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try testing.expectEqual(@as(usize, 2), peer.graph.len());
    try testing.expectEqualStrings("the-author", peer.getAuthorForActor(.{ .bytes = author_actor }).?);
    const names = try peer.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("the-author", names[0]);
}

test "a merge brings the other side's names in, and a shared name is one author" {
    const gpa = testing.allocator;
    var base = try Document.init(gpa, std.testing.io);
    defer base.deinit();
    try base.setAuthor(gpa, "local");
    const base_change = try commitRootPut(gpa, &base, "a");
    const local_actor = base.getActorId().bytes;

    var other = try base.fork(gpa);
    defer other.deinit();
    try other.setAuthor(gpa, "remote");
    const other_change = try commitRootPut(gpa, &other, "b");
    const remote_actor = other.getActorId().bytes;

    // **A third copy that ends up with the name `base` already has.**
    // `put_author` answers `Ok(index)` for a name that is already there and
    // inserts nothing ([`author.rs`:117-132](../../github-automerge-automerge/rust/automerge/src/author.rs)),
    // so two actors with one name are one entry however many times the footer
    // arrives. **It takes two calls rather than one**, because a fork inherits
    // its parent's author and `setAuthor` with the name it already has is the
    // no-op that keeps the actor — so the actor has to change once and the
    // name has to end up back where it started.
    var same = try base.fork(gpa);
    defer same.deinit();
    try same.setAuthor(gpa, "somewhere-else");
    try same.setAuthor(gpa, "local");
    const same_change = try commitRootPut(gpa, &same, "c");
    const shared_actor = same.getActorId().bytes;
    try testing.expect(!std.mem.eql(u8, local_actor, shared_actor));

    // **Both head lists are the caller's, and both are read.**
    // [`Document.merge`] ends in [`Document.getHeads`], which allocates, and a
    // merge that drops them on the floor leaks one array per call under
    // `testing.allocator`. Membership and not position: the heads come back
    // in hash order ([`ChangeGraph.updateHeads`]), which is a property of the
    // graph rather than of which side merged whom.
    //
    // **Each fork committed on top of the one change `base` already had**, so
    // the two branches are concurrent with each other and neither is
    // concurrent with `base_change` — which is why the first merge leaves one
    // head and the second leaves two, and why `base_change` is on neither list
    // by the time it is read.
    const heads_after_other = try base.merge(gpa, &other);
    defer gpa.free(heads_after_other);
    try testing.expectEqual(@as(usize, 1), heads_after_other.len);
    try testing.expect(containsHash(heads_after_other, other_change));
    try testing.expect(!containsHash(heads_after_other, base_change));
    const heads_after_same = try base.merge(gpa, &same);
    defer gpa.free(heads_after_same);
    try testing.expectEqual(@as(usize, 2), heads_after_same.len);
    try testing.expect(containsHash(heads_after_same, other_change));
    try testing.expect(containsHash(heads_after_same, same_change));
    try testing.expect(!containsHash(heads_after_same, base_change));
    const names = try base.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("local", names[0]);
    try testing.expectEqualStrings("remote", names[1]);

    // **Each actor still answers its own**, which is the half a set of names
    // alone cannot say: `shared_actor` and `local_actor` share a name and are
    // different actors.
    try testing.expectEqualStrings("local", base.getAuthorForActor(.{ .bytes = local_actor }).?);
    try testing.expectEqualStrings("local", base.getAuthorForActor(.{ .bytes = shared_actor }).?);
    try testing.expectEqualStrings("remote", base.getAuthorForActor(.{ .bytes = remote_actor }).?);
    try expectAuthorTablesAgree(gpa, &base);
}

test "an empty author name is a name, and clearing the author keeps the names" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    // **An empty name is not no name.** `encodeAuthorFooter` returns early only
    // on a null author, so an empty one still writes the tag and a zero length,
    // and `decodeAuthorFooter` hands the zero-length slice back.
    try doc.setAuthor(gpa, "");
    try testing.expect(doc.getAuthor() != null);
    const blank_actor = doc.getActorId().bytes;
    const stamped = try commitRootPut(gpa, &doc, "a");
    try testing.expectEqualStrings("", doc.getAuthorForActor(.{ .bytes = blank_actor }).?);
    {
        const names = try doc.getAuthors(gpa);
        defer gpa.free(names);
        try testing.expectEqual(@as(usize, 1), names.len);
        try testing.expectEqualStrings("", names[0]);
    }
    {
        var built = (try doc.getChangeByHash(gpa, stamped)).?;
        defer built.deinit(gpa);
        const footer_name = (decodeAuthorFooter(changeFooter(built.change)) catch null).?;
        try testing.expectEqualStrings("", footer_name);
    }

    // **Clearing the author mints a new actor and stamps nothing.** The set is
    // historical and never loses a name ([`author.rs`:93-97](../../github-automerge-automerge/rust/automerge/src/author.rs)),
    // so the empty name is still there — but the new actor's first change
    // carries no footer at all.
    try doc.setAuthor(gpa, null);
    try testing.expectEqual(@as(?[]const u8, null), doc.getAuthor());
    const bare = try commitRootPut(gpa, &doc, "b");
    {
        var built = (try doc.getChangeByHash(gpa, bare)).?;
        defer built.deinit(gpa);
        const footer = changeFooter(built.change) orelse &.{};
        try testing.expectEqual(@as(usize, 0), footer.len);
    }
    {
        const names = try doc.getAuthors(gpa);
        defer gpa.free(names);
        try testing.expectEqual(@as(usize, 1), names.len);
        try testing.expectEqualStrings("", names[0]);
    }
    // **And the actor with no footer has no author**, which is the `None`
    // branch of the association doing nothing rather than writing null over a
    // slot something else had filled.
    try testing.expectEqual(@as(?[]const u8, null), doc.getAuthorForActor(doc.getActorId()));
    try expectAuthorTablesAgree(gpa, &doc);
}

test "a fork at a head before a name was stamped excludes that name" {
    const gpa = testing.allocator;
    // Two explicitly committed raw transactions establish the dependency pair.
    var src = try Document.init(gpa, std.testing.io);
    defer src.deinit();
    try src.setAuthor(gpa, "first-name");
    // **The actor the first change was written by**, taken before the second
    // `setAuthor` mints a new one. It is the fork's only actor, because the
    // fork reaches one change and that change names one.
    const first_actor = src.getActorId().bytes;
    const early = try commitRootPut(gpa, &src, "a");
    try src.setAuthor(gpa, "second-name");
    _ = try commitRootPut(gpa, &src, "b");

    const heads = [_]ChangeHash{early};
    var forked = try src.forkAt(gpa, &heads);
    defer forked.deinit();
    // **A fork applies the changes it reaches and nothing else**, and it sets no
    // author of its own ([`automerge.rs`:711-735](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so the set is exactly the names the one change it holds carried.
    try testing.expectEqual(@as(usize, 1), forked.graph.len());
    try testing.expectEqual(@as(?[]const u8, null), forked.getAuthor());
    const names = try forked.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("first-name", names[0]);
    // **The name is with the actor that wrote the change carrying it**, which
    // is the source's actor at the time and not anything the fork chose.
    try testing.expectEqualStrings("first-name", forked.getAuthorForActor(.{ .bytes = first_actor }).?);
    // **The fork's own actor is a fresh one that has written nothing**, and an
    // actor no footer was ever stamped for names nothing — upstream mints it
    // in `fork_at` (`automerge.rs:731`), so the document it produces has an
    // actor of its own and no author for it. Reading the set through that
    // actor instead of through the one the change names would be a question
    // about the wrong document.
    try testing.expect(!std.mem.eql(u8, first_actor, forked.getActorId().bytes));
    try testing.expectEqual(@as(?[]const u8, null), forked.getAuthorForActor(forked.getActorId()));
    try expectAuthorTablesAgree(gpa, &forked);
}

test "an actor inserted below a named one keeps every name with its actor" {
    const gpa = testing.allocator;
    var three = try namedAuthors(gpa, .{ "alpha", "beta", "gamma" });
    defer three.deinit();
    try testing.expectEqualStrings("alpha", three.getAuthorForActor(.{ .bytes = actor_a }).?);
    try testing.expectEqualStrings("beta", three.getAuthorForActor(.{ .bytes = actor_b }).?);

    // **A fourth actor that sorts before all three**, so the insertion lands at
    // index 0 and renumbers every slot above it
    // ([`Document.insertActor`](src/doc.zig) over `insert_actor`,
    // `automerge.rs`:1301-1306).
    const early = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f";
    const slot = try three.putActorRef(gpa, .{ .bytes = early });
    try testing.expectEqual(@as(ActorIdx, 0), slot);
    try testing.expectEqual(@as(usize, 4), three.numActors());
    try testing.expectEqualSlices(u8, early, three.ops.actors.items[0].bytes);

    // **The names moved with their actors and not with their indices.** The
    // insertion shifted every entry at or above 0 down by one, so a table that
    // kept names by slot would answer the new actor's slot for `actor_a`.
    try testing.expectEqual(@as(?[]const u8, null), three.getAuthorForActor(.{ .bytes = early }));
    try testing.expectEqualStrings("alpha", three.getAuthorForActor(.{ .bytes = actor_a }).?);
    try testing.expectEqualStrings("beta", three.getAuthorForActor(.{ .bytes = actor_b }).?);
    try testing.expectEqualStrings("gamma", three.getAuthorForActor(.{ .bytes = actor_c }).?);
    // **And the set is untouched by a renumbering**, because it is keyed by
    // bytes and not by a slot.
    try expectAuthorTablesAgree(gpa, &three);
    const names = try three.getAuthors(gpa);
    defer gpa.free(names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("alpha", names[0]);
    try testing.expectEqualStrings("beta", names[1]);
    try testing.expectEqualStrings("gamma", names[2]);
}

/// One `set` on the root map at `ctr`, by `actor`, carrying `name` in its
/// footer, applied the way a peer's change arrives.
///
/// **`seq` is 1 and `deps` carries the previous change**, which is what a
/// first change from an actor looks like and the only case the footer rides
/// ([`automerge.rs`:568](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
fn applyNamedRootPut(
    gpa: Allocator,
    doc: *Document,
    actor: []const u8,
    ctr: u32,
    name: []const u8,
    deps: []const ChangeHash,
) !ChangeHash {
    const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
    const specs = [_]OpSpec{
        .{ .ctr = ctr, .key = KeyRef.fromStr("k"), .value = .{ .str = "x" } },
    };
    const ops = try buildOps(gpa, idx, &specs);
    defer freeChangeOps(gpa, ops);
    return applyHandChange(doc, gpa, actor, 1, ctr, deps, name, ops);
}

/// Applies two changes by two actors, each carrying a name, and reads the
/// document's answer back through the public surface, for the sweep below.
///
/// **Every exit is read, refusal or not, because the defect is what a refusal
/// leaves behind.** The actor's slot was written before the name's insertion,
/// so an induced failure in the insertion left [`Document.getAuthorForActor`]
/// answering a name [`Document.getAuthors`] did not list — and nothing healed
/// it, because the change carrying the footer was already linked at
/// `seq == 1` and no later change from that actor ever stamps one.
///
/// **Two names by two actors, so the sweep covers the new name rather than
/// only the already-there answer**: the second insertion lands in a set that
/// already holds `"first"`, which is the case that has to allocate.
///
/// **The document is allowed to be half-loaded on a refusal** —
/// [`Document.applyChanges`] interns the actors and runs the batch before it
/// links a change's history, and the op-set walk that follows the history
/// allocates as well — so what is asserted after one is that the two author
/// tables still agree with each other, that neither names something the
/// document does not hold, and that the second actor's name and the second
/// entry in the set stand or fall together. The refusal's exact landing point
/// is not asserted, because it is not a property of the caller.
///
/// **Nothing that reads the document is allocated with `gpa`.** The sweep
/// hands this function an allocator that fails every allocation past an
/// index, so a getter asked for memory with it answers `error.OutOfMemory` —
/// and `checkAllAllocationFailures` records that as a clean run. That is how
/// an induced failure *inside an assertion* lets the assertion it was supposed
/// to fail pass without running: the refusal arms below would return at their
/// first `expectAuthorTablesAgree`, and the sweep would see an orderly
/// `error.OutOfMemory` every single time. Building the document and applying
/// the changes is the code under test and keeps `gpa`; every allocation that
/// observes what came back is made with `testing.allocator`, which cannot
/// fail, so each arm reaches its checks on every index the sweep tries.
fn applyTwoNamedThenCheck(gpa: Allocator) !void {
    const observer = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    const first = applyNamedRootPut(gpa, &doc, actor_a, 1, "first", &.{}) catch |e| switch (e) {
        error.OutOfMemory => {
            try expectAuthorTablesAgree(observer, &doc);
            return error.OutOfMemory;
        },
        else => return e,
    };
    const heads_of_first = [_]ChangeHash{first};
    const second = applyNamedRootPut(gpa, &doc, actor_b, 2, "second", &heads_of_first) catch |e| switch (e) {
        error.OutOfMemory => {
            // **The first name is already in the set and its actor already
            // carries it**, because that change went through in full.
            try expectAuthorTablesAgree(observer, &doc);
            try testing.expectEqualStrings("first", doc.getAuthorForActor(.{ .bytes = actor_a }).?);
            // History, rows and both author tables publish together. Refusal
            // cannot expose a new association without its complete change.
            if (doc.getAuthorForActor(.{ .bytes = actor_b })) |name| {
                try testing.expectEqualStrings("second", name);
                const both = try doc.getAuthors(observer);
                defer observer.free(both);
                try testing.expectEqual(@as(usize, 2), both.len);
                try testing.expectEqualStrings("first", both[0]);
                try testing.expectEqualStrings("second", both[1]);
            } else {
                const only = try doc.getAuthors(observer);
                defer observer.free(only);
                try testing.expectEqual(@as(usize, 1), only.len);
                try testing.expectEqualStrings("first", only[0]);
            }
            return error.OutOfMemory;
        },
        else => return e,
    };
    try expectAuthorTablesAgree(observer, &doc);

    // **The success round, and the only one that can say what the document is
    // supposed to hold.** Both changes are linked — the second depends on the
    // first, so the document has exactly one head — and the set is the two
    // names in byte order with an actor behind each. `observer` throughout,
    // because this is the round the sweep would otherwise never get to read:
    // a failure inside one of these getters would read as "the run stopped
    // early" rather than as the document answering wrongly.
    const heads = try doc.getHeads(observer);
    defer observer.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, second.bytes[0..], heads[0].bytes[0..]);
    const names = try doc.getAuthors(observer);
    defer observer.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("first", names[0]);
    try testing.expectEqualStrings("second", names[1]);
    try testing.expectEqualStrings("first", doc.getAuthorForActor(.{ .bytes = actor_a }).?);
    try testing.expectEqualStrings("second", doc.getAuthorForActor(.{ .bytes = actor_b }).?);
    const a_actor = try doc.getActorForAuthor(observer, "first");
    defer observer.free(a_actor);
    try testing.expectEqual(@as(usize, 1), a_actor.len);
    try testing.expectEqualStrings(actor_a, a_actor[0].bytes);
    const b_actor = try doc.getActorForAuthor(observer, "second");
    defer observer.free(b_actor);
    try testing.expectEqual(@as(usize, 1), b_actor.len);
    try testing.expectEqualStrings(actor_b, b_actor[0].bytes);
}

test "an applied change's author survives every allocation failure on the apply route" {
    const gpa = testing.allocator;
    try testing.checkAllAllocationFailures(gpa, applyTwoNamedThenCheck, .{});
}

test "a refused setAuthor leaves the document's author and actor exactly as they were" {
    const gpa = testing.allocator;
    const held = "a-name-already-set";

    // **How many allocations two calls make.** The second is the one under
    // test — the first puts the document in the state where a refusal has
    // something to be wrong about — and both go through the failing allocator,
    // so the count covers every step of both.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        var doc = try Document.init(failing.allocator(), std.testing.io);
        defer doc.deinit();
        try doc.setAuthor(failing.allocator(), held);
        try doc.setAuthor(failing.allocator(), "another-name");
        break :blk failing.alloc_index;
    };
    try testing.expect(needed > 0);

    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        // **The setup is allowed to run out, and the sweep says so rather than
        // failing.** `fail_index` counts from the first allocation of the run,
        // and the run's first allocations are `Document.init` and the name the
        // document starts from — so the early indices land in the setup, where
        // there is no document to observe and no mutation to refuse. A `try`
        // there turned a sweep that had not reached its subject into a failure
        // of the test itself. **What those indices still assert is that the
        // refusal gave everything back**, which is the same invariant the rest
        // of the run asserts and is checked once, after the block, where the
        // document has been released too.
        one: {
            const inner = failing.allocator();
            var doc = Document.init(inner, std.testing.io) catch break :one;
            defer doc.deinit();
            doc.setAuthor(inner, held) catch |e| switch (e) {
                error.OutOfMemory => break :one,
                else => return e,
            };

            // **The observer is the outer allocator.** Every byte the
            // comparison below reads is copied with it, so the sweep counts the
            // document and the mutation and nothing else, and an observer that
            // ran short could never be read as a mutation that was refused.
            const actor_before = try gpa.dupe(u8, doc.getActorId().bytes);
            defer gpa.free(actor_before);
            var refused = false;
            doc.setAuthor(inner, "a-different-name") catch |e| {
                try testing.expectEqual(error.OutOfMemory, e);
                refused = true;
            };
            if (refused) {
                // **Nothing moved.** Writing the author before the draw is what
                // made this stick: the actor was still the old one, whose
                // `seq` is above 1, so every later commit answered
                // `.author = null`, no footer was ever written again, and
                // `getAuthor` named a person no change in the document carried.
                //
                // **The pair is read after the refusal, not inferred from
                // it**: `getAuthor` answering null is not "the author did not
                // move", it is the document having lost the name it had, and
                // the unwrap would have taken the whole test binary down
                // rather than failing this assertion.
                try testing.expectEqualStrings(
                    held,
                    doc.getAuthor() orelse return error.TestUnexpectedResult,
                );
                try testing.expectEqualStrings(actor_before, doc.getActorId().bytes);
            } else {
                try testing.expectEqualStrings("a-different-name", doc.getAuthor().?);
                try testing.expect(!std.mem.eql(u8, actor_before, doc.getActorId().bytes));
            }
        }
        // **Every path out releases the arena**, which is where the bytes a
        // swallowed allocation had already handed over would be sitting.
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

// ── Bundles and fragments ────────────────────────────────────────────────────

/// The document's first two changes, in graph order.
///
/// **Graph order is a topological order**, because [`ChangeGraph`] only
/// accepts a change once its dependencies are in it
/// ([`addChange`](change_graph.zig), `change_graph.rs:718-727`), so index 0
/// is the change index 1 depends on. A bundle test needs the two *in that
/// order* — a subset that names a change it does not carry is only a subset
/// when the carried one is the later one.
fn firstTwoChanges(doc: *const Document) [2]ChangeHash {
    return .{
        doc.graph.indexToHash(0) orelse ChangeHash.zero,
        doc.graph.indexToHash(1) orelse ChangeHash.zero,
    };
}

test "a bundle of a whole document loads into an empty document and rebuilds it" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const heads = try source.getHeads(gpa);
    defer gpa.free(heads);
    // **Both changes, not the head list.** The heads of this fixture are the
    // second change alone, and a bundle of one change *names* every dependency
    // it does not hold ([`ChangeWriter.add`](storage/bundle.zig) writes those
    // hashes into the chunk prefix), so a receiver would queue that change
    // rather than apply it and this round trip would be a subset of the
    // document. A bundle of the whole document is the pair, in graph order.
    const both = firstTwoChanges(&source);
    var written = try source.bundle(gpa, both[0..]);
    defer written.deinit(gpa);
    try testing.expect(written.checksumValid());
    // **A bundle of everything names no dependency.** Every change it carries
    // is inside it, so the chunk prefix is empty — which is what makes the
    // round trip below a whole document rather than a subset.
    try testing.expectEqual(@as(usize, 0), written.depsList().len);

    // **Into an empty document**, so nothing about the answer comes from the
    // receiver already holding part of it.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    const added = try peer.loadIncremental(gpa, written.bytes());
    try testing.expectEqual(source.ops.len(), added);
    try source.debugCmp(&peer);
    const peer_heads = try peer.getHeads(gpa);
    defer gpa.free(peer_heads);
    try testing.expectEqualSlices(ChangeHash, heads, peer_heads);
    try testing.expectEqual(@as(usize, 0), peer.queue.len());

    // **And again through the whole-load door**, which is a different entry
    // point and a different policy: `load` refuses a queued change and a
    // bundle-first stream carries none, so it takes the same path.
    var whole = try Document.load(gpa, std.testing.io, written.bytes(), .unicode_code_point);
    defer whole.deinit();
    try source.debugCmp(&whole);

    // **A second load of the same bytes adds nothing.** Every change is
    // already in the graph, so the batch is empty — which is what makes a
    // bundle re-sent over a link idempotent.
    try testing.expectEqual(@as(usize, 0), try peer.loadIncremental(gpa, written.bytes()));
}

test "a bundle of a subset names the changes it does not carry, and queues them until they arrive" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **The second change alone.** Its dependency is the first, so the
    // bundle carries one change and names one hash it does not have — which is
    // [`ChangeWriter.add`](storage/bundle.zig)'s external list, upstream's
    // `cap + index into external` (`bundle/builder.rs`:288-299).
    const second = firstTwoChanges(&source)[1];
    var written = try source.bundle(gpa, &.{second});
    defer written.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), written.depsList().len);

    // **Nothing is applied and everything is queued.** That is the whole
    // contract of a partial bundle: the receiver holds the change it was sent
    // and nothing else, and the change it is missing is not an error.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    _ = try peer.loadIncremental(gpa, written.bytes());
    try testing.expectEqual(@as(usize, 0), peer.ops.len());
    try testing.expectEqual(@as(usize, 1), peer.queue.len());

    // **The missing change releases it.** Applying the change the bundle named
    // drains the queue through the same [`Document.applyChanges`] path, and
    // the document is then the whole of `source`.
    var missing = (try source.getChangeByHash(gpa, firstTwoChanges(&source)[0])) orelse
        return error.MissingChange;
    defer missing.deinit(gpa);
    _ = try peer.applyChanges(gpa, &.{missing.change});
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try source.debugCmp(&peer);
}

test "a bundle of no hashes carries nothing, and a hash the document does not hold is refused" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **An empty list is a bundle and not a refusal.** It parses, it names no
    // dependency, and loading it adds no rows — upstream's `from_meta` with
    // `min = 0` and `max = 1` walks no op either
    // ([`bundle.rs`:53-56](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs)).
    var empty = try source.bundle(gpa, &.{});
    defer empty.deinit(gpa);
    try testing.expect(empty.checksumValid());
    try testing.expectEqual(@as(usize, 0), empty.depsList().len);
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 0), try peer.loadIncremental(gpa, empty.bytes()));

    // **An unknown hash is `error.MissingDeps`**, which is upstream's
    // `MissingDep` out of `get_bundle_metadata`
    // ([`change_graph.rs`:338-382](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
    // A hash the document has never seen is not a bundle of nothing: it is a
    // request for a change this document cannot produce.
    var stranger = ChangeHash.zero;
    stranger.bytes[0] = 0xab;
    try testing.expectError(error.MissingDeps, source.bundle(gpa, &.{stranger}));
}

test "a bundle and a change chunk in one stream both land" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    var written = try source.bundle(gpa, &.{firstTwoChanges(&source)[1]});
    defer written.deinit(gpa);
    const on_disk = try gpa.dupe(u8, written.bytes());
    defer gpa.free(on_disk);
    var first = (try source.getChangeByHash(gpa, firstTwoChanges(&source)[0])) orelse
        return error.MissingChange;
    defer first.deinit(gpa);
    var second = (try source.getChangeByHash(gpa, firstTwoChanges(&source)[1])) orelse
        return error.MissingChange;
    defer second.deinit(gpa);

    // **Two chunks in the order the receiver would see them off the wire**: a
    // bundle that is missing the earlier change, then that change. Upstream's
    // `load_changes` is one loop over `load_next_change`, which has a bundle
    // arm and a change arm ([`load.rs`:104-157](../../github-automerge-automerge/rust/automerge/src/storage/load.rs)),
    // so a stream may interleave them and this is the case that exercises
    // both arms in one call.
    // **A change chunk on the wire is framed, and this port's `Change.bytes`
    // is the body** ([`change.zig:93-95`](change.zig), and
    // [`Change.encode`] for the frame). Concatenating the body would give the
    // loader a stream whose second chunk has no magic, so the frame is built
    // rather than spliced in.
    const framed = try second.change.encode(gpa);
    defer gpa.free(framed);
    const stream = try gpa.alloc(u8, on_disk.len + framed.len);
    defer gpa.free(stream);
    @memcpy(stream[0..on_disk.len], on_disk);
    @memcpy(stream[on_disk.len..], framed);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    _ = try peer.loadIncremental(gpa, stream);
    // **The change chunk is the one the bundle already named**, so it is
    // recognised rather than applied twice, and the bundle's change stays
    // queued. This is the order a peer that re-sends what it just sent
    // produces.
    _ = try peer.applyChanges(gpa, &.{first.change});
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try source.debugCmp(&peer);
}

/// The concatenation of `parts`, which is what a receiver is handed when a
/// sender ships several chunks in one call.
///
/// **The parts are whole framed chunks and are copied in that framing.** A
/// bundle is a chunk, so a stream of two bundles is two of them back to back;
/// nothing here re-frames, re-encodes or lengthens a header.
fn concatChunks(gpa: Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    var at: usize = 0;
    for (parts) |part| {
        @memcpy(out[at..][0..part.len], part);
        at += part.len;
    }
    return out;
}

/// How many properties a recursive walk of `doc` yields, and whether it
/// reached `key` on the way.
///
/// **The keys are compared inside the walk rather than collected**, because
/// they borrow the document's string table
/// ([`DocObjItem`](iter/doc.zig)) — a list of them would be a list of slices
/// neither the walk nor this function owns.
fn walkReaching(
    doc: *const Document,
    gpa: Allocator,
    key: []const u8,
) !struct { count: usize, reached: bool } {
    var walk = try @import("read.zig").iter(doc, gpa);
    defer walk.deinit();
    var count: usize = 0;
    var reached = false;
    while (try walk.next()) |got| {
        var item = got;
        defer item.deinit(gpa);
        count += 1;
        const k = item.key() orelse continue;
        if (std.mem.eql(u8, k, key)) reached = true;
    }
    return .{ .count = count, .reached = reached };
}

test "a bundle behind a document chunk is applied, and the receiver reads the sender's document" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **A snapshot and then a bundle of the very same two changes**, which is
    // the stream a peer that saved and then re-sent its history produces. The
    // bundle is not the first chunk here, so it is [`Document.applyChunk`] that
    // reads it — the arm the first-chunk path never reaches, and the one that
    // was handed a body where a framed chunk was wanted.
    const snapshot = try source.save(gpa);
    defer gpa.free(snapshot);
    const both = firstTwoChanges(&source);
    var written = try source.bundle(gpa, both[0..]);
    defer written.deinit(gpa);
    const stream = try concatChunks(gpa, &.{ snapshot, written.bytes() });
    defer gpa.free(stream);

    var peer = try Document.load(gpa, std.testing.io, stream, defaultTextEncoding());
    defer peer.deinit();
    try source.debugCmp(&peer);
    // **Nothing queued and nothing applied twice.** The snapshot already
    // carried both changes, so the bundle is a re-send: the receiver recognises
    // each change it holds rather than stacking a second copy of it.
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try testing.expectEqual(source.graph.len(), peer.graph.len());

    // **What a caller reads off the loaded document**, rather than how many
    // rows it has: the value the second change overwrote, and one written into
    // the map the first change created.
    try testing.expectEqualStrings("again", try scalarOfKey(&peer, .root, "hello"));
    const map = ExId{ .id = OpId.init(3, 0) };
    try testing.expectEqualStrings("yes", try scalarOfKey(&peer, map, "in_map"));

    // **And a recursive walk reaches the same properties the sender's does**,
    // which is a different question from the row comparison above: it descends
    // through the root into the objects the bundle carried, so rows that were
    // rebuilt without their objects would pass `debugCmp` and fail here.
    const walked = try walkReaching(&peer, gpa, "in_map");
    try testing.expect(walked.reached);
    const from_source = try walkReaching(&source, gpa, "in_map");
    try testing.expectEqual(from_source.count, walked.count);

    // **The fragments are the sender's**, which is the surface a peer picks
    // its next bundle from: level 0 only, oldest first, one member each.
    const parts = try peer.fragments(gpa, .{ .end = 1 });
    defer graphmod.deinitFragments(gpa, parts);
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expect(parts[0].head.eql(both[0]));
    try testing.expect(parts[1].head.eql(both[1]));
}

test "a bundle after a change chunk lands, and the two documents are one" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const both = firstTwoChanges(&source);

    // **The first change on the wire, then a bundle of the second** — which
    // names the first and finds it already applied. This is the two-arm stream
    // in the other order from the one above: `applyChunk`'s change arm and then
    // its bundle arm, both off one stream.
    var first = (try source.getChangeByHash(gpa, both[0])) orelse
        return error.MissingChange;
    defer first.deinit(gpa);
    const framed = try first.change.encode(gpa);
    defer gpa.free(framed);
    var second = try source.bundle(gpa, both[1..]);
    defer second.deinit(gpa);
    const stream = try concatChunks(gpa, &.{ framed, second.bytes() });
    defer gpa.free(stream);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    // **The sender's own row count.** `loadIncremental` into an empty document
    // answers how many rows the document now holds, and the rows are the
    // operations both changes carry — not the two changes themselves.
    try testing.expectEqual(source.ops.len(), try peer.loadIncremental(gpa, stream));
    // **Nothing queued.** The bundle's only dependency arrived in the chunk
    // before it, which is what makes it a load rather than a deferral.
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try source.debugCmp(&peer);
    try testing.expectEqualStrings("again", try scalarOfKey(&peer, .root, "hello"));
}

test "two bundles in one stream both land" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const both = firstTwoChanges(&source);

    // **One change each, concatenated.** The first bundle carries the change
    // with no dependency and the second names it, so the second is the chunk
    // that reaches `applyChunk`'s bundle arm and the first is the one the
    // first-chunk arm reads — the same reader, twice, off one stream, each
    // time against a different chunk's own framing.
    var one = try source.bundle(gpa, both[0..1]);
    defer one.deinit(gpa);
    var two = try source.bundle(gpa, both[1..]);
    defer two.deinit(gpa);
    const stream = try concatChunks(gpa, &.{ one.bytes(), two.bytes() });
    defer gpa.free(stream);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(source.ops.len(), try peer.loadIncremental(gpa, stream));
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    try source.debugCmp(&peer);
    try testing.expectEqualStrings("b", try scalarOfKey(&peer, .root, "only_b"));
}

test "the fragments of a document come back oldest first, and each encodes to bytes a peer can load" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **Level 0 only**, which is every change: a bundle of the whole history
    // has no level-1 head to find, so this is the shape the loose fragments
    // have ([`ChangeGraph.fragments`](change_graph.zig),
    // `change_graph.rs`:614-627).
    const parts = try source.fragments(gpa, .{ .end = 1 });
    defer graphmod.deinitFragments(gpa, parts);
    try testing.expectEqual(@as(usize, 2), parts.len);
    // **Newest first from the graph, oldest first from here** — upstream's
    // `fragments.reverse()` ([`automerge.rs`:1473-1476](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expect(parts[0].head.eql(firstTwoChanges(&source)[0]));
    try testing.expect(parts[1].head.eql(firstTwoChanges(&source)[1]));

    // **Each part loads into an empty document, and the two together build
    // the document.** This is the point of the surface: the caller sends
    // history in order, and a receiver that concatenates what it is sent ends
    // up with the document the sender had.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    // **The outer array is the caller's too**, so it is released after the
    // loop rather than left behind with the buffers it holds.
    const encodings = try source.bundleFragments(gpa, parts);
    defer {
        for (encodings) |bytes| gpa.free(bytes);
        gpa.free(encodings);
    }
    for (encodings) |bytes| _ = try peer.loadIncremental(gpa, bytes);
    try source.debugCmp(&peer);
}

/// Writes the bundle of `hashes` and releases it, for the sweep below.
///
/// **The document is built with the outer allocator, so the failing allocator
/// only reaches what [`Document.bundle`] itself allocates**: the metadata
/// array, the one block its `deps` windows point into, everything
/// [`Builder.init`](storage/bundle.zig) allocates, and the two framed chunks
/// [`Builder.finish`](storage/bundle.zig) writes. Every one of those is
/// reached by a fallible step, so every one of them has an unwind behind it.
fn bundleThenDeinit(gpa: Allocator, doc: *Document, hashes: []const ChangeHash) !void {
    var written = try doc.bundle(gpa, hashes);
    defer written.deinit(gpa);
    // **A bundle that came back is a whole bundle**, and these are two
    // different checks over two different bodies: `checksumValid` re-takes
    // the uncompressed rendering's hash, and `parseChunk` reads the on-disk
    // chunk's own header back — magic, type, LEB128 length and its checksum.
    // Neither is computed from what the writer meant to write, so a writer
    // that read a dependency window after the block behind it was gone is
    // caught rather than agreed with.
    try testing.expect(written.checksumValid());
    const parsed = try chunkmod.parseChunk(written.bytes());
    try testing.expectEqual(chunkmod.ChunkType.bundle, parsed.typ);
}

/// Encodes `wanted` through [`Document.bundleFragments`] and releases the
/// result, for the sweep below.
///
/// **The expected types are an argument rather than an assertion of a count**,
/// because the two arms produce different things: a level-0 fragment with one
/// member hands back that member's change chunk and anything else hands back a
/// bundle. The caller states which of each it asked for, and the sweep fails
/// if an encoding goes missing, arrives twice, or is the wrong chunk type.
fn fragmentsThenDeinit(
    gpa: Allocator,
    doc: *Document,
    wanted: []const Fragment,
    want_types: []const chunkmod.ChunkType,
) !void {
    const encodings = try doc.bundleFragments(gpa, wanted);
    defer {
        for (encodings) |bytes| gpa.free(bytes);
        gpa.free(encodings);
    }
    try testing.expectEqual(want_types.len, encodings.len);
    // **Each buffer is a whole framed chunk**, which is what a receiver
    // dispatches on. `parseChunk` allocates nothing and verifies the checksum
    // it reads, so this says the same thing however far the call got.
    for (encodings, want_types) |bytes, want| {
        try testing.expectEqual(want, (try chunkmod.parseChunk(bytes)).typ);
    }
}

test "a bundle and its fragment encodings survive every allocation failure" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **The two changes in graph order**, which is the order the fixture wrote
    // them: the second depends on the first, so a bundle of the second names a
    // change it does not carry.
    const both = firstTwoChanges(&source);
    const alone: [1]ChangeHash = .{both[0]};
    const missing: [1]ChangeHash = .{both[1]};
    const repeated: [2]ChangeHash = .{ both[1], both[1] };
    // **Mutable, because a `Fragment`'s `members` is a mutable slice the
    // fragment owns.** `both` comes out of the graph, so this array is a real
    // one and `original[0..]` is a slice of it rather than a window into
    // read-only memory. `ChangeGraph.fragments` allocates the same array for
    // every fragment it hands out; the two fragments above own theirs and
    // `deinitFragments` releases them, and this one is released with the test.
    var original: [2]ChangeHash = .{ both[0], both[1] };
    // **The hash lists `bundle` answers differently on**, one sweep each:
    //
    // * nothing at all, which is `min = 0` and `max = 1`
    //   ([`bundle.rs`:53-56](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs)):
    //   a walk over no row and a writer with nothing to write.
    // * the change carrying the delete (`buildSample`'s `ctr = 11`) on its own,
    //   so the row set is a strict subset of the document's.
    // * a subset whose counter range covers none of that change's rows, so
    //   every row the range excludes can only be reached through a successor
    //   edge — the second half of the visit test
    //   ([`bundleRowIsVisited`] over
    //   [`iter_ctr_range`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs):1254-1266).
    // * the document's own heads, which is the one list that names no
    //   external dependency.
    // * the same change twice. Upstream maps over the caller's list and
    //   deduplicates nothing ([`bundle.rs`:41-50](../../github-automerge-automerge/rust/automerge/src/storage/bundle.rs)),
    //   so the change is written twice and the second row resolves its
    //   dependency to the later index.
    const lists = [_][]const ChangeHash{
        &.{},
        alone[0..],
        missing[0..],
        original[0..],
        repeated[0..],
    };
    // Keep failure indices independent of SafeAllocator's in-place growth.
    var backing: testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    for (lists) |hashes| {
        try testing.checkAllAllocationFailures(backing.allocator(), bundleThenDeinit, .{ &source, hashes });
    }

    // **Both arms of `bundleFragments`, on real fragments.** The first two are
    // the document's own level-0 fragments, one member each, so each is its
    // member's change chunk. The third names both changes under one head, and
    // is a bundle over them — the arm the level-0 fragments of this fixture
    // never reach, because a two-change history has no level-1 head to find.
    const parts = try source.fragments(gpa, .{ .end = 1 });
    defer graphmod.deinitFragments(gpa, parts);
    try testing.expectEqual(@as(usize, 2), parts.len);
    // **Both are one-member level-0 fragments**, which is the whole of what
    // puts them on the change-chunk arm: a level-0 fragment is one change
    // ([`ChangeGraph.fragments`](change_graph.zig)). The expectation below is
    // about the fixture rather than about a method's internals.
    for (parts) |part| {
        try testing.expectEqual(@as(usize, 1), part.members.len);
        try testing.expectEqual(@as(usize, 0), part.head.fragmentLevel());
    }
    const wanted = [_]Fragment{
        parts[0],
        parts[1],
        .{
            .head = both[1],
            .level = 0,
            .boundary = &.{},
            .checkpoints = &.{},
            .members = original[0..],
        },
    };
    const want_types = [_]chunkmod.ChunkType{ .change, .change, .bundle };
    // **Slices, not pointers to arrays.** `checkAllAllocationFailures` hands
    // the arguments to `@call` as they are, so what goes in the tuple has to
    // be the parameter's type and not something it coerces to.
    try testing.checkAllAllocationFailures(
        backing.allocator(),
        fragmentsThenDeinit,
        .{ &source, wanted[0..], want_types[0..] },
    );

    // **And once with a real allocator**, which is the round the sweep's
    // induced failures cannot make: every buffer still loads and the two
    // change chunks plus the bundle rebuild the document.
    const encodings = try source.bundleFragments(gpa, wanted[0..]);
    defer {
        for (encodings) |bytes| gpa.free(bytes);
        gpa.free(encodings);
    }
    try testing.expectEqual(want_types.len, encodings.len);
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    for (encodings) |bytes| _ = try peer.loadIncremental(gpa, bytes);
    try source.debugCmp(&peer);
}

test "a fragment the document cannot encode produces no buffer rather than failing the call" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();

    // **Two fragments that encode, then one that cannot.** The first two are
    // the document's own level-0 fragments, so each is its member's change
    // chunk. The third has to reach the **bundle** arm to be a refusal at all,
    // and the arm is chosen by `f.head.fragment_level() == 0 && f.members.len()
    // == 1` ([`automerge.rs`:1496-1500](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so a fragment with **one** member never gets there: the change arm reads
    // the fragment's *head*, and a head this document holds is a change it can
    // hand back however absent its members are. **Two members, one of them a
    // hash the document has never seen**, is the shape that asks for a bundle
    // the document cannot build — [`Document.bundle`] refuses it with
    // `error.MissingDeps`
    // ([`change_graph.rs`:338-382](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)).
    const parts = try source.fragments(gpa, .{ .end = 1 });
    defer graphmod.deinitFragments(gpa, parts);
    try testing.expectEqual(@as(usize, 2), parts.len);
    // **A members array of its own, with the stranger beside a change the
    // document does hold.** `Fragment.members` is a mutable slice the fragment
    // owns, so a literal will not do: a comptime array of comptime hashes is
    // read-only memory, and a fragment naming it as its own is a fragment
    // nobody could give back. This is the array `ChangeGraph.fragments` would
    // have built, and the held hash beside the stranger is what makes the
    // refusal about the *fragment* rather than about the document.
    const both = firstTwoChanges(&source);
    const mixed_members = try gpa.alloc(ChangeHash, 2);
    defer gpa.free(mixed_members);
    mixed_members[0] = both[0];
    mixed_members[1] = .{ .bytes = @splat(0x5a) };
    const wanted = [_]Fragment{
        parts[0],
        parts[1],
        .{
            .head = both[1],
            .level = 0,
            .boundary = &.{},
            .checkpoints = &.{},
            .members = mixed_members,
        },
    };

    // **The two that encode survive the one that does not.** Upstream's
    // `filter_map` gives `Some(self.bundle(f.members).ok()?.bytes().to_vec())`
    // ([`automerge.rs`:1499](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // so the fragment contributes no entry and the caller keeps every encoding
    // built for the fragments before it — rather than losing those too, which
    // is what propagating the refusal did.
    const encodings = try source.bundleFragments(gpa, wanted[0..]);
    defer {
        for (encodings) |bytes| gpa.free(bytes);
        gpa.free(encodings);
    }
    try testing.expectEqual(@as(usize, 2), encodings.len);
    for (encodings) |bytes| {
        try testing.expectEqual(chunkmod.ChunkType.change, (try chunkmod.parseChunk(bytes)).typ);
    }
    // **And a reader is left with the same document**, which is what the two
    // surviving buffers are for.
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    for (encodings) |bytes| _ = try peer.loadIncremental(gpa, bytes);
    try source.debugCmp(&peer);
}

/// Walks the columns of a bundle [`Document.bundle`] just wrote and compares
/// them with a re-parse of the very same bytes.
///
/// **The two walks have to agree byte for byte, and the written one is the one
/// that used to read freed memory.** [`RawColumns`] stores its data block
/// **borrowed** — `data: []const u8` with a "Borrowed, never copied" comment
/// (`src/storage/column_spec.zig`:408-409) — and [`Builder.finish`] builds
/// the two data blocks in `ArrayList`s whose `defer`s free them the moment it
/// returns. A bundle whose sets still pointed at them handed back a value that
/// decoded freed heap; `testing.allocator` fills a freed block with `0xaa`, so
/// the counters would come back as garbage rather than as the ones the change
/// really carries, and the collector would refuse the change for claiming ops
/// it does not hold.
fn writtenBundleThenWalk(gpa: Allocator, doc: *Document, hashes: []const ChangeHash) !void {
    var written = try doc.bundle(gpa, hashes);
    defer written.deinit(gpa);
    var written_changes = try collectFrom(gpa, &written);
    defer written_changes.deinit(gpa);
    // **And the same bytes through a reader.** `Document.applyChunk` hands a
    // parsed bundle to the same collector, so this is the second rendering of
    // one document rather than a second document.
    var reread = try bundlem.parse(gpa, written.bytes());
    defer reread.deinit(gpa);
    var read_changes = try collectFrom(gpa, &reread);
    defer read_changes.deinit(gpa);
    try testing.expectEqual(read_changes.len(), written_changes.len());
    for (read_changes.slice(), written_changes.slice()) |a, b| {
        try testing.expectEqualSlices(u8, a.change.hash.bytes[0..], b.change.hash.bytes[0..]);
        try testing.expectEqualSlices(u8, a.body, b.body);
    }
    for (hashes, written_changes.slice()) |want, got| {
        try testing.expectEqualSlices(u8, want.bytes[0..], got.change.hash.bytes[0..]);
    }
}

/// What [`collectBundleChanges`] makes of one bundle, for the walk above.
fn collectFrom(gpa: Allocator, b: *const Bundle) !Changes {
    var out: Changes = .{};
    errdefer out.deinit(gpa);
    try collectBundleChanges(gpa, b, &out);
    return out;
}

test "a written bundle walks its own columns after the writer's scratch is gone" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const both = firstTwoChanges(&source);
    const list: []const ChangeHash = &both;
    try writtenBundleThenWalk(gpa, &source, list);
    // **A subset that names a change it does not carry, as well.** The second
    // change depends on the first, so bundling it alone puts the first's hash
    // in the prefix, gives the bundle an actor list of its own, and makes the
    // collector resolve a dependency index against that prefix rather than
    // against a change it has already finished — a third rendering of one
    // document for the two walks to agree on.
    try writtenBundleThenWalk(gpa, &source, list[1..2]);
}

/// Writes a bundle of `hashes` and loads it into an empty peer, for the sweep
/// below.
///
/// **The load is what reaches [`collectBundleChanges`]**, and the collector is
/// where the double cleanup was: `Document.applyChunk` hands a parsed bundle
/// straight to it, so this is the same walk with the same reads. A failing
/// allocator stops it at every allocation in turn, including the ones after
/// the metadata list's cleanup — the `gpa.alloc(usize, count)`, the op walk,
/// `checkCoverage` and `finishOne` — which is exactly where the `errdefer` and
/// the identical `defer` used to fire together and free every dependency
/// window and the list a second time.
fn loadBundleChunkThenDeinit(gpa: Allocator, doc: *Document, hashes: []const ChangeHash) !void {
    var written = try doc.bundle(gpa, hashes);
    defer written.deinit(gpa);
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(doc.ops.len(), try peer.loadIncremental(gpa, written.bytes()));
}

test "a bundle chunk survives every allocation failure on the way back in" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    // **The two changes in graph order.** The second depends on the first, so
    // the bundle carries both and names no external dependency — a bundle that
    // named one would queue instead of apply and the walk would stop early.
    const both = firstTwoChanges(&source);
    const list: []const ChangeHash = &both;
    // Keep failure indices independent of SafeAllocator's in-place growth.
    var backing: testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(backing.allocator(), loadBundleChunkThenDeinit, .{ &source, list });
}

/// Writes two bundles and loads both into one peer, for the sweep below.
///
/// **The stream is two chunks where the sweep above is one**, because the
/// second bundle is what reaches [`Document.applyChunk`]'s bundle arm: the
/// collector's metadata list, the builder table, the row walk and the change
/// bodies it hands back are all allocated per bundle, and a one-chunk stream
/// reads only the first-chunk path. Both bundles are written with the supplied
/// allocator and so is the peer, so an induced failure lands in the same place
/// an ordinary out-of-memory would.
fn loadTwoBundleChunksThenDeinit(
    gpa: Allocator,
    doc: *Document,
    first_hash: ChangeHash,
    second_hash: ChangeHash,
) !void {
    var one = try doc.bundle(gpa, &.{first_hash});
    defer one.deinit(gpa);
    var two = try doc.bundle(gpa, &.{second_hash});
    defer two.deinit(gpa);
    const stream = try concatChunks(gpa, &.{ one.bytes(), two.bytes() });
    defer gpa.free(stream);
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(doc.ops.len(), try peer.loadIncremental(gpa, stream));
}

test "a bundle behind another bundle survives every allocation failure" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const both = firstTwoChanges(&source);
    // Keep failure indices independent of SafeAllocator's in-place growth.
    var backing: testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(
        backing.allocator(),
        loadTwoBundleChunksThenDeinit,
        .{ &source, both[0], both[1] },
    );
}

test "a bundle whose change claims ops its rows do not fill is refused" {
    const gpa = testing.allocator;
    // **One change, claiming three ops, with one row.** Upstream derives the
    // range from the rows it is about to encode, so a bundle like this cannot
    // come out of a document — but [`bundlem.Builder`] takes the metadata as an
    // argument and is `pub`, and `test/fixtures/incorrect_max_op.automerge` is
    // the same disagreement in the other direction.
    const actors = [_]ActorId{.{ .bytes = actor_a }};
    const one_row = bundlem.BundleOp{
        .id = OpId.init(1, 0),
        .obj = .root,
        .key = .{ .map = "k" },
        .action = .set,
        .value = .{ .int = 1 },
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    };
    var metas = [_]bundlem.BundleMetadata{.{
        .hash = ChangeHash.zero,
        .actor = 0,
        .seq = 1,
        .max_op = 3,
        .timestamp = 0,
        .message = null,
        .deps = &.{},
        .extra = &.{},
        .start_op = 1,
        .builder = 0,
    }};
    var builder = try bundlem.Builder.init(gpa, &metas, &actors);
    defer builder.deinit(gpa);
    try builder.processOp(one_row);
    var written = try builder.finish(gpa);
    defer written.deinit(gpa);

    // **A refusal, and nothing half-loaded.** `testing.allocator` is what
    // notices a double free, so this is the whole of the assertion: the call
    // does not succeed, and the document, its queue and the collector's
    // metadata list all come back empty. **Which refusal it is, is not the
    // contract and not asserted** — see [`loadMalformedThenRefuse`].
    loadMalformedThenRefuse(gpa, written.bytes()) catch |e| switch (e) {
        // **A correct refusal is this helper's passing outcome.** A bare `try`
        // here turned the very refusal the case is about into a test failure.
        error.Refused => {},
        else => return e,
    };

    // **And the same producer, the same row and the same reader with a claim
    // the row fills.** Without this the refusal would only say that *some*
    // bundle of this shape does not load; with it, the disagreement between
    // the claim and the rows is the only thing the two bundles differ in, and
    // that is what the refusal is about.
    var agreed = [_]bundlem.BundleMetadata{.{
        .hash = ChangeHash.zero,
        .actor = 0,
        .seq = 1,
        .max_op = 1,
        .timestamp = 0,
        .message = null,
        .deps = &.{},
        .extra = &.{},
        .start_op = 1,
        .builder = 0,
    }};
    var whole = try bundlem.Builder.init(gpa, &agreed, &actors);
    defer whole.deinit(gpa);
    try whole.processOp(one_row);
    var consistent = try whole.finish(gpa);
    defer consistent.deinit(gpa);
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 1), try peer.loadIncremental(gpa, consistent.bytes()));
    try testing.expectEqual(@as(usize, 1), peer.graph.len());

    // **And the same refusal under every induced failure**, which is the sweep
    // that reaches the allocations on the way to it and on the way back: the
    // collector builds the bundle, parses it, walks both column blocks, and
    // refuses — and `checkAllAllocationFailures` cannot drive a call that never
    // succeeds, so the loop is written out.
    const chunk = written.bytes();
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        loadMalformedThenRefuse(failing.allocator(), chunk) catch |e| switch (e) {
            error.OutOfMemory => return error.UnexpectedOutOfMemory,
            error.Refused => {},
            else => return e,
        };
        break :blk failing.alloc_index;
    };
    try testing.expect(needed > 0);
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        loadMalformedThenRefuse(failing.allocator(), chunk) catch |e| switch (e) {
            // **Two refusals, both of them correct.** The induced one is the
            // allocator; the other is the bundle. Either way the document, its
            // queue and the collector's metadata list are all empty and every
            // byte handed out has come back.
            error.OutOfMemory, error.Refused => {},
            else => return e,
        };
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

/// Loads the bundle chunk `bytes` and asserts the refusal, for the test above.
///
/// **`error.Refused` is this function's own word for "the bundle did not
/// load"**, so the sweep can tell "the allocator ran out" from "the bundle was
/// refused" without either being swallowed.
///
/// **Which stage refuses is not asserted, and deliberately so.** The
/// disagreement a bundle's change metadata and its op columns cannot both be
/// true about has two answers here, and upstream has both as well: the storage
/// layer materialises the op counters from the change's claimed range and the
/// wire's inverse permutation, and reports the two lengths disagreeing as
/// `error.TooManyOps` (upstream's `InverseLengthMismatch`,
/// [`storage.rs`:120-127](../../github-automerge-automerge/rust/automerge/src/storage/bundle/storage.rs));
/// the collector, given a bundle that parses, reports rows that do not fill
/// the range they claim as `error.Fail` (upstream's `MissingOps`,
/// [`collector.rs`:303-316](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs)).
/// **The bundle the public writer builds reaches the first one**, because a
/// writer writes one inverse entry per row and the claimed range then cannot
/// be longer than the row set — so pinning the second would be pinning a stage
/// a caller cannot reach, and a test that names one stops being a test of the
/// refusal when either half of the pipeline moves.
fn loadMalformedThenRefuse(gpa: Allocator, bytes: []const u8) !void {
    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    if (peer.loadIncremental(gpa, bytes)) |applied| {
        std.debug.print("doc: the malformed bundle applied {d} changes\n", .{applied});
        return error.UnexpectedSuccess;
    } else |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooManyOps, error.Fail => {},
        else => return e,
    }
    try testing.expectEqual(@as(usize, 0), peer.graph.len());
    try testing.expectEqual(@as(usize, 0), peer.ops.len());
    try testing.expectEqual(@as(usize, 0), peer.queue.len());
    // **A correct refusal is reported as `error.Refused`, and that is the
    // helper's contract.** The sweep in the case below drives it through an
    // allocator that refuses, so it has to tell a semantic refusal (this) from
    // an induced `error.OutOfMemory`, and it does that by the identity of the
    // error it receives. A caller that only wants "these bytes are refused and
    // nothing is left behind" catches `error.Refused` as the passing outcome.
    return error.Refused;
}

// ── Diffing ──────────────────────────────────────────────────────────────────
//
// **Every expectation below came out of the reference implementation**, not out
// of a reading of it: `tools/oracle`'s `diff` subcommand scripts the same three
// documents and prints what `Automerge::diff` and `AutoCommit::diff_incremental`
// produced, and `test/golden/diff.jsonl` is its output. The two renderings
// differ — upstream derives `Debug` for a patch and `patch.rs:91-93` says so —
// so what is compared here is the *content* of each patch, and the op ids are
// the same on both sides because the fixtures use the op counters the reference
// wrote.
//
// **A hand-built op set would prove nothing about this slice.** The thing under
// test is the wiring — a change applied through [`Document.applyChanges`], a log
// that records it, a walk that descends into the objects the diff surfaces, and
// a patch layer that resolves their paths — and none of that is reachable from
// a fixture that skips every one of those steps. `patches.zig`'s own tests use a
// `TestDoc` and are right to: they test the patch builder, not the wiring.

/// One change: `specs` applied by `actor`, and applied to `doc` through
/// [`Document.applyChanges`] exactly as a peer's change is.
fn applySpec(
    doc: *Document,
    gpa: Allocator,
    actor: []const u8,
    seq: u64,
    start_op: u64,
    deps: []const ChangeHash,
    specs: []const OpSpec,
) !ChangeHash {
    const idx = try doc.putActorRef(gpa, .{ .bytes = actor });
    const ops = try buildOps(gpa, idx, specs);
    defer freeChangeOps(gpa, ops);
    return applyHandChange(doc, gpa, actor, seq, start_op, deps, null, ops);
}

/// The whole stream, line by line, compared **by content and in order**.
///
/// **`expectEqualStrings` per line and not `expectEqual` on the slice**: the
/// latter compares the pointers (`std/testing.zig`:130-139`), which is the trap
/// `patches.zig`'s own `expectPatches` is written around. Every mismatch prints
/// both streams, so a failure says what changed and not merely that something
/// did.
fn expectStream(
    gpa: Allocator,
    list: *const patchesmod.Patches,
    want: []const []const u8,
) !void {
    const got = list.slice();
    if (got.len != want.len) {
        std.debug.print("got {d} patches, want {d}\n", .{ got.len, want.len });
        for (got) |patch| {
            const line = try patchesmod.formatPatch(gpa, patch);
            defer gpa.free(line);
            std.debug.print("  got:  {s}\n", .{line});
        }
        for (want) |line| std.debug.print("  want: {s}\n", .{line});
        return error.TestUnexpectedResult;
    }
    for (got, want) |patch, line_want| {
        const line = try patchesmod.formatPatch(gpa, patch);
        defer gpa.free(line);
        if (!std.mem.eql(u8, line, line_want)) {
            std.debug.print("got  {s}\nwant {s}\n", .{ line, line_want });
            return error.TestUnexpectedResult;
        }
    }
}

/// A root map holding one register, committed by `actor_a`.
///
/// **Op counter 1**, so the base change writes `1@0` and a peer writing its own
/// first register writes `1@1` — which is what the reference writes, because
/// op counters are per actor (`op_set2/types.rs`:659-668`).
fn oneKeyDoc(gpa: Allocator) !Document {
    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    _ = try applySpec(&doc, gpa, actor_a, 1, 1, &.{}, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("a"), .value = .{ .str = "one" } },
    });
    return doc;
}

test "a diff over a mutated document names the register that changed, and nothing else" {
    const gpa = testing.allocator;
    var doc = try oneKeyDoc(gpa);
    defer doc.deinit();

    // The heads **before** the second change, taken from the document rather
    // than written down: a diff between two literals would not notice a document
    // that failed to move.
    const before = try doc.getHeads(gpa);
    defer gpa.free(before);
    try testing.expectEqual(@as(usize, 1), before.len);

    // **A second actor, so the patch's id carries an actor index that is not
    // zero** — a diff that resolved ids wrongly would look right with one actor.
    // `start_op = 2` is the document-wide maximum the reference assigns here.
    _ = try applySpec(&doc, gpa, actor_b, 1, 2, before, &.{
        .{ .ctr = 2, .key = KeyRef.fromStr("b"), .value = .{ .str = "two" } },
    });
    const after = try doc.getHeads(gpa);
    defer gpa.free(after);

    var patches = try doc.diff(gpa, before, after);
    defer patches.deinit();
    // **`a` is absent, and that is the assertion.** A diff that reported the
    // whole document, or that lost track of which rows the clock range covers,
    // would put `a` in this stream.
    try expectStream(gpa, &patches, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 2@1, conflict: false }",
    });
}

test "a diff descends into an object the root's own diff does not name" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();

    // The base change makes a list and **does not fill it**, so the second
    // change's insert is into a list that already existed.
    _ = try applySpec(&doc, gpa, actor_a, 1, 1, &.{}, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("l"), .action = .make_list },
    });
    const before = try doc.getHeads(gpa);
    defer gpa.free(before);
    const list: ExId = .{ .id = OpId.init(1, 0) };

    // **The insert is the lower op id and the put the higher one**, so the two
    // patches are distinguishable by id alone.
    _ = try applySpec(&doc, gpa, actor_b, 1, 2, before, &.{
        .{
            .ctr = 2,
            .obj = list,
            .key = KeyRef.fromElemId(ElemId.head()),
            .insert = true,
            .value = .{ .str = "x" },
        },
        .{ .ctr = 3, .key = KeyRef.fromStr("k"), .value = .{ .str = "v" } },
    });
    const after = try doc.getHeads(gpa);
    defer gpa.free(after);

    var patches = try doc.diff(gpa, before, after);
    defer patches.deinit();
    // **The root's register `l` is `Diff::Same`**, so nothing in the root's own
    // diff says the list changed — the walk has to follow `make_obj`'s
    // `is_visible` arm for a `Same` object value (`iter/doc.rs`:420`) to reach
    // it. The second patch is therefore the one this test exists for, and its
    // **path** is the other half: the patch layer resolved `l`'s parent without
    // being told it.
    try expectStream(gpa, &patches, &.{
        "root path=[] PutMap { key: \"k\", value: Str(\"v\"), obj: 3@1, conflict: false }",
        "1@0 path=[root.Map(\"l\")] Insert { index: 0, values: [{ value: Str(\"x\"), obj: 2@1, conflict: false }] }",
    });
}

test "an incremental diff reports what the document recorded, and the cursor makes the next one empty" {
    const gpa = testing.allocator;
    var doc = try oneKeyDoc(gpa);
    defer doc.deinit();

    // **The cursor goes down before the edit.** That is the whole arrangement:
    // from here the document records what it applies, and an incremental diff
    // reads those events back instead of walking the op set.
    // (`autocommit.rs`:199-206` sets the cursor; the oracle's `diff incremental`
    // scenario scripts it in the same order.)
    const base_heads = try doc.getHeads(gpa);
    defer gpa.free(base_heads);
    try doc.updateDiffCursor();
    const cursor_now = try doc.diffCursor(gpa);
    defer gpa.free(cursor_now);
    try testing.expectEqualSlices(ChangeHash, base_heads, cursor_now);

    // **A peer's change**, which is the path upstream routes into `patch_log`
    // (`autocommit.rs`:498`), and the one the port has to have fed.
    _ = try applySpec(&doc, gpa, actor_b, 1, 1, base_heads, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("b"), .value = .{ .str = "two" } },
    });

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();
    // **Half one: the stream carries the new change, by content.** `a` is
    // absent because the cursor was set after it and nothing since then touched
    // it — which is the difference between this and [`Document.diff`], and the
    // reason the method exists.
    try expectStream(gpa, &first, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 1@1, conflict: false }",
    });

    // **`diffIncremental` moved the cursor itself** (`autocommit.rs`:354`), so the
    // cursor is now at the document's heads and not at the base change.
    const moved = try doc.diffCursor(gpa);
    defer gpa.free(moved);
    try testing.expect(!sameHashList(base_heads, moved));

    // **Half two: with the cursor at the heads, the stream is empty.** A cursor
    // that did nothing would fail here and only here, and a log that had not
    // been truncated would fail it too. `updateDiffCursor` is called explicitly
    // as well so that the emptying is attributable to it and not only to the
    // move `diffIncremental` made on its way out.
    try doc.updateDiffCursor();
    var second = try doc.diffIncremental(gpa);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 0), second.len());

    // **And the cursor is the only reason it is empty.** The same two heads,
    // read the un-indexed way, still produce the change: the walk did not stop
    // working, the log simply has nothing new in it.
    var walked = try doc.diff(gpa, base_heads, moved);
    defer walked.deinit();
    try expectStream(gpa, &walked, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 1@1, conflict: false }",
    });
}

test "an empty document's cursor is not a cursor, and resetting one stops the recording" {
    const gpa = testing.allocator;

    // **A document with no changes is left alone** (`autocommit.rs`:202`'s
    // `if !heads.is_empty()`): a cursor at "nothing" would make the next
    // incremental diff report the empty state as an addition, and the log would
    // be on for a document that has nothing to record.
    var empty = try Document.init(gpa, std.testing.io);
    defer empty.deinit();
    try empty.updateDiffCursor();
    try testing.expectEqual(@as(usize, 0), empty.diff_cursor.items.len);
    try testing.expect(!empty.patch_log.isActive());

    // **`resetDiffCursor` is what makes the recording worth turning off**
    // (`autocommit.rs`:191-198`): after it the log is inactive again, and the
    // next apply is not recorded — which is observable, because an incremental
    // diff over the same two heads still finds the change.
    var doc = try oneKeyDoc(gpa);
    defer doc.deinit();
    const base_heads = try doc.getHeads(gpa);
    defer gpa.free(base_heads);
    try doc.updateDiffCursor();
    _ = try applySpec(&doc, gpa, actor_b, 1, 1, base_heads, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("b"), .value = .{ .str = "two" } },
    });
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);

    var recorded = try doc.diffIncremental(gpa);
    defer recorded.deinit();
    try testing.expectEqual(@as(usize, 1), recorded.len());

    doc.resetDiffCursor();
    try testing.expectEqual(@as(usize, 0), doc.diff_cursor.items.len);
    try testing.expect(!doc.patch_log.isActive());

    // **The apply after the reset is not recorded**, so an incremental diff
    // falls back to the walk (`diffInner`'s third arm) rather than to the log.
    _ = try applySpec(&doc, gpa, actor_c, 1, 2, heads, &.{
        .{ .ctr = 2, .key = KeyRef.fromStr("c"), .value = .{ .str = "three" } },
    });
    const later = try doc.getHeads(gpa);
    defer gpa.free(later);
    var after_reset = try doc.diffIncremental(gpa);
    defer after_reset.deinit();
    // **Three patches and all three are additions**: `c` because the walk found
    // it, `a` and `b` because the cursor is empty again, so the range is "from
    // nothing" and every visible register is an addition. A log that was still
    // recording would have answered with `c` alone.
    try testing.expectEqual(@as(usize, 3), after_reset.len());
}

test "a local commit reaches the incremental diff, and the cursor then empties it" {
    // A logged raw transaction returns the eager operation log to its caller.
    // Installing that result is explicit; raw commit never reconstructs a diff
    // (`autocommit.rs:728-739` merges the transaction branch at the facade).
    const trans = @import("transact.zig");
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = &oracle_actor });

    var setup = try trans.Transaction.open(gpa, &doc);
    _ = try setup.put(.root, .{ .key = "a" }, .{ .str = "one" });
    var setup_result = try setup.commitWith(.{ .time = oracle_time });
    defer setup_result.deinit(gpa);
    setup.deinitClosed();

    // **The cursor goes down before the edit**, so the log is recording and
    // the fast path is the arm under test rather than the walk
    // (`autocommit.rs:199-206` sets the cursor; `:276-286` reads it).
    const base = try doc.getHeads(gpa);
    defer gpa.free(base);
    try doc.updateDiffCursor();

    var t = try trans.Transaction.openWithPatchLog(gpa, &doc, &doc.patch_log, null);
    _ = try t.put(.root, .{ .key = "b" }, .{ .str = "two" });
    var local_result = try t.commitWith(.{ .time = oracle_time });
    defer local_result.deinit(gpa);
    const local = local_result.hash.?;
    std.mem.swap(patchesmod.PatchLog, &doc.patch_log, &local_result.patch_log);
    t.deinitClosed();
    const after = try doc.getHeads(gpa);
    defer gpa.free(after);
    // **The commit really did move the document**, which the rest of the test
    // assumes: a commit that changed nothing would make the stream below empty
    // for a reason that has nothing to do with the feed.
    try testing.expectEqualSlices(u8, &local.bytes, &after[0].bytes);

    // **Half one: the local commit's own patch, by content.** Op counter 2 on
    // actor 0 — the first change took counter 1, and counters are a
    // document-wide namespace ([`automerge.rs:566-567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // A count would pass on the wrong patch, so this is the line.
    var first = try doc.diffIncremental(gpa);
    defer first.deinit();
    try expectStream(gpa, &first, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 2@0, conflict: false }",
    });

    // **And it is the same stream the un-indexed walk produces** over the same
    // two points in history. The recorded route and the walked route are two
    // ways to one answer, so a difference here would say the feed is wrong
    // rather than merely different.
    var walked = try doc.diff(gpa, base, after);
    defer walked.deinit();
    try expectStream(gpa, &walked, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 2@0, conflict: false }",
    });

    // **Half two: the cursor advanced.** `diffIncremental` moved it on its way
    // out (`autocommit.rs:354`), so the cursor is at the document's heads and a
    // second call over an unchanged document is empty. **A cursor that never
    // moved still passes half one**, which is why both are here.
    const moved = try doc.diffCursor(gpa);
    defer gpa.free(moved);
    try testing.expectEqualSlices(ChangeHash, after, moved);
    var second = try doc.diffIncremental(gpa);
    defer second.deinit();
    try expectStream(gpa, &second, &.{});

    // **And the emptiness is the log's, not the walk's.** The same two heads
    // read the un-indexed way still produce the change, so the walk did not
    // stop working — `truncate` emptied the recording and nothing else.
    var still_there = try doc.diff(gpa, base, after);
    defer still_there.deinit();
    try expectStream(gpa, &still_there, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"two\"), obj: 2@0, conflict: false }",
    });
}

test "recording a commit does not change the change it made" {
    // Logging records eager operation events in the same transaction kernel.
    // The requested log must not alter encoded bytes, hashes or committed heads.
    const trans = @import("transact.zig");
    const gpa = testing.allocator;

    const Scripted = struct {
        changes: Changes,
        heads: []ChangeHash,
    };
    const script = struct {
        /// Two commits by one actor, the second made with `watching` deciding
        /// whether the diff cursor is down first.
        fn run(alloc: Allocator, watching: bool) !Scripted {
            var doc = try Document.init(alloc, std.testing.io);
            defer doc.deinit();
            doc.setActorId(.{ .bytes = &oracle_actor });

            var t = try trans.Transaction.open(alloc, &doc);
            _ = try t.put(.root, .{ .key = "a" }, .{ .str = "one" });
            var base_result = try t.commitWith(.{ .message = "base", .time = oracle_time });
            defer base_result.deinit(alloc);
            t.deinitClosed();

            // **The cursor only takes on a document that has a head**
            // (`autocommit.rs:202`'s `if !heads.is_empty()`), which is why
            // there is a first commit before it.
            if (watching) try doc.updateDiffCursor();

            var t2 = if (watching)
                try trans.Transaction.openWithPatchLog(alloc, &doc, &doc.patch_log, null)
            else
                try trans.Transaction.open(alloc, &doc);
            _ = try t2.put(.root, .{ .key = "b" }, .{ .str = "two" });
            var second_result = try t2.commitWith(.{ .message = "second", .time = oracle_time });
            defer second_result.deinit(alloc);
            t2.deinitClosed();

            // **Collected before `doc.deinit`**: the bodies are this
            // document's own copies, and they have to outlive it.
            const heads = try doc.getHeads(alloc);
            return .{ .changes = try doc.getChanges(alloc, &.{}), .heads = heads };
        }
    };

    var quiet = try script.run(gpa, false);
    defer {
        quiet.changes.deinit(gpa);
        gpa.free(quiet.heads);
    }
    var watched = try script.run(gpa, true);
    defer {
        watched.changes.deinit(gpa);
        gpa.free(watched.heads);
    }

    try testing.expectEqual(@as(usize, 2), quiet.changes.len());
    try testing.expectEqual(quiet.changes.len(), watched.changes.len());
    for (quiet.changes.items.items, watched.changes.items.items) |a, b| {
        // **The bytes first**, because a byte-level failure names the encoder
        // and a hash-level failure does not.
        testing.expectEqualSlices(u8, a.body, b.body) catch |e| {
            std.debug.print(
                "doc: a change committed with the log recording is {d} bytes, without it {d}\n",
                .{ a.body.len, b.body.len },
            );
            return e;
        };
        try testing.expectEqualSlices(u8, &a.change.hash.bytes, &b.change.hash.bytes);
    }
    try testing.expectEqualSlices(ChangeHash, quiet.heads, watched.heads);
}

// ── The change-hash round trip ──────────────────────────────────────────────
//
// A change hash is SHA-256 over that change's own encoded bytes.
// The tests check each of the three directions it can break in: the document
// must hash what it wrote, the graph must record what it hashed, and the
// collector must rebuild the bytes the hash was taken over. The three tests
// are deliberately in that order — each one fails in a different place, and a
// suite that only had the last would pass on a document that cannot be saved.

/// The actor the reference's own scripted document was written by.
///
/// [`tools/oracle/src/main.rs:42`](../../tools/oracle/src/main.rs) spells it
/// `ACTOR_A = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"` — **thirty** hex characters —
/// and `actor(hex)` (`:405-407`) hex-decodes it, so the actor is **fifteen**
/// bytes of `0xa1`. Thirty-two bytes is what the literal looks like, and a
/// change header records the actor's byte count, so one extra `0xa1` is a
/// different change with a different hash. `ACTOR_B` on `:45` *is* thirty-two
/// characters and sixteen bytes; the asymmetry is in the reference's own
/// constants, and the golden chunks are what it produced from them.
const oracle_actor = @as([15]u8, @splat(0xa1));

/// The timestamp [`tools/oracle/src/main.rs:157-159`](../../tools/oracle/src/main.rs)
/// (`commit_options`) stamps on every commit of the scripted document. It is a
/// header field, so it is hash-visible.
const oracle_time: i64 = 1_700_000_000;

/// The reference's own scripted document, built here through **this port's
/// write path**: `base_document` (`main.rs:116-143`) followed by the second
/// commit `change_command` makes (`:195-198`).
///
/// The operations, the actor, both messages and the timestamp are the
/// reference's, and so are the op counters: `test/golden/change.jsonl` records
/// the second change at `seq 2`, `start_op 26`, which is what says the first
/// change holds twenty-five ops and that `seq` and `start_op` both move. Two
/// commits, so the second change has a dependency and the head is not the
/// first change — a fixture with one change would not exercise the dependency
/// hash in the header.
fn buildOracleDocument(gpa: Allocator) !Document {
    // **Local, not at file scope.** `transact.zig` imports this one, and a
    // file-scope const in both directions is a cycle that only works until it
    // does not. Nothing outside these tests needs the write surface.
    const trans = @import("transact.zig");

    var doc = try Document.init(gpa, std.testing.io);
    errdefer doc.deinit();
    doc.setActorId(.{ .bytes = &oracle_actor });

    var t = try trans.Transaction.open(gpa, &doc);
    _ = try t.put(.root, .{ .key = "title" }, .{ .str = "zautomerge oracle" });
    const list = try t.putObject(.root, .{ .key = "list" }, .list);
    _ = try t.insert(list, 0, .{ .int = -1 });
    _ = try t.insert(list, 1, .{ .str = "two" });
    _ = try t.insert(list, 2, .{ .float = 3.5 });
    _ = try t.insert(list, 3, .{ .bool_value = true });
    _ = try t.insert(list, 4, .{ .uint = 7 });
    const text = try t.putObject(.root, .{ .key = "text" }, .text);
    try t.spliceText(text, 0, 0, "hello ");
    try t.spliceText(text, 6, 0, "world");
    const map = try t.putObject(.root, .{ .key = "map" }, .map);
    _ = try t.put(map, .{ .key = "keep" }, .{ .str = "kept" });
    _ = try t.put(map, .{ .key = "counter" }, .{ .counter = .init(0) });
    _ = try t.put(map, .{ .key = "drop" }, .{ .str = "dropped" });
    try t.increment(map, .{ .key = "counter" }, 5);
    _ = try t.delete(map, .{ .key = "drop" });
    var first_result = try t.commitWith(.{ .message = "base", .time = oracle_time });
    defer first_result.deinit(gpa);
    t.deinitClosed();

    var t2 = try trans.Transaction.open(gpa, &doc);
    _ = try t2.put(.root, .{ .key = "extra" }, .{ .int = 1 });
    var second_result = try t2.commitWith(.{ .message = "extra", .time = oracle_time });
    defer second_result.deinit(gpa);
    t2.deinitClosed();
    return doc;
}

test "a locally built document saves, reloads, and comes back with the same change hashes" {
    // **The contract: a document that cannot reproduce its own change hashes
    // cannot be saved, reloaded or sent.** The heads this document reports are
    // the hashes its change graph recorded when the changes were committed; the
    // heads the reloaded document reports are hashes the collector *derived*,
    // by re-encoding the op rows. Two sources, and nothing in the type system
    // makes them agree.
    //
    // When they disagree the document is two documents that agree about
    // nothing, and `Document.load` refuses it with `error.MissingHash` — which
    // is upstream's `verify_changes`
    // ([`storage/document.rs:306-322`](../../github-automerge-automerge/rust/automerge/src/storage/document.rs)),
    // the head check whose whole job is this.
    const gpa = testing.allocator;
    var doc = try buildOracleDocument(gpa);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.stats().num_changes);
    try testing.expectEqual(@as(usize, 25), doc.stats().num_ops);
    try testing.expectEqual(@as(usize, 1), doc.stats().num_actors);

    const heads_before = try doc.getHeads(gpa);
    defer gpa.free(heads_before);
    try testing.expectEqual(@as(usize, 1), heads_before.len);

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer reloaded.deinit();

    // **The head hash is equal on both sides.** That is the sentence this test
    // exists to protect, and it is why the assertion is on the hashes and not
    // only on the rows.
    const heads_after = try reloaded.getHeads(gpa);
    defer gpa.free(heads_after);
    try testing.expectEqualSlices(ChangeHash, heads_before, heads_after);

    // **And the materialized document is the same one**, which is the other
    // half: equal heads over different rows is still a broken document.
    try doc.debugCmp(&reloaded);

    // **And the other direction**, because a save that cannot be read back is
    // only half a round trip. The reloaded document's own save must reload to
    // the same heads again, or the load fixed something rather than agreeing.
    const again = try reloaded.save(gpa);
    defer gpa.free(again);
    var twice = try Document.load(gpa, std.testing.io, again, defaultTextEncoding());
    defer twice.deinit();
    const heads_twice = try twice.getHeads(gpa);
    defer gpa.free(heads_twice);
    try testing.expectEqualSlices(ChangeHash, heads_before, heads_twice);
}

test "a change chunk the document hands out by hash is one change to an empty document" {
    // **The first step of the sync path**, and the two ends of it. `save`
    // writes a document chunk and a peer reads changes; `getChangeByHash` is
    // how a document answers a peer that names a change, and the bytes it
    // answers with must be the bytes the recorded hash was taken over.
    //
    // **The count is a number because a number is the only thing here that
    // fails.** [`Document.loadIncremental`] returns the number of *rows* the
    // load added
    // ([`automerge.rs:1065-1068`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and a change that is screened out is queued rather than applied — with no
    // error. A document whose graph holds the hash and whose rows do not match
    // therefore returns **zero** and looks like success. One op in the change,
    // one row out, so a skipped change is a zero and an applied one is a one.
    const trans = @import("transact.zig");
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = &oracle_actor });

    var t = try trans.Transaction.open(gpa, &doc);
    _ = try t.put(.root, .{ .key = "k" }, .{ .str = "v" });
    var commit_result = try t.commitWith(.{ .time = oracle_time });
    defer commit_result.deinit(gpa);
    const hash = commit_result.hash.?;
    t.deinitClosed();

    // **The document's only head is the change it just made**, so asking for
    // that head by hash is asking for the change itself.
    const heads = try doc.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, &hash.bytes, &heads[0].bytes);

    // **The rebuilt bytes hash to the hash that was asked for.** This is where
    // an author footer dropped on the way into the graph, or a header field the
    // collector fills in differently from the encoder, shows up: the change
    // still loads and still holds the right hash, and it is handed to the peer
    // under a hash of different bytes.
    var built = (try doc.getChangeByHash(gpa, hash)).?;
    defer built.deinit(gpa);
    try testing.expectEqualSlices(u8, &hash.bytes, &built.change.hash.bytes);
    const chunk = try built.change.encode(gpa);
    defer gpa.free(chunk);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, 0), peer.graph.len());
    const applied = try peer.loadIncremental(gpa, chunk);
    try testing.expectEqual(@as(usize, 1), applied);

    // **The peer holds the document the chunk came from**, under the same hash.
    try doc.debugCmp(&peer);
    const peer_heads = try peer.getHeads(gpa);
    defer gpa.free(peer_heads);
    try testing.expectEqual(@as(usize, 1), peer_heads.len);
    try testing.expectEqualSlices(u8, &hash.bytes, &peer_heads[0].bytes);
}

test "a change chunk the document hands out names the op its last operation has" {
    // **The property the C suite's three change cases turn on, asserted where
    // the value is built.** `AMchangeMaxOp` is `change.max_op()` and
    // `AMchangeSize` is `change.len()`
    // ([`automerge-c/src/change.rs:237-243`](../../github-automerge-automerge/rust/automerge-c/src/change.rs),
    // [`:294-299`](../../github-automerge-automerge/rust/automerge-c/src/change.rs)),
    // and both reach this port as one `Built.change`. Upstream cannot answer
    // zero for either, because a `Change` counts its ops as it decodes them —
    // `stored.verify_ops(|_| len += 1)`
    // ([`change.rs:30-46`](../../github-automerge-automerge/rust/automerge/src/change.rs)),
    // so `max_op()` is `start_op + len - 1`
    // ([`change.rs:74-76`](../../github-automerge-automerge/rust/automerge/src/change.rs))
    // for every `Change` that exists at all.
    //
    // **A change that lost `max_op` fails nothing on the way out.** It still
    // parses, still hashes to the same thirty-two bytes, and still hands its
    // peer every operation; the first reader to ask for the range is the one
    // that answers wrongly. So the numbers below are read three ways — the
    // graph, the change the document hands out by hash, and the rows of the
    // change chunk's own columns — and all three must be the same range.
    //
    // The first change is **one** `put`, which is the shape
    // `test_AMchange_scalars` builds (`test/c/abi_coverage.c:73-88`: a map put
    // and a commit, then `AMchangeStartOp == 1`, `AMchangeMaxOp == 1`,
    // `AMchangeSize == 1`).
    const trans = @import("transact.zig");
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = &oracle_actor });

    var t = try trans.Transaction.open(gpa, &doc);
    _ = try t.put(.root, .{ .key = "a" }, .{ .str = "b" });
    var first_result = try t.commitWith(.{ .time = oracle_time });
    defer first_result.deinit(gpa);
    const first = first_result.hash.?;
    t.deinitClosed();

    // The graph's own answer, which is what the *next* transaction starts from:
    // `start_op = max_op + 1` ([`automerge.rs:566-567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expectEqual(@as(u64, 1), doc.graph.maxOp());

    var built = (try doc.getChangeByHash(gpa, first)).?;
    defer built.deinit(gpa);
    try testing.expectEqual(@as(u64, 1), built.change.start_op);
    try testing.expectEqual(@as(u64, 1), built.change.max_op);

    // **The columns say the same thing, and say it as a row count.** This is
    // what `test_AMchangeCompress` asks for (`test/c/abi_coverage.c:182`,
    // `AMchangeSize == 1` after the change has been through the ABI's bytes),
    // because that path has no graph to ask: `AMchange.size` falls back to
    // walking the columns when the change it holds carries no `max_op`
    // (`src/c/doc.zig` §`AMchange.size`), and upstream's fallback is `len()`.
    var block = try changechunk.parseChangeChunk(built.body, gpa);
    defer block.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try block.opCount());
    try testing.expectEqual(built.change.max_op, (try block.change.withOpCount(try block.opCount())).max_op);

    // **Three operations in one change.** Every key is distinct, so every
    // `put` is its own operation, and the change starts above the first one's
    // last op — so the range is 2..=4 and the op count is a number a column
    // count could not accidentally produce.
    var t2 = try trans.Transaction.open(gpa, &doc);
    _ = try t2.put(.root, .{ .key = "k" }, .{ .str = "v" });
    _ = try t2.put(.root, .{ .key = "j" }, .{ .int = 7 });
    _ = try t2.put(.root, .{ .key = "i" }, .{ .uint = 9 });
    var second_result = try t2.commitWith(.{ .time = oracle_time });
    defer second_result.deinit(gpa);
    const second = second_result.hash.?;
    t2.deinitClosed();

    // The second change starts above the first one's last op and ends three
    // counters further on. **A commit that restarted at counter 1 answers `1`
    // to `start_op` here**, which is the collision `OpSet.validateOpOrder`
    // refuses from the second local write on
    // (`start_op = max_op + 1`, [`automerge.rs:566-567`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    try testing.expectEqual(@as(u64, 4), doc.graph.maxOp());
    var built2 = (try doc.getChangeByHash(gpa, second)).?;
    defer built2.deinit(gpa);
    try testing.expectEqual(@as(u64, 2), built2.change.start_op);
    try testing.expectEqual(@as(u64, 4), built2.change.max_op);

    var block2 = try changechunk.parseChangeChunk(built2.body, gpa);
    defer block2.deinit(gpa);
    const rows = try block2.opCount();
    try testing.expectEqual(@as(usize, 3), rows);
    try testing.expectEqual(
        @as(u64, @intCast(rows)),
        built2.change.max_op - built2.change.start_op + 1,
    );

    // **And the last row's own counter is `max_op`**, which is the assertion
    // the range exists for: `max_op` is the counter of the change's last
    // operation, not a number derived from anything else. The op columns are
    // numbered from the change's own actor, and this change names no other
    // actor, so the table has one entry.
    const actors = try gpa.alloc(ActorIdx, 1 + built2.change.other_actors.len);
    defer gpa.free(actors);
    actors[0] = doc.getActorIndex().?;
    for (built2.change.other_actors, 0..) |other, i| {
        actors[i + 1] = try doc.putActorRef(gpa, other);
    }
    const ops = try decodeChangeOps(gpa, built2.change, actors);
    defer freeChangeOps(gpa, ops);
    try testing.expectEqual(built2.change.max_op, @as(u64, ops[ops.len - 1].id().counter));

    // **A change concurrent to that one, applied to a peer that holds this
    // one.** This is the shape of
    // `test_should_handle_changes_concurrrent_to_the_last_sync_heads`
    // (`test/c/suite/ported_wasm/sync_tests.c:1090-1159`): a third document
    // forks, makes a change of its own on its own actor, and hands it to a
    // peer that already holds a different change. Op counters are
    // document-global (`automerge.rs:566-567`), so the fork's first change
    // starts at 1 and its ops sit on the *same* counters as the ones above,
    // on a different actor — which is what makes the two concurrent rather
    // than sequential.
    const fork_actor = @as([15]u8, @splat(0x5c));
    var fork = try Document.init(gpa, std.testing.io);
    defer fork.deinit();
    fork.setActorId(.{ .bytes = &fork_actor });
    var t3 = try trans.Transaction.open(gpa, &fork);
    _ = try t3.put(.root, .{ .key = "n" }, .{ .int = 5 });
    _ = try t3.put(.root, .{ .key = "m" }, .{ .int = 6 });
    var theirs_result = try t3.commitWith(.{ .time = oracle_time });
    defer theirs_result.deinit(gpa);
    const theirs = theirs_result.hash.?;
    t3.deinitClosed();

    // The change a peer is handed by `AMgetLastLocalChange` goes through
    // `getLastLocalChange` — the collector, not the commit path — and it must
    // carry its range too, or the peer has no way to place the rows.
    var theirs_built = (try fork.getLastLocalChange(gpa)).?;
    defer theirs_built.deinit(gpa);
    try testing.expectEqualSlices(u8, &theirs.bytes, &theirs_built.change.hash.bytes);
    try testing.expectEqual(@as(u64, 1), theirs_built.change.start_op);
    try testing.expectEqual(@as(u64, 2), theirs_built.change.max_op);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    // **Both of this document's changes, in order.** The second depends on the
    // first, so a peer handed only the second screens it into the change
    // queue instead of applying it and answers *zero* rows with no error
    // ([`change_queue.rs`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/queue.rs)).
    var landed: usize = 0;
    for ([_]ChangeHash{ first, second }) |want| {
        var one = (try doc.getChangeByHash(gpa, want)).?;
        defer one.deinit(gpa);
        const framed = try one.change.encode(gpa);
        defer gpa.free(framed);
        landed += try peer.loadIncremental(gpa, framed);
    }
    try testing.expectEqual(@as(usize, 4), landed);
    try testing.expectEqual(@as(u64, 4), peer.graph.maxOp());

    const theirs_chunk = try theirs_built.change.encode(gpa);
    defer gpa.free(theirs_chunk);
    try testing.expectEqual(@as(usize, 2), try peer.loadIncremental(gpa, theirs_chunk));

    // **Both heads are there and the peer's `max_op` did not move**: the
    // fork's ops landed on counters the peer's own change already used, on a
    // different actor, which is exactly what "concurrent" means here.
    const peer_heads = try peer.getHeads(gpa);
    defer gpa.free(peer_heads);
    try testing.expectEqual(@as(usize, 2), peer_heads.len);
    try testing.expectEqual(@as(u64, 4), peer.graph.maxOp());
    try testing.expect(peer_heads[0].eql(second) or peer_heads[1].eql(second));
    try testing.expect(peer_heads[0].eql(theirs) or peer_heads[1].eql(theirs));
}

test "a document that applied a peer's changes rebuilds them by hash" {
    // **The other end of the sync path, and the end that had no test.** The
    // test above hands out a change with one op in it, which is the one shape
    // that never touches the collector's predecessor table at all. This one
    // starts from [`buildSample`], whose changes overwrite a map key, delete a
    // list element and mark text: a peer's change applied through
    // `loadIncremental` puts those rows into the op set, and the document then
    // has to rebuild the change back out of them — which is what
    // [`Document.getChangeByHash`] does and what `sync.generateSyncMessage`
    // does on every message it answers.
    //
    // The rebuild walks the whole op set, not only the rows of the change it
    // was asked for, and it reverses successor edges as it goes. That
    // reversal used to hold the predecessor lists in an array and their
    // positions in a hash map beside it, and taking a list removed it with
    // `orderedRemove` — which renumbers every entry behind the one removed
    // while the map keeps handing out the old positions. The next take for any
    // id past the removal read one past the end of the array:
    // `index out of bounds: index 1, len 1`, on a document that had applied a
    // peer's changes.
    const gpa = testing.allocator;
    var sender = try buildSample(gpa);
    defer sender.deinit();

    var changes = try sender.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), changes.items.items.len);

    var receiver = try Document.init(gpa, std.testing.io);
    defer receiver.deinit();
    var rows: usize = 0;
    for (changes.items.items) |*sent| {
        const chunk = try sent.change.encode(gpa);
        defer gpa.free(chunk);
        rows += try receiver.loadIncremental(gpa, chunk);
    }
    // Every row the sender had arrived, so a change that was queued instead of
    // applied cannot pass for a peer that is in step.
    try testing.expectEqual(sender.ops.len(), rows);
    try sender.debugCmp(&receiver);

    // **The rebuilt bytes are the bytes that were sent.** A predecessor list
    // that names the wrong op does not fail anywhere in this function: it
    // changes a counter inside the encoding, so the change still rebuilds and
    // the document still reads back the same. The only thing that notices is
    // the hash, which is why the hash is asserted first.
    for (changes.items.items) |*sent| {
        var rebuilt = (try receiver.getChangeByHash(gpa, sent.change.hash)).?;
        defer rebuilt.deinit(gpa);
        try testing.expectEqualSlices(u8, &sent.change.hash.bytes, &rebuilt.change.hash.bytes);
        try testing.expectEqualSlices(u8, sent.change.bytes, rebuilt.change.bytes);
    }
}

test "a change that overwrites two ops is rebuilt with both predecessor lists" {
    // **The exact document that broke the collector**, and the smallest one
    // that does: four writes to one map key, the third overwriting the first
    // and the fourth overwriting the second. The walk records a predecessor
    // when it reaches the op that has one and claims it when it reaches the op
    // it belongs to, and with two independent chains those two moments
    // interleave — which is the shape the predecessor table never handled.
    //
    // The table held its lists in an array and their positions in a hash map
    // beside it, and taking a list removed it with `orderedRemove`, which
    // renumbers every entry behind the one removed while the map keeps handing
    // out the old positions. Rebuilding this change panicked with
    // `index out of bounds: index 1, len 1` — from `Document.getChangeByHash`,
    // which is what `sync.generateSyncMessage` calls on every message it
    // answers. The table is a map of lists now, so there is no position to
    // fall out of step.
    //
    // The document is built here and the change is handed to a second one as a
    // peer would hand it, because that is the route the panic came in on: rows
    // that arrived through `loadIncremental` rather than rows a local commit
    // wrote.
    const gpa = testing.allocator;
    const o1 = OpId.init(1, 0);
    const o2 = OpId.init(2, 0);
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .str = "v1" } },
        .{ .ctr = 2, .key = KeyRef.fromStr("k"), .value = .{ .str = "v2" } },
        .{ .ctr = 3, .key = KeyRef.fromStr("k"), .value = .{ .str = "v3" }, .pred = &.{o1} },
        .{ .ctr = 4, .key = KeyRef.fromStr("k"), .value = .{ .str = "v4" }, .pred = &.{o2} },
    };

    var sender = try Document.init(gpa, std.testing.io);
    defer sender.deinit();
    const a = try sender.putActorRef(gpa, .{ .bytes = actor_a });
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    const hash = try applyHandChange(&sender, gpa, actor_a, 1, 1, &.{}, null, ops);

    var sent = (try sender.getChangeByHash(gpa, hash)).?;
    defer sent.deinit(gpa);
    const chunk = try sent.change.encode(gpa);
    defer gpa.free(chunk);

    var peer = try Document.init(gpa, std.testing.io);
    defer peer.deinit();
    try testing.expectEqual(@as(usize, specs.len), try peer.loadIncremental(gpa, chunk));

    // **Two predecessors, in the order the ops that carry them declare them.**
    // A list that names the wrong op does not fail here — it changes a counter
    // inside the encoding — so the bytes are what says it.
    var rebuilt = (try peer.getChangeByHash(gpa, hash)).?;
    defer rebuilt.deinit(gpa);
    try testing.expectEqualSlices(u8, &hash.bytes, &rebuilt.change.hash.bytes);
    try testing.expectEqualSlices(u8, sent.change.bytes, rebuilt.change.bytes);
    try peer.debugCmp(&sender);
}

test "this port's write path produces the reference's own change chunks, byte for byte" {
    // **The compatibility contract as an equality of bytes.** The two chunks
    // below are the ones `tools/oracle`'s `change` subcommand recorded in
    // `test/golden/change.jsonl`, and the operations that produced them are the
    // ones [`buildOracleDocument`] replays through this port's own
    // transactions. Same actor, same messages, same timestamp, same
    // twenty-five op counters — so the encoding is the only thing left that
    // could differ, and the encoding is what the hash covers.
    //
    // The two vectors above ask the opposite question and are kept for it: a
    // change the *reference* wrote re-encodes to the reference's own bytes, and
    // the reference's own document comes back with the reference's hashes.
    // This one asks whether the port can *write* what the reference writes,
    // which is the direction every peer and every saved file sees.
    const gpa = testing.allocator;
    var doc = try buildOracleDocument(gpa);
    defer doc.deinit();

    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), changes.len());

    // **The bytes first**, because a byte-level failure names the encoder and a
    // hash-level failure does not. `reference_change_0` is a compressed chunk
    // and `reference_change_1` a plain one, so this also covers the framing a
    // peer sends and the checksum over the inflated body.
    const framed_hex = [_][]const u8{ reference_change_0, reference_change_1 };
    for (changes.items.items, framed_hex) |*built, hex| {
        const framed = try err.hexFrom(gpa, hex);
        defer gpa.free(framed);
        const chunk = try chunkmod.parseChunk(framed);
        var owned = try changechunk.parseFramedChunk(chunk, gpa);
        defer owned.deinit(gpa);
        testing.expectEqualSlices(u8, owned.parsed.change.bytes, built.body) catch |e| {
            std.debug.print(
                "doc: a change built here encodes to {d} bytes, the reference's is {d}\n",
                .{ built.body.len, owned.parsed.change.bytes.len },
            );
            return e;
        };
    }

    // **And the hashes**, spelled out rather than inferred from the bytes: a
    // reader who wants to know *which* change moved can see it without running
    // the byte comparison above.
    const expected = [_][]const u8{ reference_change_0_hash, reference_change_1_hash };
    for (changes.items.items, expected) |*built, want| {
        const got = try std.fmt.allocPrint(gpa, "{x}", .{&built.change.hash.bytes});
        defer gpa.free(got);
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print(
                "doc: a change built here hashes to {s}, the reference computed {s}\n",
                .{ got, want },
            );
            return e;
        };
    }
}

/// Every string the walk finds in the register `key` of `obj`, appended to
/// `out`.
///
/// The strings borrow document storage. Read them before the next document mutation.
fn collectRegister(
    gpa: Allocator,
    out: *std.ArrayList([]const u8),
    doc: *Document,
    obj: ExId,
    key: KeyRef,
) !void {
    const internal_obj = doc.ops.resolveObjId(obj) orelse return error.InvalidObjId;
    var walk = try doc.ops.iter();
    while (try walk.next()) |op| {
        if (!op.objId().eql(internal_obj)) continue;
        if (!op.elemidOrKey().eql(key)) continue;
        switch (op.value()) {
            .str => |s| try out.append(gpa, s),
            else => {},
        }
    }
}

test "two writers who edited one object load, and the conflict comes back whole" {
    // **The shape upstream's `save_restore_complex1` has**
    // ([`test.rs`:1605-1639](../../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // and the one no test here had: two authors writing into **one object**,
    // neither op naming a predecessor, so the register is a conflict rather
    // than a history, and the document also carries the empty merge commit
    // that joining them produces.
    //
    // A document of this shape is what the collector used to refuse.
    // `save and restore a complex document` in `test/upstream_doc_test.zig:2187`
    // failed at `place`'s second-op-for-one-counter guard
    // ([`VecEncoder::add`, collector.rs:298-301](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs)),
    // and **the guard was right**: upstream asserts there too, and the
    // reference loads the document. What was wrong was the *document* — a local
    // `put` on an absent key spliced the register's row in at the end of the
    // object's rows instead of the register's sorted place, so a locally built
    // document held its map registers in write order. Two writes to `title` and
    // `done` in that order put counter 3 after counter 4, the rebuilt document's
    // rows stopped being the rows the changes described, and the collector
    // refused what it could not honestly rebuild. The fix is upstream
    // `key_str.scope_to_value`
    // ([`tests.rs`:3464-3476](../../github-automerge-automerge/rust/automerge/crates/hexane/src/tests.rs));
    // the guard is untouched, and this test is here so that a document of this
    // shape can never reach it again.
    //
    // **The document is built through transactions, not through
    // [`applySpec`].** A change's counter range starts one past the
    // **document's** highest op, not the author's own
    // ([`automerge.rs`:566-567](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and that is what lets a chunk recover a change's `start_op` from its
    // dependencies' `max_op`
    // ([`ChangeIter::next`, change_graph.rs:1669](../../github-automerge-automerge/rust/automerge/src/change_graph.rs),
    // over the count `ChangeGraphCols::load` derives at `:1010-1013`). A
    // hand-built change that gives a second author `start_op = 1` while the
    // document's highest op is already 1 breaks that derivation, and **the
    // reference cannot rebuild such a document either** — so a test that built
    // one would be asserting that a document nothing can load does load. The
    // transactions give every change the range the format requires.
    const trans = @import("transact.zig");
    const gpa = testing.allocator;

    var a = try Document.init(gpa, std.testing.io);
    defer a.deinit();
    a.setActorId(.{ .bytes = actor_a });
    const m = blk: {
        var t = try trans.Transaction.open(gpa, &a);
        defer t.deinit() catch @panic("testing allocator cannot refuse rollback");
        const made = try t.putObject(.root, .{ .key = "m" }, .map);
        var committed = try t.commit();
        defer committed.deinit(gpa);
        break :blk made;
    };

    var b = try Document.init(gpa, std.testing.io);
    defer b.deinit();
    b.setActorId(.{ .bytes = actor_b });
    {
        const heads = try b.merge(gpa, &a);
        gpa.free(heads);
    }
    // **Neither write sees the other**, so the key ends up with two values and
    // the walk that rebuilds the changes has to place both.
    {
        var t = try trans.Transaction.open(gpa, &b);
        defer t.deinit() catch @panic("testing allocator cannot refuse rollback");
        _ = try t.put(m, .{ .key = "k" }, .{ .str = "from b" });
        var committed = try t.commit();
        defer committed.deinit(gpa);
    }
    {
        var t = try trans.Transaction.open(gpa, &a);
        defer t.deinit() catch @panic("testing allocator cannot refuse rollback");
        _ = try t.put(m, .{ .key = "k" }, .{ .str = "from a" });
        var committed = try t.commit();
        defer committed.deinit(gpa);
    }
    {
        const heads = try a.merge(gpa, &b);
        gpa.free(heads);
    }

    const heads_before = try a.getHeads(gpa);
    defer gpa.free(heads_before);
    const saved = try a.save(gpa);
    defer gpa.free(saved);

    var loaded = try Document.load(gpa, std.testing.io, saved, defaultTextEncoding());
    defer loaded.deinit();

    // **The conflict, and both of its values.** The load rebuilt every change
    // out of the rows, and this is what the rebuild has to reproduce.
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(gpa);
    try collectRegister(gpa, &got, &loaded, m, KeyRef.fromStr("k"));
    try testing.expectEqual(@as(usize, 2), got.items.len);
    // **Either order.** The walk emits `(obj, key, id)` and an id orders by
    // counter, so this pair happens to be fixed — but nothing in the format
    // promises it, and a test leaning on the sort would be testing the sort.
    try testing.expect((std.mem.eql(u8, got.items[0], "from a") and
        std.mem.eql(u8, got.items[1], "from b")) or
        (std.mem.eql(u8, got.items[0], "from b") and
            std.mem.eql(u8, got.items[1], "from a")));

    // **And the hashes the load derived are the ones the save recorded.** The
    // collector encodes each change from the rows and hashes the result, so
    // equal heads over different rows is the failure this shape had.
    const heads_after = try loaded.getHeads(gpa);
    defer gpa.free(heads_after);
    try testing.expectEqualSlices(ChangeHash, heads_before, heads_after);
    try a.debugCmp(&loaded);
}

test "snapshot physical map order is refused despite unchanged history heads" {
    // The public before probe accepted b@2,a@1 with the original change hash,
    // but binary lookup missed b. Permute complete rows with the real column
    // exporter; framing, graph columns, actor identities and heads stay valid.
    const gpa = testing.allocator;
    const Tx = @import("transact.zig").Transaction;
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = "snapshot-physical-order" });
    var tx = try Tx.open(gpa, &source);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "a" }, .{ .int = 1 });
    _ = try tx.put(.root, .{ .key = "b" }, .{ .int = 2 });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    const expected_head = committed.hash orelse return error.TestUnexpectedResult;
    const valid = try source.saveWithOptions(gpa, .{ .deflate = false });
    defer gpa.free(valid);

    const reversed = blk: {
        var walk = try source.ops.iter();
        const a = (try walk.next()) orelse return error.TestUnexpectedResult;
        const b = (try walk.next()) orelse return error.TestUnexpectedResult;
        try testing.expect((try walk.next()) == null);
        try testing.expectEqualStrings("a", a.keyStr().?);
        try testing.expectEqualStrings("b", b.keyStr().?);
        try testing.expectEqual(@as(u32, 1), a.id().counter);
        try testing.expectEqual(@as(u32, 2), b.id().counter);
        try testing.expectEqual(@as(usize, 0), a.succCount());
        try testing.expectEqual(@as(usize, 0), b.succCount());
        break :blk [_]opmod.Op{ b, a };
    };
    // This raw construction deliberately violates only the ordered-row
    // precondition, to produce hostile input rather than exercise a producer.
    var reordered = try opsetmod.OpSet(opmod.Op).fromDocOps(
        gpa,
        source.ops.actors.items,
        &reversed,
        source.textEncoding(),
        source.strings.table(),
    );
    defer reordered.deinit();
    var exported = try reordered.exportColumns(gpa);
    defer exported.deinit(gpa);
    var stream = chunkmod.ChunkStream.init(valid);
    var parsed = try docchunk.parseFramedChunk((try stream.next()).?, gpa);
    defer parsed.deinit(gpa);
    var block = parsed.block;
    block.ops = exported.cols;
    const malformed = try docchunk.encode(gpa, block, .none);
    defer gpa.free(malformed);

    try snapshotPhysicalOrderRefusal(gpa, valid, malformed, expected_head);
    try testing.checkAllAllocationFailures(
        gpa,
        snapshotPhysicalOrderRefusal,
        .{ valid, malformed, expected_head },
    );
}

fn snapshotPhysicalOrderRefusal(
    gpa: Allocator,
    valid: []const u8,
    malformed: []const u8,
    expected_head: ChangeHash,
) !void {
    const readonly = @import("read.zig");
    var control = try Document.load(gpa, testing.io, valid, defaultTextEncoding());
    defer control.deinit();
    try testing.expectEqual(@as(i64, 1), (try readonly.get(&control, .root, .{ .key = "a" })).?.value.scalar.int);
    try testing.expectEqual(@as(i64, 2), (try readonly.get(&control, .root, .{ .key = "b" })).?.value.scalar.int);
    const heads = try control.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqualSlices(ChangeHash, &.{expected_head}, heads);
    const saved = try control.saveWithOptions(gpa, .{ .deflate = false });
    defer gpa.free(saved);
    try testing.expectEqualSlices(u8, valid, saved);

    // Recovery relaxes marks only; it cannot expose unordered map columns.
    for ([_]opsetmod.MarkOrderValidation{ .check, .allow_invalid }) |validation| {
        if (Document.loadConfigured(gpa, testing.io, malformed, .{}, validation, null)) |owner| {
            var unexpected = owner;
            defer unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |failure| {
            if (failure != error.InvalidValue) return failure;
        }
    }
    if (Document.loadUnverifiedHeads(gpa, testing.io, malformed, .{})) |owner| {
        var unexpected = owner;
        defer unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |failure| {
        if (failure != error.InvalidValue) return failure;
    }
    if (Document.rescue(gpa, testing.io, malformed)) |owner| {
        var unexpected = owner;
        defer unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |failure| {
        if (failure != error.InvalidValue) return failure;
    }

    var stream = chunkmod.ChunkStream.init(malformed);
    var parsed = try docchunk.parseFramedChunk((try stream.next()).?, gpa);
    defer parsed.deinit(gpa);
    var strings = Strings.init(gpa);
    defer strings.deinit();
    for ([_]opsetmod.MarkOrderValidation{ .check, .allow_invalid }) |validation| {
        if (Set.loadWithMarkValidation(
            gpa,
            parsed.opColumns(),
            control.ops.actors.items,
            control.textEncoding(),
            strings.table(),
            validation,
        )) |owner| {
            var unexpected = owner;
            defer unexpected.deinit();
            return error.TestUnexpectedResult;
        } else |failure| {
            if (failure != error.InvalidValue) return failure;
        }
    }
}

test "a load the collector refuses releases every row it had read" {
    // **The leak, on the path that reached it.** `readDocChunk` builds a
    // `Reconstructed` — the op set, the actor table, the change block and the
    // collector's metadata — and then runs the one step that can refuse the
    // document. Before the `errdefer` on that line, a refusal abandoned the
    // whole of it, and `std.testing.allocator` aborted the run on the leak
    // rather than letting the next test report anything at all. The trace it
    // printed named the op columns' own allocation sites — `Ops.load` →
    // `loadFilled`/`loadInterned` → `hexane.Column.load` → `Slab.splice` —
    // which is where those blocks were born, not where they were lost.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    _ = try applySpec(&doc, gpa, actor_a, 1, 1, &.{}, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("m"), .action = .make_map },
    });

    // **One counter the rows do not have.** A document chunk stores a change's
    // `max_op` and not its `start_op`
    // ([`ChangeGraphCols::load`, change_graph.rs:986-1014](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    // so raising `max_op` writes a document that claims counters 1 and 2 while
    // holding counter 1 alone. `checkCoverage` refuses it, which is upstream's
    // `Error::MissingOps`
    // ([`VecEncoder::finish`, collector.rs:308-312](../../github-automerge-automerge/rust/automerge/src/op_set2/change/collector.rs))
    // under a name this port can answer with: the range comes from a stored
    // `max_op` here and from the rows there, and the two can disagree.
    doc.graph.nodes.items[0].meta.max_op += 1;

    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    try testing.expectError(error.Fail, Document.load(gpa, std.testing.io, saved, defaultTextEncoding()));
    // **The rest of the assertion is the allocator.** Every block the load
    // allocated is freed before the error leaves `readDocChunk`; if one is not,
    // this test fails here rather than aborting a run forty tests later.
}

/// The offset of a column's slab inside the chunk body it borrows from, which
/// is the number a byte mutation has to be applied at.
///
/// **Two levels, because a column's bytes sit in its own block.** A `RawColumns`
/// indexes the data block that holds its columns, and that block is a window
/// inside the chunk body rather than the body itself — so the slab's offset is
/// measured from the block and the block's from the body, and the sum is the
/// one the mutation uses.
fn slabOffsetInBody(body: []const u8, block: []const u8, slab: []const u8) usize {
    const at_block: usize = @intCast(@intFromPtr(block.ptr) - @intFromPtr(body.ptr));
    const in_block: usize = @intCast(@intFromPtr(slab.ptr) - @intFromPtr(block.ptr));
    return at_block + in_block;
}

test "a change whose predecessor counter is negative is refused, not wrapped" {
    // **The crash, and the shape that reached it.** A predecessor counter is a
    // `.delta` cell, so it arrives as a plain `i64` that no earlier step
    // narrows. Upstream refuses a negative one by name —
    // `invalid_value("counter", "negative value for counter")`
    // ([`column_range/opid_list.rs:210-218`](../../github-automerge-automerge/rust/automerge/src/columnar/column_range/opid_list.rs))
    // — and this port answered `@intCast(@mod(ctr, maxInt(i64)))` instead,
    // which turned the negative into a large positive and then aborted the
    // process inside `@intCast`. The refusal has to be a refusal: an
    // `error.InvalidValue` a caller can read is what the wire means.
    //
    // **No public writer can produce the input, and that is the point.**
    // `encodeChangeOps` writes `.{ .int = @intCast(p.counter) }` from a `u32`,
    // so every counter this port writes is in `0..=u32::MAX`. The bytes below
    // are therefore a real change a real writer produced, with one byte of one
    // column's payload replaced by the one-byte negative — the same mutation
    // `storage/totality_test.zig` makes over its crashers, and re-framed
    // through [`chunkmod.writeChunk`] so the checksum accepts it and the
    // refusal is the reader's rather than the framing's
    // ([`chunk.rs:300-312`](../../github-automerge-automerge/rust/automerge/src/storage/chunk.rs)).
    const gpa = testing.allocator;
    const o1 = OpId.init(1, 0);
    const specs = [_]OpSpec{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .str = "v1" } },
        .{ .ctr = 2, .key = KeyRef.fromStr("k"), .value = .{ .str = "v2" } },
        .{ .ctr = 3, .key = KeyRef.fromStr("k"), .value = .{ .str = "v3" }, .pred = &.{o1} },
    };
    var sender = try Document.init(gpa, std.testing.io);
    defer sender.deinit();
    const a = try sender.putActorRef(gpa, .{ .bytes = actor_a });
    const ops = try buildOps(gpa, a, &specs);
    defer freeChangeOps(gpa, ops);
    const hash = try applyHandChange(&sender, gpa, actor_a, 1, 1, &.{}, null, ops);

    var sent = (try sender.getChangeByHash(gpa, hash)).?;
    defer sent.deinit(gpa);
    const framed = try sent.change.encode(gpa);
    defer gpa.free(framed);

    // **The control, first.** The change as the writer produced it loads, so
    // every refusal below is the mutation's doing and not the fixture's.
    {
        var peer = try Document.init(gpa, std.testing.io);
        defer peer.deinit();
        try testing.expectEqual(@as(usize, specs.len), try peer.loadIncremental(gpa, framed));
    }

    const chunk = try chunkmod.parseChunk(framed);
    var block = try changechunk.parseChangeChunk(chunk.data, gpa);
    defer block.deinit(gpa);
    const slab = (try block.bytesFor(OpColumn.pred_counter.spec())) orelse
        return error.TestUnexpectedResult;
    try testing.expect(slab.len > 0);
    const at = slabOffsetInBody(chunk.data, block.ops.data, slab);

    var body = try gpa.dupe(u8, chunk.data);
    defer gpa.free(body);
    var mutated: std.ArrayList(u8) = .empty;
    defer mutated.deinit(gpa);

    // **Every byte of the slab, one at a time.** The slab's run header and its
    // payload are not told apart here: whichever byte carries the counter is
    // found by the refusal it produces, and `found` below says one was. That
    // keeps the test off the slab's private layout while still pinning the
    // behaviour — a negative predecessor counter is refused, and refused by
    // the load rather than by a panic.
    var found = false;
    for (0..slab.len) |k| {
        const idx = at + k;
        const original = body[idx];
        defer body[idx] = original;
        // `0x7f` is the one-byte sleb128 for -1.
        body[idx] = 0x7f;
        mutated.clearRetainingCapacity();
        try chunkmod.writeChunk(&mutated, gpa, .change, body);
        var peer = try Document.init(gpa, std.testing.io);
        defer peer.deinit();
        if (peer.loadIncremental(gpa, mutated.items)) |applied| {
            std.debug.print("doc: byte {d} of the predecessor counter applied {d} ops\n", .{ k, applied });
            continue;
        } else |e| switch (e) {
            error.InvalidValue => found = true,
            else => {},
        }
    }
    try testing.expect(found);
    // **The rest of the assertion is the allocator.** The refusal happens after
    // `gpa.alloc` has already handed out the ops array and the predecessor
    // list, so if either were abandoned the run would abort here rather than
    // letting the next test report anything at all.
}

/// Three changes in a chain, each overwriting the last through the same key.
///
/// **The shape is the point: node 0 has no dependency and nodes 1 and 2 have
/// one each.** A node's `deps` is a separate allocation per row in
/// [`decodeGraphCols`], and a zero-length one is nothing an allocator tracks —
/// so a refusal on row 1 abandons an array no test could see, and only a
/// refusal on row 2 can prove that the rows read so far were given back.
fn chainedOverwrites(gpa: Allocator, doc: *Document) !void {
    const a = try doc.putActorRef(gpa, .{ .bytes = actor_a });

    const first = try buildOps(gpa, a, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("k"), .value = .{ .int = 1 } },
    });
    defer freeChangeOps(gpa, first);
    const h0 = try applyHandChange(doc, gpa, actor_a, 1, 1, &.{}, null, first);

    const second = try buildOps(gpa, a, &.{
        .{ .ctr = 2, .key = KeyRef.fromStr("k"), .value = .{ .int = 2 }, .pred = &.{OpId.init(1, 0)} },
    });
    defer freeChangeOps(gpa, second);
    const h1 = try applyHandChange(doc, gpa, actor_a, 2, 2, &.{h0}, null, second);

    const third = try buildOps(gpa, a, &.{
        .{ .ctr = 3, .key = KeyRef.fromStr("k"), .value = .{ .int = 3 }, .pred = &.{OpId.init(2, 0)} },
    });
    defer freeChangeOps(gpa, third);
    _ = try applyHandChange(doc, gpa, actor_a, 3, 3, &.{h1}, null, third);
}

test "a graph decode refused on a later row releases the rows it had read" {
    // **The leak, on the path that reached it.** `decodeGraphCols` gives each
    // row its own `deps` allocation, and the per-row `errdefer` only ever owned
    // the current one: a refusal from row `i` gave back `deps[i]` and abandoned
    // `deps[0..i-1]`. Row 0's is zero-length and nothing, so the fixture above —
    // one change, as the refusal test beside this one uses — could not see it.
    // Three chained changes can.
    //
    // **The corruption is in the dependency-index column, and it is that
    // column because no other one can be made to refuse at a chosen row.** Every
    // graph column this port writes is non-negative by construction (`seq` and
    // `max_op` go through `std.math.cast(i64, …)`, `time` is the change's own,
    // and the dependency indices are node indices), so no in-memory mutation
    // makes the *saved* document refuse at row 2 at all. The bytes below are a
    // real saved document with one byte of one `.delta` column replaced,
    // re-framed so the checksum accepts it.
    //
    // **`deps_value` and not `seq`.** `seq` is the column one would reach for,
    // and it cannot be used: three changes by one actor have sequence numbers
    // 1, 2 and 3, so its three deltas are all 1 and the codec writes them as
    // one repeat run — there is no per-change byte to turn, and every offset
    // in that slab fails on row 0, before any `deps` array exists. The
    // dependency indices are 0 and 1, whose deltas are 0 and 1 and therefore
    // distinct: one payload byte each, belonging to rows 1 and 2 respectively.
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    try chainedOverwrites(gpa, &doc);

    // **Uncompressed**, so the saved chunk's body is the body the columns index
    // and the offset arithmetic below is arithmetic on it rather than on a
    // DEFLATE stream.
    const saved = try doc.saveWithOptions(gpa, .{ .deflate = false, .retain_orphans = true });
    defer gpa.free(saved);

    // **The control, first.** The document as saved loads and holds all three
    // changes, so every refusal below is the mutation's doing.
    {
        var peer = try Document.init(gpa, std.testing.io);
        defer peer.deinit();
        try testing.expectEqual(@as(usize, 3), try peer.loadIncremental(gpa, saved));
        try testing.expectEqual(@as(usize, 3), peer.graph.len());
    }

    const chunk = try chunkmod.parseChunk(saved);
    var parsed = try docchunk.parseFramedChunk(chunk, gpa);
    defer parsed.deinit(gpa);
    const deps_value = (try parsed.block.changes.bytesFor(GraphColumn.depsValueSpec())) orelse
        return error.TestUnexpectedResult;
    try testing.expect(deps_value.len > 0);
    const at = slabOffsetInBody(chunk.data, parsed.block.changes.data, deps_value);

    var body = try gpa.dupe(u8, chunk.data);
    defer gpa.free(body);
    var mutated: std.ArrayList(u8) = .empty;
    defer mutated.deinit(gpa);

    // **Every byte of the dependency-index column, and every refusal checked.**
    // One byte turned negative is one change's dependency index going negative,
    // and `graphNode` refuses that (`doc.zig:1654-1659`) at whichever row owns
    // the cell. The byte belonging to the **last** change is the one that
    // abandons a row with a real `deps` array behind it — the second change's —
    // and the sweep is what reaches it without the test knowing which byte that
    // is. The sweep does not stop at the first refusal, because the byte
    // belonging to the first change also refuses and proves nothing.
    var refused = false;
    for (0..deps_value.len) |k| {
        const idx = at + k;
        const original = body[idx];
        defer body[idx] = original;
        // `0x40` is the one-byte sleb128 for -64: the cell realizes negative
        // whatever came before it, so the sweep does not have to know how many
        // deltas precede this one.
        body[idx] = 0x40;
        mutated.clearRetainingCapacity();
        try chunkmod.writeChunk(&mutated, gpa, .document, body);
        var peer = try Document.init(gpa, std.testing.io);
        defer peer.deinit();
        if (peer.loadIncremental(gpa, mutated.items)) |applied| {
            std.debug.print("doc: byte {d} of the dependency index applied {d} ops\n", .{ k, applied });
            continue;
        } else |e| switch (e) {
            error.InvalidValue => refused = true,
            else => {},
        }
        // **The assertion is the one the fix is about.** Nothing here says
        // which error is right; it says that whichever one this byte produced,
        // every allocation the decode had already made is back with the
        // allocator. Before the fix the byte landing on the third change left
        // the second change's `deps` behind and `std.testing.allocator`
        // aborted the run here.
    }
    try testing.expect(refused);
}

test "an incremental load into an empty document re-establishes that document's actor" {
    // **The actor's bytes go in the document's own arena, because that is what
    // the C ABI does and what the defect needed.** `AMcreate` interns the
    // caller's bytes into that arena and hands the document a *borrowed*
    // slice ([`c.doc.internActor`](../c/doc.zig)); the load frees the arena, so
    // a document whose actor was set that way read its actor back out of freed
    // memory — and the peer actor the load interned next had taken those very
    // bytes. Every other actor in this tree's tests is a string literal
    // ([`actor_a`]; `sync/protocol.zig:1122`, `sync/v1.zig:822`), which never
    // dies, which is why the library gate stayed green and the C gate did not:
    // a document created with actor `89abcdef` reported `01234567` as its own
    // and then minted its next change under it.
    //
    // Upstream re-establishes the actor **by value, resolved against the
    // loaded document's actor table**: `doc = doc.with_actor(self.actor_id().clone())`
    // ([`automerge.rs:1040`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    // and `set_actor` caches the index when the table holds the actor and keeps
    // the bytes when it does not
    // ([`:359-366`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    // **Both halves are asserted below, because both are the fix**: carrying
    // the borrowed slice across the reset is wrong, and so is carrying an index
    // into the table the reset replaced.
    const gpa = testing.allocator;
    var source = try Document.init(gpa, std.testing.io);
    defer source.deinit();
    _ = try applySpec(&source, gpa, actor_a, 1, 1, &.{}, &.{
        .{ .ctr = 1, .key = KeyRef.fromStr("x"), .value = .{ .str = "one" } },
    });
    const saved = try source.save(gpa);
    defer gpa.free(saved);

    // An actor the loaded document does **not** have: the bytes, and no index.
    var doc = try Document.init(gpa, std.testing.io);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = doc.arena.allocator().dupe(u8, "fedcba9876543210") catch unreachable });
    _ = try doc.loadIncremental(gpa, saved);
    try testing.expectEqualStrings("fedcba9876543210", doc.getActorId().bytes);
    try testing.expectEqual(@as(?ActorIdx, null), doc.getActorIndex());

    // An actor it **does** have: the same actor, and an index that names it.
    var same = try Document.init(gpa, std.testing.io);
    defer same.deinit();
    same.setActorId(.{ .bytes = same.arena.allocator().dupe(u8, actor_a) catch unreachable });
    _ = try same.loadIncremental(gpa, saved);
    try testing.expectEqualStrings(actor_a, same.getActorId().bytes);
    try testing.expectEqual(@as(?ActorIdx, 0), same.getActorIndex());
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`saveIncremental` had no cursor, and a cursor is a set of change hashes
//   — not a byte offset and not a change index.** It answered
//   `saveAfter(gpa, self.graph.getHeads())`, which is a base meaning
//   "everything is already delivered", so it returned **zero bytes on every
//   call** and `AMsaveIncremental` with it. Upstream keeps
//   `save_cursor: Vec<ChangeHash>` (`autocommit.rs:70`), fills it with
//   `self.doc.get_heads()` (`:539`, `:594`) and hands it straight to
//   `save_after(&self.save_cursor)` (`:592`), where `save_after` is
//   `get_changes(have_deps)` (`automerge.rs:1194-1195`, `:1512-1514`): the
//   changes *not reachable* from those hashes, written as bare change chunks.
//   **An empty cursor therefore means "everything owed", not "nothing owed"** —
//   which is the whole defect, and it is why the change index and the byte
//   offset were both wrong: neither is what upstream stores.
//
//   The field is [`Document.save_cursor`], and both of the updates are guarded
//   on a non-empty answer, because upstream's are (`:538`, `:593`): an
//   unguarded advance would mark changes as delivered to a caller that never
//   received them. [`Document.saveWithOptions`] is now
//   `AutoCommit::save_with_options` (`:534-542`) over a new private
//   [`Document.saveChunk`], which is `Automerge::save_with_options`
//   (`automerge.rs:1149-1161`) and is what [`Document.clone`] calls — a clone
//   is `#[derive(Clone)]` on `Automerge` (`:248`), a type that has no cursor,
//   so a clone that saved through the wrapper would have moved the *source's*.
// * **[`defaultTextEncoding`] is the *crate's* default and stays
//   `.unicode_code_point`; the *C ABI's* default is UTF-8 code units and lives
//   in [`c.doc.cTextEncoding`](../c/doc.zig).** Upstream's answer is a cargo
//   feature, not a constant: `TextEncoding::platform_default()`
//   ([`text_value.rs:12-22`](../../github-automerge-automerge/rust/automerge/src/text_value.rs))
//   answers `Utf8CodeUnit` under `utf8-indexing`, `Utf16CodeUnit` under
//   `utf16-indexing`, and `UnicodeCodePoint` with **neither** (`:11`, `:19`).
//   This port has no features, so one build configuration became a choice —
//   and **two different consumers want two different answers.** A
//   default-configured `cargo build` of the crate enables neither feature, so
//   the crate default is `UnicodeCodePoint` and this function keeps it.
//   `rust/automerge-c` is a *different build of that same crate*:
//   `CMakeLists.txt:45` declares `UTF32_INDEXING` without setting it, so
//   `:111-117` passes `-F automerge/utf8-indexing`, and the C binding indexes
//   in bytes. Making this function answer UTF-8 would have fixed the C
//   binding by moving the **library's** default away from a default-configured
//   build of the **library** — the same class of mistake one layer up, and it
//   would have moved the text unit of every non-C document too. The port's own
//   23 ported text tests ([read.zig](../read.zig):2571-2578) are indifferent
//   to the choice — every one of them loops over all four encodings and builds
//   its fixture with `initWithEncoding` — so nothing here was hiding behind
//   them.
//
//   **This function's own doc comment asserted the opposite for a while**,
//   claiming `.unicode_code_point` was "upstream's default under the
//   `utf8-indexing` feature", which inverts `text_value.rs:14-15`. The
//   symptom was invisible until a C caller indexed a text object and named
//   the wrong character: `test/c/suite/doc_tests.c:278` and
//   `mark_tests.c:80`, `:109` are what caught it. **The comment was the
//   bug's only evidence in the tree and it pointed the wrong way.**
//
// Raw Document.commit only encodes and publishes history. The transaction owns
// eager operation events and returns the sole branch log on commit; AutoCommit
// merges that log (`autocommit.rs:728-739`). No final-diff replay engine remains.
//
// * **`loadIncremental` refuses a save that forks the document, and that is
//   upstream's answer and not a port decision.** The screen is `has_actor_seq`
//   ([`automerge.rs:1089-1091`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   reached from `BatchApply::new` before a change reaches the graph
//   ([`batch.rs:1073-1076`](../../github-automerge-automerge/rust/automerge/src/op_set2/change/batch.rs)),
//   and two *different* changes claiming one `(actor, seq)` slot is what it
//   names. Measured rather than reasoned about: the oracle's `loadinc`
//   subcommand loads a save into a document that **descends** from it (answer
//   `ok`, one row added), one that **forks** it at the same `(actor, seq)`
//   (answer `err`, `duplicate seq 1 found for actor a1a1…`), and one the
//   document already holds (answer `ok`, zero rows added). **A document built
//   by applying changes incrementally is not a document that can accept every
//   save**, and the one it cannot accept is the one that contradicts its own
//   history — which is what the port's own `DuplicateSeqNumber` test
//   (`a change that repeats a sequence number is refused through applyChanges
//   and through merge`) already pinned.
//
// * **`Document.getChangesAdded` answers about its *argument*, and the port is
//   right and the test that read it the other way round was wrong.** Upstream
//   is "Get changes in `other` that are not in `self`"
//   ([`automerge.rs:1531-1552`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
//   [`autocommit.rs:640-644`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs)):
//   it walks from `other`'s heads and rebuilds the changes from **`other`'s**
//   op set, which is what `merge` needs and is why `merge` passes the peer as
//   the argument. Read the other way round it answers with the caller's *own*
//   change, which the caller already holds, so `applyChanges` skips it on the
//   hash check and the comparison is silently empty. Measured: the oracle's
//   `loadinc` subcommand runs it both ways round over one forked pair and each
//   call answers with the *argument's* change.
//
// * **Heads come back in ascending byte order and the port keeps them there.**
//   The reference holds its heads in a `BTreeSet<ChangeHash>`
//   ([`change_graph.rs:41`](../../github-automerge-automerge/rust/automerge/src/change_graph.rs))
//   and `ChangeHash` derives `Ord` over its thirty-two bytes
//   ([`types.rs:689-690`](../../github-automerge-automerge/rust/automerge/src/types.rs)),
//   so which hash lands first is a property of the bytes and not of which
//   document the change came from. Upstream's own test for this shape asserts
//   **membership** — `heads.contains(&hash_d)`, `heads.contains(&hash_b)`
//   ([`tests/test.rs:3186-3187`](../../github-automerge-automerge/rust/automerge/tests/test.rs))
//   — and pins no order, so the ported test's positional assertion was the
//   transcription error and is now `containsHash`.
//
// * **The cached actor index is a fourth view of the actor table, and the port
//   rewrote it on insertion only.** `Actor::Cached` holds an `ActorIdx`, so an
//   insertion or a removal anywhere at or below it changes which slot it names,
//   and upstream keeps it in step from exactly two places — `insert_actor` and
//   `remove_actor` ([`automerge.rs:1301-1306`](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
//   `:427-432`) — through `Actor::rewrite_with_new_actor` and
//   `Actor::remove_actor` ([`:52-69`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
//   The port had the first and not the second, and **the omission is a silent
//   rename rather than an off-by-one**: when the cached actor's own slot is the
//   one dropped, the actor below it moves up into the freed index, so an index
//   left alone comes to name a *different* actor — and when the cached actor
//   sorts last, the index is simply past the end. Measured on the reference's
//   own `rollback_with_no_ops`
//   ([`tests/test.rs:2746-2772`](../../github-automerge-automerge/rust/automerge/tests/test.rs)):
//   an empty transaction on a fork interns its actor at the end of the table,
//   its commit drops that actor again, the cached index survives out of range,
//   and the merge then interns an actor that sorts first, shifting the stale
//   index one further — `index out of bounds: index 2, len 2` from
//   `transactionArgs`, **an `ABRT` that stops the binary and so hid every test
//   after the seventy-sixth of that file**. `Document.removeActor` now rewrites
//   the cache before it drops the slot, exactly as upstream does, and
//   `Document.removeUnusedActors` no longer repeats that arithmetic: with the
//   rewrite in one place instead of none, doing it in both decrements twice
//   whenever the cached index sits two or more slots above the one removed.
//   Both cases are pinned by *a no-op commit survives a merge: the cached actor
//   index is rewritten with the table* and *removing an actor renumbers the
//   cached index without renaming the actor*.
//
// * **`buildSample`'s mark anchors carried `insert = false`, and the third
//   instance of one day's family was a fixture rather than a derivation.**
//   Five round-trip tests — *a document built here saves, reloads, and
//   compares equal*, *a document is still readable after the bytes it was
//   loaded from are gone*, *loadIncremental into a non-empty document equals
//   loading the same bytes whole*, *the same bytes, three ways, materialise
//   one document* and *a clone shares nothing mutable* — all failed with the
//   same line, `group_mismatch { at = 11, first_top = 9, last_vis = 10 }`, so
//   the slice was one defect and the question was which of the index or the
//   rows was wrong.
//
//   **The rows.** The reloaded side was already right — row 9 `top = false`,
//   row 10 `top = true`, the `IndexBuilder::flush` answer
//   ([`op_set2/op_set/index.rs:159-176`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/index.rs))
//   — and the two rows were the `"hi"` insert (counter 7) and the `bold` mark
//   over it (counter 9). The mark carried `insert = false`, so
//   [`Op.elemidOrKey`](opset/op.zig) returned its **predecessor** element
//   (`Seq(7@0)`) rather than its own (`ElemId(9@0)`, `op.rs:1040-1046`) and the
//   mark landed **inside the register of the insert it annotates**. Upstream
//   cannot write that: `TxOp::insert` hard-codes `insert: true` for every
//   insert including a mark (`op.rs:330-357`), and the one constructor that
//   pairs `insert: false` with a `Seq` key — `TxOp::list` (`op.rs:261-292`) —
//   is reached only from `local_list_op`
//   ([`inner.rs:495-558`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
//   and is never given a mark. The fixture now writes both anchors as
//   inserts.
//
//   **The pattern, and where it points.** This is the third defect today of
//   one shape: two structures that must agree computing the same thing by
//   different rules. `mapKeyRow` derived a row's position from the object end
//   where `propRange` derives the sorted insertion point; a `SkipIter`
//   changed its skip unit from rows to yielded rows; `insertActor` rewrote a
//   cached index and `removeActor` did not. **The shared defect is a *second
//   derivation* of a value another route already owns** — and here the second
//   derivation was not even in the port: it was in the fixture, which
//   re-derived "where does a mark op go" from `OpSpec` defaults instead of
//   from `TxOp::insert`. **The one place to look, then, is every site that
//   builds an op *outside* the writer that upstream reaches it through**: a
//   hand-built `OpSpec`, a hand-encoded change, a test fixture's own default.
//   None of them is covered by the round-trip tests, because a round trip is
//   self-consistent — the fixture is wrong in the same way on both sides.
//
//   **What proves it.** The oracle grew two subcommands for this, both outside
//   the golden set (nothing regenerates them, so `-Dconformance-record`
//   cannot overwrite them): `sample` builds the same operation sequence
//   through the reference's **own public writer** and prints its `save()`
//   bytes, its heads and its materialised document; `loadhex` reads a save as
//   hex on stdin and reports what the reference makes of it. Run over the
//   corrected fixture, `loadhex` on the port's own `save()` bytes answers the
//   same document the reference's writer produces — `hello` = `"again"`,
//   `only_b` = `"b"`, `list` = `["b", "c"]`, `map` = `{in_map: "yes"}`, text
//   `"hi!"` with one `bold` mark over `[2, 3)` and value `0` — and re-saves it
//   at the same length.
//
//   **The invariant is now pinned by its own test**, *the index a document is
//   built with is the index its bytes rebuild*: soundness on **both** sides
//   first (`validateOpOrder`, `validateTopIndex`, and the two index columns'
//   lengths), then the two indexes compared cell for cell by `debugCmp`, then
//   the **materialised** document read through the read surface — text, marks,
//   object types, a map key, a list element by index, heads and stats. A
//   save/reload that merely does not error passes on a document that reads
//   differently, which is the whole of what this cluster of tests was for.
//
// * **`isolate` and `integrate` moved a field and did nothing else, and
//   upstream's both call `patch_to` first.** `AutoCommit::isolate` is
//   `patch_to(heads)` then one assignment (`autocommit.rs:435-436`) and
//   `AutoCommit::integrate` is `patch_to(self.doc.get_heads())` then one
//   assignment (`:441-442`); `patch_to` (`:816-824`) is
//   `finish_current_view` on the view being left plus a `DiffIter::log` walk
//   over `clock_range(before, after)` into the view being entered. The port had
//   neither, so an incremental diff across an isolate round trip reported the
//   local write and **nothing of the transition**. [`Document.patchTo`] is that
//   method and both callers reach it.
//
//   **Both halves were wired and the stream was still three patches short, and
//   that is a measurement, not an estimate.** The oracle's `isolateprobe` runs
//   the upstream case of
//   `incorrect_patches_produced_when_isolating_and_integrating`
//   ([`text.rs:868-921`](../../github-automerge-automerge/rust/automerge/tests/text.rs))
//   with the log drained at every step, which attributes the reference's seven:
//
//   ```text
//   0 DeleteMap { key: "color" }        isolate()   -> patch_to, DiffIter::log
//   1 DeleteMap { key: "name" }         isolate()   -> patch_to, DiffIter::log
//   2 PutMap   { key: "color" }         commit_with -> the transaction's events
//   3 SpliceText { index: 0, "unset" }  commit_with -> the same
//   4 Conflict { prop: Map("color") }   integrate() -> patch_to, DiffIter::log
//   5 PutMap   { key: "name" }          integrate() -> patch_to, DiffIter::log
//   6 SpliceText { index: 0, 100*"a" }  integrate() -> the same
//   ```
//
//   **So the walk emits five of the seven and `finish_current_view` emits
//   none of them**: at `isolate()` the log's events are empty — the previous
//   `diff_incremental` truncated them — so the guard at
//   [`patch_log.rs:291`](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)
//   returns early, and the four events that walk and the isolated commit
//   recorded are *closed* at `integrate()`. `make_patches` is
//   `completed_patches` then the current view's (`:505-509`), which is why four
//   of the seven come out of the first list. **`integrate()` is not a no-op**
//   either: after `commit_with` the isolation is `Some([that change])`
//   (`:735-736`) while the graph holds three heads, so `patch_to`'s
//   `before != after` test fires and the walk from one head to three is what
//   sees `color` twice over and raises the conflict at index 4.
//
//   **The cause was the actor index on the rows, and it was in
//   [`Document.commit`].** It opened with
//   `var args = try self.transactionArgs(gpa, self.isolation)` — it
//   re-derived the transaction's arguments because the port's transactions did
//   not carry them into it — and it did so **after
//   `Transaction.insertLocalOp` had already spliced the change's rows into the
//   op set**. The re-derivation reaches [`Document.isolatedActorIndex`], which
//   interns a concurrency actor ([`automerge.rs`:1259-1281](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   and [`Document.insertActor`] then runs `rewriteWithNewActor` and renumbers
//   every row at or above the insertion point — **including the rows this very
//   change just wrote**. The change's header named the new actor and its rows
//   named the old one, and [`ChangeGraph.clockAt`] reads the header, so the
//   clock put the fork's `max_op` in the fork's slot while the rows answered
//   to the base actor's. A clock-filtered read then saw no `"color"` at all,
//   and every patch that mentions one was missing.
//
//   **`Document.commit` takes the transaction's [`TransactionArgs`] now**,
//   which is upstream's shape: `AutoCommit::ensure_transaction_open`
//   ([`autocommit.rs`:445-457](../../github-automerge-automerge/rust/automerge/src/autocommit.rs))
//   builds them **once per transaction, before any op is written**, and
//   `TransactionInner::commit_impl` reads that same struct
//   ([`inner.rs`:146-172](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)).
//   The actor index in them is the one every op was already written against by
//   `TransactionInner::next_id` (`:295-297`), which is the invariant the
//   re-derivation broke. `deps` is borrowed rather than taken, and `scope` and
//   `author` are not read: `author` is a function of `seq` alone
//   ([`automerge.rs`:568](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//   and is derived here.
//
// Scope and actor selection happen when the transaction opens. AutoCommit owns
// one held transaction opened at its isolation heads (`autocommit.rs:445-457`);
// raw Transaction.open/openAt take their own unscoped/explicit-head semantics
// (`automerge.rs:476-509`). No automatic raw transaction helpers remain.
//
// * **`integrate` is now `DiffError!void` where it was `void`, and the
//   reference's infallibility is a panic rather than a property.**
//   Upstream's `PatchLog::finish_current_view` carries
//   `.expect("AutoCommit's patch log always belongs to its document")` on the
//   one operation in it that can fail
//   ([`patch_log.rs`:293](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)),
//   so `AutoCommit::isolate` and `::integrate` report a refusal by aborting.
//   **Making the port's `integrate` total would be a divergence, not a fix**,
//   so the error is propagated instead. The alternative — catching a refusal
//   and carrying on — leaves `patch_log` short of a view's events with nothing
//   to say so, and the next [`Document.diffIncremental`] answers with a stream
//   that is silently missing a transition, which is the defect the wiring
//   exists to remove.
//
//   **The C-ABI cost of that is one line and no header.** There is no
//   `AMintegrate` export and `include/automerge.h` declares neither
//   `AMintegrate` nor `AMisolate`; [`c.doc.AMdoc.integrate`] is a Zig method
//   with no callers, and it is now `!void`. The brief for this slice assumed
//   `AMintegrate` was in the C ABI at `src/c/doc.zig:424`; it is not, and
//   saying so is worth more than the assumption.
//
// * **`Document.dropIsolation` is upstream's isolation write on its own**, the
//   line `AutoCommit::ensure_transaction_closed` (`:464-466`) and
//   `AutoCommit::commit_with` (`:735-736`) run beside a commit and on neither
//   of which is a view transition. It exists for
//   [`transaction.commitWith`](../../src/transaction.zig), which parks the
//   document's isolation, puts a transaction's own scope in place for the
//   duration of a commit and restores it afterwards — a scope swap upstream
//   does not have, because `AutoCommit` scopes a transaction when it opens it
//   (`:447`) rather than rewinding the document to do it. Routing that
//   through [`Document.integrate`] would put a spurious transition in the log
//   of every isolated commit.
//
// * **`Document.actor` is an `Actor` union whose `Unused` arm borrows the
//   document's arena, and `loadIncremental` was moving it across a `deinit`
//   that frees that arena.** `Actor` mirrors upstream's
//   `Unused(ActorId)` / `Cached(usize)` ([`automerge.rs:47-50`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//   where the `Unused` arm **owns** a `Vec<u8>`; this port's `ActorId` is a
//   borrowed slice, so the union is a value that only one of its two arms
//   survives a copy. `Document.reset` carried `actor` (and `author`, which
//   borrows from the same arena) across [`Document.deinit`] and
//   `Document.loadIncremental`'s empty-document branch restored it afterwards
//   — so the document's own actor became a slice over freed memory, and the
//   peer actor [`Document.adoptActors`] interned next was written into those
//   bytes.
//
//   **What a C consumer saw**, and the only way the defect reached a caller:
//   `AMcreate` interns the caller's bytes into the document's arena
//   ([`c.doc.internActor`](../c/doc.zig)), and every actor in this tree's own
//   tests is a string literal, which never dies. A document created with actor
//   `89abcdef` that received a change from `01234567` before it committed
//   anything reported `01234567` as its own and minted its next change under
//   it — `test_should_handle_changes_concurrrent_to_the_last_sync_heads` and
//   `test_should_work_with_prior_sync_state_2` in the C suite, both
//   `DuplicateSeqNumber`.
//
//   Upstream cannot be wrong this way: `load_incremental_log_patches` copies
//   the **id** and re-establishes it on the document it just built —
//   `doc = doc.with_actor(self.actor_id().clone())` (`:1040`) — and
//   `set_actor` (`:359-366`) **resolves it against that document's actor
//   table**, caching the index when the table holds the actor and keeping the
//   bytes when it does not. The incremental loader stages the copied actor in
//   the fresh arena before releasing the old owner, then calls setActorId.

// Historical read clocks are retained by owned head keys. Their heap buffers
// survive pool growth and subsequent head selection until document mutation.
// Explicit transaction heads always use this pool, including current graph heads
// (`manual_transaction.rs:113-122`), so pending rows cannot leak into that view.

// ── Diff against the reference, for the actor table and its mirrors ──────────
//
// | Zig 0.16.0 | upstream | Rust | port | does not / is / this |
// | --- | --- | --- | --- | --- |
// | `adoptActorMirrors(gpa)` (private) | `ChangeGraph::new`, `change_graph.rs:96-106` | `seq_index: vec![vec![]; num_actors]`, and `Authors::with_actors`, `author.rs:46-52` | `for (self.ops.actors.items, 0..) \|actor, i\| { try self.authors.insertAt(gpa, idx, …); try self.graph.insertActor(gpa, idx); try self.actor_authors.insert(gpa, idx, null); }` | **is** upstream's rule — both mirrors sized from the actor count, never from the changes — and **is** what keeps `ChangeGraph.addChange`'s own interning a no-op on this path. Without it the mirrors **were** grown by the changes, so an actor the chunk's column names and no change did left them **short**, and the next insertion renumbered a node that had not moved |
// | `saveChunk` writes `self.ops.actors.items` in full | `write_document_chunk`, `storage/document.rs` | the actor column is the document's whole actor table, not the set its changes name | the same, so the gap is reachable: a caller that interned an actor and never committed (`[`Document.putActorRef`]`) saves one | **is** upstream's behaviour, and **is** what makes the load's job larger than the changes' worth. (This row used to cite `:3888-3890` for it; a self-reference by line number drifts with every edit below it, so it is named instead) |
// | `Document.removeActor(gpa, idx)`: the order of the fan | `Automerge::remove_actor`, `automerge.rs:427-432` | rewrites `self.actor`, then `self.ops`, then `self.change_graph`, then `self.authors` — four statements, none of which can fail: `OpSet::remove_actor` drops the actor and panics if a column still names it (`op_set.rs:1419-1429` over `columns.rs:355-357`) and `ChangeGraph::remove_actor` `assert!`s on a slot that still holds a change (`change_graph.rs:176`) | `self.graph.removeActor(…)`, then `self.ops.removeActor(…)`, then `self.authors.removeAt(…)`, then the author's cache, then **`self.actor.removeActor(…)` last**, with an `errdefer` per fallible step holding the undo for the steps before it | **does not** have upstream's cannot-fail middle, so it **has** an exit in the middle that upstream does not and the fan is interruptible — which is why the cached rewrite moved to the end and the fallible steps carry undos. It was rewritten **first**, so either refusal returned a document whose current actor had been renumbered to whichever actor moved into the freed slot, with the other three tables untouched. The graph goes first because its refusal is the reachable one; the last step owes no undo because nothing after it can fail |
// | `Actor.removeActor(slot, dropped)` | `Actor::remove_actor`, `automerge.rs:53-61` | `fn remove_actor(&mut self, index: usize, actors: &[ActorId])` — reads `actors[index]` itself, which upstream can do because its caller's four lines cannot fail | `pub fn removeActor(self: *Actor, slot: ActorIdx, dropped: ActorId) void` | **takes the bytes rather than the table**, because the port's caller rewrites the union **after** the fan has dropped the slot they came from. The out-of-range fallback the old signature needed (`ActorId.init(&.{})`) **is gone** with it: the slot is bounds-checked by the only caller |
// | the `at >= self.ops.actors.items.len` refusal at the top of `Document.removeActor` | `Vec::remove`, `op_set.rs:1420` | panics on an index past the end | `return error.InvalidActorIndex` | **is** this file's own check, and it is what makes reading `dropped` safe. It turns a process-wide trap — which stops a test binary and hides every test after it, the shape recorded above at `transact.zig` — into an error a caller can read. `error.InvalidActorIndex` is the document's word for it (`error.zig:32-33`) |
// | the `seqForActor(idx) != 0` refusal in `Document.removeActor` | `ChangeGraph::remove_actor`'s `assert!`, `change_graph.rs:176` | **traps** — a process-wide abort, not a returned error — when a slot still holds a change | `if (at >= self.graph.numActors() or self.graph.seqForActor(idx) != 0) return error.InvalidActorIndex;`, checked with the other guards before any table moves | **is** the same condition read one step earlier and through the document's vocabulary, which is what lets the fan below be all-infallible (`self.graph.removeActor(…) catch unreachable`). It costs the port the graph's own `error.InvalidIndex` as an answer, and that is the right trade: **no caller of this entry point can observe it**, because the check fires first, so a test naming it would pin a tag the public method never returns |
// | the route table on `adoptActorMirrors` | `load::load_changes`, `storage/load.rs:113-120`; `load_incremental`, `automerge.rs:1027-1069` | `Chunk::Document` hands `reconstruct_changes`' output to `apply_changes`, so on the incremental route an actor nothing names never reaches the live table either | five routes, named and checked: a document chunk adopted whole (`load`, `loadInto`, `clone`, `fork`, `forkAt`, `loadIncremental` on an empty document), a document chunk read for its changes and **released** (`loadIncremental` on a non-empty one), a change-chunk stream, `merge` and `applyChanges`, and a removal | checks actor-table consistency across loading routes. The second route adopts no table at all, and the third interns through `putActorRef` before the screen runs, which keeps `BatchApply.insertNewActors` from growing `ops.actors` alone |

test "independent default documents merge both histories" {
    const gpa = testing.allocator;
    const trans = @import("transact.zig");
    const readonly = @import("read.zig");
    var left = try Document.init(gpa, testing.io);
    defer left.deinit();
    var right = try Document.init(gpa, testing.io);
    defer right.deinit();
    {
        var tx = try trans.Transaction.open(gpa, &left);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "left" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    {
        var tx = try trans.Transaction.open(gpa, &right);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "right" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    const heads = try left.merge(gpa, &right);
    defer gpa.free(heads);
    try testing.expectEqual(@as(i64, 1), (try readonly.get(&left, .root, .{ .key = "left" })).?.value.scalar.int);
    try testing.expectEqual(@as(i64, 2), (try readonly.get(&left, .root, .{ .key = "right" })).?.value.scalar.int);
    try testing.expectEqual(@as(usize, 2), left.graph.len());
}

test "incoming authored opaque footer history remains readable after every apply OOM" {
    // Build peer bytes without the failing allocator, then observe each refused owner.
    const observer = testing.allocator;
    var peer = try Document.init(observer, testing.io);
    defer peer.deinit();
    const actor = try peer.putActorRef(observer, .{ .bytes = actor_b });
    const specs = [_]OpSpec{
        .{ .ctr = 17, .key = KeyRef.fromStr("incoming"), .value = .{ .str = "value" } },
    };
    const ops = try buildOps(observer, actor, &specs);
    defer freeChangeOps(observer, ops);
    var footer: std.ArrayList(u8) = .empty;
    defer footer.deinit(observer);
    try encodeAuthorFooter(observer, &footer, "incoming author");
    try footer.appendSlice(observer, &.{ 0xfd, 0x00, 0x81, 0x7f });
    var incoming = try encodeOneChange(observer, peer.ops.actors.items, .{
        .actor = actor,
        .seq = 1,
        .start_op = 17,
        .max_op = 17,
        .time = 123,
        .message = "opaque history",
        .deps = &.{},
        .footer = footer.items,
    }, ops);
    defer incoming.deinit(observer);

    var reached_success = false;
    for (0..2048) |fail_index| {
        var failing = testing.FailingAllocator.init(observer, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var target = Document.init(gpa, testing.io) catch |failure| switch (failure) {
            error.OutOfMemory => continue,
            else => return failure,
        };
        defer target.deinit();
        const applied = target.applyChanges(gpa, &.{incoming.change});
        // The owner retains gpa, so disable failure before every public observer.
        failing.fail_index = std.math.maxInt(usize);
        var refused = false;
        if (applied) |_| {} else |failure| {
            switch (failure) {
                error.OutOfMemory => refused = true,
                else => return failure,
            }
        }
        var metas = try target.getChangesMeta(observer, &.{});
        defer metas.deinit(observer);
        for (metas.items.items) |meta| {
            try testing.expectEqualSlices(u8, incoming.change.hash.bytes[0..], meta.hash.bytes[0..]);
            try testing.expectEqual(@as(u64, 17), meta.start_op);
            try testing.expectEqualSlices(u8, footer.items, meta.extra);
            try testing.expectEqualStrings("incoming author", meta.author.?);
            var single = (try target.getChangeMetaByHash(observer, meta.hash)).?;
            defer single.deinit(observer);
            try testing.expectEqual(@as(u64, 17), single.start_op);
            try testing.expectEqualSlices(u8, footer.items, single.extra);
            try testing.expectEqualStrings("incoming author", single.author.?);
            var rebuilt = (try target.getChangeByHash(observer, meta.hash)).?;
            defer rebuilt.deinit(observer);
            try testing.expectEqualSlices(u8, meta.hash.bytes[0..], rebuilt.change.hash.bytes[0..]);
            try testing.expectEqualSlices(u8, footer.items, changeFooter(rebuilt.change).?);
        }
        const saved = try target.save(observer);
        defer observer.free(saved);
        var reloaded = try Document.load(observer, testing.io, saved, .unicode_code_point);
        defer reloaded.deinit();
        const before = try target.getHeads(observer);
        defer observer.free(before);
        const after = try reloaded.getHeads(observer);
        defer observer.free(after);
        try testing.expectEqual(before.len, after.len);
        for (before, after) |left, right| {
            try testing.expectEqualSlices(u8, left.bytes[0..], right.bytes[0..]);
        }
        _ = try target.putActorRef(observer, .{ .bytes = &.{0} });
        for (metas.items.items) |meta| {
            var remapped = (try target.getChangeByHash(observer, meta.hash)).?;
            defer remapped.deinit(observer);
            try testing.expectEqualSlices(u8, meta.hash.bytes[0..], remapped.change.hash.bytes[0..]);
        }
        if (!refused) {
            reached_success = true;
            break;
        }
    }
    try testing.expect(reached_success);
}

test "load options ignore discards complete tail before a partial change" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const snapshot = try source.save(gpa);
    defer gpa.free(snapshot);
    const snapshot_heads = try source.getHeads(gpa);
    defer gpa.free(snapshot_heads);
    _ = try addKeyChange(&source, gpa, actor_a, 2, 16, "tail", snapshot_heads);
    const complete_tail = try source.saveIncremental(gpa);
    defer gpa.free(complete_tail);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendSlice(gpa, snapshot);
    try bytes.appendSlice(gpa, complete_tail);
    try bytes.appendSlice(gpa, complete_tail[0 .. complete_tail.len - 1]);
    var loaded = try Document.loadWithOptions(gpa, testing.io, bytes.items, .{
        .on_partial_load = .ignore,
    });
    defer loaded.deinit();
    const heads = try loaded.getHeads(gpa);
    defer gpa.free(heads);
    try testing.expectEqual(snapshot_heads.len, heads.len);
    for (snapshot_heads, heads) |expected, actual| {
        try testing.expectEqualSlices(u8, expected.bytes[0..], actual.bytes[0..]);
    }
    const readonly = @import("read.zig");
    try testing.expect((try readonly.get(&loaded, .root, .{ .key = "tail" })) == null);

    var change_first = try Document.loadWithOptions(gpa, testing.io, bytes.items[snapshot.len..], .{ .on_partial_load = .ignore });
    defer change_first.deinit();
    const no_heads = try change_first.getHeads(gpa);
    defer gpa.free(no_heads);
    try testing.expectEqual(@as(usize, 0), no_heads.len);
}

test "raw hasOurChanges compares exact full committed heads" {
    const gpa = testing.allocator;
    var document = try buildSample(gpa);
    defer document.deinit();
    var state = @import("sync/state.zig").State.new(gpa);
    defer state.deinit();
    try testing.expect(!document.hasOurChanges(&state));
    state.shared_heads = try document.getHeads(gpa);
    try testing.expect(document.hasOurChanges(&state));
    const other = try gpa.alloc(ChangeHash, state.shared_heads.len + 1);
    @memcpy(other[0..state.shared_heads.len], state.shared_heads);
    other[other.len - 1] = ChangeHash.zero;
    gpa.free(state.shared_heads);
    state.shared_heads = other;
    try testing.expect(!document.hasOurChanges(&state));
}

test "load string migration commits before assigning arbitrary author bytes" {
    const gpa = testing.allocator;
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    {
        var tx = try @import("transact.zig").Transaction.open(gpa, &source);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "before" }, .{ .str = "migrate me" });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    const author = [_]u8{ 0xff, 0x00, 0x80 };
    var loaded = try Document.loadWithOptions(gpa, testing.io, bytes, .{
        .string_migration = .convert_to_text,
        .author = &author,
    });
    defer loaded.deinit();
    try testing.expectEqualSlices(u8, &author, loaded.getAuthor().?);
    var migrated = try loaded.getChangesMeta(gpa, &.{});
    defer migrated.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), migrated.items.items.len);
    try testing.expect(migrated.items.items[1].author == null);
    try testing.expectEqual(@as(usize, 0), migrated.items.items[1].extra.len);
    const next = try commitRootPut(gpa, &loaded, "after");
    var authored = (try loaded.getChangeByHash(gpa, next)).?;
    defer authored.deinit(gpa);
    try testing.expectEqualSlices(u8, &author, (try decodeAuthorFooter(changeFooter(authored.change))).?);
}

test "unverified heads bypasses head equality but never checksum validation" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const saved = try source.saveWithOptions(gpa, .{
        .deflate = false,
        .retain_orphans = true,
    });
    defer gpa.free(saved);
    const framed = try chunkmod.parseChunk(saved);
    const body = try gpa.dupe(u8, framed.data);
    defer gpa.free(body);
    var cursor = Input.init(body);
    const actors = try cursor.takeUleb();
    for (0..actors) |_| {
        const length = try cursor.takeUleb();
        _ = try cursor.take(@intCast(length));
    }
    const head_count = try cursor.takeUleb();
    try testing.expect(head_count > 0);
    body[cursor.pos] ^= 0x01;
    var changed: std.ArrayList(u8) = .empty;
    defer changed.deinit(gpa);
    try chunkmod.writeChunk(&changed, gpa, .document, body);
    const strict = Document.loadWithOptions(gpa, testing.io, changed.items, .{});
    if (strict) |loaded_doc| {
        var unexpected = loaded_doc;
        unexpected.deinit();
        return error.ExpectedRefusal;
    } else |_| {}
    var inspected = try Document.loadUnverifiedHeads(gpa, testing.io, changed.items, .{});
    defer inspected.deinit();
    try source.debugCmp(&inspected);
    changed.items[changed.items.len - 1] ^= 0x01;
    const damaged = Document.loadUnverifiedHeads(gpa, testing.io, changed.items, .{});
    if (damaged) |loaded_doc| {
        var unexpected = loaded_doc;
        unexpected.deinit();
        return error.ExpectedRefusal;
    } else |_| {}
}

test "external apply log is borrowed across compatible document actor tables" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    var incoming = try source.getChanges(gpa, &.{});
    defer incoming.deinit(gpa);
    const changes = try asChanges(gpa, incoming.slice());
    defer gpa.free(changes);
    var first = try Document.init(gpa, testing.io);
    defer first.deinit();
    var second = try Document.init(gpa, testing.io);
    defer second.deinit();
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    _ = try first.applyChangesWithPatchLog(gpa, changes, &log);
    var patches = try first.makePatches(&log);
    defer patches.deinit();
    try testing.expect(patches.len() > 0);
    const recorded = log.events.items.len;
    _ = try second.applyChangesWithPatchLog(gpa, changes, &log);
    try first.debugCmp(&second);
    const second_heads = try second.getHeads(gpa);
    defer gpa.free(second_heads);
    try testing.expect(sameHashList(second_heads, first.graph.getHeads()));
    try testing.expectEqual(recorded * 2, log.events.items.len);
    var again = try first.makePatches(&log);
    defer again.deinit();
    try testing.expect(again.len() >= patches.len());
}

test "empty incremental load retains nested snapshot paths in a borrowed log" {
    // Mirror api_parity.rs:506-532 with real public transactions. Rust retains
    // the loaded snapshot's paths (automerge.rs:1048,1078-1079), even when the
    // caller renders against the previous owner, which has no nested objects.
    const gpa = testing.allocator;
    const Transaction = @import("transact.zig").Transaction;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_a });
    var initial = patchesmod.PatchLog.active(gpa);
    defer initial.deinit();
    var owner_tx = try Transaction.openWithPatchLog(gpa, &owner, &initial, null);
    defer owner_tx.deinitClosed();
    const owned_id = try owner_tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    try testing.expect(owned_id != null);
    var owned = try owner_tx.commitWith(.{ .time = 0 });
    defer owned.deinit(gpa);
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_a });
    var tx = try Transaction.open(gpa, &source);
    defer tx.deinitClosed();
    const map = try tx.putObject(.root, .{ .key = "map" }, .map);
    const key_id = try tx.put(map, .{ .key = "k" }, .{ .int = 7 });
    try testing.expect(key_id != null);
    const list = try tx.putObject(.root, .{ .key = "list" }, .list);
    const first_id = try tx.insert(list, 0, .{ .bool_value = true });
    const second_id = try tx.insert(list, 1, .{ .str = "two" });
    const text = try tx.putObject(.root, .{ .key = "text" }, .text);
    try tx.spliceText(text, 0, 0, "a😀b");
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    var foreign = try Document.init(gpa, testing.io);
    defer foreign.deinit();
    foreign.setActorId(.{ .bytes = actor_b });
    var offered = try owned.patch_log.cloneAndRebind(gpa, owner.patchIdentity());
    defer offered.deinit();
    try testing.expectEqual(source.len(), try foreign.loadIncrementalWithPatchLog(
        gpa,
        bytes,
        &offered,
    ));
    try source.debugCmp(&foreign);
    // Exercise the same snapshot observers as api_parity_common.expectSnapshot
    // before the first retained-log render; none may consume its cached paths.
    const AutoSerde = @import("autoserde.zig").AutoSerde(Document);
    const expected_json = try AutoSerde.from(&source).toJson(gpa);
    defer gpa.free(expected_json);
    const actual_json = try AutoSerde.from(&foreign).toJson(gpa);
    defer gpa.free(actual_json);
    try testing.expectEqualStrings(expected_json, actual_json);
    const heads = try foreign.getHeads(gpa);
    defer gpa.free(heads);
    const expected_heads = try source.getHeads(gpa);
    defer gpa.free(expected_heads);
    try testing.expect(sameHashList(expected_heads, heads));
    var reloaded = try Document.load(gpa, testing.io, bytes, foreign.textEncoding());
    defer reloaded.deinit();
    const reloaded_json = try AutoSerde.from(&reloaded).toJson(gpa);
    defer gpa.free(reloaded_json);
    try testing.expectEqualStrings(expected_json, reloaded_json);
    const reloaded_heads = try reloaded.getHeads(gpa);
    defer gpa.free(reloaded_heads);
    try testing.expect(sameHashList(expected_heads, reloaded_heads));
    const observed_save = try foreign.save(gpa);
    defer gpa.free(observed_save);
    var saved = try Document.load(gpa, testing.io, observed_save, foreign.textEncoding());
    defer saved.deinit();
    try source.debugCmp(&saved);
    var retained = try owner.makePatches(&offered);
    defer retained.deinit();
    const stream = retained.slice();
    try testing.expectEqual(@as(usize, 7), stream.len);
    const expected_puts = [_]patchesmod.PatchAction{
        .{ .put_map = .{
            .key = "owned",
            .value = .{ .scalar = .{ .bool_value = true } },
            .obj = owner.idToExid(owned_id.?),
            .conflict = false,
        } },
        .{ .put_map = .{
            .key = "list",
            .value = .{ .object = .list },
            .obj = list,
            .conflict = false,
        } },
        .{ .put_map = .{
            .key = "map",
            .value = .{ .object = .map },
            .obj = map,
            .conflict = false,
        } },
        .{ .put_map = .{
            .key = "text",
            .value = .{ .object = .text },
            .obj = text,
            .conflict = false,
        } },
        .{ .put_map = .{
            .key = "k",
            .value = .{ .scalar = .{ .int = 7 } },
            .obj = source.idToExid(key_id.?),
            .conflict = false,
        } },
    };
    for (expected_puts, stream[0..5]) |expected, patch| {
        try testing.expect(expected.eql(patch.action));
    }
    for (stream[0..4]) |patch| {
        try testing.expect(patch.obj.eql(.root));
        try testing.expectEqual(@as(usize, 0), patch.path.len);
    }
    for ([_]ExId{ map, list, text }, [_][]const u8{ "map", "list", "text" }, stream[4..7]) |object, key, patch| {
        try testing.expect(patch.obj.eql(object));
        try testing.expectEqual(@as(usize, 1), patch.path.len);
        try testing.expect(patch.path[0].obj.eql(.root));
        try testing.expect(patch.path[0].prop == .key);
        try testing.expectEqualStrings(key, patch.path[0].prop.key);
    }
    try testing.expect(stream[5].action == .insert);
    const insert = stream[5].action.insert;
    try testing.expectEqual(@as(usize, 0), insert.index);
    try testing.expectEqual(@as(usize, 2), insert.values.len());
    var inserted = insert.values.iter();
    const first = inserted.next().?;
    try testing.expect(first.value.eql(.{ .scalar = .{ .bool_value = true } }));
    try testing.expect(first.obj.eql(source.idToExid(first_id)));
    try testing.expect(!first.conflict);
    const second = inserted.next().?;
    try testing.expect(second.value.eql(.{ .scalar = .{ .str = "two" } }));
    try testing.expect(second.obj.eql(source.idToExid(second_id)));
    try testing.expect(!second.conflict);
    try testing.expect(stream[6].action == .splice_text);
    const splice = stream[6].action.splice_text;
    try testing.expectEqual(@as(usize, 0), splice.index);
    try testing.expect(splice.marks == null);
    const rendered = try splice.value.makeString(gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("a😀b", rendered);
}

test "empty incremental snapshot path publication is atomic at every log OOM" {
    // Refuse each allocation in the retained log, including copied path keys,
    // and exercise both a borrowed sink and the exact internal log address.
    const observer = testing.allocator;
    const Transaction = @import("transact.zig").Transaction;
    var owner = try Document.init(observer, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_a });
    var initial = patchesmod.PatchLog.active(observer);
    defer initial.deinit();
    var owner_tx = try Transaction.openWithPatchLog(observer, &owner, &initial, null);
    defer owner_tx.deinitClosed();
    _ = try owner_tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var owned = try owner_tx.commitWith(.{ .time = 0 });
    defer owned.deinit(observer);
    var source = try Document.init(observer, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_a });
    var tx = try Transaction.open(observer, &source);
    defer tx.deinitClosed();
    const map = try tx.putObject(.root, .{ .key = "map" }, .map);
    _ = try tx.put(map, .{ .key = "k" }, .{ .int = 7 });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(observer);
    const bytes = try source.save(observer);
    defer observer.free(bytes);
    for ([_]bool{ false, true }) |self_alias| {
        var completed = false;
        var refused = false;
        for (0..128) |offset| {
            var failing = testing.FailingAllocator.init(observer, .{
                .fail_index = std.math.maxInt(usize),
            });
            const log_gpa = failing.allocator();
            var target = try Document.init(observer, testing.io);
            defer target.deinit();
            target.setActorId(.{ .bytes = actor_b });
            var external = try owned.patch_log.cloneAndRebind(log_gpa, owner.patchIdentity());
            defer external.deinit();
            if (self_alias) {
                std.mem.swap(patchesmod.PatchLog, &target.patch_log, &external);
            }
            const log = if (self_alias) &target.patch_log else &external;
            const before = try target.save(observer);
            defer observer.free(before);
            const events = log.events.items.len;
            const identity = log.identity;
            const path_hint = log.path_hint;
            failing.fail_index = failing.alloc_index + offset;
            const attempted = target.loadIncrementalWithPatchLog(observer, bytes, log);
            failing.fail_index = std.math.maxInt(usize);
            if (attempted) |added| {
                try testing.expectEqual(source.len(), added);
                try source.debugCmp(&target);
                try testing.expectEqual(events + 2, log.events.items.len);
                try testing.expectEqual(log.events.items.len, log.path_hint);
                var retained = try owner.makePatches(log);
                defer retained.deinit();
                try testing.expectEqual(@as(usize, 3), retained.len());
                completed = true;
                break;
            } else |failure| {
                try testing.expectEqual(error.OutOfMemory, failure);
                refused = true;
            }
            const after = try target.save(observer);
            defer observer.free(after);
            try testing.expectEqualSlices(u8, before, after);
            try testing.expectEqualStrings(actor_b, target.getActorId().bytes);
            try testing.expectEqual(events, log.events.items.len);
            try testing.expectEqual(identity, log.identity);
            try testing.expectEqual(path_hint, log.path_hint);
            try testing.expect(log.gpa.ptr == log_gpa.ptr);
            var retained = try owner.makePatches(log);
            defer retained.deinit();
            try testing.expectEqual(@as(usize, 1), retained.len());
        }
        try testing.expect(completed);
        try testing.expect(refused);
    }
}

test "external log actor mismatch preflights every incoming route without mutation" {
    // A sorts before B and C. Refusal must not intern the incoming C actor either.
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_a });
    _ = try commitRootPut(gpa, &owner, "owned");
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_b });
    _ = try commitRootPut(gpa, &source, "base");
    var target = try source.clone(gpa);
    defer target.deinit();
    _ = try commitRootPut(gpa, &source, "incoming");
    _ = try addKeyChange(&source, gpa, actor_c, 1, 3, "new actor", source.graph.getHeads());
    var all = try source.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    const incoming = try asChanges(gpa, all.slice());
    defer gpa.free(incoming);
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    try log.bind(owner.patchIdentity(), owner.ops.actors.items);
    try owner.logCurrentState(gpa, &log);
    const before = try target.save(gpa);
    defer gpa.free(before);
    const before_heads = try target.getHeads(gpa);
    defer gpa.free(before_heads);
    const events = log.events.items.len;
    const identity = log.identity;
    for (0..5) |route| {
        switch (route) {
            0 => try testing.expectError(error.PatchLogMismatch, target.applyChangesWithPatchLog(gpa, incoming, &log)),
            1 => try testing.expectError(error.PatchLogMismatch, target.loadIncrementalWithPatchLog(gpa, bytes, &log)),
            2 => try testing.expectError(error.PatchLogMismatch, target.mergeWithPatchLog(gpa, &source, &log)),
            3 => try testing.expectError(error.PatchLogMismatch, target.applyChangesWithPatchLog(gpa, &.{}, &log)),
            4 => try testing.expectError(error.PatchLogMismatch, target.loadIncrementalWithPatchLog(gpa, &.{}, &log)),
            else => unreachable,
        }
        const after = try target.save(gpa);
        defer gpa.free(after);
        try testing.expectEqualSlices(u8, before, after);
        try testing.expect(sameHashList(before_heads, target.graph.getHeads()));
        try testing.expectEqual(@as(usize, 1), target.ops.actors.items.len);
        try testing.expectEqualStrings(actor_b, target.ops.actors.items[0].bytes);
        try testing.expectEqual(@as(usize, 1), log.actors.items.len);
        try testing.expectEqualStrings(actor_a, log.actors.items[0].bytes);
        try testing.expectEqual(events, log.events.items.len);
        try testing.expectEqual(identity, log.identity);
        var retained = try owner.makePatches(&log);
        defer retained.deinit();
        try testing.expectEqual(@as(usize, 1), retained.len());
    }
}

test "retained actor suffix applies successfully and refuses only missing render slots" {
    // Rust accepts this prefix migration, then panics while exporting the old B ID.
    // Native preserves application semantics and returns a checked renderer error.
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_b });
    _ = try commitRootPut(gpa, &owner, "owned");
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_a });
    _ = try commitRootPut(gpa, &source, "incoming");
    var changes = try source.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    const incoming = try asChanges(gpa, changes.slice());
    defer gpa.free(incoming);
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    try log.bind(owner.patchIdentity(), owner.ops.actors.items);
    try owner.logCurrentState(gpa, &log);
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    try testing.expectEqual(@as(usize, 1), try target.applyChangesWithPatchLog(gpa, incoming, &log));
    try source.debugCmp(&target);
    try testing.expectEqual(@as(usize, 1), target.ops.actors.items.len);
    try testing.expectEqualStrings(actor_a, target.ops.actors.items[0].bytes);
    try testing.expectEqual(@as(usize, 2), log.actors.items.len);
    try testing.expectEqualStrings(actor_a, log.actors.items[0].bytes);
    try testing.expectEqualStrings(actor_b, log.actors.items[1].bytes);
    const events = log.events.items.len;
    const before = try target.save(gpa);
    defer gpa.free(before);
    try testing.expectError(error.InvalidActorIndex, target.makePatches(&log));
    const after = try target.save(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(events, log.events.items.len);
    try testing.expectEqual(@as(usize, 2), log.actors.items.len);
}

test "snapshot replacement preserves borrowed and self-aliased logs at every log OOM" {
    // Inject only the caller log allocator and observe both owners after every refusal.
    const observer = testing.allocator;
    var owner = try Document.init(observer, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_a });
    _ = try commitRootPut(observer, &owner, "owned");
    var source = try Document.init(observer, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_b });
    _ = try commitRootPut(observer, &source, "loaded");
    const bytes = try source.save(observer);
    defer observer.free(bytes);
    for ([_]bool{ false, true }) |self_alias| {
        var completed = false;
        var refused = false;
        for (0..128) |offset| {
            var failing = testing.FailingAllocator.init(observer, .{
                .fail_index = std.math.maxInt(usize),
            });
            const log_gpa = failing.allocator();
            var target = try owner.clone(observer);
            defer target.deinit();
            var external = patchesmod.PatchLog.active(log_gpa);
            defer external.deinit();
            if (self_alias) {
                target.patch_log.deinit();
                target.patch_log = .active(log_gpa);
            }
            const log = if (self_alias) &target.patch_log else &external;
            try log.bind(owner.patchIdentity(), owner.ops.actors.items);
            try owner.logCurrentState(observer, log);
            const before = try target.save(observer);
            defer observer.free(before);
            const events = log.events.items.len;
            const identity = log.identity;
            const path_hint = log.path_hint;
            // Equal-table empty apply preflights but must not allocate a stage
            // or discard the cached path hint.
            failing.fail_index = failing.alloc_index;
            try testing.expectEqual(@as(usize, 0), try owner.applyChangesWithPatchLog(log_gpa, &.{}, log));
            try testing.expectEqual(events, log.events.items.len);
            try testing.expectEqual(path_hint, log.path_hint);
            failing.fail_index = failing.alloc_index + offset;
            const attempted = target.loadIntoWithOptions(observer, bytes, .{ .patch_log = log });
            failing.fail_index = std.math.maxInt(usize);
            if (attempted) |_| {
                try source.debugCmp(&target);
                try testing.expectEqual(events + 1, log.events.items.len);
                try testing.expect(log.gpa.ptr == log_gpa.ptr);
                completed = true;
                break;
            } else |failure| {
                try testing.expectEqual(error.OutOfMemory, failure);
                refused = true;
            }
            const after = try target.save(observer);
            defer observer.free(after);
            try testing.expectEqualSlices(u8, before, after);
            try testing.expectEqual(events, log.events.items.len);
            try testing.expectEqual(identity, log.identity);
            try testing.expectEqual(path_hint, log.path_hint);
            try testing.expectEqual(@as(usize, 1), log.actors.items.len);
            try testing.expectEqualStrings(actor_a, log.actors.items[0].bytes);
            try testing.expectEqual(@as(usize, 0), log.completed.len());
            try testing.expect(log.gpa.ptr == log_gpa.ptr);
            var retained = try owner.makePatches(log);
            defer retained.deinit();
            try testing.expectEqual(@as(usize, 1), retained.len());
        }
        try testing.expect(completed);
        try testing.expect(refused);
    }
}

test "snapshot loading bypasses actor migration while empty full load bypasses logging" {
    // Rust automerge.rs:911-914,994-997,1038-1051 logs indexed state directly.
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = actor_a });
    _ = try commitRootPut(gpa, &owner, "owned");
    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = actor_b });
    _ = try commitRootPut(gpa, &source, "loaded");
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    try log.bind(owner.patchIdentity(), owner.ops.actors.items);
    try owner.logCurrentState(gpa, &log);
    const events = log.events.items.len;
    var empty = try Document.loadWithOptions(gpa, testing.io, &.{}, .{ .patch_log = &log });
    defer empty.deinit();
    try testing.expectEqual(events, log.events.items.len);
    try testing.expectEqual(owner.patchIdentity(), log.identity.?);
    var loaded = try Document.loadWithOptions(gpa, testing.io, bytes, .{ .patch_log = &log });
    defer loaded.deinit();
    try source.debugCmp(&loaded);
    try testing.expectEqual(events + 1, log.events.items.len);
    try testing.expectEqualStrings(actor_a, log.actors.items[0].bytes);
    // Rendering itself has no actor-compatibility gate in Rust (patch_log.rs:505-529).
    var rendered = try loaded.makePatches(&log);
    defer rendered.deinit();
    try testing.expectEqual(@as(usize, 2), rendered.len());
    try empty.loadIntoWithOptions(gpa, bytes, .{ .patch_log = &log });
    try source.debugCmp(&empty);
    try testing.expectEqual(events + 2, log.events.items.len);
    var incremental = try Document.init(gpa, testing.io);
    defer incremental.deinit();
    try testing.expectEqual(source.len(), try incremental.loadIncrementalWithPatchLog(gpa, bytes, &log));
    try source.debugCmp(&incremental);
    try testing.expectEqual(events + 3, log.events.items.len);
    try testing.expectEqualStrings(actor_a, log.actors.items[0].bytes);
}

test "raw hydrate initialization commits one batch and preserves absent existing keys" {
    const gpa = testing.allocator;
    const hydration = @import("hydrate.zig");
    var document = try Document.init(gpa, testing.io);
    defer document.deinit();
    _ = try commitRootPut(gpa, &document, "keep");
    var map = hydration.Map.init(gpa, .root);
    defer map.deinit();
    try map.putOwned("first", .init(hydration.Value.fromScalar(.{ .int = 2 }), false));
    try map.putOwned("second", .init(hydration.Value.fromScalar(.{ .bool_value = true }), false));
    var initialized = try document.initFromHydrate(gpa, &map);
    switch (initialized) {
        .success => |*success| {
            defer success.patch_log.deinit();
            try testing.expect(success.hash != null);
        },
        .failure => |*failure| {
            failure.patch_log.deinit();
            if (failure.transaction) |*transaction| {
                _ = transaction.rollback() catch unreachable;
                var retained_log = transaction.takePatchLog();
                retained_log.deinit();
                transaction.deinitClosed();
            }
            return failure.err;
        },
    }
    var metadata = try document.getChangesMeta(gpa, &.{});
    defer metadata.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), metadata.items.items.len);
    const readonly = @import("read.zig");
    const keep = (try readonly.get(&document, .root, .{ .key = "keep" })) orelse
        return error.TestUnexpectedResult;
    const first = (try readonly.get(&document, .root, .{ .key = "first" })) orelse
        return error.TestUnexpectedResult;
    const second = (try readonly.get(&document, .root, .{ .key = "second" })) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 1), keep.value.scalar.int);
    try testing.expectEqual(@as(i64, 2), first.value.scalar.int);
    try testing.expect(second.value.scalar.bool_value);
    try testing.expect(try document.ops.validateOpOrder());
    try testing.expect((try document.ops.validateTopIndex()) == null);
}

test "raw object import distinguishes syntax from unresolved identity" {
    const gpa = testing.allocator;
    var document = try Document.init(gpa, testing.io);
    defer document.deinit();
    const root_obj = try document.importObj(gpa, "_root");
    try testing.expect(root_obj == .root);
    const resolved_root = try document.import(gpa, "_root");
    try testing.expect(resolved_root.id == .root);
    try testing.expectEqual(ObjType.map, resolved_root.object_type);
    try testing.expectError(error.InvalidObjIdFormat, document.importObj(gpa, "invalid"));
    try testing.expectError(error.InvalidObjIdFormat, document.importObj(gpa, "1@zz"));
    try testing.expectError(error.InvalidObjId, document.importObj(gpa, "1@ffff"));
    const Tx = @import("transact.zig").Transaction;
    const object = blk: {
        var tx = try Tx.open(gpa, &document);
        defer tx.deinit() catch @panic("testing allocator cannot refuse rollback");
        const made = try tx.putObject(.root, .{ .key = "list" }, .list);
        _ = try tx.put(.root, .{ .key = "scalar" }, .{ .int = 7 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        break :blk made;
    };
    const spelling = try object.toString(gpa);
    defer gpa.free(spelling);
    const imported = try document.import(gpa, spelling);
    try testing.expect(imported.id.eql(object));
    try testing.expectEqual(ObjType.list, imported.object_type);
    const actor = document.ops.lookupActor(document.getActorId()).?;
    const scalar = document.idToExid(OpId.init(2, @intCast(actor)));
    const scalar_spelling = try scalar.toString(gpa);
    defer gpa.free(scalar_spelling);
    try testing.expectError(error.InvalidObjId, document.import(gpa, scalar_spelling));
}

test "diagnostic writers expose actors and changed scalar columns" {
    const gpa = testing.allocator;
    const Tx = @import("transact.zig").Transaction;
    var left = try Document.init(gpa, testing.io);
    defer left.deinit();
    left.setActorId(.{ .bytes = actor_a });
    {
        var tx = try Tx.open(gpa, &left);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "value" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }

    var equal = try left.clone(gpa);
    defer equal.deinit();
    var equal_buffer: [128]u8 = undefined;
    var equal_writer: std.Io.Writer = .fixed(&equal_buffer);
    try left.diffOpSet(gpa, &equal, &equal_writer);
    try testing.expectEqual(@as(usize, 0), std.Io.Writer.buffered(&equal_writer).len);

    var dump_buffer: [4096]u8 = undefined;
    var dump_writer: std.Io.Writer = .fixed(&dump_buffer);
    try left.dump(gpa, &dump_writer);
    const dump_bytes = std.Io.Writer.buffered(&dump_writer);
    var actor_buffer: [128]u8 = undefined;
    var actor_writer: std.Io.Writer = .fixed(&actor_buffer);
    try actor_writer.print("{x}", .{actor_a});
    try testing.expect(std.mem.indexOf(u8, dump_bytes, std.Io.Writer.buffered(&actor_writer)) != null);
    var left_columns = try left.ops.exportColumns(gpa);
    defer left_columns.deinit(gpa);
    for (left_columns.cols.columns) |column| {
        const bytes = try column.range.slice(left_columns.data);
        var column_buffer: [512]u8 = undefined;
        var column_writer: std.Io.Writer = .fixed(&column_buffer);
        try column_writer.print("{x}", .{column.spec.raw});
        try testing.expect(std.mem.indexOf(u8, dump_bytes, std.Io.Writer.buffered(&column_writer)) != null);
        var value_buffer: [512]u8 = undefined;
        var value_writer: std.Io.Writer = .fixed(&value_buffer);
        try value_writer.print("{x}", .{bytes});
        try testing.expect(std.mem.indexOf(u8, dump_bytes, std.Io.Writer.buffered(&value_writer)) != null);
    }

    var right = try Document.init(gpa, testing.io);
    defer right.deinit();
    right.setActorId(.{ .bytes = actor_a });
    {
        var tx = try Tx.open(gpa, &right);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "value" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    var right_columns = try right.ops.exportColumns(gpa);
    defer right_columns.deinit(gpa);
    try testing.expectEqual(left_columns.cols.columns.len, right_columns.cols.columns.len);
    var diff_buffer: [2048]u8 = undefined;
    var diff_writer: std.Io.Writer = .fixed(&diff_buffer);
    try left.diffOpSet(gpa, &right, &diff_writer);
    const diff_bytes = std.Io.Writer.buffered(&diff_writer);
    var changed_columns: usize = 0;
    for (left_columns.cols.columns, right_columns.cols.columns) |left_column, right_column| {
        try testing.expectEqual(left_column.spec.raw, right_column.spec.raw);
        const left_bytes = try left_column.range.slice(left_columns.data);
        const right_bytes = try right_column.range.slice(right_columns.data);
        if (std.mem.eql(u8, left_bytes, right_bytes)) continue;
        changed_columns += 1;
        try testing.expect(left_bytes.len > 0 and right_bytes.len > 0);
        var id_buffer: [128]u8 = undefined;
        var id_writer: std.Io.Writer = .fixed(&id_buffer);
        try id_writer.print("{x}", .{left_column.spec.raw});
        try testing.expect(std.mem.indexOf(u8, diff_bytes, std.Io.Writer.buffered(&id_writer)) != null);
        var left_buffer: [256]u8 = undefined;
        var left_writer: std.Io.Writer = .fixed(&left_buffer);
        try left_writer.print("{x}", .{left_bytes});
        try testing.expect(std.mem.indexOf(u8, diff_bytes, std.Io.Writer.buffered(&left_writer)) != null);
        var right_buffer: [256]u8 = undefined;
        var right_writer: std.Io.Writer = .fixed(&right_buffer);
        try right_writer.print("{x}", .{right_bytes});
        try testing.expect(std.mem.indexOf(u8, diff_bytes, std.Io.Writer.buffered(&right_writer)) != null);
    }
    try testing.expectEqual(@as(usize, 1), changed_columns);
    var tiny_buffer: [0]u8 = .{};
    var tiny_writer: std.Io.Writer = .fixed(&tiny_buffer);
    try testing.expectError(error.WriteFailed, left.dump(gpa, &tiny_writer));
    var empty = try Document.init(gpa, testing.io);
    defer empty.deinit();
    var absent_buffer: [4096]u8 = undefined;
    var absent_writer: std.Io.Writer = .fixed(&absent_buffer);
    try left.diffOpSet(gpa, &empty, &absent_writer);
    const absent = std.Io.Writer.buffered(&absent_writer);
    try testing.expect(absent.len != 0);
}

test "load options logs current snapshot into caller owned log" {
    const gpa = testing.allocator;
    var source = try buildSample(gpa);
    defer source.deinit();
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    var log = patchesmod.PatchLog.active(gpa);
    defer log.deinit();
    var loaded = try Document.loadWithOptions(gpa, testing.io, bytes, .{ .patch_log = &log });
    defer loaded.deinit();
    var patches = try loaded.makePatches(&log);
    defer patches.deinit();
    try testing.expect(patches.len() > 0);
    // Log ownership stays with the caller and its events can be read again.
    var again = try loaded.makePatches(&log);
    defer again.deinit();
    try testing.expectEqual(patches.len(), again.len());
    try source.debugCmp(&loaded);
}

test "combined multi object incoming apply stays usable after every allocation refusal" {
    // Concurrent map winners, counter edges and separated sequence runs share one publication.
    const observer = testing.allocator;
    const Tx = @import("transact.zig").Transaction;
    const readonly = @import("read.zig");
    var base = try Document.init(observer, testing.io);
    defer base.deinit();
    base.setActorId(.{ .bytes = actor_a });
    var list: ExId = undefined;
    var text: ExId = undefined;
    var nested: ExId = undefined;
    {
        var tx = try Tx.open(observer, &base);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "winner" }, .{ .int = 0 });
        _ = try tx.put(.root, .{ .key = "count" }, .{ .counter = value.ScalarValue.Counter.init(10) });
        list = try tx.putObject(.root, .{ .key = "list" }, .list);
        for ([_][]const u8{ "a", "b", "c" }, 0..) |entry, index| {
            _ = try tx.insert(list, index, .{ .str = entry });
        }
        text = try tx.putObject(.root, .{ .key = "text" }, .text);
        try tx.spliceText(text, 0, 0, "abc");
        nested = try tx.putObject(.root, .{ .key = "nested" }, .map);
        _ = try tx.put(nested, .{ .key = "old" }, .{ .bool_value = true });
        var committed = try tx.commit();
        defer committed.deinit(observer);
    }
    const snapshot = try base.save(observer);
    defer observer.free(snapshot);
    const base_heads = try base.getHeads(observer);
    defer observer.free(base_heads);
    var first = try base.clone(observer);
    defer first.deinit();
    first.setActorId(.{ .bytes = "\x00" });
    {
        var tx = try Tx.open(observer, &first);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "winner" }, .{ .int = 1 });
        _ = try tx.increment(.root, .{ .key = "count" }, 7);
        _ = try tx.insert(list, 0, .{ .str = "early" });
        _ = try tx.insert(list, 4, .{ .str = "late" });
        try tx.spliceText(text, 1, 1, "XYZ");
        try tx.mark(text, 0, 5, "bold", .none, .{ .bool_value = true });
        try tx.unmark(text, 1, 3, .none, "bold", null);
        _ = try tx.put(nested, .{ .key = "new" }, .{ .str = "nested value" });
        var committed = try tx.commit();
        defer committed.deinit(observer);
    }
    var second = try base.clone(observer);
    defer second.deinit();
    second.setActorId(.{ .bytes = actor_c });
    {
        var tx = try Tx.open(observer, &second);
        defer tx.deinit() catch unreachable;
        _ = try tx.put(.root, .{ .key = "winner" }, .{ .int = 2 });
        var committed = try tx.commit();
        defer committed.deinit(observer);
    }
    var first_changes = try first.getChanges(observer, base_heads);
    defer first_changes.deinit(observer);
    var second_changes = try second.getChanges(observer, base_heads);
    defer second_changes.deinit(observer);
    var incoming: std.ArrayList(Change) = .empty;
    defer incoming.deinit(observer);
    for (first_changes.slice()) |built| try incoming.append(observer, built.change);
    for (second_changes.slice()) |built| try incoming.append(observer, built.change);
    var expected = try base.clone(observer);
    defer expected.deinit();
    _ = try expected.applyChanges(observer, incoming.items);
    var finished = false;
    for (0..4096) |failure_index| {
        var failing = testing.FailingAllocator.init(observer, .{
            .fail_index = std.math.maxInt(usize),
        });
        const gpa = failing.allocator();
        var target = try Document.load(gpa, testing.io, snapshot, .unicode_code_point);
        defer target.deinit();
        failing.fail_index = failing.alloc_index + failure_index;
        const applied = target.applyChanges(gpa, incoming.items);
        failing.fail_index = std.math.maxInt(usize);
        var refused = false;
        if (applied) |_| {} else |failure| {
            switch (failure) {
                error.OutOfMemory => refused = true,
                else => return failure,
            }
        }
        var metadata = try target.getChangesMeta(observer, &.{});
        defer metadata.deinit(observer);
        for (metadata.items.items) |meta| {
            var encoded = (try target.getChangeByHash(observer, meta.hash)).?;
            defer encoded.deinit(observer);
            try testing.expectEqualSlices(u8, meta.hash.bytes[0..], encoded.change.hash.bytes[0..]);
        }
        const saved = try target.save(observer);
        defer observer.free(saved);
        var loaded = try Document.load(observer, testing.io, saved, .unicode_code_point);
        defer loaded.deinit();
        try target.debugCmp(&loaded);
        // Retrying the full peer batch must neither lose accepted operations nor duplicate them.
        _ = try target.applyChanges(observer, incoming.items);
        try target.debugCmp(&expected);
        try testing.expectEqual(@as(i64, 17), (try readonly.get(&target, .root, .{ .key = "count" })).?.value.scalar.counter.current);
        const visible = try readonly.text(&target, text, observer);
        defer observer.free(visible);
        try testing.expectEqualStrings("aXYZc", visible);
        const retry_saved = try target.save(observer);
        defer observer.free(retry_saved);
        var retry_loaded = try Document.load(observer, testing.io, retry_saved, .unicode_code_point);
        defer retry_loaded.deinit();
        try target.debugCmp(&retry_loaded);
        const expected_span_texts = [_][]const u8{ "a", "XY", "Zc" };
        for ([_]*Document{ &target, &expected, &retry_loaded }) |document_with_marks| {
            const marks = try readonly.marks(document_with_marks, text, observer);
            defer observer.free(marks);
            try testing.expectEqual(@as(usize, 2), marks.len);
            var left_mark = false;
            var right_mark = false;
            for (marks) |mark| {
                try testing.expectEqualStrings("bold", mark.name);
                try testing.expect(mark.value == .bool_value and mark.value.bool_value);
                if (mark.start == 0 and mark.end == 1) {
                    left_mark = true;
                } else if (mark.start == 3 and mark.end == 5) {
                    right_mark = true;
                } else {
                    return error.UnexpectedMarkRange;
                }
            }
            try testing.expect(left_mark and right_mark);

            var spans = try readonly.spans(document_with_marks, text, observer);
            defer spans.deinit();
            var span_index: usize = 0;
            while (try spans.next()) |next_span| {
                var span = next_span;
                defer span.deinit(observer);
                try testing.expect(span_index < expected_span_texts.len);
                switch (span) {
                    .text => |text_span| {
                        try testing.expectEqualStrings(expected_span_texts[span_index], text_span.text);
                        if (span_index == 1) {
                            try testing.expect(text_span.marks == null);
                        } else {
                            const span_marks = text_span.marks orelse return error.MissingSpanMarks;
                            try testing.expectEqual(@as(usize, 1), span_marks.len());
                            var mark_iter = span_marks.iter();
                            const span_mark = mark_iter.next() orelse return error.MissingSpanMark;
                            try testing.expectEqualStrings("bold", span_mark.name);
                            try testing.expect(span_mark.value == .bool_value and span_mark.value.bool_value);
                            try testing.expect(mark_iter.next() == null);
                        }
                    },
                    .block => return error.UnexpectedTextBlock,
                }
                span_index += 1;
            }
            try testing.expectEqual(expected_span_texts.len, span_index);

            var hydrated = try readonly.hydrate(document_with_marks, text, null, observer);
            defer hydrated.deinit();
            try testing.expect(hydrated == .object);
            try testing.expect(hydrated.object == .text);
            try testing.expectEqual(@as(usize, 1), hydrated.object.text.marks.len());
            var hydrated_iter = hydrated.object.text.marks.iter();
            const hydrated_mark = hydrated_iter.next() orelse return error.MissingHydratedMark;
            try testing.expectEqualStrings("bold", hydrated_mark.name);
            try testing.expect(hydrated_mark.value == .bool_value and hydrated_mark.value.bool_value);
            try testing.expect(hydrated_iter.next() == null);
        }
        {
            var tx = try Tx.open(observer, &target);
            defer tx.deinit() catch unreachable;
            try tx.mark(text, 0, 5, "bold", .none, .{ .bool_value = true });
            var committed = try tx.commit();
            defer committed.deinit(observer);
        }
        const extended_marks = try readonly.marks(&target, text, observer);
        defer observer.free(extended_marks);
        try testing.expectEqual(@as(usize, 1), extended_marks.len);
        try testing.expectEqual(@as(usize, 0), extended_marks[0].start);
        try testing.expectEqual(@as(usize, 5), extended_marks[0].end);
        try testing.expectEqualStrings("bold", extended_marks[0].name);
        try testing.expect(extended_marks[0].value == .bool_value and extended_marks[0].value.bool_value);
        _ = try target.putActorRef(observer, .{ .bytes = "" });
        _ = try commitRootPut(observer, &target, "later");
        const later_save = try target.save(observer);
        defer observer.free(later_save);
        var later_load = try Document.load(observer, testing.io, later_save, .unicode_code_point);
        defer later_load.deinit();
        try target.debugCmp(&later_load);
        const saved_marks = try readonly.marks(&later_load, text, observer);
        defer observer.free(saved_marks);
        try testing.expectEqual(@as(usize, 1), saved_marks.len);
        try testing.expectEqual(@as(usize, 0), saved_marks[0].start);
        try testing.expectEqual(@as(usize, 5), saved_marks[0].end);
        try testing.expectEqualStrings("bold", saved_marks[0].name);
        try testing.expect(saved_marks[0].value == .bool_value and saved_marks[0].value.bool_value);
        if (!refused) {
            finished = true;
            break;
        }
    }
    try testing.expect(finished);
}

test "pending clone owns rows and exact committed footer after source teardown" {
    // A raw clone retains pending rows without publishing a new history node.
    const gpa = testing.allocator;
    const Tx = @import("transact.zig").Transaction;
    const readonly = @import("read.zig");
    var source = try Document.init(gpa, testing.io);
    var source_live = true;
    defer if (source_live) source.deinit();
    // Seed IDs in an order different from row traversal, including unused keys.
    const seeded_keys = [_][]const u8{ "pending", "unused\x00key", "", "é", "Pending" };
    const source_table = source.strings.table();
    for (seeded_keys, 0..) |key, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), try source_table.intern(source_table.ctx, key, gpa));
    }
    var generated_key: [64]u8 = undefined;
    for (0..256) |i| {
        const key = try std.fmt.bufPrint(&generated_key, "unused-common-prefix-{d}", .{i});
        try testing.expectEqual(
            @as(u32, @intCast(seeded_keys.len + i)),
            try source_table.intern(source_table.ctx, key, gpa),
        );
    }
    const actor = try source.putActorRef(gpa, .{ .bytes = actor_b });
    const specs = [_]OpSpec{
        .{ .ctr = 17, .key = KeyRef.fromStr("incoming"), .value = .{ .str = "value" } },
    };
    const ops = try buildOps(gpa, actor, &specs);
    defer freeChangeOps(gpa, ops);
    var footer: std.ArrayList(u8) = .empty;
    defer footer.deinit(gpa);
    try encodeAuthorFooter(gpa, &footer, "incoming author");
    try footer.appendSlice(gpa, &.{ 0xfd, 0x00, 0x81, 0x7f });
    var incoming = try encodeOneChange(gpa, source.ops.actors.items, .{
        .actor = actor,
        .seq = 1,
        .start_op = 17,
        .max_op = 17,
        .time = 123,
        .message = "opaque history",
        .deps = &.{},
        .footer = footer.items,
    }, ops);
    defer incoming.deinit(gpa);
    _ = try source.applyChanges(gpa, &.{incoming.change});
    // Changing author mints an actor (`automerge.rs:389-396`); choose the
    // deterministic local actor only after that setter has completed.
    try source.setAuthor(gpa, "local author");
    source.setActorId(.{ .bytes = actor_a });
    var tx = try Tx.open(gpa, &source);
    defer tx.deinit() catch unreachable;
    _ = try tx.put(.root, .{ .key = "pending" }, .{ .str = "retained" });
    _ = try tx.put(.root, .{ .key = "incoming" }, .{ .str = "pending replacement" });
    const CloneAttempt = struct {
        fn run(allocator: Allocator, original: *Document) !void {
            var cloned = try original.clonePending(allocator);
            defer cloned.deinit();
            try testing.expectEqual(original.ops.len(), cloned.ops.len());
            try testing.expectEqual(original.graph.len(), cloned.graph.len());
            try testing.expectEqual(cloned.graph.len(), cloned.node_info.items.len);
            try testing.expectEqualStrings(original.getActorId().bytes, cloned.getActorId().bytes);
            const before = original.strings.table();
            const after = cloned.strings.table();
            try testing.expectEqual(original.strings.count(), cloned.strings.count());
            for (0..original.strings.count()) |i| {
                const id: u32 = @intCast(i);
                const key = before.resolve(before.ctx, id);
                try testing.expectEqualStrings(key, after.resolve(after.ctx, id));
                try testing.expectEqual(id, try after.intern(after.ctx, key, allocator));
            }
            var history = (try cloned.getChangeByHash(allocator, original.graph.getHeads()[0])).?;
            defer history.deinit(allocator);
            try testing.expectEqual(@as(u64, 17), history.change.start_op);
            try testing.expectEqual(@as(u64, 17), history.change.max_op);
        }
    };
    try testing.checkAllAllocationFailures(gpa, CloneAttempt.run, .{&source});
    var copy = try source.clonePending(gpa);
    defer copy.deinit();
    try testing.expectEqual(@as(usize, 1), source.graph.len());
    try testing.expectEqual(@as(usize, 1), copy.graph.len());
    try testing.expectEqual(copy.graph.len(), copy.node_info.items.len);
    try testing.expectEqual(@as(usize, 3), copy.ops.len());
    try testing.expect(!tx.closed);
    try testing.expect(source.patch_identity != copy.patch_identity);
    _ = try tx.rollback();
    try testing.expect((try readonly.get(&source, .root, .{ .key = "pending" })) == null);
    try testing.expectEqualStrings(
        "value",
        (try readonly.get(&source, .root, .{ .key = "incoming" })).?.value.scalar.str,
    );
    source.deinit();
    source_live = false;
    const copied_table = copy.strings.table();
    for (seeded_keys, 0..) |key, i| {
        const id: u32 = @intCast(i);
        try testing.expectEqualStrings(key, copied_table.resolve(copied_table.ctx, id));
        try testing.expectEqual(id, try copied_table.intern(copied_table.ctx, key, gpa));
    }
    for (0..256) |i| {
        const key = try std.fmt.bufPrint(&generated_key, "unused-common-prefix-{d}", .{i});
        const id: u32 = @intCast(seeded_keys.len + i);
        try testing.expectEqualStrings(key, copied_table.resolve(copied_table.ctx, id));
        try testing.expectEqual(id, try copied_table.intern(copied_table.ctx, key, gpa));
    }
    try testing.expectEqualStrings(actor_a, copy.getActorId().bytes);
    try testing.expectEqualStrings("local author", copy.getAuthor().?);
    try testing.expectEqualStrings("retained", (try readonly.get(&copy, .root, .{ .key = "pending" })).?.value.scalar.str);
    try testing.expectEqualStrings(
        "pending replacement",
        (try readonly.get(&copy, .root, .{ .key = "incoming" })).?.value.scalar.str,
    );
    try testing.expectEqualStrings(
        "incoming author",
        copy.getAuthorForActor(.{ .bytes = actor_b }).?,
    );
    var metadata = (try copy.getChangeMetaByHash(gpa, incoming.change.hash)).?;
    defer metadata.deinit(gpa);
    try testing.expectEqual(@as(u64, 17), metadata.start_op);
    try testing.expectEqual(@as(u64, 17), metadata.max_op);
    try testing.expectEqual(@as(u64, 1), metadata.max_op - metadata.start_op + 1);
    try testing.expectEqualStrings("incoming author", metadata.author.?);
    try testing.expectEqualSlices(u8, footer.items, metadata.extra);
    var rebuilt = (try copy.getChangeByHash(gpa, incoming.change.hash)).?;
    defer rebuilt.deinit(gpa);
    try testing.expectEqualSlices(u8, incoming.change.hash.bytes[0..], rebuilt.change.hash.bytes[0..]);
    try testing.expectEqualSlices(u8, footer.items, changeFooter(rebuilt.change).?);
    try testing.expectEqualSlices(u8, incoming.change.bytes, rebuilt.change.bytes);
}

test "historical head cache reuses owned keys without invalidating other walks" {
    // Repeating a historical read must not allocate. Its key is owned, and
    // selecting another head set does not release clocks borrowed by readers.
    const observer = testing.allocator;
    var failing = testing.FailingAllocator.init(observer, .{
        .fail_index = std.math.maxInt(usize),
    });
    const gpa = failing.allocator();
    var document = try buildSample(gpa);
    defer document.deinit();
    const heads = try document.getHeads(observer);
    defer observer.free(heads);
    const first = try document.clockAtScope(gpa, heads);
    var expected = try document.graph.clockAt(observer, heads);
    defer expected.deinit();
    heads[0] = ChangeHash.zero;
    _ = try document.clockAtScope(gpa, &.{});
    for (1..65) |index| {
        var historical = ChangeHash.zero;
        historical.bytes[0] = @intCast(index);
        _ = try document.clockAtScope(gpa, &.{historical});
    }
    failing.fail_index = failing.alloc_index;
    const repeated = (try document.clockAtScope(gpa, document.graph.getHeads())).*;
    try testing.expect(first.*.eql(expected));
    try testing.expect(repeated.eql(expected));
}

test "raw logged incremental replacement and merge preserve the internal log owner" {
    // These borrowed routes deliberately pass the exact internal log address.
    // Empty-document replacement must transfer that owner before old teardown.
    const gpa = testing.allocator;
    const readonly = @import("read.zig");
    var source = try buildSample(gpa);
    defer source.deinit();
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    var target = try Document.init(gpa, testing.io);
    defer target.deinit();
    const identity = target.patchIdentity();
    target.patch_log.setActive(true);
    const added = try target.loadIncrementalWithPatchLog(gpa, bytes, &target.patch_log);
    try testing.expectEqual(source.len(), added);
    try testing.expectEqual(identity, target.patchIdentity());
    var snapshot = try target.makePatches(&target.patch_log);
    defer snapshot.deinit();
    try testing.expect(snapshot.len() != 0);
    try testing.expectEqual(@as(usize, 0), try target.loadIncrementalWithPatchLog(gpa, bytes, &target.patch_log));
    const before = try source.getHeads(gpa);
    defer gpa.free(before);
    _ = try addKeyChange(&source, gpa, actor_a, 2, 16, "logged merge", before);
    const heads = try target.mergeWithPatchLog(gpa, &source, &target.patch_log);
    defer gpa.free(heads);
    try testing.expect(sameHashList(heads, source.graph.getHeads()));
    try testing.expect((try readonly.get(&target, .root, .{ .key = "logged merge" })) != null);
    var merged = try target.makePatches(&target.patch_log);
    defer merged.deinit();
    try testing.expect(merged.len() != 0);
    var unrelated = try Document.init(gpa, testing.io);
    defer unrelated.deinit();
    const reused_heads = try unrelated.mergeWithPatchLog(gpa, &source, &target.patch_log);
    defer gpa.free(reused_heads);
    try testing.expect(sameHashList(reused_heads, source.graph.getHeads()));
    try target.debugCmp(&unrelated);
    var retained = try target.makePatches(&target.patch_log);
    defer retained.deinit();
    try testing.expect(retained.len() >= merged.len());
}

test "raw hydrate initialization exposes primary refusal and recoverable owner at every OOM" {
    // Observe the same raw owner after every opening, producer and commit refusal.
    // Recovery remains explicit; disabling injection allows the retained journal
    // to complete rollback rather than hiding a secondary refusal.
    const observer = testing.allocator;
    const hydration = @import("hydrate.zig");
    const readonly = @import("read.zig");
    var map = hydration.Map.init(observer, .root);
    defer map.deinit();
    try map.putOwned("first", .init(hydration.Value.fromScalar(.{ .int = 2 }), false));
    try map.putOwned("second", .init(hydration.Value.fromScalar(.{ .bool_value = true }), false));
    var completed = false;
    var saw_refusal = false;
    for (0..4096) |offset| {
        var failing = testing.FailingAllocator.init(observer, .{
            .fail_index = std.math.maxInt(usize),
        });
        const gpa = failing.allocator();
        var document = try Document.init(gpa, testing.io);
        defer document.deinit();
        _ = try commitRootPut(gpa, &document, "keep");
        failing.fail_index = failing.alloc_index + offset;
        const attempted = document.initFromHydrate(gpa, &map);
        failing.fail_index = std.math.maxInt(usize);
        if (attempted) |returned| {
            var outcome = returned;
            switch (outcome) {
                .success => |*success| {
                    defer success.patch_log.deinit();
                    try testing.expect(success.hash != null);
                    try testing.expectEqual(@as(usize, 2), document.graph.len());
                    try testing.expect((try readonly.get(
                        &document,
                        .root,
                        .{ .key = "second" },
                    )).?.value.scalar.bool_value);
                    completed = true;
                },
                .failure => |*failure| {
                    saw_refusal = true;
                    defer failure.patch_log.deinit();
                    // Release a retained recovery owner before any assertion
                    // can return, including commit failures with a body result.
                    const retained = failure.transaction != null;
                    var cancelled = failure.cancelled;
                    if (failure.transaction) |*transaction| {
                        cancelled = try transaction.rollback();
                        var log = transaction.takePatchLog();
                        log.deinit();
                        transaction.deinitClosed();
                    }
                    try testing.expectEqual(error.OutOfMemory, failure.err);
                    if (failure.result != null) {
                        // The body completed; the refusal was during commit.
                        try testing.expectEqual(@as(usize, 2), cancelled);
                    }
                    if (retained) {
                        try testing.expectEqual(
                            @as(?@import("transaction.zig").TransactionError, error.OutOfMemory),
                            failure.rollback_error,
                        );
                    } else {
                        try testing.expect(failure.rollback_error == null);
                    }
                },
            }
        } else |failure| {
            saw_refusal = true;
            try testing.expectEqual(error.OutOfMemory, failure);
        }
        try testing.expectEqual(@as(i64, 1), (try readonly.get(&document, .root, .{ .key = "keep" })).?.value.scalar.int);
        try testing.expectEqual(document.graph.len(), document.node_info.items.len);
        for (0..document.graph.len()) |index| {
            const node = document.graph.nodeAt(@intCast(index)).?;
            try testing.expect(document.node_info.items[index].start_op <= node.meta.max_op);
        }
        if (completed) break;
        try testing.expectEqual(@as(usize, 1), document.graph.len());
        try testing.expect((try readonly.get(&document, .root, .{ .key = "first" })) == null);
        try testing.expect((try readonly.get(&document, .root, .{ .key = "second" })) == null);
        const saved = try document.save(observer);
        defer observer.free(saved);
        var loaded = try Document.load(observer, testing.io, saved, document.textEncoding());
        defer loaded.deinit();
        try document.debugCmp(&loaded);
        var retry = try document.initFromHydrate(gpa, &map);
        switch (retry) {
            .success => |*success| {
                defer success.patch_log.deinit();
                try testing.expect(success.hash != null);
                try testing.expectEqual(@as(usize, 2), document.graph.len());
                try testing.expectEqual(document.graph.len(), document.node_info.items.len);
                try testing.expectEqual(
                    @as(i64, 2),
                    (try readonly.get(&document, .root, .{ .key = "first" })).?.value.scalar.int,
                );
                try testing.expect((try readonly.get(
                    &document,
                    .root,
                    .{ .key = "second" },
                )).?.value.scalar.bool_value);
            },
            .failure => |*failure| {
                defer failure.patch_log.deinit();
                if (failure.transaction) |*transaction| {
                    _ = try transaction.rollback();
                    var log = transaction.takePatchLog();
                    log.deinit();
                    transaction.deinitClosed();
                }
                return error.RetryFailedWithoutAllocationRefusal;
            },
        }
    }
    try testing.expect(saw_refusal);
    try testing.expect(completed);
}

test "raw duplicate sequence refusal publishes its prepared queued branch pruning" {
    const gpa = testing.allocator;
    var document = try Document.init(gpa, testing.io);
    defer document.deinit();
    var original = try handChange(&document, gpa, actor_a, 1, 1, &.{}, null, &.{});
    defer original.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), try document.applyChanges(gpa, &.{original.change}));
    var missing = ChangeHash.zero;
    missing.bytes[0] = 99;
    var orphan = try handChange(&document, gpa, actor_a, 3, 1, &.{missing}, null, &.{});
    defer orphan.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), try document.applyChanges(gpa, &.{orphan.change}));
    try testing.expectEqual(@as(usize, 1), document.queue.len());
    var duplicate = try handChange(&document, gpa, actor_a, 1, 1, &.{}, "different", &.{});
    defer duplicate.deinit(gpa);
    try testing.expectError(error.DuplicateSeqNumber, document.applyChanges(gpa, &.{duplicate.change}));
    try testing.expectEqual(@as(usize, 0), document.queue.len());
    try testing.expectEqual(@as(usize, 1), document.graph.len());
    try testing.expectEqual(@as(usize, 1), document.node_info.items.len);
    try testing.expectEqual(@as(usize, 0), document.ops.len());
}

test "caller-owned loader logs retain their own allocator for nested path hints" {
    const log_gpa = testing.allocator;
    var source = try buildSample(log_gpa);
    defer source.deinit();
    const bytes = try source.save(log_gpa);
    defer log_gpa.free(bytes);
    var owner_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer testing.expect(owner_allocator.deinit() == 0) catch
        @panic("loader document allocator leaked");
    const owner_gpa = owner_allocator.allocator();
    var log = patchesmod.PatchLog.inactive(log_gpa);
    defer log.deinit();
    log.setActive(true);
    var loaded = try Document.loadWithOptions(owner_gpa, testing.io, bytes, .{
        .patch_log = &log,
    });
    defer loaded.deinit();
    var patches = try loaded.makePatches(&log);
    defer patches.deinit();
    try testing.expect(patches.len() != 0);
    try source.debugCmp(&loaded);
}

test "stateless allocator merge preserves complete state heads and authored footer cleanup" {
    const gpa = std.heap.c_allocator;
    const Tx = @import("transact.zig").Transaction;
    const reader = @import("read.zig");
    const count = 1024;
    var base = try Document.init(gpa, testing.io);
    defer base.deinit();
    try base.setAuthor(gpa, "base author");
    base.setActorId(.{ .bytes = actor_a });
    {
        var tx = try Tx.open(gpa, &base);
        defer tx.deinit() catch @panic("stateless allocator rollback refused");
        _ = try tx.put(.root, .{ .key = "base" }, .{ .int = 1 });
        var committed = try tx.commit();
        defer committed.deinit(gpa);
    }
    const seed = try base.save(gpa);
    defer gpa.free(seed);
    var left = try Document.load(gpa, testing.io, seed, base.textEncoding());
    defer left.deinit();
    var right = try Document.load(gpa, testing.io, seed, base.textEncoding());
    defer right.deinit();
    try left.setAuthor(gpa, "base author");
    left.setActorId(.{ .bytes = actor_a });
    try right.setAuthor(gpa, "right author");
    right.setActorId(.{ .bytes = actor_b });
    var branch_heads: [2]ChangeHash = undefined;
    {
        var tx = try Tx.open(gpa, &left);
        defer tx.deinit() catch @panic("stateless allocator rollback refused");
        for (0..count) |index| {
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "left-{d}", .{index});
            _ = try tx.put(.root, .{ .key = key }, .{ .int = @intCast(index) });
        }
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        branch_heads[0] = committed.hash.?;
    }
    {
        var tx = try Tx.open(gpa, &right);
        defer tx.deinit() catch @panic("stateless allocator rollback refused");
        for (0..count) |index| {
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "right-{d}", .{index});
            _ = try tx.put(.root, .{ .key = key }, .{ .int = @intCast(index) });
        }
        var committed = try tx.commit();
        defer committed.deinit(gpa);
        branch_heads[1] = committed.hash.?;
    }
    const merged = try left.merge(gpa, &right);
    defer gpa.free(merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    for (branch_heads) |expected| {
        var found = false;
        for (merged) |actual| found = found or actual.eql(expected);
        try testing.expect(found);
    }
    try testing.expectEqual(@as(usize, 2 * count + 1), try reader.length(&left, .root));
    try testing.expectEqual(@as(i64, count - 1), (try reader.get(&left, .root, .{ .key = "right-1023" })).?.value.scalar.int);
    var metadata = (try left.getChangeMetaByHash(gpa, branch_heads[1])).?;
    defer metadata.deinit(gpa);
    try testing.expectEqualStrings("right author", metadata.author.?);
    const saved = try left.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, testing.io, saved, left.textEncoding());
    defer loaded.deinit();
    try left.debugCmp(&loaded);
}

test "selected history batches preserve request order and own reference bytes after teardown" {
    // Reverse dependency order is legal for this reader, not an apply order.
    const gpa = testing.allocator;
    const expected_hex = [_][]const u8{ reference_change_1, reference_change_0 };
    var selected = blk: {
        var source = try buildOracleDocument(gpa);
        defer source.deinit();
        const first = try err.hexFrom(gpa, reference_change_0_hash);
        defer gpa.free(first);
        const second = try err.hexFrom(gpa, reference_change_1_hash);
        defer gpa.free(second);
        var hashes: [2]ChangeHash = undefined;
        @memcpy(&hashes[0].bytes, second);
        @memcpy(&hashes[1].bytes, first);
        break :blk try source.getChangesByHashes(gpa, &hashes);
    };
    defer selected.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), selected.len());
    for (selected.slice(), expected_hex) |built, hex| {
        const framed = try err.hexFrom(gpa, hex);
        defer gpa.free(framed);
        var expected = try changechunk.parseFramedChunk(try chunkmod.parseChunk(framed), gpa);
        defer expected.deinit(gpa);
        const change = expected.parsed.change;
        try testing.expectEqualSlices(u8, change.bytes, built.body);
        try testing.expect(change.hash.eql(built.change.hash));
        const actors = try gpa.alloc(ActorIdx, change.other_actors.len + 1);
        defer gpa.free(actors);
        for (actors, 0..) |*actor, i| actor.* = @intCast(i);
        const expected_ops = try decodeChangeOps(gpa, change, actors);
        defer freeChangeOps(gpa, expected_ops);
        const actual_ops = try decodeChangeOps(gpa, built.change, actors);
        defer freeChangeOps(gpa, actual_ops);
        try testing.expectEqualDeep(expected_ops, actual_ops);
        try testing.expectEqual(
            (try change.withOpCount(expected_ops.len)).max_op,
            built.change.max_op,
        );
        const encoded = try built.change.encode(gpa);
        defer gpa.free(encoded);
        const expected_encoded = try change.encode(gpa);
        defer gpa.free(expected_encoded);
        try testing.expectEqualSlices(u8, expected_encoded, encoded);
    }
}

fn selectedHistoryBatchAndFree(
    gpa: Allocator,
    source: *Document,
    hashes: []const ChangeHash,
) !void {
    var selected = try source.getChangesByHashes(gpa, hashes);
    defer selected.deinit(gpa);
    try testing.expectEqual(hashes.len, selected.len());
    for (selected.slice(), hashes) |built, hash| {
        try testing.expect(hash.eql(built.change.hash));
        const encoded = try built.change.encode(gpa);
        defer gpa.free(encoded);
        try testing.expectEqualSlices(u8, built.body, (try chunkmod.parseChunk(encoded)).data);
    }
}

test "selected history batches release partial results and remain readable after refusal" {
    const gpa = testing.allocator;
    var source = try buildOracleDocument(gpa);
    defer source.deinit();
    const hashes = try source.graph.getChanges(gpa, &.{});
    defer gpa.free(hashes);
    try selectedHistoryBatchAndFree(gpa, &source, &.{});
    const absent = ChangeHash{ .bytes = @splat(0x5a) };
    try testing.expectError(error.MissingDeps, source.getChangesByHashes(gpa, &.{ hashes[0], absent }));
    try testing.checkAllAllocationFailures(gpa, selectedHistoryBatchAndFree, .{ &source, hashes });
    try selectedHistoryBatchAndFree(gpa, &source, hashes);
}

fn duplicateHistoryDocument(gpa: Allocator) !Document {
    const trans = @import("transact.zig");
    var source = try buildOracleDocument(gpa);
    errdefer source.deinit();
    source.setActorId(.{ .bytes = "duplicate-history-actor" });
    var tx = try trans.Transaction.open(gpa, &source);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "title" }, .{ .str = "replaced" });
    var committed = try tx.commitWith(.{ .message = "cross-actor", .time = 17 });
    defer committed.deinit(gpa);
    _ = try source.emptyCommit(gpa, "empty", 18);
    return source;
}

fn expectSelectedHistoryMatches(
    gpa: Allocator,
    selected: *const Changes,
    hashes: []const ChangeHash,
    expected: *const Changes,
) !void {
    try testing.expectEqual(hashes.len, selected.len());
    for (selected.slice(), hashes) |built, hash| {
        try testing.expect(hash.eql(built.change.hash));
        const original = blk: {
            for (expected.slice()) |candidate| {
                if (candidate.change.hash.eql(hash)) break :blk candidate;
            }
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualSlices(u8, original.body, built.body);
        try testing.expectEqualDeep(original.change.other_actors, built.change.other_actors);
        try testing.expectEqual(original.change.max_op, built.change.max_op);
        const actors = try gpa.alloc(ActorIdx, original.change.other_actors.len + 1);
        defer gpa.free(actors);
        for (actors, 0..) |*actor, i| actor.* = @intCast(i);
        const expected_ops = try decodeChangeOps(gpa, original.change, actors);
        defer freeChangeOps(gpa, expected_ops);
        const actual_ops = try decodeChangeOps(gpa, built.change, actors);
        defer freeChangeOps(gpa, actual_ops);
        try testing.expectEqualDeep(expected_ops, actual_ops);
        try testing.expectEqual(expected_ops.len, try built.change.len(gpa));
        try testing.expectEqual(
            (try original.change.withOpCount(expected_ops.len)).max_op,
            built.change.max_op,
        );
        const encoded = try built.change.encode(gpa);
        defer gpa.free(encoded);
        const expected_encoded = try original.change.encode(gpa);
        defer gpa.free(expected_encoded);
        try testing.expectEqualSlices(u8, expected_encoded, encoded);
    }
}

test "duplicate selected history owns every nonempty and empty occurrence after teardown" {
    // Mixed request order and cross-actor predecessors exercise body and actor ownership.
    const gpa = testing.allocator;
    var expected: Changes = .{};
    defer expected.deinit(gpa);
    var requested: [8]ChangeHash = undefined;
    var selected = blk: {
        var source = try duplicateHistoryDocument(gpa);
        defer source.deinit();
        expected = try source.getChanges(gpa, &.{});
        const order = [_]usize{ 2, 3, 1, 2, 0, 3, 2, 1 };
        for (order, &requested) |index, *hash| hash.* = expected.at(index).hash;
        break :blk try source.getChangesByHashes(gpa, &requested);
    };
    defer selected.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), expected.len());
    try testing.expect(expected.at(2).other_actors.len != 0);
    try testing.expectEqual(@as(usize, 0), try expected.at(3).len(gpa));
    try testing.expectEqual(expected.at(3).start_op - 1, expected.at(3).max_op);
    for (expected.slice()[0..2], [_][]const u8{ reference_change_0, reference_change_1 }) |built, hex| {
        const framed = try err.hexFrom(gpa, hex);
        defer gpa.free(framed);
        // Normalize compressed framing before comparing the canonical change body.
        var reference = try changechunk.parseFramedChunk(try chunkmod.parseChunk(framed), gpa);
        defer reference.deinit(gpa);
        const change = reference.parsed.change;
        try testing.expectEqualSlices(u8, change.bytes, built.body);
        try testing.expect(change.hash.eql(built.change.hash));
        try testing.expectEqualDeep(change.other_actors, built.change.other_actors);
        const actors = try gpa.alloc(ActorIdx, change.other_actors.len + 1);
        defer gpa.free(actors);
        for (actors, 0..) |*actor, i| actor.* = @intCast(i);
        const reference_ops = try decodeChangeOps(gpa, change, actors);
        defer freeChangeOps(gpa, reference_ops);
        const actual_ops = try decodeChangeOps(gpa, built.change, actors);
        defer freeChangeOps(gpa, actual_ops);
        try testing.expectEqualDeep(reference_ops, actual_ops);
        try testing.expectEqual(
            (try change.withOpCount(reference_ops.len)).max_op,
            built.change.max_op,
        );
    }
    try expectSelectedHistoryMatches(gpa, &selected, &requested, &expected);
    // Releasing one occurrence must not invalidate the later cross-actor copies.
    var released = selected.items.orderedRemove(0);
    released.deinit(gpa);
    try expectSelectedHistoryMatches(gpa, &selected, requested[1..], &expected);
}

test "duplicate selected history frees partial clones and preserves readable history on refusal" {
    const gpa = testing.allocator;
    var source = try duplicateHistoryDocument(gpa);
    defer source.deinit();
    var expected = try source.getChanges(gpa, &.{});
    defer expected.deinit(gpa);
    const before = try source.save(gpa);
    defer gpa.free(before);
    var requested: [8]ChangeHash = undefined;
    const order = [_]usize{ 2, 3, 1, 2, 0, 3, 2, 1 };
    for (order, &requested) |index, *hash| hash.* = expected.at(index).hash;
    // Keep failure indices independent of SafeAllocator's in-place growth.
    var backing: testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    try testing.checkAllAllocationFailures(
        backing.allocator(),
        selectedHistoryBatchAndFree,
        .{ &source, requested[0..] },
    );
    var selected = try source.getChangesByHashes(gpa, &requested);
    defer selected.deinit(gpa);
    try expectSelectedHistoryMatches(gpa, &selected, &requested, &expected);
    const absent = ChangeHash{ .bytes = @splat(0x5a) };
    try testing.expectError(
        error.MissingDeps,
        source.getChangesByHashes(gpa, &.{ requested[0], requested[0], absent }),
    );
    const after = try source.save(gpa);
    defer gpa.free(after);
    try testing.expectEqualSlices(u8, before, after);
    var all = try source.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    try testing.expectEqual(expected.len(), all.len());
    for (expected.slice(), all.slice()) |original, actual| {
        try testing.expect(original.hash().eql(actual.hash()));
        try testing.expectEqualSlices(u8, original.body, actual.body);
        try testing.expectEqual(original.change.max_op, actual.change.max_op);
    }
}

test "Strings preserves byte-exact owned keys and insertion IDs through high-cardinality growth" {
    // Reuse mutable input storage, then read retained borrows after many insertions.
    const gpa = testing.allocator;
    var strings = Strings.init(gpa);
    defer strings.deinit();
    const table = strings.table();
    const keys = [_][]const u8{ "", "\x00", "a\x00b", "é", "é", "key", "Key", "key-long" };
    for (keys, 0..) |key, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), try table.intern(table.ctx, key, gpa));
    }
    var input = [_]u8{ 'o', 'w', 'n', 'e', 'd' };
    const owned_id = try table.intern(table.ctx, &input, gpa);
    const retained = table.resolve(table.ctx, owned_id);
    @memset(&input, 'x');
    try testing.expectEqualStrings("owned", retained);
    var buffer: [64]u8 = undefined;
    const first_generated = strings.count();
    for (0..10_000) |i| {
        const key = try std.fmt.bufPrint(&buffer, "shared-prefix-key-{d}", .{i});
        const id: u32 = @intCast(first_generated + i);
        try testing.expectEqual(id, try table.intern(table.ctx, key, gpa));
    }
    try testing.expectEqual(first_generated + 10_000, strings.count());
    try testing.expectEqualStrings("owned", retained);
    for (keys, 0..) |key, i| {
        const id: u32 = @intCast(i);
        try testing.expectEqualStrings(key, table.resolve(table.ctx, id));
        try testing.expectEqual(id, try table.intern(table.ctx, key, gpa));
    }
    for (0..10_000) |offset| {
        const i = 9_999 - offset;
        const key = try std.fmt.bufPrint(&buffer, "shared-prefix-key-{d}", .{i});
        const id: u32 = @intCast(first_generated + i);
        try testing.expectEqualStrings(key, table.resolve(table.ctx, id));
        try testing.expectEqual(id, try table.intern(table.ctx, key, gpa));
    }
    try testing.expectEqualStrings("", table.resolve(table.ctx, std.math.maxInt(u32)));
    try testing.expectEqual(first_generated + 10_000, strings.count());
}

test "Strings duplicate lookup needs no allocation even when the allocator refuses" {
    // A duplicate must not reserve capacity or copy bytes, even at a growth boundary.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var strings = Strings.init(gpa);
    defer strings.deinit();
    const table = strings.table();
    const keys = [_][]const u8{ "", "same\x00key", "é", "shared", "shared-prefix" };
    for (keys) |key| _ = try table.intern(table.ctx, key, gpa);
    var buffer: [64]u8 = undefined;
    for (0..128) |i| {
        const key = try std.fmt.bufPrint(&buffer, "shared-prefix-{d}", .{i});
        _ = try table.intern(table.ctx, key, gpa);
    }
    const allocations = failing.alloc_index;
    const allocated_bytes = failing.allocated_bytes;
    failing.fail_index = allocations;
    for (keys, 0..) |key, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), try table.intern(table.ctx, key, gpa));
    }
    for (0..128) |i| {
        const key = try std.fmt.bufPrint(&buffer, "shared-prefix-{d}", .{i});
        try testing.expectEqual(
            @as(u32, @intCast(keys.len + i)),
            try table.intern(table.ctx, key, gpa),
        );
    }
    try testing.expectEqual(allocations, failing.alloc_index);
    try testing.expectEqual(allocated_bytes, failing.allocated_bytes);
    try testing.expectEqual(keys.len + 128, strings.count());
}

test "Strings allocation refusals preserve a readable prefix and retry without consuming IDs" {
    // Sweep allocations across both ordered-key growth and arena-owned byte copies.
    // Observe only published IDs and bytes; map capacity and layout are not contracts.
    const seeds = [_][]const u8{ "", "existing\x00key", "é" };
    var completed = false;
    var refused = false;
    for (0..256) |offset| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var strings = Strings.init(gpa);
        defer strings.deinit();
        const table = strings.table();
        for (seeds) |key| _ = try table.intern(table.ctx, key, gpa);
        const retained = table.resolve(table.ctx, 1);
        failing.fail_index = failing.alloc_index + offset;
        var published: usize = 0;
        var failure_at: ?usize = null;
        var input: [4096]u8 = @splat('x');
        for (0..64) |i| {
            _ = try std.fmt.bufPrint(input[0..8], "{d:0>8}", .{i});
            const result = table.intern(table.ctx, &input, gpa);
            if (result) |id| {
                try testing.expectEqual(@as(u32, @intCast(seeds.len + i)), id);
                published += 1;
            } else |failure| {
                try testing.expectEqual(error.OutOfMemory, failure);
                failure_at = i;
                refused = true;
                break;
            }
        }
        try testing.expectEqual(seeds.len + published, strings.count());
        try testing.expectEqualStrings("existing\x00key", retained);
        for (seeds, 0..) |key, i| {
            const id: u32 = @intCast(i);
            try testing.expectEqualStrings(key, table.resolve(table.ctx, id));
            try testing.expectEqual(id, try table.intern(table.ctx, key, gpa));
        }
        for (0..published) |i| {
            _ = try std.fmt.bufPrint(input[0..8], "{d:0>8}", .{i});
            const id: u32 = @intCast(seeds.len + i);
            try testing.expectEqualStrings(&input, table.resolve(table.ctx, id));
            try testing.expectEqual(id, try table.intern(table.ctx, &input, gpa));
        }
        failing.fail_index = std.math.maxInt(usize);
        if (failure_at) |i| {
            _ = try std.fmt.bufPrint(input[0..8], "{d:0>8}", .{i});
            const next_id: u32 = @intCast(seeds.len + published);
            try testing.expectEqual(next_id, try table.intern(table.ctx, &input, gpa));
            const retried_bytes = table.resolve(table.ctx, next_id);
            @memset(&input, 'z');
            _ = try std.fmt.bufPrint(input[0..8], "{d:0>8}", .{i});
            try testing.expect(std.mem.allEqual(u8, retried_bytes[8..], 'x'));
            try testing.expectEqual(next_id + 1, try table.intern(table.ctx, &input, gpa));
            try testing.expectEqual(seeds.len + published + 2, strings.count());
        } else {
            completed = true;
            break;
        }
    }
    try testing.expect(refused);
    try testing.expect(completed);
}
