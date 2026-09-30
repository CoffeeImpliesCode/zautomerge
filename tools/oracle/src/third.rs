//! The whole-document arm of the sync protocol, measured.
//!
//! Upstream sends a whole document instead of a change list when
//!
//! ```text
//! hashes.len() > change_graph.len() / 3 && supports_v2_messages()
//! ```
//!
//! (`sync.rs:225-228`). Both halves are things an oracle can observe rather
//! than reason about, and this subcommand observes them:
//!
//! * `change_graph.len()` is the divisor (`sync.rs:225`), and
//!   `change_graph.rs:188-190` returns `self.actors.len()`, where `actors` is
//!   one `ActorIdx` per change — so it is the **number of changes in the
//!   sender's document**, not the number of actors, not the number of changes
//!   the peer holds, and not the clock length. `get_changes(&[]).len()` is the
//!   same set of changes (`change_graph.rs:476-479` returns `&self.hashes`
//!   when `have_deps` is empty), and is the number this file prints as
//!   `graph_len`.
//! * The comparison is `>`, against an **integer** division. `hashes.len()`
//!   is the count *after* the `sent_hashes` filter at `sync.rs:221-224`, so a
//!   peer that has already been sent some of them can push the count down.
//!
//! `hashes_to_send` below is the count `hashes.len()` sees, and it is
//! **measured, not derived**: the record delivers the message to the peer and
//! reports how many changes the peer ended up holding. A port that computed
//! the count any other way would disagree here.
//!
//! One case does not go through `hashes.len()` at all: `send_doc` returns the
//! whole document before the count is taken (`sync.rs:213-215`). Its
//! `hashes_to_send` is the graph length the peer ends up holding, which is the
//! same number for a different reason, and `send_doc` says which it was.
//!
//! # The peer state is real, not synthesised
//!
//! The peer is a document that actually holds the first `prefix` changes, and
//! the sender's `their_have` / `their_heads` are whatever the peer's own
//! generated message left behind (`sync.rs:386-464`). Nothing is hand-built.
//! A hand-built `their_have` — a filter claiming an arbitrary subset — is the
//! trap: `get_hashes_to_send` walks **descendants** of anything the filter
//! misses (`sync.rs:359-368`), so on a history with forks the set it walks is
//! not the set that was excluded, and a "small minority" fixture quietly
//! becomes a large one.
//!
//! # The corpus
//!
//! `total` and `prefix` pairs chosen to put `total - prefix` either side of
//! `total / 3` for several `total`: `30`, `31`, `32` and `33`, where the last
//! divides exactly and `33 / 3 == 11` is one below a division that rounded up,
//! and `3` and `9`, the smallest documents where `total / 3` is 1 and 3.
//! `prefix` of zero is the `send_doc` arm (`state.rs:198-200`), which is a
//! *different* reason to send a document; it is in the corpus as a control
//! and the record says so in `send_doc`.
//!
//! # What a record carries
//!
//! The first record is `third-fixture`: the sender's actor, key, timestamp
//! and first two changes with their hashes, metadata and bytes. The rest are
//! `third`, one per case.
//!
//! | field           | what it is |
//! |-----------------|------------|
//! | `total`         | changes the sender's document holds |
//! | `prefix`        | of those, how many the peer really holds |
//! | `graph_len`     | `change_graph.len()`, **the divisor** (`sync.rs:225`) |
//! | `threshold`     | `graph_len / 3`, an integer division |
//! | `hashes_to_send` | what `hashes.len()` saw, **measured** by delivery |
//! | `payload`       | `document`, `changes` or `empty`, from the chunk-type byte |
//! | `send_doc`      | true when the peer advertised empty heads — a different arm |
//! | `version`       | the message's type byte, `v1` or `v2` |
//! | `chunks`        | how many chunks the payload is |
//! | `message_bytes` | the encoded message's length |
//! | `peer_heads`    | the heads the sender recorded for the peer |
//! | `sender_head`   | the head the sender advertised |

use std::error::Error;
use std::io::Write;

use automerge::sync::{Message, State, SyncDoc};
use automerge::transaction::Transactable;
use automerge::{AutoCommit, ROOT};
use serde_json::{Value as Json, json};

use crate::{ACTOR_A, ACTOR_B, TIME, actor, commit_options, emit, head_text, hex_encode};

/// The four magic bytes every framed chunk opens with (`storage.rs:26`).
const CHUNK_MAGIC: [u8; 4] = [0x85, 0x6f, 0x4a, 0x83];

/// Where the chunk-type byte sits: four of magic, four of checksum, then the
/// type (`chunk.rs:232-237`).
const CHUNK_TYPE_OFFSET: usize = 8;

/// `ChunkType::Document` as it appears in that byte (`chunk.rs:148-157`).
const CHUNK_TYPE_DOCUMENT: u8 = 0;

/// `(total, prefix)` pairs. Each `total` gets a triple that straddles
/// `total / 3`, plus a peer holding nearly all of the document.
const CASES: &[(usize, usize)] = &[
    // `30 / 3 == 10`: 10 hashes to send is exactly the threshold.
    (30, 0),
    (30, 1),
    (30, 10),
    (30, 19),
    (30, 20),
    (30, 21),
    (30, 29),
    // `31 / 3 == 10`: the division truncates, so the threshold is unchanged.
    (31, 19),
    (31, 20),
    (31, 21),
    // `32 / 3 == 10`.
    (32, 20),
    (32, 21),
    (32, 22),
    // `33 / 3 == 11`: exact, and one lower than a rounding division.
    (33, 20),
    (33, 21),
    (33, 22),
    // The smallest document that divides exactly, and one that does not.
    (3, 0),
    (3, 1),
    (3, 2),
    (9, 4),
    (9, 5),
    (9, 6),
];

/// `third`: the fixture's own first changes, then one record per
/// `(total, prefix)` case.
pub fn third_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    // The fixture's first two changes, once. Every case below is a prefix of
    // the same chain, so publishing them per record would repeat the same
    // bytes twenty times. A consumer that cannot reproduce these hashes has
    // not reproduced the script, and every number in the records after this
    // one is about a different history than the one it thinks it is measuring.
    emit(out, &fixture(30)?)?;
    for &(total, prefix) in CASES {
        emit(out, &case(total, prefix)?)?;
    }
    Ok(())
}

/// The fixture itself: the first two changes of a sender built exactly as
/// [`case`] builds its sender, with their hashes, their metadata and their
/// bytes.
///
/// **This is the record that catches a wrong fixture.** A change hash is
/// `SHA-256` over the encoded change, and that encoding holds the author's id,
/// the timestamp and the commit message — so a consumer whose replay differs in
/// any of those produces a document that loads, converges and reports a
/// plausible count for every case, while measuring a different history
/// throughout. `ACTOR_A` is **fifteen** bytes, not sixteen; reading it as
/// sixteen still parses and still loads.
fn fixture(total: usize) -> Result<Json, Box<dyn Error>> {
    let mut sender = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    for index in 0..total {
        sender.put(ROOT, "k", index as i64)?;
        sender.commit_with(commit_options("k"));
    }
    let changes: Vec<Json> = sender
        .get_changes(&[])
        .iter()
        .cloned()
        .take(2)
        .map(|mut change| {
            let bytes = change.bytes().into_owned();
            json!({
                "hash": change.hash().to_string(),
                "start_op": change.start_op().get(),
                "seq": change.seq(),
                "time": change.timestamp(),
                "deps": change.deps().iter().map(ToString::to_string).collect::<Vec<_>>(),
                "bytes": bytes.len(),
                "hex": hex_encode(&bytes),
            })
        })
        .collect();
    Ok(json!({
        "kind": "third-fixture",
        "total": total,
        "actor_a": ACTOR_A,
        "key": "k",
        "time": TIME,
        "changes": changes,
    }))
}

/// One case: a sender with `total` changes, a peer holding the first
/// `prefix`, and the message the sender then generates.
fn case(total: usize, prefix: usize) -> Result<Json, Box<dyn Error>> {
    if prefix > total {
        return Err(format!("prefix {prefix} exceeds total {total}").into());
    }

    // The sender: one change per `put`, all by one actor, all at `TIME`.
    let mut sender = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    for index in 0..total {
        sender.put(ROOT, "k", index as i64)?;
        sender.commit_with(commit_options("k"));
    }
    let changes = sender.get_changes(&[]);

    // The peer: a document that really holds the first `prefix` changes.
    let mut peer = AutoCommit::new().with_actor(actor(ACTOR_B)?);
    peer.apply_changes(changes[..prefix].to_vec())?;

    let mut sender_state = State::new();
    let mut peer_state = State::new();

    // The peer's own first message, handed to the sender, so the sender's
    // `their_have` and `their_heads` are the real ones (`sync.rs:386-464`).
    let hello = peer
        .sync()
        .generate_sync_message(&mut peer_state)
        .ok_or("the peer generated no first message")?;
    sender.sync().receive_sync_message(
        &mut sender_state,
        Message::decode(&hello.encode())?,
    )?;

    let peer_heads = peer.get_heads();

    // And now the message under test.
    let reply = sender
        .sync()
        .generate_sync_message(&mut sender_state)
        .ok_or("the sender generated no reply")?;
    let version = match reply.version {
        automerge::sync::MessageVersion::V1 => "v1",
        automerge::sync::MessageVersion::V2 => "v2",
    };
    let chunks = reply.changes.len();
    let payload = classify(&reply);
    let sender_heads = reply.heads.clone();
    let raw = reply.encode();
    let decoded = Message::decode(&raw)?;
    peer.sync()
        .receive_sync_message(&mut peer_state, decoded)?;

    // Measured, not derived: the peer holds the prefix plus whatever the
    // payload carried, so the difference is the count `hashes.len()` saw.
    let delivered = peer.get_changes(&[]).len();
    let graph_len = changes.len();

    Ok(json!({
        "kind": "third",
        "total": total,
        "prefix": prefix,
        "graph_len": graph_len,
        "threshold": graph_len / 3,
        "hashes_to_send": delivered - prefix,
        "peer_heads": head_text(&peer_heads),
        // `their_heads == Some(vec![])` **and** a V2-capable peer
        // (`state.rs:198-200`): a document here is this arm, not the 1/3 one.
        "send_doc": peer_heads.is_empty(),
        "payload": payload,
        "version": version,
        "chunks": chunks,
        "message_bytes": raw.len(),
        "delivered": delivered,
    }))
}

/// What the payload was, read off the chunk type byte and not off the magic:
/// every framed chunk opens with the magic, a change chunk included
/// (`chunk.rs:232-237`).
fn classify(message: &Message) -> &'static str {
    if message.changes.is_empty() {
        return "empty";
    }
    for chunk in message.changes.iter() {
        if chunk.len() <= CHUNK_TYPE_OFFSET {
            continue;
        }
        if chunk[..4] != CHUNK_MAGIC {
            continue;
        }
        if chunk[CHUNK_TYPE_OFFSET] == CHUNK_TYPE_DOCUMENT {
            return "document";
        }
    }
    "changes"
}
