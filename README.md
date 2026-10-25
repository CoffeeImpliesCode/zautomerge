# zautomerge

A Zig implementation of the Automerge JSON-like CRDT and its Hexane storage engine.
Documents support concurrent edits, merge, binary storage, and peer synchronization.
The compatibility target is [Automerge](https://github.com/automerge/automerge) 0.12.0
at `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.

Experimental. The API can change, and compatibility coverage is incomplete.

## Requirements

- Zig 0.17.0.
- libc for the C library, C tests, and matched benchmarks. The native Zig module does not require libc.
- Optional: cmocka and pkg-config for the upstream C suite.
- Optional: Rust, Cargo, and the reference checkout for reference comparisons and Rust benchmarks.
  Cargo can need network access to fetch locked dependencies.

`devenv shell` supplies cmocka, pkg-config, and inspection tools.
Install Zig separately. With direnv, use `direnv allow` to activate the environment.

## Use from Zig

For a checkout under your project's `vendor/zautomerge` directory, add this dependency to `build.zig.zon`:

```zig
.dependencies = .{
    .zautomerge = .{ .path = "vendor/zautomerge" },
},
```

In your `build.zig`, import the published module into your executable's root module:

```zig
const am = b.dependency("zautomerge", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zautomerge", am.module("zautomerge"));
```

Use `@import("zautomerge")` in your source.
`AutoCommit` groups writes in a held transaction. `doc.Document` uses explicit `Transaction` objects.
Keep allocators and `std.Io` providers live until document disposal.
Do not move an open automatic document or transaction.
See [API.md](API.md) for ownership, read scopes, errors, and C contracts.

## Build and test

Run these commands from the repository root:

```sh
zig build
zig build test
```

The default build installs `libzautomerge.a` and `include/automerge.h` under `zig-out`.
C consumers link the static library and libc. Serialize C calls globally, including calls on separate handles.

Additional steps:

| Command | Purpose | Additional requirements |
| --- | --- | --- |
| `zig build slow-path` | Unit tests with structural and fast/slow cross-checks | None |
| `zig build ctest` | Upstream C suite and header ABI checks | cmocka, pkg-config, libc |
| `zig build ctest-shared` | Dynamic C library and fixture consumer | libc |
| `zig build conformance` | Compare committed vectors with the Rust reference | Rust, Cargo, reference checkout |
| `zig build conformance -Dconformance-vector=doc` | Compare one named vector | Same as conformance |
| `zig build oracle -- fixtures` | Run a raw oracle subcommand | Same as conformance |
| `zig build save-interop` | Live bidirectional save comparisons | Same as conformance |
| `zig build bench -Doptimize=fast` | Run native workloads | libc for the default install |
| `zig build bench-matched -Doptimize=fast -- insert-growth small` | Run one matched workload | libc |
| `zig build bench-test` | Test benchmark counter validation | None |

Use `zig build test -Dtest-filter="test name"` to run matching cases across test roots.

Set `AUTOMERGE_REF` to the reference checkout root for Rust-backed steps.
`tools/link-oracle.sh` also supports a sibling checkout named `github-automerge-automerge`.
It creates ignored Cargo dependency links without modifying the reference source.
`-Dconformance-record` explicitly replaces committed vectors. Review changes before committing them.

See [C test usage](test/c/README.md), [benchmark usage](bench/README.md), and [oracle tools](tools/README.md).
Tests consume `test/fixtures`, `test/golden`, and `docs/hexane-cases.json` as project data.
Compressed save bytes can differ from the reference. Compare loaded state and heads instead.

## License

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses: see THIRD_PARTY_NOTICES.md.
