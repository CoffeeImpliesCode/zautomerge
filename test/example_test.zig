//! The crate-root address book, as a permanent test.
//!
//! `automerge`'s own crate docs open with an example: a document that
//! represents an address book — a `contacts` list in the root map, one map per
//! contact, a name and an email on each
//! ([`lib.rs:113-143`](../github-automerge-automerge/rust/automerge/src/lib.rs)).
//! This file runs that session through the port and then does what a real
//! consumer does next: gives a contact two addresses, reads them, removes one,
//! and reads the saved document back.
//!
//! Every other test in this tree drives **one module** with a hand-built
//! fixture. This one drives **the crate**, through `@import("zautomerge")` and
//! nothing else: no `OpSet`, no column, no spliced fixture anywhere below. It
//! is the test that fails when the pieces do not compose, and composition
//! failures are what a module-at-a-time port produces.

const std = @import("std");

/// The module under test, imported by the name a consumer imports it by.
const am = @import("zautomerge");

const testing = std.testing;

/// **The leak arbiter for the whole session.** One allocator, named once, and
/// every owned value below comes out of it: the document, the saved bytes, the
/// loaded document, and each copy a list read hands back.
const gpa = testing.allocator;

/// The borrowed capability every document constructor below is handed.
///
/// **Explicit, because `Document` keeps it.** The op set draws actors through
/// this value for as long as the document lives, so a constructor cannot
/// reach for an ambient global and no document can outlive its provider. Here
/// that value is `std.testing.io`; an executable passes its own `init.io`.
const io = std.testing.io;

const Allocator = std.mem.Allocator;

const Document = am.AutoCommit;
const ExId = am.ExId;
const ObjType = am.ObjType;

/// A list of strings the test owns.
///
/// **The copy is the point.** A [`read.ListRange`] and every item it hands out
/// borrow document storage until mutation. A test that reads a list and then
/// writes to the document copies the strings it needs to retain.
/// Reading a stale reader instead would be reading bytes the document may
/// have moved, so this test reads a **fresh** reader after every write and
/// asserts the copies taken before it afterwards.
const Strings = struct {
    gpa: Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn init(list: Allocator) Strings {
        return .{ .gpa = list };
    }

    fn deinit(self: *Strings) void {
        for (self.items.items) |s| self.gpa.free(s);
        self.items.deinit(self.gpa);
    }

    /// The element at `index`.
    fn at(self: *const Strings, index: usize) []const u8 {
        return self.items.items[index];
    }
};

/// Every visible element of the list `obj`, copied out as a string.
///
/// `read.objectType` answers what the reader is about to walk, so a
/// non-sequence is refused here rather than walked as an empty list.
fn snapshot(list: Allocator, doc: *Document, obj: ExId) !Strings {
    if (try am.read.objectType(doc, obj) != .list) return error.NotAList;
    var out = Strings.init(list);
    errdefer out.deinit();
    var walk = try am.read.listRange(doc, obj, am.read.IndexRange.all());
    while (try walk.next()) |item| {
        switch (item.value) {
            .scalar => |s| switch (s) {
                .str => |text| try out.items.append(list, try list.dupe(u8, text)),
                else => return error.NotAString,
            },
            .object => return error.NotAString,
        }
    }
    return out;
}

/// The scalar at `key`, or `error.NoSuchKey` when the key is absent and
/// `error.NotAnObject` when it holds one.
fn scalar(doc: *Document, obj: ExId, key: []const u8) !am.ScalarValue {
    const item = (try am.read.get(doc, obj, .{ .key = key })) orelse return error.NoSuchKey;
    return switch (item.value) {
        .scalar => |s| s,
        .object => error.NotAnObject,
    };
}

/// The id of the object at `key`, or `error.NoSuchKey` when the key is absent
/// and `error.NotAnObject` when it holds a scalar.
///
/// **This is the reference's own shape.** Upstream's second example matches
/// `Value::Object(ObjType::List, contacts)` out of `get`
/// ([`lib.rs:164-171`](../github-automerge-automerge/rust/automerge/src/lib.rs)),
/// and a make action's own id *is* the id of the object it makes, so the id is
/// the second field of the pair `get` returns ([`read.DocItem`](../src/read.zig),
/// `op_set.rs:1054-1060`).
fn objectId(doc: *Document, obj: ExId, key: []const u8) !ExId {
    const item = (try am.read.get(doc, obj, .{ .key = key })) orelse return error.NoSuchKey;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

/// The id of the element at `index` of the sequence `obj`, or
/// `error.NoSuchElement` when the sequence is shorter than that.
fn elementId(doc: *Document, obj: ExId, index: usize) !ExId {
    const item = (try am.read.get(doc, obj, .{ .index = index })) orelse return error.NoSuchElement;
    return switch (item.value) {
        .object => item.id,
        .scalar => error.NotAnObject,
    };
}

test "the address book: the crate-root example, run as a consumer runs it" {
    // A new document in the autocommit flavour, which is upstream's
    // `AutoCommit::new`
    // ([`autocommit.rs:92-94`](../github-automerge-automerge/rust/automerge/src/autocommit.rs),
    // [`AutoCommit`](../src/autocommit.zig)). Mutations share a held transaction;
    // ordinary reads observe pending writes, and save closes the transaction.
    var doc = try Document.init(gpa, io);
    defer doc.deinit();
    // **A named actor**, because a random one would make a failure
    // unreproducible. Upstream draws one at random
    // ([`automerge.rs:314`](../github-automerge-automerge/rust/automerge/src/automerge.rs));
    // this document takes its bytes from its caller
    // ([`doc.zig:2227-2232`](../src/doc.zig)).
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });

    // `putObject` creates a nested object in the root key/value map and returns
    // the id of the new object, in this case a list
    // ([`Transactable::put_object`](../github-automerge-automerge/rust/automerge/src/transaction/transactable.rs):33-39).
    const contacts = try doc.putObject(am.root, .{ .key = "contacts" }, .list);

    // Now we can insert objects into the list, and finally set keys in the map
    // each one is (`lib.rs:127-132`).
    const alice = try doc.insertObject(contacts, 0, .map);
    _ = try doc.put(alice, .{ .key = "name" }, .{ .str = "Alice" });
    _ = try doc.put(alice, .{ .key = "email" }, .{ .str = "alice@example.com" });

    // **The addresses.** The reference's example has no list to remove from,
    // and a removal step is what makes the session worth running: a document
    // that only ever grows is a document nobody has ever had to fix.
    const alice_addresses = try doc.putObject(alice, .{ .key = "addresses" }, .list);
    _ = try doc.insert(alice_addresses, 0, .{ .str = "1 Main St" });
    _ = try doc.insert(alice_addresses, 1, .{ .str = "PO Box 12" });

    // **A map key is not a sequence index**, so making a nested object under a
    // key of a list is refused rather than answered. This line is not part of
    // the example. It is here so that everything the example says about
    // `alice_addresses` from here down is a statement about a sequence and not
    // about an object that happens to accept the same calls
    // ([`Transaction.putObject`](../src/transact.zig), `inner.rs:285-289`).
    try testing.expectError(
        error.InvalidOp,
        doc.putObject(alice_addresses, .{ .key = "work" }, .map),
    );

    // Create another contact (`lib.rs:134-137`), with one address of its own,
    // so the removal below has an untouched neighbour to be measured against.
    const bob = try doc.insertObject(contacts, 1, .map);
    _ = try doc.put(bob, .{ .key = "name" }, .{ .str = "Bob" });
    _ = try doc.put(bob, .{ .key = "email" }, .{ .str = "bob@example.com" });
    _ = try doc.put(bob, .{ .key = "zip" }, .{ .uint = 94110 });
    const bob_addresses = try doc.putObject(bob, .{ .key = "addresses" }, .list);
    _ = try doc.insert(bob_addresses, 0, .{ .str = "22 Rue Verte" });

    // The premises, asked through the document rather than through a reader's
    // answer: two contacts, a map for each, and a list for the addresses.
    try testing.expectEqual(ObjType.map, try am.read.objectType(&doc, alice));
    try testing.expectEqual(ObjType.list, try am.read.objectType(&doc, alice_addresses));
    try testing.expectEqual(@as(usize, 2), try am.read.length(&doc, contacts));
    try testing.expectEqualStrings("Alice", (try scalar(&doc, alice, "name")).str);
    try testing.expectEqualStrings("alice@example.com", (try scalar(&doc, alice, "email")).str);
    try testing.expectEqualStrings("Bob", (try scalar(&doc, bob, "name")).str);
    try testing.expectEqualStrings("bob@example.com", (try scalar(&doc, bob, "email")).str);
    // **A scalar that is not a string**, so the session is not a session of
    // strings that happen to carry the right letters.
    try testing.expectEqual(@as(u64, 94110), (try scalar(&doc, bob, "zip")).uint);

    // Read Alice's addresses, and keep the copy.
    var before = try snapshot(gpa, &doc, alice_addresses);
    defer before.deinit();
    try testing.expectEqual(@as(usize, 2), before.items.items.len);
    try testing.expectEqualStrings("1 Main St", before.at(0));
    try testing.expectEqualStrings("PO Box 12", before.at(1));

    // Read Bob's, and keep that copy too, because the removal must leave them
    // alone and a copy taken before the removal is the only version of them
    // that the removal is not being judged against.
    var bob_before = try snapshot(gpa, &doc, bob_addresses);
    defer bob_before.deinit();
    try testing.expectEqual(@as(usize, 1), bob_before.items.items.len);
    try testing.expectEqualStrings("22 Rue Verte", bob_before.at(0));

    // **The removal.** `delete` reports how many delete operations it wrote,
    // which is one for a list element ([`Transaction.delete`](../src/transact.zig),
    // `inner.rs:573-598`).
    try testing.expectEqual(@as(usize, 1), try doc.delete(alice_addresses, .{ .index = 0 }));

    // **The copies taken before the write still hold their bytes**, which is the
    // whole of what "the copy is the caller's" means
    // ([`ListRangeItem.intoOwned`](../src/iter/list_range.zig), `list_range.rs:30-37`).
    try testing.expectEqual(@as(usize, 2), before.items.items.len);
    try testing.expectEqualStrings("1 Main St", before.at(0));
    try testing.expectEqualStrings("PO Box 12", before.at(1));

    // **A fresh reader**, because the reader from before the write is over a
    // document that has moved under it. One entry, and it is the one that was
    // not removed: a delete on a sequence removes the element at that index and
    // leaves the rest in order.
    var after = try snapshot(gpa, &doc, alice_addresses);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 1), after.items.items.len);
    try testing.expectEqualStrings("PO Box 12", after.at(0));
    try testing.expectEqual(@as(usize, 1), try am.read.length(&doc, alice_addresses));

    // **The other person is untouched**, asked through a fresh reader as well:
    // the addresses, the length, the keys beside them, and the contact list
    // the addresses hang off.
    var bob_after = try snapshot(gpa, &doc, bob_addresses);
    defer bob_after.deinit();
    try testing.expectEqual(@as(usize, 1), bob_after.items.items.len);
    try testing.expectEqualStrings("22 Rue Verte", bob_after.at(0));
    try testing.expectEqual(@as(u64, 94110), (try scalar(&doc, bob, "zip")).uint);
    try testing.expectEqualStrings("Bob", (try scalar(&doc, bob, "name")).str);
    try testing.expectEqual(@as(usize, 2), try am.read.length(&doc, contacts));
    try testing.expectEqualStrings("alice@example.com", (try scalar(&doc, alice, "email")).str);

    // Now we save the address book, we can put this in a file (`lib.rs:139`).
    const data = try doc.save(gpa);
    defer gpa.free(data);

    // … and read it back (`AutoCommit::load`, `autocommit.rs:127-138`).
    // **The encoding is an argument and not part of the file**, because a UTF-16
    // indexed document and a UTF-8 indexed one have identical bytes
    // ([`doc.zig:2767-2775`](../src/doc.zig)), so the answer is the same
    // [`Document.init`] call at the top of this test.
    var reloaded = try Document.load(gpa, io, data, am.doc.defaultTextEncoding());
    defer reloaded.deinit();

    // **The whole document, through the same public reads.** A save that lost a
    // contact, an address or a `uint` would be caught here and nowhere else:
    // every other test in this tree builds its fixture and never round-trips
    // one through the storage format.
    const again = try objectId(&reloaded, am.root, "contacts");
    try testing.expectEqual(ObjType.list, try am.read.objectType(&reloaded, again));
    try testing.expectEqual(@as(usize, 2), try am.read.length(&reloaded, again));

    const alice_again = try elementId(&reloaded, again, 0);
    try testing.expectEqual(ObjType.map, try am.read.objectType(&reloaded, alice_again));
    try testing.expectEqualStrings("Alice", (try scalar(&reloaded, alice_again, "name")).str);
    try testing.expectEqualStrings("alice@example.com", (try scalar(&reloaded, alice_again, "email")).str);
    // **The removal survived the round trip**, so it is in the saved bytes and
    // not only in the document that wrote them.
    var alice_again_addresses = try snapshot(gpa, &reloaded, try objectId(&reloaded, alice_again, "addresses"));
    defer alice_again_addresses.deinit();
    try testing.expectEqual(@as(usize, 1), alice_again_addresses.items.items.len);
    try testing.expectEqualStrings("PO Box 12", alice_again_addresses.at(0));

    const bob_again = try elementId(&reloaded, again, 1);
    try testing.expectEqual(ObjType.map, try am.read.objectType(&reloaded, bob_again));
    try testing.expectEqualStrings("Bob", (try scalar(&reloaded, bob_again, "name")).str);
    try testing.expectEqualStrings("bob@example.com", (try scalar(&reloaded, bob_again, "email")).str);
    try testing.expectEqual(@as(u64, 94110), (try scalar(&reloaded, bob_again, "zip")).uint);
    var bob_again_addresses = try snapshot(gpa, &reloaded, try objectId(&reloaded, bob_again, "addresses"));
    defer bob_again_addresses.deinit();
    try testing.expectEqual(@as(usize, 1), bob_again_addresses.items.items.len);
    try testing.expectEqualStrings("22 Rue Verte", bob_again_addresses.at(0));
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The example is upstream's, and it is the first block of the crate docs**
//   ([`lib.rs:113-143`](../github-automerge-automerge/rust/automerge/src/lib.rs)).
//   `AutoCommit` owns the raw `Document` and its held transaction, and the three
//   calls the example makes are `doc.putObject`, `doc.insertObject` and
//   `doc.put`, one for one.
//   The `addresses` list is the one addition, and the comment in the test says why.
//
// * **The second upstream example is not ported as a merge.** Upstream's second
//   block loads the saved bytes on two devices, edits each, and merges
//   ([`lib.rs:147-196`](../github-automerge-automerge/rust/automerge/src/lib.rs)).
//   A merge needs two actors, two change graphs and a clock between them, and
//   `sync` and `Document.merge` have their own tests. This file is the
//   save-and-load half of that example, which is the half with no other test: a
//   document round-tripped through the storage format and read back through the
//   public surface.
//
// * **`Prop` is one union here and a generic upstream.** Upstream takes
//   `impl Into<Prop>` and `impl Into<ScalarValue>`
//   ([`inner.rs:241-248`](../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//   so `doc.put(&alice, "name", "Alice")` reads as one call. Here it is
//   `doc.put(alice, .{ .key = "name" }, .{ .str = "Alice" })`
//   ([`types.Prop`](../src/types.zig):452-455), because a Zig union has no
//   implicit conversion from its payload and an argument that is "either a key
//   or an index" has to say which. **`ScalarValue` is the port's answer to
//   `Into<ScalarValue>` in the same position**, and it is why the two
//   conversions read as two struct literals rather than as one call with two
//   bare literals.
//
// * **The write door is the `AutoCommit` owner.** Upstream splits the
//   two representations across [`Automerge`] and [`AutoCommit`]
//   ([`lib.rs:15-24`](../github-automerge-automerge/rust/automerge/src/lib.rs)).
//   Raw `Document` writes use an explicit `Transaction`; automatic writes
//   use the owner methods and close only at publication barriers.
//
// * **[API.md](../API.md) §Document does not match the signatures, and this
//   file is the first thing to have to compile against both.** It writes
//   `init(gpa) Document` and `load(gpa, bytes) LoadError!Document`; constructors
//   also take the retained I/O capability, and load takes a text encoding.
//   The encoding is not a choice
//   this port made: it is not in the file, because a UTF-16 indexed document
//   and a UTF-8 indexed one have identical bytes
//   ([`:2767-2769`](../src/doc.zig)), so a load that guessed would be wrong
//   half the time. **`doc.defaultTextEncoding()` is the public way to get the
//   answer, and [API.md](../API.md) does not list it.** A caller that
//   hard-codes `.unicode_code_point` compiles and then breaks on the first
//   UTF-16 document; a caller that spells out `defaultTextEncoding()` has to
//   know it exists. It is public, so nothing here reaches into a private, but
//   the contract does not say so and the contract is what a reader has.

// ---------------------------------------------------------------------------
// The four map-range bound shapes: one document, two entry points, two clocks.
// ---------------------------------------------------------------------------

/// The C ABI as a Zig consumer of this module sees it. **`src/c/**` is
/// `extern "C"` over libc**, so this whole section needs the `link_libc` the
/// `example_tests` module is built with ([`build.zig:50-58`](../build.zig)):
/// [`cabi.c_allocator`] is a `@compileError` without it
/// ([`src/c/result.zig:1074-1077`](../src/c/result.zig)).
const cabi = am.c_abi.doc;
const cabi_result = am.c_abi.result;

/// The hash a change is named by, which is what a `heads` list is a list of
/// ([`types.zig`](../src/types.zig), `rust/automerge/src/change_hash.rs`).
const ChangeHash = am.ChangeHash;

/// One item of a map-range answer, as both readers report it.
///
/// **The three fields are the comparison, and the counter is one of them.**
/// The key and the value are what a caller reads. `ctr` is the row's own
/// operation counter ([`types.zig:175-177`](../src/types.zig)), which is what
/// says *which* row answered — so a reader that picked the same key and the
/// same value out of a **different** row does not pass. Two registers that
/// were written twice differ only in the row, and this fixture has one.
const Answered = struct {
    key: []const u8,
    value: []const u8,
    ctr: u64,
};

/// The C reader's answer for one item.
fn answeredC(out: []u8, item: *cabi.AMitem) !Answered {
    var key: cabi_result.AMbyteSpan = undefined;
    if (!cabi.AMitemKey(item, &key)) return error.CItemHasNoKey;
    const id = cabi.AMitemObjId(item) orelse return error.CItemHasNoId;
    return .{ .key = key.slice(), .value = try cValue(out, item), .ctr = id.counter };
}

/// The value one C item carries, as `tag:payload`.
///
/// **A tag this function cannot render is an error, not a `true`.** A
/// comparison that skipped the tags it did not know would pass on exactly
/// what it did not look at, and the fixture below uses only two tags — so
/// this is where a fixture change would otherwise go unnoticed.
///
/// **`AM_VAL_TYPE_ACTOR_ID` and `AM_VAL_TYPE_UNKNOWN` are the two tags left
/// unrendered, deliberately.** A stored actor id reaches a reader as the
/// value column's own bytes rather than as a resolved actor
/// ([`src/c/doc.zig:967-972`](../src/c/doc.zig) says so), and matching the
/// two spellings of that would be a second claim about the same bytes, not a
/// third reader.
fn cValue(out: []u8, item: *cabi.AMitem) ![]const u8 {
    return switch (cabi.AMitemValType(item)) {
        .AM_VAL_TYPE_NULL => "null",
        .AM_VAL_TYPE_BOOL => blk: {
            var v: bool = undefined;
            if (!cabi.AMitemToBool(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "bool:{}", .{v});
        },
        .AM_VAL_TYPE_INT => blk: {
            var v: i64 = undefined;
            if (!cabi.AMitemToInt(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "int:{d}", .{v});
        },
        .AM_VAL_TYPE_UINT => blk: {
            var v: u64 = undefined;
            if (!cabi.AMitemToUint(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "uint:{d}", .{v});
        },
        .AM_VAL_TYPE_F64 => blk: {
            var v: f64 = undefined;
            if (!cabi.AMitemToF64(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "f64:{d}", .{v});
        },
        .AM_VAL_TYPE_COUNTER => blk: {
            var v: i64 = undefined;
            if (!cabi.AMitemToCounter(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "counter:{d}", .{v});
        },
        .AM_VAL_TYPE_TIMESTAMP => blk: {
            var v: i64 = undefined;
            if (!cabi.AMitemToTimestamp(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "timestamp:{d}", .{v});
        },
        .AM_VAL_TYPE_STR => blk: {
            var v: cabi_result.AMbyteSpan = undefined;
            if (!cabi.AMitemToStr(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "str:{s}", .{v.slice()});
        },
        .AM_VAL_TYPE_BYTES => blk: {
            var v: cabi_result.AMbyteSpan = undefined;
            if (!cabi.AMitemToBytes(item, &v)) return error.CValueRefused;
            break :blk try std.fmt.bufPrint(out, "bytes:{x}", .{v.slice()});
        },
        else => error.CValueTagNotCompared,
    };
}

/// The Zig reader's answer for one item, in the same shape as [`answeredC`].
fn answeredZ(out: []u8, item: am.read.MapRangeItem) !Answered {
    return .{
        .key = item.key,
        .value = switch (item.value) {
            .object => |o| try std.fmt.bufPrint(out, "obj:{s}", .{@tagName(o)}),
            .scalar => |s| switch (s) {
                .null_value => "null",
                .bool_value => |x| try std.fmt.bufPrint(out, "bool:{}", .{x}),
                .int => |x| try std.fmt.bufPrint(out, "int:{d}", .{x}),
                .uint => |x| try std.fmt.bufPrint(out, "uint:{d}", .{x}),
                .float => |x| try std.fmt.bufPrint(out, "f64:{d}", .{x}),
                .counter => |x| try std.fmt.bufPrint(out, "counter:{d}", .{x.current}),
                .timestamp => |x| try std.fmt.bufPrint(out, "timestamp:{d}", .{x}),
                .str => |x| try std.fmt.bufPrint(out, "str:{s}", .{x}),
                .bytes => |x| try std.fmt.bufPrint(out, "bytes:{x}", .{x}),
                .actor_id => |x| try std.fmt.bufPrint(out, "actor:{s}", .{x.bytes}),
                .unknown => |x| try std.fmt.bufPrint(out, "unknown:{d}:{x}", .{ x.type_code, x.bytes }),
            },
        },
        .ctr = item.opId().counter,
    };
}

/// One key and value, as the table below writes them.
const KeyValue = struct { key: []const u8, value: []const u8 };

/// One bound shape, and the answer it has to give under each clock.
///
/// **`begin` and `end` are the C header's two parameters, and both are `null`
/// or neither** — that is all `AMmapRange` can be told, so it is all this
/// table can name. The four shapes are the reference's own `match
/// (begin.is_null(), end.is_null())` ([`automerge-c/src/doc/map.rs:518-554`](../github-automerge-automerge/rust/automerge-c/src/doc/map.rs)).
const Shape = struct {
    begin: ?[]const u8,
    end: ?[]const u8,
    /// The answer with no `heads`: the current state.
    at_now: []const KeyValue,
    /// The answer at the clock the fixture froze.
    at_past: []const KeyValue,
};

/// The four shapes, bounded by keys **the root map holds**.
///
/// **Both boundary keys are two rows wide, and that is what makes the four
/// arms distinguishable here.** `b` is written twice, once before the clock
/// and once after, and `d` twice before it. The rule is narrower than "two
/// rows" and this table satisfies both readings of it: an end's `Included`
/// and `Excluded` are the two ends of one range —
/// [`OpSet.mapRange`](../src/opset/op_set.zig) returns `propRange(s).start`
/// for one and `propRange(s).end` for the other (`:2656-2666`) — and **the
/// pair coincides exactly when that range is empty.** A key the map holds
/// has a non-empty range and the arms are different rows; a key it does not
/// hold has `propRange` return the sorted insertion point as both ends
/// (`:2140`) and the arms are the same row. The
/// "absent boundary key collapses the pair" test at the foot of this file
/// pins that, so the weakness is stated rather than assumed away.
const held_bounds = [_]Shape{
    // `Included(begin)..Excluded(end)`, the shape every C case builds.
    .{
        .begin = "b",
        .end = "d",
        .at_now = &.{
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
        },
        .at_past = &.{
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
        },
    },
    // `Unbounded..Excluded(end)`.
    .{
        .begin = null,
        .end = "d",
        .at_now = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
        },
        .at_past = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
        },
    },
    // `Included(begin)..Unbounded`. **The clock is visible here**: `e` is
    // written after the clock, so the now answer has four keys and the
    // clocked answer three.
    .{
        .begin = "b",
        .end = null,
        .at_now = &.{
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
            .{ .key = "e", .value = "int:5" },
        },
        .at_past = &.{
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
        },
    },
    // `Unbounded..Unbounded`.
    .{
        .begin = null,
        .end = null,
        .at_now = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
            .{ .key = "e", .value = "int:5" },
        },
        .at_past = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
        },
    },
};

/// The same four shapes, bounded by keys the root map **does not hold**.
///
/// **These eight comparisons prove the sorted-point case and nothing about
/// the arms**, and the reason is the empty-range rule above: `bb` and `cc`
/// both collapse, so no arm swap changes these answers. They are here because
/// `propRange` on an absent key is a real answer with a real failure mode —
/// an older revision answered the object's end rather than the insertion
/// point, which is the bug [`src/c/doc.zig:4037-4042`](../src/c/doc.zig) and
/// [`op_set.zig:2126-2141`](../src/opset/op_set.zig) record — and a C caller
/// passing a key it misspelled is the case that reaches it.
const absent_bounds = [_]Shape{
    .{
        .begin = "bb",
        .end = "cc",
        .at_now = &.{.{ .key = "c", .value = "int:3" }},
        .at_past = &.{.{ .key = "c", .value = "int:3" }},
    },
    .{
        .begin = null,
        .end = "cc",
        .at_now = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
        },
        .at_past = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
        },
    },
    .{
        .begin = "bb",
        .end = null,
        .at_now = &.{
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
            .{ .key = "e", .value = "int:5" },
        },
        .at_past = &.{
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
        },
    },
    .{
        .begin = null,
        .end = null,
        .at_now = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:two" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
            .{ .key = "e", .value = "int:5" },
        },
        .at_past = &.{
            .{ .key = "a", .value = "int:1" },
            .{ .key = "b", .value = "str:one" },
            .{ .key = "c", .value = "int:3" },
            .{ .key = "d", .value = "str:four!" },
        },
    },
};

/// One item, checked two ways, and **both failures are reported before the
/// test gives up** so that a disagreement and a wrong expectation in the same
/// run are not confused for one another.
fn checkItem(
    c: Answered,
    z: Answered,
    want: KeyValue,
    n: usize,
    shape: Shape,
    clock: []const u8,
) !void {
    var wrong = false;
    if (!(std.mem.eql(u8, c.key, z.key) and
        std.mem.eql(u8, c.value, z.value) and
        c.ctr == z.ctr))
    {
        std.debug.print(
            "the two readers disagree (begin={?s} end={?s} {s}) at item {d}: " ++
                "C '{s}'='{s}' row {d}, Zig '{s}'='{s}' row {d}\n",
            .{ shape.begin, shape.end, clock, n, c.key, c.value, c.ctr, z.key, z.value, z.ctr },
        );
        wrong = true;
    }
    if (!(std.mem.eql(u8, c.key, want.key) and std.mem.eql(u8, c.value, want.value))) {
        std.debug.print(
            "C answer (begin={?s} end={?s} {s}) item {d} is '{s}'='{s}', the table says '{s}'='{s}'\n",
            .{ shape.begin, shape.end, clock, n, c.key, c.value, want.key, want.value },
        );
        wrong = true;
    }
    if (wrong) return error.MapRangeAnswerWrong;
}

/// One shape, one clock, one document: the C answer and the Zig answer
/// compared **item for item**, and both against `want`.
///
/// **Item for item, not by length.** A length comparison passes on the same
/// off-by-one in both readers, and on both readers naming the same wrong
/// keys. So the two cursors are advanced together and every key, every value
/// and every row counter is compared, and each cursor is then required to be
/// exhausted — neither may hold an item the other has not named.
fn compareShape(
    cdoc: *cabi.AMdoc,
    root: *const cabi.AMobjId,
    heads: ?*const cabi.AMitems,
    zig_doc: *Document,
    shape: Shape,
    want: []const KeyValue,
    clock: []const u8,
) !void {
    const res = cabi.AMmapRange(
        cdoc,
        root,
        if (shape.begin) |k| cabi_result.AMbyteSpan.of(k) else .empty,
        if (shape.end) |k| cabi_result.AMbyteSpan.of(k) else .empty,
        heads,
    ) orelse return error.CMapRangeReturnedNull;
    defer cabi.abi.AMresultFree(res);
    // **An error result is not an empty range.** `AMitemsNext` over an error
    // result answers nothing, so without this the C side would agree with an
    // empty Zig side and the comparison would pass.
    if (res.status() != .ok) {
        std.debug.print("AMmapRange(begin={?s} end={?s} {s}) failed: '{s}'\n", .{
            shape.begin, shape.end, clock, res.errorMessage().slice(),
        });
        return error.CMapRangeFailed;
    }
    var cur = cabi.abi.AMresultItems(res);
    var walk = try am.read.mapRange(zig_doc, am.root, .between(shape.begin, shape.end));
    for (want, 0..) |one, n| {
        const citem = cabi.abi.AMitemsNext(&cur, 1) orelse {
            std.debug.print("C stopped after {d} items (begin={?s} end={?s} {s}), the table wants {d}\n", .{
                n, shape.begin, shape.end, clock, want.len,
            });
            return error.CAnsweredTooFewItems;
        };
        const zitem = (try walk.next()) orelse {
            std.debug.print("Zig stopped after {d} items (begin={?s} end={?s} {s}), the table wants {d}\n", .{
                n, shape.begin, shape.end, clock, want.len,
            });
            return error.ZigAnsweredTooFewItems;
        };
        var cbuf: [128]u8 = undefined;
        var zbuf: [128]u8 = undefined;
        try checkItem(try answeredC(&cbuf, citem), try answeredZ(&zbuf, zitem), one, n, shape, clock);
    }
    if (cabi.abi.AMitemsNext(&cur, 1) != null) {
        std.debug.print("C answered more than the {d} items the table names (begin={?s} end={?s} {s})\n", .{
            want.len, shape.begin, shape.end, clock,
        });
        return error.CAnsweredTooManyItems;
    }
    if ((try walk.next()) != null) {
        std.debug.print("Zig answered more than the {d} items the table names (begin={?s} end={?s} {s})\n", .{
            want.len, shape.begin, shape.end, clock,
        });
        return error.ZigAnsweredTooManyItems;
    }
}

/// The document every comparison above reads: five keys, **`b` and `d` each
/// written twice**, and a clock taken between the two batches.
///
/// The clock is the reason there are two batches. The six writes before
/// [`past`] are one change — an autocommit document holds its transaction
/// open across ordinary reads, and `getHeads` closes it — and
/// the two after it are a second. So `past` is a single head, and the state
/// it names differs from the current one in **two observable ways**: `b`'s
/// winner is the earlier row, and `e` is not in the map at all. A clock that
/// changed nothing would make the clocked column of every table above a
/// duplicate of the unclocked one, and the comparison would prove that the
/// `heads` parameter was ignored.
fn rangesFixture(list: Allocator) !struct { doc: Document, past: []ChangeHash } {
    var doc = try Document.init(list, io);
    errdefer doc.deinit();
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    _ = try doc.put(am.root, .{ .key = "a" }, .{ .int = 1 });
    _ = try doc.put(am.root, .{ .key = "b" }, .{ .str = "one" });
    _ = try doc.put(am.root, .{ .key = "c" }, .{ .int = 3 });
    _ = try doc.put(am.root, .{ .key = "d" }, .{ .str = "four" });
    _ = try doc.put(am.root, .{ .key = "d" }, .{ .str = "four!" });
    // Ordinary length reads remain pending; getHeads closes this first batch.
    _ = try am.read.length(&doc, am.root);
    const past = try doc.getHeads(list);
    errdefer list.free(past);
    // **`b` a second time, after the clock**: this is what makes `b` two rows
    // wide at the current state and gives the clock something to hide.
    _ = try doc.put(am.root, .{ .key = "b" }, .{ .str = "two" });
    _ = try doc.put(am.root, .{ .key = "e" }, .{ .int = 5 });
    // Close at the fixture transfer boundary: an open owner cannot move.
    _ = try doc.commit();
    return .{ .doc = doc, .past = past };
}

test "the four bound shapes: one document through AMmapRange and through read.mapRange, item for item" {
    const fixture = try rangesFixture(gpa);
    var doc = fixture.doc;
    defer doc.deinit();
    defer gpa.free(fixture.past);

    // **The same document on both sides.** The C side is `AMload` of this
    // document's own save bytes rather than a second document built by a
    // second sequence of writes, so "the same document" is a fact about the
    // bytes and not a claim about two fixtures agreeing.
    const bytes = try doc.save(gpa);
    defer gpa.free(bytes);
    const loaded = cabi.AMload(@ptrCast(bytes.ptr), bytes.len) orelse
        return error.CLoadReturnedNull;
    defer cabi.abi.AMresultFree(loaded);
    var loaded_items = cabi.abi.AMresultItems(loaded);
    const loaded_item = cabi.abi.AMitemsNext(&loaded_items, 1) orelse
        return error.CLoadAnsweredNoDocument;
    var cdoc: ?*cabi.AMdoc = null;
    if (!cabi.AMitemToDoc(loaded_item, &cdoc)) return error.CLoadAnsweredNotADoc;

    // **The heads as the C ABI's own change-hash items**, through the same
    // `boxHashes` the C layer uses for `AMmerge` and `AMgetHeads`
    // ([`src/c/doc.zig:4245-4251`](../src/c/doc.zig)) — a heads gpa a C
    // caller can produce is a heads gpa a C caller can pass, and a gpa
    // hand-assembled from the Zig side would not be.
    const head_res = try cabi.boxHashes(cabi.c_allocator, fixture.past);
    defer cabi.abi.AMresultFree(head_res);
    var heads = cabi.abi.AMresultItems(head_res);
    try testing.expect(fixture.past.len > 0);

    var root = cabi.AMobjId.rootObj(gpa);
    defer root.deinit();

    // **The clocked Zig answer is a document forked at the same heads**
    // ([`doc.forkAt`](../src/doc.zig)), not a clock threaded into
    // `read.mapRange`, because that function hardcodes a null one
    // ([`src/read.zig:1124-1131`](../src/read.zig)). Two different mechanisms
    // — a `heads` clock handed to `MapRange::init` on the C side, an
    // already-narrowed document on the Zig side — have to give the same
    // answer, and neither is derived from the other.
    var fork = try doc.forkAt(gpa, fixture.past);
    defer fork.deinit();

    for ([_][]const Shape{ &held_bounds, &absent_bounds }) |table| {
        for (table) |shape| {
            // ── The null-clock comparison for this shape ──
            try compareShape(cdoc.?, &root, null, &doc, shape, shape.at_now, "no heads");
            // ── The clocked comparison for this shape ──
            try compareShape(cdoc.?, &root, &heads, &fork, shape, shape.at_past, "at the frozen clock");
        }
    }

    // **The clock is not decorative, and this is where that is stated rather
    // than assumed.** Two of the eight shapes must answer differently with
    // and without it, or the `heads` column would be a copy of the null
    // column and the whole clocked half of this test would pass on an
    // `AMmapRange` that dropped its `heads` argument on the floor.
    for ([_][]const Shape{ &held_bounds, &absent_bounds }) |table| {
        for (table) |shape| {
            const differs = shape.at_now.len != shape.at_past.len or blk: {
                for (shape.at_now, shape.at_past) |now, was| {
                    if (!std.mem.eql(u8, now.key, was.key)) break :blk true;
                    if (!std.mem.eql(u8, now.value, was.value)) break :blk true;
                }
                break :blk false;
            };
            if (differs) continue;
            // Only `["bb","cc")` may legitimately be clock-invariant, and only
            // because none of the rows the clock hides falls inside it.
            if (!(std.mem.eql(u8, shape.begin orelse "", "bb") and
                std.mem.eql(u8, shape.end orelse "", "cc")))
            {
                std.debug.print("shape begin={?s} end={?s} gives the same answer with and without the clock, so it pins nothing about `heads`\n", .{
                    shape.begin, shape.end,
                });
                return error.ClockColumnIsADuplicate;
            }
        }
    }
}

/// The keys [`rangesFixture`] puts in the root map, as a walk sees them.
fn keysOf(list: Allocator, doc: *Document, range: am.read.KeyRange) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(list);
    var walk = try am.read.mapRange(doc, am.root, range);
    while (try walk.next()) |item| {
        try out.appendSlice(list, item.key);
        try out.append(list, ',');
    }
    return out.toOwnedSlice(list);
}

test "an absent boundary key collapses Included and Excluded; a held one does not" {
    // **This is the evidence that the eight comparisons above can fail.**
    // An end's two arms are `propRange(s).start` and `propRange(s).end`, and
    // the pair is the same row exactly when the range is empty. So a boundary
    // key the map does not hold cannot tell the arms apart, and a test built
    // on one proves nothing about either. Asserting it here turns "the arms
    // are indistinguishable for this key" from an unobservable into a stated
    // fact, and the second half is the half that matters: **the keys the
    // tables above are built on do not collapse.**
    const fixture = try rangesFixture(gpa);
    var doc = fixture.doc;
    defer doc.deinit();
    defer gpa.free(fixture.past);

    for ([_][]const u8{ "b", "d" }) |held| {
        const included = try keysOf(gpa, &doc, .{ .start = .{ .included = held } });
        defer gpa.free(included);
        const excluded = try keysOf(gpa, &doc, .{ .start = .{ .excluded = held } });
        defer gpa.free(excluded);
        if (std.mem.eql(u8, included, excluded)) {
            std.debug.print("'{s}' is a key the map holds, and its two arms still answer the same rows ('{s}')\n", .{
                held, included,
            });
            return error.HeldBoundaryKeyDoesNotDiscriminate;
        }
    }

    for ([_][]const u8{ "aa", "bb", "cc", "z" }) |absent| {
        const included = try keysOf(gpa, &doc, .{ .start = .{ .included = absent } });
        defer gpa.free(included);
        const excluded = try keysOf(gpa, &doc, .{ .start = .{ .excluded = absent } });
        defer gpa.free(excluded);
        // **The same on both ends of the key.** A missing key is a sorted
        // insertion point, and `propRange` answers it as a zero-width range,
        // so both arms name it and neither can be wrong about the other.
        if (!std.mem.eql(u8, included, excluded)) {
            std.debug.print("'{s}' is not a key the map holds, yet its two arms answer different rows ('{s}' against '{s}')\n", .{
                absent, included, excluded,
            });
            return error.AbsentBoundaryKeyDidNotCollapse;
        }
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **What the sixteen comparisons are, and which eight the brief named.**
//   Four bound shapes × two clock states, twice over: once bounded by keys
//   the root map holds (`held_bounds`) and once by keys it does not
//   (`absent_bounds`). The first eight are the ones a C caller can reach.
//   Each is a separate C call against a separate Zig walk, compared item for
//   item — key, value and the row's own operation counter — with both cursors
//   then required to be exhausted.
//
// * **The clock does not change the bounds, and that is the reference's
//   behaviour, not a gap in the comparison.** `OpSet::map_range` computes all
//   four arms from `key_str` and `obj_range` and passes the clock only to
//   `MapRange::new` ([`op_set2/op_set.rs:396-419`](../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs));
//   the C layer varies the reader on `heads` **per arm**
//   ([`src/doc/map.rs:525-529`, `:533-537`, `:541-545`, `:549-553`](../github-automerge-automerge/rust/automerge-c/src/doc/map.rs)).
//   So the clock narrows which rows are *visible* inside a range, and the
//   bound arithmetic never sees it. The tables record that as a result: the
//   two clock states differ exactly where the clock hides a row, and the
//   test asserts they are not duplicates.
//
// * **The C path reaches two of the four `Bound` variants, and that is a
//   property of the reference.** `AMmapRange` builds
//   `Included(begin)..Excluded(end)`, and the reference's header documents
//   `end` as "the key one past the last key in a subrange"
//   ([`src/doc/map.rs:482-483`](../github-automerge-automerge/rust/automerge-c/src/doc/map.rs))
//   with no entry for an inclusive end, so a C caller **cannot name
//   `Excluded(begin)` or `Included(end)` at all.** No cross-boundary test can
//   cover those two; the Zig-side test in `src/opset/op_set.zig` is their
//   only coverage, and duplicating it here would be a second copy of one
//   assertion rather than a check.
//
// * **The C layer's `begin > end` refusal and its emptiness clamp are not
//   duplication.** The reference validates the range in that layer and not in
//   `OpSet::map_range` ([`src/doc/map.rs:521-523`](../github-automerge-automerge/rust/automerge-c/src/doc/map.rs)),
//   so a C caller gets `Invalid range [begin-end)` where a Zig caller gets an
//   empty walk. The test drives no `begin > end` case, because the two
//   answers are **supposed** to differ.
//
// * **What this file can no longer prove, and why that is worth writing
//   down.** There was a time when three copies of these four arms existed and
//   a disagreement between them was silent with every suite green. The
//   consolidation removed the other two: `read.mapRange` and `AMmapRange` both
//   call [`OpSet.mapRange`](../src/opset/op_set.zig) now
//   ([`src/read.zig:1124-1131`](../src/read.zig),
//   [`src/c/doc.zig:4063-4067`](../src/c/doc.zig)). **Perturbing that one
//   implementation would move both sides of every comparison here together,
//   so this test would stay green** — a cross-check of an implementation
//   against itself. What is left for it to catch, and what it is pointed at,
//   is the **adapter**: how a C caller names a bound, with `begin > end`
//   refused, and how a `heads` clock reaches the walk. A regression there
//   moves the C side alone, and the bug that used to be there was exactly
//   there — `["b","d")` answering `b c d` where `b c` is right
//   ([`src/c/doc.zig:4027-4028`](../src/c/doc.zig) records it). The
//   expectations in the tables are what catch a regression in the single
//   remaining copy, and a cross-check of one implementation against itself
//   cannot.
//
// * **`testing.allocator` is the arbiter for everything this module owns, and
//   it cannot see the C side.** [`cabi.c_allocator`] is
//   `std.heap.c_allocator` ([`src/c/result.zig:1074-1077`](../src/c/result.zig)),
//   so every `AMresult` above is freed through `AMresultFree` and none of
//   those bytes is the testing allocator's to catch. That is the C ABI's own
//   single-destructor rule and `zig build ctest` is where a C-side leak is
//   found; here it is the same discipline written out by hand, because a
//   forgotten `AMresultFree` is invisible to the arbiter this file can
//   actually use.
