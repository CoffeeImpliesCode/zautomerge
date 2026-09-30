/* `automerge-c/config.h` is a CMake `configure_file` of
 * `rust/automerge-c/cmake/config.h.in:1-60` that defines exactly one of
 * `AUTOMERGE_C_UTF8` / `AUTOMERGE_C_UTF32`, selected by the
 * `UTF32_INDEXING` option (`rust/automerge-c/CMakeLists.txt:45`, `:111-117`).
 * The option is OFF by default, so the reference's own CI and every
 * consumer built without the flag get `AUTOMERGE_C_UTF8`.
 *
 * This port is built that way: `AUTOMERGE_C_UTF8` is the encoding its text
 * objects index in, so a C suite compiled this way is the suite the
 * reference itself runs by default. The two cases that read this macro are
 * `doc_tests.c:278` and `mark_tests.c:80`; `doc_tests.c:318` fails the
 * build-time configuration if neither macro is defined, which is what this
 * header prevents.
 */
#ifndef ZAUTOMERGE_TEST_C_SHIM_CONFIG_H
#define ZAUTOMERGE_TEST_C_SHIM_CONFIG_H

#define AUTOMERGE_C_UTF8

#endif /* ZAUTOMERGE_TEST_C_SHIM_CONFIG_H */
