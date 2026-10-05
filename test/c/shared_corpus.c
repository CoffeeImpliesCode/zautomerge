#include <automerge.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shared_fixtures.h"

/* Each borrowed handle stays alive until the fixture's owners are released. */
struct owners { AMresult *results[64]; size_t count; const char *fixture; };

static bool fail(struct owners *o, const char *operation) {
    fprintf(stderr, "FAIL %s: %s\n", o->fixture, operation);
    return false;
}

static AMresult *own(struct owners *o, AMresult *r) {
    if (o->count == sizeof(o->results) / sizeof(o->results[0])) {
        AMresultFree(r);
        fail(o, "result owner capacity exceeded");
        return NULL;
    }
    o->results[o->count++] = r;
    return r;
}

static bool ok(struct owners *o, AMresult *r, const char *operation) {
    if (AMresultStatus(r) == AM_STATUS_OK) return true;
    AMbyteSpan error = AMresultError(r);
    fprintf(stderr, "FAIL %s: %s: %.*s\n", o->fixture, operation,
            (int)error.count, error.src ? (const char *)error.src : "null result");
    return false;
}

static AMbyteSpan text(const char *s) {
    return (AMbyteSpan){(const uint8_t *)s, strlen(s)};
}

#define REQUIRE(condition, label) do { if (!(condition)) return fail(o, label); } while (0)
#define RESULT(name, expression) AMresult *name = own(o, expression); \
    if (!ok(o, name, #expression)) return false

static bool heads_equal(struct owners *o, AMdoc *a, AMdoc *b) {
    RESULT(ha, AMgetHeads(a));
    RESULT(hb, AMgetHeads(b));
    AMitems ia = AMresultItems(ha), ib = AMresultItems(hb);
    REQUIRE(AMresultSize(ha) > 0 && AMitemsEqual(&ia, &ib), "equal nonempty heads");
    return true;
}

static bool value_is(struct owners *o, AMdoc *doc, const char *key, int64_t expected) {
    RESULT(value, AMmapGet(doc, AM_ROOT, text(key), NULL));
    int64_t actual = 0;
    REQUIRE(AMresultSize(value) == 1 && AMitemToInt(AMresultItem(value), &actual)
            && actual == expected, "committed integer value");
    return true;
}

static bool write_commit(struct owners *o, AMdoc *doc, const char *key, int64_t value) {
    RESULT(write, AMmapPutInt(doc, AM_ROOT, text(key), value));
    REQUIRE(AMpendingOps(doc) == 1, "one pending transaction operation");
    const int64_t timestamp = 12345;
    RESULT(commit, AMcommit(doc, text("shared corpus gate"), &timestamp));
    AMbyteSpan hash = {0};
    REQUIRE(AMresultSize(commit) == 1 && AMitemToChangeHash(AMresultItem(commit), &hash)
            && hash.count == 32, "commit returns SHA-256 hash");
    REQUIRE(AMpendingOps(doc) == 0, "commit clears pending operations");
    RESULT(heads, AMgetHeads(doc));
    AMbyteSpan head = {0};
    REQUIRE(AMresultSize(heads) == 1 && AMitemToChangeHash(AMresultItem(heads), &head)
            && head.count == hash.count && memcmp(head.src, hash.src, hash.count) == 0,
            "commit hash is the document head");
    RESULT(change_result, AMgetChangeByHash(doc, hash.src, hash.count));
    AMchange *change = NULL;
    REQUIRE(AMitemToChange(AMresultItem(change_result), &change), "commit hash resolves to change");
    AMbyteSpan change_hash = AMchangeHash(change), message = AMchangeMessage(change);
    REQUIRE(change_hash.count == hash.count && memcmp(change_hash.src, hash.src, hash.count) == 0,
            "resolved change hash");
    REQUIRE(AMchangeTime(change) == timestamp && message.count == strlen("shared corpus gate")
            && memcmp(message.src, "shared corpus gate", message.count) == 0,
            "commit timestamp and message");
    return value_is(o, doc, key, value);
}

/* Encode/decode on the wire, not a merge or an in-process message shortcut. */
static bool send_one(struct owners *o, AMdoc *from, AMsyncState *sending,
                     AMdoc *to, AMsyncState *receiving, bool *sent) {
    bool success = false;
    AMresult *generated = AMgenerateSyncMessage(from, sending);
    AMresult *encoded = NULL, *decoded = NULL, *received = NULL;
    const AMsyncMessage *message = NULL, *wire_message = NULL;
    AMbyteSpan bytes = {0};
    *sent = false;
    if (!ok(o, generated, "generate sync message")) goto cleanup;
    if (AMitemValType(AMresultItem(generated)) == AM_VAL_TYPE_VOID) {
        success = true;
        goto cleanup;
    }
    if (!AMitemToSyncMessage(AMresultItem(generated), &message)) {
        fail(o, "generated sync message type"); goto cleanup;
    }
    encoded = AMsyncMessageEncode(message);
    if (!ok(o, encoded, "encode sync message")) goto cleanup;
    if (!AMitemToBytes(AMresultItem(encoded), &bytes) || bytes.count == 0) {
        fail(o, "nonempty encoded sync message"); goto cleanup;
    }
    decoded = AMsyncMessageDecode(bytes.src, bytes.count);
    if (!ok(o, decoded, "decode sync message")) goto cleanup;
    if (!AMitemToSyncMessage(AMresultItem(decoded), &wire_message)) {
        fail(o, "decoded sync message type"); goto cleanup;
    }
    received = AMreceiveSyncMessage(to, receiving, wire_message);
    if (!ok(o, received, "receive sync message")) goto cleanup;
    *sent = true;
    success = true;
cleanup:
    AMresultFree(received);
    AMresultFree(decoded);
    AMresultFree(encoded);
    AMresultFree(generated);
    return success;
}

static bool valid_document(struct owners *o, AMresult *loaded) {
    AMdoc *doc = NULL, *peer = NULL;
    REQUIRE(AMitemToDoc(AMresultItem(loaded), &doc), "loaded document handle");
    RESULT(saved, AMsave(doc));
    AMbyteSpan bytes = {0};
    REQUIRE(AMitemToBytes(AMresultItem(saved), &bytes) && bytes.count > 0, "saved document bytes");
    RESULT(reloaded, AMload(bytes.src, bytes.count));
    REQUIRE(AMitemToDoc(AMresultItem(reloaded), &peer), "reloaded document handle");
    REQUIRE(AMequal(doc, peer), "save/reload document equality");
    if (!heads_equal(o, doc, peer)) return false;
    if (!write_commit(o, doc, "__shared_gate_left", 314159)) return false;
    if (!write_commit(o, peer, "__shared_gate_right", -271828)) return false;
    REQUIRE(!AMequal(doc, peer), "independent commits diverge before sync");
    RESULT(left_owner, AMsyncStateInit());
    RESULT(right_owner, AMsyncStateInit());
    AMsyncState *left = NULL, *right = NULL;
    REQUIRE(AMitemToSyncState(AMresultItem(left_owner), &left)
            && AMitemToSyncState(AMresultItem(right_owner), &right), "sync state handles");
    /* Reach the production library's C-only variadic export as a consumer. */
    RESULT(combined, AMresultFrom(2, AMitemFromInt(17), AMitemFromInt(-19)));
    AMitems combined_items = AMresultItems(combined);
    int64_t first = 0, second = 0;
    REQUIRE(AMresultSize(combined) == 2
            && AMitemToInt(AMitemsNext(&combined_items, 1), &first) && first == 17
            && AMitemToInt(AMitemsNext(&combined_items, 1), &second) && second == -19,
            "variadic result export preserves values");
    size_t left_messages = 0, right_messages = 0;
    bool converged = false;
    for (size_t round = 0; round < 32; ++round) {
        bool sent_left = false, sent_right = false;
        if (!send_one(o, doc, left, peer, right, &sent_left)
            || !send_one(o, peer, right, doc, left, &sent_right)) return false;
        left_messages += sent_left;
        right_messages += sent_right;
        if (!sent_left && !sent_right) { converged = true; break; }
    }
    REQUIRE(converged && left_messages > 0 && right_messages > 0, "bidirectional sync quiesces within 32 rounds");
    REQUIRE(AMequal(doc, peer), "sync document equality");
    if (!heads_equal(o, doc, peer)) return false;
    RESULT(final_heads, AMgetHeads(doc));
    REQUIRE(AMresultSize(final_heads) == 2, "two concurrent commit heads after sync");
    if (!value_is(o, doc, "__shared_gate_left", 314159)
        || !value_is(o, doc, "__shared_gate_right", -271828)
        || !value_is(o, peer, "__shared_gate_left", 314159)
        || !value_is(o, peer, "__shared_gate_right", -271828)) return false;
    fprintf(stderr, "PASS %s: save/reload, commit/hash/value, sync (%zu/%zu messages)\n",
            o->fixture, left_messages, right_messages);
    return true;
}

static bool fixture_case(struct owners *o, bool load_ok) {
    char path[512];
    if (snprintf(path, sizeof(path), "test/fixtures/%s", o->fixture) >= (int)sizeof(path))
        return fail(o, "fixture path too long");
    FILE *file = fopen(path, "rb");
    if (!file) return fail(o, "open fixture");
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return fail(o, "seek fixture"); }
    long length = ftell(file);
    if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return fail(o, "fixture length"); }
    uint8_t *bytes = malloc((size_t)length);
    if (!bytes) { fclose(file); return fail(o, "allocate fixture"); }
    size_t count = fread(bytes, 1, (size_t)length, file);
    int closed = fclose(file);
    if (count != (size_t)length || closed != 0) { free(bytes); return fail(o, "read fixture"); }
    AMresult *loaded = own(o, AMload(bytes, count));
    free(bytes);
    if (!load_ok) {
        REQUIRE(AMresultStatus(loaded) == AM_STATUS_ERROR && AMresultError(loaded).count > 0,
                "manifest requires load error with diagnostic");
        fprintf(stderr, "PASS %s: expected load error\n", o->fixture);
        return true;
    }
    if (!ok(o, loaded, "manifest requires successful load")) return false;
    return valid_document(o, loaded);
}

int shared_corpus_main(void) {
    size_t failures = 0, valid = 0;
    for (size_t i = 0; i < sizeof(shared_fixtures) / sizeof(shared_fixtures[0]); ++i) {
        struct owners owners = {.fixture = shared_fixtures[i].name};
        valid += shared_fixtures[i].load_ok;
        if (!fixture_case(&owners, shared_fixtures[i].load_ok)) ++failures;
        while (owners.count) AMresultFree(owners.results[--owners.count]);
    }
    fprintf(stderr, "shared C corpus: %zu fixtures (%zu valid), %zu failures\n",
            sizeof(shared_fixtures) / sizeof(shared_fixtures[0]), valid, failures);
    return failures ? 1 : 0;
}
