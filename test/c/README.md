# C tests

Run these commands from the repository root with Zig 0.17.0:

```sh
zig build ctest
zig build ctest-shared
```

`ctest` requires libc, cmocka headers, and its library.
The build discovers cmocka through pkg-config by default. `devenv shell` supplies both dependencies.
Use `-Dcmocka-prefix=PREFIX` for another installation with `include` and `lib` or `lib64` directories.
The build adds runtime search paths for that prefix.
Use a cmocka build compatible with the host's libc.

## Build cmocka separately

The optional helper downloads pinned cmocka 2.0.2 and checks the tarball's SHA-256 before building.
It requires a C compiler, CMake, curl, tar, xz support, and sha256sum.
Its default prefix and work directory are siblings named `cmocka-prefix` and `cmocka-build`.
Pass explicit directories to override them:

```sh
test/c/build-cmocka.sh "$PWD/../cmocka-prefix" "$PWD/../cmocka-build"
zig build ctest -Dcmocka-prefix="$PWD/../cmocka-prefix"
```

The helper replaces its extracted cmocka source and build directories on each invocation.
It does not run cmocka's own tests.

## Test structure

| File or directory | Role |
| --- | --- |
| `suite/` | Vendored upstream C tests and fixtures |
| `main.c`, `main.zig` | Suite entry point and Zig launcher |
| `include/` | Forwarding headers for upstream's split include layout |
| `abi_coverage.c`, `.h` | Additional exported-function coverage |
| `cabi.zig` | Independent header ABI compile check |
| `shared_corpus.c`, `shared_main.zig` | Dynamic-library fixture consumer |
| `shared_fixture_table.zig` | Generator using `test/fixtures/manifest.zig` |

`ctest` links the production `libzautomerge.a`, including its variadic `AMresultFrom` implementation.
It also compiles a separate ABI-check library against the shipped `include/automerge.h`.
That check compares function signatures, struct layouts, and enum values. The suite does not link the check library.
The build runs the suite from `test/c/suite` because tests open fixture files relative to that directory.

`ctest-shared` links a C consumer against a separate dynamic production library.
It checks fixture load outcomes, valid-document save/reload, transaction commits, and encoded bidirectional sync.
The build generates the fixture table from the canonical manifest.
This step requires libc and a runnable target, but no cmocka, Cargo, or Rust checkout.
The default install remains static.

## Compatibility and ownership

The C bridge uses UTF-8 code-unit indexing. Native Zig documents default to Unicode code points.
Compressed save output need not match reference bytes. Compare reloaded documents and heads.
`AMfork` returns a document result, despite the reference's older void-result comment.

C calls from different threads require one caller-owned global lock, including calls on independent handles.
Hold the lock through outer calls and their callbacks. The library does not supply a mutex.
Synchronous stack callbacks can inspect live stack/results under that lock without reacquiring it.
They must not free or relink borrowed nodes, mutate documents, or enter from another thread.
Keep result owners live while using borrowed items, handles, and byte spans.
See [API.md](../../API.md#c-abi) and the installed header for the complete contracts.

## Upstream provenance

`suite/` comes from `rust/automerge-c/test/` at Automerge commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`.
The Zig build replaces upstream `CMakeLists.txt`.
`main.c` uses `suite_main` to let `main.zig` supply the executable entry point.
The ported sync tests cannot inspect bloom bytes or message changes because the C header lacks those accessors.
The suite retains its own [license and notices](suite/LICENSE).
