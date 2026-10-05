//! Matched public-API benchmark against Automerge 0.12.0, ddbff535407e4d28cd2a82eaf6c6add08caa3bdd.
//! Manual transaction/commit semantics: transaction/manual_transaction.rs:59-96;
//! range items: iter/list_range.rs:14-37, iter/map_range.rs:13-39;
//! sync handshake and withheld acknowledgements: bench/zautomerge_bench.zig:1419-1582.
//! Default Rust System allocator; no allocation or leak accounting is claimed.

use std::collections::BTreeMap;
use std::error::Error;
use std::hint::black_box;
use std::io::{self, Write};
use std::time::Instant;

use automerge::sync::{Message, State, SyncDoc};
use automerge::transaction::{CommitOptions, Transactable};
use automerge::{ActorId, AutoCommit, Automerge, ChangeHash, ObjId, ObjType, Patch, PatchAction, Prop, ReadDoc, ScalarValue, ScalarValueRef, Value, ValueRef, ROOT};
use serde_json::json;

type Result<T, E = Box<dyn Error>> = std::result::Result<T, E>;
type Phases = BTreeMap<&'static str, u64>;

fn elapsed(start: Instant) -> u64 {
    u64::try_from(start.elapsed().as_nanos()).expect("phase duration exceeds u64 nanoseconds")
}

fn add(phases: &mut Phases, name: &'static str, ns: u64) {
    *phases.entry(name).or_default() += ns;
}

fn new_doc(actor: &str) -> Automerge {
    Automerge::new().with_actor(ActorId::from(actor.as_bytes()))
}

fn options() -> CommitOptions {
    CommitOptions::default().with_time(0)
}

#[derive(Default)]
struct Checksum(u64);
impl Checksum {
    fn mix(&mut self, value: u64) {
        self.0 = self.0.wrapping_mul(0x9E3779B97F4A7C15).wrapping_add(value);
    }
    fn bytes(&mut self, bytes: &[u8]) {
        self.mix(bytes.len() as u64);
        for &byte in bytes { self.mix(u64::from(byte)); }
    }
}

fn require(condition: bool, message: &str) -> Result<()> {
    if condition { Ok(()) } else { Err(message.into()) }
}

fn heads(doc: &Automerge) -> Vec<String> {
    let mut result: Vec<_> = doc.get_heads().iter().map(ToString::to_string).collect();
    result.sort_unstable();
    result
}

fn object(doc: &Automerge, key: &str, kind: ObjType) -> Result<ObjId> {
    require(doc.length(ROOT) == 1, "unexpected root property count")?;
    let all = doc.get_all(ROOT, key)?;
    require(all.len() == 1, "missing or conflicting root object")?;
    let (value, id) = &all[0];
    require(matches!(value, Value::Object(actual) if *actual == kind), "incorrect root object type")?;
    require(doc.object_type(id)? == kind, "incorrect object type")?;
    Ok(id.clone())
}

fn int(value: &ValueRef<'_>) -> Result<i64> {
    match value {
        ValueRef::Scalar(ScalarValueRef::Int(value)) => Ok(*value),
        _ => Err("expected signed integer scalar".into()),
    }
}

fn verify_list(doc: &Automerge, count: usize) -> Result<u64> {
    let list = object(doc, "l", ObjType::List)?;
    require(doc.length(&list) == count, "list length differs")?;
    let mut checksum = Checksum::default();
    let mut seen = 0;
    for row in doc.list_range(&list, ..) {
        require(row.index == seen && !row.conflict, "list index or conflict differs")?;
        let value = int(&row.value)?;
        require(value == seen as i64, "list value differs")?;
        // An integer scalar has sequence width one; contiguous indices and exact
        // length/count independently check that no iterator row was skipped.
        checksum.mix(row.index as u64);
        checksum.mix(value as u64);
        seen += 1;
    }
    require(seen == count, "list iterator count differs")?;
    checksum.mix(seen as u64);
    Ok(checksum.0)
}

fn keys(prefix: char, n: usize) -> Vec<String> {
    (0..n).map(|i| format!("{prefix}{i:05}")).collect()
}

fn verify_map<'a>(doc: &Automerge, count: usize, expected: impl IntoIterator<Item = (&'a str, i64)>) -> Result<u64> {
    require(doc.length(ROOT) == count, "map length differs")?;
    let mut expected = expected.into_iter();
    let mut checksum = Checksum::default();
    let mut seen = 0;
    for row in doc.map_range(ROOT, ..) {
        require(!row.conflict, "map conflict")?;
        let (key, value) = expected.next().ok_or("unexpected extra map row")?;
        let actual_value = int(&row.value)?;
        require(row.key.as_bytes() == key.as_bytes() && actual_value == value, "map materialization differs")?;
        checksum.bytes(row.key.as_bytes());
        checksum.mix(actual_value as u64);
        seen += 1;
    }
    require(seen == count && expected.next().is_none(), "map iterator count differs")?;
    checksum.mix(seen as u64);
    Ok(checksum.0)
}

// Counts/operation bounds are derived from the independent workload, not from
// materialization. First dependencies name the independently constructed base.
fn verify_actor_history(metas: &[automerge::ChangeMetadata<'_>], actor: &str, ops: &[usize], start: u64, dependency: Option<ChangeHash>) -> Result<()> {
    let changes = metas.iter().filter(|change| change.actor.to_bytes() == actor.as_bytes());
    require(changes.clone().count() == ops.len(), "actor change count differs")?;
    let mut next = start;
    let mut parent = dependency;
    for (i, (change, &count)) in changes.zip(ops).enumerate() {
        require(change.seq == i as u64 + 1, "change sequence differs")?;
        require(change.timestamp == 0 && change.message.is_none() && change.author.is_none() && change.extra.is_empty(), "change metadata differs")?;
        require(change.start_op == next && change.max_op == next + count as u64 - 1, "change operation bounds differ")?;
        require(change.deps.as_slice() == parent.as_slice(), "change dependencies differ")?;
        next += count as u64;
        parent = Some(change.hash);
    }
    Ok(())
}

fn verify_history(doc: &Automerge, actor: &str, ops: &[usize]) -> Result<()> {
    let mut metas = doc.get_changes_meta(&[]);
    require(metas.len() == ops.len(), "document change count differs")?;
    metas.sort_unstable_by_key(|change| change.seq);
    require(doc.get_heads().len() == 1, "expected one head")?;
    verify_actor_history(&metas, actor, ops, 1, None)
}

fn list_workload(workload: &str, n: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let actor = if workload == "insert-growth" { "bench-insert-loop" } else { "bench-list-width-fixture" };
    let mut doc = new_doc(actor);
    let values: Vec<i64> = if workload == "list-range-batch" { (0..n as i64).collect() } else { Vec::new() };
    let mut tx = doc.transaction();
    let list = tx.put_object(ROOT, "l", ObjType::List)?;
    add(phases, "setup", elapsed(setup));
    let mutation = Instant::now();
    if workload == "list-range-batch" {
        tx.splice(&list, 0, 0, values.iter().copied())?;
    } else {
        for i in 0..n { tx.insert(&list, i, i as i64)?; }
    }
    add(phases, "mutation", elapsed(mutation));
    let commit = Instant::now();
    let committed = tx.commit_with(options());
    add(phases, "commit", elapsed(commit));
    black_box(&committed);
    if workload != "insert-growth" {
        let read = Instant::now();
        for row in doc.list_range(&list, ..) { black_box(row); }
        add(phases, "read", elapsed(read));
    }
    let verify = Instant::now();
    let checksum = verify_list(&doc, n)?;
    verify_history(&doc, actor, &[n + 1])?;
    let result_heads = heads(&doc);
    if workload == "insert-growth" {
        let bytes = doc.save();
        let loaded = Automerge::load(&bytes)?;
        require(verify_list(&loaded, n)? == checksum && heads(&loaded) == result_heads, "insert reload differs")?;
        verify_history(&loaded, actor, &[n + 1])?;
        black_box((&bytes, &loaded));
    }
    add(phases, "verify", elapsed(verify));
    black_box((&doc, &values));
    Ok((checksum, result_heads))
}

fn text_workload(n: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let actor = "bench-text-edits";
    let mut doc = new_doc(actor);
    let initial = "a".repeat(4096);
    let mut state = 98765u64;
    let mut positions = Vec::with_capacity(n);
    for i in 0..n {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        positions.push((state % (4096 + i) as u64) as usize);
    }
    let mut tx = doc.transaction();
    let text = tx.put_object(ROOT, "t", ObjType::Text)?;
    tx.splice_text(&text, 0, 0, &initial)?;
    black_box(tx.commit_with(options()));
    add(phases, "setup", elapsed(setup));
    for &position in &positions {
        let setup = Instant::now();
        let mut tx = doc.transaction();
        add(phases, "setup", elapsed(setup));
        let mutation = Instant::now();
        tx.splice_text(&text, position, 0, ".")?;
        add(phases, "mutation", elapsed(mutation));
        let commit = Instant::now();
        let committed = tx.commit_with(options());
        add(phases, "commit", elapsed(commit));
        black_box(&committed);
    }
    let verify = Instant::now();
    // Replay the generator separately rather than taking mutation positions as
    // the oracle. The expected bytes never come from the Automerge document.
    let mut expected = vec![b'a'; 4096];
    let mut state = 98765u64;
    for i in 0..n {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        expected.insert((state % (4096 + i) as u64) as usize, b'.');
    }
    let text = object(&doc, "t", ObjType::Text)?;
    let actual = doc.text(&text)?;
    require(actual.as_bytes() == expected && doc.length(&text) == expected.len(), "text materialization differs")?;
    let mut seen = 0;
    for row in doc.list_range(&text, ..) {
        require(row.index == seen && !row.conflict, "text index or conflict differs")?;
        match &row.value {
            ValueRef::Scalar(ScalarValueRef::Str(s)) => require(s.as_bytes() == &expected[seen..seen + 1], "text row differs")?,
            _ => return Err("text row is not a string scalar".into()),
        }
        seen += 1;
    }
    require(seen == expected.len(), "text iterator count differs")?;
    let mut ops = vec![1; n + 1];
    ops[0] = 4097;
    verify_history(&doc, actor, &ops)?;
    let mut checksum = Checksum::default();
    checksum.bytes(actual.as_bytes());
    let result_heads = heads(&doc);
    add(phases, "verify", elapsed(verify));
    black_box((&doc, &positions, &initial));
    Ok((checksum.0, result_heads))
}

fn map_workload(workload: &str, n: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let updates = workload == "map-updates";
    let actor = if updates { "bench-map-updates" } else { "bench-save-load" };
    let mut doc = new_doc(actor);
    let keys = keys('k', n);
    let mut tx = doc.transaction();
    for (i, key) in keys.iter().enumerate() { tx.put(ROOT, key.as_str(), if updates { 0i64 } else { i as i64 })?; }
    black_box(tx.commit_with(options()));
    let prebuilt = if workload == "load" { Some(doc.save()) } else { None };
    if updates {
        let mut tx = doc.transaction();
        add(phases, "setup", elapsed(setup));
        let mutation = Instant::now();
        for (i, key) in keys.iter().enumerate() { tx.put(ROOT, key.as_str(), i as i64 + 1)?; }
        add(phases, "mutation", elapsed(mutation));
        let commit = Instant::now();
        let committed = tx.commit_with(options());
        add(phases, "commit", elapsed(commit));
        black_box(&committed);
    } else { add(phases, "setup", elapsed(setup)); }
    let bytes = if workload == "save" {
        let save = Instant::now();
        let bytes = doc.save();
        add(phases, "save", elapsed(save));
        Some(bytes)
    } else { prebuilt };
    let loaded = if workload == "load" {
        let load = Instant::now();
        let loaded = Automerge::load(bytes.as_ref().unwrap())?;
        add(phases, "load", elapsed(load));
        Some(loaded)
    } else { None };
    let verify = Instant::now();
    let expected = || keys.iter().enumerate().map(|(i, key)| (key.as_str(), i as i64 + i64::from(updates)));
    let checksum = verify_map(&doc, n, expected())?;
    let ops = if updates { vec![n, n] } else { vec![n] };
    verify_history(&doc, actor, &ops)?;
    let result_heads = heads(&doc);
    // Save reload is untimed verification, while load uses its already timed result.
    let saved_reload = if workload == "save" { Some(Automerge::load(bytes.as_ref().unwrap())?) } else { None };
    if let Some(loaded) = loaded.as_ref().or(saved_reload.as_ref()) {
        require(verify_map(loaded, n, expected())? == checksum && heads(loaded) == result_heads, "map reload differs")?;
        verify_history(loaded, actor, &ops)?;
    }
    add(phases, "verify", elapsed(verify));
    black_box((&doc, &bytes, &loaded, &saved_reload));
    Ok((checksum, result_heads))
}

fn merge_workload(n: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let mut base = new_doc("bench-merge-base");
    let mut tx = base.transaction();
    tx.put(ROOT, "base", 0i64)?;
    black_box(tx.commit_with(options()));
    let bytes = base.save();
    let mut left = Automerge::load(&bytes)?.with_actor(ActorId::from(b"bench-merge-left".as_slice()));
    let mut right = Automerge::load(&bytes)?.with_actor(ActorId::from(b"bench-merge-right".as_slice()));
    let left_keys = keys('l', n);
    let right_keys = keys('r', n);
    for (doc, keys) in [(&mut left, &left_keys), (&mut right, &right_keys)] {
        let mut tx = doc.transaction();
        for (i, key) in keys.iter().enumerate() { tx.put(ROOT, key.as_str(), i as i64)?; }
        black_box(tx.commit_with(options()));
    }
    let mut expected_heads = heads(&left);
    expected_heads.extend(heads(&right));
    expected_heads.sort_unstable();
    add(phases, "setup", elapsed(setup));
    let merge = Instant::now();
    let merged_heads = left.merge(&mut right)?;
    add(phases, "merge", elapsed(merge));
    black_box(&merged_heads);
    let verify = Instant::now();
    let expected = std::iter::once(("base", 0i64))
        .chain(left_keys.iter().enumerate().map(|(i, key)| (key.as_str(), i as i64)))
        .chain(right_keys.iter().enumerate().map(|(i, key)| (key.as_str(), i as i64)));
    let checksum = verify_map(&left, 2 * n + 1, expected)?;
    verify_map(&base, 1, std::iter::once(("base", 0i64)))?;
    let right_expected = std::iter::once(("base", 0i64))
        .chain(right_keys.iter().enumerate().map(|(i, key)| (key.as_str(), i as i64)));
    verify_map(&right, n + 1, right_expected)?;
    let mut metas = left.get_changes_meta(&[]);
    require(metas.len() == 3 && left.get_heads().len() == 2, "merge history shape differs")?;
    metas.sort_unstable_by_key(|change| change.seq);
    verify_history(&base, "bench-merge-base", &[1])?;
    let base_hash = base.get_heads()[0];
    verify_actor_history(&metas, "bench-merge-base", &[1], 1, None)?;
    verify_actor_history(&metas, "bench-merge-left", &[n], 2, Some(base_hash))?;
    verify_actor_history(&metas, "bench-merge-right", &[n], 2, Some(base_hash))?;
    let result_heads = heads(&left);
    require(result_heads == expected_heads, "merge heads differ")?;
    add(phases, "verify", elapsed(verify));
    black_box((&base, &bytes, &left, &right));
    Ok((checksum, result_heads))
}

fn message(doc: &Automerge, state: &mut State) -> Result<Message> {
    doc.generate_sync_message(state).ok_or_else(|| "unexpected quiet sync endpoint".into())
}

fn sync_workload(n: usize, rounds: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let actor = "bench-sync-roundtrip-local";
    let mut local = new_doc(actor);
    let mut peer = new_doc("bench-sync-roundtrip-peer");
    let mut ls = State::new();
    let mut rs = State::new();
    let mut tx = local.transaction();
    let list = tx.put_object(ROOT, "l", ObjType::List)?;
    black_box(tx.commit_with(options()));
    let hello = message(&peer, &mut rs)?;
    local.receive_sync_message(&mut ls, hello)?;
    let snapshot = message(&local, &mut ls)?;
    require(ls.sent_hashes.len() == 1, "handshake did not record snapshot hash")?;
    peer.receive_sync_message(&mut rs, snapshot)?;
    let ack = message(&peer, &mut rs)?;
    local.receive_sync_message(&mut ls, ack)?;
    require(ls.sent_hashes.is_empty(), "handshake did not prune sent hashes")?;
    add(phases, "setup", elapsed(setup));
    let mut written = 0;
    let mut sent_before = 0;
    for round in 0..rounds {
        for _ in 0..n {
            let setup = Instant::now();
            let mut tx = local.transaction();
            add(phases, "setup", elapsed(setup));
            let mutation = Instant::now();
            tx.insert(&list, written, written as i64)?;
            add(phases, "mutation", elapsed(mutation));
            let commit = Instant::now();
            let committed = tx.commit_with(options());
            add(phases, "commit", elapsed(commit));
            black_box(&committed);
            written += 1;
        }
        let generate = Instant::now();
        let generated = local.generate_sync_message(&mut ls);
        add(phases, "generate", elapsed(generate));
        let generated = generated.ok_or("local went quiet during sync round")?;
        let verify = Instant::now();
        require(ls.sent_hashes.len() == sent_before + n + usize::from(round == 0), "sync sent hash growth differs")?;
        sent_before = ls.sent_hashes.len();
        add(phases, "verify", elapsed(verify));
        let receive = Instant::now();
        peer.receive_sync_message(&mut rs, generated)?;
        add(phases, "receive", elapsed(receive));
    }
    let verify = Instant::now();
    let expected_hashes: std::collections::BTreeSet<_> = local.get_changes_meta(&[]).iter().map(|c| c.hash).collect();
    require(ls.sent_hashes == expected_hashes, "sent hashes do not equal document history")?;
    add(phases, "verify", elapsed(verify));
    let generate = Instant::now();
    let final_ack = peer.generate_sync_message(&mut rs);
    add(phases, "generate", elapsed(generate));
    let final_ack = final_ack.ok_or("peer went quiet before final acknowledgment")?;
    let receive = Instant::now();
    local.receive_sync_message(&mut ls, final_ack)?;
    add(phases, "receive", elapsed(receive));
    let verify = Instant::now();
    require(local.generate_sync_message(&mut ls).is_none(), "local is not quiet after acknowledgment")?;
    require(ls.sent_hashes.is_empty(), "final acknowledgment did not prune sent hashes")?;
    let checksum = verify_list(&local, written)?;
    require(verify_list(&peer, written)? == checksum, "peer materialization differs")?;
    let ops = vec![1; written + 1];
    verify_history(&local, actor, &ops)?;
    verify_history(&peer, actor, &ops)?;
    let result_heads = heads(&local);
    require(heads(&peer) == result_heads, "sync heads differ")?;
    add(phases, "verify", elapsed(verify));
    black_box((&local, &peer, &ls, &rs));
    Ok((checksum, result_heads))
}

fn diff_id(id: &ObjId, counter: u64) -> bool {
    matches!(id, ObjId::Id(actual, actor, _) if *actual == counter && actor.to_bytes() == b"bench-diff-matrix")
}

fn verify_diff_patches(patches: &[Patch], names: &[String], forward: bool) -> Result<u64> {
    require(patches.len() == names.len(), "diff patch count differs")?;
    let n = names.len();
    let mut checksum = Checksum::default();
    checksum.mix(n as u64);
    for (i, patch) in patches.iter().enumerate() {
        require(diff_id(&patch.obj, 1), "diff patch target identity differs")?;
        // patch_builder.rs:143-164,296-317 always emits the global parent
        // path, including for diff_obj(m, before, after, false).
        require(patch.path.len() == 1, "diff path length differs")?;
        let (parent, property) = &patch.path[0];
        require(matches!(parent, ObjId::Root) && matches!(property, Prop::Map(key) if key == "m"), "diff parent path differs")?;
        let expected = if forward { i as i64 + 1 } else { 0 };
        match &patch.action {
            PatchAction::PutMap { key, value: (value, id), conflict } => {
                require(key == &names[i] && !conflict, "diff key/order/conflict differs")?;
                require(matches!(value, Value::Scalar(scalar) if matches!(scalar.as_ref(), ScalarValue::Int(actual) if *actual == expected)), "diff scalar type/value differs")?;
                let counter = if forward { n + 2 + i } else { 2 + i };
                require(diff_id(id, counter as u64), "diff producing operation identity differs")?;
                checksum.bytes(key.as_bytes());
                checksum.mix(expected as u64);
            }
            _ => return Err("unexpected diff patch action".into()),
        }
    }
    checksum.mix(n as u64);
    Ok(checksum.0)
}

fn diff_workload(workload: &str, n: usize, phases: &mut Phases) -> Result<(u64, Vec<String>)> {
    let setup = Instant::now();
    let mut doc = AutoCommit::new().with_actor(ActorId::from(b"bench-diff-matrix".as_slice()));
    let names = keys('k', n);
    let map = doc.put_object(ROOT, "m", ObjType::Map)?;
    for key in &names { doc.put(&map, key.as_str(), 0i64)?; }
    require(doc.commit_with(options()).is_some(), "missing first diff fixture commit")?;
    let before = doc.get_heads();
    for (i, key) in names.iter().enumerate() { doc.put(&map, key.as_str(), i as i64 + 1)?; }
    require(doc.commit_with(options()).is_some(), "missing second diff fixture commit")?;
    let after = doc.get_heads();
    // autocommit.rs:254-255,326-334: object precedes before/after and
    // nonrecursive diff_obj is fallible; root diff is infallible.
    let subtree = workload == "diff-subtree";
    if workload == "diff-repeat" {
        let prime = doc.diff(&before, &after);
        black_box(&prime);
        drop(prime);
    } else if subtree {
        let prime = doc.diff_obj(&map, &before, &after, false)?;
        black_box(&prime);
        drop(prime);
    }
    add(phases, "setup", elapsed(setup));
    let calls = if workload == "diff-first" { 1 } else { 32 };
    let mut checksum = Checksum::default();
    for call in 0..calls {
        let forward = workload != "diff-rotate" || call % 2 == 0;
        let (from, to) = if forward { (&before, &after) } else { (&after, &before) };
        let patches = if subtree {
            let diff = Instant::now();
            let patches = doc.diff_obj(&map, from, to, false);
            add(phases, "diff", elapsed(diff));
            patches?
        } else {
            let diff = Instant::now();
            let patches = doc.diff(from, to);
            add(phases, "diff", elapsed(diff));
            patches
        };
        let verify = Instant::now();
        checksum.mix(verify_diff_patches(&patches, &names, forward)?);
        black_box(&patches);
        drop(patches);
        add(phases, "verify", elapsed(verify));
    }
    let verify = Instant::now();
    checksum.mix(calls as u64);
    require(before.len() == 1 && after.len() == 1, "diff fixture head count differs")?;
    require(diff_id(&map, 1) && doc.length(ROOT) == 1 && doc.object_type(&map)? == ObjType::Map, "diff fixture root shape differs")?;
    let mut root = doc.map_range(ROOT, ..);
    let child = root.next().ok_or("missing diff fixture child")?;
    require(child.key == "m" && !child.conflict && matches!(&child.value, ValueRef::Object(ObjType::Map)) && diff_id(&child.id(), 1), "diff fixture root child differs")?;
    require(root.next().is_none(), "unexpected diff fixture root property")?;
    drop(root);
    require(doc.length(&map) == n, "diff fixture child count differs")?;
    let mut seen = 0;
    for row in doc.map_range(&map, ..) {
        require(seen < n && row.key == names[seen] && !row.conflict && int(&row.value)? == seen as i64 + 1, "diff fixture materialization differs")?;
        seen += 1;
    }
    require(seen == n, "diff fixture iterator count differs")?;
    let mut metas = doc.get_changes_meta(&[]);
    require(metas.len() == 2, "diff fixture change count differs")?;
    metas.sort_unstable_by_key(|change| change.seq);
    verify_actor_history(&metas, "bench-diff-matrix", &[n + 1, n], 1, None)?;
    require(metas[0].hash == before[0] && metas[1].hash == after[0], "diff fixture saved boundary heads differ")?;
    drop(metas);
    let mut result_heads: Vec<_> = doc.get_heads().iter().map(ToString::to_string).collect();
    result_heads.sort_unstable();
    require(doc.get_heads() == after, "diff changed fixture heads")?;
    add(phases, "verify", elapsed(verify));
    black_box((&doc, &names, &before, &after));
    Ok((checksum.0, result_heads))
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    require(args.len() == 3, "usage: matched_bench WORKLOAD small|large")?;
    let workload = args[1].as_str();
    let large = match args[2].as_str() { "small" => false, "large" => true, _ => return Err("size must be small or large".into()) };
    let n = match workload {
        "insert-growth" | "list-range-seq" | "list-range-batch" | "map-updates" | "save" | "load" => if large { 10000 } else { 2500 },
        "text-edits" | "merge" => if large { 4096 } else { 1024 },
        "diff-first" | "diff-repeat" | "diff-rotate" | "diff-subtree" => if large { 4096 } else { 1024 },
        "sync-roundtrip" => if large { 400 } else { 200 },
        _ => return Err("unknown workload".into()),
    };
    let mut phases = Phases::new();
    let (checksum, heads) = match workload {
        "insert-growth" | "list-range-seq" | "list-range-batch" => list_workload(workload, n, &mut phases)?,
        "text-edits" => text_workload(n, &mut phases)?,
        "map-updates" | "save" | "load" => map_workload(workload, n, &mut phases)?,
        "merge" => merge_workload(n, &mut phases)?,
        "sync-roundtrip" => sync_workload(n, if large { 48 } else { 24 }, &mut phases)?,
        "diff-first" | "diff-repeat" | "diff-rotate" | "diff-subtree" => diff_workload(workload, n, &mut phases)?,
        _ => unreachable!(),
    };
    let record = json!({"implementation": "rust", "workload": workload, "size": args[2], "n": n,
        "phases_ns": phases, "checksum": format!("{checksum:016x}"), "heads": heads, "verified": true});
    let stdout = io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, &record)?;
    writeln!(out)?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("matched_bench: {error}");
        std::process::exit(1);
    }
}
