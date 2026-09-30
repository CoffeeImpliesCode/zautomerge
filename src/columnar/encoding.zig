//! The columnar encoding layer: the bridge between a column's `Encoding` tag
//! and the slab codec that holds its bytes.
//!
//! A column data block is a flat byte range per column, and the metadata
//! block says for each one what its bytes mean: the low three bits of the
//! specification are one of eight `Encoding` tags ([`column_spec.zig`](../storage/column_spec.zig),
//! upstream `columns/column_specification.rs:127-153`). This module turns a
//! `ColumnSpec` and a byte range into typed values and typed values into the
//! bytes a column will hold.
//!
//! # The eight tags and the codec each one selects
//!
//! Upstream does not spell this mapping out in one place: a column's
//! specification is turned into a range type by `ColumnLayoutParser`
//! (`columns.rs:199-247`) and each range type names its own decoder
//! (`column_range/*`). The result is the table below. It is not one-to-one —
//! four tags select the same run-length codec over different widths, and
//! three of them are nullable for different reasons.
//!
//! | tag | codec | value | nullable | upstream |
//! |---|---|---|---|---|
//! | `group` | RLE of `u64` | group member count | no | `start_group(spec, num: RleRange<u64>)`, `column_builder.rs:55-60` |
//! | `actor` | RLE of `u32` | actor index | yes | `build_actor`, `column_builder.rs:13-18` |
//! | `rle_uint` | RLE of `u64` | an unsigned integer | yes | `build_integer`, `column_builder.rs:27-32` |
//! | `delta` | delta of `i64` | a signed integer | yes | `build_delta_integer`, `column_builder.rs:34-39` |
//! | `boolean` | boolean slab | `true` / `false` | no | `build_boolean`, `column_builder.rs:41-46` |
//! | `string` | RLE of length-prefixed bytes | a string | yes | `build_string`, `column_builder.rs:20-25` |
//! | `value_metadata` | prefix of `u64` | a metadata word | no | `start_value(spec, meta: RleRange<u64>)`, `column_builder.rs:48-53` |
//! | `value` | the raw payload half of a value pair | a scalar | no | `build(meta, raw)`, `column_builder.rs:78-84` |
//!
//! Three of those need a word on nullability, because the run-length codec
//! carries an absent value in the run header and the eight tags disagree
//! about whether an absent value is possible:
//!
//! * `actor` and `rle_uint` are nullable. A column that may be absent is one
//!   column whose RLE stream carries nulls: a string key is written as a null
//!   actor and a null counter, and `(None, 0)` is the root object
//!   (`column_range/key.rs:250-266`, `column_range/obj_id.rs:127-143`).
//! * `group` is not. A null member count is a hard error
//!   (`column_range/generic/group.rs:76-79`).
//! * `value_metadata` is not. A null metadata word is `unexpected_null("meta")`
//!   (`column_range/value.rs:269`).
//! * `boolean` cannot be null: a boolean slab is a sequence of run counts and
//!   no value bytes at all, so there is nowhere for a null to ride
//!   (`encoding/boolean.rs:7-12`).
//!
//! `delta` stores `value - previous` with `previous` starting at 0, run
//! length encoded, and the running total lives in the decoder
//! (`encoding/delta.rs:10-13`, `:50-54`).
//! The widths follow upstream and the format, not convenience. Upstream's
//! ranges are all `RleRange<u64>`; the wire is unsigned LEB128 either way, so
//! a `u32` column and a `u64` column of the same values are the same bytes.
//! The one narrowing here is the actor column, because an actor index is a
//! `u32` in this port (`types.zig:21`) and an index past that is not an
//! actor: a document that names one is `error.Overflow` at encode time and
//! `error.Overflow` at decode time. A group count, an `rle_uint` value and a
//! metadata word are `u64` because the format says so.
//!
//! # The value column pair
//!
//! `value_metadata` and `value` are one logical column split across two raw
//! columns of the same id ([specification](https://automerge.org/automerge-binary-format-spec/#_op_type_columns)).
//! The metadata column holds one word per value, `(byte_length << 4) | type_code`
//! (`column_range/value.rs:389-410`, `:412-435`), and the value column holds
//! the payloads back to back with no length prefix of their own
//! (`encoding/encodable_impls.rs:7-27`). A reader takes the length and the
//! type from the metadata word and exactly that many bytes from the payload
//! column.
//!
//! The length in a metadata word came off the wire, so it is the one place
//! where a corrupt word could size an allocation. Nothing here allocates on
//! the read path at all: the payload bytes are borrowed from the column, and
//! the length is checked against what remains *before* the slice is taken
//! (`ValueDecoder.next`). Upstream allocates a `Vec` per value and bounds the
//! length with `MAX_ALLOCATION = 1_000_000_000`
//! (`encoding/decodable_impls.rs:10`, `:94-110`), which is a weaker check
//! than "the bytes are there", and then rejects the read with
//! `TryingToReadPastEnd` when they are not
//! (`column_range/value.rs:260-264`). Checking the remaining bytes first
//! answers the same question without ever trusting the declared length with
//! memory.
//!
//! A type code this port does not know is **preserved**, not rejected: it
//! decodes to `ScalarValue.unknown` with its type code and its bytes intact,
//! so a document written by a future version round-trips through this one.
//! Upstream does the same with `ValueType::Unknown(code)`
//! (`column_range/value.rs:254-259`).
//!
//! # Overlong LEB128
//!
//! A value column is the one place on the load path where a LEB128 sits
//! *inside* a length-delimited payload, so a value can be encoded in more
//! bytes than it needs and still fit the length its metadata word declares.
//! `test/fixtures/counter_value_is_overlong.automerge` is exactly that: a
//! counter of -48 written as `d0 7f`, two bytes, where the one byte `40`
//! would do, under a metadata word that says two bytes. The reference refuses
//! the load (`rust/automerge/tests/test.rs:2230-2231`).
//!
//! The refusal is not this module's to make and not its to soften. Upstream
//! reads a counter, an int and a timestamp with the in-tree reader
//! (`column_range/value.rs:226`, `:249`, `:252`), and that reader returns
//! `Leb128Overlong` for an encoding that spends a byte the value did not need
//! (`storage/parse/leb128.rs:52-73`). This module inherits it through
//! `leb128.readSigned` / `leb128.readUnsigned`, so the `r.len != bytes.len`
//! check below is the *second* line of defence, not the first: it catches a
//! payload that is too short, and the reader catches one that is too long for
//! the value it holds.
//!
//! # A cursor, not a slice
//!
//! `Decoder` yields one value per call. A document walk reads one row across
//! sixteen columns at a time and must not materialise any of them, so nothing
//! in the read path allocates: a repeat or null run is served from memory, a
//! literal run re-reads the wire per value, and a value payload is a borrowed
//! sub-slice. `decodeAll` exists for the callers that do want the whole
//! column, and the two agree by construction — every test here runs the
//! cursor against the bulk decode.
//!
//! # The reported encoding
//!
//! `Encoded.encoding` is the tag the returned bytes were actually written
//! with, not a copy of the request. The two differ in exactly one place, and
//! it is the format's doing: a value column is a pair, so a request for
//! `value` yields a `.value_metadata` half and a `.value` half, each
//! reporting its own tag (`column_range/value.rs:340-355`,
//! `change_op_columns.rs:327-336`). A difference here is a fact about the
//! canonical form, not a bug.
//!
//! There is a second, different kind of difference, which is about presence
//! rather than tag: a boolean column with no `true` in it has no canonical
//! form as a column. Upstream's `MaybeBooleanEncoder` discards its buffer
//! when no `true` was appended (`encoding/boolean.rs:131-140`), a column with
//! no bytes is dropped from the set (`columns/raw_column.rs:40-50`, `:183`),
//! and `MaybeBooleanDecoder` on an empty range yields *no* rows rather than
//! any rows of `false` (`encoding/boolean.rs:156-166`) — that is what makes
//! an omitted `expand` column mean "all false". `encodeMaybeBoolean` is that
//! encoder, and it reports the difference through `Encoded.isPresent`.
//! `encodeColumn` is the plain one and always writes a column.
//!
//! # Errors
//!
//! Everything reachable from bytes is a `ParseError`. Upstream wraps each
//! failure in a `DecodeColumnError` carrying the path of the column it was
//! reading (`encoding/col_error.rs:1-88`), because an op has sixteen columns
//! and "bad leb128" alone does not say where. A `ParseError` carries no
//! payload in this port, so the column that failed is the caller's own
//! variable to name; `ColumnDecoder::next_in_col`
//! (`encoding/column_decoder.rs:26-51`) is where upstream attaches it, and
//! that is the layer above this one.
//!
//! [`column_spec.zig`]: ../storage/column_spec.zig

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");
const value = @import("../value.zig");
const rle = @import("../hexane/rle.zig");
const bool_codec = @import("../hexane/bool.zig");
const delta = @import("../hexane/delta.zig");
const prefix = @import("../hexane/prefix.zig");
const colspec = @import("../storage/column_spec.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const Encoding = colspec.Encoding;
const ColumnSpec = colspec.ColumnSpec;
const ScalarValue = value.ScalarValue;
const ValueMeta = value.ValueMeta;

/// The absent cell, as a typed binding: `null` in expression position would
/// land on the end-of-column optional wrapped around it, which is the other
/// null this module has to keep distinct.
const absent: Cell = .null_value;

// ── The tag ─────────────────────────────────────────────────────────────────

/// The encoding with the wire tag `t`, or `error.InvalidEncoding` when `t` is
/// none of the eight. Upstream reads the tag out of a specification with
/// `val & 0b0000_0111` (`column_specification.rs:142-143`), so a tag outside
/// the eight is a corrupt document rather than a version to be preserved.
pub fn encodingFromTag(t: u8) ParseError!Encoding {
    return Encoding.fromTag(t);
}

// ── One decoded value, from any of the eight encodings ──────────────────────

/// One column entry, decoded. The composite of the eight encodings: a caller
/// that walks a row across columns of different tags reads one of these per
/// column and does not branch on the tag per value, which is the whole point
/// of upstream's `Decodable` seam (`encoding.rs:59-64`) and its
/// `ColumnDecoder` blanket impls (`encoding/column_decoder.rs:67-85`).
///
/// An absent value is `.null_value`, which is *not* the same thing as the end
/// of the column: the two are the inner and the outer null of a `??T`, the
/// convention `rle.zig` already uses for a nullable column's `next`.
pub const Cell = union(enum) {
    /// An absent row: a null run in an RLE-shaped column.
    null_value,
    /// An unsigned integer: a group member count, an actor index, any
    /// `rle_uint` column, or a value metadata word.
    uint: u64,
    /// A signed integer: one row of a `delta` column.
    int: i64,
    /// One row of a boolean column.
    boolean: bool,
    /// One row of a string column, borrowed from the column's bytes.
    string: []const u8,
    /// One value of a value column pair, with its payload borrowed from the
    /// value column.
    value: ScalarValue,

    /// Whether two cells are the same value. Strings and bytes compare by
    /// content, an unknown value by its type code and its bytes.
    pub fn eql(a: Cell, b: Cell) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null_value => true,
            .uint => |x| x == b.uint,
            .int => |x| x == b.int,
            .boolean => |x| x == b.boolean,
            .string => |x| std.mem.eql(u8, x, b.string),
            .value => |x| x.eql(b.value),
        };
    }
};

// ── The string codec ────────────────────────────────────────────────────────

/// The run-length codec of a string column: the run grammar of `rle.zig` with
/// a value payload that is an unsigned LEB128 byte length followed by that
/// many raw bytes (`encoding/encodable_impls.rs:30-52`, read back by
/// `encoding/decodable_impls.rs:112-137`).
///
/// The payload is not an integer, so the integer codec cannot be reused: this
/// is the same run grammar with one different payload, and the rules are the
/// ones `rle.zig` states — a value repeated twice or more is a repeat run, an
/// absent value is a null run, and everything else joins the literal run in
/// progress (`rle.zig:527-587`).
pub const RleSlice = struct {
    /// One column entry: a present string, borrowed from the column's bytes,
    /// or null for an absent one.
    pub const Element = ?[]const u8;

    /// The number of values one slab may decode to. The same ceiling the
    /// integer codec applies, for the same reason: a run header is three bytes
    /// whatever its count says (`rle.zig:59-69`).
    pub const maxLen: usize = rle.maxSlabLen;

    /// The number of bytes one value payload occupies.
    fn payloadSize(v: []const u8) usize {
        return leb128.unsignedSize(v.len) + v.len;
    }

    /// Writes one value payload, returning the bytes written.
    fn writePayload(out: []u8, v: []const u8) usize {
        const n = leb128.writeUnsigned(out, v.len);
        @memcpy(out[n..][0..v.len], v);
        return n + v.len;
    }

    /// Reads one value payload at `pos`. A length that runs past the end of
    /// the slab is `error.UnexpectedEnd`, which is what upstream's
    /// `read_exact` on a `Vec` of the declared length reports
    /// (`encoding/decodable_impls.rs:94-110`).
    fn readPayload(bytes: []const u8, pos: usize) ParseError!struct { value: []const u8, len: usize } {
        const n = try leb128.readUnsigned(bytes[pos..]);
        const at = pos + n.len;
        const len = std.math.cast(usize, n.value) orelse return error.Overflow;
        if (len > bytes.len - at) return error.UnexpectedEnd;
        return .{ .value = bytes[at..][0..len], .len = n.len + len };
    }

    /// The number of bytes `write` emits for `values`.
    pub fn encodedSize(values: []const Element) usize {
        var total: usize = 0;
        var seg = Segmenter{ .values = values };
        while (seg.next()) |s| total += s.size(values);
        return total;
    }

    /// Writes `values` into `out`, which must hold at least
    /// `encodedSize(values)` bytes. The output is canonical.
    pub fn write(out: []u8, values: []const Element) void {
        const n = encodedSize(values);
        std.debug.assert(out.len >= n);
        var seg = Segmenter{ .values = values };
        var pos: usize = 0;
        while (seg.next()) |s| pos += s.writeTo(out[pos..], values);
        std.debug.assert(pos == n);
    }

    /// Appends the encoding of `values` to `list`.
    pub fn append(list: *std.ArrayList(u8), gpa: Allocator, values: []const Element) ParseError!void {
        const n = encodedSize(values);
        try list.ensureUnusedCapacity(gpa, n);
        const dst = list.addManyAsSliceAssumeCapacity(n);
        var seg = Segmenter{ .values = values };
        var pos: usize = 0;
        while (seg.next()) |s| pos += s.writeTo(dst[pos..], values);
        std.debug.assert(pos == n);
    }

    /// Every value in a slab, in order. The caller owns the result. The value
    /// count is walked first, so a run that expands a handful of bytes into
    /// millions of values still costs exactly one allocation.
    pub fn decodeAll(bytes: []const u8, gpa: Allocator) ParseError![]Element {
        const n = try countValues(bytes);
        const out = try gpa.alloc(Element, n);
        errdefer gpa.free(out);
        var dec = try RleSlice.Decoder.init(bytes);
        for (out) |*v| {
            // `countValues` walked the same bytes under the same rules, so
            // the cursor has exactly `n` values left.
            v.* = (try dec.next()) orelse return error.InvalidValue;
        }
        return out;
    }

    /// Checks that `bytes` is a well-formed *and* canonical slab for a string
    /// column, under the same nine rules as the integer codec (`rle.zig:143-211`).
    pub fn canonical(bytes: []const u8) ParseError!void {
        var pos: usize = 0;
        // The last run walked, which rules 4, 5, 6 and 8 compare against. A
        // repeat run and a literal run are told apart because only a literal
        // run may not be followed by another of its own.
        var prev: ?PrevRun = null;
        // The previous value inside the literal run being walked, for rule 7.
        var prev_lit: ?Element = null;
        while (pos < bytes.len) {
            const hdr = try readRunHeader(bytes, pos);
            if (hdr.is_repeat) {
                if (hdr.count < 2) return error.InvalidValue; // rule 1
                const cv = try readPayload(bytes, hdr.payload_at);
                const v: Element = cv.value;
                // Rules 6 and 8: a repeat run may not carry a value the run
                // before it ended on.
                if (prev) |p| switch (p) {
                    .run => |q| if (sameSlice(q, v)) return error.InvalidValue,
                    .lit => |q| if (sameSlice(q, v)) return error.InvalidValue,
                    .null_run => {},
                };
                pos = hdr.payload_at + cv.len;
                prev = .{ .run = v };
                prev_lit = null;
            } else if (hdr.is_null) {
                const nc = try readNullCount(bytes, hdr.payload_at);
                if (nc.count == 0) return error.InvalidValue; // rule 2
                // Rule 5: two null runs in a row are one null run.
                if (prev) |p| switch (p) {
                    .null_run => return error.InvalidValue,
                    .run, .lit => {},
                };
                pos = hdr.payload_at + nc.header_len;
                prev = .null_run;
                prev_lit = null;
            } else {
                if (hdr.count == 0) return error.InvalidValue; // rule 3
                // Rule 4: two literal runs in a row are one literal run.
                if (prev) |p| switch (p) {
                    .lit => return error.InvalidValue,
                    .run, .null_run => {},
                };
                var p = hdr.payload_at;
                var k: u64 = 0;
                while (k < hdr.count) : (k += 1) {
                    const cv = try readPayload(bytes, p);
                    const v: Element = cv.value;
                    if (prev_lit) |pl| {
                        // Rule 7: a literal run may not repeat a value, which
                        // is what would have made it a repeat run.
                        if (sameSlice(pl, v)) return error.InvalidValue;
                    } else if (prev) |q| switch (q) {
                        // Rule 8, at the boundary of the literal run.
                        .run => |x| if (sameSlice(x, v)) return error.InvalidValue,
                        .lit => |x| if (sameSlice(x, v)) return error.InvalidValue,
                        .null_run => {},
                    };
                    prev_lit = v;
                    p += cv.len;
                }
                pos = p;
                // `count` was checked non-zero, so the walk ran.
                prev = .{ .lit = prev_lit.? };
                prev_lit = null;
            }
        }
    }

    /// The last run a `canonical` walk has seen, which is what makes a repeat
    /// run and a literal run distinguishable.
    const PrevRun = union(enum) {
        /// After a repeat run, carrying the value it repeated.
        run: Element,
        /// After a literal run, carrying its last value.
        lit: Element,
        /// After a null run.
        null_run,
    };

    /// A cursor over a slab that yields values one at a time. A repeat or null
    /// run is read once and then served from memory; a literal run re-reads
    /// the wire for every value, which is what makes the format
    /// forward-decodable.
    pub const Decoder = struct {
        /// The slab being walked.
        data: []const u8,
        /// Byte offset of the next run header, or of the next literal value
        /// while a literal run is being served.
        pos: usize,
        /// Values still owed by the run in `run`.
        remaining: u64,
        run: Run,

        const Run = union(enum) {
            /// Between runs, or the slab is exhausted.
            idle,
            /// Serve `elem` `remaining` times.
            repeat: []const u8,
            /// Read a value from `pos` for each of the next `remaining`.
            literal,
            /// Serve an absent value `remaining` times.
            null_run,
        };

        /// A decoder at the start of `bytes`. The opening run header is read
        /// and checked now, so bytes that are not an RLE slab at all are
        /// rejected at the boundary rather than on the first `next`.
        pub fn init(bytes: []const u8) ParseError!RleSlice.Decoder {
            var dec: RleSlice.Decoder = .{
                .data = bytes,
                .pos = 0,
                .remaining = 0,
                .run = .idle,
            };
            if (bytes.len == 0) return dec;
            _ = try dec.enterRun();
            return dec;
        }

        /// The next value, or null once the slab is exhausted. The payload is
        /// an optional, so the return is `??[]const u8`: an absent column
        /// value stays distinct from the end of the slab.
        pub fn next(self: *RleSlice.Decoder) ParseError!?Element {
            while (self.remaining == 0) {
                if (!try self.enterRun()) return null;
            }
            self.remaining -= 1;
            switch (self.run) {
                .repeat => |v| return v,
                .null_run => return nullElement(),
                .literal => {
                    const cv = try readPayload(self.data, self.pos);
                    self.pos += cv.len;
                    return cv.value;
                },
                // `remaining > 0` means `enterRun` set a run that owes at
                // least this value, so this is not reachable.
                .idle => return error.InvalidValue,
            }
        }

        /// Reads the run header at `pos` and loads the run it describes.
        /// Returns false at the end of the slab. Every field is assigned
        /// together, so a rejected header leaves the decoder as it was.
        fn enterRun(self: *RleSlice.Decoder) ParseError!bool {
            if (self.pos >= self.data.len) {
                self.run = .idle;
                self.remaining = 0;
                return false;
            }
            const hdr = try readRunHeader(self.data, self.pos);
            if (hdr.is_repeat) {
                if (hdr.count > maxLen) return error.TooLarge;
                const cv = try readPayload(self.data, hdr.payload_at);
                self.pos = hdr.payload_at + cv.len;
                self.remaining = hdr.count;
                self.run = .{ .repeat = cv.value };
            } else if (hdr.is_null) {
                const nc = try readNullCount(self.data, hdr.payload_at);
                if (nc.count > maxLen) return error.TooLarge;
                self.pos = hdr.payload_at + nc.header_len;
                self.remaining = nc.count;
                self.run = .null_run;
            } else {
                // `readRunHeader` already proved the values are present, so
                // a literal run cannot outrun the slab.
                self.pos = hdr.payload_at;
                self.remaining = hdr.count;
                self.run = .literal;
            }
            return true;
        }
    };

    /// The element a null run yields.
    fn nullElement() ParseError!?Element {
        return @as(Element, null);
    }

    /// One run header, decoded, and where its payload starts.
    const RunHeader = struct {
        /// A repeat count or a literal count. Unused for a null run: that
        /// count is the unsigned varint in the payload.
        count: u64,
        is_repeat: bool,
        is_null: bool,
        /// Byte offset of the payload.
        payload_at: usize,
    };

    /// Reads the run header at `pos`.
    fn readRunHeader(bytes: []const u8, pos: usize) ParseError!RunHeader {
        const h = try leb128.readSigned(bytes[pos..]);
        const payload_at = pos + h.len;
        if (h.value > 0) {
            return .{
                .count = @intCast(h.value),
                .is_repeat = true,
                .is_null = false,
                .payload_at = payload_at,
            };
        }
        if (h.value < 0) {
            const count = literalCount(h.value);
            // Every value costs at least one byte, so a count larger than the
            // rest of the slab cannot be satisfied. Rejecting it here bounds
            // every walk over a literal run.
            if (count > bytes.len - payload_at) return error.LengthExceedsInput;
            return .{
                .count = count,
                .is_repeat = false,
                .is_null = false,
                .payload_at = payload_at,
            };
        }
        return .{
            .count = 0,
            .is_repeat = false,
            .is_null = true,
            .payload_at = payload_at,
        };
    }

    /// Reads the unsigned count that follows a null run's header.
    fn readNullCount(bytes: []const u8, pos: usize) ParseError!struct { count: u64, header_len: usize } {
        const c = try leb128.readUnsigned(bytes[pos..]);
        return .{ .count = c.value, .header_len = c.len };
    }

    /// `-value` for the negative header of a literal run, computed with a
    /// wrapping negate because `readSigned` can return `minInt(i64)`.
    fn literalCount(raw: i64) u64 {
        std.debug.assert(raw < 0);
        return -%@as(u64, @bitCast(raw));
    }

    /// The value count of a whole slab, walked run by run and never
    /// materialising a value.
    fn countValues(bytes: []const u8) ParseError!usize {
        var pos: usize = 0;
        var total: usize = 0;
        while (pos < bytes.len) {
            const hdr = try readRunHeader(bytes, pos);
            var run: u64 = 0;
            if (hdr.is_repeat) {
                const cv = try readPayload(bytes, hdr.payload_at);
                pos = hdr.payload_at + cv.len;
                run = hdr.count;
            } else if (hdr.is_null) {
                const nc = try readNullCount(bytes, hdr.payload_at);
                pos = hdr.payload_at + nc.header_len;
                run = nc.count;
            } else {
                var p = hdr.payload_at;
                var k: u64 = 0;
                while (k < hdr.count) : (k += 1) {
                    const cv = try readPayload(bytes, p);
                    p += cv.len;
                }
                pos = p;
                run = hdr.count;
            }
            const n = std.math.cast(usize, run) orelse return error.Overflow;
            total = std.math.add(usize, total, n) catch return error.Overflow;
            if (total > maxLen) return error.TooLarge;
        }
        return total;
    }

    /// One run of a value sequence on its way to the wire.
    const Segment = union(enum) {
        repeat: struct { count: usize, value: []const u8 },
        literal: struct { start: usize, len: usize },
        null: usize,

        /// The number of bytes this segment occupies.
        fn size(s: Segment, values: []const Element) usize {
            return switch (s) {
                .repeat => |r| headerSize(r.count) + payloadSize(r.value),
                .literal => |l| literalSize(l.start, l.len, values),
                .null => |count| headerSize(0) + leb128.unsignedSize(count),
            };
        }

        /// Writes this segment into `out`, returning the bytes written.
        fn writeTo(s: Segment, out: []u8, values: []const Element) usize {
            return switch (s) {
                .repeat => |r| blk: {
                    var n = leb128.writeSigned(out, @as(i64, @intCast(r.count)));
                    n += writePayload(out[n..], r.value);
                    break :blk n;
                },
                .literal => |l| blk: {
                    var n = leb128.writeSigned(out, literalHeader(l.len));
                    for (values[l.start..][0..l.len]) |v| {
                        n += writePayload(out[n..], v.?);
                    }
                    break :blk n;
                },
                .null => |count| blk: {
                    var n = leb128.writeSigned(out, 0);
                    n += leb128.writeUnsigned(out[n..], count);
                    break :blk n;
                },
            };
        }
    };

    /// Splits `values` into the runs `write` emits. The segmentation is
    /// forced: a value repeated twice or more is a repeat run, absent values
    /// are a null run, and what is left over is one literal run — so no run
    /// can be merged with its neighbour and no literal can hold a value a run
    /// could have held. This is the integer codec's segmenter with a slice
    /// payload (`rle.zig:527-587`).
    const Segmenter = struct {
        values: []const Element,
        pos: usize = 0,
        lit_start: usize = 0,
        lit_len: usize = 0,
        /// A literal run is emitted before the run that ended it, so at most
        /// one segment is ever held back.
        pending: ?Segment = null,

        fn next(self: *Segmenter) ?Segment {
            while (true) {
                if (self.pending) |p| {
                    self.pending = null;
                    return p;
                }
                if (self.pos >= self.values.len) return self.flushLiteral();
                const v = self.values[self.pos];
                var j = self.pos + 1;
                while (j < self.values.len and sameSlice(self.values[j], v)) j += 1;
                const run = j - self.pos;
                if (v == null) {
                    // The literal run in progress belongs before the null
                    // run, so hand one back and hold the other over.
                    const lit = self.flushLiteral();
                    self.pending = .{ .null = run };
                    self.pos = j;
                    if (lit) |l| return l;
                    continue;
                }
                if (run >= 2) {
                    const lit = self.flushLiteral();
                    self.pending = .{ .repeat = .{ .count = run, .value = v.? } };
                    self.pos = j;
                    if (lit) |l| return l;
                    continue;
                }
                // A value that appears once joins the literal run in
                // progress. Consecutive maximal runs carry different values
                // by construction, so the literal can hold no two equal
                // values, and its first value cannot equal the previous
                // run's.
                if (self.lit_len == 0) self.lit_start = self.pos;
                self.lit_len += 1;
                self.pos = j;
            }
        }

        fn flushLiteral(self: *Segmenter) ?Segment {
            if (self.lit_len == 0) return null;
            const s: Segment = .{ .literal = .{ .start = self.lit_start, .len = self.lit_len } };
            self.lit_len = 0;
            return s;
        }
    };

    /// `signed_leb128( -len )`, the header of a literal run.
    fn literalHeader(len: usize) i64 {
        std.debug.assert(len <= std.math.maxInt(i64));
        return -@as(i64, @intCast(len));
    }

    /// The number of bytes a literal run of `len` values from `start` takes.
    fn literalSize(start: usize, len: usize, values: []const Element) usize {
        var n = leb128.signedSize(literalHeader(len));
        for (values[start..][0..len]) |v| n += payloadSize(v.?);
        return n;
    }

    /// `signed_leb128( count )`, the header of a repeat run.
    fn headerSize(count: usize) usize {
        std.debug.assert(count <= std.math.maxInt(i64));
        return leb128.signedSize(@as(i64, @intCast(count)));
    }
};

/// Whether two optional strings are the same value, which for the segmenter
/// means "the same run of bytes" — two absent values are one run, and two
/// equal strings are one run however they are stored.
fn sameSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ── The value column pair ───────────────────────────────────────────────────

/// A cursor over a value column pair: the metadata column's words and the
/// value column's payload bytes, read in lockstep.
///
/// This is upstream's `ValueIter` (`column_range/value.rs:209-274`): one
/// metadata word per value, and exactly the number of bytes the word declares
/// taken from the payload column. Nothing is allocated, and a length that
/// runs past the end of the payload column is refused before the slice is
/// taken.
pub const ValueDecoder = struct {
    /// The metadata cursor. Upstream's metadata column is a plain run-length
    /// column of `u64` (`column_builder.rs:48-53`); this port reads it through
    /// the prefix codec, whose slab bytes are those same run-length bytes and
    /// whose cursor also carries the running offset of each word. Only the
    /// words themselves are used here; the pair does not need the offsets.
    meta: prefix.Prefix(u64).Decoder,
    /// The payload column, borrowed.
    raw: []const u8,
    /// The offset in `raw` of the next payload.
    pos: usize,

    /// A cursor at the start of the pair. The metadata column's opening run
    /// header is read and checked here; anything malformed further in
    /// surfaces from `next`.
    pub fn init(meta_bytes: []const u8, raw_bytes: []const u8) ParseError!ValueDecoder {
        return .{
            .meta = try prefix.Prefix(u64).Decoder.init(meta_bytes),
            .raw = raw_bytes,
            .pos = 0,
        };
    }

    /// The next value, or null once the metadata column is exhausted. The
    /// value borrows `raw`, and is valid until the caller reads the next one.
    ///
    /// A metadata word naming a type this port does not know is preserved:
    /// the value is `ScalarValue.unknown` carrying the type code and the
    /// declared bytes verbatim, so a document from a future version round
    /// trips through this one (`column_range/value.rs:254-259`).
    ///
    /// A payload whose LEB128 is overlong is refused by the reader, not
    /// clamped and not warned about: a document that differs on the wire is
    /// not a document. See the module's *Overlong LEB128* section, and
    /// `storage/parse/leb128.rs:52-73` for the reference rule.
    pub fn next(self: *ValueDecoder) ParseError!?ScalarValue {
        const word = (try self.meta.next()) orelse return null;
        const m = ValueMeta.fromRaw(word);
        const code = m.typeCode();
        switch (code) {
            // These three carry their whole value in the metadata word, so
            // the payload column is not touched at all
            // (`column_range/value.rs:222-225`).
            .null_value => return .null_value,
            .false_value => return .{ .bool_value = false },
            .true_value => return .{ .bool_value = true },
            .uleb, .leb, .float, .string, .bytes, .counter, .timestamp, .unknown => {},
        }
        // Every remaining type takes exactly the declared number of bytes, and
        // the declared number is the one thing in this column that came off
        // the wire. It is checked against what is left before anything is
        // taken, and `scalarLength` is used rather than `ValueMeta.length`,
        // whose cast is unchecked.
        const len = scalarLength(m) catch |e| return e;
        if (len > self.raw.len - self.pos) return error.LengthExceedsInput;
        const bytes = self.raw[self.pos..][0..len];
        self.pos += len;
        return switch (code) {
            .uleb => blk: {
                const r = try leb128.readUnsigned(bytes);
                // The whole payload must be the number, or the metadata word
                // and the payload disagree (`column_range/value.rs:293-309`).
                if (r.len != bytes.len) return error.InvalidValue;
                break :blk ScalarValue{ .uint = r.value };
            },
            .leb => blk: {
                const r = try leb128.readSigned(bytes);
                if (r.len != bytes.len) return error.InvalidValue;
                break :blk ScalarValue{ .int = r.value };
            },
            .counter => blk: {
                const r = try leb128.readSigned(bytes);
                if (r.len != bytes.len) return error.InvalidValue;
                break :blk ScalarValue{ .counter = .init(r.value) };
            },
            .timestamp => blk: {
                const r = try leb128.readSigned(bytes);
                if (r.len != bytes.len) return error.InvalidValue;
                break :blk ScalarValue{ .timestamp = r.value };
            },
            .float => blk: {
                // A float is a fixed eight bytes, and upstream treats any
                // other length as a hard error
                // (`column_range/value.rs:233-240`).
                if (len != 8) return error.InvalidValue;
                // Little-endian, because that is the wire order: upstream
                // writes `f64::to_le_bytes` (`value.rs:795`) and reads
                // `f64::from_le_bytes` (`column_range/value.rs:233-240`),
                // and `columns.zig`/`opset/types.zig` already say `.little`
                // on both sides. A `@bitCast` of the bytes is a host-order
                // read, so on powerpc64 it named a different number.
                break :blk ScalarValue{ .float = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) };
            },
            .string => blk: {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
                break :blk ScalarValue{ .str = bytes };
            },
            .bytes => ScalarValue{ .bytes = bytes },
            .unknown => |c| ScalarValue{ .unknown = .{ .type_code = c, .bytes = bytes } },
            // The three tags above returned before the payload was taken.
            .null_value, .false_value, .true_value => return error.InvalidValue,
        };
    }
};

/// The byte length a metadata word declares, or `error.Overflow` when it does
/// not fit a `usize`. `ValueMeta.length` casts the shift without checking it,
/// which is fine for a word this port wrote and not for one it did not.
fn scalarLength(m: ValueMeta) ParseError!usize {
    return std.math.cast(usize, m.raw >> 4) orelse error.Overflow;
}

/// The metadata word for a scalar: `(byte_length << 4) | type_code`
/// (`column_range/value.rs:412-435`).
///
/// A counter is type code 8 and a timestamp is 9, which is what makes them
/// read back as themselves rather than as a plain signed integer; the Zig
/// contract's `ScalarValue.valueType` answers a different question — which
/// `ObjType` coercion a stored value gets — and is not this word
/// (`value.zig:141-152`).
///
/// A `ScalarValue.unknown` whose type code is below 10 lands in the low
/// nibble on top of a defined tag and reads back as that tag. Upstream stores
/// the caller's code as it stands and this encoder does the same, because
/// refusing it would refuse a value the format admits
/// (`column_range/value.rs:429-432`).
pub fn metaWordOf(v: ScalarValue) ParseError!u64 {
    return switch (v) {
        .null_value => 0,
        .bool_value => |b| if (b) 2 else 1,
        .uint => |u| shiftLen(leb128.unsignedSize(u), 3),
        .int => |i| shiftLen(leb128.signedSize(i), 4),
        .float => shiftLen(8, 5),
        .str => |s| shiftLen(s.len, 6),
        .bytes => |b| shiftLen(b.len, 7),
        // An actor id in the value column is an opaque byte payload; the
        // reference to an actor lives in the key columns, not here
        // (`value.zig:138-140`).
        .actor_id => |a| shiftLen(a.bytes.len, 7),
        .counter => |c| shiftLen(leb128.signedSize(c.current), 8),
        .timestamp => |t| shiftLen(leb128.signedSize(t), 9),
        .unknown => |u| shiftLen(u.bytes.len, u.type_code),
    };
}

/// `len << 4 | code`. The shift cannot overflow: a length is a `usize` of at
/// most half the address space before the shift would leave `u64`, and a
/// length that large is refused by the pair's own bounds check anyway.
fn shiftLen(len: anytype, code: u8) ParseError!u64 {
    return (@as(u64, @intCast(len)) << 4) | @as(u64, code);
}

// ── The decoder ─────────────────────────────────────────────────────────────

/// A cursor over one column, yielding its values one at a time.
///
/// The cursor is the whole read path. It holds no allocation, so a walk that
/// reads one row across sixteen columns materialises none of them; the only
/// thing it borrows is the column's own bytes.
pub const Decoder = struct {
    /// The specification whose bytes this cursor walks. For a value column
    /// pair this is the *metadata* half's specification, because that is the
    /// specification the logical column carries
    /// (`column_builder.rs:78-84`).
    spec: ColumnSpec,
    body: Body,

    /// The per-encoding cursor. One arm per tag, and the tag is chosen once
    /// here rather than on every value.
    pub const Body = union(enum) {
        /// `group`: the member count of one row.
        rle_group: rle.Rle(u64).Decoder,
        /// `actor`: an actor index, absent for the root object.
        rle_actor: rle.RleOption(u32).Decoder,
        /// `rle_uint`: an unsigned integer, absent for a row that has none.
        rle_uint: rle.RleOption(u64).Decoder,
        /// `delta`: a signed integer, absent for a row that has none.
        delta: delta.Delta(?i64).Decoder,
        /// `boolean`.
        boolean: bool_codec.Bool.Decoder,
        /// `string`: a string, borrowed from the column.
        string: RleSlice.Decoder,
        /// `value_metadata`: one metadata word per value.
        metadata: prefix.Prefix(u64).Decoder,
        /// `value`: one scalar per value, with the payload borrowed from the
        /// value column.
        value: ValueDecoder,

        /// The cursor `enc` reads `bytes` with.
        fn forTag(enc: Encoding, bytes: []const u8) ParseError!Body {
            return switch (enc) {
                .group => .{ .rle_group = try rle.Rle(u64).Decoder.init(bytes) },
                .actor => .{ .rle_actor = try rle.RleOption(u32).Decoder.init(bytes) },
                .rle_uint => .{ .rle_uint = try rle.RleOption(u64).Decoder.init(bytes) },
                .delta => .{ .delta = try delta.Delta(?i64).Decoder.init(bytes) },
                .boolean => .{ .boolean = try bool_codec.Bool.Decoder.init(bytes) },
                .string => .{ .string = try RleSlice.Decoder.init(bytes) },
                .value_metadata => .{ .metadata = try prefix.Prefix(u64).Decoder.init(bytes) },
                .value => error.Unsupported,
            };
        }
    };

    /// A cursor at the start of the column `spec`, whose bytes are `bytes`.
    ///
    /// A `value` specification is refused: it names the payload half of a
    /// value pair and cannot be read without its metadata sibling, and
    /// upstream's layout parser rejects a lone raw value column for the same
    /// reason (`columns.rs:216`). Use `initValuePair`.
    pub fn init(spec: ColumnSpec, bytes: []const u8) ParseError!Decoder {
        const enc = spec.encoding();
        if (enc == .value) return error.Unsupported;
        return .{ .spec = spec, .body = try Body.forTag(enc, bytes) };
    }

    /// A cursor at the start of the column the raw tag `tag` names, with the
    /// column id zero. `error.InvalidEncoding` when `tag` is none of the
    /// eight.
    pub fn initTag(tag: u8, bytes: []const u8) ParseError!Decoder {
        const enc = try encodingFromTag(tag);
        return init(ColumnSpec.make(0, enc, false), bytes);
    }

    /// A cursor over a value column pair: the metadata half and the payload
    /// half, read in lockstep. `meta` must name a `value_metadata` column.
    pub fn initValuePair(
        meta: ColumnSpec,
        meta_bytes: []const u8,
        raw_bytes: []const u8,
    ) ParseError!Decoder {
        if (meta.encoding() != .value_metadata) return error.InvalidEncoding;
        return .{
            .spec = meta,
            .body = .{ .value = try ValueDecoder.init(meta_bytes, raw_bytes) },
        };
    }

    /// The column's id.
    pub fn id(self: *const Decoder) u32 {
        return self.spec.id();
    }

    /// The column's encoding tag.
    pub fn encoding(self: *const Decoder) Encoding {
        return self.spec.encoding();
    }

    /// The next value, or null once the column is exhausted.
    ///
    /// This is the composite interface: one call reads one value from any of
    /// the eight encodings, so a caller that walks a row across columns of
    /// different tags does not branch on the tag per value.
    pub fn next(self: *Decoder) ParseError!?Cell {
        // The body is switched through `self` rather than a copy of it, so
        // each arm advances the cursor it found in place.
        switch (self.body) {
            .rle_group => |*c| {
                const v = (try c.next()) orelse return null;
                return .{ .uint = v };
            },
            .rle_actor => |*c| {
                const v = (try c.next()) orelse return null;
                return cellOfActor(v);
            },
            .rle_uint => |*c| {
                const v = (try c.next()) orelse return null;
                return cellOfOptional(v);
            },
            .delta => |*c| {
                const v = (try c.next()) orelse return null;
                if (v) |i| return .{ .int = i };
                return absent;
            },
            .boolean => |*c| {
                const v = (try c.next()) orelse return null;
                return .{ .boolean = v };
            },
            .string => |*c| {
                const v = (try c.next()) orelse return null;
                if (v) |s| return .{ .string = s };
                return absent;
            },
            .metadata => |*c| {
                const v = (try c.next()) orelse return null;
                return .{ .uint = v };
            },
            .value => |*c| {
                const v = (try c.next()) orelse return null;
                return .{ .value = v };
            },
        }
    }

    /// The next unsigned value, or null at the end of the column, with an
    /// absent row as the inner null. A `.group` or `.value_metadata` column
    /// has no absent row, and its codec refuses the null run that would carry
    /// one, so no absent cell ever reaches this.
    ///
    /// The five typed readers — this one, `nextInt`, `nextBoolean`,
    /// `nextString` and `nextValue` — read a cell and then check its shape, so
    /// a reader asked for the wrong kind of value reports
    /// `error.InvalidValue` and leaves the cursor one row on. A mismatch is
    /// the caller naming the wrong reader for the column, and it is reported
    /// rather than papered over; `next` is the reader that never guesses.
    pub fn nextUint(self: *Decoder) ParseError!?u64 {
        const c = (try self.next()) orelse return null;
        return switch (c) {
            .uint => |v| v,
            .null_value => null,
            else => error.InvalidValue,
        };
    }

    /// The next signed value, or null at the end of the column, with an
    /// absent row as the inner null.
    pub fn nextInt(self: *Decoder) ParseError!?i64 {
        const c = (try self.next()) orelse return null;
        return switch (c) {
            .int => |v| v,
            .null_value => null,
            else => error.InvalidValue,
        };
    }

    /// The next boolean, or null at the end of the column. A boolean column
    /// has no absent row.
    pub fn nextBoolean(self: *Decoder) ParseError!?bool {
        const c = (try self.next()) orelse return null;
        return switch (c) {
            .boolean => |v| v,
            else => error.InvalidValue,
        };
    }

    /// The next string, or null at the end of the column, with an absent row
    /// as the inner null. The string borrows the column's bytes.
    pub fn nextString(self: *Decoder) ParseError!??[]const u8 {
        const c = (try self.next()) orelse return null;
        return switch (c) {
            .string => |v| v,
            .null_value => @as(?[]const u8, null),
            else => error.InvalidValue,
        };
    }

    /// The next value of a value column pair, or null at the end of the
    /// column.
    pub fn nextValue(self: *Decoder) ParseError!?ScalarValue {
        const c = (try self.next()) orelse return null;
        return switch (c) {
            .value => |v| v,
            else => error.InvalidValue,
        };
    }
};

/// A run-length cell: a present unsigned value, or an absent row.
fn cellOfOptional(v: ?u64) Cell {
    if (v) |x| return .{ .uint = x };
    return absent;
}

/// An actor cell: a present actor index widened to the unsigned the
/// composite cell carries, or an absent row.
fn cellOfActor(v: ?u32) Cell {
    if (v) |x| return .{ .uint = x };
    return absent;
}

/// Every value in a column, in order. The caller owns the result. A `value`
/// column is refused: it is a pair, and `decodeValuePair` reads one.
pub fn decodeAll(gpa: Allocator, spec: ColumnSpec, bytes: []const u8) ParseError![]Cell {
    var dec = try Decoder.init(spec, bytes);
    var out: std.ArrayList(Cell) = .empty;
    errdefer out.deinit(gpa);
    while (try dec.next()) |c| try out.append(gpa, c);
    return out.toOwnedSlice(gpa);
}

/// Every value in a value column pair, in order. The caller owns the result.
/// The values borrow the payload column, which the caller also owns.
pub fn decodeValuePair(gpa: Allocator, meta_bytes: []const u8, raw_bytes: []const u8) ParseError![]ScalarValue {
    var dec = try ValueDecoder.init(meta_bytes, raw_bytes);
    var out: std.ArrayList(ScalarValue) = .empty;
    errdefer out.deinit(gpa);
    while (try dec.next()) |v| try out.append(gpa, v);
    return out.toOwnedSlice(gpa);
}

// ── The encoder ─────────────────────────────────────────────────────────────

/// One encoded column: the bytes a `ColumnSpec` names, the specification they
/// go with, the tag they were actually written with, and how many entries the
/// column holds. The caller owns the bytes.
pub const Encoded = struct {
    /// The column's specification, with the DEFLATE bit clear: the bytes here
    /// are not a DEFLATE stream, and the flag is set by whoever deflates them.
    spec: ColumnSpec,
    /// The column's bytes.
    bytes: []u8,
    /// The tag those bytes were written with. It is the requested tag for
    /// every single-column encoding, and for a value pair's metadata half it
    /// is not: a request for `value` yields a `.value_metadata` half and a
    /// `.value` half, each reporting its own tag.
    encoding: Encoding,
    /// The number of column entries the bytes hold, which is not the number
    /// of bytes and not the number of runs.
    len: usize,

    /// Releases the bytes.
    pub fn deinit(self: Encoded, gpa: Allocator) void {
        gpa.free(self.bytes);
    }

    /// Whether the canonical form writes a column at all. False for a boolean
    /// column with no `true` in it, which is what an omitted `expand` column
    /// means; a column with no bytes is dropped from a column set
    /// (`columns/raw_column.rs:40-50`, `:183`).
    pub fn isPresent(self: Encoded) bool {
        return self.bytes.len != 0;
    }
};

/// A value column pair: the metadata column and the payload column, side by
/// side. The caller owns both sets of bytes.
pub const ValuePair = struct {
    /// The metadata column: one word per value.
    meta: Encoded,
    /// The value column: the payloads, concatenated.
    raw: Encoded,

    /// Releases both sets of bytes.
    pub fn deinit(self: ValuePair, gpa: Allocator) void {
        self.meta.deinit(gpa);
        self.raw.deinit(gpa);
    }
};

/// Encodes `values` as one column of the kind `enc` names, and reports the
/// bytes and the tag they were written with.
///
/// A value that does not fit the tag's shape is refused rather than
/// reinterpreted: a `.boolean` column given a string is `error.InvalidValue`,
/// and a `.group` column given an absent row is `error.UnexpectedNull`
/// because its reader would refuse the column outright
/// (`column_range/generic/group.rs:76-79`).
///
/// A `value` request is `error.Unsupported`: a value column is a pair, and
/// `encodeValuePair` is the entry point for one.
pub fn encodeColumn(
    gpa: Allocator,
    col_id: u32,
    enc: Encoding,
    values: []const Cell,
) ParseError!Encoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (enc) {
        .group => try appendGroup(gpa, &out, values),
        .actor => try appendActor(gpa, &out, values),
        .rle_uint => try appendRleUint(gpa, &out, values),
        .delta => try appendDelta(gpa, &out, values),
        .boolean => try appendBoolean(gpa, &out, values, true),
        .string => try appendString(gpa, &out, values),
        .value_metadata => try appendValueMetadata(gpa, &out, values),
        .value => return error.Unsupported,
    }
    return .{
        .spec = ColumnSpec.make(col_id, enc, false),
        .bytes = try out.toOwnedSlice(gpa),
        .encoding = enc,
        .len = values.len,
    };
}

/// Encodes `values` as a boolean column that is written only when at least
/// one of them is `true`: upstream's `MaybeBooleanEncoder`
/// (`encoding/boolean.rs:131-140`), which is what the op set's `expand`
/// column uses.
///
/// An all-`false` column has no canonical form as a column, so this reports
/// `bytes.len == 0` and `isPresent() == false`, and the reader must supply
/// the column's `false`s from its absence — which is what
/// `MaybeBooleanDecoder` on an empty range does, by yielding no rows at all
/// (`encoding/boolean.rs:156-166`).
pub fn encodeMaybeBoolean(
    gpa: Allocator,
    col_id: u32,
    values: []const Cell,
) ParseError!Encoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendBoolean(gpa, &out, values, false);
    return .{
        .spec = ColumnSpec.make(col_id, .boolean, false),
        .bytes = try out.toOwnedSlice(gpa),
        .encoding = .boolean,
        .len = values.len,
    };
}

/// Encodes `values` as a value column pair: the metadata column and the
/// payload column, in that order, both with the same column id.
///
/// The two halves report their own tags, so neither reports the `value` that
/// was asked for. That difference is the format's: a value column is two
/// columns of one id (`change_op_columns.rs:327-336`).
///
/// **`values` is borrowed and the result is not.** Every payload a value
/// carries — the bytes of a `.str`, a `.bytes`, an `.actor_id`'s id or an
/// `.unknown`'s — must be readable for the duration of the call and no
/// longer: the pair copies each one into its own `raw` column before it
/// returns, so the caller may reuse or free the source the instant this
/// returns. The reverse is not true, and cannot be: the copy *is* the read, so
/// a payload that was freed by its producer faults here, inside the encoder,
/// long after the producer let it go.
///
/// **Upstream cannot reach that state.** `TxOp` holds an `OpBuilder<'static>`
/// ([`op.rs:164-170`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
/// so a `ScalarValue<'static>` in a `pending` vector can only be `Cow::Owned`
/// ([`types.rs:566-570`](../../github-automerge-automerge/rust/automerge/src/op_set2/types.rs))
/// and the borrow checker refuses a `pending` that borrows a local. Zig has no
/// lifetime parameter to copy, so the port's `ScalarValue` and `OpBuilder`
/// borrow whatever they are handed and the *producer* owes the copy. This
/// function is where that debt is read, not where it is paid.
pub fn encodeValuePair(
    gpa: Allocator,
    col_id: u32,
    values: []const ScalarValue,
) ParseError!ValuePair {
    var words: std.ArrayList(u64) = .empty;
    defer words.deinit(gpa);
    try words.ensureTotalCapacity(gpa, values.len);
    for (values) |v| words.appendAssumeCapacity(try metaWordOf(v));

    var meta: std.ArrayList(u8) = .empty;
    errdefer meta.deinit(gpa);
    try prefix.Prefix(u64).append(&meta, gpa, words.items);

    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(gpa);
    for (values) |v| try appendPayload(gpa, &raw, v);

    const meta_bytes = try meta.toOwnedSlice(gpa);
    errdefer gpa.free(meta_bytes);
    const raw_bytes = try raw.toOwnedSlice(gpa);

    return .{
        .meta = .{
            .spec = ColumnSpec.make(col_id, .value_metadata, false),
            .bytes = meta_bytes,
            .encoding = .value_metadata,
            .len = values.len,
        },
        .raw = .{
            .spec = ColumnSpec.make(col_id, .value, false),
            .bytes = raw_bytes,
            .encoding = .value,
            .len = values.len,
        },
    };
}

/// A group column's `num` column: one unsigned count per row, the number of
/// values the group's own columns hold for that row
/// (`column_range/generic/group.rs:12-14`, `:70-97`). A count may not be
/// absent.
fn appendGroup(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .uint => |u| scratch.appendAssumeCapacity(u),
        .null_value => return error.UnexpectedNull,
        else => return error.InvalidValue,
    };
    try rle.Rle(u64).append(out, gpa, scratch.items);
}

/// An actor column: an actor index, absent for the rows that name no actor —
/// the root object, and the string half of a key
/// (`column_range/obj_id.rs:127-143`, `column_range/key.rs:250-266`).
fn appendActor(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(?u32) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .uint => |u| scratch.appendAssumeCapacity(
            std.math.cast(u32, u) orelse return error.Overflow,
        ),
        .null_value => scratch.appendAssumeCapacity(null),
        else => return error.InvalidValue,
    };
    try rle.RleOption(u32).append(out, gpa, scratch.items);
}

/// A run-length column of unsigned integers. Nullable, because a column that
/// may be absent is one column whose RLE stream carries nulls, and the op set
/// reads an absent counter as the root object.
fn appendRleUint(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(?u64) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .uint => |u| scratch.appendAssumeCapacity(u),
        .null_value => scratch.appendAssumeCapacity(null),
        else => return error.InvalidValue,
    };
    try rle.RleOption(u64).append(out, gpa, scratch.items);
}

/// A delta column: every value stored as the difference from the one before
/// it, run length encoded (`encoding/delta.rs:10-13`).
fn appendDelta(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(?i64) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .int => |i| scratch.appendAssumeCapacity(i),
        .null_value => scratch.appendAssumeCapacity(null),
        else => return error.InvalidValue,
    };
    try delta.Delta(?i64).append(out, gpa, scratch.items);
}

/// A boolean column: a sequence of run counts and no value bytes at all
/// (`encoding/boolean.rs:7-12`). With `always_present` false the column is
/// omitted when no value is `true`, which is `MaybeBooleanEncoder`.
fn appendBoolean(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    values: []const Cell,
    always_present: bool,
) ParseError!void {
    var scratch: std.ArrayList(bool) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    var any_true = false;
    for (values) |v| switch (v) {
        .boolean => |b| {
            any_true = any_true or b;
            scratch.appendAssumeCapacity(b);
        },
        else => return error.InvalidValue,
    };
    if (!any_true and !always_present) return;
    try bool_codec.Bool.append(out, gpa, scratch.items);
}

/// A string column: a run-length column whose payload is a byte length and the
/// bytes it names.
fn appendString(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(?[]const u8) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .string => |s| scratch.appendAssumeCapacity(s),
        .null_value => scratch.appendAssumeCapacity(null),
        else => return error.InvalidValue,
    };
    try RleSlice.append(out, gpa, scratch.items);
}

/// A value metadata column: one word per value, in the prefix column's
/// encoding. A word may not be absent, because the reader treats an absent
/// one as a corrupt column (`column_range/value.rs:269`).
fn appendValueMetadata(gpa: Allocator, out: *std.ArrayList(u8), values: []const Cell) ParseError!void {
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(gpa);
    try scratch.ensureTotalCapacity(gpa, values.len);
    for (values) |v| switch (v) {
        .uint => |u| scratch.appendAssumeCapacity(u),
        .null_value => return error.UnexpectedNull,
        else => return error.InvalidValue,
    };
    try prefix.Prefix(u64).append(out, gpa, scratch.items);
}

/// Appends the payload of one value to the value column, which carries no
/// length prefix of its own: the length is in the metadata word
/// (`column_range/value.rs:356-370`).
///
/// **`v`'s payload is borrowed, and only for this call.** This is the read a
/// freed payload faults in, so the caller's obligation is the whole of
/// [`encodeValuePair`]'s: the bytes must be there now. Nothing here can tell a
/// live slice from a dead one, and copying defensively would read the dead one
/// to find out.
fn appendPayload(gpa: Allocator, out: *std.ArrayList(u8), v: ScalarValue) ParseError!void {
    switch (v) {
        // These three carry their whole value in the metadata word, so the
        // value column gets no bytes for them.
        .null_value, .bool_value => {},
        .uint => |u| try leb128.appendUnsigned(out, gpa, u),
        .int => |i| try leb128.appendSigned(out, gpa, i),
        .counter => |c| try leb128.appendSigned(out, gpa, c.current),
        .timestamp => |t| try leb128.appendSigned(out, gpa, t),
        .float => |f| blk: {
            // Little-endian, matching `ValueDecoder.next`'s float arm above
            // and upstream's `self.to_le_bytes()`
            // (`columnar/encoding/encodable_impls.rs:74-78`). A `@bitCast`
            // into `[8]u8` is host order, so a big-endian build wrote this
            // document's float payloads reversed for every reader — including
            // this port's own reader, which is why the round-trip test stayed
            // green while the bytes disagreed with the reference.
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(f), .little);
            try out.appendSlice(gpa, &buf);
            break :blk;
        },
        .str => |s| try out.appendSlice(gpa, s),
        .bytes => |b| try out.appendSlice(gpa, b),
        .actor_id => |a| try out.appendSlice(gpa, a.bytes),
        .unknown => |u| try out.appendSlice(gpa, u.bytes),
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Whether a value survived the value column pair. An actor id is written as
/// an opaque byte payload and reads back as `bytes`, because the wire has no
/// actor tag of its own: the reference to an actor lives in the key columns
/// (`value.zig:138-140`).
fn sameStoredValue(want: ScalarValue, got: ScalarValue) bool {
    if (want == .actor_id) {
        const a = want.actor_id;
        return got == .bytes and std.mem.eql(u8, a.bytes, got.bytes);
    }
    return got.eql(want);
}

/// Encodes `values` as a column of the kind `enc` names.
fn encodeCells(gpa: Allocator, enc: Encoding, values: []const Cell) ParseError!Encoded {
    return encodeColumn(gpa, 7, enc, values);
}

/// Reads a whole column back through the cursor.
fn cellsOf(gpa: Allocator, enc: Encoding, bytes: []const u8) ParseError![]Cell {
    return decodeAll(gpa, ColumnSpec.make(7, enc, false), bytes);
}

/// Encodes `values`, then holds the cursor, the bulk decode and the input
/// against each other. The three must agree, and the bytes must be what a
/// second implementation of the same grammar would write, which is what makes
/// the two a format rather than a private encoding.
fn expectRoundTrip(gpa: Allocator, enc: Encoding, values: []const Cell) !void {
    const enc1 = try encodeCells(gpa, enc, values);
    defer enc1.deinit(gpa);
    try testing.expectEqual(enc, enc1.encoding);
    try testing.expectEqual(values.len, enc1.len);
    try testing.expectEqual(ColumnSpec.make(7, enc, false), enc1.spec);

    // The cursor and the bulk decode must be the same sequence.
    const bulk = try cellsOf(gpa, enc, enc1.bytes);
    defer gpa.free(bulk);
    try testing.expectEqual(values.len, bulk.len);

    var dec = try Decoder.init(enc1.spec, enc1.bytes);
    for (values, bulk) |want, from_bulk| {
        const got = (try dec.next()) orelse return error.TestUnexpectedResult;
        try testing.expect(want.eql(got));
        try testing.expect(from_bulk.eql(got));
    }
    try testing.expect((try dec.next()) == null);
}

test "the eight tags are the format's, and a tag outside them is refused" {
    inline for (.{
        Encoding.group, .actor,  .rle_uint,       .delta,
        .boolean,       .string, .value_metadata, .value,
    }) |tag| {
        const enc: Encoding = tag;
        try testing.expectEqual(enc, try encodingFromTag(@intFromEnum(enc)));
    }
    // Three bits, so there is no ninth tag: the fourth low bit of a whole
    // specification is the DEFLATE flag (`column_specification.rs:21-29`).
    try testing.expectError(error.InvalidEncoding, encodingFromTag(8));
    try testing.expectError(error.InvalidEncoding, encodingFromTag(0xff));
    try testing.expectError(error.InvalidEncoding, Decoder.initTag(8, &.{}));
    try testing.expectError(error.InvalidEncoding, Decoder.initTag(0x80, &.{1}));
}

test "a group column is a run of counts and refuses an absent one" {
    const values = [_]Cell{
        .{ .uint = 1 },
        .{ .uint = 1 },
        .{ .uint = 0 },
        .{ .uint = 3 },
    };
    try expectRoundTrip(testing.allocator, .group, &values);
    // A count repeated twice is a repeat run, and the two counts that follow
    // it are distinct, so they are one literal run of two: `7e` is the header
    // for -2.
    const enc = try encodeCells(testing.allocator, .group, &values);
    defer enc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x7e, 0x00, 0x03 }, enc.bytes);
    try testing.expectError(
        error.UnexpectedNull,
        encodeCells(testing.allocator, .group, &.{Cell.null_value}),
    );
}

test "an actor column is a nullable run of indices" {
    const values = [_]Cell{
        .{ .uint = 0 },
        absent,
        absent,
        .{ .uint = 7 },
    };
    try expectRoundTrip(testing.allocator, .actor, &values);
    // literal(0) `7f 00`, null run of 2 `00 02`, literal(7) `7f 07`.
    const enc = try encodeCells(testing.allocator, .actor, &values);
    defer enc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0x00, 0x00, 0x02, 0x7f, 0x07 }, enc.bytes);
    // An actor index is a `u32`, so an index past that is not a column.
    try testing.expectError(
        error.Overflow,
        encodeCells(testing.allocator, .actor, &.{Cell{ .uint = 1 << 33 }}),
    );
}

test "an rle_uint column is a nullable run of unsigned integers" {
    const values = [_]Cell{
        .{ .uint = 3 },
        absent,
        absent,
        .{ .uint = 3 },
    };
    try expectRoundTrip(testing.allocator, .rle_uint, &values);
    const enc = try encodeCells(testing.allocator, .rle_uint, &values);
    defer enc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0x03, 0x00, 0x02, 0x7f, 0x03 }, enc.bytes);
}

test "a delta column is the differences of its values" {
    const values = [_]Cell{
        .{ .int = 1 },
        .{ .int = 2 },
        .{ .int = 3 },
        absent,
        .{ .int = -4 },
    };
    try expectRoundTrip(testing.allocator, .delta, &values);
    const enc = try encodeCells(testing.allocator, .delta, &values);
    defer enc.deinit(testing.allocator);
    // Deltas 1, 1, 1, null, -7: a repeat run of 3 ones, a null run of 1, and
    // a literal run of one delta.
    try testing.expectEqualSlices(
        u8,
        &.{ 0x03, 0x01, 0x00, 0x01, 0x7f, 0x79 },
        enc.bytes,
    );
}

test "a boolean column is a sequence of run counts" {
    const values = [_]Cell{
        .{ .boolean = false },
        .{ .boolean = false },
        .{ .boolean = true },
        .{ .boolean = false },
    };
    try expectRoundTrip(testing.allocator, .boolean, &values);
    // Two falses, one true, one false, alternating from `false`.
    const enc = try encodeCells(testing.allocator, .boolean, &values);
    defer enc.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x01 }, enc.bytes);
}

test "a boolean column with no true has no canonical form as a column" {
    const gpa = testing.allocator;
    const values = [_]Cell{
        .{ .boolean = false },
        .{ .boolean = false },
        .{ .boolean = false },
    };
    // The plain encoder always writes a column: one run count.
    const plain = try encodeCells(gpa, .boolean, &values);
    defer plain.deinit(gpa);
    try testing.expect(plain.isPresent());
    try testing.expectEqualSlices(u8, &.{0x03}, plain.bytes);

    // `MaybeBooleanEncoder` discards it, and the reader supplies the falses
    // from the column's absence.
    const maybe = try encodeMaybeBoolean(gpa, 7, &values);
    defer maybe.deinit(gpa);
    try testing.expectEqual(.boolean, maybe.encoding);
    try testing.expect(!maybe.isPresent());
    try testing.expectEqual(@as(usize, 0), maybe.bytes.len);

    // An empty column is the same thing, and it is not an error.
    const none = try encodeMaybeBoolean(gpa, 7, &.{});
    defer none.deinit(gpa);
    try testing.expect(!none.isPresent());
}

test "a string column is a run of length-prefixed strings" {
    const gpa = testing.allocator;
    const values = [_]Cell{
        .{ .string = "a" },
        .{ .string = "a" },
        .{ .string = "b" },
        absent,
        absent,
        .{ .string = "c" },
    };
    try expectRoundTrip(gpa, .string, &values);
    const enc = try encodeCells(gpa, .string, &values);
    defer enc.deinit(gpa);
    // repeat("a", 2), literal("b"), null run of 2, literal("c").
    try testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x01, 'a', 0x7f, 0x01, 'b', 0x00, 0x02, 0x7f, 0x01, 'c' },
        enc.bytes,
    );
    try RleSlice.canonical(enc.bytes);
}

test "a string column round trips every shape, and its bytes are canonical" {
    const gpa = testing.allocator;
    // Runs of one, two and many, with absent rows at both ends and in the
    // middle, and an empty string, which is a present value of length 0.
    const shapes = [_][]const ?[]const u8{
        &.{},
        &.{""},
        &.{ "", "" },
        &.{ "a", "a" },
        &.{ null, "a", null },
        &.{ "aa", null, null, "bb", "bb", "bb", null },
        &.{ "x", "y", "z", "x", "y", "z" },
    };
    for (shapes) |shape| {
        const cells = try gpa.alloc(Cell, shape.len);
        defer gpa.free(cells);
        for (shape, cells) |s, *c| {
            c.* = if (s) |bytes| Cell{ .string = bytes } else absent;
        }
        try expectRoundTrip(gpa, .string, cells);

        const enc = try encodeCells(gpa, .string, cells);
        defer enc.deinit(gpa);
        try RleSlice.canonical(enc.bytes);

        // The bulk decode and the cursor agree on every shape.
        const bulk = try RleSlice.decodeAll(enc.bytes, gpa);
        defer gpa.free(bulk);
        try testing.expectEqual(cells.len, bulk.len);
        for (bulk, cells) |got, want| {
            switch (want) {
                .string => |w| {
                    const got_str = got orelse return error.TestUnexpectedResult;
                    try testing.expectEqualStrings(w, got_str);
                },
                .null_value => try testing.expect(got == null),
                // `expectRoundTrip` above already covered the other shapes;
                // this loop only walks the strings.
                else => return error.TestUnexpectedResult,
            }
        }
    }
}

test "a value metadata column is a prefix column of words" {
    const gpa = testing.allocator;
    // Three words: a one-byte uleb, a two-byte string, and a null.
    const values = [_]Cell{
        .{ .uint = 0x13 },
        .{ .uint = 0x26 },
        .{ .uint = 0x00 },
    };
    try expectRoundTrip(gpa, .value_metadata, &values);
    const enc = try encodeCells(gpa, .value_metadata, &values);
    defer enc.deinit(gpa);
    // One literal run of three: `7d` is the header for -3.
    try testing.expectEqualSlices(u8, &.{ 0x7d, 0x13, 0x26, 0x00 }, enc.bytes);
    // An absent metadata word is a corrupt column, not an empty one.
    try testing.expectError(
        error.UnexpectedNull,
        encodeCells(gpa, .value_metadata, &.{absent}),
    );
    // The length fields of the words add up to the length of the payload
    // column they describe, which is the cross-check between the two halves
    // of a value pair: 1 + 2 + 0.
    const words = try prefix.Prefix(u64).decodeAll(enc.bytes, gpa);
    defer gpa.free(words);
    var declared: usize = 0;
    for (words) |w| declared += w >> 4;
    try testing.expectEqual(@as(usize, 3), declared);
}

test "a value column pair round trips every scalar" {
    const gpa = testing.allocator;
    const values = [_]ScalarValue{
        .null_value,
        .{ .bool_value = true },
        .{ .bool_value = false },
        .{ .uint = 0 },
        .{ .uint = 300 },
        .{ .int = -1 },
        .{ .int = -1 << 40 },
        .{ .float = 0.5 },
        .{ .float = -0.0 },
        .{ .actor_id = .{ .bytes = "actor" } },
        .{ .counter = .init(7) },
        .{ .timestamp = -3 },
        .{ .unknown = .{ .type_code = 12, .bytes = "xy" } },
    };
    const pair = try encodeValuePair(gpa, 5, &values);
    defer pair.deinit(gpa);

    // Neither half reports the tag that was asked for: a value column is a
    // pair, and the two halves carry their own tags
    // (`change_op_columns.rs:327-336`).
    try testing.expectEqual(Encoding.value_metadata, pair.meta.encoding);
    try testing.expectEqual(Encoding.value, pair.raw.encoding);
    try testing.expectEqual(ColumnSpec.make(5, .value_metadata, false), pair.meta.spec);
    try testing.expectEqual(ColumnSpec.make(5, .value, false), pair.raw.spec);
    try testing.expectEqual(values.len, pair.meta.len);
    try testing.expectEqual(values.len, pair.raw.len);
    try testing.expectEqual(@as(usize, 5), pair.meta.spec.id());
    try testing.expectEqual(@as(usize, 5), pair.raw.spec.id());

    // The cursor and the bulk decode must both give the values back.
    const bulk = try decodeValuePair(gpa, pair.meta.bytes, pair.raw.bytes);
    defer gpa.free(bulk);
    try testing.expectEqual(values.len, bulk.len);

    var dec = try Decoder.initValuePair(pair.meta.spec, pair.meta.bytes, pair.raw.bytes);
    for (values, bulk) |want, from_bulk| {
        const got = (try dec.nextValue()) orelse return error.TestUnexpectedResult;
        try testing.expect(sameStoredValue(want, got));
        try testing.expect(sameStoredValue(want, from_bulk));
    }
    try testing.expect((try dec.next()) == null);

    // Re-encoding the pair gives the same bytes, so the writer and the
    // reader are held to the same shape.
    const again = try encodeValuePair(gpa, 5, &values);
    defer again.deinit(gpa);
    try testing.expectEqualSlices(u8, pair.meta.bytes, again.meta.bytes);
    try testing.expectEqualSlices(u8, pair.raw.bytes, again.raw.bytes);
}

test "a float value column's payload is the reference's eight little-endian bytes" {
    // **A round trip is the wrong instrument here, and the round-trip test
    // above is why this defect survived.** Its writer and its reader were both
    // host-order, so they agreed with each other on every host and with the
    // reference on none of them: `0.5` re-encoded to the same wrong bytes on
    // powerpc64 exactly as it did here. **Two halves that are wrong in the
    // same direction cannot be caught by comparing them to each other.** What
    // pins the wire is the bytes themselves, spelled out here, and a read of
    // bytes this process did not write.
    //
    // The expected bytes are upstream's: `to_le_bytes`
    // (`columnar/encoding/encodable_impls.rs:74-78`), so `1.5` is
    // `0x3FF8000000000000` least significant byte first — `f8` at index 6 and
    // `3f` at index 7. `-0.0` is in the pair because it is the value that
    // would pass any equality check written as `==`: its sign bit is the only
    // thing that separates it from `0.0`, and it is byte 7.
    const gpa = testing.allocator;
    const pair = try encodeValuePair(gpa, 5, &.{
        .{ .float = 1.5 },
        .{ .float = -0.0 },
    });
    defer pair.deinit(gpa);

    const one_point_five = [_]u8{ 0, 0, 0, 0, 0, 0, 0xf8, 0x3f };
    const negative_zero = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0x80 };
    try testing.expectEqualSlices(u8, &one_point_five, pair.raw.bytes[0..8]);
    try testing.expectEqualSlices(u8, &negative_zero, pair.raw.bytes[8..16]);

    // The other direction, and it is the half that was independently wrong: a
    // cursor handed the reference's bytes must name the numbers those bytes
    // spell. Feeding the array in rather than this build's own output is what
    // makes it a check on the reader instead of an agreement between two arms
    // of the same mistake.
    var dec = try ValueDecoder.init(pair.meta.bytes, &[_]u8{
        0, 0, 0, 0, 0, 0, 0xf8, 0x3f, 0, 0, 0, 0, 0, 0, 0, 0x80,
    });
    const first = (try dec.next()) orelse return error.TestUnexpectedResult;
    switch (first) {
        .float => |f| try testing.expectEqual(@as(f64, 1.5), f),
        else => return error.TestUnexpectedResult,
    }
    // `==` accepts a `0.0` here, so the sign bit is compared as bits.
    const second = (try dec.next()) orelse return error.TestUnexpectedResult;
    switch (second) {
        .float => |f| try testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(f))),
        else => return error.TestUnexpectedResult,
    }
    try testing.expect((try dec.next()) == null);
}

test "the encoded pair copies the payloads it is given and never aliases them" {
    const gpa = testing.allocator;
    // **The contract this pins is the one the change encoder stands on.** A
    // `ScalarValue` borrows its payload, and the value column pair is where
    // those borrows are read a second time — at commit, after whatever buffer
    // the producer named them in has been given back. The pair's bytes are
    // the encoder's own, so the copy has to have happened here: a value whose
    // buffer is reused the moment `encodeValuePair` returns must still read
    // back as the characters that were in it at the call.
    //
    // Upstream never reaches the question. Its `TxOp` holds an
    // `OpBuilder<'static>` (`op.rs:164-170`), so a `pending` operation
    // cannot hold a borrow of a local at all, and the copy is made where the
    // value is built (`inner.rs:1481-1501`) rather than where it is written
    // out.
    const buf = try gpa.dupe(u8, "hello");
    defer gpa.free(buf);
    const pair = try encodeValuePair(gpa, 5, &.{
        .{ .str = buf[0..1] },
        .{ .str = buf[1..5] },
    });
    defer pair.deinit(gpa);

    // The caller takes the buffer back and overwrites it, which is exactly
    // what `TxHook.insert`'s `concat` and `BlockDiffHook.insert`'s `run` do
    // when their hook returns (`textdiff.zig`).
    @memset(buf, 'Z');

    var dec = try ValueDecoder.init(pair.meta.bytes, pair.raw.bytes);
    const first = (try dec.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("h", first.str);
    const second = (try dec.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("ello", second.str);
    try testing.expect((try dec.next()) == null);
}

test "the pair's two halves are the metadata word and the payload" {
    const gpa = testing.allocator;
    const values = [_]ScalarValue{
        .{ .uint = 1 },
        .{ .str = "ab" },
        .null_value,
    };
    const pair = try encodeValuePair(gpa, 5, &values);
    defer pair.deinit(gpa);
    // Metadata: `(1 << 4) | 3`, `(2 << 4) | 6`, and `0` for a null — one
    // literal run of three.
    try testing.expectEqualSlices(u8, &.{ 0x7d, 0x13, 0x26, 0x00 }, pair.meta.bytes);
    // Value column: the uleb 1, then the two bytes of the string, then
    // nothing for the null. No length prefix of its own.
    try testing.expectEqualSlices(u8, &.{ 0x01, 'a', 'b' }, pair.raw.bytes);
    // A counter is type code 8 and a timestamp is 9, which is what makes them
    // read back as themselves (`column_range/value.rs:412-435`).
    // The length field of both is the size of the signed LEB128 the payload
    // is written in, so a counter of 1 is one byte long.
    try testing.expectEqual(@as(u64, 0x18), try metaWordOf(.{ .counter = .init(1) }));
    try testing.expectEqual(@as(u64, 0x19), try metaWordOf(.{ .timestamp = 1 }));
    try testing.expectEqual(@as(u64, 0x2c), try metaWordOf(.{ .unknown = .{ .type_code = 12, .bytes = "xy" } }));
}

test "a metadata word naming an unknown type is preserved, not rejected" {
    const gpa = testing.allocator;
    // Type code 12 is outside the ten this port knows, so a document written
    // by a future version must survive a round trip through this one
    // (`column_range/value.rs:254-259`).
    const values = [_]ScalarValue{
        .{ .unknown = .{ .type_code = 12, .bytes = "future" } },
        .{ .unknown = .{ .type_code = 15, .bytes = "" } },
        .{ .uint = 7 },
    };
    const pair = try encodeValuePair(gpa, 5, &values);
    defer pair.deinit(gpa);
    const bulk = try decodeValuePair(gpa, pair.meta.bytes, pair.raw.bytes);
    defer gpa.free(bulk);
    try testing.expectEqual(values.len, bulk.len);
    for (values, bulk) |want, got| try testing.expect(got.eql(want));
    try testing.expectEqual(@as(u8, 12), bulk[0].unknown.type_code);
    try testing.expectEqualStrings("future", bulk[0].unknown.bytes);
    try testing.expectEqual(@as(u8, 15), bulk[1].unknown.type_code);
    try testing.expectEqual(@as(usize, 0), bulk[1].unknown.bytes.len);
    // A hand-built word naming the *first* unknown code, 10, reads back as
    // that code and those bytes, without an error.
    const meta_bytes = [_]u8{ 0x02, 0x2a, 0x61 };
    var dec = try ValueDecoder.init(&meta_bytes, "zz");
    const got = (try dec.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u8, 10), got.unknown.type_code);
    try testing.expectEqualStrings("zz", got.unknown.bytes);
}

test "a value length that runs past the end is refused without allocating" {
    // A metadata word claiming two bytes for a string, with two bytes in the
    // value column. The length came off the wire, so it is checked against
    // what remains before anything is taken
    // (`column_range/value.rs:260-264`).
    const one_word = [_]u8{ 0x02, 0x26, 0x61 };
    const raw_bytes = [_]u8{ 'z', 'z' };

    // The metadata column holds two words of the same kind and the value
    // column holds one payload: the first value is read and the second runs
    // off the end.
    var dec = try ValueDecoder.init(&one_word, &raw_bytes);
    const read = (try dec.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zz", read.str);
    try testing.expectError(error.LengthExceedsInput, dec.next());

    // A column that holds one value and no more: the very first read is
    // already past the end.
    const empty_raw = [_]u8{};
    var dec2 = try ValueDecoder.init(&one_word, &empty_raw);
    try testing.expectError(error.LengthExceedsInput, dec2.next());

    // The payload is borrowed from the value column rather than copied, which
    // is the structural form of "no allocation to size": a declared length can
    // only ever be compared against the bytes that are there, and the slice
    // that comes back points into the caller's own buffer.
    var dec3 = try ValueDecoder.init(&one_word, &raw_bytes);
    const got = (try dec3.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zz", got.str);
    const base = @intFromPtr(&raw_bytes);
    const borrowed = @intFromPtr(got.str.ptr);
    try testing.expect(borrowed >= base and borrowed + got.str.len <= base + raw_bytes.len);

    // Three words of two bytes each against a two-byte column: the first is
    // read, and the two that follow it are refused without the cursor ever
    // reading past the end.
    const many = [_]u8{ 0x03, 0x26, 0x61, 0x26, 0x61 };
    var dec4 = try ValueDecoder.init(&many, &raw_bytes);
    const first = (try dec4.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("zz", first.str);
    try testing.expectError(error.LengthExceedsInput, dec4.next());
    try testing.expectError(error.LengthExceedsInput, dec4.next());
}

test "the value reader takes nothing for a value that has no payload" {
    const gpa = testing.allocator;
    // A null, a false and a true are three metadata words and no value
    // column bytes at all (`column_range/value.rs:222-225`).
    const values = [_]ScalarValue{ .null_value, .{ .bool_value = false }, .{ .bool_value = true } };
    const pair = try encodeValuePair(gpa, 5, &values);
    defer pair.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), pair.raw.bytes.len);
    try testing.expect(!pair.raw.isPresent());
    const bulk = try decodeValuePair(gpa, pair.meta.bytes, pair.raw.bytes);
    defer gpa.free(bulk);
    for (values, bulk) |want, got| try testing.expect(got.eql(want));
}

test "a value whose payload is not the number it claims is refused" {
    // A word claiming two bytes for a uleb, with a one-byte payload: the
    // payload and the word disagree, which upstream reports as "extra bytes"
    // (`column_range/value.rs:293-309`).
    const meta_bytes = [_]u8{ 0x02, 0x23, 0x61, 0x62 };
    var dec = try ValueDecoder.init(&meta_bytes, meta_bytes[2..]);
    try testing.expectError(error.InvalidValue, dec.next());

    // A float is exactly eight bytes, and any other length is a hard error
    // (`column_range/value.rs:233-240`). The eight bytes are there, so the
    // length is what is refused.
    const short_float = [_]u8{ 0x02, 0x45, 0x61, 0x62 };
    var dec2 = try ValueDecoder.init(&short_float, "abcdefgh");
    try testing.expectError(error.InvalidValue, dec2.next());

    // A string is UTF-8, and a payload that is present but is not is refused
    // (`encoding/decodable_impls.rs:112-137`).
    const bad_string = [_]u8{ 0x02, 0x26, 0x61 };
    var dec3 = try ValueDecoder.init(&bad_string, "\xff\xfe");
    try testing.expectError(error.InvalidUtf8, dec3.next());
}

test "an empty column and a column of one value" {
    const gpa = testing.allocator;
    // Every tag, empty. The bytes are empty and the cursor yields no values.
    inline for (.{
        Encoding.group, .actor,  .rle_uint,       .delta,
        .boolean,       .string, .value_metadata,
    }) |enc| {
        const enc1 = try encodeCells(gpa, enc, &.{});
        defer enc1.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), enc1.bytes.len);
        try testing.expectEqual(@as(usize, 0), enc1.len);
        try testing.expect(!enc1.isPresent());

        var dec = try Decoder.init(enc1.spec, enc1.bytes);
        try testing.expect((try dec.next()) == null);
        const bulk = try cellsOf(gpa, enc, enc1.bytes);
        defer gpa.free(bulk);
        try testing.expectEqual(@as(usize, 0), bulk.len);
    }

    // Every tag, one value. A single value costs a literal run of one, except
    // in a boolean column, where it costs one run count.
    const one = [_]struct { enc: Encoding, cell: Cell, bytes: []const u8 }{
        .{ .enc = .group, .cell = .{ .uint = 4 }, .bytes = &.{ 0x7f, 0x04 } },
        .{ .enc = .actor, .cell = .{ .uint = 4 }, .bytes = &.{ 0x7f, 0x04 } },
        .{ .enc = .rle_uint, .cell = .{ .uint = 4 }, .bytes = &.{ 0x7f, 0x04 } },
        .{ .enc = .delta, .cell = .{ .int = -4 }, .bytes = &.{ 0x7f, 0x7c } },
        .{ .enc = .boolean, .cell = .{ .boolean = true }, .bytes = &.{ 0x00, 0x01 } },
        .{ .enc = .string, .cell = .{ .string = "q" }, .bytes = &.{ 0x7f, 0x01, 'q' } },
        .{ .enc = .value_metadata, .cell = .{ .uint = 0x11 }, .bytes = &.{ 0x7f, 0x11 } },
    };
    for (one) |case| {
        const enc1 = try encodeCells(gpa, case.enc, &.{case.cell});
        defer enc1.deinit(gpa);
        try testing.expectEqualSlices(u8, case.bytes, enc1.bytes);
        try testing.expectEqual(@as(usize, 1), enc1.len);
        try testing.expect(enc1.isPresent());
        var dec = try Decoder.init(enc1.spec, enc1.bytes);
        const got = (try dec.next()) orelse return error.TestUnexpectedResult;
        try testing.expect(case.cell.eql(got));
        try testing.expect((try dec.next()) == null);
    }

    // A value pair of one value, and an empty one.
    const one_value = [_]ScalarValue{.{ .str = "z" }};
    const pair = try encodeValuePair(gpa, 5, &one_value);
    defer pair.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), pair.meta.len);
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0x16 }, pair.meta.bytes);
    try testing.expectEqualSlices(u8, &.{'z'}, pair.raw.bytes);

    const no_values = try encodeValuePair(gpa, 5, &.{});
    defer no_values.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), no_values.meta.bytes.len);
    try testing.expectEqual(@as(usize, 0), no_values.raw.bytes.len);
    const bulk = try decodeValuePair(gpa, no_values.meta.bytes, no_values.raw.bytes);
    defer gpa.free(bulk);
    try testing.expectEqual(@as(usize, 0), bulk.len);
}

test "a value column is a pair, and a lone one is refused" {
    const gpa = testing.allocator;
    // Asking a single column for a value payload is a category error, and
    // upstream's layout parser refuses the column that would say it
    // (`columns.rs:216`).
    try testing.expectError(
        error.Unsupported,
        encodeCells(gpa, .value, &.{.{ .value = .null_value }}),
    );
    try testing.expectError(
        error.Unsupported,
        Decoder.init(ColumnSpec.make(5, .value, false), "abc"),
    );
    // A pair is only a pair with its metadata half.
    try testing.expectError(
        error.InvalidEncoding,
        Decoder.initValuePair(ColumnSpec.make(5, .rle_uint, false), &.{}, &.{}),
    );
    var ok = try Decoder.initValuePair(ColumnSpec.make(5, .value_metadata, false), &.{}, &.{});
    try testing.expectEqual(Encoding.value_metadata, ok.encoding());
    try testing.expectEqual(@as(u32, 5), ok.id());
    try testing.expect((try ok.next()) == null);
}

test "a column refuses a value that is not of its shape" {
    const gpa = testing.allocator;
    // A boolean column given a string, an actor column given a signed value,
    // a string column given a number: each is a caller mistake, and each is
    // refused rather than reinterpreted.
    try testing.expectError(
        error.InvalidValue,
        encodeCells(gpa, .boolean, &.{.{ .string = "no" }}),
    );
    try testing.expectError(
        error.InvalidValue,
        encodeCells(gpa, .actor, &.{.{ .int = 1 }}),
    );
    try testing.expectError(
        error.InvalidValue,
        encodeCells(gpa, .string, &.{.{ .uint = 1 }}),
    );
    try testing.expectError(
        error.InvalidValue,
        encodeCells(gpa, .value_metadata, &.{.{ .boolean = true }}),
    );
    // And a delta column whose differences leave the i64 the wire carries.
    try testing.expectError(
        error.Overflow,
        encodeCells(gpa, .delta, &.{
            Cell{ .int = std.math.minInt(i64) },
            Cell{ .int = std.math.maxInt(i64) },
        }),
    );
}

test "the typed readers hand out one kind of value and refuse the rest" {
    const gpa = testing.allocator;
    const values = [_]Cell{ .{ .uint = 11 }, absent, .{ .uint = 12 } };
    const enc = try encodeCells(gpa, .rle_uint, &values);
    defer enc.deinit(gpa);
    var dec = try Decoder.init(enc.spec, enc.bytes);
    try testing.expectEqual(@as(?u64, 11), try dec.nextUint());
    // The absent row is the inner null, which is not the end of the column.
    try testing.expectEqual(@as(?u64, null), try dec.nextUint());
    try testing.expectEqual(@as(?u64, 12), try dec.nextUint());
    // And once the column is exhausted, every reader agrees that it is over.
    try testing.expectEqual(@as(?u64, null), try dec.nextUint());
    try testing.expectEqual(@as(??[]const u8, null), try dec.nextString());
    // A string reader on an integer column is a mismatch, not a null, and it
    // consumes the row it read, so it is asked on a column of its own.
    var other = try Decoder.init(enc.spec, enc.bytes);
    try testing.expectError(error.InvalidValue, other.nextString());

    const strings = [_]Cell{ .{ .string = "a" }, absent };
    const senc = try encodeCells(gpa, .string, &strings);
    defer senc.deinit(gpa);
    var sdec = try Decoder.init(senc.spec, senc.bytes);
    // The outer null is the end of the column, the inner one an absent row.
    const first = (try sdec.nextString()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a", first.?);
    const second = (try sdec.nextString()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?[]const u8, null), second);
    try testing.expectEqual(@as(??[]const u8, null), try sdec.nextString());

    // And an unsigned reader on a string column is the same mismatch.
    var other2 = try Decoder.init(senc.spec, senc.bytes);
    try testing.expectError(error.InvalidValue, other2.nextUint());
}

test "a malformed column is refused as a ParseError" {
    // A repeat run whose payload the slab does not hold. The opening run
    // header is read by `init`, so that is where the column is refused.
    const bad_repeat = [_]u8{0x05};
    try testing.expectError(
        error.UnexpectedEnd,
        Decoder.init(ColumnSpec.make(1, .rle_uint, false), &bad_repeat),
    );

    // A literal run claiming four values with one byte left to hold them.
    const bad_literal = [_]u8{ 0x7c, 0x01 };
    try testing.expectError(
        error.LengthExceedsInput,
        Decoder.init(ColumnSpec.make(1, .rle_uint, false), &bad_literal),
    );

    // A null run in a column that has no absent rows.
    const null_run = [_]u8{ 0x00, 0x02 };
    try testing.expectError(
        error.UnexpectedNull,
        Decoder.init(ColumnSpec.make(1, .group, false), &null_run),
    );

    // A truncated LEB128 run count in a boolean column.
    const bad_bool = [_]u8{0x80};
    var dec4 = try Decoder.init(ColumnSpec.make(1, .boolean, false), &bad_bool);
    try testing.expectError(error.UnexpectedEnd, dec4.next());

    // A string payload whose declared length runs past the slab: a repeat run
    // of two strings of nine bytes each, with one byte in the slab.
    const bad_string = [_]u8{ 0x02, 0x09, 'a' };
    try testing.expectError(
        error.UnexpectedEnd,
        Decoder.init(ColumnSpec.make(1, .string, false), &bad_string),
    );

    // A value column whose metadata word declares a length the value column
    // does not hold.
    var dec6 = try ValueDecoder.init(&[_]u8{ 0x7f, 0x3c }, "");
    try testing.expectError(error.LengthExceedsInput, dec6.next());
}

// The three counter fixtures, at the level this module decodes them. The
// `value_metadata` column of all three is the two bytes `7f 28`: one literal
// run of one, whose word is `(2 << 4) | 8` — two payload bytes, type code 8,
// a counter (`column_range/value.rs:412-435`). The `value` column is what
// differs, and it is the only column the three fixtures disagree about.
const counter_meta = [_]u8{ 0x7f, 0x28 };

test "an overlong LEB in a counter payload is refused, and the short form is not" {
    // `counter_value_is_ok.automerge`: 2000 as `d0 0f`, the two bytes it
    // needs. Upstream loads it (`rust/automerge/tests/test.rs:2232-2233`).
    var ok = try ValueDecoder.init(&counter_meta, &[_]u8{ 0xd0, 0x0f });
    const good = (try ok.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 2000), good.counter.current);

    // `counter_value_is_overlong.automerge`: -48 as `d0 7f`, where the one
    // byte `40` would do. Upstream refuses the load
    // (`rust/automerge/tests/test.rs:2230-2231`).
    var over = try ValueDecoder.init(&counter_meta, &[_]u8{ 0xd0, 0x7f });
    try testing.expectError(error.InvalidLeb128, over.next());

    // `counter_value_has_incorrect_meta.automerge`: the same word, but the
    // payload is `10 7f`, whose LEB is one byte and whose second byte the
    // word does not account for. That is a *different* refusal and it must
    // still be the one that fires: the two fixtures must not end up
    // indistinguishable (`rust/automerge/tests/test.rs:2228-2229`).
    var short = try ValueDecoder.init(&counter_meta, &[_]u8{ 0x10, 0x7f });
    try testing.expectError(error.InvalidValue, short.next());
}

test "an overlong LEB is refused for every value type that carries one" {
    // The three *signed* types — 4, 8 and 9 — each under a word declaring two
    // payload bytes (`column_range/value.rs:226`, `:249` and `:252`; the code
    // table is `meta.rs:23-43`, as recorded in
    // docs/survey/02-transaction-opset.md:1151). The `0x7f` in front is one
    // literal metadata row, as in the counter fixtures.
    const signed_words = [_]u8{ 0x24, 0x28, 0x29 };

    // A `0x7f` terminator after a penultimate byte whose sign bit is set
    // (`storage/parse/leb128.rs:63-65`) — the signed rule, and the shape the
    // overlong counter fixture carries.
    for (signed_words) |word| {
        var dec = try ValueDecoder.init(&[_]u8{ 0x7f, word }, &[_]u8{ 0xd0, 0x7f });
        try testing.expectError(error.InvalidLeb128, dec.next());
    }
    // The same two bytes with a terminator that does *not* continue `0xd0`'s
    // sign are canonical, and all three types must still read: this is the
    // half that keeps the refusal from being "refuse everything".
    for (signed_words) |word| {
        var dec = try ValueDecoder.init(&[_]u8{ 0x7f, word }, &[_]u8{ 0xd0, 0x0f });
        const got = (try dec.next()) orelse return error.TestUnexpectedResult;
        const as_int = switch (got) {
            .int => |v| v,
            .counter => |c| c.current,
            .timestamp => |t| t,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(@as(i64, 2000), as_int);
    }

    // The unsigned rule, on the one type that reads an unsigned LEB — code 3,
    // `column_range/value.rs:225`: a `0x00` terminator after a byte that
    // already reached the value (`storage/parse/leb128.rs:32-33`). `d0 00` is
    // 0 in two bytes.
    var uleb = try ValueDecoder.init(&[_]u8{ 0x7f, 0x23 }, &[_]u8{ 0xd0, 0x00 });
    try testing.expectError(error.InvalidLeb128, uleb.next());
    // ...and the canonical two-byte uleb, 16383, is still read.
    var ok_uleb = try ValueDecoder.init(&[_]u8{ 0x7f, 0x23 }, &[_]u8{ 0xff, 0x7f });
    const big = (try ok_uleb.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 16383), big.uint);
}

test "an overlong LEB is refused in a run header, a null count and a string length" {
    // The run header is a signed LEB (`rle.zig:59-69` for the run grammar):
    // `-1` in two bytes where the one byte `7f` would do.
    try testing.expectError(error.InvalidLeb128, RleSlice.Decoder.init(&[_]u8{ 0xff, 0x7f }));
    // The count after a null run is an unsigned LEB: zero in two bytes.
    try testing.expectError(error.InvalidLeb128, RleSlice.Decoder.init(&[_]u8{ 0x00, 0x80, 0x00 }));
    // A string payload's length prefix is an unsigned LEB: zero in two bytes.
    // A literal run's payload is not read by `init`, so the refusal lands on
    // the first `next`.
    var lit = try RleSlice.Decoder.init(&[_]u8{ 0x7f, 0x80, 0x00 });
    try testing.expectError(error.InvalidLeb128, lit.next());

    // The same three shapes, canonical: a repeat run of two empty strings, a
    // null run of one, and a literal run of one empty string.
    var repeat = try RleSlice.Decoder.init(&[_]u8{ 0x02, 0x00 });
    const first = (try repeat.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", first.?);
    const second = (try repeat.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", second.?);
    try testing.expectEqual(@as(??[]const u8, null), try repeat.next());

    // A null run of one: the first `next` is an absent row — the *inner* null —
    // and the second is the end of the column, the outer one. The two are the
    // pair `rle.zig` keeps distinct.
    var nulls = try RleSlice.Decoder.init(&[_]u8{ 0x00, 0x01 });
    try testing.expectEqual(@as(?[]const u8, null), (try nulls.next()).?);
    try testing.expectEqual(@as(??[]const u8, null), try nulls.next());

    var empty = try RleSlice.Decoder.init(&[_]u8{ 0x7f, 0x00 });
    const blank = (try empty.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("", blank.?);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`encodeValuePair` is where a freed payload faults, and it cannot be the
//   place that prevents it.** The pair copies every payload it is given into
//   its own `raw` column, so it owes the caller nothing afterwards — but the
//   copy *is* the read, and a payload its producer already freed faults inside
//   [`appendPayload`] on a `memcpy` of an unmapped address. Nothing at this
//   layer can tell a live slice from a dead one, and copying defensively
//   would read the dead one to find out.
//
//   Upstream does not reach the state, and the reason is a type rather than a
//   care: `TxOp` holds an `OpBuilder<'static>`
//   (`op.rs:164-170`), so a `ScalarValue<'static>` in its `pending` vector can
//   only be `Cow::Owned` (`types.rs:566-570`) and the borrow checker refuses a
//   pending operation that borrows a local. `BatchInsertion::splice_text`
//   relies on that — it collects an **owned** `Vec<ScalarValue>` before its
//   loop (`inner.rs:1481-1501`) — so every value the change encoder reads is
//   owned by the time it reads it. Zig has no lifetime parameter to copy, so the
//   port's [`ScalarValue`] and `OpBuilder` borrow whatever they are handed and
//   the copy is the producer's to make; it is made in
//   `Transaction.ownText` (transact.zig), which is what stopped the suite
//   dying here on a `diff_marks` commit.
//
// * **The test above is a pin, not a regression.** It fails if this encoder
//   ever starts aliasing the caller's buffer instead of copying it, which is
//   the other way this contract could rot: a "fix" that made the pair borrow
//   would leave the rows and the change disagreeing, silently, in the same
//   place. The regression test for the defect itself is at the producer, in
//   `transact.zig`: "a spliced character does not follow the caller's buffer
//   into the change".
