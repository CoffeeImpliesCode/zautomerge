//! The Bloom filter that summarises what a peer says it already has.
//!
//! One filter lives inside each `have` record of a sync message
//! (`sync/bloom.rs:125-141` builds it, `sync.rs:190-194` puts it on the
//! wire). Nothing persists a filter: it is rebuilt from the shared heads on
//! every generated message and discarded with the message.
//!
//! ```text
//! if num_entries == 0:   the field is absent — zero bytes       bloom.rs:40
//! else:
//!   uleb128  num_entries
//!   uleb128  num_bits_per_entry   10 from this implementation    bloom.rs:9, 127
//!   uleb128  num_probes            7 from this implementation    bloom.rs:10, 128
//!   bytes    ceil(num_entries * num_bits_per_entry / 8)          bloom.rs:143-146
//! ```
//!
//! Both parameters travel on the wire (`bloom.rs:7-8`), so the numbers below
//! are part of the compatibility contract for what *this* implementation
//! writes and may only be changed together with every peer. A filter that
//! arrives with other parameters is read with those parameters, which is
//! what the format requires: a peer is free to choose a different false
//! positive rate.
//!
//! The probe scheme is double hashing over three little-endian 32-bit words
//! of the change hash (`bloom.rs:69-90`). The JavaScript reference in
//! `automerge-wasm/test/helpers/sync.mjs:74-89` implements the same walk and
//! cites Dillinger & Manolios, *Bloom Filters in Probabilistic Verification*,
//! FMCAD 2004.

const std = @import("std");
const err = @import("../error.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");
const Input = @import("../storage/parse.zig").Input;

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const ChangeHash = types.ChangeHash;

/// Bits of filter per inserted hash (`bloom.rs:9`). A 1% false positive rate
/// with `num_probes` probes.
pub const bits_per_entry: u32 = 10;

/// Hash probes per inserted hash (`bloom.rs:10`).
pub const num_probes: u32 = 7;

/// The largest `num_probes` this port will read from a filter.
///
/// Upstream has no bound: `get_probes` allocates `Vec::with_capacity(
/// num_probes)` (`bloom.rs:82`), so a hostile filter asking for four billion
/// probes asks the process for sixteen gibibytes before it computes
/// anything. No implementation in the ecosystem writes more than
/// `NUM_PROBES = 7` (`bloom.rs:10`, `sync.mjs:31`,
/// `javascript/test/legacy/sync.js:36-37`) and a filter is one tenth of a
/// byte per entry (`bits_per_entry`), so a peer asking for more than this
/// many probes per entry is not a peer this format was written for. Such a
/// filter is refused at parse time rather than walked, which keeps
/// `getProbes` allocation-free and `containsHash` bounded.
pub const max_probes: u32 = 1 << 16;

/// The largest `bits.len()` for which `8 * bits.len()` still fits a `u32`,
/// which is what the probe walk reduces in and then divides by
/// (`bloom.rs:71`, `:75`). `parse` refuses a filter that declares more, and
/// `getProbes` refuses one that holds more, so the `u32` the modulus is
/// stored in is large enough for every filter it is asked to walk.
const max_bits_len: usize = std.math.maxInt(u32) / 8;

/// The number of bit-array bytes a filter over `num_entries` hashes occupies
/// (`bloom.rs:143-146`): `ceil(num_entries * num_bits_per_entry / 8)`,
/// computed in `f64` as upstream does.
///
/// The answer is bounded, because a hostile filter can declare two `u32`s
/// whose product no `usize` holds. `@min` against `maxInt(usize)` cannot be
/// that bound: `f64` has 53 bits of significand, so on a 64-bit target
/// `@floatFromInt(maxInt(usize))` rounds up to `2^64`, which
/// `@intFromFloat(2^64)` rejects. The clamp is therefore a comparison, and
/// the saturating answer is returned in the branch rather than converted.
/// Both halves agree on every value the product can reach — two `u32`s
/// divided by 8 stay below `2^61` — so the only input on which they differ
/// is the `2^64` one, which traps today and saturates here.
pub fn bitsCapacity(num_entries: u32, num_bits_per_entry: u32) usize {
    const want = (@as(f64, @floatFromInt(num_entries)) * @as(f64, @floatFromInt(num_bits_per_entry))) / 8.0;
    const ceiling = @ceil(want);
    if (ceiling >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(ceiling);
}

/// A Bloom filter over change hashes, in the wire parameters this port
/// writes and in whatever parameters a peer wrote (`bloom.rs:13-18`).
///
/// The three parameters are private in upstream, which is what keeps a
/// filter's `bits` array and its `num_entries` consistent with each other;
/// here they are readable because the record is written by hand in the
/// golden-vector tests and by `protocol.zig`. `parse` and `fromHashes` are
/// the only ways a filter is built, and both keep the invariant
/// `bits.len() == bitsCapacity(num_entries, num_bits_per_entry)`.
///
/// Single-threaded, as every type here is: no lock and no callback, so a
/// filter shared across threads needs external synchronization, and nothing
/// reenters.
pub const BloomFilter = struct {
    /// How many hashes went in. Zero means "no filter at all", which is what
    /// `toBytes` turns into zero bytes and what `containsHash` answers `false`
    /// for (`bloom.rs:40`, `bloom.rs:111-112`).
    num_entries: u32,
    /// Bits of filter per entry, from the wire.
    num_bits_per_entry: u32,
    /// Probes per entry, from the wire, at most `max_probes`.
    num_probes: u32,
    /// The bit array, least significant bit of each byte first
    /// (`bloom.rs:98-102`).
    bits: []u8,
    /// The allocator `bits` was taken from and is released with; it is the
    /// one `fromHashes` and `parse` allocate through. Borrowed, not owned: it
    /// must outlive the filter, and `deinit` frees through it.
    gpa: Allocator,

    /// The filter that means "nothing", and the one a zero-length bloom
    /// section parses to (`bloom.rs:20-29`, `bloom.rs:50-51`).
    pub fn empty(gpa: Allocator) BloomFilter {
        return .{
            .num_entries = 0,
            .num_bits_per_entry = bits_per_entry,
            .num_probes = num_probes,
            .bits = &.{},
            .gpa = gpa,
        };
    }

    /// Frees the bit array and nothing else: the three parameters are
    /// values, and a filter with no entries holds the empty static slice
    /// (`bloom.rs:13-18`).
    pub fn deinit(self: *BloomFilter) void {
        self.gpa.free(self.bits);
        self.* = undefined;
    }

    /// The filter's wire bytes (`bloom.rs:38-47`).
    ///
    /// A filter with no entries encodes as *nothing at all*, not as a zero
    /// count: `Have::default()` therefore contributes a zero-length bloom
    /// field (`sync/state.rs:86-89`, `sync.rs:683-685`).
    ///
    /// **The caller owns the result** and frees it with `gpa` — the allocator
    /// given to this call, which need not be the filter's own, because the
    /// buffer belongs to the caller from the moment it is returned and
    /// nothing in the filter is released through it. An empty filter returns
    /// an empty slice, which the allocator accepts for `free`. On an error
    /// the filter is untouched and nothing is handed over.
    pub fn toBytes(self: BloomFilter, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try self.writeBytes(&out, gpa);
        return out.toOwnedSlice(gpa);
    }

    /// The same bytes as `toBytes`, appended to `out`.
    ///
    /// Upstream calls `h.bloom.to_bytes()` twice while encoding one `have`
    /// record (`sync.rs:683-684`), once for the length and once for the
    /// payload; a caller here writes `byteLen` and then this, so the filter
    /// is written once.
    pub fn writeBytes(self: BloomFilter, out: *std.ArrayList(u8), gpa: Allocator) !void {
        if (self.num_entries == 0) return;
        try leb128.appendUnsigned(out, gpa, self.num_entries);
        try leb128.appendUnsigned(out, gpa, self.num_bits_per_entry);
        try leb128.appendUnsigned(out, gpa, self.num_probes);
        try out.appendSlice(gpa, self.bits);
    }

    /// How many bytes `writeBytes` appends, which is what a caller has to
    /// write before it (`sync.rs:683-685`).
    ///
    /// The three uleb128s it is made of have a known size, so this is
    /// arithmetic rather than a second pass over the bytes.
    pub fn byteLen(self: BloomFilter) usize {
        if (self.num_entries == 0) return 0;
        return leb128.unsignedSize(self.num_entries) +
            leb128.unsignedSize(self.num_bits_per_entry) +
            leb128.unsignedSize(self.num_probes) +
            self.bits.len;
    }

    /// Reads a filter from `bytes`, ignoring anything after the bit array
    /// (`bloom.rs:49-67`, and the `TryFrom<&[u8]>` at `bloom.rs:153-160`).
    ///
    /// `bytes` is a field the caller has already delimited, so this is total
    /// over it: a declared bit-array length past the end of `bytes` is
    /// `error.LengthExceedsInput` before anything is allocated
    /// (`bloom.rs:56` reaches the same place through `take_n`,
    /// `parse.rs:179-191`), and a `num_probes` above `max_probes` is
    /// `error.TooLarge`.
    pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!BloomFilter {
        if (bytes.len == 0) return empty(gpa);

        var in: Input = .init(bytes);
        const entries = try readU32(&in);
        const bits_each = try readU32(&in);
        const probes = try readU32(&in);
        if (probes > max_probes) return error.TooLarge;

        // `bits.len()` is bounded by the input, so the f64 product of two
        // attacker-chosen `u32`s is compared against what is left before it
        // is narrowed to a `usize`.
        const want = (@as(f64, @floatFromInt(entries)) * @as(f64, @floatFromInt(bits_each))) / 8.0;
        if (@ceil(want) > @as(f64, @floatFromInt(in.remaining()))) return error.LengthExceedsInput;
        if (want > @as(f64, @floatFromInt(max_bits_len))) return error.TooLarge;
        const raw = try in.take(bitsCapacity(entries, bits_each));

        return .{
            .num_entries = entries,
            .num_bits_per_entry = bits_each,
            .num_probes = probes,
            .bits = try gpa.dupe(u8, raw),
            .gpa = gpa,
        };
    }

    /// The probe positions `hash` maps to, walked lazily
    /// (`bloom.rs:69-90`).
    ///
    /// Upstream returns a `Vec<u32>` of length `num_probes`; this returns an
    /// iterator so the walk allocates nothing, which is what lets
    /// `containsHash` run on a filter that arrived over the network.
    ///
    /// `null` when `bits.len()` makes the walk impossible. It needs a
    /// modulus, and `8 * bits.len()` is the one upstream reduces in and then
    /// stores in a `u32` (`bloom.rs:71`, `:75`), so it has to be a non-zero
    /// `usize` that fits that `u32` — which is `1 <= bits.len() <=
    /// max_bits_len`. Both ends are refused here rather than below: `parse`
    /// refuses a filter that declares more than `max_bits_len` and builds
    /// none with no bits at all, so neither arrives over the wire, but a
    /// filter assembled by hand can reach both, and the old code answered
    /// the upper one by trapping and the lower one by dividing by zero.
    fn getProbes(self: BloomFilter, hash: ChangeHash) ?Probes {
        if (self.bits.len == 0) return null;
        const bit_count = 8 * self.bits.len;
        if (bit_count > max_bits_len * 8) return null;
        const modulo: u32 = @intCast(bit_count);
        return .{
            .x = readLeU32(hash.bytes[0..4]) % modulo,
            .y = readLeU32(hash.bytes[4..8]) % modulo,
            .z = readLeU32(hash.bytes[8..12]) % modulo,
            .modulo = modulo,
            .emitted = 0,
            .target = self.num_probes,
        };
    }

    /// Sets every probe bit of `hash` (`bloom.rs:92-96`).
    pub fn addHash(self: *BloomFilter, hash: ChangeHash) void {
        var probes = self.getProbes(hash) orelse return;
        while (probes.next()) |probe| self.setBit(probe);
    }

    /// Sets bit `probe` if the array is long enough to hold it
    /// (`bloom.rs:98-102`). A probe past the end is dropped, not an error:
    /// the array is sized from `num_bits_per_entry`, so a filter built with
    /// one value and probed with another can only reach that way.
    fn setBit(self: *BloomFilter, probe: u32) void {
        const index = probe >> 3;
        if (index >= self.bits.len) return;
        self.bits[index] |= @as(u8, 1) << @intCast(probe & 7);
    }

    /// The byte holding bit `probe`, or null when the array is shorter
    /// (`bloom.rs:104-108`). The value is the masked byte, so a set bit reads
    /// as non-zero and a clear one as `0`.
    fn getBit(self: BloomFilter, probe: u32) ?u8 {
        const index = probe >> 3;
        if (index >= self.bits.len) return null;
        return self.bits[index] & (@as(u8, 1) << @intCast(probe & 7));
    }

    /// True when every probe of `hash` is set, or when the filter has no bits
    /// at all (`bloom.rs:110-123`).
    ///
    /// The `num_entries == 0` short circuit is upstream's. The second is not:
    /// a filter whose bit array cannot be walked is hostile, and upstream
    /// would divide by zero and panic on it (`bloom.rs:79-80`), so it
    /// answers `false` here, the same way an empty filter does. That covers
    /// a filter that claims entries and holds no bits, and a filter whose
    /// bit array is longer than `max_bits_len`, which upstream would store
    /// its modulus in a `u32` that cannot hold it.
    pub fn containsHash(self: BloomFilter, hash: ChangeHash) bool {
        if (self.num_entries == 0) return false;
        var probes = self.getProbes(hash) orelse return false;
        while (probes.next()) |probe| {
            if (self.getBit(probe)) |bit| {
                if (bit == 0) return false;
            }
        }
        return true;
    }

    /// The filter over `hashes`, sized and parameterised by this port
    /// (`bloom.rs:125-141`).
    pub fn fromHashes(gpa: Allocator, hashes: []const ChangeHash) !BloomFilter {
        if (hashes.len > std.math.maxInt(u32)) return error.TooLarge;
        const num_entries: u32 = @intCast(hashes.len);
        var self: BloomFilter = .{
            .num_entries = num_entries,
            .num_bits_per_entry = bits_per_entry,
            .num_probes = num_probes,
            .bits = try gpa.alloc(u8, bitsCapacity(num_entries, bits_per_entry)),
            .gpa = gpa,
        };
        @memset(self.bits, 0);
        for (hashes) |hash| self.addHash(hash);
        return self;
    }
};

/// The probe walk of `getProbes` (`bloom.rs:82-88`): the first probe is the
/// first word reduced modulo the filter size, and every later one advances
/// `x` and `y` by the second and third. `modulo` is that filter size in bits,
/// `8 * bits.len()`, and `getProbes` only builds a walk when it is non-zero
/// and fits a `u32`, which is what makes the two `%` below defined.
const Probes = struct {
    x: u32,
    y: u32,
    z: u32,
    modulo: u32,
    emitted: u32,
    target: u32,

    fn next(self: *Probes) ?u32 {
        if (self.emitted >= self.target) return null;
        if (self.emitted == 0) {
            self.emitted = 1;
            return self.x;
        }
        // Both sums stay below `2 * modulo`, and `modulo` is at most
        // `8 * max_bits_len`, so the wrapping add never wraps in practice; it
        // is spelled `+%` because "in practice" is not a property a network
        // input gets to rely on.
        self.x = (self.x +% self.y) % self.modulo;
        self.y = (self.y +% self.z) % self.modulo;
        self.emitted += 1;
        return self.x;
    }
};

/// A little-endian `u32` over four hash bytes, which is how `get_probes`
/// reads the first three words of a change hash (`bloom.rs:72-78`).
fn readLeU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

/// One `uleb128` read as a `u32` (`parse/leb128.rs:78-85`): upstream
/// returns `Leb128TooLarge`, which the port spells `error.Overflow` for the
/// same reason `leb128.readUnsigned` does (`leb128.zig:106`).
fn readU32(in: *Input) ParseError!u32 {
    const value = try in.takeUleb();
    if (value > std.math.maxInt(u32)) return error.Overflow;
    return @intCast(value);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

// The parameters are the wire format, so they are pinned as the literals
// upstream writes rather than only against each other.
test "bloom parameters are the format's" {
    try testing.expectEqual(@as(u32, 10), bits_per_entry);
    try testing.expectEqual(@as(u32, 7), num_probes);
}

test "bits capacity rounds up" {
    // One entry is 1.25 bytes and two are 2.5, so both round to 2 and 3.
    try testing.expectEqual(@as(usize, 2), bitsCapacity(1, bits_per_entry));
    try testing.expectEqual(@as(usize, 3), bitsCapacity(2, bits_per_entry));
    try testing.expectEqual(@as(usize, 7), bitsCapacity(5, bits_per_entry));
    try testing.expectEqual(@as(usize, 0), bitsCapacity(0, bits_per_entry));
    // A filter of two `u32` maxima is 2^32*2^32/8 bytes, which no `usize`
    // holds on any target this port builds for.
    try testing.expect(bitsCapacity(std.math.maxInt(u32), std.math.maxInt(u32)) <= std.math.maxInt(usize));
}

test "an empty filter is zero bytes on the wire" {
    const gpa = testing.allocator;
    var filter = BloomFilter.empty(gpa);
    defer filter.deinit();

    const bytes = try filter.toBytes(gpa);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);

    var back = try BloomFilter.parse(gpa, bytes);
    defer back.deinit();
    try testing.expectEqual(@as(u32, 0), back.num_entries);
    try testing.expectEqual(bits_per_entry, back.num_bits_per_entry);
    try testing.expectEqual(num_probes, back.num_probes);
    try testing.expectEqual(@as(usize, 0), back.bits.len);
    try testing.expect(!back.containsHash(ChangeHash.zero));
}

test "golden bloom sections from sync.jsonl decode and re-encode" {
    const gpa = testing.allocator;
    // Record 1, round 1 left to right: a two-entry filter, and record 4,
    // round 2 right to left: a one-entry filter. Both are the whole
    // `nBloomBytes` field, so they pin the three parameters, the length
    // rule and the bit order together.
    const cases = [_]struct { bytes: []const u8, entries: u32, nbits: u8 }{
        .{ .bytes = &[_]u8{ 0x02, 0x0a, 0x07, 0xd7, 0x01, 0x55 }, .entries = 2, .nbits = 3 },
        .{ .bytes = &[_]u8{ 0x01, 0x0a, 0x07, 0x40, 0x40 }, .entries = 1, .nbits = 2 },
    };
    for (cases) |case| {
        var filter = try BloomFilter.parse(gpa, case.bytes);
        defer filter.deinit();

        try testing.expectEqual(case.entries, filter.num_entries);
        try testing.expectEqual(@as(u32, 10), filter.num_bits_per_entry);
        try testing.expectEqual(@as(u32, 7), filter.num_probes);
        try testing.expectEqual(case.nbits, filter.bits.len);

        const again = try filter.toBytes(gpa);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, case.bytes, again);
    }
}

test "a filter built from hashes contains them and encodes to its size" {
    const gpa = testing.allocator;
    var hashes = [_]ChangeHash{ hashEnding(0x01), hashEnding(0x02), hashEnding(0x03) };
    std.mem.sort(ChangeHash, &hashes, {}, ChangeHash.lessThan);

    var filter = try BloomFilter.fromHashes(gpa, &hashes);
    defer filter.deinit();

    try testing.expectEqual(@as(u32, 3), filter.num_entries);
    try testing.expectEqual(bitsCapacity(3, bits_per_entry), filter.bits.len);

    for (hashes) |hash| try testing.expect(filter.containsHash(hash));

    // The bits are exactly the ones the probe walk names, computed here from
    // the recurrence rather than from the filter's own helpers.
    const modulo: u32 = @intCast(8 * filter.bits.len);
    var x = readLeU32(hashes[0].bytes[0..4]) % modulo;
    var y = readLeU32(hashes[0].bytes[4..8]) % modulo;
    const z = readLeU32(hashes[0].bytes[8..12]) % modulo;
    var expected = std.AutoHashMapUnmanaged(u32, void){};
    defer expected.deinit(gpa);
    try expected.put(gpa, x, {});
    var k: usize = 1;
    while (k < num_probes) : (k += 1) {
        x = (x + y) % modulo;
        y = (y + z) % modulo;
        try expected.put(gpa, x, {});
    }
    var set_bits: usize = 0;
    for (filter.bits, 0..) |byte, index| {
        for (0..8) |bit| {
            const probe: u32 = @intCast(index * 8 + bit);
            const want = expected.contains(probe);
            const have = (byte & (@as(u8, 1) << @intCast(bit))) != 0;
            try testing.expectEqual(want, have);
            if (have) set_bits += 1;
        }
    }
    // 7 probes, and the walk revisits at least one of them.
    try testing.expect(set_bits > 0 and set_bits <= num_probes);

    const bytes = try filter.toBytes(gpa);
    defer gpa.free(bytes);
    var back = try BloomFilter.parse(gpa, bytes);
    defer back.deinit();
    try testing.expectEqualSlices(u8, filter.bits, back.bits);
    for (hashes) |hash| try testing.expect(back.containsHash(hash));
}

test "a filter carries its parameters, so a peer may use its own" {
    const gpa = testing.allocator;
    // 1 entry, 1 bit per entry, 1 probe: one bit array byte, one bit set.
    var filter = try BloomFilter.parse(gpa, &[_]u8{ 0x01, 0x01, 0x01, 0x01 });
    defer filter.deinit();
    try testing.expectEqual(@as(usize, 1), filter.bits.len);
    try testing.expectEqual(@as(u8, 1), filter.bits[0]);

    // A filter of this port's own parameters over the same hash would use a
    // two-byte bit array and seven probes, so the one bit here is the peer's
    // parameter rather than a bug in the reader.
    const round_trip = try filter.toBytes(gpa);
    defer gpa.free(round_trip);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x01, 0x01, 0x01 }, round_trip);
}

test "bloom rejections are ParseErrors" {
    const gpa = testing.allocator;
    // A declared bit array longer than the section that holds it.
    try testing.expectError(
        error.LengthExceedsInput,
        BloomFilter.parse(gpa, &[_]u8{ 0x02, 0x0a, 0x07, 0xd7, 0x01 }),
    );
    // A product of two `u32` maxima is 2 exabytes of bit array, refused
    // before the f64 product is narrowed to a byte count.
    try testing.expectError(
        error.LengthExceedsInput,
        BloomFilter.parse(gpa, &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x0f, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x01 }),
    );
    // A `num_probes` this port will not walk.
    try testing.expectError(
        error.TooLarge,
        BloomFilter.parse(gpa, &[_]u8{ 0x01, 0x0a, 0x81, 0x80, 0x40, 0x00 }),
    );
    // Truncated parameters.
    try testing.expectError(error.UnexpectedEnd, BloomFilter.parse(gpa, &[_]u8{0x02}));
    try testing.expectError(error.UnexpectedEnd, BloomFilter.parse(gpa, &[_]u8{ 0x02, 0x0a }));
    // A `u32` parameter that does not fit a `u32`.
    try testing.expectError(
        error.Overflow,
        BloomFilter.parse(gpa, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10, 0x0a, 0x07, 0x00 }),
    );
}

test "a filter that claims entries but holds no bits answers false" {
    const gpa = testing.allocator;
    // One entry, zero bits per entry, so the bit array is empty and every
    // probe position is a division by zero. Upstream panics here
    // (`bloom.rs:79-80`); the port answers the same way it answers for an
    // empty filter.
    var filter = try BloomFilter.parse(gpa, &[_]u8{ 0x01, 0x00, 0x01, 0x00 });
    defer filter.deinit();
    try testing.expectEqual(@as(u32, 1), filter.num_entries);
    try testing.expectEqual(@as(usize, 0), filter.bits.len);
    try testing.expect(!filter.containsHash(ChangeHash.zero));
    // Adding a hash to it is a no-op rather than a trap.
    filter.addHash(ChangeHash.zero);
    try testing.expectEqual(@as(usize, 0), filter.bits.len);
}

test "the probe modulus is a u32 exactly up to max_bits_len" {
    // `getProbes` reduces `8 * bits.len()` into the `u32` upstream stores the
    // filter size in (`bloom.rs:71`, `:75`) and walks a filter only while
    // that fits. `max_bits_len` is that boundary, so both sides of it are
    // checked against the type rather than against the constant.
    try testing.expect(8 * max_bits_len <= std.math.maxInt(u32));
    try testing.expect(8 * (max_bits_len + 1) > std.math.maxInt(u32));
    // The refusal is not dead: a filter over this port's own parameters can
    // be longer than `max_bits_len`, because `fromHashes` sizes it from an
    // entry count that is a `u32` and does not apply the bound `parse`
    // applies to a declared one.
    try testing.expect(bitsCapacity(std.math.maxInt(u32), bits_per_entry) > max_bits_len);
}

/// Parses a filter and writes it back, for the allocation-failure test below.
fn parseThenWrite(gpa: Allocator, bytes: []const u8) !void {
    var filter = try BloomFilter.parse(gpa, bytes);
    defer filter.deinit();
    const again = try filter.toBytes(gpa);
    gpa.free(again);
}

test "a filter survives every allocation failure" {
    const gpa = testing.allocator;
    try testing.checkAllAllocationFailures(
        gpa,
        parseThenWrite,
        .{&[_]u8{ 0x02, 0x0a, 0x07, 0xd7, 0x01, 0x55 }},
    );
}

/// A change hash whose last byte is `tag` and whose other bytes are zero, so
/// a test can name a hash by one number.
fn hashEnding(tag: u8) ChangeHash {
    var hash = ChangeHash.zero;
    hash.bytes[types.hash_size - 1] = tag;
    return hash;
}
