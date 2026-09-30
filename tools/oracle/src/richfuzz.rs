//! `rust/automerge/tests/rich_text_fuzz_crash.rs`, driven against the reference.
//!
//! The nine cases of that file are the port's **totality** cases: every one of
//! them exists because a fuzzer found an input on which the reference used to
//! panic, and the assertions are what the fixed reference does instead. An
//! oracle cannot "prove" that a panic is gone — only that the reference now
//! answers — so what this subcommand prints is the **answer for every case**:
//! the named error variant where upstream asserts one, the text, the spans, the
//! lengths, and the bytes `save()` produces.
//!
//! Each case is transcribed from the upstream file statement for statement,
//! including `commit_as`'s one-byte actors `[0]` and `[1]`, because the actor a
//! change is committed under decides which of two concurrent puts wins and how
//! `length` reads the conflicted position (`rich_text_fuzz_crash.rs:164-191`).
//!
//! The fixture cases (`:222-243`) read the same file the Zig suite reads, so
//! `FIXTURE_DIR` must resolve from the working directory, as it does for the
//! `fixtures` subcommand.
//!
//! Nothing here is a golden vector: no gate regenerates it, and the record it
//! prints is a description of the reference's answer rather than bytes another
//! implementation must reproduce.

use std::error::Error;
use std::io::Write;
use std::path::Path;

use automerge::iter::Span;
use automerge::marks::{ExpandMark, Mark};
use automerge::sync::{self, SyncDoc};
use automerge::transaction::Transactable;
use automerge::{ActorId, AutoCommit, Automerge, ObjType, ReadDoc, ScalarValue, ROOT};
use serde_json::{Value as Json, json};

use crate::{FIXTURE_DIR, emit, hex_encode};

/// The fixture both of the last two cases read, verified byte for byte against
/// the reference checkout before this file was written.
const BROKEN_MARK_FIXTURE: &str = "broken_zero_width_mark.automerge";

/// What a case returns: the record it prints, or an oracle-side failure.
type Case = Result<Json, Box<dyn Error>>;

/// `commit_as` (`rich_text_fuzz_crash.rs:10-13`): the actor is set and the change
/// is committed. The bytes are the upstream literal — `[0]` is a **one-byte**
/// actor whose only byte is zero, not "no actor".
fn commit_as(doc: &mut AutoCommit, bytes: &[u8]) {
    doc.set_actor(ActorId::from(bytes.to_vec()));
    doc.commit();
}

/// `save_load` (`rich_text_fuzz_crash.rs:15-22`): hydrate before, save, load the
/// bytes into a fresh document, hydrate after, and require the two mirrors to be
/// equal. The port of this compares the same two mirrors, which is the only
/// assertion in it — the bytes are printed for the port's own comparison.
fn save_load(doc: &mut AutoCommit) -> Case {
    let before = doc.hydrate(&ROOT, None)?;
    let bytes = doc.save();
    let len = bytes.len();
    let hex = hex_encode(&bytes);
    let loaded = AutoCommit::load(&bytes)?;
    let after = loaded.hydrate(&ROOT, None)?;
    let same = before == after;
    let before_debug = format!("{before:?}");
    let after_debug = format!("{after:?}");
    *doc = loaded;
    Ok(json!({
        "save_len": len,
        "save_hex": hex,
        "hydrated_equal": same,
        "hydrated": before_debug,
        "rehydrated": after_debug,
    }))
}

/// An error, in both its `Display` and its `Debug`. Upstream asserts on the
/// **variant**, and `Debug` is where the variant's payload is visible, so both
/// are printed: `Display` is what `load_rejects_...` matches on, and `Debug` is
/// what says whether the port's named error is the same refusal.
fn err_display(e: &impl std::fmt::Display) -> Json {
    json!({"outcome": "err", "display": e.to_string()})
}

/// Every span of `obj`, as the collection upstream asserts against and as this
/// file prints it. `ReadDoc::spans` returns an iterator, so the collection is
/// the same `.collect::<Vec<_>>()` upstream writes (`rich_text_fuzz_crash.rs:144`).
fn span_list(doc: &AutoCommit, obj: &automerge::ObjId) -> Vec<Span> {
    match doc.spans(obj) {
        Ok(spans) => spans.collect(),
        Err(_) => Vec::new(),
    }
}

// ── 1. splice_scalar_into_marked_text ────────────────────────────────────────
fn splice_scalar_into_marked_text() -> Case {
    // `rich_text_fuzz_crash.rs:25-44`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.update_text(&text, "abcd")?;
    doc.mark(
        &text,
        Mark::new("m".to_string(), true, 0, 4),
        ExpandMark::None,
    )?;

    let mut record = match doc.splice(&text, 2, 0, [1_i64]) {
        Ok(()) => json!({"outcome": "ok"}),
        Err(e) => json!({
            "outcome": "err",
            "display": e.to_string(),
            "debug": format!("{e:?}"),
        }),
    };
    // The refusal must leave the document alone. Upstream does not assert this,
    // so it is reported rather than compared.
    record["text_after"] = json!(doc.text(&text).unwrap_or_default());
    record["length_after"] = json!(doc.length(&text));
    record["spans_after"] = json!(format!("{:?}", span_list(&doc, &text)));
    Ok(record)
}

// ── 2. splice_string_into_marked_text ────────────────────────────────────────
fn splice_string_into_marked_text() -> Case {
    // `rich_text_fuzz_crash.rs:47-61`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.update_text(&text, "abcd")?;
    doc.mark(
        &text,
        Mark::new("m".to_string(), true, 0, 4),
        ExpandMark::None,
    )?;
    doc.splice(&text, 2, 0, ["x"])?;

    let got = doc.text(&text)?;
    let round = save_load(&mut doc)?;
    Ok(json!({
        "outcome": "ok",
        "text": got,
        "length": doc.length(&text),
        "spans": format!("{:?}", span_list(&doc, &text)),
        "marks": format!("{:?}", doc.marks(&text).unwrap_or_default()),
        "round_trip": round,
    }))
}

// ── 3. zero_width_unmark_on_empty_text_sync_from_fuzz_trace ──────────────────
fn zero_width_unmark_on_empty_text_sync() -> Case {
    // `rich_text_fuzz_crash.rs:64-92`
    let mut left = AutoCommit::new();
    let text = left.put_object(ROOT, "text", ObjType::Text)?;
    left.unmark(&text, "color", 0, 0, ExpandMark::After)?;
    left.commit();

    let mut right = left.fork();
    right.put(ROOT, "x", 1_i64)?;
    right.commit();

    let mut left_state = sync::State::new();
    let mut right_state = sync::State::new();
    let mut rounds: Vec<Json> = Vec::new();

    let message = left
        .sync()
        .generate_sync_message(&mut left_state)
        .ok_or("left generated no sync message")?;
    rounds.push(json!({"round": 0, "from": "left", "message": format!("{message:?}")}));
    right.sync().receive_sync_message(&mut right_state, message)?;

    let message = right
        .sync()
        .generate_sync_message(&mut right_state)
        .ok_or("right generated no sync message")?;
    rounds.push(json!({"round": 1, "from": "right", "message": format!("{message:?}")}));
    left.sync().receive_sync_message(&mut left_state, message)?;

    // Upstream asserts nothing here beyond "no panic", so the state after the
    // exchange is printed rather than compared: it is what the port's copy of
    // this case can additionally assert, and what says whether the two peers
    // actually converged.
    Ok(json!({
        "outcome": "ok",
        "rounds": rounds,
        "left_heads": left.get_heads().len(),
        "right_heads": right.get_heads().len(),
        "left_changes": left.get_changes(&[]).len(),
        "right_changes": right.get_changes(&[]).len(),
        "left_text": format!("{:?}", left.text(&text)),
        "right_text": format!("{:?}", right.text(&text)),
        "left_x": format!("{:?}", left.get(ROOT, "x")),
        "right_x": format!("{:?}", right.get(ROOT, "x")),
    }))
}

// ── 4. zero_width_mark_on_empty_text_from_fuzz_trace ─────────────────────────
fn zero_width_mark_on_empty_text() -> Case {
    // `rich_text_fuzz_crash.rs:95-115`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.unmark(&text, "italic", 0, 0, ExpandMark::After)?;
    commit_as(&mut doc, &[1]);
    doc.mark(
        &text,
        Mark::new("link".to_string(), true, 0, 0),
        ExpandMark::Before,
    )?;
    commit_as(&mut doc, &[1]);

    let round = save_load(&mut doc)?;
    Ok(json!({
        "outcome": "ok",
        "round_trip": round,
        "text": doc.text(&text).unwrap_or_default(),
        "length": doc.length(&text),
        "spans": format!("{:?}", span_list(&doc, &text)),
        "marks": format!("{:?}", doc.marks(&text).unwrap_or_default()),
        "changes": doc.get_changes(&[]).len(),
    }))
}

// ── 5. zero_width_mark_does_not_leak_to_later_text_object_from_fuzz_trace ────
fn zero_width_mark_does_not_leak() -> Case {
    // `rich_text_fuzz_crash.rs:118-150`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    commit_as(&mut doc, &[0]);
    doc.mark(
        &text,
        Mark::new("italic".to_string(), true, 0, 0),
        ExpandMark::After,
    )?;
    commit_as(&mut doc, &[0]);
    let other_text = doc.put_object(ROOT, "o1", ObjType::Text)?;
    commit_as(&mut doc, &[0]);
    doc.splice_text(&other_text, 0, 0, "tsxs")?;
    commit_as(&mut doc, &[1]);
    doc.splice_text(&other_text, 2, 0, "bbqiolaf")?;

    let spans = span_list(&doc, &other_text);
    Ok(json!({
        "outcome": "ok",
        "spans": format!("{spans:?}"),
        "span_count": spans.len(),
        "text": doc.text(&other_text).unwrap_or_default(),
        "other_length": doc.length(&other_text),
        "other_marks": format!("{:?}", doc.marks(&other_text).unwrap_or_default()),
        "text_spans": format!("{:?}", span_list(&doc, &text)),
        "text_marks": format!("{:?}", doc.marks(&text).unwrap_or_default()),
    }))
}

// ── 6. splice_text_at_length_over_conflicted_element_from_fuzz_trace ─────────
fn splice_text_at_length_over_conflicted_element() -> Case {
    // `rich_text_fuzz_crash.rs:164-191`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.splice_text(&text, 0, 0, "a")?;
    commit_as(&mut doc, &[0]);

    let mut fork = doc.fork();
    fork.put(&text, 0, ScalarValue::Int(1))?;
    commit_as(&mut fork, &[1]);

    doc.put(&text, 0, ScalarValue::Int(2))?;
    commit_as(&mut doc, &[0]);

    let mut record = json!({"outcome": "ok"});
    match doc.merge(&mut fork) {
        Ok(_) => record["merge"] = json!("ok"),
        Err(e) => {
            record["merge"] = json!({"err": e.to_string(), "debug": format!("{e:?}")});
            return Ok(record);
        }
    }

    // **The three numbers upstream asserts**, read before anything is written.
    let len_before = doc.length(&text);
    let all: Vec<_> = doc.get_all(&text, 0)?.into_iter().collect();
    let text_now = doc.text(&text)?;
    record["length"] = json!(len_before);
    record["get_all_len"] = json!(all.len());
    record["get_all_debug"] = json!(format!("{all:?}"));
    record["text"] = json!(text_now);
    record["text_chars"] = json!(text_now.chars().count());
    record["text_bytes"] = json!(text_now.len());
    record["spans"] = json!(format!("{:?}", span_list(&doc, &text)));

    // **The out-of-bounds append upstream calls "must never be out of bounds".**
    record["splice_at_length"] = match doc.splice_text(&text, len_before, 0, "b") {
        Ok(()) => json!("ok"),
        Err(e) => json!({"err": e.to_string(), "debug": format!("{e:?}")}),
    };
    commit_as(&mut doc, &[0]);
    record["length_after"] = json!(doc.length(&text));
    record["text_after"] = json!(doc.text(&text).unwrap_or_default());
    record["spans_after"] = json!(format!("{:?}", span_list(&doc, &text)));
    record["round_trip"] = save_load(&mut doc)?;
    Ok(record)
}

// ── 7. mark_within_single_multi_width_element_from_fuzz_trace ────────────────
fn mark_within_single_multi_width_element() -> Case {
    // `rich_text_fuzz_crash.rs:194-219`
    let mut doc = AutoCommit::new();
    let text = doc.put_object(ROOT, "text", ObjType::Text)?;
    doc.insert(&text, 0, "hello world")?;
    commit_as(&mut doc, &[0]);
    doc.mark(
        &text,
        Mark::new("bold".to_string(), true, 3, 8),
        ExpandMark::None,
    )?;
    commit_as(&mut doc, &[0]);

    let mut record = json!({
        "outcome": "ok",
        "text": doc.text(&text).unwrap_or_default(),
        "length": doc.length(&text),
        "spans": format!("{:?}", span_list(&doc, &text)),
        "marks": format!("{:?}", doc.marks(&text).unwrap_or_default()),
    });

    // `Automerge::load(&doc.save()).unwrap()` — the strict reload upstream does
    // before `save_load`, asked here separately so a failure names which of the
    // two reloads refused.
    let bytes = doc.save();
    record["save_len"] = json!(bytes.len());
    record["automerge_load"] = match Automerge::load(&bytes) {
        Ok(_) => json!("ok"),
        Err(e) => json!({"err": e.to_string(), "debug": format!("{e:?}")}),
    };
    record["round_trip"] = save_load(&mut doc)?;
    record["text_after_load"] = json!(doc.text(&text).unwrap_or_default());
    record["spans_after_load"] = json!(format!("{:?}", span_list(&doc, &text)));
    Ok(record)
}

// ── 8. load_rejects_historical_zero_width_mark_end_before_begin ──────────────
fn load_rejects_historical_zero_width_mark() -> Case {
    // `rich_text_fuzz_crash.rs:222-229`
    let bytes = std::fs::read(Path::new(FIXTURE_DIR).join(BROKEN_MARK_FIXTURE))?;
    let mut record = json!({"outcome": "ok", "fixture": BROKEN_MARK_FIXTURE, "fixture_len": bytes.len()});
    match Automerge::load(&bytes) {
        Ok(_) => record["load"] = json!("ok"),
        Err(e) => {
            let display = e.to_string();
            record["load"] = json!({
                "err": display,
                "debug": format!("{e:?}"),
                "contains_invalid_mark_operation_order":
                    display.contains("invalid mark operation order"),
            });
        }
    }
    Ok(record)
}

// ── 9. rescue_recovers_snapshot_from_historical_zero_width_mark_order ────────
fn rescue_recovers_snapshot() -> Case {
    // `rich_text_fuzz_crash.rs:232-243`
    let bytes = std::fs::read(Path::new(FIXTURE_DIR).join(BROKEN_MARK_FIXTURE))?;
    let mut record = json!({"outcome": "ok", "fixture": BROKEN_MARK_FIXTURE, "fixture_len": bytes.len()});
    match Automerge::rescue(&bytes) {
        Ok(value) => {
            record["rescue"] = json!("ok");
            record["value"] = json!(format!("{value:?}"));
        }
        Err(e) => {
            record["rescue"] = json!("err");
            record["rescue_err"] = json!(e.to_string());
            record["rescue_debug"] = json!(format!("{e:?}"));
        }
    }
    Ok(record)
}

/// Run every case, in upstream's order, and print one record per case.
///
/// **Nine cases, nine records**, and the count is asserted rather than hoped
/// for: a case dropped from the table below would otherwise leave the file
/// quietly shorter than the file it ports.
pub fn richfuzz_command(out: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    let cases: [(&str, fn() -> Case); 9] = [
        ("splice_scalar_into_marked_text", splice_scalar_into_marked_text),
        ("splice_string_into_marked_text", splice_string_into_marked_text),
        (
            "zero_width_unmark_on_empty_text_sync_from_fuzz_trace",
            zero_width_unmark_on_empty_text_sync,
        ),
        (
            "zero_width_mark_on_empty_text_from_fuzz_trace",
            zero_width_mark_on_empty_text,
        ),
        (
            "zero_width_mark_does_not_leak_to_later_text_object_from_fuzz_trace",
            zero_width_mark_does_not_leak,
        ),
        (
            "splice_text_at_length_over_conflicted_element_from_fuzz_trace",
            splice_text_at_length_over_conflicted_element,
        ),
        (
            "mark_within_single_multi_width_element_from_fuzz_trace",
            mark_within_single_multi_width_element,
        ),
        (
            "load_rejects_historical_zero_width_mark_end_before_begin",
            load_rejects_historical_zero_width_mark,
        ),
        (
            "rescue_recovers_snapshot_from_historical_zero_width_mark_order",
            rescue_recovers_snapshot,
        ),
    ];
    assert_eq!(cases.len(), 9, "every upstream case must have a table row");

    for (name, f) in cases {
        let mut record = match f() {
            Ok(record) => record,
            Err(e) => json!({"outcome": "oracle_error", "error": e.to_string()}),
        };
        record["kind"] = json!("richfuzz");
        record["case"] = json!(name);
        emit(out, &record)?;
    }
    Ok(())
}
