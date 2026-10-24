# Oracle tools

`oracle/` is a Rust crate that compares this port with the reference implementation.
The default build and unit tests do not require it.
See the [root README](../README.md) for Rust and reference-checkout requirements.

```sh
zig build conformance
zig build conformance -Dconformance-vector=doc
zig build oracle -- fixtures
```

`conformance` regenerates vectors in the build cache and compares them with `test/golden/`.
`-Dconformance-record` explicitly replaces the committed vectors.
`oracle` forwards raw subcommands and arguments without comparing their output.
`link-oracle.sh` creates ignored path-dependency links under `oracle/vendor/`.
