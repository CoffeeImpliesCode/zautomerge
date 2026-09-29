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
//! Values are packed by their own integer type: `u64` as unsigned LEB128,
//! `i64` as signed LEB128 (`rust/hexane/src/lib.rs:566-595`), so a `u64`
//! column never spends a byte on a sign and an `i64` column gets one-byte
//! values for −64..=63. `RleOption` is the nullable form: an absent value is
//! carried by the header, never by a payload byte
//! (`rust/hexane/src/lib.rs:406-437`).
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
//! Together those give the load iterator's own guarantee
//! (`rust/hexane/src/rle/load.rs:70-80`): adjacent runs never carry equal
//! values, by construction, and one wire run is exactly one logical run. Note
//! that a one-element *literal* is canonical — it is how a lone value is
//! written — while a one-element *repeat* is not, because rule 1 applies.
//! Given a value sequence the canonical encoding is unique, so `write` here
//! and the upstream state machine produce byte-identical slabs.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");

const ParseError = err.ParseError;

/// The codec over `T` for both the plain and the nullable column: `T` is the
/// integer whose LEB128 form is a value payload, and `Nullable` says whether
/// a null run is part of the format. For the plain form `Element == T`; for
/// the nullable form `Element == ?T`.
fn RleGeneric(comptime T: type, comptime Nullable: bool) type {
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
        /// `error.LengthExceedsInput`. Malformed bytes are whatever the LEB128
        /// reader says they are (`error.UnexpectedEnd`, `error.InvalidLeb128`).
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
                    // Rules 6 and 8.
                    if (prev) |p| switch (p) {
                        .run => |q| {
                            if (q == v) return error.InvalidValue;
                        },
                        .lit => |q| {
                            if (q == v) return error.InvalidValue;
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
                            if (pl == v) return error.InvalidValue; // rule 7
                        } else if (prev) |q| switch (q) {
                            // Rule 8, at the boundary of the literal run.
                            .run => |x| {
                                if (x == v) return error.InvalidValue;
                            },
                            .lit => |x| {
                                if (x == v) return error.InvalidValue;
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
                    const cv = try readValue(self.data, hdr.payload_at);
                    self.pos = hdr.payload_at + cv.len;
                    self.remaining = hdr.count;
                    self.run = .{ .repeat = cv.value };
                } else if (hdr.is_null) {
                    if (!Nullable) return error.UnexpectedNull;
                    const nc = try readNullCount(self.data, hdr.payload_at);
                    self.pos = hdr.payload_at + nc.header_len;
                    self.remaining = nc.count;
                    self.run = .null_run;
                } else {
                    // `readRunHeader` already proved the values are present.
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
        // (`rust/hexane/src/lib.rs:566-595`).

        /// The number of bytes one value of type `T` occupies.
        fn valueSize(value: T) usize {
            if (@typeInfo(T).int.signedness == .signed) {
                return leb128.signedSize(value);
            }
            return leb128.unsignedSize(value);
        }

        /// Writes one value payload, returning the bytes written.
        fn writeValue(out: []u8, value: T) usize {
            if (@typeInfo(T).int.signedness == .signed) {
                return leb128.writeSigned(out, value);
            }
            return leb128.writeUnsigned(out, value);
        }

        /// Reads one value payload. A payload byte can only ever spell a
        /// present value: an absent entry is carried by the run header, never
        /// by a payload.
        fn readValue(bytes: []const u8, pos: usize) ParseError!struct { value: T, len: usize } {
            if (@typeInfo(T).int.signedness == .signed) {
                const v = try leb128.readSigned(bytes[pos..]);
                const narrow = std.math.cast(T, v.value) orelse return error.Overflow;
                return .{ .value = narrow, .len = v.len };
            }
            const v = try leb128.readUnsigned(bytes[pos..]);
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
            const c = try leb128.readUnsigned(bytes[pos..]);
            return .{ .count = c.value, .header_len = c.len };
        }

        /// `-value` for the negative header of a literal run. Computed with a
        /// wrapping negate because `leb128.readSigned` can return
        /// `minInt(i64)`, and a literal count of 2^63 is a claim the wire
        /// allows even though no slab can satisfy it.
        fn literalCount(value: i64) u64 {
            std.debug.assert(value < 0);
            return -%@as(u64, @bitCast(value));
        }

        /// The value count of a whole slab, walked run by run and never
        /// materialising a value. Two null runs of `maxInt(u64)` absent values
        /// overflow, and that is caught here, before anything is allocated.
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
                    .null => |count| headerSize(0) + leb128.unsignedSize(count),
                };
            }

            /// Writes this segment into `out`, returning the bytes written.
            fn writeTo(s: Segment, out: []u8, values: []const Element) usize {
                return switch (s) {
                    .repeat => |r| blk: {
                        var n = leb128.writeSigned(out, @as(i64, @intCast(r.count)));
                        n += writeValue(out[n..], payload(r.value));
                        break :blk n;
                    },
                    .literal => |l| blk: {
                        var n = leb128.writeSigned(out, literalHeader(l.len));
                        for (values[l.start..][0..l.len]) |v| {
                            n += writeValue(out[n..], payload(v));
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
                    while (j < self.values.len and self.values[j] == v) j += 1;
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
            var n = leb128.signedSize(literalHeader(len));
            for (values[start..][0..len]) |v| n += valueSize(payload(v));
            return n;
        }

        /// `signed_leb128( count )`, the header of a repeat run.
        fn headerSize(count: usize) usize {
            std.debug.assert(count <= std.math.maxInt(i64));
            return leb128.signedSize(@as(i64, @intCast(count)));
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

/// The run-length codec for a non-nullable column. `T` is an integer, `u64` or
/// `i64` in this port: unsigned types pack their values as unsigned LEB128,
/// signed types as signed LEB128. A null run on the wire is
/// `error.UnexpectedNull` rather than a value.
pub fn Rle(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Rle values must be an integer type"),
    }
    return RleGeneric(T, false);
}

/// The run-length codec for a nullable column over `T`. An absent value is
/// carried by a null run in the header, so a literal or repeat payload always
/// holds a present value and `Element` is `?T`.
pub fn RleOption(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("RleOption values must be an integer type"),
    }
    return RleGeneric(T, true);
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
    try testing.expectEqualSlices(T, values, back);

    var dec = try Codec.Decoder.init(buf);
    for (values) |want| {
        try testing.expectEqual(want, (try dec.next()).?);
    }
    try testing.expect((try dec.next()) == null);

    const appended = try expectWritten(Codec, T, values);
    defer gpa.free(appended);
    try testing.expectEqualSlices(u8, buf, appended);
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
        &.{ 0 },
        &.{ 0, 0 },
        &.{300},
        &.{ std.math.maxInt(u64) },
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

test "a value count that overflows is rejected" {
    const gpa = testing.allocator;
    const O = RleOption(u64);

    // Two null runs of maxInt(u64) absent values: each one on its own fits a
    // usize, their sum does not. Caught in the counting pass, before anything
    // is allocated.
    const huge = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    const doubled = [_]u8{0x00} ++ huge ++ [_]u8{0x00} ++ huge;
    try testing.expectError(error.Overflow, O.decodeAll(&doubled, gpa));
    try testing.expectError(error.Overflow, RleOption(i64).decodeAll(&doubled, gpa));

    // A single run of maxInt(u64) does fit a usize, so it is the allocation
    // that refuses it.
    const one = [_]u8{0x00} ++ huge;
    try testing.expectError(error.OutOfMemory, O.decodeAll(&one, gpa));
    try testing.expectError(error.OutOfMemory, RleOption(i64).decodeAll(&one, gpa));

    // A repeat run is refused the same way, and by the same check: build the
    // header rather than hand-writing it.
    var repeat: [16]u8 = undefined;
    var rn = leb128.writeSigned(&repeat, 1 << 40);
    rn += leb128.writeUnsigned(repeat[rn..], 0);
    try testing.expectError(error.OutOfMemory, Rle(u64).decodeAll(repeat[0..rn], gpa));
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
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();

    var bytes: [48]u8 = undefined;
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        const len = random.uintLessThan(usize, bytes.len + 1);
        for (bytes[0..len]) |*b| b.* = random.int(u8);
        // Every entry point answers with an error or a result, never a panic,
        // whatever the bytes are.
        U.canonical(bytes[0..len]) catch {};
        O.canonical(bytes[0..len]) catch {};
        _ = U.Decoder.init(bytes[0..len]) catch continue;
        _ = O.Decoder.init(bytes[0..len]) catch continue;
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
