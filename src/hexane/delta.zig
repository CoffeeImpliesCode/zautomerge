//! Delta encoding: a column stored as successive differences.
//!
//! The first value is stored absolutely, every later one as the
//! difference from the last non-null realized value. A null stores a
//! null and leaves the running value where it is, so the first non-null
//! after a run of nulls is measured from the *last non-null*, not from
//! the null (upstream `deltas_from`, `delta/mod.rs:2017-2029`, and
//! `DeltaEncoderState::append_n`, `delta/mod.rs:428-443`).
//!
//! The storage is literally an RLE column of `i64` deltas — of
//! `Option<i64>` deltas when the column is nullable
//! (`delta/mod.rs:19-26`) — so the wire format is the RLE slab format
//! with signed LEB128 payloads, plus null runs. A non-nullable column
//! is one that never holds a null and rejects one on decode.
//!
//! # Run-header convention
//!
//! A slab is a flat sequence of runs: no count, no length prefix, no
//! header of any kind (`rle/mod.rs:24-32`).
//!
//! | Run     | Header          | Payload                  |
//! |---------|-----------------|--------------------------|
//! | repeat  | `signed(count)` | one delta, `count >= 2`  |
//! | literal | `signed(-n)`    | `n` distinct deltas      |
//! | null    | `signed(0)`     | one `unsigned(count)`    |
//!
//! Deltas are signed LEB128. A run of one is never a repeat run: it goes
//! out as a one-element literal run (`rle/state.rs:682-693`). A literal
//! run holds no two equal deltas in a row and does not end with a delta
//! the next segment repeats, which is what decides the split when a
//! delta both differs from its predecessor and equals its successor
//! (`rle/state.rs:376-396`): `[1, 2, 2, 1]` is `repeat(1, 2)` followed
//! by `literal(1, 0, -1)`, not `literal(1, 2)` followed by the rest.
//!
//! # The value domain
//!
//! Every realized value has to fit a 2^63-wide window. That is the wire
//! format's closure boundary rather than an accumulator limit: deltas
//! are `i64`, and deleting a row makes its two neighbours adjacent, so
//! *any* pair of rows in a column may end up needing their difference
//! encoded (`delta/mod.rs:75-89`). An edit or a decode that would leave
//! the window is rejected with `error.Overflow` — never wrapped — so
//! the bytes a column can hold are exactly the bytes it can produce.
//!
//! # The local slab codec
//!
//! The RLE codec itself lives in `rle.zig`, whose `write` takes a
//! materialised value slice. The delta transform has no such slice: its
//! input is realized values and its output is a delta stream, so sizing
//! and writing would need a scratch buffer and `encodedSize` could not
//! stay allocation-free. The segment splitter below therefore walks the
//! value sequence directly, following the run-header convention above.
//! It is exercised against `rle.Rle` by the interop test at the bottom
//! of the file, and it is the piece to delete in favour of `rle.zig`.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const err = @import("../error.zig");

const ParseError = err.ParseError;

/// The stored type of a delta column: one difference per row, and a null
/// for a null row. The difference is `i64` whether or not the column is
/// nullable (`delta/mod.rs:19-26`).
pub const Stored = ?i64;

/// The value type behind a nullable column type.
fn payloadOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// Whether `T` is a nullable column type.
fn isNullable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

/// The realized-value domain of a column type, as `i64`. See the module
/// comment: this is where the wire format closes.
fn domainOf(comptime T: type) struct { min: i64, max: i64 } {
    return switch (T) {
        u32 => .{ .min = 0, .max = std.math.maxInt(u32) },
        u64 => .{ .min = 0, .max = std.math.maxInt(i64) },
        i32 => .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32) },
        i64 => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
        else => @compileError("a delta column holds u32, u64, i32, i64, or an optional of one"),
    };
}

/// `a - b`, or `error.Overflow` when the difference does not fit an
/// `i64`: a payload the wire format cannot carry.
fn subI64(a: i64, b: i64) ParseError!i64 {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return error.Overflow;
    return r[0];
}

/// `a + b`, or `error.Overflow` when the sum leaves the `i64` the
/// deltas are accumulated in. Hostile bytes can steer a wrap back into
/// a plausible-looking range, so the running sum is checked rather than
/// allowed to wrap (`delta/indexed.rs:65-89`).
fn addI64(a: i64, b: i64) ParseError!i64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.Overflow;
    return r[0];
}

/// One wire segment: `count` copies of `value`, `count` distinct deltas,
/// or `count` nulls.
const Run = union(enum) {
    /// `count` equal deltas. Always two or more.
    repeat: struct { count: usize, value: i64 },
    /// `count` deltas, all different from the delta beside them. The
    /// values themselves are still in the splitter's lookahead.
    literal: struct { count: usize },
    /// `count` nulls.
    null: struct { count: usize },
};

/// Where a slab is written. `out` is null while the slab is only being
/// measured, which is how `encodedSize` and `write` share one code path
/// and can never disagree about how many bytes a slab takes.
const Sink = struct {
    out: ?[]u8,
    /// Bytes written, or counted.
    n: usize = 0,

    fn byte(self: *Sink, b: u8) void {
        if (self.out) |o| o[self.n] = b;
        self.n += 1;
    }

    fn signed(self: *Sink, v: i64) void {
        var buf: [leb128.max_signed_size]u8 = undefined;
        for (buf[0..leb128.writeSigned(&buf, v)]) |b| self.byte(b);
    }

    fn unsigned(self: *Sink, v: u64) void {
        var buf: [leb128.max_unsigned_size]u8 = undefined;
        for (buf[0..leb128.writeUnsigned(&buf, v)]) |b| self.byte(b);
    }
};

/// A cursor over the runs of a slab in the wire format.
const Slab = struct {
    bytes: []const u8,
    /// The offset of the next unread byte.
    pos: usize = 0,
    /// Rows left in the current run.
    left: usize = 0,
    /// The delta every row of the current run carries. Unused by a
    /// literal run, which reads one varint per row.
    delta: i64 = 0,
    /// Whether the current run is a literal.
    literal: bool = false,

    /// The next delta, or null at the end of the slab. A malformed run
    /// part-way through is reported here, never swallowed.
    fn next(self: *Slab) ParseError!?Stored {
        while (self.left == 0) {
            if (self.pos >= self.bytes.len) return null;
            const header = try leb128.readSigned(self.bytes[self.pos..]);
            self.pos += header.len;
            if (header.value < 0) {
                // A literal run. `-minInt` is the one header that has no
                // positive counterpart, so it is not a count.
                const n = std.math.cast(usize, 0 -% header.value) orelse return error.TooLarge;
                self.left = n;
                self.literal = true;
            } else if (header.value > 0) {
                // A repeat run. One of them is written as a literal run
                // instead, so a count of one is not canonical
                // (`rle/load.rs:19-63`).
                if (header.value == 1) return error.InvalidValue;
                self.left = std.math.cast(usize, header.value) orelse return error.TooLarge;
                const value = try leb128.readSigned(self.bytes[self.pos..]);
                self.pos += value.len;
                self.delta = value.value;
                self.literal = false;
            } else {
                // A null run. A count of zero would be two null runs
                // that should have been merged.
                const count = try leb128.readUnsigned(self.bytes[self.pos..]);
                self.pos += count.len;
                if (count.value == 0) return error.InvalidValue;
                self.left = std.math.cast(usize, count.value) orelse return error.TooLarge;
                self.literal = false;
            }
        }
        self.left -= 1;
        if (self.literal) {
            const value = try leb128.readSigned(self.bytes[self.pos..]);
            self.pos += value.len;
            return value.value;
        }
        return self.delta;
    }
};

// ── Delta ────────────────────────────────────────────────────────────────────

/// The delta codec for a column of `T`. `T` is `u32`, `u64`, `i32`,
/// `i64`, or an optional of one; anything else is a compile error.
pub fn Delta(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The column's value type.
        pub const Value = T;
        /// Whether the column can hold nulls.
        pub const nullable = isNullable(T);
        /// The realized-value domain, as `i64`. A loader validates every
        /// slab's realized values against these (`delta/mod.rs:99-100`).
        pub const min_i64: i64 = domainOf(payloadOf(T)).min;
        pub const max_i64: i64 = domainOf(payloadOf(T)).max;

        const Payload = payloadOf(T);

        /// A column value as a realized `i64`, or null for a null row.
        /// A value outside the domain is `error.Overflow`.
        fn toStored(value: T) ParseError!Stored {
            if (comptime nullable) {
                const v = value orelse return null;
                return widen(v);
            } else {
                return widen(value);
            }
        }

        fn widen(value: Payload) ParseError!i64 {
            const wide: i128 = value;
            if (wide < min_i64 or wide > max_i64) return error.Overflow;
            return @intCast(value);
        }

        /// The column value a realized `i64` stands for. `delta` is the
        /// stored difference; a null leaves the running value alone.
        fn realize(running: i64, delta: Stored) ParseError!T {
            if (delta) |_| {
                const wide: i128 = running;
                if (wide < min_i64 or wide > max_i64) return error.Overflow;
                const p: Payload = @intCast(running);
                return p;
            } else {
                // A non-nullable column rejects nulls at decode
                // (`rle/decoder.rs:487-489`); its encoder never writes
                // one, so the branch is dead for it.
                if (comptime nullable) return null;
                return error.UnexpectedNull;
            }
        }

        // ── the transform ──

        /// The delta sequence `values` stands for. The caller owns the
        /// result.
        pub fn toDeltas(gpa: std.mem.Allocator, values: []const T) ParseError![]Stored {
            const out = try gpa.alloc(Stored, values.len);
            errdefer gpa.free(out);
            var source = Source.fromValues(values);
            for (out) |*d| d.* = (try source.next()).?;
            return out;
        }

        /// Appends the delta of every value in `values` to `out`.
        pub fn appendDeltas(out: *std.ArrayList(Stored), gpa: std.mem.Allocator, values: []const T) ParseError!void {
            try out.ensureUnusedCapacity(gpa, values.len);
            var source = Source.fromValues(values);
            while (try source.next()) |d| try out.appendAssumeCapacity(d);
        }

        /// The values a delta sequence stands for. The caller owns the
        /// result. A realized value outside the domain is
        /// `error.Overflow`.
        pub fn fromDeltas(gpa: std.mem.Allocator, deltas: []const Stored) ParseError![]T {
            const out = try gpa.alloc(T, deltas.len);
            errdefer gpa.free(out);
            var running: i64 = 0;
            for (out, deltas) |*v, d| {
                if (d) |dv| running = try addI64(running, dv);
                v.* = try realize(running, d);
            }
            return out;
        }

        /// The realized value standing before row `index` — the anchor
        /// the delta at `index` is measured from.
        pub fn runningAt(deltas: []const Stored, index: usize) ParseError!i64 {
            const end = @min(index, deltas.len);
            var running: i64 = 0;
            for (deltas[0..end]) |d| {
                if (d) |dv| running = try addI64(running, dv);
            }
            return running;
        }

        // ── wire format ──

        /// The number of bytes `write` emits for `values`.
        ///
        /// A value outside the domain is a precondition violation and
        /// panics, as upstream's unsigned `to_i64` does on a write path
        /// (`delta/mod.rs:167-172`). Use `append` to be told instead.
        pub fn encodedSize(values: []const T) usize {
            return slabSize(Source.fromValues(values)) catch
                @panic("Delta.encodedSize: a value is outside the column's delta domain");
        }

        /// Writes `values` into `out`, which must hold `encodedSize`
        /// bytes. Panics on a value outside the domain, as
        /// `encodedSize` does.
        pub fn write(out: []u8, values: []const T) void {
            _ = writeSlab(out, Source.fromValues(values)) catch
                @panic("Delta.write: a value is outside the column's delta domain");
        }

        /// Appends the encoding of `values` to `list`. A value outside
        /// the domain is `error.Overflow`.
        pub fn append(list: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const T) ParseError!void {
            const n = try slabSize(Source.fromValues(values));
            try list.ensureUnusedCapacity(gpa, n);
            const start = list.items.len;
            list.items.len = start + n;
            errdefer list.items.len = start;
            _ = try writeSlab(list.items[start..], Source.fromValues(values));
        }

        /// Every value in a slab, in realized form. The caller owns the
        /// result.
        pub fn decodeAll(bytes: []const u8, gpa: std.mem.Allocator) ParseError![]T {
            // Two passes: the first counts the rows so the allocation is
            // made once, and it reads the same headers the second does,
            // so a malformed slab is rejected before any memory moves.
            const total = try countRows(bytes);
            const out = try gpa.alloc(T, total);
            errdefer gpa.free(out);
            var slab = Slab{ .bytes = bytes };
            var running: i64 = 0;
            for (out) |*v| {
                const d = (try slab.next()).?;
                if (d) |dv| running = try addI64(running, dv);
                v.* = try realize(running, d);
            }
            return out;
        }

        /// A cursor over a slab that yields values one at a time.
        pub const Decoder = struct {
            slab: Slab,
            /// The realized value standing before the next row.
            running: i64,

            /// A cursor standing at the start of `bytes`. Construction
            /// cannot fail: a malformed run is reported by `next`.
            pub fn init(bytes: []const u8) ParseError!Decoder {
                return .{ .slab = .{ .bytes = bytes }, .running = 0 };
            }

            /// The next value, null at the end of the slab.
            pub fn next(self: *Decoder) ParseError!?T {
                const d = (try self.slab.next()) orelse return null;
                if (d) |dv| self.running = try addI64(self.running, dv);
                return try realize(self.running, d);
            }
        };

        // ── editing ──

        /// A cursor over one slab of a delta column, in realized values.
        ///
        /// The storage underneath is a sequence of deltas, so this is
        /// that sequence plus two accumulators: `running`, the realized
        /// value standing before the cursor, and `adjust`, what the next
        /// non-null delta owes (`delta/mod.rs:1143-1148`). Writing a
        /// value in the middle of a slab changes that row's delta and
        /// leaves every later delta measured from the value that was
        /// there before, so the difference becomes a debt: a null holds
        /// no delta, so nulls carry through it and it lands on the first
        /// non-null after them (`delta/mod.rs:1384-1400`).
        pub const Editor = struct {
            const Self = @This();

            gpa: std.mem.Allocator,
            /// The slab's deltas, one per row.
            deltas: std.ArrayList(Stored),
            /// The number of rows the cursor has passed.
            pos: usize,
            /// The realized value standing before row `pos`.
            running: i64,
            /// What the next non-null delta owes.
            adjust: i64,

            /// An empty slab.
            pub fn init(gpa: std.mem.Allocator) Self {
                return .{ .gpa = gpa, .deltas = .empty, .pos = 0, .running = 0, .adjust = 0 };
            }

            /// An editor over the rows in `values`.
            pub fn fromValues(gpa: std.mem.Allocator, values: []const T) ParseError!Self {
                var self = Self.init(gpa);
                errdefer self.deinit();
                try self.deltas.ensureTotalCapacity(gpa, values.len);
                var source = Source.fromValues(values);
                while (try source.next()) |d| try self.deltas.appendAssumeCapacity(d);
                return self;
            }

            /// An editor over the rows a slab decodes to. The deltas are
            /// re-derived from the realized values, which is exact for
            /// the rows, and leaves the slab canonically encoded.
            pub fn load(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Self {
                const values = try decodeAll(bytes, gpa);
                defer gpa.free(values);
                return fromValues(gpa, values);
            }

            /// Frees the slab.
            pub fn deinit(self: *Self) void {
                self.deltas.deinit(self.gpa);
            }

            /// The number of rows in the slab.
            pub fn len(self: *const Self) usize {
                return self.deltas.items.len;
            }

            /// The slab's delta sequence.
            pub fn deltasSlice(self: *const Self) []const Stored {
                return self.deltas.items;
            }

            /// The delta stored for row `index`, null when `index` is
            /// past the end of the slab.
            pub fn deltaAt(self: *const Self, index: usize) ?Stored {
                if (index >= self.deltas.items.len) return null;
                return self.deltas.items[index];
            }

            /// The realized value standing before row `index` — the
            /// anchor the delta at `index` is measured from.
            pub fn runningAt(self: *const Self, index: usize) ParseError!i64 {
                return runningAt(self.deltas.items, index);
            }

            /// The realized value of row `index`, or `error.Overflow`
            /// when the running sum leaves the column's domain.
            pub fn valueAt(self: *const Self, index: usize) ParseError!T {
                if (index >= self.deltas.items.len) return error.ColumnOutOfBounds;
                var running = try self.runningAt(index);
                const d = self.deltas.items[index];
                if (d) |dv| running = try addI64(running, dv);
                return try realize(running, d);
            }

            /// The pending fix-up, in delta units: what the next non-null
            /// delta still owes. Zero when the slab is settled.
            pub fn pendingAdjust(self: *const Self) i64 {
                return self.adjust;
            }

            /// Moves the cursor forward to row `to`, carrying every row
            /// in between through unchanged and paying the fix-up on the
            /// way. A `to` at or before the cursor does nothing, as
            /// upstream's saturating seek does (`delta/mod.rs:1207`).
            pub fn seek(self: *Self, to: usize) ParseError!void {
                const target = @min(to, self.deltas.items.len);
                while (self.pos < target) {
                    const step = self.deltas.items[self.pos];
                    if (step) |dv| {
                        // The fix-up lands on the first non-null row
                        // carried across, so it is paid out of this move
                        // and not before it (`delta/mod.rs:1214-1220`).
                        const paid = if (self.adjust != 0)
                            try addI64(dv, self.adjust)
                        else
                            dv;
                        const next = try addI64(self.running, paid);
                        self.deltas.items[self.pos] = paid;
                        self.running = next;
                        self.adjust = 0;
                    }
                    // A null holds no delta: carry it and keep looking.
                    self.pos += 1;
                }
            }

            /// Appends one realized value at the end of the slab.
            pub fn append(self: *Self, value: T) ParseError!void {
                try self.seek(self.deltas.items.len);
                // Nothing follows the cursor, so a fix-up still open has
                // nothing to land on and is dropped (`delta/mod.rs:1386-1389`).
                self.adjust = 0;
                const realized = try toStored(value);
                if (realized) |v| {
                    const d = try subI64(v, self.running);
                    try self.deltas.append(self.gpa, d);
                    self.running = v;
                } else {
                    try self.deltas.append(self.gpa, null);
                }
                self.pos = self.deltas.items.len;
            }

            /// Replaces the value of row `index`, leaving every other row
            /// of the slab as it was. The fix-up lands on the next
            /// non-null row: call `settle`, or let `seek` pay it, before
            /// reading the slab back.
            pub fn replace(self: *Self, index: usize, value: T) ParseError!void {
                if (index >= self.deltas.items.len) return error.ColumnOutOfBounds;
                try self.seek(index);
                const old = self.deltas.items[index];
                const realized = try toStored(value);
                if (realized) |v| {
                    const d = try subI64(v, self.running);
                    // The debt is the delta the row used to hold plus the
                    // one it holds now: deleting the row and inserting
                    // `value` in its place is what upstream's cursor
                    // does (`delta/mod.rs:1337-1357`).
                    const debt = try subI64(old orelse 0, d);
                    self.deltas.items[index] = d;
                    self.running = v;
                    self.adjust = try addI64(self.adjust, debt);
                } else {
                    self.deltas.items[index] = null;
                    self.adjust = try addI64(self.adjust, old orelse 0);
                }
                self.pos = index + 1;
            }

            /// Pays the pending fix-up into the next non-null delta, so
            /// every realized value after the cursor is what it was.
            /// Idempotent, and a no-op when nothing follows the cursor.
            pub fn settle(self: *Self) ParseError!void {
                while (self.adjust != 0) {
                    if (self.pos >= self.deltas.items.len) {
                        // Nothing follows, so nothing decodes against
                        // the cursor.
                        self.adjust = 0;
                        return;
                    }
                    const d = self.deltas.items[self.pos];
                    if (d) |dv| {
                        const paid = try addI64(dv, self.adjust);
                        const next = try addI64(self.running, paid);
                        self.deltas.items[self.pos] = paid;
                        self.running = next;
                        self.adjust = 0;
                    }
                    // A null holds no delta: carry it and keep looking.
                    self.pos += 1;
                }
            }

            /// The realized value of every row. The caller owns the
            /// result. Requires a settled editor.
            pub fn values(self: *const Self, gpa: std.mem.Allocator) ParseError![]T {
                return fromDeltas(gpa, self.deltas.items);
            }

            /// The number of bytes the slab's encoding takes.
            pub fn encodedSize(self: *const Self) usize {
                return slabSize(Source.fromDeltas(self.deltas.items));
            }

            /// Writes the slab's bytes into `out`, which must hold
            /// `encodedSize` bytes. Requires a settled editor.
            pub fn write(self: *const Self, out: []u8) void {
                _ = writeSlab(out, Source.fromDeltas(self.deltas.items)) catch unreachable;
            }
        };

        // ── the delta stream a slab is cut from ──

        /// Either the values a caller hands the codec, transformed as
        /// they stream out, or a delta sequence that is already
        /// materialised.
        const Source = struct {
            mode: enum { values, deltas },
            values: []const T,
            deltas: []const Stored,
            pos: usize = 0,
            /// The realized value the next delta is measured from.
            running: i64 = 0,

            fn fromValues(values: []const T) Source {
                return .{ .mode = .values, .values = values, .deltas = &.{} };
            }

            fn fromDeltas(deltas: []const Stored) Source {
                return .{ .mode = .deltas, .values = &.{}, .deltas = deltas };
            }

            /// The next delta, or null once the sequence is exhausted.
            fn next(self: *Source) ParseError!?Stored {
                switch (self.mode) {
                    .values => {
                        if (self.pos >= self.values.len) return null;
                        const value = self.values[self.pos];
                        self.pos += 1;
                        const realized = try toStored(value);
                        // A null holds no delta and leaves the running
                        // value alone (`delta/mod.rs:441-443`).
                        const v = realized orelse return null;
                        const d = try subI64(v, self.running);
                        self.running = v;
                        return d;
                    },
                    .deltas => {
                        if (self.pos >= self.deltas.len) return null;
                        const d = self.deltas[self.pos];
                        self.pos += 1;
                        return d;
                    },
                }
            }
        };

        /// Splits a delta stream into the segments a slab is made of.
        const RunIter = struct {
            source: Source,
            /// Deltas read but not yet placed: the head of the run being
            /// built plus the one after it. A literal run may not end
            /// with a delta the next segment repeats, so placing one
            /// means looking at what follows it.
            look: [2]Stored = .{ null, null },
            /// How many slots of `look` hold a delta.
            filled: usize = 0,

            fn init(source: Source) RunIter {
                return .{ .source = source };
            }

            /// The delta `n` places after the next one, reading forward
            /// as needed. The outer null is the end of the stream.
            fn peekAt(self: *RunIter, n: usize) ParseError!?Stored {
                while (self.filled <= n) {
                    const d = (try self.source.next()) orelse return null;
                    self.look[self.filled] = d;
                    self.filled += 1;
                }
                return self.look[n];
            }

            /// Consumes the first `n` deltas of the lookahead.
            fn take(self: *RunIter, n: usize) void {
                std.debug.assert(n <= self.filled and n <= self.look.len);
                var i: usize = 0;
                while (i < n) : (i += 1) self.look[i] = self.look[i + n];
                self.filled -= n;
            }

            /// Whether the delta in front of `d` repeats it, so a
            /// literal run has to stop before `d`.
            fn startsRepeat(self: *RunIter, d: i64) ParseError!bool {
                const after = (try self.peekAt(1)) orelse return false;
                if (after == null) return false;
                return after.? == d;
            }

            /// The next segment, or null once the stream is exhausted.
            fn next(self: *RunIter) ParseError!?Run {
                const head = (try self.peekAt(0)) orelse return null;
                self.take(1);
                if (head == null) {
                    // A null run is every null in a row and nothing else
                    // (`rle/state.rs:578-590`).
                    var count: usize = 1;
                    while (try self.peekAt(0)) |d| {
                        if (d != null) break;
                        self.take(1);
                        count += 1;
                    }
                    return .{ .null = .{ .count = count } };
                }
                const outer = try self.peekAt(0);
                // Nothing follows the head, or a null run starts: it
                // stands alone as a one-element literal run.
                if (outer == null or outer.? == null) return .{ .literal = .{ .count = 1 } };
                const next = outer.?;
                if (next.? == head.?) {
                    // A repeat run: every delta equal to the head, and at
                    // least two of them.
                    var count: usize = 2;
                    while (try self.peekAt(0)) |d| {
                        if (d == null or d.? != head.?) break;
                        self.take(1);
                        count += 1;
                    }
                    return .{ .repeat = .{ .count = count, .value = head.? } };
                }
                // A literal run. It may not hold two equal deltas in a
                // row, and it may not end with a delta the next segment
                // repeats, so the delta after the one being placed has
                // to be looked at (`rle/state.rs:376-396`).
                if (try self.startsRepeat(next.?)) return .{ .literal = .{ .count = 1 } };
                self.take(1);
                var count: usize = 2;
                var last = next.?;
                while (true) {
                    const candidate = (try self.peekAt(0)) orelse break;
                    if (candidate.? == null) break;
                    if (candidate.? == last or try self.startsRepeat(candidate.?)) break;
                    self.take(1);
                    count += 1;
                    last = candidate.?;
                }
                return .{ .literal = .{ .count = count } };
            }

            /// Writes `run` into `sink`, taking a literal run's values
            /// from the lookahead.
            fn emit(self: *RunIter, run: Run, sink: *Sink) ParseError!void {
                switch (run) {
                    .repeat => |r| {
                        sink.signed(@intCast(r.count));
                        sink.signed(r.value);
                    },
                    .literal => |l| {
                        sink.signed(-@as(i64, @intCast(l.count)));
                        for (0..l.count) |_| {
                            // A literal run holds no nulls by
                            // construction: the run above stops at one.
                            const d = (try self.peekAt(0)).?;
                            self.take(1);
                            sink.signed(d.?);
                        }
                    },
                    .null => |n| {
                        sink.signed(0);
                        sink.unsigned(@intCast(n.count));
                    },
                }
            }

            /// Writes every remaining segment into `sink`.
            fn emitAll(self: *RunIter, sink: *Sink) ParseError!void {
                while (try self.next()) |run| try self.emit(run, sink);
            }
        };

        /// The number of bytes the slab cut from `source` takes.
        fn slabSize(source: Source) ParseError!usize {
            var sink = Sink{ .out = null };
            var runs = RunIter.init(source);
            try runs.emitAll(&sink);
            return sink.n;
        }

        /// Writes the slab cut from `source` into `out`, returning the
        /// number of bytes written.
        fn writeSlab(out: []u8, source: Source) ParseError!usize {
            var sink = Sink{ .out = out };
            var runs = RunIter.init(source);
            try runs.emitAll(&sink);
            return sink.n;
        }
    };
}

/// The nullable delta column, the shape the op set's `key_ctr` column
/// stores (`op_set2/columns.rs:25-35`). `Delta(?u32)`, spelled as a
/// struct because that is the name the column code reaches for.
pub const DeltaOption = Delta(?u32);

/// The number of rows in `bytes`.
fn countRows(bytes: []const u8) ParseError!usize {
    var slab = Slab{ .bytes = bytes };
    var total: usize = 0;
    while (try slab.next()) |_| {
        total = std.math.add(usize, total, 1) catch return error.Overflow;
    }
    return total;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Encodes `values`, checks the bytes, and reads them back through every
/// entry point.
fn expectColumn(comptime D: type, values: []const D.Value, bytes: []const u8) !void {
    const gpa = testing.allocator;
    try testing.expectEqual(bytes.len, D.encodedSize(values));

    const buf = try gpa.alloc(u8, D.encodedSize(values));
    defer gpa.free(buf);
    D.write(buf, values);
    try testing.expectEqualSlices(u8, bytes, buf);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try D.append(&list, gpa, values);
    try testing.expectEqualSlices(u8, bytes, list.items);

    const back = try D.decodeAll(bytes, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(D.Value, values, back);

    var dec = try D.Decoder.init(bytes);
    for (values) |v| try testing.expectEqual(v, (try dec.next()).?);
    try testing.expectEqual(@as(?D.Value, null), try dec.next());
}

test "strictly increasing column" {
    const D = Delta(u32);
    var values: [10]u32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i * 3);
    try testing.expectEqualSlices(u32, &.{ 0, 3, 6, 9, 12, 15, 18, 21, 24, 27 }, &values);
    // Every delta is 3, so the whole column is one repeat run.
    try expectColumn(D, &values, &.{ 0x0a, 0x03 });
}

test "strictly decreasing column" {
    const D = Delta(i64);
    // A literal run for the first delta, then a repeat run for the two
    // equal ones: a literal may not end with a delta the next segment
    // repeats.
    try expectColumn(D, &.{ 30, 20, 10 }, &.{ 0x7f, 0x1e, 0x02, 0x76 });
    try expectColumn(D, &.{ 5, 4, 3, 2, 1 }, &.{ 0x7f, 0x05, 0x02, 0x7f, 0x02, 0x03, 0x02, 0x7f });
}

test "a delta that both follows and starts a repeat" {
    const D = Delta(i64);
    // 1, 2, 2, 1 realizes to 1, 2, 2, 1 from deltas 1, 1, 0, -1. The
    // second delta cannot join the literal: the one after it repeats it.
    try expectColumn(D, &.{ 1, 2, 2, 1 }, &.{ 0x02, 0x01, 0x7d, 0x01, 0x00, 0x7f });
    try expectColumn(D, &.{ 5, 7, 7 }, &.{ 0x7f, 0x05, 0x02, 0x02, 0x07 });
}

test "a single value" {
    try expectColumn(Delta(u32), &.{10}, &.{ 0x7f, 0x0a });
    try expectColumn(Delta(i64), &.{-1}, &.{ 0x7f, 0x7f });
    try expectColumn(Delta(u64), &.{std.math.maxInt(i64)}, &.{ 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 });
}

test "an empty column" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    try expectColumn(D, &.{}, &.{});

    const back = try D.decodeAll(&.{}, gpa);
    defer gpa.free(back);
    try testing.expectEqual(@as(usize, 0), back.len);

    var ed = D.Editor.init(gpa);
    defer ed.deinit();
    try testing.expectEqual(@as(usize, 0), ed.encodedSize());
    try testing.expectError(error.ColumnOutOfBounds, ed.valueAt(0));
}

test "a nullable column with nulls" {
    const D = DeltaOption;
    // The null holds no delta: 5 after it is measured from the last
    // non-null, which is 1, not from the null.
    try expectColumn(D, &.{ 1, null, 5, 5, null }, &.{ 0x7f, 0x01, 0x00, 0x01, 0x7f, 0x04, 0x02, 0x05, 0x00, 0x01 });
    try expectColumn(D, &.{ null, null, null }, &.{ 0x00, 0x03 });
    try expectColumn(D, &.{ null, 1, 2, null, null }, &.{ 0x00, 0x02, 0x7f, 0x01, 0x7f, 0x02, 0x00, 0x02 });
    try expectColumn(D, &.{null}, &.{ 0x00, 0x01 });
}

test "a null in a non-nullable column is rejected" {
    const gpa = testing.allocator;
    // One null row, then nothing.
    try testing.expectError(error.UnexpectedNull, Delta(u32).decodeAll(&.{ 0x00, 0x01 }, gpa));
    try testing.expectError(error.UnexpectedNull, Delta(i64).decodeAll(&.{ 0x00, 0x01 }, gpa));
}

test "the deltas a column stores" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    const deltas = try D.toDeltas(gpa, &.{ 10, 20, 30 });
    defer gpa.free(deltas);
    try testing.expectEqualSlices(?i64, &.{ 10, 10, 10 }, deltas);
    try testing.expectEqual(@as(i64, 20), try D.runningAt(deltas, 2));

    const back = try D.fromDeltas(gpa, deltas);
    defer gpa.free(back);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, back);
}

test "a value outside the domain is rejected, not wrapped" {
    const gpa = testing.allocator;
    // u64 rows have to fit a 2^63-wide window, so the top half of the
    // type is not storable at all.
    try testing.expectError(error.Overflow, Delta(u64).toDeltas(gpa, &.{std.math.maxInt(i64) + 1}));
    try testing.expectError(error.Overflow, Delta(u64).toDeltas(gpa, &.{ 0, std.math.maxInt(i64) + 1 }));
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try testing.expectError(error.Overflow, Delta(u64).append(&list, gpa, &.{std.math.maxInt(i64) + 1}));

    // A deletion can put any two rows next to each other, so the
    // difference between them has to fit an i64 as well.
    try testing.expectError(
        error.Overflow,
        Delta(i64).toDeltas(gpa, &.{ std.math.minInt(i64), std.math.maxInt(i64) }),
    );
    // A realized value outside the column's own range is rejected on
    // the way out, too.
    try testing.expectError(
        error.Overflow,
        Delta(i64).toDeltas(gpa, &.{ std.math.maxInt(i64), std.math.maxInt(i64) }),
    ) catch |e| switch (e) {
        // maxInt - maxInt is zero: the deltas fit, and so does the column.
        error.Overflow => unreachable,
        else => return e,
    };
}

test "hostile deltas are rejected, not wrapped" {
    const gpa = testing.allocator;
    // A delta of -1 realizes outside u32.
    try testing.expectError(error.Overflow, Delta(u32).decodeAll(&.{ 0x7e, 0x00, 0x7f }, gpa));
    // A running sum that leaves i64: the second value would be
    // maxInt + 1.
    var repeat: [2 + leb128.max_signed_size]u8 = undefined;
    var n = leb128.writeSigned(&repeat, 2);
    n += leb128.writeSigned(repeat[n..], std.math.maxInt(i64));
    try testing.expectError(error.Overflow, Delta(i64).decodeAll(repeat[0..n], gpa));
    try testing.expectError(error.Overflow, Delta(i64).decodeAll(repeat[0..n], gpa).?);
}

test "a malformed slab is rejected" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    // A repeat run of one is written as a literal run instead.
    try testing.expectError(error.InvalidValue, D.decodeAll(&.{ 0x01, 0x0a }, gpa));
    // A null run of zero is two null runs that should have merged.
    try testing.expectError(error.InvalidValue, D.decodeAll(&.{ 0x00, 0x00 }, gpa));
    // A literal run that runs off the end of the slab.
    try testing.expectError(error.UnexpectedEnd, D.decodeAll(&.{ 0x7e, 0x01 }, gpa));
    // A header with no payload behind it.
    try testing.expectError(error.UnexpectedEnd, D.decodeAll(&.{ 0x02 }, gpa));
    // A header with no count behind it.
    try testing.expectError(error.UnexpectedEnd, D.decodeAll(&.{ 0x00 }, gpa));
}

test "editing a row in the middle leaves the other rows alone" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    var ed = try D.Editor.fromValues(gpa, &.{ 10, 20, 30, 40 });
    defer ed.deinit();

    // The slab is one repeat run of four deltas of ten.
    try testing.expectEqualSlices(?i64, &.{ 10, 10, 10, 10 }, ed.deltasSlice());

    try ed.replace(1, 25);
    // The row's own delta moved from 10 to 15, and the next non-null
    // row owes the five it lost.
    try testing.expectEqual(@as(i64, -5), ed.pendingAdjust());
    try testing.expectEqual(@as(usize, 2), ed.pos);
    try testing.expectEqual(@as(i64, 25), ed.running);

    ed.settle();
    try testing.expectEqual(@as(i64, 0), ed.pendingAdjust());
    try testing.expectEqualSlices(?i64, &.{ 10, 15, 5, 10 }, ed.deltasSlice());

    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(u32, &.{ 10, 25, 30, 40 }, values);
    try testing.expectEqual(@as(u32, 25), try ed.valueAt(1));
    try testing.expectEqual(@as(u32, 40), try ed.valueAt(3));

    // The edited slab encodes exactly as a fresh column of the same rows
    // does.
    const expected = try D.toDeltas(gpa, &.{ 10, 25, 30, 40 });
    defer gpa.free(expected);
    try testing.expectEqualSlices(?i64, expected, ed.deltasSlice());
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try ed.settle();
    try ed.write(try list.appendSlice(gpa, &.{}) catch unreachable, &.{});
}

test "an edited slab decodes to the edited rows" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    var ed = try D.Editor.fromValues(gpa, &.{ 10, 20, 30, 40, 50 });
    defer ed.deinit();
    try ed.replace(2, 1);
    try ed.settle();
    try ed.append(25);

    const expected: [6]u32 = .{ 10, 20, 1, 40, 50, 25 };
    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(u32, &expected, values);

    const bytes = try gpa.alloc(u8, ed.encodedSize());
    defer gpa.free(bytes);
    ed.write(bytes);

    const back = try D.decodeAll(bytes, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(u32, &expected, back);
    // And a fresh column of the same rows is byte for byte the same
    // slab.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try D.append(&list, gpa, &expected);
    try testing.expectEqualSlices(u8, list.items, bytes);
}

test "a fix-up skips the nulls in front of it" {
    const gpa = testing.allocator;
    const D = DeltaOption;
    // Rows 1 and 2 are null, so the debt lands on row 3.
    var ed = try D.Editor.fromValues(gpa, &.{ 1, null, null, 20, 30 });
    defer ed.deinit();
    try testing.expectEqualSlices(?i64, &.{ 1, null, null, 19, 10 }, ed.deltasSlice());

    try ed.replace(0, 2);
    try testing.expectEqual(@as(i64, -1), ed.pendingAdjust());
    ed.settle();
    try testing.expectEqual(@as(i64, 0), ed.pendingAdjust());
    try testing.expectEqualSlices(?i64, &.{ 2, null, null, 18, 10 }, ed.deltasSlice());

    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(?u32, &.{ 2, null, null, 20, 30 }, values);
}

test "replacing a row with a null and back" {
    const gpa = testing.allocator;
    const D = DeltaOption;
    var ed = try D.Editor.fromValues(gpa, &.{ 1, 2, 3, 4 });
    defer ed.deinit();

    try ed.replace(1, null);
    ed.settle();
    const with_null = try ed.values(gpa);
    defer gpa.free(with_null);
    try testing.expectEqualSlices(?u32, &.{ 1, null, 3, 4 }, with_null);

    try ed.replace(1, 2);
    ed.settle();
    const back = try ed.values(gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(?u32, &.{ 1, 2, 3, 4 }, back);
    try testing.expectEqualSlices(?i64, &.{ 1, 1, 1, 1 }, ed.deltasSlice());
}

test "a fix-up with nothing after it is dropped" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    var ed = try D.Editor.fromValues(gpa, &.{ 10, 20, 30 });
    defer ed.deinit();
    try ed.replace(2, 300);
    // Nothing decodes against the last row, so the debt has nowhere to
    // land and is dropped.
    try testing.expectEqual(@as(i64, 0), ed.pendingAdjust());
    ed.settle();
    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 300 }, values);
}

test "seeking pays the fix-up on the way" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    var ed = try D.Editor.fromValues(gpa, &.{ 10, 20, 30, 40 });
    defer ed.deinit();
    try ed.replace(0, 5);
    try testing.expectEqual(@as(i64, 5), ed.pendingAdjust());
    try ed.seek(2);
    try testing.expectEqual(@as(i64, 0), ed.pendingAdjust());
    try testing.expectEqualSlices(?i64, &.{ 5, 15, 5, 10 }, ed.deltasSlice());
    // A seek that does not move is a no-op.
    try ed.seek(1);
    try testing.expectEqual(@as(usize, 2), ed.pos);
    try ed.seek(4);
    try testing.expectEqual(@as(usize, 4), ed.pos);
    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(u32, &.{ 5, 20, 30, 40 }, values);
}

test "an editor rejects an out-of-range row and an unstorable value" {
    const gpa = testing.allocator;
    const D = Delta(u64);
    var ed = try D.Editor.fromValues(gpa, &.{ 1, 2, 3 });
    defer ed.deinit();
    try testing.expectError(error.ColumnOutOfBounds, ed.replace(3, 4));
    try testing.expectError(error.ColumnOutOfBounds, ed.valueAt(3));
    try testing.expectError(error.Overflow, ed.replace(1, std.math.maxInt(i64) + 1));
    // The rejected edit left the slab alone.
    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, values);
}

test "an editor loaded from a slab re-encodes it canonically" {
    const gpa = testing.allocator;
    const D = DeltaOption;
    var ed = try D.Editor.load(gpa, &.{ 0x7f, 0x01, 0x00, 0x02, 0x7f, 0x04 });
    defer ed.deinit();
    // Rows 1, null, null, 5.
    try testing.expectEqualSlices(?i64, &.{ 1, null, null, 4 }, ed.deltasSlice());
    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqualSlices(?u32, &.{ 1, null, null, 5 }, values);
    try testing.expectEqual(@as(u32, 5), (try ed.valueAt(3)).?);
}

test "a long column" {
    const gpa = testing.allocator;
    const D = Delta(u32);
    var values: [1000]u32 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    try expectColumn(D, &values, &.{}); // only the shape is checked here

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try D.append(&list, gpa, &values);
    // Every delta is 1: one repeat run, two bytes.
    try testing.expectEqualSlices(u8, &.{ 0x88, 0x07 }, list.items);
    const back = try D.decodeAll(list.items, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(u32, &values, back);
}

test "an editor grows a slab a row at a time" {
    const gpa = testing.allocator;
    const D = Delta(i64);
    var ed = D.Editor.init(gpa);
    defer ed.deinit();
    var i: i64 = 0;
    while (i < 300) : (i += 1) try ed.append(i * 3);

    const values = try ed.values(gpa);
    defer gpa.free(values);
    try testing.expectEqual(@as(usize, 300), values.len);
    for (values, 0..) |v, k| try testing.expectEqual(@as(i64, @intCast(k)) * 3, v);

    const bytes = try gpa.alloc(u8, ed.encodedSize());
    defer gpa.free(bytes);
    ed.write(bytes);
    const back = try D.decodeAll(bytes, gpa);
    defer gpa.free(back);
    try testing.expectEqualSlices(i64, values, back);
}
