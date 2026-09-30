//! The test root that runs the C ABI's own test sections: `src/c/doc.zig`'s
//! and `src/c/sync.zig`'s.
//!
//! **Zig collects a `test` decl only from the file set of the test root's own
//! module**, so those two sections were compiled by **no gate in this
//! repository**. [`src/root.zig:222-226`](root.zig) leaves the files out of
//! its test block on purpose — they are `extern "C"` over libc and the library
//! test links none — and [`test/c/cabi.zig`](../test/c/cabi.zig), which does
//! force every `export fn` to be analyzed and emitted, is built with
//! `b.addLibrary`, which compiles no tests. An audit found a type error sitting
//! in one of those bodies that no gate could catch: a test section no gate
//! compiles is not a test section, it is a file that happens to contain tests.
//!
//! **That is why this root is a file in `src/` and not one under `test/`.** A
//! root elsewhere cannot reach those tests. A body of
//! `test { std.testing.refAllDecls(@import("zautomerge").c_abi.doc); }` under
//! `test/c/` analyzes `src/c/doc.zig` and still runs **one** test, its own,
//! because `zautomerge` is a separate module and another module's `test` decls
//! are not collected. And `src/c/doc.zig` cannot be its own root either: a
//! module's path is its root source file's directory and its imports may not
//! leave it, so `-Mroot=src/c/doc.zig` fails on `@import("../error.zig")` with
//! `import of file outside module path`.
//! [`src/hexane/hexane_test.zig`](hexane/hexane_test.zig) is the same shape for
//! the same reason, and `zig build c-abi-test` is the step beside
//! `zig build test` that owns the sections below.
//!
//! The build step filters names to `c.doc.` and `c.sync.`. This selects the
//! ABI's own cases without rerunning the transitive library tests. Zig also
//! retains anonymous import-collection tests.
//!
//! Nothing else belongs here. `zig build ctest` remains the gate for the ABI
//! itself, from the only side a C consumer ever sees it from.

test {
    _ = @import("c/doc.zig");
    _ = @import("c/sync.zig");
}

// Zig 0.16.0 / upstream / Rust / port
//
// * **Upstream keeps its tests in the source file and this port cannot.**
//   `rust/automerge/src/automerge.rs:43-44` declares `#[cfg(test)] mod
//   rollback_tests;` inside the module and `cargo test` collects it there;
//   `rust/automerge/src/anonymize.rs` and a dozen siblings do the same. Zig
//   collects a `test` decl only from the root module's own path, so a body
//   written in `src/c/doc.zig` is reached only if that file is inside it — and
//   that file reaches `../error.zig` and twenty-five modules above it. **The
//   extra root file is the price of that one difference and it is the whole
//   of it.**
//   No test moved: the sections stay in the files that own them, which is where
//   a private of `src/c/**` is in reach and where the next reader looks for
//   them.
//
// * **`rust/automerge-c` has no `#[cfg(test)]` anywhere in `src/`** — its
//   coverage is the cmocka suite under `rust/automerge-c/test/`, which is what
//   `zig build ctest` ports and runs. The sections collected here are therefore
//   **additional to** the C suite rather than a second copy of it: the cmocka
//   cases run in `test/c/suite/`, and these run as Zig, where an `AMresult` can
//   be inspected through the same handle a C caller holds.
