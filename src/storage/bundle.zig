//! The bundle engine: the second on-disk format, and the only one that holds a
//! *set* of changes rather than a whole document.
//!
//! A bundle is one `ChunkType.bundle` chunk, so it shares the framing in
//! `chunk.zig` — magic, checksum, type byte, LEB128 length, body — and differs
//! from a document chunk only in the body. There is no table, no index, no
//! footer and no version field, and the format is explicitly experimental
//! upstream (`bundle.rs:23-33`).
//!
//! ```text
//! offset  size  field
//! 0       4     magic, [0x85, 0x6f, 0x4a, 0x83]        storage.rs:26
//! 4       4     checksum, the first four bytes of the change hash
//! 5       1     chunk type: 3, bundle                    chunk.rs:126-131
//! 6       n     uleb128 data_len
//! 6+n     m     data, m = data_len
//! ```
//!
//! The body is four sections in this order, with nothing after them
//! (`bundle/storage.rs:150-182`):
//!
//! ```text
//! prefix      deps, then actors
//! change meta column metadata block
//! change data the bytes those columns describe
//! ops meta    column metadata block
//! ops data    the bytes those columns describe
//! ```
//!
//! * The prefix is a uleb128 count and that many 32-byte hashes, then a uleb128
//!   count and that many length-prefixed actor ids — `length_prefixed_bytes`
//!   for each actor, which is a uleb128 byte length and the bytes
//!   (`bundle/builder.rs:153-166`, `change.rs:463-473`).
//! * A metadata block is a uleb128 count, then one `(spec, length)` pair per
//!   column, and the columns' bytes follow back to back
//!   (`raw_column.rs:218-247`, `:258-265`). The same block a change chunk and a
//!   document chunk carry.
//! * A column with no bytes is not a column: the writer drops it and the
//!   reader must not see one (`raw_column.rs:40-50`, `:183`).
//! * A column at least `deflate_min_size` bytes long is stored as a raw
//!   DEFLATE stream with bit 3 of its specification set, and the block
//!   carries the inflated length only for the columns that were not deflated
//!   (`raw_column.rs:62-75`, `change.rs:17`).
//!
//! ## Column ids
//!
//! Op columns (`bundle/builder.rs:935-964`), ascending by `(id, encoding)`:
//! `OBJ(0,Actor) OBJ_CTR(0,Delta) KEY_ACTOR(1,Actor) KEY_CTR(1,Delta)
//! KEY_STR(1,String) ID_ACTOR(2,Actor) INSERT(3,Bool) ACTION(4,Integer)
//! VALUE_META(5,ValueMetadata) VALUE(5,Value) PRED_COUNT(7,Group)
//! PRED_ACTOR(7,Actor) PRED_CTR(7,Delta) EXPAND(9,Bool) MARK_NAME(10,String)
//! ID_CTR_INVERSE(11,Delta)`. Ids 6 and 8 are unused.
//!
//! Change columns (`bundle/builder.rs:966-992`): `ACTOR(0,Actor) SEQ(0,Delta)
//! START_OP(1,Delta) MAX_OP(2,Delta) TIMESTAMP(3,Delta) MESSAGE(4,String)
//! DEP_COUNT(5,Group) DEPS(5,Delta) EXTRA_COUNT(6,Group) EXTRA(6,Value)`.
//!
//! The column order *is* the format: `RawColumns::parse` rejects a set that is
//! not in ascending normalized order (`raw_column.rs:248-253`), and a change's
//! identity is the hash of its bytes, so reordering a column changes every
//! hash. The two tables below are therefore the format, not an
//! implementation detail, and `writeMetaBlock` writes them in exactly this
//! order.
//!
//! ## `ID_CTR_INVERSE`
//!
//! A bundle does not store each op's counter. It stores the *inverse
//! permutation*: for every op in canonical `(actor, counter)` order, the
//! document position that op occupies, as a delta column
//! (`bundle/builder.rs:352-372`, `:397-428`). The reader walks the change
//! metadata in `(actor, seq)` order, enumerates `start_op..=max_op` to recover
//! each op's canonical counter, and writes it into the counter of the op at
//! document position `inverse[k]` (`bundle/storage.rs:105-133`). For
//! edit-shaped workloads those deltas are almost all `+1`, which is the whole
//! reason the encoding exists.
//!
//! A bundle written before the switch carries the counters directly in a
//! `Delta` column of id 2, which the reader still accepts; the inverse column
//! wins if both appear (`bundle/storage.rs:17-22`, `:136-138`).
//!
//! ## Errors
//!
//! Upstream's `bundle::ParseError` (`bundle/error.rs:5-38`) is a payload-
//! carrying enum, and this crate has one `ParseError` with no payloads
//! (`src/error.zig:94-157`). The mapping is:
//!
//! | upstream variant | this port |
//! |---|---|
//! | `Needed` | `error.UnexpectedEnd` |
//! | `Header(_)` | the chunk-level `error.InvalidMagic`, `InvalidChecksum`, `InvalidChunkType`, `UnexpectedEnd`, `LengthExceedsInput` |
//! | `CompressedChangeCols`, `CompressedOpCols`, `Deflate(_)`, `Pack(_)` | `error.InvalidDeflate` |
//! | `InvalidColumns(_)` | `error.InvalidColumnSpec`, `error.DuplicateColumn`, `error.ColumnOutOfBounds`, `error.Overflow` |
//! | `ParseColumns(_)` | the same four, from `RawColumns.validate` |
//! | `InvalidChangeColumn(_)`, `InvalidOpColumn(_)` | `error.InvalidColumnSpec` |
//! | `Leb128(_)` | `error.InvalidLeb128`, `error.Overflow` |
//! | `ReadOp(MissingValue)` | `error.MissingColumn` |
//! | `ReadOp(InvalidOpId)`, `ReadOp(InvalidKey)` | `error.InvalidPath` |
//! | `InverseDecode` | `error.InvalidValue` |
//! | `InverseLengthMismatch` | `error.TooManyOps` |
//! | `Unbundle(_)` | not reachable here; `Bundle::to_changes` needs the change collector |
//!
//! `InverseLengthMismatch` is the one mapping that reads oddly: it is reported
//! when the change metadata declares more ops than the inverse column covers,
//! or fewer, and `error.TooManyOps` is the variant whose own documentation
//! says "a change declares more operations than the implementation accepts".
//! Both directions of the mismatch collapse onto it, where upstream has one
//! error for them too.
//!
//! ## Where upstream traps
//!
//! Three places here are a `ParseError` rather than the upstream call:
//!
//! * `split_at` on the `extra` and `value` streams panics upstream when the
//!   declared length exceeds what is left (`bundle/builder.rs:695`, `:827`);
//!   here it is `error.Truncated`.
//! * `ActorMapper`'s `mapping[i].unwrap()` panics on an actor the mapper never
//!   saw (`bundle/builder.rs:22-44`); here it is `error.WrongActorTable`,
//!   which is the `InternalError` variant that says exactly that.
//! * `BundleMetadata::num_ops` subtracts unchecked `u64`
//!   (`bundle/meta.rs:19-22`), so a row with `max_op < start_op` wraps; here
//!   it is `error.Overflow`.
//!
//! The writer's error set is therefore `ParseError || InternalError`, which is
//! [`WriteError`].

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const parse_mod = @import("parse.zig");
const chunk = @import("chunk.zig");
const column_spec = @import("column_spec.zig");
const encoding = @import("../columnar/encoding.zig");
const value_mod = @import("../value.zig");

const ParseError = err.ParseError;
const InternalError = err.InternalError;
const delta = @import("../hexane/delta.zig");
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const OpId = types.OpId;
const ExId = types.ExId;
const Input = parse_mod.Input;
const ChunkType = chunk.ChunkType;
const ColumnSpec = column_spec.ColumnSpec;
const ColumnDesc = column_spec.ColumnDesc;
const ColumnRange = column_spec.ColumnRange;
const RawColumn = column_spec.RawColumn;
const RawColumns = column_spec.RawColumns;
const Cell = encoding.Cell;
const ScalarValue = value_mod.ScalarValue;
const Action = value_mod.Action;

/// What anything in this module can fail with. The reader returns only
/// [`ParseError`]; the writer adds [`InternalError`] for the three upstream
/// asserts this file replaces with errors.
pub const WriteError = ParseError || InternalError;

/// A column of at least this many bytes is stored deflated
/// (`change.rs:17`). The value is the format's, not a tuning knob: changing it
/// changes which columns carry the DEFLATE bit and so changes the bytes.
pub const deflate_min_size: usize = 256;

/// The `ParseError` a bundle reader returns, named so a caller can spell the
/// bundle's contract without importing `error.zig`.
pub const BundleParseError = ParseError;

// ── The column tables ────────────────────────────────────────────────────────

/// The op column ids of a bundle (`bundle/builder.rs:935-949`). Ids 6 and 8
/// are not used by any column.
pub const op_col = struct {
    pub const obj: u32 = 0;
    pub const key: u32 = 1;
    pub const id: u32 = 2;
    pub const insert: u32 = 3;
    pub const action: u32 = 4;
    pub const val: u32 = 5;
    pub const pred: u32 = 7;
    pub const expand: u32 = 9;
    pub const mark_name: u32 = 10;
    /// The inverse permutation of document positions
    /// (`bundle/builder.rs:944-949`).
    pub const id_ctr_inverse: u32 = 11;
};

/// The change column ids of a bundle (`bundle/builder.rs:973-980`).
pub const change_col = struct {
    pub const actor: u32 = 0;
    pub const seq: u32 = 0;
    pub const start_op: u32 = 1;
    pub const max_op: u32 = 2;
    pub const time: u32 = 3;
    pub const message: u32 = 4;
    pub const deps: u32 = 5;
    pub const extra: u32 = 6;
};

/// The op column specifications, in the order the block must be written
/// (`bundle/builder.rs:951-966`): ascending by `(id, encoding)`, which is what
/// `RawColumns::parse` demands.
pub const op_specs = struct {
    pub const obj_actor: ColumnSpec = ColumnSpec.make(op_col.obj, .actor, false);
    pub const obj_ctr: ColumnSpec = ColumnSpec.make(op_col.obj, .delta, false);
    pub const key_actor: ColumnSpec = ColumnSpec.make(op_col.key, .actor, false);
    pub const key_ctr: ColumnSpec = ColumnSpec.make(op_col.key, .delta, false);
    pub const key_str: ColumnSpec = ColumnSpec.make(op_col.key, .string, false);
    pub const id_actor: ColumnSpec = ColumnSpec.make(op_col.id, .actor, false);
    pub const insert: ColumnSpec = ColumnSpec.make(op_col.insert, .boolean, false);
    pub const action: ColumnSpec = ColumnSpec.make(op_col.action, .rle_uint, false);
    pub const value_meta: ColumnSpec = ColumnSpec.make(op_col.val, .value_metadata, false);
    pub const value: ColumnSpec = ColumnSpec.make(op_col.val, .value, false);
    pub const pred_count: ColumnSpec = ColumnSpec.make(op_col.pred, .group, false);
    pub const pred_actor: ColumnSpec = ColumnSpec.make(op_col.pred, .actor, false);
    pub const pred_ctr: ColumnSpec = ColumnSpec.make(op_col.pred, .delta, false);
    pub const expand: ColumnSpec = ColumnSpec.make(op_col.expand, .boolean, false);
    pub const mark_name: ColumnSpec = ColumnSpec.make(op_col.mark_name, .string, false);
    pub const id_ctr_inverse: ColumnSpec = ColumnSpec.make(op_col.id_ctr_inverse, .delta, false);
};

/// The change column specifications, in the order the block must be written
/// (`bundle/builder.rs:982-992`).
pub const change_specs = struct {
    pub const actor: ColumnSpec = ColumnSpec.make(change_col.actor, .actor, false);
    pub const seq: ColumnSpec = ColumnSpec.make(change_col.seq, .delta, false);
    pub const start_op: ColumnSpec = ColumnSpec.make(change_col.start_op, .delta, false);
    pub const max_op: ColumnSpec = ColumnSpec.make(change_col.max_op, .delta, false);
    pub const timestamp: ColumnSpec = ColumnSpec.make(change_col.time, .delta, false);
    pub const message: ColumnSpec = ColumnSpec.make(change_col.message, .string, false);
    pub const dep_count: ColumnSpec = ColumnSpec.make(change_col.deps, .group, false);
    pub const deps: ColumnSpec = ColumnSpec.make(change_col.deps, .delta, false);
    pub const extra_count: ColumnSpec = ColumnSpec.make(change_col.extra, .group, false);
    pub const extra: ColumnSpec = ColumnSpec.make(change_col.extra, .value, false);
};

// ── bundle/meta.rs ───────────────────────────────────────────────────────────

/// One change's metadata, as the writer receives it and as the change graph
/// produces it (`bundle/meta.rs:5-17`). Field names and order are upstream's,
/// because `change_graph.rs:369-380` fills them in this order and a bundle's
/// change columns are written from them in this order.
///
/// `actor` and `deps` are in *document* index space, not bundle index space:
/// `Builder` rewrites every actor through an [`ActorMapper`] as the columns
/// are written (`bundle/builder.rs:21-44`).
///
/// Copying this is copying a value with no allocation and no borrow in it: the
/// slices it holds (`message`, `deps`, `extra`) are borrowed from the caller and
/// the copy shares them, so it must not outlive them. Nothing here is mutated
/// by the writer, so a copy may be read from another thread while the original
/// lives.
pub const BundleMetadata = struct {
    /// The change's hash. Used only to resolve dependency indices; it is not
    /// stored in the bundle, because the bundle reconstructs changes rather
    /// than carrying them.
    hash: ChangeHash,
    /// The change author's index in the document's actor table.
    actor: ActorIdx,
    seq: u64,
    /// The largest op counter the change's last op carries.
    max_op: u64,
    /// The change's commit time, in **seconds since the Unix epoch** — the same
    /// `i64` a change chunk header carries as `time`
    /// ([`src/change.zig`](../../change.zig)) and the same value the change
    /// graph's timestamp column holds, which is where the writer takes it from.
    /// The writer stores it verbatim as a delta cell and the reader reads it back
    /// verbatim, with no unit conversion at either end, so a caller that means
    /// milliseconds writes a different column and a different bundle.
    timestamp: i64,
    /// The commit message, or null when the change has none.
    message: ?[]const u8,
    /// The hashes this change depends on, in the order the change graph gives
    /// them (`change_graph.rs:363-365`).
    deps: []const ChangeHash,
    /// The change's extra bytes, verbatim. A bundle stores them, and a
    /// document that does not use them stores an empty column.
    extra: []const u8,
    /// The smallest op counter the change's first op carries.
    start_op: u64,
    /// The change's position in the change graph's topological order. The
    /// builder sorts on it and then overwrites it with the change's position
    /// in canonical `(actor, seq)` order (`bundle/builder.rs:57-78`), which is
    /// what the canonical `ID_CTR_INVERSE` order needs.
    builder: usize,

    /// The number of operations the change carries, `1 + max_op - start_op`
    /// (`bundle/meta.rs:19-22`).
    ///
    /// Upstream's subtraction is unchecked `u64` arithmetic
    /// ([`meta.rs`:19-22](../../github-automerge-automerge/rust/automerge/src/storage/bundle/meta.rs)),
    /// so a row with `max_op < start_op` wraps to a huge count. **The one gap
    /// it does not wrap on is an empty change**, and a document that has one
    /// produces exactly that row: `start_op = max_op - num_ops + 1` with
    /// `num_ops == 0` is `max_op + 1`
    /// ([`change_graph.rs`:367](../../github-automerge-automerge/rust/automerge/src/change_graph.rs)),
    /// which is `Automerge::empty_commit`'s own numbering
    /// ([`automerge.rs`:693-697](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    /// **`max_op + 1` is the empty change and is zero operations**; anything
    /// below that is a row this port cannot have built, and it is reported as
    /// `error.Overflow` rather than wrapped into an allocation.
    pub fn numOps(self: BundleMetadata) ParseError!usize {
        if (self.start_op > self.max_op +| 1) return error.Overflow;
        const n = self.max_op +| 1 - self.start_op;
        if (n > std.math.maxInt(usize)) return error.Overflow;
        return @intCast(n);
    }
};

// ── bundle/builder.rs: the actor mapper ──────────────────────────────────────

/// Rewrites document actor indices into the bundle's own, so a bundle carries
/// only the actors it actually uses (`op_set2/change.rs:272-340`).
///
/// The mapping is built in one pass at the end, from the set of actors some
/// column mentioned, in ascending document-index order. Nothing may use the
/// mapping before `buildMapping` has run.
///
/// **The allocator is both stored and passed.** `init` keeps what it was given
/// and every later allocation goes through that kept copy — `buildMapping`'s
/// replacement for `used` included — while `deinit` frees with the allocator its
/// own parameter names. **The two must be the same value**, which nothing here
/// can check: freeing through a different allocator is a silent heap violation
/// rather than a compile error. The actor table is borrowed, not owned.
///
/// **Copying this copies an owner.** The three arrays belong to the mapper, so
/// exactly one copy may be torn down. It has no interior mutability once
/// `buildMapping` has run, so the value may be read from another thread then,
/// but not while `processActor`, `processOp` or `buildMapping` is running.
pub const ActorMapper = struct {
    /// One flag per document actor: has anything mentioned it.
    seen: []bool,
    /// The bundle index of each document actor, or null for an actor nothing
    /// mentioned.
    mapping: []?ActorIdx,
    /// The document actors the bundle uses, by document index. Sorted ascending
    /// because it is built by walking `seen` in order.
    used: []usize,
    /// The document's actor table, which `used` indexes.
    actors: []const ActorId,
    gpa: Allocator,

    /// A mapper over the document actor table `actors`. `deinit` must be given
    /// this same `gpa`; see the type comment.
    pub fn init(gpa: Allocator, actors: []const ActorId) Allocator.Error!ActorMapper {
        const seen = try gpa.alloc(bool, actors.len);
        errdefer gpa.free(seen);
        @memset(seen, false);
        const mapping = try gpa.alloc(?ActorIdx, actors.len);
        errdefer gpa.free(mapping);
        @memset(mapping, null);
        // A zero-length allocation rather than an empty slice literal, so
        // `deinit` frees every one of the three unconditionally. Neither is a
        // heap allocation — `Allocator.free` of an empty slice returns without
        // touching the allocator (`std/mem/Allocator.zig:447`) — so this is
        // about `deinit` being total, not about what the mapper holds.
        const used = try gpa.alloc(usize, 0);
        errdefer gpa.free(used);
        return .{
            .seen = seen,
            .mapping = mapping,
            .used = used,
            .actors = actors,
            .gpa = gpa,
        };
    }

    /// Releases the mapper's three allocations. The actor table belongs to the
    /// caller.
    ///
    /// **`gpa` must be the allocator `init` was given**, because that is the
    /// one every allocation here went through; see the type comment. After this
    /// the struct is poisoned, not emptied, so one call per value and one call
    /// per copy.
    pub fn deinit(self: *ActorMapper, gpa: Allocator) void {
        gpa.free(self.seen);
        gpa.free(self.mapping);
        gpa.free(self.used);
        self.* = undefined;
    }

    /// Notes that `actor` is used. An index outside the document's actor table
    /// is a caller bug, not a malformed document: the change graph and the op
    /// set both index a table they were built with.
    pub fn processActor(self: *ActorMapper, actor: ActorIdx) InternalError!void {
        if (actor >= self.seen.len) return error.WrongActorTable;
        self.seen[actor] = true;
    }

    /// Notes every actor one operation mentions: its object's, its key's, and
    /// the actor of each predecessor (`op_set2/change.rs:309-322`).
    pub fn processOp(self: *ActorMapper, op: BundleOp) InternalError!void {
        if (op.obj.actor()) |a| try self.processActor(a);
        if (op.key.actor()) |a| try self.processActor(a);
        for (op.pred) |p| try self.processActor(p.actor);
    }

    /// Assigns each used actor a bundle index, ascending by document index, and
    /// collects them into `used` (`op_set2/change.rs:324-340`).
    ///
    /// `default_actor`, when given, is pinned to bundle index 0 and removed
    /// from the walk — the mapping a change writer wants, where the change's
    /// own author must be actor 0. A bundle has no such default
    /// (`bundle/builder.rs:148` passes null), so the first used actor in
    /// document order becomes index 0.
    pub fn buildMapping(self: *ActorMapper, default_actor: ?ActorIdx) WriteError!void {
        var next: ActorIdx = 0;
        if (default_actor) |a| {
            if (a >= self.seen.len) return error.WrongActorTable;
            self.seen[a] = false;
            self.mapping[a] = 0;
            next = 1;
        }
        var list: std.ArrayList(usize) = .empty;
        errdefer list.deinit(self.gpa);
        try list.ensureTotalCapacity(self.gpa, self.seen.len);
        for (self.seen, 0..) |is_seen, index| {
            if (!is_seen) continue;
            list.appendAssumeCapacity(index);
            self.mapping[index] = next;
            next += 1;
        }
        // `toOwnedSlice` rather than `list.items`: the list reserved for every
        // actor in the table, and an allocator frees a slice by its length, so
        // handing on the spare capacity would be an invalid free later.
        //
        // The replacement is taken before the old array is released, so
        // `self.used` is a live allocation the mapper owns at every point of
        // this function and `deinit` frees it exactly once on every path.
        // Releasing first and then assigning a fallible result would leave the
        // field dangling whenever the allocation fails, and the caller frees
        // the mapper on that path. Upstream has no such window: `other_actors`
        // is pushed into in place and reused (`op_set2/change.rs:333-339`).
        const used = try list.toOwnedSlice(self.gpa);
        self.gpa.free(self.used);
        self.used = used;
    }

    /// The bundle index of a document actor, or `error.WrongActorTable` when
    /// nothing mentioned it. This is `mapping[i].unwrap()`
    /// (`bundle/builder.rs:22-44`) as an error.
    pub fn remap(self: *const ActorMapper, actor: ActorIdx) InternalError!ActorIdx {
        if (actor >= self.mapping.len) return error.WrongActorTable;
        return self.mapping[actor] orelse error.WrongActorTable;
    }

    /// The document actors the bundle uses, in bundle index order. The caller
    /// owns the array and frees it.
    ///
    /// `used` is ascending by document index and the bundle indices were
    /// handed out in that same order, so the two orders agree and no sort is
    /// needed here.
    pub fn actorList(self: *const ActorMapper, gpa: Allocator) Allocator.Error![]ActorId {
        const out = try gpa.alloc(ActorId, self.used.len);
        for (self.used, 0..) |doc, i| out[i] = self.actors[doc];
        return out;
    }
};

// ── bundle/builder.rs: the key and the op ────────────────────────────────────

/// What an operation's key is: a property name, or the element it applies at
/// (`op_set2/types.rs:606-643`).
///
/// A property name writes the string column and leaves actor and counter
/// absent; an element id writes the actor and counter columns and leaves the
/// string absent (`bundle/builder.rs:360-364`). There is no flag column, and
/// which columns carry a value is the whole encoding.
///
/// Copying this is copying a value with no allocation in it; the `map` arm
/// borrows the caller's bytes and the copy shares them. Either may be read from
/// another thread.
pub const KeyRef = union(enum) {
    /// A property name, borrowed from the caller.
    map: []const u8,
    /// The element the operation applies at. The head of a sequence is
    /// `OpId{0, 0}`.
    seq: OpId,

    /// The actor column's cell: null for a property name, and null for the
    /// **head** (`KeyRef::actor`, `op_set2/types.rs`:616-621).
    ///
    /// Upstream's arm is `KeyRef::Seq(e) => e.actor()`, and `ElemId::actor`
    /// answers null for the head because the head is not an operation
    /// ([`types.rs`:668-674](../../github-automerge-automerge/rust/automerge/src/types.rs)).
    /// Reading the field instead — the head's `OpId` actor is zero — wrote a
    /// zero into the actor column of every row anchored at the front of a
    /// sequence, and [`KeyRef.tryLoad`] then read that back as an element id
    /// with a counter of zero and no actor and refused the bundle with
    /// `error.InvalidPath`. **The head is the one sequence key with no actor**,
    /// and it is spelled as an absent actor beside a present zero counter.
    pub fn actor(self: KeyRef) ?ActorIdx {
        return switch (self) {
            .map => null,
            .seq => |e| head_actor: {
                // **The head check is the whole of this.** The payload is a
                // bare `OpId` here rather than the reference's `ElemId`, so
                // the null for the head is spelled out where upstream gets it
                // from `ElemId::actor`.
                if (e.eql(OpId.root)) break :head_actor null;
                break :head_actor e.actor;
            },
        };
    }

    /// The counter column's cell: null for a property name.
    pub fn counter(self: KeyRef) ?i64 {
        return switch (self) {
            .map => null,
            .seq => |e| @as(i64, e.counter),
        };
    }

    /// The string column's cell: null for an element id.
    pub fn keyStr(self: KeyRef) ?[]const u8 {
        return switch (self) {
            .map => |s| s,
            .seq => null,
        };
    }

    /// Whether two keys address the same place. Upstream compares the whole
    /// `KeyRef`, string included, when deciding to flush pending deletes
    /// (`bundle/builder.rs:99`).
    pub fn eql(a: KeyRef, b: KeyRef) bool {
        return switch (a) {
            .map => |x| switch (b) {
                .map => |y| std.mem.eql(u8, x, y),
                .seq => false,
            },
            .seq => |x| switch (b) {
                .map => false,
                .seq => |y| x.eql(y),
            },
        };
    }

    /// Rebuilds a key from the three columns one row carries
    /// (`op_set2/op_set/op_iter.rs:235-265`).
    ///
    /// The three shapes a key can have, and nothing else: a string with
    /// neither actor nor counter, the head of a sequence (counter zero and no
    /// actor), or a counter above zero with an actor. Any other combination is
    /// `error.InvalidPath`, which is where upstream's `ReadOpError::InvalidKey`
    /// and `MissingKey` land.
    pub fn tryLoad(
        key_str: ?[]const u8,
        key_actor: ?ActorIdx,
        key_ctr: ?i64,
    ) ParseError!KeyRef {
        if (key_str) |s| {
            if (key_actor != null or key_ctr != null) return error.InvalidPath;
            return .{ .map = s };
        }
        if (key_actor == null and key_ctr == null) return error.InvalidPath;
        if (key_actor == null) {
            // The head of a sequence: a counter of zero and no actor
            // (`op_iter.rs:242`).
            if (key_ctr.? != 0) return error.InvalidPath;
            return .{ .seq = OpId.root };
        }
        const ctr = key_ctr orelse return error.InvalidPath;
        if (ctr <= 0) return error.InvalidPath;
        const wide = std.math.cast(u32, ctr) orelse return error.Overflow;
        return .{ .seq = OpId.init(wide, key_actor.?) };
    }
};

/// One operation, as the bundle writer consumes it.
///
/// This is upstream's `op_set2::op::OpBuilder` narrowed to the fields the
/// bundle columns carry (`bundle/builder.rs:354-380`, `:840-850`): the op set
/// builds one of those per row and hands it over, and `Builder` replaces
/// `pred` with the predecessor list it collected from the successor map before
/// any of it reaches a column.
///
/// **Where this value comes from decides who owns what it points at**, and it is
/// this type in both directions:
///
/// * Handed to [`Builder.processOp`] by a caller, it is the caller's own: `key`,
///   `value`, `mark_name` and `pred` are whatever that caller had. Nothing here
///   borrows the builder.
/// * Returned by [`OpIter.next`], every slice in it is a borrow:
///   [`BundleOp.pred`] is the iterator's own `scratch` list, valid **until the
///   next call to `next`**, which clears and refills it and may reallocate it;
///   `key`'s `map` string, `mark_name`, and a `value` that is `str` or `bytes`
///   point into the bundle's column data and last as long as the bundle does.
///   A row held across a second `next` call reads stale or reallocated bytes.
///
/// Copying this is copying those borrows, so the copy is not a second owner and
/// neither may outlive what they point at.
pub const BundleOp = struct {
    /// The operation's own id.
    id: OpId,
    /// The object the operation applies to.
    obj: ExId,
    /// The property or element the operation applies at.
    key: KeyRef,
    action: Action,
    value: ScalarValue,
    /// Whether the operation inserted rather than overwrote. The `insert`
    /// column; the reader defaults it to false when the column is absent
    /// (`bundle/builder.rs:818`).
    insert: bool,
    /// Whether the operation's value is visible to a reader that wants a
    /// mark. The `expand` column; an all-false column is not written
    /// (`bundle/builder.rs:402`).
    expand: bool,
    /// The name of the mark this operation sets, or null.
    mark_name: ?[]const u8,
    /// The operation's predecessors. On the way in, `Builder.processOp` replaces
    /// whatever the caller supplies with the list it collected from the
    /// successor map, so a caller's value here is discarded.
    ///
    /// On the way out — as a row from [`OpIter.next`] — this is **borrowed from
    /// the iterator's own scratch list and is valid only until the next call to
    /// `next`**, which clears and refills that list. A row kept across a second
    /// `next` reads stale or reallocated data.
    pred: []const OpId,

    /// A `delete` of `id` on `obj` at `key`, the operation
    /// `flushDeletes` synthesises for a tombstone whose object the writer has
    /// already passed (`bundle/builder.rs:130-141`).
    pub fn del(id: OpId, obj: ExId, key: KeyRef, pred: []const OpId) BundleOp {
        return .{
            .id = id,
            .obj = obj,
            .key = key,
            .action = .delete,
            .value = .null_value,
            .insert = false,
            .expand = false,
            .mark_name = null,
            .pred = pred,
        };
    }
};

/// One change's op counter range, sorted by `(actor, seq)`
/// (`bundle/builder.rs:535-543`). The writer binary-searches this to find the
/// change an op belongs to (`bundle/builder.rs:232-245`).
const ChangeBuilder = struct {
    actor: ActorIdx,
    seq: u64,
    /// The change's position in the metadata array, which is the topological
    /// order the columns are written in.
    change: usize,
    start_op: u64,
    max_op: u64,
};

/// Canonical `(actor, seq)` order (`bundle/builder.rs:73`).
fn changeBuilderLess(_: void, a: ChangeBuilder, b: ChangeBuilder) bool {
    if (a.actor != b.actor) return a.actor < b.actor;
    return a.seq < b.seq;
}

// ── bundle/builder.rs: writing a column metadata block ──────────────────────

/// A column metadata block and the data block it describes, both owned.
const Block = struct {
    descs: []ColumnDesc,
    data: []u8,

    fn deinit(self: *Block, gpa: Allocator) void {
        gpa.free(self.descs);
        gpa.free(self.data);
    }
};

/// The smallest a column descriptor can be on the wire: a one-byte
/// specification and a one-byte length. The floor `Input.readCountThen` needs
/// before it believes a column count (`raw_column.rs:225-232`).
const min_desc_size: usize = 2;

/// The value a column's entries all take for the column to be elided rather
/// than written. Upstream's `save_to_unless`, which is one of two calls per
/// column: `save_to` always writes, and `save_to_unless(out, sentinel)` writes
/// nothing when every entry is the sentinel (`encoder.rs:281-345`).
const Elide = enum {
    /// `save_to`: the column is always written.
    never,
    /// `save_to_unless(out, None)`: an all-absent column is dropped. The
    /// object, key, message and mark-name columns.
    all_absent,
    /// `save_to_unless(out, false)`: an all-false column is dropped, which is
    /// what makes an omitted `expand` column mean "nothing expands".
    all_false,

    /// Whether `cells` is entirely the sentinel, and so is not a column. An
    /// empty column elides too, because a column with no bytes is not a column
    /// (`raw_column.rs:40-50`, `:183`).
    ///
    /// The test is on the active tag, not on `==` against a coerced variant: a
    /// union compared to an enum literal compares payloads too, and the payload
    /// of the literal is undefined.
    fn elides(self: Elide, cells: []const Cell) bool {
        return switch (self) {
            .never => false,
            .all_absent => for (cells) |c| {
                if (std.meta.activeTag(c) != .null_value) break false;
            } else true,
            .all_false => for (cells) |c| {
                if (std.meta.activeTag(c) != .boolean or c.boolean) break false;
            } else true,
        };
    }
};

/// Appends the metadata block for `descs` to `out`
/// (`raw_column.rs:258-265`).
///
/// The count leads the block, so it is counted first: a column with no bytes is
/// not a column (`raw_column.rs:40-50`, `:183`) and does not count. The
/// descriptors are written in the order `descs` holds them, which is the
/// ascending normalized order the reader demands.
///
/// The data block is *not* written here. Upstream's `RawColumns::write` stops
/// at the metadata and the caller appends the bytes next
/// (`bundle/builder.rs:175-182`), which is what lets the same descriptors be
/// paired with either the inflated or the deflated bytes.
fn writeMetaBlock(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    descs: []const ColumnDesc,
) Allocator.Error!void {
    var count: usize = 0;
    for (descs) |d| {
        if (d.len == 0) continue;
        count += 1;
    }
    try leb128.appendUnsigned(out, gpa, count);
    for (descs) |d| {
        if (d.len == 0) continue;
        try leb128.appendUnsigned(out, gpa, d.spec.raw);
        try leb128.appendUnsigned(out, gpa, d.len);
    }
}

/// The deflated rendering of a block: every column at least
/// `deflate_min_size` bytes long becomes a raw DEFLATE stream and carries the
/// DEFLATE bit on its specification (`raw_column.rs:62-75`).
///
/// The threshold is the format's, not a tuning knob, and the comparison is
/// `len < threshold` keeps the bytes, so a column of exactly
/// `deflate_min_size` bytes is deflated.
fn deflateBlock(
    gpa: Allocator,
    descs: []const ColumnDesc,
    data: []const u8,
) Allocator.Error!Block {
    const out_descs = try gpa.alloc(ColumnDesc, descs.len);
    errdefer gpa.free(out_descs);
    var out_data: std.ArrayList(u8) = .empty;
    errdefer out_data.deinit(gpa);
    var offset: usize = 0;
    for (descs, out_descs) |d, *o| {
        const start = offset;
        offset = start + d.len;
        if (d.len == 0) {
            o.* = d;
            continue;
        }
        // The ranges came from the writer's own cumulative offsets, so the
        // slice is in bounds by construction.
        const bytes = data[start..offset];
        if (bytes.len < deflate_min_size or d.spec.isCompressed()) {
            try out_data.appendSlice(gpa, bytes);
            o.* = ColumnDesc.init(d.spec, bytes.len);
            continue;
        }
        const deflated = try chunk.compressRaw(gpa, bytes);
        defer gpa.free(deflated);
        try out_data.appendSlice(gpa, deflated);
        o.* = ColumnDesc.init(d.spec.deflated(), deflated.len);
    }
    return .{ .descs = out_descs, .data = try out_data.toOwnedSlice(gpa) };
}

/// Encodes `cells` as one column, appends it to `data`, and returns the range
/// it occupies there.
///
/// A column `elide` covers is not written at all, and an empty range is what
/// makes `RawColumns.init` drop it from the block. That is the whole
/// difference between `save_to` and `save_to_unless` (`encoder.rs:281-345`),
/// and it is load-bearing: an absent `expand` column is how a reader learns
/// that nothing expands, and an absent `key_str` column is how it learns that
/// every key is an element id.
fn appendColumn(
    gpa: Allocator,
    data: *std.ArrayList(u8),
    spec: ColumnSpec,
    cells: []const Cell,
    elide: Elide,
) WriteError!ColumnRange {
    if (elide.elides(cells)) return ColumnRange.empty();
    const encoded = try encoding.encodeColumn(gpa, spec.id(), spec.encoding(), cells);
    defer encoded.deinit(gpa);
    if (!encoded.isPresent()) return ColumnRange.empty();
    const start = data.items.len;
    try data.appendSlice(gpa, encoded.bytes);
    return .init(start, data.items.len);
}

/// Appends a value column pair: the metadata column, then the payload column,
/// then the payloads' bytes as one opaque block (`bundle/builder.rs:396-398`).
/// The pair is never elided; a row with no payload takes zero bytes, which is
/// how a column of nulls, booleans and integers costs nothing here.
fn appendValuePair(
    gpa: Allocator,
    data: *std.ArrayList(u8),
    col_id: u32,
    values: []const ScalarValue,
) WriteError!struct { meta: ColumnRange, raw: ColumnRange } {
    const pair = try encoding.encodeValuePair(gpa, col_id, values);
    defer pair.deinit(gpa);
    const meta_start = data.items.len;
    try data.appendSlice(gpa, pair.meta.bytes);
    const raw_start = data.items.len;
    try data.appendSlice(gpa, pair.raw.bytes);
    return .{
        .meta = .init(meta_start, raw_start),
        .raw = .init(raw_start, data.items.len),
    };
}

/// Rewrites every present actor cell through `mapper`
/// (`bundle/builder.rs:21-44`).
///
/// `nullable` says whether the column may hold absent rows: the object and key
/// actor columns may, the id, predecessor and change-actor columns may not.
fn remapActorCells(
    cells: []Cell,
    mapper: *const ActorMapper,
    nullable: bool,
) WriteError!void {
    for (cells) |*c| switch (c.*) {
        .null_value => {
            if (!nullable) return error.Invariant;
        },
        .uint => |a| c.* = .{ .uint = try mapper.remap(std.math.cast(ActorIdx, a) orelse
            return error.WrongActorTable) },
        else => return error.Invariant,
    };
}

/// An integer widened to a delta cell. Upstream writes `change.seq as i64`
/// (`bundle/builder.rs:280-282`), and a Rust `as` on an out-of-range integer
/// is a two's complement wrap, which is what this is.
fn asI64(v: u64) i64 {
    return @bitCast(v);
}

/// The hash of a `ChangeHash` as a `u64` context, hashing the bytes rather than
/// the struct, the way `change_graph.zig:142-150` does.
const HashContext = struct {
    pub fn hash(_: @This(), key: ChangeHash) u64 {
        return std.hash.Wyhash.hash(0, &key.bytes);
    }

    pub fn eql(_: @This(), a: ChangeHash, b: ChangeHash) bool {
        return a.eql(b);
    }
};

const ChangeMap = std.HashMapUnmanaged(ChangeHash, usize, HashContext, 80);

/// The hash context for an `OpId`, which packs into a `u64`
/// (`types.zig:194-196`).
const OpIdContext = struct {
    pub fn hash(_: @This(), key: OpId) u64 {
        const key64 = key.toU64();
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&key64));
    }

    pub fn eql(_: @This(), a: OpId, b: OpId) bool {
        return a.eql(b);
    }
};

/// A predecessor list waiting for the operation it belongs to
/// (`bundle/builder.rs:48`, `:116`).
const PredList = std.ArrayList(OpId);
const PredMap = std.HashMapUnmanaged(OpId, PredList, OpIdContext, 80);

// ── bundle/builder.rs: the change writer ─────────────────────────────────────

/// Accumulates the change metadata columns and the dependency index
/// resolution (`bundle/builder.rs:248-328`).
///
/// Every column is one `Cell` per change, and the dependency column is one
/// `Cell` per dependency across all changes, with the per-change count column
/// saying how many to take (`bundle/builder.rs:288-299`).
const ChangeWriter = struct {
    gpa: Allocator,
    /// The number of changes added so far, which is the bundle index the next
    /// one gets.
    len: usize = 0,
    /// The total number of changes, fixed at construction. A dependency on a
    /// change the bundle does not hold is `cap + index into external`.
    cap: usize,
    /// The bundle index of each change hash, whether the change is in the
    /// bundle or is one of `external`.
    seen: ChangeMap = .empty,
    /// The hashes the bundle depends on but does not hold, whose bytes go in
    /// the prefix.
    external: std.ArrayList(ChangeHash) = .empty,
    actor: std.ArrayList(Cell) = .empty,
    seq: std.ArrayList(Cell) = .empty,
    start_op: std.ArrayList(Cell) = .empty,
    max_op: std.ArrayList(Cell) = .empty,
    timestamp: std.ArrayList(Cell) = .empty,
    message: std.ArrayList(Cell) = .empty,
    dep_count: std.ArrayList(Cell) = .empty,
    deps: std.ArrayList(Cell) = .empty,
    extra_count: std.ArrayList(Cell) = .empty,
    extra: std.ArrayList(u8) = .empty,

    fn init(gpa: Allocator, cap: usize) ChangeWriter {
        return .{ .gpa = gpa, .cap = cap };
    }

    fn deinit(self: *ChangeWriter, gpa: Allocator) void {
        self.seen.deinit(gpa);
        self.external.deinit(gpa);
        self.actor.deinit(gpa);
        self.seq.deinit(gpa);
        self.start_op.deinit(gpa);
        self.max_op.deinit(gpa);
        self.timestamp.deinit(gpa);
        self.message.deinit(gpa);
        self.dep_count.deinit(gpa);
        self.deps.deinit(gpa);
        self.extra_count.deinit(gpa);
        self.extra.deinit(gpa);
    }

    /// Appends one change's metadata, and resolves its dependencies to bundle
    /// indices (`bundle/builder.rs:274-300`).
    ///
    /// A dependency already added is its bundle index. One that is not gets
    /// the next external index, is recorded so a later dependency on the same
    /// change resolves to it, and has its hash written to the prefix — which is
    /// what lets a bundle name changes it does not carry.
    fn add(self: *ChangeWriter, change: *const BundleMetadata, mapper: *ActorMapper) WriteError!void {
        if (self.len >= self.cap) return error.Invariant;
        try mapper.processActor(change.actor);
        try self.seen.put(self.gpa, change.hash, self.len);
        self.len += 1;
        try self.actor.append(self.gpa, .{ .uint = change.actor });
        try self.seq.append(self.gpa, .{ .int = asI64(change.seq) });
        try self.start_op.append(self.gpa, .{ .int = asI64(change.start_op) });
        try self.max_op.append(self.gpa, .{ .int = asI64(change.max_op) });
        try self.timestamp.append(self.gpa, .{ .int = change.timestamp });
        try self.message.append(self.gpa, if (change.message) |m|
            .{ .string = m }
        else
            Cell.null_value);
        try self.extra_count.append(self.gpa, .{ .uint = change.extra.len });
        try self.extra.appendSlice(self.gpa, change.extra);
        try self.dep_count.append(self.gpa, .{ .uint = change.deps.len });
        for (change.deps) |d| {
            const index = self.seen.get(d) orelse idx: {
                const at = self.cap + self.external.items.len;
                try self.seen.put(self.gpa, d, at);
                try self.external.append(self.gpa, d);
                break :idx at;
            };
            try self.deps.append(self.gpa, .{ .int = asI64(index) });
        }
    }

    /// Writes the change columns into `data` and returns the block's
    /// descriptors, in the order `BundleChangeColumns::raw_columns` writes them
    /// (`bundle/builder.rs:488-507`).
    fn finish(
        self: *ChangeWriter,
        gpa: Allocator,
        data: *std.ArrayList(u8),
        mapper: *const ActorMapper,
    ) WriteError![]ColumnDesc {
        try remapActorCells(self.actor.items, mapper, false);
        const actor = try appendColumn(gpa, data, change_specs.actor, self.actor.items, .never);
        const seq = try appendColumn(gpa, data, change_specs.seq, self.seq.items, .never);
        const start_op = try appendColumn(gpa, data, change_specs.start_op, self.start_op.items, .never);
        const max_op = try appendColumn(gpa, data, change_specs.max_op, self.max_op.items, .never);
        const timestamp = try appendColumn(gpa, data, change_specs.timestamp, self.timestamp.items, .never);
        // `save_to`, not `save_to_unless`: a change block with no messages
        // still carries the message column, as a null run
        // (`bundle/builder.rs:307`). The reference's own two-change bundle has
        // exactly that: a two-byte null run of two.
        const message = try appendColumn(gpa, data, change_specs.message, self.message.items, .never);
        const dep_count = try appendColumn(gpa, data, change_specs.dep_count, self.dep_count.items, .never);
        const deps = try appendColumn(gpa, data, change_specs.deps, self.deps.items, .never);
        const extra_count = try appendColumn(gpa, data, change_specs.extra_count, self.extra_count.items, .never);
        // The extra bytes are opaque: a `value` column with no metadata
        // sibling, and the reader splits it by `extra_count` per change
        // (`bundle/builder.rs:642`, `:694-697`).
        const extra_start = data.items.len;
        try data.appendSlice(gpa, self.extra.items);
        const extra = if (self.extra.items.len == 0)
            ColumnRange.empty()
        else
            ColumnRange.init(extra_start, data.items.len);

        const descs = try gpa.alloc(ColumnDesc, 10);
        errdefer gpa.free(descs);
        const order = [_]struct { spec: ColumnSpec, range: ColumnRange }{
            .{ .spec = change_specs.actor, .range = actor },
            .{ .spec = change_specs.seq, .range = seq },
            .{ .spec = change_specs.start_op, .range = start_op },
            .{ .spec = change_specs.max_op, .range = max_op },
            .{ .spec = change_specs.timestamp, .range = timestamp },
            .{ .spec = change_specs.message, .range = message },
            .{ .spec = change_specs.dep_count, .range = dep_count },
            .{ .spec = change_specs.deps, .range = deps },
            .{ .spec = change_specs.extra_count, .range = extra_count },
            .{ .spec = change_specs.extra, .range = extra },
        };
        for (order, descs) |o, *d| d.* = ColumnDesc.init(o.spec, o.range.len());
        return descs;
    }
};

// ── bundle/builder.rs: the op writer ─────────────────────────────────────────

/// One op's position in the document, recorded so the inverse permutation can
/// be built at the end (`bundle/builder.rs:347-350`).
const InversePos = struct {
    actor: ActorIdx,
    counter: u32,
    doc_pos: u32,
};

/// Canonical `(actor, counter)` order, the order the inverse permutation is
/// emitted in (`bundle/builder.rs:423`).
fn inverseLess(_: void, a: InversePos, b: InversePos) bool {
    if (a.actor != b.actor) return a.actor < b.actor;
    return a.counter < b.counter;
}

/// Accumulates the op columns and the inverse permutation
/// (`bundle/builder.rs:330-452`).
const OpWriter = struct {
    gpa: Allocator,
    obj_actor: std.ArrayList(Cell) = .empty,
    obj_ctr: std.ArrayList(Cell) = .empty,
    key_actor: std.ArrayList(Cell) = .empty,
    key_ctr: std.ArrayList(Cell) = .empty,
    key_str: std.ArrayList(Cell) = .empty,
    id_actor: std.ArrayList(Cell) = .empty,
    insert: std.ArrayList(Cell) = .empty,
    action: std.ArrayList(Cell) = .empty,
    values: std.ArrayList(ScalarValue) = .empty,
    pred_count: std.ArrayList(Cell) = .empty,
    pred_actor: std.ArrayList(Cell) = .empty,
    pred_ctr: std.ArrayList(Cell) = .empty,
    expand: std.ArrayList(Cell) = .empty,
    mark_name: std.ArrayList(Cell) = .empty,
    /// `(actor, counter, document position)` for every op, in document order.
    inverse: std.ArrayList(InversePos) = .empty,

    fn init(gpa: Allocator) OpWriter {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *OpWriter, gpa: Allocator) void {
        self.obj_actor.deinit(gpa);
        self.obj_ctr.deinit(gpa);
        self.key_actor.deinit(gpa);
        self.key_ctr.deinit(gpa);
        self.key_str.deinit(gpa);
        self.id_actor.deinit(gpa);
        self.insert.deinit(gpa);
        self.action.deinit(gpa);
        self.values.deinit(gpa);
        self.pred_count.deinit(gpa);
        self.pred_actor.deinit(gpa);
        self.pred_ctr.deinit(gpa);
        self.expand.deinit(gpa);
        self.mark_name.deinit(gpa);
        self.inverse.deinit(gpa);
    }

    /// Appends one operation's row (`bundle/builder.rs:354-380`).
    ///
    /// The document position is the row's index in the id actor column, taken
    /// before the append, which is what the inverse permutation refers to.
    fn add(self: *OpWriter, op: BundleOp, mapper: *ActorMapper) WriteError!void {
        try mapper.processOp(op);
        const doc_pos: u32 = std.math.cast(u32, self.id_actor.items.len) orelse
            return error.TooManyOps;
        try self.id_actor.append(self.gpa, .{ .uint = op.id.actor });
        try self.obj_actor.append(self.gpa, if (op.obj.actor()) |a|
            .{ .uint = a }
        else
            Cell.null_value);
        try self.obj_ctr.append(self.gpa, if (op.obj.counter()) |c|
            .{ .int = asI64(c) }
        else
            Cell.null_value);
        try self.key_actor.append(self.gpa, if (op.key.actor()) |a|
            .{ .uint = a }
        else
            Cell.null_value);
        try self.key_ctr.append(self.gpa, if (op.key.counter()) |c|
            .{ .int = c }
        else
            Cell.null_value);
        try self.key_str.append(self.gpa, if (op.key.keyStr()) |s|
            .{ .string = s }
        else
            Cell.null_value);
        try self.insert.append(self.gpa, .{ .boolean = op.insert });
        try self.action.append(self.gpa, .{ .uint = @backingInt(op.action) });
        try self.values.append(self.gpa, op.value);
        try self.pred_count.append(self.gpa, .{ .uint = op.pred.len });
        for (op.pred) |p| {
            try self.pred_actor.append(self.gpa, .{ .uint = p.actor });
            try self.pred_ctr.append(self.gpa, .{ .int = asI64(p.counter) });
        }
        try self.expand.append(self.gpa, .{ .boolean = op.expand });
        try self.mark_name.append(self.gpa, if (op.mark_name) |m|
            .{ .string = m }
        else
            Cell.null_value);
        try self.inverse.append(self.gpa, .{
            .actor = op.id.actor,
            .counter = op.id.counter,
            .doc_pos = doc_pos,
        });
    }

    /// Writes the op columns into `data` and returns the block's descriptors
    /// in the order `BundleOpsColumns::raw_columns` writes them
    /// (`bundle/builder.rs:509-533`), together with each op's counter in
    /// document order, which is the in-memory twin of the inverse column.
    fn finish(
        self: *OpWriter,
        gpa: Allocator,
        data: *std.ArrayList(u8),
        mapper: *const ActorMapper,
    ) WriteError!struct { descs: []ColumnDesc, id_ctr: []i64 } {
        try remapActorCells(self.obj_actor.items, mapper, true);
        try remapActorCells(self.key_actor.items, mapper, true);
        try remapActorCells(self.id_actor.items, mapper, false);
        try remapActorCells(self.pred_actor.items, mapper, false);

        const obj_actor = try appendColumn(gpa, data, op_specs.obj_actor, self.obj_actor.items, .all_absent);
        const obj_ctr = try appendColumn(gpa, data, op_specs.obj_ctr, self.obj_ctr.items, .all_absent);
        const key_actor = try appendColumn(gpa, data, op_specs.key_actor, self.key_actor.items, .all_absent);
        const key_ctr = try appendColumn(gpa, data, op_specs.key_ctr, self.key_ctr.items, .all_absent);
        const key_str = try appendColumn(gpa, data, op_specs.key_str, self.key_str.items, .all_absent);
        const id_actor = try appendColumn(gpa, data, op_specs.id_actor, self.id_actor.items, .never);
        // `insert` is `save_to`, so an all-false insert column is written; it
        // is `expand` that is elided (`bundle/builder.rs:393-402`).
        const insert = try appendColumn(gpa, data, op_specs.insert, self.insert.items, .never);
        const action = try appendColumn(gpa, data, op_specs.action, self.action.items, .never);
        const pair = try appendValuePair(gpa, data, op_col.val, self.values.items);
        const pred_count = try appendColumn(gpa, data, op_specs.pred_count, self.pred_count.items, .never);
        const pred_actor = try appendColumn(gpa, data, op_specs.pred_actor, self.pred_actor.items, .never);
        const pred_ctr = try appendColumn(gpa, data, op_specs.pred_ctr, self.pred_ctr.items, .never);
        const expand = try appendColumn(gpa, data, op_specs.expand, self.expand.items, .all_false);
        const mark_name = try appendColumn(gpa, data, op_specs.mark_name, self.mark_name.items, .all_absent);

        // Each op's counter in document order: element `k` is the counter of
        // the op at document position `k` (`bundle/builder.rs:405-412`).
        const id_ctr = try gpa.alloc(i64, self.inverse.items.len);
        errdefer gpa.free(id_ctr);
        for (self.inverse.items, id_ctr) |pos, *c| c.* = asI64(pos.counter);

        // Sorted by canonical `(actor, counter)`, each entry's document
        // position emitted as a delta integer: the inverse permutation
        // (`bundle/builder.rs:414-428`).
        std.mem.sort(InversePos, self.inverse.items, {}, inverseLess);
        var inverse_cells: std.ArrayList(Cell) = .empty;
        defer inverse_cells.deinit(gpa);
        try inverse_cells.ensureTotalCapacity(gpa, self.inverse.items.len);
        for (self.inverse.items) |pos| {
            inverse_cells.appendAssumeCapacity(.{ .int = asI64(pos.doc_pos) });
        }
        const id_ctr_inverse = try appendColumn(gpa, data, op_specs.id_ctr_inverse, inverse_cells.items, .never);

        const descs = try gpa.alloc(ColumnDesc, 16);
        errdefer gpa.free(descs);
        const order = [_]struct { spec: ColumnSpec, range: ColumnRange }{
            .{ .spec = op_specs.obj_actor, .range = obj_actor },
            .{ .spec = op_specs.obj_ctr, .range = obj_ctr },
            .{ .spec = op_specs.key_actor, .range = key_actor },
            .{ .spec = op_specs.key_ctr, .range = key_ctr },
            .{ .spec = op_specs.key_str, .range = key_str },
            .{ .spec = op_specs.id_actor, .range = id_actor },
            .{ .spec = op_specs.insert, .range = insert },
            .{ .spec = op_specs.action, .range = action },
            .{ .spec = op_specs.value_meta, .range = pair.meta },
            .{ .spec = op_specs.value, .range = pair.raw },
            .{ .spec = op_specs.pred_count, .range = pred_count },
            .{ .spec = op_specs.pred_actor, .range = pred_actor },
            .{ .spec = op_specs.pred_ctr, .range = pred_ctr },
            .{ .spec = op_specs.expand, .range = expand },
            .{ .spec = op_specs.mark_name, .range = mark_name },
            .{ .spec = op_specs.id_ctr_inverse, .range = id_ctr_inverse },
        };
        for (order, descs) |o, *d| d.* = ColumnDesc.init(o.spec, o.range.len());
        return .{ .descs = descs, .id_ctr = id_ctr };
    }
};

// ── bundle/builder.rs: the builder ──────────────────────────────────────────

/// The object and key the writer last wrote a row for. A change of either
/// flushes the tombstones accumulated for the previous one
/// (`bundle/builder.rs:47`, `:98-107`).
const LastOp = struct {
    obj: ExId,
    key: KeyRef,
};

/// Builds a bundle from a document's changes and operations
/// (`bundle/builder.rs:42-246`).
///
/// The order of the two calls is load-bearing and not obvious. Feed the
/// changes first: [`Builder.init`] sorts them into topological order, fixes the
/// `(actor, seq)` ordering the inverse permutation needs, and gives the
/// dependency indices their meaning. Then feed the operations in document
/// order, and finally call [`Builder.finish`].
///
/// Every allocation the builder makes is released by [`Builder.deinit`]. The
/// `changes` slice is *mutated*: its `builder` field is rewritten with each
/// change's position in canonical `(actor, seq)` order
/// (`bundle/builder.rs:75-78`), which is what the caller needs in order to
/// reconstruct the changes afterwards.
///
/// **The allocator is both stored and passed, and the two must be the same
/// value.** `init` keeps what it was given, and `processOp`, `processSucc` and
/// `flushDeletes` allocate through that kept copy; `finish` takes its own
/// allocator for the bundle it hands back; `deinit` frees with the one its
/// parameter names. Nothing here can check the three agree, and freeing
/// through a different allocator is a silent heap violation rather than a
/// compile error.
///
/// **`finish` is one-shot.** See [`Builder.finish`].
///
/// **Copying this copies an owner**, so exactly one copy may be torn down.
pub const Builder = struct {
    gpa: Allocator,
    mapper: ActorMapper,
    change_writer: ChangeWriter,
    op_writer: OpWriter,
    /// The changes' op counter ranges, ascending by `(actor, seq)`.
    builders: []ChangeBuilder,
    /// The object and key of the last row written, or null before the first.
    last: ?LastOp,
    /// The predecessors of each op the writer has not yet reached, collected
    /// from the successor edges the op set walked past.
    preds: PredMap,
    /// Whether [`Builder.finish`] has run. A builder is written once and
    /// finished once; see that method for why the second call is refused.
    finished: bool = false,

    /// A builder over `changes`, the document actor table `actors`, and
    /// `gpa` (`bundle/builder.rs:52-96`). `finish` and `deinit` must be given
    /// this same `gpa`; see the type comment.
    pub fn init(
        gpa: Allocator,
        changes: []BundleMetadata,
        actors: []const ActorId,
    ) WriteError!Builder {
        // Sorting on `builder` writes the changes in topological order, which
        // is what keeps a dependency from ever naming an external change that
        // a later change in the same bundle also names
        // (`bundle/builder.rs:57-59`).
        std.mem.sort(BundleMetadata, changes, {}, metaLessByBuilder);

        const builders = try gpa.alloc(ChangeBuilder, changes.len);
        errdefer gpa.free(builders);
        for (changes, 0..) |c, index| {
            const num_ops = try c.numOps();
            builders[index] = .{
                .actor = c.actor,
                .seq = c.seq,
                .change = index,
                .start_op = c.start_op,
                .max_op = c.start_op + num_ops - 1,
            };
        }
        // Canonical `(actor, seq)` order, which the inverse permutation and
        // the reader's counter reconstruction both depend on.
        std.mem.sortUnstable(ChangeBuilder, builders, {}, changeBuilderLess);
        for (builders, 0..) |b, index| changes[b.change].builder = index;

        var mapper = try ActorMapper.init(gpa, actors);
        errdefer mapper.deinit(gpa);
        var change_writer = ChangeWriter.init(gpa, changes.len);
        errdefer change_writer.deinit(gpa);
        for (changes) |*c| try change_writer.add(c, &mapper);

        return .{
            .gpa = gpa,
            .mapper = mapper,
            .change_writer = change_writer,
            .op_writer = OpWriter.init(gpa),
            .builders = builders,
            .last = null,
            .preds = .empty,
            .finished = false,
        };
    }

    /// Releases everything the builder allocated. The changes slice and the
    /// actor table belong to the caller.
    ///
    /// **`gpa` must be the allocator `init` was given and the one `finish` was
    /// given**, because that is where everything here was allocated; see the
    /// type comment. After this the struct is poisoned, not emptied, so one
    /// call per value and one call per copy.
    pub fn deinit(self: *Builder, gpa: Allocator) void {
        self.mapper.deinit(gpa);
        self.change_writer.deinit(gpa);
        self.op_writer.deinit(gpa);
        gpa.free(self.builders);
        var it = self.preds.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(gpa);
        self.preds.deinit(gpa);
        self.* = undefined;
    }

    /// One operation, in document order (`bundle/builder.rs:98-123`).
    ///
    /// A change of object or key flushes the tombstones for the previous one,
    /// which is how a delete reaches the op columns: the op set reports a
    /// successor edge as it walks past, long after the op it points at, and the
    /// delete can only be written once the writer knows which object it
    /// belongs to.
    ///
    /// **The register is `elemid_or_key`, not `op.key`** — upstream's
    /// `process_op` takes `Some((op.obj, op.elemid_or_key()))`
    /// ([`builder.rs`:104-106](../../github-automerge-automerge/rust/automerge/src/storage/bundle/builder.rs))
    /// and that is what decides whether a flush is due, while the *columns*
    /// take `op.key` (upstream's `Op::build`, [`op.rs`:1140](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
    /// The two differ for an insert, whose register is the element it makes
    /// and whose key is the element it went after
    /// ([`op.rs`:1040-1046](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
    /// and a tombstone flushed into the wrong register is a delete landing on
    /// the wrong element.
    pub fn processOp(self: *Builder, op: BundleOp) WriteError!void {
        const register: KeyRef = if (op.insert)
            .{ .seq = op.id }
        else
            op.key;
        const flush = if (self.last) |l|
            !(l.obj.eql(op.obj) and l.key.eql(register))
        else
            true;
        if (flush) try self.flushDeletes();
        self.last = .{ .obj = op.obj, .key = register };
        // The predecessor list is the one the successor edges built, not the
        // one the op set supplied: the op set hands over a bare op, and the
        // edges are the only place the predecessors are recorded.
        var owned: ?PredList = null;
        defer if (owned) |*list| list.deinit(self.gpa);
        var built = op;
        if (self.preds.fetchRemove(op.id)) |entry| {
            owned = entry.value;
            built.pred = entry.value.items;
        } else {
            built.pred = &.{};
        }
        // An op whose counter is outside every change's range is not part of
        // this bundle and is dropped (`bundle/builder.rs:120-122`).
        if (self.buildersIndex(built.id) != null) try self.op_writer.add(built, &self.mapper);
    }

    /// One successor edge: `op_id` overwrote `succ_id`, so `op_id` is a
    /// predecessor of `succ_id` (`bundle/builder.rs:125-128`).
    pub fn processSucc(self: *Builder, op_id: OpId, succ_id: OpId) WriteError!void {
        const entry = try self.preds.getOrPut(self.gpa, succ_id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.gpa, op_id);
    }

    /// Writes the tombstones accumulated for the last object and key
    /// (`bundle/builder.rs:130-141`).
    ///
    /// Upstream walks the successor map in hash order, so the deletes it
    /// writes come out in an unspecified order. Nothing reads that order: a
    /// change's ops are canonicalised by the op columns' own sorting, and the
    /// change hashes are taken over the change chunks, not over this. Here the
    /// ids are sorted so the writer's output is reproducible and a round-trip
    /// test can pin the bytes.
    pub fn flushDeletes(self: *Builder) WriteError!void {
        const last = self.last orelse return;
        self.last = null;
        var ids: std.ArrayList(OpId) = .empty;
        defer ids.deinit(self.gpa);
        var it = self.preds.iterator();
        while (it.next()) |entry| try ids.append(self.gpa, entry.key_ptr.*);
        std.mem.sort(OpId, ids.items, {}, OpId.lessThan);
        for (ids.items) |id| {
            const preds = self.preds.get(id) orelse continue;
            const op = BundleOp.del(id, last.obj, last.key, preds.items);
            if (self.buildersIndex(id) != null) try self.op_writer.add(op, &self.mapper);
        }
        var clear = self.preds.iterator();
        while (clear.next()) |entry| entry.value_ptr.deinit(self.gpa);
        self.preds.clearRetainingCapacity();
    }

    /// The change whose op counter range covers `id`, by binary search over the
    /// `(actor, seq)`-ordered ranges (`bundle/builder.rs:232-245`).
    ///
    /// The comparison is upstream's: actor first, and then whether the id's
    /// counter falls inside the change's range, which is what lets one search
    /// find a change without a separate containment test.
    fn buildersIndex(self: *const Builder, id: OpId) ?usize {
        var lo: usize = 0;
        var hi: usize = self.builders.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const b = self.builders[mid];
            const order: std.math.Order = if (b.actor != id.actor)
                std.math.order(b.actor, id.actor)
            else if (id.counter < b.start_op)
                .gt
            else if (id.counter > b.max_op)
                .lt
            else
                .eq;
            switch (order) {
                .eq => return mid,
                .gt => hi = mid,
                .lt => lo = mid + 1,
            }
        }
        return null;
    }

    /// The finished bundle: the uncompressed form the writer iterates over,
    /// and the per-column DEFLATE form that is the on-disk one
    /// (`bundle/builder.rs:143-229`).
    ///
    /// **`gpa` must be the allocator `init` was given**, because the bundle
    /// this hands back is built through it and [`Builder.deinit`] will free
    /// through it; see the type comment.
    ///
    /// **One call per builder, whatever the outcome.** `remapActorCells`
    /// rewrites `obj_actor`, `key_actor`, `id_actor` and `pred_actor` *in
    /// place*, through `mapper.remap` (`bundle/builder.rs:21-44`), and the
    /// change writer does the same to its actor column. Those cells hold
    /// bundle indices once this has run, and feeding them through `remap` a
    /// second time reads them as document indices, so a second call would
    /// silently produce a bundle whose every actor index is wrong rather than
    /// fail. The flag is set before the first mutation, so a `finish` that
    /// fails part way through is as finished as one that succeeds: a second
    /// call is `error.Invariant`.
    pub fn finish(self: *Builder, gpa: Allocator) WriteError!Bundle {
        if (self.finished) return error.Invariant;
        self.finished = true;
        try self.flushDeletes();
        try self.mapper.buildMapping(null);

        var changes_data: std.ArrayList(u8) = .empty;
        defer changes_data.deinit(gpa);
        const change_descs = try self.change_writer.finish(gpa, &changes_data, &self.mapper);
        defer gpa.free(change_descs);

        var ops_data: std.ArrayList(u8) = .empty;
        defer ops_data.deinit(gpa);
        const ops = try self.op_writer.finish(gpa, &ops_data, &self.mapper);
        // **`descs` on every exit and `id_ctr` only on a failed one**: the
        // descriptors are written into both bodies below and are dead the
        // moment `finish` returns, while `id_ctr` becomes the bundle's own
        // (`owns_id_ctr`). Between here and that hand-off every later step is
        // fallible, and without this the counters were the one allocation in
        // this function with nothing behind it.
        defer gpa.free(ops.descs);
        errdefer gpa.free(ops.id_ctr);

        // The prefix is byte-identical in both renderings, which is what lets a
        // reader take the dependency and actor list from either one
        // (`bundle/builder.rs:155-156`, `:195`).
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(gpa);
        {
            const actors = try self.mapper.actorList(gpa);
            defer gpa.free(actors);
            try writePrefix(gpa, &prefix, self.change_writer.external.items, actors);
        }

        var body_u: std.ArrayList(u8) = .empty;
        defer body_u.deinit(gpa);
        try body_u.appendSlice(gpa, prefix.items);
        try writeMetaBlock(&body_u, gpa, change_descs);
        const changes_start_u = body_u.items.len;
        try body_u.appendSlice(gpa, changes_data.items);
        const changes_end_u = body_u.items.len;
        try writeMetaBlock(&body_u, gpa, ops.descs);
        const ops_start_u = body_u.items.len;
        try body_u.appendSlice(gpa, ops_data.items);
        const ops_end_u = body_u.items.len;

        var body_c: std.ArrayList(u8) = .empty;
        defer body_c.deinit(gpa);
        {
            var deflated_changes = try deflateBlock(gpa, change_descs, changes_data.items);
            defer deflated_changes.deinit(gpa);
            var deflated_ops = try deflateBlock(gpa, ops.descs, ops_data.items);
            defer deflated_ops.deinit(gpa);
            try body_c.appendSlice(gpa, prefix.items);
            try writeMetaBlock(&body_c, gpa, deflated_changes.descs);
            try body_c.appendSlice(gpa, deflated_changes.data);
            try writeMetaBlock(&body_c, gpa, deflated_ops.descs);
            try body_c.appendSlice(gpa, deflated_ops.data);
        }

        const frame_u = try framed(gpa, body_u.items);
        errdefer gpa.free(frame_u.bytes);
        const frame_c = try framed(gpa, body_c.items);
        errdefer gpa.free(frame_c.bytes);

        return Bundle.fromWritten(
            gpa,
            .{
                .body = frame_u.bytes,
                .owns_body = true,
                .disk = frame_c.bytes,
                .owns_disk = true,
                .changes_data = .init(
                    changes_start_u + frame_u.header_len,
                    changes_end_u + frame_u.header_len,
                ),
                .ops_data = .init(
                    ops_start_u + frame_u.header_len,
                    ops_end_u + frame_u.header_len,
                ),
                .id_ctr = ops.id_ctr,
                .owns_id_ctr = true,
                .checksum = chunk.checksumOf(.bundle, body_u.items),
                .header_len = frame_u.header_len,
                .disk_header_len = frame_c.header_len,
            },
            change_descs,
            ops.descs,
        );
    }
};

// ── bundle/storage.rs: the parsed bundle ─────────────────────────────────────

/// A parsed bundle: the chunk, the prefix, the two column blocks, and the
/// materialised op counters (`bundle/storage.rs:24-45`).
///
/// The upstream struct is generic over a read-state typestate that flips to
/// `Verified` only after every row has been walked. This port has no
/// typestate, so [`parse`] does both halves in one call and a `Bundle` is
/// always verified: `parse_following_header` builds the structure
/// (`bundle/storage.rs:151-273`) and `verify` walks every change row and every
/// op row (`bundle/storage.rs:275-295`).
///
/// **Which buffer each borrow points into.** There are two, and they are not
/// the same one:
///
/// * The **column sets** index `body`. `body` is the rebuilt chunk when a
///   column was deflated and the caller's own chunk otherwise, and either way
///   it is the bytes the columns were re-pointed at, so it must outlive the
///   bundle. The keep-alive obligation here is [`parse`]'s and
///   [`parseFramedChunk`]'s, and on the deflate path the bundle holds `body`
///   itself.
/// * **The prefix arrays** `deps` and `actors` borrow the chunk the bundle was
///   read from, which is `disk` when a column was deflated and `body`
///   otherwise — that is, [`Bundle.bytes`] — because `readPrefix` runs at the
///   top of [`parseFramedChunk`], before the DEFLATE pass, and each actor id's
///   bytes are borrowed out of the frame being walked. **Retaining `body`
///   alone is not enough on the deflate path**, and the chunk that must outlive
///   the bundle there is the caller's input, not anything the bundle owns.
///
/// **Copying this copies an owner.** A copy holds the same two chunks, the
/// same prefix arrays, the same column lists and the same counters, so exactly
/// one copy may be torn down. Nothing here is mutated after the parse returns,
/// so the value may be read from another thread while it lives.
pub const Bundle = struct {
    /// The whole chunk, header included, in its uncompressed form. The column
    /// ranges below are offsets into this and the column sets index it, so it
    /// must outlive the bundle — but the prefix arrays `deps` and `actors` do
    /// not borrow it on the deflate path; see the type comment.
    body: []const u8,
    /// Whether `body` is this bundle's to free.
    owns_body: bool,
    /// The on-disk chunk, when it differs from `body` because a column was
    /// deflated. Null for a bundle whose columns were all stored plainly, in
    /// which case `bytes` is the on-disk form.
    disk: ?[]const u8,
    /// Whether `disk` is this bundle's to free.
    owns_disk: bool,
    /// The chunk prefix: dependency hashes the bundle names but does not hold.
    /// **Borrowed from `disk` when a column was deflated and from `body`
    /// otherwise**, which is [`Bundle.bytes`]; see the type comment.
    deps: []ChangeHash,
    /// The chunk prefix: the actor ids the bundle's actor columns index into.
    /// **Borrowed from `disk` when a column was deflated and from `body`
    /// otherwise**, which is [`Bundle.bytes`]; each actor's bytes are a slice
    /// of the chunk, not a copy. See the type comment.
    actors: []ActorId,
    /// The change metadata columns, with ranges relative to `changes_data`.
    changes_cols: RawColumns,
    /// Where the change columns' bytes are inside `body`.
    changes_data: ColumnRange,
    /// The op columns, with ranges relative to `ops_data`.
    ops_cols: RawColumns,
    /// Where the op columns' bytes are inside `body`.
    ops_data: ColumnRange,
    /// Every op's counter, in document order, materialised from the wire's
    /// `ID_CTR_INVERSE` column and the change metadata
    /// (`bundle/storage.rs:77-142`).
    id_ctr: []i64,
    /// Whether `id_ctr` is this bundle's to free.
    owns_id_ctr: bool,
    /// The four checksum bytes the chunk header carries, which are the first
    /// four bytes of the chunk's change hash.
    checksum: [types.checksum_size]u8,
    /// Whether `checksum` was taken over the on-disk body rather than the
    /// in-memory one. A parsed bundle's header sits in front of the bytes it
    /// was read from, so it covers the deflated body; a written bundle records
    /// the uncompressed rendering's hash, as upstream's `header_u` does
    /// (`bundle/builder.rs:184-185`).
    checksum_is_disk: bool,
    /// The number of bytes the chunk header occupies in front of the body. The
    /// ranges above are chunk-relative rather than body-relative, so that they
    /// stay valid for a rebuilt body, which is what upstream's `shift_range`
    /// does (`bundle/builder.rs:189-191`).
    header_len: usize,
    /// The header length of the on-disk chunk, which is not the in-memory one
    /// when a column was deflated, because the length LEB128 may have grown.
    disk_header_len: usize,

    /// The dependencies the bundle names but does not hold, in prefix order.
    /// Borrowed from [`Bundle.bytes`] and owned by nobody: see the type
    /// comment for why that is `disk` and not `body` on the deflate path.
    pub fn depsList(self: *const Bundle) []const ChangeHash {
        return self.deps;
    }

    /// The actor ids the bundle's actor columns index into, in prefix order.
    /// Borrowed from [`Bundle.bytes`] — `disk` on the deflate path — and owned
    /// by nobody: each `ActorId` is a slice of that chunk.
    pub fn actorList(self: *const Bundle) []const ActorId {
        return self.actors;
    }

    /// The on-disk form of the bundle: the deflated chunk when a column was
    /// deflated, and the chunk itself otherwise (`bundle.rs:110-115`).
    pub fn bytes(self: *const Bundle) []const u8 {
        return self.disk orelse self.body;
    }

    /// The on-disk bytes, given away to the caller — [`Bundle.bytes`] without
    /// the copy. [`Document.bundleFragments`] is what takes them.
    ///
    /// **For a bundle this module wrote.** [`Builder.finish`] sets both
    /// ownership flags; a parsed bundle sets neither in the way that matters
    /// here, because it indexes the caller's own bytes ([`parse`]). The two
    /// assertions are the boundary: a bundle that does not own its chunk
    /// cannot hand one over, and the checks are what say so instead of a
    /// caller freeing memory it still holds.
    ///
    /// Everything else the bundle owns is untouched, and [`Bundle.deinit`]
    /// afterwards releases that and not these bytes: the column sets index
    /// into the chunk but never free it ([`RawColumns.deinit`],
    /// `column_spec.zig:441-443`).
    pub fn intoOwnedBytes(self: *Bundle) []u8 {
        if (self.disk) |disk| {
            std.debug.assert(self.owns_disk);
            self.disk = null;
            self.owns_disk = false;
            return @constCast(disk);
        }
        std.debug.assert(self.owns_body);
        self.owns_body = false;
        return @constCast(self.body);
    }

    /// Whether the chunk's recorded checksum matches its body. The framing
    /// already verified it on the way in (`chunk.rs:293-295`), and a written
    /// bundle computed it, so this is always true; it is here because upstream
    /// exposes it (`bundle/storage.rs:64-66`).
    pub fn checksumValid(self: *const Bundle) bool {
        const body = if (self.checksum_is_disk) self.diskBody() else self.uncompressedBody();
        return std.mem.eql(u8, &self.checksum, &chunk.checksumOf(.bundle, body));
    }

    /// The body of the on-disk chunk, which is `disk` less its header, or the
    /// same as [`Bundle.uncompressedBody`] when nothing was deflated.
    fn diskBody(self: *const Bundle) []const u8 {
        const disk = self.disk orelse return self.uncompressedBody();
        return disk[self.disk_header_len..];
    }

    /// Releases the bundle's allocations. The bytes `body` and `disk` point at
    /// are freed too when the bundle owns them; the chunk it was parsed from is
    /// borrowed and never freed, whichever of the two the prefix arrays borrow
    /// it through.
    ///
    /// After this the struct is poisoned, not emptied: `self.*` is set to
    /// undefined, so reading any field afterwards is a use of undefined memory.
    /// One call per value, and — because a copy is a second owner — one call per
    /// copy.
    pub fn deinit(self: *Bundle, gpa: Allocator) void {
        if (self.owns_body) gpa.free(self.body);
        if (self.owns_disk and self.disk != null) gpa.free(self.disk.?);
        gpa.free(self.deps);
        gpa.free(self.actors);
        self.changes_cols.deinit(gpa);
        self.ops_cols.deinit(gpa);
        if (self.owns_id_ctr) gpa.free(self.id_ctr);
        self.* = undefined;
    }

    /// The body of the uncompressed chunk, which is `body` less its header.
    /// The ranges are chunk-relative, so this is what a checksum is taken over
    /// and what a caller wanting the columns alone should index.
    fn uncompressedBody(self: *const Bundle) []const u8 {
        return self.body[self.header_len..];
    }

    /// Assembles a bundle the writer just produced. The descriptors are the
    /// writer's own buffers; the column **data** is not passed in at all,
    /// because it is not the bundle's to have.
    ///
    /// **Both sets are built over the chunk `raw` carries, and that is the
    /// whole of this function's data ownership.** `Builder.finish` builds the
    /// two data blocks in `changes_data`/`ops_data`, `ArrayList`s whose
    /// `defer`s free them the moment `finish` returns, and it then
    /// `appendSlice`s each of them into `body_u` — which is the chunk the
    /// bundle owns. Handing the writer's scratch buffers here produced a
    /// `Bundle` whose `changes_cols.data` and `ops_cols.data` pointed into
    /// freed heap the instant `Document.bundle` returned it: `RawColumns.init`
    /// borrows `data` and never copies it (`src/storage/column_spec.zig`:408),
    /// so every `ChangeIter.init(b.changes_cols, …)` and `OpIter.init(b.ops_cols, …)`
    /// read freed memory, and the value could not reproduce its own columns —
    /// which is the use `Builder.finish`'s own doc advertises ("the
    /// uncompressed form the writer iterates over").
    ///
    /// **The descriptor lengths reproduce the same cumulative layout**, so
    /// indexing the window rather than the scratch buffer changes no offset:
    /// `RawColumns.init` computes `columns[i].range` by summing the entries'
    /// lengths from zero (`raw_column.rs:232-247`), and the window *is* those
    /// `parse` does on the rebuild path, where it re-points both fields at
    /// `out.body[changes_start..changes_end]` after inflating — "the sets are
    /// re-pointed at the bytes the bundle keeps" — and the write path had no
    /// equivalent step until now.
    fn fromWritten(
        gpa: Allocator,
        raw: Written,
        change_descs: []const ColumnDesc,
        ops_descs: []const ColumnDesc,
    ) WriteError!Bundle {
        // **The two chunks are the caller's on every exit, a failed one
        // included.** [`Builder.finish`] arms the `errdefer`s that free them
        // before it calls, and `raw` is a by-value copy, so releasing them
        // here as well freed the same two allocations a second time — on
        // exactly the paths an induced allocation failure takes.

        var in: Input = .init(raw.body);
        in.skip(raw.header_len);
        var prefix = try readPrefix(gpa, &in);
        errdefer prefix.deinit(gpa);

        // **Windows into the chunk, and the descriptor lengths are the
        // layout.** `slice` is the same bound check the parse path's
        // `readColumnBlock` goes through, so a range that did not fit the
        // chunk is a `ParseError` rather than a slice past the end; nothing
        // here can reach it — both ranges are computed in `finish` from the
        // very lengths it just appended — and it costs no allocation.
        const changes_cols = try RawColumns.init(
            gpa,
            change_descs,
            try raw.changes_data.slice(raw.body),
        );
        errdefer changes_cols.deinit(gpa);
        const ops_cols = try RawColumns.init(
            gpa,
            ops_descs,
            try raw.ops_data.slice(raw.body),
        );
        errdefer ops_cols.deinit(gpa);

        return .{
            .body = raw.body,
            .owns_body = raw.owns_body,
            .disk = raw.disk,
            .owns_disk = raw.owns_disk,
            .deps = prefix.deps,
            .actors = prefix.actors,
            .changes_cols = changes_cols,
            .changes_data = raw.changes_data,
            .ops_cols = ops_cols,
            .ops_data = raw.ops_data,
            .id_ctr = raw.id_ctr,
            .owns_id_ctr = raw.owns_id_ctr,
            .checksum = raw.checksum,
            .checksum_is_disk = false,
            .header_len = raw.header_len,
            // **The deflated chunk's own header length, not the in-memory
            // one.** `Builder.finish` measured both — `frame_u.header_len` and
            // `frame_c.header_len` — and the two differ whenever a column was
            // deflated and the body length's LEB128 grew. Reading the
            // uncompressed length out of the deflated chunk is what
            // `Bundle.diskBody` indexes with, and the value `finish` computed
            // for it was dropped here and replaced with the other one.
            .disk_header_len = raw.disk_header_len,
        };
    }
};

/// What `Builder.finish` hands to `Bundle.fromWritten`: the framing and the
/// two data ranges.
const Written = struct {
    body: []u8,
    owns_body: bool,
    disk: ?[]u8,
    owns_disk: bool,
    changes_data: ColumnRange,
    ops_data: ColumnRange,
    id_ctr: []i64,
    owns_id_ctr: bool,
    checksum: [types.checksum_size]u8,
    header_len: usize,
    disk_header_len: usize,
};

/// Topological order, the order the change columns are written in
/// (`bundle/builder.rs:59`).
fn metaLessByBuilder(_: void, a: BundleMetadata, b: BundleMetadata) bool {
    return a.builder < b.builder;
}

/// The chunk prefix: the dependency count and hashes, then the actor count and
/// length-prefixed actor ids (`bundle/builder.rs:153-166`).
fn writePrefix(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    deps: []const ChangeHash,
    actors: []const ActorId,
) WriteError!void {
    try leb128.appendUnsigned(out, gpa, deps.len);
    for (deps) |d| try out.appendSlice(gpa, &d.bytes);
    try leb128.appendUnsigned(out, gpa, actors.len);
    for (actors) |a| {
        try leb128.appendUnsigned(out, gpa, a.bytes.len);
        try out.appendSlice(gpa, a.bytes);
    }
}

/// A body framed as a bundle chunk, with the header length so a caller can
/// shift a data range from body-relative to chunk-relative
/// (`bundle/builder.rs:184-191`).
const Frame = struct {
    bytes: []u8,
    header_len: usize,
};

/// The `4 + 4 + 1 + ulebsize(len)` bytes `chunk.writeChunk` puts in front of a
/// body (`chunk.rs:203-207`, `:232-236`).
fn framed(gpa: Allocator, body: []const u8) Allocator.Error!Frame {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try chunk.writeChunk(&out, gpa, .bundle, body);
    return .{
        .bytes = try out.toOwnedSlice(gpa),
        .header_len = chunk.magic.len + types.checksum_size + 1 + leb128.unsignedSize(body.len),
    };
}

// ── bundle/storage.rs: reading a bundle ──────────────────────────────────────

/// Reads a whole bundle chunk, verifies it, and walks every row
/// (`bundle.rs:151-166`, `bundle/storage.rs:151-295`).
///
/// `bytes` is one complete framed chunk: magic, checksum, type byte, LEB128
/// length, body, and nothing after it. `chunk.parseChunk` checks all of that
/// and reports `error.InvalidMagic`, `error.InvalidChecksum`,
/// `error.InvalidChunkType`, `error.UnexpectedEnd`, `error.LengthExceedsInput`
/// or `error.TrailingBytes`; a chunk of any type but `bundle` is
/// `error.InvalidChunkType`, the same refusal `change_chunk.zig` makes for a
/// `document` or `bundle` chunk it cannot read.
///
/// **The keep-alive obligation is `bytes` itself, not the bundle's own body.**
/// With nothing deflated the columns index `bytes` and the prefix arrays borrow
/// it, and the bundle holds no chunk of its own. With a column deflated the
/// bundle holds a rebuilt uncompressed copy in `body`, the prefix arrays still
/// borrow `bytes` — `readPrefix` runs before the DEFLATE pass — and `bytes`
/// becomes `disk`. `deinit` releases whatever it allocated; the chunk it was
/// read from is never freed, and it must stay alive for as long as the bundle
/// is used. See the [`Bundle`] type comment for which borrow points where.
///
/// A bundle with nothing compressed is read in place: the column sets index
/// straight into `bytes`, which is upstream's zero-copy fast path
/// (`bundle/storage.rs:183-209`).
///
/// This is [`parseFramedChunk`] over a chunk read from `bytes`, and it is for
/// a caller holding the whole chunk and nothing else. A bundle that is one
/// chunk of a document stream has no such door — there the chunk has already
/// been read, and the bytes it came from are the chunk's own.
pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Bundle {
    return parseFramedChunk(try chunk.parseChunk(bytes), gpa);
}

/// [`parse`] over a chunk the framing layer has already read and verified,
/// which is the shape a bundle arrives in when it is one chunk of a document
/// stream rather than a file of its own.
///
/// **The chunk carries the bytes it was read from**
/// ([`chunk.Chunk.frame`](chunk.zig)), and those are the bytes this reader
/// indexes. A bundle taken out of a multi-chunk stream is therefore the same
/// chunk byte for byte: no header is rebuilt from the body length, nothing is
/// re-encoded to recover the framing, and no copy of the stream is made to
/// hold it. [`Bundle.bytes`] hands back exactly what the stream had.
///
/// **The header length is read off the frame rather than worked out**, which
/// is the same fact about the other end: `data` is the frame's tail, so the
/// two lengths differ by exactly the header that was written — a length
/// LEB128 wider than one byte included. Nothing here reconstructs a framing
/// the layer above already has.
///
/// The bundle is verified as it is read, and a chunk of any type but `bundle`
/// is `error.InvalidChunkType` as it is in [`parse`]; its checksum was checked
/// with it, at [`chunk.parseChunk`].
pub fn parseFramedChunk(c: chunk.Chunk, gpa: Allocator) ParseError!Bundle {
    if (c.typ != .bundle) return error.InvalidChunkType;
    const header_len = c.frame.len - c.data.len;

    var in: Input = .init(c.frame);
    in.skip(header_len);

    // The bundle is assembled in place, so one `errdefer` covers every step and
    // `deinit` is the only cleanup there is: each owned field starts as an
    // empty slice and is replaced by a real allocation, one fallible step at a
    // time, *after* that `errdefer` is armed. Nothing in the literal below can
    // fail, which is the whole point of the shape. A `try` inside a struct
    // literal runs before an `errdefer` could be armed, so an allocation made
    // there has nothing to unwind it and a second one failing leaks the first.
    // An empty slice is the right placeholder because `Allocator.free` of one
    // returns without touching the allocator (`std/mem/Allocator.zig:447`).
    var out: Bundle = .{
        .body = c.frame,
        .owns_body = false,
        .disk = null,
        .owns_disk = false,
        .deps = &.{},
        .actors = &.{},
        .changes_cols = .{ .columns = &.{}, .data = &.{} },
        .changes_data = ColumnRange.empty(),
        .ops_cols = .{ .columns = &.{}, .data = &.{} },
        .ops_data = ColumnRange.empty(),
        .id_ctr = &.{},
        .owns_id_ctr = true,
        .checksum = c.checksum,
        .checksum_is_disk = true,
        .header_len = header_len,
        .disk_header_len = header_len,
    };
    errdefer out.deinit(gpa);

    const prefix = try readPrefix(gpa, &in);
    gpa.free(out.deps);
    gpa.free(out.actors);
    out.deps = prefix.deps;
    out.actors = prefix.actors;
    const prefix_end = in.pos;

    const changes = try readColumnBlock(&in, gpa);
    out.changes_cols.deinit(gpa);
    out.changes_cols = changes.cols;
    out.changes_data = changes.data;
    try out.changes_cols.validate(null);
    const ops = try readColumnBlock(&in, gpa);
    out.ops_cols.deinit(gpa);
    out.ops_cols = ops.cols;
    out.ops_data = ops.data;
    try out.ops_cols.validate(null);

    // Whatever is left after the op data is ignored, which is what upstream
    // does: `parse_following_header` hands back an empty remaining input
    // whatever the cursor position was (`bundle/storage.rs:193-195`,
    // `:257-258`).
    if (out.changes_cols.allUncompressed() and out.ops_cols.allUncompressed()) {
        const id_ctr = try extractIdCtr(gpa, out.changes_cols, out.ops_cols);
        gpa.free(out.id_ctr);
        out.id_ctr = id_ctr;
        try verify(gpa, &out);
        return out;
    }

    // At least one column is a DEFLATE stream. Rebuild a fully inflated chunk
    // with the same section layout, keeping the header and the prefix verbatim
    // and the primed metadata blocks carrying the inflated lengths
    // (`bundle/storage.rs:211-272`).
    var inflated: std.ArrayList(u8) = .empty;
    defer inflated.deinit(gpa);
    try inflated.appendSlice(gpa, c.frame[0..prefix_end]);
    var rebuilt_changes = try inflateColumns(gpa, out.changes_cols);
    defer rebuilt_changes.deinit(gpa);
    try writeMetaBlock(&inflated, gpa, rebuilt_changes.descs);
    const changes_start = inflated.items.len;
    try inflated.appendSlice(gpa, rebuilt_changes.data);
    const changes_end = inflated.items.len;
    var rebuilt_ops = try inflateColumns(gpa, out.ops_cols);
    defer rebuilt_ops.deinit(gpa);
    try writeMetaBlock(&inflated, gpa, rebuilt_ops.descs);
    const ops_start = inflated.items.len;
    try inflated.appendSlice(gpa, rebuilt_ops.data);
    const ops_end = inflated.items.len;

    // Both rebuilt column sets are built before either replaces the one `out`
    // holds, so a failure in the second has somewhere to give the first back.
    // The `errdefer`s are scoped to this block, which the `break` ends: from
    // the assignments below on, `out.deinit` is the one cleanup, and an
    // `errdefer` reaching the rest of the function would free both sets a
    // second time.
    const rebuilt_cols = blk: {
        const new_changes = try RawColumns.init(gpa, rebuilt_changes.descs, rebuilt_changes.data);
        errdefer new_changes.deinit(gpa);
        const new_ops = try RawColumns.init(gpa, rebuilt_ops.descs, rebuilt_ops.data);
        errdefer new_ops.deinit(gpa);
        break :blk .{ .changes = new_changes, .ops = new_ops };
    };
    out.changes_cols.deinit(gpa);
    out.ops_cols.deinit(gpa);
    out.changes_cols = rebuilt_cols.changes;
    out.ops_cols = rebuilt_cols.ops;
    out.changes_data = .init(changes_start, changes_end);
    out.ops_data = .init(ops_start, ops_end);
    out.body = try inflated.toOwnedSlice(gpa);
    out.owns_body = true;
    out.disk = c.frame;
    // The column ranges are relative to their data block, and the data block is
    // a window of the rebuilt chunk rather than the scratch buffer it was
    // assembled in, so the sets are re-pointed at the bytes the bundle keeps.
    out.changes_cols.data = out.body[changes_start..changes_end];
    out.ops_cols.data = out.body[ops_start..ops_end];

    // The counters are built from the *rebuilt* sets, not from the ones that
    // came off the wire. `extractIdCtr` decodes the `ID_CTR_INVERSE` column as
    // a delta stream and walks the change metadata with `ChangeIter`, and
    // `ColumnSpec.encoding` masks bit 3 alone (`column_spec.zig:147`,
    // `:202-204`), so a DEFLATE-marked delta column matches just the same and
    // `col.bytes(ops.data)` would hand a raw DEFLATE stream to
    // `delta.Delta(?i64).decodeAll`. Building them here, from the inflated
    // bytes, is what upstream does (`bundle/storage.rs:242-255`): the pass runs
    // first and the counters are computed from the same columns
    // `OpIter` and `ChangeIter` then read.
    const id_ctr = try extractIdCtr(gpa, out.changes_cols, out.ops_cols);
    gpa.free(out.id_ctr);
    out.id_ctr = id_ctr;
    try verify(gpa, &out);
    return out;
}

/// Walks every change row and every op row, which is what flips upstream's
/// `Unverified` typestate to `Verified` (`bundle/storage.rs:275-295`).
fn verify(gpa: Allocator, b: *const Bundle) ParseError!void {
    var changes = try ChangeIter.init(b.changes_cols, gpa);
    defer changes.deinit();
    while (try changes.next()) |_| {}

    var ops = try OpIter.init(b.ops_cols, b.id_ctr, gpa);
    defer ops.deinit();
    while (try ops.next()) |_| {}
}

/// The prefix: the dependency hashes the bundle names but does not hold, and
/// the actor table its actor columns index into (`bundle/storage.rs:161-170`).
const Prefix = struct {
    deps: []ChangeHash,
    actors: []ActorId,

    fn deinit(self: *Prefix, gpa: Allocator) void {
        gpa.free(self.deps);
        gpa.free(self.actors);
    }
};

/// Reads the prefix from `in`. The hashes and actor bytes are borrowed from
/// whatever buffer `in` walks, so the prefix has no lifetime of its own and
/// the two arrays are all it allocates.
fn readPrefix(gpa: Allocator, in: *Input) ParseError!Prefix {
    var sink: PrefixSink = .{ .in = in, .gpa = gpa };
    try in.readCountThen(&sink, types.hash_size, PrefixSink.collectDeps);
    const deps = sink.deps.?;
    errdefer gpa.free(deps);
    try in.readCountThen(&sink, 1, PrefixSink.collectActors);
    return .{ .deps = deps, .actors = sink.actors.? };
}

/// The `readCountThen` destination for the two length-prefixed sections of the
/// prefix.
const PrefixSink = struct {
    in: *Input,
    gpa: Allocator,
    deps: ?[]ChangeHash = null,
    actors: ?[]ActorId = null,

    /// A dependency is 32 raw bytes with no length prefix of its own
    /// (`change.rs:463-473`), so the floor `readCountThen` divides the
    /// remaining input by is the hash size.
    fn collectDeps(self: *PrefixSink, count: usize) ParseError!void {
        // `readCountThen` proved `count <= remaining / hash_size`, so this
        // allocation is bounded by the input.
        const out = try self.gpa.alloc(ChangeHash, count);
        errdefer self.gpa.free(out);
        for (out) |*d| {
            @memcpy(&d.bytes, try self.in.take(types.hash_size));
        }
        self.deps = out;
    }

    /// An actor is a uleb128 byte length and that many bytes
    /// (`change.rs:503-510`). The floor is one byte, which is the length
    /// prefix of the shortest actor there is.
    fn collectActors(self: *PrefixSink, count: usize) ParseError!void {
        const out = try self.gpa.alloc(ActorId, count);
        errdefer self.gpa.free(out);
        for (out) |*a| a.* = .init(try self.in.readStrBytes());
        self.actors = out;
    }
};

/// A column metadata block and the data block it describes. `data` is a range
/// into the chunk; `cols` indexes into the bytes that range covers.
const ColumnBlock = struct {
    cols: RawColumns,
    data: ColumnRange,
};

/// Reads one column metadata block and the data block that follows it
/// (`bundle/storage.rs:172-181`).
fn readColumnBlock(in: *Input, gpa: Allocator) ParseError!ColumnBlock {
    var sink: DescSink = .{ .in = in, .gpa = gpa };
    try in.readCountThen(&sink, min_desc_size, DescSink.collect);
    const descs = sink.descs orelse &.{};
    defer gpa.free(sink.descs orelse &.{});

    // Order over the descriptors as they were read, before `RawColumns.init`
    // drops the zero-length ones (`column_spec.zig:432-437`). Upstream parses
    // each block with `RawColumns::parse` (`bundle/storage.rs:173`, `:179`),
    // which keeps every descriptor the block listed and runs
    // `are_normal_sorted` over that whole set (`raw_column.rs:232-253`,
    // `:289-297`), so a block whose first column is empty still has to be
    // ascending from there. This is where the check belongs — before the data
    // block is located, as upstream puts it.
    try descsInNormalOrder(descs);

    // The data block is exactly the sum of the declared lengths, so a sum past
    // what is left means a column's length runs past the block. Checked before
    // `take`, so a hostile length costs a comparison and not a read.
    if (sink.total > in.remaining()) return error.LengthExceedsInput;
    // `in` has already stepped over the chunk header, so its position is an
    // offset into the whole chunk and needs no further shifting.
    const start = in.pos;
    const data = try in.take(sink.total);
    return .{
        .cols = try RawColumns.init(gpa, descs, data),
        .data = .init(start, start + data.len),
    };
}

/// The block's descriptors, in ascending normalized order, or
/// `error.InvalidColumnSpec`.
///
/// The whole set takes part, zero-length descriptors included, because upstream
/// compares the columns the metadata block listed rather than the columns that
/// survived construction (`raw_column.rs:232-253`, `:289-297`). A repeat is not
/// a decrease and so passes here; `RawColumns.validate` reports one, as
/// `error.DuplicateColumn`, once the empty columns are gone.
fn descsInNormalOrder(descs: []const ColumnDesc) ParseError!void {
    var previous: ?ColumnSpec = null;
    for (descs) |desc| {
        if (previous) |prev| {
            if (desc.spec.compare(prev) == .lt) return error.InvalidColumnSpec;
        }
        previous = desc.spec;
    }
}

/// The `readCountThen` destination for a column metadata block. A descriptor is
/// a specification and a length, both LEB128, and the block is a count of them
/// followed by the data they describe (`raw_column.rs:218-247`).
const DescSink = struct {
    in: *Input,
    gpa: Allocator,
    /// The descriptors read. Null only while the block is being read; a zero
    /// count leaves it an empty, non-null slice.
    descs: ?[]ColumnDesc = null,
    /// The sum of the declared lengths: the length of the data block. Saturated,
    /// because the lengths came off the wire and can be absurd, and a
    /// saturated sum is larger than any real input, so the comparison that
    /// follows catches it (`raw_column.rs:235-239`).
    total: usize = 0,

    fn collect(self: *DescSink, count: usize) ParseError!void {
        const descs = try self.gpa.alloc(ColumnDesc, count);
        errdefer self.gpa.free(descs);
        for (descs) |*d| {
            // The specification is a LEB128 u32: the id is 28 bits and the
            // encoding and DEFLATE flag three more, so a wider value is not a
            // specification (`raw_column.rs:226`).
            const spec_raw = std.math.cast(u32, try self.in.takeUleb()) orelse
                return error.Overflow;
            const len = std.math.cast(usize, try self.in.takeUleb()) orelse
                return error.TooLarge;
            d.* = ColumnDesc.init(ColumnSpec.fromRaw(spec_raw), len);
            self.total = self.total +| len;
        }
        self.descs = descs;
    }
};

/// The inflated form of a column set: every column's bytes uncompressed, with
/// the DEFLATE bit taken off its specification (`raw_column.rs:89-102`).
fn inflateColumns(gpa: Allocator, cols: RawColumns) ParseError!Block {
    const descs = try gpa.alloc(ColumnDesc, cols.columns.len);
    errdefer gpa.free(descs);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);
    for (cols.columns, descs) |col, *d| {
        if (!col.isCompressed()) {
            const plain = try col.bytes(cols.data);
            try data.appendSlice(gpa, plain);
            d.* = ColumnDesc.init(col.spec, plain.len);
            continue;
        }
        // A column that claims to be deflated and is not a DEFLATE stream is
        // `error.InvalidDeflate`, which is what upstream reports for a bad
        // stream (`raw_column.rs:94-97`). An allocation that fails while the
        // output buffer grows is not a bad stream, so it keeps its own name:
        // as `InvalidDeflate` it would tell a caller its document is malformed
        // when the document is fine and only the memory is short.
        const inflated = chunk.decompressRaw(gpa, try col.bytes(cols.data)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidDeflate,
        };
        defer gpa.free(inflated);
        try data.appendSlice(gpa, inflated);
        d.* = ColumnDesc.init(col.spec.inflated(), inflated.len);
    }
    return .{ .descs = descs, .data = try data.toOwnedSlice(gpa) };
}

// ── bundle/storage.rs: the op counters ───────────────────────────────────────

/// Materialises each op's counter in document order
/// (`bundle/storage.rs:77-142`).
///
/// The wire carries the inverse permutation, so the counters have to be
/// reconstructed: walk the change metadata in canonical `(actor, seq)` order,
/// enumerate each change's `start_op..=max_op` to learn the counter the `k`th
/// op has in that order, and place it at document position `inverse[k]`.
///
/// A bundle written before the switch carries the counters directly in a
/// `Delta` column of id 2, which is decoded as-is; the inverse column wins if
/// both appear, because it is the current format and the other is only
/// accepted for compatibility (`bundle/storage.rs:17-22`, `:103-138`).
fn extractIdCtr(gpa: Allocator, changes: RawColumns, ops: RawColumns) ParseError![]i64 {
    var inverse_bytes: ?[]const u8 = null;
    var legacy_bytes: ?[]const u8 = null;
    for (ops.columns) |*col| {
        if (col.spec.encoding() != .delta) continue;
        const bytes = try col.bytes(ops.data);
        switch (col.spec.id()) {
            op_col.id_ctr_inverse => inverse_bytes = bytes,
            op_col.id => legacy_bytes = bytes,
            else => {},
        }
    }

    if (inverse_bytes) |bytes| {
        // `decodeAll` counts the values before it allocates, so a repeat run
        // that expands a handful of bytes into millions of values costs one
        // allocation and is refused as `error.TooLarge` above the codec's own
        // ceiling (`hexane/rle.zig:69`).
        const decoded = try delta.Delta(?i64).decodeAll(bytes, gpa);
        defer gpa.free(decoded);
        const inverse = try gpa.alloc(i64, decoded.len);
        defer gpa.free(inverse);
        for (decoded, inverse) |d, *i| i.* = d orelse return error.InvalidValue;

        const rows = try changeOrder(gpa, changes);
        defer gpa.free(rows);

        // One counter per op. `inverse.len()` is the op count the wire claims,
        // and it is what bounds every loop below: the walk stops with
        // `error.TooManyOps` as soon as it runs past it, and the final check
        // catches a bundle that claims fewer ops than it has counters for.
        const counters = try gpa.alloc(i64, inverse.len);
        errdefer gpa.free(counters);
        @memset(counters, 0);
        var k: usize = 0;
        for (rows) |row| {
            if (row.max_op < row.start_op) continue;
            var ctr = row.start_op;
            while (true) {
                if (k >= inverse.len) return error.TooManyOps;
                const doc_pos = inverse[k];
                if (doc_pos < 0) return error.InvalidValue;
                const at = std.math.cast(usize, doc_pos) orelse return error.InvalidValue;
                if (at >= counters.len) return error.InvalidValue;
                counters[at] = asI64(ctr);
                k += 1;
                if (ctr == row.max_op) break;
                ctr += 1;
            }
        }
        if (k != inverse.len) return error.TooManyOps;
        return counters;
    }

    if (legacy_bytes) |bytes| {
        const decoded = try delta.Delta(?i64).decodeAll(bytes, gpa);
        defer gpa.free(decoded);
        const out = try gpa.alloc(i64, decoded.len);
        errdefer gpa.free(out);
        for (decoded, out) |d, *i| i.* = d orelse return error.InvalidValue;
        return out;
    }

    // No ops at all, so neither counter column is present.
    return gpa.alloc(i64, 0);
}

/// One change's `(actor, seq, start_op, max_op)`, the four fields the counter
/// reconstruction needs.
const ChangeOrder = struct {
    actor: ActorIdx,
    seq: u64,
    start_op: u64,
    max_op: u64,
};

/// Canonical `(actor, seq)` order, the order the counter reconstruction walks
/// the change metadata in (`bundle/storage.rs:112`).
fn changeOrderLess(_: void, a: ChangeOrder, b: ChangeOrder) bool {
    if (a.actor != b.actor) return a.actor < b.actor;
    return a.seq < b.seq;
}

/// The change block's rows in canonical `(actor, seq)` order. The caller owns
/// the array.
fn changeOrder(gpa: Allocator, changes: RawColumns) ParseError![]ChangeOrder {
    var iter = try ChangeIter.init(changes, gpa);
    defer iter.deinit();
    var out: std.ArrayList(ChangeOrder) = .empty;
    errdefer out.deinit(gpa);
    while (try iter.next()) |row| {
        try out.append(gpa, .{
            .actor = row.actor,
            .seq = row.seq,
            .start_op = row.start_op,
            .max_op = row.max_op,
        });
    }
    std.mem.sortUnstable(ChangeOrder, out.items, {}, changeOrderLess);
    return out.toOwnedSlice(gpa);
}

// ── bundle/builder.rs: the readers ───────────────────────────────────────────

/// One change's metadata, as a bundle stores it (`bundle.rs:122-133`).
///
/// `actor` is a *bundle* actor index, into [`Bundle.actorList`], not a
/// document one: the writer rewrote it through the actor mapper on the way
/// into the column. `deps` are indices too — below `changes.len` for a change
/// the bundle holds, and `changes.len + k` for the `k`th hash in
/// [`Bundle.depsList`] (`bundle/builder.rs:277-303`).
///
/// Copying this is copying a row's borrows, not a second owner: `message` and
/// `extra` point into the bundle's column data and `deps` into the iterator's
/// scratch list, so a copy must not outlive either. Nothing here is mutated, so
/// a copy may be read from another thread while the iterator lives.
pub const BundleChange = struct {
    actor: ActorIdx,
    /// Always null. Upstream carries the field and never fills it
    /// (`bundle/builder.rs:701`); it is here because upstream's struct has it.
    author: ?ActorIdx,
    seq: u64,
    start_op: u64,
    max_op: u64,
    /// The change's commit time, in **seconds since the Unix epoch**, exactly
    /// as [`BundleMetadata.timestamp`] carries it and exactly as this column
    /// stores it: one delta cell per change, decoded as-is, with no unit
    /// conversion. A bundle written in milliseconds carries a different column
    /// and different bytes, and nothing at this surface converts it.
    timestamp: i64,
    message: ?[]const u8,
    /// The dependency indices, borrowed from the iterator and valid until the
    /// next call to [`ChangeIter.next`].
    deps: []const u64,
    extra: []const u8,
};

/// Walks a bundle's change metadata, one row at a time
/// (`bundle/builder.rs:567-711`).
///
/// A column the change block does not define is `error.InvalidColumnSpec`, the
/// port of `ParseError::InvalidChangeColumn`
/// (`bundle/builder.rs:643`). Upstream builds each row's dependency vector
/// with `Vec::with_capacity(dep_count)`, so a hostile count sizes an
/// allocation before the column is read; here the vector grows one entry at a
/// time, so a count larger than the dependency column holds stops at the first
/// read past its end.
///
/// **The row this hands back borrows from the iterator and from the bundle.**
/// [`BundleChange.deps`] is the iterator's own scratch list and lasts until the
/// next [`ChangeIter.next`] call, which clears and refills it; `message` and
/// `extra` are slices of the bundle's column data. **Copying an iterator copies
/// an owner**: two copies share one scratch list and one set of decoders, so
/// exactly one copy may be torn down and only one may be advanced at a time.
pub const ChangeIter = struct {
    actor: encoding.Decoder,
    seq: encoding.Decoder,
    start_op: encoding.Decoder,
    max_op: encoding.Decoder,
    timestamp: encoding.Decoder,
    message: encoding.Decoder,
    dep_count: encoding.Decoder,
    deps: encoding.Decoder,
    extra_count: encoding.Decoder,
    /// The extra bytes, consumed `extra_count` at a time. A row that claims
    /// more than is left is `error.Truncated`; upstream's `split_at` panics
    /// (`bundle/builder.rs:695`).
    extra: []const u8,
    gpa: std.mem.Allocator,
    /// The current row's dependency indices, borrowed into [`BundleChange.deps`].
    scratch: std.ArrayList(u64) = .empty,

    /// An iterator over the change block `cols`, whose data is `cols.data`.
    pub fn init(cols: RawColumns, gpa: std.mem.Allocator) ParseError!ChangeIter {
        var self: ChangeIter = .{
            .actor = try emptyDecoder(),
            .seq = try emptyDecoder(),
            .start_op = try emptyDecoder(),
            .max_op = try emptyDecoder(),
            .timestamp = try emptyDecoder(),
            .message = try emptyDecoder(),
            .dep_count = try emptyDecoder(),
            .deps = try emptyDecoder(),
            .extra_count = try emptyDecoder(),
            .extra = &.{},
            .gpa = gpa,
        };
        for (cols.columns) |*col| {
            const spec = col.spec;
            if (spec.eql(change_specs.actor)) {
                self.actor = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.seq)) {
                self.seq = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.start_op)) {
                self.start_op = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.max_op)) {
                self.max_op = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.timestamp)) {
                self.timestamp = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.message)) {
                self.message = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.dep_count)) {
                self.dep_count = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.deps)) {
                self.deps = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.extra_count)) {
                self.extra_count = try encoding.Decoder.init(spec, try col.bytes(cols.data));
            } else if (spec.eql(change_specs.extra)) {
                self.extra = try col.bytes(cols.data);
            } else {
                return error.InvalidColumnSpec;
            }
        }
        return self;
    }

    /// Releases the dependency scratch, which the iterator owns. The column
    /// bytes belong to the bundle. After this the iterator's scratch list is
    /// gone, so a row held across this call no longer has a live `deps`.
    ///
    /// Unlike the bundle writers' teardowns this does **not** poison the struct:
    /// it releases the one allocation, and the decoders are left holding slices
    /// of the caller's column bytes. Calling it twice frees nothing the second
    /// time; calling `next` afterwards is undefined, because the scratch list it
    /// appends to is gone.
    pub fn deinit(self: *ChangeIter) void {
        self.scratch.deinit(self.gpa);
    }

    /// The next change row, or null once the actor column is exhausted. A row
    /// whose actor is absent ends the iteration too, because an absent actor
    /// is not a change (`bundle/builder.rs:661-664`).
    pub fn next(self: *ChangeIter) ParseError!?BundleChange {
        const actor = try actorCell(&self.actor);
        if (actor == null) return null;
        const seq = try requiredInt(&self.seq);
        const start_op = try requiredInt(&self.start_op);
        const max_op = try requiredInt(&self.max_op);
        const timestamp = (try optionalInt(&self.timestamp)) orelse 0;
        const message = try optionalString(&self.message);

        self.scratch.clearRetainingCapacity();
        const dep_count = (try optionalUint(&self.dep_count)) orelse 0;
        var i: u64 = 0;
        while (i < dep_count) : (i += 1) {
            const dep = try requiredInt(&self.deps);
            try self.scratch.append(self.gpa, @bitCast(dep));
        }

        const extra_count = (try optionalUint(&self.extra_count)) orelse 0;
        const at = std.math.cast(usize, extra_count) orelse return error.TooLarge;
        if (at > self.extra.len) return error.Truncated;
        const extra = self.extra[0..at];
        self.extra = self.extra[at..];

        return .{
            .actor = actor.?,
            .author = null,
            .seq = @bitCast(seq),
            .start_op = @bitCast(start_op),
            .max_op = @bitCast(max_op),
            .timestamp = timestamp,
            .message = message,
            .deps = self.scratch.items,
            .extra = extra,
        };
    }
};

/// Walks a bundle's operations, in document order
/// (`bundle/builder.rs:713-928`).
///
/// `id_ctr` is the materialised counter column the storage layer built; it is
/// read in step with the id actor column, so the op's counter is the two read
/// together (`bundle/builder.rs:797-802`).
///
/// A column the op block does not define is `error.InvalidColumnSpec`, the port
/// of `ParseError::InvalidOpColumn` (`bundle/builder.rs:907`). The id counter
/// column in either encoding is accepted and ignored here, because the storage
/// layer has already turned it into `id_ctr` (`bundle/builder.rs:889-891`).
///
/// **The row this hands back borrows from the iterator and from the bundle.**
/// [`BundleOp.pred`] is the iterator's own scratch list and lasts until the
/// next [`OpIter.next`] call, which clears and refills it; `key`'s `map` string,
/// `mark_name`, and a `value` that is `str` or `bytes` point into the bundle's
/// column data. A row held across a second `next` reads stale or reallocated
/// bytes.
///
/// **Copying an iterator copies an owner**: two copies share one scratch list
/// and one set of decoders, so exactly one copy may be torn down and only one
/// may be advanced at a time.
pub const OpIter = struct {
    obj_actor: encoding.Decoder,
    obj_ctr: encoding.Decoder,
    key_actor: encoding.Decoder,
    key_ctr: encoding.Decoder,
    key_str: encoding.Decoder,
    id_actor: encoding.Decoder,
    insert: encoding.Decoder,
    action: encoding.Decoder,
    value: encoding.Decoder,
    pred_count: encoding.Decoder,
    pred_actor: encoding.Decoder,
    pred_ctr: encoding.Decoder,
    expand: encoding.Decoder,
    mark_name: encoding.Decoder,
    /// The op counters in document order, and how far through them the
    /// iterator is.
    id_ctr: []const i64,
    id_ctr_pos: usize = 0,
    gpa: std.mem.Allocator,
    /// The current row's predecessors, borrowed into [`BundleOp.pred`].
    scratch: std.ArrayList(OpId) = .empty,

    /// An iterator over the op block `cols`, whose data is `cols.data`, reading
    /// each op's counter from `id_ctr`.
    pub fn init(
        cols: RawColumns,
        id_ctr: []const i64,
        gpa: std.mem.Allocator,
    ) ParseError!OpIter {
        var self: OpIter = .{
            .obj_actor = try emptyDecoder(),
            .obj_ctr = try emptyDecoder(),
            .key_actor = try emptyDecoder(),
            .key_ctr = try emptyDecoder(),
            .key_str = try emptyDecoder(),
            .id_actor = try emptyDecoder(),
            .insert = try emptyDecoder(),
            .action = try emptyDecoder(),
            .value = try emptyDecoder(),
            .pred_count = try emptyDecoder(),
            .pred_actor = try emptyDecoder(),
            .pred_ctr = try emptyDecoder(),
            .expand = try emptyDecoder(),
            .mark_name = try emptyDecoder(),
            .id_ctr = id_ctr,
            .gpa = gpa,
        };
        var value_meta: ?[]const u8 = null;
        var value_raw: ?[]const u8 = null;
        for (cols.columns) |*col| {
            const spec = col.spec;
            const bytes = try col.bytes(cols.data);
            if (spec.eql(op_specs.obj_actor)) {
                self.obj_actor = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.obj_ctr)) {
                self.obj_ctr = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.key_actor)) {
                self.key_actor = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.key_ctr)) {
                self.key_ctr = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.key_str)) {
                self.key_str = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.id_actor)) {
                self.id_actor = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.id_ctr_inverse) or
                (spec.id() == op_col.id and spec.encoding() == .delta))
            {
                // Handled at the storage layer, which is what the two
                // `ID_CTR` arms in upstream's match are for
                // (`bundle/builder.rs:889-891`).
            } else if (spec.eql(op_specs.insert)) {
                self.insert = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.action)) {
                self.action = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.value_meta)) {
                value_meta = bytes;
            } else if (spec.eql(op_specs.value)) {
                value_raw = bytes;
            } else if (spec.eql(op_specs.pred_count)) {
                self.pred_count = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.pred_actor)) {
                self.pred_actor = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.pred_ctr)) {
                self.pred_ctr = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.expand)) {
                self.expand = try encoding.Decoder.init(spec, bytes);
            } else if (spec.eql(op_specs.mark_name)) {
                self.mark_name = try encoding.Decoder.init(spec, bytes);
            } else {
                return error.InvalidColumnSpec;
            }
        }
        // The value pair is read in lockstep by one decoder, which is what
        // keeps the metadata words and the payloads aligned and makes a payload
        // longer than the value column an error rather than a read past the
        // end. An absent value column is an empty payload column, which is how
        // a block of nulls, booleans and integers reads
        // (`bundle/builder.rs:827-830`).
        self.value = try encoding.Decoder.initValuePair(
            op_specs.value_meta,
            value_meta orelse &.{},
            value_raw orelse &.{},
        );
        return self;
    }

    /// Releases the predecessor scratch, which the iterator owns. The column
    /// bytes belong to the bundle. After this the iterator's scratch list is
    /// gone, so a row held across this call no longer has a live `pred`.
    ///
    /// Unlike the bundle writers' teardowns this does **not** poison the struct:
    /// it releases the one allocation, and the decoders are left holding slices
    /// of the caller's column bytes. Calling it twice frees nothing the second
    /// time; calling `next` afterwards is undefined, because the scratch list it
    /// appends to is gone.
    pub fn deinit(self: *OpIter) void {
        self.scratch.deinit(self.gpa);
    }

    /// The next operation, or null once the id actor column is exhausted. An op
    /// id that will not load ends the iteration rather than failing
    /// (`bundle/builder.rs:799-802`).
    pub fn next(self: *OpIter) ParseError!?BundleOp {
        const id_actor = try actorCell(&self.id_actor);
        const ctr: ?i64 = if (self.id_ctr_pos < self.id_ctr.len)
            self.id_ctr[self.id_ctr_pos]
        else
            null;
        // The counter cursor advances once per row the id actor column yields,
        // whether or not the pair makes an op id: upstream reads it with
        // `self.id_ctr.next()` before it tries to build the id
        // (`bundle/builder.rs:797-802`).
        self.id_ctr_pos += 1;
        const id = idCtr(id_actor, ctr) orelse return null;

        const obj = try objId(
            try actorCell(&self.obj_actor),
            try optionalInt(&self.obj_ctr),
        );
        const key = try KeyRef.tryLoad(
            try optionalString(&self.key_str),
            try actorCell(&self.key_actor),
            try optionalInt(&self.key_ctr),
        );
        const action_code = (try optionalUint(&self.action)) orelse
            return error.MissingColumn;
        if (action_code > std.math.maxInt(u8)) return error.InvalidAction;
        const value = (try self.value.nextValue()) orelse return error.MissingColumn;

        self.scratch.clearRetainingCapacity();
        const pred_count = (try optionalUint(&self.pred_count)) orelse 0;
        var i: u64 = 0;
        while (i < pred_count) : (i += 1) {
            try self.scratch.append(self.gpa, idCtr(
                try actorCell(&self.pred_actor),
                try optionalInt(&self.pred_ctr),
            ) orelse return error.InvalidPath);
        }

        return .{
            .id = id,
            .obj = obj,
            .key = key,
            .action = try Action.fromCode(@intCast(action_code)),
            .value = value,
            .insert = try optionalBoolean(&self.insert) orelse false,
            .expand = try optionalBoolean(&self.expand) orelse false,
            .mark_name = try optionalString(&self.mark_name),
            .pred = self.scratch.items,
        };
    }
};

/// A cursor over no bytes at all, which reads as a column that is not there:
/// every value it would produce is absent (`bundle/builder.rs:619-628`).
fn emptyDecoder() ParseError!encoding.Decoder {
    return encoding.Decoder.init(ColumnSpec.make(0, .delta, false), &.{});
}

/// An actor cell as an actor index, or null when the row is absent.
fn actorCell(dec: *encoding.Decoder) ParseError!?ActorIdx {
    const cell = (try dec.next()) orelse return null;
    return switch (cell) {
        .null_value => null,
        .uint => |a| std.math.cast(ActorIdx, a) orelse error.Overflow,
        else => error.InvalidValue,
    };
}

/// A signed cell, where an absent row is the same as the end of the column.
fn optionalInt(dec: *encoding.Decoder) ParseError!?i64 {
    const cell = (try dec.next()) orelse return null;
    return switch (cell) {
        .null_value => null,
        .int => |i| i,
        else => error.InvalidValue,
    };
}

/// A signed cell that must be there: a value column the row needed but the
/// block did not carry is `error.MissingColumn`, the port of
/// `ReadOpError::MissingValue` (`bundle/builder.rs:665-679`).
fn requiredInt(dec: *encoding.Decoder) ParseError!i64 {
    return (try optionalInt(dec)) orelse error.MissingColumn;
}

/// An unsigned cell, where an absent row is the same as the end of the column.
fn optionalUint(dec: *encoding.Decoder) ParseError!?u64 {
    const cell = (try dec.next()) orelse return null;
    return switch (cell) {
        .null_value => null,
        .uint => |u| u,
        else => error.InvalidValue,
    };
}

/// A boolean cell. A boolean column has no absent row, so an exhausted column
/// reads as absent and the caller supplies the column's default
/// (`bundle/builder.rs:818-819`).
fn optionalBoolean(dec: *encoding.Decoder) ParseError!?bool {
    const cell = (try dec.next()) orelse return null;
    return switch (cell) {
        .boolean => |b| b,
        else => error.InvalidValue,
    };
}

/// A string cell, borrowed from the column's bytes.
fn optionalString(dec: *encoding.Decoder) ParseError!?[]const u8 {
    const cell = (try dec.next()) orelse return null;
    return switch (cell) {
        .null_value => null,
        .string => |s| s,
        else => error.InvalidValue,
    };
}

/// An op id from its two columns (`op_set2/op_set/op_iter.rs:196-208`). Either
/// half missing, or a negative counter, is not an op id.
fn idCtr(actor: ?ActorIdx, ctr: ?i64) ?OpId {
    const a = actor orelse return null;
    const c = ctr orelse return null;
    if (c < 0) return null;
    return OpId.init(std.math.cast(u32, c) orelse return null, a);
}

/// An object id from its two columns (`op_set2/op_set/op_iter.rs:210-233`). A
/// counter of zero is the root whatever the actor column says, and a
/// half-present id is not an object id at all.
fn objId(actor: ?ActorIdx, ctr: ?i64) ParseError!ExId {
    if (actor == null and ctr == null) return .root;
    const a = actor orelse return error.InvalidPath;
    const c = ctr orelse return error.InvalidPath;
    if (c < 0) return error.InvalidPath;
    if (c == 0) return .root;
    return .{ .id = OpId.init(std.math.cast(u32, c) orelse return error.Overflow, a) };
}

const testing = std.testing;

// ── The reference fixtures ───────────────────────────────────────────────────
//
// Three bundles automerge 0.12.0 itself wrote, captured by building a document
// with the reference rlib and printing `Bundle::bytes()`. They are here so this
// port's reader is pinned to bytes the reference produced, not to bytes this
// port produced.
//
// All three come from a document whose only actor is
// `aabbccddeeff00112233445566778899`, and each is the bundle of every change
// in the document.

/// A map with two properties set by two changes: `"aaa" = "aaa"` and
/// `"bbb" = 42`. 111 bytes, nothing deflated, eight of the sixteen op columns
/// present.
const reference_simple = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0xc7, 0xa4, 0x97, 0x81, 0x03, 0x65, 0x00, 0x01,
    0x10, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44,
    0x55, 0x66, 0x77, 0x88, 0x99, 0x09, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02,
    0x23, 0x02, 0x33, 0x02, 0x45, 0x02, 0x50, 0x03, 0x53, 0x02, 0x60, 0x02,
    0x02, 0x00, 0x02, 0x01, 0x02, 0x01, 0x02, 0x01, 0x02, 0x00, 0x00, 0x02,
    0x7e, 0x00, 0x01, 0x7f, 0x00, 0x02, 0x00, 0x08, 0x15, 0x09, 0x21, 0x02,
    0x34, 0x01, 0x42, 0x02, 0x56, 0x03, 0x57, 0x04, 0x70, 0x02, 0xb3, 0x01,
    0x03, 0x7e, 0x03, 0x61, 0x61, 0x61, 0x03, 0x62, 0x62, 0x62, 0x02, 0x00,
    0x02, 0x02, 0x01, 0x7e, 0x36, 0x14, 0x61, 0x61, 0x61, 0x2a, 0x02, 0x00,
    0x7e, 0x00, 0x01,
};

/// One change putting a 400-byte byte string under `"padding"`. 373 bytes on
/// disk, and the one fixture whose value column is deflated: its specification
/// is `0x5f` rather than `0x57`, and its 400 bytes are stored as a 270-byte
/// DEFLATE stream.
const reference_big = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0xc0, 0xa1, 0x22, 0x41, 0x03, 0xea, 0x02, 0x00,
    0x01, 0x10, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33,
    0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x08, 0x01, 0x02, 0x03, 0x02, 0x13,
    0x02, 0x23, 0x02, 0x33, 0x02, 0x45, 0x02, 0x50, 0x02, 0x60, 0x02, 0x7f,
    0x00, 0x7f, 0x01, 0x7f, 0x01, 0x7f, 0x01, 0x7f, 0x00, 0x00, 0x01, 0x7f,
    0x00, 0x7f, 0x00, 0x08, 0x15, 0x09, 0x21, 0x02, 0x34, 0x01, 0x42, 0x02,
    0x56, 0x03, 0x5f, 0x8e, 0x02, 0x70, 0x02, 0xb3, 0x01, 0x02, 0x7f, 0x07,
    0x70, 0x61, 0x64, 0x64, 0x69, 0x6e, 0x67, 0x7f, 0x00, 0x01, 0x7f, 0x01,
    0x7f, 0x87, 0x32, 0x63, 0x60, 0x64, 0x62, 0x66, 0x61, 0x65, 0x63, 0xe7,
    0xe0, 0xe4, 0xe2, 0xe6, 0xe1, 0xe5, 0xe3, 0x17, 0x10, 0x14, 0x12, 0x16,
    0x11, 0x15, 0x13, 0x97, 0x90, 0x94, 0x92, 0x96, 0x91, 0x95, 0x93, 0x57,
    0x50, 0x54, 0x52, 0x56, 0x51, 0x55, 0x53, 0xd7, 0xd0, 0xd4, 0xd2, 0xd6,
    0xd1, 0xd5, 0xd3, 0x37, 0x30, 0x34, 0x32, 0x36, 0x31, 0x35, 0x33, 0xb7,
    0xb0, 0xb4, 0xb2, 0xb6, 0xb1, 0xb5, 0xb3, 0x77, 0x70, 0x74, 0x72, 0x76,
    0x71, 0x75, 0x73, 0xf7, 0xf0, 0xf4, 0xf2, 0xf6, 0xf1, 0xf5, 0xf3, 0x0f,
    0x08, 0x0c, 0x0a, 0x0e, 0x09, 0x0d, 0x0b, 0x8f, 0x88, 0x8c, 0x8a, 0x8e,
    0x89, 0x8d, 0x8b, 0x4f, 0x48, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf,
    0xc8, 0xcc, 0xca, 0xce, 0xc9, 0xcd, 0xcb, 0x2f, 0x28, 0x2c, 0x2a, 0x2e,
    0x29, 0x2d, 0x2b, 0xaf, 0xa8, 0xac, 0xaa, 0xae, 0xa9, 0xad, 0xab, 0x6f,
    0x68, 0x6c, 0x6a, 0x6e, 0x69, 0x6d, 0x6b, 0xef, 0xe8, 0xec, 0xea, 0xee,
    0xe9, 0xed, 0xeb, 0x9f, 0x30, 0x71, 0xd2, 0xe4, 0x29, 0x53, 0xa7, 0x4d,
    0x9f, 0x31, 0x73, 0xd6, 0xec, 0x39, 0x73, 0xe7, 0xcd, 0x5f, 0xb0, 0x70,
    0xd1, 0xe2, 0x25, 0x4b, 0x97, 0x2d, 0x5f, 0xb1, 0x72, 0xd5, 0xea, 0x35,
    0x6b, 0xd7, 0xad, 0xdf, 0xb0, 0x71, 0xd3, 0xe6, 0x2d, 0x5b, 0xb7, 0x6d,
    0xdf, 0xb1, 0x73, 0xd7, 0xee, 0x3d, 0x7b, 0xf7, 0xed, 0x3f, 0x70, 0xf0,
    0xd0, 0xe1, 0x23, 0x47, 0x8f, 0x1d, 0x3f, 0x71, 0xf2, 0xd4, 0xe9, 0x33,
    0x67, 0xcf, 0x9d, 0xbf, 0x70, 0xf1, 0xd2, 0xe5, 0x2b, 0x57, 0xaf, 0x5d,
    0xbf, 0x71, 0xf3, 0xd6, 0xed, 0x3b, 0x77, 0xef, 0xdd, 0x7f, 0xf0, 0xf0,
    0xd1, 0xe3, 0x27, 0x4f, 0x9f, 0x3d, 0x7f, 0xf1, 0xf2, 0xd5, 0xeb, 0x37,
    0x6f, 0xdf, 0xbd, 0xff, 0xf0, 0xf1, 0xd3, 0xe7, 0x2f, 0x5f, 0xbf, 0x7d,
    0xff, 0xf1, 0xf3, 0x17, 0xc3, 0x60, 0xf4, 0x3a, 0x00, 0x7f, 0x00, 0x7f,
    0x00,
};

/// A list, a text object, and a map with a key set and then deleted, in three
/// changes. 240 bytes and fourteen of the sixteen op columns: the object and
/// key actor and counter columns, the predecessor group, the expand column and
/// the insert column are all here, which is what makes it the fixture for the
/// columns `reference_simple` leaves out.
const reference_rich = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x25, 0xa9, 0xea, 0x76, 0x03, 0xe5, 0x01, 0x00,
    0x01, 0x10, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33,
    0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x09, 0x01, 0x02, 0x03, 0x02, 0x13,
    0x04, 0x23, 0x04, 0x33, 0x02, 0x45, 0x02, 0x50, 0x04, 0x53, 0x03, 0x60,
    0x02, 0x03, 0x00, 0x03, 0x01, 0x7d, 0x01, 0x04, 0x0c, 0x7d, 0x04, 0x0c,
    0x03, 0x03, 0x00, 0x00, 0x03, 0x7f, 0x00, 0x02, 0x01, 0x7e, 0x00, 0x01,
    0x03, 0x00, 0x0e, 0x01, 0x04, 0x03, 0x0d, 0x11, 0x0a, 0x13, 0x0c, 0x15,
    0x17, 0x21, 0x02, 0x34, 0x03, 0x42, 0x08, 0x56, 0x0c, 0x57, 0x1b, 0x70,
    0x04, 0x71, 0x02, 0x73, 0x02, 0xb3, 0x01, 0x0e, 0x00, 0x03, 0x10, 0x00,
    0x00, 0x03, 0x7f, 0x01, 0x02, 0x00, 0x7f, 0x04, 0x0a, 0x00, 0x7e, 0x0c,
    0x00, 0x00, 0x04, 0x02, 0x00, 0x00, 0x01, 0x0a, 0x00, 0x00, 0x02, 0x00,
    0x03, 0x7b, 0x00, 0x02, 0x01, 0x7d, 0x06, 0x09, 0x01, 0x00, 0x02, 0x7d,
    0x04, 0x6c, 0x69, 0x73, 0x74, 0x03, 0x6d, 0x61, 0x70, 0x04, 0x74, 0x65,
    0x78, 0x74, 0x00, 0x0e, 0x02, 0x04, 0x6b, 0x65, 0x65, 0x70, 0x13, 0x00,
    0x03, 0x0e, 0x02, 0x7d, 0x02, 0x00, 0x04, 0x0f, 0x01, 0x7f, 0x03, 0x03,
    0x00, 0x7d, 0x14, 0x36, 0x85, 0x01, 0x0b, 0x16, 0x7e, 0x46, 0x00, 0x7f,
    0x74, 0x77, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x40, 0x68,
    0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64, 0x6b, 0x65,
    0x70, 0x74, 0x12, 0x00, 0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x12, 0x7e, 0x00,
    0x03, 0x02, 0x01, 0x7e, 0x7d, 0x04, 0x0a, 0x01, 0x7d, 0x71, 0x10, 0x01,
};

/// The actor every reference fixture uses.
const reference_actor = [_]u8{
    0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11,
    0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "a bundle the reference wrote reads field by field, at literal offsets" {
    const gpa = testing.allocator;
    // The whole chunk, section by section. Every offset below is absolute, so a
    // reordering of any section fails here rather than decoding to something
    // that merely looks right.
    //
    //   0  .. 10   the chunk header
    //   10 .. 29   the prefix: no dependencies, one actor
    //   29 .. 30   the change block's column count, 9
    //   30 .. 48   the change block's nine descriptors
    //   48 .. 67   the change block's data
    //   67 .. 68   the op block's column count, 8
    //   68 .. 85   the op block's eight descriptors
    //   85 .. 111  the op block's data
    try testing.expectEqualSlices(u8, &chunk.magic, reference_simple[0..4]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc7, 0xa4, 0x97, 0x81 }, reference_simple[4..8]);
    try testing.expectEqual(@as(u8, 0x03), reference_simple[8]);
    try testing.expectEqual(@as(u8, 101), reference_simple[9]);

    // The prefix: a dependency count of zero, an actor count of one, and the
    // actor as a uleb128 length and that many bytes.
    try testing.expectEqual(@as(u8, 0), reference_simple[10]);
    try testing.expectEqual(@as(u8, 1), reference_simple[11]);
    try testing.expectEqual(@as(u8, 0x10), reference_simple[12]);
    try testing.expectEqualSlices(u8, &reference_actor, reference_simple[13..29]);

    // The change block's descriptors, in order, as (spec, length) pairs. The
    // extra column is absent: its range is empty, so it is not a column.
    try testing.expectEqual(@as(u8, 9), reference_simple[29]);
    const change_descs = [_][2]u8{
        .{ 0x01, 0x02 }, .{ 0x03, 0x02 }, .{ 0x13, 0x02 }, .{ 0x23, 0x02 },
        .{ 0x33, 0x02 }, .{ 0x45, 0x02 }, .{ 0x50, 0x03 }, .{ 0x53, 0x02 },
        .{ 0x60, 0x02 },
    };
    for (change_descs, 0..) |pair, i| {
        const at = 30 + i * 2;
        try testing.expectEqual(pair[0], reference_simple[at]);
        try testing.expectEqual(pair[1], reference_simple[at + 1]);
    }
    // The change data: two changes, actor 0, seq 1 then 1, start_op 1 then 1,
    // max_op 1 then 1, no timestamps, no messages, dep counts 0 then 1, one
    // dependency index of 0, and two empty extra runs.
    const change_data = reference_simple[48..67];
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00 }, change_data[0..2]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x01 }, change_data[2..4]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x01 }, change_data[4..6]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x01 }, change_data[6..8]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00 }, change_data[8..10]);
    // `00 02` is a null run of two, not a repeat run: the run header is signed.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02 }, change_data[10..12]);
    // `7e 00 01` is a literal run of two group counts, 0 and 1.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x00, 0x01 }, change_data[12..15]);
    // `7f 00` is a literal run of one dependency index, 0: the first change in
    // the bundle.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x00 }, change_data[15..17]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00 }, change_data[17..19]);

    // The op block's eight descriptors. The last one, `0xb3`, is column 11 with
    // the delta encoding, and 179 does not fit in one LEB128 byte, so its
    // specification is two bytes: `b3 01`. That is why the descriptors run to
    // offset 85 and not 84.
    try testing.expectEqual(@as(u8, 8), reference_simple[67]);
    const op_descs = [_][2]u8{
        .{ 0x15, 0x09 }, .{ 0x21, 0x02 }, .{ 0x34, 0x01 }, .{ 0x42, 0x02 },
        .{ 0x56, 0x03 }, .{ 0x57, 0x04 }, .{ 0x70, 0x02 },
    };
    for (op_descs, 0..) |pair, i| {
        const at = 68 + i * 2;
        try testing.expectEqual(pair[0], reference_simple[at]);
        try testing.expectEqual(pair[1], reference_simple[at + 1]);
    }
    try testing.expectEqualSlices(u8, &[_]u8{ 0xb3, 0x01, 0x03 }, reference_simple[82..85]);

    // The op data: the two key strings, two actor zeros, two false inserts, two
    // `set` actions, the two value metadata words, the two payloads, no
    // predecessors, and the inverse permutation `[0, 1]`.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x03 }, reference_simple[85..87]);
    try testing.expectEqualSlices(u8, "aaa", reference_simple[87..90]);
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, reference_simple[90..91]);
    try testing.expectEqualSlices(u8, "bbb", reference_simple[91..94]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00 }, reference_simple[94..96]);
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, reference_simple[96..97]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x01 }, reference_simple[97..99]);
    // 0x36 is `(3 << 4) | 6`: three bytes of string. 0x14 is `(1 << 4) | 4`:
    // one byte of signed integer.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x36, 0x14 }, reference_simple[99..102]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x61, 0x61, 0x61, 0x2a }, reference_simple[102..106]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00 }, reference_simple[106..108]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7e, 0x00, 0x01 }, reference_simple[108..111]);

    // And now the same bytes through the reader.
    var b = try parse(gpa, &reference_simple);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 10), b.header_len);
    try testing.expectEqualSlices(u8, &reference_simple, b.bytes());
    try testing.expect(b.checksumValid());
    try testing.expectEqual(@as(usize, 0), b.depsList().len);
    try testing.expectEqual(@as(usize, 1), b.actorList().len);
    try testing.expectEqualSlices(u8, &reference_actor, b.actorList()[0].bytes);
    try testing.expectEqual(@as(usize, 9), b.changes_cols.len());
    try testing.expectEqual(@as(usize, 8), b.ops_cols.len());
    // Both data blocks are the ranges the offsets above pin.
    try testing.expectEqual(ColumnRange.init(48, 67), b.changes_data);
    try testing.expectEqual(ColumnRange.init(85, 111), b.ops_data);
    // Nothing was deflated, so the bundle borrowed the input and the on-disk
    // form is that same input.
    try testing.expect(b.disk == null);

    // The counters the inverse permutation reconstructs: the first change's op
    // is counter 1 and the second change's is counter 2, in document order.
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, b.id_ctr);

    var changes = try ChangeIter.init(b.changes_cols, gpa);
    defer changes.deinit();
    const first = (try changes.next()).?;
    try testing.expectEqual(@as(ActorIdx, 0), first.actor);
    try testing.expect(first.author == null);
    try testing.expectEqual(@as(u64, 1), first.seq);
    try testing.expectEqual(@as(u64, 1), first.start_op);
    try testing.expectEqual(@as(u64, 1), first.max_op);
    try testing.expectEqual(@as(i64, 0), first.timestamp);
    try testing.expect(first.message == null);
    try testing.expectEqual(@as(usize, 0), first.deps.len);
    try testing.expectEqual(@as(usize, 0), first.extra.len);

    const second = (try changes.next()).?;
    try testing.expectEqual(@as(u64, 2), second.seq);
    try testing.expectEqual(@as(u64, 2), second.start_op);
    try testing.expectEqual(@as(u64, 2), second.max_op);
    try testing.expectEqualSlices(u64, &[_]u64{0}, second.deps);
    try testing.expect((try changes.next()) == null);

    var ops = try OpIter.init(b.ops_cols, b.id_ctr, gpa);
    defer ops.deinit();
    const op0 = (try ops.next()).?;
    try testing.expectEqual(OpId.init(1, 0), op0.id);
    try testing.expect(op0.obj.eql(.root));
    try testing.expect(op0.key.eql(.{ .map = "aaa" }));
    try testing.expectEqual(Action.set, op0.action);
    try testing.expectEqualStrings("aaa", op0.value.str);
    try testing.expect(!op0.insert);
    try testing.expect(!op0.expand);
    try testing.expect(op0.mark_name == null);
    try testing.expectEqual(@as(usize, 0), op0.pred.len);

    const op1 = (try ops.next()).?;
    try testing.expectEqual(OpId.init(2, 0), op1.id);
    try testing.expect(op1.key.eql(.{ .map = "bbb" }));
    try testing.expectEqual(Action.set, op1.action);
    try testing.expectEqual(@as(i64, 42), op1.value.int);
    try testing.expect((try ops.next()) == null);
}

test "a deflated value column is inflated, read, and still reports the disk form" {
    const gpa = testing.allocator;
    var b = try parse(gpa, &reference_big);
    defer b.deinit(gpa);

    // A column was deflated, so the bundle holds a rebuilt uncompressed copy
    // and the input becomes the on-disk form.
    try testing.expect(b.disk != null);
    try testing.expectEqualSlices(u8, &reference_big, b.bytes());
    try testing.expect(b.checksumValid());
    // The rebuilt body is longer than the input, because 400 bytes of payload
    // came back from a 270-byte stream.
    try testing.expect(b.body.len > reference_big.len);
    // The rebuild took the DEFLATE bit off the value column's specification,
    // so the columns the bundle iterates over are all plain bytes.
    try testing.expect(b.changes_cols.allUncompressed());
    try testing.expect(b.ops_cols.allUncompressed());

    try testing.expectEqual(@as(usize, 1), b.actorList().len);
    try testing.expectEqual(@as(usize, 0), b.depsList().len);

    var changes = try ChangeIter.init(b.changes_cols, gpa);
    defer changes.deinit();
    const row = (try changes.next()).?;
    try testing.expectEqual(@as(u64, 1), row.seq);
    try testing.expectEqual(@as(u64, 1), row.start_op);
    try testing.expectEqual(@as(u64, 1), row.max_op);
    try testing.expect((try changes.next()) == null);

    var ops = try OpIter.init(b.ops_cols, b.id_ctr, gpa);
    defer ops.deinit();
    const op = (try ops.next()).?;
    try testing.expectEqual(OpId.init(1, 0), op.id);
    try testing.expect(op.key.eql(.{ .map = "padding" }));
    try testing.expectEqual(@as(usize, 400), op.value.bytes.len);
    for (op.value.bytes, 0..) |byte, i| {
        try testing.expectEqual(@as(u8, @intCast(i % 251)), byte);
    }
    try testing.expect((try ops.next()) == null);
}

test "a bundle with every op column reads its objects, keys and predecessors" {
    const gpa = testing.allocator;
    var b = try parse(gpa, &reference_rich);
    defer b.deinit(gpa);

    var changes = try ChangeIter.init(b.changes_cols, gpa);
    defer changes.deinit();
    const rows = [_]struct { seq: u64, start: u64, max: u64, deps: []const u64 }{
        .{ .seq = 1, .start = 1, .max = 4, .deps = &.{} },
        .{ .seq = 2, .start = 5, .max = 16, .deps = &.{0} },
        .{ .seq = 3, .start = 17, .max = 19, .deps = &.{1} },
    };
    for (rows) |want| {
        const got = (try changes.next()).?;
        try testing.expectEqual(want.seq, got.seq);
        try testing.expectEqual(want.start, got.start_op);
        try testing.expectEqual(want.max, got.max_op);
        try testing.expectEqualSlices(u64, want.deps, got.deps);
    }
    try testing.expect((try changes.next()) == null);

    // Nineteen ops, counters 1 through 19 in document order: one change's ops
    // are contiguous counters, and the changes are in `(actor, seq)` order.
    // Nineteen ops, and the counters in the order the op set walked them. The
    // bundle format does not define that order — the writer emits rows in the
    // order it is fed them — so this is a property of this fixture, pinned so a
    // change to the inverse permutation shows up here rather than as a change
    // in which op each counter belongs to.
    try testing.expectEqualSlices(i64, &[_]i64{
        1,  17, 5,  2,  3,  4,  6,  7,  8, 9, 10,
        11, 12, 13, 14, 15, 16, 18, 19,
    }, b.id_ctr);

    var ops = try OpIter.init(b.ops_cols, b.id_ctr, gpa);
    defer ops.deinit();
    var count: usize = 0;
    var saw_sequence_key = false;
    var saw_pred = false;
    while (try ops.next()) |op| {
        // The op at document position `count` is the one whose counter the
        // reconstruction placed there.
        try testing.expectEqual(OpId.init(@intCast(b.id_ctr[count]), op.id.actor), op.id);
        if (op.key == .seq) saw_sequence_key = true;
        if (op.pred.len != 0) saw_pred = true;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 19), count);
    // The key actor and counter columns are present, so at least one op is
    // keyed by an element rather than by a property.
    try testing.expect(saw_sequence_key);
    // So is the predecessor group, because the deleted key and the second
    // insert both overwrite something.
    try testing.expect(saw_pred);
}

test "every column of a reference bundle re-encodes to the bytes it was read from" {
    const gpa = testing.allocator;
    // The bundle's columns are hexane, the same byte format `columnar` uses, so
    // a decode followed by an encode must be the identity. This pins the codec
    // against bytes the reference wrote rather than against bytes this port
    // wrote, and it is the check that catches a column read with the wrong
    // encoding tag.
    for ([_][]const u8{ &reference_simple, &reference_rich }) |fixture| {
        var b = try parse(gpa, fixture);
        defer b.deinit(gpa);
        try expectColumnsRoundTrip(gpa, b.changes_cols, &all_change_specs, true);
        try expectColumnsRoundTrip(gpa, b.ops_cols, &all_op_specs, false);
    }
}

/// Every change column specification, so a block column the port does not name
/// is caught rather than skipped.
const all_change_specs = [_]ColumnSpec{
    change_specs.actor,     change_specs.seq,       change_specs.start_op,
    change_specs.max_op,    change_specs.timestamp, change_specs.message,
    change_specs.dep_count, change_specs.deps,      change_specs.extra_count,
    change_specs.extra,
};

/// Every op column specification.
const all_op_specs = [_]ColumnSpec{
    op_specs.obj_actor,      op_specs.obj_ctr,    op_specs.key_actor,
    op_specs.key_ctr,        op_specs.key_str,    op_specs.id_actor,
    op_specs.insert,         op_specs.action,     op_specs.value_meta,
    op_specs.value,          op_specs.pred_count, op_specs.pred_actor,
    op_specs.pred_ctr,       op_specs.expand,     op_specs.mark_name,
    op_specs.id_ctr_inverse,
};

fn isKnown(known: []const ColumnSpec, spec: ColumnSpec) bool {
    for (known) |candidate| {
        if (candidate.eql(spec)) return true;
    }
    return false;
}

/// Decodes every column of `cols`, re-encodes it, and compares the bytes. A
/// column not named by `known` is the port's own, and the value column pair is
/// left to its metadata half, because that is the half a decoder reads.
fn expectColumnsRoundTrip(
    gpa: Allocator,
    cols: RawColumns,
    known: []const ColumnSpec,
    is_change_block: bool,
) !void {
    for (cols.columns) |*col| {
        try testing.expect(isKnown(known, col.spec));
        if (is_change_block and col.spec.eql(change_specs.extra)) {
            // The extra column has no metadata sibling: it is a raw byte
            // stream, and re-encoding it is copying it.
            continue;
        }
        if (!is_change_block and (col.spec.eql(op_specs.value_meta) or
            col.spec.eql(op_specs.value))) continue;
        const cells = try encoding.decodeAll(gpa, col.spec, try col.bytes(cols.data));
        defer gpa.free(cells);
        const encoded = try encoding.encodeColumn(gpa, col.spec.id(), col.spec.encoding(), cells);
        defer encoded.deinit(gpa);
        try testing.expectEqualSlices(u8, try col.bytes(cols.data), encoded.bytes);
    }
}

test "a written bundle is byte for byte the bundle the reference wrote" {
    const gpa = testing.allocator;
    // The document `reference_simple` is: one actor, two changes, two `set`
    // operations on the root map, and no successors. A bundle stores no change
    // hash — only dependency *indices* — so the change hashes below never reach
    // the wire and the whole bundle is determined by what this test feeds in.
    // Which means the bytes must come out identical to the bytes automerge
    // produced for the same document, and that is the strongest statement this
    // slice can make about the writer: the section order, the column order, the
    // elision of the columns the reference elided, and every column codec all
    // agree with the reference.
    const h0 = ChangeHash.fromChecksum(.{ 0x11, 0x22, 0x33, 0x44 });
    const h1 = ChangeHash.fromChecksum(.{ 0x55, 0x66, 0x77, 0x88 });
    var changes = [_]BundleMetadata{
        .{
            .hash = h0,
            .actor = 0,
            .seq = 1,
            .max_op = 1,
            .timestamp = 0,
            .message = null,
            .deps = &.{},
            .extra = "",
            .start_op = 1,
            .builder = 0,
        },
        .{
            .hash = h1,
            .actor = 0,
            .seq = 2,
            .max_op = 2,
            .timestamp = 0,
            .message = null,
            .deps = &.{h0},
            .extra = "",
            .start_op = 2,
            .builder = 1,
        },
    };
    const actors = [_]ActorId{.{ .bytes = &reference_actor }};

    var builder = try Builder.init(gpa, &changes, &actors);
    defer builder.deinit(gpa);
    try builder.processOp(.{
        .id = OpId.init(1, 0),
        .obj = .root,
        .key = .{ .map = "aaa" },
        .action = .set,
        .value = .{ .str = "aaa" },
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    });
    try builder.processOp(.{
        .id = OpId.init(2, 0),
        .obj = .root,
        .key = .{ .map = "bbb" },
        .action = .set,
        .value = .{ .int = 42 },
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    });
    var written = try builder.finish(gpa);
    defer written.deinit(gpa);

    try testing.expectEqualSlices(u8, &reference_simple, written.bytes());
    try testing.expect(written.checksumValid());
    // Nothing was big enough to deflate, so the two renderings are the same
    // bytes and the in-memory form is the on-disk one.
    try testing.expectEqualSlices(u8, written.body, written.bytes());
    try testing.expectEqual(@as(usize, 1), written.actorList().len);
    try testing.expectEqualSlices(u8, &reference_actor, written.actorList()[0].bytes);
    try testing.expectEqual(@as(usize, 0), written.depsList().len);
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2 }, written.id_ctr);
}

test "a bundle deflates the columns that are big enough and still reads back" {
    const gpa = testing.allocator;
    const h0 = ChangeHash.fromChecksum(.{ 0x11, 0x22, 0x33, 0x44 });
    var changes = [_]BundleMetadata{.{
        .hash = h0,
        .actor = 0,
        .seq = 1,
        .max_op = 1,
        .timestamp = 0,
        .message = null,
        .deps = &.{},
        .extra = "",
        .start_op = 1,
        .builder = 0,
    }};
    const actors = [_]ActorId{.{ .bytes = &reference_actor }};
    var builder = try Builder.init(gpa, &changes, &actors);
    defer builder.deinit(gpa);
    var payload: [400]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try builder.processOp(.{
        .id = OpId.init(1, 0),
        .obj = .root,
        .key = .{ .map = "padding" },
        .action = .set,
        .value = .{ .bytes = &payload },
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    });
    var written = try builder.finish(gpa);
    defer written.deinit(gpa);

    // The 400-byte value column is above the threshold, so the on-disk form
    // carries it as a DEFLATE stream and is shorter than the in-memory one.
    try testing.expect(written.bytes().len < written.body.len);
    const on_disk = try gpa.dupe(u8, written.bytes());
    defer gpa.free(on_disk);

    var back = try parse(gpa, on_disk);
    defer back.deinit(gpa);
    try testing.expect(back.checksumValid());
    var ops = try OpIter.init(back.ops_cols, back.id_ctr, gpa);
    defer ops.deinit();
    const op = (try ops.next()).?;
    try testing.expectEqual(@as(usize, 400), op.value.bytes.len);
    try testing.expectEqualSlices(u8, &payload, op.value.bytes);
    try testing.expect((try ops.next()) == null);
}

test "malformed bundles are rejected, one class at a time" {
    const gpa = testing.allocator;
    // The whole chunk the reference wrote, re-framed around an edited body, so
    // every case below is a single edit plus a recomputed checksum and nothing
    // else. Body offsets are the fixture's own, and are the same ones the first
    // test pins: the change block's count at 19, its first descriptor at 20 and
    // 21, its dependency group column at 60..63, the op block's count at 57, and
    // its value column descriptor at 78 and 79.
    const Reframe = struct {
        fn build(alloc: Allocator, body: []const u8) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            try chunk.writeChunk(&out, alloc, .bundle, body);
            return out.toOwnedSlice(alloc);
        }
    };
    const Case = struct { name: []const u8, body: []const u8, want: ParseError };
    const cases = [_]Case{
        .{
            .name = "a column the change block does not define, or one out of order",
            // The actor column becomes column 60, which no change column uses.
            // Upstream's `InvalidChangeColumn` and `NotInNormalOrder` are both
            // `error.InvalidColumnSpec` here, because the error set carries no
            // payload and one variant covers both.
            .body = &[_]u8{ 0x00, 0x01, 0x10 } ++ &@as([16]u8, @splat(0xaa)) ++
                &[_]u8{ 0x09, 0x3c, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02, 0x33, 0x02, 0x45, 0x02, 0x50, 0x03, 0x53, 0x02, 0x60, 0x02 } ++
                &@as([19]u8, @splat(0x00)),
            .want = error.InvalidColumnSpec,
        },
        .{
            .name = "a column count the body could not hold",
            .body = &[_]u8{ 0x00, 0x01, 0x10 } ++ &@as([16]u8, @splat(0xaa)) ++
                &[_]u8{ 0x7f, 0x01, 0x02 },
            .want = error.LengthExceedsInput,
        },
        .{
            .name = "a column length that runs past its data block",
            .body = &[_]u8{ 0x00, 0x01, 0x10 } ++ &@as([16]u8, @splat(0xaa)) ++
                &[_]u8{ 0x09, 0x01, 0x40 },
            .want = error.LengthExceedsInput,
        },
    };
    for (cases) |c| {
        const chunk_bytes = try Reframe.build(gpa, c.body);
        defer gpa.free(chunk_bytes);
        try testing.expectError(c.want, parse(gpa, chunk_bytes));
    }

    // The framing classes, on the reference's own bytes with no re-framing.
    var bad_magic = try gpa.dupe(u8, &reference_simple);
    defer gpa.free(bad_magic);
    bad_magic[2] ^= 0xff;
    try testing.expectError(error.InvalidMagic, parse(gpa, bad_magic));

    var bad_sum = try gpa.dupe(u8, &reference_simple);
    defer gpa.free(bad_sum);
    bad_sum[110] ^= 0x01;
    try testing.expectError(error.InvalidChecksum, parse(gpa, bad_sum));

    // A type byte that is not one of the four is refused before the checksum is
    // even looked at, because the type is read first (`chunk.rs:249-255`).
    for ([_]u8{ 4, 0xff }) |typ| {
        var bad_type = try gpa.dupe(u8, &reference_simple);
        defer gpa.free(bad_type);
        bad_type[8] = typ;
        try testing.expectError(error.InvalidChunkType, parse(gpa, bad_type));
    }
    // A correctly framed chunk of another type is `error.InvalidChunkType`: the
    // reader dispatches on the type, the way `change_chunk.parseFramedChunk` does
    // for the types it cannot read.
    for ([_]chunk.ChunkType{ .change, .document, .compressed }) |typ| {
        var other: std.ArrayList(u8) = .empty;
        defer other.deinit(gpa);
        try chunk.writeChunk(&other, gpa, typ, reference_simple[10..]);
        try testing.expectError(error.InvalidChunkType, parse(gpa, other.items));
    }

    // A frame whose declared length runs past the buffer: the body is cut off,
    // so the length is what is wrong. One that stops inside its own header never
    // reaches a length at all.
    try testing.expectError(error.LengthExceedsInput, parse(gpa, reference_simple[0..60]));
    try testing.expectError(error.UnexpectedEnd, parse(gpa, reference_simple[0..7]));
    try testing.expectError(error.UnexpectedEnd, parse(gpa, ""));
    // A frame that stops inside the chunk's own LEB128 length.
    try testing.expectError(error.UnexpectedEnd, parse(gpa, reference_simple[0..9]));

    // A declared length past the end of the buffer, refused by the framing
    // before any body parser sees it.
    var long_len = try gpa.dupe(u8, &reference_simple);
    defer gpa.free(long_len);
    long_len[9] = 0x7f;
    try testing.expectError(error.LengthExceedsInput, parse(gpa, long_len));

    // A byte after a complete chunk.
    var trailing = try gpa.alloc(u8, reference_simple.len + 1);
    defer gpa.free(trailing);
    @memcpy(trailing[0..reference_simple.len], &reference_simple);
    trailing[reference_simple.len] = 0;
    try testing.expectError(error.TrailingBytes, parse(gpa, trailing));

    // An `ID_CTR_INVERSE` document position past the op count, which is
    // upstream's `InverseDecode`.
    {
        var edited = try gpa.dupe(u8, reference_simple[10..]);
        defer gpa.free(edited);
        edited[99] = 0x7f;
        const out = try Reframe.build(gpa, edited);
        defer gpa.free(out);
        try testing.expectError(error.InvalidValue, parse(gpa, out));
    }
}

/// Builds a mapping over `actors` twice and then releases the mapper, for the
/// sweep below.
///
/// Twice, because the second call is the one that can leave the field dangling.
/// `ActorMapper.init` hands out an empty `used`, and freeing an empty slice does
/// nothing at all (`std/mem/Allocator.zig:447`), so a first call that failed
/// would show nothing however wrong it was. Once a mapping exists `used` is a
/// real allocation, and the next call has to swap it for another without ever
/// leaving it freed. That state is reachable because `buildMapping` is `pub`
/// and takes the mapper by pointer, so a caller may map, map again and then
/// read the result; [`Builder.finish`], which used to be a second route to it,
/// is one-shot now.
///
/// The sweep fails remaps as well as allocations, because
/// `ArrayList.toOwnedSlice` only allocates when the in-place shrink is refused
/// (`std/array_list.zig:654-665`): with the remap left working, the step that
/// replaces `self.used` is never reached, and the release before it is the half
/// of the pair that has to be proved.
fn buildMappingTwiceThenDeinit(gpa: Allocator, actors: []const ActorId) !void {
    var mapper = try ActorMapper.init(gpa, actors);
    defer mapper.deinit(gpa);
    try mapper.processActor(0);
    try mapper.buildMapping(null);
    try mapper.buildMapping(null);
    // A mapper that came back owns exactly one array for `used`, and it is the
    // one `deinit` is about to free. The mapping it indexes is the same either
    // time round, because the walk over `seen` is unchanged.
    try testing.expectEqual(@as(usize, 1), mapper.used.len);
    try testing.expectEqual(@as(ActorIdx, 0), try mapper.remap(0));
}

test "a mapping survives every allocation failure" {
    const gpa = testing.allocator;
    // Two actors, one of them used: the list reserves room for two and has to
    // shrink to one, which is the step `toOwnedSlice` can only pay for by
    // allocating. One actor used out of one is already exact and would never
    // take the path at all.
    const other = [_]u8{
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
    };
    const actors = [_]ActorId{ .{ .bytes = &reference_actor }, .{ .bytes = &other } };
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{ .resize_fail_index = 0 });
        try buildMappingTwiceThenDeinit(failing.allocator(), &actors);
        break :blk failing.alloc_index;
    };
    try testing.expect(needed > 0);
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        if (buildMappingTwiceThenDeinit(failing.allocator(), &actors)) |_| {
            // The failure was induced and the call still came back, so
            // `buildMapping` swallowed its own out-of-memory.
            return error.SwallowedOutOfMemoryError;
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
        // Every path out of the call releases the mapper, so the bytes handed
        // out and the bytes taken back agree however far it got.
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

/// Parses each of the reference bundles and releases it, for the sweep below.
///
/// Every field a parsed bundle owns is acquired by a fallible step, and the
/// three fixtures take three different shapes: nothing deflated, a value
/// column deflated, and every op column present. So failing any single
/// allocation of the parse exercises the whole unwind — including the five
/// fields a `Bundle` owns before it has parsed anything, which are the ones a
/// `try` inside its struct literal could not have given back.
fn parseThenDeinit(gpa: Allocator, fixtures: []const []const u8) !void {
    for (fixtures) |bytes| {
        var b = try parse(gpa, bytes);
        defer b.deinit(gpa);
        try testing.expect(b.checksumValid());
    }
}

test "a bundle survives every allocation failure" {
    const gpa = testing.allocator;
    const fixtures = [_][]const u8{
        &reference_simple,
        &reference_big,
        &reference_rich,
    };
    try testing.checkAllAllocationFailures(gpa, parseThenDeinit, .{&fixtures});
}

test "a deflated bundle reconstructs its counters from the inflated columns" {
    const gpa = testing.allocator;
    // The DEFLATE pass is not limited to the value payload: `deflateBlock`
    // deflates every column of at least `deflate_min_size` bytes
    // (`raw_column.rs:62-75`). What decides a column's size is the number of
    // *runs* its codec emits rather than the number of rows it holds, and the
    // four change-block columns the counter reconstruction reads are three
    // delta streams and an actor column. One actor writing one op per change
    // makes every one of those deltas `+1`, so the three are a single repeat
    // run of a few bytes however many rows there are, and the actor column a
    // single repeat run too. Three hundred changes of that shape — the fixture
    // this one replaces — puts none of them near the threshold, so the bundle
    // comes out with nothing deflated at all: a bundle the reader never routes
    // through the inflate pass, which is the whole thing this test is about.
    //
    // Two interleaved actors are what make them grow. Every third op below
    // belongs to the second actor, and every op is its own change, so change
    // `j` is the `c`th op of its actor and `seq`, `start_op` and `max_op` are
    // all that one counter. The three counter columns then carry `+1, -(t+1),
    // t+2` per group of three rows — no two consecutive deltas equal, so one
    // literal run rather than a run of repeats — and the actor column becomes
    // four hundred alternating runs. The op block's `ID_CTR_INVERSE` is actor
    // 0's four hundred document positions at gaps of one and two, again with
    // no equal neighbours, then actor 1's two hundred at a constant three.
    // All five columns are well past 256 bytes, so all five reach the wire as
    // DEFLATE streams.
    //
    // That is what makes the counters worth reconstructing from the inflated
    // bytes: `extractIdCtr` decodes `ID_CTR_INVERSE` as a delta stream and
    // walks the change metadata with `ChangeIter`, and `ColumnSpec.encoding`
    // masks bit 3 alone (`column_spec.zig:147`, `:202-204`), so a
    // DEFLATE-marked column matches just the same and `col.bytes(...)` hands
    // the raw stream to the decoder. Upstream computes the counters after the
    // pass (`bundle/storage.rs:242-255`), and this is what pins that.
    const count = 600;
    const second_actor = [_]u8{
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
    };
    const actors = [_]ActorId{ .{ .bytes = &reference_actor }, .{ .bytes = &second_actor } };
    // Each op's counter in document order: what the writer's own `id_ctr`
    // holds, what the reader reconstructs, and what the change row for that
    // op carries as its sequence number.
    var counters: [count]u64 = undefined;
    var next: [2]u64 = .{ 1, 1 };
    var metas: [count]BundleMetadata = undefined;
    for (&metas, 0..) |*m, i| {
        const slot: usize = if (i % 3 == 2) 1 else 0;
        const ctr = next[slot];
        next[slot] = ctr + 1;
        counters[i] = ctr;
        const n: u64 = i + 1;
        const low: u16 = @intCast(n);
        m.* = .{
            .hash = ChangeHash.fromChecksum(.{ @truncate(low), @truncate(low >> 8), 0x33, 0x44 }),
            .actor = @intCast(slot),
            .seq = ctr,
            .max_op = ctr,
            .timestamp = 0,
            .message = null,
            .deps = &.{},
            .extra = "",
            .start_op = ctr,
            .builder = i,
        };
    }
    var builder = try Builder.init(gpa, &metas, &actors);
    defer builder.deinit(gpa);
    for (counters, 0..) |ctr, i| {
        try builder.processOp(.{
            .id = OpId.init(@intCast(ctr), @as(ActorIdx, if (i % 3 == 2) 1 else 0)),
            .obj = .root,
            .key = .{ .map = "k" },
            .action = .set,
            .value = .null_value,
            .insert = false,
            .expand = false,
            .mark_name = null,
            .pred = &.{},
        });
    }
    var written = try builder.finish(gpa);
    defer written.deinit(gpa);

    const on_disk = try gpa.dupe(u8, written.bytes());
    defer gpa.free(on_disk);
    var back = try parse(gpa, on_disk);
    defer back.deinit(gpa);
    try testing.expect(back.checksumValid());

    // The two renderings are the same bundle written twice, and the DEFLATE
    // bit is part of a descriptor, so a column that was deflated cannot leave
    // them equal. Comparing the bytes says the writer's pass ran without
    // pinning by how much it saved, which is nothing the format promises: a
    // column over the threshold may still come back longer than it went in.
    try testing.expect(!std.mem.eql(u8, written.bytes(), written.body));
    // And the reader took the copy-and-inflate path to match, which is the
    // property the counters depend on: `disk` is set only when some column
    // carried the DEFLATE bit, and the columns are then read out of the
    // rebuilt chunk `body` points at rather than the caller's own bytes.
    try testing.expect(back.disk != null);

    // Every change row and every op row survives, and the counters are the
    // ones the writer computed.
    var changes = try ChangeIter.init(back.changes_cols, gpa);
    defer changes.deinit();
    var seen: usize = 0;
    while (try changes.next()) |_| seen += 1;
    try testing.expectEqual(count, seen);

    var ops = try OpIter.init(back.ops_cols, back.id_ctr, gpa);
    defer ops.deinit();
    seen = 0;
    while (try ops.next()) |_| seen += 1;
    try testing.expectEqual(count, seen);
    try testing.expectEqualSlices(i64, written.id_ctr, back.id_ctr);

    // And the change rows carry the metadata the writer gave them, which is
    // the half that comes out of the inflated columns. The bundle actor index
    // is the document one: both actors are used, so the mapper hands them out
    // in document order (`bundle/builder.rs:148`).
    var rows = try ChangeIter.init(back.changes_cols, gpa);
    defer rows.deinit();
    var row_index: usize = 0;
    while (try rows.next()) |row| : (row_index += 1) {
        try testing.expectEqual(@as(ActorIdx, if (row_index % 3 == 2) 1 else 0), row.actor);
        try testing.expectEqual(counters[row_index], row.seq);
        try testing.expectEqual(counters[row_index], row.start_op);
        try testing.expectEqual(counters[row_index], row.max_op);
    }
    try testing.expectEqual(@as(usize, count), row_index);
}

test "a builder finishes once, and a second finish is refused" {
    const gpa = testing.allocator;
    // `remapActorCells` rewrites the op writer's four actor cell arrays in
    // place, through `mapper.remap` (`bundle/builder.rs:21-44`), and the change
    // writer does the same to its actor column. Those cells hold *bundle*
    // indices once `finish` has run, so feeding them through `remap` again
    // reads them as document indices and yields a bundle whose every actor
    // index is wrong — silently, because nothing downstream can tell. The flag
    // makes it `error.Invariant` instead.
    var metas = [_]BundleMetadata{.{
        .hash = ChangeHash.fromChecksum(.{ 0x11, 0x22, 0x33, 0x44 }),
        .actor = 0,
        .seq = 1,
        .max_op = 1,
        .timestamp = 0,
        .message = null,
        .deps = &.{},
        .extra = "",
        .start_op = 1,
        .builder = 0,
    }};
    const actors = [_]ActorId{.{ .bytes = &reference_actor }};
    var builder = try Builder.init(gpa, &metas, &actors);
    defer builder.deinit(gpa);
    try builder.processOp(.{
        .id = OpId.init(1, 0),
        .obj = .root,
        .key = .{ .map = "k" },
        .action = .set,
        .value = .null_value,
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    });
    var written = try builder.finish(gpa);
    defer written.deinit(gpa);

    try testing.expectError(error.Invariant, builder.finish(gpa));

    // The first bundle is untouched by the refusal, and a builder that has
    // never been finished still finishes — the flag is per builder, not a
    // global.
    try testing.expect(written.checksumValid());
    var fresh = try Builder.init(gpa, &metas, &actors);
    defer fresh.deinit(gpa);
    try fresh.processOp(.{
        .id = OpId.init(1, 0),
        .obj = .root,
        .key = .{ .map = "k" },
        .action = .set,
        .value = .null_value,
        .insert = false,
        .expand = false,
        .mark_name = null,
        .pred = &.{},
    });
    var second = try fresh.finish(gpa);
    defer second.deinit(gpa);
    try testing.expectEqualSlices(u8, written.bytes(), second.bytes());
}
