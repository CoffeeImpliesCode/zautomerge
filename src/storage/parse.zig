//! A forward-only cursor over untrusted bytes: the one thing every document
//! format parser in this crate is built from.
//!
//! Upstream is a nom-style combinator library (`storage/parse.rs`, 619 lines)
//! over a moving `Input` window. None of that machinery ports. This crate's
//! parsers are hand-written rather than combinator-composed, so
//! only the cursor and its readers are needed here. What survives the port is
//! the property the whole upstream read path rests on: a stack of decoders
//! that all borrow from one input buffer and allocate nothing.
//!
//! Four rules hold for every reader, and a caller may rely on all of them.
//!
//! * **Forward only.** There is no seek and no reset. A reader either
//!   advances the cursor or returns an error, and a reader that returns an
//!   error leaves the cursor on the value it failed on, so a failed parse can
//!   never be mistaken for a successful one and a caller that recovers is
//!   still positioned at the value it failed on.
//!
//!   [`Input.readCountThen`] is the one reader this rule does not cover, and
//!   it cannot: it has to read a count before it can judge it. A refused
//!   count has already consumed its length prefix, and an error the callback
//!   returns propagates with the cursor wherever that callback left it. A
//!   caller that must go back to the count itself records `pos` before the
//!   call; there is no rewind.
//! * **Borrowed results.** Every slice a reader returns points into the
//!   caller's own buffer. Nothing here allocates and no reader takes an
//!   allocator.
//! * **Two truncation errors, and which is which.** A reader that runs out
//!   of bytes returns `error.UnexpectedEnd`, the port of upstream's
//!   `ParseError::Incomplete` (`parse.rs:349-353`). A reader that finds a
//!   *declared* length larger than the input could possibly hold returns
//!   `error.LengthExceedsInput`, before the length is used to size or index
//!   anything.
//! * **A count is proved against the input before anything is sized from
//!   it.** [`Input.readCountThen`] applies that proof itself: it refuses a
//!   count larger than `remaining() / min_item_size` before the callback
//!   that may allocate ever sees it. Reading a count with
//!   [`Input.takeUleb`] instead is the caller's responsibility, because
//!   `takeUleb` reads a LEB128 field of any width and applies no bound to
//!   one. Neither route is enforced by the type system; a caller that sizes
//!   an allocation from an unbounded count is the defect, not the reader.
//!
//! ## Endianness
//!
//! `takeArray`, `takeU32` and `takeU64` read **big endian**. The document
//! format itself has almost no fixed-width integers — headers, column specs,
//! and lengths are all uleb128 — so this is a convention rather than a
//! compatibility constraint, but it is the one these readers use. The one
//! fixed-width field in the format is a float inside a value stream, and
//! those are **little endian** (`encodable_impls.rs:73-91`); a value decoder
//! must not route them through `takeArray`.

const std = @import("std");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");

const ParseError = err.ParseError;

/// A cursor over a byte slice that can only move forward. Every reader either
/// advances the cursor or fails; a failed parse never leaves the cursor in a
/// state that could be mistaken for a successful read.
///
/// The cursor borrows; it does not own. It holds a slice and an offset, so
/// copying one is free and safe — the copies are independent cursors over the
/// same bytes, and neither has to be released. The buffer it borrows must
/// outlive every slice, cursor and offset taken from it.
///
/// Upstream's `Input<'a>` is `{bytes, position, original}` (`parse.rs:114-118`)
/// and is a plain copy rather than a mutable handle, because every combinator
/// threads the shrunk window through its return value. A hand-written Zig
/// parser threads a `*Input` instead, which is why `pos` lives here and every
/// reader takes `*self`. The third upstream field is gone: a cursor produced
/// by `sub` addresses its own window, so `pos` is always an offset into
/// `bytes` and an offset a parser records is relative to the window it read it
/// from. That is what upstream's `truncate` achieves (`parse.rs:226-237`),
/// reached by construction instead of by a field.
pub const Input = struct {
    /// The whole buffer this cursor walks. Nothing is ever copied out of it.
    bytes: []const u8,
    /// How far into `bytes` the cursor has read. Every method preserves
    /// `pos <= bytes.len`, so `bytes[pos..]` is always valid.
    ///
    /// The field is reachable, so the invariant is the caller's to keep as
    /// well as the methods'. [`Input.rest`] slices with it and
    /// [`Input.remaining`] subtracts with it, neither checked: a value past
    /// `bytes.len` panics in a checked build and is undefined behaviour in
    /// `ReleaseFast`. Move it with the checked reader methods rather than
    /// assigning it directly.
    pos: usize,

    /// A cursor positioned at the start of `bytes`.
    ///
    /// The buffer is borrowed, not copied: `bytes` is stored as given and the
    /// caller keeps it, so mutating it while a cursor is live is the caller's
    /// to avoid.
    pub fn init(bytes: []const u8) Input {
        return .{ .bytes = bytes, .pos = 0 };
    }

    /// The bytes not yet consumed. Upstream `unconsumed_bytes`
    /// (`parse.rs:306-308`). Borrows `bytes`, so it is invalidated by nothing
    /// here: the cursor has no lifetime of its own and does not own the
    /// buffer, so a slice from `rest` stays valid exactly as long as the
    /// caller's buffer does.
    pub fn rest(self: Input) []const u8 {
        return self.bytes[self.pos..];
    }

    /// True when there is nothing left to read. Upstream `is_empty`
    /// (`parse.rs:300-303`).
    pub fn isEmpty(self: Input) bool {
        return self.pos == self.bytes.len;
    }

    /// The number of bytes not yet consumed, which is `rest().len`. This is
    /// the number every count read from a file is checked against: a
    /// `readCountThen` divides it by the section's minimum element size, and
    /// `take` refuses an `n` above it.
    pub fn remaining(self: Input) usize {
        return self.bytes.len - self.pos;
    }

    /// Consumes `n` bytes and returns them borrowed from the input. Upstream
    /// `take_n` (`parse.rs:179-191`). The only error is
    /// `error.UnexpectedEnd`, for an `n` the input cannot cover, and it
    /// leaves the cursor where it stood — never a silently short slice.
    pub fn take(self: *Input, n: usize) ParseError![]const u8 {
        if (n > self.remaining()) return error.UnexpectedEnd;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    /// One raw byte. Upstream `take_1` (`parse.rs:165-177`). The only error is
    /// `error.UnexpectedEnd`, and it consumes nothing.
    pub fn takeByte(self: *Input) ParseError!u8 {
        const out = try self.take(1);
        return out[0];
    }

    /// An unsigned LEB128 value, consuming only the bytes its encoding
    /// actually needs so a later read continues in the right place. Upstream
    /// `leb128_u64` (`parse/leb128.rs:15-40`), which shares this crate's
    /// strict reader: an overlong encoding, a tenth byte carrying more than
    /// the one bit that is left, and a truncated tail are all errors here
    /// rather than silently accepted values.
    ///
    /// The refusals are `error.UnexpectedEnd` for a truncated tail,
    /// `error.InvalidLeb128` for an overlong encoding, and `error.Overflow`
    /// for a tenth byte wider than the one bit that is left. All three leave
    /// the cursor where it stood, because the length of the encoding is only
    /// known once the value has been read.
    ///
    /// This reads any LEB128 field the format uses, a count as readily as a
    /// length or a sequence number, and it applies **no bound of its own to a
    /// count**. A caller that sizes an allocation from the value it returns
    /// proves the value against `remaining()` first — which is what
    /// [`Input.readCountThen`] does on the caller's behalf.
    pub fn takeUleb(self: *Input) ParseError!u64 {
        const r = try leb128.readUnsigned(self.rest());
        self.pos += r.len;
        return r.value;
    }

    /// A signed LEB128 value, under the same strict rules
    /// (`parse/leb128.rs:42-76`): `error.UnexpectedEnd`,
    /// `error.InvalidLeb128` or `error.Overflow`, each leaving the cursor
    /// where it stood.
    pub fn takeLeb(self: *Input) ParseError!i64 {
        const r = try leb128.readSigned(self.rest());
        self.pos += r.len;
        return r.value;
    }

    /// Consumes `@sizeOf(T)` bytes and returns them as the big-endian byte
    /// array of a `T`. Pass an integer type and read the value back with
    /// `std.mem.readInt(T, &bytes, .big)`, or pass an array type to take that
    /// many bytes by their width — a change hash is `@sizeOf([32]u8)`, a
    /// chunk checksum is `@sizeOf([4]u8)`. The only error is
    /// `error.UnexpectedEnd`, for a short input, and it consumes nothing.
    pub fn takeArray(self: *Input, comptime T: type) ParseError![@sizeOf(T)]u8 {
        const n = @sizeOf(T);
        const bytes = try self.take(n);
        var out: [n]u8 = undefined;
        @memcpy(&out, bytes);
        return out;
    }

    /// A big-endian `u32`: four bytes, most significant first. The only error
    /// is `error.UnexpectedEnd`.
    pub fn takeU32(self: *Input) ParseError!u32 {
        const bytes = try self.takeArray(u32);
        return std.mem.readInt(u32, &bytes, .big);
    }

    /// A big-endian `u64`: eight bytes, most significant first. The only error
    /// is `error.UnexpectedEnd`.
    pub fn takeU64(self: *Input) ParseError!u64 {
        const bytes = try self.takeArray(u64);
        return std.mem.readInt(u64, &bytes, .big);
    }

    /// A cursor over the next `n` bytes, which this cursor then steps past.
    /// This is upstream's `split` (`parse.rs:287-292`) with the first half
    /// thrown away: the caller keeps the body and the parent resumes after
    /// it. That is how a chunk body, one column's data, or one section of a
    /// document is isolated before it is parsed. The sub-cursor's `pos` starts
    /// at zero, so an offset recorded inside it is relative to the region.
    ///
    /// The only error is `error.UnexpectedEnd`, for an `n` the input cannot
    /// cover; a failed `sub` leaves the parent untouched. The sub-cursor
    /// borrows the parent's bytes, so it outlives neither the buffer nor a
    /// mutation of it, and it owns nothing of its own.
    pub fn sub(self: *Input, n: usize) ParseError!Input {
        return Input.init(try self.take(n));
    }

    /// Advances by `n` without checking, saturating at the end of the buffer.
    /// Upstream's `skip` clamps the same way (`parse.rs:239-247`): a skip past
    /// the end yields an empty cursor, and the next reader returns
    /// `error.UnexpectedEnd` instead of trapping. It never fails, so it
    /// cannot be the reader that reports truncation.
    ///
    /// Use it only to step over a region whose length an earlier reader
    /// already validated, such as the opaque tail of a change chunk; never to
    /// seek. The cursor ends at `min(pos + n, bytes.len)`.
    pub fn skip(self: *Input, n: usize) void {
        const end = self.pos +| n;
        self.pos = @min(end, self.bytes.len);
    }

    /// A length-prefixed byte string: a uleb128 byte count, then that many
    /// bytes, returned borrowed. Upstream `length_prefixed_bytes`
    /// (`parse.rs:453-459`) and `actor_id` (`parse.rs:503-510`) share this
    /// shape, and the document format writes an actor, a change message, a
    /// map key, and a value's byte payload exactly this way
    /// (`decodable_impls.rs:162-175`).
    ///
    /// The refusals are `error.UnexpectedEnd`,
    /// `error.InvalidLeb128` and `error.Overflow` from the prefix, and
    /// `error.LengthExceedsInput` for a declared length the bytes behind it
    /// cannot hold. All four leave the cursor where it stood: the prefix is
    /// measured without committing, so a caller that recovers is still
    /// positioned at the string.
    pub fn readStrBytes(self: *Input) ParseError![]const u8 {
        const w = try self.strWindow();
        const bytes = self.rest()[w.head..][0..w.len];
        self.pos += w.head + w.len;
        return bytes;
    }

    /// A length-prefixed UTF-8 string, returned borrowed. Upstream `utf_8`
    /// (`parse.rs:530-539`) copies the bytes into a `String`; the port
    /// validates in place and borrows, because the whole read path is meant
    /// to allocate nothing. The cursor does not move when the bytes are not
    /// UTF-8, so a caller that recovers from the error is still positioned at
    /// the string rather than in the middle of it.
    ///
    /// The refusals are those of [`Input.readStrBytes`] plus
    /// `error.InvalidUtf8`, and all five leave the cursor where it stood.
    pub fn readStr(self: *Input) ParseError![]const u8 {
        const w = try self.strWindow();
        const bytes = self.rest()[w.head..][0..w.len];
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        self.pos += w.head + w.len;
        return bytes;
    }

    /// Reads a uleb128 element count, proves it against the input, and only
    /// then runs `f` with it.
    ///
    /// `min_item_size` is the smallest number of bytes one element of the
    /// counted section can occupy, and it is a compile-time constant because
    /// it is a structural property of the format rather than of the data: an
    /// actor is at least one byte of length prefix, a change hash is 32, a
    /// column is a spec plus a length, a head index is one uleb128. A count
    /// larger than `remaining() / min_item_size` is refused with
    /// `error.LengthExceedsInput` *before* `f` runs, so a hostile ten-byte
    /// LEB128 in a forty-byte file can never size an allocation. This is the
    /// load-bearing safety property of the format layer; upstream reaches the
    /// same place from the other side, by letting `take_n` run out of input
    /// part-way through a loop (`parse.rs:179-191`) and by capping allocations
    /// in the value decoder (`decodable_impls.rs:10`). Here the bound follows
    /// from the input, so no cap constant has to be invented and none can be
    /// wrong for a differently shaped document.
    ///
    /// `f` receives the count as a `usize` already known to be at most
    /// `remaining() / min_item_size`, and it owns every allocation the count
    /// causes. It carries the caller's own state — a destination collection,
    /// an allocator, an out-parameter for the number of elements actually
    /// parsed — through `ctx`, because a function pointer cannot capture.
    ///
    /// Four things about the callback are fixed here, and a caller needs all
    /// four:
    ///
    /// * **`f` is a `comptime` parameter.** It must be named at the call
    ///   site; a function value held in a variable is not a `comptime` value
    ///   and cannot be passed. A sink that has to be chosen at run time is
    ///   dispatched by the caller, not here.
    /// * **`ctx` is passed by value and its type is whatever the caller
    ///   passed**, because `@TypeOf(ctx)` names it in the signature. A sink
    ///   that mutates therefore holds a pointer, and that is what every
    ///   in-tree sink does.
    /// * **`f` runs on the cursor the count came from, with the prefix
    ///   already consumed.** A `ctx` that holds `*Input` — which is how
    ///   `change.zig`, `storage/change_chunk.zig`, `storage/bundle.zig`,
    ///   `storage/document_chunk.zig` and `sync/message.zig` all call this —
    ///   advances that same cursor, so `f` consumes the counted section
    ///   itself and the caller resumes where `f` stopped. `f` may also call
    ///   `readCountThen` again on that cursor for a nested count: the bound
    ///   is proved against whatever is left at the inner call, and both
    ///   calls leave the cursor after their own prefix on failure.
    /// * **What survives an error.** `error.UnexpectedEnd` from the prefix
    ///   leaves the cursor where it stood. `error.LengthExceedsInput` leaves
    ///   it just past the prefix it refused, because the count must be read
    ///   before it can be judged. An error `f` itself returns propagates
    ///   unchanged, with the cursor wherever `f` left it. In no case is the
    ///   cursor restored, and a caller that recovers has to work from where
    ///   it is or re-parse the whole buffer from a fresh cursor.
    pub fn readCountThen(
        self: *Input,
        ctx: anytype,
        comptime min_item_size: usize,
        comptime f: fn (@TypeOf(ctx), usize) ParseError!void,
    ) ParseError!void {
        if (min_item_size == 0) @compileError("readCountThen needs a positive min_item_size: a zero-width element leaves the count unbounded by the input");
        const count = try self.takeUleb();
        // `remaining() / min_item_size` is at most `remaining()`, so neither
        // the comparison nor the cast below can overflow on any target.
        if (count > @as(u64, self.remaining() / min_item_size)) return error.LengthExceedsInput;
        return f(ctx, @intCast(count));
    }

    /// The uleb128 length prefix and the byte window it delimits, computed
    /// from `rest()` without moving the cursor, so a caller can check the
    /// bytes before committing to them. On return `head + len <=
    /// remaining()`, so slicing the payload with them is always in bounds.
    fn strWindow(self: Input) ParseError!struct { head: usize, len: usize } {
        const r = try leb128.readUnsigned(self.rest());
        // The payload starts *after* the prefix, so the bound is the bytes
        // left once the prefix is taken off, not the bytes left before.
        // `r.len <= remaining()` holds because the read succeeded.
        if (r.value > self.remaining() - r.len) return error.LengthExceedsInput;
        return .{ .head = r.len, .len = @intCast(r.value) };
    }
};

// --- test scaffolding -----------------------------------------------------

/// A destination for `readCountThen`, standing in for a real parser: it
/// allocates in proportion to the count, which is exactly what the count
/// check exists to bound. `ran` records whether the count got past the check.
const Sink = struct {
    gpa: std.mem.Allocator,
    ran: bool = false,
    items: usize = 0,

    /// The callback `readCountThen` invokes. One byte per element, so the
    /// allocation is exactly `count` bytes and a count that slipped through
    /// unchecked would be visible in the allocator.
    fn collect(self: *Sink, count: usize) ParseError!void {
        self.ran = true;
        self.items = count;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(self.gpa);
        try list.appendNTimes(self.gpa, 0xaa, count);
    }
};

/// `readCountThen` over a plain `usize` out-parameter, for the truncation
/// table, which wants a reader with no state of its own.
fn recordCount(n: *usize, count: usize) ParseError!void {
    n.* = count;
}

/// A `readCountThen` destination that holds the cursor itself, which is the
/// shape every in-tree sink has: it reads the counted section off the same
/// `Input` the count was read from.
const CursorSink = struct {
    in: *Input,
    /// How many bytes the callback consumed, so a test can see the cursor it
    /// left behind rather than inferring it.
    read: usize = 0,

    /// One byte per element, taken from the caller's own cursor.
    fn collect(self: *CursorSink, count: usize) ParseError!void {
        for (0..count) |_| {
            _ = try self.in.takeByte();
            self.read += 1;
        }
    }

    /// The same, but refusing after the first byte, to pin what survives an
    /// error the callback itself returns.
    fn collectThenFail(self: *CursorSink, count: usize) ParseError!void {
        try self.collect(count);
        return error.UnexpectedEnd;
    }

    /// A callback that reads a *second* counted section off the same cursor,
    /// which is the reentry case: the inner count is proved against whatever
    /// is left after the outer one.
    fn collectNested(self: *CursorSink, count: usize) ParseError!void {
        for (0..count) |_| {
            var n: usize = 0;
            try self.in.readCountThen(&n, 1, recordCount);
            self.read += n;
            _ = try self.in.take(n);
        }
    }
};

// Reader wrappers that discard their result, so readers of different return
// types can sit in one table.
fn runTake(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.take(2);
}

fn runTakeByte(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeByte();
}

fn runTakeUleb(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeUleb();
}

fn runTakeLeb(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeLeb();
}

fn runTakeU32(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeU32();
}

fn runTakeU64(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeU64();
}

fn runTakeArrayU16(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.takeArray(u16);
}

fn runReadStr(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.readStr();
}

fn runReadStrBytes(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.readStrBytes();
}

fn runSub(buf: []const u8) ParseError!void {
    var in: Input = .init(buf);
    _ = try in.sub(3);
}

fn runReadCountThen(buf: []const u8) ParseError!void {
    var n: usize = 0;
    var in: Input = .init(buf);
    try in.readCountThen(&n, 1, recordCount);
}

// --- tests ----------------------------------------------------------------

test "every reader, against one hand-built buffer" {
    // Every field laid out the way the format writes it, in the order a
    // parser meets them in a chunk: magic, a raw byte, a uleb128, a
    // sleb128, two big-endian integers of different widths, a string, a
    // length-prefixed byte blob, then a length-delimited region and a
    // trailing byte.
    const buf = [_]u8{
        0x85, 0x6f, 0x4a, 0x83, //                             chunk magic, 4 bytes
        0x07, //                                                one raw byte
        0xac, 0x02, //                                           uleb128 300
        0xae, 0x76, //                                           sleb128 -1234
        0x01, 0x02, 0x03, 0x04, //                               u32, big endian
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, //       u64, big endian
        0x03, 'a', 'b', 'c', //                               uleb 3 + "abc"
        0x02, 0xff, 0xfe, //                                    uleb 2 + two raw bytes
        0x04, 0x0a, 0x0b, 0x0c, 0x0d, 0x77, //                  uleb 4 + a region, then a tail
    };

    var in: Input = .init(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x85, 0x6f, 0x4a, 0x83 }, try in.take(4));
    try std.testing.expectEqual(@as(u8, 0x07), try in.takeByte());
    try std.testing.expectEqual(@as(u64, 300), try in.takeUleb());
    try std.testing.expectEqual(@as(i64, -1234), try in.takeLeb());
    try std.testing.expectEqual(@as(u32, 0x01020304), try in.takeU32());
    try std.testing.expectEqual(@as(u64, 0x0001020304050607), try in.takeU64());
    try std.testing.expectEqualStrings("abc", try in.readStr());
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, try in.readStrBytes());

    // A length-delimited region, delimited the way the format delimits one.
    const region_len = try in.takeUleb();
    const body = try in.sub(region_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c, 0x0d }, body.rest());
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
    try std.testing.expectEqual(@as(u8, 0x77), try in.takeByte());
    try std.testing.expect(in.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), in.remaining());
    try std.testing.expectEqual(@as(usize, buf.len), 34);
}

test "no reader traps on a truncated buffer" {
    // `buf` holds exactly one complete value and `needed` is how many bytes
    // that value occupies. Every shorter prefix must fail, and it must fail
    // with the documented error rather than by running off the end: an empty
    // input is `UnexpectedEnd` for every reader, and a prefix carrying a
    // declared length the input cannot honour is `LengthExceedsInput`.
    const cases = [_]struct {
        name: []const u8,
        buf: []const u8,
        needed: usize,
        trunc: ParseError,
        read: *const fn ([]const u8) ParseError!void,
    }{
        .{ .name = "take", .buf = "abcd", .needed = 2, .trunc = error.UnexpectedEnd, .read = runTake },
        .{ .name = "takeByte", .buf = "\x2a", .needed = 1, .trunc = error.UnexpectedEnd, .read = runTakeByte },
        .{ .name = "takeUleb", .buf = "\xac\x02", .needed = 2, .trunc = error.UnexpectedEnd, .read = runTakeUleb },
        .{ .name = "takeLeb", .buf = "\xae\x76", .needed = 2, .trunc = error.UnexpectedEnd, .read = runTakeLeb },
        .{ .name = "takeU32", .buf = "\x01\x02\x03\x04", .needed = 4, .trunc = error.UnexpectedEnd, .read = runTakeU32 },
        .{ .name = "takeU64", .buf = "\x00\x01\x02\x03\x04\x05\x06\x07", .needed = 8, .trunc = error.UnexpectedEnd, .read = runTakeU64 },
        .{ .name = "takeArray(u16)", .buf = "\x12\x34", .needed = 2, .trunc = error.UnexpectedEnd, .read = runTakeArrayU16 },
        .{ .name = "sub", .buf = "xyz", .needed = 3, .trunc = error.UnexpectedEnd, .read = runSub },
        .{ .name = "readStr", .buf = "\x03abc", .needed = 4, .trunc = error.LengthExceedsInput, .read = runReadStr },
        .{ .name = "readStrBytes", .buf = "\x02\xff\xfe", .needed = 3, .trunc = error.LengthExceedsInput, .read = runReadStrBytes },
        .{ .name = "readCountThen", .buf = "\x01\xaa", .needed = 2, .trunc = error.LengthExceedsInput, .read = runReadCountThen },
    };

    for (cases) |c| {
        // An empty input: every reader needs at least one byte to start.
        try std.testing.expectError(error.UnexpectedEnd, c.read(""));
        // Every other short prefix, cut inside the value.
        var n: usize = 1;
        while (n < c.needed) : (n += 1) {
            if (c.read(c.buf[0..n])) |_| {
                std.debug.print("{s}: a prefix of {d} of {d} bytes was accepted\n", .{
                    c.name, n, c.needed,
                });
                return error.TestExpectedError;
            } else |e| {
                if (e != c.trunc) {
                    std.debug.print("{s}: a prefix of {d} of {d} bytes gave {s}, expected {s}\n", .{
                        c.name, n, c.needed, @errorName(e), @errorName(c.trunc),
                    });
                    return e;
                }
            }
        }
        // The complete value is still a value: the truncation behaviour must
        // not have cost the reader its good input.
        try c.read(c.buf);
    }
}

test "a hostile count is rejected before anything is allocated" {
    // uleb128 4294967295 in five bytes, followed by nothing. At one byte per
    // element the input could hold zero elements.
    const hostile = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f };

    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var sink: Sink = .{ .gpa = failing.allocator() };
    var in: Input = .init(&hostile);

    try std.testing.expectError(
        error.LengthExceedsInput,
        in.readCountThen(&sink, 1, Sink.collect),
    );
    // The callback never ran, so the allocator was never touched: getting
    // `LengthExceedsInput` rather than `OutOfMemory` from an allocator that
    // fails on its very first call is the proof.
    try std.testing.expect(!sink.ran);
    try std.testing.expectEqual(@as(usize, 0), sink.items);

    // The same count against a 32-byte minimum is refused even harder, and
    // so is a count that fits the input but not a plausible element width.
    var wide: Input = .init(&hostile);
    try std.testing.expectError(
        error.LengthExceedsInput,
        wide.readCountThen(&sink, 32, Sink.collect),
    );
    try std.testing.expect(!sink.ran);

    // A count of 2^40, the widest a well-formed uleb128 reaches, is refused
    // against a full buffer too: 64 bytes cannot hold a terabyte of
    // 16-byte elements.
    var huge = std.ArrayList(u8).empty;
    defer huge.deinit(std.testing.allocator);
    try huge.appendSlice(std.testing.allocator, &@as([5]u8, @splat(0x80)));
    try huge.append(std.testing.allocator, 0x40);
    try huge.appendNTimes(std.testing.allocator, 0x00, 64);
    var big: Input = .init(huge.items);
    try std.testing.expectError(
        error.LengthExceedsInput,
        big.readCountThen(&sink, 16, Sink.collect),
    );
    try std.testing.expect(!sink.ran);
}

test "the count bound is exactly the input" {
    // A count byte then four payload bytes, two of which one element must
    // hold: two elements fit and three do not.
    var sink: Sink = .{ .gpa = std.testing.allocator };

    var fits: Input = .init(&[_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00 });
    try fits.readCountThen(&sink, 2, Sink.collect);
    try std.testing.expect(sink.ran);
    try std.testing.expectEqual(@as(usize, 2), sink.items);
    // The count itself is consumed; the callback owns the rest.
    try std.testing.expectEqual(@as(usize, 4), fits.remaining());

    sink.ran = false;
    var does_not: Input = .init(&[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectError(
        error.LengthExceedsInput,
        does_not.readCountThen(&sink, 2, Sink.collect),
    );
    try std.testing.expect(!sink.ran);
    // A rejected count still consumed its own length prefix, which is the
    // one thing the cursor is allowed to have moved past.
    try std.testing.expectEqual(@as(usize, 4), does_not.remaining());

    // A wider minimum bound holds the same bytes to a smaller count, so the
    // bound is driven by `min_item_size` and not by a constant: a 32-byte
    // element cannot fit four times over.
    var wide: Input = .init(&[_]u8{ 0x04, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectError(
        error.LengthExceedsInput,
        wide.readCountThen(&sink, 32, Sink.collect),
    );
    try std.testing.expect(!sink.ran);
}

test "the callback runs on the caller's cursor, and the caller resumes where it stopped" {
    // A count of two, one byte per element, then a byte that belongs to the
    // caller rather than to the section.
    const buf = [_]u8{ 0x02, 0xaa, 0xbb, 0xcc };
    var in: Input = .init(&buf);

    var sink: CursorSink = .{ .in = &in };
    try in.readCountThen(&sink, 1, CursorSink.collect);

    // **The callback moved the very cursor the count was read from.** Its two
    // elements are gone from it, so the caller continues at the third byte
    // rather than at the payload.
    try std.testing.expectEqual(@as(usize, 2), sink.read);
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
    try std.testing.expectEqual(@as(u8, 0xcc), try in.takeByte());
    try std.testing.expect(in.isEmpty());
}

test "a refused count consumes its prefix, and an error from the callback does not rewind it" {
    const buf = [_]u8{ 0x01, 0xaa, 0xbb };
    var in: Input = .init(&buf);

    var sink: CursorSink = .{ .in = &in };
    try std.testing.expectError(
        error.UnexpectedEnd,
        in.readCountThen(&sink, 1, CursorSink.collectThenFail),
    );
    // The error came out of `f`, and `f` had already read its element: the
    // prefix and the element are both consumed, and nothing is put back. A
    // caller that recovers starts at the second element, not at the count.
    try std.testing.expectEqual(@as(usize, 1), sink.read);
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
    try std.testing.expectEqual(@as(u8, 0xbb), try in.takeByte());

    // A count refused for being too large consumed its prefix and nothing
    // else, because the callback never ran at all.
    var refused: Input = .init(&[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x00 });
    var untouched: CursorSink = .{ .in = &refused };
    try std.testing.expectError(
        error.LengthExceedsInput,
        refused.readCountThen(&untouched, 2, CursorSink.collect),
    );
    try std.testing.expectEqual(@as(usize, 0), untouched.read);
    try std.testing.expectEqual(@as(usize, 4), refused.remaining());

    // A prefix that cannot even be read is the other case: the count is
    // refused before it exists, so the cursor does not move at all.
    var truncated: Input = .init(&[_]u8{0x80});
    try std.testing.expectError(
        error.UnexpectedEnd,
        truncated.readCountThen(&untouched, 1, CursorSink.collect),
    );
    try std.testing.expectEqual(@as(usize, 0), truncated.pos);
}

test "a callback may read a nested count off the same cursor" {
    // Three groups, each a count and then the bytes that count names: 1, 2
    // and 1. The outer count is proved against the seven bytes behind it at
    // two per group, which is exactly three, and each inner count is proved
    // against what the outer one left.
    const buf = [_]u8{ 0x03, 0x01, 0xaa, 0x02, 0xbb, 0xcc, 0x01, 0xdd };
    var in: Input = .init(&buf);

    var sink: CursorSink = .{ .in = &in };
    try in.readCountThen(&sink, 2, CursorSink.collectNested);

    // Four elements across three groups, and the cursor sits at the end: the
    // nested reads consumed exactly what their counts named.
    try std.testing.expectEqual(@as(usize, 4), sink.read);
    try std.testing.expect(in.isEmpty());

    // The same bytes under an outer minimum too wide for three groups is
    // refused before the callback runs, so the inner reads never happen.
    var wide: Input = .init(&buf);
    var wide_sink: CursorSink = .{ .in = &wide };
    try std.testing.expectError(
        error.LengthExceedsInput,
        wide.readCountThen(&wide_sink, 3, CursorSink.collectNested),
    );
    try std.testing.expectEqual(@as(usize, 0), wide_sink.read);
    try std.testing.expectEqual(@as(usize, 7), wide.remaining());
}

test "sub isolates a region and advances the parent" {
    const buf = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    var in: Input = .init(&buf);

    _ = try in.take(2);
    var body = try in.sub(3);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5 }, body.rest());
    try std.testing.expectEqual(@as(usize, 3), body.remaining());
    // The parent resumes immediately after the region, not after it plus the
    // two bytes read before it.
    try std.testing.expectEqualSlices(u8, &.{ 6, 7 }, in.rest());

    // The two cursors move independently; the parent's offset into `buf` is
    // not inherited by the sub-cursor.
    try std.testing.expectEqual(@as(u8, 3), try body.takeByte());
    try std.testing.expectEqual(@as(usize, 2), body.remaining());
    try std.testing.expectEqual(@as(usize, 2), in.remaining());
    try std.testing.expectEqual(@as(u8, 6), try in.takeByte());

    // A failed `sub` leaves the parent untouched.
    try std.testing.expectError(error.UnexpectedEnd, in.sub(2));
    try std.testing.expectEqual(@as(usize, 1), in.remaining());

    // A zero-length sub is a cursor that is already exhausted, and it still
    // consumes nothing of its own.
    const empty = try in.sub(0);
    try std.testing.expect(empty.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
}

test "the string readers borrow the input" {
    const buf = [_]u8{ 0x03, 'a', 'b', 'c', 0x02, 0xff, 0xfe, 0x05 };

    var in: Input = .init(&buf);
    const s = try in.readStr();
    try std.testing.expectEqualStrings("abc", s);
    // Borrowed, not copied: the slice points into `buf` itself.
    try std.testing.expectEqual(@intFromPtr(&buf[1]), @intFromPtr(s.ptr));
    try std.testing.expectEqual(@as(usize, 4), in.remaining());

    const bytes = try in.readStrBytes();
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, bytes);
    try std.testing.expectEqual(@intFromPtr(&buf[5]), @intFromPtr(bytes.ptr));
    try std.testing.expectEqual(@as(usize, 1), in.remaining());

    // A length that outruns the input is refused, and the cursor stays put:
    // neither the length prefix nor a byte of the payload is consumed.
    try std.testing.expectError(error.LengthExceedsInput, in.readStrBytes());
    try std.testing.expectError(error.LengthExceedsInput, in.readStr());
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
    try std.testing.expectEqual(@as(u8, 0x05), try in.takeByte());
}

test "readStr refuses non-UTF-8 without moving the cursor" {
    const buf = [_]u8{ 0x02, 0xc3, 0x28, 0xaa };
    var in: Input = .init(&buf);
    try std.testing.expectError(error.InvalidUtf8, in.readStr());
    try std.testing.expectEqual(@as(usize, 0), in.pos);
    try std.testing.expectEqual(@as(usize, buf.len), in.remaining());

    // The same bytes are fine as opaque bytes: the same two bytes a map key
    // or an actor id would be read with.
    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0x28 }, try in.readStrBytes());
    // One length byte and two payload bytes consumed, one byte left over.
    try std.testing.expectEqual(@as(usize, 3), in.pos);
    try std.testing.expectEqual(@as(u8, 0xaa), try in.takeByte());
}

test "a length prefix is measured from after itself" {
    // The payload starts after the length prefix, so a declared length that
    // exactly fills the bytes *including* the prefix is one too long. A check
    // written as `len > remaining()` instead of `len > remaining() - prefix`
    // accepts this and then reads one byte past the buffer.
    var one_short: Input = .init("\x03ab");
    try std.testing.expectError(error.LengthExceedsInput, one_short.readStrBytes());
    try std.testing.expectEqual(@as(usize, 0), one_short.pos);

    var exact: Input = .init("\x03abc");
    try std.testing.expectEqualSlices(u8, "abc", try exact.readStrBytes());
    try std.testing.expect(exact.isEmpty());

    // A two-byte prefix is measured the same way: `0x80 0x02` is 256, and
    // 256 payload bytes is the least that can satisfy it.
    var few: Input = .init(&[_]u8{ 0x80, 0x02 } ++ @as([255]u8, @splat(0x00)));
    try std.testing.expectError(error.LengthExceedsInput, few.readStrBytes());
    try std.testing.expectEqual(@as(usize, 0), few.pos);

    var many: Input = .init(&[_]u8{ 0x80, 0x02 } ++ @as([256]u8, @splat(0x00)));
    try std.testing.expectEqual(@as(usize, 256), (try many.readStrBytes()).len);
    try std.testing.expect(many.isEmpty());

    // An empty string is a length of zero and still costs its prefix byte.
    var empty: Input = .init("\x00\xff");
    try std.testing.expectEqualStrings("", try empty.readStr());
    try std.testing.expectEqual(@as(usize, 1), empty.remaining());
}

test "big-endian integers of different widths keep their boundary" {
    // A u16, a u32 and a u64 laid end to end with no padding and no length
    // prefix: the declared width is the only thing separating them.
    const buf = [_]u8{
        0x12, 0x34, //                             u16
        0xde, 0xad, 0xbe, 0xef, //                 u32
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, // u64
        0x77, //                                    a trailing byte
    };

    var in: Input = .init(&buf);
    const a16 = try in.takeArray(u16);
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, &a16, .big));
    // Reading the same two bytes the other way round gives a different
    // number, so a little-endian implementation fails here rather than
    // agreeing by accident on a palindromic fixture.
    try std.testing.expectEqual(@as(u16, 0x3412), std.mem.readInt(u16, &a16, .little));

    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try in.takeU32());
    const a64 = try in.takeArray(u64);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), std.mem.readInt(u64, &a64, .big));
    try std.testing.expectEqual(@as(u64, 0xefcdab8967452301), std.mem.readInt(u64, &a64, .little));

    // Exactly fourteen bytes went past, and the boundary held.
    try std.testing.expectEqual(@as(usize, 1), in.remaining());
    try std.testing.expectEqual(@as(u8, 0x77), try in.takeByte());
    try std.testing.expect(in.isEmpty());

    // The same four bytes read as one u32 and as an array, which is what a
    // chunk magic followed by a checksum looks like from either side.
    var pair: Input = .init(&.{ 0x85, 0x6f, 0x4a, 0x83, 0x11, 0x22, 0x33, 0x44 });
    const sum = try pair.takeArray([4]u8);
    try std.testing.expectEqualSlices(u8, &.{ 0x85, 0x6f, 0x4a, 0x83 }, &sum);
    try std.testing.expectEqual(@as(u32, 0x11223344), try pair.takeU32());
    try std.testing.expect(pair.isEmpty());
}

test "skip steps over a validated region and cannot trap" {
    const buf = [_]u8{ 0x0a, 0x0b, 0x0c, 0x07, 0xff };
    var in: Input = .init(&buf);

    in.skip(3);
    try std.testing.expectEqual(@as(u8, 0x07), try in.takeByte());
    try std.testing.expectEqual(@as(usize, 1), in.remaining());

    // Skipping past the end saturates to the end of the buffer instead of
    // running off it, and leaves a cursor whose next read is an ordinary
    // truncation error rather than a panic.
    in.skip(1000);
    try std.testing.expect(in.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), in.remaining());
    try std.testing.expectEqual(@as(usize, buf.len), in.pos);
    try std.testing.expectError(error.UnexpectedEnd, in.takeByte());
    try std.testing.expectError(error.UnexpectedEnd, in.readStr());
    try std.testing.expectError(error.UnexpectedEnd, in.sub(1));

    // A skip of zero is a no-op, and so is a skip taken twice.
    var again: Input = .init(&buf);
    again.skip(0);
    again.skip(0);
    try std.testing.expectEqual(@as(usize, buf.len), again.remaining());
    try std.testing.expectEqual(@as(u8, 0x0a), try again.takeByte());
}

test "a LEB128 read consumes only its own bytes and keeps the strict rules" {
    // uleb128 128, then two unrelated bytes that the next read must see.
    var in: Input = .init(&[_]u8{ 0x80, 0x01, 0xaa, 0xbb });
    try std.testing.expectEqual(@as(u64, 128), try in.takeUleb());
    try std.testing.expectEqual(@as(u8, 0xaa), try in.takeByte());
    try std.testing.expectEqual(@as(u8, 0xbb), try in.takeByte());

    // The strict reader's rejections reach the caller unchanged rather than
    // being smoothed into a value, and a rejected read consumes nothing.
    var overlong: Input = .init(&@as([11]u8, @splat(0x80)));
    try std.testing.expectError(error.InvalidLeb128, overlong.takeUleb());
    try std.testing.expectEqual(@as(usize, 0), overlong.pos);

    var too_wide: Input = .init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 });
    try std.testing.expectError(error.Overflow, too_wide.takeUleb());
    try std.testing.expectEqual(@as(usize, 0), too_wide.pos);

    var bad_sign: Input = .init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 });
    try std.testing.expectError(error.Overflow, bad_sign.takeLeb());
    try std.testing.expectEqual(@as(usize, 0), bad_sign.pos);
}

test "the cursor never leaves its buffer" {
    // Whatever the input, and whatever the caller does to the cursor, `pos`
    // stays a valid index into `bytes`, so `rest` and `remaining` cannot trap
    // and no later read can run off the end. This is the invariant every
    // other method depends on.
    const inputs = [_][]const u8{
        &.{},
        "a",
        "abcdef",
        &@as([64]u8, @splat(0xff)),
    };
    const jumps = [_]usize{ 0, 1, 2, 3, 7, 64, 65, 4096, std.math.maxInt(usize) };

    for (inputs) |input| {
        var in: Input = .init(input);
        for (jumps) |j| {
            in.skip(j);
            try std.testing.expect(in.pos <= input.len);
            try std.testing.expectEqual(in.pos == input.len, in.isEmpty());
            try std.testing.expectEqual(@as(usize, input.len) - in.pos, in.remaining());
            try std.testing.expectEqualSlices(u8, input[in.pos..], in.rest());
            if (in.isEmpty()) {
                try std.testing.expectError(error.UnexpectedEnd, in.take(1));
            } else {
                _ = try in.take(1);
            }
        }
    }
}

// The totality regression suite over every parser below, driven by the eight
// upstream fuzz crashers. It lives beside the parsers it drives rather than
// under `test/` because it imports them as private modules.
test {
    _ = @import("totality_test.zig");
}
