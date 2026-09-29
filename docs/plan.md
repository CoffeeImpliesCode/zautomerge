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
- `hexane` features `deep_fuzz` and `bijou64` — no `cfg` reads them.

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

Upstream has 13 error types, 30 variants on `AutomergeError`, with hand-written
`Display` strings. Zig has one global error namespace, so three sets:

- `Error` — the document API surface: the 30 `AutomergeError` variants that are
  observable through the public API, plus `OutOfMemory`.
- `ParseError` — anything reachable from parsing untrusted bytes: chunk
  framing, column decode, sync message decode, change decode. Every fuzz
  crasher in `tests/fuzz-crashers/` must produce a `ParseError`, never a crash
  and never a hang.
- `InternalError` — the asserts that upstream treats as impossible. Kept
  distinct so `-Dslow-path` can surface them instead of `unreachable`.

An upstream `panic!` that guards a reachable state becomes a `ParseError`
variant. The `too_many_ops`, `too_many_deps`, `overflow_in_length`, and
`invalid_deflate_stream` crashers are exactly this class.

### 3.2 Trait dispatch

`ReadDoc` (30 methods) and `Transactable` (21 methods) exist in Rust because
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

### P3 — columnar and the document format

- `ColumnSpec` (`(id << 4) | type | deflate_bit`, compared on `normalize()`),
  the composite logical columns (`Key`, `ObjId`, `OpIdList`, `Group`, `Value`),
  chunk framing, the document chunk, the change chunk, compression, the
  column-layout validator.
- Gate: every fixture in `tests/fixtures/` loads with the expected result; a
  document saved by the oracle loads in `zautomerge` and re-saves to a
  semantically equal document; all 8 fuzz crashers return `ParseError`.

### P4 — change graph, clocks, and change encoding

- `ChangeGraph`, the actor table and `author.rs`, heads, and the change encoder
  (14 op columns after the header, from `storage/change/change_op_columns.rs`).
- Gate: change hashes produced by `zautomerge` for oracle-generated changes are
  byte-identical to the Rust hashes. This is the strongest single
  compatibility signal available, because the hash covers the whole encoded
  change.

### P5 — op set and merge

- The 16 columns, the index columns, op lookup, local insert, remote apply,
  `MapWalker`, `Untangler`, conflict resolution, `BatchApply`, marks.
- Gate: port `tests/test.rs` (4,450 lines, 140 tests) and
  `tests/batch_insert.rs` (1,065 lines, 46 tests) case-for-case. A shared
  `Document` built in `zautomerge` and a shared document built in Rust, from
  the same operation script, produce the same `save()` bytes modulo the
  DEFLATE stream.

### P6 — document API

- `Document` (the `Automerge` and `AutoCommit` flavours), `Transaction`,
  commit, rollback, `merge`, `apply_changes`, `load`, `save`, `get_heads`,
  `get_missing_deps`, `fork`, `clone`, `split`, `history`.
- Gate: the `ReadDoc` and `Transactable` surfaces in [API.md](../API.md) are
  complete and every method has a test. The `lib.rs` address-book doctest is a
  permanent test.

### P7 — iteration and historical reads

- `iter/**`, including the `Shiftable` repositioning abstraction that avoids
  per-object allocation, the diff iterators, and `ClockRange::Diff`.
- Gate: `tests/text.rs` and `tests/text_encoding.rs` ported case-for-case,
  including the 15 tests each run under 4 encodings.

### P8 — sync

- `State`, `BloomFilter`, `Message` (v1 type byte `0x42`, v2 `0x43`),
  `MessageBuilder`, the state machine, and the v1 compatibility path.
- Gate: two `zautomerge` documents sync to convergence; a `zautomerge`
  document syncs with a Rust document in both directions, including a
  deliberately v1-only peer. Port the five round-trip tests from
  `sync/v1_compat_test/`.

### P9 — patches, marks, cursors, text diff, hydrate, serde

- Gate: `tests/diff_marks.rs` (36 tests) and `tests/test_mark_patches.rs`
  ported; `hydrate` replays a patch stream into an equal mirror.

### P10 — bindings

- C ABI first, modelled on `automerge-c`: the `AMresult` convention, the
  single-destructor rule, the 5 enums with pinned discriminants, and the
  `AMitems` cursor.
- wasm second, only if wanted; see §9.
- Gate: `automerge-c`'s 21 cmocka files, including the three ported-from-wasm
  suites, pass against the Zig library.

## 7. Verification strategy

Four independent layers, because none of them catches what the others catch.

1. **Ported unit and integration tests.** The upstream suite is 293 integration
   tests across 10 binaries plus 34 in-file test modules. Port them
   case-for-case; a test that asserts a Rust type's layout is dropped, a test
   that asserts behaviour is kept. Any test that cannot be ported gets its gap
   written down in the same commit.
2. **Fixture conformance.** 17 files. The 9 in `tests/fixtures/` have
   all-or-nothing load expectations; the 8 in `tests/fuzz-crashers/` must all
   return an error. `interop/exemplar` has its expected JSON in
   `interop/README.md` and is currently unasserted anywhere — the port makes it
   a test.
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
