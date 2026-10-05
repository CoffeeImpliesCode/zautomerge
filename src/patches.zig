//! The patch log: the record of what a merge changed, and the ordered list of
//! patches a consumer applies to a materialised view.
//!
//! Upstream is three files — `patches.rs` (6 lines), `patches/patch.rs` (95),
//! `patches/patch_builder.rs` (381) and `patches/patch_log.rs` (779) — and
//! this is all of them:
//!
//! | what | upstream |
//! |------|----------|
//! | [`Patch`], [`PatchAction`], `Patch::has` | `patch.rs:17-30`, `:33-89` |
//! | [`ConcreteTextValue`] | `text_value.rs:192-270` |
//! | [`PatchBuilder`] | `patch_builder.rs:16-364` |
//! | [`PatchLog`] and its twelve-method sink | `patch_log.rs:44-57` |
//! | [`Event`], eleven variants | `patch_log.rs:60-110` |
//! | [`ExposeQueue`] | `patch_log.rs:679-779` |
//!
//! # The three stages, and why the order of the output is the whole point
//!
//! A merge writes [`Event`]s into a [`PatchLog`], one per mutation, each
//! tagged with the object it happened to. [`PatchLog.makePatches`] then sorts
//! those events by object (`patch_log.rs`:515-516`), walks them, and turns each
//! into a [`Patch`] — a change to one object, together with the path that
//! reaches it from the root. A consumer applies the patches **in order**
//! (`hydrate::Value::apply_patches`, `hydrate.rs`:78-87`), so the order is not
//! a convenience: it is the contract. Three rules produce it, and each is a
//! separate mechanism here:
//!
//! * the event sort (`patch_log.rs`:516) groups by object while keeping each
//!   object's events in the order they were logged, because the sort is
//!   **stable** — upstream's `Vec::sort_by` is;
//! * [`PatchBuilder`] coalesces events that target the *same* object and are
//!   adjacent after the sort, and only those ([`maybe_append`](patch_builder.rs):372-381`),
//!   so one run of one object is one patch;
//! * the [`ExposeQueue`] supplies the content of an object the log never saw
//!   created, and it does so **in `ExId` order, interleaved with the events**
//!   — which is what makes a diff of a document that gained an object produce a
//!   stream a hydrate round trip can apply.
//!
//! # What a patch costs, read off the source
//!
//! **No gate in `bench/` reaches this file**, so these are source-derived, not
//! measured, and the numbers that were wrong are named with what fixed them.
//!
//! * **Per event, O(1) plus the patch's own payload.** [`PatchBuilder.maybeAppend`]
//!   reads the tail patch and compares one id — no scan, no map
//!   (`:2087-2093`). **Per patch's first event, O(depth) path steps**, each a
//!   binary search over the [`PathMap`] (`:1543-1555`), and
//!   [`PatchBuilder.updatePathMap`] walks a parent **once per builder**, not
//!   once per child, because `seen` gates it (`:1758-1759`).
//! * **Per coalesced mark event, O(runs in the event)**, and it is that by
//!   appending to the array the patch already names
//!   ([`PatchBuilder.appendMarks`], `:2001-2007`). **It was O(runs already in
//!   the patch) per event** — it built a second array and copied the whole run
//!   list into it every call — so `n` mark events on one patch cost
//!   `1 + 2 + … + (n-1)` copies. That was the one superlinear term in the
//!   builder and it is gone; `test "n mark events on one object coalesce into
//!   one patch holding every run, in order"` is the witness, and it is driven
//!   through the builder because [`PatchLog.mark`] folds consecutive runs into
//!   one event as it records them (`:2700-2716`) and so cannot reach the arm
//!   twice.
//! * **Text splices retain native encoding units in a sequence tree**, matching
//!   upstream's `SequenceTree<u8>`, `<u16>`, `<char>` and `<String>`
//!   (`text_value.rs`:36`, `:75`, `:113`, `:152`). Mutations can split UTF-8
//!   scalars or UTF-16 surrogate pairs; rendering is a separate, owned lossy
//!   UTF-8 copy. Stored grapheme elements are not resegmented by concatenation.
//! * **Once per `makePatches`, O(E log E)** for `E` events, the stable sort at
//!   [`PatchLog.buildCurrent`]'s `std.sort.block` (`:3128`). Amortised over the
//!   patches it produces that is the log's own size, not a per-patch cost.
//!   **It re-sorts on every call** and the events are already sorted after the
//!   first, so a caller that diffs repeatedly pays it repeatedly; upstream has
//!   the same shape ([`patch_log.rs`:515-516](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08/rust/automerge/src/patches/patch_log.rs)).
//! * **Per exposed object, O(1) amortised**, plus a walk of that object's own
//!   content: [`ExposeQueue`] keeps a sorted flat array where upstream has a
//!   `BTreeSet<ExId>` ([`patch_log.rs`:680](../../github-automerge-automerge/rust/automerge/src/patches/patch_log.rs)),
//!   so its `insert` is a binary search **plus an O(queue) memmove**
//!   (`:2220-2231`) and its `remove` an `orderedRemove` (`:2234-2248`). The
//!   queue holds only the objects one diff exposes, which is bounded by the
//!   objects that diff created, so the quadratic is in *that* and not in the
//!   document. **Reported, not fixed**: the memmove is the price of the flat
//!   array the module doc chose on purpose, and the queue is empty for every
//!   diff that exposes nothing.
//!
//! # The one lifetime in this file
//!
//! `opset/batch.zig` hands a sink a **borrowed** mark set and frees it as soon
//! as the call returns (`ValueState.mapFlush` and `ValueState.listFlush` own the
//! set they export, `batch.zig`:803-804`, `:849-852`). Everything a
//! [`PatchLog`] keeps from an **event** is therefore **a copy**: mark names,
//! mark-set entries, map keys, spliced text, and the bytes a scalar payload
//! names. No event borrows from the op set.
//!
//! **The path cache is the one thing that borrows, and it says so.** A
//! [`PathMap`] owns its array and none of its keys
//! ([`PathMap`](PathMap)): [`PatchBuilder.updatePathMap`] copies each key it
//! finds into the batch arena, and a map handed in through
//! [`PatchLog.pathHint`] keeps the keys its builder gave it. Either way the
//! keys are read only while a diff runs, and every path entry is copied into
//! the arena before it reaches a patch.
//!
//! The same rule holds on the way out, for a different reason. Upstream's patch
//! carries `Value<'static>` (`patch.rs`:39`, `:50`, `:61`) and gets there by
//! cloning (`patch_builder.rs`:304`). The port's op-set types borrow their
//! payload, and a patch has to survive the next mutation of the document it
//! came from, so [`Patches`] owns an arena for paths, IDs, scalars and marks.
//! Native text trees use the arena's stable child allocator and are explicitly
//! released before the arena. `Patches.deinit` is the one free a consumer owes.
//!
//! # The document is a parameter, not an import
//!
//! Upstream's [`PatchLog`] and [`PatchBuilder`] hold `&Automerge` and read the
//! op set through it (`patch_log.rs`:511`, `patch_builder.rs`:23`). This port's
//! document (`src/doc.zig`) is being written in parallel and is above this
//! file, so the document is a **comptime type parameter** `D` checked by
//! [`assertDoc`] — the same shape as `opset/batch.zig` checks its patch sink
//! with `assertLog` (`batch.zig`:274-281`). The three walks the log needs
//! yield [`MapItem`], [`ListItem`] and [`Span`]; `doc.zig` supplies iterators
//! over them.
//!
//! # Not here
//!
//! * `hydrate::Value`. Upstream's `Event` holds one (`patch_log.rs`:63`) and
//!   [`PatchBuilder.logEvent`] uses only its tag and its scalar payload
//!   (`patch_builder.rs`:58`, `:77`); [`batch.PatchValue`] is the port's
//!   stand-in and it is what a patch carries. `hydrate.zig` builds the real
//!   value from it.
//! * `Event::Mark`'s `MarkAccumulator` (`patch_log.rs`:108). [`MarkRuns`] is the
//!   same accumulator with owned names, because the port's `MarkSet` names
//!   borrow and this log outlives the op set that holds them.
//! * `Display for PatchAction` (`patch.rs`:91-93`), which is literally
//!   `write!(f, "{:?}", self)`. A derived `Debug` is not a contract; the
//!   [`PatchAction.format`] here is total — every variant prints every field —
//!   so a test that compares lines compares the whole action.
//!
//! ## `mark_decls` is not a thing
//!
//! `opset/batch.zig`'s `log_decls` holds **twelve** names and the twelfth is
//! `migrateActors` (`batch.zig`:248-261`). Upstream's `Event` has **eleven**
//! variants (`patch_log.rs`:60-110`), because `migrate_actors` re-indexes the
//! events rather than adding one. This file ports both counts as they are. It
//! does not change `log_decls`.

const std = @import("std");

const err = @import("error.zig");
const types = @import("types.zig");
const valmod = @import("value.zig");
const marksmod = @import("marks.zig");
const unicode = @import("unicode.zig");
const clocks = @import("clock.zig");
const batch = @import("opset/batch.zig");
const opiter = @import("opset/op_iter.zig");
const opmod = @import("opset/op.zig");
const optypes = @import("opset/types.zig");
const opsetmod = @import("opset/op_set.zig");
const opcols = @import("opset/columns.zig");
const changerec = @import("change.zig");
const seqtree = @import("sequence_tree.zig");

const testing = std.testing;

const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Change = changerec.Change;
const ChangeHash = types.ChangeHash;
const Clock = clocks.Clock;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const KeyRef = optypes.KeyRef;
const Mark = marksmod.Mark;
const MarkSet = marksmod.MarkSet;
const ObjId = types.ExId;
const ObjType = types.ObjType;
const OpId = types.OpId;
const PatchValue = batch.PatchValue;
const Prop = types.Prop;
const ReadOpError = opiter.ReadOpError;
const ScalarValue = optypes.ScalarValue;
const SequenceType = types.SequenceType;
const ParseError = err.ParseError;
const StringTable = opcols.StringTable;
const TextEncoding = types.TextEncoding;

const Allocator = std.mem.Allocator;

/// What [`PatchLog.makePatches`] and [`PatchLog.finishCurrentView`] can raise.
///
/// [`Error`] because the log's own work is `Error`; [`ReadOpError`] because
/// every read of the document is; [`InternalError`] because upstream's
/// `expect("AutoCommit's patch log always belongs to its document")`
/// (`patch_log.rs`:293`) and its `assert!` (`patch_log.rs`:602-605`) are checks
/// upstream treats as impossible and this port reports.
pub const MakeError = Error || ReadOpError || InternalError;

// ── The document this file reads ────────────────────────────────────────────

/// One visible entry of a map object, as [`ExposeQueue.flushObj`] reads it
/// (`doc.map_range_for(..)`, `patch_log.rs`:767-775`).
///
/// **Every slice is borrowed from the document and valid until the next
/// mutation of it.** The patch log copies before it keeps anything.
pub const MapItem = struct {
    /// The key the register hangs by.
    key: []const u8,
    /// The winning value, as a [`batch.PatchValue`].
    value: PatchValue,
    /// The id of the operation that made it.
    id: OpId,
    /// Whether the register holds a live conflict.
    conflict: bool,
};

/// One visible element of a list object, as [`ExposeQueue.flushObj`] reads it
/// (`patch_log.rs`:754-765`).
pub const ListItem = struct {
    /// The index the element sits at, in visible elements.
    index: usize,
    /// The winning value, as a [`batch.PatchValue`].
    value: PatchValue,
    /// The id of the operation that made it.
    id: OpId,
    /// Whether the register holds a live conflict.
    conflict: bool,
};

/// One span of a text object ([`SpanInternal`, `iter/spans.rs`:404-407`).
pub const Span = union(enum) {
    /// A run of text. Upstream's third field is a `MarkDiff` and the log takes
    /// `marks.export()` of it (`patch_log.rs`:739`), so the marks here are the
    /// **resolved** set, already diffed (`iter/spans.rs`:389-398`).
    text: struct {
        /// The text, borrowed.
        text: []const u8,
        /// The index the run starts at, in the object's text encoding.
        index: usize,
        /// The marks active over the run, or null when it has none. **Borrowed
        /// from the iterator and valid until its next `next`** — the same
        /// lifetime `opset/batch.zig` hands a sink, and the reason
        /// [`ExposeQueue.flushObj`] copies before it keeps.
        marks: ?*const MarkSet,
    },
    /// An embedded block object. Upstream's third field is a conflict flag and
    /// the log ignores it (`patch_log.rs`:742`).
    obj: struct {
        /// The id of the operation that made the block.
        id: OpId,
        /// The index the block sits at.
        index: usize,
        /// Whether the register holds a live conflict.
        conflict: bool,
    },
};

/// The document reads [`PatchLog`] makes, by name ([`assertDoc`]).
///
/// Nine names. They are upstream's, in the place upstream makes them:
/// `exportPatchId`, `objectType` and `objectParent` are `doc.ops()` reads
/// (`patch_builder.rs`:150-151`, `:160`), the three range walks are
/// `doc.map_range_for` / `doc.list_range_for` / `doc.ops().spans`
/// (`patch_log.rs`:736`, `:755`, `:767`; `automerge.rs`:1676-1697`;
/// `op_set2/op_set.rs`:381`), and `actorList` is `doc.ops().actors`, which
/// `opset/batch.zig` already hands the merge as `set.actors.items`
/// (`batch.zig`:2065`).
///
/// This is the internal indexed-reader contract, not the raw `Document`
/// surface. `objectType` returns `Error!ObjType`, with `NotAnObject` meaning
/// absence; range iterator `next` calls can refuse reads. `clockAtScope`
/// borrows a document-owned clock through `Error!*const Clock`. Raw documents
/// enter through their adapter-owning patch methods.
/// `exportPatchId(OpId) MakeError!ExId` is the required checked export: an
/// absent resident actor returns `InvalidActorIndex` during rendering, never
/// an unresolved replacement ID. Trusted indexed fixtures own their ID validity.
pub const doc_decls = [_][]const u8{
    "textEncoding",
    "exportPatchId",
    "objectType",
    "objectParent",
    "clockAtScope",
    "actorList",
    "mapRangeFor",
    "listRangeFor",
    "spans",
};

/// Fails to compile unless `D` carries every declaration in [`doc_decls`].
///
/// The shapes of the three range methods are **not** checked here and are
/// checked better at the call site: [`PatchBuilder.updatePathMap`] and
/// [`ExposeQueue.flushObj`] read `key`, `value`, `id`, `index` and `conflict`
/// off the items, so a document whose items are shaped differently does not
/// build, with an error at the read rather than at a name comparison.
pub fn assertDoc(comptime D: type) void {
    inline for (doc_decls) |name| {
        if (!@hasDecl(D, name)) {
            @compileError("patch log document " ++ @typeName(D) ++ " has no " ++ name ++
                "; the reads patch_log.rs:511-529 and patch_builder.rs:112-165 make are in doc_decls");
        }
    }
}

// ── The value a patch carries ───────────────────────────────────────────────

/// A patch payload ([`Value<'static>` upstream, `patch.rs`:39`]).
///
/// **The shape is [`batch.PatchValue`] and the lifetime is not.** A patch
/// outlives the document it was taken from, so every byte a `.str`, `.bytes`,
/// `.actor_id` or `.unknown` scalar names is a copy made in the [`Patches`]
/// arena the patch came out of. Upstream reaches the same place by cloning
/// (`patch_builder.rs`:304`).
pub const Value = union(enum) {
    /// A scalar. **Its byte payloads are arena-owned, not borrowed.**
    scalar: ScalarValue,
    /// An object a make action produced, and of what type.
    object: ObjType,

    /// Whether this is an object rather than a scalar
    /// ([`hydrate::Value::is_object`](hydrate.rs):67-69`).
    pub fn isObject(self: Value) bool {
        return self == .object;
    }

    /// The scalar, or null for an object
    /// ([`hydrate::Value::is_scalar`](hydrate.rs):63-65`).
    pub fn scalarValue(self: Value) ?ScalarValue {
        return switch (self) {
            .scalar => |s| s,
            .object => null,
        };
    }

    /// The value as a string: a `str` scalar is itself and everything else is
    /// the object replacement character ([`hydrate::Value::as_str`](hydrate.rs):71-76`).
    pub fn asStr(self: Value) []const u8 {
        return switch (self) {
            .scalar => |s| switch (s) {
                .str => |t| t,
                else => object_replacement,
            },
            .object => object_replacement,
        };
    }

    /// How wide the value is in a sequence
    /// ([`hydrate::Value::width`](hydrate.rs):60-65`).
    pub fn width(self: Value, seq_type: SequenceType, enc: TextEncoding) usize {
        return switch (seq_type) {
            .list => 1,
            .text => enc.width(self.asStr()),
        };
    }

    /// The value as an integer: a scalar's own, and zero for anything else
    /// ([`hydrate::Value::as_i64`](hydrate.rs):129-134`).
    pub fn asI64(self: Value) i64 {
        return switch (self) {
            .scalar => |s| scalarAsI64(s),
            .object => 0,
        };
    }

    /// Two values, by content. Upstream derives `PartialEq` on `Patch`
    /// (`patch.rs`:16`) and the port's payload is a slice, so the comparison is
    /// spelled out.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .scalar => |x| x.eql(b.scalar),
            .object => |x| x == b.object,
        };
    }
};

/// U+FFFC, the character a non-string value renders as
/// ([`OpBuilder::as_str`](opset/op.zig)).
const object_replacement: []const u8 = "\u{fffc}";

/// A scalar read as an integer, or zero (`op_set2/types.rs`:247-254`). A
/// timestamp counts, and so does a counter, whose payload is the same `i64`.
fn scalarAsI64(v: ScalarValue) i64 {
    return v.asI64OrDefault();
}

// ── ConcreteTextValue ───────────────────────────────────────────────────────

/// The text a [`PatchAction.splice_text`] carries, in the units of the
/// document's encoding ([`ConcreteTextValue`](text_value.rs):192-270`).
///
/// Stores native encoding units in sequence trees, as upstream does
/// (`text_value.rs`:36`, `:75`, `:113`, `:152`). UTF-8 and UTF-16 edits can
/// retain partial scalars and render them lossily (`:60-62`, `:137-139`).
/// Grapheme elements retain their original segmentation after concatenation.
///
/// Every tree owns its allocator-backed storage. A patch's text uses its
/// [`Patches`] arena's stable child allocator, not an allocator pointing into
/// the movable arena itself. Both ordinary values and patch-owned values must
/// be deinitialized exactly once; `Patches` releases its trees automatically.
/// `makeString` returns an independent UTF-8 allocation for the caller to free.
pub const ConcreteTextValue = struct {
    /// Retained allocator: its context must outlive this single owner. Copies
    /// transfer ownership, not duplicate it; call deinit exactly once.
    gpa: Allocator,
    units: Units,

    pub const Unit = union(TextEncoding) {
        unicode_code_point: u21,
        utf8_code_unit: u8,
        utf16_code_unit: u16,
        grapheme_cluster: []const u8,
    };
    const Units = union(TextEncoding) {
        unicode_code_point: seqtree.SequenceTree(u21),
        utf8_code_unit: seqtree.SequenceTree(u8),
        utf16_code_unit: seqtree.SequenceTree(u16),
        grapheme_cluster: seqtree.SequenceTree([]const u8),
    };

    /// Copies UTF-8 into native units. UTF-8-unit storage also accepts invalid
    /// bytes; other encodings return InvalidCharacter for invalid UTF-8.
    /// Allocation refusal releases every provisional resource.
    pub fn init(gpa: Allocator, s: []const u8, enc: TextEncoding) Error!ConcreteTextValue {
        var out: ConcreteTextValue = .{ .gpa = gpa, .units = switch (enc) {
            .utf8_code_unit => .{ .utf8_code_unit = .initReserved(gpa) },
            .utf16_code_unit => .{ .utf16_code_unit = .initReserved(gpa) },
            .unicode_code_point => .{ .unicode_code_point = .initReserved(gpa) },
            .grapheme_cluster => .{ .grapheme_cluster = .initReserved(gpa) },
        } };
        errdefer out.deinit();
        try out.splice(0, s);
        return out;
    }

    /// Ownership of bytes transfers only after successful construction.
    pub fn initOwned(gpa: Allocator, bytes: []u8, enc: TextEncoding) Error!ConcreteTextValue {
        const out = try init(gpa, bytes, enc);
        gpa.free(bytes);
        return out;
    }

    pub fn encoding(self: *const ConcreteTextValue) TextEncoding {
        return std.meta.activeTag(self.units);
    }

    pub fn deinit(self: *ConcreteTextValue) void {
        if (self.units == .grapheme_cluster) {
            var it = self.units.grapheme_cluster.iter();
            while (it.next()) |s| self.gpa.free(s.*);
        }
        switch (self.units) {
            inline else => |*tree| tree.deinit(),
        }
        self.* = undefined;
    }

    pub fn len(self: ConcreteTextValue) usize {
        return switch (self.units) {
            inline else => |tree| tree.len(),
        };
    }

    /// Reads a native unit, or null out of range. A returned grapheme slice is
    /// borrowed and must not survive mutation or deinit.
    pub fn get(self: *const ConcreteTextValue, index: usize) ?Unit {
        return switch (self.units) {
            inline else => |*tree, tag| if (tree.get(index)) |v|
                @unionInit(Unit, @tagName(tag), v.*)
            else
                null,
        };
    }

    /// Native units remain independently editable, including split scalars.
    /// Reserved node capacity makes removal of an inserted prefix infallible.
    /// Past-end indices append. Invalid input or allocation refusal leaves
    /// the original units unchanged. Grapheme boundaries are stored at insertion
    /// and are not recomputed after adjoining edits.
    pub fn splice(self: *ConcreteTextValue, index: usize, value: []const u8) Error!void {
        const at = @min(index, self.len());
        if (value.len == 0) return;
        if (self.encoding() != .utf8_code_unit and !std.unicode.utf8ValidateSlice(value))
            return error.InvalidCharacter;
        var inserted: usize = 0;
        errdefer self.removeRange(at, inserted) catch unreachable;
        switch (self.units) {
            .utf8_code_unit => |*tree| {
                for (value) |byte| {
                    try tree.insert(at + inserted, byte);
                    inserted += 1;
                }
            },
            .utf16_code_unit => |*tree| {
                var it = (std.unicode.Utf8View.initUnchecked(value)).iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp <= 0xffff) {
                        try tree.insert(at + inserted, @intCast(cp));
                        inserted += 1;
                    } else {
                        const scalar: u32 = @as(u32, cp) - 0x10000;
                        try tree.insert(at + inserted, @intCast(0xd800 + (scalar >> 10)));
                        inserted += 1;
                        try tree.insert(at + inserted, @intCast(0xdc00 + (scalar & 0x3ff)));
                        inserted += 1;
                    }
                }
            },
            .unicode_code_point => |*tree| {
                var it = (std.unicode.Utf8View.initUnchecked(value)).iterator();
                while (it.nextCodepoint()) |cp| {
                    try tree.insert(at + inserted, cp);
                    inserted += 1;
                }
            },
            .grapheme_cluster => |*tree| {
                var boundaries = unicode.graphemeBoundaries(value);
                var start: usize = 0;
                while (start < value.len) {
                    const end = (boundaries.next() catch unreachable) orelse value.len;
                    const owned = try self.gpa.dupe(u8, value[start..end]);
                    tree.insert(at + inserted, owned) catch |e| {
                        self.gpa.free(owned);
                        return e;
                    };
                    inserted += 1;
                    start = end;
                }
            },
        }
    }

    pub fn push(self: *ConcreteTextValue, value: []const u8) Error!void {
        try self.splice(self.len(), value);
    }

    pub fn spliceTextValue(self: *ConcreteTextValue, index: usize, other: *const ConcreteTextValue) Error!void {
        if (self.encoding() != other.encoding()) return error.InvalidCharacter;
        if (self == other) {
            var snapshot = try self.dup(self.gpa);
            defer snapshot.deinit();
            return self.spliceTextValue(index, &snapshot);
        }
        const at = @min(index, self.len());
        var inserted: usize = 0;
        errdefer self.removeRange(at, inserted) catch unreachable;
        switch (self.units) {
            inline else => |*tree, tag| {
                const source = &@field(other.units, @tagName(tag));
                var it = source.iter();
                while (it.next()) |v| {
                    const owned = if (tag == .grapheme_cluster)
                        try self.gpa.dupe(u8, v.*)
                    else
                        v.*;
                    tree.insert(at + inserted, owned) catch |e| {
                        if (tag == .grapheme_cluster) self.gpa.free(owned);
                        return e;
                    };
                    inserted += 1;
                }
            },
        }
    }

    pub fn remove(self: *ConcreteTextValue, index: usize) Error!void {
        try self.removeRange(index, 1);
    }

    /// Removes native units without allocation, clamping at the end. An index
    /// at or beyond the end and a zero length are no-ops.
    pub fn removeRange(self: *ConcreteTextValue, index: usize, length: usize) Error!void {
        if (index >= self.len()) return;
        const count = @min(length, self.len() - index);
        switch (self.units) {
            inline else => |*tree, tag| {
                for (0..count) |_| {
                    const removed = tree.remove(index) catch unreachable;
                    if (tag == .grapheme_cluster) self.gpa.free(removed);
                }
            },
        }
    }

    pub fn dup(self: ConcreteTextValue, gpa: Allocator) Error!ConcreteTextValue {
        var out = try init(gpa, "", self.encoding());
        errdefer out.deinit();
        try out.spliceTextValue(0, &self);
        return out;
    }

    pub fn eql(a: ConcreteTextValue, b: ConcreteTextValue) bool {
        if (a.encoding() != b.encoding() or a.len() != b.len()) return false;
        switch (a.units) {
            inline else => |*tree, tag| {
                const other = &@field(b.units, @tagName(tag));
                var it = tree.iter();
                var index: usize = 0;
                while (it.next()) |v| : (index += 1) {
                    const rhs = other.get(index).?.*;
                    if (tag == .grapheme_cluster) {
                        if (!std.mem.eql(u8, v.*, rhs)) return false;
                    } else if (v.* != rhs) return false;
                }
            },
        }
        return true;
    }

    fn appendCodepoint(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) Error!void {
        var bytes: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(cp, &bytes) catch unreachable;
        try out.appendSlice(gpa, bytes[0..width]);
    }

    /// Returns an independent, lossy UTF-8 rendering; caller frees it.
    pub fn makeString(self: *const ConcreteTextValue, gpa: Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        switch (self.units) {
            .grapheme_cluster => |*tree| {
                var it = tree.iter();
                while (it.next()) |s| try out.appendSlice(gpa, s.*);
            },
            .unicode_code_point => |*tree| {
                var it = tree.iter();
                while (it.next()) |cp| try appendCodepoint(&out, gpa, cp.*);
            },
            .utf16_code_unit => |*tree| {
                var i: usize = 0;
                while (i < tree.len()) : (i += 1) {
                    const unit = tree.get(i).?.*;
                    var cp: u21 = unit;
                    if (unit >= 0xd800 and unit <= 0xdbff) {
                        if (tree.get(i + 1)) |next| {
                            if (next.* >= 0xdc00 and next.* <= 0xdfff) {
                                cp = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + next.* - 0xdc00);
                                i += 1;
                            } else cp = 0xfffd;
                        } else cp = 0xfffd;
                    } else if (unit >= 0xdc00 and unit <= 0xdfff) cp = 0xfffd;
                    try appendCodepoint(&out, gpa, cp);
                }
            },
            .utf8_code_unit => |*tree| {
                var i: usize = 0;
                while (i < tree.len()) {
                    var bytes: [4]u8 = undefined;
                    bytes[0] = tree.get(i).?.*;
                    const width = std.unicode.utf8ByteSequenceLength(bytes[0]) catch {
                        try appendCodepoint(&out, gpa, 0xfffd);
                        i += 1;
                        continue;
                    };
                    var available: usize = 1;
                    while (available < width and i + available < tree.len()) : (available += 1) {
                        const byte = tree.get(i + available).?.*;
                        if (byte & 0xc0 != 0x80) break;
                        if (available == 1 and ((bytes[0] == 0xe0 and byte < 0xa0) or
                            (bytes[0] == 0xed and byte >= 0xa0) or
                            (bytes[0] == 0xf0 and byte < 0x90) or
                            (bytes[0] == 0xf4 and byte >= 0x90))) break;
                        bytes[available] = byte;
                    }
                    if (available == width) {
                        _ = std.unicode.utf8Decode(bytes[0..width]) catch {
                            try appendCodepoint(&out, gpa, 0xfffd);
                            i += 1;
                            continue;
                        };
                        try out.appendSlice(gpa, bytes[0..width]);
                    } else try appendCodepoint(&out, gpa, 0xfffd);
                    i += available;
                }
            },
        }
        return out.toOwnedSlice(gpa);
    }
};

// ── MarkRuns ────────────────────────────────────────────────────────────────

/// One coalesced run of one mark name ([`MarkAccItem`](marks.rs):55-60`), with
/// the name **owned**.
pub const MarkRun = struct {
    /// The mark name, owned by the accumulator.
    name: []const u8,
    /// Where the run starts.
    index: usize,
    /// How many sequence positions it covers.
    len: usize,
    /// The mark value over the whole run.
    value: ScalarValue,
};

/// The marks of one object, grouped by name and coalesced into runs
/// ([`MarkAccumulator`](marks.rs):62-65`, and the `Event::Mark` payload at
/// `patch_log.rs`:107-109`).
///
/// **The port's `MarkAccumulator` is not this type and cannot be.** That type
/// (`marks.zig`:199-280`) keeps a name-sorted flat list of per-name run lists
/// and gives the same reason for it — a text object carries one entry per
/// distinct mark name, so the array stays short and every operation is an
/// `O(n)` memmove — which is why this is a flat, name-sorted list too. What
/// differs is ownership: `MarkAccumulator` borrows its names from the mark sets
/// it is fed, and a [`PatchLog`] outlives the op set those names live in.
///
/// The name-sorted order is load-bearing: `intoIter`'s output order is what
/// lands in [`PatchAction.mark`], and upstream's is a `BTreeMap`'s
/// (`marks.rs`:68-74`).
pub const MarkRuns = struct {
    /// The allocator every name and every value payload is copied with. It is
    /// retained for the accumulator's whole life and is what
    /// [`MarkRuns.deinit`] frees through, so it must outlive it.
    gpa: Allocator,
    /// The runs, sorted by name, and in insertion order within a name.
    runs: std.ArrayList(MarkRun) = .empty,

    /// An empty accumulator that stores `gpa` for its own runs. Allocates
    /// nothing.
    pub fn init(gpa: Allocator) MarkRuns {
        return .{ .gpa = gpa };
    }

    /// Frees every run: its name **and** its value's bytes, because
    /// [`MarkRuns.add`] copies both, then the runs array itself. The allocator
    /// is not released. The accumulator is `undefined` afterward and a second
    /// call is a double free.
    pub fn deinit(self: *MarkRuns) void {
        for (self.runs.items) |*run| {
            self.gpa.free(run.name);
            freeScalar(self.gpa, run.value);
        }
        self.runs.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds the marks of `other` as a run of `len` positions starting at
    /// `index` ([`MarkAccumulator::add`](marks.rs):87-102`).
    ///
    /// A run is coalesced into the previous one for the same name when the
    /// values are equal and the previous run ends exactly where this one
    /// starts, and that is the whole reason a mark read back from the document
    /// comes out as one span rather than one span per position.
    ///
    /// **Both halves of a run are copied**, so the mark set and the names it
    /// points at may be released as soon as this returns — the log outlives the
    /// op set the names live in, which is why this type exists beside
    /// [`MarkAccumulator`](marks.zig). The copies are released together by
    /// [`MarkRuns.deinit`]; on `error.OutOfMemory` neither half of the run
    /// being built is kept, and the runs already inserted stay.
    pub fn add(self: *MarkRuns, index: usize, len: usize, other: *const MarkSet) Error!void {
        for (other.entries.items) |entry| {
            const at = self.lowerBound(entry.name);
            if (at > 0) {
                const prev = &self.runs.items[at - 1];
                if (std.mem.eql(u8, prev.name, entry.name) and
                    prev.value.eql(entry.value) and
                    prev.index + prev.len == index)
                {
                    prev.len += len;
                    continue;
                }
            }
            // **Both copies are made before the insert, and each is released
            // if the next one or the insert fails.** Built inside the struct
            // literal, the first one has no owner until the insert lands.
            const owned_name = try self.gpa.dupe(u8, entry.name);
            errdefer self.gpa.free(owned_name);
            const owned_value = try ownScalar(self.gpa, entry.value);
            errdefer freeScalar(self.gpa, owned_value);
            try self.runs.insert(self.gpa, at, .{
                .name = owned_name,
                .index = index,
                .len = len,
                .value = owned_value,
            });
        }
    }

    /// The runs as marks, name-sorted, unmark tombstones **included**
    /// ([`MarkAccumulator::into_iter`](marks.rs):68-74`). The iterator borrows.
    pub fn intoIter(self: *const MarkRuns) MarkRunsIter {
        return .{ .runs = self.runs.items };
    }

    /// Whether there is nothing to emit, which is what
    /// [`PatchBuilder.mark`] tests before it opens a patch
    /// (`patch_builder.rs`:338`).
    pub fn isEmpty(self: *const MarkRuns) bool {
        return self.runs.items.len == 0;
    }

    /// The first index whose name does not sort before `name`, which is the
    /// slot `BTreeMap::entry` would hand back (`marks.rs`:89`).
    fn lowerBound(self: *const MarkRuns, name: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.runs.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.runs.items[mid].name, name) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
};

/// The iterator over a [`MarkRuns`] (`marks.rs`:68-74). Upstream spells it as a
/// `flat_map` over a `BTreeMap`; the single cursor is this file's equivalent
/// and **it allocates nothing to be constructed**.
pub const MarkRunsIter = struct {
    runs: []const MarkRun,
    index: usize = 0,

    /// The next run as a `Mark`, or `null` at the end.
    ///
    /// **The `Mark` borrows twice**: its `name` is the run's own copy, and a
    /// `str`, `bytes`, `actor_id` or `unknown` value carries a payload that
    /// belongs to the run as well. Both die with [`MarkRuns.deinit`], so a
    /// caller that keeps the `Mark` past that call reads freed bytes.
    pub fn next(self: *MarkRunsIter) ?Mark {
        if (self.index >= self.runs.len) return null;
        const at = self.index;
        self.index += 1;
        const run = self.runs[at];
        return Mark.init(run.name, run.value, run.index, run.index + run.len);
    }
};

// ── Patch and PatchAction ───────────────────────────────────────────────────

/// One step of a path: the object the step leaves, and the property it uses to
/// reach the next. Upstream's `Vec<(ObjId, Prop)>` ([`patch.rs`](patch.rs):21`)
/// is a vector of these.
pub const PathElem = struct {
    /// The object the step leaves.
    obj: ExId,
    /// The property of that object the next object sits at.
    prop: Prop,
};

/// A change to the current state of the document ([`Patch`](patch.rs):17-24`).
///
/// **Every slice a patch names — `path`, a `key`, spliced text, a mark name, a
/// scalar payload — is allocated in the [`Patches`] that produced it, and none
/// of them is freed on its own.** See the module doc's lifetime section.
pub const Patch = struct {
    /// The object this patch modifies
    obj: ExId,
    /// The path to the property in the parent object where this object lives
    path: []const PathElem,
    /// The change this patch represents
    action: PatchAction,

    /// Whether this patch is about `obj`, or — when `recursive` — about
    /// something inside it ([`Patch::has`](patch.rs):27-29`).
    pub fn has(self: Patch, obj: ExId, recursive: bool) bool {
        if (self.obj.eql(obj)) return true;
        if (!recursive) return false;
        for (self.path) |step| {
            if (step.obj.eql(obj)) return true;
        }
        return false;
    }
};

/// One value inside an [`PatchAction.insert`]: upstream's
/// `(Value<'static>, ObjId, bool)` triple ([`patch.rs`](patch.rs):61`).
pub const InsertValue = struct {
    /// The value put in. A `str`, `bytes`, `actor_id` or `unknown` payload is
    /// **borrowed from the [`Patches`] arena** the patch lives in, like every
    /// other byte a patch names; see the module doc.
    value: Value,
    /// **Meaningful only for a `Value::Object`** (`patch.rs`:60`).
    obj: ExId,
    conflict: bool,
};

/// The values one insert action put in, in sequence order
/// ([`PatchAction::Insert::values`](patch.rs):61`).
pub const InsertValues = seqtree.SequenceTree(InsertValue);

/// The change a [`Patch`] represents ([`PatchAction`](patch.rs):33-89`), **nine**
/// variants.
pub const PatchAction = union(enum) {
    /// A key was created or updated in a map ([`patch.rs`](patch.rs):35-44`).
    put_map: struct {
        key: []const u8,
        /// The value that was put, and the object id of the object that was
        /// put. **The object id is only meaningful for a `Value::Object`**
        /// (`patch.rs`:37-39`).
        value: Value,
        obj: ExId,
        /// Whether there is a conflict at this key. If there is, this patch is
        /// the conflict's **winning** value (`patch.rs`:40-42`).
        conflict: bool,
    },
    /// An index in a sequence was updated ([`patch.rs`](patch.rs):46-55`).
    put_seq: struct {
        index: usize,
        value: Value,
        obj: ExId,
        conflict: bool,
    },
    /// One or more elements were inserted into a sequence
    /// ([`patch.rs`](patch.rs):57-62`).
    insert: struct {
        index: usize,
        /// The values that were inserted, in the order they appear.
        values: InsertValues,
    },
    /// Some text was spliced into a text object ([`patch.rs`](patch.rs):64-70`).
    splice_text: struct {
        index: usize,
        /// The text that was inserted.
        value: ConcreteTextValue,
        /// All marks currently active for this span of text, or null.
        marks: ?MarkSet,
    },
    /// A counter was incremented ([`patch.rs`](patch.rs):72-77`).
    increment: struct {
        /// The property of the counter that was incremented within the target
        /// object.
        prop: Prop,
        /// The amount incremented; **may be negative**.
        value: i64,
    },
    /// A new conflict has appeared ([`patch.rs`](patch.rs):79-82`).
    conflict: struct {
        /// The conflicted property.
        prop: Prop,
    },
    /// A key was deleted from a map ([`patch.rs`](patch.rs):84`).
    delete_map: struct {
        key: []const u8,
    },
    /// One or more indices were removed from a sequence
    /// ([`patch.rs`](patch.rs):86`).
    delete_seq: struct {
        index: usize,
        length: usize,
    },
    /// Some marks within a text object were added or removed
    /// ([`patch.rs`](patch.rs):88`).
    mark: struct {
        marks: []Mark,
    },

    /// Two actions, by content. Upstream derives `PartialEq` on `PatchAction`
    /// (`patch.rs`:32`); the port spells it out because the payloads are slices.
    pub fn eql(a: PatchAction, b: PatchAction) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .put_map => |x| std.mem.eql(u8, x.key, b.put_map.key) and
                x.value.eql(b.put_map.value) and x.obj.eql(b.put_map.obj) and
                x.conflict == b.put_map.conflict,
            .put_seq => |x| x.index == b.put_seq.index and x.value.eql(b.put_seq.value) and
                x.obj.eql(b.put_seq.obj) and x.conflict == b.put_seq.conflict,
            .insert => |x| blk: {
                if (x.index != b.insert.index) break :blk false;
                if (x.values.len() != b.insert.values.len()) break :blk false;
                var xi = x.values.iter();
                var bi = b.insert.values.iter();
                while (xi.next()) |xv| {
                    const bv = bi.next().?;
                    if (!xv.value.eql(bv.value)) break :blk false;
                    if (!xv.obj.eql(bv.obj) or xv.conflict != bv.conflict) break :blk false;
                }
                break :blk true;
            },
            .splice_text => |x| x.index == b.splice_text.index and
                x.value.eql(b.splice_text.value) and
                // **A `MarkSet` payload is a value here and not a pointer**
                // (`PatchAction.splice_text.marks` is `?MarkSet`), and
                // `markSetEql` compares by pointer so that a `null` on one
                // side and an empty set on the other are different — which is
                // upstream's `Option<MarkSet>` (`patch.rs:64-70`). The `|*m|`
                // is what borrows each without copying the set.
                markSetEql(
                    if (x.marks) |*m| m else null,
                    if (b.splice_text.marks) |*m| m else null,
                ),
            .increment => |x| x.prop.eql(b.increment.prop) and x.value == b.increment.value,
            .conflict => |x| x.prop.eql(b.conflict.prop),
            .delete_map => |x| std.mem.eql(u8, x.key, b.delete_map.key),
            .delete_seq => |x| x.index == b.delete_seq.index and x.length == b.delete_seq.length,
            .mark => |x| blk: {
                if (x.marks.len != b.mark.marks.len) break :blk false;
                for (x.marks, b.mark.marks) |xm, bm| {
                    if (xm.start != bm.start or xm.end != bm.end) break :blk false;
                    if (!std.mem.eql(u8, xm.name, bm.name)) break :blk false;
                    if (!xm.value.eql(bm.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Every field of the action, written into `out`.
    ///
    /// Upstream's `Display for PatchAction` is literally
    /// `write!(f, "{:?}", self)` (`patch.rs`:91-93`) and a derived `Debug` is
    /// not a contract. This is the port's stand-in and it is **total** — every
    /// variant writes every one of its fields, so a test that compares the
    /// lines compares the whole action.
    pub fn format(self: PatchAction, gpa: Allocator, out: *std.ArrayList(u8)) Error!void {
        switch (self) {
            .put_map => |a| {
                try out.appendSlice(gpa, "PutMap { key: \"");
                try out.appendSlice(gpa, a.key);
                try out.appendSlice(gpa, "\", value: ");
                try printValue(gpa, out, a.value);
                try out.appendSlice(gpa, ", obj: ");
                try printExId(gpa, out, a.obj);
                try out.print(gpa, ", conflict: {} }}", .{a.conflict});
            },
            .put_seq => |a| {
                try out.print(gpa, "PutSeq {{ index: {d}, value: ", .{a.index});
                try printValue(gpa, out, a.value);
                try out.appendSlice(gpa, ", obj: ");
                try printExId(gpa, out, a.obj);
                try out.print(gpa, ", conflict: {} }}", .{a.conflict});
            },
            .insert => |a| {
                try out.print(gpa, "Insert {{ index: {d}, values: [", .{a.index});
                var it = a.values.iter();
                var n: usize = 0;
                while (it.next()) |v| : (n += 1) {
                    if (n > 0) try out.appendSlice(gpa, ", ");
                    try out.appendSlice(gpa, "{ value: ");
                    try printValue(gpa, out, v.value);
                    try out.appendSlice(gpa, ", obj: ");
                    try printExId(gpa, out, v.obj);
                    try out.print(gpa, ", conflict: {} }}", .{v.conflict});
                }
                try out.appendSlice(gpa, "] }");
            },
            .splice_text => |a| {
                const rendered = try a.value.makeString(gpa);
                defer gpa.free(rendered);
                try out.print(gpa, "SpliceText {{ index: {d}, value: \"{s}\", marks: ", .{
                    a.index, rendered,
                });
                if (a.marks) |m| {
                    try out.appendSlice(gpa, "{");
                    for (m.entries.items, 0..) |e, i| {
                        if (i > 0) try out.appendSlice(gpa, ", ");
                        try out.appendSlice(gpa, e.name);
                        try out.appendSlice(gpa, "=");
                        try printScalar(gpa, out, e.value);
                    }
                    try out.appendSlice(gpa, "}");
                } else {
                    try out.appendSlice(gpa, "none");
                }
                try out.appendSlice(gpa, " }");
            },
            .increment => |a| {
                try out.appendSlice(gpa, "Increment { prop: ");
                try printProp(gpa, out, a.prop);
                try out.print(gpa, ", value: {d} }}", .{a.value});
            },
            .conflict => |a| {
                try out.appendSlice(gpa, "Conflict { prop: ");
                try printProp(gpa, out, a.prop);
                try out.appendSlice(gpa, " }");
            },
            .delete_map => |a| {
                try out.appendSlice(gpa, "DeleteMap { key: \"");
                try out.appendSlice(gpa, a.key);
                try out.appendSlice(gpa, "\" }");
            },
            .delete_seq => |a| {
                try out.print(gpa, "DeleteSeq {{ index: {d}, length: {d} }}", .{
                    a.index, a.length,
                });
            },
            .mark => |a| {
                try out.appendSlice(gpa, "Mark { marks: [");
                for (a.marks, 0..) |m, i| {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    try out.print(gpa, "{{ name: \"{s}\", value: ", .{m.name});
                    try printScalar(gpa, out, m.value);
                    try out.print(gpa, ", start: {d}, end: {d} }}", .{ m.start, m.end });
                }
                try out.appendSlice(gpa, "] }");
            },
        }
    }
};

/// A patch as one line: the object, the whole path, and the whole action
/// ([`Patch`](patch.rs):17-24, all three fields). The caller owns the result.
pub fn formatPatch(gpa: Allocator, patch: Patch) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try printExId(gpa, &out, patch.obj);
    try out.appendSlice(gpa, " path=[");
    for (patch.path, 0..) |step, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try printExId(gpa, &out, step.obj);
        try out.append(gpa, '.');
        try printProp(gpa, &out, step.prop);
    }
    try out.appendSlice(gpa, "] ");
    try patch.action.format(gpa, &out);
    return out.toOwnedSlice(gpa);
}

fn printProp(gpa: Allocator, out: *std.ArrayList(u8), prop: Prop) Error!void {
    switch (prop) {
        .key => |k| {
            try out.appendSlice(gpa, "Map(\"");
            try out.appendSlice(gpa, k);
            try out.appendSlice(gpa, "\")");
        },
        .index => |i| try out.print(gpa, "Seq({d})", .{i}),
    }
}

fn printExId(gpa: Allocator, out: *std.ArrayList(u8), id: ExId) Error!void {
    switch (id) {
        .root => try out.appendSlice(gpa, "root"),
        .id => |op| try out.print(gpa, "{d}@{d}", .{ op.counter, op.actor }),
        .named => |named| try out.print(gpa, "{d}@{d}", .{
            named.op.counter, named.op.actor,
        }),
    }
}

fn printValue(gpa: Allocator, out: *std.ArrayList(u8), v: Value) Error!void {
    switch (v) {
        .object => |o| try out.print(gpa, "Object({s})", .{@tagName(o)}),
        .scalar => |s| switch (s) {
            .str => |t| try out.print(gpa, "Str(\"{s}\")", .{t}),
            .bytes => |t| try out.print(gpa, "Bytes({d})", .{t.len}),
            .actor_id => |a| try out.print(gpa, "ActorId(\"{s}\")", .{a.bytes}),
            .int => |i| try out.print(gpa, "Int({d})", .{i}),
            .uint => |u| try out.print(gpa, "Uint({d})", .{u}),
            .float => |f| try out.print(gpa, "Float({d})", .{f}),
            .bool_value => |b| try out.print(gpa, "Bool({})", .{b}),
            .counter => |c| try out.print(gpa, "Counter({d})", .{c.current}),
            .timestamp => |t| try out.print(gpa, "Timestamp({d})", .{t}),
            .null_value => try out.appendSlice(gpa, "Null"),
            .unknown => |u| try out.print(gpa, "Unknown({d}, {d} bytes)", .{
                u.type_code, u.bytes.len,
            }),
        },
    }
}

fn printScalar(gpa: Allocator, out: *std.ArrayList(u8), s: ScalarValue) Error!void {
    try printValue(gpa, out, .{ .scalar = s });
}

/// Two optional mark sets, by content.
///
/// **This is the comparison [`PatchBuilder.spliceText`] coalesces on**, and it
/// is content equality, not pointer equality: upstream's field is
/// `Option<Arc<MarkSet>>` and `Arc<T>: PartialEq` is `**self == **other`
/// (`patch_builder.rs`:218`). The struct's own comment calls it "a quick
/// pointer equality test" (`patch_builder.rs`:18`), which the derived impl does
/// not do — and the behaviour that follows is upstream's: two adjacent splices
/// carrying the same marks merge into one patch.
///
/// The comparison itself is [`MarkSet.eql`](marks.zig), which is where the
/// derived `PartialEq` over the map belongs; this is the `Option` around it.
pub fn markSetEql(a: ?*const MarkSet, b: ?*const MarkSet) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.eql(y);
}

// ── Patches ─────────────────────────────────────────────────────────────────

test "Patches clone owns native text and named actor bytes independently" {
    const gpa = testing.allocator;
    var source = Patches.init(gpa);
    defer source.deinit();
    const id = ExId.withActor(OpId.init(1, 0), ActorId.init("actor"));
    var marks = MarkSet.init(gpa);
    defer marks.deinit();
    try marks.put("bold", .{ .str = "strong" });
    const text = try ConcreteTextValue.init(source.arena.child_allocator, "a", .grapheme_cluster);
    try source.items.append(source.allocator(), .{
        .obj = try ownExId(source.allocator(), id),
        .path = &.{},
        .action = .{ .splice_text = .{
            .index = 0,
            .value = text,
            .marks = try copyMarkSet(source.allocator(), &marks),
        } },
    });
    var cloned = try source.clone(gpa);
    defer cloned.deinit();
    source.clear();
    try testing.expect(ExId.eql(id, cloned.slice()[0].obj));
    const cloned_marks = cloned.slice()[0].action.splice_text.marks.?;
    try testing.expectEqualStrings("bold", cloned_marks.entries.items[0].name);
    try testing.expectEqualStrings("strong", cloned_marks.entries.items[0].value.str);
    try cloned.items.items[0].action.splice_text.value.splice(1, "\u{301}");
    try testing.expectEqual(@as(usize, 2), cloned.slice()[0].action.splice_text.value.len());
    const rendered = try cloned.slice()[0].action.splice_text.value.makeString(gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("a\u{301}", rendered);
}

test "Patches append and checkpoint allocation failures release native trees" {
    try testing.checkAllAllocationFailures(testing.allocator, patchesCopyAllocationFailure, .{false});
    try testing.checkAllAllocationFailures(testing.allocator, patchesCopyAllocationFailure, .{true});
}

fn patchesCopyAllocationFailure(gpa: Allocator, checkpoint: bool) !void {
    var source = Patches.init(testing.allocator);
    defer source.deinit();
    var marks = MarkSet.init(testing.allocator);
    defer marks.deinit();
    try marks.put("bold", .{ .str = "strong" });
    try source.items.ensureTotalCapacity(source.allocator(), 2);
    for (0..2) |_| {
        const text = try ConcreteTextValue.init(source.arena.child_allocator, "abcdef", .utf16_code_unit);
        source.items.appendAssumeCapacity(.{
            .obj = .root,
            .path = &.{},
            .action = .{ .splice_text = .{
                .index = 0,
                .value = text,
                .marks = try copyMarkSet(source.allocator(), &marks),
            } },
        });
    }
    var target = Patches.init(gpa);
    defer target.deinit();
    try target.items.append(target.allocator(), .{
        .obj = .root,
        .path = &.{},
        .action = .{ .delete_seq = .{ .index = 3, .length = 1 } },
    });
    if (checkpoint) {
        target.checkpointFrom(&source) catch |failure| {
            try testing.expectEqual(@as(usize, 1), target.len());
            try testing.expectEqual(@as(usize, 3), target.slice()[0].action.delete_seq.index);
            return failure;
        };
        try testing.expectEqual(@as(usize, 2), target.len());
    } else {
        target.appendFrom(&source) catch |failure| {
            try testing.expectEqual(@as(usize, 1), target.len());
            return failure;
        };
        try testing.expectEqual(@as(usize, 3), target.len());
    }
    target.clear();
    try testing.expectEqual(@as(usize, 0), target.len());
}

/// An ordered list of patches, and the storage every byte in it names.
///
/// Upstream's `Vec<Patch>` (`patch_log.rs`:505-509`) owns each patch's payload
/// outright. The port's op-set types borrow theirs, and a patch has to outlive
/// the next mutation of the document it came from, so the storage is an arena
/// and [`Patches.deinit`] is the one free.
pub const Patches = struct {
    /// Every byte a patch names.
    arena: std.heap.ArenaAllocator,
    /// The patches themselves, in stream order. **The list's buffer is arena
    /// memory**, so it is released by [`Patches.clear`] and
    /// [`Patches.deinit`] and is never freed on its own.
    items: std.ArrayList(Patch) = .empty,

    /// An empty batch. **Constructing one allocates nothing** — the arena takes
    /// its first block on the first `alloc` through it.
    pub fn init(gpa: Allocator) Patches {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    /// The allocator a patch's payload is copied with.
    pub fn allocator(self: *Patches) Allocator {
        return self.arena.allocator();
    }

    /// Frees every patch and every byte they name.
    ///
    /// The backing allocator given to [`Patches.init`] is not released, only
    /// the memory taken from it. The batch is `undefined` afterward and a
    /// second call is a double free.
    pub fn deinit(self: *Patches) void {
        for (self.items.items) |*patch| deinitPatchText(patch);
        self.arena.deinit();
        self.* = undefined;
    }

    /// How many patches this batch holds.
    pub fn len(self: *const Patches) usize {
        return self.items.items.len;
    }

    /// The patches, in the order a consumer applies them.
    ///
    /// **The slice borrows this batch's own array and dies with it.** It is
    /// invalidated by [`Patches.clear`] and by [`Patches.deinit`], and so is
    /// every patch, path and payload a caller reached through it.
    pub fn slice(self: *const Patches) []const Patch {
        return self.items.items;
    }

    /// Copies every patch of `other` into this batch, deep, and appends them
    /// in order.
    ///
    /// Upstream's `make_patches` **clones** `completed_patches` before
    /// extending it with the current ones (`patch_log.rs`:506-507`), and that
    /// clone is what this is: a [`PatchLog`] keeps its completed patches after
    /// [`PatchLog.makePatches`] returns, so a second call has to build a second
    /// batch.
    ///
    /// **All or nothing.** Every `copyPatch` can be refused, and a batch copied
    /// up to the refusal is a batch a retry would copy again on top of, so the
    /// list is put back where it started when any one of them fails. The
    /// capacity that reservation leaves behind is arena memory, which
    /// [`Patches.clear`] and [`Patches.deinit`] release with the rest.
    pub fn appendFrom(self: *Patches, other: *const Patches) Error!void {
        const mark = self.items.items.len;
        const count = other.items.items.len;
        errdefer {
            for (self.items.items[mark..]) |*patch| deinitPatchText(patch);
            self.items.shrinkRetainingCapacity(mark);
        }
        // Reserve before copying: a completed native tree must always have
        // a reachable owner, even if growing the patch array is refused.
        try self.items.ensureUnusedCapacity(self.allocator(), count);
        for (0..count) |i| {
            const copied = try copyPatch(self.allocator(), self.arena.child_allocator, other.items.items[i]);
            self.items.appendAssumeCapacity(copied);
        }
    }

    /// An independent batch; moving it never invalidates a text allocator.
    pub fn clone(self: *const Patches, gpa: Allocator) Error!Patches {
        var out = Patches.init(gpa);
        errdefer out.deinit();
        try out.appendFrom(self);
        return out;
    }

    /// Replaces this batch only after the full independent copy succeeds.
    pub fn checkpointFrom(self: *Patches, other: *const Patches) Error!void {
        var checkpoint = try other.clone(self.arena.child_allocator);
        std.mem.swap(Patches, self, &checkpoint);
        checkpoint.deinit();
    }

    /// Drops every patch, explicitly releasing native text trees before the
    /// arena frees paths, scalar payloads, marks and the patch array.
    pub fn clear(self: *Patches) void {
        for (self.items.items) |*patch| deinitPatchText(patch);
        self.items = .empty;
        _ = self.arena.reset(.free_all);
    }
};

/// Copies arena payloads separately from native text trees. `text_gpa` must
/// remain valid when the owning batch moves; never pass its arena allocator.
fn copyPatch(gpa: Allocator, text_gpa: Allocator, p: Patch) Error!Patch {
    const obj = try ownExId(gpa, p.obj);
    var path: std.ArrayList(PathElem) = .empty;
    for (p.path) |step| {
        try path.append(gpa, .{
            .obj = try ownExId(gpa, step.obj),
            .prop = try ownProp(gpa, step.prop),
        });
    }
    const action: PatchAction = switch (p.action) {
        .put_map => |a| .{ .put_map = .{
            .key = try gpa.dupe(u8, a.key),
            .value = try copyValue(gpa, a.value),
            .obj = try ownExId(gpa, a.obj),
            .conflict = a.conflict,
        } },
        .put_seq => |a| .{ .put_seq = .{
            .index = a.index,
            .value = try copyValue(gpa, a.value),
            .obj = try ownExId(gpa, a.obj),
            .conflict = a.conflict,
        } },
        .insert => |a| blk: {
            var values: InsertValues = .init(gpa);
            errdefer values.deinit();
            var it = a.values.iter();
            while (it.next()) |v| {
                try values.push(.{
                    .value = try copyValue(gpa, v.value),
                    .obj = try ownExId(gpa, v.obj),
                    .conflict = v.conflict,
                });
            }
            break :blk .{ .insert = .{ .index = a.index, .values = values } };
        },
        .splice_text => |a| blk: {
            var text = try a.value.dup(text_gpa);
            errdefer text.deinit();
            const marks = if (a.marks) |m| try copyMarkSet(gpa, &m) else null;
            break :blk .{ .splice_text = .{
                .index = a.index,
                .value = text,
                .marks = marks,
            } };
        },
        .increment => |a| .{ .increment = .{
            .prop = try ownProp(gpa, a.prop),
            .value = a.value,
        } },
        .conflict => |a| .{ .conflict = .{ .prop = try ownProp(gpa, a.prop) } },
        .delete_map => |a| .{ .delete_map = .{ .key = try gpa.dupe(u8, a.key) } },
        .delete_seq => |a| .{ .delete_seq = .{ .index = a.index, .length = a.length } },
        .mark => |a| blk: {
            const marks = try gpa.alloc(Mark, a.marks.len);
            for (a.marks, 0..) |m, i| {
                marks[i] = Mark.init(try gpa.dupe(u8, m.name), try ownScalar(gpa, m.value), m.start, m.end);
            }
            break :blk .{ .mark = .{ .marks = marks } };
        },
    };
    return .{ .obj = obj, .path = path.items, .action = action };
}

fn deinitPatchText(patch: *Patch) void {
    switch (patch.action) {
        .splice_text => |*action| action.value.deinit(),
        else => {},
    }
}

fn ownExId(gpa: Allocator, id: ExId) Error!ExId {
    return id.dup(gpa);
}

// ── Owning the payload ──────────────────────────────────────────────────────

/// A copy of `v` whose byte payloads `gpa` owns.
///
/// This is the single place the "copy what you keep" rule is applied, and both
/// directions use it: a [`PatchLog`] copies out of the op set on the way in,
/// and [`copyPatch`] copies out of a log into a [`Patches`] arena on the way
/// out.
fn ownScalar(gpa: Allocator, v: ScalarValue) Error!ScalarValue {
    return v.dup(gpa);
}

/// Frees the byte payload [`ownScalar`] allocated, and nothing else.
fn freeScalar(gpa: Allocator, v: ScalarValue) void {
    var owned = v;
    owned.deinitOwned(gpa);
}

/// A copy of a borrowed [`batch.PatchValue`] as an owned [`Value`]: the inside
/// of a [`PatchLog`], on the way in.
fn ownValue(gpa: Allocator, v: PatchValue) Error!Value {
    return switch (v) {
        .scalar => |s| .{ .scalar = try ownScalar(gpa, s) },
        .object => |o| .{ .object = o },
    };
}

/// A copy of a [`Value`] whose byte payloads `gpa` owns: the inside of a patch,
/// copied again by [`copyPatch`].
fn copyValue(gpa: Allocator, v: Value) Error!Value {
    return switch (v) {
        .scalar => |s| .{ .scalar = try ownScalar(gpa, s) },
        .object => |o| .{ .object = o },
    };
}

fn freeValue(gpa: Allocator, v: Value) void {
    switch (v) {
        .scalar => |s| freeScalar(gpa, s),
        .object => {},
    }
}

fn ownProp(gpa: Allocator, prop: Prop) Error!Prop {
    return switch (prop) {
        .key => |k| .{ .key = try gpa.dupe(u8, k) },
        .index => |i| .{ .index = i },
    };
}

/// Deep independent mark ownership, including scalar byte payloads.
fn copyMarkSet(gpa: Allocator, m: *const MarkSet) Error!MarkSet {
    return m.dup(gpa);
}

/// Releases a mark set obtained through `copyMarkSet`.
fn freeMarkSet(gpa: Allocator, m: *MarkSet) void {
    _ = gpa;
    m.deinit();
}

// ── Event ───────────────────────────────────────────────────────────────────

/// One mutation a merge logged, tagged with the object it happened to
/// ([`Event`](patch_log.rs):59-110`), **eleven** variants.
///
/// **Every slice an event names is owned by the log that holds it** and is
/// freed by [`PatchLog.deinit`] or by [`Event.deinit`]. The sink methods build
/// events that already own their payload; a caller that builds one by hand takes
/// the same responsibility.
pub const Event = union(enum) {
    /// ([`patch_log.rs`](patch_log.rs):61-66`)
    put_map: struct { key: []const u8, value: Value, id: OpId, conflict: bool },
    /// ([`patch_log.rs`](patch_log.rs):67-72`)
    put_seq: struct { index: usize, value: Value, id: OpId, conflict: bool },
    /// ([`patch_log.rs`](patch_log.rs):73-76`)
    delete_seq: struct { index: usize, num: usize },
    /// ([`patch_log.rs`](patch_log.rs):77-79`)
    delete_map: struct { key: []const u8 },
    /// ([`patch_log.rs`](patch_log.rs):80-84`)
    splice: struct { index: usize, text: []const u8, marks: ?MarkSet },
    /// ([`patch_log.rs`](patch_log.rs):85-90`)
    insert: struct { index: usize, value: Value, id: OpId, conflict: bool },
    /// ([`patch_log.rs`](patch_log.rs):91-95`)
    increment_map: struct { key: []const u8, n: i64, id: OpId },
    /// ([`patch_log.rs`](patch_log.rs):96-100`)
    increment_seq: struct { index: usize, n: i64, id: OpId },
    /// ([`patch_log.rs`](patch_log.rs):101-103`)
    flag_conflict_map: struct { key: []const u8 },
    /// ([`patch_log.rs`](patch_log.rs):104-106`)
    flag_conflict_seq: struct { index: usize },
    /// ([`patch_log.rs`](patch_log.rs):107-109`)
    mark: struct { marks: MarkRuns },

    /// Frees the event's payload.
    pub fn deinit(self: *Event, gpa: Allocator) void {
        switch (self.*) {
            .put_map => |e| {
                gpa.free(e.key);
                freeValue(gpa, e.value);
            },
            .put_seq => |e| freeValue(gpa, e.value),
            .delete_seq, .flag_conflict_seq, .increment_seq => {},
            .delete_map => |e| gpa.free(e.key),
            .splice => |e| {
                gpa.free(e.text);
                if (e.marks) |m| {
                    // A local, because the capture is const and `deinit` is
                    // not: it frees the buffer and poisons the struct, and the
                    // event itself is discarded on the next line anyway.
                    var owned = m;
                    freeMarkSet(gpa, &owned);
                }
            },
            .insert => |e| freeValue(gpa, e.value),
            .increment_map => |e| gpa.free(e.key),
            .flag_conflict_map => |e| gpa.free(e.key),
            .mark => |e| {
                // A local, for the same reason as the splice's mark set: the
                // capture is const and `deinit` is not.
                var runs = e.marks;
                runs.deinit();
            },
        }
        self.* = undefined;
    }

    /// This event with its op id re-indexed for an actor inserted at `idx`
    /// ([`Event::with_new_actor`](patch_log.rs):113-160`).
    ///
    /// Only the five variants that carry an op id change; the other six come
    /// back as they are, which is upstream's `event => event` arm
    /// (`patch_log.rs`:158`).
    fn withNewActor(ev: Event, idx: ActorIdx) Event {
        return switch (ev) {
            .put_map => |e| .{ .put_map = .{
                .key = e.key,
                .value = e.value,
                .id = e.id.withNewActor(idx),
                .conflict = e.conflict,
            } },
            .put_seq => |e| .{ .put_seq = .{
                .index = e.index,
                .value = e.value,
                .id = e.id.withNewActor(idx),
                .conflict = e.conflict,
            } },
            .insert => |e| .{ .insert = .{
                .index = e.index,
                .value = e.value,
                .id = e.id.withNewActor(idx),
                .conflict = e.conflict,
            } },
            .increment_map => |e| .{ .increment_map = .{
                .key = e.key,
                .n = e.n,
                .id = e.id.withNewActor(idx),
            } },
            .increment_seq => |e| .{ .increment_seq = .{
                .index = e.index,
                .n = e.n,
                .id = e.id.withNewActor(idx),
            } },
            else => ev,
        };
    }

    /// This event with its op id re-indexed for an actor removed at `idx`, or
    /// null when the event **is** that actor's
    /// ([`Event::without_actor`](patch_log.rs):167-214`).
    ///
    /// `?` and not a wrong answer: the caller drops the event, because an
    /// operation that named the removed actor cannot exist.
    fn withoutActor(ev: Event, idx: ActorIdx) ?Event {
        return switch (ev) {
            .put_map => |e| .{ .put_map = .{
                .key = e.key,
                .value = e.value,
                .id = e.id.withoutActor(idx) orelse return null,
                .conflict = e.conflict,
            } },
            .put_seq => |e| .{ .put_seq = .{
                .index = e.index,
                .value = e.value,
                .id = e.id.withoutActor(idx) orelse return null,
                .conflict = e.conflict,
            } },
            .insert => |e| .{ .insert = .{
                .index = e.index,
                .value = e.value,
                .id = e.id.withoutActor(idx) orelse return null,
                .conflict = e.conflict,
            } },
            .increment_map => |e| .{ .increment_map = .{
                .key = e.key,
                .n = e.n,
                .id = e.id.withoutActor(idx) orelse return null,
            } },
            .increment_seq => |e| .{ .increment_seq = .{
                .index = e.index,
                .n = e.n,
                .id = e.id.withoutActor(idx) orelse return null,
            } },
            else => ev,
        };
    }
};

// ── PathMap ─────────────────────────────────────────────────────────────────

/// "Where does this object live": the property of `parent` it sits at
/// ([`BTreeMap<ObjId, (Prop, ObjId)>`](patch_log.rs):49`).
pub const PathMapEntry = struct {
    /// The object being described.
    obj: ExId,
    /// The property of `parent` it sits at.
    prop: Prop,
    /// The object that holds it.
    parent: ExId,
};

/// The map itself: a flat array sorted by `obj`.
///
/// Upstream's is a `BTreeMap` and so is the order this keeps. **The map owns
/// its array and none of its keys.** [`PathMap.deinit`] frees the array alone,
/// so whoever put a `.key` entry in owns those bytes and keeps them alive for
/// as long as the map is read — see [`PatchBuilder.updatePathMap`] for the one
/// producer inside this module and [`PatchLog.pathHint`] for the one a caller
/// supplies.
pub const PathMap = struct {
    /// The entries, sorted by `obj`. **Not freed by anything but
    /// [`PathMap.deinit`]**, and its keys are not freed at all.
    items: std.ArrayList(PathMapEntry) = .empty,

    /// Releases the entries array. The keys stay where they are; see the type
    /// comment. `gpa` is the allocator the array was allocated with and is not
    /// released. The map is `undefined` afterward.
    pub fn deinit(self: *PathMap, gpa: Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }

    /// The entry for `obj`, or null. Allocates nothing.
    ///
    /// **The pointer is into this map's own array** and is invalidated by the
    /// next [`PathMap.put`] or [`PathMap.deinit`], both of which can reallocate
    /// or shift the entries.
    pub fn get(self: *const PathMap, obj: ExId) ?*const PathMapEntry {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (obj.order(self.items.items[mid].obj)) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return &self.items.items[mid],
            }
        }
        return null;
    }

    /// Inserts, or replaces the entry of an object that already has one.
    ///
    /// **`e.prop`'s key is taken as given and is not copied or freed.** The
    /// caller owns it; see the type comment. On `error.OutOfMemory` nothing is
    /// stored and the map is unchanged.
    pub fn put(self: *PathMap, gpa: Allocator, e: PathMapEntry) Error!void {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (e.obj.order(self.items.items[mid].obj)) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => {
                    self.items.items[mid] = e;
                    return;
                },
            }
        }
        try self.items.insert(gpa, lo, e);
    }
};

// ── PatchBuilder ────────────────────────────────────────────────────────────

/// Turns [`Event`]s into [`Patch`]es: resolves each patch's path, and merges
/// adjacent events that target the same object
/// ([`PatchBuilder`](patch_builder.rs):16-364`).
///
/// `D` is the document, checked by [`assertDoc`]. The builder copies every
/// byte a patch names into `out`, so a patch it produces and one a
/// [`Patches.appendFrom`] copied are shaped identically.
pub fn PatchBuilder(comptime D: type) type {
    return struct {
        const Self = @This();

        /// The batch the patches go into, and the allocator they are built
        /// with.
        out: *Patches,
        /// Arena allocator for patch payloads. Native text nodes instead use
        /// `out.arena.child_allocator`, whose address remains stable.
        gpa: Allocator,
        /// The document every path and value is read from. **Borrowed**: it
        /// must outlive the builder, and nothing is copied out of it except
        /// into the arena.
        doc: *const D,
        /// The patches built so far, in stream order. **This is the builder's
        /// output**: [`PatchLog.buildCurrent`] appends it to the batch in
        /// `out` once the walk is done. Its buffer is `gpa` memory, so it is
        /// never freed on its own.
        patches: std.ArrayList(Patch) = .empty,
        /// The mark set of the last splice, kept for the coalescing test
        /// (`patch_builder.rs`:18`); see [`markSetEql`] for what the comparison
        /// is. **A shallow copy of the set struct**: its buffer is arena
        /// memory, so it stays valid for as long as the patches do, and this
        /// field is never freed.
        last_mark_set: ?MarkSet = null,
        /// The mark runs of the **tail** mark patch, in the array they are
        /// built in. Arena memory like [`patches`](Self.patches), so it is
        /// never freed on its own; what it is for is a **capacity that
        /// survives from one event to the next**, which is the whole of what
        /// [`appendMarks`](Self.appendMarks) is about.
        ///
        /// **Reset to an empty array whenever a new mark patch opens, and the
        /// capacity is dropped with it.** A mark patch that is no longer the
        /// tail keeps its own `marks` slice, and retaining the capacity here
        /// would hand the next patch the very buffer that slice names. The
        /// old array is arena memory and needs no free.
        mark_scratch: std.ArrayList(Mark) = .empty,
        /// The cache `init` was handed, **taken over rather than copied**
        /// (`patch_builder.rs`:19`).
        ///
        /// **Its array belongs to `path_map_gpa` and nothing else.** Every
        /// growth here goes through that allocator and `deinit` frees it
        /// through the same one, because a growing `std.ArrayList` releases
        /// the buffer it replaces through whichever allocator was passed
        /// alongside it — a map that mixed two would free one of them wrongly.
        /// The **keys are the exception and deliberately are not routed with
        /// it**: a [`PathMap`] frees no keys, so a key copied into `gpa`'s
        /// arena is reclaimed by [`Patches.deinit`] with no free of its own.
        path_map: PathMap,
        /// The allocator `path_map`'s array was allocated with, retained for
        /// this builder's whole life so it must outlive it. **Not `gpa`.** It
        /// is whatever the caller that handed the map over built it with —
        /// for a [`PatchLog`], its own.
        path_map_gpa: Allocator,
        /// The objects whose parent has already been walked, and the cycle
        /// guard (`patch_builder.rs`:20`, `:152-155`).
        seen: std.HashMapUnmanaged(ExId, void, ExIdContext, 64) = .empty,
        /// The encoding every text length in a patch is counted in, read once
        /// from the document (`patch_builder.rs`:26). Copied, so it does not
        /// borrow from `doc`.
        text_encoding: TextEncoding,
        /// `null` for the current heads, and a clock for an earlier view
        /// (`patch_builder.rs`:22`).
        clock: ?Clock,

        /// A builder over `out` ([`PatchBuilder::new`](patch_builder.rs):27-45`).
        ///
        /// **`owned_seed` is taken over, not copied, and `seed_gpa` must be the
        /// allocator its array was built with.** The builder adopts the map
        /// and every growth of it goes through `seed_gpa`, because a growing
        /// `std.ArrayList` releases the buffer it replaces through whichever
        /// allocator was passed alongside it: a map behind two allocators
        /// frees one of them wrongly, and Zig 0.16's `ArenaAllocator.free`
        /// silently returns for a block it never handed out. Nothing is
        /// copied, so `init` cannot fail and this is not an error union.
        ///
        /// **The map's keys are the other half of the ledger.** A
        /// [`PathMap`] frees no keys at all, so the keys this builder copies
        /// in [`updatePathMap`] go into `gpa`'s arena and are reclaimed by
        /// [`Patches.deinit`] with no free of their own — while keys that came
        /// in with the seed stay the seed's owner's business for as long as
        /// they are read.
        pub fn init(
            out: *Patches,
            doc: *const D,
            owned_seed: PathMap,
            seed_gpa: Allocator,
            clock: ?Clock,
            text_encoding: TextEncoding,
        ) Self {
            return .{
                .out = out,
                .gpa = out.allocator(),
                .doc = doc,
                .path_map = owned_seed,
                .path_map_gpa = seed_gpa,
                .clock = clock,
                .text_encoding = text_encoding,
            };
        }

        /// Frees the path map with **`path_map_gpa`**, the allocator its array
        /// came from, and the cycle guard with `gpa`, the arena that holds it.
        /// Pending text trees are released unless transferred with `takePatches`.
        ///
        /// The map was **transferred in**, not borrowed, so the caller must not
        /// release it and has no route to after this. The builder is
        /// `undefined` afterward and a second call is a double free.
        pub fn deinit(self: *Self) void {
            for (self.patches.items) |*patch| deinitPatchText(patch);
            self.path_map.deinit(self.path_map_gpa);
            self.seen.deinit(self.gpa);
            self.* = undefined;
        }

        /// Transfers staged patches after the output has reserved room for them.
        /// The returned slice remains in the output arena; native trees now
        /// belong to the caller and are no longer released by this builder.
        pub fn takePatches(self: *Self) []Patch {
            const result = self.patches.items;
            self.patches = .empty;
            self.last_mark_set = null;
            return result;
        }

        /// One event, one call ([`PatchBuilder::log_event`](patch_builder.rs):49-110`).
        pub fn logEvent(self: *Self, doc: *const D, exid: ExId, ev: *const Event) MakeError!void {
            switch (ev.*) {
                .put_map => |e| try self.put(
                    exid,
                    .{ .key = e.key },
                    e.value,
                    try exportPatchId(D, doc, e.id),
                    e.conflict,
                ),
                .delete_map => |e| try self.deleteMap(exid, e.key),
                .increment_map => |e| try self.increment(exid, .{ .key = e.key }, e.n),
                .flag_conflict_map => |e| try self.flagConflict(exid, .{ .key = e.key }),
                .put_seq => |e| try self.put(
                    exid,
                    .{ .index = e.index },
                    e.value,
                    try exportPatchId(D, doc, e.id),
                    e.conflict,
                ),
                .insert => |e| try self.insert(
                    exid,
                    e.index,
                    e.value,
                    try exportPatchId(D, doc, e.id),
                    e.conflict,
                ),
                .delete_seq => |e| try self.deleteSeq(exid, e.index, e.num),
                .increment_seq => |e| try self.increment(exid, .{ .index = e.index }, e.n),
                .flag_conflict_seq => |e| try self.flagConflict(exid, .{ .index = e.index }),
                .splice => |e| {
                    // The event owns its set; the builder's parameter is a
                    // borrow, because upstream's is an `Arc` clone
                    // (`patch_builder.rs`:106`).
                    if (e.marks) |m| {
                        try self.spliceText(exid, e.index, e.text, &m);
                    } else {
                        try self.spliceText(exid, e.index, e.text, null);
                    }
                },
                .mark => |e| try self.mark(exid, &e.marks),
            }
        }

        /// The path from the root to `obj`, or null when its ancestry is absent
        /// ([`PatchBuilder::get_path`](patch_builder.rs):143-165`). Other document
        /// read errors propagate to the caller.
        ///
        /// **A cycle is a null, not a loop**: the `seen` set is consulted
        /// before a parent is walked a second time
        /// (`patch_builder.rs`:152-155`).
        pub fn getPath(self: *Self, obj_in: ExId) MakeError!?[]PathElem {
            var path: std.ArrayList(PathElem) = .empty;
            var cur = obj_in;
            while (!cur.isRoot()) {
                var prop: Prop = undefined;
                var parent: ExId = undefined;
                if (self.path_map.get(cur)) |found| {
                    prop = found.prop;
                    parent = found.parent;
                } else {
                    const parent_id = self.doc.objectParent(cur) orelse return null;
                    const parent_type = self.doc.objectType(parent_id) catch |e| switch (e) {
                        error.NotAnObject => return null,
                        else => return e,
                    };
                    if (self.seen.contains(cur)) return null;
                    try self.seen.put(self.gpa, try ownExId(self.gpa, cur), {});
                    try self.updatePathMap(parent_id, parent_type);
                    const found = self.path_map.get(cur) orelse return null;
                    prop = found.prop;
                    parent = found.parent;
                }
                cur = parent;
                // **A path entry is arena-owned whatever the cache holds.**
                // [`updatePathMap`] already copied the keys it found into the
                // arena, but a caller-supplied [`PathMap`] through
                // [`PatchLog.pathHint`] may hold borrowed ones, and this is the
                // one place every patch's key passes through. An index is a
                // number, and `ownProp` is the identity for it.
                try path.append(self.gpa, .{
                    .obj = try ownExId(self.gpa, try exportObj(D, self.doc, cur)),
                    .prop = try ownProp(self.gpa, prop),
                });
            }
            std.mem.reverse(PathElem, path.items);
            return path.items;
        }

        /// One or more elements inserted into a sequence
        /// ([`PatchBuilder::insert`](patch_builder.rs):171-197`).
        ///
        /// **Two kinds of allocation here, and only one of them is the
        /// tree's.** The [`InsertValues`] this writes into was built with the
        /// patch's arena, so the **nodes** it allocates come out of that arena
        /// and it takes no allocator here. The **payload** is the exception:
        /// `value` is an [`Event`]'s value, and an event's bytes are owned by
        /// the [`PatchLog`] that holds it — a **different** allocator, whose
        /// lifetime ends at [`PatchLog.deinit`], long before a consumer reads
        /// the patch. So the value is copied in, the way [`put`] copies its
        /// and [`ExposeQueue.flushObj`] copies its. Upstream has no allocator
        /// to get wrong and clones for the same reason
        /// (`patch_builder.rs`:304`).
        ///
        /// The merge arm: an insert landing inside the tail insert's range
        /// joins it at the right offset. `tail..=tail + len` is upstream's
        /// `RangeInclusive` (`patch_builder.rs`:185-186`).
        pub fn insert(
            self: *Self,
            obj: ExId,
            index: usize,
            value: Value,
            id: ExId,
            conflict: bool,
        ) MakeError!void {
            if (self.maybeAppend(obj)) |action| {
                if (action.* == .insert) {
                    const tail = action.insert.index;
                    if (index >= tail and index <= tail + action.insert.values.len()) {
                        const owned = try copyValue(self.gpa, value);
                        errdefer freeValue(self.gpa, owned);
                        try action.insert.values.insert(
                            index - tail,
                            .{ .value = owned, .obj = try ownExId(self.gpa, id), .conflict = conflict },
                        );
                        return;
                    }
                }
            }
            const path = (try self.getPath(obj)) orelse return;
            const owned = try copyValue(self.gpa, value);
            errdefer freeValue(self.gpa, owned);
            var values: InsertValues = .init(self.gpa);
            errdefer values.deinit();
            try values.push(.{ .value = owned, .obj = try ownExId(self.gpa, id), .conflict = conflict });
            try self.push(obj, path, .{ .insert = .{ .index = index, .values = values } });
        }

        /// Text spliced into a text object
        /// ([`PatchBuilder::splice_text`](patch_builder.rs):204-233`).
        ///
        /// The coalescing test is `marks == self.last_mark_set` — **content**
        /// equality, see [`markSetEql`] — and the splice must land inside the
        /// tail patch's range.
        pub fn spliceText(
            self: *Self,
            obj: ExId,
            index: usize,
            text: []const u8,
            marks: ?*const MarkSet,
        ) MakeError!void {
            // Segment incoming spans independently, preserving their native-unit
            // boundaries even when adjacent graphemes would combine as UTF-8.
            var incoming = try ConcreteTextValue.init(self.out.arena.child_allocator, text, self.text_encoding);
            var transferred = false;
            defer if (!transferred) incoming.deinit();
            if (self.maybeAppend(obj)) |action| {
                if (action.* == .splice_text) {
                    const tail = action.splice_text.index;
                    const len = action.splice_text.value.len();
                    if (index >= tail and index <= tail + len and
                        markSetEql(marks, if (self.last_mark_set) |*m| m else null))
                    {
                        try action.splice_text.value.spliceTextValue(index - tail, &incoming);
                        return;
                    }
                }
            }
            const path = (try self.getPath(obj)) orelse return;
            const owned = if (marks) |m| try copyMarkSet(self.gpa, m) else null;
            errdefer if (owned) |m| {
                var unowned = m;
                freeMarkSet(self.gpa, &unowned);
            };
            try self.push(obj, path, .{ .splice_text = .{
                .index = index,
                .value = incoming,
                .marks = owned,
            } });
            transferred = true;
            // Only a splice leaves this set; `push` clears it.
            self.last_mark_set = owned;
        }

        /// One or more indices removed from a sequence
        /// ([`PatchBuilder::delete_seq`](patch_builder.rs):235-285`).
        ///
        /// **Four arms, and the first two take elements back out of a patch
        /// this file has just built**: a delete landing inside the tail insert
        /// or the tail splice removes them, and a patch that empties is dropped
        /// rather than pushed.
        ///
        /// Text ranges count native units, including individual UTF-16
        /// surrogate halves and the grapheme boundaries stored in the tree.
        ///
        /// **`length == 0` does nothing, before any arithmetic.** Upstream's
        /// coalescing arms test `index + length - 1` (`patch_builder.rs`:243`,
        /// `:259`), which underflows at zero. A text element whose value is
        /// empty has width zero, and `PatchLog.replaceSeq` logs that width.
        /// Here the guard is explicit, and no patch is emitted.
        pub fn deleteSeq(self: *Self, obj: ExId, index: usize, length: usize) MakeError!void {
            if (length == 0) return;
            if (self.maybeAppend(obj)) |action| {
                switch (action.*) {
                    .splice_text => |*a| {
                        const tail = a.index;
                        const len = a.value.len();
                        if (index >= tail) {
                            const offset = index - tail;
                            if (offset < len and length <= len - offset) {
                                try a.value.removeRange(offset, length);
                                if (a.value.len() == 0) {
                                    a.value.deinit();
                                    _ = self.patches.pop();
                                    self.last_mark_set = null;
                                }
                                return;
                            }
                        }
                    },
                    .insert => |*a| {
                        const tail = a.index;
                        const len = a.values.len();
                        if (index >= tail and index + length - 1 < tail + len) {
                            for (0..length) |_| _ = try a.values.remove(index - tail);
                            if (a.values.len() == 0) {
                                a.values.deinit();
                                _ = self.patches.pop();
                                self.last_mark_set = null;
                            }
                            return;
                        }
                    },
                    .delete_seq => |*a| {
                        if (index == a.index) {
                            a.length += length;
                            return;
                        }
                    },
                    else => {},
                }
            }
            const path = (try self.getPath(obj)) orelse return;
            try self.push(obj, path, .{ .delete_seq = .{ .index = index, .length = length } });
        }

        /// A key removed from a map
        /// ([`PatchBuilder::delete_map`](patch_builder.rs):287-294`).
        pub fn deleteMap(self: *Self, obj: ExId, key: []const u8) MakeError!void {
            const path = (try self.getPath(obj)) orelse return;
            try self.push(obj, path, .{ .delete_map = .{ .key = try self.gpa.dupe(u8, key) } });
        }

        /// A key or an index put ([`PatchBuilder::put`](patch_builder.rs):296-319`).
        pub fn put(
            self: *Self,
            obj: ExId,
            prop: Prop,
            value: Value,
            id: ExId,
            conflict: bool,
        ) MakeError!void {
            const path = (try self.getPath(obj)) orelse return;
            const owned_prop = try ownProp(self.gpa, prop);
            const owned_value = try copyValue(self.gpa, value);
            const action: PatchAction = switch (owned_prop) {
                .key => |k| .{ .put_map = .{
                    .key = k,
                    .value = owned_value,
                    .obj = try ownExId(self.gpa, id),
                    .conflict = conflict,
                } },
                .index => |i| .{ .put_seq = .{
                    .index = i,
                    .value = owned_value,
                    .obj = try ownExId(self.gpa, id),
                    .conflict = conflict,
                } },
            };
            try self.push(obj, path, action);
        }

        /// A counter incremented
        /// ([`PatchBuilder::increment`](patch_builder.rs):321-327`).
        pub fn increment(self: *Self, obj: ExId, prop: Prop, n: i64) MakeError!void {
            const path = (try self.getPath(obj)) orelse return;
            const owned_prop = try ownProp(self.gpa, prop);
            try self.push(obj, path, .{ .increment = .{ .prop = owned_prop, .value = n } });
        }

        /// Marks added or removed ([`PatchBuilder::mark`](patch_builder.rs):329-343`).
        ///
        /// Appending to an open mark patch is unconditional — upstream pushes
        /// the runs and returns without re-testing whether there are any
        /// (`patch_builder.rs`:330-335`). The emptiness test is only on the way
        /// in, so a mark event with no runs opens no patch.
        pub fn mark(self: *Self, obj: ExId, runs: *const MarkRuns) MakeError!void {
            if (self.maybeAppend(obj)) |action| {
                if (action.* == .mark) {
                    try self.appendMarks(action, runs);
                    return;
                }
            }
            if (runs.isEmpty()) return;
            const path = (try self.getPath(obj)) orelse return;
            // **A new patch, so the scratch starts over and its capacity goes
            // with it.** The array the previous mark patch still points at is
            // arena memory and outlives this; reusing its buffer would rewrite
            // a patch that has already been built.
            self.mark_scratch = .empty;
            errdefer self.mark_scratch = .empty;
            try self.collectMarks(&self.mark_scratch, runs);
            try self.push(obj, path, .{ .mark = .{ .marks = self.mark_scratch.items } });
        }

        /// A new conflict appeared
        /// ([`PatchBuilder::flag_conflict`](patch_builder.rs):345-363`).
        ///
        /// **The first arm is not a merge: a conflict flag raised straight
        /// after the put it belongs to sets that put's `conflict` instead of
        /// opening a second patch** (`patch_builder.rs`:346-358`).
        pub fn flagConflict(self: *Self, obj: ExId, prop: Prop) MakeError!void {
            if (self.maybeAppend(obj)) |action| {
                switch (action.*) {
                    .put_map => |*a| {
                        if (prop.asStr()) |k| {
                            if (std.mem.eql(u8, a.key, k)) {
                                a.conflict = true;
                                return;
                            }
                        }
                    },
                    .put_seq => |*a| {
                        if (prop.asIndex()) |i| {
                            if (a.index == i) {
                                a.conflict = true;
                                return;
                            }
                        }
                    },
                    else => {},
                }
            }
            const path = (try self.getPath(obj)) orelse return;
            const owned_prop = try ownProp(self.gpa, prop);
            try self.push(obj, path, .{ .conflict = .{ .prop = owned_prop } });
        }

        /// Grows an open mark patch's array and adds one event's runs to it.
        ///
        /// **It appends to the array the patch already names, and that is the
        /// whole change.** It used to build a *second* array, copy every run
        /// the patch already carried into it, append the new ones and publish
        /// that — so a log coalescing `n` mark events onto one patch copied
        /// `1 + 2 + … + (n-1)` runs, which is **O(n²) in the patch's mark
        /// count**. Upstream pushes onto the `Vec` it already holds
        /// ([`patch_builder.rs`:330-335](../../github-automerge-automerge/rust/automerge/src/patches/patch_builder.rs)),
        /// so it is O(n) and this now is too.
        ///
        /// **The array can move, so the patch is re-pointed at it.** Growing a
        /// `std.ArrayList` reallocates, and a patch holds a slice rather than
        /// the list, so `action.mark.marks` is rewritten after the appends. A
        /// patch's slice is only ever read between events — the walk finishes
        /// before any caller sees the batch — so that is safe, and it is the
        /// same rule [`patches`](Self.patches) itself runs under.
        ///
        /// **A refused append leaves the patch naming what it named before**,
        /// which is what the copy bought and what is still bought here: the
        /// runs that made it in are arena memory [`Patches.deinit`] releases
        /// with everything else, and the length is put back below.
        fn appendMarks(self: *Self, action: *PatchAction, runs: *const MarkRuns) Error!void {
            var a = action;
            const was = self.mark_scratch.items.len;
            errdefer self.mark_scratch.shrinkRetainingCapacity(was);
            try self.collectMarks(&self.mark_scratch, runs);
            a.mark.marks = self.mark_scratch.items;
        }

        /// Copies every run of `runs` into `out`, **name and value**: a name
        /// is a `[]const u8` and a value can carry bytes of its own
        /// ([`ownScalar`]'s four cases). The event's copies belong to the
        /// [`PatchLog`] holding it and die at [`PatchLog.deinit`], while the
        /// patch has to outlive that, so both are copied in with the arena.
        fn collectMarks(
            self: *Self,
            out: *std.ArrayList(Mark),
            runs: *const MarkRuns,
        ) Error!void {
            var it = runs.intoIter();
            while (it.next()) |m| {
                // **Each copy is released if the next one or the append
                // refuses.** Built inline in the call, the name has no owner
                // between the `dupe` and the `append`.
                const owned_name = try self.gpa.dupe(u8, m.name);
                errdefer self.gpa.free(owned_name);
                const owned_value = try ownScalar(self.gpa, m.value);
                errdefer freeScalar(self.gpa, owned_value);
                try out.append(self.gpa, Mark.init(
                    owned_name,
                    owned_value,
                    m.start,
                    m.end,
                ));
            }
        }

        /// The action of the last patch, when it is about `obj`
        /// ([`maybe_append`](patch_builder.rs):372-381`).
        fn maybeAppend(self: *Self, obj: ExId) ?*PatchAction {
            const n = self.patches.items.len;
            if (n == 0) return null;
            const tail = &self.patches.items[n - 1];
            if (!tail.obj.eql(obj)) return null;
            return &tail.action;
        }

        /// Appends a patch and clears the mark-set cache
        /// ([`PatchBuilder::push`](patch_builder.rs):199-202`).
        fn push(self: *Self, obj: ExId, path: []PathElem, action: PatchAction) Error!void {
            try self.patches.append(self.gpa, .{ .obj = try ownExId(self.gpa, obj), .path = path, .action = action });
            self.last_mark_set = null;
        }

        /// The children of `parent_id`, as path entries
        /// ([`PatchBuilder::update_path_map`](patch_builder.rs):112-141`).
        ///
        /// **One walk per parent, not one lookup per object**, and that is what
        /// `seen` is for (`patch_builder.rs`:34-35`, `:152-155`). Only object
        /// values are recorded: a scalar has no path.
        ///
        /// **A map key is copied into the batch arena, not borrowed.** The
        /// module rule is that everything this file keeps is a copy, and a key
        /// a document walk hands out is only good until the next mutation of
        /// it. The index arms have nothing to copy: an index is a number.
        ///
        /// **The array grows with `path_map_gpa` and the keys land in `gpa`,
        /// and that asymmetry is the point.** The array is a `PathMap`'s one
        /// owned resource and must be freed by whoever allocated it; a key is
        /// owned by nobody, so the arena is a free place to leave it. The
        /// index arms write no key at all.
        fn updatePathMap(self: *Self, parent_id: ExId, parent_type: ObjType) MakeError!void {
            switch (parent_type) {
                .list => {
                    var it = self.doc.listRangeFor(parent_id, self.clock);
                    while (try it.next()) |item| {
                        if (!item.value.isObject()) continue;
                        try self.path_map.put(self.path_map_gpa, .{
                            .obj = try ownExId(self.gpa, try exportPatchId(D, self.doc, item.id)),
                            .prop = .{ .index = item.index },
                            .parent = try ownExId(self.gpa, try exportObj(D, self.doc, parent_id)),
                        });
                    }
                },
                .text => {
                    var it = self.doc.spans(parent_id, self.clock);
                    while (try it.next()) |span| {
                        switch (span) {
                            .obj => |o| try self.path_map.put(self.path_map_gpa, .{
                                .obj = try ownExId(self.gpa, try exportPatchId(D, self.doc, o.id)),
                                .prop = .{ .index = o.index },
                                .parent = try ownExId(self.gpa, try exportObj(D, self.doc, parent_id)),
                            }),
                            .text => {},
                        }
                    }
                },
                .map, .table => {
                    var it = self.doc.mapRangeFor(parent_id, self.clock);
                    while (try it.next()) |item| {
                        if (!item.value.isObject()) continue;
                        try self.path_map.put(self.path_map_gpa, .{
                            .obj = try ownExId(self.gpa, try exportPatchId(D, self.doc, item.id)),
                            // **Copied, so the entry this keeps does not name
                            // the walk's storage.** The arena releases it with
                            // the batch.
                            .prop = try ownProp(self.gpa, .{ .key = item.key }),
                            .parent = try ownExId(self.gpa, try exportObj(D, self.doc, parent_id)),
                        });
                    }
                },
            }
        }
    };
}

// ── ExposeQueue ─────────────────────────────────────────────────────────────

/// The objects whose content a patch stream must supply
/// ([`ExposeQueue`](patch_log.rs):679-779`).
///
/// **This is the whole reason the patch stream is complete.** A diff of a
/// document that gained an object emits a `PutMap` naming an object the
/// consumer has never seen created and holds no content for. Upstream records
/// the op id of every such object — a put, a sequence put, or an insert with
/// `expose` set (`patch_log.rs`:374-375`, `:397-398`, `:474-475`) — and here,
/// as the event sort reaches that id, the queue flushes the object's own
/// content first.
///
/// A flat array sorted by `ExId` where upstream has a `BTreeSet<ExId>`
/// (`patch_log.rs`:680): the only operations are `first`, `insert`, `remove`
/// and the ordered comparison in [`ExposeQueue.pumpQueue`], all of which the
/// array answers.
///
/// **No consumer of this module can build one.** `init` and `deinit` are
/// private and the two public methods take a `*PatchBuilder(D)`, which itself
/// needs a [`Patches`] and a [`PathMap`]; the queue is reached only through
/// [`PatchLog`], which builds one per diff in [`PatchLog.buildCurrent`]. The
/// type is published because a `pub` method on it is reachable from there, not
/// because it is meant to be constructed.
pub const ExposeQueue = struct {
    /// The allocator the array is allocated with, held for the queue's whole
    /// life.
    gpa: Allocator,
    /// Borrowed authoritative document ids, sorted by public `ExId` order and
    /// free of duplicates. The document remains unchanged for this queue's
    /// lifetime; builders copy actor bytes before publishing patches.
    items: std.ArrayList(ExId) = .empty,

    fn init(gpa: Allocator) ExposeQueue {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *ExposeQueue) void {
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    fn first(self: *const ExposeQueue) ?ExId {
        if (self.items.items.len == 0) return null;
        return self.items.items[0];
    }

    /// Whether `obj`'s own events should be skipped because the queue is about
    /// to supply the whole object
    /// ([`ExposeQueue::should_skip`](patch_log.rs):683-689`).
    fn shouldSkip(self: *const ExposeQueue, obj: ExId) bool {
        const head = self.first() orelse return false;
        return head.eql(obj);
    }

    /// Inserts `obj`, keeping the array in `ExId` order.
    fn insert(self: *ExposeQueue, obj: ExId) Error!void {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (obj.order(self.items.items[mid])) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return,
            }
        }
        try self.items.insert(self.gpa, lo, obj);
    }

    fn remove(self: *ExposeQueue, obj: ExId) void {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (obj.order(self.items.items[mid])) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => {
                    _ = self.items.orderedRemove(mid);
                    return;
                },
            }
        }
    }

    /// Flushes every queued object that sorts strictly before `obj`
    /// ([`ExposeQueue::pump_queue`](patch_log.rs):691-704`).
    pub fn pumpQueue(
        self: *ExposeQueue,
        comptime D: type,
        obj: ExId,
        builder: *PatchBuilder(D),
        doc: *const D,
        clock: ?Clock,
    ) MakeError!void {
        while (self.first()) |exposed| {
            if (exposed.order(obj) != .lt) break;
            try self.flushObj(D, exposed, builder, doc, clock);
        }
    }

    /// Flushes the rest, in `ExId` order
    /// ([`ExposeQueue::flush_queue`](patch_log.rs):706-715`).
    pub fn flushQueue(
        self: *ExposeQueue,
        comptime D: type,
        builder: *PatchBuilder(D),
        doc: *const D,
        clock: ?Clock,
    ) MakeError!void {
        while (self.first()) |exposed| {
            try self.flushObj(D, exposed, builder, doc, clock);
        }
    }

    /// One object's whole visible content, as patches
    /// ([`ExposeQueue::flush_obj`](patch_log.rs):725-778`).
    ///
    /// Three shapes, and the recursion is the point: a child that is itself an
    /// object goes on the queue, so the queue drains to a fixed point and
    /// every object a patch's **path** names has been supplied first.
    pub fn flushObj(
        self: *ExposeQueue,
        comptime D: type,
        exid: ExId,
        builder: *PatchBuilder(D),
        doc: *const D,
        clock: ?Clock,
    ) MakeError!void {
        const id = internalObjOf(exid);
        self.remove(exid);
        const kind = doc.objectType(id) catch |e| switch (e) {
            error.NotAnObject => return,
            else => return e,
        };
        switch (kind) {
            .text => {
                var it = doc.spans(id, clock);
                while (try it.next()) |span| {
                    switch (span) {
                        .text => |t| try builder.spliceText(exid, t.index, t.text, t.marks),
                        .obj => |o| {
                            const child = try exportPatchId(D, doc, o.id);
                            try self.insert(child);
                            // Upstream hard-codes `ObjType::Map` here
                            // (`patch_log.rs`:747`) and the port keeps it: a
                            // block in a text object is a map.
                            try builder.insert(exid, o.index, .{ .object = .map }, child, false);
                        },
                    }
                }
            },
            .list => {
                var it = doc.listRangeFor(id, clock);
                while (try it.next()) |item| {
                    const child = try exportPatchId(D, doc, item.id);
                    if (item.value.isObject()) try self.insert(child);
                    // The document hands out a borrowed [`batch.PatchValue`]
                    // and the builder takes an owned [`Value`], so the
                    // conversion happens here — into the patch's arena.
                    try builder.insert(
                        exid,
                        item.index,
                        try ownValue(builder.gpa, item.value),
                        child,
                        item.conflict,
                    );
                }
            },
            .map, .table => {
                var it = doc.mapRangeFor(id, clock);
                while (try it.next()) |item| {
                    const child = try exportPatchId(D, doc, item.id);
                    if (item.value.isObject()) try self.insert(child);
                    try builder.put(
                        exid,
                        .{ .key = item.key },
                        try ownValue(builder.gpa, item.value),
                        child,
                        item.conflict,
                    );
                }
            },
        }
    }
};

// ── PatchLog ────────────────────────────────────────────────────────────────

/// A record of changes made to a document
/// ([`PatchLog`](patch_log.rs):44-57`).
///
/// It holds a set of **relative** changes: what they are relative to is
/// whatever the caller recorded. A merge writes its mutations in through the
/// twelve methods `opset/batch.zig` declares in `log_decls` (`batch.zig`:248-261`),
/// and [`PatchLog.makePatches`] turns them into the ordered stream a consumer
/// applies.
///
/// **Nothing a log holds borrows from the document.** The sink copies on the
/// way in; [`PatchLog.makePatches`] copies again into the [`Patches`] it
/// returns. See the module doc's lifetime section.
pub const PatchLog = struct {
    /// The allocator every copy the log makes is taken with.
    gpa: Allocator,
    /// Whether the log is recording. **The caller is the guard**, exactly as
    /// upstream: `transaction/inner.rs`:794`, `:867`, `:1005` and `:1507` each
    /// test `is_active` before writing, and the batch path does not
    /// (`op_set2/change/batch.rs`:665-832`). The field is `recording` and not
    /// `active` only because Zig has no way to have a field and a
    /// zero-argument function of the same name, and upstream has both.
    recording: bool,
    /// The events, in the order they were logged, before the sort.
    events: std.ArrayList(EventEntry) = .empty,
    /// The op ids of objects whose content a patch needs and no event supplies
    /// (`HashSet<OpId>`, `patch_log.rs`:46`).
    expose: std.AutoHashMapUnmanaged(OpId, void) = .empty,
    /// The patches of views already left behind
    /// (`completed_patches`, `patch_log.rs`:47`).
    completed: Patches,
    /// Where the objects named by [`PatchLog.pathHint`] live
    /// (`path_map`, `patch_log.rs`:49`).
    path_map: PathMap = .{},
    /// The event count the cached `path_map` was taken at (`path_hint`,
    /// `patch_log.rs`:50`). A mismatch means the map is stale.
    path_hint: usize = 0,
    /// The heads the events were recorded against, for a view that is not the
    /// current one (`heads`, `patch_log.rs`:51`).
    heads: ?[]const ChangeHash = null,
    /// The actor list the logged ids are indexed into (`actors`,
    /// `patch_log.rs`:52`).
    actors: std.ArrayList(ActorId) = .empty,
    /// The actor speculatively added when a transaction opened
    /// (`speculative_actor`, `patch_log.rs`:56`).
    speculative_actor: ?ActorId = null,
    /// **Set when a copy the sink had to make could not be allocated.** The
    /// twelve sink methods return `void` — that is the shape
    /// `opset/batch.zig` calls them at, and `batch.zig` is not this file's to
    /// change — so a failed copy cannot be returned from there. It is recorded
    /// instead, and every fallible entry point reports it before doing anything
    /// else. Nothing is silently dropped and nothing is silently wrong: the log
    /// is unusable and says so.
    oom: bool = false,
    /// Prospective document metadata, never an actor-compatibility capability.
    /// Binding assigns it only on success; staged publication adopts it last.
    identity: ?u64 = null,
    /// A batch is an allocation-provenance capability for this exact owner.
    /// The target must stay at its address until the stage is destroyed or
    /// published. A log without a live stage can move by ownership transfer.
    batch_origin: ?*PatchLog = null,
    checkpoint: ?*Checkpoint = null,
    path_storage: std.heap.ArenaAllocator,
    publish_completed: ?Patches = null,

    const Checkpoint = struct {
        events_len: usize,
        expose: std.AutoHashMapUnmanaged(OpId, void),
        path_map: PathMap,
        path_storage: std.heap.ArenaAllocator,
        path_hint: usize,
        oom: bool,

        fn deinit(self: *Checkpoint, gpa: Allocator) void {
            self.expose.deinit(gpa);
            self.path_map.deinit(gpa);
            self.path_storage.deinit();
            gpa.destroy(self);
        }
    };

    /// One event and the object it happened to
    /// ([`Vec<(ObjId, Event)>`](patch_log.rs):45`).
    pub const EventEntry = struct {
        obj: ExId,
        event: Event,
    };

    /// Creates a new log ([`PatchLog::new`](patch_log.rs):228-240`). `active`
    /// decides whether a *caller* records through it; see `recording`.
    pub fn init(gpa: Allocator, recording: bool) PatchLog {
        return .{
            .gpa = gpa,
            .recording = recording,
            .completed = .init(gpa),
            .path_storage = .init(gpa),
        };
    }

    /// A log whose `isActive` flag is true. Event methods still record when
    /// called directly; callers use the flag to decide whether to call them
    /// ([`PatchLog::active`](patch_log.rs):256-258`).
    pub fn active(gpa: Allocator) PatchLog {
        return init(gpa, true);
    }

    /// A log whose `isActive` flag is false. This does not suppress direct
    /// event calls: callers must check the flag when they want no recording
    /// ([`PatchLog::inactive`](patch_log.rs):245-247`).
    pub fn inactive(gpa: Allocator) PatchLog {
        return init(gpa, false);
    }

    /// The same as [`PatchLog.inactive`] ([`PatchLog::null`](patch_log.rs):249-251`).
    ///
    /// **Named `nullLog` and not `null`:** Zig has a `null` primitive and a
    /// declaration may not shadow it. Nothing else about it differs from
    /// [`PatchLog.inactive`] upstream, and nothing does here.
    pub fn nullLog(gpa: Allocator) PatchLog {
        return init(gpa, false);
    }

    /// Releases all events, completed patches, actor mappings, cached paths,
    /// and transaction or publication checkpoints. Returned Patches remain
    /// independently owned by their caller.
    pub fn deinit(self: *PatchLog) void {
        for (self.events.items) |*e| {
            e.obj.deinitOwned(self.gpa);
            e.event.deinit(self.gpa);
        }
        self.events.deinit(self.gpa);
        self.expose.deinit(self.gpa);
        self.completed.deinit();
        self.path_map.deinit(self.gpa);
        if (self.heads) |h| self.gpa.free(h);
        for (self.actors.items) |a| self.gpa.free(a.bytes);
        self.actors.deinit(self.gpa);
        if (self.speculative_actor) |a| self.gpa.free(a.bytes);
        self.path_storage.deinit();
        if (self.checkpoint) |checkpoint| checkpoint.deinit(self.gpa);
        if (self.publish_completed) |*completed| completed.deinit();
        self.* = undefined;
    }

    /// ([`PatchLog::set_active`](patch_log.rs):260-262`).
    pub fn setActive(self: *PatchLog, setting: bool) void {
        self.recording = setting;
    }

    /// ([`PatchLog::is_active`](patch_log.rs):264-266`).
    pub fn isActive(self: *const PatchLog) bool {
        return self.recording;
    }

    // ── The twelve sink methods ─────────────────────────────────────────────
    //
    // `opset/batch.zig` declares the contract it calls at `log_decls`
    // (`batch.zig`:248-261`) and checks it with `assertLog`. These are that
    // contract one for one, and the test
    // `"the patch log satisfies the sink contract"` proves each shape is
    // *identical* to `batch.NullLog`'s, not merely present.

    /// One or more elements inserted into a sequence
    /// ([`PatchLog::insert`](patch_log.rs):480-495`).
    pub fn insert(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        v: PatchValue,
        id: OpId,
        conflict: bool,
    ) void {
        const value = self.ownedValue(v) orelse return;
        self.appendEvent(obj, .{ .insert = .{
            .index = index,
            .value = value,
            .id = id,
            .conflict = conflict,
        } });
    }

    /// A key put in a map ([`PatchLog::put_map`](patch_log.rs):365-386`).
    ///
    /// `expose` with an object value is the fourth rule of the expose queue:
    /// **a put that reveals a losing object** — a delete in the same batch
    /// uncovered it — is recorded, and its op id is queued so the consumer is
    /// given that object's content.
    pub fn putMap(
        self: *PatchLog,
        obj: ObjId,
        key: []const u8,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        if (expose and v.isObject()) self.queueExpose(id);
        const k = self.dupe(key) orelse return;
        const value = self.ownedValue(v) orelse {
            self.gpa.free(k);
            return;
        };
        self.appendEvent(obj, .{ .put_map = .{
            .key = k,
            .value = value,
            .id = id,
            .conflict = conflict,
        } });
    }

    /// An index put in a sequence ([`PatchLog::put_seq`](patch_log.rs):388-409`).
    pub fn putSeq(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        if (expose and v.isObject()) self.queueExpose(id);
        const value = self.ownedValue(v) orelse return;
        self.appendEvent(obj, .{ .put_seq = .{
            .index = index,
            .value = value,
            .id = id,
            .conflict = conflict,
        } });
    }

    /// A key deleted from a map ([`PatchLog::delete_map`](patch_log.rs):309-311`).
    pub fn deleteMap(self: *PatchLog, obj: ObjId, key: []const u8) void {
        const k = self.dupe(key) orelse return;
        self.appendEvent(obj, .{ .delete_map = .{ .key = k } });
    }

    /// One or more indices removed from a sequence
    /// ([`PatchLog::delete_seq`](patch_log.rs):305-307`).
    pub fn deleteSeq(self: *PatchLog, obj: ObjId, index: usize, num: usize) void {
        self.appendEvent(obj, .{ .delete_seq = .{ .index = index, .num = num } });
    }

    /// A register that became conflicted
    /// ([`PatchLog::flag_conflict`](patch_log.rs):335-340`).
    pub fn flagConflict(self: *PatchLog, obj: ObjId, prop: Prop) void {
        switch (prop) {
            .key => |k| {
                const kk = self.dupe(k) orelse return;
                self.appendEvent(obj, .{ .flag_conflict_map = .{ .key = kk } });
            },
            .index => |i| self.appendEvent(obj, .{ .flag_conflict_seq = .{ .index = i } }),
        }
    }

    /// A map counter incremented
    /// ([`PatchLog::increment_map`](patch_log.rs):320-329`).
    pub fn incrementMap(self: *PatchLog, obj: ObjId, key: []const u8, n: i64, id: OpId) void {
        const k = self.dupe(key) orelse return;
        self.appendEvent(obj, .{ .increment_map = .{ .key = k, .n = n, .id = id } });
    }

    /// A sequence counter incremented
    /// ([`PatchLog::increment_seq`](patch_log.rs):331-333`).
    pub fn incrementSeq(self: *PatchLog, obj: ObjId, index: usize, n: i64, id: OpId) void {
        self.appendEvent(obj, .{ .increment_seq = .{ .index = index, .n = n, .id = id } });
    }

    /// Text spliced into a text object ([`PatchLog::splice`](patch_log.rs):438-453`).
    ///
    /// **`marks` is borrowed and is freed as soon as this call returns**
    /// (`opset/batch.zig`'s sink contract), so the set and every name in it
    /// are copied here.
    pub fn splice(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        text: []const u8,
        marks: ?*const MarkSet,
    ) void {
        const t = self.dupe(text) orelse return;
        const m = if (marks) |set| self.copiedMarkSet(set) orelse {
            self.gpa.free(t);
            return;
        } else null;
        self.appendEvent(obj, .{ .splice = .{ .index = index, .text = t, .marks = m } });
    }

    /// One text element replaced by another
    /// ([`PatchLog::replace_seq`](patch_log.rs):411-436`).
    ///
    /// **A list replaces with a put; text replaces with a delete and an
    /// insert** (`patch_log.rs`:425-435`), because a text element can be wider
    /// than one unit and the patch has to delete the old width before it
    /// inserts the new. An object value is an insert that may expose; a scalar
    /// is a splice.
    pub fn replaceSeq(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        old_value: PatchValue,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
        seq_type: SequenceType,
        text_encoding: TextEncoding,
        marks: ?*const MarkSet,
    ) void {
        if (seq_type == .list) {
            self.putSeq(obj, index, v, id, conflict, expose);
            return;
        }
        self.deleteSeq(obj, index, old_value.width(seq_type, text_encoding));
        if (v.isObject()) {
            self.insertAndMaybeExpose(obj, index, v, id, conflict, expose);
        } else {
            self.splice(obj, index, v.asStr(), marks);
        }
    }

    /// Marks added or removed over a run
    /// ([`PatchLog::mark`](patch_log.rs):455-463`).
    ///
    /// **Consecutive mark runs fold into one event**, which is why this looks
    /// at `events.last` rather than at an accumulator
    /// (`patch_log.rs`:456-459`). The names are copied, because the run
    /// outlives the set it was read from.
    pub fn mark(self: *PatchLog, obj: ObjId, index: usize, len: usize, marks: *const MarkSet) void {
        const floor = if (self.checkpoint) |checkpoint| checkpoint.events_len else 0;
        if (self.events.items.len > floor) {
            const last = &self.events.items[self.events.items.len - 1];
            if (last.obj.eql(obj) and last.event == .mark) {
                last.event.mark.marks.add(index, len, marks) catch {
                    self.oom = true;
                };
                return;
            }
        }
        var runs: MarkRuns = .init(self.gpa);
        runs.add(index, len, marks) catch {
            self.oom = true;
            runs.deinit();
            return;
        };
        self.appendEvent(obj, .{ .mark = .{ .marks = runs } });
    }

    /// An insert that may expose the object it inserted
    /// ([`PatchLog::insert_and_maybe_expose`](patch_log.rs):465-478`).
    pub fn insertAndMaybeExpose(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        if (expose and v.isObject()) self.queueExpose(id);
        self.insert(obj, index, v, id, conflict);
    }

    /// Checks Rust's sorted insertion/prefix compatibility without allocating
    /// or changing any log state (patches/patch_log.rs:634-658).
    /// Missing old trailing actors are compatible and remain in the log.
    pub fn validateActors(self: *const PatchLog, actors: []const ActorId) Error!void {
        _ = try self.actorMigration(actors);
    }

    const ActorMigration = struct {
        insertions: usize,
        consumed: usize,
    };

    // One ordered comparison serves preflight, ownership construction, and
    // publication. `old` indexes the original table, not the inserted prefix.
    fn actorInsertion(
        actors: []const ActorId,
        actor: ActorId,
        old: *usize,
    ) Error!bool {
        if (old.* == actors.len) return true;
        switch (ActorId.order(actor, actors[old.*])) {
            .eq => {
                old.* += 1;
                return false;
            },
            .lt => return true,
            .gt => return error.PatchLogMismatch,
        }
    }

    fn actorMigration(self: *const PatchLog, others: []const ActorId) Error!ActorMigration {
        var migration: ActorMigration = .{ .insertions = 0, .consumed = 0 };
        for (others) |actor| {
            if (try actorInsertion(self.actors.items, actor, &migration.consumed))
                migration.insertions += 1;
        }
        return migration;
    }

    /// Inserts compatible actor slots and remaps indexed events and caches.
    /// Old trailing actors and their owned bytes are retained, as in Rust
    /// (patches/patch_log.rs:634-658). Mismatch or allocation failure leaves
    /// all log state unchanged; equal or already matching prefixes allocate nothing.
    pub fn migrateActors(self: *PatchLog, others: []const ActorId) Error!void {
        const migration = try self.actorMigration(others);
        if (migration.insertions == 0) return;
        var actors: std.ArrayList(ActorId) = .empty;
        errdefer {
            // Only inserted slots own new bytes until the no-fail transfer.
            var old: usize = 0;
            for (others, 0..) |actor, index| {
                if (index == actors.items.len) break;
                if (actorInsertion(self.actors.items, actor, &old) catch unreachable)
                    self.gpa.free(actors.items[index].bytes);
            }
            actors.deinit(self.gpa);
        }
        try actors.ensureTotalCapacity(self.gpa, self.actors.items.len + migration.insertions);
        var old: usize = 0;
        for (others) |actor| {
            const previous = old;
            const inserted = actorInsertion(self.actors.items, actor, &old) catch unreachable;
            actors.appendAssumeCapacity(if (inserted)
                try self.dupeActor(actor)
            else
                self.actors.items[previous]);
        }
        actors.appendSliceAssumeCapacity(self.actors.items[old..]);
        old = 0;
        for (others, 0..) |actor, index| {
            const has_old_actor = old < self.actors.items.len;
            if (actorInsertion(self.actors.items, actor, &old) catch unreachable) {
                // Rust does not remap an empty table or an appended suffix.
                if (has_old_actor) self.migrateActor(@intCast(index));
            }
        }
        self.actors.deinit(self.gpa);
        self.actors = actors;
    }

    /// Notifies the log that a transaction is beginning
    /// ([`PatchLog::begin_transaction`](patch_log.rs):589-609`).
    ///
    /// An actor whose first change this is was just added to the document, and
    /// a transaction that produces no ops takes it out again — so it is flagged
    /// speculative here and settled in [`PatchLog.finishTransaction`].
    pub fn bindBegin(
        self: *PatchLog,
        identity: u64,
        doc_actors: []const ActorId,
        seq: u64,
        actor_index: ActorIdx,
    ) (Error || InternalError)!void {
        try self.validateActors(doc_actors);
        if (self.oom) return error.OutOfMemory;
        if (self.checkpoint != null or self.speculative_actor != null) return error.Invariant;
        if (actor_index >= doc_actors.len) return error.InvalidActorIndex;
        const speculative = if (seq == 1) try self.dupeActor(doc_actors[actor_index]) else null;
        errdefer if (speculative) |actor| self.gpa.free(actor.bytes);
        const checkpoint = try self.copyCheckpoint();
        self.checkpoint = checkpoint;
        errdefer {
            self.checkpoint = null;
            checkpoint.deinit(self.gpa);
        }
        try self.bind(identity, doc_actors);
        self.speculative_actor = speculative;
    }

    /// Migrates compatible actor slots, then adopts prospective metadata.
    /// Failure retains the original metadata, actor bytes, and recorded data.
    pub fn bind(self: *PatchLog, identity: u64, actors: []const ActorId) Error!void {
        if (self.oom) return error.OutOfMemory;
        try self.migrateActors(actors);
        self.identity = identity;
    }

    pub fn take(self: *PatchLog) PatchLog {
        const result = self.*;
        self.* = .inactive(self.gpa);
        return result;
    }

    pub fn rollbackTransaction(self: *PatchLog, actors: []const ActorId) void {
        const checkpoint = self.checkpoint orelse {
            self.settleActor(actors);
            return;
        };
        self.checkpoint = null;
        for (self.events.items[checkpoint.events_len..]) |*entry| {
            entry.obj.deinitOwned(self.gpa);
            entry.event.deinit(self.gpa);
        }
        self.events.shrinkRetainingCapacity(checkpoint.events_len);
        self.expose.deinit(self.gpa);
        self.expose = checkpoint.expose;
        checkpoint.expose = .empty;
        self.path_map.deinit(self.gpa);
        self.path_storage.deinit();
        self.path_map = checkpoint.path_map;
        self.path_storage = checkpoint.path_storage;
        checkpoint.path_map = .{};
        checkpoint.path_storage = .init(self.gpa);
        self.path_hint = checkpoint.path_hint;
        self.oom = checkpoint.oom;
        checkpoint.deinit(self.gpa);
        self.settleActor(actors);
    }

    /// Returns an independently owned deep copy using `gpa` and new metadata.
    /// Copies transaction checkpoints, but never a batch publication capability.
    pub fn cloneAndRebind(self: *const PatchLog, gpa: Allocator, identity: u64) Error!PatchLog {
        var out: PatchLog = .init(gpa, self.recording);
        errdefer out.deinit();
        out.identity = identity;
        // Cloning copies owned data, not the source's publication capability.
        out.batch_origin = null;
        try out.setActors(self.actors.items);
        try out.events.ensureTotalCapacity(gpa, self.events.items.len);
        for (self.events.items) |entry| {
            const obj = try entry.obj.dup(gpa);
            errdefer {
                var id = obj;
                id.deinitOwned(gpa);
            }
            out.events.appendAssumeCapacity(.{ .obj = obj, .event = try copyEvent(gpa, entry.event) });
        }
        out.expose = try self.expose.clone(gpa);
        try out.completed.appendFrom(&self.completed);
        out.path_map = try copyPathMap(gpa, out.path_storage.allocator(), &self.path_map);
        out.path_hint = self.path_hint;
        if (self.heads) |heads| out.heads = try gpa.dupe(ChangeHash, heads);
        if (self.speculative_actor) |actor| out.speculative_actor = try out.dupeActor(actor);
        out.oom = self.oom;
        if (self.checkpoint) |checkpoint| {
            out.checkpoint = try cloneCheckpoint(gpa, checkpoint);
        }
        if (self.publish_completed) |*completed| {
            out.publish_completed = .init(gpa);
            try out.publish_completed.?.appendFrom(completed);
        }
        return out;
    }

    /// Creates an independent tail authorized to publish only to this owner.
    /// Keep this owner address-stable until the returned stage is consumed.
    pub fn beginBatch(self: *PatchLog) Error!PatchLog {
        if (self.oom) return error.OutOfMemory;
        var stage = try self.branch();
        stage.batch_origin = self;
        return stage;
    }

    /// Reserves publication into the exact owner returned by `beginBatch`.
    /// Actor mismatch or allocation failure publishes no recorded data.
    pub fn preparePublish(self: *PatchLog, target: *PatchLog) Error!void {
        if (self.batch_origin != target) return error.PatchLogMismatch;
        if (self.oom or target.oom) return error.OutOfMemory;
        if (self.checkpoint != null or target.checkpoint != null) return error.PatchLogMismatch;
        const migration = try target.actorMigration(self.actors.items);
        // A publication table must also contain all retained target slots.
        // beginBatch inherits them; merge copies any compatible trailing tail.
        if (migration.consumed != target.actors.items.len) return error.PatchLogMismatch;
        var completed: Patches = .init(target.gpa);
        errdefer completed.deinit();
        try completed.appendFrom(&target.completed);
        try completed.appendFrom(&self.completed);
        try target.events.ensureUnusedCapacity(target.gpa, self.events.items.len);
        try target.expose.ensureUnusedCapacity(target.gpa, self.expose.count());
        if (self.publish_completed) |*previous| previous.deinit();
        self.publish_completed = completed;
    }

    /// Consumes a prepared stage into its exact owner without allocating.
    /// Adopts the stage's prospective metadata, not a document-owner token.
    pub fn publish(self: *PatchLog, target: *PatchLog) void {
        if (self.batch_origin != target) @panic("PatchLog batch publication owner mismatch");
        std.debug.assert(!self.oom and !target.oom);
        const completed = self.publish_completed orelse unreachable;
        self.publish_completed = null;
        target.completed.deinit();
        target.completed = completed;
        // Actor bytes were already copied into the stage. Remapping old IDs
        // and transferring that table require no allocation after publication.
        var old: usize = 0;
        for (self.actors.items, 0..) |actor, index| {
            const has_old_actor = old < target.actors.items.len;
            if (actorInsertion(target.actors.items, actor, &old) catch unreachable) {
                if (has_old_actor) target.migrateActor(@intCast(index));
            }
        }
        for (target.actors.items) |actor| target.gpa.free(actor.bytes);
        target.actors.deinit(target.gpa);
        target.actors = self.actors;
        self.actors = .empty;
        target.events.appendSliceAssumeCapacity(self.events.items);
        self.events.clearRetainingCapacity();
        var iterator = self.expose.iterator();
        while (iterator.next()) |entry| {
            target.expose.putAssumeCapacity(entry.key_ptr.*, {});
        }
        target.identity = self.identity;
        target.path_map.deinit(target.gpa);
        target.path_map = .{};
        target.path_hint = 0;
        self.deinit();
        self.* = .inactive(target.gpa);
    }

    pub fn markSingle(
        self: *PatchLog,
        obj: ObjId,
        index: usize,
        len: usize,
        name: []const u8,
        value: ScalarValue,
    ) void {
        if (self.oom) return;
        const floor = if (self.checkpoint) |checkpoint| checkpoint.events_len else 0;
        if (self.events.items.len > floor) {
            const last = &self.events.items[self.events.items.len - 1];
            if (last.obj.eql(obj) and last.event == .mark) {
                appendMarkRun(&last.event.mark.marks, index, len, name, value) catch {
                    self.oom = true;
                };
                return;
            }
        }
        var runs: MarkRuns = .init(self.gpa);
        appendMarkRun(&runs, index, len, name, value) catch {
            runs.deinit();
            self.oom = true;
            return;
        };
        self.appendEvent(obj, .{ .mark = .{ .marks = runs } });
    }

    fn appendMarkRun(
        runs: *MarkRuns,
        index: usize,
        len: usize,
        name: []const u8,
        value: ScalarValue,
    ) Error!void {
        var at: usize = 0;
        while (at < runs.runs.items.len and
            std.mem.order(u8, runs.runs.items[at].name, name) != .gt) : (at += 1)
        {}
        if (at > 0) {
            const previous = &runs.runs.items[at - 1];
            if (std.mem.eql(u8, previous.name, name) and previous.value.eql(value) and
                previous.index + previous.len == index)
            {
                previous.len += len;
                return;
            }
        }
        const owned_name = try runs.gpa.dupe(u8, name);
        errdefer runs.gpa.free(owned_name);
        const owned_value = try ownScalar(runs.gpa, value);
        errdefer freeScalar(runs.gpa, owned_value);
        try runs.runs.insert(runs.gpa, at, .{
            .name = owned_name,
            .index = index,
            .len = len,
            .value = owned_value,
        });
    }

    fn copyPathMap(gpa: Allocator, arena: Allocator, source: *const PathMap) Error!PathMap {
        var result: PathMap = .{};
        errdefer result.deinit(gpa);
        try result.items.ensureTotalCapacity(gpa, source.items.items.len);
        for (source.items.items) |entry| {
            result.items.appendAssumeCapacity(.{
                .obj = try entry.obj.dup(arena),
                .parent = try entry.parent.dup(arena),
                .prop = switch (entry.prop) {
                    .key => |key| .{ .key = try arena.dupe(u8, key) },
                    .index => |index| .{ .index = index },
                },
            });
        }
        return result;
    }

    fn copyCheckpoint(self: *const PatchLog) Error!*Checkpoint {
        const checkpoint = try self.gpa.create(Checkpoint);
        checkpoint.* = .{
            .events_len = self.events.items.len,
            .expose = .empty,
            .path_map = .{},
            .path_storage = .init(self.gpa),
            .path_hint = self.path_hint,
            .oom = self.oom,
        };
        errdefer checkpoint.deinit(self.gpa);
        checkpoint.expose = try self.expose.clone(self.gpa);
        checkpoint.path_map = try copyPathMap(
            self.gpa,
            checkpoint.path_storage.allocator(),
            &self.path_map,
        );
        return checkpoint;
    }

    fn cloneCheckpoint(gpa: Allocator, source: *const Checkpoint) Error!*Checkpoint {
        const checkpoint = try gpa.create(Checkpoint);
        checkpoint.* = .{
            .events_len = source.events_len,
            .expose = .empty,
            .path_map = .{},
            .path_storage = .init(gpa),
            .path_hint = source.path_hint,
            .oom = source.oom,
        };
        errdefer checkpoint.deinit(gpa);
        checkpoint.expose = try source.expose.clone(gpa);
        checkpoint.path_map = try copyPathMap(
            gpa,
            checkpoint.path_storage.allocator(),
            &source.path_map,
        );
        return checkpoint;
    }

    /// Notifies the log that a transaction has finished
    /// ([`PatchLog::finish_transaction`](patch_log.rs):616-626`).
    ///
    /// Settles the speculative actor [`PatchLog.bindBegin`] took: the
    /// document kept it, so it stays, and otherwise it is dropped from the
    /// log's actor list along with every id that named it. **Infallible** —
    /// nothing here allocates and nothing here can fail, which is why a
    /// `defer` at a commit's tail needs no `catch`. `doc_actors` is borrowed
    /// for the call only.
    pub fn finishTransaction(self: *PatchLog, doc_actors: []const ActorId) void {
        if (self.checkpoint) |checkpoint| {
            checkpoint.deinit(self.gpa);
            self.checkpoint = null;
        }
        self.settleActor(doc_actors);
    }

    fn settleActor(self: *PatchLog, doc_actors: []const ActorId) void {
        const speculative = self.speculative_actor orelse return;
        self.speculative_actor = null;
        defer self.gpa.free(speculative.bytes);
        for (doc_actors) |actor| {
            if (ActorId.eql(actor, speculative)) return;
        }
        for (self.actors.items, 0..) |actor, index| {
            if (ActorId.eql(actor, speculative)) {
                self.removeActor(index);
                return;
            }
        }
    }

    /// Finalises the events recorded for the current view before the document
    /// moves to another point in history
    /// ([`PatchLog::finish_current_view`](patch_log.rs):290-303`).
    ///
    /// **Paths must be resolved while this view is still current** — a list
    /// index may name a different object after the transition — so the patches
    /// are built here, in order, and kept for [`PatchLog.makePatches`] to
    /// prepend. The events are then dropped, so the next view's events sort and
    /// emit on their own.
    pub fn finishCurrentView(
        self: *PatchLog,
        comptime D: type,
        doc: *const D,
        heads: []const ChangeHash,
    ) MakeError!void {
        if (D == @import("doc.zig").Document) return doc.finishCurrentPatchView(self, heads);
        if (self.checkpoint != null) return error.PatchLogMismatch;
        if (self.oom) return error.OutOfMemory;
        if (self.events.items.len == 0 and self.expose.count() == 0) return;
        try self.migrateActors(doc.actorList());
        const previous = self.heads;
        self.heads = try self.gpa.dupe(ChangeHash, heads);
        defer {
            self.gpa.free(self.heads.?);
            self.heads = previous;
        }
        try self.buildCurrent(D, &self.completed, doc);
        for (self.events.items) |*e| {
            e.obj.deinitOwned(self.gpa);
            e.event.deinit(self.gpa);
        }
        self.events.clearRetainingCapacity();
        self.expose.clearRetainingCapacity();
        self.path_hint = 0;
        self.path_map.deinit(self.gpa);
        self.path_map = .{};
    }

    /// The patches, in the order a consumer applies them
    /// ([`PatchLog::make_patches`](patch_log.rs):505-509`).
    ///
    /// Completed historical views precede the current view's events. Local
    /// transactions and applied batches share this same event stream.
    /// The events are not consumed, but the one-use path hint is
    /// (patch_log.rs:513). Subsequent renders resolve paths from the document.
    pub fn makePatches(self: *PatchLog, comptime D: type, doc: *const D) MakeError!Patches {
        // Raw documents own the indexed reader adapter and its lifetime.
        if (D == @import("doc.zig").Document) return doc.makePatches(self);
        if (self.oom) return error.OutOfMemory;
        var out: Patches = .init(self.gpa);
        errdefer out.deinit();
        try out.appendFrom(&self.completed);
        try self.buildCurrent(D, &out, doc);
        return out;
    }

    /// Clears the log and turns it back on
    /// ([`PatchLog::truncate`](patch_log.rs):531-538`).
    ///
    /// **This is what a rollback goes through**: the ops of a rolled-back
    /// transaction never reach the log, and a caller reusing one truncates it
    /// (`autocommit.rs`:203-204`), so nothing survives to be patched with.
    pub fn truncate(self: *PatchLog) void {
        self.recording = true;
        for (self.events.items) |*e| {
            e.obj.deinitOwned(self.gpa);
            e.event.deinit(self.gpa);
        }
        self.events.clearRetainingCapacity();
        self.expose.clearRetainingCapacity();
        self.completed.deinit();
        self.completed = .init(self.gpa);
        self.path_hint = 0;
        self.path_map.deinit(self.gpa);
        self.path_map = .{};
        self.path_storage.deinit();
        self.path_storage = .init(self.gpa);
        if (self.checkpoint) |checkpoint| checkpoint.deinit(self.gpa);
        self.checkpoint = null;
        if (self.speculative_actor) |actor| self.gpa.free(actor.bytes);
        self.speculative_actor = null;
        if (self.publish_completed) |*completed| completed.deinit();
        self.publish_completed = null;
        self.oom = false;
    }

    /// A fresh log over the same actor list
    /// ([`PatchLog::branch`](patch_log.rs):540-552`).
    ///
    /// **A deviation in the signature only**: upstream returns `Self` and its
    /// `Vec<ActorId>` of refcounted ids clones for free, where the port's
    /// [`ActorId`] borrows its bytes and a copy can fail, so this returns
    /// `Error!PatchLog`.
    pub fn branch(self: *PatchLog) Error!PatchLog {
        var out: PatchLog = .init(self.gpa, self.recording);
        errdefer out.deinit();
        try out.setActors(self.actors.items);
        out.identity = self.identity;
        if (self.heads) |heads| out.heads = try self.gpa.dupe(ChangeHash, heads);
        return out;
    }

    /// Folds another log's events into this one
    /// ([`PatchLog::merge`](patch_log.rs):661-665`).
    /// Copies the source through this log's allocator; actor incompatibility
    /// or allocation failure leaves both logs' recorded data unchanged.
    pub fn merge(self: *PatchLog, other: *PatchLog) Error!void {
        const migration = try self.actorMigration(other.actors.items);
        var stage = try other.cloneAndRebind(self.gpa, self.identity orelse
            other.identity orelse 0);
        stage.identity = self.identity orelse other.identity;
        // This copy was allocated through the destination owner, unlike a
        // detached public clone; it can safely transfer its payloads here.
        stage.batch_origin = self;
        defer stage.deinit();
        // The offered table is the prefix of Rust's insertion result. Its IDs
        // already use their final slots; retain only the destination's tail.
        try stage.actors.ensureUnusedCapacity(self.gpa, self.actors.items.len - migration.consumed);
        for (self.actors.items[migration.consumed..]) |actor|
            stage.actors.appendAssumeCapacity(try stage.dupeActor(actor));
        try stage.preparePublish(self);
        stage.publish(self);
    }

    /// Seeds the path cache and records the event count it is good for
    /// ([`PatchLog::path_hint`](patch_log.rs):667-670`).
    ///
    /// Consumes the map's array, copying all borrowed keys and object IDs into
    /// log-owned storage. The array must use this log's allocator. Allocation
    /// failure sets oom and retains the previous cache.
    pub fn pathHint(self: *PatchLog, hint: PathMap) void {
        var source = hint;
        defer source.deinit(self.gpa);
        const owned = copyPathMap(self.gpa, self.path_storage.allocator(), &source) catch {
            self.oom = true;
            return;
        };
        self.path_map.deinit(self.gpa);
        self.path_map = owned;
        self.path_hint = self.events.items.len;
    }

    /// The events of the current view, turned into patches and appended to
    /// `out` ([`PatchLog::make_current_patches`](patch_log.rs):511-529`).
    fn buildCurrent(
        self: *PatchLog,
        comptime D: type,
        out: *Patches,
        doc: *const D,
    ) MakeError!void {
        assertDoc(D);
        // Logical read-cache mutation follows Document's canonical scoped
        // readers. The borrowed clock header never owns its buffers here.
        const clock: ?Clock = if (self.heads) |h|
            (try @constCast(doc).clockAtScope(self.gpa, h)).*
        else
            null;
        // **The seed is released here, on every path out, until the builder
        // takes it.** `expose.insert` below can be refused and `getPathMap`
        // moved the array out of the log, so in that window nothing else owns
        // it. `self.gpa` is the right allocator because `getPathMap` hands back
        // either the log's cached map or one handed in through
        // [`PatchLog.pathHint`], which requires that allocator. The line after
        // the builder exists empties this, so from there the builder owns it.
        var path_map = self.getPathMap();
        defer path_map.deinit(self.gpa);
        // Rust's hint and lookup both use internal ObjId (patch_log.rs:513,
        // patch_builder.rs:145-147). Our walk seeds .id while rendered events
        // use exported ExIds in the event loop below. Export through this SAME
        // rendering owner, not the snapshot owner: current-state logging does
        // not migrate actors (automerge.rs:1048,1077-1079). Keep public named
        // entries unchanged and own new actor bytes in the output arena.
        for (path_map.items.items) |*entry| {
            if (entry.obj == .id)
                entry.obj = try ownExId(out.allocator(), try exportObj(D, doc, entry.obj));
            if (entry.parent == .id)
                entry.parent = try ownExId(out.allocator(), try exportObj(D, doc, entry.parent));
        }
        // Mixed internal/public seeds can change ordering after export. Avoid
        // sorting an already ordered map; stable sorting retains the public
        // named entry when two representations resolve to the same identity.
        var index: usize = 1;
        while (index < path_map.items.items.len) : (index += 1) {
            if (path_map.items.items[index - 1].obj.order(path_map.items.items[index].obj) == .lt)
                continue;
            std.sort.block(PathMapEntry, path_map.items.items, {}, struct {
                fn less(_: void, a: PathMapEntry, b: PathMapEntry) bool {
                    return a.obj.order(b.obj) == .lt;
                }
            }.less);
            var count: usize = 0;
            for (path_map.items.items) |entry| {
                if (count != 0 and path_map.items.items[count - 1].obj.eql(entry.obj)) {
                    path_map.items.items[count - 1] = entry;
                } else {
                    path_map.items.items[count] = entry;
                    count += 1;
                }
            }
            path_map.items.shrinkRetainingCapacity(count);
            break;
        }
        var expose: ExposeQueue = .init(self.gpa);
        defer expose.deinit();
        // **The queue is built from the log's `expose` set**, which is where
        // the three `queueExpose` rules put their op ids
        // (`patch_log.rs`:374-375`, `:397-398`, `:474-475`). Upstream collects
        // it in one expression (`patch_log.rs`:517`) and the collection is
        // ordered, which is what the pump below compares against.
        var pending = self.expose.iterator();
        while (pending.next()) |entry|
            try expose.insert(try exportPatchId(D, doc, entry.key_ptr.*));
        // **The builder takes the seed over, allocator and all**, so it is the
        // one that frees it from here on. This local is emptied below the call
        // so the `defer` above cannot free the same array a second time.
        var builder: PatchBuilder(D) = .init(out, doc, path_map, self.gpa, clock, doc.textEncoding());
        path_map = .{};
        defer builder.deinit();
        // **A stable sort, and the output order rests on it**: the events of
        // one object keep the order they were logged in (`patch_log.rs`:515-516`,
        // and `Vec::sort_by` is a stable sort).
        const scratch = if (self.checkpoint != null)
            try self.gpa.dupe(EventEntry, self.events.items)
        else
            null;
        defer if (scratch) |entries| self.gpa.free(entries);
        const entries = scratch orelse self.events.items;
        std.sort.block(EventEntry, entries, {}, eventLess);
        for (entries) |*e| {
            const key = try exportObj(D, doc, e.obj);
            try expose.pumpQueue(D, key, &builder, doc, clock);
            if (expose.shouldSkip(key)) continue;
            try builder.logEvent(doc, key, &e.event);
        }
        try expose.flushQueue(D, &builder, doc, clock);
        try out.items.ensureUnusedCapacity(out.allocator(), builder.patches.items.len);
        out.items.appendSliceAssumeCapacity(builder.takePatches());
    }

    // ── Internals ───────────────────────────────────────────────────────────

    /// Re-indexes every id in the log for an actor inserted at `index`
    /// ([`PatchLog::migrate_actor`](patch_log.rs):554-565`).
    fn migrateActor(self: *PatchLog, index: ActorIdx) void {
        for (self.events.items) |*entry| {
            entry.obj = entry.obj.withNewActor(index);
            entry.event = entry.event.withNewActor(index);
        }
        var iterator = self.expose.iterator();
        while (iterator.next()) |entry| {
            entry.key_ptr.* = entry.key_ptr.*.withNewActor(index);
        }
        if (self.expose.count() != 0) self.expose.rehash(std.hash_map.AutoContext(OpId){});
        for (self.path_map.items.items) |*entry| {
            entry.obj = entry.obj.withNewActor(index);
            entry.parent = entry.parent.withNewActor(index);
        }
        if (self.checkpoint) |checkpoint| {
            var pending = checkpoint.expose.iterator();
            while (pending.next()) |entry| {
                entry.key_ptr.* = entry.key_ptr.*.withNewActor(index);
            }
            if (checkpoint.expose.count() != 0)
                checkpoint.expose.rehash(std.hash_map.AutoContext(OpId){});
            for (checkpoint.path_map.items.items) |*entry| {
                entry.obj = entry.obj.withNewActor(index);
                entry.parent = entry.parent.withNewActor(index);
            }
        }
    }

    /// Drops an actor from the log, and every event that named it
    /// ([`PatchLog::remove_actor`](patch_log.rs):567-581`).
    fn removeActor(self: *PatchLog, index: usize) void {
        const gone = self.actors.orderedRemove(index);
        self.gpa.free(gone.bytes);
        const at: ActorIdx = @intCast(index);
        var count: usize = 0;
        for (self.events.items) |*entry| {
            const obj = entry.obj.withoutActor(at);
            const event = entry.event.withoutActor(at);
            if (obj != null and event != null) {
                self.events.items[count] = .{ .obj = obj.?, .event = event.? };
                count += 1;
            } else {
                entry.obj.deinitOwned(self.gpa);
                entry.event.deinit(self.gpa);
            }
        }
        self.events.shrinkRetainingCapacity(count);
        var iterator = self.expose.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.*.withoutActor(at)) |id| {
                entry.key_ptr.* = id;
            } else {
                self.expose.removeByPtr(entry.key_ptr);
            }
        }
        if (self.expose.count() != 0) self.expose.rehash(std.hash_map.AutoContext(OpId){});
        count = 0;
        for (self.path_map.items.items) |entry| {
            const obj = entry.obj.withoutActor(at) orelse continue;
            const parent = entry.parent.withoutActor(at) orelse continue;
            self.path_map.items.items[count] = .{ .obj = obj, .parent = parent, .prop = entry.prop };
            count += 1;
        }
        self.path_map.items.shrinkRetainingCapacity(count);
    }

    /// The path cache, dropped if it was taken at a different event count
    /// ([`PatchLog::get_path_map`](patch_log.rs):497-503`).
    fn getPathMap(self: *PatchLog) PathMap {
        if (self.path_hint != self.events.items.len) {
            self.path_hint = 0;
            self.path_map.deinit(self.gpa);
            self.path_map = .{};
        }
        const out = self.path_map;
        self.path_map = .{};
        return out;
    }

    fn dupe(self: *PatchLog, bytes: []const u8) ?[]const u8 {
        if (self.oom) return null;
        return self.gpa.dupe(u8, bytes) catch {
            self.oom = true;
            return null;
        };
    }

    fn dupeActor(self: *PatchLog, a: ActorId) Error!ActorId {
        return ActorId.init(try self.gpa.dupe(u8, a.bytes));
    }

    fn ownedValue(self: *PatchLog, v: PatchValue) ?Value {
        if (self.oom) return null;
        return ownValue(self.gpa, v) catch {
            self.oom = true;
            return null;
        };
    }

    fn copiedMarkSet(self: *PatchLog, m: *const MarkSet) ?MarkSet {
        if (self.oom) return null;
        return copyMarkSet(self.gpa, m) catch {
            self.oom = true;
            return null;
        };
    }

    fn appendEvent(self: *PatchLog, obj: ObjId, ev: Event) void {
        if (self.oom) {
            var e = ev;
            e.deinit(self.gpa);
            return;
        }
        const owned_obj = obj.dup(self.gpa) catch {
            self.oom = true;
            var event = ev;
            event.deinit(self.gpa);
            return;
        };
        self.events.append(self.gpa, .{ .obj = owned_obj, .event = ev }) catch {
            self.oom = true;
            var id = owned_obj;
            id.deinitOwned(self.gpa);
            var event = ev;
            event.deinit(self.gpa);
        };
    }

    /// Puts `id` on the expose queue ([`PatchLog::put_map`](patch_log.rs):374-375`,
    /// [`put_seq`](patch_log.rs):397-398`,
    /// [`insert_and_maybe_expose`](patch_log.rs):474-475`).
    fn queueExpose(self: *PatchLog, id: OpId) void {
        if (self.oom) return;
        self.expose.put(self.gpa, id, {}) catch {
            self.oom = true;
        };
    }

    fn setActors(self: *PatchLog, others: []const ActorId) Error!void {
        std.debug.assert(self.actors.items.len == 0);
        try self.migrateActors(others);
    }
};

/// A deep copy of `ev` into `gpa` ([`PatchLog::merge`](patch_log.rs):661-665`).
fn copyEvent(gpa: Allocator, ev: Event) Error!Event {
    return switch (ev) {
        .put_map => |e| blk: {
            const key = try gpa.dupe(u8, e.key);
            errdefer gpa.free(key);
            break :blk .{ .put_map = .{
                .key = key,
                .value = try copyValue(gpa, e.value),
                .id = e.id,
                .conflict = e.conflict,
            } };
        },
        .put_seq => |e| .{ .put_seq = .{
            .index = e.index,
            .value = try copyValue(gpa, e.value),
            .id = e.id,
            .conflict = e.conflict,
        } },
        .delete_seq => |e| .{ .delete_seq = .{ .index = e.index, .num = e.num } },
        .delete_map => |e| .{ .delete_map = .{ .key = try gpa.dupe(u8, e.key) } },
        .splice => |e| blk: {
            const text = try gpa.dupe(u8, e.text);
            errdefer gpa.free(text);
            break :blk .{ .splice = .{
                .index = e.index,
                .text = text,
                .marks = if (e.marks) |*marks| try copyMarkSet(gpa, marks) else null,
            } };
        },
        .insert => |e| .{ .insert = .{
            .index = e.index,
            .value = try copyValue(gpa, e.value),
            .id = e.id,
            .conflict = e.conflict,
        } },
        .increment_map => |e| .{ .increment_map = .{
            .key = try gpa.dupe(u8, e.key),
            .n = e.n,
            .id = e.id,
        } },
        .increment_seq => |e| .{ .increment_seq = .{ .index = e.index, .n = e.n, .id = e.id } },
        .flag_conflict_map => |e| .{ .flag_conflict_map = .{ .key = try gpa.dupe(u8, e.key) } },
        .flag_conflict_seq => |e| .{ .flag_conflict_seq = .{ .index = e.index } },
        .mark => |e| blk: {
            var runs: MarkRuns = .init(gpa);
            errdefer runs.deinit();
            try runs.runs.ensureTotalCapacity(gpa, e.marks.runs.items.len);
            for (e.marks.runs.items) |run| {
                const name = try gpa.dupe(u8, run.name);
                errdefer gpa.free(name);
                const value = try ownScalar(gpa, run.value);
                runs.runs.appendAssumeCapacity(.{
                    .name = name,
                    .index = run.index,
                    .len = run.len,
                    .value = value,
                });
            }
            break :blk .{ .mark = .{ .marks = runs } };
        },
    };
}

fn eventLess(_: void, a: PatchLog.EventEntry, b: PatchLog.EventEntry) bool {
    return a.obj.order(b.obj) == .lt;
}

/// An internal object id from an [`ExId`] ([`ExId::to_internal_obj`],
/// `patch_log.rs`:732`).
///
/// The port's `ExId` **is** the internal id — a union of an `OpId` and a root
/// tag, with no actor bytes — so this is the identity. It is spelled out
/// because upstream's is a conversion, and a reader comparing the two should
/// not have to work that out.
fn internalObjOf(id: ExId) ExId {
    return id;
}

/// An internal object id from an operation id, for the entries of a walk
/// ([`ObjId(item.op_id())`](patch_builder.rs):118`).
fn internalObj(id: OpId) ExId {
    return .{ .id = id };
}

// Actor-table authority belongs to the reader, not the retained log. Real
// document adapters reject absent resident slots rather than exporting an
// unresolved ID where Rust doc.id_to_exid would index out of bounds.
fn exportPatchId(comptime D: type, doc: *const D, id: OpId) MakeError!ExId {
    return try doc.exportPatchId(id);
}

/// The exported id of an internal object id ([`doc.id_to_exid`](automerge.rs):794-796`).
fn exportObj(comptime D: type, doc: *const D, obj: ExId) MakeError!ExId {
    return switch (obj) {
        .root, .named => obj,
        .id => |i| try exportPatchId(D, doc, i),
    };
}

/// Public identity hashing matches `ExId.eql`: root, unresolved table-local
/// ids, and named ids occupy distinct domains. Named identity depends on the
/// counter and actor bytes, never the cached actor-table index.
const ExIdContext = struct {
    pub fn hash(_: @This(), key: ExId) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .root => hasher.update(&.{0}),
            .id => |id| {
                hasher.update(&.{1});
                hasher.update(std.mem.asBytes(&id.counter));
                hasher.update(std.mem.asBytes(&id.actor));
            },
            .named => |named| {
                hasher.update(&.{2});
                hasher.update(std.mem.asBytes(&named.op.counter));
                hasher.update(named.actor.bytes);
            },
        }
        return hasher.final();
    }

    pub fn eql(_: @This(), a: ExId, b: ExId) bool {
        return a.eql(b);
    }
};

/// Fails to compile unless a sink method has `NullLog`'s shape: the same return
/// type, and the same parameter types from the second onwards.
///
/// The first parameter is the receiver, so it is skipped — it is `*PatchLog`
/// here and `*NullLog` there, and that is the whole difference. Everything
/// after it is the contract `opset/batch.zig` calls, and comparing it here
/// makes a wrong parameter type a build failure *in this file* with this file's
/// name in the message, rather than a confusing one somewhere in the merge.
fn assertSame(comptime what: []const u8, comptime got: type, comptime want: type) void {
    const g = @typeInfo(got).@"fn";
    const w = @typeInfo(want).@"fn";
    const ret = if (g.return_type != null and w.return_type != null and
        g.return_type.? == w.return_type.?)
        true
    else
        false;
    if (!ret) {
        @compileError("patch sink method " ++ what ++ " returns the wrong type: " ++
            @typeName(got) ++ " is not " ++ @typeName(want));
    }
    if (g.params.len != w.params.len) {
        @compileError("patch sink method " ++ what ++ " takes " ++
            @typeName(got) ++ " and not " ++ @typeName(want));
    }
    for (g.params[1..], w.params[1..]) |a, b| {
        if (a.type == null or b.type == null or a.type.? != b.type.?) {
            @compileError("patch sink method " ++ what ++ " has the wrong shape: " ++
                @typeName(got) ++ " is not " ++ @typeName(want));
        }
    }
}

// ── The hand-built document the tests read ──────────────────────────────────

/// A value-iterator over a fixed slice. **Constructing one allocates nothing**,
/// which is the property `opset/batch.zig`'s contract asks of a sink and the
/// one the [`assertDoc`] walks rely on.
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
/// **The document is a comptime parameter, so the tests can hand one over.**
/// Writing the content out is also what makes the expectations hand-derived:
/// the expose queue's behaviour is a function of what this says the document
/// holds, not of what a walk happens to produce.
const TestDoc = struct {
    objs: []const Obj = &.{},
    gpa: Allocator = testing.allocator,
    scope_clock: Clock = .initEmpty(testing.allocator),

    pub const Obj = struct {
        id: ExId,
        typ: ObjType,
        /// The object this one hangs by, or null for the root.
        parent: ?ExId = null,
        /// Its visible map registers.
        map_items: []const MapItem = &.{},
        /// Its visible list elements.
        list_items: []const ListItem = &.{},
        /// Its text spans.
        span_items: []const Span = &.{},
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

    pub fn exportPatchId(self: *const TestDoc, id: OpId) Error!ExId {
        _ = self;
        return if (id.eql(OpId.root)) .root else .{ .id = id };
    }

    pub fn objectType(self: *const TestDoc, id: ExId) Error!ObjType {
        const o = self.find(id) orelse return error.NotAnObject;
        return o.typ;
    }

    pub fn objectParent(self: *const TestDoc, id: ExId) ?ExId {
        const o = self.find(id) orelse return null;
        return o.parent;
    }

    /// This fixture has no committed history: every explicit scope is empty.
    /// Borrow stored clock state so its lifetime matches the fixture owner.
    pub fn clockAtScope(self: *const TestDoc, gpa: Allocator, heads: []const ChangeHash) Error!*const Clock {
        _ = gpa;
        _ = heads;
        return &self.scope_clock;
    }

    pub fn actorList(self: *const TestDoc) []const ActorId {
        _ = self;
        return &.{};
    }

    pub fn mapRangeFor(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(MapItem) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.map_items };
    }

    pub fn listRangeFor(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(ListItem) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.list_items };
    }

    pub fn spans(self: *const TestDoc, id: ExId, clock: ?Clock) Slice(Span) {
        _ = clock;
        const o = self.find(id) orelse return .{ .items = &.{} };
        return .{ .items = o.span_items };
    }
};

// ── A recording sink, for the order the merge writes in ────────────────────

/// A sink that forwards to a [`PatchLog`] and records the order of the calls.
///
/// "The merge calls `migrateActors` before it logs anything" is otherwise an
/// inference from reading `opset/batch.zig`; this makes it an assertion, and
/// [`Probe`] carries all twelve names so `assertLog(Probe)` still holds.
const Probe = struct {
    log: PatchLog,
    order: std.ArrayList([]const u8) = .empty,
    gpa: Allocator,

    fn init(gpa: Allocator) Probe {
        return .{ .log = .active(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *Probe) void {
        self.order.deinit(self.gpa);
        self.log.deinit();
    }

    pub fn beginBatch(self: *Probe) Error!Probe {
        return .{ .log = try self.log.beginBatch(), .gpa = self.gpa };
    }

    pub fn preparePublish(self: *Probe, target: *Probe) Error!void {
        try self.log.preparePublish(&target.log);
        try target.order.ensureUnusedCapacity(target.gpa, self.order.items.len);
    }

    pub fn publish(self: *Probe, target: *Probe) void {
        self.log.publish(&target.log);
        target.order.appendSliceAssumeCapacity(self.order.items);
        self.order.items.len = 0;
    }

    fn reset(self: *Probe) void {
        self.order.clearRetainingCapacity();
    }

    fn note(self: *Probe, name: []const u8) void {
        self.order.append(self.gpa, name) catch {};
    }

    pub fn insert(self: *Probe, obj: ObjId, index: usize, v: PatchValue, id: OpId, conflict: bool) void {
        self.note("insert");
        self.log.insert(obj, index, v, id, conflict);
    }

    pub fn putMap(
        self: *Probe,
        obj: ObjId,
        key: []const u8,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        self.note("putMap");
        self.log.putMap(obj, key, v, id, conflict, expose);
    }

    pub fn putSeq(
        self: *Probe,
        obj: ObjId,
        index: usize,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
    ) void {
        self.note("putSeq");
        self.log.putSeq(obj, index, v, id, conflict, expose);
    }

    pub fn deleteMap(self: *Probe, obj: ObjId, key: []const u8) void {
        self.note("deleteMap");
        self.log.deleteMap(obj, key);
    }

    pub fn deleteSeq(self: *Probe, obj: ObjId, index: usize, num: usize) void {
        self.note("deleteSeq");
        self.log.deleteSeq(obj, index, num);
    }

    pub fn flagConflict(self: *Probe, obj: ObjId, prop: Prop) void {
        self.note("flagConflict");
        self.log.flagConflict(obj, prop);
    }

    pub fn incrementMap(self: *Probe, obj: ObjId, key: []const u8, n: i64, id: OpId) void {
        self.note("incrementMap");
        self.log.incrementMap(obj, key, n, id);
    }

    pub fn incrementSeq(self: *Probe, obj: ObjId, index: usize, n: i64, id: OpId) void {
        self.note("incrementSeq");
        self.log.incrementSeq(obj, index, n, id);
    }

    pub fn splice(self: *Probe, obj: ObjId, index: usize, text: []const u8, m: ?*const MarkSet) void {
        self.note("splice");
        self.log.splice(obj, index, text, m);
    }

    pub fn replaceSeq(
        self: *Probe,
        obj: ObjId,
        index: usize,
        old_value: PatchValue,
        v: PatchValue,
        id: OpId,
        conflict: bool,
        expose: bool,
        seq_type: SequenceType,
        text_encoding: TextEncoding,
        m: ?*const MarkSet,
    ) void {
        self.note("replaceSeq");
        self.log.replaceSeq(obj, index, old_value, v, id, conflict, expose, seq_type, text_encoding, m);
    }

    pub fn mark(self: *Probe, obj: ObjId, index: usize, len: usize, m: *const MarkSet) void {
        self.note("mark");
        self.log.mark(obj, index, len, m);
    }

    pub fn migrateActors(self: *Probe, actors: []const ActorId) Error!void {
        self.note("migrateActors");
        try self.log.migrateActors(actors);
    }
};

// ── Comparing a patch stream ────────────────────────────────────────────────

/// Renders every patch of `got` and compares the lines with `want`.
///
/// **Line by line and by content.** `expectEqual` on two slices compares their
/// pointers (`std/testing.zig`:130-139), which is the trap `opset/batch.zig`'s
/// `eqlLines` exists to avoid, so this compares each line with
/// `expectEqualStrings` and prints both sides on the first difference.
fn expectPatches(gpa: Allocator, got: *const Patches, want: []const []const u8) !void {
    if (got.len() != want.len) {
        std.debug.print("patches: got {d} patches, want {d}\n", .{ got.len(), want.len });
        for (got.slice()) |p| {
            const line = try formatPatch(gpa, p);
            defer gpa.free(line);
            std.debug.print("  got  {s}\n", .{line});
        }
        for (want) |w| std.debug.print("  want {s}\n", .{w});
        return error.TestUnexpectedResult;
    }
    for (got.slice(), want, 0..) |p, w, i| {
        const line = try formatPatch(gpa, p);
        defer gpa.free(line);
        if (!std.mem.eql(u8, line, w)) {
            std.debug.print("patch {d}:\n  got  {s}\n  want {s}\n", .{ i, line, w });
            return error.TestUnexpectedResult;
        }
    }
}

/// Every variant [`PatchAction`] has, as a count. Nine
/// ([`patch.rs`](patch.rs):33-89`), and the test that uses it fails if a tenth
/// is added without being exercised.
const action_variants = 9;

// ── The merge fixture ───────────────────────────────────────────────────────

const Set = opsetmod.OpSet(opmod.ChangeOp);

/// The string table a fixture's op set borrows. The same shape as
/// `opset/batch.zig`'s, and for the same reason: the table must live at one
/// address for as long as the set does, so a fixture owns it in the heap.
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

    fn asTable(self: *Table) StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }

    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) ParseError!u32 {
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
    obj: ObjId = .root,
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

    /// An empty document over `actors`, which must be **sorted**: an actor
    /// index is a position in that table.
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

    /// Splices `rows` in at `pos`, as the base document. No patches: a base is
    /// not a change, which is the shape `opset/batch.zig`'s own fixtures use.
    fn build(self: *Fixture, pos: usize, rows: []const Rec) !void {
        const ops = try self.gpa.alloc(opmod.ChangeOp, rows.len);
        defer self.gpa.free(ops);
        var made: usize = 0;
        errdefer for (ops[0..made]) |*o| o.deinit(self.gpa);
        for (rows, 0..) |r, i| {
            ops[i] = try mkOp(self.gpa, r);
            made += 1;
        }
        _ = try self.set.splice(pos, ops);
        for (ops) |*o| o.deinit(self.gpa);
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
        var batch_apply = batch.BatchApply(L).init(self.gpa, ops);
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

/// The three actors the merge fixtures use, in actor-table order.
const fixture_actors = [_]ActorId{
    ActorId.init("aaaaaaaaaaaaaaaa"),
    ActorId.init("bbbbbbbbbbbbbbbb"),
    ActorId.init("cccccccccccccccc"),
};

fn elem(ctr: u32, actor: ActorIdx) ElemId {
    return ElemId.fromOpId(OpId.init(ctr, actor));
}

fn opId(ctr: u32, actor: ActorIdx) OpId {
    return OpId.init(ctr, actor);
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

/// A change with no ops, which is all the merge reads: the actor, the sequence
/// number, and the start op.
fn bareChange(actor: ActorId, seq: u64, start: u64, tag: u8) Change {
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
        .max_op = start,
        .other_actors = &.{},
    };
}

/// The list every list fixture is: a list at the root under key `list`, holding
/// the one element `2@0` = `"a"`.
///
/// **A file-scope `const`**, which is the property that matters: the rows hold
/// runtime values (`elem(2, 0)` is a call), so a `&.{…}` written inside a
/// function would hand the caller a pointer into a dead frame — the trap
/// `opset/op_set.zig`'s module doc records and two fixtures there fell into.
const one_list = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("list"), .act = .make_list },
    .{ .ctr = 2, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("a") },
};

/// The list object those rows make, which is the id of the op that makes it.
const list_obj: ExId = .{ .id = opId(1, 0) };

/// The predecessor of the overwrite of `2@0`. **One allocation, named**, for
/// the same reason: a non-empty `&.{…}` inside a loop is a pointer to that
/// iteration's stack frame.
const pred_two = [_]OpId{opId(2, 0)};
const pred_one = [_]OpId{opId(1, 0)};

/// A root map with the counter `k` = 5 under an `a` that **sorts before it**
/// (`batch.rs`'s `counter_doc`, `batch.zig`:3310-3313`: the object's own row
/// hangs by `a`, and a `make_map` row under a key sorting after `k` would stop
/// the map walk before it reached the register under test).
const counter_doc = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .act = .make_map },
    .{ .ctr = 2, .key = .fromStr("k"), .val = cval(5) },
};

/// A root map whose key `a` holds **one** value, `7@2` — a later actor, so a
/// concurrent writer. A change whose op id is *lesser* than `7@2`'s therefore
/// loses, which is upstream's conflict rule two (`batch.rs`:814-820`), and
/// because the register holds a single live row the document's own value is
/// **not** already conflicted — which is the other half of that arm
/// (`if !d.conflict`, `batch.rs`:816`).
const contested_doc = [_]Rec{
    .{ .ctr = 7, .actor = 2, .key = .fromStr("a"), .val = sval("a7") },
};

/// A root map with `a` = `"a0"` and a text object at `2@0` holding `"ab"`.
const text_doc = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("a"), .val = sval("a0") },
    .{ .ctr = 2, .key = .fromStr("text"), .act = .make_text },
    .{ .ctr = 3, .obj = text_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("ab") },
};

/// The text object [`text_doc`] makes.
const text_obj: ExId = .{ .id = opId(2, 0) };

const pred_three = [_]OpId{opId(3, 0)};

// ── 1. The sink contract ────────────────────────────────────────────────────

test "the patch log satisfies the sink contract" {
    // `assertLog` is the contract `opset/batch.zig` states; the twelve
    // `assertSame` calls are the stronger one, and they are what makes a wrong
    // parameter type a build failure *in this file*, with this file's name in
    // the message, rather than a confusing one somewhere in the merge.
    comptime {
        batch.assertLog(PatchLog);
        assertSame("insert", @TypeOf(PatchLog.insert), @TypeOf(batch.NullLog.insert));
        assertSame("putMap", @TypeOf(PatchLog.putMap), @TypeOf(batch.NullLog.putMap));
        assertSame("putSeq", @TypeOf(PatchLog.putSeq), @TypeOf(batch.NullLog.putSeq));
        assertSame("deleteMap", @TypeOf(PatchLog.deleteMap), @TypeOf(batch.NullLog.deleteMap));
        assertSame("deleteSeq", @TypeOf(PatchLog.deleteSeq), @TypeOf(batch.NullLog.deleteSeq));
        assertSame("flagConflict", @TypeOf(PatchLog.flagConflict), @TypeOf(batch.NullLog.flagConflict));
        assertSame("incrementMap", @TypeOf(PatchLog.incrementMap), @TypeOf(batch.NullLog.incrementMap));
        assertSame("incrementSeq", @TypeOf(PatchLog.incrementSeq), @TypeOf(batch.NullLog.incrementSeq));
        assertSame("splice", @TypeOf(PatchLog.splice), @TypeOf(batch.NullLog.splice));
        assertSame("replaceSeq", @TypeOf(PatchLog.replaceSeq), @TypeOf(batch.NullLog.replaceSeq));
        assertSame("mark", @TypeOf(PatchLog.mark), @TypeOf(batch.NullLog.mark));
        assertSame("migrateActors", @TypeOf(PatchLog.migrateActors), @TypeOf(batch.NullLog.migrateActors));
    }
}

// ── 2. A scripted merge, against a hand-derived stream ─────────────────────

test "a scripted merge produces the hand-derived patch stream" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};

    // The change, op by op:
    //
    // | op | what it is | what the merge logs |
    // |----|------------|---------------------|
    // | `3@1` | an insert at the head of the list | `insert(1@0, 0, "x", 3@1, false)` — the document has no element there, so it is an insert and not a put (`batch.rs`:682`) |
    // | `4@1` | a put over `2@0` | `putSeq(1@0, 1, "A", 4@1, false, false)` — the greater id wins, and `conflict` is `!d.deleted \|\| c.conflict` (`batch.rs`:693-694). **`d.deleted` is true here**, because `4@1` is in `2@0`'s successor list and `process_pred` marks a superseded document value deleted (`batch.rs`:497-503`) — so the change replaces the register outright and there is no conflict to report |
    // | `5@1` | a put of a key the document does not have | `putMap(root, "k", "k0", 5@1, false, false)` (`batch.rs`:822-825`) |
    //
    // The three events sort by object: `root` before `1@0`, because
    // `ExId::cmp` puts `Root` first (`exid.rs`:188-189`). The list's two keep
    // their logged order, because the sort is stable.
    const scripted = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
        .{ .ctr = 4, .actor = 1, .obj = list_obj, .key = .fromElemId(elem(2, 0)), .val = sval("A"), .pred = &pred_two },
        .{ .ctr = 5, .actor = 1, .key = .fromStr("k"), .val = sval("k0") },
    };

    const f = try Fixture.init(gpa, &fixture_actors);
    defer f.destroy();
    try f.build(0, &one_list);

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    try f.mergeInto(PatchLog, &log, &scripted, &changes);

    // The document the log is asked about: a root map holding one list.
    const root_map_item = [_]MapItem{.{
        .key = "list",
        .value = .{ .object = .list },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_map_item },
        .{
            .id = list_obj,
            .typ = .list,
            .parent = .root,
            .list_items = &.{
                .{ .index = 0, .value = .{ .scalar = sval("x") }, .id = opId(3, 1), .conflict = false },
                .{ .index = 1, .value = .{ .scalar = sval("A") }, .id = opId(4, 1), .conflict = false },
            },
        },
    } };

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] PutMap { key: \"k\", value: Str(\"k0\"), obj: 5@1, conflict: false }",
        "1@0 path=[root.Map(\"list\")] Insert { index: 0, values: [{ value: Str(\"x\"), obj: 3@1, conflict: false }] }",
        "1@0 path=[root.Map(\"list\")] PutSeq { index: 1, value: Str(\"A\"), obj: 4@1, conflict: false }",
    });
}

// ── 3. All nine variants, each produced by what it is for ───────────────────

test "every PatchAction variant is produced by the event that names it" {
    const gpa = testing.allocator;
    var log: PatchLog = .active(gpa);
    defer log.deinit();

    // The root object needs no path, so `getPath` reads nothing and the
    // document these patches are read against is empty. That is deliberate: it
    // isolates the event-to-action mapping from path resolution, which the
    // scripted-merge and expose tests cover.
    const doc: TestDoc = .{ .objs = &.{} };

    var bold: MarkSet = MarkSet.fromPairs(gpa, &.{.{ .name = "bold", .value = ival(1) }}) catch unreachable;
    defer bold.deinit();

    // One variant per call, in the order the calls are made, and each call is
    // chosen so that no other one could produce its action:
    //
    // | call | action | why that and not another |
    // |------|--------|---------------------------|
    // | `putMap("a")` | `PutMap` | a key the tail patch is not about |
    // | `flagConflict("a")` | none — it sets that put's `conflict` | upstream's first `flag_conflict` arm (`patch_builder.rs`:346-358`) |
    // | `flagConflict("b")` | `Conflict` | a key no tail put is about, so the merge arm does not apply |
    // | `putMap("c")` | `PutMap` | |
    // | `deleteMap("c")` | `DeleteMap` | `delete_map` has no merge arm at all (`patch_builder.rs`:287-294`) |
    // | `putSeq(0)` | `PutSeq` | `put` on a `Prop::Seq` |
    // | `deleteSeq(0, 1)` | `DeleteSeq` | the tail is a `PutSeq`, and `delete_seq` merges only into a splice, an insert, or a delete (`patch_builder.rs`:236-280`) |
    // | `incrementMap("n", 3)` | `Increment{Map}` | `increment` has no merge arm (`patch_builder.rs`:321-327`) |
    // | `incrementSeq(2, -1)` | `Increment{Seq}` | same, and a negative amount is legal (`patch.rs`:75-76`) |
    // | `insert(0)` | `Insert` | the tail is an `Increment`, so the insert merge arm does not apply |
    // | `splice(4, "hi")` | `SpliceText` | the tail is an `Insert` |
    // | `mark(4, 2)` | `Mark` | the tail is a splice, and `mark` merges only into a `Mark` (`patch_builder.rs`:330`) |
    log.putMap(.root, "a", .{ .scalar = sval("v1") }, opId(1, 0), false, false);
    log.flagConflict(.root, .{ .key = "a" });
    log.flagConflict(.root, .{ .key = "b" });
    log.putMap(.root, "c", .{ .scalar = sval("v3") }, opId(2, 0), false, false);
    log.deleteMap(.root, "c");
    log.putSeq(.root, 0, .{ .scalar = sval("s") }, opId(3, 0), false, false);
    log.deleteSeq(.root, 0, 1);
    log.incrementMap(.root, "n", 3, opId(4, 0));
    log.incrementSeq(.root, 2, -1, opId(5, 0));
    log.insert(.root, 0, .{ .scalar = sval("i") }, opId(6, 0), false);
    log.splice(.root, 4, "hi", null);
    log.mark(.root, 4, 2, &bold);

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] PutMap { key: \"a\", value: Str(\"v1\"), obj: 1@0, conflict: true }",
        "root path=[] Conflict { prop: Map(\"b\") }",
        "root path=[] PutMap { key: \"c\", value: Str(\"v3\"), obj: 2@0, conflict: false }",
        "root path=[] DeleteMap { key: \"c\" }",
        "root path=[] PutSeq { index: 0, value: Str(\"s\"), obj: 3@0, conflict: false }",
        "root path=[] DeleteSeq { index: 0, length: 1 }",
        "root path=[] Increment { prop: Map(\"n\"), value: 3 }",
        "root path=[] Increment { prop: Seq(2), value: -1 }",
        "root path=[] Insert { index: 0, values: [{ value: Str(\"i\"), obj: 6@0, conflict: false }] }",
        "root path=[] SpliceText { index: 4, value: \"hi\", marks: none }",
        "root path=[] Mark { marks: [{ name: \"bold\", value: Int(1), start: 4, end: 6 }] }",
    });

    // Every variant of the union is on that list. Counting the tags off the
    // patches is what makes this a checker rather than a hope: a tenth variant
    // would not appear, and the count below would not match.
    var seen: [action_variants]bool = .{false} ** action_variants;
    var total: usize = 0;
    for (patches.slice()) |p| {
        seen[actionTag(p.action)] = true;
        total += 1;
    }
    try testing.expectEqual(@as(usize, action_variants), countTrue(&seen));
    try testing.expectEqual(@as(usize, 11), total);
}

fn actionTag(a: PatchAction) usize {
    return switch (a) {
        .put_map => 0,
        .put_seq => 1,
        .insert => 2,
        .splice_text => 3,
        .increment => 4,
        .conflict => 5,
        .delete_map => 6,
        .delete_seq => 7,
        .mark => 8,
    };
}

fn countTrue(seen: []const bool) usize {
    var n: usize = 0;
    for (seen) |b| {
        if (b) n += 1;
    }
    return n;
}

// ── 4. The expose queue ─────────────────────────────────────────────────────

test "the expose queue supplies an object's content before the patch that names it" {
    const gpa = testing.allocator;

    // The document, written out by hand:
    //
    // ```text
    // root ──"a"──▶ 1@0 (map) ──"inner"──▶ "x"
    //                        └──"child"──▶ 3@0 (list) ──▶ "p" at index 0
    // ```
    const root_items = [_]MapItem{.{
        .key = "a",
        .value = .{ .object = .map },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const inner_items = [_]MapItem{
        .{ .key = "inner", .value = .{ .scalar = sval("x") }, .id = opId(2, 0), .conflict = false },
        .{ .key = "child", .value = .{ .object = .list }, .id = opId(3, 0), .conflict = false },
    };
    const child_items = [_]ListItem{
        .{ .index = 0, .value = .{ .scalar = sval("p") }, .id = opId(4, 0), .conflict = false },
    };
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = .{ .id = opId(1, 0) }, .typ = .map, .parent = .root, .map_items = &inner_items },
        .{ .id = .{ .id = opId(3, 0) }, .typ = .list, .parent = .{ .id = opId(1, 0) }, .list_items = &child_items },
    } };

    // One event: a put of `1@0` that **exposes** it — the fourth rule of the
    // queue (`patch_log.rs`:374-375`). Without `expose` the log would never
    // learn that `1@0` needs supplying, which is what the second half of this
    // test shows.
    var log: PatchLog = .active(gpa);
    defer log.deinit();
    log.putMap(.root, "a", .{ .object = .map }, opId(1, 0), false, true);

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] PutMap { key: \"a\", value: Object(map), obj: 1@0, conflict: false }",
        "1@0 path=[root.Map(\"a\")] PutMap { key: \"inner\", value: Str(\"x\"), obj: 2@0, conflict: false }",
        "1@0 path=[root.Map(\"a\")] PutMap { key: \"child\", value: Object(list), obj: 3@0, conflict: false }",
        "3@0 path=[root.Map(\"a\"), 1@0.Map(\"child\")] Insert { index: 0, values: [{ value: Str(\"p\"), obj: 4@0, conflict: false }] }",
    });

    // **The order, asserted as the property and not as the four lines above.**
    // Every object a patch's path names must already have a patch of its own,
    // or a consumer walking the stream has nowhere to apply that patch to.
    for (patches.slice(), 0..) |p, i| {
        for (p.path) |step| {
            var found = false;
            for (patches.slice()[0..i], 0..) |earlier, k| {
                if (earlier.obj.eql(step.obj)) found = true;
                _ = k;
            }
            if (!found) {
                // Rendered by hand: `ExId` has no `format`, and adding one
                // would be a change to `src/types.zig`, which is not this
                // file's to make.
                const at = step.obj;
                std.debug.print(
                    "patch {d} has a path step through {any} and no earlier patch is about it\n",
                    .{ i, at },
                );
                return error.TestUnexpectedResult;
            }
        }
    }

    // And the same log **without** the expose flag: one patch, and no patch
    // about `1@0` at all. That is the hole the queue fills, and it is why the
    // flag is not decoration.
    var bare: PatchLog = .active(gpa);
    defer bare.deinit();
    bare.putMap(.root, "a", .{ .object = .map }, opId(1, 0), false, false);
    var without = try bare.makePatches(TestDoc, &doc);
    defer without.deinit();
    try expectPatches(gpa, &without, &.{
        "root path=[] PutMap { key: \"a\", value: Object(map), obj: 1@0, conflict: false }",
    });
    for (without.slice()) |p| {
        try testing.expect(!p.obj.eql(.{ .id = opId(1, 0) }));
    }
}

// ── 5. migrateActors runs first, and the ids follow ─────────────────────────

test "migrateActors runs before any op is logged and the logged ids follow it" {
    const gpa = testing.allocator;

    // The base document has one key, `a`, written by `bbbb…` — which is actor 0
    // of a one-actor table.
    const base_rows = [_]Rec{
        .{ .ctr = 1, .key = .fromStr("a"), .val = sval("a0") },
    };
    const one_actor = [_]ActorId{fixture_actors[1]};

    // The first change is by the same actor: it overwrites `a`, and the log's
    // actor list becomes `[bbbb…]` with the op id `2@0`.
    const first_rows = [_]Rec{
        .{ .ctr = 2, .key = .fromStr("a"), .val = sval("a1"), .pred = &pred_one },
    };

    // The second change is by `aaaa…`, which **sorts before** `bbbb…`. The
    // merge inserts it at index 0, which shifts `bbbb…` to index 1, so the id
    // already in the log moves from `2@0` to `2@1`. A patch emitted after that
    // must name `2@1`.
    const second_rows = [_]Rec{
        .{ .ctr = 2, .key = .fromStr("z"), .val = sval("z0") },
    };

    const f = try Fixture.init(gpa, &one_actor);
    defer f.destroy();
    try f.build(0, &base_rows);

    var probe: Probe = .init(gpa);
    defer probe.deinit();

    try f.mergeInto(Probe, &probe, &first_rows, &[_]Change{
        bareChange(fixture_actors[1], 1, 2, 0x11),
    });
    // The merge writes `migrateActors` before anything else: it is the second
    // line of `apply` (`batch.zig`:2064-2066`), before the first walk.
    try testing.expect(probe.order.items.len >= 1);
    try testing.expectEqualStrings("migrateActors", probe.order.items[0]);
    try testing.expectEqualStrings("putMap", probe.order.items[1]);

    probe.reset();
    try f.mergeInto(Probe, &probe, &second_rows, &[_]Change{
        bareChange(fixture_actors[0], 1, 2, 0x22),
    });
    // Same order on the second merge, and this is the one that has to re-index.
    try testing.expect(probe.order.items.len >= 1);
    try testing.expectEqualStrings("migrateActors", probe.order.items[0]);
    try testing.expectEqualStrings("putMap", probe.order.items[1]);

    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map },
    } };
    var patches = try probe.log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] PutMap { key: \"a\", value: Str(\"a1\"), obj: 2@1, conflict: false }",
        "root path=[] PutMap { key: \"z\", value: Str(\"z0\"), obj: 2@0, conflict: false }",
    });
}

test "a rolled-back transaction leaves no patch behind" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 3, 0x11)};
    const scripted = [_]Rec{
        .{ .ctr = 3, .actor = 1, .obj = list_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("x") },
    };

    const f = try Fixture.init(gpa, &fixture_actors);
    defer f.destroy();
    try f.build(0, &one_list);

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    try f.mergeInto(PatchLog, &log, &scripted, &changes);

    // The root has to name the list, or `getPath` cannot resolve the path and
    // the patch is dropped (`patch_builder.rs`:157) — which is a different
    // test, and one the expose-queue test already makes.
    const root_items = [_]MapItem{.{
        .key = "list",
        .value = .{ .object = .list },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = list_obj, .typ = .list, .parent = .root },
    } };
    var before = try log.makePatches(TestDoc, &doc);
    defer before.deinit();
    try testing.expect(before.len() == 1);

    // What a rollback goes through: the log is truncated and turned back on
    // (`autocommit.rs`:203-204`, `patch_log.rs`:531-538`). The ops of a
    // rolled-back transaction never reach it, and this is the belt to that
    // braces.
    log.truncate();
    try testing.expect(log.isActive());
    var after = try log.makePatches(TestDoc, &doc);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 0), after.len());
}

// ── 6. Coalescing, and not coalescing ───────────────────────────────────────

test "two adjacent events on one object are one patch, and two objects are two" {
    const gpa = testing.allocator;
    var log: PatchLog = .active(gpa);
    defer log.deinit();

    // Two inserts on the root that are adjacent in index: the second lands at
    // `tail..=tail + len` of the first and so joins it
    // (`patch_builder.rs`:185-189`).
    log.insert(.root, 0, .{ .scalar = sval("a") }, opId(1, 0), false);
    log.insert(.root, 1, .{ .scalar = sval("b") }, opId(2, 0), false);
    // A third on the **same** object but outside that range, which does not.
    log.insert(.root, 9, .{ .scalar = sval("z") }, opId(3, 0), false);
    // One on a different object, which can never merge.
    log.insert(list_obj, 0, .{ .scalar = sval("c") }, opId(4, 0), false);

    const root_items = [_]MapItem{.{
        .key = "list",
        .value = .{ .object = .list },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = list_obj, .typ = .list, .parent = .root },
    } };

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] Insert { index: 0, values: [{ value: Str(\"a\"), obj: 1@0, conflict: false }, { value: Str(\"b\"), obj: 2@0, conflict: false }] }",
        "root path=[] Insert { index: 9, values: [{ value: Str(\"z\"), obj: 3@0, conflict: false }] }",
        "1@0 path=[root.Map(\"list\")] Insert { index: 0, values: [{ value: Str(\"c\"), obj: 4@0, conflict: false }] }",
    });
}

test "n mark events on one object coalesce into one patch holding every run, in order" {
    const gpa = testing.allocator;
    // **`list_obj` hangs in the root's registers**, because
    // [`PatchBuilder.getPath`] resolves a path by asking the document where
    // the object hangs (`:1758`) and then reading the property off the making
    // operation's key, and a root with no register naming it
    // answers nothing — the patch would be dropped, not built. The second
    // half of this test is about what a *second* mark patch does to the first
    // one's array, and it cannot ask that of a patch that was never built.
    const root_items = [_]MapItem{.{
        .key = "list",
        .value = .{ .object = .list },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = list_obj, .typ = .list, .parent = .root },
    } };

    // **Driven through the builder, not through a [`PatchLog`], and that is
    // deliberate.** `PatchLog.mark` folds consecutive mark runs into **one**
    // event as it records them (`patches.zig`:2652-2668`, upstream's
    // `patch_log.rs`:456-459`), so a log cannot hand
    // [`PatchBuilder.appendMarks`] more than one call per patch and the arm
    // cannot be reached twice through that door at all. The builder is the
    // only way to say what is being claimed here: **n calls into the
    // coalescing arm, one patch out.**
    var out: Patches = .init(gpa);
    defer out.deinit();
    // The seed is an empty map, so it has no array and `path_map_gpa` only
    // has to be the allocator every growth and the one free go through.
    var builder: PatchBuilder(TestDoc) = .init(&out, &doc, .{}, gpa, null, .unicode_code_point);
    defer builder.deinit();

    // **Many calls, one object.** The count is the point: it is what turns a
    // shape that could be exercised once into one whose cost is visible.
    // `appendMarks` used to build a *second* array, copy the patch's whole
    // run list into it and publish that, so `n` calls copied
    // `1 + 2 + … + (n-1)` runs — quadratic in `n`. It appends now, as upstream
    // pushes onto the `Vec` it already holds
    // ([`patch_builder.rs`:330-335](../../github-automerge-automerge/rust/automerge/src/patches/patch_builder.rs)).
    //
    // **Two runs per call, so the growth is not one-per-call** and a builder
    // that kept only the last call's runs cannot pass.
    const n = 64;
    for (0..n) |k| {
        var runs: MarkRuns = .init(gpa);
        defer runs.deinit();
        var set = try MarkSet.fromPairs(gpa, &.{
            .{ .name = "bold", .value = ival(1) },
            .{ .name = "link", .value = sval("https://example.com") },
        });
        defer set.deinit();
        try runs.add(k * 4, 4, &set);
        try builder.mark(.root, &runs);
    }

    // **One patch, not `n`.** The head is empty so nothing coalesces into it.
    try testing.expectEqual(@as(usize, 1), builder.patches.items.len);
    const action = builder.patches.items[0].action;
    try testing.expect(std.meta.activeTag(action) == .mark);

    // **Every run of every call is present.** That is the property the copy
    // used to preserve and the append must too: an append into the wrong
    // array would carry one call's runs, or the last call's, and this count is
    // what says it does not.
    try testing.expectEqual(@as(usize, 2 * n), action.mark.marks.len);

    // **The name-sorted order each call contributed is kept**, and the pairs
    // concatenate. `MarkRuns` sorts by name, so each pair is `bold` then
    // `link` ([`MarkRuns`]'s own doc comment calls the order load-bearing).
    for (0..n) |k| {
        const at = 2 * k;
        try testing.expectEqualStrings("bold", action.mark.marks[at].name);
        try testing.expectEqualStrings("link", action.mark.marks[at + 1].name);
        try testing.expect(action.mark.marks[at].value.eql(.{ .int = 1 }));
        try testing.expect(action.mark.marks[at + 1].value.eql(.{
            .str = "https://example.com",
        }));
        // **And the bounds are the ones this call asked for**, not a later
        // one's: the runs are appended in order, not merged by name across
        // calls, which is upstream's shape too (it pushes; it does not fold).
        try testing.expectEqual(@as(usize, k * 4), action.mark.marks[at].start);
        try testing.expectEqual(@as(usize, k * 4 + 4), action.mark.marks[at].end);
    }

    // **A second object opens a second patch, and the first one's runs are
    // untouched.** This is what the scratch's reset is for: a new mark patch
    // must not start by writing over the array the first still names.
    {
        var runs: MarkRuns = .init(gpa);
        defer runs.deinit();
        var set = try MarkSet.fromPairs(gpa, &.{
            .{ .name = "bold", .value = ival(1) },
            .{ .name = "link", .value = sval("https://example.com") },
        });
        defer set.deinit();
        try runs.add(0, 4, &set);
        try builder.mark(list_obj, &runs);
    }
    try testing.expectEqual(@as(usize, 2), builder.patches.items.len);
    try testing.expectEqual(@as(usize, 2 * n), builder.patches.items[0].action.mark.marks.len);
    try testing.expectEqual(@as(usize, 2), builder.patches.items[1].action.mark.marks.len);

    // **And the batch carries both, in order**, which is what the arena's copy
    // out of the builder is for.
    try out.items.appendSlice(out.allocator(), builder.patches.items);
    _ = builder.takePatches();
    try testing.expectEqual(@as(usize, 2), out.len());
    try testing.expectEqual(@as(usize, 2 * n), out.slice()[0].action.mark.marks.len);
}

test "a delete that lands inside the insert before it takes the elements back out" {
    const gpa = testing.allocator;
    var log: PatchLog = .active(gpa);
    defer log.deinit();
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };

    // An insert of three, then a delete of two inside it: the values come out
    // of the tail insert and only the third is left, so there is **one** patch
    // and no `DeleteSeq` (`patch_builder.rs`:253-268`).
    log.insert(.root, 0, .{ .scalar = sval("a") }, opId(1, 0), false);
    log.insert(.root, 1, .{ .scalar = sval("b") }, opId(2, 0), false);
    log.insert(.root, 2, .{ .scalar = sval("c") }, opId(3, 0), false);
    log.deleteSeq(.root, 0, 2);

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] Insert { index: 0, values: [{ value: Str(\"c\"), obj: 3@0, conflict: false }] }",
    });

    // And the whole thing deleted is dropped rather than pushed
    // (`patch_builder.rs`:264-265`).
    var other: PatchLog = .active(gpa);
    defer other.deinit();
    other.insert(.root, 0, .{ .scalar = sval("a") }, opId(1, 0), false);
    other.deleteSeq(.root, 0, 1);
    var none = try other.makePatches(TestDoc, &doc);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.len());
}

test "PatchBuilder coalesced text deletion preserves supplementary scalar suffix in every encoding" {
    // Delete the complete scalar span, not its individual encoded units.
    // Upstream removes those units from its native-unit tree (`patch_builder.rs`:242-247).
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var out: Patches = .init(testing.allocator);
        defer out.deinit();
        var builder = PatchBuilder(TestDoc).init(
            &out,
            &doc,
            .{},
            testing.allocator,
            null,
            enc,
        );
        defer builder.deinit();
        try builder.spliceText(.root, 7, "prefix😀suffix", null);
        try builder.deleteSeq(.root, 7 + enc.width("prefix"), enc.width("😀"));
        try testing.expectEqual(@as(usize, 1), builder.patches.items.len);
        const action = builder.patches.items[0].action;
        try testing.expect(action == .splice_text);
        try testing.expectEqual(@as(usize, 7), action.splice_text.index);
        const rendered = try action.splice_text.value.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("prefixsuffix", rendered);
    }
}

test "ConcreteTextValue single UTF16 unit deletion retains a split surrogate" {
    for ([_]usize{ 6, 7 }) |index| {
        var value = try ConcreteTextValue.init(testing.allocator, "prefix😀suffix", .utf16_code_unit);
        defer value.deinit();
        try value.remove(index);
        try testing.expectEqual(@as(usize, 13), value.len());
        const rendered = try value.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("prefix�suffix", rendered);
    }
}

test "ConcreteTextValue removeRange deletes complete scalar and grapheme spans in every encoding" {
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var value = try ConcreteTextValue.init(testing.allocator, "a😀e\u{301}z", enc);
        defer value.deinit();
        try value.removeRange(1, enc.width("😀e\u{301}"));
        const rendered = try value.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("az", rendered);
    }
}

test "ConcreteTextValue removeRange retains split encoded boundaries" {
    for ([_]TextEncoding{ .utf8_code_unit, .utf16_code_unit }) |enc| {
        var value = try ConcreteTextValue.init(
            testing.allocator,
            if (enc == .utf8_code_unit) "prefixésuffix" else "prefix😀suffix",
            enc,
        );
        defer value.deinit();
        try value.removeRange(6, 1);
        const rendered = try value.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("prefix�suffix", rendered);
        try value.removeRange(6, 2);
        const remainder = try value.makeString(testing.allocator);
        defer testing.allocator.free(remainder);
        try testing.expectEqualStrings("prefixuffix", remainder);
    }
}

test "ConcreteTextValue removeRange does not allocate" {
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        var value = try ConcreteTextValue.init(failing.allocator(), "prefix😀suffix", enc);
        defer value.deinit();
        const allocation_index = failing.alloc_index;
        failing.fail_index = allocation_index;
        try value.removeRange(6, enc.width("😀"));
        try testing.expectEqual(allocation_index, failing.alloc_index);
        const rendered = try value.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("prefixsuffix", rendered);
    }
}

test "ConcreteTextValue removeRange no-ops retain ownership and overshooting ends clamp" {
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        var value = try ConcreteTextValue.init(failing.allocator(), "prefix😀suffix", enc);
        defer value.deinit();
        const allocation_index = failing.alloc_index;
        failing.fail_index = allocation_index;
        try value.removeRange(7, 0);
        try value.removeRange(value.len(), 1);
        try value.removeRange(std.math.maxInt(usize), std.math.maxInt(usize));
        try value.remove(std.math.maxInt(usize));
        const unchanged = try value.makeString(testing.allocator);
        defer testing.allocator.free(unchanged);
        try testing.expectEqualStrings("prefix😀suffix", unchanged);
        try value.removeRange(6, std.math.maxInt(usize));
        const prefix = try value.makeString(testing.allocator);
        defer testing.allocator.free(prefix);
        try testing.expectEqualStrings("prefix", prefix);
        try value.removeRange(0, std.math.maxInt(usize));
        const empty = try value.makeString(testing.allocator);
        defer testing.allocator.free(empty);
        try testing.expectEqualStrings("", empty);
        try value.removeRange(0, 1);
        try testing.expectEqual(@as(usize, 0), value.len());
        try testing.expectEqual(allocation_index, failing.alloc_index);
    }
}

test "ConcreteTextValue initialization refuses truncated UTF8 outside byte encoding" {
    for ([_]TextEncoding{ .unicode_code_point, .utf16_code_unit, .grapheme_cluster }) |enc| {
        try testing.expectError(error.InvalidCharacter, ConcreteTextValue.init(testing.allocator, "\xF0\x9F", enc));
    }
    var bytes = try ConcreteTextValue.init(testing.allocator, "\xF0\x9F", .utf8_code_unit);
    defer bytes.deinit();
    try testing.expectEqual(@as(usize, 2), bytes.len());
    const rendered = try bytes.makeString(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("�", rendered);
}

// ── 7. Determinism, and 8. nothing to say ───────────────────────────────────

/// Fills `log` with the whole nine-variant script of test 3, so two of them
/// are byte-for-byte comparable.
fn logEveryVariant(gpa: Allocator, log: *PatchLog) !void {
    var bold: MarkSet = MarkSet.fromPairs(gpa, &.{.{ .name = "bold", .value = ival(1) }}) catch unreachable;
    defer bold.deinit();
    log.putMap(.root, "a", .{ .scalar = sval("v1") }, opId(1, 0), false, false);
    log.flagConflict(.root, .{ .key = "a" });
    log.flagConflict(.root, .{ .key = "b" });
    log.putMap(.root, "c", .{ .scalar = sval("v3") }, opId(2, 0), false, false);
    log.deleteMap(.root, "c");
    log.putSeq(.root, 0, .{ .scalar = sval("s") }, opId(3, 0), false, false);
    log.deleteSeq(.root, 0, 1);
    log.incrementMap(.root, "n", 3, opId(4, 0));
    log.incrementSeq(.root, 2, -1, opId(5, 0));
    log.insert(.root, 0, .{ .scalar = sval("i") }, opId(6, 0), false);
    log.splice(.root, 4, "hi", null);
    log.mark(.root, 4, 2, &bold);
}

test "the same log replayed twice yields the same patches" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };

    // Twice, over two logs built by the same calls.
    var one: PatchLog = .active(gpa);
    defer one.deinit();
    try logEveryVariant(gpa, &one);
    var other: PatchLog = .active(gpa);
    defer other.deinit();
    try logEveryVariant(gpa, &other);

    var a = try one.makePatches(TestDoc, &doc);
    defer a.deinit();
    var b = try other.makePatches(TestDoc, &doc);
    defer b.deinit();
    try testing.expectEqual(a.len(), b.len());
    for (a.slice(), b.slice()) |x, y| {
        const lx = try formatPatch(gpa, x);
        defer gpa.free(lx);
        const ly = try formatPatch(gpa, y);
        defer gpa.free(ly);
        try testing.expectEqualStrings(lx, ly);
    }

    // And twice over the *same* log, which is the harder claim: `make_patches`
    // does not consume the events (`patch_log.rs`:505-509`).
    var again = try one.makePatches(TestDoc, &doc);
    defer again.deinit();
    try testing.expectEqual(a.len(), again.len());
    for (a.slice(), again.slice()) |x, y| {
        const lx = try formatPatch(gpa, x);
        defer gpa.free(lx);
        const ly = try formatPatch(gpa, y);
        defer gpa.free(ly);
        try testing.expectEqualStrings(lx, ly);
    }
}

test "an empty log and an unchanged document produce no patches" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };

    // Nothing logged.
    var empty: PatchLog = .active(gpa);
    defer empty.deinit();
    var none = try empty.makePatches(TestDoc, &doc);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.len());

    // Logged, but a transaction that changed nothing: a batch of no ops.
    const f = try Fixture.init(gpa, &fixture_actors);
    defer f.destroy();
    try f.build(0, &one_list);
    var quiet: PatchLog = .active(gpa);
    defer quiet.deinit();
    try f.mergeInto(PatchLog, &quiet, &.{}, &[_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x11),
    });
    var still = try quiet.makePatches(TestDoc, &doc);
    defer still.deinit();
    try testing.expectEqual(@as(usize, 0), still.len());
}

// ── 10. The borrowed mark set ───────────────────────────────────────────────

test "a borrowed mark set is copied, not retained" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };

    var log: PatchLog = .active(gpa);
    defer log.deinit();

    // A mark set the log does not own, which `opset/batch.zig` frees the
    // instant the call returns. Its name is heap memory, not a literal, so
    // "overwrite the source" is a real overwrite.
    const name = try gpa.dupe(u8, "bold");
    defer gpa.free(name);
    var set: MarkSet = .init(gpa);
    try set.put(name, ival(1));

    log.mark(.root, 0, 3, &set);
    log.splice(.root, 3, "ab", &set);

    // **Mutate the source, then free it.** A retained borrow would now read
    // the wrong name and the wrong value, and — `testing.allocator` poisons
    // freed memory in a debug build — would read poison at all. `MarkSet`
    // borrows its names (`marks.zig`:326-330) and frees only its own entries
    // buffer, so `name` is freed by the `defer` above and not by `set.deinit`.
    try set.put(name, ival(99));
    @memset(name, 'z');
    set.deinit();

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] Mark { marks: [{ name: \"bold\", value: Int(1), start: 0, end: 3 }] }",
        "root path=[] SpliceText { index: 3, value: \"ab\", marks: {bold=Int(1)} }",
    });
}

// ── 11. Who owns a byte a batch names ───────────────────────────────────────
//
// A [`Patches`] is the one thing a consumer keeps: a [`PatchLog`] is the
// merge's scratch space and the caller drops it. Every test in this section
// therefore **drops the log before it reads anything**, which is the only way
// a borrowed payload shows up. A reader of `PatchBuilder.insert` sees a
// `Value` parameter, an `InsertValues` that was built with the arena, and no
// allocator at all — the borrow is invisible from the code.
//
// `testing.allocator` **unmaps** what it frees rather than filling it with a
// pattern (a read of a freed payload segfaults here, which is how these tests
// fail against the old code), so each of them asserts the **value** it went in
// with: that is the property, and it is also what a failure names.

/// A log with one insert of `value`, its patches built, and the log dropped.
///
/// **No `defer log.deinit()` in here, on purpose.** Dropping the log before
/// the read is the whole test; a `defer` would free it after.
fn patchesAfterLogInsert(gpa: Allocator, doc: *const TestDoc, value: ScalarValue) !Patches {
    var log: PatchLog = .active(gpa);
    log.insert(.root, 0, .{ .scalar = value }, opId(1, 0), false);
    const patches = try log.makePatches(TestDoc, doc);
    log.deinit();
    return patches;
}

/// The one value of the one insert action in `p`.
///
/// **A precondition, not an assertion.** A test that could not reach the
/// payload would pass vacuously, so each refusal says what was in the batch
/// instead.
fn oneInsertValue(p: *const Patches) !InsertValue {
    if (p.len() != 1) {
        std.debug.print("got {d} patches, want one insert\n", .{p.len()});
        return error.TestUnexpectedResult;
    }
    const action = p.slice()[0].action;
    if (action != .insert) {
        std.debug.print("the one patch is a {s}, want an insert\n", .{@tagName(action)});
        return error.TestUnexpectedResult;
    }
    if (action.insert.values.len() != 1) {
        std.debug.print("the insert carries {d} values, want one\n", .{
            action.insert.values.len(),
        });
        return error.TestUnexpectedResult;
    }
    var it = action.insert.values.iter();
    return it.next().?.*;
}

test "an insert's string payload belongs to the batch, not to the log" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };
    const payload = "a string that has to outlive the log that carried it";

    var patches = try patchesAfterLogInsert(gpa, &doc, .{ .str = payload });
    defer patches.deinit();

    const inserted = try oneInsertValue(&patches);
    const s = inserted.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(payload, s.str);
}

test "an insert's byte payload belongs to the batch, not to the log" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };
    const payload = "bytes that have to outlive the log that carried them";

    var patches = try patchesAfterLogInsert(gpa, &doc, .{ .bytes = payload });
    defer patches.deinit();

    const inserted = try oneInsertValue(&patches);
    const s = inserted.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, s.bytes);
}

test "an insert's actor-id payload belongs to the batch, not to the log" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };
    const payload = "0123456789abcdef";

    var patches = try patchesAfterLogInsert(gpa, &doc, .{ .actor_id = ActorId.init(payload) });
    defer patches.deinit();

    const inserted = try oneInsertValue(&patches);
    const s = inserted.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, s.actor_id.bytes);
}

test "an insert's unknown-type payload belongs to the batch, not to the log" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };
    const payload = "a value from a version of automerge this port does not know";

    var patches = try patchesAfterLogInsert(gpa, &doc, .{
        .unknown = .{ .type_code = 0x7f, .bytes = payload },
    });
    defer patches.deinit();

    const inserted = try oneInsertValue(&patches);
    const s = inserted.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 0x7f), s.unknown.type_code);
    try testing.expectEqualSlices(u8, payload, s.unknown.bytes);
}

test "an insert that merges into the tail patch copies its payload too" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };
    const first = "the payload the tail patch was opened with";
    const second = "the payload that merged into it";

    var log: PatchLog = .active(gpa);
    log.insert(.root, 0, .{ .scalar = .{ .str = first } }, opId(1, 0), false);
    // **Inside the tail patch's range**, so this takes the merge arm and lands
    // in the `InsertValues` the first call built — a different copy site from
    // the fresh tree a first insert takes, and the one the old code reached by
    // reference.
    log.insert(.root, 1, .{ .scalar = .{ .str = second } }, opId(2, 0), false);
    var patches = try log.makePatches(TestDoc, &doc);
    log.deinit();
    defer patches.deinit();

    try testing.expectEqual(@as(usize, 1), patches.len());
    const values = patches.slice()[0].action.insert.values;
    try testing.expectEqual(@as(usize, 2), values.len());
    var it = values.iter();
    try testing.expectEqualStrings(first, it.next().?.value.scalarValue().?.str);
    try testing.expectEqualStrings(second, it.next().?.value.scalarValue().?.str);
    try testing.expect(it.next() == null);
}

test "a batch of insert, put and mark patches outlives the log that built it" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{} };

    // **The mark's value is a `str` on purpose.** An `Int` value carries no
    // bytes, so a mark with one could not tell a copied value payload from a
    // borrowed one; `collectMarks` has to copy all four of `ownScalar`'s cases
    // or this dangles.
    var bold: MarkSet = MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .str = "very" } },
    }) catch unreachable;
    defer bold.deinit();

    var log: PatchLog = .active(gpa);
    log.insert(.root, 0, .{ .scalar = sval("inserted") }, opId(1, 0), false);
    log.putMap(.root, "k", .{ .scalar = sval("put") }, opId(2, 0), false, false);
    log.mark(.root, 0, 3, &bold);
    var patches = try log.makePatches(TestDoc, &doc);
    log.deinit();
    defer patches.deinit();

    // Three events on one object, none of which merges into the one before
    // it, so three patches in the order they were logged.
    const all = patches.slice();
    try testing.expectEqual(@as(usize, 3), all.len);

    // The insert: a value copied by `PatchBuilder.insert` into a fresh patch.
    try testing.expectEqual(@as(usize, 1), all[0].action.insert.values.len());
    var iv = all[0].action.insert.values.iter();
    const inserted = iv.next().?.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("inserted", inserted.str);

    // The put: `PatchBuilder.put` already copied both halves, and a
    // regression there would be as silent as the insert's was.
    try testing.expectEqualStrings("k", all[1].action.put_map.key);
    const put = all[1].action.put_map.value.scalarValue() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("put", put.str);

    // The mark: a name **and** a value, and the run's bounds the coalescing
    // computed.
    try testing.expectEqual(@as(usize, 1), all[2].action.mark.marks.len);
    const m = all[2].action.mark.marks[0];
    try testing.expectEqualStrings("bold", m.name);
    try testing.expectEqualStrings("very", m.value.str);
    try testing.expectEqual(@as(usize, 0), m.start);
    try testing.expectEqual(@as(usize, 3), m.end);
}

test "a path's map key belongs to the batch, not to the document" {
    const gpa = testing.allocator;

    // **The key is heap memory on purpose.** A [`PathMap`]'s keys are borrowed
    // from the document — that is its own contract — and a path entry outlives
    // the document it was resolved against by exactly as much as the batch
    // lives. A literal would hide the borrow: nothing ever frees it.
    const key = try gpa.dupe(u8, "inner");
    const root_items = [_]MapItem{.{
        .key = key,
        .value = .{ .object = .map },
        .id = opId(1, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = .{ .id = opId(1, 0) }, .typ = .map, .parent = .root },
    } };

    // A put **inside** `1@0`, so resolving its path walks up to the root and
    // reads the key out of the document's register table.
    var log: PatchLog = .active(gpa);
    log.putMap(.{ .id = opId(1, 0) }, "k", .{ .scalar = sval("v") }, opId(2, 0), false, false);
    var patches = try log.makePatches(TestDoc, &doc);
    log.deinit();
    // The document's key goes first, and `doc` is a table that names it, so a
    // borrowed path step is a read of freed memory.
    gpa.free(key);
    defer patches.deinit();

    try testing.expectEqual(@as(usize, 1), patches.len());
    try testing.expectEqual(@as(usize, 1), patches.slice()[0].path.len);
    try testing.expectEqualStrings("inner", patches.slice()[0].path[0].prop.key);
}

// ── Variants that a real transaction has to produce ─────────────────────────
//
// The script above proves each variant is reachable and pins the event that
// produces it. These three go the rest of the way: a **change merged into a
// real op set**, so the event is a merge's decision and not a call into the
// sink.

test "a delete in a change is a DeleteMap and a DeleteSeq" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 4, 0x11)};

    // Two deletes, one per object. `process_pred` marks the superseded
    // document value `deleted` and the register held nothing else, so
    // `OpValueOption::set` takes the struct-literal arm with
    // `deleted = true, expose = false` (`batch.zig`:550-559`) — and
    // `d.expose` being false is what sends `map_process` and `list_flush` down
    // the **delete** arm rather than the put one (`batch.rs`:700-702`,
    // `:777-780`).
    const dels = [_]Rec{
        .{ .ctr = 4, .actor = 1, .key = .fromStr("a"), .act = .delete, .pred = &pred_one },
        .{ .ctr = 5, .actor = 1, .obj = text_obj, .key = .fromElemId(elem(3, 0)), .act = .delete, .pred = &pred_three },
    };

    const f = try Fixture.init(gpa, &fixture_actors);
    defer f.destroy();
    try f.build(0, &text_doc);

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    try f.mergeInto(PatchLog, &log, &dels, &changes);

    // The length is `d.value.width(.text, encoding)` = the code point count of
    // `"ab"` (`batch.rs`:778-779`).
    const root_items = [_]MapItem{.{
        .key = "text",
        .value = .{ .object = .text },
        .id = opId(2, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = text_obj, .typ = .text, .parent = .root },
    } };
    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] DeleteMap { key: \"a\" }",
        "2@0 path=[root.Map(\"text\")] DeleteSeq { index: 0, length: 2 }",
    });
}

test "a text insert is a splice and a mark-only change is a Mark" {
    const gpa = testing.allocator;
    const changes = [_]Change{bareChange(fixture_actors[1], 1, 4, 0x11)};

    // An insert at the head of the text — the document has no element there, so
    // the text arm's first case splices whatever the value renders as
    // (`batch.rs`:708-717`) — and a mark **begin** over the element behind it.
    // The mark op is not an insert, so the change side of that register stays
    // empty and the text arm's last case fires instead: the marks are emitted
    // over the document value's own width (`batch.rs`:781-790`).
    const ins = [_]Rec{
        .{ .ctr = 4, .actor = 1, .obj = text_obj, .key = .fromElemId(ElemId.head()), .is_insert = true, .val = sval("xy") },
        .{ .ctr = 5, .actor = 1, .obj = text_obj, .key = .fromElemId(elem(3, 0)), .act = .mark, .val = cval(1), .mark = "bold" },
    };

    const f = try Fixture.init(gpa, &fixture_actors);
    defer f.destroy();
    try f.build(0, &text_doc);

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    try f.mergeInto(PatchLog, &log, &ins, &changes);

    // **`3@0`'s run starts at index 2, not 1**, and the reason is index
    // arithmetic rather than element count: the splice of `"xy"` is emitted by
    // `untangleInner`, which advances the index by the op's **width**
    // (`batch.zig`:1666-1669`, upstream `batch.rs`:245-247`) — two code
    // points, not one element. `3@0` is flushed afterwards at whatever the
    // index then is (`batch.zig`:1393-1398`), so the mark run is
    // `[index, index + width("ab"))` = `[2, 4)`.
    const root_items = [_]MapItem{.{
        .key = "text",
        .value = .{ .object = .text },
        .id = opId(2, 0),
        .conflict = false,
    }};
    const doc: TestDoc = .{ .objs = &.{
        .{ .id = .root, .typ = .map, .map_items = &root_items },
        .{ .id = text_obj, .typ = .text, .parent = .root },
    } };
    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "2@0 path=[root.Map(\"text\")] SpliceText { index: 0, value: \"xy\", marks: none }",
        "2@0 path=[root.Map(\"text\")] Mark { marks: [{ name: \"bold\", value: Counter(1), start: 2, end: 4 }] }",
    });
}

test "a merge's own two rules are a Conflict and an Increment" {
    const gpa = testing.allocator;

    // **Rule two**, `batch.rs`:814-820`: the document's `7@2` is a greater id
    // and it was not already conflicted, so the lesser change op `3@1` does not
    // win and does not patch — it flags the register.
    const contested = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("a"), .val = sval("a3") },
    };
    const cf = try Fixture.init(gpa, &fixture_actors);
    defer cf.destroy();
    try cf.build(0, &contested_doc);
    var clog: PatchLog = .active(gpa);
    defer clog.deinit();
    try cf.mergeInto(PatchLog, &clog, &contested, &[_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x11),
    });
    var cdoc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };
    var cpatches = try clog.makePatches(TestDoc, &cdoc);
    defer cpatches.deinit();
    try expectPatches(gpa, &cpatches, &.{
        "root path=[] Conflict { prop: Map(\"a\") }",
    });

    // **Rule three**, `batch.rs`:816-819`: an increment adopts the document's
    // counter (`batch.zig`:690-702`, upstream `batch.rs`:628-641`) and so the
    // two sides end up holding the *same* op id — and equal ids are an
    // increment delta, not a replacement. `6 - 5 = 1`... read the change's
    // amount off the op: it is `2` over a document value of `5`, and the
    // adopted value is the document's, so the delta is the change's `2`.
    const inc = [_]Rec{
        .{ .ctr = 3, .actor = 1, .key = .fromStr("k"), .act = .increment, .val = ival(2), .pred = &pred_two },
    };
    const nf = try Fixture.init(gpa, &fixture_actors);
    defer nf.destroy();
    try nf.build(0, &counter_doc);
    var nlog: PatchLog = .active(gpa);
    defer nlog.deinit();
    try nf.mergeInto(PatchLog, &nlog, &inc, &[_]Change{
        bareChange(fixture_actors[1], 1, 3, 0x22),
    });
    var npatches = try nlog.makePatches(TestDoc, &cdoc);
    defer npatches.deinit();
    try expectPatches(gpa, &npatches, &.{
        "root path=[] Increment { prop: Map(\"k\"), value: 2 }",
    });
}

test "a transaction that made no ops takes its speculative actor back out" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };
    const two_actors = [_]ActorId{ fixture_actors[0], fixture_actors[1] };

    var log: PatchLog = .active(gpa);
    defer log.deinit();

    // This is the actor's first change, so the actor was just added to the
    // document and a transaction producing no ops takes it out again
    // (`patch_log.rs`:589-609`).
    try log.bindBegin(1, &two_actors, 1, 1);
    // An event that names it, which `remove_actor` must then drop: an
    // operation that named the removed actor cannot exist
    // (`patch_log.rs`:567-581`).
    log.putMap(.root, "a", .{ .scalar = sval("v") }, opId(2, 1), false, false);
    var during = try log.makePatches(TestDoc, &doc);
    defer during.deinit();
    try testing.expectEqual(@as(usize, 1), during.len());

    // Committed with no ops: the document's actor table never grew, and the
    // log has to give the actor — and the event — back.
    log.finishTransaction(&.{fixture_actors[0]});
    try testing.expect(log.speculative_actor == null);
    try testing.expectEqual(@as(usize, 1), log.actors.items.len);
    var after = try log.makePatches(TestDoc, &doc);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 0), after.len());

    // A transaction that **did** produce ops keeps its actor, and so keeps the
    // event (`patch_log.rs`:620-624`).
    try log.bindBegin(1, &two_actors, 2, 1);
    log.putMap(.root, "b", .{ .scalar = sval("w") }, opId(3, 1), false, false);
    log.finishTransaction(&two_actors);
    var kept = try log.makePatches(TestDoc, &doc);
    defer kept.deinit();
    try expectPatches(gpa, &kept, &.{
        "root path=[] PutMap { key: \"b\", value: Str(\"w\"), obj: 3@1, conflict: false }",
    });
}

test "the patches of a view already left behind come first, in the order they were built" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };
    const heads = [_]ChangeHash{.{ .bytes = [_]u8{0x11} ** 32 }};

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    log.putMap(.root, "a", .{ .scalar = sval("first") }, opId(1, 0), false, false);
    // The document moves to another point in history. The paths must be
    // resolved **now**, while this view is current, so the patches are built
    // here and kept (`patch_log.rs`:290-303`).
    try log.finishCurrentView(TestDoc, &doc, &heads);
    try testing.expectEqual(@as(usize, 0), log.events.items.len);

    // The next view's events, which must come *after* the completed ones.
    log.putMap(.root, "b", .{ .scalar = sval("second") }, opId(2, 0), false, false);
    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(gpa, &patches, &.{
        "root path=[] PutMap { key: \"a\", value: Str(\"first\"), obj: 1@0, conflict: false }",
        "root path=[] PutMap { key: \"b\", value: Str(\"second\"), obj: 2@0, conflict: false }",
    });
}

test "a delete of no elements changes nothing and traps on nothing" {
    const gpa = testing.allocator;
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };

    var log: PatchLog = .active(gpa);
    defer log.deinit();
    log.splice(.root, 0, "abc", null);
    // **A delete of nothing is a no-op.** This is not a hand-made shape: a
    // text element whose value is the empty string has width zero under every
    // encoding, and [`PatchLog.replaceSeq`] logs exactly that width
    // (`opset/batch.zig:849` logs the same one).
    log.deleteSeq(.root, 0, 0);

    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    // **One patch: the splice alone.** The delete reaches the builder's
    // coalescing arm, where both arms test `index + length - 1`; at zero that
    // underflows, so Debug and ReleaseSafe trap and the wrapping modes fall
    // through and push a `DeleteSeq` carrying `length = 0`.
    try testing.expectEqual(@as(usize, 1), patches.len());
    try testing.expect(patches.slice()[0].action == .splice_text);
}

/// Records one mark and frees the log. The value has bytes of its own, so the
/// run [`MarkRuns.add`] builds has two owned halves rather than one.
fn recordOneMarkThenFree(gpa: Allocator) !void {
    // **Borrowed, so the set outlives the call and is released here.** The
    // names and the value are literals, which is what
    // `MarkSet`'s borrow contract asks a test to pass.
    var set: MarkSet = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .str = "yes" } },
    });
    defer set.deinit();
    var log: PatchLog = .active(gpa);
    defer log.deinit();
    log.mark(.root, 0, 1, &set);
    if (log.oom) return error.OutOfMemory;
}

test "a refused mark run frees the half it had already copied" {
    // **A leak-failing allocator is the whole assertion.** The name is
    // duplicated first and the value second; when the second is refused the
    // first has no owner unless the insert released it, and a plain caller
    // cannot see that difference any other way.
    try testing.checkAllAllocationFailures(testing.allocator, recordOneMarkThenFree, .{});
}

/// A document whose root holds nothing, so the only way a nested object's
/// path can be resolved is through the cache the caller seeded. The key is a
/// literal, which is what [`PathMap`]'s borrow contract asks of a test.
const unbacked_doc: TestDoc = .{
    .objs = &.{
        .{ .id = .root, .typ = .map },
        .{ .id = .{ .id = OpId.init(2, 0) }, .typ = .map, .parent = .root },
    },
};

/// Seeds `log`'s path cache with a map built by `gpa`, diffs through it, and
/// frees everything.
///
/// **This is the route `DiffIter.log` hands over, and the seed arrives *after*
/// the events it describes.** Every caller orders it that way — upstream runs
/// the walk and only then calls `path_hint`
/// ([`automerge.rs:1078-1079`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// and the port's own two callers hand over what
/// `src/iter/doc.zig`'s `DiffIter.log` returned the same way
/// (`doc.zig`:6160`, `:6444`) — because it is load-bearing, not incidental:
/// [`PatchLog.pathHint`] records the event count it was called at
/// (`patch_log.rs`:667-670`) and [`PatchLog.getPathMap`] drops a map taken at
/// any other one (`patch_log.rs`:497-503`). A seed offered before the event it
/// is meant to resolve is a seed the walk never sees.
///
/// **The seed is built with an ordinary allocator, so `testing.allocator` is
/// the whole assertion**: a builder that adopted it and released it through
/// the patch arena would leave the array behind, and one that released it
/// twice would be reported by the same allocator. The root document
/// deliberately holds nothing, so the builder cannot fall back to walking the
/// map and produce the same path — **without the seed there is no patch at
/// all.**
fn seededDiffThenFree(gpa: Allocator) !void {
    var log: PatchLog = .active(gpa);
    defer log.deinit();

    log.putMap(internalObj(OpId.init(2, 0)), "k", .{ .scalar = sval("w") }, OpId.init(3, 0), false, false);

    var hint: PathMap = .{};
    try hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 0)),
        .prop = .{ .key = "child" },
        .parent = .root,
    });
    log.pathHint(hint);

    var patches = try log.makePatches(TestDoc, &unbacked_doc);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 1), patches.len());
    // **And the key the caller handed over is the one in the patch**, which is
    // the other half: a copy taken before the arena ever saw it.
    try testing.expectEqualStrings("child", patches.slice()[0].path[0].prop.key);
}

test "seeded paths survive patch construction and allocation refusals" {
    // Sweep each allocation after transferring the seed out of the log.
    // The emitted path must retain its key, with no leaked or duplicate owner.
    try testing.checkAllAllocationFailures(testing.allocator, seededDiffThenFree, .{});
}

/// Offers the log the same seed one event too early, and diffs through it.
///
/// **The other half of [`PatchLog.pathHint`]'s rule, and the one that owns the
/// seed once it fires.** A map taken at an older event count describes a view
/// this one is not, so [`PatchLog.getPathMap`] releases it before the walk
/// (`patch_log.rs`:497-503`) rather than resolving a path against it. The
/// root document holds nothing, so the walk finds no path either way and the
/// stream is empty — **and the dropped array is still freed, through the
/// allocator it was built with**, which is what `testing.allocator` says
/// under every refusal.
fn staleSeedThenFree(gpa: Allocator) !void {
    var log: PatchLog = .active(gpa);
    defer log.deinit();

    var hint: PathMap = .{};
    try hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 0)),
        .prop = .{ .key = "child" },
        .parent = .root,
    });
    log.pathHint(hint);

    log.putMap(internalObj(OpId.init(2, 0)), "k", .{ .scalar = sval("w") }, OpId.init(3, 0), false, false);

    var patches = try log.makePatches(TestDoc, &unbacked_doc);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 0), patches.len());
}

test "a seed taken at an older event count is dropped, and released" {
    // The stale branch of `getPathMap`, which no other test here reaches: every
    // other seed arrives with the event count it was offered at.
    try testing.checkAllAllocationFailures(testing.allocator, staleSeedThenFree, .{});
}

test "snapshot hints render first against an old owner through a cloned borrowed log" {
    // Rust keeps indexed snapshot paths, then exports through the rendering
    // owner (automerge.rs:1048,1078-1079; patch_builder.rs:143-165). The source's
    // actor differs deliberately: neither its actor bytes nor its children may
    // be substituted for the selected owner's IDs and ancestry.
    const Document = @import("doc.zig").Document;
    const Transaction = @import("transact.zig").Transaction;
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = "a" });
    var initial = PatchLog.active(gpa);
    defer initial.deinit();
    var owner_tx = try Transaction.openWithPatchLog(gpa, &owner, &initial, null);
    defer owner_tx.deinitClosed();
    _ = try owner_tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var owned = try owner_tx.commitWith(.{ .time = 0 });
    defer owned.deinit(gpa);

    var source = try Document.init(gpa, testing.io);
    defer source.deinit();
    source.setActorId(.{ .bytes = "b" });
    var tx = try Transaction.open(gpa, &source);
    defer tx.deinitClosed();
    const map = try tx.putObject(.root, .{ .key = "map" }, .map);
    const list = try tx.putObject(map, .{ .key = "list" }, .list);
    _ = try tx.insert(list, 0, .{ .int = 7 });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    const bytes = try source.save(gpa);
    defer gpa.free(bytes);

    var foreign = try Document.init(gpa, testing.io);
    defer foreign.deinit();
    var offered = try owned.patch_log.cloneAndRebind(gpa, owner.patchIdentity());
    defer offered.deinit();
    _ = try foreign.loadIncrementalWithPatchLog(gpa, bytes, &offered);
    var cloned = try offered.cloneAndRebind(gpa, owner.patchIdentity());
    defer cloned.deinit();
    offered.deinit();
    offered = PatchLog.inactive(gpa);
    try testing.expect(owner.objectParent(map) == null);
    try testing.expect(owner.objectParent(list) == null);
    var rendered = try owner.makePatches(&cloned);
    defer rendered.deinit();
    try expectPatches(gpa, &rendered, &.{
        "root path=[] PutMap { key: \"owned\", value: Bool(true), obj: 1@0, conflict: false }",
        "root path=[] PutMap { key: \"map\", value: Object(map), obj: 1@0, conflict: false }",
        "1@0 path=[root.Map(\"map\")] PutMap { key: \"list\", value: Object(list), obj: 2@0, conflict: false }",
        "2@0 path=[root.Map(\"map\"), 1@0.Map(\"list\")] Insert { index: 0, values: [{ value: Int(7), obj: 3@0, conflict: false }] }",
    });
    const patches = rendered.slice();
    try testing.expect(owner.idToExid(OpId.init(1, 0)).eql(patches[1].action.put_map.obj));
    try testing.expect(owner.idToExid(OpId.init(1, 0)).eql(patches[2].obj));
    try testing.expect(owner.idToExid(OpId.init(2, 0)).eql(patches[2].action.put_map.obj));
    try testing.expect(owner.idToExid(OpId.init(2, 0)).eql(patches[3].obj));
    try testing.expect(owner.idToExid(OpId.init(1, 0)).eql(patches[3].path[1].obj));
    const first_insert = patches[3].action.insert.values.get(0).?;
    try testing.expect(owner.idToExid(OpId.init(3, 0)).eql(first_insert.obj));
}

fn clonedIndexedSeedThenFree(gpa: Allocator, owner: *const @import("doc.zig").Document) !void {
    var log = PatchLog.active(gpa);
    defer log.deinit();
    log.putMap(
        internalObj(OpId.init(2, 0)),
        "k",
        .{ .scalar = sval("v") },
        OpId.init(3, 0),
        false,
        false,
    );
    var hint: PathMap = .{};
    try hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 0)),
        .prop = .{ .key = "child" },
        .parent = .root,
    });
    log.pathHint(hint);
    var cloned = try log.cloneAndRebind(gpa, owner.patchIdentity());
    defer cloned.deinit();
    log.deinit();
    log = PatchLog.inactive(gpa);
    var rendered = try owner.makePatches(&cloned);
    defer rendered.deinit();
    try expectPatches(testing.allocator, &rendered, &.{
        "2@0 path=[root.Map(\"child\")] PutMap { key: \"k\", value: Str(\"v\"), obj: 3@0, conflict: false }",
    });
    try testing.expect(owner.idToExid(OpId.init(2, 0)).eql(rendered.slice()[0].obj));
}

test "indexed seed export owns cloned paths under allocation refusals and rejects absent actors" {
    // A real owner's actor table is valid, but it has no child to reconstruct
    // the supplied path. Sweep copying and rendering, not fixture-only .id IDs.
    const Document = @import("doc.zig").Document;
    const Transaction = @import("transact.zig").Transaction;
    const gpa = testing.allocator;
    var owner = try Document.init(gpa, testing.io);
    defer owner.deinit();
    owner.setActorId(.{ .bytes = "a" });
    var tx = try Transaction.open(gpa, &owner);
    defer tx.deinitClosed();
    _ = try tx.put(.root, .{ .key = "owned" }, .{ .bool_value = true });
    var committed = try tx.commitWith(.{ .time = 0 });
    defer committed.deinit(gpa);
    try testing.checkAllAllocationFailures(gpa, clonedIndexedSeedThenFree, .{&owner});

    // Canonicalization must restore ordering for mixed seeds and preserve the
    // already-public entry when an indexed entry names that same object.
    var mixed = PatchLog.active(gpa);
    defer mixed.deinit();
    mixed.putMap(
        internalObj(OpId.init(3, 0)),
        "k",
        .{ .scalar = sval("v") },
        OpId.init(4, 0),
        false,
        false,
    );
    var mixed_hint: PathMap = .{};
    errdefer mixed_hint.deinit(gpa);
    try mixed_hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 0)),
        .prop = .{ .key = "shadow" },
        .parent = .root,
    });
    try mixed_hint.put(gpa, .{
        .obj = internalObj(OpId.init(3, 0)),
        .prop = .{ .key = "leaf" },
        .parent = internalObj(OpId.init(2, 0)),
    });
    try mixed_hint.put(gpa, .{
        .obj = owner.idToExid(OpId.init(1, 0)),
        .prop = .{ .key = "earlier" },
        .parent = .root,
    });
    try mixed_hint.put(gpa, .{
        .obj = owner.idToExid(OpId.init(2, 0)),
        .prop = .{ .key = "child" },
        .parent = .root,
    });
    mixed.pathHint(mixed_hint);
    mixed_hint = .{};
    var mixed_rendered = try owner.makePatches(&mixed);
    defer mixed_rendered.deinit();
    try expectPatches(gpa, &mixed_rendered, &.{
        "3@0 path=[root.Map(\"child\"), 2@0.Map(\"leaf\")] PutMap { key: \"k\", value: Str(\"v\"), obj: 4@0, conflict: false }",
    });

    var invalid = PatchLog.active(gpa);
    defer invalid.deinit();
    var hint: PathMap = .{};
    try hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 1)),
        .prop = .{ .key = "absent" },
        .parent = .root,
    });
    invalid.pathHint(hint);
    try testing.expectError(error.InvalidActorIndex, owner.makePatches(&invalid));
    hint = .{};
    try hint.put(gpa, .{
        .obj = internalObj(OpId.init(2, 0)),
        .prop = .{ .key = "absent-parent" },
        .parent = internalObj(OpId.init(3, 1)),
    });
    invalid.pathHint(hint);
    try testing.expectError(error.InvalidActorIndex, owner.makePatches(&invalid));
    try testing.expectEqual(@as(usize, 1), owner.ops.actors.items.len);
}

// ── test_mark_patches.rs ──────────────────────────────────────────────────────
//
// One test upstream, and it is the one that says what a **mark** looks like on
// the wire: an operation a caller never sees as an operation, arriving as a
// `PatchAction::Mark` carrying the runs it covers. It is here rather than in
// [`doc.zig`](doc.zig) because the thing under test is the patch stream this
// file builds.
//
// The port's [`TestDoc`] cannot answer it — it has no marks and no text — so
// this drives a real document and reads the stream through
// [`AutoCommit.diffIncremental`](autocommit.zig).

const automod = @import("autocommit.zig");

test "mark_patches: a mark over the last character of a text object arrives as one mark patch" {
    const gpa = testing.allocator;

    var doc1 = try automod.AutoCommit.init(gpa, std.testing.io);
    defer doc1.deinit();
    try doc1.setActorId(.{ .bytes = "0123456789abcdef" });
    const text = try doc1.putObject(.root, .{ .key = "text" }, .text);
    try doc1.spliceText(text, 0, 0, "sample");
    const heads_before = try doc1.getHeads(gpa);
    defer gpa.free(heads_before);

    const saved = try doc1.save(gpa);
    defer gpa.free(saved);
    var doc2 = try automod.AutoCommit.load(gpa, std.testing.io, saved, doc1.textEncoding());
    defer doc2.deinit();

    // `ExpandMark::After` upstream (`test_mark_patches.rs`:19`).
    try doc1.mark(text, 5, 6, "bold", .after, .{ .bool_value = true });

    // Pop the patches, so the second read is about the mark alone
    // (`test_mark_patches.rs`:24`). The first read is the whole document, and it
    // is what moves the cursor — the half of `diff_incremental` that makes the
    // second read answer "what did this document just learn".
    var popped = try doc2.diffIncremental(gpa);
    defer popped.deinit();

    const after = try doc1.saveAfter(gpa, heads_before);
    defer gpa.free(after);
    _ = try doc2.loadIncremental(gpa, after);

    var patches = try doc2.diffIncremental(gpa);
    defer patches.deinit();

    // **The whole patch, as one line.** Upstream compares `patch.obj`,
    // `patch.path`, the action's variant and `mark.name()`
    // (`test_mark_patches.rs`:33-40`); the literal pins the run's `value`,
    // `start` and `end` as well, which is the other half of what a mark patch
    // says. A mark patch on the root, or one run over the whole object, passes
    // upstream's assertion and fails this one.
    try expectPatches(gpa, &patches, &.{
        "1@0 path=[root.Map(\"text\")] Mark { marks: [{ name: \"bold\", value: Bool(true), start: 5, end: 6 }] }",
    });

    const patch = patches.slice()[0];
    try testing.expect(patch.obj.eql(text));
    try testing.expectEqual(@as(usize, 1), patch.path.len);
    try testing.expect(patch.path[0].obj.eql(.root));
    try testing.expect(patch.path[0].prop == .key);
    try testing.expectEqualStrings("text", patch.path[0].prop.key);

    switch (patch.action) {
        .mark => |a| {
            try testing.expectEqual(@as(usize, 1), a.marks.len);
            try testing.expectEqualStrings("bold", a.marks[0].name);
            try testing.expectEqual(@as(usize, 5), a.marks[0].start);
            try testing.expectEqual(@as(usize, 6), a.marks[0].end);
            try testing.expect(a.marks[0].value.eql(.{ .bool_value = true }));
        },
        else => return error.TestUnexpectedResult,
    }
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **This section is a port of `$AUTOMERGE_REF/rust/automerge/tests/
//   test_mark_patches.rs`, which holds exactly one test.** It is ported
//   case-for-case and there is no gap to write down.
//
// * **The upstream test drives two documents and so does this one.** It is
//   `AutoCommit::load(&doc1.save())` followed by `load_incremental`
//   (`test_mark_patches.rs`:14`, `:27`) that makes the second document's patch
//   stream come from *recorded* events rather than from a walk over two heads
//   — the only path that answers "what did this document just learn", and what
//   [`AutoCommit.diffIncremental`](autocommit.zig) reaches through `batch.zig`'s
//   `applyChangesBatchToSink`.
//
// * **`PatchBuilder.seen` is keyed by `ExId` and `std.hash.autoHash` can no
//   longer key it**, because the port's `ExId` has a variant that borrows an
//   actor's bytes and `autoHash` refuses a key it cannot hash unambiguously
//   (`std/hash/auto_hash.zig`:187). `ExIdContext` is the replacement, and it
//   hashes each identity domain separately. Named keys use the full public
//   counter and actor bytes; cached actor indices do not identify actors.
//   Table-local `.id` keys are distinct from exported `.named` keys.
//   The builder exports cache inputs using the document's authoritative
//   actor table before matching them.

test "native text units retain split UTF8 and UTF16 sequences" {
    // Each encoded unit remains independently editable, even inside a scalar.
    for ([_]TextEncoding{ .utf8_code_unit, .utf16_code_unit }) |enc| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var text = try ConcreteTextValue.init(arena.allocator(), if (enc == .utf8_code_unit) "é" else "😀", enc);
        try text.splice(1, "X");
        try testing.expectEqual(@as(usize, 3), text.len());
        const rendered = try text.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("�X�", rendered);
        try text.remove(1);
        try testing.expectEqual(@as(usize, 2), text.len());
        try text.remove(0);
        const remainder = try text.makeString(testing.allocator);
        defer testing.allocator.free(remainder);
        try testing.expectEqualStrings("�", remainder);
    }
}

test "native text units preserve stored grapheme boundaries after splice" {
    // Appending a combining cluster must not resegment the existing element.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var text = try ConcreteTextValue.init(arena.allocator(), "a", .grapheme_cluster);
    try text.splice(1, "\u{301}");
    try testing.expectEqual(@as(usize, 2), text.len());
    try text.remove(0);
    const rendered = try text.makeString(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("\u{301}", rendered);
}

test "native text units failed splice retains editable owned state" {
    // Observe with a nonfailing allocator, then reuse the same owner after OOM.
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var text = try ConcreteTextValue.init(gpa, "a", enc);
        defer text.deinit();
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, text.splice(0, "😀" ** 64));
        try testing.expectEqual(@as(usize, 1), text.len());
        const observed = try text.makeString(testing.allocator);
        defer testing.allocator.free(observed);
        try testing.expectEqualStrings("a", observed);
        failing.fail_index = std.math.maxInt(usize);
        try text.splice(0, "b");
        const reused = try text.makeString(testing.allocator);
        defer testing.allocator.free(reused);
        try testing.expectEqualStrings("ba", reused);
    }
}

test "external patch log compatibility uses actors rather than document identity" {
    // Independently allocated documents can offer the same actor table.
    const a = [_]ActorId{ActorId.init("a")};
    const b = [_]ActorId{ActorId.init("b")};
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var log = PatchLog.active(failing.allocator());
    defer log.deinit();
    try log.bind(1, &a);
    log.putMap(.root, "owned", .{ .scalar = .{ .bool_value = true } }, opId(1, 0), false, false);
    const actor_bytes = log.actors.items[0].bytes.ptr;
    const allocation_index = failing.alloc_index;
    failing.fail_index = allocation_index;
    try log.validateActors(&a);
    try log.bind(2, &a);
    try testing.expectEqual(@as(?u64, 2), log.identity);
    try testing.expectEqual(actor_bytes, log.actors.items[0].bytes.ptr);
    try testing.expectEqual(allocation_index, failing.alloc_index);
    try testing.expectError(error.PatchLogMismatch, log.validateActors(&b));
    try testing.expectError(error.PatchLogMismatch, log.bind(3, &b));
    try testing.expectEqual(@as(?u64, 2), log.identity);
    try testing.expectEqual(@as(usize, 1), log.events.items.len);
    try testing.expectEqual(actor_bytes, log.actors.items[0].bytes.ptr);
    try testing.expect(!failing.has_induced_failure);
}

test "actor mismatch after a prospective insertion refuses before allocation or mutation" {
    // A scan can accept an insertion before encountering a later mismatch.
    // Neither the insertion nor its ID shifts may escape a refused preflight.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var log = try publishHandshakeTarget(failing.allocator());
    defer log.deinit();
    const offered = [_]ActorId{ ActorId.init("@"), ActorId.init("d") };
    const allocation_index = failing.alloc_index;
    const resize_index = failing.resize_index;
    const actors_ptr = log.actors.items.ptr;
    failing.fail_index = allocation_index;
    failing.resize_fail_index = resize_index;
    try testing.expectError(error.PatchLogMismatch, log.validateActors(&offered));
    try testing.expectError(error.PatchLogMismatch, log.bind(74, &offered));
    try testing.expectError(error.PatchLogMismatch, log.bindBegin(74, &offered, 1, 0));
    try testing.expectEqual(allocation_index, failing.alloc_index);
    try testing.expectEqual(resize_index, failing.resize_index);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(?u64, 73), log.identity);
    try testing.expectEqual(actors_ptr, log.actors.items.ptr);
    try testing.expect(log.checkpoint == null);
    try testing.expect(log.speculative_actor == null);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try publishHandshakeOriginal(&log);
}

test "actor migration retains trailing actors and replays both root producers" {
    // Rust's loop stops at the offered prefix, not at the old table's end
    // (patches/patch_log.rs:634-658). The retained producer still names B.
    const b = [_]ActorId{ActorId.init("b")};
    const a = [_]ActorId{ActorId.init("a")};
    var log = PatchLog.active(testing.allocator);
    defer log.deinit();
    try log.bind(1, &b);
    const b_bytes = log.actors.items[0].bytes.ptr;
    log.putMap(.root, "owned", .{ .scalar = .{ .bool_value = true } }, opId(1, 0), false, false);
    var stage = try log.beginBatch();
    defer stage.deinit();
    try stage.bind(2, &a);
    stage.putMap(.root, "added", .{ .scalar = .{ .int = 7 } }, opId(2, 0), false, false);
    try stage.preparePublish(&log);
    stage.publish(&log);
    try testing.expectEqual(@as(?u64, 2), log.identity);
    try testing.expectEqual(@as(usize, 2), log.actors.items.len);
    try testing.expectEqualStrings("a", log.actors.items[0].bytes);
    try testing.expectEqualStrings("b", log.actors.items[1].bytes);
    const doc = TestDoc{};
    var patches = try log.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(testing.allocator, &patches, &.{
        "root path=[] PutMap { key: \"owned\", value: Bool(true), obj: 1@1, conflict: false }",
        "root path=[] PutMap { key: \"added\", value: Int(7), obj: 2@0, conflict: false }",
    });
    // Prefix-only reuses do not allocate or replace even the retained bytes.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var direct = PatchLog.active(failing.allocator());
    defer direct.deinit();
    try direct.bind(1, &b);
    const direct_b = direct.actors.items[0].bytes.ptr;
    try direct.migrateActors(&a);
    try testing.expectEqual(direct_b, direct.actors.items[1].bytes.ptr);
    const allocation_index = failing.alloc_index;
    failing.fail_index = allocation_index;
    try direct.validateActors(&a);
    try direct.bind(2, &a);
    try direct.migrateActors(&.{});
    try testing.expectEqual(allocation_index, failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
    // The staged publication owns its copied actor bytes independently.
    try testing.expect(log.actors.items[1].bytes.ptr != b_bytes);
}
test "actor migration and transaction opening allocation refusals retain caller log" {
    // Exercise checkpoint copies and insertion buffers without touching the
    // original event, expose, completed-view, or path-cache ownership.
    for ([_]bool{ false, true }) |transaction| {
        var refusal_index: usize = 0;
        while (true) : (refusal_index += 1) {
            var failing = testing.FailingAllocator.init(testing.allocator, .{});
            var log = try publishHandshakeTarget(failing.allocator());
            defer log.deinit();
            const actors_ptr = log.actors.items.ptr;
            const a_bytes = log.actors.items[0].bytes.ptr;
            const c_bytes = log.actors.items[1].bytes.ptr;
            failing.fail_index = failing.alloc_index + refusal_index;
            failing.resize_fail_index = 0;
            const result = if (transaction)
                log.bindBegin(74, &publish_handshake_new_actors, 1, 1)
            else
                log.bind(74, &publish_handshake_new_actors);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |_| {
                try testing.expect(refusal_index > 0);
                try testing.expectEqual(@as(?u64, 74), log.identity);
                try testing.expectEqual(a_bytes, log.actors.items[0].bytes.ptr);
                try testing.expectEqual(c_bytes, log.actors.items[2].bytes.ptr);
                if (transaction) {
                    log.rollbackTransaction(&publish_handshake_old_actors);
                    try testing.expectEqual(@as(?u64, 74), log.identity);
                    try publishHandshakeOriginal(&log);
                }
                break;
            } else |failure| {
                try testing.expectEqual(error.OutOfMemory, failure);
                try testing.expect(log.checkpoint == null);
                try testing.expect(log.speculative_actor == null);
                try testing.expectEqual(@as(?u64, 73), log.identity);
                try testing.expectEqual(actors_ptr, log.actors.items.ptr);
                try testing.expectEqual(a_bytes, log.actors.items[0].bytes.ptr);
                try testing.expectEqual(c_bytes, log.actors.items[1].bytes.ptr);
                try publishHandshakeOriginal(&log);
            }
        }
    }
}

test "PatchLog merge accepts foreign metadata and retains the compatible actor tail" {
    const a = [_]ActorId{ActorId.init("a")};
    const ac = [_]ActorId{ ActorId.init("a"), ActorId.init("c") };
    var target = PatchLog.active(testing.allocator);
    defer target.deinit();
    try target.bind(1, &ac);
    target.putMap(.root, "old", .{ .scalar = sval("c") }, opId(1, 1), false, false);
    var other = PatchLog.active(testing.allocator);
    defer other.deinit();
    try other.bind(2, &a);
    other.putMap(.root, "new", .{ .scalar = sval("a") }, opId(2, 0), false, false);
    try target.merge(&other);
    try testing.expectEqual(@as(usize, 2), target.actors.items.len);
    try testing.expectEqualStrings("c", target.actors.items[1].bytes);
    try testing.expectEqual(@as(?u64, 2), other.identity);
    try testing.expectEqual(@as(usize, 1), other.events.items.len);
    const doc = TestDoc{};
    var patches = try target.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(testing.allocator, &patches, &.{
        "root path=[] PutMap { key: \"old\", value: Str(\"c\"), obj: 1@1, conflict: false }",
        "root path=[] PutMap { key: \"new\", value: Str(\"a\"), obj: 2@0, conflict: false }",
    });
    const b = [_]ActorId{ActorId.init("b")};
    var incompatible = PatchLog.active(testing.allocator);
    defer incompatible.deinit();
    try incompatible.bind(1, &b);
    try testing.expectError(error.PatchLogMismatch, target.merge(&incompatible));
    try testing.expectEqual(@as(usize, 2), target.events.items.len);
    try testing.expectEqual(@as(usize, 0), incompatible.events.items.len);
}

test "native text units patch coalescing retains incomplete encoded units" {
    // A consumer's patch must preserve a one-unit deletion inside a scalar.
    const doc: TestDoc = .{ .objs = &.{.{ .id = .root, .typ = .map }} };
    for ([_]TextEncoding{ .utf8_code_unit, .utf16_code_unit }) |enc| {
        var out = Patches.init(testing.allocator);
        defer out.deinit();
        var builder = PatchBuilder(TestDoc).init(
            &out,
            &doc,
            .{},
            testing.allocator,
            null,
            enc,
        );
        defer builder.deinit();
        try builder.spliceText(.root, 0, if (enc == .utf8_code_unit) "é" else "😀", null);
        try builder.deleteSeq(.root, 0, 1);
        try testing.expectEqual(@as(usize, 1), builder.patches.items.len);
        const text = builder.patches.items[0].action.splice_text.value;
        try testing.expectEqual(@as(usize, 1), text.len());
        const rendered = try text.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("�", rendered);
    }
}

test "native text units every splice allocation failure preserves original text" {
    // Cover conversion, node splitting, and rollback rather than one allocation.
    const Consumer = struct {
        fn run(gpa: Allocator, enc: TextEncoding) !void {
            var text = try ConcreteTextValue.init(gpa, "prefix😀suffix", enc);
            defer text.deinit();
            text.splice(3, "😀x" ** 64) catch |failure| {
                const observed = try text.makeString(testing.allocator);
                defer testing.allocator.free(observed);
                try testing.expectEqualStrings("prefix😀suffix", observed);
                try testing.expectEqual(enc.width("prefix😀suffix"), text.len());
                return failure;
            };
            try testing.expectEqual(
                enc.width("prefix😀suffix") + enc.width("😀x" ** 64),
                text.len(),
            );
        }
    };
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        try testing.checkAllAllocationFailures(testing.allocator, Consumer.run, .{enc});
    }
}

test "native text units self splice retains the original source" {
    for ([_]TextEncoding{
        .utf8_code_unit, .utf16_code_unit, .unicode_code_point, .grapheme_cluster,
    }) |enc| {
        var text = try ConcreteTextValue.init(testing.allocator, "ab", enc);
        defer text.deinit();
        try text.spliceTextValue(1, &text);
        try testing.expectEqual(@as(usize, 4), text.len());
        try testing.expectEqual(enc, text.encoding());
        const rendered = try text.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("aabb", rendered);
    }
}

test "native text units duplicate and compare split sequences without rendering" {
    for ([_]TextEncoding{ .utf8_code_unit, .utf16_code_unit }) |enc| {
        var text = try ConcreteTextValue.init(
            testing.allocator,
            if (enc == .utf8_code_unit) "é" else "😀",
            enc,
        );
        defer text.deinit();
        try text.remove(0);
        var copy = try text.dup(testing.allocator);
        defer copy.deinit();
        try testing.expect(ConcreteTextValue.eql(text, copy));
        try testing.expectEqual(enc, copy.encoding());
        try testing.expect(copy.get(0) != null);
        try testing.expect(copy.get(1) == null);
        const unit = copy.get(0).?;
        switch (enc) {
            .utf8_code_unit => try testing.expectEqual(@as(u8, 0xa9), unit.utf8_code_unit),
            .utf16_code_unit => try testing.expectEqual(@as(u16, 0xde00), unit.utf16_code_unit),
            else => unreachable,
        }
        try text.splice(0, "X");
        try testing.expect(!ConcreteTextValue.eql(text, copy));
        const rendered = try copy.makeString(testing.allocator);
        defer testing.allocator.free(rendered);
        try testing.expectEqualStrings("�", rendered);
    }
}

test "native text units copying preserves stored grapheme segmentation" {
    var source = try ConcreteTextValue.init(testing.allocator, "a", .grapheme_cluster);
    defer source.deinit();
    try source.splice(1, "\u{301}");
    var copy = try source.dup(testing.allocator);
    defer copy.deinit();
    var target = try ConcreteTextValue.init(testing.allocator, "z", .grapheme_cluster);
    defer target.deinit();
    try target.spliceTextValue(1, &source);
    try testing.expectEqual(@as(usize, 2), copy.len());
    try testing.expectEqual(@as(usize, 3), target.len());
    try testing.expect(ConcreteTextValue.eql(source, copy));
    try source.remove(0);
    try testing.expectEqualStrings("a", copy.get(0).?.grapheme_cluster);
    try testing.expectEqualStrings("\u{301}", copy.get(1).?.grapheme_cluster);
    try target.remove(1);
    const rendered = try target.makeString(testing.allocator);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("z\u{301}", rendered);
}

const publish_handshake_old_actors = [_]ActorId{ ActorId.init("a"), ActorId.init("c") };
const publish_handshake_new_actors = [_]ActorId{
    ActorId.init("a"), ActorId.init("b"), ActorId.init("c"),
};
const publish_handshake_heads = [_]ChangeHash{.{ .bytes = [_]u8{0x63} ** 32 }};

fn publishHandshakeDoc(comptime actor: ActorIdx) TestDoc {
    const empty_objects = comptime blk: {
        var objects: [16]TestDoc.Obj = undefined;
        for (&objects, 0..) |*object, index| {
            object.* = .{
                .id = .{ .id = opId(@intCast(40 + index), 1) },
                .typ = .map,
                .parent = .root,
            };
        }
        break :blk objects;
    };
    // The returned document borrows this fixture, so every object and nested
    // item array must have static storage rather than this call's stack.
    const objects = comptime ([_]TestDoc.Obj{
        .{ .id = .root, .typ = .map, .map_items = &.{
            .{
                .key = "child",
                .value = .{ .object = .map },
                .id = opId(10, actor),
                .conflict = false,
            },
            .{
                .key = "cached",
                .value = .{ .object = .map },
                .id = opId(20, actor),
                .conflict = false,
            },
        } },
        .{
            .id = .{ .id = opId(10, actor) },
            .typ = .map,
            .parent = .root,
            .map_items = &.{.{
                .key = "inner",
                .value = .{ .scalar = sval("exposed") },
                .id = opId(11, actor),
                .conflict = false,
            }},
        },
        .{ .id = .{ .id = opId(20, actor) }, .typ = .map, .parent = .root },
    } ++ empty_objects);
    return .{ .objs = &objects };
}

fn publishHandshakeCompleted(log: *PatchLog, text: []const u8) !void {
    const doc = TestDoc{};
    var source = PatchLog.active(log.gpa);
    defer source.deinit();
    source.splice(.root, 0, text, null);
    var patches = try source.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try log.completed.appendFrom(&patches);
}

fn publishHandshakeTarget(gpa: Allocator) !PatchLog {
    var target = PatchLog.active(gpa);
    errdefer target.deinit();
    try target.bind(73, &publish_handshake_old_actors);
    target.heads = try gpa.dupe(ChangeHash, &publish_handshake_heads);
    try publishHandshakeCompleted(&target, "old😀");
    target.putMap(.root, "old", .{ .scalar = sval("original") }, opId(1, 1), false, false);
    target.putMap(.root, "child", .{ .object = .map }, opId(10, 1), false, true);
    target.putMap(
        internalObj(opId(20, 1)),
        "value",
        .{ .scalar = sval("cached") },
        opId(21, 1),
        false,
        false,
    );
    var hint: PathMap = .{};
    errdefer hint.deinit(gpa);
    try hint.put(gpa, .{
        .obj = internalObj(opId(20, 1)),
        .parent = .root,
        .prop = .{ .key = "cached-path" },
    });
    try hint.put(gpa, .{
        .obj = internalObj(opId(10, 1)),
        .parent = .root,
        .prop = .{ .key = "child" },
    });
    target.pathHint(hint);
    return target;
}

fn publishHandshakeStage(target: *PatchLog) !PatchLog {
    var stage = try target.beginBatch();
    errdefer stage.deinit();
    try stage.bind(73, &publish_handshake_new_actors);
    try publishHandshakeCompleted(&stage, "new😀");
    stage.putMap(.root, "new", .{ .scalar = sval("published") }, opId(2, 1), false, false);
    // Enough real object events also exercise both publication reservations.
    for (0..16) |index| {
        stage.putMap(
            .root,
            "object",
            .{ .object = .map },
            opId(@intCast(40 + index), 1),
            false,
            true,
        );
    }
    return stage;
}

fn publishHandshakeOwner(log: *const PatchLog, actors: []const ActorId) !void {
    try log.validateActors(actors);
    try testing.expectEqual(actors.len, log.actors.items.len);
    for (actors, log.actors.items) |expected, actual| {
        try testing.expectEqualStrings(expected.bytes, actual.bytes);
    }
    const heads = log.heads orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), heads.len);
    try testing.expectEqualSlices(u8, &publish_handshake_heads[0].bytes, &heads[0].bytes);
}

fn publishHandshakeOriginal(target: *PatchLog) !void {
    try publishHandshakeOwner(target, &publish_handshake_old_actors);
    // Rendering consumes the one-use path seed (patch_log.rs:513). Observe
    // a deep copy so repeated atomicity checks do not mutate either owner.
    var observed = try target.cloneAndRebind(target.gpa, target.identity.?);
    defer observed.deinit();
    const doc = publishHandshakeDoc(1);
    var patches = try observed.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try expectPatches(testing.allocator, &patches, &.{
        "root path=[] SpliceText { index: 0, value: \"old😀\", marks: none }",
        "root path=[] PutMap { key: \"old\", value: Str(\"original\"), obj: 1@1, conflict: false }",
        "root path=[] PutMap { key: \"child\", value: Object(map), obj: 10@1, conflict: false }",
        "10@1 path=[root.Map(\"child\")] PutMap { key: \"inner\", value: Str(\"exposed\"), obj: 11@1, conflict: false }",
        "20@1 path=[root.Map(\"cached-path\")] PutMap { key: \"value\", value: Str(\"cached\"), obj: 21@1, conflict: false }",
    });
    // These public operation IDs still resolve to the original actor bytes.
    try testing.expectEqualStrings(
        "c",
        target.actors.items[patches.slice()[1].action.put_map.obj.id.actor].bytes,
    );
}

fn publishHandshakeStageOwned(stage: *PatchLog) !void {
    try testing.expect(stage.isActive());
    try publishHandshakeOwner(stage, &publish_handshake_new_actors);
    const doc = publishHandshakeDoc(2);
    var patches = try stage.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 18), patches.len());
    const text = try patches.slice()[0].action.splice_text.value.makeString(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("new😀", text);
    try testing.expectEqualStrings("new", patches.slice()[1].action.put_map.key);
    try testing.expect(patches.slice()[1].action.put_map.obj.eql(.{ .id = opId(2, 1) }));
    for (patches.slice()[2..], 0..) |patch, index| {
        try testing.expectEqualStrings("object", patch.action.put_map.key);
        try testing.expect(patch.action.put_map.obj.eql(.{ .id = opId(@intCast(40 + index), 1) }));
    }
}

test "canonical PatchLog handshake abandoned preflight preserves original consumer state" {
    // Preparing a middle actor insertion must not publish any part of it.
    var target = try publishHandshakeTarget(testing.allocator);
    defer target.deinit();
    {
        var stage = try publishHandshakeStage(&target);
        defer stage.deinit();
        try stage.preparePublish(&target);
        try publishHandshakeStageOwned(&stage);
    }
    try publishHandshakeOriginal(&target);
}

test "canonical PatchLog handshake every preflight allocation refusal preserves both owners" {
    // Refuse only preflight allocations, then disarm before observing each owner.
    var refusal_index: usize = 0;
    while (true) : (refusal_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var target = try publishHandshakeTarget(gpa);
        defer target.deinit();
        var stage = try publishHandshakeStage(&target);
        defer stage.deinit();
        failing.fail_index = failing.alloc_index + refusal_index;
        failing.resize_fail_index = 0;
        const result = stage.preparePublish(&target);
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        if (result) |_| {
            try testing.expect(refusal_index > 0);
            try publishHandshakeOriginal(&target);
            try publishHandshakeStageOwned(&stage);
            break;
        } else |allocation_error| {
            try testing.expectEqual(error.OutOfMemory, allocation_error);
            try publishHandshakeOriginal(&target);
            try publishHandshakeStageOwned(&stage);
        }
    }
}

test "canonical PatchLog handshake publication allocates nothing and preserves mapped event order" {
    // Arm both refusal channels only after the fallible handshake has succeeded.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var target = try publishHandshakeTarget(failing.allocator());
    defer target.deinit();
    var stage = try publishHandshakeStage(&target);
    defer stage.deinit();
    try stage.preparePublish(&target);
    const allocation_index = failing.alloc_index;
    const resize_index = failing.resize_index;
    failing.fail_index = allocation_index;
    failing.resize_fail_index = resize_index;
    stage.publish(&target);
    try testing.expectEqual(allocation_index, failing.alloc_index);
    try testing.expectEqual(resize_index, failing.resize_index);
    try testing.expect(!failing.has_induced_failure);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try testing.expect(!stage.isActive());
    try publishHandshakeOwner(&target, &publish_handshake_new_actors);
    const doc = publishHandshakeDoc(2);
    var patches = try target.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 23), patches.len());
    try expectPatches(testing.allocator, &target.completed, &.{
        "root path=[] SpliceText { index: 0, value: \"old😀\", marks: none }",
        "root path=[] SpliceText { index: 0, value: \"new😀\", marks: none }",
    });
    try testing.expectEqualStrings("old", patches.slice()[2].action.put_map.key);
    try testing.expect(patches.slice()[2].action.put_map.obj.eql(.{ .id = opId(1, 2) }));
    try testing.expectEqualStrings("child", patches.slice()[3].action.put_map.key);
    try testing.expect(patches.slice()[3].action.put_map.obj.eql(.{ .id = opId(10, 2) }));
    try testing.expectEqualStrings("new", patches.slice()[4].action.put_map.key);
    try testing.expect(patches.slice()[4].action.put_map.obj.eql(.{ .id = opId(2, 1) }));
    for (patches.slice()[5..21], 0..) |patch, index| {
        try testing.expectEqualStrings("object", patch.action.put_map.key);
        try testing.expect(patch.action.put_map.obj.eql(.{ .id = opId(@intCast(40 + index), 1) }));
    }
    const exposed = patches.slice()[21];
    try testing.expect(exposed.obj.eql(.{ .id = opId(10, 2) }));
    try testing.expectEqualStrings("exposed", exposed.action.put_map.value.scalar.str);
    try testing.expect(exposed.action.put_map.obj.eql(.{ .id = opId(11, 2) }));
    const cached = patches.slice()[22];
    try testing.expect(cached.obj.eql(.{ .id = opId(20, 2) }));
    try testing.expectEqualStrings("cached", cached.path[0].prop.key);
    try testing.expect(cached.action.put_map.obj.eql(.{ .id = opId(21, 2) }));
    try testing.expectEqualStrings("c", target.actors.items[2].bytes);
    try testing.expectEqualStrings("b", target.actors.items[1].bytes);
}

fn publishHandshakeCloneCheckpoint(gpa: Allocator) !void {
    var original = try publishHandshakeTarget(gpa);
    defer original.deinit();
    try original.bindBegin(73, &publish_handshake_new_actors, 1, 1);
    original.splice(internalObj(opId(20, 2)), 0, "discard😀", null);
    if (original.oom) return error.OutOfMemory;
    var cloned = try original.cloneAndRebind(gpa, 74);
    defer cloned.deinit();
    original.rollbackTransaction(&publish_handshake_old_actors);
    cloned.rollbackTransaction(&publish_handshake_old_actors);
    original.deinit();
    original = PatchLog.inactive(gpa);
    try cloned.validateActors(&publish_handshake_old_actors);
    try testing.expectEqual(@as(?u64, 74), cloned.identity);
    const doc = publishHandshakeDoc(1);
    var patches = try cloned.makePatches(TestDoc, &doc);
    defer patches.deinit();
    cloned.deinit();
    cloned = PatchLog.inactive(gpa);
    try testing.expectEqual(@as(usize, 5), patches.len());
    var text = &patches.items.items[0].action.splice_text.value;
    try testing.expectEqual(@as(usize, 4), text.len());
    try text.splice(text.len(), "!");
    const rendered = try text.makeString(gpa);
    defer gpa.free(rendered);
    try testing.expectEqualStrings("old😀!", rendered);
    try testing.expectEqualStrings("cached-path", patches.slice()[4].path[0].prop.key);
    try testing.expect(patches.slice()[4].action.put_map.obj.eql(.{ .id = opId(21, 1) }));
}

test "canonical PatchLog handshake cloned checkpoint owns completed native text through rollback" {
    // Sweep construction and cleanup as well as reading after both logs are freed.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        publishHandshakeCloneCheckpoint,
        .{},
    );
}

test "patch formatting retains full width named counters without resident conversion" {
    const named: ExId = .{ .named = .{
        .op = .{ .counter = std.math.maxInt(u64), .actor = 7 },
        .actor = .{ .bytes = "actor" },
    } };
    const rendered = try formatPatch(testing.allocator, .{
        .obj = named,
        .path = &.{},
        .action = .{ .delete_seq = .{ .index = 0, .length = 1 } },
    });
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        "18446744073709551615@7 path=[] DeleteSeq { index: 0, length: 1 }",
        rendered,
    );
}

test "patch values read high unsigned scalars with wrapping integer semantics" {
    const value: Value = .{ .scalar = .{ .uint = std.math.maxInt(u64) } };
    try testing.expectEqual(@as(i64, -1), value.asI64());
}

fn publishOriginPublished(target: *PatchLog) !void {
    try publishHandshakeOwner(target, &publish_handshake_new_actors);
    const doc = publishHandshakeDoc(2);
    var patches = try target.makePatches(TestDoc, &doc);
    defer patches.deinit();
    try testing.expectEqual(@as(usize, 23), patches.len());
    for ([_][]const u8{ "old😀", "new😀" }, patches.slice()[0..2]) |expected, patch| {
        const text = try patch.action.splice_text.value.makeString(testing.allocator);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(expected, text);
    }
    try testing.expectEqualStrings("old", patches.slice()[2].action.put_map.key);
    try testing.expectEqualStrings("original", patches.slice()[2].action.put_map.value.scalar.str);
    try testing.expect(patches.slice()[2].action.put_map.obj.eql(.{ .id = opId(1, 2) }));
    try testing.expectEqualStrings("child", patches.slice()[3].action.put_map.key);
    try testing.expect(patches.slice()[3].action.put_map.obj.eql(.{ .id = opId(10, 2) }));
    try testing.expectEqualStrings("new", patches.slice()[4].action.put_map.key);
    try testing.expectEqualStrings("published", patches.slice()[4].action.put_map.value.scalar.str);
    try testing.expect(patches.slice()[4].action.put_map.obj.eql(.{ .id = opId(2, 1) }));
    for (patches.slice()[5..21], 0..) |patch, index| {
        try testing.expectEqualStrings("object", patch.action.put_map.key);
        try testing.expect(patch.action.put_map.obj.eql(.{ .id = opId(@intCast(40 + index), 1) }));
    }
    const exposed = patches.slice()[21];
    try testing.expect(exposed.obj.eql(.{ .id = opId(10, 2) }));
    try testing.expectEqualStrings("child", exposed.path[0].prop.key);
    try testing.expectEqualStrings("exposed", exposed.action.put_map.value.scalar.str);
    try testing.expect(exposed.action.put_map.obj.eql(.{ .id = opId(11, 2) }));
    const cached = patches.slice()[22];
    try testing.expect(cached.obj.eql(.{ .id = opId(20, 2) }));
    try testing.expectEqualStrings("cached", cached.path[0].prop.key);
    try testing.expectEqualStrings("cached", cached.action.put_map.value.scalar.str);
    try testing.expect(cached.action.put_map.obj.eql(.{ .id = opId(21, 2) }));
    try testing.expectEqualStrings(
        "c",
        target.actors.items[patches.slice()[2].action.put_map.obj.id.actor].bytes,
    );
    try testing.expectEqualStrings(
        "b",
        target.actors.items[patches.slice()[4].action.put_map.obj.id.actor].bytes,
    );
}

test "PatchLog origin handshake publishes with actual stateless c allocator" {
    // The real stateless allocator has no context value that publication may inspect.
    var target = try publishHandshakeTarget(std.heap.c_allocator);
    defer target.deinit();
    var stage = try publishHandshakeStage(&target);
    defer stage.deinit();
    try stage.preparePublish(&target);
    try publishHandshakeOriginal(&target);
    try publishHandshakeStageOwned(&stage);
    stage.publish(&target);
    try testing.expect(!stage.isActive());
    try publishOriginPublished(&target);
}

test "PatchLog origin handshake refuses same identity foreign owner without changing either log" {
    // Same actors, metadata, and even a stateless allocator do not confer origin.
    var origin_allocator = testing.FailingAllocator.init(testing.allocator, .{});
    var foreign_allocator = testing.FailingAllocator.init(testing.allocator, .{});
    try publishForeignOriginGuard(origin_allocator.allocator(), foreign_allocator.allocator());
    try testing.expect(!origin_allocator.has_induced_failure);
    try testing.expect(!foreign_allocator.has_induced_failure);
    try publishForeignOriginGuard(std.heap.c_allocator, std.heap.c_allocator);
}

fn publishForeignOriginGuard(origin_gpa: Allocator, foreign_gpa: Allocator) !void {
    var origin = try publishHandshakeTarget(origin_gpa);
    defer origin.deinit();
    var foreign = try publishHandshakeTarget(foreign_gpa);
    defer foreign.deinit();
    var stage = try publishHandshakeStage(&origin);
    defer stage.deinit();
    try testing.expectEqual(origin.identity, foreign.identity);
    try testing.expectError(error.PatchLogMismatch, stage.preparePublish(&foreign));
    try testing.expect(stage.batch_origin == &origin);
    try testing.expect(stage.publish_completed == null);
    try publishHandshakeOriginal(&origin);
    try publishHandshakeOriginal(&foreign);
    try publishHandshakeStageOwned(&stage);
    try stage.preparePublish(&origin);
    const prepared = stage.publish_completed.?.items.items;
    // Refusal after a successful preflight preserves the original capability.
    try testing.expectError(error.PatchLogMismatch, stage.preparePublish(&foreign));
    try testing.expect(stage.batch_origin == &origin);
    try testing.expect(prepared.ptr == stage.publish_completed.?.items.items.ptr);
    try expectPatches(testing.allocator, &stage.publish_completed.?, &.{
        "root path=[] SpliceText { index: 0, value: \"old😀\", marks: none }",
        "root path=[] SpliceText { index: 0, value: \"new😀\", marks: none }",
    });
    try publishHandshakeOriginal(&origin);
    try publishHandshakeOriginal(&foreign);
    try publishHandshakeStageOwned(&stage);
    stage.publish(&origin);
    try testing.expect(!stage.isActive());
    try publishOriginPublished(&origin);
    try publishHandshakeOriginal(&foreign);
}

test "PatchLog cloned prepared batch owns data but cannot publish to original owner" {
    // Payload copies do not copy the exact-origin publication capability.
    var origin_allocator = testing.FailingAllocator.init(testing.allocator, .{});
    var clone_allocator = testing.FailingAllocator.init(testing.allocator, .{});
    try publishClonedOriginGuard(origin_allocator.allocator(), clone_allocator.allocator());
    try testing.expect(!origin_allocator.has_induced_failure);
    try testing.expect(!clone_allocator.has_induced_failure);
    try publishClonedOriginGuard(std.heap.c_allocator, std.heap.c_allocator);
}

fn publishClonedOriginGuard(origin_gpa: Allocator, clone_gpa: Allocator) !void {
    var origin = try publishHandshakeTarget(origin_gpa);
    defer origin.deinit();
    var stage = try publishHandshakeStage(&origin);
    defer stage.deinit();
    try stage.preparePublish(&origin);
    {
        var cloned = try stage.cloneAndRebind(clone_gpa, 73);
        defer cloned.deinit();
        try testing.expectError(error.PatchLogMismatch, cloned.preparePublish(&origin));
        try publishHandshakeOriginal(&origin);
        try publishHandshakeStageOwned(&stage);
        try publishHandshakeStageOwned(&cloned);
        stage.publish(&origin);
        // Both copies remain readable after the original stage is consumed.
        try publishHandshakeStageOwned(&cloned);
        try publishOriginPublished(&origin);
    }
    // Freeing the clone must not release the published payloads.
    try testing.expect(!stage.isActive());
    try publishOriginPublished(&origin);
}
