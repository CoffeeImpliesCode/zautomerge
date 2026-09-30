# Storage engine and the columnar binary format

## Scope

Reference checkout: `~/projects/github-automerge-automerge` at commit
`ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, crate `automerge` v0.12.0
(`rust/automerge/Cargo.toml:3`), edition 2021, MSRV 1.90.0. Nothing was built or run; every
claim below is read out of the source.

### In slice (all read in full)

| Path | Lines |
|---|---|
| `rust/automerge/src/storage.rs` | 26 |
| `rust/automerge/src/storage/chunk.rs` | 312 |
| `rust/automerge/src/storage/columns.rs` | 355 |
| `rust/automerge/src/storage/columns/column.rs` | 42 |
| `rust/automerge/src/storage/columns/column_builder.rs` | 199 |
| `rust/automerge/src/storage/columns/column_specification.rs` | 340 |
| `rust/automerge/src/storage/columns/raw_column.rs` | 298 |
| `rust/automerge/src/storage/change.rs` | 523 |
| `rust/automerge/src/storage/change/change_actors.rs` | 311 |
| `rust/automerge/src/storage/change/change_op_columns.rs` | 621 |
| `rust/automerge/src/storage/change/compressed.rs` | 51 |
| `rust/automerge/src/storage/change/op_with_change_actors.rs` | 1 (empty file) |
| `rust/automerge/src/storage/bundle.rs` | 218 |
| `rust/automerge/src/storage/bundle/builder.rs` | 992 |
| `rust/automerge/src/storage/bundle/error.rs` | 46 |
| `rust/automerge/src/storage/bundle/meta.rs` | 23 |
| `rust/automerge/src/storage/bundle/storage.rs` | 334 |
| `rust/automerge/src/storage/document.rs` | 440 |
| `rust/automerge/src/storage/document/compression.rs` | 362 |
| `rust/automerge/src/storage/load.rs` | 156 |
| `rust/automerge/src/storage/load/change_collector.rs` | 15 |
| `rust/automerge/src/storage/parse.rs` | 619 |
| `rust/automerge/src/storage/parse/leb128.rs` | 302 |
| `rust/automerge/src/storage/save/document.rs` | 27 |
| `rust/automerge/src/columnar.rs` | 14 |
| `rust/automerge/src/columnar/splice_error.rs` | 47 |
| `rust/automerge/src/columnar/encoding.rs` | 67 |
| `rust/automerge/src/columnar/encoding/boolean.rs` | 197 |
| `rust/automerge/src/columnar/encoding/col_error.rs` | 88 |
| `rust/automerge/src/columnar/encoding/column_decoder.rs` | 133 |
| `rust/automerge/src/columnar/encoding/decodable_impls.rs` | 175 |
| `rust/automerge/src/columnar/encoding/delta.rs` | 96 |
| `rust/automerge/src/columnar/encoding/encodable_impls.rs` | 200 |
| `rust/automerge/src/columnar/encoding/leb128.rs` | 82 |
| `rust/automerge/src/columnar/encoding/properties.rs` | 178 (`#[cfg(test)]` only) |
| `rust/automerge/src/columnar/encoding/raw.rs` | 101 |
| `rust/automerge/src/columnar/encoding/rle.rs` | 239 |
| `rust/automerge/src/columnar/column_range.rs` | 17 |
| `rust/automerge/src/columnar/column_range/boolean.rs` | 83 |
| `rust/automerge/src/columnar/column_range/delta.rs` | 148 |
| `rust/automerge/src/columnar/column_range/generic.rs` | 93 |
| `rust/automerge/src/columnar/column_range/generic/group.rs` | 138 |
| `rust/automerge/src/columnar/column_range/generic/simple.rs` | 76 |
| `rust/automerge/src/columnar/column_range/key.rs` | 272 |
| `rust/automerge/src/columnar/column_range/obj_id.rs` | 202 |
| `rust/automerge/src/columnar/column_range/opid_list.rs` | 329 |
| `rust/automerge/src/columnar/column_range/raw.rs` | 38 |
| `rust/automerge/src/columnar/column_range/rle.rs` | 216 |
| `rust/automerge/src/columnar/column_range/value.rs` | 547 |

Total: 10 210 lines by this table's own 47 rows (`wc -l`, 2026-10-01). The
"8 372" never matched the table above it.

### Read for context only (outside the slice, cited where it defines slice-visible bytes)

* `rust/automerge/src/automerge.rs` (2 361 lines) — public save/load entry points, `LoadOptions`,
  `SaveOptions`, `OnPartialLoad`, `StringMigration`.
* `rust/automerge/src/lib.rs` (333) — module visibility, re-exports.
* `rust/automerge/src/change.rs` (428) — public `Change`, author footer, `CompressionState`.
* `rust/automerge/src/change_graph.rs` — document-chunk change column set (`ids` module at
  `change_graph.rs:1780-1798`, `ChangeGraph::encode` at `:236-273`, `validate` at `:274-293`).
* `rust/automerge/src/op_set2/columns.rs` — document-chunk op column set (`ids` module at
  `:617-660`), `OpSet::export` at `op_set2/op_set.rs:1242-1244`.
* `rust/automerge/src/error.rs` — `AutomergeError` variants raised by the storage layer.
* `rust/hexane/` — the storage engine crate that encodes **bundle** columns. Not in this slice;
  see the bundle section for exactly which of its entry points the slice depends on.

### Format documentation found in the repo

There is none. The only prose format references are external links in doc comments:
`https://alexjg.github.io/automerge-storage-docs/#_columnar_storage_format`
(`storage/columns.rs:1-22`), `#column-specifications` (`column_specification.rs:1-3`),
`#raw-value-columns` / `#group-columns` (`raw_column.rs:12-19`), `#change-chunks`
(`storage/change.rs:32-41`). `rust/automerge/README.md` and `rust/CHANGELOG.md` do not describe
the binary format. The spec of record is `https://automerge.org/automerge-binary-format-spec/`
(referenced from `rust/hexane/README.md`). Everything in the Surface and Semantics sections below
is therefore derived from the implementation, not from documentation.

## Surface

### Module graph

```rust
// rust/automerge/src/storage.rs:1-26
pub(crate) mod bundle;
pub(crate) mod change;
mod chunk;                 // <- the only private module in storage
pub(crate) mod columns;
pub(crate) mod document;
pub(crate) mod load;
pub(crate) mod parse;

pub use bundle::{Bundle, BundleChange, BundleChangeIter};
pub use load::VerificationMode;

pub(crate) use {
    bundle::{BundleMetadata, BundleStorage},
    change::{AsChangeOp, Change, ChangeOp, Compressed, ReadChangeOpError},
    chunk::{CheckSum, Chunk, ChunkType, Header},
    columns::{ColumnSpec, Columns, RawColumn, RawColumns},
    document::{CompressConfig, Document},
};

fn shift_range(range: Range<usize>, by: usize) -> Range<usize> { range.start + by..range.end + by }

pub(crate) const MAGIC_BYTES: [u8; 4] = [0x85, 0x6f, 0x4a, 0x83];
```

`mod storage;` is **private** (`rust/automerge/src/lib.rs:317`). The only public names that come
out of it are re-exported at `lib.rs:318`:

```rust
pub use storage::{Bundle, BundleChange, BundleChangeIter, VerificationMode};
pub use crate::automerge::{Automerge, LoadOptions, OnPartialLoad, SaveOptions, StringMigration};
```

### Chunk layer — `rust/automerge/src/storage/chunk.rs`

```rust
pub(crate) enum Chunk<'a> {                                        // :13-17
    Document(Document<'a>),
    Change(Change<'a, Unverified>),
    Bundle(BundleStorage<'a, Unverified>),
    CompressedChange(Change<'static, Unverified>, Compressed<'a>),
}

pub(crate) mod error {                                            // :20-50
    pub(crate) enum Chunk {
        LeftoverData,                       // "there was data in a chunk leftover after parsing"
        Leb128(#[from] parse::leb128::Error),
        Bundle(#[from] bundle::ParseError),
        Header(#[from] Header),
        Change(#[from] change::ParseError),
        Document(#[from] document::ParseError),
        Deflate,                            // "unable to decompresse compressed chunk"
    }
    pub(crate) enum Header {
        Leb128(#[from] parse::leb128::Error),
        UnknownChunkType(u8),
        InvalidMagicBytes,
    }
}

impl<'a> Chunk<'a> {
    pub(crate) fn parse(input: parse::Input<'a>)
        -> parse::ParseResult<'a, Chunk<'a>, error::Chunk>;        // :53-107
    pub(crate) fn checksum_valid(&self) -> bool;                    // :113-118
}

pub(crate) enum ChunkType { Document, Change, Compressed, Bundle } // :126-131
impl TryFrom<u8> for ChunkType { type Error = u8; }                // :134-146
impl From<ChunkType> for u8                                        // :148-157

pub(crate) struct CheckSum([u8; 4]);                               // :159-160
impl CheckSum          { pub(crate) fn bytes(&self) -> [u8; 4] }  // :162-166
impl From<[u8; 4]> for CheckSum                                    // :168-171
impl AsRef<[u8]> for CheckSum                                      // :174-177
impl From<ChangeHash> for CheckSum  // hash bytes [0..4]            // :180-185

pub(crate) struct Header {                                         // :187-193
    checksum: CheckSum, chunk_type: ChunkType,
    data_len: usize, header_size: usize, hash: ChangeHash,
}
impl Header {
    pub(crate) fn new(chunk_type: ChunkType, data: &[u8]) -> Self;  // :196-211
    pub(crate) fn with_data(&self, chunk_type: ChunkType, data: &[u8]) -> Header; // :213-225
    pub(crate) fn len(&self) -> usize;                              // :227-230
    pub(crate) fn write(&self, out: &mut Vec<u8>);                  // :232-236
    pub(crate) fn parse<E: From<error::Header>>(input: parse::Input<'_>)
        -> parse::ParseResult<'_, Header, E>;                       // :238-268
    pub(crate) fn data_bytes(&self) -> Range<usize>;                // :270-273
    pub(crate) fn hash(&self) -> ChangeHash;                        // :275-277
    pub(crate) fn checksum_valid(&self) -> bool;                    // :279-281
    pub(crate) fn checksum(&self) -> CheckSum;                      // :283-285
}

fn hash(typ: ChunkType, data: &[u8]) -> ChangeHash;                 // :300-312
```

### Column metadata layer — `rust/automerge/src/storage/columns.rs` + `columns/`

```rust
// columns.rs
pub(crate) struct MismatchingColumn { pub(crate) index: usize }     // :39-43
pub(crate) mod compression {                                        // :45-55
    pub(crate) struct Unknown;
    pub(crate) struct Uncompressed;
    pub(crate) trait ColumnCompression: std::fmt::Debug {}
    impl ColumnCompression for Unknown {}
    impl ColumnCompression for Uncompressed {}
}
pub(crate) struct Columns { columns: Vec<Column> }                  // :61-64
impl Columns {
    pub(crate) fn empty() -> Self;                                   // :66-70
    pub(crate) fn append(&mut self, col: Column);                    // :72-75
    pub(crate) fn parse2<'a, I: Iterator<Item = &'a RawColumn<compression::Uncompressed>>>(
        data_size: usize, cols: I) -> Result<Columns, BadColumnLayout>;   // :77-87
}
impl FromIterator<Column> for Result<Columns, BadColumnLayout>       // :89-104
impl IntoIterator for Columns { type Item = Column; ... }            // :106-112
pub(crate) enum BadColumnLayout { ... }                              // :118-136
//   DuplicateColumnSpecs(u32) | OutOfOrder | NestedGroup
//   LoneRawValueColumn | MismatchingValueMetadataId
//   NonContiguousColumns | DataOutOfRange
struct ColumnLayoutParser { ... }                                    // :138-146
enum LayoutParserState { Ready, InValue(AwaitingRawColumnValueBuilder), InGroup(ColumnId, GroupParseState) }
enum GroupParseState { Ready(GroupBuilder), InValue(GroupAwaitingValue) }
impl ColumnLayoutParser {
    fn new(data_size: usize, size_hint: Option<usize>) -> Self;      // :160-169
    fn build(mut self) -> Result<Columns, BadColumnLayout>;          // :170-183
    #[tracing::instrument(skip(self), err)]
    fn add_column(&mut self, column: ColumnSpec, range: Range<usize>)
        -> Result<(), BadColumnLayout>;                              // :185-320
    fn check_contiguous(&self, next_range: &Range<usize>) -> Result<(), BadColumnLayout>; // :322-350
    fn check_bounds(&self, next_range: &Range<usize>) -> Result<(), BadColumnLayout>;     // :351-355
}

// columns/column_specification.rs
pub(crate) struct ColumnSpec(u32);                                   // :5
impl PartialOrd / Ord for ColumnSpec  // Ord is on `normalize()`      // :7-17
impl ColumnSpec {
    pub(crate) const fn new(id: ColumnId, col_type: ColumnType, deflate: bool) -> Self;  // :20-29
    pub(crate) const fn new_delta(id: ColumnId) -> Self;             // :31-34
    pub(crate) const fn new_integer(id: ColumnId) -> Self;           // :35-38
    pub(crate) const fn new_string(id: ColumnId) -> Self;            // :39-42
    pub(crate) const fn new_value(id: ColumnId) -> Self;             // :43-46
    pub(crate) const fn new_value_metadata(id: ColumnId) -> Self;    // :47-50
    pub(crate) const fn new_actor(id: ColumnId) -> Self;             // :51-54
    pub(crate) const fn new_group(id: ColumnId) -> Self;             // :55-58
    pub(crate) const fn new_boolean(id: ColumnId) -> Self;           // :59-62
    pub(crate) fn col_type(&self) -> ColumnType;                     // :64-66
    pub(crate) fn id(&self) -> ColumnId;                             // :68-70
    pub(crate) fn deflate(&self) -> bool;                            // :72-74
    pub(crate) fn deflated(&self) -> Self;                           // :76-78
    pub(crate) fn inflated(&self) -> Self;                           // :80-82
    pub(crate) fn normalize(&self) -> Normalized;                    // :84-86
}
pub(crate) struct Normalized(u32);                                   // :89-90
pub(crate) struct ColumnId(u32);                                     // :109-110
impl ColumnId { pub(crate) const fn new(raw: u32) -> Self }
impl From<u32> for ColumnId                                          // :112-116
pub(crate) enum ColumnType { Group, Actor, Integer, DeltaInteger, Boolean, String, ValueMetadata, Value } // :127-136
impl ColumnType { const fn from_u8(val: u8) -> Self; const fn as_u8(&self) -> u8 }  // :137-153
impl From<u8> for ColumnType / From<ColumnType> for u8              // :175-183
impl From<u32> for ColumnSpec / From<ColumnSpec> for u32            // :185-195
impl From<[u8; 4]> for ColumnSpec  // u32::from_be_bytes             // :197-201
```

```rust
// columns/column.rs
pub(crate) struct Column { spec: ColumnSpec, range: GenericColumnRange }   // :10-14
impl Column {
    pub(crate) fn new(spec: ColumnSpec, range: GenericColumnRange) -> Column;  // :16-20
    pub(crate) fn range(&self) -> Range<usize>;                                // :22-25
    pub(crate) fn into_ranges(self) -> GenericColumnRange;                     // :27-29
    pub(crate) fn col_type(&self) -> ColumnType;                               // :31-33
    pub(crate) fn id(&self) -> ColumnId;                                       // :35-37
    pub(crate) fn spec(&self) -> ColumnSpec;                                   // :39-41
}

// columns/column_builder.rs
pub(crate) struct ColumnBuilder;                                               // :10
impl ColumnBuilder {
    pub(crate) fn build_actor(spec, range: RleRange<u64>) -> Column;            // :12-18
    pub(crate) fn build_string(spec, range: RleRange<smol_str::SmolStr>) -> Column; // :20-25
    pub(crate) fn build_integer(spec, range: RleRange<u64>) -> Column;         // :27-32
    pub(crate) fn build_delta_integer(spec, range: DeltaRange) -> Column;     // :34-39
    pub(crate) fn build_boolean(spec, range: BooleanRange) -> Column;          // :41-46
    pub(crate) fn start_value(spec, meta: RleRange<u64>) -> AwaitingRawColumnValueBuilder; // :48-53
    pub(crate) fn start_group(spec, num: RleRange<u64>) -> GroupBuilder;       // :55-62
}
pub(crate) struct AwaitingRawColumnValueBuilder { spec, meta }                 // :64-67
impl AwaitingRawColumnValueBuilder {
    pub(crate) fn id(&self) -> ColumnId;                                       // :69-72
    pub(crate) fn meta_range(&self) -> &RleRange<u64>;                        // :74-76
    pub(crate) fn build(&mut self, raw: RawRange) -> Column;                   // :78-85
}
pub(crate) struct GroupBuilder { spec, num_range, columns }                   // :86-91
impl GroupBuilder {
    pub(crate) fn range(&self) -> Range<usize>;                                // :93-102
    pub(crate) fn add_actor(&mut self, _spec, range: Range<usize>);           // :104-109
    pub(crate) fn add_string(&mut self, _spec, range: Range<usize>);          // :110-116
    pub(crate) fn add_integer(&mut self, _spec, range: Range<usize>);         // :117-122
    pub(crate) fn add_delta_integer(&mut self, _spec, range: Range<usize>);   // :123-129
    pub(crate) fn add_boolean(&mut self, _spec, range: Range<usize>);         // :130-136
    pub(crate) fn start_value(&mut self, _spec, meta: Range<usize>) -> GroupAwaitingValue; // :137-147
    pub(crate) fn finish(&mut self) -> Column;                                // :148-165
}
pub(crate) struct GroupAwaitingValue { spec, num_range, columns, val_meta }   // :167-172
impl GroupAwaitingValue {
    pub(crate) fn finish_empty(&mut self) -> GroupBuilder;                    // :174-188
    // + finish_value(range) -> GroupBuilder                                 // :190-198
}

// columns/raw_column.rs
pub(crate) struct RawColumn<T: compression::ColumnCompression> {              // :21-29
    spec: ColumnSpec,
    /// range is relative to the START OF THE COLUMN DATA BLOCK, not the chunk
    data: Range<usize>,
    _phantom: PhantomData<T>,
}
impl RawColumn<compression::Uncompressed> {
    pub(crate) fn new(spec: ColumnSpec, data: Range<usize>) -> Self;          // :31-38
    pub(crate) fn try_new(spec: ColumnSpec, data: Range<usize>) -> Option<Self>; // :40-50
}
impl<T: compression::ColumnCompression> RawColumn<T> {
    pub(crate) fn spec(&self) -> ColumnSpec;                                  // :53-56
    pub(crate) fn data(&self) -> Range<usize>;                                 // :58-60
    fn compress(&self, input, out, threshold) -> (ColumnSpec, usize);         // :62-76
    pub(crate) fn uncompressed(&self) -> Option<RawColumn<compression::Uncompressed>>; // :77-86
    fn decompress(&self, input, out) -> Result<(ColumnSpec, usize), ParseError>; // :88-103
}
pub(crate) struct RawColumns<T: compression::ColumnCompression>(pub(crate) Vec<RawColumn<T>>); // :105-106
impl<T: compression::ColumnCompression> RawColumns<T> {
    pub(crate) fn uncompressed(&self) -> Option<RawColumns<compression::Uncompressed>>;   // :108-126
    pub(crate) fn compress(&self, input, out, threshold) -> RawColumns<compression::Unknown>; // :128-147
    pub(crate) fn uncompress(&self, input, out) -> Result<RawColumns<compression::Uncompressed>, ParseError>; // :149-185
}
pub(crate) enum ParseError { NotInNormalOrder, Leb128(..), Deflate(..) }       // :207-214
impl RawColumns<compression::Unknown> {
    pub(crate) fn parse<E: From<ParseError>>(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, E>; // :217-256
}
impl<T> RawColumns<T> {
    pub(crate) fn write(&self, out: &mut Vec<u8>) -> usize;                    // :257-266
    pub(crate) fn total_column_len(&self) -> usize;                            // :267-270
    pub(crate) fn as_map(&self) -> BTreeMap<ColumnSpec, Range<usize>>;         // :271-274
    pub(crate) fn bytes<'a>(&self, c: ColumnSpec, data: &'a [u8]) -> &'a [u8]; // :275-282
    pub(crate) fn iter(&self) -> impl Iterator<Item = &RawColumn<T>> + '_;     // :284-286
}
fn are_normal_sorted<T>(cols: &[RawColumn<T>]) -> bool                          // :289-297
```

### Document chunk — `rust/automerge/src/storage/document.rs` (+ `document/compression.rs`)

```rust
pub(crate) enum CompressConfig { None, Threshold(usize) }                       // :19-22

pub(crate) struct Document<'a> {                                                // :24-36
    bytes: Cow<'a, [u8]>,                   // uncompressed body, always
    #[allow(dead_code)] compressed_bytes: Option<Cow<'a, [u8]>>,  // on-disk form, if deflated
    header: Header,
    actors: Vec<ActorId>,
    heads: Vec<ChangeHash>,
    pub(crate) op_metadata: RawColumns<Uncompressed>,
    op_bytes: Range<usize>,
    change_metadata: RawColumns<Uncompressed>,
    change_bytes: Range<usize>,
}
pub(crate) enum ParseError { Leb128(..), RawColumns(..), BadColumnLayout { column_type, error } } // :38-50
impl<'a> Document<'a> {
    pub(crate) fn parse(input: parse::Input<'a>, header: Header)
        -> parse::ParseResult<'a, Document<'a>, ParseError>;                   // :64-183
    pub(crate) fn change_meta(&self) -> &RawColumns<Uncompressed>;              // :185-188
    pub(crate) fn change_bytes(&self) -> &[u8];                                 // :190-192
    pub(crate) fn new(op_set: &OpSet, change_graph: &ChangeGraph, compress: CompressConfig)
        -> Document<'static>;                                                   // :194-279
    pub(crate) fn op_raw_bytes(&self) -> &[u8];                                 // :281-284
    pub(crate) fn into_bytes(self) -> Vec<u8>;                                  // :286-291
    pub(crate) fn checksum_valid(&self) -> bool;                                // :293-296
    pub(crate) fn actors(&self) -> &[ActorId];                                  // :298-300
    pub(crate) fn heads(&self) -> &[ChangeHash];                                // :301-304
    fn verify_changes(&self, cc: &CollectedChanges, mode: VerificationMode)
        -> Result<(), ReconstructError>;                                        // :305-321
    pub(crate) fn reconstruct(&self, mode: VerificationMode, text_encoding: TextEncoding)
        -> Result<Automerge, ReconstructError>;                                 // :323-362
    pub(crate) fn reconstruct_changes(&self, text_encoding: TextEncoding)
        -> Result<Vec<Change>, ReconstructError>;                               // :364-384
}
pub(crate) enum ReconstructError {                                             // :386-419
    InvalidChanges(..), MismatchingHeads(MismatchedHeads), InvalidOp(..), PackErr(..),
    ReadOpErr(..), InvalidActorId(usize), InvalidColumnLength(ColumnSpec),
    InvalidMaxOp, InvalidMarkOrderDoc { doc, error_message },
    InvalidMarkOrderChanges { changes, error_message }, OutOfMemory(..),
}
pub(crate) struct MismatchedHeads { changes, expected_heads, derived_heads }    // :423-428
// NOTE: OpsOutOfOrder and SuccOutOfOrder variants are commented out with FIXMEs (:388-390, :400-401)

// document/compression.rs  (all `pub(super)`)
pub(super) struct Args<'a, T, DirArgs> { original, prefix, suffix, changes, ops, extra_args }  // :9-23
pub(super) struct CompressArgs { threshold, original_header_len }              // :25-28
pub(super) fn compress(args: Args<'_, Uncompressed, CompressArgs>) -> Vec<u8>;   // :30-47
pub(super) fn decompress<'a>(args: Args<'a, Unknown, ()>)
    -> Result<Decompressed<'a>, raw_column::ParseError>;                        // :49-70
pub(super) struct Decompressed<'a> { compressed, uncompressed, ops, changes, change_bytes, op_bytes } // :72-90
struct Compression<'a, D: Direction, S: CompressionState> { args, state, direction } // :92-96
pub(super) struct Cols<T> { raw_columns: RawColumns<T>, data: Range<usize> }     // :98-108
trait Direction { type Out; type In; type Error; type Args; fn process(..) }    // :110-127
struct Compressing { threshold, header_len }  // impl Direction: Error = Infallible // :129-158
struct Decompressing;   // impl Direction: Error = raw_column::ParseError        // :160-182
// typestate: Starting -> Changes<D> -> ChangesAndOps<D> -> Finished<D>         // :184-236
```

### Change chunk — `rust/automerge/src/storage/change.rs` (+ `change/`)

```rust
pub(crate) const DEFLATE_MIN_SIZE: usize = 256;                                 // :17

pub(crate) trait OpReadState {}                                                  // :24
pub(crate) struct Verified;  pub(crate) struct Unverified;                      // :25-30
impl OpReadState for Verified {} impl OpReadState for Unverified {}

pub(crate) struct Change<'a, O: OpReadState> {                                  // :43-62
    pub(crate) bytes: Cow<'a, [u8]>,   // whole chunk including header
    pub(crate) header: Header,
    pub(crate) dependencies: Vec<ChangeHash>,
    pub(crate) actor: ActorId,
    pub(crate) other_actors: Vec<ActorId>,
    pub(crate) seq: u64,
    pub(crate) start_op: NonZeroU64,
    pub(crate) timestamp: i64,
    pub(crate) message: Option<String>,
    pub(crate) ops_meta: ChangeOpsColumns,
    pub(crate) ops_data: Range<usize>,
    pub(crate) extra_bytes: Range<usize>,
    pub(crate) num_ops: usize,
    pub(crate) _phantom: PhantomData<O>,
}
impl<O: OpReadState> PartialEq for Change<'_, O>  // compares `bytes` only    // :64-68
pub(crate) enum ParseError { Leb128, InvalidUtf8, RawColumns, Header, CompressedChangeCols, InvalidColumns(Box<dyn Error + Send + Sync>) } // :70-78
impl<'a> Change<'a, Unverified> {
    pub(crate) fn parse(input) -> ParseResult<'a, Change<'a, Unverified>, ParseError>;  // :80-93
    pub(crate) fn parse_following_header(input, header) -> ...;                   // :95-159
    pub(crate) fn iter_ops(&'a self) -> impl Iterator<Item = Result<ChangeOp, ReadChangeOpError>> + Clone + 'a; // :161-165
    pub(crate) fn verify_ops<F: FnMut(ChangeOp)>(self, f: F) -> Result<Change<'a, Verified>, ReadChangeOpError>; // :167-190
}
impl<'a> Change<'a, Verified> {
    pub(crate) fn len(&self) -> usize;                                           // :192-194
    pub(crate) fn builder() -> ChangeBuilder<Unset, Unset, Unset, Unset>;       // :196-198
    pub(crate) fn iter_ops(&'a self) -> impl Iterator<Item = ChangeOp> + Clone + 'a; // :200-207
}
impl<O: OpReadState> Change<'_, O> {
    pub(crate) fn checksum(&self) -> CheckSum;        pub(crate) fn actor(&self) -> &ActorId;
    pub(crate) fn other_actors(&self) -> &[ActorId];   pub(crate) fn start_op(&self) -> NonZeroU64;
    pub(crate) fn message(&self) -> Option<&str>;      pub(crate) fn dependencies(&self) -> &[ChangeHash];
    pub(crate) fn seq(&self) -> u64;                   pub(crate) fn timestamp(&self) -> i64;
    pub(crate) fn extra_bytes(&self) -> &[u8];         pub(crate) fn checksum_valid(&self) -> bool;
    pub(crate) fn body_bytes(&self) -> &[u8];          pub(crate) fn bytes(&self) -> &[u8];
    pub(crate) fn hash(&self) -> ChangeHash;           pub(crate) fn ops_data(&self) -> &[u8];
    pub(crate) fn into_owned(self) -> Change<'static, O>;
    pub(crate) fn compress(&self) -> Option<Compressed<'static>>;                // :209-305
}
fn length_prefixed_bytes<B: AsRef<[u8]>>(b: B, out: &mut Vec<u8>) -> usize;     // :307-311

pub(crate) struct Unset;  pub(crate) struct Set<T> { value: T }                  // :313-318
pub(crate) struct ChangeBuilder<START_OP, ACTOR, SEQ, TIME> { .. }              // :320-330
// 4-parameter typestate builder: new / with_dependencies (sorts!) / with_message /
// with_extra_bytes / with_seq / with_actor / with_start_op / with_timestamp / build
// impl ChangeBuilder<Set<NonZeroU64>, Set<ActorId>, Set<u64>, Set<i64>>::build
//   -> Result<Change<'static, Verified>, PredOutOfOrder>                       // :459-523

pub(crate) trait AsChangeOp<'a> {                                              // :450-457
    type ActorId;
    type OpId: convert::OpId<Self::ActorId>;
    type PredIter: Iterator<Item = Self::OpId> + ExactSizeIterator;
    fn obj(&self) -> convert::ObjId<Self::OpId>;
    fn key(&self) -> convert::Key<'a, Self::OpId>;
    fn insert(&self) -> bool;
    fn action(&self) -> u64;
    fn val(&self) -> Cow<'a, ScalarValue>;
    fn pred(&self) -> Self::PredIter;
    fn expand(&self) -> bool;
    fn mark_name(&self) -> Option<Cow<'a, smol_str::SmolStr>>;
}
```

```rust
// change/change_op_columns.rs
const OBJ_COL_ID:     ColumnId = ColumnId::new(0);                               // :29
const KEY_COL_ID:     ColumnId = ColumnId::new(1);                               // :30
const INSERT_COL_ID:  ColumnId = ColumnId::new(3);                               // :31
const ACTION_COL_ID:  ColumnId = ColumnId::new(4);                               // :32
const VAL_COL_ID:     ColumnId = ColumnId::new(5);                               // :33
const PRED_COL_ID:    ColumnId = ColumnId::new(7);                               // :34
const EXPAND_COL_ID:  ColumnId = ColumnId::new(9);                               // :35
const MARK_NAME_COL_ID: ColumnId = ColumnId::new(10);                            // :36
// NOTE ids 2 (id/counter) and 6, 8 are unused in change chunks

pub(crate) struct ChangeOp {                                                    // :38-48
    pub(crate) key: Key, insert: bool, val: ScalarValue, pred: Vec<OpId>,
    pub(crate) action: u64, obj: ObjId, expand: bool,
    pub(crate) mark_name: Option<smol_str::SmolStr>,
}
pub(crate) struct ChangeOpsColumns {                                            // :118-128
    obj: Option<ObjIdRange>, key: KeyRange, insert: BooleanRange, action: RleRange<u64>,
    val: ValueRange, pred: OpIdListRange, expand: MaybeBooleanRange,
    mark_name: RleRange<smol_str::SmolStr>,
}
impl From<op_set2::change::ChangeOpsColumns> for ChangeOpsColumns;               // :130-165
impl ChangeOpsColumns {
    pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> ChangeOpsIter<'a>;         // :167-180
    pub(crate) fn encode<'a,'b,'c,I,C,Op>(ops: I, out: &'b mut Vec<u8>) -> ChangeOpsColumns;  // :182-197
    pub(crate) fn encode_columnwise<..>(ops: I, out) -> ChangeOpsColumns;       // :199-231
    fn encode_rowwise<..>(ops: I, out) -> ChangeOpsColumns;                     // :233-293
    pub(crate) fn raw_columns(&self) -> RawColumns<compression::Uncompressed>;  // :300-373
}
pub enum ReadChangeOpError { DecodeError(..), InvalidOpType(..), CounterTooLarge }  // :375-382
struct ChangeOpsIter<'a> { failed, obj, key, insert, action, val, pred, expand, mark_name } // :384-394
pub enum ParseChangeColumnsError { MismatchingColumn { index: usize } }          // :445-448
impl TryFrom<RawColumns<Uncompressed>> for ChangeOpsColumns                     // :459-472
impl TryFrom<Columns> for ChangeOpsColumns                                      // :474-556
// change/change_actors.rs
pub(crate) struct ChangeActors<'a, ActorId, I, O, C> { .. }                     // :37-44
pub(crate) struct PredOutOfOrder;   // "pred OpIds out of order"                 // :46-48
impl<'a, A, I, O, C> ChangeActors<'a, A, I, O, C> {
    pub(crate) fn new(actor: A, ops: I) -> Result<Self, PredOutOfOrder>;         // :66-113
    fn translate_opid(&self, opid: &O) -> ChangeOpId;                            // :115-120
    pub(crate) fn iter<'b>(&'b self) -> WithChangeActorsOpIter<'b, 'a, A, I, O, C>; // :123-129
    pub(crate) fn done(self) -> (A, Vec<A>);                                     // :131-133
}
pub(crate) struct WithChangeActorsOpIter<'actors,'aschangeop,A,I,O,C>            // :136-140
pub(crate) struct ChangeOpId { actor: usize, counter: u64 }                     // :183-187
impl convert::OpId<usize> for ChangeOpId                                         // :189-198
pub(crate) struct WithChangeActors<'actors,'aschangeop,A,I,O,C>                 // :200-204
impl AsChangeOp<'aschangeop> for WithChangeActors<..>                            // :206-253
pub(crate) struct WithChangeActorsPredIter<'actors,'aschangeop,A,I,O,C,P>       // :255-260
fn are_sorted<A, O, I>(mut opids: I) -> bool                                    // :300-312
// change/compressed.rs
pub(crate) struct Compressed<'a> { checksum: CheckSum, bytes: Cow<'a, [u8]> }   // :7-11
impl<'a> Compressed<'a> {
    pub(crate) fn new(checksum, bytes) -> Self;                                 // :13-16
    pub(crate) fn compress<'b, O: OpReadState>(change: &'b Change<'b,O>) -> Compressed<'static>; // :18-34
    pub(crate) fn bytes(&self) -> Cow<'a, [u8]>;  pub(crate) fn checksum(&self) -> CheckSum;
    pub(crate) fn into_owned(self) -> Compressed<'static>;                       // :36-50
}
// change/op_with_change_actors.rs — EMPTY (1 byte, a single newline)
```

### Bundle — `rust/automerge/src/storage/bundle.rs` (+ `bundle/`)

```rust
// bundle.rs
pub use builder::BundleChangeIter;                                              // :16
pub(crate) use builder::{BundleBuilder, BundleChangeIterUnverified, OpIter, OpIterUnverified}; // :18
pub(crate) use error::ParseError;  pub(crate) use meta::BundleMetadata;  pub(crate) use storage::BundleStorage; // :19-21
/// EXPERIMENTAL: A set of changes compressed into a bundle
pub struct Bundle { pub(crate) storage: BundleStorage<'static, Verified> }       // :34-37
impl Bundle {
    pub(crate) fn for_hashes<I: IntoIterator<Item = ChangeHash>>(
        op_set: &OpSet, change_graph: &ChangeGraph, hashes: I) -> Result<Bundle, AutomergeError>;  // :40-53
    fn from_meta(op_set: &OpSet, changes: Vec<BundleMetadata<'_>>) -> Bundle;    // :55-77
    pub(crate) fn new_from_unverified(stored: BundleStorage<'static, Unverified>) -> Result<Self, ParseError>; // :79-85
    pub fn actors(&self) -> &[ActorId];                                          // :87-89
    pub fn authors(&self) -> &[Vec<u8>];            // always `&[]`             // :91-93
    pub fn iter_changes(&self) -> BundleChangeIter<'_>;                          // :95-97
    pub fn to_changes(&self) -> Result<Vec<Change>, AutomergeError>;              // :99-104
    pub fn bytes(&self) -> &[u8];   // compressed form if present, else `bytes`   // :106-115
    pub fn deps(&self) -> &[ChangeHash];                                         // :117-119
}
pub struct BundleChange<'a> {                                                    // :122-131
    pub actor: usize, pub author: Option<usize>, pub seq: u64, pub start_op: u64,
    pub max_op: u64, pub timestamp: i64, pub message: Option<Cow<'a, str>>,
    pub deps: Vec<u64>, pub extra: Cow<'a, [u8]>,
}
impl From<BundleChange<'a>> for BuildChangeMetadata<'a>;                          // :133-148
impl TryFrom<&'a [u8]> for Bundle { type Error = InvalidBundle; }               // :150-170
pub struct InvalidBundle(String);                                                // :172-174

// bundle/meta.rs
pub(crate) struct BundleMetadata<'a> { hash, actor, seq, max_op, timestamp, message, deps, extra, start_op, builder } // :5-17
impl BundleMetadata<'_> { pub(crate) fn num_ops(&self) -> usize }               // :19-22

// bundle/error.rs
pub(crate) enum ParseError {                                                     // :5-38
    Needed, CompressedChangeCols, CompressedOpCols,
    InvalidColumns(Box<dyn Error + Send + Sync>), Header(..),
    InvalidChangeColumn(u32), InvalidOpColumn(u32), ParseColumns(..), Leb128(..),
    ReadOpErr(..), Pack(..), Deflate(..), Unbundle(Box<dyn Error + Send + Sync>),
    InverseDecode, InverseLengthMismatch,
}
impl From<parse::ParseError<E>> for ParseError  // Incomplete => Needed         // :40-46

// bundle/storage.rs
const ID_CTR_INVERSE_COL_ID: ColumnId = ColumnId::new(11);                       // :17
const ID_COL_ID: ColumnId = ColumnId::new(2);        // legacy doc-order ID_CTR // :22
pub(crate) struct BundleStorage<'a, OpReadState> {                               // :24-45
    pub(crate) bytes: Cow<'a, [u8]>,                     // uncompressed in-memory
    pub(crate) compressed_bytes: Option<Cow<'a, [u8]>>,  // on-disk, if deflated
    pub(crate) header: Header,
    pub(crate) deps: Vec<ChangeHash>,  pub(crate) actors: Vec<ActorId>,
    pub(crate) ops_meta: RawColumns<compression::Uncompressed>,
    pub(crate) ops_data: Range<usize>,
    pub(crate) changes_meta: RawColumns<compression::Uncompressed>,
    pub(crate) changes_data: Range<usize>,
    pub(crate) id_ctr: Vec<i64>,
    pub(crate) _phantom: PhantomData<OpReadState>,
}
fn extract_id_ctr_values(changes_meta, changes_data, ops_meta, ops_data) -> Result<Vec<i64>, ParseError>; // :76-140
fn decode_delta_int(bytes: &[u8]) -> Result<Vec<i64>, ParseError>;               // :142-147
impl<'a> BundleStorage<'a, Unverified> {
    pub(crate) fn parse_following_header(input, header) -> ParseResult<'a, BundleStorage<'a, Unverified>, ParseError>; // :150-268
    pub(crate) fn verify(self) -> Result<BundleStorage<'a, Verified>, ParseError>;  // :274-295
    pub(crate) fn iter_ops(&self) -> OpIterUnverified<'_>;                       // :297-300
    fn iter_change_meta(&self) -> BundleChangeIterUnverified<'_>;                // :302-306
}
impl BundleStorage<'_, Verified> {
    pub(crate) fn to_changes(&self) -> Result<Vec<Change>, ParseError>;          // :308-321
    pub(crate) fn iter_ops(&self) -> OpIter<'_>;                                 // :323-326
    pub(crate) fn iter_change_meta(&self) -> BundleChangeIter<'_>;                // :328-331
    pub(crate) fn deps(&self) -> &[ChangeHash];                                  // :333-335
}

// bundle/builder.rs  (column ids and specs at :935-992)
pub(crate) struct BundleBuilder<'a> { mapper, change_writer, op_writer, builders, last, preds, max_op } // :42-50
impl<'a> BundleBuilder<'a> {
    pub(super) fn from_change_meta(changes: Vec<BundleMetadata<'a>>, mapper) -> BundleBuilder<'a>; // :52-95
    pub(crate) fn process_op(&mut self, op: Op<'a>);                             // :97-104
    fn process_op_internal(&mut self, op: Op<'a>, flush: bool);                  // :106-123
    pub(crate) fn process_succ(&mut self, op_id: OpId, succ_id: OpId);           // :125-128
    pub(crate) fn flush_deletes(&mut self);                                      // :130-141
    pub(crate) fn finish(mut self) -> Bundle;                                     // :143-229
    fn builders_index(&self, id: OpId) -> Option<usize>;                          // :231-246
}
fn save_opt_actor_unless_empty(enc, mapping, data) -> Range<usize>;              // :21-30
fn save_actor(enc, mapping, data) -> Range<usize>;                                // :37-44
pub(crate) struct BundleChangeWriter<'a> { .. }                                  // :248-262
pub(crate) struct BundleOpWriter<'a> { .. }                                      // :330-352
pub(crate) struct BundleOpsColumns { ..16 ranges.. }                             // :454-472
struct BundleChangeColumns { ..10 ranges.. }                                     // :475-486
impl BundleChangeColumns { fn raw_columns(&self) -> RawColumns<Uncompressed> }   // :488-506
impl BundleOpsColumns      { fn raw_columns(&self) -> RawColumns<Uncompressed> } // :508-533
struct ChangeBuilder { actor, seq, change, start_op, max_op }                    // :535-542
pub struct BundleChangeIter<'a>(BundleChangeIterUnverified<'a>);                 // :544-556
pub(crate) struct BundleChangeIterUnverified<'a> { inner: Option<..> }           // :568-572
struct BundleChangeIterInner<'a> { actor, seq, max_op, start_op, timestamp, message, dep_count, deps, extra_count, extra } // :580-592
pub(crate) struct OpIterUnverified<'a> { inner: Option<OpIterInner<'a>> }        // :740-744
pub(crate) struct OpIter<'a> { iter: OpIterUnverified<'a> }                      // :796-800
struct OpIterInner<'a> { obj_actor, obj_ctr, key_actor, key_ctr, key_str, id_actor, id_ctr, insert, action, meta, pred_count, pred_actor, pred_ctr, expand, mark_name, value } // :810-828
pub(crate) mod ops   { OBJ 0, KEY 1, ID 2, INSERT 3, ACTION 4, VAL 5, PRED 7, EXPAND 9, MARK_NAME 10, ID_CTR_INVERSE 11 } // :935-964
pub(crate) mod change { ACTOR 0, SEQ 0, START_OP 1, MAX_OP 2, TIME 3, MESSAGE 4, DEPS 5, EXTRA 6 } // :966-992
```

### Load / save orchestration — `rust/automerge/src/storage/load.rs`, `storage/save/document.rs`

```rust
// load.rs
pub enum VerificationMode { Check, DontCheck }                                   // :12-16
pub(crate) enum MarkOrderValidation { Validate, AllowInvalid }                    // :18-22
impl MarkOrderValidation { pub(crate) fn allows_invalid(self) -> bool }          // :24-28
pub enum Error { Parse, InvalidChangeColumns, InvalidOpsColumns, LeftoverData,
                 InvalidBundleColumn, InvalidBundleChange, InflateDocument,
                 BadChecksum }                                                   // :31-48
pub(crate) enum LoadedChanges<'a> { Complete(Vec<Change>), Partial { loaded, remaining, error } } // :50-68
pub(crate) fn load_changes<'a>(data: parse::Input<'a>, text_encoding: TextEncoding,
    current: &ChangeGraph, mark_order: MarkOrderValidation) -> LoadedChanges<'a>; // :74-99
fn load_next_change<'a>(data, changes, text_encoding, current, mark_order)
    -> Result<parse::Input<'a>, Error>;                                          // :101-160
pub(crate) mod change_collector;                                                 // :10
// load/change_collector.rs
pub(crate) enum Error { MissingActor, ChangesOutOfOrder, InvalidState, IncorrectMaxOp, MissingOps, MissingDep(..) } // :1-15

// save/document.rs  — DEAD CODE: `save_document` has zero callers in the workspace
pub(crate) fn save_document(op_set: &OpSet, change_graph: &ChangeGraph,
    config: Option<CompressConfig>) -> Vec<u8>;                                  // :15-27
```

### Parse layer — `rust/automerge/src/storage/parse.rs`, `storage/parse/leb128.rs`

```rust
// parse.rs
const HASH_SIZE: usize = 32;                                                      // :105
pub(crate) use self::leb128::{leb128_i64, leb128_u32, leb128_u64, nonzero_leb128_u64}; // :107-108
pub(crate) type ParseResult<'a, O, E> = Result<(Input<'a>, O), ParseError<E>>;    // :110
pub(crate) struct Input<'a> { bytes: &'a [u8], position: usize, original: &'a [u8] } // :114-118
impl<'a> Input<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self;                                   // :127-133
    fn take_1<E>(&self) -> ParseResult<'a, u8, E>;                                // :142-155
    fn take_n<E>(&self, n: usize) -> ParseResult<'a, &'a [u8], E>;               // :157-170
    fn take_4<E>(&self) -> ParseResult<'a, [u8; 4], E>;                           // :172-185
    fn range_of<P, R, E>(&self, mut parser: P) -> ParseResult<'a, RangeOf<R>, E>;  // :187-194
    fn rest<E>(&self) -> ParseResult<'a, &'a [u8], E>;                             // :196-203
    fn truncate(&self, length: usize) -> Input<'a>;                                // :205-215
    fn skip(&self, length: usize) -> Input<'a>;                                    // :217-232
    pub(crate) fn split(&self, length: usize) -> Split<'a>;                        // :234-266
    pub(crate) fn reset(&self) -> Input<'a>;                                        // :269-271
    pub(crate) fn is_empty(&self) -> bool;                                         // :273-275
    pub(crate) fn unconsumed_bytes(&self) -> &'a [u8];                              // :277-280
    pub(crate) fn bytes(&self) -> &'a [u8];   // whole original buffer              // :281-286
}
pub(crate) struct Split<'a> { pub(crate) first: Input<'a>, pub(crate) remaining: Input<'a> } // :290-303
pub(crate) trait Parser<'a, O, E> { fn parse(&mut self, input: Input<'a>) -> ParseResult<'a, O, E>; } // :305-308
impl<'a, O, F, E> Parser<'a, O, E> for F where F: FnMut(Input<'a>) -> ParseResult<'a, O, E>  // :310-317
pub(crate) enum ParseError<E> { Error(E), Incomplete(Needed) }                     // :319-325
impl<E> ParseError<E> { pub(crate) fn lift<F: From<E>>(self) -> ParseError<F> }    // :327-335
pub(crate) enum Needed { Unknown, Size(NonZeroUsize) }                             // :337-343
pub(crate) fn map<'a, O1, O2, F, G, Er>(parser: F, f: G) -> impl FnMut(Input<'a>) -> ParseResult<'a, O2, Er>; // :345-360
pub(crate) fn take1<E>(input) -> ParseResult<'_, u8, E>;                           // :362-365
pub(crate) fn take4<E>(input) -> ParseResult<'_, [u8; 4], E>;                      // :367-370
pub(crate) fn take_n<E>(n: usize, input) -> ParseResult<'_, &[u8], E>;             // :372-375
pub(crate) fn length_prefixed<'a, G, O, Er>(g: G) -> impl FnMut(Input<'a>) -> ParseResult<'a, Vec<O>, Er>; // :377-402
pub(crate) fn length_prefixed_bytes<E>(input) -> ParseResult<'_, &[u8], E>;        // :404-414
pub(super) fn tuple2<'a, F, E, G, H, Er>(f: F, g: G) -> ...;                        // :416-431
pub(super) fn apply_n<'a, F, E, Er>(n: usize, f: F) -> ...;                         // :433-447
pub(crate) fn actor_id<E>(input) -> ParseResult<'_, ActorId, E>;                    // :449-461
pub(crate) fn change_hash<E>(input) -> ParseResult<'_, ChangeHash, E>;               // :463-473
pub(crate) struct InvalidUtf8;                                                      // :475-477
pub(crate) fn utf_8<E: From<InvalidUtf8>>(len: usize, input) -> ParseResult<'_, String, E>; // :479-495
pub(crate) struct RangeOf<T> { pub(crate) range: Range<usize>, pub(crate) value: T } // :497-503
pub(crate) fn range_of<'a, P, R, E>(parser: P, input) -> ParseResult<'a, RangeOf<R>, E>; // :505-540
pub(crate) fn range_only_unless_empty<'a, P, R, E>(parser, input) -> ...;            // :542-554
pub(crate) fn range_only<'a, P, R, E>(parser, input) -> ...;                         // :556-566
pub(crate) fn take_rest<E>(input) -> ParseResult<'_, &'_ [u8], E>;                   // :568-571

// parse/leb128.rs
pub(crate) enum Error { Leb128TooLarge, Leb128Overlong, UnexpectedZero }            // :5-11
pub(crate) fn leb128_u64<E: From<Error>>(input) -> ParseResult<'_, u64, E>;         // :13-38
pub(crate) fn leb128_i64<E: From<Error>>(input) -> ParseResult<'_, i64, E>;         // :40-75
pub(crate) fn leb128_u32<E: From<Error>>(input) -> ParseResult<'_, u32, E>;         // :77-85
pub(crate) fn nonzero_leb128_u64<E: From<Error>>(input) -> ParseResult<'_, NonZeroU64, E>; // :87-97
```

### Columnar encoding — `rust/automerge/src/columnar.rs`, `columnar/encoding*`

```rust
// columnar.rs (14 lines): mod column_range; pub(crate) use column_range::Key;
//                          mod encoding; mod splice_error; pub(crate) use splice_error::SpliceError;

// columnar/encoding.rs
pub(crate) use raw::{RawDecoder, RawEncoder};                                    // :3
pub(crate) use rle::{RleDecoder, RleEncoder};                                    // :6
pub(crate) use boolean::{BooleanDecoder, BooleanEncoder, MaybeBooleanDecoder, MaybeBooleanEncoder}; // :9-10
pub(crate) use delta::{DeltaDecoder, DeltaEncoder};                              // :12
pub(crate) mod leb128;  pub(crate) mod column_decoder;  pub(crate) use column_decoder::ColumnDecoder; // :14-18
#[cfg(test)] pub(crate) mod properties;                                          // :20-21
pub(crate) trait Sink { fn append(&mut self, bytes: &[u8]); }                     // :23-25
impl Sink for &mut Vec<u8>  impl Sink for Vec<u8>                                // :27-36
pub(crate) trait Encodable { fn encode<S: Sink>(&self, out: &mut S) -> usize; }  // :38-40
pub(crate) use encodable_impls::RawBytes;                                        // :42-43
pub(crate) enum DecodeError { Io, FromInt, BadLeb(leb128::read::Error), BadLeb128(crate::storage::parse::leb128::Error), OverlargeAllocation { attempted, maximum }, BadString } // :45-58
pub(crate) trait Decodable: Sized { fn decode<R: std::io::Read>(bytes: &mut R) -> Result<Self, DecodeError>; } // :60-66
pub(crate) mod col_error;  pub(crate) use col_error::DecodeColumnError;           // :68-69
```

```rust
// encoding/raw.rs
pub(crate) struct RawDecoder<'a> { offset: usize, last_read: usize, data: Cow<'a, [u8]> } // :11-15
pub(crate) enum Error { BufferSizeDidNotChange, TryingToReadPastEnd, Decode(..) }  // :17-24
impl<'a> RawDecoder<'a> {
    pub(crate) fn new(data: Cow<'a, [u8]>) -> Self;                               // :26-32
    pub(crate) fn read<T: Decodable + Debug>(&mut self) -> Result<T, Error>;      // :34-47
    pub(crate) fn read_bytes(&mut self, index: usize) -> Result<&[u8], Error>;     // :49-60
    pub(crate) fn done(&self) -> bool;   pub(crate) fn is_empty(&self) -> bool;    // :62-68
}
impl From<&'a [u8]> for RawDecoder<'a>  impl From<Cow<'a,[u8]>> for RawDecoder<'a> // :70-82
pub(crate) struct RawEncoder<S> { written: usize, output: S }                    // :84-87
impl<S: Sink> RawEncoder<S> {
    pub(crate) fn append<B: Borrow<I>, I: Encodable>(&mut self, value: B) -> usize; // :90-94
    pub(crate) fn finish(self) -> (S, usize);                                     // :96-99
}
impl<S: Sink> From<S> for RawEncoder<S>                                           // :101-105

// encoding/rle.rs
pub(crate) struct RleEncoder<S, T: Encodable + PartialEq + Clone> { buf: S, written: usize, state: RleState<T> } // :7-12
impl<S: Sink, T: Encodable + PartialEq + Clone> RleEncoder<S, T> {
    pub(crate) fn new(output_buf: S) -> RleEncoder<S, T>;                         // :15-21
    pub(crate) fn finish(mut self) -> (S, usize);                                 // :23-38
    fn flush_run(&mut self, val: &T, len: usize);                                 // :40-43
    fn flush_null_run(&mut self, len: usize);                                    // :45-48
    fn flush_lit_run(&mut self, run: Vec<T>);                                     // :50-55
    fn take_state(&mut self) -> RleState<T>;                                      // :57-61
    pub(crate) fn append_null(&mut self);                                         // :63-81
    pub(crate) fn append_value<BT: Borrow<T>>(&mut self, value: BT);               // :83-118
    pub(crate) fn append<BT: Borrow<T>>(&mut self, value: Option<BT>);             // :120-127
    fn encode<V: Encodable>(&mut self, val: &V);                                   // :129-133
}
enum RleState<T> { Empty, InitialNullRun(usize), NullRun(usize), LiteralRun(T, Vec<T>), LoneVal(T), Run(T, usize) } // :135-147
pub(crate) struct RleDecoder<'a, T> { decoder: RawDecoder<'a>, last_value: Option<T>, count: isize, literal: bool } // :150-156
impl<T> RleDecoder<'_, T> {
    pub(crate) fn done(&self) -> bool;                                             // :158-160
    fn try_next(&mut self) -> Result<Option<Option<T>>, raw::Error>;                // :162-190
}
impl<'a, T> From<Cow<'a, [u8]>> for RleDecoder<'a, T>  impl From<&'a [u8]> for RleDecoder<'a, T> // :192-208
impl<'a, T: Clone + Debug + Decodable> Iterator for RleDecoder<'a, T> { type Item = Result<Option<T>, raw::Error>; } // :210-222

// encoding/delta.rs
pub(crate) struct DeltaEncoder<S> { rle: RleEncoder<S, i64>, absolute_value: i64 }  // :10-13
impl<S: Sink> DeltaEncoder<S> {
    pub(crate) fn new(output: S) -> DeltaEncoder<S>;                               // :15-21
    pub(crate) fn append_value(&mut self, value: i64);   // saturating_sub         // :23-27
    pub(crate) fn append_null(&mut self);                                            // :29-31
    pub(crate) fn append(&mut self, val: Option<i64>);                             // :33-39
    pub(crate) fn finish(self) -> (S, usize);                                       // :41-43
}
pub(crate) struct DeltaDecoder<'a> { rle: RleDecoder<'a, i64>, absolute_val: i64 }   // :50-54
impl DeltaDecoder<'_> { #[allow(unused)] pub(crate) fn done(&self) -> bool }      // :56-60
impl Iterator for DeltaDecoder<'_> { type Item = Result<Option<i64>, raw::Error>; } // :76-95

// encoding/boolean.rs
pub(crate) struct BooleanEncoder<S> { written, buf: S, last: bool, count: usize }  // :14-19
impl BooleanEncoder<Vec<u8>> { pub(crate) fn new() -> BooleanEncoder<Vec<u8>> }     // :21-25
impl<S: Sink> BooleanEncoder<S> {
    pub(crate) fn from_sink(sink: S) -> Self;                                      // :27-35
    pub(crate) fn append(&mut self, value: bool);                                  // :37-45
    pub(crate) fn finish(mut self) -> (S, usize);                                  // :47-53
}
pub(crate) struct BooleanDecoder<'a> { decoder: RawDecoder<'a>, last_value: bool, count: usize } // :60-64
impl Iterator for BooleanDecoder<'_> { type Item = Result<bool, raw::Error>; }   // :83-103
pub(crate) struct MaybeBooleanEncoder<S> { encoder: BooleanEncoder<S>, all_false: bool } // :109-111
impl<S: Sink> MaybeBooleanEncoder<S> {
    pub(crate) fn from_sink(buf: S) -> Self;                                       // :117-124
    pub(crate) fn append(&mut self, value: bool);                                  // :126-132
    pub(crate) fn finish(self) -> (S, usize);                                      // :134-140
}
/// Like a `BooleanDecoder` but if the underlying range is empty then just returns an infinite
/// sequence of `None`
pub(crate) struct MaybeBooleanDecoder<'a>(BooleanDecoder<'a>);                     // :145-146
impl Iterator for MaybeBooleanDecoder<'_> { type Item = Result<Option<bool>, raw::Error>; } // :163-175

// encoding/leb128.rs   (SIZING ONLY, no codec)
pub(crate) fn lebsize(mut val: i64) -> u64;                                        // :1-8
pub(crate) fn ulebsize(val: u64) -> u64;                                           // :10-16
fn leb_bytes(bits: u64) -> u64 { bits.div_ceil(7) }                                 // :18-20

// encoding/col_error.rs
pub struct DecodeColumnError { path: Path, error: DecodeColErrorKind }              // :1-4
struct Path(Vec<String>);   // Display joins with ':' in REVERSE order              // :24-38
enum DecodeColErrorKind { UnexpectedNull, InvalidValue { reason: String } }         // :49-52
impl DecodeColumnError {
    pub(crate) fn decode_raw<S: AsRef<str>>(col: S, raw_err: super::raw::Error) -> Self;  // :54-63
    pub(crate) fn unexpected_null<S: AsRef<str>>(col: S) -> Self;                   // :65-72
    pub(crate) fn invalid_value<S: AsRef<str>, R: AsRef<str>>(col: S, reason: R) -> Self; // :74-85
    pub(crate) fn in_column<S: AsRef<str>>(self, col: S) -> Self;                   // :87-93
}

// encoding/column_decoder.rs
pub(crate) trait IntoColError: std::error::Error {
    fn into_col_error<S: AsRef<str>>(self, col_name: S) -> encoding::DecodeColumnError; } // :9-12
pub(crate) trait ColumnDecoder<T>: Iterator<Item = Result<T, Self::Error>> {       // :34-49
    type Error: IntoColError;
    type Value;
    fn maybe_next_in_col<S: AsRef<str>>(&mut self, col_name: S)
        -> Result<Option<Self::Value>, encoding::DecodeColumnError>;
    fn next_in_col<S: AsRef<str>>(&mut self, col_name: S)
        -> Result<Self::Value, encoding::DecodeColumnError> { .. }                  // :43-48
}
// impls for BooleanDecoder, every Iterator<Item = Result<Option<T>, E>>, OpIdListIter,
// ValueIter, KeyIter, ObjIdIter                                               // :51-133

// encoding/encodable_impls.rs
pub(crate) struct RawBytes<'a>(Cow<'a, [u8]>);                                     // :7-7
impl Encodable for RawBytes<'_>            // no length prefix                     // :23-28
impl Encodable for SmolStr                 // uleb len + utf8 bytes                 // :30-38
impl Encodable for Cow<'_, SmolStr>  impl Encodable for String                    // :40-52
impl Encodable for Option<String>          // uleb 0 for None                     // :54-62
impl Encodable for Option<Cow<'_, SmolStr>>                                        // :64-71
impl Encodable for f64 (le bytes)  impl Encodable for f32 (le bytes)                // :73-91
impl Encodable for usize/u32 -> u64 leb   impl Encodable for i32 -> i64 leb       // :93-102
impl Encodable for [u8] / &[u8] / Cow<'_,[u8]> / Vec<u8>   // raw, no prefix      // :104-126
mod leb128_things {
    impl Encodable for u64   // unsigned LEB128, continuation bit 0x80              // :130-152
    impl Encodable for i64   // signed LEB128, sign bit kept in `val >>= 6`         // :154-179
    const CONTINUATION_BIT: u8 = 1 << 7;
}

// encoding/decodable_impls.rs
const MAX_ALLOCATION: usize = 1000000000;                                          // :10
// Decodable impls: u8, u32(try_from u64), usize, isize, i32, i64(leb128 signed),
// f64(8 LE bytes), f32(4), u64(leb128 unsigned), Vec<u8>(uleb len + bytes, caps
// at MAX_ALLOCATION), SmolStr, Cow<'static, SmolStr>, String, Option<String>
// (empty -> None), ActorId(uleb len + bytes)                              // :12-175
```

### Column ranges — `rust/automerge/src/columnar/column_range*`

```rust
// column_range.rs (17 lines): RleRange, DeltaRange, BooleanRange+MaybeBooleanRange,
// RawRange, OpIdListEncoder/OpIdListIter/OpIdListRange, ValueEncoder/ValueIter/
// ValueRange, pub(crate) mod generic, Key/KeyEncoder/KeyIter/KeyRange,
// ObjIdEncoder/ObjIdIter/ObjIdRange

// column_range/rle.rs
pub(crate) struct RleRange<T> { range: Range<usize>, _phantom: PhantomData<T> }     // :15-19
impl<T> RleRange<T> {
    pub(crate) fn decoder<'a>(&self, data: &'a [u8]) -> RleDecoder<'a, T>;         // :21-37
    pub(crate) fn is_empty / start / end                                            // :27-35
}
impl<T: Clone + Decodable + Encodable + PartialEq + Eq + Debug> RleRange<T> {
    pub(crate) fn splice<'a, I, TB, E>(&self, data, replace: Range<usize>,
        replace_with: I, out: &mut Vec<u8>) -> Result<Self, SpliceError<raw::Error, E>>; // :40-93
}
impl<T: Encodable + Clone + PartialEq> RleRange<T> {
    pub(crate) fn encoder<S: Sink>(&self, output: S) -> RleEncoder<S, T>;           // :95-98
    pub(crate) fn encode<BT: Borrow<T>, I: Iterator<Item = Option<BT>>>(items: I, out) -> Self; // :100-111
}
impl From<Range<usize>> for RleRange<T>  impl From<RleRange<T>> for Range<usize>  // :113-134

// column_range/delta.rs
pub(crate) struct DeltaRange(Range<usize>);                                        // :11-12
impl DeltaRange {
    pub(crate) fn decoder<'a>(&self, data: &'a [u8]) -> DeltaDecoder<'a>;           // :14-16
    pub(crate) fn encoder<S: Sink>(&self, output: S) -> DeltaEncoder<S>;           // :18-20
    pub(crate) fn encode<I: Iterator<Item = Option<i64>>>(items: I, out) -> Self;  // :22-29
    pub(crate) fn splice<E, I>(&self, data, replace, replace_with, out)
        -> Result<Self, SpliceError<raw::Error, E>>;                                // :31-70
}

// column_range/boolean.rs
pub(crate) struct BooleanRange(Range<usize>);                                      // :9-10
impl BooleanRange {
    pub(crate) fn decoder<'a>(&self, data: &'a [u8]) -> BooleanDecoder<'a>;         // :12-14
    pub(crate) fn encode<I: Iterator<Item = bool>>(items: I, out) -> Self;          // :16-25
}
pub struct MaybeBooleanRange(Range<usize>);                                        // :52-53
impl MaybeBooleanRange {
    pub(crate) fn decoder<'a>(&self, data: &'a [u8]) -> MaybeBooleanDecoder<'a>;   // :55-57
    pub(crate) fn encode<I: Iterator<Item = bool>>(items: I, out) -> Self;          // :59-68
    pub(crate) fn is_empty(&self) -> bool;                                          // :70-72
}

// column_range/raw.rs
pub(crate) struct RawRange(Range<usize>);                                          // :8-9
impl RawRange {
    pub(crate) fn decoder<'a>(&self, data: &'a [u8]) -> RawDecoder<'a>;             // :11-13
    pub(crate) fn is_empty(&self) -> bool;  pub(crate) fn end(&self) -> usize;      // :15-21
}

// column_range/key.rs
pub(crate) enum Key { Prop(smol_str::SmolStr), Elem(ElemId) }                      // :16-19
impl Key { pub(crate) fn map(self, actor_map: &[usize]) -> Result<KeyRef<'static>, AutomergeError> } // :21-29
pub(crate) struct KeyRange { actor: RleRange<u64>, counter: DeltaRange, string: RleRange<SmolStr> } // :31-35
impl KeyRange {
    pub(crate) fn new(actor, counter, string) -> Self;                              // :37-47
    pub(crate) fn actor_range / counter_range / string_range                        // :49-60
    pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> KeyIter<'a>;                    // :62-72
    pub(crate) fn encode<'b, O, I: Iterator<Item = convert::Key<'b,O>> + Clone>(items: I, out) -> Self; // :74-90
    pub(crate) fn splice<'b, O, E, I>(&mut self, data, replace, replace_with, out)
        -> Result<Self, SpliceError<raw::Error, E>>;                                // :92-147
}
pub(crate) struct KeyIter<'a> { actor: RleDecoder<'a,u64>, counter: DeltaDecoder<'a>, string: RleDecoder<'a,SmolStr> } // :149-153
pub(crate) struct KeyEncoder<S> { actor: RleEncoder<S,u64>, counter: DeltaEncoder<S>, string: RleEncoder<S,SmolStr> } // :205-209

// column_range/obj_id.rs
pub(crate) struct ObjIdRange { actor: RleRange<u64>, counter: RleRange<u64> }       // :14-17
impl ObjIdRange {
    pub(crate) fn new(actor: RleRange<u64>, counter: RleRange<u64>) -> Option<Self>;  // :19-27
    pub(crate) fn actor_range / counter_range                                        // :29-36
    pub(crate) fn encode<O, I: Iterator<Item = convert::ObjId<O>> + Clone>(ids: I, out) -> Option<Self>; // :38-54
    pub(crate) fn splice<O, E, I>(&self, data, replace, ids, out) -> Result<Option<Self>, SpliceError<raw::Error, E>>; // :56-100
    pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> ObjIdIter<'a>;                  // :102-110
}
fn encoded_actor<O>(id: convert::ObjId<O>) -> Option<u64>;                          // :112-120
pub(crate) struct ObjIdIter<'a> { actor: RleDecoder<'a,u64>, counter: RleDecoder<'a,u64> } // :122-125
pub(crate) struct ObjIdEncoder<S> { actor: RleEncoder<S,u64>, counter: RleEncoder<S,u64> } // :152-155

// column_range/opid_list.rs
pub(crate) struct OpIdListRange { num: RleRange<u64>, actor: RleRange<u64>, counter: DeltaRange } // :18-22
impl OpIdListRange {
    pub(crate) fn new(num, actor, counter) -> Self;                                  // :24-33
    pub(crate) fn group_range / actor_range / counter_range                           // :35-48
    pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> OpIdListIter<'a>;                // :50-59
    pub(crate) fn encode<O, I, II, IE>(opids: I, out) -> Self;                        // :61-86
    #[allow(dead_code)]
    pub(crate) fn splice<I, II, IE, R>(&self, data, replace, replace_with, out)
        -> Result<Self, SpliceError<raw::Error, R>>;                                 // :88-136
}
enum SplicingIter<E, I, F> { Failed(E), Iter(I, F) }                                 // :138-141
fn group_replace_range(replace, num: RleDecoder<'_,u64>) -> Result<Range<usize>, SpliceError<raw::Error, Infallible>>; // :163-180
pub(crate) struct OpIdListIter<'a> { num, actor, counter }                            // :182-186
pub(crate) struct OpIdListEncoder<S> { num: RleEncoder<S,u64>, actor: RleEncoder<S,u64>, counter: DeltaEncoder<S> } // :256-260

// column_range/value.rs
pub(crate) struct ValueRange { meta: RleRange<u64>, raw: RawRange }                  // :25-28
impl ValueRange {
    pub(crate) fn new(meta: RleRange<u64>, raw: RawRange) -> Self;                   // :30-32
    pub(crate) fn range(&self) -> Range<usize>;                                       // :34-41
    pub(crate) fn meta_range(&self) -> &RleRange<u64>;  pub(crate) fn raw_range(&self) -> &RawRange; // :43-52
    pub(crate) fn encode<'a,'b,I: Iterator<Item = Cow<'a, ScalarValue>> + Clone>(items: I, out) -> Self; // :54-64
    pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> ValueIter<'a>;                    // :66-73
    pub(crate) fn splice<'b, I>(&self, data, replace, replace_with, out) -> Self;      // :75-85
    pub(crate) fn try_splice<'b, I, E>(&self, data, replace, replace_with, out)
        -> Result<Self, SpliceError<raw::Error, E>>;                                 // :87-196
}
pub(crate) struct ValueIter<'a> { meta: RleDecoder<'a,u64>, raw: RawDecoder<'a> }    // :198-202
pub(crate) struct ValueEncoder<S> { meta: RleEncoder<S,u64>, raw: RawEncoder<S> }    // :333-336
fn encode_val<S: Sink>(out: &mut RawEncoder<S>, val: &ScalarValue) -> usize;         // :367-381
enum ValueType { Null, False, True, Uleb, Leb, Float, String, Bytes, Counter, Timestamp, Unknown(u8) } // :382-395
struct ValueMeta(u64);                                                                // :397-398
impl ValueMeta { fn type_code(&self) -> ValueType; fn length(&self) -> usize }        // :400-408
impl From<&ScalarValue> for ValueMeta                                                 // :415-432
impl From<u64> for ValueMeta  impl From<ValueMeta> for u64                           // :434-445
impl From<&ScalarValue> for ValueType                                                 // :446-463

// column_range/generic.rs
pub(crate) enum GenericColumnRange { Simple(SimpleColRange), Value(ValueRange), Group(GroupRange) } // :26-32
impl GenericColumnRange { pub(crate) fn range(&self) -> Range<usize> }               // :33-41
pub(crate) enum CellValue { Simple(SimpleValue), Group(Vec<Vec<SimpleValue>>) }      // :45-50
pub(crate) enum SimpleValue { Uint(Option<u64>), Int(Option<i64>), String(Option<SmolStr>), Bool(bool), Value(ScalarValue) } // :52-59
pub(crate) enum GenericColIter<'a> { Simple, Value, Group }                          // :62-67

// column_range/generic/group.rs
pub(crate) struct GroupRange { pub(crate) num: RleRange<u64>, pub(crate) values: Vec<GroupedColumnRange> } // :16-19
impl GroupRange {
    pub(crate) fn new(num: RleRange<u64>, values: Vec<GroupedColumnRange>) -> Self;  // :21-25
    #[allow(dead_code)] pub(crate) fn iter<'a>(&self, data: &'a [u8]) -> GroupIter<'a>; // :27-34
    pub(crate) fn range(&self) -> Range<usize>;                                     // :35-42
}
pub(crate) enum GroupedColumnRange { Value(ValueRange), Simple(SimpleColRange) }    // :45-48
pub(crate) struct GroupIter<'a> { num: RleDecoder<'a,u64>, values: Vec<GroupedColIter<'a>> } // :66-69
enum GroupedColIter<'a> { Value(ValueIter<'a>), Simple(SimpleColIter<'a>) }           // :111-114

// column_range/generic/simple.rs
pub(crate) enum SimpleColRange { RleInt(RleRange<u64>), RleString(RleRange<SmolStr>), Delta(DeltaRange), Boolean(BooleanRange) } // :12-20
impl SimpleColRange { pub(super) fn iter<'a>(&self, data) -> SimpleColIter<'a>; pub(crate) fn range(&self) -> Range<usize> } // :22-40
pub(crate) enum SimpleColIter<'a> { RleInt, RleString, Delta, Boolean }              // :42-47

// columnar/splice_error.rs
pub(crate) enum SpliceError<E, R> { ReadExisting(E), ReadReplace(R) }               // :9-12
impl<E> SpliceError<E, Infallible> { pub(crate) fn existing<R>(self) -> SpliceError<E, R> } // :17-26
```

### Public save/load surface — `rust/automerge/src/automerge.rs`

```rust
pub enum OnPartialLoad { Ignore, Error }                                           // :73-79
pub enum StringMigration { NoMigration, ConvertToText }                            // :82-88
pub struct LoadOptions<'a> {                                                       // :90-97
    on_partial_load: OnPartialLoad, verification_mode: VerificationMode,
    string_migration: StringMigration, patch_log: Option<&'a mut PatchLog>,
    text_encoding: TextEncoding, author: Option<Author<'static>>,
}
impl<'a> LoadOptions<'a> {
    pub fn new() -> LoadOptions<'static>;                                           // :100-103
    pub fn on_partial_load(self, OnPartialLoad) -> Self;                            // :105-114
    pub fn verification_mode(self, VerificationMode) -> Self;                        // :116-121
    pub fn patch_log(self, &'a mut PatchLog) -> Self;                               // :123-128
    pub fn migrate_strings(self, StringMigration) -> Self;                          // :130-155
    pub fn text_encoding(self, TextEncoding) -> Self;                               // :157-162
    pub fn author(self, Author<'static>) -> Self;                                   // :164-169
}
impl Default for LoadOptions<'static> {                                             // :171-186
    on_partial_load: Error, verification_mode: Check, patch_log: None,
    string_migration: NoMigration, text_encoding: TextEncoding::platform_default(), author: None,
}
pub struct SaveOptions { pub deflate: bool, pub retain_orphans: bool }               // :2329-2335
impl SaveOptions { fn compress(&self) -> CompressConfig }                            // :2337-2345
impl Default for SaveOptions { deflate: true, retain_orphans: true }                // :2347-2355

// Automerge
pub fn load(data: &[u8]) -> Result<Self, AutomergeError>                            // :833-836
pub fn load_unverified_heads(data: &[u8]) -> Result<Self, AutomergeError>            // :839-847
#[deprecated(since = "0.5.2")] pub fn load_with(data, on_error, mode, patch_log)   // :850-874
pub fn load_with_options(data: &[u8], options: LoadOptions<'_>) -> Result<Self, AutomergeError> // :876-888
pub fn rescue(data: &[u8]) -> Result<hydrate::Value, AutomergeError>                // :890-899
fn load_with_options_and_mark_validation(data, options, mark_order) -> Result<Self, AutomergeError> // :901-998
pub fn load_incremental(&mut self, data: &[u8]) -> Result<usize, AutomergeError>    // :1026-1029
pub fn load_incremental_log_patches(&mut self, data, patch_log) -> Result<usize, AutomergeError> // :1031-1065
pub fn bundle<I: IntoIterator<Item = ChangeHash>>(&self, hashes: I) -> Result<Bundle, AutomergeError> // :1140-1146
pub fn save_with_options(&self, options: SaveOptions) -> Vec<u8>                    // :1148-1158
pub fn save(&self) -> Vec<u8>                                                       // :1167-1171
pub fn save_and_verify(&self) -> Result<Vec<u8>, AutomergeError>                    // :1173-1177
pub fn save_nocompress(&self) -> Vec<u8>                                            // :1179-1185
pub fn save_after(&self, heads: &[ChangeHash]) -> Vec<u8>                           // :1187-1198
```

### Feature gates affecting this slice

Crate features (`rust/automerge/Cargo.toml:11-17`): `wasm`, `utf8-indexing`, `utf16-indexing`,
`slow_path_assertions` (enables `hexane/slow_path_assertions`). Within the slice only one
feature actually changes code: `#[cfg(feature = "slow_path_assertions")]` in
`storage/load.rs:113-121` swaps a trace statement for one that collects and logs every op of
every loaded change. `wasm` only changes the `log!`/`__log!` macro bodies
(`rust/automerge/src/lib.rs:245-262`). There are **no** `#[cfg(feature = ...)]` gates in
`storage/` or `columnar/`, and no `no_std` path.

### Storage traits named in the assignment

`Storage`, `ReadableStorage`, `WriteableStorage`, `DocInfo`, `LoadOptions`, `SaveOptions`,
`AutoSave` — a grep for `ReadableStorage|WriteableStorage|AutoSave|DocInfo` over
`rust/automerge/src` returns **zero hits** at this commit. Of the seven, only `Chunk`,
`LoadOptions` and `SaveOptions` exist. There is no pluggable storage backend, no
`Chunk`-streaming reader trait, no document-info accessor and no autosave helper. The port
target is therefore: `Automerge::{load*, save*}` over `&[u8]` in, `Vec<u8>` out, plus `Bundle`.

## Semantics

### File shape

A saved document is a **concatenation of self-delimiting chunks**. There is no chunk table, no
index, no footer and no format-version field — a grep for `version|FORMAT` over `storage/` and
`columnar/` hits only a code comment about old JS output
(`storage/document.rs:131-132`). Compatibility is carried entirely by the magic bytes and the
chunk type byte.

`Automerge::save_with_options` emits exactly one document chunk, then appends the raw bytes of
every orphan change in the queue when `retain_orphans` is set
(`automerge.rs:1148-1158`). `save_after` emits only change chunks, concatenated
(`automerge.rs:1187-1198`). The reader is therefore a loop, not a seek-and-read
(`storage/load.rs:75-99`, `automerge.rs:955-975`).

### Chunk header

```
offset  size            field
0       4               magic, [0x85, 0x6f, 0x4a, 0x83]      storage.rs:26
4       4               checksum (first 4 bytes of the change hash)
5       1               chunk type
6       uleb128         length of the chunk data, in bytes
6+n     data_len        chunk data
```

* `header_size = 4 + 4 + 1 + ulebsize(data_len)` (`chunk.rs:203-207`, `:220-224`).
* Write order is exactly the field order (`chunk.rs:232-236`).
* Chunk types: `0` Document, `1` Change, `2` Compressed, `3` Bundle
  (`chunk.rs:134-157`). Any other byte is `error::Header::UnknownChunkType(u8)`; a bad magic is
  `InvalidMagicBytes` (`chunk.rs:249-260`).
* The change hash is `SHA-256(chunk_type_byte || uleb128(data_len) || data)` (`chunk.rs:300-312`).
  The checksum field is `hash[0..4]` (`chunk.rs:180-185`). `checksum_valid` recomputes the hash
  over the parsed data and compares 4 bytes (`chunk.rs:279-281`).
* `Header::parse` computes the hash eagerly over the data it just length-delimited
  (`chunk.rs:270-273` region: `let (_, data) = parse::take_n(chunk_len as usize, i)?; let hash =
  hash(chunk_type, data);`). So every chunk read is a full SHA-256 pass; there is no lazy
  checksum.

**Compressed chunks (type 2).** The stored checksum is the checksum of the *uncompressed* change,
not of the deflate stream: `Chunk::checksum_valid` requires
`compressed.checksum() == change.checksum() && change.checksum_valid()`
(`chunk.rs:119-122`), and the writer copies the change's own checksum
(`change/compressed.rs:21`). The body is a raw DEFLATE stream of the change body with no
zlib/gzip wrapper (`chunk.rs:77-79`, `change/compressed.rs:23-30`). On read, the parser inflates,
rebuilds a synthetic `ChunkType::Change` header over the inflated bytes with
`Header::with_data` — which keeps the *original* checksum field but recomputes the hash and
length (`chunk.rs:81-100`, `chunk.rs:213-225`) — then parses the reassembled buffer and hands
back both the inflated change and the original compressed bytes (`chunk.rs:96-100`).
`Compressed::compress` is only attempted when the change exceeds `DEFLATE_MIN_SIZE = 256` bytes
(`change.rs:302-306`, `change.rs:17`); the public `Change::bytes` caches the outcome in a
three-state `CompressionState` so it never retries (`change.rs:100-116`, `:140-148`).

### Document chunk body

The authoritative layout comment is `storage/document.rs:71-101`; the writer is
`Document::new` (`document.rs:194-279`); the reader is `Document::parse` (`document.rs:64-183`).

```
Prefix
  actors      uleb count, then per actor: uleb byte length + raw bytes
  heads       uleb count, then per head: 32 raw bytes (a change hash)
  change meta RawColumns   (uleb count, then per column uleb spec + uleb byte length)
  ops meta    RawColumns
Change data  (sum of the change column byte lengths)
Ops data     (sum of the ops column byte lengths)
Suffix       heads.len() x uleb128 head index     <- OPTIONAL
```

Proven properties:

* The suffix is optional for forward compatibility with old JS output; it is parsed with
  `range_only_unless_empty`, so a completely exhausted input yields `0..0`
  (`document.rs:131-135`). When present it must contain exactly `heads.len()` LEB128 values
  (`parse::apply_n(heads.len(), parse::leb128_u64)`).
* Head indexes are indices into the change graph's internal node array, not op counters
  (`change_graph.rs:141-144`), written in the same order as `heads` (`document.rs:216-217`).
* Column data offsets inside a `RawColumns` set are relative to the start of that set's data
  block, not to the chunk (`raw_column.rs:24-26`). The data block length is
  `total_column_len()` = the sum of the per-column lengths (`raw_column.rs:267-270`), and both
  data blocks are located with `range_only` so the two lengths are read straight off the wire
  (`document.rs:120-129`).
* Nothing about contiguity or bounds is checked during `Document::parse`. Both are checked later:
  contiguity and per-column bounds by `ColumnLayoutParser::check_contiguous`/`check_bounds`
  (`columns.rs:322-355`), and the overall column set by `OpSet::validate(op_bytes.len(), &ops)`
  and `ChangeGraph::validate(change_bytes.len(), &changes)` (`document.rs:148-165`). Both
  validators run `Columns::parse2` for the layout check and then filter to the known specs
  (`change_graph.rs:274-293`).

Document chunk column sets (produced outside the slice, consumed inside it):

* **change metadata**, `change_graph.rs:1780-1798` / `:236-273`:
  `ACTOR(0,Actor) SEQ(0,Delta) MAX_OP(1,Delta) TIME(2,Delta) MESSAGE(3,String)
  DEPS_COUNT(4,Group) DEPS(4,Delta) EXTRA_META(5,ValueMetadata) EXTRA(5,Value)`.
  Note `ACTOR` and `SEQ` share column id 0 and differ by type; ordering is by
  `(id, type)` so Actor (type 1) sorts before Delta (type 3).
* **ops**, `op_set2/columns.rs:617-660`:
  `ID_ACTOR(2,Actor) ID_COUNTER(2,Delta) OBJ_ID_ACTOR(0,Actor) OBJ_ID_COUNTER(0,Integer)
  KEY_ACTOR(1,Actor) KEY_COUNTER(1,Delta) KEY_STR(1,String) SUCC_COUNT(8,Group)
  SUCC_ACTOR(8,Actor) SUCC_COUNTER(8,Delta) INSERT(3,Boolean) ACTION(4,Integer)
  VALUE_META(5,ValueMetadata) VALUE(5,Value) MARK_NAME(10,String) EXPAND(9,Boolean)` —
  16 specs, emitted in exactly that order and filtered through `FromIterator` so empty columns
  are dropped (`op_set2/columns.rs:644-661`, `raw_column.rs:174-185`).

### Per-column DEFLATE in the document chunk

`CompressConfig::Threshold(n)` compresses each column whose byte length is `>= n` and which is not
already marked deflated, setting bit `0b1000` in its spec (`raw_column.rs:62-76`,
`column_specification.rs:21-29`). `SaveOptions::deflate = true` maps to
`Threshold(DEFLATE_MIN_SIZE = 256)` (`automerge.rs:2337-2345`, `change.rs:17`).
`CompressConfig::None` is the other variant and is what `save_nocompress` selects
(`automerge.rs:1179-1185`).

The (de)compression pass is a typestate machine — `Starting -> Changes<D> -> ChangesAndOps<D> ->
Finished<D>` — with a `Direction` trait parameterised on `In`/`Out` compression witnesses, so
the same code drives both directions and the compiler rejects out-of-order steps
(`document/compression.rs:110-236`). It produces one contiguous output buffer laid out as
`prefix | change meta | change data | ops meta | ops data | suffix` (`:313-330`).

Invariant that a port must not break: `Document::new` builds the **uncompressed** header first
(`document.rs:239`) and stores *that* header in `self.header` (`:270`), then computes a second,
independently hashed compressed chunk (`document.rs:246-259`). `into_bytes` returns the
compressed bytes when they exist (`document.rs:286-291`), so the `Header` field of a
compressed `Document` does **not** describe the bytes that `into_bytes` hands out. After a
round-trip through the wire, `Document::parse` re-parses the header from the compressed bytes, so
the in-memory header is correct again (`chunk.rs:57`, `document.rs:65-68`).

`decompress` short-circuits when neither column set has the deflate bit set: it returns the
original borrowed buffer untouched and no copy is made (`document/compression.rs:49-70`).

### Change chunk body

```
deps          uleb count, then per dep: 32 raw bytes
actor         uleb byte length + raw bytes
seq           uleb128
start_op      nonzero uleb128            (0 is rejected: Error::UnexpectedZero)
timestamp     sleb128
message       uleb byte length + UTF-8 bytes
other_actors  uleb count, then per actor: uleb byte length + raw bytes
ops meta      RawColumns
ops data      sum of ops column lengths
extra bytes   remainder of the chunk (author footer)
```

* Reader `storage/change.rs:97-127`; writer `ChangeBuilder::build` `storage/change.rs:459-523`.
  The two agree field-for-field; the writer sorts `dependencies` in place before encoding
  (`change.rs:352-360`), so the on-wire dep order is not the order the caller supplied.
* `start_op` must be nonzero, enforced by `nonzero_leb128_u64` → `Error::UnexpectedZero`
  (`parse/leb128.rs:87-97`, `:6-10`).
* An empty message decodes to `None`, not `Some("")` (`change.rs:143-147`).
* `extra_bytes` is "everything after the ops data" (`change.rs:121-127`): no length prefix, no
  schema. The only defined payload is the author footer
  `uleb(id=1) || uleb(len) || bytes` (`change.rs:365-403`).
* A change chunk must contain **no compressed columns**; `RawColumns::uncompressed()` returning
  `None` is `ParseError::CompressedChangeCols` (`change.rs:129-131`). Per-column deflate exists
  only in document and bundle chunks.
* `ops_data` and `extra_bytes` are recorded as absolute ranges into the whole chunk
  (`change.rs:116-127`); the writer shifts them by the header length after hashing
  (`change.rs:501-503`).
* Verification: `Change::verify_ops` walks every op, counts them, and rejects
  `start_op > u32::MAX` with `ReadChangeOpError::CounterTooLarge`
  (`change.rs:167-190`). Only a `Verified` change exposes the infallible
  `Iterator<Item = ChangeOp>`; the infallible iterator's `unwrap` is justified purely by the type
  parameter (`change.rs:200-207`).

### Change op column layout

Emitted in this order, with empty columns omitted (`change_op_columns.rs:300-373`):

| id | type | meaning |
|---|---|---|
| 0 | Actor | `obj` actor index |
| 0 | Integer | `obj` op counter |
| 1 | Actor | `key` actor index (null for string keys) |
| 1 | DeltaInteger | `key` op counter |
| 1 | String | `key` string (null otherwise) |
| 3 | Boolean | `insert` |
| 4 | Integer | `action` |
| 5 | ValueMetadata | value metadata |
| 5 | Value | value raw bytes (only if non-empty) |
| 7 | Group | pred count |
| 7 | Actor | pred actor index (only if non-empty) |
| 7 | DeltaInteger | pred counter (only if non-empty) |
| 9 | Boolean | `expand` (only if non-empty) |
| 10 | String | `mark_name` (only if non-empty) |

* `obj` is an `Option<ObjIdRange>`: an all-root change has no obj column at all, and the reader
  substitutes `ObjId::root()` for every row (`change_op_columns.rs:171`, `:404-408`).
* `KeyRange` is three columns with a null-per-variant convention: `Prop` sets only `string`;
  `Elem(Head)` sets only `counter` to `0`; `Elem(Op)` sets `actor` and `counter`. The reader
  accepts both an explicit null and an exhausted iterator for an absent field
  (`column_range/key.rs:255-273`, `:145-183`).
* `OpIdListRange` is a *group* column: `num` (one count per row) plus `actor` and `counter`
  flattened across every row's preds (`column_range/opid_list.rs:61-86`). The counter column is
  delta-encoded, which only works because preds are emitted in ascending order.
* `PRED_COL_ID`'s `Group` spec is always written even when the group is empty
  (`change_op_columns.rs:356-360`), and an empty group means the actor/counter columns are absent
  (`change_op_columns.rs:479-490`).
* `ChangeOpsColumns::try_from(Columns)` tolerates missing columns (`unwrap_or_else(|| 0..0.into())`
  for every field, `change_op_columns.rs:540-555`) but rejects an unknown `(id, type)` pair only
  by *warning* and parking the column in `other` (`change_op_columns.rs:536-539`). Forward
  compatibility is intentional here; it is not intentional in the bundle reader
  (`bundle/builder.rs:665`, `:944` both return a hard error).
* `encode` dispatches to a rowwise encoder above 10 000 ops and a columnwise encoder below
  (`change_op_columns.rs:185-197`); both produce identical bytes, the columnwise path just
  clones the op iterator once per column.
* `ChangeOpsIter` latches `failed` on the first error and then returns `None` forever
  (`change_op_columns.rs:396-445`), so a corrupt column cannot make the reader spin.

### Actor index remapping in a change

Index 0 is the change author. Every other actor referenced by an op — via an `Elem(Op)` key, via
a predecessor, or via an `ObjId::Op` — is collected into a `BTreeSet`, the author is removed,
and the remainder is sorted lexicographically. The resulting `BTreeMap<ActorId, usize>` is the
encoding table (`change/change_actors.rs:66-113`). `done()` returns
`(author, other_actors)` for the chunk header (`change/change_actors.rs:131-133`).
`ChangeActors::new` fails with `PredOutOfOrder` if any op's `pred` is not in ascending
`(actor, counter)` order (`change_actors.rs:79-82`, `:300-312`) — this is a load-time
precondition of the delta-encoded pred counter column.

The 5 type parameters (`A, I, O, C`) exist only because generic associated types were
unavailable; the file says so (`change_actors.rs:21-36`). `OpIdListRange::encode` then needs
`I: Clone + Iterator<Item = II: ExactSizeIterator>` (`column_range/opid_list.rs:61-65`).

### Bundle chunk body

```
Prefix
  deps        uleb count, then per dep: 32 raw bytes   (external deps only)
  actors      uleb count, then per actor: uleb byte length + raw bytes
Change meta  RawColumns
Change data
Ops meta     RawColumns
Ops data
```

* Writer `BundleBuilder::finish` `bundle/builder.rs:143-229`; reader
  `BundleStorage::parse_following_header` `bundle/storage.rs:150-268`.
* There is **no suffix** and no head-index block.
* The prefix is byte-identical in the compressed and uncompressed renderings
  (`bundle/builder.rs:150-166`); everything after it is written twice, once with inflated
  columns and once with deflated columns where each column is `>= DEFLATE_MIN_SIZE`
  (`bundle/builder.rs:172-215`). `Bundle::bytes` returns the compressed rendering,
  `BundleStorage.bytes` the uncompressed one (`bundle.rs:106-115`).
* The reader takes a zero-copy fast path when nothing is deflated, and otherwise rebuilds a
  fully-inflated buffer, keeping the compressed original in `compressed_bytes`
  (`bundle/storage.rs:184-268`).
* Bundle change columns (`bundle/builder.rs:966-992`): `ACTOR(0,Actor) SEQ(0,Delta)
  START_OP(1,Delta) MAX_OP(2,Delta) TIMESTAMP(3,Delta) MESSAGE(4,String) DEP_COUNT(5,Group)
  DEPS(5,Delta) EXTRA_COUNT(6,Group) EXTRA(6,Value)`.
* Bundle op columns (`bundle/builder.rs:935-964`): `OBJ_ACTOR(0,Actor) OBJ_CTR(0,Delta)
  KEY_ACTOR(1,Actor) KEY_CTR(1,Delta) KEY_STR(1,String) ID_ACTOR(2,Actor) INSERT(3,Bool)
  ACTION(4,Integer) VALUE_META(5,ValueMetadata) VALUE(5,Value) PRED_COUNT(7,Group)
  PRED_ACTOR(7,Actor) PRED_CTR(7,Delta) EXPAND(9,Bool) MARK_NAME(10,String)
  ID_CTR_INVERSE(11,Delta)`. Column ids 6 and 8 are unused in bundles.
* Dependency indices are into the bundle's own change order; a dep that is not itself in the
  bundle gets index `changes.len() + external_index` and its hash is emitted in the chunk prefix
  (`bundle/builder.rs:277-303`).
* **Bundle columns are encoded by `hexane`, not by `columnar`.** The writer uses
  `hexane::Encoder` / `hexane::DeltaEncoder` / `hexane::Decoder` / `hexane::DeltaDecoder`
  (`bundle/builder.rs:248-352`, `:625-680`, `:810-828`). The run-header convention is the same
  as `columnar`'s RLE — hexane writes `encode_signed(count)` then the value for a repeat run,
  `encode_signed(-n)` then *n* values for a literal run, and `encode_signed(0)` then
  `encode_unsigned(count)` for a null run
  (`rust/hexane/src/rle/state.rs:684-700`), which is byte-for-byte what
  `RleEncoder::flush_run` / `flush_lit_run` / `flush_null_run` produce
  (`columnar/encoding/rle.rs:40-55`). **[INFERENCE]** Every other value type in a bundle column
  is also wire-compatible, because `rust/hexane/README.md:135-137` states the hexane byte format
  *is* the automerge document format and pins it with golden fixtures — but the per-type packing
  is hexane code outside this slice and I did not read it.
* `save_to_unless(out, sentinel)` elides an all-default column, producing an empty range which
  then disappears through the `FromIterator` filter (`bundle/builder.rs:470-478`,
  `raw_column.rs:187-205`). The actor columns go through `save_to_and_remap` /
  `save_to_unless_and_remap`, which rewrite the stored actor indices through the `ActorMapper`
  as they are copied out (`bundle/builder.rs:21-44`).
* **`ID_CTR_INVERSE` is the non-obvious part.** The writer records `(actor, counter, doc_pos)` per
  op, sorts by canonical `(actor, counter)`, and emits each op's *doc position* as a delta
  integer (`bundle/builder.rs:352-372`, `:397-424`). The comment states the motivation: for
  editing-shaped workloads the deltas are almost all `+1`. The reader walks the change metadata
  in `(actor, seq)` order, enumerates `start_op..=max_op` to obtain each op's canonical counter,
  and places it at `counters[inverse[k]]` (`bundle/storage.rs:96-137`). Length and range
  mismatches are `InverseLengthMismatch` / `InverseDecode` (`bundle/error.rs:36-38`).
  A legacy `ID_CTR` column (id 2, Delta) is still accepted and decoded directly
  (`bundle/storage.rs:17-22`, `:139-143`); the new column wins if both appear.
* `verify` walks every change metadata row and every op before the type flips to `Verified`
  (`bundle/storage.rs:274-295`). `Bundle::to_changes` then feeds the rows into
  `ChangeCollector::from_bundle_changes` and calls `unbundle`
  (`bundle/storage.rs:308-321`).
* The format is explicitly experimental and may change (`bundle.rs:23-33`).
* `Bundle::authors()` returns `&[]` unconditionally — dead accessor (`bundle.rs:91-93`).

### Columnar encoding, byte level

**Primitives.** `Encodable`/`Decodable` are the only two traits the codec is built on
(`encoding.rs:38-66`). `Sink` exists so an encoder can write into a fresh `Vec` and return it
(`finish() -> (S, usize)`) or into a caller's `&mut Vec<u8>` and just return the count
(`encoding.rs:23-36`, `raw.rs:84-99`).

| Type | Wire form | Cite |
|---|---|---|
| `u64` | unsigned LEB128, continuation bit `0x80` | `encodable_impls.rs:130-152` |
| `i64` | signed LEB128 (`val >>= 6` keeps the sign bit) | `encodable_impls.rs:154-179` |
| `usize`, `u32` | widened to `u64` then unsigned LEB128 | `encodable_impls.rs:93-100` |
| `i32` | widened to `i64` then signed LEB128 | `encodable_impls.rs:101-102` |
| `f64` / `f32` | 8 / 4 bytes little-endian, fixed width | `encodable_impls.rs:73-91` |
| `String` / `SmolStr` | uleb byte length + raw UTF-8 | `encodable_impls.rs:30-52` |
| `Option<String>` / `Option<Cow<SmolStr>>` | uleb `0` for `None`, else as the string | `encodable_impls.rs:54-71` |
| `Vec<u8>` / `[u8]` / `RawBytes` | raw bytes, **no** length prefix | `encodable_impls.rs:7-27`, `:104-126` |
| `ActorId` | uleb byte length + raw bytes | `decodable_impls.rs:162-175` |

Decoding is allocation-checked: `Vec<u8>::decode` refuses any length above
`MAX_ALLOCATION = 1_000_000_000` with `DecodeError::OverlargeAllocation`
(`decodable_impls.rs:10`, `:94-110`); strings are UTF-8 validated or `DecodeError::BadString`
(`decodable_impls.rs:112-137`); `Option<String>` maps an empty payload to `None`
(`decodable_impls.rs:140-155`).

`RawDecoder::read` decodes by handing `&[u8]` to `Decodable` and measuring the shrink; a decoder
that consumes nothing is `Error::BufferSizeDidNotChange`, which is the guard against an
infinite loop (`raw.rs:34-47`).

**Two LEB128 readers, one writer.** The write side uses the `leb128` crate
(`encodable_impls.rs:130-179`); the parse side uses a hand-rolled strict reader
(`storage/parse/leb128.rs`). The strict reader rejects overlong encodings
(`Leb128Overlong`), encodings that exceed 64 bits (`Leb128TooLarge`), and — for `i64` — a tenth
byte that is not `0` or `0x7f` (`parse/leb128.rs:22-35`, `:48-73`). `RawColumns::parse` uses a
third reader, `leb128_u32`, which is `leb128_u64` plus a `u32` range check
(`parse/leb128.rs:77-85`). A fourth implementation lives in hexane's `Codec`
(`rust/hexane/src/codec.rs:230-259`).

**RLE.** A run header is a **signed** LEB128 (`i64`) followed by a payload
(`columnar/encoding/rle.rs:162-190`):

* `count > 0` — repeat run: read one value, yield it `count` times.
* `count < 0` — literal run: yield `|count|` individually-encoded values.
* `count == 0` — null run: read an **unsigned** LEB128 count, yield `count` nulls.

The encoder only ever reaches `LiteralRun` after at least two distinct values, and a single
distinct value in a run of length 1 still costs a literal header (`rle.rs:83-118`).
**An all-null column encodes to zero bytes**: `append_null` builds an `InitialNullRun` and
`finish` emits nothing for it, deliberately (`rle.rs:63-81`, `:27-33`, `:135-147`). Therefore an
empty column, an all-null column and a truncated column are indistinguishable on the wire
(`encoding/properties.rs:38-55` documents the round-trip consequence). `RleDecoder::done()` is
`decoder.done() && count == 0` (`rle.rs:158-160`) — a run that claims more values than the
buffer holds is a decode error from `RawDecoder`, not a truncation.

**Delta.** Values are emitted as `value - previous`, signed, with `previous` starting at 0, and
then RLE'd (`columnar/encoding/delta.rs:10-13`, `:23-27`). Both directions use saturating
arithmetic (`:25` encoder, `:87` decoder), so a delta column whose deltas overflow `i64`
silently clamps rather than wrapping. A delta column does **not** reset between documents; the
running total lives entirely in the decoder's `absolute_val` field (`delta.rs:50-54`).

**Boolean.** A sequence of run counts as unsigned LEB128; the count at even index 0 is the
number of `false` values, index 1 the number of `true`, alternating (`boolean.rs:7-12`). The
encoder starts with `last = false, count = 0` and flushes the previous count on every flip
(`boolean.rs:36-45`). The decoder starts with `last_value = true` and flips before each run
(`boolean.rs:86-92`) — the two are consistent only because the first flush is a count for
`false`. `MaybeBooleanEncoder` discards everything if no `true` was ever appended
(`boolean.rs:134-140`), which is only sound because an all-`false` sequence never triggers a
flush, so the discarded buffer is empty. `MaybeBooleanDecoder` on an empty range **returns
`None` immediately** (`boolean.rs:163-175`) — the doc comment above it claiming "an infinite
sequence of `None`" is wrong. That is what makes an omitted `expand` column mean "all false".

**Value columns.** Two columns: an RLE `u64` metadata column and an opaque raw column. The
metadata is `(byte_length << 4) | type_code` (`column_range/value.rs:397-408`, `:415-432`).

| type_code | variant | length field holds | raw payload |
|---|---|---|---|
| 0 | Null | 0 | none |
| 1 | False | 0 | none |
| 2 | True | 0 | none |
| 3 | Uleb | `ulebsize(value)` | unsigned LEB128 |
| 4 | Leb | `lebsize(value)` | signed LEB128 |
| 5 | Float | `8` | 8 bytes little-endian f64 |
| 6 | String | byte length | raw UTF-8, no prefix |
| 7 | Bytes | byte length | raw bytes |
| 8 | Counter | `lebsize(start)` | signed LEB128 |
| 9 | Timestamp | `lebsize(value)` | signed LEB128 |
| >= 10 | Unknown(code) | byte length | raw bytes |

The reader reads exactly `length()` bytes, then requires the *whole* sub-slice to be consumed by
the varint decoder, else "extra bytes" (`value.rs:288-311`); a `Float` whose length is not 8 is
a hard error (`value.rs:240-252`); a length exceeding the raw column is
`DecodeColumnError::invalid_value("value", TryingToReadPastEnd)` (`value.rs:265-283`).
`lebsize`/`ulebsize` (`encoding/leb128.rs:1-20`) are *sizing* functions only — they never
encode — and are what the value metadata uses for its length field.
`ValueRange::range()` is a special case: if the raw range is empty the logical range collapses
to the metadata range, because `RawRange` is not an `Option` (`value.rs:34-41`).

**Key / ObjId / OpId-list / Group columns** are described above under the change chunk; the
decode-side null-tolerance rules are at `column_range/key.rs:145-183`,
`column_range/obj_id.rs:127-143` and `column_range/opid_list.rs:190-238`. `OpIdListIter`
pre-allocates `min(num, 100)` because `num` is attacker-controlled
(`opid_list.rs:201-206`). `ObjIdIter` treats counter `0` as root, so
`(actor: None, counter: 0)`, `(actor: None, counter: None)` and `(None, None)` all decode to the
root object (`obj_id.rs:127-136`).

**Composite column model.** `GenericColumnRange` is the lossless representation: `Simple`
(one of the four simple columns), `Value` (two columns), or `Group` (a `num` column plus zero or
more grouped columns) (`column_range/generic.rs:26-41`, `generic/group.rs:12-14`). A group row
consumes `num` values from each grouped column in lockstep (`generic/group.rs:70-97`).
`GroupRange::range()` ends at the last grouped column's end, or at the `num` column's end when
there are no grouped columns (`generic/group.rs:35-42`).

**Splicing.** Every range type supports `Vec::splice`-style in-place logical replacement
(`column_range/rle.rs:40-93`, `delta.rs:31-70`, `opid_list.rs:88-136`, `value.rs:87-196`). It
decodes, skips, and re-encodes; it does not edit bytes in place. `OpIdListRange::splice` needs
`group_replace_range` to translate a row range into a flattened element range by summing the
`num` column (`opid_list.rs:163-180`). `SpliceError<E, R>` separates "could not read the existing
column" from "the replacement iterator failed" (`columnar/splice_error.rs:9-12`).

### Column specification and layout validation

`ColumnSpec` is a `u32` laid out as `(id << 4) | type | deflate_bit`, with the type in the low 3
bits and the deflate flag at `0b1000` (`column_specification.rs:21-29`, `:137-153`). Test vectors
in the file pin the encodings: `(id 7, Group) = 112`, `(0, Actor) = 1`, `(0, Integer) = 2`,
`(1, DeltaInteger) = 19`, `(3, Boolean) = 52`, `(1, String) = 21`, `(5, ValueMetadata) = 86`,
`(5, Value) = 87` (`column_specification.rs:206-268`).

Ordering and equality are defined on `normalize()` = the spec with the deflate bit masked off
(`0b11110111`), so a deflated column and its inflated twin compare equal and sort together
(`column_specification.rs:14-17`, `:76-86`). Consequences:

* `RawColumns::parse` rejects a set that is not sorted by normalized spec with
  `ParseError::NotInNormalOrder` (`raw_column.rs:243-253`, `:289-297`).
* `ColumnLayoutParser::add_column` additionally rejects exact-duplicate specs
  (`columns.rs:203-210`) and re-checks sortedness.
* `RawColumns::bytes(spec, data)` does a `binary_search_by` over specs using that normalized
  comparison, so an inflated and a deflated spec are indistinguishable to it
  (`raw_column.rs:275-282`).
* `FromIterator for RawColumn<T>` drops every column whose range is empty, on both read and write
  (`raw_column.rs:174-185`, `:187-205`). `RawColumn::try_new` does the same
  (`raw_column.rs:40-50`).
* `RawColumn::new` on an `Uncompressed` column **forces the deflate bit off**
  (`raw_column.rs:31-38`), so re-materialising a column set after decompression cannot
  accidentally reintroduce a stale flag.

`ColumnLayoutParser` is a three-state machine that folds a flat, normalized-sorted list of raw
columns into composite logical columns (`columns.rs:138-320`):

* `Group` opens a group; a second `Group` with the same id is `NestedGroup`.
* `ValueMetadata` opens a value pair; a following `Value` with a different id is
  `MismatchingValueMetadataId`; a `Value` with no preceding metadata is `LoneRawValueColumn`.
* A group member that is neither `Group` nor `ValueMetadata` ends the group and is re-dispatched.
* `check_contiguous` requires each column's range to begin exactly where the previous logical
  column ended (`columns.rs:322-350`); `check_bounds` requires `end <= total_data_size`
  (`columns.rs:351-355`).
* `build` closes any dangling state with empty ranges, so a truncated group or value pair is
  accepted rather than rejected (`columns.rs:170-183`).
* `FromIterator for Result<Columns, BadColumnLayout>` re-checks sortedness on the write side
  (`columns.rs:89-104`).

### Parse layer

`Input<'a>` is `{bytes, position, original}`: a moving window over a borrowed buffer
(`parse.rs:114-118`). `bytes()` returns the whole original buffer, `unconsumed_bytes()` the
remainder (`parse.rs:277-286`). `split(n)` yields two `Input`s, the first truncated to `n` and
the second past it, which is how a chunk body is isolated before parsing
(`parse.rs:234-266`). `range_of` records the consumed span as a `Range<usize>` so a parser can
keep offsets into the input while validating it — this is the mechanism the document and bundle
parsers use to relocate column data after decompression
(`parse.rs:505-540`, `document.rs:71-101`, `bundle/storage.rs:151-170`).

`ParseError<E>` is `Error(E) | Incomplete(Needed)`, and `lift` maps the payload error into a
composite type while preserving `Incomplete` (`parse.rs:319-335`). `Needed::Size(NonZeroUsize)`
is a *minimum*, not an exact requirement. The whole library is allocation-free on the parse
path: every combinator borrows from `Input<'a>` and the only `Vec`s allocated are the result
collections (`length_prefixed`, `apply_n`, `range_of` callers).

`Parser` has a blanket impl for `FnMut(Input<'a>) -> ParseResult<'a, O, E>` so parsers are
plain closures and there is no dynamic dispatch (`parse.rs:305-317`). Every combinator returns
`impl FnMut(...)` — monomorphised, no trait object.

### Load and save orchestration

* `load_changes` loops over `Input`s until exhausted and returns either all changes or a partial
  result carrying the failure (`storage/load.rs:74-99`). It calls `remaining.reset()` after each
  chunk, which is why absolute and relative offsets can be mixed inside one parse.
* The checksum is verified for **every** chunk, not just the first: `load_next_change` returns
  `Error::BadChecksum` before dispatching on the type (`load.rs:100-102`), and
  `Automerge::load_with_options_and_mark_validation` does the same for the first chunk
  (`automerge.rs:907-911`).
* A document chunk encountered mid-stream is only expanded if at least one of its heads is not
  already known to the current `ChangeGraph`; otherwise its changes are discarded as already
  applied (`load.rs:104-115`).
* `save_document` in `storage/save/document.rs` has **zero callers** anywhere in the workspace —
  verified by grep over `rust/`. `Automerge::save_with_options` inlines the same logic
  (`automerge.rs:1151-1152`). Do not port it.
* `MarkOrderValidation::AllowInvalid` is only reachable from `Automerge::rescue`, which
  deliberately discards the change graph and returns hydrated values
  (`load.rs:18-28`, `automerge.rs:890-899`, `:917-921`).

## Zig mapping notes

### Direct translations

| Rust | Zig 0.16.0 |
|---|---|
| `ChunkType`, `ColumnType`, `Compression` state enums | tagged union, or `enum(u8)` for the byte-mapped ones |
| `Chunk`, `ValueType`, `LayoutParserState`, `GenericColumnRange`, `SimpleColRange`, `GroupedColumnRange` | `union(enum) { ... }` |
| `Option<T>` | `?T` |
| `Result<T, E>` | `T \| E` (anyerror sets), or a concrete `error{...}` set |
| `Cow<'a, [u8]>` | `union(enum) { borrowed: []const u8, owned: []u8 }` + a `toOwned(allocator)` helper |
| `smol_str::SmolStr` | `[]const u8` + arena, or a small-string union if the inline optimisation matters (it does not for correctness) |
| `BTreeMap` / `BTreeSet` (`ChangeActors::index`, `raw_column.as_map`, `MismatchedHeads`) | `std.AutoHashMap` / `std.StringHashMap`, or `std.ArrayList` + sort for the bundle `external` deps. **Ordering matters in exactly one place**: `ChangeActors::other_actors` must be lexicographically sorted, and `RawColumns::bytes` needs binary search — so those two need sorted containers, not hash maps |
| `HashMap` (`BundleBuilder::preds`, `BundleChangeWriter::seen`) | `std.AutoHashMap(ChangeHash, ...)` |
| `BTreeSet<ChangeHash>` (`MismatchedHeads`) | `std.AutoHashMap` or a sorted `ArrayList` |
| `iter::Iterator` with `next()` | struct with `pub fn next(self: *Self) ?Item`, or the `Iterator` interface where an erased vtable is genuinely wanted |
| `impl Iterator` in return position (`RleDecoder`, `Columns::parse2`, `load_changes`) | concrete iterator structs; `Iterator` interface only if the port needs to store them heterogeneously |
| `ExactSizeIterator::len()` | an explicit `len()` on the concrete iterator type |
| `Vec<u8>` | `std.ArrayList(u8)` — **requires threading an allocator** (see below) |
| `String::from_utf8` validation | `std.unicode.utf8ValidateSlice` |
| `f64::to_le_bytes` / `from_le_bytes` | `std.mem.writeInt(u64, v, .little)` |
| `u64::to_le_bytes` in `Hash`/`ChangeHash` | `std.mem.asBytes(&h)` / `std.mem.readInt` |
| `sha2::Sha256` | `std.crypto.hash.sha2.Sha256` |
| `BTreeSet` iteration for change deps | sorted array |
| `thiserror` `#[error("…")]` | `[]const u8` statics; the derive's `#[from]` becomes an error-set member |
| `#[derive(PartialEq, Eq, Hash, Clone, Copy, Debug)]` on a newtype | `pub const ColumnSpec = u32` plus free functions; the `normalize()`-based ordering must be written out in every comparison site |
| `Range<usize>` | `struct { start: usize, end: usize }` with `len()` |
| `phantom types` (`_phantom: PhantomData<T>`) | see below |
| typestate builder (`ChangeBuilder<START_OP, ACTOR, SEQ, TIME>`) | `comptime` function parameters, or four `?T` fields with a `build()` that returns an error union |

### No clean Zig equivalent — the hard list

1. **Associated-type traits.** `AsChangeOp<'a>` (`storage/change.rs:450-457`) carries three
   associated types (`ActorId`, `OpId`, `PredIter`) and is implemented for `&ChangeOp`,
   `&legacy::Op` and `WithChangeActors`. Zig has no traits and no associated types. The
   consequences cascade: `ChangeActors` exists as a 5-parameter generic *only* to work around the
   absence of GATs (`change_actors.rs:21-36`), and `OpIdListRange::encode` needs a nested
   `ExactSizeIterator` bound to know each row's pred count
   (`opid_list.rs:61-65`). Port strategy: make the change-op encoder take a concrete op type as
   `anytype` (or a comptime generic) and write four explicit encode paths, one per op shape, or
   normalise everything to the in-memory `ChangeOp` first (`change_op_columns.rs:38-48`) at the
   cost of one allocation per op. The `ChangeActors` remap then becomes one concrete function
   over that type, and the `BTreeMap<ActorId, usize>` is a plain field.
2. **Marker/witness type parameters.** `RawColumn<T: compression::ColumnCompression>` and
   `Change<'a, O: OpReadState>` use zero-sized marker types to encode "proved uncompressed" and
   "proved valid" in the type. Zig has no nominal zero-sized types. The load-bearing part is
   `Change::<'a, Verified>::iter_ops`, which returns `Iterator<Item = ChangeOp>` and whose
   `unwrap` is justified *only* by the type parameter (`storage/change.rs:200-207`); and
   `RawColumn<Uncompressed>::new` forcing the deflate bit off
   (`raw_column.rs:31-38`). Zig options: (a) a runtime `state: enum { unverified, verified }` field
   plus a documented precondition on the infallible iterator, which reintroduces the `unwrap` the
   type system was eliminating; (b) two distinct types, `ParsedChange` and `VerifiedChange`, where
   `verify_ops` consumes one and produces the other — this preserves the guarantee without
   generics and is the better port; (c) a `comptime` boolean. For `RawColumn<T>` the honest port
   is one type plus a `compressed: bool` carried by the column set, because the witness is only
   ever used to gate `uncompressed()`.
3. **`Cow` + `PhantomData` generics in the range types.** `RleRange<T>` is a `Range<usize>` plus
   a `PhantomData<T>`; the type parameter selects the *decoder's element type* and nothing else
   (`column_range/rle.rs:15-19`). The idiomatic Zig port is
   `fn RleDecoder(comptime T: type) type` with `RleRange` collapsing to a plain
   `struct { range: Range }`, and the element type threaded at each call site
   (`KeyRange.decoder` needs three different `T`s over the same range type — fine with `anytype`).
4. **`impl Iterator` over a tagged-union column kind.** `GenericColumnRange::iter()` conceptually
   yields `CellValue`, but each variant has a *different concrete* iterator
   (`SimpleColIter` / `ValueIter` / `GroupIter`) that are themselves unions-of-iterators
   (`column_range/generic.rs:62-93`, `generic/group.rs:111-138`, `generic/simple.rs:42-70`).
   In Zig this is `union(enum)` of iterator structs, each of which is a union of decoder states,
   with a `switch` in `next`. Three nested unions per layer, and the `GroupIter` case is a
   `std.ArrayList` of per-group-column iterators that must be built in lockstep with the `num`
   column. Note `CellValue`/`SimpleValue`/`GenericColIter` are all `#[allow(dead_code)]` in Rust
   (`generic.rs:44`, `:51`, `:61`) — the generic model exists for round-tripping unknown columns,
   and its iterators are not exercised on any current path, so a Zig port can ship the union
   types without the iterators and add them only if the re-encode path is ported.
5. **`dyn std::error::Error + Send + Sync` payloads.** `change::ParseError::InvalidColumns`,
   `bundle::ParseError::{InvalidColumns, Unbundle}`, and every variant of
   `load::Error` box an arbitrary error (`storage/change.rs:78`, `bundle/error.rs:10`, `:36`,
   `load.rs:33-46`). Zig error sets are closed and cannot be boxed polymorphically. Practical
   port: collapse each into a flat error set with a `?*const Diagnostic` side channel, or an
   error struct carrying a `[]const u8` reason built lazily. This touches the four error enums
   that the public API exposes.
6. **Three independent LEB128 implementations.** Write side: the `leb128` crate
   (`encodable_impls.rs:130-179`). Read side: the strict hand-rolled reader
   (`storage/parse/leb128.rs:13-97`). Bundle: hexane's `Codec`
   (`rust/hexane/src/codec.rs:230-259`). A Zig port must implement the *strict* rules
   (`Leb128Overlong`, `Leb128TooLarge`, the tenth-byte rule) or it will accept documents that
   Rust rejects — and, worse, emit encodings that change change hashes.
7. **DEFLATE.** `flate2` with the `zlib-rs` backend (`Cargo.toml:26`) is used for both the
   document and bundle column compression and for whole compressed change chunks
   (`raw_column.rs:62-76`, `chunk.rs:77-79`, `change/compressed.rs:23-30`). There is no DEFLATE
   in the Zig standard library. A pure-Zig port needs either a zlib binding (defeats the point)
   or a vendored zlib-rs port; and because the *bytes* only have to be valid DEFLATE streams
   (not a specific compressor's output), any correct implementation interoperates — the
   per-column deflate flag, the 256-byte threshold and the raw vs zlib wrapper choice are the
   compatibility-relevant parts, not the compressor's specific output. **[INFERENCE]** I did not
   verify that claim against a decompressor; a port must be tested against a real automerge file
   in both directions.
8. **`Sink` trait + `(S, usize)` `finish`.** `RleEncoder<S, T>` is generic over the sink so the
   same encoder can own its buffer or borrow the caller's (`encoding.rs:23-36`,
   `rle.rs:15-21`, `:29-38`). In Zig the natural shape is always writing into the caller's
   `*std.ArrayList(u8)` and returning the byte count, which also removes the `Vec::new()`
   allocation in `ValueEncoder::new` (`value.rs:341-349`). This is a simplification, not a
   translation, and it is behaviour-preserving: every caller only uses the returned length.
9. **Allocator-generic plumbing.** The Rust slice hardcodes `std` allocation: `Vec<u8>` in
   every writer, `Box<dyn Error>`, `String`, `Vec<Change>`. Zig's `std.ArrayList` is
   allocator-generic, so every one of those becomes a first-class parameter that the Rust code
   does not have. Note the read path is deliberately allocation-light — `Input`, `RawDecoder`,
   `RleDecoder`, `ValueIter` and `KeyIter` all borrow from the input buffer
   (`raw.rs:11-15`, `rle.rs:150-156`, `value.rs:198-202`, `key.rs:149-153`) — so the port should
   keep that property and only allocate for the final `Vec<Change>` / `Vec<ChangeOp>`.
10. **`unsafe` and the invariants it leans on.** There are no `unsafe` blocks in this slice, but
    there are four invariant-bearing sites a Zig port must re-establish without the borrow
    checker:
    * `self.bytes[self.data.clone()]` in `RawColumn::compress` / `decompress` panics on a range
      outside the input; the only bound check is `ColumnLayoutParser::check_bounds`, which runs
      *after* the document parse (`raw_column.rs:62-103` vs `columns.rs:351-355`).
    * `DeltaRange::splice` and `RleRange::splice` `panic!("out of bounds")` when the decoder runs
      dry before `replace.start` (`delta.rs:36`, `column_range/rle.rs:66`) — reachable from
      attacker-controlled `replace` with a short column.
    * `raw_column.rs:232-236` deliberately uses `saturating_add` for column offsets "because len
      was passed over the network", so a hostile length cannot panic there but does produce a
      range that fails `check_bounds` later.
    * `OpIdListIter` pre-allocates `min(num, 100)` for exactly this reason
      (`opid_list.rs:201-206`), and `Vec<u8>::decode` caps at 1e9
      (`decodable_impls.rs:10`). Both caps must survive the port or a malformed file becomes an
      OOM.
11. **Feature and test gates.** `#[cfg(test)] pub(crate) mod properties`
    (`encoding.rs:20-21`) and the `#[cfg(feature = "slow_path_assertions")]` trace in
    `load.rs:113-121` become `if (builtin.is_test)` and a build option respectively. `wasm` only
    changes the `log!` macro body (`lib.rs:245-262`). There is no `#[cfg(feature)]` inside
    `storage/` or `columnar/`, and no proc macro touches this slice.
12. **Not present, so nothing to port:** no `serde` impls, no `Send`/`Sync` bounds, no `no_std`
    path, no trait objects with generic methods, no GATs, no `pin`, no
    `#[cfg(feature)]`-gated public API in this slice, no `unsafe impl` marker traits.
13. **`ColumnSpec`'s normalized ordering.** `Ord for ColumnSpec` delegates to `normalize()`
    (`column_specification.rs:14-17`). Zig has no operator overloading, so every
    `std.sort.pdq` call and every `std.AutoArrayHashMap` key derivation that touches specs must
    explicitly compare `spec & 0b11110111` — a port that uses plain `u32` ordering will sort a
    deflated column differently from an inflated one and fail
    `RawColumns::parse`'s `are_normal_sorted` check on files Rust reads fine.
14. **`DecodeColumnError::Path(Vec<String>)`.** Error paths are built by `to_string()` at
    every layer and printed in reverse order joined by `:` (`col_error.rs:24-38`, `:87-93`).
    This allocates a `String` per error per column. In Zig: a fixed-size path buffer in the
    decoder state, or a `std.BoundedArray`, and lazy formatting via `writer.print`. Error-message
    *text* is not part of the format, so this is free to change.
15. **The `Parser` blanket impl for `FnMut`** (`parse.rs:310-317`) is monomorphisation, not
    dynamic dispatch. A Zig port should use plain functions, not an interface — a `?*const fn`
    field would add an indirect call to the hottest parse loop for no benefit.

### Simplifications the port can take (verified behaviour-preserving)

* Delete `storage/save/document.rs` — dead code, zero callers.
* `Bundle::authors()` — returns `&[]`, delete.
* `Compressed::bytes()` and `RleEncoder::finish` returning owned buffers — replace with
  write-into-caller plus returned length.
* `GenericColIter` / `CellValue` / `SimpleValue` — `#[allow(dead_code)]`
  (`generic.rs:44`, `:51`, `:61`); the union *types* are needed for re-encoding unknown columns,
  the iterators are not on any live path.
* `OpIdListRange::splice` — `#[allow(dead_code)]` (`opid_list.rs:88`).
* The `ChangeBuilder` 4-parameter typestate — a Zig port can use four `?T` fields.
* The compression typestate machine — replaceable by four sequential functions plus a comment
  recording the mandated order (changes, then ops, then metadata, then data, then suffix;
  `document/compression.rs:184-236`).

## Risk

**Nothing in this slice was executed.** No build, no test, no fuzz. Every byte-level claim above
is read out of the encoder and decoder source and cross-checked between them; the *interoperability*
claims (SHA-256 header, DEFLATE round-trip, hexane column compatibility) are unverified against a
real file.

Highest-risk items, hardest first:

1. **The absence of any version field makes every constant a compatibility boundary.** Magic
   bytes (`storage.rs:26`), the four chunk-type values (`chunk.rs:134-157`), the eight column
   type codes (`column_specification.rs:137-153`), the deflate bit position
   (`column_specification.rs:21-29`), the column id assignments (three separate tables: change
   chunks at `change_op_columns.rs:29-36`, bundles at `bundle/builder.rs:935-992`, document
   chunks at `change_graph.rs:1780-1798` and `op_set2/columns.rs:617-660`), the `ValueMeta`
   layout (`value.rs:397-432`), the author footer id `1` (`change.rs:365-368`), the 256-byte
   deflate threshold (`change.rs:17`) — every one of these is load-bearing and none is
   self-describing. A port that "cleans up" any of them produces files that load and then
   silently mis-decode, or fail the SHA-256 check and look like corruption.
2. **Change hashes are content hashes of these exact bytes.** `hash(chunk_type, data)` is SHA-256
   over the chunk body (`chunk.rs:300-312`), and the chunk body contains the RLE, delta, boolean
   and value encodings. Any deviation in encoding — an explicit `0` null-run header for an
   all-null column instead of zero bytes (`rle.rs:27-33`, `:135-147`), a non-canonical LEB128, a
   `MaybeBoolean` column emitted where Rust omits it (`boolean.rs:134-140`), a group column
   written when `FromIterator` would drop it (`raw_column.rs:174-185`) — changes the hash and
   breaks sync with every other automerge implementation. The round-trip property tests in
   `column_range/rle.rs:145-215` and `column_range/delta.rs:87-146` pin value equality, **not**
   byte equality; nothing in the Rust source pins the exact bytes of a document save. A Zig port
   needs golden-file tests captured from the Rust implementation before any refactoring.
3. **The compressed-document `Header` inconsistency.** `Document::new` stores the uncompressed
   header in `self.header` while `into_bytes()` may return a differently-hashed compressed chunk
   (`document.rs:239`, `:246-259`, `:270`, `:286-291`). Anything in the port that calls
   `Document.checksum_valid()` or reads `Document.header.len()` on a freshly built document gets
   a header that does not describe the emitted bytes. Model the port as *two* artefacts (uncompressed
   body+header for iteration, on-disk bytes for I/O) or normalise to one and re-verify.
4. **Validation is layered and out of order.** `RawColumns::parse` accepts any byte lengths and
   computes offsets with `saturating_add` (`raw_column.rs:218-253`); contiguity and bounds are
   checked later by `ColumnLayoutParser` (`columns.rs:322-355`); the *specific* column set is
   checked even later by `OpSet::validate` / `ChangeGraph::validate` (`document.rs:148-165`).
   A port that validates earlier, or more strictly, will reject documents Rust accepts — most
   visibly the optional head-index suffix (`document.rs:131-135`) and a truncated trailing group
   or value pair, both of which are accepted by `ColumnLayoutParser::build`
   (`columns.rs:170-183`). "Safer" is not "compatible".
5. **Bundle is a different columnar engine on the same wire format.** Bundle columns are written
   by hexane, with actor-index remapping fused into the copy-out (`bundle/builder.rs:21-44`),
   all-default elision (`save_to_unless`), and the `ID_CTR_INVERSE` permutation
   (`builder.rs:397-424`, `bundle/storage.rs:76-140`). Porting the `columnar` encoders and
   reusing them for bundles would get the run headers right but the *column set* wrong (legacy
   vs inverse `ID_CTR`), and the remap direction is easy to invert. The bundle format is also
   explicitly unstable (`bundle.rs:23-33`).
6. **Hostile-input caps are security properties, not optimizations.** `MAX_ALLOCATION = 1e9`
   (`decodable_impls.rs:10`) and `min(num, 100)` (`opid_list.rs:201-206`) plus the
   `saturating_add` offsets (`raw_column.rs:232-236`) are what stop a 20-byte file from
   allocating a terabyte. A Zig port that uses `ArrayList.ensureTotalCapacity` on a
   wire-supplied length inherits a denial-of-service. This is the one area where the port is
   strictly more dangerous than the Rust code if the caps are dropped, because Zig has no
   `Vec` length ceiling.
7. **Undocumented semantics that no test pins.** These are read from the code and are the
   likeliest to be got wrong:
   * The empty column and the all-null column are the same bytes (`rle.rs:27-33`).
   * `BooleanDecoder` starts at `last_value = true` and flips per run (`boolean.rs:86-92`); the
     encoder starts at `last = false` and only flushes on a flip (`boolean.rs:36-45`). These are
     only consistent because an all-`false` column never flushes — which is also what makes
     `MaybeBooleanEncoder::finish` able to discard the buffer (`boolean.rs:134-140`).
   * `MaybeBooleanDecoder` on an empty range returns `None` (iterator ends), contradicting its
     own doc comment (`boolean.rs:145-146` vs `:163-175`). The code is what matters, and it is
     what makes an omitted `expand` column decode as "all false".
   * `KeyIter` treats both an explicit null and an exhausted decoder as "absent"
     (`key.rs:145-183`), so a truncated key column is accepted and misread.
   * `ObjIdIter` treats counter `0` as root, so `(None, 0)` and `(None, None)` both decode to
     root (`obj_id.rs:127-136`).
   * `DeltaEncoder`/`DeltaDecoder` use saturating arithmetic, so an overflowing delta sequence
     clamps rather than wrapping (`delta.rs:25`, `:87`).
   * `ValueRange::range()` collapses to the metadata range when the raw range is empty, because
     `RawRange` is not an `Option` (`value.rs:34-41`).
   * `ColumnSpec` ordering and `RawColumn<Uncompressed>::new` both depend on masking the deflate
     bit (`column_specification.rs:84-86`, `raw_column.rs:31-38`).
8. **The `Box<dyn Error>` error model will not survive translation.** Five error enums in this
   slice box foreign errors (`storage/change.rs:78`, `bundle/error.rs:10` and `:36`, `load.rs:33-46`,
   plus `load/change_collector.rs:15`). These surface in the public API as
   `AutomergeError::{Load, Unbundle, Deflate, LoadChangeError}` (`error.rs:17`, `:58`, `:60`,
   `:78`). The Zig error surface will necessarily differ from the Rust one; decide early whether
   compatibility of *error types* matters or only error *behaviour*.
9. **Aliasing and lifetime soundness in the port.** The read path is a stack of borrow-from-`&[u8]`
   decoders (`Input` → `RawDecoder` → `RleDecoder` → `ChangeOpsIter`) whose safety rests entirely
   on Rust lifetimes. In Zig each of those becomes a struct holding a `[]const u8` plus an offset
   with no relation enforced between the two, and `RawColumn.data` is an offset into a buffer the
   struct does not own (`raw_column.rs:24-26`). The natural port of `Document<'a>` and
   `BundleStorage<'a, O>` keeps both a `bytes` buffer and absolute `Range`s into it; if the port
   stores ranges into the *original* input while also building a decompressed copy, the two go
   stale. This is where the port's `unsafe` will be, and it is not a place to be casual.
10. **No public byte-level test exists to port.** The only round-trip tests are proptest-based
    (`column_range/rle.rs:145-215`, `column_range/delta.rs:87-146`,
    `encoding/boolean.rs:179-197`, `change_op_columns.rs:558-620`) and they assert decoded
    *values*, never encoded *bytes*. hexane holds the golden byte fixtures for the column
    encodings (`rust/hexane/README.md:170-179`), not this crate. Before porting, capture byte
    goldens from the Rust implementation for: one RLE column of each run kind, one all-null
    column, one all-false boolean column, one value column per `ValueMeta` type code, one change
    chunk, one compressed change chunk, one document chunk with and without per-column deflate,
    and one bundle.
