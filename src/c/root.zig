//! Static C library entrypoint. Link with libc and the installed automerge.h.
//! The C bridge owns its single-threaded I/O provider; native callers supply
//! their own std.Io capability. Export analysis is separate from ABI checks.

const c = @import("zautomerge").c_abi;

comptime {
    _ = c.doc.abi.AMresult;
    _ = c.doc.AMcreate;
    _ = c.sync.AMsyncStateInit;
}
