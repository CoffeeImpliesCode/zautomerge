//! Cursors: the anchor into a sequence that survives an edit.
//!
//! Upstream `rust/automerge/src/cursor.rs`, 296 lines, owns four types —
//! [`Cursor`], [`OpCursor`], [`CursorPosition`] and [`MoveCursor`] — the v1
//! binary codec with its EBNF (`:120-146`), the string codec, and the legacy
//! v0 parser `parse_0` (`:265-288`). It owns **no resolution logic**: where a
//! cursor dereferences to is `get_cursor_for` and `get_cursor_position_for` on
//! the document (`automerge.rs:1732-1758`, `:1760-1849`). Both are ported
//! here, as [`getCursor`] and [`getCursorPosition`], because they are the other
//! half of the bias rules and a bias rule that is not next to the code that
//! applies it is a bias rule nobody checks.
//!
//! # The wire format, which is not negotiable
//!
//! A cursor a caller stored has to decode here, and one that does not is a
//! lost cursor. The v1 grammar is reproduced verbatim below and it is the
//! normative one; nothing in this file may renumber a tag or reorder a field.
//! Version `0` is still accepted on read and is decoded by [`parse0`], which
//! is upstream's `parse_0` (`:265-288`).
//!
//! ```text
//! EBNF:
//!
//! byte = %x00-FF
//!         ; any octet
//! bytes = 1*byte
//!         ; any sequence of octets
//! uleb128 = 1*8( %x00-7F ) / ( %x80-FF bytes )
//!         ; unsigned LEB128 encoding
//!
//! ; tags:
//! version   = %d01 ; for version 1
//!
//! start     = %d01 ; Cursor::Start
//! end       = %d02 ; Cursor::End
//! opid_tag  = %d03 ; Cursor::Op
//!
//! move      = %d01 ; MoveCursor::Before
//!           / %d02 ; MoveCursor::After
//!
//! counter = uleb128
//! actor_id = uleb128 bytes ; length prefixed bytes of the actor ID
//!
//! opid = opid_tag actor_id counter move
//!
//! cursor = version (start / end / opid)
//! ```
//!
//! The version-0 layout is upstream's own comment at `:266-272`:
//!
//! ```text
//! .----------------------------------------------------------------.
//! | version   | actorId len     | actorId bytes | counter          |
//! +----------------------------------------------------------------+
//! |  1 byte   | unsigned leb128 | variable      | unsigned leb128  |
//! '----------------------------------------------------------------'
//! ```
//!
//! # `ctr` is a `u64` and the offset is not on the wire
//!
//! Two things follow from the grammar above, and both are deliberate.
//!
//! **The counter is a `u64`.** `OpCursor.ctr` is upstream's `ctr: u64`
//! (`cursor.rs:34`) and the grammar's `counter` is an unbounded
//! `uleb128`, so a cursor whose counter is above a document's `u32` decodes
//! here and is refused later, by [`OpCursor.elemId`], with no row that could
//! ever name it. Narrowing the field to `u32` would instead reject the bytes at
//! parse time, which is a stricter format than the one upstream reads.
//!
//! **The offset is not on the wire.** This port's [`OpCursor`] is an
//! `ElemId` plus the offset within the element (see "The offset" below), and
//! the v1 grammar has no field for an offset: `opid` is a tag, an actor, a
//! counter and a move. Widening the grammar is forbidden by
//! [`AGENTS.md`](../../AGENTS.md) ("Never change the document format, the
//! change encoding, the column ids, the column order, or the sync message
//! bytes") and by this slice's own instruction that the codec is FORMAT, so
//! the offset is a **resolution refinement that lives in memory only**.
//! [`toBytes`] of a cursor at offset 2 inside an element is byte-identical to
//! [`toBytes`] of one at offset 0 in the same element, and [`fromBytes`]
//! yields offset `0`. That is a pinned behaviour with a test, not a silent
//! loss, and it is the only reading of "both must encode" that does not
//! renumber the grammar.
//!
//! # The offset, and why it is here when upstream does not have it
//!
//! Upstream resolves a cursor to the **start** of its element: `get_cursor_for`
//! stores the op id of the row at the index (`automerge.rs:1747-1752`) and
//! `get_cursor_position_for` returns the `FoundOpId::index` that
//! `seek_list_opid` found (`automerge.rs:1794`), which is the element's first
//! index. A text element can be several units wide — one row's value is a
//! whole string, and its width is the width of that string under the
//! document's encoding (`op.zig:1844-1849`) — so a cursor taken two units into
//! a five-unit grapheme comes back as the grapheme's first unit once anything
//! is inserted before it.
//!
//! [`getCursor`] therefore records the offset ([`OpCursor.offset`]) and
//! [`getCursorPosition`] adds it back, so a cursor in a multi-unit element
//! resolves to the *position* it was taken at and not to the element's edge.
//! For a list the offset is always zero, because a list element's width is
//! one (`op.zig:1845`).
//!
//! # The bias rules, and which one is which
//!
//! [`MoveCursor.before`] and [`MoveCursor.after`] are the same unless the
//! element the cursor names has been **removed**. That is upstream's rule
//! (`automerge.rs:1783-1846`), and it is stated here because the whole
//! difference between the two lives in one branch of one function:
//!
//! * the element is visible — both biases answer `element index + offset`
//!   (`automerge.rs:1794` for `after`, `:1803-1804` for `before`);
//! * the element is not visible, bias `after` — the index the element would
//!   have had, which is where the **next visible element** now is, or the
//!   sequence's length if there is none (`automerge.rs:1790-1794`);
//! * the element is not visible, bias `before`, and its index is `0` — `0`
//!   (`automerge.rs:1801-1804`);
//! * the element is not visible, bias `before` — walk **backwards** through
//!   the element the cursor's row hangs by, one element at a time, and take
//!   the index of the first one that is visible; `0` if the walk runs off the
//!   front of the sequence (`automerge.rs:1806-1843`).
//!
//! The backward walk is upstream's loop verbatim in structure, with two ports'
//! differences: the walk's element is a value taken out of the row *before*
//! the next query, because the port's [`Op`] points its successors into the op
//! set's shared buffer and the next query overwrites them
//! ([op_set.zig](opset/op_set.zig)'s module doc, "The rule that follows, and
//! it is load-bearing"), and the walk is **bounded by the object's row count**,
//! where upstream's is not. Upstream's is a `loop` with an `expect` in it
//! (`:1831-1838`); the port does not trap on bytes, so a document whose rows
//! do not strictly descend by anchor cannot spin here
//! ([error.zig](error.zig)).
//!
//! # Where a cursor is resolved: the op set, not a b-tree
//!
//! Upstream's `sequence_tree.rs` is a positional b-tree with **no cursors** at
//! all ([docs/STATUS.md](../../docs/STATUS.md) defect 7), and an earlier
//! attempt at this slice invented a cursor API over it. This file resolves
//! through the op set instead, with three queries and nothing of its own:
//! [`OpSet.seekOpsByIndex`](opset/op_set.zig) to make a cursor from a
//! position, [`OpSet.seekListOpid`](opset/op_set.zig) to resolve one, and
//! [`OpSet.seqLength`](opset/op_set.zig) for `Cursor.end`.
//!
//! **Making a cursor is one of those three, not two.** It used to be two:
//! [`getCursor`] made a second [`OpSet.seekListOpid`] call to recover the
//! register's start for the offset, and that call was not a descent but an
//! **O(rows in the object) walk** in every build, because
//! [`OpSet.seekListOpid`] answered its fast arm and ran
//! [`OpSet.seekListOpidSlow`](opset/op_set.zig) beside it and compared the
//! two. **That comparison is behind
//! [`OpSet.check_slow_paths`](opset/op_set.zig) now**
//! ([`op_set.zig`:3953-3956](opset/op_set.zig)) — upstream spells it a
//! `debug_assert_eq!` (`op_set.rs:846`) that its release profile compiles out,
//! while here the second arm is a `Grouped` walk over every register in the
//! object, so an always-on comparison was O(rows) on every cursor resolve.
//! The number the call fetched was already in the first answer's `index`, so
//! the call bought nothing but the walk. **The cost is read off the source,
//! not measured**: the test at the foot of this file is the witness that the
//! two numbers are equal, and no gate in `bench/` reaches a cursor.
//!
//! # A cursor names the row the query answered, and that is upstream's rule
//!
//! Upstream mints `OpCursor::new(op.id, ...)` over `found.ops.last()`
//! ([`automerge.rs:1751-1752`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
//! and `OpCursor` is upstream's own "a cursor which represents a specific op
//! in a sequence"
//! ([`cursor.rs:31`](../../github-automerge-automerge/rust/automerge/src/cursor.rs)).
//! [`getCursor`] takes the id of that same row, and takes nothing else.
//!
//! **Where a register holds more than one row, two readings are possible and
//! both are reachable.** One is *the element the register addresses* — what
//! [`Op.cursor`](opset/op.zig) answers — and the other is *the group's last
//! operation*, which is what upstream takes. They part company for a register
//! of one insert and one `set` **over** it — a list element that op 2 inserted
//! and op 3 overwrote, which is op 2 against op 3. They cannot be told apart
//! for every register that is one insert: every register in an ordinary
//! document, and every register a `splice` leaves behind, because a splice
//! deletes and re-inserts rather than overwriting.
//!
//! **The index is the same either way, and this is worth stating because it
//! used to be stated the other way round.** A register carries exactly one
//! `index.top` — [`IndexBuilder.flush`](opset/index.zig) marks the **last**
//! row with no unshadowed successor (`index.rs:175-183`) — one winner per
//! register is what [`OpSet.validateTopIndex`](opset/op_set.zig) asserts
//! ([`op_set.rs:196-212`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//! and `index.top`'s prefix counts **winners**. So the prefix descent behind
//! [`OpSet.seekListOpid`](opset/op_set.zig) lands on the same element for
//! *every* row of a register, the overwritten one included: measured on
//! [`set_over_insert`], the element `2@0` and the `set` over it `3@0` both
//! answer index `0`, and both arms of the cross-check agree.
//!
//! **Which is why [`getCursor`] can read the element's start off the
//! [`OpSet.seekOpsByIndex`] it already made**, and does: the descent it
//! landed on is that same prefix. It used to make a second
//! [`OpSet.seekListOpid`] call to be told the number this paragraph says it
//! already had; see "Where a cursor is resolved" above for what that call
//! cost.
//!
//! **The argument that once said otherwise, and the document it needed.** It
//! was that a `set` over an element is a *second* top row in a register of
//! one width, so the fast descent over-counts by one, upstream's
//! `debug_assert_eq!` panics
//! ([`op_set.rs:846`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
//! and a release build answers the wrong index. That takes a register with
//! **two** winners, and no merge and no load can produce one: `Op::top` is
//! `Op::visible`
//! ([`op.rs:1148-1156`,`:1355-1359`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)),
//! and `local_list_op` puts a successor edge on **every** row of the register
//! it overwrites
//! ([`inner.rs:549-553`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs)),
//! which is precisely what makes the overwritten row invisible. The fixture
//! that made the claim was such a document — [`set_over_insert`] with its
//! successor edge left off — and `validate_top_index` named it for what it
//! was, `final_group_mismatch { at = 3, first_top = 1, last_vis = 2 }`. An
//! assertion that cannot fire on a document anybody can build is not a
//! finding.
//!
//! So the id on the wire is the row's own, for the two reasons that survive:
//! **a cursor is persisted and handed to other peers**
//! ([`cursor.rs:15`](../../github-automerge-automerge/rust/automerge/src/cursor.rs)),
//! so the bytes have to be the ones the reference writes; and **the head stops
//! being a special case**. [`Op.cursor`](opset/op.zig) answers the head for a
//! row that hangs by it — a `set` at index `0` of an empty sequence, which is
//! legal ([insert.zig](opset/insert.zig)'s `queryInsertAt`) — and the head is
//! `(absent actor, zero counter)` ([types.zig](types.zig) on `ElemId`), so a
//! cursor built from it names no operation and resolves to nothing. A row's
//! **own** id is never the head, so there is nothing to substitute and no
//! [`Op.cursor`] call on this path at all.

const std = @import("std");
const err = @import("error.zig");
const types = @import("types.zig");
const leb = @import("leb128.zig");
const opmod = @import("opset/op.zig");
const opiter = @import("opset/op_iter.zig");
const opset = @import("opset/op_set.zig");
const opcols = @import("opset/columns.zig");
const optypes = @import("opset/types.zig");
const clockmod = @import("clock.zig");

const Allocator = std.mem.Allocator;
const ActorId = types.ActorId;
const ActorIdx = types.ActorIdx;
const Clock = clockmod.Clock;
const ElemId = types.ElemId;
const Error = err.Error;
const ExId = types.ExId;
const InternalError = err.InternalError;
const OpId = types.OpId;
const ParseError = err.ParseError;
const SequenceType = types.SequenceType;

const testing = std.testing;

// ── The tags, which are the format ─────────────────────────────────────────

/// The version byte every v1 cursor starts with (`VERSION_TAG`,
/// `cursor.rs:82`).
pub const version_tag: u8 = 1;

/// `Cursor::Start` in the grammar (`START_TAG`, `cursor.rs:84`).
pub const start_tag: u8 = 1;

/// `Cursor::End` in the grammar (`END_TAG`, `cursor.rs:85`).
pub const end_tag: u8 = 2;

/// `Cursor::Op` in the grammar (`OP_TAG`, `cursor.rs:86`).
pub const op_tag: u8 = 3;

/// `MoveCursor::Before` in the grammar (`MOVE_BEFORE_TAG`, `cursor.rs:88`).
pub const move_before_tag: u8 = 1;

/// `MoveCursor::After` in the grammar (`MOVE_AFTER_TAG`, `cursor.rs:89`).
pub const move_after_tag: u8 = 2;

/// What [`getCursor`] and [`getCursorPosition`] can raise.
///
/// The union of the document `Error`, the op set's read set
/// ([`opiter.ReadOpError`](opset/op_iter.zig), which already contains
/// [`ParseError`]), the op set's B-tree set
/// ([`opset.SearchError`](opset/op_set.zig)) and [`InternalError`], which is
/// where the two checks upstream writes as `expect` land
/// (`automerge.rs:1813-1814`, `:1834-1837`).
pub const ResolveError = Error || opiter.ReadOpError || opset.SearchError || InternalError;

// ── MoveCursor ─────────────────────────────────────────────────────────────

/// How a cursor resolves its position if the element it names is removed
/// (`MoveCursor`, `cursor.rs:70-74`).
///
/// With [`before`], the cursor shifts to the **previous** item that was
/// visible when the cursor was made, or to `0` if there is none
/// (`cursor.rs:65-66`). With [`after`], it shifts to the **next** item that
/// was visible then, or to `sequence.length` if there is none
/// (`cursor.rs:68-69`). `after` is the default (`cursor.rs:76-80`) and is
/// what [`ReadDoc::get_cursor`](../../github-automerge-automerge/rust/automerge/src/read.rs:199-211)
/// uses, because it is what a cursor did before a bias existed
/// (`automerge.rs:1784-1787`).
pub const MoveCursor = enum {
    /// Shift backwards (`MoveCursor::Before`, `cursor.rs:72`).
    before,
    /// Shift forwards (`MoveCursor::After`, `cursor.rs:73`).
    after,

    /// `MoveCursor::default`, which is `After` (`cursor.rs:76-80`).
    pub const default: MoveCursor = .after;

    /// The one byte the grammar's `move` production is (`cursor.rs:88-89`).
    pub fn tag(self: MoveCursor) u8 {
        return switch (self) {
            .before => move_before_tag,
            .after => move_after_tag,
        };
    }

    /// Reads the grammar's `move` byte. Null for a byte that is neither tag,
    /// which is upstream's `_ => return Err(InvalidCursorFormat)`
    /// (`cursor.rs:262`).
    pub fn fromTag(t: u8) ?MoveCursor {
        return switch (t) {
            move_after_tag => .after,
            move_before_tag => .before,
            else => null,
        };
    }
};

// ── CursorPosition ─────────────────────────────────────────────────────────

/// A position in a sequence that a cursor can be made at
/// (`CursorPosition`, `cursor.rs:49-55`).
pub const CursorPosition = union(enum) {
    /// The front of the sequence, which resolves to `0`
    /// (`CursorPosition::Start`, `cursor.rs:52`; `automerge.rs:1767`).
    start,
    /// The end of the sequence, which resolves to `sequence.length`
    /// (`CursorPosition::End`, `cursor.rs:53`; `automerge.rs:1768`).
    end,
    /// An index, in the object's own units (`CursorPosition::Index`,
    /// `cursor.rs:54`).
    index: usize,

    /// `From<usize> for CursorPosition` (`cursor.rs:57-61`).
    pub fn fromIndex(i: usize) CursorPosition {
        return .{ .index = i };
    }
};

// ── OpCursor ───────────────────────────────────────────────────────────────

/// A cursor attached to one element of a sequence (`OpCursor`,
/// `cursor.rs:32-37`).
///
/// Upstream's three fields are `ctr: u64`, `actor: ActorId` and
/// `move_cursor`; this is those three plus [`offset`](#OpCursor.offset). The
/// pair `(ctr, actor)` **is** the element's id: the port's [`ElemId`] is the
/// *index* form of the same name — a `u32` counter and an actor index into the
/// document's table — while the wire format carries the actor's *bytes*
/// (`cursor.rs:141`), and the op set resolves an [`OpId`]
/// (`automerge.rs:775-776`). So the wire form is what is stored and
/// [`elemId`](#OpCursor.elemId) derives the op set's form at resolution time,
/// which is upstream's `op_cursor_to_opid` (`automerge.rs:770-786`) with the
/// same two refusals: an actor the document does not hold, and a counter that
/// fits no row.
///
/// **`actor` is borrowed, and the three sources own it differently.** An
/// actor a document handed out points into the document's actor table
/// ([types.zig](types.zig) on `ActorId`) and must outlive the cursor; an actor
/// [`fromBytes`] or [`parse0`] decoded is a subslice of the caller's own buffer,
/// which must outlive the cursor and stay unmodified; an actor [`fromStr`]
/// decoded is **fresh memory the caller allocated**, and the caller frees
/// exactly `gpa.free(c.op.actor.bytes)` when the cursor is done with. This type
/// has no `deinit`, because it cannot know which of the three it holds.
pub const OpCursor = struct {
    /// The counter of the element's operation (`ctr`, `cursor.rs:34`).
    ///
    /// A `u64` and not a `u32` because the grammar's `counter` is an unbounded
    /// `uleb128` (`cursor.rs:140`) and upstream reads it as one. A value above
    /// a document's counter range is refused by [`elemId`](#OpCursor.elemId),
    /// not here.
    ctr: u64,
    /// The actor that made the element, as bytes (`actor`, `cursor.rs:35`).
    ///
    /// **Borrowed — see the type comment** for the three owners and what each
    /// one owes. `actor.bytes` is the only borrowed field here; `ctr`,
    /// `move_cursor` and `offset` are values.
    actor: ActorId,
    /// Which way this cursor moves if its element is removed (`move_cursor`,
    /// `cursor.rs:36`).
    move_cursor: MoveCursor,
    /// How far into the element the cursor sits, in the object's own units
    /// (**this port only**; see "The offset" in the module doc).
    ///
    /// Zero for a list, because a list element's width is one
    /// (`op.zig:1845`), and for a text cursor taken at a character boundary.
    /// It is **not** in the v1 grammar and so survives
    /// [`toBytes`]/[`fromBytes`] as zero.
    offset: u32,

    /// Upstream's `OpCursor::new` (`cursor.rs:39-46`), which takes the op's id
    /// and the op set to turn its actor index into bytes. This takes the two
    /// things that constructor derives, because that is all this port needs
    /// to hold: the element, the offset, and the bias. Allocates nothing.
    pub fn init(elem: ElemId, offset: u32, move_cursor: MoveCursor, actor: ActorId) OpCursor {
        return .{ .ctr = elem.id.counter, .actor = actor, .move_cursor = move_cursor, .offset = offset };
    }

    /// The element this cursor names, in the op set's form
    /// (`automerge.rs:775-776`).
    ///
    /// `actor_index` is where `actor`'s bytes sit in the document's actor
    /// table, which the caller has already looked up — upstream does that
    /// lookup in `op_cursor_to_opid` and refuses the cursor when it misses
    /// (`automerge.rs:775`, `:783-784`).
    ///
    /// A counter above a row's range is `error.InvalidCursor`, which is the
    /// same refusal upstream reaches when `seek_list_opid` finds no row
    /// (`automerge.rs:1778-1781`); the grammar is unbounded and the document
    /// is not, and this is the earliest total place to say so.
    pub fn elemId(self: OpCursor, actor_index: ActorIdx) Error!ElemId {
        const ctr = std.math.cast(u32, self.ctr) orelse return error.InvalidCursor;
        return ElemId.fromOpId(OpId.init(ctr, actor_index));
    }

    /// Upstream derives `PartialEq` (`cursor.rs:32`), which is the field-wise
    /// comparison, offset included.
    pub fn eql(a: OpCursor, b: OpCursor) bool {
        return a.ctr == b.ctr and
            a.offset == b.offset and
            a.move_cursor == b.move_cursor and
            ActorId.eql(a.actor, b.actor);
    }
};

// ── Cursor ─────────────────────────────────────────────────────────────────

/// An identifier of a position in a sequence, either a list or a text object
/// (`Cursor`, `cursor.rs:19-29`).
///
/// Obtained from [`getCursor`] and dereferenced by [`getCursorPosition`]
/// (`cursor.rs:17-18`). It can be persisted with [`toBytes`] and read back
/// with [`fromBytes`], or written as a string with [`toStr`] and read back
/// with [`fromStr`] (`cursor.rs:15`, `:119`, `:182`).
///
/// **A `.start` or `.end` cursor owns nothing. A `.op` cursor borrows its
/// [`OpCursor.actor`], and which owner it is depends on where the value came
/// from:** the document's actor table through [`getCursor`], the caller's own
/// buffer through [`fromBytes`] and [`parse0`], or memory the caller allocated
/// through [`fromStr`]. There is no `Cursor.deinit`; read [`OpCursor`] for the
/// rule, and each constructor for the one it is responsible for.
pub const Cursor = union(enum) {
    /// Always dereferences to position `0` (`cursor.rs:22`).
    start,
    /// Always dereferences to `sequence.length` (`cursor.rs:24`).
    end,
    /// Attached to one element (`cursor.rs:27-28`).
    op: OpCursor,

    /// Upstream derives `PartialEq` (`cursor.rs:19`).
    pub fn eql(a: Cursor, b: Cursor) bool {
        return switch (a) {
            .start => b == .start,
            .end => b == .end,
            .op => |x| switch (b) {
                .op => |y| x.eql(y),
                else => false,
            },
        };
    }
};

// ── The v1 codec ───────────────────────────────────────────────────────────

/// The cursor's bytes, exactly as the grammar in the module doc spells them
/// (`Cursor::to_bytes`, `cursor.rs:119-176`).
///
/// **This is the format.** The byte order is `version`, tag, then — for an op
/// cursor — the actor's length as a `uleb128`, the actor's bytes, the counter
/// as a `uleb128`, and the move byte (`cursor.rs:161-171`). The returned
/// slice is owned by the caller and freed with `gpa`.
///
/// A cursor's [`OpCursor.offset`] is **not** written; see "The offset" in the
/// module doc. Everything else is, so a cursor this writes is byte-identical
/// to the one upstream writes for the same element and bias.
pub fn toBytes(gpa: Allocator, self: Cursor) ![]u8 {
    return switch (self) {
        .start => try dup(gpa, &.{ version_tag, start_tag }), // cursor.rs:149
        .end => try dup(gpa, &.{ version_tag, end_tag }), // cursor.rs:150
        .op => |op| blk: {
            const bytes = op.actor.bytes;
            // `Vec::with_capacity(1 + 1 + 8 + actor_bytes.len() + 8 + 1)`
            // (`cursor.rs:158-159`): two tags, the actor's length and its bytes,
            // and the counter, each with a `u64`'s worth of LEB128.
            var out = try gpa.alloc(u8, 2 + leb.max_unsigned_size + bytes.len + leb.max_unsigned_size + 1);
            errdefer gpa.free(out);
            out[0] = version_tag;
            out[1] = op_tag;
            var n: usize = 2;
            n += leb.writeUnsigned(out[n .. n + leb.max_unsigned_size], bytes.len);
            @memcpy(out[n .. n + bytes.len], bytes);
            n += bytes.len;
            n += leb.writeUnsigned(out[n .. n + leb.max_unsigned_size], op.ctr);
            out[n] = op.move_cursor.tag();
            n += 1;
            break :blk try gpa.realloc(out, n);
        },
    };
}

/// A cursor out of its bytes (`impl TryFrom<&[u8]> for Cursor`,
/// `cursor.rs:220-263`).
///
/// **Every refusal is a [`ParseError`]**, because a stored cursor is
/// untrusted input ([error.zig](error.zig)); there is no panic on any byte
/// string and no unbounded loop.
///
/// **Trailing bytes are ignored**, which is upstream's behaviour and not an
/// oversight: upstream binds the last field to `_i` (`cursor.rs:247`) and
/// never asks whether the input is spent, so a cursor read out of a larger
/// buffer is the same cursor. A refusal here is therefore about a byte that
/// could not be a cursor, never about a byte that followed one.
///
/// **The returned cursor borrows `bytes`, and nothing else here allocates.** An
/// op cursor's [`OpCursor.actor`] is a **subslice of the argument**, so the
/// buffer must stay alive and unmodified for as long as the cursor is used.
/// There is no `deinit` and no matching free, and a `.start` or `.end` result
/// borrows nothing. This is the opposite of [`fromStr`], which decodes the
/// actor into fresh memory the caller frees with `gpa`; [`parse0`] borrows the
/// same way. See [`OpCursor`] for the third source, a document's actor table.
pub fn fromBytes(bytes: []const u8) ParseError!Cursor {
    // `parse::take1` (`cursor.rs:225-226`).
    const version = take1(bytes) orelse return error.UnexpectedEnd;

    if (version == 0) return parse0(bytes[1..]); // cursor.rs:228-229
    if (version != version_tag) return error.InvalidValue; // cursor.rs:230-231

    // `parse::take1` (`cursor.rs:234-235`).
    const kind = take1(bytes[1..]) orelse return error.UnexpectedEnd;
    switch (kind) {
        start_tag => return .start, // cursor.rs:238
        end_tag => return .end, // cursor.rs:239
        op_tag => {},
        else => return error.InvalidValue, // cursor.rs:260
    }

    var rest = bytes[2..];

    // `parse::leb128_u64` then `parse::take_n` (`cursor.rs:241-244`). The
    // actor's bytes are a **borrowed subslice of the input**, so the declared
    // length cannot become an allocation and there is no size to check
    // against one; all that is checked is that the input holds them.
    const len = try takeLeb(rest);
    rest = rest[len.consumed..];
    const actor_bytes = takeN(rest, len.value) orelse return error.Truncated;
    rest = rest[actor_bytes.len..];

    const ctr = try takeLeb(rest); // cursor.rs:245-246
    rest = rest[ctr.consumed..];

    // `parse::take1` (`cursor.rs:247-248`).
    const move_byte = take1(rest) orelse return error.UnexpectedEnd;

    return .{
        .op = .{
            .ctr = ctr.value,
            .actor = ActorId.init(actor_bytes),
            // `_ => return Err(InvalidCursorFormat)` (`cursor.rs:256`).
            .move_cursor = MoveCursor.fromTag(move_byte) orelse return error.InvalidValue,
            // The grammar has no offset field; see the module doc.
            .offset = 0,
        },
    };
}

/// The version-0 layout (`parse_0`, `cursor.rs:265-288`).
///
/// The version byte has already been read; `rest` is everything after it. A
/// cursor written by an older version of `automerge` has to load, and
/// dropping it is a compatibility break that is invisible until someone tries.
///
/// **`After` and no start/end**, because `After` was the version-0 default
/// and there was no notion of a start or end cursor then
/// (`cursor.rs:281-287`).
///
/// **The result borrows `rest`** in the same way [`fromBytes`] borrows its
/// argument: the actor's bytes are a subslice, and there is nothing to free.
pub fn parse0(rest: []const u8) ParseError!Cursor {
    // `parse::leb128_u64` (`cursor.rs:274-275`).
    const len = try takeLeb(rest);
    const after_len = rest[len.consumed..];
    // `parse::take_n` (`cursor.rs:276-277`).
    const actor_bytes = takeN(after_len, len.value) orelse return error.Truncated;
    // `parse::leb128_u64` (`cursor.rs:278-279`).
    const ctr = try takeLeb(after_len[actor_bytes.len..]);
    return .{ .op = .{
        .ctr = ctr.value,
        .actor = ActorId.init(actor_bytes),
        .move_cursor = .after,
        .offset = 0,
    } };
}

// ── The string codec ───────────────────────────────────────────────────────

/// A cursor out of its string form (`Cursor::from_str`, `cursor.rs:92-117`).
///
/// `"s"` and `"e"` are the start and end cursors (`cursor.rs:94-99`);
/// anything else is `[`-]counter`@`hex(actor)``, where the leading `-` is
/// `MoveCursor::Before` and no prefix is `After` (`cursor.rs:102-105`). The
/// counter is `u64` decimal (`cursor.rs:108`) and the actor is lowercase or
/// uppercase hex ([types.rs:88-96](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/types.rs#L88-L96)).
///
/// `gpa` is first because the actor's bytes are **decoded into fresh memory**,
/// which is the one case where a cursor owns what it points at: an op cursor
/// the caller frees with exactly `gpa.free(c.op.actor.bytes)` once it is done,
/// and a `.start` or `.end` cursor owns nothing and must not be freed. This is
/// the opposite of [`fromBytes`], which borrows its argument. No error but
/// [`ParseError`] is possible, and no byte string panics. Upstream has two
/// inputs that trap here and this has neither:
///
/// * `""` reaches `&s[0..1]` (`cursor.rs:102`) and panics on the empty
///   slice — upstream's `s.len() == 1` arm does not catch it;
/// * a leading multi-byte character reaches the same slice and panics because
///   byte 0 is not a character boundary. This reads the byte instead, and a
///   UTF-8 lead or continuation byte is never `'-'`, so the two agree on
///   every string upstream survives.
///
/// Both refusals are `error.InvalidValue`, which is every other refusal here.
pub fn fromStr(gpa: Allocator, s: []const u8) ParseError!Cursor {
    if (s.len == 1) {
        // start and end cursors are just "s" and "e" respectively
        // (`cursor.rs:93-99`).
        if (std.mem.eql(u8, s, "s")) return .start;
        if (std.mem.eql(u8, s, "e")) return .end;
        return error.InvalidValue;
    }
    if (s.len == 0) return error.InvalidValue;

    // `MoveCursor::Before is prefixed with '-'` (`cursor.rs:101-105`).
    const biased = s[0] == '-';
    const body: []const u8 = if (biased) s[1..] else s;

    // `let n = s.find('@')?` (`cursor.rs:107`).
    const sign = std.mem.indexOfScalar(u8, body, '@') orelse return error.InvalidValue;

    const ctr = std.fmt.parseInt(u64, body[0..sign], 10) catch return error.InvalidValue;

    // `s[(n + 1)..].try_into()` (`cursor.rs:109`) — hex, and an empty actor
    // is legal because `hex::decode("")` is. [`err.hexFrom`] is this crate's
    // hex decoder ([error.zig](error.zig)); its `error.InvalidHex` is the
    // "not hex, or an odd length" answer and becomes the same single refusal
    // every other shape in this function gets.
    const bytes = err.hexFrom(gpa, body[sign + 1 ..]) catch |e| switch (e) {
        error.InvalidHex => return error.InvalidValue,
        else => |rest| return rest,
    };

    return .{
        .op = .{
            .ctr = ctr,
            .actor = ActorId.init(bytes),
            .move_cursor = if (biased) .before else .after,
            // The string form carries no offset either; see the module doc.
            .offset = 0,
        },
    };
}

/// A cursor as a string, exactly as `Display for Cursor` and
/// `Display for OpCursor` write it (`cursor.rs:179-187`, `:189-202`).
///
/// `"s"` for [`Cursor.start`], `"e"` for [`Cursor.end`], and
/// `[`-]``counter``@``hex(actor)`` otherwise. The returned slice is owned by
/// the caller and freed with `gpa`.
///
/// Like [`toBytes`], this does not write [`OpCursor.offset`]; see the module
/// doc.
pub fn toStr(gpa: Allocator, self: Cursor) ![]u8 {
    return switch (self) {
        .start => try dup(gpa, "s"),
        .end => try dup(gpa, "e"),
        .op => |op| std.fmt.allocPrint(gpa, "{s}{d}@{x}", .{
            if (op.move_cursor == .before) "-" else "",
            op.ctr,
            op.actor.bytes,
        }),
    };
}

// ── Resolution, through the op set ─────────────────────────────────────────

/// The cursor for `pos` in the sequence `obj`, biased by `move_cursor`
/// (`Automerge::get_cursor_for`, `automerge.rs:1732-1758`).
///
/// This is `ReadDoc::get_cursor_moving` (`read.rs:224-230`) minus the heads:
/// `clock` is the caller's already-resolved clock, or `null` for the
/// document's current state.
///
/// `gpa` is first because the op set's answer is an [`OpsFound`](opset/found_op.zig),
/// which owns the rows it collected.
///
/// * `obj` that is not an object is `error.NotAnObject`
///   (`automerge.rs:1739`, `:766`);
/// * `obj` that is not a list or a text is `error.InvalidOp` — **a map has no
///   cursor position** (`automerge.rs:1740-1742`);
/// * an index past the end of the sequence is `error.InvalidIndex`
///   (`automerge.rs:1753-1754`).
///
/// The offset the cursor records is the requested index less the element's
/// own start, which is zero for a list and is the distance into a text element
/// otherwise; see "The offset" in the module doc.
///
/// **The result borrows `set`.** `gpa` is released with the [`OpsFound`] this
/// call frees, and the actor's bytes are the document's own — the op set's
/// actor table — so the cursor is good for as long as `set` answers for that
/// document. See [`OpCursor`] for the other two owners.
pub fn getCursor(
    gpa: Allocator,
    set: anytype,
    obj: ExId,
    pos: CursorPosition,
    clock: ?Clock,
    move_cursor: MoveCursor,
) ResolveError!Cursor {
    const obj_type = set.objectType(obj) orelse return error.NotAnObject; // :1739
    const seq_type = obj_type.asSequenceType() orelse return error.InvalidOp; // :1740-1742

    const i = switch (pos) {
        .start => return .start, // :1744
        .end => return .end, // :1745
        .index => |v| v,
    };

    // `seek_ops_by_index` (`automerge.rs:1747-1749`).
    //
    // **The dispatcher chooses the arm**, because the arms are two answers to
    // the same question and upstream picks between them the same way: a
    // supplied clock takes the grouping arm
    // ([op_set.zig](opset/op_set.zig), `seekOpsByIndex`), and no clock takes
    // the prefix descent. The descent used to be unusable here — it could not
    // answer an index *inside* a multi-unit element, and a multi-unit element
    // is ordinary, because one row's value is a whole string and its width is
    // that string's width ([op.zig:1844-1849](opset/op.zig)), so
    // `splice_text(t, 0, 0, "ab")` writes one element two units wide.
    // `findPrefixInSlab` walked whole segments and read each as `count`
    // copies of its first value, which over-counts a literal run, so the
    // landing fell one run late and `seekTextOpsByIndexFast` refused with
    // `error.Invariant` rather than naming the wrong element. That is fixed at
    // source, in the slab walk rather than here, so the descent is the arm
    // this takes again.
    var found = try set.seekOpsByIndex(gpa, obj, i, seq_type, clock);
    defer found.deinit(gpa);

    // `OpCursor::new(op.id, ...)` over `found.ops.last()`
    // ([`automerge.rs:1751-1752`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    //
    // **The row's own id, and nothing is read off it** — not the element,
    // not the key. The module doc's "A cursor names the row the query
    // answered" is the long form; the short form is that a row's own id is
    // never the head, which is the one thing [`Op.cursor`](opset/op.zig)
    // could hand back that no query can find, and so the head is not a case
    // here at all.
    const items = found.ops.items;
    if (items.len == 0) return error.InvalidIndex; // :1753-1754
    const elem = ElemId.fromOpId(items[items.len - 1].id());

    // Upstream indexes `self.ops.actors[id.actor()]` and would panic on an
    // actor index the table does not hold
    // ([`cursor.rs:43`](../../github-automerge-automerge/rust/automerge/src/cursor.rs));
    // this port answers, so a caller gets `error.WrongActorTable` rather than
    // an abort. **Both arms are unreachable** — the id came off a row the op
    // set handed back, so its actor index is in the table, and it is not the
    // head, so `ElemId::actor` has an answer
    // ([types.zig](types.zig) on `ElemId.actor`) — and they are here so the
    // function is total over a document the index does not describe.
    const actor_index = elem.actor() orelse return error.Invariant;
    const actor = set.getActor(actor_index) orelse return error.WrongActorTable;

    // The register's own start, so the offset is measured from the element
    // and not from wherever the query happened to land. A list element's
    // start is the index itself, so the subtraction is zero there; a `set`
    // over a two-unit text element is in the same register, so **every** row
    // of that register answers the same start and the overwrite does not move
    // the offset.
    //
    // **`found.index` is that start, and it was already in hand.** This line
    // used to make a second descent — [`OpSet.seekListOpid`] — to fetch it,
    // which was the second of the two descents a round-3 audit named here,
    // and it was not the cheap shape that audit assumed. `seekListOpid`
    // answered the fast arm **and ran [`OpSet.seekListOpidSlow`] beside it
    // and compared the two**, and that slow arm walks the object's registers
    // from its first row to the row asked about (now
    // [`op_set.zig`:4071-4087](opset/op_set.zig), upstream's
    // `op_set.rs`:878-896). **So the second descent cost O(rows in the object)
    // per cursor, in every build.**
    //
    // **That comparison is behind [`OpSet.check_slow_paths`] now**
    // ([`op_set.zig`:3953-3956](opset/op_set.zig)), so a cursor pays for one
    // descent either way: upstream spells the comparison a
    // `debug_assert_eq!` (`op_set.rs:846`) and its release profile compiles
    // that out ([`rust/Cargo.toml`:14-16](../../github-automerge-automerge/rust/Cargo.toml)),
    // and the walk is O(rows in the object) here. Five cross-checks in
    // `op_set.zig` sit behind that flag ([`op_set.zig`:3746, 3953, 4346,
    // 4788, 4976](opset/op_set.zig)); the sixth,
    // [`OpSet.findOpByIdAndVis`](opset/op_set.zig), is ungated because its
    // slow arm stops at the end of the row's own register
    // (`op_set.rs:1131-1132`). **Each gated comparison has a default-build
    // witness test** that calls both arms directly, so the comparison is still
    // made — the gate decides who pays for it, not whether it happens.
    // Reading `index` off `found` instead makes a cursor O(log rows) plus one
    // register's width, which is what the first descent already costs.
    //
    // **The two numbers are the same number, and the reason is the index.**
    // `found.index` is the start of the register `seek_ops_by_index` landed
    // on — `index` unchanged for a list, where an element is one unit wide
    // ([`op_set.zig`:3839](opset/op_set.zig)), and the prefix the descent
    // consumed for a text ([`op_set.zig`:3884](opset/op_set.zig),
    // [`:3896`](opset/op_set.zig)), which is the element's start by that arm's
    // own sentence ([`op_set.zig`:3858-3860](opset/op_set.zig)). `seek_list_opid`
    // answers the start of the register the *named row* belongs to. Those are
    // one register, because every row `seek_ops_by_index` hands back is a row
    // of the register it landed on and a register carries exactly one
    // `index.top` ([`OpSet.validateTopIndex`](opset/op_set.zig), upstream's
    // `assert_eq!(first_top, last_vis)`, `op_set.rs`:196-212), so the prefix
    // before any of its rows is the same value. That is the round trip, and
    // it is structural rather than checked.
    //
    // **What the removed call was the witness for, and where it still is.**
    // It compared the fast descent against the walk. That comparison is not
    // gone: [`getCursorPosition`] makes the same call at [`:872`](cursor.zig)
    // and once per step of its backward walk at [`:914`](cursor.zig), and
    // three tests in `op_set.zig` compare the two arms directly and pin the
    // answers as literals ([`op_set.zig`:11266-11277](opset/op_set.zig),
    // [`:11330-11341`](opset/op_set.zig),
    // [`:11407-11409`](opset/op_set.zig)).
    // **The two refusals the call could raise here were unreachable**, which
    // is the same claim the two arms above it already make: the id came off
    // a row this query returned for this object, so `getOpIdPos` finds it and
    // it is inside the object's range. `error.InvalidIndex` below is the one
    // refusal this function really has, and it fires at the same place it
    // always did.
    if (found.index > i) return error.InvalidIndex;
    const offset = std.math.cast(u32, i - found.index) orelse return error.InvalidIndex;

    return .{ .op = OpCursor.init(elem, offset, move_cursor, actor) };
}

/// Where `cursor` sits in the sequence `obj` right now
/// (`Automerge::get_cursor_position_for`, `automerge.rs:1760-1849`).
///
/// **This is the bias rule**, and the module doc states all four cases with
/// their citations; the walk in the `before` arm is upstream's loop
/// (`:1817-1843`).
///
/// `clock` is `null` for the document's current state and a clock for an
/// earlier view (`automerge.rs:1765`).
///
/// * `error.NotAnObject` — `obj` is not in the index (`automerge.rs:1770`);
/// * `error.InvalidCursor` — `obj` is a map, so it has no cursor position
///   (`automerge.rs:1772-1774`), the actor is not in the document's table
///   (`automerge.rs:783-784`), the counter names no row (`:1778-1781`), the
///   clock does not cover the cursor (`:778-779`), or the element is not in
///   the object;
/// * `error.Invariant` — a row in a sequence hung by a map key, which is
///   upstream's `expect` (`automerge.rs:1813-1814`, `:1834-1837`) and cannot
///   arise from a well-formed document.
///
/// **Allocates nothing through `gpa`**, because the op set owns the
/// allocation its backward walk needs
/// ([`seekListOpidSlow`](opset/op_set.zig) uses the set's own allocator).
pub fn getCursorPosition(
    set: anytype,
    obj: ExId,
    cursor: Cursor,
    clock: ?Clock,
) ResolveError!usize {
    switch (cursor) {
        // `Cursor::Start => Ok(0)` (`automerge.rs:1767`).
        .start => return 0,
        // `Cursor::End => Ok(self.length_for(obj, clock))` (`:1768`).
        .end => return set.seqLength(obj, set.text_encoding, clock),
        .op => {},
    }
    const op = cursor.op;

    const obj_type = set.objectType(obj) orelse return error.NotAnObject; // :1770
    // `let Some(seq_type) = obj_meta.typ.as_sequence_type() else { ... }`
    // (`:1772-1774`): a map has no cursor position.
    const seq_type = obj_type.asSequenceType() orelse return error.InvalidCursor;

    // `op_cursor_to_opid` (`automerge.rs:770-786`): the actor's bytes become an
    // index (`:775`), and a clock that does not cover the cursor refuses it
    // (`:778-779`).
    const actor_index = blk: {
        const idx = set.lookupActor(op.actor) orelse return error.InvalidCursor; // :775, :783
        break :blk std.math.cast(ActorIdx, idx) orelse return error.InvalidCursor;
    };
    const elem = try op.elemId(actor_index);
    if (clock) |c| if (!c.contains(elem.id)) return error.InvalidCursor; // :778-779

    // `seek_list_opid` (`automerge.rs:1778-1781`).
    const found = (try set.seekListOpid(obj, elem.id, seq_type, clock)) orelse
        return error.InvalidCursor;

    // The element is still there, so both biases agree — the bias only
    // decides what happens once the element is *gone*. Upstream returns
    // `found.index` for both (`:1794` for `after`, `:1803-1804` for
    // `before`); this adds the offset, which is the position the cursor was
    // taken at.
    if (found.visible) return found.index + op.offset;

    switch (op.move_cursor) {
        // `MoveCursor::After => Ok(found.index)` (`automerge.rs:1794`), and
        // `found.index` is the index the removed element *would* have had,
        // which is the next visible element's index or the length
        // (`:1789-1793`).
        .after => return found.index,

        // `if found.visible || found.index == 0` (`automerge.rs:1803-1804`).
        .before => {
            if (found.index == 0) return 0;
        },
    }

    // The backward walk (`automerge.rs:1806-1843`).
    //
    // `let mut key = found.op.key.elemid()...0` (`:1812-1815`): the element
    // the cursor's own row hangs by, which is the element *before* it. It is
    // read out here, before the first query, because the port's `Op` points
    // its successors into the op set's shared buffer and the query below
    // overwrites them; upstream moves the id out for the same reason
    // (`:1831-1838`).
    var key = try seqElem(found.op);

    // Upstream's loop is unbounded. This one is bounded by the object's row
    // count, which is enough because each step moves to a strictly earlier
    // row and a document has no more rows than that; a document whose rows do
    // not strictly descend by anchor is a document this port reports rather
    // than spins on.
    const rows = try set.scopeToObj(obj);
    var budget: usize = rows.end - rows.start;
    while (budget != 0) {
        budget -= 1;
        const f = (try set.seekListOpid(obj, key.id, seq_type, clock)) orelse
            break; // reached the beginning of the sequence (`:1841`)
        if (f.visible) return f.index; // :1827-1829
        key = try seqElem(f.op); // :1831-1838
    }
    if (budget == 0) return error.Invariant;
    return 0; // `None => break Ok(0)` (`:1841`)
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// A copy of `bytes` in `gpa`. The two one- and two-byte cursor arms
/// (`cursor.rs:149-150`) go through here so they are not two literals.
fn dup(gpa: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, bytes.len);
    @memcpy(out, bytes);
    return out;
}

/// One byte, or null at the end of the input (`parse::take1`, `cursor.rs:225`).
fn take1(bytes: []const u8) ?u8 {
    if (bytes.len == 0) return null;
    return bytes[0];
}

/// `n` bytes, or null when the input holds fewer
/// (`parse::take_n`, `cursor.rs:243-244`).
fn takeN(bytes: []const u8, n: u64) ?[]const u8 {
    const want = std.math.cast(usize, n) orelse return null;
    if (bytes.len < want) return null;
    return bytes[0..want];
}

/// An unsigned LEB128 and how many bytes it took
/// (`parse::leb128_u64`, `cursor.rs:241-242`).
///
/// [`leb.readUnsigned`](leb128.zig) is already total over untrusted bytes: it
/// refuses a truncated value, an overlong one and a value that does not fit a
/// `u64`, and it consumes only the bytes the encoding used, which is what
/// lets the caller keep reading.
fn takeLeb(bytes: []const u8) ParseError!struct { value: u64, consumed: usize } {
    const r = try leb.readUnsigned(bytes);
    return .{ .value = r.value, .consumed = r.len };
}

/// The element a row in a sequence hangs by.
///
/// A row in a list or a text object always hangs by a sequence anchor: the
/// object's own creation row hangs off the *parent*, so it is not in the
/// object's range. Upstream writes `expect` here
/// (`automerge.rs:1813-1814`, `:1834-1837`); this reports
/// [`error.Invariant`], which is what [`error.zig`](error.zig) reserves for a
/// check upstream treats as impossible.
fn seqElem(row: anytype) ResolveError!ElemId {
    return switch (row.key()) {
        .seq => |e| e,
        .map => error.Invariant,
    };
}

// ── The fixture ────────────────────────────────────────────────────────────

/// The concrete op set a cursor resolves against.
///
/// `OpSet(ChangeOp)`, which is the one instantiation a document that applies
/// a change holds ([doc.zig](doc.zig) names it as `Set`, and
/// [patches.zig](patches.zig) and [opset/batch.zig](opset/batch.zig) use the
/// same one).
const Set = opset.OpSet(opmod.ChangeOp);

/// The string table a fixture's op set borrows.
///
/// **The table is the caller's and it lives in the heap**, which is
/// [op_set.zig](opset/op_set.zig)'s ownership rule rather than a convenience:
/// the op set borrows the table, so the table has to stay at one address for
/// as long as the set does, and a struct that owned the table and was then
/// returned by value would leave the set's `strings.ctx` pointing at a dead
/// frame.
const Table = struct {
    gpa: Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(gpa: Allocator) Table {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Table) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
    }

    fn asTable(self: *Table) opcols.StringTable {
        return .{ .ctx = self, .resolve = resolve, .intern = intern };
    }

    fn resolve(ctx: *const anyopaque, id: u32) []const u8 {
        const self: *const Table = @ptrCast(@alignCast(ctx));
        return self.items.items[id];
    }

    fn intern(ctx: *const anyopaque, text: []const u8, gpa: Allocator) ParseError!u32 {
        const self: *Table = @ptrCast(@alignCast(@constCast(ctx)));
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, text)) return std.math.cast(u32, i) orelse error.Overflow;
        }
        const id = std.math.cast(u32, self.items.items.len) orelse error.Overflow;
        try self.items.append(gpa, try gpa.dupe(u8, text));
        return id;
    }
};

/// One row of a fixture: everything `ChangeOp.init` takes, plus the successors
/// the row carries. A **delete is a successor edge and not a row**, which is
/// what a loaded document holds ([op_set.zig](opset/op_set.zig)'s
/// `documentRows` is the worked example).
const Rec = struct {
    ctr: u32,
    obj: ExId = .root,
    key: optypes.KeyRef,
    actor: ActorIdx = 0,
    is_insert: bool = false,
    act: optypes.Action = .set,
    val: optypes.ScalarValue = .null_value,
    mark: ?[]const u8 = null,
    expand: bool = false,
    pred: []const OpId = &.{},
    succ: ?opmod.SuccEntry = null,
};

/// One document: an op set over the actor table and the string table it
/// borrows, built in the heap so the table's address is fixed.
const Doc = struct {
    gpa: Allocator,
    table: Table,
    set: Set,

    /// A document over `actors`, which must be **sorted**: an actor index is
    /// a position in that table ([types.zig](types.zig)).
    fn init(gpa: Allocator, actors: []const ActorId) !*Doc {
        const self = try gpa.create(Doc);
        self.* = .{ .gpa = gpa, .table = .init(gpa), .set = undefined };
        self.set = Set.fromActors(gpa, actors, .unicode_code_point, self.table.asTable()) catch |e| {
            self.table.deinit();
            gpa.destroy(self);
            return e;
        };
        return self;
    }

    /// A document holding exactly `rows`, spliced in as its base.
    fn build(gpa: Allocator, actors: []const ActorId, rows: []const Rec) !*Doc {
        const self = try Doc.init(gpa, actors);
        errdefer self.destroy();
        const ops = try mkOps(gpa, rows);
        defer freeOps(gpa, ops);
        _ = try self.set.splice(0, ops);
        return self;
    }

    fn destroy(self: *Doc) void {
        self.set.deinit();
        self.table.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// The reloaded document: `exportColumns` is the save, and
    /// [`Set.load`] is the load, and it rebuilds the index from the sixteen
    /// data columns because the exporter never writes the five index columns
    /// ([op_set.zig](opset/op_set.zig)'s module doc, "The load path rebuilds
    /// the index").
    fn reload(self: *Doc, actors: []const ActorId) !*Doc {
        var exported = try self.set.exportColumns(self.gpa);
        defer exported.deinit(self.gpa);
        const out = try self.gpa.create(Doc);
        out.* = .{ .gpa = self.gpa, .table = .init(self.gpa), .set = undefined };
        out.set = Set.load(
            self.gpa,
            exported.cols,
            actors,
            .unicode_code_point,
            out.table.asTable(),
        ) catch |e| {
            out.table.deinit();
            self.gpa.destroy(out);
            return e;
        };
        return out;
    }
};

fn mkOp(gpa: Allocator, r: Rec) !opmod.ChangeOp {
    var op = try opmod.ChangeOp.init(
        gpa,
        OpId.init(r.ctr, r.actor),
        r.obj,
        r.act,
        r.key,
        r.val,
        r.is_insert,
        r.expand,
        r.mark,
        r.pred,
    );
    errdefer op.deinit(gpa);
    if (r.succ) |s| try op.succs.append(gpa, s);
    return op;
}

fn mkOps(gpa: Allocator, rows: []const Rec) ![]opmod.ChangeOp {
    const ops = try gpa.alloc(opmod.ChangeOp, rows.len);
    errdefer gpa.free(ops);
    var made: usize = 0;
    errdefer for (ops[0..made]) |*o| o.deinit(gpa);
    for (rows, 0..) |r, i| {
        ops[i] = try mkOp(gpa, r);
        made += 1;
    }
    return ops;
}

fn freeOps(gpa: Allocator, ops: []opmod.ChangeOp) void {
    for (ops) |*o| o.deinit(gpa);
    gpa.free(ops);
}

// ── The documents the tests read ───────────────────────────────────────────

/// The one actor every fixture uses.
///
/// **Eight raw bytes whose hex is `0123456789abcdef`**, and *raw* matters: an
/// actor is a byte string ([types.zig](types.zig) on `ActorId`) and the string
/// codec writes those bytes as hex ([types.rs:74-76](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/types.rs#L74-L76)),
/// so a fixture whose bytes were the ASCII of `"0123456789abcdef"` would read
/// back as `30313233…`. A sixteen-byte actor is the usual length; eight keeps
/// the pinned byte literals short and is equally valid
/// ([types.rs:45](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/types.rs#L45) is an inline array with a heap overflow, so any length is legal).
const solo_actor = [_]ActorId{.{
    .bytes = &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef },
}};

/// The text object every text fixture holds: a text object at the root under
/// `"t"`, made by op 1.
const t_obj: ExId = .{ .id = .{ .counter = 1, .actor = 0 } };

/// The list object [`two_list`] holds: a list at the root under `"l"`, made
/// by op 1.
const l_obj: ExId = .{ .id = .{ .counter = 1, .actor = 0 } };

/// The map object [`a_map`] holds, for the cases where a map is asked for a
/// position.
const m_obj: ExId = .{ .id = .{ .counter = 1, .actor = 0 } };

/// A sequence anchor, which is how a row says which element it hangs by.
fn hangs(ctr: u32) optypes.KeyRef {
    return optypes.KeyRef.fromElemId(ElemId.fromOpId(OpId.init(ctr, 0)));
}

/// The front of a sequence, which is the anchor an insert into an empty one
/// hangs by ([types.zig](types.zig) on `ElemId::head`).
fn at_head() optypes.KeyRef {
    return optypes.KeyRef.fromElemId(ElemId.head());
}

fn sval(v: []const u8) optypes.ScalarValue {
    return .{ .str = v };
}

/// One text element: `text`, hanging by `key`, made by op `ctr`.
fn chr(ctr: u32, key: optypes.KeyRef, text: []const u8) Rec {
    return .{ .ctr = ctr, .obj = t_obj, .key = key, .is_insert = true, .val = sval(text) };
}

/// The text object every `aaa@bbb` fixture opens with: op 1 makes it, and ops
/// 2 to 8 are the seven characters `a`, `a`, `a`, `@`, `b`, `b`, `b`.
const aaa_at_bbb = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "a"),
    chr(3, hangs(2), "a"),
    chr(4, hangs(3), "a"),
    chr(5, hangs(4), "@"),
    chr(6, hangs(5), "b"),
    chr(7, hangs(6), "b"),
    chr(8, hangs(7), "b"),
};

/// **`splice_text(3, 1, "~~~")`**: the `@` at index 3 is replaced by three
/// tildes. The new elements hang by the third `a`, which is op 4, and so
/// sort between it and the `@` (op 5) — which is why the rows are in that
/// order and not in op order. The `@` keeps its row and loses its width: a
/// delete is a successor edge on the row it removes.
const tildes = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "a"),
    chr(3, hangs(2), "a"),
    chr(4, hangs(3), "a"),
    chr(9, hangs(4), "~"),
    chr(10, hangs(9), "~"),
    chr(11, hangs(10), "~"),
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("@"), .succ = killed(12) },
    chr(6, hangs(5), "b"),
    chr(7, hangs(6), "b"),
    chr(8, hangs(7), "b"),
};

/// **`splice_text(0, 6, "")`** on [`tildes`]: the first six elements go, and
/// only `bbb` is left.
const bbb = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    .{ .ctr = 2, .obj = t_obj, .key = at_head(), .is_insert = true, .val = sval("a"), .succ = killed(20) },
    .{ .ctr = 3, .obj = t_obj, .key = hangs(2), .is_insert = true, .val = sval("a"), .succ = killed(21) },
    .{ .ctr = 4, .obj = t_obj, .key = hangs(3), .is_insert = true, .val = sval("a"), .succ = killed(22) },
    .{ .ctr = 9, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("~"), .succ = killed(23) },
    .{ .ctr = 10, .obj = t_obj, .key = hangs(9), .is_insert = true, .val = sval("~"), .succ = killed(24) },
    .{ .ctr = 11, .obj = t_obj, .key = hangs(10), .is_insert = true, .val = sval("~"), .succ = killed(25) },
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("@"), .succ = killed(12) },
    chr(6, hangs(5), "b"),
    chr(7, hangs(6), "b"),
    chr(8, hangs(7), "b"),
};

/// **`splice_text(0, 0, "hello")`** on [`bbb`]: five elements at the front.
/// They hang by the head, and the head is the minimum element
/// ([types.zig](types.zig), `ElemId::compare`), so they sort before every
/// other element whatever their counters are.
const hellobbb = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(13, at_head(), "h"),
    chr(14, hangs(13), "e"),
    chr(15, hangs(14), "l"),
    chr(16, hangs(15), "l"),
    chr(17, hangs(16), "o"),
    .{ .ctr = 2, .obj = t_obj, .key = at_head(), .is_insert = true, .val = sval("a"), .succ = killed(20) },
    .{ .ctr = 3, .obj = t_obj, .key = hangs(2), .is_insert = true, .val = sval("a"), .succ = killed(21) },
    .{ .ctr = 4, .obj = t_obj, .key = hangs(3), .is_insert = true, .val = sval("a"), .succ = killed(22) },
    .{ .ctr = 9, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("~"), .succ = killed(23) },
    .{ .ctr = 10, .obj = t_obj, .key = hangs(9), .is_insert = true, .val = sval("~"), .succ = killed(24) },
    .{ .ctr = 11, .obj = t_obj, .key = hangs(10), .is_insert = true, .val = sval("~"), .succ = killed(25) },
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("@"), .succ = killed(12) },
    chr(6, hangs(5), "b"),
    chr(7, hangs(6), "b"),
    chr(8, hangs(7), "b"),
};

/// **`splice_text(0, 6, "")`** on [`hellobbb`], which leaves `hello`. Every
/// element is gone but the five at the front, so a cursor on any of the rest
/// has nothing left to point at.
const hello = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(13, at_head(), "h"),
    chr(14, hangs(13), "e"),
    chr(15, hangs(14), "l"),
    chr(16, hangs(15), "l"),
    chr(17, hangs(16), "o"),
    .{ .ctr = 2, .obj = t_obj, .key = at_head(), .is_insert = true, .val = sval("a"), .succ = killed(20) },
    .{ .ctr = 3, .obj = t_obj, .key = hangs(2), .is_insert = true, .val = sval("a"), .succ = killed(21) },
    .{ .ctr = 4, .obj = t_obj, .key = hangs(3), .is_insert = true, .val = sval("a"), .succ = killed(22) },
    .{ .ctr = 9, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("~"), .succ = killed(23) },
    .{ .ctr = 10, .obj = t_obj, .key = hangs(9), .is_insert = true, .val = sval("~"), .succ = killed(24) },
    .{ .ctr = 11, .obj = t_obj, .key = hangs(10), .is_insert = true, .val = sval("~"), .succ = killed(25) },
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("@"), .succ = killed(12) },
    .{ .ctr = 6, .obj = t_obj, .key = hangs(5), .is_insert = true, .val = sval("b"), .succ = killed(26) },
    .{ .ctr = 7, .obj = t_obj, .key = hangs(6), .is_insert = true, .val = sval("b"), .succ = killed(27) },
    .{ .ctr = 8, .obj = t_obj, .key = hangs(7), .is_insert = true, .val = sval("b"), .succ = killed(28) },
};

/// **`splice_text(3, 3, "!!!")`** on [`aaa_at_bbb`]: the `@` and the first two
/// `b`s go and three bangs take their place. The `before` and `after` answers
/// are the same as [`tildes`] and the length is not, which is the pair of
/// cases that keeps the two fixtures from being one fixture written twice.
const bangs = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "a"),
    chr(3, hangs(2), "a"),
    chr(4, hangs(3), "a"),
    chr(9, hangs(4), "!"),
    chr(10, hangs(9), "!"),
    chr(11, hangs(10), "!"),
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("@"), .succ = killed(12) },
    .{ .ctr = 6, .obj = t_obj, .key = hangs(5), .is_insert = true, .val = sval("b"), .succ = killed(13) },
    .{ .ctr = 7, .obj = t_obj, .key = hangs(6), .is_insert = true, .val = sval("b"), .succ = killed(14) },
    chr(8, hangs(7), "b"),
};

/// `hello world` as eleven one-unit elements, ops 2 to 12.
const hello_world = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "h"),
    chr(3, hangs(2), "e"),
    chr(4, hangs(3), "l"),
    chr(5, hangs(4), "l"),
    chr(6, hangs(5), "o"),
    chr(7, hangs(6), " "),
    chr(8, hangs(7), "w"),
    chr(9, hangs(8), "o"),
    chr(10, hangs(9), "r"),
    chr(11, hangs(10), "l"),
    chr(12, hangs(11), "d"),
};

/// **`splice_text(3, 6, " new text ")`** on [`hello_world`]: the six
/// characters at indices 3 to 9 go and ten take their place, so the `w` the
/// test's cursor names is one of the six and the cursor has to move.
const spliced_world = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "h"),
    chr(3, hangs(2), "e"),
    chr(4, hangs(3), "l"),
    chr(13, hangs(4), " "),
    chr(14, hangs(13), "n"),
    chr(15, hangs(14), "e"),
    chr(16, hangs(15), "w"),
    chr(17, hangs(16), " "),
    chr(18, hangs(17), "t"),
    chr(19, hangs(18), "e"),
    chr(20, hangs(19), "x"),
    chr(21, hangs(20), "t"),
    chr(22, hangs(21), " "),
    .{ .ctr = 5, .obj = t_obj, .key = hangs(4), .is_insert = true, .val = sval("l"), .succ = killed(23) },
    .{ .ctr = 6, .obj = t_obj, .key = hangs(5), .is_insert = true, .val = sval("o"), .succ = killed(24) },
    .{ .ctr = 7, .obj = t_obj, .key = hangs(6), .is_insert = true, .val = sval(" "), .succ = killed(25) },
    .{ .ctr = 8, .obj = t_obj, .key = hangs(7), .is_insert = true, .val = sval("w"), .succ = killed(26) },
    .{ .ctr = 9, .obj = t_obj, .key = hangs(8), .is_insert = true, .val = sval("o"), .succ = killed(27) },
    .{ .ctr = 10, .obj = t_obj, .key = hangs(9), .is_insert = true, .val = sval("r"), .succ = killed(28) },
    chr(11, hangs(10), "l"),
    chr(12, hangs(11), "d"),
};

/// **`splice_text(11, 0, "!")`** on [`hello_world`]: one character after the
/// end. The `w` the test's cursor names is untouched, and that is the whole
/// point of the case.
const world_bang = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "h"),
    chr(3, hangs(2), "e"),
    chr(4, hangs(3), "l"),
    chr(5, hangs(4), "l"),
    chr(6, hangs(5), "o"),
    chr(7, hangs(6), " "),
    chr(8, hangs(7), "w"),
    chr(9, hangs(8), "o"),
    chr(10, hangs(9), "r"),
    chr(11, hangs(10), "l"),
    chr(12, hangs(11), "d"),
    chr(13, hangs(12), "!"),
};

/// **`splice_text(0, 0, "XY")`** on [`hello_world`]: two characters at the
/// front, which the `w` cursor has to move past.
const xy_world = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(13, at_head(), "X"),
    chr(14, hangs(13), "Y"),
    chr(2, at_head(), "h"),
    chr(3, hangs(2), "e"),
    chr(4, hangs(3), "l"),
    chr(5, hangs(4), "l"),
    chr(6, hangs(5), "o"),
    chr(7, hangs(6), " "),
    chr(8, hangs(7), "w"),
    chr(9, hangs(8), "o"),
    chr(10, hangs(9), "r"),
    chr(11, hangs(10), "l"),
    chr(12, hangs(11), "d"),
};

/// A text object whose **first element is two units wide**: op 2 carries the
/// string `"ab"` and op 3 carries `"c"`, so the object reads `"abc"`, element
/// 0 spans units 0 and 1, and element 1 is unit 2.
const wide = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(2, at_head(), "ab"),
    chr(3, hangs(2), "c"),
};

/// **`splice_text(0, 0, "XY")`** on [`wide`], so the wide element moves from
/// units 0 and 1 to units 2 and 3 and a cursor inside it has to move with it.
const wide_xy = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    chr(13, at_head(), "X"),
    chr(14, hangs(13), "Y"),
    chr(2, at_head(), "ab"),
    chr(3, hangs(2), "c"),
};

/// A list holding one element that was never inserted: op 2 is a `set` at
/// index 0 of an empty list, so it hangs by the **head**.
///
/// This is the row whose **element** names no operation, and it is why
/// [`getCursor`] asks for the row's own id rather than for its element: the
/// element is the head, and a cursor built on it resolves to nothing.
const head_set_list = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("l"), .act = .make_list },
    .{ .ctr = 2, .obj = l_obj, .key = at_head(), .val = sval("x") },
};

/// A map with one key, for the cases where a map is asked for a position.
const a_map = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("m"), .act = .make_map },
    .{ .ctr = 2, .obj = m_obj, .key = .fromStr("a"), .val = sval("b") },
};

/// **A list with a map key in it**, which is the case that is easy to get
/// wrong: the object is a sequence and the row is not. [`Op.cursor`] has no
/// answer for that row — it is a map key — and [`getCursor`] mints a cursor
/// on it anyway, because upstream does and the cursor resolves.
const a_list = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("l"), .act = .make_list },
    .{ .ctr = 2, .obj = l_obj, .key = .fromStr("a"), .val = sval("b") },
};

/// A list of two elements, for the list cases and the construction test.
const two_list = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("l"), .act = .make_list },
    .{ .ctr = 2, .obj = l_obj, .key = at_head(), .is_insert = true, .val = sval("a") },
    .{ .ctr = 3, .obj = l_obj, .key = hangs(2), .is_insert = true, .val = sval("b") },
};

/// A list whose only element was **overwritten**: op 2 inserts `"a"` at the
/// head, op 3 sets `"b"` over it, and op 3's key is the element op 2 made.
///
/// **The successor edge on op 2 is the whole fixture, and it was missing.**
/// `local_list_op` puts one on **every** row of the register it overwrites
/// ([`inner.rs:549-553`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs),
/// the port's `Transaction.localListOp` at `transact.zig:816-818`), which is
/// what makes the overwritten row stop being visible
/// ([op.rs:1148-1156](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs)).
/// Without it, `Op::top` is `Op::visible` for both rows and the register
/// carries **two** winners — a document no merge and no load can produce,
/// which [`OpSet.validateTopIndex`](opset/op_set.zig) reports as
/// `final_group_mismatch { at = 3, first_top = 1, last_vis = 2 }` (upstream's
/// `assert_eq!(first_top, last_vis)`,
/// [op_set.rs:196-212](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)).
/// The fixture was that document; the error was the assertion working.
///
/// With the edge there, op 2 is invisible and `seekOpsByIndex` hands back **one**
/// row for index `0` — op 3 — which is the group a reader sees
/// ([found_op.rs:61-68](opset/found_op.zig)). See the module doc's "A cursor
/// names the row the query answered".
const set_over_insert = [_]Rec{
    .{ .ctr = 1, .key = .fromStr("l"), .act = .make_list },
    // The edge is spelled out because `killed` is the *delete's* edge by name
    // and a `set` shadows rather than kills. The value is the same shape:
    // upstream's `add_succ(id, None)`.
    .{ .ctr = 2, .obj = l_obj, .key = at_head(), .is_insert = true, .val = sval("a"), .succ = .{ .id = OpId.init(3, 0), .inc = null } },
    .{ .ctr = 3, .obj = l_obj, .key = hangs(2), .val = sval("b") },
};

/// The successor a delete leaves on the row it removes: the id of the delete
/// operation and no increment, because a delete is not an increment
/// ([op.zig](opset/op.zig) on `Op.visible`). An **overwrite** leaves the same
/// shape on the row it shadows
/// ([`inner.rs:549-553`](../../github-automerge-automerge/rust/automerge/src/transaction/inner.rs))
/// — [`set_over_insert`] spells that one out inline, because this one's name
/// says delete.
fn killed(ctr: u32) opmod.SuccEntry {
    return .{ .id = OpId.init(ctr, 0), .inc = null };
}

/// A counting allocator, which is how "allocates nothing" is measured.
///
/// The same instrument as [opset/marks.zig](opset/marks.zig)'s and
/// [op_iter.zig](opset/op_iter.zig)'s, and the reason it is needed: a
/// constructor that allocated and one that did not both return a perfectly
/// usable value, so no other means tells them apart.
const Counting = struct {
    inner: Allocator,
    count: usize = 0,

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, ra: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.inner.rawAlloc(len, ra, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, ra, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, ra: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, ra, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        ra: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, ra, new_len, ret_addr);
    }
};

// ── The v1 codec, pinned as literal bytes ──────────────────────────────────

test "the v1 codec is the grammar, byte for byte, in both directions" {
    const gpa = testing.allocator;

    // `cursor = version (start / end / opid)`; the two arms with no payload
    // are two bytes.
    {
        const start: Cursor = .start;
        const end: Cursor = .end;
        const a = try toBytes(gpa, start);
        defer gpa.free(a);
        const b = try toBytes(gpa, end);
        defer gpa.free(b);
        try testing.expectEqualSlices(u8, &.{ 0x01, 0x01 }, a);
        try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, b);
        try testing.expect((try fromBytes(&.{ 0x01, 0x01 })).eql(start));
        try testing.expect((try fromBytes(&.{ 0x01, 0x02 })).eql(end));
    }

    // `opid = opid_tag actor_id counter move`, with a four-byte actor:
    // version, tag, the actor's length as a uleb128, the actor, the counter,
    // the move.
    {
        const actor = ActorId.init("dead");
        const c: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(3, 0)), 0, .after, actor) };
        const want = [_]u8{ 0x01, 0x03, 0x04, 'd', 'e', 'a', 'd', 0x03, 0x02 };
        const got = try toBytes(gpa, c);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, &want, got);
        try testing.expect((try fromBytes(&want)).eql(c));
    }

    // The same with the other bias: the move byte is the **last** byte and
    // `1` is `before`.
    {
        const actor = ActorId.init("dead");
        const c: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(3, 0)), 0, .before, actor) };
        const want = [_]u8{ 0x01, 0x03, 0x04, 'd', 'e', 'a', 'd', 0x03, 0x01 };
        const got = try toBytes(gpa, c);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, &want, got);
        try testing.expect((try fromBytes(&want)).eql(c));
    }

    // A cursor in text at a grapheme boundary: a sixteen-byte actor, so the
    // length prefix is `0x10` and the actor runs to the counter.
    {
        const c: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(7, 0)), 0, .after, wide_actor) };
        // `version`, `opid_tag`, the actor's length, the actor, the counter,
        // the move.
        const want = [_]u8{ 0x01, 0x03, 0x10 } ++ actor16 ++ [_]u8{ 0x07, 0x02 };
        const got = try toBytes(gpa, c);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, &want, got);
        try testing.expect((try fromBytes(&want)).eql(c));
    }

    // A cursor two units into a two-unit element, and the same element at
    // offset 0. **The bytes are the same**, because `opid` has no offset
    // field, and the decode answers offset 0. Pinned rather than assumed:
    // this is the one place the grammar and this port's `OpCursor` disagree,
    // and a reader has to be able to see that they do.
    {
        const edge: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(2, 0)), 0, .after, wide_actor) };
        const inside: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(2, 0)), 2, .after, wide_actor) };
        const want = [_]u8{ 0x01, 0x03, 0x10 } ++ actor16 ++ [_]u8{ 0x02, 0x02 };
        const inside_bytes = try toBytes(gpa, inside);
        defer gpa.free(inside_bytes);
        const edge_bytes = try toBytes(gpa, edge);
        defer gpa.free(edge_bytes);
        try testing.expectEqualSlices(u8, &want, inside_bytes);
        try testing.expectEqualSlices(u8, &want, edge_bytes);
        try testing.expectEqualSlices(u8, inside_bytes, edge_bytes);

        const back = try fromBytes(&want);
        try testing.expect(back.eql(edge));
        try testing.expect(!back.eql(inside));
        try testing.expectEqual(@as(u32, 0), back.op.offset);
    }

    // The largest encodable value: a counter of `u64`'s maximum, which is
    // nine `0xff` bytes and one `0x01`, and a twenty-byte actor.
    {
        var twenty: [20]u8 = undefined;
        for (&twenty, 0..) |*b, i| b.* = @intCast(i);
        // The counter is written by hand because `OpCursor.init` takes the
        // element's own counter, which is a `u32`.
        const c: Cursor = .{ .op = .{
            .ctr = std.math.maxInt(u64),
            .actor = ActorId.init(&twenty),
            .move_cursor = .after,
            .offset = 0,
        } };
        // `0x01` version, `0x03` opid_tag, `0x14` the actor's length, the
        // twenty actor bytes, the counter, `0x02` the move.
        const want = [_]u8{ 0x01, 0x03, 0x14 } ++ twenty ++ counter_max ++ [_]u8{0x02};
        const got = try toBytes(gpa, c);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, &want, got);
        const back = try fromBytes(&want);
        try testing.expectEqual(std.math.maxInt(u64), back.op.ctr);
        // A counter no row can carry is refused when it is resolved, not when
        // it is read, which is what keeps the reader's grammar unbounded.
        try testing.expectError(error.InvalidCursor, back.op.elemId(0));
    }
}

/// Sixteen bytes, the usual length of an actor id, as the ASCII the codec
/// test writes them in. The bytes pass through the codec unchanged, which is
/// the point: `actor_id = uleb128 bytes` (`cursor.rs:141`) says nothing about
/// what is in them.
const actor16 = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };

/// The actor over [`actor16`] in the two cases above.
const wide_actor: ActorId = .{ .bytes = &actor16 };

/// `u64`'s maximum as unsigned LEB128: nine `0xff` bytes carrying 63 bits and
/// one `0x01` carrying the last ([leb128.zig](leb128.zig)'s `max_unsigned_size`
/// is ten, and the tenth byte may hold one bit).
const counter_max = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };

test "every byte string is refused, never trapped on, and trailing bytes are ignored" {
    // Upstream's own two refusals (`automerge/tests.rs:217-220`).
    try testing.expectError(error.Truncated, fromBytes(&.{ 0, 3, 10 }));

    // Nothing at all, and a version with nothing after it.
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{}));
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{0x01}));

    // A version that is neither 0 nor 1 (`cursor.rs:230-231`).
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x02, 0x01 }));
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0xff, 0x01 }));

    // A tag that is none of the three (`cursor.rs:260`).
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x01, 0x00 }));
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x01, 0x04 }));

    // An actor length the input cannot hold: it is 4 and one byte follows,
    // and it is 2^63 and nothing follows.
    try testing.expectError(error.Truncated, fromBytes(&.{ 0x01, 0x03, 0x04, 0x61 }));
    try testing.expectError(
        error.Truncated,
        fromBytes(&.{ 0x01, 0x03, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }),
    );
    // A counter that runs off the end — two continuation bytes and nothing
    // else — and one that is overlong: eleven bytes, one more than a `u64`
    // takes ([leb128.zig](leb128.zig)'s `max_unsigned_size`).
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{ 0x01, 0x03, 0x00, 0x80, 0x80 }));
    try testing.expectError(
        error.InvalidLeb128,
        fromBytes(&([_]u8{ 0x01, 0x03, 0x00 } ++ ([_]u8{0x80} ** 11))),
    );
    // A missing move byte, and a move byte that is neither tag
    // (`cursor.rs:247-248`, `:256`).
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{ 0x01, 0x03, 0x00, 0x05 }));
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x01, 0x03, 0x00, 0x05, 0x00 }));
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x01, 0x03, 0x00, 0x05, 0x03 }));

    // **Trailing bytes are ignored**, which is upstream's `_i` binding at
    // `cursor.rs:247` and not an oversight: a cursor read out of a larger
    // buffer is the same cursor.
    const trailing = try fromBytes(&.{ 0x01, 0x01, 0xde, 0xad, 0xbe, 0xef });
    try testing.expect(trailing.eql(.start));

    // A hostile actor length is a bounded subtraction, not an allocation: the
    // actor's bytes are a subslice of the input.
    try testing.expectError(
        error.Truncated,
        fromBytes(&.{ 0x01, 0x03, 0xff, 0xff, 0xff, 0xff, 0x7f }),
    );

    // **The reader takes no allocator at all**, which is stronger than
    // "allocates nothing": every actor it hands out is a subslice of the
    // caller's own buffer, and that is why a hostile declared length cannot
    // become an allocation. The two pointer values say so directly.
    const input = [_]u8{ 0x01, 0x03, 0x04, 'd', 'e', 'a', 'd', 0x03, 0x02 };
    const c = try fromBytes(&input);
    try testing.expectEqualSlices(u8, input[3..7], c.op.actor.bytes);
    try testing.expectEqual(
        @intFromPtr(&input) + 3,
        @intFromPtr(c.op.actor.bytes.ptr),
    );
    try testing.expectEqual(@as(u64, 3), c.op.ctr);
    try testing.expectEqual(MoveCursor.after, c.op.move_cursor);
}

// ── The v0 parser ──────────────────────────────────────────────────────────

test "a version-0 cursor decodes to the same cursor as the version-1 one" {
    const gpa = testing.allocator;

    // `.----------------------------------------------------------------.
    // | version   | actorId len     | actorId bytes | counter          |
    // +----------------------------------------------------------------+
    // |  1 byte   | unsigned leb128 | variable      | unsigned leb128  |
    // '----------------------------------------------------------------'`
    // (`cursor.rs:266-272`)
    const v0 = [_]u8{ 0x00, 0x10, '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', 0x05 };
    const v1 = [_]u8{ 0x01, 0x03, 0x10, '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', 0x05, 0x02 };

    const old = try fromBytes(&v0);
    const new = try fromBytes(&v1);

    // The two differ in exactly one way upstream says they do: `After` was
    // the version-0 default and there was no start or end cursor then
    // (`cursor.rs:281-287`).
    try testing.expect(old.eql(new));
    try testing.expectEqual(MoveCursor.after, old.op.move_cursor);

    // And the bias a v0 cursor could never carry is the one it gets, so a
    // document saved under version 0 resolves exactly as it did then.
    try testing.expectEqual(@as(u64, 5), old.op.ctr);
    try testing.expectEqualSlices(u8, "0123456789abcdef", old.op.actor.bytes);

    // A v0 cursor and the v1 cursor that spells the same element write the
    // same bytes, because the bias is the only difference and it is the last
    // byte.
    const written = try toBytes(gpa, old);
    defer gpa.free(written);
    try testing.expectEqualSlices(u8, &v1, written);

    // A v0 cursor with an empty actor is legal: `hex::decode("")` is.
    const bare = try fromBytes(&.{ 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 0), bare.op.ctr);
    try testing.expectEqual(@as(usize, 0), bare.op.actor.bytes.len);
}

test "a malformed version-0 cursor is refused, never crashed on" {
    // The actor length is larger than what follows: upstream's own case
    // (`automerge/tests.rs:217-220`).
    try testing.expectError(error.Truncated, fromBytes(&.{ 0, 3, 10 }));
    // Nothing after the version byte.
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{0}));
    // The actor's length itself is truncated: every byte continues.
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{ 0, 0x80, 0x80 }));
    // The actor's length is overlong.
    try testing.expectError(error.InvalidLeb128, fromBytes(&([_]u8{0} ++ ([_]u8{0x80} ** 11))));
    // The actor is there and the counter is not.
    try testing.expectError(error.UnexpectedEnd, fromBytes(&.{ 0, 2, 'a', 'b' }));
    // The counter is truncated.
    try testing.expectError(
        error.UnexpectedEnd,
        fromBytes(&.{ 0, 1, 'a', 0x80 }),
    );
    // A counter that does not fit a u64.
    try testing.expectError(
        error.Overflow,
        fromBytes(&([_]u8{0} ++ ([_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }))),
    );
}

// ── The string codec ───────────────────────────────────────────────────────

test "the string codec is `[-]counter@hex(actor)`, and a round trip through it is exact" {
    const gpa = testing.allocator;

    // Every string the reader hands back owns its actor's bytes, and this is
    // the reader's own test, so the frees are part of it: a reader that leaked
    // fails here rather than in a leak checker.
    {
        const s = try fromStr(gpa, "s");
        try testing.expect(s.eql(.start));
    }
    {
        const e = try fromStr(gpa, "e");
        try testing.expect(e.eql(.end));
    }
    {
        const out = try toStr(gpa, .start);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, "s", out);
    }
    {
        const out = try toStr(gpa, .end);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, "e", out);
    }

    // The fixture's actor: eight raw bytes whose hex is `0123456789abcdef`.
    const actor = solo_actor[0];
    {
        const c: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(6, 0)), 0, .after, actor) };
        const want = "6@0123456789abcdef";
        const out = try toStr(gpa, c);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, want, out);
        const back = try fromStr(gpa, want);
        defer gpa.free(back.op.actor.bytes);
        try testing.expect(back.eql(c));
    }
    {
        // The bias is the leading `-` (`cursor.rs:102-105`) and nothing else.
        const c: Cursor = .{ .op = .init(ElemId.fromOpId(OpId.init(6, 0)), 0, .before, actor) };
        const want = "-6@0123456789abcdef";
        const out = try toStr(gpa, c);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, want, out);
        const back = try fromStr(gpa, want);
        defer gpa.free(back.op.actor.bytes);
        try testing.expect(back.eql(c));
        try testing.expect(!back.eql(.{ .op = .init(ElemId.fromOpId(OpId.init(6, 0)), 0, .after, actor) }));
    }
    {
        // A counter above a `u32` parses: the string form is not bounded by
        // a document's, for the same reason the bytes are not.
        const c: Cursor = .{ .op = .{
            .ctr = 18446744073709551615,
            .actor = ActorId.init(&[_]u8{0xff}),
            .move_cursor = .after,
            .offset = 0,
        } };
        const want = "18446744073709551615@ff";
        const out = try toStr(gpa, c);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, want, out);
        const back = try fromStr(gpa, want);
        defer gpa.free(back.op.actor.bytes);
        try testing.expect(back.eql(c));
    }
    {
        // An empty actor is legal here too, and `0@` is the shortest op
        // cursor there is.
        const back = try fromStr(gpa, "0@");
        defer gpa.free(back.op.actor.bytes);
        try testing.expectEqual(@as(u64, 0), back.op.ctr);
        try testing.expectEqual(@as(usize, 0), back.op.actor.bytes.len);
        const out = try toStr(gpa, back);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, "0@", out);
    }
    {
        // Uppercase hex decodes to the same actor as lowercase, and the
        // writer emits lowercase (`hex::encode`, `types.rs:74-76`).
        const back = try fromStr(gpa, "1@AABB");
        defer gpa.free(back.op.actor.bytes);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, back.op.actor.bytes);
        const out = try toStr(gpa, back);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, "1@aabb", out);
    }
}

test "a malformed cursor string is refused, and a leading multi-byte character is not a panic" {
    const gpa = testing.allocator;

    // Upstream's own two refusals (`automerge/tests.rs:221-224`).
    try testing.expectError(error.InvalidValue, fromStr(gpa, "notacursor"));
    // Empty, and one character that is neither `s` nor `e` (`cursor.rs:93-99`).
    try testing.expectError(error.InvalidValue, fromStr(gpa, ""));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "x"));
    // No `@` (`cursor.rs:107`).
    try testing.expectError(error.InvalidValue, fromStr(gpa, "6"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "-6"));
    // Nothing before the `@`, which is upstream's `"".parse()` failing.
    try testing.expectError(error.InvalidValue, fromStr(gpa, "@aabb"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "-@aabb"));
    // A counter that is not a `u64` (`cursor.rs:108`).
    try testing.expectError(error.InvalidValue, fromStr(gpa, "x@aabb"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "1.5@aabb"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "18446744073709551616@aabb"));
    // An actor that is not hex (`types.rs:88-96`), and one of odd length.
    try testing.expectError(error.InvalidValue, fromStr(gpa, "1@zz"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "1@a"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "1@aabbcc0"));

    // **Upstream slices at byte 0** (`cursor.rs:102`) and a `str` slice that
    // is not on a character boundary panics; this reads the byte. The answer
    // is the same as the one upstream reaches for a single-byte non-`-`
    // prefix: the string is not a cursor.
    try testing.expectError(error.InvalidValue, fromStr(gpa, "é6@aabb"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "€@aabb"));

    // **`-1@aabb` is not a refusal and must not be tested as one**: the `-`
    // is the bias prefix (`cursor.rs:102-105`) and `1` is a `u64`, so it is a
    // `before` cursor on counter one. Pinned here because a reader who
    // expected the `-` to be part of the number would get it wrong the other
    // way.
    {
        const biased = try fromStr(gpa, "-1@aabb");
        defer gpa.free(biased.op.actor.bytes);
        try testing.expectEqual(MoveCursor.before, biased.op.move_cursor);
        try testing.expectEqual(@as(u64, 1), biased.op.ctr);
        try testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, biased.op.actor.bytes);
    }

    // Nothing above traps, and the refusals are refusals rather than empty
    // answers: a caller that ignores the error gets no cursor at all.
    try testing.expect(fromStr(gpa, "6@zz") catch |e| e == error.InvalidValue);
}

// ── Where a cursor is made ─────────────────────────────────────────────────

/// The two cursors every `aaa@bbb` case makes: the same element, biased each
/// way. Upstream makes exactly these two
/// ([automerge/tests.rs:249-254](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/automerge/tests.rs#L249-L254)),
/// which is why the bias table below is a table and not a set of unrelated
/// cases.
fn bias_pair(gpa: Allocator, doc: *Doc) ![2]Cursor {
    return .{
        try getCursor(gpa, &doc.set, t_obj, .fromIndex(3), null, .before),
        try getCursor(gpa, &doc.set, t_obj, .fromIndex(3), null, .after),
    };
}

/// Where `c` sits in `t_obj` in `doc`'s current state.
fn at(gpa: Allocator, doc: *Doc, c: Cursor) !usize {
    _ = gpa;
    return getCursorPosition(&doc.set, t_obj, c, null);
}

test "the start and end cursors follow the sequence, and an index past the end is refused" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &aaa_at_bbb);
    defer doc.destroy();

    // `aaa@bbb` is seven elements, so the end is 7 (`automerge.rs:1768`).
    try testing.expectEqual(@as(usize, 0), try at(gpa, doc, .start));
    try testing.expectEqual(@as(usize, 7), try at(gpa, doc, .end));
    try testing.expectEqual(@as(usize, 7), try doc.set.seqLength(t_obj, .unicode_code_point, null));

    // Every index in the sequence names an element, and the one past the end
    // names nothing (`automerge.rs:1751-1754`).
    for (0..7) |i| {
        const c = try getCursor(gpa, &doc.set, t_obj, .fromIndex(i), null, .after);
        try testing.expectEqual(i, try at(gpa, doc, c));
    }
    try testing.expectError(
        error.InvalidIndex,
        getCursor(gpa, &doc.set, t_obj, .fromIndex(7), null, .after),
    );
    try testing.expectError(
        error.InvalidIndex,
        getCursor(gpa, &doc.set, t_obj, .fromIndex(1000), null, .before),
    );

    // The index past the end of an *empty* sequence is refused the same way,
    // so a checker is not an accident of a document that has content.
    const empty = try Doc.build(gpa, &solo_actor, &[_]Rec{
        .{ .ctr = 1, .key = .fromStr("t"), .act = .make_text },
    });
    defer empty.destroy();
    try testing.expectEqual(@as(usize, 0), try at(gpa, empty, .start));
    try testing.expectEqual(@as(usize, 0), try at(gpa, empty, .end));
    try testing.expectError(
        error.InvalidIndex,
        getCursor(gpa, &empty.set, t_obj, .fromIndex(0), null, .after),
    );
}

test "a cursor in a list is one element wide, so its offset is always zero" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &two_list);
    defer doc.destroy();

    try testing.expectEqual(@as(usize, 2), try doc.set.seqLength(l_obj, .unicode_code_point, null));
    for (0..2) |i| {
        const c = try getCursor(gpa, &doc.set, l_obj, .fromIndex(i), null, .after);
        try testing.expectEqual(@as(u32, 0), c.op.offset);
        try testing.expectEqual(i, try getCursorPosition(&doc.set, l_obj, c, null));
    }
    // The element of the first is the head-anchored insert, and the second
    // hangs by it. The cursor names the element, not the anchor.
    const first = try getCursor(gpa, &doc.set, l_obj, .fromIndex(0), null, .after);
    try testing.expectEqual(@as(u64, 2), first.op.ctr);
    const second = try getCursor(gpa, &doc.set, l_obj, .fromIndex(1), null, .after);
    try testing.expectEqual(@as(u64, 3), second.op.ctr);
}

test "a row that hangs by the head is still reachable, which is why the head is not the element" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &head_set_list);
    defer doc.destroy();

    // **The head is the trap, and it is a trap for the *element*.**
    // `Op.cursor` answers the head for this row, and the head is `(absent
    // actor, zero counter)` and names no operation, so a cursor built from it
    // would resolve to nothing. `getCursor` never asks for an element: it
    // takes the row's own id (`automerge.rs:1752`), which is op 2 here and is
    // a real row whether or not the row is an insert.
    const row = (try doc.set.get(1)).?;
    try testing.expect(!row.insert());
    try testing.expect(optypes.KeyRef.eql(row.key(), optypes.KeyRef.fromElemId(ElemId.head())));
    try testing.expect((try row.cursor()).isHead());
    try testing.expectEqual(OpId.root, (try row.cursor()).id);

    // So the cursor names op 2 — the row's own id, not the head — and it
    // resolves to index 0, which is the only index there is.
    const c = try getCursor(gpa, &doc.set, l_obj, .fromIndex(0), null, .after);
    try testing.expectEqual(@as(u64, 2), c.op.ctr);
    try testing.expectEqual(@as(u32, 0), c.op.offset);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, l_obj, c, null));
    try testing.expectEqual(@as(usize, 1), try doc.set.seqLength(l_obj, .unicode_code_point, null));

    // **A checker that cannot fail is not a checker.** Above, `Op.cursor`
    // answered the head for this row; a cursor that took that answer would
    // name `OpId{0, 0}` and resolve to nothing at all, because no row
    // carries that id. The two are different values and the cursor is the one
    // that resolves.
    try testing.expect(!c.eql(.{ .op = .init(ElemId.head(), 0, .after, solo_actor[0]) }));
    try testing.expectError(
        error.InvalidCursor,
        getCursorPosition(&doc.set, l_obj, .{ .op = .init(ElemId.head(), 0, .after, solo_actor[0]) }, null),
    );
}

// A register of one insert and one `set` **over** it is the one shape where
// "the element the register addresses" and "the group's last operation" are
// two different ids. Pinned here because the module doc's argument used to be
// the other way round, and a fixture that cannot exist will happily pin
// anything: see "A cursor names the row the query answered".
//
// The assertions are in this order because they are a chain: the fixture is a
// document the reference can hold, the group is one row, the cursor is that
// row's id, and **both** ids come back to the index. The last of those is the
// one that used to fail, and it used to fail because the fixture was broken.
test "on an overwritten element the cursor names the `set`, and both ids come back to the same index" {
    const gpa = testing.allocator;

    {
        const doc = try Doc.build(gpa, &solo_actor, &set_over_insert);
        defer doc.destroy();

        // **The fixture is a document the reference can hold.** One winner per
        // register is what `validate_top_index` asserts
        // ([op_set.rs:196-212](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs));
        // this fixture without the successor edge on op 2 has two winners in
        // one register and is reported as
        // `final_group_mismatch { at = 3, first_top = 1, last_vis = 2 }`, which
        // is what the fixture's own doc comment says. So this line is the
        // assertion that the fixture is real, and it is the one that goes
        // first if anyone edits the row again.
        try testing.expectEqual(@as(?opset.TopIndexFault, null), try doc.set.validateTopIndex());

        // **And the overwrite did not add an element**: the list is one long,
        // which is the second half of "the `set` shares the register".
        try testing.expectEqual(@as(usize, 1), try doc.set.seqLength(l_obj, .unicode_code_point, null));

        // The group `seekOpsByIndex` answers for index `0` is **one** row, op 3
        // — op 2 is not visible, because op 3 shadows it — so
        // `found.ops.last()` is op 3 and the cursor is op 3's id
        // ([`automerge.rs:1751-1752`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        var found = try doc.set.seekOpsByIndex(gpa, l_obj, 0, .list, null);
        defer found.deinit(gpa);
        try testing.expectEqual(@as(usize, 1), found.ops.items.len);
        try testing.expectEqual(@as(u32, 3), found.ops.items[0].id().counter);

        const c = try getCursor(gpa, &doc.set, l_obj, .fromIndex(0), null, .after);
        try testing.expectEqual(@as(u64, 3), c.op.ctr);
        try testing.expectEqual(@as(u32, 0), c.op.offset);
        try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, l_obj, c, null));

        // **The element is a different id and answers the same index.** This
        // is the assertion the invalid fixture got wrong in the other
        // direction: `seek_list_opid` locates a row's register by containment
        // ([`op_set.rs:878-896`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
        // and `index.top`'s prefix counts winners, of which the register has
        // exactly one — so op 2 and op 3 both land on index `0`, and the
        // `debug_assert_eq!` upstream cross-checks with ([`op_set.rs:846`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
        // does not fire.
        const by_element: Cursor = .{ .op = .init(
            ElemId.fromOpId(OpId.init(2, 0)),
            0,
            .after,
            solo_actor[0],
        ) };
        try testing.expect(!c.eql(by_element));
        try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, l_obj, by_element, null));

        // **And both biases agree for both ids**, because the element is still
        // there — the bias only decides once it is gone
        // ([`automerge.rs:1783-1846`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
        // Without this, the answer above could be the `before` arm's and the
        // test would say nothing about the `after` arm at all.
        for ([_]u32{ 2, 3 }) |ctr| {
            for ([_]MoveCursor{ .before, .after }) |bias| {
                const probe: Cursor = .{ .op = .init(
                    ElemId.fromOpId(OpId.init(ctr, 0)),
                    0,
                    bias,
                    solo_actor[0],
                ) };
                try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, l_obj, probe, null));
            }
        }

        // The two encodings differ in the counter and in nothing else, so the
        // choice is a statement about the wire and the wire is the only thing
        // it is a statement about.
        const a = try toBytes(gpa, c);
        defer gpa.free(a);
        const b = try toBytes(gpa, by_element);
        defer gpa.free(b);
        try testing.expect(!std.mem.eql(u8, a, b));
        try testing.expectEqual(@as(u8, 3), a[a.len - 2]);
        try testing.expectEqual(@as(u8, 2), b[b.len - 2]);
    }

    // **There is no text arm here, and that is a fact about changes rather
    // than about cursors.** A text element is never *overwritten*: a
    // `splice_text` deletes the rows it removes and inserts new ones (`tildes`
    // and `bangs` in this file are two fixtures of exactly that), so a
    // register of one insert and one `set` over it is a shape the change
    // encoding does not produce for a text object. It is ordinary for a
    // **list** — `put` over a list element is a `set` hanging
    // by the element — which is why the fixture above is a list. A hand-built
    // text fixture of the same shape has no upstream to be compared against:
    // `OpsFound::width` is the *last* op's width
    // ([op_set.rs:1464-1469](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
    // and the port's own width for such a register is not the same number, so
    // asserting either one would be asserting a fixture.
}

test "a map has no cursor position, and `Op.cursor` has no answer for a map key" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &a_map);
    defer doc.destroy();

    // Making one is `error.InvalidOp`, upstream's `InvalidOp(obj.typ)`
    // (`automerge.rs:1740-1742`) — for the map the caller named and for the
    // root, which is a map too ([index.zig](opset/index.zig)'s `objectType`).
    try testing.expectError(
        error.InvalidOp,
        getCursor(gpa, &doc.set, m_obj, .fromIndex(0), null, .after),
    );
    try testing.expectError(
        error.InvalidOp,
        getCursor(gpa, &doc.set, .root, .fromIndex(0), null, .after),
    );
    try testing.expectError(
        error.InvalidOp,
        getCursor(gpa, &doc.set, m_obj, .start, null, .after),
    );

    // Resolving one is `error.InvalidCursor` (`automerge.rs:1772-1774`).
    const some = Cursor{ .op = .init(ElemId.fromOpId(OpId.init(2, 0)), 0, .after, solo_actor[0]) };
    try testing.expectError(
        error.InvalidCursor,
        getCursorPosition(&doc.set, m_obj, some, null),
    );

    // `start` and `end` are **not** type-checked, which is upstream's shape:
    // `Cursor::Start` and `Cursor::End` return before the object's type is
    // read (`automerge.rs:1767-1768`), so a map answers 0 for the start and
    // its key count for the end. Pinned because a reader would reasonably
    // expect a refusal here and the answer is "no".
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, m_obj, .start, null));
    try testing.expectEqual(@as(usize, 1), try getCursorPosition(&doc.set, m_obj, .end, null));

    // And the row-level half of the same rule: `Op.cursor` refuses a map key
    // with `error.InvalidCursorOp` ([op.zig:1926-1932](opset/op.zig)), and
    // that is the error upstream's `InvalidCursorOp` is for
    // ([error.rs:49](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/error.rs#L49)).
    const map_row = (try doc.set.get(1)).?;
    try testing.expectError(error.InvalidCursorOp, map_row.cursor());
    // The root's own key row is a map key too.
    const root_row = (try doc.set.get(0)).?;
    try testing.expectError(error.InvalidCursorOp, root_row.cursor());

    // **A list's key row is a map key as well**, which is the case that is
    // easy to get wrong: the object is a sequence and the row is not. The
    // list itself passes the object-type check — it *is* a sequence.
    //
    // **The port mints the cursor here, as upstream does.** `seekOpsByIndex`
    // hands the map-key row back, because a list element is one unit wide
    // whatever the row is ([op.zig:1844-1845](opset/op.zig) over upstream's
    // `OpBuilder::width`, `op.rs:204-210`, whose `SequenceType::List` arm is a
    // constant `1`), and upstream then mints a cursor from it with no
    // question asked ([`automerge.rs:1751-1752`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)).
    //
    // **What a caller can do with the answer decides it, and the answer is
    // the same either way.** A refusal would be upstream's own
    // `InvalidCursorOp`
    // ([`error.rs:49`](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/error.rs#L49)),
    // "op has no valid cursor" — but **a cursor on that row is a perfectly
    // good cursor**: `seek_list_opid` finds the row's register by containment
    // ([`op_set.rs:878-896`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs))
    // and answers index `0`, the one unit the row occupies. So the refusal
    // would take away a cursor that resolves, on a document the reference
    // writes without complaint — and a cursor minted by a peer has to
    // resolve here whatever we would have minted ourselves. Nothing is
    // bought by refusing, so: match upstream.
    //
    // [`Op.cursor`] still refuses the row, because that is upstream's own
    // method ([`op.rs:1073-1082`](../../github-automerge-automerge/rust/automerge/src/op_set2/op.rs))
    // and upstream's own error — it is [`getCursor`] that does not go
    // through it. That is the whole of the difference and it is one call.
    const seq = try Doc.build(gpa, &solo_actor, &a_list);
    defer seq.destroy();
    try testing.expectEqual(types.ObjType.list, seq.set.objectType(l_obj).?);
    try testing.expectEqual(@as(usize, 1), try seq.set.seqLength(l_obj, .unicode_code_point, null));
    const key_row = (try seq.set.get(1)).?;
    try testing.expectError(error.InvalidCursorOp, key_row.cursor());

    const on_key = try getCursor(gpa, &seq.set, l_obj, .fromIndex(0), null, .after);
    try testing.expectEqual(@as(u64, 2), on_key.op.ctr);
    try testing.expectEqual(@as(u32, 0), on_key.op.offset);
    // **The round trip, on the one row where the element and the operation
    // are not the same thing at all.** There is no element here to name, and
    // the cursor still comes back to the index it was taken at.
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&seq.set, l_obj, on_key, null));
}

test "an object that is not there, an actor that is not there, and a clock that does not cover the cursor are all refused" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &aaa_at_bbb);
    defer doc.destroy();

    const c = try getCursor(gpa, &doc.set, t_obj, .fromIndex(3), null, .after);

    // An id the object index does not hold (`automerge.rs:1770`, `:766`).
    try testing.expectError(
        error.NotAnObject,
        getCursorPosition(&doc.set, .{ .id = OpId.init(99, 0) }, c, null),
    );
    try testing.expectError(
        error.NotAnObject,
        getCursor(gpa, &doc.set, .{ .id = OpId.init(99, 0) }, .fromIndex(0), null, .after),
    );

    // An actor the document does not hold (`automerge.rs:775`, `:783-785`).
    const stranger: Cursor = .{ .op = .{
        .ctr = 5,
        .actor = ActorId.init("ffffffffffffffff"),
        .move_cursor = .after,
        .offset = 0,
    } };
    try testing.expectError(
        error.InvalidCursor,
        getCursorPosition(&doc.set, t_obj, stranger, null),
    );

    // A counter no row carries (`automerge.rs:1778-1781`).
    const unborn: Cursor = .{ .op = .{
        .ctr = 500,
        .actor = solo_actor[0],
        .move_cursor = .after,
        .offset = 0,
    } };
    try testing.expectError(
        error.InvalidCursor,
        getCursorPosition(&doc.set, t_obj, unborn, null),
    );

    // A clock that does not cover the cursor (`automerge.rs:777-780`). This
    // is upstream's "cursors created after heads are invalid"
    // ([automerge/tests.rs:233-240](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/automerge/tests.rs#L233-L240)):
    // the cursor resolves in the present and not in a past state that predates
    // it. A clock over ops 1 to 3 is `aaa@bbb` truncated to `aaa`, and the
    // cursor made at index 3 is on op 5 — which the clock does not cover.
    var past = try Clock.init(gpa, 1);
    defer past.deinit();
    try testing.expect(past.include(0, 3));
    try testing.expectEqual(@as(usize, 3), try at(gpa, doc, c));
    try testing.expectError(
        error.InvalidCursor,
        getCursorPosition(&doc.set, t_obj, c, past),
    );

    // **And a cursor the clock *does* cover resolves in it**, which is the
    // other half: op 2 is the `a` at index 0, and the clock holds it.
    const covered = try getCursor(gpa, &doc.set, t_obj, .fromIndex(0), null, .after);
    try testing.expectEqual(@as(u64, 2), covered.op.ctr);
    try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, t_obj, covered, past));

    // The same cursor resolves in the present too, so the clock is the only
    // difference between the two answers above.
    try testing.expectEqual(@as(usize, 0), try at(gpa, doc, covered));
}

// ── The two failures a caller has to tell apart ───────────────────────────

/// Whether `name` is one of the errors in the set `set`.
///
/// **This is asked about two names and the answers are both no**, and that is
/// the whole of the distinction as a caller meets it: `InvalidCursor` is not
/// a [`ParseError`] and `InvalidValue` is not an [`Error`], so a function that
/// reads a token cannot report "this document has never seen that actor" and
/// a function that resolves a cursor cannot report "that is not a token". A
/// caller retrying on one and discarding on the other is reading two
/// vocabularies, not one name twice.
///
/// `set` is the error set **value** and not its type, and that is not a style
/// choice: Zig 0.16's `@typeInfo` answers `.type` for a type, which is the
/// union's first variant and carries no payload, so a `comptime set: type`
/// parameter cannot be asked this question at all. The parameter is a
/// `comptime anytype` and every call site passes the set.
fn errorSetHas(comptime set: anytype, comptime name: []const u8) bool {
    // `null` is the *global* error set, which carries no name list; neither
    // of the two sets asked about here is global.
    const names = @typeInfo(set).error_set orelse return false;
    for (names) |n| {
        if (std.mem.eql(u8, n.name, name)) return true;
    }
    return false;
}

const invalid_cursor_is_a_parse_error = errorSetHas(ParseError, "InvalidCursor");
const invalid_value_is_a_doc_error = errorSetHas(Error, "InvalidValue");

// Upstream has **three** names on this path and they mean three different
// things ([error.rs:27,47,49,51,115](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/error.rs)),
// and one of them is not the one the name suggests.
//
// **`InvalidCursorFormat`** (`error.rs:51`) is "this is not a cursor": every
// refusal in `TryFrom<&[u8]>` — `cursor.rs:226`, `:231`, `:243-244`, `:246`,
// `:248`, `:256`, `:260` — and in `parse_0` (`:275`, `:277`, `:279`) and in
// `TryFrom<&str>` (`:204-210`). **No document is consulted for any of them.**
//
// **`InvalidCursor(Cursor)`** (`error.rs:47`) is "this is a cursor and it
// names nothing here": the actor is not in the document's table
// ([`automerge.rs:775`, `:783-784`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
// the clock does not cover it (`:778-779`), `seek_list_opid` found nothing
// (`:1778-1781`), or the object is a map (`:1772-1774`).
//
// **`InvalidActorId`** (`error.rs:27`, and the struct of the same name at
// `:115`) is **neither**: it is only ever the error of `ActorId::try_from(&str)`
// and `FromStr` ([`types.rs:88-96`, `:154-159`](../../github-automerge-automerge/rust/automerge/src/types.rs)),
// a string that is not hex. `Cursor::try_from(&str)` funnels that `None` into
// `InvalidCursorFormat` ([`cursor.rs:109`, `:208`](../../github-automerge-automerge/rust/automerge/src/cursor.rs))
// like every other malformed string, so **an actor id this port calls
// `error.InvalidActorId` never reaches a cursor path at all**.
//
// **So "the token is not a cursor" and "the token names an actor this
// document has never seen" are `InvalidCursorFormat` and `InvalidCursor`
// upstream, and never `InvalidActorId`** — which is the name that *would* have
// said the second, and the name a reader is likelier to guess.
test "a token that is not a cursor and a cursor this document has never seen are two different failures" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &aaa_at_bbb);
    defer doc.destroy();

    // **The vocabularies are disjoint where it matters.** A parse arm cannot
    // report an unknown actor and a resolve arm cannot report a malformed
    // token, so a caller can branch on the error alone.
    try testing.expect(!invalid_cursor_is_a_parse_error);
    try testing.expect(!invalid_value_is_a_doc_error);

    // ── Arm one: the token is not a cursor ──
    //
    // Upstream's own two cases: a truncated version-0 cursor
    // (`automerge/tests.rs:217-220`) and the string `notacursor`
    // (`:221-224`). Both are `InvalidCursorFormat`; here they are refusals out
    // of the untrusted-input set ([error.zig](error.zig)), which is the layer a
    // stored token belongs to.
    try testing.expectError(error.Truncated, fromBytes(&.{ 0, 3, 10 }));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "notacursor"));
    try testing.expectError(error.InvalidValue, fromBytes(&.{ 0x02, 0x01 }));
    // **The actor's hex is the interesting one**, because it is the refusal a
    // reader is most likely to expect to be `InvalidActorId`. Upstream makes
    // it `InvalidCursorFormat` — `from_str` drops it with `.ok()?`
    // (`cursor.rs:109`) and `TryFrom<&str>` turns every `None` into
    // `InvalidCursorFormat` (`:208`) — and so does this.
    try testing.expectError(error.InvalidValue, fromStr(gpa, "10@nothex"));
    try testing.expectError(error.InvalidValue, fromStr(gpa, "10@abc"));

    // ── Arm two: the token is a cursor, and this document has never seen it ──
    //
    // **Upstream has two separate arms here and the same error for both**, so
    // a test that only pins one of them cannot tell the two apart. These four
    // tokens differ in exactly one field at a time.
    //
    // The control: the document's own actor and a counter it holds — op 5 is
    // the `@` at index 3 of `aaa@bbb`. **This resolves**, so every refusal
    // below is about the token and not about the object.
    const ours = try fromStr(gpa, "5@0123456789abcdef");
    defer gpa.free(ours.op.actor.bytes);
    try testing.expectEqual(@as(usize, 3), try getCursorPosition(&doc.set, t_obj, ours, null));

    // **The actor arm** ([`automerge.rs:775`, `:783-784`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
    // same counter, same object, an actor the table has never held.
    const theirs = try fromStr(gpa, "5@ffffffffffffffff");
    defer gpa.free(theirs.op.actor.bytes);
    try testing.expectError(error.InvalidCursor, getCursorPosition(&doc.set, t_obj, theirs, null));

    // **The counter arm** (`:1778-1781`): the document's own actor, a counter
    // no row carries. Same error, different reason — which is why pinning the
    // actor arm alone would leave the pair looking like one path.
    const unborn = try fromStr(gpa, "10@0123456789abcdef");
    defer gpa.free(unborn.op.actor.bytes);
    try testing.expectError(error.InvalidCursor, getCursorPosition(&doc.set, t_obj, unborn, null));

    // **And upstream's own case, verbatim**: `Cursor::try_from("10@aabbcc00")`
    // **succeeds** ([`automerge/tests.rs:227`](../../github-automerge-automerge/rust/automerge/src/automerge/tests.rs))
    // and it is `get_cursor_position` that refuses (`:228-231`), with
    // `InvalidCursor`. That token misses on *both* counts, and the parse is
    // not the refusal and the actor is not the parse's business — which is the
    // whole difference between the two arms, and the reason a caller may keep
    // the token and try it against another document.
    const bad = try fromStr(gpa, "10@aabbcc00");
    defer gpa.free(bad.op.actor.bytes);
    try testing.expectEqual(@as(u64, 10), bad.op.ctr);
    try testing.expectEqual(MoveCursor.after, bad.op.move_cursor);
    try testing.expectError(error.InvalidCursor, getCursorPosition(&doc.set, t_obj, bad, null));
}

// ── The bias rules ─────────────────────────────────────────────────────────

test "the bias table: one case per rule, and every case where the biases differ" {
    const gpa = testing.allocator;

    // **One cursor, six documents.** The cursor is made once, in the first
    // document, and the five edits below are applied to it. A cursor is a
    // value — an element, an offset and a bias — so reading it against a
    // later state *is* what a cursor is for; the documents are the states,
    // not five different cursor tests.
    const first = try Doc.build(gpa, &solo_actor, &aaa_at_bbb);
    defer first.destroy();
    const pair = try bias_pair(gpa, first);
    // The pair really is two cursors on one element with two biases, so every
    // difference below is the bias and nothing else.
    try testing.expectEqual(pair[0].op.ctr, pair[1].op.ctr);
    try testing.expectEqual(MoveCursor.before, pair[0].op.move_cursor);
    try testing.expectEqual(MoveCursor.after, pair[1].op.move_cursor);
    try testing.expect(!pair[0].eql(pair[1]));

    // Stage 1, `aaa@bbb`, nothing changed: the two biases agree, because
    // they only disagree once the element is gone (`automerge.rs:1783`).
    // `aaa@bbb`
    // ^  ^   ^
    // s  ba  e
    try testing.expectEqual(@as(usize, 3), try at(gpa, first, pair[0]));
    try testing.expectEqual(@as(usize, 3), try at(gpa, first, pair[1]));
    try testing.expectEqual(@as(usize, 0), try at(gpa, first, .start));
    try testing.expectEqual(@as(usize, 7), try at(gpa, first, .end));

    // Stage 2, `splice_text(3, 1, "~~~")`: **the element is replaced by three
    // others.** `before` answers the index the previous visible element has
    // and `after` answers the index the next visible element has, and the two
    // are four apart.
    // aaa~~~bbb
    // ^ ^   ^  ^
    // s b   a  e
    {
        const doc = try Doc.build(gpa, &solo_actor, &tildes);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 2), try at(gpa, doc, pair[0]));
        try testing.expectEqual(@as(usize, 6), try at(gpa, doc, pair[1]));
        try testing.expectEqual(@as(usize, 9), try at(gpa, doc, .end));
    }

    // Stage 3, `splice_text(0, 6, "")`: the element was at index 0 once
    // everything before it is gone, and `automerge.rs:1801-1804` answers 0
    // for `before` without walking. `after` reaches the same 0 by the other
    // route, which is what makes this the head case and not a bias case.
    // bbb
    // ^  ^
    // sba e
    {
        const doc = try Doc.build(gpa, &solo_actor, &bbb);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 0), try at(gpa, doc, pair[0]));
        try testing.expectEqual(@as(usize, 0), try at(gpa, doc, pair[1]));
        try testing.expectEqual(@as(usize, 3), try at(gpa, doc, .end));
    }

    // Stage 4, `splice_text(0, 0, "hello")`: **the backward walk runs off the
    // front of the sequence.** Four elements between the cursor's element and
    // the head are all deleted, so `before` walks past all of them and the
    // query for the head finds no row and answers 0
    // (`automerge.rs:1840-1841`). `after` answers 5, the five new elements.
    // hellobbb
    // ^    ^  ^
    // sb   a  e
    {
        const doc = try Doc.build(gpa, &solo_actor, &hellobbb);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 0), try at(gpa, doc, pair[0]));
        try testing.expectEqual(@as(usize, 5), try at(gpa, doc, pair[1]));
        try testing.expectEqual(@as(usize, 8), try at(gpa, doc, .end));
    }

    // Stage 5, `splice_text(5, 8, "")`: **nothing survives past the cursor**,
    // so `after` answers the sequence's length — the third bullet of
    // `automerge.rs:1789-1793` — and the answer is not 0, so this is not the
    // head case again.
    // hello
    // ^    ^
    // sb   ae
    {
        const doc = try Doc.build(gpa, &solo_actor, &hello);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 0), try at(gpa, doc, pair[0]));
        const landed = try at(gpa, doc, pair[1]);
        try testing.expectEqual(@as(usize, 5), landed);
        try testing.expectEqual(landed, try at(gpa, doc, .end));
        try testing.expectEqual(@as(usize, 5), try doc.set.seqLength(t_obj, .unicode_code_point, null));
    }

    // Stage 6, `splice_text(3, 3, "!!!")` on the *unmodified* document: the
    // same before/after pair as stage 2 and a different length, so the two
    // stages cannot be one fixture written twice.
    // aaa!!!b
    // ^ ^   ^ ^
    // s b   a e
    {
        const doc = try Doc.build(gpa, &solo_actor, &bangs);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 2), try at(gpa, doc, pair[0]));
        try testing.expectEqual(@as(usize, 6), try at(gpa, doc, pair[1]));
        try testing.expectEqual(@as(usize, 7), try at(gpa, doc, .end));
    }
}

test "a cursor made before an edit keeps its position when the edit is elsewhere, and moves when the edit is before it" {
    const gpa = testing.allocator;

    const first = try Doc.build(gpa, &solo_actor, &hello_world);
    defer first.destroy();
    try testing.expectEqual(@as(usize, 11), try first.set.seqLength(t_obj, .unicode_code_point, null));

    // The `w` at index 6, which is op 8. This is the headline property of the
    // type: a cursor is taken once and then names the same *character* however
    // far the document moves around it.
    const on_w = try getCursor(gpa, &first.set, t_obj, .fromIndex(6), null, .after);
    try testing.expectEqual(@as(u64, 8), on_w.op.ctr);
    try testing.expectEqual(@as(u64, 6), try at(gpa, first, on_w));

    // **An edit elsewhere.** One `!` after the end. The cursor does not move,
    // and the end cursor does.
    // hello world!
    //       ^
    //       c
    {
        const doc = try Doc.build(gpa, &solo_actor, &world_bang);
        defer doc.destroy();
        try testing.expectEqual(@as(u64, 6), try at(gpa, doc, on_w));
        try testing.expectEqual(@as(usize, 12), try at(gpa, doc, .end));
    }

    // **An edit before it.** Two characters at the front, and the cursor moves
    // by exactly two.
    // XYhello world
    //         ^
    //         c
    {
        const doc = try Doc.build(gpa, &solo_actor, &xy_world);
        defer doc.destroy();
        try testing.expectEqual(@as(u64, 8), try at(gpa, doc, on_w));
        try testing.expectEqual(@as(usize, 13), try at(gpa, doc, .end));
    }

    // **The element itself is deleted**, along with five others, and ten
    // take their place: `after` skips the six and lands on the ten, `before`
    // walks back to the last element that is still there.
    // hel new text ld
    //           ^  ^
    //           a  b
    {
        const doc = try Doc.build(gpa, &solo_actor, &spliced_world);
        defer doc.destroy();
        const before = try getCursor(gpa, &first.set, t_obj, .fromIndex(6), null, .before);
        try testing.expectEqual(@as(u64, 13), try at(gpa, doc, on_w));
        try testing.expectEqual(@as(u64, 2), try at(gpa, doc, before));
        try testing.expectEqual(@as(usize, 15), try at(gpa, doc, .end));
    }
}

test "a cursor inside a multi-unit text element keeps the offset, which is this port's addition" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &wide);
    defer doc.destroy();

    // The object reads `abc`, and element 0 spans units 0 and 1 because its
    // value is the string `"ab"` and a row's width is the width of its whole
    // value ([op.zig:1844-1849](opset/op.zig)).
    try testing.expectEqual(@as(usize, 3), try doc.set.seqLength(t_obj, .unicode_code_point, null));

    const edge = try getCursor(gpa, &doc.set, t_obj, .fromIndex(0), null, .after);
    const inside = try getCursor(gpa, &doc.set, t_obj, .fromIndex(1), null, .after);
    const last = try getCursor(gpa, &doc.set, t_obj, .fromIndex(2), null, .after);

    // The two cursors on the wide element differ **only** in the offset, and
    // both resolve to the position they were taken at. Upstream answers the
    // element's first index for both (`automerge.rs:1794`), which is the whole
    // reason the offset is here.
    try testing.expectEqual(@as(u64, 2), edge.op.ctr);
    try testing.expectEqual(@as(u64, 2), inside.op.ctr);
    try testing.expectEqual(@as(u32, 0), edge.op.offset);
    try testing.expectEqual(@as(u32, 1), inside.op.offset);
    try testing.expect(!edge.eql(inside));
    try testing.expectEqual(@as(u64, 0), try at(gpa, doc, edge));
    try testing.expectEqual(@as(u64, 1), try at(gpa, doc, inside));
    try testing.expectEqual(@as(u64, 3), last.op.ctr);
    try testing.expectEqual(@as(u32, 0), last.op.offset);
    try testing.expectEqual(@as(u64, 2), try at(gpa, doc, last));

    // **The offset is what travels with the element.** Two characters at the
    // front move the element by two and the cursor with it, so the cursor
    // still names the unit it named rather than the element's edge.
    {
        const moved = try Doc.build(gpa, &solo_actor, &wide_xy);
        defer moved.destroy();
        try testing.expectEqual(@as(u64, 2), try at(gpa, moved, edge));
        try testing.expectEqual(@as(u64, 3), try at(gpa, moved, inside));
        try testing.expectEqual(@as(u64, 4), try at(gpa, moved, last));
    }

    // **The offset is not on the wire**, which the codec test pins with
    // literal bytes, and this is the same fact from the string side: the two
    // cursors above write the same text, because there is no field for the
    // difference between them. A cursor that never went through a codec keeps
    // its offset, which is the four assertions above.
    const edge_str = try toStr(gpa, edge);
    defer gpa.free(edge_str);
    const inside_str = try toStr(gpa, inside);
    defer gpa.free(inside_str);
    try testing.expectEqualSlices(u8, "2@0123456789abcdef", inside_str);
    try testing.expectEqualSlices(u8, inside_str, edge_str);
}

test "the offset is the register's own start, which the first descent already answers" {
    const gpa = testing.allocator;

    // **The claim is an equality between two numbers this file used to fetch
    // from two places.** [`getCursor`] reads the register's start off
    // `seekOpsByIndex`'s `found.index`; it used to read it off a second
    // `seekListOpid` call, whose cost was an O(rows in the object) walk. This
    // test is the witness that the two are the same number, computed the old
    // way beside the new one on **every position of every fixture** — so the
    // cheap answer is checked against the expensive one rather than assumed
    // equal to it.
    //
    // The four fixtures are the four shapes that separate them if anything
    // can: a plain text ([`hello_world`], one register per character), a
    // **multi-unit** element ([`wide`], where the requested index is inside
    // the element and the start is not the index), a register of **one
    // insert and one `set` over it** ([`set_over_insert`], where the cursor
    // names the `set` and the insert it shadows is in the same register), and
    // a row hanging by the **head** ([`head_set_list`], the one row whose id
    // is not the element).
    const cases = [_]struct { name: []const u8, rows: []const Rec, obj: ExId, seq: SequenceType }{
        .{ .name = "hello_world", .rows = &hello_world, .obj = t_obj, .seq = .text },
        .{ .name = "wide", .rows = &wide, .obj = t_obj, .seq = .text },
        .{ .name = "set_over_insert", .rows = &set_over_insert, .obj = l_obj, .seq = .list },
        .{ .name = "head_set_list", .rows = &head_set_list, .obj = l_obj, .seq = .list },
    };
    for (cases) |c| {
        const doc = try Doc.build(gpa, &solo_actor, c.rows);
        defer doc.destroy();
        const len = try doc.set.seqLength(c.obj, .unicode_code_point, null);

        var i: usize = 0;
        while (i < len) : (i += 1) {
            // The expensive answer, taken the way `getCursor` used to take
            // it: the row the query named, resolved back to its register.
            var found = try doc.set.seekOpsByIndex(gpa, c.obj, i, c.seq, null);
            defer found.deinit(gpa);
            if (found.ops.items.len == 0) continue;
            const row = found.ops.items[found.ops.items.len - 1];
            const named = ElemId.fromOpId(row.id());
            const walked = (try doc.set.seekListOpid(c.obj, named.id, c.seq, null)).?;

            // **The cheap answer is the same number.** This is the assertion
            // the removal rests on.
            if (found.index != walked.index) {
                std.debug.print(
                    "{s}[{d}]: seek index {d}, register start {d}\n",
                    .{ c.name, i, found.index, walked.index },
                );
                return error.TestExpectedEqual;
            }

            // **And the cursor carries exactly that offset**, so the cheap
            // answer is not merely equal to the expensive one, it is the one
            // the cursor is built from.
            const cursor = try getCursor(gpa, &doc.set, c.obj, .fromIndex(i), null, .after);
            try testing.expectEqual(
                @as(u32, @intCast(i - found.index)),
                cursor.op.offset,
            );
            // **And the round trip closes**: the cursor comes back to the
            // position it was taken at.
            try testing.expectEqual(
                i,
                try getCursorPosition(&doc.set, c.obj, cursor, null),
            );
        }
    }

    // **A register of one insert and one `set` over it is the case the
    // argument is about, pinned as literals rather than as an equality with
    // another function's output.** Both ids answer index 0 on
    // [`set_over_insert`], so whichever row the descent names, the start is
    // 0 and the offset is 0.
    {
        const doc = try Doc.build(gpa, &solo_actor, &set_over_insert);
        defer doc.destroy();
        try testing.expectEqual(@as(usize, 1), try doc.set.seqLength(l_obj, .unicode_code_point, null));
        for ([_]OpId{ OpId.init(2, 0), OpId.init(3, 0) }) |id| {
            const here = (try doc.set.seekListOpid(l_obj, id, .list, null)).?;
            try testing.expectEqual(@as(usize, 0), here.index);
        }
        const c = try getCursor(gpa, &doc.set, l_obj, .fromIndex(0), null, .after);
        try testing.expectEqual(@as(u32, 0), c.op.offset);
        try testing.expectEqual(@as(usize, 0), try getCursorPosition(&doc.set, l_obj, c, null));
    }
}

// ── Across a save and a load ───────────────────────────────────────────────

test "a cursor survives a save and a reload" {
    const gpa = testing.allocator;
    const doc = try Doc.build(gpa, &solo_actor, &hello_world);
    defer doc.destroy();

    const made = try getCursor(gpa, &doc.set, t_obj, .fromIndex(6), null, .after);
    const before = try getCursor(gpa, &doc.set, t_obj, .fromIndex(6), null, .before);
    const end = try getCursor(gpa, &doc.set, t_obj, .end, null, .after);
    const start = try getCursor(gpa, &doc.set, t_obj, .start, null, .after);

    // A cursor is an element plus a bias, so persisting it is the grammar and
    // nothing else. The bytes are read back and compared as values.
    const bytes = try toBytes(gpa, made);
    defer gpa.free(bytes);
    const decoded = try fromBytes(bytes);
    try testing.expect(decoded.eql(made));

    const reloaded = try doc.reload(&solo_actor);
    defer reloaded.destroy();
    try reloaded.set.debugCmp(&doc.set);

    // Every one of the four shapes, decoded, resolves in the reloaded
    // document.
    try testing.expectEqual(@as(u64, 6), try getCursorPosition(&reloaded.set, t_obj, decoded, null));
    const before_bytes = try toBytes(gpa, before);
    defer gpa.free(before_bytes);
    try testing.expect((try fromBytes(before_bytes)).eql(before));
    try testing.expectEqual(@as(u64, 6), try getCursorPosition(&reloaded.set, t_obj, try fromBytes(before_bytes), null));
    try testing.expectEqual(@as(u64, 0), try getCursorPosition(&reloaded.set, t_obj, start, null));
    try testing.expectEqual(@as(u64, 11), try getCursorPosition(&reloaded.set, t_obj, end, null));

    // And the offset travels with the document, because the element it is
    // measured from does: the reloaded index is rebuilt from the sixteen data
    // columns and the wide element is still two units wide.
    {
        const wide_doc = try Doc.build(gpa, &solo_actor, &wide);
        defer wide_doc.destroy();
        const inside = try getCursor(gpa, &wide_doc.set, t_obj, .fromIndex(1), null, .after);
        try testing.expectEqual(@as(u32, 1), inside.op.offset);
        const back = try wide_doc.reload(&solo_actor);
        defer back.destroy();
        try back.set.debugCmp(&wide_doc.set);
        try testing.expectEqual(@as(u64, 1), try getCursorPosition(&back.set, t_obj, inside, null));
        try testing.expectEqual(
            @as(u64, 3),
            try back.set.seqLength(t_obj, .unicode_code_point, null),
        );
    }
}

// ── Allocation ─────────────────────────────────────────────────────────────

test "constructing a cursor allocates nothing, and the cursor it hands back owns nothing" {
    const gpa = testing.allocator;

    // The instrument is the document's own allocator, so the count can only
    // move because of the call under test.
    var counting: Counting = .{ .inner = gpa };
    const doc = try Doc.build(counting.allocator(), &solo_actor, &hello_world);
    defer doc.destroy();

    const actor = doc.set.getActor(0).?;
    const base = counting.count;

    // A cursor is a union of two tags and a struct of a number, a slice and
    // two small ones. None of its constructors take an allocator and none of
    // them can.
    const elem = ElemId.fromOpId(OpId.init(8, 0));
    const edge: Cursor = .{ .op = OpCursor.init(elem, 0, .after, actor) };
    const inside: Cursor = .{ .op = OpCursor.init(elem, 3, .before, actor) };
    const s: Cursor = .start;
    const e: Cursor = .end;
    try testing.expectEqual(base, counting.count);

    // Nor do its accessors.
    _ = try edge.op.elemId(0);
    _ = edge.eql(inside);
    _ = s.eql(e);
    _ = CursorPosition.fromIndex(3);
    _ = MoveCursor.fromTag(2);
    try testing.expectEqual(base, counting.count);

    // **The reader allocates nothing either**, and it takes no allocator, so
    // this is not a count that happens to be zero.
    const bytes = try toBytes(gpa, edge);
    defer gpa.free(bytes);
    try testing.expect((try fromBytes(bytes)).eql(edge));
    try testing.expectEqual(base, counting.count);

    // `getCursor` *does* allocate, because the op set's answer is an
    // `OpsFound` that owns the rows it collected
    // ([found_op.zig](opset/found_op.zig)). What it hands back owns nothing:
    // the actor is the document's own bytes and there is no `deinit` to call.
    const made = try getCursor(counting.allocator(), &doc.set, t_obj, .fromIndex(6), null, .after);
    try testing.expect(counting.count > base);
    try testing.expectEqual(@intFromPtr(actor.bytes.ptr), @intFromPtr(made.op.actor.bytes.ptr));
    try testing.expect(made.eql(edge));
    try testing.expectEqual(@as(u64, 6), try getCursorPosition(&doc.set, t_obj, made, null));
}

// ── Positions, over marked text ───────────────────────────────────────────────
//
// Neither `tests/diff_marks.rs` nor `tests/test_mark_patches.rs` names a
// cursor, so nothing below is a port of an upstream test. It is here because
// these are the file's own subject — **a position in a sequence** — applied to
// the case where a position carries something other than a character, and
// because the hydrate round trip (`hydrate.zig`) cannot check the *span* of a
// text mark against the mirror: upstream's `hydrate::Text` holds one value per
// mark name (`hydrate/text.rs`:10) and nothing about where.
//
// **Two readers, every position.** The mark at position `i` is read twice: once
// from the span walk ([`iter::Spans`](iter/spans.zig), which coalesces runs as
// it goes) and once from [`OpSet::calculate_marks`](opset/op_set.zig) through
// [`getMarks`](read.zig), which folds the mark operations. They share no code
// on the way to the answer, so agreement at every position is a statement
// about the document and not about one function.

const cdoc = @import("doc.zig");
const cread = @import("read.zig");
const ctrans = @import("transact.zig");
const marksmod = @import("marks.zig");

/// The marks over one position. The **names and any byte a value carries are
/// the document's**, which is why the document must not be mutated while a
/// table of these is live — it is not, and the rule is [`src/marks.zig`](marks.zig)'s.
const AtPosition = ?marksmod.MarkSet.Entry;

test "a cursor comes back to the position it was taken at, and the mark there is the one the span walk read" {
    const gpa = testing.allocator;
    var d = try cdoc.Document.init(gpa, std.testing.io, .auto);
    defer d.deinit();
    d.setActorId(.{ .bytes = "0123456789abcdef" });

    const text = try ctrans.putObject(&d, .root, .{ .key = "text" }, .text);
    try ctrans.spliceText(&d, text, 0, 0, "hello world");
    // **Two marks over disjoint spans with a gap between them**, so a reader
    // that answered "the mark" without saying which one has to fail at
    // position 5.
    try ctrans.mark(&d, text, 0, 5, "link", .after, .{ .str = "https://example.com" });
    try ctrans.mark(&d, text, 6, 11, "bold", .after, .{ .bool_value = true });

    const enc = d.textEncoding();
    const all = try d.text(gpa, text);
    defer gpa.free(all);
    const len = enc.width(all);
    try testing.expectEqual(@as(usize, 11), len);

    // Reader one: the span walk, turned into a per-position table.
    var mark_at: [32][2]AtPosition = .{.{ null, null }} ** 32;
    {
        var walk = try cread.spans(&d, text, gpa);
        defer walk.deinit();
        var idx: usize = 0;
        while (try walk.next()) |found| {
            var span = found;
            // The walk hands the span over (`Spans.next`, `spans.zig`:1332`).
            defer span.deinit(gpa);
            switch (span) {
                .text => |t| {
                    // **One mark covers every position of the span**, so each
                    // entry of the set is written across the span's whole
                    // width, not once. A span of width five with one mark puts
                    // that mark at positions 0 to 4.
                    const w = enc.width(t.text);
                    if (idx + w > mark_at.len) return error.TestUnexpectedResult;
                    if (t.marks) |set| {
                        var k: usize = 0;
                        var mit = set.iter();
                        while (mit.next()) |e| {
                            if (k >= 2) return error.TestUnexpectedResult;
                            var j: usize = 0;
                            while (j < w) : (j += 1) mark_at[idx + j][k] = e.*;
                            k += 1;
                        }
                    }
                    idx += w;
                },
                .block => return error.TestUnexpectedResult,
            }
        }
        try testing.expectEqual(len, idx);
    }

    var i: usize = 0;
    while (i < len) : (i += 1) {
        // **The cursor comes back to where it was taken.** A text element can be
        // several units wide and this port resolves a cursor to the position it
        // was taken at rather than to the element's edge (see the module doc's
        // "the offset"), so `i -> i` is a claim about the offset arithmetic.
        // **`heads` is `null` here**, so this reads at the present. The three
        // cursor readers carry `at` on the method itself, upstream's shape
        // (`read.rs:203`, `:228`, `:241`), not as a second name.
        const cursor = try cread.getCursor(&d, text, .{ .index = i }, null, gpa);
        const back = try cread.getCursorPosition(&d, text, cursor, null);
        if (back != i) {
            std.debug.print("cursor at {d} resolves to {d}\n", .{ i, back });
            return error.TestExpectedEqual;
        }

        // Reader two, over the same position.
        const over = try cread.getMarks(&d, text, i, i + 1, gpa);
        defer gpa.free(over);

        const want_n: usize = if (mark_at[i][0] == null) 0 else if (mark_at[i][1] == null) 1 else 2;
        if (over.len != want_n) {
            std.debug.print("position {d}: span walk has {d} marks, marks() has {d}\n", .{
                i, want_n, over.len,
            });
            return error.TestExpectedEqual;
        }
        for (over, 0..) |m, k| {
            const e = mark_at[i][k].?;
            if (!std.mem.eql(u8, e.name, m.name) or !e.value.eql(m.value)) {
                std.debug.print(
                    "position {d}: span walk has {s}={any}, marks() has {s}={any}\n",
                    .{ i, e.name, e.value, m.name, m.value },
                );
                return error.TestExpectedEqual;
            }
        }
    }

    // **And the gap is really a gap.** Positions 0-4 carry `link`, 5 carries
    // nothing and 6-10 carry `bold` — spelled out, because "the readers agree"
    // is also true when both of them are empty everywhere.
    try testing.expectEqualStrings("link", mark_at[0][0].?.name);
    try testing.expectEqualStrings("link", mark_at[4][0].?.name);
    try testing.expect(mark_at[5][0] == null);
    try testing.expect(mark_at[5][1] == null);
    try testing.expectEqualStrings("bold", mark_at[6][0].?.name);
    try testing.expectEqualStrings("bold", mark_at[10][0].?.name);
    try testing.expect(mark_at[0][0].?.value.eql(.{ .str = "https://example.com" }));
    try testing.expect(mark_at[6][0].?.value.eql(.{ .bool_value = true }));
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **This section is not a port.** Neither `tests/diff_marks.rs` nor
//   `tests/test_mark_patches.rs` mentions a cursor, and no upstream test is
//   claimed here. What it is: the port's own statement about **positions**,
//   which is the one thing the hydrate round trip cannot check against the
//   mirror, because upstream's `hydrate::Text` stores one value per mark name
//   (`hydrate/text.rs`:10) and no range at all. The span survives in the patch
//   stream and in [`OpSet::calculate_marks`](opset/op_set.zig); the test above
//   says those two agree with the span walk at every position.
//
// * **A cursor round trip at an unchanged position is not a tautology here.**
//   This port resolves a cursor to the *position* it was taken at rather than
//   to its element's edge (see the module doc's "the offset"), and a text
//   element is as wide as its value — so `get_cursor_for` at `i` and
//   `get_cursor_position_for` at `i` agreeing is a claim about the offset
//   arithmetic, and upstream's own reading returns the element's first index
//   (`automerge.rs`:1794`).
//
// * **The round trip through `seek_ops_by_index` is structural, and the one
//   fixture that looked like a counterexample was the broken one.**
//   `seek_list_opid` resolves a cursor by finding the register that
//   **contains** the row
//   ([`op_set.rs:878-896`](../../github-automerge-automerge/rust/automerge/src/op_set2/op_set.rs)),
//   and every row `seek_ops_by_index` hands back is in **one** register
//   ([found_op.rs:61-68](opset/found_op.zig)), so the row a cursor was minted
//   for is in the register the cursor resolves to — whatever that row is: an
//   insert, an overwrite, or a map key inside a list. The fast arm gets there
//   by prefix arithmetic on `index.top`, which is the same answer only while
//   the index holds one winner per register; that is what `validate_top_index`
//   asserts (`op_set.rs:196-212`) and what [`OpSet.seekListOpid`](opset/op_set.zig)'s
//   cross-check reports when it does not. Checked at every position of a
//   marked text object, over a plain list, over an overwritten element under
//   both biases, and over a map key in a list.
//
// * **[`getCursor`] names the row the query answered — upstream's rule, not a
//   divergence.** `OpCursor::new(op.id, ...)` over `found.ops.last()`
//   (`automerge.rs:1751-1752`), and `OpCursor` is upstream's "a cursor which
//   represents a specific op in a sequence" (`cursor.rs:31`). For a register
//   of one insert and one `set` **over** it the two possible readings — the
//   element, and the group's last operation — are different ids, and this
//   takes the `set`. **This file used to take the element**, on the argument
//   that a `set` over an element is a second `index.top` in a register of one
//   width, so upstream's fast descent over-counts by one and its
//   `debug_assert_eq!` (`op_set.rs:846`) panics. That argument needs a
//   register with **two** winners, and no merge and no load can produce one:
//   `Op::top` is `Op::visible` (`op.rs:1148-1156`, `:1355-1359`) and
//   `local_list_op` puts a successor on every row it overwrites
//   (`inner.rs:549-553`). Measured on [`set_over_insert`] with the successor
//   edge its own doc comment names, `2@0` and `3@0` both answer index `0`
//   through both arms of [`OpSet.seekListOpid`](opset/op_set.zig). The two
//   ids resolve alike, so the only thing left to choose between them is the
//   bytes — and a cursor is persisted and handed to other peers
//   (`cursor.rs:15`), so it matches the reference. Pinned by `test "on an
//   overwritten element the cursor names the `set`, and both ids come back to
//   the same index"`, which also pins the two encodings as the different
//   bytes they are.
//
// * **A map key inside a list is minted here, and that is the same decision.**
//   `seek_ops_by_index` hands the key row back — a list element is one unit
//   wide whatever the row is (`op.rs:204-210`) — and `get_cursor_for` names
//   it with no question asked. A refusal would be `error.InvalidCursorOp`
//   ([`error.rs:49`](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/error.rs#L49)),
//   upstream's own name for "op has no valid cursor" — but a cursor on that
//   row *resolves*: `seek_list_opid` finds the row's register by containment
//   and answers index `0`. Refusing would refuse a cursor the reference
//   writes and a peer can hand us. [`Op.cursor`] still refuses the row, which
//   is upstream's method and upstream's error (`op.rs:1073-1082`); it is
//   [`getCursor`] that does not go through it. Both halves are pinned by
//   `test "a map has no cursor position, and `Op.cursor` has no answer for a
//   map key"`.
//
// * **[`set_over_insert`] was a document nothing could build, and it was the
//   whole of a divergence's evidence.** The row carried no successor, so
//   `Op::top` was true for both rows of the register and `validate_top_index`
//   reported `final_group_mismatch { at = 3, first_top = 1, last_vis = 2 }` —
//   upstream's `assert_eq!(first_top, last_vis)` (`op_set.rs:196-212`) doing
//   exactly its job on an input no merge and no load produces
//   (`inner.rs:549-553`). The fixture carries the edge now, and the test
//   asserts `validateTopIndex` is `null`, so a third edit to that row has to
//   answer for itself. Measured, 2026-10-01: with the edge, `found.ops` for
//   index `0` is one row and both ids answer index `0`; without it, two rows,
//   and `error.Invariant` for the `set`'s id. The assertion was right and the
//   fixture was not.
//
// * **"The token is not a cursor" and "this document has never seen that
//   actor" are two failures, and upstream's names for them are
//   `InvalidCursorFormat` and `InvalidCursor` — never `InvalidActorId`.**
//   `InvalidActorId` ([`error.rs:27`](https://github.com/automerge/automerge/blob/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/error.rs#L27))
//   is only ever the error of `ActorId::try_from(&str)` — a string that is not
//   hex ([`types.rs:88-96`](../../github-automerge-automerge/rust/automerge/src/types.rs)) —
//   and `Cursor::try_from(&str)` turns that `None` into `InvalidCursorFormat`
//   ([`cursor.rs:208`](../../github-automerge-automerge/rust/automerge/src/cursor.rs))
//   like every other malformed string, so it cannot reach a cursor path. Here
//   the two are a refusal out of [`ParseError`] and `Error.InvalidCursor`, and
//   the two sets are **disjoint**, so a caller can tell them apart by the
//   error alone: `test "a token that is not a cursor and a cursor this
//   document has never seen are two different failures"` pins an arm of each,
//   and `errorSetHas` is the check that the names do not overlap.
//
// * **The v0 parser has no upstream test that parses a v0 cursor.** The one
//   upstream case that reaches `parse_0` is a *refusal*,
//   `Cursor::try_from(vec![0u8, 3u8, 10u8])`
//   ([`automerge/tests.rs:217-220`](../../github-automerge-automerge/rust/automerge/src/automerge/tests.rs));
//   nothing upstream decodes a well-formed version-0 cursor. So `test "a
//   version-0 cursor decodes to the same cursor as the version-1 one"` and
//   `test "a malformed version-0 cursor is refused, never crashed on"` are
//   the port's own, and the v0 layout they encode is upstream's own comment
//   ([`cursor.rs:266-272`](../../github-automerge-automerge/rust/automerge/src/cursor.rs)).
