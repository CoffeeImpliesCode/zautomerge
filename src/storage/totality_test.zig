//! The totality regression suite for the storage read path.
//!
//! Parsers must reject untrusted input without panic, unbounded loops, or unchecked allocation sizes.
//! The eight upstream `tests/fuzz-crashers/` fixtures are embedded below.
//! The suite needs no filesystem access for these inputs.
//!
//! Total does not mean "does not crash". Every input here has to answer with
//! **a named `ParseError` variant** and not merely with "an error", because a
//! caller branches on the variant, and in bounded time, and within a bounded
//! allocation. So:
//!
//! * **Named.** Each of the eight fixtures has its own pinned error at the
//!   storage layer, and its own pinned error at the whole load path. A
//!   mismatch prints the fixture name and the two variants.
//! * **Bounded in time — the argument.** Every loop in the parsers under test
//!   has a trip count that is a function of the input, and there are only
//!   three shapes. (1) A chunk is at least `magic + checksum + type +
//!   uleb128(0)` = 10 bytes long, so `chunk.parseChunks`'s
//!   `while (!in.isEmpty())` (`chunk.zig:263`) runs at most `bytes.len / 10`
//!   times and reads a length against `in.remaining()` before it takes
//!   anything (`chunk.zig:287`). (2) A count read through
//!   `parse.Input.readCountThen` is proved against the bytes that are left
//!   *before* the callback that may allocate ever sees it
//!   (`parse.zig:231-235`), so the loops that walk a counted section — the
//!   dependency list, the actor table, the head list, the two column metadata
//!   blocks — each run at most `remaining() / min_item_size` times. (3) The
//!   one loop whose trip count is not a function of the input is the DEFLATE
//!   decoder in `chunk.decompressRaw` (`chunk.zig:223`), whose work is the
//!   inflated length; that one is *measured* here rather than argued, and
//!   [`de hostile`] is the test that measures it.
//! * **Bounded in time — the check.** An argument is not a measurement, so a
//!   watchdog thread runs beside every sweep ([`watchdogMain`]). If a sweep
//!   has not finished within [`watchdog_budget_ns`] it prints **the exact
//!   input under test** — which [`describeCurrent`] keeps up to date — and
//!   aborts the process. A hang is the one failure a test cannot assert its
//!   way out of, so it is reported rather than waited on.
//! * **Bounded in allocation.** Every parse in this file goes through
//!   [`Meter`], which refuses any single allocation over
//!   [`max_single_allocation`] bytes and records the peak. The suite then
//!   asserts the budget was never hit ([`budget_hits`] is zero), which is the
//!   statement that no declared length in these inputs ever reached an
//!   allocation.
//!
//! ## Beyond the eight
//!
//! Eight inputs are a regression suite, not a fuzz campaign, so the same
//! discipline is applied to the inputs nobody has found: every fixture cut at
//! every length ([`truncated`]), every declared length field of every fixture
//! rewritten to `0`, `1`, `usize` and `usize/2` ([`length fields`]), and every
//! single bit flipped at every offset of every fixture — 7 144 mutations,
//! exhaustive rather than sampled — plus a seeded sweep of random byte
//! replacements ([`seeded`]). Mutations of a chunk *body* are re-framed with
//! [`chunk.writeChunk`], which recomputes the checksum
//! (`chunk.zig:111-123`); without that every body mutation dies at
//! `InvalidChecksum` and the body parsers never see anything.
//!
//! `std.testing.allocator` is the arbiter underneath every allocator here, so
//! a leak on any path of any of the ~20 000 parses below fails the test that
//! caused it.

const std = @import("std");

const chunk = @import("chunk.zig");
const change_chunk = @import("change_chunk.zig");
const document_chunk = @import("document_chunk.zig");
const parse = @import("parse.zig");

const doc_mod = @import("../doc.zig");
const err = @import("../error.zig");
const leb128 = @import("../leb128.zig");
const types = @import("../types.zig");

const ParseError = err.ParseError;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const gpa = testing.allocator;

const ChunkType = chunk.ChunkType;

// ── the eight upstream fuzz crashers ──────────────────────────────────────

/// `rust/automerge/tests/fuzz-crashers/action-is-48.automerge`, 58 bytes.
///
/// A `change` chunk: magic, checksum, type 1, `uleb128(48)`, then a 48-byte
/// body. The actor is sixteen `0x30` bytes, the message is empty, and the op
/// block's `action` column carries the code 48, which is not one of the eight
/// action codes.
const action_is_48 = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0xcd, 0x7c, 0xc7, 0x99, 0x01, 0x30, 0x00, 0x10,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x06, 0x15, 0x03,
    0x34, 0x01, 0x42, 0x02, 0x56, 0x02, 0x61, 0x02, 0x70, 0x02, 0x30, 0x01,
    0x30, 0x30, 0x01, 0x30, 0x7f, 0x06, 0xd0, 0x0f, 0x7f, 0x00,
};

/// `crash-da39a3ee5e6b4b0d3255bfef95601890afd80709`, 10 bytes: a `document`
/// chunk whose declared body length is zero. The SHA-1 in the name is the
/// empty string, which is how upstream filed it.
const crash_da39 = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x96, 0xa2, 0x96, 0xd2, 0x00, 0x00,
};

/// `incorrect_max_op.automerge`, 126 bytes: a `document` chunk holding one
/// change whose stored head hash is not the one the change graph derives.
const incorrect_max_op = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0xf2, 0x2b, 0x17, 0xd4, 0x00, 0x74, 0x01, 0x10,
    0x02, 0x51, 0xa6, 0x70, 0xc0, 0xd1, 0x4f, 0x52, 0x80, 0x6a, 0x06, 0xcc,
    0x23, 0x75, 0x74, 0xa3, 0x01, 0xb7, 0x84, 0x6e, 0x2f, 0x9b, 0x5c, 0x6c,
    0xaa, 0xde, 0xc8, 0xd6, 0x5a, 0xf8, 0x61, 0xcd, 0x29, 0x30, 0x49, 0x1e,
    0x88, 0x65, 0x23, 0x28, 0x90, 0x1d, 0x52, 0xac, 0x7c, 0xa8, 0xcc, 0xb2,
    0x24, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02, 0x40, 0x02,
    0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x23, 0x02, 0x34, 0x01, 0x42,
    0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x02, 0x7f, 0x00, 0x7f, 0x01,
    0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x04, 0x6f, 0x01,
    0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x01, 0x7f, 0x01, 0x7f, 0x46, 0x6f,
    0x00, 0x70, 0x73, 0x7f, 0x00, 0x00,
};

/// `invalid_deflate_stream.automerge`, 123 bytes: a `document` chunk whose
/// body is a column stream that claims a DEFLATE column and then carries
/// bytes that are not a DEFLATE stream. The chunk's own header checksum is
/// also wrong, so the framing refuses it first and the DEFLATE stream is
/// never reached — which is what [`crashers`] records.
const invalid_deflate_stream = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x30, 0x30, 0x30, 0x30, 0x00, 0x71, 0x01, 0x10,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x01, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x06, 0x01, 0x02, 0x03, 0x02, 0x20, 0x02, 0x30, 0x02, 0x31, 0x02,
    0x31, 0x02, 0x08, 0x20, 0x04, 0x21, 0x02, 0x30, 0x02, 0x31, 0x01, 0x31,
    0x02, 0x39, 0x02, 0x57, 0x03, 0x80, 0x01, 0x02, 0x7f, 0x00, 0x7f, 0x01,
    0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x02, 0x66, 0x7a,
    0x7f, 0x00, 0x7f, 0x01, 0x01, 0x7f, 0x01, 0x7f, 0x36, 0xef, 0xbf, 0xbd,
    0x7f, 0x00, 0x00,
};

/// `missing_actor.automerge`, 126 bytes: a `document` chunk whose op rows
/// name an actor index the actor table does not hold, and whose value column
/// does not decode to the type its metadata word declares.
const missing_actor = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x07, 0x73, 0xe5, 0xd8, 0x00, 0x74, 0x01, 0x10,
    0xef, 0xb0, 0xbc, 0x54, 0x89, 0x8b, 0x42, 0xd2, 0x8f, 0x85, 0xf7, 0x99,
    0x96, 0x72, 0x14, 0xe8, 0x01, 0x98, 0x19, 0xd0, 0x2a, 0x7b, 0x77, 0x32,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0xfd, 0xc6, 0xda, 0x19,
    0xf9, 0xff, 0xff, 0x00, 0x0b, 0x96, 0x6b, 0x5d, 0x28, 0xf3, 0x59, 0xc7,
    0x9b, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02, 0x40, 0x02,
    0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x24, 0x02, 0x34, 0x01, 0x42,
    0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x02, 0x7f, 0x04, 0x7f, 0x01,
    0x7f, 0x01, 0x7f, 0x00, 0x77, 0x00, 0x7f, 0x07, 0x7f, 0x04, 0x6f, 0x00,
    0x70, 0x73, 0x7f, 0x00, 0x7f, 0x01, 0x01, 0x7f, 0x03, 0x38, 0x46, 0x6f,
    0x6f, 0x70, 0xdb, 0x7f, 0x00, 0x00,
};

/// `overflow_in_length.automerge`, 182 bytes: a `document` chunk with a
/// two-byte body length and a column set whose declared lengths do not fit the
/// data block. The metadata block is *also* out of normalized order, and
/// upstream reports the order first (`raw_column.rs:248-253` against
/// `document.rs:124-129`), so the answer is `InvalidColumnSpec` and not
/// `LengthExceedsInput` — the same choice `document_chunk.zig` §What the
/// reader enforces records.
const overflow_in_length = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x0d, 0x5a, 0x0a, 0x63, 0x00, 0xab, 0x01, 0x01,
    0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0xe3, 0x85, 0x6f, 0x4a,
    0xe3, 0xe3, 0xe3, 0x85, 0x6f, 0x4a, 0x83, 0xe3, 0xe3, 0xe3, 0xe3, 0xe1,
    0xe3, 0xe3, 0x70, 0xd6, 0x70, 0x70, 0x70, 0x70, 0x70, 0x83, 0xe3, 0x1d,
    0x18, 0xe3, 0xe3, 0x2f, 0xe1, 0xe3, 0x4a, 0x83, 0xe3, 0xe3, 0xe3, 0xe3,
    0xe1, 0xe3, 0xd6, 0x70, 0x70, 0x70, 0x70, 0x70, 0x83, 0xe3, 0x1d, 0x18,
    0xe3, 0xe3, 0x2f, 0xe3, 0xe3, 0xe3, 0xff, 0xff, 0xff, 0xff, 0xff, 0x27,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00,
    0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x02, 0x01, 0x07, 0x5d, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xe3, 0xe3, 0xe3, 0xe3, 0x04, 0x70, 0x70,
    0x70, 0x70, 0x70, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x07, 0x5d,
    0x01, 0x00,
};

/// `too_many_deps.automerge`, 134 bytes: a `document` chunk whose one change
/// declares a dependency count the body cannot hold.
const too_many_deps = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x9d, 0x67, 0x5b, 0x20, 0x00, 0x7c, 0x01, 0x10,
    0xef, 0xb0, 0xbc, 0x54, 0x89, 0x8b, 0x42, 0xd2, 0x8f, 0x85, 0xf7, 0x99,
    0x70, 0x72, 0x14, 0xe8, 0x01, 0x98, 0x19, 0xd0, 0x2a, 0x7b, 0x77, 0xc3,
    0x8b, 0xa5, 0x2c, 0xd4, 0xf0, 0xeb, 0x47, 0x21, 0xfd, 0xc6, 0xda, 0x19,
    0x02, 0xf9, 0x2c, 0x42, 0x03, 0x96, 0x6b, 0x5d, 0x28, 0xf3, 0x59, 0xc7,
    0x9b, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02, 0x40, 0x0a,
    0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x23, 0x02, 0x34, 0x01, 0x42,
    0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x02, 0x7f, 0x00, 0x7f, 0x01,
    0x7f, 0x01, 0x7f, 0x00, 0x7f, 0xea, 0xea, 0xea, 0xea, 0xea, 0xea, 0xea,
    0xea, 0x00, 0x7f, 0x07, 0x7f, 0x04, 0x6f, 0x00, 0x70, 0x73, 0x7f, 0x00,
    0x7f, 0x01, 0x01, 0xbb, 0x01, 0x7f, 0x46, 0x6f, 0x6f, 0x70, 0x73, 0x7f,
    0x00, 0x00,
};

/// `too_many_ops.automerge`, 134 bytes: a `document` chunk whose one change
/// declares an op count the columns cannot hold. Identical to
/// `too_many_deps` except in the two bytes that carry the declaration.
const too_many_ops = [_]u8{
    0x85, 0x6f, 0x4a, 0x83, 0x55, 0xcf, 0x40, 0xcd, 0x00, 0x7c, 0x01, 0x10,
    0xef, 0xb0, 0xbc, 0x54, 0x89, 0x9b, 0x42, 0xd2, 0x8f, 0x85, 0xf7, 0x99,
    0x70, 0x72, 0x14, 0xe8, 0x01, 0x98, 0x19, 0xd0, 0x2a, 0x7b, 0x77, 0xc3,
    0x8b, 0xa5, 0x2c, 0xd4, 0xf0, 0xeb, 0x47, 0x21, 0xfd, 0xc6, 0xda, 0x19,
    0x02, 0xf9, 0x2c, 0x42, 0x03, 0x96, 0x6b, 0x5d, 0x28, 0xf3, 0x59, 0xc7,
    0x9b, 0x06, 0x01, 0x02, 0x03, 0x02, 0x13, 0x02, 0x23, 0x02, 0x40, 0x02,
    0x56, 0x02, 0x08, 0x15, 0x06, 0x21, 0x02, 0x23, 0x02, 0x34, 0x01, 0x42,
    0x02, 0x56, 0x02, 0x57, 0x04, 0x80, 0x01, 0x0a, 0x7f, 0x00, 0x7f, 0x01,
    0x7f, 0x01, 0x7f, 0x00, 0x7f, 0x00, 0x7f, 0x07, 0x7f, 0x04, 0x6f, 0x00,
    0x70, 0x73, 0x7f, 0x00, 0x7f, 0x01, 0x01, 0x7f, 0x01, 0x7f, 0x46, 0x6f,
    0x6f, 0x70, 0x73, 0x7f, 0x9d, 0x9d, 0x9d, 0x9d, 0x9d, 0x9d, 0x9d, 0x9d,
    0x00, 0x00,
};

/// One upstream fuzz crasher and the two verdicts the port has to produce for
/// it.
const Crasher = struct {
    /// The file it is, without the directory.
    name: []const u8,
    /// The file, byte for byte.
    bytes: []const u8,
    /// What the **storage layer** — the framing and the body parser the chunk
    /// type selects — does with it. Null means the storage layer accepted the
    /// file, which is a real answer and not a gap: the defect these files
    /// carry lives in a layer above the storage one, and a storage parser
    /// that invented a refusal for a body it has no rule about would be
    /// refusing documents automerge itself wrote.
    storage: ?ParseError,
    /// What the **whole load path** does with it, which is where the remaining
    /// five are caught.
    loader: doc_mod.LoadError,
};

/// The eight fixtures of `rust/automerge/tests/fuzz-crashers/`, which
/// `tests/test.rs:2210-2219` asserts are errors to load.
const crashers = [_]Crasher{
    // A `change` chunk: the storage layer reads the header and the column
    // set, and the action code 48 is in a column's bytes, so nothing below
    // the columnar op decoder can see it.
    .{
        .name = "action-is-48.automerge",
        .bytes = &action_is_48,
        .storage = null,
        .loader = error.InvalidAction,
    },
    // A `document` chunk with an empty body: the actor count cannot even be
    // read.
    .{
        .name = "crash-da39a3ee5e6b4b0d3255bfef95601890afd80709",
        .bytes = &crash_da39,
        .storage = error.UnexpectedEnd,
        .loader = error.UnexpectedEnd,
    },
    // A well-formed document chunk whose stored head is not the derived one.
    .{
        .name = "incorrect_max_op.automerge",
        .bytes = &incorrect_max_op,
        .storage = null,
        .loader = error.MissingHash,
    },
    // Refused by the framing itself: the header checksum does not cover the
    // body, so the bad DEFLATE stream inside it is never reached.
    .{
        .name = "invalid_deflate_stream.automerge",
        .bytes = &invalid_deflate_stream,
        .storage = error.InvalidChecksum,
        .loader = error.InvalidChecksum,
    },
    // The op rows name an actor the table does not hold, and a value column
    // that does not decode: both are the columnar layer's to refuse.
    .{
        .name = "missing_actor.automerge",
        .bytes = &missing_actor,
        .storage = null,
        .loader = error.InvalidValue,
    },
    // Out of order before too long, which is upstream's order of checks.
    .{
        .name = "overflow_in_length.automerge",
        .bytes = &overflow_in_length,
        .storage = error.InvalidColumnSpec,
        .loader = error.InvalidColumnSpec,
    },
    .{
        .name = "too_many_deps.automerge",
        .bytes = &too_many_deps,
        .storage = null,
        .loader = error.UnexpectedEnd,
    },
    .{
        .name = "too_many_ops.automerge",
        .bytes = &too_many_ops,
        .storage = null,
        .loader = error.InvalidLeb128,
    },
};

// ── the read paths under test ─────────────────────────────────────────────

/// Runs the whole storage read path over `bytes`: `chunk.parseChunks`, then
/// the body parser the chunk type selects.
///
/// * `document` → `document_chunk.parseFramedChunk`
/// * `change`, `compressed` → `change_chunk.parseFramedChunk`
/// * `bundle` → nothing: a bundle is a set of chunks, and `storage/bundle.zig`
///   owns it, so a `bundle` chunk is framed and nothing more here.
fn storageRead(bytes: []const u8, alloc: Allocator) ParseError!void {
    const chunks = try chunk.parseChunks(bytes, alloc);
    defer alloc.free(chunks);
    for (chunks) |c| switch (c.typ) {
        .document => {
            var d = try document_chunk.parseFramedChunk(c, alloc);
            d.deinit(alloc);
        },
        .change, .compressed => {
            var o = try change_chunk.parseFramedChunk(c, alloc);
            o.deinit(alloc);
        },
        .bundle => {},
    };
}

/// The whole document load path, which is where the five crashers the storage
/// layer accepts are caught. It is driven on the eight fixtures and on nothing
/// else: the sweeps below go through [`storageRead`] so that a failure points
/// at a parser in this slice rather than at one above it.
fn loadRead(bytes: []const u8) doc_mod.LoadError!void {
    var doc = try doc_mod.Document.load(
        gpa,
        std.testing.io,
        bytes,
        doc_mod.defaultTextEncoding(),
    );
    doc.deinit();
}

// ── the allocator the whole file is measured through ──────────────────────

/// The largest single allocation any parse of these inputs is allowed to ask
/// for. Every fixture is at most 182 bytes, so a legitimate parse needs
/// kilobytes; a declared length that reached an allocation would ask for
/// gigabytes. A megabyte is the ceiling: high enough that no honest parse
/// touches it, low enough that a length field turned loose is caught rather
/// than served.
const max_single_allocation: usize = 1 << 20;

/// An allocator that refuses an allocation over [`max_single_allocation`] and
/// counts what it hands out, so the suite can state a bound instead of
/// implying one.
///
/// It wraps `std.testing.allocator`, so every byte it forwards is still
/// checked for a leak at the end of the test that used it.
const Meter = struct {
    inner: Allocator,
    /// Bytes currently handed out and not yet returned.
    live: usize = 0,
    /// The high-water mark of `live`.
    peak_live: usize = 0,
    /// The largest single allocation ever granted.
    peak_single: usize = 0,
    /// How many allocations ever succeeded.
    granted: usize = 0,
    /// How many were refused for being over [`max_single_allocation`]. The
    /// suite asserts this stays zero: a non-zero value means some parse tried
    /// to size an allocation from a declared length.
    budget_hits: usize = 0,

    fn allocator(self: *Meter) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    /// Zeroes the counters. The allocator itself stays valid, so a test that
    /// wants its own budget starts from a clean measurement.
    fn reset(self: *Meter) void {
        self.* = .{ .inner = self.inner };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        if (len > max_single_allocation) {
            self.budget_hits += 1;
            return null;
        }
        const out = self.inner.rawAlloc(len, alignment, ra) orelse return null;
        self.live += len;
        self.peak_live = @max(self.peak_live, self.live);
        self.peak_single = @max(self.peak_single, len);
        self.granted += 1;
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        if (new_len > max_single_allocation) {
            self.budget_hits += 1;
            return false;
        }
        if (!self.inner.rawResize(memory, alignment, new_len, ra)) return false;
        if (new_len > memory.len) {
            self.live += new_len - memory.len;
            self.peak_single = @max(self.peak_single, new_len);
        } else {
            self.live -= memory.len - new_len;
        }
        self.peak_live = @max(self.peak_live, self.live);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        if (new_len > max_single_allocation) {
            self.budget_hits += 1;
            return null;
        }
        const out = self.inner.rawRemap(memory, alignment, new_len, ra) orelse return null;
        if (new_len > memory.len) {
            self.live += new_len - memory.len;
            self.peak_single = @max(self.peak_single, new_len);
        } else {
            self.live -= memory.len - new_len;
        }
        self.peak_live = @max(self.peak_live, self.live);
        return out;
    }

    fn free(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Meter = @ptrCast(@alignCast(ctx));
        self.live -= old_mem.len;
        self.inner.rawFree(old_mem, alignment, ra);
    }
};

/// The meter every parse in this file goes through. Its `live` must be back
/// to zero whenever a test finishes; a non-zero value is a leak that
/// `std.testing.allocator` would also report, and this one names.
var meter: Meter = .{ .inner = gpa };

/// Reports the meter's high-water marks and asserts the budget was never hit.
/// Called at the end of every sweep.
fn assertBounded(label: []const u8) !void {
    std.debug.print(
        "totality: {s}: {d} allocations, peak live {d} B, largest single {d} B, budget hits {d}\n",
        .{ label, meter.granted, meter.peak_live, meter.peak_single, meter.budget_hits },
    );
    if (meter.budget_hits != 0) {
        std.debug.print("totality: {s}: a parse sized an allocation from a declared length\n", .{label});
        return error.UnboundedAllocation;
    }
    if (meter.live != 0) {
        std.debug.print("totality: {s}: {d} bytes still held at the end of the sweep\n", .{ label, meter.live });
        return error.Leak;
    }
}

// ── the hang watchdog ─────────────────────────────────────────────────────

/// How long one sweep may take before the watchdog calls it a hang. The
/// sweeps below are ~20 000 parses of at most 182 bytes and finish in
/// milliseconds; a minute is three orders of magnitude of headroom, and it is
/// a ceiling rather than a measurement.
const watchdog_budget_ns: i128 = 60 * std.time.ns_per_s;

var sweep_running = std.atomic.Value(bool).init(false);

/// The input the main thread is parsing right now, as a human-readable line.
/// [`describeCurrent`] writes it before every parse; [`watchdogMain`] reads it
/// if the budget ever expires, which is the only way a hang gets reported
/// against the input that caused it.
var current_input: [256]u8 = undefined;
var current_input_len = std.atomic.Value(usize).init(0);

/// Records the input about to be parsed, so a hang has something to name.
fn describeCurrent(comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.bufPrint(current_input[0..], fmt, args) catch return;
    current_input_len.store(line.len, .release);
}

/// Sleeps by spinning, which is free in the normal case because the sweep
/// finishes long before the budget and the thread is joined immediately after.
fn watchdogMain(io: std.Io) void {
    const started = std.Io.Timestamp.now(io, .boot);
    while (sweep_running.load(.acquire)) {
        const elapsed = started.durationTo(.now(io, .boot)).nanoseconds;
        if (elapsed > watchdog_budget_ns) {
            const n = current_input_len.load(.acquire);
            std.debug.print(
                "\ntotality: HUNG. No parse finished within {d} s.\n" ++
                    "totality: the input under test is: {s}\n" ++
                    "totality: a parser in the storage read path does not terminate on it.\n",
                .{ @divTrunc(watchdog_budget_ns, std.time.ns_per_s), current_input[0..n] },
            );
            std.process.abort();
        }
        std.atomic.spinLoopHint();
    }
}

/// Starts the watchdog for one sweep and returns the thread to join when the
/// sweep is done. The clock is the single-threaded `Io`, which needs no
/// teardown and is only ever asked for the time.
fn startWatchdog() std.Thread {
    sweep_running.store(true, .release);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    return std.Thread.spawn(.{}, watchdogMain, .{io}) catch
        @panic("totality: cannot spawn the watchdog");
}

fn stopWatchdog(watchdog: std.Thread) void {
    sweep_running.store(false, .release);
    watchdog.join();
}

// ── mutation helpers ──────────────────────────────────────────────────────

/// A frame of at most this many bytes: the longest fixture is 182 bytes and a
/// length field is replaced by at most a 10-byte LEB128, so a mutated fixture
/// is at most 182 + 9 + 10 bytes. The margin is for the re-framing overhead.
const frame_capacity = 512;

/// Wraps `body` in a chunk of type `typ` with a **correct** checksum, so the
/// framing accepts it and the body parsers see the mutated bytes.
///
/// Without this every body mutation is refused by `error.InvalidChecksum` at
/// `chunk.zig:293-295` and the parsers this file is about are never reached.
fn reframe(typ: ChunkType, body: []const u8, out: []u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try chunk.writeChunk(&list, gpa, typ, body);
    if (list.items.len > out.len) return error.FrameTooLong;
    @memcpy(out[0..list.items.len], list.items);
    return out[0..list.items.len];
}

/// Prints a fixture name, a description of the mutation, and the mutated
/// bytes, and fails. Every failure message in this file goes through here, so
/// a failure always names the input it came from.
fn failMutation(
    comptime fmt: []const u8,
    args: anytype,
    name: []const u8,
    what: []const u8,
    bytes: []const u8,
) error{MutationAccepted} {
    std.debug.print("totality: " ++ fmt ++ "\n", args);
    std.debug.print("totality:   fixture  {s}\n", .{name});
    std.debug.print("totality:   mutation {s}\n", .{what});
    std.debug.print("totality:   bytes    {x}\n", .{bytes});
    return error.MutationAccepted;
}

/// The `uleb128` width of a fixture's declared body length, which is where its
/// header ends: `magic(4) + checksum(4) + type(1) + width`.
fn headerLen(bytes: []const u8) usize {
    var in: parse.Input = .init(bytes[9..]);
    _ = in.takeUleb() catch return bytes.len + 1;
    return 9 + in.pos;
}

// ── locating the declared length fields of a body ─────────────────────────

const FieldKind = enum {
    /// A count proved by `readCountThen`, whose bound is a comparison against
    /// the bytes that are left (`parse.zig:231-235`). An impossible count is
    /// `LengthExceedsInput` on every target.
    count,
    /// A length prefix of a byte string, proved by `strWindow`
    /// (`parse.zig:242-249`). Also `LengthExceedsInput` on every target.
    string_len,
    /// A column's declared byte length, read into a `usize` by
    /// `change_chunk.DescSink.collect` / `document_chunk.readColumnMeta`. On
    /// a target narrower than 64 bits a length that is not a `usize` is
    /// refused as `TooLarge` at the cast (`change_chunk.zig:683`) before the
    /// sum that would report `LengthExceedsInput`.
    column_len,
};

const Field = struct {
    /// What the field is called in the format's own layout comment.
    name: []const u8,
    /// Where its LEB128 starts, relative to the body.
    offset: usize,
    /// How many bytes its LEB128 occupies in the unmutated body, so the
    /// replacement does not leave a fragment of the old encoding behind.
    width: usize,
    kind: FieldKind,
};

/// The most length fields one body is allowed to declare. A document chunk's
/// is a handful — an actor length, a head count, two column counts and one
/// length per column — and a fixture is a fixture, not an adversarial
/// document, so a fixed array is enough and a body that declares more is a
/// recorded stopping point rather than a silent truncation.
const max_fields = 128;

const FieldList = struct {
    items: [max_fields]Field = undefined,
    len: usize = 0,
    /// The error that stopped the walk, or null when it reached the end of the
    /// body. A body the walk cannot finish still contributes every field
    /// *before* the stopping point, and those are the ones worth mutating:
    /// `overflow_in_length` declares column lengths that run past its own end,
    /// which is the whole point of the file, and the fields before them are
    /// exactly the ones a hostile length belongs in.
    stopped: ?anyerror = null,

    const Error = ParseError || error{TooManyFields};

    fn add(self: *FieldList, name: []const u8, start: usize, width: usize, kind: FieldKind) Error!void {
        if (self.len == max_fields) return error.TooManyFields;
        self.items[self.len] = .{ .name = name, .offset = start, .width = width, .kind = kind };
        self.len += 1;
    }
};

/// Walks a change chunk body and records every declared count and length.
///
/// The walker is a parser, so it is bounded the same way the parsers are: a
/// count is proved against `remaining()` **before** the loop that walks it, so
/// a hostile count costs a comparison and not a spin. The one count this
/// walker reads as a bare `takeUleb` — the column count — is proved against
/// two bytes per column, the same floor `change_chunk.min_desc_size` uses
/// (`change_chunk.zig:429`).
fn changeBodyFields(list: *FieldList, body: []const u8) FieldList.Error!void {
    var in: parse.Input = .init(body);

    const deps_at = in.pos;
    const deps = try in.takeUleb();
    try list.add("deps", deps_at, in.pos - deps_at, .count);
    if (deps > in.remaining() / types.hash_size) return error.LengthExceedsInput;
    _ = try in.take(deps * types.hash_size);

    const actor_at = in.pos;
    _ = try in.readStrBytes();
    try list.add("actor", actor_at, in.pos - actor_at, .string_len);

    _ = try in.takeUleb(); // seq
    _ = try in.takeUleb(); // start_op, which the reader refuses when it is zero
    _ = try in.takeLeb(); // time

    const msg_at = in.pos;
    _ = try in.readStr();
    try list.add("message", msg_at, in.pos - msg_at, .string_len);

    const others_at = in.pos;
    const others = try in.takeUleb();
    try list.add("other_actors", others_at, in.pos - others_at, .count);
    if (others > in.remaining()) return error.LengthExceedsInput;
    var i: usize = 0;
    while (i < others) : (i += 1) {
        const at = in.pos;
        _ = try in.readStrBytes();
        try list.add("other_actor", at, in.pos - at, .string_len);
    }

    // The op data block is the last region of a change body, so its length is
    // read and not stepped over: nothing follows it to misalign.
    _ = try columnMetaFields(list, &in, "ops");
}

/// Walks a document chunk body and records every declared count and length.
///
/// A document body is four regions and the order matters: the actor table,
/// the head list, then **both** column metadata blocks, and only then the two
/// data blocks (`document.rs:112-129`). So the change data has to be stepped
/// over before the op metadata can be read.
///
/// The walk finishes by checking the body against the format's own tail rule:
/// what follows the op data is either nothing or exactly `heads.len()`
/// LEB128 values (`document.rs:131-136`). That check is what makes a
/// completed walk worth trusting — a walk that reaches the end *and* leaves
/// the cursor exactly at the end of the body has agreed with the reader
/// about where every region is, and only then are the offsets it recorded
/// the offsets of real length fields. A walk that cannot finish says so
/// through `FieldList.stopped`, and the test falls back to asserting only
/// totality for it.
fn documentBodyFields(list: *FieldList, body: []const u8) FieldList.Error!void {
    var in: parse.Input = .init(body);

    const actors_at = in.pos;
    const actors = try in.takeUleb();
    try list.add("actors", actors_at, in.pos - actors_at, .count);
    if (actors > in.remaining()) return error.LengthExceedsInput;
    var i: usize = 0;
    while (i < actors) : (i += 1) {
        const at = in.pos;
        _ = try in.readStrBytes();
        try list.add("actor", at, in.pos - at, .string_len);
    }

    const heads_at = in.pos;
    const heads = try in.takeUleb();
    try list.add("heads", heads_at, in.pos - heads_at, .count);
    if (heads > in.remaining() / types.hash_size) return error.LengthExceedsInput;
    _ = try in.take(heads * types.hash_size);

    const change_len = try columnMetaFields(list, &in, "changes");
    _ = try in.take(change_len);
    // The op data block is followed by the optional head-index suffix: a run
    // of `heads.len()` LEB128 values with no count of its own, so it declares
    // no length field. Consuming it and requiring the cursor to land exactly
    // at the end of the body is the walk's own proof of correctness.
    const op_len = try columnMetaFields(list, &in, "ops");
    _ = try in.take(op_len);
    // A body with nothing left after the op data has no suffix at all, for
    // the output of an older JS implementation (`document.rs:131-135`); one
    // with something left must hold exactly `heads.len()` values
    // (`:133-136`).
    if (in.isEmpty()) return;
    if (in.remaining() < heads) return error.UnexpectedEnd;
    var k: usize = 0;
    while (k < heads) : (k += 1) _ = try in.takeUleb();
    if (!in.isEmpty()) return error.TrailingBytes;
}

/// The column count and each column's declared length, and the sum of those
/// lengths: the length of the data block the metadata block describes.
///
/// A specification is not a length and is walked past, not recorded: it is a
/// `u32`, and an impossible one is `Overflow`, which is a different claim
/// from the one under test.
fn columnMetaFields(list: *FieldList, in: *parse.Input, what: []const u8) FieldList.Error!usize {
    const min_desc_size: usize = 2; // change_chunk.zig:429
    const count_at = in.pos;
    const count = try in.takeUleb();
    try list.add(
        if (std.mem.eql(u8, what, "ops")) "op_columns" else "change_columns",
        count_at,
        in.pos - count_at,
        .count,
    );
    if (count > in.remaining() / min_desc_size) return error.LengthExceedsInput;
    // The sum saturates, as the readers' does (`raw_column.rs:235-239`), so a
    // hostile length costs a comparison rather than a wrapped offset.
    var total: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = try in.takeUleb(); // the specification
        const at = in.pos;
        const len = try in.takeUleb();
        try list.add("column_len", at, in.pos - at, .column_len);
        const n = std.math.cast(usize, len) orelse return error.TooLarge;
        total = total +| n;
    }
    return total;
}

/// The length fields `body` declares, walked the way its chunk type is. This
/// never fails: it records the fields it finds and the error that stopped it,
/// so a body that cannot be walked to the end still contributes its prefix.
fn fieldsOf(typ: ChunkType, body: []const u8) FieldList {
    var list: FieldList = .{};
    const walk = switch (typ) {
        .change => changeBodyFields(&list, body),
        .document => documentBodyFields(&list, body),
        // A compressed chunk's body is a DEFLATE stream, not a body, and a
        // bundle chunk is a set of chunks. Neither declares length fields in
        // the sense this file means.
        .compressed, .bundle => return list,
    };
    walk catch |e| {
        list.stopped = e;
        return list;
    };
    return list;
}

/// Whether the format forces exactly one refusal for a field of this kind, and
/// which.
///
/// A count and a string length are checked where they are read, before
/// anything else runs and before the field can influence any other part of
/// the body, so `error.LengthExceedsInput` is the whole answer for them
/// (`parse.zig:231-235` for a count, `:242-249` for a string length). The
/// test asserts that variant exactly.
///
/// A column's declared length is different, and the difference is upstream's
/// order of checks rather than this port's: the sum that catches it is
/// compared against what is left of the body only *after* the metadata block
/// has been read and its specifications have been put in order
/// (`raw_column.rs:248-253` against `document.rs:124-129`). So which refusal a
/// hostile column length earns depends on the body it is put in — a set
/// already out of order is refused as `InvalidColumnSpec` first, which is what
/// `test/fixtures/overflow_in_length.automerge` is. This test therefore
/// asserts that the mutation is *refused by name* and never reaches an
/// allocation, and records which variant each one earned.
fn forcedRefusal(kind: FieldKind) bool {
    return kind == .count or kind == .string_len;
}

/// The refusals this suite is willing to tally, so the record is a fixed set
/// of names rather than a string built at run time.
const tallied_refusals = [_]ParseError{
    error.UnexpectedEnd,
    error.LengthExceedsInput,
    error.InvalidColumnSpec,
    error.TrailingBytes,
    error.InvalidLeb128,
    error.Overflow,
    error.TooLarge,
    error.InvalidChunkType,
    error.InvalidChecksum,
    error.UnexpectedNull,
    error.DuplicateColumn,
    error.ColumnOutOfBounds,
};

const RefusalTally = struct {
    counts: [tallied_refusals.len]usize = @as([tallied_refusals.len]usize, @splat(0)),
    other: usize = 0,

    /// Prints the non-zero entries, so the run says which variant each
    /// mutation earned rather than only that it failed.
    fn report(self: RefusalTally, label: []const u8) void {
        for (self.counts, tallied_refusals) |n, e| {
            if (n == 0) continue;
            std.debug.print("totality: {s}: {d} x {s}\n", .{ label, n, @errorName(e) });
        }
        if (self.other != 0) {
            std.debug.print("totality: {s}: {d} x a refusal not in the table\n", .{ label, self.other });
        }
    }
};

/// Records one refusal. A variant outside the table is counted rather than
/// dropped, so a new error cannot pass unnoticed.
fn countRefusal(tally: *RefusalTally, e: ParseError) void {
    for (tallied_refusals, 0..) |known, i| {
        if (known == e) {
            tally.counts[i] += 1;
            return;
        }
    }
    tally.other += 1;
}

// ── tests ─────────────────────────────────────────────────────────────────
/// The load-path half of [`crashers`] is one block, and this is what switches
/// it. It is `true`: five of the eight fixtures are refused above the storage
/// layer, and the assertion that says which variant each of them earns is the
/// point of the table.
const with_loader = true;

test "the eight fuzz crashers are refused, each by a named ParseError" {
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    for (crashers) |c| {
        if (with_loader) {
            describeCurrent("{s} (whole load path)", .{c.name});
            if (loadRead(c.bytes)) |_| {
                return failMutation(
                    "the fixture loaded, and upstream asserts it is an error (tests/test.rs:2210-2219)",
                    .{},
                    c.name,
                    "unmutated",
                    c.bytes,
                );
            } else |e| {
                if (e != c.loader) {
                    return failMutation(
                        "{s} was refused with {s}, not the {s} this port pins",
                        .{ c.name, @errorName(e), @errorName(c.loader) },
                        c.name,
                        "unmutated",
                        c.bytes,
                    );
                }
            }
        }

        // The storage layer's own verdict, which is a refusal for three of
        // them and an acceptance for the other five.
        describeCurrent("{s} (storage layer)", .{c.name});
        if (storageRead(c.bytes, meter.allocator())) |_| {
            if (c.storage != null) {
                return failMutation(
                    "{s} was accepted by the storage layer, which pins {s}",
                    .{ c.name, @errorName(c.storage.?) },
                    c.name,
                    "unmutated",
                    c.bytes,
                );
            }
        } else |e| {
            const want = c.storage orelse {
                return failMutation(
                    "{s} was refused by the storage layer with {s}, which pins acceptance",
                    .{ c.name, @errorName(e) },
                    c.name,
                    "unmutated",
                    c.bytes,
                );
            };
            if (e != want) {
                return failMutation(
                    "{s} was refused with {s}, not the {s} this port pins",
                    .{ c.name, @errorName(e), @errorName(want) },
                    c.name,
                    "unmutated",
                    c.bytes,
                );
            }
        }
    }

    try testing.expectEqual(@as(usize, 8), crashers.len);
    try assertBounded("crashers");
}

test "every truncation of every fixture is refused with the framing's own error" {
    // Zero bytes is the one prefix that is not a refusal, and it is not an
    // oversight: a stream of zero chunks is a stream, and upstream's load
    // path treats empty input as an empty document rather than an error
    // (`automerge.rs:911-914`). It is asserted separately below.
    //
    // Every other prefix is a refusal, and which refusal is a function of the
    // fixture alone. A file cut to `k` bytes is either too short for the
    // 9-byte fixed header plus the length LEB128 — `error.UnexpectedEnd`,
    // which is upstream's `ParseError::Incomplete` (`parse.rs:349-353`) — or
    // it has a whole header and a body shorter than the length that header
    // declares, which is `error.LengthExceedsInput` (`chunk.zig:287`). There
    // is no third answer, and the boundary between the two is the header
    // length, which [`headerLen`] computes from the fixture.
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    var cuts: usize = 0;
    {
        // The empty prefix, asserted on its own terms.
        const empty = try chunk.parseChunks("", meter.allocator());
        defer meter.allocator().free(empty);
        try testing.expectEqual(@as(usize, 0), empty.len);
    }
    for (crashers) |c| {
        const header = headerLen(c.bytes);
        var k: usize = 1;
        while (k < c.bytes.len) : (k += 1) {
            describeCurrent("{s} cut to {d} of {d} bytes", .{ c.name, k, c.bytes.len });
            const want: ParseError = if (k < header) error.UnexpectedEnd else error.LengthExceedsInput;
            if (storageRead(c.bytes[0..k], meter.allocator())) |_| {
                return failMutation(
                    "a file cut to {d} of {d} bytes parsed, and a cut file is never a document",
                    .{ k, c.bytes.len },
                    c.name,
                    "truncation",
                    c.bytes[0..k],
                );
            } else |e| {
                if (e != want) {
                    return failMutation(
                        "a file cut to {d} of {d} bytes gave {s}, expected {s}",
                        .{ k, c.bytes.len, @errorName(e), @errorName(want) },
                        c.name,
                        "truncation",
                        c.bytes[0..k],
                    );
                }
            }
            cuts += 1;
        }
    }

    // One prefix per fixture is the empty one, which the block above asserts
    // on its own terms rather than as a refusal.
    try testing.expectEqual(crasher_bytes() - crashers.len, cuts);
    // The second cut, which the first cannot reach: a body cut short and
    // **re-framed**, so the checksum is right and the body parsers see it.
    // A cut body is often still a shorter body, so a parse here is a real
    // answer rather than a failure; what must not happen is a crash, a hang,
    // or an allocation over the budget.
    var body_cuts: usize = 0;
    var body_refusals: usize = 0;
    var frame: [frame_capacity]u8 = undefined;
    for (crashers) |c| {
        const parsed = chunk.parseChunk(c.bytes) catch continue;
        var k: usize = 0;
        while (k <= parsed.data.len) : (k += 1) {
            const framed = try reframe(parsed.typ, parsed.data[0..k], &frame);
            describeCurrent("{s} body cut to {d} of {d} bytes, re-framed", .{
                c.name, k, parsed.data.len,
            });
            if (storageRead(framed, meter.allocator())) |_| {} else |e| {
                body_refusals += 1;
                if (e == error.OutOfMemory) {
                    return failMutation(
                        "a body cut to {d} of {d} bytes exhausted the {d} byte budget",
                        .{ k, parsed.data.len, max_single_allocation },
                        c.name,
                        "truncation",
                        framed,
                    );
                }
            }
            body_cuts += 1;
        }
    }
    std.debug.print("totality: {d} file cuts, {d} body cuts, {d} of them refused\n", .{
        cuts, body_cuts, body_refusals,
    });
    try testing.expect(body_refusals > 0);
    try assertBounded("truncation");
}

test "every declared length field set to usize is refused as a length" {
    // The unchecked-allocation-size case, stated as an assertion rather than
    // as a fear. Each fixture is walked to find every count and length it
    // declares, and each one is replaced by a value no input could hold.
    //
    // On a 64-bit target `usize` is 2^64 - 1, which the strict LEB128 reader
    // accepts as a ten-byte encoding whose last byte carries the one bit that
    // is left, and `2^63 - 1` needs nine. Both are then refused by a
    // comparison, before anything is sized.
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    const values = [_]u64{ std.math.maxInt(usize), std.math.maxInt(usize) / 2 };
    const names = [_][]const u8{ "usize", "usize/2" };

    var mutations: usize = 0;
    var fields_seen: usize = 0;
    var frame: [frame_capacity]u8 = undefined;
    var scratch: [frame_capacity]u8 = undefined;
    var refusals: RefusalTally = .{};

    for (crashers) |c| {
        const parsed = chunk.parseChunk(c.bytes) catch continue;
        const list = fieldsOf(parsed.typ, parsed.data);
        // A body that cannot be walked to the end still contributes every
        // field before the stopping point, and saying which is which is the
        // difference between a recorded limit and a silent one.
        std.debug.print("totality: {s}: {d} length fields, walk {s}\n", .{
            c.name,
            list.len,
            if (list.stopped) |e| @errorName(e) else "complete",
        });
        fields_seen += list.len;

        for (list.items[0..list.len]) |field| {
            for (values, names) |value, value_name| {
                var enc: [leb128.max_unsigned_size]u8 = undefined;
                const width = leb128.writeUnsigned(&enc, value);
                const prefix = field.offset;
                const suffix = field.offset + field.width;
                const body = scratch[0 .. prefix + width + (parsed.data.len - suffix)];
                @memcpy(body[0..prefix], parsed.data[0..prefix]);
                @memcpy(body[prefix..][0..width], enc[0..width]);
                @memcpy(body[prefix + width ..], parsed.data[suffix..]);

                const framed = try reframe(parsed.typ, body, &frame);
                describeCurrent("{s} with {s} = {s}", .{ c.name, field.name, value_name });
                if (storageRead(framed, meter.allocator())) |_| {
                    return failMutation(
                        "{s} = {s} was accepted; a length no input can hold is never a length",
                        .{ field.name, value_name },
                        c.name,
                        "length field",
                        framed,
                    );
                } else |e| {
                    countRefusal(&refusals, e);
                    if (e == error.OutOfMemory) {
                        return failMutation(
                            "{s} = {s} exhausted the {d} byte budget",
                            .{ field.name, value_name, max_single_allocation },
                            c.name,
                            "length field",
                            framed,
                        );
                    }
                    // Where the walk was verified end to end and the format
                    // forces one refusal, it is exactly this one. Where the
                    // walk stopped early the fixture's own body is what is
                    // malformed, so the reader's order of checks is not the
                    // walker's; the mutation is still asserted to be refused
                    // by name, and `report` says which variant it earned.
                    if (list.stopped == null and
                        forcedRefusal(field.kind) and
                        e != error.LengthExceedsInput)
                    {
                        return failMutation(
                            "{s} = {s} gave {s}, expected {s}",
                            .{ field.name, value_name, @errorName(e), @errorName(error.LengthExceedsInput) },
                            c.name,
                            "length field",
                            framed,
                        );
                    }
                }
                mutations += 1;
            }
        }
    }
    std.debug.print("totality: {d} length fields, {d} impossible-length mutations\n", .{
        fields_seen, mutations,
    });
    refusals.report("impossible lengths");
    try testing.expect(fields_seen > 0);
    try assertBounded("length fields, impossible");
}

test "every declared length field set to 0 or 1 is refused or is a smaller body" {
    // The two values that are not obviously impossible, and the two code
    // paths that a hostile length never reaches: an empty section and a
    // one-element one. A zero column length is *legal* — a column with no
    // bytes is dropped at construction (`raw_column.rs:40-50`) — so the
    // assertion here is totality, and the counts are printed so a change in
    // how many of them are refusals is visible rather than silent.
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    const values = [_]u64{ 0, 1 };
    const names = [_][]const u8{ "0", "1" };

    var mutations: usize = 0;
    var refusals: usize = 0;
    var refusals_tally: RefusalTally = .{};
    var frame: [frame_capacity]u8 = undefined;
    var scratch: [frame_capacity]u8 = undefined;

    for (crashers) |c| {
        const parsed = chunk.parseChunk(c.bytes) catch continue;
        const list = fieldsOf(parsed.typ, parsed.data);

        for (list.items[0..list.len]) |field| {
            for (values, names) |value, value_name| {
                var enc: [leb128.max_unsigned_size]u8 = undefined;
                const width = leb128.writeUnsigned(&enc, value);
                const prefix = field.offset;
                const suffix = field.offset + field.width;
                const body = scratch[0 .. prefix + width + (parsed.data.len - suffix)];
                @memcpy(body[0..prefix], parsed.data[0..prefix]);
                @memcpy(body[prefix..][0..width], enc[0..width]);
                @memcpy(body[prefix + width ..], parsed.data[suffix..]);

                const framed = try reframe(parsed.typ, body, &frame);
                describeCurrent("{s} with {s} = {s}", .{ c.name, field.name, value_name });
                if (storageRead(framed, meter.allocator())) |_| {} else |e| {
                    countRefusal(&refusals_tally, e);
                    refusals += 1;
                    if (e == error.OutOfMemory) {
                        return failMutation(
                            "{s} = {s} exhausted the {d} byte budget",
                            .{ field.name, value_name, max_single_allocation },
                            c.name,
                            "length field",
                            framed,
                        );
                    }
                }
                mutations += 1;
            }
        }
    }
    std.debug.print("totality: {d} zero-and-one mutations, {d} refused, {d} accepted as smaller bodies\n", .{
        mutations, refusals, mutations - refusals,
    });
    refusals_tally.report("zero and one");
    try testing.expect(mutations > 0);
    try assertBounded("length fields, zero and one");
}

test "every bit flipped at every offset of every fixture is refused" {
    // Exhaustive rather than sampled: 58 + 10 + 126 + 123 + 126 + 182 + 134 +
    // 134 = 893 bytes, eight bits each, 7 144 mutations.
    //
    // At the *file* level every one of them is refused, and that is a real
    // property and not an accident of the fixtures: a chunk's header checksum
    // is the first four bytes of `SHA-256(type || uleb128(len) || body)`
    // (`chunk.zig:300-312`), so a flipped bit anywhere in a `change`,
    // `document` or `bundle` chunk changes the body and is caught at
    // `chunk.zig:293-295`. The one type whose checksum is *not* verified by
    // the framing is `compressed`, whose stored checksum covers the inflated
    // body (`chunk.zig:290-292`); a flip that turns a chunk into a compressed
    // one therefore reaches `decompressChunk` instead, and is caught there.
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    var mutations: usize = 0;
    var refusals: usize = 0;
    var accepted: usize = 0;
    var buf: [frame_capacity]u8 = undefined;

    for (crashers) |c| {
        if (c.bytes.len > buf.len) return error.FrameTooLong;
        var offset: usize = 0;
        while (offset < c.bytes.len) : (offset += 1) {
            var bit: u4 = 0;
            while (bit < 8) : (bit += 1) {
                @memcpy(buf[0..c.bytes.len], c.bytes);
                buf[offset] ^= @as(u8, 1) << @as(u3, @intCast(bit));
                const mutated = buf[0..c.bytes.len];
                describeCurrent("{s} with bit {d} of byte {d} flipped", .{ c.name, bit, offset });
                if (storageRead(mutated, meter.allocator())) |_| {
                    accepted += 1;
                } else |e| {
                    refusals += 1;
                    if (e == error.OutOfMemory) {
                        return failMutation(
                            "flipping bit {d} of byte {d} exhausted the {d} byte budget",
                            .{ bit, offset, max_single_allocation },
                            c.name,
                            "bit flip",
                            mutated,
                        );
                    }
                }
                mutations += 1;
            }
        }
    }
    std.debug.print("totality: {d} bit flips, {d} refused, {d} accepted\n", .{
        mutations, refusals, accepted,
    });
    // Every one is refused, which is the checksum doing its job.
    try testing.expectEqual(@as(usize, 0), accepted);
    try testing.expectEqual(crasher_bytes() * 8, mutations);
    try assertBounded("bit flips");
}

test "seeded random byte mutations are refused, and the seed is printed" {
    // The sweep the exhaustive bit flip cannot reach: several bytes changed
    // at once, at positions a bit flip never combines. The seed is fixed so a
    // failure is reproducible, and it is printed on every failure along with
    // the mutated bytes.
    const seed: u64 = 0x5EED_C0DE;
    const mutations_per_fixture = 256;

    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    var mutations: usize = 0;
    var refusals: usize = 0;
    var buf: [frame_capacity]u8 = undefined;

    for (crashers) |c| {
        if (c.bytes.len > buf.len) return error.FrameTooLong;
        var round: usize = 0;
        while (round < mutations_per_fixture) : (round += 1) {
            @memcpy(buf[0..c.bytes.len], c.bytes);
            // One to three bytes, at a random offset each.
            const changed = 1 + random.intRangeLessThan(usize, 0, 3);
            var k: usize = 0;
            while (k < changed) : (k += 1) {
                const at = random.intRangeLessThan(usize, 0, c.bytes.len);
                // A replacement that can land on the byte that was already
                // there is not a mutation at all, and an unmutated fixture
                // that the storage layer accepts is not a defect. The extra
                // bit flip guarantees the byte differs, and two draws keep
                // the replacement effectively random rather than a bit flip
                // in disguise.
                buf[at] = random.int(u8) ^ (@as(u8, 1) << @as(u3, @intCast(
                    random.intRangeLessThan(usize, 0, 8),
                )));
            }
            const mutated = buf[0..c.bytes.len];
            describeCurrent("seed {x}: {s} with {d} random bytes", .{ seed, c.name, changed });
            if (storageRead(mutated, meter.allocator())) |_| {
                return failMutation(
                    "seed {x}: {d} random bytes were accepted, and a corrupted file is never a document",
                    .{ seed, changed },
                    c.name,
                    "seeded random bytes",
                    mutated,
                );
            } else |e| {
                if (e == error.OutOfMemory) {
                    return failMutation(
                        "seed {x}: {d} random bytes exhausted the {d} byte budget",
                        .{ seed, changed, max_single_allocation },
                        c.name,
                        "seeded random bytes",
                        mutated,
                    );
                }
            }
            refusals += 1;
            mutations += 1;
        }
    }
    std.debug.print("totality: seed {x}: {d} random mutations, {d} refused\n", .{
        seed, mutations, refusals,
    });
    try testing.expectEqual(mutations_per_fixture * crashers.len, mutations);
    try assertBounded("seeded");
}

test "hostile bytes reach the DEFLATE decoder and are refused, and its output is bounded" {
    // The one loop in this slice whose trip count is not a function of the
    // input: `chunk.decompressRaw` (`chunk.zig:223`) inflates a raw DEFLATE
    // stream, and its work is the inflated length. So instead of arguing about
    // it, this test drives it and measures it.
    //
    // A `compressed` chunk is the one chunk type whose header checksum is not
    // verified by the framing (`chunk.zig:290-292`), so a `compressed` chunk
    // is the only way untrusted bytes reach the inflater — and it is reached
    // here directly, with a body the port never wrote.
    const watchdog = startWatchdog();
    defer stopWatchdog(watchdog);
    meter.reset();

    var prng: std.Random.DefaultPrng = .init(0xD3F1A7E);
    const random = prng.random();

    var trials: usize = 0;
    var refusals: usize = 0;
    var buf: [frame_capacity]u8 = undefined;

    for (crashers) |c| {
        // Every prefix of every fixture, as a compressed chunk body.
        var k: usize = 0;
        while (k <= c.bytes.len) : (k += 1) {
            try expectDeflateRefused(&refusals, buf[0..k], c.name, "prefix");
            trials += 1;
        }
        // And a seeded block of bytes that are not a DEFLATE stream at all.
        var round: usize = 0;
        while (round < 64) : (round += 1) {
            const len = random.intRangeLessThan(usize, 0, 256);
            random.bytes(buf[0..len]);
            try expectDeflateRefused(&refusals, buf[0..len], c.name, "random block");
            trials += 1;
        }
    }

    // The bound, measured. A raw DEFLATE stream of `n` bytes expands by at
    // most the ratio the encoding permits, so the inflater's output is a
    // function of its input and not an independent quantity: the largest
    // single allocation any of the {d} trials asked for is the figure below.
    std.debug.print(
        "totality: deflate: {d} trials, {d} refused, largest single allocation {d} B, peak live {d} B\n",
        .{ trials, refusals, meter.peak_single, meter.peak_live },
    );
    try testing.expect(trials > 0);
    try assertBounded("deflate");
}

/// Drives `change_chunk.parseFramedChunk` with a `compressed` chunk over
/// `body`, which is the only route from a framed chunk to the inflater.
fn expectDeflateRefused(refused: *usize, body: []const u8, name: []const u8, what: []const u8) !void {
    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(meter.allocator());
    try chunk.writeChunk(&framed, meter.allocator(), .compressed, body);
    describeCurrent("{s} {s} of {d} bytes as a compressed chunk", .{ name, what, body.len });
    if (change_chunk.parseFramedChunk(try chunk.parseChunk(framed.items), meter.allocator())) |parsed| {
        var p = parsed;
        p.deinit(meter.allocator());
        return failMutation(
            "a compressed chunk over {s} of {d} bytes inflated and verified",
            .{ what, body.len },
            name,
            what,
            body,
        );
    } else |e| {
        switch (e) {
            // The two refusals a DEFLATE stream can earn, and the one that
            // would mean the inflater ran away.
            error.InvalidDeflate, error.InvalidChecksum => refused.* += 1,
            error.OutOfMemory => return failMutation(
                "inflating {s} of {d} bytes exhausted the {d} byte budget",
                .{ what, body.len, max_single_allocation },
                name,
                what,
                body,
            ),
            // Everything else is a parser above the framing, and is still a
            // named refusal.
            else => refused.* += 1,
        }
    }
}

/// The total size of the eight fixtures, which is the number of file-level
/// truncations and of exhaustive bit flips the sweeps above perform.
fn crasher_bytes() usize {
    var total: usize = 0;
    for (crashers) |c| total += c.bytes.len;
    return total;
}
