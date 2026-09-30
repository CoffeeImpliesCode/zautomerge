/* `automerge-c/utils/string.h` declares `AMstrdup` and nothing else
 * (`rust/automerge-c/include/automerge-c/utils/string.h:24-30`); the body is
 * `rust/automerge-c/src/utils/string.c`. This port declares the same function
 * at `include/automerge.h:1200` with the same "pass the result to `free()`"
 * contract, because it allocates from `std.heap.c_allocator`
 * (`src/c/result.zig:1046-1050`). So the split header reduces to the one
 * include. See `../automerge.h` in this tree.
 */
#ifndef ZAUTOMERGE_TEST_C_SHIM_UTILS_STRING_H
#define ZAUTOMERGE_TEST_C_SHIM_UTILS_STRING_H

#include <automerge-c/automerge.h>

#endif /* ZAUTOMERGE_TEST_C_SHIM_UTILS_STRING_H */
