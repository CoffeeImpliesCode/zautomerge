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
pub const hexane = struct {
    pub const rle = @import("hexane/rle.zig");
    pub const bool_codec = @import("hexane/bool.zig");
    pub const btree = @import("hexane/btree.zig");
    pub const delta = @import("hexane/delta.zig");
    pub const prefix = @import("hexane/prefix.zig");
    pub const slab = @import("hexane/slab.zig");
    pub const column = @import("hexane/column.zig");
    pub const edit = @import("hexane/edit.zig");
    pub const raw = @import("hexane/raw.zig");
    pub const index = @import("hexane/index.zig");
};
pub const authors = @import("author.zig");
pub const change_graph = @import("change_graph.zig");
pub const change_queue = @import("change_queue.zig");
pub const sequence_tree = @import("sequence_tree.zig");
pub const change_record = @import("change.zig");
pub const columnar = struct {
    pub const encoding = @import("columnar/encoding.zig");
    pub const columns = @import("columnar/columns.zig");
};
pub const storage = struct {
    pub const parse = @import("storage/parse.zig");
    pub const chunk = @import("storage/chunk.zig");
    pub const change_chunk = @import("storage/change_chunk.zig");
    pub const document_chunk = @import("storage/document_chunk.zig");
    pub const bundle = @import("storage/bundle.zig");
    pub const column_spec = @import("storage/column_spec.zig");
};
pub const clock = @import("clock.zig");
pub const leb128 = @import("leb128.zig");
pub const unicode = @import("unicode.zig");
pub const marks = @import("marks.zig");
pub const cursor = @import("cursor.zig");
pub const patches = @import("patches.zig");
pub const hydrate = @import("hydrate.zig");
pub const doc = @import("doc.zig");
pub const sync = struct {
    pub const bloom = @import("sync/bloom.zig");
    pub const message = @import("sync/message.zig");
    pub const state = @import("sync/state.zig");
    pub const protocol = @import("sync/protocol.zig");
    pub const v1 = @import("sync/v1.zig");
};
pub const textdiff = @import("textdiff.zig");
pub const autoserde = @import("autoserde.zig");
pub const opset = struct {
    pub const ids = @import("opset/ids.zig");
    pub const types = @import("opset/types.zig");
    pub const op = @import("opset/op.zig");
    pub const columns = @import("opset/columns.zig");
    pub const mark_index = @import("opset/mark_index.zig");
    pub const op_iter = @import("opset/op_iter.zig");
    pub const op_query = @import("opset/op_query.zig");
    pub const marks = @import("opset/marks.zig");
    pub const found_op = @import("opset/found_op.zig");
    pub const insert = @import("opset/insert.zig");
    pub const index = @import("opset/index.zig");
    pub const visible = @import("opset/visible.zig");
    pub const top_op = @import("opset/top_op.zig");
    pub const op_set = @import("opset/op_set.zig");
    pub const batch = @import("opset/batch.zig");
    pub const parents = @import("opset/parents.zig");
};
pub const c_abi = struct {
    pub const result = @import("c/result.zig");
    pub const doc = @import("c/doc.zig");
    pub const sync = @import("c/sync.zig");
};
pub const iter = struct {
    pub const tools = @import("iter/tools.zig");
    pub const slice = @import("iter/slice.zig");
    pub const map_range = @import("iter/map_range.zig");
    pub const list_range = @import("iter/list_range.zig");
    pub const spans = @import("iter/spans.zig");
    pub const keys = @import("iter/keys.zig");
    pub const values = @import("iter/values.zig");
    pub const doc = @import("iter/doc.zig");
};

// The three error sets, re-exported because every public function in this
// crate returns one of them.
pub const Error = error_types.Error;
pub const ParseError = error_types.ParseError;
pub const InternalError = error_types.InternalError;
pub const read = @import("read.zig");
pub const transaction = @import("transact.zig");
/// The manual-mode `Transaction`: `Transaction.open` on a document flagged
/// `.manual`, whose caller calls `commit` itself and gets a hash back
/// ([`inner.rs:22-33`](https://github.com/automerge/automerge/blob/main/rust/automerge/src/transaction/inner.rs)).
/// Distinct from `transaction`, which is the autocommit door.
pub const manual_transaction = @import("transaction.zig");
pub const anonymize = @import("anonymize.zig");
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

// Every module is pulled into the test root so its own tests run. A module
// referenced only by a container-level declaration is not analyzed for tests.
test {
    _ = @import("error.zig");
    _ = @import("types.zig");
    _ = @import("value.zig");
    _ = @import("clock.zig");
    _ = @import("leb128.zig");
    _ = @import("unicode.zig");
    _ = @import("hexane/rle.zig");
    _ = @import("hexane/bool.zig");
    _ = @import("hexane/delta.zig");
    _ = @import("hexane/prefix.zig");
    _ = @import("hexane/btree.zig");
    _ = @import("hexane/slab.zig");
    _ = @import("hexane/column.zig");
    _ = @import("hexane/edit.zig");
    _ = @import("hexane/raw.zig");
    _ = @import("hexane/index.zig");
    _ = @import("storage/parse.zig");
    _ = @import("storage/chunk.zig");
    _ = @import("storage/column_spec.zig");
    _ = @import("storage/change_chunk.zig");
    _ = @import("storage/bundle.zig");
    _ = @import("storage/document_chunk.zig");
    _ = @import("author.zig");
    _ = @import("change.zig");
    _ = @import("change_graph.zig");
    _ = @import("change_queue.zig");
    _ = @import("columnar/encoding.zig");
    _ = @import("columnar/columns.zig");
    _ = @import("sequence_tree.zig");
    _ = @import("marks.zig");
    _ = @import("sync/bloom.zig");
    _ = @import("sync/message.zig");
    _ = @import("sync/state.zig");
    _ = @import("textdiff.zig");
    _ = @import("opset/ids.zig");
    _ = @import("opset/types.zig");
    _ = @import("opset/op.zig");
    _ = @import("opset/columns.zig");
    _ = @import("opset/mark_index.zig");
    _ = @import("opset/op_iter.zig");
    _ = @import("opset/op_query.zig");
    _ = @import("opset/marks.zig");
    _ = @import("opset/found_op.zig");
    _ = @import("opset/insert.zig");
    _ = @import("opset/index.zig");
    _ = @import("opset/visible.zig");
    _ = @import("opset/top_op.zig");
    _ = @import("opset/op_set.zig");
    _ = @import("opset/batch.zig");
    _ = @import("opset/parents.zig");
    _ = @import("iter/tools.zig");
    _ = @import("iter/map_range.zig");
    _ = @import("iter/list_range.zig");
    _ = @import("iter/spans.zig");
    _ = @import("iter/keys.zig");
    _ = @import("iter/values.zig");
    _ = @import("iter/doc.zig");
    _ = @import("iter/slice.zig");
    _ = @import("read.zig");
    _ = @import("transact.zig");
    _ = @import("anonymize.zig");
    _ = @import("sync/protocol.zig");
    _ = @import("sync/v1.zig");
    _ = @import("marks.zig");
    _ = @import("textdiff.zig");
    _ = @import("patches.zig");
    _ = @import("cursor.zig");
    _ = @import("hydrate.zig");
    _ = @import("doc.zig");
    _ = @import("c/result.zig");
    // `c/doc.zig` and `c/sync.zig` are deliberately NOT in this block: they
    // are `export fn`s over libc, and `zig test` links no libc. They are
    // verified instead by the C driver, which builds them with
    // `.link_libc = true` — a stronger test than a Zig-side one, because it
    // exercises the boundary from the side that will actually use it.
    _ = @import("autoserde.zig");
    _ = @import("transaction.zig");
}
