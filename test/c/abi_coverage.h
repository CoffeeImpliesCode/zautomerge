#ifndef ZAUTOMERGE_TEST_C_ABI_COVERAGE_H
#define ZAUTOMERGE_TEST_C_ABI_COVERAGE_H

/* The cases the copied upstream suite never reaches.
 *
 * `rust/automerge-c/test/` leaves forty `AM*` entry points untested: the
 * whole `AMchange` surface, eight of the `AMitemFrom*` constructors,
 * `AMitemToUnknown`, `AMitemsAdvance`, `AMlistDelete`, `AMlistPutBool`,
 * `AMlistPutF64`, both `AMmarkExpand` string functions, `AMresultCat`,
 * `AMgetChangesAdded`, `AMrollback`, `AMstackSize`, `AMsyncMessageEncode`,
 * `AMsyncMessageDecode`, `AMsyncStateEqual` and the three
 * `AMsyncStateTheir*` accessors. An export no case calls is an export no case
 * has tested, and the only side of this ABI that can see a wrong integer
 * width or a mis-declared out-parameter is a C caller. So each one gets a
 * case here, written against the reference's documented behaviour rather
 * than against this port's, and cited to the `path:line` that states it.
 *
 * These are not ports of upstream cases. Upstream has no case for any of
 * them; `AGENTS.md`'s "Port upstream tests case-for-case" does not apply,
 * and the gap these close is one the reference itself leaves.
 */
int run_abi_coverage_tests(void);

#endif /* ZAUTOMERGE_TEST_C_ABI_COVERAGE_H */
