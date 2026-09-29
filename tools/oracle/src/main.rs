//! The differential-testing oracle for the `zautomerge` port.
//!
//! `zautomerge` is a direct translation of the upstream Rust `automerge` crate.
//! "Wire compatible" only means something when the two implementations can be
//! held against each other byte for byte, so this binary drives the reference
//! implementation through a fixed set of operations and prints what came out.
//! The Zig test suite replays the same operations and compares the bytes.
//!
//! Every run is reproducible. Actors come from [`ACTOR_A`] and [`ACTOR_B`],
//! every commit is stamped with [`TIME`], and nothing reads the wall clock or
//! draws a random actor id.
//!
//! # Subcommands
//!
//! Every subcommand writes newline delimited JSON, one record per line, to
//! stdout or to the file named by its single optional argument (`-` is stdout).
//! Each record carries a `kind` field so a consumer can tell the streams apart:
//!
//! * `doc` — one record, the `save()` bytes of a scripted document.
//! * `change` — one record per change: hash, start op, sequence, dependencies,
//!   timestamp and the change chunk as hex.
//! * `sync` — one record per direction per round (`kind` `sync`) followed by
//!   one `sync-final` record per side.
//! * `fixtures` — one record per file in [`FIXTURE_DIR`] with the result of
//!   loading it.
//!
//! The hex is always lowercase and unprefixed.

use std::error::Error;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use automerge::sync::{Message, State, SyncDoc};
use automerge::transaction::{CommitOptions, Transactable};
use automerge::{ActorId, AutoCommit, ObjType, ScalarValue, Value, ROOT};
use serde_json::{Map, Value as Json, json};

/// The actor which writes the scripted document and the left sync peer.
const ACTOR_A: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

/// The actor which makes the concurrent edit and the right sync peer.
const ACTOR_B: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

/// The timestamp stamped on every commit, in the unix seconds the change chunk
/// format uses.
const TIME: i64 = 1_700_000_000;

/// How many rounds of the sync protocol the `sync` subcommand runs. A fixed
/// count keeps the output length fixed; rounds with nothing to say are reported
/// with `sent: false` rather than dropped.
const SYNC_ROUNDS: usize = 8;

/// The directory `fixtures` reads. Flat, and holding the corpus files only.
const FIXTURE_DIR: &str = "test/fixtures";

/// The usage text, printed by `--help` and by every usage error.

const USAGE: &str = "\
usage: zautomerge-oracle <command> [output-file]

commands:
  doc        build a scripted document and print its save() bytes as hex
  change     build a scripted document and print every change with its metadata
  sync       run two documents through the sync protocol and print every message
  fixtures   load every file in test/fixtures and print ok or err

The output file defaults to stdout, and `-` also means stdout. Output is
newline delimited JSON.
";

/// Run the subcommand named on the command line, reporting any failure on
/// stderr and through the exit code.
fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("zautomerge-oracle: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Parse the command line, open the output sink, and dispatch.
fn run() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args().skip(1);
    let Some(command) = args.next() else {
        return Err(usage_error("missing command"));
    };
    let rest: Vec<String> = args.collect();
    if rest.len() > 1 {
        return Err(usage_error("expected at most one output file"));
    }
    let out_path = rest.first().map(PathBuf::from);

    if command == "-h" || command == "--help" || command == "help" {
        print!("{USAGE}");
        return Ok(());
    }

    let mut out = open_sink(out_path.as_deref())?;
    match command.as_str() {
        "doc" => doc_command(&mut out),
        "change" => change_command(&mut out),
        "sync" => sync_command(&mut out),
        "fixtures" => fixtures_command(&mut out),
        other => Err(usage_error(format!("unknown command `{other}`"))),
    }
}

/// The scripted document: a map, a list, a text object, a counter and a delete,
/// all committed by [`ACTOR_A`] with a fixed timestamp.
fn base_document() -> Result<AutoCommit, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);

    doc.put(ROOT, "title", "zautomerge oracle")?;

    let list = doc.put_object(ROOT, "list", ObjType::List)?;
    doc.insert(&list, 0, -1i64)?;
    doc.insert(&list, 1, "two")?;
    doc.insert(&list, 2, 3.5f64)?;
    doc.insert(&list, 3, true)?;
    doc.insert(&list, 4, 7u64)?;

    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.splice_text(&text, 0, 0, "hello ")?;
    doc.splice_text(&text, 6, 0, "world")?;

    // `counter` starts at zero and is then incremented, which is how the
    // reference stores a counter: a counter put followed by increment ops.
    let map = doc.put_object(ROOT, "map", ObjType::Map)?;
    doc.put(&map, "keep", "kept")?;
    doc.put(&map, "counter", counter(0)?)?;
    doc.put(&map, "drop", "dropped")?;
    doc.increment(&map, "counter", 5)?;
    doc.delete(&map, "drop")?;

    doc.commit_with(commit_options("base"));
    Ok(doc)
}

/// A counter scalar. `ScalarValue::Counter` wraps a `Counter` whose fields are
/// private to the reference, and no `From` impl builds one, so `Value::counter`
/// is the only public way in; `increment` rejects an int with
/// `MissingCounter`, so the counter has to be real.
fn counter(amount: i64) -> Result<ScalarValue, Box<dyn Error>> {
    Value::counter(amount)
        .into_scalar()
        .map_err(|_| "Value::counter did not yield a scalar".into())
}

/// Every commit carries the same timestamp and a message, so the change chunk
/// extras encoding is exercised too.
fn commit_options(message: &str) -> CommitOptions {
    CommitOptions::default().with_time(TIME).with_message(message)
}

/// `doc`: the scripted document plus two actors editing it concurrently.
fn doc_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut base = base_document()?;
    let bytes = base.save();

    let mut left = AutoCommit::load(&bytes)?.with_actor(actor(ACTOR_A)?);
    let mut right = AutoCommit::load(&bytes)?.with_actor(actor(ACTOR_B)?);

    left.put(ROOT, "from", "left")?;
    left.commit_with(commit_options("left"));
    right.put(ROOT, "from", "right")?;
    right.put(ROOT, "only_right", 42i64)?;
    right.commit_with(commit_options("right"));

    // Pulling `right` in writes a merge change by `left` depending on both
    // heads, so the saved document has two actors and concurrent history.
    left.merge(&mut right)?;

    let bytes = left.save();
    emit(
        out,
        &json!({
            "kind": "doc",
            "actors": [ACTOR_A, ACTOR_B],
            "time": TIME,
            "bytes": bytes.len(),
            "hex": hex_encode(&bytes),
        }),
    )?;
    Ok(())
}

/// `change`: the scripted document with a second commit, so `seq` and
/// `start_op` both move, plus every change in the document.
fn change_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut doc = base_document()?;
    doc.put(ROOT, "extra", 1i64)?;
    doc.commit_with(commit_options("extra"));

    for (index, mut change) in doc.get_changes(&[]).into_iter().enumerate() {
        let hash = change.hash().to_string();
        let start_op = change.start_op().get();
        let seq = change.seq();
        let time = change.timestamp();
        let deps: Vec<String> = change.deps().iter().map(ToString::to_string).collect();
        // `bytes` is the change chunk as it goes on the wire, compressed when
        // the reference chose to compress it.
        let bytes = change.bytes().into_owned();
        emit(
            out,
            &json!({
                "kind": "change",
                "index": index,
                "hash": hash,
                "start_op": start_op,
                "seq": seq,
                "time": time,
                "deps": deps,
                "bytes": bytes.len(),
                "hex": hex_encode(&bytes),
            }),
        )?;
    }
    Ok(())
}

/// `sync`: two documents, each with a local commit the other has not seen,
/// driven through [`SYNC_ROUNDS`] rounds of the sync protocol.
fn sync_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut base = base_document()?;
    let bytes = base.save();

    let mut left = AutoCommit::load(&bytes)?.with_actor(actor(ACTOR_A)?);
    let mut right = AutoCommit::load(&bytes)?.with_actor(actor(ACTOR_B)?);

    left.put(ROOT, "left", true)?;
    left.commit_with(commit_options("left"));
    right.put(ROOT, "right", "yes")?;
    right.commit_with(commit_options("right"));

    // Each side tracks what it knows about the other.
    let mut left_state = State::new();
    let mut right_state = State::new();

    for round in 1..=SYNC_ROUNDS {
        // A message is encoded, printed, and then handed to the peer by
        // decoding those exact bytes, so the printed hex is what the peer read.
        let generated = left.sync().generate_sync_message(&mut right_state);
        let sent = generated.map(Message::encode);
        emit(out, &sync_record(round, "left", "right", sent.as_deref()))?;
        if let Some(raw) = sent {
            let message = Message::decode(&raw)?;
            right.sync().receive_sync_message(&mut left_state, message)?;
        }

        let generated = right.sync().generate_sync_message(&mut left_state);
        let sent = generated.map(Message::encode);
        emit(out, &sync_record(round, "right", "left", sent.as_deref()))?;
        if let Some(raw) = sent {
            let message = Message::decode(&raw)?;
            left.sync().receive_sync_message(&mut right_state, message)?;
        }
    }

    for (side, mut doc) in [("left", left), ("right", right)] {
        let bytes = doc.save();
        emit(
            out,
            &json!({
                "kind": "sync-final",
                "side": side,
                "bytes": bytes.len(),
                "hex": hex_encode(&bytes),
            }),
        )?;
    }
    Ok(())
}

/// One direction of one sync round. A round with nothing to send still gets a
/// record, so the output is the same length on every run.
fn sync_record(round: usize, from: &str, to: &str, sent: Option<&[u8]>) -> Json {
    json!({
        "kind": "sync",
        "round": round,
        "from": from,
        "to": to,
        "sent": sent.is_some(),
        "bytes": sent.map_or(0, <[u8]>::len),
        "hex": sent.map(hex_encode).unwrap_or_default(),
    })
}

/// `fixtures`: try to load every corpus file, reporting what happened. The
/// files in [`FIXTURE_DIR`] are the corpus; `manifest.zig` lives alongside them
/// and is a Zig source file, not a document, so it is not a fixture and is not
/// reported.
fn fixtures_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let dir = Path::new(FIXTURE_DIR);
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<io::Result<_>>()?;
    // Sorted so the output does not depend on the order the filesystem hands
    // out directory entries.
    entries.sort();

    for path in entries {
        if !path.is_file() || path.extension().is_some_and(|ext| ext == "zig") {
            continue;
        }
        let outcome: Result<(), String> = match fs::read(&path) {
            Err(err) => Err(err.to_string()),
            Ok(bytes) => AutoCommit::load(&bytes)
                .map(|_| ())
                .map_err(|err| err.to_string()),
        };
        let name = path
            .strip_prefix(dir)
            .unwrap_or(path.as_path())
            .display()
            .to_string();

        let mut record = Map::new();
        record.insert("kind".into(), json!("fixture"));
        record.insert("file".into(), json!(name));
        match outcome {
            Ok(()) => {
                record.insert("result".into(), json!("ok"));
            }
            Err(message) => {
                record.insert("result".into(), json!("err"));
                record.insert("error".into(), json!(message));
            }
        }
        emit(out, &Json::Object(record))?;
    }
    Ok(())
}

/// Write one JSON record and the newline that ends it.
fn emit(out: &mut dyn Write, record: &Json) -> io::Result<()> {
    serde_json::to_writer(&mut *out, record)?;
    out.write_all(b"\n")
}

/// Open the output sink. A missing path, or `-`, means stdout.
fn open_sink(path: Option<&Path>) -> io::Result<Box<dyn Write>> {
    match path {
        Some(path) if path != Path::new("-") => {
            Ok(Box::new(io::BufWriter::new(fs::File::create(path)?)))
        }
        _ => Ok(Box::new(io::BufWriter::new(io::stdout().lock()))),
    }
}

/// Turn a hex string into a fixed actor id. The inputs are constants, so this
/// only fails if a constant is edited into something invalid.
fn actor(hex: &str) -> Result<ActorId, Box<dyn Error>> {
    Ok(ActorId::from(&decode_hex(hex)?[..]))
}

/// Decode a hex string, rejecting anything malformed rather than panicking.
fn decode_hex(text: &str) -> Result<Vec<u8>, String> {
    fn nibble(digit: u8) -> Result<u8, String> {
        match digit {
            b'0'..=b'9' => Ok(digit - b'0'),
            b'a'..=b'f' => Ok(digit - b'a' + 10),
            b'A'..=b'F' => Ok(digit - b'A' + 10),
            _ => Err(format!("`{}` is not a hex digit", digit as char)),
        }
    }
    let bytes = text.as_bytes();
    if bytes.len() % 2 != 0 {
        return Err(format!("`{text}` has an odd number of hex digits"));
    }
    bytes
        .chunks_exact(2)
        .map(|pair| Ok(nibble(pair[0])? << 4 | nibble(pair[1])?))
        .collect()
}

/// Lowercase, unprefixed hex.
fn hex_encode(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut hex = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        hex.push(DIGITS[usize::from(byte >> 4)] as char);
        hex.push(DIGITS[usize::from(byte & 0x0f)] as char);
    }
    hex
}

/// A usage error, carrying the usage text so the message is actionable.
fn usage_error(message: impl std::fmt::Display) -> Box<dyn Error> {
    format!("{message}\n\n{USAGE}").into()
}
