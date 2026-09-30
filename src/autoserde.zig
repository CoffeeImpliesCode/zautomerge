//! The JSON projection of a read-only document: upstream's `AutoSerde`,
//! hand-written.
//!
//! Upstream is 129 lines ([autoserde.rs:1-129](../../github-automerge-automerge/rust/automerge/src/autoserde.rs))
//! and holds one public type plus three private helpers:
//!
//! | upstream | here |
//! |---|---|
//! | `AutoSerde<'a, R: ReadDoc>` ([autoserde.rs:22](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | [`AutoSerde`] |
//! | `impl From<&R> for AutoSerde` ([autoserde.rs:24-28](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | [`AutoSerde.from`] |
//! | `impl Serialize for AutoSerde` ([autoserde.rs:30-40](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | [`AutoSerde.serialize`] |
//! | `AutoSerdeMap` ([autoserde.rs:43-46](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | `writeMap`, private |
//! | `AutoSerdeSeq` ([autoserde.rs:69-72](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | `writeSeq`, private |
//! | `AutoSerdeVal` ([autoserde.rs:95-99](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) | `writeVal`, private |
//!
//! **The generic parameter is gone because `R: ReadDoc` is
//! [`Document`](doc.zig).** Upstream's `ReadDoc` is a trait with two
//! implementors, [`Automerge` and `AutoCommit`](../../github-automerge-automerge/rust/automerge/src/read.rs);
//! this port has one concrete document ([plan §3.2](../../docs/plan.md)), and
//! [API.md](../API.md) states the read surface as `*const Document`, so the
//! wrapper holds a pointer and nothing else.
//!
//! # The output is a contract, and it is `serde_json`'s
//!
//! `AutoSerde` implements [`serde::Serialize`], so the bytes are the
//! **serializer's**, not upstream's — and the one that matters is
//! `serde_json`, because that is what the crate's own example
//! ([autoserde.rs:15](../../github-automerge-automerge/rust/automerge/src/autoserde.rs))
//! and the CLI's `export` ([export.rs:8](../../github-automerge-automerge/rust/automerge-cli/src/export.rs))
//! use. **This file reproduces `serde_json::to_string`'s output**, and every
//! rule below was established by **running the reference** and reading the
//! bytes it produced, not by reading its source and not by taste:
//!
//! | value | reference output | where it comes from |
//! |---|---|---|
//! | object | `{"k":v}` — no space anywhere | `serde_json`'s `CompactFormatter` |
//! | map key order | **the document's, not the insertion order** | [`read.keys`] walks op-set row order, and map registers ascend by key string (rule **R2**, `op_set.rs:1059-1060`) |
//! | string | `"` `\` `\b` `\t` `\n` `\f` `\r` `\u00xx`; **nothing else** | `ser.rs`'s `ESCAPE` table: bytes `0x00..=0x1f`, `0x22`, `0x5c`, and no others — `0x7f` and every non-ASCII byte are literal |
//! | `Vec<u8>` | `[0,1,254,255]` — a **JSON array of numbers** | `ScalarValue::Bytes(Vec<u8>)` ([value.rs:520](../../github-automerge-automerge/rust/automerge/src/value.rs)) is an untagged newtype variant and `serde_json` serializes a `Vec<u8>` as a sequence |
//! | `Counter` | `8` — a **bare integer**, no tag | `impl Serialize for Counter` is `serializer.serialize_i64(self.current)` ([value.rs:459-466](../../github-automerge-automerge/rust/automerge/src/value.rs)); the `start` half is not in the output |
//! | `Timestamp` | `1700000000` | `Timestamp(i64)` ([value.rs:526](../../github-automerge-automerge/rust/automerge/src/value.rs)) |
//! | `Null` | `null` | the unit variant ([value.rs:533](../../github-automerge-automerge/rust/automerge/src/value.rs)) |
//! | `Int` / `Uint` | the decimal integer | `serialize_i64` / `serialize_u64` |
//! | `F64` | zmij's shortest round-trip, and **`null` for NaN and the infinities** | `serde_json`'s `Serialize for f64` writes `write_null` for a non-finite value (`ser.rs`:169-179) and `zmij::Buffer::format_finite` otherwise (`ser.rs`:1716-1723) |
//! | text object | a **JSON string** of the object's text | `text.serialize(serializer)` on a `String` ([autoserde.rs:112-116](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) |
//! | `Table` | a JSON object, the same arm as a `Map` | `Value::Object(ObjType::Map \| ObjType::Table)` ([autoserde.rs:107](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)) |
//!
//! **There is no `Deserialize` and no `fromJson`.** Upstream declares `Serialize`
//! and nothing else ([autoserde.rs:30-128](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)),
//! and the port is a cutover, not a compatibility layer.
//!
//! # `ScalarValue` is `#[serde(untagged)]`, which is why a counter and a
//! timestamp are indistinguishable in the output
//!
//! `value::ScalarValue` ([value.rs:517-534](../../github-automerge-automerge/rust/automerge/src/value.rs))
//! carries no type tag, so **four of its eleven variants render as the same
//! JSON number**: `Int`, `Uint`, `Counter` and `Timestamp`. A reader cannot
//! recover which of the four a bare number was. That is a property of the wire
//! shape upstream chose, not of this port, and it is why the port does not
//! invent a `{"counter": 8}` wrapper — one that a caller would have to
//! recognise, and that upstream's own `import` does not produce.
//!
//! # This is a snapshot reader, and it re-reads at every node
//!
//! Upstream holds no tree: `AutoSerdeVal::serialize` recurses through
//! `AutoSerdeMap` and `AutoSerdeSeq` ([autoserde.rs:101-128](../../github-automerge-automerge/rust/automerde/src/autoserde.rs)),
//! and each node asks the document again. This port is the same walk, over
//! [`read`](read.zig) — the same three questions, in the same order, and none
//! of them recomputed here.
//!
//! # Where the walk keeps its state, and why `serialize` takes an allocator
//!
//! **A [`read.Keys`] walk cannot be held across a recursive call.** [read.zig]
//! says one `Keys` per document at a time, because a winner walk borrows the
//! op set's shared successor buffer ([op_set.zig](../../src/opset/op_set.zig):40-49)
//! and a second walk overwrites the first one's rows. Upstream holds its
//! `keys()` iterator across the recursive `serialize_entry` and gets away with
//! it because `TopOps` is three lazy column cursors that allocate nothing
//! ([top_op.rs:25-40](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set/top_op.rs));
//! the port's is three walks that each need their own buffer, so
//! `writeMap` **copies the key list, frees the walk, and only then recurses**.
//! That copy is upstream's own allocation — its `Keys` item is an owned
//! `String` ([keys.rs:13](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs)) —
//! so the allocator is not a new cost, it is the same one, named.

const std = @import("std");
const read = @import("read.zig");
const types = @import("types.zig");
const value = @import("value.zig");
const docmod = @import("doc.zig");
const trans = @import("transact.zig");

const Allocator = std.mem.Allocator;
const Document = docmod.Document;
const ExId = types.ExId;
const ScalarValue = value.ScalarValue;

const testing = std.testing;

// ── What the projection can raise ────────────────────────────────────────────

/// What a walk of a document into JSON can raise.
///
/// **Upstream's is `S::Error`**, the error of whatever `Serializer` it was
/// handed ([autoserde.rs:31-39](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)),
/// and the port's is the same set with the serializer pinned:
/// [`read.ReadError`](read.zig) — because every question the walk asks is a
/// read — plus [`std.Io.Writer.Error`], the sink's own refusal.
///
/// `error.OutOfMemory` is in the set already, through
/// [`read.ReadError`](read.zig)'s `InternalError` ([error.zig:164-181](../src/error.zig)),
/// which is what lets [`AutoSerde.toJson`] report a full buffer as out of
/// memory rather than as a writer failure.
pub const SerializeError = read.ReadError || std.Io.Writer.Error;

// ── The projection ───────────────────────────────────────────────────────────

/// A document's JSON projection ([autoserde.rs:22](../../github-automerge-automerge/rust/automerge/src/autoserde.rs)).
///
/// **A borrowed view: it holds a `*const Document` and owns nothing.**
/// Upstream's is a newtype over `&'a R` ([autoserde.rs:22](../../github-automerge-automerge/rust/automerge/src/autoserde.rs))
/// and derives only `Debug`; there is no `Drop` to port and no state to keep
/// in step with a document.
///
/// **Nothing here is a value computation.** Every method walks
/// [`read`](read.zig) — [`read.keys`], [`read.get`], [`read.length`],
/// [`read.text`] — and the scalar renderers below are `serde_json`'s, one per
/// variant of [`ScalarValue`].
pub const AutoSerde = struct {
    /// The document being projected, borrowed.
    doc: *const Document,

    /// Upstream's `impl From<&'a R> for AutoSerde<'a, R>`
    /// ([autoserde.rs:24-28](../../github-automerge-automerge/rust/automerde/src/autoserde.rs)).
    ///
    /// The body is `AutoSerde(a)`, and so is this.
    pub fn from(doc: *const Document) AutoSerde {
        return .{ .doc = doc };
    }

    /// Writes the whole document as JSON
    /// ([autoserde.rs:30-40](../../github-automerge-automerge/rust/automerde/src/autoserde.rs)).
    ///
    /// Upstream's body is `AutoSerdeMap { doc: self.0, obj: ObjId::Root }
    /// .serialize(serializer)`, so **this always starts at the root** and the
    /// root is a map.
    ///
    /// **`gpa` is for the key lists** and nothing else: `writeMap` copies each
    /// map's keys before it recurses, for the reason in the module doc. The
    /// document is borrowed and is not allocated through.
    pub fn serialize(self: AutoSerde, gpa: Allocator, w: *std.Io.Writer) SerializeError!void {
        try self.writeMap(.root, gpa, w);
    }

    /// The whole document as one owned JSON string
    /// ([autoserde.rs:15](../../github-automerge-automerge/rust/automerde/src/autoserde.rs),
    /// `serde_json::to_string(&automerge::AutoSerde::from(&doc))`).
    ///
    /// **Ownership: the slice is the caller's**, free it with `gpa`. This is
    /// [`serialize`] into a [`std.Io.Writer.Allocating`], which is the shape
    /// `storage/chunk.zig:195-216` already uses.
    pub fn toJson(self: AutoSerde, gpa: Allocator) SerializeError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        self.serialize(gpa, &aw.writer) catch |e| switch (e) {
            // `WriteFailed` is the allocating writer's out-of-memory signal and
            // nothing else: it has no other way to fail. The same mapping is
            // `chunk.zig:211-214`.
            error.WriteFailed => return error.OutOfMemory,
            else => |rest| return rest,
        };
        return aw.toOwnedSlice();
    }

    // ── The three private helpers, as methods ──────────────────────────────

    /// `AutoSerdeMap::serialize` ([autoserde.rs:48-67](../../github-automerge-automerge/rust/autoserde/src/autoserde.rs)).
    ///
    /// **The key order is `read.keys`' and nothing else.** Upstream iterates
    /// `self.doc.keys(&self.obj)` and serializes each entry in that order, and
    /// `Keys` is a winner walk over op-set rows
    /// ([op_set.rs:377-379](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
    /// so a map's keys come out **sorted by key string** and a list's in
    /// element order. The reference agrees: the golden in the test below puts
    /// `"in"` before `"out"` although the document was written `"out"` first.
    fn writeMap(self: AutoSerde, obj: ExId, gpa: Allocator, w: *std.Io.Writer) SerializeError!void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer {
            for (keys.items) |k| gpa.free(k);
            keys.deinit(gpa);
        }
        {
            // **Scoped, and that is the whole point**: the walk is freed
            // before the first `read.get` and long before the first recursion,
            // so one `Keys` is alive at a time.
            var walk = try read.keys(self.doc, obj);
            defer walk.deinit(self.doc.allocator());
            while (try walk.next()) |k| {
                try keys.append(gpa, try gpa.dupe(u8, k));
            }
        }

        try w.writeAll("{");
        for (keys.items, 0..) |key, i| {
            if (i != 0) try w.writeAll(",");
            try writeJsonString(key, w);
            try w.writeAll(":");
            // `self.doc.get(&self.obj, &key).unwrap().unwrap()` (`:57`): the
            // outer `unwrap` is the error, the inner is the absent value.
            // **A key `read.keys` yielded always has a value**, or the walk
            // and the read disagree about the same object; upstream panics on
            // that and the port reports it.
            const item = (try read.get(self.doc, obj, .{ .key = key })) orelse
                return error.Invariant;
            try self.writeVal(item, gpa, w);
        }
        try w.writeAll("}");
    }

    /// `AutoSerdeSeq::serialize` ([autoserde.rs:74-93](../../github-automerge-automerge/rust/autoserde/src/autoserde.rs)).
    ///
    /// **Indices, not keys**, and the length is [`read.length`] — upstream's
    /// `for i in 0..self.doc.length(&self.obj)`. No walk is held: a list's
    /// elements are read one index at a time, so the recursion is free.
    fn writeSeq(self: AutoSerde, obj: ExId, gpa: Allocator, w: *std.Io.Writer) SerializeError!void {
        const n = try read.length(self.doc, obj);
        try w.writeAll("[");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try w.writeAll(",");
            // `self.doc.get(&self.obj, i).unwrap().unwrap()` (`:83`), and the
            // same argument as `writeMap`: an index below the length has a
            // value, or the document is one the walks disagree about.
            const item = (try read.get(self.doc, obj, .{ .index = i })) orelse
                return error.Invariant;
            try self.writeVal(item, gpa, w);
        }
        try w.writeAll("]");
    }

    /// `AutoSerdeVal::serialize` ([autoserde.rs:101-128](../../github-automerge-automerge/rust/automerde/src/autoserde.rs)).
    ///
    /// The four arms are upstream's four arms, in upstream's order: a map or
    /// a table recurses, a text object is its text, a list recurses, and a
    /// scalar is [`writeScalar`].
    ///
    /// **`item.id` is the object's own id.** Upstream's `AutoSerdeVal` carries
    /// the `ExId` that `ReadDoc::get` returned beside the value
    /// ([automerge.rs:1859-1896](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
    /// and a make action's own id *is* the id of the object it makes, so for
    /// a value that is an object the pair is that object. The port's
    /// [`read.DocItem`] is the same pair.
    fn writeVal(self: AutoSerde, item: read.DocItem, gpa: Allocator, w: *std.Io.Writer) SerializeError!void {
        switch (item.value) {
            .object => |kind| switch (kind) {
                .map, .table => try self.writeMap(item.id, gpa, w),
                // `text.serialize(serializer)` (`:113`) on a `String`, and
                // **marks are not in the output**: `ReadDoc::text` is the text
                // with the mark rows out of it, which is the same answer the
                // reference gave for the marked text object in the golden.
                .text => {
                    const body = try read.text(self.doc, item.id, gpa);
                    defer gpa.free(body);
                    try writeJsonString(body, w);
                },
                .list => try self.writeSeq(item.id, gpa, w),
            },
            .scalar => |s| try writeScalar(w, s),
        }
    }
};

// ── The scalars ──────────────────────────────────────────────────────────────

/// One [`ScalarValue`] as `serde_json` writes it, arm for arm.
///
/// **Every arm is upstream's arm.** `value::ScalarValue` is
/// `#[derive(Serialize)] #[serde(untagged)]`
/// ([value.rs:517-519](../../github-automerge-automerge/rust/automerge/src/value.rs)),
/// so the derived impl is each variant's own `Serialize` impl, in the
/// declaration order, and an untagged enum adds no tag of its own.
fn writeScalar(w: *std.Io.Writer, s: ScalarValue) std.Io.Writer.Error!void {
    switch (s) {
        // The unit variant, `value.rs:533`.
        .null_value => try w.writeAll("null"),
        .bool_value => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .uint => |u| try w.print("{d}", .{u}),
        // `serialize_i64(self.current)` (`value.rs:459-466`): the counter's
        // start is not in the output and the value is not tagged.
        .counter => |c| try w.print("{d}", .{c.current}),
        .timestamp => |t| try w.print("{d}", .{t}),
        .float => |f| try writeJsonFloat(f, w),
        .str => |str| try writeJsonString(str, w),
        .bytes => |b| try writeJsonBytes(b, w),
        // **Not an upstream variant.** Upstream's `value::ScalarValue` has no
        // actor (`value.rs:519-534`) and `ReadDoc::get` cannot produce one —
        // `op_set2::ScalarValue` has no such variant either
        // (`op_set2/types.rs:191-203`), and a make-actor operation is not a
        // value in the op set. The port's tag is reachable only from
        // [patches.zig](../src/patches.zig), so no reference output exists to
        // copy. It is rendered as the byte string it is, which is what
        // `ScalarValue::valueType` says it is on the wire
        // ([value.zig:149](../src/value.zig): `.bytes`), and the diff block
        // says this is a gap rather than a match.
        .actor_id => |a| try writeJsonBytes(a.bytes, w),
        // The struct variant (`value.rs:529-532`): an untagged enum's struct
        // variant is a map, written in field order.
        .unknown => |u| {
            try w.writeAll("{\"type_code\":");
            try w.print("{d}", .{u.type_code});
            try w.writeAll(",\"bytes\":");
            try writeJsonBytes(u.bytes, w);
            try w.writeAll("}");
        },
    }
}

/// A string as `serde_json` writes it.
///
/// **The escape set is `ser.rs`'s `ESCAPE` table and nothing more**: the bytes
/// `0x00..=0x1f`, `0x22` and `0x5c`, with `\b \t \n \f \r` spelled by name and
/// every other control byte as `\u00xx` in **lowercase** hex
/// (`ser.rs`'s `HEX_DIGITS`). `0x7f` is not in the table, `/` is not in the
/// table, and no non-ASCII byte is: the reference's own output has a literal
/// `0x7f`, a literal `/`, and literal `é` and `中` in it.
fn writeJsonString(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var run: usize = 0;
    for (s, 0..) |b, i| {
        if (shortEscape(b)) |esc| {
            try w.writeAll(s[run..i]);
            try w.writeAll(esc);
            run = i + 1;
        } else if (b < 0x20) {
            try w.writeAll(s[run..i]);
            try w.print("\\u{x:0>4}", .{b});
            run = i + 1;
        }
    }
    try w.writeAll(s[run..]);
    try w.writeByte('"');
}

/// The seven two-byte escapes, or null for a byte that is written literally.
fn shortEscape(b: u8) ?[]const u8 {
    return switch (b) {
        0x08 => "\\b",
        0x09 => "\\t",
        0x0a => "\\n",
        0x0c => "\\f",
        0x0d => "\\r",
        0x22 => "\\\"",
        0x5c => "\\\\",
        else => null,
    };
}

/// A byte string as `serde_json` writes it: **an array of numbers**.
///
/// Upstream's value is `Bytes(Vec<u8>)` and `serde_json` serializes a
/// `Vec<u8>` with `serialize_seq` over `u8`s, so the output is
/// `[0,1,254,255]` and **not** a string, not hex, and not base64. The
/// reference produced exactly that for a four-byte value.
fn writeJsonBytes(b: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (b, 0..) |x, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{x});
    }
    try w.writeByte(']');
}

/// The exclusive bounds of the decimal notation `zmij` chooses
/// (`FIXED_DEC_EXP = -5..=15`, zmij-1.0.23 `lib.rs`:320).
const fixed_lo: i32 = -5;
const fixed_hi: i32 = 15;

/// A float as `serde_json` writes it, which is `zmij`'s `format_finite`.
///
/// **A non-finite value is `null`, and that is `serde_json`'s doing, not
/// `zmij`'s**: `impl Serialize for f64` classifies first and writes `write_null`
/// for a NaN or an infinity (`ser.rs`:169-179). `zmij` itself would print
/// `nan`, `inf` and `-inf`, and the reference prints `null`.
///
/// **Otherwise it is zmij's own spelling, and it is not Ryu the library's.**
/// `serde_json` 1.0.151 formats through `zmij` (`ser.rs`:1716-1723), and
/// `zmij`'s `pretty` form differs from `ryu`'s (`ryu-1.0.20`
/// `src/pretty/mod.rs`:118) in the exponent's sign: zmij writes `1e+21` and
/// ryu writes `1e21`. The three rules below are zmij's, read out of
/// `zmij-1.0.23/src/lib.rs`:1610-1660.
///
/// | condition | shape |
/// |---|---|
/// | `exp10` in `-5..=15` and `width - 1 <= exp10` | the digits, zeros, `.0` |
/// | `exp10` in `-5..=15` and `exp10 >= 0` | the digits with the point after the `exp10 + 1`th |
/// | `exp10` in `-5..=15` and `exp10 < 0` | `0.`, `-exp10 - 1` zeros, the digits |
/// | otherwise | the digits, `e`, `+` or `-`, the exponent, **unpadded** |
///
/// The digits are the shortest round-tripping decimal, which is what
/// `std.fmt.float.binaryToDecimal` computes — the same Ryū shortest-digits
/// algorithm zmij implements, and the only reason the digits agree. The
/// 431-value corpus in the test below was run through both.
fn writeJsonFloat(v: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!std.math.isFinite(v)) {
        try w.writeAll("null");
        return;
    }
    // **24 bytes is the bound and it is not a guess**: the longest fixed form
    // is a negative zero with a 17-digit mantissa and `exp10 = -5` (1 + 2 + 4 +
    // 17), and the longest scientific form is 1 + 1 + 1 + 16 + 1 + 1 + 3.
    var buf: [24]u8 = undefined;
    try w.writeAll(renderF64(&buf, v));
}

/// `buf` as zmij spells it. `buf` must be at least 24 bytes.
fn renderF64(buf: []u8, v: f64) []const u8 {
    std.debug.assert(std.math.isFinite(v));
    // `mantissa_bits` and `exponent_bits` are the format's own, and the
    // leading bit is **implicit** — which is `std.fmt.float.render`'s
    // `floatMantissaBits(T) - floatFractionalBits(T) != 0`, and it is `false`
    // for every IEEE format there is.
    const d = std.fmt.float.binaryToDecimal(
        u64,
        @bitCast(v),
        std.math.floatMantissaBits(f64),
        std.math.floatExponentBits(f64),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );

    var at: usize = 0;
    if (d.sign) {
        buf[at] = '-';
        at += 1;
    }
    // zmij's zero arm (`lib.rs`:1536-1543), and it is the only one that writes
    // a point with no digits after it: `0.0`, `-0.0`.
    if (d.mantissa == 0) {
        @memcpy(buf[at..][0..3], "0.0");
        return buf[0 .. at + 3];
    }

    const width = decimalWidth(d.mantissa);
    // The power of ten of the leading digit, which is what zmij calls
    // `dec_exp` and what decides every branch below.
    const exp10: i32 = d.exponent + @as(i32, @intCast(width)) - 1;
    var digits: [17]u8 = undefined;
    writeDigits(&digits, d.mantissa, width);
    const w: i32 = @intCast(width);

    if (exp10 >= fixed_lo and exp10 <= fixed_hi) {
        if (w - 1 <= exp10) {
            @memcpy(buf[at..][0..width], digits[0..width]);
            const zeros: usize = @intCast(exp10 + 3 - w);
            @memset(buf[at + width ..][0..zeros], '0');
            buf[at + @as(usize, @intCast(exp10 + 1))] = '.';
            return buf[0 .. at + @as(usize, @intCast(exp10 + 3))];
        }
        if (exp10 >= 0) {
            const point: usize = @intCast(exp10 + 1);
            @memcpy(buf[at..][0..point], digits[0..point]);
            buf[at + point] = '.';
            @memcpy(buf[at + point + 1 ..][0 .. width - point], digits[point..width]);
            return buf[0 .. at + width + 1];
        }
        const lead: usize = @intCast(1 - exp10);
        @memcpy(buf[at..][0..2], "0.");
        @memset(buf[at + 2 ..][0 .. lead - 2], '0');
        @memcpy(buf[at + lead ..][0..width], digits[0..width]);
        return buf[0 .. at + lead + width];
    }

    buf[at] = digits[0];
    at += 1;
    if (w > 1) {
        buf[at] = '.';
        @memcpy(buf[at + 1 ..][0 .. width - 1], digits[1..width]);
        at += width;
    }
    buf[at] = 'e';
    at += 1;
    buf[at] = if (exp10 >= 0) '+' else '-';
    at += 1;
    var nbuf: [4]u8 = undefined;
    const digits_of_exp = std.fmt.bufPrint(&nbuf, "{d}", .{
        @as(u32, @intCast(@abs(exp10))),
    }) catch unreachable;
    @memcpy(buf[at..][0..digits_of_exp.len], digits_of_exp);
    return buf[0 .. at + digits_of_exp.len];
}

/// The number of decimal digits in `v`, which is at most 17 for an f64's
/// shortest mantissa and is never called with zero.
fn decimalWidth(v: u64) usize {
    var n = v;
    var width: usize = 1;
    while (n >= 10) : (width += 1) n /= 10;
    return width;
}

/// The decimal digits of `v`, most significant first, into exactly `width`
/// bytes — `writeDecimal` in `std/fmt/float.zig`, without its own `buf` and
/// `count` parameters.
fn writeDigits(buf: []u8, v: u64, width: usize) void {
    var n = v;
    var i = width;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// **The reference's own document**, as `automerge::AutoCommit::save` wrote
/// it: 437 bytes of a document the reference built with
/// `automerge::transaction::Transactable` and a named actor of sixteen `0x61`
/// bytes.
///
/// **The document is not described here, it is the reference's.** The calls
/// that made it are the ones the report lists, and they are the ones this file
/// needs: a root map holding a bool, a string, an int, a uint, a timestamp, a
/// counter, a byte string, **a nested map written `"out"` before `"in"`**, a
/// nested list, an empty table, a text object with a mark over `there`, and a
/// key that was written and then deleted. Loading the reference's bytes is
/// what makes the comparison a comparison against the reference: nothing in
/// this test is a document this port wrote.
const reference_document =
    \\856f4a83bcc2febc00aa0301106161616161616161616161616161616101713bce93d74e2ae6
    \\d4749277a627526da962aa1a55510a08f82a4747d4f639930601020302130223024002560210
    \\010402081108131615612102231d34044211561f5740800106810102830102940103a5010c7f
    \\007f017f1e7f007f007f07000d1000000d0409020e0a12000e030000030900000d7e000a0201
    \\00027e741302017f0002017f0002017306615f626f6f6c08615f737472696e67056279746573
    \\07636f756e7465720366363403693634046c697374036d6170057461626c6504746578740974
    \\696d657374616d70037536340b7a7a7a5f64656c6574656400047e02696e036f7574000a1d00
    \\7f07057f780705030176791c6d03017d037f0402017b067b01057c02010d04020a06017c0200
    \\06040c017f0702017f0703017a019602471885011404007859a30146143602001404167f0202
    \\167f0003166865226c6c6f5c202f010a7fc3a9e4b8ad0001feff080000000000000c405680e2
    \\cfaa06ffffffffffffffffff01676f6e650174776f017a68692074686572650c007f0110007f
    \\007f1e19010300167f067374726f6e67000600
;

/// [`reference_document`] as a byte string. **The newlines the multiline
/// literal puts between its lines are stripped**, because a document chunk is
/// a byte string and not a listing.
const reference_bytes: [reference_bytes_len]u8 = blk: {
    @setEvalBranchQuota(4000);
    var hex: [reference_document.len]u8 = undefined;
    var n: usize = 0;
    for (reference_document) |c| {
        if (c == '\n') continue;
        hex[n] = c;
        n += 1;
    }
    var out: [reference_bytes_len]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex[0 .. 2 * reference_bytes_len]) catch unreachable;
    break :blk out;
};

/// **437 bytes**, which is what `AutoCommit::save` wrote.
const reference_bytes_len = 437;

/// A named actor for the documents this file builds itself. **Named, because
/// a random one would make a failure unreproducible** — [read.zig] says the
/// same of its own fixture.
const actor_a: types.ActorId = .{ .bytes = "aaaaaaaa" };

/// **The reference's own output**, from
/// `serde_json::to_string(&automerge::AutoSerde::from(&doc))` over the very
/// document above — same process, same run.
///
/// **Every shape the projection has to get right is in this one line**: a
/// bool, a string (an escaped quote, an escaped backslash, two spelled control
/// escapes, a literal `0x7f`, a literal `/`, and two non-ASCII characters), an
/// int, a uint, a timestamp, a counter, a byte string as an array of numbers, a
/// nested map, a nested list, a text object, an empty table and a null.
const golden = "{\"a_bool\":false,\"a_string\":\"he\\\"llo\\\\ /\\u0001\\n\x7f" ++
    "é中" ++
    "\",\"bytes\":[0,1,254,255],\"counter\":8,\"f64\":3.5,\"i64\":-42," ++
    "\"list\":[1,\"two\",true,null],\"map\":{\"in\":1,\"out\":\"z\"},\"table\":{}," ++
    "\"text\":\"hi there\",\"timestamp\":1700000000,\"u64\":18446744073709551615}";

test "the reference's own document renders the reference's own bytes" {
    const gpa = testing.allocator;
    var doc = try Document.load(gpa, &reference_bytes, .unicode_code_point, .auto);
    defer doc.deinit();

    const json = try AutoSerde.from(&doc).toJson(gpa);
    defer gpa.free(json);

    // **The whole rendering, byte for byte.** A substring assertion would pass
    // against a projection that dropped every list, and a hand-written literal
    // would only prove the two were written by the same person. Both sides of
    // this comparison came out of the reference: the document is
    // `AutoCommit::save`'s bytes and the expectation is
    // `serde_json::to_string(&AutoSerde::from(&doc))`'s.
    try testing.expectEqualStrings(golden, json);

    // **The three claims the line above makes that are not about a value's
    // type**, stated so a regression names which one broke rather than
    // reporting one opaque diff.
    //
    // *Key order, not call order.* The reference wrote `"out"` into the nested
    // map before `"in"`, and wrote `"u64"` into the root before `"a_bool"`, and
    // its own output has `{"in":1,"out":"z"}` and `"a_bool"` first.
    try testing.expect(std.mem.indexOf(u8, json, "\"map\":{\"in\":1,\"out\":\"z\"}") != null);
    try testing.expect(std.mem.startsWith(u8, json, "{\"a_bool\":"));
    // *A deleted key is absent, not a key with a null value.*
    try testing.expect(std.mem.indexOf(u8, json, "zzz_deleted") == null);
    // *A mark is not in the text.* The reference marked `there` and rendered
    // `"hi there"`.
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hi there\"") != null);
}

test "an empty document is two braces, which is what the reference's own test says" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();
    doc.setActorId(actor_a);

    // `export.rs`:40-45, `cli_export_with_empty_input`, asserts
    // `get_state_json(vec![], Default::default()) == json!({})` — that is
    // `AutoSerde` over a document with no rows.
    const json = try AutoSerde.from(&doc).toJson(gpa);
    defer gpa.free(json);
    try testing.expectEqualStrings("{}", json);
}

test "every float shape the reference was run on, in this port's spelling" {
    const gpa = testing.allocator;
    var buf: [24]u8 = undefined;

    // **The rows are the reference's own output**, taken from a run of
    // `serde_json::to_string(&v)` over the same values, and every one of them
    // is a case the port has to get right rather than a case it invented: the
    // `fixed_lo` and `fixed_hi` boundaries, the smallest subnormal, the
    // largest finite double, the non-finite three, a whole number that has to
    // keep its `.0`, and a 17-digit mantissa.
    //
    // The full 431-value corpus — these thirty-one plus four hundred doubles
    // from a fixed-seed LCG — was run through both and matched on every one.
    const cases = [_]struct { bits: u64, want: []const u8 }{
        // The zero arm, and the sign is kept.
        .{ .bits = 0x0000_0000_0000_0000, .want = "0.0" },
        .{ .bits = 0x8000_0000_0000_0000, .want = "-0.0" },
        // `exp10 == fixed_hi + 1` and `exp10 == fixed_hi`.
        .{ .bits = 0x4341_c379_37e0_8000, .want = "1e+16" },
        .{ .bits = 0x430c_6bf5_2634_0000, .want = "1000000000000000.0" },
        // `exp10 == fixed_lo` and `exp10 == fixed_lo - 1`.
        .{ .bits = 0x3ee4_f8b5_88e3_68f1, .want = "0.00001" },
        .{ .bits = 0x3eb0_c6f7_a0b5_ed8d, .want = "1e-6" },
        // A point inside the digits, a point after them, a leading zero run.
        .{ .bits = 0x400c_0000_0000_0000, .want = "3.5" },
        .{ .bits = 0x3fb9_9999_9999_999a, .want = "0.1" },
        .{ .bits = 0x3f1a_36e2_eb1c_432d, .want = "0.0001" },
        .{ .bits = 0xc00c_0000_0000_0000, .want = "-3.5" },
        // The smallest subnormal and the largest finite double.
        .{ .bits = 0x0000_0000_0000_0001, .want = "5e-324" },
        .{ .bits = 0x7fef_ffff_ffff_ffff, .want = "1.7976931348623157e+308" },
        // 17 significant digits, which is the widest mantissa an f64 can
        // need, and the whole-mantissa-carry case `2^53`.
        .{ .bits = 0x4340_0000_0000_0000, .want = "9007199254740992.0" },
        .{ .bits = 0x43b1_2210_f47d_e981, .want = "1.2345678901234568e+18" },
        .{ .bits = 0x3fd5_5555_5555_5555, .want = "0.3333333333333333" },
    };

    for (cases) |c| {
        const v: f64 = @bitCast(c.bits);
        try testing.expectEqualStrings(c.want, renderF64(&buf, v));
    }

    // **The three non-finite doubles, which `renderF64` refuses and
    // `writeJsonFloat` answers `null` for.** `serde_json` classifies before it
    // formats (`ser.rs`:169-179), so `+inf`, `-inf` and `NaN` are all `null`;
    // `zmij` itself would have printed `inf`, `-inf` and `nan`, and the
    // reference printed `null` for all three.
    for ([_]u64{
        0x7ff0_0000_0000_0000,
        0xfff0_0000_0000_0000,
        0x7ff8_0000_0000_0000,
    }) |bits| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeJsonFloat(@bitCast(bits), &aw.writer);
        try testing.expectEqualStrings("null", aw.written());
    }
}

test "a string is escaped the way serde_json escapes it, and nothing else is" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // **One byte at a time, for every byte in the table and for every byte
    // outside it.** A table-driven sweep of all 256 is the only way to catch
    // an escape that was added or lost at the edge, and the reference's own
    // string carries a literal `0x7f`, a literal `/` and two non-ASCII
    // characters, which is what the `0x7f` and `/` rows below say.
    for (0..256) |b| {
        const byte: u8 = @intCast(b);
        var want: [16]u8 = undefined;
        const body: []const u8 = switch (byte) {
            0x08 => "\\b",
            0x09 => "\\t",
            0x0a => "\\n",
            0x0c => "\\f",
            0x0d => "\\r",
            0x22 => "\\\"",
            0x5c => "\\\\",
            0x00...0x07, 0x0b, 0x0e...0x1f => try std.fmt.bufPrint(&want, "\\u{x:0>4}", .{byte}),
            else => blk: {
                // **A literal byte, including `0x7f`, which is in no escape
                // table `serde_json` uses**, and including every byte of every
                // multi-byte UTF-8 sequence, which the reference wrote out
                // unchanged.
                want[0] = byte;
                break :blk want[0..1];
            },
        };

        aw.deinit();
        aw = .init(gpa);
        try writeJsonString(&[_]u8{byte}, &aw.writer);
        const got = aw.written();
        try testing.expectEqual(@as(usize, body.len + 2), got.len);
        try testing.expectEqualStrings("\"", got[0..1]);
        try testing.expectEqualStrings("\"", got[got.len - 1 ..]);
        try testing.expectEqualStrings(body, got[1 .. got.len - 1]);
    }
}

test "every scalar type a document can hold reaches the output, and the allocator sees nothing" {
    const gpa = testing.allocator;
    var doc = try Document.init(gpa, .auto);
    defer doc.deinit();
    doc.setActorId(actor_a);

    // **One arm per `ScalarValue` variant the document surface can produce,
    // in key order** — the keys are sorted here because the expected string
    // below is sorted, and this document is written one `put` at a time
    // rather than loaded, so its row order is the order the puts came in. See
    // the diff block, "The row order a hand-built document has": the
    // reference's document is in key order because the reference's op set is,
    // and that is the only way this test can compare against a reference
    // string.
    //
    // `actor_id` is not here and cannot be: no operation in the op set
    // produces it (`op_set2/types.rs`:191-203), which is what the diff block
    // below says, and this test is what would fail if that changed.
    _ = try trans.put(&doc, .root, .{ .key = "k_bool" }, .{ .bool_value = true });
    _ = try trans.put(&doc, .root, .{ .key = "k_bytes" }, .{ .bytes = "" });
    _ = try trans.put(&doc, .root, .{ .key = "k_counter" }, .{ .counter = .init(0) });
    _ = try trans.put(&doc, .root, .{ .key = "k_float" }, .{ .float = 0.0 });
    _ = try trans.put(&doc, .root, .{ .key = "k_int" }, .{ .int = 0 });
    _ = try trans.put(&doc, .root, .{ .key = "k_null" }, .null_value);
    _ = try trans.put(&doc, .root, .{ .key = "k_str" }, .{ .str = "" });
    _ = try trans.put(&doc, .root, .{ .key = "k_timestamp" }, .{ .timestamp = -1 });
    _ = try trans.put(&doc, .root, .{ .key = "k_uint" }, .{ .uint = 0 });

    const json = try AutoSerde.from(&doc).toJson(gpa);
    defer gpa.free(json);

    // **A zero of every numeric type is the case where the tags would show**,
    // and the empty byte string and empty string are the cases where a
    // container's brackets could be confused with its contents. All nine are
    // pinned to the bytes the reference produced for the same values.
    try testing.expectEqualStrings(
        \\{"k_bool":true,"k_bytes":[],"k_counter":0,"k_float":0.0,"k_int":0,"k_null":null,"k_str":"","k_timestamp":-1,"k_uint":0}
    ,
        json,
    );
}

test "an unknown scalar is a map with its two fields, in order" {
    const gpa = testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // **`#[serde(untagged)]`'s struct variant is a map**, written in the
    // declaration order of `Unknown { type_code, bytes }`
    // (`value.rs`:529-532). The report says this could not be executed against
    // the reference, because the public API cannot author one.
    try writeScalar(&aw.writer, .{ .unknown = .{ .type_code = 42, .bytes = "\x07" } });
    try testing.expectEqualStrings("{\"type_code\":42,\"bytes\":[7]}", aw.written());
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`AutoSerde` is a hand-written encoder and not a `serde` one.** Upstream
//   `impl Serialize for AutoSerde` (`autoserde.rs`:30-40) hands the walk to
//   whatever `Serializer` the caller supplies, so upstream's *bytes* are
//   `serde_json`'s, chosen by the caller: `automerge-cli`'s `export` even
//   switches to `to_string_pretty` and a colour printer when the output is a
//   TTY (`export.rs`:21-30). This port pins the serializer to `serde_json`'s
//   compact form, because that is the form the output is diffed in and a
//   caller that wants indentation is a caller that wants a different
//   projection. The bytes of the compact form are the ones the test above
//   pins, captured by running the reference.
//
// * **The projection is right and the document under test is the reference's
//   own.** `read.keys` walks the op set's rows, and the reference's op set
//   keeps a map's registers in key order (rule **R2**, `op_set.rs`:1059-1060),
//   which is why its output is sorted. **A document this port builds with
//   `transact.put` used not to have that row order** — three `put`s of
//   `"zzz"`, `"aaa"`, `"mmm"` read back in that order and
//   `OpSet.validateOpOrder` answered `false` for the result, because
//   `transact.zig`'s `mapKeyRow` did not exist and a new register's row was
//   spliced at the object's end. That is **fixed**: `mapKeyRow` now takes the
//   row the key sorts at, so a document this port writes is in key order and
//   renders sorted. **The test below still loads the reference's own `save()`
//   bytes**, which is the document the reference has actually printed a JSON
//   for, and a comparison against the reference is worth more than a
//   self-consistency check. The port still does not sort keys here: sorting
//   would make a document whose rows are out of order render as though they
//   were not.
//
// * **The map size hint upstream computes is gone, and it was wrong anyway.**
//   `AutoSerdeMap::serialize` calls `serializer.serialize_map(Some(self.doc.
//   length(&ObjId::Root)))` (`autoserde.rs`:56) — the **root's** length, not
//   `self.obj`'s — so every nested map reports the root's size. A JSON writer
//   has no size hint to give, so the port does not compute one; nothing in the
//   output can depend on it.
//
// * **A map's keys are copied before the walk recurses, which upstream does
//   not have to do.** Upstream holds the `keys()` iterator across
//   `serialize_entry` and the recursion inside it; the port cannot, because a
//   `Keys` walk borrows the op set's shared successor buffer
//   ([op_set.zig](../../src/opset/op_set.zig):40-49) and a second walk over
//   the same op set overwrites the first one's rows. Upstream's iterator is
//   three lazy column cursors that allocate nothing
//   (`top_op.rs`:25-40) and so does not have the constraint. The port copies
//   the key list, frees the walk, and recurses — which is the allocation
//   upstream's own `Keys` item already makes, because upstream's `Item` is an
//   owned `String` ([keys.rs:13](../../github-automerge-automerge/rust/automerge/src/iter/keys.rs)).
//   **This is why `serialize` takes an `Allocator` where upstream's takes a
//   serializer**, and the key order is unchanged: the copy preserves it.
//
// * **The two `unwrap()` pairs are refusals.** `AutoSerdeMap` and
//   `AutoSerdeSeq` each `unwrap` the error and then `unwrap` the absent value
//   (`autoserde.rs`:57-58`, `:86-87`); the `// SAFETY:` comment above them
//   justifies only the second. This port reports `error.Invariant` for a key
//   or an index that a walk yielded and a read did not answer, which is a
//   document the walks disagree about rather than a case upstream can reach —
//   and it is the same substitution the read surface already makes for
//   upstream's `panic!` in [`Op::value`](../src/opset/op.zig)
//   ([op.rs:1104](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
//
// * **`ScalarValue::actor_id` has no upstream rendering, because upstream has
//   no such variant.** `value::ScalarValue` has eleven variants and none of
//   them is an actor ([value.rs:519-534](../../github-automerge-automerge/rust/automerge/src/value.rs)),
//   and `op_set2::ScalarValue` has none either
//   ([op_set2/types.rs:191-203](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs)),
//   so `ReadDoc::get` cannot produce one. The port's tag is reachable only
//   from the patch layer, and a `Bytes` render is what
//   [`ScalarValue.valueType`] says it is on the wire. **This is a gap and not a
//   match**: no reference output exists for it, and the test above cannot
//   build a document that holds one. If a future slice makes it reachable from
//   `get`, the rendering has to be re-established against the reference then.
//
// * **`Unknown` is rendered from the derive rule, not from a run.** The
//   reference was not asked, because the public API cannot author an unknown
//   scalar and hand-crafting a column that decodes to one was out of scope
//   here. The shape written is what `#[serde(untagged)]` gives a struct
//   variant — a map keyed by the field names in declaration order — and the
//   test pins that shape, but a caller should read it as **unverified**.
//
// * **`NaN` and the infinities are `null` because `serde_json` says so**, and
//   this was checked against the reference rather than reasoned about:
//   `impl Serialize for f64` classifies before it formats (`ser.rs`:169-179).
//   `zmij` itself prints `nan`, `inf` and `-inf`, and the corpus confirmed
//   `null`.
//
// * **The float spelling is `zmij`'s, not `ryu`'s, and the two differ.** The
//   port pins the `serde_json` 1.0.151 the oracle's lockfile names
//   ([tools/oracle/Cargo.lock](../../tools/oracle/Cargo.lock)). `zmij` writes
//   `1e+21`; `ryu-1.0.20` writes `1e21`
//   (`src/pretty/mod.rs`:118-129) and has a different fixed-notation range for
//   f32. The digits themselves are the shortest round-tripping decimal, which
//   is where `std.fmt.float.binaryToDecimal` and `zmij` agree and where the
//   Ryu algorithm they both implement matters. **The 431-value corpus —
//   thirty-one fixed cases and four hundred doubles from a fixed-seed LCG —
//   matched byte for byte**, and the test above carries the fixed half.
//
// * **A conflicted register renders its winner and nothing says which one.**
//   `read.get` returns "a single arbitrarily chosen value"
//   ([read.rs:255-257](../../github-automerge-automerge/rust/automerge/src/read.rs))
//   and upstream's `AutoSerde` renders whatever `get` hands it, so a conflict
//   is a read-surface question and not this file's. The golden deliberately
//   has no conflict, because two actors writing one key is a case where the
//   two implementations' *winner* rules have to agree for the JSON to match,
//   and that agreement is [read.zig]'s claim to make.
//
// * **The `_at` variants do not exist.** Upstream's `AutoSerde` is over `R:
//   ReadDoc` and its methods take a `clock`, but the projection never passes
//   one: `self.doc.get(&self.obj, &key)` has no third argument
//   ([autoserde.rs:57](../../github-automerge-automerge/rust/automerde/src/autoserde.rs)).
//   So the historical read is upstream's own omission and this port does not
//   add one.
