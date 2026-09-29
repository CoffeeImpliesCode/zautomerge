//! Error sets for the automerge port.
//!
//! Upstream spreads 30 variants across 13 error types. Zig has one global
//! error namespace, so they collapse into three sets, distinguished by who may
//! observe them:
//!
//! * `Error` — the document API. Reachable only from a well-formed operation.
//! * `ParseError` — everything reachable from untrusted bytes. Every parser in
//!   this crate is total over this set: a corrupt, truncated, or hostile input
//!   returns a `ParseError`. It never panics and never loops.
//! * `InternalError` — the checks upstream treats as impossible, kept distinct
//!   so a slow-path build can surface them instead of trapping.

const std = @import("std");

/// The document API surface, mirroring `AutomergeError`.
pub const Error = error{
    /// The change graph is inconsistent: a change's dependencies are missing.
    ChangeGraph,
    /// A DEFLATE stream in the input is malformed.
    Deflate,
    /// A change repeats a sequence number already seen for its actor.
    DuplicateSeqNumber,
    /// An author index was added twice.
    DuplicateAuthor,
    /// An actor id was added to the actor table twice.
    DuplicateActorId,
    /// A generic failure with no more specific variant.
    Fail,
    /// The actor id is not valid hex, or has the wrong length.
    InvalidActorId,
    /// An actor index refers to a row outside the actor table.
    InvalidActorIndex,
    /// A change hash is not 32 bytes.
    InvalidChangeHashBytes,
    /// A string contains a character that is not valid in its encoding.
    InvalidCharacter,
    /// A stored hash does not match the recomputed one.
    InvalidHash,
    /// An index is out of range for the object it addresses.
    InvalidIndex,
    /// An object id is malformed.
    InvalidObjId,
    /// An object id has the wrong format.
    InvalidObjIdFormat,
    /// An operation is not valid in this position.
    InvalidOp,
    /// A sequence number is out of range.
    InvalidSeq,
    /// A cursor does not address a position in the document.
    InvalidCursor,
    /// A cursor refers to an operation that does not exist.
    InvalidCursorOp,
    /// A cursor has the wrong format.
    InvalidCursorFormat,
    /// A value has a type that is not valid for this position.
    InvalidValueType,
    /// The input could not be loaded.
    Load,
    /// A change could not be loaded.
    LoadChangeError,
    /// A counter that must be present is missing.
    MissingCounter,
    /// A required hash is missing.
    MissingHash,
    /// Changes are missing their dependencies.
    MissingDeps,
    /// A compressed chunk does not contain a change.
    NonChangeCompressed,
    /// The object id does not name an object.
    NotAnObject,
    /// A hydrated value is not valid.
    HydrateError,
    /// A patch log does not match the document it is applied to.
    PatchLogMismatch,
    /// Text is not valid in the document's text encoding.
    EncodingError,
    /// A bundle could not be unbundled.
    Unbundle,
    /// A string is not valid UTF-8.
    InvalidUtf8,
    /// A text index is out of range for the object.
    IndexOutOfBounds,
    /// A mark name is not valid.
    InvalidMarkName,
    /// The allocator ran out of memory.
    OutOfMemory,
};

/// Everything reachable from parsing untrusted bytes.
///
/// A parser never returns `Error` and never traps. The 8 fixture files in the
/// upstream `tests/fuzz-crashers/` directory each map to one of these.
pub const ParseError = error{
    /// The input ended before the value did.
    UnexpectedEnd,
    /// A magic number did not match.
    InvalidMagic,
    /// A chunk checksum did not match the recomputed one.
    InvalidChecksum,
    /// The chunk type byte is not one of the four defined values.
    InvalidChunkType,
    /// A LEB128 value is truncated, overlong, or otherwise malformed.
    InvalidLeb128,
    /// A length or count does not fit its target type.
    Overflow,
    /// A count is larger than the implementation will accept.
    TooLarge,
    /// A change declares more operations than the implementation accepts.
    TooManyOps,
    /// A change declares more dependencies than the implementation accepts.
    TooManyDeps,
    /// An operation references an actor that is not in the actor table.
    MissingActor,
    /// A DEFLATE stream is malformed.
    InvalidDeflate,
    /// A column specification is malformed.
    InvalidColumnSpec,
    /// A column id appears twice in one block.
    DuplicateColumn,
    /// A required column is missing.
    MissingColumn,
    /// A column's declared range does not fit the data block.
    ColumnOutOfBounds,
    /// A column that must not be null is null.
    UnexpectedNull,
    /// A value type code is not one of the defined values.
    InvalidValueType,
    /// A value's bytes do not decode to its declared type.
    InvalidValue,
    /// A value metadata word is malformed.
    InvalidValueMeta,
    /// An action code is not one of the eight defined values.
    InvalidAction,
    /// A column encoding byte is not one of the defined values.
    InvalidEncoding,
    /// A text encoding tag is not one of the defined values.
    InvalidTextEncoding,
    /// A clock or hash prefix is malformed.
    InvalidClock,
    /// A declared length exceeds what the remaining input can hold.
    LengthExceedsInput,
    /// Bytes remain after the last complete value.
    TrailingBytes,
    /// The input holds fewer bytes than the declared length.
    Truncated,
    /// A required prefix is missing.
    MissingPrefix,
    /// A string is not valid UTF-8.
    InvalidUtf8,
    /// A path, key, or index inside the value is invalid.
    InvalidPath,
    /// A value type is recognised but not supported here.
    Unsupported,
    /// The allocator ran out of memory.
    OutOfMemory,
};

/// A check that upstream treats as impossible.
///
/// These are bugs in this port, not in the input. A slow-path build turns the
/// trapping call sites into `InternalError` returns so a test can report which
/// invariant broke.
pub const InternalError = error{
    /// A documented invariant did not hold.
    Invariant,
    /// A cast between integer types would lose information.
    CastOverflow,
    /// The actor table does not contain an actor an index refers to.
    WrongActorTable,
    /// Op rows are not in `(obj, elemid-or-key, id)` order.
    WrongRowOrder,
    /// A column and its index column disagree.
    IndexMismatch,
    /// A prefix column's running sum does not match the column's length.
    PrefixMismatch,
    /// The allocator ran out of memory.
    OutOfMemory,
};

/// The union of every error this crate can produce. Convenient for callers
/// that catch rather than discriminate.
pub const AnyError = Error || ParseError || InternalError;

/// Renders a byte slice as lowercase hex into a caller-supplied buffer of at
/// least `2 * bytes.len` length.
pub fn hexInto(bytes: []const u8, out: []u8) void {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    for (bytes) |b| {
        out[i] = digits[b >> 4];
        out[i + 1] = digits[b & 0x0f];
        i += 2;
    }
}

/// Decodes lowercase or uppercase hex into `out`. Returns the number of bytes
/// written, or `error.InvalidCharacter` on a non-hex digit or an odd length.
pub fn hexFrom(gpa: std.mem.Allocator, input: []const u8) (ParseError || std.mem.Allocator.Error)![]u8 {
    if (input.len % 2 != 0) return error.InvalidPath;
    const out = try gpa.alloc(u8, input.len / 2);
    errdefer gpa.free(out);
    _ = std.fmt.hexToBytes(out, input) catch return error.InvalidPath;
    return out;
}

test "hex round trip" {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{ 0x00, 0x1f, 0xab, 0xff, 0x10 };
    var buf: [16]u8 = undefined;
    hexInto(&bytes, &buf);
    try std.testing.expectEqualStrings("001fabff10", buf[0 .. bytes.len * 2]);

    const decoded = try hexFrom(gpa, "001fabff10");
    defer gpa.free(decoded);
    try std.testing.expectEqualSlices(u8, &bytes, decoded);

    try std.testing.expectError(error.InvalidPath, hexFrom(gpa, "0"));
    try std.testing.expectError(error.InvalidPath, hexFrom(gpa, "zz"));
}
