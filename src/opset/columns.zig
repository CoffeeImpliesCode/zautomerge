//! The op set's sixteen data columns and five index columns, and the four
//! operations that move rows between them.
//!
//! Upstream `op_set2/columns.rs` (664 lines) is a struct of hexane columns
//! and four functions over them: `splice` (`columns.rs:419-492`), `remove_ops`
//! (`:361-417`), `export` (`:172-184`) and `load` (`:252-330`). Everything
//! else in the file is a `Default`, a debug comparison, a dump or a test
//! helper. This is that struct and those four functions, plus `validate`
//! (`:219-249`) and the three actor-rewriting entry points (`:332-358`).
//!
//! # What the columns are
//!
//! A row of the op set is one operation, held as sixteen parallel columns of
//! the same length (`columns.rs:17-35`). The row count *is*
//! `id_actor.len()` and the flattened successor count *is* `succ_actor.len()`
//! (`:504-510`); every other count follows from those two, and the five index
//! columns are the derived views the query layer reads instead of scanning
//! the data (`:37-43`).
//!
//! | column | holds | codec | upstream |
//! | --- | --- | --- | --- |
//! | `id_actor` | the op's actor | `Rle(ActorIdx)` | `columns.rs:18` |
//! | `id_ctr` | the op's counter | `Delta(u32)` | `:19` |
//! | `obj_actor`, `obj_ctr` | the parent's id, null at the root | `RleOption` | `:20-21` |
//! | `key_actor`, `key_ctr` | a sequence anchor's id, null for a map key | `RleOption`, `DeltaOption` | `:22-23` |
//! | `key_str` | a map key, as an interned id | `RleOption(u32)` | `:22` |
//! | `succ_count` | how many successors the row has | `Prefix(u32)` | `:24` |
//! | `succ_actor`, `succ_ctr` | the successors, flattened | `Rle`, `Delta` | `:25-26` |
//! | `insert` | whether the op inserts | boolean, prefix-weighted | `:28` |
//! | `action` | the action, as its wire code | `Rle(u64)` | `:29` |
//! | `value_meta` | the value's metadata word | `Rle(u64)`, prefix-weighted on the *length* | `:30` |
//! | `value` | the value's payload | `RawColumn` | `:31` |
//! | `mark_name` | a mark's name, as an interned id | `RleOption(u32)` | `:32` |
//! | `expand` | whether a mark expands | boolean | `:33` |
//!
//! # Three places this differs from upstream, and why
//!
//! **The two string columns hold interned ids.** The wire carries the string
//! itself, length-prefixed under `ColumnType::String`; this port's column
//! layer is integer-only, so those two columns hold a counter into the
//! document's string table, which is what the port plan chose
//! ([plan §5.3](../../docs/plan.md), and the same decision for a change's key
//! column at [columnar/columns.zig:46-49](../columnar/columns.zig)). The
//! translation happens at the three points where ids become bytes and back:
//! `splice` interns what the ops carry, `export` resolves, `load` interns.
//! Nothing else may write those two columns.
//!
//! **The mark index is one type, split across two files, and it is derived
//! state.** Upstream's `MarkIndexColumn`
//! (`op_set2/op_set/mark_index.rs:213-217`) is a row column *and* a cache
//! from op id to `MarkData` as a single value, and the port's is that same
//! value, declared once in [mark_index.zig](mark_index.zig). This file owns
//! the storage half — what a splice writes into it, and what an undo takes
//! back out — because that is where load and export live. The query half,
//! `hasAnyMarks`, `markData`, `marksAt`, `richTextAt` and `remapValues`, is
//! that file's, and none of it can exist without the cache. Neither half
//! declares a second `MarkIdx` or a second `MarkIndexColumn`: two types with
//! those names and the same `extend`/`undo` seam would be two definitions of
//! the same rows.
//!
//! None of it is a stored format. The exporter writes the sixteen data
//! columns and has no arm for the mark index (`columns.rs:135-170`), and a
//! load builds the index columns empty (`:252-330`, `Indexes::default` at
//! `:314`) because every one of them is derived state the data columns
//! already determine. What a load does hand back is the *mark name*,
//! interned through the string table; the words are pinned anyway, because
//! this port's column layer is integer-only and the word is what the column
//! holds ([mark_index.zig:6-32](mark_index.zig)).
//!
//! **The one borrow in this file: a cached `MarkData` name is anchored in
//! the document's string table.** The cache holds a `MarkData`, whose name
//! is a borrowed slice ([marks.zig:462-474](../marks.zig)). `splice` does
//! not hand the cache the name the op carries: it interns the name first —
//! `internMarkName` copies the bytes into the document's own table — and
//! hands over the *resolved* interned string, so the name outlives the op
//! that carried it. The owner is the [`StringTable`] the splice was handed,
//! and it must outlive the op set that caches into it. A name taken straight
//! off an op would dangle as soon as the change it was read out of was
//! dropped, and the cache is what `markData` hands to every mark reader.
//!
//! **A delete is never a row.** Both `splice` and `remove_ops` drop every op
//! whose action is `Delete` before anything is written
//! (`columns.rs:365`, `:423`) and return the number of *rows* written, not the
//! number of ops passed. A delete exists only as a successor id on its
//! predecessor, with a null entry in `index.inc`.
//!
//! # The two prefix positions
//!
//! `splice` and `remove_ops` both read two byte offsets *before* they move
//! anything (`columns.rs:425-426`, `:368-369`): `value_meta.get_prefix(pos)`,
//! where row `pos`'s payload starts in the raw value arena, and
//! `succ_count.get_prefix(pos)`, where row `pos`'s successors start in the
//! flattened pair. Both are sums over the columns being spliced, so computing
//! either after the splice has moved that column would read a different
//! answer. That is why they are the first two statements in both functions.
//!
//! # The op type
//!
//! Upstream writes the row accessors once, as the `OpLike` trait
//! (`op_set2/op.rs:1327-1372`). Its successor iterator is a generic
//! associated type, which Zig has no spelling for
//! ([survey §Zig mapping notes](../../docs/survey/02-transaction-opset.md)),
//! so this file is generic over the op type `O` and calls a fixed set of
//! accessors on it — the split the survey settles on. `op.zig` owns `Op`;
//! nothing here reaches into its fields.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const hexane = @import("../hexane/column.zig");
const rawcol = @import("../hexane/raw.zig");
const columnar = @import("../columnar/encoding.zig");
const colspec = @import("../storage/column_spec.zig");
const docchunk = @import("../storage/document_chunk.zig");
const chunkmod = @import("../storage/chunk.zig");
const ids = @import("ids.zig");
const optypes = @import("types.zig");
const markidx = @import("mark_index.zig");
const leb128 = @import("../leb128.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ColumnSpec = colspec.ColumnSpec;
const ColumnDesc = colspec.ColumnDesc;
const RawColumn = colspec.RawColumn;
const RawColumns = colspec.RawColumns;
const ActorIdx = types.ActorIdx;
const OpId = types.OpId;
const Action = optypes.Action;
const KeyRef = optypes.KeyRef;
const ValueMeta = optypes.ValueMeta;

// ── Codecs the column layer does not have ──────────────────────────────────
//
// A `Column(T, E)` names its slab codec as a type parameter
// ([column.zig:10-27](../hexane/column.zig)), and the four codecs it ships
// are integer-only. Three of the op set's sixteen columns are not integers:
// two are booleans that also carry a prefix sum, and one is a metadata word
// whose prefix is the *length* rather than the word. Both are the same wire
// format as a codec the column layer already has, with a different weight,
// so each is written here as that codec with the weight swapped.

/// `PrefixColumn<bool>`: the boolean wire format, indexed by the number of
/// true rows in front of a slab (`columns.rs:28`, `:39`).
///
/// Upstream's `PrefixValue for bool` adds `val as usize`
/// (`hexane/src/prefix.rs:316-325`), so the prefix sum counts *inserts* and
/// *tops*, which is the offset of a row in its object's visible run. The wire
/// is the boolean codec's, unchanged: `expand` and `index.visible` are
/// `Column<bool>` (`columns.rs:33`, `:41`) and carry the same bytes.
pub const BoolPrefixCodec = struct {
    pub const Value = bool;
    pub const Wire = bool;
    pub const Weight = hexane.PrefixWeight;
    pub const has_lit_header = hexane.Bool.has_lit_header;
    pub const tracks_prefix = true;
    pub const is_prefix_column = true;
    pub const is_delta = false;
    pub const WireDecoder = hexane.Bool.WireDecoder;
    /// The boolean wire walk a streaming load drives.
    pub const LoadCursor = hexane.Bool.LoadCursor;
    /// The boolean streaming encoder, unchanged by the swapped weight.
    pub const StreamEncoder = hexane.Bool.StreamEncoder;

    pub const segmentsOf = hexane.Bool.segmentsOf;
    pub const wireRange = hexane.Bool.wireRange;
    /// A boolean run carries no payload: its value is its position in the
    /// run sequence, so `to - from` copies of `value` **is** the run's items.
    /// A fragment cut out of a longer sequence cannot say so for itself —
    /// read on its own it opens on the `false` run a slab's own bytes open
    /// on — so the value the run carries has to be handed over with it
    /// (`hexane/bool.zig:13-25`, `bool.rs:988-1002`). The swapped weight
    /// does not change the wire, so this is the boolean codec's own.
    pub const wireRunItems = hexane.Bool.wireRunItems;
    pub const wireEncode = hexane.Bool.wireEncode;
    pub const wireFill = hexane.Bool.wireFill;
    pub const fillBytes = hexane.Bool.fillBytes;
    pub const wireSlice = hexane.Bool.wireSlice;
    pub const lastValueOfRun = hexane.Bool.lastValueOfRun;
    pub const litTail = hexane.Bool.litTail;
    pub const litHead = hexane.Bool.litHead;
    pub const runAtOrAfter = hexane.Bool.runAtOrAfter;
    pub const firstRunValue = hexane.Bool.firstRunValue;
    pub const literalValueAt = hexane.Bool.literalValueAt;
    pub const valueOfWire = hexane.Bool.valueOfWire;
    pub const wireOfInsert = hexane.Bool.wireOfInsert;
    pub const reanchor = hexane.Bool.reanchor;
    pub const sameValue = hexane.Bool.sameValue;
    pub const mustMergeKinds = hexane.Bool.mustMergeKinds;
    pub const canonicalSlab = hexane.Bool.canonicalSlab;

    /// The slab's item count, and the number of true rows in it, the second
    /// refused as `error.Overflow` rather than wrapped.
    ///
    /// **The fold is over runs, and a boolean run is O(1) to read however
    /// long it is.** A boolean slab is a sequence of counts and holds no
    /// value bytes at all (`bool.zig:12-15`, `bool.rs:13-25`), so a run of a
    /// million `true`s costs the same single varint as a run of one, and
    /// [`nextRunMax`](WireDecoder.nextRunMax) hands back `count` copies of
    /// `value` in one step (`bool.zig:312-323`, `bool.rs:603-616`). A slab's
    /// weight is the count of its true rows (`hexane/src/prefix.rs:316-325`),
    /// and upstream's own fold of a run is
    /// `target += run.value as usize * run.count` (`prefix.rs:322-324`) —
    /// which is the addition below, in the type this port keeps: `i64`, where
    /// upstream keeps `usize` and where a sum that leaves the range is
    /// refused rather than wrapped.
    ///
    /// **This is the walk every reindex pays.** `Column.reindexFrom`
    /// (`hexane/column.zig:6687-6693`) calls `weightOf` for every slab from
    /// the first one a splice touched, and `settle` reaches it on every
    /// splice (`column.zig:6553`), so the row-at-a-time fold this replaces
    /// charged every edit a row per row from that slab on, however few runs
    /// those rows were cut into. A boolean slab is the cheapest case for that
    /// and the most wasteful: a slab of a million `true`s is one varint on
    /// the wire and a million iterations here.
    ///
    /// **Every caller gets it.** There is no second walk to bring over: the
    /// index rebuild (`hexane/column.zig:6687-6693`, reached from every
    /// splice at `:6553`), the three slab-append paths that weigh a slab as
    /// it lands (`:5244`, `:5553`, `:5595`), and the invariant check that
    /// reweighs every slab against the index (`:6908`) all go through `E.
    /// weightOf` with this codec, so one change here is the whole of it.
    ///
    /// **The refusals are the row walk's, at the same run.** There are two,
    /// and a third the walk cannot raise at all.
    ///
    /// *Exhaustion, `error.InvalidValue`.* Both walks take runs in the same
    /// order and stop at the first one they cannot have, and `nextRunMax`
    /// answers null from exactly the state `next` answers null from: no items
    /// left in the run in hand, and no bytes left to read the next one
    /// (`bool.zig:320` against `:210`). So `null` while `left != 0` is the
    /// same condition, at the same run, as the `null` from `next` that today
    /// becomes `error.InvalidValue` — and the budget makes the two ends of
    /// the walk agree too, because `count` is capped at `left` exactly as
    /// `nth`'s is (`bool.zig:316`, `bool.rs:606`): a slab whose bytes hold
    /// more rows than its `len` counts its first `len`, as the row walk did.
    ///
    /// *Overflow, `error.Overflow`.* Today's sum is a running total of `+1`
    /// per true row, so it never falls: every addition raises it or leaves it
    /// where it is. With `T` the sum in front of a run, `c` the count of
    /// `true`s it holds and `M` the largest `i64`, the partial sums inside it
    /// are `T, T+1, …, T+c` and they are monotone, so the row walk refuses at
    /// its `(M - T + 1)`-st row exactly when `T + c > M`. That is the
    /// condition the addition below refuses at, in the same run.
    /// **A run cannot straddle the boundary**: it adds `c` atomically, and the
    /// row the row walk refuses at is a member of the run this fold refuses
    /// at, so the run fold never reads a header the row walk would not have
    /// read to reach that row. The one sum it cannot even attempt is a run
    /// wider than `i64` on a 64-bit `usize`; it refuses `error.Overflow` for
    /// the same reason, since the row walk would have added `M` ones of that
    /// run before it ran out of room. No slab reaches either refusal — a
    /// count is at most `slab.len`, and a slab of `maxInt(i64) + 1` true rows
    /// is not a slab — so the test at the foot of this file shows the fold's
    /// own refusal through [`accumulateRun`](BoolPrefixCodec.accumulateRun),
    /// which is the same addition at a sum a caller can reach.
    ///
    /// *A run of no rows.* This decoder cannot serve one: `count` is
    /// `min(remaining, max)` with `remaining > 0` and `max = left > 0`, so
    /// it is never zero, and a count of zero in the bytes is stepped over
    /// inside `nextRunMax` rather than handed back (`bool.zig:280-298`).
    /// **The loop needs no guard for one anyway**, because each iteration
    /// makes progress whichever way it goes: it either spends rows, which
    /// takes `left` down, or spends a header, which takes `dec.pos` up by at
    /// least one byte — `readUnsigned` never returns a length of zero
    /// (`leb128.zig:146-177` breaks only after reading a byte) — and the
    /// bytes are finite. The test at the foot of this file walks slabs with
    /// zero counts in them, which is the shape that would spin a loop that
    /// spun on the count.
    pub fn weightOf(gpa: Allocator, slab: *const slabmod.Slab) ParseError!Weight {
        _ = gpa;
        var sum: i64 = 0;
        var dec = try WireDecoder.init(slab.data);
        var left: usize = slab.len;
        while (left != 0) {
            const run = (try dec.nextRunMax(left)) orelse return error.InvalidValue;
            left -= run.count;
            if (run.value) {
                // A count too wide for `i64` refuses here and not at a cast,
                // which would trap: the row walk would have refused inside
                // this run, so this is where it refuses too.
                const each = std.math.cast(i64, run.count) orelse return error.Overflow;
                sum = std.math.add(i64, sum, each) catch return error.Overflow;
            }
        }
        return .{ .len = slab.len, .prefix = sum };
    }

    pub fn weightIncrement(w: Weight) i64 {
        return w.prefix;
    }

    /// A true row is one unit long and a false row is none
    /// (`hexane/src/prefix.rs:319-320`).
    pub fn accumulate(w: Wire, running: *i64) ParseError!void {
        running.* = std.math.add(i64, running.*, @intFromBool(w)) catch return error.Overflow;
    }

    /// `accumulate` over `count` rows of one value: a `true` row is one unit
    /// and a `false` row is none, so a run of `count` `true`s adds `count` in
    /// one step — upstream's own fold of a run
    /// (`hexane/src/prefix.rs:322-324`).
    ///
    /// **Publishing it is what puts this codec on the fast arm of
    /// `accumulateWire`** (`hexane/column.zig:291-301`), which dispatches on
    /// `@hasDecl(E, "accumulateRun")` and takes a whole run at a time when a
    /// decoder can hand one over. So `Column.runningAt` — and `getPrefix`,
    /// `prefixIter` and every other prefix question through it — stops
    /// reading a boolean slab a row at a time, which is the same win
    /// [`weightOf`](BoolPrefixCodec.weightOf) takes for the index.
    ///
    /// **The refusals are the row walk's, at the same run, and no refusal is
    /// lost to the fold.** The arm refuses `false` — which its caller turns
    /// into `error.InvalidValue` (`column.zig:3387`) — on exactly the
    /// exhaustion `accumulate` over rows sees, and it raises this function's
    /// `error.Overflow` where that walk would. Every other refusal a boolean
    /// run can carry is its own count varint, which the arm has to read to
    /// learn how long the run is, so all three of `advanceRun`'s are raised
    /// at the run that carries them (`bool.zig:300-311`). The sum is monotone
    /// for the reason `weightOf` gives: a `true` adds one and a `false` adds
    /// nothing, so with `T` the sum in front of the run, `c` its count and
    /// `M` the largest `i64`, the row walk refuses at the run's
    /// `(M - T + 1)`-st row exactly when `T + c > M`.
    pub fn accumulateRun(w: Wire, count: usize, running: *i64) ParseError!void {
        if (!w) return;
        // A count wider than `i64` refuses here, at the same sum the row walk
        // would have refused after `maxInt(i64)` of its own additions.
        const each = std.math.cast(i64, count) orelse return error.Overflow;
        running.* = std.math.add(i64, running.*, each) catch return error.Overflow;
    }

    /// The wire entry one value takes, and the running value it leaves
    /// behind: a boolean column's value is its position in the sequence,
    /// so the wire *is* the value.
    pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
        return .{ .wire = v, .running = running };
    }
};

/// `PrefixColumn<ValueMeta>`: the unsigned-LEB128 wire format, indexed by the
/// sum of the *lengths* the words declare (`columns.rs:30`).
///
/// A metadata word is `(length << 4) | type` (`op_set2/meta.rs:20-43`) and
/// upstream's `PrefixValue for ValueMeta` adds `val.length()`
/// (`op_set2/meta.rs:116-124`), which is what makes the column an index into
/// the raw value arena. The column holds the raw word rather than a
/// `ValueMeta` because the column layer's codecs are integer-only; the
/// conversion is `ValueMeta.fromRaw` and `.raw`, both free.
pub const MetaPrefixCodec = struct {
    /// A metadata word, as the `u64` the wire carries.
    pub const Value = u64;
    pub const Wire = u64;
    pub const Weight = hexane.PrefixWeight;
    pub const has_lit_header = hexane.Rle(u64).has_lit_header;
    pub const tracks_prefix = true;
    pub const is_prefix_column = true;
    pub const is_delta = false;
    pub const WireDecoder = hexane.Rle(u64).WireDecoder;
    /// The run-length wire walk a streaming load drives.
    pub const LoadCursor = hexane.Rle(u64).LoadCursor;
    /// The run-length streaming encoder, unchanged by the swapped weight.
    pub const StreamEncoder = hexane.Rle(u64).StreamEncoder;

    pub const segmentsOf = hexane.Rle(u64).segmentsOf;
    pub const wireRange = hexane.Rle(u64).wireRange;
    /// A metadata word is stored in the run's own payload, so a fragment
    /// reads back the words it was written from and `value` is not read
    /// (`hexane/column.zig:678-697`). The swapped weight does not change
    /// the wire, so this is the integer codec's own.
    pub const wireRunItems = hexane.Rle(u64).wireRunItems;
    pub const wireEncode = hexane.Rle(u64).wireEncode;
    pub const wireFill = hexane.Rle(u64).wireFill;
    pub const fillBytes = hexane.Rle(u64).fillBytes;
    pub const wireSlice = hexane.Rle(u64).wireSlice;
    pub const lastValueOfRun = hexane.Rle(u64).lastValueOfRun;
    pub const litTail = hexane.Rle(u64).litTail;
    pub const litHead = hexane.Rle(u64).litHead;
    pub const runAtOrAfter = hexane.Rle(u64).runAtOrAfter;
    pub const firstRunValue = hexane.Rle(u64).firstRunValue;
    pub const literalValueAt = hexane.Rle(u64).literalValueAt;
    pub const valueOfWire = hexane.Rle(u64).valueOfWire;
    pub const wireOfInsert = hexane.Rle(u64).wireOfInsert;
    pub const reanchor = hexane.Rle(u64).reanchor;
    pub const sameValue = hexane.Rle(u64).sameValue;
    pub const mustMergeKinds = hexane.Rle(u64).mustMergeKinds;
    pub const canonicalSlab = hexane.Rle(u64).canonicalSlab;

    /// The weight of a slab of metadata words: its row count, and the sum of
    /// the lengths the words declare (`op_set2/meta.rs:116-124`,
    /// `MetaPrefixCodec`'s own weight).
    ///
    /// **A repeat run is folded in one step, so the walk is `O(runs in the
    /// slab)` and not `O(rows)`.** `nextRunMax` charges a repeat run its whole
    /// count in O(1) (`rle.zig:592-599`), and the word in front of the run is
    /// one length, so `count` rows of it add `length * count` in the single
    /// multiplication [`accumulateRun`](MetaPrefixCodec.accumulateRun)
    /// implies. **This is what makes an append cost what it should.** Every
    /// splice runs this once per slab through `reindexFrom`
    /// ([column.zig:6739-6750](../hexane/column.zig)) and `rebuildAggs`
    /// ([:6824-6841](../hexane/column.zig)), from the first slab the cut
    /// touched — which is the only slab, for a set appended to — and an op set
    /// of same-length metadata words is one repeat run. **A literal run is
    /// still folded a value at a time**, because its values are packed back to
    /// back and its count says nothing about where any one of them starts
    /// (`rle.zig:600-605`); so a slab of distinct lengths is the case the row
    /// walk was for, and it is the case this column is in for a text object.
    ///
    /// **The refusals are the row walk's, at the same run, and no refusal is
    /// lost to the fold.** `nextRunMax` reads every run header through
    /// `enterRun` ([rle.zig:640-668](../hexane/rle.zig)), which reads the
    /// header and a repeat run's one payload through `readRunHeader` and
    /// `readValue`, so a truncated or overlong varint, a count that is not
    /// representable, a run claiming more values than the bytes hold, a count
    /// past `maxSlabLen` and a null run in a column that has none are all
    /// raised inside the fold itself, at the run that carries them. The fold
    /// reads no further than the row walk did: it stops on `slab.len` without
    /// opening the next header. Exhaustion answers null, which is the fold's
    /// `error.InvalidValue` and the row walk's (`dec.next() orelse return`).
    /// The sum refuses where [`accumulateRun`](MetaPrefixCodec.accumulateRun)
    /// says it does, which is where the row walk's `count` additions refuse.
    ///
    /// **There is no second walk.** The decoder is
    /// `hexane.Rle(u64).WireDecoder` — `RleCodec.Decoder` (`column.zig:702`)
    /// — and it publishes `nextRunMax` (`rle.zig:589`), so the row-at-a-time
    /// arm the boolean codec's fold has no use for is not a shape this one
    /// can take either. The row walk that was here is kept in the test
    /// section as `metaWeightOfRows`, where the substitution it made is the
    /// claim being tested.
    pub fn weightOf(gpa: Allocator, slab: *const slabmod.Slab) ParseError!Weight {
        _ = gpa;
        var sum: i64 = 0;
        var dec = try WireDecoder.init(slab.data);
        var left = slab.len;
        while (left != 0) {
            const run = (try dec.nextRunMax(left)) orelse return error.InvalidValue;
            left -= run.count;
            try accumulateRun(run.value, run.count, &sum);
        }
        return .{ .len = slab.len, .prefix = sum };
    }

    pub fn weightIncrement(w: Weight) i64 {
        return w.prefix;
    }

    /// The length half of the word, which is the row's width
    /// (`op_set2/meta.rs:40-42`).
    pub fn accumulate(w: Wire, running: *i64) ParseError!void {
        running.* = std.math.add(i64, running.*, try lengthOf(w)) catch return error.Overflow;
    }

    /// `accumulate` over `count` rows of one metadata word: a row's length
    /// is the word's own, so a run of `count` rows of one word adds
    /// `length * count` in one step. **Publishing it is what puts this codec
    /// on the fast arm of `accumulateWire`**
    /// ([column.zig:297-314](../hexane/column.zig)), which dispatches on
    /// `@hasDecl(E, "accumulateRun")`. So `Column.runningAt` — and
    /// `getPrefix`, and the two prefix reads at the head of
    /// [`Columns.splice`](columns.zig) — stops reading a `value_meta` slab a
    /// row at a time, the same win [`weightOf`](MetaPrefixCodec.weightOf)
    /// takes on the write path.
    ///
    /// **The refusal is the row walk's, at the same sum, and a refusal leaves
    /// the sum where it was.** The addition is made in `i128` and refused when
    /// the *result* leaves `i64`, because a sum already inside `i64` can span
    /// more than `i64` on its own — a fold that added `length * count` first
    /// would refuse a span that fits. With `lengthOf` casting an unsigned
    /// shift it is never negative, so the partial sums inside a run run from
    /// the value in front of it to the value behind it monotonically: both
    /// endpoints in range is every one between them, and the arm refuses
    /// exactly what `count` calls to [`accumulate`](MetaPrefixCodec.accumulate)
    /// refuse.
    ///
    /// **`lengthOf`'s own `error.Overflow` is unreachable from a word**, and it
    /// is stated where it lives: a `u64` shifted right four is at most
    /// `2^60 - 1`, and `2^60 - 1 < maxInt(i64)`, so no word reaches it. The
    /// width of a *sum* of lengths is the thing that does leave `i64`, and that
    /// is the refusal both folds raise.
    pub fn accumulateRun(w: Wire, count: usize, running: *i64) ParseError!void {
        const wide: i128 = @as(i128, running.*) + @as(i128, try lengthOf(w)) * @as(i128, count);
        if (wide < std.math.minInt(i64) or wide > std.math.maxInt(i64)) return error.Overflow;
        running.* = @intCast(wide);
    }

    /// The length half of the word, which is the row's width
    /// (`op_set2/meta.rs:40-42`).
    ///
    /// **The `error.Overflow` is unreachable from a word, and is here because
    /// the cast is the check rather than an assertion.** A word is a `u64` and
    /// the shift leaves at most `2^60 - 1`, which is inside `i64` — so
    /// `cast` answers null for no `u64` at all, and a test that expects this
    /// refusal would pass for the wrong reason or fail for the right one. The
    /// width of a *sum* of lengths is the thing that does overflow, and that
    /// is what [`accumulate`](MetaPrefixCodec.accumulate) and
    /// [`accumulateRun`](MetaPrefixCodec.accumulateRun) refuse.
    fn lengthOf(w: u64) ParseError!i64 {
        return std.math.cast(i64, w >> 4) orelse error.Overflow;
    }

    /// The wire entry one value takes, and the running value it leaves
    /// behind: this column stores the metadata word itself, so the two are
    /// the same number.
    pub fn wireOfOne(running: i64, v: Value) ParseError!struct { wire: Wire, running: i64 } {
        return .{ .wire = v, .running = running };
    }
};

// ── The sixteen data columns and the five index columns ────────────────────

/// A run-length column of actor indices with no nulls: `id_actor` and
/// `succ_actor` (`columns.rs:18`, `:25`).
pub const ActorColumn = optypes.ActorColumn;

/// The same column with nulls, for the root object and for a map key, which
/// name no actor: `obj_actor` and `key_actor` (`columns.rs:20`, `:22`).
pub const ActorOptColumn = optypes.ActorColumnOption;

/// A delta-coded counter: `id_ctr` and `succ_ctr` (`columns.rs:19`, `:26`).
pub const CounterColumn = hexane.Column(u32, hexane.Delta(u32));

/// A nullable counter, delta coded: `key_ctr` (`columns.rs:23`).
pub const OptCounterColumn = hexane.Column(?u32, hexane.DeltaOption);

/// A nullable unsigned integer on a run-length column: `obj_ctr`, `key_str`
/// and `mark_name` (`columns.rs:21`, `:22`, `:32`).
///
/// The two string columns hold an interned string id rather than a counter,
/// which is the port's storage model ([plan §5.3](../../docs/plan.md)). The
/// *specification* they are saved under is `.string`, so only `export` and
/// `load` may write or read them; a caller that dumps this column's bytes
/// under its own specification writes the wrong format.
pub const UintOptColumn = hexane.Column(?u32, hexane.RleOption(u32));

/// A prefix column of `u32`: how many successors each row has,
/// `succ_count` (`columns.rs:24`).
pub const CountColumn = hexane.Column(u32, hexane.Prefix(u32));

/// A boolean column: `expand` and `index.visible` (`columns.rs:33`, `:41`).
pub const BoolColumn = hexane.Column(bool, hexane.Bool);

/// A boolean prefix column: `insert` and `index.top` (`columns.rs:28`, `:39`).
pub const BoolPrefixColumn = hexane.Column(bool, BoolPrefixCodec);

/// The action column, holding codes rather than actions (`columns.rs:29`).
pub const ActionColumn = optypes.ActionColumn;

/// The value metadata column, holding raw words (`columns.rs:30`).
pub const MetaColumn = hexane.Column(u64, MetaPrefixCodec);

/// The raw value arena: the payloads the metadata words describe, with no
/// run structure of its own (`columns.rs:31`).
pub const ValueColumn = rawcol.RawColumn;

/// The text-width index: how wide a top row is, null for a row that is not
/// top (`columns.rs:38`).
pub const TextColumn = hexane.Column(?u32, hexane.Prefix(?u32));

/// The increment index: the delta a counter successor carries, and null for
/// every other successor (`columns.rs:42`).
pub const IncColumn = hexane.Column(?i64, hexane.RleOption(i64));

// ── The mark index ─────────────────────────────────────────────────────────

// A row of the mark index is a `markidx.MarkIdx` — a mark opens here, or the
// mark that opened earlier closes (`mark_index.rs:12-16`) — and the column
// that holds those rows, together with the cache from a mark's begin op to
// the `MarkData` it puts on its span, is upstream's `MarkIndexColumn`
// (`mark_index.rs:213-217`) as one value. Both are declared once, in
// [mark_index.zig](mark_index.zig): the word arithmetic
// (`MarkIdx.asI64` and `MarkIdx.load`, `mark_index.rs:25-34`, `:36-49`), the
// column, and the query half. What this file owns is the other half — the
// rows a splice writes and an undo takes back out — which is `splice` and
// `removeOps` below and the one helper they share.

// ── The five index columns ─────────────────────────────────────────────────

/// The derived views the query layer reads instead of scanning the sixteen
/// data columns (`columns.rs:37-43`).
///
/// They are never loaded from a document and never saved to one
/// (`columns.rs:314`): a load rebuilds them, because every one of them is
/// derived state that the data columns already determine.
pub const Indexes = struct {
    /// How wide a top row is, in the text encoding the op set was built with.
    text: TextColumn,
    /// Whether a row is the winner of its key (`columns.rs:39`).
    top: BoolPrefixColumn,
    /// Whether a row is visible: present and not shadowed (`columns.rs:41`).
    visible: BoolColumn,
    /// The increment a counter successor carries, and null for every other
    /// successor — which is how a delete is told from a counter update
    /// (`columns.rs:42`).
    inc: IncColumn,
    /// Which rows open a mark and which close one, and the `MarkData` of every
    /// live mark begin (`columns.rs:43`, `mark_index.rs:213-217`).
    ///
    /// The cache's names are borrowed from the document's string table, which
    /// must outlive this: the module doc says which one and why.
    mark: markidx.MarkIndexColumn,

    /// Five empty index columns (`Indexes::default`, `columns.rs:47-56`).
    pub fn init(gpa: Allocator) ParseError!Indexes {
        var text = try TextColumn.init(gpa);
        errdefer text.deinit();
        var top = try BoolPrefixColumn.init(gpa);
        errdefer top.deinit();
        var visible = try BoolColumn.init(gpa);
        errdefer visible.deinit();
        var inc = try IncColumn.init(gpa);
        errdefer inc.deinit();
        return .{
            .text = text,
            .top = top,
            .visible = visible,
            .inc = inc,
            .mark = try markidx.MarkIndexColumn.init(gpa),
        };
    }

    /// Frees the five index columns and the mark cache, and leaves the
    /// receiver as it was — **no poisoning here**, unlike
    /// [`Columns.deinit`] next door, because nothing in this file frees a
    /// standalone `Indexes` twice and a moved-from one is never read.
    ///
    /// The mark column owns two things
    /// ([`MarkIndexColumn`](mark_index.zig:461-475)): the rows, and the cache
    /// of every open mark's `MarkData`, whose names are borrows from the
    /// document's string table. Both go here, and neither outlives the op set
    /// that holds them.
    pub fn deinit(self: *Indexes) void {
        self.text.deinit();
        self.top.deinit();
        self.visible.deinit();
        self.inc.deinit();
        self.mark.deinit();
    }

    /// The five lengths, so a caller can check them against the data columns
    /// in one place. `text`, `top` and `visible` are row-indexed and `inc` is
    /// successor-indexed, so the first three must equal the row count and
    /// `inc` must not exceed the successor count.
    pub fn lengths(self: *const Indexes) IndexLengths {
        return .{
            .text = self.text.len(),
            .top = self.top.len(),
            .visible = self.visible.len(),
            .inc = self.inc.len(),
            .mark = self.mark.len(),
        };
    }
};

/// The five index columns' row counts, which the index rebuild and
/// `removeOps` both have to keep true.
///
/// **`text`, `top`, `visible` and `mark` are row counts and `inc` is a
/// successor count**, so the four must equal the row count and the fifth must
/// not exceed the successor count. [`Indexes.checkLengths`] is the check that
/// says so, and [`Indexes.lengths`](columns.zig) is where a caller gets this
/// shape.
pub const IndexLengths = struct {
    /// Rows in `index.text`, which must equal the row count.
    text: usize,
    /// Rows in `index.top`, which must equal the row count.
    top: usize,
    /// Rows in `index.visible`, which must equal the row count.
    visible: usize,
    /// Successors in `index.inc`, which must not exceed the successor count.
    inc: usize,
    /// Rows in `index.mark`, which must equal the row count.
    mark: usize,
};

// ── Strings across the storage boundary ────────────────────────────────────

/// The document's string table, which is what the two string columns are
/// counters into ([plan §5.3](../../docs/plan.md)).
///
/// `resolve` turns an id into the bytes the wire carries and `intern` turns
/// bytes back into an id. Both are the caller's own table; nothing here stores
/// a string.
///
/// **The bytes `resolve` hands back must be the table's own.** The mark index's
/// cache holds what `resolve` returns for as long as the op set lives (the
/// module doc's lifetime), so a table that resolved an id to a borrow of the
/// change it was read out of would dangle there. `intern` is the other half of
/// the same rule and is what makes it hold: it copies the bytes in rather than
/// recording where they came from, which is also why an id is stable across a
/// save and a load.
pub const StringTable = struct {
    /// The table's own state, passed to both functions unchanged.
    ctx: *const anyopaque,
    /// The bytes of the string `id` names, owned by the table and valid for as
    /// long as the table is.
    resolve: *const fn (ctx: *const anyopaque, id: u32) []const u8,
    /// The id of `bytes`, interning it if the table has not seen it. A table
    /// with more strings than an id can name answers `error.Overflow`; the
    /// error set is the parser's because that is where a save and a load
    /// already fail.
    intern: *const fn (ctx: *const anyopaque, bytes: []const u8, gpa: Allocator) ParseError!u32,
};

/// What `export` produced: the column set and the data block its ranges index
/// (`columns.rs:174-183`, which returns the pair).
pub const Exported = struct {
    /// The saved columns, ascending by normalized specification.
    cols: RawColumns,
    /// The block `cols`' ranges index. Borrowed by `cols`, owned here.
    data: []u8,

    /// Frees the column list and the data block. The caller owns the block
    /// and the list is the set's own.
    pub fn deinit(self: *Exported, gpa: Allocator) void {
        self.cols.deinit(gpa);
        gpa.free(self.data);
        self.* = undefined;
    }
};

// ── The op set's columns ───────────────────────────────────────────────────

/// The element type of what [`Columns.removeOps`] accepts: a `[]const T`, or a
/// `*const [N]T` standing for the whole of its array.
///
/// **Why a helper at all.** Upstream's parameter is `&[&dyn OpLike]`
/// (`columns.rs:361`) — a trait, so every op shape reached the body. This port
/// narrowed the trait to one type parameter, `Columns(O)` took that narrowing
/// for the whole body, and [`OpSet.undoOp`](op_set.zig) was left with no way in
/// at all: its one op is an [`OpBuilder`](op.zig), because that is what a
/// [`TxOp`](op.zig) holds, and `OpBuilder` is not `O`. **One type parameter is
/// narrower than a trait.** What the body asks of each op is `action()`,
/// `value()`, `succCount()` and `markName()`, and both shapes have all four.
///
/// **What Zig 0.16.0 reports for each spelling**, because the shape is not the
/// one a reader would guess, and writing down the one that is wrong is what let
/// a broken arm ship. Both spellings of "a list of ops" are `.one`, not
/// `.many`, and only the `child` tells them from a `.slice`:
///
/// | written | `@TypeOf` | `pointer.size` | `pointer.child` |
/// | --- | --- | --- | --- |
/// | `rows[0..]` | `[]const T` | `.slice` | `T` |
/// | `&rows`, `rows: [N]T` | `*const [N]T` | `.one` | an `Array` |
/// | `&.{op}` | `*const struct { comptime T }` | `.one` | a one-field `Struct`, `is_tuple` |
///
/// **The third row is refused, and the reason is mechanical.** A pointer to a
/// one-field tuple cannot be turned into a slice in 0.16.0 — both `ops[0..]` and
/// `ops[0..1]` hand back `*const struct { … }` — so accepting it would mean a
/// second iteration path for the body. The one caller that wrote it that way
/// ([`OpSet.undoOp`](op_set.zig)) now writes `&[_]OpBuilder{op.bld}`, which is
/// the second row. **An arm no caller reaches is an arm that does not
/// compile**, so there is no third arm here to be wrong.
fn opElementType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .pointer) {
        @compileError("removeOps takes a slice or a pointer to an array, not " ++ @typeName(T));
    }
    return switch (info.pointer.size) {
        .slice => info.pointer.child,
        // A pointer names **one** thing, so a pointer to an array is `.one`
        // whose child is that array; the element type is the array's.
        .one, .many => switch (@typeInfo(info.pointer.child)) {
            .array => |a| a.child,
            else => @compileError("removeOps got a ." ++ @tagName(info.pointer.size) ++
                " pointer whose child is a " ++
                @tagName(@typeInfo(info.pointer.child)) ++ ", not an array: " ++
                @typeName(info.pointer.child) ++
                ". `&.{op}` is a pointer to a one-element *tuple*, which cannot be " ++
                "turned into a slice; write `&[_]T{op}` instead"),
        },
        else => @compileError("removeOps got a ." ++ @tagName(info.pointer.size) ++
            " pointer; it takes a slice or a pointer to an array"),
    };
}

/// The op set's columns, generic over the op type `O` it is handed.
///
/// `O` is anything with the accessors `op.zig` publishes: `id`, `obj`,
/// `action`, `key`, `insert`, `expand`, `visible`, `top`, `width`,
/// `value`, `metaValue`, `markName`, `markIndex`, `succCount`, `succAt`,
/// `succIncCount` and `succIncAt`. This file reads those and nothing else, so
/// a loaded `Op`, a decoded change op and a test op are the same code here.
///
/// The value's payload is written from `value` rather than from `rawValue`,
/// because `rawValue` is the *borrowed* half of upstream's `as_raw`
/// (`op_set2/types.rs:369-394`): it answers for a string, a byte string and
/// an unknown value and has nothing to say for the numeric tags, whose bytes
/// have to be built. `appendRaw` and `rawLen` are that other half
/// ([types.zig:290-338](types.zig)), and for every variant the two together
/// are exactly the bytes `as_raw` returns — the two it declines are `Null`
/// and `Boolean`, which occupy none (`:375-376`).
///
/// **The sixteen data columns and the five index columns are the whole of the
/// state, and the index is derived.** A load builds the five empty
/// (`columns.rs:252-330`) and every document rebuilds them, so a caller that
/// has rows and an empty `index` holds a value no query can read — that is what
/// [`OpSet.fromParts`](op_set.zig) is for, and what [`OpSet.load`](op_set.zig)
/// exists to avoid.
///
pub fn Columns(comptime O: type) type {
    return struct {
        const Self = @This();

        /// The op type this column set is written in terms of.
        pub const Op = O;

        /// The actor half of each op's own id (`columns.rs:18`).
        id_actor: ActorColumn,
        /// The counter half of each op's own id (`columns.rs:19`).
        id_ctr: CounterColumn,
        /// The actor half of the parent object's id, null at the root
        /// (`columns.rs:20`).
        obj_actor: ActorOptColumn,
        /// The counter half of the parent object's id (`columns.rs:21`).
        obj_ctr: UintOptColumn,
        /// The actor half of a sequence anchor, null for a map key
        /// (`columns.rs:22`).
        key_actor: ActorOptColumn,
        /// The counter half of a sequence anchor (`columns.rs:23`).
        key_ctr: OptCounterColumn,
        /// The map key, as an interned id (`columns.rs:22`).
        key_str: UintOptColumn,
        /// How many successors each row has (`columns.rs:24`).
        succ_count: CountColumn,
        /// The successors' actors, flattened (`columns.rs:25`).
        succ_actor: ActorColumn,
        /// The successors' counters, flattened (`columns.rs:26`).
        succ_ctr: CounterColumn,
        /// Whether each row inserts rather than overwrites (`columns.rs:28`).
        insert: BoolPrefixColumn,
        /// Each row's action, as its wire code (`columns.rs:29`).
        action: ActionColumn,
        /// Each row's value metadata word (`columns.rs:30`).
        value_meta: MetaColumn,
        /// The value payloads the metadata words describe (`columns.rs:31`).
        value: ValueColumn,
        /// A mark's name, as an interned id (`columns.rs:32`).
        mark_name: UintOptColumn,
        /// Whether a mark expands past its span (`columns.rs:33`).
        expand: BoolColumn,
        /// The five derived index columns (`columns.rs:39`).
        index: Indexes,

        /// Sixteen empty data columns and five empty index columns
        /// (`Columns::default`, `columns.rs:57-80`).
        pub fn init(gpa: Allocator) ParseError!Self {
            var id_actor = try ActorColumn.init(gpa);
            errdefer id_actor.deinit();
            var id_ctr = try CounterColumn.init(gpa);
            errdefer id_ctr.deinit();
            var obj_actor = try ActorOptColumn.init(gpa);
            errdefer obj_actor.deinit();
            var obj_ctr = try UintOptColumn.init(gpa);
            errdefer obj_ctr.deinit();
            var key_actor = try ActorOptColumn.init(gpa);
            errdefer key_actor.deinit();
            var key_ctr = try OptCounterColumn.init(gpa);
            errdefer key_ctr.deinit();
            var key_str = try UintOptColumn.init(gpa);
            errdefer key_str.deinit();
            var succ_count = try CountColumn.init(gpa);
            errdefer succ_count.deinit();
            var succ_actor = try ActorColumn.init(gpa);
            errdefer succ_actor.deinit();
            var succ_ctr = try CounterColumn.init(gpa);
            errdefer succ_ctr.deinit();
            var insert = try BoolPrefixColumn.init(gpa);
            errdefer insert.deinit();
            var action = try ActionColumn.init(gpa);
            errdefer action.deinit();
            var value_meta = try MetaColumn.init(gpa);
            errdefer value_meta.deinit();
            var value = try ValueColumn.init(gpa);
            errdefer value.deinit();
            var mark_name = try UintOptColumn.init(gpa);
            errdefer mark_name.deinit();
            var expand = try BoolColumn.init(gpa);
            errdefer expand.deinit();
            return .{
                .id_actor = id_actor,
                .id_ctr = id_ctr,
                .obj_actor = obj_actor,
                .obj_ctr = obj_ctr,
                .key_actor = key_actor,
                .key_ctr = key_ctr,
                .key_str = key_str,
                .succ_count = succ_count,
                .succ_actor = succ_actor,
                .succ_ctr = succ_ctr,
                .insert = insert,
                .action = action,
                .value_meta = value_meta,
                .value = value,
                .mark_name = mark_name,
                .expand = expand,
                .index = try Indexes.init(gpa),
            };
        }

        /// Frees the sixteen data columns and the five index columns, and then
        /// **poisons the receiver** with `self.* = undefined`.
        ///
        /// **That line is why this function exists at all** and why it is
        /// written the way every caller in this slice writes its own teardown.
        /// A second call is a use-after-free with no diagnostic, and — worse —
        /// the idiom `X.deinit(); try …; X = …` frees the columns, poisons
        /// `X`, and then reads the poisoned value if the `try` fails. That is
        /// the defect [`OpSet.fromParts`](op_set.zig) documents at length, and
        /// it reached a release build through `test/fixtures/missing_actor.automerge`.
        /// So: **load first, free second, and assign third.**
        ///
        /// The columns hold no borrow of the string table that outlives it
        /// beyond the mark cache's names, which the module doc's lifetime rule
        /// covers; nothing here frees the table itself.
        pub fn deinit(self: *Self) void {
            self.id_actor.deinit();
            self.id_ctr.deinit();
            self.obj_actor.deinit();
            self.obj_ctr.deinit();
            self.key_actor.deinit();
            self.key_ctr.deinit();
            self.key_str.deinit();
            self.succ_count.deinit();
            self.succ_actor.deinit();
            self.succ_ctr.deinit();
            self.insert.deinit();
            self.action.deinit();
            self.value_meta.deinit();
            self.value.deinit();
            self.mark_name.deinit();
            self.expand.deinit();
            self.index.deinit();
            self.* = undefined;
        }

        /// The number of rows (`Columns::len`, `columns.rs:504-506`).
        pub fn len(self: *const Self) usize {
            return self.id_actor.len();
        }

        /// The number of successors, counted across every row
        /// (`Columns::sub_len`, `columns.rs:508-510`).
        ///
        /// This is the length of the flattened pair, not the length of
        /// `succ_count`, and it is the only count a splice at a non-zero
        /// position may not disturb.
        pub fn subLen(self: *const Self) usize {
            return self.succ_actor.len();
        }

        /// Whether the op set holds no rows.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        // ── Loading and saving ──────────────────────────────────────────

        /// The op set's columns as a document column set
        /// (`Columns::export`, `columns.rs:172-184`), spelled `exportColumns`
        /// because `export` is a keyword in Zig 0.16.
        ///
        /// The specs are sorted on the way out, because a stored column set
        /// has to be ascending by normalized specification for
        /// `RawColumns::parse` to read it
        /// ([column_spec.zig:53](../storage/column_spec.zig)); the declared
        /// order in `ids.all_column_specs` is not that order. A column that
        /// holds nothing but its default is dropped, and which columns those
        /// are is [`exportColumn`]'s rule, below.
        pub fn exportColumns(self: *const Self, gpa: Allocator, strings: StringTable) ParseError!Exported {
            var data: std.ArrayList(u8) = .empty;
            errdefer data.deinit(gpa);
            var descs: std.ArrayList(ColumnDesc) = .empty;
            // `RawColumns.init` copies the descriptions, so this list is
            // scratch either way and the buffer goes back on every path.
            defer descs.deinit(gpa);

            var sorted = ids.all_column_specs;
            std.mem.sort(ColumnSpec, &sorted, {}, columnLessThan);
            for (sorted) |spec| {
                if (try self.exportColumn(gpa, spec, strings, &data)) |desc| {
                    try descs.append(gpa, desc);
                }
            }

            // The block is handed over rather than copied, and the set's
            // ranges index it directly, so the set has to be built over the
            // final buffer and not over the list's spare capacity.
            const block = try data.toOwnedSlice(gpa);
            data = .empty;
            errdefer gpa.free(block);
            const cols = try RawColumns.init(gpa, descs.items, block);
            errdefer cols.deinit(gpa);
            return .{ .cols = cols, .data = block };
        }

        /// The bytes of one column, appended to `data`, or null when the
        /// column is not written at all (`Columns::export_column`,
        /// `columns.rs:135-169`).
        ///
        /// The rule is the one upstream's `save_to` versus `save_to_unless`
        /// draws. Nine columns are saved whatever they hold — `id_actor`,
        /// `id_ctr`, `insert`, `action`, `succ_count`, `succ_actor`,
        /// `succ_ctr`, `value_meta` and `value` (`:141-142`, `:157-158`,
        /// `:163-167`) — because a document that has ever written them must
        /// keep writing them; upstream says so of `insert` alone
        /// (`:156`). Seven are saved only when they hold something: the five
        /// nullable columns `obj_actor`, `obj_ctr`, `key_actor`, `key_ctr` and
        /// `key_str` (`:143-155`), the mark name (`:159-161`) and `expand`,
        /// which is dropped when nothing expands (`:162`).
        ///
        /// An empty column is also dropped, because a column with no bytes is
        /// not part of a column set at all
        /// ([column_spec.zig:324-333](../storage/column_spec.zig)).
        fn exportColumn(
            self: *const Self,
            gpa: Allocator,
            spec: ColumnSpec,
            strings: StringTable,
            data: *std.ArrayList(u8),
        ) ParseError!?ColumnDesc {
            const bytes: ?[]u8 = switch (spec.raw) {
                ids.id_actor_col_spec.raw => try self.id_actor.encode(gpa),
                ids.id_counter_col_spec.raw => try self.id_ctr.encode(gpa),
                ids.obj_id_actor_col_spec.raw => try self.obj_actor.encodeUnless(gpa, null),
                ids.obj_id_counter_col_spec.raw => try self.obj_ctr.encodeUnless(gpa, null),
                ids.key_actor_col_spec.raw => try self.key_actor.encodeUnless(gpa, null),
                ids.key_counter_col_spec.raw => try encodeUnlessAllNull(OptCounterColumn, gpa, &self.key_ctr),
                ids.key_str_col_spec.raw => try encodeInterned(gpa, &self.key_str, strings),
                ids.insert_col_spec.raw => try self.insert.encode(gpa),
                ids.action_col_spec.raw => try self.action.encode(gpa),
                ids.mark_name_col_spec.raw => try encodeInterned(gpa, &self.mark_name, strings),
                ids.expand_col_spec.raw => try self.expand.encodeUnless(gpa, false),
                ids.succ_count_col_spec.raw => try self.succ_count.encode(gpa),
                ids.succ_actor_col_spec.raw => try self.succ_actor.encode(gpa),
                ids.succ_counter_col_spec.raw => try self.succ_ctr.encode(gpa),
                ids.value_meta_col_spec.raw => try self.value_meta.encode(gpa),
                ids.value_col_spec.raw => try self.value.encode(gpa),
                else => null,
            };
            const encoded = bytes orelse return null;
            defer gpa.free(encoded);
            const start = data.items.len;
            try data.appendSlice(gpa, encoded);
            return ColumnDesc.init(spec, data.items.len - start);
        }

        /// The op set's columns, read back from a document column set
        /// (`Columns::load`, `columns.rs:252-330`).
        ///
        /// The row count is `id_actor.len()` and nothing else
        /// (`columns.rs:258-259`): every data column is then held to exactly
        /// that many rows, and a column the document omitted becomes a column
        /// of the right length holding the right default — null for the five
        /// nullable ones, false for `insert` and `expand` (`:266-283`). A
        /// column that is present and decodes to another count is
        /// `error.InvalidValue`, which is upstream's `PackError::InvalidLength`
        /// ([column.zig:2640](../hexane/column.zig)).
        ///
        /// The successor pair is loaded against the total `succ_count`
        /// declares (`columns.rs:297-300`), not against the row count, because
        /// the two are different lengths: a row may have any number of
        /// successors, and a document that declares more successors than it
        /// has rows of them is the normal case.
        ///
        /// The five index columns are **not** loaded (`columns.rs:314`): they
        /// are rebuilt from the data columns by the index builder.
        pub fn load(gpa: Allocator, cols: RawColumns, strings: StringTable) ParseError!Self {
            var id_actor = try ActorColumn.load(gpa, try bytesFor(cols, ids.id_actor_col_spec));
            errdefer id_actor.deinit();
            const rows = id_actor.len();

            var id_ctr = try loadLen(CounterColumn, gpa, cols, ids.id_counter_col_spec, rows);
            errdefer id_ctr.deinit();
            var obj_actor = try loadFilled(ActorOptColumn, gpa, cols, ids.obj_id_actor_col_spec, rows, null);
            errdefer obj_actor.deinit();
            var obj_ctr = try loadFilled(UintOptColumn, gpa, cols, ids.obj_id_counter_col_spec, rows, null);
            errdefer obj_ctr.deinit();
            var key_actor = try loadFilled(ActorOptColumn, gpa, cols, ids.key_actor_col_spec, rows, null);
            errdefer key_actor.deinit();
            var key_ctr = try loadFilled(OptCounterColumn, gpa, cols, ids.key_counter_col_spec, rows, null);
            errdefer key_ctr.deinit();
            var key_str = try loadInterned(gpa, cols, ids.key_str_col_spec, rows, strings);
            errdefer key_str.deinit();
            var insert = try loadFilled(BoolPrefixColumn, gpa, cols, ids.insert_col_spec, rows, false);
            errdefer insert.deinit();
            var action = try loadLen(ActionColumn, gpa, cols, ids.action_col_spec, rows);
            errdefer action.deinit();
            var mark_name = try loadInterned(gpa, cols, ids.mark_name_col_spec, rows, strings);
            errdefer mark_name.deinit();
            var expand = try loadFilled(BoolColumn, gpa, cols, ids.expand_col_spec, rows, false);
            errdefer expand.deinit();
            var succ_count = try loadLen(CountColumn, gpa, cols, ids.succ_count_col_spec, rows);
            errdefer succ_count.deinit();

            // columns.rs:297-300 — the successor columns are as long as the
            // successor counts add up to, which is not the row count.
            const succs = try prefixOffset(CountColumn, &succ_count, succ_count.len());
            var succ_actor = try loadLen(ActorColumn, gpa, cols, ids.succ_actor_col_spec, succs);
            errdefer succ_actor.deinit();
            var succ_ctr = try loadLen(CounterColumn, gpa, cols, ids.succ_counter_col_spec, succs);
            errdefer succ_ctr.deinit();
            var value_meta = try loadLen(MetaColumn, gpa, cols, ids.value_meta_col_spec, rows);
            errdefer value_meta.deinit();
            var value = try ValueColumn.load(gpa, try bytesFor(cols, ids.value_col_spec));
            errdefer value.deinit();

            return .{
                .id_actor = id_actor,
                .id_ctr = id_ctr,
                .obj_actor = obj_actor,
                .obj_ctr = obj_ctr,
                .key_actor = key_actor,
                .key_ctr = key_ctr,
                .key_str = key_str,
                .succ_count = succ_count,
                .succ_actor = succ_actor,
                .succ_ctr = succ_ctr,
                .insert = insert,
                .action = action,
                .value_meta = value_meta,
                .value = value,
                .mark_name = mark_name,
                .expand = expand,
                .index = try Indexes.init(gpa),
            };
        }

        /// The layout of an op column block, checked, with the index columns
        /// dropped (`Columns::validate`, `columns.rs:219-249`).
        ///
        /// Upstream's `bytes` argument is the size of the data block, which
        /// it needs because the logical-column layout parser is handed the
        /// whole set; the port's `RawColumns` already carries the block, so
        /// the argument has nothing left to say. What upstream's
        /// `ColumnFormat::parse2` rejects is rejected here, in the order
        /// `add_column` runs its checks (`storage/columns.rs:191-199`):
        ///
        /// * a range that is not a `[start, end)` inside the block
        ///   (`storage/columns.rs:348-354`), and a range that is not where the
        ///   column before it ended (`:313-346`);
        /// * two columns with the same id and encoding, and a set that is not
        ///   ascending by normalized specification
        ///   ([column_spec.zig:552-558](../storage/column_spec.zig));
        /// * a value payload that belongs to no value column
        ///   (`storage/columns.rs:216`, `:246`), which is
        ///   [`docchunk.checkColumnLayout`] — the same walk
        ///   `parseDocumentChunk` runs, so a block is checked the same way
        ///   whichever door it came through.
        ///
        /// The first two are `RawColumns.validate`'s and `checkContiguous`'s,
        /// so that is what this calls rather than a second copy of them.
        ///
        /// **The duplicate check is the port's, and it is stricter than
        /// upstream's.** Upstream has exactly one duplicate check, in
        /// `add_column` (`storage/columns.rs:193-199`), behind
        /// `if let Some(last_spec) = self.last_spec`. That field is written
        /// once, as `None`, in `ColumnLayoutParser::new` (`:157`), and read
        /// once, at `:193`; a grep of the whole crate for `last_spec` returns
        /// those three lines and no assignment, so the guard never fires and
        /// `BadColumnLayout::DuplicateColumnSpecs` (`:118-119`) is unreachable.
        /// The check that *does* run is in `RawColumns::parse`
        /// (`storage/columns/raw_column.rs:248-252`), which calls
        /// `are_normal_sorted` (`:289-298`); that compares with a strict `<`,
        /// so **equal** specifications pass and a document may name one twice.
        /// The reference was run against 44 documents derived from one it wrote
        /// itself, each naming one of its columns a second time — every column
        /// of the change block and of the op block, once with the same length
        /// and once naming no bytes. **The reference loaded 21 of the 44,
        /// returned an error on 20, and aborted the process with a
        /// `Result::unwrap` on an `UnexpectedEof` (`hexane/src/lib.rs:354`) on
        /// 3.** The panic is upstream's own: `RawColumns::bytes`
        /// (`raw_column.rs:275-282`) binary-searches a vector that may hold the
        /// same specification twice and takes whichever index comes back.
        ///
        /// The port's answer on those same 44 bytes: 22 loaded and 22 were
        /// refused with `error.DuplicateColumn`, with no other error and no
        /// trap. The 22 that load are exactly the 22 that name the repeat with
        /// **no bytes** — `RawColumns.init` drops a zero-length entry as
        /// upstream's `FromIterator` does (`raw_column.rs:183`, `:187-205`), so
        /// it is not a second column at all, and there the port and the
        /// reference agree. The 22 that are refused are the repeats that name
        /// bytes, of which the reference loaded 2 and panicked on 3.
        ///
        /// So the divergence is exactly two documents out of forty-four, in
        /// exchange for never choosing between two byte ranges for one column
        /// — the parser differential the check exists to stop — and for being
        /// total where the reference aborts the process. It is safe because a
        /// document automerge wrote never names a column twice: its writer
        /// emits each specification once, and `FromIterator` drops the
        /// zero-length entries that are the only way a repeat could arise.
        ///
        /// What is checked is the *whole* set, index columns included,
        /// because upstream checks the layout before it filters
        /// (`:224` parses, `:225-249` filters); only then are the columns
        /// that are not one of the sixteen op specs dropped, silently, as
        /// upstream's `filter` does.
        /// `checkColumnLayout` deliberately requires no logical column to be
        /// complete, for the reason its own doc comment gives: the writer
        /// emits incomplete ones, and upstream's parser finishes them rather
        /// than refusing them.
        pub fn validate(gpa: Allocator, cols: RawColumns) ParseError!RawColumns {
            try cols.validate(null);
            try checkContiguous(cols);
            try docchunk.checkColumnLayout(cols);
            var kept: std.ArrayList(RawColumn) = .empty;
            errdefer kept.deinit(gpa);
            for (cols.columns) |col| {
                if (!isOpSpec(col.spec)) continue; // columns.rs:228-247
                try kept.append(gpa, col);
            }
            return .{ .columns = try kept.toOwnedSlice(gpa), .data = cols.data };
        }

        // ── Renumbering actors ──────────────────────────────────────────

        /// Every actor index in the op set, renumbered by `f`
        /// (`Columns::remap_actors`, `columns.rs:332-340`).
        ///
        /// Four columns hold an actor index: the two that name the op, the two
        /// that name a successor, and the two that name the parent — the
        /// parent as a pair, so `obj_actor` and `key_actor` are the nullable
        /// pair and `id_actor`/`succ_actor` are not. The mark index is *not*
        /// remapped here: upstream's `MarkIndexColumn::rewrite_with_new_actor`
        /// (`op_set/mark_index.rs:252-259`) is a separate call the op set
        /// makes, because the mark column is an index and this is the data.
        ///
        /// **All four are renumbered before any of them is committed**, which is
        /// what makes the pass all-or-nothing. A column renumbered in place is
        /// atomic on its own ([`Column.remap`]: it builds a new column and
        /// releases the old one only once the build has succeeded), but four
        /// sequential calls are four atomic steps and not one atomic pass — a
        /// refusal in the third would return with `id_actor` and `succ_actor`
        /// renumbered and the other two not, and two columns of one row
        /// disagreeing about that row's actor is the one state no reader here
        /// survives. So each column is staged with [`Column.remapped`], which
        /// reads one column and builds another and **leaves its source holding
        /// every byte it held** — there is nothing to copy first, and nothing
        /// is released before the commit — and the four are published together
        /// at the end, where nothing can fail.
        ///
        /// **The commit is four swaps.** Each column trades its contents with
        /// its staged copy ([`Column.swapContents`]) and the local is then
        /// released as the retired half, so the old bytes go back to the
        /// allocator they were taken from and none is freed twice. The swap
        /// also moves both counters past either column's, which is what
        /// invalidates a cursor suspended over the pre-renumbering rows: it
        /// cannot resume against the renamed ones
        /// ([`Column.IterState.tryResume`] compares the counter first). The run
        /// budget is the one thing a swap does not trade, and both halves
        /// already hold the same one, `remapped` having built on the source's.
        ///
        /// **The allocator moves with the contents**, for all four columns:
        /// they are holding `gpa`'s bytes when this returns, so ask
        /// [`Column.allocator`] again afterwards rather than reusing a value
        /// cached before it.
        ///
        /// **What it costs.** Four staged columns are alive at once at the
        /// moment before the commit, so the peak is higher than a column-at-a-
        /// time pass reaches — four rewrites' worth of slabs rather than one.
        /// This is an actor insertion or a removal, which is rare and not on any
        /// read path, and the alternative is a pass that can fail half way.
        pub fn remapActors(
            self: *Self,
            gpa: Allocator,
            ctx: anytype,
            comptime f: fn (@TypeOf(ctx), ActorIdx) ActorIdx,
        ) ParseError!void {
            var id_actor = try stagedRemap(ActorColumn, ActorIdx, &self.id_actor, gpa, ctx, f);
            errdefer id_actor.deinit();
            var succ_actor = try stagedRemap(ActorColumn, ActorIdx, &self.succ_actor, gpa, ctx, f);
            errdefer succ_actor.deinit();
            const opt = shiftOptActor(@TypeOf(ctx), f);
            var obj_actor = try stagedRemap(ActorOptColumn, ?ActorIdx, &self.obj_actor, gpa, ctx, opt);
            errdefer obj_actor.deinit();
            var key_actor = try stagedRemap(ActorOptColumn, ?ActorIdx, &self.key_actor, gpa, ctx, opt);
            errdefer key_actor.deinit();
            // The commit. Nothing below can fail, so no `errdefer` above can
            // fire after the column it guards has been swapped, and the four
            // columns move together or none of them does.
            self.id_actor.swapContents(&id_actor);
            id_actor.deinit();
            self.succ_actor.swapContents(&succ_actor);
            succ_actor.deinit();
            self.obj_actor.swapContents(&obj_actor);
            obj_actor.deinit();
            self.key_actor.swapContents(&key_actor);
            key_actor.deinit();
        }

        /// Renumber the actor indices as if a new actor had been interned at
        /// `idx` (`Columns::rewrite_with_new_actor`, `columns.rs:342-348`).
        ///
        /// All-or-nothing, by [`Columns.remapActors`]: **an error leaves the
        /// four columns exactly as they were**, and the mark index is not this
        /// function's business.
        pub fn rewriteWithNewActor(self: *Self, gpa: Allocator, idx: ActorIdx) ParseError!void {
            try self.remapActors(gpa, idx, actorShiftedUp);
        }

        /// Renumber the actor indices as if the actor at `idx` had been
        /// removed (`Columns::rewrite_without_actor`, `columns.rs:350-358`).
        ///
        /// Upstream panics if the actor being removed is still referenced
        /// (`:355-357`); the port refuses instead, before it has changed
        /// anything. The check walks the same four columns the remap does, and
        /// it is a read, so a refusal there is as safe as one from the remap
        /// itself: **an error leaves the columns exactly as they were.**
        ///
        /// **The check also asks the mark index.** This function renumbers the
        /// four data columns and leaves `index.mark` alone, so a mark row or a
        /// cache key still naming `idx` would end up naming an actor half of
        /// this set has forgotten: the `MarkIdx` in a row and the `OpId` in the
        /// cache are actor indices too (`mark_index.rs:25-34`). Upstream never
        /// asks, because upstream's `OpSet::remove_actor`
        /// (`op_set2/op_set.rs:1419-1429`) renumbers neither the mark rows nor
        /// anything else here — `columns.rs:350-358` is the whole of it.
        ///
        /// **In a well-formed set that arm refuses nothing the four columns have
        /// not already refused**: a mark's begin is a row, and a row names its
        /// actor in `id_actor`. It is here because
        /// [`MarkIndexColumn.stageRemap`](mark_index.zig) is a public seam that
        /// cannot renumber such a row downwards — a mark row cannot become "no
        /// mark", because the index is aligned with the op set and has nothing
        /// to drop — and because a function whose name says "no store of this
        /// set names the actor" should be true of the whole set.
        pub fn rewriteWithoutActor(self: *Self, gpa: Allocator, idx: ActorIdx) ParseError!void {
            if (try self.referencesActor(idx)) return error.InvalidValue;
            try self.remapActors(gpa, idx, actorShiftedDown);
        }

        /// Whether any of the four actor columns, or the mark index, still
        /// names `idx`.
        ///
        /// **Every store of this set that holds an actor index is asked**, so
        /// there is no half-renumbered refusal hiding behind a narrower check.
        /// The mark index's half is
        /// [`MarkIndexColumn.referencesActor`](mark_index.zig) — the same
        /// predicate [`MarkIndexColumn.stageRemap`](mark_index.zig) refuses on,
        /// asked of the two stores it keeps an actor index in.
        fn referencesActor(self: *const Self, idx: ActorIdx) ParseError!bool {
            if (try hasActor(&self.id_actor, idx)) return true;
            if (try hasActor(&self.succ_actor, idx)) return true;
            if (try hasOptActor(&self.obj_actor, idx)) return true;
            if (try hasOptActor(&self.key_actor, idx)) return true;
            if (try self.index.mark.referencesActor(idx)) return true;
            return false;
        }

        // ── Writing rows ────────────────────────────────────────────────

        /// Inserts `ops` before row `pos` and returns how many rows were
        /// written (`Columns::splice`, `columns.rs:419-492`).
        ///
        /// A delete is not a row: it is filtered out here (`:423`) and does
        /// not appear in the return value, in any of the sixteen columns, or
        /// in the count. It reaches the op set as a successor id on the op it
        /// deletes, which `add_succ` writes after this returns
        /// ([survey §4](../../docs/survey/02-transmission-opset.md)).
        ///
        /// The two prefix positions are read first, before any column moves
        /// (`:425-426`), because both are sums over columns this function is
        /// about to splice.
        ///
        /// **What an error leaves.** Every value is built before the first
        /// column moves, so a refusal while *building* — an interner out of
        /// memory, a counter that does not fit a `u32` — leaves the columns as
        /// they were.
        ///
        /// A refusal in the twenty-one column writes that follow used to leave
        /// the columns holding some of the new rows and not the rest.
        /// **Upstream's sequence at `:428-492` is not the precedent for that.**
        /// Its `?`s are packing and bounds — `Column::splice` returns
        /// `Result<_, PackError>` because a value may not pack, not because
        /// memory ran out; a Rust allocation failure aborts the process rather
        /// than returning an error (`handle_alloc_error`). **The port's heap is
        /// fallible where upstream's is not, so upstream's shape says nothing
        /// about what this port owes its caller on an `error.OutOfMemory`.**
        /// That is why the twenty-one writes are staged and published together
        /// rather than run in sequence.
        ///
        /// The mark index is written from a builder per row rather than from a
        /// word, because upstream's `MarkIndexColumn` is the column *and* the
        /// cache (`mark_index.rs:213-217`) and only a builder carries the
        /// `MarkData` a begin puts in it (`mark_index.rs:277-289`). Its name
        /// is the *interned* one, resolved back out of `strings`, so the
        /// cache is anchored in the document and not in the op; the module
        /// doc has the lifetime and the owner.
        pub fn splice(
            self: *Self,
            gpa: Allocator,
            pos: usize,
            ops: []const O,
            text_encoding: types.TextEncoding,
            strings: StringTable,
        ) ParseError!usize {
            var kept: std.ArrayList(O) = .empty;
            defer kept.deinit(gpa);
            for (ops) |o| {
                if (o.action() == .delete) continue; // columns.rs:423
                try kept.append(gpa, o);
            }
            const rows = kept.items;
            const n = rows.len;

            // columns.rs:425-426 — before anything moves.
            const value_pos = try prefixOffset(MetaColumn, &self.value_meta, pos);
            const succ_pos = try prefixOffset(CountColumn, &self.succ_count, pos);

            var id_actors = try gpa.alloc(ActorIdx, n);
            defer gpa.free(id_actors);
            var id_ctrs = try gpa.alloc(u32, n);
            defer gpa.free(id_ctrs);
            var obj_actors = try gpa.alloc(?ActorIdx, n);
            defer gpa.free(obj_actors);
            var obj_ctrs = try gpa.alloc(?u32, n);
            defer gpa.free(obj_ctrs);
            var key_actors = try gpa.alloc(?ActorIdx, n);
            defer gpa.free(key_actors);
            var key_ctrs = try gpa.alloc(?u32, n);
            defer gpa.free(key_ctrs);
            var key_strs = try gpa.alloc(?u32, n);
            defer gpa.free(key_strs);
            var inserts = try gpa.alloc(bool, n);
            defer gpa.free(inserts);
            var actions = try gpa.alloc(u64, n);
            defer gpa.free(actions);
            var expands = try gpa.alloc(bool, n);
            defer gpa.free(expands);
            var mark_names = try gpa.alloc(?u32, n);
            defer gpa.free(mark_names);
            var metas = try gpa.alloc(u64, n);
            defer gpa.free(metas);
            var tops = try gpa.alloc(bool, n);
            defer gpa.free(tops);
            var widths = try gpa.alloc(?u32, n);
            defer gpa.free(widths);
            var visibles = try gpa.alloc(bool, n);
            defer gpa.free(visibles);
            // One builder per row, in row order, which is the whole of what
            // `extend` takes (mark_index.rs:277-289). Upstream collects the
            // same list — `ops.clone().map(O::mark_index).collect()`
            // (columns.rs:468-470) — and this port spells it one allocation of
            // `n`, so the size is known before the first element exists and
            // the buffer goes back on every path.
            var mark_builders = try gpa.alloc(?markidx.MarkIndexBuilder, n);
            defer gpa.free(mark_builders);
            var succ_counts = try gpa.alloc(u32, n);
            defer gpa.free(succ_counts);

            var raw: std.ArrayList(u8) = .empty;
            defer raw.deinit(gpa);
            var succ_total: usize = 0;
            var inc_total: usize = 0;

            // Every value is built before any column is touched, so a splice
            // that cannot *build* — an interner that runs out of memory, a
            // counter that does not fit a u32 — leaves the columns as they
            // were rather than half written.
            //
            // After this build phase comes the twenty-one column writes, and
            // each of them is staged and published together rather than run in
            // sequence, so a refusal there leaves the whole set as it was.
            // **Upstream's `?`s at columns.rs:428-492 are packing and bounds,
            // not memory** — `Column::splice` returns `Result<_, PackError>`
            // because a value may not pack, and a Rust allocation failure
            // aborts rather than returning an error. This port's heap is
            // fallible where upstream's is not, so upstream's shape is not a
            // precedent and the staging is not optional here.
            for (rows, 0..) |o, i| {
                const id = o.id();
                id_actors[i] = id.actor;
                id_ctrs[i] = id.counter;
                if (o.obj()) |obj| {
                    obj_actors[i] = obj.actor;
                    obj_ctrs[i] = obj.counter;
                } else {
                    obj_actors[i] = null;
                    obj_ctrs[i] = null;
                }
                const key = o.key();
                key_actors[i] = key.actor();
                key_ctrs[i] = try optCounter(key.icounter());
                key_strs[i] = try internKey(gpa, key, strings);
                inserts[i] = o.insert();
                actions[i] = optypes.actionCode(o.action());
                expands[i] = o.expand();
                mark_names[i] = try internMarkName(gpa, o.markName(), strings);
                metas[i] = o.metaValue().raw;
                tops[i] = o.top();
                // columns.rs:466-471 — a row that is not top has no width.
                widths[i] = if (o.top()) try optCounter(o.width(.text, text_encoding)) else null;
                visibles[i] = o.visible();
                // The name the cache gets is the interned one, resolved back
                // out of the table `mark_names[i]` was written to above: the
                // cache outlives the op, and the document's own copy of the
                // name is what outlives it.
                mark_builders[i] = try markBuilderOf(
                    o,
                    internedName(mark_names[i], strings),
                    o.value(),
                );
                succ_counts[i] = try countOf(o.succCount());
                succ_total += o.succCount();
                inc_total += o.succIncCount();
                try raw.ensureUnusedCapacity(gpa, optypes.rawLen(o.value()));
                try optypes.appendRaw(gpa, &raw, o.value());
            }

            var succ_actors = try gpa.alloc(ActorIdx, succ_total);
            defer gpa.free(succ_actors);
            var succ_ctrs = try gpa.alloc(u32, succ_total);
            defer gpa.free(succ_ctrs);
            var incs = try gpa.alloc(?i64, inc_total);
            defer gpa.free(incs);
            var at_succ: usize = 0;
            var at_inc: usize = 0;
            for (rows) |o| {
                for (0..o.succCount()) |k| {
                    const id = o.succAt(k);
                    succ_actors[at_succ] = id.actor;
                    succ_ctrs[at_succ] = try counterOf(@as(i64, id.counter));
                    at_succ += 1;
                }
                for (0..o.succIncCount()) |k| {
                    incs[at_inc] = o.succIncAt(k);
                    at_inc += 1;
                }
            }

            // columns.rs:428-441 — the row columns, in upstream's order.
            //
            // **Every column is staged before any is published.** A stage
            // reads its column and writes nothing, and its `publish` cannot
            // fail, so a refusal from any of the twenty-one leaves the set
            // exactly as it was instead of holding some of the new rows and not
            // the rest. The two that are not `Column`s — `value` and
            // `index.mark` — are written directly below, **after** every stage
            // is in hand, for the same reason: the only remaining fallible
            // steps are then the last two, and each one's own failure still
            // leaves every stage unpublished.

            // **Which of the twenty-one carries nothing, and why none of
            // them is skipped.**
            //
            // Three are genuinely empty on a splice whose rows bring no
            // successors: `succ_actor`, `succ_ctr` and `index.inc`, each
            // handed `del == 0` and a value list of no length. **They are
            // still called, and the call is free**: `stageSplice` answers
            // `del == 0 and values.len == 0` with the no-op stage and returns
            // before it allocates anything
            // ([column.zig:4598-4607](../hexane/column.zig)), and its
            // `publish` leaves the column alone
            // ([column.zig:4532-4535](../hexane/column.zig)). Hoisting the
            // condition up here would move no work.
            //
            // The other eighteen are the row-indexed columns, and they are
            // not empty even when every value they are handed is a default.
            // **The row count is the count of rows**: `cols.len()` *is*
            // `id_actor.len()`, and `rowLengthMismatch`
            // ([op_iter.zig:1883](op_iter.zig)) names the first row-indexed
            // column that disagrees with it, which `OpIter.init` refuses the
            // set over. A default payload is a value, not the absence of a
            // row, so a skip there would leave the columns short by one and
            // shift every row behind the splice.
            //
            // **`removeOps` does skip its three
            // ([`removeOps`](columns.zig) below), and the reasoning does not
            // transfer.** Upstream guards the removal and not the insertion
            // (`columns.rs:400-408` against `:457-470`), and the guard is not
            // free here: `stageSplice` refuses a position past the end of the
            // column it is handed
            // ([column.zig:4596](../hexane/column.zig)), so those three calls
            // are what refuse a `succ_count` whose prefix runs past the
            // flattened pair — the one disagreement
            // `succLengthMismatch` names. Skipping them when `succ_total` is
            // zero would trade that refusal for a saving on a path that
            // already allocates nothing.
            //
            // **What a splice costs here, and what it does not.** The build
            // phase above is one pass over `rows`, and the two prefix reads
            // are a binary search for the slab and the runs inside it
            // ([column.zig:3372-3395](../hexane/column.zig)), so this file
            // adds **O(rows) once per call, not O(rows) per row**. A caller
            // that inserts `n` rows in `n` calls pays `n` calls of a cost
            // that does not itself grow with the document. What each call
            // hands the column layer is per column, and what the column layer
            // does with it is its own arithmetic
            // ([`stageSplice`](../hexane/column.zig)).
            var s_id_actor = try self.id_actor.stageSplice(pos, 0, id_actors);
            defer s_id_actor.deinit();
            var s_id_ctr = try self.id_ctr.stageSplice(pos, 0, id_ctrs);
            defer s_id_ctr.deinit();
            var s_obj_actor = try self.obj_actor.stageSplice(pos, 0, obj_actors);
            defer s_obj_actor.deinit();
            var s_obj_ctr = try self.obj_ctr.stageSplice(pos, 0, obj_ctrs);
            defer s_obj_ctr.deinit();
            var s_key_actor = try self.key_actor.stageSplice(pos, 0, key_actors);
            defer s_key_actor.deinit();
            var s_key_ctr = try self.key_ctr.stageSplice(pos, 0, key_ctrs);
            defer s_key_ctr.deinit();
            var s_key_str = try self.key_str.stageSplice(pos, 0, key_strs);
            defer s_key_str.deinit();
            var s_insert = try self.insert.stageSplice(pos, 0, inserts);
            defer s_insert.deinit();
            var s_action = try self.action.stageSplice(pos, 0, actions);
            defer s_action.deinit();
            var s_expand = try self.expand.stageSplice(pos, 0, expands);
            defer s_expand.deinit();
            var s_mark_name = try self.mark_name.stageSplice(pos, 0, mark_names);
            defer s_mark_name.deinit();
            var s_value_meta = try self.value_meta.stageSplice(pos, 0, metas);
            defer s_value_meta.deinit();
            var s_text = try self.index.text.stageSplice(pos, 0, widths);
            defer s_text.deinit();
            var s_top = try self.index.top.stageSplice(pos, 0, tops);
            defer s_top.deinit();
            var s_visible = try self.index.visible.stageSplice(pos, 0, visibles);
            defer s_visible.deinit();
            // columns.rs:446-462 — the successor counts, then the flattened
            // pair and the increments, at the offset read above.
            var s_succ_count = try self.succ_count.stageSplice(pos, 0, succ_counts);
            defer s_succ_count.deinit();
            var s_succ_actor = try self.succ_actor.stageSplice(succ_pos, 0, succ_actors);
            defer s_succ_actor.deinit();
            var s_succ_ctr = try self.succ_ctr.stageSplice(succ_pos, 0, succ_ctrs);
            defer s_succ_ctr.deinit();
            var s_inc = try self.index.inc.stageSplice(succ_pos, 0, incs);
            defer s_inc.deinit();

            // columns.rs:443-444 — the payloads, at the offset read above.
            var s_value = try self.value.stageSpliceSlice(value_pos, 0, raw.items);
            defer s_value.deinit();
            // columns.rs:464-492 — the five index columns.
            var s_mark = try self.index.mark.stageExtend(pos, mark_builders);
            defer s_mark.deinit();

            // The commit. Every publish is infallible and consumes its stage,
            // and the `defer`s above are no-ops afterwards.
            s_id_actor.publish(&self.id_actor);
            s_id_ctr.publish(&self.id_ctr);
            s_obj_actor.publish(&self.obj_actor);
            s_obj_ctr.publish(&self.obj_ctr);
            s_key_actor.publish(&self.key_actor);
            s_key_ctr.publish(&self.key_ctr);
            s_key_str.publish(&self.key_str);
            s_insert.publish(&self.insert);
            s_action.publish(&self.action);
            s_expand.publish(&self.expand);
            s_mark_name.publish(&self.mark_name);
            s_value_meta.publish(&self.value_meta);
            s_text.publish(&self.index.text);
            s_top.publish(&self.index.top);
            s_visible.publish(&self.index.visible);
            s_succ_count.publish(&self.succ_count);
            s_succ_actor.publish(&self.succ_actor);
            s_succ_ctr.publish(&self.succ_ctr);
            s_inc.publish(&self.index.inc);
            s_value.publish(&self.value);
            s_mark.publish(&self.index.mark);
            return n;
        }

        /// Removes the `ops` rows from `pos` and returns how many rows were
        /// removed (`Columns::remove_ops`, `columns.rs:361-417`).
        ///
        /// This is `splice` with the insertion and the removal exchanged: the
        /// same filter (`:365`), the same two prefix positions read first
        /// (`:368-369`), the same twenty-one columns, and the same two counts
        /// — `del`, the number of rows, and `succ_del`, the number of
        /// successors, which is why the successor columns are only touched
        /// when it is not zero (`:406-416`).
        ///
        /// The mark index is undone from the same builder list `splice`
        /// extends with, because upstream's is: `remove_ops` collects
        /// `ops.map(O::mark_index)` and hands it to `undo`
        /// (`columns.rs:410-411`), which reads the begin ids out of it and
        /// drops the data (`mark_index.rs:291-299`). That is why the name
        /// here is the op's own rather than the interned one: it is never
        /// stored, and interning a name for a row on its way out would grow
        /// the document's string table for nothing.
        ///
        /// **`ops` is `anytype`, not `[]const O`,** and [`opElementType`] says
        /// why and what the accepted shapes are: with `[]const O` this does not
        /// compile for the only op set a document has (`OpSet(ChangeOp)`),
        /// because the one caller that exists ([`OpSet.undoOp`](op_set.zig))
        /// hands over an [`OpBuilder`](op.zig) and not an `O`. **One type
        /// parameter is narrower than a trait**, and every place this port
        /// collapsed a trait into a parameter has this shape.
        pub fn removeOps(self: *Self, gpa: Allocator, pos: usize, ops: anytype) ParseError!usize {
            const B = opElementType(@TypeOf(ops));
            // A slice is already one; a pointer to an array is not, and
            // `ops[0..]` is the spelling that turns it into one.
            const items: []const B = if (@typeInfo(@TypeOf(ops)).pointer.size == .slice) ops else ops[0..];
            var kept: std.ArrayList(B) = .empty;
            defer kept.deinit(gpa);
            for (items) |o| {
                if (o.action() == .delete) continue; // columns.rs:365
                try kept.append(gpa, o);
            }
            const rows = kept.items;
            const del = rows.len;

            // columns.rs:368-369 — before anything moves.
            const value_pos = try prefixOffset(MetaColumn, &self.value_meta, pos);
            const succ_pos = try prefixOffset(CountColumn, &self.succ_count, pos);

            var raw_len: usize = 0;
            var succ_del: usize = 0;
            for (rows) |o| {
                raw_len += optypes.rawLen(o.value());
                succ_del += o.succCount();
            }

            // columns.rs:410 — the same one-builder-per-row list `splice`
            // extends with, and the only thing that arrives before the row
            // columns move, so a builder that cannot be built leaves the
            // columns as they were. `undo` needs the ids alone.
            var mark_builders = try gpa.alloc(?markidx.MarkIndexBuilder, del);
            defer gpa.free(mark_builders);
            for (rows, 0..) |o, i| {
                mark_builders[i] = try markBuilderOf(o, o.markName(), o.value());
            }

            // columns.rs:371-390 — the row columns, in upstream's order.
            //
            // **Staged, then published together**, for the reason
            // [`Columns.splice`] gives: twenty-one columns spliced in sequence
            // can be refused half way and leave a set whose columns disagree
            // about how many rows it has. `publish` cannot fail, so every stage
            // is built before any is published and the commit below is
            // infallible. `value` and `index.mark` are the two that are not
            // `Column`s and are written directly, after every stage is in hand.
            var s_id_actor = try self.id_actor.stageSplice(pos, del, &.{});
            defer s_id_actor.deinit();
            var s_id_ctr = try self.id_ctr.stageSplice(pos, del, &.{});
            defer s_id_ctr.deinit();
            var s_obj_actor = try self.obj_actor.stageSplice(pos, del, &.{});
            defer s_obj_actor.deinit();
            var s_obj_ctr = try self.obj_ctr.stageSplice(pos, del, &.{});
            defer s_obj_ctr.deinit();
            var s_key_actor = try self.key_actor.stageSplice(pos, del, &.{});
            defer s_key_actor.deinit();
            var s_key_ctr = try self.key_ctr.stageSplice(pos, del, &.{});
            defer s_key_ctr.deinit();
            var s_key_str = try self.key_str.stageSplice(pos, del, &.{});
            defer s_key_str.deinit();
            var s_insert = try self.insert.stageSplice(pos, del, &.{});
            defer s_insert.deinit();
            var s_action = try self.action.stageSplice(pos, del, &.{});
            defer s_action.deinit();
            var s_expand = try self.expand.stageSplice(pos, del, &.{});
            defer s_expand.deinit();
            var s_mark_name = try self.mark_name.stageSplice(pos, del, &.{});
            defer s_mark_name.deinit();
            var s_value_meta = try self.value_meta.stageSplice(pos, del, &.{});
            defer s_value_meta.deinit();
            // columns.rs:410-416 — the index columns, all four row-aligned
            // ones at the same `pos` and `del` the rows had.
            var s_text = try self.index.text.stageSplice(pos, del, &.{});
            defer s_text.deinit();
            var s_top = try self.index.top.stageSplice(pos, del, &.{});
            defer s_top.deinit();
            var s_visible = try self.index.visible.stageSplice(pos, del, &.{});
            defer s_visible.deinit();
            // columns.rs:403-416 — the successor counts, then the flattened
            // pair and the increments.
            var s_succ_count = try self.succ_count.stageSplice(pos, del, &.{});
            defer s_succ_count.deinit();
            // The successor columns are only touched when there is something to
            // take out, which is upstream's `:406-416` and is why `spliceSlice`
            // below is conditional in the same way.
            var s_succ_actor: ?ActorColumn.StagedSplice = null;
            defer if (s_succ_actor) |*st| st.deinit();
            var s_succ_ctr: ?CounterColumn.StagedSplice = null;
            defer if (s_succ_ctr) |*st| st.deinit();
            var s_inc: ?IncColumn.StagedSplice = null;
            defer if (s_inc) |*st| st.deinit();
            if (succ_del > 0) {
                s_succ_actor = try self.succ_actor.stageSplice(succ_pos, succ_del, &.{});
                s_succ_ctr = try self.succ_ctr.stageSplice(succ_pos, succ_del, &.{});
                s_inc = try self.index.inc.stageSplice(succ_pos, succ_del, &.{});
            }

            // columns.rs:396-401 — the raw payloads, by their byte length.
            var s_value = try self.value.stageSpliceSlice(value_pos, raw_len, &.{});
            defer s_value.deinit();
            var s_mark = try self.index.mark.stageUndo(pos, mark_builders);
            defer s_mark.deinit();

            // The commit.
            s_id_actor.publish(&self.id_actor);
            s_id_ctr.publish(&self.id_ctr);
            s_obj_actor.publish(&self.obj_actor);
            s_obj_ctr.publish(&self.obj_ctr);
            s_key_actor.publish(&self.key_actor);
            s_key_ctr.publish(&self.key_ctr);
            s_key_str.publish(&self.key_str);
            s_insert.publish(&self.insert);
            s_action.publish(&self.action);
            s_expand.publish(&self.expand);
            s_mark_name.publish(&self.mark_name);
            s_value_meta.publish(&self.value_meta);
            s_text.publish(&self.index.text);
            s_top.publish(&self.index.top);
            s_visible.publish(&self.index.visible);
            s_succ_count.publish(&self.succ_count);
            if (s_succ_actor) |*st| st.publish(&self.succ_actor);
            if (s_succ_ctr) |*st| st.publish(&self.succ_ctr);
            if (s_inc) |*st| st.publish(&self.index.inc);
            s_value.publish(&self.value);
            s_mark.publish(&self.index.mark);
            return del;
        }

        /// The mark index builder for one op, or null for a row that is not
        /// part of a mark (`OpBuilder::mark_index`, `op_set2/op.rs:191-202`).
        ///
        /// Upstream matches the op's action against its mark name: a mark
        /// row *with* a name is a begin and carries the `MarkData` it puts
        /// on its span, a mark row *without* one is the end of the mark that
        /// began at `id.prev()`, and every other row is nothing
        /// (`:194-200`). The port reads the same three answers out of the one
        /// accessor it already had: the op's own mark word is null for a row
        /// that is not a mark, positive for a begin and negative for an end
        /// ([op.zig:742-757](op.zig)), and `MarkIdx.load` decodes which of
        /// the three it is and names the begin (`mark_index.rs:36-49`). For
        /// every well-formed op the two agree, because the word is *built*
        /// from that match.
        ///
        /// `name` is the name the cache will hold. It is the caller's choice
        /// and the two callers choose differently: `splice` passes the
        /// document's interned copy, because the value outlives the op, and
        /// `removeOps` passes the op's own, because `undo` drops it. A begin
        /// with no name at all is `error.InvalidValue`: the word and the name
        /// are the same fact stated twice, and an op that says both ways is
        /// a document this port is expected to survive rather than a
        /// position it may invent ([error.zig:6-12](../error.zig)).
        /// **`o` is `anytype` for the same reason [`removeOps`]'s `ops` is**: it
        /// asks one op-like thing of it, `markIndex()`, and the caller is not
        /// always holding this column set's `O`.
        fn markBuilderOf(
            o: anytype,
            name: ?[]const u8,
            value: optypes.ScalarValue,
        ) ParseError!?markidx.MarkIndexBuilder {
            const word = o.markIndex() orelse return null;
            return switch (markidx.MarkIdx.load(word)) {
                .start => |begin| .{ .start = .{
                    .id = begin,
                    .data = .{
                        .name = name orelse return error.InvalidValue,
                        .value = value,
                    },
                } },
                .end => |begin| .{ .end = begin },
            };
        }
    };
}

const slabmod = @import("../hexane/slab.zig");

// ── Free functions the column set is written in terms of ───────────────────

/// Ascending by normalized specification, which is the order a stored column
/// set carries ([ids.zig:149-153](ids.zig)).
fn columnLessThan(_: void, a: ColumnSpec, b: ColumnSpec) bool {
    return a.lessThan(b);
}

/// Whether `spec` is one of the sixteen op set columns, ignoring the DEFLATE
/// bit, which is the whole of upstream's `validate` filter
/// (`columns.rs:228-247`).
fn isOpSpec(spec: ColumnSpec) bool {
    for (ids.all_column_specs) |declared| {
        if (declared.eql(spec)) return true;
    }
    return false;
}

/// That the columns of `cols` cover `[0, data.len)` with no gap and no
/// overlap, in order. Upstream's `ColumnLayoutParser` is handed the data size
/// for exactly this (`storage/columns.rs:77-86`).
fn checkContiguous(cols: RawColumns) ParseError!void {
    var at: usize = 0;
    for (cols.columns) |col| {
        if (col.range.start != at) return error.ColumnOutOfBounds;
        at = col.range.end;
    }
    if (at < cols.data.len) return error.TrailingBytes;
    if (at > cols.data.len) return error.ColumnOutOfBounds;
}

/// The bytes of `spec`, or none at all when the set holds no such column
/// (`columns.rs:254`, whose `data_for` is `&data[cols.get(..).unwrap_or_default()]`).
fn bytesFor(cols: RawColumns, spec: ColumnSpec) ParseError![]const u8 {
    return (try cols.bytesFor(spec)) orelse &.{};
}

/// The offset row `pos` starts at in a prefix column, as the byte offset or
/// sub-position the op set splices at (`columns.rs:297`, `:368`, `:425`).
fn prefixOffset(comptime Col: type, col: *const Col, pos: usize) ParseError!usize {
    const at = try col.getPrefix(pos);
    return std.math.cast(usize, at) orelse error.Overflow;
}

/// A counter that fits the column's `u32`, or a refusal.
///
/// Upstream writes `as u32` (`columns.rs:429-430`, `:458-459`), which
/// truncates. This refuses instead: a counter at or above 2^32 is not a value
/// the column could hold, and a truncated one would name a different op.
fn counterOf(v: i64) ParseError!u32 {
    if (v < 0) return error.Overflow;
    return std.math.cast(u32, v) orelse error.Overflow;
}

/// The nullable form of [`counterOf`], for `key_ctr` (`columns.rs:434-435`).
fn optCounter(v: ?i64) ParseError!?u32 {
    const n = v orelse return null;
    return try counterOf(n);
}

/// A successor count that fits `u32` (`columns.rs:446`).
fn countOf(n: usize) ParseError!u32 {
    return std.math.cast(u32, n) orelse error.Overflow;
}

/// The interned id of a row's map key, or null for a sequence anchor
/// (`columns.rs:434`).
fn internKey(gpa: Allocator, key: KeyRef, strings: StringTable) ParseError!?u32 {
    const str = key.keyStr() orelse return null;
    return try strings.intern(strings.ctx, str, gpa);
}

/// The interned id of a row's mark name (`columns.rs:441`).
fn internMarkName(gpa: Allocator, name: ?[]const u8, strings: StringTable) ParseError!?u32 {
    const str = name orelse return null;
    return try strings.intern(strings.ctx, str, gpa);
}

/// The bytes an interned id names, or null for a row with no string there
/// ([StringTable]).
///
/// This is the other half of `internMarkName`, and it exists because the mark
/// index's cache stores a `MarkData` whose name is a borrowed slice
/// ([`marks.zig:462-474`](../marks.zig)). A splice therefore hands the cache
/// the name resolved out of the document's own table rather than the one the
/// op carried, and this is what turns the id `mark_name` holds back into those
/// bytes. The table that owns them must outlive the op set.
fn internedName(id: ?u32, strings: StringTable) ?[]const u8 {
    const which = id orelse return null;
    return strings.resolve(strings.ctx, which);
}

/// The wire form of a nullable delta column, or null when every row is absent
/// (`columns.rs:152-154`, which is `save_to_unless(data, None)`).
///
/// The other six suppressed columns ask the column layer, which compares a
/// run's *wire* value against the value to suppress
/// ([column.zig:1931-1954](../hexane/column.zig)); a delta column's wire
/// value is a difference from the row in front and not the row's own value
/// ([column.zig:1117](../hexane/column.zig)), so that comparison is a type
/// error there. This asks the question the only way a delta column can
/// answer it, one row at a time, and `key_ctr` is the only column in the op
/// set that needs it.
fn encodeUnlessAllNull(comptime Col: type, gpa: Allocator, col: *const Col) ParseError!?[]u8 {
    var it = try col.iterator();
    while (try it.next()) |v| {
        if (v != null) return try col.encode(gpa);
    }
    return null;
}

/// The length-prefixed wire form of a string column, or null when every row is
/// absent (`columns.rs:155`, `:159-161`).
///
/// This is the one place the two string columns are written, and the bytes
/// are `ColumnType::String`'s: a run-length run sequence whose value payload
/// is the string's length as unsigned LEB128 followed by the bytes
/// (`hexane/src/lib.rs:696-716`). An all-absent column has no run to write,
/// which is what drops it.
fn encodeInterned(gpa: Allocator, col: *const UintOptColumn, strings: StringTable) ParseError!?[]u8 {
    if (try col.isOnly(null)) return null;
    var values: std.ArrayList(?[]const u8) = .empty;
    defer {
        for (values.items) |v| {
            if (v) |bytes| gpa.free(bytes);
        }
        values.deinit(gpa);
    }
    var it = try col.iterator();
    while (try it.next()) |id| {
        // The wire carries the bytes, so the ids are resolved here and copied
        // out; the column itself never learns a string.
        try values.append(gpa, if (id) |i| try gpa.dupe(u8, strings.resolve(strings.ctx, i)) else null);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try columnar.RleSlice.append(&out, gpa, values.items);
    return try out.toOwnedSlice(gpa);
}

/// A string column read back from the wire, as interned ids
/// (`columns.rs:279`, `:285`).
fn decodeInterned(
    gpa: Allocator,
    bytes: []const u8,
    rows: usize,
    strings: StringTable,
) ParseError!UintOptColumn {
    if (bytes.len == 0) {
        // A column the document omitted is every row absent, not no rows at
        // all (columns.rs:266-283, and the fill rule at
        // [column.zig:2694-2709](../hexane/column.zig)).
        return UintOptColumn.fill(gpa, rows, null);
    }
    try columnar.RleSlice.canonical(bytes);
    const values = try columnar.RleSlice.decodeAll(bytes, gpa);
    defer gpa.free(values);
    if (values.len != rows) return error.InvalidValue;
    const interned = try gpa.alloc(?u32, values.len);
    defer gpa.free(interned);
    for (values, interned) |v, *slot| {
        slot.* = if (v) |text| try strings.intern(strings.ctx, text, gpa) else null;
    }
    var col = try UintOptColumn.init(gpa);
    errdefer col.deinit();
    try col.extend(gpa, interned);
    return col;
}

/// Loads a column and holds it to `rows` rows, with no fill
/// (`columns.rs:265`, `:288`, `:303`).
fn loadLen(
    comptime Col: type,
    gpa: Allocator,
    cols: RawColumns,
    spec: ColumnSpec,
    rows: usize,
) ParseError!Col {
    return Col.loadWith(gpa, try bytesFor(cols, spec), Col.LoadOpts.new().withLength(rows));
}

/// Loads a column and holds it to `rows` rows, reading an absent column as
/// `rows` copies of `fill` (`columns.rs:266-283`).
fn loadFilled(
    comptime Col: type,
    gpa: Allocator,
    cols: RawColumns,
    spec: ColumnSpec,
    rows: usize,
    fill: Col.Value,
) ParseError!Col {
    return Col.loadWith(gpa, try bytesFor(cols, spec), Col.LoadOpts.new().withLength(rows).withFill(fill));
}

/// Loads one of the two string columns as interned ids (`columns.rs:279`, `:285`).
fn loadInterned(
    gpa: Allocator,
    cols: RawColumns,
    spec: ColumnSpec,
    rows: usize,
    strings: StringTable,
) ParseError!UintOptColumn {
    return decodeInterned(gpa, try bytesFor(cols, spec), rows, strings);
}

/// The actor remap that inserts a new actor at `idx` (`columns.rs:344-347`).
fn actorShiftedUp(idx: ActorIdx, a: ActorIdx) ActorIdx {
    return if (a >= idx) a + 1 else a;
}

/// The actor remap that removes the actor at `idx` (`columns.rs:352-355`).
///
/// The `a == idx` arm cannot happen: `rewriteWithoutActor` has already
/// refused. Falling out of the range check is the honest answer for a
/// function that cannot report an error, and it is unreachable.
fn actorShiftedDown(idx: ActorIdx, a: ActorIdx) ActorIdx {
    return if (a > idx) a - 1 else a;
}

/// The nullable form of an actor remap, for `obj_actor` and `key_actor`
/// (`columns.rs:337`, `:338`).
fn shiftOptActor(comptime Ctx: type, comptime f: fn (Ctx, ActorIdx) ActorIdx) fn (Ctx, ?ActorIdx) ?ActorIdx {
    return struct {
        fn go(ctx: Ctx, a: ?ActorIdx) ?ActorIdx {
            const one = a orelse return null;
            return f(ctx, one);
        }
    }.go;
}

/// Whether a non-nullable actor column names `idx` anywhere.
fn hasActor(col: *const ActorColumn, idx: ActorIdx) ParseError!bool {
    var it = try col.iterator();
    while (try it.next()) |a| {
        if (a == idx) return true;
    }
    return false;
}

/// One column's renumbering, built beside the column and handed back for
/// [`Columns.remapActors`] to publish.
///
/// It is [`Column.remapped`]: the borrowed build that reads this column and
/// writes a fresh one. **The column handed in is not written, not released,
/// and holds every byte it held** — so the caller still owns it, whole, while
/// the four stages are being built and again if one of them is refused.
///
/// The value returned is a whole column of the caller's own, in `gpa` and on
/// the source's run budget, and it is the only thing this hands over: a
/// refusal frees the partial build and propagates with nothing to release.
///
/// (This used to copy the column and remap the copy. A column is a slab list,
/// an index and a weight array rather than one byte buffer, so that copy was
/// an alias of the original's storage: remapping it released slabs the
/// original still named, and the publication released them a second time. The
/// whole-column clone a stage wants is a copy of the *values*, which is what
/// this build already does, run at a time.)
fn stagedRemap(
    comptime C: type,
    comptime V: type,
    col: *const C,
    gpa: Allocator,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), V) V,
) ParseError!C {
    return col.remapped(gpa, ctx, f);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The op type these tests splice: a row held by value, with the accessors
/// `Columns` calls and nothing else. It is the smallest thing that answers
/// every question `splice` and `removeOps` ask of an op, which is what makes
/// the tests below statements about the columns rather than about a view.
const Row = struct {
    op_id: OpId = .root,
    parent: ?OpId = null,
    act: Action = .set,
    anchor: KeyRef = .fromStr(""),
    does_insert: bool = false,
    does_expand: bool = false,
    is_visible: bool = true,
    is_top: bool = true,
    units: i64 = 0,
    v: optypes.ScalarValue = .null_value,
    name: ?[]const u8 = null,
    mark: ?i64 = null,
    succs: []const OpId = &.{},
    incs: []const ?i64 = &.{},

    pub fn id(self: Row) OpId {
        return self.op_id;
    }

    pub fn obj(self: Row) ?OpId {
        return self.parent;
    }

    pub fn action(self: Row) Action {
        return self.act;
    }

    pub fn key(self: Row) KeyRef {
        return self.anchor;
    }

    pub fn insert(self: Row) bool {
        return self.does_insert;
    }

    pub fn expand(self: Row) bool {
        return self.does_expand;
    }

    pub fn visible(self: Row) bool {
        return self.is_visible;
    }

    pub fn top(self: Row) bool {
        return self.is_top;
    }

    /// Upstream's is a `u64` (`op_set2/op.rs:1355`); a width is never
    /// negative, so the narrower type is behaviour-preserving and it is the
    /// one `key_ctr`'s and `index.text`'s own column widths are held at.
    pub fn width(self: Row, _: types.SequenceType, _: types.TextEncoding) i64 {
        return self.units;
    }

    pub fn value(self: Row) optypes.ScalarValue {
        return self.v;
    }

    /// The metadata word the value encodes as (`op_set2/meta.rs:73-93`),
    /// which is what upstream's `OpLike::meta_value` answers for a row
    /// (`op_set2/op.rs:1344-1346`).
    pub fn metaValue(self: Row) ValueMeta {
        return optypes.metaOf(self.v);
    }

    pub fn markName(self: Row) ?[]const u8 {
        return self.name;
    }

    /// The word this row puts in the mark index, or null for a row that is
    /// not part of a mark (`OpBuilder::mark_index`, `op_set2/op.rs:191-202`;
    /// encoded by `MarkIdx::asI64`, `mark_index.rs:25-34`).
    ///
    /// A mark's end carries the *begin's* id, negated, and not its own
    /// (`op_set2/op.rs:199`), so a row names the mark it belongs to either
    /// way and `markBuilderOf` has one id to read out of the word.
    pub fn markIndex(self: Row) ?i64 {
        return self.mark;
    }

    pub fn succCount(self: Row) usize {
        return self.succs.len;
    }

    pub fn succAt(self: Row, i: usize) OpId {
        return self.succs[i];
    }

    pub fn succIncCount(self: Row) usize {
        return self.incs.len;
    }

    pub fn succIncAt(self: Row, i: usize) ?i64 {
        return self.incs[i];
    }
};

/// The mark index word for a mark that begins at `id` (`MarkIdx::as_i64`,
/// `mark_index.rs:25-34`).
///
/// A [`Row`] carries the word rather than the begin-or-end it stands for,
/// because that is what `markIndex` hands the column set: the op decides the
/// word and `splice` only has to name the begin it decodes back out.
fn markStartWord(id: OpId) i64 {
    const m: markidx.MarkIdx = .{ .start = id };
    return m.asI64();
}

/// The word for the row that ends the mark beginning at `begin`
/// (`MarkIdx::as_i64`, `mark_index.rs:25-34`): the begin's id, negated
/// (`mark_index.rs:54-58`, and the rule at `op_set2/op.rs:199`).
fn markEndWord(begin: OpId) i64 {
    const m: markidx.MarkIdx = .{ .end = begin };
    return m.asI64();
}

/// A sequence anchor from a counter and an actor.
///
/// `ElemId` wraps the `OpId` rather than being one (`types.rs:652-653`), so a
/// row's `.anchor` takes the wrapper: [`types.ElemId.head`] for the front of a
/// sequence, and this for an element that exists.
fn seqAt(ctr: u32, actor: ActorIdx) KeyRef {
    return .fromElemId(types.ElemId.fromOpId(OpId.init(ctr, actor)));
}

/// A string table for the tests: the strings it has been given, in the order
/// they were first asked for, which is what makes an interned id stable across
/// a save and a load.
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

    /// The id of a string is its position, so a table that has interned more
    /// than 2^32 strings cannot name the last of them. The bound is checked
    /// rather than assumed: a `@intCast` of a collection length here would
    /// trap in a debug build and wrap in a release one.
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

/// The rows of `col`, for a test that wants to read a column all at once.
fn valuesOf(comptime Col: type, col: *const Col, gpa: Allocator) ParseError![]Col.Value {
    return col.toSlice(gpa);
}

/// The mark index's rows, decoded, in order (`MarkIndexColumn::iter`,
/// `mark_index.rs:252-254`), for a test that wants to read them all at once.
///
/// By runs, because a row that carries no mark and the end of the window are
/// the same `null` in this cursor ([mark_index.zig:503-511](mark_index.zig)):
/// walking it row by row would stop at the first unmarked row.
fn markRows(col: *const markidx.MarkIndexColumn, gpa: Allocator) ParseError![]?markidx.MarkIdx {
    var out: std.ArrayList(?markidx.MarkIdx) = .empty;
    errdefer out.deinit(gpa);
    var it = try col.iter();
    while (try it.nextRun()) |run| {
        var left = run.count;
        while (left > 0) : (left -= 1) try out.append(gpa, run.value);
    }
    return out.toOwnedSlice(gpa);
}

/// That the mark index's cache and its rows name the same marks: every row's
/// begin is in the cache, and there is one cached mark per `Start` row.
///
/// The two halves are written by one `extend` and read as one by
/// `richTextAt` (`mark_index.rs:277-286`, `:302-313`), and a remap that moved
/// the rows without the cache keys — or the other way round — is the only
/// thing that can make them disagree, and nothing else would notice.
fn expectCacheAgreesWithRows(mark: *const markidx.MarkIndexColumn, gpa: Allocator) !void {
    const rows = try markRows(mark, gpa);
    defer gpa.free(rows);
    var starts: usize = 0;
    for (rows) |row| {
        const m = row orelse continue;
        const begin = switch (m) {
            .start => |id| id,
            .end => |id| id,
        };
        if (std.meta.activeTag(m) == .start) starts += 1;
        if (mark.markData(begin) == null) return error.TestUnexpectedResult;
    }
    try testing.expectEqual(starts, mark.cache.count());
}

/// That every row column of `cols` holds `rows` rows, and that the successor
/// columns hold as many successors as `succ_count` declares. This is the one
/// invariant the whole engine agrees on, so a test that splices checks it
/// after every splice rather than only at the end.
fn checkLengths(cols: *const Columns(Row), gpa: Allocator, rows: usize, succs: usize) !void {
    const c = cols;
    try testing.expectEqual(rows, c.len());
    try testing.expectEqual(succs, c.subLen());
    try testing.expectEqual(rows, c.id_ctr.len());
    try testing.expectEqual(rows, c.obj_actor.len());
    try testing.expectEqual(rows, c.obj_ctr.len());
    try testing.expectEqual(rows, c.key_actor.len());
    try testing.expectEqual(rows, c.key_ctr.len());
    try testing.expectEqual(rows, c.key_str.len());
    try testing.expectEqual(rows, c.succ_count.len());
    try testing.expectEqual(rows, c.insert.len());
    try testing.expectEqual(rows, c.action.len());
    try testing.expectEqual(rows, c.value_meta.len());
    try testing.expectEqual(rows, c.mark_name.len());
    try testing.expectEqual(rows, c.expand.len());
    const idx = c.index.lengths();
    try testing.expectEqual(rows, idx.text);
    try testing.expectEqual(rows, idx.top);
    try testing.expectEqual(rows, idx.visible);
    try testing.expectEqual(rows, idx.mark);
    // And the successor total the flattened pair is indexed against is the
    // sum of the counts, not the row count (columns.rs:297-300).
    const counts = try valuesOf(CountColumn, &c.succ_count, gpa);
    defer gpa.free(counts);
    var total: usize = 0;
    for (counts) |n| total += n;
    try testing.expectEqual(succs, total);
}

/// Whether a nullable actor column names `idx` anywhere.
fn hasOptActor(col: *const ActorOptColumn, idx: ActorIdx) ParseError!bool {
    var it = try col.iterator();
    while (try it.next()) |a| {
        if (a) |one| {
            if (one == idx) return true;
        }
    }
    return false;
}

// ── The tests' rows ────────────────────────────────────────────────────────

/// A row that puts a non-default value in every column it can: a parent, a
/// string key, a payload, a width, an insert, a mark name, an expansion, a
/// successor and an increment. Used for the round trip and for the export
/// that has to write all sixteen columns.
const rich: [4]Row = .{
    // The root map: no parent, a string key, no value.
    .{
        .op_id = .{ .counter = 1, .actor = 0 },
        .parent = null,
        .act = .make_map,
        .anchor = .fromStr("map"),
    },
    // An insert into it, anchored to a sequence, carrying a payload.
    .{
        .op_id = .{ .counter = 2, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .set,
        .anchor = seqAt(1, 0),
        .does_insert = true,
        .units = 1,
        .v = .{ .str = "x" },
    },
    // A mark over the same element, with a name, an expansion and a mark
    // index, hidden and not top.
    .{
        .op_id = .{ .counter = 3, .actor = 1 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .mark,
        .anchor = seqAt(2, 0),
        .does_expand = true,
        .is_visible = false,
        .is_top = false,
        .name = "em",
        .mark = markStartWord(.{ .counter = 3, .actor = 1 }),
    },
    // An overwrite of the first element by a second actor, with two
    // successors: the one it replaces and an increment of its own.
    .{
        .op_id = .{ .counter = 1, .actor = 1 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .set,
        .anchor = seqAt(1, 0),
        .units = 1,
        .v = .{ .str = "yz" },
        .succs = &.{ .{ .counter = 2, .actor = 0 }, .{ .counter = 1, .actor = 1 } },
        .incs = &.{ null, @as(?i64, 5) },
    },
};

/// A hand-built op set that reaches all three shapes the key columns have: a
/// map key, a sequence anchor that names a real element, and — in
/// `head_anchored`, beside this one — a sequence anchor that is the head.
///
/// **These rows are a column fixture, not a document.** The sequence anchors
/// here name element ids the set does not itself create, because a set that
/// created its own first list element would have to anchor it at the head
/// (`op_set2/batch.rs:264-300`, the stack upstream pre-seeds with anything
/// whose predecessor is `HEAD`), and the head's encoding is the one thing
/// `ElemId` changes. Keeping the head out is what lets [`three_kinds`] pin the
/// bytes a non-head anchor produced before the type existed and must still
/// produce.
const three_kinds: [9]Row = .{
    // The root map, and the three objects it holds.
    .{ .op_id = .{ .counter = 1, .actor = 0 }, .act = .make_map, .anchor = .fromStr("m") },
    .{
        .op_id = .{ .counter = 2, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .make_list,
        .anchor = .fromStr("l"),
    },
    .{
        .op_id = .{ .counter = 3, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .make_text,
        .anchor = .fromStr("t"),
    },
    // A map row, with a payload and a width that is not top's to answer for.
    .{
        .op_id = .{ .counter = 4, .actor = 0 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .set,
        .anchor = .fromStr("k"),
        .units = 1,
        .v = .{ .int = 7 },
    },
    // A list row: a sequence anchor, so it writes `key_actor` and `key_ctr`
    // and leaves `key_str` absent (`columns.rs:434`).
    .{
        .op_id = .{ .counter = 5, .actor = 0 },
        .parent = .{ .counter = 2, .actor = 0 },
        .act = .set,
        .anchor = seqAt(4, 0),
        .units = 1,
        .v = .{ .int = 3 },
    },
    // A text row, the other half of the same shape.
    .{
        .op_id = .{ .counter = 6, .actor = 0 },
        .parent = .{ .counter = 3, .actor = 0 },
        .act = .set,
        .anchor = seqAt(5, 0),
        .units = 2,
        .v = .{ .str = "hi" },
    },
    // A second actor overwriting the map key: a successor edge and nothing
    // else that a first-actor set would not have written.
    .{
        .op_id = .{ .counter = 1, .actor = 1 },
        .parent = .{ .counter = 1, .actor = 0 },
        .act = .set,
        .anchor = .fromStr("k"),
        .v = .{ .int = 9 },
        .succs = &.{.{ .counter = 4, .actor = 0 }},
    },
    // A list row by the second actor, so `key_actor` names an actor other
    // than zero and `key_ctr` a counter other than the one in front of it.
    .{
        .op_id = .{ .counter = 2, .actor = 1 },
        .parent = .{ .counter = 2, .actor = 0 },
        .act = .set,
        .anchor = seqAt(3, 0),
        .units = 1,
        .v = .{ .int = 4 },
    },
    // A mark over the text element: hidden, not top, a name and an expansion
    // and a mark index word.
    .{
        .op_id = .{ .counter = 3, .actor = 1 },
        .parent = .{ .counter = 3, .actor = 0 },
        .act = .mark,
        .anchor = seqAt(6, 0),
        .does_expand = true,
        .is_visible = false,
        .is_top = false,
        .name = "b",
        .mark = markStartWord(.{ .counter = 3, .actor = 1 }),
    },
};

/// The same nine rows with one sequence anchor replaced by the head, which is
/// the row shape that could not be written before `ElemId` was a type: an
/// insert at the front of a list (`op_set2/op_set.rs:1984`).
const head_anchored: [9]Row = .{
    three_kinds[0],
    three_kinds[1],
    three_kinds[2],
    three_kinds[3],
    .{
        .op_id = .{ .counter = 5, .actor = 0 },
        .parent = .{ .counter = 2, .actor = 0 },
        .act = .set,
        .anchor = .fromElemId(types.ElemId.head()),
        .does_insert = true,
        .units = 1,
        .v = .{ .int = 3 },
    },
    three_kinds[5],
    three_kinds[6],
    three_kinds[7],
    three_kinds[8],
};

/// The specifications in `cols`, in the order the set carries them.
fn specsOf(cols: RawColumns, gpa: Allocator) Allocator.Error![]ColumnSpec {
    var out: std.ArrayList(ColumnSpec) = .empty;
    errdefer out.deinit(gpa);
    for (cols.columns) |col| try out.append(gpa, col.spec);
    return out.toOwnedSlice(gpa);
}

/// The two columns' encodings, compared by content.
fn expectSameColumn(
    comptime Col: type,
    gpa: Allocator,
    a: *const Col,
    b: *const Col,
    tag: []const u8,
) !void {
    try testing.expectEqual(a.len(), b.len());
    const left = try a.encode(gpa);
    defer gpa.free(left);
    const right = try b.encode(gpa);
    defer gpa.free(right);
    if (!std.mem.eql(u8, left, right)) {
        std.debug.print("column {s} differs\n  before: {x}\n  after:  {x}\n", .{ tag, left, right });
        return error.TestUnexpectedResult;
    }
}

/// That `a` and `b` are the same sixteen data columns, byte for byte.
fn expectSameColumns(gpa: Allocator, a: *const Columns(Row), b: *const Columns(Row)) !void {
    try expectSameColumn(ActorColumn, gpa, &a.id_actor, &b.id_actor, "id_actor");
    try expectSameColumn(CounterColumn, gpa, &a.id_ctr, &b.id_ctr, "id_ctr");
    try expectSameColumn(ActorOptColumn, gpa, &a.obj_actor, &b.obj_actor, "obj_actor");
    try expectSameColumn(UintOptColumn, gpa, &a.obj_ctr, &b.obj_ctr, "obj_ctr");
    try expectSameColumn(ActorOptColumn, gpa, &a.key_actor, &b.key_actor, "key_actor");
    try expectSameColumn(OptCounterColumn, gpa, &a.key_ctr, &b.key_ctr, "key_ctr");
    try expectSameColumn(UintOptColumn, gpa, &a.key_str, &b.key_str, "key_str");
    try expectSameColumn(CountColumn, gpa, &a.succ_count, &b.succ_count, "succ_count");
    try expectSameColumn(ActorColumn, gpa, &a.succ_actor, &b.succ_actor, "succ_actor");
    try expectSameColumn(CounterColumn, gpa, &a.succ_ctr, &b.succ_ctr, "succ_ctr");
    try expectSameColumn(BoolPrefixColumn, gpa, &a.insert, &b.insert, "insert");
    try expectSameColumn(ActionColumn, gpa, &a.action, &b.action, "action");
    try expectSameColumn(MetaColumn, gpa, &a.value_meta, &b.value_meta, "value_meta");
    try expectSameColumn(UintOptColumn, gpa, &a.mark_name, &b.mark_name, "mark_name");
    try expectSameColumn(BoolColumn, gpa, &a.expand, &b.expand, "expand");
    const left = try a.value.encode(gpa);
    defer gpa.free(left);
    const right = try b.value.encode(gpa);
    defer gpa.free(right);
    if (!std.mem.eql(u8, left, right)) {
        std.debug.print("column value differs\n  before: {x}\n  after:  {x}\n", .{ left, right });
        return error.TestUnexpectedResult;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "every column survives an export and a load" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();

    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    const written = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());
    try testing.expectEqual(rich.len, written);
    try checkLengths(&cols, gpa, 4, 2);

    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    var loaded = try Columns(Row).load(gpa, exported.cols, table.asTable());
    defer loaded.deinit();

    // Every one of the sixteen, by content and by length: the round trip has
    // to preserve the encoding, not merely the number of rows.
    try expectSameColumns(gpa, &cols, &loaded);
    // The five index columns are rebuilt, not loaded (columns.rs:314), so
    // they come back empty rather than as what was there — which is why the
    // length check above is the data columns' and not this one's.
    const idx = loaded.index.lengths();
    try testing.expectEqual([5]usize{ 0, 0, 0, 0, 0 }, .{
        idx.text, idx.top, idx.visible, idx.inc, idx.mark,
    });
    // And the string columns came back as the same ids, not as new ones.
    try testing.expectEqual(table.items.items.len, 2);
}

test "an op set that holds something in every column writes all sixteen, in order" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());

    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    const specs = try specsOf(exported.cols, gpa);
    defer gpa.free(specs);

    // Ascending by normalized specification, which is the order a stored
    // column set carries (ids.zig:200-217).
    const expected = [_]u32{ 1, 2, 17, 19, 21, 33, 35, 52, 66, 86, 87, 128, 129, 131, 148, 165 };
    try testing.expectEqual(expected.len, specs.len);
    for (specs, expected) |spec, word| try testing.expectEqual(word, spec.raw);
    // The data block is exactly the concatenation of the columns, in that
    // order, with nothing padded in between.
    try testing.expectEqual(exported.data.len, exported.cols.totalLen());
}

test "a column that holds only its default is dropped and one that does not is kept" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();

    // Two rows at the root, keyed by strings, with no mark and nothing
    // expanding: six of the seven suppressible columns hold their default
    // here, and the seventh is `key_str`, which does not.
    const at_root = [_]Row{
        .{ .op_id = .{ .counter = 1, .actor = 0 }, .parent = null, .act = .make_map, .anchor = .fromStr("a") },
        .{ .op_id = .{ .counter = 2, .actor = 0 }, .parent = null, .act = .make_list, .anchor = .fromStr("b") },
    };
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &at_root, .unicode_code_point, table.asTable());
    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    {
        const specs = try specsOf(exported.cols, gpa);
        defer gpa.free(specs);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(gpa);
        for (specs) |s| try words.append(gpa, s.raw);
        // Dropped: the five nullable columns that are all null here, and the
        // boolean that is all false (columns.rs:143-162).
        for ([_]u32{ 1, 2, 17, 19, 148, 165 }) |absent| {
            for (words.items) |w| try testing.expect(w != absent);
        }
        // Kept although every one of them holds a single repeated value:
        // `id_actor`, `id_ctr`, `key_str`, `insert` (all false), `action`
        // (two codes, so two runs) and `succ_count` (all zero).
        for ([_]u32{ 33, 35, 21, 52, 128 }) |present| {
            var found = false;
            for (words.items) |w| {
                if (w == present) found = true;
            }
            try testing.expect(found);
        }
    }

    // The seventh: a sequence anchor, so `key_str` holds its default and
    // `key_actor` and `key_ctr` do not.
    const in_sequence = [_]Row{
        .{
            .op_id = .{ .counter = 1, .actor = 0 },
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .set,
            .anchor = seqAt(1, 0),
        },
        .{
            .op_id = .{ .counter = 2, .actor = 0 },
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .set,
            .anchor = seqAt(2, 0),
        },
    };
    var seq_cols = try Columns(Row).init(gpa);
    defer seq_cols.deinit();
    _ = try seq_cols.splice(gpa, 0, &in_sequence, .unicode_code_point, table.asTable());
    var seq_exported = try seq_cols.exportColumns(gpa, table.asTable());
    defer seq_exported.deinit(gpa);
    const seq_specs = try specsOf(seq_exported.cols, gpa);
    defer gpa.free(seq_specs);
    var has_key_str = false;
    for (seq_specs) |s| {
        if (s.eql(ids.key_str_col_spec)) has_key_str = true;
    }
    try testing.expect(!has_key_str);
}

test "an op set with no rows writes no columns at all" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    try testing.expect(cols.isEmpty());

    // `id_actor` is saved whatever it holds rather than suppressed when it
    // holds its default (columns.rs:141), but a column of no bytes is not
    // part of a column set at all (column_spec.zig:324-333), so an op set
    // with no rows contributes nothing to the document.
    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    try testing.expectEqual(0, exported.cols.len());
    try testing.expectEqual(0, exported.data.len);
}

test "a delete writes no row, no successor and no index entry" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &.{rich[0]}, .unicode_code_point, table.asTable());

    const del: [3]Row = .{
        // A delete that names a successor of its own, so the filter is what
        // keeps it out rather than the op happening to have nothing to say.
        .{ .op_id = .{ .counter = 2, .actor = 0 }, .act = .delete, .succs = &.{.{ .counter = 1, .actor = 0 }} },
        .{ .op_id = .{ .counter = 3, .actor = 0 }, .act = .delete },
        .{ .op_id = .{ .counter = 4, .actor = 0 }, .act = .set },
    };
    const written = try cols.splice(gpa, 1, &del, .unicode_code_point, table.asTable());

    // One row written: the set. The two deletes are not rows, so they are not
    // in the return value either.
    try testing.expectEqual(1, written);
    try checkLengths(&cols, gpa, 2, 0);
    const actions = try valuesOf(ActionColumn, &cols.action, gpa);
    defer gpa.free(actions);
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, actions);
    // And the delete's own successor edge did not come along with it.
    const counts = try valuesOf(CountColumn, &cols.succ_count, gpa);
    defer gpa.free(counts);
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, counts);
}

test "a delete reaches the op set as a successor edge with no increment" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &.{rich[0]}, .unicode_code_point, table.asTable());

    // The op that the delete names as its predecessor, and the delete
    // itself. A delete is never a row, so the edge it adds is written by the
    // op set's successor bookkeeping and read here as an id in the flattened
    // pair with a null increment beside it (columns.rs:42, and the survey's
    // account of `add_succ`).
    const del: [2]Row = .{
        .{ .op_id = .{ .counter = 2, .actor = 0 }, .act = .delete, .parent = .{ .counter = 1, .actor = 0 } },
        .{
            .op_id = .{ .counter = 3, .actor = 0 },
            .act = .set,
            .parent = .{ .counter = 1, .actor = 0 },
            .succs = &.{.{ .counter = 2, .actor = 0 }},
            .incs = &.{null},
        },
    };
    const written = try cols.splice(gpa, 1, &del, .unicode_code_point, table.asTable());
    try testing.expectEqual(1, written);
    try checkLengths(&cols, gpa, 2, 1);
    const actors = try valuesOf(ActorColumn, &cols.succ_actor, gpa);
    defer gpa.free(actors);
    try testing.expectEqualSlices(ActorIdx, &.{0}, actors);
    const ctrs = try valuesOf(CounterColumn, &cols.succ_ctr, gpa);
    defer gpa.free(ctrs);
    try testing.expectEqualSlices(u32, &.{2}, ctrs);
    // The increment of a delete is absent, which is how one is told from a
    // counter update (columns.rs:42).
    const incs = try valuesOf(IncColumn, &cols.index.inc, gpa);
    defer gpa.free(incs);
    try testing.expectEqualSlices(?i64, &.{null}, incs);
}

test "a splice writes the five index columns from the op, and the two prefix weights answer" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());
    try checkLengths(&cols, gpa, 4, 2);

    // `index.text` is the width of a row that is top and absent otherwise
    // (columns.rs:466-471), so a row that is not top has no width at all.
    const widths = try valuesOf(TextColumn, &cols.index.text, gpa);
    defer gpa.free(widths);
    try testing.expectEqualSlices(?u32, &.{ 0, 1, null, 1 }, widths);
    const tops = try valuesOf(BoolPrefixColumn, &cols.index.top, gpa);
    defer gpa.free(tops);
    try testing.expectEqualSlices(bool, &.{ true, true, false, true }, tops);
    const visibles = try valuesOf(BoolColumn, &cols.index.visible, gpa);
    defer gpa.free(visibles);
    try testing.expectEqualSlices(bool, &.{ true, true, false, true }, visibles);
    // The mark index carries the row the op's own word stands for, decoded,
    // and nothing at all for a row that is not part of a mark.
    const begin = OpId{ .counter = 3, .actor = 1 };
    const marks = try markRows(&cols.index.mark, gpa);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 4), marks.len);
    try testing.expect(marks[0] == null);
    try testing.expect(marks[1] == null);
    try testing.expect(marks[2].?.eql(.{ .start = begin }));
    try testing.expect(marks[3] == null);
    // And the increments are indexed by sub-position, not by row: the two
    // successors of the last row are the only ones there are.
    const incs = try valuesOf(IncColumn, &cols.index.inc, gpa);
    defer gpa.free(incs);
    try testing.expectEqualSlices(?i64, &.{ null, 5 }, incs);

    // The two boolean prefix weights are the op set's own arithmetic: the
    // number of inserts before a row, and the number of tops before it
    // (`hexane/src/prefix.rs:316-325`). `insert` is a data column and
    // `index.top` an index column, and they answer from the same rule.
    const insert_prefix = [_]i64{ 0, 0, 1, 1 };
    const top_prefix = [_]i64{ 0, 1, 2, 2 };
    for (0..4) |i| {
        try testing.expectEqual(insert_prefix[i], try cols.insert.getPrefix(i));
        try testing.expectEqual(top_prefix[i], try cols.index.top.getPrefix(i));
    }
    try testing.expectEqual(@as(i64, 1), try cols.insert.getPrefix(4));
    try testing.expectEqual(@as(i64, 3), try cols.index.top.getPrefix(4));
}

test "the row count and the successor count agree after every splice" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    try checkLengths(&cols, gpa, 0, 0);

    var rows: usize = 0;
    var succs: usize = 0;
    const batches = [_][]const Row{
        rich[0..2],
        rich[2..4],
        &.{.{ .op_id = .{ .counter = 9, .actor = 0 }, .act = .set, .v = .{ .str = "zz" } }},
    };
    for (batches) |batch| {
        var batch_succs: usize = 0;
        for (batch) |o| batch_succs += o.succCount();
        rows += batch.len;
        succs += batch_succs;
        const written = try cols.splice(gpa, cols.len(), batch, .unicode_code_point, table.asTable());
        try testing.expectEqual(batch.len, written);
        try checkLengths(&cols, gpa, rows, succs);
    }
    try testing.expectEqual(5, rows);
    try testing.expectEqual(2, succs);
}

test "a splice at a non-zero position puts the payloads and the successors where they belong" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();

    // Three rows with payload lengths 2, 3 and 1 and successor counts 0, 2
    // and 0, so that a splice at 1 has to move the value arena and the
    // flattened pair by different amounts.
    const before = [_]Row{
        .{
            .op_id = .{ .counter = 1, .actor = 0 },
            .act = .set,
            .v = .{ .str = "ab" },
        },
        .{
            .op_id = .{ .counter = 2, .actor = 0 },
            .act = .set,
            .v = .{ .str = "cde" },
            .succs = &.{ .{ .counter = 1, .actor = 1 }, .{ .counter = 9, .actor = 2 } },
            .incs = &.{ @as(?i64, 1), null },
        },
        .{
            .op_id = .{ .counter = 3, .actor = 0 },
            .act = .set,
        },
    };
    _ = try cols.splice(gpa, 0, &before, .unicode_code_point, table.asTable());
    try checkLengths(&cols, gpa, 3, 2);

    // The inserted rows carry a payload of 2 bytes, an empty one and one
    // successor, so the value offset and the successor offset are both wrong
    // if either is read after the column it indexes has moved.
    const at: [2]Row = .{
        .{
            .op_id = .{ .counter = 1, .actor = 1 },
            .act = .set,
            .v = .{ .str = "ZZ" },
            .succs = &.{.{ .counter = 7, .actor = 3 }},
            .incs = &.{@as(?i64, -2)},
        },
        .{
            .op_id = .{ .counter = 2, .actor = 1 },
            .act = .set,
            .v = .{ .str = "" },
        },
    };
    const written = try cols.splice(gpa, 1, &at, .unicode_code_point, table.asTable());
    try testing.expectEqual(2, written);
    try checkLengths(&cols, gpa, 5, 3);

    // The payloads, in row order: the two inserted between "ab" and "cde".
    const value = try cols.value.encode(gpa);
    defer gpa.free(value);
    try testing.expectEqualStrings("abZZcde", value);
    // And the prefix the next splice at 3 would read is the sum of the
    // lengths before it: 2 + 2 + 0.
    try testing.expectEqual(@as(i64, 4), try cols.value_meta.getPrefix(3));
    try testing.expectEqual(@as(i64, 0), try cols.value_meta.getPrefix(0));
    try testing.expectEqual(@as(i64, 7), try cols.value_meta.getPrefix(4));
    // The metadata words come back in row order, and each one's length is the
    // number of payload bytes that belong to it.
    const metas = try valuesOf(MetaColumn, &cols.value_meta, gpa);
    defer gpa.free(metas);
    for (metas, 0..) |m, i| {
        const at_row = ValueMeta.fromRaw(m);
        const want: usize = switch (i) {
            0, 1 => 2,
            2 => 0,
            3 => 3,
            else => 0,
        };
        try testing.expectEqual(want, at_row.length());
    }
    // The successor pair: the inserted row's one successor comes first, then
    // the two that were already at row 1.
    const actors = try valuesOf(ActorColumn, &cols.succ_actor, gpa);
    defer gpa.free(actors);
    try testing.expectEqualSlices(ActorIdx, &.{ 3, 1, 2 }, actors);
    const ctrs = try valuesOf(CounterColumn, &cols.succ_ctr, gpa);
    defer gpa.free(ctrs);
    try testing.expectEqualSlices(u32, &.{ 7, 1, 9 }, ctrs);
    const counts = try valuesOf(CountColumn, &cols.succ_count, gpa);
    defer gpa.free(counts);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2, 0 }, counts);
    // And the increments are indexed by the same sub-position.
    const incs = try valuesOf(IncColumn, &cols.index.inc, gpa);
    defer gpa.free(incs);
    try testing.expectEqualSlices(?i64, &.{ -2, 1, null }, incs);
}

test "a row whose payload is every column's default still lengthens every row column" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();

    // **A default is a value, not the absence of a row.** Every column that
    // can hold an absent value holds one here, and the row is still written
    // into all eighteen row-indexed columns, because `cols.len()` *is*
    // `id_actor.len()` and a column one row short is a set the walk refuses
    // ([op_iter.zig:1883](op_iter.zig)). This is the row that would be a
    // candidate for a per-column skip if a default payload were one.
    //
    // `key_str` is the one column it cannot leave at its default: a
    // `KeyRef` with no counter is a map key ([types.zig:214-226](types.zig)),
    // and a map key is interned, so the column holds the id `0`.
    // `is_visible` and `is_top` are off here, and both default to `true` on
    // the type — a type default is not the column's default. With `is_top`
    // off the row has no width either (`columns.rs:466-471`).
    const defaults: [1]Row = .{.{
        .op_id = .{ .counter = 1, .actor = 0 },
        .is_visible = false,
        .is_top = false,
    }};
    _ = try cols.splice(gpa, 0, &defaults, .unicode_code_point, table.asTable());
    try checkLengths(&cols, gpa, 1, 0);

    // **Each of those defaults is read back, so "all-default" is a claim
    // about the columns and not a label on the fixture.**
    const obj_actors = try valuesOf(ActorOptColumn, &cols.obj_actor, gpa);
    defer gpa.free(obj_actors);
    try testing.expectEqualSlices(?ActorIdx, &.{null}, obj_actors);
    const obj_ctrs = try valuesOf(UintOptColumn, &cols.obj_ctr, gpa);
    defer gpa.free(obj_ctrs);
    try testing.expectEqualSlices(?u32, &.{null}, obj_ctrs);
    const key_actors = try valuesOf(ActorOptColumn, &cols.key_actor, gpa);
    defer gpa.free(key_actors);
    try testing.expectEqualSlices(?ActorIdx, &.{null}, key_actors);
    const key_ctrs = try valuesOf(OptCounterColumn, &cols.key_ctr, gpa);
    defer gpa.free(key_ctrs);
    try testing.expectEqualSlices(?u32, &.{null}, key_ctrs);
    const key_strs = try valuesOf(UintOptColumn, &cols.key_str, gpa);
    defer gpa.free(key_strs);
    try testing.expectEqualSlices(?u32, &.{0}, key_strs);
    const inserts = try valuesOf(BoolPrefixColumn, &cols.insert, gpa);
    defer gpa.free(inserts);
    try testing.expectEqualSlices(bool, &.{false}, inserts);
    const expands = try valuesOf(BoolColumn, &cols.expand, gpa);
    defer gpa.free(expands);
    try testing.expectEqualSlices(bool, &.{false}, expands);
    const mark_names = try valuesOf(UintOptColumn, &cols.mark_name, gpa);
    defer gpa.free(mark_names);
    try testing.expectEqualSlices(?u32, &.{null}, mark_names);
    const widths = try valuesOf(TextColumn, &cols.index.text, gpa);
    defer gpa.free(widths);
    try testing.expectEqualSlices(?u32, &.{null}, widths);
    const tops = try valuesOf(BoolPrefixColumn, &cols.index.top, gpa);
    defer gpa.free(tops);
    try testing.expectEqualSlices(bool, &.{false}, tops);
    const visibles = try valuesOf(BoolColumn, &cols.index.visible, gpa);
    defer gpa.free(visibles);
    try testing.expectEqualSlices(bool, &.{false}, visibles);
    const marks = try markRows(&cols.index.mark, gpa);
    defer gpa.free(marks);
    try testing.expect(marks[0] == null);
}

test "a single-row splice with no successors leaves the three successor columns as they were" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();

    // **Two rows, and the second carries two successors**, so the flattened
    // pair is not empty and a stage that wrote nothing into it is visible.
    const first: [1]Row = .{rich[0]};
    const with_succs: [1]Row = .{rich[3]};
    _ = try cols.splice(gpa, 0, &first, .unicode_code_point, table.asTable());
    _ = try cols.splice(gpa, 1, &with_succs, .unicode_code_point, table.asTable());
    try checkLengths(&cols, gpa, 2, 2);

    const actors_before = try cols.succ_actor.encode(gpa);
    defer gpa.free(actors_before);
    const ctrs_before = try cols.succ_ctr.encode(gpa);
    defer gpa.free(ctrs_before);
    const incs_before = try cols.index.inc.encode(gpa);
    defer gpa.free(incs_before);

    // **One row, and no successors.** These are the three stages that carry
    // nothing: each is handed `del == 0` and a value list of no length,
    // which `stageSplice` answers with the no-op stage before it allocates
    // ([column.zig:4598-4607](../hexane/column.zig)) and whose `publish`
    // leaves the column alone ([column.zig:4532-4535](../hexane/column.zig)).
    // They are still called, and calling them is what the encodings below
    // measure.
    const plain: [1]Row = .{.{ .op_id = .{ .counter = 7, .actor = 0 } }};
    _ = try cols.splice(gpa, 2, &plain, .unicode_code_point, table.asTable());

    // **Nothing moved**, and the row count says the splice was not a no-op
    // over the set as a whole: three rows, two successors.
    try checkLengths(&cols, gpa, 3, 2);
    const actors_after = try cols.succ_actor.encode(gpa);
    defer gpa.free(actors_after);
    const ctrs_after = try cols.succ_ctr.encode(gpa);
    defer gpa.free(ctrs_after);
    const incs_after = try cols.index.inc.encode(gpa);
    defer gpa.free(incs_after);
    try testing.expectEqualSlices(u8, actors_before, actors_after);
    try testing.expectEqualSlices(u8, ctrs_before, ctrs_after);
    try testing.expectEqualSlices(u8, incs_before, incs_after);
}

test "a successor count that runs past the flattened pair is refused, and nothing moves" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();

    const first: [1]Row = .{.{ .op_id = .{ .counter = 1, .actor = 0 } }};
    const second: [1]Row = .{.{ .op_id = .{ .counter = 2, .actor = 0 } }};

    // **The control: the same two rows into a set whose own counts agree.**
    var clean = try Columns(Row).init(gpa);
    defer clean.deinit();
    _ = try clean.splice(gpa, 0, &first, .unicode_code_point, table.asTable());
    _ = try clean.splice(gpa, 1, &second, .unicode_code_point, table.asTable());
    try checkLengths(&clean, gpa, 2, 0);

    // **And here the counts disagree.** `succ_count` says row 0 has two
    // successors and the flattened pair has none, which is the one thing
    // `succLengthMismatch` names
    // ([op_iter.zig:1920-1937](op_iter.zig)). Nothing that built the set can
    // produce it, so the set is written directly.
    var broken = try Columns(Row).init(gpa);
    defer broken.deinit();
    _ = try broken.splice(gpa, 0, &first, .unicode_code_point, table.asTable());
    // **One row in, one row out** — `del == 1`, not `del == 0`. A splice that
    // deletes nothing *inserts* the `2` in front of the `0` row the splice
    // above wrote, leaving two count rows (`{2, 0}`) against one op row. That
    // is a second, unrelated malformation — a row-length mismatch, which
    // `rowLengthMismatch` names — and `broken.len()` cannot see it, because
    // that is `id_actor.len()` ([opset/columns.zig:1556](columns.zig)). The
    // count the case is about is row 0's own, so row 0 is replaced.
    try broken.succ_count.splice(gpa, 0, 1, &.{2});
    try testing.expectEqual(@as(usize, 1), broken.len());
    try testing.expectEqual(@as(usize, 0), broken.subLen());

    // **The refusal is the successor triple's, and rows that bring no
    // successors are why**: `succ_pos` is 2 and `succ_actor` holds nothing,
    // so `stageSplice` refuses the position
    // ([column.zig:4596](../hexane/column.zig)).
    //
    // **This is the witness that `removeOps`'s `if (succ_del > 0)` guard was
    // not copied here.** With that guard this splice would answer `1` and
    // accept a set no walk can read; upstream guards the removal and not the
    // insertion (`columns.rs:400-408` against `:457-470`), and the guard is
    // what makes the removal's asymmetry upstream's rather than the port's.
    try testing.expectError(
        error.InvalidValue,
        broken.splice(gpa, 1, &second, .unicode_code_point, table.asTable()),
    );

    // **And the refusal moved nothing**, which is the staging's own claim:
    // the row count, the successor total and the counts themselves are the
    // ones the set held before the call.
    try testing.expectEqual(@as(usize, 1), broken.len());
    try testing.expectEqual(@as(usize, 0), broken.subLen());
    const counts = try valuesOf(CountColumn, &broken.succ_count, gpa);
    defer gpa.free(counts);
    try testing.expectEqualSlices(u32, &.{2}, counts);
}

test "a splice of nothing, and a splice of only deletes, write no row" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();

    // **All twenty-one stages run on an empty splice and none of them has
    // anything to do** — `del == 0` and a value list of no length is the no-op
    // `stageSplice` was given an answer for
    // ([column.zig:4598-4607](../hexane/column.zig)). Zero rows, and every
    // column exactly as long as it was.
    // `&.{}` is the spelling an empty slice argument takes here
    // ([op_set.zig:8473](op_set.zig)), where the same call is made.
    try testing.expectEqual(@as(usize, 0), try cols.splice(gpa, 0, &.{}, .unicode_code_point, table.asTable()));
    try checkLengths(&cols, gpa, 0, 0);

    // **A delete is not a row** (`columns.rs:423`), so a splice of nothing but
    // deletes writes nothing either. This is the one that pays the filter and
    // still has nothing left to stage.
    const only_deletes: [2]Row = .{
        .{ .op_id = .{ .counter = 1, .actor = 0 }, .act = .delete },
        .{ .op_id = .{ .counter = 2, .actor = 0 }, .act = .delete },
    };
    try testing.expectEqual(@as(usize, 0), try cols.splice(gpa, 0, &only_deletes, .unicode_code_point, table.asTable()));
    try checkLengths(&cols, gpa, 0, 0);
}

test "a splice and the matching removal leave every column byte-identical" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());

    var before = try cols.exportColumns(gpa, table.asTable());
    defer before.deinit(gpa);
    const before_specs = try specsOf(before.cols, gpa);
    defer gpa.free(before_specs);
    const before_data = try gpa.dupe(u8, before.data);
    defer gpa.free(before_data);
    const before_index = cols.index.lengths();

    const at: [3]Row = .{
        .{
            .op_id = .{ .counter = 5, .actor = 0 },
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .mark,
            .anchor = .fromStr("strong"),
            .does_expand = true,
            .is_top = false,
            .is_visible = false,
            .units = 2,
            .name = "strong",
            .mark = markStartWord(.{ .counter = 5, .actor = 0 }),
            .v = .{ .str = "ab" },
        },
        .{
            .op_id = .{ .counter = 6, .actor = 1 },
            .parent = .{ .counter = 2, .actor = 0 },
            .act = .set,
            .anchor = seqAt(1, 0),
            .does_insert = true,
            .units = 3,
            .succs = &.{.{ .counter = 1, .actor = 1 }},
            .incs = &.{@as(?i64, 7)},
        },
        .{
            .op_id = .{ .counter = 7, .actor = 0 },
            .act = .delete,
        },
    };
    // Inserted in the middle, so both prefix offsets are non-zero and neither
    // is zero.
    const written = try cols.splice(gpa, 2, &at, .unicode_code_point, table.asTable());
    try testing.expectEqual(2, written);
    try checkLengths(&cols, gpa, 6, 3);

    // The mark index is a column *and* a cache (`mark_index.rs:213-217`): the
    // mark that went in at 2 brought its data with it, beside the one `rich`
    // already had, and the two are told apart by their begin.
    const rich_mark = OpId{ .counter = 3, .actor = 1 };
    const added_mark = OpId{ .counter = 5, .actor = 0 };
    try testing.expect(cols.index.mark.markData(rich_mark) != null);
    try testing.expect(cols.index.mark.markData(added_mark) != null);

    const removed = try cols.removeOps(gpa, 2, &at);
    try testing.expectEqual(2, removed);
    try checkLengths(&cols, gpa, 4, 2);

    // Every column is back to the bytes it had, and so is the whole block.
    var after = try cols.exportColumns(gpa, table.asTable());
    defer after.deinit(gpa);
    const after_specs = try specsOf(after.cols, gpa);
    defer gpa.free(after_specs);
    try testing.expectEqualSlices(ColumnSpec, before_specs, after_specs);
    try testing.expectEqualSlices(u8, before_data, after.data);
    // And the cache is back to what it was: `undo` forgets the data of the
    // marks that began in the rows it removed and keeps the rest
    // (`mark_index.rs:291-299`).
    try testing.expect(cols.index.mark.markData(added_mark) == null);
    try testing.expect(cols.index.mark.markData(rich_mark) != null);
    // And the index columns are back to their lengths, including the mark
    // index, which `removeOps` undoes at the same position and width.
    try testing.expectEqual(before_index.text, cols.index.lengths().text);
    try testing.expectEqual(before_index.top, cols.index.lengths().top);
    try testing.expectEqual(before_index.visible, cols.index.lengths().visible);
    try testing.expectEqual(before_index.mark, cols.index.lengths().mark);
    const counts = try valuesOf(CountColumn, &cols.succ_count, gpa);
    defer gpa.free(counts);
    // `rich`'s two successors belong to its last row, and the rows that were
    // inserted at 2 and taken out again were never before it.
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 2 }, counts);
}

test "a sequence anchor that is not the head encodes to the bytes it always did" {
    // The bytes below are the ones this op set produced *before* `ElemId` was
    // a type, captured from this very fixture on the tree where `ElemId` was
    // still an alias of `OpId`. Every key shape that is not the head
    // has to keep producing them: the wire is the compatibility contract, and
    // a key column that moved by a byte renumbers every change hash in the
    // document.
    //
    // This is what makes the type change safe. The one shape that is *not*
    // pinned here is the head, because its encoding is the one thing the
    // change is meant to move — [`head_anchored`] and the test below pin what
    // it moves to.
    const gpa = testing.allocator;
    const hex = "00010800000103017b02030102030004" ++
        "02000001020000047e040100017e7e03" ++
        "7c016d016c0174016b00027f016b0002" ++
        "0600030106017f7b0201097d00020405" ++
        "017f07030002147f2602147f00070368" ++
        "69090406007f0102007f007f04080100" ++
        "087f0162";
    const want = try err.hexFrom(gpa, hex);
    defer gpa.free(want);
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    const written = try cols.splice(gpa, 0, &three_kinds, .unicode_code_point, table.asTable());
    try testing.expectEqual(@as(usize, 9), written);
    try checkLengths(&cols, gpa, 9, 1);

    // The two key columns say what the fixture says they say: a map key is
    // absent from both, and a sequence anchor is present in both with the
    // element's own actor and counter (`columns.rs:429-435`).
    const key_actors = try valuesOf(ActorOptColumn, &cols.key_actor, gpa);
    defer gpa.free(key_actors);
    try testing.expectEqualSlices(?ActorIdx, &.{ null, null, null, null, 0, 0, null, 0, 0 }, key_actors);
    const key_ctrs = try valuesOf(OptCounterColumn, &cols.key_ctr, gpa);
    defer gpa.free(key_ctrs);
    try testing.expectEqualSlices(?u32, &.{ null, null, null, null, 4, 5, null, 3, 6 }, key_ctrs);

    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    try checkContiguous(exported.cols);
    try testing.expectEqual(@as(usize, 16), exported.cols.columns.len);
    try testing.expectEqualSlices(u8, want, exported.data);
}

test "a head anchor writes an absent actor against a zero counter" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    const written = try cols.splice(gpa, 0, &head_anchored, .unicode_code_point, table.asTable());
    try testing.expectEqual(@as(usize, 9), written);
    try checkLengths(&cols, gpa, 9, 1);

    // Row 4 is the insert at the front of the list. Its actor column is
    // **absent**, which is `KeyRef::actor` forwarding `ElemId::actor` for the
    // head (`op_set2/types.rs:616-621`, `types.rs:668-674`), and its counter
    // column is a **zero**, which is `KeyRef::icounter` forwarding
    // `ElemId::icounter` without a head case (`op_set2/types.rs:623-628`,
    // `types.rs:663-666`).
    //
    // The pair is what the reader needs to call this a head rather than a map
    // key: `(absent, absent)` is a map key (`op_set2/op_set/op_iter.rs:240-241`)
    // and `(Some(0), absent)` is the head (`:242`).
    const key_actors = try valuesOf(ActorOptColumn, &cols.key_actor, gpa);
    defer gpa.free(key_actors);
    try testing.expectEqualSlices(?ActorIdx, &.{ null, null, null, null, null, 0, null, 0, 0 }, key_actors);
    const key_ctrs = try valuesOf(OptCounterColumn, &cols.key_ctr, gpa);
    defer gpa.free(key_ctrs);
    try testing.expectEqualSlices(?u32, &.{ null, null, null, null, 0, 5, null, 3, 6 }, key_ctrs);

    // The reader that tells this pair apart from a map key lives in
    // `op_iter.zig`, which imports this file; the round trip through it is
    // that file's test, "an anchor read back from the two key columns is the
    // head it was written as".
}

test "a load that declares the wrong number of rows is refused" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();

    var two = try Columns(Row).init(gpa);
    defer two.deinit();
    _ = try two.splice(gpa, 0, &.{ rich[0], rich[1] }, .unicode_code_point, table.asTable());
    var two_exported = try two.exportColumns(gpa, table.asTable());
    defer two_exported.deinit(gpa);

    var one = try Columns(Row).init(gpa);
    defer one.deinit();
    _ = try one.splice(gpa, 0, &.{rich[0]}, .unicode_code_point, table.asTable());
    var one_exported = try one.exportColumns(gpa, table.asTable());
    defer one_exported.deinit(gpa);

    // A document whose `id_actor` says one row and whose `id_ctr` says two:
    // the length the op set takes everything from disagrees with a column it
    // holds to that length, and the load refuses rather than padding or
    // truncating (columns.rs:258-259, and the fill rule at column.zig:2700).
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var descs: std.ArrayList(ColumnDesc) = .empty;
    defer descs.deinit(gpa);
    for (two_exported.cols.columns) |col| {
        const bytes = if (col.spec.eql(ids.id_actor_col_spec))
            try one_exported.cols.bytesFor(col.spec)
        else
            try two_exported.cols.bytesFor(col.spec);
        const n = bytes orelse continue;
        const start = data.items.len;
        try data.appendSlice(gpa, n);
        try descs.append(gpa, .init(col.spec, data.items.len - start));
    }
    const bad = try RawColumns.init(gpa, descs.items, data.items);
    defer bad.deinit(gpa);
    try testing.expectError(error.InvalidValue, Columns(Row).load(gpa, bad, table.asTable()));
}

test "validate keeps the sixteen op columns and drops the rest" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());
    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);

    // The predecessor group is not an op set column, and upstream's filter
    // drops a column it does not recognise without complaining
    // (columns.rs:228-247).
    const predecessor = ColumnSpec.make(7, .group, false);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var descs: std.ArrayList(ColumnDesc) = .empty;
    defer descs.deinit(gpa);
    // The block is rebuilt with the predecessor group's two bytes in the
    // place its specification sorts — 112, between the value column and the
    // successor group — so the result is a set a document could have carried
    // rather than a list with a hole in it.
    var inserted = false;
    for (exported.cols.columns) |col| {
        if (!inserted and predecessor.lessThan(col.spec)) {
            const at = data.items.len;
            try data.appendSlice(gpa, &.{ 1, 1 });
            try descs.append(gpa, .init(predecessor, data.items.len - at));
            inserted = true;
        }
        const n = (try exported.cols.bytesFor(col.spec)).?;
        const at = data.items.len;
        try data.appendSlice(gpa, n);
        try descs.append(gpa, .init(col.spec, data.items.len - at));
    }
    const with_extra = try RawColumns.init(gpa, descs.items, data.items);
    defer with_extra.deinit(gpa);
    try testing.expectEqual(exported.cols.len() + 1, with_extra.len());

    const kept = try Columns(Row).validate(gpa, with_extra);
    defer kept.deinit(gpa);
    try testing.expectEqual(exported.cols.len(), kept.len());
    for (kept.columns) |col| try testing.expect(isOpSpec(col.spec));
    // The ranges are the input's, not recomputed from zero: dropping the
    // predecessor group leaves a hole in the set and the columns behind it
    // still point at their own bytes.
    var want: usize = 0;
    for (with_extra.columns) |col| {
        if (!isOpSpec(col.spec)) continue;
        try testing.expect(col.spec.eql(kept.columns[want].spec));
        try testing.expect(col.range.eql(kept.columns[want].range));
        want += 1;
    }
    try testing.expectEqual(kept.len(), want);
}

test "validate refuses a duplicate, an out-of-order set and a range past the block" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();

    // The same id and encoding twice (columns.rs:203-210, upstream).
    {
        const descs = [_]ColumnDesc{
            .init(ids.id_actor_col_spec, 1),
            .init(ids.id_actor_col_spec, 1),
        };
        const data = [_]u8{ 1, 1 };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.DuplicateColumn, Columns(Row).validate(gpa, cols));
    }
    // Descending by normalized specification, which `RawColumns.parse` and
    // so a document can never carry (raw_column.rs:248-253).
    {
        const descs = [_]ColumnDesc{
            .init(ids.id_counter_col_spec, 1),
            .init(ids.id_actor_col_spec, 1),
        };
        const data = [_]u8{ 1, 1 };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.InvalidColumnSpec, Columns(Row).validate(gpa, cols));
    }
    // A range that runs past the data block, which is what a hostile length
    // in the metadata produces.
    {
        const descs = [_]ColumnDesc{.init(ids.id_actor_col_spec, 5)};
        const data = [_]u8{ 1, 1 };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.ColumnOutOfBounds, Columns(Row).validate(gpa, cols));
    }
    // More columns than the block has bytes, which no writer can produce.
    {
        const descs = [_]ColumnDesc{
            .init(ids.id_actor_col_spec, 1),
            .init(ids.id_counter_col_spec, 1),
            .init(ids.obj_id_actor_col_spec, 1),
        };
        const data = [_]u8{1};
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.Overflow, Columns(Row).validate(gpa, cols));
    }
    _ = &table;
}

test "the chunk parser and the op set validator refuse a repeated specification alike" {
    const gpa = testing.allocator;
    // Two doors onto one set of bytes, and they have to agree. The chunk
    // parser validates as it decodes (`document_chunk.zig:465`, through
    // `validateSets` at `:571-591`) and [`Columns.validate`] is the op set's
    // own door (`columns.rs:219-249`); both reach
    // [`colspec.RawColumns.validate`]. A parser that reads a block one way and
    // a validator that checks it another is the differential a repeat makes
    // possible, because the block then names two byte ranges for one column
    // and each door picks its own.
    const spec = ColumnSpec.make(3, .boolean, false); // 0x34
    const descs = [_]ColumnDesc{ .init(spec, 1), .init(spec, 1) };
    const data = [_]u8{ 1, 1 };
    const cols = try RawColumns.init(gpa, &descs, &data);
    defer cols.deinit(gpa);
    try testing.expectError(error.DuplicateColumn, Columns(Row).validate(gpa, cols));

    // The same set inside a real framed chunk: no actors, no heads, no change
    // columns, and an op block that names column id 3 twice with one byte each.
    const body = [_]u8{
        0x00, 0x00, // no actors, no heads
        0x00, // no change columns
        0x02, 0x34, 0x01, 0x34, 0x01, // id 3 boolean, and itself again
        0x01, 0x01, // the op data
    };
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunkmod.writeChunk(&framed, gpa, .document, &body);
    try testing.expectError(
        error.DuplicateColumn,
        docchunk.parseFramedChunk(try chunkmod.parseChunk(framed.items), gpa),
    );
}

test "a specification block cut short, and a length that runs past the chunk, are both refused" {
    const gpa = testing.allocator;
    // The totality of the reader the validator sits behind: a column
    // specification is a uleb128 and a length is a uleb128, both counted off
    // the wire, and neither may be believed before it is bounded
    // (`document_chunk.zig:418-436`).

    // A specification table that stops in the middle of a pair. The count is
    // checked against the bytes that are left before any pair is read
    // (`parse.zig:234`, at two bytes per pair), so the first column's
    // specification is written as a two-byte uleb128: that leaves four bytes
    // for two columns, which passes the count, and one byte short of the pair
    // the reader actually needs. A uleb128 that runs off the end of its input
    // is `error.InvalidLeb128` and not a short read — and that is the
    // distinction this pins: the count bound and the value read are two
    // different checks, and only the second one is reached here.
    const cut_spec = [_]u8{
        0x00, 0x00, // no actors, no heads
        0x00, // no change columns
        0x02, // two op columns
        0xb4, 0x00, 0x01, // column 0x34 as a two-byte specification, one byte
        0x34, // column 2's specification, and nothing for its length
    };
    {
        var framed: std.ArrayList(u8) = .empty;
        defer framed.deinit(gpa);
        try chunkmod.writeChunk(&framed, gpa, .document, &cut_spec);
        try testing.expectError(
            error.InvalidLeb128,
            docchunk.parseFramedChunk(try chunkmod.parseChunk(framed.items), gpa),
        );
    }

    // A length of 2^40 over a body with three bytes behind it. The sums
    // saturate as upstream's do (`raw_column.rs:235-239`), so the refusal is
    // the comparison against what is left, not an overflow and not a
    // reservation of a terabyte.
    const overlong_len = [_]u8{
        0x00, 0x00, // no actors, no heads
        0x00, // no change columns
        0x01, 0x34, // one op column, id 3 boolean
        0x80, 0x80, 0x80, 0x80, 0x80, 0x08, // 2^40 bytes
        0x01, 0x02, 0x03, // three bytes of data
    };
    {
        var framed: std.ArrayList(u8) = .empty;
        defer framed.deinit(gpa);
        try chunkmod.writeChunk(&framed, gpa, .document, &overlong_len);
        try testing.expectError(
            error.LengthExceedsInput,
            docchunk.parseFramedChunk(try chunkmod.parseChunk(framed.items), gpa),
        );
    }
}

test "a specification repeated across the deflate bit is one repeat, and an empty one is no column" {
    const gpa = testing.allocator;
    // `ColumnSpec::eql` masks the DEFLATE bit (`column_spec.zig:226-228`), so
    // one column named compressed and again uncompressed names one column
    // twice. That is the right comparison: upstream's `normalize()` masks the
    // same bit (`column_specification.rs:84-86`), which is what its dead guard
    // compared and what its live order check compares (`raw_column.rs:292`). A
    // document that carried both spellings of one column would otherwise be
    // read twice, from two different ranges.
    const plain = ColumnSpec.make(3, .boolean, false);
    const deflated = ColumnSpec.make(3, .boolean, true);
    const descs = [_]ColumnDesc{ .init(deflated, 1), .init(plain, 1) };
    const data = [_]u8{ 1, 1 };
    const cols = try RawColumns.init(gpa, &descs, &data);
    defer cols.deinit(gpa);
    try testing.expectError(error.DuplicateColumn, Columns(Row).validate(gpa, cols));

    // The other end of the same question, and the half that keeps the check
    // from becoming a blanket refusal. A repeat that names **no bytes** is not
    // a second column: `RawColumns.init` drops a zero-length entry exactly as
    // upstream's `FromIterator` does (`raw_column.rs:183`, `:187-205`), so the
    // set holds one column. The reference loads such a document — it was run
    // against every one of the twenty zero-length variants and loaded all of
    // them — and this must agree.
    const with_empty = [_]ColumnDesc{ .init(plain, 1), .init(plain, 0) };
    const one = [_]u8{1};
    const kept = try RawColumns.init(gpa, &with_empty, &one);
    defer kept.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), kept.len());
    const survivors = try Columns(Row).validate(gpa, kept);
    defer survivors.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), survivors.len());
}

test "a declared length that saturates, and a block with no bytes behind it, are refused" {
    const gpa = testing.allocator;
    // A length off the wire is a `usize` and can be any value
    // (`raw_column.rs:232-247`), so the offsets accumulate with a saturating
    // add: a hostile length lands as the largest representable offset instead
    // of wrapping round into a small one that would then pass the bounds
    // check. Nothing is allocated from the length — the set indexes a `data`
    // block the reader has already bounded by the chunk — so the refusal is a
    // bounds check rather than a failed reservation.
    {
        const descs = [_]ColumnDesc{.init(ids.id_actor_col_spec, std.math.maxInt(usize))};
        const cols = try RawColumns.init(gpa, &descs, &.{ 1, 1 });
        defer cols.deinit(gpa);
        try testing.expectError(error.ColumnOutOfBounds, Columns(Row).validate(gpa, cols));
    }
    // The block the columns index is gone: one column, no data at all. The
    // cheapest check runs first — an empty column is dropped, so every column
    // of a set occupies at least one byte and a larger set is not one this
    // format could have written.
    {
        const descs = [_]ColumnDesc{.init(ids.id_actor_col_spec, 1)};
        const cols = try RawColumns.init(gpa, &descs, &.{});
        defer cols.deinit(gpa);
        try testing.expectError(error.Overflow, Columns(Row).validate(gpa, cols));
    }
}

test "a document naming one specification in both column sets loads and materializes" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());
    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);

    // **The half that keeps the repeat check from being a blanket refusal.**
    // The two column sets of a document chunk are independent, and they name
    // the same column ids: the 446-byte document the reference wrote for
    // `test/golden/doc.jsonl` carries specifications 0x01, 0x13, 0x23 and 0x56
    // in **both** its change block and its op block. So one specification
    // recurring is ordinary, and a validator that carried its "already seen"
    // set across the two would refuse every document automerge has ever
    // written. Here both sets are the same sixteen columns over the same
    // bytes, which is the strongest form the property can take.
    const body = try docchunk.encodeBody(gpa, docchunk.DocumentBlock.init(
        &.{},
        &.{},
        exported.cols,
        exported.cols,
        &.{},
    ));
    defer gpa.free(body);
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(gpa);
    try chunkmod.writeChunk(&framed, gpa, .document, body);

    var doc = try docchunk.parseFramedChunk(try chunkmod.parseChunk(framed.items), gpa);
    defer doc.deinit(gpa);
    try testing.expectEqual(exported.cols.len(), doc.changeColumns().len());
    try testing.expectEqual(exported.cols.len(), doc.opColumns().len());

    // And the op set materializes out of it: every one of the sixteen columns
    // back, by content, which is what "loads" has to mean for a document.
    const kept = try Columns(Row).validate(gpa, doc.opColumns());
    defer kept.deinit(gpa);
    var loaded = try Columns(Row).load(gpa, kept, table.asTable());
    defer loaded.deinit();
    try testing.expectEqual(rich.len, loaded.len());
    try expectSameColumns(gpa, &cols, &loaded);
}

test "validate refuses ranges that do not cover the data block" {
    const gpa = testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4 };
    // A hole between the two columns: the second starts at 3, not 2.
    {
        var gapped = [_]RawColumn{
            .init(ids.id_actor_col_spec, .init(0, 2)),
            .init(ids.id_counter_col_spec, .init(3, 4)),
        };
        const cols: RawColumns = .{ .columns = gapped[0..], .data = &data };
        try testing.expectError(error.ColumnOutOfBounds, Columns(Row).validate(gpa, cols));
    }
    // Two bytes of the block that no column claims.
    {
        var short = [_]RawColumn{
            .init(ids.id_actor_col_spec, .init(0, 2)),
            .init(ids.id_counter_col_spec, .init(2, 3)),
        };
        const cols: RawColumns = .{ .columns = short[0..], .data = &data };
        try testing.expectError(error.TrailingBytes, Columns(Row).validate(gpa, cols));
    }
}

test "validate refuses a value payload that belongs to no value column" {
    const gpa = testing.allocator;
    // Upstream parses the layout over the *whole* set before the filter
    // (`op_set2/columns.rs:222-247`), so a payload with no metadata word in
    // front of it is refused by the layout and is not rescued by being an op
    // column: `LoneRawValueColumn` (`storage/columns.rs:216`).
    {
        const descs = [_]ColumnDesc{.init(ids.value_col_spec, 1)};
        const data = [_]u8{1};
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.MissingColumn, Columns(Row).validate(gpa, cols));
    }
    // A payload on another id than the metadata word it follows, which is
    // upstream's `MismatchingValueMetadataId` (`storage/columns.rs:246`).
    {
        const descs = [_]ColumnDesc{
            .init(ids.value_meta_col_spec, 1),
            .init(ColumnSpec.make(6, .value, false), 1),
        };
        const data = [_]u8{ 1, 1 };
        const cols = try RawColumns.init(gpa, &descs, &data);
        defer cols.deinit(gpa);
        try testing.expectError(error.InvalidColumnSpec, Columns(Row).validate(gpa, cols));
    }
}

test "validate accepts a complete value column and an incomplete key" {
    const gpa = testing.allocator;
    // The half that matters: the layout parser is not a completeness rule. A
    // metadata word whose payload never comes is finished with an empty range
    // (`storage/columns.rs:253`), and `key_actor`, `key_ctr` and `key_str`
    // are suppressed one by one, each on its own, when every row of that
    // column is null (`op_set2/columns.rs:152-156`), so the string half of a
    // map key is written on its own. The reference loads both and so must
    // this.
    const three = [_]u8{ 1, 1, 1 };
    const one = [_]u8{1};
    {
        // Both halves of the value column, which is what a value column is
        // (`storage/columns.rs:57-60`).
        const descs = [_]ColumnDesc{
            .init(ids.value_meta_col_spec, 1),
            .init(ids.value_col_spec, 2),
        };
        const cols = try RawColumns.init(gpa, &descs, &three);
        defer cols.deinit(gpa);
        const kept = try Columns(Row).validate(gpa, cols);
        defer kept.deinit(gpa);
        try testing.expectEqual(@as(usize, 2), kept.len());
    }
    {
        const descs = [_]ColumnDesc{.init(ids.key_str_col_spec, 1)};
        const cols = try RawColumns.init(gpa, &descs, &one);
        defer cols.deinit(gpa);
        const kept = try Columns(Row).validate(gpa, cols);
        defer kept.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), kept.len());
    }
    {
        // A metadata word with no payload behind it, the other half of the
        // same question.
        const descs = [_]ColumnDesc{.init(ids.value_meta_col_spec, 1)};
        const cols = try RawColumns.init(gpa, &descs, &one);
        defer cols.deinit(gpa);
        const kept = try Columns(Row).validate(gpa, cols);
        defer kept.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), kept.len());
    }
}

test "a mark begin and a mark end fill the mark index and its cache" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();

    // A mark is two back-to-back inserts: the begin names the mark and puts
    // the data on its span, the end names the *begin* and nothing else
    // (`op_set2/op.rs:194-200`). A mark row with no name is the end, which is
    // the same fact `markIndex` decides it by (`op.zig:748-757`).
    const begin = OpId{ .counter = 3, .actor = 1 };
    const rows = [_]Row{
        .{
            .op_id = .{ .counter = 1, .actor = 0 },
            .act = .make_text,
            .anchor = .fromStr("text"),
        },
        .{
            .op_id = begin,
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .mark,
            .anchor = seqAt(1, 0),
            .does_expand = true,
            .is_visible = false,
            .is_top = false,
            .name = "em",
            .v = .{ .uint = 3 },
            .mark = markStartWord(begin),
        },
        .{
            .op_id = .{ .counter = 4, .actor = 1 },
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .mark,
            .anchor = seqAt(1, 0),
            .is_visible = false,
            .is_top = false,
            .mark = markEndWord(begin),
        },
        .{
            .op_id = .{ .counter = 5, .actor = 0 },
            .parent = .{ .counter = 1, .actor = 0 },
            .act = .set,
            .anchor = seqAt(1, 0),
            .v = .{ .str = "ab" },
        },
    };
    const written = try cols.splice(gpa, 0, &rows, .unicode_code_point, table.asTable());
    try testing.expectEqual(@as(usize, 4), written);
    try checkLengths(&cols, gpa, 4, 0);

    // The rows are the two words the ops carried, decoded, and null for the
    // rows that are not part of a mark at all (`mark_index.rs:277-289`).
    const marks = try markRows(&cols.index.mark, gpa);
    defer gpa.free(marks);
    try testing.expectEqual(@as(usize, 4), marks.len);
    try testing.expect(marks[0] == null);
    try testing.expect(marks[1].?.eql(.{ .start = begin }));
    try testing.expect(marks[2].?.eql(.{ .end = begin }));
    try testing.expect(marks[3] == null);

    // The mark is open from the begin's own row, which is the row a reader
    // asks about at index 1, and closed from the end's row on
    // (`mark_index.rs:315-331`).
    var open = try cols.index.mark.marksAt(gpa, 1, null);
    defer open.deinit();
    try testing.expect(open.next().?.eql(begin));
    try testing.expect(open.next() == null);
    var shut = try cols.index.mark.marksAt(gpa, 2, null);
    defer shut.deinit();
    try testing.expect(shut.next() == null);

    // The cache holds the begin's data under the name the document's own
    // string table owns rather than the one the op carried, and holds
    // nothing for the end (`mark_index.rs:216`, `:267-269`).
    try testing.expect(cols.index.mark.hasAnyMarks());
    const data = cols.index.mark.markData(begin) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("em", data.name);
    switch (data.value) {
        .uint => |n| try testing.expectEqual(@as(u64, 3), n),
        else => return error.TestUnexpectedResult,
    }
    const end_id = OpId{ .counter = 4, .actor = 1 };
    try testing.expect(cols.index.mark.markData(end_id) == null);
    try expectCacheAgreesWithRows(&cols.index.mark, gpa);

    // Renumbering the actor table moves the rows' ids *and* the cache's keys,
    // and the op set makes the two calls in that order
    // (`op_set2/op_set.rs:1407-1409` beside `columns.rs:342-348`).
    // `MarkIndexColumn::rewrite_with_new_actor` does both halves
    // (`mark_index.rs:271-278`), which is why a mark whose row moved still
    // answers for its data afterwards.
    try cols.rewriteWithNewActor(gpa, 0);
    try cols.index.mark.remapValues(0);
    try checkLengths(&cols, gpa, 4, 0);
    const lifted = begin.withNewActor(0);
    try testing.expect(!lifted.eql(begin));
    const after = try markRows(&cols.index.mark, gpa);
    defer gpa.free(after);
    try testing.expectEqual(@as(usize, 4), after.len);
    try testing.expect(after[1].?.eql(.{ .start = lifted }));
    try testing.expect(after[2].?.eql(.{ .end = lifted }));
    // The old key is gone and the new one answers, and the two halves still
    // name the same marks: the rows moved and the cache followed.
    try testing.expect(cols.index.mark.markData(begin) == null);
    const moved = cols.index.mark.markData(lifted) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("em", moved.name);
    try expectCacheAgreesWithRows(&cols.index.mark, gpa);
}

test "the mark index is derived state, so a load leaves it empty and a re-splice builds it" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());

    var exported = try cols.exportColumns(gpa, table.asTable());
    defer exported.deinit(gpa);
    var loaded = try Columns(Row).load(gpa, exported.cols, table.asTable());
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 4), loaded.len());
    try testing.expectEqual(@as(usize, 2), loaded.subLen());
    try expectSameColumns(gpa, &cols, &loaded);

    // The index columns are not a stored format (`columns.rs:135-170`,
    // `:252-330`, `Indexes::default` at `:314`): the exporter has no arm for
    // the mark index and a load leaves all five empty, because every one of
    // them is state the sixteen data columns already determine.
    const idx = loaded.index.lengths();
    try testing.expectEqual([5]usize{ 0, 0, 0, 0, 0 }, .{
        idx.text, idx.top, idx.visible, idx.inc, idx.mark,
    });
    try testing.expect(!loaded.index.mark.hasAnyMarks());
    // What the round trip does carry is the mark *name*, and it is the anchor
    // a rebuild resolves the cache's names out of, so the id has to name the
    // same bytes on the far side.
    const names = try valuesOf(UintOptColumn, &loaded.mark_name, gpa);
    defer gpa.free(names);
    try testing.expectEqualStrings("em", internedName(names[2], table.asTable()).?);

    // So a re-splice rebuilds the index over the same interned name, with no
    // byte of the document involved, and the document it writes is the one it
    // read: the mark index contributes nothing to the wire in either state.
    var again = try Columns(Row).init(gpa);
    defer again.deinit();
    _ = try again.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());
    try checkLengths(&again, gpa, 4, 2);
    try testing.expect(again.index.mark.hasAnyMarks());
    try expectCacheAgreesWithRows(&again.index.mark, gpa);
    const rebuilt = try markRows(&again.index.mark, gpa);
    defer gpa.free(rebuilt);
    try testing.expectEqual(@as(usize, 4), rebuilt.len);
    try testing.expect(rebuilt[2].?.eql(.{ .start = OpId{ .counter = 3, .actor = 1 } }));
    const data = again.index.mark.markData(.{ .counter = 3, .actor = 1 }).?;
    try testing.expectEqualStrings("em", data.name);
    var after = try again.exportColumns(gpa, table.asTable());
    defer after.deinit(gpa);
    try testing.expectEqualSlices(u8, exported.data, after.data);
    const after_specs = try specsOf(after.cols, gpa);
    defer gpa.free(after_specs);
    const exported_specs = try specsOf(exported.cols, gpa);
    defer gpa.free(exported_specs);
    try testing.expectEqualSlices(ColumnSpec, exported_specs, after_specs);
}

test "renumbering an actor moves every index that names it" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());

    const actorsOf = struct {
        fn go(c: *const Columns(Row), g: Allocator) ![]ActorIdx {
            const id = try valuesOf(ActorColumn, &c.id_actor, g);
            defer g.free(id);
            const succ = try valuesOf(ActorColumn, &c.succ_actor, g);
            defer g.free(succ);
            const obj = try valuesOf(ActorOptColumn, &c.obj_actor, g);
            defer g.free(obj);
            var out: std.ArrayList(ActorIdx) = .empty;
            errdefer out.deinit(g);
            for (id) |a| try out.append(g, a);
            for (succ) |a| try out.append(g, a);
            for (obj) |a| {
                if (a) |one| try out.append(g, one);
            }
            return out.toOwnedSlice(g);
        }
    }.go;

    const before = try actorsOf(&cols, gpa);
    defer gpa.free(before);
    // `rich` names actor 0 as the op of two rows and as the parent of three,
    // actor 1 as the op of two rows and as a successor, and actor 2 as the
    // other successor.
    try testing.expectEqualSlices(ActorIdx, &.{ 0, 0, 1, 1, 0, 1, 0, 0, 0 }, before);

    // A new actor at index 1 lifts every index at or above it
    // (columns.rs:344-347), and nothing names index 1 afterwards because the
    // new actor is the only thing that did.
    var raised_marks = try cols.index.mark.stageRemap(1, .up);
    defer raised_marks.deinit();
    try cols.rewriteWithNewActor(gpa, 1);
    raised_marks.publish(&cols.index.mark);
    const lifted = try actorsOf(&cols, gpa);
    defer gpa.free(lifted);
    try testing.expectEqualSlices(ActorIdx, &.{ 0, 0, 2, 2, 0, 2, 0, 0, 0 }, lifted);
    try checkLengths(&cols, gpa, 4, 2);

    // And removing it again puts every index back where it was.
    var lowered_marks = try cols.index.mark.stageRemap(1, .down);
    defer lowered_marks.deinit();
    try cols.rewriteWithoutActor(gpa, 1);
    lowered_marks.publish(&cols.index.mark);
    const lowered = try actorsOf(&cols, gpa);
    defer gpa.free(lowered);
    try testing.expectEqualSlices(ActorIdx, before, lowered);
    try checkLengths(&cols, gpa, 4, 2);
}

/// The four columns that hold an actor index, as decoded values, so a refused
/// [`Columns.remapActors`] can be asked whether it moved any of them.
const ActorColumns = struct {
    id_actor: []ActorIdx,
    succ_actor: []ActorIdx,
    obj_actor: []?ActorIdx,
    key_actor: []?ActorIdx,

    fn take(gpa: Allocator, c: *const Columns(Row)) !ActorColumns {
        const id_actor = try valuesOf(ActorColumn, &c.id_actor, gpa);
        errdefer gpa.free(id_actor);
        const succ_actor = try valuesOf(ActorColumn, &c.succ_actor, gpa);
        errdefer gpa.free(succ_actor);
        const obj_actor = try valuesOf(ActorOptColumn, &c.obj_actor, gpa);
        errdefer gpa.free(obj_actor);
        const key_actor = try valuesOf(ActorOptColumn, &c.key_actor, gpa);
        return .{
            .id_actor = id_actor,
            .succ_actor = succ_actor,
            .obj_actor = obj_actor,
            .key_actor = key_actor,
        };
    }

    fn deinit(self: ActorColumns, gpa: Allocator) void {
        gpa.free(self.id_actor);
        gpa.free(self.succ_actor);
        gpa.free(self.obj_actor);
        gpa.free(self.key_actor);
    }

    fn expectSame(self: ActorColumns, gpa: Allocator, c: *const Columns(Row)) !void {
        const id_actor = try valuesOf(ActorColumn, &c.id_actor, gpa);
        defer gpa.free(id_actor);
        try testing.expectEqualSlices(ActorIdx, self.id_actor, id_actor);
        const succ_actor = try valuesOf(ActorColumn, &c.succ_actor, gpa);
        defer gpa.free(succ_actor);
        try testing.expectEqualSlices(ActorIdx, self.succ_actor, succ_actor);
        const obj_actor = try valuesOf(ActorOptColumn, &c.obj_actor, gpa);
        defer gpa.free(obj_actor);
        try testing.expectEqualSlices(?ActorIdx, self.obj_actor, obj_actor);
        const key_actor = try valuesOf(ActorOptColumn, &c.key_actor, gpa);
        defer gpa.free(key_actor);
        try testing.expectEqualSlices(?ActorIdx, self.key_actor, key_actor);
    }
};

test "a refused actor renumbering leaves all four actor columns where they were" {
    // **The claim is all-or-nothing across the four columns.** A column
    // renumbered in place is atomic on its own ([`Column.remap`], which
    // releases the old bytes only once the new column has been built), so four
    // sequential calls are four atomic steps and not one atomic pass: a
    // refusal in the third used to return with `id_actor` and `succ_actor`
    // renumbered and `obj_actor` and `key_actor` not, so two columns of the
    // same row disagreed about that row's actor — the one state no reader in
    // this slice survives. It is also the claim a stage has to earn from the
    // other side: a refused `remapped` must leave its source exactly as it
    // found it, or the sources themselves are half-renumbered.
    const gpa = testing.allocator;
    var failing: testing.FailingAllocator = .init(gpa, .{});
    const agpa = failing.allocator();
    var table = Table.init(agpa);
    defer table.deinit();
    var cols = try Columns(Row).init(agpa);
    defer cols.deinit();
    _ = try cols.splice(agpa, 0, &rich, .unicode_code_point, table.asTable());

    const before = try ActorColumns.take(agpa, &cols);
    defer before.deinit(agpa);
    // The arm is a base captured once, so `skip` walks this pass's own
    // allocations one at a time however much a check took in between.
    const base = failing.alloc_index;
    var skip: usize = 0;
    var landed = false;
    while (skip <= 512) : (skip += 1) {
        failing.fail_index = base + skip;
        const outcome = cols.rewriteWithNewActor(agpa, 1);
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            landed = true;
            break;
        } else |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            try before.expectSame(agpa, &cols);
        }
    }
    try testing.expect(landed);
    // A pass that allocated nothing could not have been refused, so the sweep
    // would have proved nothing.
    try testing.expect(skip > 0);
    // And the pass that landed did the whole renumbering, which is the other
    // half: staging four columns must not have cost the move itself.
    const after = try ActorColumns.take(agpa, &cols);
    defer after.deinit(agpa);
    try testing.expectEqualSlices(ActorIdx, &.{ 0, 0, 2, 2 }, after.id_actor);
    try testing.expectEqualSlices(ActorIdx, &.{ 0, 2 }, after.succ_actor);
    try checkLengths(&cols, agpa, 4, 2);
}

test "removing an actor the op set still names is refused" {
    const gpa = testing.allocator;
    var table = Table.init(gpa);
    defer table.deinit();
    var cols = try Columns(Row).init(gpa);
    defer cols.deinit();
    _ = try cols.splice(gpa, 0, &rich, .unicode_code_point, table.asTable());

    // Upstream panics here (columns.rs:355-357); the port refuses, and
    // refuses before it has changed anything.
    try testing.expectError(error.InvalidValue, cols.rewriteWithoutActor(gpa, 1));
    try testing.expectError(error.InvalidValue, cols.rewriteWithoutActor(gpa, 0));
    var after = try cols.exportColumns(gpa, table.asTable());
    defer after.deinit(gpa);
    var reloaded = try Columns(Row).load(gpa, after.cols, table.asTable());
    defer reloaded.deinit();
    try expectSameColumns(gpa, &cols, &reloaded);
}

/// The generator upstream's fuzz cases use (`tests.rs`'s `xorshift`), kept
/// here so the seeded sweeps are the same sweep the reference walks.
fn xorshift(seed: *u64) u64 {
    var x = seed.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    seed.* = x;
    return x;
}

test "fuzz_prefix_column_bool" {
    // `tests.rs`. Two hundred trials of three hundred inserts and removals
    // against a `PrefixColumn<bool>`, with a plain array as the model and
    // the prefix total checked after **every** operation.
    //
    // **This is the one case that needs the op set's own boolean prefix
    // codec** (`BoolPrefixCodec`, `:150-204`), not the column layer's:
    // a boolean column's weight has to count its `true` rows, and the
    // column layer's codecs are integer-valued, so there was no
    // `Column(bool, Prefix(…))` to run this over before this codec
    // existed. The wire is the boolean codec's, unchanged — what the
    // prefix rule adds is the index's aggregate (`prefix.rs:316-325`).
    const gpa = testing.allocator;
    var rng: u64 = 44444;
    for (0..200) |trial| {
        var col = try BoolPrefixColumn.init(gpa);
        defer col.deinit();
        var mirror: std.ArrayList(bool) = .empty;
        defer mirror.deinit(gpa);

        for (0..300) |i| {
            const len = mirror.items.len;
            const r = xorshift(&rng);
            if (len == 0 or r % 3 != 0) {
                const pos = if (len == 0) 0 else @as(usize, @intCast(xorshift(&rng))) % (len + 1);
                const val = xorshift(&rng) % 2 == 0;
                try col.splice(gpa, pos, 0, &[_]bool{val});
                try mirror.insert(gpa, pos, val);
            } else {
                const pos = @as(usize, @intCast(xorshift(&rng))) % len;
                try col.splice(gpa, pos, 1, &.{});
                _ = mirror.orderedRemove(pos);
            }

            var true_count: usize = 0;
            for (mirror.items) |v| true_count += @intFromBool(v);
            const total = try col.getPrefix(mirror.items.len);
            if (total != @as(i64, @intCast(true_count))) {
                std.debug.print("trial {d} op {d}: prefix {d}, model {d}\n", .{ trial, i, total, true_count });
                return error.TestUnexpectedResult;
            }
            // And every row still reads back as the model has it, which is
            // what says the splice landed where it was told to.
            for (mirror.items, 0..) |want, k| {
                if ((try col.get(k)).? != want) {
                    std.debug.print("trial {d} op {d}: row {d} differs\n", .{ trial, i, k });
                    return error.TestUnexpectedResult;
                }
            }
        }

        // Preserve the per-trial save/load/save assertion too
        // (`rust/hexane/src/tests.rs:4401-4405`).
        const saved = try col.encode(gpa);
        defer gpa.free(saved);
        var loaded = try BoolPrefixColumn.load(gpa, saved);
        defer loaded.deinit();
        const resaved = try loaded.encode(gpa);
        defer gpa.free(resaved);
        try testing.expectEqualSlices(u8, saved, resaved);
    }
}

test "next_run_never_yields_adjacent_equal_runs_at_default_config" {
    // **`tests.rs:4959-4989`** — the second arm of the upstream case, and the
    // one that needs a codec of *this* file's.
    //
    // Three hundred alternating booleans in a `PrefixColumn<bool>` are **three
    // hundred runs** against the default 64-run budget, so the column splits on
    // its own with no budget tuned to make it (`tests.rs:4963-4966`), and one
    // value is then deleted at — or just before — the first slab boundary, so
    // the edit leaves `false | false` across it (`tests.rs:4967-4970`).
    //
    // **The contract is that the run walk coalesces whatever the layout is**:
    // no two consecutive runs may carry equal values, and the walk covers all
    // 299 rows that are left. The first arm of the same upstream case — an
    // `Option<String>` column over the same edit — is transcribed in
    // `hexane/column.zig` under this same name, and **the boolean prefix column
    // could not go with it**: its weight is the count of `true` rows in front of
    // a slab (`columns.rs:28`, `prefix.rs:316-325`), which is the op set's
    // `insert` column and is [`BoolPrefixCodec`] above.
    //
    // **The prefix sums are checked as well, because on this codec the run's
    // value and the column's weight are two different questions.** A walk that
    // coalesced across the seam and dropped the seam's weight would answer the
    // values right and every `get_prefix` wrong, and a run walk on its own
    // would not see it.
    const gpa = testing.allocator;
    var vals: [300]bool = undefined;
    for (&vals, 0..) |*v, i| v.* = i % 2 == 0;

    var col = try BoolPrefixColumn.init(gpa);
    defer col.deinit();
    // Upstream's `PrefixColumn::new()` then one `splice(0, 0, vals)`, so the
    // three hundred values arrive as one edit rather than as three hundred.
    try col.splice(gpa, 0, 0, &vals);
    // The premise: without a cut there is no boundary to coalesce across, and
    // the walk below would pass for the wrong reason (`tests.rs:4966`).
    if (col.slabCount() <= 1) {
        std.debug.print("{d} alternating booleans at the default budget are {d} slab(s)\n", .{ vals.len, col.slabCount() });
        return error.TestUnexpectedResult;
    }
    const boundary = col.slabAt(0).?.len;

    // Upstream deletes the `true` at the boundary if there is one and the row
    // just before it otherwise (`tests.rs:4968-4970`) — either way the row that
    // goes is a `true`, and the two `false`s it leaves are the run the walk has
    // to coalesce.
    const at_boundary = if ((try col.get(boundary))) |v| v else false;
    const del = if (at_boundary) boundary else boundary - 1;
    try col.splice(gpa, del, 1, &.{});
    // The edit must not have folded the column back into one slab
    // (`tests.rs:4971-4974`).
    if (col.slabCount() <= 1) {
        std.debug.print("the delete at {d} folded the column back into {d} slab(s)\n", .{ del, col.slabCount() });
        return error.TestUnexpectedResult;
    }

    // The model, built from the drawn values rather than fed in: the same three
    // hundred with row `del` gone.
    var want: [299]bool = undefined;
    var k: usize = 0;
    for (vals, 0..) |v, i| {
        if (i == del) continue;
        want[k] = v;
        k += 1;
    }

    // **The walk.** `PrefixIter.nextRun` is upstream's `next_run` over the
    // prefix cursor (`prefix.rs:935-947`), and its run value is the
    // `PrefixedValue` the string column's walk does not have.
    var it = try col.prefixIter();
    var prev: ?bool = null;
    var total: usize = 0;
    while (try it.nextRun()) |r| {
        const v = r.value.value;
        if (prev) |p| {
            if (p == v) {
                std.debug.print("rows {d} and {d} are one run of {}\n", .{ total, total + r.count, v });
                return error.TestUnexpectedResult;
            }
        }
        prev = v;
        total += r.count;
    }
    try testing.expectEqual(@as(usize, 299), total);

    // **The rows, against the model**, so the walk is not the only witness.
    var trues: usize = 0;
    for (want, 0..) |v, i| {
        if (((try col.get(i)) orelse return error.TestUnexpectedResult) != v) {
            std.debug.print("row {d} is not the model's\n", .{i});
            return error.TestExpectedEqual;
        }
        trues += @intFromBool(v);
    }
    try testing.expect((try col.get(want.len)) == null);

    // **And the prefix sums**, this codec's own question: the column's own
    // total, and the same total arrived at through the cursor the run walk
    // used — so a seam that coalesced and lost its weight cannot pass.
    try testing.expectEqual(@as(i64, @intCast(trues)), try col.getPrefix(want.len));
    try testing.expectEqual(@as(i64, @intCast(trues)), it.total());
    if (try col.checkInvariants()) |v| {
        if (v.detail_len != 0) {
            std.debug.print("{s} ({s}, at {d})\n", .{ v.what, v.detail(), v.at });
        } else {
            std.debug.print("{s} (at {d})\n", .{ v.what, v.at });
        }
        return error.TestUnexpectedResult;
    }
}

/// The boolean prefix weight walk as it stood before the run-level fold:
/// one row at a time, with the checked addition per row.
///
/// A copy of the code the run fold replaced rather than a description of it,
/// because the claim the tests below make is a substitution — the fold over
/// runs answers what the fold over rows answered — and only the replaced
/// code itself witnesses that.
fn boolWeightOfRows(slab: *const slabmod.Slab) ParseError!BoolPrefixCodec.Weight {
    var sum: i64 = 0;
    var dec = try BoolPrefixCodec.WireDecoder.init(slab.data);
    var i: usize = 0;
    while (i < slab.len) : (i += 1) {
        const w = (try dec.next()) orelse return error.InvalidValue;
        sum = std.math.add(i64, sum, @intFromBool(w)) catch return error.Overflow;
    }
    return .{ .len = slab.len, .prefix = sum };
}

/// Whether two refusals are the same refusal: both answered, or both the
/// same error.
///
/// This is not `==` on purpose. A `null` optional leaves its payload
/// uninitialised, and `==`/`!=` on an optional error compare the whole
/// representation — tag *and* payload — so two answered walks compare
/// unequal whenever their garbage payloads differ. The comparison below
/// reads the tag only, which is all a refusal is.
fn sameRefusal(a: ?ParseError, b: ?ParseError) bool {
    if (a) |ea| {
        if (b) |eb| return ea == eb;
        return false;
    }
    return b == null;
}

/// What one weight walk said about one slab: its weight, or the refusal it
/// raised, in a shape two walks can be compared with `sameRefusal`.
const WalkOutcome = struct {
    weight: BoolPrefixCodec.Weight,
    refused: ?ParseError,
};

/// Both folds on one slab, held to each other: the same weight, or the same
/// refusal. What they agreed on is returned, so a caller can hold them to a
/// refusal or an answer of its own.
fn sameBoolWeight(gpa: Allocator, slab: *const slabmod.Slab) !WalkOutcome {
    const runs = BoolPrefixCodec.weightOf(gpa, slab);
    const rows = boolWeightOfRows(slab);
    const a: WalkOutcome = if (runs) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    const b: WalkOutcome = if (rows) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    if (!sameRefusal(a.refused, b.refused) or a.weight.len != b.weight.len or a.weight.prefix != b.weight.prefix) {
        std.debug.print("over runs {any} | over rows {any}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
    return a;
}

/// One case's bytes as a slab owned by `gpa`.
///
/// `segments` and `tail` are left empty on purpose: a case is here to drive
/// the two folds, and measuring the bytes first would refuse a malformed
/// case before either fold ever saw it. The weight walk reads `data` and
/// `len` and nothing else (`columns.zig:269-285`).
fn boolCaseSlab(gpa: Allocator, bytes: []const u8, len: usize) !slabmod.Slab {
    return .{ .data = try gpa.dupe(u8, bytes), .len = len, .segments = 0, .tail = .zero };
}

/// What one case owes, checked as well as agreed on, so a pair of walks that
/// agree on a wrong answer cannot pass for a pair that agrees. A case that
/// owes a refusal owes nothing else, and a case that owes an answer owes
/// both halves of it.
fn boolCaseOwed(outcome: WalkOutcome, want: ?ParseError, len: usize, prefix: i64) bool {
    if (!sameRefusal(outcome.refused, want)) return false;
    if (want != null) return true;
    return outcome.weight.len == len and outcome.weight.prefix == prefix;
}

test "the run-level weight of a boolean slab is the row-level weight, over runs of one, two and three hundred" {
    // **The claim is a substitution.** `weightOf` folds runs; it folded rows.
    // Runs of one, two and three hundred are the three shapes that separate
    // the two walks: a run no wider than the row walk's step, a run twice it,
    // and a run that makes the row walk three hundred times longer than the
    // run walk. Every slab is held to the row walk and to a count of the
    // `true`s the test drew.
    const gpa = testing.allocator;
    var rng: u64 = 0x243f6a8885a308d3;
    const run_lengths = [_]usize{ 1, 2, 300 };

    for (0..32) |trial| {
        var values: std.ArrayList(bool) = .empty;
        defer values.deinit(gpa);
        var trues: i64 = 0;
        var v = (xorshift(&rng) & 1) == 0;
        while (values.items.len < 900) {
            const n = run_lengths[@as(usize, @intCast(xorshift(&rng) % run_lengths.len))];
            for (0..n) |_| try values.append(gpa, v);
            if (v) trues += @as(i64, @intCast(n));
            v = !v;
        }
        const bytes = try BoolPrefixCodec.wireEncode(gpa, values.items, false);
        defer gpa.free(bytes);
        var slab = try slabmod.init(gpa, BoolPrefixCodec, bytes);
        defer slab.deinit(gpa);

        const w = (try sameBoolWeight(gpa, &slab)).weight;
        if (w.len != values.items.len or w.prefix != trues) {
            std.debug.print("trial {d}: {any} over {d} rows of which {d} are true\n", .{ trial, w, values.items.len, trues });
            return error.TestUnexpectedResult;
        }
    }

    // **The two slabs the drawn runs cannot be relied on to produce**: one
    // run of `true` and one run of `false`, each long enough that the row walk
    // is the slow one by three orders of magnitude. The `true` slab is the one
    // carrying the opening pad, and it is the shape the op set's `insert`
    // column is at its widest (`bool.zig:14-15`).
    for ([_]usize{ 900, 4096 }) |n| {
        for ([_]bool{ true, false }) |v| {
            const bytes = try BoolPrefixCodec.wireFill(gpa, n, v, false);
            defer gpa.free(bytes);
            var slab = try slabmod.init(gpa, BoolPrefixCodec, bytes);
            defer slab.deinit(gpa);
            const w = (try sameBoolWeight(gpa, &slab)).weight;
            try testing.expectEqual(@as(usize, n), w.len);
            try testing.expectEqual(if (v) @as(i64, @intCast(n)) else 0, w.prefix);
        }
    }
}

test "a slab that opens on a pad, and one with zero counts inside it, weight the same either way" {
    // **The opening pad is a run of no rows, and it is never served.** A
    // slab's own run sequence opens on a `false` run, so a slab whose values
    // open on `true` carries a count of zero in front of them
    // (`bool.zig:17-25`, `bool.rs:988-1002`). `nextRunMax` steps over that
    // header and returns the run behind it, which is what `next` does too, so
    // the fold must neither serve the pad as a run of no rows nor spend a row
    // on it: a loop that spun on a zero count would hang on every all-`true`
    // slab the port writes, and the second case below is here to catch that.
    //
    // **Zero counts inside the sequence are not canonical** — the writer
    // merges two neighbours that carry the same value, so an empty run in the
    // middle means the bytes should have been merged (`bool.zig:17-25`) — but
    // the decoder accepts them and steps over each, so a fold that read one
    // as a run of no rows and kept its budget would walk a different row
    // count from the row walk. They are written in pairs, which leaves the
    // parity the value is stored in the one the bytes mean: two zero counts
    // flip it twice, so the second slab holds exactly the rows the first
    // holds.
    const gpa = testing.allocator;
    const cases = [_][]const usize{
        &.{ 300, 300 },
        &.{ 300, 0, 0, 300 },
        &.{ 0, 300 },
        &.{ 1, 1, 1, 1, 0, 0, 0, 0, 1, 1 },
        &.{ 0, 0, 0, 1 },
    };

    for (cases, 0..) |counts, i| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        for (counts) |c| try leb128.appendUnsigned(&bytes, gpa, c);

        var slab = try slabmod.init(gpa, BoolPrefixCodec, bytes.items);
        defer slab.deinit(gpa);

        // The model, walked the way `advanceRun` walks: the decoder opens on
        // `true` and flips before each count, so the first count is a `false`
        // count and a count of zero still occupies a run position.
        var want_len: usize = 0;
        var want_true: i64 = 0;
        var value = true;
        for (counts) |c| {
            value = !value;
            want_len += c;
            if (value and c != 0) want_true += @as(i64, @intCast(c));
        }
        // The measure agrees: an empty run is a run position and no rows.
        if (slab.len != want_len) {
            std.debug.print("case {d} {any}: measured {d} rows, counts say {d}\n", .{ i, counts, slab.len, want_len });
            return error.TestUnexpectedResult;
        }

        const w = (try sameBoolWeight(gpa, &slab)).weight;
        if (w.len != want_len or w.prefix != want_true) {
            std.debug.print("case {d} {any}: {any}, model {d} rows of which {d} are true\n", .{ i, counts, w, want_len, want_true });
            return error.TestUnexpectedResult;
        }
    }
}

test "the run-level weight refuses what the row-level weight refuses, and neither of them allocates" {
    // **Every refusal a boolean slab carries, at the same point.** The
    // exhaustion is `error.InvalidValue`; the rest are the three raises of
    // `advanceRun` — a truncated varint, an overlong one, and a count too wide
    // for the packing (`bool.zig:325-335`, `leb128.zig:146-177`). Each case
    // states which one it is, so the two folds agreeing on `error.InvalidValue`
    // for a case that owed `error.UnexpectedEnd` cannot pass.
    const gpa = testing.allocator;
    // **A well-formed case is its own counts**: a count of one or two is one
    // byte, and `300` is two (`0xac 0x02`). A slab's first count is a `false`
    // count, so the all-`true` slab is the one with a zero in front of it.
    const cases = [_]struct {
        bytes: []const u8,
        len: usize,
        prefix: i64,
        want: ?ParseError,
        why: []const u8,
    }{
        .{ .bytes = &.{2}, .len = 5, .prefix = 0, .want = error.InvalidValue, .why = "two rows for five owed" },
        .{ .bytes = &.{ 2, 2 }, .len = 4, .prefix = 2, .want = null, .why = "two falses then two trues" },
        .{ .bytes = &.{ 2, 2 }, .len = 2, .prefix = 0, .want = null, .why = "two rows of a four-row slab" },
        .{ .bytes = &.{3}, .len = 0, .prefix = 0, .want = null, .why = "no rows owed of a three-row slab" },
        .{ .bytes = &.{}, .len = 3, .prefix = 0, .want = error.InvalidValue, .why = "no bytes at all" },
        .{ .bytes = &.{ 0xac, 0x02 }, .len = 300, .prefix = 0, .want = null, .why = "three hundred falses" },
        .{ .bytes = &.{ 0x00, 0xac, 0x02 }, .len = 300, .prefix = 300, .want = null, .why = "the pad then three hundred trues" },
        .{ .bytes = &.{ 2, 0xac, 0x02 }, .len = 302, .prefix = 300, .want = null, .why = "two falses then three hundred trues" },
        .{ .bytes = &.{0x80}, .len = 1, .prefix = 0, .want = error.UnexpectedEnd, .why = "a count cut short" },
        .{ .bytes = &.{ 2, 0x80 }, .len = 3, .prefix = 0, .want = error.UnexpectedEnd, .why = "a count cut short after a run" },
        .{ .bytes = &.{ 0x80, 0x00 }, .len = 1, .prefix = 0, .want = error.InvalidLeb128, .why = "an overlong count" },
        .{ .bytes = &.{ 2, 0x80, 0x00 }, .len = 3, .prefix = 0, .want = error.InvalidLeb128, .why = "an overlong count after a run" },
        .{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }, .len = 1, .prefix = 0, .want = error.Overflow, .why = "a count too wide for the packing" },
    };

    for (cases) |c| {
        var slab = try boolCaseSlab(gpa, c.bytes, c.len);
        defer slab.deinit(gpa);
        const outcome = try sameBoolWeight(gpa, &slab);
        if (!boolCaseOwed(outcome, c.want, c.len, c.prefix)) {
            std.debug.print("{s}: {any}, and the case says {any} at {d}\n", .{ c.why, outcome, c.want, c.prefix });
            return error.TestUnexpectedResult;
        }
    }

    // **The sum's own refusal, at a boundary no slab can reach.** A count is
    // at most `slab.len`, and a slab of `maxInt(i64) + 1` true rows is not a
    // slab, so `weightOf` cannot leave `i64` and its `error.Overflow` is
    // unreachable from bytes. `accumulateRun` is the same addition at a sum
    // a caller can reach, and the row walk it replaces is `accumulate` over
    // rows — so the pair below is where the two folds' overflow refusals are
    // shown to land on the same sum: one `true` adds one, a run of them adds
    // its count, and a `false` adds nothing however long it is.
    var running: i64 = std.math.maxInt(i64) - 1;
    try BoolPrefixCodec.accumulateRun(true, 1, &running);
    try testing.expectEqual(std.math.maxInt(i64), running);
    try testing.expectError(error.Overflow, BoolPrefixCodec.accumulateRun(true, 1, &running));
    // **A refusal leaves the sum where it was**, which is what makes the
    // refusal usable: `accumulateWire` propagates it with `try`
    // (`column.zig:298`), so nothing downstream of it is half folded.
    try testing.expectEqual(std.math.maxInt(i64), running);
    running = std.math.maxInt(i64);
    try BoolPrefixCodec.accumulateRun(false, 4096, &running);
    try testing.expectEqual(std.math.maxInt(i64), running);
    running = 0;
    try BoolPrefixCodec.accumulateRun(false, std.math.maxInt(usize), &running);
    try testing.expectEqual(@as(i64, 0), running);
    if (comptime @bitSizeOf(usize) > @bitSizeOf(i64)) {
        // **A run too wide for `i64` refuses rather than truncating**, at the
        // sum the row walk would have refused after `maxInt(i64)` of its own
        // additions.
        try testing.expectError(error.Overflow, BoolPrefixCodec.accumulateRun(true, @as(usize, std.math.maxInt(i64)) + 1, &running));
    }

    // **And neither fold allocates, so there is no allocation point in one
    // to move.** `weightOf` ignores its allocator — `reindexFrom` calls it
    // once per slab and keeps the weight (`hexane/column.zig:6687-6693`) —
    // so the fold that was replaced allocated nothing and the fold that
    // replaced it allocates nothing. The sweep holds both to that: for every
    // allocation index the run can be armed at, the two walks are answered
    // and the allocator is left on the index it entered them on.
    for (cases) |c| {
        const needed = blk: {
            var failing: testing.FailingAllocator = .init(gpa, .{});
            var probe = try boolCaseSlab(failing.allocator(), c.bytes, c.len);
            defer probe.deinit(failing.allocator());
            _ = try sameBoolWeight(failing.allocator(), &probe);
            break :blk failing.alloc_index;
        };
        // How many allocations the clean run makes, which is the number of
        // arms worth visiting (`mark_index.zig:2907-2930`,
        // `column.zig:9075-9101`).
        for (0..needed + 1) |fail_index| {
            var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
            const arm = failing.allocator();
            // A refusal in the setup says nothing about a fold, so it is
            // skipped rather than counted as a pass: `fail_index` counts from
            // the first allocation of the run, and this run's first
            // allocation is the duplication.
            var slab = boolCaseSlab(arm, c.bytes, c.len) catch continue;
            defer slab.deinit(arm);
            const before = failing.alloc_index;
            const outcome = try sameBoolWeight(arm, &slab);
            if (failing.alloc_index != before) {
                std.debug.print("{s}: a fold allocated, and the allocator is on {d} not {d}\n", .{ c.why, failing.alloc_index, before });
                return error.TestUnexpectedResult;
            }
            if (!boolCaseOwed(outcome, c.want, c.len, c.prefix)) {
                std.debug.print("{s}: {any} under a refusal, and the case says {any} at {d}\n", .{ c.why, outcome, c.want, c.prefix });
                return error.TestUnexpectedResult;
            }
        }
        // **Armed where the walks left the allocator, they still answer.**
        // `fail_index` counts successful allocations and latches once it is
        // reached (`std/testing/FailingAllocator.zig:65-79`, the note at
        // `mark_index.zig:3543-3547`), so arming it at `needed` refuses the
        // very next allocation — and a walk that allocated would have been the
        // one refused instead. The walks are answered and the refusal lands
        // after them, which is the same point for the fold that was replaced
        // and for the fold that replaced it.
        var armed: testing.FailingAllocator = .init(gpa, .{ .fail_index = needed });
        const arm = armed.allocator();
        var slab = try boolCaseSlab(arm, c.bytes, c.len);
        defer slab.deinit(arm);
        const outcome = try sameBoolWeight(arm, &slab);
        if (!boolCaseOwed(outcome, c.want, c.len, c.prefix)) {
            std.debug.print("{s}: {any} armed at {d}, and the case says {any} at {d}\n", .{ c.why, outcome, needed, c.want, c.prefix });
            return error.TestUnexpectedResult;
        }
        try testing.expectError(error.OutOfMemory, arm.alloc(u8, c.bytes.len + 1));
    }
}

/// One refused splice on a boolean prefix column cut into several slabs, with
/// the rows and the prefix sums read back as the model has them.
fn boolSpliceRefusalAt(gpa: Allocator, budget: usize, model: []const bool, ins: []const bool, index: usize, del: usize) !void {
    var col = try BoolPrefixColumn.initWithBudget(gpa, budget);
    defer col.deinit();
    try col.extend(gpa, model);

    var want: std.ArrayList(bool) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, model[0..index]);
    try want.appendSlice(testing.allocator, ins);
    try want.appendSlice(testing.allocator, model[index + del ..]);

    var committed = true;
    if (col.splice(gpa, index, del, ins)) |_| {} else |e| {
        // The bounds are checked before anything moves, so the only refusal a
        // valid request can come back with is the allocator's.
        if (e != error.OutOfMemory) return e;
        committed = false;
    }

    // **The invariants are checked on a clean run and not here**: they read
    // the column's own allocator (`column.zig:6863`, `:6879`), so an armed
    // one refuses them and the refusal says nothing about the edit.
    const got = try col.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(got.len, col.len());
    if (!committed) {
        // **A refusal leaves the column exactly as it was**: rows written but
        // not counted, a range dropped but not rebuilt, or an index describing
        // the layout before the cut would each show here as a value sequence
        // that is neither list.
        try testing.expectEqualSlices(bool, model, got);
        return;
    }
    try testing.expectEqualSlices(bool, want.items, got);
    // **And the prefix sums, which is the question `weightOf` answers.** Every
    // one of them goes through `accumulateWire`, so a fold that lost or
    // invented a row — or that refused where the row walk answered — shows
    // here as a prefix that is not the count of the `true`s in front of it.
    var trues: i64 = 0;
    for (got, 0..) |_, i| {
        if (i != 0) trues += @intFromBool(got[i - 1]);
        const at = try col.getPrefix(i);
        if (at != trues) {
            std.debug.print("prefix at {d} is {d}, model {d}\n", .{ i, at, trues });
            return error.TestUnexpectedResult;
        }
    }
    // The loop leaves the count of every row but the last, so the last row
    // joins it here: the total is the count of every `true` in `got`.
    if (got.len != 0) trues += @intFromBool(got[got.len - 1]);
    if (trues != try col.getPrefix(got.len)) {
        std.debug.print("the column's own total is not the model's {d}\n", .{trues});
        return error.TestUnexpectedResult;
    }
}

test "a refused allocation leaves a boolean prefix column's rows and prefix sums where they were" {
    // **The path the fold is on.** `reindexFrom` asks this codec for the
    // weight of every slab from the first one a splice touched
    // (`hexane/column.zig:6687-6693`), and `settle` reaches it on every
    // splice (`column.zig:6553`), so a weight that refused where the old one
    // answered would show here as a refused splice on a column nothing was
    // wrong with, and a weight that answered differently as a prefix sum that
    // is not the model's.
    const model = [_]bool{ true, false, true, true, false, true, false, true, true, true, false, false, true, false, true, true };
    const ins = [_]bool{ true, true, false, true, false, false };
    // Three and four runs to a slab, so sixteen alternating values are still
    // several slabs: `reindexFrom` weighs more than one on every arm, which
    // is the shape the measured profile was in.
    const cuts = [_]struct { budget: usize, index: usize, del: usize }{
        .{ .budget = 3, .index = 7, .del = 3 },
        .{ .budget = 3, .index = 0, .del = 1 },
        .{ .budget = 4, .index = 1, .del = 1 },
        .{ .budget = 4, .index = 15, .del = 0 },
    };
    for (cuts) |c| {
        const needed = blk: {
            var failing: testing.FailingAllocator = .init(testing.allocator, .{});
            try boolSpliceRefusalAt(failing.allocator(), c.budget, &model, &ins, c.index, c.del);
            // **The invariants, on a column no allocator refused.** They
            // reweigh every slab against the index (`column.zig:6908`), which
            // is the same fold this file changed, so they are read once here
            // where every allocation they make succeeds.
            var col = try BoolPrefixColumn.initWithBudget(testing.allocator, c.budget);
            defer col.deinit();
            try col.extend(testing.allocator, &model);
            _ = try col.splice(testing.allocator, c.index, c.del, &ins);
            if (try col.checkInvariants()) |v| {
                std.debug.print("{s} (at {d})\n", .{ v.what, v.at });
                return error.TestUnexpectedResult;
            }
            break :blk failing.alloc_index;
        };
        for (0..needed + 1) |fail_index| {
            var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
            // A refusal in the setup says nothing about the splice, so it is
            // skipped rather than counted as a pass: `fail_index` counts from
            // the first allocation of the run, and this run's first
            // allocations are the column's own.
            boolSpliceRefusalAt(failing.allocator(), c.budget, &model, &ins, c.index, c.del) catch |e| switch (e) {
                error.OutOfMemory => continue,
                else => return e,
            };
        }
    }
}

test "the metadata weight fold and the row walk it replaced land on the same sum" {
    // **The pair below is the claim, and both halves are checked**:
    // `accumulateRun` is the fold `MetaPrefixCodec.weightOf` now takes, and
    // `accumulate` over rows is the one it replaced. They must answer the
    // same sum and refuse on the same sum, because the fold runs on the write
    // path of every splice and the row walk still runs on the read path.
    //
    // **A word whose length is two** (`op_set2/meta.rs:40-42`: the word is
    // `(length << 4) | type`), so a run of `count` rows of it adds
    // `2 * count` and the refusals below land on round numbers.
    const word: u64 = (2 << 4) | 1;
    const M = std.math.maxInt(i64);

    // **Every ordinary count, and the two agree exactly** — including a run of
    // no rows, which adds nothing, and a run long enough to need the
    // multiplication the fold is for.
    for ([_]usize{ 0, 1, 2, 7, 64, 1000 }) |count| {
        var run: i64 = 0;
        var rows: i64 = 0;
        try MetaPrefixCodec.accumulateRun(word, count, &run);
        var i: usize = 0;
        while (i < count) : (i += 1) try MetaPrefixCodec.accumulate(word, &rows);
        try testing.expectEqual(rows, run);
        try testing.expectEqual(@as(i64, @intCast(2 * count)), run);
    }

    // **A sum in front of a run can be negative**, which is the `runningAt`
    // case: `runningAt` folds a slab onto the column's own base
    // ([column.zig:3483](../hexane/column.zig)), and a base is not always
    // zero. Both folds start at the smallest `i64` and neither refuses.
    {
        var run: i64 = std.math.minInt(i64);
        var rows: i64 = std.math.minInt(i64);
        try MetaPrefixCodec.accumulateRun(word, 4096, &run);
        var i: usize = 0;
        while (i < 4096) : (i += 1) try MetaPrefixCodec.accumulate(word, &rows);
        try testing.expectEqual(rows, run);
    }

    // **The span hazard, reached — and this is the case the one above is not.**
    // A sum already inside `i64` can span more than `i64` on its own
    // ([addRunOf](../hexane/column.zig)), so a fold that multiplied first and
    // added second would refuse where this one must answer. Here the span is
    // `2 * (1 << 62) = 2^63`, which leaves `i64` on its own, and the result is
    // `minInt(i64) + 2^63 = 0`, which fits — so the arm answers `0` and
    // refuses nothing. **The 4096 rows above span 8192 and reach none of
    // this**; a case that stops short of the hazard and is described as
    // reaching it is the false sentence in miniature.
    //
    // **The row walk is not the witness here, and cannot be.** It is the same
    // addition `count` times, so it would need `1 << 62` rows to be walked;
    // `accumulateRun` never materialises the run, which is the whole of what
    // makes it O(1). So this case pins the arm on its own, and the agreement
    // with the walk is pinned above, where both are affordable.
    {
        var run: i64 = std.math.minInt(i64);
        try MetaPrefixCodec.accumulateRun(word, @as(usize, 1) << 62, &run);
        try testing.expectEqual(@as(i64, 0), run);
    }

    // **And they refuse on the same sum, at the same row.** `M - 2` plus one
    // row of length two is exactly `M`, and the second row is the refusal —
    // the run takes it as one step where the walk takes it as the second of
    // two.
    {
        var run: i64 = M - 2;
        var rows: i64 = M - 2;
        try MetaPrefixCodec.accumulateRun(word, 1, &run);
        try MetaPrefixCodec.accumulate(word, &rows);
        try testing.expectEqual(@as(i64, M), run);
        try testing.expectEqual(@as(i64, M), rows);
        try testing.expectError(error.Overflow, MetaPrefixCodec.accumulateRun(word, 1, &run));
        try testing.expectError(error.Overflow, MetaPrefixCodec.accumulate(word, &rows));
    }

    // **A refusal leaves the sum where it was**, which is what makes it
    // usable: `accumulateWire` propagates it with `try`
    // ([column.zig:298](../hexane/column.zig)), so nothing downstream of a
    // fold that stops is half folded.
    {
        var run: i64 = M - 2;
        try testing.expectError(error.Overflow, MetaPrefixCodec.accumulateRun(word, 2, &run));
        try testing.expectEqual(@as(i64, M - 2), run);
    }
}

/// `MetaPrefixCodec.weightOf` as it stood before the run-level fold: one row
/// at a time, with the checked addition per row.
///
/// A copy of the code the fold replaced rather than a description of it,
/// because the claim the tests below make is a substitution — the fold over
/// runs answers what the fold over rows answered — and only the replaced code
/// itself witnesses that. `boolWeightOfRows` is the same copy for the boolean
/// codec, and the reason is the one it gives.
fn metaWeightOfRows(slab: *const slabmod.Slab) ParseError!MetaPrefixCodec.Weight {
    var sum: i64 = 0;
    var dec = try MetaPrefixCodec.WireDecoder.init(slab.data);
    var i: usize = 0;
    while (i < slab.len) : (i += 1) {
        const w = (try dec.next()) orelse return error.InvalidValue;
        sum = std.math.add(i64, sum, try MetaPrefixCodec.lengthOf(w)) catch return error.Overflow;
    }
    return .{ .len = slab.len, .prefix = sum };
}

/// Both folds on one metadata slab, held to each other: the same weight, or
/// the same refusal. What they agreed on comes back, so a caller can hold it
/// to a refusal or an answer of its own.
fn sameMetaWeight(gpa: Allocator, slab: *const slabmod.Slab) !WalkOutcome {
    const runs = MetaPrefixCodec.weightOf(gpa, slab);
    const rows = metaWeightOfRows(slab);
    const a: WalkOutcome = if (runs) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    const b: WalkOutcome = if (rows) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    if (!sameRefusal(a.refused, b.refused) or a.weight.len != b.weight.len or a.weight.prefix != b.weight.prefix) {
        std.debug.print("over runs {any} | over rows {any}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
    return a;
}

/// One word list, held on four counts: the bytes must be cut into `runs` runs,
/// the fold and the row walk must answer the same weight, and that weight must
/// be the model's own sum of the declared lengths over `words.len` rows — so a
/// pair of folds agreeing on a wrong answer cannot pass. The run count is in
/// the call because a case cannot be taken for a repeat run or a literal run
/// until the bytes say it is one, and a repeat run is never written with a
/// count of one (`column.zig:1704-1706`), so a single word is a literal run.
fn metaWordsHeld(gpa: Allocator, words: []const u64, runs: usize) !void {
    const bytes = try MetaPrefixCodec.wireEncode(gpa, words, false);
    defer gpa.free(bytes);
    var slab = try slabmod.init(gpa, MetaPrefixCodec, bytes);
    defer slab.deinit(gpa);
    if (slab.segments != runs) {
        std.debug.print("{d} rows encoded into {d} run(s), the case says {d}\n", .{ words.len, slab.segments, runs });
        return error.TestUnexpectedResult;
    }
    var model: i64 = 0;
    for (words) |w| model += @intCast(w >> 4);
    const outcome = try sameMetaWeight(gpa, &slab);
    if (outcome.refused != null or outcome.weight.len != words.len or outcome.weight.prefix != model) {
        std.debug.print("{d} rows in {d} run(s): {any}, and the model says {d} over {d} rows\n", .{ words.len, runs, outcome, model, words.len });
        return error.TestUnexpectedResult;
    }
}

/// One hand-built metadata case, held: both folds must say what the case says
/// — the refusal, or the sum over `len` rows — and `sameMetaWeight` has
/// already held them to each other before this runs.
///
/// The bytes are copied rather than borrowed because `Slab.data` is owned.
/// `segments` and `tail` are left empty on purpose: a case is here to drive the
/// two folds, and measuring the bytes first would refuse a malformed case
/// before either fold ever saw it. The weight walk reads `data` and `len` and
/// nothing else (`columns.zig:428-439`).
fn metaCaseHeld(gpa: Allocator, why: []const u8, bytes: []const u8, len: usize, want: ?ParseError, prefix: i64) !void {
    const owned = try gpa.dupe(u8, bytes);
    defer gpa.free(owned);
    const slab: slabmod.Slab = .{ .data = owned, .len = len, .segments = 0, .tail = .zero };
    const outcome = try sameMetaWeight(gpa, &slab);
    if (!sameRefusal(outcome.refused, want)) {
        std.debug.print("{s}: {any}, and the case says {any}\n", .{ why, outcome, want });
        return error.TestUnexpectedResult;
    }
    if (want == null and (outcome.weight.len != len or outcome.weight.prefix != prefix)) {
        std.debug.print("{s}: {any}, and the case says {d} over {d} rows\n", .{ why, outcome, prefix, len });
        return error.TestUnexpectedResult;
    }
}

test "the metadata weight fold is the row walk's weight, over every run shape a metadata column holds" {
    // **The claim is a substitution**, and `metaWeightOfRows` is the code it
    // replaced. Every case is held three ways — the bytes are cut into the runs
    // the case names, the two folds answer the same weight, and that weight is
    // the model's own sum of the declared lengths — so a pair of folds that
    // agree on a wrong answer cannot pass for a pair that agrees.
    const gpa = testing.allocator;
    var buf: [400]u64 = undefined;

    // **A word is `(length << 4) | type`** (`op_set2/meta.rs:20-43`), so these
    // three are a length-9 word, a length-3 word and a word of no length.
    const a: u64 = (9 << 4) | 1;
    const b: u64 = (3 << 4) | 2;
    const nothing: u64 = 3;

    // **One repeat run of one word** — no differences between the rows at all,
    // and the shape `Slab.fill` builds in O(1) (`slab.zig:242-243`), which is
    // what a staged op set holds for a column of equal-length metadata words.
    // Three hundred rows are one varint and one word on the wire, and were
    // three hundred iterations of the row walk.
    @memset(buf[0..300], a);
    try metaWordsHeld(gpa, buf[0..300], 1);

    // **Words of no length**, which add nothing and are not a null run: a
    // length of zero is the prefix identity in a word rather than in a header,
    // and a slab of them weighs zero over every row it holds.
    @memset(buf[0..64], nothing);
    try metaWordsHeld(gpa, buf[0..64], 1);

    // **One literal run of three hundred distinct words.** `nextRunMax` hands a
    // literal run back one value at a time (`rle.zig:600-605`), so this is the
    // case the fold still walks a row at a time, and it must walk it to the
    // same sum.
    for (buf[0..300], 0..) |*v, i| v.* = (@as(u64, @intCast(i + 1)) << 4) | 1;
    try metaWordsHeld(gpa, buf[0..300], 1);

    // **Repeat, literal, repeat, and a run of no length** — four runs, so the
    // sum has to be carried across every boundary rather than restarted. The
    // literal run's sixty lengths run 100 to 159, none of which is 9, 3 or 0,
    // so the four runs stay four runs.
    {
        var n: usize = 0;
        for (0..120) |_| {
            buf[n] = a;
            n += 1;
        }
        for (0..60) |i| {
            buf[n] = (@as(u64, @intCast(100 + i)) << 4) | 1;
            n += 1;
        }
        for (0..120) |_| {
            buf[n] = b;
            n += 1;
        }
        for (0..40) |_| {
            buf[n] = nothing;
            n += 1;
        }
        try metaWordsHeld(gpa, buf[0..n], 4);
    }

    // **A decreasing run**: three hundred distinct lengths falling one at a
    // time, so the running value at the last row is 1 and not the slab's own
    // start. A prefix sum over a falling sequence is the one shape where the
    // total is not the count times anything.
    for (buf[0..300], 0..) |*v, i| v.* = (@as(u64, @intCast(300 - i)) << 4) | 1;
    try metaWordsHeld(gpa, buf[0..300], 1);

    // **A literal run whose widest word is interior**, so the fold cannot take
    // the run's first or last value for its extent. The widest word this codec
    // can hold declares `maxInt(u64) >> 4` and it is the third of five; the
    // other four differ from it only in the type nibble, so this case is also
    // the one that says the nibble is not part of the length.
    {
        var n: usize = 0;
        for ([_]u64{ 1, 3, std.math.maxInt(u64), 2, 5 }) |v| {
            buf[n] = v;
            n += 1;
        }
        try metaWordsHeld(gpa, buf[0..n], 1);
    }

    // **The declared length under all sixteen types**: sixteen distinct words
    // of one length, so the run is literal and every one of them has to add
    // the same five.
    {
        var n: usize = 0;
        for (0..16) |t| {
            buf[n] = (@as(u64, 5) << 4) | @as(u64, @intCast(t));
            n += 1;
        }
        try metaWordsHeld(gpa, buf[0..n], 1);
    }

    // **The two ends of the declared-length range on their own**, which the
    // fold may neither round, widen nor drop: the widest word there is, and
    // the word of no length. A single word is a literal run of one, so both
    // are the one run `nextRunMax` hands back a value at a time.
    buf[0] = std.math.maxInt(u64);
    try metaWordsHeld(gpa, buf[0..1], 1);
    buf[0] = 0;
    try metaWordsHeld(gpa, buf[0..1], 1);

    // **The two bounds that disagree with the bytes.** Both folds bound
    // themselves by the slab's declared length and not by the bytes, so a
    // length short of the wire stops both early with the same shortened sum,
    // and a length past the end is `error.InvalidValue` in both — the third
    // shape the budget makes the two ends of the walk agree on.
    @memset(buf[0..10], a);
    {
        const bytes = try MetaPrefixCodec.wireEncode(gpa, buf[0..10], false);
        defer gpa.free(bytes);
        for ([_]usize{ 0, 4, 10, 11 }) |len| {
            const slab: slabmod.Slab = .{ .data = bytes, .len = len, .segments = 0, .tail = .zero };
            const outcome = try sameMetaWeight(gpa, &slab);
            const want: ?ParseError = if (len > 10) error.InvalidValue else null;
            // **The row count is widened before the multiply, and it has to
            // be.** `@min(len, 10)` does not answer `usize`: Zig gives `@min`
            // the smallest type that holds *both* operands' range, and `10`
            // fits in `u4`, so the product would be `u4 * 9` — `9` does not
            // fit `u4`, and the multiply traps on `len == 4` (`4 * 9` is 36
            // against a maximum of 15) before the cast ever runs. The typed
            // binding is the same widening `change_graph.zig:1046` spells as
            // `const from: u32 = @intCast(@min(...))`, and it puts the `usize`
            // the loop already had back under the product.
            const rows: usize = @min(len, 10);
            const sum: i64 = @intCast(rows * 9);
            if (!sameRefusal(outcome.refused, want)) {
                std.debug.print("{d} rows owed of ten: {any}, and the case says {any}\n", .{ len, outcome, want });
                return error.TestUnexpectedResult;
            }
            if (want == null and (outcome.weight.len != len or outcome.weight.prefix != sum)) {
                std.debug.print("{d} rows owed of ten: {any}, and the case says {d}\n", .{ len, outcome, sum });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the metadata weight fold refuses what the row walk refuses, at the same run" {
    // **Every refusal a metadata slab carries, each named**, so two folds that
    // agree on `error.InvalidValue` for a case that owed `error.UnexpectedEnd`
    // cannot pass. Each case goes through `sameMetaWeight` as well, so the two
    // walks are held to each other and not only to what is written here.
    //
    // The bytes are built through the packing rather than written out, because
    // a run header is a *signed* varint and a payload an unsigned one, and the
    // literal-run cases below are exactly the ones where a hand-written byte
    // would be wrong in a way the test could not tell from the refusal it was
    // reaching for.
    const gpa = testing.allocator;
    // A length-9 word, whose unsigned varint is two bytes, so the case that
    // cuts it short cuts it mid-varint rather than mid-byte.
    const word_len9: u64 = (9 << 4) | 1;

    // **The two refusals of a run header**, before any payload is read: a
    // varint cut short, and one that runs past the ten bytes a `i64` needs.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.append(gpa, 0x80);
        try metaCaseHeld(gpa, "a run header cut short", bytes.items, 1, error.UnexpectedEnd, 0);
    }
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try bytes.append(gpa, 0x80);
        try bytes.append(gpa, 0x00);
        try metaCaseHeld(gpa, "a run header running past its own width", bytes.items, 1, error.InvalidLeb128, 0);
    }

    // **A repeat run's one payload, cut short.** The header says three rows of
    // one word and the word's varint never finishes. `nextRunMax` reads that
    // payload inside `enterRun` (`rle.zig:651`) — the very call the row walk's
    // `next` makes — so the fold cannot spend the run's count without reading
    // the word that run is made of.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try leb128.appendSigned(&bytes, gpa, 3);
        try leb128.appendUnsigned(&bytes, gpa, word_len9);
        bytes.items.len -= 1;
        try metaCaseHeld(gpa, "a repeat run's payload cut short", bytes.items, 3, error.UnexpectedEnd, 0);
    }

    // **A run claiming more values than the bytes hold**, which
    // `readRunHeader` refuses before the walk starts (`rle.zig:835`).
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try leb128.appendSigned(&bytes, gpa, -5);
        try leb128.appendUnsigned(&bytes, gpa, 7);
        try metaCaseHeld(gpa, "a literal run longer than the bytes", bytes.items, 1, error.LengthExceedsInput, 0);
    }

    // **A literal run's third payload, cut short.** This is the case the fold
    // is judged on: a literal run's values are packed back to back and its
    // count says nothing about where any one of them starts, so `nextRunMax`
    // reads them one at a time (`rle.zig:600-605`) — through the same
    // `readValue` the row walk reads them through (`rle.zig:493`). A fold that
    // counted the run instead would walk past this and answer.
    //
    // **The third payload is a byte, not a missing one**: every value costs at
    // least a byte, so a count the bytes cannot back is refused by the header
    // reader instead (`rle.zig:835`, the case above), and a payload can only
    // be cut short inside its own varint. This is the byte that says another
    // byte is coming.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try leb128.appendSigned(&bytes, gpa, -3);
        try leb128.appendUnsigned(&bytes, gpa, 5);
        try leb128.appendUnsigned(&bytes, gpa, 6);
        try bytes.append(gpa, 0x80);
        try metaCaseHeld(gpa, "a literal run's third payload cut short", bytes.items, 3, error.UnexpectedEnd, 0);
    }

    // **A count past `maxSlabLen`**, refused before the payload is even read
    // (`rle.zig:650`).
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try leb128.appendSigned(&bytes, gpa, @as(i64, (@as(u64, 1) << 32) + 1));
        try metaCaseHeld(gpa, "a run count past maxSlabLen", bytes.items, 2, error.TooLarge, 0);
    }

    // **A null run in a column that has none**, which is what the
    // non-nullable instantiation of this wire — the one `value_meta` is written
    // under — answers for every null run (`rle.zig:655-656`). It sits behind a
    // well-formed repeat run so the case also says the refusal is at the run
    // that carries it and not at the head of the walk.
    {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try leb128.appendSigned(&bytes, gpa, 2);
        try leb128.appendUnsigned(&bytes, gpa, word_len9);
        try leb128.appendSigned(&bytes, gpa, 0);
        try leb128.appendUnsigned(&bytes, gpa, 3);
        try metaCaseHeld(gpa, "a null run in a column with none", bytes.items, 5, error.UnexpectedNull, 0);
        // **And stopping short of it answers**, which is the other half of the
        // budget: two rows of a length-9 word, and the null run behind them
        // never opened.
        try metaCaseHeld(gpa, "two rows in front of the null run", bytes.items, 2, null, 18);
    }

    // **The `i64` refusal, at a sum a slab can reach.** The widest word
    // declares `2^60 - 1`, so eight of them are `maxInt(i64) - 7` and answer,
    // and nine leave `i64` and refuse. The word is not what overflows — no word
    // can, `lengthOf`'s own refusal being unreachable — the count is, which is
    // why the pair sits here and not in a case about the word.
    {
        var buf: [9]u64 = undefined;
        @memset(&buf, std.math.maxInt(u64));
        const eight = try MetaPrefixCodec.wireEncode(gpa, buf[0..8], false);
        defer gpa.free(eight);
        const nine = try MetaPrefixCodec.wireEncode(gpa, buf[0..9], false);
        defer gpa.free(nine);
        // `2^60 - 1` is the widest length a word can declare.
        const span: i64 = (@as(i64, 1) << 60) - 1;
        for ([_]usize{ 8, 9 }) |rows| {
            const bytes = if (rows == 8) eight else nine;
            var slab = try slabmod.init(gpa, MetaPrefixCodec, bytes);
            defer slab.deinit(gpa);
            const outcome = try sameMetaWeight(gpa, &slab);
            const want: ?ParseError = if (rows == 8) null else error.Overflow;
            if (!sameRefusal(outcome.refused, want)) {
                std.debug.print("{d} rows of the widest word: {any}, and the case says {any}\n", .{ rows, outcome, want });
                return error.TestUnexpectedResult;
            }
            if (want == null and outcome.weight.prefix != @as(i64, @intCast(rows)) * span) {
                std.debug.print("{d} rows of the widest word: {any}\n", .{ rows, outcome });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// `Prefix.weightOf` as it stood before the run-level fold, for the nullable
/// instantiation: one row at a time, with the checked addition per row and an
/// absent row adding nothing (`column.zig:2172-2181`). The copy, for the
/// reason `metaWeightOfRows` gives.
fn optPrefixWeightOfRows(comptime E: type, slab: *const slabmod.Slab) ParseError!E.Weight {
    var sum: i64 = 0;
    var dec = try E.WireDecoder.init(slab.data);
    var i: usize = 0;
    while (i < slab.len) : (i += 1) {
        const w = (try dec.next()) orelse return error.InvalidValue;
        if (w) |v| sum = std.math.add(i64, sum, std.math.cast(i64, v) orelse return error.Overflow) catch return error.Overflow;
    }
    return .{ .len = slab.len, .prefix = sum };
}

test "the nullable instantiation of the same wire folds the same way, and the non-nullable one refuses its null run" {
    // **The claim is about the wire and not about this codec's payload type.**
    // `MetaPrefixCodec` takes the non-nullable instantiation of the run-length
    // codec — `hexane.Rle(u64)` is `RleWith(Leb128, u64, false, false)`
    // (`rle.zig:1042-1043`), and a metadata word is never absent — but the
    // argument that a run-level fold steps over no refusal has to hold on the
    // nullable arm too, where a null run is a run the fold must *serve* rather
    // than a run it must refuse.
    //
    // **The nullable fold is the crate's own** (`hexane.Prefix`,
    // `column.zig:2059-2061`), so the run-level walk below is production code,
    // and the row walk beside it is a copy of the branch it replaced
    // (`column.zig:2172-2181`).
    const gpa = testing.allocator;
    const Opt = hexane.Prefix(?u64);

    // Three rows of length five, a null run of four, and a literal run of two.
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try leb128.appendSigned(&bytes, gpa, 3);
    try leb128.appendUnsigned(&bytes, gpa, 5);
    try leb128.appendSigned(&bytes, gpa, 0);
    try leb128.appendUnsigned(&bytes, gpa, 4);
    try leb128.appendSigned(&bytes, gpa, -2);
    try leb128.appendUnsigned(&bytes, gpa, 7);
    try leb128.appendUnsigned(&bytes, gpa, 9);
    const owned = try gpa.dupe(u8, bytes.items);
    defer gpa.free(owned);
    const slab: slabmod.Slab = .{ .data = owned, .len = 9, .segments = 0, .tail = .zero };

    const runs = Opt.weightOf(gpa, &slab);
    const rows = optPrefixWeightOfRows(Opt, &slab);
    const a: WalkOutcome = if (runs) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    const b: WalkOutcome = if (rows) |w| .{ .weight = w, .refused = null } else |e| .{ .weight = .{}, .refused = e };
    if (!sameRefusal(a.refused, b.refused) or a.weight.len != b.weight.len or a.weight.prefix != b.weight.prefix) {
        std.debug.print("nullable: over runs {any} | over rows {any}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
    // Three rows of five, four absent rows adding nothing, and two of 7 and 9.
    if (a.refused != null or a.weight.len != 9 or a.weight.prefix != 31) {
        std.debug.print("nullable: {any}, and the model says 31 over nine rows\n", .{a});
        return error.TestUnexpectedResult;
    }

    // **The same bytes on the instantiation `value_meta` is written under**,
    // where the null run is refused at `enterRun` rather than served as the
    // prefix identity — and both walks refuse it, which is the point: the fold
    // does not step over the one run kind it cannot fold.
    {
        const outcome = try sameMetaWeight(gpa, &slab);
        if (!sameRefusal(outcome.refused, error.UnexpectedNull)) {
            std.debug.print("a null run in a column with none: {any}\n", .{outcome});
            return error.TestUnexpectedResult;
        }
    }
    // **And stopping short of it answers**, which is the other half: the three
    // rows carry the values 5, 5 and 5 read as metadata *words*, so each of
    // them declares a length of `5 >> 4 = 0`, and the null run behind them was
    // never opened by either walk.
    {
        const short: slabmod.Slab = .{ .data = owned, .len = 3, .segments = 0, .tail = .zero };
        const outcome = try sameMetaWeight(gpa, &short);
        if (outcome.refused != null or outcome.weight.len != 3 or outcome.weight.prefix != 0) {
            std.debug.print("three rows in front of the null run: {any}\n", .{outcome});
            return error.TestUnexpectedResult;
        }
    }
}
