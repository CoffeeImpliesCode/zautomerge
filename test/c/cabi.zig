//! The root module of the static library the C conformance suite links
//! against. It exists to force every `export fn` in `src/c/` to be analyzed
//! and emitted, because `src/root.zig`'s `c_abi` namespace is lazy: nothing
//! pulls `c/doc.zig` or `c/sync.zig` in until a reference to them appears,
//! and an unanalyzed `export fn` emits no symbol.
//!
//! `zig test` cannot do this job. These are `extern "C"` exports over libc,
//! and the test binary links no libc, which is why `src/root.zig:222-226`
//! leaves `c/doc.zig` and `c/sync.zig` out of its test block. A C suite
//! compiled against `include/automerge.h` and linked against this library is
//! the gate instead: it proves the header's declarations and the library's
//! symbols are the same set, in the same ABI, from the only side a C
//! consumer ever sees them from.

const std = @import("std");

/// `src/c/doc.zig` holds `pub const abi = result.CAbi(AMitem);` (`:825`),
/// which is the single instantiation that emits the twenty-six `AMresult*`,
/// `AMitems*`, `AMstack*`, `AMstrdup` and `AMstackCallbackDataInit` exports
/// (`src/c/doc.zig:814-822`). Touching one member is enough to instantiate
/// the container; the rest of its `export fn`s come with it.
const abi = @import("zautomerge").c_abi.doc.abi;

/// The document layer, which is where the item, object and list/map/mark
/// exports live. Rust: `rust/automerge-c/src/doc.rs`,
/// `rust/automerge-c/src/doc/{list,map,mark}.rs`.
const doc = @import("zautomerge").c_abi.doc;

/// The sync layer. Rust: `rust/automerge-c/src/sync/{have,message,state}.rs`.
const sync = @import("zautomerge").c_abi.sync;

comptime {
    // Referencing a value is what marks it used; a `comptime` block keeps
    // that from being optimized away as a no-op.
    std.debug.assert(@TypeOf(abi.AMresult) == type);
    std.debug.assert(@TypeOf(doc.AMcreate) == fn (?*const doc.AMactorId) callconv(.c) ?*abi.AMresult);
    std.debug.assert(@TypeOf(sync.AMsyncStateInit) == fn () callconv(.c) ?*abi.AMresult);
}
