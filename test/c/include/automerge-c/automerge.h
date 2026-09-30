/* The upstream C suite includes `<automerge-c/automerge.h>`, which is what
 * cbindgen writes (`rust/automerge-c/cbindgen.toml:1-48`, run from
 * `rust/automerge-c/build.rs:10-20`). This port ships one header,
 * `include/automerge.h`, and it is a transcription of that generated
 * artifact: every declaration in it, the enum tags, the struct layouts and
 * the `AM*` spellings, is the one the reference emits. So the whole split
 * header reduces to this one include.
 *
 * The split is a packaging difference, not an interface difference. The
 * reference's `utils/enum_string.h`, `utils/result.h`, `utils/stack.h` and
 * `utils/stack_callback_data.h` are cbindgen output too — the cbindgen
 * `header` is `automerge-c/automerge.h` plus those, split by the
 * `file-regex-replace.cmake` pass at `rust/automerge-c/CMakeLists.txt:152-156`
 * — and the hand-written `utils/string.h` declares only `AMstrdup`, which
 * `include/automerge.h:1200` also declares. This port folds all of them into
 * one translation unit, so the five siblings below are empty forwarding
 * headers and nothing more.
 */
#ifndef ZAUTOMERGE_TEST_C_SHIM_AUTOMERGE_H
#define ZAUTOMERGE_TEST_C_SHIM_AUTOMERGE_H

#include <automerge.h>

#endif /* ZAUTOMERGE_TEST_C_SHIM_AUTOMERGE_H */
