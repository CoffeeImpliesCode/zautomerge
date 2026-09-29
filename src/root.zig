//! `zautomerge` — a direct Zig 0.16 translation of the `automerge` library.
//!
//! A JSON-like CRDT that several devices can edit concurrently and merge
//! without conflict-resolution code, with an efficient binary document format
//! and a sync protocol for any reliable in-order transport.
//!
//! The compatibility contract: a document written by `automerge` 0.12.0 loads
//! here and one written here loads there; sync states interoperate in both
//! directions; change hashes match byte for byte. `save()` output is not
//! byte-identical, because DEFLATE is not reproducible across implementations.
//! See `docs/plan.md` §1.

const std = @import("std");

pub const error_types = @import("error.zig");
pub const types = @import("types.zig");
pub const value = @import("value.zig");
pub const clock = @import("clock.zig");
pub const leb128 = @import("leb128.zig");
pub const unicode = @import("unicode.zig");

// The three error sets, re-exported because every public function in this
// crate returns one of them.
pub const Error = error_types.Error;
pub const ParseError = error_types.ParseError;
pub const InternalError = error_types.InternalError;

// Identity and shape.
pub const ActorId = types.ActorId;
pub const ActorIdx = types.ActorIdx;
pub const OpId = types.OpId;
pub const ExId = types.ExId;
pub const ElemId = types.ElemId;
pub const ObjId = types.ExId;
pub const ObjType = types.ObjType;
pub const ObjMeta = types.ObjMeta;
pub const Prop = types.Prop;
pub const SequenceType = types.SequenceType;
pub const TextEncoding = types.TextEncoding;
pub const ChangeHash = types.ChangeHash;

/// The object id of the document root map.
pub const root: ExId = .root;

// Values.
pub const Value = value.Value;
pub const ScalarValue = value.ScalarValue;
pub const Counter = value.ScalarValue.Counter;
pub const ValueType = value.ValueType;
pub const ValueMeta = value.ValueMeta;
pub const Action = value.Action;
pub const OpType = value.OpType;
pub const ScalarValueRef = value.ScalarValueRef;

// Clocks.
pub const Clock = clock.Clock;
pub const SeqClock = clock.SeqClock;
pub const ClockRange = clock.ClockRange;

/// The version of this port. Tracks the upstream `automerge` crate it targets.
pub const version = "0.0.0";

/// The upstream `automerge` crate version this port is written against.
pub const upstream_version = "0.12.0";

test {
    _ = @import("error.zig");
    _ = @import("types.zig");
    _ = @import("value.zig");
    _ = @import("clock.zig");
    _ = @import("leb128.zig");
    _ = @import("unicode.zig");
}
