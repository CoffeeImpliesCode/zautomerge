//! The materialised mirror: the value tree a patch stream is replayed into.
//!
//! Upstream is four files — `hydrate.rs` (372 lines), `hydrate/map.rs` (141),
//! `hydrate/list.rs` (149), `hydrate/text.rs` (109) and `hydrate/tests.rs` (40)
//! — and this is all of them bar the wasm bridge:
//!
//! | what | upstream |
//! |------|----------|
//! | [`Value`], [`Value.fromPatch`], [`Value.map`], [`Value.list`], [`Value.text`] | `hydrate.rs`:22-54` |
//! | [`Value.applyPatches`] | `hydrate.rs`:78-87` |
//! | [`Value.applyOne`] | `hydrate.rs`:89-113` |
//! | [`Map`], [`MapValue`] | `map.rs`:11-17`, `:24-65` |
//! | [`List`], [`ListValue`] | `list.rs`:10-23`, `:38-93` |
//! | [`Text`] | `text.rs`:8-11`, `:23-62` |
//! | [`hydrateMap`], [`hydrateList`], [`hydrateText`], [`hydrateOp`] | `hydrate.rs`:244-302` |
//! | the `hydrate_map!` / `hydrate_list!` / `hydrate_text!` macros | `hydrate.rs`:305-327` |
//!
//! # Refuse, do not invent
//!
//! **A patch whose path names an object the mirror does not have is a stream
//! that cannot be applied**, and this file says so instead of making one up.
//! Upstream cannot express that distinction: it walks the **properties** of
//! `p.path` and throws the object ids away (`hydrate.rs`:84`,
//! `p.path.iter().map(|(_, prop)| prop)`), so a patch about an object the
//! mirror has never heard of arrives as a `get_mut` miss and comes back as
//! `ApplyInvalidProp` (`hydrate.rs`:98`). That is one error for two different
//! faults, and the second one is the interesting one: a stream whose first
//! patch is `obj = 1@0, path = [root."list"]` applied to an empty mirror means
//! the [`ExposeQueue`](patches.zig) failed to introduce the list, and a
//! hydrate that quietly applied the action to the nearest match would hide it.
//! Upstream's `_ => Err(HydrateError::Fail)` arm (`hydrate.rs`:111`) is the
//! same refusal with no diagnosis attached; here the refusal is
//! [`Failure.unknown_object`], and it carries **the whole path, the object the
//! patch asked for, the object the mirror holds there, and the step it stopped
//! at**.
//!
//! That check needs the mirror to know which object each of its values is, so
//! [`Map`], [`List`] and [`Text`] carry an [`ExId`]. Upstream's equivalents
//! compute exactly that id and drop it — `MapValue::new(value, _id, conflict)`
//! (`hydrate/map.rs`:81`) and `List::push(value, _id, conflict)`
//! (`hydrate/list.rs`:104`) — so keeping it is the one addition this file makes
//! to the data model, and it is the whole of the addition: eight bytes per
//! object, read on every path step, never compared by [`Value.eql`].
//!
//! # What a mirror owns
//!
//! **Everything.** A mirror owns its structure — the map keys it dups, the text
//! buffers, the sequence trees, the mark-set arrays — **and every byte of
//! content**: a `str`, a `bytes` payload, an `unknown` payload, an actor id, a
//! mark name, the payload of a mark value. The copy is made where a value
//! crosses into a container ([`ownValue`], [`ownMark`]) and the free is in the
//! container's `deinit`.
//!
//! **There is no lifetime rule here, and upstream is why.**
//! Upstream's [`Value`] holds [`ScalarValue`], whose byte cases are
//! `Bytes(Vec<u8>)` and `Str(SmolStr)` ([`value.rs`:519-522]) — **owned**, and
//! the enum carries **no lifetime parameter at all**. The op set holds the
//! borrowed form instead (`Cow<'a, [u8]>` and `Cow<'a, str>`,
//! [`op_set2/types.rs`:192-194`), and the crossing is
//! `OpType::Put(scalar) => Value::Scalar(scalar.into())`
//! ([`hydrate.rs`:299]), which runs
//! `From<ScalarValue<'a>> for types::ScalarValue`
//! ([`op_set2/types.rs`:222-225`) into `into_legacy`
//! ([`op_set2/types.rs`:278-281`) — `b.to_vec()` and `s.to_string().into()`.
//! **Upstream copies once, at the boundary, and a mirror there is `'static`**,
//! so it cannot be read across a mutation of the op set because there is
//! nothing in it that the op set owns. The same is true of the patch path:
//! [`Value::new`] takes `Value::Scalar(s.into_owned())` ([`hydrate.rs`:36`),
//! and `into_owned` turns `Cow::Borrowed` into `Cow::Owned`
//! ([`value.rs`:182-188]).
//!
//! **The cost is one copy per byte-bearing scalar per patch, and one per mark
//! name and per mark payload per patch** — the same work upstream does at the
//! same place. It buys what upstream got from its type system: a mirror a
//! caller can keep and edit across any number of mutations of the document it
//! was read from.
//!
//! # The allocator lives in the containers
//!
//! Upstream has no allocator to thread. This port takes one on every
//! constructor — [`Map.init`], [`List.init`], [`Text.init`], [`Value.map`] —
//! and **each container uses only its own**. So [`Value.applyPatches`] takes
//! none: the walk allocates only inside a container it has already reached, and
//! a scalar at the root is a refusal rather than an allocation. A mirror built
//! with two allocators is a bug the constructors make hard to write.
//!
//! # What is not here
//!
//! * **The wasm bridge** (`hydrate.rs`:329-372`). It is `#[cfg(feature =
//!   "wasm")]` and reaches for `js_sys::Array`, `Date`, `Object`, `Reflect`
//!   and `Uint8Array`; there is no host in this port for it to talk to.
//! * **The document-level entry points.** [`Automerge::hydrate_map`],
//!   [`hydrate_list`] and [`hydrate_text`] (`hydrate.rs`:231-241`) are `impl
//!   Automerge`, and [`Automerge::hydrate`] / [`Automerge::hydrate_obj`]
//!   (`automerge.rs`:1633-1649`) sit on top of them. The op-set-level four
//!   below are ported; **what the document-level ones need from `src/doc.zig`
//!   is the last section of this doc**, and it is five reads and two functions.
//! * **`From<Value> for value::Value`** and the eleven `From` impls
//!   (`hydrate.rs`:137-229`). They are conversions into the *read* value type
//!   and the wasm target, and nothing here produces them.
//!
//! ## The three `hydrate_*!` macros, as functions
//!
//! `hydrate_map!`, `hydrate_list!` and `hydrate_text!` (`hydrate.rs`:305-327`)
//! are constructor sugar over `HashMap::from`, `Vec::from` and `Text::new`,
//! and they exist to write a test in a shape that reads like the answer. The
//! functions they wrap — [`Value.map`], [`Value.list`], [`Value.text`] and
//! [`Map.putOwned`] — are what this file has, and the test at the bottom builds
//! its expected tree out of them.
//!
//! # What `src/doc.zig` must hand over
//!
//! Upstream's four are one-liners over five reads, and the port's need the
//! same five. Each is named here with the line that asks for it, so `doc.zig`
//! can be written against the list rather than against this prose.
//!
//! | what | upstream | here |
//! | --- | --- | --- |
//! | the op set | `self.ops()` (`hydrate.rs`:233`, `:236`, `:239`) | `doc.ops`, the `OpSet(ChangeOp)` the document already holds. [`hydrateMap`], [`hydrateList`], [`hydrateText`] and [`hydrateOp`] take it as `set: *Set` and read everything else off it; the six methods they read are [`set_decls`] and [`assertSet`] checks them at every call site. |
//! | the text encoding | `self.text_encoding()` (`hydrate.rs`:233`) | **Nothing.** `OpSet` already carries it (`op_set.rs`:64`) and the four above read it from the set. A document that kept a second copy would be a second thing to get wrong. |
//! | a clock for some heads | `self.clock_at(heads)` (`automerge.rs`:1634`, `:1644`) | `doc.clockAt(heads) ?Clock` — the name [`patches.doc_decls`](patches.zig) already requires, over [`ChangeGraph.clockAt`](change_graph.zig). |
//! | an `ExId` and its type | `self.exid_to_obj(exid)` (`automerge.rs`:1643`, `:2225`) | `doc.objectType(exid) ?ObjType`, which the document already exposes for [`patches.doc_decls`](patches.zig). The port's [`ExId`] *is* the internal object id ([`patches.internalObjOf`](patches.zig)), so there is no reverse mapping to write. |
//! | an allocator | none — Rust's | `gpa` as the first parameter, per the house rule, and [`Value.deinit`] to free it. |
//!
//! So the four are a `hydrate` over the root and a `hydrateObj` over any id,
//! and the other three become private calls into the [`hydrateMap`],
//! [`hydrateList`] and [`hydrateText`] this file already exports:
//!
//! ```zig
//! pub fn hydrateMap(gpa: Allocator, heads: ?[]const ChangeHash) !Value
//! pub fn hydrateObj(gpa: Allocator, exid: ExId, heads: ?[]const ChangeHash) !Value
//! ```
//!
//! (`automerge.rs`:1633-1636` and `:1638-1649`). `hydrateObj`'s dispatch is
//! `ObjType::Map | ObjType::Table => hydrate_map` and so on
//! (`automerge.rs`:1646-1648`), plus `error.NotAnObject` for an `exid_to_obj`
//! that finds nothing — a variant [`Error`](error.zig) already has.

const std = @import("std");

const err = @import("error.zig");
const types = @import("types.zig");
const valmod = @import("value.zig");
const marksmod = @import("marks.zig");
const clocks = @import("clock.zig");
const patches = @import("patches.zig");
const seqtree = @import("sequence_tree.zig");
const opmod = @import("opset/op.zig");
const optypes = @import("opset/types.zig");
const opiter = @import("opset/op_iter.zig");
const opsetmod = @import("opset/op_set.zig");
const opcols = @import("opset/columns.zig");
const batchmod = @import("opset/batch.zig");
const changerec = @import("change.zig");

const testing = std.testing;

const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Change = changerec.Change;
const Clock = clocks.Clock;
const Counter = valmod.ScalarValue.Counter;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const Mark = marksmod.Mark;
const MarkSet = marksmod.MarkSet;
const ObjType = types.ObjType;
const OpId = types.OpId;
const PatchAction = patches.PatchAction;
const PatchValue = batchmod.PatchValue;
const Prop = types.Prop;
const ScalarValue = valmod.ScalarValue;
const SequenceType = types.SequenceType;
const TextEncoding = types.TextEncoding;

const Allocator = std.mem.Allocator;

/// One step of a path: the object the step leaves and the property it uses to
/// reach the next ([`patches.PathElem`](patches.zig), upstream `patch.rs`:21`).
/// Re-exported because [`Failure`] names it.
pub const PathElem = patches.PathElem;

/// A patch, re-exported for the same reason
/// ([`patches.Patch`](patches.zig), upstream `patch.rs`:17-24`).
pub const Patch = patches.Patch;

/// What applying a patch stream can raise that is not a refusal
/// ([`HydrateError`](hydrate.rs)'s fallible arms are all refusals, and the
/// remaining work is allocation).
pub const ApplyError = Error;

/// What the op-set-level hydration can raise: the refusals and the allocation
/// are [`ApplyError`], and the two [`Set`](opset/op_set.zig) walks add
/// [`ReadOpError`](opset/op_iter.zig), [`InternalError`] and
/// [`MarksError`](opset/op_set.zig).
pub const OpHydrateError = ApplyError || opiter.ReadOpError || InternalError || opsetmod.MarksError;

// ── Refusals ────────────────────────────────────────────────────────────────

/// Why a patch stream stopped, one variant per upstream [`HydrateError`]
/// variant (`error.rs`:155-176) plus the one this file makes distinguishable.
///
/// **Every payload is borrowed** from the patch batch the stream came from, and
/// is only valid while that batch is. Nothing here owns anything: the
/// `PatchAction` a refusal carries is a shallow copy of the one that was
/// refused, and its `InsertValues` tree and `MarkSet` still point into the
/// arena. Nothing frees them — the batch's `deinit` is the one free.
pub const Failure = union(enum) {
    /// A patch named an object the mirror does not have, or named one it holds
    /// under a different id, or put a patch on something that is not an object
    /// at all.
    ///
    /// Upstream reaches the same refusal through three different arms and
    /// reports none of them: the catch-all `Err(HydrateError::Fail)`
    /// (`hydrate.rs`:111`), and — for a path that resolves to a scalar — the
    /// two `ok_or_else(ApplyInvalidProp)` misses (`hydrate.rs`:98`, `:102`).
    unknown_object: struct {
        /// The object the patch asked for: the step's `obj`, or the patch's own
        /// `obj` for the step past the end of the path.
        want: ExId,
        /// The object the mirror holds at that place, or null when it holds a
        /// scalar — a value with no object to be.
        got: ?ExId,
        /// Which step of the path stopped. Equal to `path.len` for the patch's
        /// own `obj` check, which is the last step.
        at: usize,
        /// The whole path, so the refusal names it.
        path: []const PathElem,
    },
    /// The path named a property the object does not have — a key that is not
    /// in the map, or an index past the end of the list
    /// ([`ApplyInvalidProp`](hydrate.rs):98`, `:102`).
    invalid_prop: struct {
        /// Which step of the path stopped.
        at: usize,
        /// The whole path, so the refusal names it.
        path: []const PathElem,
    },
    /// A key an increment or a conflict flag needs is not in the map
    /// ([`InvalidKey`](hydrate.rs):50`, `:58`).
    invalid_key: []const u8,
    /// An index a put, an increment, a conflict flag or a delete needs is not
    /// in the sequence ([`InvalidIndex`](hydrate.rs):53`, `:75`, `:83`).
    invalid_index: usize,
    /// A counter was incremented on something that is not a counter
    /// ([`BadIncrement`](hydrate.rs):90`, `list.rs`:117`).
    bad_increment,
    /// The action is not one a map takes ([`InvalidMapOp`](hydrate.rs):63`).
    invalid_map_op: PatchAction,
    /// The action is not one a list takes ([`InvalidListOp`](hydrate.rs):91`).
    invalid_list_op: PatchAction,
    /// The action is not one a text takes ([`InvalidTextOp`](hydrate.rs):60`).
    invalid_text_op: PatchAction,
    /// The text is not valid in the document's encoding
    /// ([`InvalidEncoding`](hydrate.rs):32`).
    invalid_encoding,
};

/// The outcome of applying one action or a whole stream
/// ([`Value.applyPatches`], [`Value.applyOne`]).
pub const Applied = union(enum) {
    /// Every action applied.
    ok,
    /// The stream stopped here. **The mirror holds every action before it** —
    /// upstream applies in order and returns on the first error
    /// (`hydrate.rs`:83-86`) — and nothing after it was applied.
    ///
    /// **The refused action itself may already have changed the mirror.** One
    /// arm does that, and it is [`List.apply`]'s `delete_seq`. It
    /// removes **one element per iteration** and stops at the first index the
    /// list does not have, so a delete of five elements against a list of two
    /// removes and frees both and then refuses — the mirror is left holding
    /// neither, and a caller that retries the same action removes nothing
    /// further because the index it names is gone. [`List.apply`] says which
    /// arms have no residue and which has this one.
    refused: Failure,
};

// ── Value ───────────────────────────────────────────────────────────────────

/// U+FFFC, the character every non-string value renders as
/// ([`hydrate::Value::as_str`](hydrate.rs):71-76`).
const object_replacement: []const u8 = "\u{fffc}";

/// The three kinds of object a value can be ([`hydrate::Value`](hydrate.rs):22-27`).
pub const Object = union(enum) {
    /// A map, a table, or a root object.
    map: Map,
    /// A list.
    list: List,
    /// A text object.
    text: Text,
};

/// The byte buffers one stored value owns, and the frees that give them back.
///
/// **A mirror owns every byte it holds** (see the module doc's "what a mirror
/// owns"), and this is where those bytes are recorded. One record per stored
/// value: [`MapValue`] holds the payload of its scalar, [`ListValue`] holds
/// the payload of its scalar *and* the name and payload of each of its marks,
/// and [`Text`] holds the same for its marks.
///
/// **It is a list and not a single slice** because a mirror stores mark sets,
/// which are unbounded, and because one type that every container can hold
/// beats three that differ only in arity. The common case costs nothing: a
/// scalar with no bytes never builds a record at all.
pub const Owned = struct {
    /// The allocator every buffer in `items` was taken with, and the one
    /// [`Owned.deinit`] frees them with.
    ///
    /// **It must not be replaced once a buffer is in `items`**, and nothing
    /// checks it: a write between a [`Owned.keep`] and the `deinit` hands the
    /// allocator a pointer it never lent. [`Map.gpa`] says the same for a
    /// container, which is where the field is reached from.
    gpa: Allocator,
    /// The buffers this record owns, each one a block `gpa` lent.
    ///
    /// **`deinit` frees every element through `gpa`, so appending a slice that
    /// came from anywhere else makes it hand a foreign pointer to the
    /// allocator.** The two functions that reach this list — [`ownScalar`] and
    /// [`ownMark`] — both go through [`Owned.keep`], which copies first, and
    /// nothing else appends to it.
    items: std.ArrayList([]const u8) = .empty,

    /// Frees every buffer and the list itself.
    ///
    /// **`self` is unusable afterwards and exactly one owner may run this on a
    /// given record**: `self.* = undefined` is what turns a second run into a
    /// walk over undefined bytes instead of a silent double free.
    ///
    /// A `MapValue`, a `ListValue` and a `Text` each hold this record by value,
    /// so a by-value copy of one of those is a move — the same rule
    /// [`Map.deinit`] states for the containers that hold one.
    pub fn deinit(self: *Owned) void {
        for (self.items.items) |bytes| self.gpa.free(bytes);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    /// A copy of `bytes` this record owns. The caller repoints whatever held
    /// the borrowed slice at the copy; this only allocates.
    fn keep(self: *Owned, bytes: []const u8) ApplyError![]const u8 {
        const copy = try self.gpa.dupe(u8, bytes);
        errdefer self.gpa.free(copy);
        try self.items.append(self.gpa, copy);
        return copy;
    }
};

/// Releases `o`'s buffers by value, for the error paths that hold the record
/// by value and cannot take a mutable pointer to it. Every `errdefer` in this
/// file that frees a copy goes through here, so there is one spelling of the
/// free rather than one per call site.
fn releaseOwned(o: ?Owned) void {
    if (o) |held| {
        var copy = held;
        copy.deinit();
    }
}

/// Copies the byte payload `s` borrows into `owned` and repoints `s` at the
/// copy.
///
/// **A [`ScalarValue`] has at most one byte payload**: the eleven arms are
/// mutually exclusive and four of them carry bytes — `str`, `bytes`,
/// `unknown.bytes` and `actor_id.bytes`.
fn ownScalar(owned: *Owned, s: *ScalarValue) ApplyError!void {
    switch (s.*) {
        .str => |v| s.str = try owned.keep(v),
        .bytes => |v| s.bytes = try owned.keep(v),
        .unknown => |u| s.unknown = .{
            .type_code = u.type_code,
            .bytes = try owned.keep(u.bytes),
        },
        .actor_id => |a| s.actor_id = .{ .bytes = try owned.keep(a.bytes) },
        else => {},
    }
}

/// Copies every byte `v` borrows and repoints `v` at the copies. Null when
/// `v` carries none — an object, whose containers own their own, or a scalar
/// with no byte payload.
///
/// **This is where the mirror's scalars stop borrowing**, and it is the one
/// place a value crosses into a container: [`Map.putOwned`], [`List.push`],
/// [`List.apply`]. Upstream makes the same copy at the same boundary —
/// `Value::Scalar(scalar.into())` ([`hydrate.rs`:299`).
fn ownValue(gpa: Allocator, v: *Value) ApplyError!?Owned {
    var s = v.toScalar() orelse return null;
    var owned: Owned = .{ .gpa = gpa };
    errdefer owned.deinit();
    try ownScalar(&owned, &s);
    if (owned.items.items.len == 0) {
        owned.deinit();
        return null;
    }
    v.* = Value.fromScalar(s);
    return owned;
}

/// Puts `name` at `v` in `set`, copying `name` and every byte `v` borrows into
/// `owned`.
///
/// **A name the set already holds is not copied again**: [`MarkSet.put`]
/// ([`marks.zig`](marks.zig):374-383) replaces the value and leaves the name
/// it has, so a second copy of a name already there would be retained for
/// nothing. The value is always copied, because it is what `put` replaces.
fn ownMark(
    owned: *Owned,
    set: *MarkSet,
    name: []const u8,
    v: ScalarValue,
) ApplyError!void {
    const kept_name = if (markNameHeld(set, name)) name else try owned.keep(name);
    var kept_value = v;
    try ownScalar(owned, &kept_value);
    try set.put(kept_name, kept_value);
}

/// Whether `set` already holds `name`. The sets a mirror holds are a handful
/// of entries, so this is a walk and not the binary search [`MarkSet.put`]
/// does.
fn markNameHeld(set: *const MarkSet, name: []const u8) bool {
    for (set.entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// A value in the mirror ([`hydrate::Value`](hydrate.rs):22-27`).
///
/// **Upstream's is `Scalar(ScalarValue) | Map | List | Text`, and this one
/// flattens the scalar into its eleven cases.** Nothing is lost — the eleven
/// are [`ScalarValue`]'s eleven, one for one (`src/value.zig`:88-101`), and
/// `fromScalar` is the round trip between the two spellings. What the flat
/// union buys is that a caller never has to unwrap a scalar to see what kind
/// it is, and that `deinit` has no scalar arm to get wrong.
///
/// **The four byte-bearing cases are borrowed by the value and owned by the
/// container that holds it**: `str`, `bytes`, `unknown.bytes` and
/// `actor_id.bytes` point at the copy [`ownValue] made on the way in, and a
/// `Value` that has not been stored yet points at whatever its caller had.
/// [`Value.deinit`] frees the structure only; the bytes are the
/// [`MapValue`], [`ListValue`] or [`Text`] record's to free.
///
/// **A value no container holds is released by one [`Value.deinit`], and the
/// containers in its `object` arm are what it frees.** The constructors that
/// produce one — [`Value.map`], [`Value.list`], [`Value.text`] and
/// [`Value.fromPatch`] — take the `gpa` it was built with and record it on it,
/// so `deinit` needs no allocator; a value from those, or from a make arm of
/// [`hydrateOp`] through [`hydrateMap`], [`hydrateList`] or [`hydrateText`], is
/// freed whole by the one call.
///
/// A scalar built by [`Value.fromScalar`] holds no container, and the bytes in
/// it are its caller's until some [`Map.putOwned`] or [`List.push`] takes it —
/// so it frees nothing and needs no allocator.
///
/// **A by-value copy is a move, and not a second owner.** [`Value.applyOne`]
/// takes a `*Value`, [`Map.putOwned`] and [`List.push`] take a `Value` by
/// value, and the `object` arm holds a [`Map`], a [`List`] or a [`Text`] by
/// value, so every one of those copies the owner. Exactly one copy may call
/// `deinit`; a second frees the same table twice. Zig has no move-only type
/// and no `Drop`, so nothing checks this and this comment is the whole
/// contract — [`Map.deinit`] states it again for the container, and
/// [`List.deinit`] and [`Text.deinit`] for the other two.
pub const Value = union(enum) {
    /// A null.
    null_value,
    /// A boolean.
    bool_value: bool,
    /// A signed integer.
    int: i64,
    /// An unsigned integer.
    uint: u64,
    /// A 64-bit float.
    float: f64,
    /// A string. **Owned by the container holding this value** — see the doc
    /// above.
    str: []const u8,
    /// A byte string. **Owned by the container holding this value.**
    bytes: []const u8,
    /// A counter: an integer that merges by addition.
    counter: Counter,
    /// A logical timestamp.
    timestamp: i64,
    /// An actor id.
    actor_id: ActorId,
    /// A value from a future version of automerge, kept whole
    /// ([`ScalarValue::Unknown`](src/value.zig):99-105`). Upstream holds the
    /// variant inside its `Scalar`; a flat union would have to drop the type
    /// code, so it does not.
    unknown: valmod.ScalarValue.UnknownValue,
    /// An object. See the module doc's "what a mirror owns".
    object: Object,

    /// An empty map ([`Value::map`](hydrate.rs):40-42`).
    pub fn map(gpa: Allocator) Value {
        return .{ .object = .{ .map = Map.init(gpa, .root) } };
    }

    /// An empty list ([`Value::list`](hydrate.rs):44-46`).
    pub fn list(gpa: Allocator) Value {
        return .{ .object = .{ .list = List.init(gpa, .root) } };
    }

    /// A text object holding `s` ([`Value::text`](hydrate.rs):48-50`).
    pub fn text(gpa: Allocator, enc: TextEncoding, s: []const u8) ApplyError!Value {
        return .{ .object = .{ .text = try Text.init(gpa, .root, enc, s) } };
    }

    /// A scalar value ([`Value::scalar`](hydrate.rs):52-54`).
    pub fn scalar(s: ScalarValue) Value {
        return fromScalar(s);
    }

    /// A mirror value for a patch payload ([`Value::new`](hydrate.rs):30-38`).
    ///
    /// **The patch payload is [`patches.Value`], whose byte cases live in the
    /// patch arena, and this borrows them.** `id` is the object the value is and
    /// is recorded for the object case only: a scalar has no id, and upstream
    /// discards the one it is handed anyway (`hydrate/map.rs`:81`,
    /// `hydrate/list.rs`:104`).
    ///
    /// An object becomes an **empty** container of the right kind
    /// (`hydrate.rs`:32-35`) — a map, a table, a list, a text — and the
    /// patches that follow fill it. That is the arm that makes the mirror
    /// object-addressable: `put_map` introduces the object, and every later
    /// patch whose path runs through it is checked against the id recorded
    /// here.
    pub fn fromPatch(
        gpa: Allocator,
        v: patches.Value,
        id: ExId,
        enc: TextEncoding,
    ) ApplyError!Value {
        return switch (v) {
            .scalar => |s| fromScalar(s),
            .object => |t| .{
                .object = switch (t) {
                    // A map is a [`Map`] (`hydrate.rs`:32`).
                    .map => .{ .map = Map.init(gpa, id) },
                    // **A table is a map as well, and upstream gives it an arm
                    // of its own** (`hydrate.rs`:35`) rather than sharing the
                    // first one's comma. **The split is the point**: a table
                    // is otherwise an arm no test in the tree can reach, and an
                    // arm no test can reach is an arm nobody has shown
                    // failing.
                    .table => .{ .map = Map.init(gpa, id) },
                    .list => .{ .list = List.init(gpa, id) },
                    .text => .{ .text = try Text.init(gpa, id, enc, "") },
                },
            },
        };
    }

    /// The eleven [`ScalarValue`] cases, one for one
    /// ([`Value::Scalar(scalar.into_owned())`](hydrate.rs):36`).
    pub fn fromScalar(s: ScalarValue) Value {
        return switch (s) {
            .null_value => .null_value,
            .bool_value => |b| .{ .bool_value = b },
            .int => |i| .{ .int = i },
            .uint => |u| .{ .uint = u },
            .float => |f| .{ .float = f },
            .str => |t| .{ .str = t },
            .bytes => |b| .{ .bytes = b },
            .counter => |c| .{ .counter = c },
            .timestamp => |t| .{ .timestamp = t },
            .actor_id => |a| .{ .actor_id = a },
            .unknown => |u| .{ .unknown = u },
        };
    }

    /// The [`ScalarValue`] this value is, or null for an object. The inverse of
    /// [`Value.fromScalar`] and the way a caller hands a mirror value back to
    /// the read API.
    pub fn toScalar(self: Value) ?ScalarValue {
        return switch (self) {
            .null_value => .null_value,
            .bool_value => |b| .{ .bool_value = b },
            .int => |i| .{ .int = i },
            .uint => |u| .{ .uint = u },
            .float => |f| .{ .float = f },
            .str => |t| .{ .str = t },
            .bytes => |b| .{ .bytes = b },
            .counter => |c| .{ .counter = c },
            .timestamp => |t| .{ .timestamp = t },
            .actor_id => |a| .{ .actor_id = a },
            .unknown => |u| .{ .unknown = u },
            .object => null,
        };
    }

    /// Whether this is a scalar rather than an object
    /// ([`Value::is_scalar`](hydrate.rs):56-58`).
    pub fn isScalar(self: Value) bool {
        return self != .object;
    }

    /// Whether this is an object rather than a scalar
    /// ([`Value::is_object`](hydrate.rs):67-69`).
    pub fn isObject(self: Value) bool {
        return self == .object;
    }

    /// The value as a string: a `str` is itself and **everything else is the
    /// object replacement character**
    /// ([`Value::as_str`](hydrate.rs):71-76`).
    pub fn asStr(self: Value) []const u8 {
        return switch (self) {
            .str => |s| s,
            else => object_replacement,
        };
    }

    /// How wide the value is in a sequence: one for a list, its own width in
    /// the encoding for a text ([`Value::width`](hydrate.rs):60-65`).
    pub fn width(self: Value, seq_type: SequenceType, enc: TextEncoding) usize {
        return switch (seq_type) {
            .list => 1,
            .text => enc.width(self.asStr()),
        };
    }

    /// The value as an integer, and zero for anything that is not one
    /// ([`Value::as_i64`](hydrate.rs):129-134`, over
    /// [`ScalarValue::as_i64_or_default`](hydrate.rs), `op_set2/types.rs`:247-254`).
    ///
    /// A counter and a timestamp are both the `i64` they carry
    /// ([`patches.scalarAsI64`](patches.zig)).
    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .int => |i| i,
            .uint => |u| std.math.cast(i64, u) orelse 0,
            .counter => |c| c.current,
            .timestamp => |t| t,
            else => 0,
        };
    }

    /// The object this value is, or null for a scalar. See the module doc's
    /// "refuse, do not invent" for why the mirror keeps the id at all.
    pub fn objId(self: *const Value) ?ExId {
        const o = switch (self.*) {
            .object => |*o| o,
            else => return null,
        };
        return switch (o.*) {
            .map => |m| m.id,
            .list => |l| l.id,
            .text => |t| t.id,
        };
    }

    /// Frees the structure this value owns, and **no byte payload**.
    ///
    /// **A scalar's bytes are the container's, not this value's**: the copy
    /// [`ownValue] made is recorded on the [`MapValue`] or [`ListValue`] that
    /// holds the value, and that record's `deinit` frees it. A value that has
    /// not been stored holds whatever its caller's buffer held, and there is
    /// nothing of the caller's to free here.
    ///
    /// **The containers in the `object` arm are freed with the allocator each
    /// one recorded**, which is why this takes none: a mirror handed back by
    /// one of the four `hydrate*` functions or built by [`Value.map`],
    /// [`Value.list`] or [`Value.text`] is released whole by this one call.
    ///
    /// **`self` is unusable afterwards, and only one owner of a given value may
    /// call this** — a by-value copy is a move, which the type doc says why.
    /// Calling it twice walks undefined bytes rather than reporting a double
    /// free.
    pub fn deinit(self: *Value) void {
        const o = switch (self.*) {
            .object => |*o| o,
            else => {
                self.* = undefined;
                return;
            },
        };
        switch (o.*) {
            .map => |*m| m.deinit(),
            .list => |*l| l.deinit(),
            .text => |*t| t.deinit(),
        }
        self.* = undefined;
    }

    /// Two values, by content. Upstream derives `PartialEq`
    /// (`hydrate.rs`:21`), and the port spells it out because a `str` is a
    /// slice.
    ///
    /// **The object id is not compared.** It is bookkeeping for the path walk
    /// and not part of what the value says; two mirrors built by different
    /// routes to the same tree are equal.
    pub fn eql(a: *const Value, b: *const Value) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .null_value => true,
            .bool_value => |x| x == b.bool_value,
            .int => |x| x == b.int,
            .uint => |x| x == b.uint,
            .float => |x| x == b.float,
            .str => |x| std.mem.eql(u8, x, b.str),
            .bytes => |x| std.mem.eql(u8, x, b.bytes),
            .counter => |x| x.eql(b.counter),
            .timestamp => |x| x == b.timestamp,
            .actor_id => |x| x.eql(b.actor_id),
            .unknown => |x| x.type_code == b.unknown.type_code and
                std.mem.eql(u8, x.bytes, b.unknown.bytes),
            // **The other side is read through its own tag**, not through the
            // tag `a` has: a union field is only addressable when the active
            // tag is known, and comparing an empty map with an empty list must
            // not read a `list` as a `map`.
            .object => |x| switch (x) {
                .map => |m| switch (b.object) {
                    .map => |other| m.eql(&other),
                    else => false,
                },
                .list => |l| switch (b.object) {
                    .list => |other| l.eql(&other),
                    else => false,
                },
                .text => |t| switch (b.object) {
                    .text => |other| t.eql(&other),
                    else => false,
                },
            },
        };
    }

    /// Applies `stream` in order ([`Value::apply_patches`](hydrate.rs):78-87`).
    ///
    /// The order is the contract, and it is `patches.zig`'s to keep: a patch
    /// whose path names an object the mirror has not been told about is a
    /// refusal ([`Failure.unknown_object`]), and the [`ExposeQueue`] is what
    /// guarantees the object was introduced first. See the module doc.
    ///
    /// **No allocator, and here is why**: the walk allocates only inside a
    /// container it has already reached, and every container records the
    /// allocator it was built with ([`Map.init`], [`List.init`],
    /// [`Text.init`]). A scalar at the root is a refusal, not an allocation.
    /// [`Value.applyOne`] takes `enc` because a text object splices in the
    /// document's own encoding, and every container carries that too — the
    /// parameter is the mirror's, and `apply` refuses an object whose encoding
    /// does not match it.
    pub fn applyPatches(
        self: *Value,
        enc: TextEncoding,
        stream: []const Patch,
    ) ApplyError!Applied {
        for (stream) |p| {
            switch (try self.applyOne(enc, p)) {
                .ok => {},
                .refused => |f| return .{ .refused = f },
            }
        }
        return .ok;
    }

    /// Walks `patch.path` root-first and hands the action to the object it
    /// names ([`Value::apply`](hydrate.rs):89-113`).
    ///
    /// **A path that does not resolve is a refusal, not a nearest match.** Four
    /// arms, in the order upstream states them:
    ///
    /// * an index into a list, or a key into a map, that the object has
    ///   (`hydrate.rs`:96-103`);
    /// * an index into a **text**, which is a no-op and not a refusal
    ///   (`hydrate.rs`:107`): a hydrated text holds an embedded block only by
    ///   its replacement characters, so a patch into a block's contents does
    ///   not change the text;
    /// * the path exhausted, so the action goes to the object the last step
    ///   reached (`hydrate.rs`:108-110`);
    /// * anything else is a refusal (`hydrate.rs`:111`).
    ///
    /// The two new checks are before all four: the object the step *leaves* is
    /// the one the mirror must be holding, and the object the action *names*
    /// is the one the path must have ended in. Both are what make the refusal
    /// of a missing object distinguishable from a missing key.
    pub fn applyOne(self: *Value, enc: TextEncoding, patch: Patch) ApplyError!Applied {
        var cur: *Value = self;
        for (patch.path, 0..) |step, i| {
            const here = cur.objId() orelse
                return refusedObject(patch, i, step.obj, null);
            if (!sameObject(here, step.obj)) return refusedObject(patch, i, step.obj, here);
            if (textIndexed(cur, step.prop)) return .ok;
            cur = cur.child(step.prop) orelse
                return .{ .refused = .{ .invalid_prop = .{ .at = i, .path = patch.path } } };
        }
        const end = patch.path.len;
        const here = cur.objId() orelse return refusedObject(patch, end, patch.obj, null);
        if (!sameObject(here, patch.obj)) return refusedObject(patch, end, patch.obj, here);
        const o = switch (cur.*) {
            .object => |*o| o,
            // **Unreachable, and kept as a refusal rather than as a trap.**
            // `cur.objId()` is the line above and it is non-null here, and a
            // value's id is null unless it is an object ([`Value.objId`]), so
            // the `else` cannot be taken. It is written as a refusal because
            // the alternative — `unreachable` — would turn a refactor of
            // either line into a crash instead of a wrong answer.
            else => return refusedObject(patch, end, patch.obj, null),
        };
        return switch (o.*) {
            .map => |*m| m.apply(enc, patch.action),
            .list => |*l| l.apply(enc, patch.action),
            .text => |*t| t.apply(enc, patch.action),
        };
    }

    /// The value at `prop` inside this one, or null when there is none.
    ///
    /// Upstream spells this as two `get_mut` calls inside one `match` and
    /// turns each miss into `ApplyInvalidProp` (`hydrate.rs`:96-103`); the
    /// refusal carries the step, so the three shapes are told apart here and
    /// the step is added by the caller.
    fn child(self: *Value, prop: Prop) ?*Value {
        const o = switch (self.*) {
            .object => |*o| o,
            // **Unreachable for the same reason**, one step earlier: the only
            // caller reaches here through `cur.objId() orelse return` ([`:724`]),
            // so `self` is an object by the time it is asked for a child.
            else => return null,
        };
        return switch (o.*) {
            .map => |*m| blk: {
                const key: ?[]const u8 = switch (prop) {
                    .key => |k| k,
                    .index => null,
                };
                const mv = m.entries.getPtr(key orelse break :blk null) orelse break :blk null;
                break :blk &mv.value;
            },
            .list => |*l| blk: {
                const i: ?usize = switch (prop) {
                    .index => |n| n,
                    .key => null,
                };
                const lv = l.items.getMut(i orelse break :blk null) orelse break :blk null;
                break :blk &lv.value;
            },
            // A text holds no children: its characters are its storage.
            .text => null,
        };
    }
};

/// The refusal for a step that found the wrong object, or no object.
fn refusedObject(patch: Patch, at: usize, want: ExId, got: ?ExId) Applied {
    return .{ .refused = .{ .unknown_object = .{
        .want = want,
        .got = got,
        .at = at,
        .path = patch.path,
    } } };
}

/// Whether `prop` addresses a **text** by index — the one path step into a
/// text that applies and changes nothing (`hydrate.rs`:104-107`).
fn textIndexed(v: *const Value, prop: Prop) bool {
    if (prop != .index) return false;
    return switch (v.*) {
        .object => |o| o == .text,
        // **Unreachable**, for the reason on [`Value.child`]'s own guard: this
        // is only called where `cur.objId()` is non-null.
        else => false,
    };
}

/// Whether two object ids name the same object **across two documents**, which
/// is upstream's [`PartialEq for ExId`][exid.rs:126-138]: two roots are equal,
/// and two ids are equal when the counter matches and the actor's **bytes**
/// match. The actor's *index* is the third field upstream carries and neither
/// [`Hash`](exid.rs:157-167) nor [`Ord`](exid.rs:184-194) has anything to say
/// about it, because it is not part of what the id *is*.
///
/// **This is not [`ExId.eql`](types.zig), and the difference is the whole
/// point.** [`ExId.eql`] compares the [`OpId`], and an `OpId` names the actor
/// by its position in the table it came from. Two documents that hold the same
/// operations can number their actors differently — `isolate` interns a
/// concurrency actor whose magic bytes are `0x13 b2 23 09`
/// ([`types.rs`:23](../../github-automerge-automerge/rust/automerge/src/types.rs)),
/// which sorts before most real actors and so lands at the *front* of the
/// sorted table and shifts every index at or above it
/// ([`op_set.rs`:1400-1405](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
/// Upstream carries the bytes on every `ExId` for exactly this reason and
/// repairs the index on each use ([`automerge.rs`:744-758](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
///
/// **An id that carries no actor is compared the old way**, on the index,
/// because there is nothing better to compare it by: a bare
/// [`ExId.id`](types.zig) is the shape [`ExId.fromParts`] makes from a caller
/// that has only an index. That is strictly the old behaviour, never worse.
fn sameObject(a: ExId, b: ExId) bool {
    const ao = a.opId() orelse return b.opId() == null;
    const bo = b.opId() orelse return false;
    if (ao.counter != bo.counter) return false;
    const aa = a.actorBytes() orelse return ao.eql(bo);
    const ba = b.actorBytes() orelse return ao.eql(bo);
    return aa.eql(ba);
}

// ── Map ─────────────────────────────────────────────────────────────────────

/// One register of a map mirror ([`hydrate::MapValue`](hydrate/map.rs):14-17`).
///
/// **The `ExId` upstream's `MapValue::new` is handed is not kept**
/// (`hydrate/map.rs`:81`); the mirror keeps the map's own instead, on
/// [`Map`], which is what [`Value.applyOne`] checks a path against.
pub const MapValue = struct {
    /// The value the register holds.
    value: Value,
    /// Whether the register holds a live conflict (`hydrate/map.rs`:16`).
    conflict: bool,
    /// The bytes this register owns, which [`Map.putOwned`] copied out of
    /// whatever produced the value. Null until it has, and null for a value
    /// with no bytes.
    owned: ?Owned = null,

    /// A register holding `v` ([`MapValue::new`](hydrate/map.rs):81`).
    ///
    /// **Upstream's takes the operation's `ExId` as its second argument and
    /// discards it** (`_id`); this file records the id on the [`Map`] instead,
    /// which is what [`Value.applyOne`] checks a path against — see the module
    /// doc's "refuse, do not invent".
    ///
    /// **The value's bytes are still the caller's.** Upstream's
    /// `MapValue::new` takes a `Value` by value and a Rust `Value` owns its
    /// bytes, so the register owns them the moment it is handed over
    /// ([`hydrate/map.rs`](hydrate/map.rs):81`); the port's [`Value`] is the
    /// borrowed view, so the copy happens in [`Map.putOwned`] — the one
    /// function that takes this record over.
    pub fn init(v: Value, conflict: bool) MapValue {
        return .{ .value = v, .conflict = conflict };
    }

    /// Frees the bytes this register owns and then the structure its value
    /// owns.
    ///
    /// **No allocator, and there is none to thread**: every buffer in
    /// [`Owned`] carries the allocator that lent it, so this stays the one
    /// free per buffer, and the payload goes first because the value reads
    /// its structure rather than its payload.
    pub fn deinit(self: *MapValue) void {
        if (self.owned) |*o| o.deinit();
        self.value.deinit();
        self.* = undefined;
    }

    /// Adds `n` to the counter this register holds
    /// ([`MapValue::increment`](hydrate/map.rs):85-92`).
    ///
    /// **False when the value is not a counter**, which is upstream's
    /// `Err(HydrateError::BadIncrement)` and this file's
    /// [`Failure.bad_increment`].
    pub fn increment(self: *MapValue, n: i64) bool {
        switch (self.value) {
            .counter => |*c| {
                c.current += n;
                return true;
            },
            else => return false,
        }
    }

    /// Two registers, by value and by conflict flag
    /// ([`#[derive(PartialEq)]`](hydrate/map.rs):13`).
    pub fn eql(a: *const MapValue, b: *const MapValue) bool {
        return a.conflict == b.conflict and a.value.eql(&b.value);
    }
};

/// A map mirror ([`hydrate::Map`](hydrate/map.rs):11`).
///
/// Upstream's is a `HashMap<String, MapValue>` and iteration order is whatever
/// the hash gives; so is this one's, and [`Map.eql`] does not depend on it.
pub const Map = struct {
    /// Every allocation this map makes, and every `deinit` frees, is taken
    /// with this. See the module doc's "the allocator lives in the containers".
    ///
    /// **This is the allocator `init` was handed, and it must not be replaced
    /// once the map has allocated.** Nothing checks it, and the field is
    /// reachable, because Zig has no private fields: a write between a
    /// [`Map.putOwned`] and a [`Map.deinit`] would have the key copy, the
    /// table and every [`MapValue`] buffer freed through an allocator that lent
    /// none of them. `deinit` frees with **this field** and not with the one
    /// the allocations came from, so a replaced field is a wrong free rather
    /// than a reported error.
    ///
    /// The allocator itself is borrowed, never released: it is an interface
    /// value the caller keeps.
    gpa: Allocator,
    /// Which object of the document this is the mirror of. See the module doc's
    /// "refuse, do not invent".
    id: ExId,
    /// The registers, in the hash's own order.
    entries: std.StringHashMapUnmanaged(MapValue) = .empty,

    /// An empty map over `id` ([`Map::new`](hydrate/map.rs):75-77`).
    ///
    /// Allocates nothing. `gpa` is recorded on the map and is not released by
    /// [`Map.deinit`] — the caller keeps it — and the map is usable for
    /// [`Map.putOwned`] from here on.
    pub fn init(gpa: Allocator, id: ExId) Map {
        return .{ .gpa = gpa, .id = id };
    }

    /// Frees every register — **the bytes it owns and every key this map
    /// copied** — and [`Map.putOwned`] is what owns all three.
    ///
    /// **This is the one free, and exactly one owner may run it.** A `Map`
    /// holds a hash table by value and Zig has no `Drop`, so a **by-value copy
    /// of a `Map` is a move and the source must not be deinit'd afterwards** —
    /// doing so frees the same table twice. Upstream cannot express the
    /// hazard: Rust's `Value` holds its `Map` by value too and `Drop` makes the
    /// copy safe (`hydrate.rs`:22-27`), and Zig has no way to make a type
    /// move-only. Two consequences are worth stating because both are easy to
    /// trip over:
    ///
    /// * [`Value`] embeds a `Map` by value in its `object` arm, so every
    ///   function here that takes or returns a `Value` copies one. That is
    ///   sound as long as **one** owner deinits, which is the rule the whole
    ///   port uses — see [`List.deinit`] and [`Text.deinit`] for the same.
    /// * [`Transaction.initRootFromHydrate`](transact.zig) takes a
    ///   `hydmod.Map` **by value**, so calling it copies the caller's map into
    ///   the parameter and frees nothing. The caller keeps ownership and must
    ///   deinit its own map; handing it a temporary would leak.
    ///
    /// A copy is indistinguishable from its source, so the rule cannot be
    /// checked at runtime either: it has to be a rule, and this comment is
    /// where it is written down.
    pub fn deinit(self: *Map) void {
        var values = self.entries.valueIterator();
        while (values.next()) |mv| mv.deinit();
        var keys = self.entries.keyIterator();
        while (keys.next()) |k| self.gpa.free(k.*);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many registers the map holds ([`Map::len`](hydrate/map.rs), the
    /// `Deref` to the `HashMap` at `:95-101`).
    pub fn count(self: *const Map) usize {
        return self.entries.count();
    }

    /// The value at `key`, or null ([`Map::get`](hydrate/map.rs):67-69`).
    pub fn get(self: *const Map, key: []const u8) ?*const Value {
        const mv = self.entries.getPtr(key) orelse return null;
        return &mv.value;
    }

    /// The value at `key` for writing, or null
    /// ([`Map::get_mut`](hydrate/map.rs):71-73`).
    pub fn getPtr(self: *Map, key: []const u8) ?*Value {
        const mv = self.entries.getPtr(key) orelse return null;
        return &mv.value;
    }

    /// Replaces `key`'s value, frees the old one, and **takes the register
    /// over**: from here the map owns the bytes `mv.value` borrowed.
    ///
    /// **The key and the value's bytes are both copied** into the map's own
    /// storage. Upstream moves the `String` out of the
    /// [`PatchAction`](patches.zig) (`hydrate/map.rs`:40-41`) and hands
    /// `MapValue::new` a `Value` that is already owned, because a Rust
    /// `String` and a Rust [`ScalarValue`] own their bytes
    /// ([`hydrate/map.rs`](hydrate/map.rs):81`). The port's key is a slice into
    /// the patch arena and its [`Value`] is the borrowed view, so both are
    /// copied here — **this is the one door a register comes through**, and
    /// [`Map.apply`], [`hydrateMap`] and every caller in the crate reach the
    /// mirror through it.
    ///
    /// **On an error the caller still owns `mv`, exactly as before**: the copy
    /// is released and none of the value's own structure is freed.
    pub fn putOwned(self: *Map, key: []const u8, mv: MapValue) Error!void {
        var held = mv;
        errdefer if (held.owned) |*o| o.deinit();
        held.owned = try ownValue(self.gpa, &held.value);
        if (self.entries.getPtr(key)) |old| {
            old.deinit();
            old.* = held;
            return;
        }
        const kept = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(kept);
        try self.entries.put(self.gpa, kept, held);
    }

    /// Drops `key` and frees what it held.
    ///
    /// **A key that is not there is not an error** — upstream's
    /// `self.0.remove(&key);` discards the `Option` (`hydrate/map.rs`:31`) —
    /// and the delete is idempotent.
    pub fn removeKey(self: *Map, key: []const u8) void {
        const gone = self.entries.fetchRemove(key) orelse return;
        var mv = gone.value;
        mv.deinit();
        self.gpa.free(gone.key);
    }

    /// Applies one action to this map ([`Map::apply`](hydrate/map.rs):24-65`).
    ///
    /// Four of the nine actions land here — `delete_map`, `put_map`,
    /// `increment` and `conflict` — and each of the other five is upstream's
    /// `Err(HydrateError::InvalidMapOp)` (`hydrate/map.rs`:63`), which is
    /// [`Failure.invalid_map_op`] here.
    ///
    /// **A refusal here leaves the map exactly as it was.** `increment` and
    /// `conflict` are reads that either find their register or refuse before
    /// writing, and `delete_map` cannot fail; `put_map` allocates a value, a
    /// key copy and a table slot, and every one of those failures releases the
    /// value it had built and stores nothing, so the register count and every
    /// value in it are what they were. The residue an action leaves when it
    /// **refuses** rather than failing is [`Applied.refused`]'s, and this is
    /// not one of the arms that leaves any.
    pub fn apply(self: *Map, enc: TextEncoding, action: PatchAction) ApplyError!Applied {
        const out: Applied = switch (action) {
            .delete_map => |a| blk: {
                self.removeKey(a.key);
                break :blk .ok;
            },
            .put_map => |a| blk: {
                var v = try Value.fromPatch(self.gpa, a.value, a.obj, enc);
                // Scoped to this body, and the same sentence as `List.apply`'s
                // `put_seq` arm: a successful `putOwned` has taken the value and
                // a failing one has not. `Map.putOwned`'s own doc promises the
                // caller still owns the register on an error, so the release is
                // this arm's to make — and what it drops is exactly the value's
                // own storage, because the register it would have gone into is
                // not in the map on either path.
                errdefer v.deinit();
                try self.putOwned(a.key, MapValue.init(v, a.conflict));
                break :blk .ok;
            },
            .increment => |a| blk: {
                const key = switch (a.prop) {
                    .key => |k| k,
                    .index => break :blk .{ .refused = .{ .invalid_map_op = action } },
                };
                const mv = self.entries.getPtr(key) orelse
                    break :blk .{ .refused = .{ .invalid_key = key } };
                if (!mv.increment(a.value)) break :blk .{ .refused = .bad_increment };
                break :blk .ok;
            },
            .conflict => |a| blk: {
                const key = switch (a.prop) {
                    .key => |k| k,
                    .index => break :blk .{ .refused = .{ .invalid_map_op = action } },
                };
                const mv = self.entries.getPtr(key) orelse
                    break :blk .{ .refused = .{ .invalid_key = key } };
                mv.conflict = true;
                break :blk .ok;
            },
            else => .{ .refused = .{ .invalid_map_op = action } },
        };
        return out;
    }

    /// Two maps, by content ([`#[derive(PartialEq)]`](hydrate/map.rs):10`).
    ///
    /// Order is not compared, because a `HashMap` has none. Counting the
    /// registers and finding every one of this map's in the other **is** set
    /// equality: keys are unique, so a miss on either side shows up.
    pub fn eql(a: *const Map, b: *const Map) bool {
        if (a.entries.count() != b.entries.count()) return false;
        var it = a.entries.iterator();
        while (it.next()) |entry| {
            const other = b.entries.getPtr(entry.key_ptr.*) orelse return false;
            if (!entry.value_ptr.eql(other)) return false;
        }
        return true;
    }
};

// ── List ────────────────────────────────────────────────────────────────────

/// One element of a list mirror ([`hydrate::ListValue`](hydrate/list.rs):19-23`).
pub const ListValue = struct {
    /// The value the element holds.
    value: Value,
    /// The marks the element carries, by name. Upstream's field is
    /// `HashMap<String, ScalarValue>` (`hydrate/list.rs`:20`) and nothing ever
    /// writes it; the port's [`applyMarks`](List.apply) does.
    marks: MarkSet,
    /// Whether the element's register holds a live conflict
    /// (`hydrate/list.rs`:22`).
    conflict: bool,
    /// The bytes this element owns: the payload of its value, and the name and
    /// the payload of each of its marks. Null until something has been
    /// stored, and null for an element with neither.
    owned: ?Owned = null,

    /// An element holding `v`, with an empty mark set
    /// ([`ListValue::new`](hydrate/list.rs):122-128`).
    ///
    /// **The value's bytes are still the caller's**, as on [`MapValue.init`]:
    /// the copy happens in [`List.push`] and [`List.apply`], the two doors an
    /// element comes through.
    pub fn init(gpa: Allocator, v: Value, conflict: bool) ListValue {
        return .{ .value = v, .marks = .init(gpa), .conflict = conflict };
    }

    /// Frees the marks and the value's own structure, in that order, and the
    /// bytes this element owns.
    ///
    /// **The bytes go last**, because [`ownMark`] repoints the mark set's
    /// entries at them and freeing them first would leave the set holding
    /// freed slices for the length of the other two frees.
    pub fn deinit(self: *ListValue) void {
        self.marks.deinit();
        self.value.deinit();
        if (self.owned) |*o| o.deinit();
        self.* = undefined;
    }

    /// Adds `n` to the counter this element holds
    /// ([`ListValue::increment`](hydrate/list.rs):113-120`). False when the
    /// value is not a counter.
    pub fn increment(self: *ListValue, n: i64) bool {
        switch (self.value) {
            .counter => |*c| {
                c.current += n;
                return true;
            },
            else => return false,
        }
    }

    /// Two elements, by value, by marks and by conflict flag
    /// ([`#[derive(PartialEq)]`](hydrate/list.rs):18`).
    ///
    /// **The marks are compared here**, and not in [`Text.eql`], because they
    /// are per element and so can say where. The two sets are name-sorted
    /// ([`src/marks.zig`](marks.zig)), so a zip is the comparison.
    pub fn eql(a: *const ListValue, b: *const ListValue) bool {
        if (a.conflict != b.conflict) return false;
        if (!a.value.eql(&b.value)) return false;
        if (a.marks.len() != b.marks.len()) return false;
        for (a.marks.entries.items, b.marks.entries.items) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name)) return false;
            if (!x.value.eql(y.value)) return false;
        }
        return true;
    }
};

/// A list mirror ([`hydrate::List`](hydrate/list.rs):10`).
///
/// Upstream's is a `SequenceTree<ListValue>` and so is this one
/// ([`src/sequence_tree.zig`](sequence_tree.zig)): the patch layer's
/// `Insert.values` is the same tree, and an `O(log n)` insert and remove is what
/// an index-addressed patch needs.
pub const List = struct {
    /// The allocator every element's mark set and every node is taken with.
    ///
    /// **This is the allocator `init` was handed, and it must not be replaced
    /// once the list has allocated** — see [`Map.gpa`], which states the rule
    /// and why nothing catches a breach of it. Here the buffer that goes with
    /// the wrong allocator is the tree's own nodes and every [`ListValue`]
    /// mark set, and [`List.deinit`] frees them through this field.
    ///
    /// The allocator itself is borrowed, never released.
    gpa: Allocator,
    /// Which object of the document this is the mirror of. See the module doc's
    /// "refuse, do not invent".
    id: ExId,
    /// The elements, in sequence order.
    items: seqtree.SequenceTree(ListValue),

    /// An empty list over `id` ([`List::new`](hydrate/list.rs):107-109`).
    ///
    /// Allocates nothing. `gpa` is recorded on the list and on the tree it
    /// builds, and is not released by [`List.deinit`] — the caller keeps it.
    pub fn init(gpa: Allocator, id: ExId) List {
        return .{ .gpa = gpa, .id = id, .items = .init(gpa) };
    }

    /// Frees every element and the tree that holds them.
    ///
    /// **This is the one free, and exactly one owner may run it** — the same
    /// rule as [`Map.deinit`], which says why a by-value copy is a move and
    /// not a share. [`Value`] embeds a `List` by value in its `object` arm, so
    /// every function here that takes or returns a `Value` copies one.
    ///
    /// `self.* = undefined` at the end is what makes the second free loud
    /// rather than silent: a mirror that deinits twice walks undefined bytes,
    /// and a no-op would hide the bug.
    pub fn deinit(self: *List) void {
        var it = self.items.iter();
        while (it.next()) |lv| {
            var owned = lv.*;
            owned.deinit();
        }
        self.items.deinit();
        self.* = undefined;
    }

    /// How many elements the list holds ([`List::len`](hydrate/list.rs):30-32`).
    pub fn count(self: *const List) usize {
        return self.items.len();
    }

    /// The value at `index`, or null ([`List::get`](hydrate/list.rs):99-101`).
    pub fn get(self: *const List, index: usize) ?*const Value {
        const lv = self.items.get(index) orelse return null;
        return &lv.value;
    }

    /// The value at `index` for writing, or null
    /// ([`List::get_mut`](hydrate/list.rs):95-97`).
    pub fn getPtr(self: *List, index: usize) ?*Value {
        const lv = self.items.getMut(index) orelse return null;
        return &lv.value;
    }

    /// Appends `v`, **and takes it over**: the element the list stores owns
    /// the bytes `v` borrowed ([`List::push`](hydrate/list.rs):103-105`).
    ///
    /// **On an error the caller still owns `v`**, exactly as before: only the
    /// copy goes back.
    pub fn push(self: *List, v: Value, conflict: bool) Error!void {
        var lv = try self.ownElement(ListValue.init(self.gpa, v, conflict));
        errdefer if (lv.owned) |*o| o.deinit();
        try self.items.push(lv);
    }

    /// `lv` with every byte it holds copied into its own storage.
    ///
    /// **This and [`Map.putOwned`] are the two doors**, and between them every
    /// scalar and every mark a mirror holds has crossed one of them. On an
    /// error the copy is released and nothing else is freed, so the caller's
    /// value is untouched.
    fn ownElement(self: *List, lv: ListValue) ApplyError!ListValue {
        var held = lv;
        errdefer if (held.owned) |*o| o.deinit();
        held.owned = try ownValue(self.gpa, &held.value);
        return held;
    }

    /// Applies one action to this list ([`List::apply`](hydrate/list.rs):38-93`).
    ///
    /// Five of the nine actions land here — `put_seq`, `insert`, `delete_seq`,
    /// `increment` and `conflict` — plus `mark`, which upstream leaves as
    /// `todo!()` (`hydrate/list.rs`:88-90`) and this file fills. The other four
    /// are upstream's `Err(HydrateError::InvalidListOp)` (`hydrate/list.rs`:91`).
    ///
    /// **A refusal leaves the list exactly as it was, except in `delete_seq`.**
    /// `put_seq`, `increment` and `conflict` find their element or refuse
    /// before writing to it, `insert` refuses nothing, and `mark` returns
    /// without a tag; so `delete_seq` is the one arm that can answer
    /// `.refused = .{ .invalid_index }` **with the list already shorter than it
    /// was.** It removes one element per iteration at `a.index` and stops at
    /// the first index the list does not have, so a delete of five elements
    /// against a list of two removes and frees both, leaves nothing at that
    /// index, and then refuses. **A caller must not retry the action as
    /// written**: the elements before the miss are gone and cannot be restored
    /// from the mirror, and a shorter `length` would name an index that is no
    /// longer there. [`Applied.refused`] states the same from the other side.
    ///
    /// **An `error.OutOfMemory` from the same arm is not a refusal and the
    /// residue is not the one above.** `SequenceTree.remove`
    /// (sequence_tree.zig:540) can fail after it has begun restructuring a
    /// node, so the list is left in whatever state that walk reached and the
    /// caller must not read it. This arm tells that failure apart from the
    /// index miss for exactly that reason: an `error.InvalidIndex` is a
    /// statement about the patch, and an `error.OutOfMemory` is not.
    pub fn apply(self: *List, enc: TextEncoding, action: PatchAction) ApplyError!Applied {
        const out: Applied = switch (action) {
            .put_seq => |a| blk: {
                const lv = self.items.getMut(a.index) orelse
                    break :blk .{ .refused = .{ .invalid_index = a.index } };
                var v = try Value.fromPatch(self.gpa, a.value, a.obj, enc);
                // Scoped to this body: a successful `put` has taken the value,
                // and a failing one has not.
                errdefer v.deinit();
                const fresh = try self.ownElement(ListValue.init(self.gpa, v, a.conflict));
                lv.deinit();
                lv.* = fresh;
                break :blk .ok;
            },
            .insert => |a| blk: {
                var it = a.values.iter();
                var n: usize = 0;
                while (it.next()) |iv| : (n += 1) {
                    var v = try Value.fromPatch(self.gpa, iv.value, iv.obj, enc);
                    // Scoped to this body: a successful `insert` has taken the
                    // value, and a failing one has not.
                    errdefer v.deinit();
                    const fresh = try self.ownElement(ListValue.init(self.gpa, v, iv.conflict));
                    errdefer releaseOwned(fresh.owned);
                    try self.items.insert(a.index + n, fresh);
                }
                break :blk .ok;
            },
            .delete_seq => |a| blk: {
                // Upstream ignores the result of each remove
                // (`hydrate/list.rs`:63-67`); a delete past the end of the
                // sequence is a stream that cannot be applied and is refused
                // here.
                //
                // **Element by element, and no rollback.** Every element this
                // loop got through is removed and freed before the miss, which
                // is the residue `List.apply`'s doc and `Applied.refused` both
                // promise. Upstream has the same shape and hides it by
                // dropping the result and answering `Ok` — the port refuses
                // instead, and says what the refusal cost.
                //
                // **`error.InvalidIndex` is the miss and nothing else.**
                // `SequenceTree.remove` can also fail on allocation, after it
                // has begun restructuring a node, and that is a different
                // fault with a different residue: the list is not readable
                // afterwards. Reporting it as `invalid_index` would tell the
                // caller the patch is wrong when the list is, so it is
                // propagated instead. Both error tags are already in
                // `ApplyError`, so nothing about the signature widens.
                for (0..a.length) |_| {
                    var gone = self.items.remove(a.index) catch |e| switch (e) {
                        error.InvalidIndex => break :blk .{ .refused = .{ .invalid_index = a.index } },
                        else => return e,
                    };
                    gone.deinit();
                }
                break :blk .ok;
            },
            .increment => |a| blk: {
                const i = switch (a.prop) {
                    .index => |i| i,
                    .key => break :blk .{ .refused = .{ .invalid_list_op = action } },
                };
                const lv = self.items.getMut(i) orelse
                    break :blk .{ .refused = .{ .invalid_index = i } };
                if (!lv.increment(a.value)) break :blk .{ .refused = .bad_increment };
                break :blk .ok;
            },
            .conflict => |a| blk: {
                const i = switch (a.prop) {
                    .index => |i| i,
                    .key => break :blk .{ .refused = .{ .invalid_list_op = action } },
                };
                const lv = self.items.getMut(i) orelse
                    break :blk .{ .refused = .{ .invalid_index = i } };
                lv.conflict = true;
                break :blk .ok;
            },
            .mark => |a| return self.applyMarks(a.marks),
            else => .{ .refused = .{ .invalid_list_op = action } },
        };
        return out;
    }

    /// Puts every run's marks on the elements the run covers, **and copies
    /// each name and each payload into the element**.
    ///
    /// **This is the arm upstream leaves as `todo!()`**
    /// (`hydrate/list.rs`:88-90`), filled out of the storage upstream declares:
    /// marks live on the element (`hydrate/list.rs`:20`), and a
    /// [`PatchAction.mark`](patches.zig) run is a half-open range of positions.
    /// A list's positions are elements, so a run is a range of elements and a
    /// run past the end stops at the end.
    ///
    /// Upstream's field is `HashMap<String, ScalarValue>` — **an owned name and
    /// an owned value** — so a mark there needs no lifetime. A
    /// [`MarkSet`](marks.zig) borrows, because the op set's does, so
    /// [`ownMark`] makes the copy and records it on the element's
    /// [`ListValue.owned`].
    fn applyMarks(self: *List, marks: []const Mark) ApplyError!Applied {
        for (marks) |m| {
            const stop = @min(m.end, self.items.len());
            var i = @min(m.start, stop);
            while (i < stop) : (i += 1) {
                // **Unreachable**, and the two `@min`s above are why: the loop
                // runs while `i < stop` and `stop <= items.len()`, so `i` is
                // always an index the list holds. It is left as a `break`
                // because it is the shape a reader expects and because
                // removing either `@min` should stop the walk, not trap.
                const lv = self.items.getMut(i) orelse break;
                if (lv.owned == null) lv.owned = .{ .gpa = self.gpa };
                ownMark(&lv.owned.?, &lv.marks, m.name, m.value) catch |e| return e;
            }
        }
        return .ok;
    }

    /// Two lists, by content ([`#[derive(PartialEq)]`](hydrate/list.rs):9`).
    pub fn eql(a: *const List, b: *const List) bool {
        if (a.items.len() != b.items.len()) return false;
        var ai = a.items.iter();
        var bi = b.items.iter();
        while (true) {
            const x = ai.next() orelse return true;
            const y = bi.next() orelse return false;
            if (!x.eql(y)) return false;
        }
    }
};

// ── Text ────────────────────────────────────────────────────────────────────

/// A text mirror ([`hydrate::Text`](hydrate/text.rs):8-11`).
///
/// The text is a [`patches.ConcreteTextValue`] over the document's own encoding,
/// so `len`, `asStr`, `splice` and `remove` are the port's already-tested
/// arithmetic. **The discipline differs in one place**: a patch's copy is arena
/// memory and the tree never frees an intermediate buffer, while a mirror owns
/// one buffer at a time, so [`Text.splice`] and [`Text.removeAt`] free the
/// buffer they replace.
pub const Text = struct {
    /// The allocator the text buffer, the mark set and every byte in
    /// `owned` are taken with.
    ///
    /// **This is the allocator `init` was handed, and it must not be replaced
    /// once the text has allocated** — see [`Map.gpa`], which states the rule
    /// and why nothing catches a breach of it.
    ///
    /// **This field and `value.gpa` are two records of one allocator, and both
    /// must stay the one `init` was given.** [`Text.splice`] and
    /// [`Text.removeAt`] free the buffer they replace through *this* field
    /// while [`ConcreteTextValue.splice`] takes the next one from *its* own, so
    /// a pair that disagreed would free a block with an allocator that never
    /// lent it. Nothing compares them.
    ///
    /// The allocator itself is borrowed, never released.
    gpa: Allocator,
    /// Which object of the document this is the mirror of. See the module doc's
    /// "refuse, do not invent".
    id: ExId,
    /// The text, owned.
    value: patches.ConcreteTextValue,
    /// The marks this text carries, by name. Upstream's field is
    /// `HashMap<String, ScalarValue>` (`hydrate/text.rs`:10`) and **nothing ever
    /// writes it** — the mark arm is a `todo!()` (`hydrate/text.rs`:57-59`).
    /// The port fills it, which is what makes a mark survive the round trip:
    /// an unmark is a mark whose value is null (`src/marks.zig`'s module doc,
    /// over `marks.rs`:170-171`), and a name held at null is a removal
    /// tombstone, not an active mark.
    marks: MarkSet,
    /// The bytes this text owns: the name and the payload of each of its
    /// marks. The text's own characters were never at risk — a
    /// [`ConcreteTextValue`] copies its buffer on every splice — so this is
    /// the marks and nothing else.
    owned: ?Owned = null,

    /// A text object holding `s` ([`Text::new`](hydrate/text.rs):64-69`).
    ///
    /// **This is the one constructor that allocates**, one buffer for `s`; a
    /// failure leaves nothing to release. `gpa` is recorded on the text, on
    /// its [`patches.ConcreteTextValue`] and on its mark set, and the caller
    /// keeps it — [`Text.deinit`] frees the three with it and never with
    /// anything else.
    pub fn init(gpa: Allocator, id: ExId, enc: TextEncoding, s: []const u8) Error!Text {
        return .{
            .gpa = gpa,
            .id = id,
            .value = try patches.ConcreteTextValue.init(gpa, s, enc),
            .marks = .init(gpa),
        };
    }

    /// Frees the mark set, the text buffer and the bytes this text owns, in
    /// that order.
    ///
    /// **This is the one free, and exactly one owner may run it** — the same
    /// rule as [`Map.deinit`], which says why a by-value copy is a move and
    /// not a share. [`Value`] embeds a `Text` by value in its `object` arm,
    /// so every function here that takes or returns a `Value` copies one.
    pub fn deinit(self: *Text) void {
        self.marks.deinit();
        self.value.deinit();
        if (self.owned) |*o| o.deinit();
        self.* = undefined;
    }

    /// The text as a string ([`impl From<&Text> for String`](hydrate/text.rs):72-76`).
    pub fn asStr(self: *const Text) []const u8 {
        return self.value.asStr();
    }

    /// The text's length in the document's encoding
    /// ([`ConcreteTextValue::len`](patches.zig)).
    pub fn count(self: *const Text) usize {
        return self.value.len();
    }

    /// Inserts `text` at unit `index` ([`TextValue::splice`](hydrate/text.rs):40`).
    ///
    /// **This frees the buffer it replaces, and the free is not optional.**
    /// `ConcreteTextValue.splice` drops its old reference without freeing, which
    /// is right for a patch inside an arena and wrong for an owning mirror: an
    /// ordinary allocator reports the old buffer as leaked on every call that
    /// skips this line. The `old` local is what makes it a free of the
    /// *previous* block and not of the one `splice` just installed, and it is
    /// freed with [`Text.gpa`].
    ///
    /// **`error.InvalidCharacter` is upstream's `InvalidEncoding`**
    /// (`hydrate/text.rs`:32`): `byteOffset` reached a byte that is not valid
    /// UTF-8. The refusal is made by [`Text.apply`], which is where an
    /// [`Applied`] exists.
    ///
    /// **On either error the text is unchanged and nothing was allocated.**
    /// `ConcreteTextValue.splice` resolves the index before it allocates, so
    /// neither `error.InvalidCharacter` nor `error.OutOfMemory` reaches the
    /// free below, and `value.bytes` still names the buffer it named before the
    /// call.
    pub fn splice(self: *Text, index: usize, text: []const u8) Error!void {
        const old = self.value.bytes;
        try self.value.splice(index, text);
        self.gpa.free(old);
    }

    /// Removes the one unit at `index`
    /// ([`TextValue::remove`](hydrate/text.rs):51-56`).
    ///
    /// Out of range is a no-op. This UTF-8-backed value cannot retain a partial
    /// scalar: deleting one UTF-8 byte or UTF-16 unit that splits a scalar
    /// returns `error.InvalidCharacter` without changing the text.
    ///
    /// A replacement buffer is freed with [`Text.gpa`] only after success;
    /// no-ops retain their buffer. Allocation and encoding errors leave the
    /// text unchanged.
    pub fn removeAt(self: *Text, index: usize) Error!void {
        const old = self.value.bytes;
        try self.value.remove(index);
        if (self.value.bytes.ptr != old.ptr) self.gpa.free(old);
    }

    /// Removes a bounded span in one mutation. Overshoot clamps to the end;
    /// zero length and out-of-range starts retain the original buffer.
    /// Both boundaries must be valid for the text's encoding.
    fn removeRange(self: *Text, index: usize, length: usize) Error!void {
        const old = self.value.bytes;
        try self.value.removeRange(index, length);
        if (self.value.bytes.ptr != old.ptr) self.gpa.free(old);
    }

    /// Applies one action to this text ([`Text::apply`](hydrate/text.rs):23-62`).
    ///
    /// Four of the nine land here — `splice_text`, `insert`, `put_seq` and
    /// `delete_seq` — plus `mark`, and the other four are upstream's
    /// `Err(HydrateError::InvalidTextOp(p))` (`hydrate/text.rs`:60`).
    ///
    /// **A splice's marks are applied too** (`hydrate/text.rs`:29` discards
    /// them). They are the resolved mark set over the span the splice created
    /// ([`patches.PatchBuilder.spliceText`](patches.zig)), and they arrive again
    /// as a separate `mark` action; `MarkSet.put` is idempotent, so applying
    /// both leaves the one value and there is no arm in which the mirror's
    /// marks depend on which of the two a stream happens to carry.
    ///
    /// **Three arms can leave partial changes when they fail or refuse.**
    /// A caller that needs to know what the mirror holds after a non-`.ok`
    /// answer needs the following rules:
    ///
    /// * `delete_seq` **removes the bounded span in one mutation**. Lengths
    ///   past the end remove only what is there and report success; zero
    ///   length and out-of-range starts change nothing. This UTF-8-backed
    ///   mirror refuses boundaries that split a scalar (or a grapheme in
    ///   grapheme mode) as [`Failure.invalid_encoding`]. Allocation failure
    ///   and encoding refusal leave the whole action's text unchanged.
    /// * `insert` splices **one value at a time**, so a refusal on the third
    ///   value leaves the first two in the text. Invalid text encountered
    ///   while resolving the insertion index is refused as
    ///   [`Failure.invalid_encoding`].
    /// * `put_seq` removes the unit at `a.index` **before** it splices the
    ///   replacement, so a refusal from the splice leaves the text one unit
    ///   shorter with nothing in its place. `splice_text` commits its splice
    ///   first and stores its marks after, so an `error.OutOfMemory` from
    ///   [`Text.putMarks`] leaves the text changed and the marks not all there.
    /// * Every other arm either refuses before it writes or, for `mark`, has no
    ///   partial state to leave: [`Text.putMark`] copies each name and payload
    ///   before it stores either, so a failure leaves the marks already stored
    ///   and the one that failed absent.
    pub fn apply(self: *Text, enc: TextEncoding, action: PatchAction) ApplyError!Applied {
        const out: Applied = switch (action) {
            .splice_text => |a| blk: {
                self.splice(a.index, a.value.asStr()) catch |e| break :blk encodingRefusal(e) orelse return e;
                if (a.marks) |*m| try self.putMarks(m);
                break :blk .ok;
            },
            .insert => |a| blk: {
                // The index advances by the **width** of what was spliced, not
                // by one: a text position is a code point, a code unit or a
                // grapheme (`hydrate/text.rs`:35-44`).
                var index = a.index;
                var it = a.values.iter();
                while (it.next()) |iv| {
                    var v = try Value.fromPatch(self.gpa, iv.value, iv.obj, enc);
                    errdefer v.deinit();
                    const s = v.asStr();
                    self.splice(index, s) catch |e| break :blk encodingRefusal(e) orelse return e;
                    index += enc.width(s);
                }
                break :blk .ok;
            },
            .put_seq => |a| blk: {
                self.removeAt(a.index) catch |e| break :blk encodingRefusal(e) orelse return e;
                var v = try Value.fromPatch(self.gpa, a.value, a.obj, enc);
                errdefer v.deinit();
                self.splice(a.index, v.asStr()) catch |e| break :blk encodingRefusal(e) orelse return e;
                break :blk .ok;
            },
            .delete_seq => |a| blk: {
                self.removeRange(a.index, a.length) catch |e| break :blk encodingRefusal(e) orelse return e;
                break :blk .ok;
            },
            .mark => |a| blk: {
                for (a.marks) |m| try self.putMark(m.name, m.value);
                break :blk .ok;
            },
            else => .{ .refused = .{ .invalid_text_op = action } },
        };
        return out;
    }

    /// `error.InvalidCharacter` turned into the refusal upstream spells
    /// `InvalidEncoding` ([`HydrateError`](hydrate.rs):174`), or null for every
    /// other error — which is then propagated.
    fn encodingRefusal(e: Error) ?Applied {
        return switch (e) {
            error.InvalidCharacter => .{ .refused = .invalid_encoding },
            else => null,
        };
    }

    /// Puts `name` at `v` in this text's mark set, **copying the name and the
    /// payload**.
    ///
    /// **Every write to a mirror's mark set goes through here**, which is what
    /// makes "a mirror owns its marks" a fact about one function rather than
    /// about every call site. Upstream's field is
    /// `HashMap<String, ScalarValue>` (`hydrate/text.rs`:10`) — an owned name
    /// and an owned value — so nothing there borrows.
    fn putMark(self: *Text, name: []const u8, v: ScalarValue) Error!void {
        if (self.owned == null) self.owned = .{ .gpa = self.gpa };
        try ownMark(&self.owned.?, &self.marks, name, v);
    }

    /// Puts every entry of `m` into this text's mark set, **copying each name
    /// and each payload**.
    fn putMarks(self: *Text, m: *const MarkSet) Error!void {
        for (m.entries.items) |entry| try self.putMark(entry.name, entry.value);
    }

    /// Two texts, by their text.
    ///
    /// **The marks are not compared, and the reason is the storage, not the
    /// port.** `Text.marks` is a name-to-value map (`hydrate/text.rs`:10`, and
    /// [`MarkSet`](marks.zig)), so it says what each mark name last held and
    /// nothing about where — "bold is true over `[0, 2)` and absent over
    /// `[2, 4)`" and "bold is true everywhere" are the same map. Comparing it
    /// would make two texts that are not equal look equal, so the marks are
    /// read through [`Text.marks`] and the property that matters is the one
    /// the `"a mark applies to text and an unmark tombstones it"` test pins: a
    /// live mark is a value, an unmark is that name at null.
    ///
    /// [`ListValue.eql`] **does** compare marks, because there they are
    /// per-element and so can say where.
    pub fn eql(a: *const Text, b: *const Text) bool {
        return std.mem.eql(u8, a.asStr(), b.asStr());
    }
};

// ── Hydration from the op set ────────────────────────────────────────────────

/// The op-set surface [`hydrateMap`], [`hydrateList`], [`hydrateText`] and
/// [`hydrateOp`] read, by name ([`assertSet`]).
///
/// **Six methods, and they are upstream's own.** `topOps` is
/// `OpSet::top_ops` (`hydrate.rs`:251`), `opIdText` is `OpSet::to_string`
/// (`hydrate.rs`:252`, `op_set.rs`:1093-1098`), `idToExid` is
/// `OpSet::id_to_exid` (`hydrate.rs`:253`), `textEncoding` is the
/// `text_encoding` field of `OpSet` (`op_set.rs`:64`) read out, and `text` and
/// `calculateMarksAt` are `OpSet::text` (`hydrate.rs`:284`) and
/// `OpSet::calculate_marks` (`automerge.rs`:1569-1573`).
///
/// **The list is one and not one per entry point**, because
/// [`hydrateOp`] dispatches to the other three: a `Set` handed to
/// [`hydrateMap`], [`hydrateList`] or [`hydrateOp`] reaches all six, and one
/// type has to satisfy all four. [`hydrateText`] reads three of them and is
/// checked against the same list, which costs a caller that wants only a text
/// three declarations it will not call.
pub const set_decls = [_][]const u8{
    "topOps",
    "opIdText",
    "idToExid",
    "textEncoding",
    "text",
    "calculateMarksAt",
};

/// The error set `OpSet.topOps` answers, written out because it is private
/// to `op_set.zig` (`:188`) and [`assertSet`] has to name it.
///
/// It is `TopError` itself — the three sets `op_set.zig` composes it from, in
/// the same three terms.
const TopReadError = opiter.ReadOpError || InternalError || Error;

/// The type `Set.topOps` yields once the error union is off.
///
/// **`OpSet.topOps` answers `TopError!Self.Winners`** (`op_set.zig`:2581`) and
/// `Self.Winners` is the cursor's own type, so for a `Set` this file has never
/// seen there is no way to write it down. [`assertSet`] takes it off the
/// declaration instead, so what it checks is that the result is an error union
/// and that the parameter list matches; the caller still names its own cursor
/// in the one place it builds one.
fn topOpsSuccess(comptime Set: type) type {
    const R = @typeInfo(@TypeOf(@field(Set, "topOps"))).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload,
        else => @compileError("op set " ++ @typeName(Set) ++
            ".topOps must return an error union; OpSet.topOps answers TopError!Self.Winners" ++
            " (op_set.zig:2581)"),
    };
}

/// Fails to compile unless `Set` carries every declaration in
/// [`set_decls`], and carries it with these signatures.
///
/// **This is the whole of the op-set contract in this file**, and it is a
/// comptime check rather than a trait for the reason
/// [`patches.assertDoc`](patches.zig) gives: every call site below resolves at
/// comptime and inlines, so nothing here is dynamic and nothing here allocates.
/// A `Set` that is missing a name gets one `@compileError` naming the
/// declaration and this list, rather than a member error with no
/// replacement — which is what the four signatures would otherwise publish as
/// their entire contract.
///
/// **The signature checks are the point as much as the names**, the argument
/// [`assertQueryTerm`](../opset/op_query.zig) makes. A `text` that answered a
/// plain `[]const u8` would need an adapter inventing a free the walk does not
/// describe; a `topOps` that took no `?Clock` could not answer a historical
/// read at all; and a `calculateMarksAt` that dropped the clock would silently
/// give a mirror built at past heads the present's marks, which is the mistake
/// [`hydrateText`]'s own doc is about. [`topOpsSuccess`] says why its success
/// type is the one thing not checked.
pub fn assertSet(comptime Set: type) void {
    inline for (set_decls) |name| {
        if (!@hasDecl(Set, name)) {
            @compileError("op set " ++ @typeName(Set) ++ " has no " ++ name ++
                "; the reads hydrate.rs:244-302 make are in set_decls");
        }
    }
    const top_ops: *const fn (*Set, ExId, ?Clock) TopReadError!topOpsSuccess(Set) = &Set.topOps;
    const op_id_text: *const fn (*const Set, Allocator, OpId) Error![]u8 = &Set.opIdText;
    const id_to_exid: *const fn (*const Set, OpId) ExId = &Set.idToExid;
    const text_encoding: *const fn (*const Set) TextEncoding = &Set.textEncoding;
    const text: *const fn (*Set, Allocator, ExId, ?Clock) TopReadError![]u8 = &Set.text;
    const marks_at: *const fn (*Set, Allocator, ExId, ?Clock) TopReadError![]Mark = &Set.calculateMarksAt;
    _ = top_ops;
    _ = op_id_text;
    _ = id_to_exid;
    _ = text_encoding;
    _ = text;
    _ = marks_at;
}

/// The key a winner hangs by, as a string
/// ([`OpSet::to_string(top.elemid_or_key())`](hydrate.rs):252`,
/// `op_set2/op_set.rs`:1093-1098`).
///
/// A map key is the key; a sequence element is `"<counter>@<actor>"`. The
/// caller owns the result.
fn winnerKey(comptime Set: type, set: *const Set, gpa: Allocator, key: KeyRef) Error![]u8 {
    if (key.keyStr()) |s| return gpa.dupe(u8, s);
    return set.opIdText(gpa, key.seq.id);
}

/// The mirror of `obj` as a map ([`OpSet::hydrate_map`](hydrate.rs):244-259`).
///
/// One walk over the register winners, in order. The conflict flag is the
/// winner's own ([`Op.conflict`](opset/op.zig), read at `hydrate.rs`:254`) and
/// the value is [`hydrateOp`].
///
/// **The caller owns the result, and `set` is borrowed for the call only.**
/// Every byte the mirror holds — each key [`winnerKey`] produced and each
/// value's payload — is copied on the way in ([`Map.putOwned`]), so the mirror
/// outlives the next mutation of `set` and nothing in it points into the op
/// set. Release it with **one** [`Value.deinit`], which frees the whole tree;
/// [`Value`] says why a copy of the result is a move and not a second owner.
///
/// **On an error the caller owns nothing.** The map and every value built
/// before the failure are released by the `errdefer` before the error leaves,
/// so no tag of [`OpHydrateError`] returns a partial object: a map that is
/// empty, a map that is short and a map that is complete are not three
/// outcomes a caller has to tell apart. `gpa` is recorded on the containers and
/// is never released here — the caller keeps it.
///
/// `clock` is borrowed too, for the call: it is a [`Clock`] view and the
/// mirror holds no part of it. `Set` must carry [`set_decls`]; [`assertSet`]
/// says what that means and fails the build naming what is missing.
pub fn hydrateMap(
    comptime Set: type,
    set: *Set,
    gpa: Allocator,
    obj: ExId,
    clock: ?Clock,
) OpHydrateError!Value {
    assertSet(Set);
    var map = Map.init(gpa, obj);
    errdefer map.deinit();
    var tops = try set.topOps(obj, clock);
    defer tops.deinit(gpa);
    while (try tops.next()) |top| {
        const key = try winnerKey(Set, set, gpa, top.elemidOrKey());
        defer gpa.free(key);
        var value = try hydrateOp(Set, set, gpa, top, clock);
        errdefer value.deinit();
        try map.putOwned(key, MapValue.init(value, top.conflict));
    }
    return .{ .object = .{ .map = map } };
}

/// The mirror of `obj` as a list ([`OpSet::hydrate_list`](hydrate.rs):261-276`).
///
/// One walk over the register winners, in order; the conflict flag is the
/// winner's own ([`Op.conflict`](opset/op.zig), read at `hydrate.rs`:271`) and
/// the value is [`hydrateOp`]. The order of the winners **is** the element
/// order, which is why there is no index to pass.
///
/// **The caller owns the result, and `set` is borrowed for the call only.**
/// Every byte the mirror holds — each element's payload, and the name and
/// payload of each mark [`List.push`] stores — is copied on the way in, so the
/// mirror outlives the next mutation of `set` and nothing in it points into the
/// op set. Release it with **one** [`Value.deinit`], which frees the tree and
/// every element's mark set; [`Value`] says why a copy of the result is a move
/// and not a second owner.
///
/// **On an error the caller owns nothing.** The list and every element built
/// before the failure are released by the `errdefer` before the error leaves,
/// so no tag of [`OpHydrateError`] returns a partial list: an empty list and a
/// complete one are the only two answers. `gpa` is recorded on the containers
/// and is never released here — the caller keeps it.
///
/// `clock` is borrowed for the call and the mirror holds no part of it. `Set`
/// must carry [`set_decls`]; [`assertSet`] says what that means and fails the
/// build naming what is missing.
pub fn hydrateList(
    comptime Set: type,
    set: *Set,
    gpa: Allocator,
    obj: ExId,
    clock: ?Clock,
) OpHydrateError!Value {
    assertSet(Set);
    var list = List.init(gpa, obj);
    errdefer list.deinit();
    var tops = try set.topOps(obj, clock);
    defer tops.deinit(gpa);
    while (try tops.next()) |top| {
        var value = try hydrateOp(Set, set, gpa, top, clock);
        errdefer value.deinit();
        try list.push(value, top.conflict);
    }
    return .{ .object = .{ .list = list } };
}

/// The mirror of `obj` as a text ([`OpSet::hydrate_text`](hydrate.rs):278-286`).
///
/// **The marks are filled, and that is a deliberate addition.** Upstream is
/// `Text::new(encoding, self.text(obj, clock))` — the text and nothing else,
/// and the `marks` field of [`Text`] is written by no code path in the crate
/// (`hydrate/text.rs`:10, and the mark arm is a `todo!()` at `:57-59`).
/// This folds the mark rows into the set, because a mirror that drops marks
/// cannot answer "what does this text look like", and the round trip this file
/// exists to make honest would then be comparing two texts that both happen to
/// be unmarked.
///
/// **The fold takes `clock`, and that is the second half of the same decision.**
/// The note this replaces said "`calculate_marks` takes no clock upstream
/// either, so this is the one place the two disagree, and it is upstream's
/// shape rather than a choice". **Upstream has no fold here at all, so there is
/// no upstream shape to defer to**, and the premise was false besides:
/// [`Automerge::calculate_marks`]
/// (`automerge.rs`:1569-1573) *does* take `clock: Option<Clock>` — what takes
/// no clock is the indexed arm it dispatches to,
/// [`OpSet.calculateMarks`](opset/op_set.zig) (`op_set.rs`:961-1024), and the
/// arm is reached only when the clock is `None` (`automerge.rs`:1585).
///
/// So the choice is the port's, and it is made here: **a mirror that honours
/// its clock in every other line honours it in this one.** [`set.text`] above
/// takes `clock`, and a mirror built at historical heads that carried the
/// present's marks would answer "what does this text look like" about a text
/// that no longer exists in that state. [`OpSet.calculateMarksAt`]
/// (opset/op_set.zig) is upstream's own dispatch over that clock, so this is
/// upstream's rule applied to a fold the port added, not a second fold.
///
/// **The caller owns the result, and `set` is borrowed for the call only.**
/// The text itself is a copy ([`Text.init`] dupes it) and every mark's name and
/// payload is a copy too, both through [`Text.putMark`], so the mirror outlives
/// the next mutation of `set` and nothing in it points into the op set. Release
/// it with **one** [`Value.deinit`], which frees the text buffer, the mark set
/// and the mark bytes; [`Value`] says why a copy of the result is a move and
/// not a second owner. `gpa` is recorded on the text and is never released
/// here — the caller keeps it — and `clock` is borrowed for the call.
///
/// **On an error the caller owns nothing.** The text built so far and its
/// marks are released by the `errdefer` and the two buffers this function
/// allocated for itself are freed by their `defer`s, so a failure after three
/// marks and a failure after none are the same thing to the caller: no value.
/// [`Text.init`] registers nothing itself, and its own failure to duplicate
/// `text` leaves nothing to release either.
///
/// `Set` must carry [`set_decls`]; [`assertSet`] says what that means and
/// fails the build naming what is missing.
pub fn hydrateText(
    comptime Set: type,
    set: *Set,
    gpa: Allocator,
    obj: ExId,
    clock: ?Clock,
) OpHydrateError!Value {
    assertSet(Set);
    const text = try set.text(gpa, obj, clock);
    defer gpa.free(text);
    var out = try Text.init(gpa, obj, set.textEncoding(), text);
    errdefer out.deinit();
    // **`:1585` — the clock picks the arm**, the two indexes for the present
    // and the walk of the rows it sees for anything else. Unscoped, this is
    // the very call it was before, and an isolation now reports the marks the
    // isolation has rather than the marks the document has.
    const runs = try set.calculateMarksAt(gpa, obj, clock);
    defer gpa.free(runs);
    // **Through [`Text.putMark`], not `MarkSet.put`.** `runs` is freed on the
    // line above and each `Mark`'s name and payload point into the op set's
    // own columns, so a `put` that borrowed would leave this mirror reading
    // freed memory the moment this function returned — and an op set that
    // grows or renumbers would change a mark under the caller's feet.
    for (runs) |m| try out.putMark(m.name, m.value);
    return .{ .object = .{ .text = out } };
}

/// The mirror of one op's value ([`OpSet::hydrate_op`](hydrate.rs):288-302`).
///
/// **Four makes, one put, and upstream's `panic!("invalid op to hydrate")`**
/// (`hydrate.rs`:300`) as [`error.InvalidOp`](error.zig). The panic cannot
/// happen: a register winner is never an increment ([`Op::visible`](opset/op.zig))
/// and a mark row carries no value, so the arm is unreachable from a top-op
/// walk — but it is reachable from a caller who hands this an arbitrary row, and
/// a refusal is the right answer there.
///
/// **The result is owned in one of two different ways, and which one the tag
/// decides.** A `make` arm returns a container that was built here: it owns its
/// storage, it is taken with `gpa`, and one [`Value.deinit`] frees all of it. A
/// `.set` arm returns a scalar whose bytes are **the op set's, not the
/// caller's** — [`Value.fromScalar`] copies nothing — so that `Value` owns no
/// buffer at all, its `deinit` frees nothing, and the caller must copy or
/// consume it before the next mutation of `set`. Upstream's `'static` `Value`
/// ([`hydrate.rs`](hydrate.rs):22-27`, over the owned [`ScalarValue`] at
/// `value.rs`:519-522`) has no such split, and [`Value`] spells out which
/// release applies to which tag.
///
/// The two callers here ([`hydrateMap`], [`hydrateList`]) store through
/// [`Map.putOwned`] and [`List.push`] at once, so nothing is read past the end
/// of a walk and neither split is observable to them. `clock` is borrowed for
/// the call. `Set` must carry [`set_decls`]; [`assertSet`] says what that means.
///
/// **On an error the caller owns nothing**: `error.InvalidOp` is the only tag
/// this function raises for the row itself, and the four `make` arms forward
/// the residue of the function they call — which is none, each of them
/// releasing everything it had built before the error left.
pub fn hydrateOp(
    comptime Set: type,
    set: *Set,
    gpa: Allocator,
    op: opmod.Op,
    clock: ?Clock,
) OpHydrateError!Value {
    assertSet(Set);
    const id = set.idToExid(op.id());
    return switch (op.action()) {
        .make_map => try hydrateMap(Set, set, gpa, id, clock),
        // A table hydrates as a map, and it is upstream's own arm and not the
        // first one's comma (`hydrate.rs`:296`) — see [`Value.fromPatch`] for
        // why the two are spelled apart.
        .make_table => try hydrateMap(Set, set, gpa, id, clock),
        .make_list => try hydrateList(Set, set, gpa, id, clock),
        .make_text => try hydrateText(Set, set, gpa, id, clock),
        .set => Value.fromScalar(op.value()),
        .delete, .increment, .mark => error.InvalidOp,
    };
}

// ── The document the hand-built streams read ────────────────────────────────

/// A value-iterator over a fixed slice, as [`PatchLog`]'s `doc_decls` wants
/// one. **Constructing one allocates nothing**, which is the property the
/// document contract asks of the three range walks
/// ([`patches.assertDoc`](patches.zig)).
fn Slice(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []const T,
        index: usize = 0,

        pub fn next(self: *Self) Error!?T {
            if (self.index >= self.items.len) return null;
            const at = self.index;
            self.index += 1;
            return self.items[at];
        }
    };
}

/// A hand-built document: the whole surface [`PatchLog`] reads, with the
/// content written out by hand.
///
/// **The document is a comptime parameter**, which is how the hand-built
/// streams below hand one over, and writing the content out is what makes the
/// expectations hand-derived: what the expose queue does is a function of what
/// this says the document holds.
const TestDoc = struct {
    objs: []const Obj = &.{},
    gpa: Allocator = testing.allocator,

    pub const Obj = struct {
        id: ExId,
        typ: ObjType,
        /// The object this one hangs by, or null for the root.
        parent: ?ExId = null,
        /// Its visible map registers.
        map_items: []const patches.MapItem = &.{},
        /// Its visible list elements.
        list_items: []const patches.ListItem = &.{},
        /// Its text spans.
        span_items: []const patches.Span = &.{},
    };

    fn find(self: *const TestDoc, id: ExId) ?*const Obj {
        for (self.objs) |*o| {
            if (o.id.eql(id)) return o;
        }
        return null;
    }

    pub fn textEncoding(self: *const TestDoc) TextEncoding {
        _ = self;
        return .unicode_code_point;
    }

    pub fn idToExid(self: *const TestDoc, id: OpId) ExId {
        _ = self;
        return if (id.eql(OpId.root)) .root else .{ .id = id };
    }

    pub fn objectType(self: *const TestDoc, id: ExId) ?ObjType {
        const o = self.find(id) orelse return null;
        return o.typ;
    }

    pub fn objectParent(self: *const TestDoc, id: ExId) ?ExId {
        const o = self.find(id) orelse return null;
        return o.parent;
    }

    /// An empty clock. Only a log with `heads` set asks for one, and no test
    /// here sets it; the value is a total function of the input, which is all
    /// [`PatchLog`] needs of it.
    pub fn clockAt(self: *const TestDoc, heads: []const types.ChangeHash) Clock {
        _ = heads;
        return Clock.initEmpty(self.gpa);
    }

    pub fn actorList(self: *const TestDoc) []const ActorId {
        _ = self;
        return &.{};
    }

    pub fn mapRangeFor(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(patches.MapItem) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.map_items };
    }

    pub fn listRangeFor(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(patches.ListItem) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.list_items };
    }

    pub fn spans(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(patches.Span) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.span_items };
    }
};

/// Every action names one encoding, so every test that says "the document" means
/// this one. **Named `doc_enc`, not `enc`**, because the public API takes an
/// `enc` parameter and Zig will not let a container-scope declaration be
/// shadowed by one.
const doc_enc: TextEncoding = .unicode_code_point;

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
}

fn ex(ctr: u32, actor: ActorIdx) ExId {
    return .{ .id = OpId.init(ctr, actor) };
}

fn elem(ctr: u32, actor: ActorIdx) ElemId {
    return ElemId.fromOpId(OpId.init(ctr, actor));
}

fn sval(v: []const u8) ScalarValue {
    return .{ .str = v };
}

fn cval(v: i64) ScalarValue {
    return .{ .counter = .{ .current = v } };
}

fn ival(v: i64) ScalarValue {
    return .{ .int = v };
}

// ── 1. The round trip ───────────────────────────────────────────────────────

/// The one actor the round-trip document is built by.
const rt_actor: ActorId = ActorId.init("aaaaaaaaaaaaaaaa");

/// The three objects the round-trip change makes, which are the ids of the ops
/// that make them.
const rt_nested: ExId = .{ .id = opId(1, 0) };
const rt_list: ExId = .{ .id = opId(2, 0) };
const rt_text: ExId = .{ .id = opId(3, 0) };

/// The string table an op set borrows. The same shape as the one in
/// [`patches.zig`](patches.zig) and for the same reason: the table must live at
/// one address for as long as the set does.
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

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) err.ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// One row of a fixture: everything `ChangeOp.init` takes, and the successors
/// the row holds.
const Rec = struct {
    ctr: u32,
    obj: ExId = .root,
    key: KeyRef,
    actor: ActorIdx = 0,
    is_insert: bool = false,
    act: optypes.Action = .set,
    val: ScalarValue = .null_value,
    mark: ?[]const u8 = null,
    expand: bool = false,
    pred: []const OpId = &.{},
    succ: []const opmod.SuccEntry = &.{},
};

/// One document, built out of [`Rec`]s and merged into.
const Fixture = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    const Set = opsetmod.OpSet(opmod.ChangeOp);

    fn init(gpa: Allocator, actors: []const ActorId) !*Fixture {
        const self = try gpa.create(Fixture);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, .unicode_code_point, self.table.asTable()) catch |e| {
            self.table.deinit();
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Splices `rows` in as the base document. No patches: a base is not a
    /// change, and the round trip has no base — every register the mirror ends
    /// up with is created by a change the log saw.
    fn build(self: *Fixture, pos: usize, rows: []const Rec) !void {
        const ops = try mkOps(self.gpa, rows);
        defer freeOps(self.gpa, ops);
        _ = try self.set.splice(pos, ops);
    }

    /// Merges `rows` in as **one** batch, writing every patch through `log`.
    fn mergeInto(
        self: *Fixture,
        comptime L: type,
        log: *L,
        rows: []const Rec,
        changes: []const Change,
    ) !void {
        const ops = try mkOps(self.gpa, rows);
        defer freeOps(self.gpa, ops);
        var batch_apply = batchmod.BatchApply(L).init(self.gpa, ops);
        defer batch_apply.deinit();
        try batch_apply.apply(&self.set, changes, log);
    }
};

fn mkOp(gpa: Allocator, r: Rec) !opmod.ChangeOp {
    var op = try opmod.ChangeOp.init(
        gpa,
        OpId.init(r.ctr, r.actor),
        r.obj,
        r.act,
        r.key,
        r.val,
        r.is_insert,
        r.expand,
        r.mark,
        r.pred,
    );
    errdefer op.deinit(gpa);
    try op.succs.appendSlice(gpa, r.succ);
    return op;
}

fn mkOps(gpa: Allocator, rows: []const Rec) ![]opmod.ChangeOp {
    const ops = try gpa.alloc(opmod.ChangeOp, rows.len);
    errdefer gpa.free(ops);
    var made: usize = 0;
    errdefer for (ops[0..made]) |*o| o.deinit(gpa);
    for (rows, 0..) |r, i| {
        ops[i] = try mkOp(gpa, r);
        made += 1;
    }
    return ops;
}

fn freeOps(gpa: Allocator, ops: []opmod.ChangeOp) void {
    for (ops) |*o| o.deinit(gpa);
    gpa.free(ops);
}

/// A change with no ops, which is all the merge reads: the actor, the sequence
/// number, and where its ops start.
fn bareChange(actor: ActorId, seq: u64, start: u64, max_op: u64, tag: u8) Change {
    return .{
        .bytes = &.{},
        .header_len = 0,
        .actor = actor,
        .deps = &.{},
        .hash = .{ .bytes = [_]u8{tag} ** 32 },
        .time = 0,
        .message = &.{},
        .seq = seq,
        .start_op = start,
        .max_op = max_op,
        .other_actors = &.{},
    };
}

/// The change that builds the whole round-trip document: a root map with a
/// nested map, a list, a text object, a counter and a register that the second
/// change deletes; and a text of two elements carrying a mark and an unmark.
///
/// **The mark is a begin and an end, and so is the unmark** — a mark is two
/// operations (`src/marks.zig`'s module doc, over `transaction/inner.rs`:827-857`),
/// each an insert into the text, and the end is the operation immediately after
/// its begin. An unmark is a begin whose value is null
/// (`transaction/inner.rs`:879-891`), so the two pairs are the same shape with
/// one different value.
const rt_first = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("nested"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 3, .key = .fromStr("text"), .act = .make_text },
    .{ .ctr = 4, .key = .fromStr("n"), .val = cval(5) },
    .{ .ctr = 5, .key = .fromStr("gone"), .val = sval("bye") },
    .{ .ctr = 6, .obj = rt_nested, .key = .fromStr("a"), .val = sval("A") },
    .{ .ctr = 7, .obj = rt_nested, .key = .fromStr("b"), .val = ival(7) },
    .{ .ctr = 8, .obj = rt_nested, .key = .fromStr("c"), .val = .{ .float = 1.5 } },
    .{ .ctr = 9, .obj = rt_list, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("one") },
    .{ .ctr = 10, .obj = rt_list, .key = .fromElemId(elem(9, 0)), .is_insert = true, .val = ival(2) },
    .{ .ctr = 11, .obj = rt_list, .key = .fromElemId(elem(10, 0)), .is_insert = true, .val = .{ .bool_value = true } },
    .{ .ctr = 12, .obj = rt_list, .key = .fromElemId(elem(11, 0)), .is_insert = true, .val = .{ .bytes = "\x01\x02" } },
    .{ .ctr = 13, .obj = rt_list, .key = .fromElemId(elem(12, 0)), .is_insert = true, .act = .make_map },
    // Two text elements, "ab" and "cd", so the text is "abcd" and a mark has
    // two positions to sit between.
    .{ .ctr = 14, .obj = rt_text, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("ab") },
    .{ .ctr = 15, .obj = rt_text, .key = .fromElemId(elem(14, 0)), .is_insert = true, .val = sval("cd") },
    // "bold" over the first element: the begin at 0 and the end at 2.
    .{ .ctr = 16, .obj = rt_text, .key = .fromElemId(ElemId.head()), .is_insert = true, .act = .mark, .val = .{ .bool_value = true }, .mark = "bold" },
    .{ .ctr = 17, .obj = rt_text, .key = .fromElemId(elem(14, 0)), .is_insert = true, .act = .mark, .val = .null_value },
    // The unmark over the second element: a begin at 2 whose value is null, and
    // its end at 4.
    .{ .ctr = 18, .obj = rt_text, .key = .fromElemId(elem(14, 0)), .is_insert = true, .act = .mark, .val = .null_value, .mark = "bold" },
    .{ .ctr = 19, .obj = rt_text, .key = .fromElemId(elem(15, 0)), .is_insert = true, .act = .mark, .val = .null_value },
};

const pred_four = [_]OpId{opId(4, 0)};
const pred_five = [_]OpId{opId(5, 0)};

/// The second change: the counter moves, and the register the first one made is
/// deleted.
const rt_second = [_]Rec{
    .{ .ctr = 20, .key = .fromStr("gone"), .act = .delete, .pred = &pred_five },
    .{ .ctr = 21, .key = .fromStr("n"), .act = .increment, .val = ival(3), .pred = &pred_four },
};

/// The round-trip document, as [`TestDoc`] sees it.
///
/// **Only the object entries matter** — the log asks the document for an
/// object's parent and type to resolve a path, and for the parent's registers to
/// say which property the child hangs by. Nothing is exposed, so no content is
/// ever read. The entries are the *final* state, which is the state the mirror
/// must end up in.
const rt_root_items = [_]patches.MapItem{
    .{ .key = "list", .value = .{ .object = .list }, .id = opId(2, 0), .conflict = false },
    .{ .key = "nested", .value = .{ .object = .map }, .id = opId(1, 0), .conflict = false },
    .{ .key = "n", .value = .{ .scalar = cval(8) }, .id = opId(4, 0), .conflict = false },
    .{ .key = "text", .value = .{ .object = .text }, .id = opId(3, 0), .conflict = false },
};

const rt_nested_items = [_]patches.MapItem{
    .{ .key = "a", .value = .{ .scalar = sval("A") }, .id = opId(6, 0), .conflict = false },
    .{ .key = "b", .value = .{ .scalar = ival(7) }, .id = opId(7, 0), .conflict = false },
    .{ .key = "c", .value = .{ .scalar = .{ .float = 1.5 } }, .id = opId(8, 0), .conflict = false },
};

const rt_list_items = [_]patches.ListItem{
    .{ .index = 0, .value = .{ .scalar = sval("one") }, .id = opId(9, 0), .conflict = false },
    .{ .index = 1, .value = .{ .scalar = ival(2) }, .id = opId(10, 0), .conflict = false },
    .{ .index = 2, .value = .{ .scalar = .{ .bool_value = true } }, .id = opId(11, 0), .conflict = false },
    .{ .index = 3, .value = .{ .scalar = .{ .bytes = "\x01\x02" } }, .id = opId(12, 0), .conflict = false },
    .{ .index = 4, .value = .{ .object = .map }, .id = opId(13, 0), .conflict = false },
};

const rt_objs = [_]TestDoc.Obj{
    .{ .id = .root, .typ = .map, .map_items = &rt_root_items },
    .{ .id = rt_nested, .typ = .map, .parent = .root, .map_items = &rt_nested_items },
    .{ .id = rt_list, .typ = .list, .parent = .root, .list_items = &rt_list_items },
    .{ .id = rt_text, .typ = .text, .parent = .root },
};

test "a patch stream replayed into a mirror equals the document it came from" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, &.{rt_actor});
    defer f.destroy();

    const doc: TestDoc = .{ .objs = &rt_objs };

    // **One stream, read straight out of the log, and the log is gone before
    // the mirror is built.** A [`Patches`](patches.zig) owns its payload, so a
    // patch outlives the [`PatchLog`](patches.zig) it came from; a round trip
    // that read the mirror with the log still alive would pass on a stream that
    // does not own what it hands out, and that is the failure this test exists
    // to catch.
    var stream: ?patches.Patches = null;
    defer if (stream) |*p| p.deinit();
    {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        try f.mergeInto(patches.PatchLog, &log, &rt_first, &.{
            bareChange(rt_actor, 1, 1, 19, 0x11),
        });
        // **The first view is finalised**, which is what a document does when it
        // moves to another point in history ([`PatchLog::finishCurrentView`],
        // upstream `patch_log.rs`:290-303`): the first change's patches move into
        // the log's completed batch and its events are dropped, so the second
        // change's events sort and emit on their own. `makePatches` then returns
        // one stream — the completed patches and then the current ones — which is
        // upstream's `diff(cursor, heads)`.
        try log.finishCurrentView(TestDoc, &doc, &.{});
        try f.mergeInto(patches.PatchLog, &log, &rt_second, &.{
            bareChange(rt_actor, 2, 20, 21, 0x22),
        });
        stream = try log.makePatches(TestDoc, &doc);
    }
    const ps = &stream.?;

    // Replay.
    var mirror = Value.map(gpa);
    defer mirror.deinit();
    switch (try mirror.applyPatches(doc_enc, ps.slice())) {
        .ok => {},
        .refused => |f2| {
            try printFailure(gpa, ps, f2);
            return error.TestUnexpectedResult;
        },
    }

    // **Against the document**, read straight off the op set.
    var source = try hydrateMap(Fixture.Set, &f.set, gpa, .root, null);
    defer source.deinit();
    if (!mirror.eql(&source)) {
        const a = try renderTop(gpa, &mirror);
        defer gpa.free(a);
        const b = try renderTop(gpa, &source);
        defer gpa.free(b);
        std.debug.print("replayed:\n  {s}\ndocument:\n  {s}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }

    // **And against a hand-declared tree**, which is the arm that is not two
    // copies of one answer: a wrong `patches.zig` fails the second check even
    // when the two agree with each other.
    var expected = Value.map(gpa);
    defer expected.deinit();
    {
        const m = &expected.object.map;
        // The register the second change deleted is **absent**, not null: a
        // `delete_map` removes the key and puts nothing in its place
        // ([`Map::apply`](hydrate/map.rs):30-33`).
        try m.putOwned("n", MapValue.init(.{ .counter = .init(8) }, false));

        var nested = Value.map(gpa);
        const n = &nested.object.map;
        try n.putOwned("a", MapValue.init(.{ .str = "A" }, false));
        try n.putOwned("b", MapValue.init(.{ .int = 7 }, false));
        try n.putOwned("c", MapValue.init(.{ .float = 1.5 }, false));
        try m.putOwned("nested", MapValue.init(nested, false));

        var list = Value.list(gpa);
        const l = &list.object.list;
        try l.push(.{ .str = "one" }, false);
        try l.push(.{ .int = 2 }, false);
        try l.push(.{ .bool_value = true }, false);
        try l.push(.{ .bytes = "\x01\x02" }, false);
        try l.push(Value.map(gpa), false);
        try m.putOwned("list", MapValue.init(list, false));

        try m.putOwned("text", MapValue.init(
            try Value.text(gpa, doc_enc, "abcd"),
            false,
        ));
    }
    // Four keys: the three objects and the counter. Not five — `"gone"` was
    // deleted, and the second change's `increment` moved `"n"` rather than
    // replacing it.
    try testing.expectEqual(@as(usize, 4), expected.object.map.count());
    if (!mirror.eql(&expected)) {
        const a = try renderTop(gpa, &mirror);
        defer gpa.free(a);
        const b = try renderTop(gpa, &expected);
        defer gpa.free(b);
        std.debug.print("replayed:\n  {s}\ndeclared:\n  {s}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }

    // **The marks agree too**, and separately: `Text.eql` does not compare them
    // (see its doc), so the claim is made here against the document's own fold.
    const mirrored_text = mirror.object.map.get("text") orelse return error.TestUnexpectedResult;
    var mt = &mirrored_text.object.text;
    var wanted: MarkSet = .init(gpa);
    defer wanted.deinit();
    {
        const runs = try f.set.calculateMarks(gpa, rt_text);
        defer gpa.free(runs);
        for (runs) |run| try wanted.put(run.name, run.value);
    }
    if (mt.marks.len() != wanted.len()) {
        std.debug.print("marks: replayed {d} names, document {d}\n", .{ mt.marks.len(), wanted.len() });
        return error.TestUnexpectedResult;
    }
    for (mt.marks.entries.items, wanted.entries.items) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !x.value.eql(y.value)) {
            std.debug.print("mark {s}: replayed {any}, document {any}\n", .{ x.name, x.value, y.value });
            return error.TestUnexpectedResult;
        }
    }
    // **A live mark survives the tombstone filter, and a tombstone would not.**
    // The document's own fold leaves `bold` live — the unmark pair in the change
    // is closed by its own end, so it removes the mark rather than holding it at
    // null — and so the mirror must hold it live too. `withoutUnmarks` is the
    // check that "live" means live ([`MarkSet::withoutUnmarks`](marks.zig),
    // upstream `marks.rs`:180-187`), and it is applied to a **copy** because it
    // consumes the set it is given.
    try testing.expectEqual(@as(usize, 1), mt.marks.len());
    try testing.expectEqualStrings("bold", mt.marks.entries.items[0].name);
    try testing.expect(mt.marks.entries.items[0].value == .bool_value);
    var live = try withoutUnmarks(gpa, &mt.marks);
    defer live.deinit();
    try testing.expectEqual(@as(usize, 1), live.len());
    try testing.expectEqualStrings("bold", live.entries.items[0].name);
}

// ── Reporting a failure ─────────────────────────────────────────────────────

/// Fails, naming the patch stream and the refusal, because a refusal without
/// the patch that caused it is a refusal nobody can act on.
fn printFailure(
    gpa: Allocator,
    stream: *const patches.Patches,
    f: Failure,
) Error!void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    switch (f) {
        .unknown_object => |u| {
            try line.appendSlice(gpa, "refused: object ");
            try printId(gpa, &line, u.want);
            try line.print(gpa, " wanted at step {d}/{d} of the path, mirror holds ", .{
                u.at, u.path.len,
            });
            if (u.got) |g| try printId(gpa, &line, g) else try line.appendSlice(gpa, "a scalar");
            try line.append(gpa, '\n');
            std.debug.print("{s}", .{line.items});
        },
        .invalid_prop => |p| std.debug.print(
            "refused: step {d}/{d} of the path does not resolve\n",
            .{ p.at, p.path.len },
        ),
        .invalid_key => |k| std.debug.print("refused: no key \"{s}\"\n", .{k}),
        .invalid_index => |i| std.debug.print("refused: no index {d}\n", .{i}),
        .bad_increment => std.debug.print("refused: increment of a non-counter\n", .{}),
        .invalid_map_op => |a| std.debug.print("refused: not a map action: {s}\n", .{@tagName(a)}),
        .invalid_list_op => |a| std.debug.print("refused: not a list action: {s}\n", .{@tagName(a)}),
        .invalid_text_op => |a| std.debug.print("refused: not a text action: {s}\n", .{@tagName(a)}),
        .invalid_encoding => std.debug.print("refused: text is not valid in the encoding\n", .{}),
    }
    for (stream.slice()) |p| {
        const text = try patches.formatPatch(gpa, p);
        defer gpa.free(text);
        std.debug.print("  {s}\n", .{text});
    }
}

/// Applies `stream` and fails, naming it, unless every action applied.
fn applyAll(
    gpa: Allocator,
    v: *Value,
    stream: *const patches.Patches,
    what: []const u8,
) !void {
    switch (try v.applyPatches(doc_enc, stream.slice())) {
        .ok => {},
        .refused => |f| {
            std.debug.print("{s}:\n", .{what});
            try printFailure(gpa, stream, f);
            return error.TestUnexpectedResult;
        },
    }
}

/// Applies `stream` and fails, naming the refusal, unless it is refused.
fn expectRefusal(
    v: *Value,
    stream: *const patches.Patches,
    what: []const u8,
) !Failure {
    switch (try v.applyPatches(doc_enc, stream.slice())) {
        .ok => {
            std.debug.print("{s}: applied, and should not have\n", .{what});
            return error.TestUnexpectedResult;
        },
        .refused => |f| return f,
    }
}

/// `"<counter>@<actor index>"` — the shape `formatPatch` writes an id in, so a
/// refusal and the stream it came from read the same way.
fn printId(gpa: Allocator, out: *std.ArrayList(u8), id: ExId) Error!void {
    const op = id.opId() orelse {
        try out.appendSlice(gpa, "root");
        return;
    };
    try out.print(gpa, "{}@{}", .{ op.counter, op.actor });
}

// ── Rendering a mirror ──────────────────────────────────────────────────────

/// [`MarkSet::withoutUnmarks`] on a **copy** of `set`.
///
/// The real one takes the set by value and frees it
/// ([`src/marks.zig`](marks.zig) says so, over upstream's
/// `marks.rs`:180-187`), which is right upstream and wrong for a test that
/// wants to look at the original afterwards. The caller owns the result.
fn withoutUnmarks(gpa: Allocator, set: *const MarkSet) Error!MarkSet {
    var pairs: std.ArrayList(MarkSet.Entry) = .empty;
    defer pairs.deinit(gpa);
    try pairs.appendSlice(gpa, set.entries.items);
    const copy = try MarkSet.fromPairs(gpa, pairs.items);
    return copy.withoutUnmarks();
}

/// The key of `p`, or the empty string when it is an index — a test reads the
/// path a refusal carries and does not care which arm it was.
fn propKey(p: Prop) []const u8 {
    return switch (p) {
        .key => |k| k,
        .index => "",
    };
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Writes `v` in a shape that shows every register, every element, every mark
/// and every conflict flag.
///
/// **This is not [`Value.eql`] and must not drift into it.** The tests below
/// compare renderings to say "these two mirrors differ", which needs the
/// conflicts and the marks that `Text.eql` deliberately leaves out — a map has no
/// order, so a rendering is the only place two maps can be *seen* to differ.
fn renderTree(gpa: Allocator, out: *std.ArrayList(u8), v: *const Value) Error!void {
    switch (v.*) {
        .null_value => try out.appendSlice(gpa, "null"),
        .bool_value => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .int => |i| try out.print(gpa, "int({d})", .{i}),
        .uint => |u| try out.print(gpa, "uint({d})", .{u}),
        .float => |f| try out.print(gpa, "f64({x})", .{@as(u64, @bitCast(f))}),
        .str => |s| try out.print(gpa, "str(\"{s}\")", .{s}),
        .bytes => |b| {
            try out.appendSlice(gpa, "bytes(");
            for (b, 0..) |x, i| {
                if (i > 0) try out.append(gpa, ' ');
                try out.print(gpa, "{d}", .{x});
            }
            try out.append(gpa, ')');
        },
        .counter => |c| try out.print(gpa, "ctr({d})", .{c.current}),
        .timestamp => |t| try out.print(gpa, "ts({d})", .{t}),
        .actor_id => |a| {
            var buf: [32]u8 = undefined;
            err.hexInto(a.bytes[0..], &buf);
            try out.print(gpa, "actor({s})", .{buf});
        },
        .unknown => |u| {
            try out.print(gpa, "unk({d},", .{u.type_code});
            for (u.bytes, 0..) |x, i| {
                if (i > 0) try out.append(gpa, ' ');
                try out.print(gpa, "{d}", .{x});
            }
            try out.append(gpa, ')');
        },
        .object => |o| switch (o) {
            .map => |m| {
                var keys: std.ArrayList([]const u8) = .empty;
                defer keys.deinit(gpa);
                var it = m.entries.keyIterator();
                while (it.next()) |k| try keys.append(gpa, k.*);
                std.mem.sort([]const u8, keys.items, {}, lessStr);
                try out.appendSlice(gpa, "map{");
                for (keys.items, 0..) |k, i| {
                    if (i > 0) try out.append(gpa, ',');
                    const mv = m.entries.getPtr(k).?;
                    try out.print(gpa, "\"{s}\":", .{k});
                    if (mv.conflict) try out.append(gpa, '!');
                    try renderTree(gpa, out, &mv.value);
                }
                try out.append(gpa, '}');
            },
            .list => |l| {
                try out.appendSlice(gpa, "list[");
                var it = l.items.iter();
                var n: usize = 0;
                while (it.next()) |lv| : (n += 1) {
                    if (n > 0) try out.append(gpa, ',');
                    if (lv.conflict) try out.append(gpa, '!');
                    if (lv.marks.len() > 0) {
                        try out.appendSlice(gpa, "m");
                        try renderMarks(gpa, out, &lv.marks);
                    }
                    try renderTree(gpa, out, &lv.value);
                }
                try out.append(gpa, ']');
            },
            .text => |t| {
                try out.print(gpa, "text(\"{s}\"", .{t.asStr()});
                if (t.marks.len() > 0) {
                    try out.appendSlice(gpa, " marks=");
                    try renderMarks(gpa, out, &t.marks);
                }
                try out.append(gpa, ')');
            },
        },
    }
}

fn renderMarks(gpa: Allocator, out: *std.ArrayList(u8), set: *const MarkSet) Error!void {
    try out.append(gpa, '{');
    for (set.entries.items, 0..) |e, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.print(gpa, "\"{s}\"=", .{e.name});
        try renderTree(gpa, out, &Value.fromScalar(e.value));
    }
    try out.append(gpa, '}');
}

/// The whole mirror as one line. The caller owns the result.
fn renderTop(gpa: Allocator, v: *const Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try renderTree(gpa, &out, v);
    return out.toOwnedSlice(gpa);
}

// ── The skeleton every hand-built action is applied on ──────────────────────

const sk_list: ExId = .{ .id = opId(1, 0) };
const sk_nested: ExId = .{ .id = opId(2, 0) };
const sk_text: ExId = .{ .id = opId(3, 0) };
/// An id the document knows nothing about, for the arm where the path names an
/// object the mirror is not holding.
const other_obj: ExId = .{ .id = opId(77, 0) };

const sk_root_items = [_]patches.MapItem{
    .{ .key = "list", .value = .{ .object = .list }, .id = opId(1, 0), .conflict = false },
    .{ .key = "nested", .value = .{ .object = .map }, .id = opId(2, 0), .conflict = false },
    .{ .key = "text", .value = .{ .object = .text }, .id = opId(3, 0), .conflict = false },
};

const sk_objs = [_]TestDoc.Obj{
    .{ .id = .root, .typ = .map, .map_items = &sk_root_items },
    .{ .id = sk_list, .typ = .list, .parent = .root },
    .{ .id = sk_nested, .typ = .map, .parent = .root },
    .{ .id = sk_text, .typ = .text, .parent = .root },
};

const sk_doc: TestDoc = .{ .objs = &sk_objs };

/// The skeleton: a root map holding a list of two, a nested map with one
/// counter, and a text of two characters.
fn seedLog(log: *patches.PatchLog) void {
    log.putMap(.root, "list", .{ .object = .list }, opId(1, 0), false, false);
    log.insert(sk_list, 0, .{ .scalar = sval("a") }, opId(50, 0), false);
    log.insert(sk_list, 1, .{ .scalar = ival(2) }, opId(51, 0), false);
    log.putMap(.root, "nested", .{ .object = .map }, opId(2, 0), false, false);
    log.putMap(sk_nested, "c", .{ .scalar = cval(5) }, opId(52, 0), false, false);
    log.putMap(.root, "text", .{ .object = .text }, opId(3, 0), false, false);
    log.splice(sk_text, 0, "ab", null);
}

/// A mirror holding [`seedLog`], and the patches that built it.
///
/// **The mirror owns its own bytes, so the order of the two frees does not
/// matter** — see the module doc's "what a mirror owns". The log the patches
/// were built from does **not** have to outlive anything either, and
/// [`seeded`] drops it before handing the mirror over: that is the property
/// the module doc claims, and a helper that quietly kept the log alive would
/// be a test that cannot fail.
const Seed = struct {
    value: Value,
    patches: patches.Patches,

    fn deinit(self: *Seed) void {
        self.value.deinit();
        self.patches.deinit();
    }
};

/// A fresh mirror holding the skeleton.
///
/// **The log is deinited before this returns, on purpose.** A
/// [`Patches`](patches.zig) owns its payload — that is the whole of
/// [`Patches.init`](patches.zig)'s arena — so a mirror built from one outlives
/// the [`PatchLog`](patches.zig) it came from. Reading the mirror with the log
/// still alive would make every test below pass on a patch stream that does not
/// own what it hands out, so the log goes first.
fn seeded(gpa: Allocator) !Seed {
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        seedLog(&log);
        break :blk log.makePatches(TestDoc, &sk_doc);
    };
    errdefer ps.deinit();
    var v = Value.map(gpa);
    errdefer v.deinit();
    switch (try v.applyPatches(doc_enc, ps.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &ps, f);
            return error.TestUnexpectedResult;
        },
    }
    return .{ .value = v, .patches = ps };
}

// ── 2. Every action, one at a time ──────────────────────────────────────────

fn actPutMap(log: *patches.PatchLog) void {
    log.putMap(.root, "new", .{ .scalar = ival(7) }, opId(60, 0), false, false);
}

fn actPutSeq(log: *patches.PatchLog) void {
    log.putSeq(sk_list, 0, .{ .scalar = sval("Z") }, opId(61, 0), false, false);
}

fn actInsert(log: *patches.PatchLog) void {
    log.insert(sk_list, 1, .{ .scalar = .{ .bool_value = true } }, opId(62, 0), false);
}

fn actSpliceText(log: *patches.PatchLog) void {
    log.splice(sk_text, 1, "X", null);
}

fn actIncrement(log: *patches.PatchLog) void {
    log.incrementMap(sk_nested, "c", 3, opId(64, 0));
}

fn actConflict(log: *patches.PatchLog) void {
    log.flagConflict(sk_nested, .{ .key = "c" });
}

fn actDeleteMap(log: *patches.PatchLog) void {
    log.deleteMap(.root, "nested");
}

fn actDeleteSeq(log: *patches.PatchLog) void {
    log.deleteSeq(sk_list, 0, 1);
}

fn actMark(log: *patches.PatchLog) void {
    var set = MarkSet.fromPairs(log.gpa, &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
    }) catch return;
    defer set.deinit();
    log.mark(sk_text, 0, 1, &set);
}

/// The two orders of a mark and an unmark of the **same** name, as the
/// [`PatchAction.mark`] payload ([`patch.rs`](patch.rs):88`).
///
/// **File-scope `const`s**, which is the property that matters: the rows hold
/// calls, so a `&.{…}` written inside a function would hand the caller a
/// pointer into a dead frame.
const mark_then_unmark = [_]Mark{
    Mark.init("bold", .{ .bool_value = true }, 0, 1),
    Mark.init("bold", .null_value, 1, 2),
};
const unmark_then_mark = [_]Mark{
    Mark.init("bold", .null_value, 1, 2),
    Mark.init("bold", .{ .bool_value = true }, 0, 1),
};

/// One entry per [`PatchAction`] variant, in the order `patch.rs`:33-89` states
/// them. The test below checks that this list covers every tag the union has,
/// so a tenth variant fails the build rather than going untested.
const actions = [_]struct {
    name: []const u8,
    tag: std.meta.Tag(PatchAction),
    write: *const fn (*patches.PatchLog) void,
}{
    .{ .name = "put_map", .tag = .put_map, .write = actPutMap },
    .{ .name = "put_seq", .tag = .put_seq, .write = actPutSeq },
    .{ .name = "insert", .tag = .insert, .write = actInsert },
    .{ .name = "splice_text", .tag = .splice_text, .write = actSpliceText },
    .{ .name = "increment", .tag = .increment, .write = actIncrement },
    .{ .name = "conflict", .tag = .conflict, .write = actConflict },
    .{ .name = "delete_map", .tag = .delete_map, .write = actDeleteMap },
    .{ .name = "delete_seq", .tag = .delete_seq, .write = actDeleteSeq },
    .{ .name = "mark", .tag = .mark, .write = actMark },
};

test "every patch action applies, and each one changes the mirror" {
    const gpa = testing.allocator;
    comptime {
        if (@typeInfo(PatchAction).@"union".fields.len != 9) {
            @compileError("patches.PatchAction is not the nine variants of patch.rs:33-89");
        }
        if (actions.len != 9) @compileError("one action is missing from the table");
    }

    // **Ten renderings: the skeleton and the nine.** Distinctness across all ten
    // is the property — it says each of the nine *changed* the mirror, and that
    // no two of them changed it the same way. A case two actions satisfy is not
    // a test of either.
    const n = actions.len + 1;
    var lines: [n][]u8 = undefined;

    {
        var seed = try seeded(gpa);
        defer seed.deinit();
        lines[0] = try renderTop(gpa, &seed.value);
    }
    for (actions, 0..) |a, i| {
        // **The log is gone before the mirror is read**: the stream must own
        // everything it hands a consumer.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            a.write(&log);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        try testing.expectEqual(@as(usize, 1), ps.len());

        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, a.name);
        lines[i + 1] = try renderTop(gpa, &seed.value);
    }
    defer for (lines) |l| gpa.free(l);

    for (lines, 0..) |x, i| {
        const what = if (i == 0) "the skeleton" else actions[i - 1].name;
        for (lines[i + 1 ..], 0..) |y, j| {
            if (std.mem.eql(u8, x, y)) {
                std.debug.print(
                    "{s} and {s} leave the same mirror:\n  {s}\n",
                    .{ what, if (i + 1 + j == 0) "the skeleton" else actions[i + j].name, x },
                );
                return error.TestUnexpectedResult;
            }
        }
    }

    // And every variant was in fact exercised: a tag the table does not name
    // would otherwise be a silently untested arm.
    var covered = [_]bool{false} ** 9;
    for (actions) |a| covered[@intFromEnum(a.tag)] = true;
    for (covered, 0..) |was, i| {
        if (!was) {
            std.debug.print("no action exercises the {s} variant\n", .{@tagName(@as(std.meta.Tag(PatchAction), @enumFromInt(i)))});
            return error.TestUnexpectedResult;
        }
    }
}

test "a mark applies to a list's elements, and the run is a range of elements" {
    const gpa = testing.allocator;

    // **Two runs of one name, over two elements.** The claim is threefold and
    // each third is separate: a run is a half-open range of the object's own
    // positions ([`PatchAction.mark`](patches.zig), upstream `patch.rs`:88`),
    // a list's positions are **elements** (`hydrate::List` is indexed by
    // element, `hydrate/list.rs`:10`), and a mark whose value is null is the
    // unmark tombstone ([`src/marks.zig`](marks.zig), over `marks.rs`:170-171`)
    // — the same shape as a live mark, told apart by the value.
    {
        var seed = try seeded(gpa);
        defer seed.deinit();
        const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};
        // A `PatchAction.mark` carries a **mutable** slice of marks, so the
        // file-scope array is copied into a local first: the patch holds the
        // copy, not the `const`.
        var runs = mark_then_unmark;
        var ps = try onePatch(gpa, sk_list, &path, .{ .mark = .{ .marks = runs[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "a mark and an unmark");
        const l = &seed.value.object.map.get("list").?.object.list;
        try testing.expectEqual(@as(usize, 2), l.count());
        {
            // The run `[0, 1)` is the live mark, and it lands on the **first
            // element**.
            const first = l.items.get(0).?;
            try testing.expectEqual(@as(usize, 1), first.marks.len());
            try testing.expectEqualStrings("bold", first.marks.entries.items[0].name);
            try testing.expectEqual(@as(bool, true), first.marks.entries.items[0].value.bool_value);
            var live = try withoutUnmarks(gpa, &first.marks);
            defer live.deinit();
            try testing.expectEqual(@as(usize, 1), live.len());
        }
        {
            // The run `[1, 2)` is the unmark, and it lands on the **second**.
            const second = l.items.get(1).?;
            try testing.expectEqual(@as(usize, 1), second.marks.len());
            try testing.expectEqualStrings("bold", second.marks.entries.items[0].name);
            try testing.expect(second.marks.entries.items[0].value == .null_value);
            var live = try withoutUnmarks(gpa, &second.marks);
            defer live.deinit();
            try testing.expectEqual(@as(usize, 0), live.len());
        }
        // A mark is out of band: the values are untouched.
        try testing.expectEqualStrings("a", l.get(0).?.asStr());
        try testing.expectEqual(@as(i64, 2), l.get(1).?.asI64());
    }
    {
        // A run past the end of the sequence stops at the end rather than
        // refusing: a mark is out of band and cannot address an element that
        // does not exist.
        var seed = try seeded(gpa);
        defer seed.deinit();
        const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};
        var wide = [_]Mark{Mark.init("bold", .{ .bool_value = true }, 1, 99)};
        var ps = try onePatch(gpa, sk_list, &path, .{ .mark = .{ .marks = wide[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "a run past the end");
        const l = &seed.value.object.map.get("list").?.object.list;
        try testing.expectEqual(@as(usize, 0), l.items.get(0).?.marks.len());
        try testing.expectEqual(@as(usize, 1), l.items.get(1).?.marks.len());
    }
}

test "a mark applies to text, and an unmark tombstones it" {
    const gpa = testing.allocator;

    // **Arm one: a mark arrives through a real patch stream.** Two names, so
    // the two runs cannot interfere and the assertion is about the plumbing:
    // a live mark is a value, an unmark is that name at null, and the two are
    // told apart by the value and not by the name.
    {
        var seed = try seeded(gpa);
        defer seed.deinit();
        const t = &seed.value.object.map.get("text").?.object.text;
        try testing.expectEqual(@as(usize, 0), t.marks.len());

        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            var live = MarkSet.fromPairs(gpa, &.{
                .{ .name = "bold", .value = .{ .bool_value = true } },
                .{ .name = "italic", .value = ival(4) },
            }) catch return error.TestUnexpectedResult;
            defer live.deinit();
            var unmark = MarkSet.fromPairs(gpa, &.{
                .{ .name = "link", .value = .null_value },
            }) catch return error.TestUnexpectedResult;
            defer unmark.deinit();
            log.mark(sk_text, 0, 1, &live);
            log.mark(sk_text, 1, 1, &unmark);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "text marks");

        try testing.expectEqualStrings("ab", t.asStr());
        try testing.expectEqual(@as(usize, 3), t.marks.len());
        {
            // Name order, so the entries are the ones below whatever order the
            // runs were logged in ([`MarkSet`](marks.zig) keeps a name-sorted
            // array).
            try testing.expectEqualStrings("bold", t.marks.entries.items[0].name);
            try testing.expectEqual(@as(bool, true), t.marks.entries.items[0].value.bool_value);
            try testing.expectEqualStrings("italic", t.marks.entries.items[1].name);
            try testing.expectEqual(@as(i64, 4), t.marks.entries.items[1].value.int);
            // **A null-valued mark is the tombstone.** It is a distinct thing
            // from the live mark next to it: the same shape, a different value,
            // and it is the one that is dropped.
            try testing.expectEqualStrings("link", t.marks.entries.items[2].name);
            try testing.expect(t.marks.entries.items[2].value == .null_value);
        }
        {
            // Dropping the tombstones leaves the live marks and only those
            // ([`MarkSet::withoutUnmarks`](marks.zig), upstream `marks.rs`:180-187`).
            var live = try withoutUnmarks(gpa, &t.marks);
            defer live.deinit();
            try testing.expectEqual(@as(usize, 2), live.len());
            try testing.expectEqualStrings("bold", live.entries.items[0].name);
            try testing.expectEqualStrings("italic", live.entries.items[1].name);
        }
    }

    // **Arm two: a mark and an unmark of the same name, in both orders.** This
    // is the unmark "removing" a mark, and the order is explicit here rather
    // than left to whatever order a patch stream happened to list the runs in.
    {
        const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "text" } }};
        var seed = try seeded(gpa);
        defer seed.deinit();
        // A `PatchAction.mark` carries a **mutable** slice of marks, so the
        // file-scope array is copied into a local first: the patch holds the
        // copy, not the `const`.
        var runs = mark_then_unmark;
        var ps = try onePatch(gpa, sk_text, &path, .{ .mark = .{ .marks = runs[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "a mark then an unmark");
        const t = &seed.value.object.map.get("text").?.object.text;
        try testing.expectEqualStrings("ab", t.asStr());
        try testing.expectEqual(@as(usize, 1), t.marks.len());
        try testing.expectEqualStrings("bold", t.marks.entries.items[0].name);
        try testing.expect(t.marks.entries.items[0].value == .null_value);
        {
            var live = try withoutUnmarks(gpa, &t.marks);
            defer live.deinit();
            // **The unmark removed the mark**: the name is held at null, and
            // dropping the tombstones leaves nothing.
            try testing.expectEqual(@as(usize, 0), live.len());
        }
    }
    {
        const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "text" } }};
        var seed = try seeded(gpa);
        defer seed.deinit();
        // A `PatchAction.mark` carries a **mutable** slice of marks, so the
        // file-scope array is copied into a local first: the patch holds the
        // copy, not the `const`.
        var runs = unmark_then_mark;
        var ps = try onePatch(gpa, sk_text, &path, .{ .mark = .{ .marks = runs[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "an unmark then a mark");
        const t = &seed.value.object.map.get("text").?.object.text;
        try testing.expectEqual(@as(usize, 1), t.marks.len());
        try testing.expectEqual(@as(bool, true), t.marks.entries.items[0].value.bool_value);
        var live = try withoutUnmarks(gpa, &t.marks);
        defer live.deinit();
        try testing.expectEqual(@as(usize, 1), live.len());
    }
}

// ── 3. The refusals ─────────────────────────────────────────────────────────

/// One hand-made patch, with a path the log never had to resolve. Everything
/// the patch names is a string literal, so the batch owns only the path slice.
fn onePatch(
    gpa: Allocator,
    obj: ExId,
    path: []const PathElem,
    action: PatchAction,
) !patches.Patches {
    var ps: patches.Patches = .init(gpa);
    errdefer ps.deinit();
    const a = ps.allocator();
    try ps.items.append(a, .{
        .obj = obj,
        .path = try a.dupe(PathElem, path),
        .action = action,
    });
    return ps;
}

test "a patch naming an unknown object is refused, and the refusal names the path" {
    const gpa = testing.allocator;

    // **Arm one: a step names an object the mirror holds under a different id.**
    // The path resolves as far as the first step, and the second step says the
    // mirror should be inside an object it is not.
    {
        const path = [_]PathElem{
            .{ .obj = .root, .prop = .{ .key = "nested" } },
            .{ .obj = other_obj, .prop = .{ .key = "c" } },
        };
        var ps = try onePatch(gpa, other_obj, &path, .{
            .increment = .{ .prop = .{ .key = "c" }, .value = 1 },
        });
        defer ps.deinit();

        var seed = try seeded(gpa);
        defer seed.deinit();
        const before = try renderTop(gpa, &seed.value);
        defer gpa.free(before);

        const f = try expectRefusal(&seed.value, &ps, "a step naming another object");
        const u = switch (f) {
            .unknown_object => |u| u,
            else => {
                std.debug.print("expected unknown_object, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        };
        try testing.expect(u.at == 1);
        try testing.expect(u.want.eql(other_obj));
        // The mirror *does* hold an object there; it is simply not this one.
        try testing.expect(u.got.?.eql(sk_nested));
        // **The refusal names the path**: the same two steps, element for
        // element. `expectEqual` on the slices would compare their pointers, so
        // this compares the contents.
        try testing.expectEqual(@as(usize, 2), u.path.len);
        try testing.expect(u.path[0].obj.eql(.root));
        try testing.expectEqualStrings("nested", propKey(u.path[0].prop));
        try testing.expect(u.path[1].obj.eql(other_obj));
        try testing.expectEqualStrings("c", propKey(u.path[1].prop));

        const after = try renderTop(gpa, &seed.value);
        defer gpa.free(after);
        try testing.expectEqualStrings(before, after);
    }

    // **Arm two: the path resolves, and the patch's own object is not the one it
    // ended in.** This is the check upstream cannot make — it throws the
    // `obj` away (`hydrate.rs`:84) — and it is what stops a patch for `7@0` from
    // being applied to `2@0` just because the properties happen to line up.
    {
        const path = [_]PathElem{
            .{ .obj = .root, .prop = .{ .key = "nested" } },
        };
        var ps = try onePatch(gpa, other_obj, &path, .{
            .increment = .{ .prop = .{ .key = "c" }, .value = 1 },
        });
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, "a patch whose object is not the path's end");
        const u = switch (f) {
            .unknown_object => |u| u,
            else => {
                std.debug.print("expected unknown_object, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        };
        // The check is past the last step, so `at` is the path length.
        try testing.expect(u.at == u.path.len);
        try testing.expect(u.path.len == 1);
        try testing.expect(u.want.eql(other_obj));
        try testing.expect(u.got.?.eql(sk_nested));
    }
}

test "a path that does not resolve is an error, not a nearest match" {
    const gpa = testing.allocator;
    // `obj["missing"]["deeper"]`: the first step names a key the map does not
    // have. **The nearest match would be to apply the action to the map itself**,
    // so the mirror being unchanged is half of this test.
    // The path is root-first and **every step names the object it leaves**
    // ([`PatchBuilder.getPath`](patches.zig), upstream `patch_builder.rs`:143-165`),
    // so the first step leaves the root.
    const path = [_]PathElem{
        .{ .obj = .root, .prop = .{ .key = "nested" } },
        .{ .obj = sk_nested, .prop = .{ .key = "missing" } },
        .{ .obj = other_obj, .prop = .{ .index = 0 } },
    };
    var ps = try onePatch(gpa, other_obj, &path, .{
        .put_seq = .{ .index = 0, .value = .{ .scalar = ival(1) }, .obj = ex(80, 0), .conflict = false },
    });
    defer ps.deinit();

    var seed = try seeded(gpa);
    defer seed.deinit();
    const before = try renderTop(gpa, &seed.value);
    defer gpa.free(before);

    const f = try expectRefusal(&seed.value, &ps, "a path that does not resolve");
    const p = switch (f) {
        .invalid_prop => |p| p,
        else => {
            std.debug.print("expected invalid_prop, got {s}\n", .{@tagName(f)});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expect(p.at == 1);
    try testing.expectEqual(@as(usize, 3), p.path.len);
    try testing.expectEqualStrings("missing", propKey(p.path[1].prop));

    const after = try renderTop(gpa, &seed.value);
    defer gpa.free(after);
    try testing.expectEqualStrings(before, after);

    // The other shape: an index past the end of a list. Same refusal, same
    // no-nearest-match property.
    var lseed = try seeded(gpa);
    defer lseed.deinit();
    const lpath = [_]PathElem{
        .{ .obj = .root, .prop = .{ .key = "list" } },
        .{ .obj = sk_list, .prop = .{ .index = 9 } },
    };
    var lps = try onePatch(gpa, sk_list, &lpath, .{
        .put_seq = .{ .index = 0, .value = .{ .scalar = ival(1) }, .obj = ex(81, 0), .conflict = false },
    });
    defer lps.deinit();
    const lf = try expectRefusal(&lseed.value, &lps, "an index past the end of a list");
    const lp = switch (lf) {
        .invalid_prop => |bad| bad,
        else => {
            std.debug.print("expected invalid_prop, got {s}\n", .{@tagName(lf)});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expect(lp.at == 1);
}

test "an action the object cannot take is refused, naming the action" {
    const gpa = testing.allocator;
    var spliced = try patches.ConcreteTextValue.init(gpa, "x", doc_enc);
    defer spliced.deinit();
    const to_list = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};
    const to_text = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "text" } }};
    const no_path = [_]PathElem{};
    const cases = [_]struct {
        what: []const u8,
        obj: ExId,
        path: []const PathElem,
        action: PatchAction,
    }{
        .{
            .what = "a splice on a map",
            .obj = .root,
            .path = &no_path,
            .action = .{
                .splice_text = .{
                    .index = 0,
                    // **Owned here and freed after the loop**: a `splice_text`
                    // action carries its text by value, and this one is a copy, so
                    // only this binding owns the buffer.
                    .value = spliced,
                    .marks = null,
                },
            },
        },
        .{
            .what = "a put_map on a list",
            .obj = sk_list,
            .path = &to_list,
            .action = .{ .put_map = .{
                .key = "k",
                .value = .{ .scalar = ival(1) },
                .obj = ex(90, 0),
                .conflict = false,
            } },
        },
        .{
            // A `put_seq` is **not** one a text cannot take — it is
            // `Text::apply`'s third arm ([`hydrate/text.rs`](hydrate/text.rs):45-50`),
            // and it replaces one element. What a text has no arm for is a
            // `put_map` ([`hydrate/text.rs`](hydrate/text.rs):60`).
            .what = "a put_map on a text",
            .obj = sk_text,
            .path = &to_text,
            .action = .{ .put_map = .{
                .key = "k",
                .value = .{ .scalar = ival(1) },
                .obj = ex(91, 0),
                .conflict = false,
            } },
        },
    };
    for (cases) |c| {
        var ps = try onePatch(gpa, c.obj, c.path, c.action);
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, c.what);
        switch (f) {
            .invalid_map_op, .invalid_list_op, .invalid_text_op => {},
            else => {
                std.debug.print("{s}: got {s}\n", .{ c.what, @tagName(f) });
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "an increment of a non-counter and a delete past the end are refused" {
    const gpa = testing.allocator;
    {
        // The skeleton holds `"a" = "a string"` at the root, so incrementing it
        // is the `BadIncrement` arm ([`MapValue::increment`](hydrate/map.rs):85-92`).
        var ps = try onePatch(gpa, .root, &.{}, .{
            .increment = .{ .prop = .{ .key = "list" }, .value = 1 },
        });
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, "an increment of a list");
        switch (f) {
            .bad_increment => {},
            else => {
                std.debug.print("expected bad_increment, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
    }
    {
        const to_list = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};
        var ps = try onePatch(gpa, sk_list, &to_list, .{ .delete_seq = .{ .index = 9, .length = 1 } });
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, "a delete past the end of a list");
        switch (f) {
            .invalid_index => |i| try testing.expectEqual(@as(usize, 9), i),
            else => {
                std.debug.print("expected invalid_index, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
    }
    {
        var ps = try onePatch(gpa, .root, &.{}, .{
            .increment = .{ .prop = .{ .key = "nowhere" }, .value = 1 },
        });
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, "an increment of a key that is not there");
        switch (f) {
            .invalid_key => |k| try testing.expectEqualStrings("nowhere", k),
            else => {
                std.debug.print("expected invalid_key, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "a delete_seq that runs out of elements refuses with the ones it removed already gone" {
    const gpa = testing.allocator;
    const to_list = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};

    // **Five elements asked of a list of two.** The arm removes at `a.index`
    // once per iteration, so it takes both and only then misses — and the two
    // it took are gone. Counting them is the whole claim: a mirror that
    // reported the refusal with its two elements still there would contradict
    // the residue `Applied.refused` and `List.apply` promise, and a mirror
    // that reported `.ok` would be upstream's silent under-delete instead.
    var ps = try onePatch(gpa, sk_list, &to_list, .{ .delete_seq = .{ .index = 0, .length = 5 } });
    defer ps.deinit();
    var seed = try seeded(gpa);
    defer seed.deinit();

    // The list is read through its own accessor, and the pointer is taken
    // before the removal because the register holding it is not the one that
    // moved.
    const l = &seed.value.object.map.get("list").?.object.list;
    try testing.expectEqual(@as(usize, 2), l.count());

    const f = try expectRefusal(&seed.value, &ps, "a delete of five over a list of two");
    switch (f) {
        .invalid_index => |i| try testing.expectEqual(@as(usize, 0), i),
        else => {
            std.debug.print("expected invalid_index, got {s}\n", .{@tagName(f)});
            return error.TestUnexpectedResult;
        },
    }

    // **Both elements are gone and the rest of the mirror is untouched**, so
    // the residue is exactly the two removals and not a broken tree.
    try testing.expectEqual(@as(usize, 0), l.count());
    try testing.expectEqual(@as(usize, 3), seed.value.object.map.count());
    try testing.expect(l.get(0) == null);
}

// ── 4. The expose queue, both arms ──────────────────────────────────────────

const ex_list: ExId = .{ .id = opId(1, 0) };

const ex_root_items = [_]patches.MapItem{
    .{ .key = "list", .value = .{ .object = .list }, .id = opId(1, 0), .conflict = false },
};

const ex_list_items = [_]patches.ListItem{
    .{ .index = 0, .value = .{ .scalar = ival(1) }, .id = opId(10, 0), .conflict = false },
    .{ .index = 1, .value = .{ .scalar = sval("two") }, .id = opId(11, 0), .conflict = false },
    .{ .index = 2, .value = .{ .scalar = .{ .bool_value = true } }, .id = opId(12, 0), .conflict = false },
};

const ex_objs = [_]TestDoc.Obj{
    .{ .id = .root, .typ = .map, .map_items = &ex_root_items },
    .{ .id = ex_list, .typ = .list, .parent = .root, .list_items = &ex_list_items },
};

const ex_doc: TestDoc = .{ .objs = &ex_objs };

test "a patch about an object the log never saw created is refused" {
    const gpa = testing.allocator;
    // A diff of a document that already had the list writes patches **about**
    // the list and nothing that introduces it: the log saw no make.
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        log.insert(ex_list, 1, .{ .scalar = sval("two") }, opId(11, 0), false);
        break :blk log.makePatches(TestDoc, &ex_doc);
    };
    defer ps.deinit();
    try testing.expectEqual(@as(usize, 1), ps.len());

    var mirror = Value.map(gpa);
    defer mirror.deinit();
    const f = try expectRefusal(&mirror, &ps, "a patch about an object the mirror lacks");
    // The property does not resolve, and the refusal says which step of which
    // path — which is the shape a missing object takes when the mirror has
    // nothing at the property at all.
    const p = switch (f) {
        .invalid_prop => |p| p,
        else => {
            std.debug.print("expected invalid_prop, got {s}\n", .{@tagName(f)});
            return error.TestUnexpectedResult;
        },
    };
    try testing.expect(p.at == 0);
    try testing.expectEqual(@as(usize, 1), p.path.len);
    try testing.expectEqualStrings("list", propKey(p.path[0].prop));
    try testing.expect(p.path[0].obj.eql(.root));
}

test "with the expose queue in play the same content applies" {
    const gpa = testing.allocator;
    // **The same content, and the only difference is the `put_map` with
    // `expose` set** — which is the third of the log's `queueExpose` rules
    // ([`PatchLog.putMap`](patches.zig), upstream `patch_log.rs`:374-375`) and
    // the whole of the [`ExposeQueue`](patches.zig).
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        log.putMap(.root, "list", .{ .object = .list }, opId(1, 0), false, true);
        log.insert(ex_list, 1, .{ .scalar = sval("two") }, opId(11, 0), false);
        break :blk log.makePatches(TestDoc, &ex_doc);
    };
    defer ps.deinit();
    try testing.expect(ps.len() >= 2);

    var mirror = Value.map(gpa);
    defer mirror.deinit();
    try applyAll(gpa, &mirror, &ps, "the exposed stream");

    // The mirror holds the list, with the content the queue supplied: the
    // `putMap` skipped the log's own insert (the queue was about to supply the
    // whole object) and the expose patches supplied all three elements.
    const lv = mirror.object.map.get("list") orelse return error.TestUnexpectedResult;
    const l = &lv.object.list;
    try testing.expectEqual(@as(usize, 3), l.count());
    try testing.expectEqual(@as(i64, 1), l.get(0).?.asI64());
    try testing.expectEqualStrings("two", l.get(1).?.asStr());
    try testing.expectEqual(@as(bool, true), l.get(2).?.bool_value);

    // **The list's own id is the one the put introduced**, which is what the
    // next patch's path is checked against.
    try testing.expectEqual(ex_list, lv.objId().?);
}

// ── 5. Deletes ──────────────────────────────────────────────────────────────

test "a delete removes the key or the element, and later indices shift down" {
    const gpa = testing.allocator;
    {
        // A key that is there goes, and the rest of the map is untouched.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.deleteMap(.root, "nested");
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, "a delete_map");
        const m = &seed.value.object.map;
        try testing.expectEqual(@as(usize, 2), m.count());
        try testing.expect(m.get("nested") == null);
        try testing.expect(m.get("list") != null);
        try testing.expect(m.get("text") != null);
    }
    {
        // A key that is not there is not an error: upstream discards the
        // `Option` ([`Map::apply`](hydrate/map.rs):31`) and so does this.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.deleteMap(.root, "never-there");
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, "a delete_map of a key that is not there");
        try testing.expectEqual(@as(usize, 3), seed.value.object.map.count());
    }
    {
        // The front element goes and **the second shifts down into index 0**.
        // `insert` is put on top of the same skeleton, so the two answers are
        // not a copy of one another.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.deleteSeq(sk_list, 0, 1);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, "a delete_seq");
        const l = &seed.value.object.map.get("list").?.object.list;
        try testing.expectEqual(@as(usize, 1), l.count());
        try testing.expectEqual(@as(i64, 2), l.get(0).?.asI64());
    }
    {
        // Two at once, and the element after them shifts down twice. The list
        // is `["a", 2]`, `3` goes in at index 1, and the first two go: what is
        // left is the `2`, which is what "the indices shift down" means.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.insert(sk_list, 1, .{ .scalar = ival(3) }, opId(52, 0), false);
            log.deleteSeq(sk_list, 0, 2);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, "a delete_seq of two");
        const l = &seed.value.object.map.get("list").?.object.list;
        try testing.expectEqual(@as(usize, 1), l.count());
        try testing.expectEqual(@as(i64, 2), l.get(0).?.asI64());
    }
    {
        // A delete in a text removes the characters, and the text after them
        // moves down.
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.deleteSeq(sk_text, 0, 1);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        try applyAll(gpa, &seed.value, &ps, "a delete_seq on a text");
        const t = &seed.value.object.map.get("text").?.object.text;
        try testing.expectEqualStrings("b", t.asStr());
        try testing.expectEqual(@as(usize, 1), t.count());
    }
}

// ── 6. The empty mirror ─────────────────────────────────────────────────────

test "an empty stream builds an empty mirror, and empty map, list and text stay distinct" {
    const gpa = testing.allocator;
    var stream: patches.Patches = .init(gpa);
    defer stream.deinit();
    try testing.expectEqual(@as(usize, 0), stream.len());

    var mirror = Value.map(gpa);
    defer mirror.deinit();
    try applyAll(gpa, &mirror, &stream, "an empty stream");
    try testing.expectEqual(@as(usize, 0), mirror.object.map.count());
    try testing.expect(mirror.isObject());
    try testing.expect(!mirror.isScalar());
    try testing.expect(mirror.objId().?.eql(.root));

    // **Three empty objects, and no two of them are the same value.** Upstream's
    // `Value::new` builds a different one for each of `ObjType::Map`, `List` and
    // `Text` (`hydrate.rs`:32-34`), and a patch that put an object where an
    // object was must not be able to change a map into a list.
    var m = Value.map(gpa);
    defer m.deinit();
    var l = Value.list(gpa);
    defer l.deinit();
    var t = try Value.text(gpa, doc_enc, "");
    defer t.deinit();
    try testing.expect(!m.eql(&l));
    try testing.expect(!l.eql(&t));
    try testing.expect(!m.eql(&t));
    try testing.expect(m.eql(&Value.map(gpa)));
    try testing.expectEqualStrings("", t.object.text.asStr());
    try testing.expectEqual(@as(usize, 0), m.object.map.count());
    try testing.expectEqual(@as(usize, 0), l.object.list.count());
    try testing.expectEqual(@as(usize, 0), t.object.text.marks.len());
}

// ── 7. Every value variant ──────────────────────────────────────────────────

test "every value variant round-trips through the mirror" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, v: ScalarValue }{
        .{ .name = "null", .v = .null_value },
        .{ .name = "bool", .v = .{ .bool_value = true } },
        .{ .name = "int", .v = .{ .int = -9 } },
        .{ .name = "uint", .v = .{ .uint = 9 } },
        .{ .name = "float", .v = .{ .float = 0.5 } },
        .{ .name = "str", .v = .{ .str = "hi" } },
        .{ .name = "bytes", .v = .{ .bytes = "\x00\xff" } },
        .{ .name = "counter", .v = .{ .counter = .init(3) } },
        .{ .name = "timestamp", .v = .{ .timestamp = 1234 } },
        .{ .name = "actor_id", .v = .{ .actor_id = rt_actor } },
        .{ .name = "unknown", .v = .{ .unknown = .{ .type_code = 42, .bytes = "\x07" } } },
    };
    // **One case per [`ScalarValue`] variant, so a new one fails the build.**
    comptime {
        if (@typeInfo(ScalarValue).@"union".fields.len != cases.len) {
            @compileError("ScalarValue is not the eleven variants of src/value.zig:88-101");
        }
    }

    for (cases) |c| {
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.putMap(.root, "k", .{ .scalar = c.v }, opId(70, 0), false, false);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();

        var mirror = Value.map(gpa);
        defer mirror.deinit();
        try applyAll(gpa, &mirror, &ps, c.name);

        const got = mirror.object.map.get("k") orelse {
            std.debug.print("{s}: the mirror has no key\n", .{c.name});
            return error.TestUnexpectedResult;
        };
        if (!got.eql(&Value.fromScalar(c.v))) {
            const line = try renderTop(gpa, &mirror);
            defer gpa.free(line);
            std.debug.print("{s}: {s}\n", .{ c.name, line });
            return error.TestUnexpectedResult;
        }
        // **And back out again**, which is the other half of a round trip: the
        // flat union is lossless against the `ScalarValue` it came from.
        const back = got.toScalar() orelse {
            std.debug.print("{s}: not a scalar\n", .{c.name});
            return error.TestUnexpectedResult;
        };
        if (!back.eql(c.v)) {
            std.debug.print("{s}: came back as {any}\n", .{ c.name, back });
            return error.TestUnexpectedResult;
        }
    }

    // The object case, twice over: a patch that puts an object, and a patch that
    // then reaches inside it. The second is only applicable because the first
    // recorded the object's id.
    {
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            // **The child is an object [`sk_doc`] knows**, because the log
            // resolves a path by asking the document for the child's parent and
            // for the parent's registers ([`PatchBuilder.getPath`](patches.zig)).
            // An object the document cannot place produces no patch at all —
            // silently — which is the other half of why [`Value.applyOne`]
            // checks what it is holding.
            log.putMap(.root, "nested", .{ .object = .map }, opId(2, 0), false, false);
            log.putMap(sk_nested, "in", .{ .scalar = ival(5) }, opId(72, 0), false, false);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var mirror = Value.map(gpa);
        defer mirror.deinit();
        try applyAll(gpa, &mirror, &ps, "a nested object");
        const inner = mirror.object.map.get("nested") orelse return error.TestUnexpectedResult;
        try testing.expect(inner.isObject());
        try testing.expect(inner.objId().?.eql(sk_nested));
        try testing.expectEqual(@as(i64, 5), inner.object.map.get("in").?.asI64());
    }

    // `width` and `asStr` over the eleven, because they are the two questions a
    // text asks a value ([`hydrate::Value::width`](hydrate.rs):60-65`,
    // [`as_str`](hydrate.rs):71-76`).
    try testing.expectEqualStrings("hi", Value.fromScalar(.{ .str = "hi" }).asStr());
    try testing.expectEqual(@as(usize, 1), Value.fromScalar(.{ .int = 1 }).width(.list, doc_enc));
    try testing.expectEqual(@as(usize, 2), Value.fromScalar(.{ .str = "hi" }).width(.text, doc_enc));
    // **A non-string value is the replacement character, and a list position is
    // one wide** — the two rules [`Value.asStr`] and [`Value.width`] state
    // ([`hydrate.rs`](hydrate.rs):71-76`, `:60-65`).
    try testing.expectEqualStrings(object_replacement, Value.fromScalar(.{ .int = 1 }).asStr());
    // **Three bytes, one position**: `width` counts units of the encoding, and
    // the document's is a code point, not a byte
    // ([`TextEncoding.width`](types.zig)).
    try testing.expectEqual(@as(usize, 1), Value.fromScalar(.{ .int = 1 }).width(.text, doc_enc));
    try testing.expectEqual(@as(i64, -9), Value.fromScalar(.{ .int = -9 }).asI64());
    try testing.expectEqual(@as(i64, 3), Value.fromScalar(.{ .counter = .init(3) }).asI64());
    // **The two integer-shaped cases `as_i64_or_default` names and this file's
    // list above does not reach** ([`hydrate::Value::as_i64`](hydrate.rs):129-134`,
    // over [`ScalarValue::as_i64_or_default`](opset/types.zig)): a `uint` that
    // fits, and a timestamp, which is an `i64` with a name.
    try testing.expectEqual(@as(i64, 9), Value.fromScalar(.{ .uint = 9 }).asI64());
    try testing.expectEqual(@as(i64, 1234), Value.fromScalar(.{ .timestamp = 1234 }).asI64());
    // **A `uint` too large for an `i64` is zero, not a trap** — the same
    // `orelse 0` the `cast` falls back to, and the reason the port spells the
    // arm as a cast rather than an `@intCast`.
    try testing.expectEqual(@as(i64, 0), Value.fromScalar(.{ .uint = std.math.maxInt(u64) }).asI64());
    try testing.expectEqual(@as(i64, 0), Value.fromScalar(.{ .str = "hi" }).asI64());
    // An object reads as zero, whatever it is: the object case has no integer
    // ([`hydrate::Value::as_i64`](hydrate.rs):129-134`).
    var empty_root = Value.map(gpa);
    defer empty_root.deinit();
    try testing.expectEqual(@as(i64, 0), empty_root.asI64());
    // **And an object is not a scalar at all**, which is the other half of the
    // round trip: [`Value.toScalar`] is the door back to the read API and it
    // returns null for the case that has no [`ScalarValue`] spelling.
    try testing.expect(empty_root.toScalar() == null);
}

// ── 8. Constructing a mirror ────────────────────────────────────────────────

/// An allocator that counts every allocation and free that goes through it, so
/// "constructing a mirror allocates only its own storage" is a measurement and
/// not a claim.
const Counting = struct {
    inner: Allocator,
    allocs: usize = 0,
    frees: usize = 0,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ra);
    }

    fn allocator(self: *Counting) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }
};

test "constructing a mirror allocates only its own storage" {
    var counting: Counting = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    // **A map and a list allocate nothing at all**: an empty
    // `StringHashMapUnmanaged` and an empty `SequenceTree` are both `{ .empty }`
    // headers, and a `MarkSet` is a three-word struct.
    var m = Value.map(gpa);
    var l = Value.list(gpa);
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.frees);

    // **A text allocates exactly one buffer**, for its own bytes, and frees it.
    var t = try Value.text(gpa, doc_enc, "abc");
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    t.deinit();
    try testing.expectEqual(@as(usize, 1), counting.frees);

    l.deinit();
    m.deinit();
    // Nothing leaked and nothing freed twice.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 1), counting.frees);
}

/// One `put_map` of `value` onto an empty root map built with `gpa`.
///
/// The patch is built with `testing.allocator` and never with `gpa`, so
/// `checkAllAllocationFailures` counts only the allocations the **mirror** is
/// responsible for: the copies [`Map.putOwned`] makes and the table slot it
/// takes. Every one of them is on the critical path, so every failure index
/// produces an `error.OutOfMemory` and the walk is deterministic.
///
/// **The value is passed in rather than written here** because the two shapes
/// fail at different places and both matter: a `str` makes [`ownValue`] copy a
/// buffer before the key is duped, and an object makes [`Value.fromPatch`]
/// build a container before the same point. The mirror is read back through
/// its public accessors, so a half-applied put cannot pass by agreeing with
/// itself.
fn putOntoRoot(gpa: Allocator, value: patches.Value, want: []const u8) !void {
    var ps = try onePatch(testing.allocator, .root, &.{}, .{
        .put_map = .{ .key = "k", .value = value, .obj = ex(90, 0), .conflict = false },
    });
    defer ps.deinit();

    var m = Value.map(gpa);
    defer m.deinit();

    switch (try m.applyPatches(doc_enc, ps.slice())) {
        .ok => {},
        .refused => |f| {
            std.debug.print("the put_map was refused: {s}\n", .{@tagName(f)});
            return error.TestUnexpectedResult;
        },
    }
    try testing.expectEqual(@as(usize, 1), m.object.map.count());
    try testing.expectEqualStrings(want, m.object.map.get("k").?.asStr());
}

/// The object shape: a `put_map` whose payload is a **text object**, which is
/// the one patch value [`Value.fromPatch`] builds a container for. An object
/// renders as the replacement character, not as its text — [`Value.asStr`]
/// says which arms do that, and this is the assertion that it still does.
fn putObjectOntoRoot(gpa: Allocator) !void {
    try putOntoRoot(gpa, .{ .object = .text }, "\u{fffc}");
}

/// The scalar shape: a `put_map` whose payload is a **string**, so the copy
/// [`ownValue`] makes is a buffer the mirror really owns.
fn putScalarOntoRoot(gpa: Allocator) !void {
    try putOntoRoot(gpa, .{ .scalar = .{ .str = "payload" } }, "payload");
}

test "a put_map that cannot store its value leaves the mirror exactly as it was" {
    // **The property is the contract, not the allocation.** `Map.putOwned`
    // promises its caller that the register is still the caller's on an
    // error, and `Map.apply` is that caller: it built a value, handed it over,
    // and has to release it when the hand-over fails. `checkAllAllocationFailures`
    // walks every acquisition on that path — the value's own copy, the key copy
    // and the table's first slot — and `testing.allocator` behind it turns a
    // dropped buffer into a failure rather than into a leak nobody sees.
    //
    // **At this revision the value `Value.fromPatch` builds owns no buffer at
    // all**: every container it makes is empty, and `gpa.dupe(u8, "")` does
    // not call the allocator, so the object arm cannot fail before the key copy
    // and the two shapes differ only by that one copy. It is run anyway — the
    // arm is typed fallible and stays so, and a mirror holding a half-stored
    // register is the failure this pins.
    try testing.checkAllAllocationFailures(testing.allocator, putObjectOntoRoot, .{});
    try testing.checkAllAllocationFailures(testing.allocator, putScalarOntoRoot, .{});
}

// ── 9. Hydration from the op set ────────────────────────────────────────────

/// The three objects [`os_first`] makes, which are the ids of the ops that
/// make them.
const os_nested: ExId = .{ .id = opId(1, 0) };
const os_list: ExId = .{ .id = opId(2, 0) };
const os_text: ExId = .{ .id = opId(3, 0) };

const os_first = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("m"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 3, .key = .fromStr("t"), .act = .make_text },
    .{ .ctr = 4, .key = .fromStr("k"), .val = sval("v") },
    .{ .ctr = 5, .obj = os_nested, .key = .fromStr("deep"), .val = ival(1) },
    .{ .ctr = 6, .obj = os_list, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = ival(10) },
    .{ .ctr = 7, .obj = os_list, .key = .fromElemId(elem(6, 0)), .is_insert = true, .val = sval("ten") },
    .{ .ctr = 8, .obj = os_text, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("hi") },
};

test "hydrateMap reads the op set, and hydrateOp refuses a row that is not a value" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, &.{rt_actor});
    defer f.destroy();
    try f.mergeInto(batchmod.NullLog, undefined, &os_first, &.{
        bareChange(rt_actor, 1, 1, 8, 0x33),
    });

    var root = try hydrateMap(Fixture.Set, &f.set, gpa, .root, null);
    defer root.deinit();
    const m = &root.object.map;
    // Four keys: the three objects the change makes and the scalar it puts.
    try testing.expectEqual(@as(usize, 4), m.count());
    try testing.expectEqualStrings("v", m.get("k").?.asStr());
    // The child objects are hydrated by recursing into their own top ops, and
    // each records the id of the op that made it.
    try testing.expect(m.get("m").?.objId().?.eql(os_nested));
    try testing.expectEqual(@as(i64, 1), m.get("m").?.object.map.get("deep").?.asI64());
    try testing.expectEqual(@as(usize, 2), m.get("list").?.object.list.count());
    try testing.expectEqual(@as(i64, 10), m.get("list").?.object.list.get(0).?.asI64());
    try testing.expectEqualStrings("hi", m.get("t").?.object.text.asStr());

    // `hydrate_op` on each make builds the same subtree it would reach by
    // recursing, which is the claim `hydrate.rs`:294-298` makes.
    var tops = try f.set.topOps(.root, null);
    defer tops.deinit(gpa);
    while (try tops.next()) |top| {
        if (top.action() != .make_map) continue;
        var one = try hydrateOp(Fixture.Set, &f.set, gpa, top, null);
        defer one.deinit();
        try testing.expect(one.eql(m.get("m").?));
        break;
    } else {
        return error.TestUnexpectedResult;
    }

    // **The three arms upstream panics on** (`hydrate.rs`:300`) are refusals
    // here. A delete op is not a stored row (`Op::del` builds one only for the
    // encoder, `opset/op.zig`), and an increment or a mark row can only reach
    // this from a caller who hands one over — which is what these three do.
    const rows = [_]opmod.Op{
        opmod.Op.del(opId(9, 0), .root, .fromStr("k")),
        opmod.Op.init(
            0,
            false,
            opId(10, 0),
            .increment,
            .root,
            .fromStr("k"),
            false,
            ival(1),
            false,
            null,
            opmod.SuccCursors.none(),
        ),
        opmod.Op.init(
            0,
            false,
            opId(11, 0),
            .mark,
            .root,
            .fromStr("k"),
            true,
            ival(1),
            false,
            "bold",
            opmod.SuccCursors.none(),
        ),
    };
    for (rows) |row| {
        try testing.expectError(
            error.InvalidOp,
            hydrateOp(Fixture.Set, &f.set, gpa, row, null),
        );
    }
}

test "a register with two live rows is hydrated with its conflict flag" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, &.{
        ActorId.init("aaaaaaaaaaaaaaaa"),
        ActorId.init("bbbbbbbbbbbbbbbb"),
    });
    defer f.destroy();

    // **Rule two of the merge** (`batch.rs`:814-820, over
    // `transaction/inner.rs`): a lesser change op does not win a register the
    // document already holds and flags it instead. `7@2` is in the base and
    // `3@1` arrives from a concurrent actor, so the register holds two live rows
    // and the winner carries the flag.
    try f.build(0, &[_]Rec{
        .{ .ctr = 7, .actor = 2, .key = .fromStr("a"), .val = sval("a7") },
    });
    var log: patches.PatchLog = .active(gpa);
    defer log.deinit();
    try f.mergeInto(patches.PatchLog, &log, &[_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("a"), .val = sval("a3") },
    }, &.{bareChange(ActorId.init("bbbbbbbbbbbbbbbb"), 1, 3, 3, 0x55)});

    var root = try hydrateMap(Fixture.Set, &f.set, gpa, .root, null);
    defer root.deinit();
    const m = &root.object.map;
    try testing.expectEqual(@as(usize, 1), m.count());
    const got = m.get("a") orelse return error.TestUnexpectedResult;
    // `7@2` beats `3@1`, so it is the value and the flag is on it.
    try testing.expectEqualStrings("a7", got.asStr());
    const mv = m.entries.getPtr("a").?;
    try testing.expect(mv.conflict);

    // **The same register with one live row is not conflicted** — the other half
    // of the rule, and the reason the flag is a property of the document and not
    // of the key.
    const f2 = try Fixture.init(gpa, &.{rt_actor});
    defer f2.destroy();
    try f2.mergeInto(batchmod.NullLog, undefined, &[_]Rec{
        .{ .ctr = 7, .key = .fromStr("a"), .val = sval("a7") },
    }, &.{bareChange(rt_actor, 1, 7, 7, 0x66)});
    var solo = try hydrateMap(Fixture.Set, &f2.set, gpa, .root, null);
    defer solo.deinit();
    try testing.expect(!solo.object.map.entries.getPtr("a").?.conflict);
}

// ── The round trip, from a document ───────────────────────────────────────────
//
// The tests above replay a stream a [`PatchLog`] was fed by hand. What they
// cannot do is answer the question a caller actually has — **does a document's
// own patch stream replay into a mirror equal to that document?** — because the
// stream they build is not a document's stream. These do, through
// [`Document.diff`](doc.zig), which is `Automerge::diff`
// (`automerge.rs`:1419-1426`) over two heads.
//
// **The comparison is per key and per element, and not a length or a hash.**
// A mirror that is non-empty, or a hash that agrees, passes on a tree that is
// entirely wrong. [`expectMirrorMatches`] walks the document's own objects,
// looks up every register by name and every element by index, and compares the
// value at each one.

const rtdoc = @import("doc.zig");
const rttrans = @import("transact.zig");

/// The op set a [`Document`] holds, for [`hydrateMap`] and [`hydrateList`].
const RtSet = opsetmod.OpSet(opmod.ChangeOp);

/// The document both tests start from.
const RtDoc = struct {
    doc: rtdoc.Document,
    /// The text object, which carries a string mark and a boolean mark over
    /// disjoint spans.
    text: ExId,

    fn deinit(self: *RtDoc) void {
        self.doc.deinit();
    }
};

/// A document with everything the round trip has to carry: a map holding a map,
/// a list holding a map and a counter, a counter at the root, a text object with
/// two marks of different types, and a key the second stage deletes.
fn roundTripDoc(gpa: Allocator) !RtDoc {
    var d = try rtdoc.Document.init(gpa, std.testing.io, .auto);
    errdefer d.deinit();
    d.setActorId(.{ .bytes = "0123456789abcdef" });

    const nested = try rttrans.putObject(&d, .root, .{ .key = "nested" }, .map);
    _ = try rttrans.put(&d, nested, .{ .key = "a" }, .{ .str = "A" });
    _ = try rttrans.put(&d, nested, .{ .key = "b" }, .{ .int = 7 });
    _ = try rttrans.put(&d, nested, .{ .key = "c" }, .{ .float = 1.5 });

    const list = try rttrans.putObject(&d, .root, .{ .key = "list" }, .list);
    _ = try rttrans.insert(&d, list, 0, .{ .str = "one" });
    _ = try rttrans.insert(&d, list, 1, .{ .counter = Counter.init(5) });
    const inner = try rttrans.insertObject(&d, list, 2, .map);
    _ = try rttrans.put(&d, inner, .{ .key = "k" }, .{ .bool_value = true });

    _ = try rttrans.put(&d, .root, .{ .key = "n" }, .{ .counter = Counter.init(5) });
    try rttrans.increment(&d, .root, .{ .key = "n" }, 3);

    _ = try rttrans.put(&d, .root, .{ .key = "gone" }, .{ .str = "bye" });

    const text = try rttrans.putObject(&d, .root, .{ .key = "text" }, .text);
    try rttrans.spliceText(&d, text, 0, 0, "hello world");
    // Two marks over disjoint spans and of different value types, so a mirror
    // that keeps one map of name to value for the whole text still has to get
    // both names and both values right.
    try rttrans.mark(&d, text, 0, 5, "link", .after, .{ .str = "https://example.com" });
    try rttrans.mark(&d, text, 6, 11, "bold", .after, .{ .bool_value = true });

    return .{ .doc = d, .text = text };
}

test "hydrate: a whole-state patch stream replays into a mirror equal to the document" {
    const gpa = testing.allocator;
    var rt = try roundTripDoc(gpa);
    defer rt.deinit();

    const heads = try rt.doc.getHeads(gpa);
    defer gpa.free(heads);

    // From nothing to the present: every row is an addition, which is the
    // stream a consumer bootstraps from (`automerge.rs`:1420-1426` with an
    // empty `before`).
    var stream = try rt.doc.diff(gpa, &.{}, heads);
    defer stream.deinit();

    var mirror = Value.map(gpa);
    defer mirror.deinit();
    switch (try mirror.applyPatches(rt.doc.textEncoding(), stream.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &stream, f);
            return error.TestUnexpectedResult;
        },
    }

    try expectMirrorMatches(gpa, &rt.doc, .root, &mirror, "$");
}

test "hydrate: an incremental stream deletes a key and marks a span, and the mirror follows" {
    const gpa = testing.allocator;
    var rt = try roundTripDoc(gpa);
    defer rt.deinit();

    const heads_a = try rt.doc.getHeads(gpa);
    defer gpa.free(heads_a);
    var first = try rt.doc.diff(gpa, &.{}, heads_a);
    defer first.deinit();

    var mirror = Value.map(gpa);
    defer mirror.deinit();
    switch (try mirror.applyPatches(rt.doc.textEncoding(), first.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &first, f);
            return error.TestUnexpectedResult;
        },
    }
    {
        const m = rootMap(&mirror);
        // **The mirror has the key before the delete.** Asserting only its
        // absence afterwards would pass on a stream that never carried it.
        try testing.expect(m.get("gone") != null);
    }

    _ = try rttrans.delete(&rt.doc, .root, .{ .key = "gone" });
    try rttrans.mark(&rt.doc, rt.text, 0, 5, "em", .after, .{ .bool_value = true });

    const heads_b = try rt.doc.getHeads(gpa);
    defer gpa.free(heads_b);
    var second = try rt.doc.diff(gpa, heads_a, heads_b);
    defer second.deinit();

    // **The stream carries the delete, and the mark action carries the runs with
    // their spans.** The two things a length comparison cannot see.
    //
    // **A `mark` action carries every run the text has, not only the one this
    // change wrote**: [`PatchBuilder`] exports the resolved mark set over the
    // range it is emitting (upstream's `Mark { marks }` is that accumulator,
    // `patch_builder.rs`), so the two marks this document already had travel
    // with the new one. The assertion is therefore that the run this change
    // wrote is *among* them with its own span — not that it is the only one.
    var saw_delete = false;
    var em_run: ?Mark = null;
    for (second.slice()) |p| {
        switch (p.action) {
            .delete_map => |a| {
                try testing.expect(p.obj.eql(.root));
                try testing.expectEqualStrings("gone", a.key);
                saw_delete = true;
            },
            .mark => |a| {
                for (a.marks) |m| {
                    if (!std.mem.eql(u8, m.name, "em")) continue;
                    try testing.expect(m.value.eql(.{ .bool_value = true }));
                    try testing.expectEqual(@as(usize, 0), m.start);
                    try testing.expectEqual(@as(usize, 5), m.end);
                    em_run = m;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_delete);
    try testing.expect(em_run != null);

    // **Every run in the stream is a run the document has**, by name, value and
    // span — the span in the stream is the span in the document, read by the
    // other reader: [`Document.marks`](doc.zig) folds the mark operations and
    // the patch stream reports what the log recorded. A stream that invented a
    // run, or shifted one, fails here.
    const runs = try rt.doc.marks(gpa, rt.text);
    defer gpa.free(runs);
    for (second.slice()) |p| {
        if (p.action != .mark) continue;
        for (p.action.mark.marks) |m| {
            var in_document = false;
            for (runs) |d| {
                if (std.mem.eql(u8, d.name, m.name) and d.value.eql(m.value) and
                    d.start == m.start and d.end == m.end) in_document = true;
            }
            if (!in_document) {
                std.debug.print("stream carries {s} over [{d},{d}), the document does not\n", .{
                    m.name, m.start, m.end,
                });
                return error.TestExpectedEqual;
            }
        }
    }

    switch (try mirror.applyPatches(rt.doc.textEncoding(), second.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &second, f);
            return error.TestUnexpectedResult;
        },
    }

    {
        const m = rootMap(&mirror);
        // **Gone, and not null.** `delete_map` removes the key and puts nothing
        // in its place ([`Map::apply`](hydrate/map.rs):30-33`), and a mirror
        // that left a null behind would pass a key-count check.
        try testing.expect(m.get("gone") == null);
        // **And the mark is in the mirror**, by name and by value.
        // The text is a **child** of the root, at the key it was created
        // under — the mirror is addressed the way the document is.
        const text_value = m.get("text") orelse return error.TestUnexpectedResult;
        const t = asText(text_value) orelse return error.TestUnexpectedResult;
        var it = t.marks.iter();
        var in_mirror = false;
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.name, "em")) continue;
            try testing.expect(e.value.eql(.{ .bool_value = true }));
            in_mirror = true;
        }
        try testing.expect(in_mirror);
    }

    // **The whole tree, after the incremental stream.** This is the same
    // per-key, per-element comparison as the whole-state case, so a stream that
    // fixed the deleted key and broke something else cannot pass.
    try expectMirrorMatches(gpa, &rt.doc, .root, &mirror, "$");
}

// ── Across an isolation ──────────────────────────────────────────────────────
//
// The two round trips above build a mirror and then never renumber anything
// underneath it, so they cannot tell an id that carries its actor's bytes from
// one that does not. **This one can.** The isolation's transaction interns a
// concurrency actor whose magic bytes are `0x13 b2 23 09`
// ([`types.rs`:23](../../github-automerge-automerge/rust/automerge/src/types.rs)),
// which sorts before most real actors, so it lands at the **front** of the
// sorted table and shifts every index at or above it
// ([`op_set.rs`:1400-1405](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
// The mirror below is built before that happens and the stream is read after
// it, so the two sides **disagree about the index and agree about the object** —
// which is the only disagreement there is, and it is the one upstream's
// `ExId` carries the actor's bytes for
// ([`exid.rs`:15-18](../../github-automerge-automerge/rust/automerge/src/exid.rs)).

test "hydrate: a patch stream crosses an isolation the mirror was built before" {
    const gpa = testing.allocator;
    var doc = try rtdoc.Document.init(gpa, std.testing.io, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });

    const list = try rttrans.putObject(&doc, .root, .{ .key = "list" }, .list);
    _ = try rttrans.insert(&doc, list, 0, .{ .str = "base" });
    const beginning = try doc.getHeads(gpa);
    defer gpa.free(beginning);
    const first = try rttrans.putObject(&doc, list, .{ .index = 0 }, .text);
    try rttrans.spliceText(&doc, first, 0, 0, "first");

    // **One actor, at index 0.** Every id the mirror is about to record
    // carries this table, so `first` and the list are both `n@0`.
    try testing.expectEqual(@as(usize, 1), doc.numActors());

    // The mirror as a consumer holds it **before** the isolation, built the
    // ordinary way — by replaying the document's own stream — so that the ids
    // in it are the ones a real consumer would be holding.
    var opening = try doc.diffIncremental(gpa);
    defer opening.deinit();
    var mirror = Value.map(gpa);
    defer mirror.deinit();
    switch (try mirror.applyPatches(doc.textEncoding(), opening.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &opening, f);
            return error.TestUnexpectedResult;
        },
    }
    const held = (rootMap(&mirror).get("list") orelse return error.TestUnexpectedResult)
        .objId() orelse return error.TestUnexpectedResult;

    // **The isolation, and with it the renumbering.** `isolate` itself only
    // moves the view; the fork is interned by the **first write inside the
    // isolation**, which is where upstream reaches `isolate_actor`
    // (`automerge.rs`:1259-1281` via `get_or_create_actor_index`). The
    // concurrency actor sorts before `"7f"`, so the table grows to two and
    // `"7f"` is pushed from index 0 to index 1 while every id the mirror
    // already holds still says 0.
    try doc.isolate(gpa, beginning);
    try testing.expectEqual(@as(usize, 1), doc.numActors());

    // A second object at the same index, on the other side of the isolation,
    // so the merge is a conflict and the stream has real work to do.
    const second = try rttrans.putObject(&doc, list, .{ .index = 0 }, .text);
    try rttrans.spliceText(&doc, second, 0, 0, "second");
    try testing.expectEqual(@as(usize, 2), doc.numActors());
    try doc.integrate();

    var later = try doc.diffIncremental(gpa);
    defer later.deinit();
    try testing.expect(later.len() > 0);

    // **The claim this test makes, checked rather than assumed.** The stream
    // names the mirror's list, its id carries the actor's *bytes*, and those
    // bytes are the same on both sides while the *indices* are not. A mirror
    // and a stream that agreed on the index would pass a comparison that never
    // had to look at the actor, and this test would be proving nothing.
    var crossed = false;
    for (later.slice()) |p| {
        for (p.path) |step| {
            if (!sameObject(step.obj, held)) continue;
            crossed = true;
            try testing.expectEqualStrings(
                "7f",
                step.obj.actorBytes().?.bytes,
            );
            try testing.expectEqualStrings(
                "7f",
                held.actorBytes().?.bytes,
            );
            try testing.expect(step.obj.actor().? != held.actor().?);
        }
        if (sameObject(p.obj, held)) crossed = true;
    }
    try testing.expect(crossed);

    // **And the stream applies.** This is the assertion that used to be a
    // refusal: [`Value.applyOne`] walks the path, and the first step leaves the
    // root and the second leaves the list, so both ids are compared — by the
    // actor's bytes, which agree, rather than by the index, which does not.
    switch (try mirror.applyPatches(doc.textEncoding(), later.slice())) {
        .ok => {},
        .refused => |f| {
            try printFailure(gpa, &later, f);
            return error.TestUnexpectedResult;
        },
    }

    // **The whole tree afterwards**, so a stream that applied to the wrong
    // object and then agreed with it cannot pass.
    try expectMirrorMatches(gpa, &doc, .root, &mirror, "$");
}

// ── 11. A mirror owns its bytes ──────────────────────────────────────────────

/// The `id` string the first element of the root's `items` list holds.
fn firstElemId(v: *const Value) ?[]const u8 {
    const items = rootMap(v).get("items") orelse return null;
    const at0 = (asList(items) orelse return null).get(0) orelse return null;
    const id = (asMap(at0) orelse return null).get("id") orelse return null;
    return switch (id.*) {
        .str => |s| s,
        else => null,
    };
}

/// The root's `text` object.
fn rootText(v: *const Value) ?*const Text {
    return asText(rootMap(v).get("text") orelse return null);
}

/// The first name the root text's mark set holds, and the payload it holds
/// there.
fn rootTextMark(v: *const Value) ?MarkSet.Entry {
    const t = rootText(v) orelse return null;
    if (t.marks.len() == 0) return null;
    return t.marks.entries.items[0];
}

test "hydrate: a register and an element own the bytes they were handed" {
    const gpa = testing.allocator;

    // **Overwriting the source is the assertion, and a value comparison could
    // not be.** A mirror that borrowed reads the right bytes right up until
    // the moment it does not, so the only way to say "owned" is to change what
    // the source says and read the mirror again. Each buffer below outlives the
    // mirror, so nothing here is a use-after-free; it is a rewrite of memory
    // the mirror is *supposed* to have copied out of.
    {
        var m = Map.init(gpa, .root);
        defer m.deinit();
        var scratch = "borrowed".*;
        try m.putOwned("k", MapValue.init(.{ .str = &scratch }, false));
        const held = m.get("k").?.asStr();
        @memset(&scratch, '!');
        try testing.expectEqualStrings("borrowed", held);
    }
    {
        var l = List.init(gpa, .root);
        defer l.deinit();
        var scratch = "borrowed".*;
        try l.push(.{ .str = &scratch }, false);
        const held = l.get(0).?.asStr();
        @memset(&scratch, '!');
        try testing.expectEqualStrings("borrowed", held);
    }
}

test "hydrate: two reads of one op set give two mirrors different bytes" {
    const gpa = testing.allocator;
    var doc = try rtdoc.Document.init(gpa, std.testing.io, .auto);
    defer doc.deinit();
    doc.setActorId(.{ .bytes = "7f" });

    const items = try rttrans.putObject(&doc, .root, .{ .key = "items" }, .list);
    const a = try rttrans.insertObject(&doc, items, 0, .map);
    _ = try rttrans.put(&doc, a, .{ .key = "id" }, .{ .str = "a" });
    _ = try rttrans.put(&doc, a, .{ .key = "n" }, .{ .int = 1 });
    const text = try rttrans.putObject(&doc, .root, .{ .key = "text" }, .text);
    try rttrans.spliceText(&doc, text, 0, 0, "hello");
    try rttrans.mark(&doc, text, 0, 5, "link", .after, .{ .str = "https://example.com" });

    const beginning = try doc.getHeads(gpa);
    defer gpa.free(beginning);

    var one = try hydrateMap(RtSet, &doc.ops, gpa, .root, null);
    defer one.deinit();
    var two = try hydrateMap(RtSet, &doc.ops, gpa, .root, null);
    defer two.deinit();

    // **The aliasing claim, which is the whole of it.** Two reads of one op
    // set, taken at the same moment, cannot both point into the op set's
    // columns, and cannot both point at the *same* buffer either: each read
    // made its own. The addresses are what this asserts, because two buffers
    // holding equal bytes is exactly what a borrowing mirror also produces
    // until the crossing happens.
    try testing.expectEqualStrings("a", firstElemId(&one).?);
    try testing.expectEqualStrings("a", firstElemId(&two).?);
    try testing.expect(firstElemId(&one).?.ptr != firstElemId(&two).?.ptr);
    {
        const m1 = rootTextMark(&one).?;
        const m2 = rootTextMark(&two).?;
        try testing.expectEqualStrings("link", m1.name);
        try testing.expectEqualStrings("link", m2.name);
        try testing.expect(m1.name.ptr != m2.name.ptr);
        try testing.expectEqualStrings("https://example.com", m1.value.str);
        try testing.expectEqualStrings("https://example.com", m2.value.str);
        try testing.expect(m1.value.str.ptr != m2.value.str.ptr);
    }

    // **And the crossing itself**, which is the fault this test is here for:
    // the isolation grows the op set's value column while `one` is held. The
    // measured failure was a mirror reading the wrong byte for exactly this,
    // and the mirror is read again afterwards rather than trusted.
    try doc.isolate(gpa, beginning);
    _ = try rttrans.put(&doc, a, .{ .key = "id" }, .{ .str = "changed" });
    try rttrans.spliceText(&doc, text, 5, 0, "!");
    try doc.integrate();

    try testing.expectEqualStrings("a", firstElemId(&one).?);
    try testing.expectEqualStrings("hello", rootText(&one).?.asStr());
    {
        const m1 = rootTextMark(&one).?;
        try testing.expectEqualStrings("link", m1.name);
        try testing.expectEqualStrings("https://example.com", m1.value.str);
    }

    // **And the document really did move**, so the three assertions above are
    // about a mirror that is a snapshot rather than about one that was never
    // in the way of anything.
    var three = try hydrateMap(RtSet, &doc.ops, gpa, .root, null);
    defer three.deinit();
    try testing.expectEqualStrings("changed", firstElemId(&three).?);
    try testing.expectEqualStrings("hello!", rootText(&three).?.asStr());
}

test "hydrate: two applications of one stream give two mirrors different bytes" {
    const gpa = testing.allocator;

    var one = try seeded(gpa);
    defer one.deinit();
    var two = try seeded(gpa);
    defer two.deinit();

    // **The batch arena is immutable while a stream applies**, so the same
    // argument as the op set applies here: a borrowing mirror would hand both
    // applications the same address, and an owning one hands each its own.
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        log.putMap(.root, "s", .{ .scalar = sval("from the stream") }, opId(70, 0), false, false);
        var set = try MarkSet.fromPairs(log.gpa, &.{
            .{ .name = "link", .value = .{ .str = "https://example.com" } },
        });
        defer set.deinit();
        log.mark(sk_list, 0, 1, &set);
        break :blk log.makePatches(TestDoc, &sk_doc);
    };
    defer ps.deinit();

    try applyAll(gpa, &one.value, &ps, "the first application");
    try applyAll(gpa, &two.value, &ps, "the second application");

    const a = rootMap(&one.value).get("s").?.asStr();
    const b = rootMap(&two.value).get("s").?.asStr();
    try testing.expectEqualStrings("from the stream", a);
    try testing.expectEqualStrings("from the stream", b);
    try testing.expect(a.ptr != b.ptr);
    {
        const l1 = asList(rootMap(&one.value).get("list").?).?;
        const l2 = asList(rootMap(&two.value).get("list").?).?;
        const e1 = l1.items.get(0).?.marks.entries.items[0];
        const e2 = l2.items.get(0).?.marks.entries.items[0];
        try testing.expectEqualStrings("link", e1.name);
        try testing.expectEqualStrings("link", e2.name);
        try testing.expect(e1.name.ptr != e2.name.ptr);
        try testing.expectEqualStrings("https://example.com", e1.value.str);
        try testing.expectEqualStrings("https://example.com", e2.value.str);
        try testing.expect(e1.value.str.ptr != e2.value.str.ptr);
    }
}

fn asMap(v: *const Value) ?*const Map {
    return switch (v.*) {
        .object => |*o| switch (o.*) {
            .map => |*m| m,
            else => null,
        },
        else => null,
    };
}

fn asList(v: *const Value) ?*const List {
    return switch (v.*) {
        .object => |*o| switch (o.*) {
            .list => |*l| l,
            else => null,
        },
        else => null,
    };
}

fn asText(v: *const Value) ?*const Text {
    return switch (v.*) {
        .object => |*o| switch (o.*) {
            .text => |*t| t,
            else => null,
        },
        else => null,
    };
}

fn rootMap(v: *const Value) *const Map {
    return asMap(v) orelse unreachable;
}

/// Asserts the mirror holds what `obj` holds, one register and one element at a
/// time.
///
/// **Every register is looked up by name and every element by index**, and a
/// count mismatch is a failure in its own right, so a mirror with a missing
// register and a spare one cannot pass. The recursion follows the *document's*
// objects, taking each child's id from the document side
/// ([`Value.objId`]), so the walk cannot be misled by the mirror.
fn expectMirrorMatches(
    gpa: Allocator,
    doc: *rtdoc.Document,
    obj: ExId,
    got: *const Value,
    path: []const u8,
) !void {
    switch (try doc.objectType(obj)) {
        .map, .table => {
            var src = try hydrateMap(RtSet, &doc.ops, gpa, obj, null);
            defer src.deinit();
            const sm = asMap(&src) orelse return wrongKind(path, "map");
            const gm = asMap(got) orelse return wrongKind(path, "map");
            if (sm.count() != gm.count()) {
                std.debug.print("{s}: mirror has {d} registers, document has {d}\n", .{
                    path, gm.count(), sm.count(),
                });
                return error.TestUnexpectedResult;
            }
            var it = sm.entries.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const mine = gm.get(key) orelse {
                    std.debug.print("{s}.{s}: absent from the mirror\n", .{ path, key });
                    return error.TestUnexpectedResult;
                };
                if (!e.value_ptr.value.eql(mine)) {
                    std.debug.print("{s}.{s}: document {any}, mirror {any}\n", .{
                        path, key, e.value_ptr.value, mine.*,
                    });
                    return error.TestUnexpectedResult;
                }
                // **The child's id comes from the *document's* value, not the
                // mirror's.** The mirror is a snapshot of an earlier view, so
                // its ids carry the actor table that held when it was built —
                // and an isolation renumbers that table. The document side is
                // hydrated from the live op set, so its ids are the ones
                // `hydrateList` and `doc.objectType` can answer for.
                if (e.value_ptr.value.objId()) |child| {
                    const sub = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ path, key });
                    defer gpa.free(sub);
                    try expectMirrorMatches(gpa, doc, child, mine, sub);
                }
            }
        },
        .list => {
            var src = try hydrateList(RtSet, &doc.ops, gpa, obj, null);
            defer src.deinit();
            const sl = asList(&src) orelse return wrongKind(path, "list");
            const gl = asList(got) orelse return wrongKind(path, "list");
            if (sl.count() != gl.count()) {
                std.debug.print("{s}: mirror has {d} elements, document has {d}\n", .{
                    path, gl.count(), sl.count(),
                });
                return error.TestUnexpectedResult;
            }
            var i: usize = 0;
            var sit = sl.items.iter();
            while (sit.next()) |sv| {
                const mine = gl.get(i) orelse {
                    std.debug.print("{s}[{d}]: absent from the mirror\n", .{ path, i });
                    return error.TestUnexpectedResult;
                };
                if (!sv.value.eql(mine)) {
                    std.debug.print("{s}[{d}]: document {any}, mirror {any}\n", .{
                        path, i, sv.value, mine.*,
                    });
                    return error.TestUnexpectedResult;
                }
                if (sv.value.objId()) |child| {
                    const sub = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ path, i });
                    defer gpa.free(sub);
                    try expectMirrorMatches(gpa, doc, child, mine, sub);
                }
                i += 1;
            }
        },
        .text => {
            const src = try doc.text(gpa, obj);
            defer gpa.free(src);
            const gt = asText(got) orelse return wrongKind(path, "text");
            if (!std.mem.eql(u8, src, gt.asStr())) {
                std.debug.print("{s}: document text \"{s}\", mirror text \"{s}\"\n", .{
                    path, src, gt.asStr(),
                });
                return error.TestUnexpectedResult;
            }
            try expectTextMarks(gpa, doc, obj, gt, path);
        },
    }
}

fn wrongKind(path: []const u8, want: []const u8) error{TestUnexpectedResult} {
    std.debug.print("{s}: the mirror does not hold a {s}\n", .{ path, want });
    return error.TestUnexpectedResult;
}

/// Asserts the mirror's text carries every mark the document's text carries.
///
/// **By name and by value, and no more.** [`Text.marks`] is upstream's
/// `HashMap<String, ScalarValue>` (`hydrate/text.rs`:10`), one entry per name,
/// so it cannot say *where* — that is the one thing the round trip cannot read
/// back out of the mirror, and the span is checked where it does survive: in
/// the patch stream and in [`Document.marks`](doc.zig), which the caller
/// compares above. This function says the two agree on every name and value,
/// and that the mirror has no name the document does not.
fn expectTextMarks(
    gpa: Allocator,
    doc: *rtdoc.Document,
    obj: ExId,
    gt: *const Text,
    path: []const u8,
) !void {
    const runs = try doc.marks(gpa, obj);
    defer gpa.free(runs);
    for (runs) |m| {
        var it = gt.marks.iter();
        var seen = false;
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.name, m.name)) continue;
            seen = true;
            if (!e.value.eql(m.value)) {
                std.debug.print("{s}: mark {s} is {any} in the mirror, {any} in the document\n", .{
                    path, m.name, e.value, m.value,
                });
                return error.TestUnexpectedResult;
            }
        }
        if (!seen) {
            std.debug.print("{s}: mark {s} is absent from the mirror\n", .{ path, m.name });
            return error.TestUnexpectedResult;
        }
    }
    var it = gt.marks.iter();
    while (it.next()) |e| {
        var found = false;
        for (runs) |m| {
            if (std.mem.eql(u8, e.name, m.name) and e.value.eql(m.value)) found = true;
        }
        if (!found) {
            std.debug.print("{s}: the mirror holds mark {s}={any}, the document does not\n", .{
                path, e.name, e.value,
            });
            return error.TestUnexpectedResult;
        }
    }
}

// ── 12. The arms nothing reached ────────────────────────────────────────────
//
// Every case below is here for one reason, and the reason is measured rather
// than assumed: **the arm it names was reached by no test in the tree**, which
// was established by breaking that arm and watching the whole suite stay
// green — 1250 tests, no compile error, `FAIL=0`. That is `docs/plan.md` §1.1a
// pointed at this file, and it is the same instrument twice: the arm is broken
// once more after the test is written, and the run names the test that goes
// red.
//
// **The three arms a table shares with a map were split rather than left
// joined** — [`Value.fromPatch`] and [`hydrateOp`]. Upstream states them apart
// (`hydrate.rs`:32`, `:35`, `:295-296`), and a shared arm can only be broken
// together: a mutation that takes out the map takes out the table with it, so
// a test of the table would prove nothing the test of the map had not.

/// The two payload types the assertions below name. **A tagged union's field is
/// reached with [`@FieldType`] and not with `Failure.unknown_object`**, which
/// is the union's *tag*, not its payload.
const UnknownObject = @FieldType(Failure, "unknown_object");
const InvalidProp = @FieldType(Failure, "invalid_prop");

/// Applies `stream` and asserts the refusal is an unknown object, and that it
/// names the step it stopped at.
fn expectUnknownObject(
    v: *Value,
    stream: *const patches.Patches,
    what: []const u8,
    at: usize,
) !UnknownObject {
    const f = try expectRefusal(v, stream, what);
    const u = switch (f) {
        .unknown_object => |u| u,
        else => {
            std.debug.print("{s}: expected unknown_object, got {s}\n", .{ what, @tagName(f) });
            return error.TestUnexpectedResult;
        },
    };
    if (u.at != at) {
        std.debug.print("{s}: stopped at step {d}, expected {d}\n", .{ what, u.at, at });
        return error.TestUnexpectedResult;
    }
    return u;
}

/// Applies `stream` and asserts the refusal is a property that does not
/// resolve, and that it names the step it stopped at.
fn expectInvalidProp(
    v: *Value,
    stream: *const patches.Patches,
    what: []const u8,
    at: usize,
) !InvalidProp {
    const f = try expectRefusal(v, stream, what);
    const p = switch (f) {
        .invalid_prop => |p| p,
        else => {
            std.debug.print("{s}: expected invalid_prop, got {s}\n", .{ what, @tagName(f) });
            return error.TestUnexpectedResult;
        },
    };
    if (p.at != at) {
        std.debug.print("{s}: stopped at step {d}, expected {d}\n", .{ what, p.at, at });
        return error.TestUnexpectedResult;
    }
    return p;
}

test "the walk refuses a scalar in three places, and the three wrong-kind steps are three refusals" {
    const gpa = testing.allocator;

    // **A mirror with a scalar at the root**, which every refusal below needs
    // and which the skeleton does not have: the skeleton's three registers are
    // all objects.
    var m = Value.map(gpa);
    defer m.deinit();
    try m.object.map.putOwned("k", MapValue.init(Value.scalar(ival(1)), false));

    // **A path that ends on a scalar.** The check is past the last step, so the
    // refusal names the path's own length and the object the patch was about —
    // and nothing checks it, because there is no second step to check.
    {
        const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "k" } }};
        var ps = try onePatch(gpa, ex(90, 0), &path, .{
            .put_map = .{
                .key = "k",
                .value = .{ .scalar = ival(2) },
                .obj = ex(91, 0),
                .conflict = false,
            },
        });
        defer ps.deinit();
        const u = try expectUnknownObject(&m, &ps, "a path that ends on a scalar", 1);
        try testing.expect(u.at == u.path.len);
        // **There is no object where it stopped** — the whole content of this
        // refusal is that the mirror holds a scalar, and `got` is how it says
        // so (`hydrate.zig`:224-226`).
        try testing.expect(u.got == null);
        try testing.expect(u.want.eql(ex(90, 0)));
        // **And the register is untouched**: a refusal is not a write.
        try testing.expectEqual(@as(i64, 1), m.object.map.get("k").?.asI64());
    }
    // **A path that walks *through* a scalar**, which is the check inside the
    // loop (`hydrate.zig`:717-718`) and not the one after it. The two are told
    // apart by the object they name: this one names the step's `obj` and that
    // is not the object the patch was about.
    {
        const path = [_]PathElem{
            .{ .obj = .root, .prop = .{ .key = "k" } },
            .{ .obj = ex(90, 0), .prop = .{ .key = "k" } },
            .{ .obj = ex(92, 0), .prop = .{ .key = "k" } },
        };
        var ps = try onePatch(gpa, ex(92, 0), &path, .{ .delete_map = .{ .key = "k" } });
        defer ps.deinit();
        const u = try expectUnknownObject(&m, &ps, "a path that walks through a scalar", 1);
        try testing.expect(u.at < u.path.len);
        try testing.expect(u.got == null);
        try testing.expect(u.want.eql(ex(90, 0)));
        try testing.expectEqual(@as(i64, 1), m.object.map.get("k").?.asI64());
    }
    // **A scalar at the root with nothing to walk** — the *same* check as the
    // case above, because the check is `cur.objId()` and the loop is what
    // moves `cur`, and an empty path never moves it
    // ([`hydrate.zig`](hydrate.zig):731-732`). It is here because it is the
    // shape [`Value.applyPatches`]'s own doc promises: "a scalar at the root
    // is a refusal, not an allocation" (`:675-676`).
    {
        var s = Value.fromScalar(ival(1));
        defer s.deinit();
        var ps = try onePatch(gpa, ex(90, 0), &.{}, .{ .delete_map = .{ .key = "k" } });
        defer ps.deinit();
        const u = try expectUnknownObject(&s, &ps, "a scalar at the root", 0);
        try testing.expect(u.path.len == 0);
        try testing.expect(u.got == null);
    }

    // **Three properties that address nothing**, each refused at the step it
    // names. Upstream reaches the first two through the two `ok_or_else`s of
    // its match (`hydrate.rs`:96-103`) and never reaches the third at all,
    // because it cannot walk into a text's children and a hydrated text has
    // none to walk into (`hydrate/text.rs`:8-11`).
    {
        var seed = try seeded(gpa);
        defer seed.deinit();
        {
            // A map has no indices. This is the arm the walk would otherwise
            // answer with the register the key named.
            const path = [_]PathElem{.{ .obj = .root, .prop = .{ .index = 0 } }};
            var ps = try onePatch(gpa, .root, &path, .{ .delete_map = .{ .key = "list" } });
            defer ps.deinit();
            _ = try expectInvalidProp(&seed.value, &ps, "an index into a map", 0);
        }
        {
            // A list has no keys, and the arm the walk would otherwise answer
            // with the element the index named.
            const path = [_]PathElem{
                .{ .obj = .root, .prop = .{ .key = "list" } },
                .{ .obj = sk_list, .prop = .{ .key = "a" } },
            };
            var ps = try onePatch(gpa, sk_list, &path, .{
                .delete_seq = .{ .index = 0, .length = 1 },
            });
            defer ps.deinit();
            _ = try expectInvalidProp(&seed.value, &ps, "a key into a list", 1);
        }
        {
            // **A text holds no children**: its characters are its storage, so
            // there is nothing at any property of one. An *index* is the
            // no-op of the next test; a *key* has no arm at all.
            const path = [_]PathElem{
                .{ .obj = .root, .prop = .{ .key = "text" } },
                .{ .obj = sk_text, .prop = .{ .key = "a" } },
            };
            var into = try patches.ConcreteTextValue.init(gpa, "Z", doc_enc);
            defer into.deinit();
            var ps = try onePatch(gpa, sk_text, &path, .{ .splice_text = .{
                .index = 0,
                .value = into,
                .marks = null,
            } });
            defer ps.deinit();
            _ = try expectInvalidProp(&seed.value, &ps, "a key into a text", 1);
        }
    }
}

test "a patch that indexes into a text applies and changes nothing" {
    const gpa = testing.allocator;
    var m = Value.map(gpa);
    defer m.deinit();
    try m.object.map.putOwned("text", MapValue.init(try Value.text(gpa, doc_enc, "ab"), false));

    // **The no-op arm of [`Value.applyOne`]** (`hydrate.zig`:720`), and it is
    // upstream's own with the same reason written on it: "Hydrated text
    // represents embedded block objects only by their replacement characters,
    // so patches to a block's contents do not affect the hydrated text value"
    // (`hydrate.rs`:104-107`). **A `.ok` and not a refusal** is the claim, so
    // this asserts both halves: the stream applies, and the text is the text it
    // was.
    const path = [_]PathElem{
        .{ .obj = .root, .prop = .{ .key = "text" } },
        .{ .obj = .root, .prop = .{ .index = 0 } },
    };
    var spliced = try patches.ConcreteTextValue.init(gpa, "Z", doc_enc);
    defer spliced.deinit();
    var ps = try onePatch(gpa, .root, &path, .{ .splice_text = .{
        .index = 0,
        .value = spliced,
        .marks = null,
    } });
    defer ps.deinit();
    try applyAll(gpa, &m, &ps, "a patch into a text's contents");

    const t = asText(m.object.map.get("text").?) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ab", t.asStr());
    try testing.expectEqual(@as(usize, 2), t.count());
    // **The same step into a list is not a no-op**, and that is what makes the
    // one a decision about texts rather than a shrug over indices: the
    // mirror's list holds a map at index 0, the patch names that map, and the
    // register lands in it. A build that read every index as a text index would
    // drop this patch and pass the half above.
    {
        // **A list holding a map at index 0.** `errdefer` and not `defer`,
        // because [`Map.putOwned`] *takes* the value over: on success the map
        // owns this list, and a second `deinit` would be a double free — the
        // hazard [`Map.deinit`]'s doc writes down.
        var l = Value.list(gpa);
        errdefer l.deinit();
        try l.object.list.push(Value.map(gpa), false);
        try m.object.map.putOwned("list", MapValue.init(l, false));

        const lpath = [_]PathElem{
            .{ .obj = .root, .prop = .{ .key = "list" } },
            .{ .obj = .root, .prop = .{ .index = 0 } },
        };
        var lps = try onePatch(gpa, .root, &lpath, .{ .put_map = .{
            .key = "k",
            .value = .{ .scalar = ival(1) },
            .obj = ex(93, 0),
            .conflict = false,
        } });
        defer lps.deinit();
        try applyAll(gpa, &m, &lps, "a patch into a list's contents");
        const el = asList(m.object.map.get("list").?) orelse return error.TestUnexpectedResult;
        const inner = el.get(0) orelse return error.TestUnexpectedResult;
        const im = asMap(inner) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(i64, 1), im.get("k").?.asI64());
    }
}

test "a sequence counter increments by index, and a sequence conflict flags the element it names" {
    const gpa = testing.allocator;
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        log.putMap(.root, "list", .{ .object = .list }, opId(1, 0), false, false);
        log.insert(sk_list, 0, .{ .scalar = cval(10) }, opId(60, 0), false);
        log.insert(sk_list, 1, .{ .scalar = cval(20) }, opId(61, 0), false);
        log.insert(sk_list, 2, .{ .scalar = cval(30) }, opId(62, 0), false);
        log.incrementSeq(sk_list, 1, 7, opId(63, 0));
        log.flagConflict(sk_list, .{ .index = 2 });
        break :blk log.makePatches(TestDoc, &sk_doc);
    };
    defer ps.deinit();

    var m = Value.map(gpa);
    defer m.deinit();
    try applyAll(gpa, &m, &ps, "a sequence increment and a sequence conflict");

    // **Two arms of [`List.apply`] that upstream has and nothing here reached**:
    // `Increment { prop: Prop::Seq(index) }` (`hydrate/list.rs`:69-78`) and
    // `Conflict { prop: Prop::Seq(index) }` (`:79-87`).
    const l = &m.object.map.get("list").?.object.list;
    try testing.expectEqual(@as(usize, 3), l.count());
    // **The element that was incremented, and not its neighbours**: 20 + 7 is
    // 27, and the two counters either side of it are the two the document
    // wrote. A mutation that moved the index or doubled the delta cannot make
    // these three numbers.
    try testing.expectEqual(@as(i64, 10), l.get(0).?.asI64());
    try testing.expectEqual(@as(i64, 27), l.get(1).?.asI64());
    try testing.expectEqual(@as(i64, 30), l.get(2).?.asI64());
    // **The element that was flagged, and not the others** — the conflict is a
    // property of the property, not of the list.
    try testing.expect(!l.items.get(0).?.conflict);
    try testing.expect(!l.items.get(1).?.conflict);
    try testing.expect(l.items.get(2).?.conflict);
    // **And the map's own conflict arms are a different pair**: the same two
    // actions against a map are [`Map.apply`]'s, and the skeleton's nested map
    // has the counter to increment.
    var mps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        log.incrementMap(sk_nested, "c", 3, opId(64, 0));
        log.flagConflict(sk_nested, .{ .key = "c" });
        break :blk log.makePatches(TestDoc, &sk_doc);
    };
    defer mps.deinit();
    var seed = try seeded(gpa);
    defer seed.deinit();
    try applyAll(gpa, &seed.value, &mps, "a map increment and a map conflict");
    const n = &seed.value.object.map.get("nested").?.object.map;
    try testing.expectEqual(@as(i64, 8), n.get("c").?.asI64());
    try testing.expect(n.entries.getPtr("c").?.conflict);
}

test "an increment or a conflict naming the wrong kind of property is refused, naming the action" {
    const gpa = testing.allocator;
    const to_list = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};
    const cases = [_]struct {
        what: []const u8,
        obj: ExId,
        path: []const PathElem,
        action: PatchAction,
        want: []const u8,
    }{
        // A map's increment and conflict are `Prop::Map(key)` and nothing else
        // (`hydrate/map.rs`:44-62`); an index names no register, so the action
        // is not one the map takes.
        .{
            .what = "an increment of an index into a map",
            .obj = .root,
            .path = &.{},
            .action = .{ .increment = .{ .prop = .{ .index = 0 }, .value = 1 } },
            .want = "invalid_map_op",
        },
        .{
            .what = "a conflict on an index into a map",
            .obj = .root,
            .path = &.{},
            .action = .{ .conflict = .{ .prop = .{ .index = 0 } } },
            .want = "invalid_map_op",
        },
        // A list's are `Prop::Seq(index)` (`hydrate/list.rs`:69-87`), which is
        // the mirror image of the map's: the two arms are each other's
        // missing half, and neither object has an arm for the other's property.
        .{
            .what = "an increment of a key in a list",
            .obj = sk_list,
            .path = &to_list,
            .action = .{ .increment = .{ .prop = .{ .key = "a" }, .value = 1 } },
            .want = "invalid_list_op",
        },
        .{
            .what = "a conflict on a key in a list",
            .obj = sk_list,
            .path = &to_list,
            .action = .{ .conflict = .{ .prop = .{ .key = "a" } } },
            .want = "invalid_list_op",
        },
    };
    for (cases) |c| {
        var ps = try onePatch(gpa, c.obj, c.path, c.action);
        defer ps.deinit();
        var seed = try seeded(gpa);
        defer seed.deinit();
        const f = try expectRefusal(&seed.value, &ps, c.what);
        const got = @tagName(f);
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("{s}: refused as {s}, expected {s}\n", .{ c.what, got, c.want });
            return error.TestUnexpectedResult;
        }
    }
    // **And the mirror is unchanged by all four**, which a tag check alone
    // would not say: a refusal that also wrote is still a refusal.
    {
        var seed = try seeded(gpa);
        defer seed.deinit();
        const before = try renderTop(gpa, &seed.value);
        defer gpa.free(before);
        for (cases) |c| {
            var ps = try onePatch(gpa, c.obj, c.path, c.action);
            defer ps.deinit();
            _ = try expectRefusal(&seed.value, &ps, c.what);
        }
        const after = try renderTop(gpa, &seed.value);
        defer gpa.free(after);
        try testing.expectEqualStrings(before, after);
    }
}

test "a text takes an insert, takes a put_seq, and refuses text that is not text in the encoding" {
    const gpa = testing.allocator;

    // **`Text::apply`'s `Insert` arm** (`hydrate/text.rs`:35-44`), which the
    // index advances by the **width of what was spliced** and not by one
    // (`hydrate/text.rs`:41`, and this file's `:1456`). The width is the
    // document's encoding's, so the claim is only visible in an encoding where
    // it is not one — and every test above this one runs in the default one.
    //
    // **U+1F600 is four UTF-8 code units, one code point and two UTF-16 code
    // units**, so a test in `unicode_code_point` cannot tell the two rules
    // apart at all. This test uses `utf8_code_unit` to distinguish them.
    {
        // **The first value is four units wide in this encoding**, so the index
        // the second value lands on is the claim.
        var t = try Value.text(gpa, .utf8_code_unit, "ab");
        defer t.deinit();
        const inner = &t.object.text;
        var values: patches.InsertValues = .init(gpa);
        defer values.deinit();
        try values.push(.{
            .value = .{ .scalar = sval("\xf0\x9f\x98\x80") },
            .obj = ex(90, 0),
            .conflict = false,
        });
        try values.push(.{ .value = .{ .scalar = sval("Z") }, .obj = ex(91, 0), .conflict = false });
        var ps = try onePatch(gpa, .root, &.{}, .{ .insert = .{ .index = 0, .values = values } });
        defer ps.deinit();
        switch (try t.applyOne(.utf8_code_unit, ps.items.items[0])) {
            .ok => {},
            .refused => |f| {
                std.debug.print("an insert of two values refused: {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
        // **The second value went after the first, and not inside it.** Had the
        // index advanced by one unit the "Z" would have landed between the
        // bytes of the U+1F600 and the text would have been left holding
        // invalid UTF-8 — which is a different, and much quieter, fault.
        try testing.expectEqualStrings("\xf0\x9f\x98\x80Zab", inner.asStr());
        try testing.expectEqual(@as(usize, 7), inner.count());
    }

    // **`Text::apply`'s `PutSeq` arm** (`hydrate/text.rs`:45-50`): one unit is
    // removed and the value is spliced in its place, which is a **replace** and
    // not an insert.
    {
        var t = try Value.text(gpa, doc_enc, "abc");
        defer t.deinit();
        const inner = &t.object.text;
        var ps = try onePatch(gpa, .root, &.{}, .{ .put_seq = .{
            .index = 1,
            .value = .{ .scalar = sval("Z") },
            .obj = ex(92, 0),
            .conflict = false,
        } });
        defer ps.deinit();
        switch (try t.applyOne(doc_enc, ps.items.items[0])) {
            .ok => {},
            .refused => |f| {
                std.debug.print("a put_seq on a text refused: {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
        try testing.expectEqualStrings("aZc", inner.asStr());
    }

    // **And the encoding refusal** — upstream's `InvalidEncoding`, which is
    // `splice_text_value`'s error turned into a [`Failure`] (`hydrate/text.rs`:32`,
    // `hydrate.rs`:174`). This case exercises invalid stored bytes; the
    // range-deletion regression below also checks unrepresentable boundaries
    // in otherwise valid UTF-16 text. An index past the end clamps rather
    // than complaining. Here the mirror starts out holding bytes no text can
    // hold, and the walk over them is what fails.
    {
        var t = try Value.text(gpa, doc_enc, "\xffab");
        defer t.deinit();
        const inner = &t.object.text;
        var ps = try onePatch(gpa, .root, &.{}, .{ .delete_seq = .{ .index = 0, .length = 1 } });
        defer ps.deinit();
        const f = try expectRefusal(&t, &ps, "a delete from text that is not text");
        switch (f) {
            .invalid_encoding => {},
            else => {
                std.debug.print("expected invalid_encoding, got {s}\n", .{@tagName(f)});
                return error.TestUnexpectedResult;
            },
        }
        // **Nothing was removed**, which a refusal on its own does not say.
        try testing.expectEqualStrings("\xffab", inner.asStr());
    }
}

test "Text.apply delete_seq preserves the suffix after a supplementary scalar in every encoding" {
    const gpa = testing.allocator;
    const emoji = "\xf0\x9f\x98\x80";
    for ([_]TextEncoding{ .unicode_code_point, .utf8_code_unit, .utf16_code_unit, .grapheme_cluster }) |enc| {
        var text = try Text.init(gpa, .root, enc, "ab" ++ emoji ++ "cd");
        defer text.deinit();
        const applied = try text.apply(enc, .{ .delete_seq = .{
            .index = enc.width("ab"),
            .length = enc.width(emoji),
        } });
        switch (applied) {
            .ok => {},
            .refused => return error.TestUnexpectedResult,
        }
        try testing.expectEqualStrings("abcd", text.asStr());
        try testing.expectEqual(enc.width("abcd"), text.count());
    }
}

test "Text.apply delete_seq leaves the whole action unchanged on allocation refusal" {
    for (0..2) |offset| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var text = try Text.init(gpa, .root, .unicode_code_point, "abcd");
        defer text.deinit();
        const old = text.value.bytes;
        failing.fail_index = failing.alloc_index + offset;
        const applied = text.apply(.unicode_code_point, .{ .delete_seq = .{ .index = 1, .length = 2 } });
        failing.fail_index = std.math.maxInt(usize);
        if (applied) |out| {
            switch (out) {
                .ok => {},
                .refused => return error.TestUnexpectedResult,
            }
            try testing.expectEqualStrings("ad", text.asStr());
        } else |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            try testing.expectEqualStrings("abcd", text.asStr());
            try testing.expectEqual(old.ptr, text.value.bytes.ptr);
        }
    }
}

test "Text.apply delete_seq refuses split UTF16 boundaries without changing text" {
    const initial = "ab\xf0\x9f\x98\x80cd";
    for ([_]struct { index: usize, length: usize }{
        .{ .index = 2, .length = 1 },
        .{ .index = 3, .length = 1 },
    }) |span| {
        var text = try Text.init(testing.allocator, .root, .utf16_code_unit, initial);
        defer text.deinit();
        const old = text.value.bytes;
        const applied = try text.apply(.utf16_code_unit, .{ .delete_seq = .{
            .index = span.index,
            .length = span.length,
        } });
        switch (applied) {
            .refused => |failure| switch (failure) {
                .invalid_encoding => {},
                else => return error.TestUnexpectedResult,
            },
            .ok => return error.TestUnexpectedResult,
        }
        try testing.expectEqualStrings(initial, text.asStr());
        try testing.expectEqual(old.ptr, text.value.bytes.ptr);
    }
}

test "Text.apply delete_seq clamps overshoot and preserves no-op buffers" {
    for ([_]TextEncoding{ .unicode_code_point, .utf8_code_unit, .utf16_code_unit, .grapheme_cluster }) |enc| {
        var text = try Text.init(testing.allocator, .root, enc, "ab\xf0\x9f\x98\x80cd");
        defer text.deinit();
        const old = text.value.bytes;
        for ([_]struct { index: usize, length: usize }{
            .{ .index = 1, .length = 0 },
            .{ .index = std.math.maxInt(usize), .length = std.math.maxInt(usize) },
        }) |span| {
            switch (try text.apply(enc, .{ .delete_seq = .{ .index = span.index, .length = span.length } })) {
                .ok => {},
                .refused => return error.TestUnexpectedResult,
            }
            try testing.expectEqual(old.ptr, text.value.bytes.ptr);
            try testing.expectEqualStrings("ab\xf0\x9f\x98\x80cd", text.asStr());
        }
        switch (try text.apply(enc, .{ .delete_seq = .{ .index = 2, .length = std.math.maxInt(usize) } })) {
            .ok => {},
            .refused => return error.TestUnexpectedResult,
        }
        try testing.expectEqualStrings("ab", text.asStr());
        try testing.expectEqual(enc.width("ab"), text.count());
    }
}

test "a document in all four encodings hydrates to the same bytes, and its marks are read by hand" {
    const gpa = testing.allocator;
    // **Every encoding, one at a time.** `Document.init` takes
    // the platform default ([`doc.zig`](doc.zig):2413-2415`) and that is a
    // code-point document on this host, so a test that only ever calls it
    // reaches [`TextEncoding.width`]'s first arm and no other.
    for ([_]TextEncoding{ .unicode_code_point, .utf8_code_unit, .utf16_code_unit, .grapheme_cluster }) |enc| {
        var doc = try rtdoc.Document.initWithEncoding(gpa, std.testing.io, enc, .auto);
        defer doc.deinit();
        doc.setActorId(.{ .bytes = "0123456789abcdef" });
        const text = try rttrans.putObject(&doc, .root, .{ .key = "text" }, .text);
        // **A character that is not one unit in any of the three that count
        // code points, code units or UTF-16 units**: U+1F600 is one code point,
        // four UTF-8 code units and two UTF-16 code units, so every encoding
        // puts this text at a different length.
        try rttrans.spliceText(&doc, text, 0, 0, "a\xf0\x9f\x98\x80b");
        try rttrans.mark(&doc, text, 1, 3, "bold", .after, .{ .bool_value = true });

        const heads = try doc.getHeads(gpa);
        defer gpa.free(heads);
        var stream = try doc.diff(gpa, &.{}, heads);
        defer stream.deinit();

        var mirror = Value.map(gpa);
        defer mirror.deinit();
        switch (try mirror.applyPatches(doc.textEncoding(), stream.slice())) {
            .ok => {},
            .refused => |f| {
                std.debug.print("{s}: {s}\n", .{ @tagName(enc), @tagName(f) });
                return error.TestUnexpectedResult;
            },
        }

        // **The bytes are the document's, whatever the encoding measured them
        // in.**
        const t = asText(rootMap(&mirror).get("text") orelse return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("a\xf0\x9f\x98\x80b", t.asStr());
        // **And the length is the encoding's**, read back off the mirror's own
        // text and not off the string: this is the assertion that says the
        // mirror spliced in *its* encoding rather than the default one.
        try testing.expectEqual(enc.width("a\xf0\x9f\x98\x80b"), t.count());

        // **The mark set, compared by hand and not with [`Text.eql`].** That
        // helper is `asStr()` alone (see its doc), so a document whose marks
        // were dropped entirely would pass a comparison written with it; the
        // round trip above is the reason that is acceptable there and the
        // reason it is not acceptable here. Every name, every value, and no
        // name the document does not have.
        try testing.expectEqual(@as(usize, 1), t.marks.len());
        try testing.expectEqualStrings("bold", t.marks.entries.items[0].name);
        try testing.expect(t.marks.entries.items[0].value.eql(.{ .bool_value = true }));
        var live = try withoutUnmarks(gpa, &t.marks);
        defer live.deinit();
        try testing.expectEqual(@as(usize, 1), live.len());
        try testing.expectEqualStrings("bold", live.entries.items[0].name);
    }
}

test "a conflict flag on a put, a put_seq and an insert reaches the mirror" {
    const gpa = testing.allocator;
    var ps = try blk: {
        var log: patches.PatchLog = .active(gpa);
        defer log.deinit();
        // **The same key twice, and the two puts disagree about the conflict
        // flag.** That is what makes [`Map.putOwned`]'s replace branch
        // observable at all: the register ends up holding the *second* put's
        // value **and** the second put's flag, and a branch that kept the old
        // record would answer the first put's. The leak checker is what says
        // the first register's bytes were freed rather than dropped.
        log.putMap(.root, "c", .{ .scalar = ival(1) }, opId(60, 0), false, false);
        log.putMap(.root, "c", .{ .scalar = ival(2) }, opId(61, 0), true, false);
        log.putSeq(sk_list, 0, .{ .scalar = sval("Z") }, opId(62, 0), true, false);
        log.insert(sk_list, 1, .{ .scalar = ival(9) }, opId(63, 0), true);
        break :blk log.makePatches(TestDoc, &sk_doc);
    };
    defer ps.deinit();

    var seed = try seeded(gpa);
    defer seed.deinit();
    try applyAll(gpa, &seed.value, &ps, "three conflicted actions");

    // **The flag is the patch's own** ([`patch.rs`](patches.zig):40-42`, `:51-54`,
    // `:60`) and it is the winner's, so it rides on the register and the
    // element and not on the map and the list.
    const m = &seed.value.object.map;
    try testing.expectEqual(@as(i64, 2), m.get("c").?.asI64());
    try testing.expect(m.entries.getPtr("c").?.conflict);
    // **And a register the stream did not write conflicted is not conflicted.**
    try testing.expect(!m.entries.getPtr("list").?.conflict);
    try testing.expect(!m.entries.getPtr("nested").?.conflict);
    const l = &m.get("list").?.object.list;
    try testing.expectEqual(@as(usize, 3), l.count());
    try testing.expectEqualStrings("Z", l.get(0).?.asStr());
    try testing.expectEqual(@as(i64, 9), l.get(1).?.asI64());
    try testing.expectEqual(@as(i64, 2), l.get(2).?.asI64());
    try testing.expect(l.items.get(0).?.conflict);
    try testing.expect(l.items.get(1).?.conflict);
    try testing.expect(!l.items.get(2).?.conflict);
}

test "a table is a map, in a patch and in the op set" {
    const gpa = testing.allocator;
    {
        // **A patch that puts a table.** The arm is
        // [`Value.fromPatch`]'s and it is a map, not a list and not a text —
        // upstream says so in a line of its own (`hydrate.rs`:35`).
        var ps = try blk: {
            var log: patches.PatchLog = .active(gpa);
            defer log.deinit();
            log.putMap(.root, "tbl", .{ .object = .table }, opId(60, 0), false, false);
            break :blk log.makePatches(TestDoc, &sk_doc);
        };
        defer ps.deinit();
        var m = Value.map(gpa);
        defer m.deinit();
        try applyAll(gpa, &m, &ps, "a table");
        const got = m.object.map.get("tbl") orelse {
            std.debug.print("the mirror has no key \"tbl\"\n", .{});
            return error.TestUnexpectedResult;
        };
        try testing.expect(got.object == .map);
        try testing.expectEqual(@as(usize, 0), got.object.map.count());
        // **And the id the patch named is the one the mirror recorded**, which
        // is the same record a map's `put_map` makes and the only thing that
        // makes a later patch about the table applicable.
        try testing.expect(got.objId().?.eql(ex(60, 0)));
    }
    {
        // **A `make_table` row in the op set**, which is [`hydrateOp`]'s arm
        // (`hydrate.rs`:296`) and a different function from the one above.
        const f = try Fixture.init(gpa, &.{rt_actor});
        defer f.destroy();
        // **Spliced in and not merged**, which is [`Fixture.build`]'s own note:
        // a base is spliced, a change is merged, and a `make` is not a patch,
        // so there is nothing for a log to say. The second row is a register
        // **inside** the table, so the assertion below is a walk and not a
        // shape check.
        try f.build(0, &[_]Rec{
            .{ .ctr = 1, .key = .fromStr("t"), .act = .make_table },
            .{ .ctr = 2, .obj = ex(1, 0), .key = .fromStr("in"), .val = ival(1) },
            // **A second object, empty**, so that an arm which hydrated the
            // table as *this* one would answer an empty map rather than crash
            // — a wrong answer is a test, and a crash is a bug report.
            .{ .ctr = 3, .key = .fromStr("other"), .act = .make_map },
        });
        var root = try hydrateMap(Fixture.Set, &f.set, gpa, .root, null);
        defer root.deinit();
        const got = root.object.map.get("t") orelse return error.TestUnexpectedResult;
        // **A table is a map and not a list or a text**, and it hydrates the
        // object's own registers like any other.
        try testing.expect(got.object == .map);
        try testing.expectEqual(@as(usize, 1), got.object.map.count());
        try testing.expectEqual(@as(i64, 1), got.object.map.get("in").?.asI64());
        // **And the id the row carried is the one the mirror recorded.** With
        // the wrong one the walk above reads the root's registers and finds
        // nothing there, which is a crash rather than a wrong answer — so this
        // assertion is the one that says which of the two it was.
        try testing.expect(got.objId().?.eql(ex(1, 0)));
    }
}

test "two marks on one element, and the second one does not lose the first" {
    const gpa = testing.allocator;
    var seed = try seeded(gpa);
    defer seed.deinit();
    const path = [_]PathElem{.{ .obj = .root, .prop = .{ .key = "list" } }};

    {
        // A [`PatchAction.mark`](patches.zig) carries **runs** — a name, a
        // value and a half-open range — and not a [`MarkSet`], which is the
        // resolved set over a span the builder has already computed.
        var runs = [_]Mark{Mark.init("bold", .{ .bool_value = true }, 0, 1)};
        var ps = try onePatch(gpa, sk_list, &path, .{ .mark = .{ .marks = runs[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "a mark on element 0");
    }
    {
        // **A second mark on the same element, in a second stream.** The first
        // one gave the element an [`Owned`] record ([`hydrate.zig`:1312`) and the
        // second must add to it rather than make another: a mirror that replaced
        // the record would drop the first name and the first payload. The
        // assertion at the end of this test is what says so, and the leak
        // checker is what says the drop was also a leak.
        var runs = [_]Mark{Mark.init("link", .{ .str = "https://example.com" }, 0, 1)};
        var ps = try onePatch(gpa, sk_list, &path, .{ .mark = .{ .marks = runs[0..] } });
        defer ps.deinit();
        try applyAll(gpa, &seed.value, &ps, "a second mark on element 0");
    }

    const l = &seed.value.object.map.get("list").?.object.list;
    const first = l.items.get(0).?;
    // **Both names, both payloads, in name order** ([`MarkSet`](marks.zig) keeps
    // a name-sorted array).
    try testing.expectEqual(@as(usize, 2), first.marks.len());
    try testing.expectEqualStrings("bold", first.marks.entries.items[0].name);
    try testing.expect(first.marks.entries.items[0].value.eql(.{ .bool_value = true }));
    try testing.expectEqualStrings("link", first.marks.entries.items[1].name);
    try testing.expectEqualStrings("https://example.com", first.marks.entries.items[1].value.str);
    // **And the element's own record holds every byte the element holds**: the
    // value's own payload, the name of each mark, and the payload of the mark
    // that has one — four copies, because a `bool_value` mark has no payload
    // and `["a", bold, link]` is a string, a name, a name and a string. **This
    // is the assertion that makes the record load-bearing**: with the record
    // replaced, the mark set above still reads correctly and only this count
    // fails, which is why it is here and not left to the leak checker.
    try testing.expect(first.owned != null);
    try testing.expectEqual(@as(usize, 4), first.owned.?.items.items.len);
    // **The second element is untouched**, because a mark is a run and the run
    // was `[0, 1)`.
    try testing.expectEqual(@as(usize, 0), l.items.get(1).?.marks.len());
    // **And the value is untouched**, because a mark is out of band.
    try testing.expectEqualStrings("a", l.get(0).?.asStr());
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The section above is the hydrate round trip a caller actually performs,
//   and it is new: upstream has no test for it.** Upstream's
//   `hydrate/tests.rs` is forty lines and its round trips are
//   `automerge/tests/text.rs`, whose thirteen patch-stream tests the file
//   `src/read.zig`'s own diff block records as unportable at the time it was
//   written — `Document` had no patch log and `Automerge::diff` had no
//   counterpart. Both exist now (`doc.zig`:3948-4188`, and
//   `opset/batch.zig`'s `applyChangesBatchToSink` in place of the hard-coded
//   `NullLog`), so the stream a document produces can be replayed and compared.
//
// * **The comparison is per register and per element, not a length and not a
//   hash.** [`expectMirrorMatches`] walks the document's own objects, looks up
//   every register by name and every element by index, compares the value at
//   each one, and treats a count mismatch as its own failure. The round trip is
//   only a round trip if the two trees are the same tree.
//
// * **The span of a text mark is checked where the format keeps it, not in the
//   mirror.** Upstream's `hydrate::Text` holds
//   `marks: HashMap<String, ScalarValue>` (`hydrate/text.rs`:10) — one entry per
//   name and nothing about where — so a mirror *cannot* carry a text mark's
//   range, and a test that claims it does would be testing something the data
//   model does not have. The second test therefore says it in three places:
//   the patch stream's [`PatchAction.mark`](patches.zig) run carries
//   `[start, end)`, [`Document.marks`](doc.zig) reports the same range from the
//   other reader, and the mirror holds the name and value. The first test
//   asserts the mirror's mark set against every run the document has, which is
//   the whole of what [`Text.marks`] can hold.
//
// * **A mirror's containers are copied by value, and that is upstream's own
//   shape.** Upstream's [`Value`] holds `Map` by value and Rust's `Drop` is
//   what makes that safe to copy; Zig has no `Drop`, so [`Map.deinit`] is the
//   one free and **exactly one owner may run it.** The hazard is real and is
//   documented on the type: a by-value copy of a [`Map`] — which the port's own
//   [`Transaction.initRootFromHydrate`](transact.zig) is *given*, because it
//   takes a `hydmod.Map` parameter by value — is a move, and the source must
//   not be deinit'd afterwards. Zig has no move-only type, so this cannot be
//   made a compile error; it is a rule the constructors and the doc comments
//   state rather than one the compiler enforces. The fixture that faulted,
//   `transact.test.initRootFromHydrate`, copied a `Map` into another `Map` *and*
//   freed the source on the error path.
//
//   **The answer, stated once: yes, the type permits the copy, and yes, that
//   is a double free if both owners deinit — and it should stay that way,
//   because the alternative is worse.** A move-only type is not expressible
//   in Zig: a `deinit(self: Map)` that consumes its receiver is still a copy
//   at every call site and still compiles for a second `deinit`, so the type
//   system buys nothing and the debug print goes away. What *is* worth buying
//   is the loudness of getting it wrong, and every container here ends its
//   `deinit` with `self.* = undefined` — a second free then walks undefined
//   bytes and traps, where a zeroed-after-free would be a silent no-op and
//   would hide the bug behind a document that leaks instead. The rule is
//   written on all three containers now: [`Map.deinit`] argues it,
//   [`List.deinit`] and [`Text.deinit`] carry the same two sentences and point
//   at it, because [`Value`] embeds each of them by value and so every
//   function in this file that takes or returns a `Value` copies one.
//
// * **The two id checks in [`Value.applyOne`] compare by the actor's *bytes*,
//   and this is upstream's [`PartialEq for ExId`]**
//   ([`exid.rs`:126-138](../../github-automerge-automerge/rust/automerge/src/exid.rs)):
//   two roots are equal, and two ids are equal when the counter matches and the
//   actor's bytes match. It is **not** [`ExId.eql`](types.zig), which compares
//   the [`OpId`] — and that difference is the whole point, because an `OpId`
//   names its actor by **position**. Upstream cannot get this wrong in the
//   first place, because [`Value.apply_patches`] throws the ids away
//   (`hydrate.rs`:84`, `p.path.iter().map(|(_, prop)| prop)`) and walks only
//   the properties; the object check is this file's own addition (the module
//   doc's "refuse, do not invent"), so the comparison it needs is this file's
//   to get right too.
//
//   **It is bytes, because a patch stream and the mirror it is replayed into
//   can be read from two documents that number their actors differently.** The
//   isolation forks a concurrency actor whose magic bytes are
//   `0x13 b2 23 09` ([`types.rs`:23](../../github-automerge-automerge/rust/automerge/src/types.rs));
//   it sorts before most real actors, so it lands at the front of the sorted
//   table and shifts every index at or above it
//   ([`op_set.rs`:1400-1405](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
//   Upstream's answer to that is the third field of `ExId::Id`: the actor's
//   bytes beside the index, read back by `Automerge::exid_to_opid`
//   ([`automerge.rs`:744-758](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
//   whenever an index needs repairing. **This port repairs nothing here** — the
//   mirror has no actor table to repair against — and does not need to: with
//   the bytes on both sides ([`OpSet.idToExid`](opset/op_set.zig) now records
//   them, as upstream's `OpSet::id_to_exid` does at `op_set.rs:1054-1060`), the
//   index is not consulted at all. An id that carries no actor is compared the
//   old way, on the index, because there is nothing better to compare it by.
//
// * **The round trip test across an isolation asserts the disagreement, not
//   only the agreement.** It requires the actor's bytes to match on both sides
//   and the **indices to differ**, so a build where the two sides happened to
//   agree — and the comparison therefore never had to consult the actor —
//   cannot pass it. The two round trips above it cannot: neither renumbers
//   anything under the mirror, so neither would have caught a comparison on the
//   index.
//
// * **A mirror owns every byte it stores, and this file's borrow rule is gone
//   because upstream never had one.** The rule it replaced said a mirror
//   "borrows every byte of content — a `str`, a `bytes` payload, an `unknown`
//   payload, a mark name — from the [`Patches`](patches.zig) batch the stream
//   came out of, or from the op set the [`hydrateOp`] family read", and named
//   only the batch. **It was a port-only invention, and it was unenforceable:
//   `Value` here is a flat union of borrowed slices with no lifetime
//   parameter, so nothing stopped a mirror outliving the op set it was read
//   from.** The measured failure was `upstream_doc_test.zig:4543` — a mirror's
//   `id` at `5@0` reading `0xe3` where a re-read said `"b"` — and the fault was
//   in a *value*, not a crash, which is worse: a crash is a bug report and a
//   wrong byte is a corrupted document.
//
//   **Upstream cannot express the crossing because the mirror there owns its
//   bytes by construction.** `hydrate::Value` is `Scalar(ScalarValue) | Map |
//   List | Text` (`hydrate.rs`:22-27`) and holds `crate::types::ScalarValue`
//   (`value.rs`:519-522`) — `Bytes(Vec<u8>)` and `Str(SmolStr)` — so the enum
//   carries **no lifetime parameter at all** and a mirror is `'static`. The
//   op set holds the borrowed form instead (`Cow<'a, [u8]>`, `Cow<'a, str>`,
//   `op_set2/types.rs`:192-194`), and the crossing is one line:
//   `OpType::Put(scalar) => Value::Scalar(scalar.into())` (`hydrate.rs`:299`),
//   whose `From<ScalarValue<'a>> for types::ScalarValue`
//   (`op_set2/types.rs`:222-225`) is `into_legacy` (`:278-281`) — `b.to_vec()`
//   and `s.to_string().into()`. **The copy is upstream's, at the boundary, and
//   the port's [`ownValue`] is the same copy at the same place.** The patch
//   path is the same story: [`Value::new`] takes
//   `Value::Scalar(s.into_owned())` (`hydrate.rs`:36`), and `into_owned` turns
//   `Cow::Borrowed` into `Cow::Owned` (`value.rs`:182-188`).
//
//   **Three doors, and every byte crosses one of them**: [`Map.putOwned`],
//   [`List.ownElement`] (behind [`List.push`] and [`List.apply`]), and
//   [`ownMark`] (behind [`List.applyMarks`], [`Text.putMark`] and the
//   [`hydrateText`] fold). Each records what it copied on the stored record —
//   [`MapValue.owned`], [`ListValue.owned`], [`Text.owned`] — and that record's
//   `deinit` frees it, so a replaced register and a removed element give their
//   bytes back at once rather than at the container's death.
//
//   **The cost is one copy per byte-bearing scalar per patch, and one per mark
//   name and per mark payload per patch.** That is the work upstream does at the
//   same place, so it is not a price the port invented; it is stated here
//   because it is a real allocation on a path that previously had none. A
//   scalar with no bytes builds no record at all — [`ownValue`] returns null and
//   nothing is allocated — and a mark name the set already holds is not copied
//   twice, because [`MarkSet.put`](marks.zig):374-383 keeps the name it has.
//   The text buffer was never at risk: a [`ConcreteTextValue`] copies on every
//   splice ([`Text.splice`], [`Text.removeAt`]).
//
//   **The three tests in §11 assert ownership rather than value, because a
//   value comparison cannot.** The first overwrites the caller's buffer after
//   the register has taken the value: a borrowing mirror answers the
//   overwrite. The second and the third read the same source **twice** — one
//   op set, and one patch batch — and require the two mirrors to hold
//   **different addresses**. That is airtight where a comparison is not: a
//   source is immutable while it is being read, so two reads of one source can
//   only land on different addresses if each made its own copy. Both were
//   checked against a build whose [`Owned.keep`] returns its argument, and all
//   three fail there on the ownership assertion itself.
//
// * **Nine of the arms of this file's own dispatches were reached by no test in
//   the tree, and that was measured rather than assumed.** §12 says which. The
//   instrument is `docs/plan.md` §1.1a's: each arm was broken on its own, the
//   whole suite run, and the arm counted as *unverified* when the suite stayed
//   green. **Twenty-six such mutations were run against the tree as it stood,
//   in one batch, and only two of them were detected** — [`Text.putMarks`],
//   which the round trip reaches through a splice that carries marks, and
//   [`textIndexed`]'s *classification*, which the list-index refusal reaches.
//   Everything else in the batch — [`asI64`]'s `uint` and `timestamp`,
//   [`Value.child`]'s three null arms, [`Map.apply`]'s and [`List.apply`]'s
//   wrong-property arms, [`Text.apply`]'s `insert` and `put_seq`,
//   [`encodingRefusal`], [`Value.toScalar`]'s object, the three conflict flags,
//   [`List.applyMarks`]'s owned guard and [`Value.applyOne`]'s three scalar
//   checks — was invisible.
//
//   **The `.ok` arm of [`Value.applyOne`] is the one §12 exists for.** A
//   hydrate test that only ever walks maps cannot tell "a patch into a text's
//   contents is a no-op" (`hydrate.rs`:104-107`) from "every index step is a
//   no-op", and the measured failure of the mutation that confuses the two is
//   that the walk *silently drops* the patch. Upstream's arm is load-bearing
//   for block markers, so a mirror that dropped it would lose every block's
//   contents in a replay.
//
// * **The three arms a table shares with a map are now spelled apart**, in
//   [`Value.fromPatch`] and [`hydrateOp`]. Upstream spells them apart
//   (`hydrate.rs`:32`, `:35`, `:295-296`) and this file did not, and the
//   consequence was not cosmetic: **a shared arm cannot be broken on its own**,
//   so the test that put a table proved nothing the test that put a map had not
//   already proved. With the split, `a table is a map, in a patch and in the
//   op set` fails on the table alone.
//
// * **Four arms of this file are unreachable, and three of them are this
//   port's own additions.** [`Value.applyOne`]'s non-object arm after the walk,
//   [`Value.child`]'s non-object arm and [`textIndexed`]'s are all dead
//   because the one guard above them — `cur.objId() orelse return` — has
//   already refused, and [`List.applyMarks`]'s `getMut` guard is dead because
//   the two `@min`s above it keep the index inside the list. **They are
//   documented where they are rather than deleted**, because a defensive
//   refusal costs one branch and its removal would turn a future refactor of
//   the guard into a crash.
//
// * **`Text.eql` is `asStr()` alone, and §12 does not use it.** Every mark
//   assertion in the new tests is made against the name and the value by
//   hand, and the four-encoding loop says so in as many words: a mirror whose
//   marks were dropped entirely passes a comparison written with that helper,
//   which is why the round trip may use it and this section may not.
