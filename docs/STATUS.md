# Status: where the port is, and what comes next

The plan of record is [plan.md](plan.md); this is the state of it.

**Every number below was measured on 2026-09-30/2026-10-01 CEST, and the
command that measured it is given next to it.** A number that could not be
measured is written *not measured* rather than estimated. This file has carried
a wrong test count more than once, and each time the error cost a round, so the
rule is now structural: if a claim cannot be produced by running something, it
does not go in.

## The shape of the thing

`zautomerge` is a direct Zig 0.16 translation of the `automerge` CRDT library
and its `hexane` storage engine, targeting a library that must read and write
the same document bytes, produce the same change hashes, and speak the same
sync protocol.

The upstream size, measured 2026-10-01. **Two scopes, both correct; they were
being compared as if they were one.** Over the two `src` trees alone
(`find …/src -name '*.rs' | xargs wc -l`):

| Crate | `src/` only | whole crate (`src` + `tests` + benches) |
| --- | --- | --- |
| `rust/automerge` | 54,589 | **64,979** in 163 files |
| `rust/hexane` | 29,683 | **32,664** in 39 files |
| **both** | **84,272** | **97,643** |

`plan.md` §2 quotes the right-hand column and `automerge-c` is 7,507,
`automerge-wasm` 6,708, `automerge-cli` 1,395, `automerge-test` 487 — all six
re-measured and all six correct. This file's earlier "about 98,000 lines, which
was wrong" was wrong about the *table*, not about the number: 97,643 is the
whole-crate total that `plan.md` §9 risk 8 rounds to 98k, and it is a different
measurement from the 84,272 this table now leads with.

Two things are normative and must be byte-exact: the document format, and
change hashes, which are SHA-256 over an encoded change. `save()` output is
deliberately *not* byte-identical, because DEFLATE is not reproducible across
implementations; equivalence is checked by loading the output with the Rust
reference and comparing the materialized document. See `plan.md` §1.

## Test state

**The library suite completes and is green.** That is the headline, and it
replaces everything this section said before it — "the library suite does not
complete", "905 passed; 13 failed", "861 tests pass", "1,130 tests pass" — all
of which were wrong in the way this section is written to prevent. The
non-terminating `a mark at the end of a long text is found at the end`
(`tests/text.rs:1121-1154`) and the `updateText inside an isolation keeps both
sides` failure are both gone; neither is skipped or filtered to achieve that,
because `src/root.zig`'s test block names the module each lives in and the run
below is the whole binary.

All four test roots and both gates, measured 2026-10-01:

```
$ zig test -ODebug -Mroot=src/root.zig
1604 passed; 1 skipped; 0 failed

$ zig test -ODebug -Mroot=test/fixtures_test.zig
All 6 tests passed.

$ zig test -ODebug -lc --dep zautomerge -Mroot=test/example_test.zig -Mzautomerge=src/root.zig
All 3 tests passed.

$ zig test -ODebug --dep zautomerge -Mroot=test/upstream_doc_test.zig -Mzautomerge=src/root.zig
All 117 tests passed.                      real 80s

$ zig build --summary all conformance
Build Summary: 18/18 steps succeeded

$ zig build -Dcmocka-prefix=../cmocka-prefix --summary all ctest
Build Summary: 5/5 steps succeeded          153 cmocka cases, 0 failed
```

| What | Measured | Command |
| --- | --- | --- |
| library suite | **1604 passed, 1 skipped, 0 failed** | `zig test -ODebug -Mroot=src/root.zig`, option off |
| fixture suite | **6 / 6 pass** | `zig test -ODebug -Mroot=test/fixtures_test.zig` |
| crate-root example suite | **3 / 3 pass** | as above, `-lc` and `--dep zautomerge` |
| ported upstream `tests/test.rs` | **117 / 117 pass** | `zig test … -Mroot=test/upstream_doc_test.zig` |
| conformance vectors | **8 vectors, all checked against the reference** | `zig build conformance` |
| C ABI cmocka cases | **153 run, 153 pass** | `zig build ctest -Dcmocka-prefix=<dir>` |

The example suite needs `-lc` because its third test reads one document through
`AMmapRange` and through `read.mapRange` in the same process
(the example step's own comment says why); `zig build test` passes it. `zig build ctest` needs both `-Dcmocka-prefix` and
`LD_LIBRARY_PATH`, because the step sets no rpath.

**The failure mode is exit 127, not a compile error — and that is the part worth
knowing.** `run_ctest` sets the step's working directory to `test/c/suite`, so
**a relative `-Dcmocka-prefix` and a relative `LD_LIBRARY_PATH` both resolve
against that directory**, not against the repository root. The binary still
compiles; it then fails to launch:

```
error while loading shared libraries: libcmocka.so.0: cannot open shared object file
error: process exited with code 127 (expected exited with code 0)
```

**So a relative `LD_LIBRARY_PATH` is a build failure that is not one**, and the
`...FAIL`-count rule does not apply — this is neither a failing test nor a blocked
run but a process that never started. Use an **absolute** path.


**The instrument, stated first because a ranking whose instrument is unstated is
not a measurement.** Count coverage by this port's own
`test "<upstream file>: <English name>"` convention: one such block per upstream
case, and **no upstream-name-based measure is sound here**, because the port
renames every ported case into English. Name-presence under-counted this tree by
a factor of three — `diff_marks` read 13 of 36 by name and is 36 of 36 by
convention — and counting blocks that cite the upstream file failed the other
way, reporting 9 of 36 for `diff_marks` and 25 for `text.rs` when upstream has
15. **Both instruments were used to rank the gates here, both were wrong, and
the ranking they produced was retracted.** The convention is the only one of the
three that measures this tree; a name match remains a floor rather than proof —
it says a case exists, not that it asserts upstream's expectations.

| Upstream file | `#[test]` | Ported | |
| --- | --- | --- | --- |
| `tests/test.rs` | 140 | **140** | `test/upstream_doc_test.zig` and others |
| `tests/batch_insert.rs` | 46 | **46** | one file, two row-order assertions |
| `tests/diff_marks.rs` | 36 | **36** | `src/marks.zig`, prefix `diff_marks:` |
| `tests/text.rs` | 21 | **26 blocks** | prefix `text:`, in `src/read.zig`, `src/iter/spans.zig`, `test/upstream_text_more.zig` |
| `tests/text_encoding.rs` | 15 | **16 blocks** | prefix `text_encoding:`, in `src/read.zig` |
| `tests/block_tests.rs` | 19 | **19** | `test/upstream_block_tests.zig`, all green |
| `tests/convert_string_to_text.rs` | 3 | **3** | `test/upstream_convert_string.zig` |
| `tests/rich_text_fuzz_crash.rs` | 9 | **9** | `test/upstream_rich_text_fuzz.zig` |
| `tests/test_mark_patches.rs` | 1 | **1** | `test/mark_patches_test.zig` |
| `tests/test_save_load_orphans.rs` | 3 | **3** | `test/upstream_save_load_orphans.zig` |

**Every one of the ten upstream integration files is ported, every case** —
re-measured 2026-10-01, `FAIL=0`.

**And one of them had a recorded gap whose blocker landed later in the same
session, which is the pattern worth keeping.** `update_spans_uses_expand_config`
(upstream `block_tests.rs:676-726`) was recorded as blocked on
`UpdateSpansConfig`; that type arrived afterwards, for a different reason and a
different slice, and the recorded gap became stale rather than closing itself.
**A recorded gap whose blocker is later fixed is a gap that must be revisited,
and nothing in the gap announces that its reason has expired.** This one was
caught only because the table above was re-measured rather than assumed — the
same reason the retracted ranking was worth keeping visible. Neither announced
itself.

**A record whose reason has expired is a defect, so expired records are deleted
rather than amended.** The next reader who needs this one will not be the one
who finds it today, and the reason it existed is already in the history.

The port declares **1541 test blocks** in total (1316 under `src/`, 225 under
`test/`) — **not re-measured for this revision and therefore not to be relied
on**; the number is here because deleting it would lose the shape of the tree
and no current figure was available to replace it.

**The one large gap left in the port is `hexane/src/tests.rs` — and that is
P2's gate.** **181 of the 284 distinct upstream names are present and 103 are
missing**, measured 2026-10-01. It was **1** that morning, **72** an hour later
and **160** at the previous revision of this line; it is dated, not final, and
it has moved four times in one session.

**The instrument, named first, because a coverage number without one is not a
measurement: exact upstream `fn`-name presence with an 8-line `#[test]`
window.** For each `#[test]` in `hexane/src/tests.rs`, the next
`fn <name>(` within eight lines is that case's name, and a name occurring
anywhere in this tree counts as present. **It reproduces upstream exactly** —
**286** `#[test]` functions and **284** distinct names — so the denominator is
upstream's and not a regex's opinion of it. The two duplicated names are
`splice_and_nullable` and `u64_column_roundtrip_and_wire_divergence`, each
declared twice under a second codec parameter (`BeLen` and `Bijou64`), so a
tally of functions overstates the denominator by two.

**What it is not.** This is name presence, and this file has already retracted
a ranking built on name presence over the integration files, because the port
renames every ported case into English. `hexane/src/tests.rs` has no prefix
convention for the port to follow, so name presence is the only measure
available — and it is a **floor, not a proof**: it says a case exists, not that
it asserts upstream's expectations.

`src/hexane/` declares 198 test blocks of its own, so the codecs and the btree
are tested — just not by upstream's cases.

**There is no unaccounted test block.** This section used to report a residue
of two — `grep -rhoE '^\s*test "' src/` counting more than the runner held, less
the sixteen `src/c/doc.zig` and `src/c/sync.zig` blocks it could account for —
and called it "two blocks the binary holds that `grep` does not see", the same
unexplained pair it had recorded before. **That residue was never evidence of a
gap, and the instrument cannot distinguish the two cases**: a file carrying
tests reaches the runner three ways, and the `grep` side sees only the first.

- **a direct import.** `src/root.zig`'s test block names the module —
  `src/root.zig:168` names `storage/parse.zig` and `src/root.zig:172` names
  `storage/bundle.zig`, among the rest. Both sides see this route.
- **a transitive import.** `src/storage/parse.zig:726` is `_ =
  @import("totality_test.zig");` in that file's own test block, so the **7**
  test blocks of `src/storage/totality_test.zig` run in the library suite and
  **no line of `src/root.zig` names that file**.
- **a dedicated build step.** `build.zig:201-210` is a second `b.addTest`
  whose root is `src/hexane/hexane_test.zig` (`build.zig:203`), run as
  `run_hexane_tests` (`build.zig:209`) off `test_step` (`build.zig:210`).
  Nothing imports that file, and it is in the `zig build test` gate while being
  in no `zig test -Mroot=src/root.zig` run at all.

**So the two counts were never measuring the same set**, which is why their
difference could not mean "declared and never run". The lesson is the
instrument's rather than the arithmetic's: **a difference of two counts is a
claim about a gap, and the difference of two counts cannot tell "the gap is
there" from "the second count is blind".**

Both of the two "findings about what runs at all" recorded previously are
**resolved**:

- `test/upstream_doc_test.zig` **is** wired. The `upstream_doc_tests` step declares it,
  `:99-109` declares `upstream_doc_more.zig`, `:126-135` declares
  `upstream_text_more.zig`, and all three run under `zig build test`.
- `src/_slabgate_scratch.zig` **no longer exists**.

## The reference checkout

`../github-automerge-automerge` is the upstream tree, read-only and never built
in or modified. It is present at commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd` (measured, `git rev-parse HEAD` in
the checkout).

**`AUTOMERGE_REF` in this environment is unset** (measured, 2026-10-01), so
anything that reads the variable rather than the relative path falls back
correctly through `tools/link-oracle.sh` to the sibling checkout. Where it is
*set* it has pointed at an absolute path from elsewhere rather than the sibling
`../github-automerge-automerge`, and that path does not exist here; the script
refuses it by name and says so, so a stale export is a warning rather than a
wrong source.

`test/fixtures/` holds **18** corpus files (measured: regular files at depth 1,
excluding `manifest.zig`). `test/fixtures/manifest.zig` records **5** entries
`.load_ok` and **13** `.load_err`. `test/golden/{doc,change,sync}.jsonl` are
generated from the oracle; `doc.jsonl` records `"bytes":446` for the
interoperability exemplar, which is the document chunk reproduced byte for byte.

`test/golden/` holds **eight** vectors, and every one of them is regenerated
into the build cache and `cmp`-ed against the committed copy on every
`zig build conformance` (`addGoldenVector` in `build.zig`), so a vector cannot drift from the
reference without the build failing on the file that drifted. Record counts,
measured 2026-10-01: `codec.jsonl` **1989**, `clock.jsonl` **110**,
`converge-parallel.jsonl` **20**, `converge.jsonl` **19**, `sync.jsonl` **18**,
`diff.jsonl` **6**, `change.jsonl` **2**, `doc.jsonl` **1**.

**The two `sync.jsonl` records that carry no `sent` field are not a defect, and
this file recorded them as an unexplained residue. They are `kind:
"sync-final"`, one per side, and `kind` discriminates them.** The oracle emits
two different record shapes on purpose: `sync_record`
(`tools/oracle/src/main.rs:417-427`) writes
`{kind, round, from, to, sent, bytes, hex}` for one direction of one round, and
the document each side ends the exchange holding is written separately as
`{kind, side, bytes, hex}` with `"kind": "sync-final"`
(`tools/oracle/src/main.rs:405`), after the rounds are done. So `sync.jsonl` is
**16 sync messages — 5 `sent: true`, 11 `sent: false` — plus 2 final
documents**, and the 5/11/2 split is the whole of the eighteen. The old
"the eleven-plus-five split alone does not account for all eighteen" was an
artefact of reading a `sent` split as if `sent` were the record's only
discriminator.

## What is done and verified

"Verified" means a test or an execution in this tree demonstrated it, not that
the file exists.

| Phase | State | Evidence |
| --- | --- | --- |
| P0 conformance harness | done | 18 corpus files, a manifest of what loading each must do, and a Rust oracle that drives the reference. The manifest/corpus agreement test passes (6/6). |
| P1 foundation | done | `error.zig`, `types.zig`, `value.zig`, `clock.zig`, `leb128.zig`, `unicode.zig`. |
| P2 hexane | **done; gate partly met — and now the weakest gate in the plan** | The four slab codecs, the B=64 btree, the slab, the generic column, the byte arena (`hexane/raw.zig`), the Fenwick weight index (`hexane/index.zig`), the forward-only edit cursor (`hexane/edit.zig`) and the column read surface; 198 test blocks in `src/hexane/`. The gate has three clauses. "Every codec round-trips bytes for random inputs against the Rust encoder" **is** met — `test/golden/codec.jsonl` is 1989 records regenerated from the reference and `cmp`-ed on every `zig build conformance`. "The upstream invariant checker, ported as a `-Dslow-path` test" **is** met as of 2026-10-01: `-Dslow-path` is a build option in `build.zig`, carried into the library module as `build_options.check_slow_paths` and read by `SlabBTree.assertSound` (`src/hexane/btree.zig`) and by `OpSet.seekOpsByIndex`'s fast/slow cross-check (`src/opset/op_set.zig`), and `zig build slow-path` runs the unit tests in a build where it cannot be off. The checker is tested ungated (`btree.zig:2487` accepts a sound tree, `:2500` rejects ten corruptions) and the gate is tested from both sides (`btree.zig:2634`: a corrupted tree is `error.InvariantViolation` with the option and silent without it). What the option buys is upstream's deep fuzz at upstream's scale (`btree.zig:2847`), skipped without it; it costs **2.46 s → 4.72 s** on the 30-test `src/hexane/btree.zig` suite (2026-10-01, Debug, this machine). The third clause, the 286-case `hexane/src/tests.rs` suite "ported case-for-case", is **not** met: **181 of the 284 distinct upstream names are present and 103 are missing**, measured 2026-10-01 by exact upstream-`fn`-name presence with an 8-line `#[test]` window — the instrument, and what that instrument is not, is under *Test state*. **This is the largest remaining gap in the port and it makes P2 the weakest gate.** |
| P3 columnar and format | done | `parse.zig`, `chunk.zig`, `column_spec.zig`, `columnar/encoding.zig`, `columnar/columns.zig`, `storage/change_chunk.zig`, `storage/document_chunk.zig`. The document chunk reproduces the oracle's 446-byte `save()` output byte for byte. |
| P4 change graph and encoding | done | `change.zig`, `author.zig`, `change_graph.zig`, `change_queue.zig`, `storage/change_chunk.zig`. |
| P5 op set and merge | **done; one gate clause open** | `opset/ids.zig`, `types.zig`, `op.zig` (the row and `Op.step`, the row-order invariant as four machine-checkable rules, each with a rejection test), `columns.zig`, `mark_index.zig`, `op_iter.zig`, `index.zig`, `visible.zig`, `top_op.zig`, `op_query.zig`, `marks.zig`, `found_op.zig`, `insert.zig`, `parents.zig`, `op_set.zig` and `batch.zig`. Both invariant checkers are demonstrated failing. The merge is checked against itself one change at a time by `debugCmp`, over a map, a list and text. **Both named upstream files are ported**: `tests/test.rs` 140/140 and `tests/batch_insert.rs` 46/46 (`test/upstream_batch_insert.zig`, wired at `the `upstream_batch_insert_tests` step`, 47/47 passing, 45 replay sites). What remains is the gate's second clause — a shared document's `save()` bytes matching modulo the DEFLATE stream is **not separately asserted anywhere**; `save()` equivalence is checked by loading, per `plan.md` §1. |
| P6 document API | **done** | `doc.zig` (the document, actor table, change graph, op set, `load`/`save`/`commit`/`merge`/`applyChanges`/`fork`/`forkAt`/`clone`/`isolate`, the diff surface), `read.zig` (twenty methods, the `ReadDoc` surface), `transact.zig` (the `Transactable` bodies and the manual `Transaction`), `transaction.zig` (`CommitOptions`, `Outcome`, `enclose`, the accessors). The crate-root address-book example **compiles and passes** (3/3, 2026-10-01) — the "`src/c/sync.zig` does not compile" claim this row used to carry is false. |
| P7 iteration | **done; gate clause re-measured 2026-10-01 and met bar two named cases** | `sequence_tree.zig` and all six of upstream's iterators: `iter/tools.zig` (`Unshift`, `PeekShift`, `SkipIter`, `Diff`, `DiffKernel`, `Shiftable`), `iter/map_range.zig`, `iter/list_range.zig`, `iter/spans.zig`, `iter/keys.zig`, `iter/values.zig`, `iter/doc.zig` (`ObjIdIter`, `DiffIter`) and `iter/slice.zig`. The claim that "one of the ported text tests fails" is **false**: the library suite is **1469 passed, 1 skipped, 0 failed**. **This row said the gate's other clause was not met, on a name-presence count of 8 for `tests/text.rs` and 10 for `tests/text_encoding.rs`, and that count was wrong** — it is the same instrument this file has already retracted once, and the port renames every ported case into English. Verified case by case against both upstream files: **all 21 `text.rs` cases and all 15 `text_encoding.rs` cases are in the tree**, and the instrument that settles it is that case-by-case comparison rather than any name match. **34 of the 36 run under all four `TextEncoding`s**, so the gate's "the 15 tests each run under 4 encodings" holds for 34, and the two exceptions are named: `empty_marks_before_block_marker_dont_repeat_text` (`text.rs:321-348`) and the `marks_are_okay` proptest driver (`text.rs:658-710`). **Both build their model in ASCII-plus-`'\n'`, and a block marker is three units wide under `utf8_code_unit`** — upstream measures every non-`Set(Str)` action as `text_encoding.width("\u{fffc}")` (`op_set2/op_set.rs:443-447`) — so a `'\n'`-wide model does not describe that document. `src/read.zig:7971-7981` is the port's own record of the same two. |
| P8 sync | **done, measured 2026-10-01** | `sync/bloom.zig`, `sync/message.zig`, `sync/state.zig`, `sync/protocol.zig` and `sync/v1.zig`: the message codec, the peer state, the document-side state machine and the frozen v1 path. The gate's third clause names "the five round-trip tests from `sync/v1_compat_test/`"; upstream has **three** (`src/sync/v1_compat_test/mod.rs:473`, `:496`, `:519` — `bloom.rs` and `state.rs` declare none), and the directory is **907** lines as the plan says. The port's `src/sync/v1.zig` carries 9 tests, covering both directions and a v1-only peer. |
| P9 patches, marks, cursors, text diff, hydrate | **done; gate met** | `marks.zig`, `textdiff.rs` (the vendored Myers diff, byte-identical to upstream's), `patches.zig` (all nine `PatchAction` variants, the expose queue's ordering asserted as a property), `cursor.zig` (the v1 codec pinned as literal bytes in both directions, plus the legacy v0 parser), `hydrate.zig` (the round trip), and both `anonymize.zig` and `autoserde.zig`. **Both named files are ported: `tests/diff_marks.rs` 36 of 36** (`src/marks.zig`, one `test "diff_marks: …"` block per upstream case, all green) **and `tests/test_mark_patches.rs` 1 of 1** (`test/mark_patches_test.zig`, wired). The hydrate clause holds. **This row said "partly met, the weakest gate in the plan" until 2026-10-01, on a name-presence count of 12/36 that was measuring the wrong thing — the port renames every case into English.** **The hydrate dispatch arms are now measured, and the measurement is what closed the defect `plan.md` §1.1a records.** That section had one mutation: three tests all hydrating `.root`, a root is a map, so the `text` and `list` arms were never reached, and rewriting the `.text` arm to build an empty string left all three green. **It is now a sweep — 25 mutations applied at once, one per candidate arm, over the whole suite reachable from `src/hydrate.zig` — and 23 of the 25 arms were invisible to the entire tree while 2 were detected.** What closed it is the **nine tests now covering the uncovered arms**. `plan.md` §1.1a still carries the single-mutation account and has not been amended. |
| P10 C ABI | **done, measured 2026-10-01** | `include/automerge.h`, `src/c/result.zig`, `src/c/doc.zig`, `src/c/sync.zig`. `zig build ctest` is **5/5 steps, 153 cmocka cases, 0 failed**: 136 of the cases are upstream's own (`test/c/suite/` is a verbatim copy of `rust/automerge-c/test/`, re-verified file-by-file on 2026-10-01) and 17 are this port's `abi_coverage.c`. The gate's "21 cmocka files" is not a measurable count — upstream's directory holds **19** `.c` files, 5 headers, one data file and `CMakeLists.txt`. |
| bundle engine | **done, and the two halves are not the same claim** | **The bundle chunk codec works and is proved against the reference.** `storage/bundle.zig` carries **9** test blocks, among them `a bundle the reference wrote reads field by field, at literal offsets` (`src/storage/bundle.zig:2553`) and `a written bundle is byte for byte the bundle the reference wrote` (`:2869`), and the file is in the library suite through `src/root.zig:172`. **The fragment API that produces bundle chunks for an incremental load does not exist.** There is no `Fragment`, `fragments()`, `get_fragment()`, `cache_fragment()`, `loose_commit()` or `bfs_until_clock()` anywhere in `src/`, where upstream declares `get_fragment` (`change_graph.rs:585`), `fragments` (`:614`) and `pub struct Fragment` (`:1768`), so **10 of upstream's 12 `change_graph.rs` `#[test]`s (`change_graph.rs:1229-1642`) are missing code rather than missing tests** — the two that are not fragment cases are `clock_by_heads` (`:1072`) and `remove_ancestors` (`:1094`). **`Automerge::bundle(hashes)` (`automerge.rs:1141`) is absent**, so `loadIncremental` refuses a bundle chunk: `src/doc.zig:3972` is `.bundle => return error.Unsupported`. `API.md` §Known gaps item 6 records the absence, and `src/change_graph.zig:1997` is the row that records the missing fragment surface. |

## The API contract

`API.md` is the target public surface. It was audited against the tree on
2026-09-30 and **re-measured against both trees on 2026-10-01**. Its
[audit table](../API.md#audit-every-declaration-in-this-file-against-the-port)
records, for every declaration, whether it is present, renamed, absent or
deliberately different, with the file and line it lives on. The short version of
what the audit found:

- `Automerge::diff` and its five siblings were missing from `API.md` entirely,
  for a method thirteen upstream tests need.
- The manual `Transaction` surface was one sentence and no names.
- `getMarks` was documented as upstream's single-index `MarkSet` read and is in
  fact a half-open window over `[]Mark`. **Upstream's single-index read is now
  ported** — `read.markSetAtIndex` / `read.markSetAtScope` — and the window
  stays as `API.md`'s own method with its audit row saying which is which;
  `Transaction.get` and `Transaction.markSetAtIndex` are ported beside it. The
  gap that replaced the first two was "a transaction opened at historical heads
  does not always read at them"; **that gap is closed** — the transcription in
  `test/upstream_doc_test.zig:3126` asserts upstream's own values at every line
  and passes. The last recorded gap there — **a missing method**, the `_at`
  historical variants — **is closed too** (2026-10-01): `src/read.zig` carries
  all fourteen upstream spellings. **That sentence counted a second name the
  upstream crate does not have.** Upstream carries `at` on the three cursor
  methods themselves (`read.rs:203`, `:228`, `:241`), so the port's
  `getCursorAt` / `getCursorMovingAt` / `getCursorPositionAt` were a port-only
  split and **have been removed**; `getCursor`, `getCursorMoving` and
  `getCursorPosition` now carry `heads: ?[]const ChangeHash` in upstream's own
  argument position, and `API.md` § Conventions, §Read and §Known gaps item 2
  record the cutover. The same fold relabelled one refusal —
  `getCursorPosition` answers `error.InvalidCursor` where it used to answer
  `error.InvalidIndex` unscoped (`automerge.rs:1778-1781`).
- The actor block (`getAuthors`, `setActor`, `getActor`,
  `getAuthorForActor`, `getActorForAuthor`) was wrong against the **Rust** as
  well as against the port.
- `split` matched nothing at all, upstream or here; `rollback` is a
  transaction's method upstream and here, not a document's; `bundle` upstream
  takes a hash list and there is no document-level one.

- **Re-measured 2026-10-01, three more declarations wrong against the Rust, not
  only against the port.** `parents` was declared as
  `pub fn parents(doc, obj) Parents` — upstream `read.rs:35` returns a
  `Result<Parents<'_>, AutomergeError>` and the port's own `src/read.zig:1102`
  returns `ReadError!Parents`, so the contract dropped an error union that
  *both* implementations have. §Write's "twenty … one for one" counts
  **twenty-one** declarations against upstream's **twenty** methods, and
  `mark` / `unmark` do not match `transactable.rs:103-117` in arity or order.
  All three are fixed in `API.md` with the upstream `path:line` beside them.
- **149 of the 184 `// path:line` citations in `API.md` and 72 of its audit
  table's Location cells had drifted** — the port grew after the audit
  (`doc.zig` by up to +1061 lines). Every one has been re-derived by matching
  the declared name *and* the parameter and return types, and `184/184` now
  land on the declaration they name.

## The slab merge budget, and why the previous account of it was wrong

This file previously said that `slab.merge` could leave a merged slab over the
64-segment budget, that the fix was to port upstream's `rewrite_lit_header`,
and that the characterization test would then fail with 65 found and 64
expected. It also said, in the same document, both that the defect had been
fixed and that it was the first thing to fix.

All three statements were wrong in the same way: they assumed the merged slab's
run count could be one lower than it is.

**The run count is 65, and 65 is correct.** The inputs are `a` = 11 runs ending
in the literal run `[11, 12]` and `b` = 53 runs opening with the literal run
`[12, 13]`, so the merged values at the seam are `11, 12, 12, 13`. Canonical RLE
cannot encode those four values in two runs: a literal value equal to the
previous one is not canonical (`rle/decoder.rs:452-455`) and two adjacent
literal runs are not canonical either (`rle/decoder.rs:444-451`). The encoding
is `lit[11] + run(2,12) + lit[13]` — three runs, which is upstream's own bytes.

**Upstream never reaches the case.** Upstream's `Slab.segments` counts a
literal run as its number of *values* (`rle/load.rs:131-138`,
`rle/state.rs:229-231`), so `a.segs = 12` and `b.segs = 54` and
`Column::try_merge`'s pre-check `a + b <= max`
(`hexane/src/column.rs:1789`) refuses the merge outright. This port's metric is
the run count, and it is not additive across the seam: 1 + 1 seam runs can
become 3.

What landed:

- `slab.zig` has `rewrite_lit_header` under the upstream name
  (`hexane/src/codec.rs:207-219`), and `merge` builds the seam from bytes
  through it rather than by decoding and regrouping the two runs' items.
- `litSeam` had a real defect of its own, which the account above never
  mentioned: at the b side it rewrote the run's count header but did not remove
  the first value's bytes, so the seam it produced would not parse. It now drops
  that value, and `Base.litHead` — the mirror of `Base.litTail` — is what
  measures the value that goes.
- The characterization test is now `a merge at the segment budget stays inside
  it`, which uses a `b` of 52 runs so the pre-check gives 63 and the result is
  64, and it carries the budget assertion. The +1 case has its own test,
  `a merge whose seam values meet costs one run more than the two it replaces`,
  which asserts 65 and explains the arithmetic.
- The genuine over-budget case is `Column.tryMerge`'s pre-check, not the seam.
  It now splits the merged slab exactly as `settle` does, and a test reaches it
  through the public column API.

## Defects found and fixed during the port

Recorded because they are the kind of thing that recurs if nobody writes them
down. Every `path:line` in this list was re-checked against the reference on
2026-09-30 and still resolves.

1. **The encoding field of a column specification is three bits, and bit three
   is the DEFLATE flag.** The port masks the whole 32-bit word, not upstream's
   8-bit literal, because upstream's literal discards the high bits of a column
   id of 128 or more.
2. **A compressed chunk's checksum covers the inflated body, hashed as a change
   chunk, not the DEFLATE stream.** `parseChunk` therefore cannot verify a
   compressed chunk at all; the load layer must route every compressed chunk
   through `decompressChunk`.
3. **The boolean codec is not the RLE codec.** Applying the RLE rule that two
   adjacent single-item literal runs are not canonical to a boolean column
   merges runs of *different* values at a slab boundary and shifts every value
   after it.
4. **The leading boolean pad belongs when the region's first value is `true`
   and the run at its position is a `false` run.**
5. **The column merge policy was enforced over too small a range.**
6. **`slab.merge` rebuilt the seam from items instead of rewriting the run
   header, and the seam it built did not parse.** Both halves are described
   above.
7. **Rust's `sequence_tree.rs` is a positional b-tree, not an interval tree**,
   and it has no cursors. A cursor is resolved through the op set.
8. **`writeOpsBlock` wrote the column count after the descriptors**, so every
   body it produced was unreadable by `parseChangeChunk`. It was not a compile
   error and the round-trip test had never run.
9. **`opTypeFromActionAndValue` could never return `OpType.mark_end`.** A mark
   row is a begin when its `mark_name` column holds a name and an end when that
   column is null, and the column is nullable (`op_set2/columns.rs:32`,
   `op_set2/types.rs:177-186`). The port returned `error.InvalidValue` instead,
   so the `mark_end` variant was unreachable. `OpType.MarkEnd` also carried a
   name and a value that upstream's `MarkEnd(bool)` does not have.
10. **Six kernel methods were declared `!?T` and returned `!T`,** which does
    not type-check, and nothing noticed for the life of the file. A comptime
    check that instantiates a generic — `column.Shiftable(I)` resolves the type
    and leaves every method body **unanalyzed**, so a malformed body passes it
    cleanly. The bodies were only analyzed when a sibling module tried to call
    one. A test that drives every kernel method on a real fixture is now the
    instrument; it is not scaffolding, and it found four of the six.
11. **`&.{…}` inside a loop is a pointer to that iteration's stack frame.**
    `Row.succs` is `[]const OpId`, and a one-element slice literal with a
    runtime element taken inside a loop body is not a constant — it is an
    address the next iteration overwrites. Two op-set fixtures did this, and
    the symptom was three measurements of the same fixture disagreeing: a
    column read, an indexed walk and a scan walk gave three different answers,
    and the third varied between runs because it was reading reused stack.
    It looked exactly like a cursor bug and the column layer was sound: the
    same 500 values spliced directly into the column round-tripped
    correctly. Fixtures now own their successor ids in one allocation sized
    once.
    **The lesson is about the test, not the fixture.** A comparison test does
    *not* catch this: the clock and the columns are built from the same rows, so
    a fixture that is wrong in one place is wrong in both and they agree with
    each other. What catches it deterministically is a **premise** assertion —
    that the ids are N distinct values, in row order, with specific values at
    specific rows. Assert the premise, then the conclusion.
12. **A helper that is never instantiated has never been type-checked.** Two
    visibility helpers were dead, and instantiating them produced two const
    errors that lazy analysis had been hiding. The same shape as item 10 and
    the same fix: a check that resolves a type is not a check that a body
    compiles, so the body has to be reached.
13. **`ElemId` was collapsed to `OpId`, and a list's first element could not be
    written at all.** Upstream's `ElemId(OpId)` wrapper exists for exactly one
    reason: to carry the head. `ElemId::actor()` returns `None` for the head and
    `icounter()` does not (`automerge/src/types.rs:664-674`), so **a
    sequence key's actor is optional** and the port's bare alias could not
    express that. An insert anchored at the head of a list then wrote
    `key_actor = 0` where the reference writes absent, and a reader takes
    absent as the head.
    The load path was unaffected — the stored bytes already say absent — which
    is why a green suite never caught it, and the local-write path is where it
    bit.
    The restoring fix has three parts worth keeping separate, because the first
    is not the one that matters:
    - **the type.** `ElemId` is a struct again, with `fromOpId` and `head`. The
      head is the distinguished *value* `OpId(0, 0)`, reused from the root
      sentinel, because a counter of zero is not an operation's counter — so
      nothing can construct an almost-head.
    - **the two shapes.** A sequence row is `(actor, counter)` for a normal
      element and `(absent, 0)` for the head. `(absent, absent)` is the third
      shape and it is a **map key**. Getting that wrong produces a row that
      round-trips cleanly and is not a head anchor at all, which is why it is
      called out here rather than left to the code.
    - **the proof, which took three passes and had a gap.** The ordering half —
      the head is the minimum, so a head-anchored insert sorts first — is
      proven by the stepper tests. The round trip through `tryLoadElemId` was
      already proven. Neither is the same as the encoding half. The two existing
      proofs were coupled by a shared literal and a cross-reference rather than
      by a shared execution, and the only production path from stored bytes to
      the reader — `KeyIter`'s nullable widening — was crossed by neither. It
      is now, with and without a clock.
14. **The LEB128 reader accepted an over-long encoding, so a document the
    reference refuses loaded here.** `readUnsigned` stopped at the first byte
    with the high bit clear and never asked whether that byte was the last one
    the value needed; `readSigned` did the same and had no `prev` byte at all.
    `test/fixtures/counter_value_is_overlong.automerge` is exactly this, and
    the manifest records that the reference refuses it.
    **The module doc at `leb128.zig:9-10` already promised it** — "an overlong
    encoding is a parse error, not a silently accepted value" — and
    `readUnsigned`'s own doc claimed it. The contract was written and the
    implementation never followed, and the tests only covered an eleven-byte
    encoding. The reference's rule is `storage/parse/leb128.rs:32-33` for the
    unsigned form and `:62-65` for the signed one.
15. **A prefix descent could not land inside a multi-unit element.**
    `findPrefixInSlab` walked whole segments and read each as `count` copies
    of its first value, so it over-counted a literal run and every landing fell
    one run late. A text element carrying `"ab"` has width 2, so asking for
    unit 1 landed on the element *after* it, and `seekTextOpsByIndexFast`
    refused with `error.Invariant` rather than naming the wrong element. The
    cursor took a grouping arm — O(object) per cursor where the descent is
    O(log n) — until this was fixed at source.
    Upstream's decoder hands a literal group back as a run of **one item per
    value** (`rle/decoder.rs:516-522`), so it only ever divides by a single
    item's length and never over-counts. The port's `RunAt` is a whole
    segment, and the arithmetic followed the port's shape instead of
    upstream's.
16. **A patch stored a payload owned by the log that built it.**
    `PatchBuilder.insert` put the `Event`'s value verbatim into the patch's
    arena, but that value belongs to the **`PatchLog`'s** allocator — so a
    `Patches` outliving its log read freed memory. Three more instances of the
    same class turned up in the sweep: a `Patch.path`'s map key (document-
    owned), a mark's `ScalarValue` (log-owned), and a leak in
    `MarkRuns.deinit` that dropped every byte-carrying mark value.
    **The doc comment that let two arms through claimed the tree "was built
    with the arena, so it allocates with it"** — true of the *nodes*, false of
    the *payload*. A comment that is half-true about ownership is worse than
    none, because it reads as a reason.
17. **The change decoder dropped the change-local to document actor mapping.**
    `actorAt` returned the local index instead of mapping it through
    `actors[i]`, so a second change's ops named objects the document does not
    hold. **Invisible while a document has one actor**, because then the table
    is the identity — 790 tests passed and only two-actor fixtures failed. It
    arrived six tests away, as upstream's
    `panic!("Obj {:?} Missing from Index")` (`op_set2/change/batch.rs:920`) arriving on
    time as an `error.Invariant`.
18. **A decoded column was indexed without a bound.** `graphStr` read `cells[i]`
    with no length check and panicked on the corpus fixtures. That is the third
    place in the document loader where a decoded length disagreeing with the
    reader's expectation needed a check — `decodeColumn` for the four
    change-block columns, `cellAt` for the fourteen op columns, and now this.
    **One discipline, not three ad-hoc checks:** every read of a decoded column
    is bounded by the actor column's row count, and a group column's flattened
    half is bounded by the sum of its counts. That sentence belongs where a
    column reader is written, not in each reader.
19. **A mark's closing run was reported past the end of its object.**
    `calculateMarks` subtracted `base` at the closing line, where upstream
    subtracts it at two. Upstream's `base` is the **absolute** prefix of the
    whole column at `range.start`; the port's was **zero**, because
    `prefixIterRange` parks the absolute prefix in the cursor and starts its sum
    at 0. Inside the loop the two forms agree — `pv.prefix()` is already
    object-relative — so `- base` looked like a no-op subtraction of zero, and
    at the one line where an absolute number is subtracted it produced an
    absolute end against an object-relative start. **A subtraction of a value
    that looks like zero hides the question of which coordinate space it is in.**
20. **A document chunk was validated only when it was compressed.** The check
    lived inside the DEFLATE helper, so the DEFLATE decision decided whether a
    document was checked at all, and an uncompressed document with a repeated
    column specification loaded. Upstream has no such coupling: decompression
    and validation are separate steps. `ColumnLayoutParser`
    (`storage/columns.rs:153-355`) is ported with it, so a half-present logical
    group is now refused too.
21. **The span fold flattened each mark fold on its own, so every mark read as
    an unmark.** `SpanState.refreshMarks` copied the document fold and the merge
    fold separately, and did it through `batch.MarkDiff.exportSet` — which is
    `Pop::Before` for the document fold alone (`spans.rs:360-366`), and rewrites
    every name to `ScalarValue::Null`. Upstream keeps the two sets apart for
    exactly this reason: `RichTextDiff::current` returns
    `MarkDiff::Diff(b.clone(), a.clone())` (`spans.rs:653-660`) and flattens once,
    at export (`spans.rs:389-400`).
    **The symptom was a mark reported where the reference reports none, and a
    run split at every mark boundary** — a `Same` text span carrying a mark set
    becomes a patch (`spans.rs:32-36`), so four of upstream's five mark-patch
    tests went red with a spurious `Mark` patch in the stream. The companion
    defect was in the comparison rather than the copy: `flattenedEql` compared a
    one-fold `.before`/`.after` view by its raw entries instead of by its
    flattening, which is a different question whenever the fold holds a
    tombstone (`spans.rs:360-372`) — so an unmark split a run that had not
    changed. **The lesson is that `Pop::Before` is a statement about the
    difference between two folds, and applying it to one of them inverts it.**

22. **A float reached the wire in the host's byte order, and the round-trip
    test could not have caught it.** `appendPayload`'s float arm
    (`src/columnar/encoding.zig:1424`) wrote `@bitCast(f)` into `[8]u8` and
    `ValueDecoder.next`'s float arm (`:813-819`) read it back with `@bitCast`
    of the payload's bytes, while the two op-column writers in the same tree
    spelled `std.mem.writeInt(..., .little)`
    (`src/columnar/columns.zig:526`, `src/opset/types.zig:371`), upstream
    encodes with `self.to_le_bytes()`
    (`columnar/encoding/encodable_impls.rs:74-78`), and upstream decodes with
    `f64::from_le_bytes(raw)` (`columnar/column_range/value.rs:245`).
    **Every little-endian row agreed with itself, and the bytes disagreed with
    the reference.** `1.5` came out of a `powerpc64-linux-musl` build under
    `/bin/qemu-ppc64` as `{0x3f, 0xf8, 0, …}`, where it is
    `{0, …, 0xf8, 0x3f}` everywhere else; after the fix it is the latter on
    both endians.
    **The lesson is the one the round-trip instrument cannot express: two
    halves that are wrong in the same direction agree with each other on every
    host.** `a value column pair round trips every scalar` encodes and decodes
    with the same two arms, so it passed on powerpc64 too — it measures
    self-consistency, not the wire. The test that pins this one
    (`a float value column's payload is the reference's eight little-endian
    bytes`) asserts the **bytes** and feeds the reader a literal array it did
    not write. That is the general form: **a byte-order contract is only
    measured against bytes the test did not produce, and the row that measures
    it is the one that is not the host's** — which is why
    `test/cross-test.profile.sh` names this site as the reason powerpc64 is in
    the matrix.

23. **A bulk index replacement built a root larger than the branch factor
    permits.** `propagateSplits`'s terminal root-overflow case put every
    replacement slot into one new internal node. `makeLeaves` makes one slot
    per leaf, so replacing a whole tree with more than `branch_factor` slabs
    arrived there with more than `branch_factor` slots and the new root was
    itself overfull — **65 children at 4097 slabs, 66 at 4167, 128 at 8192**.
    A straight `fromSlice` build cannot produce that shape, because it adds a
    level at a time (`buildLevel`), so a load-then-edit column was sound and an
    edit that grew one past a leaf boundary was not. The slots are now grouped
    into internal nodes first, the way a straight build does.
24. **A slab split left a guard naming a destroyed list.** `Column.settle`
    armed an `errdefer` over `spilled`, called `spilled.deinit(gpa)` on the
    success path, and only then made two more fallible calls. A refusal below
    read `spilled.items` out of the `undefined` an `ArrayList.deinit` leaves
    behind and freed garbage — **the general protection fault the apply-route
    allocation sweep hit at refusal 56 of 787**. `spilled` has one owner now
    and no guard outlives it.
25. **The batch screen's accept path left a double free.** A change the screen
    accepted was appended into `accepted` and the `incoming` slot it came from
    was **not** blanked, so that slot still aliased the buffer `accepted` now
    owned. On a refusal the guard released the accepted copies and the
    caller's release walked the same buffers again. The skip path already
    blanked its slot for exactly this reason; the accept path did not, and two
    screen tests reported the double free through `DebugAllocator` while their
    assertions passed.
26. **`Document.reset` aborted the process on a refused allocation.** It tore
    `self` down and only then allocated the replacement, under
    `catch unreachable`. Building the fresh document first costs nothing —
    `initWithEncoding` neither reads nor writes `self` — and makes the refusal
    a `ParseError` the caller can hold a whole document against.
27. **A taken predecessor list leaked when its shrink was refused.** `take`
    pulled the entry out of the map and then returned
    `kv.value.toOwnedSlice(gpa)`; that call shrinks the buffer and the realloc
    is fallible, so on a refusal the entry was already out of the map and a
    local was the only thing still naming the buffer. The collector's sweep
    found it, and the release belongs on the failure path beside the
    successful one.

### The pattern under 14 to 18

Three of these five are invisible to a green suite for the same reason: **the
port only ever exercised one of something.** One actor, one mark value that
borrows nothing, one eleven-byte LEB, one literal run. A test that passes is
evidence about the cases it covered and nothing else, which is the same lesson
as the three classes of uninstantiated code earlier in this list.

And 14 is its own lesson: **a doc comment promising a rule the code does not
implement is a defect that reads as a specification.** Two of them, in this
case — the module doc and the method doc — and both were believed, by me and by
an agent writing against them.

### The two rules under all of it

They are stated here because they are the most transferable things this
session produced about how the port goes wrong, and both cost real rounds.

**A reader that is more permissive than its writer hides the writer's bug.**
`encodeGraphCols` wrote an unsigned cell into a delta column, and the column's
reader had been deliberately made sign-lenient so the load path would accept
the reference's data. The leniency was correct on its own terms and it meant
the writer's error could not surface — every `save` of any document with a
change died at one line, and a passing load path said nothing was wrong.
**The things written to be forgiving are the things that hide the errors.**

**An `errdefer` written before a value moves into a longer-lived owner frees it
twice.** It has cost this port four double frees, in four files, and each was
found only because a downstream test aborted and the abort was chased rather
than dismissed. The errdefer fires on the path that returns; the move means
the new owner also frees.

**An `errdefer` covers failure, and a path that succeeds by giving up still owns
what it was handed.** The collector's `place()` had an `errdefer` and three
plain `return`s, and **every op it dropped** — the common case, not the edge —
leaked its predecessor list, because a plain `return` is a success. This is the
same class as the rule above seen from the other side: both are about an
`errdefer` being treated as if it covered a path it does not.

## Traps found and not yet fixed

Next to the list above because they have the same character — the wrong
answer looks right — but these are open, not closed.

1. **`MarkIndexColumn.iter().next()` answers `null` both for "no more" and for
   "this row carries no mark."** `MarkIndexColumn.ValueIter.next` decodes a
   nullable word and hands back `?MarkIdx`, so those two cases are one value
   (`src/opset/mark_index.zig:488-496`). A row-at-a-time read stops at the
   first unmarked row. It is correct where it is used — the cursor says so,
   and `calculate_marks_fast` walks it run at a time for that reason
   (`op_set2/op_set.rs:981-987`) — and it is a trap for the query surface,
   which is where marks turn into per-row answers. The fix, when someone wants
   it, is a distinct accessor beside `next`, not a change to what `next` means:
   `next` is the column's own cursor shape (`src/opset/mark_index.zig:252-260`)
   and `nextRun` already covers the run-at-a-time walk.
2. **`src/opset/op_iter.zig` is the counter-example, and the property is worth
   keeping there.** Every sub-iterator in it has a *total* item type — `bool`,
   `Action`, `KeyRef`, `ObjId`, `ScalarValue`, `SuccCursors`, `OpId` — so
   "this row carries nothing" is a value and only the walk's own end is
   `null` (`src/opset/op_iter.zig:117-133`). A row with no mark is
   `MarkInfo{ .name = null, … }`, a row with no successors is an empty
   `SuccCursors`, and a row naming no property at all is `error.MissingKey`.
   Do not copy the mark index's shape when a new sub-iterator is added.

3. **`src/c/sync.zig` did not compile, and no longer does** — *closed 2026-10-01*.
   The `gpa` shadowing at `src/c/sync.zig:197` is gone; the file compiles.
   The reason it is kept here rather than deleted is the way it hid, which is
   the transferable part: the library test block keeps most of `src/c/**` out
   (`src/root.zig:222-226`) because those files are `extern "C"` over libc, so
   the library suite could not have seen it, and the one test that *does* pull
   the module in is a single example file. **A file excluded from the main
   suite has exactly one other place it can fail, and it should not be the
   crate-root example.** It passes now — `test/example_test.zig` is 3/3.
4. **The 20-target portability matrix has no verdict yet — its one run was
   interrupted, not failed.** Run `20261002-115542-31452-24919` (Zig 0.16.0,
   `test/cross-test.profile.sh`, `zig build test`) covered 12 of the 20
   runnable targets before the harness was stopped (exit 143): 0 pass /
   20 fail with `bookkeeping_failure=false` is the shape of an aborted run,
   not of twenty broken targets. The per-target logs stay outside the repo;
   re-run per the profile and record the outcome here before claiming any
   platform verdict.

## Traps found and fixed

4. **An isolated write's ops carried the base actor's index, not the
   concurrency fork's, so every clock-filtered read was blind to them.**
   `Document.isolate` and `Document.integrate` call `Document.patchTo`,
   upstream's `AutoCommit::patch_to` (`autocommit.rs:816-824`). With that in
   place the isolate round trip emitted **five** of the reference's seven
   patches under all four encodings, and the three it missed were the three
   that mention `"color"`. The cause was one line in `Document.commit`:
   it opened with `var args = try self.transactionArgs(gpa, self.isolation)` —
   it re-derived the transaction's arguments because the port's transactions
   did not carry them into it — **after `Transaction.insertLocalOp` had
   already spliced the change's rows into the op set**. The re-derivation
   reaches `Document.isolatedActorIndex`, which interns a concurrency actor,
   and `Document.insertActor` then runs `rewriteWithNewActor`, renumbering
   every row at or above the insertion point — **including the rows this very
   change just wrote**. The change's header named the new actor and its rows
   named the old one; `ChangeGraph.clockAt` reads the header, so the clock put
   the fork's `max_op` in the fork's slot while the rows answered to the base
   actor's.

   **How it looked, measured.** A document holding `"name"` = `"abc"` and,
   under an isolation, `"color"` = `"red"` had two actors (`actor[0]` = the
   8-byte concurrency fork, `actor[1]` = `"aaaaaa"`) and a clock at its real
   heads of `[8, 4]`, which covers both changes. `hydrateMap` at those heads
   answered **one** register (`name`) where the same document read unscoped
   answered **two**. Raising only the clock's **second** slot made `color`
   appear, at exactly the counter its op id carries — the rows were at actor
   1, whose slot held 4. `OpSet.validateOpOrder()` was `true` and
   `OpSet.validateTopIndex()` was `null`, so the op set's index was sound and
   the rows' actor index was the fault.

   **Two defects, not one, and the second was found only by the first.** With
   `Document.commit` taking the transaction's `TransactionArgs` — upstream
   builds them once per transaction, in `AutoCommit::ensure_transaction_open`
   (`autocommit.rs:445-457`), and `TransactionInner::commit_impl` reads that
   same struct (`inner.rs:146-172`) — the fork happened and the stream went to
   **nine** patches, every `color` patch present and the `name` pair re-emitted
   at the front. The cause of that was the range `Document.commit` walks for
   the change's own patches: it used `graph.getHeads()` as `after`, which is
   the same list as the change's own hash for a sequential change and **not**
   the same under an isolation, where the graph keeps every concurrent branch.
   It reported the concurrent branch's `name` and its hundred-character splice
   as this change's own, and flagged the contested `color` as conflicted on
   the `PutMap` that introduces it. **`after` is `[this change's hash]`.**

   **A third thing was the fixture, and it is the transferable part.** The
   actor a change is written as is decided when the transaction is **opened**,
   so a caller that isolates and then opens through `Transaction.openAt` with
   `null` — the low-level door, `Automerge::transaction`, which reads no
   isolation — gets a sequential change no matter what the document holds.
   `Document.commit` cannot paper over it and must not: the actor index in the
   arguments is the one every op was written against, and overriding it is the
   trap above. **Two doors that each re-derive "which actor is this" is the
   same shape as the mark-anchor and skip-unit traps above**, and the test that
   would have caught it did not, because every assertion in the file was
   self-consistent with the fixture.

   **The seven, and which half of `patch_to` emits them.** The oracle's
   `isolateprobe` runs the reference's own case with the log drained at every
   step, which attributes the stream: the walk (`DiffIter::log`) emits
   **five** of the seven and `finish_current_view` emits **none** of them,
   being a no-op at that case's `isolate()` because the previous
   `diff_incremental` left the log empty. The close half's job there is to
   *finalise* the four events the walk and the isolated commit recorded, which
   is what puts them ahead of the three the `integrate()` walk records.
   `integrate()` is not a no-op either: after a commit the isolation is
   `Some([that change])` (`autocommit.rs:735-736`) while the graph holds every
   concurrent head, so `patch_to`'s `before != after` test fires and the walk
   is what sees a contested key twice over and raises the conflict.
   `test/upstream_text_more.zig` pins all seven, by name and in order, under
   all four encodings, and passes.

## Where the document slice stands

P6 is written, the crate-root example that drives it end to end compiles and
passes, and **the whole library suite is green** — **1469 passed, 1 skipped, 0
failed**, 2026-10-01. The
failure and the non-terminating test this section used to report at the top of
the file are both gone.

**What is proved.** A change chunk the **Rust reference wrote** decodes,
re-encodes, and reproduces the reference's own bytes and all 32 hash bytes — so
`writeChangeOps`, the `ActorMapper` ordering, the column-dropping rule, the
value-pair split, the predecessor group and the delta ordering are byte-exact.
The reference's own document loads and change 0's hash `108741df…` is reproduced
exactly. The document chunk reproduces the oracle's 446-byte `save()` output
byte for byte. Commit determinism, `forkAt`, and the duplicate-sequence refusal
through both `applyChanges` and `merge` all pass.

**The direction that matters most, re-measured.** The three tests that prove
the *write* path — not only the read-back — are named in the tree and pass
(`zig test … --test-filter "reference"`, 2026-10-01, 20/20):

- `src/doc.zig:9003` `this port's write path produces the reference's own change
  chunks, byte for byte`. It builds the oracle's document through this port's
  own transactions, asks for its two changes, and asserts **two** things per
  change: the encoded body equals the reference's bytes
  (`expectEqualSlices(owned.parsed.change.bytes, built.body)`) and the hash
  equals the reference's own 32 bytes (`expectEqualStrings(want, got)` against
  `reference_change_0_hash` / `reference_change_1_hash`). It also asserts
  `changes.len == 2`, so it cannot pass by comparing an empty list.
- `src/doc.zig:6425` and `:6442` — a change chunk the reference *wrote*
  re-encodes to the reference's bytes **and** hash, for the plain and the
  compressed framing.
- `src/doc.zig:6500` — every change in the reference's own 446-byte document
  comes back with the reference's hashes.

**What is still open in this slice** is not a failing test, and this sentence
used to say it was. It said `tests/batch_insert.rs` "is not ported at all" and
that P7/P9's ported-upstream clauses are partly met; **the first is false** —
the file is ported 46 of 46 in `test/upstream_batch_insert.zig`, which the
coverage table under *Test state* already recorded — and the P7 clause is
re-measured and met bar two named cases. What is open is the gate arithmetic
under *What is done and verified*: the `hexane/src/tests.rs` suite, and the
fragment API behind the bundle row. And `can_transaction_at`
(`test.rs:2507-2546`) — which this file previously called "left failing", and
which `API.md` §Known gaps item 1 also called a hole — is now transcribed with
upstream's own expected values at every line and **passes**
(`test/upstream_doc_test.zig:3126`).

**Three walls this session turned out to be one wrong assertion each**, and in
all three the instrument was the reference rather than a re-reading of the port:
a mark fixture whose begin and end were anchored to the same op, so it spanned
zero graphemes and the reference reports no mark either; a string comparison
across two documents' intern tables, where the same string has two ids; and a
fifth test that passed either way because the reader does not sort. **When a
wall is certain, ask the reference the same question and write down its answer.**

## Next steps, in order

### 1. Port `tests/batch_insert.rs`

**Closed 2026-10-01, and this entry recorded the opposite twice.** It said
"none of its **46** cases exists in the port and the string `batch_insert`
occurs nowhere in `src/` or `test/`". **Both halves are false**, and the same
file's coverage table said 46 of 46 while this entry said zero; the table was
right. Established by reading the files rather than by trusting either number:
upstream's `tests/batch_insert.rs` holds **46** `#[test]` functions, and
`test/upstream_batch_insert.zig` holds a `test "batch: <upstream name>"` block
for each of the 46 — one per upstream case — plus one port-only test, and the
string `batch_insert` occurs in `src/hexane/hexane_test.zig`, `src/read.zig`,
`test/upstream_block_tests.zig`, `test/upstream_batch_insert.zig` and
`test/upstream_save_load_orphans.zig`. The one gate clause still open on P5 is
its second, the `save()`-modulo-DEFLATE comparison, which is a missing
assertion rather than a missing file.

### 2. The `_at` historical variants

**Closed 2026-10-01.** `API.md` §Known gaps item 2 said this was "one optional
`?[]const ChangeHash` per read signature, and every walk underneath already takes
a `?Clock`, so no body changes" — and that is **what happened**, with one
exception the gap did not foresee. `src/read.zig` now answers at caller-named
heads on **fourteen** readers: the
eleven `_at` readers (`getAt` `read.rs:266-271`, `getAllAt` `:293-298`,
`lengthAt` `:149`, `keysAt` `:55`, `valuesAt` `:137`, `textAt` `:180-184`,
`spansAt` `:190-194`, `marksAt` `:158-162`, `mapRangeAt` `:99-104`,
`listRangeAt` `:118-123`, `parentsAt` `:40-44`) and the three cursor readers
`getCursor`, `getCursorMoving` and `getCursorPosition`, with `hydrate`,
`markSetAtIndex` and `getMissingDeps` beside them. **This entry then named
`getCursorAt` (`:199-204`), `getCursorMovingAt` (`:224-230`) and
`getCursorPositionAt` (`:237-242`) as three further spellings, and that is
wrong.** Upstream carries `at` **on those three methods themselves** (`:203`,
`:228`, `:241`) and has no second name for any of them, so the port's three
`_at` names were a port-only split and **have been removed**; the heads are in
the three signatures, in upstream's own argument position. **The same cutover
relabelled one refusal**: `getCursorPosition` answers `error.InvalidCursor` for
a cursor naming a row of another object where it used to answer
`error.InvalidIndex` unscoped, which is upstream's own
`.ok_or_else(|| InvalidCursor(cursor.clone()))` on the seek's empty answer
(`automerge.rs:1778-1781`) and is what the same cursor already answered with a
clock. The one thing that did need building is
`Document.clockAtScope` (`src/doc.zig:5477`), upstream's `Automerge::clock_at`
(`automerge.rs:1236-1247`): the unsuffixed readers resolve their clock through
`readScope`, which reads the **isolation's** heads, and six of the new readers
hand a walk back — and a walk copies the `Clock` by value and borrows only its
`slots`, so the clock has to outlive the call. It shares the document's one
existing cache rather than adding a second.

### 3. The gate arithmetic that does not add up

`plan.md`'s gates and `test/` disagree about what "ported case-for-case" means,
and the number this entry rested on cannot settle it. **"123 of the 293 upstream
integration cases have no name in the port" is a name-presence count**, which is
the instrument this file retracted once already — the port renames every ported
case into English, so it under-counts by a factor of three. Measured by the
`test "<upstream file>: <English name>"` convention instead, the table under
*Test state* records all ten upstream integration files ported, every case.
**One measurable gap is left and it is the hexane suite: 181 of 284 distinct
upstream names present, 103 missing** (instrument named under *Test state*).
Either the gates are the contract and the hexane work is outstanding, or the
gates name the wrong files. **Decide which, in writing, before the next
round** — a gate that cannot be met is worth more than a gate that is quietly
redefined.


#### `tests/rich_text_fuzz_crash.rs` — the other half of the totality gate

**Closed 2026-10-01, 8 of upstream's 9, and it is not a second copy of the
8-fixture suite.** `src/storage/totality_test.zig` **mutates** well-formed
documents — 885 truncations, 7,144 bit flips, 1,413 hostile DEFLATE streams — so
what it proves is that the framing and column decoders are total. Seven of these
nine cases build their document **through the writer**, from the operation
sequence a fuzzer produced and a human minimised, and the defect each one guards
is **semantic**: a `MarkEnd` spliced before its `MarkBegin`
(`rich_text_fuzz_crash.rs:194`), a `length` counting a conflicted text element
twice (`:164`), a zero-width mark leaking into a different text object (`:118`),
and a **panic** in `BatchApply::apply` while validating op order when a
zero-width unmark on an *empty* text object is synced (`:64`). **A byte mutation
cannot reach any of them**, because the input is a *valid* document whose
*operation order* is what is under test.

**No panic, no hang, no unbounded allocation.** All eight run in **0.64 s and
0.78 s wall clock at 10.5 MB and 12.6 MB peak RSS** over two runs of the whole
debug binary (`/usr/bin/time -v`). The boundedness is **argued, not timed**: the
only untrusted bytes in the file are the 207 of
`test/fixtures/broken_zero_width_mark.automerge` (byte-compared against the
reference before use — identical), whose framing holds the magic **once**, so
`parseChunks` runs once against a ceiling of `207 / 10`; and its chunk type is
`0x00` (`document`), **not** `compressed`, so **the DEFLATE decoder — the one
loop whose trip count is not a function of the input — is never entered**.

**Every named error is asserted by name**, not as "it did not succeed":
`error.InvalidMarkOrder` (`opset/index.zig`; upstream's
`ReconstructError::InvalidMarkOrder{Doc,Changes}`, both of which render
`"invalid mark operation order: …"`) and `error.InvalidValueType`
(`transact.joinTextValues`; upstream `InvalidValueType { expected: "a string",
unexpected: "Scalar(Int(1))" }`). A third-party probe of the reference for all
nine answers is `tools/oracle`'s new `richfuzz` subcommand.

**The one gap is `Automerge::rescue`** (`:232-243`), recorded at its own
upstream line. `rescue` is "load with `MarkOrderValidation::AllowInvalid`, then
`hydrate(None)`" (`automerge.rs:894-904`) and **the port has neither**: no public
load door skips the mark-order check, and `API.md` §Known gaps item 5 records
that there is no document-level `hydrate`. `src/root.zig` does not export
`storage.document`, so a consumer cannot build an op set from a document chunk
at all — **the gap cannot be closed by hand from outside the crate**. The
refusal half of the pair, case 8, is ported and green.

### 4. The `-Dslow-path` build option — closed 2026-10-01

There is now a `-Dslow-path` option in `build.zig`, carried into the library
module as `build_options.check_slow_paths` and read by both checks upstream
gates behind `slow_path_assertions`: `OpSet.seekOpsByIndex`'s fast/slow
cross-check (`src/opset/op_set.zig`) and `SlabBTree.assertSound`
(`src/hexane/btree.zig`). `zig build slow-path` runs the unit tests in a build
where the option cannot be off, so the checker is never a check nobody runs.
Both halves are demonstrated: a corrupted tree is `error.InvariantViolation`
with the option and silent without it, and each half fails if the gate is
removed. What is left is **not** the mechanism: it is the finding the option
made on its first run, and the cost.

**It found a defect.** With the option off the library suite is 1229 passed /
1 skipped / 0 failed / 4m58s. With it on: 1228 passed / 0 skipped / **2 failed
/ 2 leaked** / 8m17s, both failures in `src/cursor.zig` and both from
`OpSet.seekOpsByIndex`'s fast/slow cross-check (`op_set.zig:2852`,
`expected error.InvalidCursorOp, found error.Invariant` on a text cursor at
`cursor.zig:1840`). That arm was comptime-dead until the option existed, so the
default build could not see it; re-running the frozen test binary reproduces
`1228 passed; 0 skipped; 2 failed` and `2 tests leaked memory`, so it is the
source state and not a concurrent edit. **Diagnosing it is a separate slice
and is not done.**

**Cost.** The `src/hexane/btree.zig` suite goes 2.46 s / 29 passed / 1 skipped
to 4.72 s / 30 passed / 0 skipped — that is the deep sweep the option buys. The
whole library suite goes 4m58s to 8m17s, the rest being the cross-check on
every `seekOpsByIndex` call site. Both Debug, both on the machine measured,
2026-10-01.

**`zig build ctest -Dslow-path` is green: 17/17, exit 0.** That combination is
new rather than a repeat — `cabi_lib` in `build.zig` imports `zautomerge`,
reaching the C ABI since it was added, with no wiring. The option-off run is
also 17/17, so the C surface does not move. `zig build conformance` is the one
gate the option cannot touch: it builds no Zig code (only `sh
tools/link-oracle.sh`, `cargo run` and `cmp`), and its subject is bytes from the
reference, which no comptime flag changes. The tests that *read* those vectors
are in the library test binary, which `zig build test -Dslow-path` already
covers.

**One environment fact the note below states without its mechanism, which is
the part worth keeping.** `LD_LIBRARY_PATH` must be **absolute**, and the reason
is the *working directory*, not the variable. `run_ctest` sets it to
`test/c/suite` (the `run_ctest.setCwd` line in `build.zig`), because upstream's
own CMake step arranges it that way for the four fixture-reading cases. So a
relative `LD_LIBRARY_PATH` resolves against `test/c/suite`, the loader does not
find `libcmocka.so.0`, and the step dies with exit 127 — reported as
`ctest transitive failure → run exe automerge-c-test failure`, which reads as a
build failure and is not one.

**The trap in it is that the two halves of one command line resolve
differently, and only the runtime half breaks.** `-Dcmocka-prefix` is consumed
at *build* time — `addIncludePath`/`addLibraryPath` on the module — so a
relative prefix works. `LD_LIBRARY_PATH` is consumed at *run* time by the
child, whose cwd is `test/c/suite`. So an agent who passes both relatively
sees the prefix succeed at link time, concludes the shape is right, and meets
the failure only after the whole link has finished. That is the same shape as
§1.1 one layer out: exit 127 and a red step are each compatible with "the code
is fine and the invocation is wrong", and only the message tells them apart.

**The durable fix is two changes, not one, and the measurement is why.** The
obvious one is the missing rpath — `each_lib_rpath = true` on the
`automerge-c-test` `Step.Compile`, the zig flag being `-feach-lib-rpath`
("ensure adding rpath for each used dynamic library") — and it is **not
sufficient on its own**. Measured on a two-line executable linked against the
prefix's `libcmocka.so.0`:

- `-L <absolute>/lib64 -feach-lib-rpath` → `RUNPATH: [<prefix>/lib64]`, runs from any working directory with no `LD_LIBRARY_PATH`, exit 0.
- `-L ../cmocka-prefix/lib64 -feach-lib-rpath` → `RUNPATH: [../cmocka-prefix/lib64]`, and from `test/c/suite` it fails with **the same `libcmocka.so.0` message and the same exit 127**.

So the rpath supplies the *entry* and the prefix supplies its *value*, and a
relative prefix produces a relative entry that is just as cwd-dependent as the
environment variable was. The pair is: **absolutise `cmocka_prefix` once**
(`b.pathFromRoot(prefix)`, public but documented as low-level) before it reaches
`addIncludePath`/`addLibraryPath`, **and** set `each_lib_rpath`. **Done, both
halves**: `build.zig:539` takes `b.pathFromRoot(prefix)` unless
`std.fs.path.isAbsolute(prefix)` is true, and `build.zig:612` sets
`ctest_bin.each_lib_rpath = true`. Six lines in `build.zig`, no test changes,
and it deletes a requirement from the invoker: the `LD_LIBRARY_PATH` export
described above is obsolete, the prefix is all the step takes, and a relative
`-Dcmocka-prefix=../cmocka-prefix` now works.

### 5. Gates measured, and one environment note

`zig build test`, `zig build conformance` and `zig build ctest` were all
**not measured** in the previous revision of this file; all three are measured
now, at the top of this file. `zig build ctest` needs `-Dcmocka-prefix=<dir>`
naming the directory holding `lib64/libcmocka.so` (here `../cmocka-prefix`, a
sibling of this repository, which is the default `test/c/build-cmocka.sh`
derives from the repository's own location); **without it the step does not
fail at the launch, it fails at the link**, with `unable to find dynamic system
library 'cmocka' using strategy 'paths_first'` and a search list that does not
include the prefix — which reads like a missing dependency rather than a
missing flag. That is the whole of the long-standing "`zig build ctest`
FAILS, reason never captured": there is no defect in the C ABI or the suite,
only an argument the gate does not pass. With the prefix the suite links,
runs and passes. The house gate was not run.

## How to work on this

- Read `AGENTS.md` first, then `plan.md` §6 for the phase you are in, then the
  matching section of `docs/survey/`. Every claim in the survey carries a
  `path:line` into the Rust source; do not work from memory of the Rust code.
- The test command is `zig build test`, or
  `zig test -ODebug -Mroot=src/root.zig` for the library suite alone. A module
  that `src/root.zig`'s test block does not name does not have its tests run —
  and a test that fails to compile in a module the block *does* name takes the
  whole suite down, which is what `src/c/sync.zig` demonstrates from the other
  direction.
- A test that instantiates a generic wrapper is not a test that calls its
  methods. `column.Shiftable(I)` resolves the *type* and leaves every method
  body unanalyzed, so `op_iter.zig`'s `assertShiftable` passed over six
  sub-iterator methods whose declared return type (`! ?T`) did not match
  their body (`!T`); an error union does not narrow into an optional payload.
  They surfaced only when a consumer wrapped a sub-iterator and forwarded the
  kernel, because that is what finally forced the analysis. Where a
  conformance mark exists for a type, something has to call through it.
- The repository is on a network export and the build cache should not be: put
  `ZIG_GLOBAL_CACHE_DIR` and `--cache-dir` on a large local scratch volume, and
  never let two builds share one. A system volume's `/tmp` is small; a dozen
  agents each with a private cache will fill it.
- `zig build conformance -- fixtures` runs the Rust reference against the
  corpus and prints the same 18 results the manifest records. `doc`, `change`,
  `codec`, `diff`, `converge` and `sync` emit the golden vectors to compare a
  Zig implementation against.
- The reference checkout is read-only. Never build in it, never modify it. And
  **do not trust `AUTOMERGE_REF`**: it points at another machine's path here.
  Use `../github-automerge-automerge`, or fix the export.