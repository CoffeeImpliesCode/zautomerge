# Slice 7 — Bindings Surface: C ABI, wasm, JavaScript, CLI, interop, Nix

## Scope

Paths covered, with line counts.

**`rust/automerge-c/`** (crate `automerge-c` 0.2.2, `lib.name = "automerge_core"`, `crate-type = ["staticlib"]`; `rust/automerge-c/Cargo.toml:1-22`)

| File | Lines | Role |
|---|---|---|
| `src/lib.rs` | 11 | `mod` list only: `actor_id, byte_span, change, cursor, doc, index, item, items, obj, result, sync` (`src/lib.rs:1-13`) |
| `src/byte_span.rs` | 227 | `AMbyteSpan` + 3 fns |
| `src/result.rs` | 653 | `AMresult`, `AMstatus`, 7 fns, ~35 `From` impls |
| `src/actor_id.rs` | 193 | `AMactorId` + 6 fns |
| `src/change.rs` | 356 | `AMchange` + 15 fns |
| `src/cursor.rs` | 168 | `AMcursor` + 5 fns |
| `src/doc.rs` | 1009 | `AMdoc` + 33 fns, `pub mod list/map/mark/utils` (`:15-18`) |
| `src/doc/utils.rs` | 46 | `clamp!`, `to_doc!`, `to_doc_mut!`, `to_items!` macros |
| `src/doc/list.rs` | 636 | 15 `AMlist*` fns |
| `src/doc/map.rs` | 556 | 15 `AMmap*` fns |
| `src/doc/mark.rs` | 296 | `AMmark`, `AMmarkExpand`, 6 fns |
| `src/index.rs` | 84 | `AMindex` (private), `AMidxType` |
| `src/item.rs` | 2177 | `AMitem`, `AMunknownValue`, `AMvalType`, internal `Value`/`Item`, 36 fns |
| `src/items.rs` | 401 | `AMitems` iterator, 7 fns |
| `src/obj.rs` | 216 | `AMobjId`, `AMobjType`, 4 fns |
| `src/sync.rs` | 7 | `pub mod have; pub mod message; pub mod state;` |
| `src/sync/have.rs` | 42 | `AMsyncHave` + 1 fn |
| `src/sync/message.rs` | 146 | `AMsyncMessage` + 5 fns |
| `src/sync/state.rs` | 262 | `AMsyncState` + 8 fns |
| `src/utils/{result,stack,stack_callback_data,string}.c` | 33/105/9/46 | hand-written C utility layer |
| `include/automerge-c/utils/{result,stack,stack_callback_data,string}.h` | — | the only checked-in headers |
| `cbindgen.toml`, `build.rs`, `CMakeLists.txt` (439 lines), `cmake/` (6 files) | — | header generation + build |
| `examples/quickstart.c` | 131 | canonical usage |
| `test/` (21 files, cmocka) | — | incl. `test/ported_wasm/{basic,sync,cursor}_tests.c` ported from the wasm suite |

`automerge.h` itself is **not** checked in; it is generated at build time.

**`rust/automerge-wasm/`** (crate 0.1.0, `crate-type = ["cdylib","rlib"]`; `Cargo.toml:24-25`)

| File | Lines | Role |
|---|---|---|
| `src/lib.rs` | 3048 | `Automerge` class (`:447`), `impl` (`:454-1873`), free fns (`:1888-2309`), `pub mod error` (`:2311-3048`), `typescript_custom_section` (`:60-443`) |
| `src/interop.rs` | 2407 | JS↔Rust conversion (`JS`, `AR` newtypes, ~40 `TryFrom`/`From`) |
| `src/sequence_tree.rs` | 617 | private sequence tree for span ops; exports `pub struct Iter<'a,T>` (`:472`) only |
| `src/export_cache.rs` | 367 | `ExportCache` for materialize/hydrate; no public items |
| `src/sync.rs` | 83 | `SyncState` class (`:13`) + `DecodeSyncStateErr` |
| `src/value.rs` | 186 | `pub(crate) enum Datatype`, `InvalidDatatype` |
| `src/export-web-wasm.js`, `scripts/compile.mjs`, `fixup-node-cjs.mjs`, `package.json`, `deno-tests/deno.ts`, `test/` (10 files), `examples/` (3) | — | build/test harness |

**`javascript/`** — `src/index.ts` (7.5 KB, doc + 2 re-export lines), `src/implementation.ts` (2093 lines, the real API), `src/proxies.ts` (931), `src/apply_patches.ts` (396), `src/counter.ts` (~135), `src/conflicts.ts` (~130), `src/low_level.ts` (~135), `src/internal_state.ts` (56), `src/constants.ts` (16), `src/numbers.ts` (47), `src/types.ts` (~75), `src/immutable_string.ts` (20), `src/entrypoints/*.ts` (6 files, 28-302 B), `config/{declonly,mjs,cjs}.json`, `scripts/build.mjs` (516), `packaging_tests/` (14 fixtures + `run.mjs`), `test/` (14 files).

**`rust/automerge-cli/`** — `src/main.rs` (~280), `src/color_json.rs` (~350), `src/export.rs` (~100), `src/import.rs` (~110), `src/examine.rs` (~50), `src/examine_sync.rs` (~35), `src/merge.rs` (~55), `src/anonymize.rs` (~35), `src/change.rs` (8.3 KB, **not `mod`-declared** in `main.rs:15-22` — dead file), `tests/integration.rs`.

**`interop/`** — `README.md` (1.4 KB), `exemplar` (406 B binary).
**Root** — `flake.nix` (501), `flake.lock`, `.envrc` (10 B), `scripts/ci/` (12 shell scripts), `.github/workflows/` (4 files).

## Surface

### A. automerge-c — the C ABI

#### A.1 Preprocessor constants

From `cbindgen.toml` `after_includes` (`cbindgen.toml:1-19`):

```c
#define AM_ROOT NULL
#define AM_CHANGE_HASH_SIZE 32
```

From `cmake/config.h.in` (`cmake/config.h.in:15-45`), symbol prefix `AUTOMERGE_C` (derived from `project(automerge-c)`):

```c
#define AUTOMERGE_C_VERSION     /* 100000*major + 100*minor + patch */
#define AUTOMERGE_C_MAJOR_VERSION (AUTOMERGE_C_VERSION / 100000)
#define AUTOMERGE_C_MINOR_VERSION ((AUTOMERGE_C_VERSION / 100) % 1000)
#define AUTOMERGE_C_PATCH_VERSION (AUTOMERGE_C_VERSION % 100)
/* exactly one of: */
#define AUTOMERGE_C_UTF8   /* or */
#define AUTOMERGE_C_UTF32
```

`UTF32_INDEXING` is the only CMake option that changes the ABI's *meaning* (not its shape): `CMakeLists.txt:47-48` (option), `:106-112` (feature selection + `TEXT_INDEXING_ENCODING`).

#### A.2 Enumerations (5, all `#[repr(C)]`)

```c
typedef enum AMstatus {   /* src/result.rs:459-472 */
  AM_STATUS_OK = 0, AM_STATUS_ERROR = 1, AM_STATUS_INVALID_RESULT = 2
} AMstatus;

typedef enum AMidxType {  /* src/index.rs:52-66 */
  AM_IDX_TYPE_DEFAULT = 0, AM_IDX_TYPE_KEY = 1, AM_IDX_TYPE_POS = 2
} AMidxType;

typedef enum AMobjType {  /* src/obj.rs:156-170 */
  AM_OBJ_TYPE_DEFAULT = 0, AM_OBJ_TYPE_LIST = 1, AM_OBJ_TYPE_MAP = 2, AM_OBJ_TYPE_TEXT = 3
} AMobjType;

typedef enum AMmarkExpand { /* src/doc/mark.rs:33-48 */
  AM_MARK_EXPAND_DEFAULT = 0, AM_MARK_EXPAND_NONE = 1,
  AM_MARK_EXPAND_BEFORE = 2, AM_MARK_EXPAND_AFTER = 3, AM_MARK_EXPAND_BOTH = 4
} AMmarkExpand;

typedef enum AMvalType {  /* src/item.rs:1290-1338 */
  AM_VAL_TYPE_DEFAULT = 0,     AM_VAL_TYPE_VOID         = 1<<0,
  AM_VAL_TYPE_ACTOR_ID = 1<<1, AM_VAL_TYPE_BOOL        = 1<<2,
  AM_VAL_TYPE_BYTES  = 1<<3,   AM_VAL_TYPE_CHANGE      = 1<<4,
  AM_VAL_TYPE_CHANGE_HASH = 1<<5, AM_VAL_TYPE_COUNTER  = 1<<6,
  AM_VAL_TYPE_CURSOR  = 1<<7,  AM_VAL_TYPE_DOC         = 1<<8,
  AM_VAL_TYPE_F64     = 1<<9,  AM_VAL_TYPE_INT         = 1<<10,
  AM_VAL_TYPE_MARK    = 1<<11, AM_VAL_TYPE_NULL        = 1<<12,
  AM_VAL_TYPE_OBJ_TYPE= 1<<13, AM_VAL_TYPE_STR         = 1<<14,
  AM_VAL_TYPE_SYNC_HAVE = 1<<15, AM_VAL_TYPE_SYNC_MESSAGE = 1<<16,
  AM_VAL_TYPE_SYNC_STATE = 1<<17, AM_VAL_TYPE_TIMESTAMP = 1<<18,
  AM_VAL_TYPE_UINT    = 1<<19, AM_VAL_TYPE_UNKNOWN     = 1<<20
} AMvalType;
```

`AMvalType` and `AMmarkExpand` use non-sequential discriminants; cbindgen is configured with `enum_class = true`, `prefix_with_name = true`, `rename_variants = "ScreamingSnakeCase"`, `derive_const_casts = true`, `must_use = "MUST_USE_ENUM"` (`cbindgen.toml:22-28`). The exact numeric values are ABI.

#### A.3 Opaque handle types

Forward-declared only (no layout crosses the boundary): `AMactorId` (`src/actor_id.rs:22-26`), `AMobjId` (`src/obj.rs:29-33`), `AMchange` (`src/change.rs:17-21`), `AMcursor` (`src/cursor.rs:24-29`), `AMdoc` (`src/doc.rs:35-36`), `AMmark` (`src/doc/mark.rs:80-81`), `AMsyncHave` (`src/sync/have.rs:6-7`), `AMsyncMessage` (`src/sync/message.rs:24-28`), `AMsyncState` (`src/sync/state.rs:21-24`). `AMitem` is `pub struct AMitem(Rc<Item>)` (`src/item.rs:1023-1024`) — also effectively opaque.

#### A.4 Structs with layout

```c
typedef struct AMbyteSpan {      /* src/byte_span.rs:22-32, #[repr(C)] */
  const uint8_t* src;  size_t count;
} AMbyteSpan;

typedef struct AMunknownValue { /* src/item.rs:19-30, #[repr(C)], fields private */
  AMbyteSpan bytes; uint8_t type_code;
} AMunknownValue;

typedef struct AMitems {         /* src/items.rs:112-119, #[repr(C)] */
  uint8_t detail[sizeof(Detail)];   /* 24 on x86_64; opaque, post-processed */
  /* PhantomData<&'a mut AMresult> — erased */
} AMitems;
```

`USIZE_USIZE_USIZE_` is a cbindgen workaround for `size_of::<Detail>()`; `CMakeLists.txt:150-151` rewrites the literal `USIZE_` token to `+8` via `file-regex-replace.cmake`. `Detail` is `{len: usize, offset: isize, ptr: *const c_void}` (`src/items.rs:11-15`).

#### A.5 The 166 `#[no_mangle]` exports

`path:line` is the Rust `fn` line. Signatures are given as C.

**`AMbyteSpan` — `src/byte_span.rs`**
```c
AMbyteSpan AMbytes(const uint8_t* src, size_t count);                          // :176
AMbyteSpan AMstr(const char* c_str);                                            // :194
int         AMstrCmp(AMbyteSpan lhs, AMbyteSpan rhs);                          // :216
```

**`AMresult` / `AMstatus` — `src/result.rs`**
```c
AMresult*  AMresultCat(const AMresult* dest, const AMresult* src);               // :504
AMbyteSpan AMresultError(const AMresult* result);                                // :538
void       AMresultFree(AMresult* result);                                      // :557
AMitem*    AMresultItem(AMresult* result);                                      // :575
AMitems    AMresultItems(AMresult* result);                                     // :597
size_t     AMresultSize(const AMresult* result);                                // :619
AMstatus   AMresultStatus(const AMresult* result);                              // :639
```

**`AMactorId` — `src/actor_id.rs`**
```c
AMbyteSpan AMactorIdBytes(const AMactorId*);                                    // :71
int        AMactorIdCmp(const AMactorId*, const AMactorId*);                    // :94
AMresult*  AMactorIdInit(void);                                                 // :118
AMresult*  AMactorIdFromBytes(const uint8_t* src, size_t count);                // :140
AMresult*  AMactorIdFromStr(AMbyteSpan value);                                  // :164
AMbyteSpan AMactorIdStr(const AMactorId*);                                      // :188
```

**`AMchange` — `src/change.rs`**
```c
AMresult*  AMchangeActorId(const AMchange*);                                    // :81
void       AMchangeCompress(AMchange*);                                        // :98
AMresult*  AMchangeDeps(const AMchange*);                                       // :117
AMbyteSpan AMchangeExtraBytes(const AMchange*);                                 // :135
AMresult*  AMchangeFromBytes(const uint8_t* src, size_t count);                 // :160
AMbyteSpan AMchangeHash(const AMchange*);                                       // :176
bool       AMchangeIsEmpty(const AMchange*);                                    // :194
AMresult*  AMchangeLoadDocument(const uint8_t* src, size_t count);              // :219
uint64_t   AMchangeMaxOp(const AMchange*);                                      // :237
AMbyteSpan AMchangeMessage(const AMchange*);                                    // :257
uint64_t   AMchangeSeq(const AMchange*);                                        // :275
size_t     AMchangeSize(const AMchange*);                                       // :294
uint64_t   AMchangeStartOp(const AMchange*);                                    // :312
int64_t    AMchangeTime(const AMchange*);                                       // :331
AMbyteSpan AMchangeRawBytes(const AMchange*);                                   // :350
```

**`AMcursor` — `src/cursor.rs`**
```c
AMbyteSpan AMcursorBytes(const AMcursor*);                                      // :79
bool       AMcursorEqual(const AMcursor*, const AMcursor*);                     // :101
AMresult*  AMcursorFromBytes(const uint8_t* src, size_t count);                 // :126
AMresult*  AMcursorFromStr(AMbyteSpan value);                                   // :148
AMbyteSpan AMcursorStr(const AMcursor*);                                        // :163
```

**`AMobjId` — `src/obj.rs`**
```c
const AMactorId* AMobjIdActorId(const AMobjId*);                                // :89
uint64_t        AMobjIdCounter(const AMobjId*);                                 // :107
bool            AMobjIdEqual(const AMobjId*, const AMobjId*);                   // :133
size_t          AMobjIdIndex(const AMobjId*);                                   // :151
```

**`AMitem` — `src/item.rs`**
```c
bool       AMitemEqual(const AMitem*, const AMitem*);                           // :1415
AMresult*  AMitemFromBool(bool value);                                          // :1430
AMresult*  AMitemFromBytes(const uint8_t* src, size_t count);                   // :1451
AMresult*  AMitemFromChangeHash(AMbyteSpan value);                              // :1470
AMresult*  AMitemFromCounter(int64_t value);                                    // :1482
AMresult*  AMitemFromF64(double value);                                          // :1494
AMresult*  AMitemFromInt(int64_t value);                                        // :1506
AMresult*  AMitemFromNull(void);                                                 // :1517
AMresult*  AMitemFromStr(AMbyteSpan value);                                     // :1535
AMresult*  AMitemFromTimestamp(int64_t value);                                  // :1548
AMresult*  AMitemFromUint(uint64_t value);                                      // :1560
AMidxType  AMitemIdxType(const AMitem*);                                        // :1576
const AMobjId* AMitemObjId(const AMitem*);                                      // :1595
bool       AMitemKey(const AMitem*, AMbyteSpan* value);                         // :1617
bool       AMitemPos(const AMitem*, size_t* value);                             // :1644
size_t     AMitemRefCount(const AMitem*);                                       // :1670
AMresult*  AMitemResult(const AMitem*);                                         // :1691
bool AMitemToActorId(const AMitem*, const AMactorId** value);                    // :1711
bool AMitemToBool(const AMitem*, bool* value);                                   // :1739
bool AMitemToBytes(const AMitem*, AMbyteSpan* value);                            // :1764
bool AMitemToChange(AMitem*, AMchange** value);              /* MUT item */      // :1789
bool AMitemToChangeHash(const AMitem*, AMbyteSpan* value);                      // :1814
bool AMitemToCounter(const AMitem*, int64_t* value);                            // :1839
bool AMitemToCursor(const AMitem*, const AMcursor** value);                     // :1864
bool AMitemToDoc(AMitem*, AMdoc** value);                   /* MUT item */      // :1889
bool AMitemToF64(const AMitem*, double* value);                                 // :1914
bool AMitemToInt(const AMitem*, int64_t* value);                                // :1939
bool AMitemToMark(const AMitem*, const AMmark** value);                         // :1964
bool AMitemToStr(const AMitem*, AMbyteSpan* value);                             // :1989
bool AMitemToSyncHave(const AMitem*, const AMsyncHave** value);                 // :2014
bool AMitemToSyncMessage(const AMitem*, const AMsyncMessage** value);           // :2042
bool AMitemToSyncState(AMitem*, AMsyncState** value);        /* MUT item */     // :2070
bool AMitemToTimestamp(const AMitem*, int64_t* value);                          // :2098
bool AMitemToUint(const AMitem*, uint64_t* value);                              // :2123
bool AMitemToUnknown(const AMitem*, AMunknownValue* value);                     // :2148
AMvalType  AMitemValType(const AMitem*);                                        // :2172
```

The three `MUT item` variants require a *unique* `AMitem` because they use `Rc::get_mut` (`src/item.rs:1189-1196`, `:1210-1218`, `:1234-1242`) and fail with `AutomergeError::Fail` on a shared item.

**`AMitems` — `src/items.rs`**
```c
void     AMitemsAdvance(AMitems* items, isize_t n);                             // :266
bool     AMitemsEqual(const AMitems*, const AMitems*);                          // :288
AMitem*  AMitemsNext(AMitems* items, isize_t n);                                // :312
AMitem*  AMitemsPrev(AMitems* items, isize_t n);                                // :338
size_t   AMitemsSize(const AMitems*);                                           // :358
AMitems  AMitemsReversed(const AMitems*);                                       // :377
AMitems  AMitemsRewound(const AMitems*);                                        // :396
```

**`AMdoc` — `src/doc.rs`** (33)
```c
AMresult* AMapplyChanges(AMdoc* doc, const AMitems* items);                      // :85
AMresult* AMclone(const AMdoc* doc);                                            // :108
AMresult* AMcreate(const AMactorId* actor_id);   /* NULL = random */             // :126
AMresult* AMcommit(AMdoc*, AMbyteSpan message, const int64_t* timestamp);       // :151
AMresult* AMemptyChange(AMdoc*, AMbyteSpan message, const int64_t* timestamp);  // :194
bool      AMequal(AMdoc* doc1, AMdoc* doc2);                                     // :225
AMresult* AMfork(AMdoc* doc, const AMitems* heads);   /* NULL = now */           // :249
AMresult* AMgenerateSyncMessage(AMdoc* doc, AMsyncState* sync_state);           // :278
AMresult* AMgetActorId(const AMdoc* doc);                                       // :300
AMresult* AMgetChangeByHash(AMdoc* doc, const uint8_t* src, size_t count);      // :327
AMresult* AMgetChanges(AMdoc* doc, const AMitems* have_deps);                   // :355
AMresult* AMgetChangesAdded(AMdoc* doc1, AMdoc* doc2);                          // :384
AMresult* AMgetCursor(const AMdoc*, const AMobjId* /*|AM_ROOT*/, size_t position, const AMitems* heads); // :412
AMresult* AMgetCursorPosition(const AMdoc*, const AMobjId*, const AMcursor*, const AMitems* heads);     // :455
AMresult* AMgetHeads(AMdoc* doc);                                               // :488
AMresult* AMgetMissingDeps(AMdoc* doc, const AMitems* heads);                   // :512
AMresult* AMgetLastLocalChange(AMdoc* doc);                                     // :540
AMresult* AMkeys(const AMdoc*, const AMobjId*, const AMitems* heads);           // :564
AMresult* AMload(const uint8_t* src, size_t count);                             // :598
AMresult* AMloadIncremental(AMdoc* doc, const uint8_t* src, size_t count);      // :623
AMresult* AMmerge(AMdoc* dest, AMdoc* src);                                     // :666
size_t    AMobjSize(const AMdoc*, const AMobjId*, const AMitems* heads);        // :706
AMobjType AMobjObjType(const AMdoc* doc, const AMobjId* obj_id);                 // :727
AMresult* AMobjItems(const AMdoc*, const AMobjId*, const AMitems* heads);       // :748
size_t    AMpendingOps(const AMdoc* doc);                                       // :772
AMresult* AMreceiveSyncMessage(AMdoc*, AMsyncState*, const AMsyncMessage*);     // :789
size_t    AMrollback(AMdoc* doc);                                               // :809
AMresult* AMsave(AMdoc* doc);                                                   // :823
AMresult* AMsaveIncremental(AMdoc* doc);                                       // :838
AMresult* AMsetActorId(AMdoc* doc, const AMactorId*);                           // :858
AMresult* AMsplice(AMdoc*, const AMobjId*, size_t pos, isize_t del, AMitems values);        // :877
AMresult* AMspliceText(AMdoc*, const AMobjId*, size_t pos, isize_t del, AMbyteSpan text);  // :902
AMresult* AMtext(const AMdoc*, const AMobjId*, const AMitems* heads);           // :930
```

**List — `src/doc/list.rs`** (15)
```c
AMresult* AMlistDelete(AMdoc*, const AMobjId*, size_t pos);                     // :50
AMresult* AMlistGet(const AMdoc*, const AMobjId*, size_t pos, const AMitems*);  // :83
AMresult* AMlistGetAll(const AMdoc*, const AMobjId*, size_t pos, const AMitems*); // :124
AMresult* AMlistIncrement(AMdoc*, const AMobjId*, size_t pos, int64_t value);   // :162
AMresult* AMlistPutBool(AMdoc*, const AMobjId*, size_t pos, bool insert, bool value);        // :198
AMresult* AMlistPutBytes(AMdoc*, const AMobjId*, size_t pos, bool insert, AMbyteSpan value); // :244
AMresult* AMlistPutCounter(AMdoc*, const AMobjId*, size_t pos, bool insert, int64_t value);  // :286
AMresult* AMlistPutF64(AMdoc*, const AMobjId*, size_t pos, bool insert, double value);        // :328
AMresult* AMlistPutInt(AMdoc*, const AMobjId*, size_t pos, bool insert, int64_t value);      // :369
AMresult* AMlistPutNull(AMdoc*, const AMobjId*, size_t pos, bool insert);                    // :409
AMresult* AMlistPutObject(AMdoc*, const AMobjId*, size_t pos, bool insert, AMobjType);       // :449
AMresult* AMlistPutStr(AMdoc*, const AMobjId*, size_t pos, bool insert, AMbyteSpan value);  // :494
AMresult* AMlistPutTimestamp(AMdoc*, const AMobjId*, size_t pos, bool insert, int64_t value); // :537
AMresult* AMlistPutUint(AMdoc*, const AMobjId*, size_t pos, bool insert, uint64_t value);   // :579
AMresult* AMlistRange(const AMdoc*, const AMobjId*, size_t begin, size_t end, const AMitems*); // :619
```

**Map — `src/doc/map.rs`** (15)
```c
AMresult* AMmapDelete(AMdoc*, const AMobjId*, AMbyteSpan key);                  // :30
AMresult* AMmapGet(const AMdoc*, const AMobjId*, AMbyteSpan key, const AMitems* heads);   // :63
AMresult* AMmapGetAll(const AMdoc*, const AMobjId*, AMbyteSpan key, const AMitems* heads); // :105
AMresult* AMmapIncrement(AMdoc*, const AMobjId*, AMbyteSpan key, int64_t value); // :143
AMresult* AMmapPutBool(AMdoc*, const AMobjId*, AMbyteSpan key, bool value);     // :174
AMresult* AMmapPutBytes(AMdoc*, const AMobjId*, AMbyteSpan key, AMbyteSpan value); // :208
AMresult* AMmapPutCounter(AMdoc*, const AMobjId*, AMbyteSpan key, int64_t value); // :239
AMresult* AMmapPutNull(AMdoc*, const AMobjId*, AMbyteSpan key);                 // :273
AMresult* AMmapPutObject(AMdoc*, const AMobjId*, AMbyteSpan key, AMobjType);   // :303
AMresult* AMmapPutF64(AMdoc*, const AMobjId*, AMbyteSpan key, double value);    // :339
AMresult* AMmapPutInt(AMdoc*, const AMobjId*, AMbyteSpan key, int64_t value);  // :370
AMresult* AMmapPutStr(AMdoc*, const AMobjId*, AMbyteSpan key, AMbyteSpan value); // :401
AMresult* AMmapPutTimestamp(AMdoc*, const AMobjId*, AMbyteSpan key, int64_t value); // :432
AMresult* AMmapPutUint(AMdoc*, const AMobjId*, AMbyteSpan key, uint64_t value); // :463
AMresult* AMmapRange(const AMdoc*, const AMobjId*, AMbyteSpan begin, AMbyteSpan end, const AMitems* heads); // :500
```

**Marks — `src/doc/mark.rs`** (6)
```c
AMbyteSpan AMmarkName(const AMmark*);                                           // :109
AMresult*  AMmarkValue(const AMmark*);                                          // :129
size_t     AMmarkStart(const AMmark*);                                          // :148
size_t     AMmarkEnd(const AMmark*);        /* NULL -> SIZE_MAX */              // :167
AMresult*  AMmarks(const AMdoc*, const AMobjId*, const AMitems* heads);         // :193
AMresult*  AMmarkCreate(AMdoc*, const AMobjId*, size_t start, size_t end,
                       AMmarkExpand expand, AMbyteSpan name, const AMitem* value); // :236
AMresult*  AMmarkClear(AMdoc*, const AMobjId*, size_t start, size_t end,
                      AMmarkExpand expand, AMbyteSpan name);                    // :283
```
(7 lines listed, 6 distinct `#[no_mangle]` + `AMmarks` is the 7th; total in this file is 7 — see the per-file tally in A.6.)

**Sync — `src/sync/{have,message,state}.rs`** (14)
```c
AMresult* AMsyncHaveLastSync(const AMsyncHave*);                                // have.rs:37
AMresult* AMsyncMessageDecode(const uint8_t* src, size_t count);                // message.rs:64
AMresult* AMsyncMessageEncode(const AMsyncMessage*);                            // message.rs:82
AMresult* AMsyncMessageHaves(const AMsyncMessage*);                             // message.rs:100
AMresult* AMsyncMessageHeads(const AMsyncMessage*);                             // message.rs:120
AMresult* AMsyncMessageNeeds(const AMsyncMessage*);                             // message.rs:141
AMresult* AMsyncStateDecode(const uint8_t* src, size_t count);                  // state.rs:73
AMresult* AMsyncStateEncode(const AMsyncState*);                                // state.rs:91
bool      AMsyncStateEqual(const AMsyncState*, const AMsyncState*);            // state.rs:111
AMresult* AMsyncStateInit(void);              /* the only non-`unsafe` export */ // state.rs:129
AMresult* AMsyncStateSharedHeads(const AMsyncState*);                           // state.rs:146
AMresult* AMsyncStateLastSentHeads(const AMsyncState*);                         // state.rs:164
AMresult* AMsyncStateTheirHaves(const AMsyncState*, bool* has_value);           // state.rs:186
AMresult* AMsyncStateTheirHeads(const AMsyncState*, bool* has_value);           // state.rs:218
AMresult* AMsyncStateTheirNeeds(const AMsyncState*, bool* has_value);           // state.rs:250
```

#### A.6 Per-file export tally

`byte_span.rs` 3 · `result.rs` 7 · `actor_id.rs` 6 · `change.rs` 15 · `cursor.rs` 5 · `doc.rs` 33 · `doc/list.rs` 15 · `doc/map.rs` 15 · `doc/mark.rs` 7 · `item.rs` 36 · `items.rs` 7 · `obj.rs` 4 · `sync/have.rs` 1 · `sync/message.rs` 5 · `sync/state.rs` 8 · `index.rs` 0 = **168** `#[no_mangle]` items, of which **166** are functions (the 2 extra are the `AMvalType` and `AMidxType` enum blocks, which are `#[repr(C)] pub enum`, not functions). Corrected tally: 166 functions.

#### A.7 Hand-written C utility layer (9 functions + 1 macro)

`src/utils/stack.c` + `include/automerge-c/utils/stack.h`:
```c
typedef struct AMstack { AMresult* result; struct AMstack* prev; } AMstack;
typedef bool (*AMstackCallback)(AMstack** stack, void* data);
void      AMstackFree(AMstack** stack);
AMresult* AMstackPop(AMstack** stack, AMresult const* result);
AMresult* AMstackResult(AMstack**, AMresult*, AMstackCallback, void*);
AMitem*   AMstackItem(AMstack**, AMresult*, AMstackCallback, void*);
AMitems   AMstackItems(AMstack**, AMresult*, AMstackCallback, void*);
size_t    AMstackSize(AMstack const* const);
```
`src/utils/result.c` + `include/.../result.h`: `AMresult* AMresultFrom(int count, ...);`
`src/utils/string.c` + `include/.../string.h`: `char* AMstrdup(AMbyteSpan const str, char const* nul);` (caller owns; `free()`).
`src/utils/stack_callback_data.c` + header: `AMstackCallbackData* AMstackCallbackDataInit(AMvalType bitmask, char const* file, int line);` and `#define AMexpect(bitmask) AMstackCallbackDataInit(bitmask, __FILE__, __LINE__)`.

#### A.8 CMake-generated enum string functions (10)

`cmake/enum-string-functions-gen.cmake:30-77` generates, for every `enum` in the generated header, `char const* AMxxxToString(AMxxx const tag);` and `bool AMxxxFromString(AMxxx* dest, char const* const src);`, emitted into `automerge-c/utils/enum_string.h`/`.c`. Unknown tags map to `"???"` (`:63-66`). That is 5 enums x 2 = 10 functions.

**Total C ABI: 166 Rust exports + 9 hand-written C + 10 generated C = 185 functions, 3 structs, 5 enums, 6 macros/constant macros.**

#### A.9 Header generation pipeline

`build.rs:1-19` runs cbindgen; honours `CBINDGEN_TARGET_DIR` to redirect output. `CMakeLists.txt:141-196`:
1. `file-touch.cmake` on `cbindgen.toml` — cbindgen caches on config mtime, so touching the config forces regeneration (`:149-151`).
2. `cargo build` with `--target=$host`, `-Z build-std=std,panic_abort` and `RUSTFLAGS=-C panic=abort` in release (`:96-104`, `:93-115`).
3. Regex fixup `A_M([^_]+)_` -> `AM_\1_`, compensating cbindgen's "ScreamingSnakeCase" mangling of `AMobjType` -> `A_M_ObjType` (`:153-155`).
4. Regex fixup `USIZE_` -> `+${CMAKE_SIZEOF_VOID_P}` (`:157-159`).

`CMakeLists.txt` also **rewrites `Cargo.toml` and `cbindgen.toml` in the source tree** from `cmake/Cargo.toml.in` and `cmake/cbindgen.toml.in` (`:117-128`) — a generated-file-in-VCS pattern.

Build: staticlib only from Cargo (`Cargo.toml:11-12`), merged into one C library target `automerge` (`:229-233`), optionally shared (`:281-283`, `WHOLE_ARCHIVE`), with post-build object merging on non-Windows static builds (`:319-338`).

### B. automerge-wasm — the wasm-bindgen surface

Two exported classes, 89 + 8 methods, 13 free functions, 1 `start` hook.

#### B.1 `Automerge` class — `src/lib.rs:445-1873`

```rust
#[wasm_bindgen]
#[derive(Debug)]
pub struct Automerge {                       // :447
    doc: AutoCommit,
    freeze: bool,
    external_types: HashMap<Datatype, interop::ExternalTypeConstructor>,
}
```

`doc` is always `AutoCommit::new_with_encoding(TextEncoding::Utf16CodeUnit)` (`:456`, `:1929`) — the wasm binding is **UTF-16-code-unit indexed, unconditionally**.

Methods (`js_name` shown where it differs; `skip_typescript` means the signature is hand-written in the TS custom section):

| js_name | Rust signature | path:line |
|---|---|---|
| `new` | `fn new(actor: Option<String>) -> Result<Automerge, error::BadActorId>` | :455 |
| `initRootFromHydrate` | `fn init_root_from_hydrate(&mut self, value: JsValue) -> Result<(), error::InitFromHydrate>` | :471 |
| `anonymize` | `fn anonymize(&mut self) -> Result<Automerge, error::Anonymize>` | :486 |
| `clone` | `fn clone(&mut self, actor: Option<String>) -> Result<Automerge, error::BadActorId>` | :495 |
| `fork` | `fn fork(&mut self, actor: Option<String>, heads: JsValue) -> Result<Automerge, error::Fork>` | :511 |
| `pendingOps` | `fn pending_ops(&self) -> JsValue` | :536 |
| `commit` | `fn commit(&mut self, message: Option<String>, time: Option<f64>) -> JsValue` | :541 |
| `merge` | `fn merge(&mut self, other: &mut Automerge) -> Result<Array, error::Merge>` | :557 |
| `rollback` | `fn rollback(&mut self) -> f64` | :566 |
| `keys` | `fn keys(&self, obj: JsValue, heads: JsValue) -> Result<Array, error::Get>` | :572 |
| `text` | `fn text(&self, obj: JsValue, heads: JsValue) -> Result<String, error::Get>` | :587 |
| `spans` | `fn spans(&self, obj: JsValue, heads: JsValue) -> Result<Array, error::GetSpans>` | :598 |
| `splice` | `fn splice(&mut self, obj: JsValue, start: f64, delete_count: f64, text: JsValue) -> Result<(), error::Splice>` | :612 |
| `updateText` | `fn update_text(&mut self, obj, new_text: JsValue) -> Result<(), error::UpdateText>` | :660 |
| `updateSpans` | `fn update_spans(&mut self, obj, args, config: JsValue) -> Result<(), error::UpdateSpans>` | :678 |
| `push` | `fn push(&mut self, obj, value, datatype: JsValue) -> Result<(), error::Insert>` | :698 |
| `pushObject` | `fn push_object(&mut self, obj, value: JsValue) -> Result<String, error::InsertObject>` | :713 |
| `insert` | `fn insert(&mut self, obj, index: f64, value, datatype: JsValue) -> Result<(), error::Insert>` | :735 |
| `splitBlock` | `fn split_block(&mut self, obj, index: f64, block: JsValue) -> Result<(), error::SplitBlock>` | :750 |
| `joinBlock` | `fn join_block(&mut self, obj, index: usize) -> Result<(), error::Block>` | :768 |
| `updateBlock` | `fn update_block(&mut self, obj, index: usize, block: JsValue) -> Result<(), error::UpdateBlock>` | :779 |
| `getBlock` | `fn get_block(&mut self, text, index: usize, heads: JsValue) -> Result<JsValue, error::GetBlock>` | :797 |
| `insertObject` | `fn insert_object(&mut self, obj, index: f64, value) -> Result<String, error::InsertObject>` | :823 |
| `put` | `fn put(&mut self, obj, prop, value, datatype: JsValue) -> Result<(), error::Insert>` | :845 |
| `putObject` | `fn put_object(&mut self, obj, prop, value) -> Result<JsValue, error::InsertObject>` | :861 |
| `putObjectFromHydrate` | `fn put_object_from_hydrate(&mut self, obj, prop, value) -> Result<JsValue, error::BatchCreateObject>` | :884 |
| `insertObjectFromHydrate` | `fn insert_object_from_hydrate(&mut self, obj, index: f64, value) -> Result<JsValue, error::BatchCreateObject>` | :903 |
| `spliceFromHydrate` | `fn splice_from_hydrate(&mut self, obj, index: f64, del: f64, values) -> Result<(), error::SpliceHydrate>` | :923 |
| `increment` | `fn increment(&mut self, obj, prop, value) -> Result<(), error::Increment>` | :976 |
| `get` | `fn get(&self, obj, prop, heads) -> Result<JsValue, error::Get>` | :991 |
| `getWithType` | `fn get_with_type(&self, obj, prop, heads) -> Result<JsValue, error::Get>` | :1016 |
| `objInfo` | `fn obj_info(&self, obj, heads) -> Result<Object, error::Get>` | :1057 |
| `getAll` | `fn get_all(&self, obj, arg, heads) -> Result<Array, error::Get>` | :1078 |
| `enableFreeze` | `fn enable_freeze(&mut self, enable) -> Result<bool, JsValue>` | :1103 |
| `registerDatatype` | `fn register_datatype(&mut self, datatype, export_function, import_function) -> Result<(), value::InvalidDatatype>` | :1116 |
| `applyPatches` | `fn apply_patches(&mut self, object, meta) -> Result<JsValue, JsValue>` | :1145 |
| `applyAndReturnPatches` | `fn apply_and_return_patches(&mut self, object, meta) -> Result<JsValue, JsValue>` | :1152 |
| `diffIncremental` | `fn diff_incremental(&mut self) -> Result<Array, error::PopPatches>` | :1205 |
| `updateDiffCursor` | `fn update_diff_cursor(&mut self)` | :1216 |
| `resetDiffCursor` | `fn reset_diff_cursor(&mut self)` | :1221 |
| `diff` | `fn diff(&mut self, before, after) -> Result<Array, error::Diff>` | :1226 |
| `diffPath` | `fn diff_path(&mut self, path, before, after, options) -> Result<Array, error::Diff>` | :1244 |
| `isolate` | `fn isolate(&mut self, heads) -> Result<(), error::Isolate>` | :1269 |
| `integrate` | `fn integrate(&mut self)` | :1281 |
| `length` | `fn length(&self, obj, heads) -> Result<f64, error::Get>` | :1287 |
| `delete` | `fn delete(&mut self, obj, prop) -> Result<(), error::Get>` | :1296 |
| `save` | `fn save(&mut self) -> Uint8Array` | :1307 |
| `saveIncremental` | `fn save_incremental(&mut self) -> Uint8Array` | :1312 |
| `saveSince` | `fn save_since(&mut self, heads) -> Result<Uint8Array, interop::error::BadChangeHashes>` | :1318 |
| `saveNoCompress` | `fn save_nocompress(&mut self) -> Uint8Array` | :1328 |
| `saveAndVerify` | `fn save_and_verify(&mut self) -> Result<Uint8Array, error::Load>` | :1334 |
| `loadIncremental` | `fn load_incremental(&mut self, data) -> Result<f64, error::Load>` | :1340 |
| `applyChanges` | `fn apply_changes(&mut self, changes) -> Result<(), error::ApplyChangesError>` | :1347 |
| `getChanges` | `fn get_changes(&mut self, have_deps) -> Result<Array, error::Get>` | :1361 |
| `getChangesMeta` | `fn get_changes_meta(&mut self, have_deps) -> Result<Array, error::Get>` | :1375 |
| `getChangeByHash` | `fn get_change_by_hash(&mut self, hash) -> Result<JsValue, interop::error::BadChangeHash>` | :1386 |
| `getChangeMetaByHash` | `fn get_change_meta_by_hash(&mut self, hash) -> Result<JsValue, interop::error::BadChangeHash>` | :1400 |
| `getDecodedChangeByHash` | `fn get_decoded_change_by_hash(&mut self, hash) -> Result<JsValue, error::GetDecodedChangeByHash>` | :1414 |
| `getChangesAdded` | `fn get_changes_added(&mut self, other: &mut Automerge) -> Array` | :1430 |
| `getFragmentMetadata` | `fn get_fragment_metadata(&mut self, levels) -> Result<Array, error::Fragments>` | :1440 |
| `getFragmentMeta` | `fn get_fragment_meta(&mut self, head) -> Result<JsValue, interop::error::BadChangeHash>` | :1454 |
| `bundleFragmentMetadata` | `fn bundle_fragment_metadata(&mut self, fragments) -> Result<Array, error::BadJSFragments>` | :1467 |
| `addCommits` | `fn add_commits(&mut self, commits) -> Result<(), error::AddCommits>` | :1481 |
| `addFragments` | `fn add_fragments(&mut self, fragments) -> Result<(), error::AddFragments>` | :1495 |
| `getHeads` | `fn get_heads(&mut self) -> Array` | :1512 |
| `getActorId` | `fn get_actor_id(&self) -> String` | :1518 |
| `getAuthor` | `fn get_author(&self) -> Option<String>` | :1523 |
| `getAuthors` | `fn get_authors(&self) -> Array` | :1528 |
| `getAuthorForActor` | `fn get_author_for_actor(&self, actor: String) -> Result<Option<String>, JsValue>` | :1537 |
| `getActorsForAuthor` | `fn get_actors_for_author(&self, author: String) -> Result<Array, JsValue>` | :1543 |
| `setAuthor` | `fn set_author(&mut self, author: Option<String>) -> Result<(), JsValue>` | :1554 |
| `getLastLocalChange` | `fn get_last_local_change(&mut self) -> JsValue` | :1564 |
| `dump` | `fn dump(&mut self)` | :1572 |
| `getMissingDeps` | `fn get_missing_deps(&mut self, heads) -> Result<Array, error::Get>` | :1578 |
| `receiveSyncMessage` | `fn receive_sync_message(&mut self, state: &mut SyncState, message: Uint8Array) -> Result<(), error::ReceiveSyncMessage>` | :1589 |
| `generateSyncMessage` | `fn generate_sync_message(&mut self, state: &mut SyncState) -> JsValue` | :1604 |
| `toJS` | `fn to_js(&mut self, meta) -> Result<JsValue, interop::error::Export>` | :1615 |
| `materialize` | `fn materialize(&mut self, obj, heads, meta) -> Result<JsValue, error::Materialize>` | :1623 |
| `getCursor` | `fn get_cursor(&mut self, obj, position, heads, move_cursor) -> Result<String, error::Cursor>` | :1639 |
| `getCursorPosition` | `fn get_cursor_position(&mut self, obj, cursor, heads) -> Result<f64, error::Cursor>` | :1688 |
| `emptyChange` | `fn empty_change(&mut self, message: Option<String>, time: Option<f64>) -> JsValue` | :1708 |
| `mark` | `fn mark(&mut self, obj, range, name, value, datatype) -> Result<(), error::Mark>` | :1718 |
| `unmark` | `fn unmark(&mut self, obj, range, name) -> Result<(), error::Mark>` | :1752 |
| `marks` | `fn marks(&mut self, obj, heads) -> Result<JsValue, JsValue>` | :1763 |
| `marksAt` | `fn marks_at(&mut self, obj, index: f64, heads) -> Result<Object, JsValue>` | :1786 |
| `hasOurChanges` | `fn has_our_changes(&mut self, state: &mut SyncState) -> bool` | :1819 |
| `topoHistoryTraversal` | `fn topo_history_traversal(&mut self) -> JsValue` | :1824 |
| `stats` | `fn stats(&mut self) -> JsValue` | :1835 |
| `saveBundle` | `fn save_bundle(&mut self, hashes) -> Result<Uint8Array, error::SaveBundle>` | :1855 |

Private helpers on the same impl: `subset` (`:958`), `apply_patches_impl` (`:1167`), `text_at` (`:1806`).

`unmark` is implemented by delegating to `mark` with a `null` value (`:1759`).

#### B.2 `SyncState` class — `src/sync.rs:12-77`

```rust
#[wasm_bindgen] pub struct SyncState(pub(crate) am::sync::State);   // :13
```
| js_name | Rust | path:line |
|---|---|---|
| `get sharedHeads` | `fn shared_heads(&self) -> JsValue` | :17 |
| `get lastSentHeads` | `fn last_sent_heads(&self) -> JsValue` | :23 |
| `set lastSentHeads` | `fn set_last_sent_heads(&mut self, heads) -> Result<(), interop::error::BadChangeHashes>` | :29 |
| `set sentHashes` | `fn set_sent_hashes(&mut self, hashes) -> Result<(), JsValue>` | :38 |
| `get readOnly` | `fn read_only(&self) -> bool` | :50 |
| `set readOnly` | `fn set_read_only(&mut self, read_only: bool)` | :54 |
| `get peerReadOnly` | `fn peer_read_only(&self) -> bool` | :59 |
| `clone` | `fn clone(&self) -> Self` | :63 |

Plus `pub(crate) fn decode(data: Uint8Array) -> Result<SyncState, DecodeSyncStateErr>` (`:67`, not exported) and `pub struct DecodeSyncStateErr(#[from] automerge::sync::DecodeStateError)` (`:78-80`).

#### B.3 Free functions — `src/lib.rs`

| js_name | Rust signature | path:line |
|---|---|---|
| — (`#[wasm_bindgen(start)]`) | `fn on_start()` | :1876 |
| `create` | `fn init(options: JsValue) -> Result<Automerge, error::BadActorId>` | :1889 |
| `load` | `fn load(data: Uint8Array, options: JsValue) -> Result<Automerge, error::Load>` | :1897 |
| `wasmReleaseInfo` | `fn wasm_release_info() -> JsValue` | :1948 |
| `encodeChange` | `fn encode_change(change: JsValue) -> Result<Uint8Array, error::EncodeChange>` | :1978 |
| `decodeChange` | `fn decode_change(change: Uint8Array) -> Result<JsValue, error::DecodeChange>` | :1989 |
| `initSyncState` | `fn init_sync_state() -> SyncState` | :1997 |
| `importSyncState` | `fn import_sync_state(state: JsValue) -> Result<SyncState, interop::error::BadSyncState>` | :2003 |
| `exportSyncState` | `fn export_sync_state(state: &SyncState) -> JsValue` | :2009 |
| `encodeSyncMessage` | `fn encode_sync_message(message: JsValue) -> Result<Uint8Array, interop::error::BadSyncMessage>` | :2014 |
| `decodeSyncMessage` | `fn decode_sync_message(msg: Uint8Array) -> Result<JsValue, error::BadSyncMessage>` | :2020 |
| `encodeSyncState` | `fn encode_sync_state(state: &SyncState) -> Uint8Array` | :2052 |
| `decodeSyncState` | `fn decode_sync_state(data: Uint8Array) -> Result<SyncState, sync::DecodeSyncStateErr>` | :2057 |
| `readBundle` | `fn read_bundle(bundle: Uint8Array) -> Result<JsValue, error::ReadBundle>` | :2281 |

#### B.4 Feature gates in this crate

`Cargo.toml:29-31`: `[features] default = []` with `wee_alloc` commented out. `Cargo.toml:35`: `automerge = { path = "../automerge", features = ["wasm", "utf16-indexing"] }` — hard-coded, not selectable. `Cargo.toml:48-50`: `wasm-bindgen = "= 0.2.127"` exact pin, features `["serde-serialize","std"]`. `package.json:29-30` has `debug`/`dev` profiles that force `PROFILE=dev TARGET_DIR=debug`.

#### B.5 The TypeScript custom section

`src/lib.rs:60-443` is a single `#[wasm_bindgen(typescript_custom_section)] const TS` string containing ~50 type aliases, 8 patch types, an `interface Automerge` declaration-merge block (`:263-330`) supplying the optional-parameter signatures that `#[wasm_bindgen]` cannot express, and free-function/`API` declarations. It is copied verbatim into the generated `index.d.ts` (`package.json` `buildall` script). **The generated `.d.ts` is a merge of codegen output and this hand-written string; neither is complete alone.**

#### B.6 `pub mod error` — 46 error types (`src/lib.rs:2311-3048`)

`Anonymize`(2322), `BadActorId`(2336), `BadAuthor`(2343), `ApplyChangesError`(2352), `BadFragmentLevelRange`(2367), `Fragments`(2381), `BadJSCommit`(2392), `BadJSCommits`(2414), `BadCommitBytes`(2425), `AddCommits`(2445), `BadJSFragmentInput`(2461), `BadJSFragmentInputs`(2494), `BadJSFragments`(2511), `AddFragments`(2529), `Fork`(2545), `Merge`(2567), `Get`(2576), `Splice`(2601), `UpdateText`(2621), `UpdateSpans`(2642), `Insert`(2670), `Block`(2693), `InsertObject`(2715), `BatchCreateObject`(2738), `InitFromHydrate`(2760), `SpliceHydrate`(2782), `Increment`(2803), `BadSyncMessage`(2822), `ApplyPatch`(2833), `PopPatches`(2852), `Diff`(2860), `Isolate`(2884), `Materialize`(2895), `Cursor`(2906), `ReceiveSyncMessage`(2930), `Load`(2941), `EncodeChange`(2955), `DecodeChange`(2962), `Mark`(2976), `SplitBlock`(3002), `UpdateBlock`(3019), `GetBlock`(3036). Each has a hand-written `impl From<X> for JsValue` producing a `js_sys::RangeError`.

#### B.7 Non-exported internals

`src/value.rs:6-21` `pub(crate) enum Datatype { Map, Table, List, Text, Bytes, Str, Int, Uint, F64, Counter, Timestamp, Boolean, Null, Unknown(u8) }`; `InvalidDatatype` (`:167-177`).
`src/interop.rs`: `pub(crate) struct JS(JsValue)` (`:27`), `pub(crate) struct AR(Array)` (`:28`), ~40 `TryFrom`/`From` impls (`:91-715`), free functions `import_span`(:717), `import_update_spans_args`(:788), `import_update_spans_config`(:805), `to_js_err`(:846), `js_get`(:850), `js_set`(:863), `to_prop`(:873), `import_obj`(:937), `get_heads`(:995), `import_scalar`(:1124), `alloc`(:1622), `alloc_scalar`(:1638), `export_just_path`(:1677), `export_spans`(:1685), `export_span`(:1693), `export_patches`(:1754); `JsObjType`(:884), `SubValIter`(:917), `ExternalTypeConstructor`(:1013); `Automerge::export_value`(:1167), `Automerge::import`(:1518), `Automerge::import_prop`(:1587), `Automerge::import_value`(:1597).
`src/sequence_tree.rs:472` `pub struct Iter<'a, T>` — a local sequence-tree reimplementation plus proptests; not bound to wasm.
`src/export_cache.rs` — `ExportCache` only, no public items.

#### B.8 wasm build pipeline

`scripts/compile.mjs:16-46` runs `cargo build --target wasm32-unknown-unknown -Zbuild-std=std,panic_unwind` with `RUSTFLAGS` appending `-C panic=unwind -C llvm-args=-wasm-use-legacy-eh`; requires nightly + `rust-src`; `WASM_CARGO` overrides the `cargo +nightly` invocation for Nix. `package.json` `bindgen`: `wasm-bindgen --omit-default-module-path --weak-refs --typescript --target $TARGET`. Targets built: `nodejs`, `bundler`, `deno`, `web` (`package.json` `buildall`). `fixup-node-cjs.mjs:3-4` renames `nodejs/automerge_wasm.js` -> `.cjs` and copies the `.d.ts` -> `.d.cts`.

### C. `@automerge/automerge` — the JavaScript package

#### C.1 Layout and export map

`package.json:34-88`. Six subpath conditions, all resolving to bundles under `dist/`:

```jsonc
"exports": {
  ".": {
    "types": "./dist/index.d.ts",
    "workerd": { "import": "./dist/mjs/entrypoints/fullfat_workerd.js", "require": "./dist/cjs/fullfat_base64.cjs" },
    "node":    { "import": "./dist/mjs/entrypoints/fullfat_node.js",    "require": "./dist/cjs/fullfat_node.cjs" },
    "webpack": { "import": "./dist/mjs/entrypoints/fullfat_base64.js", "require": "./dist/cjs/fullfat_base64.cjs" },
    "browser": { "import": "./dist/mjs/entrypoints/fullfat_bundler.js", "require": "./dist/cjs/fullfat_base64.cjs" },
    "import": "./dist/mjs/entrypoints/fullfat_base64.js",
    "require": "./dist/cjs/fullfat_base64.cjs"
  },
  "./slim": { ... "./dist/mjs/entrypoints/slim.js" ... },
  "./automerge.wasm": "./dist/automerge.wasm",
  "./automerge.wasm.base64": { ... }
}
```
`"type": "module"` (`:34`), `main = ./dist/cjs/fullfat_node.cjs`, `module = ./dist/mjs/entrypoints/fullfat_base64.js`, `types = ./dist/index.d.ts`.

Entrypoints (`src/entrypoints/`), each `UseApi(<wasm module>)` then `export * from "../index.js"`:
- `slim.ts` — **does not** call `UseApi`; the caller must call `initializeWasm` first (`src/low_level.ts:104-124`).
- `fullfat_base64.ts` -> `wasm_bindgen_output/web/index.js`
- `fullfat_bundler.ts` -> `wasm_bindgen_output/bundler/automerge_wasm.js`
- `fullfat_node.ts` -> `wasm_bindgen_output/nodejs/automerge_wasm.cjs`
- `fullfat_workerd.ts` -> `wasm_bindgen_output/workerd/automerge_wasm.js` + `api.initSync({ module: wasm })`
- `iife.ts` -> assigns `window.Automerge`, no re-export.

`src/index.ts:205-206` is the whole runtime surface: `export * from "./implementation.js"` and `export * as next from "./implementation.js"`. The rest of the 7.5 KB file is TSDoc.

#### C.2 Public API — `src/implementation.ts` (2093 lines)

**Values exported** (re-exported from `types.ts`/`counter.ts`/`numbers.ts`/`immutable_string.ts`, `src/implementation.ts:26-50`): `AutomergeValue`, `Cursor`, `Counter` (class), `Doc`, `Int`, `Uint`, `Float64`, `Mark`, `MarkSet`, `MarkRange`, `MarkValue`, `MoveCursor`, `Patch`, `PatchCallback`, `ScalarValue`, `PatchInfo`, `PatchSource`, `ImmutableString` (class, `:99`), `isImmutableString` (`:8`), `isCounter` (`:9`).
**Types re-exported from the wasm `.d.ts`** (`:71-82`): `ChangeMetadata`, `FragmentMeta`, `Commit`, `Fragment`, `FragmentLevelRange`, `PutPatch`, `DelPatch`, `DiffOptions`, `SpliceTextPatch`, `InsertPatch`, `IncPatch`, `Span`, `SyncMessage`, `UpdateSpansConfig`.
**Types declared locally**: `ChangeOptions<T>`(:129), `ApplyOptions<T>`(:144), `List<T>`(:149), `ChangeFn<T>`(:189), `State<T>`(:192), `InitOptions<T>`(:206), `ChangeAtResult<T>`(:503), `JsReleaseInfo`(:1486), `WasmReleaseInfo`(:1490), `ReleaseInfo`(:1497), `Conflicts`(`conflicts.ts:6`), `JsSyncState`/`SyncState`(:87-91).
**Functions** (`src/implementation.ts`, `path:line`):
`insertAt`160, `deleteAt`174, `use`198, `getBackend`223, `getChangesSince`235, `getChangesMetaSince`240, `init`273, `view`308, `clone`333, `anonymize`365, `free`398, `from`418, `change`483, `changeAt`577, `emptyChange`709, `load`754, `loadIncremental`801, `saveIncremental`839, `save`859, `merge`878, `getActorId`896, `getAuthor`901, `getAuthors`906, `getAuthorForActor`911, `getActorsForAuthor`916, `getConflicts`977, `getLastLocalChange`998, `getObjectId`1010, `getChanges`1029, `getAllChanges`1041, `applyChanges`1057, `getHistory`1088, `diff`1106, `diffPath`1131, `equals`1166, `encodeSyncState`1183, `decodeSyncState`1195, `generateSyncMessage`1213, `receiveSyncMessage`1245, `hasOurChanges`1289, `initSyncState`1307, `encodeChange`1319, `decodeChange`1324, `encodeSyncMessage`1329, `decodeSyncMessage`1334, `getMissingDeps`1341, `getHeads`1349, `dump`1355, `toJS`1361, `isAutomerge`1369, `saveSince`1381, `hasHeads`1390, `topoHistoryTraversal`1440, `inspectChange`1452, `stats`1463, `releaseInfo`1511, `splice`1542, `updateText`1584, `spans`1609, `block`1623, `splitBlock`1639, `joinBlock`1664, `updateBlock`1688, `updateSpans`1726, `getCursor`1780, `getCursorPosition`1805, `mark`1820, `unmark`1840, `marks`1859, `marksAt`1870, `isRawString`1897, `RawString`1901, `saveBundle`1910, `getFragmentMetadata`1927, `getFragmentMeta`1942, `bundleFragmentMetadata`1958, `getCommits`1973, `getFragments`1992, `addCommits`2017, `addFragments`2055, `readBundle`2088, `applyPatch`/`applyPatches` (re-exported from `apply_patches.ts`, `src/implementation.ts:112`).

**`Text` does not exist in this package.** The only occurrences of `new automerge.Text(...)` are in TSDoc examples in `src/index.ts:25,34,42,46` and are stale — text values are plain JS strings now (`proxies.ts` `case "text": return context.text(...)`, `proxies.ts:105`).

**Hidden metadata symbols** (`src/constants.ts:3-16`), all `Symbol.for(...)` so they survive duplicate module loads:
`STATE="_am_meta"`, `TRACE="_am_trace"`, `OBJECT_ID="_am_objectId"`, `IS_PROXY="_am_isProxy"`, `CLEAR_CACHE="_am_clearCache"`, `UINT="_am_uint"`, `INT="_am_int"`, `F64="_am_f64"`, `COUNTER="_am_counter"`, `TEXT="_am_text"`, `IMMUTABLE_STRING="_am_immutableString"`.

**Wrapper classes**: `Counter` (`counter.ts:9`, plus non-exported `WriteableCounter` and `getWriteableCounter` at `:110`), `ImmutableString` (`immutable_string.ts:3`), `Int`/`Uint`/`Float64` (`numbers.ts:5,22,39`) — each tagged with a symbol and `Object.freeze`d.

**Proxies** (`src/proxies.ts`): `validateForBatchInsert`(:11), `mapProxy`(:470), `listProxy`(:488), `rootProxy`(:506), `isImmutableString`(:909), `isCounter`(:921).

**Plugin point** (`src/low_level.ts:33-40`): `UseApi(api)` copies every key of `api` onto `ApiHandler` and flips `_initialized`. `ApiHandler` (`:47-83`) is a stub object whose every method throws `RangeError("Automerge.use() not called")` — the entire JS package is backend-swappable at runtime.

#### C.3 Build

`scripts/build.mjs` steps: `all | build-wasm | build-wasm-tarball | compile-typescript | transpile-cjs` (`:64-69`, `:100-112`). `buildWasm` (`:114-143`) invokes the same nightly `cargo build -Zbuild-std=std,panic_unwind` with `-C panic=unwind -C llvm-args=-wasm-use-legacy-eh` and injects `GIT_HEAD` at compile time. `config/{mjs,cjs,declonly}.json` are esbuild `tsconfig` overlays. `packaging_tests/run.mjs` (13.4 KB) drives 14 bundler fixtures (webpack esm/cjs x slim/fullfat, vite x3, workerd x2, node esm/cjs x2, iife).

### D. `automerge` CLI

Binary name `automerge`, `path = "src/main.rs"` (`Cargo.toml:12-15`). clap 4 derive.

Subcommands (`src/main.rs:79-152`):

| Command | Args | path:line |
|---|---|---|
| `export` | `-f/--format <json\|toml>` (default json), `[changes_file]`, `-o/--out <file>`, `--skip-verifying-heads <boolish>` | :81-101 |
| `import` | `-f/--format <json\|toml>` (default json), `[input_file]`, `-o/--out <changes_file>` | :103-115 |
| `examine` | `[input_file]`, `--skip-verifying-heads` | :117-127 |
| `examine-sync` | `[input_file]` | :129-132 |
| `anonymize` | `[input_file]`, `-o/--out` | :134-145 |
| `merge` | `-o/--out`, `<input>...` (variadic `Vec<PathBuf>`, empty = stdin) | :147-159 |

`ExportFormat` is both `clap::ValueEnum` (`:26-30`) and `FromStr` (`:67-76`). `VerifyFlag(bool)` is a `clap::ValueParserFactory`/`TypedValueParser` wrapping `BoolishValueParser` (`:32-64`); `--skip-verifying-heads` is `ArgAction::SetFalse`, so its *value* is "verify or not" — i.e. passing `--skip-verifying-heads=false` verifies. `VerifyFlag::load` picks `Automerge::load` vs `load_unverified_heads` (`:36-42`).

Handlers: `export::export_json` (`src/export.rs:13`), `import::import_json` (`src/import.rs:97`), `examine::examine` (`src/examine.rs:25`), `examine_sync::examine_sync` (`src/examine_sync.rs:19`), `anonymize::anonymize` (`src/anonymize.rs:11`), `merge::merge` (`src/merge.rs:34`). Helper `open_file_or_stdin` (`:154`) errors when stdin is a TTY; `create_file_or_stdout` (`:165`) errors when stdout is a TTY.

`--format toml` hits `unimplemented!()` in both `export` (`src/main.rs:186`, `:196`) and `import` (`:206`) — a panic, not a graceful error.

`src/change.rs` (8.3 KB) is **not** in the `mod` list (`src/main.rs:15-22`) and is unreachable dead code.

### E. `interop/`

Two files. `README.md` specifies one 406-byte binary Automerge document (`exemplar`) and, in prose, its expected interpretation: a title string, a `notes` Text object, an ISO-8601 `timestamp`, a `location` URL, `counter: 5`, `int: -4`, `uint: 18446744073709551615`, `fp: 3.14159267`, `bytes: 0x856f4a83`, `bool: true` (`interop/README.md:5-17`). It shows the expected `automerge export exemplar` JSON, in which `timestamp` renders as `-905182979000` — an integer, not the ISO-8601 string the prose describes (`:19-33`).

**`interop/` contains no test vectors, no fixtures, and no harness.** `exemplar` is binary and is referenced by no code in the repo (no test, no build script, no CI job reads `interop/`). It is a documentation artifact. [INFERENCE]

### F. Nix flake and CI scripts

Inputs (`flake.nix:3-17`): `nixpkgs` (nixos-26.05), `nixpkgs-node18` (nixos-23.11), `nixos-unstable` (unstable-small), `command-utils`, `flake-utils`, `rust-overlay` (follows nixpkgs).

Toolchain pins: `rust-rust-toolchain.toml`-derived stable (`:50-67`); pinned nightly `2026-04-25` for wasm (`:70-73`); `wasm-cargo` wrapper (`:77-82`); `wasm-bindgen-cli` built from source at `0.2.127` (`:86-98`). Node matrix: `nodejs_26` default, `nodejs_24` for CI, `nodejs_18` (insecure-allowed) for the Node 18 packaging test, `nodejs_20` for release (`:41-47`).

**Outputs — only three, and none of them is a library/derivation:**
- `devShells.default` (`:445-495`): name `automerge`; nativeBuildInputs = nightly rustfmt (hiPrio), cargo-criterion/deny/edit/flamegraph/fuzz/watch, `rust-toolchain`, `wasm-cargo`, unstable `irust`/`binaryen`/`wasm-pack`/`deno`, chromedriver, chromium, `nodejs`, cmake, cmocka, doxygen, direnv, nixpkgs-fmt, gnuplot, openssl, plus `command_menu`, `format-pkgs` (nixpkgs-fmt, alejandra, taplo), `cargo-installs` (criterion, cargo-deny, cargo-expand, nextest, outdated, sort, udeps, watch, twiggy, wasm-bindgen-cli, wasm-tools), and `darwin-installs` (Security, CoreFoundation, Foundation). Env: `WASM_CARGO="wasm-cargo"`, `PUPPETEER_SKIP_DOWNLOAD="1"`, `PUPPETEER_EXECUTABLE_PATH`. `shellHook = "menu"`.
- `packages` = `ci-packages` (`:451`): 12 shell scripts — `ci`, `ci-build-test`, `ci-cargo-deny`, `ci-fmt`, `ci-js-tests`, `ci-lint`, `ci-node18-packaging-test`, `ci-rust-docs`, `ci-wasm-tests`, `release-js-build`, `release-js-docs`, `release-js-publish`. `ci` is `ci-linux` on Linux, `ci-host` elsewhere (`:421-426`).
- `apps` (`:453-458`): the same 12, each `program = "${package}/bin/${name}"`.
- `formatter` = `alejandra` (`:461`).

Command menu (available as bare commands in the devshell, `flake.nix:136-283`): `release:host`, `release:wasm:web`, `release:wasm:nodejs`, `build:host`, `build:wasm:web`, `build:wasm:nodejs`, `build:node`, `build:deno`, `build:wasi`, `bench`, `bench:host:open`, `lint`, `lint:pedantic`, `lint:fix`, `watch:build:host`, `watch:build:wasm`, `watch:lint`, `watch:lint:pedantic`, `watch:test:host`, `watch:test:wasm`, `test:all`, `test:host`, `test:wasm`, `test:wasm:node`, `test:wasm:chrome`, `test:docs`, `docs:build:host`, `docs:build:wasm`, `docs:open:host`, `docs:open:wasm`.

`mk-ci-command` (`:303-319`) wraps each in `writeShellApplication` that resolves the repo root via `git rev-parse --show-toplevel` and, on Darwin, injects `NIX_LDFLAGS`/`LIBRARY_PATH` for `libiconv` because `writeShellApplication` does not apply the stdenv setup hooks.

`scripts/ci/` (12 shell scripts, all `set -eoux pipefail`, all self-locating via `dirname $0`): `fmt` (69 B), `fmt_js` (339 B), `lint` (468 B), `build-test` (`cargo test` for `automerge`, `automerge-test`, `automerge-c`, `automerge-cli`, `automerge-wasm`), `rust-docs`, `advisory` (`cargo deny`), `wasm_tests`, `js_tests`, `node_18_packaging_test`, `cmake-build <BUILD_TYPE> [shared|static]`, `c-docs` (doxygen target `automerge_docs`), `run` (285 B).

**automerge-c is not in CI.** `.github/workflows/ci.yaml` invokes only `ci-fmt`, `ci-lint`, `ci-rust-docs`, `ci-cargo-deny`, `ci-build-test`, `ci-wasm-tests`, `ci-js-tests`, `ci-node18-packaging-test`, `ci-build-test` on Linux and macOS, and a native Windows job. Neither `ci-cmake-build` nor `ci-c-docs` exists as a flake package (`flake.nix:427-441`) and no workflow job runs them. `scripts/ci/cmake-build` and `scripts/ci/c-docs` are therefore **dead scripts** in this checkout.

## Semantics

### S.1 automerge-c

**One destructor.** `AMresultFree` is the only function that deallocates anything (`src/result.rs:557-562`: `*Box::from_raw(result)` then `drop`). Every other returned `*mut T` is obtained by `Box::into_raw` inside `to_result` (`src/result.rs:490-492`) and every sub-handle (`*mut AMdoc`, `*const AMobjId`, `*const AMchange`, `*const AMcursor`, `*const AMmark`, `*const AMsyncHave`, `*const AMsyncMessage`, `*mut AMsyncState`) is a **borrowed pointer into the `AMresult` that owns it**. There is no `AMdocFree`, no `AMitemFree`, no `AMobjIdFree`. Consequence: freeing the owning `AMresult` invalidates every sub-handle and every `AMbyteSpan` obtained from it. This is stated in the header docs (`src/byte_span.rs:24-29`: "`src` will be freed when the pointer to the `AMresult` struct containing the `AMitem` struct is passed to `AMresultFree()`") and in the README.

**The `AMresult` discriminant is two-variant, not an error code per call.** `enum AMresult { Items(Vec<AMitem>), Error(String) }` (`src/result.rs:11-14`). `AMstatus` is derived from it: `Error(_)` -> `AM_STATUS_ERROR`, anything else -> `AM_STATUS_OK`, and a **null pointer** -> `AM_STATUS_INVALID_RESULT` (`src/result.rs:639-652`). So `AM_STATUS_INVALID_RESULT` means "you passed `NULL`", not "the value had the wrong type".

**The type check is deferred to `AMitemValType`.** Every fallible call returns a result whose items must be type-checked by the caller; the wrapper library encodes the expected tag in `AMstackCallbackData.bitmask` and compares with `==`, not a bitmask AND (`examples/quickstart.c:110-115`: `if (tag != sc_data->bitmask)`), despite the field being documented as "a bitmask". A call that legitimately returns a multi-type result cannot use `AMexpect`.

**`AMitemValType` is stable within one result only.** For a `get_all`/`get_all_at` result, items may have different `AMitemValType` tags; `AMitemIdxType` likewise. Nothing enforces homogeneity at the C level.

**`AMresultCat` allocates a new result and leaves the inputs alive** (`src/result.rs:504-520`). It returns an *error* result (not `NULL`) if either input is an error or either pointer is `NULL`. `AMresultFrom(count, ...)` (variadic, `src/utils/result.c:5-31`) instead **frees every argument** and returns `NULL` on failure — the two concatenation helpers have opposite ownership contracts, and the header says so explicitly (`include/automerge-c/utils/result.h:19-21`).

**`AMitems` is a copied, mutating cursor with an erased lifetime.** `AMitems` is returned **by value** (`AMresultItems` returns `AMitems` on the stack, `src/result.rs:597`) and holds `{len, offset, ptr}` (`src/items.rs:11-15`, `:104-106`) with a `PhantomData<&'a mut AMresult>` that cbindgen erases. The `unsafe` doc on the struct says "Modifying `detail` will cause undefined behavior" (`src/items.rs:108-109`). Copying an `AMitems` gives two independently-advancing cursors over the same buffer (see `AMitemsEqual`, which compares the *underlying* sequences, not the cursors: `src/items.rs:288-293` compares `items1.as_ref() == items2.as_ref()` which is `[AMitem]` equality via `AsRef<[AMitem]>`, `src/items.rs:181-186`). Forward iteration clamps `offset` to `[0, len]`; reverse iteration clamps to `[-(len+1), -1]` and is signalled by a negative offset (`src/items.rs:36-59`). `is_stopped` is `offset < -len || offset == len` (`src/items.rs:80-83`), so a forward cursor at `len` and a reverse cursor at `-(len+1)` are both exhausted, and an **empty** range (`len == 0`) has `offset == 0` both forward and stopped — `AMitemsNext` on an empty result returns `NULL` immediately.

**`AMitemsNext(n)` / `AMitemsPrev(n)` are get-then-advance vs advance-then-get.** `Detail::next` returns the item at the current index and *then* advances (`src/items.rs:69-78`); `Detail::prev` advances *first* and then returns (`src/items.rs:85-93`). With `n == 1` this is a standard iterator. With `n == 0`, `next` returns the current item without moving; `prev(0)` calls `advance(0)` (a no-op, `src/items.rs:36-38`) and returns the current item — so `prev(0)` is equivalent to `next(0)`, not to a peek-before-advance. With `|n| > 1` the two functions return *different* items at the same starting cursor. [INFERENCE — derived from the code paths, not exercised by the tests read.]

**`AM_ROOT` is `NULL`, and a `NULL` obj_id means root, not "invalid".** `to_obj_id!` maps `None` to `&automerge::ROOT` (`src/obj.rs:8-14`). This is distinct from `to_doc!`, which maps `None` to an **error result** `"Invalid \`AMdoc*\`"` (`src/doc/utils.rs:14-21`). So a `NULL` doc is an error and a `NULL` obj_id is the root.

**`heads` parameters are uniformly optional-but-typed.** Every `*const AMitems heads` accepts `NULL` meaning "current state" (`src/doc.rs:246-251`, `:410-420`, etc.). A non-`NULL` `heads` whose items are not `AM_VAL_TYPE_CHANGE_HASH` yields an error result from `Vec::<am::ChangeHash>::try_from(heads)` (`src/items.rs:216-231`).

**`AMsplice` splices from the cursor's *current position*, not from the start.** The header is explicit: "A copy of an `AMitems` struct from which values will be spliced **starting at its current position**; call `AMitemsRewound()` on a used `AMitems` first" (`src/doc.rs:846-849`). The parameter is passed **by value** (`values: AMitems`, `src/doc.rs:877`) so the caller's cursor is not advanced.

**`clamp!` is the pos/length boundary rule for splice and delete.** `pos > len && pos != usize::MAX` is an error `"Invalid pos {n}"`; otherwise `pos = min(pos, len)` (`src/doc/utils.rs:1-7`). `del` is **not** clamped — the caller must satisfy `-len <= del <= len` (`src/doc.rs:857-858`).

**`adjust!` is the list-index rule** (`src/doc/list.rs:20-41`, used by every `AMlist*`): `SIZE_MAX` means "the last item" when `insert == false` and "one past the end" when `insert == true`; an out-of-range `pos` is an error.

**Text indexing unit is a build-time choice, and it is not uniform with the wasm binding.** Default is `-F automerge/utf8-indexing` -> byte offsets (`CMakeLists.txt:110`); `-DUTF32_INDEXING=true` -> code points (`CMakeLists.txt:108`); the choice is surfaced as `AUTOMERGE_C_UTF8` / `AUTOMERGE_C_UTF32` in `config.h` and documented on `AMobjSize`, `AMgetCursorPosition`, `AMspliceText` (`src/doc.rs:686-694`, `:446-451`, `:882-890`). The wasm binding hard-codes `TextEncoding::Utf16CodeUnit` (`src/lib.rs:456`). **A document indexed as UTF-16 by JS and then read through the C API at UTF-8 offsets gives different `AMobjSize` for the same object.** No test in the repo crosses the two.

**`AMitems` embedded in a result may be shared, and three accessors require uniqueness.** `AMitem` is `Rc<Item>` (`src/item.rs:1023-1024`). `AMitemToChange`, `AMitemToDoc` and `AMitemToSyncState` take `*mut AMitem` and use `Rc::get_mut`, returning `false` (not an error) when the refcount is > 1 (`src/item.rs:1189-1196`, `:1210-1218`, `:1234-1242`). `AMitemRefCount` exposes the count (`src/item.rs:1670-1673`). This is the mechanism behind the Rust-side note that `AMresultItem` hands out a pointer into the *result's own* `Vec`, so two `AMitem` pointers from the same result alias the same `Rc`.

**`AMitemResult` is the escape hatch from collection ownership.** It clones the `Rc` into a fresh one-item `AMresult` (`src/item.rs:1691-1695`), so the originating collection's result can be freed while the extracted item survives. Documented in the README under "Beyond that".

**`AMactorId` and `AMchange` store raw pointers, not values.** `AMactorId { body: *const am::ActorId, hex_str: RefCell<Option<Box<str>>> }` (`src/actor_id.rs:22-26`); `AMchange { body: *mut am::Change, change_hash: RefCell<Option<am::ChangeHash>> }` (`src/change.rs:17-21`). `AMactorId` is therefore **not** `Send`/`Sync`-shaped and, since it is a bare raw pointer into whatever container produced it, aliasing rules are the caller's problem. The lazy `RefCell` caches mean `AMactorIdStr` and `AMchangeHash` return a pointer into a `Box<str>`/`ChangeHash` that lives as long as the containing `AMitem`'s `Rc`. `AMchangeCompress` mutates the change through `*mut` and is the only function that takes `AMchange*` mutably besides nothing else.

**`AMsyncState` and `AMsyncMessage` carry extra side tables that the API never reads.** `AMsyncState { body, their_haves_storage: RefCell<BTreeMap<usize, AMsyncHave>> }` (`src/sync/state.rs:21-24`) and `AMsyncMessage { body, changes_storage, haves_storage }` (`src/sync/message.rs:24-28`) allocate lazily-typed `RefCell` maps that no exported function populates. [INFERENCE — no `#[no_mangle]` in those files writes to `_storage`.]

**`AMsyncStateTheir{Haves,Heads,Needs}` use an out-parameter to express `Option`.** The `has_value` out-param is set to `true` only when the corresponding field on `am::sync::State` is `Some`; otherwise `false` and an **empty** (not `NULL`) result (`src/sync/state.rs:186-201`, `:218-233`, `:250-265`). Passing `NULL` for `has_value` is UB — the code writes through it unconditionally.

**`AMobjIdActorId` memoises into a `RefCell<Option<AMactorId>>` and returns a pointer into it** (`src/obj.rs:41-59`). The returned `AMactorId` is owned by the `AMobjId`, and its `body` raw pointer points at the `am::ActorId` inside the `am::ObjId` inside the same `AMobjId`. `AMobjIdIndex` returns `usize::MAX` and `AMobjIdCounter` returns `u64::MAX` for `NULL` — but for the *root* id they return `0` (`src/obj.rs:107-118`, `:151-163`).

**`AMequal` mutates both documents to compare them.** `AMdoc::is_equal_to` calls `self.document()` on both, which on an `AutoCommit` closes the open transaction and commits pending ops (`src/doc.rs:41-45`). So `AMequal(a, b)` has the side effect of committing both. Same for `AMfork`, `AMgetHeads`, `AMgetChanges`, `AMgetChangesAdded`, `AMsave`, `AMsaveIncremental` — all take `*mut AMdoc` and go through `to_doc_mut!`.

**`AMcommit` / `AMemptyChange` distinguish "nothing to commit" from "a change".** `AMcommit` returns one `AM_VAL_TYPE_CHANGE_HASH` item or one `AM_VAL_TYPE_VOID` item (`src/doc.rs:145-147`, via `From<Result<(), AutomergeError>>` at `src/result.rs:154-160`). `AMemptyChange` **always** returns a `CHANGE_HASH`, and if there were pending ops it emits **two** changes (`src/doc.rs:167-172`).

**`AMmarkCreate` requires a pre-`NULL`-checked `*const AMitem` and `start < end`.** It does `value.as_ref().unwrap()` (`src/doc/mark.rs:250`) — a `NULL` item is an immediate panic (abort under `-C panic=abort`, `CMakeLists.txt:101`), not an error result. The `expand` conversion rejects `AM_MARK_EXPAND_DEFAULT` with an error result (`src/doc/mark.rs:59-76`).

**`AMmapRange` and `AMlistRange` bound-check the range but the map form has four cases.** `AMmapRange` matches on `(begin.is_null(), end.is_null())` (four arms, `src/doc/map.rs:527-...`); a non-null `begin > end` is `"Invalid range [a-b)"`. `AMlistRange` uses `to_range!` (`src/doc/list.rs:17-20` region).

**Byte spans are non-owning and may contain NUL.** `AMbyteSpan` is `{src, count}` with no NUL requirement; `AMstrCmp` compares as UTF-8 (`src/byte_span.rs:216-227`); `AMstrdup` copies and *substitutes* NUL characters (`include/automerge-c/utils/string.h:20-27`). `AMbytes(NULL, n)` normalises `count` to 0 (`src/byte_span.rs:176-181`); `AMstr(NULL)` gives `{NULL, 0}` (`src/byte_span.rs:88-97`).

**Enum `<-> string` round-trip is total but lossy on unknown tags.** `ToString` returns `"???"` for an unrecognised tag (`cmake/enum-string-functions-gen.cmake:63-66`); `FromString` returns `false` for no match (`:85-89`).

### S.2 automerge-wasm

**Every `Result<_, E>` becomes a thrown `RangeError`.** Each of the 46 error types has a hand-written `From<X> for JsValue` (e.g. `src/lib.rs:2326-2330`). The JS-visible error contract is therefore a set of strings, not a discriminant. `wasm-bindgen` also installs a `start` hook (`src/lib.rs:1875-1885`) that registers a console-error hook for hard aborts; recoverable panics surface as `PanicError` only because the build forces `-C panic=unwind` (`scripts/compile.mjs:38-40`).

**`Automerge` is a mutable, non-reentrant handle.** Nearly every method takes `&mut self`, including read-only ones (`getHeads`, `getChanges`, `getActorId` is `&self` but most are `&mut self`). There is no borrow-tracking at the JS layer; the JS wrapper's `InternalState.heads` bookkeeping (`src/internal_state.ts:8-14`) is what enforces "one mutable pointer per document".

**UTF-16 is unconditional.** `AutoCommit::new_with_encoding(TextEncoding::Utf16CodeUnit)` at `:456`; `load_with_options(... .text_encoding(TextEncoding::Utf16CodeUnit))` at `:1929`. `index`, `pos`, `length` are `f64` at the boundary and cast with `as usize` (`:616-617`, `:740`, `:1029` for length) — a negative or fractional JS number becomes a huge `usize` via `as` semantics, not an error. `js_usize` (`:2110-2116`) is used only for fragment levels, and it *does* validate (finite, `>= 0`, `fract() == 0`).

**`heads` is uniformly `Option<[ChangeHash]>` at the boundary.** `get_heads(heads: JsValue) -> Result<Option<Vec<ChangeHash>>, BadChangeHashes>` treats `undefined`/`null` as `None` (`src/interop.rs:995-1011`). Every read method that takes `heads` branches on `Some`/`None` to call `*_at` vs the plain form.

**`splice` is polymorphic on both object type and argument type** (`src/lib.rs:612-657`): a `string` argument against a Text object calls `splice_text`; a `string` against a non-Text object is split into per-character `ScalarValue::Str` inserts; an `Array` argument becomes a list of imported scalars; an empty value set still dispatches List-vs-Text so the UTF-16 path is used.

**`import` resolves an ObjID *or a path*** — `import(&self, id: JsValue) -> Result<(ObjId, am::ObjType), error::ImportObj>` (`src/interop.rs:1518-1521`) accepts a string that is either an ObjID hex or a `/`-separated path. `to_prop` maps JS `string` -> `Prop::Map`, `number` -> `Prop::Seq` (`src/interop.rs:873-881`).

**`putObjectFromHydrate` / `insertObjectFromHydrate` / `spliceFromHydrate` bypass the per-key round-trip** and go through `am::hydrate::Value` + `batch_create_object` / `splice` (`:884-951`). The doc comments state these are "much faster" for large nested objects.

**`registerDatatype` is a plugin registry keyed by `Datatype` string, and un-registering is passing a non-`Function`** (`:1116-1143`): if `dyn_into::<Function>()` fails for either callback, the entry is removed and `Ok(())` is returned. The JS layer uses this for exactly two datatypes: `"counter"` and `"str"` (`src/implementation.ts:1416-1438`).

**`enableFreeze` toggles the JS-object freeze mode** and returns the previous value (`:1103-1113`). `freeze: bool` is copied on `clone` (`:499`) and `fork` (`:497`).

**`isolate` / `integrate` / `update_diff_cursor` / `reset_diff_cursor` are a four-call transaction model** (`:1216`, `:1221`, `:1269`, `:1281`) that the JS layer uses to batch patch production.

**`load` options map 1:1 to core `LoadOptions`** (`:1897-1932`): `unchecked` -> `VerificationMode::DontCheck`, `allowMissingDeps` -> `OnPartialLoad::Ignore`, `convertImmutableStringsToText` -> `StringMigration::ConvertToText`. Each defaults to the strict value.

**`Commit::into_change` re-derives truth from bytes and rejects mismatched JS metadata** (`:2141-2156`): the encoded change's `hash()` must equal the JS `head` and its `deps()` must equal the JS `parents`, else `HeadMismatch`/`ParentsMismatch`. The comment names Subduction as the source of the `addCommits` shape.

**Sync messages carry a version tag and optional capabilities.** `decodeSyncMessage` emits `type: "v1"|"v2"` from `MessageVersion` and `supportedCapabilities` from `msg.flags` when present (`:2030-2046`); `MessageFlags` conversion is in `src/interop.rs:642-656`.

**`SyncState` exposes a lossy JS mirror.** `exportSyncState` (`JS::from(am::sync::State)`, `src/interop.rs:91-131`) round-trips through `JsSyncState`, whose TS declaration at `src/lib.rs:392-400` has a **typo** (`theirHeed`, not `theirNeeds`) and omits `theirHaves`' `lastSync` shape. `set_sent_hashes` deserializes a JS `HashMap<ChangeHash, bool>` and keeps only the keys (`src/sync.rs:38-48`).

**`getFragmentMetadata` accepts a number, a `{start,end}` object, or null/undefined**, and `undefined`/`null` means "all levels" (`:2081-2108`); a bare number `n` means the single level `[n, n+1)`.

### S.3 JavaScript layer

**`ApiHandler` is a global mutable singleton replaced by `UseApi`** (`src/low_level.ts:33-40`, `:47-83`). `use(api)` (`src/implementation.ts:198`) is the exported entry point. Every other function calls `ApiHandler.<method>`, so a second copy of the package can install a different backend. Two entrypoints (`slim`, and any use before init) leave the stub in place, and the stubs `throw new RangeError`.

**Documents are `Proxy` objects carrying hidden state.** `MapHandler`/`ListHandler` (from `src/proxies.ts:250+`) intercept `get`/`set`/`has`/`ownKeys`/`deleteProperty`, route reads through `context.getWithType(objectId, prop)`, cache per-`Prop` in a `Map` on the proxy target, and clear the cache on every `set` (`src/proxies.ts:~250-300`). `Symbol.for` keys (`src/constants.ts`) are the only channel between the proxy and the `InternalState`.

**Mutation outside a change callback throws `RangeError`.** `insertAt`/`deleteAt` check `_is_proxy(list)` and throw `"object cannot be modified outside of a change block"` (`src/implementation.ts:161-163`, `:175-177`); `updateText` does the same (`:1586-1588`); `anonymize` throws `"Calls to Automerge.anonymize cannot be nested"` (`:367-369`); `Counter::increment` outside a change throws `"Counters should not be incremented outside of a change callback"` (`counter.ts:60-64`).

**`anonymize` returns `Doc<Record<string, unknown>>`, losing the user's type parameter** (`src/implementation.ts:365`).

**Value import rules are the JS↔wire type contract** (`src/proxies.ts` `import_value`): `bigint > 2^63-1` -> `uint`, else `int`; JS `number` that is an integer -> `int`, else `f64`; plain `string` -> `text` (Text object, not Str); `ImmutableString` -> `str`; `Uint8Array` -> `bytes`; `Date` -> `timestamp` (ms); `Array` -> `list`; plain object -> `map`; `undefined` -> throws; a `Counter`/`Int`/`Uint`/`Float64` instance is detected by its symbol. **A bare JS string becomes a Text object, not a `str` scalar** — the inverse of what most users expect, and a real behavioural difference from the C and Rust APIs where `str` and `text` are distinct put functions.

**`"__proto__"` is rejected on both read-set and write paths** (`src/proxies.ts:36-42` for `validateForBatchInsert`, and in `MapHandler.set`).

**Self-referential assignment is a hard error.** `isSameDocument` compares `val[STATE].handle.__wbg_ptr === context.__wbg_ptr` (`src/proxies.ts`, in `isSameDocument`) and throws `"Cannot create a reference to an existing document object"`. **This depends on the wasm-bindgen-private `__wbg_ptr` field**, with an in-source comment acknowledging "a new version of wasm-bindgen will break this" and relying on tests to catch it. `Date` is exempted as immutable.

**`view(doc, heads)` materializes a snapshot and is a fresh object**, not a live view (`src/implementation.ts:308-330`); the TSDoc in `src/index.ts:70-77` calls it "a cheap reference based copy" and separately notes you must `clone` before mutating a view.

**`saveIncremental` refuses when `state.heads` is set** (i.e. on a viewed doc): `throw new RangeError(...)` (`src/implementation.ts:841-844`); `merge` does the same (`:880-882`).

**`SyncState` in JS is a plain object, not a wasm object.** `type SyncState = JsSyncState & { _opaque: typeof _SyncStateSymbol }` (`src/implementation.ts:87-91`); every call does `importSyncState` -> wasm handle -> use -> `free()` (`:1183-1198`, `:1289-1293`).

**`getConflicts` returns proxies inside a change callback and frozen POJOs outside** (`src/conflicts.ts:30-40` doc, `:42-45` implementation). The result is keyed by **op id** (the second field of `FullValueWithId`), not by a value hash.

**`getObjectId` compares against the literal string `"_root"`** (`src/implementation.ts:1010-1014`, `proxies.ts:508`), and `isAutomerge` does the same (`:1369-1372`) — the root ObjID is a magic string, matching the wasm `materialize("/", ...)` convention.

**`applyPatch`/`applyPatches` operate on plain JS objects and support block-aware path resolution** (`src/apply_patches.ts:25`, `:244`; `resolveEmbeddedBlock` at `:275`, `resolvePath` at `:354`).

### S.4 CLI

**`open_file_or_stdin` / `create_file_or_stdout` are TTY-guarded** (`src/main.rs:154-175`): a missing path argument with a TTY stdin is `"Must provide file path if not providing input via stdin"`; a missing `-o` with a TTY stdout is `"Must provide file path if not piping to stdout"`.

**`anonymize` refuses same-file in/out and is read-only-until-success.** `paths_refer_to_same_file` compares raw paths then canonicalised paths (`:178-180`); the input is fully loaded and anonymized *before* the output file is created (`:243-249`); it prints `"anonymized {n} change(s), {m} operation(s), and {k} actor(s)"` and a warning to stderr (`:251-258`).

**`examine`, `examine-sync` and `merge` print their error and return exit 0.** All three swallow the error into `eprintln!` + `Ok(())` (`:212-222`, `:224-234`, `:255-261`); only `export`, `import` and `anonymize` propagate via `anyhow::Result` from `main`.

**`export` and `import` are lossy round-trips.** `import` maps JSON `String` to a `Str` scalar via `doc.put(obj, key, s)` (not a Text object) (`src/import.rs:40-42`), while `export` renders through `AutoSerde` (`src/export.rs:9-12`). Numbers choose `i64` > `u64` > `f64` in that order (`src/import.rs:44-55`), so the interop exemplar's `int: -4`, `uint: 18446744073709551615` and `fp: 3.14159267` require all three branches. `export` uses `to_string_pretty` when not a TTY and a colour printer when it is (`src/export.rs:22-30`).

**`merge` accumulates incrementally** into one `am::Automerge` via `load_incremental` per path (`src/merge.rs:34-48`) and writes `backend.save()`.

**`examine` decodes every change** to `ExpandedChange` and serializes to JSON (`src/examine.rs:37-46`); `examine-sync` decodes a `sync::Message` (`src/examine_sync.rs:26-30`).

### S.5 interop

The `exemplar` is a fixed input document whose *interpretation* is specified in prose only. There is no executable assertion anywhere in the repo comparing a reader's output to the README's expected JSON. [INFERENCE]

## Zig mapping notes

**`#[no_mangle] pub unsafe extern "C" fn` -> `export fn` + `callconv(.C)`.** Every `*const T` -> `*const T`, `*mut T` -> `*T`, `usize` -> `usize`, `bool` -> `bool` (C `_Bool`, 1 byte), `c_int` -> `c_int`. The `?*const AMdoc` null convention is a real `?*T` in Zig. The `-> bool` "did the out-param get written" pattern becomes `?T` returns or an out-param struct.

**Opaque handles -> `*anyopaque` or a distinct `opaque {}`.** `AMdoc`, `AMactorId`, `AMobjId`, `AMchange`, `AMcursor`, `AMmark`, `AMsyncHave`, `AMsyncMessage`, `AMsyncState`, `AMitem` are all opaque. A Zig port must *add* `pub fn amDocFree(*AMdoc) void` etc. — the Rust ABI has no such functions, and the "borrowed from the result" invariant is enforced only by documentation.

**`enum AMresult { Items(Vec<AMitem>), Error(String) }` -> `union(enum)`.** `pub const AMresult = union(enum) { items: []AMitem, err: []const u8 };` exported by pointer. This is the one Rust type in the C crate that maps *cleanly* to Zig — Zig tagged unions are exactly Rust enums with payloads. `AMresultStatus` becomes a derived function, not a tag.

**`#[repr(C)] enum` with sequential tags -> `enum(c_int)`.** `AMstatus` (`Ok=0, Error, InvalidResult`) and `AMidxType` map directly. **`AMvalType` and `AMmarkExpand` do not** — their discriminants are explicit bit-shifts and out-of-order values. A Zig port MUST pin the exact integers (`AM_VAL_TYPE_VOID = 1<<0` ... `AM_VAL_TYPE_UNKNOWN = 1<<20`; `AM_MARK_EXPAND_NONE = 1` ... `BOTH = 4`) because the C header's numeric values are ABI. `enum(c_int)` with explicit values preserves them.

**`Rc<Item>` inside `AMitem` -> explicit refcount.** `AMitem` is `Rc<Item>` (`src/item.rs:1023`). A Zig port needs `struct { rc: std.atomic.Value(usize), body: *Item }` or a hand-rolled `Rc`. The three `Rc::get_mut` accessors must be reimplemented as "succeed iff `rc.load(.monotonic) == 1`". `std.atomic.Value(usize)` is the direct mapping; there is no `Rc` in the Zig standard library.

**`RefCell<T>` -> raw pointer plus a documented non-reentrancy invariant.** `AMobjId.c_actor_id: RefCell<Option<AMactorId>>` (`src/obj.rs:30-33`), `AMsyncState.their_haves_storage` (`src/sync/state.rs:22`), `AMsyncMessage.changes_storage` (`src/sync/message.rs:26-27`), `AMactorId.hex_str`, `AMchange.change_hash`, `AMcursor.bytes`/`fmt_str`, `AMdoc`'s inner `AutoCommit`. Zig has no `RefCell`; these become `*T` (possibly `?*T`) fields. Each is lazily populated, so the port needs an explicit "is it already built?" flag — the `RefCell<Option<T>>` *is* the flag in Rust.

**`UnsafeCell<Option<AMactorId>>` inside `Value::ActorId` / `Box<am::Change>` inside `Value::Change`** (`src/item.rs:33-44`) — the internal `Value` enum is a heterogeneous, un-`repr(C)` union used only inside `AMitem`. In Zig this is a tagged union with one field per `AMvalType`; a C-facing port should keep it private.

**`AMitems` -> a plain, explicit struct.** The Rust `{detail: [u8; 24], phantom: PhantomData<&'a mut AMresult>}` with "modifying `detail` will cause undefined behavior" is *worse* for a Zig port than the obvious design. Replace with `pub const AMitems = struct { ptr: [*]AMitem, len: usize, offset: isize };` — the `Detail` layout at `src/items.rs:11-15` is exactly that. A Zig port can then make `advance`/`next`/`prev` methods with a `*AMitems` receiver and no lifetime erasure, which removes one whole class of UB. **Recommendation: do not reproduce the opaque-bytes hack.**

**Iterators -> methods, not `Iterator`.** `AMitems` is a random-access cursor, not a Rust `Iterator`: `next(n)` gets-then-advances, `prev(n)` advances-then-gets (`src/items.rs:69-93`). A `Iterator` interface + `next()` cannot express the `n`-step form. Model it as `amItemsNext(items: *AMitems, n: isize) ?*AMitem` and port the `Detail` arithmetic verbatim, including the reversed-encoding-by-negative-offset trick (`:36-59`) and the `is_stopped` bound `offset < -len || offset == len` (`:80-83`).

**`to_result` / `Box::into_raw` -> allocator-generic `create`.** The Rust code uses the global allocator (`Box`). A Zig port should thread an `std.mem.Allocator` through — every `*mut AMresult` returned by the 166 exports is a heap allocation whose matching free is `AMresultFree`, so a single `_ = gpa.create(AMresult)` + `gpa.destroy` pair is the whole story. Making the allocator a parameter is a strict improvement and costs one extra argument on ~90 functions.

**`Result<T, E>` -> error unions.** Straightforward inside Zig. But the C ABI deliberately *erases* `E` into a string (`AMresult::error(&e.to_string())`, `src/result.rs:12-14` and ~35 `From` impls). A Zig C ABI should keep the erase-to-string behaviour for compatibility while retaining the typed error internally.

**`Option<T>` -> `?T`.** Two encoding choices in the C crate worth keeping: (a) a `NULL` `*const AMitems heads` means "current" (`src/doc.rs:246-251`) — `?*const AMitems` in Zig; (b) `AMsyncStateTheirHeads(state, has_value: *bool)` uses an out-param *plus* an empty result rather than an optional item (`src/sync/state.rs:186-201`) — the port should return `?[]const AMitem` and keep the out-param only for C compatibility.

**`HashMap<Datatype, ExternalTypeConstructor>` -> `std.StringHashMap`.** `src/lib.rs:450`; in a Zig port this only exists in the wasm layer, which is out of scope for a native port.

**`unsafe` blocks and their invariants.** Every `extern "C"` fn in the crate is `unsafe`; the invariants are (1) non-null pointers are valid and live, (2) `AMbyteSpan.src` points to at least `count` bytes, (3) borrowed sub-handles outlive neither their `AMresult` nor a reallocation of it, (4) the `*mut` accessors need a uniquely-owned `Rc`. A Zig port should document these as `!` on the function plus a `/// Safety:`-style note; Zig has no `unsafe fn`, so the only enforcement is convention.

**`no_mangle` + `cbindgen` codegen has no Zig equivalent.** The entire header is *generated* by a third-party tool from doc comments, then regex-patched twice (`CMakeLists.txt:141-159`). A Zig port should hand-write `automerge.h` (or generate it with `zig translate-c`, which handles `export fn` + `callconv(.C)` + `extern struct` but **not** the `#[repr(C)] enum` non-sequential tags, and **not** the `union(enum)` `AMresult` layout needed for a stable pointer-only ABI). A hand-written header plus `comptime` layout assertions is the safer route.

### Constructs with no clean Zig equivalent in this slice

1. **`#[wasm_bindgen]` + `JsValue` + `unchecked_param_type`/`unchecked_return_type`/`skip_typescript`** (`src/lib.rs` throughout) — a proc-macro codegen pipeline that emits JS glue, a `.d.ts`, and a set of TypeScript `declare` statements. `zig translate-c`/wasm target does none of this. A Zig wasm binding would need a hand-written JS shim layer plus a hand-written `.d.ts`.
2. **The 380-line `typescript_custom_section` + `interface Automerge` declaration merge** (`src/lib.rs:60-443`). The generated `.d.ts` is incomplete without it; `skip_typescript` methods have *no* generated signature at all. This is a macro that expands into public API with no mechanical equivalent.
3. **`serde` / `serde_wasm_bindgen` derive-driven serialization** of `am::ExpandedChange`, `am::sync::Message`, `FragmentMeta`, `Commit` (`src/lib.rs:1991-1992`, `:2023-2024`, `:2131-2140`). A Zig port must hand-write the JSON writer *and* the reader for the decoded-change shape, and must keep them field-for-field compatible with the JS `DecodedChange` type. The one hand-rolled oddity — `encode_change` uses the deprecated `into_serde` because `serde_wasm_bindgen::from_value` "fails for some inscrutable reason" (`src/lib.rs:1979-1982`) — is a note that the round trip is not self-evidently correct.
4. **`JS::from(am::sync::State)` / `JS(state).try_into()`** (`src/interop.rs:91-131`, `:375-445`) — a 50-line hand-written bidirectional mapping between a Rust struct and a JS POJO, with a `BadSyncState` error. Plus the TS typo `theirHeed` (`src/lib.rs:396`) proving the two sides are kept in sync manually.
5. **`Symbol.for` + `Proxy` + `Reflect`** (`src/constants.ts`, `src/proxies.ts`) — pure JS-runtime object model. No Zig analogue; a native port drops the entire proxy layer and exposes the `wasm` class surface directly.
6. **`__wbg_ptr` identity check** (`src/proxies.ts` `isSameDocument`) — a wasm-bindgen implementation detail used as a public invariant. There is no stable equivalent.
7. **`clap` derive** (`src/main.rs:23-159`): `Parser`, `ValueEnum`, `ValueParserFactory`, `TypedValueParser`, `ArgAction::SetFalse`, `BoolishValueParser`. Zig has no arg-parsing library in std; this is a from-scratch sub-project, and the `--skip-verifying-heads` inverted-flag semantics need to be reproduced by hand.
8. **`Combine` parser** in `automerge-cli` (`Cargo.toml:24`) — a parser-combinator dependency listed for the CLI but not referenced in any of the 9 source files read. [INFERENCE — likely a leftover.]
9. **`#[cfg(test)]` / `dev-dependencies` surface** — `proptest` for `sequence_tree.rs` and `automerge-wasm`, `cmocka` for the C tests, `duct` for the CLI. `wasm-bindgen-test` requires a browser. None of this maps.
10. **`#[wasm_bindgen(start)]`** (`src/lib.rs:1876`) — a module-init hook. Zig wasm has `start` sections but no equivalent ergonomics for registering JS-side error hooks.
11. **`byte: bool` in C.** Zig `bool` is 1 byte and ABI-compatible with C `_Bool`; this one is fine, but note that `bool` in the C crate is returned from functions where the value carries *three* states in some places (`AMchangeIsEmpty(NULL)` -> `true` at `src/change.rs:194-199`; `AMmarkEnd(NULL)` -> `SIZE_MAX` at `src/doc/mark.rs:167-173`). Those sentinel-on-null behaviours must be preserved.

## Risk

**Highest risk: the C ABI's implicit lifetimes.** A Zig port that "cleans this up" by giving every handle a real destructor changes the ABI, and one that copies the `AMresult`-owns-everything rule by hand will leak or dangle in ways that no compile-time check catches. The single-destructor rule is a *documented* invariant (`README.md`, `src/byte_span.rs:24-29`) with **zero runtime enforcement** — `AMresultItem` and `AMresultItems` hand out pointers into the result's own `Vec<AMitem>`, and freeing the result invalidates them. Every claim about this is derived from reading, not from running.

**Unverifiable without running: the `AMitems` get-then-advance vs advance-then-get asymmetry.** `Detail::next` (`:69-78`) and `Detail::prev` (`:85-93`) differ in where `advance` sits. The tests I read (`examples/quickstart.c:48-56`, `rust/automerge-c/test/*.c`) only ever use `AMitemsNext(&changes, 1)`. Whether `AMitemsPrev(&items, 1)` and `AMitemsNext(&items, 1)` on the same cursor return the same item is not demonstrated anywhere I read, and `AMitemsPrev` has no caller in `quickstart.c`. I marked the `n != 1` behaviour `[INFERENCE]`.

**Unverifiable: the empty-`AMitems` case.** `Detail::is_stopped` with `len == 0` is `offset < 0 || offset == 0`, so a fresh forward cursor over an empty result is *already stopped*. `AMresultItems` returns `Default::default()` for an empty result anyway (`src/result.rs:597-604`, `{detail: [0;24]}`), which is indistinguishable from a cursor at `len == 0` over a non-empty result. Both spell "no items", so it is probably benign, but the encoding cannot distinguish them.

**Unverifiable: the `A_M(...)_` -> `AM_..._` header regex fixup.** `CMakeLists.txt:153-155` patches cbindgen's output with a regex derived from one specific mangling. If cbindgen changes its casing rule, the patch silently stops matching and the header gets `A_M_ObjType` instead of `AM_OBJ_TYPE_MAP` with no error. I read the CMake but did not run it, so I cannot confirm the patch currently produces the documented names. **A Zig port must hand-check all 5 enums against these names.**

**Unverifiable: the `USIZE_` -> `+8` patch hardcodes pointer size.** `CMakeLists.txt:157-159` substitutes `${CMAKE_SIZEOF_VOID_P}`, but `Detail` is `{usize, isize, *const c_void}` — 24 bytes on 64-bit, 12 on 32-bit. The header embeds the size at generation time, so a header generated on x86-64 and used on 32-bit is ABI-incompatible. The README warns about exactly this for the whole header (`README.md:56-59`) but the failure is silent, not a compile error.

**The cbindgen post-processing is fragile enough that it may already be wrong.** `derive_const_casts = true` and `must_use = "MUST_USE_ENUM"` (`cbindgen.toml:26-27`) affect whether the `AMvalType` constants appear as usable C expressions. I could not run cbindgen, so the exact form of `AM_VAL_TYPE_BOOL` in the generated header is `[INFERENCE]`.

**`AMsyncState.their_haves_storage` and `AMsyncMessage.changes_storage`/`haves_storage` are dead fields** (`src/sync/state.rs:22`, `src/sync/message.rs:26-27`). No `#[no_mangle]` function in those files writes them. A Zig port that faithfully ports them ports dead weight; a port that omits them might diverge from an internal-but-real invariant. [INFERENCE]

**`AMmarkCreate` panics on a `NULL` value item** (`src/doc/mark.rs:250`, `value.as_ref().unwrap()`), and the release build is compiled with `-C panic=abort` (`CMakeLists.txt:101`) — so that is an immediate process abort, not a catchable failure. The header's `\pre \p value \`!= NULL\`` (`:232`) is the only guard.

**`AMsyncStateTheir*` write through `has_value` without a null check** (`src/sync/state.rs:193`, `:226`, `:258`). The doc says `\pre \p has_value \`!= NULL\``; the code does `*has_value = true` unconditionally. Passing `NULL` is UB with no diagnostic.

**UTF-8 vs UTF-16 indexing is a silent cross-binding hazard.** C defaults to byte offsets (`CMakeLists.txt:110`); wasm hard-codes UTF-16 code units (`src/lib.rs:456`, `:1929`). The same document yields different `AMobjSize`/`AMgetCursorPosition` values depending on which binding produced or read it. **No test in this checkout reads the same document through both.** A Zig port must pick one and document it, or re-implement the `TextEncoding` selection the core crate already has.

**The wasm `f64`-as-index convention is a silent-corruption vector.** `start as usize` (`:616`), `index as usize` (`:740`), `index as f64` for the inverse. A JS caller passing `-1`, `1.5` or `NaN` gets a wrapped/huge index, not a `RangeError`. `js_usize` (`:2110-2116`) exists and validates, but is used only for fragment levels. A Zig port should apply the validating helper everywhere.

**The JS `string` -> Text mapping is easy to get backwards.** `import_value` maps a bare JS `string` to `"text"` (`src/proxies.ts`, `case "string": return [value, "text"]`), so `d.key = "hello"` creates a **Text object**, while the CLI's `import` maps a JSON string to a `Str` scalar (`src/import.rs:40-42`) and the C API has separate `AMmapPutStr` and `AMmapPutObject(AM_OBJ_TYPE_TEXT)`. Three bindings, three behaviours for the same JSON. Any port that unifies them changes observable behaviour.

**The wasm `Automerge` methods are `&mut self` for reads.** 40+ of the 89 methods take `&mut self` even though they are logically reads (`getHeads` `:1512`, `getChanges` `:1361`, `topoHistoryTraversal` `:1824`). A Zig port using a plain `*Automerge` will not reproduce any aliasing check, because there is none to reproduce — the JS layer's `InternalState.heads` bookkeeping is the only thing preventing two mutable views, and it is advisory (`src/internal_state.ts:20-30`).

**The `interop/exemplar` fixture is untested.** Nothing in the repo reads it. It cannot be used as a regression oracle for a port without writing the oracle first.

**The Nix flake pins a future nightly (`2026-04-25`) and a future nixpkgs (`nixos-26.05`)** (`flake.nix:6`, `:70`). The `-Zbuild-std=std,panic_unwind` + `-wasm-use-legacy-eh` combination is required for `PanicError` to reach JS at all (`scripts/compile.mjs:36-40`); a port that drops it turns every recoverable panic into a permanent module abort. This is the single most fragile part of the wasm build and it is invisible from the Rust source.

**`automerge-c` is not exercised by CI** (no flake package, no workflow job — see §F). So none of the C ABI behaviour above is regression-protected by this repository. A Zig C ABI has *more* CI exposure than the Rust one it would replace.
