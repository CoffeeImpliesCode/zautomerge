/* `automerge-c/utils/result.h` declares `AMresultFrom` and nothing else
 * (`rust/automerge-c/include/automerge-c/utils/result.h:28`). It is
 * hand-written C, not cbindgen output: the body is
 * `rust/automerge-c/src/utils/result.c:5-24`, which concatenates `count`
 * variadic `AMresult *` arguments with `AMresultCat`
 * (`rust/automerge-c/src/result.rs:503-504`) and frees each one.
 *
 * This port declares `AMresultFrom` at `include/automerge.h:528` and
 * `AMresultCat` at `:418`, so the split header reduces to the one include.
 * See `../automerge.h` in this tree.
 */
#ifndef ZAUTOMERGE_TEST_C_SHIM_UTILS_RESULT_H
#define ZAUTOMERGE_TEST_C_SHIM_UTILS_RESULT_H

#include <automerge-c/automerge.h>

#endif /* ZAUTOMERGE_TEST_C_SHIM_UTILS_RESULT_H */
