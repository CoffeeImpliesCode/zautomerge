# `test/c/` — the C conformance suite

This directory is **not** a port of the reference's C tests. It **is** the
reference's C tests, plus three things this port adds around them. Read this
before changing anything under `test/c/suite/`: that tree is vendored, and a
vendored tree that drifts silently is worse than one that is wrong.

## What is vendored, and from where

`test/c/suite/` is upstream `rust/automerge-c/test/` copied **verbatim** from
the reference checkout at commit

```
ddbff535407e4d28cd2a82eaf6c6add08caa3bdd   2026-09-22
rust/automerge: Answer get_marks from the mark index
```

`test/c/suite/LICENSE` is upstream's own licence file for that tree
(MIT, plus the vendored notices it carries).

**The one upstream file that is not copied is `CMakeLists.txt`**, because the
build is `build.zig`'s: `build.zig:98-156` names every `.c` file explicitly,
sets the two include paths (`test/c/include`, which forwards onto this port's
one `include/automerge.h`, and `include` itself), and sets the run step's
working directory. Nothing in upstream's CMake file survives in any form.

**`test/c/main.c` is upstream's `rust/automerge-c/test/main.c` with exactly one
change**: the function is `suite_main`, not `main`, because Zig 0.16 passes a
C root source as `-Mroot=<file>.c`, reads that as a Zig compilation unit, and
then `std/start.zig` needs a Zig `root.main`. `test/c/main.zig` owns `main` and
calls `suite_main`. Every other line of `main.c` is upstream's.

## What this port adds, and why it lives here rather than in `suite/`

Three files sit beside `suite/` and are **not** upstream's:

| File | What it is |
| --- | --- |
| `abi_coverage.c` / `.h` | This port's own group. `rust/automerge-c/test/` calls **147 of the 187** functions `include/automerge.h` declares; the other forty would link and never run. `main.c` calls `run_abi_coverage_tests()` so they are covered. |
| `main.c`, `main.zig` | The driver, described above. |
| `include/` | Forwarding headers onto `include/automerge.h`, because the suite does `#include <automerge-c/…>` and the reference's split-header layout is part of what is being tested. |

## Dropped and altered assertions

Every deliberate deviation from upstream's suite, with the reason.

### `suite/ported_wasm/sync_tests.c:132-133`

Two assertions on a decoded `AMsyncHave` are not present:

* `have[0].bloom.byteLength === 0`
* `changes === []`

**They are unreachable, not skipped.** `include/automerge.h:1016` exposes
`AMsyncHaveLastSync` and nothing else on a have, so a C caller cannot read the
bloom filter at all; and the message surface is `Haves` / `Heads` / `Needs`
(`include/automerge.h`, the `AMsyncMessage*` accessors) with no
`AMsyncMessageChanges`, so a C caller cannot read the changes. A case that
asserts on an API the header does not declare is a case that cannot be written,
and one that is written to fail is worse than one that is absent.

### Nothing else

No other assertion in `test/c/suite/` has been dropped, relaxed, reordered, or
given a different expected value. Where this port's behaviour differs from the
reference, the case is left failing and the difference is reported — see
*Known differences* below and the slice reports.

## Behavioural differences from the reference

### Text encoding: the C ABI is UTF-8, the library default is not

The three C construction sites — `AMcreate`, `AMload`, `AMclone` — build their
document in **UTF-8 code units** (`src/c/doc.zig`'s `cTextEncoding`). That
matches how the reference's own C suite is built: `rust/automerge-c/CMakeLists.txt:45`
and `:111-117` pass `-F automerge/utf8-indexing`, which is what makes
`TextEncoding::platform_default()` resolve to `utf8_code_unit` for an
`automerge-c` build (`rust/automerge/src/text_value.rs:11`, `:19`).

The **library's own** `defaultTextEncoding()` stays `unicode_code_point`,
because that is the `platform_default()` of a featureless library build. So
every index in a text object reached through the C ABI is in UTF-8 code units
and every index reached through the Zig API is in code points. A reader of a
case in this directory should know which side of that line the case is on; the
mark and text cases here are on the UTF-8 side.

### The `save()` byte-comparison exemption

`AGENTS.md` says `save()` output is not required to be byte-identical to the
reference, because DEFLATE is not reproducible across implementations.
`ported_wasm/basic_tests.c:773-774` is the one case in this directory that
compares `save()` output directly, and it is a **`not`-equal** comparison
(`assert_memory_not_equal(saveA, saveB)`), which DEFLATE non-determinism cannot
affect in the direction that matters. **There is no byte-identical `save()`
assertion in this suite, and none may be added**: if a case ever needs one, the
`save()` exemption has to be applied to that case deliberately, with the reason
written down in the case and here, rather than folded in silently.

Equivalence is checked the other way round, by loading: `doc_tests.c:175` and
the ported-wasm save cases load the bytes back and compare the materialized
document.

## Running it, and the two things that will bite you

```
zig build ctest
```

### cmocka is not in the compiler's default search path here, and the packaged one will not run

The Nix-provided `cmocka-2.0.2` needs `GLIBC_ABI_GNU2_TLS` (glibc ≥ 2.42) and
glibc 2.40 on the build host is older than that, so a suite linked against the
packaged library fails to launch. The gate therefore needs
`-Dcmocka-prefix=<dir>` pointing at a cmocka built against the glibc the build
host runs.

**`test/c/build-cmocka.sh` builds it, and the prefix it installs to is a
sibling of this repository** — `../cmocka-prefix`, on the same volume the
repository and the reference checkout live on. That is the same convention
`devenv.nix:12-17` uses for `github-automerge-automerge`: a dependency this
repository does not vendor lives next to the repository and is derived from
its location, so there is no `/home/<someone>/...` to go stale and the
checkout keeps working wherever it is cloned.

```
test/c/build-cmocka.sh                                  # prefix = ../cmocka-prefix
zig build ctest -Dcmocka-prefix="$PWD/../cmocka-prefix"
```

The script fetches `cmocka-2.0.2.tar.xz` from `cmocka.org` and **checks the
tarball's SHA-256 on every run**; a tarball whose hash does not match is not
built. The pinned value is
`39f92f366bdf3f1a02af4da75b4a5c52df6c9f7e736c7d65de13283f9f0ef416`, which is
the hash in the nixpkgs derivation for this version
(`pkgs/by-name/cm/cmocka/package.nix`, `src.hash = "sha256-OfkvNmvfPxoCr02nW0pcUt9sn35zbH1l3hMoP58O9BY="`,
base64 for the same digest), so the bytes here are the bytes a reproducible
build would fetch. The header at the top of the script records the two things
it deliberately does not do — nixpkgs's `uintptr_t.patch`, which is a no-op on
a host that has `<stdint.h>`, and cmocka's own test suite.

`build.zig:153` declares the option and `build.zig:194-203` adds `include` plus
both `lib` and `lib64` under it, so one prefix covers either layout (cmocka
installs into `lib64` here). Nothing is vendored and no path is hardcoded in
`build.zig`. **A build step that only works because of something done by hand,
with no record, is a build step that breaks for the next person** — hence this
section and the script.

### Zig 0.16 swallows a failing run step's stdout

`build.zig:255` sets `run_ctest.expectExitCode(0)`, so any failing case fails
the step, and **Zig 0.16 does not print the run step's output when it fails**.
The per-case report therefore comes from running the binary `zig build ctest`
just built, with the working directory `build.zig` uses (`test/c/suite`,
`build.zig:250` — `doc_tests.c:175` opens `files/brave-ape-49.automerge`
relative to it, which is what upstream's CMake copy step arranges).

```
zig build ctest -Dcmocka-prefix="$PWD/../cmocka-prefix"        # build
cd test/c/suite && <--cache-dir>/o/<hash>/automerge-c-test      # report
```

cmocka prints one line per case and a `[  PASSED  ] N test(s).` count
(`cmocka_run_group_tests`), and `main.c` sums the group results, so the
process exit status is 0 or not-0 and nothing finer.

### One more thing worth knowing

A compile error **anywhere** in the tree — including inside a `test` block in
a file nobody is building — fails `zig build ctest`, because Zig 0.16
analyses test declarations in a non-test build. When the C gate fails to
*compile* and the error is in `src/` and not in `src/c/`, another slice is
mid-edit.

## Known differences

This file records **provenance and permanent facts**. **No case in this suite
is failing**; what is below is either a permanent fact about the suite or the
record of a defect it caught.

**Measured 2026-10-01: 153 cases in 13 groups, 153 passing, 0 failing.**

### The one defect this suite caught that `zig build test` did not, and why

This suite exists for exactly this, so the record stays.

Two cases used to fail, both with `DuplicateSeqNumber`, both from **one**
defect:

| Case | First failing assertion | Error |
| --- | --- | --- |
| `test_should_handle_changes_concurrrent_to_the_last_sync_heads` | `ported_wasm/sync_tests.c:1149` — `AMapplyChanges(test_state->n2, &changes)` under `AMexpect(AM_VAL_TYPE_VOID)` | `DuplicateSeqNumber` |
| `test_should_work_with_prior_sync_state_2` | `ported_wasm/sync_tests.c:68`, inside the file's own `sync()` helper — `AMreceiveSyncMessage` under `AMexpect(AM_VAL_TYPE_VOID)` | `DuplicateSeqNumber` |

**What the C consumer observed.** A document created with actor `89abcdef`
that received a change from `01234567` *before* it committed anything of its
own reported its own actor as `01234567` — `AMgetActorId` said `01234567`,
`AMgetLastLocalChange` handed back a change whose actor was `01234567` and
whose `seq` was `2` (`start_op`/`max_op` `2`), and applying that change to a
peer that already held `01234567@2` is a `DuplicateSeqNumber`. The same
document reported `89abcdef` correctly once it committed first, and the same
sequence through the Zig API was right.

**Where it was.** `Document.actor` is an `Actor` union whose `Unused` arm is a
**borrowed** slice over the document's arena (`src/doc.zig:305-311`) and whose
`Cached` arm is an index. `Document.loadIncremental`'s empty-document branch
copied the **union** across `loadIntoWith` (`src/doc.zig:3613`, `:3623`), which
resets the document through `Document.deinit` — and so frees that arena
(`src/doc.zig:2463`). The slice named freed memory, the peer actor the load
interned next was written into those bytes by `Document.adoptActors`, and the
document then minted its next change under the other actor.

Upstream cannot be wrong this way: `Actor::Unused` owns a `Vec<u8>`
(`automerge.rs:47-50`), and `load_incremental_log_patches` re-establishes the
actor **by value, resolved against the loaded document's actor table** —
`doc = doc.with_actor(self.actor_id().clone())` (`automerge.rs:1040`), then
`set_actor` (`automerge.rs:359-366`), which caches the index when the table
holds the actor and keeps the bytes when it does not.

**The fix is in the core, not in the C binding**: `Document.reset` no longer
carries the actor (or the author, which borrows from the same arena) across the
`deinit`, and `Document.loadIncremental` copies the actor's bytes and
re-establishes them through `Document.setActorId`. `src/c/**` was not the wrong
side — it was reporting the core's answer faithfully.

**Why `zig build test` stayed green**, which is the part worth remembering:
every actor in this tree's own tests is a **string literal**
(`src/doc.zig:5903`, `src/sync/protocol.zig:1122`, `src/sync/v1.zig:822`). A
literal never dies, so carrying a borrowed slice across a reset looks
harmless. `AMcreate` interns the caller's bytes into the document's arena
(`src/c/doc.zig`, `internActor`), so the C ABI is the only caller that can
reach the defect, and it reaches it on **every** peer that receives a change
before it commits — which is the normal order for a newly created document.
`src/doc.zig`'s
"an incremental load into an empty document re-establishes that document's
actor" interns its actor into the arena for exactly this reason, and asserts
both halves of `set_actor`: the bytes for an actor the table does not hold, and
the index for one it does.

**No case in `test/c/suite/` was touched.** The fix was in the library, the
cases are as upstream wrote them, and the record of what was dropped and why
is *Dropped and altered assertions* above.

### `AMfork`: upstream's doc comment is wrong

Upstream's own doc comment (`rust/automerge-c/src/doc.rs:239`)
says it returns an `AM_VAL_TYPE_VOID` item, and its code
(`to_result(doc.fork())` at `:252`, with
`impl From<am::AutoCommit> for AMresult` at `src/result.rs:37-41`) returns a
`DOC`. **The code is right and the comment is wrong**, and the reference's own
suite (`ported_wasm/basic_tests.c:1501`) reads the item with `AMitemToDoc`
under `AMexpect(AM_VAL_TYPE_DOC)`. This port follows the code and the suite.
