//! An object's keys, in row order, one per visible register
//! (`rust/automerge/src/iter/keys.rs`, 90 lines).
//!
//! This is the shape `ReadDoc::keys` returns
//! ([`read.rs:50`](../../github-automerge-automerge/rust/automerge/src/read.rs)):
//! one string per register, and **for a sequence the string is the element id
//! rendered as `"<counter>@<actor>"`**. It is a [`TopOps`] walk and an
//! `OpSet::to_string` call and nothing else — which is the whole reason it is
//! this small and the reason it must not grow any logic of its own.
//!
//! # It is `OpSet.topOps`, and the buffers are that walk's own
//!
//! [`OpSet.keys`] is `Keys::new(self, self.top_ops(obj, clock))`
//! ([`op_set.rs:377-379`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//! so [`Keys.init`] takes a [`TopWalk`] **by value** and never builds a second
//! one. The port's [`TopOps`] is three walks alive at once and each needs its
//! own successor buffer ([`TopWalk`](../opset/op_set.zig), `op_set.zig:354-385`),
//! so [`OpSet.topOps`] allocates a **fresh** [`top_op.TopScratch`] on every call
//! — three allocations, one per walk
//! ([`topScratch`](../opset/top_op.zig), `top_op.zig:730-744`).
//!
//! **So two [`Keys`] over one op set are independent, and both may be live at
//! once.** The port's sharing rule ([`op_set.zig:40-49`](../opset/op_set.zig))
//! is about the walks that borrow the op set's *shared* buffer
//! ([`OpSet.succ_scratch`](../opset/op_set.zig)), and a top walk borrows no such
//! buffer: it brings its own. The test "a key walk takes the winner walk's
//! scratch, so two may be live at once" reads two of them interleaved and
//! deinits both, which is what a caller who needs two at once is doing.
//! [`Keys.deinit`] frees the three buffers it was handed and nothing else.
//!
//! # A register is absent, not null
//!
//! A key every row of which has been deleted yields **nothing**. There is no
//! `null` entry and no tombstone: the winner of a register is the highest-id
//! row with no unshadowed successor
//! ([`IndexBuilder.flush`](../opset/index.zig), `index.rs:175-184`), and a
//! register whose rows are all shadowed has none, so the top walk steps over
//! it. Upstream's `Item` is a `String` and not an `Option<String>`
//! ([`keys.rs:13`](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs)),
//! which is this fact stated as a type.
//!
//! # The key is borrowed, not owned, and there are two owners
//!
//! Upstream's item is an owned `String` because `OpSet::to_string` is
//! `format!` ([`op_set.rs:1093-1098`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
//! The port returns a borrowed slice into document storage. One
//! return type carries both windows, so which one a key is under is decided by
//! what kind of key it is, and that is stated here because nothing else on the
//! surface says it:**
//!
//! * a **map key** is the **string table's own bytes**, resolved from the
//!   interned id `key_str` holds
//!   ([`opiter.KeyIter.load`](../opset/op_iter.zig), `op_iter.rs:258-263`;
//!   [`Op.elemidOrKey`](../opset/op.zig)). The owner is the
//!   [`columns.StringTable`](../opset/columns.zig) the op set borrows — in a
//!   document that is its own `Strings`
//!   ([`Document.strings`](../../doc.zig)), and **interning copies into an
//!   arena that only grows** ([`Strings.intern`](../../doc.zig),
//!   `doc.zig:287-296`: the bytes are duped into an `ArenaAllocator` and the id
//!   list may reallocate without moving them), so **a map key is valid for as
//!   long as the table, and so for a document for as long as the document** — a
//!   later mutation does not move it. The test in
//!   [src/read.zig](../../read.zig), "a map key is the document's own bytes, and
//!   a mutation does not move them", is the one that pins it.
//! * a **sequence anchor** is **rendered into a buffer this walk already owns**
//!   ([`Keys.buf`]), which the next [`next`] overwrites, so it is valid only
//!   until this walk's next `next`. A caller that has to hold one across
//!   another call copies it — or hands the walk's answer to
//!   [`OpSet.opIdText`](../opset/op_set.zig), which allocates and takes any
//!   length.
//!
//! **A sequence anchor is a key here, not a stop**, which is why the two
//! windows share one return type; see [`Keys.next`].
//!
//! # What is not here
//!
//! `KeyIter` and `KeyOpIter` ([`keys.rs:30-90`](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs))
//! are `#[cfg(test)]` upstream and are **not ported**, for the reason
//! [op_query.zig's module table](../opset/op_query.zig) already recorded:
//! `key_ops` is a test-only combinator. These helpers group a raw op stream by
//! key, and the walk this file holds has already done that — a register is one
//! row out of it.
//!
//! [`TopOps`]: ../opset/top_op.zig
//! [`TopWalk`]: ../opset/op_set.zig

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const clockmod = @import("../clock.zig");
const opcols = @import("../opset/columns.zig");
const optypes = @import("../opset/types.zig");
const opiter = @import("../opset/op_iter.zig");
const opmod = @import("../opset/op.zig");
const opset = @import("../opset/op_set.zig");

const Allocator = std.mem.Allocator;
const Error = err.Error;
const InternalError = err.InternalError;
const ReadOpError = opiter.ReadOpError;

const Clock = clockmod.Clock;
const KeyRef = optypes.KeyRef;

// ── What a key walk can fail with ───────────────────────────────────────────

/// What reading a key walk can fail with.
///
/// The top walk's own set ([`top_op.TopError`](../opset/top_op.zig), which is
/// the union of the three below) — a column that ran out or a cast that would
/// lose bits ([`ReadOpError`](../opset/op_iter.zig)), a range that is not one
/// object's ([`Error`](../../src/error.zig)), and the two upstream assertions
/// the port keeps as [`InternalError`](../../src/error.zig). Nothing else: the
/// op set's [`OpSet.getActor`](../opset/op_set.zig) raises
/// `error.InvalidActorIndex` and a key too long to render raises
/// `error.Overflow`, and both are already members.
pub const KeysError = ReadOpError || Error || InternalError;

/// The head of a sequence, as upstream renders it
/// ([`types.rs:33`](../../github-automerge-automerge/rust/automerge/src/types.rs),
/// `HEAD_STR`, reached through `ElemId`'s `Exportable` at `types.rs:296-303`).
///
/// **Only reachable from a key that is a sequence anchor**, because
/// [`Op.elemidOrKey`] builds that anchor from the inserting row's own id
/// ([`op.zig:1876-1879`](../opset/op.zig), `op.rs:1040-1046`) and no id is
/// `{0, 0}`. It is written anyway because upstream is, and because a reader
/// that answered a null there would be answering something upstream does not.
const head_text = "_head";

/// How many bytes the rendered-anchor buffer is.
///
/// A rendered anchor is the counter (at most ten decimal digits), one `@`, and
/// the actor id. `ActorId.bytes` is a caller slice of no fixed length
/// ([`types.zig:84-85`](../../src/types.zig)), so the buffer is sized for the
/// ids a document actually carries and an id that does not fit is
/// `error.Overflow` — a total answer, never a truncated key and never a panic.
/// [`OpSet.opIdText`](../opset/op_set.zig) is the allocating answer and takes
/// any length.
const key_buf_len = 96;

// ── The walk ────────────────────────────────────────────────────────────────

/// An object's keys, one per visible register, in row order
/// ([`Keys`], [`keys.rs:7-28`](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs)).
///
/// **Row order is the walk's order and this walk does not sort.** Within one
/// object the registers **ascend** — map registers by key string, sequence
/// registers by element id, rule **R2** ([`Op.step`](../opset/op.zig),
/// `op.zig:2215-2222`, `op.rs:1059-1060`) — so `Keys` over a map with keys
/// `"a"`, `"b"`, `"c"` answers them in that order and over a list answers the
/// element ids in *element* order, which is not the order the strings they
/// render to sort in.
///
/// # What this value borrows, and who frees it
///
/// **Three borrows and one obligation, and none of them is the caller's
/// memory.** `op_set` is borrowed and must outlive this walk; `walk` **owns**
/// three successor buffers, which [`deinit`](Keys.deinit) must release exactly
/// once, with the **op set's own allocator** — in a document,
/// [`Document.allocator`](../../doc.zig) — because that is what
/// [`OpSet.topOps`](../opset/op_set.zig) allocated them with; and `buf` is
/// inline storage for a rendered sequence anchor, owned here and overwritten by
/// the next [`next`](Keys.next).
///
/// **Constructing one allocates nothing by hand** — a pointer, a [`TopWalk`]
/// and a fixed buffer — but [`ofObj`](Keys.ofObj) *is* handed a walk from
/// `topOps`, and that call allocates.
pub fn Keys(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op set the walk reads and a rendered anchor's actor bytes come
        /// from, and the one [`ofObj`](Keys.ofObj) asked for the object of
        /// (`keys.rs:9`).
        ///
        /// **Borrowed**, and the op set must not be mutated, moved or freed
        /// while a walk built over it is alive: the rendered arm of
        /// [`next`](Keys.next) reads the actor table, and a map key is the
        /// string table's own bytes (the module's third section).
        op_set: *opset.OpSet(O),
        /// The winner walk, **together with the three successor buffers it
        /// owns** (`keys.rs:9`, upstream's `TopOps`).
        ///
        /// These buffers are this walk's and no other walk's: `topOps` built a
        /// fresh scratch for this call, so two walks over one op set do not
        /// share them. [`deinit`](Keys.deinit) releases them.
        walk: opset.TopWalk(O),
        /// Where a sequence anchor's text is rendered, owned here and valid
        /// until the next [`next`](Keys.next).
        buf: [key_buf_len]u8 = undefined,

        /// A walk over the keys `walk` yields (`Keys::new`, `keys.rs:23-27`).
        ///
        /// Upstream's is one line; the port's is one line too, and it is
        /// **taken, not rebuilt** — see the module's first section.
        ///
        /// **The teardown travels with the walk it is given**: this walk takes
        /// `walk` by value, so it owns those three buffers and the caller must
        /// call [`deinit`](Keys.deinit) with the allocator they came from. A
        /// caller that built the walk with its own
        /// [`topScratch`](../opset/top_op.zig) frees it with the allocator it
        /// passed there.
        pub fn init(op_set: *opset.OpSet(O), walk: opset.TopWalk(O)) Self {
            return .{ .op_set = op_set, .walk = walk };
        }

        /// The keys of `obj`, as the clock sees them (`OpSet::keys`,
        /// `op_set.rs:377-379`).
        ///
        /// The one-liner upstream spells, against the port's `topOps`.
        ///
        /// # What this walk owns, and what it borrows
        ///
        /// **Owns: three successor buffers.** `topOps` builds a fresh
        /// [`topScratch`](../opset/top_op.zig) for this call and with **the
        /// op set's own `gpa`**, so **any number of walks over one op set may
        /// be live at once** — they do not share a buffer, and the port's
        /// one-live-at-a-time rule ([`op_set.zig:40-49`](../opset/op_set.zig))
        /// is about the walks that borrow the op set's *shared* one, which a
        /// top walk does not. The test "a key walk takes the winner walk's
        /// scratch, so two may be live at once" reads two of them interleaved.
        /// Whatever built the walk must free it with
        /// [`deinit`](Keys.deinit) **and the allocator it was built with**:
        /// the op set's own, which for a document is
        /// [`Document.allocator`](../../doc.zig). **Exactly once** — see
        /// [`deinit`](Keys.deinit).
        ///
        /// **Borrows: the op set and the clock.** `op_set` must not move or be
        /// mutated while the walk is alive. `clock` is a [`Clock`] **by value**,
        /// which is a borrowed `[]u32` plus the allocator it was taken with, and
        /// the walk reads through it: **null is the present** — every operation
        /// the op set holds — and a non-null clock bounds the walk to the
        /// operations it covers, so **the caller's clock has to outlive this
        /// walk, and calling `Clock.deinit` while a walk built from it is still
        /// being read leaves that walk reading released counters.**
        pub fn ofObj(
            op_set: *opset.OpSet(O),
            obj: types.ExId,
            clock: ?Clock,
        ) KeysError!Self {
            return .{ .op_set = op_set, .walk = try op_set.topOps(obj, clock) };
        }

        /// Frees the successor buffers and nothing else
        /// ([`TopWalk.deinit`](../opset/op_set.zig)).
        ///
        /// Upstream has nothing to free: its `TopOps` borrows three lazy
        /// column cursors and allocates nothing (`top_op.rs:19-23`). The port's
        /// is three walks alive at once, which is what makes this necessary.
        ///
        /// # Which allocator, and how many times
        ///
        /// **`gpa` must be the allocator the buffers were allocated with** —
        /// for a walk from [`ofObj`](Keys.ofObj) or from
        /// [`OpSet.topOps`](../opset/op_set.zig) that is **the op set's own**,
        /// which for a document is [`Document.allocator`](../../doc.zig). Any
        /// other allocator is a mismatched free. A walk built by hand over a
        /// caller's [`topScratch`](../opset/top_op.zig) is freed with the
        /// allocator that scratch was taken with.
        ///
        /// **Once, on the one owner.** The receiver is a pointer and the body
        /// ends in `self.* = undefined`, so a second call reads undefined
        /// storage rather than freeing the same three buffers again. **A copy
        /// carries the buffers but not the teardown**: `var b = a; a.deinit(gpa);
        /// b.deinit(gpa);` frees them twice, because the copy's own outer state
        /// was never poisoned. Moving the walk is fine (`var b = a; a` is dead
        /// from then on); copying it is not.
        ///
        /// After this call the value is unusable: `next` and every other method
        /// read it. Nothing this walk borrowed is freed here — not the op set,
        /// not the string table, not the caller's clock.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.walk.deinit(gpa);
            self.* = undefined;
        }

        /// The next key, or null at the end of the object's rows
        /// ([`Iterator::next` for `Keys`],
        /// [`keys.rs:15-19`](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs))).
        ///
        /// `op_set.to_string(op.elemid_or_key())`, both halves of which are in
        /// [`render`].
        ///
        /// # Which borrow the answer is
        ///
        /// **The return type is one slice for two answers with two owners, so
        /// this is the place that has to say which one this is:**
        ///
        /// * a **map key** is the op set's string table's own bytes — valid for
        ///   as long as that table, and so for a document for as long as the
        ///   document. The next `next` does not disturb it.
        /// * a **sequence anchor** is rendered into this walk's
        ///   [`buf`](Keys.buf), and **the next `next` on this walk overwrites
        ///   it.** Copy it if it has to survive the step, or ask
        ///   [`OpSet.opIdText`](../opset/op_set.zig), which allocates.
        ///
        /// **Null is the end of the rows, not an absent register** — see the
        /// module's second section.
        pub fn next(self: *Self) KeysError!?[]const u8 {
            const op = (try self.walk.next()) orelse return null;
            return try self.render(op.elemidOrKey());
        }

        /// Returns a copied key that survives another step and document
        /// teardown (`keys.rs:13`). The caller frees it with `gpa`.
        /// A failed copy consumes the step but owns no returned storage.
        pub fn nextOwned(self: *Self, gpa: Allocator) (KeysError || Allocator.Error)!?[]u8 {
            const op = (try self.walk.next()) orelse return null;
            return switch (op.elemidOrKey()) {
                .map => |key| try gpa.dupe(u8, key),
                .seq => |elem| blk: {
                    if (elem.isHead()) break :blk try gpa.dupe(u8, head_text);
                    const actor = self.op_set.getActor(elem.actor().?) orelse return error.InvalidActorIndex;
                    break :blk try std.fmt.allocPrint(gpa, "{d}@{f}", .{ elem.icounter(), actor });
                },
            };
        }

        /// [`OpSet::to_string`] for a key
        /// ([`op_set.rs:1093-1098`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
        /// on the two shapes a [`KeyRef`] has.
        ///
        /// * `.map` is `Export::Special(p.to_string())`
        ///   ([`types.rs:645-650`](../../github-automerge-automerge/rust/automerge/src/types.rs)),
        ///   so it is the key itself, borrowed out of the string table.
        /// * `.seq` is `Export::Id` and reaches the format string at
        ///   `op_set.rs:1095`, `"{}@{}"` over the counter and the actor's
        ///   bytes. The head is `Export::Special("_head")` (`types.rs:296-303`),
        ///   which is the other arm.
        ///
        /// **A sequence anchor is a key here, not a stop.** Upstream's
        /// `ReadDoc::keys` documents that a sequence's keys *are* the element
        /// ids as strings ([`read.rs:49-50`](../../github-automerge-automerge/rust/automerge/src/read.rs)),
        /// and the walk is the same for every object type
        /// ([`automerge.rs:1662-1667`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
        /// so refusing one would empty `keys()` on every list and text. A
        /// register whose key is an anchor rather than a string is therefore
        /// **rendered**. The anchor-rendering test uses a valid list child
        /// beside map keys, since a map cannot hold sequence registers.
        fn render(self: *Self, key: KeyRef) KeysError![]const u8 {
            switch (key) {
                .map => |text| return text,
                .seq => |elem| {
                    if (elem.isHead()) return head_text;
                    const actor = self.op_set.getActor(elem.actor().?) orelse
                        return error.InvalidActorIndex;
                    return std.fmt.bufPrint(
                        &self.buf,
                        "{d}@{f}",
                        .{ elem.icounter(), actor },
                    ) catch error.Overflow;
                },
            }
        }
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The concrete op set the fixtures are read through.
///
/// **`opmod.Op` and not `opmod.ChangeOp`**, for the reason
/// [map_range.zig](map_range.zig) records: `Op` borrows its row's successors
/// and its value, so a fixture is an array of `Op` over its own spans and needs
/// no allocator. The index columns come from [`OpSet.rebuildIndex`] rather than
/// from the rows, which is what a loaded document does and is the only way a
/// fixture with a *conflicted* or *deleted* register can be right — `Op.top` is
/// `Op.visible` ([`op.zig:1868-1871`](../opset/op.zig)), so a splice would mark
/// every visible row a winner.
const Set = opset.OpSet(opmod.Op);

/// The encoding every fixture is built with, so a width is a count of code
/// points and not a count of bytes.
const encoding: types.TextEncoding = .unicode_code_point;

/// The document's actors, **sorted**: an actor index is a position in this
/// table ([`types.zig:20-21`](../../src/types.zig)).
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

fn opId(ctr: u32, actor: types.ActorIdx) types.OpId {
    return types.OpId.init(ctr, actor);
}

fn made(ctr: u32, actor: types.ActorIdx) types.ExId {
    return .{ .id = opId(ctr, actor) };
}

fn anchor(id: types.OpId) KeyRef {
    return .{ .seq = types.ElemId.fromOpId(id) };
}

/// A row as the columns spell it. Every borrowed payload — the key, the value
/// and the successor span — belongs to the fixture, which outlives the op set.
fn row(
    id: types.OpId,
    obj: types.ExId,
    key: KeyRef,
    insert: bool,
    act: optypes.Action,
    val: optypes.ScalarValue,
    succs: []const opmod.SuccEntry,
) opmod.Op {
    return opmod.Op.init(
        0,
        false,
        id,
        act,
        obj,
        key,
        insert,
        val,
        false,
        null,
        opmod.SuccCursors.fromSpan(succs, 0),
    );
}

/// The common shape of every row above: a map row that inserts nothing.
fn mapRow(
    id: types.OpId,
    obj: types.ExId,
    key: []const u8,
    val: optypes.ScalarValue,
    succs: []const opmod.SuccEntry,
) opmod.Op {
    return row(id, obj, .{ .map = key }, false, .set, val, succs);
}

/// A successor edge with no increment, which is how a delete reaches the op
/// set ([`columns.zig:81-85`](../opset/columns.zig): "A delete is never a
/// row"). The id it names need not be a row either, and in a real document it
/// is not — it is the delete's own id.
fn shadows(succ_id: types.OpId) [1]opmod.SuccEntry {
    return [1]opmod.SuccEntry{.{ .id = succ_id, .inc = null }};
}

/// The string table a fixture's op set borrows.
///
/// **Heap-allocated, and that is an ownership rule rather than a convenience**
/// ([`op_set.zig`](../opset/op_set.zig)'s `documentSet`): the op set borrows
/// the table, so it has to sit at one address for as long as the set does, and
/// a struct that owned the table and were returned by value would leave the
/// set's `strings.ctx` pointing at a dead frame.
const Table = struct {
    gpa: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }
    fn deinit(self: *Table) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
    }
    fn asTable(self: *Table) opcols.StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }
    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }
    fn intern(ctx: *anyopaque, text: []const u8, gpa: Allocator) err.ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(ctx));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// An op set and the table it borrows, built together.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    fn build(gpa: Allocator, actors: []const types.ActorId, rows: []const opmod.Op) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, encoding, self.table.asTable()) catch |e| {
            self.table.deinit();
            return e;
        };
        errdefer self.set.deinit();
        _ = try self.set.splice(0, rows);
        // The index is **derived**, never declared: a row carries no statement
        // about which register it wins, and a fixture that let `Op.top` stand
        // in for that would make every visible row a winner.
        try self.set.rebuildIndex();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// The root map's keys, each read and compared by content.
///
/// `expectEqual` on two slices compares their **pointers**
/// ([`std/testing.zig:130-139`](../../lib/std/testing.zig)), and a key here is
/// a borrow whose address says nothing, so the comparison has to be by bytes.
/// The trailing null is the exhaustion check, and asking again after it is the
/// idempotence a document walk depends on.
fn expectKeys(walk: *Keys(opmod.Op), want: []const []const u8) !void {
    for (want) |text| {
        const got = (try walk.next()) orelse return error.TestExpectedResult;
        try testing.expectEqualStrings(text, got);
    }
    try testing.expect((try walk.next()) == null);
}

// ── The tests ───────────────────────────────────────────────────────────────

test "a map's three keys come out in row order, and the walk then stops" {
    const gpa = testing.allocator;
    // Registers **ascend** within an object (rule R2, `op.rs:1059-1060`:
    // `(KeyRef::Map(s1), KeyRef::Map(s2)) => s1 > s2` on the new row against
    // the stepper), so a, b, c is the canonical row order and the reader —
    // which walks rows and does not sort — answers a, b, c. **For a map that
    // order coincides with sorted order**, so this test cannot by itself tell
    // a walk from a sort; the list test below is the one that can, because
    // element ids and the strings they render to do not sort the same way.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(2, 0), .root, "b", .{ .int = 2 }, &.{}),
        mapRow(opId(3, 0), .root, "c", .{ .int = 3 }, &.{}),
    });
    defer doc.destroy();

    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    defer walk.deinit(gpa);

    try expectKeys(&walk, &.{ "a", "b", "c" });

    // **Exhaustion is idempotent**, because a document walk asks twice: once
    // to learn the length and once to stop.
    try testing.expect((try walk.next()) == null);
    try testing.expect((try walk.next()) == null);
}

test "a key whose every row is deleted is absent, not present and null" {
    const gpa = testing.allocator;
    // A delete is never a row: it reaches the op set as a successor id on the
    // row it shadows, with no increment beside it (`columns.zig:81-85`). So a
    // fully deleted register is two rows that are *both* shadowed, and the
    // highest-id row with no unshadowed successor — the register's winner
    // (`index.rs:175-184`) — is not there to be found. `d`'s two successor ids
    // are the two deletes' ids, and neither is a row.
    const s4 = shadows(opId(5, 0));
    const s5 = shadows(opId(6, 0));
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(4, 0), .root, "d", .{ .int = 4 }, &s4),
        mapRow(opId(5, 0), .root, "d", .{ .int = 5 }, &s5),
    });
    defer doc.destroy();

    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    defer walk.deinit(gpa);

    // `d` is gone and `a` is not, so this is not a walk that stops early: the
    // absence is per register. Registers ascend, so `a` before `d` is the
    // canonical order and the walk answers the only register that is left.
    try expectKeys(&walk, &.{"a"});
}

test "a three-row key appears once, at the register that won it" {
    const gpa = testing.allocator;
    // `c`'s three rows: the first two are shadowed and the third is not, so
    // the winner is the **highest id**, not the first row
    // (`index.zig:539-543`, and the backwards scan at `index.zig:563-570`).
    const s7 = shadows(opId(8, 0));
    const s8 = shadows(opId(9, 0));
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(7, 0), .root, "c", .{ .int = 70 }, &s7),
        mapRow(opId(8, 0), .root, "c", .{ .int = 80 }, &s8),
        mapRow(opId(9, 0), .root, "c", .{ .int = 90 }, &.{}),
    });
    defer doc.destroy();

    // Two registers, three rows in the first. **One key for the register** is
    // the claim, so the count matters as much as the names.
    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    defer walk.deinit(gpa);

    const first = (try walk.next()) orelse return error.TestExpectedResult;
    try testing.expectEqualStrings("a", first);
    const second = (try walk.next()) orelse return error.TestExpectedResult;
    try testing.expectEqualStrings("c", second);
    try testing.expect((try walk.next()) == null);

    // **Which of the three rows won is not observable here**, because `Keys`
    // hands out no value. values.zig reads the same register through `Values`
    // and pins the winner's value; that is the other half of this claim and
    // it belongs there rather than duplicated here.
}

test "a key walk takes the winner walk's scratch, so two may be live at once" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        mapRow(opId(2, 0), .root, "b", .{ .int = 2 }, &.{}),
    });
    defer doc.destroy();

    // **Two walks alive at once, each with its own scratch.** `ofObj` builds
    // one; a second `ofObj` builds another. If either reached into the op set's
    // shared successor buffer they would clobber each other, and the second
    // walk below would answer the first one's rows or nothing at all. That
    // `testing.allocator` reports no leak is the other half: the scratch a walk
    // borrows is the only memory any of this owns, and `deinit` gives it back.
    var one = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    var two = try Keys(opmod.Op).ofObj(&doc.set, .root, null);

    // **Both are read part-way first**, so the second walk is exercised while
    // the first is half consumed rather than from a clean slate.
    try testing.expectEqualStrings("a", (try one.next()).?);
    try expectKeys(&two, &.{ "a", "b" });
    try expectKeys(&one, &.{"b"});

    one.deinit(gpa);
    two.deinit(gpa);
}

test "constructing a key walk allocates nothing, and neither does reading one" {
    // `FailingAllocator` with no `fail_index` never fails and counts every byte
    // its inner allocator hands out, so it is a counter and a real allocator at
    // once ([parents.zig:1089-1096](../opset/parents.zig)). It is the **op
    // set's** allocator, which is the only allocator a walk can reach: `Keys`
    // has none of its own, so an allocation inside `ofObj` or `next` would come
    // through here.
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counter.allocator();

    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
    });
    defer doc.destroy();

    // Warm the op set, then let the scratch this walk borrows be accounted
    // for: the property under test is the *next* walk's construction, not the
    // first one's, and comparing across the two is what says so.
    {
        var warm = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
        warm.deinit(gpa);
    }

    const before = counter.allocated_bytes;
    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    try testing.expectEqual(before, counter.allocated_bytes);

    // **And reading one allocates nothing either**, which is the stronger half
    // and the one upstream's `Vec<String>` does not give: the map key is
    // borrowed out of the string table and a sequence anchor is rendered into
    // a buffer the walk already owns.
    var read: usize = 0;
    while (try walk.next()) |text| {
        read += 1;
        try testing.expect(text.len > 0);
    }
    try testing.expectEqual(@as(usize, 1), read);
    try testing.expectEqual(before, counter.allocated_bytes);
    walk.deinit(gpa);
}

test "an empty object has no keys, and an empty range is a walk" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{});
    defer doc.destroy();

    // An op set with no rows: the root's range is empty, and an empty range is
    // a defined walk rather than a corner — `OpSet.scopeToObj` answers
    // `.{0, 0}` and `TopIter.init` clamps to it.
    const rows = try doc.set.scopeToObj(.root);
    try testing.expectEqual(@as(usize, 0), rows.end - rows.start);

    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    defer walk.deinit(gpa);
    try testing.expect((try walk.next()) == null);
    try testing.expect((try walk.next()) == null);
}

test "a map key that is a sequence anchor is rendered, not dropped" {
    const gpa = testing.allocator;
    // The root remains a valid map. Its list child supplies the sequence
    // anchor to the same Keys adapter: a real map cannot mix map and sequence
    // registers. Check the map on both sides of the child as well, so the
    // rendered anchor is not mistaken for iterator exhaustion.
    const list = made(2, 0);
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "a", .{ .int = 1 }, &.{}),
        row(opId(2, 0), .root, .{ .map = "b" }, false, .make_list, .null_value, &.{}),
        mapRow(opId(3, 0), .root, "c", .{ .int = 3 }, &.{}),
        row(opId(4, 0), list, .{ .seq = types.ElemId.head() }, true, .set, .{ .int = 2 }, &.{}),
    });
    defer doc.destroy();

    var map_walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    defer map_walk.deinit(gpa);
    try expectKeys(&map_walk, &.{ "a", "b", "c" });
    var walk = try Keys(opmod.Op).ofObj(&doc.set, list, null);
    defer walk.deinit(gpa);
    try expectKeys(&walk, &.{"4@6161616161616161"});
}

test "a sequence's keys are its element ids, one per register" {
    const gpa = testing.allocator;
    // Two objects: the root and the list it holds. Objects **ascend**
    // (`op.rs:1049-1054`), so the root's row comes first.
    const list = made(2, 0);
    // Element **9** has two rows (9 inserts it, 11 overwrites it) and element
    // **12** has one. Registers ascend by element id (rule R2), and each
    // register's rows are contiguous and ascend in id (rule R3), so this is
    // the canonical row order.
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        row(opId(2, 0), .root, .{ .map = "l" }, false, .make_list, .null_value, &.{}),
        row(opId(9, 0), list, .{ .seq = types.ElemId.head() }, true, .set, .{ .str = "x" }, &.{}),
        row(opId(11, 0), list, anchor(opId(9, 0)), false, .set, .{ .str = "y" }, &.{}),
        row(opId(12, 0), list, anchor(opId(9, 0)), true, .set, .{ .str = "z" }, &.{}),
    });
    defer doc.destroy();

    // **One key per element — two rows, one key** — and the order is *element*
    // order, not string order: `12@6161616161616161` sorts before `9@6161616161616161`
    // and does not come out first. That is what tells a row walk from a sort,
    // which a map fixture cannot do (rule R2 makes the two orders agree there).
    var walk = try Keys(opmod.Op).ofObj(&doc.set, list, null);
    defer walk.deinit(gpa);
    try expectKeys(&walk, &.{ "9@6161616161616161", "12@6161616161616161" });
}

test "API parity owned keys survive iterator and document destruction" {
    const gpa = testing.allocator;
    const doc = try Fixture.build(gpa, &.{actor_a}, &.{
        mapRow(opId(1, 0), .root, "consumer-key", .{ .int = 1 }, &.{}),
    });
    var walk = try Keys(opmod.Op).ofObj(&doc.set, .root, null);
    const key = (try walk.nextOwned(gpa)).?;
    defer gpa.free(key);
    walk.deinit(gpa);
    doc.destroy();
    try testing.expectEqualStrings("consumer-key", key);
}
