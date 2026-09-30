# Sync Protocol and Change Exchange

## Scope

All paths below are relative to `rust/automerge/src/`. The sync protocol lives **entirely inside the `automerge` crate** — there is no separate sync crate. `rust/Cargo.toml:1-11` lists the workspace members (`automerge`, `automerge-c`, `benchmark-battery`, `automerge-cli`, `automerge-test`, `automerge-wasm`, `edit-trace`, `hexane`) and none is a sync package. The module is `pub mod sync;` (`lib.rs:288`).

| Path | Lines | Role |
|---|---|---|
| `sync.rs` | 2495 | Trait `SyncDoc`, `Message`, encode/decode, `generate_sync_message`, `receive_sync_message`, tests |
| `sync/state.rs` | 214 | `State`, `Have`, capability predicates, `State::encode`/`decode` |
| `sync/message_builder.rs` | 118 | `MessageBuilder` — v1 vs v2 payload construction |
| `sync/bloom.rs` | 160 | `BloomFilter` (the `have` summariser) |
| `sync/v1_compat_test/mod.rs` | 625 | Frozen copy of the pre-V2 sync implementation + 5 round-trip tests |
| `sync/v1_compat_test/state.rs` | 120 | Frozen copy of the pre-V2 `State`/`Have` |
| `sync/v1_compat_test/bloom.rs` | 162 | Frozen copy of the pre-V2 `BloomFilter` |
| `clock.rs` | 251 | `Clock`, `SeqClock`, `ClockRange` — **not** on the sync path (read-at + change-graph caching) |
| `change_queue.rs` | 177 | `ChangeQueue`, `ChangeBatch` — on the sync path via `missing_deps_from` and `load_incremental_log_patches` |

Read for context, not covered here: `storage/parse.rs` (619 lines), `storage/parse/leb128.rs` (302), `change_graph.rs` (1798), `automerge.rs` (2361), `autocommit.rs` (`SyncWrapper`, 1301-1344), `patches/patch_log.rs`.

---

## Surface

### `sync.rs` — protocol type byte, version, trait

`rust/automerge/src/sync.rs:136-137`

```rust
const MESSAGE_TYPE_SYNC: u8 = 0x42; // first byte of a sync message, for identification
const MESSAGE_TYPE_SYNC_V2: u8 = 0x43; // first byte of a sync message, for identification
```

`rust/automerge/src/sync.rs:139-164`

```rust
#[derive(Clone, Debug, PartialEq)]
pub enum MessageVersion {
    V1,
    V2,
}

impl MessageVersion {
    fn parse(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, ReadMessageError>;
    fn encode(&self) -> u8;
}
```

`rust/automerge/src/sync.rs:97-134` — the public trait:

```rust
pub trait SyncDoc {
    fn generate_sync_message(&self, sync_state: &mut State) -> Option<Message>;

    fn receive_sync_message(
        &mut self,
        sync_state: &mut State,
        message: Message,
    ) -> Result<(), AutomergeError>;

    fn receive_sync_message_log_patches(
        &mut self,
        sync_state: &mut State,
        message: Message,
        patch_log: &mut PatchLog,
    ) -> Result<(), AutomergeError>;
}
```

Implementors: `impl SyncDoc for Automerge` (`sync.rs:166-308`) and the private decorator `SyncWrapper<'a>` in `autocommit.rs:1301-1344`. `AutoCommit::sync(&mut self) -> impl SyncDoc + '_` (`autocommit.rs:778-782`) closes the open transaction and wraps.

`sync.rs:90-92` — re-exports:

```rust
pub use bloom::{BloomFilter, DecodeError as DecodeBloomError};
pub use state::DecodeError as DecodeStateError;
pub use state::{Have, State};
```

`rust/automerge/src/sync.rs:467-476`

```rust
#[derive(Debug, thiserror::Error)]
pub enum ReadMessageError {
    WrongType { expected_one_of: Vec<u8>, found: u8 },
    Parse(String),
    ReadChangeOps(#[from] ReadChangeOpError),
    NotEnoughInput,
}
```

Conversions: `From<parse::leb128::Error>` (`479-482`), `From<bloom::ParseError>` (`485-488`), `From<crate::storage::change::ParseError>` (`491-494`), `From<ReadMessageError> for parse::ParseError<ReadMessageError>` (`497-500`), and the flattening `From<parse::ParseError<ReadMessageError>>` which collapses `Incomplete` to `NotEnoughInput` (`503-510`).

### `sync.rs` — the message type

`rust/automerge/src/sync.rs:528-548`

```rust
#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub heads: Vec<ChangeHash>,
    pub need: Vec<ChangeHash>,
    pub have: Vec<Have>,
    pub changes: ChunkList,
    pub flags: Option<MessageFlags>,
    pub version: MessageVersion,
}
```

`sync.rs:603-614` — hand-written `serde::Serialize`, **4 fields only** (`heads`, `need`, `have`, `changes`); `flags` and `version` are omitted.

`sync.rs:550-600` — `ChunkList`:

```rust
#[derive(Clone, Debug, PartialEq)]
pub struct ChunkList(Vec<Vec<u8>>);          // field is private

impl From<Vec<Vec<u8>>> for ChunkList;
impl From<Vec<u8>> for ChunkList;            // wraps a single chunk

impl ChunkList {
    fn parse(i: parse::Input<'_>) -> parse::ParseResult<'_, Self, ReadMessageError>;
    pub fn empty() -> Self;
    pub fn is_empty(&self) -> bool;
    pub fn len(&self) -> usize;
    pub fn iter(&self) -> impl ExactSizeIterator<Item = &[u8]>;
    pub(crate) fn join(&self) -> Vec<u8>;
}
```

`sync.rs:617-621` — the `have` element parser:

```rust
fn parse_have(input: parse::Input<'_>) -> parse::ParseResult<'_, Have, ReadMessageError>;
```

`sync.rs:624-700` — the encode/decode pair:

```rust
impl Message {
    pub(crate) fn reset(our_heads: Vec<ChangeHash>) -> Message;
    pub fn decode(input: &[u8]) -> Result<Self, ReadMessageError>;
    pub(crate) fn parse(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, ReadMessageError>;
    pub fn encode(self) -> Vec<u8>;
}
```

`sync.rs:741-796` — flags:

```rust
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct MessageFlags(u8);          // tuple field is private

impl MessageFlags {
    pub const SYNC_RESET: u8 = 1 << 0;
    pub const READ_ONLY: u8 = 1 << 1;
    pub const SUPPORTS_SYNC_RESET: u8 = 1 << 2;

    const BITFIELD_MARKER: u8 = 0x80;
    const LEGACY_V2_BYTE: u8 = 0x02;

    pub fn new() -> Self;
    pub fn contains(self, flag: u8) -> bool;
    pub fn set(&mut self, flag: u8);
    fn encode(&self, out: &mut Vec<u8>);
    fn parse_bytes(bytes: &[u8]) -> Self;
}
```

`sync.rs:799-806` — capabilities:

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Capability {
    MessageV1,   // never constructed in live code (only in commented-out proptest blocks, sync.rs:895/897/921/923)
    MessageV2,
    SyncReset,
}
```

`sync.rs:808-825` — free encode helpers:

```rust
fn encode_many<'a, I, It, F>(out: &mut Vec<u8>, data: I, f: F)
where I: Iterator<Item = It> + ExactSizeIterator + 'a, F: Fn(&mut Vec<u8>, It);

fn encode_hashes(buf: &mut Vec<u8>, hashes: &[ChangeHash]);  // debug_assert: input must be sorted
```

`sync.rs:827-850` — `advance_heads(my_old_heads: &HashSet<&ChangeHash>, my_new_heads: &HashSet<ChangeHash>, our_old_shared_heads: &[ChangeHash]) -> Vec<ChangeHash>`.

`sync.rs:309-385` — the two private message-content helpers on `Automerge`:

```rust
fn make_bloom_filter(&self, last_sync: Vec<ChangeHash>) -> Have;
fn get_hashes_to_send(&self, have: &[Have], need: &[ChangeHash]) -> Result<Vec<ChangeHash>, AutomergeError>;
```

`sync.rs:386-465` — the receive path:

```rust
pub(crate) fn receive_sync_message_inner(
    &mut self,
    sync_state: &mut State,
    message: Message,
    patch_log: &mut PatchLog,
) -> Result<(), AutomergeError>;
```

### `sync/state.rs` — the per-peer state

`rust/automerge/src/sync/state.rs:9`

```rust
const SYNC_STATE_TYPE: u8 = 0x43; // first byte of an encoded sync state
```

`rust/automerge/src/sync/state.rs:11-18`

```rust
#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    Parse(String),
    WrongType { expected_one_of: Vec<u8>, found: u8 },
    NotEnoughInput,
}
```

`rust/automerge/src/sync/state.rs:33-81` — **12** public fields:

```rust
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct State {
    pub shared_heads: Vec<ChangeHash>,
    pub last_sent_heads: Vec<ChangeHash>,
    pub their_heads: Option<Vec<ChangeHash>>,
    pub their_need: Option<Vec<ChangeHash>>,
    pub their_have: Option<Vec<Have>>,
    pub sent_hashes: BTreeSet<ChangeHash>,
    pub in_flight: bool,
    pub have_responded: bool,
    pub their_capabilities: Option<Vec<Capability>>,
    pub read_only: bool,
    pub peer_read_only: bool,
    pub needs_reset: bool,
}
```

`rust/automerge/src/sync/state.rs:83-89`

```rust
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, serde::Serialize)]
pub struct Have {
    pub last_sync: Vec<ChangeHash>,
    pub bloom: BloomFilter,
}
```

`rust/automerge/src/sync/state.rs:92-214` — full method set:

```rust
impl State {
    pub fn new() -> Self;                                        // :93
    pub fn new_read_only() -> Self;                              // :101
    pub fn encode(&self) -> Vec<u8>;                             // :108
    pub fn decode(input: &[u8]) -> Result<Self, DecodeError>;    // :114
    pub(crate) fn parse(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, DecodeError>; // :123
    pub fn set_read_only(&mut self, read_only: bool);           // :159
    pub fn is_peer_read_only(&self) -> bool;                    // :187
    pub(crate) fn peer_supports_sync_reset(&self) -> bool;      // :191
    pub(crate) fn send_doc(&self) -> bool;                      // :198
    pub(crate) fn their(&self) -> Option<(&[Have], &[ChangeHash])>; // :202
    pub(crate) fn supports_v2_messages(&self) -> bool;          // :208
}
```

### `sync/message_builder.rs`

`rust/automerge/src/sync/message_builder.rs:9-118` — `pub(super)`, i.e. crate-private to the sync module.

```rust
pub(super) struct MessageBuilder<'a> {
    heads: Vec<ChangeHash>,
    need: Vec<ChangeHash>,
    have: Vec<Have>,
    changes: Vec<Vec<u8>>,
    hashes: Cow<'a, [ChangeHash]>,
    flags: Option<MessageFlags>,
    version: MessageVersion,
}

impl<'a> MessageBuilder<'a> {
    pub(super) fn new(changes: Vec<Change>, sync_state: &State) -> MessageBuilder<'static>;   // :20
    fn new_v1(changes: Vec<Change>) -> MessageBuilder<'static>;                               // :26
    fn new_empty_v2() -> MessageBuilder<'static>;                                             // :43
    fn new_v2_from_changes(changes: Vec<Change>) -> MessageBuilder<'static>;                  // :55
    pub(super) fn new_v2<'b>(data: Vec<u8>, hashes: Cow<'b, [ChangeHash]>) -> MessageBuilder<'b>; // :67
    pub(super) fn is_empty(&self) -> bool;                                                   // :79
    pub(super) fn hashes(&self) -> impl Iterator<Item = &ChangeHash>;                         // :83
    pub(super) fn heads(self, heads: Vec<ChangeHash>) -> Self;                               // :87
    pub(super) fn need(self, need: Vec<ChangeHash>) -> Self;                                 // :92
    pub(super) fn have(self, have: Vec<Have>) -> Self;                                       // :97
    pub(super) fn flags(self, flags: Option<MessageFlags>) -> Self;                          // :102
    pub(super) fn build(self) -> Message;                                                    // :107
}
```

### `sync/bloom.rs`

`rust/automerge/src/sync/bloom.rs:7-160`

```rust
const BITS_PER_ENTRY: u32 = 10;   // ~1% false-positive rate
const NUM_PROBES: u32 = 7;

#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize)]
pub struct BloomFilter {           // :13 — all four fields private
    num_entries: u32,
    num_bits_per_entry: u32,
    num_probes: u32,
    bits: Vec<u8>,
}

impl Default for BloomFilter;                                    // :20

impl BloomFilter {
    pub fn to_bytes(&self) -> Vec<u8>;                           // :38
    pub(crate) fn parse(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, ParseError>; // :48
    fn get_probes(&self, hash: &ChangeHash) -> Vec<u32>;         // :69
    fn add_hash(&mut self, hash: &ChangeHash);                   // :92
    fn set_bit(&mut self, probe: usize);                         // :98
    fn get_bit(&self, probe: usize) -> Option<u8>;               // :104
    pub fn contains_hash(&self, hash: &ChangeHash) -> bool;      // :110
    pub fn from_hashes<H: Borrow<ChangeHash>>(hashes: impl ExactSizeIterator<Item = H>) -> Self; // :125
}

fn bits_capacity(num_entries: u32, num_bits_per_entry: u32) -> usize;   // :143

pub(crate) enum ParseError { Leb128(#[from] parse::leb128::Error) };     // :32
pub struct DecodeError(String);                                           // :150
impl TryFrom<&[u8]> for BloomFilter { type Error = DecodeError; }         // :152
```

### `sync/v1_compat_test/` — the frozen v1 implementation

`rust/automerge/src/sync.rs:87-88`

```rust
#[cfg(test)]
mod v1_compat_test;
```

`v1_compat_test/mod.rs:24` — `const MESSAGE_TYPE_SYNC: u8 = 0x42;` (single byte, no V2).

`v1_compat_test/mod.rs:26-265` — frozen `Automerge` methods (private, `_v1` suffix):

```rust
fn generate_sync_message_v1(&self, sync_state: &mut State) -> Option<Message>;      // :27
fn receive_sync_message_v1(&mut self, sync_state: &mut State, message: Message)
    -> Result<(), AutomergeError>;                                                   // :117
fn make_bloom_filter_v1(&self, last_sync: Vec<ChangeHash>) -> Have;                  // :125
fn get_changes_to_send_v1(&self, have: &[Have], need: &[ChangeHash])
    -> Result<Vec<Change>, AutomergeError>;                                           // :134
fn receive_sync_message_inner_v1(&mut self, sync_state: &mut State, message: Message)
    -> Result<(), AutomergeError>;                                                   // :205
```

`v1_compat_test/mod.rs:267-311` — `enum ReadMessageError` (identical variants, private).

`v1_compat_test/mod.rs:313-422` — frozen `Message`:

```rust
#[derive(Clone, Debug, PartialEq)]
struct Message {                     // :314
    heads: Vec<ChangeHash>,
    need: Vec<ChangeHash>,
    have: Vec<Have>,
    changes: Vec<Change>,            // :321 — typed, already-decoded changes
}

impl Message {
    fn decode(input: &[u8]) -> Result<Self, ReadMessageError>;   // :354
    fn parse(input: parse::Input<'_>) -> parse::ParseResult<'_, Self, ReadMessageError>; // :363
    fn encode(mut self) -> Vec<u8>;                              // :407
}
```

`v1_compat_test/mod.rs:346` — `fn parse_have(...)`; `427-470` — duplicated `encode_many`, `encode_hashes`, `advance_heads`.

`v1_compat_test/state.rs:32-77` — frozen `State`, 8 fields (no `their_capabilities`, `read_only`, `peer_read_only`, `needs_reset`; `DecodeError` is `pub(crate)`), plus `Have` at `40-47` and `impl State` at `49-119` (`new`, `encode`, `decode`, `parse`).

`v1_compat_test/bloom.rs:1-162` — byte-for-byte identical algorithm to `sync/bloom.rs`; only visibility differs (`pub(crate)` vs `pub`) and `from_hashes` is written across four lines (`v1_compat_test/bloom.rs:125-143`).

Five interop tests: `sync_from_v1_to_v2` (`mod.rs:473`), `sync_from_v2_to_v1` (`:496`), `sync_v1_to_v2_with_compressed_change` (`:519`), plus the drivers `sync_v1_to_v2` (`:550`) / `sync_v2_to_v1` (`:591`), both `const MAX_ITER: usize = 10`.

### `clock.rs` — NOT on the sync path

`rust/automerge/src/clock.rs:11-15`

```rust
#[derive(Default, Debug, Clone, PartialEq)]
pub(crate) struct Clock(pub(crate) Vec<u32>);

#[derive(Default, Debug, Clone, PartialEq)]
pub(crate) struct SeqClock(pub(crate) Vec<Option<NonZeroU32>>);
```

`clock.rs:17-72` — `SeqClock::{iter, remove_actor, rewrite_with_new_actor, get_for_actor, new, include, merge, covers}`.
`clock.rs:74-78` — `pub(crate) enum ClockRange { Current(Option<Clock>), Diff(Clock, Clock) }`.
`clock.rs:86-117` — `ClockRange::{current, after, visible_after, visible_before, predates}`.
`clock.rs:119-157` — `Clock::{isolate, covers}`, private `counter_of`/`set_counter_of`, plus `FromIterator<Option<u32>>`.
`clock.rs:165-251` — `#[cfg(test)] mod tests` adds a **second** `impl Clock { new, include, is_greater }` and `impl PartialOrd for Clock` **inside the test module only**. `Clock` has no `Ord`/`PartialOrd` outside tests.

Consumers are the read path and the change graph: `automerge.rs:794, 1230-1246, 1571-1702`, `change_graph.rs:43-46, 457, 643-655, 703-705, 729-740, 793-851`, `iter/*`, `hydrate.rs:232-237`. **`sync.rs` never mentions `Clock`.**

### `change_queue.rs` — on the sync path

`rust/automerge/src/change_queue.rs:5-37`

```rust
#[derive(Debug, Clone)]
pub(crate) struct ChangeBatch {
    changes: Vec<Change>,
    hashes: HashSet<ChangeHash>,
    incoming_actor_seqs: HashSet<(ActorId, u64)>,
}
impl ChangeBatch {
    pub(crate) fn new() -> Self;                                          // :11
    pub(crate) fn push(&mut self, change: Change) -> Result<(), AutomergeError>; // :15
}
```

`change_queue.rs:44-50`

```rust
/// An indexed queue of unapplied changes that are not yet causally ready.
#[derive(Debug, Clone)]
pub(crate) struct ChangeQueue {
    changes: Vec<Change>,
    hashes: HashSet<ChangeHash>,           // O(1) contains
    incoming_actor_seqs: HashSet<(ActorId, u64)>,
}
```

`change_queue.rs:53-176`

```rust
pub(crate) fn new() -> Self;                                                  // :54
pub(crate) fn is_empty(&self) -> bool;                                       // :60
pub(crate) fn iter(&self) -> impl Iterator<Item = &Change>;                  // :64
pub(crate) fn remove_actor_branch_from(&mut self, actor: &ActorId, seq: u64); // :68
pub(crate) fn extend(&mut self, batch: ChangeBatch);                         // :107
pub(crate) fn pop_topo_sorted_ready(&mut self, change_graph: &ChangeGraph) -> Vec<Change>; // :123
```

Sync reaches the queue twice: `generate_sync_message` calls `self.missing_deps_from(...)` (`sync.rs:184`), which walks `self.queue` (`automerge.rs:2037-2062`); and `receive_sync_message_inner` calls `load_incremental_log_patches` (`sync.rs:419`) → `apply_changes_batch_log_patches` (`op_set2/change/batch.rs:1048-1106`), which does `self.queue.extend(incoming)` then `self.queue.pop_topo_sorted_ready(...)` (`batch.rs:1103-1105`).

### `encode_sync_message` / `decode_sync_message`

Not in the core crate; binding-layer only.

- WASM: `encode_sync_message` (`automerge-wasm/src/lib.rs:2013-2017`, `js_name = "encodeSyncMessage"`), `decode_sync_message` (`lib.rs:2019-2049`, `js_name = "decodeSyncMessage"`), both via `am::sync::Message::encode` / `::decode`. `decode` also exports `type` (`"v1"`/`"v2"`) and `supportedCapabilities`.
- C: `automerge-c/src/sync/message.rs:66` (`::decode`) and `:84` (`.encode()`).
- State: `automerge-wasm/src/lib.rs:2051-2059` (`encodeSyncState` / `decodeSyncState`), `automerge-c/src/sync/state.rs:93`.

Core-level: `Message::encode` (`sync.rs:676`), `Message::decode` (`sync.rs:640`), `State::encode` (`state.rs:108`), `State::decode` (`state.rs:114`).

### Feature gates

**None in the sync module.** The only `cfg` is `#[cfg(test)] mod v1_compat_test;` (`sync.rs:87-88`) and `#[cfg(test)] use crate::ReadDoc;` (`sync.rs:74-75`). Crate features (`automerge/Cargo.toml:11-17`: `wasm`, `utf8-indexing`, `utf16-indexing`, `slow_path_assertions`) do not touch sync.

### Supporting types

`rust/automerge/src/types.rs:686`

```rust
pub(crate) const HASH_SIZE: usize = 32; // 256 bits = 32 bytes

#[derive(Eq, PartialEq, Hash, Clone, PartialOrd, Ord, Copy)]
pub struct ChangeHash(pub [u8; HASH_SIZE]);
```

`Ord` is derived from `[u8; 32]` — **lexicographic byte order** (memcmp order). This is what makes `BTreeSet<ChangeHash>` iteration and the `encode_hashes` sortedness requirement work.

`rust/automerge/src/storage/parse.rs:112-118, 347-353, 380-384, 404-417, 423-458, 514-520`

```rust
const HASH_SIZE: usize = 32;
pub(crate) type ParseResult<'a, O, E> = Result<(Input<'a>, O), ParseError<E>>;

#[derive(PartialEq, Clone, Copy)]
pub(crate) struct Input<'a> { bytes: &'a [u8], position: usize, original: &'a [u8] }

pub(crate) enum ParseError<E> { Error(E), Incomplete(Needed) }
pub(crate) enum Needed { Unknown, Size(NonZeroUsize) }

pub(crate) fn take1<E>(input: Input<'_>) -> ParseResult<'_, u8, E>;
pub(crate) fn take_n<E>(n: usize, input: Input<'_>) -> ParseResult<'_, &[u8], E>;
pub(crate) fn length_prefixed<'a, G, O, Er>(g: G) -> impl FnMut(Input<'a>) -> ParseResult<'a, Vec<O>, Er>;
pub(crate) fn length_prefixed_bytes<E>(input: Input<'_>) -> ParseResult<'_, &[u8], E>;
pub(crate) fn change_hash<E>(input: Input<'_>) -> ParseResult<'_, ChangeHash, E>;
```

`Input` is `Copy`; state is threaded as `Ok((remaining_input, value))`. `length_prefixed` reads a LEB128 `u64` count and applies the element parser that many times; the count is **trusted** — a count of `2^63` allocates a `Vec` then fails on the first element.

`rust/automerge/src/storage/parse/leb128.rs:5-11, 13-37, 74-85`

```rust
pub(crate) enum Error { Leb128TooLarge, Leb128Overlong, UnexpectedZero }
pub(crate) fn leb128_u64<E>(input: Input<'_>) -> ParseResult<'_, u64, E>;
pub(crate) fn leb128_i64<E>(input: Input<'_>) -> ParseResult<'_, i64, E>;
pub(crate) fn leb128_u32<E>(input: Input<'_>) -> ParseResult<'_, u32, E>;
pub(crate) fn nonzero_leb128_u64<E>(input: Input<'_>) -> ParseResult<'_, NonZeroU64, E>;
```

`leb128::write::unsigned` in `sync.rs` comes from the **external `leb128 = "^0.2.5"` crate** (`automerge/Cargo.toml:28`), not the in-tree module. It returns `Result<usize, leb128::Error>`; every call site `.unwrap()`s it (`sync.rs:683, 688, 778, 813`).

---

## Byte layouts

### Sync message (`Message::encode`, `sync.rs:676-700`; `Message::parse`, `sync.rs:649-674`)

```
offset  size            field
0       1               version byte: 0x42 (V1) | 0x43 (V2)          [sync.rs:136-137, 160-162]
1       varint(leb128)  nHeads
        32 * nHeads     heads[i]     — raw 32 bytes each, must be sorted ascending
        varint(leb128)  nNeed
        32 * nNeed      need[i]      — raw 32 bytes each, must be sorted ascending
        varint(leb128)  nHave
          per Have:                    [sync.rs:681-685 / 617-621]
            varint     nLastSync
            32*nLastSync  last_sync[i]  — raw 32 bytes, sorted
            varint     nBloomBytes
            nBloomBytes    bloom bytes  (see below)
        varint(leb128)  nChunks
          per chunk:                   [sync.rs:687-690]
            varint     nChunkBytes
            nChunkBytes    raw bytes
        --- optional trailing section, present iff the parser had >=1 byte left here ---
            varint     nFlagBytes      [sync.rs:658-665]
            nFlagBytes  flag bytes      (see below)
```

`leb128` here is unsigned LEB128: 7 payload bits/byte, high bit = continuation. A 32-byte hash and any length < 128 are one byte; length 128 is `0x80 0x01`.

Minimum legal message (all empty, V2, no flags): `43 00 00 00 00` — 5 bytes. This is what `encode_decode_empty_message` (`sync.rs:945-958`) round-trips.

**Chunk payload shapes.** A chunk is a byte string the receiver feeds to the change-chunk / document-chunk stream parser:
- V1 (`new_v1`, `message_builder.rs:26-41`): one chunk per change, `c.raw_bytes()`, in the order given by `get_hashes_to_send` — i.e. `need` hashes first, then graph-topological order.
- V2 from changes (`new_v2_from_changes`, `message_builder.rs:55-65`): **one** chunk = all `c.raw_bytes()` concatenated. Still uncompressed individual changes, not a document chunk.
- V2 whole document (`new_v2`, `message_builder.rs:67-78`, called with `self.save()` at `sync.rs:221` and `sync.rs:240`): one chunk = `Automerge::save()` output, a `Chunk::Document` (asserted at `sync.rs:1403-1405`). `SaveOptions::default()` is `deflate: true, retain_orphans: true` (`automerge.rs:2348-2352`), so columns may be DEFLATE'd (`automerge.rs:2338-2340`) and queued orphan changes are appended raw after the chunk (`automerge.rs:1154-1158`).
- V2 empty (`new_empty_v2`, `message_builder.rs:43-53`): `changes` empty; `version` still `V2`.

### `have` bloom filter bytes (`BloomFilter::to_bytes`, `bloom.rs:38-47`; `parse`, `bloom.rs:48-66`)

```
if num_entries == 0:  <0 bytes — nothing at all>
else:
  varint  num_entries
  varint  num_bits_per_entry     (10 when built by this implementation)
  varint  num_probes             (7 when built by this implementation)
  bytes   ceil(num_entries * num_bits_per_entry / 8)   [bloom.rs:143-146]
```

A zero-length slice parses to `BloomFilter::default()` (`bloom.rs:49-50`), so an empty bloom is wire-legal. `bits` is a little-endian bit array; probe `p` is bit `p & 7` of `bits[p >> 3]`, LSB first (`bloom.rs:98-107`).

Probe derivation (`bloom.rs:69-89`), given `modulo = 8 * bits.len()`:
```
x = u32::from_le_bytes(hash[0..4]) % modulo
y = u32::from_le_bytes(hash[4..8]) % modulo
z = u32::from_le_bytes(hash[8..12]) % modulo
probes[0] = x
for i in 1..num_probes:
    x = (x + y) % modulo
    y = (y + z) % modulo
    probes[i] = x
```
`contains_hash` returns `false` immediately when `num_entries == 0` (`bloom.rs:111-112`), the only thing preventing `% 0`.

### Flags section (`MessageFlags::encode`, `sync.rs:776-781`; `parse_bytes`, `sync.rs:785-795`)

```
varint  0x02                     // nFlagBytes = 2, always
0x02                            // LEGACY_V2_BYTE, always emitted
0x80 | flags.0                  // BITFIELD_MARKER | bitfield byte
```

Canonical 3-byte flags section is `02 02 80|F`:
- `F = 0b100` (SUPPORTS_SYNC_RESET) → `02 02 84`
- `F = 0b110` (READ_ONLY | SUPPORTS_SYNC_RESET) → `02 02 86`
- `F = 0b001` (SYNC_RESET) → `02 02 81`
- default generated message (SUPPORTS_SYNC_RESET only, `sync.rs:266-267`) → `02 02 84`

`parse_bytes` iterates all bytes: if `byte & 0x80 != 0`, `flags |= byte & 0x7F`; otherwise the byte is **ignored**. No check that the section is exactly 3 bytes, no rejection of unknown bits. A section of `00` (length 0) yields `MessageFlags(0)` yet still sets `their_capabilities = Some([MessageV2])` (`sync.rs:404-406`).

### Encoded sync state (`State::encode`, `state.rs:108-111`; `State::parse`, `state.rs:123-157`)

```
0       1      0x43  == SYNC_STATE_TYPE   [state.rs:9]
1       varint nSharedHeads
        32*n   shared_heads[i]  (sorted)
```

Nothing else is persisted. `State::parse` initialises every other field to `Default`/`None`/`false`, with one exception: `their_have: Some(Vec::new())` (`state.rs:139`). Minimum encoding: `43 00` — 2 bytes.

**Type-byte collision:** `SYNC_STATE_TYPE` is `0x43` (`state.rs:9`) and `MESSAGE_TYPE_SYNC_V2` is also `0x43` (`sync.rs:137`). Two unrelated formats share a leading byte.

### v1 sync state (`v1_compat_test/state.rs:79-84`)

Identical layout, identical `0x43` type byte, identical semantics (`v1_compat_test/state.rs:96-119`).

### v1 sync message (`v1_compat_test/mod.rs:407-422`; `parse`, `:363-405`)

```
0       1      0x42  == MESSAGE_TYPE_SYNC   (0x43 REJECTED, mod.rs:365-370)
1       varint nHeads
        32*n   heads
        varint nNeed
        32*n   need
        varint nHave
          per Have: nLastSync, 32*n, nBloomBytes, bloom bytes   (mod.rs:413-416)
        varint nChanges
          per change: varint len, len bytes   (mod.rs:418-421)
```

**No flags section.** The prefix through `nChanges` is byte-identical to V2; V1 and V2 differ only in the leading byte and in whether a trailing flags section is present. A V1 parser that stops after the change chunks parses a V2 body correctly if it ignores the leading byte.

### v1 chunk payload

Each chunk is a single *uncompressed* change. The v1 parser runs `storage::Change::parse` then `Change::new_from_unverified(stored.into_owned(), None)` (`mod.rs:381-402`). This is the hard incompatibility: a V2 whole-document chunk cannot be parsed by the v1 path. `sync_v1_to_v2_with_compressed_change` (`mod.rs:519-547`) is the regression test for exactly this.

---

## Semantics

### `generate_sync_message` (`sync.rs:167-296`)

Signature note: `&self` for the document, `&mut State` — the state is mutated by generation, not only by reception.

1. `our_heads = self.get_heads()` (`sync.rs:168`) → `automerge.rs:1506-1509`, a **sorted** `Vec<ChangeHash>`.
2. `our_need` (`sync.rs:170-184`):
   - if `sync_state.read_only` → `vec![]` (`sync.rs:170-172`);
   - else → `self.missing_deps_from(sync_state.their_heads.iter().flatten().copied())` (`sync.rs:184`).
   The comment at `sync.rs:174-183` states why this is *not* `get_missing_deps`: the queue may hold orphans whose dependencies this peer will never have; advertising those blocks the sync. `missing_deps_from` (`automerge.rs:2037-2062`) walks back from the peer's advertised heads, descending into queued changes' deps and stopping at the first unapplied, unqueued hash, then **sorts** the result.
3. `their_heads_set` — `HashSet<&ChangeHash>` from `their_heads`, or empty (`sync.rs:186-192`).
4. `our_have` (`sync.rs:194-198`): `vec![make_bloom_filter(shared_heads.clone())]` **iff** every hash in `our_need` is in `their_heads_set`; otherwise empty. `make_bloom_filter` (`sync.rs:310-316`) blooms `change_graph.get_hashes(&last_sync)` — all changes not ancestors of `shared_heads`.
5. **Reset detection** (`sync.rs:200-212`): if `their_have` is `Some` and the *first* `Have`'s `last_sync` contains a hash we lack, return `Message::reset(our_heads)` — a V1 message with `need = []`, `have = vec![Have::default()]`, no changes, `flags = Some(SUPPORTS_SYNC_RESET)` (`sync.rs:625-638`). This is the "peer has data I do not know about, restart" signal.
6. **Payload selection** (`sync.rs:214-249`):
   - `sync_state.is_peer_read_only()` → `MessageBuilder::new(vec![], sync_state)`; changes are never sent to a peer that advertised `READ_ONLY` (`sync.rs:216-218`).
   - else if `sync_state.their()` is `Some((their_have, their_need))`:
     - `sync_state.send_doc()` — `their_heads == Some(vec![])` **and** `supports_v2_messages()` (`state.rs:198-200`) → `MessageBuilder::new_v2(self.save(), change_graph.get_hashes(&[]))` (`sync.rs:220-222`).
     - else `all_hashes = get_hashes_to_send(their_have, their_need)` (`sync.rs:228-230`), filtered against `sent_hashes` (`sync.rs:232-236`). If `hashes.len() > self.change_graph.len() / 3` and `supports_v2_messages()` → whole document as V2 (`sync.rs:237-241`). Otherwise materialise `get_changes_by_hashes(hashes)` and `MessageBuilder::new(changes, sync_state)` (`sync.rs:243-245`), which picks single-chunk-V2 vs one-chunk-per-change-V1 on `supports_v2_messages()` (`message_builder.rs:20-25`).
   - else → `MessageBuilder::new(vec![], sync_state)` (`sync.rs:247-249`).
7. **Suppression** (`sync.rs:251-259`):
   ```rust
   if sync_state.last_sent_heads == our_heads && sync_state.have_responded {
       if (heads_equal || sync_state.read_only) && message_builder.is_empty() { return None; }
       if sync_state.in_flight { return None; }
   }
   ```
   `message_builder.is_empty()` tests `hashes.is_empty()`, not `changes.is_empty()` (`message_builder.rs:79-81`) — a V2 whole-doc send is never "empty" because `hashes` is the full hash set.
8. **Commit** (`sync.rs:261-263`): `have_responded = true`; `last_sent_heads = our_heads`; `sent_hashes.extend(message_builder.hashes())`.
9. **Flags** (`sync.rs:265-269`): `SUPPORTS_SYNC_RESET` always; `READ_ONLY` iff `read_only`. `.flags(Some(flags))` is unconditional, so **every** message from `generate_sync_message` carries a flags section.
10. **`needs_reset`** (`sync.rs:271-285`): cleared unconditionally. If `peer_supports_sync_reset()` → set `SYNC_RESET`, send real heads; otherwise send `heads = vec![]`, driving the old peer into its "peer lost all data" reset path (`sync.rs:432-437` on receipt). Covered by `switch_to_read_write_with_old_peer` (`sync.rs:2452-2494`).
11. Build and return; `in_flight = true` (`sync.rs:287-296`).

**Protocol completion.** The loop terminates when both peers return `None` (`sync.rs:1361-1364`, `v1_compat_test/mod.rs:568-580`). A peer returns `None` only when it has responded at least once (`have_responded`), its heads have not changed since the last send, either heads match or it is read-only, and there is nothing in the builder (or `in_flight` is set). `in_flight` is cleared on *receive* (`sync.rs:392`), which unblocks the next message.

### `receive_sync_message_inner` (`sync.rs:386-465`)

Order is load-bearing.

1. `sync_state.in_flight = false` (`sync.rs:392`) — **before** anything can fail, so even an erroring receive unblocks generation.
2. `before_heads = self.get_heads()` (`sync.rs:393`).
3. Destructure; `version` is discarded by `..` (`sync.rs:395-402`). The version byte has no effect on what the receiver does.
4. **Flags** (`sync.rs:404-414`), only if a flags section was present:
   - `their_capabilities = Some(vec![MessageV2])`, plus `SyncReset` iff `SUPPORTS_SYNC_RESET`;
   - `SYNC_RESET` → `sync_state.sent_hashes.clear()`;
   - `peer_read_only = flags.contains(READ_ONLY)`.
   Capabilities are **overwritten wholesale** on every flagged message, not accumulated.
5. **Apply changes** (`sync.rs:416-423`): if the chunk list is non-empty *and* `!sync_state.read_only`, `self.load_incremental_log_patches(&changes.join(), patch_log)?` — a `?` here is the only fallible step. Then `shared_heads = advance_heads(before_heads, self.get_heads(), shared_heads)`.
   `advance_heads` (`sync.rs:827-850`) = `(my_new_heads \ my_old_heads) ∪ (old_shared_heads ∩ my_new_heads)`, deduped and **sorted**.
6. **Ack** (`sync.rs:425-426`): `self.filter_changes(&message_heads, &mut sync_state.sent_hashes)?` — removes every hash that is an ancestor of the peer's advertised heads (`automerge.rs:1206-1218`, which filters `heads` to hashes we actually have before calling `change_graph.remove_ancestors`). This is the entire change-acknowledgement mechanism: the peer acknowledging by advertising heads derived from what we sent.
7. `if changes_is_empty && message_heads == before_heads { last_sent_heads = message_heads }` (`sync.rs:428-430`).
8. **Shared-heads update** (`sync.rs:432-450`):
   - if *all* of `message_heads` are hashes we have: `shared_heads = message_heads`; and if `message_heads` is **empty**, also reset `last_sent_heads` and `sent_hashes` (peer-lost-everything path, `sync.rs:433-437`);
   - else `shared_heads = sorted(unique(shared_heads ∪ known_heads))` where `known_heads` is the subset of `message_heads` we have (`sync.rs:443-449`).
9. `their_have = Some(message_have)`, `their_heads = Some(message_heads)`, `their_need = Some(message_need)` (`sync.rs:452-455`).

**Error surface:** `AutomergeError` from `load_incremental_log_patches` and (nominally) from `filter_changes` — but `filter_changes` is `Result` for future-proofing and returns `Ok` unconditionally (`automerge.rs:1206-1218`).

**`load_incremental_log_patches`** (`automerge.rs:1033-1071`): if `self.is_empty()` it does a full `load_with_options(.., OnPartialLoad::Ignore, VerificationMode::Check)` and replaces `*self`, re-attaching the current actor. Otherwise it runs `load::load_changes(.., MarkOrderValidation::Validate)` and on `LoadedChanges::Partial` logs a warning and applies the subset. `load_changes` handles `Chunk::Document` by calling `d.reconstruct_changes(text_encoding)` when the current graph lacks the document's heads (`storage/load.rs:110-114`) — which is why a V2 whole-doc payload works on a non-empty receiver, not only an empty one.

**`apply_changes_batch_log_patches`** (`batch.rs:1048-1106`) is where sync hits `ChangeQueue`. Rejection rules, all of which become `AutomergeError` and abort the whole message: duplicate `(actor, seq)` against the graph (`batch.rs:1073-1077`, which also calls `queue.remove_actor_branch_from(actor, seq+1)` to drop the conflicting branch and its dependents — `change_queue.rs:68-105`), duplicate `(actor, seq)` against the queue (`batch.rs:1078-1083`), duplicate actor→author mapping (`batch.rs:1085-1092`). Changes already applied or already queued are silently skipped (`batch.rs:1069-1072`). `pop_topo_sorted_ready` (`change_queue.rs:123-175`) is Kahn's algorithm over the queue against the graph; only the topologically-ready prefix is applied, the rest stays queued.

### `get_hashes_to_send` (`sync.rs:318-384`)

```
need := need.filter(hash => self.has_change(hash))          // :324-327
if have.is_empty() { return need }                           // :328-329
last_sync := union of every Have.last_sync                   // :334-337
hashes    := change_graph.get_hashes(last_sync)              // :339  (topological order, COW)
for h in hashes:                                             // :347-356
    dependents[dep].push(h)  for dep in change_graph.deps(h) // parents -> child index
    if all blooms miss h: hashes_to_send.insert(h)
// transitive closure downward over children                    // :358-367
stack = hashes_to_send
while let Some(h) = stack.pop():
    for child in dependents[h]: if hashes_to_send.insert(child) { stack.push(child) }
final = need.filter(not in hashes_to_send) ++ hashes_to_send-in-graph-order  // :369-381
```

Invariants provable from the code:
- `dependents[h]` are the **children** of `h`, not its ancestors (`deps()` returns parents, `change_graph.rs:766-772`; the loop reverses them, `sync.rs:350-351`). The closure therefore pulls in *descendants* of everything we send. Correct because `hashes` already excludes everything the peer has by ancestry from `last_sync`; anything missing is missing transitively, and so are its children.
- Output order is `need` first, then graph order. **Independent of `HashSet` iteration order**, which is SipHash-nondeterministic. The `stack` pop order varies but affects only the *set*, not the ordering.
- `change_hashes` (`sync.rs:343, 348`) is written and never read — dead local. The v1 copy has the same dead local (`v1_compat_test/mod.rs:157`).
- `get_changes_by_hashes` (`sync.rs:245` → `automerge.rs:737-742` → `ChangeCollector::for_hashes`) can return `Err`; the code uses `.ok()?` (`sync.rs:245`), so an error makes `generate_sync_message` return `None`, not `Err`.

### `State` invariants

- `sent_hashes` ⊆ hashes actually put on the wire this session. Grows in step 8 of generation, shrinks in step 6 of reception. A `BTreeSet` for deterministic removal, never for iteration order.
- `their_have` / `their_need` / `their_heads` are all `Some` together after the first received message; before that `their()` returns `None` (`state.rs:202-206`) and generation sends no changes.
- `their_capabilities == None` means "the peer has never sent a flags section" — the definition of an old peer, forcing V1 in both directions (`state.rs:208-212`, `message_builder.rs:20-25`).
- `read_only` suppresses `our_need` entirely (`sync.rs:170-172`) and suppresses applying incoming changes (`sync.rs:417`), but *not* sending our own changes.
- `peer_read_only` is set only from `MessageFlags::READ_ONLY` (`sync.rs:412-413`) and clears nothing else.
- `have_responded` guarantees at least one message is always emitted so the peer learns our heads (`state.rs:56-62`; test `first_response_is_some_even_if_no_changes`, `sync.rs:981-1003`).

### `set_read_only` (`state.rs:159-184`)

- No-op if the value is unchanged (`state.rs:160-162`).
- read-write → read-only: sets `read_only`, clears `in_flight`, clears `have_responded` so the next generation emits a message carrying `READ_ONLY` (`state.rs:176-181`).
- read-only → read-write: **replaces `*self`** with a fresh default, preserving only `their_capabilities`, and sets `needs_reset = true` (`state.rs:163-175`). `shared_heads`, `sent_hashes`, `their_heads` are lost, so a fresh full exchange happens.

### V1 vs V2 — exact differences

| Aspect | v1 (frozen, `v1_compat_test/`) | v2 (current, `sync.rs` + `sync/`) |
|---|---|---|
| Type byte | `0x42` only; `0x43` rejected (`mod.rs:24, 365-370`) | `0x42` or `0x43` (`sync.rs:136-137, 146-155`) |
| Message `changes` | `Vec<Change>` — decoded, typed (`mod.rs:321`) | `ChunkList(Vec<Vec<u8>>)` — opaque bytes (`sync.rs:551`) |
| Change decode | `storage::Change::parse` + `Change::new_from_unverified` per chunk (`mod.rs:381-402`) | never; bytes go straight to `load_incremental` (`sync.rs:591-593`, `417-419`) |
| Flags section | none (`mod.rs:407-422`) | optional trailing length-prefixed flags (`sync.rs:658-665, 692-695`) |
| `State` fields | 8 (`v1_compat_test/state.rs:36-77`) | 13, incl. `their_capabilities`, `read_only`, `peer_read_only`, `needs_reset` (`state.rs:33-81`) |
| `our_need` | `get_missing_deps(their_heads.unwrap_or(&[]))` — includes **all** queued orphan deps (`mod.rs:30`) | `missing_deps_from(their_heads)` — only deps reachable from the peer's heads (`sync.rs:184`) |
| Bloom source | `self.get_changes(&last_sync)` — materialises `Change`s (`mod.rs:126`) | `change_graph.get_hashes(&last_sync)` — `Cow<[ChangeHash]>` (`sync.rs:311`) |
| Changes to send | `get_changes_to_send_v1 -> Vec<Change>` (`mod.rs:134-203`) | `get_hashes_to_send -> Vec<ChangeHash>` (`sync.rs:318-384`) |
| Dedup order | dedup after materialising changes (`mod.rs:80-88`) | dedup on hashes before materialising (`sync.rs:232-236`) |
| Apply received | `self.apply_changes(changes)` — unconditional (`mod.rs:218`) | `load_incremental_log_patches(&changes.join(), patch_log)`, skipped when `read_only` (`sync.rs:417-419`) |
| Reset message | inline literal (`mod.rs:46-52`) | `Message::reset()` (`sync.rs:625-638`) |
| `heads_equal` | inline `their_heads.as_ref() == Some(&our_heads)` (`mod.rs:74-79`) | `sync_state.their_heads.as_ref() == Some(&our_heads)` (`sync.rs:253`) |
| Suppression test | `heads_equal && changes_to_send.is_empty()` (`mod.rs:90`) | `(heads_equal \|\| read_only) && builder.is_empty()` (`sync.rs:255`) |
| Whole-doc send | impossible | `send_doc()` + >1/3 heuristic (`sync.rs:220, 237`) |
| Helpers | duplicated `encode_many`/`encode_hashes`/`advance_heads` (`mod.rs:427-470`) | single copy (`sync.rs:808-850`) |
| Bloom | same algorithm, `pub(crate)` | same algorithm, `pub` |
| Sync loop shape | strict ping-pong ordering (`mod.rs:556-588`) | both sides generate before either receives (`sync.rs:1361-1380`) |
| `have_responded` / `in_flight` / ack logic | identical logic, duplicated | — |

There is **no separate handshake message**. The handshake is: the initiator emits a V1 message (a fresh `State` has `their_capabilities == None`, so `MessageBuilder::new` picks `new_v1`, `message_builder.rs:20-25`) that already carries a flags section advertising `MessageV2` + `SyncReset`; the responder parses the section, sets `their_capabilities = Some([MessageV2, SyncReset])`, and may then send V2. `Capability::MessageV1` is never constructed in live code, so "V1 support" is the absence of a flags section, not an advertised capability.

---

## Zig mapping notes

**Traits.** `SyncDoc` is a plain object-safe trait with three methods, two of which take `&mut self` *and* `&mut State`. Zig has no trait objects. The natural mapping is free functions:

```zig
pub fn generateSyncMessage(doc: *const Automerge, st: *State) ?Message;
pub fn receiveSyncMessage(doc: *Automerge, st: *State, msg: Message) AutomergeError!void;
```

`SyncWrapper<'a>` (`autocommit.rs:1301-1344`) exists only to (a) `ensure_transaction_closed()` and (b) route to `AutoCommit`'s own `patch_log` vs `PatchLog::null()` when the doc is in isolation mode (`autocommit.rs:1316-1330`). In Zig that is an explicit `ensureTransactionClosed()` at the call site plus one branch, not a decorator. No GAT, no `dyn`+assoc-type, no `pin`, no proc macro, no `unsafe` anywhere in the sync module.

**`Option`/`Result`.** `Option<Message>` → `?Message`; `Option<Vec<ChangeHash>>` → `?[]ChangeHash`. Zig's `?T` is an explicit tag byte, so `?Message` is one byte larger than Rust's niche-packed `Option<Message>`; irrelevant except for ABI, and this type is never `extern struct`.

**`Result`/errors.** `thiserror` derive on `ReadMessageError`/`DecodeError`/`ParseError` → plain error sets. But `ParseError<E>` is **not** a Zig error set: it is `Error(E) | Incomplete(Needed)`, and `Incomplete` is a control-flow signal (retry with more bytes), not a failure. Zig error sets are flat and cannot carry a payload. Model it as an explicit tagged struct:

```zig
pub const ParseError = struct { kind: enum { failed, incomplete }, needed: usize };
```
`From<parse::ParseError<E>> for ReadMessageError` (`sync.rs:503-510`) collapses `Incomplete` to `NotEnoughInput` — a lossy flattening a Zig port must reproduce exactly, because `Message::decode` and `State::decode` both surface it that way.

**Parser combinators.** `Input<'a>` is `Copy` with `(bytes, position, original)`; state is threaded as `Ok((Input, value))`. Near-exact `struct` + by-value threading. `parse::Parser<'a, O, E>` is a blanket impl over `Fn(Input) -> ParseResult` (`parse.rs:334-345`); in Zig it is a `comptime` function parameter or a function-pointer-plus-context struct. `length_prefixed` and `length_prefixed_bytes` (`parse.rs:423-458`) are single generic functions; in Zig `lengthPrefixed` must be `comptime`-generic or hand-inlined three times. No `Iterator` machinery in Zig 0.16, so the many `impl Iterator` returns — `ChunkList::iter` (`sync.rs:587`), `MessageBuilder::hashes` (`message_builder.rs:83`), `change_graph.deps` (`change_graph.rs:766`), `encode_many`'s `I: Iterator + ExactSizeIterator` bound (`sync.rs:808-816`) — each become a concrete iterator struct with `next()`, or an inline loop. `encode_many` takes a closure `F: Fn(&mut Vec<u8>, It)`; in Zig that is a `comptime` callback or an explicit loop at each of its two call sites (`sync.rs:681, 687`).

**Allocator-generic plumbing — the largest mechanical delta.** Nothing in `sync.rs`, `state.rs`, `message_builder.rs` or `bloom.rs` mentions an allocator; every buffer is a plain `Vec<u8>` on the Rust global allocator. Zig has no global allocator, so each of these signatures acquires an `Allocator` parameter Rust does not have: `Message::encode`, `Message::decode`, `Message::parse`, `State::encode`, `State::decode`, `State::parse`, `MessageBuilder::new_v2`, `MessageBuilder::build`, `BloomFilter::to_bytes`, `BloomFilter::parse`, `BloomFilter::from_hashes`, `ChunkList::parse`, `ChunkList::join`, `parse_have`, `encode_many`, `encode_hashes`, `get_hashes_to_send`, `make_bloom_filter`. The public wire API becomes allocator-parameterised — a visible API change, not a mechanical detail. Ownership: `Message::encode(self)` consumes `self` and returns an owned `Vec<u8>` → in Zig either return `[]u8` with caller-frees, or return a `*Payload` behind `deinit`.

**`Cow<'a, [ChangeHash]>`** (`message_builder.rs:16`, `change_graph.rs:476`) → `union(enum) { borrowed: []const ChangeHash, owned: ArrayListUnmanaged(ChangeHash) }`. In practice `get_hashes(&[])` always returns the borrowed variant (`change_graph.rs:477-479`); the `owned` arm exists only for the non-empty-`have_deps` case.

**`BTreeSet<ChangeHash>`** (`state.rs:44`) — Zig 0.16 has no `BTreeSet`. `ChangeHash`'s `Ord` is derived from `[u8; 32]`, so ordering is `std.mem.order(u8, a, b)`. A sorted `ArrayListUnmanaged(ChangeHash)` with binary-search insert is the direct equivalent and preserves the only property relied on: `remove_ancestors` mutates the set, and nothing iterates it for order-sensitive output.

**`HashSet`/`HashMap`** — `sync.rs` uses `std::collections::{HashMap, HashSet}` (SipHash-1-3, `sync.rs:71`); `change_queue.rs` and `change_graph.rs` use `rustc_hash` (FxHash). Zig: `std.AutoHashMap` / `std.AutoHashMapUnmanaged` (Wyhash). Hash iteration order differs, but as proven above `get_hashes_to_send`'s output ordering does not depend on it. A port that emits chunks in `HashSet` order instead of graph order still produces a *valid* message but a different byte stream, breaking byte-for-byte tests.

**`MessageVersion`** (2-variant enum) → `enum { v1, v2 }`; `encode()` becomes `switch (v) { .v1 => 0x42, .v2 => 0x43 }`.

**`MessageFlags(u8)` newtype + associated consts** (`sync.rs:742-781`) → plain `u8` constants in a namespace, or an `enum(u8)`. `SYNC_RESET`/`READ_ONLY`/`SUPPORTS_SYNC_RESET` are `u8` bit *masks* (`1 << 0`, `1 << 1`, `1 << 2`), not enum discriminants, so a packed-struct or `u8` is the faithful representation. `BITFIELD_MARKER`/`LEGACY_V2_BYTE` are private consts.

**`Capability` enum** (`sync.rs:800-806`) → Zig `enum { message_v1, message_v2, sync_reset }`. The Rust code only does `caps.contains(&Capability::X)` on a `Vec<Capability>` (`state.rs:191-195, 208-212`), so the natural port is a `u3` bitmask — which also drops the dead `MessageV1` variant. Note `Capability: Hash` was clearly added for exactly that and never used.

**`ChunkList(Vec<Vec<u8>>)`** with a private field and `From` impls → `struct { chunks: [][]u8 }` with free functions or explicit `.chunks`. No `Deref` in Zig, so `.iter()` / `.len()` / `.is_empty()` / `.join()` (`sync.rs:575-600`) become plain methods and `join()` a manual copy loop.

**`#[derive(Hash)]`, `#[derive(Eq)]`, `#[derive(PartialEq, PartialOrd, Ord)]`** → `std.hash.autoHash`, `std.meta.eql`, and for `ChangeHash` ordering a hand-written `lessThan` = `std.mem.order(u8, …) == .lt`.

**`serde`** — `Message` has a hand-written `Serialize` emitting only 4 keys (`sync.rs:603-614`); `Have` and `BloomFilter` derive `Serialize` (`state.rs:83`, `bloom.rs:12`). None is on the Rust path; it exists for `automerge-wasm` and `automerge-c`. `std.json` can serialise a struct with matching field names, but the 4-key map with a computed key (`"changes"` from a private tuple field) needs a manual `jsonStringify` or an intermediate DTO. Note the `Serialize` impl **omits `flags` and `version`**, whereas the wasm `decode_sync_message` adds `type` and `supportedCapabilities` from separate code (`automerge-wasm/src/lib.rs:2032-2046`) — two different JSON shapes for the same message. A Zig port must pick one.

**`#[cfg(test)] mod v1_compat_test`** — Zig has no `cfg`. The frozen v1 implementation (625 + 120 + 162 lines) is a complete second implementation of the protocol, a second `State`, and a second `BloomFilter`, and it must be compiled into every build or excluded by hand from `build.zig`. It is exercised only by five tests. This is the clearest place a Zig port must decide: keep the frozen copy as a test-only module (accepting ~900 duplicated lines), or replace it with a golden-vector suite (byte fixtures captured from the Rust implementation) — cheaper and better coverage. The frozen copy carries `#[allow(dead_code)]` on `SYNC_STATE_TYPE`, `DecodeError`, `State::encode` and `State::decode` (`v1_compat_test/state.rs:7, 10, 79, 86`); they exist only to prove the v1 state format is unchanged, and are never called.

**`#[cfg(test)] impl PartialOrd for Clock`** (`clock.rs:169-197`) — `Clock` gains `new`, `include`, `is_greater` and `PartialOrd` *only* under test. A Zig port that gives `Clock` these unconditionally is strictly more capable and behaviour-identical outside tests; one that omits them cannot run its own `clock.rs` tests without a test-only build.

**`Send`/`Sync`** — no `State`, `Message`, `Have`, `MessageFlags` or `BloomFilter` has a `Send`/`Sync` assertion. Zig has no such concept, so nothing is lost; but there is consequently **no compile-time proof** that the ported sync state is safe to share across threads, and the Rust original does not provide one either.

**`no_std`** — not applicable; the crate is std-only and the sync module uses `std::collections`, `std::borrow::Cow`, and the global allocator throughout.

**No clean Zig equivalents encountered in this slice** beyond the `Parser` trait and the error-payload problem: no GATs, no `dyn` with associated types, no `pin`, no proc macros expanding into public API, no `unsafe impl` marker traits, no `#[cfg(feature)]`-gated surface in `sync.rs`/`sync/`.

---

## Risk

1. **`0x43` is overloaded.** `MESSAGE_TYPE_SYNC_V2` (`sync.rs:137`) and `SYNC_STATE_TYPE` (`state.rs:9`) are the same byte for different formats. A port that models "record type" as one tagged enum will decode a V2 sync message as a sync state, or vice versa. Keep them as separate constants in separate namespaces.

2. **Trailing bytes are silently ignored.** `Message::decode` (`sync.rs:640-647`) and `State::decode` (`state.rs:114-121`) both discard the `Input` returned by `parse`. A Zig port returning `error.TrailingBytes` rejects legitimate traffic: a flags section is exactly "trailing bytes" to a v1-only parser, and the frozen v1 tests feed current-encoded messages into the v1 parser (`v1_compat_test/mod.rs:576, 614`).

3. **The flags section is trusted and under-validated.** `MessageFlags::parse_bytes` (`sync.rs:785-795`) ignores every byte `< 0x80` and ORs every byte `>= 0x80` into the flag bits, without checking that the section is 3 bytes, that the second byte is `0x02`, or that unknown bits are zero. A peer can send `00` (advertising V2 with no flags) or `80 80 …`. A port that validates here is stricter than every real peer and will fail interop.

4. **`in_flight` is a single bit, not a counter** (`state.rs:43, 68`). Two generated-but-unacked messages are indistinguishable from one. The code documents the failure mode this causes — automerge issue #702, both ends returning `None` with divergent documents (`sync.rs:1313-1318`). A port that replaces the bit with a counter changes the suppression rule at `sync.rs:251-259` and therefore the loop-termination guarantee every driver relies on with `MAX_ITER = 10` (`sync.rs:1354`, `v1_compat_test/mod.rs:550/591`).

5. **`get_hashes_to_send` closes over *children*, not ancestors** (`sync.rs:350-351, 358-367`). Inverting the edge direction silently drops changes: a port that sends only the missing ancestors leaves the receiver unable to apply anything, and the symptom is a non-converging sync with no error. No assertion guards this.

6. **`change_graph.len()` is the number of change nodes, not actors** (`change_graph.rs:188-190` returns `self.actors.len()`, where `actors: Vec<ActorIdx>` is one entry per change — confirmed by `debug_assert_eq!(changes.len(), graph.len())` at `change_graph.rs:892`). It is the divisor in the 1/3 whole-document heuristic at `sync.rs:237`. A port that reads `len()` as an actor count changes when the whole-document path is taken, hence the bytes on the wire.

7. **The V2 whole-document payload is not V1-parseable, by construction.** `self.save()` (`sync.rs:221, 240`) emits a `Chunk::Document` with `deflate: true` and `retain_orphans: true` (`automerge.rs:2348-2352`), so the chunk may be DEFLATE'd *and* may have raw orphan change bytes appended (`automerge.rs:1154-1158`). Both break the v1 change parser. The only thing keeping this safe is the `supports_v2_messages()` guard on both whole-doc paths (`sync.rs:220, 237`) — a port that drops the guard, or that sends the whole document to a peer whose `their_capabilities` is `Some([MessageV2])` but which is nonetheless an old *automerge-js* build, breaks the wire.

8. **`Message::parse` does not validate `version` against payload shape.** A `0x43` message with one chunk per change parses fine, and `receive_sync_message_inner` ignores `version` entirely (`sync.rs:395-402`). A port that enforces "V2 ⇒ exactly one chunk, a document" is stricter than the reference and rejects messages real peers send.

9. **The frozen v1 copy can drift from the current implementation with no compile error.** It is `#[cfg(test)]`-only (`sync.rs:87-88`) and duplicates ~200 lines of protocol logic, a `State`, a `BloomFilter`, and three helper functions. Only the five interop tests catch behavioural divergence. A Zig port that keeps the copy inherits the blind spot; one that deletes it loses the only interop coverage.

10. **Bloom probe arithmetic has a latent `% 0`.** `get_probes` computes `modulo = 8 * bits.len()` and takes `% modulo` (`bloom.rs:71-79`); if `bits` were empty this divides by zero. `contains_hash` short-circuits on `num_entries == 0` (`bloom.rs:111-112`) and `to_bytes` emits nothing when `num_entries == 0` (`bloom.rs:40`), so no wire-reachable filter has `bits.len() == 0` with `num_entries > 0`: `from_hashes` with 0 entries sets both (`bloom.rs:126-131`) and `bits_capacity(0, 10) == 0` (`bloom.rs:143-146`). `[INFERENCE]` A port that constructs a `BloomFilter` field-by-field — which Zig's plain struct makes easy — can reach the panic; Rust's field privacy (`bloom.rs:14-17`) is the only thing preventing it.

11. **Unverifiable without running the code:** the exact byte output of `Message::encode` for every flag combination, the behaviour of `MessageFlags::parse_bytes` on multi-byte sections, and convergence of the mixed read-only/read-write configurations. The read-only matrix is covered by ~20 tests (`sync.rs:1410-2451`) but there is no convergence proof in the code; `[INFERENCE]` the read-only cases converge because both sides' suppression rule short-circuits on `read_only` (`sync.rs:255`), not because the exchange is well-founded.

12. **`ChangeQueue` is on the protocol path, `Clock` is not.** `sync.rs:184` calls `missing_deps_from`, which walks `self.queue` (`automerge.rs:2041-2043`); orphaned queued changes therefore change `our_need` and thus the bytes on the wire. Porting `ChangeQueue` with the read path instead of with sync yields a subtly non-converging port. Conversely `Clock`/`SeqClock` serve only `get_at`-style reads and change-graph clock caching and have no presence in `sync.rs` — porting them into the sync slice adds nothing.
