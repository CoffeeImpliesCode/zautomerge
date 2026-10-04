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
//! * `diff` — one record per scripted scenario: the heads diffed between and
//!   every patch the reference produced, in its own `Debug`.
//! * `converge` — the awkward merge, driven by the reference's own sync
//!   protocol: the base document, every message of every round, both sides'
//!   heads, both sides' `save()` bytes and both sides' **materialised**
//!   documents as a JSON tree.
//! * `feed` — the other direction. It reads sync messages from stdin, hands
//!   them to the same two peers `converge` drives, and prints what the
//!   reference made of them. This is the subcommand that answers whether the
//!   *port's* bytes are messages the reference acts on, which `converge` — the
//!   reference talking to itself — cannot.
//! * `converge-parallel` — the same two documents and the same merge, driven in
//!   the reference's **own** driver shape: generate from both sides, then
//!   deliver both (`sync.rs:1364-1380`). `converge` drives them one side at a
//!   time, and the round count differs between the two, so a consumer that
//!   pins a round count has to say which shape it measured.
//! * `clock` — the clock operations, reached through the only public surface
//!   that reaches them. `Clock::covers`, `Clock::merge` and `Clock::include`
//!   are `pub(crate)` (`clock.rs:12-15`, `:38-71`), so an oracle cannot call
//!   them; it asks the same questions in the same order through
//!   `get_missing_deps`, `merge` and `get_heads`, over every dependency-closed
//!   subset of a four-change history that forks in the middle.
//! * `third` — the "more than a third of the document is cheaper as one
//!   snapshot" arm (`sync.rs:225-228`), measured rather than reasoned about:
//!   for a sender with `total` changes and a peer holding a prefix of them, it
//!   prints the divisor `change_graph.len()`, the number of hashes the sender
//!   computed to send, and whether the payload that went on the wire was a
//!   change list or a whole `save()`. The peer is a real document holding a
//!   real prefix, so the sender's `their_have` and `their_heads` are whatever
//!   the peer's own message left behind.
//! * `insertat` — where the reference puts a new row at a given index of a text object, asked through
//!   `Transactable::split_block` (`transaction/inner.rs:893-929`), which is `OpSet::query_insert_at`
//!   plus one spliced row: the text left in the original object is the rows before `query.pos`. Built
//!   on a text of `"b"`, `"a"` and a bold mark written three ways. **Run in a debug profile this is
//!   also the fast/slow agreement check**: `query_insert_at` compares the prefix descent against the
//!   general walk on every call (`op_set.rs:583-598`, a `debug_assert_eq!`), so a disagreement
//!   aborts the process instead of printing one of the two answers.
//!
//! * `loadinc` — what `load_incremental` does with a save that descends from the document, with
//!   one that forks it at the same `(actor, seq)`, and with one it already holds; then
//!   `get_changes_added` run both ways round over one forked pair, so the argument order is
//!   measured rather than read off a doc comment.
//!
//! * `updocprobe` — the reference's own document reads asked at a *set of heads* rather than at the
//!   present, which is the only way to measure whether a reader is scoped: `marks_at`/`text_at` at
//!   each of a three-change history's heads, beside the unscoped `marks`/`text` at the present. It
//!   is what answers whether a mark fold that only ever reads the index is scoped, because
//!   `calculate_marks` reaches its indexed path only when there is no clock (`automerge.rs:1585`).
//!
//! * `orphans` — the three cases of `rust/automerge/tests/test_save_load_orphans.rs`: an orphan
//!   retained by `save()` and the same orphan dropped by `SaveOptions::retain_orphans = false`,
//!   each followed by the apply that supplies the missing dependency, and a change-chunk stream
//!   whose first chunk is not a document chunk. Like `sample` it owns no golden vector: nothing
//!   replays it, so what it is for is the *reference's* answers on a path no other subcommand
//!   reaches.
//!
//! * `save-interop` — the six scripted documents the port and the reference have to agree on,
//!   written through manual transactions with named commit messages: the default compressed
//!   `save()`, the heads, every change with its raw bytes, and the materialised document.
//! * `verify-save-interop` — the other direction. It reads the **port's** saves back and checks
//!   each one against a document this side builds independently, then prints this side's re-save
//!   of what it loaded. See `save_interop.rs` for why that is not an echo.
//! * `hexane-regression` — one upstream regression, recorded rather than
//!   re-derived: upstream replays seed 799 out of its own `cross_slab_fuzz`
//!   (`hexane/src/tests.rs:2711-2743`), and a port that draws from a different
//!   generator cannot produce that op list at all. This runs it on the
//!   reference's own `SmallRng`, against the reference's own `Column<u64>`,
//!   and prints the initial rows, the slab budget and — after **every** splice
//!   — the rows the reference holds and the canonical bytes `save()` gives for
//!   them. See `hexane_regression.rs`.
//!
//! The hex is always lowercase and unprefixed.

use std::error::Error;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use automerge::marks::{ExpandMark, Mark};
use automerge::sync::{Message, State, SyncDoc};
use automerge::transaction::{CommitOptions, Transactable};
use automerge::{ActorId, AutoCommit, ObjId, ObjType, ReadDoc, SaveOptions, ScalarValue, Value, ROOT};
use serde_json::{Map, Value as Json, json};

mod codec;
mod third;
mod richfuzz;
mod save_interop;
mod hexane_regression;

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

  doc        build a scripted document and print its save() bytes as hex
  change     build a scripted document and print every change with its metadata
  sync       run two documents through the sync protocol and print every message
  fixtures   load every file in test/fixtures and print ok or err
  diff       script three patch-stream scenarios and print them in the reference's Debug
  marks      expand a mark at its own two anchors and print the ranges it ends up with
  insertat   build one text of b, a bold mark and a, three ways, and report where a new row goes at
             each index, through split_block (which is query_insert_at plus one spliced row)
  updocprobe probe the reference's own document reads at a given set of heads — what `marks_at`
             and `text_at` answer at each of a three-change history's heads, and what the unscoped
             `marks` answers at the present
  converge   run the awkward merge through the sync protocol and print every message,
             both heads, both save() bytes and both materialised documents
  converge-parallel
             the same merge driven the reference's own way, generating from both sides and then
             delivering both, so the recorded round count is the parallel one
  feed       apply sync messages read from stdin to the converge peers and print what
             the reference made of them
  codec      drive the column codecs over a corpus of boundary and random values and print
             the reference's bytes, slab metadata, loader cuts, prefix sums and btree
             answers
  clock      drive the clock's covers, merge and include through the only public surface that
             reaches them (get_missing_deps, merge, get_heads), over every dependency-closed
             subset of a four-change forked history

  text       the three upstream text cases a hand-built fixture cannot express — a
             zero-width noexpand mark rewritten by update_spans, an isolate/integrate round trip
             with more than a hundred patches, and a legacy change whose insert op carries five
             grapheme clusters — each under all four text encodings

  isolateprobe
            the isolate/integrate round trip of `text` above, run again with the
            patch log drained at every step, so each record says which call put
            which patches into the log. `text` reports the sum; this attributes
            it. Like `sample` it is deliberately not a golden vector: nothing
            regenerates it, and it exists to answer which of the two halves of
            patch_to emits a given patch, with the reference's own numbers.

  richfuzz   the nine cases of tests/rich_text_fuzz_crash.rs, driven against the reference:
             the two `splice` cases on a marked text object, the zero-width mark/unmark cases
             on an empty text object, the leak of a zero-width mark into a later text object,
             the splice at a conflicted element's own length, the mark inside one multi-width
             element, and the two fixture cases — `load` on broken_zero_width_mark.automerge
             and `Automerge::rescue` on it. Each record carries the answer the reference gives
             today: the named error and its Debug payload, the text, the spans, the lengths and
             the `save()` bytes. These are the cases a fuzzer minimised out of a *panic*, so the
             question each record answers is what the fixed reference does instead

  loadinc    load a save incrementally into a document that descends from it, forks it at the
             same (actor, seq), and already has it; then run get_changes_added both ways round
  orphans    the three cases of tests/test_save_load_orphans.rs — an orphan retained by save(),
             the same orphan discarded by SaveOptions::retain_orphans, and a change-chunk
             stream whose first chunk is not a document chunk — each run through the reference
  third      measure the whole-document arm (sync.rs:225-228) at a few sizes either side of its
             threshold, with a peer built by really holding a prefix of the sender's history

  sample     the operation sequence `src/doc.zig`'s `buildSample` fixture claims to encode,
             built here through the public writer of the reference and printed as `save()` bytes
             and a materialised document. It is what answers whether the reference writer would
             have produced these bytes for a hand-built fixture, and it is deliberately not a
             golden vector: nothing regenerates it.

  loadhex    load a save given as lowercase hex on stdin and print the reference materialised
             document, its heads, and the bytes it re-saves. It is how the reference is asked
             what it makes of save() bytes another implementation produced.

  save-interop
             build the six interoperability scenarios and print, for each, the default
             compressed save() bytes, the heads, every change with its raw bytes and the
             materialised document
  verify-save-interop
             read the port's own saves as {\"kind\":\"port-save\",\"scenario\":...,\"hex\":...} records
             on stdin, check each against a document built here independently, and print this
             side's re-save of what it loaded

  hexane-regression
             replay upstream's seed 799 out of `cross_slab_fuzz`
             (hexane/src/tests.rs:2711-2743) on the reference's own `SmallRng`, and print the
             reference column's rows and its canonical `save()` bytes after every splice

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
        "marks" => marks_command(&mut out),
        "updocprobe" => updocprobe_command(&mut out),
        "insertat" => insertat_command(&mut out),
        "diff" => diff_command(&mut out),
        "converge" => converge_command(&mut out),
        "converge-parallel" => converge_parallel_command(&mut out),
        "feed" => feed_command(&mut out, &mut io::stdin().lock()),
        "clock" => clock_command(&mut out),
        "codec" => codec::codec_command(&mut out),
        "loadinc" => loadinc_command(&mut out),
        "orphans" => orphans_command(&mut out),
        "third" => third::third_command(&mut out),
        "richfuzz" => richfuzz::richfuzz_command(&mut out),
        "text" => text_command(&mut out),
        "isolateprobe" => isolate_probe(&mut out),
        "sample" => sample_command(&mut out),
        "loadhex" => loadhex_command(&mut out, &mut io::stdin().lock()),
        "save-interop" => save_interop::save_interop_command(&mut out),
        "verify-save-interop" => {
            save_interop::verify_save_interop_command(&mut out, &mut io::stdin().lock())
        }
        "hexane-regression" => hexane_regression::hexane_regression_command(&mut out),
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

    // Pulling `right` in **applies** its change and writes no change of `left`'s own
    // (`merge` is `get_changes_added` plus `apply_changes`, `automerge.rs:1115-1131`), so the
    // saved document has two actors and a forked history with both commits still heads.
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
        emit(out, &sync_record("sync", round, "left", "right", sent.as_deref()))?;
        if let Some(raw) = sent {
            let message = Message::decode(&raw)?;
            right.sync().receive_sync_message(&mut left_state, message)?;
        }

        let generated = right.sync().generate_sync_message(&mut left_state);
        let sent = generated.map(Message::encode);
        emit(out, &sync_record("sync", round, "right", "left", sent.as_deref()))?;
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
fn sync_record(kind: &str, round: usize, from: &str, to: &str, sent: Option<&[u8]>) -> Json {
    json!({
        "kind": kind,
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

/// `loadinc`: what [`Automerge::load_incremental`] does with a save that
/// **descends** from the document it is loaded into, and with a save that
/// **forks** it at the same `(actor, seq)` — the case a two-document
/// comparison has to get right, because a fork is two different changes
/// claiming one slot of one actor's history, and
/// [`has_actor_seq`](../../github-automerge-automerge/rust/automerge/src/automerge.rs)
/// is what decides it (`BatchApply::new`, `op_set2/change/batch.rs:1073-1076`).
///
/// The third case is the same save loaded into a document that already has it,
/// which is what a peer re-announcing a change looks like and must cost
/// nothing.
///
/// The `getchangesadded` record settles the argument order of
/// `get_changes_added` by running it both ways round over one pair of forked
/// documents and printing which document's change came back each time. The
/// reference documents it as "Get changes in `other` that are not in `self`"
/// (`automerge.rs:1531`, `autocommit.rs:640`); this measures it.
fn loadinc_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    // One change by ACTOR_A at (ACTOR_A, seq 1).
    let mut first = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    first.put(ROOT, "string", "hello")?;
    first.commit_with(commit_options("first"));
    let first_bytes = first.save();

    // The descendant: the same history with one more change on top of it, by
    // a second actor, so loading it incrementally is the ordinary case.
    let mut descendant = AutoCommit::load(&first_bytes)?.with_actor(actor(ACTOR_B)?);
    descendant.put(ROOT, "later", "x")?;
    descendant.commit_with(commit_options("descendant"));
    let descendant_bytes = descendant.save();

    // The fork: a *different* change at (ACTOR_A, seq 1). Same actor, same
    // sequence number, different contents — so a different hash, and the pair
    // is exactly what a duplicate sequence number is.
    let mut fork = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    fork.put(ROOT, "string", "goodbye")?;
    fork.commit_with(commit_options("fork"));
    let fork_bytes = fork.save();

    let mut cases: Vec<(&str, Vec<u8>, Vec<u8>)> = vec![
        ("descendant", first_bytes.clone(), descendant_bytes.clone()),
        ("fork", first_bytes.clone(), fork_bytes.clone()),
        ("same-again", first_bytes.clone(), first_bytes.clone()),
    ];
    // And the direction that matters for a merge: the fork loaded into the
    // descendant, so the document is neither empty nor an ancestor of the save.
    cases.push(("into-descendant", descendant_bytes.clone(), fork_bytes));

    for (case, base_bytes, added_bytes) in cases {
        let mut doc = AutoCommit::load(&base_bytes)?;
        let outcome = doc.load_incremental(&added_bytes);
        let mut record = Map::new();
        record.insert("kind".into(), json!("loadinc"));
        record.insert("case".into(), json!(case));
        match outcome {
            Ok(rows) => {
                record.insert("result".into(), json!("ok"));
                record.insert("rows".into(), json!(rows));
                record.insert(
                    "heads".into(),
                    json!(doc.get_heads()
                        .iter()
                        .map(|hash| hash.to_string())
                        .collect::<Vec<_>>()),
                );
            }
            Err(err) => {
                record.insert("result".into(), json!("err"));
                record.insert("error".into(), json!(err.to_string()));
            }
        }
        emit(out, &Json::Object(record))?;
    }

    // `get_changes_added` both ways round. `left` holds ACTOR_B's change on top
    // of `first`; `right` holds ACTOR_A's different change at the same seq.
    let mut left = AutoCommit::load(&first_bytes)?.with_actor(actor(ACTOR_B)?);
    left.put(ROOT, "from_left", "x")?;
    left.commit_with(commit_options("left"));
    let mut right = AutoCommit::load(&first_bytes)?.with_actor(actor(ACTOR_A)?);
    right.put(ROOT, "from_right", "y")?;
    right.commit_with(commit_options("right"));

    // Each side committed exactly one change on top of `first`, so its head is
    // that change's hash.
    let left_change = left.get_heads()[0].to_string();
    let right_change = right.get_heads()[0].to_string();

    let forward = left
        .get_changes_added(&mut right)
        .iter()
        .map(|change| change.hash().to_string())
        .collect::<Vec<_>>();
    let backward = right
        .get_changes_added(&mut left)
        .iter()
        .map(|change| change.hash().to_string())
        .collect::<Vec<_>>();
    let merged = left
        .merge(&mut right)
        .map(|heads| heads.iter().map(|hash| hash.to_string()).collect::<Vec<_>>())
        .map_err(|err| err.to_string());

    emit(
        out,
        &json!({
            "kind": "getchangesadded",
            "left_change": left_change,
            "right_change": right_change,
            "left_get_changes_added_right": forward,
            "right_get_changes_added_left": backward,
            "left_merge_right_heads": merged,
        }),
    )?;
    Ok(())
}

// ── orphans ──────────────────────────────────────────────────────────────────

/// The fixture both of the first two cases of
/// `rust/automerge/tests/test_save_load_orphans.rs` build
/// (`test_save_load_orphans.rs`:9-27): a document holding one change, a fork of
/// it that makes two more, and the **second** of those two applied to the
/// first document on its own.
///
/// That is the orphan: `change2` depends on `change1`, `doc1` never sees
/// `change1`, so `apply_changes` queues `change2` rather than applying it
/// (`op_set2/change/batch.rs`:1103-1105). The function returns `doc1` with
/// `change1` still in the caller's hands, which is the only way either case can
/// supply it afterwards.
///
/// **The actors are pinned** where upstream's are random. `AutoCommit::new`
/// draws an actor from the system entropy source
/// ([`automerge.rs`:314](../../github-automerge-automerge/rust/automerge/src/automerge.rs))
/// and `Automerge::fork` draws another, so a run of this subcommand would
/// produce different hashes every time and the record could not be compared to
/// anything. Nothing below depends on the bytes, only on the *shape* — a
/// queued orphan, a retained one and a discarded one — so pinning them changes
/// no answer.
fn doc_with_orphans() -> Result<(AutoCommit, automerge::Change), Box<dyn Error>> {
    let mut doc1 = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc1.put(ROOT, "key", "value")?;
    doc1.commit_with(commit_options("value"));

    // `let mut doc2 = doc1.fork();`
    let mut doc2 = doc1.fork().with_actor(actor(ACTOR_B)?);
    doc2.put(ROOT, "key", "value2")?;
    doc2.commit_with(commit_options("value2"));
    let change1 = doc2
        .get_last_local_change()
        .ok_or("the fork made no change")?;
    doc2.put(ROOT, "key", "value3")?;
    doc2.commit_with(commit_options("value3"));
    let change2 = doc2
        .get_last_local_change()
        .ok_or("the fork made no second change")?;

    // "Apply the second change, which means it will be orphaned because doc1
    // doesn't have the first change" (`test_save_load_orphans.rs`:20-21).
    doc1.apply_changes(vec![change2])?;
    // **The orphan is queued, not applied**, and this is where that is proved
    // rather than assumed: `apply_changes` reports no count (its `Result` is
    // `()`), so the only observable is `get_missing_deps`, which chains the
    // queue in front of its argument (`automerge.rs`:2290-2291) and therefore
    // names `change1` — the dependency a queued `change2` is waiting for — and
    // nothing at all if `change2` had been applied.
    let waiting = queued_deps(&doc1);
    if waiting != vec![change1.hash().to_string()] {
        return Err(format!("the second change was not queued as an orphan: {waiting:?}").into());
    }
    Ok((doc1, change1))
}

/// What the document reads at `ROOT`, `"key"`, as JSON: the same shape every
/// other subcommand's materialisation uses, so a reader does not have to learn
/// a second spelling.
fn key_value(doc: &AutoCommit) -> Result<Json, Box<dyn Error>> {
    Ok(match doc.get(&ROOT, "key")? {
        None => Json::Null,
        Some((value, _)) => match value {
            Value::Scalar(scalar) => {
                json!({ "type": scalar_type(&scalar), "value": render_scalar(&scalar) })
            }
            other => {
                json!({ "type": "object", "value": format!("{other:?}") })
            }
        },
    })
}

/// The hashes the document is missing with **no** heads named
/// ([`get_missing_deps`](../../github-automerge-automerge/rust/automerge/src/read.rs):302).
///
/// This is the observable that says whether an orphan survived a round trip,
/// and it is the right one: the implementation chains **every queued change** in
/// front of the named heads
/// ([`automerge.rs`:2290-2291](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
/// so a document that came back holding `change2` in its queue answers with
/// `change1`'s hash — the dependency the peer still has to send — and a
/// document that dropped it answers with nothing.
fn queued_deps(doc: &AutoCommit) -> Vec<String> {
    doc.get_missing_deps(&[])
        .iter()
        .map(|hash| hash.to_string())
        .collect()
}

/// `orphans`: the three cases of
/// [`tests/test_save_load_orphans.rs`](../../github-automerge-automerge/rust/automerge/tests/test_save_load_orphans.rs),
/// driven through the reference and printed as records.
///
/// * **`save_orphaned_changes`** (`:29-46`) and **`discard_orphans`** (`:48-69`)
///   are the same fixture saved twice, once with the default
///   `SaveOptions { retain_orphans: true, … }` and once with
///   `retain_orphans: false`. The difference in the assertion is the whole
///   subject: with the orphan retained the save carries `change2`'s bytes
///   appended after the document chunk
///   ([`automerge.rs`:1155-1158](../../github-automerge-automerge/rust/automerge/src/automerge.rs)),
///   so supplying `change1` afterwards drains the queue and `"key"` reads
///   `"value3"`; with the orphan discarded the same apply leaves `"value2"`.
///   Each record therefore prints `saved_bytes` and `missing_before`, because
///   a value that happens to come out right does not say which of the two saves
///   the reference actually performed.
/// * **`load_incremental_change_without_deps_throws`** (`:71-83`) is the
///   first-chunk rule. `load` accepts an orphan stream **only** when its first
///   chunk is a document chunk
///   ([`automerge.rs`:976-982](../../github-automerge-automerge/rust/automerge/src/automerge.rs)):
///   a change-chunk stream whose changes leave anything queued is
///   `AutomergeError::MissingDeps`. The record prints the chunk type byte at
///   offset 8 of the save as well as the error, so the answer is attributable
///   to the stream shape rather than to an assumption about it.
///
/// It owns no golden vector and is not in `golden_vectors` in [`build.zig`](../../build.zig):
/// nothing replays it, so recording one would be a file no check compares.
fn orphans_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    for (label, retain_orphans) in [
        ("save_orphaned_changes", true),
        ("discard_orphans", false),
    ] {
        let (mut doc, missing_change) = doc_with_orphans()?;
        let missing_hash = missing_change.hash().to_string();
        let saved = doc.save_with_options(SaveOptions {
            retain_orphans,
            ..Default::default()
        });

        let mut loaded = AutoCommit::load(&saved)?;
        // Before the dependency arrives, and after it does. The first list is
        // the orphan still queued — or gone.
        let before = queued_deps(&loaded);
        let value_before = key_value(&loaded)?;
        let applied = loaded.apply_changes(vec![missing_change]);
        emit(
            out,
            &json!({
                "kind": "orphans",
                "case": label,
                "retain_orphans": retain_orphans,
                "missing_change": missing_hash,
                "saved_bytes": saved.len(),
                "saved_first_chunk_type": saved.get(8).copied(),
                "missing_before_apply": before,
                "value_before_apply": value_before,
                "applied": match applied {
                    Ok(()) => json!("ok"),
                    Err(err) => json!(err.to_string()),
                },
                "value_after_apply": key_value(&loaded)?,
                "missing_after_apply": queued_deps(&loaded),
            }),
        )?;
    }

    // The incremental arm, verbatim from `:71-83`: one change, saved
    // incrementally, a second change, saved incrementally again. The second
    // save is a bare change chunk whose first change depends on a change no
    // reader of that stream has.
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "key", "value")?;
    doc.commit_with(commit_options("value"));
    let first_save = doc.save_incremental();
    doc.put(ROOT, "key", "value2")?;
    doc.commit_with(commit_options("value2"));
    let orphan = doc.save_incremental();

    let (result, detail) = match AutoCommit::load(&orphan) {
        Ok(loaded) => (
            "ok",
            json!({ "value": key_value(&loaded)? }),
        ),
        Err(err) => (
            "err",
            json!({ "debug": format!("{err:?}"), "display": err.to_string() }),
        ),
    };
    emit(
        out,
        &json!({
            "kind": "orphans",
            "case": "load_incremental_change_without_deps_throws",
            "first_save_bytes": first_save.len(),
            "first_save_first_chunk_type": first_save.get(8).copied(),
            "orphan_bytes": orphan.len(),
            "orphan_first_chunk_type": orphan.get(8).copied(),
            "result": result,
            "detail": detail,
        }),
    )?;
    Ok(())
}

/// `marks`: one mark over `[1, 3)` of a four-character text object, then a
/// single character spliced in **at the mark's own start or at its own end**,
/// under each of the four expand flags.
///
/// The anchors are the whole question. A character spliced *inside* a mark's
/// span is inside it whether or not either anchor expands, so it reads the
/// same answer for all four flags; the anchors are the only places the flag is
/// observable. The ranges are printed in the **text's own coordinates**, which
/// is where the answer lives: a character spliced before a mark shifts the
/// mark's indices without changing which characters it covers, so a range that
/// has not moved in those coordinates has not stayed put.
fn marks_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let cases: [(&str, ExpandMark, usize); 6] = [
        ("none@start", ExpandMark::None, 1),
        ("before@start", ExpandMark::Before, 1),
        ("after@start", ExpandMark::After, 1),
        ("none@end", ExpandMark::None, 3),
        ("before@end", ExpandMark::Before, 3),
        ("both@end", ExpandMark::Both, 3),
    ];
    for (label, expand, at) in cases {
        let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
        let text = doc.put_object(ROOT, "t", ObjType::Text)?;
        doc.splice_text(&text, 0, 0, "abcd")?;
        doc.mark(&text, Mark::new("em".to_string(), true, 1, 3), expand)?;
        doc.splice_text(&text, at, 0, "X")?;
        doc.commit_with(commit_options(label));

        let found: Vec<Json> = doc
            .marks(&text)?
            .iter()
            .map(|m| json!({ "name": m.name.as_str(), "start": m.start, "end": m.end }))
            .collect();
        emit(
            out,
            &json!({
                "kind": "marks",
                "case": label,
                "at": at,
                "text": doc.text(&text)?,
                "marks": found,
            }),
        )?;
    }
    Ok(())
}

/// `insertat`: **where the reference puts a new row at a given index of a text
/// object**, asked through the one public call that reaches
/// `OpSet::query_insert_at` and reports the answer in the document's own terms.
///
/// `Transactable::split_block` (`transaction.rs:426-435` →
/// `transaction/inner.rs:893-929`) is exactly `query_insert_at` plus one row:
/// it takes `query.pos` and `query.elemid` and splices a map block in there
/// (`inner.rs:905-916`). **The text left in the original object is therefore
/// the rows that came before `query.pos`**, which is the answer written in a
/// form a caller can see.
///
/// **A debug profile makes this an agreement check, not just an answer.**
/// `query_insert_at` compares the prefix-descent result against the general
/// walk's on every call (`op_set.rs:583-598`, a `debug_assert_eq!`), so a
/// disagreement between the two paths aborts the process rather than printing
/// one of them. Build this subcommand's run with the dev profile to keep it.
fn insertat_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    // The three documents are the same text — `"b"`, then `"a"` — with the
    // mark written three ways. The order matters: `"ba"` is built first and the
    // mark afterwards, so `mark(.., {1, 1}, Before)` resolves index 1 through
    // the fast path and lands the begin **between** `"b"` and `"a"`, which is
    // the row order `insert_mark_end_after` (`inner.rs:404-430`) then extends
    // with the end at `begin.pos + 1`.
    let cases: [(&str, Option<(usize, usize)>); 3] = [
        ("plain", None),
        ("zero-width-bold", Some((1, 1))),
        ("bold-over-a", Some((1, 2))),
    ];
    for (label, span) in cases {
        let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
        let text = doc.put_object(ROOT, "t", ObjType::Text)?;
        doc.splice_text(&text, 0, 0, "b")?;
        doc.splice_text(&text, 1, 0, "a")?;
        if let Some((start, end)) = span {
            doc.mark(&text, Mark::new("bold".to_string(), true, start, end), ExpandMark::Before)?;
        }

        let before = json!({
            "text": doc.text(&text)?,
            "marks": mark_nodes(&doc.marks(&text)?),
        });

        let mut readings = Vec::new();
        for index in 0..=2usize {
            let mut probe = doc.clone();
            let (ok, left, detail) = match probe.split_block(&text, index) {
                Ok(_) => (true, probe.text(&text)?, String::new()),
                Err(err) => (false, String::new(), format!("{err}")),
            };
            let left_len = if ok { probe.length(&text) } else { 0 };
            readings.push(json!({
                "index": index,
                "ok": ok,
                // **`left` is the whole answer.** A new row spliced at
                // `query.pos` leaves `probe.text(&text)` holding exactly the
                // rows before that position, so `"b"` means the row went in
                // right after `"b"` and `"ba"` means it went past both.
                "left": left,
                "left_len": left_len,
                "detail": detail,
            }));
        }

        emit(
            out,
            &json!({
                "kind": "insertat",
                "case": label,
                "before": before,
                "readings": readings,
            }),
        )?;
    }
    Ok(())
}

/// Every mark as a JSON node: the name, the two indexes, and the value.
///
/// **Sorted by `(start, end, name)`, and not in the reference's own order**, for
/// the same reason a map's keys are: the set of runs is the observable and the
/// order `MarkAccumulator` hands them over in is not. The **value** is printed
/// here and not in [`marks_command`], because the two answer different
/// questions — a mark's value is what decides whether two runs of one name
/// coalesce ([`MarkAccumulator::add`](src/marks.rs:87-102)), so it changes the
/// *number* of runs rather than their shape, and a consumer comparing runs sees
/// it there.
fn mark_nodes(marks: &[Mark]) -> Vec<Json> {
    let mut sorted: Vec<(usize, usize, String, Json)> = marks
        .iter()
        .map(|m| {
            let node = json!({
                "name": m.name.as_str(),
                "start": m.start,
                "end": m.end,
                "value": render_scalar(&m.value),
            });
            (m.start, m.end, m.name.to_string(), node)
        })
        .collect();
    sorted.sort_by(|a, b| (a.0, a.1, &a.2).cmp(&(b.0, b.1, &b.2)));
    sorted.into_iter().map(|(_, _, _, node)| node).collect()
}

/// `updocprobe`: what the reference answers for a text object's marks **at each
/// of a history's own heads**, and at the present.
///
/// This is the subcommand that answers whether a mark read is scoped at all,
/// and it is the one measurement the port's mark fold cannot be checked
/// against any other way. `calculate_marks` reaches the indexed
/// `calculate_marks_fast` only when `clock.is_none() && seq_type == Text`
/// (`automerge.rs:1585`) and walks the object's rows as the clock sees them
/// otherwise (`:1595-1631`), so **the present and an older head of one
/// document are two different questions**, and a reader that only ever reads
/// the index answers the present one for both.
///
/// The history is three commits over one text object, and each commit changes
/// what a mark read can answer, so all three readings are distinct from each
/// other and from the present:
///
/// * **first** — the text, and one mark over `[0, 3)`.
/// * **second** — text spliced into the middle and a second mark over the
///   splice. Read at `first`, neither the splice nor the mark is in the
///   document; read at the present, both are. **This is the case a reader that
///   ignores the clock gets wrong.**
/// * **third** — an unmark over the second mark. A tombstone is not a mark, so
///   the run disappears rather than becoming a run of `null`
///   ([`into_iter_no_unmark`](src/marks.rs:76-85)) — **and at `first` and
///   `second` that run is still there**, because the unmark is under neither of
///   those clocks.
///
/// The script is the one `src/read.zig`'s own isolation fixture builds, so the
/// two are comparable reading for reading: the same text, the same splices and
/// the same marks, written through two different writers.
fn updocprobe_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    let text = doc.put_object(ROOT, "t", ObjType::Text)?;
    doc.splice_text(&text, 0, 0, "aaabbbccc")?;
    doc.mark(&text, Mark::new("bold".to_string(), true, 0, 3), ExpandMark::Both)?;
    doc.commit_with(commit_options("first"));
    let first = doc.get_heads();

    doc.splice_text(&text, 3, 0, "QQQ")?;
    doc.mark(&text, Mark::new("italic".to_string(), true, 3, 6), ExpandMark::Both)?;
    doc.commit_with(commit_options("second"));
    let second = doc.get_heads();

    // **`ExpandMark::None`, and the reason is the boundary.** An unmark carries
    // the same expand flag a mark does, and `Both` at an index that is also the
    // edge of another run reaches *that* run as well — measured, not reasoned:
    // the reference answers `bold [3, 6)` for the document this builds with
    // `Both`, which is the second mark's range, not the one that was unmarked.
    // `None` is the flag that makes this scenario about the clock and not about
    // how two adjacent marks at one boundary resolve.
    doc.unmark(&text, "italic", 3, 6, ExpandMark::None)?;
    doc.commit_with(commit_options("third"));
    let third = doc.get_heads();

    // **The present is read through the unscoped methods**, so it is the
    // reference's own `marks`/`text` and not a clock built from the present's
    // heads: passing the current heads is a *different* call with a different
    // answer path (`autocommit.rs:794-813`), and this one is the one whose arm
    // the port has to reach by leaving the clock absent.
    let present = json!({
        "text": doc.text(&text)?,
        "marks": mark_nodes(&doc.marks(&text)?),
    });

    let mut readings = Vec::new();
    for (label, heads) in [("first", &first), ("second", &second), ("third", &third)] {
        readings.push(json!({
            "at": label,
            "heads": head_text(heads),
            "text": doc.text_at(&text, heads)?,
            "length": doc.length_at(&text, heads),
            "marks": mark_nodes(&doc.marks_at(&text, heads)?),
        }));
    }

    Ok(emit(
        out,
        &json!({
            "kind": "updocprobe",
            "scenario": "atheads",
            "present": present,
            "readings": readings,
        }),
    )?)
}

/// One scenario's two head lists and the patches between them.
struct DiffRun {
    /// The heads the diff started from, lowercase hex.
    before: Vec<String>,
    /// The heads it ended at, lowercase hex.
    after: Vec<String>,
    /// One [`automerge::Patch`] per element, in the reference's own `Debug`.
    patches: Vec<String>,
}

/// A head list as the hex the `change` subcommand already prints.
///
/// **The list and not the document**, because `AutoCommit::get_heads` takes
/// `&mut self` and these three scenarios each need their heads twice — once to
/// diff between and once to print — without the borrow.
fn head_text(hashes: &[automerge::ChangeHash]) -> Vec<String> {
    hashes.iter().map(ToString::to_string).collect()
}

/// A patch stream in the reference's own `Debug`, which is what makes the
/// contents checkable: the object, the whole path and every field of the action.
///
/// **`Debug` and not the port's rendering.** The two formats differ — upstream
/// derives it and `patch.rs:91-93` says so — so what a consumer compares is the
/// *content* of each line, which is the same question either format answers.
fn debug_patches(patches: &[automerge::Patch]) -> Vec<String> {
    patches.iter().map(|p| format!("{p:?}")).collect()
}

/// `diff`: the patch streams `Automerge::diff` and `AutoCommit::diff_incremental`
/// produce, scripted so that the op ids are the ones the port's own fixtures
/// use.
///
/// **Three scenarios and each answers a different question:**
///
/// * `map` — one register added to a root map: the simplest patch there is, and
///   the one that shows a `Diff::Add` reaching the log.
/// * `nested` — an element inserted into a list that **already existed**,
///   beside a register added to the same root. This is the scenario that proves
///   the walk descends: nothing in the root's own diff says the list changed,
///   because the list's register is `Diff::Same`.
/// * `incremental` — one register added, but read through
///   `update_diff_cursor` and `diff_incremental`, so the stream comes from the
///   events the document **recorded** as it moved rather than from a walk over
///   two heads. It is the scenario that cannot come out right unless
///   `apply_changes` feeds the log.
///
/// * `insertopid-cursor` / `insertopid-applylog` — the same list, filled the
///   same way, read back through two different histories: one where
///   `update_diff_cursor` ran between the two commits, and one where a fresh
///   document and a fresh active log were fed both changes. They are two
///   answers to a question the upstream case `regression_insert_opid` does not
///   separate, so a port of that case has to say which one it is a port of.
fn diff_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    for scenario in [
        "map",
        "nested",
        "incremental",
        "insertopid-cursor",
        "insertopid-applylog",
        "localmerge",
    ] {
        let run = match scenario {
            "map" => diff_map()?,
            "nested" => diff_nested()?,
            "insertopid-cursor" => diff_insert_opid_cursor()?,
            "insertopid-applylog" => diff_insert_opid_applylog()?,
            "localmerge" => diff_local_merge()?,
            _ => diff_incremental()?,
        };
        emit(
            out,
            &json!({
                "kind": "diff",
                "scenario": scenario,
                "before": run.before,
                "after": run.after,
                "patches": run.patches,
            }),
        )?;
    }
    Ok(())
}

/// `map`: one register added to a root map by a second actor.
fn diff_map() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "a", "one")?;
    doc.commit_with(commit_options("base"));

    let before = doc.get_heads();
    let before_text = head_text(&before);

    // A second actor, so the patch's id carries an actor index that is not
    // zero and the document really has two of them.
    doc.set_actor(actor(ACTOR_B)?);
    doc.put(ROOT, "b", "two")?;
    doc.commit_with(commit_options("added"));

    let after = doc.get_heads();
    let after_text = head_text(&after);
    let patches = debug_patches(&doc.diff(&before, &after));
    Ok(DiffRun { before: before_text, after: after_text, patches })
}

/// `nested`: an insert into a list the base change already made, and a register
/// added beside it in the same change.
///
/// **The insert comes first**, so the insert's op id is the lower one and the
/// two are distinguishable by id alone.
fn diff_nested() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    let list = doc.put_object(ROOT, "l", ObjType::List)?;
    doc.commit_with(commit_options("base"));

    let before = doc.get_heads();
    let before_text = head_text(&before);

    doc.set_actor(actor(ACTOR_B)?);
    doc.insert(&list, 0, "x")?;
    doc.put(ROOT, "k", "v")?;
    doc.commit_with(commit_options("added"));

    let after = doc.get_heads();
    let after_text = head_text(&after);
    let patches = debug_patches(&doc.diff(&before, &after));
    Ok(DiffRun { before: before_text, after: after_text, patches })
}

/// `incremental`: `map`'s edit, but a peer's change applied through
/// `apply_changes` and read with `diff_incremental`.
///
/// **A peer and not a local commit**, because the recording path under test is
/// `apply_changes`, which upstream routes into `self.patch_log`
/// (`autocommit.rs:498`); a local commit takes a different road — it merges a
/// branch log built by the transaction (`autocommit.rs:732`) — and would
/// answer a different question.
///
/// **The cursor goes down before the edit**, which is the whole point: from that
/// moment the document records what it applies, and the incremental diff reads
/// those events back.
fn diff_incremental() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "a", "one")?;
    doc.commit_with(commit_options("base"));

    let before = doc.get_heads();
    let before_text = head_text(&before);
    doc.update_diff_cursor();

    let mut peer = AutoCommit::new().with_actor(actor(ACTOR_B)?);
    peer.put(ROOT, "b", "two")?;
    peer.commit_with(commit_options("added"));
    let incoming: Vec<_> = peer.get_changes(&[]).into_iter().collect();
    doc.apply_changes(incoming)?;

    let after = doc.get_heads();
    let after_text = head_text(&after);
    let patches = debug_patches(&doc.diff_incremental());
    Ok(DiffRun { before: before_text, after: after_text, patches })
}
/// **How many elements the two `insertopid` scenarios fill the list with.** It
/// is the upstream case's own `N` (`tests/test.rs:2375`), and a count the
/// scenarios and the port's test can both read off one number is a count a
/// transcription cannot quietly change.
const INSERT_OPID_N: usize = 30;

/// `insertopid-cursor`: the list made, `update_diff_cursor` run, the list
/// filled, and the document's **own** log read back.
///
/// **The order is the measurement.** `update_diff_cursor` truncates the log
/// (`autocommit.rs:199-206`, `patch_log.rs`:531-538) and puts the cursor at the
/// present, so everything the log can report is written after that line — and
/// the `PutMap` that made the list was written before it. Whether the
/// reference still reports that put is the question this scenario exists to
/// answer, and the answer decides whether a patch stream read this way is
/// allowed to contain a patch about a change the cursor already covers.
///
/// **`diff_incremental` and not `make_patches`**, because upstream's
/// `AutoCommit::make_patches` takes a caller's log and not the document's own
/// ([`autocommit.rs`:214-217](../../../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// and the document's own log is private. `diff_incremental` is the one public
/// call that reads it (`autocommit.rs:280`, `:283`), and it reads it exactly
/// when `after == get_heads()` and `before == diff_cursor()` — which is the
/// state this scenario puts the document in.
fn diff_insert_opid_cursor() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    let list = doc.put_object(ROOT, "list", ObjType::List)?;
    doc.commit_with(commit_options("list"));

    let before = doc.get_heads();
    let before_text = head_text(&before);
    doc.update_diff_cursor();

    for i in 0..=INSERT_OPID_N {
        doc.insert(&list, i, ScalarValue::Null)?;
        doc.put(&list, i, ScalarValue::Int(i as i64))?;
    }
    doc.commit_with(commit_options("fill"));

    let after = doc.get_heads();
    let after_text = head_text(&after);
    let patches = debug_patches(&doc.diff_incremental());
    Ok(DiffRun { before: before_text, after: after_text, patches })
}

/// `insertopid-applylog`: the upstream case's own shape — a **fresh** document
/// and a **fresh active log**, fed both changes through
/// `apply_changes_log_patches` in the order they were made, and then read back
/// with `make_patches` (`tests/test.rs`:2383-2390`, `:2406`).
///
/// **This is the shape that has two patches**, and the one a port of the case
/// is trying to reproduce. It never calls `update_diff_cursor`, so nothing
/// truncates the log and the `PutMap` the first change recorded is still in it
/// when the second change's events are read back beside it.
fn diff_insert_opid_applylog() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    let list = doc.put_object(ROOT, "list", ObjType::List)?;
    doc.commit_with(commit_options("list"));
    let change1 = doc.get_last_local_change().ok_or("no first change")?;

    for i in 0..=INSERT_OPID_N {
        doc.insert(&list, i, ScalarValue::Null)?;
        doc.put(&list, i, ScalarValue::Int(i as i64))?;
    }
    doc.commit_with(commit_options("fill"));
    let change2 = doc.get_last_local_change().ok_or("no second change")?;

    let mut fresh = automerge::Automerge::new();
    let before = vec![];
    let mut patch_log = automerge::PatchLog::active();
    fresh.apply_changes_log_patches(vec![change1], &mut patch_log)?;
    fresh.apply_changes_log_patches(vec![change2], &mut patch_log)?;
    let after = fresh.get_heads();
    let patches = debug_patches(&fresh.make_patches(&mut patch_log));
    Ok(DiffRun { before, after: head_text(&after), patches })
}

/// `localmerge`: a local commit and then a **peer's** change applied after it,
/// read back through the document's own log.
///
/// **The question is the order.** Upstream keeps *one* event list, and
/// `AutoCommit::commit_with` merges the transaction's branch log into it at the
/// moment the commit returns ([`autocommit.rs:728-739`](../../../../github-automerge-automerge/rust/automerge/src/autocommit.rs)),
/// so the local change's events are already in the list when
/// `apply_changes` appends the peer's. A patch stream is order-sensitive — a
/// consumer applies the patches in the order it receives them — so "the local
/// change's patches come first" is a property worth measuring rather than
/// assuming, and it is the one a log that keeps local patches in a *second*
/// list has to earn.
fn diff_local_merge() -> Result<DiffRun, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "a", "one")?;
    doc.commit_with(commit_options("base"));

    let before = doc.get_heads();
    let before_text = head_text(&before);
    doc.update_diff_cursor();

    // **The local change**, recorded by `commit_with` merging the
    // transaction's branch log.
    doc.put(ROOT, "b", "two")?;
    doc.commit_with(commit_options("local"));

    // **And then the peer's**, recorded by `apply_changes` — which runs after
    // the local commit, and so appends after it in the one list upstream keeps.
    let mut peer = AutoCommit::new().with_actor(actor(ACTOR_B)?);
    peer.put(ROOT, "c", "three")?;
    peer.commit_with(commit_options("remote"));
    let incoming: Vec<_> = peer.get_changes(&[]).into_iter().collect();
    doc.apply_changes(incoming)?;

    let after = doc.get_heads();
    let after_text = head_text(&after);
    let patches = debug_patches(&doc.diff_incremental());
    Ok(DiffRun { before: before_text, after: after_text, patches })
}

// ── converge ─────────────────────────────────────────────────────────────────

/// How many rounds the `converge` subcommand runs. The exchange reaches its
/// fixed point inside this; a round with nothing to say is still reported, so
/// the transcript has the same length on every run and a consumer can tell
/// "converged" from "the script stopped early".
const CONVERGE_ROUNDS: usize = 6;

/// The base document the two `converge` peers start from, and the bytes both
/// [`converge_left`] and [`converge_right`] load.
///
/// **Its own document, not [`base_document`]**, and the difference is the
/// scenario: `base_document` has already deleted its one deletable key
/// (`main.rs:142`), and the awkward case this exists for needs a key one side
/// *deletes* while the other *edits* it. Every key here is named after the case
/// that uses it, so a reader can check the script against the table.
fn converge_base() -> Result<AutoCommit, Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "contested", "base")?;
    doc.put(ROOT, "doomed", "doomed")?;
    doc.put(ROOT, "counter", counter(10)?)?;
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.splice_text(&text, 0, 0, "abcdefgh")?;
    // A nested map and a list, so the materialisation walk has to descend: a
    // read path that stops at the root calls two documents equal when the
    // difference is one level down.
    let map = doc.put_object(ROOT, "nested", ObjType::Map)?;
    doc.put(&map, "inner", "x")?;
    let list = doc.put_object(ROOT, "list", ObjType::List)?;
    doc.insert(&list, 0, "one")?;
    doc.insert(&list, 1, 2i64)?;
    doc.commit_with(commit_options("base"));
    Ok(doc)
}

/// The left peer's single commit, made on top of the base and concurrent with
/// [`converge_right`].
///
/// | case | call |
/// |---|---|
/// | a write on each side, concurrently, on one key | `put(ROOT, "contested", …)` |
/// | a write on one side only | `put(ROOT, "only_left", …)` |
/// | a counter incremented on this side | `increment(ROOT, "counter", 1)` |
/// | a delete here of a key the other side edits | `delete(ROOT, "doomed")` |
/// | a mark here over a span the other side splices into | `mark(text, 1..4)` |
///
/// **The op order is part of the script.** A consumer replays these six calls
/// in this order to build the same change, and the change's hash is a hash of
/// the encoded operations, so a reordered replay is a different change.
fn converge_left(bytes: &[u8]) -> Result<AutoCommit, Box<dyn Error>> {
    let mut doc = AutoCommit::load(bytes)?.with_actor(actor(ACTOR_A)?);
    doc.put(ROOT, "contested", "left")?;
    doc.put(ROOT, "only_left", 1i64)?;
    doc.increment(ROOT, "counter", 1)?;
    doc.delete(ROOT, "doomed")?;
    let text = (doc.get(ROOT, "text")?.ok_or("the base has no `text`")?.1);
    doc.mark(&text, Mark::new("bold".to_string(), true, 1, 4), ExpandMark::Both)?;
    doc.splice_text(&text, 8, 0, "!")?;
    doc.commit_with(commit_options("left"));
    Ok(doc)
}

/// The right peer's single commit, made on top of the base and concurrent with
/// [`converge_left`]. The mirror of that function, case for case, and the one
/// place where "the same key" and "the same span" mean the other side's edit.
fn converge_right(bytes: &[u8]) -> Result<AutoCommit, Box<dyn Error>> {
    let mut doc = AutoCommit::load(bytes)?.with_actor(actor(ACTOR_B)?);
    doc.put(ROOT, "contested", "right")?;
    doc.put(ROOT, "only_right", 2i64)?;
    doc.increment(ROOT, "counter", 2)?;
    doc.put(ROOT, "doomed", "edited")?;
    // Inside the span `converge_left` marked, not at either anchor: the answer
    // does not depend on `ExpandMark`, which is what makes this the case that
    // shows the mark survived the merge.
    let text = (doc.get(ROOT, "text")?.ok_or("the base has no `text`")?.1);
    doc.splice_text(&text, 2, 0, "XY")?;
    doc.commit_with(commit_options("right"));
    Ok(doc)
}

/// `converge`: the awkward merge, driven by the reference's own sync protocol.
///
/// Every record is something a consumer checks rather than something it
/// summarises:
///
/// * `converge-base` — the base document's `save()` bytes, so a consumer loads
///   the same starting state rather than a similar one.
/// * `converge-sync` — one record per direction per round, the message bytes
///   **encoded and then decoded by the peer**, so the hex is what the peer read.
/// * `converge-heads` and `converge-save` — each side's heads and `save()`
///   bytes, which is the state the exchange is supposed to end in.
/// * `converge-state` — each side's **materialised** document as a JSON tree.
fn converge_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let base = converge_base()?.save();
    emit(
        out,
        &json!({
            "kind": "converge-base",
            "actor_a": ACTOR_A,
            "actor_b": ACTOR_B,
            "time": TIME,
            "bytes": base.len(),
            "hex": hex_encode(&base),
        }),
    )?;

    let mut left = converge_left(&base)?;
    let mut right = converge_right(&base)?;
    let mut left_state = State::new();
    let mut right_state = State::new();

    // **One side at a time.** The left peer generates, the right peer receives
    // what it generated, and only then does the right peer generate. The
    // reference's own test driver is the other shape — generate from both, then
    // deliver both (`sync.rs:1364-1380`) — and
    // [`converge_parallel_command`] records that one, because the round count
    // is not the same in the two shapes and this transcript must not be read as
    // an answer about the other. A message is encoded, printed and then handed
    // to the peer by decoding those exact bytes, so the hex is what the peer
    // read.
    for round in 1..=CONVERGE_ROUNDS {
        let to_right = left.sync().generate_sync_message(&mut right_state).map(Message::encode);
        emit(out, &sync_record("converge-sync", round, "left", "right", to_right.as_deref()))?;
        if let Some(raw) = to_right {
            let message = Message::decode(&raw)?;
            right.sync().receive_sync_message(&mut left_state, message)?;
        }

        let to_left = right.sync().generate_sync_message(&mut left_state).map(Message::encode);
        emit(out, &sync_record("converge-sync", round, "right", "left", to_left.as_deref()))?;
        if let Some(raw) = to_left {
            let message = Message::decode(&raw)?;
            left.sync().receive_sync_message(&mut right_state, message)?;
        }
    }

    // The trailing rounds are silent on both sides. Emitting them rather than
    // stopping is what lets a consumer tell "the exchange reached its fixed
    // point" from "the loop ran out of rounds".

    for (side, mut doc) in [("left", left), ("right", right)] {
        let bytes = doc.save();
        emit(
            out,
            &json!({
                "kind": "converge-heads",
                "side": side,
                "heads": head_text(&doc.get_heads()),
            }),
        )?;
        emit(
            out,
            &json!({
                "kind": "converge-save",
                "side": side,
                "bytes": bytes.len(),
                "hex": hex_encode(&bytes),
            }),
        )?;
        emit(
            out,
            &json!({
                "kind": "converge-state",
                "side": side,
                "root": children(&doc, &ROOT)?,
            }),
        )?;
    }
    Ok(())
}

/// How many rounds `converge-parallel` runs. **The same count as
/// [`CONVERGE_ROUNDS`], on purpose**: the two transcripts then have the same
/// length and a consumer can line them up and see the difference rather than
/// guess at it from two files of different sizes.
const CONVERGE_PARALLEL_ROUNDS: usize = CONVERGE_ROUNDS;

/// The awkward merge again, in the reference's **own** driver shape.
///
/// [`converge`] generates from one side and delivers before the other side
/// generates. The driver every sync test in the reference's own `sync` module
/// uses is the other one: it generates from **both** sides and only then
/// delivers **both** (`sync.rs:1364-1380`). This subcommand records that, and
/// the round count is different, which is the entire reason it exists.
///
/// A round is over when **both** sides return `None` in it (`sync.rs:1367-1369`),
/// so a round in which one side speaks and the other does not is a round. The
/// trailing silent rounds are still emitted, for the reason
/// [`CONVERGE_ROUNDS`] gives.
///
/// Every record is named `converge-parallel-*` **and** carries
/// `"shape": "parallel"`. Two reasons, and the second is the one that matters:
/// a `converge` record and a `converge-parallel` record describe the same two
/// documents and the same protocol, and a reader handed a concatenation of the
/// two files must be able to tell which driver produced a given message.
fn converge_parallel_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let base = converge_base()?.save();
    emit(
        out,
        &json!({
            "kind": "converge-parallel-base",
            "shape": "parallel",
            "actor_a": ACTOR_A,
            "actor_b": ACTOR_B,
            "time": TIME,
            "bytes": base.len(),
            "hex": hex_encode(&base),
        }),
    )?;

    let mut left = converge_left(&base)?;
    let mut right = converge_right(&base)?;
    let mut left_state = State::new();
    let mut right_state = State::new();

    // The loop of `sync.rs:1364-1380`, in the order that function uses it:
    // both `generate_sync_message` calls happen before either
    // `receive_sync_message`, which is what the parallel shape *is*.
    let mut traffic_rounds: usize = 0;
    let mut silent_from: Option<usize> = None;
    for round in 1..=CONVERGE_PARALLEL_ROUNDS {
        let to_right = left.sync().generate_sync_message(&mut right_state).map(Message::encode);
        let to_left = right.sync().generate_sync_message(&mut left_state).map(Message::encode);

        emit(out, &parallel_sync_record(round, "left", "right", to_right.as_deref()))?;
        emit(out, &parallel_sync_record(round, "right", "left", to_left.as_deref()))?;

        // `sync.rs:1367-1369`: the round is over when both sides have nothing
        // to say, and a round where only one side speaks still counts.
        if to_right.is_none() && to_left.is_none() {
            silent_from.get_or_insert(round);
            continue;
        }
        traffic_rounds += 1;

        if let Some(raw) = to_right {
            let message = Message::decode(&raw)?;
            right.sync().receive_sync_message(&mut left_state, message)?;
        }
        if let Some(raw) = to_left {
            let message = Message::decode(&raw)?;
            left.sync().receive_sync_message(&mut right_state, message)?;
        }
    }

    // The count a consumer pins, and the round the fixed point starts at.
    // `traffic_rounds` is what a driver that breaks on the first all-silent
    // round returns (`sync.rs:1367-1369`, `:1379`).
    emit(
        out,
        &json!({
            "kind": "converge-parallel-rounds",
            "shape": "parallel",
            "rounds_run": CONVERGE_PARALLEL_ROUNDS,
            "traffic_rounds": traffic_rounds,
            "silent_from": silent_from,
        }),
    )?;

    for (side, mut doc) in [("left", left), ("right", right)] {
        let bytes = doc.save();
        emit(
            out,
            &json!({
                "kind": "converge-parallel-heads",
                "shape": "parallel",
                "side": side,
                "heads": head_text(&doc.get_heads()),
            }),
        )?;
        emit(
            out,
            &json!({
                "kind": "converge-parallel-save",
                "shape": "parallel",
                "side": side,
                "bytes": bytes.len(),
                "hex": hex_encode(&bytes),
            }),
        )?;
        emit(
            out,
            &json!({
                "kind": "converge-parallel-state",
                "shape": "parallel",
                "side": side,
                "root": children(&doc, &ROOT)?,
            }),
        )?;
    }
    Ok(())
}

/// [`sync_record`] with the parallel driver stamped on it, so a record cannot
/// be mistaken for one from the one-sided driver.
fn parallel_sync_record(round: usize, from: &str, to: &str, sent: Option<&[u8]>) -> Json {
    let mut record = sync_record("converge-parallel-sync", round, from, to, sent);
    record["shape"] = json!("parallel");
    record
}

/// One materialised value, as JSON: `{"type": …, …}`.
/// Generic over the document, so a [`automerge::Automerge`] driven by manual transactions renders
/// through this same tree as an [`AutoCommit`]. Everything below is a [`ReadDoc`] read, and the
/// two document types hold the same document.
///
/// **The type is always spelled out**, so a consumer that renders `"13"` and one
/// that renders `13` are distinguishable, and a counter that came out as an
/// integer by accident is a difference rather than a match.
///
/// The counter's value is a **decimal string**, not a JSON number, and the only
/// reason is the float formatting a number would drag in behind it. The scenario
/// holds no floats and says so, and a counter is an `i64` in every reading of
/// it, so the string is exactly as checkable and cannot be reformatted on the
/// way through.
fn render_value<R: ReadDoc>(doc: &R, value: &Value<'_>, id: &ObjId) -> Result<Json, Box<dyn Error>> {
    Ok(match value {
        Value::Object(ObjType::Text) => json!({
            "type": "text",
            "text": doc.text(id)?,
            "marks": render_marks(doc, id)?,
        }),
        Value::Object(ObjType::List) => json!({ "type": "list", "elements": children(doc, id)? }),
        Value::Object(ObjType::Map) => json!({ "type": "map", "entries": children(doc, id)? }),
        Value::Object(ObjType::Table) => json!({ "type": "table", "entries": children(doc, id)? }),
        Value::Scalar(scalar) => json!({ "type": scalar_type(scalar), "value": render_scalar(scalar) }),
    })
}

/// The visible children of a map or a list.
///
/// **A map's keys are sorted, a list's are not.** Key order in a map is not an
/// observable of the document, so sorting makes the golden readable and the
/// comparison meaningful; element order in a list *is* the document, so it is
/// emitted in index order and the index is printed beside every element.
fn children<R: ReadDoc>(doc: &R, id: &ObjId) -> Result<Vec<Json>, Box<dyn Error>> {
    let mut out: Vec<Json> = Vec::new();
    if doc.object_type(id)? == ObjType::List {
        for index in 0..doc.length(id) {
            if let Some((value, child)) = doc.get(id, index)? {
                out.push(json!({ "index": index, "node": render_value(doc, &value, &child)? }));
            }
        }
    } else {
        let mut keys: Vec<String> = doc.keys(id).collect();
        keys.sort();
        for key in keys {
            if let Some((value, child)) = doc.get(id, &key)? {
                out.push(json!({ "key": key, "node": render_value(doc, &value, &child)? }));
            }
        }
    }
    Ok(out)
}

/// The marks over a text object, in `(start, end, name)` order.
///
/// **The sorting is [`mark_nodes`]'**, and the reason for it is the one written
/// there.
fn render_marks<R: ReadDoc>(doc: &R, id: &ObjId) -> Result<Vec<Json>, Box<dyn Error>> {
    Ok(mark_nodes(&doc.marks(id)?))
}

/// The type name a consumer can switch on.
fn scalar_type(value: &ScalarValue) -> &'static str {
    match value {
        ScalarValue::Bytes(_) => "bytes",
        ScalarValue::Str(_) => "str",
        ScalarValue::Int(_) => "int",
        ScalarValue::Uint(_) => "uint",
        ScalarValue::F64(_) => "float",
        ScalarValue::Counter(_) => "counter",
        ScalarValue::Timestamp(_) => "timestamp",
        ScalarValue::Boolean(_) => "bool",
        ScalarValue::Unknown { .. } => "unknown",
        ScalarValue::Null => "null",
    }
}

/// A scalar as JSON, in the shape [`render_value`] documents.
fn render_scalar(value: &ScalarValue) -> Json {
    match value {
        ScalarValue::Bytes(bytes) => json!({ "hex": hex_encode(bytes) }),
        ScalarValue::Str(text) => json!(text.as_str()),
        ScalarValue::Int(n) => json!(n),
        ScalarValue::Uint(n) => json!(n),
        ScalarValue::F64(n) => json!(n),
        ScalarValue::Counter(n) => json!(format!("{n}")),
        ScalarValue::Timestamp(n) => json!(n),
        ScalarValue::Boolean(b) => json!(b),
        ScalarValue::Unknown { type_code, bytes } => {
            json!({ "type_code": type_code, "hex": hex_encode(bytes) })
        }
        ScalarValue::Null => Json::Null,
    }
}

/// `feed`: hand the reference **someone else's** sync messages and print what it
/// made of them.
///
/// The input is newline delimited JSON on stdin, one message per line:
/// `{"to": "right", "hex": "4201…"}`. The two peers are the ones
/// [`converge_left`] and [`converge_right`] build, so a message meant for a peer
/// with a particular history arrives at a peer that has exactly that history.
///
/// **This is the direction [`converge`] cannot reach on its own.** `converge`
/// prints the reference's own messages; feeding it bytes the *other*
/// implementation produced is what answers whether the other implementation's
/// bytes are messages the reference can act on, rather than whether the two
/// implementations agree with each other.
fn feed_command(out: &mut dyn Write, input: &mut dyn io::BufRead) -> Result<(), Box<dyn Error>> {
    let base = converge_base()?.save();
    let mut left = converge_left(&base)?;
    let mut right = converge_right(&base)?;
    let mut left_state = State::new();
    let mut right_state = State::new();

    let mut index: usize = 0;
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Json = serde_json::from_str(&line)?;
        let to = request["to"].as_str().unwrap_or_default();
        let hex = request["hex"].as_str().unwrap_or_default();
        let message = Message::decode(&decode_hex(hex)?)?;
        match to {
            "right" => right.sync().receive_sync_message(&mut left_state, message)?,
            "left" => left.sync().receive_sync_message(&mut right_state, message)?,
            other => return Err(usage_error(format!("unknown side `{other}`"))),
        }
        index += 1;
        emit(out, &json!({ "kind": "feed", "index": index, "to": to }))?;
    }
    if index == 0 {
        return Err(usage_error("feed read no messages"));
    }

    for (side, mut doc) in [("left", left), ("right", right)] {
        let bytes = doc.save();
        emit(
            out,
            &json!({
                "kind": "feed-final",
                "side": side,
                "heads": head_text(&doc.get_heads()),
                "save": hex_encode(&bytes),
                "root": children(&doc, &ROOT)?,
            }),
        )?;
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

// ── clock ───────────────────────────────────────────────────────────────────

/// The history [`clock_command`] walks: four changes over two actors, with a
/// fork in the middle of it.
///
/// **A fork and not a chain**, because a chain makes every clock a prefix of
/// every other one and a comparison has nothing to decide. `from b` and
/// `second` are both made on the base and on nothing else, so the graph has two
/// heads from the second change onwards and a document that has seen one of
/// them has not seen the other. `third` sits on top of `from b`, so the graph
/// has a path of length two as well as a branch, and `covers` has a one-step
/// and a two-step case to answer.
///
/// The fork is only real if the base is saved **before** `second` is committed.
/// Saving afterwards hands both later peers a document that already contains
/// `second`, and the result is the chain this script is not about.
fn clock_history() -> Result<AutoCommit, Box<dyn Error>> {
    let base_bytes = base_document()?.save();

    let mut a = AutoCommit::load(&base_bytes)?.with_actor(actor(ACTOR_A)?);
    a.put(ROOT, "second", 2i64)?;
    a.commit_with(commit_options("second"));

    let mut b = AutoCommit::load(&base_bytes)?.with_actor(actor(ACTOR_B)?);
    b.put(ROOT, "from_b", 1i64)?;
    b.commit_with(commit_options("from b"));

    // `third` sits on `from b` and not on `second`, so it is concurrent with
    // `second` too and the graph forks twice over.
    let mut b_branch = AutoCommit::load(&b.save())?.with_actor(actor(ACTOR_B)?);
    b_branch.put(ROOT, "third", 3i64)?;
    b_branch.commit_with(commit_options("third"));

    let mut doc = AutoCommit::load(&base_bytes)?;
    doc.apply_changes(b_branch.get_changes(&[]))?;
    doc.apply_changes(a.get_changes(&[]))?;
    Ok(doc)
}

/// True when every change selected by `mask` has all of its dependencies
/// selected too. A subset that leaves one out is not a document the reference
/// can hold, so asking it about such a subset is a different question.
fn clock_subset_is_valid(changes: &[automerge::Change], mask: u32) -> bool {
    for (index, change) in changes.iter().enumerate() {
        if mask & (1 << index) == 0 {
            continue;
        }
        for dep in change.deps() {
            let found = changes.iter().position(|other| other.hash() == *dep);
            match found {
                Some(position) if mask & (1 << position) != 0 => {}
                // A dependency the reference did not hand us is a subset this
                // script cannot build, so it is skipped rather than guessed at.
                _ => return false,
            }
        }
    }
    true
}

/// `clock`: what the reference says about the three operations a clock has,
/// through the only surface that reaches them.
///
/// `Clock::covers`, `Clock::merge` and `Clock::include` are `pub(crate)`
/// (`clock.rs:12-15`, `:38-71`), so no consumer of the crate can call them and
/// an oracle has to ask a question the reference will answer through a public
/// door. There are two, and both are printed:
///
/// * **`get_missing_deps`** (`read.rs:302`) walks the change graph from the
///   heads it is given and answers with the changes this document does not have.
///     An empty answer is the statement `covers` makes, asked through the
///   document layer: every change reachable from those heads is already here.
/// * **`merge`** (`autocommit.rs:517`) folds one document's clock into
///   another's and answers with the heads that came out, which is the statement
///   `merge` makes about the same clock.
/// * **`get_heads`** (`autocommit.rs:695`) is the clock read back out as change
///   hashes, so a consumer can check its own `covers` against it.
///
/// Every record is named `clock-*`, and every one carries the **indices of the
/// changes its document holds** rather than the hashes: the hashes depend on the
/// encoder and a consumer that had to reproduce them would be testing the
/// change encoder rather than the clock.
fn clock_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut doc = clock_history()?;
    let changes: Vec<automerge::Change> = doc.get_changes(&[]);
    let n = changes.len();

    emit(out, &json!({ "kind": "clock-history", "changes": n }))?;
    for (index, change) in changes.iter().enumerate() {
        emit(out, &json!({
            "kind": "clock-change",
            "index": index,
            "hash": change.hash().to_string(),
            "deps": change.deps().iter().map(ToString::to_string).collect::<Vec<_>>(),
        }))?;
    }

    // One document per dependency-closed subset, in the order the masks run, so
    // the transcript is the same length on every run.
    let mut made: Vec<(Vec<usize>, Vec<u8>, Vec<automerge::ChangeHash>)> = Vec::new();
    for mask in 0..(1u32 << n) {
        if !clock_subset_is_valid(&changes, mask) {
            continue;
        }
        let mut subset = AutoCommit::new().with_actor(actor(ACTOR_A)?);
        let mut indices = Vec::new();
        let mut ordered = Vec::new();
        for (index, change) in changes.iter().enumerate() {
            if mask & (1 << index) == 0 {
                continue;
            }
            indices.push(index);
            ordered.push(change.clone());
        }
        subset.apply_changes(ordered)?;
        let heads = subset.get_heads();
        made.push((indices, subset.save(), heads));
        emit(out, &json!({
            "kind": "clock-doc",
            "changes": made[made.len() - 1].0,
            "heads": head_text(&made[made.len() - 1].2),
        }))?;
    }

    for (left_index, left) in made.iter().enumerate() {
        for (right_index, right) in made.iter().enumerate() {
            let probe = AutoCommit::load(&left.1)?;
            let missing = probe.get_missing_deps(&right.2);
            emit(out, &json!({
                "kind": "clock-covers",
                "left": left_index,
                "right": right_index,
                "missing": missing.iter().map(ToString::to_string).collect::<Vec<_>>(),
            }))?;

            let mut left_doc = AutoCommit::load(&left.1)?;
            let mut right_doc = AutoCommit::load(&right.1)?;
            let merged = left_doc.merge(&mut right_doc)?;
            emit(out, &json!({
                "kind": "clock-merge",
                "left": left_index,
                "right": right_index,
                "heads": merged.iter().map(ToString::to_string).collect::<Vec<_>>(),
            }))?;
        }
    }
    Ok(())
}


// ── text ────────────────────────────────────────────────────────────────────

/// The four text encodings, in the order `tests/text_encoding.rs` declares its
/// `Encoding` enum (`text_encoding.rs:50-55`) and in the order its `Scenario`
/// loops over them (`:124-133`).
///
/// The labels are this oracle's; the order is upstream's, and a consumer that
/// walks the records in order is walking the same axis `text_encoding.rs` is.
const ENCODINGS: [(&str, automerge::TextEncoding); 4] = [
    ("code_point", automerge::TextEncoding::UnicodeCodePoint),
    ("utf8", automerge::TextEncoding::Utf8CodeUnit),
    ("utf16", automerge::TextEncoding::Utf16CodeUnit),
    ("grapheme", automerge::TextEncoding::GraphemeCluster),
];


/// `text`: the three cases from `tests/text.rs` a hand-built fixture cannot
/// express, each under all four encodings.
///
/// **Why a subcommand exists for them at all.** Each of the three needs a
/// document state the port's public surface cannot reach, so a test cannot
/// construct it and can only replay what the reference produced:
///
/// * [`text_noexpand_spans`] needs `update_spans` over a zero-width `ExpandMark::None`
///   mark, and the interesting number is the index table the resulting
///   element sequence implies.
/// * [`text_isolate_incremental`] needs **more than a hundred patches**
///   (`text.rs`:884-885), which is the threshold at which `PatchBuilder::new`
///   precomputes a visible-path cache.
/// * [`text_legacy_multibyte`] needs a change whose insert op carries five
///   grapheme clusters, which `splice_text` will not produce and which the
///   oracle can only build through `automerge::legacy`.
fn text_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    for (label, enc) in ENCODINGS {
        text_noexpand_spans(out, label, enc)?;
        text_isolate_incremental(out, label, enc)?;
        text_legacy_multibyte(out, label, enc)?;
    }
    Ok(())
}

/// The block marker's width in each encoding, which is the whole of the index
/// arithmetic in [`text_noexpand_spans`].
///
/// **`seq_length` measures anything that is not a string as
/// `width("\u{fffc}")`** (`op_set.rs:443-447`), and U+FFFC is three bytes in
/// UTF-8, so a block marker is one position wide in three encodings and three
/// positions wide in the fourth. Everything ASCII is one unit in all four.
fn block_width(enc: automerge::TextEncoding) -> usize {
    match enc {
        automerge::TextEncoding::Utf8CodeUnit => 3,
        _ => 1,
    }
}

/// `insertions_after_noexpand_spans_are_not_marked` (`text.rs`:350-415).
///
/// The case: two blocks, a heading, a paragraph, a **zero-width** `strong`
/// mark at the paragraph's start, then `update_spans` over the shapes the walk
/// produced plus one more block — and a character spliced in after that must
/// come back **unmarked**, because a `None`-expanding mark covers nothing.
///
/// **Both index tables are run, because they answer different questions.**
/// `literal` is upstream's own numbers (`:354`, `:365`, `:366`, `:377`,
/// `:380`, `:397`) used unchanged, which is only the *right* index under
/// `UnicodeCodePoint`. `translated` is the same script with each number moved
/// into the encoding's own units, which is the shape a consumer that reads the
/// axis rather than one number has to have. Both are printed so a consumer can
/// see which one the element sequence agrees with.
fn text_noexpand_spans(
    out: &mut dyn Write,
    label: &str,
    enc: automerge::TextEncoding,
) -> Result<(), Box<dyn Error>> {
    let w = block_width(enc);
    // (name, splice after block 1, split the second block, splice after block
    // 2, mark start, final splice). Upstream's own numbers are
    // 1, 8, 9, 9, 11 (`:365`, `:366`, `:377`, `:380`, `:397`); the translated
    // row moves each one by the widths of the block markers before it.
    //
    // **The final index is `8 + 3w`, not a translation of 11**, and the reason
    // is that `update_spans` *appends* a block the walk did not see, so the
    // shape it leaves behind is [BLOCK, "Heading", BLOCK, "a", BLOCK] —
    // three block markers, not the two the script wrote. In code points that
    // is 11, which is why upstream's own number is right there and only
    // there; in UTF-8 code units the same shape is `3*3 + 7 + 1 = 17`.
    for (mode, after_a, split_b, after_b, mark_at, tail) in [
        ("literal", 1usize, 8, 9, 9, 11),
        ("translated", w, 7 + w, 7 + 2 * w, 7 + 2 * w, 8 + 3 * w),
    ] {
        let mut doc = AutoCommit::new_with_encoding(enc).with_actor(actor(ACTOR_A)?);
        let text = doc.put_object(ROOT, "text", ObjType::Text)?;
        let block1 = doc.split_block(&text, 0)?;
        doc.update_object(
            &block1,
            &automerge::hydrate_map! {
                "type" => "heading",
                "parents" => automerge::hydrate_list![],
                "attrs" => automerge::hydrate_map!{},
            }
            .into(),
        )?;
        doc.splice_text(&text, after_a, 0, "Heading")?;
        let block2 = doc.split_block(&text, split_b)?;
        doc.update_object(
            &block2,
            &automerge::hydrate_map! {
                "type" => "paragraph",
                "parents" => automerge::hydrate_list![],
                "attrs" => automerge::hydrate_map!{},
            }
            .into(),
        )?;
        doc.splice_text(&text, after_b, 0, "a")?;
        doc.mark(
            &text,
            automerge::marks::Mark::new("strong".to_string(), ScalarValue::from(true), mark_at, mark_at),
            automerge::marks::ExpandMark::None,
        )?;
        let text_before = doc.text(&text)?;
        let length_before = doc.length(&text);

        // `spans` is a walk, not a list: it is collected once and the `Debug`
        // of each span is taken from the collected `Vec`, because
        // `Spans` itself is not an iterator.
        let walked: Vec<automerge::iter::Span> = doc.spans(&text)?.collect();
        let spans_before: Vec<String> = walked.iter().map(|s| format!("{s:?}")).collect();
        let mut new_blocks = walked;
        new_blocks.push(automerge::iter::Span::Block(
            automerge::hydrate_map! {
                "type" => "paragraph",
                "parents" => automerge::hydrate_list![],
                "attrs" => automerge::hydrate_map!{},
            }
            .into(),
        ));
        doc.update_spans(&text, automerge::marks::UpdateSpansConfig::default(), new_blocks)?;

        // The marks the rewritten document carries, in the walk's own order,
        // so a consumer can pin that the zero-width `None`-expanding mark
        // covers nothing rather than inferring it from the patch alone.
        let marks_after: Vec<Json> = doc
            .marks(&text)?
            .iter()
            .map(|m| json!({ "name": m.name, "start": m.start, "end": m.end, "value": m.value }))
            .collect();

        let length_after = doc.length(&text);
        let text_after = doc.text(&text)?;
        let heads_before = head_text(&doc.get_heads());
        doc.splice_text(&text, tail, 0, "a")?;
        let heads_after = head_text(&doc.get_heads());
        let patches = doc.diff(&hashes_of(&heads_before)?, &hashes_of(&heads_after)?);
        emit(
            out,
            &json!({
                "kind": "text-noexpand-spans",
                "encoding": label,
                "mode": mode,
                "text_before_update_spans": text_before,
                "length_before_update_spans": length_before,
                "marks_after": marks_after,
                "length_after_update_spans": length_after,
                "text_after_update_spans": text_after,
                "spans": spans_before,
                "index": tail,
                "text": doc.text(&text)?,
                "patch_count": patches.len(),
                "patches": debug_patches(&patches),
            }),
        )?;
    }
    Ok(())
}

/// The head hashes a list of lowercase hex names stands for.
///
/// `AutoCommit::get_heads` takes `&mut self`, and [`text_noexpand_spans`] needs
/// its heads twice — once to diff between and once to print — so the hex names
/// are what crosses that borrow, and this is where they come back.
fn hashes_of(hexes: &[String]) -> Result<Vec<automerge::ChangeHash>, Box<dyn Error>> {
    hexes
        .iter()
        .map(|h| {
            let bytes: [u8; 32] = decode_hex(h)?.try_into().map_err(|_| "not 32 bytes")?;
            Ok(automerge::ChangeHash(bytes))
        })
        .collect()
}

/// `incorrect_patches_produced_when_isolating_and_integrating` (`text.rs`:868-921),
/// the bug from [automerge#951](https://github.com/automerge/automerge/issues/951).
///
/// The case: a hundred-character text, a concurrent root change under an
/// isolation, an empty patch log drained and a clean commit, a **second**
/// concurrent root change, and then `diff_incremental`. Reconstructing the
/// integrated document from the patches is the assertion; the epochs mean the
/// exact sequence can carry intermediate conflict updates, so upstream compares
/// the reconstruction against a fresh hydration rather than against a literal.
///
/// **Every index here is an ASCII index and so is the same number in all four
/// encodings**, which is why the script is run unchanged under each of them.
fn text_isolate_incremental(
    out: &mut dyn Write,
    label: &str,
    enc: automerge::TextEncoding,
) -> Result<(), Box<dyn Error>> {
    /// `text.rs`:885 — the count at which `PatchBuilder::new` stops building a
    /// patch per op and precomputes a visible-path cache.
    const NUM_CHARS_IN_NEW_NAME: usize = 100;

    let actor_id = actor("aaaaaa")?;
    let mut doc = AutoCommit::new_with_encoding(enc).with_actor(actor_id);

    let beginning = doc.get_heads();
    let name = doc.put_object(ROOT, "name", ObjType::Text)?;
    doc.splice_text(&name, 0, 0, &"a".repeat(NUM_CHARS_IN_NEW_NAME))?;

    doc.isolate(&beginning);
    let color = doc.put_object(ROOT, "color", ObjType::Text)?;
    doc.splice_text(&color, 0, 0, "red")?;
    doc.integrate();
    let color_after_first = doc.text(&color)?;

    let drained = doc.diff_incremental();
    doc.commit_with(commit_options("isolate"));

    let mut hydrated = doc.hydrate(&ROOT, None)?;

    doc.isolate(&beginning);
    let color = doc.put_object(ROOT, "color", ObjType::Text)?;
    doc.splice_text(&color, 0, 0, "unset")?;
    doc.commit_with(commit_options("isolate-2"));
    doc.integrate();

    let patches = doc.diff_incremental();
    let patch_count = patches.len();
    let applied = hydrated.apply_patches(enc, patches.clone());
    let expected = doc.hydrate(&ROOT, None)?;
    let equal = matches!(&applied, Ok(())) && hydrated == expected;
    let kinds: Vec<String> = patches.iter().map(|p| format!("{:?}", p.action)).collect();

    emit(
        out,
        &json!({
            "kind": "text-isolate-incremental",
            "encoding": label,
            "num_chars": NUM_CHARS_IN_NEW_NAME,
            "color_after_first": color_after_first,
            "drained_patches": drained.len(),
            "patch_count": patch_count,
            "applied": matches!(applied, Ok(())),
            "reconstructs": equal,
            "actions": kinds,
            "name": doc.text(&name)?,
            "color": doc.text(&color)?,
        }),
    )?;
    Ok(())
}

/// TEMPORARY ATTRIBUTION PROBE — not part of the oracle's contract.
///
/// `text_isolate_incremental` reports the *sum* of every event the
/// `AutoCommit` patch log holds when the second `diff_incremental` runs. This
/// runs the same script and drains the log with `diff_incremental` at every
/// checkpoint, so each record says which step of the script put which patches
/// into the log. `heads` and `actors` are printed alongside so a step that
/// forks an actor is visible.
fn isolate_probe(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    const NUM_CHARS_IN_NEW_NAME: usize = 100;
    for (label, enc) in ENCODINGS {
        let actor_id = actor("aaaaaa")?;
        let mut doc = AutoCommit::new_with_encoding(enc).with_actor(actor_id);
        let mut step = 0usize;
        let mut mark = |out: &mut dyn Write,
                        step: &mut usize,
                        doc: &mut AutoCommit,
                        what: &str|
         -> Result<(), Box<dyn Error>> {
            *step += 1;
            let patches = doc.diff_incremental();
            let kinds: Vec<String> = patches.iter().map(|p| format!("{:?}", p.action)).collect();
            let heads: Vec<String> = doc.get_heads().iter().map(|h| format!("{h:?}")).collect();
            let doc_heads = doc.get_heads();
            let actors: Vec<String> = doc
                .get_changes(&doc_heads)
                .into_iter()
                .map(|c| format!("{:?}", c.actor_id()))
                .collect();
            emit(
                out,
                &json!({
                    "kind": "isolate-probe",
                    "encoding": label,
                    "step": *step,
                    "what": what,
                    "patch_count": kinds.len(),
                    "actions": kinds,
                    "heads": heads,
                    "actors": actors,
                }),
            )?;
            Ok(())
        };

        let beginning = doc.get_heads();
        let name = doc.put_object(ROOT, "name", ObjType::Text)?;
        doc.splice_text(&name, 0, 0, &"a".repeat(NUM_CHARS_IN_NEW_NAME))?;

        doc.isolate(&beginning);
        mark(out, &mut step, &mut doc, "after isolate #1 (name committed, view moved to beginning)")?;
        let color = doc.put_object(ROOT, "color", ObjType::Text)?;
        doc.splice_text(&color, 0, 0, "red")?;
        doc.integrate();
        mark(out, &mut step, &mut doc, "after integrate #1 (color=red committed)")?;
        let _ = doc.text(&color)?;

        let _drained = doc.diff_incremental();
        step += 1;
        {
            let heads: Vec<String> = doc.get_heads().iter().map(|h| format!("{h:?}")).collect();
            emit(
                out,
                &json!({
                    "kind": "isolate-probe",
                    "encoding": label,
                    "step": step,
                    "what": "the drain the upstream test performs",
                    "heads": heads,
                }),
            )?;
        }
        doc.commit_with(commit_options("isolate"));
        mark(out, &mut step, &mut doc, "after the empty commit")?;
        let _hydrated = doc.hydrate(&ROOT, None)?;

        doc.isolate(&beginning);
        mark(out, &mut step, &mut doc, "after isolate #2 (view moved back to beginning)")?;
        let color = doc.put_object(ROOT, "color", ObjType::Text)?;
        doc.splice_text(&color, 0, 0, "unset")?;
        doc.commit_with(commit_options("isolate-2"));
        mark(out, &mut step, &mut doc, "after the isolated commit (color=unset)")?;
        doc.integrate();
        mark(out, &mut step, &mut doc, "after integrate #2")?;
        let final_patches = doc.diff_incremental();
        let kinds: Vec<String> = final_patches
            .iter()
            .map(|p| format!("{:?}", p.action))
            .collect();
        emit(
            out,
            &json!({
                "kind": "isolate-probe-final",
                "encoding": label,
                "patch_count": kinds.len(),
                "actions": kinds,
                "name": doc.text(&name)?,
                "color": doc.text(&color)?,
            }),
        )?;
    }
    Ok(())
}

/// `splicing_into_multibyte_characters` (`text.rs`:944-1023).
///
/// The case: a **legacy change** whose first op is a single `put` of
/// `"BBBBB"` — five grapheme clusters in one insert op — so an index that
/// lands inside it is inside an *op*, not inside a character, and every splice
/// has to round to the far side of that op.
///
/// **Both changes are printed as hex, because the second one's dependency is
/// the first one's hash** and a consumer cannot compute that hash without
/// reproducing the first commit's timestamp. Replaying both hex blobs is the
/// only way a consumer reaches this state, which is the same reason the
/// fixture corpus exists.
fn text_legacy_multibyte(
    out: &mut dyn Write,
    label: &str,
    enc: automerge::TextEncoding,
) -> Result<(), Box<dyn Error>> {
    let mut doc = AutoCommit::new_with_encoding(enc).with_actor(actor(ACTOR_A)?);
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    let actor_id = doc.get_actor().clone();
    doc.splice_text(&text, 0, 0, "A")?;
    let parent_hash = doc.commit_with(commit_options("legacy-parent"));

    let weird_actor = actor("bbbbbb")?;
    let weird = automerge::ExpandedChange {
        operations: vec![
            automerge::legacy::Op {
                action: automerge::legacy::OpType::Put("BBBBB".into()),
                obj: automerge::legacy::ObjectId::Id(automerge::legacy::OpId(1, actor_id.clone())),
                key: automerge::legacy::Key::Seq(automerge::legacy::ElementId::Id(
                    automerge::legacy::OpId(2, actor_id.clone()),
                )),
                pred: automerge::legacy::SortedVec::new(),
                insert: true,
            },
            automerge::legacy::Op {
                action: automerge::legacy::OpType::Make(ObjType::Map),
                obj: automerge::legacy::ObjectId::Id(automerge::legacy::OpId(1, actor_id.clone())),
                key: automerge::legacy::Key::Seq(automerge::legacy::ElementId::Id(
                    automerge::legacy::OpId(3, weird_actor.clone()),
                )),
                pred: automerge::legacy::SortedVec::new(),
                insert: true,
            },
            automerge::legacy::Op {
                action: automerge::legacy::OpType::Put("C".into()),
                obj: automerge::legacy::ObjectId::Id(automerge::legacy::OpId(1, actor_id.clone())),
                key: automerge::legacy::Key::Seq(automerge::legacy::ElementId::Id(
                    automerge::legacy::OpId(4, weird_actor.clone()),
                )),
                pred: automerge::legacy::SortedVec::new(),
                insert: true,
            },
        ],
        actor_id: weird_actor,
        author: None,
        hash: None,
        seq: 1,
        start_op: std::num::NonZeroU64::new(3).unwrap(),
        time: 0,
        message: None,
        deps: vec![parent_hash.expect("the parent commit has a hash")],
        extra_bytes: Vec::new(),
    };
    doc.apply_changes(vec![weird.into()])?;

    let loaded = doc.text(&text)?;
    let length = doc.length(&text);

    let mut changes: Vec<Json> = Vec::new();
    for (index, mut change) in doc.get_changes(&[]).into_iter().enumerate() {
        // **`bytes` is the wire form and `raw` is the body**, and the two are
        // different things: `bytes` compresses and frames the body as a
        // `ChunkType.compressed` chunk (`change.rs:102-116`), while
        // `raw_bytes` is the header-plus-columns-plus-footer the change hash
        // is taken over and what a loader's `parseChange` is handed
        // (`change.rs:120`). Both are printed because a consumer that parses a
        // change chunk needs the second and a consumer that checks the wire
        // bytes needs the first, and picking the wrong one is a parse error
        // that looks like corrupt data.
        let bytes = change.bytes().into_owned();
        changes.push(json!({
            "index": index,
            "hash": change.hash().to_string(),
            "seq": change.seq(),
            "start_op": change.start_op().get(),
            "wire_len": bytes.len(),
            "wire_hex": hex_encode(&bytes),
            "raw_len": change.raw_bytes().len(),
            "raw_hex": hex_encode(change.raw_bytes()),
        }));
    }

    // The three splices `text.rs`:1007-1022 makes, each on its own clone.
    let mut results: Vec<Json> = Vec::new();
    for (case, index, delete, insert) in [
        ("replace", 3usize, 4isize, "X"),
        ("insert", 3, 0, "X"),
        ("delete", 3, 1, ""),
    ] {
        let mut probe = doc.clone();
        probe.splice_text(&text, index, delete, insert)?;
        results.push(json!({
            "case": case,
            "index": index,
            "delete": delete,
            "insert": insert,
            "text": probe.text(&text)?,
        }));
    }

    emit(
        out,
        &json!({
            "kind": "text-legacy-multibyte",
            "encoding": label,
            "text": loaded,
            "length": length,
            "changes": changes,
            "splices": results,
        }),
    )?;
    Ok(())
}

/// `sample`: the reference's own writer over the operation sequence
/// `src/doc.zig`'s `buildSample` fixture claims to encode, in two commits by two
/// actors.
fn sample_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let mut doc = AutoCommit::new().with_actor(actor(ACTOR_A)?);

    let list = doc.put_object(ROOT, "list", ObjType::List)?;
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    let map = doc.put_object(ROOT, "map", ObjType::Map)?;
    doc.put(ROOT, "hello", "world")?;
    doc.insert(&list, 0, "a")?;
    doc.insert(&list, 1, "b")?;
    doc.splice_text(&text, 0, 0, "hi")?;
    doc.splice_text(&text, 2, 0, "!")?;
    // `mark(text, {start: 2, end: 3})`: the begin anchor lands after `hi` and
    // the end anchor after `!`, which is what the fixture's two `Seq` keys
    // name, and `ExpandMark::None` keeps either anchor from expanding.
    doc.mark(&text, Mark::new("bold".to_string(), 0u64, 2, 3), ExpandMark::None)?;
    doc.delete(&list, 0)?;
    doc.put(ROOT, "hello", "again")?;
    doc.commit_with(CommitOptions::default().with_time(TIME));

    let after_a = doc.save();
    let mut second = AutoCommit::load(&after_a)?.with_actor(actor(ACTOR_B)?);
    second.insert(&list, 1, "c")?;
    second.put(&map, "in_map", "yes")?;
    second.put(ROOT, "only_b", "b")?;
    second.commit_with(CommitOptions::default().with_time(TIME));

    // The changes one per line, raw and wire, because the change encoding is
    // the compatibility contract while `save()` is not: DEFLATE is not
    // reproducible across implementations, so a port test comparing bytes has
    // to compare something the format actually fixes.
    for (index, mut change) in second.get_changes(&[]).into_iter().enumerate() {
        emit(
            out,
            &json!({
                "kind": "sample-change",
                "index": index,
                "hash": change.hash().to_string(),
                "seq": change.seq(),
                "start_op": change.start_op().get(),
                "time": change.timestamp(),
                "deps": change.deps().iter().map(ToString::to_string).collect::<Vec<String>>(),
                "raw_len": change.raw_bytes().len(),
                "raw_hex": hex_encode(change.raw_bytes()),
                "wire_len": change.bytes().into_owned().len(),
                "wire_hex": hex_encode(&change.bytes().into_owned()),
            }),
        )?;
    }
    let bytes = second.save();
    let heads = head_text(&second.get_heads());
    emit(
        out,
        &json!({
            "kind": "sample",
            "actors": [ACTOR_A, ACTOR_B],
            "time": TIME,
            "len": second.length(ROOT),
            "heads": heads,
            "root": children(&second, &ROOT)?,
            "bytes": bytes.len(),
            "hex": hex_encode(&bytes),
        }),
    )?;
    Ok(())
}

/// `loadhex`: load a save read as hex from `input` and report what the
/// reference makes of it — the materialised document, the heads, and the bytes
/// it saves back.
///
/// **The direction [`sample_command`] cannot reach on its own.** `sample` is the
/// reference's own writer; this is the reference's own reader over bytes
/// somebody else wrote, which is the only way to ask whether a document another
/// implementation built is one this one agrees with.
fn loadhex_command(out: &mut dyn Write, input: &mut dyn io::BufRead) -> Result<(), Box<dyn Error>> {
    let mut text = String::new();
    input.read_to_string(&mut text)?;
    let bytes = decode_hex(text.trim())?;
    let mut doc = AutoCommit::load(&bytes)?;
    let heads = head_text(&doc.get_heads());
    let root = children(&doc, &ROOT)?;
    let again = doc.save();
    emit(
        out,
        &json!({
            "kind": "loadhex",
            "in_len": bytes.len(),
            "heads": heads,
            "root": root,
            "out_len": again.len(),
            "hex": hex_encode(&again),
        }),
    )?;
    Ok(())
}
