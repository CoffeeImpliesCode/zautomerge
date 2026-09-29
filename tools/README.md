# tools

`oracle/` is a Rust binary which drives the upstream automerge implementation
so the Zig port can be compared against it byte for byte. It is a development
tool, not part of the library, so nothing in `zig build` or `zig build test`
needs it. Run it with `zig build conformance -- <doc|change|sync|fixtures>`,
which links the reference checkout named by `AUTOMERGE_REF` into
`oracle/vendor/` and then runs the given subcommand.
