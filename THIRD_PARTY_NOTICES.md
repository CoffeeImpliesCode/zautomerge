# Third-party notices

The root [LICENSE](LICENSE) covers first-party code and Automerge-derived code, subject to the separate license for the Myers text-diff component below.

## Automerge

- **Paths:** `include/automerge.h`; `test/fixtures/` (including the corpus identified by `test/fixtures/manifest.zig`); `test/c/suite/` and `test/c/suite/LICENSE`.
- **License:** MIT.
- **Copyright holder:** the Automerge contributors (2019–2021).
- **Upstream URL:** [Automerge at the source revision](https://github.com/automerge/automerge/tree/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd); [upstream C test suite](https://github.com/automerge/automerge/tree/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge-c/test).
- **License text:** present in the root `LICENSE` and `test/c/suite/LICENSE`.

## Myers text diff

- **Paths:** `src/textdiff.zig`; `src/textdiff/LICENSE`.
- **License:** Apache-2.0. Do not apply the root MIT license to this component.
- **Copyright holder:** the upstream Apache license text does not name a holder. The upstream package metadata lists Armin Ronacher, Pierre-Étienne Meunier, and Brandon Williams as authors.
- **Upstream URL:** [`mitsuhiko/similar` at the source revision](https://github.com/mitsuhiko/similar/tree/2b31f65445df9093ba007ca5a5ae6a71b899d491); [Automerge's vendored copy](https://github.com/automerge/automerge/tree/ddbff535407e4d28cd2a82eaf6c6add08caa3bdd/rust/automerge/src/text_diff).
- **License text:** `src/textdiff/LICENSE` contains the Apache-2.0 license text.
