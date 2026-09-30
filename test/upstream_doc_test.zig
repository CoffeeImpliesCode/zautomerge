//! `rust/automerge/tests/test.rs`, the document's own test suite, ported case
//! for case and in upstream's order.
//!
//! Every other test in this tree drives **one module** against a hand-built
//! fixture. This one drives **the whole crate** through `@import("zautomerge")`
//! and nothing else: no `OpSet`, no column, no spliced fixture anywhere below.
//! Upstream's file is 4,450 lines and 140 tests, and they are *the document's*
//! tests — the change graph, clocks, merge, actors, heads, `get_changes`,
//! patches, and the many small behaviours that only a long session reaches.
//!
//! Three things make it a session rather than 140 isolated cases, and all three
//! are ported rather than flattened:
//!
//! * **`automerge_test`'s `RealizedObject`.** `assert_doc!` and `assert_obj!`
//!   ([`automerge-test/src/lib.rs`:89-113](../github-automerge-automerge/rust/automerge-test/src/lib.rs))
//!   compare a *fully hydrated* document, conflicts and all, against a literal.
//!   That is the specification for about fifty of the tests below, so both the
//!   literal and the realization are here.
//! * **Set semantics.** `realize_values` collects a register's values into a
//!   `BTreeSet`
//!   ([`:367-383`](../github-automerge-automerge/rust/automerge-test/src/lib.rs))
//!   and `map!` collects a literal's into a `BTreeSet` too
//!   ([`:386-393`](../github-automerge-automerge/rust/automerge-test/src/lib.rs)),
//!   so both sides are compared **as sets**: two operations carrying the same
//!   value are one value, which is what `test_overwriting_a_conflict` asserts,
//!   and the order either side was written in does not matter.
//! * **`hydrate`.** The thirty-odd tests that check a *patch stream* say the
//!   same thing in the same shape: materialize the document, apply the patches,
//!   and require the result to equal a fresh materialization. That is
//!   `hydrate(...).apply_patches(...)` upstream and it is ported as it stands.
//!
//! The leak arbiter is [`gpa`], and **every owned value below comes out of it**:
//! every document, every saved byte string, every head list
//! ([`Document.getHeads`](../src/doc.zig) returns a copy the caller frees), every
//! patch batch ([`Patches.deinit`](../src/patches.zig)), every hydrated mirror
//! ([`hydrate.Value.deinit`](../src/hydrate.zig)) and every clock.
//! [AGENTS.md](../AGENTS.md)'s rule about slices borrowed from a document's own
//! storage is why [`realizeValues`] borrows and the assertions that use it come
//! before the next write.

const std = @import("std");
const am = @import("zautomerge");

const testing = std.testing;

/// **The leak arbiter for the whole file.** One allocator, named once.
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

const Document = am.doc.Document;
const Change = am.change_record.Change;
const ExId = am.ExId;
const ObjType = am.ObjType;
const Prop = am.Prop;
const ScalarValue = am.ScalarValue;
const ChangeHash = am.ChangeHash;
const ActorId = am.ActorId;
const TextEncoding = am.TextEncoding;
const Patch = am.patches.Patch;
const Patches = am.patches.Patches;
const Mirror = am.hydrate.Value;
const Tx = am.manual_transaction.Transaction;

/// The document root, [`automerge::ROOT`](../src/root.zig).
const root: ExId = am.root;

// ── Actors ───────────────────────────────────────────────────────────────────

/// **Upstream draws an actor at random and this file names every one of them.**
///
/// `AutoCommit::new` takes its actor from `ActorId::random`
/// ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and `automerge_test::new_doc` draws a fresh one per document
/// ([`automerge-test/src/lib.rs`:11-15](../github-automerge-automerge/rust/automerge-test/src/lib.rs)),
/// which is right for a test suite and wrong for a failure you cannot reproduce.
/// [`test/example_test.zig`](example_test.zig) says the same thing and does the
/// same thing, so this file mints its actors from a counter instead: distinct
/// bytes, a stable order, and the same bytes on every run.
///
/// The bytes start at one so that no document ever has an **empty** actor,
/// which is a different value from every other one.
var minted_actors: [512][8]u8 = undefined;
var minted_count: usize = 0;

/// The next actor [`newDoc`] hands out. The bytes live in this file's static
/// storage, which is what lets an [`ActorId`] be a borrow: a document
/// **copies** the bytes when it interns the actor ([`doc.zig`](../src/doc.zig),
/// `Actor.unused`).
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

/// A new document in the autocommit flavour ([`AutoCommit::new`](../src/doc.zig),
/// [`autocommit.rs`:92-94](../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
fn newDoc() !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(mintActor());
    return doc;
}

/// The same, with the actor the caller names
/// ([`automerge_test::new_doc_with_actor`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):17-21).
fn newDocWithActor(actor: ActorId) !Document {
    var doc = try Document.init(gpa, .auto);
    errdefer doc.deinit();
    doc.setActorId(actor);
    return doc;
}

/// Two actor ids, the first ordered before the second
/// ([`automerge_test::sorted_actors`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):23-32).
///
/// Upstream draws both at random and sorts them; the property the tests want is
/// only the order, so the order is written down. `aaaaaaaa` and `bbbbbbbb` are
/// fixed width, so the comparison is the byte comparison [`ActorId.order`]
/// ([`types.zig`](../src/types.zig)) makes.
fn sortedActors() [2]ActorId {
    return .{ .{ .bytes = "aaaaaaaa" }, .{ .bytes = "bbbbbbbb" } };
}

/// Three actor ids in ascending order, for the two tests that draw three at
/// random and sort them ([`test.rs`:1710-1715](../github-automerge-automerge/rust/automerge/tests/test.rs),
/// [`:1885-1890](../github-automerge-automerge/rust/automerge/tests/test.rs)).
fn sortedThreeActors() [3]ActorId {
    return .{ .{ .bytes = "aaa00001" }, .{ .bytes = "bbb00002" }, .{ .bytes = "ccc00003" } };
}

// ── Reading ──────────────────────────────────────────────────────────────────

/// The scalar at `prop`, or `error.NoSuchKey` when nothing is there and
/// `error.NotAnObject` when an object is.
fn scalarAt(doc: *const Document, obj: ExId, prop: Prop) !ScalarValue {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The scalar at the root's `prop` **through a transaction**, or
/// `error.NoSuchKey` when nothing is there
/// ([`Transaction.get`](../src/transact.zig), upstream's
/// `impl_read_doc_for_tx!` at [`transaction.rs`:241-248](../github-automerge-automerge/rust/automerge/src/transaction.rs)).
///
/// **The root is fixed and the helper is not general on purpose**: every
/// upstream assertion that uses it is `tx.get(&ROOT, "size")`
/// ([`test.rs`:2517, :2521, :2526, :2530, :2537, :2541](../github-automerge-automerge/rust/automerge/tests/test.rs)),
/// and a helper that took the object too would be a second spelling of the
/// same read.
///
/// **Through the transaction and not through [`scalarAt`]**, and that is the
/// whole difference: a transaction resolves its scope through
/// `get_scope(None)` ([`manual_transaction.rs`:113-122](../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
/// which is the transaction's **own** scope, while a document read resolves
/// through [`Document.readScope`](../src/doc.zig) — null with no isolation. A
/// transaction opened at historical heads therefore reads the document as it
/// stood at those heads, and the two readers disagree while the transaction is
/// open.
fn scalarIn(tx: *Tx, prop: Prop) !ScalarValue {
    const item = (try tx.get(root, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The heads of `doc`. **The caller frees the result**
/// ([`Document.getHeads`](../src/doc.zig) returns a copy, because the graph's
/// own list moves under the next change).
///
/// **The isolation first, and that is the whole point of this helper.** Every
/// upstream case that writes `doc.get_heads()` is calling it on an
/// [`AutoCommit`](../../github-automerge-automerge/rust/automerge/src/autocommit.rs),
/// and upstream has **two** `get_heads`: [`Automerge::get_heads`]
/// (`automerge.rs:1506-1510`, the graph's heads) and
/// [`AutoCommit::get_heads`] (`autocommit.rs:695-700`), which answers the
/// isolation first and falls back to the document's heads
/// (`match &self.isolation { Some(heads) => heads.clone(), None => self.doc.get_heads() }`).
/// [`Document.getHeads`](../src/doc.zig) is the first one; the tests drive the
/// autocommit door throughout, so `headsOf` is the second.
///
/// The case that forces it is
/// `incremental_diff_discards_edits_inside_deleted_map`
/// ([`test.rs`:4024-4028](../../github-automerge-automerge/rust/automerge/tests/test.rs)):
/// upstream reads `after` **while the document is isolated at `before_delete`**,
/// so `after` is that isolation and not the deletion change that follows it.
/// Reading the graph's heads there makes `diff_incremental` answer the
/// recorded log instead of walking, and the stream it returns names three
/// patches where the reference names one — measured, not inferred: the
/// reference emits a single `SpliceText` at
/// `[(Root, "container"), (list, "text")]` and
/// `doc.diffObj(gpa, root, before, before_delete, true)` emits exactly that.
fn headsOf(doc: *const Document) ![]ChangeHash {
    if (doc.isolationHeads()) |at| return gpa.dupe(ChangeHash, at);
    return doc.getHeads(gpa);
}

/// The text of `obj`, compared with `want` and freed.
///
/// **A helper and not a `defer` at every call site**, because
/// [`am.read.text`](../src/read.zig) returns a **caller-owned** string (the
/// reader's own contract) and the shape these assertions were written in —
/// `try testing.expectEqualStrings(want, try am.read.text(doc, obj, gpa))` —
/// drops it on the floor inside an expression. `std.testing.allocator`
/// reports that against the whole test rather than against the line, and
/// `a document can be isolated and integrated` leaks seven of them.
fn expectText(doc: *const Document, obj: ExId, want: []const u8) !void {
    const got = try am.read.text(doc, obj, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

/// The mark set's entries, compared with `want` by name and value **in the
/// set's own order**, which is name order
/// ([`marks.zig`:355-363](../src/marks.zig)).
///
/// **A helper and not an expression**, for the reason [`expectText`] gives:
/// [`am.read.markSetAtIndex`](../src/read.zig) hands back a **caller-owned**
/// [`MarkSet`](../src/marks.zig) to be `deinit`ed, and the
/// `expectEqual(.., (try ..).len)` shape drops it on the floor.
fn expectMarkSet(got: *const am.marks.MarkSet, want: []const am.marks.MarkSet.Entry) !void {
    if (got.len() != want.len) {
        std.debug.print("read {d} mark name(s), want {d}\n", .{ got.len(), want.len });
        var dump = got.iter();
        while (dump.next()) |entry| {
            std.debug.print("  got:  {s} = {any}\n", .{ entry.name, entry.value });
        }
        for (want) |w| std.debug.print("  want: {s} = {any}\n", .{ w.name, w.value });
        return error.TestExpectedEqual;
    }
    var it = got.iter();
    for (want) |w| {
        const entry = it.next() orelse return error.TestExpectedResult;
        if (!std.mem.eql(u8, entry.name, w.name) or !entry.value.eql(w.value)) {
            std.debug.print("got {s} = {any}, want {s} = {any}\n", .{
                entry.name,
                entry.value,
                w.name,
                w.value,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// The id of the object at `prop`, or `error.NoSuchKey`.
fn objectAt(doc: *const Document, obj: ExId, prop: Prop) !ExId {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

/// [`Document.getChanges`](../src/doc.zig)'s list as the `[]Change`
/// [`Document.applyChanges`](../src/doc.zig) takes. **The caller frees the
/// array**; the [`Change`] values themselves borrow the list's bodies, which is
/// why the list outlives the call.
fn changeViews(list: *const am.doc.Changes) ![]Change {
    const out = try gpa.alloc(Change, list.len());
    errdefer gpa.free(out);
    for (0..list.len()) |i| out[i] = list.at(i);
    return out;
}

// ── Realized documents ──────────────────────────────────────────────────────

/// One property of a map and every value that property holds
/// ([`automerge-test/src/lib.rs`:386-393](../github-automerge-automerge/rust/automerge-test/src/lib.rs),
/// `BTreeMap<&str, BTreeSet<I>>`).
const Reg = struct {
    key: []const u8,
    values: []const Exp,
};

/// What a ported test expects a document to hold. **`RealizedObject`**
/// ([`automerge-test/src/lib.rs`:210-217](../github-automerge-automerge/rust/automerge-test/src/lib.rs)),
/// written as a literal in the port instead of a macro, because a Zig union has
/// to say which arm it is. `map!` is [`Exp.map`] and `list!` is [`Exp.list`];
/// the braces upstream wraps every value in are the `values` list.
const Exp = union(enum) {
    map: []const Reg,
    /// One list of registers; each element is a set of conflicting values.
    list: []const []const Exp,
    scalar: ScalarValue,
};

/// One key of a realized map, with its register's values.
const Entry = struct { key: []const u8, values: []const Node };

/// What a document actually holds. **The mirror image of [`Exp`]**, and the
/// borrow rule is the port's: a `str`, a `bytes` or a map key points into the
/// document's own storage and is valid until the next mutation
/// ([AGENTS.md](../AGENTS.md)), which is why every assertion below that uses one
/// runs before the next write.
const Node = union(enum) {
    map: []Entry,
    list: []const []const Node,
    scalar: ScalarValue,
};

inline fn scStr(v: []const u8) Exp {
    return .{ .scalar = .{ .str = v } };
}
inline fn scInt(v: i64) Exp {
    return .{ .scalar = .{ .int = v } };
}
inline fn scUint(v: u64) Exp {
    return .{ .scalar = .{ .uint = v } };
}
inline fn scFloat(v: f64) Exp {
    return .{ .scalar = .{ .float = v } };
}
inline fn scCounter(v: i64) Exp {
    return .{ .scalar = .{ .counter = .{ .current = v } } };
}
inline fn scBool(v: bool) Exp {
    return .{ .scalar = .{ .bool_value = v } };
}
inline fn scNull() Exp {
    return .{ .scalar = .null_value };
}
inline fn scBytes(v: []const u8) Exp {
    return .{ .scalar = .{ .bytes = v } };
}

/// The error set the realization walks raise, **named rather than inferred**.
///
/// [`realizeObj`], [`realizeMap`], [`realizeSeq`] and [`realizeValues`] are
/// mutually recursive — an object realizes its children, which realize theirs —
/// and Zig cannot infer an error set through a cycle, so the set is written
/// down: the read surface's own set, allocation, and the one refusal this file
/// adds for a property that is not there.
const RealizeError = am.read.ReadError || Allocator.Error || error{NoSuchKey};

/// The realized root map ([`automerge_test::realize`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):327-329`).
fn realizeRoot(doc: *const Document) RealizeError!Node {
    return realizeObj(doc, root, .map);
}

/// The realized object `obj` ([`realize_obj`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):343-365`).
fn realizeObj(doc: *const Document, obj: ExId, typ: ObjType) RealizeError!Node {
    return switch (typ) {
        .map, .table => realizeMap(doc, obj),
        .list, .text => realizeSeq(doc, obj),
    };
}

/// A map, one entry per visible key.
fn realizeMap(doc: *const Document, obj: ExId) RealizeError!Node {
    var out: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(gpa, out.items);
    var keys = try am.read.keys(doc, obj);
    defer keys.deinit(gpa);
    while (try keys.next()) |key| {
        const values = try realizeValues(doc, obj, .{ .key = key });
        out.append(gpa, .{ .key = key, .values = values }) catch |e| {
            freeNodes(gpa, values);
            return e;
        };
    }
    return .{ .map = try out.toOwnedSlice(gpa) };
}

/// A list or a text, one register per visible element
/// ([`realize_obj`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):356-364`).
fn realizeSeq(doc: *const Document, obj: ExId) RealizeError!Node {
    const len = try am.read.length(doc, obj);
    var out: std.ArrayList([]const Node) = .empty;
    errdefer {
        for (out.items) |set| freeNodes(gpa, set);
        out.deinit(gpa);
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const values = try realizeValues(doc, obj, .{ .index = i });
        out.append(gpa, values) catch |e| {
            freeNodes(gpa, values);
            return e;
        };
    }
    return .{ .list = try out.toOwnedSlice(gpa) };
}

/// Every value a property holds ([`realize_values`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):367-383`).
fn realizeValues(doc: *const Document, obj: ExId, prop: Prop) RealizeError![]const Node {
    const all = try am.read.getAll(doc, obj, prop, gpa);
    defer gpa.free(all);
    var out: std.ArrayList(Node) = .empty;
    errdefer freeNodes(gpa, out.items);
    for (all) |item| {
        const node: Node = switch (item.value) {
            .scalar => |s| .{ .scalar = s },
            .object => |t| try realizeObj(doc, item.id, t),
        };
        out.append(gpa, node) catch |e| {
            freeNode(gpa, node);
            return e;
        };
    }
    return out.toOwnedSlice(gpa);
}

/// What `realize_prop` does ([`automerge-test/src/lib.rs`:331-341](../github-automerge-automerge/rust/automerge-test/src/lib.rs)):
/// the value at one property, and nothing above it.
fn realizeProp(doc: *const Document, obj: ExId, prop: Prop) RealizeError!Node {
    const item = (try am.read.get(doc, obj, prop)) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| .{ .scalar = s },
        .object => |t| try realizeObj(doc, item.id, t),
    };
}

fn freeNode(a: Allocator, node: Node) void {
    switch (node) {
        .scalar => {},
        .map => |entries| freeEntries(a, entries),
        .list => |items| {
            for (items) |set| freeNodes(a, set);
            a.free(items);
        },
    }
}

fn freeNodes(a: Allocator, nodes: []const Node) void {
    for (nodes) |n| freeNode(a, n);
    a.free(nodes);
}

fn freeEntries(a: Allocator, entries: []Entry) void {
    for (entries) |e| freeNodes(a, e.values);
    a.free(entries);
}

// ── The canonical rendering, which is the whole comparison ───────────────────

/// **Any total order answers the set comparison, and this one is the
/// lexicographic order of the rendered text.**
///
/// That means the sort key is the finished value, so the recursion has no
/// fixed point to establish: a parent register sorts its children after each
/// child has rendered its own register completely. It also means a failure
/// prints two strings a reader can diff, which is what `pretty_panic` does
/// ([`automerge-test/src/lib.rs`:480-487](../github-automerge-automerge/rust/automerge-test/src/lib.rs)).
fn renderNode(a: Allocator, node: Node) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    switch (node) {
        .scalar => |s| try renderScalar(a, &out, s),
        .map => |entries| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(a);
            for (entries) |e| try keys.append(a, e.key);
            std.mem.sort([]const u8, keys.items, {}, strLess);
            try out.append(a, '{');
            for (keys.items, 0..) |k, i| {
                if (i > 0) try out.append(a, ',');
                try writeJsonString(a, &out, k);
                try out.appendSlice(a, ":[");
                try renderSet(a, &out, findEntry(entries, k).?.values);
                try out.appendSlice(a, "]");
            }
            try out.append(a, '}');
        },
        .list => |items| {
            try out.append(a, '[');
            for (items, 0..) |set, i| {
                if (i > 0) try out.append(a, ',');
                try out.append(a, '[');
                try renderSet(a, &out, set);
                try out.append(a, ']');
            }
            try out.append(a, ']');
        },
    }
    return out.toOwnedSlice(a);
}

/// One register: every value it holds, sorted, **with the duplicates one
/// `BTreeSet` would have dropped removed**.
fn renderSet(a: Allocator, out: *std.ArrayList(u8), values: []const Node) Allocator.Error!void {
    var rendered: std.ArrayList([]u8) = .empty;
    defer {
        for (rendered.items) |s| a.free(s);
        rendered.deinit(a);
    }
    for (values) |v| try rendered.append(a, try renderNode(a, v));
    std.mem.sort([]u8, rendered.items, {}, strLess);
    try out.append(a, '[');
    var i: usize = 0;
    while (i < rendered.items.len) : (i += 1) {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, rendered.items[i]);
        while (i + 1 < rendered.items.len and
            std.mem.eql(u8, rendered.items[i], rendered.items[i + 1])) : (i += 1)
        {}
    }
    try out.append(a, ']');
}

/// A scalar, **type-tagged**.
///
/// Upstream's `OrdScalarValue::serialize`
/// ([`:275-298`](../github-automerge-automerge/rust/automerge-test/src/lib.rs))
/// prints a number as a bare number, which is fine for a human reading a
/// failure and wrong here: `Int(1)` and `Uint(1)` would render identically, two
/// different values would deduplicate into one, and a test would pass that
/// should not. So each kind carries its own tag and the rendering stays
/// injective.
fn renderScalar(a: Allocator, out: *std.ArrayList(u8), s: ScalarValue) Allocator.Error!void {
    switch (s) {
        .null_value => try out.appendSlice(a, "null"),
        .bool_value => |v| try out.appendSlice(a, if (v) "true" else "false"),
        .int => |v| try out.print(a, "int:{d}", .{v}),
        .uint => |v| try out.print(a, "uint:{d}", .{v}),
        // The bit pattern, so that `-0.0` and `0.0` do not render alike.
        .float => |v| try out.print(a, "f64:{x}", .{@as(u64, @bitCast(v))}),
        .counter => |c| try out.print(a, "counter:{d}", .{c.current}),
        .timestamp => |t| try out.print(a, "ts:{d}", .{t}),
        .str => |v| try writeJsonString(a, out, v),
        .bytes => |v| {
            try out.appendSlice(a, "bytes:");
            for (v) |byte| try out.print(a, "{x:0>2}", .{byte});
        },
        .actor_id => |id| {
            try out.appendSlice(a, "actor:");
            for (id.bytes) |byte| try out.print(a, "{x:0>2}", .{byte});
        },
        .unknown => |u| try out.print(a, "unknown:{d}:", .{u.type_code}),
    }
}

fn writeJsonString(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => {
            if (c < 0x20) {
                try out.print(a, "\\u{x:0>4}", .{c});
            } else {
                try out.append(a, c);
            }
        },
    };
    try out.append(a, '"');
}

fn findEntry(entries: []Entry, key: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── The two assertions ───────────────────────────────────────────────────────

/// `assert_doc!` ([`automerge-test/src/lib.rs`:89-99](../github-automerge-automerge/rust/automerge-test/src/lib.rs)):
/// the whole realized document against a literal.
fn expectDoc(doc: *const Document, expected: Exp) !void {
    const got = try realizeRoot(doc);
    defer freeNode(gpa, got);
    try expectNode(&got, expected);
}

/// `assert_obj!` ([`automerge-test/src/lib.rs`:101-113](../github-automerge-automerge/rust/automerge-test/src/lib.rs)):
/// one property of the document against a literal.
fn expectObj(doc: *const Document, obj: ExId, prop: Prop, expected: Exp) !void {
    const got = try realizeProp(doc, obj, prop);
    defer freeNode(gpa, got);
    try expectNode(&got, expected);
}

fn expectNode(got: *const Node, expected: Exp) !void {
    const want = try expandExp(gpa, expected);
    defer freeNode(gpa, want);
    const a = try renderNode(gpa, want);
    defer gpa.free(a);
    const b = try renderNode(gpa, got.*);
    defer gpa.free(b);
    if (!std.mem.eql(u8, a, b)) {
        std.debug.print(
            "\ndocuments didn't match\n expected\n{s}\n got\n{s}\n",
            .{ a, b },
        );
        return error.DocumentsDoNotMatch;
    }
}

/// The literal as a realized tree, so that one renderer answers for both sides.
fn expandExp(a: Allocator, exp: Exp) Allocator.Error!Node {
    return switch (exp) {
        .scalar => |s| .{ .scalar = s },
        .map => |regs| blk: {
            var out: std.ArrayList(Entry) = .empty;
            errdefer freeEntries(a, out.items);
            for (regs) |r| {
                const values = try expandReg(a, r.values);
                out.append(a, .{ .key = r.key, .values = values }) catch |e| {
                    freeNodes(a, values);
                    return e;
                };
            }
            break :blk Node{ .map = try out.toOwnedSlice(a) };
        },
        .list => |items| blk: {
            var out: std.ArrayList([]const Node) = .empty;
            errdefer {
                for (out.items) |set| freeNodes(a, set);
                out.deinit(a);
            }
            for (items) |set| try out.append(a, try expandReg(a, set));
            break :blk Node{ .list = try out.toOwnedSlice(a) };
        },
    };
}

/// One register: its values, which is the `BTreeSet` `realize_values` builds on
/// the other side.
fn expandReg(a: Allocator, values: []const Exp) Allocator.Error![]const Node {
    var out: std.ArrayList(Node) = .empty;
    errdefer freeNodes(a, out.items);
    for (values) |v| {
        const node = try expandExp(a, v);
        out.append(a, node) catch |e| {
            freeNode(a, node);
            return e;
        };
    }
    return out.toOwnedSlice(a);
}

// ── Hydration and patch streams ──────────────────────────────────────────────

/// The materialized document at `heads`, or at the present when `heads` is
/// null: `Automerge::hydrate`, which the thirty patch-stream tests below use.
///
/// The port reaches the same mirror through [`hydrate.hydrateMap`](../src/hydrate.zig),
/// which takes the op set and an optional clock rather than a document, so the
/// two are named here once. The clock a historical read needs is the one its
/// heads name ([`Document.clockAtHeads`](../src/doc.zig)).
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

/// Applies a patch stream to a mirror and requires the whole stream to apply:
/// `hydrate::Value::apply_patches`
/// ([`hydrate.rs`](../github-automerge-automerge/rust/automerge/src/hydrate.rs)).
fn applyPatches(mirror: *Mirror, enc: TextEncoding, patches: []const Patch) !void {
    const applied = try mirror.applyPatches(enc, patches);
    switch (applied) {
        .ok => {},
        // `Applied.refused` carries the reason as a value rather than as an
        // error ([`hydrate.zig`](../src/hydrate.zig):242-249), so the reason is
        // printed and the stream counts as a failure.
        .refused => |failure| {
            std.debug.print("\npatch stream refused: {s}\n", .{@tagName(failure)});
            return error.PatchStreamRefused;
        },
    }
}

/// **`merge_and_log_patches` followed by `make_patches`**, which is what
/// [`test.rs`:119-126](../github-automerge-automerge/rust/automerge/tests/test.rs)
/// and the other twenty patch-stream tests spell.
///
/// Upstream hands the merge a fresh `PatchLog` and asks for the patches
/// afterwards. This port has one document type with the log on it
/// ([`doc.zig`](../src/doc.zig), `Document.patch_log`), and the only way to
/// turn that log on is [`Document.updateDiffCursor`](../src/doc.zig)
/// ([`autocommit.rs`:199-206](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// which is also the only way to make a local transaction record. So the port's
/// spelling of the upstream pair is: start the cursor, do the work, take the
/// document's own log. `ctx.run` is the work.
fn patchesFrom(doc: *Document, ctx: anytype) !Patches {
    try doc.updateDiffCursor();
    try ctx.run(doc);
    return doc.makePatches(&doc.patch_log);
}

/// [`Document.fork`](../src/doc.zig) through [`Document.forkAt`](../src/doc.zig)
/// at the document's own heads, which is the same document with a fresh actor.
///
/// **`Document.fork` leaks and this is why.** It stores
/// `ActorId.random(gpa)` — sixteen bytes taken from `gpa` — in `actor.unused`
/// ([`doc.zig`](../src/doc.zig):3827-3830) and `Document.deinit` frees no actor
/// bytes, because a caller may have handed `setActorId` a string literal.
/// `Document.forkAt` does the same work correctly (`:3883-3891`): it copies the
/// minted bytes into the fork's own arena and frees the temporary. **Forking at
/// the current heads is what `fork` means**, so the ported tests go through the
/// one that frees what it takes.
fn forkDoc(src: *Document) !Document {
    return forkDocMode(src, .auto);
}

/// The same, for a document in the other flavour. The manual door is the only
/// one a rollback is expressible through, because the autocommit door commits
/// every call (see the `// ── 83.` comment).
fn forkDocMode(src: *Document, mode: am.doc.Mode) !Document {
    const heads = try src.getHeads(gpa);
    defer gpa.free(heads);
    return src.forkAt(gpa, heads, mode);
}

/// The work [`patchesFrom`] runs for
/// `increment_patch_clears_resolved_map_conflict`: one increment of a
/// document's own root key. A named struct because a Zig anonymous struct
/// literal cannot carry a declared method.
const IncrementKeyBy = struct {
    key: []const u8,
    by: i64,

    fn run(self: @This(), d: *Document) !void {
        try am.transaction.increment(d, root, .{ .key = self.key }, self.by);
    }
};

/// The work [`patchesFrom`] runs between turning the log on and reading it: a
/// merge of `other` into the document under test. A named struct because a Zig
/// anonymous struct literal cannot carry a declared method.
const MergeInto = struct {
    other: *Document,

    fn run(self: @This(), d: *Document) !void {
        const heads = try d.merge(gpa, self.other);
        gpa.free(heads);
    }
};

// ── 1. The four patch-log-refusal tests ──────────────────────────────────────
//
// Upstream's `patch_log_from_actor` and `doc_with_actor`
// ([`test.rs`:13-35](../github-automerge-automerge/rust/automerge/tests/test.rs))
// build a patch log and a document for two *different* actors, and the four
// tests below assert that handing one document a patch log built against
// another is an `Err(PatchLogMismatch)` and never a panic.
//
// **The port has no `PatchLogMismatch` to reach, so none of the four is
// ported.** [`error.zig`](../src/error.zig) declares
// `error.PatchLogMismatch` and nothing raises it: the port has one document
// with one log ([`doc.zig`](../src/doc.zig), `Document.patch_log`), so a
// caller's `PatchLog` is never consulted by `applyChanges`, there is no
// `apply_changes_log_patches` to hand one in through, and no
// `into_transaction(Some(log), None)` to carry one. The gap is the API and not
// the behaviour: `PatchLog.migrateActors` and `PatchLog.finishTransaction`
// ([`patches.zig`](../src/patches.zig)) are the machinery a mismatch check
// would sit on.

// ── 2. merge_patches_clear_conflict_after_losing_list_value_is_deleted_from_fuzz_trace
//    [`test.rs`:94-132](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "merge patches clear a conflict after the losing list value is deleted" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x02" });
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .null_value);

    var left = try forkDoc(&doc);
    defer left.deinit();
    left.setActorId(.{ .bytes = "\x03" });
    _ = try am.transaction.put(&left, list, .{ .index = 0 }, .{ .int = 10 });

    var right = try forkDoc(&doc);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&right, list, .{ .index = 0 }, .{ .str = "a" });

    for ([_]*Document{ &left, &right }) |other| {
        const heads = try doc.merge(gpa, other);
        gpa.free(heads);
    }
    _ = try am.transaction.delete(&right, list, .{ .index = 0 });

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    var patches = try patchesFrom(&doc, MergeInto{ .other = &right });
    defer patches.deinit();
    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 3. bundle_with_mark_columns_decodes_from_fuzz_trace
//    [`test.rs`:134-152](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// **Not ported: the port has no `Document.bundle`.** [`API.md`](../API.md)
// §Document lists `bundle(doc, gpa) !Bundle` and nothing implements it: the
// bundle *parser* is written ([`storage/bundle.zig`](../src/storage/bundle.zig),
// `Bundle`, `Builder`, `ChangeIter`, `OpIter`) but no walk turns a document's op
// set into the `BundleChange` / `BundleOp` stream the `Builder` consumes, which
// is the same gap [`doc.zig`](../src/doc.zig)'s module header records for a
// bundle as a document's first chunk.

// ── 4. fork_at_rejects_edit_to_object_outside_isolation_from_fuzz_trace
//    [`test.rs`:154-169](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "fork_at rejects an edit to an object outside the isolation" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    try doc.isolate(gpa, &.{});

    // The list was created after the empty heads, so this edit is refused.
    const result = am.transaction.insert(&doc, list, 0, .{ .int = 1 });

    const heads = try headsOf(&doc);
    defer gpa.free(heads);
    var fork = try doc.forkAt(gpa, heads, .auto);
    defer fork.deinit();

    try testing.expectError(error.InvalidObjId, result);
}

// ── 5. historical_owned_transaction_omits_patches_for_unreachable_object_from_fuzz_trace
//    [`test.rs`:171-196](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a historical transaction omits patches for an unreachable object" {
    var source = try newDoc();
    defer source.deinit();
    const text = try am.transaction.putObject(&source, root, .{ .key = "text" }, .text);

    var doc = try source.clone(gpa, .manual);
    defer doc.deinit();
    var actual = try hydrateAt(&doc, &.{});
    defer actual.deinit();

    // The transaction is scoped to the empty heads, so the text object does not
    // exist inside it and the edit is refused — and must emit no patch with a
    // path through the hidden object.
    try doc.updateDiffCursor();
    var tx = try Tx.openAt(gpa, &doc, &.{});
    defer tx.deinit();
    const result = tx.insert(text, 0, .{ .counter = .{ .current = -104 } });
    // Upstream's `hash.into_iter().collect()`: a transaction that wrote
    // nothing commits nothing, so the branch heads are the empty list.
    const hash_opt = try tx.commit(null, null);
    try testing.expectError(error.InvalidObjId, result);
    const branch = if (hash_opt) |h| blk: {
        const one = try gpa.alloc(ChangeHash, 1);
        one[0] = h;
        break :blk one;
    } else try gpa.alloc(ChangeHash, 0);
    defer gpa.free(branch);
    var expected = try hydrateAt(&doc, branch);
    defer expected.deinit();
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 6. diff_incremental_respects_isolated_heads_from_fuzz_trace
//    [`test.rs`:198-215](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "diff_incremental respects isolated heads" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.putObject(&doc, root, .{ .key = "map" }, .map);
    try doc.isolate(gpa, &.{});

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    // Two hydrations rather than a clone: the port's [`Mirror`] has no `clone`,
    // and a hydration is a pure read, so the second one is the same value from
    // the same bytes.
    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, doc.textEncoding(), patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 7. fork_at_with_increment_over_conflicted_counter_survives_save_load_from_fuzz_trace
//    [`test.rs`:217-246](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "fork_at with an increment over a conflicted counter survives save and load" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });

    var counter = try newDoc();
    defer counter.deinit();
    counter.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.put(&counter, root, .{ .key = "key" }, .{ .counter = .{ .current = 34 } });

    var scalar = try newDoc();
    defer scalar.deinit();
    scalar.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&scalar, root, .{ .key = "key" }, .null_value);

    for ([_]*Document{ &counter, &scalar }) |other| {
        const heads = try doc.merge(gpa, other);
        gpa.free(heads);
    }
    try am.transaction.increment(&doc, root, .{ .key = "key" }, -59);

    const heads = try headsOf(&doc);
    defer gpa.free(heads);
    var fork = try doc.forkAt(gpa, heads, .auto);
    defer fork.deinit();

    var before = try hydrateNow(&fork);
    defer before.deinit();
    const bytes = try fork.saveWithOptions(gpa, .{ .deflate = false });
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, bytes, fork.textEncoding(), .auto);
    defer loaded.deinit();
    var after = try hydrateNow(&loaded);
    defer after.deinit();
    try testing.expect(after.eql(&before));
}

// ── 8. transaction_patches_replace_multi_character_string_in_text_from_fuzz_trace
//    [`test.rs`:248-285](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "transaction patches replace a multi-character string in text" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const text = try tx.putObject(root, .{ .key = "text" }, .text);
        _ = try tx.insert(text, 0, .{ .str = "ab" });
        _ = try tx.commit(null, null);
    }
    const before_heads = try headsOf(&doc);
    defer gpa.free(before_heads);

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const text = try objectAt(&doc, root, .{ .key = "text" });
        _ = try tx.put(text, .{ .index = 1 }, .{ .float = std.math.floatMax(f64) });
        _ = try tx.commit(null, null);
    }
    const after_heads = try headsOf(&doc);
    defer gpa.free(after_heads);
    // **The port's `Document.commit` does not feed the document's patch log**
    // ([`doc.zig`](../src/doc.zig): only `applyChanges` branches on
    // `patch_log.isActive()`, at `:3372`), so a *local* transaction has no patch
    // stream to read back and this test's patches come from
    // [`Document.diff`](../src/doc.zig) over the two head lists. That is
    // `AutoCommit::diff` rather than `make_patches`, and it is the whole of the
    // deviation: the assertion is about the patch content for one known change.
    var patches = try doc.diff(gpa, before_heads, after_heads);
    defer patches.deinit();

    // A string scalar is one text sequence element even when it renders as two
    // characters, so the patch removes the whole rendered width and then
    // splices one object-replacement character.
    const got = patches.slice();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[0].action == .delete_seq);
    try testing.expectEqual(@as(usize, 0), got[0].action.delete_seq.index);
    try testing.expectEqual(@as(usize, 2), got[0].action.delete_seq.length);
    try testing.expect(got[1].action == .splice_text);
    try testing.expectEqual(@as(usize, 0), got[1].action.splice_text.index);
    try testing.expectEqualStrings("\u{fffc}", got[1].action.splice_text.value.asStr());

    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 9. merge_patches_replace_multi_character_string_in_text_from_fuzz_trace
//    [`test.rs`:287-329](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "merge patches replace a multi-character string in text" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    _ = try am.transaction.insert(&doc, text, 0, .{ .str = "ab" });

    var branch = try forkDoc(&doc);
    defer branch.deinit();
    _ = try am.transaction.put(&branch, text, .{ .index = 0 }, .null_value);

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    var patches = try patchesFrom(&doc, MergeInto{ .other = &branch });
    defer patches.deinit();
    const got = patches.slice();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[0].action == .delete_seq);
    try testing.expectEqual(@as(usize, 2), got[0].action.delete_seq.length);
    try testing.expect(got[1].action == .splice_text);
    try testing.expectEqualStrings("\u{fffc}", got[1].action.splice_text.value.asStr());

    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 10. merge_patches_include_text_element_update_from_fuzz_trace
//     [`test.rs`:331-357](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "merge patches include a text element update" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "a");

    var branch = try forkDoc(&doc);
    defer branch.deinit();
    _ = try am.transaction.put(&branch, text, .{ .index = 0 }, .{ .int = 10 });

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    var patches = try patchesFrom(&doc, MergeInto{ .other = &branch });
    defer patches.deinit();
    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 11. diff_preserves_conflict_after_winning_value_is_deleted_from_fuzz_trace
//     [`test.rs`:359-393](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "diff preserves a conflict after the winning value is deleted" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    var second = try forkDoc(&doc);
    defer second.deinit();
    second.setActorId(.{ .bytes = "\x01" });
    var third = try forkDoc(&doc);
    defer third.deinit();
    third.setActorId(.{ .bytes = "\x02" });

    _ = try am.transaction.put(&doc, root, .{ .key = "key" }, .{ .bool_value = false });
    _ = try am.transaction.put(&second, root, .{ .key = "key" }, .null_value);
    _ = try am.transaction.put(&third, root, .{ .key = "key" }, .{ .int = -88 });
    for ([_]*Document{ &second, &third }) |other| {
        const heads = try doc.merge(gpa, other);
        gpa.free(heads);
    }
    const before_heads = try headsOf(&doc);
    defer gpa.free(before_heads);

    _ = try am.transaction.delete(&third, root, .{ .key = "key" });
    {
        const heads = try doc.merge(gpa, &third);
        gpa.free(heads);
    }
    const current_heads = try headsOf(&doc);
    defer gpa.free(current_heads);

    var actual = try hydrateAt(&doc, before_heads);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, current_heads);
    defer expected.deinit();
    var patches = try doc.diff(gpa, before_heads, current_heads);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
    // Two actors still hold a value, so the property is still conflicted.
    try expectDoc(&doc, .{ .map = &.{
        .{ .key = "key", .values = &.{ scBool(false), scNull() } },
    } });
}

// ── 12. incremental_put_seq_in_text_applies_to_hydrated_value_from_fuzz_trace
//     [`test.rs`:395-418](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "an incremental put_seq in text applies to a hydrated value" {
    var doc = try Document.initWithEncoding(gpa, .grapheme_cluster, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "a");
    const before_heads = try headsOf(&doc);
    defer gpa.free(before_heads);
    try doc.updateDiffCursor();

    _ = try am.transaction.put(&doc, text, .{ .index = 0 }, .null_value);
    const current_heads = try headsOf(&doc);
    defer gpa.free(current_heads);

    var actual = try hydrateAt(&doc, before_heads);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, current_heads);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .grapheme_cluster, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 13. current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace
//     [`test.rs`:420-447](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// **Not ported.** The test writes a *block with contents* —
// `update_spans(&text, config, [Span::Block(hydrate_map!{"type" =>
// "paragraph"})])` — and the port's [`transact.Span`](../src/transact.zig) is
// `union(enum) { text: …, block: ExId }`
// ([`iter/spans.zig`](../src/iter/spans.zig):474-485), so a block span names an
// object and carries no map. `am.transaction.updateSpans` therefore cannot
// describe what this test writes.

// ── 14. reverse_diff_of_replaced_lists_applies_to_hydrated_value_from_fuzz_trace
//     [`test.rs`:449-474](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a reverse diff of replaced lists applies to a hydrated value" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.putObject(&doc, root, .{ .key = "first" }, .list);
    const old_second = try am.transaction.putObject(&doc, root, .{ .key = "second" }, .list);
    const historical_heads = try headsOf(&doc);
    defer gpa.free(historical_heads);

    _ = try am.transaction.putObject(&doc, root, .{ .key = "first" }, .list);
    _ = try am.transaction.putObject(&doc, root, .{ .key = "second" }, .text);
    _ = try am.transaction.insert(&doc, old_second, 0, .{ .int = 1 });
    const current_heads = try headsOf(&doc);
    defer gpa.free(current_heads);

    var actual = try hydrateAt(&doc, current_heads);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, historical_heads);
    defer expected.deinit();
    var patches = try doc.diff(gpa, current_heads, historical_heads);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 15. unmark_at_end_of_remotely_inserted_conflicted_scalar_in_text_from_fuzz_trace
//     [`test.rs`:476-508](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "unmark at the end of a remotely inserted conflicted scalar in text" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);

    var inserted = try forkDoc(&doc);
    defer inserted.deinit();
    inserted.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.insert(&inserted, text, 0, .{ .uint = 155 });

    var left = try forkDoc(&inserted);
    defer left.deinit();
    left.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&left, text, .{ .index = 0 }, .{ .uint = 187 });

    var right = try forkDoc(&inserted);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x03" });
    _ = try am.transaction.put(&right, text, .{ .index = 0 }, .{ .bool_value = false });

    for ([_]*Document{ &left, &right }) |other| {
        const heads = try inserted.merge(gpa, other);
        gpa.free(heads);
    }
    {
        const heads = try doc.merge(gpa, &inserted);
        gpa.free(heads);
    }

    const len = try am.read.length(&doc, text);
    try am.transaction.unmark(&doc, text, len, len, .before, "color", null);
}

// ── 16. insert_into_replaced_text_run_with_trailing_zero_width_unmark_from_fuzz_trace
//     [`test.rs`:510-542](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "insert into a replaced text run with a trailing zero-width unmark" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);

    doc.setActorId(.{ .bytes = "\x01" });
    try am.transaction.unmark(&doc, text, 0, 0, .both, "comment", null);
    _ = try am.transaction.insert(&doc, text, 0, .{ .str = "o" });

    var left = try forkDoc(&doc);
    defer left.deinit();
    left.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.put(&left, text, .{ .index = 0 }, .{ .str = "multi\nline" });

    var right = try forkDoc(&doc);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&right, text, .{ .index = 0 }, .null_value);
    _ = try am.transaction.delete(&right, text, .{ .index = 0 });

    for ([_]*Document{ &left, &right }) |other| {
        const heads = try doc.merge(gpa, other);
        gpa.free(heads);
    }

    _ = try am.transaction.insert(&doc, text, 5, .{ .int = -85 });
}

// ── 17. update_text_after_marking_text_with_hidden_scalar
//     [`test.rs`:544-563](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "update_text after marking text with a hidden scalar" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "a");
    _ = try am.transaction.insert(&doc, text, 0, .{ .str = "" });
    try am.transaction.mark(&doc, text, 0, 1, "bold", .before, .{ .bool_value = true });
    try am.transaction.updateText(&doc, text, "hello");
    const got = try am.read.text(&doc, text, gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("hello", got);
}

// ── 18. rollback_after_save_load_of_deep_hydrated_root_map_from_fuzz_trace
//     [`test.rs`:565-632](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// The four generators below are upstream's `fuzz_text`, `fuzz_hydrated_map`,
// `fuzz_hydrated_list` and `fuzz_hydrated_value`
// ([`test.rs`:567-614](../github-automerge-automerge/rust/automerge/tests/test.rs)),
// one for one, and `seed` and `depth` are `u8` here as they are `u8` there.

const fuzz_strings = [_][]const u8{
    "",
    "a",
    "hello",
    "hello world",
    "\u{1F98A}\u{1F43B}",
    "multi\nline",
    "abcdefghijklmnopqrstuvwxyz",
};

/// The generators' error set: allocation plus [`hydrate.ApplyError`], which is
/// the document [`Error`](../src/error.zig) set, because
/// [`hydrate.Value.text`](../src/hydrate.zig) can refuse a string its encoding
/// cannot measure. **Named rather than inferred**, because the three generators
/// are mutually recursive.
const FuzzError = Allocator.Error || am.hydrate.ApplyError;

fn fuzzText(slot: u8) []const u8 {
    if (slot % 8 == 0) return "the quick brown fox jumps over the lazy dog";
    return fuzz_strings[@as(usize, slot) % fuzz_strings.len];
}

fn fuzzValue(seed: u8, depth: u8) FuzzError!am.hydrate.Value {
    if (depth == 0) return am.hydrate.Value.scalar(.{ .int = @as(i64, seed) - 128 });
    return switch (seed % 4) {
        0 => am.hydrate.Value{ .object = .{ .map = try fuzzMap(seed, depth - 1) } },
        1 => am.hydrate.Value{ .object = .{ .list = try fuzzList(seed, depth - 1) } },
        2 => try am.hydrate.Value.text(gpa, .unicode_code_point, fuzzText(seed)),
        else => am.hydrate.Value.scalar(.{ .str = "a" }),
    };
}

fn fuzzMap(seed: u8, depth: u8) FuzzError!am.hydrate.Map {
    var out = am.hydrate.Map.init(gpa, .root);
    errdefer out.deinit();
    {
        const key = try std.fmt.allocPrint(gpa, "m{}", .{seed % 8});
        defer gpa.free(key);
        // `putOwned` takes the value, so there is no `defer` here: upstream's
        // `entries.insert(key, value)` moves it too.
        const value = try fuzzValue(seed, depth);
        out.putOwned(key, .{ .value = value, .conflict = false }) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    {
        const key = try std.fmt.allocPrint(gpa, "n{}", .{seed % 8});
        defer gpa.free(key);
        const value = try fuzzValue(seed +% 1, if (depth == 0) 0 else depth - 1);
        out.putOwned(key, .{ .value = value, .conflict = false }) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    return out;
}

fn fuzzList(seed: u8, depth: u8) FuzzError!am.hydrate.List {
    var out = am.hydrate.List.init(gpa, .root);
    errdefer out.deinit();
    {
        // `push` takes the value; upstream's `vec.push(value)` moves it.
        const value = try fuzzValue(seed, depth);
        out.push(value, false) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    {
        const value = try fuzzValue(seed +% 1, if (depth == 0) 0 else depth - 1);
        out.push(value, false) catch |e| {
            var owned = value;
            owned.deinit();
            return e;
        };
    }
    return out;
}

test "rollback after a save and load of a deep hydrated root map" {
    var doc = try newDoc();
    defer doc.deinit();
    var root_value = try fuzzMap(0, 42);
    defer root_value.deinit();
    try am.transaction.updateObject(&doc, root, root_value);

    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, bytes, .unicode_code_point, .manual);
    defer loaded.deinit();
    var before = try hydrateNow(&loaded);
    defer before.deinit();

    var tx = try Tx.open(gpa, &loaded);
    defer tx.deinit();
    _ = try tx.put(root, .{ .key = "k0" }, .{ .str = "a" });
    _ = try tx.rollback();

    var after = try hydrateNow(&loaded);
    defer after.deinit();
    try testing.expect(after.eql(&before));
}

// ── 19. fork_at_preserves_text_encoding
//     [`test.rs`:634-658](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "fork_at preserves the text encoding" {
    var doc = try Document.initWithEncoding(gpa, .grapheme_cluster, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    _ = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);

    const heads = try headsOf(&doc);
    defer gpa.free(heads);
    var forked = try doc.forkAt(gpa, heads, .auto);
    defer forked.deinit();
    forked.setActorId(.{ .bytes = "\x02" });
    try testing.expectEqual(TextEncoding.grapheme_cluster, forked.textEncoding());

    var before = try hydrateNow(&forked);
    defer before.deinit();
    const bytes = try forked.saveWithOptions(gpa, .{ .deflate = false });
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, bytes, .grapheme_cluster, .auto);
    defer loaded.deinit();
    var after = try hydrateNow(&loaded);
    defer after.deinit();
    try testing.expect(after.eql(&before));
}

// ── 20. load_incremental_into_empty_doc_preserves_utf8_text_encoding
//     [`test.rs`:660-684](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "load_incremental into an empty document preserves the UTF-8 text encoding" {
    var source = try Document.initWithEncoding(gpa, .utf8_code_unit, .auto);
    defer source.deinit();
    source.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.putObject(&source, root, .{ .key = "text" }, .text);

    var receiver = try Document.initWithEncoding(gpa, .utf8_code_unit, .auto);
    defer receiver.deinit();
    receiver.setActorId(.{ .bytes = "\x00" });
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);
    _ = try receiver.loadIncremental(gpa, bytes);

    try testing.expectEqual(TextEncoding.utf8_code_unit, receiver.textEncoding());
    var before = try hydrateNow(&receiver);
    defer before.deinit();
    const again = try receiver.save(gpa);
    defer gpa.free(again);
    var loaded = try Document.load(gpa, again, .utf8_code_unit, .auto);
    defer loaded.deinit();
    var after = try hydrateNow(&loaded);
    defer after.deinit();
    try testing.expect(after.eql(&before));
}

// ── 21. spans_match_text_after_merge_of_conflicting_text_overwrites_from_fuzz_trace
//     [`test.rs`:686-720](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "spans match text after a merge of conflicting text overwrites" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    _ = try am.transaction.insert(&doc, text, 0, .{ .str = "base" });

    var left = try forkDoc(&doc);
    defer left.deinit();
    left.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.put(&left, text, .{ .index = 0 }, .{ .str = "left" });

    var right = try forkDoc(&doc);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&right, text, .{ .index = 0 }, .{ .str = "right" });

    {
        const heads = try left.merge(gpa, &right);
        gpa.free(heads);
    }

    const from_text = try am.read.text(&left, text, gpa);
    defer gpa.free(from_text);
    const from_spans = try spanText(&left, text);
    defer gpa.free(from_spans);
    try testing.expectEqualStrings(from_text, from_spans);
}

/// The visible text of `obj` reassembled from [`am.read.spans`], which is the
/// other half of upstream's `filter_map(|span| match span { Span::Text { text,
/// .. } => Some(text), Span::Block(_) => None })`
/// ([`test.rs`:710-717](../github-automerge-automerge/rust/automerge/tests/test.rs)).
fn spanText(doc: *const Document, obj: ExId) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var walk = try am.read.spans(doc, obj, gpa);
    defer walk.deinit();
    while (try walk.next()) |item| {
        switch (item) {
            .text => |t| try out.appendSlice(gpa, t.text),
            .block => {},
        }
        // The span is the walk's own buffer, so it is released before the next
        // `next` overwrites it.
        var owned = item;
        owned.deinit(gpa);
    }
    return out.toOwnedSlice(gpa);
}

// ── 22. doc_iter_spans_skip_losing_conflicting_text_overwrites_after_object_shift
//     [`test.rs`:722-755](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// **Not ported: the port has no document-level `iter()`.** Upstream's
// `ReadDoc::iter` hands out `DocItem::Text(Span::Text { text, .. })` over the
// whole document ([`iter/doc.rs`](../github-automerge-automerge/rust/automerge/src/iter/doc.rs));
// the port has [`iter/doc.zig`](../src/iter/doc.zig), whose `Doc(O)` walk is the
// *diff* walk and is built from `set.objIdIterRange`, so a consumer cannot
// construct one. There is no `Document.iter` and none of the walk is reachable
// from the public surface.

// ── 23. diff_spans_preserve_marks_on_inserted_text
//     [`test.rs`:757-789](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "diff spans preserve marks on inserted text" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    const before = try headsOf(&doc);
    defer gpa.free(before);

    try am.transaction.spliceText(&doc, text, 0, 0, "abc");
    try am.transaction.mark(&doc, text, 0, 3, "bold", .after, .{ .int = 1 });
    const after = try headsOf(&doc);
    defer gpa.free(after);

    var patches = try doc.diff(gpa, before, after);
    defer patches.deinit();
    var found = false;
    for (patches.slice()) |p| {
        if (p.action == .splice_text and p.action.splice_text.marks != null) found = true;
    }
    try testing.expect(found);
}

// ── 24. diff_spans_skip_losing_conflicting_text_overwrites
//     [`test.rs`:791-825](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "diff spans skip losing conflicting text overwrites" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x00" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    _ = try am.transaction.insert(&doc, text, 0, .{ .str = "base" });
    const before = try headsOf(&doc);
    defer gpa.free(before);

    var left = try forkDoc(&doc);
    defer left.deinit();
    left.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.put(&left, text, .{ .index = 0 }, .{ .str = "left" });

    var right = try forkDoc(&doc);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&right, text, .{ .index = 0 }, .{ .str = "right" });
    {
        const heads = try left.merge(gpa, &right);
        gpa.free(heads);
    }
    const after = try headsOf(&left);
    defer gpa.free(after);

    var patches = try left.diff(gpa, before, after);
    defer patches.deinit();
    var spliced: std.ArrayList(u8) = .empty;
    defer spliced.deinit(gpa);
    for (patches.slice()) |p| {
        if (p.action == .splice_text) {
            try spliced.appendSlice(gpa, p.action.splice_text.value.asStr());
        }
    }
    const from_text = try am.read.text(&left, text, gpa);
    defer gpa.free(from_text);
    try testing.expectEqualStrings(from_text, spliced.items);
}

// ── 25. no_conflict_on_repeated_assignment
//     [`test.rs`:827-838](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "no conflict on a repeated assignment" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "foo" }, .{ .int = 1 });
    _ = try am.transaction.put(&doc, root, .{ .key = "foo" }, .{ .int = 2 });
    try expectDoc(&doc, .{ .map = &.{.{ .key = "foo", .values = &.{scInt(2)} }} });
}

// ── 26. repeated_map_assignment_which_resolves_conflict_not_ignored
//     [`test.rs`:840-858](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a repeated map assignment which resolves a conflict is not ignored" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .int = 123 });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc2, root, .{ .key = "field" }, .{ .int = 456 });
    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .int = 789 });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    const conflicted = try am.read.getAll(&doc1, root, .{ .key = "field" }, gpa);
    defer gpa.free(conflicted);
    try testing.expectEqual(@as(usize, 2), conflicted.len);

    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .int = 123 });
    try expectDoc(&doc1, .{ .map = &.{.{ .key = "field", .values = &.{scInt(123)} }} });
}

// ── 27. repeated_list_assignment_which_resolves_conflict_not_ignored
//     [`test.rs`:860-883](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a repeated list assignment which resolves a conflict is not ignored" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .int = 123 });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc2, list, .{ .index = 0 }, .{ .int = 456 });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc1, list, .{ .index = 0 }, .{ .int = 789 });
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{&.{scInt(789)}} }} },
    } });
}

// ── 28. list_deletion
//     [`test.rs`:885-904](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "list deletion" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .int = 123 });
    _ = try am.transaction.insert(&doc, list, 1, .{ .int = 456 });
    _ = try am.transaction.insert(&doc, list, 2, .{ .int = 789 });
    _ = try am.transaction.delete(&doc, list, .{ .index = 1 });
    try expectDoc(&doc, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{ &.{scInt(123)}, &.{scInt(789)} } }} },
    } });
}

// ── 29. merge_concurrent_map_prop_updates
//     [`test.rs`:906-933](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "merge concurrent map property updates" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "foo" }, .{ .str = "bar" });
    _ = try am.transaction.put(&doc2, root, .{ .key = "hello" }, .{ .str = "world" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try testing.expectEqualStrings("bar", (try scalarAt(&doc1, root, .{ .key = "foo" })).str);
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "foo", .values = &.{scStr("bar")} },
        .{ .key = "hello", .values = &.{scStr("world")} },
    } });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "foo", .values = &.{scStr("bar")} },
        .{ .key = "hello", .values = &.{scStr("world")} },
    } });
    // Upstream's `assert_eq!(realize(doc1), realize(doc2))`: two documents that
    // have merged each other hold the same realized content.
    try doc1.debugCmp(&doc2);
}

// ── 30. add_concurrent_increments_of_same_property
//     [`test.rs`:935-953](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "add concurrent increments of the same property" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try am.transaction.increment(&doc1, root, .{ .key = "counter" }, 1);
    try am.transaction.increment(&doc2, root, .{ .key = "counter" }, 2);
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "counter", .values = &.{scCounter(3)} },
    } });
}

// ── 31. add_increments_only_to_preceeded_values
//     [`test.rs`:955-981](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "add increments only to preceded values" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();

    _ = try am.transaction.put(&doc1, root, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
    try am.transaction.increment(&doc1, root, .{ .key = "counter" }, 1);
    _ = try am.transaction.put(&doc2, root, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
    try am.transaction.increment(&doc2, root, .{ .key = "counter" }, 3);
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "counter", .values = &.{ scCounter(1), scCounter(3) } },
    } });
}

// ── 32. concurrent_updates_of_same_field
//     [`test.rs`:983-1001](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent updates of the same field" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .str = "one" });
    _ = try am.transaction.put(&doc2, root, .{ .key = "field" }, .{ .str = "two" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "field", .values = &.{ scStr("one"), scStr("two") } },
    } });
}

// ── 33. concurrent_updates_of_same_list_element
//     [`test.rs`:1003-1028](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent updates of the same list element" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .list);
    _ = try am.transaction.insert(&doc1, birds, 0, .{ .str = "finch" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc1, birds, .{ .index = 0 }, .{ .str = "greenfinch" });
    _ = try am.transaction.put(&doc2, birds, .{ .index = 0 }, .{ .str = "goldfinch" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{&.{
            scStr("greenfinch"),
            scStr("goldfinch"),
        }} }} },
    } });
}

// ── 34. assignment_conflicts_of_different_types
//     [`test.rs`:1030-1053](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "assignment conflicts of different types" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    var doc3 = try newDoc();
    defer doc3.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .str = "string" });
    _ = try am.transaction.putObject(&doc2, root, .{ .key = "field" }, .list);
    _ = try am.transaction.putObject(&doc3, root, .{ .key = "field" }, .map);
    for ([_]*Document{ &doc2, &doc3 }) |other| {
        const heads = try doc1.merge(gpa, other);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "field", .values = &.{
            scStr("string"),
            .{ .list = &.{} },
            .{ .map = &.{} },
        } },
    } });
}

// ── 35. changes_within_conflicting_map_field
//     [`test.rs`:1055-1079](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "changes within a conflicting map field" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "field" }, .{ .str = "string" });
    const map_id = try am.transaction.putObject(&doc2, root, .{ .key = "field" }, .map);
    _ = try am.transaction.put(&doc2, map_id, .{ .key = "innerKey" }, .{ .int = 42 });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "field", .values = &.{
            scStr("string"),
            .{ .map = &.{.{ .key = "innerKey", .values = &.{scInt(42)} }} },
        } },
    } });
}

// ── 36. changes_within_conflicting_list_element
//     [`test.rs`:1081-1122](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "changes within a conflicting list element" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    const list_id = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list_id, 0, .{ .str = "hello" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }

    const map_in_doc1 = try am.transaction.putObject(&doc1, list_id, .{ .index = 0 }, .map);
    _ = try am.transaction.put(&doc1, map_in_doc1, .{ .key = "map1" }, .{ .bool_value = true });
    _ = try am.transaction.put(&doc1, map_in_doc1, .{ .key = "key" }, .{ .int = 1 });

    const map_in_doc2 = try am.transaction.putObject(&doc2, list_id, .{ .index = 0 }, .map);
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc2, map_in_doc2, .{ .key = "map2" }, .{ .bool_value = true });
    _ = try am.transaction.put(&doc2, map_in_doc2, .{ .key = "key" }, .{ .int = 2 });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }

    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{&.{ .{ .map = &.{
            .{ .key = "key", .values = &.{scInt(1)} },
            .{ .key = "map1", .values = &.{scBool(true)} },
        } }, .{ .map = &.{
            .{ .key = "key", .values = &.{scInt(2)} },
            .{ .key = "map2", .values = &.{scBool(true)} },
        } } }} }} },
    } });
}

// ── 37. concurrently_assigned_nested_maps_should_not_merge
//     [`test.rs`:1124-1154](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrently assigned nested maps should not merge" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const doc1_map_id = try am.transaction.putObject(&doc1, root, .{ .key = "config" }, .map);
    _ = try am.transaction.put(&doc1, doc1_map_id, .{ .key = "background" }, .{ .str = "blue" });
    const doc2_map_id = try am.transaction.putObject(&doc2, root, .{ .key = "config" }, .map);
    _ = try am.transaction.put(&doc2, doc2_map_id, .{ .key = "logo_url" }, .{ .str = "logo.png" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "config", .values = &.{
            .{ .map = &.{.{ .key = "background", .values = &.{scStr("blue")} }} },
            .{ .map = &.{.{ .key = "logo_url", .values = &.{scStr("logo.png")} }} },
        } },
    } });
}

// ── 38. concurrent_insertions_at_different_list_positions
//     [`test.rs`:1156-1189](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent insertions at different list positions" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    try testing.expect(actors[0].order(actors[1]) == .lt);

    const list_id = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list_id, 0, .{ .str = "one" });
    _ = try am.transaction.insert(&doc1, list_id, 1, .{ .str = "three" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try am.transaction.splice(&doc1, list_id, 1, 0, gpa, &.{.{ .str = "two" }});
    _ = try am.transaction.insert(&doc2, list_id, 2, .{ .str = "four" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{
            &.{scStr("one")},
            &.{scStr("two")},
            &.{scStr("three")},
            &.{scStr("four")},
        } }} },
    } });
}

// ── 39. concurrent_insertions_at_same_list_position
//     [`test.rs`:1191-1226](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent insertions at the same list position" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    try testing.expect(actors[0].order(actors[1]) == .lt);

    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .list);
    _ = try am.transaction.insert(&doc1, birds, 0, .{ .str = "parakeet" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc1, birds, 1, .{ .str = "starling" });
    _ = try am.transaction.insert(&doc2, birds, 1, .{ .str = "chaffinch" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("parakeet")},
            &.{scStr("chaffinch")},
            &.{scStr("starling")},
        } }} },
    } });
}

// ── 40. concurrent_assignment_and_deletion_of_a_map_entry
//     [`test.rs`:1228-1247](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent assignment and deletion of a map entry" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "bestBird" }, .{ .str = "robin" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.delete(&doc1, root, .{ .key = "bestBird" });
    _ = try am.transaction.put(&doc2, root, .{ .key = "bestBird" }, .{ .str = "magpie" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "bestBird", .values = &.{scStr("magpie")} },
    } });
}

// ── 41. concurrent_assignment_and_deletion_of_list_entry
//     [`test.rs`:1249-1296](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent assignment and deletion of a list entry" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .list);
    _ = try am.transaction.insert(&doc1, birds, 0, .{ .str = "blackbird" });
    _ = try am.transaction.insert(&doc1, birds, 1, .{ .str = "thrush" });
    _ = try am.transaction.insert(&doc1, birds, 2, .{ .str = "goldfinch" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc1, birds, .{ .index = 1 }, .{ .str = "starling" });
    _ = try am.transaction.delete(&doc2, birds, .{ .index = 1 });

    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("blackbird")},
            &.{scStr("goldfinch")},
        } }} },
    } });
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("blackbird")},
            &.{scStr("starling")},
            &.{scStr("goldfinch")},
        } }} },
    } });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("blackbird")},
            &.{scStr("starling")},
            &.{scStr("goldfinch")},
        } }} },
    } });
}

// ── 42. insertion_after_a_deleted_list_element
//     [`test.rs`:1298-1340](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "insertion after a deleted list element" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .list);
    _ = try am.transaction.insert(&doc1, birds, 0, .{ .str = "blackbird" });
    _ = try am.transaction.insert(&doc1, birds, 1, .{ .str = "thrush" });
    _ = try am.transaction.insert(&doc1, birds, 2, .{ .str = "goldfinch" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try am.transaction.splice(&doc1, birds, 1, 2, gpa, &.{});
    try am.transaction.splice(&doc2, birds, 2, 0, gpa, &.{.{ .str = "starling" }});
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("blackbird")},
            &.{scStr("starling")},
        } }} },
    } });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("blackbird")},
            &.{scStr("starling")},
        } }} },
    } });
}

// ── 43. concurrent_deletion_of_same_list_element
//     [`test.rs`:1342-1382](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent deletion of the same list element" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .list);
    _ = try am.transaction.insert(&doc1, birds, 0, .{ .str = "albatross" });
    _ = try am.transaction.insert(&doc1, birds, 1, .{ .str = "buzzard" });
    _ = try am.transaction.insert(&doc1, birds, 2, .{ .str = "cormorant" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.delete(&doc1, birds, .{ .index = 1 });
    _ = try am.transaction.delete(&doc2, birds, .{ .index = 1 });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("albatross")},
            &.{scStr("cormorant")},
        } }} },
    } });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .list = &.{
            &.{scStr("albatross")},
            &.{scStr("cormorant")},
        } }} },
    } });
}

// ── 44. concurrent_updates_at_different_levels
//     [`test.rs`:1384-1427](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent updates at different levels" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();

    const animals = try am.transaction.putObject(&doc1, root, .{ .key = "animals" }, .map);
    const birds = try am.transaction.putObject(&doc1, animals, .{ .key = "birds" }, .map);
    _ = try am.transaction.put(&doc1, birds, .{ .key = "pink" }, .{ .str = "flamingo" });
    _ = try am.transaction.put(&doc1, birds, .{ .key = "black" }, .{ .str = "starling" });
    const mammals = try am.transaction.putObject(&doc1, animals, .{ .key = "mammals" }, .list);
    _ = try am.transaction.insert(&doc1, mammals, 0, .{ .str = "badger" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc1, birds, .{ .key = "brown" }, .{ .str = "sparrow" });
    _ = try am.transaction.delete(&doc2, animals, .{ .key = "birds" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }

    const want: Exp = .{ .map = &.{
        .{ .key = "mammals", .values = &.{.{ .list = &.{&.{scStr("badger")}} }} },
    } };
    try expectObj(&doc1, root, .{ .key = "animals" }, want);
    try expectObj(&doc2, root, .{ .key = "animals" }, want);
}

// ── 45. concurrent_updates_of_concurrently_deleted_objects
//     [`test.rs`:1429-1456](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "concurrent updates of concurrently deleted objects" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const birds = try am.transaction.putObject(&doc1, root, .{ .key = "birds" }, .map);
    const blackbird = try am.transaction.putObject(&doc1, birds, .{ .key = "blackbird" }, .map);
    _ = try am.transaction.put(&doc1, blackbird, .{ .key = "feathers" }, .{ .str = "black" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.delete(&doc1, birds, .{ .key = "blackbird" });
    _ = try am.transaction.put(&doc2, blackbird, .{ .key = "beak" }, .{ .str = "orange" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "birds", .values = &.{.{ .map = &.{} }} },
    } });
}

// ── 46. does_not_interleave_sequence_insertions_at_same_position
//     [`test.rs`:1458-1516](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "sequence insertions at the same position do not interleave" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    const wisdom = try am.transaction.putObject(&doc1, root, .{ .key = "wisdom" }, .list);
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    try am.transaction.splice(&doc1, wisdom, 0, 0, gpa, &.{
        .{ .str = "to" },
        .{ .str = "be" },
        .{ .str = "is" },
        .{ .str = "to" },
        .{ .str = "do" },
    });
    try am.transaction.splice(&doc2, wisdom, 0, 0, gpa, &.{
        .{ .str = "to" },
        .{ .str = "do" },
        .{ .str = "is" },
        .{ .str = "to" },
        .{ .str = "be" },
    });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "wisdom", .values = &.{.{ .list = &.{
            &.{scStr("to")},
            &.{scStr("do")},
            &.{scStr("is")},
            &.{scStr("to")},
            &.{scStr("be")},
            &.{scStr("to")},
            &.{scStr("be")},
            &.{scStr("is")},
            &.{scStr("to")},
            &.{scStr("do")},
        } }} },
    } });
}

// ── 47. mutliple_insertions_at_same_list_position_with_insertion_by_greater_actor_id
//     [`test.rs`:1518-1541](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "multiple insertions at the same position by the greater actor id" {
    const actors = sortedActors();
    try testing.expect(actors[1].order(actors[0]) == .gt);
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "two" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc2, list, 0, .{ .str = "one" });
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{ &.{scStr("one")}, &.{scStr("two")} } }} },
    } });
}

// ── 48. mutliple_insertions_at_same_list_position_with_insertion_by_lesser_actor_id
//     [`test.rs`:1543-1566](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "multiple insertions at the same position by the lesser actor id" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    var doc2 = try newDocWithActor(actors[1]);
    defer doc2.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "two" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc2, list, 0, .{ .str = "one" });
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{ &.{scStr("one")}, &.{scStr("two")} } }} },
    } });
}

// ── 49. insertion_consistent_with_causality
//     [`test.rs`:1568-1595](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "insertion consistent with causality" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try newDoc();
    defer doc2.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "four" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc2, list, 0, .{ .str = "three" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "two" });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.insert(&doc2, list, 0, .{ .str = "one" });
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = &.{
            &.{scStr("one")},
            &.{scStr("two")},
            &.{scStr("three")},
            &.{scStr("four")},
        } }} },
    } });
}

// ── 50. save_and_restore_empty
//     [`test.rs`:1597-1603](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "save and restore an empty document" {
    var doc = try newDoc();
    defer doc.deinit();
    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer loaded.deinit();
    try expectDoc(&loaded, .{ .map = &.{} });
}

// ── 51. save_restore_complex1
//     [`test.rs`:1605-1639](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "save and restore a complex document" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    const todos = try am.transaction.putObject(&doc1, root, .{ .key = "todos" }, .list);
    const first_todo = try am.transaction.insertObject(&doc1, todos, 0, .map);
    _ = try am.transaction.put(&doc1, first_todo, .{ .key = "title" }, .{ .str = "water plants" });
    _ = try am.transaction.put(&doc1, first_todo, .{ .key = "done" }, .{ .bool_value = false });

    var doc2 = try newDoc();
    defer doc2.deinit();
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    _ = try am.transaction.put(&doc2, first_todo, .{ .key = "title" }, .{ .str = "weed plants" });
    _ = try am.transaction.put(&doc1, first_todo, .{ .key = "title" }, .{ .str = "kill plants" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    const bytes = try doc1.save(gpa);
    defer gpa.free(bytes);
    var reloaded = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer reloaded.deinit();
    try expectDoc(&reloaded, .{ .map = &.{
        .{ .key = "todos", .values = &.{.{ .list = &.{&.{.{ .map = &.{
            .{ .key = "done", .values = &.{scBool(false)} },
            .{ .key = "title", .values = &.{ scStr("kill plants"), scStr("weed plants") } },
        } }}} }} },
    } });
}

// ── 52. handle_repeated_out_of_order_changes
//     [`test.rs`:1641-1659](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "repeated out of order changes" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "a" });
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();
    _ = try am.transaction.insert(&doc1, list, 1, .{ .str = "b" });
    _ = try am.transaction.insert(&doc1, list, 2, .{ .str = "c" });
    _ = try am.transaction.insert(&doc1, list, 3, .{ .str = "d" });

    var all = try doc1.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    try testing.expectEqual(@as(usize, 5), all.len());
    // The tail twice, then the whole list, which contains the tail again.
    for ([_]usize{ 2, 2, 0 }) |from| {
        const view = try changeViews(&all);
        defer gpa.free(view);
        const tail = try gpa.dupe(Change, view[from..]);
        defer gpa.free(tail);
        _ = try doc2.applyChanges(gpa, tail);
    }
    try doc1.debugCmp(&doc2);
}

// ── 53. save_restore_complex_transactional
//     [`test.rs`:1661-1706](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "save and restore a complex transactional document" {
    var doc1 = try Document.init(gpa, .manual);
    defer doc1.deinit();
    doc1.setActorId(mintActor());
    const first_todo = blk: {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        const todos = try tx.putObject(root, .{ .key = "todos" }, .list);
        const todo = try tx.insertObject(todos, 0, .map);
        _ = try tx.put(todo, .{ .key = "title" }, .{ .str = "water plants" });
        _ = try tx.put(todo, .{ .key = "done" }, .{ .bool_value = false });
        _ = try tx.commit(null, null);
        break :blk todo;
    };

    var doc2 = try Document.init(gpa, .manual);
    defer doc2.deinit();
    doc2.setActorId(mintActor());
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        _ = try tx.put(first_todo, .{ .key = "title" }, .{ .str = "weed plants" });
        _ = try tx.commit(null, null);
    }
    {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        _ = try tx.put(first_todo, .{ .key = "title" }, .{ .str = "kill plants" });
        _ = try tx.commit(null, null);
    }
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    const bytes = try doc1.save(gpa);
    defer gpa.free(bytes);
    var reloaded = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer reloaded.deinit();
    try expectDoc(&reloaded, .{ .map = &.{
        .{ .key = "todos", .values = &.{.{ .list = &.{&.{.{ .map = &.{
            .{ .key = "done", .values = &.{scBool(false)} },
            .{ .key = "title", .values = &.{ scStr("kill plants"), scStr("weed plants") } },
        } }}} }} },
    } });
}

// ── The P5 save round trip: an addition, not an upstream case ────────────────
//
// **What this asserts, and what it deliberately does not.** [`AGENTS.md`](../AGENTS.md)
// declares that `save()` output is **not** byte-identical to the reference,
// because DEFLATE is not reproducible across implementations, and that
// "equivalence is checked by loading and comparing the materialized document".
// That exemption was previously only *stated*. **An exemption nobody checks is
// an exemption that quietly widens**, and this port has already had a
// save-byte comparison applied narrowly once with the decision recorded, so
// the test below pins the boundary from both sides:
//
// * **What is claimed.** A document saved, loaded, and saved again has the
//   **same heads** and **materialises the same document** — compared register
//   by register, element by element, and value by value.
// * **What is not claimed, and must not be added by narrowing.** The two byte
//   strings are **not** compared, and this test must never be "fixed" into
//   comparing them *modulo the compression*: a test that compares everything
//   except the compressed columns is a byte comparison with a hole in it, and
//   the hole is exactly where a column-ordering defect would hide. Upstream
//   writes `assert_eq!(doc1.save(), doc2.save())` three times; the port's three
//   answers are [`Document.debugCmp`](../src/doc.zig), which compares the two
//   **op sets** rather than the two byte strings, and this test is the one that
//   compares the two **materialisations**. None of the three is a byte
//   comparison and none may become one without changing
//   [`AGENTS.md`](../AGENTS.md).
// * **Why the comparison is element by element and not by length or by a
//   shared head count.** A document can share every head and still read
//   differently. **This port has had exactly that defect**: a wrong row order
//   reads back as a different map, because the map reader walks the rows in the
//   order the column holds them and does **not** sort them. A length check
//   passes on that document, and a head check passes on it too, because the
//   changes that produced it are the same changes. So the two assertions here
//   are **separate**: the heads, each one compared; and the materialisation,
//   key by key and index by index.
// * **Why a register's values are compared as a set and not in the order
//   `realizeValues` returned them.** [`realizeValues`] hands a register's
//   values back in the order the column holds them, so a positional zip of the
//   two sides would call two equal registers different exactly when the two
//   documents' row orders differ — the thing under test. Upstream's
//   `realize_values` collects into a `BTreeSet`
//   ([`automerge-test/src/lib.rs`:367-383](../github-automerge-automerge/rust/automerge-test/src/lib.rs)),
//   so each value is rendered with this file's own [`renderNode`] and the two
//   sorted renderings are walked element by element. The rendering is
//   **type-tagged** ([`renderScalar`]), so `Int(1)` and `Uint(1)` do not
//   deduplicate into one value and the comparison does not quietly pass.

test "save, load and save again materialise the same document" {
    var doc1 = try newDoc();
    defer doc1.deinit();

    // A nested map carrying every scalar kind the value column can hold, so
    // that a column written one way and read another shows up as a value.
    const cfg = try am.transaction.putObject(&doc1, root, .{ .key = "cfg" }, .map);
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "int" }, .{ .int = -7 });
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "uint" }, .{ .uint = 7 });
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "bool" }, .{ .bool_value = true });
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "null" }, .null_value);
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "str" }, .{ .str = "héllo, wörld" });
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "bytes" }, .{ .bytes = &.{ 0, 1, 2, 254, 255 } });
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "ts" }, .{ .timestamp = 1_700_000_000 });

    // A counter written by four increments and a decrement, so the **delta**
    // column is what the round trip has to reproduce rather than the value
    // column: a save that wrote the counter's value where a delta belongs reads
    // back as a different number, not as a failure to load.
    _ = try am.transaction.put(&doc1, cfg, .{ .key = "counter" }, .{ .counter = .{ .current = 0 } });
    try am.transaction.increment(&doc1, cfg, .{ .key = "counter" }, 3);
    try am.transaction.increment(&doc1, cfg, .{ .key = "counter" }, -1);
    try am.transaction.increment(&doc1, cfg, .{ .key = "counter" }, 10);

    // Text with non-ASCII, a **deleted** run, a mark and an unmark, because
    // the text columns and the mark columns are written by different encoders
    // and a round trip that loses either reads back as a different string.
    const text = try am.transaction.putObject(&doc1, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc1, text, 0, 0, "hello world");
    try am.transaction.spliceText(&doc1, text, 5, 6, "");
    try am.transaction.spliceText(&doc1, text, 0, 0, "αβγ");
    try am.transaction.mark(&doc1, text, 3, 6, "bold", .after, .{ .bool_value = true });
    try am.transaction.unmark(&doc1, text, 0, 1, .none, "italic", null);

    // A list **long enough to cross the slab boundary several times**, because
    // a one-slab column cannot reproduce a slab-ordering defect. 200 values at
    // `branch_factor` 64 (`src/hexane/btree.zig`) is three leaves at least.
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    for (0..200) |i| {
        _ = try am.transaction.insert(&doc1, list, i, .{ .uint = i });
    }
    // An object **inside** the list, so the reader has to follow an id from the
    // key column into the object column and back.
    const item = try am.transaction.insertObject(&doc1, list, 100, .map);
    _ = try am.transaction.put(&doc1, item, .{ .key = "tag" }, .{ .str = "middle" });
    // And a deleted element, so the round trip has to reproduce a hole rather
    // than only a prefix.
    _ = try am.transaction.delete(&doc1, list, .{ .index = 3 });

    // A **counter at the root**, incremented three times across two different
    // changes, and a register **deleted** afterwards: the deletion leaves the
    // counter's ops in the document with nothing reading them, which is the
    // shape a lost `delete` hides in.
    _ = try am.transaction.put(&doc1, root, .{ .key = "hits" }, .{ .counter = .{ .current = 0 } });
    try am.transaction.increment(&doc1, root, .{ .key = "hits" }, 1);
    try am.transaction.increment(&doc1, root, .{ .key = "hits" }, 2);
    _ = try am.transaction.delete(&doc1, cfg, .{ .key = "null" });
    // **And the whole nested object**, so the round trip has to reproduce a
    // subtree's worth of ops that nothing visible reads any more.
    _ = try am.transaction.delete(&doc1, root, .{ .key = "cfg" });

    // **A second actor**, so the save carries two actors, a **conflict** and a
    // merge. A round trip that loses the actor table renumbers every actor
    // index on the way back, and a conflict is where that is visible.
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();
    _ = try am.transaction.put(&doc2, root, .{ .key = "title" }, .{ .str = "from the fork" });
    _ = try am.transaction.put(&doc1, root, .{ .key = "title" }, .{ .str = "from the original" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }

    const heads_before = try headsOf(&doc1);
    defer gpa.free(heads_before);
    const first_save = try doc1.save(gpa);
    defer gpa.free(first_save);
    var reloaded = try Document.load(gpa, first_save, doc1.textEncoding(), .auto);
    defer reloaded.deinit();
    const second_save = try reloaded.save(gpa);
    defer gpa.free(second_save);

    // **The heads, element by element.** Not a head *count*: two documents can
    // agree on how many heads they have and name different ones.
    const heads_after = try headsOf(&reloaded);
    defer gpa.free(heads_after);
    if (heads_before.len != heads_after.len) {
        std.debug.print("before the round trip the document has {d} head(s), after it {d}\n", .{
            heads_before.len,
            heads_after.len,
        });
        return error.TestExpectedEqual;
    }
    for (heads_before, heads_after, 0..) |a, b, i| {
        if (!a.eql(b)) {
            std.debug.print("head {d} differs across the round trip\n", .{i});
            return error.TestExpectedEqual;
        }
    }

    // **And the materialisation**, register by register and element by element.
    try expectSameDocument(&doc1, &reloaded);
}

/// Two documents' materialisations, compared **element by element**.
///
/// [`realizeRoot`] is the file's own realization of a whole document
/// ([`automerge-test/src/lib.rs`:327-329](../github-automerge-automerge/rust/automerge-test/src/lib.rs))
/// and this walks the two [`Node`] trees it produces rather than rendering
/// either side, so a failure names **where** the two documents parted rather
/// than printing two strings a reader has to diff. The rendering is still what
/// compares a register's values, for the reason [`expectSameRegister`] gives.
fn expectSameDocument(left: *const Document, right: *const Document) !void {
    const a = try realizeRoot(left);
    defer freeNode(gpa, a);
    const b = try realizeRoot(right);
    defer freeNode(gpa, b);
    switch (a) {
        .map => |am_entries| switch (b) {
            .map => |bm_entries| try expectSameMap("<root>", am_entries, bm_entries),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectSameMap(where: []const u8, a: []Entry, b: []Entry) !void {
    // **The key set, both ways.** Walking only the first side's keys would miss
    // a register the second side has and the first does not, which is the shape
    // a lost `put_map` takes on the way back.
    if (a.len != b.len) {
        std.debug.print("{s} has {d} register(s) before the round trip, {d} after\n", .{
            where,
            a.len,
            b.len,
        });
        return error.TestExpectedEqual;
    }
    for (a) |entry| {
        const other = findEntry(b, entry.key) orelse {
            std.debug.print("{s} has no \"{s}\" after the round trip\n", .{ where, entry.key });
            return error.TestExpectedEqual;
        };
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ where, entry.key }) catch where;
        try expectSameRegister(path, entry.values, other.values);
    }
}

/// One register, both sides, **as sets** — which is what upstream compares
/// ([`realize_values`](../github-automerge-automerge/rust/automerge-test/src/lib.rs):367-383 collects into a
/// `BTreeSet`) and what the ordering of a column's rows must not be allowed to
/// change.
///
/// **Each value is compared by its own canonical rendering, element by
/// element.** `realizeValues` hands the values back in the order the column
/// holds them, so a zip of the two sides would call two equal registers
/// different whenever the two documents' row orders differ — which is the very
/// thing being tested.
fn expectSameRegister(where: []const u8, a: []const Node, b: []const Node) !void {
    if (a.len != b.len) {
        std.debug.print("{s} holds {d} value(s) before the round trip, {d} after\n", .{
            where,
            a.len,
            b.len,
        });
        return error.TestExpectedEqual;
    }
    const rendered = try renderBoth(gpa, a, b);
    defer {
        for (rendered.left) |r| gpa.free(r);
        gpa.free(rendered.left);
        for (rendered.right) |r| gpa.free(r);
        gpa.free(rendered.right);
    }
    for (rendered.left, rendered.right, 0..) |x, y, i| {
        if (!std.mem.eql(u8, x, y)) {
            std.debug.print("{s}: value {d} is\n{s}\nafter the round trip, and\n{s}\nbefore it\n", .{
                where,
                i,
                y,
                x,
            });
            return error.TestExpectedEqual;
        }
    }
}

/// Both sides of a register, each value rendered and each list sorted by that
/// rendering, so a pairwise walk is a set comparison.
fn renderBoth(a: Allocator, left: []const Node, right: []const Node) !struct { left: [][]u8, right: [][]u8 } {
    const l = try a.alloc([]u8, left.len);
    errdefer {
        for (l) |r| a.free(r);
        a.free(l);
    }
    for (left, 0..) |v, i| l[i] = try renderNode(a, v);
    const r = try a.alloc([]u8, right.len);
    errdefer {
        for (r) |x| a.free(x);
        a.free(r);
    }
    for (right, 0..) |v, i| r[i] = try renderNode(a, v);
    std.mem.sort([]u8, l, {}, strLess);
    std.mem.sort([]u8, r, {}, strLess);
    return .{ .left = l, .right = r };
}

// ── 54. list_counter_del
//     [`test.rs`:1708-1805](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "list counter and delete" {
    const actors = sortedThreeActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    const list = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list, 0, .{ .str = "a" });
    _ = try am.transaction.insert(&doc1, list, 1, .{ .str = "b" });
    _ = try am.transaction.insert(&doc1, list, 2, .{ .str = "c" });

    const first = try doc1.save(gpa);
    defer gpa.free(first);
    var doc2 = try Document.load(gpa, first, .unicode_code_point, .auto);
    defer doc2.deinit();
    doc2.setActorId(actors[1]);
    var doc3 = try Document.load(gpa, first, .unicode_code_point, .auto);
    defer doc3.deinit();
    doc3.setActorId(actors[2]);

    _ = try am.transaction.put(&doc1, list, .{ .index = 1 }, .{ .counter = .{ .current = 0 } });
    _ = try am.transaction.put(&doc2, list, .{ .index = 1 }, .{ .counter = .{ .current = 10 } });
    _ = try am.transaction.put(&doc3, list, .{ .index = 1 }, .{ .counter = .{ .current = 100 } });
    _ = try am.transaction.put(&doc1, list, .{ .index = 2 }, .{ .counter = .{ .current = 0 } });
    _ = try am.transaction.put(&doc2, list, .{ .index = 2 }, .{ .counter = .{ .current = 10 } });
    _ = try am.transaction.put(&doc3, list, .{ .index = 2 }, .{ .int = 100 });
    try am.transaction.increment(&doc1, list, .{ .index = 1 }, 1);
    try am.transaction.increment(&doc1, list, .{ .index = 2 }, 1);

    for ([_]*Document{ &doc2, &doc3 }) |other| {
        const heads = try doc1.merge(gpa, other);
        gpa.free(heads);
    }

    try expectObj(&doc1, root, .{ .key = "list" }, .{ .list = &.{
        &.{scStr("a")},
        &.{ scCounter(1), scCounter(10), scCounter(100) },
        &.{ scInt(100), scCounter(1), scCounter(10) },
    } });

    try am.transaction.increment(&doc1, list, .{ .index = 1 }, 1);
    try am.transaction.increment(&doc1, list, .{ .index = 2 }, 1);
    try expectObj(&doc1, root, .{ .key = "list" }, .{ .list = &.{
        &.{scStr("a")},
        &.{ scCounter(2), scCounter(11), scCounter(101) },
        &.{ scCounter(2), scCounter(11) },
    } });

    _ = try am.transaction.delete(&doc1, list, .{ .index = 2 });
    try testing.expectEqual(@as(usize, 2), try am.read.length(&doc1, list));
    const saved1 = try doc1.save(gpa);
    defer gpa.free(saved1);
    var doc4 = try Document.load(gpa, saved1, .unicode_code_point, .auto);
    defer doc4.deinit();
    try testing.expectEqual(@as(usize, 2), try am.read.length(&doc4, list));

    _ = try am.transaction.delete(&doc1, list, .{ .index = 1 });
    try testing.expectEqual(@as(usize, 1), try am.read.length(&doc1, list));
    const saved2 = try doc1.save(gpa);
    defer gpa.free(saved2);
    var doc5 = try Document.load(gpa, saved2, .unicode_code_point, .auto);
    defer doc5.deinit();
    try testing.expectEqual(@as(usize, 1), try am.read.length(&doc5, list));
}

// ── 55. observe_counter_change_application
//     [`test.rs`:1807-1817](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "observe counter change application" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "counter" }, .{ .counter = .{ .current = 1 } });
    try am.transaction.increment(&doc, root, .{ .key = "counter" }, 2);
    try am.transaction.increment(&doc, root, .{ .key = "counter" }, 5);
    var changes = try doc.getChanges(gpa, &.{});
    defer changes.deinit(gpa);

    var other = try newDoc();
    defer other.deinit();
    const view = try changeViews(&changes);
    defer gpa.free(view);
    _ = try other.applyChanges(gpa, view);
    try testing.expectEqual(@as(i64, 8), (try scalarAt(&other, root, .{ .key = "counter" })).counter.current);
}

// ── 56. increment_non_counter_map
//     [`test.rs`:1819-1850](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "increment a non-counter map value" {
    var doc = try newDoc();
    defer doc.deinit();
    // Can't increment nothing.
    try testing.expectError(
        error.MissingCounter,
        am.transaction.increment(&doc, root, .{ .key = "nothing" }, 2),
    );
    // Can't increment a non-counter.
    _ = try am.transaction.put(&doc, root, .{ .key = "non-counter" }, .{ .str = "mystring" });
    try testing.expectError(
        error.MissingCounter,
        am.transaction.increment(&doc, root, .{ .key = "non-counter" }, 2),
    );
    // Can increment a counter still.
    _ = try am.transaction.put(&doc, root, .{ .key = "counter" }, .{ .counter = .{ .current = 1 } });
    try am.transaction.increment(&doc, root, .{ .key = "counter" }, 2);
    // And a counter that is part of a conflict.
    var doc1 = try newDoc();
    defer doc1.deinit();
    doc1.setActorId(.{ .bytes = "\x01" });
    var doc2 = try newDoc();
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .counter = .{ .current = 1 } });
    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "mystring" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try am.transaction.increment(&doc1, root, .{ .key = "key" }, 2);
}

// ── 57. increment_non_counter_list
//     [`test.rs`:1852-1881](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "increment a non-counter list value" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .str = "mystring" });
    try testing.expectError(
        error.MissingCounter,
        am.transaction.increment(&doc, list, .{ .index = 0 }, 2),
    );
    _ = try am.transaction.insert(&doc, list, 0, .{ .counter = .{ .current = 1 } });
    try am.transaction.increment(&doc, list, .{ .index = 0 }, 2);

    var doc1 = try newDoc();
    defer doc1.deinit();
    doc1.setActorId(.{ .bytes = "\x01" });
    const list1 = try am.transaction.putObject(&doc1, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc1, list1, 0, .null_value);
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&doc1, list1, .{ .index = 0 }, .{ .counter = .{ .current = 1 } });
    _ = try am.transaction.put(&doc2, list1, .{ .index = 0 }, .{ .str = "mystring" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try am.transaction.increment(&doc1, list1, .{ .index = 0 }, 2);
}

// ── 58. test_local_inc_in_map
//     [`test.rs`:1883-1926](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a local increment in a map" {
    const actors = sortedThreeActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "hello" }, .{ .str = "world" });
    const bytes = try doc1.save(gpa);
    defer gpa.free(bytes);
    var doc2 = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer doc2.deinit();
    doc2.setActorId(actors[1]);
    var doc3 = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer doc3.deinit();
    doc3.setActorId(actors[2]);

    _ = try am.transaction.put(&doc1, root, .{ .key = "cnt" }, .{ .uint = 20 });
    _ = try am.transaction.put(&doc2, root, .{ .key = "cnt" }, .{ .counter = .{ .current = 0 } });
    _ = try am.transaction.put(&doc3, root, .{ .key = "cnt" }, .{ .counter = .{ .current = 10 } });
    for ([_]*Document{ &doc2, &doc3 }) |other| {
        const heads = try doc1.merge(gpa, other);
        gpa.free(heads);
    }
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "cnt", .values = &.{ scUint(20), scCounter(0), scCounter(10) } },
        .{ .key = "hello", .values = &.{scStr("world")} },
    } });
    try am.transaction.increment(&doc1, root, .{ .key = "cnt" }, 5);
    try expectDoc(&doc1, .{ .map = &.{
        .{ .key = "cnt", .values = &.{ scCounter(5), scCounter(15) } },
        .{ .key = "hello", .values = &.{scStr("world")} },
    } });
    const saved = try doc1.save(gpa);
    defer gpa.free(saved);
    var doc4 = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer doc4.deinit();
    const again = try doc4.save(gpa);
    defer gpa.free(again);
    // DEFLATE is not reproducible across implementations ([AGENTS.md](../AGENTS.md)),
    // so upstream's `assert_eq!(doc4.save(), doc1.save())` is a comparison of
    // **materialized documents** here, which is the equivalence the port
    // promises.
    try doc4.debugCmp(&doc1);
}

// ── 59. test_merging_test_conflicts_then_saving_and_loading
//     [`test.rs`:1928-1963](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "merging text conflicts, then saving and loading" {
    const actors = sortedActors();
    var doc1 = try newDocWithActor(actors[0]);
    defer doc1.deinit();
    const text = try am.transaction.putObject(&doc1, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc1, text, 0, 0, "hello");

    const bytes = try doc1.save(gpa);
    defer gpa.free(bytes);
    var doc2 = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer doc2.deinit();
    doc2.setActorId(actors[1]);

    // A text object is five elements under the document's encoding, and the
    // expected literal spells them out one at a time because that is what the
    // upstream `list!` says.
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "text", .values = &.{.{ .list = &.{
            &.{scStr("h")}, &.{scStr("e")}, &.{scStr("l")}, &.{scStr("l")}, &.{scStr("o")},
        } }} },
    } });

    try am.transaction.spliceText(&doc2, text, 4, 1, "");
    try am.transaction.spliceText(&doc2, text, 4, 0, "!");
    try am.transaction.spliceText(&doc2, text, 5, 0, " ");
    try am.transaction.spliceText(&doc2, text, 6, 0, "world");
    const want: Exp = .{ .map = &.{
        .{ .key = "text", .values = &.{.{ .list = &.{
            &.{scStr("h")}, &.{scStr("e")}, &.{scStr("l")}, &.{scStr("l")},
            &.{scStr("!")}, &.{scStr(" ")}, &.{scStr("w")}, &.{scStr("o")},
            &.{scStr("r")}, &.{scStr("l")}, &.{scStr("d")},
        } }} },
    } };
    try expectDoc(&doc2, want);
    const saved = try doc2.save(gpa);
    defer gpa.free(saved);
    var doc3 = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer doc3.deinit();
    try expectDoc(&doc3, want);
}

// ── 60. delete_only_change
//     [`test.rs`:1965-2000](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// Surfaces an error which occurs when loading a document with a change which
// only contains a delete operation. In this case the delete operation doesn't
// appear in the encoded document operations except as a succ, so the max_op was
// calculated incorrectly.

test "a change that only deletes" {
    const actor: ActorId = .{ .bytes = "\x7f" };
    var doc1 = try Document.init(gpa, .manual);
    defer doc1.deinit();
    doc1.setActorId(actor);
    const list = blk: {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        const l = try tx.putObject(root, .{ .key = "list" }, .list);
        _ = try tx.insert(l, 0, .{ .str = "a" });
        _ = try tx.commit(null, null);
        break :blk l;
    };
    const first = try doc1.save(gpa);
    defer gpa.free(first);
    var doc2 = try Document.load(gpa, first, .unicode_code_point, .manual);
    defer doc2.deinit();
    doc2.setActorId(actor);
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        _ = try tx.delete(list, .{ .index = 0 });
        _ = try tx.commit(null, null);
    }
    const second = try doc2.save(gpa);
    defer gpa.free(second);
    var doc3 = try Document.load(gpa, second, .unicode_code_point, .manual);
    defer doc3.deinit();
    doc3.setActorId(actor);
    {
        var tx = try Tx.open(gpa, &doc3);
        defer tx.deinit();
        _ = try tx.insert(list, 0, .{ .str = "b" });
        _ = try tx.commit(null, null);
    }
    const third = try doc3.save(gpa);
    defer gpa.free(third);
    var doc4 = try Document.load(gpa, third, .unicode_code_point, .manual);
    defer doc4.deinit();
    doc4.setActorId(actor);

    var changes = try doc4.getChanges(gpa, &.{});
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), changes.len());
    try testing.expectEqual(@as(u64, 4), changes.at(2).start_op);
}

// ── 61. save_and_reload_create_object
//     [`test.rs`:2002-2028](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "save and reload a create-object change" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    // A change containing an object and no other operations.
    const list = blk: {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const l = try tx.putObject(root, .{ .key = "foo" }, .list);
        _ = try tx.commit(null, null);
        break :blk l;
    };
    const first = try doc.save(gpa);
    defer gpa.free(first);
    var doc2 = try Document.load(gpa, first, .unicode_code_point, .manual);
    defer doc2.deinit();
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        _ = try tx.insert(list, 0, .{ .uint = 1 });
        _ = try tx.commit(null, null);
    }
    try expectDoc(&doc2, .{ .map = &.{
        .{ .key = "foo", .values = &.{.{ .list = &.{&.{scUint(1)}} }} },
    } });
    const second = try doc2.save(gpa);
    defer gpa.free(second);
    var doc3 = try Document.load(gpa, second, .unicode_code_point, .auto);
    defer doc3.deinit();
}

// ── 62. test_compressed_changes
//     [`test.rs`:2030-2044](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// **Not ported.** The test is about *change-chunk* compression: it puts 300
// bytes, takes `change.bytes()` (the deflated chunk) and `change.raw_bytes()`
// (the body), and asserts the deflated one is smaller and that
// `Change::try_from(bytes)` recovers the body. The port's
// [`change_record.Change`](../src/change.zig) has `bytes` — the body the hash
// was taken over — and `Change.encode` writes the framed chunk, but **no deflated
// change chunk exists**: [`Document.getChanges`](../src/doc.zig) collects
// uncompressed bodies, and the only deflate the port writes is a document
// column ([`storage/document_chunk.zig`](../src/storage/document_chunk.zig)).

// ── 63. test_compressed_doc_cols
//     [`test.rs`:2046-2068](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "compressed document columns" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    // One allocation per register, and **an owner list**, because each element
    // of the expected list is a `[]const Exp` the literal has to outlive the
    // assertion that reads it.
    var expected: std.ArrayList([]const Exp) = .empty;
    defer {
        for (expected.items) |one| gpa.free(one);
        expected.deinit(gpa);
    }
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try am.transaction.insert(&doc, list, i, .{ .uint = i });
        const one = try gpa.alloc(Exp, 1);
        one[0] = scUint(i);
        expected.append(gpa, one) catch |e| {
            gpa.free(one);
            return e;
        };
    }
    const uncompressed = try doc.saveWithOptions(gpa, .{ .deflate = false });
    defer gpa.free(uncompressed);
    const compressed = try doc.save(gpa);
    defer gpa.free(compressed);
    try testing.expect(compressed.len < uncompressed.len);
    var loaded = try Document.load(gpa, compressed, .unicode_code_point, .auto);
    defer loaded.deinit();
    try expectDoc(&loaded, .{ .map = &.{
        .{ .key = "list", .values = &.{.{ .list = expected.items }} },
    } });
}

// ── 64. test_change_encoding_expanded_change_round_trip
//     [`test.rs`:2070-2095](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a change parses to the bytes it was written as" {
    // The change chunk upstream builds byte for byte, so the reader is pinned to
    // bytes the reference wrote.
    const change_bytes = [_]u8{
        0x85, 0x6f, 0x4a, 0x83, // magic bytes
        0xb2, 0x98, 0x9e, 0xa9, // checksum
        1, 61, 0, 2, 0x12, 0x34, // chunkType: change, length, deps, actor '1234'
        1, 1, 252, 250, 220, 255, 5, // seq, startOp, time
        14, 73, 110, 105, 116, 105, 97, 108, 105, 122, 97, 116, 105, 111, 110, // message: 'Initialization'
        0, 6, // actor list, column count
        0x15, 3, 0x34, 1, 0x42, 2, // keyStr, insert, action
        0x56, 2, 0x57, 1, 0x70, 2, // valLen, valRaw, predNum
        0x7f, 1, 0x78, // keyStr: 'x'
        1, // insert: false
        0x7f, 1, // action: set
        0x7f, 19, // valLen: 1 byte of type uint
        1, // valRaw: 1
        0x7f, 0, // predNum: 0
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, // 10 trailing bytes
    };
    var change = try am.change_record.parseChange(change_bytes[10..], gpa);
    defer change.deinit(gpa);
    try testing.expectEqualSlices(u8, change_bytes[10..], change.bytes);

    // **The `ExpandedChange` half of upstream's test is a gap.** The port has
    // no `ExpandedChange` and no serde: [`change_record.Change`](../src/change.zig)
    // is the encoded form and `Document.collectChanges` is the only other view
    // of a change's operations, and it walks an op set rather than a decoded
    // change. So "decode to a structured change, re-encode, get the same bytes"
    // has no consumer-shaped spelling, and only the parse half is ported.
}

// ── 65. save_and_load_incremented_counter
//     [`test.rs`:2097-2115](../github-automerge-automerge/rust/automerge/tests/test.rs)
//
// **Not ported: it is a serde round trip.** The test writes a document, turns
// its changes into JSON with `serde_json::to_string(&c.decode())`, reads them
// back with `serde_json::from_str::<ExpandedChange>`, and asserts the two
// change lists are equal. There is no `ExpandedChange` (see test 64) and no
// serde in the port.

// ── 66. load_incremental_with_corrupted_tail
//     [`test.rs`:2117-2134](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "load_incremental with a corrupted tail" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "key" }, .{ .str = "value" });
    const clean = try doc.save(gpa);
    defer gpa.free(clean);
    const bytes = try gpa.alloc(u8, clean.len + 4);
    defer gpa.free(bytes);
    @memcpy(bytes[0..clean.len], clean);
    @memcpy(bytes[clean.len..], &[_]u8{ 1, 2, 3, 4 });

    var loaded = try Document.init(gpa, .auto);
    defer loaded.deinit();
    // Upstream asserts `assert_eq!(loaded_len, 1)` ([`test.rs`:2127](../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // and the port's answer is the same number for the same reason: the empty
    // document's `load_incremental` branch returns `self.ops.len()`
    // ([`automerge.rs`:1051](../github-automerge-automerge/rust/automerge/src/automerge.rs)), and the save holds exactly
    // one operation — the `put` above.
    //
    // **`1`, not `> 0`.** The four trailing bytes are the whole of the test:
    // they are what makes `parseChunksPartial` return `err = InvalidMagic`
    // (`chunk.zig`, over `load_changes`'s `LoadedChanges::Partial`,
    // [`storage/load.rs`:87-92](../github-automerge-automerge/rust/automerge/src/storage/load.rs)), and the
    // assertion that says so is that the document behind it is the *whole*
    // one. A `> 0` passes on a load that recovered nothing.
    const loaded_len = try loaded.loadIncremental(gpa, bytes);
    try testing.expectEqual(@as(usize, 1), loaded_len);
    try expectDoc(&loaded, .{ .map = &.{.{ .key = "key", .values = &.{scStr("value")} }} });
}

// ── 67. load_doc_with_deleted_objects
//     [`test.rs`:2136-2150](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "load a document with deleted objects" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    _ = try am.transaction.putObject(&doc, root, .{ .key = "map" }, .map);
    _ = try am.transaction.putObject(&doc, root, .{ .key = "table" }, .table);
    for ([_][]const u8{ "list", "text", "map", "table" }) |key| {
        _ = try am.transaction.delete(&doc, root, .{ .key = key });
    }
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();
    try expectDoc(&loaded, .{ .map = &.{} });
}

// ── 68. insert_after_many_deletes
//     [`test.rs`:2152-2160](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "insert after many deletes" {
    var doc = try newDoc();
    defer doc.deinit();
    const obj = try am.transaction.putObject(&doc, root, .{ .key = "object" }, .map);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{d}", .{i});
        _ = try am.transaction.put(&doc, obj, .{ .key = key }, .{ .int = @intCast(i) });
        _ = try am.transaction.delete(&doc, obj, .{ .key = key });
    }
}

// ── 69. simple_bad_saveload
//     [`test.rs`:2162-2181](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a simple bad save and load" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "count" }, .{ .int = 0 });
        _ = try tx.commit(null, null);
    }
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.commit(null, null);
    }
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "count" }, .{ .int = 0 });
        _ = try tx.commit(null, null);
    }
    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    var loaded = try Document.load(gpa, bytes, .unicode_code_point, .auto);
    defer loaded.deinit();
}

// ── 70. ops_on_wrong_objets
//     [`test.rs`:2183-2207](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "operations on the wrong object types" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .str = "a" });
    _ = try am.transaction.insert(&doc, list, 1, .{ .str = "b" });
    try testing.expectError(
        error.InvalidOp,
        am.transaction.put(&doc, list, .{ .key = "a" }, .{ .str = "AAA" }),
    );
    try testing.expectError(
        error.InvalidOp,
        am.transaction.spliceText(&doc, list, 0, 0, "hello world"),
    );
    const map = try am.transaction.putObject(&doc, root, .{ .key = "map" }, .map);
    _ = try am.transaction.put(&doc, map, .{ .key = "a" }, .{ .str = "AAA" });
    _ = try am.transaction.put(&doc, map, .{ .key = "b" }, .{ .str = "BBB" });
    try testing.expectError(
        error.InvalidOp,
        am.transaction.insert(&doc, map, 0, .{ .str = "b" }),
    );
    try testing.expectError(
        error.InvalidOp,
        am.transaction.spliceText(&doc, map, 0, 0, "hello world"),
    );
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "hello world");
    try testing.expectError(
        error.InvalidOp,
        am.transaction.put(&doc, text, .{ .key = "a" }, .{ .str = "AAA" }),
    );
}

// ── 71. negative_64
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2249-2253

test "a negative 64-bit value" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    _ = try tx.put(root, .{ .key = "a" }, .{ .int = -64 });
    _ = try tx.commit(null, null);
}

// ── 72. bad_change_on_optree_node_boundary
//     [`test.rs`:2271-2306](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "a bad change on an op-tree node boundary" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .str = "z" });
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = 0 });
        _ = try tx.put(root, .{ .key = "c" }, .{ .int = 0 });
        _ = try tx.commit(null, null);
    }
    const iterations: u64 = 15;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        var buf: [64]u8 = undefined;
        @memset(&buf, 'a');
        const s = buf[0..@as(usize, @intCast(i))];
        _ = try tx.put(root, .{ .key = "a" }, .{ .str = s });
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = @intCast(i + 1) });
        _ = try tx.put(root, .{ .key = "c" }, .{ .int = @intCast(i + 1) });
        _ = try tx.commit(null, null);
    }
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var doc2 = try Document.load(gpa, saved, .unicode_code_point, .manual);
    defer doc2.deinit();
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const n = iterations + 2;
        var buf: [64]u8 = undefined;
        @memset(&buf, 'a');
        const s = buf[0..@as(usize, @intCast(n))];
        _ = try tx.put(root, .{ .key = "a" }, .{ .str = s });
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = @intCast(n) });
        _ = try tx.put(root, .{ .key = "c" }, .{ .int = @intCast(n) });
        _ = try tx.commit(null, null);
    }
    const doc2_heads = try doc2.getHeads(gpa);
    defer gpa.free(doc2_heads);
    var changes = try doc.getChanges(gpa, doc2_heads);
    defer changes.deinit(gpa);
    const view = try changeViews(&changes);
    defer gpa.free(view);
    _ = try doc2.applyChanges(gpa, view);
    const saved2 = try doc2.save(gpa);
    defer gpa.free(saved2);
    var doc3 = try Document.load(gpa, saved2, .unicode_code_point, .auto);
    defer doc3.deinit();
}

// ── 73. regression_nth_miscount
//     [`test.rs`:2308-2335](../github-automerge-automerge/rust/automerge/tests/test.rs)

test "regression: nth miscount" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const list_id = try tx.putObject(root, .{ .key = "listval" }, .list);
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            _ = try tx.insert(list_id, i, .null_value);
            const map = try tx.putObject(list_id, .{ .index = i }, .map);
            _ = try tx.put(map, .{ .key = "test" }, .{ .int = @intCast(i) });
        }
        _ = try tx.commit(null, null);
    }
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const list_id = try objectAt(&doc, root, .{ .key = "listval" });
        try testing.expectEqual(ObjType.list, try am.read.objectType(&doc, list_id));
        const map_id = try objectAt(&doc, list_id, .{ .index = i });
        try testing.expectEqual(ObjType.map, try am.read.objectType(&doc, map_id));
        try testing.expectEqual(
            @as(i64, @intCast(i)),
            (try scalarAt(&doc, map_id, .{ .key = "test" })).int,
        );
    }
}

// ── 74. regression_nth_miscount_smaller
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2337-2361
//
// Upstream's own `const B: usize = 16` (`test.rs`:11) is spelled out as the
// literal it is, because the ported file has no reason to carry the alias.

test "regression: nth miscount, smaller" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const list_id = try tx.putObject(root, .{ .key = "listval" }, .list);
        var i: usize = 0;
        while (i < 16 * 4) : (i += 1) {
            _ = try tx.insert(list_id, i, .null_value);
            _ = try tx.put(list_id, .{ .index = i }, .{ .int = @intCast(i) });
        }
        _ = try tx.commit(null, null);
    }
    var i: usize = 0;
    while (i < 16 * 4) : (i += 1) {
        const list_id = try objectAt(&doc, root, .{ .key = "listval" });
        try testing.expectEqual(ObjType.list, try am.read.objectType(&doc, list_id));
        try testing.expectEqual(
            @as(i64, @intCast(i)),
            (try scalarAt(&doc, list_id, .{ .index = i })).int,
        );
    }
}

// ── 75. marks
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2476-2504

test "marks" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    const text_id = try tx.putObject(root, .{ .key = "text" }, .text);
    try tx.spliceText(text_id, 0, 0, "hello world");
    try tx.mark(text_id, 0, 5, "bold", .both, .{ .bool_value = true });
    // " cool", which is bold because `ExpandMark::Both`.
    try tx.spliceText(text_id, 5, 0, " cool");
    // Unbold "hello".
    try tx.unmark(text_id, 0, 5, .before, "bold", null);
    // "why " before "hello".
    try tx.spliceText(text_id, 0, 0, "why ");

    const found = try doc.marks(gpa, text_id);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(@as(usize, 9), found[0].start);
    try testing.expectEqual(@as(usize, 14), found[0].end);
    try testing.expectEqualStrings("bold", found[0].name);
    try testing.expectEqual(ScalarValue{ .bool_value = true }, found[0].value);
}

// ── 76. can_transaction_at
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2506-2546

test "a transaction can be opened at historical heads" {
    var doc1 = try Document.init(gpa, .manual);
    defer doc1.deinit();
    doc1.setActorId(mintActor());
    const txt = blk: {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        const t = try tx.putObject(root, .{ .key = "text" }, .text);
        _ = try tx.put(root, .{ .key = "size" }, .{ .int = 100 });
        try tx.spliceText(t, 0, 0, "aaabbbccc");
        _ = try tx.commit(null, null);
        break :blk t;
    };
    const heads1 = try headsOf(&doc1);
    defer gpa.free(heads1);
    {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        try testing.expectEqualStrings("aaabbbccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 100), (try scalarIn(&tx, .{ .key = "size" })).int);
        try tx.spliceText(txt, 3, 3, "QQQ");
        _ = try tx.put(root, .{ .key = "size" }, .{ .int = 200 });
        try testing.expectEqualStrings("aaaQQQccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 200), (try scalarIn(&tx, .{ .key = "size" })).int);
        _ = try tx.commit(null, null);
    }
    {
        var tx = try Tx.openAt(gpa, &doc1, heads1);
        defer tx.deinit();
        try testing.expectEqualStrings("aaabbbccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 100), (try scalarIn(&tx, .{ .key = "size" })).int);
        try tx.spliceText(txt, 3, 3, "ZZZ");
        _ = try tx.put(root, .{ .key = "size" }, .{ .int = 300 });
        try testing.expectEqualStrings("aaaZZZccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 300), (try scalarIn(&tx, .{ .key = "size" })).int);
        _ = try tx.commit(null, null);
    }
    // `test.rs:2532` — a **document** read, so [`scalarAt`] and [`expectText`]
    // and not the transaction pair. `am.read.text` hands back a caller-owned
    // string, which is what [`expectText`] exists to free.
    try expectText(&doc1, txt, "aaaZZZQQQccc");
    try testing.expectEqual(@as(i64, 300), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    {
        var tx = try Tx.openAt(gpa, &doc1, heads1);
        defer tx.deinit();
        // **The two reads below fail, and not because of the read.** They are
        // upstream's [`test.rs`:2536-2537](../github-automerge-automerge/rust/automerge/tests/test.rs)
        // and they want the state at `heads1`; this transaction reads the state
        // *after* the previous transaction instead. The read is scoped and the
        // scope is right for what it is given: `Transaction.textFor` is
        // `doc.ops.text(.., try self.scopeClock())`
        // ([`transact.zig`:1532-1538](../src/transact.zig)) and `scopeClock` is
        // `clockAt(heads)` with `Clock.isolate(self.actor)` on top
        // ([`:517-543`](../src/transact.zig)).
        //
        // **Measured, not inferred.** The fourth transaction is handed
        // **actor 1** — the same fork the third one used — where upstream's
        // `isolate_actor` walk ([`automerge.rs`:1259-1281](../github-automerge-automerge/rust/automerge/src/automerge.rs))
        // would fork to level 2, because by then `max_op_for_actor(1)` is
        // non-zero and the clock at `heads1` does not cover it. The port's
        // [`Document.isolatedActorIndex`](doc.zig) implements that walk
        // correctly; it is handed the wrong actor. After the third
        // transaction the change graph holds three nodes and reports
        // `seq = 3, maxOp = 25` for actor **0** and `seq = 0, maxOp = 0` for
        // actor **1**: the isolated change was committed under the document's
        // own actor. The rows it wrote carry actor 1.
        //
        // **Why the change lands on the base actor.**
        // [`Document.commit`](doc.zig) opens with
        // `var args = try self.transactionArgs(gpa, self.isolation)` and
        // `self.isolation` is null here — this test opens the scope with
        // `Transaction.openAt`, not with `Document.isolate` — so the
        // re-derivation takes the *unscoped* arm and names the document's own
        // actor. Upstream never re-derives at commit:
        // `TransactionInner::commit_impl` is handed its own `actor`, `seq` and
        // `start_op` ([`inner.rs`:146-172, :174-189](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
        // and `AutoCommit` builds the isolation once, at
        // `ensure_transaction_open` ([`autocommit.rs`:445-457](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
        // before any op is written.
        //
        // **The consequence is the mark, not the walk.** The fourth
        // transaction's actor is 1 again, so `Clock.isolate(1)` sets slot 1 to
        // `maxInt` ([`clock.zig`:128-131](../src/clock.zig)) — "everything
        // actor 1 has ever done" — and actor 1's slot now *holds* the `ZZZ`
        // ops, because those rows carry actor 1. The scope is exactly one
        // change too new, which is also why the last assertion of this test
        // fails: the third change claims to descend from the second and
        // overrides `ZZZ` rather than running concurrent with it.
        //
        // **So this test is red on `Document.commit` re-deriving what the
        // transaction already knows, and not in either read.** The reads are
        // exercised where the scope is right: the four `scalarIn` assertions
        // above, of which [`test.rs`:2526, :2530](../github-automerge-automerge/rust/automerge/tests/test.rs)
        // are the two `scopeClock` was added for.
        try testing.expectEqualStrings("aaabbbccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 100), (try scalarIn(&tx, .{ .key = "size" })).int);
        try tx.spliceText(txt, 3, 3, "TTT");
        _ = try tx.put(root, .{ .key = "size" }, .{ .int = 400 });
        // [`test.rs`:2539](../github-automerge-automerge/rust/automerge/tests/test.rs)
        // and [`:2541`](../github-automerge-automerge/rust/automerge/tests/test.rs):
        // the text, then the value the same transaction wrote.
        try testing.expectEqualStrings("aaaTTTccc", try tx.textFor(txt));
        try testing.expectEqual(@as(i64, 400), (try scalarIn(&tx, .{ .key = "size" })).int);
        _ = try tx.commit(null, null);
    }
    const final_text = try am.read.text(&doc1, txt, gpa);
    defer gpa.free(final_text);
    try testing.expectEqualStrings("aaaTTTZZZQQQccc", final_text);
    try testing.expectEqual(@as(i64, 400), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
}

// ── 77. can_isolate
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2548-2616

test "a document can be isolated and integrated" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    const txt = try am.transaction.putObject(&doc1, root, .{ .key = "text" }, .text);
    _ = try am.transaction.put(&doc1, root, .{ .key = "size" }, .{ .int = 100 });
    try am.transaction.spliceText(&doc1, txt, 0, 0, "aaabbbccc");
    const heads1 = try headsOf(&doc1);
    defer gpa.free(heads1);
    _ = try am.transaction.put(&doc1, root, .{ .key = "size" }, .{ .int = 150 });

    try doc1.isolate(gpa, heads1);
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();
    _ = try am.transaction.put(&doc2, root, .{ .key = "other" }, .{ .int = 999 });
    try am.transaction.spliceText(&doc2, txt, 9, 0, "111");

    try expectText(&doc1, txt, "aaabbbccc");
    try testing.expectEqual(@as(i64, 100), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    try am.transaction.spliceText(&doc1, txt, 3, 3, "QQQ");
    _ = try am.transaction.put(&doc1, root, .{ .key = "size" }, .{ .int = 200 });
    try expectText(&doc1, txt, "aaaQQQccc");
    try testing.expectEqual(@as(i64, 200), (try scalarAt(&doc1, root, .{ .key = "size" })).int);

    const heads2 = try headsOf(&doc1);
    defer gpa.free(heads2);
    try testing.expect(!std.mem.eql(u8, &heads1[0].bytes, &heads2[0].bytes));
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    try testing.expectEqual(@as(i64, 200), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    try testing.expect((try am.read.get(&doc1, root, .{ .key = "other" })) == null);

    try doc1.isolate(gpa, heads1);
    try expectText(&doc1, txt, "aaabbbccc");
    try testing.expectEqual(@as(i64, 100), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    try am.transaction.spliceText(&doc1, txt, 3, 3, "ZZZ");
    _ = try am.transaction.put(&doc1, root, .{ .key = "size" }, .{ .int = 300 });
    try expectText(&doc1, txt, "aaaZZZccc");
    try testing.expectEqual(@as(i64, 300), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    const heads3 = try headsOf(&doc1);
    defer gpa.free(heads3);
    try expectText(&doc1, txt, "aaaZZZccc");

    try doc1.integrate();
    try expectText(&doc1, txt, "aaaZZZQQQccc111");
    try testing.expectEqual(@as(i64, 999), (try scalarAt(&doc1, root, .{ .key = "other" })).int);

    try doc1.isolate(gpa, heads1);
    try am.transaction.spliceText(&doc1, txt, 3, 3, "TTT");
    _ = try am.transaction.put(&doc1, root, .{ .key = "size" }, .{ .int = 400 });
    try expectText(&doc1, txt, "aaaTTTccc");
    try testing.expectEqual(@as(i64, 400), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
    const heads4 = try headsOf(&doc1);
    defer gpa.free(heads4);
    try doc1.integrate();
    try expectText(&doc1, txt, "aaaTTTZZZQQQccc111");
    try testing.expectEqual(@as(i64, 400), (try scalarAt(&doc1, root, .{ .key = "size" })).int);
}

// ── 78. inserting_text_near_deleted_marks
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2618-2635

test "inserting text near deleted marks" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    const text_id = try tx.putObject(root, .{ .key = "text" }, .text);
    try tx.spliceText(text_id, 0, 0, "hello world");
    try tx.mark(text_id, 2, 8, "bold", .after, .{ .bool_value = true });
    try tx.mark(text_id, 3, 6, "link", .none, .{ .bool_value = true });
    try tx.spliceText(text_id, 1, 10, ""); // remove the 'h'
    try tx.spliceText(text_id, 0, 0, "a"); // 'ah'
    try tx.spliceText(text_id, 2, 0, "a"); // 'ah<bold>a</bold>'

    // Upstream's test ends in `dbg!`, which asserts nothing. **The text is
    // asserted here instead**, because it is the observable the sequence was
    // written to produce and a "does not panic" test proves nothing
    // ([AGENTS.md](../AGENTS.md)). "hello world" is eleven characters; deleting
    // ten from index one leaves "h", and the two inserts make "ah" and then
    // "aha" — which is what upstream's three `//` comments say.
    try testing.expectEqualStrings("aha", try tx.textFor(text_id));
    // **The marks are the property, and the text on its own does not pin it.**
    // The reference's own `dbg!` at [`test.rs`:2634](../github-automerge-automerge/rust/automerge/tests/test.rs)
    // prints `bold[2,3)` for this splice, and it is bold because the new row
    // lands *inside* the mark — between the link end and the bold end of the
    // op set, which is what [`OpSet.scanForStickyMarks`](../src/opset/op_set.zig)
    // exists to find.
    //
    // **A row placed one position earlier leaves both assertions looking
    // right.** "aha" does not say where the row went, and the mark list read
    // over the whole sequence would not say it either, so the only thing that
    // distinguishes them is the mark set at the index the row went to. Today
    // [`OpSet.queryInsertAt`]'s fast-versus-slow cross-check
    // ([`op_set.rs`:584-596](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
    // is what catches it; this assertion is what would still catch it if that
    // check were ever removed. `tx.markSetAtIndex` is upstream's
    // `tx.marks` narrowed to one index
    // ([`transact.zig`:1495-1516](../src/transact.zig)), and `null` heads is
    // the transaction's own scope, which is where the pending row lives.
    var at_two = try tx.markSetAtIndex(text_id, 2, null, gpa);
    defer at_two.deinit();
    try testing.expectEqual(@as(usize, 1), at_two.len());
    try testing.expectEqualStrings("bold", at_two.entries.items[0].name);
    try testing.expectEqual(ScalarValue{ .bool_value = true }, at_two.entries.items[0].value);
}

// ── 79. test_load_incremental_partial_load
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2637-2659

test "load_incremental with a partial load" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .int = 1 });
        _ = try tx.commit(null, null);
    }
    const start_heads = try headsOf(&doc);
    defer gpa.free(start_heads);
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = 2 });
        _ = try tx.commit(null, null);
    }
    var changes = try doc.getChanges(gpa, start_heads);
    defer changes.deinit(gpa);
    const view = try changeViews(&changes);
    defer gpa.free(view);
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    for (view) |change| try am.storage.chunk.writeChunk(&framed, gpa, .change, change.bytes);

    var doc2 = try Document.init(gpa, .manual);
    defer doc2.deinit();
    _ = try doc2.loadIncremental(gpa, framed.items);
}

// ── 80. test_get_change_meta
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2661-2679

test "get_changes metadata" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .int = 1 });
        _ = try tx.commit(null, null);
    }
    const start_heads = try headsOf(&doc);
    defer gpa.free(start_heads);
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = 2 });
        _ = try tx.commit(null, null);
    }
    var changes = try doc.getChanges(gpa, start_heads);
    defer changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), changes.len());
    try testing.expect(doc.getActorId().eql(changes.at(0).actor));
    try testing.expectEqual(@as(u64, 2), changes.at(0).seq);
}

// ── 81. get_marks_at_heads
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2681-2713

test "get marks at historical heads" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    const text_id = blk: {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const t = try tx.putObject(root, .{ .key = "text" }, .text);
        try tx.spliceText(t, 0, 0, "hello world");
        try tx.mark(t, 0, 10, "bold", .after, .{ .bool_value = true });
        _ = try tx.commit(null, null);
        break :blk t;
    };
    const heads = try headsOf(&doc);
    defer gpa.free(heads);

    // **The present before the un-mark, which is the port's own read and not
    // one of upstream's two.** Upstream reads nothing but `heads` in this test
    // ([`test.rs`:2700, :2708](../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // and this one is here to say what the historical reads below are
    // different *from*. **`null` heads and not `heads`**: `get_scope(None)` is
    // the unscoped read
    // ([`autocommit.rs`:794-814](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // and on a text object with no clock it is the **indexed** arm —
    // `clock.is_none() && obj.typ == Text`
    // ([`automerge.rs`:1937](../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    const want_bold = [_]am.marks.MarkSet.Entry{.{ .name = "bold", .value = .{ .bool_value = true } }};
    {
        var before = try am.read.markSetAtIndex(&doc, text_id, 1, null, gpa);
        defer before.deinit();
        try expectMarkSet(&before, &want_bold);
    }

    try doc.updateDiffCursor();
    {
        // **The un-mark is pending here**, which is upstream's shape
        // ([`test.rs`:2693-2699](../github-automerge-automerge/rust/automerge/tests/test.rs)):
        // the operation that changes the answer is not in any change yet, which
        // is exactly why a read at those heads can still see the old mark.
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        // The mark is set to null, which is a change and not an absence.
        try tx.mark(text_id, 0, 10, "bold", .none, .null_value);

        // **`tx.get_marks(&text_id, 1, Some(&heads))`**
        // ([`test.rs`:2700](../github-automerge-automerge/rust/automerge/tests/test.rs)).
        // Through the transaction, so the scope is `get_scope(Some(h))` =
        // `clock_at(h)` ([`manual_transaction.rs`:113-122](../github-automerge-automerge/rust/automerge/src/transaction/manual_transaction.rs)),
        // and the un-mark is in the op set but in no clock at those heads.
        var through_tx = try tx.markSetAtIndex(text_id, 1, heads, gpa);
        defer through_tx.deinit();
        try expectMarkSet(&through_tx, &want_bold);

        _ = try tx.commit(null, null);
    }
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    var saw_mark = false;
    for (patches.slice()) |p| {
        if (p.action == .mark) {
            for (p.action.mark.marks) |m| {
                if (std.mem.eql(u8, m.name, "bold")) saw_mark = true;
            }
        }
    }
    try testing.expect(saw_mark);

    // **And the mark is gone from the present**, which is what the null value
    // means ([`marks.zig`](../src/marks.zig): `MarkStateMachine.markEnd`) — and
    // this is the read that makes the next one mean something.
    {
        var after = try am.read.markSetAtIndex(&doc, text_id, 1, null, gpa);
        defer after.deinit();
        try testing.expectEqual(@as(usize, 0), after.len());
    }

    // **`doc.get_marks(&text_id, 1, Some(&heads))`**
    // ([`test.rs`:2708](../github-automerge-automerge/rust/automerge/tests/test.rs)),
    // **after the commit** — the same historical read through the document,
    // where the scope is the *document's* `get_scope(Some(h))` and not a
    // transaction's. The clock is not null, so this is the **walk** arm and
    // not the mark index's, which is the second of
    // [`read.markSetAtScope`](../src/read.zig)'s two.
    {
        var at_heads = try am.read.markSetAtIndex(&doc, text_id, 1, heads, gpa);
        defer at_heads.deinit();
        try expectMarkSet(&at_heads, &want_bold);
    }
}

// ── 82. rollback_with_no_ops
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2746-2772

test "rollback with no ops" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .int = 1 });
        _ = try tx.commit(null, null);
    }
    var doc2 = try forkDocMode(&doc, .manual);
    defer doc2.deinit();
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        _ = try tx.commit(null, null);
    }
    var doc3 = try forkDocMode(&doc, .manual);
    defer doc3.deinit();
    {
        var tx = try Tx.open(gpa, &doc3);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "b" }, .{ .int = 2 });
        _ = try tx.commit(null, null);
    }
    {
        const heads = try doc2.merge(gpa, &doc3);
        gpa.free(heads);
    }
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        _ = try tx.rollback();
    }
}

// ── 83. rollback_with_several_actors
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2774-2801

test "rollback with several actors" {
    // **The port's autocommit door commits every mutating call**, where
    // upstream's `AutoCommit` keeps **one** transaction open until something
    // closes it ([`autocommit.rs`:445-462](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    // `ensure_transaction_open` / `ensure_transaction_closed`). `doc3.rollback()`
    // in upstream therefore undoes the five writes that precede it, and the
    // whole point of this test is that it can. Through the port's `.auto` door
    // those five writes are five committed changes and no rollback reaches them,
    // so the sequence is written against the **manual** door, which is upstream's
    // `Transaction::rollback` reached through `AutoCommit::transaction()`.
    var doc1 = try Document.init(gpa, .manual);
    defer doc1.deinit();
    doc1.setActorId(.{ .bytes = "aaaaaa" });
    const text = blk: {
        var tx = try Tx.open(gpa, &doc1);
        defer tx.deinit();
        const t = try tx.putObject(root, .{ .key = "text" }, .text);
        try tx.spliceText(t, 0, 0, "the sly fox jumped over the lazy dog");
        const map_a = try tx.putObject(root, .{ .key = "map_a" }, .map);
        _ = try tx.put(map_a, .{ .key = "key1" }, .{ .str = "value1a" });
        _ = try tx.put(map_a, .{ .key = "key2" }, .{ .str = "value2a" });
        _ = try tx.commit(null, null);
        break :blk t;
    };
    const map_a = try objectAt(&doc1, root, .{ .key = "map_a" });

    var doc2 = try forkDocMode(&doc1, .manual);
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = "cccccc" });
    {
        var tx = try Tx.open(gpa, &doc2);
        defer tx.deinit();
        try tx.spliceText(text, 8, 3, "monkey");
        try tx.spliceText(text, 36, 3, "pig");
        const map_c = try tx.putObject(root, .{ .key = "map_c" }, .map);
        _ = try tx.put(map_a, .{ .key = "key2" }, .{ .str = "value2c" });
        _ = try tx.put(map_a, .{ .key = "key3" }, .{ .str = "value3c" });
        _ = try tx.put(map_c, .{ .key = "key1" }, .{ .str = "value" });
        _ = try tx.commit(null, null);
    }

    var doc3 = try forkDocMode(&doc2, .manual);
    defer doc3.deinit();
    doc3.setActorId(.{ .bytes = "bbbbbb" });
    {
        var tx = try Tx.open(gpa, &doc3);
        defer tx.deinit();
        try tx.spliceText(text, 8, 5, "zebra");
        const map_b = try tx.putObject(root, .{ .key = "map_b" }, .map);
        _ = try tx.put(map_a, .{ .key = "key1" }, .{ .str = "value3b" });
        _ = try tx.put(map_a, .{ .key = "key3" }, .{ .str = "value3b" });
        _ = try tx.put(map_b, .{ .key = "key1" }, .{ .str = "value" });
        _ = try tx.rollback();
    }

    // The rollback put `doc3` back to `doc2`'s state, which is what
    // `assert_eq!(doc3.save(), doc2.save())` says modulo DEFLATE.
    try doc3.debugCmp(&doc2);
}

// ── 84. save_with_ops_which_reference_actors_only_via_delete
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2803-2832

test "save with ops which reference actors only via delete" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .int = 1 });
        _ = try tx.commit(null, null);
    }
    // **`.manual`, and the reason is upstream's type, not this port's flag.**
    // `let mut forked = doc.fork();` ([`test.rs`:2813](../github-automerge-automerge/rust/automerge/tests/test.rs)) forks an `Automerge`, and
    // `forked.transact(..)` ([`:2814-2819`](../github-automerge-automerge/rust/automerge/tests/test.rs)) is `Automerge::transact`, the manual door.
    // The port's [`forkDoc`] helper hands back `.auto` because most of this
    // file's forks are driven through the module-level autocommit functions,
    // and a manual transaction on one of those is `error.InvalidOp` from
    // `Tx.open` — which is what the `.manual` variant
    // [`forkDocMode`] exists for.
    var forked = try forkDocMode(&doc, .manual);
    defer forked.deinit();
    {
        var tx = try Tx.open(gpa, &forked);
        defer tx.deinit();
        _ = try tx.delete(root, .{ .key = "a" });
        _ = try tx.commit(null, null);
    }
    {
        const heads = try doc.merge(gpa, &forked);
        gpa.free(heads);
    }
    // `doc` now holds a delete op that uses the fork's actor. Delete ops are not
    // in the document's ops; they are referenced in the successors, so the save
    // must encode every actor the successors name.
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();
    // Upstream stops at `Automerge::load(&saved).unwrap()` and says in a
    // comment that this "will panic if we failed to encode the referenced
    // actor ID" ([`test.rs`:2830-2831](../github-automerge-automerge/rust/automerge/tests/test.rs)). **That is
    // the absence of an error, and it is not what is asserted here**, because a
    // save that dropped the second actor would still load: the successors
    // would name an actor index the change's own actor table does not hold,
    // and nothing about the empty root map would say so. The actor count
    // across the round trip is the property, and it is the one that fails
    // first when the encoder omits a referenced actor.
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try testing.expectEqual(@as(usize, 2), loaded.numActors());
    // And the merged state is the one the delete left behind, which is the
    // other half: the op survived the round trip, it is only invisible.
    try expectDoc(&loaded, .{ .map = &.{} });
}

// ── 85. save_with_empty_commits
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2834-2852

test "save with empty commits" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        _ = try tx.put(root, .{ .key = "a" }, .{ .int = 1 });
        _ = try tx.commit(null, null);
    }
    var forked = try forkDoc(&doc);
    defer forked.deinit();
    _ = try forked.emptyCommit(gpa, null, null);
    {
        const heads = try doc.merge(gpa, &forked);
        gpa.free(heads);
    }
    const saved = try doc.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();
}

// ── 86. large_patches_in_lists_are_correct
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2854-2895

test "large patches in lists are correct" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    const heads_before = try headsOf(&doc);
    defer gpa.free(heads_before);
    const list = blk: {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const l = try tx.putObject(root, .{ .key = "list" }, .list);
        // This should count as one.
        _ = try tx.insert(l, 0, .{ .str = "123456" });
        var i: usize = 1;
        while (i < 501) : (i += 1) {
            const inner = try tx.insertObject(l, i, .map);
            _ = try tx.put(inner, .{ .key = "a" }, .{ .int = @intCast(i) });
        }
        _ = try tx.commit(null, null);
        break :blk l;
    };
    const heads_after = try headsOf(&doc);
    defer gpa.free(heads_after);
    var patches = try doc.diff(gpa, heads_before, heads_after);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expect(got.len > 0);
    const last = got[got.len - 1];
    // The bug this pins: counting "123456" as six list elements makes the index
    // 505 rather than 500.
    try testing.expectEqual(@as(usize, 2), last.path.len);
    try testing.expect(last.path[0].obj.eql(root));
    try testing.expectEqualStrings("list", last.path[0].prop.key);
    try testing.expect(last.path[1].obj.eql(list));
    try testing.expectEqual(@as(usize, 500), last.path[1].prop.index);
    try testing.expect(last.action == .put_map);
}

// ── 87. diff_should_reverse_deletion_of_object_in_list_correctly
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2897-2931

test "a diff should reverse a deletion of an object in a list" {
    var doc = try newDoc();
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .str = "a" });
    const text = try am.transaction.insertObject(&doc, list, 1, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "b");
    _ = try am.transaction.insert(&doc, list, 2, .{ .str = "c" });

    const heads_before = try headsOf(&doc);
    defer gpa.free(heads_before);
    _ = try am.transaction.delete(&doc, list, .{ .index = 1 });
    const heads_after = try headsOf(&doc);
    defer gpa.free(heads_after);

    try doc.updateDiffCursor();
    var patches = try doc.diff(gpa, heads_after, heads_before);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[0].action == .insert);
    try testing.expectEqual(@as(usize, 1), got[0].action.insert.index);
    try testing.expectEqual(@as(usize, 1), got[0].action.insert.values.len());
    try testing.expectEqual(ObjType.text, got[0].action.insert.values.get(0).?.value.object);
    try testing.expect(got[1].action == .splice_text);
    try testing.expectEqual(@as(usize, 0), got[1].action.splice_text.index);
    try testing.expectEqualStrings("b", got[1].action.splice_text.value.asStr());
}

// ── 88. diff_should_reverse_deletion_of_object_in_map_correctly
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2933-2966

test "a diff should reverse a deletion of an object in a map" {
    var doc = try newDoc();
    defer doc.deinit();
    const map = try am.transaction.putObject(&doc, root, .{ .key = "map" }, .map);
    _ = try am.transaction.putObject(&doc, map, .{ .key = "text" }, .text);
    _ = try am.transaction.put(&doc, map, .{ .key = "a" }, .{ .str = "a" });
    const text = try am.transaction.putObject(&doc, map, .{ .key = "b" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "b");
    _ = try am.transaction.put(&doc, map, .{ .key = "c" }, .{ .str = "c" });

    const heads_before = try headsOf(&doc);
    defer gpa.free(heads_before);
    _ = try am.transaction.delete(&doc, map, .{ .key = "b" });
    const heads_after = try headsOf(&doc);
    defer gpa.free(heads_after);

    try doc.updateDiffCursor();
    var patches = try doc.diff(gpa, heads_after, heads_before);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[0].action == .put_map);
    try testing.expectEqualStrings("b", got[0].action.put_map.key);
    try testing.expectEqual(ObjType.text, got[0].action.put_map.value.object);
    try testing.expect(got[1].action == .splice_text);
    try testing.expectEqual(@as(usize, 0), got[1].action.splice_text.index);
    try testing.expectEqualStrings("b", got[1].action.splice_text.value.asStr());
}

// ── 89. diff_should_reverse_deletion_of_block_in_text_correctly
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2968-3003

test "a diff should reverse a deletion of a block in text" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "a");
    const block = try am.transaction.splitBlock(&doc, text, 1);
    try am.transaction.spliceText(&doc, text, 2, 0, "b");
    _ = try am.transaction.put(&doc, block, .{ .key = "key" }, .{ .str = "value" });

    const heads_before = try headsOf(&doc);
    defer gpa.free(heads_before);
    _ = try am.transaction.delete(&doc, text, .{ .index = 1 });
    const heads_after = try headsOf(&doc);
    defer gpa.free(heads_after);

    try doc.updateDiffCursor();
    var patches = try doc.diff(gpa, heads_after, heads_before);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(got[0].action == .insert);
    try testing.expectEqual(@as(usize, 1), got[0].action.insert.index);
    try testing.expectEqual(@as(usize, 1), got[0].action.insert.values.len());
    try testing.expectEqual(ObjType.map, got[0].action.insert.values.get(0).?.value.object);
    try testing.expect(got[1].action == .put_map);
    try testing.expectEqualStrings("key", got[1].action.put_map.key);
    try testing.expectEqualStrings("value", got[1].action.put_map.value.asStr());
}

// ── 90. missing_actors_when_docs_are_forked
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3005-3060

test "missing actors when documents are forked" {
    // Reproduces https://github.com/automerge/automerge/issues/897: a document
    // can hold an actor in its table that never reaches a change, and saving it
    // then writes actor indexes off by one.
    var doc0 = try newDocWithActor(.{ .bytes = "\x00" });
    defer doc0.deinit();
    _ = try am.transaction.put(&doc0, root, .{ .key = "a" }, .{ .int = 1 });

    // Swapping these actors is where the error occurred upstream.
    var doc1 = try forkDoc(&doc0);
    defer doc1.deinit();
    doc1.setActorId(.{ .bytes = "\x02" });
    var doc2 = try forkDoc(&doc0);
    defer doc2.deinit();
    doc2.setActorId(.{ .bytes = "\x01" });

    _ = try am.transaction.put(&doc1, root, .{ .key = "b" }, .{ .int = 2 });
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    const s1 = try doc2.save(gpa);
    defer gpa.free(s1);

    // This transaction does nothing, because "c" does not exist, so the actor
    // reaches `doc2`'s actor table and never reaches a change.
    _ = try am.transaction.delete(&doc2, root, .{ .key = "c" });

    // **Upstream's `save_and_verify` is a save followed by a load and a
    // comparison, and that is what runs here**: [`Document.save`](../src/doc.zig)
    // has no `verify` arm, and [AGENTS.md](../AGENTS.md) is explicit that
    // `save()` bytes are not required to be identical across implementations.
    const s2 = try doc2.save(gpa);
    defer gpa.free(s2);
    var reloaded = try Document.load(gpa, s2, .unicode_code_point, .auto);
    defer reloaded.deinit();
    try reloaded.debugCmp(&doc2);
    try testing.expectEqual(s1.len > 0, s2.len > 0);
}

// ── 91. allows_empty_keys_in_mappings
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3062-3072

test "empty keys in mappings are allowed" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "" }, .{ .int = 1 });
    try expectDoc(&doc, .{ .map = &.{.{ .key = "", .values = &.{scInt(1)} }} });
}

// ── 92. has_our_changes
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3074-3108
//
// **Not ported: the port has no `has_our_changes`.** Upstream's is
// `SyncDoc::has_our_changes(&self, state: &State)`
// ([`sync.rs`](../github-automerge-automerge/rust/automerge/src/sync.rs)), which
// asks the state whether the peer's `have` covers our heads. The port's
// [`sync/protocol.zig`](../src/sync/protocol.zig) exports
// `generateSyncMessage`, `receiveSyncMessage`, `getHashesToSend` and
// `makeBloomFilter` and nothing else; the pieces the answer is built from
// ([`State.their_heads`](../src/sync/state.zig), [`State.shared_heads`](../src/sync/state.zig))
// are public, so a caller *could* write it, but there is no function to test and
// writing one here would be a new API rather than a ported test.

// ── 93. stats_smoke_test
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3110-3120

test "stats smoke test" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "a" }, .{ .int = 1 });
    _ = try am.transaction.put(&doc, root, .{ .key = "b" }, .{ .int = 2 });
    const stats = am.read.stats(&doc);
    try testing.expectEqual(@as(u64, 2), stats.num_changes);
    try testing.expectEqual(@as(u64, 2), stats.num_ops);
}

// ── 94. invalid_index
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3122-3141

test "an invalid index" {
    var doc = try newDoc();
    defer doc.deinit();
    const obj = try am.transaction.putObject(&doc, root, .{ .key = "a" }, .list);
    _ = try am.transaction.insert(&doc, obj, 0, .{ .int = 1 });
    _ = try am.transaction.put(&doc, obj, .{ .index = 0 }, .{ .int = 2 });
    try testing.expectEqual(@as(i64, 2), (try scalarAt(&doc, obj, .{ .index = 0 })).int);
    try testing.expectError(error.InvalidIndex, am.transaction.insert(&doc, obj, 2, .{ .int = 1 }));
    try testing.expectError(error.InvalidIndex, am.transaction.put(&doc, obj, .{ .index = 2 }, .{ .int = 2 }));
    try testing.expectError(error.InvalidIndex, am.transaction.insert(&doc, obj, 100, .{ .int = 1 }));
    try testing.expectError(error.InvalidIndex, am.transaction.put(&doc, obj, .{ .index = 100 }, .{ .int = 2 }));
}

// ── 95. zero_length_data
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3143-3157

test "zero length data" {
    var doc = try newDoc();
    defer doc.deinit();
    _ = try am.transaction.put(&doc, root, .{ .key = "string" }, .{ .str = "" });
    _ = try am.transaction.put(&doc, root, .{ .key = "bytes" }, .{ .bytes = &.{} });
    try expectDoc(&doc, .{ .map = &.{
        .{ .key = "bytes", .values = &.{scBytes("")} },
        .{ .key = "string", .values = &.{scStr("")} },
    } });
}

// ── 96. make_sure_load_incremental_doesnt_skip_a_load_with_a_common_head
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3159-3192

test "load_incremental does not skip a load with a common head" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    _ = try am.transaction.put(&doc1, root, .{ .key = "string" }, .{ .str = "hello" });
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();
    var doc3 = try forkDoc(&doc1);
    defer doc3.deinit();
    {
        // `headsOf` returns an owned slice ([`Document.getHeads`](../src/doc.zig)), so
        // reading `.len` off it and dropping it leaks. This is the one leak
        // `std.testing.allocator` reported for this file.
        const heads = try headsOf(&doc1);
        defer gpa.free(heads);
        try testing.expectEqual(@as(usize, 1), heads.len);
    }

    _ = try am.transaction.put(&doc1, root, .{ .key = "concurrent1" }, .{ .str = "123" });
    const heads1 = try headsOf(&doc1);
    defer gpa.free(heads1);
    try testing.expectEqual(@as(usize, 1), heads1.len);
    const hash_b = heads1[0];

    const saved1 = try doc1.save(gpa);
    defer gpa.free(saved1);
    _ = try doc3.loadIncremental(gpa, saved1);
    const heads3 = try headsOf(&doc3);
    defer gpa.free(heads3);
    try testing.expectEqual(@as(usize, 1), heads3.len);
    const hash_c = heads3[0];
    try testing.expect(hash_b.eql(hash_c));

    _ = try am.transaction.put(&doc2, root, .{ .key = "concurrent2" }, .{ .str = "abc" });
    const heads2 = try headsOf(&doc2);
    defer gpa.free(heads2);
    try testing.expectEqual(@as(usize, 1), heads2.len);
    const hash_d = heads2[0];
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    const merged = try headsOf(&doc2);
    defer gpa.free(merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expect(merged[0].eql(hash_d) or merged[1].eql(hash_d));
    try testing.expect(merged[0].eql(hash_b) or merged[1].eql(hash_b));

    const saved2 = try doc2.save(gpa);
    defer gpa.free(saved2);
    _ = try doc3.loadIncremental(gpa, saved2);
    const heads3b = try headsOf(&doc3);
    defer gpa.free(heads3b);
    const heads2b = try headsOf(&doc2);
    defer gpa.free(heads2b);
    try testing.expectEqualSlices(ChangeHash, heads3b, heads2b);
}

// ── 97. test_get_last_local_change_generation
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3194-3213

test "the last local change follows every edit" {
    var doc = try newDoc();
    defer doc.deinit();
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&doc, text, 0, 0, "hello world");
    try confirmLastChange(&doc);
    try am.transaction.spliceText(&doc, text, 5, 1, "X");
    try confirmLastChange(&doc);
    try am.transaction.spliceText(&doc, text, 6, 1, "");
    try confirmLastChange(&doc);
    try am.transaction.spliceText(&doc, text, 0, 0, "ten thousand and five hundred");
    try confirmLastChange(&doc);
}

/// Upstream's `confirm_last_change`
/// ([`test.rs`:3209-3213](../github-automerge-automerge/rust/automerge/tests/test.rs)).
fn confirmLastChange(doc: *Document) !void {
    const heads = try headsOf(doc);
    defer gpa.free(heads);
    var last = (try doc.getLastLocalChange(gpa)) orelse return error.NoLocalChange;
    defer last.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expect(last.hash().eql(heads[0]));
}

// ── 98. test_overwriting_a_conflict
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3215-3236

test "overwriting a conflict" {
    var doc1 = try newDoc();
    defer doc1.deinit();
    var doc2 = try forkDoc(&doc1);
    defer doc2.deinit();

    // The same value twice.
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value" });
    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "value" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    {
        const a = try am.read.getAll(&doc1, root, .{ .key = "key" }, gpa);
        defer gpa.free(a);
        const b = try am.read.getAll(&doc2, root, .{ .key = "key" }, gpa);
        defer gpa.free(b);
        try testing.expectEqual(@as(usize, 2), a.len);
        try testing.expectEqual(@as(usize, 2), b.len);
    }
    _ = try am.transaction.put(&doc1, root, .{ .key = "key" }, .{ .str = "value" });
    _ = try am.transaction.put(&doc2, root, .{ .key = "key" }, .{ .str = "value" });
    {
        const heads = try doc1.merge(gpa, &doc2);
        gpa.free(heads);
    }
    {
        const heads = try doc2.merge(gpa, &doc1);
        gpa.free(heads);
    }
    {
        const a = try am.read.getAll(&doc1, root, .{ .key = "key" }, gpa);
        defer gpa.free(a);
        const b = try am.read.getAll(&doc2, root, .{ .key = "key" }, gpa);
        defer gpa.free(b);
        try testing.expectEqual(@as(usize, 1), a.len);
        try testing.expectEqual(@as(usize, 1), b.len);
    }
}

// ── 99. get_changes_with_hash_of_empty_change_produces_correct_result
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3238-3255)

test "get_changes with the hash of an empty change produces nothing" {
    // An empty change has a sequence number and no ops, so a clock built from
    // `max_op` alone does not cover it and the change must not come back.
    var doc = try newDoc();
    defer doc.deinit();
    const head = try doc.emptyCommit(gpa, null, null);
    var have = try gpa.alloc(ChangeHash, 1);
    defer gpa.free(have);
    have[0] = head;
    var changes = try doc.getChanges(gpa, have);
    defer changes.deinit(gpa);
    try testing.expect(changes.isEmpty());
}

// ── 100. reproduce_clock_cache_bug
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3257-3403

test "the clock cache does not lose commits" {
    var base = try newDoc();
    defer base.deinit();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "initial_commit_{d}", .{i});
        _ = try am.transaction.put(&base, root, .{ .key = key }, .{ .bool_value = true });
    }

    const num_branches: usize = 20;
    const commits_per_branch: usize = 2;
    var branches: std.ArrayList(Document) = .empty;
    {
        var n: usize = 0;
        while (n < num_branches - 1) : (n += 1) try branches.append(gpa, try forkDoc(&base));
        try branches.append(gpa, try base.clone(gpa, .auto));
    }
    defer {
        for (branches.items) |*b| b.deinit();
        branches.deinit(gpa);
    }
    for (branches.items, 0..) |*branch, branch_no| {
        var commit_no: usize = 0;
        while (commit_no < commits_per_branch) : (commit_no += 1) {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "branch_{d}-{d}", .{ branch_no, commit_no });
            _ = try am.transaction.put(branch, root, .{ .key = key }, .{ .bool_value = true });
            // A new actor for the next commit.
            const next = try forkDoc(branch);
            branch.deinit();
            branch.* = next;
        }
    }
    var merged = branches.pop().?;
    defer merged.deinit();
    for (branches.items) |*branch| {
        const heads = try merged.merge(gpa, branch);
        gpa.free(heads);
    }
    // Commits after the merge, so a clock is cached between the heads and the
    // branches.
    i = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "after-merge-{d}", .{i});
        _ = try am.transaction.put(&merged, root, .{ .key = key }, .{ .bool_value = true });
    }
    const heads = try headsOf(&merged);
    defer gpa.free(heads);
    var changes = try merged.getChanges(gpa, heads);
    defer changes.deinit(gpa);
    try testing.expect(changes.isEmpty());
}

// ── 101. merge_panic_after_putting_value_equal_to_initial_value
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3404-3432)

test "a merge after putting a value equal to the initial value" {
    // Regression test for https://github.com/automerge/automerge/issues/1390:
    // putting the value that is already there is a no-op, so the transaction
    // produces no ops and the actor it speculatively added is removed again on
    // commit, which used to leave the patch log naming an actor the document no
    // longer had.
    var base = try newDocWithActor(.{ .bytes = "base" });
    defer base.deinit();
    _ = try am.transaction.put(&base, root, .{ .key = "a" }, .{ .int = 1 });

    var left = try forkDoc(&base);
    defer left.deinit();
    left.setActorId(.{ .bytes = "left" });
    var right = try forkDoc(&base);
    defer right.deinit();
    right.setActorId(.{ .bytes = "right" });

    // Equal to the initial value, so a no-op.
    _ = try am.transaction.put(&left, root, .{ .key = "a" }, .{ .int = 1 });
    _ = try am.transaction.put(&right, root, .{ .key = "a" }, .{ .int = 0 });
    {
        const heads = try left.merge(gpa, &right);
        gpa.free(heads);
    }
    // "right" wins the conflict, so "a" is 0.
    try testing.expectEqual(@as(i64, 0), (try scalarAt(&left, root, .{ .key = "a" })).int);

    var patches = try left.diffIncremental(gpa);
    defer patches.deinit();
    const saved = try left.save(gpa);
    defer gpa.free(saved);
    var reloaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer reloaded.deinit();
    try testing.expectEqual(@as(i64, 0), (try scalarAt(&reloaded, root, .{ .key = "a" })).int);
}

// ── 102. merge_after_noop_then_real_put
//     [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3434-3458)

test "a merge after a no-op and then a real put" {
    var base = try newDocWithActor(.{ .bytes = "base" });
    defer base.deinit();
    _ = try am.transaction.put(&base, root, .{ .key = "a" }, .{ .int = 1 });

    var left = try forkDoc(&base);
    defer left.deinit();
    left.setActorId(.{ .bytes = "left" });
    var right = try forkDoc(&base);
    defer right.deinit();
    right.setActorId(.{ .bytes = "right" });

    // A no-op, then a real change in a separate commit on the same actor.
    _ = try am.transaction.put(&left, root, .{ .key = "a" }, .{ .int = 1 });
    _ = try am.transaction.put(&left, root, .{ .key = "b" }, .{ .str = "hello" });
    _ = try am.transaction.put(&right, root, .{ .key = "a" }, .{ .int = 0 });
    {
        const heads = try left.merge(gpa, &right);
        gpa.free(heads);
    }
    var patches = try left.diffIncremental(gpa);
    defer patches.deinit();
    try testing.expectEqual(@as(i64, 0), (try scalarAt(&left, root, .{ .key = "a" })).int);
    try testing.expectEqualStrings("hello", (try scalarAt(&left, root, .{ .key = "b" })).str);
}

// ── 103. fork_at_current_heads_after_interleaved_actor_changes
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3848-3873

test "fork_at at the current heads after interleaved actor changes" {
    // Three linear changes on one document, the first and third by the same
    // actor with a different actor in between. `fork_at` at the document's own
    // heads used to panic with `MissingOps` in
    // `ChangeCollector::from_build_meta_inner`, and which actor ids trigger it
    // depends on the ids: [2,0,2], [0,1,0] and [2,1,2] panic, [1,0,1] and
    // [0,2,0] do not.
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.putObject(&doc, root, .{ .key = "a" }, .map);
    doc.setActorId(.{ .bytes = "\x00" });
    _ = try am.transaction.put(&doc, root, .{ .key = "b" }, .{ .bool_value = false });
    doc.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&doc, root, .{ .key = "c" }, .{ .int = -7 });

    const heads = try headsOf(&doc);
    defer gpa.free(heads);
    var forked = try doc.forkAt(gpa, heads, .auto);
    defer forked.deinit();
    // The fork is at the document's present, so it agrees with it.
    try forked.debugCmp(&doc);
}

// ── 104. fork_at_foreign_heads_errors_instead_of_panicking
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3875-3886

test "fork_at foreign heads errors instead of panicking" {
    var a = try newDoc();
    defer a.deinit();
    _ = try am.transaction.put(&a, root, .{ .key = "k" }, .{ .int = 1 });
    const heads_a = try headsOf(&a);
    defer gpa.free(heads_a);

    var b = try newDoc();
    defer b.deinit();
    _ = try am.transaction.put(&b, root, .{ .key = "x" }, .{ .int = 2 });

    try testing.expectError(error.InvalidHash, b.forkAt(gpa, heads_a, .auto));
}

// ── 105. increment_patch_clears_resolved_map_conflict
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3888-3919

test "an increment patch clears a resolved map conflict" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "01" });
    _ = try am.transaction.put(&doc, root, .{ .key = "key" }, .null_value);

    var concurrent = try forkDoc(&doc);
    defer concurrent.deinit();
    concurrent.setActorId(.{ .bytes = "02" });
    _ = try am.transaction.put(&concurrent, root, .{ .key = "key" }, .{ .counter = .{ .current = -1000 } });
    {
        const heads = try doc.merge(gpa, &concurrent);
        gpa.free(heads);
    }

    // Incrementing the visible counter resolves the concurrent null as well as
    // changing the counter, so the patch must replace the conflicted register
    // entry and not merely apply an increment to it.
    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    var patches = try patchesFrom(&doc, IncrementKeyBy{ .key = "key", .by = 28 });
    defer patches.deinit();
    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 106. diff_from_integrated_to_isolated_heads_reconstructs_target
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3921-3942

test "a diff from integrated to isolated heads reconstructs the target" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    _ = try am.transaction.putObject(&doc, root, .{ .key = "k8" }, .map);

    try doc.isolate(gpa, &.{});
    _ = try am.transaction.put(&doc, root, .{ .key = "k8" }, .{ .int = 1000 });
    const isolated_heads = try headsOf(&doc);
    defer gpa.free(isolated_heads);

    try doc.integrate();
    const integrated_heads = try headsOf(&doc);
    defer gpa.free(integrated_heads);
    var actual = try hydrateAt(&doc, integrated_heads);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, isolated_heads);
    defer expected.deinit();
    var patches = try doc.diff(gpa, integrated_heads, isolated_heads);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 107. incremental_diff_survives_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3944-3974

test "an incremental diff survives an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const list = try am.transaction.putObject(&doc, root, .{ .key = "k6" }, .list);

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.splice(&doc, list, 0, 0, gpa, &.{
        .{ .bool_value = false },
        .{ .int = 1000 },
    });
    try doc.isolate(gpa, &.{});
    try doc.integrate();

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 108. incremental_text_diff_survives_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3976-3999

test "an incremental text diff survives an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const text = try am.transaction.putObject(&doc, root, .{ .key = "text" }, .text);

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.spliceText(&doc, text, 0, 0, "hello");
    try doc.isolate(gpa, &.{});
    try doc.integrate();

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 109. incremental_diff_discards_edits_inside_deleted_map
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4001-4032

test "an incremental diff discards edits inside a deleted map" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const map = try am.transaction.putObject(&doc, root, .{ .key = "container" }, .map);
    const text = try am.transaction.putObject(&doc, map, .{ .key = "text" }, .text);

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.spliceText(&doc, text, 0, 0, "hello");
    const before_delete = try headsOf(&doc);
    defer gpa.free(before_delete);
    _ = try am.transaction.delete(&doc, root, .{ .key = "container" });

    // Back behind the object's creation and forward to the state immediately
    // before its deletion, which exposes the map and text from a view whose
    // clock covered neither.
    try doc.isolate(gpa, &.{});
    try doc.isolate(gpa, before_delete);

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 110. incremental_counter_diff_survives_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4034-4058

test "an incremental counter diff survives an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const map = try am.transaction.putObject(&doc, root, .{ .key = "container" }, .map);
    _ = try am.transaction.put(&doc, map, .{ .key = "count" }, .{ .counter = .{ .current = 0 } });

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.increment(&doc, map, .{ .key = "count" }, 1);
    try doc.isolate(gpa, &.{});
    try doc.integrate();

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 111. incremental_deep_text_diff_survives_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4060-4085

test "an incremental deep text diff survives an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const outer = try am.transaction.putObject(&doc, root, .{ .key = "outer" }, .map);
    const inner = try am.transaction.putObject(&doc, outer, .{ .key = "inner" }, .map);
    const text = try am.transaction.putObject(&doc, inner, .{ .key = "text" }, .text);

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.spliceText(&doc, text, 0, 0, "deep");
    try doc.isolate(gpa, &.{});
    try doc.integrate();

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 112. incremental_sibling_text_diffs_survive_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4087-4112

test "incremental sibling text diffs survive an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const left = try am.transaction.putObject(&doc, root, .{ .key = "left" }, .text);
    const right = try am.transaction.putObject(&doc, root, .{ .key = "right" }, .text);

    var first = try doc.diffIncremental(gpa);
    defer first.deinit();

    try am.transaction.spliceText(&doc, left, 0, 0, "L");
    try am.transaction.spliceText(&doc, right, 0, 0, "R");
    try doc.isolate(gpa, &.{});
    try doc.integrate();

    const before = try doc.diffCursor(gpa);
    defer gpa.free(before);
    const after = try headsOf(&doc);
    defer gpa.free(after);
    var actual = try hydrateAt(&doc, before);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, after);
    defer expected.deinit();
    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 113. incremental_patches_survive_nested_edit_and_list_shift_across_isolation
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4114-4142

test "incremental patches survive a nested edit and a list shift across isolation" {
    var doc = try newDoc();
    defer doc.deinit();
    const items = try am.transaction.putObject(&doc, root, .{ .key = "items" }, .list);
    const a = try am.transaction.insertObject(&doc, items, 0, .map);
    _ = try am.transaction.put(&doc, a, .{ .key = "id" }, .{ .str = "a" });
    _ = try am.transaction.put(&doc, a, .{ .key = "n" }, .{ .int = 1 });
    const b = try am.transaction.insertObject(&doc, items, 1, .map);
    _ = try am.transaction.put(&doc, b, .{ .key = "id" }, .{ .str = "b" });
    _ = try am.transaction.put(&doc, b, .{ .key = "n" }, .{ .int = 2 });
    const beginning = try headsOf(&doc);
    defer gpa.free(beginning);

    const z = try am.transaction.insertObject(&doc, items, 0, .map);
    _ = try am.transaction.put(&doc, z, .{ .key = "id" }, .{ .str = "z" });
    _ = try am.transaction.put(&doc, z, .{ .key = "n" }, .{ .int = 0 });
    try doc.updateDiffCursor();
    var actual = try hydrateNow(&doc);
    defer actual.deinit();

    try doc.isolate(gpa, beginning);
    _ = try am.transaction.put(&doc, a, .{ .key = "n" }, .{ .int = 99 });
    try doc.integrate();

    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    try applyPatches(&actual, doc.textEncoding(), patches.slice());
    var want = try hydrateNow(&doc);
    defer want.deinit();
    try testing.expect(actual.eql(&want));
}

// ── 114. incremental_list_conflict_survives_isolate_integrate_roundtrip
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4180-4208

test "an incremental list conflict survives an isolate and integrate round trip" {
    var doc = try newDoc();
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .str = "base" });
    const beginning = try headsOf(&doc);
    defer gpa.free(beginning);

    const first = try am.transaction.putObject(&doc, list, .{ .index = 0 }, .text);
    try am.transaction.spliceText(&doc, first, 0, 0, "first");
    var opening = try doc.diffIncremental(gpa);
    defer opening.deinit();
    var actual = try hydrateNow(&doc);
    defer actual.deinit();

    try doc.isolate(gpa, beginning);
    const second = try am.transaction.putObject(&doc, list, .{ .index = 0 }, .text);
    try am.transaction.spliceText(&doc, second, 0, 0, "second");
    try doc.integrate();

    var patches = try doc.diffIncremental(gpa);
    defer patches.deinit();
    var saw_conflict = false;
    for (patches.slice()) |p| {
        if (p.action == .conflict and p.action.conflict.prop.eql(.{ .index = 0 })) saw_conflict = true;
    }
    try testing.expect(saw_conflict);
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    var want = try hydrateNow(&doc);
    defer want.deinit();
    try testing.expect(actual.eql(&want));
}

// ── 115. diff_to_isolated_batch_created_text_applies_to_hydrated_value_from_fuzz_trace
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4209-4251

test "a diff to an isolated batch-created text applies to a hydrated value" {
    const actor: ActorId = .{ .bytes = "7f" };
    var doc = try newDocWithActor(actor);
    defer doc.deinit();
    var peer = try forkDoc(&doc);
    defer peer.deinit();
    peer.setActorId(.{ .bytes = "7f00000000000000" });
    peer.setActorId(actor);
    _ = try am.transaction.putObject(&peer, root, .{ .key = "k4" }, .text);

    try exchange(7, &doc, &peer);

    try doc.isolate(gpa, &.{});
    doc.setActorId(.{ .bytes = "ff0000" });
    var value = try am.hydrate.Value.text(gpa, .unicode_code_point, "hello world");
    defer value.deinit();
    _ = try am.transaction.batchCreateValue(&doc, root, .{ .key = "k4" }, value, false);
    const isolated = try headsOf(&doc);
    defer gpa.free(isolated);
    try doc.integrate();

    const integrated = try headsOf(&doc);
    defer gpa.free(integrated);
    var actual = try hydrateAt(&doc, integrated);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, isolated);
    defer expected.deinit();
    var patches = try doc.diff(gpa, integrated, isolated);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

/// `rounds` rounds of the two-sided exchange upstream writes out by hand
/// ([`test.rs`:4221-4234](../github-automerge-automerge/rust/automerge/tests/test.rs)):
/// generate from each side in turn and deliver what the other produced.
///
/// **The generated message is handed over by value and never freed here.**
/// `receiveSyncMessage` takes a `Message` **by value and consumes it**: it
/// destructures the message (`sync.rs:395-402`) and *moves* `have`, `heads`
/// and `need` into the peer's `State` (`sync.rs:459-461`), freeing only
/// `changes` itself. Upstream moves the message and has nothing left to free
/// ([`test.rs`:4224-4227](../github-automerge-automerge/rust/automerge/tests/test.rs)),
/// so there is nothing here to free either.
///
/// A `defer msg.deinit()` here — which is what this helper used to have — is a
/// **second** free of `heads`, `need`, `have` and `changes`, and it leaves
/// `State.their_have` pointing into freed memory. The symptom is not in this
/// helper: it is a `General protection exception` in the **next**
/// `generateSyncMessage`, at the `their_have[0]` read, one call later. Zig has
/// no move-only type, so a by-value hand-off *is* the move and exactly one
/// owner runs the free; here that owner is the callee.
fn exchange(rounds: usize, left: *Document, right: *Document) !void {
    var ls = am.sync.state.State.new(gpa);
    defer ls.deinit();
    var rs = am.sync.state.State.new(gpa);
    defer rs.deinit();
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        if (try am.sync.protocol.generateSyncMessage(gpa, left, &ls)) |msg| {
            try am.sync.protocol.receiveSyncMessage(gpa, right, &rs, msg);
        }
        if (try am.sync.protocol.generateSyncMessage(gpa, right, &rs)) |msg| {
            try am.sync.protocol.receiveSyncMessage(gpa, left, &ls, msg);
        }
    }
}

// ── 116. diff_exposes_list_object_when_conflict_winner_is_removed
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4253-4285

test "a diff exposes a list object when the conflict winner is removed" {
    var doc = try newDocWithActor(.{ .bytes = "7f" });
    defer doc.deinit();
    const list = try am.transaction.putObject(&doc, root, .{ .key = "list" }, .list);
    _ = try am.transaction.insert(&doc, list, 0, .{ .str = "base" });
    const base = try headsOf(&doc);
    defer gpa.free(base);

    var peer = try forkDoc(&doc);
    defer peer.deinit();
    peer.setActorId(.{ .bytes = "7f00000000000000" });
    _ = try am.transaction.putObject(&peer, list, .{ .index = 0 }, .text);
    {
        const heads = try doc.merge(gpa, &peer);
        gpa.free(heads);
    }

    try doc.isolate(gpa, base);
    doc.setActorId(.{ .bytes = "ff0000" });
    var value = try am.hydrate.Value.text(gpa, .unicode_code_point, "hello world");
    defer value.deinit();
    _ = try am.transaction.batchCreateValue(&doc, list, .{ .index = 0 }, value, false);
    const isolated = try headsOf(&doc);
    defer gpa.free(isolated);
    try doc.integrate();

    const integrated = try headsOf(&doc);
    defer gpa.free(integrated);
    var actual = try hydrateAt(&doc, integrated);
    defer actual.deinit();
    var expected = try hydrateAt(&doc, isolated);
    defer expected.deinit();
    var patches = try doc.diff(gpa, integrated, isolated);
    defer patches.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 117. transaction_patches_insert_hidden_scalar_into_utf8_text_from_fuzz_trace
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4287-4314

test "transaction patches insert a hidden scalar into UTF-8 text" {
    // Upstream builds the value on an `AutoCommit`
    // ([`test.rs`:4290](../github-automerge-automerge/rust/automerge/tests/test.rs))
    // and only reaches for a manual transaction afterwards
    // ([`:4302-4304`](../github-automerge-automerge/rust/automerge/tests/test.rs)):
    // `batch_create_object` is a `Transactable` method, and the transaction it
    // opens is the one `AutoCommit` holds across calls
    // ([`autocommit.rs`:445-457](../github-automerge-automerge/rust/automerge/src/autocommit.rs));
    // `doc.document().clone()` is a plain `Automerge`, so every write after
    // line 4300 is a manual transaction.
    //
    // The port's spelling of that split is one mode flag, and **it belongs on
    // the `.auto` side of `batchCreateValue`**: the module-level
    // [`am.transaction.batchCreateValue`](../src/transact.zig) refuses a
    // document that is not in autocommit mode (`requireAuto`), which is
    // upstream's `Transactable` door spelled as a runtime check. The `.manual`
    // that used to be on this line was therefore a transcription that **could
    // not have passed against the reference either** — it made the call below
    // impossible.
    var doc = try Document.initWithEncoding(gpa, .utf8_code_unit, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "fe004faf" });
    var emoji = try am.hydrate.Value.text(gpa, .utf8_code_unit, "\u{1F469}\u{1F3FF}\u{200D}\u{1F692}");
    defer emoji.deinit();
    const text = try am.transaction.batchCreateValue(&doc, root, .{ .key = "k31" }, emoji, false);
    // Upstream's `doc.commit()` plus the clone it takes at `:4300-4302`. The
    // commit is already done — the autocommit call above closed its own
    // transaction — so this only has to switch the door for `Tx.open`.
    doc.setMode(.manual);

    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    try doc.updateDiffCursor();
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    const index = 195 % (try am.read.length(&doc, text) + 1);
    _ = try tx.insert(text, index, .{ .uint = 150 });
    _ = try tx.commit(null, null);

    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    try applyPatches(&actual, .utf8_code_unit, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 118. transaction_patches_split_block_at_normalized_utf8_index
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4316-4335

test "transaction patches split a block at a normalized UTF-8 index" {
    var source = try Document.initWithEncoding(gpa, .utf8_code_unit, .auto);
    defer source.deinit();
    const text = try am.transaction.putObject(&source, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&source, text, 0, 0, "\u{1F469}\u{1F3FF}\u{200D}\u{1F692}");

    var doc = try source.clone(gpa, .manual);
    defer doc.deinit();
    var actual = try hydrateNow(&doc);
    defer actual.deinit();
    try doc.updateDiffCursor();
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    _ = try tx.splitBlock(text, 3);
    _ = try tx.commit(null, null);

    var expected = try hydrateNow(&doc);
    defer expected.deinit();
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    try applyPatches(&actual, .utf8_code_unit, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 119. transaction_patches_mark_at_normalized_utf8_indexes
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4337-4360

test "transaction patches mark at normalized UTF-8 indexes" {
    var source = try Document.initWithEncoding(gpa, .utf8_code_unit, .auto);
    defer source.deinit();
    const text = try am.transaction.putObject(&source, root, .{ .key = "text" }, .text);
    try am.transaction.spliceText(&source, text, 0, 0, "\u{1F469}\u{1F3FF}\u{200D}\u{1F692}");

    var doc = try source.clone(gpa, .manual);
    defer doc.deinit();
    try doc.updateDiffCursor();
    var tx = try Tx.open(gpa, &doc);
    defer tx.deinit();
    try tx.mark(text, 3, 5, "bold", .none, .{ .bool_value = true });
    _ = try tx.commit(null, null);
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expect(got.len > 0);
    try testing.expect(got[0].action == .mark);
    try testing.expectEqual(@as(usize, 1), got[0].action.mark.marks.len);
    try testing.expectEqual(@as(usize, 4), got[0].action.mark.marks[0].start);
    try testing.expectEqual(@as(usize, 8), got[0].action.mark.marks[0].end);
}

// ── 120. patches_expose_surviving_conflict_after_deleting_other_branch_from_fuzz_trace
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):4407-4450

test "patches expose a surviving conflict after deleting the other branch" {
    var target = try newDocWithActor(.{ .bytes = "7f0000000000008027" });
    defer target.deinit();
    var value = try am.hydrate.Value.text(gpa, .unicode_code_point, "a");
    defer value.deinit();
    const object = try am.transaction.batchCreateValue(&target, root, .{ .key = "value" }, value, false);

    var left = try forkDoc(&target);
    defer left.deinit();
    _ = try am.transaction.put(&left, object, .{ .index = 0 }, .{ .str = "\u{1F98A}\u{1F43B}" });

    var right = try forkDoc(&target);
    defer right.deinit();
    right.setActorId(.{ .bytes = "fe004faf" });
    _ = try am.transaction.put(&right, object, .{ .index = 0 }, .{ .bytes = &[_]u8{0} ** 32 });
    {
        const heads = try target.merge(gpa, &left);
        gpa.free(heads);
    }
    {
        const heads = try target.merge(gpa, &right);
        gpa.free(heads);
    }
    _ = try am.transaction.delete(&right, object, .{ .index = 0 });

    var actual = try hydrateNow(&target);
    defer actual.deinit();
    var patches = try patchesFrom(&target, MergeInto{ .other = &right });
    defer patches.deinit();
    var expected = try hydrateNow(&target);
    defer expected.deinit();
    try applyPatches(&actual, .unicode_code_point, patches.slice());
    try testing.expect(actual.eql(&expected));
}

// ── 121. big_list
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2437-2474
//
// Upstream's `const B: usize = 16` (`test.rs`:11) is the literal it is.

test "a big list" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    const list_id = blk: {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const l = try tx.putObject(root, .{ .key = "list" }, .list);
        _ = try tx.commit(null, null);
        break :blk l;
    };
    try doc.updateDiffCursor();
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        var i: usize = 0;
        while (i <= 16) : (i += 1) _ = try tx.insert(list_id, i, .null_value);
        i = 0;
        while (i <= 16) : (i += 1) _ = try tx.putObject(list_id, .{ .index = i }, .map);
        _ = try tx.commit(null, null);
    }
    var patches = try doc.makePatches(&doc.patch_log);
    defer patches.deinit();
    const got = patches.slice();
    try testing.expect(got.len > 0);
    const last = got[got.len - 1];
    const ok = switch (last.action) {
        .put_seq => |a| a.index == 16,
        .insert => |a| a.index == 0 and a.values.len() == 17,
        else => false,
    };
    try testing.expect(ok);
}

// ── 122. regression_insert_opid
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):2363-2435

test "regression: an insert's operation ids" {
    var doc = try Document.init(gpa, .manual);
    defer doc.deinit();
    doc.setActorId(mintActor());
    const list_id = blk: {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        const l = try tx.putObject(root, .{ .key = "list" }, .list);
        _ = try tx.commit(null, null);
        break :blk l;
    };
    const n: usize = 30;
    {
        var tx = try Tx.open(gpa, &doc);
        defer tx.deinit();
        var i: usize = 0;
        while (i <= n) : (i += 1) {
            _ = try tx.insert(list_id, i, .null_value);
            _ = try tx.put(list_id, .{ .index = i }, .{ .int = @intCast(i) });
        }
        _ = try tx.commit(null, null);
    }
    // **Upstream's shape is a second document, not this one**
    // ([`test.rs`:2383-2390](../github-automerge-automerge/rust/automerge/tests/test.rs)):
    // a fresh `Automerge` and a fresh `PatchLog::active()` fed both changes.
    // The port carries the log on the document
    // ([`doc.zig`](../src/doc.zig), `Document.patch_log`), so the same shape is
    // a second document whose own log is made active directly.
    //
    // **There is no [`Document.updateDiffCursor`](../src/doc.zig) here, and
    // its absence is the point.** It turns the log on and *truncates* it
    // ([`autocommit.rs`:203-204](../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
    // and truncate clears the events, the expose set and the completed
    // patches ([`patch_log.rs`:531-538](../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)).
    // Called between the two commits — which is where it used to sit, between
    // the `PutMap` commit and the edits — it throws away the `PutMap` patch,
    // and the failure that follows reads as a patch the port never emitted
    // rather than a log the test threw away. Upstream's
    // `regression_insert_opid` does not make the call, and the oracle settles
    // it in both shapes: `diff`/`insertopid-cursor` emits **no** `PutMap`,
    // `diff`/`insertopid-applylog` emits exactly the two patches asserted
    // below. Two independent reasons the first commit is invisible in the
    // cursor shape, and only one of them — that the log was never on when the
    // first change was committed — is visible from this file.
    var all = try doc.getChanges(gpa, &.{});
    defer all.deinit(gpa);
    var fresh = try Document.init(gpa, .manual);
    defer fresh.deinit();
    fresh.patch_log.deinit();
    fresh.patch_log = .active(gpa);
    for (all.slice()) |b| _ = try fresh.applyChanges(gpa, &.{b.change});
    var patches = try fresh.makePatches(&fresh.patch_log);
    defer patches.deinit();
    const got = patches.slice();
    // Upstream asserts the whole `Vec<Patch>` (`test.rs:2434`), not a count.
    try testing.expectEqual(@as(usize, 2), got.len);
    // The make of the list, then the whole list in one insert. **The `PutMap`
    // is the patch with the empty path** (`test.rs:2418`) — and the insert's
    // is the one with a path (`test.rs:2430`), so the two lengths are not
    // interchangeable and reading either off the wrong patch still compiles.
    try testing.expectEqual(@as(usize, 0), got[0].path.len);
    try testing.expect(got[0].obj.eql(root));
    try testing.expect(got[0].action == .put_map);
    try testing.expectEqualStrings("list", got[0].action.put_map.key);
    try testing.expectEqual(ObjType.list, got[0].action.put_map.value.object);
    try testing.expect(got[0].action.put_map.obj.eql(list_id));
    try testing.expect(!got[0].action.put_map.conflict);
    try testing.expectEqual(@as(usize, 1), got[1].path.len);
    try testing.expect(got[1].path[0].obj.eql(root));
    try testing.expectEqualStrings("list", got[1].path[0].prop.key);
    try testing.expect(got[1].obj.eql(list_id));
    try testing.expect(got[1].action == .insert);
    try testing.expectEqual(@as(usize, 0), got[1].action.insert.index);
    try testing.expectEqual(n + 1, got[1].action.insert.values.len());
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const value = got[1].action.insert.values.get(i).?;
        try testing.expect(value.value.scalar.eql(.{ .int = @intCast(i) }));
        try testing.expect(!value.conflict);
        // **The operation id is the whole of this test** (`test.rs:2411`):
        // the op that carried element `i` is the put, the one after the insert
        // it replaced, so it counts `2 * (i + 1) + 1`. Read through
        // [`ExId.counter`](../src/types.zig), because the id on a patch value
        // is a `.named` [`ExId`] and carries the actor's bytes
        // (`exid.rs:15-18`) — reading `.id` off one traps rather than fails.
        try testing.expectEqual(@as(u32, @intCast(2 * (i + 1) + 1)), value.obj.counter().?);
    }
    // Upstream reads every index back out of **both** documents
    // (`test.rs:2392-2404`): the one that made the changes and the one that
    // applied them.
    i = 0;
    while (i <= n) : (i += 1) {
        const want: i64 = @intCast(i);
        try testing.expectEqual(want, (try scalarAt(&doc, list_id, .{ .index = i })).int);
        try testing.expectEqual(want, (try scalarAt(&fresh, list_id, .{ .index = i })).int);
    }
}

// ── 123. failed_merge_with_duplicate_sequence_number_does_not_corrupt_save_load
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3528-3556

test "a failed merge with a duplicate sequence number does not corrupt save and load" {
    var left = try newDocWithActor(.{ .bytes = "\x00" });
    defer left.deinit();
    var right = try forkDoc(&left);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x01" });

    _ = try am.transaction.putObject(&right, root, .{ .key = "k" }, .map);
    right.setActorId(.{ .bytes = "\x00" });
    _ = try am.transaction.putObject(&right, root, .{ .key = "k" }, .map);

    _ = try am.transaction.put(&left, root, .{ .key = "k" }, .{ .str = "a" });

    try testing.expectError(error.DuplicateSeqNumber, left.merge(gpa, &right));

    var before = try hydrateNow(&left);
    defer before.deinit();
    const saved = try left.save(gpa);
    defer gpa.free(saved);
    var loaded = try Document.load(gpa, saved, .unicode_code_point, .auto);
    defer loaded.deinit();
    var after = try hydrateNow(&loaded);
    defer after.deinit();
    try testing.expect(after.eql(&before));
}

// ── 124. queued_orphan_need_does_not_block_unrelated_sync_response
//      [`test.rs`](../github-automerge-automerge/rust/automerge/tests/test.rs):3721-3780

test "a queued orphan need does not block an unrelated sync response" {
    var left = try newDocWithActor(.{ .bytes = "\x00" });
    defer left.deinit();
    _ = try am.transaction.put(&left, root, .{ .key = "base" }, .{ .uint = 0 });
    const base = try left.save(gpa);
    defer gpa.free(base);

    var orphan_source = try forkDoc(&left);
    defer orphan_source.deinit();
    orphan_source.setActorId(.{ .bytes = "\x01" });
    _ = try am.transaction.put(&orphan_source, root, .{ .key = "missing" }, .{ .uint = 1 });
    const orphan1 = try headsOf(&orphan_source);
    defer gpa.free(orphan1);
    const missing = orphan1[0];

    _ = try am.transaction.put(&orphan_source, root, .{ .key = "orphan" }, .{ .uint = 2 });
    const orphan2 = try headsOf(&orphan_source);
    defer gpa.free(orphan2);
    const orphan_head = orphan2[0];
    const missing_slice = try gpa.dupe(ChangeHash, &.{missing});
    defer gpa.free(missing_slice);
    var orphan_changes = try orphan_source.getChanges(gpa, missing_slice);
    defer orphan_changes.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), orphan_changes.len());

    // A change whose dependency is absent is a valid intermediate sync state:
    // the receiver advertises the missing dependency in its next `need`.
    //
    // The message built below **owns both** of the two things it is handed,
    // because `receiveSyncMessage` consumes it: `heads` moves into the peer's
    // `State` ([`sync.rs`:460](../github-automerge-automerge/rust/automerge/src/sync.rs)) and `changes` is joined and
    // freed with the message ([`:420-422`](../github-automerge-automerge/rust/automerge/src/sync.rs), [`:395-402`](../github-automerge-automerge/rust/automerge/src/sync.rs)). `built.body` is owned
    // by the `Built` and is freed by `Changes.deinit`, so the chunk list holds
    // copies. `toOwnedSlice` leaves `payloads` empty, so the `defer` above is a
    // no-op on the list and the message is the only owner of the array.
    //
    // **Each payload is framed as a change chunk, and that is upstream's
    // `change.raw_bytes()`.** `Message::changes` is documented as "a `Vec` of
    // bytes which should be passed to `Automerge::load_incremental`. The
    // reason it is a `Vec<Vec<u8>>` and not a `Vec<u8>` is that the V1
    // message format is a sequence of **change chunks**, each of which is
    // length delimited" ([`sync.rs`:537-542](../github-automerge-automerge/rust/automerge/src/sync.rs)), and the
    // test writes exactly that ([`test.rs`:3750-3754](../github-automerge-automerge/rust/automerge/tests/test.rs)). Upstream's
    // `Change::raw_bytes` is `self.stored.bytes()` ([`change.rs`:118-120](../github-automerge-automerge/rust/automerge/src/change.rs)), and
    // `StoredChange::parse_following_header` fills that from the **whole**
    // chunk input, header included
    // ([`storage/change.rs`:133-137](../github-automerge-automerge/rust/automerge/src/storage/change.rs)).
    //
    // The port's `Built.body` is that byte range **without** the chunk header:
    // it is the change's own header (deps, actor, seq, start op, columns) and
    // nothing else, which is also exactly what the change hash is taken over
    // (`SHA-256(0x01 ‖ uleb128(len) ‖ body)`). Measured on this document it
    // begins `01 5d 92 f0 9d 3d 93 4f`, and
    // [`am.storage.chunk.parseChunks`](../src/storage/chunk.zig) answers
    // `error.InvalidMagic` for it — so the unframed form was feeding the
    // receiver bytes no automerge reader would accept. [`writeChunk`] is the
    // port's spelling of `raw_bytes()`, and this file already uses it at the
    // `load_incremental with a partial load` case below.
    const orphan_head_slice = try gpa.dupe(ChangeHash, &.{orphan_head});
    var payloads: std.ArrayList([]u8) = .empty;
    defer payloads.deinit(gpa);
    for (orphan_changes.slice()) |built| {
        var framed: std.ArrayList(u8) = .empty;
        defer framed.deinit(gpa);
        try am.storage.chunk.writeChunk(&framed, gpa, .change, built.body);
        try payloads.append(gpa, try framed.toOwnedSlice(gpa));
    }
    const orphan_message: am.sync.message.Message = .{
        .gpa = gpa,
        .heads = orphan_head_slice,
        .need = &.{},
        .have = &.{},
        .changes = .{ .items = try payloads.toOwnedSlice(gpa), .gpa = gpa },
        .flags = null,
        .version = .v1,
    };
    var one_shot = am.sync.state.State.new(gpa);
    defer one_shot.deinit();
    try am.sync.protocol.receiveSyncMessage(gpa, &left, &one_shot, orphan_message);
    const still_missing = try left.getMissingDeps(gpa, &.{});
    defer gpa.free(still_missing);
    try testing.expectEqual(@as(usize, 1), still_missing.len);
    try testing.expect(still_missing[0].eql(missing));

    var right = try Document.load(gpa, base, .unicode_code_point, .auto);
    defer right.deinit();
    right.setActorId(.{ .bytes = "\x02" });
    _ = try am.transaction.put(&right, root, .{ .key = "right" }, .{ .uint = 3 });
    const right_heads = try headsOf(&right);

    var state = am.sync.state.State.new(gpa);
    defer state.deinit();
    // **The three peer fields are owned by the state**, so each of these hands
    // its slice over rather than borrowing it. Upstream's `State` owns them
    // too — `their_have: Option<Vec<Have>>`
    // ([`sync.rs`:459-461](../github-automerge-automerge/rust/automerge/src/sync.rs)) — and upstream writes
    // `Some(vec![...])`, a fresh allocation, where the port's own
    // [`State.new`] writes `try gpa.alloc(Have, 0)`
    // ([`state.zig`](../src/sync/state.zig)) for the empty `have`. A borrowed
    // `&.{}` is the one thing neither side would write, and
    // [`State.deinit`] would hand it to `gpa.free`.
    state.their_heads = right_heads;
    state.their_need = try gpa.dupe(ChangeHash, &.{missing});
    state.their_have = try gpa.alloc(am.sync.state.Have, 0);
    const message_opt = try am.sync.protocol.generateSyncMessage(gpa, &right, &state);
    var message_storage: ?am.sync.message.Message = message_opt;
    defer if (message_storage) |*m| m.deinit();
    // Right still advertises its heads even though it cannot satisfy the orphan
    // dependency.
    try testing.expect(message_storage != null);
    try testing.expectEqualSlices(ChangeHash, right_heads, message_storage.?.heads);
}

// ── Zig 0.16.0 / upstream / Rust / port ───────────────────────────────────────
//
// What this file changed about upstream's, and why, in one place.
//
// ## The actors are named, not drawn
//
// `AutoCommit::new` takes its actor from `ActorId::random`
// ([`automerge.rs`:314](../github-automerge-automerge/rust/automerge/src/automerge.rs))
// and `automerge_test::new_doc` draws a fresh one per document
// ([`automerge-test/src/lib.rs`:11-15](../github-automerge-automerge/rust/automerge-test/src/lib.rs)).
// Upstream can afford that because a failure is re-run until it is not flaky;
// a port cannot, so [`mintActor`] hands out `01 00 …`, `02 00 …` and
// [`sortedActors`] writes down `aaaaaaaa` / `bbbbbbbb`. **The property each test
// wants is the order, and the order is preserved.** Upstream's `const B: usize =
// 16` (`test.rs`:11) is the literal it is, at each of its three uses.
//
// ## `RealizedObject` is a literal and a canonical string
//
// `assert_doc!` and `assert_obj!`
// ([`automerge-test/src/lib.rs`:89-113](../github-automerge-automerge/rust/automerge-test/src/lib.rs))
// compare a fully hydrated document against a `map!` / `list!` literal. Here the
// literal is [`Exp`] and the document is [`Node`], and the comparison is one
// canonical rendering of each side. **Set semantics are preserved and are the
// whole point**: `realize_values` collects a register's values into a `BTreeSet`
// and `map!` collects a literal's into a `BTreeSet`, so two operations carrying
// the same value are **one** value (`test_overwriting_a_conflict`) and the order
// either side was written in does not matter. The canonical order is the
// lexicographic order of the rendered text rather than upstream's
// `OrdScalarValue` declaration order — **any total order answers a set
// comparison**, and this one makes the sort key the finished value, so the
// recursion has no fixed point to establish.
//
// **The rendering is type-tagged and that is a change of substance, not of
// shape.** Upstream's `OrdScalarValue::serialize` prints a number as a bare
// number, so `Int(1)` and `Uint(1)` would render alike and deduplicate into one
// value; a test would then pass that should not. `renderScalar` therefore
// writes `int:`, `uint:`, `counter:`, `ts:`, `f64:` and `bytes:` prefixes, and a
// float by its bit pattern so that `-0.0` and `0.0` do not render alike.
//
// ## `hydrate` is reached through the op set
//
// Upstream's `ReadDoc::hydrate(&self, obj, heads)` is a method; the port reaches
// the same mirror through [`hydrate.hydrateMap`](../src/hydrate.zig), which
// takes the op set and an optional clock, so [`hydrateAt`] names the pair once.
// `Document.ops` and `ChangeGraph.clockAt` are public, so nothing here reaches
// into a private. **The port's [`Mirror`] has no `clone`**, so the two
// "expected" hydrations in `diff_incremental_respects_isolated_heads_from_fuzz_trace`
// are two hydrations rather than a clone of one; a hydration is a pure read, so
// the second is the same value from the same bytes.
//
// ## `merge_and_log_patches` and `make_patches` are `updateDiffCursor` and `doc.patch_log`
//
// Upstream hands a merge a fresh `PatchLog` and reads the patches off it
// afterwards. The port has one document with the log on it
// ([`doc.zig`](../src/doc.zig), `Document.patch_log`) and the only way to turn
// that log on is [`Document.updateDiffCursor`](../src/doc.zig)
// ([`autocommit.rs`:199-206](../github-automerge-automerge/rust/automerge/src/autocommit.rs)).
// [`patchesFrom`] is that pair: start the cursor, do the work, take the
// document's own log.
//
// **That only works for an *apply*, and two tests say so where they cannot.**
// `Document.commit` does not feed the log ([`doc.zig`](../src/doc.zig): only
// `applyChanges` branches on `patch_log.isActive()`, at `:3372`), so a *local*
// transaction has no patch stream to read back.
// `transaction_patches_replace_multi_character_string_in_text_from_fuzz_trace`
// takes its patches from [`Document.diff`](../src/doc.zig) over the two head
// lists instead — which is `AutoCommit::diff` rather than `make_patches`, and
// is the whole of that deviation: the assertion is about the patch content for
// one known change, and `doc.diff` is what the port can answer it with.
//
// ## A fork goes through `forkAt`
//
// **Upstream's `doc.fork()` is `Document.forkAt(gpa, heads, .auto)` in the
// port, and that is not cosmetic: `Document.fork` leaks.**
// [`Document.fork`](../src/doc.zig):3827-3830 stores
// `ActorId.random(gpa)` — sixteen bytes taken from `gpa` — in `actor.unused`,
// and `Document.deinit` frees no actor bytes because a caller may have handed
// `setActorId` a string literal. `Document.forkAt` does the same work correctly
// (`:3883-3891`): it copies the minted bytes into the fork's own arena and
// frees the temporary. Forking at the current heads is what `fork` means, so
// every forked document below is forked the way that frees what it takes.
//
// ## A rollback is only expressible through the manual door
//
// Upstream's `AutoCommit` keeps **one** transaction open across mutating calls
// until something closes it ([`autocommit.rs`:445-462](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
// `ensure_transaction_open` / `ensure_transaction_closed`), which is why
// `doc3.rollback()` in `rollback_with_several_actors`
// ([`test.rs`:2798](../github-automerge-automerge/rust/automerge/tests/test.rs))
// undoes the five writes before it. **The port's autocommit door commits every
// mutating call** ([`transact.zig`](../src/transact.zig), every module-level
// function opens a transaction and commits it), so through it those five writes
// are five committed changes and no rollback reaches them. That test is
// therefore written against [`Transaction.open`](../src/transact.zig) on a
// `.manual` document, which is upstream's `Transaction::rollback` reached
// through `AutoCommit::transaction()`.
//
// ## `save()` bytes are compared as documents, not as bytes
//
// Upstream's `assert_eq!(doc1.save(), doc2.save())` appears three times here.
// DEFLATE is not reproducible across implementations ([AGENTS.md](../AGENTS.md)),
// so each is [`Document.debugCmp`](../src/doc.zig) — **the equivalence the port
// promises**, materialized document rather than byte string.
//
// ## Two assertions are additions, and one is a correction
//
// * `diff_preserves_conflict_after_winning_value_is_deleted_from_fuzz_trace`
//   ends with an `expectDoc` upstream does not have. It states the test's own
//   claim — the property is *still conflicted* — and the expected register is
//   `{false, null}`: `third.delete` removes the winning `-88`, which leaves the
//   two concurrent values that remain.
// * `inserting_text_near_deleted_marks` ends in upstream's `dbg!`, which asserts
//   nothing, and a bare "does not panic" proves nothing ([AGENTS.md](../AGENTS.md)).
//   The text is asserted instead, and it is `"aha"`: `"hello world"` is eleven
//   characters, deleting ten from index one leaves `"h"`, and the two inserts
//   make `"ah"` and then `"aha"` — which is what upstream's three `//` comments
//   say.
// * `get_marks_at_heads` reads `am.read.markSetAtIndex(..)` and
//   `tx.markSetAtIndex(..)` — upstream's `get_marks` with its heads — and both
//   returns are [`MarkSet`](../src/marks.zig)s, not `[]Mark`. The two reads the
//   port added around them (the mark before, the recorded patch, the mark gone
//   after) stay, with `null` heads, because they are the port's own statement
//   about the present.
//
// ## Not ported, with the reason
//
// Each is marked at its place in the file above with the API that is missing and
// what exists in its stead. In summary: the four `PatchLogMismatch` cases (the
// error exists in [`error.zig`](../src/error.zig) and nothing raises it, because
// the port has one document with one log); `bundle_with_mark_columns_decodes_from_fuzz_trace`
// and the bundle arm of `incremental_load_preserves_text_encoding_for_all_change_chunk_types`
// (no `Document.bundle`; the bundle *parser* is written);
// `current_state_diff_with_block_applies_to_hydrated_value_from_fuzz_trace` (the
// port's `Span.block` is an `ExId` and carries no map);
// `doc_iter_spans_skip_losing_conflicting_text_overwrites_after_object_shift`
// (no document-level `iter()`); `test_compressed_changes` (no deflated change
// chunk); `test_change_encoding_expanded_change_round_trip` (half of it — no
// `ExpandedChange`); `save_and_load_incremented_counter` and
// `round_trip_change_with_extra_bytes` (`ExpandedChange` and serde);
// `has_our_changes` (no such function); the three `duplicate_seq_number_*`
// cases (no `apply_changes_batch`); and the four fixture-driven cases
// (`fuzz_crashers`, `overlong_leb`, `load`, `obj_id_64bits`), which
// [`test/fixtures_test.zig`](fixtures_test.zig) and the fixture table
// [`doc.zig`](../src/doc.zig):4889-4892 spells out already cover, and which
// would need a working-directory contract this file does not otherwise have.
//
// ## Nine corrections, each derived from the reference
//
// These are transcription faults, not expectations adjusted to the port's
// output. Each says at its place in the file above what the reference does
// and why the port's reading of it was impossible; the short form:
//
// * `transaction_patches_insert_hidden_scalar_into_utf8_text_from_fuzz_trace`
//   built its value on a `.manual` document and then called the autocommit
//   door `batchCreateValue`, which refuses one ([`transact.zig`](../src/transact.zig)).
//   Upstream is `AutoCommit` there
//   ([`test.rs`:4290](../github-automerge-automerge/rust/automerge/tests/test.rs)); the mode flag moved to `.auto`.
// * `save_with_ops_which_reference_actors_only_via_delete` opened a **manual**
//   transaction on a fork that [`forkDoc`] makes `.auto`. Upstream forks an
//   `Automerge` ([`test.rs`:2813](../github-automerge-automerge/rust/automerge/tests/test.rs)) and uses
//   `Automerge::transact`; [`forkDocMode`] is the port's spelling of that type.
//   The test also gained the assertion upstream's comment promises and does not
//   make — the actor count across the round trip.
// * `queued_orphan_need_does_not_block_unrelated_sync_response` put
//   [`Document.Built.body`](doc.zig) straight into `Message.changes`. Upstream
//   sends `change.raw_bytes()`, which is the **chunk**
//   ([`sync.rs`:537-542](../github-automerge-automerge/rust/automerge/src/sync.rs), [`test.rs`:3750-3754](../github-automerge-automerge/rust/automerge/tests/test.rs)), and
//   `Built.body` is the chunk *body* — measured here as 69 bytes beginning
//   `01 5d 92 f0 9d 3d 93 4f`, which `parseChunks` answers `InvalidMagic`
//   for. [`writeChunk`] is the port's `raw_bytes()`. The test also hands the
//   [`State`](sync/state.zig) its own copies of `their_heads`, `their_need`
//   and `their_have`, because the state owns them.
// * `a transaction can be opened at historical heads` read `scalarAt(&doc1, …)`
//   where upstream reads `tx.get(&ROOT, "size")`; it now reads
//   [`Transaction.get`](../src/transact.zig) through [`scalarIn`], at
//   [`test.rs`:2517, :2521, :2526, :2530, :2537, :2541](../github-automerge-automerge/rust/automerge/tests/test.rs)
//   — **four of the six pass** and the test is still red on the two inside the
//   **third** transaction, where the cause is the isolation machinery and not
//   the read: with every `tx.get` in this file removed the same transaction
//   answers `tx.textFor` = `"aaaZZZccc"` where upstream's `:2536` is
//   `"aaabbbccc"`. The defect is named where it is asserted.
// * `get_marks_at_heads` called `getMarks(&doc, text_id, 1, 1, gpa)` — `from`
//   equal to `max`, which returns `&.{}` by construction
//   ([`read.zig`](../src/read.zig)) — and then asserted one mark; it now calls
//   `markSetAtIndex(..)` with upstream's `heads`
//   ([`test.rs`:2700, :2708](../github-automerge-automerge/rust/automerge/tests/test.rs))
//   and **passes**. The windowed `getMarks` is still there for the port's own
//   present-time reads, and [`read.zig`](../src/read.zig) says which of the two
//   is upstream's.
// * [`headsOf`] read [`Document.getHeads`](doc.zig) — upstream's
//   **`Automerge::get_heads`** — where every case that writes `doc.get_heads()`
//   is calling it on an `AutoCommit`, so it is **`AutoCommit::get_heads`**
//   (`autocommit.rs:695-700`) and answers the **isolation** first. It reads
//   while isolated only in
//   `incremental_diff_discards_edits_inside_deleted_map`
//   ([`test.rs`:4024-4028](../github-automerge-automerge/rust/automerge/tests/test.rs)),
//   where upstream's `after` is `before_delete` and not the deletion change
//   that follows it. Measured: the reference emits one `SpliceText`, the port
//   emitted three because `diff_incremental` then took the recorded-log arm.
// * `a document can be isolated and integrated` wrote
//   `try testing.expectEqualStrings(want, try am.read.text(doc, obj, gpa))` seven
//   times. [`am.read.text`](../src/read.zig) returns a **caller-owned** string
//   and an expression drops it, which `std.testing.allocator` reports as one
//   leaked test. [`expectText`] frees it; **no assertion changed**.
// * `load_incremental does not skip a load with a common head` read
//   `(try headsOf(&doc1)).len` and dropped the slice. That was a leak
//   `std.testing.allocator` reported; the assertion is unchanged.
// * `regression: an insert's operation ids` was transcribed from a **different
//   scenario than the one it ran in**: it called [`Document.updateDiffCursor`]
//   (../src/doc.zig) between the two commits and read the patches off *this*
//   document's log, where upstream
//   ([`test.rs`:2383-2390](../github-automerge-automerge/rust/automerge/tests/test.rs))
//   builds a **second** document and a fresh `PatchLog::active()`. The cursor
//   call truncates the log ([`autocommit.rs`:203-204](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
//   [`patch_log.rs`:531-538](../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)),
//   so the `PutMap` patch was gone — **and** the first change was committed
//   while the log was still inactive, so its events were never recorded either.
//   Two independent reasons, and the second one is invisible from the test.
//   The oracle settles it in both shapes: `diff`/`insertopid-cursor` emits
//   **no** `PutMap`, `diff`/`insertopid-applylog` emits the two patches
//   [`test.rs`:2415-2433](../github-automerge-automerge/rust/automerge/tests/test.rs)
//   asserts, and the port reproduces them byte for byte in that shape. The test
//   now asserts the **operation ids** `2 * (i + 1) + 1` through
//   [`ExId.counter`](../src/types.zig) — the id on a patch value is a
//   **`.named`** `ExId` carrying the actor's bytes (`exid.rs:15-18`), so the
//   `.id` the old transcription read would have **trapped** — and the two
//   patch shapes: the `PutMap` is the patch with the **empty** path and the
//   insert's path is **length one** (`test.rs:2418`, `:2430`), which the old
//   `got[1].path.len == 0` had the wrong way round. A patch **count** is not
//   the assertion; upstream's is whole-`Vec<Patch>` equality, and the ids are
//   what this test is named for.
//
// ## `Document.load` and `Document.loadIncremental` now differ in kind
//
// Upstream's `OnPartialLoad` ([`automerge.rs`:74-81](../github-automerge-automerge/rust/automerge/src/automerge.rs))
// is a contract, not a tolerance knob: `Automerge::load` defaults to
// `.error`, `load_incremental` passes `.ignore` on its empty-document branch
// ([`:1038-1045`](../github-automerge-automerge/rust/automerge/src/automerge.rs)) and **always** ignores
// the error on the non-empty one ([`:1060-1064`](../github-automerge-automerge/rust/automerge/src/automerge.rs)). The port
// had one all-or-nothing path for both, so a save with rubbish appended was a
// refusal where upstream answers with the document. [`Document.load`](doc.zig) is
// still the refusal — **`Document.loadIncremental` is not**, and a caller
// that relied on it reporting a truncated stream has lost that.
