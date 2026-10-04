//! Save interoperability: the six scripted documents the Zig port and this
//! oracle must agree on, and the direction in which the port's own saves are
//! read back here.
//!
//! Every other subcommand asks the reference about a document **it** built.
//! These two hold the port's writer against the reference's, and then the
//! port's reader against the reference's:
//!
//! * [`save_interop_command`] builds the six scenarios and prints what the
//!   reference produced for each.
//! * [`verify_save_interop_command`] reads the port's saves back **here**,
//!   rebuilds the same six scripts from scratch, and compares.
//!
//! # The fixed history
//!
//! Both implementations script the same operations in the same order, so the
//! six **histories** are identical: [`ACTOR_A`] and [`ACTOR_B`] write every
//! change, [`TIME`] and each transaction's own message stamp it, and the text
//! encoding is [`TextEncoding::UnicodeCodePoint`] so a splice index counts the
//! same units on both sides. The **compressed** save is deliberately not part
//! of that promise — `save()` deflates, and how a deflater frames its stream
//! is the writer's business. What must agree byte for byte is
//! `changes[].raw_hex`; how the two compress it is compared after decoding.
//!
//! `conflicts` and `merge` reach the same document two ways: the first applies
//! the peer's change with `get_changes_added` and `apply_changes`, the second
//! calls `merge`, which applies the peer's changes and **writes no change of
//! its own**. Two scenarios with the same hashes and the same changes is what
//! pins that down. Every save is one document chunk with nothing queued, since
//! the port's reader has to load it whole.
//!
//! # A record
//!
//! | field      | what it is |
//! |------------|------------|
//! | `kind`     | `save-interop` from the first command, `cross-loaded` from the second |
//! | `scenario` | one of [`SCENARIOS`] |
//! | `hex`      | the **default compressed** `save()` — this run's own bytes |
//! | `heads`    | `get_heads()`, lowercase hex |
//! | `hashes`   | every change hash, in the order `get_changes` returns them |
//! | `changes`  | `{hash, seq, start_op, raw_hex}` per change, in that same order |
//! | `root`     | the materialised document, through the same [`children`] renderer every other subcommand uses |
//!
//! `get_changes` returns changes in dependency order: a change's dependencies
//! are already among the changes before it.
//!
//! `raw_hex` is `Change::raw_bytes`, the whole change chunk header included,
//! **not** `Change::bytes`, which deflates a chunk that is worth deflating.
//!
//! # Why the reverse direction is not an echo
//!
//! Reading `{"scenario": "marks", "hex": …}` and printing the record back
//! checks nothing. [`verify_save_interop_command`] reads only the id and the
//! bytes of each request — a record's claim about its own heads or changes is
//! not evidence — builds the expected document from the same scripts this
//! module's other half runs, loads the port's bytes, and compares the head
//! **set**, every change by hash identity with its `seq`, `start_op` and raw
//! bytes, and the materialised document marks included. Only then does it
//! emit a record containing its re-save and `reference_hex`, the independently
//! built document's default save. Zig compares both normalized bodies. A
//! re-save alone can preserve an incorrect metadata tag from the input.
//!
//! Six ids are required, each exactly once: an unknown id, a repeated id, a
//! malformed record and a load that fails are errors, and so is a document
//! that differs in any of the three comparisons.

use std::error::Error;
use std::io::{BufRead, Write};

use automerge::marks::{ExpandMark, Mark};
use automerge::transaction::Transactable;
use automerge::{Automerge, ObjId, ObjType, ReadDoc, ScalarValue, TextEncoding, Value, ROOT};
use serde_json::{Value as Json, json};

use crate::{
    ACTOR_A, ACTOR_B, TIME, actor, children, commit_options, counter, decode_hex, emit, head_text,
    hex_encode,
};

/// The six scenario ids, in the order both commands emit them.
///
/// The id is the whole contract between the two sides: the port names its
/// record with one of these and this side answers that name, so an id this file
/// does not know is a mismatch rather than something to skip.
const SCENARIOS: [&str; 6] = ["map", "list", "text", "marks", "conflicts", "merge"];

// ── The two commands ─────────────────────────────────────────────────────────

/// `save-interop`: build all six scenarios and print what the reference made of
/// each. This is what the golden vector is generated from; nothing here writes
/// a file.
pub fn save_interop_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    for scenario in SCENARIOS {
        let doc = build(scenario)?;
        emit(out, &record("save-interop", scenario, &doc)?)?;
    }
    Ok(())
}

/// `verify-save-interop`: read the port's saves from `input` and check each one
/// against a document this side builds itself.
///
/// The input is newline delimited JSON on stdin, one record per scenario:
/// `{"kind":"port-save","scenario":"marks","hex":"856f…"}`. Records may arrive
/// in any order; output is in [`SCENARIOS`] order, each with `kind` set to
/// `cross-loaded` and `hex` holding this side's re-save of what it loaded.
pub fn verify_save_interop_command(
    out: &mut dyn Write,
    input: &mut dyn BufRead,
) -> Result<(), Box<dyn Error>> {
    let requests = read_requests(input)?;
    for scenario in SCENARIOS {
        let bytes = requests
            .iter()
            .find(|(id, _)| id.as_str() == scenario)
            .map(|(_, bytes)| bytes.as_slice())
            .expect("read_requests holds every scenario exactly once");
        emit(out, &check(scenario, bytes)?)?;
    }
    Ok(())
}

/// The port's requests by id, once every line has been checked for shape.
///
/// A line that is not JSON, a record that is not a `port-save`, a missing
/// field, a bad hex string, an unknown id, a repeated id and a count other
/// than six are all errors: verifying five of six scenarios and reporting
/// success would be worse than failing.
fn read_requests(input: &mut dyn BufRead) -> Result<Vec<(String, Vec<u8>)>, Box<dyn Error>> {
    let mut text = String::new();
    input.read_to_string(&mut text)?;

    let mut requests: Vec<(String, Vec<u8>)> = Vec::new();
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let where_ = format!("request {}", number + 1);

        let request: Json = serde_json::from_str(line)
            .map_err(|err| format!("{where_}: not JSON: {err}"))?;
        let kind = request["kind"]
            .as_str()
            .ok_or_else(|| format!("{where_}: no `kind` field"))?;
        if kind != "port-save" {
            return Err(format!("{where_}: expected kind `port-save`, found `{kind}`").into());
        }
        let scenario = request["scenario"]
            .as_str()
            .ok_or_else(|| format!("{where_}: no `scenario` field"))?;
        if !SCENARIOS.contains(&scenario) {
            return Err(format!(
                "{where_}: unknown scenario `{scenario}`; this oracle knows {}",
                SCENARIOS.join(", ")
            )
            .into());
        }
        if requests.iter().any(|(seen, _)| seen.as_str() == scenario) {
            return Err(format!("{where_}: scenario `{scenario}` appears twice").into());
        }
        let hex = request["hex"]
            .as_str()
            .ok_or_else(|| format!("{where_}: no `hex` field"))?;
        let bytes = decode_hex(hex).map_err(|err| format!("{where_}: bad `hex`: {err}"))?;
        requests.push((scenario.to_string(), bytes));
    }

    if requests.len() != SCENARIOS.len() {
        let seen: Vec<&str> = requests.iter().map(|(id, _)| id.as_str()).collect();
        return Err(format!(
            "expected {} records, one per scenario, found {}: {}",
            SCENARIOS.len(),
            requests.len(),
            seen.join(" ")
        )
        .into());
    }
    Ok(requests)
}

/// Load the port's bytes, check them against this side's own build of the same
/// script, and answer with this side's re-save of what was loaded.
fn check(scenario: &str, bytes: &[u8]) -> Result<Json, Box<dyn Error>> {
    let expected = build(scenario)?;
    let actual = Automerge::load(bytes)
        .map_err(|err| format!("{scenario}: the port save did not load: {err}"))?;

    compare_heads(scenario, &expected, &actual)?;
    compare_changes(scenario, &expected, &actual)?;
    compare_root(scenario, &expected, &actual)?;

    let mut response = record("cross-loaded", scenario, &actual)?;
    response["reference_hex"] = Json::String(hex_encode(&expected.save()));
    Ok(response)
}

// ── The comparisons ──────────────────────────────────────────────────────────

/// The head **set**, sorted, so neither order nor a duplicate can hide a
/// difference behind one.
fn heads_of(doc: &Automerge) -> Vec<String> {
    let mut heads = head_text(&doc.get_heads());
    heads.sort();
    heads
}

fn compare_heads(
    scenario: &str,
    expected: &Automerge,
    actual: &Automerge,
) -> Result<(), Box<dyn Error>> {
    let (expected_heads, actual_heads) = (heads_of(expected), heads_of(actual));
    if expected_heads != actual_heads {
        return Err(format!(
            "{scenario}: heads differ\n  this oracle built {}\n  the port save has {}",
            expected_heads.join(" "),
            actual_heads.join(" ")
        )
        .into());
    }
    Ok(())
}

/// Changes are compared **by hash identity**: the same changes in a different
/// order are the same document, and a change under a hash the reference did
/// not produce is not.
///
/// `raw_bytes` is borrowed from the change rather than copied, and a hash is
/// only formatted when a diagnostic has to name it. The bytes are the whole
/// change chunk, and a loaded document's changes are re-encoded from its op
/// set when they are read back, so this compares the two documents' operations
/// as the reference encodes them — which is where an operation that differs
/// shows up even when both documents materialise the same value.
fn compare_changes(
    scenario: &str,
    expected: &Automerge,
    actual: &Automerge,
) -> Result<(), Box<dyn Error>> {
    let (expected_changes, actual_changes) = (expected.get_changes(&[]), actual.get_changes(&[]));
    // Two or three changes per scenario, so the set is compared by scanning
    // the borrowed lists: no index, no hash table, and a hash is only turned
    // into a string when a diagnostic has to name it.
    let same_set = expected_changes.len() == actual_changes.len()
        && expected_changes
            .iter()
            .all(|mine| actual_changes.iter().any(|theirs| theirs.hash() == mine.hash()));
    if !same_set {
        let missing: Vec<String> = expected_changes
            .iter()
            .filter(|mine| !actual_changes.iter().any(|theirs| theirs.hash() == mine.hash()))
            .map(|mine| mine.hash().to_string())
            .collect();
        let extra: Vec<String> = actual_changes
            .iter()
            .filter(|theirs| !expected_changes.iter().any(|mine| mine.hash() == theirs.hash()))
            .map(|theirs| theirs.hash().to_string())
            .collect();
        return Err(format!(
            "{scenario}: {} changes here, {} in the port save\n  missing from the port save: {}\n  not in this oracle's build: {}",
            expected_changes.len(),
            actual_changes.len(),
            missing.join(" "),
            extra.join(" ")
        )
        .into());
    }

    for mine in &expected_changes {
        let hash = mine.hash();
        let theirs = actual_changes
            .iter()
            .find(|theirs| theirs.hash() == hash)
            .expect("the two change sets were just compared, so this hash is there");
        if mine.seq() != theirs.seq() || mine.start_op() != theirs.start_op() {
            return Err(format!(
                "{scenario}: change {hash} is seq {} start_op {} here and seq {} start_op {} in the port save",
                mine.seq(),
                mine.start_op(),
                theirs.seq(),
                theirs.start_op()
            )
            .into());
        }
        let (mine_bytes, their_bytes) = (mine.raw_bytes(), theirs.raw_bytes());
        if mine_bytes != their_bytes {
            let at = mine_bytes
                .iter()
                .zip(their_bytes.iter())
                .position(|(a, b)| a != b)
                .unwrap_or_else(|| mine_bytes.len().min(their_bytes.len()));
            return Err(format!(
                "{scenario}: change {hash} differs at byte {at} ({} bytes here, {} in the port save); {} here against {} there",
                mine_bytes.len(),
                their_bytes.len(),
                window(mine_bytes, at),
                window(their_bytes, at),
            )
            .into());
        }
    }
    Ok(())
}

/// The materialised document, marks included, through the same [`children`]
/// renderer the rest of the oracle prints.
fn compare_root(
    scenario: &str,
    expected: &Automerge,
    actual: &Automerge,
) -> Result<(), Box<dyn Error>> {
    let (expected_root, actual_root) = (children(expected, &ROOT)?, children(actual, &ROOT)?);
    if expected_root != actual_root {
        return Err(format!(
            "{scenario}: the materialised documents differ: {}",
            first_difference(&expected_root, &actual_root)
        )
        .into());
    }
    Ok(())
}

/// The first child of two renderings that differs, named by key or index.
///
/// [`children`] renders a list as `{"index": …, "node": …}` and a map as
/// `{"key": …, "node": …}`, and the `list` scenario holds two hundred of them,
/// so the first difference is named rather than both sides printed whole. The
/// node is shown with its **marks** when it has them: a mark that did not
/// survive is the difference a reader is usually looking for, and it is inside
/// the node, not beside it.
fn first_difference(expected: &[Json], actual: &[Json]) -> String {
    for (mine, theirs) in expected.iter().zip(actual) {
        if mine != theirs {
            return format!(
                "{}: {} here, {} in the port save",
                label(mine),
                node_text(mine.get("node").unwrap_or(mine)),
                node_text(theirs.get("node").unwrap_or(theirs)),
            );
        }
    }
    format!(
        "{} entries here, {} in the port save",
        expected.len(),
        actual.len()
    )
}

/// How a child names itself in a diagnostic.
fn label(node: &Json) -> String {
    match (node.get("key").and_then(Json::as_str), node.get("index").and_then(Json::as_u64)) {
        (Some(key), _) => format!("key `{key}`"),
        (None, Some(index)) => format!("index {index}"),
        (None, None) => "an entry".to_string(),
    }
}

/// A node as one line: its text and its marks when it has them.
fn node_text(node: &Json) -> String {
    match (node.get("text"), node.get("marks")) {
        (Some(text), Some(marks)) => format!("text {text} marks {}", brief(marks)),
        _ => brief(node),
    }
}

/// A rendered value, short enough to read in a diagnostic.
fn brief(value: &Json) -> String {
    const LIMIT: usize = 160;
    let text = value.to_string();
    if text.chars().count() <= LIMIT {
        text
    } else {
        format!("{}…", text.chars().take(LIMIT).collect::<String>())
    }
}

/// Sixteen bytes of a change chunk from `at`, hexed.
fn window(bytes: &[u8], at: usize) -> String {
    hex_encode(&bytes[at..bytes.len().min(at + 16)])
}

// ── The record ───────────────────────────────────────────────────────────────

/// One scenario, as both commands print it. `hex` is this document's own
/// `save()`, which for `cross-loaded` is the re-save of the document the port's
/// bytes loaded into and not the bytes that came in.
fn record(kind: &str, scenario: &str, doc: &Automerge) -> Result<Json, Box<dyn Error>> {
    let changes = doc.get_changes(&[]);
    let hashes: Vec<String> = changes.iter().map(|change| change.hash().to_string()).collect();
    let entries: Vec<Json> = changes
        .iter()
        .map(|change| {
            json!({
                "hash": change.hash().to_string(),
                "seq": change.seq(),
                "start_op": change.start_op().get(),
                "raw_hex": hex_encode(change.raw_bytes()),
            })
        })
        .collect();
    Ok(json!({
        "kind": kind,
        "scenario": scenario,
        "hex": hex_encode(&doc.save()),
        "heads": head_text(&doc.get_heads()),
        "hashes": hashes,
        "changes": entries,
        "root": children(doc, &ROOT)?,
    }))
}

// ── The scripts ──────────────────────────────────────────────────────────────

/// The scenario named by an id, built from scratch.
fn build(scenario: &str) -> Result<Automerge, Box<dyn Error>> {
    match scenario {
        "map" => build_map(),
        "list" => build_list(),
        "text" => build_text(),
        "marks" => build_marks(),
        "conflicts" => {
            let (mut left, right) = forked()?;
            // `get_changes_added` plus `apply_changes`, which is what `merge`
            // does internally (`automerge.rs:1115-1131`): the same document
            // reached without calling it.
            let added = left.get_changes_added(&right);
            left.apply_changes(added)?;
            Ok(left)
        }
        "merge" => {
            let (mut left, mut right) = forked()?;
            left.merge(&mut right)?;
            right.merge(&mut left)?;
            Ok(left)
        }
        other => Err(format!("unknown save-interop scenario `{other}`").into()),
    }
}

/// A document this side writes by hand: the reference's own [`Automerge`], a
/// scripted actor, and [`TextEncoding::UnicodeCodePoint`].
///
/// `AutoCommit` folds operations into one implicit change stamped with the
/// wall clock. These scripts name their transaction and its message, so the
/// manual transaction is the only way to write the history the port reproduces.
fn new_doc(actor_hex: &str) -> Result<Automerge, Box<dyn Error>> {
    Ok(Automerge::new_with_encoding(TextEncoding::UnicodeCodePoint).with_actor(actor(actor_hex)?))
}

/// The id of a root key's object, read before the transaction that writes into
/// it: the id is stable across a transaction, but reading it inside one would
/// borrow a document the transaction already holds.
fn child_id(doc: &Automerge, key: &str) -> Result<ObjId, Box<dyn Error>> {
    match doc.get(&ROOT, key)? {
        Some((Value::Object(_), id)) => Ok(id),
        _ => Err(format!("no object at root key `{key}`").into()),
    }
}

/// `map`: every scalar type the format has, a counter, a delete, and a nested
/// map written twice — the writes in one commit, the edits in another.
fn build_map() -> Result<Automerge, Box<dyn Error>> {
    let mut doc = new_doc(ACTOR_A)?;

    let mut tx = doc.transaction();
    tx.put(ROOT, "title", "title")?;
    tx.put(ROOT, "int", -7i64)?;
    tx.put(ROOT, "uint", u64::MAX)?;
    tx.put(ROOT, "bool", true)?;
    tx.put(ROOT, "null", ScalarValue::Null)?;
    tx.put(ROOT, "str", "naïve🦊")?;
    tx.put(ROOT, "bytes", vec![0u8, 1, 255])?;
    tx.put(ROOT, "timestamp", ScalarValue::Timestamp(TIME))?;
    tx.put(ROOT, "counter", counter(0)?)?;
    tx.put(ROOT, "removed", "gone")?;
    let nested = tx.put_object(ROOT, "nested", ObjType::Map)?;
    tx.put(&nested, "value", 1i64)?;
    tx.put(&nested, "value", 2i64)?;
    tx.delete(ROOT, "removed")?;
    tx.commit_with(commit_options("map/base"));

    let mut tx = doc.transaction();
    tx.increment(ROOT, "counter", 3)?;
    tx.increment(ROOT, "counter", -1)?;
    tx.increment(ROOT, "counter", 10)?;
    tx.put(ROOT, "title", "updated")?;
    tx.commit_with(commit_options("map/update"));

    Ok(doc)
}

/// `list`: two hundred elements, then a commit that splices strings and whole
/// objects into the middle and deletes from the front.
///
/// Big enough that the document's columns are worth compressing and indexing,
/// which is what makes this a save-format case rather than a list case. The
/// `tail` index is the list's length **inside** this transaction (200 + the two
/// inserts), which is what "append at the current length" means.
fn build_list() -> Result<Automerge, Box<dyn Error>> {
    let mut doc = new_doc(ACTOR_A)?;

    let mut tx = doc.transaction();
    let list = tx.put_object(ROOT, "list", ObjType::List)?;
    for index in 0..200usize {
        tx.insert(&list, index, index as i64)?;
    }
    tx.commit_with(commit_options("list/base"));

    let mut tx = doc.transaction();
    tx.insert(&list, 0, "head")?;
    tx.insert(&list, 100, "middle")?;
    let length = tx.length(&list);
    tx.insert(&list, length, "tail")?;
    let inserted_map = tx.insert_object(&list, 100, ObjType::Map)?;
    tx.put(&inserted_map, "ok", true)?;
    let inserted_list = tx.insert_object(&list, 101, ObjType::List)?;
    tx.insert(&inserted_list, 0, "inner")?;
    tx.delete(&list, 7)?;
    tx.delete(&list, 7)?;
    tx.delete(&list, 7)?;
    tx.commit_with(commit_options("list/update"));

    Ok(doc)
}

/// `text`: a spliced text object, a delete that leaves a hole, a prepend, and
/// a second text object — three commits, so each one's ops land at the offsets
/// the ones before it left behind.
fn build_text() -> Result<Automerge, Box<dyn Error>> {
    let mut doc = new_doc(ACTOR_A)?;

    let mut tx = doc.transaction();
    let text = tx.put_object(ROOT, "text", ObjType::Text)?;
    tx.splice_text(&text, 0, 0, "hello world")?;
    tx.commit_with(commit_options("text/base"));

    let text_id = child_id(&doc, "text")?;

    let mut tx = doc.transaction();
    tx.splice_text(&text_id, 5, 6, "")?;
    tx.commit_with(commit_options("text/delete"));

    let mut tx = doc.transaction();
    tx.splice_text(&text_id, 0, 0, "αβγ")?;
    let second = tx.put_object(ROOT, "second", ObjType::Text)?;
    tx.splice_text(&second, 0, 0, "second")?;
    tx.commit_with(commit_options("text/prepend"));

    Ok(doc)
}

/// `marks`: every expansion there is, on one text object and on a second one
/// written only to carry the four expansion flags.
///
/// The unmark shares a commit with the marks it removes, so the fold has to
/// read the change rather than the state at its end. The four marks over
/// `[0, 1)` of `mark_modes` differ **only** in expansion, which is what
/// separates an implementation that stores the flag from one that applies it
/// and drops it.
fn build_marks() -> Result<Automerge, Box<dyn Error>> {
    let mut doc = new_doc(ACTOR_A)?;

    let mut tx = doc.transaction();
    let text = tx.put_object(ROOT, "text", ObjType::Text)?;
    tx.splice_text(&text, 0, 0, "abcdefghij")?;
    tx.commit_with(commit_options("marks/base"));

    let text_id = child_id(&doc, "text")?;

    let mut tx = doc.transaction();
    tx.mark(&text_id, Mark::new("bold".to_string(), 0i64, 3, 6), ExpandMark::After)?;
    tx.mark(&text_id, Mark::new("italic".to_string(), true, 0, 1), ExpandMark::None)?;
    tx.mark(&text_id, Mark::new("label".to_string(), "name", 6, 9), ExpandMark::Both)?;
    tx.unmark(&text_id, "italic", 0, 1, ExpandMark::None)?;
    let modes = tx.put_object(ROOT, "mark_modes", ObjType::Text)?;
    tx.splice_text(&modes, 0, 0, "xyz")?;
    tx.mark(&modes, Mark::new("none".to_string(), "active", 0, 1), ExpandMark::None)?;
    tx.mark(&modes, Mark::new("before".to_string(), "active", 0, 1), ExpandMark::Before)?;
    tx.mark(&modes, Mark::new("after".to_string(), "active", 0, 1), ExpandMark::After)?;
    tx.mark(&modes, Mark::new("both".to_string(), "active", 0, 1), ExpandMark::Both)?;
    tx.commit_with(commit_options("marks/edit"));

    Ok(doc)
}

/// The forked history `conflicts` and `merge` both start from: the base
/// committed by [`ACTOR_A`], loaded twice, each side writing its own change
/// against it.
///
/// `left` keeps [`ACTOR_A`] and carries on its history, `right` selects
/// [`ACTOR_B`]. Both changes depend on the base alone, so the document they
/// reach has two heads, one conflicted scalar, a counter that adds up to three,
/// and two concurrent sequence insertions.
fn forked() -> Result<(Automerge, Automerge), Box<dyn Error>> {
    let base = branch_base()?.save();
    let mut left = Automerge::load(&base)?.with_actor(actor(ACTOR_A)?);
    let mut right = Automerge::load(&base)?.with_actor(actor(ACTOR_B)?);
    let (left_list, right_list) = (child_id(&left, "list")?, child_id(&right, "list")?);

    let mut tx = left.transaction();
    tx.put(ROOT, "value", "left")?;
    tx.increment(ROOT, "counter", 1)?;
    tx.delete(ROOT, "doomed")?;
    tx.insert(&left_list, 1, "left")?;
    tx.commit_with(commit_options("branch/left"));

    let mut tx = right.transaction();
    tx.put(ROOT, "value", "right")?;
    tx.increment(ROOT, "counter", 2)?;
    tx.delete(ROOT, "doomed")?;
    tx.insert(&right_list, 1, "right")?;
    tx.commit_with(commit_options("branch/right"));

    Ok((left, right))
}

/// The commit both branches fork from: a scalar, a counter, a doomed key and a
/// three-element list.
fn branch_base() -> Result<Automerge, Box<dyn Error>> {
    let mut doc = new_doc(ACTOR_A)?;

    let mut tx = doc.transaction();
    tx.put(ROOT, "value", "base")?;
    tx.put(ROOT, "counter", counter(0)?)?;
    tx.put(ROOT, "doomed", "x")?;
    let list = tx.put_object(ROOT, "list", ObjType::List)?;
    tx.insert(&list, 0, 11i64)?;
    tx.insert(&list, 1, 22i64)?;
    tx.insert(&list, 2, 33i64)?;
    tx.commit_with(commit_options("branch/base"));

    Ok(doc)
}