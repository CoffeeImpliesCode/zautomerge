# zautomerge: direct Zig translation of automerge

Port target: the `automerge` crate v0.12.0 and its `hexane` storage engine
(`hexane` 1.0.0-alpha.5) from `../github-automerge-automerge` at commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, to Zig 0.16.0.

The survey that grounds every claim below lives in [survey/](survey/); each
section carries `path:line` citations into the Rust source. Read a section
before changing anything that depends on it.

## 1. Compatibility contract

`zautomerge` is a **direct translation**: same data model, same CRDT
semantics, same public operation names, same wire formats. It is not a redesign
and not a binding layer over Rust.

Three things are normative and must be byte- or behaviour-exact:

1. **Document format.** A file written by `automerge` 0.12.0 must load in
   `zautomerge` and vice versa, including the compressed-change-chunk variant.
2. **Sync protocol.** A `zautomerge` sync state must interoperate with an
   `automerge` one in both directions, including the v1 message type for peers
   that do not advertise v2.
3. **Change hashes.** Change hashes are SHA-256 over the encoded change, so the
   change encoder is a compatibility boundary. Any change to column ids,
   column order, or the value wire format changes every hash. See
   [survey/03](survey/03-storage-columnar.md) for the exact encoders.

One thing is explicitly **not** normative: the exact bytes produced by
`save()`. DEFLATE output is not reproducible across implementations, so
`zautomerge.save()` produces a different, equally valid encoding. Equivalence
is checked by loading the output with the Rust reference and comparing the
materialized document, not by comparing bytes. Everything except the DEFLATE
stream is byte-exact.

Text indexing: UTF-8 code points by default, matching the upstream default
(`text_value::TextValue`, feature `utf8-indexing`). The wasm binding's forced
UTF-16 is a binding policy, not a format requirement; `zautomerge` makes the
encoding a document-level field and a compile-time default, so a consumer can
build a UTF-16-indexed document. See [survey/07](survey/07-bindings.md) §Risk 2
for the divergence this avoids in Rust.

### 1.1 What the contract is checked against, and how hard

This section is a statement of what a reader of this repository may rely on.
Every claim in it was **measured by running the thing that produces it** on
2026-10-01, and the two strongest of them were **proved by breaking them**.

**The change-hash property is a property, not a hope.** `src/doc.zig:5941` and
`:5943` hold the two expected hashes as **string literals**, and the bytes they
are compared against (`reference_change_0` / `reference_change_1`, `:5940`,
`:5942`) are literals too, decoded from hex. **Neither is recomputed from the
port's own output**, which is the failure this claim is most prone to: a hash
derived from the port is a hash that moves with it. Both literals match
`test/golden/change.jsonl` exactly, and that file is produced by the reference
oracle. The property is exercised **in both directions**:

- **decode-and-re-encode** — a change chunk the *reference wrote* re-encodes to
  the reference's bytes **and** the reference's 32 hash bytes,
  `src/doc.zig:6425` (plain framing) and `:6442` (compressed).
- **encode-what-the-reference-wrote** — `src/doc.zig:9003`, *this port's write
  path produces the reference's own change chunks, byte for byte*. It builds the
  oracle's document through this port's own transactions, requires
  `changes.len == 2`, and asserts per change both
  `expectEqualSlices(owned.parsed.change.bytes, built.body)` and
  `expectEqualStrings(want, got)` against the reference's hash.

**The golden-vector gate is not a tautology.** `addGoldenVector` in `build.zig`
captures the oracle's output into the **build cache** and `cmp`s it against the
committed `test/golden/<name>.jsonl`; the write path into `test/golden/` is
reachable only under `-Dconformance-record`, which is the same function's record
branch. Structure is not proof, so it was **proved by breaking it**: one byte of
`test/golden/change.jsonl` was flipped and `zig build conformance -- change`
failed, naming both files in the `cmp` —
`cmp /home/tmp/…/o/4c715b…/change.jsonl /vol/…/test/golden/change.jsonl`,
`Build Summary: 2/4 steps succeeded (1 failed)`. The file was then restored and
confirmed **byte-exact by sha256** (`0689ff5d…` identical before and after), and
the gate returned to 4/4. Full sweep: **18/18 steps, 8 vectors**, each
regenerated from the reference and compared.

**The honest caveat, which is part of the claim.** These checks cover **the
vectors the oracle chose, not the whole format**. That is what the 8 golden
vectors and the **18-file fixture corpus** (`test/fixtures/manifest.zig`, 5
`.load_ok` and 13 `.load_err`, checked 6/6 by `test/fixtures_test.zig`) are for,
and a reader should weigh the property as *strong on the vectors it covers,
absent elsewhere*.

**A falsification is only evidence when it fails for the right reason.** Every
break in this repository — the golden vector's byte, the batch suite's key sort
and its write-path replay — was checked the same way, because a falsification
that fails for the wrong reason is not a falsification: **an exit code says
something went wrong, it does not say what.**

**And the count that tells you which is `FAIL`, not the exit code.** Read
precisely:

> **`FAIL=0` is not "zero tests failed". It is "the run never started."**

A compile error anywhere in the library exits non-zero and produces **zero**
`...FAIL` lines and **zero** `...OK` lines. **The `FAIL` count is the only one of
the three signals that distinguishes a blocked run from a real failure**, because
the other two — a non-zero exit, and an error line in the log — are compatible
with both states. Reading a compile-blocked run as a failure in one's own slice
has happened repeatedly today, by several agents — **three of them within one
hour, counted in a single report** — and each time the exit code alone said
something compatible with the wrong answer. **The figure is worth keeping only
while it stays attached to that report.** An unenumerable tally is not a
defensible number: the auditor's own was "four times, by four agents", and it was
wrong before the ink was dry, having been overtaken by events rather than by any
mistake of arithmetic.

**The concrete instance of that failure mode, which cost three agents the same
hour.** `@import("build_options")` is reached by `src/opset/op_set.zig` and
`src/hexane/btree.zig`, so a bare `zig test` from the command line has to supply
it, and **the `--dep` has to attach to the module that needs it** —
`-Mzautomerge=src/root.zig` for a consumer test that imports the library by
name, and `-Mroot` when the root *is* the library. Putting `--dep
build_options` *before* `-Mroot=` attaches it to the root module instead and
produces the identical `no module named 'build_options' available within module
'zautomerge'`. All three read that message rather than counting `FAIL`, which
is the failure mode this section is about. **Through `zig build` none of it
arises**, and that is why a gate number from `zig build` is worth more than a
filtered run.

So a falsification, or any verification, counts only when **the `FAIL` count is
non-zero with a diagnostic naming the fault**; a **non-zero exit** and **zero
compile errors** corroborate it. And the symmetric reading matters just as much:
**a green run whose `OK` count is zero has tested nothing**, which is why
`zig build slow-path` deliberately runs with no filter — a filtered build reports
`0 passed` and exits 0, which is a gate that passes by having stopped testing
anything.

### 1.1a A green assertion that cannot fail

**Wrong because nothing verified where a claim came from has no repair path.
Wrong because someone checked it carefully and got it wrong does.** The
distinction is what separates "this is right" from "someone checked this", and it
is why a claim whose instrument was never tested cannot be repaired by re-running
it.

**The instance, so this is not an abstraction.** An audit of this port produced an
inverted gate ranking — it named P9 the weakest when P9 was the most completely
ported — from an instrument it had never checked against the tree. It defended
that ranking through two rounds of review and retracted it only on discovering
that **this port renames every ported test case into English**, so counting
upstream function names under-counted by a factor of three. **The fix was a
retraction, not a patch.** A number derived from a bad instrument cannot be
corrected by re-running it, because re-running it reproduces the same wrong
number; a number derived from a good instrument that happens to be wrong can be.
**Nothing was wrong with the reading, the arithmetic or the care — the instrument
was unchecked**, and that is a different failure with a different repair path.

**A test that cannot be shown failing has not been tested.** §1.1 says a
falsification counts only when the `FAIL` count is non-zero with a diagnostic
naming the fault. This is the same rule pointed the other way, and it governs
what you write rather than what you read: **a suite that was green before the
code was broken and green after it has verified nothing**, and nothing in that
suite's own output can tell you so.

**The cheapest demonstration, and for a method with a dispatch it is the only
cheap one: break each arm in turn and watch the suite go red.**

**The forms this port has shipped. Every one is a green assertion that cannot
fail, and every one was found by breaking something rather than by reading a
test — except the third, which is named and not yet shown. A form that has not
been broken is not shipped, and this list is where that distinction has to be
kept:**

- **An assertion over only what must be absent** passes on an empty result. "The
  mirror does not show the write the heads exclude" is satisfied just as well by
  a mirror with nothing in it, which is why the same test must also prove the
  excluded write **is** visible at the present and that the heads **do** include
  what they should.
- **An equality helper that compares less than its name claims.**
  [`Text.eql`](../src/hydrate.zig) is `asStr()` alone, so every test that uses it
  reads as a test of text equality and is a test of text *content*; the marks
  are invisible to it, and a mirror holding the wrong marks compares equal.
- **A fast path and a slow path that must agree, where only one is exercised.**
  **IDENTIFIED, NOT YET SHIPPED — and this bullet is the one this section's own
  rule applies to.** `OpSet.seekOpsByIndex` has a fast path and a slow path that
  must answer identically, and until the `-Dslow-path` option existed the slow
  one was comptime-dead, so nothing compared them. Turning the option on
  (`zig build slow-path`) makes the comparison live and it **disagrees**:
  `OpSet.seekOpsByIndex`'s `opsFoundEqual` arm reports `error.Invariant` on two
  `src/cursor.zig` tests, and the op-set checker reports *right is out of row
  order*. **Those two are option-on only, and they are not
  `src/hexane/**`'s to fix.** A third symptom in that report — *node reachable
  twice*, from `SlabBTree.assertSound` — **was** `src/hexane/btree.zig`'s, and it
  is resolved; see below.

  **The `column.zig` half of this, measured and closed 2026-10-01.**
  `src/hexane/column.zig` was red in the option-**off** build too, under three
  different test names across two runs, and it is **green in both builds now**.
  Two independent defects accounted for all three names, and **the tree as it
  stood could not tell them apart**, because the record of the first lived in a
  comment in a test file rather than at the function:

  - `PrefixColumn::iter_range` is `iter()` plus `advance_by(start)`, which
    **accumulates** the skipped widths into `total` (`prefix.rs:669-676`,
    `:903-907`), so a window opened at `s` reports **absolute** totals. The port
    had a window-*relative* variant, and the op set compensated for it at
    `OpSet.calculateMarks`. The compensation's symptom was not a wrong number but
    a **refusal**: `cast(usize, 0 - base)` is `error.Overflow` for every text
    object that does not begin at column row 0, and re-introducing the relative
    window took the tree from 46 to **69** `...FAIL` lines, 23 of them in that
    family. The record now sits at `prefixIterRange` itself
    ([`src/hexane/column.zig`](../src/hexane/column.zig)) and names the second
    half to undo, in `src/opset/op_set.zig`.
  - `Iter::shift` is `set_max(range.end)` then `advance_to(range.start)`
    (`column.rs:542-545`, `shift.rs:51-54`) and the port's was the first half
    alone, while its own doc comment claimed both — **a shape error, not a
    boundary one**: `shift(5..9)` on a fresh cursor left `pos()` at 0, and it did
    so on five consecutive runs, so the brief's "seed-dependent" reading of it
    was wrong. `scan_to_value_on_rle_columns` now calls `shift` alone.

  **What the two tell the method.** The option-on build being green is this
  bullet's own promotion condition and it is **not** what closed these: neither
  defect is reachable only with the option on. What closed them is that each
  was **falsified** — a `prefixIterRange` that reported relative sums and an
  `Iterator.shift` that only truncated, each producing a non-zero exit, zero
  compile errors and a `...FAIL` naming the fault — and then measured over
  **400 seeds / 40,998 prefix windows**, **60 seeds / 2,400 random row windows**,
  and **200 seeds / ~80,000 checked btree mutations**, clean in both builds. The
  `node reachable twice` report was falsified the same way: an injected aliased
  child slot in `makeLeaves` is reported by both the option-off sweep and the
  option-on deep sweep as `node 3 is reachable twice`.

  **So the promotion condition stands and is still unmet**, on the parts that
  are not `src/hexane/**`.
- **A dispatch whose arms are all reached through a helper rather than through
  the method under test.** The instance is below.
- **A condition computed correctly, adjacent to the site that needed it, with the
  value discarded.** `Document.loadIntoWith` already asked
  `chunks[0].typ == .document` to decide where a document's changes begin, and
  dropped the answer **one line above** the `if` that needed it — so the first
  conjunct of upstream's rule was being evaluated by nobody. `MissingDeps` was
  not missing either: the port raised it from eight other sites in the same file.
  **This is the same failure one layer up from an assertion that asserts nothing,
  and it is the cheapest to miss, because the code that computes the condition
  looks exactly right.** The port's other defects this session were all *a rule
  computed in one place and applied in another*; this one is *a rule computed in
  the right place and not connected to its consumer*.

**The instance, because the evidence is what makes a rule stick.** `ReadDoc::hydrate`
([`src/read.zig`](../src/read.zig), 2026-10-01) dispatches on the object's type —
map, list, text (`automerge.rs:1645-1649`). Its first three tests all hydrated
`.root`, and **a root is a map**, so the `list` and `text` arms were reached
only through `hydrate.zig`'s own `hydrate_op` and never through the method under
test. **Rewriting the `.text` arm to build an empty text left all three tests
green** — `FAIL=0`, exit 0, every case `OK`.

**The suite was not weak. It was aimed one layer above the thing that changed**,
which is the part worth carrying: the assertions were about map keys, scalars
and mark *sets*, all of which a broken text arm leaves intact. A fourth test
that calls the method on a list and on a text — at `null` heads and at `heads` —
closes it, and both mutations now fail it: `.text` building `""`, and `.list`
routed to the map arm.

**The generalisable form: a method whose dispatch has arms is tested by its
arms.** A test that only ever calls it on the most common input has not tested
the others, whatever it asserts.

**And the boundary, which a citation without it would hide.** That is the same
shape as P5's "two routes to the same rows" (`expectKeys` and
`expectSameThroughApplyChanges`, §P5), **but a two-route comparison is not
equivalent to a content assertion, and the difference is measured.**
`expectSameThroughApplyChanges` pins the two routes' **agreement**; it cannot see
a defect **both** routes share, because a shared defect is not a disagreement.

**Measured on this tree, 2026-10-01.** Giving the source document an extra
operation *before* the replay — so the replayed document inherits it and **both**
routes end up holding the same wrong thing — the replay fired **zero** times
across all 43 cases that carry it: `FAIL=0`, no compile errors. The one test that
did fail was the probe's own fault, an `InvalidOp` in the single `.manual` case,
not a detection. So a third comparison built on the assumption that a route
comparison certifies correctness would be **blind in exactly the class that
matters**, and the routes need a content assertion beside them and not only each
other. `expectKeys` is the content assertion in that pair, and it is the half
that would catch what the replay cannot.

### 1.1b A measurement taken against the thing it measures

**A measurement taken against the thing it measures is valid only until that
thing changes — and the thing that changes it is usually the fix.** This is
stronger than "re-measure stale numbers", because it says the *fix* invalidates
the evidence *for the fix*.

The instance, and it is the one above. The `43 opportunities, zero detections`
figure was taken against an `OpSet.seekOpsByIndex` whose fast and slow paths
**disagreed**. A clamp that repairs that disagreement changes exactly the
agreement the probe was measuring. **Carrying the number forward would be
recording a measurement of a tree that no longer exists** — and it would arrive
through the most defensible route in the room, because the number *was* measured,
by falsification, and written down with its evidence. **That is the carry-forward
error this document has been about all day — an instrument unchecked, a stale
numerator — arriving through a number that was true when it was written.**

**So the rule is: a measurement whose subject is the thing being repaired must be
re-taken after the repair, and if its value moves, the move is recorded with the
reason.** A measurement that does not move is evidence the repair changed nothing
it could see, which is worth knowing too. **The test of a fix is not the test
that failed before it; it is the same test, run again afterwards, on the tree the
fix produced.**

### 1.2 What a reader may *not* rely on: a line number is not a stable reference

**Two halves, and the second is the operative one.**

**First, the survey's citations are known-drifted.** The [survey](survey/) is the
reference for **claims**, and its `path:line` citations are wrong in **65 of 144
sampled**, file-local and one-directional in each file. They were **deliberately
left wrong rather than guessed**, because a known-wrong citation is visible and a
confidently-wrong one is not. The pattern and the count are in
[`survey/README.md`](survey/README.md).

**Second — and this is the half that governs what you write — this is not a
legacy problem to be cleaned up once. It is the standing cost of citing a line
number at all.** The evidence is from the same hour, by the auditor who measured
the 149 of 184 stale citations in [`API.md`](../API.md):

* Three `build.zig` citations written into this plan and into `STATUS.md` were
  **wrong within the hour**, because a neighbouring comment block grew by 28
  lines and moved the step from `:266` to `:294`.
* On another slice, an agent broadcast an insertion anchor three times in about
  twenty minutes and **two of the three were stale** — once because the number
  named the wrong step, once because the region moved after it had been
  corrected. **Four peers had taken the number.**
* Its `src/**` citations, re-verified against the tree the same morning —
  twenty of them — **all landed on the function they name**, because nothing was
  editing `src/**` at the time.

**The rule that survives all three cases: cite the anchor's identity, never its
number.** `path:line` is the right form for a file nobody is editing —
`src/**`, and the read-only reference checkout, which is frozen by construction —
and **the wrong form for any region under concurrent edit**. For a region under
edit, name the declaration or the step and let the reader re-derive the number
with a fresh read: "after `test_step.dependOn(&run_upstream_batch_insert_tests.step);`",
not "after line 266".

**And the writer's half, which is the half that is easy to skip:** a reader who
re-derives a number protects themselves; **a document that asserted the number
outlived the edit did not.** When a region is moving, do not write the line at
all.

## 2. Upstream shape

| Crate | Path | Lines | Port? |
| --- | --- | --- | --- |
| `automerge` | `rust/automerge` | 64,979 / 163 files | yes |
| `hexane` | `rust/hexane` | 32,664 / 39 files | yes — `automerge` depends on it (`Cargo.toml:26`) |
| `automerge-wasm` | `rust/automerge-wasm` | 6,708 | later phase, C ABI first |
| `automerge-c` | `rust/automerge-c` | 7,507 | later phase |
| `automerge-cli` | `rust/automerge-cli` | 1,395 | out of scope |
| `automerge-test` | `rust/automerge-test` | 487 | out of scope, it is a test DSL |
| javascript, interop | `javascript`, `interop` | — | out of scope |

Every number in that table is a **whole-crate** count (`src` + `tests` +
benches + `build.rs`), re-measured 2026-10-01 and all six correct.
`docs/STATUS.md` quotes a different, also-correct measure — `src` only, 54,589
and 29,683 — and the two were being compared as if one contradicted the other.

`hexane` is not optional: `automerge` stores its op set in `hexane::Column`
instances ([survey/02](survey/02-transaction-opset.md) §Surface,
`op_set2/columns.rs:16-35`). Porting `automerge` without `hexane` is not
possible, and porting it as a flat array-of-structs would forfeit the
compressed on-disk layout that the document format mandates.

Dead upstream code that is **not** ported, verified by declaration search:

- `op_set2/skip_list.rs` (20,160 bytes) — declared by nothing, referenced by
  nothing.
- `query/` (`list_state.rs`, `seek_mark.rs`, 372 lines) — not declared in
  `lib.rs`, no external use.
- `indexed_cache.rs` — declared, all real methods commented out, zero uses
  outside the file.
- `automerge-cli/src/change.rs` — not `mod`-declared in the CLI.
- ~~`hexane` features `deep_fuzz` and `bijou64` — no `cfg` reads them.~~ **This
  was wrong, and it was checked (2026-10-01).** `bijou64` is read at
  `hexane/src/codec.rs:358` and `:362`, which gate a complete `Bijou64` `Codec`
  implementation, and `Cargo.toml:20` wires it to `dep:bijoux`. `deep_fuzz` is
  read at `hexane/src/edit_fuzz.rs:493` and `:1142` and four times in
  `hexane/src/tests.rs`, all as `#[cfg_attr(test, ignore)]` guards. Neither is
  dead code. `Bijou64` is a second unsigned codec that the format does not
  currently use, so the port is still right not to have it — but the reason is
  that nothing selects it, **not** that no `cfg` reads it.

Feature gates that are part of the port's behaviour: `utf8-indexing`,
`utf16-indexing` (mutually exclusive), `slow_path_assertions` (invariant
checkers, test-only upstream), `wasm`. See
[survey/08](survey/08-conformance-history.md) for the full matrix.

## 3. Zig 0.16.0 mapping rules

One rule per construct, applied everywhere. The full per-slice discussion is in
the `## Zig mapping notes` section of each survey file.

| Rust | Zig 0.16 | Note |
| --- | --- | --- |
| `struct S { .. }` with private fields | struct with the same field set | keep field names and order; layout is load-bearing in the columnar path |
| `enum E { A, B(..) }` | `union(enum)` | payload-carrying variants map exactly |
| `#[repr(C)] enum` with explicit tags | `enum(c_int)` with explicit values | `AMvalType` and `AMmarkExpand` tag values are ABI; never renumber |
| `Option<T>` | `?T` | `NULL` in the C ABI maps to `?*T` |
| `Result<T, E>` | `!T` with an error set | 13 error types collapse to 3 error sets (§3.1) |
| `&T` / `&mut T` | `*const T` / `*T` | every container stores its allocator explicitly |
| `Vec<T>` | `std.ArrayList(T)` | unmanaged in 0.16; `ArrayListUnmanaged` is a deprecated alias. Every call takes the allocator |
| `String` / `smol_str` | `[]const u8` into an arena, plus an intern table | key strings are interned per document; never a `[]u8` the caller must free |
| `BTreeMap<K,V>` | `std.Treap` or a sorted `ArrayList` + binary search | see §5.1 — the port uses sorted arrays, not a treap |
| `HashMap` | `std.StringHashMapUnmanaged` / `AutoHashMapUnmanaged` | used only for interning and memo tables, never on the format path |
| `Rc<T>` | `*const T` plus an explicit lifetime owner | no `Rc` in Zig std; a returned value borrows the document |
| `RefCell<T>` | `*T` with a documented invariant | the lazily-built field carries its own `?T` |
| `Arc<T>` | `std.atomic.Value(usize)` refcount, or an explicit shared owner | only in the bindings phase |
| `Box::into_raw` | `gpa.create(T)` | the caller's allocator, not the page allocator |
| `Iterator` / `impl Iterator` | struct with `next() ?Item` | no allocation per iterator; an iterator is a value, not a heap object |
| `impl Trait` returned | concrete type | |
| `dyn Trait` | a struct of function pointers (`vtable`) | used for exactly one thing, §3.2 |
| `macro_rules!` in the public API | none | the `log!` macro becomes a comptime-switchable no-op or a `std.log` call |
| `serde` derive | hand-written encoder/decoder | only `autoserde` and the wasm JSON shapes need it |
| `panic!` / `unwrap` | `unreachable` where a preceding check proves it, else a real error | no `unreachable` on parser input |
| `#[cfg(test)]` invariant checks | `comptime` debug flag or a `slow_path` build option | a struct field behind `-Dslow-path`, not a separate code path |
| allocator-generic `impl Allocator` | `std.mem.Allocator` parameter | every public entry point takes one, except pure functions |

### 3.1 Error sets

Upstream has 13 error types, **31** variants on `AutomergeError`
(`automerge/src/error.rs:13-79`; this said 30, and the survey said 30 while
listing 31 rows), with hand-written `Display` strings. Zig has one global error
namespace, so three sets:

- `Error` — the document API surface: the `AutomergeError` variants that are
  observable through the public API, plus `OutOfMemory`.
- `ParseError` — anything reachable from parsing untrusted bytes: chunk
  framing, column decode, sync message decode, change decode. Every fuzz
  crasher in `tests/fuzz-crashers/` must produce a `ParseError`, never a crash
  and never a hang.
- `InternalError` — the asserts that upstream treats as impossible. Kept
  distinct so a slow-path build can surface them instead of `unreachable`.
  **`-Dslow-path` is a build option** (`build.zig`), and the port's spelling of
  upstream's `slow_path_assertions` feature is
  `pub const check_slow_paths: bool = build_options.check_slow_paths`
  (`src/opset/op_set.zig`), read by `OpSet.seekOpsByIndex` and by
  `SlabBTree.assertSound` (`src/hexane/btree.zig`). Off by default, which is
  upstream's default feature set; `zig build slow-path` runs the unit tests in
  a build where it cannot be off.

An upstream `panic!` that guards a reachable state becomes a `ParseError`
variant. The `too_many_ops`, `too_many_deps`, `overflow_in_length`, and
`invalid_deflate_stream` crashers are exactly this class.

### 3.2 Trait dispatch

`ReadDoc` (**34** methods, `read.rs:21-311`) and `Transactable` (**20**
methods, `transaction/transactable.rs:9-216`; this said 30 and 21) exist in
Rust because
`Automerge` and `AutoCommit` are two flavours of the same document, one
requiring an explicit `Transaction` and one managing it. In Zig this is a
single concrete `Document` plus a mode flag, and the "trait" becomes a `vtable`
struct only where a caller genuinely holds either flavour polymorphically:

```zig
pub const ReadOps = struct {
    ptr: *const anyopaque,
    get: *const fn (ptr: *const anyopaque, obj: ExId, key: []const u8) Error!?Value,
    // ... one field per ReadDoc method
};
```

Every other function is a plain generic or concrete function. A method that
would need `&mut self` on a read (`getHeads`, `getChanges` take `&mut self`
upstream purely for interior-mutability caching) takes `*Document` in Zig and
the cache is explicit.

## 4. Module map

`src/root.zig` re-exports the public modules. Names follow the Rust module
names so the two trees are diffable; the file layout mirrors it.

| Zig module | Rust source | Port notes |
| --- | --- | --- |
| `zautomerge.types` | `types.rs`, `exid.rs` | `ExId`, `ActorId`, `OpId`, `ObjType`, `Prop`, `SequenceType`, `TextEncoding` |
| `zautomerge.value` | `value.rs`, `op_set2/types.rs` | `ScalarValue`, `Value`, `ValueMeta`, `OpType` |
| `zautomerge.error` | `error.rs`, `columnar/encoding/col_error.rs` | the three error sets |
| `zautomerge.clock` | `clock.rs` | `Clock` = `[]u32` indexed by actor index; `SeqClock`; `ClockRange` |
| `zautomerge.change` | `change.rs`, `op_set2/change.rs` | `Change`, `ChangeMetadata`, `LoadChangeError` |
| `zautomerge.change_graph` | `change_graph.rs` | adjacency list, per-actor counters, cached clock per node |
| `zautomerge.change_queue` | `change_queue.rs` | Kahn topological sort + `ChangeBatch` |
| `zautomerge.opset` | `op_set2/**` | the op set: 16 columns, index columns, merge, batch apply |
| `zautomerge.storage` | `storage/**` | chunk framing, `ColumnSpec`, `RawColumn`, document and change chunks, compression |
| `zautomerge.columnar` | `columnar/**` | RLE, boolean, delta, raw encodings; the composite logical columns |
| `zautomerge.hthane` | `hexane/**` | `Column`, `Slab`, `SlabBTree`, the edit cursor, the codecs |
| `zautomerge.sync` | `sync.rs`, `sync/**` | `State`, `Message`, `BloomFilter`, v1 compatibility |
| `zautomerge.transaction` | `transaction.rs`, `transaction/**` | `Transaction`, commit, rollback |
| `zautomerge.doc` | `automerge.rs`, `autocommit.rs` | `Document` (Automerge + AutoCommit flavours) |
| `zautomerge.iter` | `iter.rs`, `iter/**` | `MapRange`, `ListRange`, `Spans`, `Keys`, `Values`, the diff machinery |
| `zautomerge.read` | `read.rs` | the `ReadDoc` surface |
| `zautomerge.patches` | `patches.rs`, `patches/**` | `PatchLog`, `PatchBuilder`, `ExposeQueue` |
| `zautomerge.marks` | `marks.rs` | `Mark`, `MarkSet`, `ExpandMark` |
| `zautomerge.cursor` | `cursor.rs` | `Cursor`, `OpCursor` |
| `zautomerge.textdiff` | `text_diff/**` | vendored Myers diff, Apache-2.0, attribution required (§9) |
| `zautomerge.hexane` | `hexane/**` | `Column`, `Slab`, `SlabBTree`, the edit cursor, the codecs |
| `zautomerge.hydrate` | `hydrate.rs`, `hydrate/**` | materialized mirror |
| `zautomerge.autoserde` | `autoserde.rs` | non-`serde` JSON projection |
| `zautomerge.anonymize` | `anonymize.rs` | whole-document rewriter |

Every public module is a separate file under `src/`, flat, mirroring the Rust
layout. `src/opset/` and `src/hexane/` are the only subdirectories, because
they are the only ones with more than six files.

## 5. Core data model

### 5.1 Identity

Upstream indexes actors by position in a per-document sorted actor table, and
every stored reference is that index. This is the single most important
structural fact for the port, because it is what makes the on-disk columns
`u32`-wide.

```zig
pub const ActorIdx = u32;          // index into Document.actors
pub const Counter = u32;           // an op counter; 0 means "no object"

pub const ExId = union(enum) {     // object identity
    id: struct { counter: Counter, actor: ActorIdx },
    root,
};
```

`ExId::Id` field order is `(counter, actor, index)` upstream
([survey/01](survey/01-core-api.md) §3); the third field is an in-memory
lookup hint and is not serialised. The port keeps `counter` and `actor` only,
and re-derives the hint, because a stale hint is worse than a missing one.

`OpId` is `(counter, actor)`. `ActorId` is the external byte string; the
document maps it to `ActorIdx` and owns the mapping for its whole life, so
`ActorId` never appears in a column.

Maps keyed by a hash map (`HashMap` in Rust) become a sorted `ArrayList` with
binary search, because the iterators and the change graph both need ordered
traversal; the hash map is only an accelerator for `ActorId → ActorIdx`.

### 5.2 Values

```zig
pub const ObjType = enum { map, list, text };
pub const Prop = union(enum) { key: []const u8, index: Counter, seq: SequenceType };
pub const ScalarValue = union(enum) {
    null,
    bool_: bool,
    int: i64,
    uint: u64,
    f64_: f64,
    str: []const u8,       // interned
    bytes: []const u8,     // interned
    counter: i64,
    timestamp: i64,
    actor_id: ActorId,
    value_ref: ValueRef,   // an object reference; enum with an object id + type
};
```

`ScalarValue` is stored in a raw column, not as a native Zig union, because
the wire format is a two-column split: `value_meta` (a `PrefixColumn` carrying
`ValueMeta`) and `value` (a `RawColumn` of `(byte_length << 4) | type_code`
plus opaque bytes). The union above is the **logical** model; the column
encoder is §6.3.

### 5.3 The op set

Sixteen columns, from `op_set2/columns.rs:16-35`, of which five are index
columns maintained alongside:

| Column | Zig type | Role |
| --- | --- | --- |
| `id_actor` | `Column(ActorIdx)` | op id actor |
| `id_ctr` | `DeltaColumn(u32)` | op id counter, delta coded |
| `obj_actor` | `Column(?ActorIdx)` | parent object actor |
| `obj_ctr` | `Column(?u32)` | parent object counter |
| `key_actor` | `Column(?ActorIdx)` | map key string actor |
| `key_ctr` | `DeltaColumn(?u32)` | map key string counter |
| `key_str` | `Column(?Interned)` | map key string |
| `succ_count` | `PrefixColumn(u32)` | number of successors |
| `succ_actor` | `Column(ActorIdx)` | successor id actor |
| `succ_ctr` | `DeltaColumn(u32)` | successor id counter |
| `insert` | `PrefixColumn(bool)` | sequence insert flag |
| `action` | `Column(Action)` | set / make-map / make-list / make-text / del / link / mark-begin … |
| `value_meta` | `PrefixColumn(ValueMeta)` | value type + length |
| `value` | `RawColumn` | opaque value payload |
| `mark_name` | `Column(?Interned)` | mark name |
| `expand` | `Column(bool)` | mark expand behaviour |
| `index.text` | `PrefixColumn(?u32)` | text length index |
| `index.top` | `PrefixColumn(bool)` | is this op a top op |
| `index.visible` | `Column(bool)` | visible flag |
| `index.inc` | `Column(?i64)` | counter increment |
| `index.mark` | `MarkIndexColumn` | mark begin/end index |

Rows are ordered by `(obj, elemid-or-key, id)`. That order is maintained by
`MapWalker` for maps and `Untangler` for sequences during merge, and it is what
every iterator assumes. Getting it wrong produces documents that load and read
back plausibly wrong, so §8 makes row order an explicit test gate.

`PrefixColumn` is the load-bearing subtlety: the length of every row is the
prefix sum of the previous row's value, which is what makes a single-column
sequence walk O(1) per row. It is the port's main correctness risk after
merging, and it is the reason `hexane` is ported rather than replaced with
plain arrays.

### 5.4 Ownership

Every public type that can return borrowed data states its owner in the
signature: `pub fn get(doc: *const Document, obj: ExId, key: []const u8) Error!?DocItem`
where `DocItem` is a copy, and `pub fn keyStr(doc: *const Document, idx: Interned) []const u8`
where the slice lives in the document's intern arena. No public function
returns memory the caller must free except the `save()` byte buffer and the
explicitly-owned `OwnedTransaction`.

`Transaction` upstream holds `&mut Document` for its whole life
(`manual_transaction.rs`); the Zig `Transaction` holds `*Document` plus a
generation stamp, and asserts the stamp at commit, because Zig cannot
enforce a mutable borrow across a call boundary.

## 6. Port phases

Each phase has an entry condition, deliverables, and a gate. A gate is a
command that must pass, not an intention. Phases 0 to 5 are the load-bearing
ones; nothing above 5 is worth doing until they are green.

### P0 — Scaffold and conformance harness

- Entry: none.
- Deliver: `build.zig` module graph, `test/` layout, the fixture corpus
  (17 files from `tests/fixtures/` and `tests/fuzz-crashers/`, plus
  `interop/exemplar`), a `tools/oracle` cargo crate that depends on the Rust
  reference through a symlink to `$AUTOMERGE_REF/rust/automerge`, and a
  `zig build conformance` step that runs the oracle and writes golden vectors
  into `test/golden/`.
- Gate: `zig build test` runs; `zig build conformance` produces vectors; the
  oracle crate builds with the pinned toolchain; every fixture is listed in a
  manifest with the expected outcome (`load ok` / `load err`).

**Verdict 2026-10-01 — SATISFIED.** `zig build conformance` is **18/18 steps**
and regenerates all eight vectors into the build cache and `cmp`-s each against
the committed copy (`addGoldenVector` in `build.zig`), so every vector is byte-identical to
what the reference produces now. `zig build test` runs; the manifest covers all
**18** corpus files (`5` `.load_ok`, `13` `.load_err`) and the agreement test is
6/6. The oracle builds against the pinned toolchain.

The oracle is the whole differential-testing story and it is worth building
first: without it, "compatible with automerge" is an opinion. See
[survey/08](survey/08-conformance-history.md) for the fixture expectations
(9 files, 1162 B, all-or-nothing load) and the 8 fuzz crashers that must all
yield an error.

### P1 — Foundation

- `types`, `value`, `error`, `clock`, `change` metadata, text encoding,
  interning.
- Internals needed by everything: LEB128 encode/decode (not in Zig std — only
  a DWARF-internal copy exists), SHA-256 (`std.crypto.hash.sha2`, present),
  raw DEFLATE (`std.compress.flate` with `Container.raw`; upstream uses
  `flate2::bufread::DeflateEncoder`, which is a raw stream, not a zlib
  container).
- Gate: LEB128 and the clock merge (`covers`, `merge`, `include`) are
  property-tested against the Rust oracle; the SHA-256 and DEFLATE round trips
  pass.

**Verdict 2026-10-01 — SATISFIED.** LEB128 is checked against the reference
through `test/golden/clock.jsonl` (110 records, `cmp`-ed on every conformance
run) and directly by 15 tests in `src/leb128.zig`; the clock merge is exercised
through the same vector. SHA-256 and DEFLATE round-trip in the chunk layer
(`src/storage/chunk.zig`, and a compressed change chunk is inflated and checked
at `src/storage/change_chunk.zig:1329`).

### P2 — hexane

- `Slab`, `Column(T, Encoding)`, `SlabBTree` (B = 64), the RLE and boolean
  codecs, `DeltaColumn`, `PrefixColumn`, `RawColumn`, the edit cursor
  (`edit::Edit`, one open slab across many edits), and `splice`.
- The per-type `Encoding` dispatch in Rust is a type-level map. In Zig it is a
  comptime switch inside a generic `Column(T, Encoding)`, so the type parameter
  carries the codec and there is no vtable.
- Gate: every codec round-trips bytes for random inputs against the Rust
  encoder; `SlabBTree` passes the upstream invariant checker, ported as a
  `-Dslow-path` test; the 193 KB `hexane/src/tests.rs` unit suite is ported
  case-for-case where it tests behaviour rather than Rust layout.
- Risk: the B-tree rebalance policy and the `SlabAgg` order-sensitive merge
  ([survey/06](survey/06-hexane.md) §2) are subtle. Budget for a second pass
  here rather than assuming a first pass converges.

**Verdict 2026-10-01 — PARTLY SATISFIED, and this is the weakest gate in the
plan.** With every upstream integration file ported bar one case of
`block_tests.rs`, clause 3 is the largest remaining gap in the port. Three
clauses:

1. *codec round trips against the Rust encoder* — **SATISFIED**.
   `test/golden/codec.jsonl` is 1,989 records generated by the reference and
   `cmp`-ed on every `zig build conformance`; four tests read it, one per codec
   (`src/hexane/{rle,bool,delta,prefix}.zig`).
2. *`SlabBTree` passes the upstream invariant checker, ported as a `-Dslow-path
   test* — **SATISFIED.** `-Dslow-path` is a real build option (`build.zig`),
   carried into the library module as `build_options.check_slow_paths` and read
   by both gated checks: `OpSet.seekOpsByIndex`'s fast/slow cross-check
   (`src/opset/op_set.zig`) and `SlabBTree.assertSound`
   (`src/hexane/btree.zig`), which is upstream's `check_invariants`
   (`btree.rs:1283-1360`) as an assertion. The checker is tested ungated
   (`btree.zig:2487` accepts a sound tree, `:2500` rejects ten corruptions),
   the gate is tested from both sides (`btree.zig:2634`: with the option a
   corrupted tree is `error.InvariantViolation`, without it the same tree is
   silent), and the sweep the option buys is upstream's own deep fuzz at its
   own scale (`btree.zig:2847`: 25 trials of 300 steps, skipped without the
   option). `zig build slow-path` runs the unit tests in a build where the
   option cannot be off.

   **The option found a defect on its first run; fixed 2026-10-01. That arm
   was comptime-dead until this option existed**, so no gate in the plan had
   ever compiled it. With `-Dslow-path` off the library suite was 1229
   passed / 1 skipped / 0 failed / 4m58s; with it on, 1228 passed / 0
   skipped / **2 failed / 2 leaked** / 8m17s, both failures in
   `src/cursor.zig` and both from the `seekOpsByIndex` cross-check at
   `op_set.zig:2852` (`expected error.InvalidCursorOp, found
   error.Invariant`). It was a defect in the port, not in the gate, and it was
   **not** closed by turning the cross-check back off.

   **Root cause: `listRegisterAtPos`'s third arm reads the element's own
   insert out of the `insert` column, and `get_index_for_total(0)` answers
   row 0 of the whole op set** — `get_index_for_prefix` returns `0` for a
   target at or below zero (`prefix.rs:605-608`) and `get_index_for_total`
   subtracts one (`:596-598`), while `pv.total()` is the number of `insert`
   rows at or before `pos` (`prefix.rs:706-710`). A sequence register whose
   element has no insert before it — a list's first row being a `set` hung by
   the head, or a row keyed by a map string — therefore got the register
   `0..pos + 1`, **rows of another object**: the fast path answered with the
   parent object's own `make_list` row that the prefix descent had already
   excluded. Two structures that must agree computing the same thing by
   different rules — `index.top` says row 1 is the element at index 0 of this
   object, the `insert` column says there is no insert before it — which is
   **the fifth instance of this port's most repeated failure shape** (after
   `mapKeyRow`, `SkipIter`'s skip unit, `scanForStickyMarks`' `run.value.value`
   and `propRange`'s absent key). The fix is `@max(…, range.start)`, and it
   is the identity wherever the write path can reach: `TxOp::list`'s key comes
   from `Op::cursor` on a row that already exists (`inner.rs:510-514`,
   `op.rs:1073-1082`), so it is always an earlier insert and `pv.total() >= 1`.

   **Both leaks were the checker dropping the answer it was checking.**
   `seekOpsByIndex` had no `errdefer` on the fast path's `OpsFound`, so its
   `return error.Invariant` at `:2852` leaked the `ArrayList` buffer
   `seekListOpsByIndexFast`'s `append` allocated — upstream's `assert_eq!`
   aborts and never returns (`op_set.rs:648`), this port returns and carries
   on. **The fix changed no fast-path answer on anything the default build
   can reach**, and the evidence is the cross-check itself: it compares the
   two answers on every `seekOpsByIndex` call in the suite and is green, and
   a test of its own in `src/opset/op_set.zig` compares them with the option
   **off**.

   **`zig build ctest -Dslow-path` is green, 17/17.** `cabi_lib` imports
   `zautomerge`, so the option reaches the C ABI with no wiring at all; the
   option-off run is also 17/17, so the C surface does not move.
3. *the 193 KB `hexane/src/tests.rs` unit suite ported case-for-case where it
   tests behaviour* — **NOT SATISFIED.** `src/hexane/` declares 198 test blocks
   of its own, but only **72** of that file's upstream `#[test]` names
   (**284 distinct upstream names**, measured 2026-10-01 — **not** the 286
   `#[test]` functions, because two cases are declared twice under a second codec
   parameter, `BeLen` and `Bijou64`, so a tally of functions overstates the
   denominator by two) appear in the tree. It was **1** that morning and **72**
   an hour later, so this figure is moving. The suite is tested; upstream's cases are not
   transcribed.

### P3 — columnar and the document format

- `ColumnSpec` (`(id << 4) | type | deflate_bit`, compared on `normalize()`),
  the composite logical columns (`Key`, `ObjId`, `OpIdList`, `Group`, `Value`),
  chunk framing, the document chunk, the change chunk, compression, the
  column-layout validator.
- Gate: every fixture in `tests/fixtures/` loads with the expected result; a
  document saved by the oracle loads in `zautomerge` and re-saves to a
  semantically equal document; all 8 fuzz crashers return `ParseError`.

**Verdict 2026-10-01 — SATISFIED.** `test/fixtures/` holds **18** corpus files
(the 9 upstream fixtures, the 8 fuzz crashers and `interop-exemplar`);
`test/fixtures_test.zig` is **6/6**, including *the 8 upstream fuzz crashers are
`load_err`* and *the manifest says `load_err` for every fixture whose name starts
with `crash-`*. The oracle-saved document round trip is pinned by
`src/doc.zig:6500`. **Note the gate says "every fixture in `tests/fixtures/`"
while §7 calls the corpus 17 files**: 17 is the upstream count (9 + 8), 18 is
what the port's directory holds once `interop/exemplar` is added. Both are
right about different sets; the wording should say which.

### P4 — change graph, clocks, and change encoding

- `ChangeGraph`, the actor table and `author.rs`, heads, and the change encoder
  (14 op columns after the header, from `storage/change/change_op_columns.rs`).
- Gate: change hashes produced by `zautomerge` for oracle-generated changes are
  byte-identical to the Rust hashes. This is the strongest single
  compatibility signal available, because the hash covers the whole encoded
  change.

**Verdict 2026-10-01 — SATISFIED, and this is the strongest evidence in the
port.** Re-measured, not taken on trust:

- `src/doc.zig:9003` `this port's write path produces the reference's own change
  chunks, byte for byte` builds the oracle's document through this port's own
  transactions and asserts, per change, that the encoded body equals the
  reference's bytes **and** that the hash equals the reference's own 32 bytes;
  it also asserts `changes.len == 2`, so it cannot pass vacuously.
- `src/doc.zig:6425` / `:6442` re-encode a change chunk the *reference wrote* to
  the reference's bytes and hash, plain and compressed.
- `src/doc.zig:6500` returns every change in the reference's own 446-byte
  document with the reference's hashes.

`zig test … --test-filter "reference"` → **20/20 pass**, including all three.

### P5 — op set and merge

- The 16 columns, the index columns, op lookup, local insert, remote apply,
  `MapWalker`, `Untangler`, conflict resolution, `BatchApply`, marks.
- Gate: port `tests/test.rs` (4,450 lines, 140 tests) and
  `tests/batch_insert.rs` (1,065 lines, 46 tests) case-for-case. A shared
  `Document` built in `zautomerge` and a shared document built in Rust, from
  the same operation script, produce the same `save()` bytes modulo the
  DEFLATE stream.

**Verdict 2026-10-01 — the named cases are now ported; one clause remains
unasserted.** The gate names two upstream files and both counts in it are right
(`test.rs` is 4,450 lines with 140 `#[test]`; `batch_insert.rs` is 1,065 lines
with 46). Measured by name:

- `tests/test.rs` — **140 / 140** present.
- `tests/batch_insert.rs` — **46 / 46** present, in `test/upstream_batch_insert.zig`,
  wired by the `upstream_batch_insert_tests` step, **47/47 passing** with no leaks. The file carries two
  complementary row-order assertions: `expectKeys` (the keys in row order) and
  `expectSameThroughApplyChanges` (the same document replayed through
  `Document.applyChanges`, compared with `debugCmp` first) at **45 sites across
  43 of the 47 cases**. `BatchInsertion::next_pos` computes each operation's row
  from the ones before it (`inner.rs:1460-1462`) and a map reader does not sort
  (`iter/map_range.rs:1486-1490`), so the write path and the apply path are two
  routes to the same rows; both assertions were falsified rather than believed.

**What is still open is the second clause**, not the porting: a shared document's
`save()` bytes matching modulo the DEFLATE stream is not separately asserted
anywhere. `save()` equivalence is checked the other way round, by loading, per §1
— which is the right check, but a gate that says "the bytes match" should say so
with a test rather than with an exemption.

### P6 — document API

- `Document` (the `Automerge` and `AutoCommit` flavours), `Transaction`,
  commit, rollback, `merge`, `apply_changes`, `load`, `save`, `get_heads`,
  `get_missing_deps`, `fork`, `clone`, `split`, `history`.
- Gate: the `ReadDoc` and `Transactable` surfaces in [API.md](../API.md) are
  complete and every method has a test. The `lib.rs` address-book doctest is a
  permanent test.

**Verdict 2026-10-01 — SATISFIED, with three `API.md` corrections.** The
`ReadDoc` and `Transactable` surfaces are present and the crate-root address-book
doctest is a permanent test (`test/example_test.zig`, **3/3**). Three
declarations in `API.md` were wrong and are now corrected: `parents` had lost
the `Result` that `read.rs:35` and `src/read.zig:1102` both carry; §Write's
"twenty … one for one" counts **twenty-one** declarations against upstream's
**twenty** methods; and `mark` / `unmark` do not match
`transaction/transactable.rs:103-117` in arity or order.

### P7 — iteration and historical reads

- `iter/**`, including the `Shiftable` repositioning abstraction that avoids
  per-object allocation, the diff iterators, and `ClockRange::Diff`.
- Gate: `tests/text.rs` and `tests/text_encoding.rs` ported case-for-case,
  including the 15 tests each run under 4 encodings.

**Verdict 2026-10-01 — PARTLY SATISFIED.** The gate's numbers are themselves off:
upstream's `tests/text.rs` has **21** `#[test]` functions and
`tests/text_encoding.rs` has **15**, so "the 15 tests each" does not hold for the
first file. Measured by name: `text.rs` **8 / 21** present, `text_encoding.rs`
**10 / 15** present. The ported subset is green — the library suite is
**1228/1228** — so this is a completeness gap, not a correctness one.

### P8 — sync

- `State`, `BloomFilter`, `Message` (v1 type byte `0x42`, v2 `0x43`),
  `MessageBuilder`, the state machine, and the v1 compatibility path.
- Gate: two `zautomerge` documents sync to convergence; a `zautomerge`
  document syncs with a Rust document in both directions, including a
  deliberately v1-only peer. Port the five round-trip tests from
  `sync/v1_compat_test/`.

**Verdict 2026-10-01 — SATISFIED, and the gate's count is wrong.** `sync/v1_compat_test/`
holds **three** round-trip tests (`mod.rs:473`, `:496`, `:519`); `bloom.rs` and
`state.rs` declare none, so "the five" is not a measurable number. The port's
`src/sync/v1.zig` carries **9** tests and covers both directions and a v1-only
peer; `src/sync/protocol.zig:3193` drives a Zig and a Rust document in both
directions byte for byte.

### P9 — patches, marks, cursors, text diff, hydrate, serde

- Gate: `tests/diff_marks.rs` (36 tests) and `tests/test_mark_patches.rs`
  ported; `hydrate` replays a patch stream into an equal mirror.

**Verdict 2026-10-01 — SATISFIED, and this row was wrong for most of the day.**
Both named files are ported: `tests/diff_marks.rs` is **36 of 36** — one
`test "diff_marks: …"` block per upstream case, in `src/marks.zig`, every name
upstream's own case translated (`overlapping_marks_remove_one_keep_other` →
*overlapping marks lose one and keep the other*), and `--test-filter
diff_marks` is green. `tests/test_mark_patches.rs` is **1 of 1** in
`test/mark_patches_test.zig`, wired. The hydrate clause holds, with the log
dropped before the mirror is read.

**The correction, because the error was mine and it was load-bearing.** This row
said *partly satisfied, and the weakest gate in the plan*, on a name-presence
count of **12 of 36**. **That instrument is wrong for this port**: every ported
case is renamed into English, so name-presence under-counts by roughly three, and
ranking the gates on it made P9 look like the largest hole in the port when it
was the most completely ported. The sound instrument is the port's own prefix
convention — one `test "<upstream file>: …"` block per upstream case — and by
that measure the whole of the upstream integration suite is ported bar **one**
case of `block_tests.rs`. **See STATUS.md's table.**

### P10 — bindings

- C ABI first, modelled on `automerge-c`: the `AMresult` convention, the
  single-destructor rule, the 5 enums with pinned discriminants, and the
  `AMitems` cursor.
- wasm second, only if wanted; see §9.
- Gate: `automerge-c`'s 21 cmocka files, including the three ported-from-wasm
  suites, pass against the Zig library.

**Verdict 2026-10-01 — SATISFIED; the count is wrong.** `zig build ctest` is
**5/5 steps, 153 cmocka cases, 0 failed** (measured 2026-10-01). 136 of those
cases are upstream's own: `test/c/suite/` is a verbatim copy of
`rust/automerge-c/test/`, re-verified file by file on 2026-10-01 (24 of 25
non-`CMakeLists` files identical; `main.c` lives at `test/c/main.c`, which that
file's header explains). The other 17 are this port's `abi_coverage.c`.

"21 cmocka files" is not a measurable count. Upstream's
`rust/automerge-c/test/` holds **19** `.c` files, 5 headers, one data file and
`CMakeLists.txt` — 26 files in all. Two upstream fixtures are worth recording:
the suite needs `-Dcmocka-prefix=<dir>` pointing at a cmocka built against this
host's glibc, and it needs `LD_LIBRARY_PATH` to include that prefix's `lib64`,
because the build step sets no rpath.

## 7. Verification strategy

Four independent layers, because none of them catches what the others catch.

1. **Ported unit and integration tests.** The upstream suite is 293 integration
   tests across 10 binaries, plus in-file test modules. **293 is right**
   (re-measured 2026-10-01: `grep -c '#\[test\]'` over the ten files sums to
   exactly 293). **"34 in-file test modules" is not reproducible from any
   measure I could find**: `automerge/src` holds 67 `#[cfg(test)]` attributes
   across 42 files, `hexane/src` holds 33 across 17, and there are 47 `mod
   test…` declarations. Whichever was meant, the number should be dropped
   rather than restated. Port the cases case-for-case; a test that asserts a
   Rust type's layout is dropped, a test that asserts behaviour is kept. Any
   test that cannot be ported gets its gap written down in the same commit —
   and **173 of the 293 names are in the tree today**, with
   `batch_insert.rs` at zero.
2. **Fixture conformance.** 17 upstream files, **18** in the port's
   `test/fixtures/` (the extra one is `interop-exemplar`). The 9 in
   `tests/fixtures/` have
   all-or-nothing load expectations; the 8 in `tests/fuzz-crashers/` must all
   return an error. `interop/exemplar` has its expected JSON in
   `interop/README.md`; the port asserts it — `test/golden/doc.jsonl` pins the
   446-byte document chunk it produces, byte for byte.
3. **Differential testing against the Rust reference.** The oracle crate
   generates documents, change streams, and sync transcripts; the Zig side
   replays them and compares. This is the only layer that proves wire
   compatibility rather than behavioural resemblance.
4. **Property tests.** Upstream uses `proptest` for `sequence_tree` and
   `hexane`, and commits `proptest-regressions/tests.txt`. The port keeps the
   same seeds so a failure is reproducible, and adds property tests for the
   codecs and the btree, which upstream only tests by example.

The 11 upstream CI jobs are all `nix run .#ci-*`; `zig build` and the
`devenv` `gate` script are this project's equivalent.

## 8. Decisions taken

| Decision | Choice | Why | Alternative |
| --- | --- | --- | --- |
| Storage engine | port `hexane` as written | the document format mandates its column layout; a flat representation cannot encode a conforming file | a flat op array plus a re-encoding layer, which is a second implementation of the same format and always wrong somewhere |
| `save()` bytes | not byte-identical | DEFLATE is not reproducible across implementations; requiring it buys nothing and costs a port of zlib-rs | vendoring a compatible deflate encoder, for byte identity nobody needs |
| Allocator | caller-supplied everywhere | the C ABI phase needs it, and a library that hides its allocator cannot be embedded | a global page allocator, which makes the leak test impossible |
| `ReadDoc` / `Transactable` | one `Document` + a `vtable` only where polymorphic | Rust needs two traits for two flavours; Zig does not | two separate document types, which duplicates the whole read surface |
| Text indexing | UTF-8 default, compile-time selectable | matches the upstream default; the wasm UTF-16 policy is a binding choice | hard-code UTF-16 for JS parity, which breaks native use |
| Bundle storage (`ChunkType::Bundle`) | port it in P3 | it is a second on-disk engine that shares the chunk framing; skipping it halves the format work but leaves a documented gap | defer to a later phase, explicitly |
| Bindings | C ABI only, wasm only on request | the C ABI is 166 functions and a strict superset of effort; the wasm layer is a codegen pipeline with a hand-merged TypeScript declaration | port both |

## 9. Risks

Ordered by how likely they are to cost real time.

1. **`PrefixColumn` and the RLE slab split.** A wrong prefix length produces
   a document that reads back with plausible but wrong rows, and the symptom
   surfaces three phases later. Mitigation: the btree invariant checker and the
   codec round-trip tests are in P2, before anything depends on them.
2. **Row order under merge.** `(obj, elemid-or-key, id)` is maintained by two
   different walkers for maps and sequences. Getting either wrong is a silent
   corruption. Mitigation: P5's gate is a byte comparison against the Rust
   encoder, not a read-back comparison.
3. **The `RefCell` / lazy-field invariant set.** Upstream leans on `RefCell`
   to make "built once, lazily" and "no aliasing" the same check. Zig has no
   equivalent, so each of these becomes an explicit field plus a comment that
   nobody verifies. Mitigation: enumerate them in the port, one per line, and
   cover each with a test.
4. **Borrowing without lifetimes.** `Document` returns slices into its own
   storage. Zig's borrow checker stops the easy mistakes, but a
   `save()`-then-`mutate` sequence that invalidates a held slice is legal Zig
   and a use-after-free. Mitigation: return owned copies from anything a
   caller could hold across a mutation, even at a copy cost.
5. **The v1 sync path.** It is maintained as a frozen copy of the pre-v2
   implementation (`sync/v1_compat_test/`, 907 lines). Porting it is
   mechanical; skipping it is not an option, because peers that do not
   advertise v2 are the common case.
6. **Apache-2.0 vendored code.** `text_diff/myers.rs` is a vendored port of
   `mitsuhiko/similar` at `2b31f65`, not diff-match-patch as the file name
   suggests. The port carries the Apache-2.0 notice and attribution
   separately from the MIT notice. Getting this wrong is a licence defect, not
   a bug.
7. **Recursion depth.** `materialize` and `hydrate` recurse over the document
   tree, and the wasm build works around stack exhaustion with
   `#[inline(never)]` on every hot path. A native Zig port will hit the same
   wall on a deep document. Mitigation: an explicit depth limit with a real
   error, decided in P6.
8. **Scope.** 98k lines of Rust across two crates. The phases above are
   ordered so that each one is useful on its own; P0 to P5 alone is a working
   library that loads, merges, and syncs.

## 10. Open questions

Answered with a default, stated in §8, and easy to change:

- Does the C ABI need to be source- and binary-compatible with the existing
  `automerge.h`? Default: yes for the type tags and the `AMresult`
  convention, no for the `AMitems` opaque-bytes hack, which the Zig port
  replaces with a plain `{ptr, len, offset}` struct.
- Is `automerge-c`'s single-destructor ownership rule acceptable, given that
  Zig can do better? Default: keep the rule, because a stricter C ABI is a
  different ABI.
- Is wasm wanted at all? Default: no, unless asked. It is a 6,708-line
  codegen pipeline in the upstream crate, and a hand-written Zig wasm binding
  is a project of its own.
