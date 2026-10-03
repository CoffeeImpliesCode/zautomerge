//! Identity, object, and value types.
//!
//! These are the types every other module speaks in. Two facts drive the whole
//! design:
//!
//! * An actor is stored in a per-document table and referenced everywhere by
//!   its `u32` index into that table, never by its bytes. The index is the
//!   actor column of the op set, and the change encoder, so it is not an
//!   implementation detail.
//! * `OpId` orders by counter first, then actor. `OpId` order is the document's
//!   total order over operations and is relied on by the op set, the iterators,
//!   and the change encoder. Do not change it.

const std = @import("std");
const err = @import("error.zig");

/// The document API error set, re-exported so a reader of the identity types
/// finds both sets in one place. [`error.zig`](error.zig) owns the contract.
pub const Error = err.Error;
/// Everything reachable from parsing untrusted bytes, re-exported for the
/// same reason as [`Error`](types.zig).
pub const ParseError = err.ParseError;

/// An index into a document's sorted actor table.
pub const ActorIdx = u32;

/// The number of bytes in a change hash.
pub const hash_size = 32;

/// The number of bytes in the per-chunk checksum.
pub const checksum_size = 4;

/// A change hash: SHA-256 over an encoded change.
pub const ChangeHash = struct {
    /// The 32 hash bytes.
    bytes: [hash_size]u8,

    /// The hash no change has. A change never compares equal to it.
    pub const zero: ChangeHash = .{ .bytes = @splat(0) };

    /// Whether the two are the same hash.
    pub fn eql(a: ChangeHash, b: ChangeHash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Total order, by the underlying bytes. This is the order the change
    /// graph and the sync `have` set depend on.
    pub fn order(a: ChangeHash, b: ChangeHash) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// The first four bytes, stored in every chunk header.
    pub fn checksum(self: ChangeHash) [checksum_size]u8 {
        return .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] };
    }

    /// The hash a stored chunk checksum expands to: the four bytes it carries
    /// and zeros everywhere else. A chunk header stores only the prefix.
    pub fn fromChecksum(sum: [checksum_size]u8) ChangeHash {
        var h: ChangeHash = .zero;
        @memcpy(h.bytes[0..checksum_size], &sum);
        return h;
    }

    /// The number of leading zero bytes. Automerge's fragment encoding uses
    /// this to compress sparse hash sets.
    pub fn fragmentLevel(self: ChangeHash) usize {
        var n: usize = 0;
        for (self.bytes) |b| {
            if (b != 0) break;
            n += 1;
        }
        return n;
    }

    /// Whether `a` sorts before `b`; [`order`](ChangeHash.order) is the
    /// comparison.
    pub fn lessThan(_: void, a: ChangeHash, b: ChangeHash) bool {
        return a.order(b) == .lt;
    }

    /// The hash `text` spells, or `error.InvalidHex` for a string that is not
    /// hex and `error.InvalidChangeHashBytes` for one whose length is not
    /// [`hash_size`](types.zig). The result owns nothing the caller has to
    /// free.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) !ChangeHash {
        const decoded = try err.hexFrom(gpa, text);
        defer gpa.free(decoded);
        if (decoded.len != hash_size) return error.InvalidChangeHashBytes;
        return .{ .bytes = decoded[0..hash_size].* };
    }
};

/// An actor: a byte string, unique within a document, ordered lexicographically.
///
/// **The bytes are borrowed, and this one type carries three ways to get
/// them.** Which applies is decided by the call that produced the `ActorId`,
/// not by the value, so a caller has to remember which one it holds:
///
/// | made by | `bytes` points at | released by |
/// | --- | --- | --- |
/// | [`init`](ActorId.init) | the caller's own buffer | the caller, whenever it likes |
/// | a document ([`Document`](doc.zig)) | that document's actor table | that document's `deinit` |
/// | [`initCopy`](ActorId.initCopy), [`random`](ActorId.random), [`fromHex`](ActorId.fromHex), [`withConcurrency`](ActorId.withConcurrency) | a fresh allocation from the allocator that call was given | the caller, with `gpa.free(id.bytes)` |
///
/// A borrow and an owned copy are the same type and the type system cannot
/// tell them apart, so freeing an `ActorId.bytes` that was borrowed is a
/// caller error with no diagnostic. That table is the rule.
pub const ActorId = struct {
    /// The actor's bytes, borrowed as the table above describes.
    bytes: []const u8,

    /// An actor over `bytes`, which the caller keeps alive. Nothing is copied
    /// and nothing is retained; see the ownership table on [`ActorId`](types.zig).
    pub fn init(bytes: []const u8) ActorId {
        return .{ .bytes = bytes };
    }

    /// The actor spelled by `bytes`, copied into `gpa`. Use this when the
    /// actor has to outlive the buffer it came from: a randomly generated one,
    /// or one read out of a scratch buffer.
    ///
    /// **Any length is legal, including zero.** An automerge actor id is a
    /// byte string, not a fixed-width number; sixteen is what
    /// [`random`](ActorId.random) draws and nothing more. The copy is the
    /// caller's to release with `gpa.free(id.bytes)`.
    pub fn initCopy(gpa: std.mem.Allocator, bytes: []const u8) !ActorId {
        return .{ .bytes = try gpa.dupe(u8, bytes) };
    }

    /// Sixteen cryptographically secure bytes drawn into `gpa`, which the
    /// caller frees with `gpa.free(id.bytes)`.
    ///
    /// `io` supplies the bytes and is not retained. The draw is
    /// [`std.Io.randomSecure`](../../lib/std/Io.zig), which always leaves
    /// the process, has no weaker fallback, and blocks; `error.Canceled` is
    /// the caller's own cancellation and nothing was drawn.
    /// `error.EntropyUnavailable` means the operating system had no entropy
    /// to give, and `error.OutOfMemory` that the 16 bytes were not available.
    /// On either refusal nothing is allocated for the caller.
    ///
    /// Upstream draws the same sixteen bytes from `getrandom` and panics when
    /// that fails ([`types.rs:63-68`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
    /// This returns the refusal instead, because a caller that cannot get
    /// entropy still has to decide what to do, and a caller that cannot tell
    /// "no id" from "no entropy" cannot decide anything.
    pub fn random(
        gpa: std.mem.Allocator,
        io: std.Io,
    ) (std.mem.Allocator.Error || std.Io.RandomSecureError)!ActorId {
        const bytes = try gpa.alloc(u8, 16);
        errdefer gpa.free(bytes);
        try io.randomSecure(bytes);
        return .{ .bytes = bytes };
    }

    /// Whether the two spell the same actor.
    pub fn eql(a: ActorId, b: ActorId) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }

    /// Change encoding orders actors by the lexicographic order of their
    /// bytes. Every ordered comparison of actors must go through this.
    pub fn order(a: ActorId, b: ActorId) std.math.Order {
        return std.mem.order(u8, a.bytes, b.bytes);
    }

    /// Whether `a` sorts before `b`; [`order`](ActorId.order) is the
    /// comparison.
    pub fn lessThan(_: void, a: ActorId, b: ActorId) bool {
        return a.order(b) == .lt;
    }

    /// The actor's bytes as lowercase hex, in a fresh allocation from `gpa`
    /// that the caller frees with that allocator. Every actor length is legal,
    /// so the result is `2 * bytes.len` characters.
    pub fn toHex(gpa: std.mem.Allocator, self: ActorId) ![]u8 {
        const out = try gpa.alloc(u8, self.bytes.len * 2);
        err.hexInto(self.bytes, out);
        return out;
    }

    /// The actor `text` spells, decoded into a fresh allocation from `gpa` that
    /// the caller frees with `gpa.free(id.bytes)`.
    ///
    /// Upper and lower case hex are both accepted. **Any even number of hex
    /// digits is accepted, including none and including a length that is not
    /// sixteen**: an automerge actor id is a byte string of any length, and
    /// upstream's `ActorId::try_from(&str)` refuses only a string that is not
    /// hex ([`types.rs:88-96`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
    ///
    /// `error.InvalidActorId` is that refusal and `error.OutOfMemory` the
    /// only other one. Neither hands the caller an allocation.
    pub fn fromHex(gpa: std.mem.Allocator, text: []const u8) Error!ActorId {
        const bytes = err.hexFrom(gpa, text) catch |e| switch (e) {
            error.InvalidHex => return error.InvalidActorId,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .bytes = bytes };
    }

    /// The actor id an `automerged`-style concurrency level expands to:
    /// four magic bytes, the level as LEB128, then the original bytes. This
    /// actor id is longer than the original, which is why the magic bytes are
    /// 0x13 0xb2 0x23 0x09 and not arbitrary.
    ///
    /// The result is an owned copy even when `self` is one: the caller frees
    /// it with `gpa.free(id.bytes)`. `self` is unchanged.
    pub fn withConcurrency(gpa: std.mem.Allocator, self: ActorId, level: usize) !ActorId {
        // `unsignedSize` is a size, not a fallible call: it returns the width
        // the value's LEB128 encoding needs and cannot fail
        // (`parse/leb128.rs:15-40`, reached through `leb128::unsignedSize`).
        const leb = @import("leb128.zig").unsignedSize(level);
        const out = try gpa.alloc(u8, 4 + leb + self.bytes.len);
        @memcpy(out[0..4], &concurrency_magic_bytes);
        // `writeUnsigned` writes and reports how many bytes it used; it cannot
        // fail, and its return is the width `unsignedSize` promised above.
        const n = @import("leb128.zig").writeUnsigned(out[4..], level);
        @memcpy(out[4 + n ..], self.bytes);
        return .{ .bytes = out };
    }
};

/// The fixed prefix a concurrency-derived actor id carries. Upstream's
/// `CONCURRENCY_MAGIC_BYTES` ([`types.rs:23`](../../github-automerge-automerge/rust/automerge/src/types.rs));
/// they sort before most real actors, which is what puts a forked actor at the
/// front of the table.
pub const concurrency_magic_bytes = [4]u8{ 0x13, 0xb2, 0x23, 0x09 };

/// An operation id: a per-actor counter plus the actor index.
///
/// A counter is that actor's own operation number and starts at one
/// ([`types.rs:423`](../../github-automerge-automerge/rust/automerge/src/types.rs));
/// a zero counter is the head sentinel rather than an operation, which is why
/// [`root`](OpId.root) and a sequence head are the same value.
pub const OpId = struct {
    /// The actor's operation number: one or more for a real operation, zero
    /// for the root and for a sequence head.
    counter: u32,
    /// The actor's index in the document's actor table.
    actor: ActorIdx,

    /// The root object (`ROOT`, `types.rs:30`). Not the head of a sequence:
    /// that is an [`ElemId`], and the two are different values that happen to
    /// share this id (`HEAD`, `types.rs:29`).
    pub const root: OpId = .{ .counter = 0, .actor = 0 };

    /// The id of the operation at `counter` made by actor `actor`. Every pair
    /// is legal; the constraints on moving between ids are on
    /// [`prev`](OpId.prev), [`next`](OpId.next) and
    /// [`withNewActor`](OpId.withNewActor), not here.
    pub fn init(counter: u32, actor: ActorIdx) OpId {
        return .{ .counter = counter, .actor = actor };
    }

    /// Whether the two name the same operation.
    pub fn eql(a: OpId, b: OpId) bool {
        return a.counter == b.counter and a.actor == b.actor;
    }

    /// Counter first, then actor. The document's total order over operations.
    pub fn order(a: OpId, b: OpId) std.math.Order {
        if (a.counter != b.counter) return std.math.order(a.counter, b.counter);
        return std.math.order(a.actor, b.actor);
    }

    /// Whether `a` sorts before `b`; [`order`](OpId.order) is the comparison.
    pub fn lessThan(_: void, a: OpId, b: OpId) bool {
        return a.order(b) == .lt;
    }

    /// The id of the operation this actor made immediately before this one.
    ///
    /// **Precondition: `self.counter` is not zero.** This is a subtraction,
    /// so a zero counter — [`root`](OpId.root), or a sequence head, which is
    /// the same value — is a caller error and not an answer: Debug and
    /// ReleaseSafe trap on it and ReleaseFast and ReleaseSmall do not check
    /// it. A caller whose counter came off the wire and may therefore be
    /// corrupt has to test it first, and the op set does exactly that where
    /// a mark end at counter zero would otherwise wrap
    /// ([`op.zig:231-237`](opset/op.zig)).
    pub fn prev(self: OpId) OpId {
        return .{ .counter = self.counter - 1, .actor = self.actor };
    }

    /// The id of the operation this actor made immediately after this one.
    ///
    /// **Precondition: `self.counter` is below `maxInt(u32)`.** This is the
    /// same arithmetic and the same obligation as [`prev`](OpId.prev).
    pub fn next(self: OpId) OpId {
        return .{ .counter = self.counter + 1, .actor = self.actor };
    }

    /// Removes actor index `idx`, shifting the indices above it down. Returns
    /// null when the id itself was the removed actor.
    pub fn withoutActor(self: OpId, idx: ActorIdx) ?OpId {
        if (self.actor > idx) return .{ .counter = self.counter, .actor = self.actor - 1 };
        if (self.actor == idx) return null;
        return self;
    }

    /// Inserts a new actor at index `idx`, shifting indices at or above it up.
    ///
    /// **Precondition: `self.actor` is below `maxInt(ActorIdx)` whenever
    /// `self.actor >= idx`.** The shift is a plain addition, so a document
    /// whose actor table has filled every index and then gains one more
    /// cannot be renumbered through this call. Debug and ReleaseSafe trap on
    /// a violation; ReleaseFast and ReleaseSmall do not check it.
    pub fn withNewActor(self: OpId, idx: ActorIdx) OpId {
        if (self.actor >= idx) return .{ .counter = self.counter, .actor = self.actor + 1 };
        return self;
    }

    /// The id with its actor index replaced by `actor_map`'s entry for it
    /// (`OpId::map`, `types.rs:467-471`).
    ///
    /// An index the map does not cover is `error.InvalidActorIndex`, which is
    /// upstream's `AutomergeError::InvalidActorIndex` (`types.rs:469`). The
    /// mapped value has to fit an `ActorIdx`, which upstream does not check —
    /// it writes `actor as u32` (`types.rs:470`) — because a truncated index
    /// would name a different actor for every op the document holds.
    pub fn map(self: OpId, actor_map: []const usize) MapError!OpId {
        if (self.actor >= actor_map.len) return error.InvalidActorIndex;
        const actor = actor_map[self.actor];
        if (actor > std.math.maxInt(ActorIdx)) return error.Overflow;
        return .{ .counter = self.counter, .actor = @intCast(actor) };
    }

    /// The id as the single `u64` upstream keeps an operation in: the counter
    /// in the high 32 bits and the actor index in the low 32
    /// ([`types.rs:434-437`](../../github-automerge-automerge/rust/automerge/src/types.rs)).
    pub fn toU64(self: OpId) u64 {
        return (@as(u64, self.counter) << 32) | self.actor;
    }
};

/// An object id: the document root, or an operation id — and, for an id a
/// document hands out, **the same operation id plus the actor's bytes**.
///
/// **The third field is the whole point, and it is upstream's.** Upstream's
/// `ExId` is `Root` or `Id(u64, ActorId, usize)` — counter, actor *bytes*,
/// actor *index* ([`exid.rs:15-18`](../../github-automerge-automerge/rust/automerge/src/exid.rs)) —
/// and it carries the bytes because an interned actor can **move**: the table
/// is sorted, and interning an actor that sorts before the others renumbers
/// every index at or above it
/// ([`op_set.rs:1400-1405`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
/// Upstream therefore *re-resolves* the index on every use
/// ([`Automerge::exid_to_opid`, `automerge.rs:744-758`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
/// the recorded index if the table still holds that actor there, and
/// `lookup_actor` if it does not.
///
/// **Without the bytes an `ExId` a caller is still holding names nothing after
/// such a move**, and the caller cannot repair it — the information is gone.
/// The one operation that moves the table is `isolate`, which forks a
/// concurrency actor whose magic bytes are `0x13 0xb2 0x23 0x09`
/// ([`types.rs:23`](../../github-automerge-automerge/rust/automerge/src/types.rs))
/// and so sort before most real actors: the fork lands at the front of the
/// table and shifts everything.
///
/// **Identity is the [`OpId`] alone, in both shapes.** The actor is a repair
/// hint, never part of what the id *is*, so a `.named` and an `.id` naming the
/// same operation are the same value to [`ExId.eql`], [`ExId.order`] and every
/// hash map keyed by an `ExId`. That is what keeps this addition from reaching
/// the op set, whose own tables are keyed by [`OpId`] directly
/// ([`ObjIndex.objectType`](opset/index.zig)).
pub const ExId = union(enum) {
    /// An operation named by its counter and actor index alone.
    id: OpId,
    /// Upstream's `ExId::Id` (`exid.rs:17`): the operation and the actor's
    /// bytes, with the index the actor had folded into the operation.
    named: Named,
    /// The document root, which no operation made.
    root,

    /// An operation identity with a borrowed actor repair hint.
    pub const Named = struct {
        /// The operation this names.
        op: OpId,
        /// Borrows the actor's bytes from the document that minted the id, the
        /// way every [`ActorId`] in the port does. Upstream's `ExId` owns a
        /// clone (`op_set.rs:1057-1059`); the borrow is valid as long as the
        /// document is, because the actor table's bytes live in the document's
        /// arena for its whole life.
        actor: ActorId,
    };

    /// Upstream's `ExId::Id(counter, actor, actor_index)`
    /// (`op_set.rs:1057-1059`).
    pub fn withActor(op: OpId, who: ActorId) ExId {
        return .{ .named = .{ .op = op, .actor = who } };
    }

    /// The id a cursor's two halves name: `.root` when neither half is
    /// present, null when only one is, and null when the counter is wider
    /// than an [`OpId`]'s. `idsEqual`-style cursors carry the two halves
    /// separately (`exid.rs:22-28`), so this is the shape a cursor becomes.
    pub fn fromParts(ctr: ?u64, act: ?ActorIdx) ?ExId {
        if (ctr == null and act == null) return .root;
        if (ctr == null or act == null) return null;
        const c = ctr.?;
        if (c > std.math.maxInt(u32)) return null;
        return .{ .id = .{ .counter = @intCast(c), .actor = act.? } };
    }

    /// Whether this names the document root rather than an operation. Only
    /// `.root` answers true; [`fromParts`](ExId.fromParts) produces it for a
    /// cursor with neither half, and [`withActor`](ExId.withActor) never
    /// does.
    pub fn isRoot(self: ExId) bool {
        return self == .root;
    }

    /// The operation id, or null for the root.
    pub fn opId(self: ExId) ?OpId {
        return switch (self) {
            .root => null,
            .id => |i| i,
            .named => |n| n.op,
        };
    }

    /// The operation counter, or `null` for the root.
    pub fn counter(self: ExId) ?u32 {
        return if (self.opId()) |i| i.counter else null;
    }

    /// The actor-table index, or `null` for the root.
    pub fn actor(self: ExId) ?ActorIdx {
        return if (self.opId()) |i| i.actor else null;
    }

    /// The actor's bytes, or null when this id does not carry them.
    ///
    /// **The one thing that decides whether an id can be re-resolved**, and
    /// why it is an accessor rather than a field: an id from
    /// [`ExId.fromParts`] or straight off a row carries an index and no way to
    /// check it.
    pub fn actorBytes(self: ExId) ?ActorId {
        return switch (self) {
            .root, .id => null,
            .named => |n| n.actor,
        };
    }

    /// Compares operation identities. Actor repair hints do not affect equality.
    pub fn eql(a: ExId, b: ExId) bool {
        const ai = a.opId() orelse return b == .root;
        const bi = b.opId() orelse return false;
        return ai.eql(bi);
    }

    /// Orders the root first, then operation identities. Ignores actor repair hints.
    pub fn order(a: ExId, b: ExId) std.math.Order {
        const ai = a.opId() orelse return if (b.isRoot()) .eq else .lt;
        const bi = b.opId() orelse return .gt;
        return ai.order(bi);
    }

    /// Removes actor index `idx` and shifts later indices down.
    /// Returns `null` if this operation used `idx`. The root is unchanged.
    pub fn withoutActor(self: ExId, idx: ActorIdx) ?ExId {
        const i = self.opId() orelse return self;
        const n = i.withoutActor(idx) orelse return null;
        return switch (self) {
            .named => |v| withActor(n, v.actor),
            else => .{ .id = n },
        };
    }

    /// `OpId::with_new_actor` (`types.rs:447-451`) shifts the **index**; the
    /// bytes it names are the same actor either way, so they ride along.
    /// The `OpId.withNewActor` index-overflow precondition also applies here.
    pub fn withNewActor(self: ExId, idx: ActorIdx) ExId {
        const i = self.opId() orelse return self;
        const n = i.withNewActor(idx);
        return switch (self) {
            .named => |v| withActor(n, v.actor),
            else => .{ .id = n },
        };
    }
};

/// The element a sequence row is anchored to (`ElemId`, `types.rs:652-683`).
///
/// This is a wrapper over an [`OpId`] for exactly one reason: **the head**. The
/// head is `OpId{0, 0}` (`HEAD`, `types.rs:29`), and a counter of zero is not
/// an operation — an actor's first op has counter one (`types.rs:423`) — so
/// that value means "the front of the sequence" instead of naming an element.
/// A sequence row therefore has two shapes, and they differ in the actor column
/// alone:
///
/// | anchor | `key_actor` | `key_ctr` |
/// | --- | --- | --- |
/// | a normal element | the element's actor | the element's counter |
/// | the head | absent | zero |
///
/// Which is [`actor`] and [`icounter`], upstream's two answers, which
/// deliberately do not agree with each other (`types.rs:663-674`,
/// `op_set2/types.rs:616-628`). The encoder appends exactly those two
/// (`op_set2/change/collector.rs:406-407`) and the reader reads exactly those
/// two back (`op_set2/op_set/op_iter.rs:239-247`). `(absent, absent)` is the
/// third shape and it is a **map key**, not a head — which is why the counter
/// of a head anchor is a zero and not a null.
///
/// **`id` is the payload and the accessors below are the surface.** Zig has no
/// field privacy, so a caller *can* reach `id` and nothing stops it; reaching
/// for it is what loses the head, and `actor()` is the answer that keeps it.
pub const ElemId = struct {
    /// The operation that made the element. The head is `OpId{0, 0}`
    /// (`types.rs:680-682`).
    id: OpId,

    /// The head of a sequence (`ElemId::head`, `types.rs:680-682`), which is
    /// the constant `HEAD` (`types.rs:29`). This is what a row inserting at
    /// the front of a list hangs by (`op_set2/op_set.rs:1984`).
    pub fn head() ElemId {
        return .{ .id = OpId.root };
    }

    /// The element an operation made (`ElemId(opid)`, `types.rs:653`).
    ///
    /// Upstream's field is `pub(crate)` (`types.rs:653`), so in-crate code
    /// writes the wrapper directly wherever it has an `OpId`: an insert's
    /// register is its own id (`op_set2/op.rs:1042`, `:1075`). This is the
    /// same construction, and it is total — `fromOpId(OpId{0, 0})` *is* the
    /// head, because upstream's `is_head` is `*self == HEAD` (`types.rs:676-678`)
    /// and so there is no "almost head" for this to lose.
    pub fn fromOpId(id: OpId) ElemId {
        return .{ .id = id };
    }

    /// Whether this is the head rather than an element (`ElemId::is_head`,
    /// `types.rs:676-678`).
    pub fn isHead(self: ElemId) bool {
        return self.id.eql(OpId.root);
    }

    /// The actor that made the element, or null for the head
    /// (`ElemId::actor`, `types.rs:668-674`).
    pub fn actor(self: ElemId) ?ActorIdx {
        if (self.isHead()) return null;
        return self.id.actor;
    }

    /// The counter the element was made at, zero for the head
    /// (`ElemId::icounter`, `types.rs:663-666`).
    ///
    /// There is no head case here, unlike [`actor`]: the head's counter is a
    /// `Some(0)` on the wire and `KeyRef::icounter` wraps this in a `Some`
    /// without asking (`op_set2/types.rs:623-628`).
    pub fn icounter(self: ElemId) i64 {
        return @intCast(self.id.counter);
    }

    /// The element with its actor index remapped, and the head unchanged
    /// (`ElemId::map`, `types.rs:656-662`).
    ///
    /// The head returns before the map is consulted, so an actor map with no
    /// entry for index zero still maps a head — upstream `:657-659`.
    pub fn map(self: ElemId, actor_map: []const usize) MapError!ElemId {
        if (self.isHead()) return self;
        return .{ .id = try self.id.map(actor_map) };
    }

    /// Upstream derives `PartialEq` (`types.rs:652`); the field is a plain
    /// struct, so the comparison is `OpId`'s.
    pub fn eql(a: ElemId, b: ElemId) bool {
        return a.id.eql(b.id);
    }

    /// Upstream derives `Ord` over the single `OpId` field (`types.rs:652`), so
    /// this is `OpId`'s order and nothing else: counter first, then actor
    /// (`types.rs:440-444`).
    ///
    /// The head is therefore the **minimum**, because no counter is below
    /// zero, and that is what makes "anchored at the head" the first position
    /// in a list rather than an unordered special case. Rule R4 depends on it:
    /// an insert is legal in a register iff it is anchored to the previous
    /// element *or* its own id sorts before the register's anchor
    /// (`op_set2/op.rs:1061-1063`), and with the head as the minimum an insert
    /// anchored at the head sits in front of every other register.
    pub fn compare(a: ElemId, b: ElemId) std.math.Order {
        return a.id.order(b.id);
    }

    /// Whether `a` sorts before `b`; [`compare`](ElemId.compare) is the
    /// comparison.
    pub fn lessThan(_: void, a: ElemId, b: ElemId) bool {
        return a.compare(b) == .lt;
    }
};

/// What an actor remap refuses (`OpId::map`, `types.rs:467-471`).
///
/// Upstream returns `AutomergeError::InvalidActorIndex(self.actor())`
/// (`types.rs:469`) and then writes `actor as u32` (`types.rs:470`), which
/// truncates. The port refuses the truncation as well; see [`OpId.map`].
pub const MapError = error{
    /// The actor map has no entry for the id's actor index
    /// (`types.rs:469`).
    InvalidActorIndex,
    /// The map's entry does not fit an actor index (`types.rs:470`, which does
    /// not check).
    Overflow,
};

/// What kind of object an id names.
pub const ObjType = enum {
    map,
    /// Retained for backwards compatibility. Tables are identical to maps.
    table,
    list,
    text,

    /// Whether objects of this type are addressed by position rather than by
    /// key.
    pub fn isSequence(self: ObjType) bool {
        return self == .list or self == .text;
    }

    /// The sequence flavour of this object type, or null for a map or a
    /// table.
    pub fn asSequenceType(self: ObjType) ?SequenceType {
        return switch (self) {
            .list => .list,
            .text => .text,
            else => null,
        };
    }

    /// Orders the types by their numeric value, which is the order they are
    /// declared in. Nothing in the wire format depends on it.
    pub fn order(a: ObjType, b: ObjType) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
};

/// A property of an object: a map key, or a sequence index.
///
/// **`key` is a borrow.** It points at key bytes that live somewhere else —
/// for a document that is the op set's key arena, for a value the caller
/// supplied it is the caller's own buffer. Neither this type nor anything it
/// is returned with copies the bytes, so they have to outlive the `Prop`.
/// The same rule governs [`ScalarValueRef.raw`](value.zig) on the value side.
pub const Prop = union(enum) {
    /// The map key's bytes, borrowed as described above.
    key: []const u8,
    /// The position in the sequence.
    index: usize,

    /// The key's bytes, or null when this is a sequence index.
    pub fn asStr(self: Prop) ?[]const u8 {
        return switch (self) {
            .key => |k| k,
            .index => null,
        };
    }

    /// The sequence position, or null when this is a map key.
    pub fn asIndex(self: Prop) ?usize {
        return switch (self) {
            .key => null,
            .index => |i| i,
        };
    }

    /// Whether the two name the same property. A key and an index are never
    /// the same property, and two keys are compared by content.
    pub fn eql(a: Prop, b: Prop) bool {
        return switch (a) {
            .key => |x| switch (b) {
                .key => |y| std.mem.eql(u8, x, y),
                .index => false,
            },
            .index => |x| switch (b) {
                .key => false,
                .index => |y| x == y,
            },
        };
    }
};

/// Whether a sequence holds arbitrary values or characters.
pub const SequenceType = enum {
    list,
    text,
};

/// How text is measured. Every index into a text object is in these units.
pub const TextEncoding = enum {
    unicode_code_point,
    utf8_code_unit,
    utf16_code_unit,
    grapheme_cluster,

    /// The number of units in `s` under this encoding.
    pub fn width(self: TextEncoding, s: []const u8) usize {
        return switch (self) {
            .unicode_code_point => std.unicode.utf8CountCodepoints(s) catch s.len,
            .utf8_code_unit => s.len,
            .utf16_code_unit => @import("unicode.zig").countUtf16CodeUnits(s) catch s.len,
            .grapheme_cluster => @import("unicode.zig").countGraphemes(s) catch s.len,
        };
    }

    /// The `TEXT_ENCODING_TAG` byte written into a change.
    pub fn tag(self: TextEncoding) u8 {
        return switch (self) {
            .unicode_code_point => 0,
            .utf8_code_unit => 1,
            .utf16_code_unit => 2,
            .grapheme_cluster => 3,
        };
    }

    /// The encoding a stored `TEXT_ENCODING_TAG` names.
    /// `error.InvalidTextEncoding` for a byte outside the four the format
    /// defines, which is the only refusal.
    pub fn fromTag(t: u8) !TextEncoding {
        return switch (t) {
            0 => .unicode_code_point,
            1 => .utf8_code_unit,
            2 => .utf16_code_unit,
            3 => .grapheme_cluster,
            else => error.InvalidTextEncoding,
        };
    }
};

/// An object id plus its type: the pair an object's header records.
pub const ObjMeta = struct {
    /// Which object this is. `.root` for the document root.
    id: ExId,
    /// What kind of object it is.
    typ: ObjType,

    /// The document root, which is a map (`types.rs:30`).
    pub fn root() ObjMeta {
        return .{ .id = .root, .typ = .map };
    }
};

test "OpId orders by counter then actor" {
    try std.testing.expect(OpId.init(1, 0).order(OpId.init(2, 0)) == .lt);
    try std.testing.expect(OpId.init(2, 0).order(OpId.init(1, 9)) == .gt);
    try std.testing.expect(OpId.init(1, 0).order(OpId.init(1, 1)) == .lt);
    try std.testing.expect(OpId.init(1, 1).order(OpId.init(1, 1)) == .eq);
}

test "ElemId's head has no actor, and a normal element has one" {
    // The head is `OpId{0, 0}` (`types.rs:680-682`) and answers null for the
    // actor (`types.rs:668-674`), which is what makes a head anchor's actor
    // column absent.
    try std.testing.expectEqual(@as(?ActorIdx, null), ElemId.head().actor());
    // Its counter is *not* null: `icounter` has no head case
    // (`types.rs:663-666`), and the reader's head arm is `(Some(0), None)`
    // (`op_set2/op_set/op_iter.rs:240-242`).
    try std.testing.expectEqual(@as(i64, 0), ElemId.head().icounter());

    const one = ElemId.fromOpId(OpId.init(4, 2));
    try std.testing.expectEqual(@as(?ActorIdx, 2), one.actor());
    try std.testing.expectEqual(@as(i64, 4), one.icounter());

    // Only the head answers that way, and an element whose actor happens to be
    // zero is still an element.
    try std.testing.expect(ElemId.head().isHead());
    try std.testing.expect(!one.isHead());
    try std.testing.expect(!ElemId.fromOpId(OpId.init(1, 0)).isHead());
    try std.testing.expectEqual(@as(?ActorIdx, 0), ElemId.fromOpId(OpId.init(1, 0)).actor());
    // `fromOpId` cannot build an "almost head": upstream's `is_head` is
    // `*self == HEAD` (`types.rs:676-678`), so the one value it recognises is
    // the head, and there is nothing between the two.
    try std.testing.expect(ElemId.fromOpId(OpId.root).isHead());
    try std.testing.expectEqual(@as(?ActorIdx, null), ElemId.fromOpId(OpId.root).actor());
}

test "ElemId's order is the OpId order, which makes the head the minimum" {
    // `Ord` is derived over the single field (`types.rs:652`), and `OpId`'s is
    // counter then actor (`types.rs:440-444`).
    try std.testing.expectEqual(.lt, ElemId.head().compare(ElemId.fromOpId(OpId.init(1, 0))));
    try std.testing.expectEqual(.gt, ElemId.fromOpId(OpId.init(1, 0)).compare(ElemId.head()));
    try std.testing.expectEqual(.eq, ElemId.head().compare(ElemId.head()));
    // Nothing sorts below a counter of zero, so the head is below every
    // element whatever its actor is — which is what makes "anchored at the
    // head" the first position in a list rather than an unordered case
    // (`op_set2/op.rs:1061-1063`).
    try std.testing.expectEqual(.lt, ElemId.head().compare(ElemId.fromOpId(OpId.init(0, 9))));
    const biggest = ElemId.fromOpId(OpId.init(std.math.maxInt(u32), 9));
    try std.testing.expect(ElemId.lessThan({}, ElemId.head(), biggest));
}

test "ElemId's map leaves the head alone and remaps an element" {
    // The head returns before the map is read (`types.rs:656-659`), so an empty
    // map — which covers no actor index at all — still maps it.
    const none: []const usize = &.{};
    try std.testing.expect((try ElemId.head().map(none)).isHead());
    try std.testing.expectEqual(@as(?ActorIdx, null), (try ElemId.head().map(none)).actor());

    const map = [_]usize{ 7, 8, 9 };
    const moved = try ElemId.fromOpId(OpId.init(4, 2)).map(&map);
    try std.testing.expectEqual(@as(ActorIdx, 9), moved.actor().?);
    try std.testing.expectEqual(@as(i64, 4), moved.icounter());
    try std.testing.expect(moved.eql(ElemId.fromOpId(OpId.init(4, 9))));
    // An element whose actor the map does not cover is upstream's
    // `InvalidActorIndex` (`types.rs:469`).
    try std.testing.expectError(error.InvalidActorIndex, ElemId.fromOpId(OpId.init(4, 3)).map(&map));
    // Upstream writes the mapped value with `as u32` (`types.rs:470`) and
    // truncates it. A truncated actor index would rename this element's
    // author for every column that names it, so the port refuses instead.
    const wide = [_]usize{std.math.maxInt(ActorIdx) + 1};
    try std.testing.expectError(error.Overflow, ElemId.fromOpId(OpId.init(4, 0)).map(&wide));
}

test "ExId root and remapping" {
    try std.testing.expect(ExId.isRoot(ExId.root));
    try std.testing.expect(ExId.counter(ExId.root) == null);
    const a: ExId = .{ .id = .init(3, 1) };
    try std.testing.expectEqual(@as(?u32, 3), ExId.counter(a));
    // Removing actor 0 shifts actor 1 down to 0; removing actor 1 removes the
    // id itself.
    try std.testing.expect(ExId.actor(a.withoutActor(0).?) == 0);
    try std.testing.expect(a.withoutActor(1) == null);
    // Inserting a new actor 0 shifts actor 1 up.
    try std.testing.expect(ExId.actor(a.withNewActor(0)) == 2);
    // The root is never affected.
    try std.testing.expect(ExId.isRoot(ExId.withoutActor(ExId.root, 0).?));
}

test "ExId from parts rejects half a pair" {
    try std.testing.expect(ExId.fromParts(null, null).? == .root);
    try std.testing.expect(ExId.fromParts(1, null) == null);
    try std.testing.expect(ExId.fromParts(null, 0) == null);
    try std.testing.expect(ExId.counter(ExId.fromParts(5, 2).?) == 5);
    try std.testing.expect(ExId.fromParts(std.math.maxInt(u32) + 1, 0) == null);
}

test "ChangeHash ordering, checksum, and fragment level" {
    const gpa = std.testing.allocator;
    var a: ChangeHash = .zero;
    a.bytes = [_]u8{0x01} ** 32;
    var b: ChangeHash = .zero;
    b.bytes = [_]u8{0x02} ** 32;
    try std.testing.expect(a.order(b) == .lt);
    try std.testing.expectEqual([4]u8{ 1, 1, 1, 1 }, a.checksum());
    // Only the first four bytes survive a checksum round trip.
    const from_sum = ChangeHash.fromChecksum(a.checksum());
    try std.testing.expectEqualSlices(u8, a.bytes[0..4], from_sum.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 28, from_sum.bytes[4..]);
    try std.testing.expectEqual(@as(usize, 0), a.fragmentLevel());

    var c: ChangeHash = .zero;
    c.bytes = [_]u8{0} ** 32;
    c.bytes[31] = 1;
    try std.testing.expectEqual(@as(usize, 31), c.fragmentLevel());

    const parsed = try ChangeHash.parse(gpa, "00" ** 32);
    try std.testing.expect(parsed.eql(ChangeHash.zero));
}

test "ActorId equality and ordering" {
    const gpa = std.testing.allocator;
    const a = try ActorId.initCopy(gpa, &[_]u8{ 0xaa, 0xbb });
    defer gpa.free(a.bytes);
    const b = try ActorId.initCopy(gpa, &[_]u8{ 0xaa, 0xcc });
    defer gpa.free(b.bytes);

    try std.testing.expect(a.order(b) == .lt);
    try std.testing.expect(a.eql(a));

    const hex = try ActorId.toHex(gpa, a);
    defer gpa.free(hex);
    try std.testing.expectEqualStrings("aabb", hex);

    const back = try ActorId.fromHex(gpa, "aabb");
    defer gpa.free(back.bytes);
    try std.testing.expect(back.eql(a));
}

test "TextEncoding widths" {
    // "aé" is two code points, three UTF-8 bytes, two UTF-16 units, and two
    // grapheme clusters.
    const s = "aé";
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.unicode_code_point.width(s));
    try std.testing.expectEqual(@as(usize, 3), TextEncoding.utf8_code_unit.width(s));
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.utf16_code_unit.width(s));
    try std.testing.expectEqual(@as(usize, 2), TextEncoding.grapheme_cluster.width(s));
    try std.testing.expect((try TextEncoding.fromTag(2)) == .utf16_code_unit);
    try std.testing.expectError(error.InvalidTextEncoding, TextEncoding.fromTag(9));
}

test "an actor id is any byte string, and only a non-hex string is refused" {
    const gpa = std.testing.allocator;

    // Sixteen is what `random` draws and is not a rule: upstream's actor id
    // is a byte string (`types.rs:88-96`), so no digits, two digits and
    // sixty-four all decode.
    const empty = try ActorId.fromHex(gpa, "");
    defer gpa.free(empty.bytes);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);

    const short = try ActorId.fromHex(gpa, "aabb");
    defer gpa.free(short.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, short.bytes);

    // Either case decodes to the same bytes.
    const upper = try ActorId.fromHex(gpa, "AABB");
    defer gpa.free(upper.bytes);
    try std.testing.expect(upper.eql(short));

    const long = try ActorId.fromHex(gpa, "ab" ** 32);
    defer gpa.free(long.bytes);
    try std.testing.expectEqual(@as(usize, 32), long.bytes.len);

    // A non-hex digit and an odd count are the two refusals, and both are
    // `InvalidActorId` rather than a parse error a caller has to guess at.
    try std.testing.expectError(error.InvalidActorId, ActorId.fromHex(gpa, "zz"));
    try std.testing.expectError(error.InvalidActorId, ActorId.fromHex(gpa, "0"));
    // A well-formed hex string of the wrong length is not a refusal here: the
    // length is a change hash's business, not an actor id's.
    try std.testing.expectError(error.InvalidChangeHashBytes, ChangeHash.parse(gpa, "aabb"));
    try std.testing.expectError(error.InvalidHex, ChangeHash.parse(gpa, "zz"));
}

test "ActorId.random refuses a runtime with no entropy and keeps nothing" {
    const gpa = std.testing.allocator;
    // A `std.Io` that differs from the test runtime in exactly one slot.
    // `randomSecure` has no weaker fallback by design, so this is the refusal
    // a caller has to handle rather than a degraded draw. The testing
    // allocator reports a leak at the end of the test, so this also proves
    // the refusal leaves no allocation behind.
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = std.Io.failingRandomSecure;
    const blind: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };

    try std.testing.expectError(error.EntropyUnavailable, ActorId.random(gpa, blind));
}

test "ActorId.random draws sixteen secure bytes, and no two draws agree" {
    const gpa = std.testing.allocator;
    const a = try ActorId.random(gpa, std.testing.io);
    defer gpa.free(a.bytes);
    const b = try ActorId.random(gpa, std.testing.io);
    defer gpa.free(b.bytes);

    try std.testing.expectEqual(@as(usize, 16), a.bytes.len);
    try std.testing.expectEqual(@as(usize, 16), b.bytes.len);
    // Sixteen bytes from a process-wide counter repeat; sixteen bytes from the
    // operating system do not.
    try std.testing.expect(!a.eql(b));
}
