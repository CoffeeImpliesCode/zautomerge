//! The root module of the C conformance suite's executable.
//!
//! The executable is C — every test case is a cmocka case in
//! `test/c/suite/` — but Zig 0.16's build system cannot use a C file as the
//! root of an executable: it passes it as `-Mroot=main.c`, the CLI reads that
//! as a Zig compilation unit, and `std/start.zig` then fails on the missing
//! `root.main` ([std/Build/Step/Compile.zig:1319-1331](
//! ../../lib/std/Build/Step/Compile.zig)
//! is where that `-M` is emitted). So the root is this file, it owns `main`,
//! and it hands control to the suite's C driver, `test/c/main.c`, which is
//! upstream's `rust/automerge-c/test/main.c` with the function renamed.
//!
//! That is the whole of the shim. It is here to make the link possible, not
//! to be tested: it forwards an exit status and nothing else.

extern fn suite_main() callconv(.c) c_int;

/// cmocka sums each group's failure count, so the driver's return value is a
/// count of failed cases, not a boolean (`test/c/suite/*_tests.c`,
/// `cmocka_run_group_tests`). A count wider than 255 would wrap, so it is
/// clamped: the process exit status is 0 or not-0 and nothing finer.
pub fn main() u8 {
    const failures = suite_main();
    return if (failures == 0) 0 else 1;
}
