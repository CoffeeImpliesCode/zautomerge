# Iteration, Queries, Patches, Text Diff, Marks, Cursors, Hydrate

Reference checkout: `~/projects/github-automerge-automerge` @ `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`, crate `rust/automerge` (v0.12.0, `rust/automerge/Cargo.toml:1-3`).

## Scope

Paths covered under `rust/automerge/src/`, with total line counts.

| Path | Lines | Notes |
| --- | ---: | --- |
| `iter.rs` | 25 | module root, re-export surface |
| `iter/doc.rs` | 603 | `DocIter`, `DocItem`, `DocObjItem`, internal `DiffIter` |
| `iter/keys.rs` | 90 | `Keys`; rest is `#[cfg(test)]` |
| `iter/values.rs` | 36 | `Values` |
| `iter/list_range.rs` | 441 | `ListRange`, `ListRangeItem`, internal `ListDiff` |
| `iter/map_range.rs` | 328 | `MapRange`, `MapRangeItem`, internal `MapDiff` |
| `iter/spans.rs` | 684 | `Spans`, `Span`, internal `SpansDiff`/`SpanState`/`MarkDiff` |
| `iter/tools.rs` | 626 | `Unshift`, `PeekShift`, `SkipIter`, `DiffIter`, `Diff` |
| `read.rs` | 330 | `ReadDoc` trait, `Stats` |
| `query/list_state.rs` | 230 | **dead — not compiled**, see Risk |
| `query/seek_mark.rs` | 142 | **dead — not compiled**, see Risk |
| `patches.rs` | 7 | module root |
| `patches/patch.rs` | 95 | `Patch`, `PatchAction` |
| `patches/patch_builder.rs` | 381 | `PatchBuilder` (crate-private) |
| `patches/patch_log.rs` | 779 | `PatchLog`, internal `Event`, `ExposeQueue` |
| `text_diff.rs` | 515 | Myers driver + hooks |
| `text_diff/myers.rs` | 332 | Myers O((N+M)D) + `DiffHook` trait |
| `text_diff/replace.rs` | 139 | `Replace<D>` hook decorator |
| `text_diff/utils.rs` | 119 | prefix/suffix helpers |
| `text_diff/LICENSE` | 201 | Apache-2.0, copied from `similar` |
| `marks.rs` | 541 | `Mark`, `MarkSet`, `ExpandMark`, `UpdateSpansConfig` |
| `cursor.rs` | 296 | `Cursor`, `OpCursor`, `MoveCursor`, wire format |
| `hydrate.rs` | 372 | `hydrate::Value`, macros, wasm bridge |
| `hydrate/map.rs` | 141 | `hydrate::Map`, `MapValue` |
| `hydrate/list.rs` | 149 | `hydrate::List`, `ListValue` |
| `hydrate/text.rs` | 109 | `hydrate::Text` |
| `hydrate/tests.rs` | 40 | `#[cfg(test)]` |
| `autoserde.rs` | 128 | `AutoSerde` |
| `sequence_tree.rs` | 662 | B-tree sequence, `SequenceTree<T>` |
| `anonymize.rs` | 558 | `anonymize`, `AnonymizeError` |
| `anonymize/shape.rs` | 464 | `#[cfg(test)]` only |
| `anonymize/fuzz.rs` | 200 | `#[cfg(test)]` only |

Total in slice: 10 244 lines. `query.rs` **does not exist**. `HistIter`, `LazyState`, `Length`, `KeyRange`, `ValueIter`-as-public do **not** exist in this tree; see Surface notes.

Correction to the brief: the text-diff is **not** a diff-match-patch port. It is a vendored copy of `mitsuhiko/similar` @ `2b31f65445df9093ba007ca5a5ae6a71b899d491` (Myers + replace), Apache-2.0 (`text_diff/myers.rs:1-8`, `text_diff/replace.rs:1-6`, `text_diff/utils.rs:1-7`, `text_diff/LICENSE`).

## Surface

### `iter` module root — `iter.rs:1-25`

```rust
pub use doc::{DocItem, DocIter, DocObjItem};                              // iter.rs:10
pub use keys::Keys;                                                      // iter.rs:11
pub use list_range::{ListRange, ListRangeItem};                          // iter.rs:12
pub use map_range::{MapRange, MapRangeItem};                             // iter.rs:13
pub use spans::{Span, Spans};                                            // iter.rs:14
pub use values::Values;                                                 // iter.rs:15
pub(crate) use doc::DiffIter;                                           // iter.rs:17
pub(crate) use list_range::{ListDiff, ListDiffItem};                     // iter.rs:18
pub(crate) use map_range::{MapDiff, MapDiffItem};                       // iter.rs:19
pub(crate) use tools::Diff;                                             // iter.rs:21
pub(crate) use spans::{RichTextDiff, SpanDiff, SpanInternal, SpansDiff, SpansInternal}; // iter.rs:23
#[cfg(test)] pub(crate) use keys::KeyOpIter;                            // iter.rs:24-25
```

`pub use iter::Span;` is additionally re-exported at crate root (`lib.rs:257`). `mod iter;` is `pub` (`lib.rs:264`).

### Public iterator types

```rust
// iter/doc.rs:19-23
pub struct DocIter<'a> { op_set: Option<&'a OpSet>, obj_export: Arc<ExId>, inner: DocIterInternal<'a> }
impl<'a> Iterator for DocIter<'a> { type Item = DocObjItem<'a>; }        // iter/doc.rs:291-303

// iter/doc.rs:337-340
pub struct DocObjItem<'a> { pub obj: Arc<ExId>, pub item: DocItem<'a> }
impl<'a> DocObjItem<'a> {
    pub fn key(&self) -> Option<&str>                                     // iter/doc.rs:365-371
    pub fn value(&self) -> Option<ValueRef<'a>>                           // iter/doc.rs:373-380
}

// iter/doc.rs:383-387
pub enum DocItem<'a> { Map(MapRangeItem<'a>), List(ListRangeItem<'a>), Text(Span) }
impl<'a> DocItem<'a> {
    pub fn id(&self) -> Option<ExId>                                      // iter/doc.rs:492-500
    pub fn value(&self) -> Option<&ValueRef<'a>>                          // iter/doc.rs:502-510
}

// iter/keys.rs:8-10
pub struct Keys<'a> { pub(crate) iter: Option<(&'a OpSet, TopOps<'a>)> }
impl Iterator for Keys<'_> { type Item = String; }                       // iter/keys.rs:12-19

// iter/values.rs:9-11
pub struct Values<'a> { iter: Option<(&'a OpSet, Box<dyn OpQueryTerm<'a> + 'a>)> }
impl<'a> Iterator for Values<'a> { type Item = (types::Value<'a>, ExId); } // iter/values.rs:26-35

// iter/list_range.rs:15-19
pub struct ListRangeItem<'a> { pub index: usize, pub value: ValueRef<'a>, pub conflict: bool,
                              pub(crate) maybe_exid: ExIdPromise<'a> }
impl ListRangeItem<'_> {
    pub(crate) fn op_id(&self) -> OpId                                    // iter/list_range.rs:23-25
    pub fn id(&self) -> ExId                                              // iter/list_range.rs:27-29
    pub fn into_owned(self) -> ListRangeItem<'static>                     // iter/list_range.rs:30-38
}

// iter/list_range.rs:256-259
pub struct ListRange<'a> { iter: ListDiff<'a>, range: Range<usize> }
impl<'a> Iterator for ListRange<'a> { type Item = ListRangeItem<'a>; }    // iter/list_range.rs:345-357

// iter/map_range.rs:14-20
pub struct MapRangeItem<'a> { pub key: Cow<'a, str>, pub value: ValueRef<'a>, pub conflict: bool,
                              pub(crate) pos: usize, pub(crate) maybe_exid: ExIdPromise<'a> }
impl MapRangeItem<'_> {
    pub(crate) fn op_id(&self) -> OpId                                    // iter/map_range.rs:23-25
    pub fn id(&self) -> ExId                                              // iter/map_range.rs:27-29
    pub fn into_owned(self) -> MapRangeItem<'static>                      // iter/map_range.rs:31-40
}

// iter/map_range.rs:95-97
pub struct MapRange<'a> { iter: MapDiff<'a> }
impl<'a> Iterator for MapRange<'a> { type Item = MapRangeItem<'a>; }     // iter/map_range.rs:99-105

// iter/spans.rs:286-288
pub struct Spans<'a> { internal: SpansInternal<'a> }
impl Iterator for Spans<'_> { type Item = Span; }                        // iter/spans.rs:635-645

// iter/spans.rs:410-418
pub enum Span {
    Text { text: String, marks: Option<Arc<MarkSet>> },
    Block(crate::hydrate::Map),
}
impl Span { pub fn as_str(&self) -> &str }                                // iter/spans.rs:420-427
```

Absent public types (checked crate-wide, no alternate spelling found): `iter::Iter`, `KeyRange`, `Length`, `HistIter`, `LazyState`, `ValueIter`. `ValueIter` exists only as `op_set2/op_set/op_iter.rs:866 pub(crate) struct ValueIter<'a>` (crate-private). `sequence_tree::Iter` is `pub` but lives in a private module and is not re-exported (`lib.rs:283 mod sequence_tree;` re-exports only `SequenceTree`, `lib.rs:316`) — yet it is the return type of the public `SequenceTree::iter`, so it is an unnameable leaked type.

### `ReadDoc` — the public query/iteration entry points — `read.rs:21-307`

```rust
pub trait ReadDoc {
    fn parents<O: AsRef<ExId>>(&self, obj: O) -> Result<Parents<'_>, AutomergeError>;              // read.rs:35
    fn parents_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash])
        -> Result<Parents<'_>, AutomergeError>;                                                   // read.rs:40-48
    fn keys<O: AsRef<ExId>>(&self, obj: O) -> Keys<'_>;                                          // read.rs:50
    fn keys_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Keys<'_>;                 // read.rs:55
    fn iter_at<O: AsRef<ExId>>(&self, obj: O, heads: Option<&[ChangeHash]>) -> DocIter<'_>;       // read.rs:60
    fn iter(&self) -> DocIter<'_> { self.iter_at(&ROOT, None) }                                  // read.rs:74-76 (default)
    fn map_range<'a, O: AsRef<ExId>, R: RangeBounds<String> + 'a>(&'a self, obj: O, range: R)
        -> MapRange<'a>;                                                                           // read.rs:84-90
    fn map_range_at<'a, O: AsRef<ExId>, R: RangeBounds<String> + 'a>(&'a self, obj: O, range: R,
        heads: &[ChangeHash]) -> MapRange<'a>;                                                     // read.rs:99-107
    fn list_range<O: AsRef<ExId>, R: RangeBounds<usize>>(&self, obj: O, range: R)
        -> ListRange<'_>;                                                                         // read.rs:110
    fn list_range_at<O: AsRef<ExId>, R: RangeBounds<usize>>(&self, obj: O, range: R,
        heads: &[ChangeHash]) -> ListRange<'_>;                                                   // read.rs:118-126
    fn values<O: AsRef<ExId>>(&self, obj: O) -> Values<'_>;                                      // read.rs:129
    fn values_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> Values<'_>;             // read.rs:137
    fn length<O: AsRef<ExId>>(&self, obj: O) -> usize;                                            // read.rs:142
    fn length_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash]) -> usize;                   // read.rs:149
    fn object_type<O: AsRef<ExId>>(&self, obj: O) -> Result<ObjType, AutomergeError>;              // read.rs:152
    fn marks<O: AsRef<ExId>>(&self, obj: O) -> Result<Vec<Mark>, AutomergeError>;                 // read.rs:155
    fn marks_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash])
        -> Result<Vec<Mark>, AutomergeError>;                                                      // read.rs:161-166
    fn get_marks<O: AsRef<ExId>>(&self, obj: O, index: usize, heads: Option<&[ChangeHash]>)
        -> Result<MarkSet, AutomergeError>;                                                        // read.rs:175-180
    fn text<O: AsRef<ExId>>(&self, obj: O) -> Result<String, AutomergeError>;                      // read.rs:186
    fn text_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash])
        -> Result<String, AutomergeError>;                                                         // read.rs:192-197
    fn spans<O: AsRef<ExId>>(&self, obj: O) -> Result<Spans<'_>, AutomergeError>;                 // read.rs:200
    fn spans_at<O: AsRef<ExId>>(&self, obj: O, heads: &[ChangeHash])
        -> Result<Spans<'_>, AutomergeError>;                                                      // read.rs:205-211
    fn get_cursor<O: AsRef<ExId>, I: Into<CursorPosition>>(&self, obj: O, position: I,
        at: Option<&[ChangeHash]>) -> Result<Cursor, AutomergeError>;                               // read.rs:222-227
    fn get_cursor_moving<O: AsRef<ExId>, I: Into<CursorPosition>>(&self, obj: O, position: I,
        at: Option<&[ChangeHash]>, move_cursor: MoveCursor) -> Result<Cursor, AutomergeError>;     // read.rs:245-251
    fn get_cursor_position<O: AsRef<ExId>>(&self, obj: O, cursor: &Cursor,
        at: Option<&[ChangeHash]>) -> Result<usize, AutomergeError>;                                 // read.rs:262-267
    fn get<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P)
        -> Result<Option<(Value<'_>, ExId)>, AutomergeError>;                                       // read.rs:285-289
    fn get_at<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P, heads: &[ChangeHash])
        -> Result<Option<(Value<'_>, ExId)>, AutomergeError>;                                       // read.rs:293-299
    fn hydrate<O: AsRef<ExId>>(&self, obj: O, heads: Option<&[ChangeHash]>)
        -> Result<hydrate::Value, AutomergeError>;                                                  // read.rs:301-304
    fn get_all<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P)
        -> Result<Vec<(Value<'_>, ExId)>, AutomergeError>;                                          // read.rs:312-316
    fn get_all_at<O: AsRef<ExId>, P: Into<Prop>>(&self, obj: O, prop: P, heads: &[ChangeHash])
        -> Result<Vec<(Value<'_>, ExId)>, AutomergeError>;                                          // read.rs:321-327
    fn get_missing_deps(&self, heads: &[ChangeHash]) -> Vec<ChangeHash>;                            // read.rs:302
    fn get_change_by_hash(&self, hash: &ChangeHash) -> Option<Change>;                              // read.rs:305
    fn stats(&self) -> Stats;                                                                        // read.rs:307
    fn text_encoding(&self) -> TextEncoding;                                                         // read.rs:309
}

// read.rs:313-329
pub struct Stats { pub num_ops: u64, pub num_changes: u64, pub num_actors: u64,
                   pub cargo_package_name: &'static str, pub cargo_package_version: &'static str,
                   pub rustc_version: &'static str }
```

`Automerge::hydrate(&self, heads: Option<&[ChangeHash]>) -> hydrate::Value` (root only) is an inherent method, not on the trait: `automerge.rs:1634-1637`.

Crate-private backing constructors (all `pub(crate)`, the only way to build an iterator):

```rust
pub(crate) fn Keys::new(op_set: &'a OpSet, iter: TopOps<'a>) -> Self          // iter/keys.rs:23
pub(crate) fn Values::new<I: OpQueryTerm<'a> + 'a>(op_set: &'a OpSet,
        iter: I, _clock: Option<Clock>) -> Self                                // iter/values.rs:15-24
pub(crate) fn ListRange::new<R: RangeBounds<usize>>(op_set: &'a OpSet,
        obj_range: Range<usize>, clock: Option<Clock>, range: R) -> Self        // iter/list_range.rs:324-334
pub(crate) fn MapRange::new(op_set: &'a OpSet, range: Range<usize>,
        clock: Option<Clock>) -> Self                                          // iter/map_range.rs:204-208
pub(crate) fn Spans::new(internal: SpansInternal<'_>) -> Spans<'_>             // iter/spans.rs:630-632
```

`OpSet` entry points that produce them: `op_set2/op_set.rs:377` `keys`, `:381` `spans`, `:386` `list_range`, `:396` `map_range`.

`Automerge` plumbing helpers, all `pub(crate)`, all returning the *default* (empty) iterator on an unknown object id rather than erroring:

```rust
fn keys_for(&self, obj: &ExId, clock: Option<Clock>) -> Keys<'_>              // automerge.rs:1662-1667
fn iter_for(&self, obj: &ExId, clock: Option<Clock>) -> DocIter<'_>            // automerge.rs:1669-1674
fn map_range_for<'a, R: RangeBounds<String> + 'a>(&'a self, obj: &ExId, range: R,
        clock: Option<Clock>) -> MapRange<'a>                                   // automerge.rs:1676-1684
fn list_range_for<R: RangeBounds<usize>>(&self, obj: &ExId, range: R,
        clock: Option<Clock>) -> ListRange<'_>                                 // automerge.rs:1686-1694
fn values_for(&self, obj: &ExId, clock: Option<Clock>) -> Values<'_>           // automerge.rs:1700-1704
fn length_for(&self, obj: &ExId, clock: Option<Clock>) -> usize                // automerge.rs:1707-1712
fn text_for(&self, obj: &ExId, clock: Option<Clock>) -> Result<String, ...>    // automerge.rs:1714-1720
fn spans_for(&self, obj: &ExId, clock: Option<Clock>) -> Result<Spans<'_>, ...> // automerge.rs:1723-1729
fn get_cursor_for(...)                                                          // automerge.rs:1732-1757
fn get_cursor_position_for(...)                                                 // automerge.rs:1760-1846
fn marks_for(&self, obj: &ExId, clock: Option<Clock>) -> Result<Vec<Mark>, ...> // automerge.rs:1851-1856
fn get_for(&self, obj: &ExId, prop: Prop, clock) -> ...                         // automerge.rs:1859-1896
fn get_all_for<O, P>(...)                                                       // automerge.rs:1898-1930
fn get_marks_for<O>(&self, obj: O, index: usize, clock) -> Result<MarkSet, ...> // automerge.rs:1930-1948
fn calculate_marks(...)                                                          // automerge.rs:1569-1596
fn calculate_marks_slow(...)                                                     // automerge.rs:1598-1628
fn op_cursor_to_opid(...)                                                        // automerge.rs:770-...
```

### Patches — `patches/patch.rs`

```rust
// patches/patch.rs:17-24
pub struct Patch { pub obj: ObjId, pub path: Vec<(ObjId, Prop)>, pub action: PatchAction }
impl Patch { pub(crate) fn has(&self, obj: &ObjId, recursive: bool) -> bool }   // patches/patch.rs:27-29

// patches/patch.rs:33-89
pub enum PatchAction {
    PutMap  { key: String, value: (Value<'static>, ObjId), conflict: bool },
    PutSeq  { index: usize, value: (Value<'static>, ObjId), conflict: bool },
    Insert  { index: usize, values: SequenceTree<(Value<'static>, ObjId, bool)> },
    SpliceText { index: usize, value: ConcreteTextValue, marks: Option<MarkSet> },
    Increment   { prop: Prop, value: i64 },
    Conflict    { prop: Prop },
    DeleteMap   { key: String },
    DeleteSeq   { index: usize, length: usize },
    Mark        { marks: Vec<Mark> },
}
impl fmt::Display for PatchAction  // patches/patch.rs:91-95  (delegates to `{:?}`)
```

Re-exports: `pub use patch::{Patch, PatchAction};` (`patches.rs:3`), `pub use patch_log::PatchLog;` (`patches.rs:6`), `pub(crate) use patch_builder::PatchBuilder;` (`patches.rs:4`), `pub(crate) use patch_log::Event;` (`patches.rs:5`). Crate root: `pub use patches::{Patch, PatchAction, PatchLog};` (`lib.rs:310`).

### `PatchLog` public surface — `patches/patch_log.rs`

```rust
// patches/patch_log.rs:44-57
pub struct PatchLog {
    events: Vec<(ObjId, Event)>,          // private
    expose: HashSet<OpId>,                // private
    completed_patches: Vec<Patch>,        // private
    active: bool,                         // private
    path_map: BTreeMap<ObjId, (Prop, ObjId)>, // private
    path_hint: usize,                     // private
    pub(crate) heads: Option<Vec<ChangeHash>>,
    pub(crate) actors: Vec<ActorId>,
    speculative_actor: Option<ActorId>,   // private
}
impl PatchLog {
    pub fn new(active: bool) -> Self                                    // patches/patch_log.rs:228
    pub fn inactive() -> Self                                           // patches/patch_log.rs:245
    pub fn null() -> Self                                               // patches/patch_log.rs:249
    pub fn active() -> Self                                             // patches/patch_log.rs:256
}
```

Everything else on `PatchLog` is `pub(crate)`: `set_active` (`:260`), `is_active` (`:264`), `finish_current_view` (`:290`), `delete_seq` (`:305`), `delete_map` (`:309`), `increment` (`:313`), `increment_map` (`:320`), `increment_seq` (`:331`), `flag_conflict` (`:335`), `flag_conflict_map` (`:342`), `flag_conflict_seq` (`:346`), `put` (`:350`), `put_map` (`:365`), `put_seq` (`:388`), `replace_seq` (`:412`), `splice` (`:438`), `mark` (`:455`), `insert_and_maybe_expose` (`:465`), `insert` (`:480`), `make_patches` (`:505`), `make_current_patches` (private, `:510`), `truncate` (`:531`), `branch` (`:540`), `migrate_actor` (`:554`), `begin_transaction` (`:589`), `finish_transaction` (`:616`), `migrate_actors` (`:634`), `merge` (`:661`), `path_hint` (`:667`).

Public producers of patches: `Automerge::make_patches(&self, patch_log: &mut PatchLog) -> Vec<Patch>` (`automerge.rs:1005-1007`) and `AutoCommit::make_patches` (`autocommit.rs:215-217`), both delegating to `PatchLog::make_patches` (`patches/patch_log.rs:505-509`).

Internal `Event` enum (`patches/patch_log.rs:60-110`): `PutMap{key,value,id,conflict}`, `PutSeq{index,value,id,conflict}`, `DeleteSeq{index,num}`, `DeleteMap{key}`, `Splice{index,text,marks:Option<Arc<MarkSet>>}`, `Insert{index,value,id,conflict}`, `IncrementMap{key,n,id}`, `IncrementSeq{index,n,id}`, `FlagConflictMap{key}`, `FlagConflictSeq{index}`, `Mark{marks: MarkAccumulator}`.

`PatchBuilder` (`patches/patch_builder.rs:16-24`, all methods `pub(crate)`): `new` (`:27`), `log_event` (`:49`), `get_path` (`:143`), `take_patches` (`:167`), `insert` (`:171`), `splice_text` (`:204`), `delete_seq` (`:235`), `delete_map` (`:287`), `put` (`:296`), `increment` (`:321`), `mark<M: Iterator<Item = Mark>>` (`:329`), `flag_conflict` (`:345`); private `update_path_map` (`:119`), `push` (`:199`).

### Marks — `marks.rs`

```rust
// marks.rs:21-27
pub struct Mark { pub start: usize, pub end: usize, pub name: SmolStr, pub value: ScalarValue }
impl Mark {
    pub fn new<V: Into<ScalarValue>>(name: String, value: V, start: usize, end: usize) -> Mark // marks.rs:224
    pub fn name(&self) -> &str                                          // marks.rs:233
    pub fn value(&self) -> &ScalarValue                                  // marks.rs:237
    pub(crate) fn old_data(&self) -> OldMarkData                        // marks.rs:36-42
    pub(crate) fn into_mark_set(self) -> Arc<MarkSet>                    // marks.rs:48-53
}

// marks.rs:106-108
pub struct MarkSet { marks: BTreeMap<SmolStr, ScalarValue> }
impl MarkSet {
    pub fn iter(&self) -> MarkSetIter<'_>                                // marks.rs:137-139
    pub fn num_marks(&self) -> usize                                     // marks.rs:141-143
    pub fn len(&self) -> usize                                           // marks.rs:149-151
    pub fn is_empty(&self) -> bool                                       // marks.rs:161-163
    pub fn non_deleted_marks(&self) -> NonDeletedMarks<'_>               // marks.rs:208-210
    pub(crate) fn insert(&mut self, name: SmolStr, value: ScalarValue)    // marks.rs:153-155
    pub(crate) fn from_query_state(q: &RichTextQueryState<'_>) -> Option<Arc<Self>> // marks.rs:165-180
    pub(crate) fn without_unmarks(self) -> Self                          // marks.rs:182-187
}
impl std::iter::FromIterator<(String, ScalarValue)> for MarkSet          // marks.rs:213-220

// marks.rs:113-115
pub struct MarkSetIter<'a> { set: Option<btree_map::Iter<'a, SmolStr, ScalarValue>> }
impl<'a> Iterator for MarkSetIter<'a> { type Item = (&'a str, &'a ScalarValue); } // marks.rs:125-133

// marks.rs:29-33 / :356-359
pub struct OldMark<'a> { pub start: usize, pub end: usize, pub(crate) data: Cow<'a, OldMarkData> }
pub struct OldMarkData { pub name: SmolStr, pub value: ScalarValue }

// marks.rs:372-377
pub enum ExpandMark { Before, After, Both, None }
impl Default for ExpandMark  -> After                                   // marks.rs:379-383
impl ExpandMark { pub fn from(before: bool, after: bool) -> Self;         // marks.rs:386-392
                  pub fn before(&self) -> bool;                           // marks.rs:394-396
                  pub fn after(&self) -> bool }                            // marks.rs:397-399

// marks.rs:468-473
pub struct UpdateSpansConfig { pub default_expand: ExpandMark,
                               pub per_mark_expands: HashMap<String, ExpandMark> }
impl UpdateSpansConfig { pub fn with_default_expand(mut self, e: ExpandMark) -> Self;  // marks.rs:476-479
                         pub fn with_mark_expand<S: AsRef<str>>(mut self, n: S, e: ExpandMark) -> Self } // marks.rs:481-485

// marks.rs:438 / 441 / 453 / 461
pub struct NonDeletedMarks<'a>(&'a MarkSet);
impl PartialEq for NonDeletedMarks<'_>                                 // marks.rs:441-450
impl NonDeletedMarks<'_> { pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool } // marks.rs:453-463
```

Crate-private: `MarkAccumulator` (`marks.rs:63-65`) with `into_iter` (`:68`), `into_iter_no_unmark` (`:76`), `add` (`:87-104`); `MarkStateMachine<'a>` (`marks.rs:243-246`) with `current` (`:250`), `process` (`:258`), `mark_begin` (`:266`), `mark_end` (`:294`), `find` (`:321`), `mark_above` (`:325`), `mark_below` (`:339`); `RichTextQueryState<'a>` (`marks.rs:403-406`) with `process` (`:409`) and `iter` (`:429`).

`mod marks;` is `pub` (`lib.rs:265`).

### Cursors — `cursor.rs`

```rust
// cursor.rs:20-30
pub enum Cursor { Start, End, Op(OpCursor) }
// cursor.rs:33-37
pub struct OpCursor { pub(crate) ctr: u64, pub(crate) actor: ActorId, pub(crate) move_cursor: MoveCursor }
// cursor.rs:51-55
pub enum CursorPosition { Start, End, Index(usize) }
impl From<usize> for CursorPosition                                     // cursor.rs:57-61
// cursor.rs:71-74
pub enum MoveCursor { Before, After }
impl Default for MoveCursor -> After                                    // cursor.rs:76-80

impl Cursor { pub fn to_bytes(&self) -> Vec<u8> }                       // cursor.rs:118-176
impl fmt::Display for Cursor                                            // cursor.rs:179-187  -> "s" | "e" | [-]ctr@actor
impl fmt::Display for OpCursor                                          // cursor.rs:189-202
impl TryFrom<&str> for Cursor     { type Error = AutomergeError; }      // cursor.rs:204-210
impl TryFrom<String> for Cursor   { type Error = AutomergeError; }      // cursor.rs:212-218
impl TryFrom<&[u8]> for Cursor    { type Error = AutomergeError; }      // cursor.rs:220-263
impl TryFrom<Vec<u8>> for Cursor   { type Error = AutomergeError; }      // cursor.rs:290-296
fn parse_0(i: parse::Input<'_>) -> Result<Cursor, AutomergeError>        // cursor.rs:265-288
```

Wire constants: `VERSION_TAG=1`, `START_TAG=1`, `END_TAG=2`, `OP_TAG=3`, `MOVE_BEFORE_TAG=1`, `MOVE_AFTER_TAG=2` (`cursor.rs:82-89`). Crate root re-export: `pub use cursor::{Cursor, CursorPosition, MoveCursor, OpCursor};` (`lib.rs:303`).

### Hydrate — `hydrate.rs` + submodules

```rust
// hydrate.rs:22-28
pub enum Value { Scalar(ScalarValue), Map(Map), List(List), Text(Text) }
impl Value {
    pub fn new<'a, V: Into<crate::Value<'a>>>(value: V, text_encoding: TextEncoding) -> Self  // hydrate.rs:30-38
    pub fn map() -> Self                                             // hydrate.rs:40-42
    pub fn list() -> Self                                            // hydrate.rs:44-46
    pub fn text(text_encoding: TextEncoding, s: &str) -> Self         // hydrate.rs:48-50
    pub fn scalar<V: Into<ScalarValue>>(val: V) -> Self              // hydrate.rs:52-54
    pub fn is_scalar(&self) -> bool                                  // hydrate.rs:56-58
    pub fn is_object(&self) -> bool                                  // hydrate.rs:67-69
    pub fn apply_patches<P: IntoIterator<Item = Patch>>(&mut self, text_encoding: TextEncoding,
                                                        patches: P) -> Result<(), HydrateError> // hydrate.rs:78-85
    pub fn as_map(&mut self) -> Option<&mut Map>                     // hydrate.rs:115-120
    pub fn as_list(&mut self) -> Option<&mut List>                   // hydrate.rs:122-127
    pub fn as_i64(&self) -> i64                                       // hydrate.rs:129-134
    pub(crate) fn width(&self, seq_type: SequenceType, encoding: TextEncoding) -> usize // hydrate.rs:60-65
    pub(crate) fn as_str(&self) -> &str                               // hydrate.rs:71-76
    pub(crate) fn apply<'a, P: Iterator<Item = &'a Prop>>(&mut self, path: P,
                     text_encoding: TextEncoding, patch: PatchAction) -> Result<(), HydrateError> // hydrate.rs:89-112
}

// hydrate/map.rs:11  — pub struct Map(HashMap<String, MapValue>);   Deref/DerefMut to HashMap at :92-102
impl Map {
    pub fn iter(&self) -> impl Iterator<Item = (&String, &MapValue)>  // hydrate/map.rs:16-18
    pub fn get(&self, key: &str) -> Option<&Value>                    // hydrate/map.rs:62-64
    pub fn get_mut(&mut self, key: &str) -> Option<&mut Value>        // hydrate/map.rs:66-68
    pub(crate) fn new() -> Self                                       // hydrate/map.rs:70-72
    pub(crate) fn apply(&mut self, text_encoding: TextEncoding, patch: PatchAction)
        -> Result<(), HydrateError>                                    // hydrate/map.rs:23-59
}
// hydrate/map.rs:13-16
pub struct MapValue { pub value: Value, pub conflict: bool }

// hydrate/list.rs:11 — pub struct List(SequenceTree<ListValue>);
impl List {
    pub fn iter(&self) -> impl Iterator<Item = &ListValue>             // hydrate/list.rs:25-27
    pub fn len(&self) -> usize                                        // hydrate/list.rs:29-31
    pub fn is_empty(&self) -> bool                                    // hydrate/list.rs:33-35
    pub fn get(&mut self, index: usize) -> Option<&Value>             // hydrate/list.rs:94-96
    pub fn get_mut(&mut self, index: usize) -> Option<&mut Value>     // hydrate/list.rs:90-92
    pub(crate) fn apply(&mut self, text_encoding: TextEncoding, patch: PatchAction)
        -> Result<(), HydrateError>                                    // hydrate/list.rs:41-84
    pub(crate) fn push<V: Into<Value>>(&mut self, value: V, _id: ExId, conflict: bool) // hydrate/list.rs:105-107
}
// hydrate/list.rs:19-23
pub struct ListValue { pub value: Value, pub marks: HashMap<String, ScalarValue>, pub conflict: bool }

// hydrate/text.rs:11-14
pub struct Text { value: ConcreteTextValue, marks: HashMap<String, ScalarValue> }
impl Text { pub fn new<S: AsRef<str>>(text_encoding: TextEncoding, text: S) -> Self } // hydrate/text.rs:64-71
impl From<&Text> for String (hydrate/text.rs:73-75);  impl Display for Text (hydrate/text.rs:77-82)
```

Exported macros: `hydrate_map!` (`hydrate.rs:305-314`), `hydrate_list!` (`:315-321`), `hydrate_text!` (`:322-327`) — all `#[macro_export]`, i.e. **part of the public API surface**.

Feature-gated: `#[cfg(feature = "wasm")] impl From<Value> for wasm_bindgen::JsValue` (`hydrate.rs:329-335`) and `impl From<&Value> for wasm_bindgen::JsValue` (`hydrate.rs:336-372`). `mod hydrate;` is `pub` (`lib.rs:269`).

Errors: `HydrateError` — `Fail`, `InvalidIndex(usize)`, `InvalidKey(String)`, `BadIncrement`, `InvalidMapOp`, `InvalidListOp`, `InvalidTextOp(PatchAction)`, `ApplyInvalidProp(PatchAction)`, `InvalidEncoding` (`error.rs:140-165`).

### Text diff

```rust
// text_diff/myers.rs:29-52
pub(super) trait DiffHook: Sized {
    type Error;
    fn equal(&mut self, old_index: usize, new_index: usize, len: usize) -> Result<(), Self::Error>;
    fn delete(&mut self, old_index: usize, old_len: usize, new_index: usize) -> Result<(), Self::Error>;
    fn insert(&mut self, old_index: usize, new_index: usize, new_len: usize) -> Result<(), Self::Error>;
    fn replace(&mut self, old_index: usize, old_len: usize, new_index: usize, new_len: usize)
        -> Result<(), Self::Error>;
    fn finish(&mut self) -> Result<(), Self::Error>;
}

// text_diff/myers.rs:56-70
pub(super) fn diff<Old, New, D>(d: &mut D, old: &Old, old_range: Range<usize>, new: &New,
                                new_range: Range<usize>) -> Result<(), D::Error>
where Old: Index<usize> + ?Sized, New: Index<usize> + ?Sized, D: DiffHook,
      New::Output: PartialEq<Old::Output>

// text_diff/replace.rs:20
pub(super) struct Replace<D: DiffHook> { d: D, del: Option<(usize,usize,usize)>,
                                          ins: Option<(usize,usize,usize)>, eq: Option<(usize,usize,usize)> }
impl<D: DiffHook> Replace<D> { pub(super) fn new(d: D) -> Self; }      // text_diff/replace.rs:26-34

// text_diff/utils.rs
pub(super) fn is_empty_range<T: PartialOrd<T>>(range: &Range<T>) -> bool   // :12-15
pub(super) fn common_prefix_len<Old, New>(old, old_range, new, new_range) -> usize // :19-44
pub(super) fn common_suffix_len<Old, New>(old, old_range, new, new_range) -> usize // :46-64

// text_diff.rs — the only crate-level entry points, both pub(crate)
pub(crate) fn myers_diff<'a, S: AsRef<str>>(doc: &'a mut Automerge, tx: &'a mut TransactionInner,
    patch_log: &mut PatchLog, text_obj: &ExId, new: S) -> Result<(), crate::AutomergeError> // text_diff.rs:15-37
pub(crate) fn myers_block_diff<'a, I: IntoIterator<Item = Span>>(doc: &'a mut Automerge,
    tx: &'a mut TransactionInner, patch_log: &mut PatchLog, text_obj: &crate::ObjId,
    new: I, config: &crate::marks::UpdateSpansConfig) -> Result<(), crate::AutomergeError>    // text_diff.rs:136-155
```

`mod text_diff;` is private (`lib.rs:285`). Public reach is only through:
- `Transactable::update_text` (`transaction.rs:460-470`, inside a macro-generated `impl`)
- `Transactable::update_spans` (`transaction.rs:472-489`)
- `Transactable::update_object` (`transaction.rs:491-499`) → `TransactionInner::update_object` → `myers_diff` (`transaction/inner.rs:1084`, `transaction/inner.rs:1220`)
- `AutoCommit::update_text` (`autocommit.rs:1239`) and `AutoCommit::update_spans` (`autocommit.rs:1250`)

Private Myers internals: `struct V { offset: isize, v: Vec<usize> }` with `Index<isize>`/`IndexMut<isize>` (`text_diff/myers.rs:92-122`); `max_d(len1, len2) = (len1+len2).div_ceil(2) + 1` (`:124-127`); `find_middle_snake` (`:145-253`); `conquer` (`:256-319`).

### `autoserde` — Automerge's non-serde-derive JSON encoding

```rust
// autoserde.rs:22
pub struct AutoSerde<'a, R: crate::ReadDoc>(&'a R);
impl<'a, R: ReadDoc> From<&'a R> for AutoSerde<'a, R>                     // autoserde.rs:24-28
impl<R: crate::ReadDoc> serde::Serialize for AutoSerde<'_, R> { ... }     // autoserde.rs:30-40
// private helper types
struct AutoSerdeMap<'a, R> { doc: &'a R, obj: ObjId }                     // autoserde.rs:43-46
struct AutoSerdeSeq<'a, R> { doc: &'a R, obj: ObjId }                     // autoserde.rs:69-72
struct AutoSerdeVal<'a, R> { doc: &'a R, val: Value<'a>, obj: ObjId }     // autoserde.rs:95-99
```

`mod autoserde;` is private (`lib.rs:280`); exported as `pub use autoserde::AutoSerde;` (`lib.rs:299`). **Serialize only — there is no `Deserialize`.** The encoded value model is the public `value::Value<'a>` = `Object(ObjType) | Scalar(Cow<'a, ScalarValue>)`; the encoder never owns a tree, it re-reads the document on every node.

### `sequence_tree` — `sequence_tree.rs`

```rust
pub(crate) const B: usize = 16;                                           // sequence_tree.rs:7
pub type SequenceTree<T> = SequenceTreeInternal<T>;                       // sequence_tree.rs:8
#[derive(Clone)] pub struct SequenceTreeInternal<T> { root_node: Option<SequenceTreeNode<T>> } // :10-13
impl<T: Debug> SequenceTreeInternal<T> {
    pub fn new() -> Self                                                  // sequence_tree.rs:27-29
    pub fn len(&self) -> usize                                            // sequence_tree.rs:32-34
    pub fn iter(&self) -> Iter<'_, T>                                     // sequence_tree.rs:37-45
    pub fn insert(&mut self, index: usize, element: T)                    // sequence_tree.rs:49-89  (panics if index > len)
    pub fn push(&mut self, element: T)                                    // sequence_tree.rs:92-95
    pub fn get(&self, index: usize) -> Option<&T>                        // sequence_tree.rs:98-100
    pub fn get_mut(&mut self, index: usize) -> Option<&mut T>            // sequence_tree.rs:103-105
    pub fn remove(&mut self, index: usize) -> T                           // sequence_tree.rs:112-132 (panics if out of bounds / empty tree)
}
impl<T: Debug> std::fmt::Debug for SequenceTreeInternal<T>               // sequence_tree.rs:529-537
impl<T: Clone + Debug + PartialEq> PartialEq for SequenceTreeInternal<T> // sequence_tree.rs:471-478
impl<'a, T: Clone + Debug> IntoIterator for &'a SequenceTreeInternal<T>  // sequence_tree.rs:480-493
impl<T: Clone + Debug> FromIterator<T> for SequenceTreeInternal<T>       // sequence_tree.rs:496-504
// sequence_tree.rs:507-510 — `pub struct Iter<'a, T>` — NOT re-exported (private module)
impl<'a, T: Debug> Iterator for Iter<'a, T> { type Item = &'a T; }        // sequence_tree.rs:512-526
```

Node: `struct SequenceTreeNode<T> { elements: Vec<T>, children: Vec<SequenceTreeNode<T>>, length: usize }` (`:16-20`); `is_leaf` (`:152`), `is_full` (`elements.len() >= 2*B-1`, `:156-158`), `find_child_index` (`:162-171`), `insert_into_non_full_node` (`:173-197`), `split_child` (`:199-241`), `remove_from_leaf` (`:243-247`), `remove_element_from_non_leaf` (`:249-271`), `cumulative_index` (`:273-278`), `remove_from_internal_child` (`:280-365`), `check` (`:367-375`), `remove` (`:377-412`), `merge` (`:414-425`), `get` (`:427-446`), `get_mut` (`:448-461`).

Public consumers: `PatchAction::Insert.values` (`patches/patch.rs:57`) and `hydrate::List` (`hydrate/list.rs:11`). Exported as `pub use sequence_tree::SequenceTree;` (`lib.rs:316`).

### `anonymize` — `anonymize.rs`

```rust
// anonymize.rs:12-25
pub enum AnonymizeError {
    MissingDependency { change: ChangeHash, dependency: ChangeHash },
    Apply(#[from] AutomergeError),
}
// anonymize.rs:27
pub fn anonymize(document: &Automerge) -> Result<Automerge, AnonymizeError>
```

`pub mod anonymize;` (`lib.rs:246`); `pub use crate::anonymize::AnonymizeError;` (`lib.rs:289`). This is the **entire** public surface — `Anonymization`, `StructuralPermutations`, `StructuralAlphabet`, `random_derangement`, `structural_character_rank`, `structural_character_from_rank`, `mapped_actor`, `map_op_id`, `map_object_id` are all private (`anonymize.rs:31`, `:265`, `:290`, `:298`, `:315`, `:345`, `:365`, `:372`, `:376`). `anonymize/shape.rs` and `anonymize/fuzz.rs` are `#[cfg(test)]` only (`anonymize.rs:382-385`).

### Feature gates in slice

| Gate | Sites in slice |
| --- | --- |
| `slow_path_assertions` | `sequence_tree.rs:52`, `:114`, `:126` |
| `wasm` | `hydrate.rs:329`, `:336` |
| `utf8-indexing` / `utf16-indexing` | declared `Cargo.toml:14-15`; consumed by `TextEncoding::platform_default()` (`text_value.rs:12-33`), which slice code calls via `hydrate_text!` (`hydrate.rs:323-326`) |
| `#[cfg(test)]` | `iter.rs:24`, `iter/keys.rs:1,30,37,52,58,68`, `iter/doc.rs:525`, `iter/list_range.rs:374`, `hydrate.rs:12`, `marks.rs:488`, `anonymize.rs:53,382,384,387`, `sequence_tree.rs:539` |
| `#[cfg(doc)]` | `cursor.rs:4` |
| `#[expect]` / `#[allow]` | `marks.rs:43`, `iter/spans.rs:55`, `patches/patch_log.rs:411`, `text_diff/myers.rs:255`, `text_diff/replace.rs:36`, `text_diff/utils.rs:12,66` |

## Semantics

### Iteration

- `DocIter` visits the whole document in **causal order** — parents before children (`read.rs:68-72`). Proven by the implementation: when an item's value is a visible object, the child is pushed into `next_objs` and only yielded after the current object's items are exhausted (`iter/doc.rs:120-131`, `iter/doc.rs:141-153`, `iter/doc.rs:306-319`). `next_objs` is a `BTreeMap<ObjId, IterType>` so children are visited in `ObjId` (actor, counter) order, not insertion order (`iter/doc.rs:55`).
- `DocObjItem.obj` is the *parent* of the yielded property, not the object that owns the value. `DocObjItem::key()` returns `Some` only for `DocItem::Map`; list items and text spans return `None` (`iter/doc.rs:365-371`).
- `DocItem::id()` / `DocItem::value()` return `None` for `DocItem::Text` (`iter/doc.rs:492-510`). Text is instead reachable via `DocObjItem::value()`, which wraps the span string in a fresh `ValueRef::str(...).into_owned()` (`iter/doc.rs:373-380`).
- `Keys` yields **element ids encoded as strings** for lists and texts, not indexes (`read.rs:48-49`, `iter/keys.rs:12-19` via `op_set.to_string(op.elemid_or_key())`).
- `Keys` is backed by `TopOps` (`op_set2/op_set/top_op.rs:19`), so conflicting map keys yield **one** entry each, not one per conflict.
- `Values` ignores the clock it is handed: `Values::new(op_set, iter, _clock)` names the parameter `_clock` and the body stores only `(op_set, Box::new(iter))` (`iter/values.rs:14-24`). The clock is applied by the caller before constructing the `TopOps` term (`automerge.rs:1700-1704` passes `self.ops.top_ops(&obj.id, clock.clone())`). The `// FIXME - ignore clock?` comment at `iter/values.rs:14` is stale.
- `Values` boxes its term: `Box<dyn OpQueryTerm<'a>>` (`iter/values.rs:10`). `OpQueryTerm` is `pub(crate) trait OpQueryTerm<'a>: Iterator<Item = Op<'a>> + Debug` (`op_set2/op_set/op_query.rs:14-16`). This is a **private bound on a public type** — external code can consume `Values` but cannot name or implement the bound.
- `ListRange` filters *after* diffing: the diff runs over the whole object range and `ListRange::next` loops, discarding items whose `index` is outside `self.range` (`iter/list_range.rs:345-357`). Consequence: `list_range(obj, 900_000..)` on a 5-element list still walks every op.
- `normalize_range` (`iter/list_range.rs:359-372`) converts `RangeBounds` to a half-open `(start, end)`: `Unbounded start -> usize::MIN`, `Excluded(n) start -> n - 1`, `Unbounded end -> usize::MAX`, `Included(n) end -> n + 1`. `Excluded(0)` as a start bound underflows; `Included(usize::MAX)` as an end bound overflows. `[INFERENCE]` (the arithmetic is unguarded in the source; Rust panics in debug, wraps in release).
- `MapRange` does **no** key filtering of its own: `MapRange::new` takes a positional `Range<usize>` and hands it straight to `MapDiff::new` (`iter/map_range.rs:204-208`). The `RangeBounds<String>` is resolved earlier, by translating each bound key into a positional op range via `cols.key_str.scope_to_value(Some(s), obj_range)` (`op_set2/op_set.rs:396-419`). `Unbounded` start/end become the object range itself; `Included(s)` start -> `scope(s).start`, `Excluded(s)` start -> `scope(s).end`, `Included(s)` end -> `scope(s).end`, `Excluded(s)` end -> `scope(s).start`.
- Conflict flags: `ListDiff` sets `conflict = num_new > 1 && !(diff == Same && num_old > 1)` (`iter/list_range.rs:150`); `MapDiff` uses the same rule (`iter/map_range.rs:260`). `Diff::Del` items always have `expose` set from the previous `Same` state (`iter/list_range.rs:127-130`, `iter/map_range.rs:226-228`).
- `Diff::Add` sets `expose = self.clock.predates(&id)` (`iter/list_range.rs:138`, `iter/map_range.rs:252`, `iter/spans.rs:191`); `ClockRange::predates` is `true` only in the `Diff(before, _)` variant (`clock.rs:111-115`).
- Counters: when a value is `ScalarValue::Counter(c)`, both diff iterators compute `inc = inc2 - inc1` from `op_set.get_increment_diff_at_pos(pos, &clock)` and set `state.inc`; the emitted value is `c + inc2` (`iter/list_range.rs:135-141`, `iter/map_range.rs:257-263`).
- Deleting a winning value exposes the previously-shadowed one. Both `ListDiff::next` and `MapDiff::next` hold the item back in `last_visible`, then on the delete emit it with `update()` called, promoting `Diff::Same -> Diff::Add` and **overwriting** `conflict` with the post-deletion count (`iter/list_range.rs:157-168`, `iter/map_range.rs:266-276`).
- When the surviving value is unchanged but its conflict flag clears (`diff == Same && num_old > 1 && num_new == 1`), the iterators still emit it with `update(true)` so the metadata change is observable and object children get exposed (`iter/list_range.rs:170-179`, `iter/map_range.rs:280-286`).
- `Values`, `MapRange`, `ListRange` and `Keys` all return the *default* (empty) iterator when the object id is unknown, rather than erroring: `.ok().map(...).unwrap_or_default()` (`automerge.rs:1662-1667`, `:1669-1674`, `:1676-1684`, `:1686-1694`, `:1700-1704`, `:1707-1712`). `spans`, `text`, and `length` are the same shape for `length` (`:1707-1712`); `spans` and `text` return `Result` instead (`automerge.rs:1714-1729`).
- `Unshift::peek()` returns a borrow into the lookahead slot that is held across a `continue` in both diff iterators (`iter/map_range.rs:262-269`, `iter/list_range.rs:152-160`).

### `Spans` / text iteration

- `SpansActionValue` picks a fast path: if the clock is `Current(None)` **and** `op_set.all_of_range_is_top(&range)`, it streams `ActionValueIter` directly and tags everything `Diff::Add`; otherwise it wraps in `DiffIter::new_top` with a `TopIter` skipper (`iter/spans.rs:67-82`, `:96-106`). `shift` demotes `Current -> Diff` if the new range is no longer all-top (`iter/spans.rs:84-93`).
- `SpansDiff::next` first drains `state.pop()` (a deferred block marker), then feeds action/value pairs through `process_action_val_diff` (`iter/spans.rs:120-134`).
- Action dispatch: `Action::Set`+`Str`+`Add` -> `push_unmarked_add_str`; `Action::Set`+`Str` -> `push_str`; `MakeMap` -> `push_block`; `Mark` -> `process_mark` (emits nothing itself); `Delete`/`Increment` -> dropped; everything else -> `push_str(diff, PLACEHOLDER)` (`iter/spans.rs:213-233`).
- `Mark` ops consume **no width**: `Op::width` returns `0` for `Action::Mark` in text (`op_set2/op.rs:1007-1010`). The mark name and value are read from a separate `MarkInfoIter` in lockstep with `OpIdIter` (`iter/spans.rs:151-160`, `:195-212`). If the op-id column has an entry but the mark-name column does not, it is treated as `mark_end_diff` (`iter/spans.rs:203-208`).
- `SpanState` keeps two mark states: `marks` (currently active) and `next_text.marks` (marks on the buffered span). They legitimately differ when marks open and close with no text between — the source documents this exact example (`iter/spans.rs:436-451`).
- `push_str` flushes the buffered text whenever `diff` or `marks` changes (`iter/spans.rs:492-513`). `flush()` drops zero-length buffers, so a run of only mark ops never yields a span (`iter/spans.rs:563-586`).
- Index accounting: `index` advances by `encoding.width(s)` only for non-`Del` diffs; `Del` contributes width 0 (`iter/spans.rs:536-542`, `:583-585`, `:588-595`). Block markers are one position wide (`iter/spans.rs:266-271`).
- `const PLACEHOLDER: &str = "\u{fffc}"` (`iter/spans.rs:429`); `Span::as_str()` returns it for `Block` variants (`iter/spans.rs:420-427`).
- `MarkDiff` equality short-circuits on `Arc::ptr_eq` for `After`/`Before`/`Diff` (`iter/spans.rs:299-313`). `MarkDiff::iter()` merges the before/after mark sets, skipping `Null` values in the "before" set and emitting `ScalarValue::Null` for removed marks (`iter/spans.rs:342-386`).
- `MarkDiff::export()` returns `None` when the merged set is empty, else `Some(Arc<MarkSet>)` (`iter/spans.rs:389-401`).
- `Spans::next` calls `SpanInternal::export`, which re-hydrates a block's map from the OpSet and **warns + substitutes an empty map** if the object is not a map (`iter/spans.rs:605-627`, `tracing::warn!("unexpected non map object in text")`).
- `RichTextDiff` maintains a `before` and an `after` `MarkStateMachine`; `Diff::Same` feeds both, `Add` only `after`, `Del` only `before` (`iter/spans.rs:663-682`).

### Marks

- `MarkStateMachine.state` is a `Vec<(OpId, MarkData)>` kept sorted by `OpId`; `find` is a binary search returning `Result<usize, usize>` = (found, insertion point) (`marks.rs:245`, `:321-323`).
- `mark_begin(id)`: inserts at the binary-search position. If no mark of the same name exists *above* the position, the value below (nearest same-name below, exclusive) becomes the active value; if the below value differs, or there is nothing below, the new name is written into `current` and the return value is `true` (= changed) (`marks.rs:266-291`).
- `mark_end(id)`: looks up `id.prev()` — the `MarkBegin` op id is the `MarkEnd` op id minus one — removes that entry, then restores the mark below, or removes the name entirely if nothing is below and nothing above (`marks.rs:294-318`).
- `current()` returns `None` when the set is empty (`marks.rs:250-256`).
- `MarkSet::from_query_state` replays a `RichTextQueryState` through a fresh `MarkStateMachine` and then strips `Null` values, so an *unmark* tombstone alone yields `None` (`marks.rs:165-180`; regression test with an explanatory comment at `marks.rs:509-538`).
- `without_unmarks` clones the whole map then `retain`s (`marks.rs:182-187`; the crate's own `// FIXME - do I need this clone?` at `:183`).
- `MarkAccumulator::add(index, len, set)` coalesces into the previous run when the value matches and `last.index + last.len == index` (`marks.rs:87-104`). `into_iter` keeps `Null` marks (unmarks), `into_iter_no_unmark` filters them; the latter is what `calculate_marks_slow` uses (`automerge.rs:1629`).
- `NonDeletedMarks::eq` treats a `Null` on **either** side as "matches anything" (`marks.rs:441-450`).
- `get_marks` uses a fast indexed path only when `clock.is_none() && obj.typ == ObjType::Text`; any clock or non-text object falls back to `get_marks_slow` (`automerge.rs:1930-1948`). Under `slow_path_assertions` the two are asserted equal (`automerge.rs:1941-1946`).
- `RichTextQueryState::process` ignores any op not covered by the clock (`marks.rs:409-427`).

### Patches

- Two-stage: mutations append `Event`s to a `PatchLog` keyed by `ObjId`; `make_patches` sorts those events **by object**, then runs them through `PatchBuilder`, which coalesces adjacent same-object events into one `Patch` per action kind.
- `make_current_patches` sorts by `obj` — patch order is *object order, not chronological order* (`patches/patch_log.rs:510-529`, specifically `self.events.sort_by(|(obj_a, _), (obj_b, _)| obj_a.cmp(obj_b))` at `:519`). `finish_current_view` exists solely to preserve chronology when the view moves backwards in history (documented at `patches/patch_log.rs:279-289`, implemented at `:290-303`).
- Actor maintenance: because actors are stored in a sorted list and referenced by index, inserting a new actor shifts every later index. `migrate_actors` walks the document's actor list, inserting and re-indexing events, and returns `Err(PatchLogMismatch)` if the lists diverge non-monotonically (`patches/patch_log.rs:634-659`, `migrate_actor` at `:554-573`, `remove_actor` at `:576-586`).
- Speculative actors: a transaction whose `seq == 1` may have just added a new actor. `begin_transaction` records it as speculative; `finish_transaction` removes it (and every event referencing it) if the transaction produced no ops (`patches/patch_log.rs:589-613`, `:616-631`). `Event::without_actor` returns `None` for any event that actually references the removed actor, which drops that event (`patches/patch_log.rs:167-214`).
- "Expose" mechanism: when a previously-shadowed object becomes visible, `put_map`/`put_seq`/`insert_and_maybe_expose` record its `OpId` in `self.expose` (`patches/patch_log.rs:365-386`, `:388-410`, `:465-478`). During `make_current_patches`, `ExposeQueue` holds the sorted set; `pump_queue` flushes every expose whose `ExId` sorts *before* the current event object, and `should_skip` suppresses the event for an object that is about to be fully re-emitted (`patches/patch_log.rs:510-529`, `:682-690`).
- `ExposeQueue::flush_obj` walks the object's whole current state: text -> `splice_text` per span and `insert` per block (enqueuing each block child); list -> `insert` per element (enqueuing object children); map/table -> `put` per key (enqueuing object children) (`patches/patch_log.rs:731-778`).
- `PatchLog::mark` coalesces into the tail event if the tail is a `Mark` (`patches/patch_log.rs:455-463`).
- `PatchBuilder` coalescing, all gated on the previous patch targeting the same `obj` (`maybe_append`, `patches/patch_builder.rs:372-380`):
  - `insert` appends into a trailing `PatchAction::Insert` when the index falls in `[tail_index, tail_index + len]` (`patches/patch_builder.rs:171-197`).
  - `splice_text` splices into a trailing `SpliceText` only when the marks are **equal** (`Option<Arc<MarkSet>>` compares by value here, despite the `last_mark_set` "quick pointer equality test" comment at `:18`) and the index is in range (`patches/patch_builder.rs:204-232`).
  - `delete_seq` subtracts from a trailing `SpliceText` or `Insert` when the whole span is inside it, popping the patch if it becomes empty; otherwise it extends a trailing `DeleteSeq` at the same start index (`patches/patch_builder.rs:235-285`).
  - `mark` appends to a trailing `Mark` patch; an empty mark list produces no patch (`patches/patch_builder.rs:329-343`).
  - `flag_conflict` flips `conflict = true` on a matching trailing `PutMap`/`PutSeq` instead of emitting a separate `Conflict` action (`patches/patch_builder.rs:345-364`).
- `PatchBuilder::get_path` walks `object_parent` up to the root, memoising into `path_map` and refreshing it per parent type via `update_path_map` when a lookup misses (`patches/patch_builder.rs:143-165`, `:119-141`). A `seen` set breaks cycles (`patches/patch_builder.rs:150-153`). **If path resolution fails, the patch is silently dropped** — every `PatchBuilder` mutator wraps its `push` in `if let Some(path) = self.get_path(&obj)` (`patches/patch_builder.rs:184-186`, `:229-231`, `:288-294`, `:297-318`, `:322-326`, `:338-342`, `:357-362`).
- `path_map` is a hint: `get_path_map` discards the cached map when `path_hint != events_len()` (`patches/patch_log.rs:496-501`).
- `PatchLog::replace_seq` sequence-type split: on a `List` it degenerates to `put_seq`; on `Text` it emits `delete_seq` followed by either `insert_and_maybe_expose` (for objects) or `splice` (`patches/patch_log.rs:411-435`).
- `ListDiffItem::log` and `SpanDiff::log` are the translation from internal diff items to `PatchLog` events (`iter/list_range.rs:216-244`, `iter/spans.rs:21-51`); `MapDiffItem::log` likewise (`iter/map_range.rs:70-89`).
- `Patch::has(obj, recursive)` is `obj == self.obj || (recursive && self.path.iter().any(|(o, _)| o == obj))` (`patches/patch.rs:27-29`). It is `pub(crate)`; no caller exists inside the slice.

### Hydrate

- `Value::apply_patches` walks each patch's `path` (root-first) then applies the action at the terminal node (`hydrate.rs:78-85`).
- `Value::apply` path/action compatibility (`hydrate.rs:89-112`):
  - `Prop::Seq(n)` + `Value::List` -> descend into element `n`, else `ApplyInvalidProp(patch.clone())`.
  - `Prop::Map(s)` + `Value::Map` -> descend into key `s`, else `ApplyInvalidProp`.
  - `Prop::Seq(_)` + `Value::Text` -> **`Ok(())`, the patch is dropped**. The source comment: hydrated text represents embedded block objects only by their replacement characters (`hydrate.rs:97-104`).
  - path exhausted -> dispatch to `Map::apply` / `List::apply` / `Text::apply`.
  - any other combination -> `HydrateError::Fail`.
- `Map::apply` handles `DeleteMap`, `PutMap`, `Increment{Prop::Map}`, `Conflict{Prop::Map}`; anything else is `InvalidMapOp` (`hydrate/map.rs:23-59`). `Increment` on a missing key is `InvalidKey(key)`; on a non-counter value it is `BadIncrement` (`hydrate/map.rs:38-46`, `:82-89`).
- `List::apply` handles `PutSeq`, `Insert`, `DeleteSeq`, `Increment{Prop::Seq}`, `Conflict{Prop::Seq}`, and `Mark` — where `Mark` is `todo!()`, i.e. **panics** (`hydrate/list.rs:73-75`). Same in `Text::apply` (`hydrate/text.rs:54-56`). `Text::apply` returns `InvalidTextOp(p)` for anything outside its handled set (`hydrate/text.rs:57`).
- `List::apply` for `Insert` walks `values.into_iter().enumerate()` and uses `value.2` (the bool) as the conflict flag (`hydrate/list.rs:51-58`), matching `SequenceTree<(Value<'static>, ObjId, bool)>`.
- `Text::apply` for `PutSeq` does `remove(index)` then `splice(index, new)` (`hydrate/text.rs:43-49`) — length changes if the replacement has a different encoded width.
- Storage invariants: `hydrate::Map` is a `HashMap<String, MapValue>` (**unordered** — key order is not preserved through `apply_patches`); `hydrate::List` is a `SequenceTree<ListValue>` (ordered); `hydrate::Text` is a `ConcreteTextValue` plus a `HashMap<String, ScalarValue> marks` field that is **never written** — `Text::apply` `todo!()`s on `Mark`, so `marks` is always empty (`hydrate/text.rs:11-14`).
- Object ids are discarded on the way in: `MapValue::new(value, _id, conflict)` (`hydrate/map.rs:78-82`), `List::push(value, _id, conflict)` (`hydrate/list.rs:105-107`), `ListValue::new(value, conflict)` (`hydrate/list.rs:127-133`).
- `OpSet::hydrate_op` **panics** on any op that is not `Make` or `Put` (`hydrate.rs:288-303`, `_ => panic!("invalid op to hydrate")`).
- `OpSet::hydrate_text` builds text via `self.text(obj, clock)` and therefore **loses all marks and all block objects** (`hydrate.rs:278-286`).
- `Value::as_str` returns `"\u{fffc}"` for anything that is not `ScalarValue::Str` (`hydrate.rs:71-76`) — this is how a block marker becomes a one-character `PutSeq` target in `Text::apply` (`hydrate/text.rs:43-49`).
- `Value::as_i64` returns `0` for non-scalars and `s.as_i64_or_default()` otherwise (`hydrate.rs:129-134`).

### `autoserde`

- `AutoSerde::serialize` always starts at `ObjId::Root` and delegates to `AutoSerdeMap` (`autoserde.rs:30-40`).
- `AutoSerdeMap::serialize` sizes the map with `self.doc.length(&ObjId::Root)` — **the root's length, not `self.obj`'s** (`autoserde.rs:56`). This is a provable defect: nested maps report the wrong map length hint. `serialize_seq` in `AutoSerdeSeq` passes `None` for length (`autoserde.rs:82`), so sequences are unaffected.
- `AutoSerdeMap` iterates `self.doc.keys(&self.obj)` then calls `self.doc.get(&self.obj, &key).unwrap().unwrap()` for each — **two `unwrap`s**; a key that is not a map key (a list element id) or an object id that becomes invalid panics (`autoserde.rs:57-58`, with a `// SAFETY:` comment that only justifies the second unwrap). `AutoSerdeSeq` has the same double unwrap (`autoserde.rs:86-87`).
- `AutoSerdeVal` dispatch (`autoserde.rs:101-128`): `Object(Map|Table)` -> recurse `AutoSerdeMap`; `Object(Text)` -> `self.doc.text(&self.obj).unwrap()` serialized as a `String`; `Object(List)` -> recurse `AutoSerdeSeq`; `Scalar(v)` -> `v.serialize(serializer)` (i.e. `crate::value::ScalarValue`'s own serde impls). `self.obj` here is the ExId returned alongside the value by `ReadDoc::get` (`automerge.rs:1859-1896`), so it is the value's own object id.
- Because it re-reads the document at each node, `AutoSerde` is O(nodes) `get` calls and allocates a fresh `String` per key. It is a snapshot reader, not a streaming iterator.
- Only `Serialize` exists. There is no `AutoSerde` `Deserialize`, no patch-driven variant, and no handling of `conflict`.

### Text diff

- `myers_diff` splits both the current text and the new text into **grapheme clusters** via `unicode_segmentation` (`text_diff.rs:21-22`) and runs the raw `myers::diff` (no `Replace` wrapper) (`text_diff.rs:36`).
- `TxHook` maintains a running **encoded** offset `idx` into the text object; `equal` advances it by the sum of `text_encoding.width(...)` over the equal graphemes, `insert`/`replace` advance by the width of the spliced string, `delete` does not advance it (`text_diff.rs:60-133`). `replace` is implemented as a single `splice_text` with the deleted length computed from grapheme widths (`text_diff.rs:73-95`).
- `myers_block_diff` converts the existing document into `Vec<BlockOrGrapheme>` where a block is one element and text is per-grapheme (`text_diff.rs:472-494`, `spans_as_grapheme` at `:449-471`, `span_as_grapheme` at `:476-491`). It then runs the diff through a `replace::Replace` hook (`text_diff.rs:146-155`) so inserts/deletes collapse into `replace` events.
- `BlockDiffHook` (`text_diff.rs:250-258`, impl `:279-448`): `delete` on a block calls `tx.join_block`, on a grapheme calls `tx.delete` (`:283-299`); `insert` batches runs of graphemes into one `splice_text` and calls `split_block` for each block, flushing the run before each block (`:301-327`); `replace` pairs old and new positionally and dispatches `update_block` / `join_block` / `delete` / `split_block` / `splice_text` combinations (`:359-447`).
- `myers_block_diff` runs a **second pass** for marks (`text_diff.rs:157`, `apply_marks_diff` at `:165-231`): collect the target `(name, value, start, end)` set from the new spans (blocks count as one position, text counts as `doc.text_encoding().width(text)`), diff against `doc.marks_for(text_obj, None)`, `unmark` the ones not present, then `mark` the ones not already present. `expand` is looked up per mark name in `config.per_mark_expands`, falling back to `config.default_expand` (`text_diff.rs:209-212`, `:225-228`).
- The add pass re-queries `doc.marks_for(text_obj, None)` on every iteration of the loop (`text_diff.rs:218`), i.e. O(n) full mark walks for n added marks. `[INFERENCE]`
- `myers::diff` allocates two `V` vectors of `2 * max_d` usize each (`text_diff.rs:57-59`, `myers.rs:98-103`) and recurses through `conquer` (`:256-319`). `find_middle_snake` returns `None` when no overlap is found, and `conquer` then degrades to a full `delete` + `insert` for the whole range (`myers.rs:298-313`).
- The module has no deadline parameter (explicitly removed from the vendored copy, `myers.rs:7`). The header comment states the algorithm has no advanced heuristics, so two large disjoint sequences "will make it spin without making reasonable progress" (`myers.rs:19-23`).
- `Replace::delete` / `Replace::insert` assert contiguity of the run being accumulated with `debug_assert_eq!` (`text_diff/replace.rs:98-103`, `:114-117`) — i.e. the `DiffHook` contract requires monotonic, contiguous events, and violations only fire in debug builds.

### Cursors

- `Cursor::Start` and `Cursor::End` are position-independent: they always dereference to `0` and `sequence.length` respectively, and `move_cursor` is irrelevant to them (`read.rs:237-241`, `automerge.rs:1789-1791`).
- `OpCursor` stores `(ctr: u64, actor: ActorId, move_cursor)` — the `ActorId` is copied out of the OpSet's actor table at creation (`cursor.rs:40-47`).
- `get_cursor_for`: `Start`/`End` short-circuit; `Index(i)` seeks the ops at index `i` and takes `found.ops.last()`, erroring with `InvalidIndex(i)` if empty (`automerge.rs:1732-1757`).
- `get_cursor_position_for`, `MoveCursor::After`: returns `found.index` from `seek_list_opid` — the op's own index if visible, otherwise the next item that was *also visible at creation time*, otherwise `sequence.length` (`automerge.rs:1806-1815`).
- `get_cursor_position_for`, `MoveCursor::Before`: if the op is visible or at index 0, return the index; otherwise walk backwards through `op.key.elemid()` calling `seek_list_opid` until a visible element is found, else `0` (`automerge.rs:1817-1843`). The source carries a `// FIXME: this should probably be an OpSet query` and "likely very inefficient" note at `automerge.rs:1805-1807`.
- Binary wire format, v1 (`cursor.rs:118-176`): `[1, 3, uleb128(actor_len), actor_bytes, uleb128(ctr), move_tag]`; `Start` = `[1, 1]`, `End` = `[1, 2]`. v0 was `[0, uleb128(actor_len), actor_bytes, uleb128(ctr)]` and always implies `MoveCursor::After` (`cursor.rs:265-288`). Any unknown version, tag, or move tag is `AutomergeError::InvalidCursorFormat` (`cursor.rs:227-262`).
- Text wire format: `"s"` / `"e"`; op cursors are `[-]ctr@actor` where the leading `-` means `MoveCursor::Before` (`cursor.rs:92-113`, `:179-202`). A parse failure is `InvalidCursorFormat` (`cursor.rs:208`).
- Non-sequence objects are rejected with `AutomergeError::InvalidOp(obj.typ)` (`automerge.rs:1738-1740`) and on deref with `InvalidCursor(cursor.clone())` (`automerge.rs:1796-1798`).

### `anonymize`

- `anonymize(document)` walks `document.get_changes(&[])`, builds an actor map, and **replays** every change into a fresh `Automerge`, translating dep hashes through a `change_hashes: HashMap<ChangeHash, ChangeHash>` (`anonymize.rs:60-101`). A dep that has not been seen yields `AnonymizeError::MissingDependency` (`anonymize.rs:73-81`); the replay failure path yields `AnonymizeError::Apply` (`anonymize.rs:25`, `:97`).
- Actor ids are rewritten to `prefix[8] || rank as u64 BE` (16 bytes) where `rank` is the position in the `BTreeSet` of all referenced actors; the random prefix loop retries until no mapped actor collides with an existing one (`anonymize.rs:103-126`).
- Rewritten: `actor_id`, `time` (i32-sampled, see below), `message` (content-anonymized), `extra_bytes`, every operation's `obj`, `key`, `pred` and action (`anonymize.rs:82-100`, `:128-158`).
- `random_i64_other_than` samples `i32` and widens to `i64` — deliberately, so signed integer column delta encoding stays representable (documented at `anonymize.rs:186-188`, implemented at `:184-194`). `random_u64_other_than` samples a full `u64` (`:196-203`). `random_f64_other_than` samples `[0, 1)` and compares by `to_bits()` (`:205-214`).
- Scalars: `Bytes` -> synthetic bytes; `Str` -> content-anonymized; `Int`/`Timestamp`/`Counter` -> `random_i64_other_than`; `Uint` -> `random_u64_other_than`; `F64` -> `random_f64_other_than`; `Boolean` -> `self.rng.random()`; `Unknown` -> type code kept, bytes anonymized; `Null` -> `Null` (`anonymize.rs:160-182`).
- `anonymize_structural_string` (used for **map keys** and **mark names**) maps each `char` through a per-UTF-8-length-class derangement (`anonymize.rs:216-224`, `:264-287`, `:298-312`, `:315-362`). Consequence: character-equality patterns and encoded lengths are preserved exactly. The module comment is explicit that this is a substitution cipher, not cryptographic protection (`anonymize.rs:257-263`).
- `anonymize_content_string` (used for **string values and commit messages**) retains whitespace and ASCII control characters **verbatim**, replaces printable ASCII with bytes drawn from a shuffled 57-byte `SYNTHETIC_TEXT` alphabet, and maps non-ASCII through the non-printable-ASCII permutation table (`anonymize.rs:226-238`, alphabet at `:8`, seeded shuffle at `:41-43`). The verbatim retention of whitespace/control characters is a deliberate, in-source-documented behaviour.
- `random_synthetic_byte` walks a rotating cursor over the shuffled alphabet, rejecting a replacement equal to the original byte (`anonymize.rs:247-258`).
- `structural_character_from_rank` collapses the whole `[0x20, 0x7f]` rank space onto `0x7f` (DEL) for single-byte non-printable, non-control input (`anonymize.rs:352-357`), so several ranks are not injective. `[INFERENCE]` (the inverse `structural_character_rank` maps `0x7f` back to rank `0x20` at `:328`, so the mapping is well-defined but not a bijection on that class).
- Proven invariants, exercised by `anonymize.rs:439-556` and `anonymize/fuzz.rs:19-31`: change count, per-change `seq`/`start_op`/dep-index graph, message presence, extra-bytes length, text byte length and UTF-16 length, and per-character encoded width are all preserved; the result re-loads from `save()` unchanged.

### `sequence_tree`

- B-tree of order `B = 16`; a node is full at `elements.len() >= 2*B - 1 = 31` (`sequence_tree.rs:7`, `:156-158`). `length` is the subtree's element count, not `elements.len()` (`:20`, `:143-145`).
- `insert(index, element)` splits a full root by creating a new root, pushing the old root down, splitting it, and inserting into the correct child (`sequence_tree.rs:49-89`). It asserts `self.len() == old_len + 1` on the way out (`:88`).
- `remove(index)` collapses the root when it empties: if the root becomes a leaf, `root_node = None`; else the first child is promoted to root (`sequence_tree.rs:112-132`).
- `remove_from_internal_child` rebalances by borrowing from a sibling with `>= B` elements, or by merging with a sibling when both neighbours have `< B` (`sequence_tree.rs:280-365`).
- `find_child_index` returns `(child_index, index_adjusted)` and **panics** with `"index not found in node"` if the index exceeds the subtree (`:162-171`).
- `check()` recomputes the length bottom-up and asserts equality; it is only invoked under `slow_path_assertions` (`:367-375`, gated at `:52`, `:114`, `:126`).
- `Iter` is O(n log n) to walk because it goes through `get(index)` per step, and its `nth` is `self.index += n + 1; self.inner.get(self.index - 1)` — i.e. `nth` advances the cursor by `n+1` total, matching `next`'s contract (`:512-526`).
- `PartialEq` is O(n) and compares element-wise after a length check (`:471-478`).
- `Debug` prints every element inline (`:529-537`).
- Proptest coverage exists for insert/remove against `Vec` (`sequence_tree.rs:539-661`).

## Zig mapping notes

### Ownership and lifetimes

- `'a` in `MapRangeItem<'a>`, `ListRangeItem<'a>`, `DocItem<'a>`, `MapRange<'a>`, `ListRange<'a>`, `Spans<'a>`, `Keys<'a>`, `Values<'a>` all mean "borrowed from the `&OpSet` / `&Automerge` the iterator was built from". In Zig this is a `*const OpSet` (or `*const Automerge`) plus any derived slices (`[]const u8`, `[]const T`) carried in the iterator struct. `Keys<'a>`/`Values<'a>` need no lifetime at all once the backing data is owned; the borrow is purely for soundness.
- `into_owned()` on both range items (`iter/list_range.rs:30`, `iter/map_range.rs:31`) is the escape hatch: a Zig port should provide `intoOwned(self) ListRangeItem` that resolves `ExIdPromise` to a concrete `ExId` and `Cow<'a, str>` to an owned `[]const u8`.
- `ExIdPromise<'a>` (`iter/tools.rs:188-246`) is a hand-rolled deferred resolution: it holds either `&'a OpSet` + `OpId` or an already-resolved `ExId`, resolved on `exid()`. In Zig, either store `union(enum){ op_set: *const OpSet, exid: ExId }` and branch at resolve time, or resolve eagerly at construction. Eager is correct and cheaper; the deferred form only exists in Rust to avoid work on the common `op_id()` path.
- `Arc<ExId>` in `DocObjItem.obj` (`iter/doc.rs:338`) is a refcounted, cheaply-clonable object id that the iterator re-creates only when the object changes (`iter/doc.rs:294-296`). In Zig: either an interned pointer (`*const ExId` owned by a document-level interner) or a small refcount. The pointer-equality check there is an optimization, not a semantic.
- `Box<dyn OpQueryTerm<'a>>` inside `Values` (`iter/values.rs:10`) is a **trait object**. Zig has no trait objects; use a vtable struct `{ ptr: *anyopaque, nextFn: *const fn(*anyopaque) ?Op, getMarksFn: ..., rangeFn: ... }`, or — better — since there is exactly one concrete term (`TopOps`) constructed by `Automerge::values_for`, make `Values` hold a concrete `TopOps` and drop the `dyn` indirection entirely. That removes one heap allocation per `values()` call.

### Enums and unions

- `Span`, `DocItem`, `PatchAction`, `Cursor`, `MoveCursor`, `CursorPosition`, `ExpandMark`, `Diff`, `MarkDiff`, `hydrate::Value` → Zig tagged unions (`union(enum) { ... }`). `PatchAction` is the largest (it embeds `SequenceTree<(Value, ObjId, bool)>` and `Vec<Mark>`); boxing the large payloads in a pointer variant keeps the union small. Note that `#[derive(PartialEq)]` on `PatchAction` (`patches/patch.rs:32`) is part of the public contract, so `std.meta.eql` must be deep — expect this to be a hot path in patch application.
- `Diff` (`iter/tools.rs:611-616`) is a 3-variant fieldless enum → `enum { same, add, del }`. `MarkDiff` (`iter/spans.rs:291-297`) is `enum { nothing, after: *MarkSet, before: *MarkSet, diff: struct{ before: *MarkSet, after: *MarkSet } }` with `Arc` → refcounted pointers. The custom `PartialEq` with `Arc::ptr_eq` fast paths (`iter/spans.rs:299-313`) maps to comparing the refcount pointers before falling back to `std.meta.eql`.
- `ClockRange` (`clock.rs:75-78`, adjacent slice) is `Current(?Clock) | Diff(Clock, Clock)` → the same tagged union, referenced by `?*const Clock`.

### Iterators

- Rust's `Iterator` trait with `next() -> Option<T>` maps directly to a Zig struct with a context pointer and a function pointer. Every public iterator in this slice is `next()`-only except `ListIter`/`MapIter` which also override `nth` (`iter/list_range.rs:311-320`, `iter/map_range.rs:191-201`) and `Unshift` which overrides `nth` (`iter/tools.rs:53-57`).
- `DiffIter::next` deliberately branches on `skip == 0` to call `next()` instead of `nth(0)`, with a comment that `nth(0)` is "noticeably slower for column iterators" (`iter/tools.rs:596-604`). **Port this branch verbatim** — the RLE column iterators from `hexane` make `nth(0)` non-trivial.
- `Unshift<T>` (`iter/tools.rs:13-57`) is a one-item lookahead. `peek()` returns a borrow; `next()`/`nth()` swap the lookahead out and pull a fresh one. Straightforward in Zig, but the *borrow* returned by `peek()` in `MapDiff::next` (`iter/map_range.rs:262-269`) and `ListDiff::next` (`iter/list_range.rs:152-160`) is held across a `continue`, which in Zig means the `next()` call must not mutate the buffer while a pointer into it is live. Practical fix: return a copied tag (`{diff, pos, key_ptr, ...}`) instead of a pointer.
- The `Shiftable` trait (`iter/tools.rs:62-64`) — `fn shift_next(&mut self, range: Range<usize>) -> Option<Item>` — is the core abstraction that lets `DocIter`/`DiffIter` *reposition* a mid-flight iterator into a child object's op range without allocating. This has no direct Zig equivalent. Options: (a) an inline `anytype`/comptime-generic `shiftNext` method on every column iterator, or (b) a vtable. (a) is the right call — everything in `iter/tools.rs` is monomorphized in Rust anyway.
- `Skipper` (`iter/tools.rs:60`) is a marker trait: `Iterator<Item = usize>` where the `usize` is a *skip count*. Same treatment.
- `BoolColumnSkipper::next` (`iter/tools.rs:355-383`) uses `hexane::Iter::next_run()` to skip whole RLE runs of `false`. This is a RLE-specific optimization; a Zig port of the `hexane` column layer must expose the equivalent (`nextRun()` returning `{value, count}`).
- `PeekShift::next_if(f)` (`iter/tools.rs:90-97`) takes an `impl FnOnce` predicate — in Zig, an explicit `?*const fn(*const Item) bool` field or a comptime-generic.
- `MergeIter` (`iter/tools.rs:248-308`) is a two-way dedup-merge of monotonically increasing `usize` streams. Needs a manual `peek` slot per side.

### Traits and generics

- `ReadDoc` (`read.rs:21-307`) is generic-heavy: 13 of its 30 methods take `O: AsRef<ExId>`, several take `R: RangeBounds<..>`, and two take `P: Into<Prop>` / `I: Into<CursorPosition>`. In Zig: replace `O: AsRef<ExId>` with a concrete `ExId` (callers pass `&ExId`, `&ObjId`, or `ObjId::Root` — a `pubUseAsExId` union or just a small `ExIdLike` struct), and replace `RangeBounds` with an explicit `struct { start: ?Bound, end: ?Bound }` where `Bound = union(enum){ included: usize, excluded: usize }`. This is the single most valuable signature change in the port: `RangeBounds` is a Rust ergonomic feature with no Zig analogue and it is what forces `normalize_range`'s overflow edge cases (`iter/list_range.rs:359-372`).
- `RangeBounds<String>` for maps (`read.rs:84`, `:99`) → a `StringRange` struct; the resolution logic in `op_set2/op_set.rs:398-417` is a direct port.
- `impl Iterator for X` for each of the ~8 public iterators → each becomes a plain Zig struct with a `next(self: *Self) ?Item`. No vtable needed unless they must be stored heterogeneously (they are not, except inside `DocIterInternal` where each variant is a distinct field).
- `SpansActionValue` (`iter/spans.rs:56-59`) is a hand-rolled `Either` with an explicit `#[expect(clippy::large_enum_variant)]` at `:55`, and the source comment notes boxing "loses a few milliseconds on some iteration benchmarks" (`:54`). In Zig: `union(enum){ current: Unshift, diff: Unshift }`, both inline, for the same reason.
- `DiffHook` (`text_diff/myers.rs:29-52`) is a trait with an **associated type** `type Error`. Zig equivalent: a vtable `{ equal, delete, insert, replace, finish, ptr }` where every hook returns `AutomergeError!void` directly — the associated type exists only so `TxHook` and `BlockDiffHook` can both use `AutomergeError`; collapsing it is strictly better.
- `OpQueryTerm<'a>` (`op_set2/op_set/op_query.rs:14`) is a **private bound on a public type** (`Values`). This is a Rust-specific hazard: it makes `Values` unusable as a generic parameter outside the crate. Monomorphizing to `TopOps` removes the problem entirely.
- `TextValue` (`text_value.rs:38,76,114,154`) is a trait with an associated type `Elem` (`u8`/`char`/`u16`/`String`) implemented four times over `SequenceTree<T>`. Zig: four concrete `TextValue` structs plus a `switch` on `TextEncoding` at each use site, or a comptime-generic `TextValue(comptime E: type)`.
- `Deref`/`DerefMut` on `hydrate::Map` (`hydrate/map.rs:92-102`) exposing the inner `HashMap<String, MapValue>` — there is no Zig operator overloading. Either expose the field publicly (matching the Rust behavior callers already rely on) or provide a full pass-through method set.

### Data structures

- `HashMap` → `std.StringHashMap` (for `hydrate::Map`, `UpdateSpansConfig::per_mark_expands`) or `std.AutoHashMap` (for hot maps). `SmallHashMap<A,B> = HashMap<A,B,FxBuildHasher>` (`types.rs:19-20`) → `std.AutoHashMap` / `std.HashMapUnmanaged` with a fixed-seed hasher.
- `BTreeMap<SmolStr, ScalarValue>` (`marks.rs:107`, `:64`) → `std.StringHashMap` would change **iteration order**. `MarkSet` iterates in sorted-key order and `MarkDiff::iter()` (`iter/spans.rs:342-386`) merges two iterators by key comparison assuming sorted order. Keeping `BTreeMap` semantics requires either `std.Treap`/`std.StringHashMap` + explicit sort on iteration, or a sorted `ArrayList` (marks sets are tiny — at most one entry per mark name — so a sorted array is faster in practice).
- `BTreeSet<ExId>` (`ExposeQueue`, `patches/patch_log.rs:680`) and `BTreeMap<ObjId, IterType>` (`iter/doc.rs:55`) are used for **ordered** iteration semantics. `ExposeQueue` relies on `.first()` (smallest) and `>= obj` comparison (`patches/patch_log.rs:683-706`) — that is a min-heap/ordered-set operation, not a set operation. `iter/doc.rs` relies on `pop_first()` (min) for child traversal order. A `std.PriorityQueue(ExId, void, compare)` or a `std.Treap` is required; a hash map would silently change document iteration order.
- `SequenceTree<T>` (B-tree, `sequence_tree.rs`) is the ordered-sequence primitive behind `hydrate::List` and `PatchAction::Insert`. A direct port is mechanical. Two hooks: `impl PartialEq` is O(n) (`sequence_tree.rs:471-478`) and `Debug` prints everything (`:529-537`) — in Zig use an `ArrayList` unwrapping for debug and keep `PartialEq` explicit.
- `SmolStr` (`marks.rs`) → `[]const u8` with an inline small-string optimization, or just a plain slice plus a borrowed/owned union. Zig's `[]const u8` is the borrowed half; add an owned variant if the port must round-trip `Mark.name`.
- `Cow<'a, str>` (`MapRangeItem.key`, `iter/map_range.rs:15`) → `union(enum){ borrowed: []const u8, owned: []u8 }`. `Cow` is used pervasively across the wider crate (`types::ScalarValue`, `ValueRef`, `ChangeMetadata`); a single `CowStr` type used consistently across slices is worth the investment.
- `Vec<(Value<'static>, ObjId, bool)>` in a `SequenceTree` (`patches/patch.rs:57`) — 3-way tuple payload, ~48+ bytes per element. Consider `struct { value: Value, id: ObjId, conflict: bool }` with explicit padding, and assert the size matches what `PatchAction`'s `PartialEq` and consumers expect.
- `Vec<(usize, usize, usize)>`-shaped optional triples in `Replace<D>` (`text_diff/replace.rs:20-24`) → `?struct{ a: usize, b: usize, c: usize }`, or three separate `?T` fields.

### `unsafe`-equivalent invariants

- `SequenceTreeNode::split_child` asserts `full_child.is_full()` and that lengths add up (`sequence_tree.rs:200-241`); `merge` asserts `self.is_full()` (`:414-425`); `remove_from_leaf`/`remove_element_from_non_leaf` decrement `length` unconditionally (`:243-271`). These are pointer/offset invariants in Zig: `ArrayList` bounds must be checked by the same reasoning. `find_child_index` panics rather than returning an error (`sequence_tree.rs:169`) — in Zig use `std.debug.panic` (matches) or return an error (safer, changes the contract).
- `OpSet::hydrate_op` panics on a non-`Make`/`Put` op (`hydrate.rs:302`). In Zig, switch the default arm to `unreachable` only if the op-set invariant is enforced upstream; otherwise return an error.
- `hydrate::List::apply` / `Text::apply` `todo!()` on `PatchAction::Mark` (`hydrate/list.rs:73-75`, `hydrate/text.rs:54-56`). **These are live panics reachable from the public `Value::apply_patches`.** Any document whose patch stream contains a `Mark` action will abort. A Zig port must decide: implement mark application on hydrated lists/text, or return an explicit error. Returning `error.UnsupportedMark` is the honest port; silently succeeding would hide the divergence.
- `autoserde.rs:57-58`, `:86-87` — double `unwrap()` per entry. In Zig these become `catch unreachable` and will crash on any doc where `keys()` and `get()` disagree, i.e. any list, since `Keys` yields element-id strings for sequences (`read.rs:48-49`).
- `PatchBuilder::get_path` returning `None` silently drops patches (`patches/patch_builder.rs:184-186` and five other call sites). In Zig, propagate an error or record a diagnostic; silent drop is how materialized views desync.
- `PatchLog::finish_current_view` calls `.expect("AutoCommit's patch log always belongs to its document")` (`patches/patch_log.rs:292-293`) — an `unreachable` that is a real invariant.
- `structural_character_from_rank` calls `char::from_u32(codepoint).expect("character rank should map to a valid Unicode scalar")` (`anonymize.rs:360`) — a real invariant, portable as `std.unicode.utf8Decode` + unreachable.

### Constructs with no clean Zig equivalent

- **`Box<dyn OpQueryTerm<'a>>` in a public struct** (`iter/values.rs:10`). No trait objects in Zig; monomorphize to `TopOps`.
- **Private trait bound on a public type** (`Values`, above). Not a Zig problem once monomorphized, but it is a Rust API leak worth recording.
- **Associated type in a trait used for a driver** (`DiffHook::Error`, `text_diff/myers.rs:30`). Collapse to one error type.
- **`Index<usize>` / `IndexMut<isize>` on a wrapper (`V`, `text_diff/myers.rs:110-122`)** — Zig has no indexing operators. `V` is used as `vf[k] += 1` throughout `find_middle_snake`; port to an explicit `fn get(self, k: isize) usize` / `fn set(self, k: isize, v: usize)` or, better, to a `[]usize` plus a local `offset` that is added at each access site.
- **`#[cfg(feature = "wasm")]` on trait impls** (`hydrate.rs:329`, `:336`). Rust allows `impl From<Value> for JsValue` under a feature gate. Zig has no conditional trait impls; the `wasm_bindgen::JsValue` conversions are a separate build artifact anyway and should be dropped or made an explicit `toJson`-style function.
- **`#[macro_export] macro_rules!` that expand into the public API**: `hydrate_map!`, `hydrate_list!`, `hydrate_text!` (`hydrate.rs:305-327`). These are part of the public surface (exported at crate root, used in `hydrate/tests.rs:24-28`) and have no Zig analogue. Replace with builder functions: `hydrate.Map.init(.{ .{"key", value} }, ...)` or `hydrate.mapFromPairs`.
- **`#[derive(Serialize)]` surface**: `AutoSerde` is a `serde::Serialize` impl, not a data type (`autoserde.rs:30-128`). `crate::value::ScalarValue`'s serde impls are what make `Value::Scalar(v) => v.serialize(...)` work (`autoserde.rs:127`). In Zig this is a hand-written `pub fn writeJson(self, writer: anytype) !void` on each value type, or a `std.json` emission path. The `SerializeMap`/`SerializeSeq` vtable split (`autoserde.rs:52-66`, `:79-90`) is a serializer interface — port as a small `JsonWriter` struct with `writeObjectStart(len)`, `writeKey`, `writeObjectEnd`, `writeArrayStart`, `writeArrayEnd`.
- **`thiserror` `#[error(transparent)]` / `#[from]`** (`anonymize.rs:25`, `error.rs`) → Zig error sets plus a manual `format`. `AnonymizeError::Apply(#[from] AutomergeError)` is error-set flattening; in Zig, either nest the error payload or merge the sets.
- **`impl Trait` in return position**: `MarkAccumulator::into_iter` (`marks.rs:68`), `MarkDiff::iter_before`/`iter_after`/`iter` (`iter/spans.rs:326,334,342`), `RichTextQueryState::iter` (`marks.rs:429`), `Map::iter` (`hydrate/map.rs:16`), `List::iter` (`hydrate/list.rs:25`), `ReadDoc::iter`'s default body. Each becomes a concrete iterator struct (or a comptime-generic `Iter` over the container).
- **`std::iter::from_fn` with a closure state machine** (`iter/spans.rs:345-386`): a `Pop` enum + `move ||` closure capturing two `Peekable`s. In Zig: an explicit struct with the two cursors and the `Pop` tag as an enum field.
- **`zip` + `take_while` + `rev`** in `common_prefix_len` / `common_suffix_len` (`text_diff/utils.rs:19-64`) — direct `while` loops, no allocation.
- **GATs / `dyn` + associated types**: not present in this slice. `Send`/`Sync` bounds: not present in this slice. `no_std`: not present — the crate uses `std::sync::Arc`, `std::collections`, `std::io`, `std::fmt`.
- **Allocator-generic (`impl Allocator`) plumbing**: the automerge crate takes no allocator parameter; every `Vec`/`String`/`HashMap` uses the global allocator. A Zig port must either thread an `Allocator` through every struct in this slice (a large mechanical change, since `SequenceTree`, `Map`, `List`, `Text`, `PatchLog`, `PatchBuilder`, `Anonymization` all own collections) or commit to the page allocator + an explicit arena. Recommend threading `std.mem.Allocator` — these types are long-lived and the `hydrate` tree in particular is per-document.
- **`#[derive(PartialEq)]` on `PatchAction` (`patches/patch.rs:32`)** and the hand-written `PartialEq` for `MarkDiff` (`iter/spans.rs:301-313`) and `NonDeletedMarks` (`marks.rs:441-450`) are semantic, not derived — each needs a deliberate Zig implementation.
- **`prop_map` / `prop_filter_map` / `flat_map` / `peekable` / `collect` / `by_ref`** chains throughout the slice — all become explicit loops; there is no chaining sugar in Zig.
- **`std::mem::take` / `mem::replace` / `mem::swap`** (`iter/tools.rs:49,55`; `patch_log.rs:505,506,555,562,578`; `sequence_tree.rs:57,262,329,352`) — `swap` and `replace` are one-liners; `take` needs a temporary or a `std.mem.Allocator`-aware `defer`.

## Risk

Three findings dominate, in order of how badly a Zig port would get them wrong.

1. **`query/` is dead code and will mislead the port plan.** There is no `mod query;` anywhere in the crate (`lib.rs:238-286` lists the module tree; no `query` entry; a crate-wide grep for `mod query` returns nothing). `query/list_state.rs` and `query/seek_mark.rs` are orphans from the pre-`op_set2` op-tree implementation: they import `crate::op_set`, `crate::op_tree::{LastInsert, OpTreeNode}`, `crate::query::{Index, ListState, OpQueryTerm, QueryResult, TreeQuery}`, and `crate::types::ListEncoding`, none of which exist (verified: no `op_set.rs`/`op_tree.rs`/`query.rs` at `src/` root, no `ListEncoding` in `types.rs`). They are **not compiled and not part of the API**. Anything a port plan extracts from them is fiction. The same applies to `src/automerge/tests.rs:6` (`use crate::op_tree::B`). Note the *live* replacements with deceptively similar names: `iter::Diff`/`DiffIter` (`iter/tools.rs:611,529`) supersede `query::{Index, QueryResult, TreeQuery}`; `iter/list_range::ListState` (`iter/list_range.rs:81`) supersedes `query::list_state::ListState`; and `marks::RichTextQueryState` (`marks.rs:403`) is the live one — there is a second, dead `RichTextQueryState` in `query/list_state.rs:11` with a *different* field type (`&'a OldMarkData` vs `MarkData<'a>`).

2. **`hydrate` silently loses object identity, marks, map order, and blocks, and `todo!()`s on `Mark`.** Concretely, all provable from the source: `MapValue`/`List::push`/`ListValue::new` all take an `ExId` and discard it (`hydrate/map.rs:78-82`, `hydrate/list.rs:105-107,127-133`); `hydrate::Map` is a `HashMap`, so applying patches does not preserve key order (`hydrate/map.rs:11`); `hydrate::Text.marks` is never written because `Text::apply` `todo!()`s on `PatchAction::Mark` (`hydrate/text.rs:11-14,54-56`), and `hydrate::List::apply` `todo!()`s on the same action (`hydrate/list.rs:73-75`); `OpSet::hydrate_text` goes through `self.text(obj, clock)`, so hydrated text has **no marks and no block objects at all** (`hydrate.rs:278-286`); `Value::apply` drops any patch that descends into a `Value::Text` (`hydrate.rs:97-104`); `OpSet::hydrate_op` panics on any op that is not `Make`/`Put` (`hydrate.rs:302`). A Zig port that "fixes" these will not round-trip with the Rust implementation's output, and one that copies them faithfully ships two reachable panics through the public `Value::apply_patches`. The port plan must state which behaviour it is matching; myers/patch tests will not catch the divergence because it is a data-loss divergence, not a crash.

3. **The patch pipeline's correctness rests on three non-local invariants a port will not see.** (a) `PatchLog` stores events as `OpId`, which is an *index into a sorted, insert-order-dependent actor table*; every new actor shifts indices, so `migrate_actors` must re-index all buffered events and every op id on the way, and it returns `PatchLogMismatch` when the lists diverge non-monotonically (`patches/patch_log.rs:634-659`). Drop this and every buffered event points at the wrong actor. (b) `make_current_patches` sorts events **by object, not chronologically** (`patches/patch_log.rs:510-529`, sort at `:519`); the only thing preserving chronology across a backwards time travel (isolate) is `finish_current_view` having already frozen concrete patches (`patches/patch_log.rs:279-303`). A port that "fixes" the sort to chronological order will produce correct-looking but *different* patch streams. (c) `PatchBuilder::get_path` returning `None` **silently drops the patch** (`patches/patch_builder.rs:184-186` and five other call sites), and path resolution depends on `path_map` being a live hint invalidated by `path_hint != events_len()` (`patches/patch_log.rs:496-501`) plus the cycle-breaking `seen` set (`patches/patch_builder.rs:150-153`). Any mismatch between the path map and the op set drops changes from a materialized view with no error.

Lower-severity but real:

- **`normalize_range` arithmetic is unguarded** (`iter/list_range.rs:359-372`): `Excluded(0)` as a start bound and `Included(usize::MAX)` as an end bound under/overflow. A Zig port using `?usize` bounds will need explicit handling rather than inheriting the wrap.
- **`AutoSerdeMap` reports the root's length for every nested map** (`autoserde.rs:56`). A wrong size hint; some serializers truncate or pad. The two `unwrap().unwrap()` pairs (`autoserde.rs:57-58`, `:86-87`) are reachable crashes for any document where `keys()` and `get()` disagree, i.e. any list, since `Keys` yields element-id strings for sequences (`read.rs:48-49`).
- **`Values` ignores its clock argument** (`iter/values.rs:14-24`, marked `// FIXME`). The call site compensates (`automerge.rs:1700-1704`); a port that drops the parameter at the call site instead will return current values where historical values were requested.
- **`MoveCursor::Before` resolution is an O(n) backwards walk with repeated `seek_list_opid` calls** (`automerge.rs:1805-1843`, source-marked "likely very inefficient"). Behaviour is correct; performance is not, and it will degrade worse in Zig if the port copies the loop rather than building an index.
- **The Myers vendored copy has no deadline and no advanced heuristics** (`text_diff.rs:7`, `myers.rs:19-23`). Two large dissimilar inputs degrade to the full-range `delete` + `insert` fallback (`myers.rs:298-313`) or, in the pathological case the header describes, spin. A port must reproduce the exact same fallback to keep `myers_diff` output byte-identical; a "better" diff produces a different (though arguably still correct) set of ops, which changes patch output. Related: `Replace`'s run-contiguity `debug_assert_eq!`s (`text_diff/replace.rs:98-103,114-117`) mean violations are silent in release builds.
- **`myers_block_diff`'s mark pass re-runs `doc.marks_for(text_obj, None)` inside the add loop** (`text_diff.rs:218`). Quadratic in added marks. Porting as-is inherits a performance cliff; changing it changes nothing observable.
- **`MarkSet::without_unmarks` clones the whole map then retains** (`marks.rs:182-187`, with the crate's own `// FIXME - do I need this clone?`). It is on the hot `get_marks` path.
- **`PatchBuilder::splice_text` compares `Option<Arc<MarkSet>>` by value, not by pointer** (`patches/patch_builder.rs:213`), despite the `last_mark_set` "keep this around for a quick pointer equality test" comment at `:18`. `Option<Arc<T>>: PartialEq` compares `T`, so every spliced text span pays a deep mark-set comparison. The comment is wrong and the code allocates.
- **`sequence_tree::Iter` is O(n log n)** (`sequence_tree.rs:512-526`) because it goes through `get(index)` per step rather than walking `elements` directly. `hydrate::List` and `PatchAction::Insert` both iterate through it, so patch application and list hydration are both paying tree descents. A direct walk is a free 10-100x on long lists; it changes no semantics.
- **`structural_character_from_rank` is not injective for single-byte non-printable, non-control input** (`anonymize.rs:352-357`): the entire `[0x20, 0x7f]` rank space collapses onto `0x7f`. `anonymize()` still produces a valid document, but distinct source characters can map to the same output character. Only observable via the `#[cfg(test)]` `ShapeSignature` invariant, which a port has no reason to reproduce.
- **Unverifiable without running the Rust code**: the exact coalescing boundaries in `PatchBuilder` (e.g. whether `splice_text` should compare marks by pointer or by value changes the shape of emitted patches, and the source comment and code disagree). Same for the interaction between `expose` and `should_skip` (`patches/patch_log.rs:683-689`) at the boundary case where an exposed object is also the target of the next event. Neither is decidable from reading the source; both change observable patch output.