//! Mark values, and the fold that turns mark operations into a mark set
//! (`rust/automerge/src/marks.rs`).
//!
//! A mark is out-of-band information about a range of a sequence. The
//! motivating case is rich text, where each position carries at most one mark
//! of a given name; collaborators who set the same name to different values
//! over overlapping ranges get a consistent but arbitrary winner when the
//! document is read (`marks.rs:13-19`). The marks at one position are a
//! `MarkSet`, one value per name, and they are produced by folding the mark
//! operations that precede that position. That fold is `MarkStateMachine`, and
//! every text reader in the crate depends on it, so its rules are transcribed
//! one for one and each of them is cited below.
//!
//! Nothing in this file reads or writes storage. `MarkStateMachine` takes mark
//! operations and gives back a set; where those operations come from is the op
//! set's business. `NonDeletedMarks` is a borrowed view of visible marks
//! (`marks.rs:437-464`).
//!
//! ## The fold
//!
//! `MarkStateMachine` holds the marks that are open, sorted by op id, and the
//! set they currently resolve to (`marks.rs:242-247`). An op id orders by
//! counter first, then actor (`src/types.zig:163-170`), so "above" a mark means
//! "a mark with a higher op id": a later operation, or a concurrent one from a
//! higher-numbered actor. `mark_above` scans only the entries strictly above
//! the mark being decided on and `mark_below` only the entries below it
//! (`marks.rs:325-337`, `:339-353`), so the state behaves as a stack — the
//! nearest mark of the same name above shadows this one, the nearest below is
//! what this one restores to.
//!
//! `mark_begin` (`marks.rs:266-292`) writes the new value into the current set
//! only when no same-name mark sits above the insertion point, and then only
//! when the nearest same-name mark below holds a different value, or there is
//! none. `mark_end` (`marks.rs:294-319`) finds its begin at `id.prev()`,
//! removes it, and — only when no same-name mark is left above — restores the
//! value below or removes the name. Both return whether the current set
//! changed, which is what a text diff uses to decide a span boundary.
//!
//! Four cases are rules rather than consequences, so they are called out here
//! and each has a test:
//!
//! * An end that leaves a same-name mark above it changes nothing: the mark
//!   that remains decides the value from here on (`marks.rs:303`, the
//!   `mark_above` guard).
//! * An end whose nearest same-name mark below already holds the value being
//!   closed writes nothing and reports no change, because the set already says
//!   that (`marks.rs:305`).
//! * A begin whose id is already in the state is ignored outright
//!   (`marks.rs:269-272`); op ids are unique, so reaching that arm means the
//!   document is corrupt.
//! * An end whose `id.prev()` is not in the state is ignored
//!   (`marks.rs:296-299`). A mark end is written as the operation immediately
//!   after its begin, so this is likewise a corrupt document rather than
//!   something a caller does.
//!
//! ## The mark operations (FORMAT)
//!
//! A mark is two operations, both `action = 7` — `Action::Mark`
//! (`op_set2/types.rs:80-81`, durable code 7 from the table at
//! `op_set2/types.rs:99-112`; this port spells it `value.Action.mark`,
//! `src/value.zig:186`). Both are inserts into a text object, so each carries
//! its own op id and its own element id, and each contributes one row to every
//! op column. They differ only in the two mark columns and in the value column,
//! and the split is made by `OpType::decompose` (`op_set2/types.rs:405-430`):
//!
//! | op         | `mark_name` (col 10) | `expand` (col 9)  | value column     |
//! | ---------- | -------------------- | ----------------- | ---------------- |
//! | mark begin | `Some(name)`         | `expand.before()` | the mark's value |
//! | mark end   | `None`               | `expand.after()`  | `Null`           |
//!
//! Column ids are format: `EXPAND_COL_ID = 9` and `MARK_NAME_COL_ID = 10`
//! (`op_set2/columns.rs:624-625`), with the specs
//! `ColumnSpec::new_boolean(9)` and `ColumnSpec::new_string(10)`
//! (`op_set2/columns.rs:641-642`). The `mark_name` column is a
//! `Column<Option<String>>` and the `expand` column a `Column<bool>`
//! (`op_set2/columns.rs:32-33`), and neither is always written: they are
//! encoded with `encode_to_unless(.., None)` and `encode_to_unless(.., false)`
//! (`op_set2/change.rs:240-245`, `op_set2/change/collector.rs:491-492`), so a
//! change whose operations are all mark ends carries no mark-name column, and a
//! change whose marks all fail to expand carries no expand column. On load the
//! missing column is filled with `None` and `false` respectively
//! (`op_set2/columns.rs:289-292`), which is why a reader cannot tell an absent
//! column from a column of defaults.
//!
//! An unmark is not a third kind of operation. It is a mark *begin* whose value
//! is `Null`: `unmark` builds `Mark::new(name, ScalarValue::Null, start, end)`
//! and calls the same `mark` (`transaction/inner.rs:879-891`). So the value
//! column alone does not distinguish an unmark from a mark end — the
//! `mark_name` column does — and a `MarkSet` holding a name whose value is
//! `Null` is a removal tombstone rather than an active mark (`marks.rs:170-171`).
//!
//! Two invariants tie the two operations together, and both are read by this
//! file's fold:
//!
//! * The end operation's op id is the begin's op id plus one in the same
//!   actor. A mark is written as two back-to-back inserts
//!   (`transaction/inner.rs:827-857`), and every reader pairs them by
//!   `OpId::prev()`: here (`marks.rs:296`), in the op-set mark iterator
//!   (`op_set2/op_set/marks.rs:29-37`), and in the mark query state
//!   (`marks.rs:419-421`).
//! * The end must sort strictly after the begin in the op set. When both
//!   anchors resolve to the same op-set position — a zero-width mark, or a
//!   range inside one multi-width text element — the end is inserted at
//!   `begin.pos + 1` against `ElemId(begin.id)` instead
//!   (`transaction/inner.rs:404-430`, `:830-866`). Violating this inverts the
//!   mark index and yields a document that fails to reload.
//!
//! The mark index column is `MarkIdx = Start(OpId) | End(OpId)`
//! (`op_set2/op_set/mark_index.rs:12-16`), stored as a signed 64-bit: `Start`
//! is `((actor as i64) << 32) + ((counter as i64) & 0xffffffff)` and `End` is
//! its negation (`op_set2/op_set/mark_index.rs:25-36`, decoded by `load` at
//! `:36-52`). The `End` payload is the *begin's* op id, not the end's:
//! `Op::mark_index` passes `self.id.prev()` (`op_set2/op.rs:199`), and
//! `MarkData` is present only for a begin (`op_set2/op.rs:75-79`). That
//! column is the op set's; it is named here because the fold above is what the
//! column feeds.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const Error = err.Error;
const OpId = types.OpId;
const ScalarValue = value.ScalarValue;

/// A mark over a half-open range of a sequence: `start` and `end` are
/// positions, `end` exclusive (`marks.rs:20-26`).
///
/// The name is borrowed and the value is owned. Upstream's `SmolStr` is a
/// refcounted inline string; here the caller keeps the bytes alive for as long
/// as the mark, the same rule this port uses for `ActorId`
/// (`src/types.zig:79-88`).
pub const Mark = struct {
    start: usize,
    end: usize,
    name: []const u8,
    value: ScalarValue,

    /// A mark over `[start, end)` with the given name and value
    /// (`marks.rs:223-231`). The name is borrowed.
    pub fn init(name: []const u8, v: ScalarValue, start: usize, end: usize) Mark {
        return .{ .start = start, .end = end, .name = name, .value = v };
    }

    /// The name and value as the payload an operation carries
    /// (`marks.rs:35-41`). Upstream clones the name because `SmolStr` is
    /// refcounted; here there is nothing to clone.
    pub fn oldData(self: Mark) OldMarkData {
        return .{ .name = self.name, .value = self.value };
    }

    /// The single-mark set this mark describes (`marks.rs:48-52`). Upstream
    /// hands back an `Arc`; here the set is returned by value, because
    /// nothing in this file shares one.
    pub fn intoMarkSet(self: Mark, gpa: Allocator) Error!MarkSet {
        var set = MarkSet.init(gpa);
        errdefer set.deinit();
        try set.put(self.name, self.value);
        return set;
    }
};

/// A mark over a range, with the name and value in one payload
/// (`marks.rs:28-33`).
///
/// Upstream's `data` is a `Cow<'a, OldMarkData>`, which is a slice plus an
/// ownership rule; the port spells that as a borrowed slice. A borrowed
/// `data` is valid until its owner is; an owned one outlives everything that
/// borrows from the document.
pub const OldMark = struct {
    start: usize,
    end: usize,
    data: []const OldMarkData,
};

/// One coalesced run of one mark name: `index` is where the run starts, `len`
/// how many sequence positions it covers, and `value` the mark value over the
/// whole run (`marks.rs:55-60`).
pub const MarkAccItem = struct {
    index: usize,
    len: usize,
    value: ScalarValue,
};

/// The marks of one object, grouped by name and coalesced into runs
/// (`marks.rs:62-65`).
///
/// Upstream holds a `BTreeMap<SmolStr, Vec<MarkAccItem>>`. The port keeps the
/// same name-sorted order in a flat array of per-name run lists: a text object
/// carries one entry per distinct mark name, so the array stays short, and
/// every operation on it is an `O(n)` memmove instead of a tree descent.
/// Iteration order is observable — `MarkDiff::iter` merges two sets by name
/// and assumes both are sorted (`iter/spans.rs:342-387`) — and this reproduces
/// it exactly.
pub const MarkAccumulator = struct {
    /// The allocator the run lists are allocated with. It is retained for the
    /// accumulator's whole life, so it must outlive it; every name this
    /// accumulator stores is borrowed, not allocated with it.
    gpa: Allocator,
    /// The per-name run lists, sorted by name.
    names: std.ArrayList(NameRuns) = .empty,

    /// One mark name and the runs recorded under it. Published because
    /// [`MarkAccumulatorIter.names`] is a slice of these and an out-of-tree
    /// consumer holding that iterator can read the field.
    pub const NameRuns = struct {
        /// The mark name. Borrowed from whatever [`MarkAccumulator.add`] was
        /// given; the accumulator never frees it.
        name: []const u8,
        /// The coalesced runs of this name, in the order they were added.
        runs: std.ArrayList(MarkAccItem) = .empty,
    };

    /// An empty accumulator that stores `gpa` for its own run lists and for
    /// [`MarkAccumulator.deinit`]. Allocates nothing.
    pub fn init(gpa: Allocator) MarkAccumulator {
        return .{ .gpa = gpa };
    }

    /// Releases every per-name run list and the array of them. **The names are
    /// not freed** — they are borrowed, see [`MarkAccumulator.add`] — and no
    /// mark value owns bytes. The accumulator is `undefined` afterward and a
    /// second call is a double free.
    pub fn deinit(self: *MarkAccumulator) void {
        for (self.names.items) |*entry| entry.runs.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.* = undefined;
    }

    /// Adds the marks of `other` as a run of `len` positions starting at
    /// `index` (`marks.rs:87-102`).
    ///
    /// A run is coalesced into the previous one for the same name when the
    /// values are equal and the previous run ends exactly where this one
    /// starts. That is the whole reason a mark read back from the document
    /// comes out as one span rather than one span per position.
    ///
    /// **The names are retained by borrow, not copied.** A name already in the
    /// accumulator keeps pointing at the storage it was first added from, so
    /// every `MarkSet` fed here must outlive this accumulator and the marks it
    /// yields. A mark value is copied by value and carries no bytes.
    ///
    /// On `error.OutOfMemory` the entries appended before the refusal are
    /// kept; the accumulator stays usable and the marks already added are
    /// still there.
    pub fn add(
        self: *MarkAccumulator,
        index: usize,
        len: usize,
        other: *const MarkSet,
    ) Error!void {
        for (other.entries.items) |entry| {
            const runs = try self.entryFor(entry.name);
            if (runs.runs.items.len > 0) {
                const last = &runs.runs.items[runs.runs.items.len - 1];
                if (last.value.eql(entry.value) and last.index + last.len == index) {
                    last.len += len;
                    continue;
                }
            }
            try runs.runs.append(self.gpa, .{
                .index = index,
                .len = len,
                .value = entry.value,
            });
        }
    }

    /// The runs for `name`, appending an empty one if the name is new. This is
    /// `BTreeMap::entry(..).or_default()` (`marks.rs:89`).
    fn entryFor(self: *MarkAccumulator, name: []const u8) Error!*NameRuns {
        var lo: usize = 0;
        var hi: usize = self.names.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.names.items[mid].name, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &self.names.items[mid],
            }
        }
        try self.names.insert(self.gpa, lo, .{ .name = name });
        return &self.names.items[lo];
    }

    /// Every run as a `Mark`, unmark tombstones included (`marks.rs:68-74`).
    /// The iterator borrows the accumulator and is invalidated by the next
    /// [`MarkAccumulator.add`] or [`MarkAccumulator.deinit`], and a `Mark` it
    /// returns borrows the same names.
    pub fn intoIter(self: *const MarkAccumulator) MarkAccumulatorIter {
        return .{ .names = self.names.items };
    }

    /// Every run as a `Mark`, except those whose value is `Null`
    /// (`marks.rs:76-85`). This is what a document hands back when asked for
    /// the marks over a range (`automerge.rs:1630`, `op_set2/op_set.rs:1023`):
    /// an unmark is a tombstone, not a mark.
    ///
    /// The borrow rules are [`MarkAccumulator.intoIter`]'s.
    pub fn intoIterNoUnmark(self: *const MarkAccumulator) MarkAccumulatorIter {
        return .{ .names = self.names.items, .drop_nulls = true };
    }
};

/// The iterator over an accumulator's runs (`marks.rs:68-85`). Upstream spells
/// it as a `flat_map` over a `BTreeMap`; the two cursors are explicit here.
pub const MarkAccumulatorIter = struct {
    /// The per-name run lists being walked, borrowed from the accumulator
    /// [`MarkAccumulator.intoIter`] was made from. A `Mark` this returns
    /// borrows its `name` from the same place.
    names: []const MarkAccumulator.NameRuns,
    /// Which per-name run list we are walking.
    name_index: usize = 0,
    /// Which run within that list.
    item_index: usize = 0,
    /// `into_iter_no_unmark` drops the runs whose value is `Null`
    /// (`marks.rs:80`); `into_iter` keeps them.
    drop_nulls: bool = false,

    /// The next run as a `Mark`, or `null` at the end. The `Mark` borrows its
    /// name and copies its value; it is invalidated by the next
    /// [`MarkAccumulator.add`] on the accumulator this walks.
    pub fn next(self: *MarkAccumulatorIter) ?Mark {
        while (self.name_index < self.names.len) {
            const runs = self.names[self.name_index];
            const items = runs.runs.items;
            if (self.item_index < items.len) {
                const item = items[self.item_index];
                self.item_index += 1;
                if (self.drop_nulls) switch (item.value) {
                    .null_value => continue,
                    else => {},
                };
                return Mark.init(
                    runs.name,
                    item.value,
                    item.index,
                    item.index + item.len,
                );
            }
            self.name_index += 1;
            self.item_index = 0;
        }
        return null;
    }
};

/// The marks at one position: one value per mark name, sorted by name
/// (`marks.rs:105-108`).
///
/// A name whose value is `Null` is an unmark tombstone: the mark exists in the
/// document and has been removed, which is different from the name being
/// absent (`marks.rs:170-171`, `:180-187`).
///
/// `init` and `fromPairs` borrow payloads; `dup` owns independent payloads.
/// Every set owns its entries array and is released exactly once with `deinit`.
/// Assignment does not clone storage; use `dup` for an independent owner.
pub const MarkSet = struct {
    /// Retained for the set's whole lifetime and used for all its allocations.
    gpa: Allocator,
    /// The entries, sorted by name. See `MarkAccumulator` for why this is a
    /// flat array rather than a map.
    entries: std.ArrayList(Entry) = .empty,
    /// False for borrowed constructors; true for deep-owned duplicates.
    /// Do not change this after entries have been stored.
    owns_payloads: bool = false,

    /// One mark name and the value it holds here.
    pub const Entry = struct {
        /// Borrows source storage in a borrowed set, or the set's own allocation
        /// in an owned set. Invalidated by replacement, removal or teardown.
        name: []const u8,
        value: ScalarValue,
    };

    /// An empty set that stores `gpa` for its entries array. Allocates nothing.
    pub fn init(gpa: Allocator) MarkSet {
        return .{ .gpa = gpa };
    }

    /// A set holding one entry per pair, later pairs replacing earlier ones
    /// with the same name (`marks.rs:213-221`, the `FromIterator` impl).
    pub fn fromPairs(gpa: Allocator, pairs: []const Entry) Error!MarkSet {
        var set = MarkSet.init(gpa);
        errdefer set.deinit();
        for (pairs) |pair| try set.put(pair.name, pair.value);
        return set;
    }

    /// Releases the entries array and, for an owned set, all names and scalar
    /// payloads. The set is invalid afterward; release it exactly once.
    pub fn deinit(self: *MarkSet) void {
        if (self.owns_payloads) {
            for (self.entries.items) |*entry| {
                self.gpa.free(entry.name);
                entry.value.deinitOwned(self.gpa);
            }
        }
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Deep independent copy, including names, scalar bytes and actor IDs.
    /// The result retains `gpa` and must be released once with `deinit`.
    /// On allocation failure the source remains unchanged.
    pub fn dup(self: *const MarkSet, gpa: Allocator) Error!MarkSet {
        var out = MarkSet.init(gpa);
        out.owns_payloads = true;
        errdefer out.deinit();
        try out.entries.ensureTotalCapacity(gpa, self.entries.items.len);
        for (self.entries.items) |entry| {
            const name = try gpa.dupe(u8, entry.name);
            errdefer gpa.free(name);
            const scalar = try entry.value.dup(gpa);
            out.entries.appendAssumeCapacity(.{ .name = name, .value = scalar });
        }
        return out;
    }

    /// Borrowed visible-mark view, with no allocation. Mutating or releasing
    /// this set invalidates the view and any entries reached through it.
    pub fn nonDeletedMarks(self: *const MarkSet) NonDeletedMarks {
        return .{ .set = self };
    }

    /// The entries, in name order (`marks.rs:136-139`).
    ///
    /// The iterator borrows this set and is invalidated by the next
    /// [`MarkSet.put`], [`MarkSet.remove`] or [`MarkSet.deinit`], any of which
    /// can reallocate or shift the entries array it points into.
    pub fn iter(self: *const MarkSet) MarkSetIter {
        return .{ .entries = self.entries.items };
    }

    /// How many names this set holds, tombstones included
    /// (`marks.rs:140-143`).
    pub fn numMarks(self: *const MarkSet) usize {
        return self.entries.items.len;
    }

    /// How many names this set holds (`marks.rs:148-151`). The same number as
    /// `numMarks`; upstream keeps both spellings and so does the port.
    pub fn len(self: *const MarkSet) usize {
        return self.entries.items.len;
    }

    /// Sets `name` to `value`, replacing any value it already had
    /// (`marks.rs:152-155`, `BTreeMap::insert`).
    ///
    /// Borrowed sets retain the name and scalar payloads by borrow. Owned sets
    /// copy inputs, so callers can release them immediately after success;
    /// inputs may also refer to this set's current entries.
    ///
    /// On `error.OutOfMemory` nothing is stored and the set is unchanged.
    pub fn put(self: *MarkSet, name: []const u8, v: ScalarValue) Error!void {
        const at = self.lowerBound(name);
        if (at < self.entries.items.len and
            std.mem.eql(u8, self.entries.items[at].name, name))
        {
            if (self.owns_payloads) {
                const replacement = try v.dup(self.gpa);
                self.entries.items[at].value.deinitOwned(self.gpa);
                self.entries.items[at].value = replacement;
            } else {
                self.entries.items[at].value = v;
            }
            return;
        }
        if (self.owns_payloads) {
            const copied_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(copied_name);
            var copied_value = try v.dup(self.gpa);
            errdefer copied_value.deinitOwned(self.gpa);
            try self.entries.insert(self.gpa, at, .{
                .name = copied_name,
                .value = copied_value,
            });
        } else {
            try self.entries.insert(self.gpa, at, .{ .name = name, .value = v });
        }
    }

    /// Drops `name` if it is present (`marks.rs:156-159`).
    pub fn remove(self: *MarkSet, name: []const u8) void {
        if (self.find(name)) |index| {
            var removed = self.entries.orderedRemove(index);
            if (self.owns_payloads) {
                self.gpa.free(removed.name);
                removed.value.deinitOwned(self.gpa);
            }
        }
    }

    /// Whether the set holds no names at all. A set holding only unmark
    /// tombstones is not empty.
    pub fn isEmpty(self: *const MarkSet) bool {
        return self.entries.items.len == 0;
    }

    /// This set without the marks whose value is `Null`, i.e. without the
    /// unmark tombstones (`marks.rs:180-187`).
    ///
    /// **The receiver is consumed on both outcomes.** It is taken by value and
    /// its entries buffer is released before this returns, whether it returns
    /// a set or `error.OutOfMemory`, so the caller must not [`MarkSet.deinit`]
    /// the value it passed and has no release route for it afterwards. On
    /// error the partially built result is released as well and nothing is
    /// handed back.
    ///
    /// Borrowed inputs produce borrowed payloads; owned inputs produce an
    /// independent owned result before releasing the consumed source.
    pub fn withoutUnmarks(self: MarkSet) Error!MarkSet {
        // Upstream clones the whole map and retains on the clone
        // (`marks.rs:183-186`, with its own `FIXME - do I need this clone?`).
        // Same work here: the clone is the flat array this builds, and the
        // original is freed rather than dropped, because Zig has no drop.
        var out = MarkSet.init(self.gpa);
        out.owns_payloads = self.owns_payloads;
        errdefer out.deinit();
        // **A plain `defer`, not `errdefer` plus a call on the success path.**
        // The release is the same on both, and one deferred call cannot be
        // reached twice.
        var consumed = self;
        defer consumed.deinit();
        for (self.entries.items) |entry| {
            switch (entry.value) {
                .null_value => {},
                else => try out.put(entry.name, entry.value),
            }
        }
        return out;
    }

    /// Whether two sets hold the same marks, by content (`marks.rs:106` —
    /// `#[derive(PartialEq)]` over a `BTreeMap<SmolStr, ScalarValue>`).
    ///
    /// **This is the comparison `calculate_marks_slow` folds on**
    /// ([`automerge.rs`:1614](../../github-automerge-automerge/rust/automerge/src/automerge.rs),
    /// `last_marks.as_ref() != marks`), which upstream gets from
    /// `Arc<MarkSet>: PartialEq` being `**self == **other`. It compares names
    /// *and* values, so a mark whose value changed is a change of set — which
    /// is what decides where a run of marks ends and the next begins.
    ///
    /// Both sets are sorted by name, so this is a pairwise walk and no lookup.
    pub fn eql(a: *const MarkSet, b: *const MarkSet) bool {
        if (a.entries.items.len != b.entries.items.len) return false;
        for (a.entries.items, b.entries.items) |am, bm| {
            if (!std.mem.eql(u8, am.name, bm.name)) return false;
            if (!am.value.eql(bm.value)) return false;
        }
        return true;
    }

    /// The index of `name`, or null.
    fn find(self: *const MarkSet, name: []const u8) ?usize {
        const at = self.lowerBound(name);
        if (at < self.entries.items.len and
            std.mem.eql(u8, self.entries.items[at].name, name)) return at;
        return null;
    }

    /// The first index whose name does not sort before `name`, which is the
    /// slot `BTreeMap::entry` would hand back (`marks.rs:89`). The names are
    /// sorted, so this is a binary search.
    fn lowerBound(self: *const MarkSet, name: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.entries.items[mid].name, name) == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
};

/// Borrowed view that ignores Null tombstones (`marks.rs:437-464`).
/// Holds no storage; the source set must stay alive and unmodified.
pub const NonDeletedMarks = struct {
    set: *const MarkSet,

    /// Number of visible names, excluding Null tombstones.
    pub fn len(self: NonDeletedMarks) usize {
        var count: usize = 0;
        for (self.set.entries.items) |entry| {
            if (entry.value != .null_value) count += 1;
        }
        return count;
    }

    /// Whether no visible names remain.
    pub fn isEmpty(self: NonDeletedMarks) bool {
        for (self.set.entries.items) |entry| {
            if (entry.value != .null_value) return false;
        }
        return true;
    }

    /// Equality of visible names and values; tombstones do not participate.
    pub fn eql(a: NonDeletedMarks, b: NonDeletedMarks) bool {
        var ai: usize = 0;
        var bi: usize = 0;
        while (true) {
            while (ai < a.set.entries.items.len and
                a.set.entries.items[ai].value == .null_value) : (ai += 1)
            {}
            while (bi < b.set.entries.items.len and
                b.set.entries.items[bi].value == .null_value) : (bi += 1)
            {}
            const a_done = ai == a.set.entries.items.len;
            const b_done = bi == b.set.entries.items.len;
            if (a_done or b_done) return a_done and b_done;
            const am = a.set.entries.items[ai];
            const bm = b.set.entries.items[bi];
            if (!std.mem.eql(u8, am.name, bm.name) or !am.value.eql(bm.value)) {
                return false;
            }
            ai += 1;
            bi += 1;
        }
    }
};

/// The iterator over a mark set (`marks.rs:112-134`).
///
/// Upstream wraps `Option<btree_map::Iter>` so that the type has a `Default`
/// and can stand for "no marks" (`iter/spans.rs:330`, `:338`); a zero-valued
/// `MarkSetIter` is empty in the same way, with no allocation behind it.
pub const MarkSetIter = struct {
    /// The entries being walked, borrowed from the set [`MarkSet.iter`] was
    /// made from. A `null` name here is not possible; the zero value walks
    /// nothing.
    entries: []const MarkSet.Entry = &.{},
    /// How many entries have been handed out.
    index: usize = 0,

    /// The next entry, or `null` at the end. The returned pointer is into the
    /// set's own entries array and is invalidated by the next
    /// [`MarkSet.put`], [`MarkSet.remove`] or [`MarkSet.deinit`].
    pub fn next(self: *MarkSetIter) ?*const MarkSet.Entry {
        if (self.index >= self.entries.len) return null;
        const entry = &self.entries[self.index];
        self.index += 1;
        return entry;
    }
};

/// The name and value of one open mark. Upstream `op_set2::types::MarkData`
/// (`op_set2/types.rs:56-60`), declared in the op set because that is where it
/// is built; it is a value type with no behaviour, so it lives here and the op
/// set imports it. The name is borrowed.
pub const MarkData = struct {
    /// The mark name. Borrowed, and this type owns nothing: a holder keeps
    /// the bytes alive for as long as the value.
    name: []const u8,
    value: ScalarValue,

    /// The name and value as one value type. **The name is borrowed** and is
    /// retained by whatever stores this, so it must outlive it. Allocates
    /// nothing and frees nothing.
    pub fn init(name: []const u8, v: ScalarValue) MarkData {
        return .{ .name = name, .value = v };
    }

    // There is deliberately no `eql`: the fold compares a name and a value
    // separately, because that is what decides the set. Two marks of the same
    // name and different values are not equal, and two of different names are
    // not comparable at all (`marks.rs:333`, `:347`).
};

/// The fold: mark operations in, the mark set at the current position out
/// (`marks.rs:242-247`). See the module comment for the rules it implements.
///
/// `state` is the set of marks that are open, sorted by op id, and `resolved`
/// is what they resolve to. Upstream holds the set in an `Arc` and clones it
/// on write; here the set is owned outright, because the only two holders in
/// the crate are the text diff's `before` and `after` machines, which each own
/// theirs separately (`iter/spans.rs:648-651`).
pub const MarkStateMachine = struct {
    /// The allocator the open-mark array is allocated with. It is retained
    /// for the machine's whole life, so it must outlive it; the mark names the
    /// machine holds are borrowed, not allocated with it.
    gpa: Allocator,
    /// The open marks, sorted by op id.
    state: std.ArrayList(Entry) = .empty,
    /// What the open marks resolve to. Upstream names this field `current`
    /// (`marks.rs:246`); a field and a method cannot share a name in Zig, and
    /// the method is the one every caller uses.
    resolved: MarkSet,

    /// One open mark: the operation that opened it, and what it carries.
    pub const Entry = struct {
        id: OpId,
        mark: MarkData,
    };

    /// Where a binary search landed: on the id, or on the point it would be
    /// inserted at. Upstream's `Result<usize, usize>`
    /// (`marks.rs:321-323`); a union rather than an error because neither
    /// outcome is a failure.
    const Found = union(enum) {
        at: usize,
        insert_at: usize,
    };

    /// An empty machine that stores `gpa` for its open-mark array and for the
    /// [`MarkSet`] it resolves into. Allocates nothing.
    pub fn init(gpa: Allocator) MarkStateMachine {
        return .{ .gpa = gpa, .resolved = MarkSet.init(gpa) };
    }

    /// Releases the open-mark array and the resolved set. **The mark names are
    /// not freed** — they are borrowed, see [`MarkData`] — and no mark value
    /// owns bytes. The machine is `undefined` afterward and a second call is a
    /// double free.
    pub fn deinit(self: *MarkStateMachine) void {
        self.state.deinit(self.gpa);
        self.resolved.deinit();
        self.* = undefined;
    }

    /// The set at the current position, or null when nothing is marked
    /// (`marks.rs:250-256`).
    ///
    /// The pointer is into this machine's own `resolved` set and is invalidated
    /// by the next [`MarkStateMachine.process`], [`MarkStateMachine.markBegin`]
    /// or [`MarkStateMachine.markEnd`], and by [`MarkStateMachine.deinit`].
    pub fn current(self: *const MarkStateMachine) ?*const MarkSet {
        if (self.resolved.isEmpty()) return null;
        return &self.resolved;
    }

    /// Folds one operation. Anything that is not a mark operation leaves the
    /// set alone and reports no change (`marks.rs:258-264`).
    pub fn process(self: *MarkStateMachine, opid: OpId, action: value.OpType) Error!bool {
        return switch (action) {
            .mark_begin => |begin| self.markBegin(opid, .{
                .name = begin.name,
                // An unmark reaches the fold as a mark begin whose value is
                // `null_value`, which is how upstream spells the tombstone
                // (`op_set2/types.rs:59-60`); it is the same mark here.
                .value = begin.value,
            }),
            .mark_end => self.markEnd(opid),
            else => false,
        };
    }

    /// Opens a mark. Returns whether the current set changed
    /// (`marks.rs:266-292`).
    ///
    /// **Every decision is taken before anything is written, and an error
    /// leaves the machine exactly as it was.** The fold this drives keeps going
    /// after a caught error (`op_set.zig`'s `calculateMarksSlow`), so a
    /// half-applied step would leave a mark value with no open mark behind it,
    /// and every later end for that id would be dropped. `MarkSet.put` leaves
    /// its set unchanged when it fails, and `orderedRemove` allocates nothing,
    /// so the rollback is exact.
    pub fn markBegin(self: *MarkStateMachine, id: OpId, mark: MarkData) Error!bool {
        // An id already in the state is a corrupt document: op ids are unique,
        // so upstream drops the operation rather than opening it twice
        // (`marks.rs:269-272`).
        const index = switch (self.find(id)) {
            .at => return false,
            .insert_at => |at| at,
        };

        const changes = decision: {
            // A same-name mark above shadows this one entirely: whatever is in
            // the set stays until that mark ends (`marks.rs:274`).
            if (markAbove(self.state.items, index, mark) != null) break :decision false;
            if (markBelow(self.state.items, index, mark)) |below| {
                // The value below is already the one being opened, so the set
                // does not change and the caller is told so (`marks.rs:276`).
                break :decision !below.value.eql(mark.value);
            }
            // Nothing above and nothing below: this mark decides the value
            // from here on (`marks.rs:281-286`).
            break :decision true;
        };

        // **The open mark goes in first and comes back out if the resolved set
        // refuses the value.** The reverse order would publish the value and
        // then fail to record the mark that owns it.
        try self.state.insert(self.gpa, index, .{ .id = id, .mark = mark });
        errdefer _ = self.state.orderedRemove(index);
        if (changes) try self.resolved.put(mark.name, mark.value);
        return changes;
    }

    /// Closes the mark that `id` ends, which is the one opened at `id.prev()`
    /// (`marks.rs:294-319`). Returns whether the current set changed.
    ///
    /// An `id.prev()` that is not in the state is ignored (`marks.rs:296-299`)
    /// and reports no change. The atomicity guarantee is
    /// [`MarkStateMachine.markBegin`]'s.
    ///
    /// **The scans run against the state with the closed mark still in it, so
    /// the one above starts one entry past it.** Upstream removes the entry
    /// first (`marks.rs:301`) and only then looks for its neighbours, which is
    /// why its `mark_above` never sees the mark being closed; asking here with
    /// the closed mark's own index would let a mark answer the question asked
    /// about itself, and every end would report no change and write nothing —
    /// every mark would then run to the end of the object.
    pub fn markEnd(self: *MarkStateMachine, id: OpId) Error!bool {
        const index = switch (self.find(id.prev())) {
            .at => |at| at,
            .insert_at => return false,
        };

        const mark = self.state.items[index].mark;

        // **One past the closed mark.** Upstream's `state.remove(index)`
        // happens before `mark_above` (`marks.rs:301-303`), so upstream's
        // `state[index..]` is this port's `state[index + 1..]`.
        const above = index + 1;

        const changes = decision: {
            if (markAbove(self.state.items, above, mark) != null) break :decision false;
            if (markBelow(self.state.items, index, mark)) |below| {
                // Restoring the value below is a change only when it differs
                // from the value being closed (`marks.rs:305`).
                break :decision !below.value.eql(mark.value);
            }
            break :decision true;
        };

        // **The resolved set is settled while the mark is still open.**
        // Removing first and re-inserting after a failed `put` would need an
        // allocation that can itself fail, which is the same hazard one level
        // down; `MarkSet.remove` and `MarkSet.put` are the two steps here and
        // only one of them can fail, with the mark still in place to unwind.
        if (changes) {
            if (markBelow(self.state.items, index, mark)) |below| {
                try self.resolved.put(below.name, below.value);
            } else {
                // Nothing of this name is left, so the name leaves the set
                // (`marks.rs:311-314`).
                self.resolved.remove(mark.name);
            }
        }
        _ = self.state.orderedRemove(index);
        return changes;
    }

    /// Binary search for `target` in the open marks, by op id
    /// (`marks.rs:321-323`).
    fn find(self: *const MarkStateMachine, target: OpId) Found {
        var lo: usize = 0;
        var hi: usize = self.state.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (OpId.order(self.state.items[mid].id, target)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .at = mid },
            }
        }
        return .{ .insert_at = lo };
    }
};

/// The first mark of the same name in `state[from..]`, if any
/// (`marks.rs:325-337`). `from` is where the first entry **strictly above** the
/// mark the caller is deciding on sits: the insertion point for a begin, and
/// one past the mark itself for an end, which upstream has already removed.
fn markAbove(state: []const MarkStateMachine.Entry, from: usize, mark: MarkData) ?MarkData {
    for (state[from..]) |entry| {
        if (std.mem.eql(u8, entry.mark.name, mark.name)) return entry.mark;
    }
    return null;
}

/// The last mark of the same name below `index`, if any (`marks.rs:339-353`).
/// Upstream takes the slice mutably and calls `next_back`; nothing here writes,
/// so the port walks the same entries backwards.
fn markBelow(state: []const MarkStateMachine.Entry, index: usize, mark: MarkData) ?MarkData {
    var i = index;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, state[i].mark.name, mark.name)) return state[i].mark;
    }
    return null;
}

/// The name and value of a mark (`marks.rs:355-359`). Upstream's `SmolStr`
/// owns its bytes; here, as everywhere in this port, the name is borrowed and
/// the owner keeps it alive. This type frees nothing.
pub const OldMarkData = struct {
    /// The mark name, borrowed.
    name: []const u8,
    value: ScalarValue,

    /// Whether the two carry the same name **and** the same value
    /// (`marks.rs:355-359`, upstream's derived `PartialEq` over a
    /// `SmolStr`/`ScalarValue` pair). Allocates nothing.
    pub fn eql(a: OldMarkData, b: OldMarkData) bool {
        return std.mem.eql(u8, a.name, b.name) and a.value.eql(b.value);
    }
};

/// Whether text inserted at the start or the end of a mark inherits it
/// (`marks.rs:367-377`).
///
/// See <https://www.inkandswitch.com/peritext/> for which value suits which
/// editing operation. This is the API form of the pair of booleans a mark
/// operation carries on the wire: the begin operation stores
/// `expand.before()` and the end operation stores `expand.after()`
/// (`op_set2/types.rs:422-428`).
pub const ExpandMark = enum {
    before,
    after,
    both,
    none,

    /// Upstream's `Default for ExpandMark` is `After` (`marks.rs:379-383`).
    pub const default: ExpandMark = .after;

    /// The pair of booleans the wire form uses, as one value
    /// (`marks.rs:385-393`).
    pub fn from(before: bool, after: bool) ExpandMark {
        return switch (before) {
            true => if (after) .both else .before,
            false => if (after) .after else .none,
        };
    }

    /// Whether the begin operation expands backwards. Upstream calls this
    /// `before` (`marks.rs:394-396`), which is the name of an enum tag here,
    /// and an enum tag and a declaration cannot share a name.
    pub fn expandsBefore(self: ExpandMark) bool {
        return self == .before or self == .both;
    }

    /// Whether the end operation expands forwards. Upstream calls this `after`
    /// (`marks.rs:397-399`); see `expandsBefore` for the rename.
    pub fn expandsAfter(self: ExpandMark) bool {
        return self == .after or self == .both;
    }
};

/// The expand flags [`updateSpans`](transact.zig) writes and clears its marks
/// with ([`UpdateSpansConfig`](../../github-automerge-automerge/rust/automerge/src/marks.rs):466-486).
///
/// **Two fields and one rule.** [`per_mark_expands`] names the flag for a
/// particular mark name and [`default_expand`] is the flag for a name the map
/// does not hold, and the mark pass asks for one of the two **for every mark
/// it writes and for every mark it removes** — not once for the call
/// ([`apply_marks_diff`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs):216-226, `:229-245`).
/// That is what lets three mark names on one span grow in three different
/// directions, which is upstream's `multiple_marks_different_expand_behaviors`
/// (`diff_marks.rs`:864-903`).
///
/// **`default_expand` is [`ExpandMark.after`] because upstream derives
/// `Default`** ([`marks.rs`:467`, `:379-383`), so a config built by [`init`] is
/// upstream's `UpdateSpansConfig::default()`. [API.md](../API.md) drops the
/// type; it is here because two ported cases set flags
/// (`diff_marks.rs`:864-903`, `:906-944`) and there is no way to ask for a
/// non-default flag without it.
///
/// **One owner, and a copy is not one.** The table and every name in it belong
/// to this value and [`UpdateSpansConfig.deinit`] frees them, so a second copy
/// deinited as well is a double free and a flag set through one copy is
/// visible through the other. There is no method here that hands a copy back.
pub const UpdateSpansConfig = struct {
    /// The allocator the map and the copies of the names in it were made with.
    gpa: Allocator,
    /// The flag for a mark name [`per_mark_expands`] does not hold
    /// ([`marks.rs`:470`](../../github-automerge-automerge/rust/automerge/src/marks.rs)).
    default_expand: ExpandMark = ExpandMark.default,
    /// The flag for each named mark ([`marks.rs`:472`](../../github-automerge-automerge/rust/automerge/src/marks.rs)).
    per_mark_expands: std.StringHashMapUnmanaged(ExpandMark) = .empty,

    /// Upstream's `UpdateSpansConfig::default()`: no per-mark flags and
    /// [`ExpandMark.default`] ([`marks.rs`:467-473`](../../github-automerge-automerge/rust/automerge/src/marks.rs)).
    pub fn init(gpa: Allocator) UpdateSpansConfig {
        return .{ .gpa = gpa };
    }

    /// Frees the table and every name copied into it.
    ///
    /// **The names are freed here, not by the map.**
    /// [`std.StringHashMapUnmanaged`] frees its table and nothing else: a key
    /// it did not allocate is a key its caller must free, and
    /// [`setMarkExpand`] `dupe`s every name it stores. The allocator itself is
    /// not released. A second call is a double free.
    pub fn deinit(self: *UpdateSpansConfig) void {
        var names = self.per_mark_expands.keyIterator();
        while (names.next()) |name| self.gpa.free(name.*);
        self.per_mark_expands.deinit(self.gpa);
    }

    /// Sets [`default_expand`](UpdateSpansConfig.default_expand) and returns
    /// the same config ([`with_default_expand`](../../github-automerge-automerge/rust/automerge/src/marks.rs):476-479).
    ///
    /// **In place, because a returned-by-value copy would be a second owner.**
    /// Upstream consumes the config and hands it back so the calls chain; here
    /// the table and the duped names have one owner, so handing back a copy
    /// would give two `deinit`s one set of bytes. The return is `self` so the
    /// call still reads as a builder step, and it may be discarded. Cannot
    /// fail and allocates nothing.
    pub fn withDefaultExpand(self: *UpdateSpansConfig, expand: ExpandMark) *UpdateSpansConfig {
        self.default_expand = expand;
        return self;
    }

    /// Records the flag for `name` ([`per_mark_expands.insert`](../../github-automerge-automerge/rust/automerge/src/marks.rs):481-485).
    ///
    /// **A statement, not upstream's consuming builder.** Upstream returns the
    /// config by value so the calls chain; a Zig insertion into a hash map can
    /// fail, and a builder that had to hand the config back on the failure path
    /// as well would be the only place in this file that owns a value twice.
    /// The name is copied, so a caller may pass a literal or a slice into the
    /// document.
    ///
    /// **Nothing is lost when the copy or the insert fails.** The new entry
    /// goes in before any old one goes out, so a name that already had a flag
    /// still has it — the one change an error must not make is a silent
    /// fallback to [`default_expand`](UpdateSpansConfig.default_expand) on a
    /// retry.
    pub fn setMarkExpand(
        self: *UpdateSpansConfig,
        name: []const u8,
        expand: ExpandMark,
    ) Allocator.Error!void {
        const entry = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(entry);
        const slot = try self.per_mark_expands.getOrPut(self.gpa, entry);
        if (slot.found_existing) {
            // **The map keeps the copy of the name it already had**, so the
            // one just made is not stored and would otherwise leak.
            self.gpa.free(entry);
        }
        slot.value_ptr.* = expand;
    }

    /// The flag for `name`: its own, or [`default_expand`]
    /// ([`text_diff.rs`:217-221`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs), [`:235-239`](../../github-automerge-automerge/rust/automerge/src/text_diff.rs)),
    /// which is upstream's `.copied().unwrap_or(config.default_expand)` written
    /// as one lookup.
    pub fn expandFor(self: *const UpdateSpansConfig, name: []const u8) ExpandMark {
        return self.per_mark_expands.get(name) orelse self.default_expand;
    }
};

/// Asserts that `set` holds exactly `want`, in name order. A null `set` is an
/// empty fold, which is the same thing as an empty want list.
fn expectMarks(set: ?*const MarkSet, want: []const MarkSet.Entry) !void {
    var got: std.ArrayList(MarkSet.Entry) = .empty;
    defer got.deinit(testing.allocator);
    if (set) |s| {
        var it = s.iter();
        while (it.next()) |entry| try got.append(testing.allocator, entry.*);
    }
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expect(w.value.eql(g.value));
    }
}

/// Opens a mark, closes it, and frees the machine. A step that fails must
/// leave the machine exactly as the step before it left it.
fn openThenCloseThenFree(gpa: Allocator) !void {
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    if (machine.markBegin(OpId.init(1, 0), MarkData.init("bold", .{ .bool_value = true }))) |_| {
        if (machine.markEnd(OpId.init(2, 0))) |changed| {
            try testing.expect(changed);
            try expectMarks(machine.current(), &.{});
            return;
        } else |_| {
            // **A refused close puts the mark back.** The value is still
            // resolved and the mark is still open, so the fold that keeps
            // going after a caught error still finds it.
            try expectMarks(machine.current(), &.{
                .{ .name = "bold", .value = .{ .bool_value = true } },
            });
            try testing.expectEqual(@as(usize, 1), machine.state.items.len);
            return error.OutOfMemory;
        }
    } else |_| {
        // **A refused open leaves nothing at all**: no open mark, and no
        // resolved value with no mark behind it. The other order would leave
        // the value, and every later end for that id would be dropped.
        try testing.expectEqual(@as(usize, 0), machine.state.items.len);
        try expectMarks(machine.current(), &.{});
        return error.OutOfMemory;
    }
}

test "a refused mark step leaves the state machine as the step before it left it" {
    const gpa = testing.allocator;
    // **The sweep is written out rather than run through
    // `testing.checkAllAllocationFailures`.** That harness reports leaks, and
    // a half-applied step leaks nothing: it is the state after the refusal
    // that a caller reads next.
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try openThenCloseThenFree(failing.allocator());
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, openThenCloseThenFree(failing.allocator()));
        // **Live bytes, and not `allocated_bytes`.** `FailingAllocator` never
        // decrements `allocated_bytes` on a free, it adds to `freed_bytes`
        // ([`std/testing/FailingAllocator.zig`](../../lib/std/testing/FailingAllocator.zig)),
        // so the count of bytes still held is the difference.
        try testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
    }
}

/// Strips the tombstones off a copy of a set and frees the result.
fn stripThenFree(gpa: Allocator) !void {
    const set: MarkSet = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "gone", .value = .null_value },
    });
    // **There is deliberately no `defer set.deinit()` here.** The receiver is
    // consumed on both outcomes, so a refusal frees it too; adding the defer
    // is the double free the contract rules out. A leak-failing allocator is
    // what notices that the refusal released it.
    var stripped = try set.withoutUnmarks();
    defer stripped.deinit();
    try expectMarks(&stripped, &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
}

test "withoutUnmarks frees the set it was given on the error path too" {
    try testing.checkAllAllocationFailures(testing.allocator, stripThenFree, .{});
}

/// Records one per-mark flag, overwrites it, and frees the config.
fn flagThenOverwriteThenFree(gpa: Allocator) !void {
    var config = UpdateSpansConfig.init(gpa);
    defer config.deinit();
    if (config.setMarkExpand("bold", .before)) |_| {
        if (config.setMarkExpand("bold", .after)) |_| {
            try testing.expectEqual(ExpandMark.after, config.expandFor("bold"));
            return;
        } else |_| {
            // **The flag the caller set first is still the one in force.** A
            // refusal that took it with it would answer a retry with
            // `ExpandMark.after` — the default — and write this mark the wrong
            // way at both boundaries.
            try testing.expectEqual(ExpandMark.before, config.expandFor("bold"));
            return error.OutOfMemory;
        }
    } else |_| return error.OutOfMemory;
}

test "a refused per-mark flag leaves the flag that was already there" {
    const gpa = testing.allocator;
    const needed = blk: {
        var failing: testing.FailingAllocator = .init(gpa, .{});
        try flagThenOverwriteThenFree(failing.allocator());
        break :blk failing.alloc_index;
    };
    for (0..needed) |fail_index| {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, flagThenOverwriteThenFree(failing.allocator()));
        try testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
    }
}

test "an empty fold produces no marks" {
    const gpa = testing.allocator;

    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();
    try testing.expect(machine.current() == null);
    // Folding an operation that is not a mark changes nothing and reports no
    // change (`marks.rs:262`).
    try testing.expect(!try machine.process(OpId.init(1, 0), .delete));
    try expectMarks(machine.current(), &.{});

    var acc = MarkAccumulator.init(gpa);
    defer acc.deinit();
    var all = acc.intoIter();
    try testing.expect(all.next() == null);
    var live = acc.intoIterNoUnmark();
    try testing.expect(live.next() == null);

    var set = MarkSet.init(gpa);
    defer set.deinit();
    try testing.expect(set.isEmpty());
    try testing.expectEqual(@as(usize, 0), set.numMarks());
    var none = set.iter();
    try testing.expect(none.next() == null);
    // A zero-valued iterator stands for "no marks", which is what the text
    // diff reaches for when one side of a diff has no mark set
    // (`iter/spans.rs:330`, `:338`).
    var empty_iter: MarkSetIter = .{};
    try testing.expect(empty_iter.next() == null);
}

test "one mark opens and closes" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);
}

test "two marks of different names that do not overlap" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    const bold = MarkData.init("bold", .{ .bool_value = true });
    const italic = MarkData.init("italic", .{ .bool_value = true });

    try testing.expect(try machine.markBegin(OpId.init(1, 0), bold));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);

    try testing.expect(try machine.markBegin(OpId.init(3, 0), italic));
    try expectMarks(machine.current(), &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try testing.expect(try machine.markEnd(OpId.init(4, 0)));
    try testing.expect(machine.current() == null);
}

test "an overlapping mark of the same name wins while it is open" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    // bold over [1, 5) then bold over [3, 7), the second one a different
    // value. The two are written by one actor, so each mark's end operation is
    // the operation immediately after its begin (`transaction/inner.rs:827-857`)
    // and the fold meets them in position order: begin(1), begin(3), end(2),
    // end(4).
    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    try testing.expect(try machine.markBegin(
        OpId.init(3, 0),
        MarkData.init("bold", .{ .bool_value = false }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = false } }});

    // The first mark ends, but the second one is still open above it, so the
    // set does not change and the fold says so (`marks.rs:303`).
    try testing.expect(!try machine.markEnd(OpId.init(2, 0)));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = false } }});

    try testing.expect(try machine.markEnd(OpId.init(4, 0)));
    try testing.expect(machine.current() == null);
}

test "an unmark inside a mark restores the value below when it ends" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    // bold over [0, 9) and an unmark over [3, 6). An unmark is a mark begin
    // whose value is `Null` (`transaction/inner.rs:879-891`).
    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try testing.expect(try machine.markBegin(
        OpId.init(3, 0),
        MarkData.init("bold", .null_value),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .null_value }});

    // The unmark ends and the mark below it takes the value back
    // (`marks.rs:306-310`).
    try testing.expect(try machine.markEnd(OpId.init(4, 0)));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);
}

test "a mark inside another of a different name" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try testing.expect(try machine.markBegin(
        OpId.init(3, 0),
        MarkData.init("italic", .{ .bool_value = true }),
    ));
    try expectMarks(machine.current(), &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "italic", .value = .{ .bool_value = true } },
    });

    try testing.expect(try machine.markEnd(OpId.init(4, 0)));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});

    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);
}

test "a mark that begins and ends at the same position" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    // Two zero-width marks of the same name at one position, as
    // `transaction/inner.rs:830-831` writes them: each end immediately after
    // its own begin.
    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);

    try testing.expect(try machine.markBegin(
        OpId.init(3, 0),
        MarkData.init("bold", .{ .bool_value = false }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = false } }});
    try testing.expect(try machine.markEnd(OpId.init(4, 0)));
    try testing.expect(machine.current() == null);
}

test "a begin with no matching end stays open" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try testing.expect(try machine.markBegin(
        OpId.init(3, 0),
        MarkData.init("bold", .{ .bool_value = false }),
    ));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = false } }});
    // Nothing was ever closed, so the last value read stands.
    try testing.expect(machine.current() != null);
}

test "a begin whose id is already open is ignored" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    try testing.expect(try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    // A second operation with the same id is a corrupt document, and upstream
    // drops it (`marks.rs:269-272`). Opening it twice would leave the mark in
    // the state after its end, so the end below is what proves the difference.
    try testing.expect(!try machine.markBegin(
        OpId.init(1, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try testing.expect(try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);
}

test "an end with no open begin is ignored" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    // `mark_end` looks for `id.prev()` (`marks.rs:296`), which is not here.
    try testing.expect(!try machine.markEnd(OpId.init(2, 0)));
    try testing.expect(machine.current() == null);

    try testing.expect(try machine.markBegin(
        OpId.init(5, 0),
        MarkData.init("bold", .{ .bool_value = true }),
    ));
    try testing.expect(!try machine.markEnd(OpId.init(2, 0)));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
}

test "process folds mark operations and ignores the rest" {
    const gpa = testing.allocator;
    var machine = MarkStateMachine.init(gpa);
    defer machine.deinit();

    // An unmark is a mark begin whose value is null; `OpType` spells the
    // end of a mark as `.mark_end`, which carries only the expand flag
    // (`op_set2/types.rs:135`, `src/value.zig`).
    const begin: value.OpType = .{ .mark_begin = .{
        .expand = true,
        .name = "bold",
        .value = .{ .bool_value = true },
    } };
    const end: value.OpType = .{ .mark_end = .{ .expand = false } };

    try testing.expect(try machine.process(OpId.init(1, 0), begin));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try testing.expect(try machine.process(OpId.init(2, 0), end));
    try testing.expect(machine.current() == null);

    // An unmark begin reaches the fold as a null value.
    try testing.expect(try machine.process(OpId.init(3, 0), .{ .mark_begin = .{
        .expand = false,
        .name = "bold",
        .value = .null_value,
    } }));
    try expectMarks(machine.current(), &.{.{ .name = "bold", .value = .null_value }});
}

test "accumulator runs coalesce only when they are adjacent and equal" {
    const gpa = testing.allocator;
    var acc = MarkAccumulator.init(gpa);
    defer acc.deinit();

    var bold = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
    });
    defer bold.deinit();
    var bold_off = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .bool_value = false } },
    });
    defer bold_off.deinit();

    try acc.add(0, 3, &bold);
    try acc.add(3, 2, &bold);
    // A different value starts a new run even though it is adjacent.
    try acc.add(5, 1, &bold_off);
    // A gap does too.
    try acc.add(7, 1, &bold);

    var got: std.ArrayList(Mark) = .empty;
    defer got.deinit(gpa);
    var it = acc.intoIter();
    while (it.next()) |m| try got.append(gpa, m);

    const want = [_]Mark{
        Mark.init("bold", .{ .bool_value = true }, 0, 5),
        Mark.init("bold", .{ .bool_value = false }, 5, 6),
        Mark.init("bold", .{ .bool_value = true }, 7, 8),
    };
    try testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| {
        try testing.expectEqual(w.start, g.start);
        try testing.expectEqual(w.end, g.end);
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expect(w.value.eql(g.value));
    }
}

test "accumulator runs are grouped by name in name order" {
    const gpa = testing.allocator;
    var acc = MarkAccumulator.init(gpa);
    defer acc.deinit();

    var set = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "zebra", .value = .{ .int = 1 } },
        .{ .name = "alpha", .value = .{ .int = 2 } },
    });
    defer set.deinit();

    try acc.add(0, 1, &set);
    // A second name added later still sorts ahead of the first.
    var other = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "middle", .value = .{ .int = 3 } },
    });
    defer other.deinit();
    try acc.add(1, 1, &other);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = acc.intoIter();
    while (it.next()) |m| try names.append(gpa, m.name);

    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("alpha", names.items[0]);
    try testing.expectEqualStrings("middle", names.items[1]);
    try testing.expectEqualStrings("zebra", names.items[2]);
}

test "only the unmark-free walk drops the tombstones" {
    const gpa = testing.allocator;
    var acc = MarkAccumulator.init(gpa);
    defer acc.deinit();

    var unmark = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .null_value },
    });
    defer unmark.deinit();
    try acc.add(0, 2, &unmark);

    // `into_iter` keeps the tombstone: the patch log needs to report the
    // unmark itself (`marks.rs:76-85`).
    var kept = acc.intoIter();
    const one = kept.next().?;
    try testing.expectEqualStrings("bold", one.name);
    try testing.expect(one.value == .null_value);
    try testing.expect(kept.next() == null);

    // `into_iter_no_unmark` does not, and that is what a document returns for
    // a range of text (`automerge.rs:1630`).
    var dropped = acc.intoIterNoUnmark();
    try testing.expect(dropped.next() == null);
}

test "a mark set is sorted by name, replaces and drops" {
    const gpa = testing.allocator;
    var set = MarkSet.init(gpa);
    defer set.deinit();

    try set.put("zebra", .{ .int = 1 });
    try set.put("alpha", .{ .int = 2 });
    try set.put("middle", .{ .int = 3 });
    try testing.expectEqual(@as(usize, 3), set.numMarks());
    try testing.expectEqual(set.numMarks(), set.len());
    try testing.expect(!set.isEmpty());

    // A repeat of a name replaces its value in place rather than adding a
    // second entry (`BTreeMap::insert`, `marks.rs:152-155`).
    try set.put("zebra", .{ .int = 9 });
    try testing.expectEqual(@as(usize, 3), set.numMarks());

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = set.iter();
    while (it.next()) |entry| try names.append(gpa, entry.name);
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("alpha", names.items[0]);
    try testing.expectEqualStrings("middle", names.items[1]);
    try testing.expectEqualStrings("zebra", names.items[2]);

    set.remove("middle");
    set.remove("absent");
    try testing.expectEqual(@as(usize, 2), set.numMarks());
    it = set.iter();
    try testing.expectEqualStrings("alpha", it.next().?.name);
    try testing.expectEqualStrings("zebra", it.next().?.name);
    try testing.expect(it.next() == null);
}

test "without unmarks drops the tombstones" {
    const gpa = testing.allocator;
    var set = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "italic", .value = .null_value },
    });
    var stripped = try set.withoutUnmarks();
    try expectMarks(&stripped, &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    stripped.deinit();

    var only_tombstones = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "italic", .value = .null_value },
    });
    var empty = try only_tombstones.withoutUnmarks();
    try testing.expect(empty.isEmpty());
    empty.deinit();
}

test "a mark becomes its payload and its set" {
    const gpa = testing.allocator;
    const mark = Mark.init("bold", .{ .bool_value = true }, 2, 5);

    const data = mark.oldData();
    try testing.expectEqualStrings("bold", data.name);
    try testing.expect(data.value.eql(mark.value));
    try testing.expect(data.eql(.{ .name = "bold", .value = .{ .bool_value = true } }));

    var set = try mark.intoMarkSet(gpa);
    defer set.deinit();
    try expectMarks(&set, &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
}

test "expand mark decomposes and recomposes" {
    try testing.expectEqual(ExpandMark.both, ExpandMark.from(true, true));
    try testing.expectEqual(ExpandMark.after, ExpandMark.from(false, true));
    try testing.expectEqual(ExpandMark.before, ExpandMark.from(true, false));
    try testing.expectEqual(ExpandMark.none, ExpandMark.from(false, false));
    try testing.expectEqual(ExpandMark.after, ExpandMark.default);

    inline for (.{
        ExpandMark.before,
        ExpandMark.after,
        ExpandMark.both,
        ExpandMark.none,
    }) |expand| {
        // The two booleans are what a mark operation carries, one on the begin
        // and one on the end (`op_set2/types.rs:422-428`).
        try testing.expectEqual(
            expand,
            ExpandMark.from(expand.expandsBefore(), expand.expandsAfter()),
        );
    }

    try testing.expect(ExpandMark.both.expandsBefore());
    try testing.expect(ExpandMark.both.expandsAfter());
    try testing.expect(ExpandMark.before.expandsBefore());
    try testing.expect(!ExpandMark.before.expandsAfter());
    try testing.expect(!ExpandMark.after.expandsBefore());
    try testing.expect(ExpandMark.after.expandsAfter());
    try testing.expect(!ExpandMark.none.expandsBefore());
    try testing.expect(!ExpandMark.none.expandsAfter());
}

// ── The document-level mark surface ──────────────────────────────────────────
//
// Everything below drives a real [`Document`]. The module doc above says this
// file reads and writes no storage, and it does not — but the surface these
// tests are about is a property of the operations a transaction wrote, and the
// fold alone cannot reach it. So the read is exercised the only way a caller
// can: build a document, drive `update_spans` and `mark` at it, and read the
// spans back.
//
// The tests are ports of
// `$AUTOMERGE_REF/rust/automerge/tests/diff_marks.rs`, in upstream's order and
// one for one, with no gaps; the diff block at the bottom of this file says
// which parts are the port's own deviations and which are upstream's.

const automod = @import("autocommit.zig");
const readmod = @import("read.zig");
const spanmod = @import("iter/spans.zig");
const hydmod = @import("hydrate.zig");
const opmod = @import("opset/op.zig");
const opsetmod = @import("opset/op_set.zig");

/// The op set [`hydrateMap`] walks: the one every document in this crate holds.
const HydrateSet = opsetmod.OpSet(opmod.ChangeOp);

const AutoCommit = automod.AutoCommit;
const ExId = types.ExId;

/// A document with one text object at `text`, which is where every test in
/// this section starts. Upstream's `AutoCommit::new()` plus its `put_object`.
const MarkFixture = struct {
    doc: AutoCommit,
    text: ExId,

    fn deinit(self: *MarkFixture) void {
        self.doc.deinit();
    }
};

fn markFixture(gpa: Allocator) !MarkFixture {
    var doc = try AutoCommit.init(gpa, std.testing.io);
    errdefer doc.deinit();
    // A named actor, so a change hash does not come out of the allocator
    // (`std.testing.allocator` is the arbiter).
    try doc.setActorId(.{ .bytes = "0123456789abcdef" });
    const text = try doc.putObject(.root, .{ .key = "text" }, .text);
    // An open facade is address-stable; close it before returning by value.
    _ = try doc.commit();
    return .{ .doc = doc, .text = text };
}

/// Borrowed update inputs backed by stable owned maps and mark sets.
const NewSpans = struct {
    gpa: Allocator,
    items: std.ArrayList(spanmod.SpanInput) = .empty,

    fn init(gpa: Allocator) NewSpans {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *NewSpans) void {
        for (self.items.items) |s| switch (s) {
            .block => |map| {
                const owned = @constCast(map);
                owned.deinit();
                self.gpa.destroy(owned);
            },
            .text => |t| if (t.marks) |marks| {
                const owned = @constCast(marks);
                owned.deinit();
                self.gpa.destroy(owned);
            },
        };
        self.items.deinit(self.gpa);
    }

    fn plain(self: *NewSpans, s: []const u8) !void {
        try self.items.append(self.gpa, .{ .text = .{ .text = s } });
    }

    fn marked(self: *NewSpans, s: []const u8, entries: []const MarkSet.Entry) !void {
        var borrowed = MarkSet.init(self.gpa);
        defer borrowed.deinit();
        for (entries) |entry| try borrowed.put(entry.name, entry.value);
        const owned = try self.gpa.create(MarkSet);
        errdefer self.gpa.destroy(owned);
        owned.* = try borrowed.dup(self.gpa);
        errdefer owned.deinit();
        try self.items.append(self.gpa, .{ .text = .{ .text = s, .marks = owned } });
    }

    fn block(self: *NewSpans, doc: *AutoCommit, id: ExId) !void {
        var hydrated = try hydmod.hydrateMap(HydrateSet, &doc.doc.ops, self.gpa, id, null);
        defer hydrated.deinit();
        const map = try self.gpa.create(hydmod.Map);
        errdefer self.gpa.destroy(map);
        map.* = try hydrated.object.map.dup(self.gpa);
        errdefer map.deinit();
        try self.items.append(self.gpa, .{ .block = map });
    }

    fn emptyBlock(self: *NewSpans) !void {
        const map = try self.gpa.create(hydmod.Map);
        errdefer self.gpa.destroy(map);
        map.* = hydmod.Map.init(self.gpa, .root);
        errdefer map.deinit();
        try self.items.append(self.gpa, .{ .block = map });
    }

    fn putBlock(self: *NewSpans, index: usize, key: []const u8, scalar: ScalarValue) !void {
        const map = @constCast(self.items.items[index].block);
        try map.putOwned(key, hydmod.MapValue.init(hydmod.Value.fromScalar(scalar), false));
    }
};

/// One span as a reader saw it, copied out of the walk so that the comparison
/// does not depend on the walk staying alive and a failure can be printed.
const ReadSpan = struct {
    /// The span's text; the object replacement character for a block, which is
    /// what [`Span.asStr`](iter/spans.zig) reports for one.
    text: []u8,
    /// Deep-owned hydrated payload for a block span.
    block: ?hydmod.Map = null,
    /// Deep-owned names and scalar payloads, independent of iterator spans.
    marks: []MarkSet.Entry,

    fn deinit(self: *ReadSpan, gpa: Allocator) void {
        gpa.free(self.text);
        if (self.block) |*map| map.deinit();
        for (self.marks) |*entry| {
            gpa.free(entry.name);
            entry.value.deinitOwned(gpa);
        }
        gpa.free(self.marks);
    }
};

/// What a ported test expects one span to say.
const WantSpan = struct {
    /// Text or an expected borrowed hydrated block payload.
    text: []const u8 = "",
    block: ?*const hydmod.Map = null,
    /// The marks, in name order.
    marks: []const MarkSet.Entry = &.{},
};

/// The spans of `obj` as a reader sees them, each one owned by `gpa`.
fn readSpanList(gpa: Allocator, doc: *AutoCommit, obj: ExId) ![]ReadSpan {
    var out: std.ArrayList(ReadSpan) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(gpa);
        out.deinit(gpa);
    }
    var walk = try readmod.spans(doc, obj, gpa);
    defer walk.deinit();
    while (try walk.next()) |found| {
        var span = found;
        // The walk hands the span over (`Spans.next`, `spans.zig`:1332`), so
        // its bytes are this function's from here.
        defer span.deinit(gpa);
        switch (span) {
            .text => |t| {
                const copy = try gpa.dupe(u8, t.text);
                errdefer gpa.free(copy);
                var entries: std.ArrayList(MarkSet.Entry) = .empty;
                errdefer {
                    for (entries.items) |*entry| {
                        gpa.free(entry.name);
                        entry.value.deinitOwned(gpa);
                    }
                    entries.deinit(gpa);
                }
                if (t.marks) |set| {
                    var it = set.iter();
                    while (it.next()) |entry| {
                        const name = try gpa.dupe(u8, entry.name);
                        errdefer gpa.free(name);
                        var scalar = try entry.value.dup(gpa);
                        errdefer scalar.deinitOwned(gpa);
                        try entries.append(gpa, .{ .name = name, .value = scalar });
                    }
                }
                const marks = try entries.toOwnedSlice(gpa);
                errdefer {
                    for (marks) |*entry| {
                        gpa.free(entry.name);
                        entry.value.deinitOwned(gpa);
                    }
                    gpa.free(marks);
                }
                try out.append(gpa, .{
                    .text = copy,
                    .block = null,
                    .marks = marks,
                });
            },
            .block => |*map| {
                const copy = try gpa.dupe(u8, span.asStr());
                errdefer gpa.free(copy);
                var owned = try map.dup(gpa);
                errdefer owned.deinit();
                try out.append(gpa, .{
                    .text = copy,
                    .block = owned,
                    .marks = &.{},
                });
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

fn marksEql(a: []const MarkSet.Entry, b: []const MarkSet.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if (!x.value.eql(y.value)) return false;
    }
    return true;
}

/// Asserts the spans of `obj` are exactly `want`.
///
/// **A length comparison would not do.** Every one of upstream's span tests
/// says something about *which* mark is over *which* text, and a mirror of the
/// wrong length with the wrong spans passes one.
fn expectDocSpans(
    gpa: Allocator,
    doc: *AutoCommit,
    obj: ExId,
    want: []const WantSpan,
) !void {
    const got = try readSpanList(gpa, doc, obj);
    defer {
        for (got) |*s| s.deinit(gpa);
        gpa.free(got);
    }
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const w = &report.writer;
    var same = want.len == got.len;
    if (same) {
        for (want, got) |x, y| {
            const ok = if (x.block) |expected|
                if (y.block) |*actual| expected.eql(actual) else false
            else if (y.block != null)
                false
            else
                std.mem.eql(u8, x.text, y.text) and marksEql(x.marks, y.marks);
            if (!ok) {
                same = false;
                break;
            }
        }
    }
    if (same) return;

    try w.print("expected {d} spans, got {d}\n  want:\n", .{ want.len, got.len });
    for (want) |s| {
        if (s.block != null) {
            try w.print("    Block\n", .{});
        } else {
            try w.print("    Text {s} marks=[", .{s.text});
            try writeMarkList(w, s.marks);
            try w.print("]\n", .{});
        }
    }
    try w.print("  got:\n", .{});
    for (got) |s| {
        if (s.block != null) {
            try w.print("    Block\n", .{});
        } else {
            try w.print("    Text {s} marks=[", .{s.text});
            try writeMarkList(w, s.marks);
            try w.print("]\n", .{});
        }
    }
    std.debug.print("{s}", .{report.written()});
    return error.TestExpectedEqual;
}

fn writeMarkList(w: *std.Io.Writer, entries: []const MarkSet.Entry) !void {
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s}=", .{e.name});
        try writeScalar(w, e.value);
    }
}

/// Render scalar mark values for comparison diagnostics.
fn writeScalar(w: *std.Io.Writer, s: ScalarValue) !void {
    switch (s) {
        .null_value => try w.writeAll("Null"),
        .bool_value => |b| try w.print("Bool({})", .{b}),
        .int => |i| try w.print("Int({d})", .{i}),
        .uint => |u| try w.print("Uint({d})", .{u}),
        .float => |f| try w.print("Float({d})", .{f}),
        .str => |t| try w.print("Str(\"{s}\")", .{t}),
        .bytes => |b| try w.print("Bytes({d})", .{b.len}),
        .counter => |c| try w.print("Counter({d})", .{c.current}),
        .timestamp => |t| try w.print("Timestamp({d})", .{t}),
        .actor_id => |a| try w.print("ActorId({d} bytes)", .{a.bytes.len}),
        .unknown => |u| try w.print("Unknown({d}, {d} bytes)", .{ u.type_code, u.bytes.len }),
    }
}

// 1 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: overlapping marks lose one and keep the other" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "hello world");
    try f.doc.mark(f.text, 6, 11, "bold", .both, .{ .bool_value = true });
    try f.doc.mark(f.text, 6, 11, "italic", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain("hello ");
    try spans.marked("world", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "hello " },
        .{ .text = "world", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 2 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: overlapping marks change boundaries" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "hello beautiful world");
    try f.doc.mark(f.text, 0, 15, "bold", .both, .{ .bool_value = true });
    try f.doc.mark(f.text, 6, 21, "italic", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("hello", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" beautiful ");
    try spans.marked("world", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "hello", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " beautiful " },
        .{ .text = "world", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
    });
}

// 3 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: overlapping marks take on a third" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "hello world");
    try f.doc.mark(f.text, 0, 11, "bold", .both, .{ .bool_value = true });
    try f.doc.mark(f.text, 6, 11, "italic", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("hel", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.marked("lo wo", &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "underline", .value = .{ .bool_value = true } },
    });
    try spans.marked("rld", &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "italic", .value = .{ .bool_value = true } },
        .{ .name = "underline", .value = .{ .bool_value = true } },
    });
    try f.doc.updateSpans(f.text, spans.items.items);

    // Upstream joins every span's text and compares it with the whole, because
    // "the exact number of spans depends on grapheme clustering"
    // (`diff_marks.rs`:178). The port's default encoding is code points, so the
    // three spans above are the whole object, and saying so is stronger than
    // joining them.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "hel", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = "lo wo", .marks = &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
            .{ .name = "underline", .value = .{ .bool_value = true } },
        } },
        .{ .text = "rld", .marks = &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
            .{ .name = "italic", .value = .{ .bool_value = true } },
            .{ .name = "underline", .value = .{ .bool_value = true } },
        } },
    });

    const all = try f.doc.text(f.text, gpa);
    defer gpa.free(all);
    try testing.expectEqualStrings("hello world", all);
}

// 4 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark expands" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text");
    try f.doc.mark(f.text, 0, 4, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold text", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold text", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 5 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark contracts" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text");
    try f.doc.mark(f.text, 0, 9, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" text");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " text" },
    });
}

// 6 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark shifts position" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text");
    try f.doc.mark(f.text, 0, 4, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain("text ");
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "text " },
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 7 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark splits in two" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text here");
    try f.doc.mark(f.text, 0, 14, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" text ");
    try spans.marked("here", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " text " },
        .{ .text = "here", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 8 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: adjacent marks of one name merge" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text");
    try f.doc.mark(f.text, 0, 4, "bold", .both, .{ .bool_value = true });
    try f.doc.mark(f.text, 5, 9, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold text", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold text", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 9 ───────────────────────────────────────────────────────────────────────────

test "diff_marks: adjacent marks of one name stay separate" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text");

    // Applied twice, because upstream applies it twice and reads the spans
    // after: the second pass is what proves the shape is stable rather than
    // the first pass's own result.
    for (0..2) |_| {
        var spans = NewSpans.init(gpa);
        defer spans.deinit();
        try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
        try spans.plain(" ");
        try spans.marked("text", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
        try f.doc.updateSpans(f.text, spans.items.items);
    }

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " " },
        .{ .text = "text", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 10 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: different marks side by side" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bolditalic");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.marked("italic", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = "italic", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
    });
}

// 11 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark over empty text produces no span" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{});
}

// 12 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: marks over whitespace" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked(" ", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.marked("\n", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = " ", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = "\n", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
    });
}

// 13 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: removing all the text from a marked span" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "hello world");
    try f.doc.mark(f.text, 0, 5, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain(" world");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{.{ .text = " world" }});
}

// 14 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark spans across a block" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold");
    const block = try f.doc.splitBlock(f.text, 4);
    try f.doc.spliceText(f.text, 5, 0, "text");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.block(&f.doc, block);
    try spans.marked("text", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .block = spans.items.items[1].block },
        .{ .text = "text", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 15 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark ends at a block boundary" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold");
    const block = try f.doc.splitBlock(f.text, 4);
    try f.doc.spliceText(f.text, 5, 0, "text");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.block(&f.doc, block);
    try spans.plain("text");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .block = spans.items.items[1].block },
        .{ .text = "text" },
    });
}

// 16 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: marks nested inside one another" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "italic bold and italic just italic");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("italic ", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try spans.marked("bold and italic", &.{
        .{ .name = "italic", .value = .{ .bool_value = true } },
        .{ .name = "bold", .value = .{ .bool_value = true } },
    });
    try spans.marked(" just italic", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "italic ", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
        .{ .text = "bold and italic", .marks = &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
            .{ .name = "italic", .value = .{ .bool_value = true } },
        } },
        .{ .text = " just italic", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
    });
}

// 17 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: many marks on one run of text" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "formatted");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("formatted", &.{
        .{ .name = "bold", .value = .{ .bool_value = true } },
        .{ .name = "italic", .value = .{ .bool_value = true } },
        .{ .name = "link", .value = .{ .str = "https://example.com" } },
        .{ .name = "underline", .value = .{ .bool_value = true } },
    });
    try f.doc.updateSpans(f.text, spans.items.items);

    // **Four marks, named.** Upstream only counts them (`diff_marks.rs`:751`),
    // which passes on four marks of the same name; a set is a map from name to
    // value, so naming all four says what the span actually carries.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "formatted", .marks = &.{
            .{ .name = "bold", .value = .{ .bool_value = true } },
            .{ .name = "italic", .value = .{ .bool_value = true } },
            .{ .name = "link", .value = .{ .str = "https://example.com" } },
            .{ .name = "underline", .value = .{ .bool_value = true } },
        } },
    });
}

// 18 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark's value changes its link url" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "click here");
    try f.doc.mark(f.text, 0, 10, "link", .both, .{ .str = "https://old.com" });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("click here", &.{.{ .name = "link", .value = .{ .str = "https://new.com" } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "click here", .marks = &.{.{ .name = "link", .value = .{ .str = "https://new.com" } }} },
    });
}

// 19 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark's value changes its colour" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "colored");
    try f.doc.mark(f.text, 0, 7, "color", .both, .{ .str = "red" });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("colored", &.{.{ .name = "color", .value = .{ .str = "blue" } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "colored", .marks = &.{.{ .name = "color", .value = .{ .str = "blue" } }} },
    });
}

// 20 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark's value changes type" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "text");
    try f.doc.mark(f.text, 0, 4, "custom", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("text", &.{.{ .name = "custom", .value = .{ .str = "value" } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    // **The value is a string, not the boolean it was.** The old mark is gone
    // and the new one is in its place, which is the whole of the test.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "text", .marks = &.{.{ .name = "custom", .value = .{ .str = "value" } }} },
    });
}

// 21 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: three marks grow in three directions" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    // `config.per_mark_expands.insert(..)` for three names
    // (`diff_marks.rs`:868-877`). Upstream mutates the `Default` config's map;
    // the port's [`UpdateSpansConfig.setMarkExpand`] is a statement for the
    // reason its doc gives, and the three names are the three upstream uses.
    var config = UpdateSpansConfig.init(gpa);
    defer config.deinit();
    try config.setMarkExpand("before", .before);
    try config.setMarkExpand("after", .after);
    try config.setMarkExpand("none", .none);

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("text", &.{
        .{ .name = "before", .value = .{ .bool_value = true } },
        .{ .name = "after", .value = .{ .bool_value = true } },
        .{ .name = "none", .value = .{ .bool_value = true } },
    });
    try f.doc.updateSpansWithConfig(f.text, &config, spans.items.items);

    // Upstream's two inserts (`diff_marks.rs`:894`, `:896`): `"a"` at 0 and
    // `"b"` at 5, which is the end of `"atext"` and not of `"text"`.
    try f.doc.spliceText(f.text, 0, 0, "a");
    try f.doc.spliceText(f.text, 5, 0, "b");

    // **Which mark is over which text, and no mark over the other end.**
    // Upstream asserts a count of three (`diff_marks.rs`:902`) and says
    // nothing about what is in the three. The permissive failure was measured
    // rather than guessed — with every mark written as [`ExpandMark.both`] this
    // object reads as **one** span, `atextb`, carrying all three names — and
    // the three assertions below are the negatives that a count cannot carry:
    // `none` covers `"text"` and neither the `"a"` before it nor the `"b"`
    // after it, `before` reaches `"a"` and not `"b"`, and `after` is the other
    // way round. A mark set is name-sorted, so the entries are in name order.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "a", .marks = &.{.{ .name = "before", .value = .{ .bool_value = true } }} },
        .{ .text = "text", .marks = &.{
            .{ .name = "after", .value = .{ .bool_value = true } },
            .{ .name = "before", .value = .{ .bool_value = true } },
            .{ .name = "none", .value = .{ .bool_value = true } },
        } },
        .{ .text = "b", .marks = &.{.{ .name = "after", .value = .{ .bool_value = true } }} },
    });
}

// 22 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark with expand none stays where it is" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    // `UpdateSpansConfig::default().with_default_expand(ExpandMark::None)`
    // (`diff_marks.rs`:910) — the default for **every** name, so this is the
    // config's [`default_expand`](UpdateSpansConfig) and not its map.
    var config = UpdateSpansConfig.init(gpa);
    defer config.deinit();
    _ = config.withDefaultExpand(.none);

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("text", &.{.{ .name = "mark", .value = .{ .bool_value = true } }});
    try f.doc.updateSpansWithConfig(f.text, &config, spans.items.items);

    // Upstream's inserts at both boundaries (`diff_marks.rs`:923-924`).
    try f.doc.spliceText(f.text, 0, 0, "before ");
    try f.doc.spliceText(f.text, 11, 0, " after");

    // **Both inserted runs are unmarked, and each is an absence rather than a
    // length.** Upstream compares the three spans, which is what this does.
    // What makes it a real check is the measured alternative: with
    // [`ExpandMark.after`] — what this port wrote before, and this case's
    // entire subject — the mark swallows both inserts and the object reads as
    // **one** span, `before text after`, with `mark` over all of it.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "before " },
        .{ .text = "text", .marks = &.{.{ .name = "mark", .value = .{ .bool_value = true } }} },
        .{ .text = " after" },
    });
}

// 23 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark over a family emoji" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    // U+1F468 ZWJ U+1F469 ZWJ U+1F467 ZWJ U+1F466, spelled out because the
    // joiners are invisible and a failure would not show what went wrong.
    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}";
    try f.doc.spliceText(f.text, 0, 0, "Hello " ++ family ++ " world");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain("Hello ");
    try spans.marked(family, &.{.{ .name = "emoji", .value = .{ .bool_value = true } }});
    try spans.plain(" world");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "Hello " },
        .{ .text = family, .marks = &.{.{ .name = "emoji", .value = .{ .bool_value = true } }} },
        .{ .text = " world" },
    });
}

// 24 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mark over text that is not plain ASCII" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "caf\u{e9}");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("caf\u{e9}", &.{.{ .name = "accented", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "caf\u{e9}", .marks = &.{.{ .name = "accented", .value = .{ .bool_value = true } }} },
    });
    const all = try f.doc.text(f.text, gpa);
    defer gpa.free(all);
    try testing.expectEqualStrings("caf\u{e9}", all);
}

// 25 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: removing a mark from the middle of its range" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "bold text here");
    try f.doc.mark(f.text, 0, 14, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("bold", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" text ");
    try spans.marked("here", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "bold", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " text " },
        .{ .text = "here", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 26 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: removing marks leaves gaps" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "a b c d e");
    try f.doc.mark(f.text, 0, 9, "mark", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    const m = MarkSet.Entry{ .name = "mark", .value = .{ .bool_value = true } };
    try spans.marked("a", &.{m});
    try spans.plain(" b ");
    try spans.marked("c", &.{m});
    try spans.plain(" d ");
    try spans.marked("e", &.{m});
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "a", .marks = &.{m} },
        .{ .text = " b " },
        .{ .text = "c", .marks = &.{m} },
        .{ .text = " d " },
        .{ .text = "e", .marks = &.{m} },
    });
}

// 27 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a block's properties change while its marks stay" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    const block = try f.doc.splitBlock(f.text, 0);
    try f.doc.spliceText(f.text, 1, 0, "marked text");
    try f.doc.mark(f.text, 1, 7, "bold", .both, .{ .bool_value = true });

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.block(&f.doc, block);
    try spans.putBlock(0, "type", .{ .str = "paragraph" });
    try spans.putBlock(0, "level", .{ .int = 1 });
    try spans.marked("marked", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" text");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .block = spans.items.items[0].block },
        .{ .text = "marked", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " text" },
    });
}

// 28 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: update_spans is idempotent" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var first: ?[]types.ChangeHash = null;
    defer if (first) |h| gpa.free(h);

    for (0..3) |_| {
        var spans = NewSpans.init(gpa);
        defer spans.deinit();
        try spans.marked("hello ", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
        try spans.marked("world", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
        try f.doc.updateSpans(f.text, spans.items.items);

        // `getHeads` allocates and the slice is the caller's
        // (`doc.zig`:3601-3606`), so every round's copy is freed here and only
        // the first is kept, to compare the rest against.
        const heads = try f.doc.getHeads(gpa);
        if (first) |held| {
            defer gpa.free(heads);
            // **Nothing changed after the first round**, so the heads are the
            // same. Upstream compares head lists (`diff_marks.rs`:1159-1160`);
            // a head that moved is a change that was written for nothing.
            try testing.expectEqual(held.len, heads.len);
            for (held, heads) |a, b| try testing.expect(a.eql(b));
        } else {
            first = heads;
        }
    }
}

// 29 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: alternating mark changes" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "text");

    var bold = NewSpans.init(gpa);
    defer bold.deinit();
    try bold.marked("text", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, bold.items.items);

    var bare = NewSpans.init(gpa);
    defer bare.deinit();
    try bare.plain("text");
    try f.doc.updateSpans(f.text, bare.items.items);

    var italic = NewSpans.init(gpa);
    defer italic.deinit();
    try italic.marked("text", &.{.{ .name = "italic", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, italic.items.items);

    // **Italic, and only italic.** A mark that survives its own removal, or a
    // bold that never went, would both pass a length check.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "text", .marks = &.{.{ .name = "italic", .value = .{ .bool_value = true } }} },
    });
}

// 30 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: a mix of scripts and emoji" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain("Hello ");
    try spans.marked("\u{1f60a}", &.{.{ .name = "emoji", .value = .{ .bool_value = true } }});
    try spans.marked(" \u{4e16}\u{754c} ", &.{.{ .name = "chinese", .value = .{ .bool_value = true } }});
    try spans.marked("\u{1f30d}", &.{.{ .name = "emoji", .value = .{ .bool_value = true } }});
    try spans.marked(" \u{0645}\u{0631}\u{062d}\u{0628}\u{0627}", &.{
        .{ .name = "arabic", .value = .{ .bool_value = true } },
    });
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "Hello " },
        .{ .text = "\u{1f60a}", .marks = &.{.{ .name = "emoji", .value = .{ .bool_value = true } }} },
        .{ .text = " \u{4e16}\u{754c} ", .marks = &.{.{ .name = "chinese", .value = .{ .bool_value = true } }} },
        .{ .text = "\u{1f30d}", .marks = &.{.{ .name = "emoji", .value = .{ .bool_value = true } }} },
        .{ .text = " \u{0645}\u{0631}\u{062d}\u{0628}\u{0627}", .marks = &.{
            .{ .name = "arabic", .value = .{ .bool_value = true } },
        } },
    });
}

// 31 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: blocks with marked content" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    // diff_marks.rs:1254-1287 creates both blocks through their map payloads.
    try spans.emptyBlock();
    try spans.putBlock(0, "type", .{ .str = "heading" });
    try spans.putBlock(0, "level", .{ .int = 1 });
    try spans.plain("Chapter ");
    try spans.marked("One", &.{.{ .name = "emphasis", .value = .{ .bool_value = true } }});
    try spans.emptyBlock();
    try spans.putBlock(3, "type", .{ .str = "paragraph" });
    try spans.plain("This is the ");
    try spans.marked("first", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try spans.plain(" chapter.");
    try f.doc.updateSpans(f.text, spans.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .block = spans.items.items[0].block },
        .{ .text = "Chapter " },
        .{ .text = "One", .marks = &.{.{ .name = "emphasis", .value = .{ .bool_value = true } }} },
        .{ .block = spans.items.items[3].block },
        .{ .text = "This is the " },
        .{ .text = "first", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
        .{ .text = " chapter." },
    });
}

// 32 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: an empty span between two marked ones" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    const m = MarkSet.Entry{ .name = "mark", .value = .{ .bool_value = true } };
    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("a", &.{m});
    try spans.plain("");
    try spans.marked("b", &.{m});
    try f.doc.updateSpans(f.text, spans.items.items);

    // **The empty span is not there and the two marked runs are one.** A
    // reader that emitted the empty run, or that failed to coalesce, would
    // give two spans here.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "ab", .marks = &.{m} },
    });
}

// 33 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: one mark name with three different values" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "red blue green");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.marked("red", &.{.{ .name = "color", .value = .{ .str = "red" } }});
    try spans.plain(" ");
    try spans.marked("blue", &.{.{ .name = "color", .value = .{ .str = "blue" } }});
    try spans.plain(" ");
    try spans.marked("green", &.{.{ .name = "color", .value = .{ .str = "green" } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    // **Each run carries its own value.** Three runs of one mark name with the
    // value of the first on all three would pass upstream's count.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "red", .marks = &.{.{ .name = "color", .value = .{ .str = "red" } }} },
        .{ .text = " " },
        .{ .text = "blue", .marks = &.{.{ .name = "color", .value = .{ .str = "blue" } }} },
        .{ .text = " " },
        .{ .text = "green", .marks = &.{.{ .name = "color", .value = .{ .str = "green" } }} },
    });
}

// 34 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: update_spans with nothing but blocks" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "text");
    _ = try f.doc.splitBlock(f.text, 4);
    try f.doc.spliceText(f.text, 5, 0, "more");

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.emptyBlock();
    try spans.emptyBlock();
    try f.doc.updateSpans(f.text, spans.items.items);

    // **Two block markers and no text at all.** Upstream asserts only that
    // some block survives; saying what is left is the stronger statement and
    // it is what "remove all the text" has to mean.
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .block = spans.items.items[0].block },
        .{ .block = spans.items.items[1].block },
    });
}

// 35 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: marks survive a block update" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    var first = NewSpans.init(gpa);
    defer first.deinit();
    // diff_marks.rs:1428-1454 changes block properties through update_spans.
    try first.emptyBlock();
    try first.putBlock(0, "type", .{ .str = "p" });
    try first.marked("marked", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, first.items.items);

    var second = NewSpans.init(gpa);
    defer second.deinit();
    try second.emptyBlock();
    try second.putBlock(0, "type", .{ .str = "h1" });
    try second.putBlock(0, "level", .{ .int = 1 });
    try second.marked("marked", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, second.items.items);

    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .block = second.items.items[0].block },
        .{ .text = "marked", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

// 36 ──────────────────────────────────────────────────────────────────────────

test "diff_marks: an insertion at the end of an expanding mark writes no mark" {
    const gpa = testing.allocator;
    var f = try markFixture(gpa);
    defer f.deinit();

    try f.doc.spliceText(f.text, 0, 0, "hello world");
    try f.doc.mark(f.text, 6, 11, "bold", .both, .{ .bool_value = true });

    // Match the upstream commit boundary (diff_marks.rs:1487). Count the
    // operation rows added by the following update: only its two insertions.
    _ = try f.doc.commit();
    const before = f.doc.doc.ops.len();

    var spans = NewSpans.init(gpa);
    defer spans.deinit();
    try spans.plain("hello ");
    try spans.marked("wworldd", &.{.{ .name = "bold", .value = .{ .bool_value = true } }});
    try f.doc.updateSpans(f.text, spans.items.items);

    // **Two rows, and two rows is exactly the two inserted characters.** The
    // mark already expands to cover what was typed at its end, so the second
    // pass of `update_spans` finds the mark it wants already there
    // (`text_diff.rs`:206-213`) and writes no unmark and no mark. Four more
    // rows would mean the mark had been torn down and rewritten.
    try testing.expectEqual(@as(usize, 2), f.doc.doc.ops.len() - before);
    try expectDocSpans(gpa, &f.doc, f.text, &.{
        .{ .text = "hello " },
        .{ .text = "wworldd", .marks = &.{.{ .name = "bold", .value = .{ .bool_value = true } }} },
    });
}

test "diff_marks: copied reader marks survive span and document teardown" {
    const gpa = testing.allocator;
    var fixture = try markFixture(gpa);
    var fixture_live = true;
    defer if (fixture_live) fixture.deinit();
    try fixture.doc.spliceText(fixture.text, 0, 0, "linked");
    try fixture.doc.mark(fixture.text, 0, 6, "link", .both, .{ .str = "https://example.com" });
    const found = try readSpanList(gpa, &fixture.doc, fixture.text);
    defer {
        for (found) |*span| span.deinit(gpa);
        gpa.free(found);
    }
    fixture.deinit();
    fixture_live = false;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("linked", found[0].text);
    try testing.expect(marksEql(found[0].marks, &.{
        .{ .name = "link", .value = .{ .str = "https://example.com" } },
    }));
}

test "parity rich marks filtered view ignores null tombstones" {
    // The borrowed view must compare visible names and values, not tombstones.
    var left = MarkSet.init(std.testing.allocator);
    defer left.deinit();
    var right = MarkSet.init(std.testing.allocator);
    defer right.deinit();
    try left.put("deleted", .null_value);
    try testing.expect(left.nonDeletedMarks().isEmpty());
    try left.put("bold", .{ .bool_value = true });
    try right.put("bold", .{ .bool_value = true });
    const visible = left.nonDeletedMarks();
    try testing.expectEqual(@as(usize, 1), visible.len());
    try testing.expect(visible.eql(right.nonDeletedMarks()));
    try right.put("bold", .{ .bool_value = false });
    try testing.expect(!visible.eql(right.nonDeletedMarks()));
}

test "parity rich marks duplicate owns names and scalar bytes" {
    // Releasing the source buffers must not invalidate the independent copy.
    const gpa = std.testing.allocator;
    const name = try gpa.dupe(u8, "link");
    const payload = try gpa.dupe(u8, "target");
    var source = MarkSet.init(gpa);
    try source.put(name, .{ .str = payload });
    var copied = try source.dup(gpa);
    defer copied.deinit();
    source.deinit();
    gpa.free(name);
    gpa.free(payload);
    const entry = copied.entries.items[0];
    try std.testing.expectEqualStrings("link", entry.name);
    try std.testing.expectEqualStrings("target", entry.value.str);
    try copied.put("link", .{ .str = "replacement" });
    try std.testing.expectEqualStrings("replacement", copied.entries.items[0].value.str);
}

fn ownedMarksAllocationBoundaries(gpa: Allocator) !void {
    var source = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "actor", .value = .{ .actor_id = .{ .bytes = "actor-bytes" } } },
        .{ .name = "bytes", .value = .{ .bytes = "binary" } },
        .{ .name = "link", .value = .{ .str = "target" } },
        .{ .name = "unknown", .value = .{
            .unknown = .{ .type_code = 12, .bytes = "future" },
        } },
    });
    defer source.deinit();
    var owned = source.dup(gpa) catch |failure| {
        try testing.expectEqualStrings("target", source.entries.items[2].value.str);
        return failure;
    };
    defer owned.deinit();
    try testing.expect(owned.eql(&source));
    // Replacement must copy before releasing an aliased prior payload.
    owned.put(owned.entries.items[2].name, owned.entries.items[2].value) catch |failure| {
        try testing.expect(owned.eql(&source));
        return failure;
    };
    owned.put("added", .{ .str = "new" }) catch |failure| {
        try testing.expect(owned.eql(&source));
        return failure;
    };
    owned.remove("actor");
    try testing.expectEqual(@as(usize, 4), owned.len());
    try testing.expectEqualStrings("actor-bytes", source.entries.items[0].value.actor_id.bytes);
    try testing.expectEqualStrings("target", source.entries.items[2].value.str);
}

test "parity rich marks owned duplication and mutation allocation boundaries" {
    // Every refused allocation preserves its input and releases partial copies.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        ownedMarksAllocationBoundaries,
        .{},
    );
}

fn ownedMarksStripAllocationBoundaries(gpa: Allocator) !void {
    var source = try MarkSet.fromPairs(gpa, &.{
        .{ .name = "gone", .value = .null_value },
        .{ .name = "link", .value = .{ .str = "target" } },
    });
    defer source.deinit();
    const owned = try source.dup(gpa);
    // Consumed on success and failure: no separate owned.deinit is permitted.
    var visible = try owned.withoutUnmarks();
    defer visible.deinit();
    try testing.expectEqual(@as(usize, 1), visible.len());
    try testing.expectEqualStrings("link", visible.entries.items[0].name);
    try testing.expectEqualStrings("target", visible.entries.items[0].value.str);
    try visible.put("link", visible.entries.items[0].value);
}

test "parity rich marks owned filtering survives consumed source allocation boundaries" {
    // The filtered owned result remains usable after its input is destroyed.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        ownedMarksStripAllocationBoundaries,
        .{},
    );
}

test "parity rich marks owned insertion copies transient inputs and removal is independent" {
    // Mutation of a duplicate retains no caller buffers or source payloads.
    const gpa = testing.allocator;
    var source = MarkSet.init(gpa);
    defer source.deinit();
    try source.put("original", .{ .str = "unchanged" });
    var owned = try source.dup(gpa);
    defer owned.deinit();
    {
        const name = try gpa.dupe(u8, "transient");
        defer gpa.free(name);
        const actor = try gpa.dupe(u8, "ephemeral-actor");
        defer gpa.free(actor);
        try owned.put(name, .{ .actor_id = .{ .bytes = actor } });
    }
    try testing.expectEqualStrings("transient", owned.entries.items[1].name);
    try testing.expectEqualStrings(
        "ephemeral-actor",
        owned.entries.items[1].value.actor_id.bytes,
    );
    owned.remove("original");
    try testing.expectEqualStrings("unchanged", source.entries.items[0].value.str);
}
