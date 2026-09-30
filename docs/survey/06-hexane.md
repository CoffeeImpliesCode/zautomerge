# Slice 6 — `hexane`: the columnar storage engine

## Scope

Reference checkout: `~/projects/github-automerge-automerge`, commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, crate root `rust/hexane/`
(`hexane` v1.0.0-alpha.5, edition 2021, MSRV `rust-version = "1.90.0"` in
`Cargo.toml:7`; the README claims MSRV 1.80 — `Cargo.toml:7` is authoritative).

### Library source (line counts)

| Path | Lines |
|---|---|
| `src/lib.rs` | 770 |
| `src/error.rs` | 24 |
| `src/codec.rs` | 451 |
| `src/load_opts.rs` | 98 |
| `src/column.rs` | 2583 |
| `src/encoding.rs` | 377 |
| `src/index.rs` | 153 |
| `src/btree.rs` | 2459 |
| `src/bool.rs` | 2058 |
| `src/encoder.rs` | 1204 |
| `src/edit.rs` | 626 |
| `src/prefix.rs` | 1388 |
| `src/raw.rs` | 1278 |
| `src/shift.rs` | 294 |
| `src/rle/mod.rs` | 237 |
| `src/rle/decoder.rs` | 608 |
| `src/rle/load.rs` | 630 |
| `src/rle/state.rs` | 860 |
| `src/rle/splice.rs` | 1115 |
| `src/rle/writer.rs` | 229 |
| `src/rle/edit.rs` | 395 |
| `src/rle/tests.rs` | 100 |
| `src/delta/mod.rs` | 3576 |
| `src/delta/decoder.rs` | 150 |
| `src/delta/indexed.rs` | 490 |
| **library total** | **22 153** |

Test-only (not compiled into the lib): `src/tests.rs` (5770), `src/splice_fuzz.rs` (583),
`src/edit_fuzz.rs` (1177), `tests/pending.rs` (145).

Benches: `benches/column_ops.rs` (1379), `benches/max_segments.rs` (530),
`benches/btree_b_sweep.rs` (224), `benches/column_u64_mutations.rs` (150),
`benches/remap.rs` (118), `benches/profile_str_splice.rs` (97), `benches/load.rs` (77),
`benches/seek_to_value.rs` (63), `benches/profile_bool_replace.rs` (52).
Example: `examples/column_splice_profile.rs` (146).
Docs: `README.md` (~300, included as crate docs via `#![doc = include_str!("../README.md")]`,
`src/lib.rs:1`), `CHANGELOG.md` (~110), `V1_MIGRATION.md` (361), `TODO` (12).
`proptest-regressions/tests.txt`, `.gitignore`.

Dev-dependencies: `proptest 1.7` (default-features off, `std`), `rand 0.10`, `divan 0.1.15`.
Runtime deps: `leb128 ^0.2.5`, `thiserror ^2.0.12`, optional `bijoux ^0.3.1`
(features `u64`,`i64`), optional `web-sys ^0.3.55` (feature `console`). All from
`Cargo.toml:23-41`.

### Dependency relationship with `rust/automerge`

`rust/automerge` depends on `hexane`; the arrow does not exist in the other direction.

```toml
# rust/automerge/Cargo.toml:26
hexane = { version = "1.0.0-alpha.5", path = "../hexane" }
```

Feature wiring (`rust/automerge/Cargo.toml:12,17`):

```toml
wasm = [..., "hexane/wasm"]
slow_path_assertions = ["hexane/slow_path_assertions"]
```

`hexane` is a workspace member (`rust/Cargo.toml:10`).

How it is used, by call site:

- **Column types in the op-set**: `src/op_set2/columns.rs:18-33` declares
  `Columns { id_actor: Column<ActorIdx>, id_ctr: DeltaColumn<u32>, obj_actor:
  Column<Option<ActorIdx>>, obj_ctr: Column<Option<u32>>, key_actor:
  Column<Option<ActorIdx>>, key_ctr: DeltaColumn<Option<u32>>, key_str:
  Column<Option<String>>, succ_count: PrefixColumn<u32>, succ_actor:
  Column<ActorIdx>, succ_ctr: DeltaColumn<u32>, insert: PrefixColumn<bool>,
  action: Column<Action>, value_meta: PrefixColumn<ValueMeta>, value:
  RawColumn, mark_name: Column<Option<String>>, expand: Column<bool> }` and
  `Indexes { text: PrefixColumn<Option<u32>>, top: PrefixColumn<bool>,
  visible: Column<bool>, … }` (`src/op_set2/op_set/index.rs:150-156`). There is
  no `src/op_set2/index.rs`; the earlier path here was wrong.
- **Value types implemented against hexane's traits** (this is the *only* way
  automerge extends hexane — there is no plugin API):
  `hexane::ColumnValue` + `hexane::RleValue` for `ActorIdx` and `Action`
  (`src/types.rs:717-745`), for `ValueMeta` (`src/op_set2/meta.rs:101-114`),
  for `MarkIdx` (`src/op_set2/mark_index.rs:64-78`); `hexane::PrefixValue` for
  `ValueMeta` (`src/op_set2/meta.rs:116-123`).
- **Encoders** in the change/bundle write paths:
  `src/op_set2/change.rs:200-243` (`Encoder::<…>::encode_to` / `encode_to_unless`),
  `src/storage/bundle/builder.rs:254-262,332-340`,
  `src/change/collector.rs:344-357` (`ProgressiveEncoder`).
- **Decoders/streaming** at load: `src/change_graph.rs:944-961`
  (`hexane::decoder::<ActorIdx>`, `hexane::DeltaDecoder::<u32>::new`,
  `hexane::LoadOpts::new().with_length(len)`, `load_with(..., opts.with_fill(…))`),
  `src/storage.rs:145-148`.
- **Iterators and suspended iterators** (op iteration state):
  `src/op_set2/op_iter.rs:268-500` (`hexane::Iter`, `hexane::DeltaIter`,
  `hexane::PrefixIter`, `hexane::IterState`, `hexane::DeltaIterState`,
  `hexane::FindByRange`), `src/op_set2/op.rs:848-851`,
  `src/iter/tools.rs:311-321`, `src/iter/map_range.rs:109-110`,
  `src/op_set2/top_op.rs:272-274`.
- **Errors** are absorbed at the boundary:
  `#[from] hexane::PackError` (`src/storage/error.rs:28`),
  `use hexane::PackError` (`src/op_set2/op_set.rs:22`, `src/op_set2/columns.rs:10`,
  `src/op_set2/mark_index.rs:3`, `src/storage/document.rs:1`).
- **Sizes**: `hexane::{lebsize, ulebsize}` (`src/op_set2/meta.rs:2`).

Nothing in `hexane` references `automerge`.

---

## Surface

### Feature gates (`Cargo.toml:15-21`)

| Feature | Default | Effect |
|---|---|---|
| `wasm` | off | pulls optional `web-sys`; selects `web_sys::console::log_1` for the `log!` macro under `target_family = "wasm"` (`src/lib.rs:16-21`), `println!` otherwise (`src/lib.rs:23-27`) |
| `slow_path_assertions` | off | declared empty; automerge forwards it. No `#[cfg(feature = …)]` reads it inside hexane's own sources — the *debug* assertions are gated on `#[cfg(debug_assertions)]` instead (`src/rle/mod.rs:117`, `src/column.rs:1203`, `src/bool.rs:28`). `[INFERENCE]` |
| `deep_fuzz` | off | "Deep/expensive fuzz tests, skipped by default so `cargo test` stays fast" (`Cargo.toml:19-20`). No `#[cfg(feature = "deep_fuzz")]` found in `src/`. `[INFERENCE]` — the flag appears to be dead |
| `bijou64` | off | adds `dep:bijoux`, exports `Bijou64` and the `bijou` alias module |

`#[cfg(test)]` gates (not features): `src/edit_fuzz.rs`, `src/splice_fuzz.rs`,
`src/tests.rs` (`src/lib.rs:32-36,184-186`), `src/rle/tests.rs` (`src/rle/mod.rs:8-9`),
`src/rle/load.rs:321` (its own `mod tests`).
`#[cfg(debug_assertions)]` gates: `validate_rle_slab` (`src/rle/mod.rs:117`),
`validate_slab` (`src/bool.rs:28`), `from_slabs`' re-validation
(`src/column.rs:1203-1213`), the post-splice re-validation in
`splice_slab` (`src/rle/splice.rs:972-978`).

### `src/lib.rs` — the public root

Macros (exported, hidden from docs):

```rust
#[macro_export] macro_rules! log { ($($t:tt)*) => { { use $crate::__log; __log!($($t)*); } } }   // lib.rs:6-14
#[macro_export] macro_rules! __log { … }                                                        // lib.rs:16-27
```

Modules (`src/lib.rs:32-186`):

| Module | Visibility |
|---|---|
| `hexane::edit` | `pub` (`lib.rs:32`) |
| `hexane::leb128` | `pub` (`lib.rs:51-66`) — codec-pinned type aliases |
| `hexane::bijou` | `pub` behind `#[cfg(feature = "bijou64")]` (`lib.rs:84-100`) |
| `hexane::bool` | `pub` (`lib.rs:102`) |
| `hexane::btree` | **`pub(crate)`** (`lib.rs:103`) — *but* `SlabAggregate` is re-exported |
| `hexane::codec` | `pub` (`lib.rs:104`) |
| `hexane::column` | `pub` (`lib.rs:105`) |
| `hexane::delta` | `pub` (`lib.rs:106`); `delta::indexed` is `pub` (`delta/mod.rs:2`) |
| `hexane::encoder` | `pub` (`lib.rs:107`) |
| `hexane::encoding` | `pub` (`lib.rs:108`) |
| `hexane::index` | `#[doc(hidden)] pub` (`lib.rs:109-110`) |
| `hexane::load_opts` | `pub` (`lib.rs:111`) |
| `hexane::prefix` | `pub` (`lib.rs:112`) |
| `hexane::raw` | `pub` (`lib.rs:113`) |
| `hexane::rle` | `pub` (`lib.rs:114`); `rle::edit` is `pub` (`rle/mod.rs:2`) |
| `hexane::shift` | `pub` (`lib.rs:115`) |

Private: `mod error` (`lib.rs:37`, `PackError` re-exported), `mod sealed`
(`lib.rs:176-178`, holds `pub trait Sealed {}` used as a supertrait).

Re-exports (`src/lib.rs:38-186`):

```rust
pub use error::PackError;                              // lib.rs:39
pub use codec::{lebsize, ulebsize, Codec, Leb128, VarBuf};   // lib.rs:41
pub use codec::Bijou64;                                // lib.rs:44 (cfg bijou64)
pub use column::{Column, ColumnLoadIter, Iter, IterState, Runs, Splice};  // lib.rs:139
pub use delta::indexed::FindByRange;                   // lib.rs:140
pub use delta::{DeltaColumn, DeltaDecoder, DeltaEncoder, DeltaIter,
                DeltaIterState, DeltaRun, DeltaRuns, DeltaValue};          // lib.rs:141-143
pub use shift::{Ranges, Shiftable, Unshift};           // lib.rs:144
pub use bool::BoolLoadIter;                            // lib.rs:162
pub use btree::SlabAggregate;                          // lib.rs:163
pub use encoding::{ColumnEncoding, EncoderApi, LoadIterApi, RunDecoder, RunSrc}; // lib.rs:164-167
pub use load_opts::{Fill, LoadOpts, MaybeFill, NoFill};                   // lib.rs:168
pub use prefix::{PrefixColumn, PrefixColumnLoadIter, PrefixIter, PrefixIterState,
                 PrefixValue, PrefixedValue};                               // lib.rs:169-170
pub use raw::{RawColumn, RawColumnIter};                // lib.rs:171
pub use rle::RleLoadIter;                               // lib.rs:172
pub use bool::BoolEncoding;                             // lib.rs:188
pub use rle::RleEncoding;                               // lib.rs:189
```

Free functions and type aliases (`src/lib.rs:146-160`):

```rust
pub type Encoder<'a, T, C = Leb128> =
    <<T as ColumnValueRef>::Encoding<C> as ColumnEncoding>::Encoder<'a>;      // lib.rs:152-153
pub type Decoder<'a, T, C = Leb128> =
    <<T as ColumnValueRef>::Encoding<C> as ColumnEncoding>::Decoder<'a>;      // lib.rs:159-160
pub fn decoder<'a, T: ColumnValueRef>(data: &'a [u8]) -> Decoder<'a, T>;      // lib.rs:149
pub fn decoder_in<'a, T: ColumnValueRef, C: Codec>(data: &'a [u8]) -> Decoder<'a, T, C>; // lib.rs:156
```

Not re-exported but reachable by path: `column::{Slab, TailOf, SlabWeight,
WeightFn, LenWeight, DEFAULT_MAX_SEG}`, `index::{ColumnIndex, BitIndex}`,
`btree::{PrefixAggregate, SlabAgg, SlabBTree, FindByValue, FindByValueRange}`,
`codec::{MAX_VARINT_LEN, VarBufIter}`, `delta::{DeltaInner, IndexedDeltaWeightFn}`,
`delta::indexed::{IndexedDeltaWeightFn}`, `bool::{BoolDecoder, BoolDecoderState, BoolPartition}`,
`rle::{RleDecoder, RleDecoderState, RleTail}`, `rle::edit::RleEdit`,
`prefix::{UnsignedPrefix, PrefixSlabWeight, PrefixWeightFn, PrefixSeek}`,
`encoding::SlabInfo`, `raw::RawColumnIter`, `shift::*`,
`edit::{Edit, SlabEdit, EditSlab}`.

### `src/lib.rs` — core value traits

```rust
pub struct Run<V> { pub count: usize, pub value: V }        // lib.rs:196-201
  // Copy, Clone, Debug, PartialEq, Eq, Default

pub trait ColumnValueRef: 'static + Sized + AsColumnRef<Self> + Debug {  // lib.rs:214
    type Encoding<C: Codec>: ColumnEncoding<Value = Self, Codec = C>
        + crate::edit::SlabEdit<Value = Self>;
    type Get<'a>: Copy + PartialEq + Debug;
    fn to_owned(val: Self::Get<'_>) -> Self;
    fn eq(a: Self::Get<'_>, b: Self::Get<'_>) -> bool;
    fn shorten<'s>(v: &'s Self::Get<'_>) -> Self::Get<'s>;
}

pub trait ColumnValue: Copy + PartialEq + Debug + 'static {                // lib.rs:279
    type Encoding<C: Codec>: ColumnEncoding<Value = Self, Codec = C>
        + crate::edit::SlabEdit<Value = Self>;
}
// blanket: impl<T: ColumnValue> ColumnValueRef for T with Get<'a> = T   (lib.rs:300-315)

pub trait RleValue: ColumnValueRef {                                     // lib.rs:324
    const NULLABLE: bool = false;
    fn is_null(_value: Self::Get<'_>) -> bool { false }
    fn value_len<C: Codec>(data: &[u8]) -> Option<usize>;
    fn try_unpack<C: Codec>(data: &[u8]) -> Result<(usize, Self::Get<'_>), PackError>;
    fn unpack<C: Codec>(data: &[u8]) -> (usize, Self::Get<'_>) { …unwrap() }
    fn get_null<'a>() -> Self::Get<'a> { panic!("unexpected null in non-nullable column") }
    fn pack<C: Codec>(value: Self::Get<'_>, out: &mut Vec<u8>) -> bool;
}

pub trait AsColumnRef<T: ColumnValueRef>: Debug + Clone {                  // lib.rs:459
    fn as_column_ref(&self) -> T::Get<'_>;
}
```

`impl` matrix (all in `src/lib.rs`):

- `Option<T>` gets `ColumnValueRef`, `AsColumnRef`, `RleValue` by blanket impl
  over any `T: RleValue` (`lib.rs:381-437`); `NULLABLE = true`,
  `get_null() == None`, `is_null(v) = v.is_none()`, `pack(None) == false`
  (writes nothing).
- `ColumnValue for` / `RleValue for`: `u64` (566-581), `i64` (583-595), `u32` (597-611),
  `i32` (613-626), `usize` (628-642), `std::num::NonZeroU32` (644-660),
  `String` (662-707: `Get<'a> = &'a str`), `Vec<u8>` (709-736: `Get<'a> = &'a [u8]`).
- `ColumnValueRef for bool` with `Encoding<C> = BoolEncoding<C>` (441-455);
  `AsColumnRef<bool> for bool` (457-462).
- `AsColumnRef` impls: blanket `T: ColumnValue → T` (462-467), `String→&str` (469),
  `&str→&str` (474), `Option<&str>→Option<&str>` (479), `&str→Option<&str>` (485),
  `Vec<u8>→&[u8]` (490), `&[u8]→&[u8]` (495), `Option<&[u8]>` (500), `&[u8]→Option<&[u8]>` (506).

Value wire formats (all from `src/lib.rs`):

| `T` | payload bytes | `value_len` | notes |
|---|---|---|---|
| `u64` | `C::encode_unsigned(v)` | `C::unsigned_len` | |
| `i64` | `C::encode_signed(v)` | `C::signed_len` | |
| `u32` | `C::encode_unsigned(v as u64)` | `C::unsigned_len` | `try_unpack` range-checks; `value_len` deliberately does not |
| `i32` | `C::encode_signed(v as i64)` | `C::signed_len` | same |
| `usize` | `C::encode_unsigned(v as u64)` | `C::unsigned_len` | same |
| `NonZeroU32` | `C::encode_unsigned(v.get() as u64)` | `C::unsigned_len` | `try_unpack` rejects 0 |
| `String` | `C::encode_unsigned(len)` ++ `&str` bytes | via `Vec<u8>` | `unpack` uses `from_utf8_unchecked` (see Risk) |
| `Vec<u8>` | `C::encode_unsigned(len)` ++ bytes | own | |

### `src/codec.rs`

```rust
pub const MAX_VARINT_LEN: usize = 16;                    // codec.rs:20
pub struct VarBuf { buf: [u8; 16], len: u8 }            // codec.rs:24
impl VarBuf {
    pub fn new() -> Self;                                // codec.rs:31
    pub fn push(&mut self, byte: u8);                    // codec.rs:44
    pub fn as_bytes(&self) -> &[u8];                     // codec.rs:50
    pub fn extend_from_slice(&mut self, bytes: &[u8]);   // codec.rs:60
}
// Default (codec.rs:67), Deref<Target=[u8]> (codec.rs:70), Debug (codec.rs:80)
pub struct VarBufIter;                                   // codec.rs:87
// Iterator<Item=u8> (codec.rs:90), ExactSizeIterator (codec.rs:111)
// IntoIterator for VarBuf (codec.rs:113)

pub trait Codec: std::fmt::Debug + 'static {              // codec.rs:139
    fn encode_unsigned(n: u64) -> VarBuf;                                     // :141
    fn encode_signed(n: i64) -> VarBuf;                                       // :144
    fn read_unsigned(data: &[u8]) -> Option<(usize, u64)>;                    // :147
    fn read_signed(data: &[u8]) -> Option<(usize, i64)>;                      // :150
    fn try_read_unsigned(data: &[u8]) -> Result<(usize, u64), PackError>;     // :153
    fn try_read_signed(data: &[u8]) -> Result<(usize, i64), PackError>;       // :156
    fn unsigned_len(data: &[u8]) -> Option<usize> { … }                      // :161
    fn signed_len(data: &[u8]) -> Option<usize> { … }                        // :166
    fn unsigned_size(n: u64) -> u64 { … }                                   // :170
    fn signed_size(n: i64) -> u64 { … }                                     // :175
    fn encode_count(n: usize) -> VarBuf { … }                               // :179
    fn read_count(data: &[u8]) -> Option<(usize, usize)> { … }               // :184
    fn signed_bytes(buf: &[u8], pos: usize) -> Range<usize> { … }           // :189
    fn rewrite_lit_header(buf: &mut Vec<u8>, header_pos: usize,
                          total: usize) -> i64 { … }                         // :194
}

pub struct Leb128;                                       // codec.rs:226
pub struct Bijou64;                                      // codec.rs:360 (cfg bijou64)
pub fn lebsize(val: i64) -> u64 { Leb128::signed_size(val) }   // codec.rs:444
pub fn ulebsize(val: u64) -> u64 { Leb128::unsigned_size(val) } // codec.rs:449
```

`impl Codec for Leb128` at `codec.rs:228-329`. `impl Codec for Bijou64` at
`codec.rs:362-436` (in `mod bijou64_impl`, gated `#[cfg(feature = "bijou64")]`).

### `src/error.rs`

```rust
#[derive(thiserror::Error, Debug)]
pub enum PackError {                                     // error.rs:3
    #[error(transparent)] InvalidNumber(#[from] leb128::read::Error),  // :6-7
    #[error("invalid utf8")]          InvalidUtf8,                      // :9
    #[error("invalid value: {0}")]    InvalidValue(String),             // :11
    #[error("invalid load length len={0}, expected={1}")] InvalidLength(usize, usize), // :14
    #[error("malformed leb encoding")] BadFormat,                       // :16
    #[error("invalid resume")]         InvalidResume,                    // :20
}
```

### `src/load_opts.rs`

```rust
pub struct LoadOpts<F = NoFill> { length: Option<usize>, fill: F, max_segments: usize } // :18
pub struct NoFill;                                       // :26  (Copy, Default)
pub struct Fill<A>(pub(crate) A);                        // :30
pub trait MaybeFill<G> { fn fill_value(self) -> Option<G>; }  // :34
impl LoadOpts<NoFill> { pub fn new() -> Self; }            // :52
impl LoadOpts<NoFill> { pub fn with_fill<A>(self, value: A) -> LoadOpts<Fill<A>>; } // :65
impl<F> LoadOpts<F> { pub fn with_length(mut self, len: usize) -> Self; }  // :88
impl<F> LoadOpts<F> { pub fn with_max_segments(mut self, n: usize) -> Self; } // :94
impl Default for LoadOpts<NoFill>                          // :77
```

### `src/column.rs`

```rust
pub type TailOf<T, C = Leb128> =
    <<T as ColumnValueRef>::Encoding<C> as ColumnEncoding>::Tail;   // column.rs:15
pub const DEFAULT_MAX_SEG: usize = 64;                              // column.rs:21

#[doc(hidden)]
pub struct Slab<Tail: Copy+Clone+Debug+Default = ()> { data: Vec<u8>, len: usize,
                                                     segments: usize, tail: Tail } // column.rs:27
// all fields pub(crate); Slab::new (column.rs:35) is pub(crate)

#[doc(hidden)]
pub trait SlabWeight: Sealed + Clone + Default + Debug + AddAssign + SubAssign { // column.rs:53
    fn len(&self) -> usize;                                         // :55
    fn is_empty(&self) -> bool { self.len() == 0 }                  // :58
}
// impl for usize (column.rs:63-69)

#[doc(hidden)]
pub trait WeightFn<T: ColumnValueRef, C: Codec = Leb128>: Sealed {   // column.rs:81
    type Weight: Clone + Default + Debug + SlabAggregate;            // :95
    fn compute(slab: &Slab<TailOf<T, C>>) -> Self::Weight;           // :96
    const ACCUMULATES: bool = false;                                 // :105
    fn accumulate_run(weight: &mut Self::Weight, count: usize,
                      value: T::Get<'_>) -> Result<(), PackError>;    // :113
}
pub struct LenWeight;  // column.rs:115; Weight = usize, compute = slab.len  (:122-127)

pub(crate) trait ColumnRef<T: ColumnValueRef> {                       // column.rs:327
    fn find_slab(&self, index: usize) -> (usize, usize);
    fn slab_data(&self, index: usize) -> &[u8];
    fn slab_start(&self, index: usize) -> usize;
}

pub struct Iter<'a, T: ColumnValueRef, C: Codec = Leb128>;           // column.rs:359
impl Iter<'_,'_,_> {
    pub fn set_max(&mut self, pos: usize);                            // :510
    pub fn get_slab(&self) -> usize;                                  // :516
    pub fn pos(&self) -> usize;                                       // :522
    pub fn end_pos(&self) -> usize;                                   // :528
    pub fn advance_to(&mut self, target: usize);                      // :531
    pub fn shift(&mut self, range: Range<usize>);                     // :542
    pub fn advance_by(&mut self, amount: usize);                      // :547
    pub fn next_run(&mut self) -> Option<Run<T::Get<'a>>>;            // :555
    pub fn runs(self) -> Runs<'a, T, C>;                              // :561
    pub fn shift_next(&mut self, range: Range<usize>) -> Option<T::Get<'a>>; // :629
    pub fn scan_to_value<'t>(&mut self, target: T::Get<'t>) -> Option<usize>; // :894
    pub fn seek_to_value<'t>(&mut self, target: T::Get<'t>,
                            range: impl RangeBounds<usize>) -> …;     // :913
}
// Iterator (Item = T::Get<'a>, column.rs:391) + next/nth/fold/size_hint (393-465)
// ExactSizeIterator (:471), RunSrc (:475), Debug (:483), Clone (:489), Default (:383)

pub struct Splice { pub pos: usize, pub delete: usize, pub range: Range<usize> } // column.rs:710
// Default: { pos: 0, delete: 0, range: 0..usize::MAX } (column.rs:725)

pub struct Runs<'a, T: ColumnValueRef, C: Codec = Leb128>(pub(crate) Iter<'a, T, C>); // :776
impl Iterator for Runs: Item = Run<T::Get<'a>>                          // :778

pub struct IterState { counter, num_slabs, slab_idx, pos, items_left, slab_consumed } // :792
impl IterState { pub fn try_resume<'a, T, C, WF, Idx>(
        &self, column: &'a Column<T, C, WF, Idx>) -> Result<Iter<'a, T, C>, PackError> } // :807
impl Iter { pub fn suspend(&self) -> IterState }                         // :857

pub struct Column<T: ColumnValueRef, C: Codec = Leb128,
                  WF: WeightFn<T, C> = LenWeight,
                  Idx = SlabBTree<<WF as WeightFn<T, C>>::Weight>>
where Idx: ColumnIndex<WF::Weight>;                                     // column.rs:1022
// fields (all pub(crate)): slabs: Vec<Slab<TailOf<T, C>>>, index: Idx,
//   total_len: usize, max_segments: usize, counter: usize
// Clone (:1044), Debug (:1059), Default (:1075)
```

`impl Column` — constructors and IO:

```rust
pub fn new() -> Self                                                    // :1117
pub fn with_max_segments(max_segments: usize) -> Self                  // :1121
pub fn from_values(values: Vec<T>) -> Self                              // :1137
pub fn from_values_with_max_segments(values: Vec<T>, max_segments: usize) -> Self // :1141
pub fn load(data: &[u8]) -> Result<Self, PackError>                     // :1147
pub fn load_with<'a, F>(data: &'a [u8], opts: LoadOpts<F>) -> Result<Self, PackError>
        where F: MaybeFill<T::Get<'a>>                                   // :1156
pub fn load_iter<'a, F>(data: &'a [u8], opts: LoadOpts<F>)
        -> ColumnLoadIter<'a, T, C, WF, Idx> where F: MaybeFill<T::Get<'a>> // :1173
pub fn fill(len: usize, value: T::Get<'_>) -> Self                       // :1227
```

`impl Column` — reads:

```rust
pub fn len(&self) -> usize                                              // :1247
pub fn is_empty(&self) -> bool                                          // :1251
pub fn slab_count(&self) -> usize                                       // :1255
pub fn get(&self, index: usize) -> Option<T::Get<'_>>                  // :1259
pub fn remap<F: Fn(T) -> T>(&mut self, f: F)                            // :1268
#[doc(hidden)] pub fn check_invariants(&self)                           // :1292
pub fn validate_encoding(&self) -> Result<(), PackError>                // :1348
pub fn save(&self) -> Vec<u8>                                           // :1354
pub fn save_to(&self, out: &mut Vec<u8>) -> Range<usize>                // :1360
pub fn iter(&self) -> Iter<'_, T, C>                                    // :1378
pub fn iter_range(&self, range: Range<usize>) -> Iter<'_, T, C>         // :1384
pub fn to_vec(&self) -> Vec<T::Get<'_>>                                // :1424
pub fn is_only(&self, value: T::Get<'_>) -> bool                         // :1429
pub fn save_to_unless(&self, out: &mut Vec<u8>, value: T::Get<'_>) -> Range<usize> // :1447
pub fn slab_lens(&self) -> Vec<usize>                                   // :1455
pub fn slab_segments(&self) -> Vec<usize>                               // :1459
pub fn dump_slabs(&self)                                                // :1463
pub fn scope_to_value<V: AsColumnRef<T>>(&self, value: V,
        range: impl RangeBounds<usize>) -> …                             // :1495
```

`impl Column` — mutations:

```rust
pub fn insert(&mut self, index: usize, value: impl AsColumnRef<T>)      // :1510
pub fn remove(&mut self, index: usize)                                  // :1514
pub fn remove_n(&mut self, index: usize, n: usize)                      // :1528
pub fn push(&mut self, value: impl AsColumnRef<T>)                      // :1534
pub fn clear(&mut self)                                                 // :1539
pub fn truncate(&mut self, len: usize)                                  // :1546
pub fn splice<V, I>(&mut self, index: usize, del: usize, values: I)
        where V: AsColumnRef<T>, I: IntoIterator<Item = V>               // :1552
pub fn splice_runs<V, I>(&mut self, index: usize, del: usize, runs: I)
        where V: AsColumnRef<T>, I: IntoIterator<Item = Run<V>>           // :1563
pub fn copy_ranges<I>(&mut self, src: Self, splices: I)
        where I: IntoIterator<Item = Splice>, for<'b> T::Get<'b>: AsColumnRef<T> // :1582
pub fn edit(&mut self) -> Edit<'_, T, C, WF, Idx>                        // :2022
pub fn edit_at(&mut self, at: usize) -> Edit<'_, T, C, WF, Idx>          // :2027
```

`pub(crate)` internals worth naming for the port: `splice_inner` (the single write
path, `:1768`), `try_merge` (`:1785`), `try_merge_range` (`:1799`),
`retain_ranges` (`:1739`), `swap_contents` (`:1755`), `from_slabs` (`:1202`),
`copy_splices_with` (`:1598`), `copy_strategy` (`:1645`).
`Column<T, C, WF, SlabBTree<SlabAgg>>` gains `find_by_value(i64) -> FindByValue<'_>`
(`:1815`) and `find_by_value_range(lo, hi) -> FindByValueRange<'_>` (`:1821`).

Module-level helpers (`src/column.rs`): `rebuild_bit` (`:147`), `bit_point_update`
(`:168`), `try_merge_range_skeleton` (`:185`), `normalize_range_max` (`:235`),
`splice_bytes` (`:277`, a memcpy-based `Vec::splice`), `find_slab_bit` (`:301`),
`for_each_gap` (`:1091`), `normalize_ranges` (`:677`), `normalize_splices` (`:731`),
`CopyStrategy::{Direct, Invert}` (`:664`) with `COPY_INVERT_FACTOR = 1` (`:672`).

```rust
pub struct ColumnLoadIter<'a, T, C = Leb128, WF = LenWeight,
        Idx = SlabBTree<<WF as WeightFn<T, C>>::Weight>>;                // :1835
impl ColumnLoadIter {
    pub fn try_next_run(&mut self) -> Result<Option<Run<T::Get<'a>>>, PackError>; // :1872
    pub fn finalize(self) -> Result<Column<T, C, WF, Idx>, PackError>;    // :1912
}
```

`FromIterator<T> for Column<T>` (`:1996`), `Extend<V> for Column` (`:2005`).

### `src/encoding.rs` — the dispatch layer

```rust
pub trait ColumnEncoding: Default {                                     // encoding.rs:15
    type Codec: crate::Codec;                                            // :17
    type Value: ColumnValueRef<Encoding<Self::Codec> = Self>;             // :20
    type Tail: Copy + Clone + Debug + Default;                           // :23
    fn empty_slab() -> Slab<Self::Tail> { Slab::new(vec![], 0, 0) }       // :25
    fn fill(len: usize, value: <Self::Value as ColumnValueRef>::Get<'_>) -> Slab<Self::Tail>; // :31
    fn merge_slabs(a: &mut Slab<Self::Tail>, b: Slab<Self::Tail>);       // :36
    fn validate_encoding(slab: &[u8]) -> Result<SlabInfo<Self::Tail>, PackError>; // :43
    fn do_merge(acc: &mut Vec<u8>, a_tail: Self::Tail, a_segments: usize,
                b: &Slab<Self::Tail>, buf: &mut Vec<u8>)
        -> (usize, Self::Tail);                                          // :50
    fn splice_slab<V: AsColumnRef<Self::Value>>(&mut Slab, index, del,
        values: impl Iterator<Item = (V, usize)>, max_segments: usize)
        -> (Vec<Slab<Self::Tail>>, usize);                                // :59
    fn remap<'a, F, WF, Idx>(iter, max, f: F) -> Column<…> where … ;    // :70 (default)
    fn last_run(slab: &Slab<Self::Tail>) -> Option<Run<…>>;              // :93
    type Decoder<'a>: Iterator<Item = …> + RunDecoder + Clone;           // :97
    fn decoder(slab: &[u8]) -> Self::Decoder<'_>;                        // :100
    type State: Clone;                                                    // :105
    fn state_at(slab: &Slab<Self::Tail>, at: usize) -> Self::State;       // :110
    fn state_peek<'s>(slab: &'s Slab<Self::Tail>, state: &Self::State)
        -> Option<…::Get<'s>>;                                           // :114
    fn state_advance(slab: &Slab<Self::Tail>, state: &mut Self::State, n: usize); // :119
    type Encoder<'a>: EncoderApi<'a, Self::Value, Self::Codec>;           // :123
    fn encoder<'a>() -> Self::Encoder<'a>;                                 // :126
    type LoadIter<'a>: LoadIterApi<'a, Self::Value, Tail = Self::Tail>;   // :130
    fn load_iter(data: &[u8], max_segments: usize) -> Self::LoadIter<'_>; // :133
    fn encode<V: AsColumnRef<Self::Value>>(values: impl Iterator<Item = V>)
        -> Slab<Self::Tail>;                                              // :136
}

pub trait LoadIterApi<'a, T: ColumnValueRef> {                           // :148
    fn try_next_run(&mut self) -> Result<Option<Run<T::Get<'a>>>, PackError>; // :150
    fn slabs_completed(&self) -> usize;                                  // :158
    fn completed_slab_len(&self, i: usize) -> usize;                      // :161
    type Tail: Copy + Clone + Debug + Default;                            // :166
    fn finalize(self) -> Result<Vec<Slab<Self::Tail>>, PackError> where Self: Sized; // :170
}

pub trait RunSrc<'a, T: ColumnValueRef> {                                // :183
    fn try_next_run(&mut self) -> Result<Option<Run<T::Get<'a>>>, PackError>; // :185
}
impl<'a, T, S: RunSrc<'a,T> + ?Sized> RunSrc<'a,T> for &mut S             // :190

pub trait EncoderApi<'a, T: ColumnValueRef, C: Codec = Leb128>: Sized {  // :196
    fn append(&mut self, value: T::Get<'a>);                              // :198
    fn append_owned(&mut self, value: T);                                 // :199
    fn append_n(&mut self, value: T::Get<'a>, n: usize);                  // :200
    fn append_n_owned(&mut self, value: T, n: usize);                     // :201
    fn extend(&mut self, iter: impl IntoIterator<Item = T::Get<'a>>)     // :204
    fn len(&self) -> usize;                                               // :208
    fn is_empty(&self) -> bool                                            // :211
    fn max_segments(&mut self, _max: usize) {}                            // :219
    fn with_max_segments(mut self, max: usize) -> Self                    // :225
    fn with_segments(self) -> Self                                        // :230
    fn into_column<WF, Idx>(self) -> Column<T, C, WF, Idx>                // :239
    fn save(self) -> Vec<u8>;                                             // :244
    fn save_to(self, out: &mut Vec<u8>) -> Range<usize>;                  // :246
    fn save_to_unless(self, out: &mut Vec<u8>, value: T::Get<'a>) -> Range<usize>; // :248
    fn into_slab(self) -> Slab<Self::Tail>;                               // :250
    type Tail: Copy + Clone + Debug + Default;                            // :251
    fn encode(iter) -> Vec<u8> where Self: Default                        // :255
    fn encode_to(buf: &mut Vec<u8>, iter) -> Range<usize>                 // :262
    fn encode_to_unless(buf, iter, value) -> Range<usize>                 // :271
    fn encode_slab(iter) -> Slab<Self::Tail>                               // :309
}

pub trait RunDecoder: Iterator {                                         // :315
    fn next_run(&mut self) -> Option<Run<Self::Item>>;                    // :322
    fn next_run_max(&mut self, max: usize) -> Option<Run<Self::Item>>;    // :328
    fn advance_by(&mut self, n: usize)                                    // :333
    fn scan_for(&mut self, target: Self::Item, max: usize) -> (usize, usize)
        where Self::Item: Ord;                                            // :345
}

pub struct SlabInfo<T> { pub segments: usize, pub len: usize, pub tail: T } // :370
```

### `src/index.rs`

```rust
pub trait ColumnIndex<W>: Sealed + Default {                             // index.rs:27
    fn from_weights<I: IntoIterator<Item = W>>(iter: I) -> Self;          // :29
    fn len(&self) -> usize;                                               // :31
    fn is_empty(&self) -> bool                                            // :33
    fn find_slab(&self, index: usize) -> (usize, usize);                  // :38
    fn items_before(&self, slab_idx: usize) -> usize;                     // :44
    fn update_slab(&mut self, slab_idx: usize, new_weight: W);            // :48
    fn splice<I: IntoIterator<Item = W>>(&mut self, range: Range<usize>, new_weights: I); // :52
}

pub struct BitIndex<W: SlabWeight> { weights: Vec<W>, bit: Vec<W> }       // index.rs:67
// ColumnIndex impl (:77-125); items_before uses a standard BIT prefix query
// over the `len` component only (:96-106)
```
`impl ColumnIndex for SlabBTree<A: SlabAggregate>` at `index.rs:126-152`;
`impl Sealed for BitIndex` (`:75`) and `for SlabBTree` (`:126`).

### `src/btree.rs` — the slab index

`pub(crate) mod btree` (`lib.rs:103`), but `SlabAggregate` is re-exported
(`lib.rs:163`) and appears in `PrefixSlabWeight`'s bounds, so it is
nameable from outside. Everything else is crate-internal except the two
`pub` cursor types that leak through `pub(crate)` types.

```rust
const B: usize = 64;                                                     // btree.rs:32

pub trait SlabAggregate: Clone + Default + Debug {                        // btree.rs:47
    fn merge(l: &Self, r: &Self) -> Self;                                 // :49
    fn len(&self) -> usize;                                               // :52
}
pub trait PrefixAggregate: SlabAggregate {                                // btree.rs:63
    type Prefix: Clone + Default + Add<Output = Self::Prefix> + Debug
               + for<'a> AddAssign<&'a Self::Prefix>;                      // :74
    fn prefix(&self) -> &Self::Prefix;                                    // :85
}

pub struct SlabAgg { pub len: usize, pub total: i64,
                     pub min_offset: i64, pub max_offset: i64 }           // btree.rs:102
// SlabAggregate (:109), PrefixAggregate with Prefix = i64 (:129)
impl SlabAgg { fn contains(&self, target: i64, prefix_before: i64) -> bool }  // :138
             fn overlaps(&self, lo: i64, hi: i64, prefix_before: i64) -> bool } // :144

// SlabAggregate for usize (:153) → Weight = usize for LenWeight.
```

Node layout (private, `src/btree.rs:194-236`):

```rust
type NodeId = u32;                                                       // :194
enum Node<A: SlabAggregate> { Leaf(Leaf<A>), Internal(Internal<A>) }     // :196
struct Leaf<A> { aggs: Vec<A> }                                          // :202
struct Internal<A> { children: Vec<ChildSlot<A>> }                       // :209
struct ChildSlot<A> { id: NodeId, agg: A, slab_count: usize }            // :224

pub struct SlabBTree<A: SlabAggregate> {                                 // :237
    nodes: Vec<Option<Node<A>>>,   // arena; None = on the free list
    free: Vec<NodeId>,
    root: NodeId,
    total_slabs: usize,
    _phantom: PhantomData<A>,
}
```

`pub(crate)` methods: `new` (`:252`), `len` (`:264`), `is_empty` (`:269`, test),
`root_agg` (`:274`), `from_iter` (`:317`), `update_slab` (`:366`),
`splice` (`:412`), `find_by_prefix` (`:1192`), `items_before_slab` (`:1232`),
`check_invariants` (`:1283`), `find_by_value` (`:1366`),
`find_by_value_range` (`:1370`).
`impl<A: PrefixAggregate>` adds `find_slab_at_item(item_idx) -> FoundSlab<A>`
(`:1563`) and, under `A::Prefix: Ord`, `find_slab_at_prefix(target) -> (usize,
A::Prefix, usize)` (`:1628`).
`FoundSlab<A> { index, prefix, pos }` (`:1541`, `pub(crate)`).

Private helpers: `alloc` (`:283`), `free` (`:294`), `node`/`node_mut` (`:299,303`),
`agg_of` (`:308`), `overwrite_range` (`:442`), `splice_structural` (`:473`),
`splice_via_lca` (`:490`), `free_subtree` (`:635`), `remove_and_cascade` (`:657`),
`collapse_root` (`:690`), `maybe_merge_leaf` (`:710`), `subtree_height` (`:761`),
`build_children_at_height` (`:774`), `make_fresh_leaves` (`:806`),
`split_and_propagate` (`:834`), `splice_into_empty` (`:879`),
`try_single_leaf_splice` (`:905`), `locate_leaf_for_start` (`:975`),
`update_ancestor_aggregates` (`:1014`), `make_leaves_from_aggs` (`:1030`),
`propagate_splits` (`:1072`), `internal_summary` (`:1154`), `slab_count_of` (`:1165`),
`collect_into` (`:1172`), `check_node` (`:1314`).
Free function `merge_all` (`:88`).

Cursors (public types, but the module is `pub(crate)`):

```rust
pub struct FindByValue<'a> { tree: &'a SlabBTree<SlabAgg>, target: i64, stack: Vec<Frame> }  // :1375
// Iterator<Item = (usize /*slab_idx*/, usize /*items_before*/, i64 /*prefix_before*/)> (:1411)
pub struct FindByValueRange<'a> { tree, lo: i64, hi: i64, stack: Vec<Frame> }               // :1460
// Iterator with the same Item type (:1490)
struct Frame { node: NodeId, next_child: usize, prefix_before: i64,
               slab_base: usize, items_before: usize }                                     // :1384
```

### `src/rle/` — the RLE encoding

Module wiring (`src/rle/mod.rs:1-9`): `mod decoder; pub mod edit; mod load;
pub(crate) mod writer; pub(crate) mod splice; pub(crate) mod state;
#[cfg(test)] mod tests;`. Re-exports `load::RleLoadIter` (`:5`) and
`decoder::RleDecoder` (`:11`).

Wire format, verbatim from the source comment (`src/rle/mod.rs:25-33`):

```text
// Repeat run : signed_leb128( count > 0 )  packed_value
// Literal run: signed_leb128( -n      )    v0 v1 … v(n-1)
// Null run   : signed_leb128( 0       )    unsigned_leb128( count )
```

```rust
pub struct RleEncoding<T: RleValue, C: Codec = Leb128>(PhantomData<fn() -> (T, C)>); // :41
// Default (:43); impl ColumnEncoding (:128-236) with
//   Codec = C, Value = T, Tail = RleTail, State = crate::rle::RleDecoderState

#[doc(hidden)]
pub struct RleTail { pub(crate) bytes: u32,
                     pub(crate) lit_tail: Option<NonZeroU32> }           // rle/mod.rs:93
// Clone, Copy, Debug, Default, PartialEq; with_lit_tail (rle/mod.rs:107)

pub(crate) fn compute_rle_tail<T, C>(data: &[u8]) -> RleTail            // rle/mod.rs:51 (test only)
```

`src/rle/decoder.rs`:

```rust
pub struct RleDecoder<'a, T: RleValue, C: Codec = Leb128>;             // :14
// fields: data: &'a [u8], byte_pos, remaining, state: RunState, run_at, _codec
// Clone (:34), Debug (:43)
enum RunState<'a, T> { Repeat(T::Get<'a>), Literal, Null, Idle }        // :51
pub struct RleDecoderState { byte_pos: usize, remaining: usize, run: SuspendedRun } // :96
enum SuspendedRun { Repeat { at: usize }, Literal, Null, Idle }          // :101
// DecoderState::start (rle/decoder.rs:119), RleDecoder::new (:125),
// suspend (:138), resume (:157), pos (:174), is_literal (:178),
// advance_run (:182), try_next_segment (:227)
impl RleDecoder { pub fn advance_by(&mut self, n: usize) }               // :278
// Iterator (Item = T::Get<'a>, :300) with next (:302) and nth (:326)
pub(crate) enum RleSegment<'a, T: RleValue> {
    Run { count, value, bytes }, Null { count, bytes },
    LitHead { count, bytes }, Lit { value, bytes } }                     // :404
impl RleSegment { pub(crate) fn validate_after(&self, prev: &Option<Self>,
        prev_lit: Option<T::Get<'a>>) -> Result<(), &'static str> }      // :438
impl RunDecoder for RleDecoder { next_run (:479), next_run_max (:482) }  // :479
fn skip_literals(&mut self, n: usize)                                   // :287
```

`src/rle/load.rs`:

```rust
pub(crate) fn rle_validate_encoding<T: RleValue, C: Codec>(slab: &[u8])
        -> Result<SlabInfo<RleTail>, PackError>                          // :15
struct CutState { slabs, slab, start, last_lit_count, lit_count, pending_header } // :106
impl CutState { fn track(...) -> Option<Run<T::Get<'a>>>  }              // :119
               fn cut_slab<C: Codec>(&mut self, input: &[u8], pos) }    // :157
pub struct RleLoadIter<'a, T: RleValue, C: Codec = Leb128>;             // :82
impl RleLoadIter {
    pub fn new(data: &'a [u8], max_segments: usize) -> Self;              // :185  (asserts max >= 2)
    pub fn try_next_run(&mut self) -> Result<Option<Run<T::Get<'a>>>, PackError>; // :203
    pub fn finalize(self) -> Result<Vec<Slab>, PackError>;                 // :231
}
impl LoadIterApi for RleLoadIter                                         // :258
impl Slab { fn copy_from<C: Codec>(&mut self, input: &[u8], pending_header,
        lit_count, last_lit_count) }                                     // :300
```

`src/rle/state.rs` — the canonical-form state machine:

```rust
pub(crate) enum RleCow<'a, T: RleValue, V: AsColumnRef<T>> { Owned(V), Ref(T::Get<'a>) } // :16
impl RleCow { get() (:38), pack<C>(&self, buf) -> usize (:46), is_null() (:56) }  // pub(crate)
pub(crate) struct RewriteHeader { pub count: usize, pub pos: usize }     // :78
pub(crate) struct FlushState { pub segments: usize, pub rewrite: Option<RewriteHeader>,
                               pub wpos: WPos }                          // :90
pub(crate) enum WPos { Run { pos, local }, Lit { pos, bytes, local } }    // :97
impl WPos { merge(prefix, middle, postfix, tail) -> RleTail (:136)
           as_tail(prefix, local) -> RleTail (:152) }
pub(crate) enum RleState<'a, T: RleValue, V: AsColumnRef<T>, C: Codec = Leb128> {  // :225
    Empty(PhantomData<fn() -> C>),
    Lone(RleCow<'a, T, V>),
    Run(usize, RleCow<'a, T, V>),
    Lit { count, local, header_pos, bytes: Option<NonZeroUsize>, current: RleCow },
    Null(usize),
}
pub(crate) enum OwnedPostfix<T> { Run { count, value, segments },
    Lit { value, lit, segments }, LonePlusLit { lone, value, lit, segments } }  // :251
impl RleState {
    pub(crate) fn into_owned(self) -> RleState<'static, T, T, C>          // :297
    pub const fn empty() -> Self                                          // :326
    pub fn pending_segments(&self) -> usize                               // :331
    pub(crate) fn is_single_run_of(&self, value) -> bool                  // :341
    pub fn append(&mut self, buf, value) -> FlushState                     // :352
    pub fn append_n(&mut self, buf, value, n) -> FlushState                // :356
    pub fn lit(count, current, header_pos) -> Self                         // :464
    pub fn make_run(n, value) -> Self                                      // :475
    pub fn flush_postfix(&mut self, buf, postfix) -> (FlushState, usize)  // :479
    pub fn flush_postfix_owned(...) -> (FlushState, usize)                 // :520
    pub fn flush(&mut self, buf) -> FlushState                             // :637
    pub fn do_flush(state, buf) -> FlushState                              // :641
    fn flush_with_lit(&mut self, buf, lit) -> FlushState                   // :601
    fn emit_lit(buf, value) -> (usize, usize)                              // :676
    fn emit_run(buf, count, value) -> WPos                                 // :681
    fn emit_null(buf, count) -> WPos                                       // :693
    fn append_null_n(&mut self, buf, n) -> FlushState                      // (n=0 short-circuit at :360)
}
impl OwnedPostfix<T> { segments() (:272), pending() (:280) }
```

`src/rle/splice.rs`:

```rust
pub(crate) enum Postfix<'a, T: RleValue> { Run { count, value, segments },
    Lit { value, lit, segments }, LonePlusLit { lone, value, lit, segments } } // :20
struct Prefix<'a, T, V, C> { state: RleState, segments: usize, bytes: usize }  // :57
struct RlePartition<'a, T, V, C> { outer: Range<usize>, prefix: Prefix,
    postfix: Option<Postfix>, read_segments: usize,
    read_state: crate::rle::RleDecoderState }                                  // :71
fn find_partition<'a, T, V, C>(slab, range) -> RlePartition   // :83
fn find_partition_inner<...>(slab, range, want_postfix: bool)  // :95
pub(crate) fn postfix_from_run<'a, T, C>(slab, dec, base, …) -> (Postfix, usize) // :227
pub(crate) struct PartitionAt<'a, T, C> { state: RleState, segments, byte_start,
    read_state, read_segments }                                               // :277
pub(crate) fn find_partition_at<T, C>(slab, at) -> PartitionAt   // :292
pub(crate) fn splice_slab<T, V, C>(slab, index, del, values, max_segments) -> Vec<Slab> // :946
fn build_splice_buf<...>(…) -> SpliceBuf                        // :~900
fn head<T, C>(slab) -> (Postfix, usize)                        // :992
pub(crate) fn tail<T, C>(data, tail: RleTail) -> (RleState, usize, usize)  // :1032
pub(crate) fn rle_merge<T, C>(a: &mut Slab, b: &Slab)          // :1075
pub(crate) fn do_merge<T, C>(a: &mut Vec<u8>, a_tail, a_segs, b, buf) -> (usize, RleTail) // :1083
```

`src/rle/writer.rs` (229 lines, entirely `pub(crate)`):

```rust
pub(crate) struct Rebuilt { bytes: Vec<u8>, range: Range<usize>, len: usize, … } // :7
pub(crate) struct SpliceWriter<T: RleValue, C: Codec> {
    state: RleState<'static, T, T, C>, f: FlushState, buf: Vec<u8>, … }          // :17
impl SpliceWriter {
    fn empty() -> Self                                                          // :32
    fn reset(&mut self, state, prefix_segments, …)                             // :48
    fn recycle(&mut self, bytes: Vec<u8>)                                       // :72
    fn push(&mut self, value: impl AsColumnRef<T>, count: usize)                // :79
    fn set_range_end(&mut self, end: usize)                                     // :88
    fn finish(&mut self, postfix: Option<OwnedPostfix<T>>, tail_count, …)       // :117
    fn apply(&mut self, slab: &mut Slab) -> (Vec<Slab>, Vec<u8>)                 // :202
}
```

`src/rle/edit.rs`:

```rust
pub struct RleEdit<T: RleValue, C: Codec> { w: SpliceWriter<T, C>, dec: RleDecoderState,
    read_segments: usize, read: usize, written: usize }                         // :31
// Default (:46), open(slab, at) (:63, test only)
impl RleEdit { fn walk<F>(&mut self, slab, n, emit, budget, f) -> usize  }     // :77
               fn tail<'s>(dec, read_segments, slab) -> (Option<Postfix<'s,T>>, usize) } // :110
impl EditSlab for RleEdit   // reset (:130), pass (:151), insert (:170), delete (:180),
                             // read_state (:188), close (:193)
impl SlabEdit for RleEncoding<T, C> { type Edit = RleEdit<T, C>; }   // :~240
```

### `src/bool.rs` — the boolean encoding

Wire format, verbatim (`src/bool.rs:13-27`):

```text
// Alternating run-length counts, starting with `false`:
//   run0: uleb128  (false count)
//   run1: uleb128  (true count)
//   run2: uleb128  (false count)
// No boolean value is stored — the value is implicit from the run's position
// (even-indexed runs are false, odd-indexed are true).
// An empty slab means an empty column.  An all-true column encodes as [0, N].
```

Confirmed by golden tests: `vec![false; 5]` → `[5]` (`bool.rs:1653`);
`vec![true; 5]` → `[0, 5]` (`bool.rs:1660`); `[t,t,f,t]` → `[0, 2, 1, 1]`
(`bool.rs:1667`).

```rust
type Slab = crate::column::Slab<u8>;                          // bool.rs:5
pub(crate) struct BoolPartition { pub value: bool, pub count: usize,
                                  pub pos: usize, pub segments: usize }   // :43
pub(crate) fn find_partition<C: Codec>(slab, start_index, end_index)
        -> Option<(BoolPartition, BoolPartition)>                            // :159
pub(crate) fn splice_slab<C: Codec>(slab, index, del, values, max_segments) // :233
pub struct BoolDecoder<'a, C: Codec = Leb128> { data, byte_pos, remaining, value, _codec } // :452
#[doc(hidden)] pub struct BoolDecoderState { byte_pos, remaining, value }    // :475
pub struct BoolEncoding<C: Codec = Leb128>(PhantomData<fn() -> C>);         // :625
// ColumnEncoding (:633) with Codec = C, Value = bool, Tail = u8, State = BoolDecoderState
pub struct BoolLoadIter<'a, C: Codec = Leb128> { data, pos, run_index, … }   // :942
impl BoolLoadIter { pub fn new(data, max_segments) -> Self (:957)
                    pub fn try_next_run(&mut self) -> Result<Option<Run<bool>>, PackError> (:988)
                    pub fn finalize(mut self) -> Result<Vec<Slab>, PackError> (:1027) }
fn bool_count_segments<C>(slab: &[u8]) -> usize                             // :758
fn bool_validate_encoding<C>(slab: &[u8]) -> Result<SlabInfo<u8>, PackError> // :784
fn bool_merge_slabs<C>(a_data, a_tail, a_segments, …) -> (usize, u8)        // :841
pub struct BoolEdit<C: Codec = Leb128> { cur_value: bool, cur_count: usize, … } // :1166
struct BoolTail                                                            // :~1095
impl EditSlab for BoolEdit  // reset (:1547), pass (:1551), insert (:1558),
                             // delete (:1562), read_state (:1570), close (:1574)
impl SlabEdit for BoolEncoding<C> { type Edit = BoolEdit<C>; }   // :1538
impl BoolDecoder { pub fn advance_by(&mut self, n: usize) }      // :519
```

### `src/encoder.rs`

```rust
pub struct RleEncoderState<'a, T: RleValue, C: Codec = Leb128> { state, flush, len } // :40
impl RleEncoderState { new (:53), len (:61), is_empty (:65), append (:69),
    append_owned (:74), append_n (:79), append_n_owned (:84), extend (:89),
    finish (:96), is_single_run_of (:107), flush_state (:111) }

pub struct RleEncoder<'a, T: RleValue, C: Codec = Leb128> {
    data: Vec<u8>, state: RleEncoderState<'a,T,C>, slabs: Vec<Slab<RleTail>>,
    max_segments: Option<usize>, len_flushed: usize }                      // :131
impl RleEncoder { new (:159), len (:170), is_empty (:175), append (:235),
    append_owned (:240), append_n (:246), append_n_owned (:252), extend (:257),
    save (:275), save_to (:283), save_to_unless (:319),
    save_to_and_remap<F>(out, f) -> Range<usize> (:329),
    save_to_unless_and_remap<F>(out, unless, f) -> Range<usize> (:345) }
impl EncoderApi for RleEncoder   // :378-497, overriding max_segments, into_column,
                                 // into_slab, encode_to, encode_to_unless

pub struct BoolEncoderState<C: Codec = Leb128> { cur_value, cur_count, segments, len, _codec } // :513
impl BoolEncoderState { new, len, is_empty, append, append_n, extend, flush_run } // :525-590
pub struct BoolEncoder<C: Codec = Leb128>;                                // :~600
```

`Encoder<'a, T, C>` in the public API *is* `RleEncoder` for RLE types and
`BoolEncoder` for `bool`, resolved through `T::Encoding<C>::Encoder<'a>`
(`lib.rs:146-153`).

### `src/prefix.rs`

```rust
pub trait UnsignedPrefix: Copy {}       // prefix.rs:24, impls u32/u64/usize/u128 (:25-28)
pub trait PrefixValue: ColumnValueRef {  // prefix.rs:44
    type Prefix: Default + Clone + Debug + Add<Output=Self::Prefix>
               + Sub<Output=Self::Prefix> + AddAssign + SubAssign
               + for<'a> AddAssign<&'a Self::Prefix>;                       // :55
    fn accumulate(target: &mut Self::Prefix, val: Self::Get<'_>);           // :72
    fn accumulate_run(target: &mut Self::Prefix, run: &Run<Self::Get<'_>>); // :81
    fn slab_sum<C: Codec>(slab: &Slab<TailOf<Self, C>>) -> Self::Prefix;     // :85
    fn partial_sum<C: Codec>(slab, count) -> Self::Prefix;                   // :95
}
pub struct PrefixSlabWeight<P> { len: usize, prefix: P }                     // :160
pub struct PrefixWeightFn<T>(PhantomData<fn() -> T>);                        // :206
pub struct PrefixSeek<'a, T: PrefixValue> { pub pos: usize, pub delta: T::Prefix,
                                             pub pv: PrefixedValue<'a, T> }  // :366
pub struct PrefixColumn<T: PrefixValue, C: Codec = Leb128> { col: Column<T, C, PrefixWeightFn<T>> } // :414
pub struct PrefixedValue<'a, T: PrefixValue> { pub value: T::Get<'a>, total: T::Prefix } // :699
pub struct PrefixIter<'a, T: PrefixValue, C: Codec = Leb128> { col, inner, total, base, … } // :756
pub struct PrefixIterState<T: PrefixValue> { inner: IterState, total, base } // :1024
pub struct PrefixColumnLoadIter<'a, T, C = Leb128>(ColumnLoadIter<…>);     // :1109
fn find_prefix_in_slab<T, C>(slab, target) -> usize                        // :110
```

`PrefixValue` impls: `u64 → u128` (`:239`), `i64 → i128` (`:249`),
`u32 → u64` (`:259`), `NonZeroU32 → u64` (`:269`), blanket
`Option<T> where T: PrefixValue + RleValue` (`:287`), `bool → usize` (`:316`).

`PrefixColumn` methods:

```rust
new (:442), with_max_segments (:446), from_values (:452), load (:458), len (:466),
is_empty (:470), save (:474), slab_count (:478), insert (:484), remove (:488),
remove_n (:495), push (:499), clear (:503), truncate (:507), splice (:511),
splice_runs (:523), copy_ranges (:533), get_prefix (:546), get_total (:553),
delta (:564), sum_range (:573), save_to_unless (:354), load_with (:342),
load_iter (:335), save_to (:629), to_vec (:633), values (:644), from_column (:649),
get (:654), iter (:659), iter_range (:669), edit (:1051), edit_at (:1064)
where T::Prefix: UnsignedPrefix + Div<Output=T::Prefix> + TryInto<usize>
                 + TryFrom<usize> + Ord (:588-626):
    get_index_for_total (:596), get_index_for_prefix (:605)
```

`PrefixedValue`: `total()` = running sum **through** the item inclusive (`:708`);
`prefix()` = sum **before** it (`:715`).
`PrefixIter`: `pos (:862)`, `total (:871)`, `reset_prefix (:884)`, `items_left (:890)`,
`end_pos (:895)`, `set_max (:899)`, `advance_by (:903)`, `suspend (:909)`,
`shift_next (:923)`, `runs (:931)`, `next_run (:937)`, `advance_to (:951)`,
`shift (:962)`, `prefix (:969)`, `delta_nth (:973)`, and `advance_prefix(n: T::Prefix)`
under the unsigned bound (`:997`).

### `src/raw.rs` — the byte arena

```rust
const DEFAULT_MAX_SEGMENTS: usize = 4_096;              // raw.rs:30
struct RawSlab { data: Vec<u8> }                        // :33
pub struct RawColumn { slabs: Vec<RawSlab>, bit: Vec<usize>, total_len: usize,
                       max_segments: usize }             // :41
pub struct RawColumnIter<'a> { slabs, slab_idx, offset_in_slab, pos }  // :592
```

`RawColumn`: `new (:59)`, `with_max_segments (:63)`, `len (:74)`,
`is_empty (:79)`, `splice<I,B> (:93)`, `try_splice<I,B> (:103)`,
`splice_slice (:134)`, `try_splice_slice (:145)`, `copy_ranges<I> (:321)`,
`get (:376)`, `try_get (:382)`, `iter (:410)`, `iter_at (:421)`, `save (:446)`,
`save_to (:452)`, `load (:463)`, `load_with_max_segments (:468)`.
Private: `find_slab (:263)`, `try_merge_pair (:275)`, `chunks_in (:351)`;
free `splice_slab (…) -> (Vec<RawSlab>, usize)` (`:504`), `pick_split` (`:558`).
`RawColumnIter`: `pos (:605)`, plus `take`/`skip`/`seek_to` (used by the module docs).

### `src/shift.rs`

```rust
pub trait Shiftable: Iterator + Debug {                 // shift.rs:19
    fn get_pos(&self) -> usize;                           // :21
    fn get_max(&self) -> usize;                           // :24
    fn set_max(&mut self, pos: usize);                    // :27
    fn get_range(&self) -> Range<usize>;                  // :30
    fn advance_to(&mut self, target: usize);              // :36
    fn advance_by(&mut self, amount: usize);              // :43
    fn shift(&mut self, range: Range<usize>);             // :51
    fn shift_next(&mut self, range: Range<usize>) -> Option<Self::Item>;   // :59
    fn seek_to(&mut self, pos: usize) -> Option<Self::Item>;               // :68
    fn unshift(self) -> Unshift<Self> where Self: Sized;   // :77
    fn ranges<R>(self, ranges: R) -> Ranges<Self, R::IntoIter>
        where R: IntoIterator<Item = Range<usize>>, Self: Sized;           // :87
}
pub struct Ranges<I, R> { iter: I, ranges: R }            // :105  (Iterator, :112)
pub struct Unshift<T: Iterator> { inner: T, next: Option<T::Item> }  // :245
impl Unshift { new (:260), peek (:265) }
impl Unshift<T: Shiftable + Iterator> { pub fn shift(&mut self, range: Range<usize>) } // :271
// Shiftable for Iter<'_, T> (shift.rs:128) and PrefixIter<'_, T> (shift.rs:142)
```

### `src/edit.rs` — the in-place splice cursor

```rust
pub trait SlabEdit: crate::encoding::ColumnEncoding {    // edit.rs:12
    type Edit: EditSlab<Tail = Self::Tail, Value = Self::Value, State = Self::State>;
    const CARRY_BUDGET: usize = RUN_BUDGET;               // :18
}
pub trait EditSlab: Default {                             // edit.rs:21
    type Tail: Copy + Debug + Default;                    // :22
    type Value: crate::ColumnValueRef;                    // :23
    type State: Clone;                                     // :28
    fn reset(&mut self, slab: &Slab<Self::Tail>, at: usize, max_segments: usize); // :32
    fn pass<F>(&mut self, slab, n, runs, f: &mut F) -> usize
        where F: FnMut(<Self::Value as ColumnValueRef>::Get<'_>, usize);   // :42
    fn insert<V: AsColumnRef<Self::Value>>(&mut self, value: V, n: usize); // :53
    fn delete<F>(&mut self, slab, n, f: &mut F)
        where F: FnMut(<Self::Value as ColumnValueRef>::Get<'_>, usize);   // :58
    fn read_state(&self) -> &Self::State;                 // :63
    fn close(&mut self, slab: &mut Slab<Self::Tail>) -> Vec<Slab<Self::Tail>>; // :68
}
pub(crate) const RUN_BUDGET: usize = 8;                   // edit.rs:85
pub struct Edit<'a, T, C, WF, Idx> { col, slab, in_slab, orig, out, edit,
                                     dirty, remaining, rebuilds, dec }  // :102
```

`Edit` methods: `pos (:198)`, `out_pos (:203)`, `rebuilds (:221)`, `seek (:230)`,
`advance (:237)`, `insert (:299)`, `insert_run (:304)`, `insert_runs (:315)`,
`peek (:330)`, `replace (:347)`, `delete (:366)`, `finish (:460)`.
Private: `new (:165)`, `remaining (:208)`, `column (:214)`, `advance_with (:243)`,
`jump (:268)`, `delete_with (:373)`, `took (:412)`, `load_reader (:422)`,
`orig_len (:469)`, `step (:476)`, `est_runs (:498)`, `stamp (:511)`,
`locate_out (:517)`, `next_slab (:533)`, `open (:552)`, `close (:566)`,
`reconcile (:602)`. `Drop` closes an open rebuild (`edit.rs:616-626`).

### `src/delta/`

```rust
// delta/mod.rs
pub trait DeltaInner: RleValue + ColumnValueRef<Encoding<Leb128>=RleEncoding<Self,Leb128>>
    + AsColumnRef<Self> + sealed::Sealed + Copy + Debug + Sized + 'static {  // :27
    fn to_opt(v: Self::Get<'_>) -> Option<i64>;                              // :38
    fn from_opt(v: Option<i64>) -> Self;                                     // :41
}
// impls: i64 (:47), Option<i64> (:58); Sealed for both (:44-45)

pub trait DeltaValue: Copy + PartialEq + Default + Debug {  // :90
    const NULLABLE: bool;                                    // :92
    type Inner: DeltaInner;                                  // :95
    const MIN_I64: i64;  const MAX_I64: i64;                  // :99-100
    fn to_i64(self) -> Option<i64>;                           // :110
    fn try_to_i64(self) -> Option<i64> { self.to_i64() }      // :118
    fn from_i64(v: i64) -> Self;                              // :123
    fn try_from_i64(v: i64) -> Result<Self, String>           // :128
    fn null_value() -> Self;                                  // :133
}
// impls: u32 (:138), u64 (:157), i32 (:188), i64 (:207), usize (:223),
//        Option<u32> (:260), Option<u64> (:281), Option<i32> (:306),
//        Option<i64> (:325), Option<usize> (:341)

pub struct DeltaEncoderState<'a, T: DeltaValue, C: Codec = Leb128> { inner, abs, uniform, _phantom } // :373
impl { new (:397), len (:406), is_empty (:410), append (:414), append_n (:418),
       extend (:443), finish (:450), is_uniform (:457) }

pub struct DeltaEncoder<'a, T: DeltaValue, C: Codec = Leb128> { data, state }  // :482
impl { new (:504), len (:512), is_empty (:517), append (:526), append_n (:535),
       append_owned (:542), extend (:547), save (:556), save_to (:563),
       save_to_unless (:578), encode (:586), encode_to (:597),
       encode_to_unless (:615) }

pub struct DeltaColumn<T: DeltaValue, C: Codec = Leb128> {
    col: Column<T::Inner, C, IndexedDeltaWeightFn>, _phantom: PhantomData<T> }  // :647
impl { new (:677), with_max_segments (:684), check_invariants (:694),
       from_values (:698), load_with (:708), load (:741), len (:745), is_empty (:749),
       slab_count (:753), save (:757), save_to (:761), save_to_unless (:778),
       to_vec (:811), get (:815), iter (:819), iter_range (:828),
       scope_to_value (:851), insert (:858), remove (:862), remove_n (:871),
       push (:877), pop (:882), first (:891), last (:895), clear (:903),
       truncate (:907), splice (:914), splice_runs (:938), copy_ranges (:956) }
// private: splice_inner (:918), copy_splices_with (:972), retain_ranges (:1053),
//          splice_items_inner (:1066), find_boundaries (:1099)

pub struct DeltaEdit<'a, T: DeltaValue, C: Codec = Leb128> { inner: InnerEdit,
    running: i64, adjust: i64, _phantom }                                    // :1154
impl { pos (:1195), seek (:1200), advance (:1207), peek (:1238), insert (:1249),
       insert_run (:1255), insert_runs (:1290), delete (:1322), replace (:1337),
       finish (:1345) }
// private: new (:1170), prefix_at (:1181), take_delta (:1359), pay_step (:1371),
//          settle (…)
pub struct DeltaRun { pub prefix: i64, pub delta: Option<i64>, pub count: usize } // :1448
pub struct DeltaIter<'a, T: DeltaValue, C: Codec = Leb128> { inner, running, col, _phantom } // :1466
// Iterator (:1482) with next/nth/size_hint, ExactSizeIterator (:1541);
//   pos (:1544), end_pos (:1549), set_max (:1553), …
pub struct DeltaRuns<'a, T, C = Leb128>(pub(crate) DeltaIter<'a, T, C>);  // :1970
pub struct DeltaIterState { inner: IterState, running: i64 }              // :1981
impl DeltaIterState { pub fn try_resume<'a, T, C>(&self, &DeltaColumn<T, C>)
        -> Result<DeltaIter<'a, T, C>, PackError> }                        // :1985
pub(crate) fn deltas_from<'a, I: DeltaInner>(values: &'a [Option<i64>],
        prev_realized: i64) -> impl Iterator<Item = I> + 'a               // :2017
enum SpliceItem { Value(Option<i64>), Run(DeltaRun) }                       // :2030

// delta/decoder.rs
pub struct DeltaDecoder<'a, T: DeltaValue, C: Codec = Leb128> { inner, running, _phantom } // :22
impl { new (:30), next_delta_run_max (:43), advance_by (:59) }
// Iterator<Item = T> with next/nth (:73-95)

// delta/indexed.rs
pub struct IndexedDeltaWeightFn;                                           // :32
// WeightFn<I, C> with Weight = SlabAgg, ACCUMULATES = true,
   compute (:38), accumulate_run (:65)
fn compute_slab_agg<I, C>(data: &[u8]) -> SlabAgg                          // :99
struct SlabScan<'a, C> { decoder, lo, hi, items_before, prefix_before,
                         partial, item_idx, pending: Range<usize> }      // :265
pub struct FindByRange<'a, T: DeltaValue, C: Codec = Leb128> { lo, hi, slabs, outer, current } // :182
impl FindByRange { pub fn new(lo: i64, hi: i64, col) -> Self }               // :205
// Iterator<Item = usize> (:216)
```

---

## Semantics

### Wire formats, exactly as implemented

**Varint codecs.** `Leb128` (`codec.rs:228-329`) is LEB128: 7 bits per byte,
low first, bit `0x80` set on all but the last byte. `encode_unsigned` always
emits at least one byte (`0x00` for zero, `codec.rs:231-244`). `encode_signed`
terminates on the first byte that leaves the remaining value a valid sign
extension: `more = !((val == 0 && byte & 0x40 == 0) || (val == -1 && byte & 0x40 != 0))`
(`codec.rs:247-257`). Consequently the one-byte signed range is −64..=63.
`unsigned_len` is a pure continuation-bit scan capped at 10 bytes
(`codec.rs:302-309`); `unsigned_size`/`signed_size` use `ceil(bits/7)`
(`codec.rs:311-327`) with the signed form adding one bit for the sign.

`Bijou64` (`codec.rs:362-436`, feature `bijou64`) delegates encode/decode to the
`bijoux` crate. Per the doc comment (`codec.rs:337-356`): unsigned 0..=247 is a
single byte equal to the value; larger values use a tag byte `0xF8..=0xFF`
followed by 1–8 big-endian payload bytes with a per-tier offset, max 9 bytes for
`u64::MAX`. `unsigned_len` is `1 + b.saturating_sub(0xF7)` with a
`data.len() >= len` check (`codec.rs:408-417`) — pure ALU, no table. Signed is
`bijoux::i64`: zigzag `(n << 1) ^ (n >> 63)` composed with the unsigned encoding,
so the one-byte signed range is −124..=123.

The contract every codec must satisfy is **forward-decodability**: the length of
a value is discoverable from its first byte; nothing scans backwards
(`codec.rs:10-15`).

**RLE slab** (`src/rle/mod.rs:25-33`). A slab is a flat sequence of runs with no
count, no length prefix and no header of any kind:

| Run kind | Header (signed varint `h`) | Payload |
|---|---|---|
| repeat | `h > 0`, `h = count` | one `T::pack`ed value |
| literal | `h < 0`, `h = -(n)` | `n` back-to-back `T::pack`ed values |
| null | `h == 0` | one *unsigned* varint `count` |

A repeat run with `count == 1` is never emitted: `emit_run` writes
`signed(-1)` + the value, i.e. a one-element literal run
(`src/rle/state.rs:681-690`). A `Lone` state is the deferred form of that
(`state.rs:227`). Empty literals are unrepresentable in canonical form, because
`signed(0)` is the null marker (`load.rs:440-447` documents this explicitly).

Value encodings per type are in the table under *Surface*.

**`RleTail` metadata** (`src/rle/mod.rs:93-104`):
`bytes: u32` = the total byte length of the last segment (header + values, same
meaning for repeat/literal/null), and `lit_tail: Option<NonZeroU32>` = for a
literal run only, the byte length of its *last value*. `u32` is deliberate: a
single segment must stay under 4 GiB, so blobs larger than that belong in
`RawColumn`. `tail()` (`rle/splice.rs:1032-1073`) reconstructs an `RleState`
from these two numbers in O(1): `header_pos = data.len() - tail.bytes`, then
re-read one signed varint and at most one value.

**Bool slab** (`src/bool.rs:13-27`): alternating *unsigned* varint run counts
starting with `false`. No value bytes at all. `BoolDecoderState::default` sets
`value: true` precisely so the first `advance_run` flip yields `false`
(`bool.rs:478`, `bool.rs:494-502`). Tail metadata is `u8` = the byte width of
the last count varint (`bool.rs:820-831`), which is why a count above 127
needed a fix (`CHANGELOG.md:50`).

**Delta column** (`src/delta/mod.rs:19-26`): the storage is *literally*
`Column<i64>` or `Column<Option<i64>>` of RLE-encoded deltas, so the wire format
is the RLE format above with `i64` payloads, plus null runs. `first` delta
relative to an implicit running zero (`delta/mod.rs:428-441`); each subsequent
value is `v - previous_non_null_realized`; a null is a null run and leaves the
running value alone (`delta/mod.rs:441-443`). A repeated value is `delta` once
followed by `count-1` zeros (`delta/decoder.rs`-side construction,
`delta/mod.rs:436-440`).

**`RawColumn`** (`src/raw.rs:1-16`): no framing at all. `save` is the plain
concatenation of the slabs' bytes (`raw.rs:452-460`), and `load` puts
everything into one slab (`raw.rs:463-484`).

### Canonical-form invariants (load rejects anything else)

Proved from `RleSegment::validate_after` (`src/rle/decoder.rs:438-497`), which
`rle_validate_encoding` (`rle/load.rs:19-63`) and `RleLoadIter` (`load.rs:203-226`)
both run on every segment:

1. A repeat run has `count >= 2` — else `"repeat run with count < 2"`.
2. A null run has `count != 0` — else `"null run with count 0"`.
3. A literal run has `count != 0` — else `"empty literal run"` (unreachable
   from valid LEB128, as `load.rs:440-447` notes).
4. No two adjacent literal runs — `"adjacent literal runs"`.
5. No two adjacent null runs — `"adjacent null runs"`.
6. No two adjacent repeat runs with the same value — `"adjacent repeat runs
   with same value"`.
7. No consecutive equal values *within* a literal run — `"literal has
   consecutive equal values"`.
8. A run's first value may not equal the previous segment's value — `"boundary
   values match (should be merged)"`, checked in both directions (repeat→lit
   and lit→repeat).
9. Nulls are rejected outright in a non-nullable column (`T::NULLABLE == false`)
   — `"null in non-nullable column"` (`rle/decoder.rs:487-489`).

The consequence, stated by the load iterator's own doc comment
(`rle/load.rs:70-80`): consumers get "adjacent runs never carry equal values"
**by construction**, and every yielded run is exactly one wire segment — so a
run never spans a slab boundary during a load.

Bool canonical form (`bool_validate_encoding`, `src/bool.rs:784-831`):
1. Empty slab ⇔ empty column (`:785-792`).
2. A zero count is only legal on run 0 — `"zero count in non-first run"`.
3. No trailing zero-count run — `"trailing zero-count run"`.
4. `len` accumulation is `checked_add` — `"length overflows usize"` (`:817-820`).
A zero-count interior run is what would make neighbours merge, so (2) subsumes
the "no mergeable neighbours" check (doc comment `:777-783`).

### Slab and column invariants

`Column::check_invariants` (`src/column.rs:1286-1343`) asserts:
- An empty column holds at most one slab (`:1299-1308`).
- No slab has `len == 0` (`:1310`).
- `slab.segments <= max_segments` **or** `slab.segments == 1` — a single
  oversize value may exceed the budget (`:1311-1318`).
- Each slab's cached `len` and `segments` agree with a fresh parse of its own
  bytes (`:1319-1323`).
- No adjacent pair is simultaneously *mergeable*: not
  `(a < min || b < min) && a + b <= max` where `min = max(4)/4` at least 1
  (`:1324-1333`).
- `total_len` equals the sum of slab lengths, `index.len() == slabs.len()`, and
  `index.items_before(i)` equals the running sum (`:1334-1342`).

`with_max_segments` rejects budgets below 2 because `load` splits at
`max/2` and `splice` asserts `slab.segments <= max_segments` — a budget of 1
would make the next mutation panic (`column.rs:1121-1135`).

`Column::try_merge` (`column.rs:1785-1798`) is the merge policy: merge `a` and
`b` when `(a.segments < min || b.segments < min) && a.segments + b.segments <= max`,
with `min = (max/4).max(1)` so a slab emptied by a deletion (0 segments) always
merges away.

`RleLoadIter::new` sets `target_segments = max_segments / 2` and cuts a slab
whenever the in-progress slab reaches it (`load.rs:185-196`, `load.rs:216-222`).
So a freshly loaded column's slabs are **half full**; a freshly spliced one can
run to the full budget. `Edit::close` then merges the neighbours back down
(`edit.rs:566-593`).

`RleLoadIter` re-cuts a literal run across a slab boundary by *copying input
bytes verbatim* and rewriting only the header (`Slab::copy_from`,
`load.rs:300-322`): if the literal run continues into the next slab the new
header is `-lit_count`; if it terminated, the header is `-pending_header`; if
the truncated count is less than the count the header came with, the original
header is rewritten in place via `Codec::rewrite_lit_header`
(`load.rs:313-321`).

`IterState::try_resume` (`column.rs:807-855`) refuses to resume when
`state.counter != column.counter` or `state.num_slabs != column.slabs.len()`,
returning `PackError::InvalidResume` (`column.rs:822-828`). The `counter` is
bumped by `Edit::stamp` on every path that moves slabs, *including* a write-back
that leaves the slab count unchanged (`edit.rs:511-514`).

`Codec::rewrite_lit_header` (`codec.rs:194-205`) splices a new signed header at
`header_pos` and returns the signed change in buffer length, so callers can fix
`RleTail.bytes` in the same step (`rle/load.rs:317-320`).

### B-tree invariants and rebalancing

`SlabBTree::check_invariants` (`src/btree.rs:1283-1312`) asserts, via the
recursive `check_node` (`:1314-1360`):

- An internal root has ≥ 2 children, else it should have been collapsed
  (`:1286-1292`).
- `slabs == total_slabs` (`:1294`).
- No duplicate free-list entries (`:1296-1301`).
- Arena consistency, node by node: reachable ⟺ live, dead ⟺ on the free list,
  no node both live and freed, no node neither (`:1302-1309`).
- No node reachable twice (`:1319`).
- Leaf occupancy ≤ `B = 64`; internal child count ≤ `B` (`:1325`, `:1343`).
- No empty non-root leaf; no empty internal node (`:1326-1330`, `:1341`).
- All leaves at uniform depth (`:1331-1335`).
- Every cached `ChildSlot::slab_count` and `ChildSlot::agg.len()` equals
  recomputation (`:1345-1358`).

Mutation paths:

- `splice` (`btree.rs:412-439`) decomposes into an in-place `overwrite_range` for
  the common prefix (`min(range.len(), new.len())` items, zero allocation,
  O(k + log n)) and a structural delta for the rest.
- `try_single_leaf_splice` (`:905-973`) handles a range inside one leaf; if the
  result still fits in `B` it splices the leaf in place and then, **only if the
  leaf shrank**, calls `maybe_merge_leaf` (`:958-961`).
- `maybe_merge_leaf` (`:710-758`) mirrors the column's policy: merge when the
  leaf is under `B/4` and the pair fits in `B`; merge **right-into-left** so
  slab order is preserved (`:723-729`); bails when the leaf is the only child
  (that case is `remove_and_cascade`/`collapse_root`'s job).
- Emptying a non-root leaf goes to `remove_and_cascade` (`:657-687`), which
  frees the subtree, removes the parent's slot, cascades while the parent is
  empty, and resets an emptied root to a fresh leaf reusing the root id (`:669-675`).
- `collapse_root` (`:690-701`) runs once per structural mutation, promoting a
  single child until the root is a leaf or has ≥ 2 children.
- Internal nodes are **deliberately never rebalanced** (`btree.rs:18-22`): they
  lose a child only when a whole leaf dies, so their fill tracks the leaf count;
  worst case is extra memory, never a wrong query.
- `splice_via_lca` (`:490-632`) is O(log n + k), rebuilding only the affected
  LCA span. Its "paths identical" branch is a `debug_assert!`-guarded
  full-rebuild fallback that the comment calls a routing bug (`:531-546`).

Searches:

- `find_by_prefix` (`:1192-1229`) descends by `agg.len()`, returning
  `(slab_idx, items_before)` or `None` past the end.
- `items_before_slab` (`:1232-1280`) is its inverse; `slab_idx` may equal the
  slab count, yielding the total item count.
- `FindByValue` (`:1411-1459`) is an explicit-stack cursor: it descends only
  into children whose `SlabAgg::contains(target, prefix_before)` holds
  (`:138-142`) and returns `(slab_idx, items_before, prefix_before)`.
  `FindByValueRange` is the same with `overlaps(lo, hi, prefix_before)`
  (`:144-149`, `:1490-1535`).
- `SlabAgg::merge` (`:110-122`) is order-**sensitive** (allowed by the trait:
  only associativity is required, `btree.rs:44-46`): `min_offset` is
  `l.min_offset.min(l.total + r.min_offset)`.
- `find_slab_at_item` (`:1563-1617`) returns `FoundSlab { index, prefix, pos }`
  where `pos` is the *item offset inside the slab*; `find_slab_at_prefix`
  (`:1628-1671`) is the "first slab whose running prefix reaches `target`"
  search and returns one-past-the-end when the target exceeds the total.

### The edit cursor's contract

`Edit` is **forward-only** in the column's *original* coordinates: `seek`
asserts `to >= self.orig` (`edit.rs:231`). The dual positions `orig` (pre-edit)
and `out` (as-edited) exist because every caller holds pre-edit positions
(`edit.rs:118-122`), and `locate_out` re-finds `slab`/`in_slab` from `out` after
a write-back, invalidating any reader (`:517-531`).

`remaining` counts *original* items ahead. The tail beyond the cursor is
untouched, so it is simultaneously "original items left" and "current items
left" — which is what lets the cursor answer "am I at the end?" while a rebuild
is open and `col.total_len` is stale (`:135-140`).

The reader `dec` is **lazy**: `None` until a read asks for one, and cleared by
every index jump (`:145-157`, `:527`). Building it eagerly would be wasted work
for the common `edit().seek()` chain.

`est_runs(n) = n * slab.segments / slab.len` (`:498-504`) — a cheap average-runs
estimate used to decide whether carrying is worth it against
`SlabEdit::CARRY_BUDGET` (default 8 runs, `edit.rs:85`, `edit.rs:18`).

`delete_with` (`:373-411`) short-circuits: a whole slab deleted with no rebuild
open is dropped outright without decoding (`:389-400`), and a delete off the end
of the column is clamped to `n.min(self.remaining)` so the cursor never moves
past items that never existed (`:379-383`).

`Edit::drop` calls `close` (`:616-626`), so a chain does not need an explicit
`finish()`.

`RleEdit::walk` (`rle/edit.rs:77-108`) reads from a *suspended* decoder, so
nothing is decoded twice; a literal run counts one segment per value, a repeat
or null run one segment however many items (`:103-107`).
`RleEdit::close` (`:193-217`) reads only the tail's **first run** and carries
the rest as bytes, so the carried region is never re-encoded.

`RleEdit` holds `RleState<'static, T, T, C>` (owned, via `into_owned`,
`rle/state.rs:297-329`) rather than the borrowed form a one-shot splice uses
(`rle/edit.rs:16-18`): the cursor lives alongside a `&mut Column` and so cannot
borrow the slab. For a `Copy` value this is a register move; string columns pay
one clone per run carried.

### Delta's boundary fix-up

Deleting or inserting shifts every realized value after the cursor unless the
next non-null delta absorbs the difference. `DeltaColumn::find_boundaries`
(`delta/mod.rs:1099-1121`) returns `(prev, skip, next_val)` where `prev` is the
realized prefix at `index`, `skip` is the number of null entries between
`index+del` and the next non-null, and `next_val` that value. RLE merges
consecutive null runs, so at most one null run sits in between — no loop needed
(`delta/mod.rs:1116-1118`). `splice_items_inner` (`:1066-1092`) then deletes
`del + skip + 1` original items and re-emits the null run inline plus a
recomputed boundary delta.

`DeltaEdit` does the same thing incrementally: it carries a `running` value and
an `adjust` debt, pays the debt one item at a time in `pay_step`
(`delta/mod.rs:1371-1390`), and a null is carried without paying
(`delta/mod.rs:1385-1389`) because "a null holds no delta".

`DeltaValue` domain contract (`delta/mod.rs:75-89`): realized values must lie in
a 2^63-wide window. This is a wire-format closure property, not an accumulator
limitation — deltas are `i64`, and a deletion makes two neighbours adjacent, so
*any* pair may need its difference encoded. Unsigned `to_i64` **panics** outside
the domain (`:167-172`, `:237-242`); `try_to_i64` returns `None`
(`:177-179`, `:246-249`); `load` **rejects** out-of-domain data (via the
per-slab `SlabAgg` min/max checked against `MIN_I64`/`MAX_I64`).

`IndexedDeltaWeightFn::compute_slab_agg` (`delta/indexed.rs:99-136`) exploits
monotonicity: within a run of `count` items with delta `v`, the realized-prefix
progression is `partial+v, partial+2v, …, partial+count·v`, so min and max are
at the endpoints. The loader's twin `accumulate_run` (`delta/indexed.rs:65-89`)
uses checked arithmetic and errors with `"delta running sum overflows i64"`
rather than wrapping, because hostile bytes could steer a wrap back into a
plausible-looking range.

`SlabScan::next` (`delta/indexed.rs:270-300`) solves
`lo ≤ a + v·k < hi` for `k` with sign-aware `div_ceil`/`div_floor` and emits
`pending: Range<usize>`; `v == 0` is special-cased (`:288-293`).

### Failure-mode policy

Uniform across the crate (README "Loading untrusted data"):

| Situation | Behaviour | Evidence |
|---|---|---|
| caller breaks a documented precondition | **panic** | `edit.rs:231`, `column.rs:1773`, `load_opts.rs`/`column.rs:1176`, `delta/mod.rs:161-165` |
| malformed/hostile/out-of-domain bytes | **`Err(PackError)`** | every `try_*` returns `Result`; `load` never panics |
| query for an unstorable value | **empty result** | `delta/indexed.rs:151-155`, `try_to_i64` (`:118`) |

`PackError::InvalidValue(String)` carries the `validate_after` message verbatim
(`rle/load.rs:29-30`, `rle/load.rs:207-208`).

### `unsafe`

Exactly one `unsafe` block in the crate: `String::unpack`
(`src/lib.rs:695-701`) calls `std::str::from_utf8_unchecked`. Its stated safety
argument: hexane only writes valid UTF-8 via `pack` (which extends from
`&str::as_bytes`), and `Column::load` calls `try_unpack` on every value during
validation. Two load paths that must therefore be non-bypassing:
`RleLoadIter::try_next_run` (`load.rs:203-226`) and
`Column::from_slabs` (`column.rs:1202-1213`; its debug-build check is
`#[cfg(debug_assertions)]` only — a release build trusts the caller). The
`leb128` crate's decoders are the other untrusted-byte surface, surfaced as
`PackError::InvalidNumber` (`error.rs:6-7`).

---

## Zig mapping notes

### The type-level dispatch — the hard part

`Column<T>` resolves its encoding, decoder, encoder, tail type, index weight and
edit cursor *through the type system*:

```rust
T: ColumnValueRef  ->  type Encoding<C>  ->  ColumnEncoding { Codec, Value, Tail, State, Decoder<'a>, Encoder<'a>, LoadIter<'a> }
                                 |-> edit::SlabEdit { type Edit: EditSlab }
T: PrefixValue     ->  type Prefix
T: DeltaValue      ->  type Inner: DeltaInner
Column<T, C, WF, Idx>  where WF: WeightFn<T, C>, Idx: ColumnIndex<WF::Weight>
```

Zig has no associated types and no comptime trait dispatch, so this cannot be
transliterated. Three options, in descending order of fidelity:

1. **Explicit encoding parameter, comptime dispatch on a tag.** Make the
   encoding a comptime parameter carrying a tag enum:
   `pub fn Column(comptime E: Encoding) type { return struct { … }; }` with
   `E.Tag == .rle` / `.bool`, and `E.Value`/`E.Tail` as comptime-derived
   functions `E.initValue()`, `E.tailDefault()`. This preserves the
   "one monomorphisation per (T, C, WF, Idx)" property that all the `#[inline]`
   placement depends on. Use `@TypeOf`/`@hasDecl` for the `T::Get<'a>`
   borrowed-vs-owned split.
2. **Vtable-style vtable struct** with a `*const VTable` field. Faithful to the
   trait dispatch, but it loses the zero-cost property the whole design is
   built on — the crate's `#[inline(always)]` on `try_next_segment`
   (`rle/decoder.rs:226`), `CutState::track` (`rle/load.rs:118`) and
   `Bijou64::unsigned_len` (`codec.rs:406`) exist to keep everything
   monomorphised. **Do not take this route** for the hot loops.
3. **Manual dispatch at the few call sites** that need a runtime-selected
   encoding. Only `ColumnEncoding` *itself* is a trait object in practice
   (nothing stores a boxed encoding), so this costs little.

### Per-construct mapping

| Rust | Zig 0.16 |
|---|---|
| `trait` | `pub const X = struct { … }` with `pub fn` fields, or a namespaced set of functions; use `anytype` generics for the monomorphic case |
| `impl Trait for T` | a free function namespace `fn t_xxx(...)` or a `T` namespace struct; **no** ad-hoc methods — Zig has no impl blocks |
| `enum` (data-carrying) | `union(enum)` |
| `enum` (fieldless) | `enum` |
| `Option<T>` | `?T` |
| `Result<T, E>` | `anyerror!T` or a Zig error set + payload struct |
| `Vec<u8>` | `std.ArrayListUnmanaged(u8)` + an explicit allocator, or `std.ArrayList(u8)` |
| `&[u8]` | `[]const u8` |
| `&mut Vec<u8>` | `*std.ArrayListUnmanaged(u8)` |
| `Range<usize>` | `struct { start: usize, end: usize }` (Zig has no range type) |
| `HashMap` | `std.StringHashMap` / `AutoHashMap` |
| `BTreeSet` | `std.TreeMap` or a sorted array |
| `Arc<T>` | refcounted pointer; hexane has no `Arc` |
| interior mutability | raw pointer + `*const`-to-`*mut` cast at the one `Sealed`-trait site, or a `RefCell` shim |
| `PhantomData` | `comptime` phantom type parameters (`T` never appears in a field); Zig allows unused generic params, so this is free |
| `Self::Get<'a>` (GAT) | **no direct equivalent.** See below |
| `impl Iterator` | `struct` with `next(self: *Self) ?Item`; `std` adapters where they fit |
| `#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]` | hand-written; `Default` → `init`/`empty`; `Debug` → `std.debug.print` |
| `dyn ColumnRef<T>` (`column.rs:361`) | `*const anyopaque` + a small vtable of 3 fn ptrs |
| `unsafe` | raw pointers plus a documented invariant; `String::unpack`'s invariant (validate-on-load) must be enforced at every `unpack` call site |
| allocator-generic (`impl Allocator`) | **hexane never parameterises on an allocator** — every `Vec` is the global allocator's. A Zig port should thread an `Allocator` anyway, but note that this is *added* genericity, not a translation |

#### GATs — `type Get<'a>` (lib.rs:218)

`ColumnValueRef::Get<'a>` is a generic associated type with two shapes:
owned for `Copy` types (`u64`, `bool`, `DeltaValue`), borrowed for
`String → &'a str` and `Vec<u8> → &'a [u8]`. Zig has no GATs.

The consequence is a **type-level function**, which Zig expresses as a
comptime-returning function:

```zig
// T.Get('a)
pub fn Get(comptime Self: type, comptime a: []const u8) type {
    return if (Self == hexane.String) []const u8 else Self;
}
```

`T::to_owned` and `T::eq` become `pub fn toOwned(self: T) T` and
`pub fn eql(a: T, b: T) bool`. `T::shorten` (lib.rs:223) exists purely because
Rust cannot express covariance for a GAT; in Zig, `&[a]`-reborrowing to
`&[b]` is a no-op and the method disappears entirely.

The one place this bites: `Column<T>` must store and return different types
depending on `T`, so a caller writing generic-over-`T` code has to be
`comptime`-generic too. That is fine for the port (hexane is entirely
monomorphic today) but it is the main ergonomic cost.

#### `T::Encoding<C>` with a codec parameter

`type Encoding<C: Codec>` is a GAT over *values*, not lifetimes. Zig:

```zig
pub fn Encoding(comptime T: type, comptime C: type) type { … }
```

`C` must be a zero-sized type with associated functions. `Leb128` maps to a
namespaced struct of `pub fn`s over `VarBuf`. `Codec` trait → a set of functions
taking `comptime C: type`. `Bijou64` is the same shape.

The `MAX_VARINT_LEN = 16` stack buffer (`codec.rs:20`) maps directly:
`var buf: [16]u8 = undefined`. But the Rust `VarBuf` is a *returned value* with a
length — in Zig, return `struct { bytes: [16]u8, len: u8 }` and pass
`*const VarBuf` / `[]const u8` around. The `rewrite_lit_header` helper
(`codec.rs:194`) mutates a `Vec<u8>` in place, which is an allocator-bearing
operation on a hot path (`rle/load.rs:317`, `rle/splice.rs:965`,
`rle/state.rs:376`) — in Zig it needs the allocator threaded explicitly, or an
`ensureUnusedCapacity`+`resizeAssumeCapacity` pair to keep it allocation-free.

#### `&mut self` + `?T` returns vs Zig's `error` returns

Rust's `PackError` carries a payload (`InvalidValue(String)`,
`InvalidLength(usize, usize)`, `InvalidNumber(leb128::read::Error)`). Zig error
sets cannot carry payloads. Two options:

- **Enum-tagged error payload**: `error{InvalidUtf8, BadFormat, …}` plus an
  out-parameter struct. Loses the payload at every call site.
- **Error union with an error *value***: not expressible; the idiom is
  `anyerror` + a thread-local or an out-param.

Given how much of the code does `map_err(|e| PackError::InvalidValue(e.to_string()))`
(`rle/load.rs:29`, `rle/load.rs:207`), the pragmatic mapping is an `error` set
with the message-producing sites collapsed into a generic
`error.InvalidValue` plus a `?[]const u8` detail slot on the load path only.
Note that `PackError` messages are produced by `RleSegment::validate_after`
returning `&'static str` (`rle/decoder.rs:496`) — in Zig that is a
`[]const u8` switch arm, cheap.

#### Traits with generic methods

Three traits have generic methods, and none of them can be trait objects in Zig:

- `ColumnEncoding::remap<F>` (`encoding.rs:70`), `EncoderApi::extend<I>`
  (`encoding.rs:204`), `RunDecoder::scan_for` where `Self::Item: Ord`
  (`encoding.rs:345`), `RleState::append_n<V: Into<Cow<..>>>` — generic over a
  closure or iterator type. Zig: `anytype` parameters, which is a natural fit.
- `AsColumnRef<T>` (`lib.rs:459`) exists to accept `&str` where `String` is
  wanted. In Zig this collapses to a `[]const u8` with an optional "is null"
  wrapper struct. The whole `Cow` machinery in `rle/state.rs:16-67` — the crate's
  own `TODO` lists "would be nice to get rid of all the Cow's" — disappears.
- `EditSlab::pass<F>` / `delete<F>` (`edit.rs:42`, `edit.rs:58`) pass a callback
  so a wrapper (the delta accumulator) stays in step. In Zig: `*const fn`
  context, or `anytype` if monomorphised.

#### Sealed traits

`mod sealed { pub trait Sealed {} }` (`lib.rs:176-178`) is a supertrait on
`SlabWeight`, `WeightFn`, `ColumnIndex`, `PrefixSlabWeight`, `BoolDecoderState`'s
owners, `DeltaInner` and `PrefixWeightFn`. Purpose: keep the index/weight
machinery free to change shape without breaking downstream
(`lib.rs:172-175`). In Zig, seal with an unexported comptime check
(`@import("root").private.Token` style) or simply don't export the trait.

#### `SlabBTree`'s arena

`Vec<Option<Node<A>>>` + a free list (`btree.rs:237-243`) maps to
`[]?Node` (a slice of optionals) plus `[]NodeId`. `NodeId = u32` (`btree.rs:194`)
becomes `u32`. `alloc` (`:283`) pops the free list first — Zig:
`self.free.popOrNull() orelse newId: { self.nodes.append(node); … }`.

`ChildSlot<A> { id, agg, slab_count }` (`btree.rs:224`) is the key structural
idea: the aggregate is **cached** at the parent so top-down descent is
constant-time per node. This is a real algorithmic dependency, not a
micro-optimisation — `find_by_prefix` (`:1192`) and `FindByValue`
(`:1411-1459`) read `c.agg` / `c.slab_count` on every level without descending
first.

#### Suspend/resume decoder state

`RleDecoderState` (`rle/decoder.rs:96-100`) and `BoolDecoderState`
(`bool.rs:475-480`) are `Copy`, borrow-free snapshots whose whole purpose is to
be held *beside* a `&mut Column` so a cursor can carry its reader across writes
(`rle/decoder.rs:72-79`). Zig's borrow checker does not exist, so this whole
design — `suspend`, `resume`, `state_at`, `state_peek`, `state_advance`,
`RleDecoderState`, `BoolDecoderState`, `IterState`, `DeltaIterState`,
`PrefixIterState`, `RleDecoder::run_at`, and the `run_at`-vs-`Repeat(value)`
split documented at `rle/decoder.rs:22-27` — can be **deleted outright**.
`Iter` becomes a struct holding a pointer to the slab bytes plus a byte offset
and a remaining count; `RleDecoder` likewise. The `#[inline]` reasoning in
`rle/decoder.rs:22-27` (widening `RunState::Repeat` costs 9-15% on value-heavy
columns) becomes irrelevant.

The one thing to keep: `IterState::try_resume`'s staleness check
(`column.rs:822-828`, returning `InvalidResume`). A Zig port that keeps any
suspend/resume API must keep the `counter` and `num_slabs` guards
(`column.rs:1032`, `edit.rs:511-514`), because the same aliasing hazard exists
even without a borrow checker.

#### `Column<T, C, WF, Idx>` — four type parameters

The doc says plainly: "Treat the public type as `Column<T>`. The `WF` and `Idx`
parameters are internal plumbing with the right defaults" (`column.rs:1016-1021`).
A Zig port should hard-code `LenWeight` + `SlabBTree` and expose exactly two
entry points: `Column(comptime T, comptime C)` and
`PrefixColumn(comptime T)`. Anything more re-creates the genericity the crate
deliberately hides.

#### B-tree / Fenwick

Both index backends share `ColumnIndex<W>` (`index.rs:27`). A Zig port needs
one. `BitIndex` (`index.rs:67`) is a Fenwick tree over `W` with
`AddAssign`/`SubAssign`; `SlabBTree` (`btree.rs:237`) is the default because
`SlabAgg`'s min/max is not invertible. The Zig version of `BitIndex` is a
straightforward `[]W` with `W.len()` arithmetic — note that `items_before`
(`index.rs:96-106`) only ever reads the **`len` component**, not the prefix.

`SlabBTree` is 2459 lines of arena bookkeeping, split/merge/underflow logic and
a 700-line `#[cfg(test)]` block (from `:1674`). The portable part is roughly
`btree.rs:194-1300` minus tests: node layout, `from_iter`, `update_slab`,
`overwrite_range`, `splice_structural` routing, `split_and_propagate`,
`propagate_splits`, `collapse_root`, `remove_and_cascade`, `maybe_merge_leaf`,
and the two `Frame`-stack cursors.

#### Codec-in-the-type-system

`Column<u64, Bijou64>` and `Column<u64, Leb128>` are different types with
different wire formats, selected at compile time (`lib.rs:129-136`,
`codec.rs:139-205`). In Zig this is a comptime type parameter — an exact fit, and
arguably cleaner than Rust's `Encoder<'a, T, C = Leb128>` defaulting. The
`leb128::` / `bijou::` alias modules (`lib.rs:51-100`) exist to make the codec
visible *at the import site*; a Zig port would name the codec in the type
parameter directly and drop them.

#### What has no clean Zig equivalent

- **GATs** (`ColumnValueRef::Get<'a>`, `ColumnEncoding::Decoder<'a>`,
  `Encoder<'a>`, `LoadIter<'a>`, `PrefixAggregate::Prefix`) — as above,
  comptime-returning functions. Mechanical, but the *lifetimes inside the
  signature* (`state_peek<'s>(slab: &'s Slab, state: &State) -> Option<Value::Get<'s>>`,
  `encoding.rs:114-118`) become lifetime parameters on the comptime function.
- **`Self::Get<'a>` in a *stored* field** — `RleDecoder` stores
  `RunState::Repeat(T::Get<'a>)` (`rle/decoder.rs:51-63`) and `RleState` stores
  `RleCow<'a, T, V>` (`rle/state.rs:225-245`). Both are the borrowed form;
  in Zig the owned form is a struct with a slice pointer and Zig does not
  encode the borrow, so this is actually *easier*.
- **Trait objects with generic methods** — `ColumnRef` is fine (3 non-generic
  methods), but nothing else with generics is ever used as a `dyn`.
- **`for<'a> AddAssign<&'a Self::Prefix>`** (`prefix.rs:55`, `btree.rs:74`) —
  an HRTB allowing prefix accumulation by reference so a `HashMap`-backed
  non-scalar prefix avoids a per-level clone (`btree.rs:66-73`). Zig's
  `@TypeOf`/`anytype` on the `+=` operand covers the same call shape, but the
  "borrow to avoid a clone" *motivation* disappears: Zig copies are explicit.
- **`#[cfg]` / feature-gated surface** — the `bijou64` gate removes
  `pub struct Bijou64`, `pub mod bijou`, and seven `pub type` aliases
  (`lib.rs:84-100`, `codec.rs:359-360`). A Zig build must either always
  compile bijou64 (pulling a dependency hexane does not otherwise need) or use
  a build option. `wasm` and `deep_fuzz` affect only logging and test gating.
- **Proc macros** — none. `thiserror` is the only derive-like macro; the
  six-variant `PackError` becomes an error set plus, where the payload matters,
  explicit formatting.
- **`unsafe impl` marker traits** — none (`Send`/`Sync` bounds appear nowhere).
  Zig has no `Send`/`Sync`, so nothing is lost. `PhantomData<fn() -> (T, C)>`
  (`lib.rs:41`, `rle/mod.rs:41`) and `PhantomData<fn() -> C>` mark "does not own
  T/C" and are just unused type parameters in Zig.
- **`no_std`** — hexane is not `no_std`: `Vec`, `println!`, `thiserror`,
  `std::str`. A `no_std` port would need an allocator parameter and its own
  formatting; not a free ride.
- **Allocator-generic plumbing** — absent today, as noted.

---

## Risk

### What is hard

1. **The type-level encoding dispatch is the port's whole difficulty.** Twelve
   traits participate in `Column<T>`'s type identity
   (`ColumnValueRef`, `ColumnValue`, `RleValue`, `AsColumnRef`, `WeightFn`,
   `ColumnIndex`, `SlabEdit`, `EditSlab`, `ColumnEncoding`, `PrefixValue`,
   `DeltaValue`, `DeltaInner`). Getting this wrong produces a column that
   compiles and silently writes the wrong bytes. The safest route is route (1)
   above: explicit comptime encoding tag, `Column(comptime T, comptime C)` as
   the *only* public shape, `LenWeight`/`SlabBTree` hard-coded.

2. **`RleTail` correctness.** The two-field tail (`bytes`, `lit_tail`) is the
   single mechanism that makes O(1) in-place splice possible, and it is
   threaded through six arithmetic sites that must all agree:
   `WPos::as_tail` (`rle/state.rs:152-172`), `WPos::merge`
   (`rle/state.rs:136-149`), `Slab::copy_from` (`rle/load.rs:300-322`),
   `RleLoadIter::cut_slab` (`rle/load.rs:157-170`),
   `do_merge` (`rle/splice.rs:1083-1113`), and `splice_slab`'s ordering
   constraint (splice bytes **before** rewriting the header, generate the tail
   **after** — `rle/splice.rs:962-971`, with the reason given inline). A tail
   that is off by one header length is silent: the values still decode, the
   next merge or splice produces garbage.

3. **The literal-header rewrite protocol.** The encoder defers writing a
   literal run's header (`emit_lit` writes `-1` as a placeholder,
   `rle/state.rs:676-680`) and patches it later once the run is known to have
   length > 1. The bookkeeping is `FlushState::rewrite: Option<RewriteHeader>`
   plus `RleState::Lit { count, local, header_pos, bytes, current }` where
   `count` is items already in the buffer and `local` is items this machine
   wrote (`rle/state.rs:229-245`). When the header is *not* ours (`local != count`)
   the rewrite must be deferred to the caller (`RewriteHeader`), and every
   consumer (`splice_slab`, `load::copy_from`, `SpliceWriter::apply`,
   `edit.rs`) must honour it. Getting `local`/`count` mixed up corrupts a
   run silently.

### What is unverifiable without running the code

- **The B-tree underflow policy.** Internal nodes are never rebalanced on
   purpose (`btree.rs:18-22`) and `maybe_merge_leaf` fires only when the leaf
   shrank *and* is under `B/4` (`btree.rs:710-758`). Whether the resulting
   shape stays query-correct under adversarial deletion is exactly what the
   700-line test module (`:1674-2459`) and the CHANGELOG's two corruption fixes
   (`CHANGELOG.md:56-59`) were chasing. A port has no way to check this by
   inspection; it must carry `check_invariants` (`btree.rs:1283-1312`) verbatim
   and run the same fuzzers.
- **`DeltaEdit`'s `adjust` debt across slab jumps.** The accumulator is lost
   when the cursor jumps whole slabs and is read back from the index
   (`delta/mod.rs:1219-1227`, with the timing constraint spelled out: "it has to
   be asked *now*: the next op may open a rebuild, after which the index no
   longer describes the column"). The same subtlety runs through
   `find_boundaries` (`delta/mod.rs:1099-1121`). This is the most likely place
   for a port to produce a column that decodes to plausible but wrong values.
- **Any claim about performance.** The `#[inline]` hints carry measured
  justifications ("9-15% on value-heavy columns", `rle/decoder.rs:22-27`;
  "4 KiB sits at the bottom of a shallow plateau", `raw.rs:24-29`; "64 is
  empirically a good compromise", `btree.rs:26-32`). A Zig port's inliner will
  not reproduce any of them, and the `B = 64` / `DEFAULT_MAX_SEG = 64` /
  `DEFAULT_MAX_SEGMENTS = 4096` / `RUN_BUDGET = 8` constants are all
  empirically tuned, not derived.

### What a Zig port would silently get wrong

- **`RleTail` staleness after a cursor's `open()` but before `close()`.**
  `Edit::column()` is documented as "only meaningful while no rebuild is open —
  the slab metadata is stale until one closes" (`edit.rs:213-216`). Every
  in-place invariant checker in the crate is `#[cfg(debug_assertions)]`
  (`rle/mod.rs:117`, `bool.rs:28`, `column.rs:1203`) — i.e. **release builds
  check nothing**. A port that drops the debug assertions, or that validates at
  the wrong moment, loses the only guard the original has.
- **The `unsafe` in `String::unpack` (`lib.rs:695-701`).** Its justification is
  "validated during load". A Zig port that adds a fast path which skips
  `try_unpack` — or that lets a caller reach `unpack` through
  `Column::from_slabs` (`column.rs:1202`) in a release build — produces a
  `[]const u8` that is not valid UTF-8, with no second line of defence.
- **Overlong LEB128 encodings.** `Codec` allows them (`codec.rs:10-15` says
  LEB128 "admits overlong forms"; `Bijou64` does not, `codec.rs:339-341`).
  Hexane's *structural* validation (`validate_after`) checks run shape, not
  varint canonicality, so an input like `0x80 0x00` for `signed(0)` decodes as a
  null run of count 0 and is rejected — but `0x81 0x00` for a repeat count is
  accepted with the same item count. A port that "helpfully" enforces
  minimality on read would reject bytes this crate accepts; one that
  skips it would accept a superset. **Match the source exactly, do not
  tighten.**
- **The "adjacent runs never carry equal values" guarantee is a *load-time*
  property, not an in-memory one.** It is enforced on decode
  (`rle/load.rs:203-226`, `rle/load.rs:231-259`) and assumed by every merge
  path. A port that constructs slabs directly (the
  `Column::from_slabs` route, `column.rs:1202`, taken by
  `EncoderApi::into_column`, `encoder.rs:432-443`) must re-establish it, or
  merges will produce non-canonical output that a later `load` rejects.
- **Load-time slab cutting at `max_segments / 2` vs splice-time at the full
  budget.** `RleLoadIter::new` (`rle/load.rs:195`) and
  `RleEncoder::maybe_cut` (`encoder.rs:187-215`) both cut at half, while
  `Column::with_max_segments` (`column.rs:1121`) budgets the full value and
  `check_invariants` checks against the full value
  (`column.rs:1311-1318`). A port that cuts at the full budget changes which
  documents round-trip to the same slab layout — and `save` merges boundary
  runs, so `save(load(x))` is layout-dependent even though it is
  value-identical.
- **Counting `segments` for a partial literal run.** `RleEdit::walk` only
  counts the segment once the decoder has given up the *last* item of a literal
  run (`rle/edit.rs:103-107`), and `pending_segments` returns `local + 1` for a
  `Lit` state (`rle/state.rs:336`). An off-by-one here makes the cursor cut
  slabs at the wrong point, which is invisible until a merge mis-attributes the
  tail.
- **`RleDecoderState::resume` against the wrong slab decodes garbage and does
  not detect it** (`rle/decoder.rs:150-153`, stated explicitly). Nothing
  validates it. A port that adds a debug check will find bugs the original
  tolerates; a port that omits the check is no worse than the original.
