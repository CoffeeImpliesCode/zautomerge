//! The root module of `abi_check` — a **check-only** static library, not the
//! artifact anyone consumes. The shipped library is built from
//! `src/c/root.zig` into `cabi_lib`, and that is what `zig build install` and
//! the C conformance suite link; nothing links this one except the build graph
//! itself.
//!
//! It exists for two reasons, and they are different jobs.
//!
//! **One, forcing emission.** `src/root.zig`'s `c_abi` namespace is lazy:
//! nothing pulls `c/doc.zig` or `c/sync.zig` in until a reference to them
//! appears, and an unanalyzed `export fn` emits no symbol. Being a module root
//! that names all three is enough to instantiate them. `zig test` cannot do
//! this: these are `extern "C"` exports over libc, and a test binary links no
//! libc, which is why the production root leaves `c/doc.zig` and `c/sync.zig`
//! out of its test block.
//!
//! **Two, proving the header.** That is what the rest of this file is.
//!
//! # What the C gate can and cannot see
//!
//! The C suite is compiled against `include/automerge.h` and linked against
//! the shipped `cabi_lib`, which is the *production* root. That link proves
//! one thing: every declaration in the header resolves to a symbol. It is a
//! link-level check and nothing more. Rename a struct field, reorder
//! `AMitems`, widen an enum or change a parameter's signedness, and the suite
//! still compiles, still links, and reads a cursor whose `len` and `ptr` no
//! longer agree — a silently wrong answer rather than a build failure.
//!
//! So this root does the part the link cannot: it **translates the header
//! itself**, through the same `zig translate-c` every other C translation unit
//! in this project goes through, and compares what the C side sees against
//! what the library actually is. Five things are checked, all at comptime, all
//! of them failing the build rather than a run:
//!
//! 1. **Every function the header declares exists on both sides, and the
//!    table below is checked against the header rather than trusted.** The
//!    187 names are each looked up in the translated header *and* in the
//!    four namespaces under `c_abi` that can export one, so a declaration
//!    the library does not export is a compile error. In the other direction
//!    the translated header's own declaration list is reflected, and every
//!    `AM` **function** it declares must already be one of those 187, so a
//!    new declaration cannot escape the sweep by simply not being written
//!    down here.
//!
//! 2. **Every one of those 187 declarations agrees with its export on the
//!    whole ABI signature** — arity, variadicity, calling convention, and the
//!    canonical ABI shape of every parameter and of the return type. A renamed
//!    export, a reordered parameter, an `i32` that became `u32`, a `struct`
//!    passed by pointer on one side and by value on the other: each is a
//!    compile error that names the symbol and the parameter. The
//!    canonicaliser is [`canon`], and **what it deliberately does not compare
//!    is documented on that function** — pointer nullability among them, which
//!    is why this check cannot be read as pinning it.
//!
//! 3. **Every struct whose layout the boundary pins has the same layout.**
//!    `AMbyteSpan` and `AMitems` are returned **by value** on both sides;
//!    `AMunknownValue`, `AMstack` and `AMstackCallbackData` are only ever
//!    reached through a pointer — a caller's out-parameter, a node the library
//!    allocates and hands back through `AMstackCallback`'s `AMstack **`, a
//!    `malloc` allocation from `AMstackCallbackDataInit()` — and a struct one
//!    side allocates while the other reads its fields is pinned just as hard.
//!    All five are compared on size, alignment, and every field's offset and
//!    width, and each also has a size floor, so a truncated layout cannot
//!    satisfy the equality check by shrinking both sides at once.
//!
//! 4. **Every enum discriminant equals the header's, and neither side can hold
//!    a tag the other cannot name.** All 37 tags across the five enums are
//!    compared against the constants `zig translate-c` emitted, and both lists
//!    are reflected against the side they describe rather than trusted: every
//!    `AM_OBJ_TYPE_`, `AM_MARK_EXPAND_`, `AM_IDX_TYPE_`, `AM_VAL_TYPE_` and
//!    `AM_STATUS_` constant the header translates to must already be one of
//!    the names checked here, and every field of the Zig enum one of the tags
//!    paired with one. The lowering itself is pinned as well: each Zig enum
//!    must be the size and alignment of the `c_uint` the header's enum lowers
//!    to. That is the requirement `include/automerge.h` states for
//!    `-fshort-enums`, made into a check.
//!
//! 5. **`AMresultFrom` is checked on its own terms.** It is the one variadic
//!    boundary in the ABI and the one declaration Zig 0.16.0 cannot define, so
//!    it is compared against what `src/c/result_from.c` can express and against
//!    the [`abi.AMresultFromList`] it calls, rather than skipped.
//!
//! On top of those five, a handful of signatures are pinned by **exact type
//! equality**, which is stronger than the canonical comparison where it
//! applies: the five `*FromString` exports, and the span, string and result
//! accessors whose parameter and return types are the same type on both sides.
//! **These exact-type anchors are the only place nullability is pinned at
//! all.** `canon` collapses optionality on purpose — a C `T *` can always be
//! `NULL`, so the difference between `?*T` and `*T` is a C-level precondition
//! rather than an ABI one — which means "a `?*` that became `*`" is *not*
//! caught by check 2 and would only be caught for the exports listed here.
//! That is a deliberate division, not an oversight: the exact anchors are
//! where the semantics matter, and they are the ones whose change would alter
//! what a caller may pass.
//!
//! Nothing here needs libc at run time; `@cImport` is a compile-time
//! translation. The module is still built with `link_libc`, because
//! `c/doc.zig`'s `c_allocator` is a `@compileError` without it.
//!
//! # Target
//!
//! Every check above is a *compile-time* assertion, so it holds for whatever
//! target `abi_check` is built for and says nothing about any other, and for
//! whatever enum lowering `zig translate-c` picks there. Two are genuinely
//! target-dependent and will say so by failing rather than by passing
//! quietly.
//!
//! `AMitems.offset` is `isize` in the library and `ptrdiff_t` in the header.
//! `ptrdiff_t` is not a fixed `c_long`: it reaches `@cImport` as whatever
//! this toolchain's `<stddef.h>` expands the target builtin
//! `__PTRDIFF_TYPE__` to, so naming an ABI's long width here would be a
//! guess about a builtin rather than a check. The available check is the
//! target-dependent comparison, and it is stated as its own requirement
//! below: the translated `ptrdiff_t` must be the signed pointer-width
//! integer on the target being compiled, and a target where it is not fails
//! rather than being assumed away. An enum is likewise compared by width, so
//! `-fshort-enums` in a *consumer's* build is a requirement the header
//! states and this root cannot check on its behalf.
//!
//! **What has been run, and what that is not.** This guard has been compiled
//! under native Linux on x86-64 with Zig 0.16.0, so the checks above compile
//! and agree on that target with that toolchain — a claim about this
//! configuration and about no other. It is **not** a claim that the C
//! conformance suite passes: in that same run the suite built and linked, and
//! the production runtime then crashed on an unrelated actor-remap defect, so
//! no cmocka result is being claimed here. The two artifacts answer
//! different questions and a compiling guard says nothing about the second:
//! this root proves the header and the library describe the same ABI, the
//! suite proves the built library behaves. The measured record lives in
//! `docs/STATUS.md` and `docs/plan.md`; this file states only what its own
//! compilation shows, and any failure it raises names the symbol, the
//! parameter and both shapes.
//!
//! **Build wiring.** `abi_check` is declared in `build.zig` with this file as
//! its `root_source_file`, `link_libc = true`, and `include` on its root
//! module's include path — without that path `@cImport` fails with `unable to
//! find 'automerge.h'`. `ctest_bin.step.dependOn(&abi_check.step)` is what
//! makes `zig build ctest` depend on it, so the C gate fails if any check
//! below does.

const std = @import("std");

/// The header a C consumer compiles against, translated here by the same
/// `zig translate-c` that produced `include/automerge.h`'s types in every
/// other translation unit. Nothing below is transcribed: `c.AMitems`,
/// `c.AMstackCallbackData`, `c.AM_OBJ_TYPE_MAP` and the rest are whatever the
/// C declarations actually are, so this file cannot drift from the header the
/// way a hand-copied declaration list would.
const c = @cImport({
    @cInclude("automerge.h");
    // AMexpect is a source-location macro, not an ABI entry point. Removing
    // only the macro avoids translate-c's unevaluable __FILE__ expression;
    // a real function declaration of that name would remain reflected.
    @cUndef("AMexpect");
});

/// `src/c/result.zig`: the enums, the byte span, and the ten file-level entry
/// points that need no allocator.
const result = @import("zautomerge").c_abi.result;

/// `src/c/doc.zig`: the handles, the value model and the document entry points.
/// Rust: `rust/automerge-c/src/doc.rs` and `src/doc/{list,map,mark}.rs`.
const doc = @import("zautomerge").c_abi.doc;

/// The single instantiation of `result.CAbi(AMitem)` (`src/c/doc.zig`),
/// which emits the twenty-six `AMresult*`, `AMitems*`, `AMstack*`, `AMstrdup`
/// and `AMstackCallbackDataInit` exports and declares three of the five
/// structs whose layout the boundary pins — `AMitems`, `AMstack` and
/// `AMstackCallbackData`.
const abi = doc.abi;

/// `src/c/sync.zig`: the three sync handles and their fifteen entry points.
const sync = @import("zautomerge").c_abi.sync;

/// Every namespace a `pub export fn` of this ABI can live in. The sweep below
/// looks each header declaration up in all four, which is what makes it a
/// check of the *set* rather than of three hand-picked symbols.
const namespaces = [_]type{ result, doc, abi, sync };

/// Every function `include/automerge.h` declares.
///
/// This is the header's list, not a list of what the library happens to
/// export; the two differ by exactly one entry in each direction and both
/// differences are checked explicitly below. A declaration added to the header
/// without being added here is a hole, which is why the length is pinned and
/// why a duplicate is a compile error.
const header_exports = [_][]const u8{
    "AMactorIdBytes",
    "AMactorIdCmp",
    "AMactorIdFromBytes",
    "AMactorIdFromStr",
    "AMactorIdInit",
    "AMactorIdStr",
    "AMapplyChanges",
    "AMbytes",
    "AMchangeActorId",
    "AMchangeCompress",
    "AMchangeDeps",
    "AMchangeExtraBytes",
    "AMchangeFromBytes",
    "AMchangeHash",
    "AMchangeIsEmpty",
    "AMchangeLoadDocument",
    "AMchangeMaxOp",
    "AMchangeMessage",
    "AMchangeRawBytes",
    "AMchangeSeq",
    "AMchangeSize",
    "AMchangeStartOp",
    "AMchangeTime",
    "AMclone",
    "AMcommit",
    "AMcreate",
    "AMcursorBytes",
    "AMcursorEqual",
    "AMcursorFromBytes",
    "AMcursorFromStr",
    "AMcursorStr",
    "AMemptyChange",
    "AMequal",
    "AMfork",
    "AMgenerateSyncMessage",
    "AMgetActorId",
    "AMgetChangeByHash",
    "AMgetChanges",
    "AMgetChangesAdded",
    "AMgetCursor",
    "AMgetCursorPosition",
    "AMgetHeads",
    "AMgetLastLocalChange",
    "AMgetMissingDeps",
    "AMidxTypeFromString",
    "AMidxTypeToString",
    "AMitemEqual",
    "AMitemFromBool",
    "AMitemFromBytes",
    "AMitemFromChangeHash",
    "AMitemFromCounter",
    "AMitemFromF64",
    "AMitemFromInt",
    "AMitemFromNull",
    "AMitemFromStr",
    "AMitemFromTimestamp",
    "AMitemFromUint",
    "AMitemIdxType",
    "AMitemKey",
    "AMitemObjId",
    "AMitemPos",
    "AMitemRefCount",
    "AMitemResult",
    "AMitemToActorId",
    "AMitemToBool",
    "AMitemToBytes",
    "AMitemToChange",
    "AMitemToChangeHash",
    "AMitemToCounter",
    "AMitemToCursor",
    "AMitemToDoc",
    "AMitemToF64",
    "AMitemToInt",
    "AMitemToMark",
    "AMitemToStr",
    "AMitemToSyncHave",
    "AMitemToSyncMessage",
    "AMitemToSyncState",
    "AMitemToTimestamp",
    "AMitemToUint",
    "AMitemToUnknown",
    "AMitemValType",
    "AMitemsAdvance",
    "AMitemsEqual",
    "AMitemsNext",
    "AMitemsPrev",
    "AMitemsReversed",
    "AMitemsRewound",
    "AMitemsSize",
    "AMkeys",
    "AMlistDelete",
    "AMlistGet",
    "AMlistGetAll",
    "AMlistIncrement",
    "AMlistPutBool",
    "AMlistPutBytes",
    "AMlistPutCounter",
    "AMlistPutF64",
    "AMlistPutInt",
    "AMlistPutNull",
    "AMlistPutObject",
    "AMlistPutStr",
    "AMlistPutTimestamp",
    "AMlistPutUint",
    "AMlistRange",
    "AMload",
    "AMloadIncremental",
    "AMmapDelete",
    "AMmapGet",
    "AMmapGetAll",
    "AMmapIncrement",
    "AMmapPutBool",
    "AMmapPutBytes",
    "AMmapPutCounter",
    "AMmapPutF64",
    "AMmapPutInt",
    "AMmapPutNull",
    "AMmapPutObject",
    "AMmapPutStr",
    "AMmapPutTimestamp",
    "AMmapPutUint",
    "AMmapRange",
    "AMmarkClear",
    "AMmarkCreate",
    "AMmarkEnd",
    "AMmarkExpandFromString",
    "AMmarkExpandToString",
    "AMmarkName",
    "AMmarkStart",
    "AMmarkValue",
    "AMmarks",
    "AMmerge",
    "AMobjIdActorId",
    "AMobjIdCounter",
    "AMobjIdEqual",
    "AMobjIdIndex",
    "AMobjItems",
    "AMobjObjType",
    "AMobjSize",
    "AMobjTypeFromString",
    "AMobjTypeToString",
    "AMpendingOps",
    "AMreceiveSyncMessage",
    "AMresultCat",
    "AMresultError",
    "AMresultFree",
    "AMresultFrom",
    "AMresultItem",
    "AMresultItems",
    "AMresultSize",
    "AMresultStatus",
    "AMrollback",
    "AMsave",
    "AMsaveIncremental",
    "AMsetActorId",
    "AMsplice",
    "AMspliceText",
    "AMstackCallbackDataInit",
    "AMstackFree",
    "AMstackItem",
    "AMstackItems",
    "AMstackPop",
    "AMstackResult",
    "AMstackSize",
    "AMstatusFromString",
    "AMstatusToString",
    "AMstr",
    "AMstrCmp",
    "AMstrdup",
    "AMsyncHaveLastSync",
    "AMsyncMessageDecode",
    "AMsyncMessageEncode",
    "AMsyncMessageHaves",
    "AMsyncMessageHeads",
    "AMsyncMessageNeeds",
    "AMsyncStateDecode",
    "AMsyncStateEncode",
    "AMsyncStateEqual",
    "AMsyncStateInit",
    "AMsyncStateLastSentHeads",
    "AMsyncStateSharedHeads",
    "AMsyncStateTheirHaves",
    "AMsyncStateTheirHeads",
    "AMsyncStateTheirNeeds",
    "AMtext",
    "AMvalTypeFromString",
    "AMvalTypeToString",
};

/// Fails the build unless the two C-visible structs agree on size, on
/// alignment, and on every named field's offset and width.
///
/// Size, alignment and every field's width together pin a layout; offsets
/// alone would not, because a field could move and a later one could move
/// back. The callers below each also assert a size floor, so the equality
/// check cannot be satisfied by shrinking both sides together.
fn sameLayout(
    comptime label: []const u8,
    comptime C: type,
    comptime Zig: type,
    comptime fields: []const []const u8,
) void {
    if (@sizeOf(C) != @sizeOf(Zig)) {
        @compileError(std.fmt.comptimePrint(
            "{s}: the header says @sizeOf is {d} and the library says {d}",
            .{ label, @sizeOf(C), @sizeOf(Zig) },
        ));
    }
    if (@alignOf(C) != @alignOf(Zig)) {
        @compileError(std.fmt.comptimePrint(
            "{s}: the header says @alignOf is {d} and the library says {d}",
            .{ label, @alignOf(C), @alignOf(Zig) },
        ));
    }
    inline for (fields) |field| {
        if (!@hasField(C, field)) {
            @compileError(label ++ " has no field " ++ field ++ " in the header; the header changed");
        }
        if (!@hasField(Zig, field)) {
            @compileError(label ++ " has no field " ++ field ++ " in the library; the library changed");
        }
        if (@offsetOf(C, field) != @offsetOf(Zig, field)) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s}: the header says the offset is {d} and the library says {d}",
                .{ label, field, @offsetOf(C, field), @offsetOf(Zig, field) },
            ));
        }
        if (@sizeOf(@FieldType(C, field)) != @sizeOf(@FieldType(Zig, field))) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s}: the header says the field is {d} bytes and the library says {d}",
                .{ label, field, @sizeOf(@FieldType(C, field)), @sizeOf(@FieldType(Zig, field)) },
            ));
        }
        if (!std.mem.eql(u8, canon(@FieldType(C, field)), canon(@FieldType(Zig, field)))) {
            @compileError(label ++ "." ++ field ++ ": field ABI shapes disagree");
        }
    }
}

/// Fails the build unless every tag of `Zig` has the integer the header gives
/// the same-named constant, **and** unless neither side holds a tag the other
/// cannot name.
///
/// `zig translate-c` lowers a C enum to a `c_uint` typedef plus one `c_int`
/// constant per tag, so the comparison is between two integers and does not
/// depend on how this toolchain chooses to spell the enum type itself. The
/// names are spelled out on both sides rather than derived, because the Zig
/// enum is not always named after the C constant: `AMstatus` is
/// `{ok, error_, invalid_result}` in Zig and `AM_STATUS_*` in C.
///
/// Spelling them out is only half of it, for the reason the function sweep
/// gives about `header_exports`: a list can only report what somebody
/// remembered to put in it. So both directions are pinned against what the
/// two sides actually declare, `prefix` being this enum's own prefix in the
/// header:
///
/// * every declaration the translated header makes whose name starts with
///   `prefix` and is an integer constant must already be one of
///   `header_names`, so a tag added to `include/automerge.h` without a line
///   here — the case a caller would reach through `AMvalTypeToString` and be
///   answered `"???"` for — is a compile error;
/// * every field of `Zig` must be one of `library_values`, so a tag added to
///   the library's enum alone is caught too, and each of those fields has its
///   integer compared above rather than left unchecked.
///
/// A C **alias** — a second header constant naming a tag that is already
/// listed — is the one thing allowed to outnumber the library's fields,
/// because it repeats a value that is already compared, and that is the only
/// way the two lists are allowed to be different lengths. See [`headerTag`]
/// and [`namesHave`] for the reflection itself.
fn sameDiscriminants(
    comptime label: []const u8,
    comptime prefix: []const u8,
    comptime Zig: type,
    comptime header_names: []const []const u8,
    comptime library_values: []const Zig,
) void {
    // A library tag with no name beside it would be walked past by the pairing
    // below, so the direction that cannot be an alias is checked on its own.
    if (library_values.len > header_names.len) {
        @compileError(label ++ ": the library lists " ++ num(library_values.len) ++
            " tags and the header names only " ++ num(header_names.len) ++
            ", so one of them is compared against no header constant at all");
    }
    inline for (header_names[0..library_values.len], library_values) |header_name, library_value| {
        if (!@hasDecl(c, header_name)) {
            @compileError("the header's " ++ label ++ " does not declare " ++ header_name);
        }
        const from_header: c_int = @field(c, header_name);
        const from_library: c_int = @intCast(@intFromEnum(library_value));
        if (from_header != from_library) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s}: the header says {d} and the library says {d}",
                .{ label, header_name, from_header, from_library },
            ));
        }
    }
    // The paired slices have equal lengths. Header names beyond the paired
    // prefix are checked here; only aliases of listed values are accepted.
    inline for (header_names, 0..) |header_name, i| {
        if (i < library_values.len) continue;
        if (!@hasDecl(c, header_name)) {
            @compileError("the header's " ++ label ++ " does not declare " ++ header_name);
        }
        const from_header: c_int = @intCast(@field(c, header_name));
        var aliased = false;
        inline for (library_values) |library_value| {
            const value: c_int = @intCast(@intFromEnum(library_value));
            if (from_header == value) aliased = true;
        }
        if (!aliased) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s}: the header says {d} and no listed tag has that value",
                .{ label, header_name, from_header },
            ));
        }
    }
    // The translated header's own declaration list, reflected the way
    // `header_exports` is: a tag nobody wrote down is a compile error here
    // rather than a constant this file claims to cover and does not.
    inline for (@typeInfo(c).@"struct".decls) |decl| {
        if (!headerTag(prefix, decl.name)) continue;
        if (!namesHave(header_names, decl.name)) {
            @compileError("include/automerge.h declares " ++ decl.name ++
                ", which this file does not check: add it to the " ++ label ++
                " name list in the same edit and pair it with the tag it names, " ++
                "or with the tag it aliases");
        }
    }
    // …and the library's own fields, so neither side can end up holding a tag
    // the other has no name for.
    inline for (@typeInfo(Zig).@"enum".fields) |field| {
        var paired = false;
        inline for (library_values) |library_value| {
            if (@intFromEnum(library_value) == field.value) paired = true;
        }
        if (!paired) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s}: the library has the tag and no header constant is paired with it",
                .{ label, field.name },
            ));
        }
    }
}

/// Fails the build unless a Zig enum is the size and alignment of the
/// `c_uint` the header's enum lowers to, which is the default-lowering
/// requirement `include/automerge.h` states and `-fshort-enums` breaks.
fn sameLowering(comptime label: []const u8, comptime Zig: type) void {
    if (@sizeOf(Zig) != @sizeOf(c_uint) or @alignOf(Zig) != @alignOf(c_uint)) {
        @compileError(label ++
            " is not the size and alignment of the unsigned int the header's enum lowers to");
    }
    if (@typeInfo(Zig).@"enum".tag_type != @field(c, label)) {
        @compileError(label ++ " has a tag type the header's enum cannot be");
    }
}

// ---------------------------------------------------------------------------
// Signature canonicalisation.
//
// The eleven handles this ABI passes are **opaque** in C
// (`typedef struct AMresult AMresult;`, which `zig translate-c` gives as
// `opaque {}`) and concrete in Zig. No amount of structural walking lines
// those two up, so `handles` is the table that says `?*struct_AMresult` and
// `?*Result(Item)` are the same shape. The self-linked `AMstack` uses the
// same nominal match plus the separate layout check. Other structs are
// canonicalised structurally.

/// One ABI name both spellings must agree on.
const Handle = struct {
    name: []const u8,
    c: type,
    zig: type,
};

const handles = [_]Handle{
    .{ .name = "AMresult", .c = c.AMresult, .zig = abi.AMresult },
    .{ .name = "AMitem", .c = c.AMitem, .zig = doc.AMitem },
    .{ .name = "AMdoc", .c = c.AMdoc, .zig = doc.AMdoc },
    .{ .name = "AMactorId", .c = c.AMactorId, .zig = doc.AMactorId },
    .{ .name = "AMchange", .c = c.AMchange, .zig = doc.AMchange },
    .{ .name = "AMcursor", .c = c.AMcursor, .zig = doc.AMcursor },
    .{ .name = "AMobjId", .c = c.AMobjId, .zig = doc.AMobjId },
    .{ .name = "AMmark", .c = c.AMmark, .zig = doc.AMmark },
    .{ .name = "AMsyncHave", .c = c.AMsyncHave, .zig = sync.AMsyncHave },
    .{ .name = "AMsyncMessage", .c = c.AMsyncMessage, .zig = sync.AMsyncMessage },
    .{ .name = "AMsyncState", .c = c.AMsyncState, .zig = sync.AMsyncState },
    // A public, self-linked struct rather than an opaque handle. Its complete
    // layout and field shapes are checked separately; expanding `prev` here
    // would recurse indefinitely while checking stack pointers and callbacks.
    .{ .name = "AMstack", .c = c.AMstack, .zig = abi.AMstack },
};

/// A comptime integer as text, for the diagnostics.
fn num(comptime n: anytype) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// The canonical ABI shape of a type, with **no** reference to the other
/// side. Total by construction: a shape it does not recognise is reported as
/// itself rather than as a compile error, so the mismatch is the sweep's to
/// name rather than this function's.
///
/// Five things are deliberately *not* in the shape, because the C ABI cannot
/// see them and a check that reported them would be reporting a C-level type
/// rule rather than an ABI one:
///
/// * **nullability.** `translate-c` spells a C `T *` as `[*c]T` for a mutable
///   pointee and `?*const T` for a const one, and Zig spells the same pointer
///   `?*T` or `?*const T`. `.optional` and pointee `const` both vanish here.
///   **The consequence is deliberate and worth stating plainly: this sweep
///   does not catch an optional destination becoming a required one.** A C
///   `T *` can always be `NULL`, so the distinction is a precondition a C
///   caller reads rather than an ABI fact — but it changes what a caller may
///   pass, so it is pinned where it matters by the exact-type anchors in the
///   `comptime` block below, the `*FromString` exports above all.
/// * **sentinels.** `[*:0]` and `[*]` pass and return identically.
/// * **which enum.** A C enum lowers to `c_uint`, so `AMvalType` and
///   `AMmarkExpand` are the same type to `translate-c` and no structural walk
///   can tell them apart. Semantic enum names in function parameters cannot
///   be recovered after lowering; the enum discriminants are checked separately.
///   here an enum is compared by its integer backing type.
/// * **pointer size spelling.** C, single and many pointers cross as addresses;
///   a Zig slice remains a two-word struct and is not interchangeable with one.
/// * **by-value struct padding.** A struct that crosses *inside* a
///   signature is compared field by field in declaration order, so a
///   reordered, renamed or retyped field is caught — but alignment and field
///   offsets are not part of that shape. Only the five structs passed to
///   `sameLayout` below are compared on size, alignment and every offset, so
///   a struct newly passed by value would need that call added for its layout
///   to be pinned rather than merely field-checked.
fn canon(comptime T: type) []const u8 {
    if (T == anyopaque) return "any";
    if (T == bool) return "bool";
    if (T == void) return "void";
    inline for (handles) |h| {
        if (T == h.c or T == h.zig) return "handle:" ++ h.name;
    }
    return switch (@typeInfo(T)) {
        .optional => |o| canon(o.child),
        .pointer => |p| blk: {
            // A pointer to a function *is* the function as far as an ABI is
            // concerned, so `?*const fn(...)` and `*const fn(...)` — which is
            // exactly how `AMstackCallback` and its parameters differ — give
            // the same shape.
            // `[*c]`, `*T`, `*const T` and `[*:0]const T` are all one address
            // and all take this branch; only a slice, which is two words, is
            // spelled differently.
            if (p.size == .slice) break :blk "slice(" ++ canon(p.child) ++ ")";
            if (@typeInfo(p.child) == .@"fn") break :blk "fnptr(" ++ fnShape(p.child) ++ ")";
            break :blk "ptr(" ++ canon(p.child) ++ ")";
        },
        .@"enum" => |e| canon(e.tag_type),
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ num(i.bits),
        // Width and signedness are the whole of a float's ABI too, so
        // `f32` against `f64` and `double` against `f80` are both caught here
        // rather than by falling through to `@typeName`.
        .float => |f| "f" ++ num(f.bits),
        .@"struct" => |st| blk: {
            var out: []const u8 = "struct(";
            inline for (st.fields) |f| out = out ++ f.name ++ ":" ++ canon(f.type) ++ ",";
            break :blk out ++ ")";
        },
        .@"fn" => "fnptr(" ++ fnShape(T) ++ ")",
        else => "?" ++ @typeName(T),
    };
}

/// The canonical shape of a bare function type, as a callback is declared.
fn fnShape(comptime T: type) []const u8 {
    const info = @typeInfo(T).@"fn";
    var out: []const u8 = "fn(";
    inline for (info.params) |p| out = out ++ canon(p.type.?) ++ ",";
    out = out ++ ")";
    if (info.is_var_args) out = out ++ "...";
    out = out ++ "->";
    if (info.return_type) |r| {
        out = out ++ (if (r == void) "void" else canon(r));
    } else {
        out = out ++ "noreturn";
    }
    return out ++ "+" ++ @tagName(info.calling_convention);
}

/// Whether `name` is one of the header's **function** declarations, decided by
/// the translation rather than by its spelling. Both filters are needed.
///
/// `@cImport`ing `include/automerge.h` also brings in everything `<stddef.h>`
/// and the C library's own headers declare, so the `AM` prefix is what keeps
/// the reflection to this ABI's entry points. Inside it, `AM_CHANGE_HASH_SIZE`
/// and `AM_ROOT` are macros, the eleven handles and the by-value structs are
/// typedefs, and `AMstackCallback` is a typedef for a function *pointer* —
/// which `translate-c` lowers to an optional pointer, not to a `fn`.
/// `@typeInfo` separates translated values and typedefs from `extern fn`.
/// `AMexpect` is undefined after inclusion because its source-location macro
/// is not translatable or part of the ABI; no function declaration is removed.
fn headerFunction(comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, "AM") and
        @typeInfo(@TypeOf(@field(c, name))) == .@"fn";
}

/// Whether `name` is one of an enum's own **tag constants**, decided by the
/// translation rather than by its spelling. `prefix` is the header's own
/// prefix for that enum, and the five are mutually exclusive.
///
/// `AM_ROOT` and `AM_CHANGE_HASH_SIZE` are `AM`-named macros that start with
/// none of them, and `<stddef.h>` and the C library's headers translate into
/// the same struct. `@typeInfo` is what separates a tag from a typedef, a
/// function or a callback typedef, and it accepts the one alias shape that is
/// not an enumerator of its own: `#define AM_VAL_TYPE_X AM_VAL_TYPE_Y` reaches
/// `@cImport` as a constant of the same integer type holding the same value,
/// which is exactly the case `sameDiscriminants` allows to outnumber the
/// library's fields.
fn headerTag(comptime prefix: []const u8, comptime name: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix) and
        @typeInfo(@TypeOf(@field(c, name))) == .int;
}

/// Whether `names` already contains `name`. Lengths are compared first
/// because this runs once per reflected declaration against a long table, and
/// a length mismatch is the cheap way to fail.
fn namesHave(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |entry| {
        if (entry.len == name.len and std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

/// Whether `header_exports` already contains `name` — the same question
/// `sameDiscriminants` asks of an enum's own name list, through the same
/// helper.
fn tableHas(comptime name: []const u8) bool {
    return namesHave(&header_exports, name);
}

/// The `zautomerge.c_abi` namespace that exports `name`, as a function type.
fn zigExport(comptime name: []const u8) type {
    inline for (namespaces) |ns| {
        if (@hasDecl(ns, name)) return @TypeOf(@field(ns, name));
    }
    @compileError("no namespace under zautomerge.c_abi exports " ++ name);
}

/// Fails the build unless one header declaration and one Zig export agree on
/// **arity, variadicity, calling convention, and every parameter's and the
/// return type's canonical ABI shape.**
fn sameSignature(comptime label: []const u8, comptime C: type, comptime Zig: type) void {
    const ci = @typeInfo(C).@"fn";
    const zi = @typeInfo(Zig).@"fn";
    if (ci.params.len != zi.params.len) {
        @compileError(label ++ ": the header takes " ++ num(ci.params.len) ++
            " parameters and the library takes " ++ num(zi.params.len));
    }
    if (ci.is_var_args != zi.is_var_args) {
        @compileError(label ++ ": only one side is variadic");
    }
    if (!std.meta.eql(ci.calling_convention, zi.calling_convention)) {
        @compileError(label ++ ": the header calls it " ++ @tagName(ci.calling_convention) ++
            " and the library calls it " ++ @tagName(zi.calling_convention));
    }
    inline for (ci.params, zi.params, 0..) |cp, zp, i| {
        const ct = cp.type.?;
        const zt = zp.type.?;
        if (!std.mem.eql(u8, canon(ct), canon(zt))) {
            @compileError(std.fmt.comptimePrint(
                "{s}: parameter {d} is {s} in the header and {s} in the library",
                .{ label, i, canon(ct), canon(zt) },
            ));
        }
    }
    if ((ci.return_type == null) != (zi.return_type == null)) {
        @compileError(label ++ ": one side returns nothing at all");
    }
    if (ci.return_type) |cr| {
        const zr = zi.return_type.?;
        if (!std.mem.eql(u8, canon(cr), canon(zr))) {
            @compileError(label ++ ": it returns " ++ canon(cr) ++ " in the header and " ++
                canon(zr) ++ " in the library");
        }
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    // 1. The header's declarations and the library's exports are the same set.
    //
    // Listing the header is only half of that: it proves the names written
    // down are checked, not that the list is complete. The other half is the
    // reflection further down, because a table can only ever report the
    // functions somebody remembered to put in it.
    //
    // `@compileError` rather than `assert`, so the message names the symbol.
    for (header_exports) |name| {
        if (!@hasDecl(c, name)) {
            @compileError("include/automerge.h declares " ++ name ++
                ", which @cImport did not translate: the header and this table have drifted");
        }
        var exported = false;
        for (namespaces) |ns| {
            if (@hasDecl(ns, name)) exported = true;
        }
        // `AMresultFrom` is the one declaration here with no `export fn`
        // behind it: Zig 0.16.0 cannot define a C variadic function, so the
        // symbol comes from `src/c/result_from.c` calling
        // `abi.AMresultFromList`. It is still required to be *declared* by the
        // header, which the `@hasDecl` above checks, and both halves of the
        // arrangement are pinned explicitly further down; it is only the
        // "some namespace must export this name" half it cannot satisfy.
        if (!exported and !std.mem.eql(u8, name, "AMresultFrom")) {
            @compileError("include/automerge.h declares " ++ name ++
                ", which no namespace under zautomerge.c_abi exports");
        }
    }

    // …and every one of them agrees with the library on its whole ABI
    // signature. This is the check that makes the header-parity claim true
    // rather than aspirational: arity, variadicity, calling convention, and
    // the canonical ABI shape of every parameter and of the return type, for
    // **all** of them and not a hand-picked few.
    for (header_exports) |name| {
        // `AMresultFrom` is the one declaration with no Zig counterpart at
        // all, and it is checked on its own terms just below.
        if (std.mem.eql(u8, name, "AMresultFrom")) continue;
        sameSignature(name, @TypeOf(@field(c, name)), zigExport(name));
    }

    // `AMresultFrom(int, ...)`: Zig 0.16.0 cannot define a C variadic
    // function, so the declaration is checked against what `src/c/result_from.c`
    // can actually express and against the Zig half it calls.
    {
        const ci = @typeInfo(@TypeOf(c.AMresultFrom)).@"fn";
        if (ci.params.len != 1 or !ci.is_var_args) {
            @compileError("AMresultFrom must stay `(int, ...)`");
        }
        const zi = @typeInfo(@TypeOf(abi.AMresultFromList)).@"fn";
        if (zi.params.len != 2 or zi.is_var_args) {
            @compileError("AMresultFromList must stay `(int, AMresult *const *)`");
        }
        // The count crosses as a C `int` on one side and a `c_int` on the
        // other, and the answer as a nullable `AMresult *` on both.
        if (!std.mem.eql(u8, canon(ci.params[0].type.?), canon(zi.params[0].type.?))) {
            @compileError("AMresultFrom's count parameter is " ++ canon(ci.params[0].type.?) ++
                " in the header and " ++ canon(zi.params[0].type.?) ++ " in the library");
        }
        // The C file collects the variadic arguments into `AMresult *[count]`
        // and hands that array over, so the Zig half's second parameter is a
        // pointer to an array of result pointers — two levels of pointer, one
        // of them to the opaque handle.
        if (!std.mem.eql(u8, canon(zi.params[1].type.?), "ptr(ptr(handle:AMresult))")) {
            @compileError("AMresultFromList's second parameter is " ++
                canon(zi.params[1].type.?) ++ ", not an array of AMresult *");
        }
        if (!std.mem.eql(u8, canon(ci.return_type.?), canon(zi.return_type.?))) {
            @compileError("AMresultFrom returns " ++ canon(ci.return_type.?) ++
                " in the header and " ++ canon(zi.return_type.?) ++ " in the library");
        }
    }

    // A duplicate would make the sweep weaker without making it wrong, which is
    // the worst kind of drift, so it is a build failure rather than a count.
    for (header_exports, 0..) |name, i| {
        for (header_exports[i + 1 ..]) |later| {
            if (std.mem.eql(u8, name, later)) {
                @compileError("include/automerge.h's function list repeats " ++ name);
            }
        }
    }

    // …and the table is a claim the header gets to check, not one the header
    // has to agree with. `header_exports` is transcribed by hand, so on its
    // own it proves only that the names somebody wrote down are checked: a
    // declaration added to `include/automerge.h` without a line here would
    // not be in the sweep at all, and every check below would still pass.
    // So the *translated header* is reflected instead — the same declarations
    // `zig translate-c` produced, not a second copy of the list — and every
    // `AM` function it declares is required to already be in the table.
    // `headerFunction` is what keeps the reflection to entry points: `<stddef.h>`
    // and the C library's headers translate into this same struct, and this
    // header's own macros, typedefs and callback typedef are `AM`-named too.
    if (@typeInfo(c) != .@"struct") {
        @compileError("the translated header is not a struct, so its declarations cannot be reflected");
    }
    for (@typeInfo(c).@"struct".decls) |decl| {
        if (!headerFunction(decl.name)) continue;
        if (!tableHas(decl.name)) {
            @compileError("include/automerge.h declares AM function " ++ decl.name ++
                ", which this file does not check: add it to header_exports in the same " ++
                "edit, bump the pinned count below, and give it the signature check it " ++
                "then needs");
        }
    }
    // The same reflection run the other way, so the two sets are equal rather
    // than merely covered: an entry left behind by a declaration that was
    // removed has no `fn` for `@typeInfo` to find any more. It also means a
    // reflection that found nothing at all fails here instead of passing the
    // check above vacuously.
    for (header_exports) |name| {
        if (!headerFunction(name)) {
            @compileError("header_exports lists " ++ name ++
                ", which include/automerge.h does not declare as an AM function");
        }
    }
    // The count is a tripwire for the diff, not the coverage check. Coverage
    // is the reflection above, which would catch a name the wrong way round
    // and a name that is not a function; what this adds is that adding or
    // removing a declaration has to edit *this file in the same change*, so
    // the next reader sees the header's shape move. Bump it in the same edit
    // that fixes the list.
    if (header_exports.len != 187) {
        @compileError(std.fmt.comptimePrint(
            "this file lists {d} header functions, not the 187 include/automerge.h declares; " ++
                "a declaration was added or removed and this list is stale",
            .{header_exports.len},
        ));
    }

    // The one header declaration with no `export fn` behind it, and the one
    // export with no declaration. Both are deliberate; both are pinned so a
    // later change to either is a build failure rather than a surprise.
    //
    // `AMresultFrom` is variadic and Zig 0.16.0 cannot define a C variadic
    // function — `export fn f(x: c_int, a: ...)` is a parse error and
    // `zig translate-c` demotes a variadic *definition* to an `extern`
    // *declaration` — so the symbol comes from `src/c/result_from.c`, which
    // calls `AMresultFromList`.
    if (!@hasDecl(c, "AMresultFrom")) {
        @compileError("the header no longer declares AMresultFrom");
    }
    if (!@hasDecl(abi, "AMresultFromList")) {
        @compileError("AMresultFrom is served by AMresultFromList, which src/c/result.zig no longer exports");
    }
    if (@hasDecl(c, "AMresultFromList")) {
        @compileError("AMresultFromList is deliberately absent from include/automerge.h; " ++
            "if it was added there, delete this check with it");
    }

    // 2. Every struct whose layout the boundary pins.
    sameLayout("AMbyteSpan", c.AMbyteSpan, result.AMbyteSpan, &.{ "src", "count" });
    sameLayout("AMunknownValue", c.AMunknownValue, result.AMunknownValue, &.{ "bytes", "type_code" });
    sameLayout("AMitems", c.AMitems, abi.AMitems, &.{ "len", "offset", "ptr" });
    sameLayout("AMstack", c.AMstack, abi.AMstack, &.{ "result", "prev" });
    sameLayout("AMstackCallbackData", c.AMstackCallbackData, abi.AMstackCallbackData, &.{
        "bitmask", "file", "line",
    });

    // The size floors the layout equality above cannot supply on its own. Each
    // is the sum of the fields' minimum widths, so a layout that lost a field
    // fails here rather than passing the equality check by shrinking both
    // sides together.
    if (@sizeOf(c.AMbyteSpan) < 2 * @sizeOf(usize)) {
        @compileError("AMbyteSpan is smaller than a pointer and a count");
    }
    if (@sizeOf(c.AMunknownValue) < @sizeOf(c.AMbyteSpan) + @sizeOf(u8)) {
        @compileError("AMunknownValue is smaller than an AMbyteSpan and a type code");
    }
    if (@sizeOf(c.AMitems) < @sizeOf(usize) + @sizeOf(c.ptrdiff_t) + @sizeOf(usize)) {
        @compileError("AMitems is smaller than a length, an offset and a pointer");
    }
    if (@sizeOf(c.AMstack) < 2 * @sizeOf(usize)) {
        @compileError("AMstack is smaller than a result pointer and a prev pointer");
    }
    if (@sizeOf(c.AMstackCallbackData) < @sizeOf(c_uint) + @sizeOf(usize) + @sizeOf(c_int)) {
        @compileError("AMstackCallbackData is smaller than a bitmask, a file and a line");
    }
    // `AMitems.offset` crosses as `ptrdiff_t` in the header and `isize` in
    // the library, and `sameLayout` compares the two field types. It is
    // restated as its own requirement because that comparison is the whole of
    // what can honestly be claimed about it: `ptrdiff_t` arrives as the target
    // builtin `__PTRDIFF_TYPE__` through this toolchain's `<stddef.h>`, so the
    // statement that holds is "the signed pointer-width integer on the target
    // being compiled", not a named ABI's long width. A mismatch gets its own
    // message here rather than the generic "field ABI shapes disagree".
    if (!std.mem.eql(u8, canon(@FieldType(c.AMitems, "offset")), canon(isize))) {
        @compileError("AMitems.offset is " ++ canon(@FieldType(c.AMitems, "offset")) ++
            " in the header and " ++ canon(isize) ++ " in the library: ptrdiff_t is not " ++
            "the signed pointer-width integer on this target");
    }
    // Callback signatures are checked at the functions that accept them;
    // this also checks that the public alias remains one pointer wide.
    if (@sizeOf(abi.AMstackCallback) != @sizeOf(c.AMstackCallback)) {
        @compileError("AMstackCallback is one pointer wide on one side and not on the other");
    }
    if (c.AM_CHANGE_HASH_SIZE != 32) {
        @compileError("AM_CHANGE_HASH_SIZE is not 32");
    }

    // 3. Enum discriminants and the lowering itself.
    //
    // Both directions, for the reason the function sweep above gives: a list
    // written out here only proves that the names somebody remembered are
    // checked. `sameDiscriminants` reflects the translated header's own
    // declarations and the library enum's own fields against each other, so a
    // tag added on either side without the other is a build failure rather
    // than a constant the library has no name for.
    sameLowering("AMobjType", result.AMobjType);
    sameLowering("AMmarkExpand", result.AMmarkExpand);
    sameLowering("AMidxType", result.AMidxType);
    sameLowering("AMvalType", result.AMvalType);
    sameLowering("AMstatus", result.AMstatus);

    sameDiscriminants("AMobjType", "AM_OBJ_TYPE_", result.AMobjType, &.{
        "AM_OBJ_TYPE_DEFAULT",
        "AM_OBJ_TYPE_LIST",
        "AM_OBJ_TYPE_MAP",
        "AM_OBJ_TYPE_TEXT",
    }, &.{
        result.AMobjType.AM_OBJ_TYPE_DEFAULT,
        result.AMobjType.AM_OBJ_TYPE_LIST,
        result.AMobjType.AM_OBJ_TYPE_MAP,
        result.AMobjType.AM_OBJ_TYPE_TEXT,
    });
    sameDiscriminants("AMmarkExpand", "AM_MARK_EXPAND_", result.AMmarkExpand, &.{
        "AM_MARK_EXPAND_AFTER",
        "AM_MARK_EXPAND_BEFORE",
        "AM_MARK_EXPAND_BOTH",
        "AM_MARK_EXPAND_DEFAULT",
        "AM_MARK_EXPAND_NONE",
    }, &.{
        result.AMmarkExpand.AM_MARK_EXPAND_AFTER,
        result.AMmarkExpand.AM_MARK_EXPAND_BEFORE,
        result.AMmarkExpand.AM_MARK_EXPAND_BOTH,
        result.AMmarkExpand.AM_MARK_EXPAND_DEFAULT,
        result.AMmarkExpand.AM_MARK_EXPAND_NONE,
    });
    sameDiscriminants("AMidxType", "AM_IDX_TYPE_", result.AMidxType, &.{
        "AM_IDX_TYPE_DEFAULT",
        "AM_IDX_TYPE_KEY",
        "AM_IDX_TYPE_POS",
    }, &.{
        result.AMidxType.AM_IDX_TYPE_DEFAULT,
        result.AMidxType.AM_IDX_TYPE_KEY,
        result.AMidxType.AM_IDX_TYPE_POS,
    });
    sameDiscriminants("AMvalType", "AM_VAL_TYPE_", result.AMvalType, &.{
        "AM_VAL_TYPE_ACTOR_ID",
        "AM_VAL_TYPE_BOOL",
        "AM_VAL_TYPE_BYTES",
        "AM_VAL_TYPE_CHANGE",
        "AM_VAL_TYPE_CHANGE_HASH",
        "AM_VAL_TYPE_COUNTER",
        "AM_VAL_TYPE_CURSOR",
        "AM_VAL_TYPE_DEFAULT",
        "AM_VAL_TYPE_DOC",
        "AM_VAL_TYPE_F64",
        "AM_VAL_TYPE_INT",
        "AM_VAL_TYPE_MARK",
        "AM_VAL_TYPE_NULL",
        "AM_VAL_TYPE_OBJ_TYPE",
        "AM_VAL_TYPE_STR",
        "AM_VAL_TYPE_SYNC_HAVE",
        "AM_VAL_TYPE_SYNC_MESSAGE",
        "AM_VAL_TYPE_SYNC_STATE",
        "AM_VAL_TYPE_TIMESTAMP",
        "AM_VAL_TYPE_UINT",
        "AM_VAL_TYPE_UNKNOWN",
        "AM_VAL_TYPE_VOID",
    }, &.{
        result.AMvalType.AM_VAL_TYPE_ACTOR_ID,
        result.AMvalType.AM_VAL_TYPE_BOOL,
        result.AMvalType.AM_VAL_TYPE_BYTES,
        result.AMvalType.AM_VAL_TYPE_CHANGE,
        result.AMvalType.AM_VAL_TYPE_CHANGE_HASH,
        result.AMvalType.AM_VAL_TYPE_COUNTER,
        result.AMvalType.AM_VAL_TYPE_CURSOR,
        result.AMvalType.AM_VAL_TYPE_DEFAULT,
        result.AMvalType.AM_VAL_TYPE_DOC,
        result.AMvalType.AM_VAL_TYPE_F64,
        result.AMvalType.AM_VAL_TYPE_INT,
        result.AMvalType.AM_VAL_TYPE_MARK,
        result.AMvalType.AM_VAL_TYPE_NULL,
        result.AMvalType.AM_VAL_TYPE_OBJ_TYPE,
        result.AMvalType.AM_VAL_TYPE_STR,
        result.AMvalType.AM_VAL_TYPE_SYNC_HAVE,
        result.AMvalType.AM_VAL_TYPE_SYNC_MESSAGE,
        result.AMvalType.AM_VAL_TYPE_SYNC_STATE,
        result.AMvalType.AM_VAL_TYPE_TIMESTAMP,
        result.AMvalType.AM_VAL_TYPE_UINT,
        result.AMvalType.AM_VAL_TYPE_UNKNOWN,
        result.AMvalType.AM_VAL_TYPE_VOID,
    });
    sameDiscriminants("AMstatus", "AM_STATUS_", result.AMstatus, &.{
        "AM_STATUS_OK",
        "AM_STATUS_ERROR",
        "AM_STATUS_INVALID_RESULT",
    }, &.{
        result.AMstatus.ok,
        result.AMstatus.error_,
        result.AMstatus.invalid_result,
    });

    // 4. The signatures that are exactly comparable.
    //
    // The handles are opaque on the C side and concrete on the Zig side, so a
    // whole-signature comparison is impossible for anything that takes one.
    // These are the ones where it is not: no opaque handle in the signature, or
    // a type that is literally the same on both sides.

    // The five `*FromString` exports take an **optional** destination. That is
    // the difference between reporting a `NULL` out-parameter and
    // dereferencing it (`src/c/result.zig`), and a symbol-existence check
    // cannot see it.
    std.debug.assert(@TypeOf(result.AMobjTypeFromString) ==
        fn (?*result.AMobjType, ?[*:0]const u8) callconv(.c) bool);
    std.debug.assert(@TypeOf(result.AMmarkExpandFromString) ==
        fn (?*result.AMmarkExpand, ?[*:0]const u8) callconv(.c) bool);
    std.debug.assert(@TypeOf(result.AMidxTypeFromString) ==
        fn (?*result.AMidxType, ?[*:0]const u8) callconv(.c) bool);
    std.debug.assert(@TypeOf(result.AMvalTypeFromString) ==
        fn (?*result.AMvalType, ?[*:0]const u8) callconv(.c) bool);
    std.debug.assert(@TypeOf(result.AMstatusFromString) ==
        fn (?*result.AMstatus, ?[*:0]const u8) callconv(.c) bool);

    // …and the five `*ToString` exports take the raw integer the header's enum
    // lowers to, so an out-of-range tag answers `"???"` rather than trapping.
    std.debug.assert(@TypeOf(result.AMobjTypeToString) == fn (u32) callconv(.c) [*:0]const u8);
    std.debug.assert(@TypeOf(result.AMmarkExpandToString) == fn (u32) callconv(.c) [*:0]const u8);
    std.debug.assert(@TypeOf(result.AMidxTypeToString) == fn (u32) callconv(.c) [*:0]const u8);
    std.debug.assert(@TypeOf(result.AMvalTypeToString) == fn (u32) callconv(.c) [*:0]const u8);
    std.debug.assert(@TypeOf(result.AMstatusToString) == fn (u32) callconv(.c) [*:0]const u8);

    // The span and result surface, where both spellings are the same type on
    // both sides.
    std.debug.assert(@TypeOf(result.AMbytes) ==
        fn (?[*]const u8, usize) callconv(.c) result.AMbyteSpan);
    std.debug.assert(@TypeOf(result.AMstr) ==
        fn (?[*:0]const u8) callconv(.c) result.AMbyteSpan);
    std.debug.assert(@TypeOf(result.AMstrCmp) ==
        fn (result.AMbyteSpan, result.AMbyteSpan) callconv(.c) c_int);
    std.debug.assert(@TypeOf(abi.AMresultCat) ==
        fn (?*const abi.AMresult, ?*const abi.AMresult) callconv(.c) ?*abi.AMresult);
    std.debug.assert(@TypeOf(abi.AMresultStatus) ==
        fn (?*const abi.AMresult) callconv(.c) result.AMstatus);
    std.debug.assert(@TypeOf(abi.AMresultFree) ==
        fn (?*abi.AMresult) callconv(.c) void);

    // The canonical sweep checks ABI shapes; these anchors also preserve
    // the nullable-result contract that canonicalisation deliberately omits.
    std.debug.assert(@typeInfo(@TypeOf(doc.AMcreate)).@"fn".return_type.? == ?*abi.AMresult);
    std.debug.assert(@typeInfo(@TypeOf(sync.AMsyncStateInit)).@"fn".return_type.? == ?*abi.AMresult);
    std.debug.assert(std.meta.eql(@typeInfo(@TypeOf(sync.AMsyncStateInit)).@"fn".calling_convention, .c));
}
