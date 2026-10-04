//! The run-length codec that backs every non-boolean column.
//!
//! A slab is a flat sequence of runs with no count, no length prefix and no
//! header of any kind. The wire format, verbatim from the upstream source
//! comment (`rust/hexane/src/rle/mod.rs:25-33`):
//!
//! ```text
//!   Repeat run : signed_leb128( count > 0 )  packed_value
//!   Literal run: signed_leb128( -n      )    v0 v1 … v(n-1)
//!   Null run   : signed_leb128( 0       )    unsigned_leb128( count )
//! ```
//!
//! The run header is a signed LEB128 whose sign selects the run kind: positive
//! is a repeat count and the value follows once, negative is a literal count
//! and that many values follow, and zero is a marker whose payload is an
//! *unsigned* LEB128 count of absent values. A repeat run is never written
//! with `count == 1`; `emit_run` writes `signed(-1)` plus the value instead,
//! i.e. a one-element literal run (`rust/hexane/src/rle/state.rs:682-693`).
//! An empty literal run is unrepresentable, because `signed(0)` is the null
//! marker.
//!
//! Values are packed by their own type: `u64` as unsigned LEB128, `i64` as
//! signed LEB128 (`lib.rs:566-595`), so a `u64` column never spends a byte
//! on a sign and an `i64` column gets one-byte values for −64..=63, and
//! `String` / `Vec<u8>` as an *unsigned LEB128 length* followed by that many
//! raw bytes (`lib.rs:694-773`). The byte payload is what makes a value's
//! width depend on the value rather than on the column, and it is the only
//! payload whose length is not implied by the run header's arithmetic:
//! a literal run of 40 one-byte strings is 40 payload *headers* plus their
//! bytes, and the byte offsets of its later values are only recoverable by
//! walking it.
//!
//! `RleOption` is the nullable form: an absent value is carried by the
//! header, never by a payload byte (`lib.rs:406-437`). **An empty `String`
//! is therefore a present value of zero length, not a null run** — the two
//! are different wire forms and `null` never round-trips to `""`.
//!
//! Canonical form — the shape `write` always produces and the shape
//! `canonical` demands — is upstream's `RleSegment::validate_after`
//! (`rust/hexane/src/rle/decoder.rs:438-497`):
//!
//!  1. a repeat run has `count >= 2`;
//!  2. a null run has `count != 0`;
//!  3. a literal run has `count != 0` (unreachable from a valid LEB128, since
//!     `signed(0)` is the null marker);
//!  4. no two adjacent literal runs;
//!  5. no two adjacent null runs;
//!  6. no two adjacent repeat runs carrying the same value;
//!  7. no two consecutive equal values inside a literal run;
//!  8. a run's first value may not equal the previous run's value, in either
//!     direction (repeat→literal and literal→repeat);
//!  9. no null run at all in a non-nullable column.
//!
//! Rules 6, 7 and 8 say *the same value*, and for a byte payload that is
//! **equal bytes, not the same slice**: two spellings of `"a"` borrowed from
//! two offsets of one slab are different slices and the same value, exactly as
//! upstream's `ColumnValueRef::eq` (`lib.rs:688-690`, `:739-741`) decides it.
//! Every equality-sensitive path here — the segmenter's run detection, these
//! three rules, and a caller asking whether two decoded rows are equal — goes
//! through `Rle(T).elementEql` rather than through Zig's `==`.
//!
//! Together those give the load iterator's own guarantee
//! (`rust/hexane/src/rle/load.rs:70-80`): adjacent runs never carry equal
//! values, by construction, and one wire run is exactly one logical run. Note
//! that a one-element *literal* is canonical — it is how a lone value is
//! written — while a one-element *repeat* is not, because rule 1 applies.
//! Given a value sequence the canonical encoding is unique, so `write` here
//! and the upstream state machine produce byte-identical slabs.
//!
//! # Packing
//!
//! Every LEB128 call above is a call on a **packing**: the run headers, the
//! null-run counts, the value payloads and the byte payload's length prefix all
//! go through one `comptime P`, which defaults to [`Leb128`] — the
//! `../leb128.zig` module under a name, not a copy of it. That is what upstream's
//! `Codec` type parameter is (`codec.rs:110-211`) and it is the whole of the
//! reason [`RleWith`] exists: the wire format is a parameter of the codec, not a
//! property of it, and a seam that only reached the payloads would leave the
//! headers, the counts and the lengths on LEB128 — which is not a second wire
//! format, it is a corrupt one.
//!
//! There is exactly one packing this port ships. The second exists so the five
//! `alt_codec` cases in `column.zig` can drive the parameter through every path
//! and catch one that misses it.
//!
//! # Import route and the shortest sequence that works
//!
//! `@import("hexane/rle.zig")`, or `zautomerge.hexane.rle` through the root
//! module. Zig 0.16.0. What a column imports from here is the three factories
//! [`Rle`], [`RleOption`] and [`RleUtf8`], plus the three value-payload
//! helpers [`payloadRead`], [`payloadAppend`] and [`payloadEql`] and the
//! [`maxSlabLen`] bound — and, for a codec that is not on the default wire,
//! [`RleWith`] and the `…With` payload pair beside it.
//!
//! ```zig
//! const Codec = rle.Rle(u64);
//! var out: std.ArrayList(u8) = .empty;
//! try Codec.append(&out, gpa, &.{ 1, 2, 2, 2 });    // canonical bytes
//! const rows = try Codec.decodeAll(out.items, gpa); // one allocation
//! defer gpa.free(rows);
//! ```
//!
//! # What it deliberately does not do
//!
//! It owns nothing and copies no byte payload out of the slab it reads. Every
//! value a byte column hands back is a window on the caller's bytes — which
//! is what makes a whole-column decode cost one allocation, and which means a
//! caller that keeps a value past the slab's lifetime has to copy it. It does
//! not expose the segmenter either: a slab's runs are a wire detail, and the
//! codec's `canonical` is the whole of the shape a caller can ask about.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");

const ParseError = err.ParseError;

/// The default integer packing: the [`../leb128.zig`](../leb128.zig) module
/// under a name, so a `Pack` parameter can be given one without copying its
/// ten decls into a struct of forwarders.
pub const Leb128 = @import("../leb128.zig");

/// The most values one slab may decode to.
///
/// A run header is three bytes whatever its count says, so the count is not
/// bounded by the slab's size: eight bytes can claim four billion values, and
/// a decoder that believed them would spend its life filling the array. This
/// is the same 2^32 the upstream tail metadata reasons about when it keeps a
/// segment's byte length in a `u32` — "a single segment must stay under 4
/// GiB, so blobs larger than that belong in `RawColumn`"
/// (`rust/hexane/src/rle/mod.rs:93-104`). A slab over it is
/// `error.TooLarge`.
pub const maxSlabLen: usize = if (@bitSizeOf(usize) < 33) std.math.maxInt(usize) else 1 << 32;

/// Whether `T` is one of this crate's value payloads: an integer, which
/// packs as LEB128, or `[]const u8`, which packs as an unsigned LEB128
/// length followed by that many raw bytes (`lib.rs:694-773`).
fn isPayload(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => true,
        // The same shape `column.zig` uses to recognise a byte payload.
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

/// Rejects any `T` that is not a payload, with one message for both
/// factories so the two cannot drift into accepting different types.
fn checkPayload(comptime T: type) void {
    if (comptime !isPayload(T) or T == [:0]const u8) @compileError(
        "an RLE value must be an integer type or []const u8",
    );
}

/// One value payload read from `bytes` at `pos`, and the bytes it occupies.
///
/// `T` is one of the two payload types [`Rle`] and [`RleOption`] take: an
/// integer type, or `[]const u8` and not `[:0]const u8`. Anything else is a
/// compile error, from the same check both factories run.
///
/// An integer payload is LEB128, signed or unsigned by `T`'s own signedness
/// (`lib.rs:566-637`). A byte payload is an unsigned LEB128 length followed
/// by exactly that many bytes (`lib.rs:747-764`): a length that does not
/// fit `usize` is `error.Overflow`, one longer than the bytes that follow is
/// `error.LengthExceedsInput`, and a malformed length is whatever the LEB128
/// reader says.
///
/// **A byte payload borrows `bytes`.** It is a window on the encoded slab,
/// not a copy, exactly as upstream's `try_unpack` returns `&'a [u8]`
/// (`lib.rs:756-764`); a caller that keeps it past the slab's own lifetime
/// has to copy it. The same is true of every value [`decodeAll`] hands out and
/// of every one `Decoder.next` returns.
pub fn payloadRead(comptime T: type, bytes: []const u8, pos: usize) ParseError!struct { value: T, len: usize } {
    return payloadReadWith(Leb128, T, bytes, pos);
}

/// [`payloadRead`] over an explicit packing. `P` is the same shape as
/// `Leb128` — `readUnsigned`, `readSigned` — so a caller that needs a wire
/// format other than the default names one here; nothing else in this file
/// changes, because every read in it already goes through this pair.
pub fn payloadReadWith(
    comptime P: type,
    comptime T: type,
    bytes: []const u8,
    pos: usize,
) ParseError!struct { value: T, len: usize } {
    checkPayload(T);
    if (comptime T == []const u8) {
        const hdr = try P.readUnsigned(bytes[pos..]);
        const n = std.math.cast(usize, hdr.value) orelse return error.Overflow;
        const at = pos + hdr.len;
        // `readUnsigned` consumed `hdr.len` bytes out of `bytes`, so `at` is
        // inside the slice and the difference cannot underflow.
        if (bytes.len - at < n) return error.LengthExceedsInput;
        return .{ .value = bytes[at..][0..n], .len = hdr.len + n };
    }
    if (@typeInfo(T).int.signedness == .signed) {
        const v = try P.readSigned(bytes[pos..]);
        const narrow = std.math.cast(T, v.value) orelse return error.Overflow;
        return .{ .value = narrow, .len = v.len };
    }
    const v = try P.readUnsigned(bytes[pos..]);
    const narrow = std.math.cast(T, v.value) orelse return error.Overflow;
    return .{ .value = narrow, .len = v.len };
}

/// Appends one value payload to `out`, which is allocated from `gpa` and
/// stays the caller's.
///
/// `T` is one of the two payload types [`Rle`] and [`RleOption`] take: an
/// integer type, or `[]const u8` and not `[:0]const u8`. Anything else is a
/// compile error, from the same check both factories run.
pub fn payloadAppend(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) std.mem.Allocator.Error!void {
    return payloadAppendWith(Leb128, gpa, out, T, value);
}

/// [`payloadAppend`] over an explicit packing, the writer half of
/// [`payloadReadWith`].
pub fn payloadAppendWith(
    comptime P: type,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime T: type,
    value: T,
) std.mem.Allocator.Error!void {
    checkPayload(T);
    if (comptime T == []const u8) {
        try P.appendUnsigned(out, gpa, @as(u64, @intCast(value.len)));
        try out.appendSlice(gpa, value);
        return;
    }
    if (@typeInfo(T).int.signedness == .signed) return P.appendSigned(out, gpa, value);
    return P.appendUnsigned(out, gpa, @as(u64, @intCast(value)));
}

/// Whether two value payloads are **the same value**.
///
/// `T` is one of the two payload types [`Rle`] and [`RleOption`] take: an
/// integer type, or `[]const u8` and not `[:0]const u8`. Anything else is a
/// compile error, from the same check both factories run.
///
/// An integer compares by its own `==`. A byte payload compares by content,
/// which is upstream's `ColumnValueRef::eq` for `Vec<u8>` (`lib.rs:739-741`)
/// and `String` (`lib.rs:688-690`) — and *not* Zig's `==` on a slice, which
/// compares the pointer and the length. Every run boundary and every
/// canonicality rule in this file goes through here rather than through `==`.
pub fn payloadEql(comptime T: type, a: T, b: T) bool {
    checkPayload(T);
    if (comptime T == []const u8) return std.mem.eql(u8, a, b);
    return a == b;
}

/// The codec over `T` for both the plain and the nullable column: `T` is the
/// payload whose bytes one value occupies, `Nullable` says whether a null run
/// is part of the format, and `Utf8` says whether a byte payload has to be
/// valid UTF-8. For the plain form `Element == T`; for the nullable form
/// `Element == ?T`.
fn RleGeneric(comptime T: type, comptime Nullable: bool, comptime Utf8: bool, comptime P: type) type {
    return struct {
        /// One decoded column entry: `T` for the plain form, `?T` for the
        /// nullable one.
        pub const Element = if (Nullable) ?T else T;

        /// The number of bytes `write` will emit for `values`.
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

        /// Appends the encoding of `values` to `list`. The bytes are built
        /// straight into the list's spare capacity, so nothing is copied twice.
        pub fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const Element) !void {
            const n = encodedSize(values);
            try list.ensureUnusedCapacity(gpa, n);
            const dst = list.addManyAsSliceAssumeCapacity(n);
            var seg = Segmenter{ .values = values };
            var pos: usize = 0;
            while (seg.next()) |s| pos += s.writeTo(dst[pos..], values);
            std.debug.assert(pos == n);
        }

        /// Decodes every value in a slab into a freshly allocated slice. The
        /// value count is walked first, so a run that expands a handful of
        /// bytes into millions of values still costs exactly one allocation.
        ///
        /// A null run in a non-nullable column is `error.UnexpectedNull`, a
        /// count that does not fit a `usize` is `error.Overflow`, and a run
        /// that claims more values than the bytes hold is
        /// `error.LengthExceedsInput`, and a slab claiming more values than
        /// `maxSlabLen` is `error.TooLarge`. Malformed bytes are whatever the
        /// LEB128 reader says they are (`error.UnexpectedEnd`,
        /// `error.InvalidLeb128`).
        ///
        /// **A byte payload borrows `bytes`.** For `Rle([]const u8)`,
        /// `RleOption([]const u8)` and both [`RleUtf8`] forms the elements of
        /// the returned slice are windows on `bytes` and not copies: this
        /// allocates the header slice and nothing else, so a caller that frees
        /// or overwrites `bytes` and keeps the rows reads freed memory. An
        /// integer column's rows are values and carry no such obligation.
        pub fn decodeAll(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]Element {
            const n = try countValues(bytes);
            const out = try gpa.alloc(Element, n);
            errdefer gpa.free(out);
            var dec = try Decoder.init(bytes);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                // `countValues` walked the same bytes under the same rules, so
                // the cursor has exactly `n` values left. The `orelse` keeps a
                // bug in that reasoning an error rather than a panic.
                out[i] = (try dec.next()) orelse return error.InvalidValue;
            }
            return out;
        }

        /// The number of values a slab holds, counted run by run without
        /// materialising one.
        ///
        /// This is the length [`decodeAll`] allocates from, and it is the
        /// right answer for a caller that only needs the row count: a repeat
        /// or null run is charged its declared length instead of being
        /// stepped through, so a slab claiming `maxSlabLen` values costs one
        /// pass over its runs rather than `maxSlabLen` calls. A slab that is
        /// not a slab at all raises whatever the walk hits first.
        pub fn countEntries(bytes: []const u8) ParseError!usize {
            return countValues(bytes);
        }

        /// Checks that `bytes` is a well-formed *and* canonical slab for this
        /// column type. Structural non-canonicality is `error.InvalidValue`, a
        /// null run in a non-nullable column is `error.UnexpectedNull`, and a
        /// malformed slab raises whatever the walk hits first. The empty slab
        /// is canonical: it is the encoding of no values at all.
        pub fn canonical(bytes: []const u8) ParseError!void {
            var pos: usize = 0;
            // The last value-bearing run, which rule 8 compares against.
            var prev: ?PrevRun = null;
            // The previous value inside the literal run being walked, for
            // rule 7. Cleared whenever a run ends, so it is only set while a
            // literal run is in progress.
            var prev_lit: ?Element = null;
            while (pos < bytes.len) {
                const hdr = try readRunHeader(bytes, pos);
                if (hdr.is_repeat) {
                    if (hdr.count < 2) return error.InvalidValue; // rule 1
                    const cv = try readValue(bytes, hdr.payload_at);
                    const v: Element = cv.value;
                    // Rules 6 and 8, by value and not by slice identity:
                    // two payloads borrowed from the slab at different
                    // offsets are still the same value.
                    if (prev) |p| switch (p) {
                        .run => |q| {
                            if (elementEql(q, v)) return error.InvalidValue;
                        },
                        .lit => |q| {
                            if (elementEql(q, v)) return error.InvalidValue;
                        },
                        .null_run => {},
                    };
                    pos = hdr.payload_at + cv.len;
                    prev = .{ .run = v };
                    prev_lit = null;
                } else if (hdr.is_null) {
                    if (!Nullable) return error.UnexpectedNull; // rule 9
                    const nc = try readNullCount(bytes, hdr.payload_at);
                    if (nc.count == 0) return error.InvalidValue; // rule 2
                    if (prev) |p| {
                        if (std.meta.activeTag(p) == .null_run) return error.InvalidValue; // rule 5
                    }
                    pos = hdr.payload_at + nc.header_len;
                    prev = .null_run;
                    prev_lit = null;
                } else {
                    if (hdr.count == 0) return error.InvalidValue; // rule 3
                    if (prev) |p| {
                        if (std.meta.activeTag(p) == .lit) return error.InvalidValue; // rule 4
                    }
                    var p = hdr.payload_at;
                    var k: u64 = 0;
                    while (k < hdr.count) : (k += 1) {
                        const cv = try readValue(bytes, p);
                        const v: Element = cv.value;
                        if (prev_lit) |pl| {
                            if (elementEql(pl, v)) return error.InvalidValue; // rule 7
                        } else if (prev) |q| switch (q) {
                            // Rule 8, at the boundary of the literal run.
                            .run => |x| {
                                if (elementEql(x, v)) return error.InvalidValue;
                            },
                            .lit => |x| {
                                if (elementEql(x, v)) return error.InvalidValue;
                            },
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

        /// A cursor over a slab that yields values one at a time. A repeat or
        /// null run is read once and then served from memory; a literal run
        /// re-reads the wire for every value, which is what makes the format
        /// forward-decodable.
        pub const Decoder = struct {
            /// The slab being walked.
            ///
            /// **The decoder borrows it.** The `bytes` given to [`init`] must
            /// stay alive and unmodified for as long as the decoder is used,
            /// and the slab's owner must outlive the decoder. For
            /// `Rle([]const u8)`, `RleOption([]const u8)` and both
            /// [`RleUtf8`] forms the values `next` returns are windows into
            /// this slab rather than copies — [`payloadRead`] is where that
            /// happens, and it is upstream's `try_unpack` borrowing `&'a
            /// [u8]` (`lib.rs:756-764`). A caller that keeps one past the
            /// slab's lifetime has to copy it.
            data: []const u8,
            /// Byte offset of the next run header, or of the next literal value
            /// while a literal run is being served.
            pos: usize,
            /// Values still owed by the run in `run`.
            remaining: u64,
            /// The run being served, and the shape of the bytes `pos` reads.
            /// Its variants are private; `next` is the only way to advance it.
            run: Run,

            const Run = union(enum) {
                /// Between runs, or the slab is exhausted.
                idle,
                /// Serve `elem` `remaining` times.
                repeat: Element,
                /// Read a value from `pos` for each of the next `remaining`.
                literal,
                /// Serve an absent value `remaining` times.
                null_run,
            };

            /// A decoder at the start of `bytes`. The opening run header is
            /// read and checked now, so bytes that are not an RLE slab at all
            /// are rejected at the boundary rather than on the first `next`.
            /// Anything malformed further in surfaces from `next`.
            pub fn init(bytes: []const u8) ParseError!Decoder {
                var dec: Decoder = .{
                    .data = bytes,
                    .pos = 0,
                    .remaining = 0,
                    .run = .idle,
                };
                if (bytes.len == 0) return dec;
                _ = try dec.enterRun();
                return dec;
            }

            /// The next value, or null once the slab is exhausted.
            ///
            /// For `RleOption` the payload is `?T`, so the return is `??T`:
            /// an absent column value stays distinct from the end of the slab.
            /// A run that yields nothing — a null run of count zero, or an
            /// empty slab — is stepped over rather than reported.
            pub fn next(self: *Decoder) ParseError!?Element {
                // `enterRun` reports a run of zero values by leaving
                // `remaining` at zero, so it is the loop, not a single test,
                // that steps over it.
                while (self.remaining == 0) {
                    if (!try self.enterRun()) return null;
                }
                self.remaining -= 1;
                switch (self.run) {
                    .repeat => |v| return v,
                    .null_run => return nullElement(),
                    .literal => {
                        const cv = try readValue(self.data, self.pos);
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
            fn enterRun(self: *Decoder) ParseError!bool {
                if (self.pos >= self.data.len) {
                    self.run = .idle;
                    self.remaining = 0;
                    return false;
                }
                const hdr = try readRunHeader(self.data, self.pos);
                if (hdr.is_repeat) {
                    // A count the slab could never back is refused before the
                    // value is even read.
                    if (hdr.count > maxSlabLen) return error.TooLarge;
                    const cv = try readValue(self.data, hdr.payload_at);
                    self.pos = hdr.payload_at + cv.len;
                    self.remaining = hdr.count;
                    self.run = .{ .repeat = cv.value };
                } else if (hdr.is_null) {
                    if (!Nullable) return error.UnexpectedNull;
                    const nc = try readNullCount(self.data, hdr.payload_at);
                    if (nc.count > maxSlabLen) return error.TooLarge;
                    self.pos = hdr.payload_at + nc.header_len;
                    self.remaining = nc.count;
                    self.run = .null_run;
                } else {
                    // `readRunHeader` already proved the values are present,
                    // and a literal run cannot outrun the slab.
                    self.pos = hdr.payload_at;
                    self.remaining = hdr.count;
                    self.run = .literal;
                }
                return true;
            }
        };

        // ── Element helpers ────────────────────────────────────────────────

        /// The element a null run yields. Unreachable for a non-nullable
        /// column, where `enterRun` and `canonical` reject the run first.
        fn nullElement() ParseError!?Element {
            if (Nullable) {
                // A typed binding, so the `null` lands on the column value and
                // not on the end-of-slab optional wrapped around it.
                const absent: Element = null;
                return absent;
            }
            return error.UnexpectedNull;
        }

        /// Whether an element is an absent value. Always false for a
        /// non-nullable column, which has no null to test for.
        fn isNull(value: Element) bool {
            if (Nullable) return value == null;
            return false;
        }

        /// Whether two elements are **the same column value**.
        ///
        /// Zig's `==` on a slice compares the pointer and the length, so a
        /// byte payload borrowed twice from the same slab at different
        /// offsets would compare unequal and every run boundary would be
        /// missed. Every equality-sensitive path in this file — the
        /// segmenter's run detection and rules 6, 7 and 8 of `canonical` —
        /// goes through here, and so does anything that has to answer
        /// "are these two values the same" about decoded rows.
        pub fn elementEql(a: Element, b: Element) bool {
            if (comptime Nullable) {
                // An absent value is its own value: it equals another absent
                // one and nothing else, so it can never be content-equal to
                // a present empty payload.
                const av = a orelse return b == null;
                const bv = b orelse return false;
                return payloadEql(T, av, bv);
            }
            return payloadEql(T, a, b);
        }

        /// The `T` behind a value payload. The segmenter sends every absent
        /// value to a null run, so an absent value never reaches a repeat or
        /// literal payload; the panic is a bug in this file, not in the input.
        fn payload(value: ?T) T {
            return value orelse std.debug.panic(
                "rle: an absent value reached a value payload",
                .{},
            );
        }

        // ── The value payload ──────────────────────────────────────────────
        //
        // `u64` packs as unsigned LEB128 and `i64` as signed LEB128, matching
        // the upstream `RleValue for u64` / `for i64` impls
        // (`rust/hexane/src/lib.rs:566-595`). `String` and `Vec<u8>` pack as
        // an unsigned LEB128 length followed by that many raw bytes
        // (`lib.rs:725-729`, `:765-769`), which is the one payload whose
        // length is not the LEB128 width of the value itself.

        /// The number of bytes one value of type `T` occupies.
        fn valueSize(value: T) usize {
            if (comptime T == []const u8) return P.unsignedSize(@as(u64, @intCast(value.len))) + value.len;
            if (@typeInfo(T).int.signedness == .signed) {
                return P.signedSize(@as(i64, value));
            }
            return P.unsignedSize(@as(u64, value));
        }

        /// Writes one value payload, returning the bytes written.
        fn writeValue(out: []u8, value: T) usize {
            if (comptime T == []const u8) {
                const n = P.writeUnsigned(out, @as(u64, @intCast(value.len)));
                @memcpy(out[n..][0..value.len], value);
                return n + value.len;
            }
            if (@typeInfo(T).int.signedness == .signed) {
                return P.writeSigned(out, @as(i64, value));
            }
            return P.writeUnsigned(out, @as(u64, value));
        }

        /// Reads one value payload. A payload byte can only ever spell a
        /// present value: an absent entry is carried by the run header, never
        /// by a payload.
        ///
        /// A byte payload is borrowed from `bytes`, and is validated as UTF-8
        /// here when the codec asks for it — upstream's `RleValue for String`
        /// validates in `try_unpack` (`lib.rs:700-709`) and skips the check in
        /// `unpack` only because the column was validated when it loaded
        /// (`lib.rs:710-723`). This port has no unchecked `unpack`: every
        /// reader is a `try_` reader, so `RleUtf8`'s check runs on every read,
        /// and `Rle([]const u8)` keeps `Vec<u8>`'s rule of accepting any byte
        /// (`lib.rs:756-764`).
        fn readValue(bytes: []const u8, pos: usize) ParseError!struct { value: T, len: usize } {
            if (comptime T == []const u8) {
                const pv = try payloadReadWith(P, T, bytes, pos);
                if (comptime Utf8) {
                    if (!std.unicode.utf8ValidateSlice(pv.value)) return error.InvalidUtf8;
                }
                return .{ .value = pv.value, .len = pv.len };
            }
            if (@typeInfo(T).int.signedness == .signed) {
                const v = try P.readSigned(bytes[pos..]);
                const narrow = std.math.cast(T, v.value) orelse return error.Overflow;
                return .{ .value = narrow, .len = v.len };
            }
            const v = try P.readUnsigned(bytes[pos..]);
            const narrow = std.math.cast(T, v.value) orelse return error.Overflow;
            return .{ .value = narrow, .len = v.len };
        }

        // ── The wire walk, shared by every reader ──────────────────────────

        /// One run header, decoded, and where its payload starts.
        const RunHeader = struct {
            /// A repeat count or a literal count. Unused for a null run: that
            /// count is the unsigned varint in the payload, and reading it is
            /// left to the caller.
            count: u64,
            is_repeat: bool,
            is_null: bool,
            /// Byte offset of the payload: the single value of a repeat run,
            /// the first value of a literal run, or the unsigned count of a
            /// null run.
            payload_at: usize,
        };

        /// Reads the run header at `pos`.
        fn readRunHeader(bytes: []const u8, pos: usize) ParseError!RunHeader {
            const h = try P.readSigned(bytes[pos..]);
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
                // Every value costs at least one byte, so a count larger than
                // the rest of the slab cannot be satisfied. Rejecting it here
                // bounds every walk over a literal run, and answers "a run that
                // claims more values than the bytes hold" with a dedicated
                // error rather than a truncation found part-way through.
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
            const c = try P.readUnsigned(bytes[pos..]);
            return .{ .count = c.value, .header_len = c.len };
        }

        /// `-value` for the negative header of a literal run. Computed with a
        /// wrapping negate because the signed reader can return
        /// `minInt(i64)`, and a literal count of 2^63 is a claim the wire
        /// allows even though no slab can satisfy it.
        fn literalCount(value: i64) u64 {
            std.debug.assert(value < 0);
            return -%@as(u64, @bitCast(value));
        }

        /// The value count of a whole slab, walked run by run and never
        /// materialising a value. A run count that is not representable, an
        /// accumulation that overflows, and a total past `maxSlabLen` are all
        /// caught here, before anything is allocated.
        fn countValues(bytes: []const u8) ParseError!usize {
            var pos: usize = 0;
            var total: usize = 0;
            while (pos < bytes.len) {
                const hdr = try readRunHeader(bytes, pos);
                var run: u64 = 0;
                if (hdr.is_repeat) {
                    const cv = try readValue(bytes, hdr.payload_at);
                    pos = hdr.payload_at + cv.len;
                    run = hdr.count;
                } else if (hdr.is_null) {
                    if (!Nullable) return error.UnexpectedNull;
                    const nc = try readNullCount(bytes, hdr.payload_at);
                    pos = hdr.payload_at + nc.header_len;
                    run = nc.count;
                } else {
                    var p = hdr.payload_at;
                    var k: u64 = 0;
                    while (k < hdr.count) : (k += 1) {
                        const cv = try readValue(bytes, p);
                        p += cv.len;
                    }
                    pos = p;
                    run = hdr.count;
                }
                const n = std.math.cast(usize, run) orelse return error.Overflow;
                total = std.math.add(usize, total, n) catch return error.Overflow;
                if (total > maxSlabLen) return error.TooLarge;
            }
            return total;
        }

        // ── The encoder side ───────────────────────────────────────────────

        /// One run of a value sequence on its way to the wire.
        const Segment = union(enum) {
            repeat: struct { count: usize, value: ?T },
            literal: struct { start: usize, len: usize },
            null: usize,

            /// The number of bytes this segment occupies.
            fn size(s: Segment, values: []const Element) usize {
                return switch (s) {
                    .repeat => |r| headerSize(r.count) + valueSize(payload(r.value)),
                    .literal => |l| literalSize(l.start, l.len, values),
                    .null => |count| headerSize(0) + P.unsignedSize(@as(u64, @intCast(count))),
                };
            }

            /// Writes this segment into `out`, returning the bytes written.
            fn writeTo(s: Segment, out: []u8, values: []const Element) usize {
                return switch (s) {
                    .repeat => |r| blk: {
                        var n = P.writeSigned(out, @as(i64, @intCast(r.count)));
                        n += writeValue(out[n..], payload(r.value));
                        break :blk n;
                    },
                    .literal => |l| blk: {
                        var n = P.writeSigned(out, literalHeader(l.len));
                        for (values[l.start..][0..l.len]) |v| {
                            n += writeValue(out[n..], payload(v));
                        }
                        break :blk n;
                    },
                    .null => |count| blk: {
                        var n = P.writeSigned(out, 0);
                        n += P.writeUnsigned(out[n..], @as(u64, @intCast(count)));
                        break :blk n;
                    },
                };
            }
        };

        /// Splits `values` into the runs `write` emits. The segmentation is
        /// forced: a value repeated twice or more is a repeat run, absent
        /// values are a null run, and what is left over is one literal run —
        /// so no run can be merged with its neighbour and no literal can hold
        /// a value a run could have held.
        const Segmenter = struct {
            values: []const Element,
            pos: usize = 0,
            lit_start: usize = 0,
            lit_len: usize = 0,
            /// A literal run is emitted before the run that ended it, so at
            /// most one segment is ever held back.
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
                    while (j < self.values.len and elementEql(self.values[j], v)) j += 1;
                    const run = j - self.pos;
                    if (isNull(v)) {
                        // The literal run in progress belongs before the null
                        // run, so hand one back and hold the other over.
                        const lit = self.flushLiteral();
                        self.pending = .{ .null = run };
                        self.pos = j;
                        if (lit) |l| return l;
                        continue;
                    }
                    if (run >= 2) {
                        const value: ?T = v;
                        const lit = self.flushLiteral();
                        self.pending = .{ .repeat = .{ .count = run, .value = value } };
                        self.pos = j;
                        if (lit) |l| return l;
                        continue;
                    }
                    // A value that appears once joins the literal run in
                    // progress. Consecutive maximal runs carry different
                    // values by construction, so the literal can hold no two
                    // equal values, and its first value cannot equal the
                    // previous run's.
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

        /// The number of bytes a literal run of `len` values from `start`
        /// takes: one signed header plus one payload per value.
        fn literalSize(start: usize, len: usize, values: []const Element) usize {
            var n = P.signedSize(literalHeader(len));
            for (values[start..][0..len]) |v| n += valueSize(payload(v));
            return n;
        }

        /// `signed_leb128( count )`, the header of a repeat run.
        fn headerSize(count: usize) usize {
            std.debug.assert(count <= std.math.maxInt(i64));
            return P.signedSize(@as(i64, @intCast(count)));
        }

        /// The last value-bearing run of a slab, which the boundary check in
        /// `canonical` compares the next run against.
        const PrevRun = union(enum) {
            run: Element,
            lit: Element,
            null_run,
        };
    };
}

/// The run-length codec for a non-nullable column. `T` is an integer — `u64`
/// or `i64` in this port, unsigned types packing as unsigned LEB128 and
/// signed ones as signed LEB128 — or `[]const u8`, the length-prefixed byte
/// payload of upstream's `Vec<u8>` (`lib.rs:732-770`). A null run on the
/// wire is `error.UnexpectedNull` rather than a value.
///
/// `Rle([]const u8)` accepts any byte, because `Vec<u8>` does. The codec
/// that refuses a byte string that is not UTF-8 is [`RleUtf8`].
pub fn Rle(comptime T: type) type {
    return RleWith(Leb128, T, false, false);
}

/// The run-length codec over `T` under an explicit packing. This is the one
/// entry point [`Rle`], [`RleOption`] and [`RleUtf8`] all forward to, and the
/// reason it takes `Nullable` and `Utf8` rather than having a `With` variant of
/// its own per factory: one name does the work of three, and a caller in
/// another module of this crate that needs a wire format other than LEB128
/// names one here instead of the port growing a second codec family.
pub fn RleWith(comptime P: type, comptime T: type, comptime Nullable: bool, comptime Utf8: bool) type {
    checkPayload(T);
    return RleGeneric(T, Nullable, Utf8, P);
}

/// The run-length codec for a nullable column over `T`. An absent value is
/// carried by a null run in the header, so a literal or repeat payload always
/// holds a present value and `Element` is `?T`.
///
/// **An absent value is not an empty one.** `?[]const u8`'s `null` encodes as
/// the null run and its `""` as a zero-length payload, and the two decode
/// back to the two distinct values they came from.
pub fn RleOption(comptime T: type) type {
    return RleWith(Leb128, T, true, false);
}

/// The run-length codec over `String`, in both the plain and the nullable
/// form: upstream's `RleValue for String` (`lib.rs:696-730`), which is
/// `Vec<u8>`'s payload plus a UTF-8 check.
///
/// The value type is the byte slice, not an owning string — one `[]const u8`
/// per row, borrowed from whatever storage the slab lives in — and
/// `Nullable` picks the same two forms [`Rle`] and [`RleOption`] have.
///
/// **Where the check runs.** Upstream splits it: `try_unpack` validates and
/// `unpack` does not, the second relying on the column having been validated
/// at load (`lib.rs:700-723`). This port has one reader and no unchecked
/// path, so the check is in the reader itself — a byte string that is not
/// UTF-8 is `error.InvalidUtf8` from `decodeAll`, from `Decoder.next` and
/// from `canonical`, and a slab carrying one is never counted, never sized
/// and never handed out a row for.
pub fn RleUtf8(comptime Nullable: bool) type {
    return RleWith(Leb128, []const u8, Nullable, true);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Encodes `values` with `append` and returns the bytes, owned by the caller.
fn expectWritten(comptime Codec: type, comptime T: type, values: []const T) ![]u8 {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try Codec.append(&list, gpa, values);
    return list.toOwnedSlice(gpa);
}

/// Encodes `values` and checks the result against `want` byte for byte, by
/// both sizing entry points, and against `canonical`.
fn expectBytes(
    comptime Codec: type,
    comptime T: type,
    values: []const T,
    want: []const u8,
) !void {
    const gpa = testing.allocator;
    const appended = try expectWritten(Codec, T, values);
    defer gpa.free(appended);
    try testing.expectEqualSlices(u8, want, appended);

    // `encodedSize` must be exactly what `write` fills, and `write` must
    // touch nothing past it.
    const padded = try gpa.alloc(u8, want.len + 8);
    defer gpa.free(padded);
    @memset(padded, 0xaa);
    std.debug.assert(Codec.encodedSize(values) == want.len);
    Codec.write(padded, values);
    try testing.expectEqualSlices(u8, want, padded[0..want.len]);
    for (padded[want.len..]) |b| try testing.expectEqual(@as(u8, 0xaa), b);
    try Codec.canonical(padded[0..want.len]);
}

/// Encodes `values` and checks that the result is canonical.
fn expectCanonical(comptime Codec: type, comptime T: type, values: []const T) !void {
    const gpa = testing.allocator;
    const bytes = try expectWritten(Codec, T, values);
    defer gpa.free(bytes);
    try Codec.canonical(bytes);
}

/// Encodes `values`, decodes them back through both entry points, and holds
/// the three ways of using the codec against each other. Also demands that the
/// output is canonical, which is what ties the encoder to `canonical`.
fn checkRoundTrip(comptime Codec: type, comptime T: type, values: []const T) !void {
    const gpa = testing.allocator;
    const size = Codec.encodedSize(values);
    const buf = try gpa.alloc(u8, size);
    defer gpa.free(buf);
    Codec.write(buf, values);
    try testing.expectEqual(size, buf.len);
    try Codec.canonical(buf);

    const back = try Codec.decodeAll(buf, gpa);
    defer gpa.free(back);
    try expectEqualElements(Codec, values, back);

    var dec = try Codec.Decoder.init(buf);
    for (values) |want| {
        const got = (try dec.next()).?;
        try testing.expect(Codec.elementEql(want, got));
    }
    try testing.expect((try dec.next()) == null);

    const appended = try expectWritten(Codec, T, values);
    defer gpa.free(appended);
    try testing.expectEqualSlices(u8, buf, appended);
}

/// Two value sequences hold the same values.
///
/// **`expectEqualSlices` cannot answer this for a byte payload.** Its
/// element comparison is `==`, and `==` on a slice is the pointer and the
/// length — so two spellings of `"a"` borrowed from two places in one slab
/// would be reported unequal. The codec's own `elementEql` is the same
/// answer the run boundaries are decided by, which is what makes a
/// round trip test and a canonicality test agree about "the same value".
fn expectEqualElements(comptime Codec: type, want: []const Codec.Element, got: []const Codec.Element) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expect(Codec.elementEql(a, b));
}

test "u64 values round trip through write, decodeAll and Decoder" {
    const Codec = Rle(u64);
    const cases = [_][]const u64{
        &.{},
        &.{42},
        &.{ 0, 0 },
        &.{ 1, 2 },
        &.{ 7, 7, 7, 7, 7 },
        &.{ 1, 2, 3, 4 },
        &.{ 1, 2, 3, 3, 3 },
        &.{ 5, 5, 5, 1, 2, 3 },
        &.{ 1, 1, 2, 3, 3 },
        &.{ 1, 2, 2 },
        &.{ 2, 2, 1 },
        &.{ 1, 2, 3, 3, 3, 4, 5, 5, 6, 7, 7, 7, 7, 8 },
        &.{ 0, 0, 0, 1, 1, 0, 0 },
        &.{ std.math.maxInt(u64), 0, std.math.maxInt(u64) },
    };
    for (cases) |c| try checkRoundTrip(Codec, u64, c);

    // Every value a singleton run, so this is one literal run over the whole
    // slab.
    var alt: [200]u64 = undefined;
    for (&alt, 0..) |*v, i| v.* = if (i % 2 == 0) 1 else 2;
    try checkRoundTrip(Codec, u64, &alt);

    // A long literal run crosses the point where the header needs a second
    // byte: 64 values encode as `signed(-64)`, 65 do not.
    var wide: [65]u64 = undefined;
    for (&wide, 0..) |*v, i| v.* = @intCast(i);
    try checkRoundTrip(Codec, u64, &wide);
}

test "i64 values round trip through write, decodeAll and Decoder" {
    const Codec = Rle(i64);
    const cases = [_][]const i64{
        &.{},
        &.{-1},
        &.{ 0, 0, 0 },
        &.{ std.math.minInt(i64), 0, std.math.maxInt(i64) },
        &.{std.math.minInt(i64)},
        &.{ std.math.minInt(i64), std.math.minInt(i64) },
        &.{ -1, -1, -2 },
        &.{ 1 << 40, -(1 << 40), 0 },
        &.{ 63, 64, -64, -65 },
        &.{ 0, 0, 0, 0 },
    };
    for (cases) |c| try checkRoundTrip(Codec, i64, c);
}

test "encodedSize is exactly the bytes write produces" {
    const gpa = testing.allocator;
    // A value that needs more than one payload byte, a run that needs more
    // than one header byte, and a mix of the two.
    const us = [_][]const u64{
        &.{},
        &.{0},
        &.{ 0, 0 },
        &.{300},
        &.{std.math.maxInt(u64)},
        &.{ 1, 2, 3 },
        &([_]u64{0} ** 5),
        &([_]u64{0} ** 200),
        &.{ 1, 2, 3, 3, 3 },
        &.{ 1, 2, 3, 3, 3, 4, 5, 5, 6, 7, 7, 7, 7, 8 },
    };
    for (us) |c| {
        const size = Rle(u64).encodedSize(c);
        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);
        Rle(u64).write(buf, c);
        // `write` fills exactly `encodedSize` bytes and no more.
        const appended = try expectWritten(Rle(u64), u64, c);
        defer gpa.free(appended);
        try testing.expectEqualSlices(u8, buf, appended);
        try Rle(u64).canonical(buf);
    }
    const os = [_][]const ?u64{ &.{null}, &.{ null, null }, &.{ 1, null, null, 2 } };
    for (os) |c| {
        const size = RleOption(u64).encodedSize(c);
        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);
        RleOption(u64).write(buf, c);
        try RleOption(u64).canonical(buf);
    }
}

test "identical values encode as one repeat run" {
    const Codec = Rle(u64);
    // signed(5) ++ unsigned(7): a header and a value, nothing else.
    try expectBytes(Codec, u64, &([_]u64{7} ** 5), &.{ 0x05, 0x07 });
    // Two equal values are the smallest run that may carry a repeat header.
    try expectBytes(Codec, u64, &.{ 9, 9 }, &.{ 0x02, 0x09 });
    // A long run: the count needs two header bytes, the value one.
    try expectBytes(Codec, u64, &([_]u64{0} ** 200), &.{ 0xc8, 0x01, 0x00 });
    // One value alone is a one-element literal, never `signed(1)`.
    try expectBytes(Codec, u64, &.{42}, &.{ 0x7f, 0x2a });

    // A run of one and a run of two side by side are two runs, not three.
    try expectBytes(Codec, u64, &.{ 1, 1, 2, 2, 3 }, &.{ 0x02, 0x01, 0x02, 0x02, 0x7f, 0x03 });

    // The option codec is the same, and an absent value never becomes a run.
    try expectBytes(RleOption(u64), ?u64, &([_]?u64{9} ** 5), &.{ 0x05, 0x09 });

    // A run far larger than the slab that carries it: two header bytes and one
    // value byte in, a thousand values out, in a single allocation. The
    // counting pass in `decodeAll` is what makes that possible.
    const gpa = testing.allocator;
    const big = [_]u8{ 0xe8, 0x07, 0x07 }; // signed(1000), value 7
    try Codec.canonical(&big);
    const many = try Codec.decodeAll(&big, gpa);
    defer gpa.free(many);
    try testing.expectEqual(@as(usize, 1000), many.len);
    for (many) |v| try testing.expectEqual(@as(u64, 7), v);
}

test "a null run round trips" {
    const gpa = testing.allocator;
    const Codec = RleOption(u64);

    // literal(1) ++ null(3) ++ literal(1)
    const bytes = [_]u8{ 0x7f, 0x01, 0x00, 0x03, 0x7f, 0x02 };
    try expectBytes(Codec, ?u64, &.{ 1, null, null, null, 2 }, &bytes);

    const back = try Codec.decodeAll(&bytes, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(?u64, &.{ 1, null, null, null, 2 }, back);

    // The same bytes through the cursor: an absent value is not the end of the
    // slab, which is why the cursor's payload is `??u64`.
    var dec = try Codec.Decoder.init(&bytes);
    for (&[_]?u64{ 1, null, null, null, 2 }) |want| {
        try testing.expectEqual(want, (try dec.next()).?);
    }
    try testing.expect((try dec.next()) == null);

    // Adjacent absent values merge into one null run; an absent value never
    // merges with a present one.
    try expectBytes(Codec, ?u64, &([_]?u64{null} ** 5), &.{ 0x00, 0x05 });
    try expectBytes(Codec, ?u64, &.{ 5, null, null, 6 }, &.{ 0x7f, 0x05, 0x00, 0x02, 0x7f, 0x06 });
    // A present run, then a null run, then a present run.
    try expectBytes(
        Codec,
        ?u64,
        &.{ 7, 7, 7, null, null, 1, 2, 2, 2 },
        &.{ 0x03, 0x07, 0x00, 0x02, 0x7f, 0x01, 0x03, 0x02 },
    );
    // Signed payloads under a null run.
    try expectBytes(
        RleOption(i64),
        ?i64,
        &.{ -1, -1, 5, null },
        &.{ 0x02, 0x7f, 0x7f, 0x05, 0x00, 0x01 },
    );
}

test "the wire format is what the upstream comment says" {
    const U = Rle(u64);
    const I = Rle(i64);
    const O = RleOption(u64);

    // Repeat run : signed_leb128( count > 0 )  packed_value
    try expectBytes(U, u64, &.{ 5, 5, 5 }, &.{ 0x03, 0x05 });
    // Literal run: signed_leb128( -n )  v0 v1 … v(n-1)
    try expectBytes(U, u64, &.{ 1, 2, 3, 4 }, &.{ 0x7c, 0x01, 0x02, 0x03, 0x04 });
    // Null run   : signed_leb128( 0 )  unsigned_leb128( count )
    try expectBytes(O, ?u64, &([_]?u64{null} ** 3), &.{ 0x00, 0x03 });
    // An i64 payload is signed LEB128, so -1 is one byte and the most negative
    // value is ten.
    try expectBytes(I, i64, &.{ -1, 0 }, &.{ 0x7e, 0x7f, 0x00 });
    try expectBytes(I, i64, &.{std.math.minInt(i64)}, &.{ 0x7f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f });
    // A u64 payload is unsigned LEB128: 127 is one byte there and two under
    // the signed codec, which is why the same number is not the same slab.
    try expectBytes(U, u64, &.{127}, &.{ 0x7f, 0x7f });
    try expectBytes(
        U,
        u64,
        &.{std.math.maxInt(u64)},
        &.{ 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
    );
}

test "a literal run ends where a run begins" {
    const U = Rle(u64);

    // A value that appears once, between two runs, is a literal run of its
    // own — the shorter `literal(2, 3)` that would swallow the trailing run is
    // canonical too, and upstream's state machine does not write it. This is
    // the one place the format leaves a choice, so it is pinned here: the
    // literal is flushed before every run (`RleState::append_n` emits
    // `emit_lit` and then starts the run, `rust/hexane/src/rle/state.rs:427-455`).
    try expectBytes(
        U,
        u64,
        &.{ 1, 1, 2, 3, 3 },
        &.{ 0x02, 0x01, 0x7f, 0x02, 0x02, 0x03 },
    );
    // The same choice, repeated: literal, run, literal, run, literal, run,
    // literal. This is upstream's `roundtrip_complex` case.
    try expectBytes(
        U,
        u64,
        &.{ 1, 2, 3, 3, 3, 4, 5, 5, 6, 7, 7, 7, 7, 8 },
        &.{ 0x7e, 0x01, 0x02, 0x03, 0x03, 0x7f, 0x04, 0x02, 0x05, 0x7f, 0x06, 0x04, 0x07, 0x7f, 0x08 },
    );
    // A literal that only ever grows keeps the one header it was given.
    try expectBytes(
        U,
        u64,
        &.{ 4, 5, 6, 7, 8, 9 },
        &.{ 0x7a, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 },
    );
}

test "a truncated slab is rejected" {
    const gpa = testing.allocator;
    const U = Rle(u64);
    const O = RleOption(u64);

    // A run header whose continuation bit is set and which never ends.
    try testing.expectError(error.UnexpectedEnd, U.decodeAll(&[_]u8{0x80}, gpa));
    // A repeat run with a header but no value.
    try testing.expectError(error.UnexpectedEnd, U.decodeAll(&[_]u8{0x02}, gpa));
    // A literal run whose one value is a truncated LEB128.
    try testing.expectError(error.UnexpectedEnd, U.decodeAll(&[_]u8{ 0x7f, 0x80 }, gpa));
    // A null run with a header but no count.
    try testing.expectError(error.UnexpectedEnd, O.decodeAll(&[_]u8{0x00}, gpa));
    try testing.expectError(error.UnexpectedEnd, O.Decoder.init(&[_]u8{0x00}));

    // The cursor reports truncation part-way through a run, having served the
    // values that are there.
    const slab = [_]u8{ 0x7e, 0x01, 0x02, 0x80 };
    var dec = try U.Decoder.init(&slab);
    try testing.expectEqual(@as(?u64, 1), try dec.next());
    try testing.expectEqual(@as(?u64, 2), try dec.next());
    try testing.expectError(error.UnexpectedEnd, dec.next());
}

test "a run claiming more values than the bytes hold is rejected" {
    const gpa = testing.allocator;
    const U = Rle(u64);

    // signed(-3) promises three values; one follows.
    try testing.expectError(error.LengthExceedsInput, U.decodeAll(&[_]u8{ 0x7d, 0x01 }, gpa));
    try testing.expectError(error.LengthExceedsInput, U.Decoder.init(&[_]u8{ 0x7d, 0x01 }));
    // signed(-1) with no value at all.
    try testing.expectError(error.LengthExceedsInput, U.decodeAll(&[_]u8{0x7f}, gpa));
    // A literal run at the end of a slab that runs past it.
    try testing.expectError(
        error.LengthExceedsInput,
        U.decodeAll(&[_]u8{ 0x02, 0x05, 0x7e, 0x01 }, gpa),
    );
    // minInt(i64) as a header is a literal count of 2^63: negating it must not
    // trap, and no slab can hold that many values.
    const two_to_63 = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f };
    try testing.expectError(error.LengthExceedsInput, U.decodeAll(&two_to_63, gpa));
    try testing.expectError(error.LengthExceedsInput, U.Decoder.init(&two_to_63));
}

test "an overlong LEB128 is rejected" {
    const gpa = testing.allocator;
    const U = Rle(u64);
    const O = RleOption(u64);

    // Eleven continuation bytes: longer than any LEB128.
    const overlong = [_]u8{0x80} ** 11;
    try testing.expectError(error.InvalidLeb128, U.decodeAll(&overlong, gpa));
    try testing.expectError(error.InvalidLeb128, O.decodeAll(&overlong, gpa));
    try testing.expectError(error.InvalidLeb128, U.Decoder.init(&overlong));
    // Overlong in a run header after a well-formed run.
    try testing.expectError(
        error.InvalidLeb128,
        U.decodeAll(&[_]u8{ 0x02, 0x05 } ++ overlong, gpa),
    );
    // Overlong in a value payload.
    try testing.expectError(error.InvalidLeb128, U.decodeAll(&[_]u8{0x7f} ++ overlong, gpa));
    // Overlong in a null run's count.
    try testing.expectError(error.InvalidLeb128, O.decodeAll(&[_]u8{0x00} ++ overlong, gpa));
    // A tenth byte carrying more than the one bit that is left is an overflow,
    // not an overlong encoding.
    try testing.expectError(
        error.Overflow,
        U.decodeAll(&[_]u8{ 0x7f, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }, gpa),
    );
}

test "the largest counts a header can spell are refused" {
    const gpa = testing.allocator;
    const O = RleOption(u64);

    // A null run's count is an unsigned varint, so `maxInt(u64)` is the
    // largest a null run can claim: eleven bytes for four billion values
    // each.
    const huge = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    const one = [_]u8{0x00} ++ huge;
    try testing.expectError(error.TooLarge, O.decodeAll(&one, gpa));
    try testing.expectError(error.TooLarge, RleOption(i64).decodeAll(&one, gpa));
    // Two of them: the count has to notice the accumulation, and it does so
    // in the counting pass, before anything is allocated.
    const doubled = [_]u8{0x00} ++ huge ++ [_]u8{0x00} ++ huge;
    try testing.expectError(error.TooLarge, O.decodeAll(&doubled, gpa));

    // A repeat run spells its count with a signed header, which reaches one
    // bit lower: `maxInt(i64)`.
    const repeat = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x07 };
    try testing.expectError(error.TooLarge, Rle(u64).decodeAll(&repeat, gpa));
    try testing.expectError(error.TooLarge, Rle(i64).decodeAll(&repeat, gpa));

    // The cursor refuses the same slabs at the same point, before it reads a
    // single value.
    try testing.expectError(error.TooLarge, O.Decoder.init(&one));
    try testing.expectError(error.TooLarge, Rle(u64).Decoder.init(&repeat));
}

test "canonical accepts what write produces" {
    const us = [_][]const u64{
        &.{},
        &.{42},
        &.{ 7, 7, 7, 7, 7 },
        &.{ 1, 2, 3, 4 },
        &.{ 1, 2, 3, 3, 3 },
        &.{ 5, 5, 5, 1, 2, 3 },
        &.{ 1, 1, 2, 3, 3 },
        &.{ 1, 2, 3, 3, 3, 4, 5, 5, 6, 7, 7, 7, 7, 8 },
        &.{ std.math.maxInt(u64), 0, std.math.maxInt(u64) },
    };
    for (us) |c| try expectCanonical(Rle(u64), u64, c);

    const is = [_][]const i64{ &.{ -1, -1, 5 }, &([_]i64{0} ** 3), &.{ std.math.minInt(i64), 0 } };
    for (is) |c| try expectCanonical(Rle(i64), i64, c);

    const os = [_][]const ?u64{
        &([_]?u64{null} ** 4),
        &.{ 1, null, null, 2 },
        &.{ 5, 5, 5, null, null, 4, 5, 5 },
        &.{ null, 1, 2, 3, null },
    };
    for (os) |c| try expectCanonical(RleOption(u64), ?u64, c);

    // The empty slab is canonical and decodes to no values at all.
    const gpa = testing.allocator;
    try Rle(u64).canonical(&[_]u8{});
    const none = try Rle(u64).decodeAll(&[_]u8{}, gpa);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    var dec = try Rle(u64).Decoder.init(&[_]u8{});
    try testing.expect((try dec.next()) == null);
}

test "canonical rejects a non-canonical slab" {
    const U = Rle(u64);
    const O = RleOption(u64);

    // Rule 1: a repeat run with count < 2.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x01, 0x05 }));
    // Rule 6: two adjacent repeat runs with the same value.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x02, 0x05, 0x02, 0x05 }));
    // Adjacent repeat runs with different values are fine.
    try U.canonical(&[_]u8{ 0x02, 0x05, 0x02, 0x06 });
    // Rule 7: consecutive equal values inside a literal run.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x7e, 0x05, 0x05 }));
    // Rule 8, run to literal.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x02, 0x05, 0x7f, 0x05 }));
    // Rule 8, literal to run.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x7f, 0x05, 0x02, 0x05 }));
    // Rule 8 does not fire when the boundary values differ.
    try U.canonical(&[_]u8{ 0x02, 0x05, 0x7f, 0x06 });
    // Rule 4: two adjacent literal runs.
    try testing.expectError(error.InvalidValue, U.canonical(&[_]u8{ 0x7f, 0x05, 0x7f, 0x06 }));
    // Rule 2: a null run of count zero.
    try testing.expectError(error.InvalidValue, O.canonical(&[_]u8{ 0x00, 0x00 }));
    // Rule 5: two adjacent null runs.
    try testing.expectError(error.InvalidValue, O.canonical(&[_]u8{ 0x00, 0x01, 0x00, 0x01 }));
    // A single null run is fine.
    try O.canonical(&[_]u8{ 0x00, 0x01 });
    // Rule 9: a null run in a non-nullable column, at every entry point.
    try testing.expectError(error.UnexpectedNull, U.canonical(&[_]u8{ 0x00, 0x01 }));
    try testing.expectError(error.UnexpectedNull, U.Decoder.init(&[_]u8{ 0x00, 0x01 }));
    const gpa = testing.allocator;
    try testing.expectError(error.UnexpectedNull, U.decodeAll(&[_]u8{ 0x00, 0x01 }, gpa));
    // A malformed slab is malformed, not non-canonical.
    try testing.expectError(error.LengthExceedsInput, U.canonical(&[_]u8{ 0x7d, 0x01 }));
    try testing.expectError(error.UnexpectedEnd, U.canonical(&[_]u8{0x80}));
}

test "a value payload is read as the type it was written as" {
    const gpa = testing.allocator;
    // The same bytes are both a signed and an unsigned payload, and they are
    // not the same number: -1 as signed LEB128 is 0x7f, which unsigned LEB128
    // reads as 127. This is the whole reason the value type is in the codec.
    const neg = [_]u8{ 0x02, 0x7f };
    const as_i64 = try Rle(i64).decodeAll(&neg, gpa);
    defer gpa.free(as_i64);
    try testing.expectEqualSlices(i64, &.{ -1, -1 }, as_i64);
    const as_u64 = try Rle(u64).decodeAll(&neg, gpa);
    defer gpa.free(as_u64);
    try testing.expectEqualSlices(u64, &.{ 127, 127 }, as_u64);
}

test "pseudo-random value sequences round trip and stay canonical" {
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const random = prng.random();

    // Small values with plenty of repeats, so the sweep keeps landing on runs
    // of two and three rather than on one long literal.
    var us: [64]u64 = undefined;
    var is: [64]i64 = undefined;
    var os: [64]?u64 = undefined;
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        const n = random.uintLessThan(usize, us.len + 1);
        for (0..n) |i| {
            us[i] = random.intRangeAtMost(u64, 0, 3);
            is[i] = random.intRangeAtMost(i64, -3, 3);
            os[i] = if (random.boolean()) null else random.intRangeAtMost(u64, 0, 3);
        }
        try checkRoundTrip(Rle(u64), u64, us[0..n]);
        try checkRoundTrip(Rle(i64), i64, is[0..n]);
        try checkRoundTrip(RleOption(u64), ?u64, os[0..n]);
    }
}

test "arbitrary bytes are refused, never a trap" {
    const gpa = testing.allocator;
    const U = Rle(u64);
    const O = RleOption(u64);
    // The byte payload's reader is the one that trusts a number from the
    // wire, so the sweep below runs all four of its codecs over the same
    // bytes: two spellings of "any byte" and two of "UTF-8 only".
    const B = Rle([]const u8);
    const BO = RleOption([]const u8);
    const S = RleUtf8(false);
    const SO = RleUtf8(true);
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();

    // One sweep over raw random bytes through everything that does not
    // materialise values. The header and payload readers are what could trap
    // here, and this is what covers them over input nobody chose.
    var bytes: [48]u8 = undefined;
    var round: usize = 0;
    while (round < 3000) : (round += 1) {
        const len = random.uintLessThan(usize, bytes.len + 1);
        for (bytes[0..len]) |*b| b.* = random.int(u8);
        U.canonical(bytes[0..len]) catch {};
        O.canonical(bytes[0..len]) catch {};
        B.canonical(bytes[0..len]) catch {};
        BO.canonical(bytes[0..len]) catch {};
        S.canonical(bytes[0..len]) catch {};
        SO.canonical(bytes[0..len]) catch {};
        if (U.Decoder.init(bytes[0..len])) |made| {
            var d = made;
            // Three values is enough to cross a header boundary; counting them
            // all is what would be unbounded.
            var steps: usize = 0;
            while (steps < 3) : (steps += 1) {
                _ = d.next() catch break;
            }
        } else |_| {}
        if (O.Decoder.init(bytes[0..len])) |made| {
            var d = made;
            var steps: usize = 0;
            while (steps < 3) : (steps += 1) {
                _ = d.next() catch break;
            }
        } else |_| {}
        inline for (.{ B, BO, S, SO }) |codec| {
            if (codec.Decoder.init(bytes[0..len])) |made| {
                var d = made;
                var steps: usize = 0;
                while (steps < 3) : (steps += 1) {
                    _ = d.next() catch break;
                }
            } else |_| {}
        }
    }

    // A second sweep over slabs built from the run grammar with *byte*
    // payloads — a length, then that many bytes — so the payload reader is
    // exercised against lengths that are right, short by a byte or two, and
    // absurd.
    round = 0;
    while (round < 2000) : (round += 1) {
        const len = byteGrammarSlab(random, &bytes);
        const flip = random.uintLessThan(usize, len);
        bytes[flip] ^= @as(u8, 1) << @intCast(random.uintLessThan(u8, 8));
        _ = B.canonical(bytes[0..len]) catch {};
        _ = BO.canonical(bytes[0..len]) catch {};
        _ = S.canonical(bytes[0..len]) catch {};
        _ = SO.canonical(bytes[0..len]) catch {};
        const back = B.decodeAll(bytes[0..len], gpa) catch continue;
        defer gpa.free(back);
        // What decoded must hold exactly what the cursor yields, value for
        // value, compared by content — the two readers cannot drift apart.
        var dec = try B.Decoder.init(bytes[0..len]);
        var i: usize = 0;
        while (i < back.len) : (i += 1) {
            try testing.expect(B.elementEql(back[i], (try dec.next()).?));
        }
        try testing.expect((try dec.next()) == null);
    }

    // A third sweep over slabs built from the run grammar with integer
    // payloads, each one then flipped at a random bit. These keep the counts
    // small enough to decode in full, so the two readers can be held against
    // each other.
    round = 0;
    while (round < 2000) : (round += 1) {
        const len = grammarSlab(random, &bytes);
        const flip = random.uintLessThan(usize, len);
        bytes[flip] ^= @as(u8, 1) << @intCast(random.uintLessThan(u8, 8));
        _ = U.canonical(bytes[0..len]) catch {};
        _ = O.canonical(bytes[0..len]) catch {};
        const back = U.decodeAll(bytes[0..len], gpa) catch continue;
        defer gpa.free(back);
        // What decoded must hold exactly what the cursor yields, value for
        // value, so the two readers cannot drift apart.
        var dec = try U.Decoder.init(bytes[0..len]);
        var i: usize = 0;
        while (i < back.len) : (i += 1) {
            try testing.expectEqual(back[i], (try dec.next()).?);
        }
        try testing.expect((try dec.next()) == null);
    }
}

/// Writes a slab built from the run grammar — a few repeat, literal and null
/// runs with small counts — into `out`, returning its length. The result need
/// not be canonical: two adjacent null runs are as likely as not, and the
/// reader has to be happy with that.
fn grammarSlab(random: std.Random, out: []u8) usize {
    var n: usize = 0;
    const runs = random.uintLessThan(usize, 4) + 1;
    for (0..runs) |_| {
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                n += leb128.writeSigned(out[n..], random.intRangeAtMost(i64, 1, 40));
                n += leb128.writeUnsigned(out[n..], random.int(u8) & 0x3f);
            },
            1 => {
                const count = random.uintLessThan(usize, 4) + 1;
                n += leb128.writeSigned(out[n..], -@as(i64, @intCast(count)));
                for (0..count) |_| n += leb128.writeUnsigned(out[n..], random.int(u8) & 0x3f);
            },
            else => {
                n += leb128.writeSigned(out[n..], 0);
                n += leb128.writeUnsigned(out[n..], random.intRangeAtMost(u64, 0, 40));
            },
        }
    }
    return n;
}

/// Writes a slab built from the run grammar with *byte* payloads — a length,
/// then that many bytes — into `out`, returning its length. The counts and the
/// payload lengths are capped so the slab always fits `out`; the payloads are
/// rarely all well-formed, because the claim the reader has to catch is a
/// length the bytes behind it do not back.
fn byteGrammarSlab(random: std.Random, out: []u8) usize {
    var n: usize = 0;
    const runs = random.uintLessThan(usize, 3) + 1;
    for (0..runs) |_| {
        switch (random.uintLessThan(u8, 3)) {
            0 => {
                n += leb128.writeSigned(out[n..], random.intRangeAtMost(i64, 1, 40));
                n += writeBytePayload(random, out[n..]);
            },
            1 => {
                const count = random.uintLessThan(usize, 2) + 1;
                n += leb128.writeSigned(out[n..], -@as(i64, @intCast(count)));
                for (0..count) |_| n += writeBytePayload(random, out[n..]);
            },
            else => {
                n += leb128.writeSigned(out[n..], 0);
                n += leb128.writeUnsigned(out[n..], random.intRangeAtMost(u64, 0, 40));
            },
        }
    }
    return n;
}

/// One length-prefixed byte payload, half the time claiming more bytes than
/// are written behind it.
fn writeBytePayload(random: std.Random, out: []u8) usize {
    const claimed = random.intRangeAtMost(u8, 0, 4);
    const written = if (random.boolean()) claimed else random.intRangeAtMost(u8, 0, 4);
    const n = leb128.writeUnsigned(out, claimed);
    for (out[n..][0..written]) |*b| b.* = random.int(u8);
    return n + written;
}

test "a slab claiming more values than a slab may hold is refused" {
    const gpa = testing.allocator;
    const U = Rle(u64);
    const O = RleOption(u64);
    var slab: [16]u8 = undefined;
    var n: usize = 0;

    // A repeat run of 2^33 values is three header bytes and one value byte.
    n = leb128.writeSigned(&slab, 1 << 33);
    n += leb128.writeUnsigned(slab[n..], 7);
    try testing.expectError(error.TooLarge, U.decodeAll(slab[0..n], gpa));
    try testing.expectError(error.TooLarge, U.Decoder.init(slab[0..n]));
    try testing.expectError(error.TooLarge, O.decodeAll(slab[0..n], gpa));
    // The same for a null run, whose count is unsigned.
    n = leb128.writeSigned(&slab, 0);
    n += leb128.writeUnsigned(slab[n..], 1 << 33);
    try testing.expectError(error.TooLarge, O.decodeAll(slab[0..n], gpa));
    try testing.expectError(error.TooLarge, O.Decoder.init(slab[0..n]));

    // Exactly the limit is still a legal slab: the cursor serves a run that
    // long out of memory, without materialising it.
    n = leb128.writeSigned(&slab, @as(i64, 1) << 32);
    n += leb128.writeUnsigned(slab[n..], 7);
    var dec = try U.Decoder.init(slab[0..n]);
    try testing.expectEqual(@as(?u64, 7), try dec.next());
    try testing.expectEqual(@as(?u64, 7), try dec.next());
}

// ── Upstream `hexane/src/tests.rs`, the frozen byte fixtures ──────────────────

test "golden_format_rle_u64" {
    // **`tests.rs:4793-4799`.** `Column::<u64>::from_values(..).save()` against
    // the frozen bytes, then `Column::load` back to the values
    // ([`golden_rle`, `tests.rs:4773-4791`](
    // ../github-automerge-automerge/rust/hexane/src/tests.rs)).
    //
    // **A single-slab column's `save()` *is* its codec's bytes.** The column
    // wire format has no column-level header: the fixture
    // `[3, 1, 125, 2, 3, 4, 4, 5]` reads as `repeat(3)×1`, `signed(125) ==
    // -3` literal count then `2, 3, 4`, then `repeat(4)×5` — the whole of
    // upstream's RLE wire, which is what the module doc above quotes from
    // `rle/mod.rs:25-33`. So the case pins the **codec**, and it pins it at
    // the same bytes; a `Column` in the way would add nothing.
    //
    // The fixture is frozen, and upstream says so at `tests.rs:4762-4771`:
    // "If one of these assertions fails, the wire format changed. That is a
    // compatibility break with every existing automerge document: stop and
    // think, don't update the fixture." It is written out here, not read
    // from the corpus, for that reason.
    const fixture = [_]u8{ 3, 1, 125, 2, 3, 4, 4, 5 };
    const values = [_]u64{ 1, 1, 1, 2, 3, 4, 5, 5, 5, 5 };
    try expectBytes(Rle(u64), u64, &values, &fixture);

    // The reload half of `golden_rle`: the fixture decodes back to the values
    // it was frozen from, element by element and not by a length.
    const back = try Rle(u64).decodeAll(&fixture, testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u64, &values, back);
}

test "golden_format_rle_opt_u64" {
    // **`tests.rs:4802-4807`.** `Column::<Option<u64>>`, same fixture shape.
    //
    // Read as runs: `signed(0)` is the null marker and its payload is an
    // *unsigned* count, so `[0, 2]` is two absent values; then `2, 1` is
    // `repeat(2)×1`; `0, 1` is one absent; then `126, 2` is `signed(126) ==
    // -2` literal count with `2, 172` behind it — `172` as unsigned LEB128
    // is `172 - 128 = 44`, but the fixture says `300`, so the two literal
    // values are `172 & 0x7F = 44` continuing `2`'s high bit — that is,
    // `unsigned(2) = 0b10` low seven bits then `172`'s payload
    // `0b0101100`, which joins to `300`. The codec's own split is what
    // decides this, and `expectBytes` asserts the encoder agrees with it.
    const fixture = [_]u8{ 0, 2, 2, 1, 0, 1, 126, 2, 172, 2 };
    const values = [_]?u64{ null, null, 1, 1, null, 2, 300 };
    try expectBytes(RleOption(u64), ?u64, &values, &fixture);

    const back = try RleOption(u64).decodeAll(&fixture, testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(?u64, &values, back);
}

test "golden_format_rle_str" {
    // **`tests.rs:4810-4815`.** `Column::<String>`, the same frozen-fixture
    // shape as the two integer cases above.
    //
    // Read as runs: `2` is `repeat(2)` and its payload is `1, 97` — an
    // unsigned LEB128 length of one followed by the byte `'a'`, which is
    // `RleValue for String`'s `pack` (`lib.rs:725-729`). `126` is
    // `signed(126) == -2`, a literal run of two values `"bb"` and `"ccc"`,
    // each written the same way. So the fixture is exactly what `write`
    // produces and `decodeAll` reads back.
    const fixture = [_]u8{ 2, 1, 97, 126, 2, 98, 98, 3, 99, 99, 99 };
    // The two `"a"`s are two windows of one buffer, so the repeat run this
    // fixture pins cannot come from comparing slice identity.
    var raw = [_]u8{ 'a', 'x', 'a', 'y', 'b', 'b', 'c', 'c', 'c' };
    const values = [_][]const u8{ raw[0..1], raw[2..3], raw[4..6], raw[6..9] };
    try expectBytes(RleUtf8(false), []const u8, &values, &fixture);

    const back = try RleUtf8(false).decodeAll(&fixture, testing.allocator);
    defer testing.allocator.free(back);
    try expectEqualElements(RleUtf8(false), &values, back);
}

test "golden_format_rle_opt_str" {
    // **`tests.rs:4818-4823`.** `Column::<Option<String>>`.
    //
    // `127` is `signed(-1)`, a literal run of one value `"x"`; `0, 2` is the
    // null marker with an *unsigned* count of two, so two absent values; then
    // `127` again for the literal `"yz"`. **The two adjacent absent values are
    // one null run and not two literal zero-length payloads**: an absent
    // value is carried by the header and never by a payload
    // (`lib.rs:406-437`), so `null` and `""` are different wire forms.
    const fixture = [_]u8{ 127, 1, 120, 0, 2, 127, 2, 121, 122 };
    const present_x: ?[]const u8 = "x";
    const absent: ?[]const u8 = null;
    const present_yz: ?[]const u8 = "yz";
    const values = [_]?[]const u8{ present_x, absent, absent, present_yz };
    try expectBytes(RleUtf8(true), ?[]const u8, &values, &fixture);

    const back = try RleUtf8(true).decodeAll(&fixture, testing.allocator);
    defer testing.allocator.free(back);
    try expectEqualElements(RleUtf8(true), &values, back);
}

test "golden_format_rle_bytes" {
    // **`tests.rs:4826-4831`.** `Column::<Vec<u8>>`, the payload that takes
    // any byte rather than only UTF-8 (`lib.rs:747-770`).
    //
    // `2` is `repeat(2)` over the payload `2, 1, 2` — length two, bytes
    // `1, 2` — and `127` is a literal run of one value, `1, 3`. The wire form
    // is `Vec<u8>`'s, and the value type is `[]const u8`: a borrowed window on
    // the slab, not an owning buffer.
    const fixture = [_]u8{ 2, 2, 1, 2, 127, 1, 3 };
    // Two windows of one buffer, so the repeat run the fixture pins is found
    // by content and not by slice identity.
    var raw = [_]u8{ 1, 2, 1, 2, 3 };
    const values = [_][]const u8{ raw[0..2], raw[2..4], raw[4..5] };
    try expectBytes(Rle([]const u8), []const u8, &values, &fixture);

    const back = try Rle([]const u8).decodeAll(&fixture, testing.allocator);
    defer testing.allocator.free(back);
    try expectEqualElements(Rle([]const u8), &values, back);
}

test "a byte payload is a length and the bytes, at every width" {
    // **`lib.rs:696-770`.** The one payload whose width is not a function of
    // the type: a length prefix plus that many bytes, with the length itself
    // LEB128, so a value's size crosses from one header byte to two at 128
    // bytes of content. Every value below round trips through all four entry
    // points, and `encodedSize` has to agree with `write` at each of them.
    const Codec = Rle([]const u8);
    const gpa = testing.allocator;

    // 127 bytes is the widest one-byte length; 128 is the first that needs a
    // second header byte. The contents cycle, so a payload is never a
    // constant string a comparison could short-circuit.
    var at127: [127]u8 = undefined;
    for (&at127, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    var at128: [128]u8 = undefined;
    for (&at128, 0..) |*b, i| b.* = @intCast('a' + i % 26);

    const empty: [0]u8 = .{};
    const bad: []const u8 = &[_]u8{ 0xff, 0xfe };
    const bad2: []const u8 = &[_]u8{ 0x00, 0x80 };
    const mixed: []const u8 = &[_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xf4, 0x8f, 0xbf, 0xbf };

    const cases = [_][]const []const u8{
        &.{},
        &.{""},
        &.{ "", "" },
        &.{ "", "x", "" },
        &.{ "a", "a" },
        &.{ "a", "b", "a" },
        &.{ "hello", "hello", "hello", "world" },
        &.{ "", "hello", "", "world", "" },
        &.{&empty},
        // Bytes that are not UTF-8 at all: `Vec<u8>` takes them, and this is
        // the codec a `Vec<u8>` column is spelled with upstream
        // (`lib.rs:747-770`).
        &.{bad},
        &.{ bad, bad, bad2 },
        &.{mixed},
        &.{at127[0..]},
        &.{at128[0..]},
        &.{ at127[0..], at128[0..], at127[0..] },
    };
    for (cases) |c| try checkRoundTrip(Codec, []const u8, c);

    // The width claim itself, read off the wire. A single value is a
    // one-element literal: one header byte, then the length, then the bytes.
    // 127 fits one length byte and 128 needs two, so the two slabs differ by
    // exactly the extra length byte and nothing else.
    const one = [_][]const u8{at127[0..]};
    const one_bytes = try expectWritten(Codec, []const u8, &one);
    defer gpa.free(one_bytes);
    try testing.expectEqual(@as(usize, 1 + 1 + 127), one_bytes.len);
    const two = [_][]const u8{at128[0..]};
    const two_bytes = try expectWritten(Codec, []const u8, &two);
    defer gpa.free(two_bytes);
    try testing.expectEqual(@as(usize, 1 + 2 + 128), two_bytes.len);
}

test "an empty string is a present value and a null is not one" {
    // Upstream's nullable string column has three states a run boundary can
    // tell apart — a present non-empty value, a present *empty* value, and an
    // absent one (`lib.rs:406-437`, `:696-730`). Only the last is a null run.
    //
    // This is the arm a byte payload adds and an integer cannot: with `""`
    // present and `null` absent, `null` is not the identity of the codec's
    // element equality, and `""` twice in a row is a repeat run while `""`
    // then `null` is two runs of different kinds.
    const Codec = RleOption([]const u8);
    const gpa = testing.allocator;
    const empty_v: ?[]const u8 = "";
    const absent: ?[]const u8 = null;
    const one: ?[]const u8 = "x";

    // Two empty values are `repeat(2)` over a zero-length payload — one
    // length byte and no content at all.
    try expectBytes(Codec, ?[]const u8, &.{ empty_v, empty_v }, &.{ 0x02, 0x00 });
    // An empty value beside a null: the literal is `127` (one value) with a
    // zero-length payload, then the null marker with its unsigned count.
    try expectBytes(Codec, ?[]const u8, &.{ empty_v, absent }, &.{ 0x7f, 0x00, 0x00, 0x01 });

    const values = [_]?[]const u8{ empty_v, absent, empty_v, empty_v, absent, one, empty_v };
    const bytes = try expectWritten(Codec, ?[]const u8, &values);
    defer gpa.free(bytes);
    const back = try Codec.decodeAll(bytes, gpa);
    defer gpa.free(back);
    try expectEqualElements(Codec, &values, back);

    // And the three states really are three states: an absent value is never
    // content-equal to an empty one.
    try testing.expect(!Codec.elementEql(absent, empty_v));
    try testing.expect(!Codec.elementEql(empty_v, absent));
    try testing.expect(Codec.elementEql(absent, absent));
    try testing.expect(Codec.elementEql(empty_v, empty_v));

    // A slab that spells two empty values as two adjacent literals is
    // non-canonical, because they should have been one repeat run.
    try testing.expectError(error.InvalidValue, Codec.canonical(&.{ 0x7f, 0x00, 0x7f, 0x00 }));
}

test "run boundaries are decided by content, not by slice identity" {
    // The byte payload's trap: two spellings of the same string borrowed from
    // two offsets of one slab are different slices, so Zig's `==` says they
    // differ. Every rule that turns on "these are the same value" — the
    // segmenter's run detection and rules 6, 7 and 8 of `canonical` — has to
    // answer it by content instead.
    const Codec = Rle([]const u8);

    // Three windows of one buffer: different pointers, same bytes.
    var raw = [_]u8{ 'a', 'a', 'a' };
    const b = raw[0..1];
    const c = raw[1..2];
    const d = raw[2..3];
    try testing.expect(!std.meta.eql(b, c));
    try testing.expect(Codec.elementEql(b, c));

    // The encoder's side: three equal values are one repeat run, because the
    // segmenter compared their contents.
    try expectBytes(Codec, []const u8, &.{ b, c, d }, &.{ 0x03, 0x01, 97 });

    // The validator's side, on hand-written slabs whose payloads sit at
    // different byte offsets and are therefore *different* slices:
    // `repeat(2)×"a"` then a literal `"a"` breaks rule 8.
    try testing.expectError(
        error.InvalidValue,
        Codec.canonical(&.{ 0x02, 0x01, 97, 0x7f, 0x01, 97 }),
    );
    // Two equal values inside one literal run: rule 7, same reason — the two
    // payloads sit at different offsets of the same slab, so `==` cannot see
    // them. And the encoder never produces either shape.
    try testing.expectError(
        error.InvalidValue,
        Codec.canonical(&.{ 0x7f, 0x02, 0x01, 97, 0x01, 97 }),
    );
    const three = [_][]const u8{ b, c, d };
    try expectCanonical(Codec, []const u8, &three);
}

test "load_invalid_utf8_in_string_is_error" {
    // **`tests.rs:1797-1814`.** A bytes column's output must not load as a
    // string column.
    //
    // Upstream builds the slab with `Column::<Vec<u8>>::from_values` and reads
    // it back with `Column::<String>::load`, and expects
    // `PackError::InvalidUtf8`. **The slab is the same bytes either way** —
    // `String` and `Vec<u8>` share one payload (`lib.rs:696-730`,
    // `:747-770`) — so what differs is only which codec reads it, which is
    // exactly what this does: the bytes codec writes, the UTF-8 codec reads.
    const gpa = testing.allocator;
    const bad: []const u8 = &[_]u8{ 0xff, 0xfe };
    const values = [_][]const u8{bad};
    const bytes = try expectWritten(Rle([]const u8), []const u8, &values);
    defer gpa.free(bytes);

    // The bytes codec is happy with them: they are its own output.
    const own = try Rle([]const u8).decodeAll(bytes, gpa);
    defer gpa.free(own);
    try expectEqualElements(Rle([]const u8), &values, own);
    try Rle([]const u8).canonical(bytes);

    // Every reading of the same slab as a string is `error.InvalidUtf8`.
    try testing.expectError(error.InvalidUtf8, RleUtf8(false).decodeAll(bytes, gpa));
    try testing.expectError(error.InvalidUtf8, RleUtf8(false).canonical(bytes));
    try testing.expectError(error.InvalidUtf8, RleUtf8(false).countEntries(bytes));
    // **`Decoder.init` reads the opening run *header* only**, and the header
    // of a literal run says nothing about its payload, so the refusal is
    // raised by the first `next` — where the payload is read. The same is
    // true of the nullable form's null refusal, and the same reasoning is
    // recorded at the foot of this file.
    {
        var dec = try RleUtf8(false).Decoder.init(bytes);
        try testing.expectError(error.InvalidUtf8, dec.next());
    }
}

test "load_invalid_utf8_in_nullable_string_is_error" {
    // **`tests.rs:1817-1833`.** The same refusal for `Column<Option<String>>`.
    //
    // **The null run is not what makes this nullable.** Upstream's slab holds
    // one value and no null at all, and the refusal is the UTF-8 check on
    // that value's payload; the nullable form only adds that a *payload* byte
    // can never spell an absent one, so the check has to run in the same
    // place for both forms.
    const gpa = testing.allocator;
    const present: ?[]const u8 = &[_]u8{ 0xff, 0xfe };
    const values = [_]?[]const u8{present};
    const bytes = try expectWritten(RleOption([]const u8), ?[]const u8, &values);
    defer gpa.free(bytes);

    const own = try RleOption([]const u8).decodeAll(bytes, gpa);
    defer gpa.free(own);
    try expectEqualElements(RleOption([]const u8), &values, own);

    try testing.expectError(error.InvalidUtf8, RleUtf8(true).decodeAll(bytes, gpa));
    try testing.expectError(error.InvalidUtf8, RleUtf8(true).canonical(bytes));
    try testing.expectError(error.InvalidUtf8, RleUtf8(true).countEntries(bytes));
    {
        var dec = try RleUtf8(true).Decoder.init(bytes);
        try testing.expectError(error.InvalidUtf8, dec.next());
    }
}

test "a string codec refuses a payload the bytes cannot back" {
    // **Truncation is where a variable-width payload stops being total.** An
    // integer payload is bounded by its own LEB128 width; a byte payload is
    // bounded by a number the wire spells and the bytes do not have to
    // agree with, so the reader has to check and refuse.
    const gpa = testing.allocator;
    const B = Rle([]const u8);
    const S = RleUtf8(false);

    // A literal run of one value whose length is 5 with two bytes behind it.
    const short = [_]u8{ 0x7f, 0x05, 'a', 'b' };
    try testing.expectError(error.LengthExceedsInput, S.decodeAll(&short, gpa));
    try testing.expectError(error.LengthExceedsInput, S.canonical(&short));
    try testing.expectError(error.LengthExceedsInput, B.decodeAll(&short, gpa));

    // The same claim in a repeat run, which is the other way a payload is
    // read: once at the run, then served from memory for each of its values.
    const repeat = [_]u8{ 0x02, 0x05, 'a' };
    try testing.expectError(error.LengthExceedsInput, S.decodeAll(&repeat, gpa));
    try testing.expectError(error.LengthExceedsInput, B.canonical(&repeat));

    // A length that does not fit `usize` at all: ten continuation bytes and a
    // payload, which `readUnsigned` refuses before anything is sized from it.
    const huge = [_]u8{
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01,
    };
    try testing.expectError(error.Overflow, S.decodeAll(&huge, gpa));

    // Every prefix of a real slab is either refused or decoded, and the two
    // that cut a payload in half are the dedicated error. A run-length format
    // makes no promise about a prefix that lands on a run boundary — that is a
    // complete slab — so what is pinned is that no cut traps and that the two
    // readers never disagree about a cut both of them accept.
    const whole = [_]u8{ 0x02, 0x02, 'h', 'i', 0x7e, 0x01, 'a', 0x02, 'b', 'b' };
    for (0..whole.len) |cut| {
        const got = B.decodeAll(whole[0..cut], gpa) catch continue;
        defer gpa.free(got);
        var dec = try B.Decoder.init(whole[0..cut]);
        var i: usize = 0;
        while (i < got.len) : (i += 1) {
            try testing.expect(B.elementEql(got[i], (try dec.next()).?));
        }
        try testing.expect((try dec.next()) == null);
    }
    for ([_]usize{ 3, 9 }) |cut| {
        try testing.expectError(error.LengthExceedsInput, B.decodeAll(whole[0..cut], gpa));
    }

    // The payload read out of a slab is a window on the slab itself, so a
    // value's bytes are the encoded bytes and not a copy of them.
    const decoded = try B.decodeAll(&whole, gpa);
    defer gpa.free(decoded);
    try testing.expectEqualSlices(u8, "hi", decoded[0]);
    try testing.expectEqualSlices(u8, "bb", decoded[3]);
}

test "load_null_in_non_nullable_bytes_is_error" {
    // **`tests.rs:1869-1878`.** Bytes a *nullable* column saved must not load
    // into a non-nullable one — upstream's `Column<Option<Vec<u8>>>` into
    // `Column<Vec<u8>>`.
    //
    // **Rule 9 is carried by the run header, never by a payload byte** — that
    // is the module doc's own statement of the null run's form
    // (`rle/mod.rs:25-33`, quoted at `rle.zig:1-20`), and it is why the
    // refusal is the same whatever the values are. What is exercised here is
    // the half a hand-written fixture does not: the bytes are *produced* by
    // the nullable encoder and then refused by the non-nullable reader, so an
    // encoder that stopped emitting the null run would fail here.
    const gpa = testing.allocator;
    const present: ?[]const u8 = "a";
    const nullable = [_]?[]const u8{ present, null };
    const bytes = try expectWritten(RleOption([]const u8), ?[]const u8, &nullable);
    defer gpa.free(bytes);

    // The nullable codec is happy with them: they are its own output.
    const own = try RleOption([]const u8).decodeAll(bytes, gpa);
    defer gpa.free(own);
    try expectEqualElements(RleOption([]const u8), &nullable, own);

    // And every non-nullable entry point that sees the null run refuses them.
    // **Not `Decoder.init`, which legitimately succeeds here**: the slab is
    // `[0x7f, 0x01, 0x61, 0x00, 0x01]` — one literal value then one absent —
    // and `init` reads only the *first* run header, which is a legal literal
    // (`rle.zig:344-352`). The refusal is raised when the cursor reaches the
    // null run, which is what `decodeAll` and the walk below both show.
    try testing.expectError(error.UnexpectedNull, Rle([]const u8).decodeAll(bytes, gpa));
    try testing.expectError(error.UnexpectedNull, Rle([]const u8).canonical(bytes));
    {
        var dec = try Rle([]const u8).Decoder.init(bytes);
        try testing.expectEqualStrings("a", (try dec.next()).?);
        try testing.expectError(error.UnexpectedNull, dec.next());
    }
}

test "load_null_in_non_nullable_string_is_error" {
    // **`tests.rs:1858-1867`.** The same refusal, for `Column<String>` — and
    // **the UTF-8 codec rather than the bytes codec**, so the two cases differ
    // in more than their names: this one has to get past the string check
    // before it reaches the null run at all.
    //
    // Two cases that reduce to one assertion at the codec are kept as two
    // tests because upstream has two tests, and a coverage count against
    // `rust/hexane/src/tests.rs` is only legible if every upstream name is
    // spelled; **the body is deliberately the same, so a reader who wants one
    // of them can delete the other.**
    const gpa = testing.allocator;
    const present: ?[]const u8 = "a";
    const nullable = [_]?[]const u8{ present, null };
    const bytes = try expectWritten(RleUtf8(true), ?[]const u8, &nullable);
    defer gpa.free(bytes);

    const own = try RleUtf8(true).decodeAll(bytes, gpa);
    defer gpa.free(own);
    try expectEqualElements(RleUtf8(true), &nullable, own);

    // The same two whole-slab entry points, and for the same reason `init` is
    // not among them: the null run is the second one, not the first.
    try testing.expectError(error.UnexpectedNull, RleUtf8(false).decodeAll(bytes, gpa));
    try testing.expectError(error.UnexpectedNull, RleUtf8(false).canonical(bytes));
    {
        var dec = try RleUtf8(false).Decoder.init(bytes);
        try testing.expectEqualStrings("a", (try dec.next()).?);
        try testing.expectError(error.UnexpectedNull, dec.next());
    }
}

// ── The differential corpus ──────────────────────────────────────────────────

const corpus = @import("codec_golden.zig");

/// The boundary cases the RLE corpus has to carry.
///
/// Named case by case because a corpus that quietly lost one of these would
/// still pass every comparison below while testing less: the run counts are
/// where a LEB128 width changes, `pair_*` is where a header width and a
/// payload width disagree, and the `null_*` counts are the same widths on the
/// nullable form's own count field.
const rle_boundary_cases = [_][]const u8{
    "empty",
    "one",
    "two_equal",
    "two_differ",
    "three_aba",
    "three_all_differ",
    "repeat_2",
    "repeat_3",
    "repeat_63",
    "repeat_64",
    "repeat_65",
    "repeat_127",
    "repeat_128",
    "repeat_129",
    "repeat_16383",
    "repeat_16384",
    "repeat_16385",
    "null_2",
    "null_127",
    "null_128",
    "null_16384",
    "null_16385",
    "pair_0",
    "boundary_literal",
    "all_equal_300",
    "ascending",
    "descending",
    "alternating",
    "null_alone",
    "null_then_value",
    "value_then_null",
    "null_sandwiched",
    "nulls_and_boundaries",
    "random_0",
    "random_12",
    "random_23",
};

/// The eight column types the RLE corpus carries.
///
/// A table of `(name, tag)` pairs rather than a `switch` on the name: Zig
/// will not switch on a `[]const u8`, and the codec type has to be known at
/// compile time for `checkOne` to instantiate it. `corpus.dispatch` walks
/// this with an `inline for` and hands each arm a comptime tag.
const RleKind = enum { u64, i64, u32, i32, opt_u64, opt_i64, opt_u32, opt_i32 };

const rle_kinds = [_]struct { name: []const u8, tag: RleKind }{
    .{ .name = "rle-u64", .tag = .u64 },
    .{ .name = "rle-i64", .tag = .i64 },
    .{ .name = "rle-u32", .tag = .u32 },
    .{ .name = "rle-i32", .tag = .i32 },
    .{ .name = "rle-opt-u64", .tag = .opt_u64 },
    .{ .name = "rle-opt-i64", .tag = .opt_i64 },
    .{ .name = "rle-opt-u32", .tag = .opt_u32 },
    .{ .name = "rle-opt-i32", .tag = .opt_i32 },
};

/// One golden case, through the codec the record names.
fn rleCaseFor(kind: RleKind, rec: corpus.Record, gpa: std.mem.Allocator) !void {
    switch (kind) {
        .u64 => try corpus.checkOne(Rle(u64), u64, gpa, rec),
        .i64 => try corpus.checkOne(Rle(i64), i64, gpa, rec),
        .u32 => try corpus.checkOne(Rle(u32), u32, gpa, rec),
        .i32 => try corpus.checkOne(Rle(i32), i32, gpa, rec),
        .opt_u64 => try corpus.checkOne(RleOption(u64), ?u64, gpa, rec),
        .opt_i64 => try corpus.checkOne(RleOption(i64), ?i64, gpa, rec),
        .opt_u32 => try corpus.checkOne(RleOption(u32), ?u32, gpa, rec),
        .opt_i32 => try corpus.checkOne(RleOption(i32), ?i32, gpa, rec),
    }
}

fn rleCase(rec: corpus.Record, gpa: std.mem.Allocator) !void {
    try corpus.dispatch(rle_kinds, rleCaseFor, gpa, rec);
}

test "the RLE codec encodes the reference's bytes for every golden case" {
    const gpa = testing.allocator;
    var names = corpus.Names.init(gpa);
    defer names.deinit();

    // The count is the corpus: eight types over one case list each. A change
    // to it means the corpus changed and the coverage below has to be re-read.
    const cases = try corpus.eachCase(gpa, "rle", &names, rleCase);
    try testing.expectEqual(@as(usize, 890), cases);
    try names.expectRequired(&rle_boundary_cases);
}

test "the corpus came out of the generator this port can reproduce" {
    try testing.expectEqual(@as(usize, 1), try corpus.checkGenerator(testing.allocator));
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **The frozen fixtures are pinned at the codec, and a single-slab column's
//   `save()` is its codec's bytes.** There is no column-level header above a
//   run sequence, so `Column::<u64>::from_values(..).save()` over
//   `[1,1,1,2,3,4,5,5,5,5]` is exactly `Rle(u64).write` over the same values:
//   `[3, 1, 125, 2, 3, 4, 4, 5]`, read as `repeat(3)×1`, `signed(125) == -3`
//   literal count over `2,3,4`, then `repeat(4)×5`. **`golden_format_rle_u64`
//   and `golden_format_rle_opt_u64` therefore pin `Rle`/`RleOption` directly**
//   and name no `Column`; the fixtures are written out rather than read from
//   the corpus because upstream freezes them at `tests.rs:4762-4771` and says a
//   failure is a compatibility break with every existing automerge document.
//
// * **The three variable-width fixtures are pinned here too, and `RawColumn`
//   still could not carry them.** `golden_format_rle_str`,
//   `golden_format_rle_opt_str` and `golden_format_rle_bytes` encode a
//   length-prefixed byte payload, which is `Rle([]const u8)`,
//   `RleOption([]const u8)` and `RleUtf8` — one payload with two rules about
//   what it may contain (`lib.rs:696-730`, `:747-770`). They are pinned at the
//   same three fixtures for the same reason as the integer two: a single-slab
//   column's `save()` *is* its codec's bytes, so a `Column` in the way would
//   add nothing. `RawColumn` cannot stand in for any of them — its wire form
//   is a plain concatenation of slab bytes with no run headers and no value
//   boundary (`raw.zig:461-466`), so it cannot produce `[2, 1, 97, 126, 2, 98,
//   98, …]` — and `columnar/encoding.zig`'s `RleSlice` is outside this
//   crate's hexane surface.
//
// * **`load_null_in_non_nullable_bytes_is_error` and
//   `load_null_in_non_nullable_string_is_error` are spelled over the byte
//   codecs now, and that is a widening rather than a re-spelling.** Both were
//   written over `u64` because there was no byte payload to name; there is one
//   now, so each is spelled over the codec upstream names — `Rle([]const u8)`
//   and `RleUtf8` — with the *values* upstream uses (`Some("a")` then
//   `None`, `tests.rs:1858-1878`). What each case asserts is upstream's rule 9
//   either way: **a null run is carried by the run header and never by a
//   payload byte** (`rle/mod.rs:25-33`, quoted at `rle.zig:1-20`). What the
//   byte form adds is that the run before the null is a real payload, so an
//   encoder that stopped emitting the null run, or a reader that mistook a
//   zero-length payload for an absent value, fails here and would not have
//   failed over `u64`.
//
// * **`Decoder.init` is deliberately not among the refused entry points, for
//   either refusal.** `[Some("a"), null]` encodes as
//   `[0x7f, 0x01, 0x61, 0x00, 0x01]` — one literal value, then one absent —
//   and `init` reads only the *first* run header, which is a legal literal and
//   says nothing about its payload. The refusal surfaces when the cursor
//   reaches the null run, which `decodeAll` and the explicit walk both show;
//   the UTF-8 refusal surfaces on the first `next` for the same reason.
//   Asserting on `init` would be asserting that the slab's first run is the
//   null one, which it is not.
//
// * **A byte payload is borrowed, never copied, and that is upstream's rule.**
//   `payloadRead`, `decodeAll` and `Decoder.next` all return windows on the
//   bytes they were given, which is `try_unpack`'s `&'a [u8]`
//   (`lib.rs:700-709`, `:756-764`). `decodeAll` allocates the *headers* and
//   nothing else. **A caller that keeps a value past its slab's lifetime has
//   to copy it**, and a caller that appends to a `List` it handed to `append`
//   invalidates every value read out of it — which is why
//   `payloadRead`/`payloadAppend`/`payloadEql` are the three names a column
//   needs, and why `elementEql` rather than `==` is what it must compare with.
//
// * **A literal run of byte payloads is bounded by its byte count, not by its
//   value count.** `readRunHeader` rejects a literal count larger than the
//   bytes behind it, and that check is still right here because every payload
//   costs at least one byte — an empty `[]const u8` is the single-byte length
//   `0x00`, never zero bytes. So a run cannot claim more values than the slab
//   holds whatever its payloads are, and every walk over one stays bounded
//   before it starts.
