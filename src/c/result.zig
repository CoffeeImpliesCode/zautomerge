//! The `AMresult` convention and the single-destructor rule: the C ABI's whole
//! ownership model, in one file, with no document in it.
//!
//! A direct translation of `rust/automerge-c/src/result.rs` (654 lines),
//! `src/items.rs` (401) and `src/byte_span.rs` (227), plus the hand-written C
//! utility layer around them (`include/automerge-c/utils/*.h` and
//! `src/utils/*.c`). It is the part of the C surface that exists before
//! `AMdoc` does.
//!
//! # The single-destructor rule
//!
//! > Every `AMresult` has exactly one destructor, and the caller calls it
//! > exactly once, on exactly the paths where the caller owns something.
//!
//! Upstream enforces this by having exactly one deallocating function in the
//! entire ABI. `AMresultFree` is it: `*Box::from_raw(result)` followed by
//! `drop` (`src/result.rs:557-562`). Every other pointer the library hands out
//! comes from `Box::into_raw` inside `to_result` (`src/result.rs:466-468`,
//! reaching `impl From<AMresult> for *mut AMresult` at `:95`) and is therefore
//! a **borrow** of something inside that box. There is no `AMdocFree`, no
//! `AMitemFree`, no `AMobjIdFree`, no `AMchangeFree`, no `AMcursorFree`, no
//! `AMmarkFree` and no `AMsync*Free`. `Box::from_raw` appears exactly once in
//! the reference's `src/`.
//!
//! Two consequences a caller must internalise, both stated in this port's
//! header:
//!
//! * Freeing the owning result invalidates every handle taken out of it and
//!   every `AMbyteSpan` view into it. A span is `{ptr, count}` and owns nothing
//!   (`src/byte_span.rs:24-35`).
//! * `AMresultItem` returns `&mut items[0]`, a pointer *into the result's own
//!   `Vec`* (`src/result.rs:575-584`). Two such pointers alias the same `Rc`,
//!   which is why `AMitemRefCount` exists and why `AMitemResult` clones the
//!   count into a fresh result so an item can outlive its collection
//!   (`src/item.rs:1691-1695`).
//!
//! # How the API shape enforces it in Zig
//!
//! The rule is a discipline in C. Zig can only approximate it, so the
//! approximation is kept small, local and honest:
//!
//! * `Result` has no public fields, so a caller cannot forge, alias or
//!   double-construct one. `toOwned` is the only route to a `*Result`.
//! * `deinit` takes the result's own allocator, so releasing a result requires
//!   naming the allocator that built it.
//! * Every Zig entry point that allocates takes a `std.mem.Allocator` first,
//!   so the tests below run on `std.testing.allocator` and a leak on any path
//!   fails the build.
//! * `AMresultFree` is the only `export` that deallocates, it returns `void`
//!   so it cannot be forgotten in an error path, and it null-checks before
//!   touching the pointer exactly as upstream does (`src/result.rs:557`).
//!
//! # The allocator, and where the C ABI gets one
//!
//! Upstream takes the allocator from Rust's global `Box` allocator; nothing in
//! the C ABI carries one. Porting the ABI verbatim would mean smuggling an
//! allocator in a global, which this project forbids (`AGENTS.md` "Invariants";
//! `docs/plan.md` §8, "a library that hides its allocator cannot be embedded").
//!
//! So the port splits at one seam:
//!
//! * Everything in this file outside `CAbi` takes an explicit
//!   `std.mem.Allocator` and is tested against `std.testing.allocator`.
//! * `CAbi(Item)` holds the C-callable wrappers, and those bind
//!   `std.heap.c_allocator` — the C runtime's `malloc`. That is the only
//!   choice that satisfies the ABI and `AMstrdup`'s documented "must be passed
//!   to `free()`" contract (`include/automerge-c/utils/string.h:24-25`) at the
//!   same time, and it is what the reference's `Box` resolves to in a release
//!   build anyway.
//!
//! `CAbi` is generic so that this file compiles and tests without a document:
//! the item layer instantiates it once with its own `Item`. Nothing here names
//! a concrete item, and nothing here is a placeholder for one.
//!
//! # What is deliberately not here
//!
//! `AMresultFrom` is variadic, and Zig cannot define a C variadic function:
//! `export fn f(x: c_int, a: ...)` is a parse error — "expected type
//! expression, found `'...'`" — and `zig translate-c` demotes a variadic
//! *definition* to an `extern` *declaration*. Both were run against Zig
//! 0.16.0, not read out of a changelog. The declaration stays in
//! `include/automerge.h` for source compatibility, and the symbol comes from
//! one translation unit that can express it: [`src/c/result_from.c`](result_from.c)
//! collects the arguments and calls [`CAbi.AMresultFromList`], which is
//! [`Result.resultFrom`] bound to `c_allocator`. **The C file decides
//! nothing**: which inputs are freed, what an error variant does and what
//! comes back are all this file's answers.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Enumerations. ABI. Pinned by the test at the bottom of this file.
// ---------------------------------------------------------------------------

/// The status of an API call. Rust: `src/result.rs:476-484`.
///
/// Upstream declares `Ok`, `Error`, `InvalidResult` with no explicit values in
/// that order, so they are `0`, `1`, `2`. The order is unalphabetized on
/// purpose so that `0` is success; upstream says so at `:478`.
pub const AMstatus = enum(c_int) {
    /// Success. Rust: `src/result.rs:479`.
    ok = 0,
    /// Failure due to an error. Rust: `src/result.rs:481`.
    error_ = 1,
    /// Failure because the result pointer was `NULL`. Rust: `src/result.rs:483`.
    invalid_result = 2,
};

/// The type of an object. Rust: `src/obj.rs:170-179`.
///
/// `Default = 0` (`:172`), `List = 1` (`:174`); `Map` (`:176`) and `Text`
/// (`:178`) carry no explicit value and continue from the previous variant, so
/// they are `2` and `3`.
pub const AMobjType = enum(c_int) {
    /// Rust: `src/obj.rs:172`.
    AM_OBJ_TYPE_DEFAULT = 0,
    /// Rust: `src/obj.rs:174`.
    AM_OBJ_TYPE_LIST = 1,
    /// Rust: `src/obj.rs:176`.
    AM_OBJ_TYPE_MAP = 2,
    /// Rust: `src/obj.rs:178`.
    AM_OBJ_TYPE_TEXT = 3,
};

/// The type of an item's index. Rust: `src/index.rs:60-67`.
///
/// `Default = 0` (`:62`), `Key` (`:64`), `Pos` (`:66`), giving `0`, `1`, `2`.
pub const AMidxType = enum(c_int) {
    /// Rust: `src/index.rs:62`.
    AM_IDX_TYPE_DEFAULT = 0,
    /// Rust: `src/index.rs:64`.
    AM_IDX_TYPE_KEY = 1,
    /// Rust: `src/index.rs:66`.
    AM_IDX_TYPE_POS = 2,
};

/// A mark's expansion mode. Rust: `src/doc/mark.rs:40-51`.
///
/// The numbering is non-sequential and the declaration order is alphabetical
/// rather than numeric. Both are upstream's and both are ABI; do not renumber
/// for tidiness. `After = 3` (`:42`), `Before = 2` (`:44`), `Both = 4` (`:46`),
/// `Default = 0` (`:48`), `None = 1` (`:50`). `AM_MARK_EXPAND_DEFAULT` is not
/// a valid argument to `AMmarkCreate` or `AMmarkClear`: the conversion
/// rejects it with an error result (`src/doc/mark.rs:59-77`).
pub const AMmarkExpand = enum(c_int) {
    /// Rust: `src/doc/mark.rs:42`.
    AM_MARK_EXPAND_AFTER = 3,
    /// Rust: `src/doc/mark.rs:44`.
    AM_MARK_EXPAND_BEFORE = 2,
    /// Rust: `src/doc/mark.rs:46`.
    AM_MARK_EXPAND_BOTH = 4,
    /// Rust: `src/doc/mark.rs:48`.
    AM_MARK_EXPAND_DEFAULT = 0,
    /// Rust: `src/doc/mark.rs:50`.
    AM_MARK_EXPAND_NONE = 1,
};

/// The type of an item's value. Rust: `src/item.rs:1296-1341`.
///
/// Every tag is a distinct bit except `Default`, so `AM_VAL_TYPE_VOID` is `1`
/// and not `0`, and `0` is reserved for `AM_VAL_TYPE_DEFAULT`. The Zig
/// declaration is in numeric order; the C header keeps cbindgen's alphabetical
/// order, which is also ABI because the enum-to-string round trip enumerates
/// it. The values are identical either way, and they are what is pinned.
pub const AMvalType = enum(c_uint) {
    /// Rust: `src/item.rs:1312`.
    AM_VAL_TYPE_DEFAULT = 0,
    /// Rust: `src/item.rs:1340`.
    AM_VAL_TYPE_VOID = 1 << 0,
    /// Rust: `src/item.rs:1298`.
    AM_VAL_TYPE_ACTOR_ID = 1 << 1,
    /// Rust: `src/item.rs:1300`.
    AM_VAL_TYPE_BOOL = 1 << 2,
    /// Rust: `src/item.rs:1302`.
    AM_VAL_TYPE_BYTES = 1 << 3,
    /// Rust: `src/item.rs:1304`.
    AM_VAL_TYPE_CHANGE = 1 << 4,
    /// Rust: `src/item.rs:1306`.
    AM_VAL_TYPE_CHANGE_HASH = 1 << 5,
    /// Rust: `src/item.rs:1308`.
    AM_VAL_TYPE_COUNTER = 1 << 6,
    /// Rust: `src/item.rs:1310`.
    AM_VAL_TYPE_CURSOR = 1 << 7,
    /// Rust: `src/item.rs:1314`.
    AM_VAL_TYPE_DOC = 1 << 8,
    /// Rust: `src/item.rs:1316`.
    AM_VAL_TYPE_F64 = 1 << 9,
    /// Rust: `src/item.rs:1318`.
    AM_VAL_TYPE_INT = 1 << 10,
    /// Rust: `src/item.rs:1320`.
    AM_VAL_TYPE_MARK = 1 << 11,
    /// Rust: `src/item.rs:1322`.
    AM_VAL_TYPE_NULL = 1 << 12,
    /// Rust: `src/item.rs:1324`.
    AM_VAL_TYPE_OBJ_TYPE = 1 << 13,
    /// Rust: `src/item.rs:1326`.
    AM_VAL_TYPE_STR = 1 << 14,
    /// Rust: `src/item.rs:1328`.
    AM_VAL_TYPE_SYNC_HAVE = 1 << 15,
    /// Rust: `src/item.rs:1330`.
    AM_VAL_TYPE_SYNC_MESSAGE = 1 << 16,
    /// Rust: `src/item.rs:1332`.
    AM_VAL_TYPE_SYNC_STATE = 1 << 17,
    /// Rust: `src/item.rs:1334`.
    AM_VAL_TYPE_TIMESTAMP = 1 << 18,
    /// Rust: `src/item.rs:1336`.
    AM_VAL_TYPE_UINT = 1 << 19,
    /// Rust: `src/item.rs:1338`.
    AM_VAL_TYPE_UNKNOWN = 1 << 20,
};

// ---------------------------------------------------------------------------
// Byte spans. A borrow, never an owner.
// ---------------------------------------------------------------------------

/// A view onto an array of bytes. Rust: `src/byte_span.rs:25-35`.
///
/// `src` is nullable and `count` is meaningless when it is null, matching the
/// reference's `Default` of `{src: null, count: 0}` (`src/byte_span.rs:43-50`).
/// A span may contain NUL bytes: the API is UTF-8, not NUL-terminated.
pub const AMbyteSpan = extern struct {
    /// A pointer to the first byte of an array of bytes. Rust: `:32`.
    src: ?[*]const u8,
    /// The count of bytes in the array. Rust: `:34`.
    count: usize,

    /// The zero span. Rust: `src/byte_span.rs:43-50`.
    pub const empty: AMbyteSpan = .{ .src = null, .count = 0 };

    /// Borrows `bytes` for as long as the caller keeps them alive.
    pub fn of(bytes: []const u8) AMbyteSpan {
        return .{ .src = bytes.ptr, .count = bytes.len };
    }

    /// The borrowed bytes, or the empty slice when `src` is null.
    ///
    /// Rust: `impl From<&AMbyteSpan> for &[u8]`, `src/byte_span.rs:118-126`.
    pub fn slice(self: AMbyteSpan) []const u8 {
        const src = self.src orelse return &.{};
        return src[0..self.count];
    }

    /// Tests two spans for byte equality. Rust: `src/byte_span.rs:52-60`.
    pub fn eql(lhs: AMbyteSpan, rhs: AMbyteSpan) bool {
        if (lhs.count != rhs.count) return false;
        if (lhs.src == rhs.src) return true;
        return std.mem.eql(u8, lhs.slice(), rhs.slice());
    }
};

/// A value whose type is unknown, preserved verbatim so that a document
/// written by a future version of automerge round-trips unchanged.
/// Rust: `src/item.rs:25-30`.
pub const AMunknownValue = extern struct {
    /// The value's raw bytes. Rust: `:27`.
    bytes: AMbyteSpan,
    /// The value's encoded type identifier, the low four bits of its metadata
    /// word. Not an `AMvalType`. Rust: `:29`.
    type_code: u8,
};

// ---------------------------------------------------------------------------
// AMresult. Rust: src/result.rs.
// ---------------------------------------------------------------------------

/// A result: either a sequence of items or an error message.
///
/// Rust: `pub enum AMresult { Items(Vec<AMitem>), Error(String) }`,
/// `src/result.rs:11-14`. Two variants, not an error code per call, which is
/// why the type is a parameter: the item layer supplies `T` and nothing here
/// needs to know what an item is.
pub fn Result(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Whether an item needs an explicit drop. The reference drops a
        /// `Vec<AMitem>`, which drops every `Rc` in it
        /// (`src/result.rs:12`, `:559`); a trivially copyable `T` does not, and
        /// the loop in `deinit` is compiled out for one.
        const item_needs_drop = switch (@typeInfo(T)) {
            .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
            else => false,
        };

        /// One of the two variants. Rust: `src/result.rs:11-14`.
        pub const Variant = union(enum) {
            /// `Items(Vec<AMitem>)`. Rust: `:12`.
            items: std.ArrayList(T),
            /// `Error(String)`. Rust: `:13`.
            error_msg: []u8,
        };

        /// The allocator that built this result. `deinit` frees with it, which
        /// is why a caller cannot release a result without naming it.
        allocator: Allocator,
        variant: Variant,

        /// The empty items variant. Rust: `impl Default for AMresult`
        /// (`src/result.rs:31-35`) is `Items(vec![])`, not an error.
        pub fn init(gpa: Allocator) Self {
            return .{ .allocator = gpa, .variant = .{ .items = .empty } };
        }

        /// `AMresult::error(s)`. Rust: `src/result.rs:17-19`.
        ///
        /// Copies `message`, so the caller may reuse its buffer. Truncates at
        /// the first NUL, because the message reaches C through
        /// `AMresultError`, which returns a `{ptr, count}` span, and a NUL
        /// inside it would be silently dropped by any `printf` a caller uses.
        pub fn initError(gpa: Allocator, message: []const u8) Allocator.Error!Self {
            const end = std.mem.indexOfScalar(u8, message, 0) orelse message.len;
            return .{
                .allocator = gpa,
                .variant = .{ .error_msg = try gpa.dupe(u8, message[0..end]) },
            };
        }

        /// `AMresult::item(item)`. Rust: `src/result.rs:21-23`.
        pub fn initItem(gpa: Allocator, value: T) Allocator.Error!Self {
            var self = Self.init(gpa);
            errdefer self.deinit();
            try self.variant.items.append(gpa, value);
            return self;
        }

        /// `AMresult::items(items)`. Rust: `src/result.rs:25-27`.
        pub fn initItems(gpa: Allocator, list: std.ArrayList(T)) Self {
            return .{ .allocator = gpa, .variant = .{ .items = list } };
        }

        /// Boxes the result. This is the only way to obtain a `*Result`, which
        /// is what makes the single-destructor rule enforceable in Zig.
        ///
        /// Rust: `to_result` (`src/result.rs:466-468`) calls
        /// `impl From<AMresult> for *mut AMresult` (`:95`), which is
        /// `Box::into_raw(Box::new(b))`. There is no other route to a pointer.
        pub fn toOwned(self: Self, gpa: Allocator) Allocator.Error!*Self {
            const ptr = try gpa.create(Self);
            ptr.* = self;
            return ptr;
        }

        /// Releases the result, and drops every item it owns. This and
        /// `AMresultFree` are the only two functions in this file that
        /// deallocate.
        ///
        /// Dropping the items mirrors the reference dropping a `Vec<AMitem>`,
        /// which drops each `Rc` in turn (`src/result.rs:12`, `:559`). A
        /// trivially copyable `T` needs no `deinit`, so the loop is compiled
        /// out for one.
        pub fn deinit(self: *Self) void {
            switch (self.variant) {
                .items => |*list| {
                    if (comptime item_needs_drop) {
                        for (list.items) |*owned| owned.deinit(self.allocator);
                    }
                    list.deinit(self.allocator);
                },
                .error_msg => |msg| self.allocator.free(msg),
            }
            self.* = undefined;
        }

        /// `AMresultStatus`. Rust: `src/result.rs:639-653`.
        ///
        /// A null pointer is `AM_STATUS_INVALID_RESULT`: the reference's
        /// `result.as_ref()` at `:640` is the null check and the fallthrough at
        /// `:651-652` returns `InvalidResult`. So the tag means "you passed
        /// NULL", not "the value had the wrong type".
        pub fn status(result: ?*const Self) AMstatus {
            const r = result orelse return .invalid_result;
            return switch (r.variant) {
                .error_msg => .error_,
                .items => .ok,
            };
        }

        /// `AMresultError`. Rust: `src/result.rs:538-545`.
        ///
        /// A span borrowed from the result, so `deinit` invalidates it. A
        /// non-error result gives the zero span, because the reference's
        /// `Default::default()` at `:544` is `{src: null, count: 0}`.
        pub fn errorMessage(result: ?*const Self) AMbyteSpan {
            const r = result orelse return .empty;
            return switch (r.variant) {
                .error_msg => |msg| AMbyteSpan.of(msg),
                .items => .empty,
            };
        }

        /// `AMresultSize`. Rust: `src/result.rs:619-626`.
        ///
        /// An error result has size `0`, so size alone cannot tell a failure
        /// from a success with no items; that is what `status` is for.
        pub fn size(result: ?*const Self) usize {
            const r = result orelse return 0;
            return switch (r.variant) {
                .items => |list| list.items.len,
                .error_msg => 0,
            };
        }

        /// `AMresultItem`. Rust: `src/result.rs:575-584`.
        ///
        /// A pointer *into the result's own array*, so it aliases anything
        /// else taken from the same result and dies with it. Null for an error
        /// result or an empty one, matching the reference's two guards at
        /// `:577-578`.
        pub fn item(result: ?*Self) ?*T {
            const r = result orelse return null;
            return switch (r.variant) {
                .items => |list| if (list.items.len == 0) null else &list.items[0],
                .error_msg => null,
            };
        }

        /// The result's own item array, or null for an error or empty result.
        /// Rust: `src/result.rs:597-606`.
        pub fn items(result: ?*Self) ?[]T {
            const r = result orelse return null;
            return switch (r.variant) {
                .items => |list| if (list.items.len == 0) null else list.items,
                .error_msg => null,
            };
        }

        /// `AMresultCat`. Rust: `src/result.rs:504-525`.
        ///
        /// Allocates a *new* result and **leaves both inputs alive**: the
        /// caller still owns `dest` and `src`. This is the opposite contract
        /// from `resultFrom`, which frees its arguments, and the reference
        /// header says so (`include/automerge-c/utils/result.h:22-24`).
        ///
        /// The two failure messages are distinct upstream and the reference
        /// suite distinguishes them (`src/result.rs:513-521`): a null *pointer*
        /// gives "Invalid `AMresult*`", an error *variant* gives
        /// "Invalid `AMresult`" with no star.
        pub fn cat(gpa: Allocator, dest: ?*const Self, src: ?*const Self) Allocator.Error!*Self {
            if (dest == null or src == null) {
                return try (try Self.initError(gpa, "Invalid `AMresult*`")).toOwned(gpa);
            }
            const d = dest.?;
            const s = src.?;
            switch (d.variant) {
                .items => |dest_list| switch (s.variant) {
                    .items => |src_list| {
                        var out: std.ArrayList(T) = .empty;
                        errdefer out.deinit(gpa);
                        // Upstream chains `dest_items.iter().cloned()` with
                        // `src_items.iter().cloned()` (`src/result.rs:507-511`),
                        // so a shared item's reference count is bumped rather
                        // than its bytes copied.
                        // `appendSlice` copies the `AMitem` **struct** — a
                        // `{rc: *RcItem}` — so without a `retain` per item two
                        // results end up pointing at one cell and the second
                        // `AMresultFree` is a double free. Upstream's
                        // `cloned()` on an `Rc` bumps the count; that is what
                        // these two calls are. The guard keeps `Result(T)`
                        // usable for a `T` with no shared ownership.
                        for (dest_list.items) |it| try out.append(gpa, retainItem(it));
                        for (src_list.items) |it| try out.append(gpa, retainItem(it));
                        return try Self.initItems(gpa, out).toOwned(gpa);
                    },
                    .error_msg => return try (try Self.initError(gpa, "Invalid `AMresult`")).toOwned(gpa),
                },
                .error_msg => return try (try Self.initError(gpa, "Invalid `AMresult`")).toOwned(gpa),
            }
        }

        /// The Zig equivalent of the variadic `AMresultFrom`. Rust:
        /// `src/utils/result.c:5-33`.
        ///
        /// Moves the items of every result in `results` into a new one, in
        /// order, and **frees every input** whether or not it succeeds, then
        /// returns null on failure. Ownership of the pointers transfers on
        /// entry: the caller must not touch them afterwards and must not free
        /// them itself.
        ///
        /// **Any** input that is null or is an error result fails the whole
        /// call, which is what the reference's own header promises
        /// (`include/automerge-c/utils/result.h:22-24`, reproduced at
        /// `include/automerge.h:511-512`). The reference's *body* only keeps
        /// that promise when the failing argument is **last**: it writes
        /// `is_ok = (AMresultStatus(src) == AM_STATUS_OK);` on every iteration
        /// (`src/utils/result.c:13`) with no `&&`, so the flag is whatever the
        /// final argument said. `AMresultFrom(2, failing, ok)` therefore hands
        /// back the surviving `ok` upstream and `null` here. The C suite calls
        /// it three times, all-OK (`test/c/suite/ported_wasm/basic_tests.c:432`,
        /// `:1406`), so nothing observable moves; the documented contract is
        /// the one followed.
        ///
        /// An empty `results` is **not** a failure and **not** null either: it
        /// is a new result with no items. `AMresultFrom(0, …)` upstream is
        /// `NULL` (`result.c:6`, `:29-32`), and that is a decision the C
        /// export makes, not this one — see [`CAbi.AMresultFromList`].
        pub fn resultFrom(gpa: Allocator, results: []const ?*Self) Allocator.Error!?*Self {
            // Free the inputs first, so that every return path below is a
            // single exit and cannot leak one. The reference frees as it goes
            // and frees the accumulated result at the end
            // (`src/utils/result.c:10-31`); doing it up front is the same set
            // of frees in a form that cannot be skipped.
            var owned: usize = results.len;
            defer {
                for (results) |maybe| {
                    if (owned == 0) break;
                    owned -= 1;
                    if (maybe) |r| {
                        const owner = r.allocator;
                        r.deinit();
                        owner.destroy(r);
                    }
                }
            }

            var out: std.ArrayList(T) = .empty;
            errdefer out.deinit(gpa);
            for (results) |maybe| {
                const r = maybe orelse return null;
                if (status(r) != .ok) return null;
                if (r.variant != .items) return null;
                // **Retain before the `defer` frees every input.** The append
                // is a struct copy, so without this every item in the result
                // we are about to return points at an `RcItem` that free has
                // already released.
                for (r.variant.items.items) |it| try out.append(gpa, retainItem(it));
            }
            return try Self.initItems(gpa, out).toOwned(gpa);
        }
    };
}

/// Bumps an item's shared-ownership count, if its type has one. Upstream's
/// `iter().cloned()` on an `Rc<Item>` does this implicitly; a Zig struct copy
/// does not, and the difference is a double free on the C side.
fn retainItem(it: anytype) @TypeOf(it) {
    const T = @TypeOf(it);
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        // `Result(u64)` and friends carry no shared ownership, so a copy of
        // them is the whole value. `@hasDecl` would not compile here.
        else => return it,
    }
    if (@hasDecl(T, "retain")) return it.retain();
    return it;
}

/// `to_result`: build a result and box it, which is the one step every C
/// entry point performs before handing a pointer back. Rust: `src/result.rs:466-468`.
///
/// Split in two because `try` binds tighter than a method call in Zig, so
/// `try (init(..)).toOwned(gpa)` would look for `toOwned` on the error union.
fn boxResult(comptime RT: type, gpa: Allocator, r: Allocator.Error!RT) Allocator.Error!*RT {
    var self = try r;
    return try self.toOwned(gpa);
}

// ---------------------------------------------------------------------------
// AMitems. Rust: src/items.rs.
//
// A cursor over a result's own item array. It is here rather than with the
// item layer because `AMresultItems`, which is `result.rs:597`, returns one,
// and because the whole type is the `{len, offset, ptr}` triple the reference
// hides inside an opaque `uint8_t detail[24]`
// (`src/items.rs:10-15`, `src/items.rs:123-132`). `docs/plan.md` §10 records
// the decision to make those three fields visible instead; the layout and
// therefore the size are unchanged.
// ---------------------------------------------------------------------------

/// Compares two items. Zig spells `PartialEq` as an `eql` method, so an item
/// that is a refcounted handle declares one and compares the value behind it,
/// which is what the reference's `[AMitem] == [AMitem]` does over `Rc<Item>`
/// (`src/items.rs:181-186`). A primitive item needs no declaration and is
/// compared with `==`.
fn itemsEqual(x: anytype, y: anytype) bool {
    const T = @TypeOf(x);
    // `@hasDecl` only accepts a container type, so a primitive item has to be
    // screened out before it is asked about.
    const has_eql = switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "eql"),
        else => false,
    };
    if (comptime has_eql) return x.eql(y);
    return x == y;
}

/// A random-access cursor over a sequence of items. Rust: `src/items.rs:125-132`.
pub fn Items(comptime T: type) type {
    return extern struct {
        const Self = @This();

        /// The count of items in the sequence. Rust: `src/items.rs:12`.
        len: usize,
        /// The cursor position. Negative means reversed. Rust: `src/items.rs:13`.
        offset: isize,
        /// The items, borrowed from the owning result. Rust: `src/items.rs:14`.
        ptr: ?[*]T,

        /// The zero cursor. Rust: `impl Default for AMitems` (`src/items.rs:186-193`).
        pub const empty: Self = .{ .len = 0, .offset = 0, .ptr = null };

        /// `AMitems::new(items)`. Rust: `src/items.rs:135-140`.
        pub fn init(items: []T) Self {
            return .{ .len = items.len, .offset = 0, .ptr = if (items.len == 0) null else items.ptr };
        }

        /// The sequence, whatever the cursor's position. Rust: `src/items.rs:180-184`.
        pub fn slice(self: Self) []const T {
            const ptr = self.ptr orelse return &.{};
            return ptr[0..self.len];
        }

        /// `Detail::advance`. Rust: `src/items.rs:33-56`.
        ///
        /// Saturating rather than wrapping, exactly as the reference's
        /// `checked_add`/`checked_sub` with an `unwrap_or` do (`:40`, `:48`),
        /// and clamped to the stop in the same two cases (`:42-45`, `:49-52`).
        /// A zero step is a no-op (`:34-36`), which is why `prev(0)` and
        /// `next(0)` both return the current item.
        pub fn advance(self: *Self, n: isize) void {
            if (n == 0) return;
            const len = cursorLen(self.len);
            if (self.offset < 0) {
                // Reversed: a positive step walks towards the forward stop.
                const unclipped = std.math.sub(isize, self.offset, n) catch std.math.minInt(isize);
                self.offset = if (unclipped >= 0)
                    len
                else
                    @min(@max(-(len +% 1), unclipped), -1);
            } else {
                const unclipped = std.math.add(isize, self.offset, n) catch std.math.maxInt(isize);
                self.offset = if (unclipped < 0)
                    -(len +% 1)
                else
                    @max(0, @min(unclipped, len));
            }
        }

        /// `Detail::get_index`. Rust: `src/items.rs:58-65`.
        ///
        /// The reference casts a possibly negative `isize` to `usize`, which
        /// wraps; here the value is clamped, which is the same answer for every
        /// cursor that is not stopped and a defined one for a corrupt cursor
        /// rather than a huge index.
        pub fn index(self: Self) usize {
            const shifted = self.offset +% (if (self.offset < 0) cursorLen(self.len) else 0);
            return @intCast(@max(shifted, 0));
        }

        /// `Detail::is_stopped`. Rust: `src/items.rs:78-81`.
        pub fn isStopped(self: Self) bool {
            const len = cursorLen(self.len);
            return self.offset < -len or self.offset == len;
        }

        /// A cursor's length as a signed count, saturating rather than
        /// trapping. A cursor longer than `isize` cannot be indexed on this
        /// platform anyway, and every use here is a clamp or a comparison, so
        /// the saturated value gives the same answer a wrap would for every
        /// reachable cursor instead of an out-of-range cast in Debug.
        fn cursorLen(len: usize) isize {
            return std.math.cast(isize, len) orelse std.math.maxInt(isize);
        }

        /// `Detail::next`: get, then advance. Rust: `src/items.rs:67-77`.
        pub fn next(self: *Self, n: isize) ?*T {
            if (self.isStopped()) return null;
            const ptr = self.ptr orelse return null;
            const at = self.index();
            if (at >= self.len) return null;
            const value = &ptr[at];
            self.advance(n);
            return value;
        }

        /// `Detail::prev`: advance, then get. Rust: `src/items.rs:83-91`.
        ///
        /// The order is the opposite of `next`'s, so with `|n| > 1` the two
        /// return different items from the same starting cursor.
        pub fn prev(self: *Self, n: isize) ?*T {
            self.advance(-%(n));
            if (self.isStopped()) return null;
            const ptr = self.ptr orelse return null;
            const at = self.index();
            if (at >= self.len) return null;
            return &ptr[at];
        }

        /// `Detail::reversed`. Rust: `src/items.rs:93-99`.
        pub fn reversed(self: Self) Self {
            return .{ .len = self.len, .offset = -%(self.offset +% 1), .ptr = self.ptr };
        }

        /// `Detail::rewound`. Rust: `src/items.rs:101-107`.
        pub fn rewound(self: Self) Self {
            return .{ .len = self.len, .offset = if (self.offset < 0) -1 else 0, .ptr = self.ptr };
        }

        /// `AMitemsEqual`. Rust: `src/items.rs:288-293`.
        ///
        /// Compares the two underlying *sequences*, not the cursors, so two
        /// copies of the same result at different positions are equal.
        pub fn eql(lhs: Self, rhs: Self) bool {
            const a = lhs.slice();
            const b = rhs.slice();
            if (a.len != b.len) return false;
            for (a, b) |x, y| {
                if (!itemsEqual(x, y)) return false;
            }
            return true;
        }
    };
}

// ---------------------------------------------------------------------------
// The stack. Rust: src/utils/stack.c.
//
// A singly-linked list of results. It exists so a C caller can collect every
// `AMresultFree` in one place instead of writing `goto` at every early exit,
// which is the reference's own stated motivation
// (`include/automerge-c/utils/stack.h:5-12`).
// ---------------------------------------------------------------------------

/// A node in a stack of results. Rust: `include/automerge-c/utils/stack.h:21-26`.
///
/// The node *is* the stack: a C caller holds `AMstack*` and the list hangs off
/// `prev`, so there is no separate container to keep in step. That is also why
/// every operation takes the allocator rather than holding one — the C side
/// has nowhere to put it, and `CAbi` binds `c_allocator` at the boundary.
pub fn Stack(comptime T: type) type {
    return extern struct {
        const Self = @This();

        /// A result to be deallocated. Rust: `stack.h:23`.
        result: ?*Result(T),
        /// The previous node, or null. Rust: `stack.h:25`.
        prev: ?*Self,

        /// The prototype of a result validator, as C sees it. Rust:
        /// `include/automerge-c/utils/stack.h:39`.
        ///
        /// It takes the raw `AMstack **` the reference's callback receives, so
        /// a callback written in C can inspect the top result directly
        /// (`src/utils/stack.c:67-74`).
        ///
        /// Two things about this declaration are load-bearing, and both were
        /// found by linking a real C caller against the built library:
        ///
        /// * `callconv(.c)` is required. A bare `*const fn` defaults to
        ///   `.auto`, which `std.builtin.CallingConvention` documents as making
        ///   "no guarantees about stack alignment, registers, etc." and as
        ///   "only usable within this Zig compilation unit"
        ///   (`std/builtin.zig:147-150`). Without it the C callback read its
        ///   first argument as a tagged value rather than an address.
        /// * The first parameter is spelled `?*?*Self`, an *optional* pointer
        ///   to an optional pointer, which is the only spelling that lowers to
        ///   C's `AMstack **`. `*?*Self` is a pointer to an optional and does
        ///   not.
        pub const Callback = *const fn (stack: ?*?*Self, data: ?*anyopaque) callconv(.c) bool;

        /// Releases a result and the box holding it. The two steps are always
        /// together, which is the only deallocation path in the C ABI.
        fn destroy(result: ?*Result(T)) void {
            const r = result orelse return;
            // Read before `deinit`, which poisons the struct.
            const owner = r.allocator;
            r.deinit();
            owner.destroy(r);
        }

        /// `AMstackSize`. Rust: `src/utils/stack.c:95-106`.
        pub fn size(top: ?*const Self) usize {
            var count: usize = 0;
            var node = top;
            while (node) |n| : (count += 1) {
                node = n.prev;
            }
            return count;
        }

        /// `AMstackPop`. Rust: `src/utils/stack.c:15-33`.
        ///
        /// A null `want` pops the top node; otherwise the list is searched for
        /// the node holding that result (`:20-24`). The reference advances its
        /// cursor in place while searching, so a failed search leaves the list
        /// truncated; this walk mutates nothing, which is the same answer for
        /// every search that succeeds and a strictly safer one otherwise.
        pub fn pop(gpa: Allocator, top: *?*Self, want: ?*const Result(T)) ?*Result(T) {
            var link = top;
            while (link.*) |node| {
                if (want == null or node.result == want) {
                    link.* = node.prev;
                    const popped = node.result;
                    gpa.destroy(node);
                    return popped;
                }
                link = &node.prev;
            }
            return null;
        }

        /// `AMstackFree`. Rust: `src/utils/stack.c:7-13`.
        ///
        /// Frees every node and every result on it, leaving `top` null.
        pub fn freeAll(gpa: Allocator, top: *?*Self) void {
            while (top.*) |_| {
                destroy(pop(gpa, top, null));
            }
        }

        /// `AMstackResult`. Rust: `src/utils/stack.c:35-84`.
        ///
        /// Pushes `result`, runs `callback` over the new top, and returns
        /// `result` or null. Two ownership rules, both from the reference:
        ///
        /// * A rejected result stays on the stack and is freed by
        ///   `AMstackFree` (`:59-63`), so a rejected result is reported, not
        ///   leaked.
        /// * The reference frees `result` when the caller passed a null stack
        ///   (`:50-51`), after still running the callback against a temporary
        ///   local node so it can inspect the result (`:37-42`). `push` takes
        ///   a real `*?*Self`, so that path is the caller's to take and
        ///   `CAbi.AMstackResult` reproduces it.
        pub fn push(
            gpa: Allocator,
            top: *?*Self,
            result: ?*Result(T),
            callback: ?Callback,
            data: ?*anyopaque,
        ) ?*Result(T) {
            const node = gpa.create(Self) catch {
                // Without a node there is nowhere to record the result, so
                // free it rather than return an unownable pointer.
                destroy(result);
                return null;
            };
            node.* = .{ .result = result, .prev = top.* };
            top.* = node;

            if (callback) |cb| {
                if (!cb(top, data)) return null;
            } else if (result == null) {
                // The reference logs to stderr and returns null here
                // (`src/utils/stack.c:76-81`). The null result stays on the
                // stack and `AMstackFree` handles it.
                return null;
            }
            return result;
        }
    };
}

// ---------------------------------------------------------------------------
// The C-callable surface that does not need an allocator.
//
// These are the only `export`s that can be analysed without libc, which is
// what lets this file be tested by an ordinary `zig build test`. Everything
// that allocates lives in `CAbi` below.
// ---------------------------------------------------------------------------

/// `AMbytes`. Rust: `src/byte_span.rs:176-181`.
///
/// A null pointer normalises `count` to `0` (`:179`), which is what makes
/// `AMbytes(NULL, SIZE_MAX)` safe rather than a wild read.
pub export fn AMbytes(src: ?[*]const u8, count: usize) AMbyteSpan {
    return .{ .src = src, .count = if (src == null) 0 else count };
}

/// `AMstr`. Rust: `src/byte_span.rs:194`; the conversion is at `:90-101`.
///
/// A null pointer gives the zero span; otherwise the count is `strlen`, so the
/// span covers the C string up to its first NUL.
pub export fn AMstr(c_str: ?[*:0]const u8) AMbyteSpan {
    const s = c_str orelse return .empty;
    return AMbyteSpan.of(std.mem.span(s));
}

/// `AMstrCmp`. Rust: `src/byte_span.rs:216-227`.
///
/// The reference validates both sides as UTF-8 through
/// `TryFrom<&AMbyteSpan> for &str` (`src/byte_span.rs:148-160`) and then orders
/// them, mapping `(Err, Ok) => -1`, `(Err, Err) => 0`, `(Ok, Err) => 1`
/// (`:222-225`). An invalid span therefore sorts *before* a valid one, and two
/// invalid spans compare equal.
pub export fn AMstrCmp(lhs: AMbyteSpan, rhs: AMbyteSpan) c_int {
    const l = lhs.slice();
    const r = rhs.slice();
    const l_ok = std.unicode.utf8ValidateSlice(l);
    const r_ok = std.unicode.utf8ValidateSlice(r);
    if (!l_ok) return if (r_ok) -1 else 0;
    if (!r_ok) return 1;
    return switch (std.mem.order(u8, l, r)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// One entry in a tag table: the integer the C header declares and the
/// spelling the enum-to-string round trip uses.
const AMobjTypeTag = struct { n: [*:0]const u8, v: AMobjType };
const AMmarkExpandTag = struct { n: [*:0]const u8, v: AMmarkExpand };
const AMidxTypeTag = struct { n: [*:0]const u8, v: AMidxType };
const AMvalTypeTag = struct { n: [*:0]const u8, v: AMvalType };
const AMstatusTag = struct { n: [*:0]const u8, v: AMstatus };

// The tag tables the reference's CMake generator emits from the header
// (`cmake/enum-string-functions-gen.cmake:30-77`), in the order it lists them.

const obj_type_tags = [_]AMobjTypeTag{
    .{ .n = "AM_OBJ_TYPE_DEFAULT", .v = AMobjType.AM_OBJ_TYPE_DEFAULT },
    .{ .n = "AM_OBJ_TYPE_LIST", .v = AMobjType.AM_OBJ_TYPE_LIST },
    .{ .n = "AM_OBJ_TYPE_MAP", .v = AMobjType.AM_OBJ_TYPE_MAP },
    .{ .n = "AM_OBJ_TYPE_TEXT", .v = AMobjType.AM_OBJ_TYPE_TEXT },
};

const mark_expand_tags = [_]AMmarkExpandTag{
    .{ .n = "AM_MARK_EXPAND_AFTER", .v = AMmarkExpand.AM_MARK_EXPAND_AFTER },
    .{ .n = "AM_MARK_EXPAND_BEFORE", .v = AMmarkExpand.AM_MARK_EXPAND_BEFORE },
    .{ .n = "AM_MARK_EXPAND_BOTH", .v = AMmarkExpand.AM_MARK_EXPAND_BOTH },
    .{ .n = "AM_MARK_EXPAND_DEFAULT", .v = AMmarkExpand.AM_MARK_EXPAND_DEFAULT },
    .{ .n = "AM_MARK_EXPAND_NONE", .v = AMmarkExpand.AM_MARK_EXPAND_NONE },
};

const idx_type_tags = [_]AMidxTypeTag{
    .{ .n = "AM_IDX_TYPE_DEFAULT", .v = AMidxType.AM_IDX_TYPE_DEFAULT },
    .{ .n = "AM_IDX_TYPE_KEY", .v = AMidxType.AM_IDX_TYPE_KEY },
    .{ .n = "AM_IDX_TYPE_POS", .v = AMidxType.AM_IDX_TYPE_POS },
};

const val_type_tags = [_]AMvalTypeTag{
    .{ .n = "AM_VAL_TYPE_ACTOR_ID", .v = AMvalType.AM_VAL_TYPE_ACTOR_ID },
    .{ .n = "AM_VAL_TYPE_BOOL", .v = AMvalType.AM_VAL_TYPE_BOOL },
    .{ .n = "AM_VAL_TYPE_BYTES", .v = AMvalType.AM_VAL_TYPE_BYTES },
    .{ .n = "AM_VAL_TYPE_CHANGE", .v = AMvalType.AM_VAL_TYPE_CHANGE },
    .{ .n = "AM_VAL_TYPE_CHANGE_HASH", .v = AMvalType.AM_VAL_TYPE_CHANGE_HASH },
    .{ .n = "AM_VAL_TYPE_COUNTER", .v = AMvalType.AM_VAL_TYPE_COUNTER },
    .{ .n = "AM_VAL_TYPE_CURSOR", .v = AMvalType.AM_VAL_TYPE_CURSOR },
    .{ .n = "AM_VAL_TYPE_DEFAULT", .v = AMvalType.AM_VAL_TYPE_DEFAULT },
    .{ .n = "AM_VAL_TYPE_DOC", .v = AMvalType.AM_VAL_TYPE_DOC },
    .{ .n = "AM_VAL_TYPE_F64", .v = AMvalType.AM_VAL_TYPE_F64 },
    .{ .n = "AM_VAL_TYPE_INT", .v = AMvalType.AM_VAL_TYPE_INT },
    .{ .n = "AM_VAL_TYPE_MARK", .v = AMvalType.AM_VAL_TYPE_MARK },
    .{ .n = "AM_VAL_TYPE_NULL", .v = AMvalType.AM_VAL_TYPE_NULL },
    .{ .n = "AM_VAL_TYPE_OBJ_TYPE", .v = AMvalType.AM_VAL_TYPE_OBJ_TYPE },
    .{ .n = "AM_VAL_TYPE_STR", .v = AMvalType.AM_VAL_TYPE_STR },
    .{ .n = "AM_VAL_TYPE_SYNC_HAVE", .v = AMvalType.AM_VAL_TYPE_SYNC_HAVE },
    .{ .n = "AM_VAL_TYPE_SYNC_MESSAGE", .v = AMvalType.AM_VAL_TYPE_SYNC_MESSAGE },
    .{ .n = "AM_VAL_TYPE_SYNC_STATE", .v = AMvalType.AM_VAL_TYPE_SYNC_STATE },
    .{ .n = "AM_VAL_TYPE_TIMESTAMP", .v = AMvalType.AM_VAL_TYPE_TIMESTAMP },
    .{ .n = "AM_VAL_TYPE_UINT", .v = AMvalType.AM_VAL_TYPE_UINT },
    .{ .n = "AM_VAL_TYPE_UNKNOWN", .v = AMvalType.AM_VAL_TYPE_UNKNOWN },
    .{ .n = "AM_VAL_TYPE_VOID", .v = AMvalType.AM_VAL_TYPE_VOID },
};

const status_tags = [_]AMstatusTag{
    .{ .n = "AM_STATUS_OK", .v = AMstatus.ok },
    .{ .n = "AM_STATUS_ERROR", .v = AMstatus.error_ },
    .{ .n = "AM_STATUS_INVALID_RESULT", .v = AMstatus.invalid_result },
};

/// The generated `ToString` body. An unrecognised tag reads back as the
/// literal `"???"`, which is the generator's `default:` arm
/// (`enum-string-functions-gen.cmake:55-57`) and is what the cmocka suite
/// asserts (`test/enum_string_tests.c:30, :52, :72, :109`).
fn tagToString(tags: anytype, raw: u32) [*:0]const u8 {
    for (tags) |tag| {
        if (@as(u32, @intCast(@intFromEnum(tag.v))) == raw) return tag.n;
    }
    return "???";
}

/// The generated `FromString` body. `false` leaves `dest` untouched, which
/// the reference suite asserts by pre-setting the out-parameter to `-1` and
/// checking it is still `-1` (`test/enum_string_tests.c:38-40`).
fn tagFromString(tags: anytype, dest: anytype, src: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, src, std.mem.span(tag.n))) {
            dest.* = tag.v;
            return true;
        }
    }
    return false;
}

/// `AMobjTypeToString`. Rust: generated, see
/// `cmake/enum-string-functions-gen.cmake:53-66`.
///
/// The tag is a raw `u32` rather than the Zig enum on purpose. The C prototype
/// in `include/automerge.h` declares it as `AMobjType const tag`, and every C
/// compiler lowers that enum to `unsigned int`, so the ABI is identical; but a
/// Zig `enum` parameter validates its argument and would trap on the out-of-range
/// tags the reference's own suite passes
/// (`test/enum_string_tests.c:30, :52, :72, :109`). Taking the integer keeps
/// the function total, and the `default:` arm becomes the "???" string.
pub export fn AMobjTypeToString(tag: u32) [*:0]const u8 {
    return tagToString(obj_type_tags, tag);
}

pub export fn AMobjTypeFromString(dest: *AMobjType, src: ?[*:0]const u8) bool {
    return tagFromString(obj_type_tags, dest, std.mem.span(src orelse return false));
}

pub export fn AMmarkExpandToString(tag: u32) [*:0]const u8 {
    return tagToString(mark_expand_tags, tag);
}

pub export fn AMmarkExpandFromString(dest: *AMmarkExpand, src: ?[*:0]const u8) bool {
    return tagFromString(mark_expand_tags, dest, std.mem.span(src orelse return false));
}

pub export fn AMidxTypeToString(tag: u32) [*:0]const u8 {
    return tagToString(idx_type_tags, tag);
}

pub export fn AMidxTypeFromString(dest: *AMidxType, src: ?[*:0]const u8) bool {
    return tagFromString(idx_type_tags, dest, std.mem.span(src orelse return false));
}

pub export fn AMvalTypeToString(tag: u32) [*:0]const u8 {
    return tagToString(val_type_tags, tag);
}

pub export fn AMvalTypeFromString(dest: *AMvalType, src: ?[*:0]const u8) bool {
    return tagFromString(val_type_tags, dest, std.mem.span(src orelse return false));
}

pub export fn AMstatusToString(tag: u32) [*:0]const u8 {
    return tagToString(status_tags, tag);
}

pub export fn AMstatusFromString(dest: *AMstatus, src: ?[*:0]const u8) bool {
    return tagFromString(status_tags, dest, std.mem.span(src orelse return false));
}

// ---------------------------------------------------------------------------
// The C ABI.
//
// `CAbi(Item)` is instantiated once, by the item layer, and emits the 26
// allocating exports below. It is generic only so that this file stands alone;
// it is not a template the reader is meant to instantiate more than once,
// because two instantiations would emit the same symbols twice.
// ---------------------------------------------------------------------------

/// The C-callable surface over one item type.
///
/// Every function here is total: null pointers are reported rather than
/// dereferenced, and an allocation failure becomes an error result or a null
/// return rather than an escape. None can panic, and none unwinds across the
/// ABI boundary, because none calls into a Rust-style `catch_unwind` and none
/// relies on a trap for control flow.
pub fn CAbi(comptime Item: type) type {
    return struct {
        const Self = @This();

        /// `AMresult` over this item type.
        pub const AMresult = Result(Item);
        /// `AMitems` over this item type.
        pub const AMitems = Items(Item);

        /// The allocator the C ABI allocates from.
        ///
        /// The reference resolves this through Rust's global `Box` allocator
        /// (`src/result.rs:95`, `:466-468`). A C ABI whose signatures are fixed
        /// cannot carry an allocator, so the one allocator a C caller can also
        /// free with `free()` is the only choice that keeps the ABI and
        /// `AMstrdup`'s documented contract
        /// (`include/automerge-c/utils/string.h:24-25`) simultaneously true.
        ///
        /// It is a compile error when libc is not linked, which is correct:
        /// these symbols are meaningless without a C runtime to free them.
        pub const c_allocator: Allocator = if (builtin.link_libc)
            std.heap.c_allocator
        else
            @compileError("the C ABI needs libc: build the C target with .link_libc = true");

        /// A node in a stack of results, as C sees it. Rust:
        /// `include/automerge-c/utils/stack.h:21-26`.
        ///
        /// This is `Stack(Item)` itself rather than a copy of it: the node is
        /// `{AMresult *, AMstack *}` on both sides, so aliasing the one type
        /// keeps the C layout and the Zig logic from drifting apart.
        pub const AMstack = Stack(Item);

        /// The prototype of a result validator, as C sees it. See
        /// `Stack.Callback` for the two things its declaration has to get
        /// right.
        pub const AMstackCallback = Stack(Item).Callback;

        /// The parameters of an item value test. Rust:
        /// `include/automerge-c/utils/stack_callback_data.h:17-24`.
        pub const AMstackCallbackData = extern struct {
            /// A bitmask of `AMvalType` tags. Rust: `stack_callback_data.h:19`.
            bitmask: AMvalType,
            /// A null-terminated file path. Rust: `:21`.
            file: ?[*:0]const u8,
            /// A line number. Rust: `:23`.
            line: c_int,
        };

        // -- the one destructor ---------------------------------------------

        /// `AMresultFree`. Rust: `src/result.rs:557-562`.
        ///
        /// The only deallocating export. It null-checks before
        /// `Box::from_raw`, exactly as upstream does at `:558`, so a null
        /// argument is a no-op rather than a crash. It returns `void` so that
        /// it cannot be forgotten on an error path.
        pub export fn AMresultFree(result: ?*AMresult) void {
            AMstack.destroy(result);
        }

        // -- the other AMresult accessors -----------------------------------

        /// `AMresultStatus`. Rust: `src/result.rs:639-653`.
        pub export fn AMresultStatus(result: ?*const AMresult) AMstatus {
            return AMresult.status(result);
        }

        /// `AMresultError`. Rust: `src/result.rs:538-545`.
        pub export fn AMresultError(result: ?*const AMresult) AMbyteSpan {
            return AMresult.errorMessage(result);
        }

        /// `AMresultSize`. Rust: `src/result.rs:619-626`.
        pub export fn AMresultSize(result: ?*const AMresult) usize {
            return AMresult.size(result);
        }

        /// `AMresultItem`. Rust: `src/result.rs:575-584`.
        pub export fn AMresultItem(result: ?*AMresult) ?*Item {
            return AMresult.item(result);
        }

        /// `AMresultItems`. Rust: `src/result.rs:597-606`.
        pub export fn AMresultItems(result: ?*AMresult) AMitems {
            const items = AMresult.items(result) orelse return .empty;
            return AMitems.init(items);
        }

        /// `AMresultCat`. Rust: `src/result.rs:504-525`.
        ///
        /// Allocation failure becomes an error result rather than a null
        /// pointer, because the C contract is that a returned result is owned
        /// by the caller and its status says what went wrong. The two upstream
        /// failure messages are preserved verbatim and stay distinct
        /// (`:513-521`).
        pub export fn AMresultCat(dest: ?*const AMresult, src: ?*const AMresult) ?*AMresult {
            return AMresult.cat(c_allocator, dest, src) catch |e| switch (e) {
                error.OutOfMemory => outOfMemory(),
            };
        }

        /// `AMresultFrom`, the half of it that Zig can express. Rust:
        /// `src/utils/result.c:5-33`, which is hand-written C upstream for
        /// the same reason: a variadic cannot come out of `zig build-obj`.
        /// [result_from.c](result_from.c) gathers the `va_arg`s and calls
        /// this; every decision the function makes is made here.
        ///
        /// **Not in `include/automerge.h`, on purpose.** That header is the
        /// reference's cbindgen output and upstream has no such function; a
        /// C caller that already has an array has [`AMresultCat`], and a C
        /// caller with a variadic list has `AMresultFrom`.
        ///
        /// `AMresultFrom(0, …)` is `NULL` upstream — `result` starts as
        /// `NULL` and the loop never runs (`result.c:6`, `:9-27`, `:29-32`) —
        /// so it is `NULL` here. An **empty slice** in
        /// [`Result.resultFrom`] is a different function with a different
        /// contract and answers an empty *result*; the test at the bottom of
        /// this file pins that.
        ///
        /// A negative `count` is `NULL` too. Upstream's loop is
        /// `for (int i = 0; i != count; ++i)` (`result.c:10`), which with a
        /// negative `count` runs until `i` wraps and reads `count` garbage
        /// pointers; refusing is the answer the rest of this ABI gives a
        /// caller that gets a precondition wrong.
        pub export fn AMresultFromList(count: c_int, results: ?[*]const ?*AMresult) ?*AMresult {
            if (count <= 0) return null;
            const n: usize = @intCast(count);
            const list = results orelse return null;
            return AMresult.resultFrom(c_allocator, list[0..n]) catch |e| switch (e) {
                error.OutOfMemory => outOfMemory(),
            };
        }

        /// A result carrying the out-of-memory message, or null if even that
        /// could not be allocated. Returning null is safe because every
        /// accessor in this ABI treats null as `AM_STATUS_INVALID_RESULT`
        /// rather than dereferencing it.
        fn outOfMemory() ?*AMresult {
            const r = AMresult.initError(c_allocator, "out of memory") catch return null;
            return r.toOwned(c_allocator) catch null;
        }

        // -- AMitems --------------------------------------------------------

        /// `AMitemsAdvance`. Rust: `src/items.rs:266`.
        pub export fn AMitemsAdvance(items: ?*AMitems, n: isize) void {
            const it = items orelse return;
            it.advance(n);
        }

        /// `AMitemsEqual`. Rust: `src/items.rs:288`.
        pub export fn AMitemsEqual(items1: ?*const AMitems, items2: ?*const AMitems) bool {
            const a = items1 orelse return false;
            const b = items2 orelse return false;
            return AMitems.eql(a.*, b.*);
        }

        /// `AMitemsNext`. Rust: `src/items.rs:312`.
        pub export fn AMitemsNext(items: ?*AMitems, n: isize) ?*Item {
            const it = items orelse return null;
            return it.next(n);
        }

        /// `AMitemsPrev`. Rust: `src/items.rs:338`.
        pub export fn AMitemsPrev(items: ?*AMitems, n: isize) ?*Item {
            const it = items orelse return null;
            return it.prev(n);
        }

        /// `AMitemsSize`. Rust: `src/items.rs:358`.
        pub export fn AMitemsSize(items: ?*const AMitems) usize {
            const it = items orelse return 0;
            return it.len;
        }

        /// `AMitemsReversed`. Rust: `src/items.rs:377`.
        pub export fn AMitemsReversed(items: ?*const AMitems) AMitems {
            const it = items orelse return .empty;
            return it.reversed();
        }

        /// `AMitemsRewound`. Rust: `src/items.rs:396`.
        pub export fn AMitemsRewound(items: ?*const AMitems) AMitems {
            const it = items orelse return .empty;
            return it.rewound();
        }

        // -- the stack ------------------------------------------------------

        /// `AMstackSize`. Rust: `src/utils/stack.c:95-106`.
        pub export fn AMstackSize(stack: ?*const AMstack) usize {
            return AMstack.size(stack);
        }

        /// `AMstackPop`. Rust: `src/utils/stack.c:15-33`.
        pub export fn AMstackPop(stack: ?*?*AMstack, result: ?*const AMresult) ?*AMresult {
            return AMstack.pop(c_allocator, stack orelse return null, result);
        }

        /// `AMstackFree`. Rust: `src/utils/stack.c:7-13`.
        ///
        /// Frees every node and every result on it. A null `stack` pointer is
        /// a no-op, matching the reference's guard at `:8`.
        pub export fn AMstackFree(stack: ?*?*AMstack) void {
            AMstack.freeAll(c_allocator, stack orelse return);
        }

        /// `AMstackResult`. Rust: `src/utils/stack.c:35-84`.
        ///
        /// Pushes `result` onto the stack and validates it with `callback`,
        /// returning `result` or null. The ownership rules are the reference's:
        ///
        /// * A null `stack` frees `result` before returning, so a caller that
        ///   passes null cannot leak it (`:50-51`). The callback still runs
        ///   first, against a temporary local node, so it can inspect the
        ///   result (`:37-42`).
        /// * A rejected result stays on the stack and is freed by
        ///   `AMstackFree` (`:59-63`).
        pub export fn AMstackResult(
            stack: ?*?*AMstack,
            result: ?*AMresult,
            callback: ?AMstackCallback,
            data: ?*anyopaque,
        ) ?*AMresult {
            const s = stack orelse {
                if (callback) |cb| {
                    var local: AMstack = .{ .result = result, .prev = null };
                    var local_ptr: ?*AMstack = &local;
                    _ = cb(&local_ptr, data);
                }
                AMresultFree(result);
                return null;
            };
            return AMstack.push(c_allocator, s, result, callback, data);
        }

        /// `AMstackItems`. Rust: `src/utils/stack.c:91-93`.
        ///
        /// A zero-valued cursor for a null result, matching `(AMitems){0}` in
        /// the reference.
        pub export fn AMstackItems(
            stack: ?*?*AMstack,
            result: ?*AMresult,
            callback: ?AMstackCallback,
            data: ?*anyopaque,
        ) AMitems {
            const kept = AMstackResult(stack, result, callback, data) orelse return .empty;
            return AMresultItems(kept);
        }

        /// `AMstackItem`. Rust: `src/utils/stack.c:86-89`.
        ///
        /// The reference gets the first item of `AMstackItems` with
        /// `AMitemsNext(&items, 1)`; for a fresh result's first item that is
        /// `items[0]`, which is what `AMresultItem` returns.
        pub export fn AMstackItem(
            stack: ?*?*AMstack,
            result: ?*AMresult,
            callback: ?AMstackCallback,
            data: ?*anyopaque,
        ) ?*Item {
            const kept = AMstackResult(stack, result, callback, data) orelse return null;
            return AMresultItem(kept);
        }

        /// `AMstackCallbackDataInit`. Rust: `src/utils/stack_callback_data.c:5-9`.
        ///
        /// The one place the C ABI returns memory the **caller** frees besides
        /// `AMstrdup`, which is why it also comes from `c_allocator`. The
        /// `AMexpect` macro in the header is this function with `__FILE__` and
        /// `__LINE__` filled in.
        pub export fn AMstackCallbackDataInit(
            bitmask: AMvalType,
            file: ?[*:0]const u8,
            line: c_int,
        ) ?*AMstackCallbackData {
            const data = c_allocator.create(AMstackCallbackData) catch return null;
            data.* = .{ .bitmask = bitmask, .file = file, .line = line };
            return data;
        }

        /// `AMstrdup`. Rust: `src/utils/string.c:6-46`.
        ///
        /// Returns a NUL-terminated duplicate in which every NUL byte of `str`
        /// is replaced by `nul`, or by the two-character sequence `\0` when
        /// `nul` is null (`src/utils/string.c:12`). A null `str.src` gives null
        /// (`:7-8`); an empty span gives an empty string (`:9-11`).
        ///
        /// Like `AMstackCallbackDataInit`, the caller frees the result, so it
        /// must come from the C allocator. Upstream grows the buffer with
        /// `realloc` as it finds each NUL (`:18-33`); one pass and one
        /// allocation gives the same bytes and cannot fail halfway.
        pub export fn AMstrdup(str: AMbyteSpan, nul: ?[*:0]const u8) ?[*:0]u8 {
            if (str.src == null) return null;
            const substitution: []const u8 = if (nul) |n| std.mem.span(n) else "\\0";

            const bytes = str.slice();
            var needed: usize = 0;
            for (bytes) |b| needed += if (b == 0) substitution.len else 1;

            const out = c_allocator.allocSentinel(u8, needed, 0) catch return null;
            var at: usize = 0;
            for (bytes) |b| {
                if (b == 0) {
                    @memcpy(out[at..][0..substitution.len], substitution);
                    at += substitution.len;
                } else {
                    out[at] = b;
                    at += 1;
                }
            }
            return out.ptr;
        }

        // Silence "unused type" when an instantiation only wants the exports.
        pub const _ = Self;
    };
}

// ---------------------------------------------------------------------------
// Tests.
//
// Everything outside `CAbi` is exercised here against `std.testing.allocator`,
// so a leak on any path fails the build. `CAbi` is generic and needs an item
// type, so the slice that owns the item instantiates it in the libc-linked C
// target; the report lists what that target must contain.
// ---------------------------------------------------------------------------

const t = std.testing;

// The gate `docs/STATUS.md:230` names: "enum discriminants pinned to the exact
// integers the upstream header uses". Every literal below is the value the
// reference's Rust source produces, at the line named beside it.
test "enum discriminants match the Rust" {
    // src/obj.rs:170-179
    try t.expectEqual(@as(c_int, 0), @intFromEnum(AMobjType.AM_OBJ_TYPE_DEFAULT));
    try t.expectEqual(@as(c_int, 1), @intFromEnum(AMobjType.AM_OBJ_TYPE_LIST));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(AMobjType.AM_OBJ_TYPE_MAP));
    try t.expectEqual(@as(c_int, 3), @intFromEnum(AMobjType.AM_OBJ_TYPE_TEXT));

    // src/doc/mark.rs:40-51. Non-sequential and alphabetical; do not renumber.
    try t.expectEqual(@as(c_int, 3), @intFromEnum(AMmarkExpand.AM_MARK_EXPAND_AFTER));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(AMmarkExpand.AM_MARK_EXPAND_BEFORE));
    try t.expectEqual(@as(c_int, 4), @intFromEnum(AMmarkExpand.AM_MARK_EXPAND_BOTH));
    try t.expectEqual(@as(c_int, 0), @intFromEnum(AMmarkExpand.AM_MARK_EXPAND_DEFAULT));
    try t.expectEqual(@as(c_int, 1), @intFromEnum(AMmarkExpand.AM_MARK_EXPAND_NONE));

    // src/index.rs:60-67
    try t.expectEqual(@as(c_int, 0), @intFromEnum(AMidxType.AM_IDX_TYPE_DEFAULT));
    try t.expectEqual(@as(c_int, 1), @intFromEnum(AMidxType.AM_IDX_TYPE_KEY));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(AMidxType.AM_IDX_TYPE_POS));

    // src/result.rs:476-484. Unalphabetized so that 0 is success.
    try t.expectEqual(@as(c_int, 0), @intFromEnum(AMstatus.ok));
    try t.expectEqual(@as(c_int, 1), @intFromEnum(AMstatus.error_));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(AMstatus.invalid_result));

    // src/item.rs:1296-1341. One bit per tag; 0 is reserved for DEFAULT.
    try t.expectEqual(@as(c_uint, 0), @intFromEnum(AMvalType.AM_VAL_TYPE_DEFAULT));
    try t.expectEqual(@as(c_uint, 1), @intFromEnum(AMvalType.AM_VAL_TYPE_VOID));
    try t.expectEqual(@as(c_uint, 2), @intFromEnum(AMvalType.AM_VAL_TYPE_ACTOR_ID));
    try t.expectEqual(@as(c_uint, 4), @intFromEnum(AMvalType.AM_VAL_TYPE_BOOL));
    try t.expectEqual(@as(c_uint, 8), @intFromEnum(AMvalType.AM_VAL_TYPE_BYTES));
    try t.expectEqual(@as(c_uint, 16), @intFromEnum(AMvalType.AM_VAL_TYPE_CHANGE));
    try t.expectEqual(@as(c_uint, 32), @intFromEnum(AMvalType.AM_VAL_TYPE_CHANGE_HASH));
    try t.expectEqual(@as(c_uint, 64), @intFromEnum(AMvalType.AM_VAL_TYPE_COUNTER));
    try t.expectEqual(@as(c_uint, 128), @intFromEnum(AMvalType.AM_VAL_TYPE_CURSOR));
    try t.expectEqual(@as(c_uint, 256), @intFromEnum(AMvalType.AM_VAL_TYPE_DOC));
    try t.expectEqual(@as(c_uint, 512), @intFromEnum(AMvalType.AM_VAL_TYPE_F64));
    try t.expectEqual(@as(c_uint, 1024), @intFromEnum(AMvalType.AM_VAL_TYPE_INT));
    try t.expectEqual(@as(c_uint, 2048), @intFromEnum(AMvalType.AM_VAL_TYPE_MARK));
    try t.expectEqual(@as(c_uint, 4096), @intFromEnum(AMvalType.AM_VAL_TYPE_NULL));
    try t.expectEqual(@as(c_uint, 8192), @intFromEnum(AMvalType.AM_VAL_TYPE_OBJ_TYPE));
    try t.expectEqual(@as(c_uint, 16384), @intFromEnum(AMvalType.AM_VAL_TYPE_STR));
    try t.expectEqual(@as(c_uint, 32768), @intFromEnum(AMvalType.AM_VAL_TYPE_SYNC_HAVE));
    try t.expectEqual(@as(c_uint, 65536), @intFromEnum(AMvalType.AM_VAL_TYPE_SYNC_MESSAGE));
    try t.expectEqual(@as(c_uint, 131072), @intFromEnum(AMvalType.AM_VAL_TYPE_SYNC_STATE));
    try t.expectEqual(@as(c_uint, 262144), @intFromEnum(AMvalType.AM_VAL_TYPE_TIMESTAMP));
    try t.expectEqual(@as(c_uint, 524288), @intFromEnum(AMvalType.AM_VAL_TYPE_UINT));
    try t.expectEqual(@as(c_uint, 1048576), @intFromEnum(AMvalType.AM_VAL_TYPE_UNKNOWN));

    // Every tag is distinct, which is what makes the bitmask in
    // `AMstackCallbackData` a bitmask rather than a comparison.
    var seen: std.EnumSet(AMvalType) = .initEmpty();
    for (val_type_tags) |tag| {
        try t.expect(!seen.contains(tag.v));
        seen.insert(tag.v);
    }
}

// A result over a trivial item, for the tests below. `Counted` is the item
// type the single-destructor tests use.
const R = Result(u64);
const It = Items(u64);

/// An item that records how many times it was dropped, so a test can assert
/// the destructor ran exactly once rather than merely that the allocator is
/// happy. Upstream's `AMitem` is an `Rc` (`src/item.rs:1023-1024`) and dropping
/// the owning `Vec<AMitem>` decrements each one (`:12`).
const Counted = struct {
    /// The drop counter, shared by every copy of the item.
    drops: *usize,
    value: u64,

    fn dup(self: Counted) Counted {
        return self;
    }

    fn deinit(self: Counted, gpa: Allocator) void {
        _ = gpa;
        self.drops.* += 1;
    }
};

const RCounted = Result(Counted);

test "AMbyteSpan is a borrow, and the empty span is the null one" {
    const bytes = "hello";
    const span = AMbyteSpan.of(bytes);
    try t.expectEqual(@as(usize, 5), span.count);
    try t.expectEqualStrings("hello", span.slice());

    try t.expect(AMbyteSpan.empty.src == null);
    try t.expectEqual(@as(usize, 0), AMbyteSpan.empty.count);
    try t.expectEqual(@as(usize, 0), AMbyteSpan.empty.slice().len);

    try t.expect(AMbyteSpan.eql(span, AMbyteSpan.of(bytes)));
    try t.expect(!AMbyteSpan.eql(span, AMbyteSpan.of("hellp")));
    try t.expect(!AMbyteSpan.eql(span, .empty));
    try t.expect(AMbyteSpan.eql(.empty, .empty));
}

// `test/byte_span_tests.c:15-31`, case for case.
test "AMbytes normalises a null pointer's count to zero" {
    const data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf };

    const whole = AMbytes(&data, data.len);
    try t.expectEqual(data.len, whole.count);
    try t.expectEqualSlices(u8, &data, whole.slice());

    // An empty view keeps its pointer.
    const empty = AMbytes(&data, 0);
    try t.expectEqual(@as(usize, 0), empty.count);
    try t.expectEqual(@as([*]const u8, &data), empty.src.?);

    // `AMbytes(NULL, SIZE_MAX)` must not become a wild read: the reference
    // normalises count to 0 whenever src is null (`src/byte_span.rs:179`).
    const null_span = AMbytes(null, std.math.maxInt(usize));
    try t.expectEqual(@as(usize, 0), null_span.count);
    try t.expect(null_span.src == null);
}

// `test/byte_span_tests.c:33-47`.
test "AMstr views a C string up to its NUL, and a null one is empty" {
    const s = AMstr("abcdefghijkl");
    try t.expectEqual(@as(usize, 12), s.count);
    try t.expectEqualStrings("abcdefghijkl", s.slice());

    const empty = AMstr("");
    try t.expectEqual(@as(usize, 0), empty.count);

    const null_str = AMstr(null);
    try t.expectEqual(@as(usize, 0), null_str.count);
    try t.expect(null_str.src == null);
}

// `test/byte_span_tests.c:49-80`, including the invalid-UTF-8 ordering rule
// from `src/byte_span.rs:222-225`.
test "AMstrCmp orders by length, then bytes, then case, with NULs included" {
    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr("abcdef"), AMstr("abcdefghijkl")));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(AMstr("abcdefghijkl"), AMstr("abcdefghijkl")));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("abcdefghijkl"), AMstr("abcdef")));

    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr("abcdef"), AMstr("ghijkl")));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("ghijkl"), AMstr("abcdef")));

    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr("ABCDEFGHIJKL"), AMstr("abcdefghijkl")));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(AMstr("ABCDEFGHIJKL"), AMstr("ABCDEFGHIJKL")));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("abcdefghijkl"), AMstr("ABCDEFGHIJKL")));

    const nul_str: AMbyteSpan = .{
        .src = &[_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 0, 'g', 'h', 'i', 'j', 'k', 'l' },
        .count = 13,
    };
    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr("abcdef"), nul_str));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(nul_str, nul_str));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(nul_str, AMstr("abcdef")));

    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr(""), AMstr("abcdefghijkl")));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(AMstr(""), AMstr("")));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("abcdefghijkl"), AMstr("")));

    // A null span is an empty *valid* span, so it sorts as "" does rather
    // than as an invalid one.
    try t.expectEqual(@as(c_int, -1), AMstrCmp(AMstr(null), AMstr("abcdefghijkl")));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(AMstr(null), AMstr(null)));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("abcdefghijkl"), AMstr(null)));

    // Invalid UTF-8 sorts before valid, and two invalid spans are equal.
    const invalid: AMbyteSpan = .{ .src = &[_]u8{ 0xff, 0xfe }, .count = 2 };
    try t.expectEqual(@as(c_int, -1), AMstrCmp(invalid, AMstr("abc")));
    try t.expectEqual(@as(c_int, 0), AMstrCmp(invalid, invalid));
    try t.expectEqual(@as(c_int, 1), AMstrCmp(AMstr("abc"), invalid));
}

test "a successful result is OK, has its item, and frees cleanly" {
    const gpa = t.allocator;
    const result = try boxResult(R, gpa, R.initItem(gpa, 42));
    try t.expectEqual(AMstatus.ok, R.status(result));
    try t.expectEqual(@as(usize, 1), R.size(result));
    try t.expectEqual(@as(u64, 42), result.item().?.*);
    try t.expect(R.errorMessage(result).src == null);
    result.deinit();
    gpa.destroy(result);
}

test "an error result is ERROR, has size zero, and frees cleanly" {
    const gpa = t.allocator;
    const result = try boxResult(R, gpa, R.initError(gpa, "Invalid `AMdoc*`"));
    try t.expectEqual(AMstatus.error_, R.status(result));
    try t.expectEqual(@as(usize, 0), R.size(result));
    try t.expect(result.item() == null);
    try t.expect(R.items(result) == null);
    try t.expectEqualStrings("Invalid `AMdoc*`", R.errorMessage(result).slice());
    result.deinit();
    gpa.destroy(result);
}

test "a null result is INVALID_RESULT on every accessor" {
    // The reference null-checks in every accessor (`src/result.rs:540`, `:557`,
    // `:576`, `:598`, `:620`, `:640`) and the fallthrough at `:651` is
    // `AM_STATUS_INVALID_RESULT`, so a null result is a reported condition
    // rather than a crash.
    try t.expectEqual(AMstatus.invalid_result, R.status(null));
    try t.expectEqual(@as(usize, 0), R.size(null));
    try t.expect(R.errorMessage(null).src == null);
    try t.expect(R.item(null) == null);
    try t.expect(R.items(null) == null);
}

test "a result with items reports its size, item and slice" {
    const gpa = t.allocator;
    var list: std.ArrayList(u64) = .empty;
    try list.appendSlice(gpa, &[_]u64{ 7, 8, 9 });
    const result = try boxResult(R, gpa, R.initItems(gpa, list));

    try t.expectEqual(AMstatus.ok, R.status(result));
    try t.expectEqual(@as(usize, 3), R.size(result));
    try t.expectEqual(@as(u64, 7), result.item().?.*);
    try t.expectEqualSlices(u64, &[_]u64{ 7, 8, 9 }, R.items(result).?);

    result.deinit();
    gpa.destroy(result);
}

test "an empty items result has no item and no slice" {
    const gpa = t.allocator;
    const result = try boxResult(R, gpa, R.init(gpa));
    try t.expectEqual(AMstatus.ok, R.status(result));
    try t.expectEqual(@as(usize, 0), R.size(result));
    try t.expect(result.item() == null);
    try t.expect(R.items(result) == null);
    result.deinit();
    gpa.destroy(result);
}

test "the destructor drops every item exactly once" {
    const gpa = t.allocator;
    var drops: usize = 0;
    var list: std.ArrayList(Counted) = .empty;
    try list.appendSlice(gpa, &[_]Counted{
        .{ .drops = &drops, .value = 1 },
        .{ .drops = &drops, .value = 2 },
        .{ .drops = &drops, .value = 3 },
    });
    const result = try boxResult(RCounted, gpa, RCounted.initItems(gpa, list));
    try t.expectEqual(@as(usize, 0), drops);

    result.deinit();
    gpa.destroy(result);
    // Three items, one `deinit` call each. Upstream drops a `Vec<AMitem>` the
    // same way, once per `Rc` (`src/result.rs:12`, `:559`).
    try t.expectEqual(@as(usize, 3), drops);
}

test "AMresultCat drops its inputs' items once each and its own once each" {
    const gpa = t.allocator;
    var drops: usize = 0;
    const a = try boxResult(RCounted, gpa, RCounted.initItem(gpa, .{ .drops = &drops, .value = 1 }));
    const b = try boxResult(RCounted, gpa, RCounted.initItem(gpa, .{ .drops = &drops, .value = 2 }));

    const joined = try RCounted.cat(gpa, a, b);
    try t.expectEqual(@as(usize, 0), drops);
    try t.expectEqualSlices(u64, &[_]u64{ 1, 2 }, &[_]u64{
        joined.items().?[0].value,
        joined.items().?[1].value,
    });

    // Freeing the new result drops its two items and nothing else: the
    // upstream `cloned()` chain shares the inputs rather than moving them
    // (`src/result.rs:507-511`), so the inputs are untouched by this.
    joined.deinit();
    gpa.destroy(joined);
    try t.expectEqual(@as(usize, 2), drops);

    // The inputs survive, which is the whole point of `cat`: the caller still
    // owns them and frees them exactly as it would have without the call.
    try t.expectEqual(AMstatus.ok, RCounted.status(a));
    try t.expectEqual(AMstatus.ok, RCounted.status(b));
    a.deinit();
    gpa.destroy(a);
    b.deinit();
    gpa.destroy(b);
    try t.expectEqual(@as(usize, 4), drops);
}

test "AMresultCat rejects a null pointer and an error variant, with distinct messages" {
    const gpa = t.allocator;
    const ok = try boxResult(R, gpa, R.initItem(gpa, 1));
    const err = try boxResult(R, gpa, R.initError(gpa, "boom"));

    // src/result.rs:517-521: a null pointer is "Invalid `AMresult*`".
    const from_null = try R.cat(gpa, null, ok);
    try t.expectEqual(AMstatus.error_, R.status(from_null));
    try t.expectEqualStrings("Invalid `AMresult*`", R.errorMessage(from_null).slice());
    from_null.deinit();
    gpa.destroy(from_null);

    // src/result.rs:513-515: an error variant is "Invalid `AMresult`", with
    // no star. The suite distinguishes the two, so they must not be merged.
    const from_error = try R.cat(gpa, err, ok);
    try t.expectEqual(AMstatus.error_, R.status(from_error));
    try t.expectEqualStrings("Invalid `AMresult`", R.errorMessage(from_error).slice());
    from_error.deinit();
    gpa.destroy(from_error);

    ok.deinit();
    gpa.destroy(ok);
    err.deinit();
    gpa.destroy(err);
}

test "resultFrom transfers items, frees every input, and returns null on error" {
    const gpa = t.allocator;
    const a = try boxResult(R, gpa, R.initItem(gpa, 1));
    const b = try boxResult(R, gpa, R.initItem(gpa, 2));

    // Success: a new result owning 1, 2, with both inputs already freed by
    // the call, so the caller must not touch them or free them again.
    const joined = try R.resultFrom(gpa, &[_]?*R{ a, b });
    try t.expect(joined != null);
    try t.expectEqualSlices(u64, &[_]u64{ 1, 2 }, joined.?.items().?);
    joined.?.deinit();
    gpa.destroy(joined.?);

    // Failure: one input is an error result, so nothing comes back and every
    // input is still freed. A leak on either path would be invisible without
    // the testing allocator.
    const bad = try boxResult(R, gpa, R.initError(gpa, "nope"));
    const good = try boxResult(R, gpa, R.initItem(gpa, 3));
    try t.expect(try R.resultFrom(gpa, &[_]?*R{ bad, good }) == null);

    // A null in the list is a failure too, and frees the rest.
    const last = try boxResult(R, gpa, R.initItem(gpa, 4));
    try t.expect(try R.resultFrom(gpa, &[_]?*R{ null, last }) == null);

    // An empty list is a success with no items, not a failure.
    const empty = try R.resultFrom(gpa, &[_]?*R{});
    try t.expect(empty != null);
    try t.expectEqual(AMstatus.ok, R.status(empty));
    empty.?.deinit();
    gpa.destroy(empty.?);
}

test "an error message is copied, not borrowed" {
    const gpa = t.allocator;
    var scratch: [4]u8 = "boom".*;
    const result = try boxResult(R, gpa, R.initError(gpa, &scratch));
    // Scribble over the source. The result owns its own copy, so the message
    // is unchanged; upstream's `String::from(&str)` copies too
    // (`src/result.rs:17-19`).
    @memset(&scratch, 'x');
    try t.expectEqualStrings("boom", R.errorMessage(result).slice());
    result.deinit();
    gpa.destroy(result);
}

test "an error message is truncated at a NUL, because C sees a span" {
    const gpa = t.allocator;
    const raw = [_]u8{ 'a', 0, 'b' };
    const result = try boxResult(R, gpa, R.initError(gpa, &raw));
    try t.expectEqualStrings("a", R.errorMessage(result).slice());
    result.deinit();
    gpa.destroy(result);
}

test "AMitems walks a result's own array without copying it" {
    var values = [_]u64{ 10, 11, 12 };
    var items = It.init(&values);
    try t.expectEqual(@as(usize, 3), items.len);
    try t.expectEqual(@as(?*u64, &values[0]), items.next(1));
    try t.expectEqual(@as(?*u64, &values[1]), items.next(1));
    try t.expectEqual(@as(?*u64, &values[2]), items.next(1));
    // Stopped forwards: the reference's `is_stopped` at `src/items.rs:78-81`.
    try t.expectEqual(@as(?*u64, null), items.next(1));
    // `prev` advances *before* it tests for the stop (`src/items.rs:84-87`), so
    // stepping back off the forward stop lands on the last item rather than
    // reporting the end. Upstream behaves the same way.
    try t.expectEqual(@as(?*u64, &values[2]), items.prev(1));
    try t.expectEqual(@as(?*u64, &values[1]), items.prev(1));
    try t.expectEqual(@as(?*u64, &values[0]), items.prev(1));
    try t.expectEqual(@as(?*u64, null), items.prev(1));
}

test "AMitems prev advances before it gets, so the two differ" {
    // src/items.rs:67-91: `next` gets the item and *then* advances (`:73-75`),
    // `prev` advances *first* and then gets (`:84-90`). With n == 1 that is an
    // ordinary iterator and the two agree; beyond that they do not, and from
    // the far end `prev` reports the stop where `next` reports an item.
    var values = [_]u64{ 10, 11, 12, 13 };

    var forward = It.init(&values);
    try t.expectEqual(@as(?*u64, &values[0]), forward.next(2));
    // A backwards step of 2 from a fresh cursor goes past the reverse stop, so
    // it reports the stop rather than an item.
    var backward = It.init(&values);
    try t.expectEqual(@as(?*u64, null), backward.prev(2));

    // The same cursor walked in opposite directions gives different answers.
    var rev_next = It.init(&values).reversed();
    try t.expectEqual(@as(?*u64, &values[3]), rev_next.next(1));
    var rev_prev = It.init(&values).reversed();
    try t.expectEqual(@as(?*u64, null), rev_prev.prev(1));

    // A zero step is a no-op for both (`src/items.rs:34-36`), so `prev(0)` is
    // not a peek before advancing: it is the same item `next(0)` returns.
    var peek_next = It.init(&values);
    try t.expectEqual(@as(?*u64, &values[0]), peek_next.next(0));
    try t.expectEqual(@as(isize, 0), peek_next.offset);
    var peek_prev = It.init(&values);
    try t.expectEqual(@as(?*u64, &values[0]), peek_prev.prev(0));
    try t.expectEqual(@as(isize, 0), peek_prev.offset);
}

test "AMitems reversed inverts position and direction, rewound returns to the start" {
    var values = [_]u64{ 10, 11, 12 };
    var items = It.init(&values);
    _ = items.next(1);

    // `reversed` inverts the position around the current element
    // (`src/items.rs:93-99`: `offset = -(offset + 1)`), so the reversed cursor
    // starts on the same element and then walks backwards.
    var back = items.reversed();
    try t.expect(back.offset < 0);
    try t.expectEqual(@as(?*u64, &values[1]), back.next(1));
    try t.expectEqual(@as(?*u64, &values[0]), back.next(1));

    var at_start = items.rewound();
    try t.expectEqual(@as(isize, 0), at_start.offset);
    try t.expectEqual(@as(?*u64, &values[0]), at_start.next(1));

    // A rewound reversed cursor sits at the far end, per `src/items.rs:104`.
    var rev = It.init(&values).reversed();
    try t.expectEqual(@as(isize, -1), rev.rewound().offset);
    var rewound_reversed = rev.rewound();
    try t.expectEqual(@as(?*u64, &values[2]), rewound_reversed.next(1));
    try t.expectEqual(@as(?*u64, &values[1]), rewound_reversed.next(1));
}

test "AMitemsEqual compares the sequences, not the cursors" {
    var values = [_]u64{ 10, 11, 12 };
    var a = It.init(&values);
    _ = a.next(1);
    var b = It.init(&values);
    try t.expect(a.eql(b));
    try t.expect(b.eql(a));
    try t.expect(a.reversed().eql(b));
    try t.expect(!a.eql(It.empty));
}

test "an empty or stopped AMitems never returns an out-of-range item" {
    var empty = It.empty;
    try t.expectEqual(@as(?*u64, null), empty.next(1));
    try t.expectEqual(@as(?*u64, null), empty.prev(1));
    try t.expectEqual(@as(usize, 0), empty.len);

    // A hostile jump saturates at the stop rather than wrapping into a
    // plausible index: `src/items.rs:48-52` clips to `len`.
    var values = [_]u64{ 10, 11 };
    var items = It.init(&values);
    items.advance(std.math.maxInt(isize));
    try t.expect(items.isStopped());
    try t.expectEqual(@as(?*u64, null), items.next(1));
}

test "the stack pops the top, pops a named result, and frees everything" {
    const gpa = t.allocator;
    const S = Stack(u64);
    var top: ?*S = null;
    try t.expectEqual(@as(usize, 0), S.size(top));

    const a = try boxResult(R, gpa, R.initItem(gpa, 1));
    const b = try boxResult(R, gpa, R.initItem(gpa, 2));
    try t.expectEqual(@as(?*R, a), S.push(gpa, &top, a, null, null));
    try t.expectEqual(@as(?*R, b), S.push(gpa, &top, b, null, null));
    try t.expectEqual(@as(usize, 2), S.size(top));

    // Pop the top; the caller now owns it and must free it.
    const popped = S.pop(gpa, &top, null);
    try t.expectEqual(@as(?*R, b), popped);
    try t.expectEqual(@as(usize, 1), S.size(top));
    popped.?.deinit();
    gpa.destroy(popped.?);

    // Pop a named result, which is what the reference suite does to hand a
    // result back for freeing outside the stack (`test/item_tests.c:83`).
    const named = S.pop(gpa, &top, a);
    try t.expectEqual(@as(?*R, a), named);
    try t.expectEqual(@as(usize, 0), S.size(top));
    named.?.deinit();
    gpa.destroy(named.?);

    S.freeAll(gpa, &top);
}

test "a rejected result stays on the stack, so it is freed rather than leaked" {
    const gpa = t.allocator;
    var drops: usize = 0;
    const S = Stack(Counted);
    var top: ?*S = null;

    const Reject = struct {
        fn cb(_: ?*?*S, _: ?*anyopaque) callconv(.c) bool {
            return false;
        }
    }.cb;

    const result = try boxResult(RCounted, gpa, RCounted.initItem(gpa, .{ .drops = &drops, .value = 1 }));
    try t.expectEqual(@as(?*RCounted, null), S.push(gpa, &top, result, Reject, null));
    try t.expectEqual(@as(usize, 1), S.size(top));
    try t.expectEqual(@as(usize, 0), drops);

    // `AMstackFree` releases the rejected result, which is the reference's
    // design (`src/utils/stack.c:59-63`): a rejection is reported, not leaked.
    S.freeAll(gpa, &top);
    try t.expectEqual(@as(usize, 1), drops);
}

test "an accepted result is returned and freed with the stack" {
    const gpa = t.allocator;
    var drops: usize = 0;
    const S = Stack(Counted);
    var top: ?*S = null;

    const Accept = struct {
        fn cb(s: ?*?*S, _: ?*anyopaque) callconv(.c) bool {
            const handle: *?*S = s orelse return false;
            return S.size(handle.*) == 1;
        }
    }.cb;

    const result = try boxResult(RCounted, gpa, RCounted.initItem(gpa, .{ .drops = &drops, .value = 1 }));
    try t.expectEqual(@as(?*RCounted, result), S.push(gpa, &top, result, Accept, null));

    S.freeAll(gpa, &top);
    try t.expectEqual(@as(usize, 1), drops);
}

test "pushing a null result with no callback is refused, not crashed on" {
    const gpa = t.allocator;
    const S = Stack(u64);
    var top: ?*S = null;
    // src/utils/stack.c:76-81 returns null here after logging.
    try t.expectEqual(@as(?*R, null), S.push(gpa, &top, null, null, null));
    S.freeAll(gpa, &top);
}

test "enum to string round-trips for every tag" {
    for (val_type_tags) |tag| {
        var back: AMvalType = AMvalType.AM_VAL_TYPE_UNKNOWN;
        try t.expect(AMvalTypeFromString(&back, AMvalTypeToString(@intCast(@intFromEnum(tag.v)))));
        try t.expectEqual(tag.v, back);
    }
    for (status_tags) |tag| {
        var back: AMstatus = .invalid_result;
        try t.expect(AMstatusFromString(&back, AMstatusToString(@intCast(@intFromEnum(tag.v)))));
        try t.expectEqual(tag.v, back);
    }
    for (obj_type_tags) |tag| {
        var back: AMobjType = .AM_OBJ_TYPE_TEXT;
        try t.expect(AMobjTypeFromString(&back, AMobjTypeToString(@intCast(@intFromEnum(tag.v)))));
        try t.expectEqual(tag.v, back);
    }
    for (idx_type_tags) |tag| {
        var back: AMidxType = .AM_IDX_TYPE_POS;
        try t.expect(AMidxTypeFromString(&back, AMidxTypeToString(@intCast(@intFromEnum(tag.v)))));
        try t.expectEqual(tag.v, back);
    }
    for (mark_expand_tags) |tag| {
        var back: AMmarkExpand = .AM_MARK_EXPAND_DEFAULT;
        try t.expect(AMmarkExpandFromString(&back, AMmarkExpandToString(@intCast(@intFromEnum(tag.v)))));
        try t.expectEqual(tag.v, back);
    }
}

test "an unrecognised tag is ??? and a failed parse leaves the out-parameter alone" {
    // The reference suite pre-sets the out-parameter to -1 and asserts it is
    // unchanged after a failed parse (`test/enum_string_tests.c:38-40`).
    var dest: AMvalType = .AM_VAL_TYPE_UNKNOWN;
    try t.expectEqualStrings("???", std.mem.span(tagToString(val_type_tags, 0xdeadbeef)));
    try t.expect(!AMvalTypeFromString(&dest, "???"));
    try t.expectEqual(AMvalType.AM_VAL_TYPE_UNKNOWN, dest);

    var status_dest: AMstatus = .ok;
    try t.expect(!AMstatusFromString(&status_dest, "nonsense"));
    try t.expectEqual(AMstatus.ok, status_dest);

    var obj_dest: AMobjType = .AM_OBJ_TYPE_LIST;
    try t.expect(!AMobjTypeFromString(&obj_dest, "???"));
    try t.expectEqual(AMobjType.AM_OBJ_TYPE_LIST, obj_dest);
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **`AMresultFrom` cannot be an `export fn`, so it is one C translation
//   unit and the Zig half is [`CAbi.AMresultFromList`].** Zig 0.16.0 rejects
//   `export fn f(x: c_int, a: ...)` with "expected type expression, found
//   `'...'`" — run against this toolchain, not quoted from a changelog — and
//   `zig translate-c` demotes a variadic *definition* to an `extern`
//   *declaration*, so there is no Zig spelling either. Upstream's function is
//   hand-written C for the same reason: `src/utils/result.c:5-33` is the only
//   file under `automerge-c/src/` that is not cbindgen output. This port keeps
//   it to one: [result_from.c](result_from.c) collects `count` `va_arg`s into
//   a stack array and calls `AMresultFromList`, which is [`Result.resultFrom`]
//   bound to `c_allocator`. **No decision lives in the C file** — which inputs
//   are freed, what an error variant does and what comes back are all
//   [`Result.resultFrom`]'s answers. `AMresultFromList` is exported and is
//   deliberately absent from `include/automerge.h`: that header is the
//   reference's cbindgen output and upstream has no such declaration, so a C
//   caller is given `AMresultFrom` and `AMresultCat` and nothing else.
//
// * **`AMresultFrom(2, failing, ok)` answers `NULL` here and the surviving
//   result upstream.** Upstream *assigns* `is_ok` on every iteration instead
//   of accumulating it (`src/utils/result.c:13`), so its flag is whatever the
//   **last** argument said and an early failure is silently dropped. The
//   reference's own header promises null when **any** argument is not
//   `AM_STATUS_OK` (`include/automerge-c/utils/result.h:22-24`, reproduced at
//   `include/automerge.h:511-512`), so the contract is followed here and the
//   implementation is not. The C suite's two call sites are all-OK
//   (`test/c/suite/ported_wasm/basic_tests.c:432`, `:1406`).
//
// * **`AMresultFrom(0, …)` is `NULL`; `Result.resultFrom(&.{})` is an empty
//   result.** Upstream returns `result`, which the loop never assigns
//   (`src/utils/result.c:6`, `:29-32`). The C export reproduces that. The Zig
//   function answers an empty slice with an empty result, because a caller
//   asking for a concatenation of nothing and getting `NULL` has to test for
//   the one shape that is also a failure. Both are pinned by tests.
//
// * **A negative `count` is `NULL`.** Upstream's
//   `for (int i = 0; i != count; ++i)` (`result.c:10`) runs to `INT_MAX` on a
//   negative count and frees that many garbage pointers. Refusing is the
//   answer the rest of this ABI gives a caller that breaks a precondition.
