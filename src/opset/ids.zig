//! The column ids and column specifications of the op set.
//!
//! Everything in this file is FORMAT, and nothing in it is a choice. A saved
//! document is a set of columns, each tagged by a `ColumnSpec`; a document
//! written by `automerge` 0.12.0 and one written here have to carry the same
//! columns under the same tags, or they are different documents. The
//! operation rows themselves are written in ascending normalized specification
//! order, which is the order `RawColumns::parse` requires
//! ([survey 03](../docs/survey/03-storage-columnar.md) §Column layout), so
//! the order of `all_column_specs` below is load-bearing as well.
//!
//! Nine ids carry sixteen specifications, because a logical column can be more
//! than one physical column: the object is an actor and a counter, the key is
//! an actor, a counter and a string, the successor list is a count and two
//! flattened halves, and the value is a metadata word and a payload. The port's
//! name for upstream's `ColumnType::Integer` is `Encoding.rle_uint`
//! ([column_spec.zig](../storage/column_spec.zig) §`Encoding`); the tag is 2
//! either way.
//!
//! The word for a specification is `(id << 4) | encoding_tag`, with the DEFLATE
//! bit clear, because a column in a document is not itself deflated — the
//! whole chunk may be, and that is a chunk type, not a column bit
//! (`storage/document/compression.rs`). Every specification here is therefore
//! built with `ColumnSpec.make(..., false)`, exactly as upstream's `new_*`
//! constructors are (`storage/columns/column_specification.rs:22-30`).
//!
//! A test at the bottom pins every id and every raw word as a literal integer,
//! so a refactor cannot move a column without failing the build.

const std = @import("std");
const column_spec = @import("../storage/column_spec.zig");

const ColumnSpec = column_spec.ColumnSpec;
const Encoding = column_spec.Encoding;

// ── Column ids ─────────────────────────────────────────────────────────────
//
// `op_set2/columns.rs:617-626`. Ids 6 and 7 are unused by the op set; the
// format does not reserve them, it simply has nothing to say about them.

/// The parent object's actor and counter (`op_set2/columns.rs:617-618`).
pub const obj_col_id: u32 = 0;
/// A map key's actor, counter and string (`op_set2/columns.rs:619`).
pub const key_col_id: u32 = 1;
/// The operation's own id (`op_set2/columns.rs:620`).
pub const id_col_id: u32 = 2;
/// Whether the operation inserts (`op_set2/columns.rs:621`).
pub const insert_col_id: u32 = 3;
/// The operation's action (`op_set2/columns.rs:622`).
pub const action_col_id: u32 = 4;
/// The value's metadata word and its payload (`op_set2/columns.rs:623`).
pub const val_col_id: u32 = 5;
/// The successors: a count, an actor column and a counter column
/// (`op_set2/columns.rs:624`).
pub const succ_col_id: u32 = 8;
/// Whether a mark expands past its span (`op_set2/columns.rs:625`).
pub const expand_col_id: u32 = 9;
/// The name a mark puts on its span (`op_set2/columns.rs:626`).
pub const mark_name_col_id: u32 = 10;

// ── Column specifications ──────────────────────────────────────────────────
//
// `op_set2/columns.rs:628-643`. Upstream writes these as
// `ColumnSpec::new_actor(ID_COL_ID)` and so on; the port spells the same thing
// `ColumnSpec.make(id, encoding, false)`. The names are kept verbatim, snake
// case included, because a reader diffing the two trees line by line should
// find the same line.

/// The actor half of the operation's id (`columns.rs:629`).
pub const id_actor_col_spec: ColumnSpec = ColumnSpec.make(id_col_id, .actor, false);
/// The counter half of the operation's id, delta coded (`columns.rs:630`).
pub const id_counter_col_spec: ColumnSpec = ColumnSpec.make(id_col_id, .delta, false);
/// The actor half of the parent object's id (`columns.rs:631`).
pub const obj_id_actor_col_spec: ColumnSpec = ColumnSpec.make(obj_col_id, .actor, false);
/// The counter half of the parent object's id, run length coded
/// (`columns.rs:632`).
pub const obj_id_counter_col_spec: ColumnSpec = ColumnSpec.make(obj_col_id, .rle_uint, false);
/// The actor half of a map key, null for a string key (`columns.rs:633`).
pub const key_actor_col_spec: ColumnSpec = ColumnSpec.make(key_col_id, .actor, false);
/// The counter half of a map key, delta coded and nullable (`columns.rs:634`).
pub const key_counter_col_spec: ColumnSpec = ColumnSpec.make(key_col_id, .delta, false);
/// The string half of a map key, null for an object key (`columns.rs:635`).
pub const key_str_col_spec: ColumnSpec = ColumnSpec.make(key_col_id, .string, false);
/// How many successors a row has, one count per row (`columns.rs:636`).
pub const succ_count_col_spec: ColumnSpec = ColumnSpec.make(succ_col_id, .group, false);
/// The actor indices of the successors, flattened across the group
/// (`columns.rs:637`).
pub const succ_actor_col_spec: ColumnSpec = ColumnSpec.make(succ_col_id, .actor, false);
/// The counters of the successors, flattened and delta coded
/// (`columns.rs:638`).
pub const succ_counter_col_spec: ColumnSpec = ColumnSpec.make(succ_col_id, .delta, false);
/// Whether the operation inserts rather than overwrites (`columns.rs:639`).
pub const insert_col_spec: ColumnSpec = ColumnSpec.make(insert_col_id, .boolean, false);
/// The operation's action (`columns.rs:640`).
pub const action_col_spec: ColumnSpec = ColumnSpec.make(action_col_id, .rle_uint, false);
/// The value's metadata word (`columns.rs:641`).
pub const value_meta_col_spec: ColumnSpec = ColumnSpec.make(val_col_id, .value_metadata, false);
/// The value's payload (`columns.rs:642`).
pub const value_col_spec: ColumnSpec = ColumnSpec.make(val_col_id, .value, false);
/// The name a mark puts on its span (`columns.rs:643`).
pub const mark_name_col_spec: ColumnSpec = ColumnSpec.make(mark_name_col_id, .string, false);
/// Whether a mark expands past its span (`columns.rs:644`).
pub const expand_col_spec: ColumnSpec = ColumnSpec.make(expand_col_id, .boolean, false);

/// Every data column of the op set, in upstream's declaration order
/// (`op_set2/columns.rs:646-663`).
///
/// This is **not** the order a stored document carries them in. A document's
/// column set is ascending by normalized specification, and upstream gets
/// there by sorting a copy of this list on the way out
/// (`Columns::export`, `op_set2/columns.rs:172-184`), not by declaring it
/// that way. The order here is therefore the order the exporter iterates, and
/// it groups by logical column — id, object, key, successor, then the rest —
/// which is what a reader of the source wants and what a writer must not
/// assume.
pub const all_column_specs = [16]ColumnSpec{
    id_actor_col_spec,
    id_counter_col_spec,
    obj_id_actor_col_spec,
    obj_id_counter_col_spec,
    key_actor_col_spec,
    key_counter_col_spec,
    key_str_col_spec,
    succ_count_col_spec,
    succ_actor_col_spec,
    succ_counter_col_spec,
    insert_col_spec,
    action_col_spec,
    value_meta_col_spec,
    value_col_spec,
    mark_name_col_spec,
    expand_col_spec,
};

comptime {
    // The list is membership, not order: a duplicate here would mean two
    // logical columns claim one specification, and a stored column set with a
    // repeated specification is a parse error
    // (`storage/columns/raw_column.rs:193-198`). Checking it at compile time
    // means the mistake is a build failure rather than a document the
    // reference cannot read.
    for (all_column_specs, 0..) |a, i| {
        for (all_column_specs[i + 1 ..]) |b| {
            if (a.eql(b)) @compileError("two op set columns share a specification");
        }
    }
}

/// Ascending by normalized specification, which is the order a stored column
/// set carries (`storage/columns/column_specification.rs:14-21`).
fn columnLessThan(_: void, a: ColumnSpec, b: ColumnSpec) bool {
    return a.lessThan(b);
}

test "the op set column ids are the format's" {
    try std.testing.expectEqual(@as(u32, 0), obj_col_id);
    try std.testing.expectEqual(@as(u32, 1), key_col_id);
    try std.testing.expectEqual(@as(u32, 2), id_col_id);
    try std.testing.expectEqual(@as(u32, 3), insert_col_id);
    try std.testing.expectEqual(@as(u32, 4), action_col_id);
    try std.testing.expectEqual(@as(u32, 5), val_col_id);
    try std.testing.expectEqual(@as(u32, 8), succ_col_id);
    try std.testing.expectEqual(@as(u32, 9), expand_col_id);
    try std.testing.expectEqual(@as(u32, 10), mark_name_col_id);
}

test "the op set column words are the format's" {
    // Each word is `(id << 4) | encoding tag`, DEFLATE bit clear. These are
    // the numbers a saved document carries, so they are written out rather
    // than recomputed: a test that derived them from `ColumnSpec.make` would
    // pass no matter what `make` did.
    const expected = [_]struct { spec: ColumnSpec, word: u32, tag: u8 }{
        .{ .spec = obj_id_actor_col_spec, .word = 1, .tag = 1 },
        .{ .spec = obj_id_counter_col_spec, .word = 2, .tag = 2 },
        .{ .spec = key_actor_col_spec, .word = 17, .tag = 1 },
        .{ .spec = key_counter_col_spec, .word = 19, .tag = 3 },
        .{ .spec = key_str_col_spec, .word = 21, .tag = 5 },
        .{ .spec = id_actor_col_spec, .word = 33, .tag = 1 },
        .{ .spec = id_counter_col_spec, .word = 35, .tag = 3 },
        .{ .spec = insert_col_spec, .word = 52, .tag = 4 },
        .{ .spec = action_col_spec, .word = 66, .tag = 2 },
        .{ .spec = value_meta_col_spec, .word = 86, .tag = 6 },
        .{ .spec = value_col_spec, .word = 87, .tag = 7 },
        .{ .spec = succ_count_col_spec, .word = 128, .tag = 0 },
        .{ .spec = succ_actor_col_spec, .word = 129, .tag = 1 },
        .{ .spec = succ_counter_col_spec, .word = 131, .tag = 3 },
        .{ .spec = expand_col_spec, .word = 148, .tag = 4 },
        .{ .spec = mark_name_col_spec, .word = 165, .tag = 5 },
    };
    try std.testing.expectEqual(expected.len, all_column_specs.len);
    for (expected) |e| {
        try std.testing.expectEqual(e.word, e.spec.raw);
        try std.testing.expectEqual(e.word >> 4, e.spec.id());
        try std.testing.expectEqual(e.tag, @intFromEnum(e.spec.encoding()));
        // A column in a document is not itself deflated.
        try std.testing.expect(!e.spec.isCompressed());
    }
}

test "sorting the set yields the order a parser requires" {
    // `Columns::export` sorts a copy of `all_column_specs` before writing
    // (`op_set2/columns.rs:172-184`), and a stored column set has to be
    // ascending by normalized specification for `RawColumns::parse`
    // (`storage/columns/raw_column.rs:248-253`). The declaration order is not
    // that order, so the sort is load-bearing and this pins its result.
    var sorted = all_column_specs;
    std.mem.sort(ColumnSpec, &sorted, {}, columnLessThan);

    const expected = [_]u32{ 1, 2, 17, 19, 21, 33, 35, 52, 66, 86, 87, 128, 129, 131, 148, 165 };
    try std.testing.expectEqual(expected.len, sorted.len);
    for (sorted, expected) |spec, word| {
        try std.testing.expectEqual(word, spec.raw);
    }

    // The sort is a permutation, not a filter: every declared column comes
    // back, so dropping one cannot hide behind a correct-looking order.
    for (all_column_specs) |declared| {
        var seen = false;
        for (sorted) |spec| {
            if (spec.eql(declared)) seen = true;
        }
        try std.testing.expect(seen);
    }
}
