/**
 * The C entry point of the conformance suite.
 *
 * This is `rust/automerge-c/test/main.c` with two changes, and no others:
 *
 * 1. The function is `suite_main`, not `main`. Zig 0.16's build system passes
 *    a C root source file as `-Mroot=<file>.c`, and the CLI then treats the
 *    compilation as a Zig compilation unit and compiles `std/start.zig`,
 *    which needs a Zig `root.main`. A C `main` cannot supply one, so the
 *    Zig root (`test/c/main.zig`) owns `main` and calls this. Every other C
 *    file in the suite is compiled unchanged.
 *
 * 2. `run_abi_coverage_tests()` joins the sum. It is this port's own group
 *    (`test/c/abi_coverage.c`), and it is here because
 *    `rust/automerge-c/test/` calls 147 of the 187 functions
 *    `include/automerge.h` declares; the other forty would be linked into
 *    the binary and never run.
 *
 * `test/c/suite/` therefore holds the upstream suite without this file, and
 * `test/c/suite/LICENSE` records that.
 */

#include <setjmp.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

/* third-party */
#include <cmocka.h>

extern int run_abi_coverage_tests(void);

extern int run_actor_id_tests(void);

extern int run_byte_span_tests(void);

extern int run_cursor_tests(void);

extern int run_doc_tests(void);

extern int run_enum_string_tests(void);

extern int run_item_tests(void);

extern int run_list_tests(void);

extern int run_map_tests(void);

extern int run_mark_tests(void);

extern int run_ported_wasm_suite(void);

int suite_main(void) {
    return run_actor_id_tests() + run_byte_span_tests() + run_cursor_tests() + run_doc_tests() +
           run_enum_string_tests() + run_item_tests() + run_list_tests() + run_map_tests() + run_mark_tests() +
           run_ported_wasm_suite() + run_abi_coverage_tests();
}
