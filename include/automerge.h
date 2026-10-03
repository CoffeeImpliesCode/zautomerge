/**
 * \file
 * \brief All constants, functions and types in the core Automerge C API.
 *
 * \note This header is a direct transcription of the header the reference
 *       implementation generates with cbindgen 0.29
 *       (`rust/automerge-c/build.rs:10-20`, config
 *       `rust/automerge-c/cbindgen.toml:1-48`), run at commit
 *       `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd` and then post-processed by
 *       the two `file-regex-replace.cmake` passes at
 *       `rust/automerge-c/CMakeLists.txt:152-156`. The generated artifact was
 *       reproduced and diffed against the 168 `#[no_mangle]` `extern "C" fn`
 *       declarations in the reference source; every declaration below carries
 *       the `path:line` of the Rust function it mirrors.
 *
 * \warning The enum discriminants are ABI. A consumer compiled against a
 *          different numbering links to a library that answers a different
 *          question. `src/c/result.zig` pins each one against the literal in
 *          the comment beside it, so a renumbering fails this project's build
 *          rather than a consumer's.
 *
 * \warning The five enumerations below must be compiled with the **default C
 *          enum lowering**, which is what every toolchain applies unless
 *          `-fshort-enums` is given. `AMobjType`, `AMmarkExpand`, `AMidxType`
 *          and `AMstatus` then have a four-byte `unsigned int` type, which is
 *          what the library's entry points take and return. Under
 *          `-fshort-enums` those four become one byte and a one-byte enum
 *          argument leaves the rest of its register unspecified, so
 *          `AMxxxToString()` would read garbage and answer `"???"` for a tag
 *          that has a name. `AMvalType` is unaffected — its largest tag is
 *          `1 << 20` — and so is every struct in this header, because the one
 *          enum any of them embeds is `AMvalType`.
 *          `test/c/cabi.zig` pins the four-byte lowering against
 *          `zig translate-c`'s own `c_uint`.
 *
 * \section ownership Ownership
 *
 * `AMresult` is the one owning type in the *result* half of this API. A
 * function that can fail returns `AMresult *`; the caller owns it and must
 * release it with `AMresultFree()` exactly once, on every path, including the
 * error path. Every handle taken out of a result — `AMdoc *`, `AMitem *`,
 * `AMactorId const *`, `AMchange *`, `AMcursor *`, `AMobjId *`,
 * `AMsyncHave const *`, `AMsyncMessage const *`, `AMsyncState *` — is a
 * **borrow into that result** and has no destructor of its own: there is no
 * `AMdocFree`, no `AMitemFree`, no `AMobjIdFree`, no `AMchangeFree`, no
 * `AMcursorFree`, no `AMmarkFree`, and no `AMsync*Free`. Freeing the owning
 * `AMresult` invalidates every handle taken out of it, including every
 * `AMbyteSpan` view.
 *
 * **Three things in this header are not that, and each owns itself:**
 *
 * | Function | Returns | The caller releases it with |
 * | --- | --- | --- |
 * | `AMitemResult()` | a fresh one-item `AMresult` that clones the item's reference count | `AMresultFree()`, same as any other result |
 * | `AMstackCallbackDataInit()` / `AMexpect()` | an `AMstackCallbackData *` from `malloc` | `free()` |
 * | `AMstrdup()` | a NUL-terminated `char *` from `malloc` | `free()` |
 *
 * An `AMstack *` is a fourth kind of value rather than a fifth: it owns the
 * `AMresult`s pushed onto it, and `AMstackFree()` releases every one of them
 * and sets the caller's pointer to `NULL`. A result taken back out with
 * `AMstackPop()` belongs to the caller again and needs `AMresultFree()`.
 *
 * \section threads Thread confinement
 *
 * \warning **Calls from different threads must use one caller-owned global
 *          serialization boundary, even across distinct handles.** They must
 *          not overlap. This is stronger than "do not share one object between
 *          threads", and the reasons are three.
 *
 * 1. **There are no locks.** Several accessors memoise a result inside a
 *    handle whose prototype is `const`, an item's reference count is a plain
 *    integer, and there is no interior mutability over which a lock could be
 *    taken. Handing one `AMresult *`, one handle, one `AMitems`, one
 *    `AMstack` or one `AMbyteSpan` to a second thread while the first is still
 *    using it is undefined behaviour.
 *
 * 2. **Construction and randomness share one process-wide runtime.** This
 *    library cannot ask a C caller for a runtime, so it binds one at the ABI
 *    seam — the standard library's explicitly single-threaded provider, named
 *    `c_io` in `src/c/doc.zig` — and every entry point that builds a document
 *    or draws an actor id reaches it: `AMcreate()`, `AMclone()`, `AMfork()`,
 *    `AMload()`, `AMloadIncremental()`, `AMchangeLoadDocument()` and
 *    `AMactorIdInit()`. That provider is shared by the whole process and its
 *    own documentation states that it does not support concurrency, so
 *    **two independent documents in two threads are not safe either**.
 *
 * 3. **A thread-safe allocator is not a thread-safe library.** Allocation
 *    goes through `malloc` and `free`, which the C standard does require to
 *    be thread-safe — and that is exactly why this rule is about this library
 *    rather than about the heap. Reason 1 is what the heap's safety does not
 *    cover.
 *
 * In practice: hold one lock of your own around each outer call into this
 * library, through its return and any callback it invokes. An `AMstackCallback`
 * invoked by `AMstackResult()`, `AMstackItem()` or `AMstackItems()` may
 * synchronously inspect the stack and result on that same thread, including
 * advancing a local borrowed `AMitems` cursor and copying result diagnostics.
 * Such nested inspection is inside the already-held boundary:
 * **do not reacquire or release that lock**.
 * The callback must keep the stack and result live and must not change their
 * ownership or links; see the callback contract below. This is not permission
 * for general mutation, other reentrancy or cross-thread entry. Two threads may
 * use distinct handles or the same handle only under this one global boundary.
 * A caller who needs genuine concurrency should use separate processes.
 */

#ifndef AUTOMERGE_H
#define AUTOMERGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

/**
 * \defgroup enumerations Public Enumerations
 *  Symbolic names for integer constants.
 */

/**
 * \memberof AMdoc
 * \def AM_ROOT
 * \brief The root object of a document.
 */
#define AM_ROOT NULL

/**
 * \memberof AMdoc
 * \def AM_CHANGE_HASH_SIZE
 * \brief The count of bytes in a change hash.
 */
#define AM_CHANGE_HASH_SIZE 32

/**
 * \ingroup enumerations
 * \enum AMobjType
 * \brief The type of an object.
 *
 * \note Discriminants read out of `rust/automerge-c/src/obj.rs:170-179`:
 *       `Default = 0` (`:172`), `List = 1` (`:174`), `Map` (`:176`),
 *       `Text` (`:178`). `Map` and `Text` carry no explicit value and so
 *       continue from the previous variant: `2` and `3`.
 */
typedef enum AMobjType {
  /** The default tag, not a type signifier. */ AM_OBJ_TYPE_DEFAULT = 0,
  /** A list. */ AM_OBJ_TYPE_LIST = 1,
  /** A key-value map. */ AM_OBJ_TYPE_MAP = 2,
  /** A list of Unicode graphemes. */ AM_OBJ_TYPE_TEXT = 3
} AMobjType;

/**
 * \ingroup enumerations
 * \enum AMmarkExpand
 * \brief A mark's expansion mode for when bordering text is inserted.
 *
 * \note Discriminants read out of `rust/automerge-c/src/doc/mark.rs:40-51`:
 *       `After = 3` (`:42`), `Before = 2` (`:44`), `Both = 4` (`:46`),
 *       `Default = 0` (`:48`), `None = 1` (`:50`). The numbering is
 *       deliberately non-sequential and the declaration order is alphabetical
 *       rather than numeric; both are upstream's and both are ABI. Do not
 *       renumber for tidiness. `AM_MARK_EXPAND_DEFAULT` is not a valid
 *       argument to `AMmarkCreate()` or `AMmarkClear()`: the conversion
 *       rejects it with an error result (`src/doc/mark.rs:59-77`).
 */
typedef enum AMmarkExpand {
  /** Include text inserted at the end offset. */ AM_MARK_EXPAND_AFTER = 3,
  /** Include text inserted at the start offset. */ AM_MARK_EXPAND_BEFORE = 2,
  /** Include text inserted at either offset. */ AM_MARK_EXPAND_BOTH = 4,
  /** The default tag, not a mark expansion mode signifier. */
  AM_MARK_EXPAND_DEFAULT = 0,
  /** Exclude text inserted at either offset. */ AM_MARK_EXPAND_NONE = 1
} AMmarkExpand;

/**
 * \ingroup enumerations
 * \enum AMidxType
 * \brief The type of an item's index.
 *
 * \note Discriminants read out of `rust/automerge-c/src/index.rs:60-67`:
 *       `Default = 0` (`:62`), `Key` (`:64`), `Pos` (`:66`). The last two
 *       carry no explicit value and so continue from the previous variant:
 *       `1` and `2`.
 */
typedef enum AMidxType {
  /** The default tag, not a type signifier. */ AM_IDX_TYPE_DEFAULT = 0,
  /** A UTF-8 string view key. */ AM_IDX_TYPE_KEY = 1,
  /** A 64-bit unsigned integer position. */ AM_IDX_TYPE_POS = 2
} AMidxType;

/**
 * \ingroup enumerations
 * \enum AMvalType
 * \brief The type of an item's value.
 *
 * \note Discriminants read out of `rust/automerge-c/src/item.rs:1296-1341`,
 *       one `1 << n` per line: `ActorId` `:1298`, `Bool` `:1300`, `Bytes`
 *       `:1302`, `Change` `:1304`, `ChangeHash` `:1306`, `Counter` `:1308`,
 *       `Cursor` `:1310`, `Default` `:1312`, `Doc` `:1314`, `F64` `:1316`,
 *       `Int` `:1318`, `Mark` `:1320`, `Null` `:1322`, `ObjType` `:1324`,
 *       `Str` `:1326`, `SyncHave` `:1328`, `SyncMessage` `:1330`,
 *       `SyncState` `:1332`, `Timestamp` `:1334`, `Uint` `:1336`, `Unknown`
 *       `:1338`, `Void` `:1340`. Every tag is a distinct bit, so
 *       `AM_VAL_TYPE_VOID` is `1` and not `0`; `0` is reserved for
 *       `AM_VAL_TYPE_DEFAULT`. The declaration order is alphabetical, not
 *       numeric, and that order is ABI too because the enum-to-string
 *       round trip enumerates it.
 */
typedef enum AMvalType {
  AM_VAL_TYPE_DEFAULT = 0,     /**< The default tag, not a type signifier. */
  AM_VAL_TYPE_VOID = 1 << 0,   /**< A void. */
  AM_VAL_TYPE_ACTOR_ID = 1 << 1,  /**< An actor identifier value. */
  AM_VAL_TYPE_BOOL = 1 << 2,   /**< A boolean value. */
  AM_VAL_TYPE_BYTES = 1 << 3,  /**< A view onto an array of bytes value. */
  AM_VAL_TYPE_CHANGE = 1 << 4, /**< A change value. */
  AM_VAL_TYPE_CHANGE_HASH = 1 << 5, /**< A change hash value. */
  AM_VAL_TYPE_COUNTER = 1 << 6, /**< A CRDT counter value. */
  AM_VAL_TYPE_CURSOR = 1 << 7, /**< A cursor value. */
  AM_VAL_TYPE_DOC = 1 << 8,    /**< A document value. */
  AM_VAL_TYPE_F64 = 1 << 9,    /**< A 64-bit float value. */
  AM_VAL_TYPE_INT = 1 << 10,   /**< A 64-bit signed integer value. */
  AM_VAL_TYPE_MARK = 1 << 11,  /**< A mark. */
  AM_VAL_TYPE_NULL = 1 << 12,  /**< A null value. */
  AM_VAL_TYPE_OBJ_TYPE = 1 << 13, /**< An object type value. */
  AM_VAL_TYPE_STR = 1 << 14,   /**< A UTF-8 string view value. */
  AM_VAL_TYPE_SYNC_HAVE = 1 << 15,    /**< A synchronization have value. */
  AM_VAL_TYPE_SYNC_MESSAGE = 1 << 16, /**< A synchronization message value. */
  AM_VAL_TYPE_SYNC_STATE = 1 << 17,   /**< A synchronization state value. */
  AM_VAL_TYPE_TIMESTAMP = 1 << 18,    /**< A *nix timestamp (milliseconds) value. */
  AM_VAL_TYPE_UINT = 1 << 19,  /**< A 64-bit unsigned integer value. */
  AM_VAL_TYPE_UNKNOWN = 1 << 20 /**< An unknown type of value. */
} AMvalType;

/**
 * \ingroup enumerations
 * \enum AMstatus
 * \brief The status of an API call.
 *
 * \note Discriminants read out of `rust/automerge-c/src/result.rs:476-484`:
 *       `Ok` `:479`, `Error` `:481`, `InvalidResult` `:483`. None carries an
 *       explicit value, so they are `0`, `1` and `2` in declaration order. The
 *       order is unalphabetized on purpose so that `0` is success (upstream
 *       says so at `:478`).
 *
 * \note `AM_STATUS_INVALID_RESULT` means the pointer handed in was `NULL`. It
 *       does not mean the result held the wrong kind of value
 *       (`src/result.rs:638-653`).
 */
typedef enum AMstatus {
  AM_STATUS_OK = 0,             /**< Success. */
  AM_STATUS_ERROR = 1,          /**< Failure due to an error. */
  AM_STATUS_INVALID_RESULT = 2  /**< Failure due to an invalid result. */
} AMstatus;

/* -------------------------------------------------------------------------
 * Opaque handles.
 *
 * Every one of these is a Rust newtype over a value the library owns. None
 * crosses the boundary by value; the header only forward-declares them, so no
 * layout is ABI and a consumer may not `sizeof` or `memcpy` one.
 * ------------------------------------------------------------------------- */

/** \brief An actor's unique identifier. Rust: `src/actor_id.rs:22-26`. */
typedef struct AMactorId AMactorId;

/** \brief A group of operations performed by an actor. Rust: `src/change.rs:17-21`. */
typedef struct AMchange AMchange;

/**
 * \brief An identifier of a position within a list object or text object.
 *
 * Example use cases:
 * 1. Maintaining the contextual position of a user's cursor while merging
 *    remote changes.
 * 2. Indexing a sentence within a text field.
 *
 * Rust: `src/cursor.rs:24-29`.
 */
typedef struct AMcursor AMcursor;

/** \brief A JSON-like CRDT. Rust: `src/doc.rs:35-36`. */
typedef struct AMdoc AMdoc;

/** \brief An item within a result. Rust: `src/item.rs:1020-1024`, an `Rc<Item>`. */
typedef struct AMitem AMitem;

/**
 * \brief An association of out-of-bound information with a list object or text
 *        object.
 *
 * Rust: `src/doc/mark.rs:79-83`.
 */
typedef struct AMmark AMmark;

/** \brief An object's unique identifier. Rust: `src/obj.rs:31-38`. */
typedef struct AMobjId AMobjId;

/** \brief A discriminated union of result variants. Rust: `src/result.rs:9-15`. */
typedef struct AMresult AMresult;

/**
 * \brief A summary of the changes that the sender of a synchronization
 *        message already has.
 *
 * Rust: `src/sync/have.rs:6-7`.
 */
typedef struct AMsyncHave AMsyncHave;

/** \brief A synchronization message for a peer. Rust: `src/sync/message.rs:24-28`. */
typedef struct AMsyncMessage AMsyncMessage;

/** \brief The state of synchronization with a peer. Rust: `src/sync/state.rs:21-24`. */
typedef struct AMsyncState AMsyncState;

/* -------------------------------------------------------------------------
 * Structs whose layout is ABI.
 * ------------------------------------------------------------------------- */

/**
 * \brief A view onto an array of bytes.
 *
 * A span is a borrow. It never owns its bytes and it never frees them.
 * \warning `src` is only valid until the array it points into is freed.
 * \note If the span came out of an `AMitem` inside an `AMresult`, then `src` is
 *       freed when that `AMresult` is passed to `AMresultFree()`. A span may
 *       contain NUL (0) bytes; use `AMstrdup()` to obtain a NUL-terminated
 *       copy.
 *
 * Rust: `#[repr(C)] pub struct AMbyteSpan { src: *const u8, count: usize }`,
 * `src/byte_span.rs:24-35`.
 */
typedef struct AMbyteSpan {
  const uint8_t *src; /**< A pointer to the first byte of an array of bytes. */
  size_t count;       /**< The count of bytes in the array. */
} AMbyteSpan;

/**
 * \brief A value (typically for a `set` operation) whose type is unknown.
 *
 * The bytes are the raw columnar encoding, preserved verbatim so that a
 * document written by a future version of automerge round-trips through this
 * library unchanged. `type_code` is the low four bits of the value's metadata
 * word; it is not the same numbering as `AMvalType`.
 *
 * Rust: `#[repr(C)] pub struct AMunknownValue { bytes: AMbyteSpan, type_code: u8 }`,
 * `src/item.rs:20-30`.
 */
typedef struct AMunknownValue {
  AMbyteSpan bytes; /**< The value's raw bytes. */
  uint8_t type_code; /**< The value's encoded type identifier. */
} AMunknownValue;

/**
 * \brief A random-access iterator over a sequence of `AMitem` structs.
 *
 * An `AMitems` is returned **by value** and is a *copy* of a cursor over a
 * result's own item array. Two copies advance independently over the same
 * buffer, and `AMitemsEqual()` compares the underlying sequences rather than
 * the cursors (`src/items.rs:287-293`).
 *
 * This port replaces the reference's opaque `uint8_t detail[24]` blob with the
 * plain struct `Detail` it has always wrapped: `{len: usize, offset: isize,
 * ptr: *const c_void}` at `src/items.rs:10-15`. The layout, and therefore the
 * 24-byte size, is identical; only the transparency differs. See
 * `docs/plan.md` §10.
 */
typedef struct AMitems {
  size_t len;      /**< The count of items in the sequence. */
  ptrdiff_t offset; /**< The cursor position; negative means reversed. */
  const struct AMitem *ptr; /**< The items. Borrowed from the owning result. */
} AMitems;

/* -------------------------------------------------------------------------
 * Enumeration to string.
 *
 * Upstream generates these from the header itself
 * (`cmake/enum-string-functions-gen.cmake:30-77`, driven by
 * `CMakeLists.txt:233-245`), so the tag set can never drift from the enum.
 * An unrecognised tag reads back as the literal string "???"
 * (`enum-string-functions-gen.cmake:55-57`) and `AMxxxFromString()` returns
 * `false` without writing through `dest` (`:77-79`).
 *
 * **This port answers `false` for a `NULL` `dest` as well**, which is a
 * superset of the generated body rather than a change of contract: the
 * generator writes `*dest` as its first act inside the matching branch
 * (`:71-74`), so a caller forwarding an optional out-parameter would otherwise
 * dereference it rather than report the miss. `src` may be `NULL` for the
 * same reason and with the same result.
 * ------------------------------------------------------------------------- */

/**
 * \brief Gets the string representation of an `AMobjType` enum tag.
 * \param[in] tag An `AMobjType` enum tag.
 * \return The tag's name, or `"???"` for any value that is not one of the
 *         four. A static string: never freed, and outlives every handle.
 * \warning \p tag must be compiled with the default enum lowering; see the
 *          file-level warning.
 */
char const *AMobjTypeToString(AMobjType const tag);

/**
 * \brief Gets an `AMobjType` enum tag from its string representation.
 * \param[out] dest Where the tag is written, or `NULL`.
 * \param[in] src A null-terminated byte string, or `NULL`.
 * \return `true` when both pointers are non-NULL and \p src names a tag.
 *         Otherwise returns `false`; a non-NULL destination is unchanged.
 */
bool AMobjTypeFromString(AMobjType *dest, char const *const src);

/**
 * \brief Gets the string representation of an `AMmarkExpand` enum tag.
 * \param[in] tag An `AMmarkExpand` enum tag.
 * \return The tag's name, or `"???"` for any other value. A static string.
 * \warning The default enum lowering applies; see the file-level warning.
 */
char const *AMmarkExpandToString(AMmarkExpand const tag);

/**
 * \brief Gets an `AMmarkExpand` enum tag from its string representation.
 * \param[out] dest Where the tag is written, or `NULL`.
 * \param[in] src A null-terminated byte string, or `NULL`.
 * \return `true` when both pointers are non-NULL and \p src names a tag.
 *         Otherwise returns `false`; a non-NULL destination is unchanged.
 */
bool AMmarkExpandFromString(AMmarkExpand *dest, char const *const src);

/**
 * \brief Gets the string representation of an `AMidxType` enum tag.
 * \param[in] tag An `AMidxType` enum tag.
 * \return The tag's name, or `"???"` for any other value. A static string.
 * \warning The default enum lowering applies; see the file-level warning.
 */
char const *AMidxTypeToString(AMidxType const tag);

/**
 * \brief Gets an `AMidxType` enum tag from its string representation.
 * \param[out] dest Where the tag is written, or `NULL`.
 * \param[in] src A null-terminated byte string, or `NULL`.
 * \return `true` when both pointers are non-NULL and \p src names a tag.
 *         Otherwise returns `false`; a non-NULL destination is unchanged.
 */
bool AMidxTypeFromString(AMidxType *dest, char const *const src);

/**
 * \brief Gets the string representation of an `AMvalType` enum tag.
 * \param[in] tag An `AMvalType` enum tag.
 * \return The tag's name, or `"???"` for any other value. A static string.
 * \note `-fshort-enums` cannot shrink this enum — its largest tag is
 *       `1 << 20` — so it is four bytes under every lowering.
 */
char const *AMvalTypeToString(AMvalType const tag);

/**
 * \brief Gets an `AMvalType` enum tag from its string representation.
 * \param[out] dest Where the tag is written, or `NULL`.
 * \param[in] src A null-terminated byte string, or `NULL`.
 * \return `true` when both pointers are non-NULL and \p src names a tag.
 *         Otherwise returns `false`; a non-NULL destination is unchanged.
 */
bool AMvalTypeFromString(AMvalType *dest, char const *const src);

/**
 * \brief Gets the string representation of an `AMstatus` enum tag.
 * \param[in] tag An `AMstatus` enum tag.
 * \return The tag's name, or `"???"` for any other value. A static string.
 * \warning The default enum lowering applies; see the file-level warning.
 */
char const *AMstatusToString(AMstatus const tag);

/**
 * \brief Gets an `AMstatus` enum tag from its string representation.
 * \param[out] dest Where the tag is written, or `NULL`.
 * \param[in] src A null-terminated byte string, or `NULL`.
 * \return `true` when both pointers are non-NULL and \p src names a tag.
 *         Otherwise returns `false`; a non-NULL destination is unchanged.
 * \note The three tags are the whole of what `AMresultStatus()` can return.
 */
bool AMstatusFromString(AMstatus *dest, char const *const src);

/* -------------------------------------------------------------------------
 * AMbyteSpan. Rust: src/byte_span.rs.
 * ------------------------------------------------------------------------- */

/**
 * \brief Creates a view onto an array of bytes.
 *
 * \param[in] src A pointer to an array of bytes or `NULL`.
 * \param[in] count The count of bytes to view from the array pointed to by
 *                  \p src.
 * \return An `AMbyteSpan` struct.
 * \pre When `src` is not `NULL`, `count` bytes starting at it must be
 *      readable. **There is no upper bound on `count`.**
 * \post (`src` `== NULL) -> (AMbyteSpan){NULL, 0}`
 * \note `count` is *ignored* when `src` is `NULL`, not merely clamped:
 *       a null pointer normalises the whole span to `{NULL, 0}`, so
 *       `AMbytes(NULL, SIZE_MAX)` is a call the caller can make. This is
 *       upstream's `src/byte_span.rs:179` and it is what makes the
 *       precondition above conditional on `src` rather than on `count`.
 *
 * Rust: `src/byte_span.rs:176`.
 */
AMbyteSpan AMbytes(const uint8_t *src, size_t count);

/**
 * \brief Creates a view onto a C string.
 *
 * \param[in] c_str A null-terminated byte string or `NULL`.
 * \return An `AMbyteSpan` struct.
 * \pre Each byte in \p c_str encodes one UTF-8 character.
 * \post `(`\p c_str `== NULL) -> (AMbyteSpan){NULL, 0}`
 *
 * Rust: `src/byte_span.rs:194`.
 */
AMbyteSpan AMstr(const char *c_str);

/**
 * \brief Compares two UTF-8 string views lexicographically.
 *
 * \param[in] lhs A UTF-8 string view as an `AMbyteSpan` struct.
 * \param[in] rhs A UTF-8 string view as an `AMbyteSpan` struct.
 * \return Negative value if \p lhs appears before \p rhs in lexicographical
 *         order, zero if they compare equal, positive if \p lhs appears
 *         after \p rhs. A span that is not valid UTF-8 sorts before one that
 *         is, and two invalid spans compare equal.
 *
 * Rust: `src/byte_span.rs:216-227`.
 */
int AMstrCmp(AMbyteSpan lhs, AMbyteSpan rhs);

/* -------------------------------------------------------------------------
 * AMresult. Rust: src/result.rs.
 *
 * The single-destructor rule. `AMresultFree` is the only function in this
 * header that deallocates anything. Everything else hands out a raw pointer
 * obtained from `Box::into_raw` inside `to_result` (`src/result.rs:466-468`).
 * ------------------------------------------------------------------------- */

/**
 * \brief Concatenates the items from two results.
 *
 * \param[in] dest A pointer to an `AMresult` struct.
 * \param[in] src A pointer to an `AMresult` struct.
 * \return A pointer to an `AMresult` struct with the items from \p dest in
 *         their original order followed by the items from \p src in their
 *         original order, or an error result if either input is an error
 *         result or either pointer is `NULL`.
 * \pre \p dest `!= NULL`
 * \pre \p src `!= NULL`
 * \warning The returned `AMresult` struct pointer must be passed to
 *          `AMresultFree()` in order to avoid a memory leak.
 * \note Unlike `AMresultFrom()`, this function **leaves both inputs alive**.
 *          The caller still owns \p dest and \p src and must free both.
 *
 * Rust: `src/result.rs:504`. The two failure messages are distinct and both
 * are asserted by the reference suite: `"Invalid \`AMresult\`"` when an input
 * holds an error, `"Invalid \`AMresult*\`"` when a pointer was `NULL`
 * (`:513-521`).
 */
AMresult *AMresultCat(const AMresult *dest, const AMresult *src);

/**
 * \brief Gets a result's error message string.
 *
 * \param[in] result A pointer to an `AMresult` struct.
 * \return A UTF-8 string view as an `AMbyteSpan` struct, or
 *         `(AMbyteSpan){NULL, 0}` when \p result is not an error result.
 * \pre \p result `!= NULL`
 * \warning The returned span borrows from \p result and is invalidated by
 *          `AMresultFree()`.
 *
 * Rust: `src/result.rs:538`.
 */
AMbyteSpan AMresultError(const AMresult *result);

/**
 * \brief Deallocates the storage for a result, and everything borrowed from it.
 *
 * The one destructor. Calling it twice on the same pointer, or using any
 * handle obtained from the result afterwards, is undefined behaviour.
 *
 * \param[in] result A pointer to an `AMresult` struct, or `NULL`. A `NULL`
 *                   argument is a no-op, not an error.
 *
 * Rust: `src/result.rs:557-562`, which null-checks before
 * `Box::from_raw(..)` and dropping.
 */
void AMresultFree(AMresult *result);

/**
 * \brief Gets a result's first item.
 *
 * \param[in] result A pointer to an `AMresult` struct.
 * \return A pointer to an `AMitem` struct, or `NULL` when \p result is an
 *         error result or holds no items.
 * \pre \p result `!= NULL`
 * \warning The returned pointer borrows from \p result. It is invalidated by
 *          `AMresultFree()` and by nothing else. In particular
 *          `AMresultCat()` **does not** invalidate it: `cat` takes two
 *          `const AMresult *` and no `AMitems` at all, and it leaves both
 *          inputs alive, so an `AMitem *` taken from either one is still good
 *          afterwards. (`AMresultFrom()` is the function that consumes its
 *          inputs, and it frees them.)
 * \warning Two `AMitem *` values taken from the same result alias the same
 *          storage, which is why `AMitemRefCount()` exists and why
 *          `AMitemResult()` exists: it clones the reference count into a
 *          fresh result so the item can outlive the collection.
 *
 * Rust: `src/result.rs:575-584`.
 */
AMitem *AMresultItem(AMresult *result);

/**
 * \brief Gets a result's items.
 *
 * \param[in] result A pointer to an `AMresult` struct.
 * \return An `AMitems` struct over the result's own item array, or a
 *         zero-valued `AMitems` when \p result is an error result or holds no
 *         items.
 * \pre \p result `!= NULL`
 * \warning The returned struct borrows from \p result and is invalidated by
 *          `AMresultFree()`.
 *
 * Rust: `src/result.rs:597-606`.
 */
AMitems AMresultItems(AMresult *result);

/**
 * \brief Gets the size of a result.
 *
 * \param[in] result A pointer to an `AMresult` struct.
 * \return The count of items within \p result. An error result has size zero;
 *         use `AMresultStatus()` to tell the two apart.
 * \pre \p result `!= NULL`
 *
 * Rust: `src/result.rs:619-626`.
 */
size_t AMresultSize(const AMresult *result);

/**
 * \brief Gets the status code of a result.
 *
 * \param[in] result A pointer to an `AMresult` struct, or `NULL`.
 * \return `AM_STATUS_INVALID_RESULT` when \p result is `NULL`,
 *         `AM_STATUS_ERROR` when it holds an error message, and
 *         `AM_STATUS_OK` otherwise.
 *
 * Rust: `src/result.rs:639-653`.
 */
AMstatus AMresultStatus(const AMresult *result);

/**
 * \brief Transfers the items within an arbitrary list of results into a new
 *        result in their order of specification.
 *
 * \param[in] count The count of subsequent arguments.
 * \param[in] ... A \p count list of pointers, each of which is an `AMresult`
 *                struct pointer whose items will be transferred out of it and
 *                which is subsequently freed.
 * \return A pointer to an `AMresult` struct, or `NULL`. **`NULL` means
 *         either of two things and the two cannot be told apart:**
 *
 *         * `\p count <= 0`. An empty concatenation is not a result. This is
 *           upstream's own answer — `result` starts as `NULL` and the loop
 *           never runs (`src/utils/result.c:6`, `:29-32`) — and the header of
 *           the reference utility layer says nothing else.
 *         * An argument whose status was not `AM_STATUS_OK`, per the `\post`
 *           below.
 *
 *         A caller that treats `NULL` as "no items" therefore swallows the
 *         second case, and a caller that treats it as a failure reports one
 *         for the first. **Guard on `\p count` before calling**, which is the
 *         only way to tell them apart.
 * \pre `\p count >= 0`. A negative count is `NULL`, where upstream's loop
 *      (`src/utils/result.c:10`) would run until the index wraps and read that
 *      many garbage pointers.
 * \pre `\p count` bounds the stack space the implementation needs: the port's
 *      `src/c/result_from.c` collects the arguments into a `AMresult *[count]`
 *      on the stack, so a `count` in the millions is a stack overflow before
 *      it is anything else. Upstream folds as it goes (`result.c:12-25`) and
 *      has no such bound, so a value that is comfortable there is not
 *      necessarily comfortable here.
 * \pre `∀𝑥 ∈` \p ... `, AMresultStatus(𝑥) == AM_STATUS_OK`
 * \post `(∃𝑥 ∈` \p ... `, AMresultStatus(𝑥) != AM_STATUS_OK) -> NULL`
 * \attention All `AMresult` struct pointer arguments are passed to
 *            `AMresultFree()` regardless of success. Use `AMresultCat()`
 *            instead if you wish to free them yourself. **This is the exact
 *            opposite of `AMresultCat()`'s contract, which consumes nothing.**
 * \warning The returned `AMresult` struct pointer must be passed to
 *          `AMresultFree()` in order to avoid a memory leak.
 *
 * \note This is the one function in the surface that is variadic, and it is
 *       the one function whose ownership contract is the *opposite* of
 *       `AMresultCat()`'s. Zig cannot define a C variadic function —
 *       `export fn f(x: c_int, a: ...)` is a parse error and `zig translate-c`
 *       demotes a variadic *definition* to an `extern` *declaration* — so this
 *       symbol comes from the one hand-written C file in the port,
 *       `src/c/result_from.c`, which is upstream's arrangement as well. That
 *       file only collects the arguments; it calls `AMresultFromList` in
 *       `src/c/result.zig`, which is `Result.resultFrom` bound to
 *       `std.heap.c_allocator`, and every decision this function makes is
 *       made there.
 *
 * Rust: the hand-written C at `src/utils/result.c:5-33`, declared at
 * `include/automerge-c/utils/result.h:28`.
 */
AMresult *AMresultFrom(int count, ...);

/* -------------------------------------------------------------------------
 * AMactorId. Rust: src/actor_id.rs.
 * ------------------------------------------------------------------------- */

/** \brief Gets the value of an actor identifier as an array of bytes. Rust: `src/actor_id.rs:71`. */
AMbyteSpan AMactorIdBytes(const AMactorId *actor_id);

/** \brief Compares two actor identifiers. Rust: `src/actor_id.rs:94`. */
int AMactorIdCmp(const AMactorId *actor_id1, const AMactorId *actor_id2);

/**
 * \brief Allocates a new actor identifier and initializes it from a random
 *        UUID value.
 * \return A pointer to an `AMresult` struct with an `AM_VAL_TYPE_ACTOR_ID` item.
 * \warning Must be passed to `AMresultFree()`.
 *
 * Rust: `src/actor_id.rs:118`.
 */
AMresult *AMactorIdInit(void);

/** \brief Allocates a new actor identifier from an array of bytes. Rust: `src/actor_id.rs:140`. */
AMresult *AMactorIdFromBytes(const uint8_t *src, size_t count);

/** \brief Allocates a new actor identifier from a hexadecimal string view. Rust: `src/actor_id.rs:164`. */
AMresult *AMactorIdFromStr(AMbyteSpan value);

/**
 * \brief Gets an actor identifier as a UTF-8 hexadecimal string view.
 * \param[in] actor_id An `AMactorId const *`, or `NULL`.
 * \return Twice as many bytes as the actor id has, lower-case hexadecimal, or
 *         `(AMbyteSpan){NULL, 0}` when \p actor_id is `NULL`.
 * \warning The span borrows the handle and is invalidated by
 *          `AMresultFree()`. The same bytes and the same pointer come back on
 *          every call.
 * Rust: `src/actor_id.rs:188`.
 */
AMbyteSpan AMactorIdStr(const AMactorId *actor_id);

/* -------------------------------------------------------------------------
 * AMchange. Rust: src/change.rs.
 *
 * **A `NULL` `AMchange *` is not an error here.** Upstream dereferences the
 * handle inside a `match … { None => <this value> }` arm for every one of
 * these, and the value in the arm is what the `\return` lines below record:
 * the sentinel `UINT64_MAX` / `INT64_MAX`, the zero span, `0`, `true`. They
 * are upstream's own answers (`src/change.rs:241`, `:261`, `:279`, `:298`,
 * `:316`, `:335`), kept because a caller that already checks its handle sees
 * no difference — but a caller that *forwards* an optional change cannot tell
 * a real `UINT64_MAX` operation id from the one that means "no change", and
 * **that is the caller's to resolve by checking the handle first.**
 * ------------------------------------------------------------------------- */

/** \brief Gets the first referenced actor identifier in a change. Rust: `src/change.rs:81`. */
AMresult *AMchangeActorId(const AMchange *change);

/** \brief Compresses the raw bytes of a change, in place. Rust: `src/change.rs:98`. */
void AMchangeCompress(AMchange *change);

/** \brief Gets the dependencies of a change. Rust: `src/change.rs:117`. */
AMresult *AMchangeDeps(const AMchange *change);

/**
 * \brief Gets a change's extra bytes (the author footer).
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The footer as a view into \p change, or `(AMbyteSpan){NULL, 0}`
 *         when \p change is `NULL`.
 * \warning The span borrows from \p change and dies with `AMresultFree()`.
 * Rust: `src/change.rs:135`.
 */
AMbyteSpan AMchangeExtraBytes(const AMchange *change);

/** \brief Loads a change from an array of bytes. Rust: `src/change.rs:160`. */
AMresult *AMchangeFromBytes(const uint8_t *src, size_t count);

/** \brief Gets a change's hash. Rust: `src/change.rs:176`. */
AMbyteSpan AMchangeHash(const AMchange *change);

/**
 * \brief Tests whether a change contains no operations.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return `true` for a change with no operations, **and `true` for `NULL`**:
 *         there is nothing there, and nothing there is empty.
 * Rust: `src/change.rs:194`.
 */
bool AMchangeIsEmpty(const AMchange *change);

/** \brief Loads a document containing exactly one change. Rust: `src/change.rs:219`. */
AMresult *AMchangeLoadDocument(const uint8_t *src, size_t count);

/**
 * \brief Gets a change's maximum operation id.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The highest operation id in \p change, or `UINT64_MAX` when \p
 *         change is `NULL`.
 * Rust: `src/change.rs:237`.
 */
uint64_t AMchangeMaxOp(const AMchange *change);

/**
 * \brief Gets a change's message.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The message as a view into \p change, or `(AMbyteSpan){NULL, 0}`
 *         when \p change is `NULL`. A change with no message and one with an
 *         empty message are the same answer.
 * \warning The span borrows from \p change and dies with `AMresultFree()`.
 * Rust: `src/change.rs:257`.
 */
AMbyteSpan AMchangeMessage(const AMchange *change);

/**
 * \brief Gets a change's sequence number.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The change's index in its actor's change chunk — numbered from
 *         **one**, not zero — or `UINT64_MAX` when \p change is `NULL`.
 * Rust: `src/change.rs:275`.
 */
uint64_t AMchangeSeq(const AMchange *change);

/**
 * \brief Gets the count of operations in a change.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The count of operations, or `0` when \p change is `NULL`.
 * Rust: `src/change.rs:294`.
 */
size_t AMchangeSize(const AMchange *change);

/**
 * \brief Gets a change's starting operation id.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The lowest operation id in \p change, or `UINT64_MAX` when \p
 *         change is `NULL`.
 * Rust: `src/change.rs:312`.
 */
uint64_t AMchangeStartOp(const AMchange *change);

/**
 * \brief Gets a change's timestamp, in *nix milliseconds.
 * \param[in] change An `AMchange *`, or `NULL`.
 * \return The time passed to `AMcommit()`, or `INT64_MAX` when \p change is
 *         `NULL`.
 * Rust: `src/change.rs:331`.
 */
int64_t AMchangeTime(const AMchange *change);

/** \brief Gets a change's raw bytes. Rust: `src/change.rs:350`. */
AMbyteSpan AMchangeRawBytes(const AMchange *change);

/* -------------------------------------------------------------------------
 * AMcursor. Rust: src/cursor.rs.
 * ------------------------------------------------------------------------- */

/** \brief Gets a cursor as an array of bytes. Rust: `src/cursor.rs:79`. */
AMbyteSpan AMcursorBytes(const AMcursor *cursor);

/** \brief Tests two cursors for equality. Rust: `src/cursor.rs:101`. */
bool AMcursorEqual(const AMcursor *cursor1, const AMcursor *cursor2);

/** \brief Loads a cursor from an array of bytes. Rust: `src/cursor.rs:126`. */
AMresult *AMcursorFromBytes(const uint8_t *src, size_t count);

/** \brief Loads a cursor from a hexadecimal string view. Rust: `src/cursor.rs:148`. */
AMresult *AMcursorFromStr(AMbyteSpan value);

/** \brief Gets a cursor as a hexadecimal string view. Rust: `src/cursor.rs:163`. */
AMbyteSpan AMcursorStr(const AMcursor *cursor);

/* -------------------------------------------------------------------------
 * AMobjId. Rust: src/obj.rs.
 * ------------------------------------------------------------------------- */

/**
 * \brief Gets an object id's actor id.
 * \return A pointer owned by \p obj_id, or `NULL` for the root object, which
 *         has no actor.
 * \note The returned pointer is memoised inside \p obj_id, so two calls
 *       return the same pointer (`src/obj.rs:41-60`).
 *
 * Rust: `src/obj.rs:89`.
 */
const AMactorId *AMobjIdActorId(const AMobjId *obj_id);

/** \brief Gets an object id's counter, or `UINT64_MAX` for `NULL`. Rust: `src/obj.rs:107`. */
uint64_t AMobjIdCounter(const AMobjId *obj_id);

/** \brief Tests two object ids for equality. Rust: `src/obj.rs:133`. */
bool AMobjIdEqual(const AMobjId *obj_id1, const AMobjId *obj_id2);

/** \brief Gets an object id's index, `0` for the root and `SIZE_MAX` for `NULL`. Rust: `src/obj.rs:151`. */
size_t AMobjIdIndex(const AMobjId *obj_id);

/* -------------------------------------------------------------------------
 * AMitem. Rust: src/item.rs.
 *
 * The type check is deferred to the caller. `AMresult` carries no tag of its
 * own: every function that can return more than one kind of value returns
 * items, and the caller reads `AMitemValType()` to find out what it got. That
 * is why `AMstackCallbackData.bitmask` exists, and why the reference compares
 * a tag with the mask using `==` rather than a bitwise and
 * (`examples/quickstart.c:110-115`) even though the field is named `bitmask`.
 * ------------------------------------------------------------------------- */

/** \brief Tests two items for value equality. Rust: `src/item.rs:1415`. */
bool AMitemEqual(const AMitem *item1, const AMitem *item2);

/** \brief Creates a standalone boolean item. Rust: `src/item.rs:1430`. */
AMresult *AMitemFromBool(bool value);

/** \brief Creates a standalone bytes item. Rust: `src/item.rs:1451`. */
AMresult *AMitemFromBytes(const uint8_t *src, size_t count);

/** \brief Creates a standalone change-hash item. Rust: `src/item.rs:1470`. */
AMresult *AMitemFromChangeHash(AMbyteSpan value);

/** \brief Creates a standalone counter item. Rust: `src/item.rs:1482`. */
AMresult *AMitemFromCounter(int64_t value);

/** \brief Creates a standalone 64-bit float item. Rust: `src/item.rs:1494`. */
AMresult *AMitemFromF64(double value);

/** \brief Creates a standalone 64-bit signed integer item. Rust: `src/item.rs:1506`. */
AMresult *AMitemFromInt(int64_t value);

/** \brief Creates a standalone null item. Rust: `src/item.rs:1517`. */
AMresult *AMitemFromNull(void);

/** \brief Creates a standalone string item. Rust: `src/item.rs:1535`. */
AMresult *AMitemFromStr(AMbyteSpan value);

/** \brief Creates a standalone timestamp item. Rust: `src/item.rs:1548`. */
AMresult *AMitemFromTimestamp(int64_t value);

/** \brief Creates a standalone 64-bit unsigned integer item. Rust: `src/item.rs:1560`. */
AMresult *AMitemFromUint(uint64_t value);

/** \brief Gets an item's index type tag. Rust: `src/item.rs:1576`. */
AMidxType AMitemIdxType(const AMitem *item);

/** \brief Gets an item's object id, or `NULL` if it has none. Rust: `src/item.rs:1595`. */
const AMobjId *AMitemObjId(const AMitem *item);

/** \brief Gets an item's key, if it is a key-indexed item. Rust: `src/item.rs:1617`. */
bool AMitemKey(const AMitem *item, AMbyteSpan *value);

/** \brief Gets an item's position, if it is a position-indexed item. Rust: `src/item.rs:1644`. */
bool AMitemPos(const AMitem *item, size_t *value);

/**
 * \brief Gets an item's strong reference count, or `0` for `NULL`.
 *
 * Three accessors take a **mutable** `AMitem *` because they need a unique
 * handle and use `Rc::get_mut` internally: `AMitemToChange`, `AMitemToDoc` and
 * `AMitemToSyncState` (`src/item.rs:1186, :1206, :1242`). They return `false`,
 * not an error, when the count is greater than one. `AMitemResult()` is the
 * escape hatch: it clones the count into a fresh result so the item can
 * outlive the collection (`src/item.rs:1691-1695`).
 *
 * Rust: `src/item.rs:1670`.
 */
size_t AMitemRefCount(const AMitem *item);

/** \brief Clones an item into a fresh one-item result the caller then owns. Rust: `src/item.rs:1691`. */
AMresult *AMitemResult(const AMitem *item);

bool AMitemToActorId(const AMitem *item, const AMactorId **value);      /**< Rust: `src/item.rs:1711`. */
bool AMitemToBool(const AMitem *item, bool *value);                     /**< Rust: `src/item.rs:1739`. */
bool AMitemToBytes(const AMitem *item, AMbyteSpan *value);              /**< Rust: `src/item.rs:1764`. */
bool AMitemToChange(AMitem *item, AMchange **value);                    /**< Rust: `src/item.rs:1789`. Needs a unique item. */
bool AMitemToChangeHash(const AMitem *item, AMbyteSpan *value);         /**< Rust: `src/item.rs:1814`. */
bool AMitemToCounter(const AMitem *item, int64_t *value);               /**< Rust: `src/item.rs:1839`. */
bool AMitemToCursor(const AMitem *item, const AMcursor **value);        /**< Rust: `src/item.rs:1864`. */
bool AMitemToDoc(AMitem *item, AMdoc **value);                          /**< Rust: `src/item.rs:1889`. Needs a unique item. */
bool AMitemToF64(const AMitem *item, double *value);                    /**< Rust: `src/item.rs:1914`. */
bool AMitemToInt(const AMitem *item, int64_t *value);                   /**< Rust: `src/item.rs:1939`. */
bool AMitemToMark(const AMitem *item, const AMmark **value);            /**< Rust: `src/item.rs:1964`. */
bool AMitemToStr(const AMitem *item, AMbyteSpan *value);                /**< Rust: `src/item.rs:1989`. */
bool AMitemToSyncHave(const AMitem *item, const AMsyncHave **value);    /**< Rust: `src/item.rs:2014`. */
bool AMitemToSyncMessage(const AMitem *item, const AMsyncMessage **value); /**< Rust: `src/item.rs:2042`. */
bool AMitemToSyncState(AMitem *item, AMsyncState **value);              /**< Rust: `src/item.rs:2070`. Needs a unique item. */
bool AMitemToTimestamp(const AMitem *item, int64_t *value);             /**< Rust: `src/item.rs:2098`. */
bool AMitemToUint(const AMitem *item, uint64_t *value);                 /**< Rust: `src/item.rs:2123`. */
bool AMitemToUnknown(const AMitem *item, AMunknownValue *value);        /**< Rust: `src/item.rs:2148`. */

/** \brief Gets an item's value type tag. Rust: `src/item.rs:2172`. */
AMvalType AMitemValType(const AMitem *item);

/* -------------------------------------------------------------------------
 * AMitems. Rust: src/items.rs.
 * ------------------------------------------------------------------------- */

/** \brief Advances a cursor, clamped to its stop. Rust: `src/items.rs:266`. */
void AMitemsAdvance(AMitems *items, ptrdiff_t n);

/** \brief Tests two cursors' underlying sequences for equality, ignoring position. Rust: `src/items.rs:288`. */
bool AMitemsEqual(const AMitems *items1, const AMitems *items2);

/** \brief Gets the item at the cursor, then advances it. Rust: `src/items.rs:312`. */
AMitem *AMitemsNext(AMitems *items, ptrdiff_t n);

/** \brief Advances the cursor, then gets the item. Rust: `src/items.rs:338`. */
AMitem *AMitemsPrev(AMitems *items, ptrdiff_t n);

/** \brief Gets the count of items in a cursor's underlying sequence. Rust: `src/items.rs:358`. */
size_t AMitemsSize(const AMitems *items);

/** \brief Copies a cursor, inverting its position and direction. Rust: `src/items.rs:377`. */
AMitems AMitemsReversed(const AMitems *items);

/** \brief Copies a cursor, rewinding it to the start of its direction. Rust: `src/items.rs:396`. */
AMitems AMitemsRewound(const AMitems *items);

/* -------------------------------------------------------------------------
 * AMdoc. Rust: src/doc.rs.
 * ------------------------------------------------------------------------- */

/** \brief Applies a sequence of changes to a document. Rust: `src/doc.rs:85`. */
AMresult *AMapplyChanges(AMdoc *doc, const AMitems *items);

/** \brief Deep-copies a document. Rust: `src/doc.rs:108`. */
AMresult *AMclone(const AMdoc *doc);

/** \brief Creates a document, with a random actor id when \p actor_id is `NULL`. Rust: `src/doc.rs:126`. */
AMresult *AMcreate(const AMactorId *actor_id);

/** \brief Commits the document's pending operations. Rust: `src/doc.rs:151`. */
AMresult *AMcommit(AMdoc *doc, AMbyteSpan message, const int64_t *timestamp);

/** \brief Emits an empty change, or a change carrying the pending operations. Rust: `src/doc.rs:194`. */
AMresult *AMemptyChange(AMdoc *doc, AMbyteSpan message, const int64_t *timestamp);

/**
 * \brief Tests two documents for equality.
 * \note This **commits the pending operations of both documents** as a side
 *       effect, because `is_equal_to` closes the open transaction
 *       (`src/doc.rs:41-45`).
 *
 * Rust: `src/doc.rs:225`.
 */
bool AMequal(AMdoc *doc1, AMdoc *doc2);

/** \brief Forks a document at the given heads, or at the current heads when `NULL`. Rust: `src/doc.rs:249`. */
AMresult *AMfork(AMdoc *doc, const AMitems *heads);

/** \brief Builds the next sync message for a peer. Rust: `src/doc.rs:278`. */
AMresult *AMgenerateSyncMessage(AMdoc *doc, AMsyncState *sync_state);

/** \brief Gets a document's actor id. Rust: `src/doc.rs:300`. */
AMresult *AMgetActorId(const AMdoc *doc);

/** \brief Looks up a change by its hash. Rust: `src/doc.rs:327`. */
AMresult *AMgetChangeByHash(AMdoc *doc, const uint8_t *src, size_t count);

/** \brief Gets the changes a peer is missing. Rust: `src/doc.rs:355`. */
AMresult *AMgetChanges(AMdoc *doc, const AMitems *have_deps);

/** \brief Gets the changes present in \p doc2 but not \p doc1. Rust: `src/doc.rs:384`. */
AMresult *AMgetChangesAdded(AMdoc *doc1, AMdoc *doc2);

/** \brief Creates a cursor at a position in a list or text object. Rust: `src/doc.rs:412`. */
AMresult *AMgetCursor(const AMdoc *doc, const AMobjId *obj_id, size_t position, const AMitems *heads);

/** \brief Gets the position of a cursor within an object. Rust: `src/doc.rs:455`. */
AMresult *AMgetCursorPosition(const AMdoc *doc, const AMobjId *obj_id, const AMcursor *cursor, const AMitems *heads);

/** \brief Gets a document's current heads. Rust: `src/doc.rs:488`. */
AMresult *AMgetHeads(AMdoc *doc);

/** \brief Gets the hashes a document's changes depend on but does not have. Rust: `src/doc.rs:512`. */
AMresult *AMgetMissingDeps(AMdoc *doc, const AMitems *heads);

/** \brief Gets the document's last local change. Rust: `src/doc.rs:540`. */
AMresult *AMgetLastLocalChange(AMdoc *doc);

/** \brief Gets the keys of a map object. Rust: `src/doc.rs:564`. */
AMresult *AMkeys(const AMdoc *doc, const AMobjId *obj_id, const AMitems *heads);

/** \brief Loads a document from an array of bytes. Rust: `src/doc.rs:598`. */
AMresult *AMload(const uint8_t *src, size_t count);

/** \brief Applies a saved document to an existing document. Rust: `src/doc.rs:623`. */
AMresult *AMloadIncremental(AMdoc *doc, const uint8_t *src, size_t count);

/** \brief Merges \p src into \p dest. Rust: `src/doc.rs:650`. */
AMresult *AMmerge(AMdoc *dest, AMdoc *src);

/** \brief Gets an object's size. Rust: `src/doc.rs:674`. */
size_t AMobjSize(const AMdoc *doc, const AMobjId *obj_id, const AMitems *heads);

/** \brief Gets an object's type. Rust: `src/doc.rs:709`. */
AMobjType AMobjObjType(const AMdoc *doc, const AMobjId *obj_id);

/** \brief Gets an object's items. Rust: `src/doc.rs:738`. */
AMresult *AMobjItems(const AMdoc *doc, const AMobjId *obj_id, const AMitems *heads);

/** \brief Gets the count of operations pending in a document's transaction. Rust: `src/doc.rs:766`. */
size_t AMpendingOps(const AMdoc *doc);

/** \brief Applies a sync message from a peer. Rust: `src/doc.rs:791`. */
AMresult *AMreceiveSyncMessage(AMdoc *doc, AMsyncState *sync_state, const AMsyncMessage *sync_message);

/** \brief Rolls back the pending operations, returning the count rolled back. Rust: `src/doc.rs:817`. */
size_t AMrollback(AMdoc *doc);

/** \brief Saves a document, committing first. Rust: `src/doc.rs:837`. */
AMresult *AMsave(AMdoc *doc);

/** \brief Saves the changes added since the last save, committing first. Rust: `src/doc.rs:856`. */
AMresult *AMsaveIncremental(AMdoc *doc);

/** \brief Sets a document's actor id. Rust: `src/doc.rs:877`. */
AMresult *AMsetActorId(AMdoc *doc, const AMactorId *actor_id);

/**
 * \brief Splices values into a list object.
 * \param[in] values An `AMitems` struct, passed **by value**, from which
 *                   values will be spliced **starting at its current
 *                   position**. Call `AMitemsRewound()` on a used `AMitems`
 *                   first. Passing by value means the caller's cursor is not
 *                   advanced.
 *
 * Rust: `src/doc.rs:916`, the position note at `src/doc.rs:846-849`.
 */
AMresult *AMsplice(AMdoc *doc, const AMobjId *obj_id, size_t pos, ptrdiff_t del, AMitems values);

/** \brief Splices text into a list or text object. Rust: `src/doc.rs:962`. */
AMresult *AMspliceText(AMdoc *doc, const AMobjId *obj_id, size_t pos, ptrdiff_t del, AMbyteSpan text);

/** \brief Gets a text object's contents. Rust: `src/doc.rs:995`. */
AMresult *AMtext(const AMdoc *doc, const AMobjId *obj_id, const AMitems *heads);

/* -------------------------------------------------------------------------
 * Lists. Rust: src/doc/list.rs.
 *
 * `pos` is `SIZE_MAX` for "the last item" when `insert` is false and for "one
 * past the end" when `insert` is true; any other out-of-range value is an
 * error result (`src/doc/list.rs:20-41`).
 * ------------------------------------------------------------------------- */

/** Rust: `src/doc/list.rs:50`. */
AMresult *AMlistDelete(AMdoc *doc, const AMobjId *obj_id, size_t pos);
/** Rust: `src/doc/list.rs:83`. */
AMresult *AMlistGet(const AMdoc *doc, const AMobjId *obj_id, size_t pos, const AMitems *heads);
/** Rust: `src/doc/list.rs:124`. */
AMresult *AMlistGetAll(const AMdoc *doc, const AMobjId *obj_id, size_t pos, const AMitems *heads);
/** Rust: `src/doc/list.rs:162`. */
AMresult *AMlistIncrement(AMdoc *doc, const AMobjId *obj_id, size_t pos, int64_t value);
/** Rust: `src/doc/list.rs:198`. */
AMresult *AMlistPutBool(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, bool value);
/** Rust: `src/doc/list.rs:244`. */
AMresult *AMlistPutBytes(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, AMbyteSpan value);
/** Rust: `src/doc/list.rs:286`. */
AMresult *AMlistPutCounter(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, int64_t value);
/** Rust: `src/doc/list.rs:328`. */
AMresult *AMlistPutF64(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, double value);
/** Rust: `src/doc/list.rs:369`. */
AMresult *AMlistPutInt(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, int64_t value);
/** Rust: `src/doc/list.rs:409`. */
AMresult *AMlistPutNull(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert);
/** Rust: `src/doc/list.rs:449`. */
AMresult *AMlistPutObject(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, AMobjType obj_type);
/** Rust: `src/doc/list.rs:494`. */
AMresult *AMlistPutStr(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, AMbyteSpan value);
/** Rust: `src/doc/list.rs:537`. */
AMresult *AMlistPutTimestamp(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, int64_t value);
/** Rust: `src/doc/list.rs:579`. */
AMresult *AMlistPutUint(AMdoc *doc, const AMobjId *obj_id, size_t pos, bool insert, uint64_t value);
/** Rust: `src/doc/list.rs:619`. */
AMresult *AMlistRange(const AMdoc *doc, const AMobjId *obj_id, size_t begin, size_t end, const AMitems *heads);

/* -------------------------------------------------------------------------
 * Maps. Rust: src/doc/map.rs.
 *
 * A `NULL` obj_id is the document's root map, not an error
 * (`src/obj.rs:8-14`), which is the opposite of a `NULL` document
 * (`src/doc/utils.rs:12-21`).
 * ------------------------------------------------------------------------- */

/** Rust: `src/doc/map.rs:30`. */
AMresult *AMmapDelete(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key);
/** Rust: `src/doc/map.rs:63`. */
AMresult *AMmapGet(const AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, const AMitems *heads);
/** Rust: `src/doc/map.rs:105`. */
AMresult *AMmapGetAll(const AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, const AMitems *heads);
/** Rust: `src/doc/map.rs:143`. */
AMresult *AMmapIncrement(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, int64_t value);
/** Rust: `src/doc/map.rs:174`. */
AMresult *AMmapPutBool(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, bool value);
/** Rust: `src/doc/map.rs:208`. */
AMresult *AMmapPutBytes(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, AMbyteSpan value);
/** Rust: `src/doc/map.rs:239`. */
AMresult *AMmapPutCounter(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, int64_t value);
/** Rust: `src/doc/map.rs:273`. */
AMresult *AMmapPutNull(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key);
/** Rust: `src/doc/map.rs:303`. */
AMresult *AMmapPutObject(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, AMobjType obj_type);
/** Rust: `src/doc/map.rs:339`. */
AMresult *AMmapPutF64(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, double value);
/** Rust: `src/doc/map.rs:370`. */
AMresult *AMmapPutInt(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, int64_t value);
/** Rust: `src/doc/map.rs:401`. */
AMresult *AMmapPutStr(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, AMbyteSpan value);
/** Rust: `src/doc/map.rs:432`. */
AMresult *AMmapPutTimestamp(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, int64_t value);
/** Rust: `src/doc/map.rs:463`. */
AMresult *AMmapPutUint(AMdoc *doc, const AMobjId *obj_id, AMbyteSpan key, uint64_t value);
/** Rust: `src/doc/map.rs:500`. */
AMresult *AMmapRange(const AMdoc *doc, const AMobjId *obj_id, AMbyteSpan begin, AMbyteSpan end, const AMitems *heads);

/* -------------------------------------------------------------------------
 * Marks. Rust: src/doc/mark.rs.
 * ------------------------------------------------------------------------- */

/** \brief Gets a mark's name. Rust: `src/doc/mark.rs:109`. */
AMbyteSpan AMmarkName(const AMmark *mark);

/** \brief Gets a mark's value as a new one-item result the caller owns. Rust: `src/doc/mark.rs:129`. */
AMresult *AMmarkValue(const AMmark *mark);

/** \brief Gets a mark's start offset. Rust: `src/doc/mark.rs:148`. */
size_t AMmarkStart(const AMmark *mark);

/** \brief Gets a mark's end offset, or `SIZE_MAX` when it has none. Rust: `src/doc/mark.rs:167`. */
size_t AMmarkEnd(const AMmark *mark);

/** \brief Gets the marks over a range of a list or text object. Rust: `src/doc/mark.rs:193`. */
AMresult *AMmarks(const AMdoc *doc, const AMobjId *obj_id, const AMitems *heads);

/**
 * \brief Creates a mark over a range of a list or text object.
 * \param[in] value The value the mark holds, or `NULL`.
 * \return An `AMresult` carrying an `AM_VAL_TYPE_MARK` item, or an error
 *         result.
 * \pre \p expand `!= AM_MARK_EXPAND_DEFAULT`. The conversion rejects it with
 *      an error result (`src/doc/mark.rs:59-77`); it is not a crash.
 * \warning **A `NULL` \p value is an error result here, not a crash.**
 *          Upstream dereferences it without checking
 *          (`src/doc/mark.rs:250`), so this port checks and answers
 *          ``AMresult::error("Invalid `AMitem*`")`` instead of turning a C bug
 *          into a segfault. Every caller that passes a real item takes the
 *          same path upstream does; a caller that guards its pointer learns
 *          that the guard was worth having, not that it was pointless.
 * \warning \p name is copied into the document, so the span need not outlive
 *          the call; \p value is stored, not copied, and the item must.
 *
 * Rust: `src/doc/mark.rs:236`.
 */
AMresult *AMmarkCreate(AMdoc *doc, const AMobjId *obj_id, size_t start, size_t end, AMmarkExpand expand, AMbyteSpan name, const AMitem *value);

/** \brief Clears marks over a range of a list or text object. Rust: `src/doc/mark.rs:283`. */
AMresult *AMmarkClear(AMdoc *doc, const AMobjId *obj_id, size_t start, size_t end, AMmarkExpand expand, AMbyteSpan name);

/* -------------------------------------------------------------------------
 * Sync. Rust: src/sync/{have,message,state}.rs.
 *
 * `AMsyncState` and `AMsyncMessage` are mutable here because
 * `AMgenerateSyncMessage` and `AMreceiveSyncMessage` take a `*mut` state, but
 * the state itself is still owned by the `AMresult` that produced it.
 *
 * **A `NULL` sync handle is answered in one of two ways, and which one
 * depends on the function.** The accessors that read a list out of a handle —
 * `AMsyncHaveLastSync()`, `AMsyncMessageHaves()`, `AMsyncMessageHeads()`,
 * `AMsyncMessageNeeds()` — answer an **empty success**: the status is
 * `AM_STATUS_OK` and the size is `0`, because upstream's
 * `None => Default::default()` arm turns an empty slice into an empty result
 * (`src/sync/have.rs:37-40`, `src/sync/message.rs:98`, `:118`, `:139`).
 * The two encoders answer an **error result** carrying the reference's own
 * hard-coded message, ``"Invalid `AMsyncMessage*`"`` and ``"Invalid
 * `AMsyncState*`"`` (`src/sync/message.rs:12-19`, `src/sync/state.rs:8-15`).
 * Those strings are reproduced byte for byte because a C caller can match on
 * them. `AMsyncStateEqual()` is the third case and is documented on itself:
 * two `NULL`s are **not** equal.
 *
 * **A `NULL` `has_value` is a third thing again, and it is an error result
 * and not undefined behaviour.** Upstream writes through it unconditionally
 * (`src/sync/state.rs:186-201`, `:218-232`, `:250-264`); this port refuses
 * with ``AMresult::error("Invalid `bool*`")``. A caller that honours the
 * precondition sees no difference.
 * ------------------------------------------------------------------------- */

/**
 * \brief Gets a have's last sync sequence.
 * \param[in] sync_have An `AMsyncHave const *`, or `NULL`.
 * \return An `AMresult` of `AM_VAL_TYPE_CHANGE_HASH` items, or an **empty
 *         success** when \p sync_have is `NULL`.
 * Rust: `src/sync/have.rs:37`.
 */
AMresult *AMsyncHaveLastSync(const AMsyncHave *sync_have);

/** \brief Decodes a sync message from an array of bytes. Rust: `src/sync/message.rs:64`. */
AMresult *AMsyncMessageDecode(const uint8_t *src, size_t count);

/**
 * \brief Encodes a sync message.
 * \param[in] sync_message An `AMsyncMessage const *`, or `NULL`.
 * \return An `AMresult` holding one `AM_VAL_TYPE_BYTES` item, or an error
 *         result. A `NULL` \p sync_message is the error result
 *         ``"Invalid `AMsyncMessage*`"``.
 * Rust: `src/sync/message.rs:82`.
 */
AMresult *AMsyncMessageEncode(const AMsyncMessage *sync_message);

/**
 * \brief Gets the haves a sync message carries.
 * \param[in] sync_message An `AMsyncMessage const *`, or `NULL`.
 * \return An `AMresult` of `AM_VAL_TYPE_SYNC_HAVE` items, or an **empty
 *         success** when \p sync_message is `NULL`.
 * Rust: `src/sync/message.rs:100`.
 */
AMresult *AMsyncMessageHaves(const AMsyncMessage *sync_message);

/**
 * \brief Gets the heads a sync message carries.
 * \param[in] sync_message An `AMsyncMessage const *`, or `NULL`.
 * \return An `AMresult` of `AM_VAL_TYPE_CHANGE_HASH` items, or an **empty
 *         success** when \p sync_message is `NULL`.
 * Rust: `src/sync/message.rs:120`.
 */
AMresult *AMsyncMessageHeads(const AMsyncMessage *sync_message);

/**
 * \brief Gets the needs a sync message carries.
 * \param[in] sync_message An `AMsyncMessage const *`, or `NULL`.
 * \return An `AMresult` of `AM_VAL_TYPE_CHANGE_HASH` items, or an **empty
 *         success** when \p sync_message is `NULL`.
 * Rust: `src/sync/message.rs:141`.
 */
AMresult *AMsyncMessageNeeds(const AMsyncMessage *sync_message);

/** \brief Decodes a sync state from an array of bytes. Rust: `src/sync/state.rs:73`. */
AMresult *AMsyncStateDecode(const uint8_t *src, size_t count);

/**
 * \brief Encodes a sync state.
 * \param[in] sync_state An `AMsyncState const *`, or `NULL`.
 * \return An `AMresult` holding one `AM_VAL_TYPE_BYTES` item, or an error
 *         result. A `NULL` \p sync_state is the error result
 *         ``"Invalid `AMsyncState*`"``.
 * Rust: `src/sync/state.rs:91`.
 */
AMresult *AMsyncStateEncode(const AMsyncState *sync_state);

/**
 * \brief Tests two sync states for equality.
 * \return `true` only when both handles are non-`NULL` and their thirteen
 *         fields match. **Two `NULL`s are not equal**, and neither is a
 *         `NULL` and a real state: that is upstream's own match arm
 *         (`src/sync/state.rs:118`) and its `\post`
 *         (`src/sync/state.rs:105`).
 * Rust: `src/sync/state.rs:111`.
 */
bool AMsyncStateEqual(const AMsyncState *sync_state1, const AMsyncState *sync_state2);

/** \brief Allocates a new sync state. Rust: `src/sync/state.rs:129`. */
AMresult *AMsyncStateInit(void);

/** \brief Gets the heads this peer and the other peer share. Rust: `src/sync/state.rs:146`. */
AMresult *AMsyncStateSharedHeads(const AMsyncState *sync_state);

/** \brief Gets the heads last sent to the other peer. Rust: `src/sync/state.rs:164`. */
AMresult *AMsyncStateLastSentHeads(const AMsyncState *sync_state);

/**
 * \brief Gets the other peer's haves.
 * \param[in] sync_state An `AMsyncState const *`, or `NULL`.
 * \param[out] has_value Set to `true` when the returned items are relevant,
 *                      `false` otherwise. May be `NULL`.
 * \return An `AMresult` of `AM_VAL_TYPE_SYNC_HAVE` items, or an **empty
 *         success** when the state is `NULL` or has no haves for the peer.
 * \warning **A `NULL` \p has_value is an error result, not undefined
 *          behaviour.** Upstream writes through it unconditionally
 *          (`src/sync/state.rs:186-201`); this port refuses with
 *          ``AMresult::error("Invalid `bool*`")`` rather than turning a C bug
 *          into a segfault. Every caller that honours the precondition takes
 *          the same path upstream does.
 * Rust: `src/sync/state.rs:186`.
 */
AMresult *AMsyncStateTheirHaves(const AMsyncState *sync_state, bool *has_value);

/**
 * \brief Gets the other peer's heads.
 * \param[in] sync_state An `AMsyncState const *`, or `NULL`.
 * \param[out] has_value Set to `true` when the returned items are relevant.
 *                      May be `NULL`, with the same error result as
 *                      `AMsyncStateTheirHaves()`.
 * \return An `AMresult` of `AM_VAL_TYPE_CHANGE_HASH` items, or an **empty
 *         success** when the state is `NULL` or has no heads for the peer.
 * Rust: `src/sync/state.rs:218`.
 */
AMresult *AMsyncStateTheirHeads(const AMsyncState *sync_state, bool *has_value);

/**
 * \brief Gets the other peer's needs.
 * \param[in] sync_state An `AMsyncState const *`, or `NULL`.
 * \param[out] has_value Set to `true` when the returned items are relevant.
 *                      May be `NULL`, with the same error result as
 *                      `AMsyncStateTheirHaves()`.
 * \return An `AMresult` of `AM_VAL_TYPE_CHANGE_HASH` items, or an **empty
 *         success** when the state is `NULL` or has no needs for the peer.
 * Rust: `src/sync/state.rs:250`.
 */
AMresult *AMsyncStateTheirNeeds(const AMsyncState *sync_state, bool *has_value);

/* -------------------------------------------------------------------------
 * The hand-written C utility layer.
 *
 * Upstream keeps these in four separate headers under
 * `include/automerge-c/utils/` and never regenerates them. They are folded
 * into this one header here because a consumer of this port has a single
 * header to install, and because `docs/STATUS.md` gives this slice exactly
 * two files. Every declaration below is a transcription of
 * `include/automerge-c/utils/{result,string,stack,stack_callback_data}.h`
 * plus `src/utils/{result,string,stack,stack_callback_data}.c`.
 *
 * **Two of these return memory the caller owns**, which is the one place the
 * ownership section above does not reach: `AMstackCallbackDataInit()` and
 * `AMexpect()` return a `malloc` allocation that must be passed to `free()`,
 * and so does `AMstrdup()`. An `AMstack *` is a third kind of value: it owns
 * the `AMresult`s pushed onto it, `AMstackFree()` releases all of them and
 * nulls the caller's pointer, and a result taken back out with
 * `AMstackPop()` is the caller's again. The rest borrow.
 *
 * All three of the allocating ones come from the C runtime's `malloc`, which is
 * what makes `free()` the correct release. Separate results do not exempt calls
 * from the global serialization rule above.
 * ------------------------------------------------------------------------- */

/**
 * \brief A node in a singly-linked list of result pointers.
 *
 * A stack exists so that a C caller can defer a batch of `AMresultFree()`
 * calls to one place instead of writing `goto` at every early exit. It owns
 * the results it holds; `AMstackFree()` releases all of them.
 *
 * Rust: `include/automerge-c/utils/stack.h:21-26`, `src/utils/stack.c`.
 */
typedef struct AMstack {
  AMresult *result;    /**< A result to be deallocated. */
  struct AMstack *prev; /**< The previous node, or `NULL`. */
} AMstack;

/**
 * \brief The prototype of a function that examines the result at the top of a
 *        stack.
 * \return `true` if the top result is valid, `false` otherwise. Returning
 *         `false` leaves the result on the stack, so it is still freed by
 *         `AMstackFree()`.
 * \pre \p stack `!= NULL`
 *
 * `AMstackResult()`, `AMstackItem()` and `AMstackItems()` invoke this callback
 * synchronously on the invoking thread, after pushing the result and before
 * returning. It borrows the stack and its result; it receives \p data unchanged,
 * including `NULL`. The library neither retains nor frees \p data. Keep the
 * callback code and any context it accesses valid through their last use; a
 * callback may release context it owns after that last use.
 *
 * The callback may inspect the stack, result and borrowed items (for example,
 * `AMstackSize()`, `AMresultStatus()`, `AMresultItems()`, `AMitemsNext()` on a
 * local cursor and `AMitemValType()`). Inspection also includes
 * `AMresultError()`, `AMvalTypeToString()` and copying a diagnostic span with
 * `AMstrdup()`; release that independently owned copy with `free()`, not the
 * borrowed result. These nested calls use the outer call's already-held global
 * lock and **must not reacquire or release it**. No general mutation, other
 * reentrancy or cross-thread entry is permitted.
 *
 * Keep the stack nodes and result live and unchanged in ownership until the
 * outer call returns: do not pop or free them, replace `*stack`, or relink the
 * nodes. Returning `false` does not return ownership to the caller. Do not
 * retain the callback's \p stack address. When the outer call was given a
 * `NULL` stack, the callback instead borrows a temporary local node, and the
 * result and all views into it are invalidated when it returns to the outer
 * call, which frees the result. Otherwise, retained item or byte views require
 * their owning result to stay live under the usual ownership rules.
 *
 * Rust: `include/automerge-c/utils/stack.h:39`.
 */
typedef bool (*AMstackCallback)(AMstack **stack, void *data);

/**
 * \brief Deallocates the storage for a stack of results, and every result on
 *        it.
 * \post `*stack == NULL`
 *
 * Rust: `src/utils/stack.c:7-13`.
 */
void AMstackFree(AMstack **stack);

/**
 * \brief Removes a result from a stack without freeing it.
 * \param[in] result The result to pop, or `NULL` to pop the top one.
 * \return The popped result, now owned by the caller, or `NULL` if it was not
 *         on the stack.
 * \pre \p stack `!= NULL`
 * \warning The returned pointer must be passed to `AMresultFree()`.
 *
 * Rust: `src/utils/stack.c:15-33`.
 */
AMresult *AMstackPop(AMstack **stack, const AMresult *result);

/**
 * \brief Pushes a result onto a stack and validates it with a callback.
 * \return \p result, or `NULL` when the callback rejected it.
 * \warning If \p stack is `NULL` then \p result is freed before returning, so
 *          that a caller passing `NULL` cannot leak it.
 *
 * Rust: `src/utils/stack.c:35-84`.
 */
AMresult *AMstackResult(AMstack **stack, AMresult *result, AMstackCallback callback, void *data);

/**
 * \brief Pushes a result onto a stack, validates it, and gets its first item.
 * \return A pointer to an `AMitem` borrowed from the result, or `NULL`.
 * \warning If \p stack is `NULL` then \p result is freed before returning.
 *
 * Rust: `src/utils/stack.c:86-89`.
 */
AMitem *AMstackItem(AMstack **stack, AMresult *result, AMstackCallback callback, void *data);

/**
 * \brief Pushes a result onto a stack, validates it, and gets its items.
 * \return An `AMitems` struct borrowed from the result, or a zero-valued one.
 * \warning If \p stack is `NULL` then \p result is freed before returning.
 *
 * Rust: `src/utils/stack.c:91-93`.
 */
AMitems AMstackItems(AMstack **stack, AMresult *result, AMstackCallback callback, void *data);

/** \brief Gets the count of results on a stack, or `0` for `NULL`. Rust: `src/utils/stack.c:95-106`. */
size_t AMstackSize(const AMstack *const stack);

/**
 * \struct AMstackCallbackData
 * \brief The parameters of an item value test, passed to an
 *        `AMstackCallback`.
 *
 * Rust: `include/automerge-c/utils/stack_callback_data.h:17-24`.
 */
typedef struct {
  AMvalType bitmask; /**< A bitmask of `AMvalType` tags. */
  char const *file;  /**< A null-terminated file path string. */
  int line;          /**< The ordinal number of a line within a file. */
} AMstackCallbackData;

/**
 * \brief Allocates a new `AMstackCallbackData` struct.
 * \warning The returned pointer must be passed to `free()`.
 *
 * Rust: `src/utils/stack_callback_data.c:5-9`.
 */
AMstackCallbackData *AMstackCallbackDataInit(AMvalType const bitmask, char const *const file, int const line);

/**
 * \memberof AMstackCallbackData
 * \def AMexpect
 * \brief Allocates a new `AMstackCallbackData` struct from an `AMvalType`
 *        bitmask, recording the call site.
 * \warning The returned pointer must be passed to `free()`.
 *
 * Rust: `include/automerge-c/utils/stack_callback_data.h:51`.
 */
#define AMexpect(bitmask) AMstackCallbackDataInit(bitmask, __FILE__, __LINE__)

/**
 * \brief Returns a `malloc`-allocated, NUL-terminated duplicate of a UTF-8
 *        string view, with each NUL (0) byte substituted for \p nul.
 * \param[in] str A UTF-8 string view as an `AMbyteSpan` struct.
 * \param[in] nul The substitution for a NUL byte, or `NULL` to substitute the
 *                two-character sequence `\0`.
 * \return A disowned string, or `NULL` if \p str is `NULL` or on allocation
 *         failure.
 * \pre \p str.src `!= NULL` or the result is `NULL`.
 * \warning The returned pointer must be passed to `free()`.
 *
 * Rust: `include/automerge-c/utils/string.h:27`, `src/utils/string.c:6-46`.
 */
char *AMstrdup(AMbyteSpan const str, char const *nul);


#endif /* AUTOMERGE_H */
