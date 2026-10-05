# Transaction machinery, change application, and the op-set engine

## Scope

Reference checkout: `../github-automerge-automerge`, commit `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd`. All paths below are relative to `rust/automerge/src/`.

| Path | Lines | What was read |
|---|---|---|
| `transaction.rs` | 528 | module root, `commit_transaction`, both `impl_*_for_tx!` macros, full |
| `transaction/inner.rs` | 1643 | full — `TransactionInner`, `TransactionArgs`, op production, splice, batch insertion |
| `transaction/manual_transaction.rs` | 145 | full — `Transaction<'a>`, `Drop` |
| `transaction/owned_transaction.rs` | 273 | 1-120 (rest is tests) — `OwnedTransaction` |
| `transaction/result.rs` | 21 | full |
| `transaction/commit.rs` | 34 | full |
| `transaction/transactable.rs` | 203 | full — `Transactable`, `BlockOrText` |
| `autocommit.rs` | 1384 | 40-143, 429-533, 689-833, plus full signature map |
| `automerge.rs` | 2361 | 1-350, 474-703, 899-1143, 1239-1333, 1499-1573, plus full signature map |
| `automerge/current_state.rs` | 546 | grep-mapped; **entirely `#[cfg(test)] mod tests`** (line 1-2), no production code |
| `automerge/tests.rs` | 2024 | test-only, not analysed |
| `automerge/rollback_tests.rs` | 468 | test-only, not analysed |
| `change_graph.rs` | 1798 | 1-113, 126-193, 203-503, 499-603, 699-893, plus full signature map |
| `change_queue.rs` | 177 | full |
| `op_set2.rs` | 16 | full |
| `op_set2/op.rs` | 1378 | 1-203, 828-853, 1039-1085, 1206-1378, plus full signature map |
| `op_set2/op_set.rs` | 2061 | 1-70, 100-360, 460-703, 1316-1403, 1438-1548, plus full signature map |
| `op_set2/types.rs` | 777 | full |
| `op_set2/meta.rs` | 176 | full |
| `op_set2/columns.rs` | 664 | 1-103, 355-664 |
| `op_set2/parents.rs` | 133 | full |
| `op_set2/skip_list.rs` | 714 | 440-714 (impl + tests), plus grep map |
| `op_set2/change.rs` | 354 | full |
| `op_set2/change/batch.rs` | 2041 | 1-902, 900-1403, plus grep map |
| `op_set2/change/collector.rs` | 1001 | full signature map |
| `op_set2/op_set/index.rs` | 263 | full |
| `op_set2/op_set/mark_index.rs` | 819 | 1-300, plus grep map |
| `op_set2/op_set/top_op.rs` | 360 | grep map |
| `op_set2/op_set/visible.rs` | 275 | 1-103, plus grep map |
| `op_set2/op_set/op_iter.rs` | 1335 | grep map + 998-1003 |
| `op_set2/op_set/op_query.rs` | 121 | grep map |
| `op_set2/op_set/insert.rs` | 191 | grep map |
| `op_set2/op_set/found_op.rs` | 77 | grep map |
| `op_set2/op_set/elems.rs` | 43 | grep map |
| `op_set2/op_set/marks.rs` | 88 | grep map |
| `indexed_cache.rs` | 113 | full |
| `exid.rs` | 238 | full |
| `clock.rs` | 251 | full |
| `error.rs` | ~190 | full |
| `types.rs` | 774 | 22-33, 388-623, plus grep map |
| `Cargo.toml` | — | feature list |

`opid.rs` **does not exist** in this crate. `OpId` is defined in `types.rs:429-500`. The `indexed_cache.rs` module is `pub(crate)` and, after dead-code elision, only retains `len()` and `sorted()` (`indexed_cache.rs:24-56`, `:41-45`, `:59-69`); every other method is commented out. It is not referenced from any `op_set2` path.

---

## Surface

### `transaction` module root — `transaction.rs`

```rust
mod commit; mod inner; mod manual_transaction; mod owned_transaction; mod result; mod transactable;   // :1-6
pub use self::commit::CommitOptions;                                    // :8
pub use self::transactable::{BlockOrText, Transactable};                // :9
pub(crate) use inner::{TransactionArgs, TransactionInner};              // :10
pub use manual_transaction::Transaction;                                // :11
pub use owned_transaction::OwnedTransaction;                            // :12
pub use result::Failure;  pub use result::Success;                      // :13-14
pub type Result<O, E> = std::result::Result<Success<O>, Failure<E>>;   // :16

fn commit_transaction(tx: TransactionInner, doc: &mut crate::Automerge,
                      patch_log: &mut crate::PatchLog,
                      options: CommitOptions) -> Option<crate::ChangeHash>;  // :18-31

macro_rules! impl_read_doc_for_tx { ($ty:ty) => { … } }        // :37-315
macro_rules! impl_transactable_for_tx { ($ty:ty) => { … } }   // :317-526
pub(crate) use impl_read_doc_for_tx;                           // :527
pub(crate) use impl_transactable_for_tx;                       // :528
```

`commit_transaction` body (`transaction.rs:18-31`): capture `tx.get_deps()` as `historical_heads` only when `tx.get_scope().is_some()`; call `tx.commit(doc, options.message, options.time)`; when scoped, override `patch_log.heads` with `hash` or the pre-transaction deps; always `patch_log.finish_transaction(&doc.ops().actors)`.

### `transaction::commit` — `transaction/commit.rs`

```rust
#[derive(Debug, Default)]
pub struct CommitOptions { pub message: Option<String>, pub time: Option<i64> }   // :2-8
impl CommitOptions {
    pub fn with_message<S: Into<String>>(mut self, message: S) -> Self   // :12
    pub fn set_message<S: Into<String>>(&mut self, message: S) -> &mut Self  // :18
    pub fn with_time(mut self, time: i64) -> Self                        // :24
    pub fn set_time(&mut self, time: i64) -> &mut Self                   // :30
}
```

### `transaction::result` — `transaction/result.rs`

```rust
pub struct Success<O> { pub result: O, pub hash: Option<ChangeHash>, pub patch_log: PatchLog }  // :5-12
pub struct Failure<E> { pub error: E, pub cancelled: usize }                                  // :15-21
```

### `transaction::transactable` — `transaction/transactable.rs`

```rust
pub trait Transactable: ReadDoc {                                        // :9
    fn pending_ops(&self) -> usize;                                      // :11
    fn put<O: AsRef<ExId>, P: Into<Prop>, V: Into<ScalarValue>>(&mut self, obj: O, prop: P, value: V) -> Result<(), AutomergeError>;                        // :20
    fn put_object<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, object: ObjType) -> Result<ExId, AutomergeError>;                        // :33
    fn insert<O: AsRef<ExId>, V: Into<ScalarValue>>(&mut self, obj: O, index: usize, value: V) -> Result<(), AutomergeError>;                        // :41
    fn insert_object<O: AsRef<ExId>>(&mut self, obj: O, index: usize, object: ObjType) -> Result<ExId, AutomergeError>;                        // :48
    fn increment<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, value: i64) -> Result<(), AutomergeError>;                        // :53
    fn delete<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P) -> Result<(), AutomergeError>;                        // :59
    fn splice<O: AsRef<ExId>, V: Into<crate::hydrate::Value>, I: IntoIterator<Item = V>>(&mut self, obj: O, pos: usize, del: isize, vals: I) -> Result<(), AutomergeError>;                        // :69
    fn splice_text<O: AsRef<ExId>>(&mut self, obj: O, pos: usize, del: isize, text: &str) -> Result<(), AutomergeError>;                        // :77
    fn mark<O: AsRef<ExId>>(&mut self, obj: O, mark: Mark, expand: ExpandMark) -> Result<(), AutomergeError>;                        // :84
    fn unmark<O: AsRef<ExId>>(&mut self, obj: O, key: &str, start: usize, end: usize, expand: ExpandMark) -> Result<(), AutomergeError>;                        // :91
    fn split_block<O>(&mut self, obj: O, index: usize) -> Result<ExId, AutomergeError> where O: AsRef<ExId>;                        // :103
    fn join_block<O: AsRef<ExId>>(&mut self, text: O, index: usize) -> Result<(), AutomergeError>;                        // :107
    fn replace_block<O: AsRef<ExId>>(&mut self, text: O, index: usize) -> Result<ExId, AutomergeError>;                        // :112
    fn update_spans<O: AsRef<ExId>, I: IntoIterator<Item = Span>>(&mut self, text: O, config: UpdateSpansConfig, new_text: I) -> Result<(), AutomergeError>;                        // :126
    fn base_heads(&self) -> Vec<ChangeHash>;                             // :132
    fn update_text<S: AsRef<str>>(&mut self, obj: &ExId, new_text: S) -> Result<(), AutomergeError>;                        // :144
    fn update_object<O: AsRef<ExId>>(&mut self, obj: O, new_value: &crate::hydrate::Value) -> Result<(), crate::error::UpdateObjectError>;                        // :148
    fn batch_create_object<O: AsRef<ExId>, P: Into<Prop>>(&mut self, obj: O, prop: P, value: &crate::hydrate::Value, insert: bool) -> Result<ExId, AutomergeError>;                        // :161
    fn init_root_from_hydrate(&mut self, value: &crate::hydrate::Map) -> Result<(), AutomergeError>;                        // :173
}

pub enum BlockOrText<'a> { Block(crate::hydrate::Map), Text(Cow<'a, str>) }   // :199-203
```

### `transaction::manual_transaction` — `transaction/manual_transaction.rs`

```rust
pub struct Transaction<'a> { inner: Option<TransactionInner>, patch_log: PatchLog, doc: &'a mut Automerge }  // :20-27
impl<'a> Transaction<'a> {
    pub(crate) fn new(doc: &'a mut Automerge, args: TransactionArgs, patch_log: PatchLog) -> Self;  // :30
    pub fn hash_for_opid(&self, opid: &ExId) -> Option<ChangeHash>;         // :44
    pub(crate) fn empty(doc: &'a mut Automerge, args: TransactionArgs, opts: CommitOptions) -> ChangeHash;  // :50
}
impl Transaction<'_> {
    pub fn get_heads(&self) -> Vec<ChangeHash>;                             // :61
    pub fn commit(mut self) -> (Option<ChangeHash>, PatchLog);              // :67
    pub fn commit_with(mut self, options: CommitOptions) -> (Option<ChangeHash>, PatchLog);  // :91
    pub fn rollback(mut self) -> usize;                                     // :100
    fn do_tx<F, O>(&mut self, f: F) -> O where F: FnOnce(&mut TransactionInner, &mut Automerge, &mut PatchLog) -> O;  // :105-110
    fn get_scope(&self, heads: Option<&[ChangeHash]>) -> Option<crate::types::Clock>;  // :112-121
    pub(crate) fn batch_init_root_map(&mut self, value: &crate::hydrate::Map) -> Result<(), AutomergeError>;  // :124
}
impl Drop for Transaction<'_> { fn drop(&mut self) { if let Some(txn) = self.inner.take() { txn.rollback(self.doc); } } }  // :135-145
```

### `transaction::owned_transaction` — `transaction/owned_transaction.rs`

```rust
pub struct OwnedTransaction { inner: Option<TransactionInner>, patch_log: PatchLog, doc: Automerge }  // :17-25
const _: () = { /* compile-time `Send` assertion on OwnedTransaction */ };                            // :27-32
impl OwnedTransaction {
    pub(crate) fn new(mut doc: Automerge, patch_log: Option<PatchLog>, heads: Option<&[ChangeHash]>) -> Result<Self, PatchLogMismatch>;  // :37
    pub fn hash_for_opid(&self, opid: &ExId) -> Option<ChangeHash>;         // :58
    pub fn get_heads(&self) -> Vec<ChangeHash>;                             // :63
    pub fn commit(mut self) -> (Automerge, Option<ChangeHash>, PatchLog);  // :70
    pub fn commit_with(mut self, options: CommitOptions) -> (Automerge, Option<ChangeHash>, PatchLog);  // :82
    pub fn rollback(mut self) -> (Automerge, usize);                        // :92
    fn do_tx<F, O>(&mut self, f: F) -> O;                                  // :99
    fn get_scope(&self, heads: Option<&[ChangeHash]>) -> Option<crate::types::Clock>;  // :106-114
}
```

`OwnedTransaction::new` calls `doc.transaction_args(heads)`, defaults `patch_log` to `PatchLog::inactive()`, then `patch_log.begin_transaction(&doc, &args)?` (`owned_transaction.rs:37-49`).

### `transaction::inner` — `transaction/inner.rs` (all `pub(crate)`)

```rust
pub(crate) struct TransactionInner {
    actor: usize, seq: u64, start_op: NonZeroU64, time: i64, message: Option<String>,
    deps: Vec<ChangeHash>, scope: Option<Clock>, pending: Vec<TxOp>, author: Option<Author<'static>>,
}                                                                        // :22-34
struct InsertedOp { id: OpId, pos: usize, index: usize }                // :36-40
impl InsertedOp { fn id(&self) -> OpId }                               // :42-46

pub(crate) struct TransactionArgs {
    pub(crate) actor_index: usize,
    pub(crate) seq: u64,
    //pub(crate) checkpoint: OpSetCheckpoint,                            // :56 (commented out)
    pub(crate) start_op: NonZeroU64,
    pub(crate) deps: Vec<ChangeHash>,
    pub(crate) scope: Option<Clock>,
    pub(crate) author: Option<Author<'static>>,
}                                                                        // :49-64

impl TransactionInner {
    pub(crate) fn new(TransactionArgs { .. }) -> Self;                   // :68
    pub(crate) fn empty(doc: &mut Automerge, args: TransactionArgs, message: Option<String>, time: Option<i64>) -> ChangeHash;  // :94
    pub(crate) fn pending_ops(&self) -> usize;                           // :103
    fn exid_to_obj(&self, doc: &Automerge, id: &ExId) -> Result<ObjMeta, AutomergeError>;  // :107
    #[tracing::instrument(skip(self, doc))]
    pub(crate) fn commit(self, doc: &mut Automerge, message: Option<String>, time: Option<i64>) -> Option<ChangeHash>;  // :129
    pub(crate) fn commit_impl(mut self, doc: &mut Automerge, message: Option<String>, time: Option<i64>) -> ChangeHash;  // :146
    pub(crate) fn change_meta<'a>(&self, deps: Vec<u64>) -> crate::op_set2::change::BuildChangeMetadata<'a>;  // :174
    fn extra_bytes<'a>(&self) -> Cow<'a, [u8]>;                          // :193
    pub(crate) fn export(mut self, op_set: &OpSet, change_graph: &ChangeGraph) -> Change;  // :197
    pub(crate) fn rollback(self, doc: &mut Automerge) -> usize;            // :211
    pub(crate) fn put<P: Into<Prop>, V: Into<ScalarValue>>(&mut self, doc, patch_log, ex_obj: &ExId, prop: P, value: V) -> Result<(), AutomergeError>;  // :241
    pub(crate) fn put_object<P: Into<Prop>>(&mut self, doc, patch_log, ex_obj: &ExId, prop: P, value: ObjType) -> Result<ExId, AutomergeError>;  // :275
    fn next_delete(&mut self, obj: ObjMeta, index: usize, elemid: ElemId, ops: &[Op<'_>]) -> TxOp;  // :298
    fn insert_local_op(&mut self, doc, patch_log, op: TxOp, succ: &[SuccInsert], range: Range<usize>, replaced: Option<hydrate::Value>);  // :308
    pub(crate) fn insert<V: Into<ScalarValue>>(&mut self, doc, patch_log, ex_obj: &ExId, index: usize, value: V) -> Result<(), AutomergeError>;  // :331
    pub(crate) fn insert_object(&mut self, doc, patch_log, ex_obj: &ExId, index: usize, value: ObjType) -> Result<ExId, AutomergeError>;  // :349
    fn do_insert(&mut self, doc, patch_log, obj: &ObjMeta, seq_type: SequenceType, index: usize, action: OpType) -> Result<InsertedOp, AutomergeError>;  // :367
    fn insert_mark_end_after(&mut self, doc, patch_log, obj: &ObjMeta, begin: &InsertedOp, expand: bool) -> InsertedOp;  // :404
    pub(crate) fn local_op(&mut self, doc, patch_log, obj: &ObjMeta, prop: Prop, action: OpType) -> Result<Option<OpId>, AutomergeError>;  // :432
    fn local_map_op(&mut self, doc, patch_log, obj: &ObjMeta, prop: String, action: OpType) -> Result<Option<OpId>, AutomergeError>;  // :446
    fn local_list_op(&mut self, doc, patch_log, obj: &ObjMeta, index: usize, action: OpType) -> Result<Option<OpId>, AutomergeError>;  // :495
    pub(crate) fn increment<P: Into<Prop>>(&mut self, doc, patch_log, obj: &ExId, prop: P, value: i64) -> Result<(), AutomergeError>;  // :560
    pub(crate) fn delete<P: Into<Prop>>(&mut self, doc, patch_log, ex_obj: &ExId, prop: P) -> Result<(), AutomergeError>;  // :573
    pub(crate) fn splice(&mut self, doc, patch_log, ex_obj: &ExId, index: usize, del: isize, vals: impl IntoIterator<Item = impl Into<hydrate::Value>>) -> Result<(), AutomergeError>;  // :606
    pub(crate) fn splice_text<O>(&mut self, doc, patch_log, ex_obj: &ExId, index: usize, del: isize, text: &str) -> Result<(), AutomergeError>;  // :648
    fn inner_splice(&mut self, doc, patch_log, SpliceArgs { obj, index, del, splice_type }) -> Result<(), AutomergeError>;  // :673
    pub(crate) fn mark(&mut self, doc, patch_log, ex_obj: &ExId, mark: Mark, expand: ExpandMark) -> Result<(), AutomergeError>;  // :801
    pub(crate) fn unmark(&mut self, doc, patch_log, ex_obj: &ExId, name: &str, start: usize, end: usize, expand: ExpandMark) -> Result<(), AutomergeError>;  // :879
    pub(crate) fn split_block(&mut self, doc, patch_log, ex_obj: &ExId, index: usize) -> Result<ExId, AutomergeError>;  // :893
    pub(crate) fn join_block(&mut self, doc, patch_log, text: &ExId, index: usize) -> Result<(), AutomergeError>;  // :931
    pub(crate) fn replace_block(&mut self, doc, patch_log, text: &ExId, index: usize) -> Result<ExId, AutomergeError>;  // :984
    fn finalize_op(&mut self, encoding: TextEncoding, patch_log: &mut PatchLog, op: &TxOp, marks: Option<Arc<MarkSet>>, replaced: Option<&hydrate::Value>);  // :995
    pub(crate) fn update_object(&mut self, doc, patch_log, obj: &ExId, new_value: &crate::hydrate::Value) -> Result<(), crate::error::UpdateObjectError>;  // :1068
    pub(crate) fn update_map(&mut self, doc, patch_log, map: &crate::ObjId, new_value: &crate::hydrate::Map) -> Result<(), AutomergeError>;  // :1096
    pub(crate) fn update_list(&mut self, doc, patch_log, list: &crate::ObjId, new_value: &crate::hydrate::List) -> Result<(), AutomergeError>;  // :1148
    fn update_value(&mut self, doc, patch_log, parent, key: Prop, new_value, old_value: Option<(ExId, crate::Value<'_>)>) -> Result<(), AutomergeError>;  // :1203
    pub(crate) fn batch_create_object(&mut self, doc, patch_log, ex_parent: &ExId, prop: Prop, value: &hydrate::Value, insert: bool) -> Result<ExId, AutomergeError>;  // :1269
    pub(crate) fn batch_init_root_map(&mut self, doc, patch_log, value: &crate::hydrate::Map) -> Result<(), AutomergeError>;  // :1334
    pub(crate) fn get_scope(&self) -> &Option<Clock>;                      // :1382
    pub(crate) fn get_deps(&self) -> Vec<ChangeHash>;                     // :1386
    pub(super) fn next_id(&self) -> OpId;                                 // :295
}

fn values_to_splice_text(values: Vec<hydrate::Value>) -> Result<String, AutomergeError>;  // :1391
enum SpliceType<'a> { List(Vec<hydrate::Value>), Text(&'a str) }         // :1407-1410
impl SpliceType<'_> { fn seq_type(&self) -> SequenceType; fn is_empty(&self) -> bool; }  // :1413-1426
struct SpliceArgs<'a> { obj: ObjMeta, index: usize, del: isize, splice_type: SpliceType<'a> }  // :1428-1432
struct BatchInsertion<'a> { inner: &'a mut TransactionInner, doc: &'a mut Automerge, patch_log: &'a mut PatchLog, pending_start: usize, insert_pos: usize }  // :1435-1441
impl<'a> BatchInsertion<'a> {
    fn new(inner, doc, patch_log, start_pos: usize) -> Self;              // :1444
    fn next_pos(&self) -> usize;                                          // :1460
    fn append<F: FnOnce(usize, OpId) -> TxOp>(&mut self, factory: F) -> OpId;  // :1464
    fn splice_text(&mut self, container: ObjMeta, index: usize, after: ElemId, text_str: &str, marks: Option<Arc<MarkSet>>) -> SpliceResult;  // :1473
    fn finish(self);                                                      // :1514
}
struct SpliceResult { inserted_width: usize }                            // :1522-1524
fn value_to_op_type(value: &hydrate::Value) -> (Option<ObjType>, OpType);  // :1526
fn batch_bfs(batch: &mut BatchInsertion<'_>, queue: &mut VecDeque<(ObjMeta, &'_ hydrate::Value)>) -> Result<(), AutomergeError>;  // :1539
fn increment_replacement(ops: &[Op<'_>], action: &ResolvedAction, text_encoding: TextEncoding) -> Option<hydrate::Value>;  // :1605
```

### `AutoCommit` — `autocommit.rs`

```rust
pub struct AutoCommit {
    pub(crate) doc: Automerge,
    transaction: Option<(PatchLog, TransactionInner)>,
    patch_log: PatchLog,
    diff_cursor: Vec<ChangeHash>,
    diff_cache: Option<(OpRange, ObjId, bool, Vec<Patch>)>,
    save_cursor: Vec<ChangeHash>,
    isolation: Option<Vec<ChangeHash>>,
}                                                                        // :63-72
```

Inherent methods (all `pub` unless noted):

| Signature | Line |
|---|---|
| `new() -> AutoCommit` | :92 |
| `diff_opset(&self, other: &AutoCommit) -> Result<(), AutomergeError>` | :96 |
| `new_with_encoding(encoding: TextEncoding) -> AutoCommit` | :100 |
| `anonymize(&mut self) -> Result<Self, AnonymizeError>` | :114 |
| `load(data: &[u8]) -> Result<Self, AutomergeError>` | :127 |
| `load_unverified_heads(data: &[u8]) -> Result<Self, AutomergeError>` | :140 |
| `load_with(data, on_error: OnPartialLoad, mode: VerificationMode, patch_log) -> Result<Self, AutomergeError>` `#[deprecated(since="0.5.2")]` | :153-154 |
| `load_with_options(data: &[u8], options: LoadOptions<'_>) -> Result<Self, AutomergeError>` | :167 |
| `reset_diff_cursor(&mut self)` | :185 |
| `update_diff_cursor(&mut self)` | :199 |
| `diff_cursor(&self) -> Vec<ChangeHash>` | :210 |
| `make_patches(&self, patch_log: &mut PatchLog) -> Vec<Patch>` | :215 |
| `diff(&mut self, before: &[ChangeHash], after: &[ChangeHash]) -> Vec<Patch>` | :254 |
| `diff_inner(&mut self, exid, obj, before, after, top_level) -> Vec<Patch>` | :258 |
| `diff_obj(&mut self, obj: &ExId, before, after) -> Result<Vec<Patch>, AutomergeError>` | :326 |
| `diff_incremental(&mut self) -> Vec<Patch>` | :347 |
| `fork(&mut self) -> Self` | :356 |
| `fork_at(&mut self, heads: &[ChangeHash]) -> Result<Self, AutomergeError>` | :369 |
| `document(&mut self) -> &Automerge` `#[doc(hidden)]` | :384 |
| `with_actor(mut self, actor: ActorId) -> Self` | :389 |
| `set_actor(&mut self, actor: ActorId) -> &mut Self` | :395 |
| `with_author(mut self, author: Option<Author<'static>>) -> Self` | :401 |
| `set_author(&mut self, author: Option<Author<'static>>) -> &mut Self` | :407 |
| `get_actor(&self) -> &ActorId` | :413 |
| `get_actors_for_author(&self, author: &Author<'_>) -> Vec<ActorId>` | :417 |
| `get_author_for_actor(&self, actor: &ActorId) -> Option<Author<'_>>` | :421 |
| `get_author(&self) -> Option<&Author<'static>>` | :425 |
| `get_authors(&self) -> &[Author<'static>]` | :429 |
| `isolate(&mut self, heads: &[ChangeHash])` | :433 |
| `integrate(&mut self)` | :439 |
| `pub(crate) ensure_transaction_open(&mut self)` | :445 |
| `pub(crate) ensure_transaction_closed(&mut self)` | :459 |
| `load_incremental(&mut self, data: &[u8]) -> Result<usize, AutomergeError>` | :477 |
| `apply_changes(&mut self, changes: impl IntoIterator<Item = Change> + Clone) -> Result<(), AutomergeError>` | :488 |
| `apply_changes_batch(&mut self, changes: impl IntoIterator<Item = Change> + Clone) -> Result<(), AutomergeError>` | :502 |
| `merge(&mut self, other: &mut AutoCommit) -> Result<Vec<ChangeHash>, AutomergeError>` | :517 |
| `save(&mut self) -> Vec<u8>` | :530 |
| `save_with_options(&mut self, options: SaveOptions) -> Vec<u8>` | :534 |
| `save_and_verify(&mut self) -> Result<Vec<u8>, AutomergeError>` | :545 |
| `bundle<I>(&self, hashes: I) -> Result<Bundle, AutomergeError> where I: IntoIterator<Item = ChangeHash>` | :559 |
| `debug_cmp(&self, other: &Self)` `#[cfg(test)]` | :566 |
| `pub(crate) validate_top_index(&self) -> bool` `#[cfg(test)]` | :571 |
| `save_nocompress(&mut self) -> Vec<u8>` | :577 |
| `save_incremental(&mut self) -> Vec<u8>` | :590 |
| `is_empty(&self) -> bool` | :599 |
| `save_after(&mut self, heads: &[ChangeHash]) -> Vec<u8>` | :604 |
| `get_missing_deps(&mut self, heads: &[ChangeHash]) -> Vec<ChangeHash>` | :609 |
| `get_last_local_change(&mut self) -> Option<Change>` | :615 |
| `get_changes(&mut self, have_deps: &[ChangeHash]) -> Vec<Change>` | :620 |
| `get_changes_meta(&mut self, have_deps: &[ChangeHash]) -> Vec<ChangeMetadata<'_>>` | :625 |
| `get_change_by_hash(&mut self, hash: &ChangeHash) -> Option<Change>` | :630 |
| `get_change_meta_by_hash(&mut self, hash: &ChangeHash) -> Option<ChangeMetadata<'_>>` | :635 |
| `get_changes_added(&mut self, other: &mut Self) -> Vec<Change>` | :641 |
| `import(&self, s: &str) -> Result<(ExId, ObjType), AutomergeError>` `#[doc(hidden)]` | :648 |
| `import_obj(&self, s: &str) -> Result<ExId, AutomergeError>` `#[doc(hidden)]` | :653 |
| `dump(&mut self)` `#[doc(hidden)]` | :658 |
| `fragments<R: RangeBounds<usize>>(&self, levels: R) -> Vec<Fragment>` `#[doc(hidden)]` | :669 |
| `get_fragment(&self, head: ChangeHash) -> Option<Fragment>` `#[doc(hidden)]` | :678 |
| `bundle_fragments<I: IntoIterator<Item = Fragment>>(&self, fragments: I) -> Vec<Vec<u8>>` | :688 |
| `get_heads(&mut self) -> Vec<ChangeHash>` | :695 |
| `commit(&mut self) -> Option<ChangeHash>` | :707 |
| `commit_with(&mut self, options: CommitOptions) -> Option<ChangeHash>` | :728 |
| `rollback(&mut self) -> usize` | :742 |
| `empty_change(&mut self, options: CommitOptions) -> ChangeHash` | :762 |
| `sync(&mut self) -> impl SyncDoc + '_` | :779 |
| `hash_for_opid(&self, opid: &ExId) -> Option<ChangeHash>` | :790 |
| `get_scope(&self, heads: Option<&[ChangeHash]>) -> Option<Clock>` | :794 |
| `patch_to(&mut self, after: &[ChangeHash])` | :816 |
| `has_our_changes(&mut self, state: &crate::sync::State) -> bool` | :827 |

`impl ReadDoc for AutoCommit` at `autocommit.rs:833-1067`; `impl Transactable for AutoCommit` at `:1069-1303`; `impl SyncDoc for SyncWrapper<'_>` at `:1306-1344`; `struct OpRange { before_len, hashes }` at `:1346-1373`; `mod tests` at `:1375-1384` (asserts `AutoCommit: Send`).

### `Automerge` — `automerge.rs`

```rust
pub(crate) enum Actor { Unused(ActorId), Cached(usize) }                       // :47-50
impl Actor {
    fn remove_actor(&mut self, index: usize, actors: &[ActorId]);             // :53
    fn rewrite_with_new_actor(&mut self, index: usize);                       // :63
}
pub enum OnPartialLoad { Ignore, Error }                                       // :74-79
pub enum StringMigration { NoMigration, ConvertToText }                       // :83-87
pub struct LoadOptions<'a> { on_partial_load, verification_mode, patch_log, string_migration, text_encoding, author }  // :91-97
impl<'a> LoadOptions<'a> {
    pub fn new() -> LoadOptions<'static>;                                      // :101
    pub fn on_partial_load(self, OnPartialLoad) -> Self;                      // :108
    pub fn verification_mode(self, VerificationMode) -> Self;                  // :118
    pub fn patch_log(self, &'a mut PatchLog) -> Self;                         // :128
    pub fn migrate_strings(self, StringMigration) -> Self;                     // :152
    pub fn text_encoding(self, TextEncoding) -> Self;                         // :159
    pub fn author(self, Author<'static>) -> Self;                             // :166
}

pub struct Automerge {
    pub(crate) queue: ChangeQueue,       // :251
    pub(crate) change_graph: ChangeGraph,// :252
    authors: Authors,                    // :253
    deps: HashSet<ChangeHash>,           // :255
    pub(crate) ops: OpSet,               // :257
    actor: Actor,                        // :259
    author: Option<Author<'static>>,     // :261
}                                                                             // :248-262
```

Selected `Automerge` methods:

| Signature | Line |
|---|---|
| `new() -> Self` | :267 |
| `anonymize(&self) -> Result<Self, AnonymizeError>` | :292 |
| `init_from_hydrate(&mut self, value: &crate::hydrate::Map) -> Result<(), AutomergeError>` | :300 |
| `new_with_encoding(encoding: TextEncoding) -> Self` | :307 |
| `pub(crate) from_parts(ops: OpSet, change_graph: ChangeGraph, authors: Authors) -> Self` | :321 |
| `pub(crate) ops_mut(&mut self) -> &mut OpSet` | :336 |
| `pub(crate) ops(&self) -> &OpSet` | :340 |
| `pub(crate) changes(&self) -> &ChangeGraph` | :344 |
| `is_empty(&self) -> bool` | :349 |
| `pub(crate) actor_id(&self) -> &ActorId` | :353 |
| `with_actor(mut self, actor: ActorId) -> Self` | :361 |
| `set_actor(&mut self, actor: ActorId) -> &mut Self` | :367 |
| `with_author / set_author` | :376, :389 |
| `get_author / get_actors_for_author / get_authors / get_author_for_actor / get_actor` | :399, :403, :410, :414, :420 |
| `pub(crate) remove_actor(&mut self, actor: usize)` | :427 |
| `pub(crate) assert_no_unused_actors(&self, panic: bool)` | :434 |
| `pub(crate) remove_unused_actors(&mut self, panic: bool)` | :446 |
| `fn get_or_create_actor_index(&mut self) -> usize` | :457 |
| `fn get_actor_index(&self) -> Option<usize>` | :468 |
| `transaction(&mut self) -> Transaction<'_>` | :476 |
| `transaction_log_patches(&mut self, mut patch_log: PatchLog) -> Result<Transaction<'_>, crate::PatchLogMismatch>` | :487 |
| `transaction_at(&mut self, mut patch_log: PatchLog, heads: &[ChangeHash]) -> Result<Transaction<'_>, crate::PatchLogMismatch>` | :501 |
| `into_transaction(self, patch_log: Option<PatchLog>, heads: Option<&[ChangeHash]>) -> Result<OwnedTransaction, crate::PatchLogMismatch>` | :525 |
| `pub(crate) transaction_args(&mut self, heads: Option<&[ChangeHash]>) -> TransactionArgs` | :533 |
| `pub(crate) save_checkpoint(&self) -> HashMap<&'static str, Vec<u8>>` `#[cfg(test)]` | :580 |
| `transact<F, O, E>(&mut self, f: F) -> transaction::Result<O, E> where F: FnOnce(&mut Transaction<'_>) -> Result<O, E>` | :586 |
| `transact_with<F, O, E, C>(&mut self, c: C, f: F) -> transaction::Result<O, E> where C: FnOnce(&O) -> CommitOptions` | :594 |
| `fn transact_with_impl<F, O, E, C>(...)` | :603 |
| `transact_and_log_patches<F, O, E>(...)` | :635 |
| `transact_and_log_patches_with<F, O, E, C>(...)` | :643 |
| `fn transact_and_log_patches_with_impl<F, O, E, C>(...)` | :655 |
| `empty_commit(&mut self, opts: CommitOptions) -> ChangeHash` | :693 |
| `fork(&self) -> Self` | :702 |
| `fork_at(&self, heads: &[ChangeHash]) -> Result<Self, AutomergeError>` | :711 |
| `pub(crate) get_changes_by_hashes<I>(&self, hashes: I) -> Result<Vec<Change>, AutomergeError>` | :737 |
| `pub(crate) exid_to_opid(&self, id: &ExId) -> Result<OpId, AutomergeError>` | :744 |
| `pub(crate) get_obj_meta(&self, id: ObjId) -> Result<ObjMeta, AutomergeError>` | :760 |
| `pub(crate) op_cursor_to_opid(&self, cursor: &OpCursor, clock: Option<&Clock>) -> …` | :770 |
| `pub(crate) exid_to_obj(&self, id: &ExId) -> Result<ObjMeta, AutomergeError>` | :788 |
| `pub(crate) id_to_exid(&self, id: OpId) -> ExId` | :794 |
| `diff_opset(&self, other: &Self) -> Result<(), AutomergeError>` | :798 |
| `load / load_unverified_heads / load_with / load_with_options` | :834, :841, :862, :883 |
| `rescue(data: &[u8]) -> Result<hydrate::Value, AutomergeError>` | :897 |
| `fn load_with_options_and_mark_validation(data, options, mark_order)` | :906 |
| `make_patches / current_state / load_incremental / load_incremental_log_patches` | :1005, :1014, :1027, :1033 |
| `pub(crate) log_current_state(&self, obj: ObjMeta, patch_log: &mut PatchLog, …)` | :1071 |
| `fn seq_for_actor(&self, actor: &ActorId) -> u64` | :1082 |
| `pub(crate) has_actor_seq(&self, change: &Change) -> bool` | :1089 |
| `apply_changes / apply_changes_log_patches / merge / merge_and_log_patches` | :1097, :1106, :1115, :1121 |
| `bundle<I>` | :1141 |
| `save_with_options / save / save_and_verify / save_nocompress / save_after` | :1149, :1169, :1174, :1181, :1194 |
| `pub(crate) filter_changes(&self, heads: &[ChangeHash], changes: &mut BTreeSet<ChangeHash>)` | :1206 |
| `get_last_local_change(&self) -> Option<Change>` | :1223 |
| `pub(crate) clock_range(&self, before, after) -> ClockRange` | :1230 |
| `pub(crate) clock_at(&self, heads: &[ChangeHash]) -> Option<Clock>` | :1241 |
| `fn get_isolated_actor_index(&mut self, level: usize) -> usize` | :1249 |
| `pub(crate) isolate_actor(&mut self, heads: &[ChangeHash]) -> Isolation` | :1259 |
| `fn get_hash(&self, actor: usize, seq: u64) -> Result<ChangeHash, AutomergeError>` | :1283 |
| `pub(crate) update_history(&mut self, change: &Change)` | :1287 |
| `fn insert_actor(&mut self, index: usize, actor: ActorId) -> usize` | :1301 |
| `pub(crate) put_actor_ref(&mut self, actor: &ActorId) -> usize` | :1309 |
| `fn put_actor(&mut self, actor: ActorId) -> usize` | :1316 |
| `fn update_deps(&mut self, change: &Change)` | :1323 |
| `import / import_obj / dump` | :1331, :1344, :1364 |
| `diff / diff_obj` | :1420, :1444 |
| `fragments / get_fragment / bundle_fragments` `#[doc(hidden)]` | :1465, :1481, :1491 |
| `get_heads(&self) -> Vec<ChangeHash>` | :1506 |
| `get_changes / get_changes_meta / get_change_meta_by_hash` | :1512, :1516, :1525 |
| `get_changes_added(&self, other: &Self) -> Vec<Change>` | :1532 |
| `hash_for_opid(&self, exid: &ExId) -> Option<ChangeHash>` | :1559 |
| `fn calculate_marks / fn calculate_marks_slow` | :1569, :1598 |
| `hydrate / pub(crate) hydrate_obj / parents_for / keys_for / iter_for / map_range_for / list_range_for / values_for / length_for / text_for / spans_for / get_cursor_for / get_cursor_position_for / marks_for / get_for / get_all_for / get_marks_for` | :1633, :1638, :1652, :1662, :1669, :1676, :1688, :1700, :1707, :1714, :1723, :1732, :1760, :1851, :1859, :1891, :1929 |
| `fn convert_scalar_strings_to_text(&mut self) -> Result<(), AutomergeError>` | :1973 |
| `has_our_changes(&self, other: &crate::sync::State) -> bool` | :2027 |
| `pub(crate) has_change(&self, head: &ChangeHash) -> bool` | :2031 |
| `pub(crate) missing_deps_from(&self, start: impl Iterator<Item = ChangeHash>) -> Vec<ChangeHash>` | :2037 |
| `text_encoding(&self) -> TextEncoding` | :2068 |

```rust
impl ReadDoc for Automerge { … }                                     // :2073-2320
impl Default for Automerge { fn default() -> Self { Self::new() } }  // :2322-2326
pub struct SaveOptions { pub deflate: bool, pub retain_orphans: bool }  // :2330-2335
impl SaveOptions { fn compress(&self) -> CompressConfig }              // :2338
impl Default for SaveOptions { deflate: true, retain_orphans: true }    // :2348-2353
pub(crate) struct Isolation { actor_index: usize, seq: u64, … }        // :2357-2360
```

`automerge/current_state.rs` contains only `#[cfg(test)] mod tests` (line 1-2) and defines no production type or function.

### `ChangeGraph` — `change_graph.rs`

```rust
pub(crate) struct ChangeGraph {
    edges: Vec<Edge>,                                   // :29
    hashes: Vec<ChangeHash>,                            // :30
    actors: Vec<ActorIdx>,                              // :31
    parents: Vec<Option<EdgeIdx>>,                      // :32
    seq: Vec<u32>,                                      // :33
    max_ops: Vec<u32>,                                  // :34
    max_op: u32,                                        // :35
    num_ops: hexane::Column<u64>,                       // :36
    timestamps: hexane::DeltaColumn<i64>,               // :37
    messages: hexane::Column<Option<String>>,           // :38
    extra_bytes_meta: hexane::PrefixColumn<ValueMeta>,  // :39
    extra_bytes_raw: Vec<u8>,                           // :40
    heads: BTreeSet<ChangeHash>,                        // :41
    nodes_by_hash: HashMap<ChangeHash, NodeIdx>,        // :42
    clock_cache: HashMap<NodeIdx, SeqClock>,            // :43
    seq_index: Vec<Vec<NodeIdx>>,                       // :44
    fragment_top: SeqClock,                             // :45
    fragments: Vec<FragmentNode>,                       // :46
}                                                        // :27-47
pub(crate) struct ChangeGraphCols(ChangeGraph);         // :49
const CACHE_STEP: u32 = 16;                             // :51
struct NodeIdx(u32);  struct EdgeIdx(NonZeroU32);       // :54, :65
struct Edge { target: NodeIdx, next: Option<EdgeIdx> }  // :77-81  (child→parent; child implicit)
```

| Method | Line |
|---|---|
| `new(num_actors: usize) -> Self` | :85 |
| `all_actor_ids / actor_ids / unused_actors` → `impl Iterator<Item = usize>` | :108, :112, :119 |
| `heads(&self) -> impl Iterator<Item = ChangeHash>` | :126 |
| `heads_are_current(&self, heads: &[ChangeHash]) -> bool` | :132 |
| `head_indexes(&self) -> impl Iterator<Item = u64>` | :141 |
| `num_actors(&self) -> usize` (= `seq_index.len()`) | :147 |
| `insert_actor(&mut self, idx: usize)` | :151 |
| `remove_actor(&mut self, idx: usize)` | :169 |
| `len(&self) -> usize` (= `actors.len()`, i.e. **change count**) | :188 |
| `is_empty(&self) -> bool` | :192 |
| `hash_to_index(&self, hash) -> Option<usize>` | :196 |
| `index_to_hash(&self, index) -> Option<&ChangeHash>` | :200 |
| `max_op(&self) -> u64` | :204 |
| `max_op_for_actor(&mut self, actor_index: usize) -> u64` | :208 |
| `seq_for_actor(&self, actor: usize) -> u64` | :216 |
| `encode(&self, out: &mut Vec<u8>) -> RawColumns<Uncompressed>` | :236 |
| `validate(bytes, cols) -> Result<RawColumns<Uncompressed>, BadColumnLayout>` | :274 |
| `opid_to_hash(&self, id: OpId) -> Option<ChangeHash>` | :300 |
| `deps_for_hash(&self, hash) -> impl Iterator<Item = ChangeHash>` | :322 |
| `has_change(&self, hash) -> bool` | :334 |
| `get_bundle_metadata<I: IntoIterator<Item=ChangeHash>>(…) -> impl Iterator<Item = Result<BundleMetadata<'_>, MissingDep>>` | :338 |
| `get_build_metadata<I>(hashes) -> Result<Vec<BuildChangeMetadata<'_>>, MissingDep>` | :384 |
| `iter(&self) -> ChangeIter<'_>` | :404 |
| `get_build_metadata_for_indexes / get_build_indexes / get_hashes / get_build_metadata_clock` | :420, :457, :476, :491 |
| `get_hash_for_actor_seq(&self, actor, seq) -> Result<ChangeHash, AutomergeError>` | :500 |
| `update_heads / add_nodes / add_changes` | :513, :520, :545 |
| `get_fragment / loose_commit / fragments / loose_fragments / fragment_content / bfs_until_clock / cache_fragments / cache_fragment` | :585, :598, :614, :629, :641, :650, :677, :683 |
| `add_change(&mut self, change, actor, authors) -> Result<(), MissingDep>` | :708 |
| `cache_clock / add_parent / deps / parents / heads_to_nodes` | :729, :745, :766, :774, :784 |
| `clock_at(&self, heads: &[ChangeHash]) -> Clock` | :794 |
| `seq_clock_for_heads(&self, heads: &[ChangeHash]) -> SeqClock` | :808 |
| `calculate_clock / calculate_clock_inner` | :817, :827 |
| `remove_ancestors / traverse_ancestors` | :855, :868 |
| `impl ChangeGraphCols { len / iter / finalize / load }` | :884-1051 |
| `pub struct MissingDep(ChangeHash)` | :1055 |
| `pub(crate) struct ChangeIter<'a>` (`Iterator<Item = BuildChangeMetadata<'a>>`) | :1644-1727 |
| `struct FragmentNode { head: NodeIdx, deps: Vec<NodeIdx>, … }` | :1731-1735 |
| `#[doc(hidden)] pub struct Fragment { pub head: ChangeHash, pub level: usize, pub boundary: Vec<ChangeHash>, … }` | :1768-1776 |
| `pub(crate) mod ids` (column id constants) | :1778 |

### `ChangeQueue` / `ChangeBatch` — `change_queue.rs`

```rust
pub(crate) struct ChangeBatch { changes: Vec<Change>, hashes: HashSet<ChangeHash>, incoming_actor_seqs: HashSet<(ActorId, u64)> }  // :6-10
impl ChangeBatch {
    pub(crate) fn new() -> Self;                                                        // :13
    pub(crate) fn push(&mut self, change: Change) -> Result<(), AutomergeError>;       // :20
}
pub(crate) struct ChangeQueue { changes: Vec<Change>, hashes: HashSet<ChangeHash>, incoming_actor_seqs: HashSet<(ActorId, u64)> }  // :45-50
impl ChangeQueue {
    pub(crate) fn new() -> Self;                                                        // :53
    pub(crate) fn is_empty(&self) -> bool;                                              // :60
    pub(crate) fn iter(&self) -> impl Iterator<Item = &Change>;                        // :64
    pub(crate) fn remove_actor_branch_from(&mut self, actor: &ActorId, seq: u64);      // :71
    pub(crate) fn extend(&mut self, batch: ChangeBatch);                                // :111
    pub(crate) fn pop_topo_sorted_ready(&mut self, change_graph: &ChangeGraph) -> Vec<Change>;  // :127
}
```

### `op_set2` module root — `op_set2.rs`

```rust
pub(crate) mod change; pub(crate) mod columns; pub(crate) mod meta; pub(crate) mod op;
pub(crate) mod op_set; pub(crate) mod parents; pub(crate) mod types;                   // :1-7
pub use parents::{Parent, Parents};                                                    // :9
pub(crate) use op::{ChangeOp, Op, OpBuilder, SuccInsert, TxOp};                        // :11
pub(crate) use types::{ActorIdx, KeyRef, MarkData, OpType, PropRef};                    // :12
pub use types::{ChangeMetadata, ScalarValue, ValueRef};                                 // :14
pub(crate) use meta::ValueMeta;                                                        // :16
pub(crate) use op_set::{OpQuery, OpQueryTerm, OpSet, ReadOpError, TopOps};              // :17
```

The `pub` items are re-exported at crate root as `automerge::ScalarValueRef`, `automerge::ValueRef`, `automerge::ChangeMetadata`, `automerge::Parent`, `automerge::Parents`.

### `op_set2::types` — `op_set2/types.rs`

```rust
pub(crate) struct ActorIdx(pub(crate) u32);                                            // :19
impl From<usize|u64|…> for ActorIdx; impl From<ActorIdx> for usize|u64                  // :24-49
impl fmt::Display for ActorIdx                                                          // :21
pub(crate) struct MarkData<'a> { pub(crate) name: Cow<'a, str>, pub(crate) value: ScalarValue<'a> }  // :52-55
pub(crate) enum Action { MakeMap, MakeList, MakeText, Set, Delete, Increment, MakeTable, Mark }  // :61-82
impl From<Action> for u64  // 0..=7                                                     // :88
impl TryFrom<u64> for Action                                                           // :99
impl TryFrom<Action> for ObjType                                                       // :115
pub(crate) enum OpType<'a> { Make(ObjType), Delete, Increment(i64), Put(ScalarValue<'a>), MarkBegin(bool, MarkData<'a>), MarkEnd(bool) }  // :129-136
impl OpType<'_> { pub(crate) fn from_action_and_value(action, value, mark_name, expand) -> OpType<'a> }  // :140

pub enum ScalarValue<'a> { Bytes(Cow<'a,[u8]>), Str(Cow<'a,str>), Int(i64), Uint(u64), F64(f64),
                          Counter(i64), Timestamp(i64), Boolean(bool),
                          Unknown { type_code: u8, bytes: Cow<'a,[u8]> }, Null }        // :177-189
impl fmt::Display for ScalarValue                                                       // :191
impl<'a> ScalarValue<'a> {
    pub fn as_i64(&self) -> i64;                                                        // :216
    pub fn str(s: &'a str) -> Self;                                                    // :222
    pub(crate) fn to_owned(&self) -> types::ScalarValue;                               // :226
    pub(crate) fn into_legacy(self) -> types::ScalarValue;                              // :246
    pub(crate) fn into_owned(self) -> ScalarValue<'static>;                            // :269
    pub(crate) fn from_raw(meta: ValueMeta, raw: &'a [u8]) -> Result<Self, ReadScalarError>;  // :318
    pub(crate) fn to_raw(&self) -> Option<Cow<'a, [u8]>>;                              // :348
    pub(super) fn as_raw(&self) -> Option<Cow<'_, [u8]>>;                               // :374
    pub(crate) fn meta(&self) -> ValueMeta;                                            // :400
}
pub(crate) enum ReadScalarError { Uleb, Leb, Float, Str }                              // :467-476
pub(crate) enum PropRef<'a> { Map(Cow<'a, str>), Seq(usize) }                           // :568-571
pub(crate) enum KeyRef<'a> { Map(Cow<'a, str>), Seq(ElemId) }                          // :574-577
impl PartialOrd for KeyRef<'_>   // Map vs Map, Seq vs Seq; None across variants        // :580-589
impl<'a> KeyRef<'a> { actor/icounter/key_str/elemid }                                  // :604-628
impl types::Exportable for KeyRef<'_>                                                  // :630
pub enum ValueRef<'a> { Object(ObjType), Scalar(ScalarValue<'a>) }                      // :641-644
impl<'a> ValueRef<'a> { from_action_value / hydrate / into_owned / into_value / to_value / str / is_object }  // :655-712
impl hexane::ColumnValue for ActorIdx / Action                                          // :716-758
pub struct ChangeMetadata<'a> { pub actor: Cow<'a, ActorId>, pub author: Option<Author<'a>>,
    pub seq: u64, pub start_op: u64, pub max_op: u64, pub timestamp: i64,
    pub message: Option<Cow<'a, str>>, pub deps: Vec<ChangeHash>,
    pub hash: ChangeHash, pub extra: Cow<'a, [u8]> }                                    // :730-742
impl ChangeMetadata<'_> { pub fn into_owned(self) -> ChangeMetadata<'static> }         // :744
```

### `op_set2::meta` — `op_set2/meta.rs`

```rust
pub(crate) enum ValueType { Null, False, True, Uleb, Leb, Float, String, Bytes, Counter, Timestamp, Unknown(u8) }  // :4-16
pub(crate) struct ValueMeta(u64);                                                       // :19
impl ValueMeta { pub(crate) fn type_code(&self) -> ValueType; pub(crate) fn length(&self) -> usize }  // :22-43
impl From<&crate::ScalarValue> for ValueMeta                                             // :56-73
impl hexane::ColumnValue for ValueMeta / RleValue / PrefixValue                          // :116-146
```

### `op_set2::op` — `op_set2/op.rs`

```rust
pub(crate) trait AsBuilder: Debug { fn as_builder(&self) -> &OpBuilder<'_>; }           // :16
pub(crate) struct ChangeOp { succ: Vec<(OpId, Option<i64>)>, pos: Option<usize>, subsort: usize, conflicted: bool, bld: OpBuilder<'static> }  // :50-57
pub(crate) struct TxOp { obj_type: ObjType, index: usize, pos: usize, noop: bool, bld: OpBuilder<'static>, undo: Vec<SuccUndo>, reset_range: Option<Range<usize>> }  // :163-175
pub(crate) struct OpBuilder<'a> { id: OpId, obj: ObjId, action: Action, key: KeyRef<'a>, value: ScalarValue<'a>, insert: bool, expand: bool, mark_name: Option<Cow<'a, str>>, pred: Vec<OpId> }  // :177-188
pub(crate) struct Op<'a> { pos: usize, conflict: bool, id: OpId, action: Action, obj: ObjId, key: KeyRef<'a>, insert: bool, value: ScalarValue<'a>, expand: bool, mark_name: Option<&'a str>, succ_cursors: SuccCursors<'a> }  // :831-844
pub(crate) struct SuccCursors<'a> { len, succ_actor, succ_counter, inc_values }          // :846-852
pub(crate) struct SuccIncCursors<'a>(SuccCursors<'a>); struct IncCursors<'a>(SuccCursors<'a>);  // :871, :873
pub(crate) struct SuccInsert { id: OpId, pos: usize, inc: Option<i64>, … }               // :933-939
pub(crate) trait AsChangeOp { obj_actor, obj_ctr, key_actor, key_ctr, key_str, insert, action, value, value_meta, pred_count, expand, mark_name, op_id_ctr, pred }  // :1208-1225
pub(crate) trait OpLike: Debug { type SuccIter<'b>: ExactSizeIterator<Item=OpId>; id_actor, id_ctr, id, obj, action, key_str, key, raw_value, meta_value, insert, expand, succ, succ_inc, mark_name, mark_index, width, visible, top, obj_info }  // :1327-1372
pub(crate) struct OpStepper<'a> { obj: ObjId, key: KeyRef<'a>, id: OpId }                 // :1374-1378
```

Notable constructors: `TxOp::list` `:261`, `TxOp::map` `:296`, `TxOp::insert` `:330`, `TxOp::insert_val` `:360`, `TxOp::insert_obj` `:390`, `TxOp::list_del` `:421`; `Op::del` `:1158`; `Op::add_succ(&self, id, inc) -> SuccInsert` `:956`; `Op::fix_counter` `:979`; `Op::build(self, pred) -> OpBuilder<'a>` `:1134`; `Op::step(&self, stepper) -> bool` `:1048`; `Op::cursor(&self) -> Result<ElemId, AutomergeError>` `:1073`.

### `op_set2::op_set` — `op_set2/op_set.rs`

```rust
pub(crate) struct OpSet { pub(crate) actors: Vec<ActorId>, pub(crate) obj_info: ObjIndex, cols: Columns, pub(crate) text_encoding: TextEncoding }  // :59-65
pub(crate) type InsertAcc<'a> = hexane::PrefixIter<'a, bool>;                             // :57
```

`OpSet` methods (all `pub(crate)`), grouped:

*Structure / lifecycle*: `debug_cmp` :69, `save_checkpoint` :74, `from_actors` :79, `dump` :88, `new` :1191, `load(doc, text_encoding)` :1200, `from_doc_ops` :1208, `from_parts` :1224, `export` :1242, `insert_actor` :1400, `rewrite_with_new_actor` :1407, `remove_actor` :1419.

*Mutation*: `splice_objects<O: OpLike>(&mut self, ops: &[O])` :232, `splice<O: OpLike>(&mut self, pos: usize, ops: &[O]) -> usize` :240, `undo_op(&mut self, op: &TxOp)` :246, `add_succ(&mut self, op_pos: &[SuccInsert])` :259, `add_succ_with_undo(&mut self, op_pos: &[SuccInsert]) -> Vec<SuccUndo>` :285, `undo_succ(&mut self, op_pos: &[SuccUndo])` :327, `conflict(&mut self, pos)` :140, `expose(&mut self, pos)` :147, `reset_top(&mut self, range: Range<usize>)` :107, `set_indexes(&mut self, indexes: Indexes)` :216, `index_builder(&self) -> IndexBuilder` :103.

*Queries*: `parent_object` :353, `keys` :377, `spans` :381, `list_range` :386, `map_range` :396, `len` :421, `sub_len` :425, `seq_length` :429, `query_insert_at_text` :463, `query_insert_at_list` :546, `query_insert_at` :569, `seek_ops_by_map_key` :611, `seek_ops_by_index` :632, `seek_ops_by_index_slow` :656, `list_register_at_pos` :688, `seek_list_ops_by_index_fast` :706, `seek_text_ops_by_index_fast` :735, `get` :786, `elemid_at` :793, `get_op_id_pos` :830, `seek_list_opid` :837, `seek_list_opid_fast` :853, `seek_list_opid_slow` :878, `action_iter_range` :898, `insert_acc_range` :902, `insert_iter_range` :906, `top_index_range` :910, `all_of_range_is_top` :916, `key_str_iter_range` :927, `action_value_iter` :934, `action_value_top_iter` :949, `calculate_marks_fast` :961, `get_marks_fast` :1026, `text` :1041, `id_to_exid` :1054, `iter_obj_ids` :1062, `iter_objs` :1077, `top_ops` :1085, `to_string<E: Exportable>` :1093, `find_op_by_id_and_vis` :1100, `find_op_by_id_and_vis_fast` :1114, `find_op_by_id_and_vis_slow` :1121, `get_increment_diff_at_pos` :1142, `object_type` :1171, `object_parent` :1175, `get_actor` :1179, `get_actor_safe` :1183, `lookup_actor` :1187, `scope_to_obj` :1246, `iter_ctr_range` :1254, `prop_range` :1268, `iter_obj` :1273, `value_iter_range` :1278, `id_iter_range` :1285, `mark_info_iter_range` :1292, `succ_iter_range` :1299, `iter_range` :1318, `obj_id_iter` :1344, `iter` :1348, `validate` :160, `validate_op_order` :167, `validate_top_index` :177, `parents` :95.

Supporting types in the same file: `struct Parent { obj, typ, prop, visible }` :1432; `struct QueryNth { marks: Option<Arc<MarkSet>>, pos, index, elemid }` :1440; `struct FoundOpId<'a> { op, index, visible }` :1448; `struct OpsFound<'a> { index, ops: Vec<Op<'a>>, end_pos, range }` :1455 with `resolve_action` :1482 and `elemid` :1511; `enum ResolvedAction { ConflictResolution(types::OpType), VisibleUpdate(types::OpType) }` :1525-1530 with `is_increment` :1534; `struct IterObjIds<'a>` :1543; `struct SuccUndo { succ: SuccInsert, visible: Option<bool>, text: Option<Option<u32>>, top: … }` :1587-1592.

Re-exports from `op_set/*.rs` (`op_set.rs:39-56`): `IndexBuilder`, `MarkOrderValidator`, `ObjIndex`, `ObjInfo`; `Keys`, `ListRange`, `MapRange`, `SpansInternal`; `OpsFoundIter`, `InsertQuery`, `MarkIdx`, `MarkIndexBuilder`, `MarkIndexColumn`, `MarkIter`, `NoMarkIter`; `ActionIter`, `ActionValueIter`, `CtrWalker`, `InsertIter`, `KeyIter`, `MarkInfoIter`, `ObjIdIter`, `OpIdIter`, `OpIter`, `ReadOpError`, `SuccIterIter`, `SuccWalker`, `ValueIter`; `FixCounters`, `OpQuery`, `OpQueryTerm`; `TopIter`, `TopOps`, `VisIter`, `VisibleOpIter`.

### `op_set2::op_set` keyset / shadow / insulation structures

The "shadow" structures are the derived index columns; the "insulation" structures are the clock/scope plumbing.

**Index (shadow) columns — `op_set2/op_set/index.rs`**

```rust
pub(crate) struct IndexBuilder { counters: HashMap<OpId, Vec<(usize, usize)>>, succ: Vec<u32>, top: Vec<bool>, widths: Vec<u64>, incs: Vec<Option<i64>>, marks: Vec<Option<MarkIndexBuilder>>, obj_info: ObjIndex, last_flush: usize, text_encoding: TextEncoding, mark_order: MarkOrderValidator }  // :9-20
pub(crate) struct MarkOrderValidator { begins: HashMap<OpId, ObjId>, error: Option<String> }   // :22-26
impl MarkOrderValidator { process_op :29, process_mark_index :34, take_error :45, fn check_mark_op :52 }
pub(crate) struct ObjIndex(pub(crate) HashMap<OpId, ObjInfo>);                              // :78
impl ObjIndex { object_type :81, object_parent :89, insert :97, remove :101 }
pub(crate) struct ObjInfo { pub(crate) parent: ObjId, pub(crate) obj_type: ObjType }           // :106-110
impl ObjInfo { with_new_actor :113, without_actor :120 }
pub(crate) struct Indexes { pub(crate) text: hexane::PrefixColumn<Option<u32>>, pub(crate) top: hexane::PrefixColumn<bool>, pub(crate) visible: hexane::Column<bool>, pub(crate) inc: hexane::Column<Option<i64>>, pub(crate) mark: MarkIndexColumn, pub(crate) obj_info: ObjIndex }  // :139-146
impl IndexBuilder { new :158, flush :170, process_op :178, process_succ :196, finish :207 }
fn vis_num(op: &Op<'_>) -> u32                                                               // :250
```

**Mark index — `op_set2/op_set/mark_index.rs`**

```rust
pub(crate) enum MarkIdx { Start(OpId), End(OpId) }                       // :12-16
pub(crate) enum MarkIndexBuilder { Start(OpId, MarkData<'static>), End(OpId) }  // :18-22
impl MarkIdx { as_i64 :25, load :36, with_new_actor :51 }                 // encodes (actor<<32 | ctr) signed; End is the negation
pub(crate) struct MarkAcc { opens: FxHashSet<OpId>, closes: FxHashSet<OpId> }  // :99-103
impl AddAssign/SubAssign/Add/Sub for MarkAcc                             // :126, :144, :159, :177
impl PrefixValue for MarkIdx { type Prefix = MarkAcc }                   // :200
pub(crate) struct MarkIndexColumn { data: PrefixColumn<Option<MarkIdx>>, cache: HashMap<OpId, MarkData<'static>> }  // :234-237
impl MarkIndexColumn { new :242, len :248, iter :252, iter_range :256, has_any_marks :263, mark_data :267, rewrite_with_new_actor :271, fn remap_values :280, extend :288, undo :300 }  // through :319
```

**Top / visible iterators — `op_set2/op_set/top_op.rs`, `visible.rs`**

```rust
pub(crate) struct TopOps<'a> { inner: FixCounters<'a, SkipIter<OpIter<'a>, TopIter<'a>>>, visible: VisIter<'a>, visible_pos: usize, … }  // :18-24
impl TopOps<'a> { pub(crate) fn new(op_set, clock: Option<Clock>, range: Range<usize>) -> Self }  // :26
pub(crate) struct TopIter<'a> { range, cursor, exhausted, … }            // :157-163
enum TopIterInner<'a> { Empty, Current(BoolColumnSkipper<'a>), … }        // :165-171
pub(crate) enum VisIter<'a> { Indexed(IndexedVisIter<'a>), Scan(Box<ScanVisIter<'a>>) }  // :44-48
pub(crate) struct IndexedVisIter<'a> { iter: BoolColumnSkipper<'a> }      // :81-84
pub(crate) struct ScanVisIter<'a> { … }                                   // :103
```

**Query plumbing — `op_set2/op_set/op_query.rs`, `insert.rs`, `found_op.rs`, `marks.rs`, `elems.rs`, `op_iter.rs`**

```rust
pub(crate) trait OpQueryTerm<'a>: Iterator<Item = Op<'a>> + Debug { fn get_marks(&self) -> Option<&Arc<MarkSet>>; fn range(&self) -> Range<usize>; }  // :14-18
pub(crate) trait OpQuery<'a>: OpQueryTerm<'a> + Clone { fn marks(self) -> MarkIter<'a, Self>; fn no_marks(self) -> NoMarkIter<'a, Self>; fn key_ops(self) -> KeyOpIter<'a, Self> /*#[cfg(test)]*/; fn visible_slow(self, clock) -> VisibleOpIter<'a, Self>; fn visible(self, op_set, clock) -> … }  // :20-47
pub(crate) struct FixCounters<'a, I> { iter: I, clock: Option<Clock>, … }   // :74-79
pub(crate) struct InsertQuery<'a> { iter: OpIter<'a>, marks: RichTextQueryState<'a>, seq_type: SequenceType, … }  // :12-22
impl InsertQuery<'_> { new :25, fn identify_valid_insertion_spot :62, pub(crate) fn resolve(&mut self, index) -> Result<QueryNth, AutomergeError> :92 }
pub(crate) struct Loc { cursor: ElemId, pos: usize, id: Option<OpId> }       // :164-168
pub(crate) struct OpsFoundIter<'a, I: Iterator<Item = Op<'a>>> { iter, start_pos, clock, … }  // :24-31
pub(crate) struct MarkIter<'a, I> / NoMarkIter<'a, I>                     // :10-13, :55-58
pub(crate) struct ElemIter<'a, I: Iterator<Item = Op<'a>> + Clone>        // :11-16
pub(crate) struct OpIter<'a> { pos, id, obj, key, succ, insert, action, value, marks, range, op_set }  // :19-32
pub(crate) struct OpIterState { … }                                        // :33-44
pub(crate) enum ReadOpError { InvalidOpId(String), … }                    // :66-77
```

### `op_set2::columns` — `op_set2/columns.rs`

```rust
pub(super) struct Columns {
    id_actor: hexane::Column<ActorIdx>,   id_ctr: hexane::DeltaColumn<u32>,
    obj_actor: hexane::Column<Option<ActorIdx>>, obj_ctr: hexane::Column<Option<u32>>,
    key_actor: hexane::Column<Option<ActorIdx>>, key_ctr: hexane::DeltaColumn<Option<u32>>,
    key_str: hexane::Column<Option<String>>,
    succ_count: hexane::PrefixColumn<u32>,
    succ_actor: hexane::Column<ActorIdx>,  succ_ctr: hexane::DeltaColumn<u32>,
    insert: hexane::PrefixColumn<bool>,    action: hexane::Column<Action>,
    value_meta: hexane::PrefixColumn<ValueMeta>, value: hexane::RawColumn,
    mark_name: hexane::Column<Option<String>>, expand: hexane::Column<bool>,
    index: Indexes,
}                                                                        // :16-35
pub(super) struct Indexes { text: hexane::PrefixColumn<Option<u32>>, top: hexane::PrefixColumn<bool>, visible: hexane::Column<bool>, inc: hexane::Column<Option<i64>>, mark: MarkIndexColumn }  // :37-43
impl Columns { fn export_column :135, pub(crate) fn export :172, pub(crate) fn save_checkpoint :187 (#[cfg(test)]), pub(crate) fn validate :219, pub(crate) fn load :252, fn remap_actors :332, pub(crate) fn rewrite_with_new_actor :342, pub(crate) fn rewrite_without_actor :350, pub(crate) fn remove_ops<O: OpLike> :361, pub(crate) fn splice<O: OpLike> :420, pub(crate) fn new :~520, len, sub_len, dump }  // :95-620
pub(crate) mod ids { … }                                                 // :620-660
```

### `op_set2::parents` — `op_set2/parents.rs`

```rust
pub struct Parents<'a> { pub(crate) obj: ObjId, pub(crate) ops: &'a OpSet, pub(crate) clock: Option<Clock> }  // :12-17
impl Parents<'_> { pub fn path(self) -> Vec<(ExId, Prop)>; pub fn visible_path(self) -> Option<Vec<(ExId, Prop)>>; }  // :19-45
impl Iterator for Parents<'_> { type Item = Parent; }                    // :47-74
pub struct Parent { pub obj: ExId, pub typ: ObjType, pub prop: Prop, pub visible: bool }  // :77-89
```

### `op_set2::skip_list` — `op_set2/skip_list.rs`

```rust
struct Link<K> / struct LinkLevel<K> / struct Node<K>                    // :17, :26, :35
trait OrderedSet<K> { index_of / remove_key / insert_index / remove_index / key_of }  // :148-154
pub(crate) struct SkipList<K> where K: Copy + Clone + Debug + Hash + PartialEq + Eq  // :252-261
impl<K> SkipList<K> { new :276, index_of :197, key_of :176, remove_key :168, remove_index :160,
                      insert_index :216, splice :402, insert_head :415, push :419,
                      insert_after :430, fn insert, fn random_level }  // :156-560
pub(crate) struct SkipIterator<'a, K>                                     // :561-567
```

`SkipList` is not referenced by any `op_set2` type in this checkout — grep for `SkipList` finds only its own module. It is dead code. `[INFERENCE]`

### `op_set2::change` — durable change encoding

`op_set2/change.rs`

```rust
pub(crate) mod batch; pub(crate) mod collector;                           // :14-15
pub(crate) use collector::{BuildChangeMetadata, ChangeCollector, CollectedChanges, OutOfMemory};  // :17
pub(crate) trait GetHash { fn get_hash(&self, index: usize) -> Option<ChangeHash>; }   // :19-22
impl GetHash for Vec<crate::Change>; impl GetHash for ChangeGraph        // :24-36
pub(crate) fn build_change<T: AsChangeOp, G: GetHash>(ops: &[T], meta: &BuildChangeMetadata<'_>, graph: &G, actors: &[ActorId]) -> Change<'static, Verified>  // :38
pub(crate) fn build_change_inner<T, G>(…) -> Change<'static, Verified>    // :50
pub(crate) struct ChangeOpsColumns { obj_actor: Range<usize>, obj_ctr, key_actor, key_ctr, key_str, insert, action, value_meta, value, pred_count, pred_actor, pred_ctr, expand, mark_name }  // :145-163
pub(crate) fn shift_range(range: Range<usize>, by: usize) -> Range<usize>  // :165
pub(crate) fn length_prefixed_bytes<B: AsRef<[u8]>>(b: B, out: &mut Vec<u8>) -> usize  // :169
fn write_change_ops<T: AsChangeOp>(ops, change_actor, data, mapper) -> ChangeOpsColumns2  // :181
pub(crate) struct ActorMapper<'a> { seen_actors: Vec<bool>, pub(crate) mapping: Vec<Option<ActorIdx>>, actors: &'a [ActorId], other_actors: Vec<usize> }  // :288-293
impl ActorMapper<'_> { iter :295, new :300, fn reset :305, process_actor :313, process_op :318, build_mapping :333, fn remap_actors :348 }
impl PartialOrd/Ord/PartialEq/Eq for OpBuilder<'_>  (all by `id` only)     // :128, :133, :171, :175
```

`op_set2/change/collector.rs`

```rust
pub(crate) struct OutOfMemory;                                              // :31
pub(crate) struct IndexedChangeCollector<'a> { index: &'a mut IndexBuilder, collector: ChangeCollector<'a> }  // :33-36
pub(crate) struct ChangeCollector<'a> { mapper: ActorMapper<'a>, changes: Vec<BuildChangeMetadata<'a>>, pub(crate) builders: Vec<ChangeBuilder<'a>>, … }  // :90-96
pub(crate) struct BuildChangeMetadata<'a> { actor: usize, seq: u64, max_op: u64, start_op, timestamp, message, extra, deps: Vec<u64>, builder: usize }  // :98-109
impl BuildChangeMetadata<'_> { num_ops :112, message_str :116 }
pub(crate) struct ChangeBuilder<'a> { actor, seq, change, start_op, encoder: OpEncoderStrategy<'a>, … }  // :121-128
enum OpEncoderStrategy<'a> { Ops(VecEncoder<'a>), Enc(Box<ProgressiveEncoder<'a>>) }  // :130-136
pub(crate) struct VecEncoder<'a> { data: Vec<Option<OpBuilder<'a>>> }     // :274-277
pub(crate) struct ProgressiveEncoder<'a> { len, start_op, num_ops, … }    // :337-…
pub(crate) struct CollectedChanges { changes: Vec<Change>, heads: BTreeSet<ChangeHash> }  // :956-959
pub(crate) struct ChangeCols { num_ops, start_op, meta, data }            // :987-995
const CAN_OOM: bool  // true only on wasm                                    :997-1001
```

### `op_set2::change::batch` — applying changes to the op set

`op_set2/change/batch.rs`

```rust
type PredCache = SmallHashMap<OpId, Vec<(OpId, Option<i64>)>>;             // :21
struct BatchApply { ops: Vec<ChangeOp>, changes: Vec<Change>, pred: PredCache, obj_spans: Vec<ObjSpan> }  // :23-29
struct Untangler<'a> { change_ops, entry, gosub, stack, updates, updates_stack, pred, top: Top, conflicts, value: ValueState<'a>, seq_type, text_encoding, count, index, max, width }  // :31-52
struct MapWalker<'a, 'b> { ops, log, pred, succ, value, pos, doc_op, conflicts, top }  // :338-350
enum Adjust { Conflict(usize), Expose(usize) }                              // :355-359
enum Top { Nothing, ChangeIndex(usize), Doc(usize), Expose(usize) }        // :363-368
struct ValueState<'a> { obj, seq_type, text_encoding, key: Option<PropRef<'a>>, doc: OpValueOption, change: OpValueOption, marks: RichTextDiff<'a> }  // :532-539
struct OpValue { id: OpId, value: Value, deleted: bool, conflict: bool, expose: bool, replaced: Option<Value> }  // :542-550
struct OpValueOption(Option<OpValue>);                                     // :553-554
struct ObjWalker<'a> { iter: ObjIdIter<'a> }                               // :1051-1054
struct ObjSpan { obj: ObjId, span: Range<usize> }                          // :1057-1060
fn walk_list / fn walk_map                                                // :323, :851
fn normalize_increment_successors(is_counter: bool, successors: &mut [(OpId, Option<i64>)])  // :483
fn process_pred(doc_op, pred, succ) -> bool                                // :492
fn BatchApply::new(changes: Vec<Change>)                                   // :857

impl BatchApply {
    fn insert_new_actors(&mut self, doc: &mut Automerge);                    // :851
    fn import_ops(&mut self, doc: &mut Automerge);                          // :857
    pub(crate) fn apply(&mut self, doc: &mut Automerge, log: &mut PatchLog) -> Result<(), PatchLogMismatch>;  // :865
    fn insert_runs_of_ops(&mut self, doc: &mut Automerge);                  // :953
    pub(crate) fn insert_ops(&self, doc: &mut Automerge, pos: usize, range: Range<usize>) -> usize;  // :972
    pub(crate) fn order_ops_for_doc(&mut self, obj_info: &mut ObjIndex);    // :979
}
impl Automerge {
    pub fn apply_changes_batch(&mut self, changes: impl IntoIterator<Item = Change> + Clone) -> Result<(), AutomergeError>;  // :1041
    pub fn apply_changes_batch_log_patches<I: IntoIterator<Item = Change>>(&mut self, changes: I, log: &mut PatchLog) -> Result<(), AutomergeError>;  // :1048
    fn import_ops_to(&mut self, change: &Change, ops: &mut Vec<ChangeOp>) -> Result<(), AutomergeError>;  // :1108
    fn import_ops(&mut self, change: &Change) -> Result<Vec<ChangeOp>, AutomergeError>;  // :1118
}
```

### `clock.rs` — the vector clocks

```rust
pub(crate) struct Clock(pub(crate) Vec<u32>);                               // :11
pub(crate) struct SeqClock(pub(crate) Vec<Option<NonZeroU32>>);            // :14
impl SeqClock { iter :17, remove_actor :22, rewrite_with_new_actor :26, get_for_actor :30, new :34, include :38, merge :49, covers :57 }  // :16-65
pub(crate) enum ClockRange { Current(Option<Clock>), Diff(Clock, Clock) }   // :69-73
impl ClockRange { current :79, after :83, visible_after :90, visible_before :97, predates :101 }  // :78-105
impl Clock { isolate :109, covers :122, fn counter_of :133, fn set_counter_of :139 }  // :108-145
```

### `indexed_cache.rs`

```rust
pub(crate) struct IndexedCache<T> { pub(crate) cache: Vec<T>, lookup: HashMap<T, usize> }  // :6-10
impl<T: PartialEq> PartialEq for IndexedCache<T>                             // :12-19
impl<T: Clone+Eq+Hash+Ord> IndexedCache<T> { new :24, len :47 (#[allow(dead_code)]), sorted :59 (#[allow(dead_code)]) }  // :22-70
impl IntoIterator for IndexedCache<T> / for &IndexedCache<T>                 // :72-88
impl Index<usize> for IndexedCache<T>                                        // :90-95
impl<A: Hash+Eq+Clone> FromIterator<A> for IndexedCache<A>                    // :97-110
```

All other methods (`cache`, `lookup`, `get`, `safe_get`) are commented out (`indexed_cache.rs:30-39, :47-56`).

### `exid.rs`

```rust
pub enum ExId { Root, Id(u64, ActorId, usize) }          // :13-17   (fields: actor-index-hint, actor id, counter)
const SERIALIZATION_VERSION_TAG: u8 = 0; TYPE_ROOT: u8 = 0; TYPE_ID: u8 = 1;   // :19-21
impl ExId {
    pub fn to_bytes(&self) -> Vec<u8>;                    // :25  (1 tag byte, then uleb(actor_len) actor uleb(counter) uleb(idx))
    pub(crate) fn to_internal_obj(&self) -> ObjId;       // :70
}
pub enum ObjIdFromBytesError { NoVersion, InvalidVersion(u8), InvalidType(u8), ParseActorLen(String), ParseActor, ParseCounter(String), ParseActorIdxHint(String) }  // :75-87
impl<'a> TryFrom<&'a [u8]> for ExId                        // :89-113
impl PartialEq for ExId   // ignores the actor-index hint (third field)        :115-126
impl Eq, Display ("_root" / "ctr@actor"), Hash (ignores hint), Serialize (as str), AsRef<ExId>, Ord (Root < Id; then counter, then actor id), PartialOrd  :128-190
```

### `types.rs` — identifiers the engine depends on

```rust
pub(crate) const CONCURRENCY_MAGIC_BYTES: [u8; 4] = [0x13, 0xb2, 0x23, 0x09];  // :23
pub(crate) const HEAD: ElemId = ElemId(OpId(0, 0));                             // :29
pub(crate) const ROOT: OpId = OpId(0, 0);                                       // :30
pub(crate) struct OpId(u32, u32);   // (counter, actor index)                    // :430
impl OpId { with_new_actor :447, without_actor :454, new :462, counter :472, icounter :476, actor :480, actoridx :484, prev :489, minus :495, next :501 }  // :446-506
impl Ord for OpId { self.0.cmp(&other.0).then(self.1.cmp(&other.1)) }            // :439-444
pub(crate) struct ObjId(pub(crate) OpId);                                       // :520
impl ObjId { with_new_actor :523, without_actor :531, load :539, map :548, root :555, is_root :559, id :563, counter :567, icounter :573, actor :579 }  // :522-585
pub(crate) struct ObjMeta { pub(crate) id: ObjId, pub(crate) typ: ObjType };    // :596-600
impl ObjMeta { pub(crate) fn root() -> Self }                                    // :611-618
pub(crate) struct ElemId(pub(crate) OpId);                                      // :653
pub enum TextEncoding { UnicodeCodePoint, Utf8CodeUnit, Utf16CodeUnit, GraphemeCluster }   // :622-631
pub struct ChangeHash(pub [u8; 32]);                                             // :690
```

### Feature gates

| Feature | Effect in the covered surface |
|---|---|
| `wasm` | `error.rs:106` adds `From<AutomergeError> for JsValue`; `hexane/wasm`, `getrandom/wasm_js`, `js-sys`, `wasm-bindgen`, `web-sys` deps; also flips `CAN_OOM = true` in `op_set2/change/collector.rs:997-998` |
| `utf8-indexing` / `utf16-indexing` | empty feature flags; consumed by `TextEncoding::platform_default()` (`types.rs:621+`) and `Automerge::new` (`automerge.rs:271`) |
| `slow_path_assertions` | `transaction/inner.rs:164`; `automerge.rs:1587, 1939`; `op_set2/op_set.rs:645, 1088`; `op_set2/op_set/top_op.rs:6, 77, 110, 117, 127`; `op_set2/change/batch.rs:924`; `storage/load.rs:129`; `sequence_tree.rs:52, 114, 126` |
| `#[cfg(test)]` | `op_set2/op_set.rs:68, 73, 78, 1207`; `op_set2/columns.rs:82, 96, 186`; `autocommit.rs:566, 571`; `automerge.rs:43, 579, 1163`; `op_set2/op_query.rs:7, 29` |
| `#[cfg(debug_assertions)]` | `op_set2/change/collector.rs:742` |
| `#[cfg(feature = "wasm", target_family = "wasm")]` | `op_set2/change/collector.rs:997, 1000` |
| crate lints | `lib.rs:184-206` — `dead_code`, `unused_allocation`, `improper_ctypes`, `unreachable_pub` are warn-level in this crate, so dead code is *not* a hard error |

---

## Semantics

### 1. Transaction lifecycle

**There is no nesting.** `TransactionInner` has no parent pointer and no reentrant entry point; every mutation entry point takes `&mut self` on the inner value, which the wrappers obtain through a single `Option` slot (`transaction.rs:105-110` `do_tx`, `transaction.rs:320` `self.inner.as_ref().unwrap().pending_ops()`). A second `transaction()` call on `Automerge` cannot be made while a `Transaction<'a>` is alive because `Transaction<'a>` holds `&'a mut Automerge` (`manual_transaction.rs:26`). `AutoCommit` instead has exactly one `transaction: Option<(PatchLog, TransactionInner)>` slot (`autocommit.rs:66`) which `ensure_transaction_open` creates and `ensure_transaction_closed` drains (`autocommit.rs:445-457`, `:459-467`). `OwnedTransaction` owns the doc, so it has the same single-slot restriction (`owned_transaction.rs:19-25`).

**Open.** `Automerge::transaction_args` (`automerge.rs:533-577`) is the sole allocator of transaction identity:

- `heads == None`: `actor_index = get_or_create_actor_index()`; `seq = change_graph.seq_for_actor(actor_index) + 1`; `deps = get_heads()`; if `seq > 1`, the hash of `(actor_index, seq-1)` is pushed into `deps` if not already present (`automerge.rs:546-556`).
- `heads == Some(h)`: `deps = h.to_vec()`; `isolation = isolate_actor(h)`; `actor_index = isolation.actor_index`; `seq = isolation.seq`; `scope = Some(isolation.clock)` (`automerge.rs:540-545`).
- Then `queue.remove_actor_branch_from(&actor, seq)` — a local change claims this sequence, so any *queued* change at `seq` or later for the same actor is dropped (`automerge.rs:561-563`).
- `start_op = NonZeroU64::new(change_graph.max_op() + 1).unwrap()` — the comment asserts "we always add 1" (`automerge.rs:566-567`). `max_op` is `0` for an empty graph, so `start_op >= 1` always.
- `author = if seq == 1 { self.author.clone() } else { None }` — only the actor's *first* change carries the author (`automerge.rs:568`).

`TransactionInner::new` sets `time = 0`, `message = None`, `pending = vec![]` (`inner.rs:68-92`).

**Op production.** Every mutation immediately materialises into the `OpSet` and is *also* appended to `pending` (`inner.rs:324-325` `insert_local_op`; `inner.rs:388-390` `do_insert`; `inner.rs:795-797` delete loop). Invariant: after each op, `pending.len()` is exactly the number of ops this transaction has created, and their ids are the contiguous run `start_op .. start_op+pending.len()` because `next_id() = OpId::new(start_op.get() + pending_ops(), actor)` (`inner.rs:295-297`) and each producer pushes exactly one op before the next `next_id()` call.

**Commit.** `TransactionInner::commit` (`inner.rs:129-143`):
- If `pending_ops() == 0`: if `seq == 1` the actor created for the transaction is removed, `remove_unused_actors(true)` runs, and `None` is returned. So an empty transaction never produces a change — except through `TransactionInner::empty` (`inner.rs:94-100`), which calls `commit_impl` unconditionally and therefore *does* produce a zero-op change.
- Otherwise `commit_impl` (`inner.rs:146-171`): `message`/`time` override if `Some`; `export(doc.ops(), doc.changes())` builds the `Change`; `hash = change.hash()`; `doc.update_history(&change)`; `doc.remove_unused_actors(true)`; returns `hash`.

`export` (`inner.rs:197-209`): `deps.sort_unstable()`; then `deps.iter().filter_map(|hash| change_graph.hash_to_index(hash).map(|i| i as u64)).collect()`. `filter_map` **silently drops** any dep hash not present in the graph. `change_meta` (`inner.rs:174-190`) computes `max_op = start_op + pending.len() - 1` — with `pending.len() == 0` and `start_op >= 1` this yields `start_op - 1 >= 0`, and `build_change_inner` then sets `start_op = ops.first().map(op_id_ctr).unwrap_or(meta.max_op + 1)` (`change.rs:68`), restoring `start_op`. `extra` is the encoded author footer (`inner.rs:193-195`).

**The op set is already mutated at commit time.** `update_history` only touches `deps`, `change_graph` and `authors` (`automerge.rs:1287-1298`); the columns written during op production are *not* rewound or re-written. A committed transaction's ops are indistinguishable, in the op set, from ops that arrived via `apply_changes`.

**Rollback.** `TransactionInner::rollback` (`inner.rs:211-227`): iterate `pending` in reverse, `doc.ops.undo_op(o)`; if `seq == 1`, `doc.remove_actor(self.actor)`; `remove_unused_actors(true)`; return the cancelled count. `OpSet::undo_op` (`op_set.rs:246-257`) replays the recorded `SuccUndo` list, then physically removes the op row via `cols.remove_ops(op.pos, &[op])`, removes its `ObjInfo` entry, and — for scoped transactions — re-runs `reset_top(reset_range)` to undo the conflict reordering that `reset_top` performed at insert time.

**Drop.** `Transaction<'a>` rolls back on drop if `inner` is still `Some` (`manual_transaction.rs:135-145`); `commit`/`commit_with`/`rollback` all `take()` the inner first, so a committed/rolled-back transaction does not double-apply. `OwnedTransaction` has no `Drop` impl, so an abandoned `OwnedTransaction` leaks the pending ops into the op set (the doc is dropped with it, so this is not observable through the public API) — `[INFERENCE]`, verified by the absence of `impl Drop for OwnedTransaction` in `owned_transaction.rs:17-119`.

**Closure form.** `transact_with_impl` (`automerge.rs:603-629`) runs the closure, then on `Ok` commits and wraps in `Success { result, hash, patch_log }`; on `Err` calls `tx.rollback()` and wraps in `Failure { error, cancelled }`. Note the success path consumes `tx` by value, so the `Drop` impl cannot double-roll-back.

**Nested/re-entrant reads during a transaction.** `Transaction::get_scope` and `OwnedTransaction::get_scope` (`manual_transaction.rs:112-121`, `owned_transaction.rs:106-114`) deliberately bypass the `clock_at` "heads are current ⇒ `None`" shortcut whenever `heads` is explicitly supplied, because pending ops are in the op set but not under the graph's heads. `AutoCommit::get_scope` (`autocommit.rs:794-810`) encodes the same rule as a three-way match: explicit heads > in-flight isolated transaction scope > isolation heads > `None` (unscoped).

### 2. `Automerge` internal state and its invariants

```rust
pub struct Automerge {
    pub(crate) queue: ChangeQueue,        // unapplied, causally-unready changes
    pub(crate) change_graph: ChangeGraph, // node/edge graph + per-actor columns
    authors: Authors,
    deps: HashSet<ChangeHash>,            // == change_graph.heads, kept separately
    pub(crate) ops: OpSet,
    actor: Actor,
    author: Option<Author<'static>>,
}                                                                 // automerge.rs:248-262
```

Invariants provable from the code:

1. **Actor-index consistency.** `ops.actors`, `change_graph.actors`/`seq_index`, `authors`, and `ops.obj_info` all index actors by the same integer. `insert_actor` (`automerge.rs:1301-1306`) pushes into all four; `remove_actor` (`automerge.rs:427-431`) calls `self.actor.remove_actor`, `self.ops.remove_actor`, `self.change_graph.remove_actor` and additionally `authors`/queue via `remove_unused_actors` (`automerge.rs:446-455`). `OpSet::remove_actor` panics if the removed actor is still referenced by any column (`op_set2/columns.rs:350-358` `rewrite_without_actor` → `panic!("cant rewrite - actor is present")`).
2. **`deps` mirrors `change_graph.heads`.** `update_deps` (`automerge.rs:1323-1328`) removes every dep of the new change and inserts the change hash; `get_heads` (`automerge.rs:1506-1510`) returns `deps` sorted. `from_parts` seeds `deps` from `change_graph.heads()` (`automerge.rs:322`).
3. **Ops precede the change that contains them.** `update_history` is called *after* the ops are in the set during `apply_changes` (`batch.rs:857-862`) and *at* commit for local transactions. `Automerge::hash_for_opid` therefore never sees a dangling opid — except for pending local ops, which are documented to return `None` (`autocommit.rs:789-792`).
4. **Queue contents.** `queue` holds only changes that are *not* yet in `change_graph` and *not* yet causally ready. `is_empty()` is `change_graph.is_empty() && queue.is_empty()` (`automerge.rs:349-351`).
5. **No unused actors.** `assert_no_unused_actors(panic)` compares `ops.actors.len()` with `change_graph.actor_ids().count()` (`automerge.rs:434-444`) and is called with `panic = true` from `remove_unused_actors` in debug builds and unconditionally from `save_with_options` (`automerge.rs:1150`).
6. **Op ordering within the op set.** `validate_op_order` walks `OpIter` with an `OpStepper`; `Op::step` (`op.rs:1048-1071`) requires ops grouped by non-decreasing `ObjId`, and within an object by non-decreasing `elemid_or_key()` with strictly increasing `id` inside a run. `debug_assert!(doc.ops.validate_op_order())` runs at the end of every batch apply (`batch.rs:949`).
7. **Top/visible index coherence.** `validate_top_index` (`op_set.rs:177-213`) asserts `top.len() == visible.len() == ops.len()`, `top ⇒ visible`, and — per `(obj, elemid_or_key)` group — that the first top op equals the last visible op. `top` is a `PrefixColumn`; it is only ever updated by `conflict`, `expose`, `reset_top`, `add_succ`/`add_succ_with_undo` and `Columns::splice`.
8. **Text width is stored per op** in `index.text` as `Option<u32>`; it is `Some(w)` only when `top` is true, and is written as `None` by `conflict` and by any non-increment successor (`op_set.rs:140-145`, `:277-281`).

### 3. Producing an operation from a transaction

**Map put/delete/increment** — `local_map_op` (`inner.rs:446-490`):

1. `id = next_id()`.
2. `query = doc.ops().seek_ops_by_map_key(&obj.id, &prop, self.scope.as_ref())` → `OpsFound { index, ops, end_pos, range }` where `ops` is the visible conflict stack for that key, Lamport-ordered ascending so `ops.last()` is the winner.
3. `resolved_action = query.resolve_action(action)`; `None` ⇒ return `Ok(None)` (no op at all, no op-id consumed beyond the `next_id()` computation which is discarded).
4. If `resolved_action.is_increment()` and no op in `query.ops` `is_counter()` ⇒ `Err(AutomergeError::MissingCounter)`.
5. `pred = query.ops.iter().map(|op| op.id)` — **every** visible conflicting op, not just the winner.
6. `op = TxOp::map(id, *obj, query.end_pos, resolved_action, prop, pred)`.
7. `inc_value = op.get_increment_value()`; `succ = query.ops.iter().map(|op| op.add_succ(id, inc_value))`.
8. `insert_local_op(doc, patch_log, op, &succ, query.range, increment_replacement)`.

`resolve_action` (`op_set.rs:1482-1509`) has exactly three outcomes:

- last op is a `Set` with the *same* value and there is exactly one op ⇒ `None` (a redundant put is a no-op).
- last op is a `Set` with the same value and there is *several* ops ⇒ pop the winner off `query.ops` and return `ConflictResolution(OpType::Delete)` — i.e. write `value` again so the op-id ordering makes the new op the winner, and record predecessors for *all* the losers. This is the conflict-resolution-by-redundant-write trick.
- otherwise ⇒ `VisibleUpdate(original_action)`. Special case: a `Delete` with an empty `ops` stack is `None`.

**List set/increment** — `local_list_op` (`inner.rs:495-556`): same shape, but the `elemid` is `query.ops.first().and_then(|op| op.cursor().ok()).ok_or(AutomergeError::InvalidIndex(index))?` — an empty stack at a valid index is an error, unlike the map path. `replaced` for patch purposes is the increment materialisation, or for `ObjType::Text` the `hydrate_value` of the first op.

**Insert** — `do_insert` (`inner.rs:367-400`): `query = doc.ops().query_insert_at(&obj.id, index, seq_type, self.scope.clone())?` → `QueryNth { marks, pos, index, elemid }`; the op is `TxOp::insert(id, *obj, pos, index, action, elemid)`; spliced at `pos`, finalized with `marks`, pushed. The `id` of an insert is *also* its `ElemId` (`op.rs:1140-1146`, `op.rs:1073-1076`).

**`query_insert_at` fast paths** (`op_set.rs:569-608`): when `clock.is_none() && index > 0` it dispatches to `query_insert_at_list` (prefix-advance on `index.top`, then `InsertQuery::resolve(index-1)`) or `query_insert_at_text` (prefix-advance on `index.text`, plus `scan_for_sticky_marks`), and `debug_assert_eq!`s the result against the general `InsertQuery::new(...).resolve(0)` path. Under `slow_path_assertions` a scoped read takes `seek_ops_by_index_slow` and asserts `fast == slow` (`op_set.rs:645-650`).

**Mark begin/end ordering invariant** — `mark` (`inner.rs:801-876`): the `MarkEnd` op **must** land at a strictly greater op-set position than its `MarkBegin`; if the computed end position is not greater (both anchors resolve inside one multi-width text element), `insert_mark_end_after` anchors it immediately after the begin (`inner.rs:838-866`). A `debug_assert!(end.pos > begin.pos)` guards it (`inner.rs:869-874`), and the load path re-validates the same property with `MarkOrderValidator` (`index.rs:22-73`).

**Splice** — `inner_splice` (`inner.rs:673-797`): negative `del` is normalised against `index` with `checked_add_signed`, `Err(AutomergeError::InvalidIndex)` on underflow (`inner.rs:681-688`). Inserts happen first, then deletions walk forward from `index + inserted_width`, advancing by `op.width(seq_type, text_encoding)` per element, re-querying per element, and skipping forward when `query.index < delete_index` (i.e. a delete landing inside a multi-width element) (`inner.rs:764-772`).

**Batch insertion** — `BatchInsertion` (`inner.rs:1435-1519`) appends ops to `pending` *without* splicing, computing positions arithmetically (`next_pos = pending[pending_start..].len() + insert_pos`, `inner.rs:1460-1462`), and performs exactly one `OpSet::splice` in `finish()` (`inner.rs:1514-1519`). `batch_bfs` (`inner.rs:1539-1602`) walks the `hydrate::Value` tree breadth-first, sorting map keys so op ids are deterministic across runs (`inner.rs:1546-1547`, `inner.rs:1372-1373`, `inner.rs:1128-1130`). For list splices the root ops are inserted at `query.pos` in one batch and all descendants in a second batch appended at `doc.ops().len()` (`inner.rs:702-724`).

**Text width on insert** — `BatchInsertion::splice_text` splits into `ScalarValue::from(char)` per code point, except under `TextEncoding::GraphemeCluster` where it splits per grapheme cluster; each is a separate op with `elemid` chained to the previous (`inner.rs:1484-1512`).

### 4. Applying ops to the op set

**Local (in-transaction) application — `insert_local_op` (`inner.rs:308-328`):**

```
let added = doc.ops_mut().splice(op.pos, &[&op]);
op.undo = doc.ops_mut().add_succ_with_undo(succ);
if self.scope.is_some() {
    doc.ops_mut().reset_top(range.start..(range.end + added));
    op.reset_range = Some(range);
}
```

`OpSet::splice` (`op_set.rs:240-244`) delegates to `Columns::splice` and then `splice_objects`, which records `ObjInfo` for every op whose action is a `Make*` (`op_set.rs:232-238`).

`Columns::splice` (`columns.rs:420-…`) **filters out every op whose action is `Action::Delete`** (`columns.rs:426-427`). Deletes are never materialised as rows; they exist only as successor edges on their predecessors. It then writes, in lockstep: `id_actor/id_ctr`, `obj_actor/obj_ctr`, `key_actor/key_ctr/key_str`, `insert`, `action`, `expand`, `mark_name`, `value_meta`, the raw `value` blob (offset by `value_meta.get_prefix(pos)`), `succ_count` (from `o.succ().len()`), the flat `succ_actor`/`succ_ctr` arrays (offset by `succ_count.get_prefix(pos)`), `index.inc` (the per-successor increment amounts), `index.mark`, `index.text` (`Some(width)` iff `O::top(op)`), `index.top` (`O::top(op)`), and `index.visible` (`O::visible(op)`).

`add_succ_with_undo` (`op_set.rs:285-325`) iterates the `SuccInsert` list **in reverse**:

- Coalesces consecutive entries with the same `pos` by bumping a running `succ_inc`, writing `succ_count = i.len + succ_inc`.
- Inserts the new successor at `i.sub_pos` in `succ_actor`, `succ_ctr` and `index.inc`.
- If `inc.is_none()` (a real delete): record `SuccUndo::new(*i, visible, text, top)` and clear `visible`, `text` and `top` at `i.pos`; set `delete = true`.
- Else if `delete && !expose`: record a `SuccUndo` carrying only the previous `top` value and set `top[pos] = true` — this is the "expose the winner that the delete had hidden" step.
- Else record a no-op `SuccUndo`.

`add_succ` (`op_set.rs:259-283`) is the same without the undo bookkeeping.

`reset_top(range)` (`op_set.rs:107-138`) recomputes conflict/expose for a range touched by a scoped transaction: it walks `visible` and `top` in parallel; whenever `top` is set it asserts `visible` and records the previous top position as a conflict, and when only `visible` is set it exposes that position.

`undo_succ` (`op_set.rs:327-351`) replays the undo list in reverse, shrinking `succ_count` and erasing one entry from `succ_actor`/`succ_ctr`/`index.inc` at `sub_pos`, and restoring `visible`/`text`/`top` where the `SuccUndo` carries them.

**Remote application — `apply_changes_batch_log_patches` (`batch.rs:1048-1106`):**

1. Seed `seen` from the queue, and `actor_seqs` / `actor_author` from queued changes.
2. For each incoming change, in order: skip if the hash is in `change_graph` or already `seen`; if `has_actor_seq(&change)` (the graph already has this actor at ≥ this seq) then evict the incompatible queued branch at `seq+1` and return `Err(AutomergeError::DuplicateSeqNumber)`; if the batch itself repeats an `(actor, seq)` ⇒ same error; if the change carries an author and the doc or batch already has an author for that actor ⇒ `Err(AutomergeError::DuplicateAuthor)`.
3. `queue.extend(incoming)`; `changes = queue.pop_topo_sorted_ready(&change_graph)` (Kahn topological sort; anything not causally ready stays queued).
4. `BatchApply::new(changes).apply(self, log)`.

`BatchApply::apply` (`batch.rs:865-951`):

1. `insert_new_actors` — for every change with `seq == 1`, `doc.put_actor_ref(change.actor_id())` (`batch.rs:851-855`).
2. `log.migrate_actors(&doc.ops().actors)?` — the patch log must learn about the new actor indices before any op is logged.
3. `import_ops` — per change: decode into `ChangeOp`s (`batch.rs:1118-1160`, mapping per-change actor indices to document actor indices through `change.actors()`) and immediately `doc.update_history(c)`. The `unwrap()` on both the actor lookup and the history update is sound only because step 1 guarantees every `seq == 1` actor is present and the queue was topologically sorted. After the loop, `remove_unused_actors(true)`.
4. Clone `doc.ops().obj_info` into a mutable `obj_info`.
5. `order_ops_for_doc(&mut obj_info)` (`batch.rs:979-1036`): sort all `ChangeOp`s by `(bld.obj, elemid_or_key, bld.id)`, populate the `pred` cache (`op.id → Vec<(pred, increment)>`), insert `ObjInfo` for `Make*` ops, and record `obj_spans` — the contiguous run of change ops belonging to each object.
6. For each `obj_span`: seek the document's existing ops for that object with `ObjWalker` (`batch.rs:1055-1063`), then
   - `ObjType::Map` → `MapWalker` + `walk_map` (`batch.rs:411-491`, `:851-857`),
   - sequences → `Untangler::new(...)` + `walk_list` (`batch.rs:264-321`, `:323-341`).
   - The sequence branch computes `max` as `doc_ops.end_pos()` — the end of the *object's* existing range, not the whole op set.
   - `unreachable!()` for a missing object, `panic!("Obj {:?} Missing from Index", os.obj)` for an object with no type (`batch.rs:925`) — the op set is expected to be self-consistent.
7. Apply the accumulated `Adjust`s: `Conflict(i) → doc.ops.conflict(i)`, `Expose(i) → doc.ops.expose(i)` (`batch.rs:939-943`).
8. `doc.ops.add_succ(&succ)` (`batch.rs:945`).
9. `insert_runs_of_ops` (`batch.rs:953-970`): walk the sorted change ops and splice each *run of equal `pos`* into the document with a running `shift` so positions stay correct; `insert_ops` returns the number of rows actually inserted (`batch.rs:972-977`).
10. `debug_assert!(doc.ops.validate_op_order())`.

`Untangler` (`batch.rs:31-321`) is the sequence-merge state machine:

- `Untangler::new` (`batch.rs:264-300`) partitions the batch's ops into: inserts keyed by their `ElemId` predecessor (`entry` map, with `gosub` chains for repeated predecessors, and a pre-seeded `stack` for anything whose predecessor is `HEAD`), and non-insert updates keyed by `ElemId` (`updates`).
- `untangle_inserts` (`batch.rs:151-168`): before handling document op `d`, pops the stack down to the point where `d.id` belongs, pushing its `entry`/`updates` children.
- `untangle_inner` (`batch.rs:170-258`): assigns `op.pos = insert_pos` and `op.subsort = count`; within one run, all following ops sharing the same `KeyRef::Seq(ElemId(op.id()))` (i.e. updates to the same element) get the same `pos` and increasing `subsort`; the last op in the run that `is_set_or_make() && !has_succ()` is the visible one and earlier ones are flagged `conflicted = true`; the visible one drives the patch (`log.insert` for lists, `log.insert(Value::map())` for `Action::MakeMap` block markers, `log.splice` otherwise).
- `normalize_increment_successors` (`batch.rs:483-490`): increments preserve counter predecessors (`Some(inc)`) but act as ordinary overwrites for non-counter predecessors, so any `Some` becomes `None` when the predecessor is not a counter. The same normalisation is applied to *incoming* change ops in `Untangler::new` and `MapWalker::change_op` using the *op's own* declared value, not the document's (`batch.rs:274-278`, `:432-437`).
- `finish` (`batch.rs:138-149`): `finish_updates`, `flush`, `assert!(entry.is_empty())` (every entry point must have been reached), `finish_inserts`, `flush`, `assert_eq!(self.top, Top::Nothing)`, then sorts `change_ops` by `(pos, subsort)`.
- Under `slow_path_assertions`, `succ` is re-sorted by `(pos, sub_pos, counter, actor)` and asserted equal to its natural order (`batch.rs:924-935`).

`MapWalker` (`batch.rs:338-491`): a merge of two sorted streams — existing document ops for the object (by `key_str` then `id`) and incoming change ops for that object. `advance_doc_op` (`batch.rs:451-472`) consumes document ops until `d.key > op.key()` or `d.key == op.key() && d.id > op.id()`. `ValueState` (`batch.rs:532-782`) tracks the per-key "current document value" and "incoming change value" and flushes patches on key boundaries via `map_process` (`batch.rs:805-848`) or on element boundaries via `list_flush` (`batch.rs:637-802`). `Top` (`batch.rs:363-400`) tracks whether the current register's winner is a document op or a change op, and records `Adjust::Conflict` / `Adjust::Expose`.

Conflict winner rules, all expressed by `OpId` comparison (counter, then actor index — `types.rs:439-444`):

- `c.id > d.id` ⇒ change wins; conflict flag = `(c.conflict && !d.conflict) || !d.deleted` (`batch.rs:833-836`).
- `c.id < d.id` ⇒ document wins; a conflict is flagged only if `!d.conflict` (`batch.rs:837-842`).
- `c.id == d.id` ⇒ the increment delta `c.value.as_i64() - d.value.as_i64()` is emitted as an increment patch when non-zero (`batch.rs:843-848`).
- List: `c.id < d.id` ⇒ `log.flag_conflict` (`batch.rs:701-703`).
- Text: `(Some(d), Some(c)) if d.deleted` ⇒ always `log.replace_seq` (a text update replaces an element that may render as multiple units) (`batch.rs:713-728`).

### 5. `ChangeGraph` — causality

Representation: parallel vectors indexed by `NodeIdx(u32)`. `parents[i]` is the head of a singly-linked edge list; each `Edge { target, next }` names a *parent* node, so edges are stored child → parent with the child implicit (`change_graph.rs:77-81`).

`add_change(change, actor_index, authors)` (`change_graph.rs:708-726`):
- already present by hash ⇒ `Ok(())` (idempotent).
- any dep hash absent ⇒ `Err(MissingDep(hash))`.
- else `add_changes([(change, actor)].into_iter(), authors)`.

`add_changes` (`change_graph.rs:545-582`):
- `max_op = max(max_op, change.max_op())`; push the hash into `hashes` and `nodes_by_hash`; `update_heads` removes every dep and inserts the change hash (`change_graph.rs:513-517`).
- If the change has an author, `assert!(change.seq() == 1)` and `authors.assign_author(...)` — **author assignment is only legal on the actor's first change** (`change_graph.rs:564-567`).
- `assert_eq!(self.seq_index[actor].len() + 1, change.seq())` — per-actor changes are strictly sequential in insertion order (`change_graph.rs:571-573`).
- Every parent hash goes through `add_parent` (`change_graph.rs:745-763`), which `debug_assert!`s the parent is already known and appends to the tail of the child's edge list.
- Every `CACHE_STEP = 16`-th node gets `cache_clock` (`change_graph.rs:575-577`).
- Every node gets `cache_fragment` (`change_graph.rs:579`).

Causality queries:

- `has_change(hash)` — `nodes_by_hash.contains_key` (`change_graph.rs:334-336`).
- `deps(hash)` / `deps_for_hash(hash)` — walk the edge list, map `NodeIdx → hash`; unknown hashes are silently skipped via `.get()` (`change_graph.rs:766-782`, `:322-331`).
- `clock_at(heads)` (`change_graph.rs:794-806`): `heads_to_nodes` uses `filter_map`, so **unknown heads are silently dropped**; `calculate_clock` returns a `SeqClock` (per-actor `Option<NonZeroU32>` seq numbers); the result is then mapped to a `Clock` (`Vec<u32>`) by reading `max_ops` of the change at that seq, `None → 0` via `FromIterator<Option<u32>>` (`clock.rs:148-152`).
- `calculate_clock_inner` (`change_graph.rs:827-852`): DFS from `to_visit.pop_last()`; `clock.include(actor, seq)`; if a cached `SeqClock` exists it is merged in wholesale, otherwise the node's parents are pushed. It `assert!`s no node is visited twice and that `visited.len() <= hashes.len()`.
- `calculate_clock` asserts `to_visit.is_empty()` at the end — i.e. every reachable ancestor of the heads must be in the graph. Passing an unknown head does not trip this (it is dropped before the call), so a head from a different document silently yields a partial clock.
- `heads_are_current(heads)` (`change_graph.rs:132-138`): early `false` if `heads.len() < self.heads.len()`, then exact set equality against `BTreeSet`.
- `seq_for_actor(actor)` = `seq_index[actor].len()` (`change_graph.rs:216-221`).
- `get_hash_for_actor_seq(actor, seq)` = `seq_index[actor][seq-1] → hashes` (`change_graph.rs:500-510`).
- `opid_to_hash(OpId)` (`change_graph.rs:300-320`): binary-searches the actor's change list by the interval `[max_op - num_ops + 1, max_op]` derived from the `max_ops` and `num_ops` columns; the counter must fall inside exactly one change.
- `get_build_indexes(clock)` (`change_graph.rs:457-474`): for each actor, take the change slice *after* the seq recorded in the clock (or the whole list if the clock has no entry), then `sort_unstable()` the node indices — which sorts by `(actor, seq)` because nodes are appended in that order for locally-produced histories. This is what makes `get_changes(have_deps)` deterministic and what feeds `build_change` its `deps` as node indices.
- `remove_ancestors` / `traverse_ancestors` (`change_graph.rs:855-881`) prune a `BTreeSet<ChangeHash>` down to changes not reachable from `heads`.

`ChangeGraphCols::load(doc)` (`change_graph.rs:926-1051`) and `finalize` (`:893-924`) are the load path; `ChangeGraph::validate` (`:274-297`) filters the raw document columns to the nine known change-graph specs.

### 6. Op metadata, counters, heads, clock updates

**There is no `OpSetMetadata` type in this crate** — `grep -r OpSetMetadata rust/` returns no matches. The role is split three ways:

1. **Change-side metadata** lives in `ChangeGraph`'s columnar stores (`change_graph.rs:33-40`): `seq: Vec<u32>` (delta-encoded), `max_ops: Vec<u32>` (delta-encoded), `max_op: u32` (scalar), `num_ops: hexane::Column<u64>`, `timestamps: hexane::DeltaColumn<i64>`, `messages: hexane::Column<Option<String>>`, `extra_bytes_meta: PrefixColumn<ValueMeta>` + `extra_bytes_raw: Vec<u8>`.
2. **Op-side derived index ("shadow") columns** live in `Columns::index` (`columns.rs:38-43`): `text: PrefixColumn<Option<u32>>` (rendered width per op, `Some` iff top), `top: PrefixColumn<bool>`, `visible: Column<bool>`, `inc: Column<Option<i64>>` (per-successor increment amount, indexed by the *sub-column* not the op row), `mark: MarkIndexColumn`.
3. **The public read model** is `ChangeMetadata<'a>` (`op_set2/types.rs:730-742`) with `actor/author/seq/start_op/max_op/timestamp/message/deps/hash/extra`.

Counter updates, provable:

- `max_op` is `max` over all added changes (`change_graph.rs:556`). `start_op` of a new local transaction is `max_op + 1` (`automerge.rs:566`).
- `max_op_for_actor(actor_index)` is the `max_ops` of the actor's *last* change in `seq_index` (`change_graph.rs:208-213`).
- `seq_index[actor].len()` is the actor's next sequence number (`change_graph.rs:216-221`).
- Heads live in two places: `ChangeGraph::heads: BTreeSet<ChangeHash>` (maintained by `update_heads`, `change_graph.rs:513-517`) and `Automerge::deps: HashSet<ChangeHash>` (maintained by `update_deps`, `automerge.rs:1323-1328`). `get_heads` reads only `deps`.
- Clock updates: `SeqClock::include` only advances (`clock.rs:38-48`); `SeqClock::merge` takes the per-actor max (`clock.rs:49-55`); `Clock::isolate(actor_index)` sets that actor's counter to `u32::MAX` so the isolated actor's entire history is covered (`clock.rs:109-111`); `Clock::covers(opid)` is `counter_of(actor) as u64 >= opid.counter()` (`clock.rs:122-124`); `SeqClock::covers` asserts equal lengths and returns true for any `None` on the right-hand side (`clock.rs:57-65`).
- `isolate_actor` (`automerge.rs:1259-1281`): level 0 uses the document's own actor; level `i > 0` uses `get_actor().with_concurrency(i)` (prefixed by `CONCURRENCY_MAGIC_BYTES`, `types.rs:23`). It walks levels until either the actor has no ops (`max_op == 0`) or the clock already covers its last op; then `clock.isolate(actor_index)` and `seq = seq_for_actor(actor_index) + 1`. The clock is recomputed after each level because the actor indices shift (`automerge.rs:1263-1279`).
- `IndexBuilder::process_op` / `flush` (`index.rs:178-205`) rebuild `top` from scratch: `process_op` pushes `vis_num(op)` (a successor count, or `u32::MAX` for increments), and `flush` scans backwards to the last op with `succ == 0` and marks it top. `visible` is `succ == 0`. Increment successors are resolved in `process_succ`/`process_op` via the `counters: HashMap<OpId, Vec<(succ_idx, op_idx)>>` map.

### 7. Durable-format encoding

**Inside a saved document** (`OpSet::export` → `Columns::export`, `columns.rs:172-184`, and `ChangeGraph::encode`, `change_graph.rs:236-272`). The document is a set of `RawColumn`s, each tagged by a `ColumnSpec` built from a `ColumnId` plus a kind. Op columns (`op_set2/columns.rs:620-660`):

| ColumnId | Specs |
|---|---|
| 0 `OBJ` | `OBJ_ID_ACTOR_COL_SPEC` (`ColumnSpec::new_actor`), `OBJ_ID_COUNTER_COL_SPEC` (`new_integer`) |
| 1 `KEY` | `KEY_ACTOR_COL_SPEC` (`new_actor`), `KEY_COUNTER_COL_SPEC` (`new_delta`), `KEY_STR_COL_SPEC` (`new_string`) |
| 2 `ID`  | `ID_ACTOR_COL_SPEC` (`new_actor`), `ID_COUNTER_COL_SPEC` (`new_delta`) |
| 3 `INSERT` | `INSERT_COL_SPEC` (`new_boolean`) |
| 4 `ACTION` | `ACTION_COL_SPEC` (`new_integer`) |
| 5 `VAL` | `VALUE_META_COL_SPEC` (`new_value_metadata`), `VALUE_COL_SPEC` (`new_value`) |
| 8 `SUCC` | `SUCC_COUNT_COL_SPEC` (`new_group`), `SUCC_ACTOR_COL_SPEC` (`new_actor`), `SUCC_COUNTER_COL_SPEC` (`new_delta`) |
| 9 `EXPAND` | `EXPAND_COL_SPEC` (`new_boolean`) |
| 10 `MARK_NAME` | `MARK_NAME_COL_SPEC` (`new_string`) |

`ALL_COLUMN_SPECS: [ColumnSpec; 16]` (`columns.rs:648-663`) lists all sixteen in export order. Note ids 6 and 7 are unused.

Change-graph columns (`change_graph.rs:1778+`, `ids` module): `ACTOR_COL_SPEC`, `SEQ_COL_SPEC`, `MAX_OP_COL_SPEC`, `TIME_COL_SPEC`, `MESSAGE_COL_SPEC`, `DEPS_COUNT_COL_SPEC`, `DEPS_VAL_COL_SPEC`, `EXTRA_META_COL_SPEC`, `EXTRA_VAL_COL_SPEC` — nine columns (`change_graph.rs:256-271`). Deps are stored as a per-node count plus a flat delta-encoded stream of `NodeIdx`.

Value encoding: `ValueMeta(u64)` packs `(length << 4) | type_code`, with type codes `0=Null, 1=False, 2=True, 3=Uleb, 4=Leb, 5=Float, 6=String, 7=Bytes, 8=Counter, 9=Timestamp`, anything else `Unknown(n)` (`meta.rs:23-43`, `meta.rs:56-73`). `ValueMeta` is a `hexane::PrefixValue` with `Prefix = u64` summing the lengths, so the prefix sum is a byte offset into the single `value` blob (`meta.rs:139-146`). `ScalarValue::to_raw` / `from_raw` (`op_set2/types.rs:318-373`) round-trip: `Null`/`Boolean` contribute zero bytes; `Uint` uleb128; `Int`/`Counter`/`Timestamp` sleb128; `F64` 8 LE bytes; `Str`/`Bytes`/`Unknown` raw.

Action encoding: `MakeMap=0, Set=1, MakeList=2, Delete=3, MakeText=4, Increment=5, MakeTable=6, Mark=7` (`op_set2/types.rs:88-113`). `TryFrom<Action> for ObjType` maps the four `Make*` actions and errors for the rest (`op_set2/types.rs:115-127`).

Mark index encoding: `MarkIdx` is stored as a *signed* 64-bit `i64` — `Start(id)` is `+((actor << 32) | (ctr & 0xffffffff))`, `End(id)` is its negation (`op_set2/op_set/mark_index.rs:25-50`). Because the value is sign-sensitive, counters are masked to 32 bits and the actor to 32 bits; a counter ≥ 2^32 or actor index ≥ 2^32 would silently alias.

**Inside a change chunk** (`build_change_inner`, `op_set2/change.rs:50-125`). Byte layout, in order:

1. `leb128(deps.len())`, then each dep's 32 raw hash bytes (deps are **node indices into the graph**, resolved through `G: GetHash`; a `None` here is `.unwrap()`-ed, so a missing index panics rather than erroring — `change.rs:76-79`).
2. length-prefixed actor id (`uleb` length + bytes).
3. `leb128(seq)`, `leb128(start_op)`, `leb128_signed(timestamp)`.
4. length-prefixed commit message.
5. `leb128(other_actors.len())` then each length-prefixed other actor id.
6. The op columns, written by `write_change_ops` (`change.rs:181-253`) into `col_data` and then `ops_meta.raw_columns().write(&mut data)`: `obj_actor`, `obj_ctr`, `key_actor`, `key_ctr` (delta), `key_str`, `insert`, `action`, `value_meta`, `value` (raw blob), `pred_count`, `pred_actor`, `pred_ctr` (delta), `expand`, `mark_name` — the `ChangeOpsColumns` record of 14 `Range<usize>` offsets (`change.rs:145-163`).
7. `extra_bytes` (the encoded author footer), only if non-empty.
8. A `Header::new(ChunkType::Change, &data)` prepended (`change.rs:100-105`); all recorded ranges are shifted by `header.len()`.

Actor indices in a change are **remapped to change-local indices** by `ActorMapper` (`change.rs:288-354`): the change's own actor always maps to 0, and other actors are assigned in ascending document-actor-index order over the actors actually referenced by obj/key/pred (`change.rs:333-347`). This is why `build_change` is actor-table-relative and why `OpId` comparison for conflict resolution uses *document* actor indices, not change-local ones.

---

## Zig mapping notes

**Native transaction ownership.** `Document` has no public mode switch.
`transaction.Transaction` borrows it. `OwnedTransaction` embeds the same journal engine and owns the document at its final address.
`AutoCommit` owns one raw document and one optional transaction.
Writes reuse that transaction until commit or rollback (`src/transaction.zig:156-159`, `src/autocommit.zig:30-39`, `:114-173`).

Ordinary reads do not publish pending operations.
Explicit historical reads select the transaction's clock rather than the raw current-head shortcut.
Raw hydration retains its separate scope exception (`src/read.zig:942-963`, `:2261-2447`).
`cloneInto` copies both document state and the open journal without closing the source (`src/autocommit.zig:193-215`).

Commit returns an owned `{ hash, patch_log }` result, including a no-write result.
`CommitResult.deinit(gpa)` releases the log (`src/transaction.zig:110-122`).
Closure outcomes preserve generic user errors, separate rollback errors, and any retained recovery owner (`src/transaction.zig:124-153`).
`Transaction.deinit` is fallible and rolls back open work.
`deinitClosed` is resource-only disposal after a terminal transition or whole-document destruction (`src/transact.zig:321-344`).


**Trait mapping.** Rust `Transactable` and `OpLike` describe operations over several concrete owners and rows.
`OpLike::SuccIter<'b>` is a GAT (`op.rs:1327-1372`).
Native rows expose `succCount`, `succAt`, `succIncCount`, and `succIncAt`.
Compile-time generic callers select those accessors without a vtable (`src/opset/op.zig:34-52`).

**Enum → tagged union.** `Action` (`op_set2/types.rs:61-82`) → `const Action = enum { make_map, make_list, make_text, set, delete, increment, make_table, mark };` with `@intFromEnum`/`@enumFromInt` for the durable codes, but note the durable codes are *not* in declaration order (`MakeMap=0, Set=1, MakeList=2, …`), so the `From<Action> for u64` table must be transcribed, not `@intFromEnum`. Same for `ResolvedAction` (`op_set.rs:1525`), `Top` (`batch.rs:363`), `ClockRange` (`clock.rs:69`), `ValueType` (`meta.rs:4`), `MarkIdx`/`MarkIndexBuilder` (`mark_index.rs:12`, `:18`), `Adjust` (`batch.rs:355`), `TopIterInner` (`top_op.rs:165`), `VisIter` (`visible.rs:44`), `Actor` (`automerge.rs:47`), `OnPartialLoad`/`StringMigration` (`automerge.rs:74`, `:83`).

**Option → `?T`.** `Option<Clock>` is the load-bearing one: `None` means "unscoped read, use the indexed fast path", `Some` means "filter by this clock" (`automerge.rs:1241-1246`, `op_set.rs:632-653`, `automerge.rs:794-810`). Porting `Option` to a nullable `?Clock` is direct, but the *semantics* of `None` (a performance dispatch, not merely "no filter") must be preserved. `Option<Arc<MarkSet>>` (`op_set.rs:1442`) becomes `?*const MarkSet` or an explicit `marks_ptr: ?*const MarkSet` field, because `Arc<MarkSet>` gives shared ownership of an immutable, refcounted snapshot shared by many ops in a query result — Zig has no `Arc`, only `Rc` (non-atomic) or a hand-rolled atomic refcount. `Arc` here is only ever used for immutable `MarkSet` snapshots, so `Rc` would suffice, but `MarkSet` is presumably `Send` via `Arc`; `Rc` is not `Send`. `[INFERENCE]`

**Result → error union.** `Result<(), AutomergeError>` → `AutomergeError!void`. The error set is closed and large (`error.rs:14-72`): `ChangeGraph`, `Deflate`, `DuplicateSeqNumber`, `DuplicateAuthor`, `DuplicateActorId`, `Fail`, `InvalidActorId`, `InvalidActorIndex`, `InvalidChangeHashBytes`, `InvalidCharacter`, `InvalidHash`, `InvalidIndex`, `InvalidObjId`, `InvalidObjIdFormat`, `InvalidOp`, `InvalidSeq`, `InvalidCursor`, `InvalidCursorOp`, `InvalidCursorFormat`, `InvalidValueType`, `Load`, `LoadChangeError`, `MissingCounter`, `MissingHash`, `MissingDeps`, `NonChangeCompressed`, `NotAnObject`, `HydrateError`, `PatchLogMismatch`, `EncodingError`, `Unbundle`. Several carry *payloads* (`InvalidValueType { expected, unexpected }`, `InvalidIndex(usize)`, `DuplicateAuthor(Author, ActorId, u64)`, `Unbundle(Box<dyn Error + Send + Sync>)`). Zig error values cannot carry payloads; these must be logged to a struct field on the document or re-materialised by re-deriving from the call site. `Unbundle(Box<dyn Error + Send + Sync + 'static>)` is a boxed trait object and has no Zig equivalent — use `anyerror` or an explicit enum. Note also `impl PartialEq for AutomergeError` compares only `std::mem::discriminant` (`error.rs:100-106`) — the equality is tag-only, which Zig error sets reproduce exactly.

**`impl Iterator` → `Iterator` + `next()`.** `ChangeGraph` alone has ~20 `-> impl Iterator` returns (`change_graph.rs:108, 112, 119, 126, 223, 227, 231, 322, 338, 404, 766, 774, 784`). Each becomes a distinct struct with a `next(self: *Self) ?Item` plus a `deinit`. The CRTP-style iterators with a generic `S: Skipper` parameter (`DiffIter` in `iter/tools.rs:529`, `TopIter` at `top_op.rs:158`) are best ported as generic functions returning a generic struct — Zig supports that directly, which is the one place Zig is *better* than the Rust code here. `ExactSizeIterator` maps to a `len(self) usize` method. `nth(n)` is hand-rolled in `OpIter` (`op_iter.rs:191-193`) and `ChangeIter` (`change_graph.rs:1692`) and calls `try_nth`, which `.unwrap()`s — in Zig the error must be propagated rather than panicked, or the port silently diverges on corrupt input.

**`Cow<'a, str>` / `Cow<'a, [u8]>` → pointer + length + ownership flag.** `ScalarValue` (`op_set2/types.rs:177-189`) is the worst case: every variant can be borrowed or owned, and `as_raw`/`to_raw`/`into_owned`/`to_owned`/`into_legacy` produce different ownership on each path (`op_set2/types.rs:226-417`). A faithful Zig port needs either a tagged union with a `[]const u8` + `owned: ?[]u8` pair, or a small string-type with explicit `deinit`. There is no zero-cost equivalent; every design here costs either a copy or a manual refcount.

**Hash maps and ordered sets.** Rust's maps cover graph hashes and clocks (`change_graph.rs:42-43`),
counter and object indexes (`index.rs:10`, `:24`, `:78`), and mark caches (`mark_index.rs:236`).
`MarkAcc` uses `FxHashSet` (`mark_index.rs:99-103`). Its upstream performance comment does not measure native hashers.
`deps` needs membership (`automerge.rs:255`). Graph heads need sorted iteration and set equality (`change_graph.rs:41`, `:137`).
The column-spec map also has ordered keys (`columns.rs:253`).
Native container selection must preserve those ordering contracts. This survey reports no native performance comparison.

**Borrowing → slices/pointers.** `Op<'a>` (`op.rs:831-844`) is a *borrowed* view: `key: KeyRef<'a>` and `value: ScalarValue<'a>` borrow from the column blobs, and `mark_name: Option<&'a str>` borrows from the `key_str`/`mark_name` column. In Zig the equivalent is a struct of `[*]const u8` + `usize` with the lifetime erased and the backing `Columns` kept alive by the caller. `Success<O>` / `Failure<E>` (`result.rs`) and `Transactable`'s `O: AsRef<ExId>` / `P: Into<Prop>` / `V: Into<ScalarValue>` generic parameters are the main porting friction: `Into<Prop>` means `put(ROOT, "k", 1)` and `put(&obj, 0, "v")` are the same method. In Zig, resolve at comptime with a tagged-union parameter: `put(obj: ExId, prop: Prop, value: ScalarValue)`, and make callers construct `Prop` explicitly, or add comptime-generic wrappers.

**`impl Trait` / opaque.** `AutoCommit::sync() -> impl SyncDoc + '_` (`autocommit.rs:779`) hides Rust's `SyncWrapper`.
Native `AutoCommit.sync()` closes and returns a concrete borrowed `Sync`.
Receive selects an inactive log during isolation (`src/autocommit.zig:375-430`).

**`Arc` → refcount, `Rc` → `Rc`, interior mutability → raw pointers.** `Arc<MarkSet>` is the only `Arc` in the covered surface (`inner.rs:311`, `op_set.rs:1442`, `op.rs:1507`, `top_op.rs:68`). Interior mutability is absent — `Automerge`, `OpSet`, `ChangeGraph` are all `&mut self`-mutated. The one exception is `hexane`'s column API itself, which is out of this slice.

**`unsafe` → note the invariant.** The covered files contain almost no `unsafe`; the crate has no `#![forbid(unsafe_code)]` and `lib.rs:184-206` does not mention `unsafe_code`. The places a Zig port would *need* `unsafe` that Rust gets from safe code: (a) reconstructing an `Op<'a>` from parallel column iterators — the Rust code does this with an `OpIter` holding eleven sub-iterators and relying on all columns being the same length (`op_set.rs:1318-1342`); the invariant is that `id_actor.len() == obj_actor.len() == … == self.len()`, checked only by `validate_top_index` (`op_set.rs:183-186`); (b) `NodeIdx(u32)` ↔ `usize` and `ActorIdx(u32)` ↔ `usize` conversions (`op_set2/types.rs:24-49`) with the FIXME "shouldn't this be usize? (wasm is 32bit)" — on a 32-bit Zig target these are not free; (c) `MarkIdx::as_i64`/`load` (`mark_index.rs:25-50`) pack an `OpId` into 64 bits with two 32-bit masks — needs `@bitCast`-level care.

**No clean Zig equivalent — flagged:**

1. **GATs.** Rust `OpLike::SuccIter<'b>` has no direct Zig lifetime equivalent (`op.rs:1329-1332`).
   The native static-arity accessor contract above replaces it.
2. **`dyn` + associated types.** Rust `OpLike::succ_inc` returns a boxed iterator (`op.rs:511`, `:590`, `:677`, `:810`).
   Native successor windows use caller-owned buffers and checked cursors (`src/opset/op.zig:484-502`).
3. **`#[cfg]`-gated surface.** `slow_path_assertions` adds `assert_matches_slow` (`top_op.rs:77`), `SlowTopOpIter` (`top_op.rs:110-153`), a `seek_ops_by_index_slow` cross-check (`op_set.rs:645-650`), a `succ`-sort cross-check (`batch.rs:924-935`), and indexed-vs-walked marks cross-checks (`automerge.rs:1587`, `:1939`). These are *assertions about the fast path*, so the Zig port should keep them behind a build option and, better, make them a test target rather than a build flag. The `wasm` feature changes `CAN_OOM` (`collector.rs:997-1001`) and adds `From` impls into `wasm_bindgen::JsValue` — no Zig analogue, and a direct port must decide what "OOM during load" means (`VecEncoder::try_new` uses `try_reserve` and returns `OutOfMemory`, `collector.rs:286-292`).
4. **Macros that expand into public API.** Rust's `impl_read_doc_for_tx!` and `impl_transactable_for_tx!` implement both transaction forms (`transaction.rs:37-526`).
   Native borrowed and owned transactions use the same journal engine.
   Compile-time `ReadDoc(R)` dispatch borrows the corresponding owner (`src/transaction.zig:156-159`, `src/read.zig:2261-2274`).
5. **`Send`/`Sync` bounds.** Rust asserts `OwnedTransaction` and `AutoCommit` are `Send` (`owned_transaction.rs:27-32`, `autocommit.rs:1378-1383`).
   Zig has no equivalent type-system check.
   Open native owners keep stable addresses. Closed `AutoCommit` owners can transfer ownership (`src/autocommit.zig:30-39`).
   C callers additionally use one global serialization boundary (`src/c/result.zig:94-113`).
6. **Allocator plumbing.** Rust uses the global allocator throughout.
   Native loaders and savers take explicit allocators (`src/doc.zig:3794-3832`).
   Native columns retain their allocator for owned storage (`src/hexane/column.zig:3303-3308`).
7. **`serde` derive surface.** `ExId: Serialize` is hand-written (serialises to a string, `exid.rs:170-175`); `ActorId` has `#[derive(…)]` plus a manual `Debug` (`types.rs:44-48`); `ChangeMetadata`, `SaveOptions`, `LoadOptions`, `Value`, `Prop` all have derive surface. `LoadOptions` has private fields and a builder API (`automerge.rs:91-171`) — in Zig, an options struct with a public builder function chain.
8. **`no_std`.** Not applicable as written — the crate uses `std` throughout (`std::collections`, `std::time`, `getrandom`, `sha2`). A `no_std` port is a separate project.

---

## Risk

**Silently dropped dependencies.** `TransactionInner::export` maps dep hashes to graph node indices with `filter_map` (`inner.rs:198-204`), so a dep that is not in the graph disappears from the change with no error. `ChangeGraph::heads_to_nodes` does the same (`change_graph.rs:784-792`), and `clock_at` on an unknown head yields a clock that silently omits that head's entire history. `deps_for_hash` skips unknown targets (`change_graph.rs:322-331`). Every one of these turns a corrupted-document condition into a wrong answer rather than an error. A Zig port that replaces `filter_map` with a `while (it.next()) |h| { … }` loop will *panic* on the `unwrap`-equivalent instead of diverging — a different failure mode, and arguably better, but not the same behaviour, so tests that rely on the silent path will diverge.

**`unwrap()`/`expect()` in the mutation path.** `update_history` (`automerge.rs:1292`, `:1297`), `Automerge::import_ops` (`batch.rs:1120`, `:1125`), `build_change_inner`'s dep resolution (`change.rs:78`), `NonZeroU64::new(max_op + 1).unwrap()` (`automerge.rs:566`), `OpId::new(counter, actor).try_into().unwrap()` (`types.rs:463`), and `start_op: NonZero::new(start_op).unwrap()` (`change.rs:118`) all panic on malformed input. These are reachable from a corrupt `save()` payload, since `load` feeds the same code path (`automerge.rs:911-995`). A Zig port must decide per-site whether to propagate an error (changing the signature of `commit`, `update_history`, `build_change`) or to `@panic`. Getting this wrong turns a load-time validation failure into memory unsafety in the port.

**Index-column coherence is asserted, not maintained.** `validate_top_index` (`op_set.rs:177-213`) and `validate_op_order` (`op_set.rs:167-175`) are `#[cfg(test)]`-adjacent: `validate_op_order` is called from a `debug_assert!` (`batch.rs:949`), which vanishes in release. `OpSet::splice` splices 19 columns and assumes every prefix-column offset is consistent (`columns.rs:420-…`); a single off-by-one in `value_meta.get_prefix(pos)` corrupts every subsequent value blob silently. This is the highest-value target for a Zig port's own invariant checks, and the place where a "compiles and passes the test suite" port is most likely to be *wrong* rather than *broken*.

**`Op::step`'s ordering rule is subtle and under-specified.** `op.rs:1048-1071` implements a *custom* total order: ops must be grouped by strictly increasing `ObjId`; within an object, `elemid_or_key()` must be non-decreasing with the special case that a `KeyRef::Seq` insert may be positioned by `ElemId(self.id) < e2` *or* equal to its predecessor. The comment at `types.rs:432-433` says the `OpId` `Ord` impl is hand-written specifically so this cannot break "from a generated derive". A Zig port that replaces any of these with a lexicographic `std.mem.sort` comparator will produce an op set that saves and loads but *merges differently* — the failure is silent and appears only in cross-device merge tests.

**`MarkIdx` 32-bit packing.** `as_i64`/`load` (`mark_index.rs:25-50`) pack `actor << 32 | (counter & 0xffffffff)` and negate for `End`. A counter or actor index ≥ 2^32 aliases to a different mark. Zig's `@bitCast` on a struct layout is *not* guaranteed to match, so this must be written as explicit shifts/masks, not as a bitcast of a packed struct.

**`OpSet::splice` drops delete ops.** `columns.rs:426-427` filters `Action::Delete` out of the row set. A port that materialises delete rows (the obvious reading of "insert an op") changes `OpSet::len()`, every prefix-column offset, `sub_len()`, and `succ_count.get_prefix` — all of which feed the durable byte layout. Documents would no longer round-trip.

**`Clock` truncation.** `Clock(Vec<u32>)` and `SeqClock(Vec<Option<NonZeroU32>>)` are indexed by actor position, not actor id, and every insert/remove of an actor must shift them (`change_graph.rs:151-186`, `op_set2/columns.rs:342-358`, `op_set.rs:1407-1430`, `clock.rs:22-28`). `SeqClock::covers` `assert_eq!`s the lengths (`clock.rs:58`), so a missed remap is a panic in release-stripped builds or a wrong answer in a port that drops the assert. Actor insertion is not rare: `transaction_args` calls `get_or_create_actor_index` on every transaction (`automerge.rs:546`), and `isolate_actor` can insert several.

**`reset_top` for scoped transactions is under-specified.** `insert_local_op` only records `op.reset_range = Some(range)` when `self.scope.is_some()` (`inner.rs:316-321`), and rollback replays `reset_top` over it (`op_set.rs:254-256`). But `reset_range` is recorded *before* the successor state is final, and the range stored is the pre-insert `range`, not the post-insert `range.start..range.end + added`. A port that "cleans this up" changes rollback behaviour for isolated transactions. `[INFERENCE]` — the interaction is not covered by an explicit test I read.

**Counter increments and `normalize_increment_successors` are applied at two different points with two different sources of truth.** In `BatchApply`, incoming change ops are normalised against the *op's own declared value* (`batch.rs:274-278`, `:432-437`) while document ops are normalised against the *document op's* value (`batch.rs:70-74`, `:492-504`). Getting these backwards silently changes counter merge results.

**Hasher performance requires measurement.** Rust's `mark_index.rs:101-102` comment reports a 3-5× per-hash `rustc_hash` improvement.
That comment does not measure native mark-heavy workloads or compare native hashers.
No native speedup or regression follows from the comment alone.

**`hexane` is the upstream column-storage engine, not an optional row-array replacement.**
Its codecs, prefix sums, and edit indexes define the wire format.
The native repository implements those column interfaces under `src/hexane/`.
This source mapping makes no claim about an unmeasured performance ratio or identical compressed save bytes.

**Unverifiable without running the code.** The following claims in this survey are read off the source and not executed: that `OpSet::splice`'s 19-column lockstep splice is correct for all prefix columns; that `Untangler::finish`'s `assert!(entry.is_empty())` and `assert_eq!(self.top, Top::Nothing)` never fire in production; that `BatchApply::insert_runs_of_ops`'s `shift` arithmetic is right for interleaved object runs; that `MarkOrderValidator` is the complete set of mark-order invariants the loader enforces; that `ChangeGraph::add_changes`' `debug_assert_eq!(seq_index[actor].len() + 1, change.seq())` cannot be violated by a hostile change stream that arrives topologically sorted but with a *gap* (it can — a change with `seq = 3` arriving before `seq = 2` for a brand-new actor passes the queue's Kahn test only if `seq = 2` is present as a dep, which `add_change` checks, so the gap case is caught by `MissingDep` rather than the assert; this reasoning is `[INFERENCE]`). Each of these is a place where a Zig port that "looks right" can be wrong in a way no signature-level review catches.
