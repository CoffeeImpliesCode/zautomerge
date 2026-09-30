/* `AMresultFrom`: the one variadic function in the C ABI, and the whole of
 * this translation unit.
 *
 * Upstream's is hand-written C (`rust/automerge-c/src/utils/result.c:5-33`) for
 * the same reason, and it is the only file under `automerge-c/src/` that is
 * not cbindgen output. Zig 0.16.0 cannot define a C variadic function:
 * `export fn f(x: c_int, a: ...)` is a parse error ("expected type expression,
 * found '...'"), and `zig translate-c` demotes a variadic *definition* to an
 * `extern` *declaration`. Both were run against this toolchain.
 *
 * So the split is: this file marshals, and `AMresultFromList` in
 * `src/c/result.zig` decides. Which inputs are freed, what an error variant
 * does, and what comes back are `Result.resultFrom`'s answers and carry its
 * citations. Nothing here duplicates them, and nothing here inspects a result.
 *
 * The header is reached by a relative path rather than an `-I` so this file
 * compiles with no build-system coupling beyond being listed as a source, and
 * so that the compiler checks this definition against the declaration a C
 * caller actually sees (`include/automerge.h:528`).
 */
#include "../../include/automerge.h"

#include <stdarg.h>
#include <stddef.h>

/* The marshalling half, `src/c/result.zig`. It is deliberately absent from
 * `include/automerge.h`: that header is the reference's cbindgen output and
 * upstream declares no such function. A C caller holding an array has
 * `AMresultCat`; a C caller holding a variadic list has `AMresultFrom`. */
extern AMresult *AMresultFromList(int count, AMresult *const *results);

AMresult *AMresultFrom(int count, ...) {
    if (count <= 0) {
        /* Upstream returns `result`, which the loop below never assigns
         * because it never runs, so `AMresultFrom(0, ...)` is `NULL`
         * (`result.c:6`, `:9-27`, `:29-32`). `AMresultFromList` answers the
         * same and says why in its own doc comment; asking it rather than
         * hard-coding the null keeps one place that knows what an empty call
         * means. */
        return AMresultFromList(0, NULL);
    }

    /* One pointer per argument the caller has just handed over and still owns,
     * so this is bounded by the caller's own allocations. Upstream keeps no
     * array and folds as it goes (`result.c:12-25`); holding the list is what
     * lets the whole ownership rule live on one side of the boundary, where
     * it is testable. */
    AMresult *args[count];
    va_list ap;
    va_start(ap, count);
    for (int i = 0; i != count; ++i) {
        args[i] = va_arg(ap, AMresult *);
    }
    va_end(ap);
    return AMresultFromList(count, args);
}
