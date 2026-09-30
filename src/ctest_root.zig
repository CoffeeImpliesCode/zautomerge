//! Scratch test root. `src/root.zig` deliberately leaves `c/doc.zig` and
//! `c/sync.zig` out of its test block because they are `export fn`s over libc
//! and `zig build test` links no libc (`root.zig:222-225`). This root exists so
//! `zig test -lc` can reach the tests that live in those files. It is scratch
//! and must be deleted.
test {
    _ = @import("c/doc.zig");
}
