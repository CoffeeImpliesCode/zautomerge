#include <float.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* third-party */
#include <cmocka.h>

/* local */
#include <automerge-c/automerge.h>
#include <automerge-c/utils/stack_callback_data.h>
#include "suite/base_state.h"
#include "suite/cmocka_utils.h"
#include "abi_coverage.h"

/* -------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */

/* A document with a known actor id, for cases that need a reproducible one.
 * `AMcreate` takes an `AMactorId` borrowed from a result
 * (`rust/automerge-c/src/doc.rs:126-130`), so the actor result is pushed on
 * the stack first and stays alive for the whole case.
 */
static AMdoc* make_doc(AMstack** stack_ptr, char const* actor_hex) {
    AMactorId const* actor_id;
    assert_true(AMitemToActorId(
        AMstackItem(stack_ptr, AMactorIdFromStr(AMstr(actor_hex)), cmocka_cb, AMexpect(AM_VAL_TYPE_ACTOR_ID)),
        &actor_id));
    AMdoc* doc;
    assert_true(AMitemToDoc(AMstackItem(stack_ptr, AMcreate(actor_id), cmocka_cb, AMexpect(AM_VAL_TYPE_DOC)), &doc));
    return doc;
}

/* The single head of a document, as a borrowed byte view. The `AMitems`
 * cursor borrows from the result pushed on the stack, which is why the
 * caller must not free it before it is done reading.
 */
static AMbyteSpan single_head(AMstack** stack_ptr, AMdoc* doc) {
    AMitems heads = AMstackItems(stack_ptr, AMgetHeads(doc), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&heads), 1);
    AMbyteSpan hash;
    assert_true(AMitemToChangeHash(AMitemsNext(&heads, 1), &hash));
    assert_int_equal(hash.count, AM_CHANGE_HASH_SIZE);
    return hash;
}

/* The change at a document's single head.
 * `AMitemToChange` needs a unique item (`rust/automerge-c/src/item.rs:1789`,
 * "needs a unique item" in `include/automerge.h:727`), which is what
 * `AMgetChangeByHash` hands back: it loads a fresh `AMchange` per call
 * (`rust/automerge-c/src/doc.rs:327-341`).
 */
static AMchange* head_change(AMstack** stack_ptr, AMdoc* doc) {
    AMbyteSpan hash = single_head(stack_ptr, doc);
    AMchange* change;
    assert_true(AMitemToChange(
        AMstackItem(stack_ptr, AMgetChangeByHash(doc, hash.src, hash.count), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE)),
        &change));
    return change;
}

/* -------------------------------------------------------------------------
 * AMchange. Rust: rust/automerge-c/src/change.rs:68-356.
 * ------------------------------------------------------------------------- */

static void test_AMchange_scalars(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "0123456789abcdef0123456789abcdef");
    int64_t const timestamp = 1234567890123;
    /* One `put` op, so the change has exactly one operation. */
    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc, AMstr("hello"), &timestamp), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));

    AMchange* const change = head_change(stack_ptr, doc);

    /* `AMchangeStartOp`/`AMchangeMaxOp` are the first and last op indices
     * within the change (`src/change.rs:236-243`, `:311-318`). The root map
     * starts at op 0 and the first `put` is op 1, so a one-op change spans
     * 1..=1. */
    assert_int_equal(AMchangeStartOp(change), UINT64_C(1));
    assert_int_equal(AMchangeMaxOp(change), UINT64_C(1));
    /* `AMchangeSize` counts operations, not bytes (`src/change.rs:293-299`). */
    assert_int_equal(AMchangeSize(change), 1);
    /* `AMchangeSeq` is the change's index in its actor's change chunk, and
     * the reference numbers it from one, not from zero
     * (`src/change.rs:274-281` -> `Change::seq` at
     * `rust/automerge/src/change.rs:94-96` -> `StoredChange::seq` at
     * `rust/automerge/src/storage/change.rs:244-246`). The oracle prints
     * `change.seq()` verbatim (`tools/oracle/src/main.rs:222`, `:235`) and
     * `test/golden/change.jsonl:1` records `"index":0,"seq":1` for a
     * document's first change. This is the one number in this file that the
     * C ABI could get wrong without any Zig-side test noticing. */
    assert_int_equal(AMchangeSeq(change), UINT64_C(1));
    /* The commit time is the *nix milliseconds passed to `AMcommit`
     * (`src/doc.rs:151-171`; `src/change.rs:330-337`). */
    assert_int_equal(AMchangeTime(change), timestamp);
    /* A change carrying operations is not empty (`src/change.rs:193-200`). */
    assert_false(AMchangeIsEmpty(change));

    /* The message is the string handed to `AMcommit`
     * (`src/change.rs:256-262`). */
    AMbyteSpan const message = AMchangeMessage(change);
    assert_int_equal(message.count, 5);
    assert_memory_equal(message.src, "hello", 5);

    /* A change made with `AMcommit` carries no extra bytes
     * (`src/change.rs:134-141`); the `Option<Vec<u8>>` is `None`, which
     * `into()` turns into an empty span. */
    assert_int_equal(AMchangeExtraBytes(change).count, 0);

    /* The first actor referenced by a change is the one that authored it
     * (`src/change.rs:80-86`). */
    AMactorId const* author;
    assert_true(AMitemToActorId(AMstackItem(stack_ptr, AMchangeActorId(change), cmocka_cb,
                                            AMexpect(AM_VAL_TYPE_ACTOR_ID)),
                                &author));
    /* Its hex, and **the length before the content**. `AMactorIdStr` answers
     * `Box<str>::as_bytes()` (`rust/automerge-c/src/actor_id.rs:44-47`), and a
     * `Box<str>` is a `(ptr, len)` pair with no terminator, so `AMbyteSpan.count`
     * is the only thing that bounds the string and `strlen` reads past it.
     * Every call site in the reference's own suite asserts the count and then
     * compares that many bytes — `test/actor_id_tests.c:96-98`,
     * `test/doc_tests.c:247-249`, `test/ported_wasm/basic_tests.c:194-196` —
     * and none of them calls `strlen`, because the value is not a C string.
     * Two characters per byte is the writer's contract
     * (`AMactorId::to_str` -> `to_hex_string`, `src/actor_id.rs:39-51`). */
    AMbyteSpan const author_hex = AMactorIdStr(author);
    assert_int_equal(author_hex.count, 2 * AMactorIdBytes(author).count);
    assert_memory_equal(author_hex.src, "0123456789abcdef0123456789abcdef", author_hex.count);

    /* A first change has no dependencies: the clock it advances from is
     * empty, so there is nothing to depend on. The result is an items
     * result with zero items, not an error. */
    AMitems deps = AMstackItems(stack_ptr, AMchangeDeps(change), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&deps), 0);
}

static void test_AMchange_hash_and_bytes(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));

    AMbyteSpan const expected = single_head(stack_ptr, doc);
    AMchange* const change = head_change(stack_ptr, doc);

    /* The hash of a change is the hash of its encoded bytes, so the head the
     * document reports and the hash the change reports are the same 32
     * bytes (`src/change.rs:175-181`). */
    AMbyteSpan const hash = AMchangeHash(change);
    assert_int_equal(hash.count, AM_CHANGE_HASH_SIZE);
    assert_memory_equal(hash.src, expected.src, AM_CHANGE_HASH_SIZE);

    /* The raw bytes decode back into the same change, with the same hash
     * (`src/change.rs:159-163`). This is the round trip that makes a change
     * hash a content address. */
    AMbyteSpan const raw = AMchangeRawBytes(change);
    assert_true(raw.count > 0);
    AMchange* reloaded;
    assert_true(AMitemToChange(AMstackItem(stack_ptr, AMchangeFromBytes(raw.src, raw.count), cmocka_cb,
                                            AMexpect(AM_VAL_TYPE_CHANGE)),
                               &reloaded));
    assert_memory_equal(AMchangeHash(reloaded).src, hash.src, AM_CHANGE_HASH_SIZE);
    assert_int_equal(AMchangeSize(reloaded), AMchangeSize(change));
    assert_int_equal(AMchangeSeq(reloaded), AMchangeSeq(change));
}

static void test_AMchangeCompress(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMchange* const change = head_change(stack_ptr, doc);

    AMbyteSpan const hash_before = AMchangeHash(change);
    /* A span cannot be compared by identity, so copy the 32 bytes out: the
     * compression is in place and the old pointer may dangle afterwards. */
    uint8_t hash_copy[AM_CHANGE_HASH_SIZE];
    memcpy(hash_copy, hash_before.src, AM_CHANGE_HASH_SIZE);

    /* `AMchangeCompress` re-encodes the change with DEFLATE, in place
     * (`src/change.rs:97-102`). Compressing an already-compressed change is
     * a no-op upstream, so the assertion is the invariant that must survive
     * either way: the change still names the same content. */
    AMchangeCompress(change);
    assert_memory_equal(AMchangeHash(change).src, hash_copy, AM_CHANGE_HASH_SIZE);
    assert_int_equal(AMchangeSize(change), 1);

    /* And the compressed bytes still decode to the same change, which is the
     * only reason the compression is safe to do at all. */
    AMbyteSpan const compressed = AMchangeRawBytes(change);
    assert_true(compressed.count > 0);
    AMchange* reloaded;
    assert_true(AMitemToChange(AMstackItem(stack_ptr, AMchangeFromBytes(compressed.src, compressed.count), cmocka_cb,
                                            AMexpect(AM_VAL_TYPE_CHANGE)),
                               &reloaded));
    assert_memory_equal(AMchangeHash(reloaded).src, hash_copy, AM_CHANGE_HASH_SIZE);
}

static void test_AMchangeLoadDocument(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    for (int i = 0; i != 3; ++i) {
        AMstackItem(NULL, AMmapPutInt(doc, AM_ROOT, AMstr("a"), i), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
        AMstackItem(NULL, AMcommit(doc, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    }
    /* Three commits means three changes, numbered from one. */
    assert_int_equal(AMchangeSeq(head_change(stack_ptr, doc)), UINT64_C(3));

    AMbyteSpan saved;
    assert_true(AMitemToBytes(AMstackItem(stack_ptr, AMsave(doc), cmocka_cb, AMexpect(AM_VAL_TYPE_BYTES)), &saved));

    /* `AMchangeLoadDocument` reads a saved document and answers with one
     * `AMchange` item per change in it, in order
     * (`src/change.rs:218-224`). The sequence numbers are the only stable
     * way to check the order, because a saved document's change order is
     * not the document's head order. */
    AMitems changes = AMstackItems(stack_ptr, AMchangeLoadDocument(saved.src, saved.count), cmocka_cb,
                                   AMexpect(AM_VAL_TYPE_CHANGE));
    assert_int_equal(AMitemsSize(&changes), 3);
    AMchange* change;
    assert_true(AMitemToChange(AMitemsNext(&changes, 1), &change));
    assert_int_equal(AMchangeSeq(change), UINT64_C(1));
    assert_true(AMitemToChange(AMitemsNext(&changes, 1), &change));
    assert_int_equal(AMchangeSeq(change), UINT64_C(2));
    assert_true(AMitemToChange(AMitemsNext(&changes, 1), &change));
    assert_int_equal(AMchangeSeq(change), UINT64_C(3));
    assert_null(AMitemsNext(&changes, 1));
}

/* -------------------------------------------------------------------------
 * AMdoc. Rust: rust/automerge-c/src/doc.rs.
 * ------------------------------------------------------------------------- */

static void test_AMgetChangesAdded(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc1 = make_doc(stack_ptr, "aaaa");
    AMdoc* doc2 = make_doc(stack_ptr, "bbbb");

    AMstackItem(NULL, AMmapPutStr(doc1, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc1, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMbyteSpan const head1 = single_head(stack_ptr, doc1);

    /* doc2 learns doc1's change, then adds one of its own. */
    AMstackItem(NULL, AMmerge(doc2, doc1), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMstackItem(NULL, AMmapPutStr(doc2, AM_ROOT, AMstr("b"), AMstr("c")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc2, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMbyteSpan const head2 = single_head(stack_ptr, doc2);

    /* `AMgetChangesAdded` answers with the changes present in doc2 that
     * doc1 does not have (`src/doc.rs:367-388`). doc1 is missing exactly
     * doc2's own commit, and nothing else. */
    AMitems added = AMstackItems(stack_ptr, AMgetChangesAdded(doc1, doc2), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE));
    assert_int_equal(AMitemsSize(&added), 1);
    AMchange* change;
    assert_true(AMitemToChange(AMitemsNext(&added, 1), &change));
    AMbyteSpan const added_hash = AMchangeHash(change);
    assert_int_equal(added_hash.count, AM_CHANGE_HASH_SIZE);
    assert_memory_equal(added_hash.src, head2.src, AM_CHANGE_HASH_SIZE);
    assert_memory_not_equal(head2.src, head1.src, AM_CHANGE_HASH_SIZE);

    /* The other direction is empty: doc1 has nothing doc2 lacks. */
    AMitems none_added = AMstackItems(stack_ptr, AMgetChangesAdded(doc2, doc1), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE));
    assert_int_equal(AMitemsSize(&none_added), 0);
}

static void test_AMrollback(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");

    /* Nothing pending yet, so nothing to roll back. */
    assert_int_equal(AMrollback(doc), 0);

    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMmapPutInt(doc, AM_ROOT, AMstr("c"), 1), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMmapPutObject(doc, AM_ROOT, AMstr("l"), AM_OBJ_TYPE_LIST), cmocka_cb,
                AMexpect(AM_VAL_TYPE_OBJ_TYPE));
    assert_int_equal(AMpendingOps(doc), 3);

    /* `AMrollback` cancels the transaction's pending operations and answers
     * how many it cancelled (`src/doc.rs:805-822`). The root map ends up the
     * size an empty document has, which is the observable consequence: a
     * rolled-back `put` never happened. */
    assert_int_equal(AMrollback(doc), 3);
    assert_int_equal(AMpendingOps(doc), 0);
    assert_int_equal(AMobjSize(doc, AM_ROOT, NULL), 0);
    /* The document still has no changes at all, not merely no pending ones:
     * a rolled-back transaction never reached the clock. */
    AMitems heads = AMstackItems(stack_ptr, AMgetHeads(doc), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&heads), 0);
}

/* -------------------------------------------------------------------------
 * AMitem. Rust: rust/automerge-c/src/item.rs:1434-1562, :2139-2158.
 * ------------------------------------------------------------------------- */

static void test_AMitemFrom_scalars(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    uint8_t const bytes[] = {0x0, 0x1, 0x2, 0xfe, 0xff};
    AMitems items = AMstackItems(stack_ptr, AMitemFromBytes(bytes, sizeof(bytes)), cmocka_cb, AMexpect(AM_VAL_TYPE_BYTES));
    assert_int_equal(AMitemsSize(&items), 1);
    AMitem* item = AMitemsNext(&items, 1);
    AMbyteSpan view;
    assert_true(AMitemToBytes(item, &view));
    assert_int_equal(view.count, sizeof(bytes));
    assert_memory_equal(view.src, bytes, sizeof(bytes));

    items = AMstackItems(stack_ptr, AMitemFromCounter(-7), cmocka_cb, AMexpect(AM_VAL_TYPE_COUNTER));
    item = AMitemsNext(&items, 1);
    int64_t integer;
    assert_true(AMitemToCounter(item, &integer));
    assert_int_equal(integer, -7);

    items = AMstackItems(stack_ptr, AMitemFromInt(-1234567890123LL), cmocka_cb, AMexpect(AM_VAL_TYPE_INT));
    item = AMitemsNext(&items, 1);
    assert_true(AMitemToInt(item, &integer));
    assert_int_equal(integer, -1234567890123LL);

    items = AMstackItems(stack_ptr, AMitemFromUint(12345678901234567890ULL), cmocka_cb, AMexpect(AM_VAL_TYPE_UINT));
    item = AMitemsNext(&items, 1);
    uint64_t unsigned_integer;
    assert_true(AMitemToUint(item, &unsigned_integer));
    assert_int_equal(unsigned_integer, UINT64_C(12345678901234567890));

    items = AMstackItems(stack_ptr, AMitemFromF64(-1.5), cmocka_cb, AMexpect(AM_VAL_TYPE_F64));
    item = AMitemsNext(&items, 1);
    double real;
    assert_true(AMitemToF64(item, &real));
    assert_true(real == -1.5);

    items = AMstackItems(stack_ptr, AMitemFromTimestamp(1234567890123), cmocka_cb, AMexpect(AM_VAL_TYPE_TIMESTAMP));
    item = AMitemsNext(&items, 1);
    assert_true(AMitemToTimestamp(item, &integer));
    assert_int_equal(integer, 1234567890123);

    items = AMstackItems(stack_ptr, AMitemFromNull(), cmocka_cb, AMexpect(AM_VAL_TYPE_NULL));
    item = AMitemsNext(&items, 1);
    assert_int_equal(AMitemValType(item), AM_VAL_TYPE_NULL);
    /* A null has no scalar of any other kind, which is what makes the
     * failing conversions below meaningful rather than accidental. */
    assert_false(AMitemToInt(item, &integer));
    assert_false(AMitemToStr(item, &view));

    /* A change hash is 32 bytes, and a shorter one is rejected rather than
     * padded: `ChangeHash::try_from(&value)`
     * (`rust/automerge-c/src/item.rs:1470-1472`). */
    uint8_t const hash_bytes[AM_CHANGE_HASH_SIZE] = {0};
    items = AMstackItems(stack_ptr, AMitemFromChangeHash(AMbytes(hash_bytes, AM_CHANGE_HASH_SIZE)), cmocka_cb,
                         AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    item = AMitemsNext(&items, 1);
    AMbyteSpan hash_view;
    assert_true(AMitemToChangeHash(item, &hash_view));
    assert_int_equal(hash_view.count, AM_CHANGE_HASH_SIZE);
    assert_memory_equal(hash_view.src, hash_bytes, AM_CHANGE_HASH_SIZE);

    AMresult* too_short = AMitemFromChangeHash(AMbytes(hash_bytes, AM_CHANGE_HASH_SIZE - 1));
    assert_int_not_equal(AMresultStatus(too_short), AM_STATUS_OK);
    assert_true(AMresultError(too_short).count > 0);
    AMresultFree(too_short);
}

static void test_AMitemToUnknown(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    /* `AMitemToUnknown` answers `true` only for an item whose value type is
     * `AM_VAL_TYPE_UNKNOWN`, and only then does it write through the
     * out-parameter (`rust/automerge-c/src/item.rs:2139-2158`). Every
     * scalar this library can name has a known type, so the answer is
     * `false` and — the part that is a real ABI assertion — the
     * out-parameter is left exactly as the caller wrote it.
     *
     * An unknown value only arises from a columnar document carrying a
     * value-type byte this build does not implement
     * (`rust/automerge/src/value/arbitrary.rs`), which the C API has no way
     * to construct; that is the one direction this case cannot reach, and it
     * is reached from the *Rust* side in upstream's own tests instead. */
    AMunknownValue const sentinel = {
        .bytes = {.src = (uint8_t const*)"sentinel", .count = 8}, .type_code = 0x5A};

    AMresult* results[5];
    results[0] = AMitemFromNull();
    results[1] = AMitemFromBool(true);
    results[2] = AMitemFromInt(1);
    results[3] = AMitemFromUint(1);
    results[4] = AMitemFromF64(1.0);
    AMvalType const expected[] = {AM_VAL_TYPE_NULL, AM_VAL_TYPE_BOOL, AM_VAL_TYPE_INT, AM_VAL_TYPE_UINT, AM_VAL_TYPE_F64};
    for (size_t i = 0; i != 5; ++i) {
        AMunknownValue value = sentinel;
        AMitem* const item = AMstackItem(stack_ptr, results[i], cmocka_cb, AMexpect(expected[i]));
        assert_int_equal(AMitemValType(item), expected[i]);
        assert_false(AMitemToUnknown(item, &value));
        /* The out-parameter is untouched, both halves of it: a build that
         * wrote a default `AMunknownValue` instead of leaving the struct
         * alone would still answer `false` and would pass a test that only
         * checked the return value. */
        assert_ptr_equal(value.bytes.src, sentinel.bytes.src);
        assert_int_equal(value.bytes.count, sentinel.bytes.count);
        assert_int_equal(value.type_code, sentinel.type_code);
    }
}

/* -------------------------------------------------------------------------
 * AMitems. Rust: rust/automerge-c/src/items.rs:252-270.
 * ------------------------------------------------------------------------- */

static void test_AMitemsAdvance(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMobjId const* const list =
        AMitemObjId(AMstackItem(stack_ptr, AMmapPutObject(doc, AM_ROOT, AMstr("list"), AM_OBJ_TYPE_LIST), cmocka_cb,
                               AMexpect(AM_VAL_TYPE_OBJ_TYPE)));
    /* Appended rather than inserted at zero, so the list reads 0,1,2,3,4
     * and the cursor arithmetic below can be done by hand. */
    for (int i = 0; i != 5; ++i) {
        AMstackItem(NULL, AMlistPutInt(doc, list, i, true, i), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    }

    /* `AMitemsAdvance` moves the cursor without yielding an item
     * (`src/items.rs:252-270`). Skipping two and then reading gives the
     * third element, which is the whole contract. */
    AMitems items = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_INT));
    assert_int_equal(AMitemsSize(&items), 5);
    AMitemsAdvance(&items, 2);
    AMitem* item = AMitemsNext(&items, 1);
    int64_t value;
    assert_true(AMitemToInt(item, &value));
    assert_int_equal(value, 2);

    /* The count is a property of the underlying sequence, not of the cursor
     * position, so advancing does not change it. */
    assert_int_equal(AMitemsSize(&items), 5);

    /* A reversed cursor runs the other way, and the sign of `n` is relative
     * to that direction (`src/items.rs:252-259`, `Detail::reversed` at
     * `:93-99`). By hand: the forward cursor is at offset 3, `reversed()`
     * makes that `-(3 + 1) = -4`, `advance(1)` on a reversed cursor subtracts
     * and clips to `-(len + 1) = -6` so lands on -5, and `get_index()`
     * (`:58-65`) reads `-5 + 5 = 0`. So the answer is the first element, not
     * the one after it. */
    AMitems reversed = AMitemsReversed(&items);
    AMitemsAdvance(&reversed, 1);
    assert_true(AMitemToInt(AMitemsNext(&reversed, 1), &value));
    assert_int_equal(value, 0);

    /* Advancing past the end clamps rather than running off
     * (`include/automerge.h:750`, "clamped to its stop"). **Clamping lands on
     * the stop, and the stop yields nothing**: `Detail::advance` with a
     * forward cursor is `unclipped.clamp(0, len)` (`src/items.rs:52-54`), so
     * `advance(1000)` on a five-item cursor puts the offset at exactly `len`,
     * which is where `is_stopped` is true (`:78-81`). */
    AMitems clamped = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb,
                                   AMexpect(AM_VAL_TYPE_INT));
    AMitemsAdvance(&clamped, 1000);
    assert_null(AMitemsNext(&clamped, 1));
    /* And backing off the forward stop does not come back to the start: the
     * same `advance` computes `unclipped = offset - n`, and a result below
     * zero is clipped to `-(len + 1)`, the *before-start* stop
     * (`src/items.rs:49-51`), which is stopped for the same reason
     * (`:78-81`). So the answer is nothing. */
    AMitemsAdvance(&clamped, -1000);
    assert_null(AMitemsNext(&clamped, 1));
    /* `AMitemsRewound` is a *reversed* cursor's rewind, not a reset
     * (`src/items.rs:101-107`): the offset is `-1`, which is the **last**
     * element and not the first. `get_index` reads `-1 + len = 4` (`:58-65`).
     */
    AMitems rewound = AMitemsRewound(&clamped);
    assert_true(AMitemToInt(AMitemsNext(&rewound, 1), &value));
    assert_int_equal(value, 4);
}

/* -------------------------------------------------------------------------
 * Lists. Rust: rust/automerge-c/src/doc/list.rs:32-59, :198-243, :328-368.
 * ------------------------------------------------------------------------- */

static void test_AMlistDelete(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMobjId const* const list =
        AMitemObjId(AMstackItem(stack_ptr, AMmapPutObject(doc, AM_ROOT, AMstr("list"), AM_OBJ_TYPE_LIST), cmocka_cb,
                               AMexpect(AM_VAL_TYPE_OBJ_TYPE)));
    for (int i = 0; i != 4; ++i) {
        AMstackItem(NULL, AMlistPutInt(doc, list, i, true, i), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    }
    assert_int_equal(AMobjSize(doc, list, NULL), 4);

    /* `AMlistDelete` deletes the item at `pos` (`src/doc/list.rs:32-59`). */
    AMstackItem(NULL, AMlistDelete(doc, list, 1), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    assert_int_equal(AMobjSize(doc, list, NULL), 3);
    /* `SIZE_MAX` is the documented spelling for the last item
     * (`src/doc/list.rs:37-41`), and `adjust!` is how the reference turns
     * that into a position (`src/doc/list.rs:11-21`): for a delete,
     * `insert` is false, so `end = len - 1` and the position is
     * `min(pos, end)`. **`SIZE_MAX` is therefore `len - 1`, the last index,
     * and not "past the end"** — so the element that goes is index 2 of
     * [0, 2, 3], which is the value 3, and what is left is [0, 2]. */
    AMstackItem(NULL, AMlistDelete(doc, list, SIZE_MAX), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    assert_int_equal(AMobjSize(doc, list, NULL), 2);

    AMitems remaining = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb,
                                     AMexpect(AM_VAL_TYPE_INT));
    int64_t value;
    assert_true(AMitemToInt(AMitemsNext(&remaining, 1), &value));
    assert_int_equal(value, 0);
    assert_true(AMitemToInt(AMitemsNext(&remaining, 1), &value));
    assert_int_equal(value, 2);
    assert_null(AMitemsNext(&remaining, 1));
}

static void test_AMlistPutBool(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMobjId const* const list =
        AMitemObjId(AMstackItem(stack_ptr, AMmapPutObject(doc, AM_ROOT, AMstr("list"), AM_OBJ_TYPE_LIST), cmocka_cb,
                               AMexpect(AM_VAL_TYPE_OBJ_TYPE)));

    /* `AMlistPutBool` takes the same `insert` flag as every other list put
     * (`src/doc/list.rs:198-243`): `true` splices in, `false` overwrites.
     * The pair is what distinguishes the two, so a build that ignored the
     * flag would fail the size assertion after the overwrite. */
    AMstackItem(NULL, AMlistPutBool(doc, list, 0, true, true), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMlistPutBool(doc, list, 1, true, false), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    assert_int_equal(AMobjSize(doc, list, NULL), 2);

    AMstackItem(NULL, AMlistPutBool(doc, list, 0, false, false), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    assert_int_equal(AMobjSize(doc, list, NULL), 2);

    AMitems items = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_BOOL));
    bool flag;
    assert_true(AMitemToBool(AMitemsNext(&items, 1), &flag));
    assert_false(flag);
    assert_true(AMitemToBool(AMitemsNext(&items, 1), &flag));
    assert_false(flag);
}

static void test_AMlistPutF64(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMobjId const* const list =
        AMitemObjId(AMstackItem(stack_ptr, AMmapPutObject(doc, AM_ROOT, AMstr("list"), AM_OBJ_TYPE_LIST), cmocka_cb,
                               AMexpect(AM_VAL_TYPE_OBJ_TYPE)));
    AMstackItem(NULL, AMlistPutF64(doc, list, 0, true, 1.5), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMlistPutF64(doc, list, 1, true, -0.25), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));

    AMitems items = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_F64));
    double value;
    assert_true(AMitemToF64(AMitemsNext(&items, 1), &value));
    assert_true(value == 1.5);
    assert_true(AMitemToF64(AMitemsNext(&items, 1), &value));
    assert_true(value == -0.25);

    /* An overwrite replaces in place; a `double` is 64 bits wide, so a
     * build that passed it as a 32-bit float would fail on the low word. */
    AMstackItem(NULL, AMlistPutF64(doc, list, 0, false, 1.0 / 3.0), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    assert_int_equal(AMobjSize(doc, list, NULL), 2);
    items = AMstackItems(stack_ptr, AMlistRange(doc, list, 0, SIZE_MAX, NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_F64));
    assert_true(AMitemToF64(AMitemsNext(&items, 1), &value));
    assert_true(value == 1.0 / 3.0);
}

/* -------------------------------------------------------------------------
 * Enumeration strings. Rust: rust/automerge-c/src/utils/enum_string.rs, with
 * the tag values from rust/automerge-c/src/doc/mark.rs:40-51.
 * ------------------------------------------------------------------------- */

static void test_AMmarkExpand_strings(void** state) {
    (void)state;
    /* The generated `ToString`/`FromString` pair for `AMmarkExpand`
     * (`rust/automerge-c/build.rs:10-20`). The tag numbering is not
     * sequential — `After = 3`, `Before = 2`, `Both = 4`, `Default = 0`,
     * `None = 1` (`rust/automerge-c/src/doc/mark.rs:40-51`) — so this case
     * pins each spelling to its own number rather than to its position. */
    assert_string_equal(AMmarkExpandToString(AM_MARK_EXPAND_AFTER), "AM_MARK_EXPAND_AFTER");
    assert_string_equal(AMmarkExpandToString(AM_MARK_EXPAND_BEFORE), "AM_MARK_EXPAND_BEFORE");
    assert_string_equal(AMmarkExpandToString(AM_MARK_EXPAND_BOTH), "AM_MARK_EXPAND_BOTH");
    assert_string_equal(AMmarkExpandToString(AM_MARK_EXPAND_DEFAULT), "AM_MARK_EXPAND_DEFAULT");
    assert_string_equal(AMmarkExpandToString(AM_MARK_EXPAND_NONE), "AM_MARK_EXPAND_NONE");
    /* A tag outside the enumeration is the "???" spelling the other five
     * pairs use (`rust/automerge-c/test/enum_string_tests.c:30`). */
    assert_string_equal(AMmarkExpandToString((AMmarkExpand)99), "???");

    struct {
        char const* text;
        AMmarkExpand expected;
    } const round_trip[] = {
        {"AM_MARK_EXPAND_AFTER", AM_MARK_EXPAND_AFTER},
        {"AM_MARK_EXPAND_BEFORE", AM_MARK_EXPAND_BEFORE},
        {"AM_MARK_EXPAND_BOTH", AM_MARK_EXPAND_BOTH},
        {"AM_MARK_EXPAND_DEFAULT", AM_MARK_EXPAND_DEFAULT},
        {"AM_MARK_EXPAND_NONE", AM_MARK_EXPAND_NONE},
    };
    for (size_t i = 0; i != sizeof(round_trip) / sizeof(round_trip[0]); ++i) {
        AMmarkExpand tag = AM_MARK_EXPAND_NONE;
        assert_true(AMmarkExpandFromString(&tag, round_trip[i].text));
        assert_int_equal(tag, round_trip[i].expected);
    }
    AMmarkExpand unused = AM_MARK_EXPAND_NONE;
    assert_false(AMmarkExpandFromString(&unused, "AM_MARK_EXPAND_SOMETIMES"));
    assert_int_equal(unused, AM_MARK_EXPAND_NONE);
}

/* -------------------------------------------------------------------------
 * AMresult. Rust: rust/automerge-c/src/result.rs:484-525.
 * ------------------------------------------------------------------------- */

static void test_AMresultCat(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    AMresult* const left = AMitemFromStr(AMstr("a"));
    AMresult* const right = AMitemFromStr(AMstr("b"));
    /* `AMresultCat` answers with dest's items in order followed by src's
     * (`src/result.rs:484-525`). The order is the assertion; a
     * concatenation that sorted or reversed would still have size 2. */
    AMresult* const joined = AMresultCat(left, right);
    assert_int_equal(AMresultStatus(joined), AM_STATUS_OK);
    assert_int_equal(AMresultSize(joined), 2);
    AMitems items = AMresultItems(joined);
    AMbyteSpan text;
    assert_true(AMitemToStr(AMitemsNext(&items, 1), &text));
    assert_int_equal(text.count, 1);
    assert_int_equal(text.src[0], 'a');
    assert_true(AMitemToStr(AMitemsNext(&items, 1), &text));
    assert_int_equal(text.count, 1);
    assert_int_equal(text.src[0], 'b');
    assert_null(AMitemsNext(&items, 1));
    AMresultFree(joined);

    /* `AMresultCat` borrows both arguments: it clones their items, so
     * freeing the concatenation must not have consumed them. */
    assert_int_equal(AMresultSize(left), 1);
    assert_int_equal(AMresultSize(right), 1);
    AMstackItem(stack_ptr, left, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
    AMstackItem(stack_ptr, right, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));

    /* An error on either side is an error, not a partial concatenation
     * (`src/result.rs:517-519`). The error side does not have to be second:
     * the match at `:507-520` sends both orders to the same error result. */
    AMresult* const bad = AMload((uint8_t const*)"not a document", 13);
    assert_int_not_equal(AMresultStatus(bad), AM_STATUS_OK);
    AMresult* const good = AMitemFromStr(AMstr("a"));
    AMresult* const joined_error = AMresultCat(good, bad);
    assert_int_equal(AMresultStatus(joined_error), AM_STATUS_ERROR);
    AMresult* const joined_error_reversed = AMresultCat(bad, good);
    assert_int_equal(AMresultStatus(joined_error_reversed), AM_STATUS_ERROR);
    AMresultFree(joined_error);
    AMresultFree(joined_error_reversed);
    AMresultFree(good);
    AMresultFree(bad);

    /* A null on either side is an error too (`src/result.rs:521-523`), and
     * so is a pair of nulls. */
    AMresult* const present = AMitemFromStr(AMstr("a"));
    AMresult* const joined_null = AMresultCat(NULL, present);
    assert_int_equal(AMresultStatus(joined_null), AM_STATUS_ERROR);
    AMresultFree(joined_null);
    AMresult* const joined_both_null = AMresultCat(NULL, NULL);
    assert_int_equal(AMresultStatus(joined_both_null), AM_STATUS_ERROR);
    AMresultFree(joined_both_null);
    /* `present` was borrowed, not consumed, so it is still readable. */
    assert_int_equal(AMresultSize(present), 1);
    AMstackItem(stack_ptr, present, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
}

/* -------------------------------------------------------------------------
 * AMstack. Rust: rust/automerge-c/src/utils/stack.c:95-106.
 * ------------------------------------------------------------------------- */

static void test_AMstackSize(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    /* `AMstackSize` walks the node chain and answers 0 for a null stack
     * (`src/utils/stack.c:95-106`). */
    assert_int_equal(AMstackSize(NULL), 0);
    assert_int_equal(AMstackSize(*stack_ptr), 0);

    AMstackItem(stack_ptr, AMcreate(NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_DOC));
    assert_int_equal(AMstackSize(*stack_ptr), 1);
    AMstackItem(stack_ptr, AMitemFromInt(1), cmocka_cb, AMexpect(AM_VAL_TYPE_INT));
    AMstackItem(stack_ptr, AMitemFromInt(2), cmocka_cb, AMexpect(AM_VAL_TYPE_INT));
    assert_int_equal(AMstackSize(*stack_ptr), 3);

    /* A real stack takes the node *before* the result is examined
     * (`src/utils/stack.c:53-58`), so a result the callback rejects is still
     * counted: it stays on the stack for `AMstackFree` rather than leaking
     * (`:59-63`). `AMresultFrom(0)` is the rejected case — upstream's
     * `result` variable is never assigned for a zero count
     * (`rust/automerge-c/src/utils/result.c:6`, `:9-32`) — and it is also
     * the null-result path at `:76-81`. */
    assert_null(AMstackResult(stack_ptr, AMresultFrom(0), NULL, NULL));
    assert_int_equal(AMstackSize(*stack_ptr), 4);

    /* With no stack at all nothing is tracked and the result is freed on the
     * spot (`src/utils/stack.c:36-52`), so the count cannot move. */
    assert_null(AMstackResult(NULL, AMitemFromInt(9), NULL, NULL));
    assert_int_equal(AMstackSize(*stack_ptr), 4);
}

/* -------------------------------------------------------------------------
 * Sync. Rust: rust/automerge-c/src/sync/{message,state}.rs.
 * ------------------------------------------------------------------------- */

static void test_AMsyncMessage_encode_decode(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMbyteSpan const head = single_head(stack_ptr, doc);

    AMsyncState* state_a;
    assert_true(AMitemToSyncState(AMstackItem(stack_ptr, AMsyncStateInit(), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_STATE)),
                                  &state_a));
    AMsyncMessage const* sent;
    assert_true(AMitemToSyncMessage(
        AMstackItem(stack_ptr, AMgenerateSyncMessage(doc, state_a), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_MESSAGE)),
        &sent));

    AMitems heads_before = AMstackItems(stack_ptr, AMsyncMessageHeads(sent), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&heads_before), 1);
    AMitems haves_before = AMstackItems(stack_ptr, AMsyncMessageHaves(sent), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_HAVE));
    assert_true(AMitemsSize(&haves_before) > 0);
    AMitems needs_before = AMstackItems(stack_ptr, AMsyncMessageNeeds(sent), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&needs_before), 0);

    /* `AMsyncMessageEncode` serialises the message to bytes
     * (`src/sync/message.rs:69-85`) and `AMsyncMessageDecode` parses them
     * back (`src/sync/message.rs:48-67`). The three payload lists are
     * compared item for item, because "the bytes differ" would not catch a
     * decoder that dropped the need list. */
    AMbyteSpan encoded;
    assert_true(AMitemToBytes(AMstackItem(stack_ptr, AMsyncMessageEncode(sent), cmocka_cb, AMexpect(AM_VAL_TYPE_BYTES)),
                              &encoded));
    assert_true(encoded.count > 0);

    AMsyncMessage const* decoded;
    assert_true(AMitemToSyncMessage(AMstackItem(stack_ptr, AMsyncMessageDecode(encoded.src, encoded.count), cmocka_cb,
                                                 AMexpect(AM_VAL_TYPE_SYNC_MESSAGE)),
                                    &decoded));

    /* All three payload lists, item for item, because "the bytes round-trip"
     * would not catch a decoder that dropped the need list or reordered the
     * heads. The heads are also checked against the document's own head, so
     * a decoder that invented a hash would fail too. */
    AMitems heads_after = AMstackItems(stack_ptr, AMsyncMessageHeads(decoded), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&heads_after), AMitemsSize(&heads_before));
    AMbyteSpan lhs, rhs;
    assert_true(AMitemToChangeHash(AMitemsNext(&heads_after, 1), &lhs));
    assert_true(AMitemToChangeHash(AMitemsNext(&heads_before, 1), &rhs));
    assert_int_equal(lhs.count, rhs.count);
    assert_memory_equal(lhs.src, rhs.src, lhs.count);
    assert_memory_equal(lhs.src, head.src, head.count);

    AMitems haves_after = AMstackItems(stack_ptr, AMsyncMessageHaves(decoded), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_HAVE));
    assert_int_equal(AMitemsSize(&haves_after), AMitemsSize(&haves_before));

    AMitems needs_after = AMstackItems(stack_ptr, AMsyncMessageNeeds(decoded), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&needs_after), AMitemsSize(&needs_before));
}

static void test_AMsyncStateEqual_and_their(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;
    AMdoc* doc = make_doc(stack_ptr, "aaaa");
    AMstackItem(NULL, AMmapPutStr(doc, AM_ROOT, AMstr("a"), AMstr("b")), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));
    AMstackItem(NULL, AMcommit(doc, AMstr(""), NULL), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    AMbyteSpan const head = single_head(stack_ptr, doc);

    /* A fresh state has `their_have = None`, `their_heads = None` and
     * `their_need = None`. `State` derives `Default`
     * (`rust/automerge/src/sync/state.rs:32`) and `State::new()` **is**
     * `Default::default()` (`:92-95`), so all three `Option` fields are
     * `None`. The `Some(Vec::new())` at `state.rs:140` is in `State::parse`,
     * which is the **decode** path, not the fresh one.
     *
     * `AMsyncStateTheirHaves` reports the difference through `has_value`
     * (`rust/automerge-c/src/sync/state.rs:190-197`: `if let Some(haves)` …
     * `*has_value = true`, and the `*has_value = false` fallthrough for
     * anything else), and it is the only way a C caller can tell an empty
     * have list from an absent one — so a fresh state must say `false`. */
    AMsyncState* fresh;
    assert_true(AMitemToSyncState(AMstackItem(stack_ptr, AMsyncStateInit(), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_STATE)),
                                  &fresh));
    bool has_value = true;
    AMitems haves = AMstackItems(stack_ptr, AMsyncStateTheirHaves(fresh, &has_value), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_HAVE));
    assert_false(has_value);
    assert_int_equal(AMitemsSize(&haves), 0);
    has_value = true;
    AMitems their_heads = AMstackItems(stack_ptr, AMsyncStateTheirHeads(fresh, &has_value), cmocka_cb,
                                       AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_false(has_value);
    assert_int_equal(AMitemsSize(&their_heads), 0);
    has_value = true;
    AMitems their_needs = AMstackItems(stack_ptr, AMsyncStateTheirNeeds(fresh, &has_value), cmocka_cb,
                                       AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_false(has_value);
    assert_int_equal(AMitemsSize(&their_needs), 0);

    /* `AMsyncStateEqual` compares the whole state
     * (`rust/automerge-c/src/sync/state.rs:100-119`), so two fresh states
     * are equal and a state that has generated a message is not. */
    AMsyncState* other;
    assert_true(AMitemToSyncState(AMstackItem(stack_ptr, AMsyncStateInit(), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_STATE)),
                                  &other));
    assert_true(AMsyncStateEqual(fresh, other));
    assert_false(AMsyncStateEqual(fresh, NULL));

    AMsyncState* peer;
    assert_true(AMitemToSyncState(AMstackItem(stack_ptr, AMsyncStateInit(), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_STATE)),
                                  &peer));
    AMsyncMessage const* message;
    assert_true(AMitemToSyncMessage(
        AMstackItem(stack_ptr, AMgenerateSyncMessage(doc, peer), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_MESSAGE)),
        &message));
    assert_false(AMsyncStateEqual(fresh, peer));
    AMstackItem(stack_ptr, AMreceiveSyncMessage(doc, fresh, message), cmocka_cb, AMexpect(AM_VAL_TYPE_VOID));

    /* After the exchange, `their_heads` is the peer's head
     * (`rust/automerge/src/sync/state.rs:39`), which is exactly the hash the
     * document committed. */
    has_value = false;
    their_heads = AMstackItems(stack_ptr, AMsyncStateTheirHeads(fresh, &has_value), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_true(has_value);
    assert_int_equal(AMitemsSize(&their_heads), 1);
    AMbyteSpan theirs;
    assert_true(AMitemToChangeHash(AMitemsNext(&their_heads, 1), &theirs));
    assert_memory_equal(theirs.src, head.src, head.count);

    /* `their_need` becomes `Some` as soon as a message arrives, even when
     * the need list is empty: the peer asked for nothing, which is not the
     * same as having not asked. */
    has_value = false;
    their_needs = AMstackItems(stack_ptr, AMsyncStateTheirNeeds(fresh, &has_value), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_true(has_value);
    assert_int_equal(AMitemsSize(&their_needs), 0);

    /* The shared heads are what both peers now have in common. */
    AMitems shared = AMstackItems(stack_ptr, AMsyncStateSharedHeads(fresh), cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));
    assert_int_equal(AMitemsSize(&shared), 1);
    AMbyteSpan common;
    assert_true(AMitemToChangeHash(AMitemsNext(&shared, 1), &common));
    assert_memory_equal(common.src, head.src, head.count);
}

/* -------------------------------------------------------------------------
 * What a null handle answers, what a null pointer is worth, and who owns
 * what. These are the contracts `include/automerge.h` states and the
 * vendored suite never reaches, because upstream's own tests never pass the
 * arguments in the first place.
 * ------------------------------------------------------------------------- */

/* The reference hard-codes these error strings and a C caller is allowed to
 * match on them (`src/result.rs:466`, `src/sync/message.rs:17`,
 * `src/sync/state.rs:13`). The span is **not** NUL-terminated
 * (`src/result.rs:544`), so the length is compared rather than the string. */
static void assert_error_message(AMresult* result, char const* expected) {
    assert_non_null(result);
    assert_int_equal(AMresultStatus(result), AM_STATUS_ERROR);
    AMbyteSpan const message = AMresultError(result);
    assert_int_equal(message.count, strlen(expected));
    assert_memory_equal(message.src, expected, strlen(expected));
}

static void test_enum_FromString_null_destination(void** state) {
    (void)state;
    /* A `NULL` out-parameter is `false`, and not a dereference
     * (`src/c/result.zig`). The generated body writes `*dest` as its first
     * act inside the matching branch
     * (`cmake/enum-string-functions-gen.cmake:71-74`), so a name that *does*
     * match is the case that would trap — which is why these pass names that
     * match rather than names that do not. Upstream's own generated header
     * declares `AMxxx *dest` with nothing a caller could act on. */
    assert_false(AMobjTypeFromString(NULL, "AM_OBJ_TYPE_MAP"));
    assert_false(AMmarkExpandFromString(NULL, "AM_MARK_EXPAND_BOTH"));
    assert_false(AMidxTypeFromString(NULL, "AM_IDX_TYPE_POS"));
    assert_false(AMvalTypeFromString(NULL, "AM_VAL_TYPE_CURSOR"));
    assert_false(AMstatusFromString(NULL, "AM_STATUS_ERROR"));

    /* The other two refusals, so the arm is pinned as a set: a `NULL` source
     * and an unknown name both leave a pre-set destination exactly as it was
     * (`test/enum_string_tests.c:38-40`). */
    AMobjType tag = AM_OBJ_TYPE_DEFAULT;
    assert_false(AMobjTypeFromString(&tag, NULL));
    assert_int_equal(tag, AM_OBJ_TYPE_DEFAULT);
    assert_false(AMobjTypeFromString(&tag, "AM_OBJ_TYPE_MA"));
    assert_int_equal(tag, AM_OBJ_TYPE_DEFAULT);
    assert_true(AMobjTypeFromString(&tag, "AM_OBJ_TYPE_MAP"));
    assert_int_equal(tag, AM_OBJ_TYPE_MAP);
}

static void test_AMbytes_null_normalises_count(void** state) {
    (void)state;
    /* The precondition is on `src`, not on `count`. A null pointer
     * normalises the whole span to `{NULL, 0}` (`src/byte_span.rs:179`), so
     * this is a call a C caller can make rather than one it must guard. */
    AMbyteSpan const none = AMbytes(NULL, SIZE_MAX);
    assert_null(none.src);
    assert_int_equal(none.count, 0);

    /* A zero count over a real pointer is a *different* span: an empty view
     * over real memory, not the null one, and the two must not be confused. */
    uint8_t const text[] = {'a', 'b', 'c'};
    AMbyteSpan const empty = AMbytes(text, 0);
    assert_ptr_equal(empty.src, text);
    assert_int_equal(empty.count, 0);
}

static void test_AMresultCat_leaves_items_alive(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    AMresult* const left = AMitemFromStr(AMstr("a"));
    AMresult* const right = AMitemFromStr(AMstr("b"));

    /* Take a handle into `left` *before* concatenating. `AMresultCat` is
     * declared `(const AMresult *dest, const AMresult *src)` and takes no
     * `AMitems` at all, and its own note says it leaves both inputs alive
     * (`include/automerge.h`, `src/result.rs:504-525`), so the only thing
     * that can invalidate this pointer is `AMresultFree`. */
    AMitem* const borrowed = AMresultItem(left);
    assert_non_null(borrowed);

    AMresult* const joined = AMresultCat(left, right);
    assert_int_equal(AMresultStatus(joined), AM_STATUS_OK);
    assert_int_equal(AMresultSize(joined), 2);

    /* Still live, still the same cell, still readable. */
    assert_int_equal(AMresultStatus(left), AM_STATUS_OK);
    assert_int_equal(AMresultSize(left), 1);
    assert_ptr_equal(AMresultItem(left), borrowed);
    AMbyteSpan text;
    assert_true(AMitemToStr(borrowed, &text));
    assert_int_equal(text.count, 1);
    assert_int_equal(text.src[0], 'a');

    /* The concatenation is a *different* array of items, because `cat`
     * clones the reference counts rather than moving them
     * (`src/result.rs:507-511`). Freeing one does not touch the other. */
    assert_ptr_not_equal(AMresultItem(joined), borrowed);
    AMresultFree(joined);
    assert_int_equal(AMresultSize(left), 1);
    assert_true(AMitemToStr(AMresultItem(left), &text));
    assert_int_equal(text.src[0], 'a');

    AMstackItem(stack_ptr, left, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
    AMstackItem(stack_ptr, right, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
}

static void test_AMresultFrom_empty_and_negative(void** state) {
    (void)state;
    /* One `NULL` answers two different situations, and `count` is the only
     * way a caller can tell them apart (`include/automerge.h`). Upstream's
     * `result` starts as `NULL` and the loop never runs
     * (`src/utils/result.c:6`, `:29-32`), so the empty call is one of them;
     * a negative count is the other, because upstream's loop
     * `for (int i = 0; i != count; ++i)` (`result.c:10`) would run until the
     * index wraps and read that many garbage pointers. */
    assert_null(AMresultFrom(0));
    assert_null(AMresultFrom(-1));

    /* One real argument: the result is the caller's, and the argument is
     * consumed — freed — whether or not the call succeeded
     * (`src/utils/result.c:12-25`, `include/automerge-c/utils/result.h:22-24`). */
    AMresult* const single = AMresultFrom(1, AMitemFromStr(AMstr("a")));
    assert_int_equal(AMresultStatus(single), AM_STATUS_OK);
    assert_int_equal(AMresultSize(single), 1);
    AMresultFree(single);

    /* The other `NULL`, from an argument that was not OK — and freed on the
     * way out like every other argument. */
    assert_null(AMresultFrom(1, AMload((uint8_t const*)"not a document", 13)));
}

static void test_AMactorIdStr_is_stable_and_total(void** state) {
    (void)state;
    char const actor_hex[] = "0123456789abcdef0123456789abcdef";
    AMresult* const result = AMactorIdFromStr(AMstr(actor_hex));
    assert_int_equal(AMresultStatus(result), AM_STATUS_OK);
    AMactorId const* actor_id;
    assert_true(AMitemToActorId(AMresultItem(result), &actor_id));

    /* The hex is staged when the handle is built (`src/c/doc.zig`), so two
     * calls answer the same pointer with the same bytes. A hex computed on
     * first use would have to swallow an allocation failure, and the only
     * thing an `AMbyteSpan` can say about that is that it is empty — which
     * is indistinguishable from a legitimately empty span. */
    AMbyteSpan const first = AMactorIdStr(actor_id);
    AMbyteSpan const second = AMactorIdStr(actor_id);
    assert_ptr_equal(first.src, second.src);
    assert_int_equal(first.count, strlen(actor_hex));
    assert_memory_equal(first.src, actor_hex, strlen(actor_hex));

    /* A null handle is the zero span, and it is the only way this function
     * answers with one. */
    AMbyteSpan const none = AMactorIdStr(NULL);
    assert_null(none.src);
    assert_int_equal(none.count, 0);

    /* The round trip the hex exists for, which under an allocation failure
     * would have read as invalid input rather than as a failure. */
    AMresult* const round_trip = AMactorIdFromStr(first);
    assert_int_equal(AMresultStatus(round_trip), AM_STATUS_OK);
    AMactorId const* parsed;
    assert_true(AMitemToActorId(AMresultItem(round_trip), &parsed));
    AMbyteSpan const again = AMactorIdStr(parsed);
    assert_int_equal(again.count, first.count);
    assert_memory_equal(again.src, first.src, first.count);

    AMresultFree(round_trip);
    AMresultFree(result);
}

static void test_null_handle_answers(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    /* `AMchange`: the sentinels are upstream's own answers and are not
     * distinguishable from real values (`src/change.rs:241`, `:261`,
     * `:279`, `:298`, `:316`, `:335`), so a caller forwarding an optional
     * change has to check the handle first. */
    assert_int_equal(AMchangeMaxOp(NULL), UINT64_MAX);
    assert_int_equal(AMchangeSeq(NULL), UINT64_MAX);
    assert_int_equal(AMchangeStartOp(NULL), UINT64_MAX);
    assert_int_equal(AMchangeTime(NULL), INT64_MAX);
    assert_int_equal(AMchangeSize(NULL), 0);
    assert_true(AMchangeIsEmpty(NULL));
    AMbyteSpan const no_footer = AMchangeExtraBytes(NULL);
    assert_null(no_footer.src);
    assert_int_equal(no_footer.count, 0);
    AMbyteSpan const no_message = AMchangeMessage(NULL);
    assert_null(no_message.src);
    assert_int_equal(no_message.count, 0);

    /* Sync readers: a null handle is an empty *success*, because upstream's
     * `None => Default::default()` arm turns an empty slice into an empty
     * result (`src/sync/have.rs:37-40`, `src/sync/message.rs:98`, `:118`,
     * `:139`). */
    AMresult* const empty_have = AMsyncHaveLastSync(NULL);
    assert_int_equal(AMresultStatus(empty_have), AM_STATUS_OK);
    assert_int_equal(AMresultSize(empty_have), 0);
    AMstackItem(stack_ptr, empty_have, cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));

    AMresult* const empty_needs = AMsyncMessageNeeds(NULL);
    assert_int_equal(AMresultStatus(empty_needs), AM_STATUS_OK);
    assert_int_equal(AMresultSize(empty_needs), 0);
    AMstackItem(stack_ptr, empty_needs, cmocka_cb, AMexpect(AM_VAL_TYPE_CHANGE_HASH));

    /* The two encoders are the other kind: an error result carrying the
     * reference's hard-coded message (`src/sync/message.rs:12-19`,
     * `src/sync/state.rs:8-15`). */
    AMresult* const refused_message = AMsyncMessageEncode(NULL);
    assert_error_message(refused_message, "Invalid `AMsyncMessage*`");
    AMresultFree(refused_message);

    AMresult* const refused_state = AMsyncStateEncode(NULL);
    assert_error_message(refused_state, "Invalid `AMsyncState*`");
    AMresultFree(refused_state);

    /* Two null states are not equal — the one place in the ABI where a null
     * is a distinct answer rather than an absence
     * (`src/sync/state.rs:105`, `:118`). */
    assert_false(AMsyncStateEqual(NULL, NULL));

    /* A null out-parameter is an error result and not undefined behaviour
     * (`src/c/sync.zig`): upstream writes through it unconditionally
     * (`src/sync/state.rs:186-201`). */
    AMsyncState* sync_state;
    assert_true(AMitemToSyncState(AMstackItem(stack_ptr, AMsyncStateInit(), cmocka_cb, AMexpect(AM_VAL_TYPE_SYNC_STATE)),
                                  &sync_state));
    AMresult* const refused_out = AMsyncStateTheirHaves(sync_state, NULL);
    assert_error_message(refused_out, "Invalid `bool*`");
    AMresultFree(refused_out);
    AMresult* const refused_out_needs = AMsyncStateTheirNeeds(sync_state, NULL);
    assert_error_message(refused_out_needs, "Invalid `bool*`");
    AMresultFree(refused_out_needs);

    /* `AMmarkCreate`: a null value is an error result, not the segfault
     * upstream's unchecked dereference at `src/doc/mark.rs:250` would be.
     * A wrapper that guards the pointer before the call is right to. */
    AMdoc* const doc = make_doc(stack_ptr, "aaaa");
    AMobjId const* const obj_id = AMitemObjId(AMstackItem(stack_ptr,
                                                          AMmapPutObject(doc, AM_ROOT, AMstr("text"), AM_OBJ_TYPE_TEXT),
                                                          cmocka_cb, AMexpect(AM_VAL_TYPE_OBJ_TYPE)));
    AMstackItem(stack_ptr, AMspliceText(doc, obj_id, 0, 0, AMstr("hello world")), cmocka_cb,
                AMexpect(AM_VAL_TYPE_VOID));
    AMresult* const refused_mark = AMmarkCreate(doc, obj_id, 0, 5, AM_MARK_EXPAND_BOTH, AMstr("bold"), NULL);
    assert_error_message(refused_mark, "Invalid `AMitem*`");
    AMresultFree(refused_mark);
}

static void test_utility_layer_ownership(void** state) {
    BaseState* base_state = *state;
    AMstack** stack_ptr = &base_state->stack;

    /* `AMstrdup` returns a `malloc` allocation, not a borrow into a result,
     * and `free()` is the release the header promises
     * (`include/automerge-c/utils/string.h:24-25`). `AMstr()` would stop at
     * the NUL, so the span is built by hand to reach the substitution. */
    uint8_t const raw[] = {'a', 0, 'b'};
    char* const copy = AMstrdup(AMbytes(raw, sizeof raw), NULL);
    assert_non_null(copy);
    assert_string_equal(copy, "a\\0b");
    free(copy);
    /* A null source is a null answer, not an empty string. */
    assert_null(AMstrdup(AMbytes(NULL, 0), NULL));

    /* `AMstackFree` releases every result on the stack and nulls the caller's
     * pointer, and a result taken back off belongs to the caller again. */
    AMstack* stack = NULL;
    AMresult* const kept = AMitemFromStr(AMstr("kept"));
    AMresult* const dropped = AMitemFromStr(AMstr("dropped"));
    AMstackResult(&stack, kept, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
    AMstackResult(&stack, dropped, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));
    assert_int_equal(AMstackSize(stack), 2);
    AMresult* const popped = AMstackPop(&stack, NULL);
    assert_ptr_equal(popped, dropped);
    assert_int_equal(AMstackSize(stack), 1);
    AMstackFree(&stack);
    assert_null(stack);
    /* `dropped` was popped, so the stack never freed it and it is still the
     * caller's to release. */
    assert_int_equal(AMresultStatus(dropped), AM_STATUS_OK);
    AMstackItem(stack_ptr, dropped, cmocka_cb, AMexpect(AM_VAL_TYPE_STR));

    /* A null stack frees what it is handed rather than leaking it
     * (`src/utils/stack.c:50-51`). */
    AMresult* const orphan = AMitemFromStr(AMstr("orphan"));
    assert_null(AMstackResult(NULL, orphan, cmocka_cb, AMexpect(AM_VAL_TYPE_STR)));
}

int run_abi_coverage_tests(void) {
    const struct CMUnitTest tests[] = {
        cmocka_unit_test_setup_teardown(test_AMchange_scalars, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMchange_hash_and_bytes, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMchangeCompress, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMchangeLoadDocument, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMgetChangesAdded, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMrollback, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMitemFrom_scalars, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMitemToUnknown, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMitemsAdvance, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMlistDelete, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMlistPutBool, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMlistPutF64, setup_base, teardown_base),
        cmocka_unit_test(test_AMmarkExpand_strings),
        cmocka_unit_test_setup_teardown(test_AMresultCat, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMstackSize, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMsyncMessage_encode_decode, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_AMsyncStateEqual_and_their, setup_base, teardown_base),
        cmocka_unit_test(test_enum_FromString_null_destination),
        cmocka_unit_test(test_AMbytes_null_normalises_count),
        cmocka_unit_test(test_AMactorIdStr_is_stable_and_total),
        cmocka_unit_test_setup_teardown(test_AMresultCat_leaves_items_alive, setup_base, teardown_base),
        cmocka_unit_test(test_AMresultFrom_empty_and_negative),
        cmocka_unit_test_setup_teardown(test_null_handle_answers, setup_base, teardown_base),
        cmocka_unit_test_setup_teardown(test_utility_layer_ownership, setup_base, teardown_base),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
