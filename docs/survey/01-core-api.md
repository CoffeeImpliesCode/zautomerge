# Core public API and value model

Reference: `automerge` v0.12.0, commit `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`,
`rust/automerge/`. All paths below are relative to `rust/automerge/src/`.

## Scope

Primary target files, read in full:

| Path | Lines |
| --- | --- |
| `lib.rs` | 333 |
| `automerge.rs` | 2361 |
| `types.rs` | 774 |
| `value.rs` | 904 |
| `exid.rs` | 238 |
| `clock.rs` | 251 |
| `change.rs` | 428 |
| `error.rs` | 184 |
| `text_value.rs` | 276 |
| `convert.rs` | 112 |
| `author.rs` | 580 |
| `decoding.rs` | 475 |
| `Cargo.toml` | 56 |

Read for the trait/impl surface the assigned files depend on (signature-level):

| Path | Lines | Why |
| --- | --- | --- |
| `read.rs` | 330 | `ReadDoc` trait + `Stats` |
| `autocommit.rs` | 1384 | `AutoCommit` |
| `transaction.rs` | 528 | `Transactable`/`Transaction` re-exports + `impl_*_for_tx!` macros |
| `transaction/transactable.rs` | 203 | `Transactable` trait, `BlockOrText` |
| `transaction/manual_transaction.rs` | 145 | `Transaction` |
| `transaction/commit.rs` | 34 | `CommitOptions` |
| `transaction/result.rs` | 21 | `Success`, `Failure`, `Result` |
| `patches/patch.rs` | 95 | `Patch`, `PatchAction` |
| `marks.rs` | 541 | `Mark`, `MarkSet`, `ExpandMark`, `UpdateSpansConfig` |
| `cursor.rs` | 296 | `Cursor`, `OpCursor`, `CursorPosition`, `MoveCursor` |
| `op_set2/types.rs` | 777 | `ScalarValueRef`, `ValueRef`, `ChangeMetadata` |
| `op_set2/parents.rs` | 133 | `Parent`, `Parents` |
| `hydrate.rs` | 372 | `hydrate::Value`/`Map`/`List`/`Text` |
| `anonymize.rs` | 558 | `AnonymizeError` |
| `autoserde.rs` | 128 | `AutoSerde` |

---

## Surface

### Crate root — `lib.rs`

Crate-level lint set (`lib.rs:216-231`): `missing_debug_implementations`,
`rust_2018_idioms`, `unreachable_pub`, `bad_style`, `dead_code`, `improper_ctypes`,
`non_shorthand_field_patterns`, `no_mangle_generic_items`, `overflowing_literals`,
`path_statements`, `patterns_in_fns_without_body`, `unconditional_recursion`,
`unused`, `unused_allocation`, `unused_comparisons`, `unused_parens`, `while_true`.
`missing_docs` is commented out (`lib.rs:219`).

Exported macros (all `#[doc(hidden)] #[macro_export]`, so they expand into *user* code
and are therefore part of the public surface):

```rust
// lib.rs:235
macro_rules! log { ( $( $t:tt )* ) => { { use $crate::__log; __log!( $( $t )* ); } } }

// lib.rs:247  — cfg(all(feature = "wasm", target_family = "wasm"))
macro_rules! __log { ( $( $t:tt )* ) => { web_sys::console::log_1(&format!( $( $t )* ).into()); } }

// lib.rs:256  — cfg(not(all(feature = "wasm", target_family = "wasm")))
macro_rules! __log { ( $( $t:tt )* ) => { println!( $( $t )* ); } }
```

Module tree (`lib.rs:262-293`):

| Public modules | Private modules |
| --- | --- |
| `anonymize` (262), `error` (274), `hydrate` (276), `iter` (278), `legacy` (281, `#[doc(hidden)]`), `marks` (282), `op_set2` (283), `patches` (284), `sync` (288), `transaction` (291) | `author` (263), `autocommit` (264), `automerge` (265), `autoserde` (266), `change` (267), `change_graph` (268), `change_queue` (269), `clock` (270), `columnar` (271), `convert` (272), `cursor` (273), `exid` (275), `indexed_cache` (277), `read` (285), `sequence_tree` (286), `storage` (287), `text_diff` (289), `text_value` (290), `types` (292), `value` (293) |

Crate root constant (`lib.rs:320`):

```rust
pub const ROOT: ObjId = ObjId::Root;   // ObjId here is exid::ExId (see below)
```

#### Re-export map (`lib.rs:295-317`)

| Root name | Actual item | Defining path |
| --- | --- | --- |
| `AnonymizeError` | `anonymize::AnonymizeError` | `anonymize.rs:12` |
| `Automerge` | `automerge::Automerge` | `automerge.rs:249` |
| `LoadOptions` | `automerge::LoadOptions<'a>` | `automerge.rs:91` |
| `OnPartialLoad` | `automerge::OnPartialLoad` | `automerge.rs:74` |
| `SaveOptions` | `automerge::SaveOptions` | `automerge.rs:2330` |
| `StringMigration` | `automerge::StringMigration` | `automerge.rs:83` |
| `Author` | `author::Author<'a>` | `author.rs:144` |
| `AutoCommit` | `autocommit::AutoCommit` | `autocommit.rs:64` |
| `AutoSerde` | `autoserde::AutoSerde<'a, R>` | `autoserde.rs:22` |
| `Change` | `change::Change` | `change.rs:14` |
| `LoadChangeError` | `change::LoadError` (renamed) | `change.rs:168` |
| `Fragment` | `change_graph::Fragment` (`#[doc(hidden)]`) | `change_graph.rs:1768` |
| `Cursor` | `cursor::Cursor` | `cursor.rs:24` |
| `CursorPosition` | `cursor::CursorPosition` | `cursor.rs:53` |
| `MoveCursor` | `cursor::MoveCursor` | `cursor.rs:71` |
| `OpCursor` | `cursor::OpCursor` | `cursor.rs:35` |
| `InvalidActorId` | `error::InvalidActorId` | `error.rs:115` |
| `InvalidChangeHashSlice` | `error::InvalidChangeHashSlice` | `error.rs:132` |
| `AutomergeError` | `error::AutomergeError` | `error.rs:13` |
| `PatchLogMismatch` | `error::PatchLogMismatch` | `error.rs:10` |
| **`ObjId`** | **`exid::ExId` (renamed)** | **`exid.rs:19`** |
| `ObjIdFromBytesError` | `exid::ObjIdFromBytesError` | `exid.rs:80` |
| `ExpandedChange` | `legacy::Change` (renamed) | `legacy/mod.rs:328` |
| `ChangeMetadata` | `op_set2::ChangeMetadata<'a>` | `op_set2/types.rs:749` |
| `Parent` | `op_set2::Parent` | `op_set2/parents.rs:87` |
| `Parents` | `op_set2::Parents<'a>` | `op_set2/parents.rs:16` |
| **`ScalarValueRef`** | **`op_set2::ScalarValue<'a>` (renamed)** | `op_set2/types.rs:192` |
| `ValueRef` | `op_set2::ValueRef<'a>` | `op_set2/types.rs:655` |
| `Patch` | `patches::Patch` | `patches/patch.rs:17` |
| `PatchAction` | `patches::PatchAction` | `patches/patch.rs:33` |
| `PatchLog` | `patches::PatchLog` | `patches/patch_log.rs:44` |
| `ReadDoc` | `read::ReadDoc` (trait) | `read.rs:20` |
| `Stats` | `read::Stats` | `read.rs:312` |
| `SequenceTree` | `sequence_tree::SequenceTree<T>` | `sequence_tree.rs` |
| `Bundle` | `storage::Bundle` | `storage/bundle.rs` |
| `BundleChange` | `storage::BundleChange` | `storage/bundle.rs` |
| `BundleChangeIter` | `storage::BundleChangeIter` | `storage/bundle.rs` |
| `VerificationMode` | `storage::load::VerificationMode` | `storage/load.rs:12` |
| `ConcreteTextValue` | `text_value::ConcreteTextValue` | `text_value.rs:186` |
| `BlockOrText` | `transaction::BlockOrText<'a>` | `transaction/transactable.rs:198` |
| `ActorId` | `types::ActorId` | `types.rs:45` |
| `ChangeHash` | `types::ChangeHash` | `types.rs:690` |
| `ObjType` | `types::ObjType` | `types.rs:171` |
| `OpType` | `types::OpType` | `types.rs:227` |
| `ParseChangeHashError` | `types::ParseChangeHashError` | `types.rs:727` |
| `Prop` | `types::Prop` | `types.rs:389` |
| `TextEncoding` | `types::TextEncoding` | `types.rs:622` |
| `ScalarValue` | `value::ScalarValue` | `value.rs:519` |
| `Value` | `value::Value<'a>` | `value.rs:10` |
| `Span` | `iter::Span` (re-export of `iter::spans::Span`) | `iter/spans.rs:410` |

Two re-exports are **renames that change what a name means**, and both are easy to
port wrong:

* `automerge::ObjId` is `exid::ExId`, **not** `types::ObjId`. The internal `types::ObjId`
  (a newtype over `types::OpId`) is `pub(crate)` and unreachable from outside the crate
  (`types.rs:514`).
* `automerge::ScalarValueRef` is the *borrowed* op-set scalar
  (`op_set2::ScalarValue<'a>`, using `Cow` and a flat `Counter(i64)`), while
  `automerge::ScalarValue` is the *owned* value scalar (`value.rs:519`). Same variant
  names, different payload types, and a different `Counter` shape.

`pub mod legacy` is `#[doc(hidden)]` (`lib.rs:280-281`) but fully public;
`ExpandedChange` (`legacy::Change`) is a documented, serde-deriving, fully-public
"expanded" representation of a change.

### Feature gates — `Cargo.toml:11-17`

```toml
[features]
wasm                = ["js-sys", "wasm-bindgen", "web-sys", "getrandom/wasm_js", "hexane/wasm"]
utf8-indexing       = []
utf16-indexing      = []
slow_path_assertions = ["hexane/slow_path_assertions"]
```

There is **no `default` feature list**, so all four are off by default.

Compile-time-visible consequences in the public surface:

| Gate | Effect | `path:line` |
| --- | --- | --- |
| `wasm` | `From<AutomergeError> for wasm_bindgen::JsValue` | `error.rs:106-111` |
| `wasm` | `From<Prop> for wasm_bindgen::JsValue` | `types.rs:766-773` |
| `wasm` | `From<Value> for JsValue`, `From<&Value> for JsValue` (hydrate) | `hydrate.rs:329-372` |
| `wasm` | `__log!` body switches from `println!` to `web_sys::console::log_1` | `lib.rs:244-260` |
| `utf8-indexing` | `TextEncoding::platform_default() == Utf8CodeUnit` | `text_value.rs:14-15` |
| `utf16-indexing` | `TextEncoding::platform_default() == Utf16CodeUnit` | `text_value.rs:16-17` |
| (neither) | `TextEncoding::platform_default() == UnicodeCodePoint` | `text_value.rs:18-19` |
| `slow_path_assertions` | extra invariant assertions in mark/sequence-tree/op-set/chunk code | `automerge.rs:1587,1939`; `sequence_tree.rs:52,114,126`; `op_set2/op_set.rs:645,1088`; `op_set2/op_set/top_op.rs:6,77`; `op_set2/change/batch.rs:924`; `storage/load.rs:129`; `transaction/inner.rs:164` |

`utf8-indexing` takes precedence over `utf16-indexing`; `GraphemeCluster` is never a
platform default (`text_value.rs:12-22`).

### `types.rs` — identifiers and properties

```rust
// types.rs:44-45
#[derive(Eq, PartialEq, Hash, Clone, PartialOrd, Ord)]
pub struct ActorId(TinyVec<[u8; 16]>);   // inline ≤16 bytes, heap beyond
```

`ActorId` methods (`types.rs:63-85`):

```rust
pub fn random() -> ActorId;                                        // 64 — 16 bytes from getrandom::fill
pub fn to_bytes(&self) -> &[u8];                                   // 68
pub fn to_hex_string(&self) -> String;                             // 72
pub(crate) fn with_concurrency(&self, level: usize) -> ActorId;    // 76
```

Trait impls on `ActorId`: `fmt::Debug` as hex tuple (`types.rs:47-51`);
`rand::distr::Distribution<StandardUniform>` (`types.rs:60`);
`TryFrom<&str>`/`TryFrom<String>` → `InvalidActorId` on hex-decode failure
(`types.rs:88-105`); `AsRef<[u8]>` (`types.rs:107`);
`From<&[u8]>`/`From<&Vec<u8>>`/`From<Vec<u8>>`/`From<[u8; N]>`/`From<&[u8; N]>`
(`types.rs:113-156`); `FromStr` = `try_from` (`types.rs:158`);
`Display` = `to_hex_string` (`types.rs:164`).

```rust
// types.rs:169-181
#[derive(Deserialize, Serialize, Debug, Clone, PartialEq, Eq, Copy, Hash, Default)]
#[serde(rename_all = "camelCase", untagged)]
pub enum ObjType {
    #[default] Map,     // a map
    Table,              // retained for backwards compatibility, identical to Map
    List,               // a sequence of arbitrary values
    Text,               // a sequence of characters
}
```

`ObjType` methods: `is_sequence()` → `List | Text` (`types.rs:184-186`);
`pub(crate) as_sequence_type() -> Option<SequenceType>` (`types.rs:189`);
`From<amp::MapType>` / `From<amp::SequenceType>` (`types.rs:196-215`);
`Display` → `"map" | "table" | "list" | "text"` (`types.rs:218-227`).

```rust
// types.rs:226-233
#[derive(PartialEq, Debug, Clone)]
pub enum OpType {
    Make(ObjType),
    Delete,
    Increment(i64),
    Put(ScalarValue),                 // value::ScalarValue
    MarkBegin(bool, OldMarkData),      // OldMarkData = marks::OldMarkData (marks.rs:356)
    MarkEnd(bool),
}
```

`OpType::validate_action_and_value(action: u64, value: &ScalarValue)` is `pub(crate)`
(`types.rs:236-251`); it constrains wire action indices `0..=7`: `0..=4`, `6`, `7`
always OK; `5` (increment) requires `Int` or `Uint`, else
`InvalidOpType::NonNumericInc`; anything else is `InvalidOpType::UnknownAction`.

```rust
// types.rs:388-394
#[derive(Debug, PartialEq, PartialOrd, Eq, Ord, Clone)]
pub enum Prop {
    Map(String),   // a property in a map
    Seq(usize),    // an index into a sequence
}
```

`Prop` methods: `as_str() -> Option<&str>` (`types.rs:397`);
`as_index() -> Option<usize>` (`types.rs:404`); `Display` (`types.rs:411`).
`From` impls: `String`, `&String`, `Cow<'a, str>`, `&str` → `Map`; `usize`, `&usize`,
**`f64`** → `Seq` (`types.rs:338-379`; the `f64` case is `Prop::Seq(index as usize)`
at `types.rs:373-377`).

```rust
// types.rs:621-631
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum TextEncoding {
    UnicodeCodePoint,  // each unicode code point counts as one unit
    Utf8CodeUnit,      // each UTF-8 code unit (byte) counts as one unit
    Utf16CodeUnit,     // each UTF-16 code unit counts as one unit
    GraphemeCluster,   // each grapheme cluster counts as one unit
}
```

`pub(crate) width(&self, s: &str) -> usize` (`types.rs:634-643`). The public companion
`TextEncoding::platform_default()` lives in `text_value.rs:12-22` (an intrinsic method
split across two files).

```rust
// types.rs:687-690
pub(crate) const HASH_SIZE: usize = 32; // 256 bits = 32 bytes

#[derive(Eq, PartialEq, Hash, Clone, PartialOrd, Ord, Copy)]
pub struct ChangeHash(pub [u8; HASH_SIZE]);
```

`ChangeHash` `pub(crate)` methods: `as_bytes()` (`types.rs:693`),
`checksum() -> [u8;4]` (`types.rs:697`, first 4 bytes), `fragment_level()`
(`types.rs:701`, count of leading zero bytes). `AsRef<[u8]>` (`types.rs:706`), `Debug`
as hex tuple (`types.rs:710`), `Display` as hex (`types.rs:717`).

```rust
// types.rs:726-734
#[derive(thiserror::Error, Debug)]
pub enum ParseChangeHashError {
    #[error(transparent)] HexDecode(#[from] hex::FromHexError),
    #[error("incorrect length, change hash should be {} bytes, got {actual}", HASH_SIZE)]
    IncorrectLength { actual: usize },
}
```

`FromStr for ChangeHash` (`types.rs:736-746`): hex-decode, then require exactly
`HASH_SIZE`. `TryFrom<&[u8]>` (`types.rs:748-758`) → `InvalidChangeHashSlice`.

Crate-private items in `types.rs` a port must still model:

```rust
pub(crate) type SmallHasher = FxBuildHasher;                        // types.rs:18
pub(crate) type SmallHashMap<A, B> = HashMap<A, B, SmallHasher>;    // types.rs:19
pub(crate) const CONCURRENCY_MAGIC_BYTES: [u8; 4] = [0x13,0xb2,0x23,0x09];  // 22
pub(crate) const HEAD: ElemId = ElemId(OpId(0, 0));                 // 29
pub(crate) const ROOT: OpId = OpId(0, 0);                           // 30
pub(crate) struct OpId(u32 /*counter*/, u32 /*actor index*/);      // 424
pub(crate) struct ObjId(pub(crate) OpId);                           // 514
pub(crate) struct ObjMeta { id: ObjId, typ: ObjType }               // 599
pub(crate) enum SequenceType { List, Text }                         // 652
pub(crate) struct ElemId(pub(crate) OpId);                          // 655
pub(crate) trait Exportable { fn export(&self) -> Export; }         // 277
pub(crate) enum Export { Id(OpId), Special(String) }                 // 271
```

`ROOT_STR = "_root"`, `HEAD_STR = "_head"` (`types.rs:32-33`) are the magic strings
used by `Display` for `ExId::Root` and by the `Exportable` impls.

`OpId` carries the actor as a `u32` **index** into the op set's actor table, not as an
`ActorId` (`types.rs:419-424`); `Ord` is hand-written
`self.0.cmp(&other.0).then(self.1.cmp(&other.1))` (`types.rs:433-438`) with a comment
that this is done deliberately so the total order does not shift when a `derive` is
regenerated. Methods: `with_new_actor`, `without_actor`, `new(counter: u64, actor:
usize)` (`types.rs:440-459`; `new` panics on `u64→u32` counter overflow via
`try_into().unwrap()`), `map(actor_map)`, `counter() -> u64`, `icounter() -> i64`,
`actor() -> usize`, `actoridx() -> ActorIdx`, `prev()`, `minus(n)`, `next()`
(`types.rs:461-497`).

`ObjId` methods (`types.rs:516-597`): `with_new_actor`, `without_actor`,
`load(counter, actor) -> Option<ObjId>`, `map(actor_map)`, `const root()`,
`is_root()` (⇔ `counter() == 0`), `id() -> Option<&OpId>`, `counter() -> Option<u64>`,
`icounter() -> Option<i64>`, `actor() -> Option<ActorIdx>` — every accessor returns
`None` for the root rather than a sentinel.

### `exid.rs` — the public object identifier

```rust
// exid.rs:14-20
/// An identifier for an object in a document
#[derive(Debug, Clone)]
pub enum ExId {
    Root,
    Id(u64, ActorId, usize),
}
```

The variant has **no field names**. Three call sites bind them as
`(counter, ActorId, actor_index)`:

* `ExId::to_internal_obj`: `ExId::Id(ctr, _, actor) => ObjId(OpId::new(*ctr, *actor))`
  (`exid.rs:70-75`) — internal `OpId.counter = field 0`, `OpId.actor index = field 2`.
* `Display`: `ExId::Id(ctr, actor, _) => write!(f, "{}@{}", ctr, actor)` (`exid.rs:139-144`).
* `Automerge::exid_to_opid`: `ExId::Id(ctr, actor, idx)` is **not**
  `OpId::new(*ctr, *idx)`. It re-resolves the index
  (`automerge.rs:744-758`):

  ```rust
  let opid = if self.ops.get_actor_safe(*idx) == Some(actor) {
      OpId::new(*ctr, *idx)
  } else if let Some(backup_idx) = self.ops.lookup_actor(actor) {
      OpId::new(*ctr, backup_idx)
  } else {
      return Err(AutomergeError::InvalidObjId(id.to_string()));
  };
  ```

  **This is the whole reason `ExId` carries the actor at all.** The actor
  table is sorted, so `OpSet::insert_actor` renumbers every index at or above
  the slot it fills (`op_set2/op_set.rs:1400-1405`), and the only operation
  that fills a slot in the middle is `isolate`, which interns a concurrency
  actor — magic bytes `0x13 0xb2 0x23 09` (`types.rs:23`), which sort before
  most real actors (`Automerge::isolate_actor`, `automerge.rs:1259-1281`).
  An `ExId` minted before that isolate names nothing after it unless the index
  is repaired, and the actor bytes are the only thing that makes the repair
  possible. Upstream's own `PartialEq` (`exid.rs:129-133`) likewise compares
  `(counter, actor)` and **ignores the index**, which is the same statement
  from the other side.
* The producer, `OpSet::id_to_exid`:
  `ExId::Id(id.counter(), self.actors[id.actor()].clone(), id.actor())`
  (`op_set2/op_set.rs:1054-1059`) — confirms field 0 = counter, field 2 = actor index.

Two call sites instead bind them as `(actor_index_hint, ActorId, counter)` — inverted:

* `to_bytes`: `ExId::Id(id, actor, counter)` writes `*counter` then `*id`
  (`exid.rs:46-66`).
* `TryFrom<&[u8]>`: reads `counter` then `actor_idx_hint` and builds
  `Self::Id(actor_idx_hint, actor.into(), counter as usize)` (`exid.rs:107-111`).

These two are self-consistent, so the **wire format is actor-index-first,
counter-last**, the opposite of the enum's own field order. See Risk.

Public methods and impls:

```rust
pub fn to_bytes(&self) -> Vec<u8>;                                        // exid.rs:30
impl TryFrom<&[u8]> for ExId { type Error = ObjIdFromBytesError; }        // exid.rs:96
impl Display for ExId        // 139  "_root" | "{ctr}@{actor}"
impl Serialize for ExId      // 156  serializes as to_string()
impl AsRef<ExId> for ExId    // 163
impl Ord / PartialOrd       // 170 / 187
impl Hash                    // 145
impl PartialEq               // 130  (hand-written)
impl PartialEq<ObjId>        // 141  (crate-private type)
```

Wire constants (`exid.rs:22-24`): `SERIALIZATION_VERSION_TAG: u8 = 0`, `TYPE_ROOT: u8 = 0`,
`TYPE_ID: u8 = 1`.

```rust
// exid.rs:79-97
#[derive(Debug, thiserror::Error)]
pub enum ObjIdFromBytesError {
    #[error("no version tag")] NoVersion,
    #[error("invalid version tag")] InvalidVersion(u8),
    #[error("invalid type tag")] InvalidType(u8),
    #[error("invalid Actor ID length: {0}")] ParseActorLen(String),
    #[error("Not enough bytes in actor ID")] ParseActor,
    #[error("invalid counter: {0}")] ParseCounter(String),
    #[error("invalid actor index hint: {0}")] ParseActorIdxHint(String),
}
```

### `value.rs` — the value model

```rust
// value.rs:9-17
#[derive(Debug, Clone, PartialEq)]
pub enum Value<'a> {
    /// A composite object of type `ObjType`
    Object(ObjType),
    /// A non composite value
    Scalar(Cow<'a, ScalarValue>),
}
```

There is **no `Text` variant**: text is `Value::Object(ObjType::Text)`. `Value<'a>`
carries a lifetime only through `Scalar(Cow<'a, ScalarValue>)` — the object case owns
nothing. The source carries a TODO noting the `Cow` may be removable if patches stop
storing scalars (`value.rs:13-15`).

`Value` constructors (`value.rs:19-62`):

```rust
pub fn map() -> Value<'a>;                 pub fn list() -> Value<'a>;
pub fn text() -> Value<'a>;                pub fn table() -> Value<'a>;
pub fn str(s: &str) -> Value<'a>;          pub fn int(n: i64) -> Value<'a>;
pub fn uint(n: u64) -> Value<'a>;          pub fn counter(n: i64) -> Value<'a>;
pub fn timestamp(n: i64) -> Value<'a>;     pub fn f64(n: f64) -> Value<'a>;
pub fn bytes(b: Vec<u8>) -> Value<'a>;
```

`Value` predicates — eleven `is_*` classifiers, all of which return `false` for objects
(`value.rs:64-143`): `is_object`, `is_scalar`, `is_bytes`, `is_str`, `is_int`, `is_uint`,
`is_f64`, `is_counter`, `is_timestamp`, `is_boolean`, `is_null`.

`Value` accessors, each in a `to_*` / `as_*` / `into_*` triple. The `to_*` forms are all
`#[deprecated]` except `to_objtype` (`value.rs:169`):

| `to_*` (deprecated) | `as_*` | `into_*` |
| --- | --- | --- |
| `to_scalar` → `Option<&ScalarValue>` (156) | `as_scalar` (162) | `into_scalar() -> Result<ScalarValue, Self>` (146) |
| `to_bytes` → `Option<&[u8]>` (214) | `as_bytes` (220) | `into_bytes() -> Result<Vec<u8>, Self>` (201) |
| `to_str` → `Option<&str>` (242) | `as_str` (248) | `into_string() -> Result<String, Self>` (229) |
| `to_i64` (258) | `as_i64` (264) | — |
| `to_u64` (274) | `as_u64` (280) | — |
| `to_f64` (290) | `as_f64` (296) | — |
| `to_bool` (305) | `as_bool` (310) | — |
| `to_objtype` (169, *not* deprecated) | `as_objtype` (175) | — |

Plus `into_owned() -> Value<'static>` (182) and `to_owned() -> Value<'static>` (190).
`Display` delegates to `ObjType::Display` / `ScalarValue::Display` (`value.rs:317-324`).

`From` impls into `Value<'static>` / `Value<'_>` (`value.rs:326-427`): `&str`, `&String`,
`String`, `SmolStr`, `char`, `Vec<u8>`, `f64`, `i64`, `i32`, `u32`, `u64`, `bool`, `()`,
`ObjType`, `ScalarValue`, `&'a ScalarValue`, `&'a op_set2::ScalarValue<'a>`.

```rust
// value.rs:429-445
#[derive(Deserialize, Serialize, PartialEq, Debug, Clone, Copy)]
pub(crate) enum DataType { Counter, Timestamp, Bytes, Uint, Int, F64, Undefined }
// serde renames: "counter", "timestamp", "bytes", "uint", "int", "float64", "undefined"
```

`DataType` exists because "numerical values are not self-describing (unlike strings /
bytes / etc.)" (`value.rs:616-618`). It is the columnar-storage tag attached to a raw op
value, and is what `ScalarValue::as_datatype(DataType) -> Result<ScalarValue,
InvalidScalarValue>` coerces by (`value.rs:543-613`).

```rust
// value.rs:447-457
#[derive(Debug, Clone)]
pub struct Counter {
    pub(crate) start: i64,
    pub(crate) current: i64,
}
```

`Counter` is a public struct with **no public fields and no public constructor**, but a
hand-written `PartialEq` that compares `current` only:

```rust
// value.rs:539-544
impl PartialEq for Counter {
    fn eq(&self, other: &Self) -> bool { self.current == other.current }
}
```

`Counter` methods: `pub(crate) increment(&mut self, inc: i64)` (`value.rs:454`);
`Serialize` as `serialize_i64(self.current)` (`value.rs:460-468`); `Display` as
`current` (`value.rs:470-475`); `From<i64>` / `From<&i64>` set `start = current = n`
(`value.rs:477-493`); `From<&Counter>` for `i64`/`u64`/`f64` and `From<Counter> for i64`
take `.current` (`value.rs:495-521`).

```rust
// value.rs:515-539
#[derive(Serialize, PartialEq, Debug, Clone)]
#[serde(untagged)]
pub enum ScalarValue {
    Bytes(Vec<u8>),
    Str(SmolStr),
    Int(i64),
    Uint(u64),
    F64(f64),
    Counter(Counter),
    Timestamp(i64),
    Boolean(bool),
    /// A value from a future version of automerge
    Unknown { type_code: u8, bytes: Vec<u8> },
    Null,
}
```

`serde(untagged)` plus `Counter: Serialize` writing `serialize_i64` means a counter
serializes as a bare JSON number. `PartialEq` on `ScalarValue` is `derive`d
(`value.rs:517`) except that the `Counter` payload's own `PartialEq` ignores `start`
(`value.rs:539-544`).

`ScalarValue` methods:

```rust
pub(crate) fn as_datatype(&self, DataType) -> Result<ScalarValue, InvalidScalarValue>;  // 543
pub(crate) fn as_numerical_datatype(&self) -> Option<DataType>;                          // 619
pub fn is_bytes/is_str/is_int/is_uint/is_f64/is_counter/is_timestamp/is_boolean/is_null;   // 630-664
pub fn into_bytes(self) -> Result<Vec<u8>, Self>;                                          // 668
pub fn to_bytes/as_bytes        (678 / 684, to_* deprecated)
pub fn into_string(self) -> Result<String, Self>;                                          // 693
pub fn to_str/as_str            (703 / 709, to_* deprecated)
pub fn to_i64/as_i64            (719 / 725, to_* deprecated)
pub fn to_u64/as_u64            (739 / 752, to_* deprecated)
pub fn to_f64/as_f64            (766 / 772, to_* deprecated)
pub fn to_bool/as_bool          (786 / 791, to_* deprecated)
pub fn counter(n: i64) -> ScalarValue;                                                    // 799
pub(crate) fn as_i64_or_default(&self) -> i64;                                             // 807
```

The four numeric coercions are lossy and infallible (`value.rs:725-784`):

|  | `Int` | `Uint` | `F64` | `Counter` | `Timestamp` | others |
| --- | --- | --- | --- | --- | --- | --- |
| `as_i64` | id | `*n as i64` (wrapping) | `*n as i64` (saturating) | `.current` | id | `None` |
| `as_u64` | `*n as u64` (wrapping) | id | `*n as u64` (saturating) | `.current` | `*n as u64` | `None` |
| `as_f64` | `*n as f64` | `*n as f64` | id | `.current` | `*n as f64` | `None` |

`From` impls into `ScalarValue` (`value.rs:819-887`): `&str`, `&String`, `String`,
`Vec<u8>`, `i64`, `f64`, `u64`, `u32`, `i32`, `bool`, `()`, `char`. `Display`
(`value.rs:889-903`) prints `Str`/`Bytes` quoted, `F64` with `{:.324}`, `Counter` as
`Counter: {current}`, `Timestamp` as `Timestamp: {n}`, `Null` as `null`, `Unknown` as
`unknown type {type_code}`.

### `op_set2` borrowed scalars and metadata

```rust
// op_set2/types.rs:191-203
#[derive(PartialEq, Debug, Clone)]
pub enum ScalarValue<'a> {          // re-exported as `automerge::ScalarValueRef`
    Bytes(Cow<'a, [u8]>),
    Str(Cow<'a, str>),
    Int(i64), Uint(u64), F64(f64),
    Counter(i64),                  // FLAT, not value::Counter
    Timestamp(i64),
    Boolean(bool),
    Unknown { type_code: u8, bytes: Cow<'a, [u8]> },
    Null,
}

// op_set2/types.rs:654-658
#[derive(Debug, Clone, PartialEq)]
pub enum ValueRef<'a> { Object(ObjType), Scalar(ScalarValue<'a>) }

// op_set2/types.rs:748-759
#[derive(PartialEq, Debug, Clone)]
pub struct ChangeMetadata<'a> {
    pub actor: Cow<'a, ActorId>,
    pub author: Option<Author<'a>>,
    pub seq: u64,
    pub start_op: u64,
    pub max_op: u64,
    pub timestamp: i64,
    pub message: Option<Cow<'a, str>>,
    pub deps: Vec<ChangeHash>,
    pub hash: ChangeHash,
    pub extra: Cow<'a, [u8]>,
}
impl ChangeMetadata<'_> { pub fn into_owned(self) -> ChangeMetadata<'static>; }  // 763

// op_set2/parents.rs:86-97
#[derive(Debug, PartialEq, Eq)]
pub struct Parent {
    pub obj: ExId,
    pub typ: ObjType,
    pub prop: Prop,
    /// Whether this component is "visible"
    pub visible: bool,
}

// op_set2/parents.rs:15-19 — Iterator<Item = Parent>, YIELDS IN REVERSE ORDER
#[derive(Debug, Clone)]
pub struct Parents<'a> { obj: ObjId, ops: &'a OpSet, clock: Option<Clock> }
impl Parents<'_> {
    pub fn path(self) -> Vec<(ExId, Prop)>;                 // 25  — forward order
    pub fn visible_path(self) -> Option<Vec<(ExId, Prop)>>;  // 37  — None if any !visible
}
```

### `patches/patch.rs` — patch model

```rust
// patches/patch.rs:16-26
#[derive(Debug, Clone, PartialEq)]
pub struct Patch {
    pub obj: ObjId,                     // exid::ExId
    pub path: Vec<(ObjId, Prop)>,       // path to the property in the parent
    pub action: PatchAction,
}

// patches/patch.rs:32-84
#[derive(Debug, Clone, PartialEq)]
pub enum PatchAction {
    PutMap   { key: String, value: (Value<'static>, ObjId), conflict: bool },
    PutSeq   { index: usize, value: (Value<'static>, ObjId), conflict: bool },
    Insert   { index: usize, values: SequenceTree<(Value<'static>, ObjId, bool)> },
    SpliceText { index: usize, value: ConcreteTextValue, marks: Option<MarkSet> },
    Increment  { prop: Prop, value: i64 },
    Conflict   { prop: Prop },
    DeleteMap  { key: String },
    DeleteSeq  { index: usize, length: usize },
    Mark       { marks: Vec<Mark> },
}
```

`PatchAction::Display` is literally `write!(f, "{:?}", self)` (`patches/patch.rs:86-91`).
`Patch::has(&self, obj, recursive)` matches `obj` directly or, when recursive, any
object on the path (`patches/patch.rs:26-28`).

### `marks.rs` — rich-text marks

```rust
// marks.rs:20-25
#[derive(Debug, Clone, PartialEq)]
pub struct Mark {                 // a struct, not an enum
    pub start: usize,
    pub end: usize,
    pub name: SmolStr,
    pub value: ScalarValue,
}
impl Mark {
    pub fn new<V: Into<ScalarValue>>(name: String, value: V, start: usize, end: usize) -> Mark;  // 214
    pub fn name(&self) -> &str;                    // 222
    pub fn value(&self) -> &ScalarValue;           // 226
}

// marks.rs:106-108   — BTreeMap-backed, not a public enum
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MarkSet { marks: BTreeMap<SmolStr, ScalarValue> }

// marks.rs:112-131
#[derive(Debug, Clone, Default)]
pub struct MarkSetIter<'a> { set: Option<btree_map::Iter<'a, SmolStr, ScalarValue>> }
// Iterator<Item = (&'a str, &'a ScalarValue)>

impl MarkSet {
    pub fn iter(&self) -> MarkSetIter<'_>;                            // 136
    pub fn num_marks(&self) -> usize;                                 // 140
    pub fn len(&self) -> usize;                                       // 148
    pub fn is_empty(&self) -> bool;                                   // 160
    pub fn non_deleted_marks(&self) -> NonDeletedMarks<'_>;          // 191
    pub(crate) fn insert(&mut self, name: SmolStr, value: ScalarValue);  // 152
    fn remove(&mut self, name: &SmolStr);                             // 156
    pub(crate) fn without_unmarks(self) -> Self;                     // 182
    pub(crate) fn from_query_state(q: &RichTextQueryState<'_>) -> Option<Arc<Self>>;  // 167
}
impl FromIterator<(String, ScalarValue)> for MarkSet;                 // 206

// marks.rs:373-378
#[derive(PartialEq, Debug, Clone, Copy)]
pub enum ExpandMark { Before, After, Both, None }   // Default = After (marks.rs:380-383)
impl ExpandMark {
    pub fn from(before: bool, after: bool) -> Self;  // 386
    pub fn before(&self) -> bool;                     // 392
    pub fn after(&self) -> bool;                      // 396
}

// marks.rs:443-462
#[derive(Default, Debug, Clone)]
pub struct UpdateSpansConfig {
    pub default_expand: ExpandMark,
    pub per_mark_expands: HashMap<String, ExpandMark>,
}
impl UpdateSpansConfig {
    pub fn with_default_expand(mut self, expand: ExpandMark) -> Self;      // 451
    pub fn with_mark_expand<S: AsRef<str>>(mut self, mark_name: S, expand: ExpandMark) -> Self;  // 456
}
```

Also public: `OldMark<'a> { start, end, data }` (`marks.rs:28-32`) and
`OldMarkData { name: SmolStr, value: ScalarValue }` (`marks.rs:355-359`).
`NonDeletedMarks<'a>` (`marks.rs:440`) has a custom `PartialEq` treating
`ScalarValue::Null` entries as absent on either side (`marks.rs:448-460`).

### `cursor.rs` — sequence positions

```rust
// cursor.rs:23-30
#[derive(Clone, PartialEq, Debug)]
pub enum Cursor {
    Start,       // always dereferences to position 0
    End,         // always dereferences to sequence.length
    Op(OpCursor),// attached to a specific op
}

// cursor.rs:34-40
#[derive(Clone, PartialEq, Debug)]
pub struct OpCursor { ctr: u64, actor: ActorId, move_cursor: MoveCursor }  // all pub(crate)

// cursor.rs:52-58
#[derive(Debug)]
pub enum CursorPosition { Start, End, Index(usize) }
impl From<usize> for CursorPosition;

// cursor.rs:70-81
#[derive(Clone, PartialEq, Debug)]
pub enum MoveCursor { Before, After }   // Default = After

impl Cursor {
    pub fn to_bytes(&self) -> Vec<u8>;        // 120
    fn from_str(s: &str) -> Option<Self>;     // 88
}
impl TryFrom<&str>/<String>/<&[u8]>/<Vec<u8>> for Cursor  // 178,188,195,277
impl Display for Cursor / OpCursor                        // 159,173
```

Wire tags (`cursor.rs:84-86`): `VERSION_TAG = 1`, `START_TAG = 1`, `END_TAG = 2`,
`OP_TAG = 3`, `MOVE_BEFORE_TAG = 1`, `MOVE_AFTER_TAG = 2`. Version `0` is still accepted
on read and is decoded by `parse_0` (`cursor.rs:257-274`) into
`Cursor::Op(OpCursor { move_cursor: MoveCursor:: After })`, because `After` was the
version-0 default and start/end cursors did not exist.

### `clock.rs` — vector clocks (crate-private)

**The vector clock is not a bit-set.** It is a dense per-actor-index counter array:

```rust
// clock.rs:9-12
#[derive(Default, Debug, Clone, PartialEq)]
pub(crate) struct Clock(pub(crate) Vec<u32>);          // one u32 per actor index

// clock.rs:14-15
#[derive(Default, Debug, Clone, PartialEq)]
pub(crate) struct SeqClock(pub(crate) Vec<Option<NonZeroU32>>);  // None = "no change from this actor"
```

`Clock` API (`clock.rs:106-151`):

```rust
pub(crate) fn isolate(&mut self, actor_index: usize);              // 107  sets u32::MAX
pub(crate) fn covers(&self, id: &OpId) -> bool;                   // 113  INDEXES self.0[id.actor()]
fn counter_of(&self, actor: usize) -> u32;                         // 125  INDEXES self.0[actor]
fn set_counter_of(&mut self, actor: usize, counter: u32);         // 131  INDEXES self.0[actor]
impl FromIterator<Option<u32>> for Clock;                          // 145  None -> 0
```

`Clock::new`, `Clock::include`, `Clock::is_greater` and `impl PartialOrd for Clock`
exist **only under `#[cfg(test)]`** (`clock.rs:155-181`). In a non-test build there is
no `Clock::new`, no `Clock::include`, no `Ord`, and no way to construct a `Clock` other
than `Default` (empty) or `collect()` from `Option<u32>`s. Any port needs a real
constructor.

`SeqClock` API (`clock.rs:17-72`):

```rust
pub(crate) fn iter(&self) -> impl Iterator<Item = (usize, Option<NonZeroU32>)>;  // 18
pub(crate) fn remove_actor(&mut self, idx: usize);                               // 22
pub(crate) fn rewrite_with_new_actor(&mut self, idx: usize);                     // 26
pub(crate) fn get_for_actor(&self, actor_index: &usize) -> Option<NonZeroU32>;   // 30
pub(crate) fn new(size: usize) -> Self;                                          // 34
pub(crate) fn include(&mut self, actor_idx: usize, data: Option<u32>) -> bool;   // 38
pub(crate) fn merge(a: &mut Self, b: &Self);                                     // 54
pub(crate) fn covers(&self, other: &SeqClock) -> bool;                           // 64
```

`SeqClock` is the change-graph's clock: cached per change-graph node
(`change_graph.rs:43 clock_cache: HashMap<NodeIdx, SeqClock>`) and accumulated into
`fragment_top` (`change_graph.rs:45`).

```rust
// clock.rs:74-78
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum ClockRange {
    Current(Option<Clock>),
    Diff(Clock, Clock),
}
impl Default for ClockRange { fn default() -> Self { Self::Current(None) } }   // 80-84

impl ClockRange {
    pub(crate) fn current(clock: Option<Clock>) -> Self;   // 87
    pub(crate) fn after(&self) -> Option<&Clock>;         // 91
    pub(crate) fn visible_after(&self, id: &OpId) -> bool; // 98
    pub(crate) fn visible_before(&self, id: &OpId) -> bool;// 106  — same as predates
    pub(crate) fn predates(&self, id: &OpId) -> bool;      // 110
}
```

`ClockRange::Current(None)` is the "everything is visible, no clock needed" fast path,
matched directly at several call sites (`iter/tools.rs:407,422`; `iter/spans.rs:72,85`;
`iter/map_range.rs:205,333`).

### `change.rs` — change metadata

```rust
// change.rs:13-18
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    stored: StoredChange<'static, Verified>,   // storage::Change, the verified op-column form
    compression: CompressionState,
    len: usize,                                // op count, precomputed
}
```

`Change` public API (`change.rs:20-138`):

```rust
pub fn author<'a>(&'a self) -> Option<Author<'a>>;      // 48
pub fn actor_id(&self) -> &ActorId;                      // 52
pub fn actors(&self) -> impl Iterator<Item = &ActorId>;  // 56
pub fn other_actor_ids(&self) -> &[ActorId];             // 62
pub fn len(&self) -> usize;                              // 66
pub fn is_empty(&self) -> bool;                          // 70
pub fn max_op(&self) -> u64;                             // 74  start_op + len - 1
pub fn start_op(&self) -> NonZeroU64;                    // 78
pub fn message(&self) -> Option<&str>;                   // 82
pub fn deps(&self) -> &[ChangeHash];                      // 86
pub fn hash(&self) -> ChangeHash;                         // 90
pub fn seq(&self) -> u64;                                 // 94
pub fn timestamp(&self) -> i64;                           // 98
pub fn bytes(&mut self) -> Cow<'_, [u8]>;                 // 102  — TAKES &mut self
pub fn raw_bytes(&self) -> &[u8];                         // 118
pub fn extra_bytes(&self) -> &[u8];                       // 126
pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, LoadError>;  // 131
pub fn decode(&self) -> crate::ExpandedChange;            // 135
pub(crate) fn iter_ops(&self) -> impl Iterator<Item = ChangeOp> + '_;  // 122
```

`Change::bytes()` **mutates** the receiver to memoize the DEFLATE decision
(`change.rs:102-116`, `CompressionState` at `change.rs:140-148`). `raw_bytes()` never
compresses.

```rust
// change.rs:167-177  — re-exported as `automerge::LoadChangeError`
#[derive(thiserror::Error, Debug)]
pub enum LoadError {
    #[error("unable to parse change: {0}")]  Parse(Box<dyn std::error::Error + Send + Sync + 'static>),
    #[error("leftover data after parsing")]   LeftoverData,
    #[error("wrong chunk type")]              WrongChunkType,
}
```

Conversions: `TryFrom<&[u8]>` (`change.rs:179-201`, rejects non-`Change` chunks with
`WrongChunkType` and trailing bytes with `LeftoverData`);
`TryFrom<StoredChange<'a, Unverified>>` → `ReadChangeOpError` (`change.rs:203-211`);
`From<ExpandedChange>` (`change.rs:206-230`, panics on `PredOutOfOrder`);
`From<&Change> for ExpandedChange` (`change.rs:299-362`);
`AsRef<StoredChange<'static, Verified>>` (`change.rs:150`).

Author footer codec (`change.rs:365-403`): `Footer::Author = 1`; the encoding is
`leb128(footer_id) ‖ leb128(author_len) ‖ author_bytes`; `decode_author_footer` returns
`None` for a wrong id or a short buffer, and **does not check that the trailing bytes
are empty** (`change.rs:395-403`).

### `error.rs` — the complete error surface

```rust
// error.rs:8-10
#[derive(Error, Debug, Clone, Copy, PartialEq, Eq)]
#[error("patch logs cannot be shared between documents; this probably means a PatchLog created for one document was reused with another")]
pub struct PatchLogMismatch;
```

`AutomergeError` — **31** variants, each with an explicit `Display` string
(`error.rs:13-79`):

| Line | Variant | `Display` |
| --- | --- | --- |
| 15 | `ChangeGraph(#[from] change_graph::MissingDep)` | transparent |
| 17 | `Deflate(#[source] std::io::Error)` | `failed to load compressed data: {0}` |
| 19 | `DuplicateSeqNumber(u64, ActorId)` | `duplicate seq {0} found for actor {1}` |
| 21 | `DuplicateAuthor(Author<'static>, ActorId, u64)` | `duplicate author assignment {0} for actor {1} found for seq {2}` |
| 23 | `DuplicateActorId(ActorId)` | `duplicate actor {0}: possible document clone` |
| 25 | `Fail` | `general failure` |
| 27 | `InvalidActorId(String)` | ``invalid actor ID `{0}` `` |
| 29 | `InvalidActorIndex(usize)` | ``invalid actor index `{0}` `` |
| 31 | `InvalidChangeHashBytes(#[from] InvalidChangeHashSlice)` | transparent |
| 33 | `InvalidCharacter(usize)` | `invalid UTF-8 character at {0}` |
| 35 | `InvalidHash(ChangeHash)` | `invalid hash {0}` |
| 37 | `InvalidIndex(usize)` | `index {0} is out of bounds` |
| 39 | `InvalidObjId(String)` | ``invalid obj id `{0}` `` |
| 41 | `InvalidObjIdFormat(String)` | ``invalid obj id format `{0}` `` |
| 43 | `InvalidOp(ObjType)` | ``invalid op for object of type `{0}` `` |
| 45 | `InvalidSeq(u64)` | `seq {0} is out of bounds` |
| 47 | `InvalidCursor(Cursor)` | `cursor {0} is invalid` |
| 49 | `InvalidCursorOp` | `op has no valid cursor` (source comment: `// this error sucks`) |
| 51 | `InvalidCursorFormat` | `cursor format is invalid` |
| 53 | `InvalidValueType { expected: String, unexpected: String }` | ``invalid type of value, expected `{expected}` but received `{unexpected}` `` |
| 58 | `Load(#[from] storage::load::Error)` | transparent |
| 60 | `LoadChangeError(#[from] LoadChangeError)` | transparent |
| 62 | `MissingCounter` | `increment operations must be against a counter value` |
| 64 | `MissingHash(ChangeHash)` | `hash {0} does not correspond to a change in this document` |
| 66 | `MissingDeps` | `change's deps should already be in the document` |
| 68 | `NonChangeCompressed` | `compressed chunk was not a change` |
| 70 | `NotAnObject` | `id was not an object id` |
| 72 | `HydrateError(#[from] HydrateError)` | transparent |
| 74 | `PatchLogMismatch(#[from] PatchLogMismatch)` | transparent |
| 76 | `EncodingError(String)` | `{0}` (raw passthrough) |
| 78 | `Unbundle(Box<dyn std::error::Error + Send + Sync + 'static>)` | `failed to unbundle: {0}` |

`AutomergeError` crate constructors (`error.rs:81-98`): `encoding(impl Display)`,
`duplicate_seq(&Change)`, `duplicate_author(&Change)`.

**`AutomergeError` does not derive `PartialEq`**; it has a hand-written impl that
compares only the discriminant:

```rust
// error.rs:100-104
impl PartialEq for AutomergeError {
    fn eq(&self, other: &Self) -> bool {
        std::mem::discriminant(self) == std::mem::discriminant(other)
    }
}
```

Other error types in the same module:

```rust
// error.rs:113-115
#[derive(Error, Debug)] #[error("Invalid actor ID: {0}")]
pub struct InvalidActorId(pub String);                      // re-exported at root

// error.rs:117-119
#[derive(Error, Debug)] #[error("Invalid author: {0}")]
pub struct InvalidAuthor(pub String);                       // NOT re-exported at root

// error.rs:121-129   pub(crate)
#[derive(Error, Debug, PartialEq)]
#[error("Invalid scalar value, expected {expected} but received {unexpected}")]
pub(crate) struct InvalidScalarValue {
    pub(crate) raw_value: ScalarValue,
    pub(crate) datatype: DataType,
    pub(crate) unexpected: String,
    pub(crate) expected: String,
}

// error.rs:131-132    re-exported at root
#[derive(Error, Debug, Eq, PartialEq)]
#[error("Invalid change hash slice: {0:?}")]
pub struct InvalidChangeHashSlice(pub Vec<u8>);

// error.rs:134-136 / 138-140 / 142-144
#[error("Invalid object ID: {0}")]    pub struct InvalidObjectId(pub String);
#[error("Invalid element ID: {0}")]   pub struct InvalidElementId(pub String);
#[error("Invalid OpID: {0}")]         pub struct InvalidOpId(pub String);

// error.rs:146-152
#[derive(Error, Debug)]
pub enum InvalidOpType {
    #[error("unrecognized action index {0}")] UnknownAction(u64),
    #[error("non numeric argument for inc op")] NonNumericInc,
}

// error.rs:154-176
#[derive(Error, Debug)]
pub enum HydrateError {
    #[error("general failure")]                          Fail,
    #[error("invalid index {0} for sequence")]           InvalidIndex(usize),
    #[error("invalid key {0} for map")]                  InvalidKey(String),
    #[error("increment of a non-counter")]               BadIncrement,
    #[error("invalid op applied to map")]                InvalidMapOp,
    #[error("invalid op appied to list")]                InvalidListOp,     // sic: "appied"
    #[error("invalid op applied to map: {0}")]            InvalidTextOp(PatchAction),
    #[error("invalid prop in patch: {0}")]               ApplyInvalidProp(PatchAction),
    #[error("invalid encoding for text value")]           InvalidEncoding,
}

// error.rs:178-184
#[derive(Error, Debug)]
pub enum UpdateObjectError {
    #[error("cannot change object type")] ChangeType,
    #[error(transparent)] Automerge(#[from] AutomergeError),
}
```

### `decoding.rs` — columnar decoding (public error types only)

```rust
// decoding.rs:10-56
#[derive(Debug, thiserror::Error)]
pub enum Error {
    BufferSizeDidNotChange,
    NoDecodedValue,
    TryingToReadPastEnd,
    WrongType { expected_one_of: Vec<u8>, found: u8 },
    BadChangeFormat(#[source] error::InvalidChangeHashSlice),
    NotEnoughBytes,
    WrongMagicBytes,
    WrongByteLength { expected: usize, found: usize },
    ColumnsNotInAscendingOrder { last: u32, found: u32 },
    ChangeContainedCompressedColumns,
    InvalidChecksum { found: [u8; 4], calculated: [u8; 4] },
    InvalidChange(#[from] InvalidChangeError),
    ChangeDecompressFailed(String),
    NoDocChanges,
    Overflow,
    MismatchedHeads,
    Leb128(#[from] leb128::read::Error),
    Io(#[from] io::Error),
}
```

`decoding::Error` has a hand-written `PartialEq` (`decoding.rs:58-100`) that compares
fields for the structured variants, treats **all** `Leb128` errors as equal regardless
of cause, and compares `Io` errors by `ErrorKind` only. This is the second place in the
slice where `PartialEq` is deliberately weaker than content equality.

```rust
// decoding.rs:102-117
#[derive(thiserror::Error, PartialEq, Debug)]
pub enum InvalidChangeError {
    #[error("Change contained an operation with action 'set' which did not have a 'value'")]
    SetOpWithoutValue,
    #[error("Received an inc operation which had an invalid value, value was: {op_value:?}")]
    IncOperationWithInvalidValue { op_value: Option<amp::ScalarValue> },
    #[error("Change contained an invalid object id: {}", source.0)]
    InvalidObjectId { #[from] source: error::InvalidObjectId },
    #[error("Change contained an invalid hash: {:?}", source.0)]
    InvalidChangeHash { #[from] source: error::InvalidChangeHashSlice },
}
```

Crate-private decoders: `Decodable` trait with
`fn decode<R: Read>(bytes: &mut R) -> Option<Self>` (`decoding.rs:316-321`), implemented
for `u8,u32,usize,isize,i32,i64,f64,f32,u64,NonZeroU64,Vec<u8>,SmolStr,String,
Option<String>,ActorId` (`decoding.rs:323-475`); `Decoder<'a>` (`decoding.rs:122`),
`BooleanDecoder<'a>` (`decoding.rs:170`), `RleDecoder<'a, T>` (`decoding.rs:214`),
`DeltaDecoder<'a>` (`decoding.rs:288`). `BooleanDecoder` and `RleDecoder` are
*endless* iterators that keep yielding after the input is exhausted
(`decoding.rs:196-212`, `245-283`).

### `author.rs`

```rust
// author.rs:143-144
#[derive(PartialEq, Hash, Clone, Ord, Eq, PartialOrd)]
pub struct Author<'a>(Cow<'a, [u8]>);

impl Author<'a> {
    pub fn into_owned(self) -> Author<'static>;         // 147
    pub fn as_borrowed<'b>(&'b self) -> Author<'b>;    // 153
    pub fn as_bytes(&self) -> &[u8];                    // 160
    pub fn to_hex_string(&self) -> String;              // 164
}
impl Display for Author                                 // 169  hex
impl Debug for Author                                   // 190  hex tuple
impl From<Vec<u8>> / From<&'a [u8]>                      // 176 / 181
impl TryFrom<&str> / <String> → error::InvalidAuthor     // 195 / 204
impl FromStr for Author                                 // 213
```

Crate-private: `Authors { authors: Vec<Author<'static>>, current: Option<AuthorIdx>,
actor_to_author: Vec<Option<AuthorIdx>> }` (`author.rs:19-38`) with `with_actors`,
`get_authors`, `get_author_for_actor`, `get_actors_for_author`, `assign_author`,
`insert_actor`, `remove_actor`, `put_author` (`author.rs:40-137`); `AuthorIdx(usize)`
(`author.rs:219`) with `as_usize` and `with_new_author`. The `authors` vec is kept
**sorted by `Ord` over the raw bytes**, and inserting a new author re-indexes every
`AuthorIdx` (`author.rs:126-137`).

### `convert.rs` — generic actor-id translation

All crate-private. Exists so that generic op code can translate `OpId` actor
representations without allocating (`convert.rs:1-26`):

```rust
pub(crate) trait OpId<ActorId> {         // convert.rs:28-31
    fn actor(&self) -> ActorId;
    fn counter(&self) -> u64;
}

pub(crate) enum ObjId<O>  { Root, Op(O) }              // convert.rs:31-34
pub(crate) enum ElemId<O> { Head, Op(O) }              // convert.rs:59-62
pub(crate) enum Key<'a, O> {                            // convert.rs:77-80
    Prop(Cow<'a, smol_str::SmolStr>),
    Elem(ElemId<O>),
}
```

`ObjId::map`, `ElemId::map`, `Key::map` take `F: Fn(O) -> P` (`convert.rs:44-56`,
`65-72`, `83-92`). `OpId<usize>` is implemented for both `crate::types::OpId` and
`&crate::types::OpId` (`convert.rs:94-105`); `OpId<&'a ActorId>` for `&'a legacy::OpId`
(`change.rs:239-252`).

**Naming traps.** The names the assignment asked about map to *different* things in
different namespaces:

| Asked-about name | What actually exists |
| --- | --- |
| `Obj` | no such type. `convert::ObjId<O>` (`convert.rs:31`) and `legacy::ObjectId` (`legacy/mod.rs:55`) |
| `ObjProp` | no such type. The public property enum is `types::Prop` (`types.rs:389`); the crate-private op-key enum is `op_set2::KeyRef<'a>` (`op_set2/types.rs:579`) |
| `Key` | `convert::Key<'a, O>` (`convert.rs:77`, crate-private) and `legacy::Key`; `columnar::Key` is the stored form |
| `Diff` | `iter::tools::Diff { Same, Add, Remove }` (`iter/tools.rs:611`, crate-private) and `iter::spans::MarkDiff` (`iter/spans.rs:291`, crate-private) |
| `Move` | only `cursor::MoveCursor { Before, After }` (`cursor.rs:71`, public) |
| `Mark` | a public **struct** (`marks.rs:21`), not an enum; the enum-like thing is `ExpandMark` |
| vector-clock bit-set | no such representation; see `clock.rs` above |

### `text_value.rs`

```rust
impl TextEncoding { pub fn platform_default() -> Self; }   // text_value.rs:12-22

pub(crate) trait TextValue {                                 // text_value.rs:26-33
    type Elem;
    fn new(s: &str) -> Self;
    fn splice(&mut self, index: usize, value: &str);
    fn splice_text_value(&mut self, index: usize, value: &SequenceTree<Self::Elem>);
    fn make_string(&self) -> String;
    fn len(&self) -> usize;
    fn remove(&mut self, index: usize);
}

pub struct Utf8(SequenceTree<u8>);        // text_value.rs:37   (pub)
pub struct CodePoint(SequenceTree<char>); // text_value.rs:74   (pub)
pub struct Utf16(SequenceTree<u16>);      // text_value.rs:107  (pub)
pub struct Grapheme(SequenceTree<String>);// text_value.rs:141  (pub)

pub enum ConcreteTextValue {              // text_value.rs:185-192
    Utf8CodeUnit(Utf8), Utf16CodeUnit(Utf16), CodePoint(CodePoint), Grapheme(Grapheme),
}
impl ConcreteTextValue {
    pub fn new(s: &str, text_encoding: TextEncoding) -> Self;   // 194
    pub fn make_string(&self) -> String;                         // 203
    pub(crate) fn splice_text_value(&mut self, index, other) -> Result<(), MismatchedEncoding>;  // 214
    pub(crate) fn splice(&mut self, index: usize, value: &str); // 236
    pub(crate) fn len(&self) -> usize;                          // 243
    pub(crate) fn remove(&mut self, index: usize);              // 250
}
```

`Utf8::make_string` uses `String::from_utf8_lossy` (`text_value.rs:60-63`) and
`Utf16::make_string` uses `String::from_utf16_lossy` (`text_value.rs:129-132`), so
neither is infallible-by-construction.

### `read.rs` — `ReadDoc`

```rust
// read.rs:14-20
/// Methods for reading values from an automerge document
pub trait ReadDoc {
```

Full method set, in declaration order (`read.rs:20-310`):

```rust
// objects & parents
fn parents<O: AsRef<ExId>>(&self, obj: O) -> Result<Parents<'_>, AutomergeError>;                    // 32
fn parents_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Result<Parents<'_>, Auto…>;     // 40

// key iteration
fn keys<O: AsRef<ExId>>(&self, obj: O) -> Keys<'_>;                                                  // 47
fn keys_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Keys<'_>;                          // 51

// object iteration
fn iter(&self) -> DocIter<'_> { self.iter_at(&ROOT, None) }                                            // 64  (default body)
fn iter_at<O: AsRef<ExId>>(&self, obj: O, heads: Option<&[ChangeHash]>) -> DocIter<'_>;                // 58
fn map_range<'a, O: AsRef<ExId>, R: RangeBounds<String> + 'a>(&'a self, obj: O, range: R) -> MapRange<'a>;  // 79
fn map_range_at<'a, O: AsRef<ExId>, R: RangeBounds<String> + 'a>(&'a self, obj: O, range: R, heads: &[ChangeHash]) -> MapRange<'a>;  // 91
fn list_range<O: AsRef<ExId>, R: RangeBounds<usize>>(&self, obj: O, range: R) -> ListRange<'_>;        // 105
fn list_range_at<O: AsRef<ExId>, R: RangeBounds<usize>>(&self, obj: O, range: R, heads: &[ChangeHash]) -> ListRange<'_>;  // 115
fn values<O: AsRef<ExId>>(&self, obj: O) -> Values<'_>;                                                // 124
fn values_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Values<'_>;                      // 130

// shape
fn length<O: AsRef<ExId>>(&self, obj: O) -> usize;                                                     // 137
fn length_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> usize;                            // 143
fn object_type<O: AsRef<ExId>>(&self, obj: O) -> Result<ObjType, AutomergeError>;                       // 149

// marks
fn marks<O: AsRef<ExId>>(&self, obj: O) -> Result<Vec<Mark>, AutomergeError>;                           // 155
fn marks_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Result<Vec<Mark>, Auto…>;            // 161
fn get_marks<O: AsRef<ExId>>(&self, obj: O, index: usize, heads: Option<&[ChangeHash]>) -> Result<MarkSet, AutomergeError>;  // 171

// text
fn text<O: AsRef<ExId>>(&self, obj: O) -> Result<String, AutomergeError>;                                // 179
fn text_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Result<String, Auto…>;                // 184
fn spans<O: AsRef<ExId>>(&self, obj: O) -> Result<Spans<'_>, AutomergeError>;                            // 190
fn spans_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Result<Spans<'_>, Auto…>;            // 196

// cursors
fn get_cursor<O: AsRef<ExId>, I: Into<CursorPosition>>(&self, obj: O, position: I, at: Option<&[ChangeHash]>) -> Result<Cursor, AutomergeError>;      // 220
fn get_cursor_moving<O: AsRef<ExId>, I: Into<CursorPosition>>(&self, obj: O, position: I, at: Option<&[ChangeHash]>, move_cursor: MoveCursor) -> Result<Cursor, AutomergeError>;  // 240
fn get_cursor_position<O: AsRef<ExId>>(&self, obj: O, cursor: &Cursor, at: Option<&[ChangeHash]>) -> Result<usize, AutomergeError>;  // 254

// values
fn get<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P) -> Result<Option<(Value<'_>, ExId)>, AutomergeError>;  // 275
fn get_at<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P, heads: &[ChangeHash]) -> Result<Option<(Value<'_>, ExId)>, AutomergeError>;  // 285
fn get_all<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P) -> Result<Vec<(Value<'_>, ExId)>, AutomergeError>;  // 296
fn get_all_at<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P, heads: &[ChangeHash]) -> Result<Vec<(Value<'_>, ExId)>, AutomergeError>;  // 303
fn hydrate<O: AsRef<ExId>>(&self, obj: O, heads: Option<&[ChangeHash]>) -> Result<hydrate::Value, AutomergeError>;  // 291

// document-level
fn get_missing_deps(&self, heads: &[ChangeHash]) -> Vec<ChangeHash>;   // 307
fn get_change_by_hash(&self, hash: &ChangeHash) -> Option<Change>;     // 310
fn stats(&self) -> Stats;                                              // 313
fn text_encoding(&self) -> TextEncoding;                               // 315
}
```

`fn iter()` is the only method with a default body (`read.rs:64`); every other method is
required. Note the API split: `length` returns `0` for an object not in the document
rather than an error (`read.rs:137-141`), while `object_type`, `text`, `marks`, and
`parents` return `Err`.

```rust
// read.rs:312-327
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stats {
    pub num_ops: u64,
    pub num_changes: u64,
    pub num_actors: u64,
    pub cargo_package_name: &'static str,     // "automerge"
    pub cargo_package_version: &'static str,  // from env!("CARGO_PKG_VERSION")
    pub rustc_version: &'static str,          // env!("CARGO_PKG_RUST_VERSION")
}
```

`Automerge`'s `stats()` populates these from `change_graph.len()`, `ops.len()`,
`ops.actors.len()` and the compile-time env macros (`automerge.rs:2300-2315`). Note
`rustc_version` is the crate's **`rust-version` MSRV** (`1.90.0`, `Cargo.toml:7`), not
the compiling compiler's version.

Implementors of `ReadDoc`: `Automerge` (`automerge.rs:2073-2320`),
`AutoCommit` (`autocommit.rs:833-1067`), `Transaction<'_>` via
`macro_rules! impl_read_doc_for_tx` (`transaction.rs:36`, invoked at
`transaction/manual_transaction.rs:121`). `OwnedTransaction` is separate.

### `transaction/transactable.rs` — `Transactable`

```rust
// transaction/transactable.rs:8-9
/// A way of mutating a document within a single change.
pub trait Transactable: ReadDoc {
```

Full method set (`transaction/transactable.rs:9-196`):

```rust
fn pending_ops(&self) -> usize;                                                                     // 11
fn put<O: AsRef<ExId>, P: Into<Prop>, V: Into<ScalarValue>>(&mut self, obj: O, prop: P, value: V) -> Result<(), AutomergeError>;      // 24
fn put_object<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, object: ObjType) -> Result<ExId, AutomergeError>;                    // 37
fn insert<O: AsRef<ExId>, V: Into<ScalarValue>>(&mut self, obj: O, index: usize, value: V) -> Result<(), AutomergeError>;                    // 47
fn insert_object<O: AsRef<ExId>>(&mut self, obj: O, index: usize, object: ObjType) -> Result<ExId, AutomergeError>;                           // 54
fn increment<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, value: i64) -> Result<(), AutomergeError>;                              // 61
fn delete<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P) -> Result<(), AutomergeError>;                                           // 68
fn splice<O: AsRef<ExId>, V: Into<crate::hydrate::Value>, I: IntoIterator<Item = V>>(&mut self, obj: O, pos: usize, del: isize, vals: I) -> Result<(), AutomergeError>;  // 83
fn splice_text<O: AsRef<ExId>>(&mut self, obj: O, pos: usize, del: isize, text: &str) -> Result<(), AutomergeError>;                           // 92
fn mark<O: AsRef<ExId>>(&mut self, obj: O, mark: Mark, expand: ExpandMark) -> Result<(), AutomergeError>;                                    // 99
fn unmark<O: AsRef<ExId>>(&mut self, obj: O, key: &str, start: usize, end: usize, expand: ExpandMark) -> Result<(), AutomergeError>;           // 105
fn split_block<O>(&mut self, obj: O, index: usize) -> Result<ExId, AutomergeError> where O: AsRef<ExId>;                                      // 116
fn join_block<O: AsRef<ExId>>(&mut self, text: O, index: usize) -> Result<(), AutomergeError>;                                                 // 122
fn replace_block<O>(&mut self, text: O, index: usize) -> Result<ExId, AutomergeError> where O: AsRef<ExId>;                                   // 128
fn update_spans<O: AsRef<ExId>, I: IntoIterator<Item = Span>>(&mut self, text: O, config: UpdateSpansConfig, new_text: I) -> Result<(), AutomergeError>;  // 141
fn base_heads(&self) -> Vec<ChangeHash>;                                                                                                    // 147
fn update_text<S: AsRef<str>>(&mut self, obj: &ExId, new_text: S) -> Result<(), AutomergeError>;                                             // 158
fn update_object<O: AsRef<ExId>>(&mut self, obj: O, new_value: &crate::hydrate::Value) -> Result<(), crate::error::UpdateObjectError>;         // 164
fn batch_create_object<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, value: &crate::hydrate::Value, insert: bool) -> Result<ExId, AutomergeError>;  // 179
fn init_root_from_hydrate(&mut self, value: &crate::hydrate::Map) -> Result<(), AutomergeError>;                                            // 190
}
```

`split_block` and `replace_block` put their `where O: AsRef<ExId>` clause on the
*method* rather than the trait (unlike the other generic methods) — cosmetic, but it
means they are not uniform with `join_block`.

```rust
// transaction/transactable.rs:198-203
#[derive(Debug, PartialEq, Clone)]
pub enum BlockOrText<'a> {
    Block(crate::hydrate::Map),
    Text(Cow<'a, str>),
}

// transaction.rs:8-16
pub use self::commit::CommitOptions;
pub use self::transactable::{BlockOrText, Transactable};
pub(crate) use inner::{TransactionArgs, TransactionInner};
pub use manual_transaction::Transaction;
pub use owned_transaction::OwnedTransaction;
pub use result::Failure;
pub use result::Success;
pub type Result<O, E> = std::result::Result<Success<O>, Failure<E>>;

// transaction/result.rs:4-10
#[derive(Debug)]
pub struct Success<O> { pub result: O, pub hash: Option<ChangeHash>, pub patch_log: PatchLog }
// transaction/result.rs:13-18
#[derive(Debug)]
pub struct Failure<E> { pub error: E, pub cancelled: usize }

// transaction/commit.rs:1-7
#[derive(Debug, Default)]
pub struct CommitOptions { pub message: Option<String>, pub time: Option<i64> }
// with_message / set_message / with_time / set_time   (commit.rs:11,17,22,27)

// transaction/manual_transaction.rs:22-29
#[derive(Debug)]
pub struct Transaction<'a> {
    inner: Option<TransactionInner>,
    patch_log: PatchLog,
    doc: &'a mut Automerge,
}
impl Transaction<'_> {
    pub fn get_heads(&self) -> Vec<ChangeHash>;                                        // 57
    pub fn commit(mut self) -> (Option<ChangeHash>, PatchLog);                        // 62
    pub fn commit_with(mut self, options: CommitOptions) -> (Option<ChangeHash>, PatchLog);  // 84
    pub fn rollback(mut self) -> usize;                                               // 94
}
impl<'a> Transaction<'a> { pub fn hash_for_opid(&self, opid: &ExId) -> Option<ChangeHash>; }  // 40
impl Drop for Transaction<'_> { /* rolls back if inner is still Some */ }           // 128-140
```

### `automerge.rs` — `Automerge`

```rust
// automerge.rs:247-262
#[derive(Debug, Clone)]
pub struct Automerge {
    pub(crate) queue: ChangeQueue,       // unapplied changes not causally ready
    pub(crate) change_graph: ChangeGraph,
    authors: Authors,
    deps: HashSet<ChangeHash>,           // current heads
    pub(crate) ops: OpSet,
    actor: Actor,                        // enum Actor { Unused(ActorId), Cached(usize) }  (automerge.rs:48-51)
    author: Option<Author<'static>>,
}

// automerge.rs:70-80
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnPartialLoad { Ignore, Error }     // Error is the default

// automerge.rs:82-88
#[derive(Debug)]
pub enum StringMigration { NoMigration, ConvertToText }

// automerge.rs:90-98  — builder, all fields private
#[derive(Debug)]
pub struct LoadOptions<'a> {
    on_partial_load: OnPartialLoad,        // default Error      (automerge.rs:177)
    verification_mode: VerificationMode,   // default Check      (automerge.rs:178)
    string_migration: StringMigration,     // default NoMigration
    patch_log: Option<&'a mut PatchLog>,  // default None
    text_encoding: TextEncoding,           // default platform_default
    author: Option<Author<'static>>,       // default None
}
impl<'a> LoadOptions<'a> {
    pub fn new() -> LoadOptions<'static>;                       // 101
    pub fn on_partial_load(self, OnPartialLoad) -> Self;        // 108
    pub fn verification_mode(self, VerificationMode) -> Self;   // 118
    pub fn patch_log(self, &'a mut PatchLog) -> Self;           // 128
    pub fn migrate_strings(self, StringMigration) -> Self;      // 152
    pub fn text_encoding(self, TextEncoding) -> Self;           // 159
    pub fn author(self, Author<'static>) -> Self;               // 166
}

// automerge.rs:2329-2334
#[derive(Debug)]
pub struct SaveOptions { pub deflate: bool, pub retain_orphans: bool }
// Default: deflate = true, retain_orphans = true   (automerge.rs:2347-2353)
```

Every `Automerge` public method (`automerge.rs:265-2071`):

```rust
// construction & identity
pub fn new() -> Self;                                                   // 267  (random ActorId)
pub fn new_with_encoding(encoding: TextEncoding) -> Self;              // 307
pub fn anonymize(&self) -> Result<Self, AnonymizeError>;               // 292
pub fn init_from_hydrate(&mut self, &hydrate::Map) -> Result<(), AutomergeError>;  // 300
pub fn is_empty(&self) -> bool;                                         // 349
pub fn with_actor(self, ActorId) -> Self;                               // 361
pub fn set_actor(&mut self, ActorId) -> &mut Self;                      // 367
pub fn with_author(self, Option<Author<'static>>) -> Self;             // 376
pub fn set_author(&mut self, Option<Author<'static>>) -> &mut Self;    // 389
pub fn get_author(&self) -> Option<&Author<'static>>;                  // 399
pub fn get_actors_for_author(&self, &Author<'_>) -> Vec<ActorId>;       // 403
pub fn get_authors(&self) -> &[Author<'static>];                       // 410
pub fn get_author_for_actor(&self, &ActorId) -> Option<Author<'_>>;   // 414
pub fn get_actor(&self) -> &ActorId;                                   // 420

// transactions
pub fn transaction(&mut self) -> Transaction<'_>;                                       // 476
pub fn transaction_log_patches(&mut self, PatchLog) -> Result<Transaction<'_>, PatchLogMismatch>;  // 487
pub fn transaction_at(&mut self, PatchLog, &[ChangeHash]) -> Result<Transaction<'_>, …>; // 501
pub fn into_transaction(self, Option<PatchLog>, Option<&[ChangeHash]>) -> Result<Transaction<'_>, …>;  // 525
pub fn transact<F,O,E>(&mut self, f: F) -> transaction::Result<O, E>;                 // 586
pub fn transact_with<F,O,E,C>(&mut self, c: C, f: F) -> transaction::Result<O, E>;     // 594
pub fn transact_and_log_patches<F,O,E>(&mut self, f: F) -> transaction::Result<O, E>;   // 635
pub fn transact_and_log_patches_with<F,O,E,C>(&mut self, c: C, f: F) -> …;               // 643
pub fn empty_commit(&mut self, CommitOptions) -> ChangeHash;                            // 693

// forking & comparison
pub fn fork(&self) -> Self;                                                    // 702  (fresh random ActorId)
pub fn fork_at(&self, heads: &[ChangeHash]) -> Result<Self, AutomergeError>;     // 711
pub fn diff_opset(&self, &Self) -> Result<(), AutomergeError>;                    // 798

// loading
pub fn load(data: &[u8]) -> Result<Self, AutomergeError>;                          // 834
pub fn load_unverified_heads(data: &[u8]) -> Result<Self, AutomergeError>;         // 841
#[deprecated(since = "0.5.2", note = "Use `load_with_options` instead")]
pub fn load_with(data: &[u8], OnPartialLoad, VerificationMode, &mut PatchLog) -> Result<Self, AutomergeError>;  // 862
pub fn load_with_options(data: &[u8], LoadOptions<'_>) -> Result<Self, AutomergeError>;  // 883
pub fn rescue(data: &[u8]) -> Result<hydrate::Value, AutomergeError>;               // 897
pub fn load_incremental(&mut self, data: &[u8]) -> Result<usize, AutomergeError>;    // 1027
pub fn load_incremental_log_patches(&mut self, data: &[u8], &mut PatchLog) -> Result<usize, AutomergeError>;  // 1033

// patches & diffs
pub fn make_patches(&self, &mut PatchLog) -> Vec<Patch>;                            // 1005
pub fn current_state(&self) -> Vec<Patch>;                                          // 1014
pub fn diff(&self, before_heads: &[ChangeHash], after_heads: &[ChangeHash]) -> Vec<Patch>;  // 1420
pub fn diff_obj(&self, obj: &ExId, before_heads: &[ChangeHash], after_heads: &[ChangeHash]) -> Vec<Patch>;  // 1444

// change application
pub fn apply_changes(&mut self, impl IntoIterator<Item = Change> + Clone) -> Result<(), AutomergeError>;  // 1097
pub fn apply_changes_log_patches<I: IntoIterator<Item = Change> + Clone>(&mut self, I, &mut PatchLog) -> Result<(), AutomergeError>;  // 1106
pub fn merge(&mut self, &mut Self) -> Result<Vec<ChangeHash>, AutomergeError>;        // 1115
pub fn merge_and_log_patches(&mut self, &mut Self, &mut PatchLog) -> Result<Vec<ChangeHash>, AutomergeError>;  // 1121

// saving
pub fn save(&self) -> Vec<u8>;                                                       // 1169
pub fn save_with_options(&self, SaveOptions) -> Vec<u8>;                             // 1149
pub fn save_and_verify(&self) -> Result<Vec<u8>, AutomergeError>;                    // 1174
pub fn save_nocompress(&self) -> Vec<u8>;                                            // 1181
pub fn save_after(&self, heads: &[ChangeHash]) -> Vec<u8>;                            // 1194
pub fn bundle<I>(&self, hashes: I) -> Result<Bundle, AutomergeError> where I: IntoIterator<Item = ChangeHash>;  // 1141

// heads & changes
pub fn get_heads(&self) -> Vec<ChangeHash>;                                          // 1506
pub fn get_last_local_change(&self) -> Option<Change>;                              // 1223
pub fn get_changes(&self, have_deps: &[ChangeHash]) -> Vec<Change>;                  // 1512
pub fn get_changes_meta(&self, have_deps: &[ChangeHash]) -> Vec<ChangeMetadata<'_>>; // 1516
pub fn get_change_meta_by_hash(&self, &ChangeHash) -> Option<ChangeMetadata<'_>>;    // 1525
pub fn get_changes_added(&self, &mut Self) -> Vec<Change>;                          // 1532
pub fn hash_for_opid(&self, &ExId) -> Option<ChangeHash>;                            // 1559
pub fn has_our_changes(&self, &sync::State) -> bool;                                 // 2027

// hydration
pub fn hydrate(&self, heads: Option<&[ChangeHash]>) -> hydrate::Value;                // 1633

// doc(hidden) internals exposed publicly
#[doc(hidden)] pub fn import(&self, s: &str) -> Result<(ExId, ObjType), AutomergeError>;         // 1331
#[doc(hidden)] pub fn import_obj(&self, s: &str) -> Result<ExId, AutomergeError>;                // 1344
#[doc(hidden)] pub fn fragments<R: RangeBounds<usize>>(&self, levels: R) -> Vec<Fragment>;      // 1465
#[doc(hidden)] pub fn get_fragment(&self, head: ChangeHash) -> Option<Fragment>;                 // 1481
#[doc(hidden)] pub fn bundle_fragments<I: IntoIterator<Item = Fragment>>(&self, I) -> Vec<Vec<u8>>;  // 1491
pub fn dump(&self);                                                                            // 1364
#[cfg(test)] pub fn debug_cmp(&self, &Self);                                                   // 1164
pub fn text_encoding(&self) -> TextEncoding;                                                   // 2068
```

`Automerge` implements `ReadDoc` (`automerge.rs:2073-2320`), `Default`
(`automerge.rs:2322-2326`), and `sync::SyncDoc`.

### `autocommit.rs` — `AutoCommit`

```rust
// autocommit.rs:63-72
#[derive(Debug, Clone)]
pub struct AutoCommit {
    pub(crate) doc: Automerge,
    transaction: Option<(PatchLog, TransactionInner)>,
    patch_log: PatchLog,
    diff_cursor: Vec<ChangeHash>,
    diff_cache: Option<(OpRange, ObjId, bool, Vec<Patch>)>,
    save_cursor: Vec<ChangeHash>,
    isolation: Option<Vec<ChangeHash>>,
}
```

`AutoCommit` public methods (`autocommit.rs:91-831`). The recurring shape is
"call `ensure_transaction_closed()` first, then delegate to `self.doc`" — that call is
what commits any in-flight transaction as a side effect of an otherwise read-only
method such as `get_heads`.

```rust
pub fn new() -> AutoCommit;                                     // 92
pub fn new_with_encoding(TextEncoding) -> AutoCommit;          // 100
pub fn default() -> AutoCommit;                                 // 78
pub fn diff_opset(&self, &AutoCommit) -> Result<(), AutomergeError>;  // 96
pub fn anonymize(&mut self) -> Result<Self, AnonymizeError>;    // 114
pub fn load(&[u8]) -> Result<Self, AutomergeError>;             // 127
pub fn load_unverified_heads(&[u8]) -> Result<Self, AutomergeError>;  // 140
#[deprecated(since="0.5.2")] pub fn load_with(&[u8], OnPartialLoad, VerificationMode, &mut PatchLog) -> Result<Self, AutomergeError>;  // 154
pub fn load_with_options(&[u8], LoadOptions<'_>) -> Result<Self, AutomergeError>;  // 167
pub fn reset_diff_cursor(&mut self);                            // 185
pub fn update_diff_cursor(&mut self);                           // 199
pub fn diff_cursor(&self) -> Vec<ChangeHash>;                   // 210
pub fn make_patches(&self, &mut PatchLog) -> Vec<Patch>;        // 215
pub fn diff(&mut self, &[ChangeHash], &[ChangeHash]) -> Vec<Patch>;   // 254
pub fn diff_obj(&mut self, &ExId, &[ChangeHash], &[ChangeHash]) -> Vec<Patch>;  // 326
pub fn diff_incremental(&mut self) -> Vec<Patch>;               // 347
pub fn fork(&mut self) -> Self;                                 // 356
pub fn fork_at(&mut self, &[ChangeHash]) -> Result<Self, AutomergeError>;  // 369
#[doc(hidden)] pub fn document(&mut self) -> &Automerge;         // 384
pub fn with_actor(self, ActorId) -> Self;                       // 389
pub fn set_actor(&mut self, ActorId) -> &mut Self;              // 395
pub fn with_author(self, Option<Author<'static>>) -> Self;      // 401
pub fn set_author(&mut self, Option<Author<'static>>) -> &mut Self;  // 407
pub fn get_actor(&self) -> &ActorId;                            // 413
pub fn get_actors_for_author(&self, &Author<'_>) -> Vec<ActorId>;  // 417
pub fn get_author_for_actor(&self, &ActorId) -> Option<Author<'_>>;  // 421
pub fn get_author(&self) -> Option<&Author<'static>>;           // 425
pub fn get_authors(&self) -> &[Author<'static>];                // 429
pub fn isolate(&mut self, heads: &[ChangeHash]);                // 433
pub fn integrate(&mut self);                                    // 439
pub fn load_incremental(&mut self, &[u8]) -> Result<usize, AutomergeError>;  // 477
pub fn apply_changes(&mut self, impl IntoIterator<Item=Change> + Clone) -> Result<(), AutomergeError>;  // 488
pub fn apply_changes_batch(&mut self, impl IntoIterator<Item=Change> + Clone) -> Result<(), AutomergeError>;  // 502
pub fn merge(&mut self, &mut AutoCommit) -> Result<Vec<ChangeHash>, AutomergeError>;  // 517
pub fn save(&mut self) -> Vec<u8>;                               // 530
pub fn save_with_options(&mut self, SaveOptions) -> Vec<u8>;     // 534
pub fn save_and_verify(&mut self) -> Result<Vec<u8>, AutomergeError>;  // 545
pub fn bundle<I>(&self, hashes: I) -> Result<Bundle, AutomergeError>;  // 559
pub fn save_nocompress(&mut self) -> Vec<u8>;                    // 577
pub fn save_incremental(&mut self) -> Vec<u8>;                  // 590
pub fn is_empty(&self) -> bool;                                 // 599
pub fn save_after(&mut self, heads: &[ChangeHash]) -> Vec<u8>;   // 604
pub fn get_missing_deps(&mut self, &[ChangeHash]) -> Vec<ChangeHash>;  // 609
pub fn get_last_local_change(&mut self) -> Option<Change>;       // 615
pub fn get_changes(&mut self, &[ChangeHash]) -> Vec<Change>;     // 620
pub fn get_changes_meta(&mut self, &[ChangeHash]) -> Vec<ChangeMetadata<'_>>;  // 625
pub fn get_change_by_hash(&mut self, &ChangeHash) -> Option<Change>;  // 630
pub fn get_change_meta_by_hash(&mut self, &ChangeHash) -> Option<ChangeMetadata<'_>>;  // 635
pub fn get_changes_added(&mut self, &mut Self) -> Vec<Change>;   // 641
pub fn get_heads(&mut self) -> Vec<ChangeHash>;                  // 695
pub fn commit(&mut self) -> Option<ChangeHash>;                  // 707
pub fn commit_with(&mut self, CommitOptions) -> Option<ChangeHash>;  // 728
pub fn rollback(&mut self) -> usize;                             // 742
pub fn empty_change(&mut self, CommitOptions) -> ChangeHash;     // 762
pub fn sync(&mut self) -> impl SyncDoc + '_;                     // 779
pub fn hash_for_opid(&self, &ExId) -> Option<ChangeHash>;        // 790
pub fn has_our_changes(&mut self, &sync::State) -> bool;         // 827
#[doc(hidden)] pub fn import(&self, &str) -> Result<(ExId, ObjType), AutomergeError>;  // 648
#[doc(hidden)] pub fn import_obj(&self, &str) -> Result<ExId, AutomergeError>;  // 653
#[doc(hidden)] pub fn dump(&mut self);                           // 658
#[doc(hidden)] pub fn fragments<R: RangeBounds<usize>>(&self, R) -> Vec<Fragment>;  // 669
#[doc(hidden)] pub fn get_fragment(&self, ChangeHash) -> Option<Fragment>;  // 678
#[doc(hidden)] pub fn bundle_fragments<I: IntoIterator<Item=Fragment>>(&self, I) -> Vec<Vec<u8>>;  // 688
#[cfg(test)] pub fn debug_cmp(&self, &Self);                     // 567
```

`AutoCommit` implements `ReadDoc` (`autocommit.rs:833-1067`) and `Transactable`
(`autocommit.rs:1069-1303`), and is asserted `Send` in a test
(`autocommit.rs:1378-1383`) — not via an `unsafe impl Send`.

### Supporting public types referenced by the above

```rust
// storage/load.rs:11-14
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum VerificationMode { Check, DontCheck }

// hydrate.rs:21-27
#[derive(Clone, Debug, PartialEq)]
pub enum Value { Scalar(ScalarValue), Map(Map), List(List), Text(Text) }

// iter/spans.rs:409-424
#[derive(Debug, Clone, PartialEq)]
pub enum Span {
    Text { text: String, marks: Option<Arc<MarkSet>> },
    Block(crate::hydrate::Map),
}
impl Span { pub fn as_str(&self) -> &str; }   // returns "\u{fffc}" for Block

// anonymize.rs:11-23
#[derive(Debug, thiserror::Error)]
pub enum AnonymizeError {
    #[error("change {change} appeared before dependency {dependency}")]
    MissingDependency { change: ChangeHash, dependency: ChangeHash },
    #[error(transparent)] Apply(#[from] AutomergeError),
}

// autoserde.rs:21-30
#[derive(Debug)]
pub struct AutoSerde<'a, R: crate::ReadDoc>(&'a R);
impl<'a, R: ReadDoc> From<&'a R> for AutoSerde<'a, R>;
impl<R: crate::ReadDoc> serde::Serialize for AutoSerde<'_, R>;
```

---

## Semantics

Claims are derived from the code as written; anything needing a running build is
marked `[INFERENCE]`.

### Object identity and the `ExId` field order

1. `automerge::ObjId` is `exid::ExId`; the internal `types::ObjId` is unreachable
   outside the crate (`lib.rs:307`, `types.rs:514`).
2. `ExId::Id` field order is `(counter: u64, actor: ActorId, actor_index: usize)`.
   Proven by the only producer, `OpSet::id_to_exid`
   (`op_set2/op_set.rs:1054-1059`) and the only internal consumer,
   `Automerge::exid_to_opid` (`automerge.rs:744-757`).
3. **The byte encoding writes the last two fields in the opposite order.** `to_bytes`
   binds them as `(id, actor, counter)` and emits
   `… actor_len ‖ actor_bytes ‖ counter(field 2) ‖ id(field 0)` (`exid.rs:46-66`);
   `try_from` reads them back and constructs
   `Id(actor_idx_hint, actor, counter)` (`exid.rs:107-111`). The two agree, so the wire
   format is `[tag][leb actor_len][actor bytes][leb actor_index][leb counter]`.
4. `ExId::Root` is produced only for `OpId(0,0)` (`op_set2/op_set.rs:1055-1056`,
   `automerge.rs:746`). `types::ROOT = OpId(0,0)` and
   `types::ObjId::is_root()` is `counter() == 0` (`types.rs:539-541`) — root-ness is
   decided by counter alone, not by `(0,0)`.
5. `ExId` equality and hashing **ignore the actor-index field**:
   `PartialEq` matches `(ctr1 == ctr2 && actor1 == actor2)` and discards the third
   field (`exid.rs:130-139`); `Hash` hashes the first two (`exid.rs:145-154`). This is
   self-consistent (equal values hash equally) but two `ExId`s differing only in their
   cached actor index compare equal. The round-trip proptest (`exid.rs:222-229`)
   generates a random third field and would pass even if it were dropped entirely.
   `[INFERENCE]`: no reachable path in this slice constructs an `ExId` with a *stale*
   third field, so the weakening is not currently observable.
6. `ExId` `Ord`: `Root` < every `Id`; within `Id` the order is on `(field0, ActorId)`
   and the actor-index field is ignored (`exid.rs:170-185`). This is **not** the same
   total order as the internal `OpId` order (`types.rs:433-438`, `(counter, actor
   index)`). `[INFERENCE]` no `BTreeSet<ExId>`-style use in this slice depends on the
   difference.
7. `ExId::to_internal_obj` → `ObjId(OpId::new(*ctr, *actor))` (`exid.rs:70-75`);
   `OpId::new` does `try_into().unwrap()` on both fields (`types.rs:454-457`), so an
   `ExId` with field 0 or field 2 above `u32::MAX` panics.
8. `ExId`'s serialization is version-tagged (`SERIALIZATION_VERSION_TAG = 0`, low
   nibble) with a type tag in the high nibble (`exid.rs:22-24`, `96-100`). A change to
   that layout is declared breaking (`exid.rs:14-17`, `32-35`).

### `ActorId` and `Author` ordering

9. `ActorId: Ord` is `derive`d over `TinyVec<[u8; 16]>`, i.e. lexicographic over bytes
   (`types.rs:44-45`). The source carries an explicit warning that change encoding
   relies on this being byte-lexicographic (`types.rs:39-42`). The actor table is
   maintained with `binary_search` over this order (`automerge.rs:368`, `415`, `1310`,
   `1317`), so a port that compares `ActorId` by anything else corrupts the whole actor
   table.
10. `ActorId` is inline for ≤16 bytes, heap beyond (`types.rs:113-156`);
    `From<Vec<u8>>` tries `ArrayVec::try_from` and only then heap-allocates
    (`types.rs:134-143`).
11. `Author: Ord` is derived over `Cow<'a, [u8]>` (`author.rs:143`);
    `Authors::put_author` keeps the vec sorted by it and re-indexes all `AuthorIdx` on
    insert (`author.rs:126-137`); `get_actors_for_author` uses `binary_search`
    (`author.rs:66-82`).
12. `ActorId::with_concurrency(level)` prefixes the 4 magic bytes
    `[0x13,0xb2,0x23,0x09]` and a LEB128 level, then the raw bytes (`types.rs:22`,
    `76-84`). This is how a forked isolation actor is made distinct from the original.

### Value model

13. `Value<'a>` has exactly two cases; text is an *object type*, not a scalar
    (`value.rs:10-17`, `types.rs:171-181`).
14. `ScalarValue` has 10 variants, including `Unknown { type_code, bytes }` for forward
    compatibility (`value.rs:519-539`).
15. `Counter` equality compares only `current`, ignoring `start` (`value.rs:539-544`).
    Two `Counter`s with different origins are `==`; because `ScalarValue: PartialEq` is
    derived, `ScalarValue::Counter` inherits that weakening. `[INFERENCE]` this is
    deliberate — the visible value of a counter is its current total.
16. `Counter` serializes as a bare `i64` (`value.rs:460-468`), so `#[serde(untagged)]`
    on `ScalarValue` gives a counter the JSON shape of a number, not an object.
17. The four numeric coercions are **not** checked conversions. `as_i64` on a `Uint`
    wraps (`value.rs:729`); `as_u64` on a negative `Int` wraps (`value.rs:756`);
    `as_i64`/`as_u64` on an `F64` saturate per Rust's float→int `as` rules
    (`value.rs:730`, `757`). Non-numeric variants return `None` for all four
    (`value.rs:733`, `760`, `785`). `as_i64_or_default` returns `0` instead of `None`
    and also excludes `F64` (`value.rs:807-814`).
18. `as_f64` on `Int`/`Uint`/`Timestamp` is `*n as f64` — lossy above 2^53
    (`value.rs:775-778`).
19. `Value::into_owned` and `Value::to_owned` differ only in that the first consumes
    `self` (`value.rs:182-188`, `190-198`).
20. `Prop` ordering is `#[derive(PartialOrd, Eq, Ord)]` over the variant order `Map`
    then `Seq`, then by payload (`types.rs:388-393`). **Every `Prop::Map` sorts before
    every `Prop::Seq`**, independent of the key text.
21. `Prop: From<f64>` is `Prop::Seq(index as usize)` (`types.rs:373-377`). Under Rust
    `as` semantics a negative or NaN `f64` truncates to `0` and a fractional value
    truncates toward zero. `[INFERENCE]`: the conversion exists for FFI layers; no
    non-test caller appears in the covered files.
22. `ObjType::Table` is retained for backward compatibility and is "identical to maps"
    (`types.rs:175-176`); still constructible (`Value::table()` → `Value::Object(
    ObjType::Table)`, `value.rs:32-34`) and treated as a map by
    `ValueRef::from_action_value`/`hydrate` (`op_set2/types.rs:671-683`).
23. `ObjType` is `Copy + Hash + Eq`, `#[default] Map` (`types.rs:169-181`); `Display`
    is lowercase (`types.rs:218-227`).

### Clock semantics

24. `Clock` is a dense `Vec<u32>` indexed by *actor index*, not a bit-set
    (`clock.rs:9-12`). `SeqClock` is a dense `Vec<Option<NonZeroU32>>` where `None`
    means "this actor contributed nothing" (`clock.rs:14-15`).
25. `Clock::covers(&self, id: &OpId)` returns
    `self.0[id.actor()] as u64 >= id.counter()` (`clock.rs:113-118`). It **indexes
    `self.0` directly** and panics if the actor index is out of range; the doc comment
    says exactly that (`clock.rs:105-112`). Same for `counter_of` (`clock.rs:121-127`)
    and `set_counter_of` (`clock.rs:129-132`).
26. `Clock::isolate(actor_index)` sets that actor's counter to `u32::MAX`
    (`clock.rs:107-109`), which makes `covers` true for every `OpId` of that actor
    without special-casing. This is how `Automerge::isolate_actor` builds an isolation
    clock (`automerge.rs:1259-1281`).
27. `Clock: FromIterator<Option<u32>>` maps `None → 0` (`clock.rs:145-150`). This is how
    `change_graph.clock_at` builds a clock from a `SeqClock` of change counts.
28. In a **non-test** build `Clock` has no `new`, no `include`, no `Ord` and no
    `PartialOrd` (`clock.rs:155-181` is `#[cfg(test)]`). The only non-test
    constructors are `Default` (empty vec) and the `FromIterator` impl.
29. `SeqClock::include(idx, data)` returns `true` iff it raised the stored counter; it
    stores `None` for `data == 0` (`NonZeroU32::try_from(data).ok()`), and returns
    `false` for `None` input and for a non-increasing value (`clock.rs:38-52`).
30. `SeqClock::merge(a, b)` is elementwise `max` over `Option<NonZeroU32>`, and
    `zip`s, so **it silently truncates to the shorter of the two** (`clock.rs:54-62`).
31. `SeqClock::covers(&self, other)` starts with `assert_eq!(self.0.len(), other.0.len())`
    (`clock.rs:64-71`), i.e. it panics on mismatched actor counts; semantically
    `a.covers(b)` is "every actor in `b` is dominated-or-equal by `a`".
32. `ClockRange::Current(None)` means "no clock, everything visible": `visible_after`
    returns `true` and `predates` returns `false` (`clock.rs:98-116`).
    `ClockRange::Default` is `Current(None)` (`clock.rs:80-84`).
33. `ClockRange::visible_before` is literally `self.predates(id)` (`clock.rs:106-108`);
    a readability alias only.
34. `ClockRange::Diff(before, after)`: `visible_after` tests `after.covers(id)`;
    `predates` tests `before.covers(id)` (`clock.rs:98-116`). `after()` returns the
    `after` clock for both `Current(Some)` and `Diff` (`clock.rs:91-96`).
35. `Automerge::clock_at(heads)` returns `None` when `heads` are the current heads
    (`change_graph.heads_are_current(heads)`), the fast-path sentinel
    (`automerge.rs:1236-1247`).
36. **The "heads == current heads means unscoped read" shortcut is unsound while a
    transaction is in flight**, because pending ops are already in the op set but not
    under the graph's heads. Both transaction types special-case this:
    `Transaction::get_scope` (`transaction/manual_transaction.rs:102-110`) and
    `AutoCommit::get_scope` (`autocommit.rs:794-814`) always compute a real clock from
    the change graph when a transaction is open. A port that reimplements `clock_at`
    without carrying this condition will read uncommitted ops on `AutoCommit`.

### Transactions

37. `Transaction<'a>` holds `Option<TransactionInner>` specifically so `commit`/
    `rollback` can `take()` it and prevent the `Drop` rollback
    (`transaction/manual_transaction.rs:26-29`, `128-140`). Dropping a `Transaction`
    without committing **rolls back**.
38. `Transaction::commit()` returns `(Option<ChangeHash>, PatchLog)` and *clones* the
    patch log to do it — flagged `// TODO - remove this clone`
    (`transaction/manual_transaction.rs:65-68`, `86-89`).
39. `AutoCommit::commit()` returns only `Option<ChangeHash>`; the `PatchLog` stays
    internal (`autocommit.rs:707-709`, `728-740`).
40. `AutoCommit::ensure_transaction_open` lazily creates a `TransactionInner` plus a
    *branch* of the internal patch log; `ensure_transaction_closed` commits it and
    merges the branch back (`autocommit.rs:447-469`). Both are invoked from the
    `Transactable` and `ReadDoc` impls (`autocommit.rs:833-1303`), which is why
    effectively every `AutoCommit` method is `&mut self`, including pure readers like
    `get_heads` (`autocommit.rs:695`).
41. `ensure_transaction_closed` also advances `isolation` to the newly committed heads
    when isolated (`autocommit.rs:465-467`).
42. `Automerge::transact` is a scoped-transaction helper returning
    `transaction::Result<O, E> = Result<Success<O>, Failure<E>>` rather than
    `Result<O, E>` (`automerge.rs:586-591`, `transaction.rs:16`). `Success.hash` is
    `None` when the transaction produced no operations (`transaction/result.rs:8`).
43. `Automerge::empty_commit` always produces a change hash (it is an empty change, not
    a no-op) (`automerge.rs:692-696`).
44. `update_spans` reconciles text and block markers toward a target `Span` stream,
    choosing `ExpandMark` per mark name via `UpdateSpansConfig`
    (`transaction/transactable.rs:130-146`, `marks.rs:443-462`).

### Cursors

45. `Cursor::Start` always dereferences to `0` and `Cursor::End` always to
    `sequence.length`; `move_cursor` does not affect them, because those positions can
    never be removed (`read.rs:225-240`, `cursor.rs:25-27`).
46. `MoveCursor::Before` on a removed target resolves to the previous item that was
    visible at creation time, or `0`; `MoveCursor::After` resolves to the next such
    item, or `sequence.length` (`cursor.rs:62-69`).
47. `get_cursor` is defined as `get_cursor_moving(.., MoveCursor::After)`
    (`read.rs:216-218`), and `MoveCursor::default() == After` (`cursor.rs:76-81`).
48. `Cursor` wire version `0` is still accepted and decodes to
    `Op(OpCursor { move_cursor: After })` with no start/end cursor available
    (`cursor.rs:257-274`, `206-211`). Any unknown version, tag, or move byte yields
    `AutomergeError::InvalidCursorFormat` (`cursor.rs:195-232`).
49. `OpCursor` stores the full `ActorId`, not an index (`cursor.rs:34-40`) — cursors are
    portable across documents, unlike `ExId`'s cached index.
50. `Span::as_str()` returns U+FFFC for a `Block` span (`iter/spans.rs:419-426`).

### Marks

51. `MarkSet` keeps marks in a `BTreeMap<SmolStr, ScalarValue>`, so `MarkSet::iter`
    yields names in sorted order (`marks.rs:106-108`, `136-138`).
52. A mark whose value is `ScalarValue::Null` is an **unmark tombstone**, not an
    absence: `without_unmarks` strips it (`marks.rs:170-186`), `from_query_state`
    returns `None` if stripping leaves the set empty (`marks.rs:167-176`), and
    `NonDeletedMarks` comparison treats `Null` as absent on either side
    (`marks.rs:448-460`).
53. `MarkStateMachine::mark_begin` only updates the current set when the new mark
    differs from the mark immediately below it, or when there is no mark above
    (`marks.rs:257-281`); `mark_end` finds the begin by `id.prev()` (`marks.rs:283+`).
    Mark resolution is a stack discipline over `(OpId, MarkData)` ordered by `OpId`, not
    a scan.
54. `MarkAccumulator::add` coalesces adjacent equal-valued runs of the same mark name
    (`marks.rs:86-100`); `into_iter_no_unmark` filters tombstones (`marks.rs:73-84`).
55. `OpType::MarkEnd(bool)` and `OpType::MarkBegin(bool, OldMarkData)` carry an
    `expand` bool; the public `ExpandMark` (4 states) is decomposed by
    `ExpandMark::from(before, after)` (`marks.rs:386-391`) and re-joined by
    `before()`/`after()` (`marks.rs:392-399`). The bool pair in `OpType` is the
    on-the-wire form; `ExpandMark` is the API form. A port that stores only
    `ExpandMark` in the op type must remember `Both` ⇔ `(true, true)`.

### Patches and parents

56. `Patch.obj` is the *object being modified*; `Patch.path` is the chain of
    `(ObjId, Prop)` from the root down to `Patch.obj`'s parent
    (`patches/patch.rs:19-23`). `Patch::has(obj, recursive)` matches `obj` directly or,
    when recursive, any object on the path (`patches/patch.rs:26-28`).
57. `PatchAction::Insert` carries a `SequenceTree<(Value<'static>, ObjId, bool)>`, not a
    `Vec` — the third tuple element is the per-element conflict flag
    (`patches/patch.rs:48-53`).
58. `PatchAction::Increment.value` "may be negative" (`patches/patch.rs:55-60`), so a
    counter patch is a delta, not an absolute.
59. `PatchAction::SpliceText.marks` is `Option<MarkSet>`; `None` and `Some(empty)` are
    different states and both are reachable (`patches/patch.rs:54-59`; `MarkSet` is
    returned as `None` when it strips to empty, `marks.rs:167-176`).
60. `PatchAction::Display` is `Debug`, i.e. the human-readable form of a patch is its
    Rust `Debug` output (`patches/patch.rs:86-91`).
61. `Parents` is an `Iterator<Item = Parent>` that yields **in reverse order**; `None`
    means the root has been passed (`op_set2/parents.rs:5-14`, `50-71`). `path()`
    reverses it back to forward order; `visible_path()` returns `None` if any component
    has `visible == false` (`op_set2/parents.rs:25-48`).
62. `Parent::visible == false` means the property is either deleted or it lost a
    conflict (`op_set2/parents.rs:92-96`).
63. `PatchLogMismatch` is the error you get when a `PatchLog` from one document is passed
    to another (`error.rs:8-10`); `Automerge::transaction_log_patches` is the only
    constructor that can produce it at the API boundary (`automerge.rs:486-499`).

### Errors

64. `AutomergeError`'s `PartialEq` compares discriminants only (`error.rs:100-104`). Two
    `InvalidCursor` values with different cursors compare equal.
65. `decoding::Error`'s `PartialEq` treats all `Leb128` payloads as equal and compares
    `Io` by `ErrorKind` (`decoding.rs:91-95`).
66. `PatchLogMismatch` is `Clone, Copy, PartialEq, Eq` by derive (`error.rs:8-10`) but
    appears inside `AutomergeError` as a non-`Copy` field (`error.rs:74`).
67. `AutomergeError::encoding(impl Display)` eagerly stringifies into
    `EncodingError(String)`, whose `Display` is the raw string (`error.rs:82-84`,
    `75-76`).
68. `HydrateError::InvalidTextOp(PatchAction)` and `ApplyInvalidProp(PatchAction)` embed
    an entire `PatchAction` (including a possible `SequenceTree` and
    `ConcreteTextValue`) in the error (`error.rs:170-173`). Error values here are not
    cheap.
69. `AutomergeError::Unbundle` boxes a `dyn std::error::Error + Send + Sync`, so
    `AutomergeError` is `Send + Sync`; it is not `Clone` and not `Eq`.
70. `AutomergeError` derives only `Error, Debug` (`error.rs:12`), and several variants
    that could carry a `source()` chain do not.

### Documents and heads

71. `Automerge::get_heads()` returns `self.deps` collected into a `Vec` and
    `sort_unstable()`d (`automerge.rs:1506-1510`). The sort is what makes the head list
    canonical; `has_our_changes` compares it to `state.shared_heads` for exact equality
    (`automerge.rs:2026-2029`).
72. `Automerge::set_actor` binary-searches the actor into the existing table and
    distinguishes `Actor::Cached(idx)` from `Actor::Unused(actor_id)`; the actor slot is
    only allocated lazily at first commit, via `get_or_create_actor_index`
    (`automerge.rs:48-51`, `366-373`, `456-466`).
73. `Automerge::set_author` regenerates the actor ID when the author changes (the
    comment says `// TODO: re-use old actors`) (`automerge.rs:388-396`).
74. `Automerge::fork` clones and assigns a fresh random `ActorId`
    (`automerge.rs:701-708`); `fork_at` clones and rewinds to `heads`, deduplicating and
    validating the head set first (`automerge.rs:710-735`).
75. `Automerge::is_empty()` is `change_graph.is_empty() && queue.is_empty()`
    (`automerge.rs:348-351`).
76. `Automerge::save_with_options` calls `assert_no_unused_actors(true)` *before*
    serializing (`automerge.rs:1149-1152`), so "every actor in the op set has at least
    one change in the graph" is a hard requirement of saving.
77. `LoadOptions::patch_log(self, &'a mut PatchLog)` is the *only* builder method that
    introduces a lifetime parameter on `LoadOptions<'a>` (`automerge.rs:128-133`).
78. `LoadOptions::default()` uses `TextEncoding::platform_default()`, so the text
    indexing unit of a document is chosen by *compile-time features*, not by the caller
    (`automerge.rs:180`, `text_value.rs:12-22`).
79. `Automerge::rescue` bypasses mark-order validation (`MarkOrderValidation::
    AllowInvalid`) and returns only the hydrated value, discarding the change graph
    (`automerge.rs:896-904`, `storage/load.rs:18-24`).
80. `Stats::rustc_version` is `env!("CARGO_PKG_RUST_VERSION")` = the declared MSRV
    `1.90.0` (`automerge.rs:2303-2313`, `Cargo.toml:7`), not the building compiler's
    version.

### Decoding

81. `Decodable::decode` is a fallible `Read`-based decoder returning `Option`, and
    `Decoder::read` treats "returned `None`" and "consumed zero bytes" as distinct
    errors (`decoding.rs:12-16`, `147-159`, `316-321`).
82. `Decodable for Option<String>` decodes an empty `Vec<u8>` as `None`
    (`decoding.rs:444-456`), i.e. the *empty string is unrepresentable* as an
    `Option<String>` in this column format.
83. `RleDecoder` is endless: it returns `Some(None)` forever after the input is exhausted
    (`decoding.rs:257-263`), and `DeltaDecoder` maps that to `Some(None)` forever
    (`decoding.rs:307-311`). A port that expects a terminating iterator will not
    terminate.
84. `BooleanDecoder` starts with `last_value = true` and flips before the first read
    (`decoding.rs:182-188`, `196-212`), so the RLE boolean stream is differential: the
    first run is encoded as a bit-flip from `true`.
85. `RleDecoder`'s sign convention: `count > 0` is a run of one repeated value,
    `count < 0` is a run of `-count` literals, `count == 0` is a run of
    `read::<usize>()` nulls (`decoding.rs:245-275`).

### Author footer

86. The author footer is `leb128(1) ‖ leb128(len) ‖ author_bytes` appended to a change's
    `extra_bytes` (`change.rs:369-384`). Decoding checks the footer id and that the
    buffer is *at least* `len` long, but does not check for trailing bytes
    (`change.rs:395-403`), so a change with an author footer followed by other data
    decodes to the author successfully.
87. `Change::author()` decodes on every call and allocates nothing (`change.rs:48-50`).

---

## Zig mapping notes

### Crate-level

* **Re-exports**: Zig has no `pub use`. `automerge::ObjId` → `pub const ObjId = ExId;`
  at the root module; the `error` module becomes a namespace struct of error sets. A
  Zig error set is **flat and has no payloads**, so every `AutomergeError` variant
  carrying a value must be split (see below).
* **`log!` / `__log!` macros**: `pub fn log(comptime fmt: []const u8, args: anytype) void`
  wrapping `std.debug.print` or a `std.log` scoped logger. The `wasm` feature split
  becomes a comptime branch, which is exactly what `std.log` already does — no macro
  needed.
* **Crate lints**: no equivalent. `unreachable_pub` and `dead_code` are already
  compiler diagnostics in Zig; the rest have no analogue and should be dropped rather
  than emulated.
* **`#[cfg(test)]`-only methods** (`Clock::new`, `Clock::include`, `Clock::is_greater`,
  `PartialOrd for Clock`, `Automerge::debug_cmp`, `AutoCommit::debug_cmp`): Zig has no
  `cfg(test)`. The port must **promote** these to real functions or reimplement the
  property in tests. Promoting them is strictly better: it removes an asymmetry where
  the production build cannot construct a `Clock` at all.
* **Feature gates** (`Cargo.toml:11-17`): build options in `build.zig`. `utf8-indexing`
  must be resolved at *comptime* and baked in as a `comptime` value. Rust's precedence
  is `utf8 > utf16 > codepoint`; Zig must reproduce the *behaviour* when both are set
  (Rust's `cfg_if` silently picks `utf8`, and the crate never errors).
* **Allocator plumbing**: the Rust code hardcodes the global allocator throughout
  (`Vec::new()`, `String::new()`, `vec![]`); there is no `impl Allocator` in this slice.
  See the numbered list below.

### Traits → interfaces

* `ReadDoc` → `pub const ReadDoc = struct { ... }` holding function pointers plus a
  self pointer, or a vtable. Real hazard: `ReadDoc` has 30 methods, `AutoCommit`'s
  `&mut self` methods auto-commit transactions as a side effect, so a vtable must
  carry mutability per method (it does) *and* the `self` pointer must be `*AutoCommit`
  for the `&mut` methods. A `*anyopaque` vtable works only if every mutating method is
  reached through a documented cast. The alternative — generic dispatch,
  `fn get(comptime Self_: type, self: *const Self_, …)` — loses the vtable and forces
  static dispatch. Given `AutoSerde` and the `sync` module both take `&R: ReadDoc`
  generically, **static generic dispatch is the closer fit**; the trait's
  `AsRef<ExId>` / `Into<Prop>` generic parameters are the harder part.
* `Transactable: ReadDoc` → same, with the supertrait meaning "the struct also has the
  `ReadDoc` methods". Zig has no trait bounds, so a `Transactable` interface must
  *redeclare* the `ReadDoc` methods or document that the caller must have both.
  Together the two traits are ~50 methods on a Zig struct.
* `impl SyncDoc for SyncWrapper<'_>` and `AutoCommit::sync() -> impl SyncDoc + '_`
  (`autocommit.rs:779-782`, `1306-1350`): `impl Trait` in return position maps cleanly
  to a Zig opaque return type — `fn sync(self: *AutoCommit) SyncDoc` where `SyncDoc` is
  `anyopaque`-backed, or a public concrete `SyncWrapper` struct.
* `TextValue` (`text_value.rs:26`) with associated type `Elem` — the one place a
  *generic interface* is the honest mapping: `fn TextValue(comptime Elem: type) type`.
  A single runtime `ConcreteTextValue` union is the other option and matches how the
  library actually uses it.
* `Decodable` (`decoding.rs:316`) with `Self: Sized` and `decode<R: Read>` — Zig:
  `fn decode(bytes: anytype) ?T` as a free function per type, or an `interface` with a
  comptime `T`. The "consumed zero bytes" check (`decoding.rs:147-159`) has no Zig
  analogue and must be written explicitly.
* `convert::OpId<ActorId>` (`convert.rs:28`) — a trait **generic over its own
  associated value type**. Zig cannot express this. The honest translation is comptime
  duplication: two concrete functions, since there are exactly two implementors
  (`types::OpId` and `&legacy::OpId`).
* `Exportable` (`types.rs:277`) — same, one method, four implementors.

### Enums → tagged unions

* `ObjType` → `pub const ObjType = enum { map, table, list, text };` with `map` as the
  default. Rust's `Default` is a derive attribute; Zig has no equivalent, so
  `pub const default: ObjType = .map;` plus an explicit `fn default() ObjType`.
* `Prop` → a `union(enum) { map: []const u8, seq: usize }` plus a **hand-written**
  `pub fn order(a, b) std.math.Order` that compares the tag then the payload. Rust
  derives `Ord` over a mixed key/index space, and `std.meta.order` on a mixed union is
  not the same. Getting this wrong reorders every sorted key set.
* `Value<'a>` → `pub const Value = union(enum) { object: ObjType, scalar: ScalarValue };`
  The lifetime disappears (Zig slices carry their own). `Scalar(Cow<'a, ScalarValue>)`
  becomes a plain `ScalarValue` — the borrow-vs-own distinction is *lost*, and
  `Value::into_owned` / `to_owned` (`value.rs:182`, `190`) become no-ops. Acceptable:
  the public `Value<'a>` in `PatchAction` (`patches/patch.rs:37`) is already
  `Value<'static>`, so no zero-copy is promised there.
* `ScalarValue` → `union(enum) { bytes: []u8, str: SmolStr, int: i64, uint: u64, f64: f64,
  counter: Counter, timestamp: i64, boolean: bool, unknown: Unknown, null: void }`.
  `SmolStr` needs a port or `[]const u8` + arena. **The `Counter` payload is the trap**:
  `value::Counter { start, current }` with a `PartialEq` that ignores `start`
  (`value.rs:539-544`). A Zig struct with derived-`eql` semantics would compare both
  fields and silently change the behaviour of `ScalarValue` equality, which feeds patch
  generation, `get_all` conflict comparison, and `MarkSet` comparison.
  `pub fn eql(a: Counter, b: Counter) bool { return a.current == b.current; }` must be
  written explicitly and called from every comparison site.
* `ScalarValueRef` (`op_set2::ScalarValue<'a>`) is a **second, differently-shaped**
  union with `Counter(i64)` flat. It must be a distinct Zig type; merging the two would
  break the columnar packing. `Cow<'a, [u8]>` → `[]const u8` with an explicit
  owned/borrowed flag if the borrow distinction is load-bearing (it is, for zero-copy
  reads of the op set).
* `ExId` → `union(enum) { root, id: struct { counter: u64, actor: ActorId, actor_index:
  u32 } }`. This makes the field order *explicit and named*, which is a strict
  improvement over the Rust original and removes the `(id, actor, counter)` vs
  `(ctr, _, actor)` naming hazard entirely. Keep the serialization order
  `[tag][leb actor_len][actor bytes][leb actor_index][leb counter]` exactly as proven at
  `exid.rs:46-66`.
* `PatchAction` → `union(enum)` with the 9 payloads. `SequenceTree<(Value, ObjId, bool)>`
  is a generic container, so a Zig port needs a concrete `SequenceTree` for that tuple.
  `ConcreteTextValue` is itself a `union(enum)` of 4 sequence trees
  (`text_value.rs:186-192`) — nested unions with 4 different `SequenceTree<T>`
  instantiations, which in Zig means a generic `SequenceTree(T)` or an erased
  representation.
* `ClockRange` → `union(enum) { current: ?Clock, diff: struct { before: Clock, after:
  Clock } }`. `ClockRange::Current(None)` → `.current = null`; the fast path is a
  pointer compare.
* `convert::ObjId<O>` / `ElemId<O>` (`convert.rs:31`, `59`) are generic over the op-id
  type — Zig: `fn ObjId(comptime O: type) type`, or two concrete union types given the
  exact instantiation count.

### `Option` / `Result`

* `Option<T>` → `?T`; `Option<&T>` → `?*const T`.
* `Result<T, E>` → `T!E` when `E` is a plain enum, but **`AutomergeError` cannot be a
  Zig error set**: 31 variants, of which **24** declare a payload
  (`error.rs:13-79`; the "15" and the "30" here were both wrong) and Zig error
  sets are tag-only. Two workable shapes:
  1. Tag-only error set + out-parameter payload:
     `pub fn exidToOpId(self: *const Automerge, id: ExId, out: *OpId) Error!void`.
  2. `AutomergeError = union(enum) { changeGraph: MissingDep, deflate: anyerror,
     duplicateSeq: struct { seq: u64, actor: ActorId }, … }` returned by value, with a
     `pub fn toErrorSet(e: AutomergeError) ?ErrNoPayload`.
  Option 1 keeps every public call site's shape (`Result<Option<(Value, ExId)>,
  AutomergeError>` → `!?struct { Value, ExId }`) and is the smaller diff. The cost is
  that a payload-carrying variant cannot be returned through `!` without the out-param.
* `Result<T, Self>` (the `into_scalar` / `into_bytes` / `into_string` idiom,
  `value.rs:146`, `201`, `229`, `668`, `693`) → `T || Self` (an error union whose error
  type is the value type itself). Zig supports this directly and it is idiomatic.
* `transaction::Result<O, E> = Result<Success<O>, Failure<E>>` → `Success(O) ||
  Failure(E)`; `Success { result: O, hash: ?ChangeHash, patch_log: PatchLog }` is a
  plain struct.

### Ownership and lifetimes

* `&'a self` → `*const Self`; `&mut self` → `*Self`. `Transaction<'a>` holding
  `doc: &'a mut Automerge` (`transaction/manual_transaction.rs:28`) becomes
  `doc: *Automerge` with a hand-rolled `deinit` that calls `rollback` — Zig `deinit` is
  the exact analogue of Rust `Drop`, and the "take the inner out first" dance
  (`transaction/manual_transaction.rs:26-29`) maps to a `?TransactionInner` field set
  to `null` before commit.
* Borrowed *return* values are the hard part. `ReadDoc::get` returns
  `Result<Option<(Value<'_>, ExId)>, _>` (`read.rs:275`) where the `Value` may borrow
  from `self`; `keys`, `values`, `iter`, `map_range`, `list_range`, `spans`, `parents`
  all return lazily-evaluated iterators borrowing `&self` (`read.rs:32-219`). Zig
  iterator structs holding a `*const Automerge` plus a position reproduce this, but
  **every one becomes a concrete type in the signature** where Rust wrote `Keys<'_>`
  (a type alias for an opaque `impl Iterator`). That is the single largest
  signature-expansion in this slice: 12 `ReadDoc` methods return `impl Iterator` or a
  named iterator type.
* `Change<'static>`'s `'static` is `StoredChange<'static, Verified>` (`change.rs:15`);
  a Zig port would naturally be a borrowed `*const StoredChange`, which is *stricter*
  than Rust's (the Rust value owns it). Fine, but it changes the struct layout and
  invalidates any `Change` stored in an array.
* `Cow<'a, [u8]>` → a two-variant union or a slice + sentinel. Rust's
  `Cow::Owned` vs `Cow::Borrowed` distinction is observable through `Value::into_owned`
  (`value.rs:182-188`), which returns early without cloning for `Cow::Owned` and clones
  for `Cow::Borrowed`. A slice-only port cannot observe the difference — benign here
  (the only effect is a clone), but it means an `into_owned` that "optimizes"
  differently is not a behaviour change.
* `Pin` does not appear in this slice.

### Hash maps and iteration

* `HashMap<K, V, FxBuildHasher>` → `std.HashMap` / `std.AutoHashMap`.
  `rustc-hash`'s `FxBuildHasher` is a non-DoS-resistant hasher; Zig's default is Wyhash.
  Do not preserve iteration-order expectations from either — the code already avoids
  depending on `HashMap` order (authors are in a sorted `Vec` with `binary_search`).
* `BTreeMap<SmolStr, ScalarValue>` (`marks.rs:107`) → `std.StringHashMap` loses the
  sorted-iteration guarantee that `MarkSet::iter` and `Authors` rely on (`marks.rs:136`,
  `author.rs:126`). Use `std.ArrayHashMap` with an explicit sort at the iteration site,
  or a sorted-array map. `MarkSet::iter` yielding sorted-by-name is *observable* in
  patch output ordering.
* `HashSet<ChangeHash>` (`automerge.rs:254 deps`) → `std.AutoHashMap([32]u8, void)`.
  `get_heads` sorts afterwards (`automerge.rs:1506-1510`), so this is safe.
* `impl Iterator` → a Zig iterator struct with `next(self: *T) ?Item`. The `Iterator`
  return types must be named concrete types (Zig has no `impl Trait` in return
  position, and opaque return types cannot be stored — `AutoCommit::sync() -> impl
  SyncDoc + '_` gets away with it only because callers cannot name it).
* `TinyVec<[u8; 16]>` → a union of `[16]u8` + `len: u8` and `[]u8`, or a fixed
  `[16]u8` + length with heap spill. `ActorId`'s inline/heap split
  (`types.rs:113-156`) is a memory optimization, not semantics; a slice + arena is fine.
* `SmolStr` → `[]const u8` (arena) or a port of `smol_str`. `Mark.name`,
  `ScalarValue::Str`, and `MarkData.name` all use it.

### `Arc` / `Rc` / interior mutability

* `Arc<MarkSet>` (used by `Mark::into_mark_set`, `MarkSet::from_query_state` →
  `Option<Arc<Self>>`) is a plain reference-counted shared value with no `Mutex`. Zig's
  direct equivalent is a manual refcount (`*MarkSet` + `refs: usize`, or an atomic
  counter if cross-thread). It is used only to avoid cloning a `BTreeMap` per
  `PatchAction::SpliceText` (`patches/patch.rs:56`); an owned value inside the patch is
  acceptable if the patch is cloned less often.
* `MarkStateMachine.current: Arc<MarkSet>` with `Arc::make_mut` for copy-on-write
  (`marks.rs:229-281`) is **interior mutability via COW**, and `process`/`mark_begin`
  take `&mut self` (`marks.rs:229`, `257`). Map to a value field + an explicit
  `ensureUnique` helper; the COW trigger condition (`mark.value != below.value`,
  `marks.rs:275`) is a *semantic* condition, not just a perf one, and must be preserved.
* No `Rc`, no `Cell`, no `RefCell`, no `Mutex` in this slice.

### Generics with trait bounds — where Zig has no equivalent

* `O: AsRef<ExId>` is the pervasive pattern: 25 of the 30 `ReadDoc` methods and 15 of
  the 21 `Transactable` methods take it (`read.rs:32-305`,
  `transactable.rs:24-196`). It exists so callers can pass `&ExId`, `ExId`, or `ROOT`
  (a `const`) interchangeably. In Zig: pass `ExId` **by value** everywhere. At ~48 bytes
  this is a worse ABI than Rust's flexibility but is correct, and it removes 40 generic
  parameters. This is the cleanest large simplification available and should be taken.
* `P: Into<Prop>` — the same, plus the coercions `&str → Prop::Map` (allocates a
  `String`), `usize → Prop::Seq`, and **`f64 → Prop::Seq(index as usize)`**
  (`types.rs:338-379`). Taking `Prop` by value forces the caller to build it, which
  makes the silent `f64` truncation visible at the call site — a behavioural
  improvement.
* `V: Into<ScalarValue>` — 11 `From` impls (`value.rs:819-887`). Zig has no implicit
  conversion, so the port must provide either 11 named constructors or a
  comptime-dispatched `fn toScalar(comptime V: type, v: V) ScalarValue` that does the
  same job at zero runtime cost and reproduces the `From<()>` → `Null` and
  `From<char>` → `Str` cases.
* `I: IntoIterator<Item = Change>` (four `apply_changes`/`merge`/`bundle`/
  `bundle_fragments` overloads) → pass a concrete `[]const Change` plus a `total: usize`
  header, matching the existing `StoredChange` design. Note `apply_changes` requires
  `IntoIterator + Clone` (`automerge.rs:1097`), i.e. **two passes over the input**; a
  slice port must keep that (it is used for retry after partial application).
* `R: RangeBounds<String>` / `R: RangeBounds<usize>` (`read.rs:79-121`) — Rust
  `RangeBounds` is implemented by `Range`, `RangeFrom`, `RangeTo`, `RangeFull`,
  `RangeInclusive`, `RangeToInclusive`. Zig's `std.BoundedRange(T)` covers all six: a
  direct swap.
* `C: FnOnce(&O) -> CommitOptions` (`automerge.rs:594-601`, `643-652`) → a
  `*const fn (*const O) CommitOptions` function-pointer parameter.
* `impl Display` → `pub fn format(self, writer: *std.io.Writer) std.io.Writer.Error!void`.
  Every `Display` here is trivial except `PatchAction::Display`, which is literally
  `Debug` (`patches/patch.rs:88`) — and Zig has no stdlib equivalent of
  `std.debug.format`. **This is a real gap**: `PatchAction` has 9 variants with
  structured payloads. Options: hand-write 9 format functions, or emit JSON via
  `std.json` (which changes the output format, a visible API change).
* `rand::distr::Distribution<ActorId>` (`types.rs:60-61`) and the `make_rng` test
  helper (`lib.rs:322-333`) → `std.Random.DefaultPrng`.
* **serde derive surface**: `ObjType` (`types.rs:170`), `ScalarValue`
  `#[serde(untagged)]` (`value.rs:518`), `Counter` (`value.rs:459-468`), `DataType`
  (`value.rs:429`), `ExId` (hand-written, serializes as a string, `exid.rs:156-161`),
  `legacy::Change` (`legacy/mod.rs:327`), `AutoSerde` (`autoserde.rs:30`). Zig 0.16 has
  `std.json` with `jsonSerialize`/`jsonParse` methods but **no derive and no
  untagged-enum support**. `ScalarValue`'s `untagged` + `Counter`-as-i64 means the wire
  shape is a *bare JSON number with no type tag* — the reader must guess from the value,
  which is why `DataType` exists internally (`value.rs:616-618`). Reproducing untagged
  serde in Zig is a substantial separate project; the honest scope call is explicit
  `toJson`/`fromJson` for `Value`/`ScalarValue`, and accepting that `AutoSerde`'s output
  cannot be reproduced byte-for-byte without it.

### `unsafe`

* The only `unsafe`-adjacent code in this slice is the `// SAFETY:` comment in
  `Change::bytes` (`change.rs:111-112`), where `unreachable!()` is justified by the
  match on `self.compression` having just been mutated. The invariant is: *after* the
  `if let CompressionState::NotCompressed` block, `self.compression` is never
  `NotCompressed` (`change.rs:102-116`). A Zig port expresses this with the `switch` arm
  being unreachable and needs **no `unsafe` at all** — the borrow-checker complaint that
  necessitated the SAFETY comment (mutating `self.compression` then matching on
  `&self.compression`) does not arise if the cache is computed and stored in one
  expression.
* `Clock::covers` / `counter_of` / `set_counter_of` index `self.0[actor]` with no bounds
  check (`clock.rs:113-132`). In Zig these are `self.v[actor]`, which is UB on
  out-of-range even in safe builds. **These three functions must either be
  `std.debug.assert`-guarded or document the precondition**, and every caller must be
  audited: the contract (`clock.rs:105-112`) says the actor must already exist in the
  clock. A Zig port that silently trusts this corrupts memory instead of panicking.
* `SeqClock::covers` `assert_eq!`s the two lengths (`clock.rs:65`) — a
  `std.debug.assert` in Zig, which is a no-op in `ReleaseFast`. If that check is
  load-bearing it must become a real `error`.

### What has no clean Zig equivalent in this slice

1. **Trait objects with generic methods.** `AutoSerde<'a, R: crate::ReadDoc>`
   (`autoserde.rs:22`) and `impl<'a, R: ReadDoc> From<&'a R> for AutoSerde<'a, R>`
   (`autoserde.rs:24`) are a generic wrapper over a trait. Zig:
   `fn AutoSerde(comptime R: type) type`, and the *`impl From`* becomes
   `pub fn init(self: *const R) @This()` — a method where Rust has a trait impl.
2. **`Transactable: ReadDoc` supertrait.** No Zig analogue; must be re-declared.
3. **`impl Trait` in argument position.** `AutomergeError::encoding(impl Display)`
   (`error.rs:82`) takes `impl Display` — Zig needs a generic
   `fn encoding(comptime T: type, v: T) AutomergeError`.
   `OpSet::save_checkpoint` returns `HashMap<&'static str, Vec<u8>>`
   (`automerge.rs:580`, `#[cfg(test)]`).
4. **`dyn` + associated types.** `AutomergeError::Unbundle(Box<dyn std::error::Error +
   Send + Sync + 'static>)` (`error.rs:78`), `LoadError::Parse(Box<dyn …>)`
   (`change.rs:170`), `decoding::Error::Io(io::Error)`. Zig's `anyerror` is closest but
   erases the payload, so `AutomergeError::Parse(Box<…>)` becomes a tag-only
   `AutomergeError.parse` plus a separately-returned `anyerror`. `AutomergeError` then
   loses `Send`/`Sync` entirely (trivially so), which is fine, but the *information* is
   lost.
5. **Macros that expand into public API.** `log!` and `__log!` (`lib.rs:235`, `247`,
   `256`) are `#[macro_export]`ed, so they exist in *user* crates' namespaces and expand
   to `$crate::__log!` and `web_sys::console::log_1` / `println!`. Zig cannot ship a
   macro, only a function. Any downstream crate that wrote `use automerge::log;` breaks
   — unavoidable, but it must be a deliberate documented cutover.
6. **`#[cfg]`-gated surface.** `From<Prop> for JsValue` (`types.rs:766`),
   `From<Value> for JsValue` (`hydrate.rs:329`), `From<AutomergeError> for JsValue`
   (`error.rs:106`), and the `__log!` body (`lib.rs:244-260`) are four *trait
   implementations* that exist or don't. In Zig these become comptime branches, and a
   caller writing `x: anytype` through them gets a different error set per build.
7. **Proc macros / derive macros.** None in this slice. `thiserror` derives on 12+ error
   types (`error.rs:8`, `12`, `113`, `117`, `121`, `131`, `134`, `138`, `142`, `146`,
   `154`, `178`; `change.rs:167`; `exid.rs:79`; `decoding.rs:10`, `102`;
   `text_value.rs:271`; `anonymize.rs:11`) generate the `Display` strings, `Error::source`
   and `From` conversions. **Every one of those message strings is part of the public API
   contract** and must be transcribed by hand. There is no `thiserror` equivalent.
8. **`unsafe impl` marker traits.** None in this slice. `AutoCommit: Send` is asserted
   only in a test (`autocomge.rs:1378-1383` → `autocommit.rs:1378-1383`) — there is no
   `unsafe impl Send`. In Zig this becomes a design decision, not a mechanical
   translation.
9. **`Send`/`Sync` bounds.** `AutomergeError` carries `Box<dyn Error + Send + Sync>`
   (`error.rs:78`), `LoadError::Parse` too (`change.rs:170`), and `storage::load::Error`
   is built entirely from `Box<dyn Error + Send + Sync>` (`storage/load.rs:31-42`).
   These bounds exist so the error types cross threads. Zig's `anyerror` is `Send` by
   construction, so the bounds vanish and the *reason* they existed (threading) must be
   checked elsewhere: does the port intend `Automerge` to be shareable across threads?
   The Rust crate's answer is implied by `OpSet`/`ChangeGraph` internals, out of this
   slice.
10. **`no_std`.** The crate is `std`-only and pervasive: `Box<dyn Error>`,
    `std::io::Error`, `getrandom`, `String`/`Vec`, `println!`. There is no `no_std`
    configuration and none should be invented. The Zig equivalent question — is
    `Automerge` usable in a freestanding/wasm build with no OS? — is a *new* design
    decision. The only genuinely OS-free parts of this slice are `exid.rs`, `types.rs`,
    `value.rs`, `clock.rs` and `convert.rs`; `change.rs` needs `sha2`/`flate2` and
    `decoding.rs` needs `std.io`. The crate already supports a wasm target
    (`Cargo.toml:12`, `lib.rs:244`).
11. **Allocator-generic (`impl Allocator`) plumbing.** The Rust code hardcodes the
    global allocator throughout. A Zig port must decide whether to thread
    `std.mem.Allocator` through the ~40 public signatures here (all of which return
    `Vec<u8>`, `String`, `Vec<Change>`, `Vec<Patch>`, `Vec<ChangeHash>`,
    `Vec<(Value, ExId)>`) or use the page allocator. Threading it is a large but
    mechanical diff; not threading it is a real limitation for embedders.
    **Recommend threading it from the start** — retrofitting an allocator parameter
    through 40 public signatures is far more expensive than adding it.
12. **`serde` derive surface** — covered in item 7 and the mapping section above.

---

## Risk

### Highest-risk findings

1. **`ExId` field order is inverted between the wire format and the enum, and
   equality/hash ignore the actor-index field.** Evidence:
   `op_set2/op_set.rs:1054-1059` (produces `(counter, ActorId, actor_index)`) vs
   `exid.rs:46-66` and `exid.rs:107-111` (serialize actor-index then counter);
   `exid.rs:130-139` and `exid.rs:145-154` (ignore field 2). A port that "cleans up" the
   naming by treating field 0 as the actor index — exactly what `to_bytes`'s local
   variables say — will produce documents that load with a swapped actor index. A port
   that also "fixes" `PartialEq` to include field 2 changes hash bucketing and could
   invalidate the round-trip proptest. **Both hazards are invisible at the type level**
   and only manifest as documents that merge incorrectly.
2. **`ScalarValue::Counter` equality ignores `start`** (`value.rs:539-544`), and
   `AutomergeError` / `decoding::Error` equality are deliberately weakened
   (`error.rs:100-104`, `decoding.rs:91-95`). These are the classic places a Zig port
   writes the obvious derived `eql` and silently changes observable behaviour:
   `ScalarValue` equality feeds `get_all` conflict detection, patch comparison and
   `MarkSet` comparison. There is no compiler error and no test failure unless a test
   happens to compare counters with different `start`s.
3. **`Clock`/`SeqClock` panic-or-UB on out-of-range actor indices** (`clock.rs:113-132`,
   `clock.rs:65`) and in a non-test build have **no constructor at all**
   (`clock.rs:155-181`). A Zig port that adds a constructor is *forced* to decide the
   semantics Rust hides in `#[cfg(test)]`, and an incorrect decision about
   `include`/`covers` corrupts visibility filtering for every `*_at` read.

### Medium-risk

4. **The "heads are current ⟹ unscoped read" shortcut is unsound with a transaction in
   flight** and is compensated for in two separate places with different code
   (`transaction/manual_transaction.rs:102-110`, `autocommit.rs:794-814`). A port that
   unifies the two `get_scope` implementations is very likely to drop the
   in-flight-transaction condition and expose uncommitted operations.
5. **`Parents` iterates in reverse** (`op_set2/parents.rs:5-14`); `path()` and
   `visible_path()` reverse it back. A port that "fixes" the iterator to forward order
   breaks both accessors (double reversal) — or, if only one is fixed, silently returns
   the wrong path. The doc comment states it, and the test at
   `op_set2/parents.rs:100-133` itself reverses before comparing, which makes the
   convention easy to miss.
6. **Nine `impl Display` impls carry hand-written message strings, and 12+ `thiserror`
   derives carry more.** The `AutomergeError` message table (`error.rs:13-79`) is 30
   user-visible strings. `PatchAction::Display` is `Debug` (`patches/patch.rs:88`),
   which Zig has no stdlib equivalent for. Nothing in the type system ties these to the
   variants; only review ties them.
7. **`MarkSet` ordered iteration is observable** (`marks.rs:106-108`, `136-138`) and
   `Authors` uses a sorted `Vec` + `binary_search` with index fixups on insert
   (`author.rs:126-137`). Replacing either with a `StringHashMap` breaks patch ordering
   and author lookup.
8. **The COW in `MarkStateMachine`** (`marks.rs:229-281`) couples the `Arc::make_mut`
   call to the semantic condition "the new mark value differs from the mark below it".
   Separating the two gives wrong mark state, not just wrong performance.
9. **The `storage`/`hexane` boundary.** `Change` stores a `storage::Change<'static,
   Verified>` (`change.rs:15`) — another crate's type in a public struct's private
   field. `Action`, `ActorIdx` and `MarkData` implement `hexane::ColumnValue` /
   `RleValue` (`op_set2/types.rs:717-746`). A port that models the value model without
   modelling the columnar encoding needs a second, separate design for the storage
   layer; the two are coupled through `DataType` (`value.rs:430`) and
   `ScalarValue::as_datatype` (`value.rs:543`).

### Unverifiable without running the code

* Whether the round-trip proptest (`exid.rs:222-229`) actually exercises the third
  field. It constructs `ExId::Id(idx as u64, actor, counter)` and asserts
  `objid == objid2`; since `PartialEq` ignores the third field, the test would pass even
  if the counter were corrupted. Verifying this means adding a test that compares
  `to_bytes()` output or all three fields.
* Whether any reachable code path produces an `ExId` with a *stale* actor index (which
  would make the weakened `PartialEq` observable). `Automerge::exid_to_opid`
  (`automerge.rs:744-757`) is written to *tolerate* it: it tries the cached index, then
  falls back to `lookup_actor`, then errors. The fallback's existence is strong evidence
  that stale indices do occur — but nothing in this slice produces them.
* Whether `f64 → Prop` (`types.rs:373-377`) is reachable from any public entry point.
  No non-test caller appears in the covered files.
* The `PartialOrd for Clock` implementation is test-only (`clock.rs:170-180`) and is a
  *partial* order (returns `None` for concurrent clocks, `clock.rs:171-179`). Since
  production code cannot construct a `Clock`, this ordering is never used in production
  — but `Diff`-based iteration and `PatchLog` path hints may rely on the conceptual
  partial order. Whether any production path *wants* a partial order is not answerable
  from this slice.

### Port decisions that must be made, not derived

* Whether to thread `std.mem.Allocator` through the ~40 allocating public signatures
  (Zig note 11). This is the largest single mechanical decision and is much cheaper to
  make at the start.
* Whether to reproduce serde's `untagged` output for `Value`/`ScalarValue`/`ObjType` at
  all, given no derive and no untagged support in `std.json`. A counter is
  indistinguishable from an int in the Rust output (`value.rs:460-468`), so a faithful
  port is lossy in the same way the original is — but only if the untagged writer is
  hand-built.
* Whether to delete the 13 `#[deprecated]` methods (recommended) or keep them
  unannotated. There is no middle option in Zig.
* Whether collapsing `O: AsRef<ExId>` to pass-by-value is acceptable given `ExId`'s size
  (~48 bytes on the stack).
* Whether `Clock`/`SeqClock` should be dense arrays (as today) or a sparse/interval
  representation. A dense `Vec<u32>` is O(actors) per clock and the change graph caches
  one per node (`change_graph.rs:43`); this may be the dominant memory cost in a port and
  is worth a deliberate decision rather than a transliteration.