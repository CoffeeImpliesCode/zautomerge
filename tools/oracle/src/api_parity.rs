//! Bounded public-consumer probes for Automerge 0.12.0 ddbff535.
//! Values, patches, hashes and bytes below are computed by the reference, never fixtures.
//! Source citations are relative to the pinned rust/automerge checkout.
use std::{error::Error, io::Write};
use automerge::{ActorId, Author, AutoCommit, Automerge, AutoSerde, Change, ChangeHash,
    LoadOptions, ObjId, ObjType, OnPartialLoad, Patch, PatchAction, PatchLog, ReadDoc,
    ScalarValue, StringMigration, TextEncoding, Value, ROOT};
use automerge::transaction::{CommitOptions, Transactable};
use automerge::sync::{State, SyncDoc};
use serde_json::{json, Value as Json};
use sha2::{Digest, Sha256};
use crate::{actor, emit, hex_encode, ACTOR_A, ACTOR_B, FIXTURE_DIR};

type Result<T = ()> = std::result::Result<T, Box<dyn Error>>;
fn options() -> CommitOptions { CommitOptions::default().with_time(0) }
fn auto() -> Result<AutoCommit> { Ok(AutoCommit::new().with_actor(actor(ACTOR_A)?)) }
fn raw() -> Result<Automerge> { Ok(Automerge::new().with_actor(actor(ACTOR_A)?)) }
fn tree<R: ReadDoc>(doc: &R) -> Result<Json> { Ok(serde_json::to_value(AutoSerde::from(doc))?) }
fn record(out: &mut dyn Write, scenario: &str, source: &str, data: Json) -> Result {
    emit(out, &json!({"kind":"api-parity", "scenario":scenario, "source":source, "data":data}))?;
    Ok(())
}
fn snapshot(doc: &Automerge) -> Result<Json> {
    Ok(json!({"value":tree(doc)?, "heads":doc.get_heads(), "save_hex":hex_encode(&doc.save())}))
}
fn object_type(kind: ObjType) -> &'static str {
    match kind {ObjType::Map=>"map",ObjType::List=>"list",ObjType::Text=>"text",ObjType::Table=>"table"}
}
fn scalar_type(value: &ScalarValue) -> &'static str {
    match value {
        ScalarValue::Null=>"null",ScalarValue::Boolean(_)=>"boolean",ScalarValue::Int(_)=>"int",
        ScalarValue::Uint(_)=>"uint",ScalarValue::F64(_)=>"float64",ScalarValue::Str(_)=>"str",
        ScalarValue::Bytes(_)=>"bytes",ScalarValue::Counter(_)=>"counter",ScalarValue::Timestamp(_)=>"timestamp",
        ScalarValue::Unknown{..}=>"unknown",
    }
}
fn stable_value(value: &Value<'_>) -> Json {
    match value {
        Value::Object(kind)=>json!({"type":"object","object_type":object_type(*kind)}),
        Value::Scalar(s)=>json!({"type":"scalar","datatype":scalar_type(s),"value":s}),
    }
}
fn prop(value: &automerge::Prop) -> Json {
    match value {automerge::Prop::Map(key)=>json!({"key":key}),automerge::Prop::Seq(index)=>json!({"index":index})}
}
fn read_value(value: &(Value<'_>,ObjId)) -> Json {json!([stable_value(&value.0),value.1])}
fn read_option(value: Option<(Value<'_>,ObjId)>) -> Json {
    value.as_ref().map(read_value).unwrap_or(Json::Null)
}
fn mark(value: &automerge::marks::Mark) -> Json {
    json!({"name":value.name(),"value":value.value(),"start":value.start,"end":value.end})
}
fn mark_set(value: Option<&automerge::marks::MarkSet>) -> Json {
    match value {
        None=>Json::Null,
        Some(set)=>Json::Object(set.iter().map(|(k,v)|(k.to_string(),serde_json::to_value(v).expect("scalar JSON"))).collect()),
    }
}
fn span(value: automerge::iter::Span) -> Result<Json> {
    match value {
        automerge::iter::Span::Block(m)=>Ok(json!({"type":"block","value":hydrated_json(&automerge::hydrate::Value::Map(m))?})),
        automerge::iter::Span::Text{text,marks}=>Ok(json!({"type":"text","text":text,"marks":mark_set(marks.as_deref())})),
    }
}
fn patch(value: &Patch) -> Json {
    let action=match &value.action {
        PatchAction::PutMap{key,value,conflict}=>json!({"type":"put_map","key":key,"value":read_value(value),"conflict":conflict}),
        PatchAction::PutSeq{index,value,conflict}=>json!({"type":"put_seq","index":index,"value":read_value(value),"conflict":conflict}),
        PatchAction::Insert{index,values}=>json!({"type":"insert","index":index,
            "values":values.iter().map(|(v,id,c)|json!([stable_value(v),id,c])).collect::<Vec<_>>()}),
        PatchAction::SpliceText{index,value,marks}=>json!({"type":"splice_text","index":index,
            "value":value.make_string(),"marks":mark_set(marks.as_ref())}),
        PatchAction::Increment{prop:p,value}=>json!({"type":"increment","prop":prop(p),"value":value}),
        PatchAction::Conflict{prop:p}=>json!({"type":"conflict","prop":prop(p)}),
        PatchAction::DeleteMap{key}=>json!({"type":"delete_map","key":key}),
        PatchAction::DeleteSeq{index,length}=>json!({"type":"delete_seq","index":index,"length":length}),
        PatchAction::Mark{marks}=>json!({"type":"mark","marks":marks.iter().map(mark).collect::<Vec<_>>()}),
    };
    json!({"obj":value.obj,"path":value.path.iter().map(|(id,p)|json!([id,prop(p)])).collect::<Vec<_>>(),"action":action})
}
fn patches(doc: &Automerge, log: &mut PatchLog) -> Json {
    json!(doc.make_patches(log).iter().map(patch).collect::<Vec<_>>())
}
fn map_item(item: automerge::iter::MapRangeItem<'_>) -> Json {
    let id=item.id();
    json!({"key":item.key,"value":stable_value(&item.value.into_value()),"id":id,"conflict":item.conflict})
}
fn list_item(item: automerge::iter::ListRangeItem<'_>) -> Json {
    let id=item.id();
    json!({"index":item.index,"value":stable_value(&item.value.into_value()),"id":id,"conflict":item.conflict})
}
fn parent(item: automerge::Parent) -> Json {
    json!({"obj":item.obj,"typ":object_type(item.typ),"prop":prop(&item.prop),"visible":item.visible})
}
fn doc_item(item: automerge::iter::DocObjItem<'_>) -> Result<Json> {
    use automerge::iter::DocItem;
    let obj=item.obj;
    let item=match item.item {
        DocItem::Map(m)=>{let mut j=map_item(m);j["type"]=json!("map");j},
        DocItem::List(l)=>{let mut j=list_item(l);j["type"]=json!("list");j},
        DocItem::Text(s)=>json!({"type":"text","span":span(s)?}),
    };
    Ok(json!({"obj":obj.as_ref(),"item":item}))
}
fn encoding(value: TextEncoding) -> &'static str {
    match value {TextEncoding::Utf8CodeUnit=>"utf8",TextEncoding::Utf16CodeUnit=>"utf16",
        TextEncoding::UnicodeCodePoint=>"codepoint",TextEncoding::GraphemeCluster=>"grapheme"}
}
fn error_observation(error: &automerge::AutomergeError) -> Json {
    use automerge::AutomergeError as E;
    let class=match error {
        E::ChangeGraph(_)=>"ChangeGraph",E::Deflate(_)=>"Deflate",E::DuplicateSeqNumber(..)=>"DuplicateSeqNumber",
        E::DuplicateAuthor(..)=>"DuplicateAuthor",E::DuplicateActorId(_)=>"DuplicateActorId",E::Fail=>"Fail",
        E::InvalidActorId(_)=>"InvalidActorId",E::InvalidActorIndex(_)=>"InvalidActorIndex",
        E::InvalidChangeHashBytes(_)=>"InvalidChangeHashBytes",E::InvalidCharacter(_)=>"InvalidCharacter",
        E::InvalidHash(_)=>"InvalidHash",E::InvalidIndex(_)=>"InvalidIndex",E::InvalidObjId(_)=>"InvalidObjId",
        E::InvalidObjIdFormat(_)=>"InvalidObjIdFormat",E::InvalidOp(_)=>"InvalidOp",E::InvalidSeq(_)=>"InvalidSeq",
        E::InvalidCursor(_)=>"InvalidCursor",E::InvalidCursorOp=>"InvalidCursorOp",E::InvalidCursorFormat=>"InvalidCursorFormat",
        E::InvalidValueType{..}=>"InvalidValueType",E::Load(_)=>"Load",E::LoadChangeError(_)=>"LoadChangeError",
        E::MissingCounter=>"MissingCounter",E::MissingHash(_)=>"MissingHash",E::MissingDeps=>"MissingDeps",
        E::NonChangeCompressed=>"NonChangeCompressed",E::NotAnObject=>"NotAnObject",E::HydrateError(_)=>"HydrateError",
        E::PatchLogMismatch(_)=>"PatchLogMismatch",E::EncodingError(_)=>"EncodingError",E::Unbundle(_)=>"Unbundle",
    };
    json!({"outcome":"error","class":class})
}
fn exid_result(result: std::result::Result<ObjId,automerge::ObjIdFromBytesError>) -> Json {
    use automerge::ObjIdFromBytesError as E;
    match result {
        Ok(value)=>json!({"outcome":"ok","value":value}),
        Err(e)=>{
            let class=match &e {E::NoVersion=>"NoVersion",E::InvalidVersion(_)=>"InvalidVersion",
                E::InvalidType(_)=>"InvalidType",E::ParseActorLen(_)=>"ParseActorLen",E::ParseActor=>"ParseActor",
                E::ParseCounter(_)=>"ParseCounter",E::ParseActorIdxHint(_)=>"ParseActorIdxHint"};
            json!({"outcome":"error","class":class})
        },
    }
}
fn hydrate_error(error: &automerge::error::HydrateError) -> Json {
    use automerge::error::HydrateError as E;
    let class=match error {E::Fail=>"Fail",E::InvalidIndex(_)=>"InvalidIndex",E::InvalidKey(_)=>"InvalidKey",
        E::BadIncrement=>"BadIncrement",E::InvalidMapOp=>"InvalidMapOp",E::InvalidListOp=>"InvalidListOp",
        E::InvalidTextOp(_)=>"InvalidTextOp",E::ApplyInvalidProp(_)=>"ApplyInvalidProp",E::InvalidEncoding=>"InvalidEncoding"};
    json!({"outcome":"error","class":class})
}
fn panic_observation(value: Box<dyn std::any::Any+Send>) -> Json {
    json!({"outcome":"panic","panic_debug":value.downcast_ref::<String>().cloned()
        .or_else(||value.downcast_ref::<&str>().map(|s|s.to_string())).unwrap_or_else(||"non-string panic".into())})
}

pub fn api_parity_command(out: &mut dyn Write) -> Result {
    lifecycle(out)?;
    native_text(out)?;
    loads(out)?;
    logged_routes(out)?;
    transactions(out)?;
    expanded(out)?;
    identities(out)?;
    rich(out)?;
    marks(out)?;
    sync_serde(out)?;
    Ok(())
}

fn lifecycle(out: &mut dyn Write) -> Result {
    // autocommit.rs:63-70,395-443,459-468,695-772; hydrate null bypasses isolation.
    let mut doc = auto()?;
    doc.put(ROOT,"a",1i64)?; doc.put(ROOT,"b",2i64)?;
    let pending = doc.pending_ops();
    let observed = tree(&doc)?;
    let mut copy = doc.clone();
    let clone_pending = copy.pending_ops();
    let source_after_clone = doc.pending_ops();
    let cancelled = copy.rollback();
    let first = doc.commit_with(options());
    let empty = doc.commit_with(options());
    let history = doc.get_changes(&[]);
    record(out,"held-clone-rollback","autocommit.rs:63-70,704-772",json!({
        "pending":pending,"read":observed,"clone_pending":clone_pending,
        "source_pending_after_clone":source_after_clone,"clone_cancelled":cancelled,
        "clone_value":tree(&copy)?,"source_value":tree(&doc)?,"hash":first,
        "empty_commit":empty,"history_len":history.len(),
        "change_hex":history.iter().map(|c|hex_encode(c.raw_bytes())).collect::<Vec<_>>() }))?;
    doc.put(ROOT,"c",3i64)?;
    let empty_hash = doc.empty_change(options());
    let history = doc.get_changes(&[]);
    record(out,"empty-change-closes-pending","autocommit.rs:753-772",json!({
        "hash":empty_hash,"history_len":history.len(),"op_counts":history.iter().map(Change::len).collect::<Vec<_>>(),
        "value":tree(&doc)?}))?;
    let mut doc = auto()?;
    doc.put(ROOT,"k",1i64)?; let h1 = doc.commit_with(options()).ok_or("first hash")?;
    doc.put(ROOT,"k",2i64)?; let h2 = doc.commit_with(options()).ok_or("second hash")?;
    doc.isolate(&[h1]);
    let isolated_heads = doc.get_heads();
    let mut state = State::new(); state.shared_heads = vec![h2];
    let has_full = doc.has_our_changes(&state);
    doc.put(ROOT,"p",3i64)?;
    let scope = tree(&doc)?;
    let explicit = read_option(doc.get_at(ROOT,"p",&[h1])?);
    let hydrate_current = doc.hydrate(ROOT,None)?;
    let hydrate_history = doc.hydrate(ROOT,Some(&[h1]))?;
    // Convert hydrated trees through real initialization rather than unstable HashMap Debug.
    let current = hydrated_json(&hydrate_current)?;
    let historical = hydrated_json(&hydrate_history)?;
    let before_integrate = doc.pending_ops(); doc.integrate();
    record(out,"isolation-hydrate-null","autocommit.rs:433-443,827-829,ReadDoc::hydrate",json!({
        "h1":h1,"h2":h2,"isolated_heads":isolated_heads,"has_full_changes":has_full,
        "scoped_serde":scope,"explicit_pending":explicit,"hydrate_null":current,
        "hydrate_historical":historical,"pending_before_integrate":before_integrate,
        "pending_after_integrate":doc.pending_ops(),"value":tree(&doc)?,"heads":doc.get_heads()}))?;
    // Test every close/read distinction on fresh clones of the same pending owner.
    let mut pending_doc = auto()?; pending_doc.put(ROOT,"pending",true)?;
    let mut cases = Vec::new();
    for barrier in ["read","hydrate","trait-missing","inherent-missing","trait-change","inherent-change",
        "heads","history","save","save-incremental","save-after","save-verify","fork","actor","author",
        "diff","diff-incremental","reset-diff","update-diff","apply","merge","load-incremental",
        "isolate","integrate","sync","has-our-changes"] {
        let mut d = pending_doc.clone();
        match barrier {
            "read" => { let _ = ReadDoc::get(&d,ROOT,"pending")?; },
            "trait-missing" => { let _ = ReadDoc::get_missing_deps(&d,&[]); },
            "inherent-missing" => { let _ = AutoCommit::get_missing_deps(&mut d,&[]); },
            "hydrate" => { let _ = ReadDoc::hydrate(&d,ROOT,None)?; },
            "trait-change" => { let _ = ReadDoc::get_change_by_hash(&d,&ChangeHash([0;32])); },
            "inherent-change" => { let _ = AutoCommit::get_change_by_hash(&mut d,&ChangeHash([0;32])); },
            "heads" => { let _ = AutoCommit::get_heads(&mut d); },
            "history" => { let _ = AutoCommit::get_changes(&mut d,&[]); },
            "save" => { let _ = AutoCommit::save(&mut d); },
            "fork" => { let _ = AutoCommit::fork(&mut d); },
            "actor" => { AutoCommit::set_actor(&mut d,actor(ACTOR_B)?); },
            "author" => { AutoCommit::set_author(&mut d,Some(Author::from(vec![0,255,128]))); },
            "diff" => { let _ = AutoCommit::diff(&mut d,&[],&[]); },
            "sync" => { let _ = SyncDoc::generate_sync_message(&mut AutoCommit::sync(&mut d),&mut State::new()); },
            "has-our-changes" => { let _ = AutoCommit::has_our_changes(&mut d,&State::new()); },
            "save-incremental" => { let _=AutoCommit::save_incremental(&mut d); },
            "save-after" => { let _=AutoCommit::save_after(&mut d,&[]); },
            "save-verify" => { let _=AutoCommit::save_and_verify(&mut d)?; },
            "diff-incremental" => { let _=AutoCommit::diff_incremental(&mut d); },
            "reset-diff" => { AutoCommit::reset_diff_cursor(&mut d); },
            "update-diff" => { AutoCommit::update_diff_cursor(&mut d); },
            "apply" => { AutoCommit::apply_changes(&mut d,Vec::<Change>::new())?; },
            "merge" => { AutoCommit::merge(&mut d,&mut auto()?)?; },
            "load-incremental" => { AutoCommit::load_incremental(&mut d,&[])?; },
            "isolate" => { AutoCommit::isolate(&mut d,&[]); },
            "integrate" => { AutoCommit::integrate(&mut d); },
            _ => unreachable!(),
        }
        let after = d.pending_ops();
        cases.push(json!({"route":barrier,"pending":after,"value":tree(&d)?,
            "changes":d.get_changes(&[]).iter().map(|c|json!({"hash":c.hash(),"actor":c.actor_id(),"time":c.timestamp()})).collect::<Vec<_>>() }));
    }
    record(out,"barrier-map","autocommit.rs:184-215,254,356-411,609-632,827-829",json!(cases))?;
    let h = pending_doc.commit_with(options()).ok_or("diff hash")?;
    let mut a = pending_doc.diff(&[],&[h]); let b = pending_doc.diff(&[],&[h]);
    let same = a == b; a.clear();
    record(out,"diff-owned-repeat","autocommit.rs:254-335",json!({"hash":h,"same":same,"second_len_after_first_clear":b.len(),"patches":b.iter().map(patch).collect::<Vec<_>>()}))?;
    let mut logged=auto()?;
    logged.put(ROOT,"v","first")?; let first=logged.commit_with(options()).ok_or("log first")?;
    logged.update_diff_cursor();
    logged.put(ROOT,"v","second")?; logged.commit_with(options());
    let forward=logged.diff_incremental();
    logged.isolate(&[first]);
    let backwards=logged.diff_incremental();
    logged.put(ROOT,"isolated",true)?; logged.commit_with(options());
    let isolated=logged.diff_incremental();
    logged.integrate();
    let integrated=logged.diff_incremental();
    record(out,"isolated-ordered-patches","autocommit.rs:433-443,patches/patch_log.rs:276-301",
        json!({"forward":forward.iter().map(patch).collect::<Vec<_>>(),"backward":backwards.iter().map(patch).collect::<Vec<_>>(),
            "isolated":isolated.iter().map(patch).collect::<Vec<_>>(),"integrated":integrated.iter().map(patch).collect::<Vec<_>>(),
            "state":tree(&logged)?,"heads":logged.get_heads()}))?;
    let mut left=fixture()?;
    let mut right=left.fork().with_actor(actor(ACTOR_B)?);
    { let mut tx=left.transaction();tx.put(ROOT,"left",true)?;tx.commit_with(options()); }
    { let mut tx=right.transaction();tx.put(ROOT,"right",true)?;tx.commit_with(options()); }
    left.merge(&mut right)?;
    let heads=left.get_heads(); let mut state=State::new();state.shared_heads=heads.clone();
    let exact=left.has_our_changes(&state);
    state.shared_heads.reverse();let reversed=left.has_our_changes(&state);
    state.shared_heads.pop();let subset=left.has_our_changes(&state);
    record(out,"has-our-changes-ordered","automerge.rs:2027-2029",
        json!({"heads":heads,"exact":exact,"reversed":reversed,"subset":subset,"state":snapshot(&left)?}))?;
    let mut d=auto()?;let list=d.put_object(ROOT,"list",ObjType::List)?;
    d.insert(&list,0,1i64)?;d.insert(&list,1,2i64)?;
    let old=d.commit_with(options()).ok_or("scoped list base")?;
    d.delete(&list,1)?;let new=d.commit_with(options()).ok_or("scoped list delete")?;
    d.isolate(&[old]);let length=d.length(&list);
    let scoped_get=read_option(d.get(&list,1)?);let all=d.get_all(&list,1)?;
    let all_json=all.iter().map(read_value).collect::<Vec<_>>();
    let explicit=read_option(d.get_at(&list,1,&[new])?);
    d.insert(&list,length,3i64)?;let appended=tree(&d)?;let pending=d.pending_ops();
    let cancelled=d.rollback();
    record(out,"isolated-list-boundary","autocommit.rs:ReadDoc scope,automerge-c/src/doc/list.rs:83-99,124-140",
        json!({"old_heads":[old],"full_heads":[new],"scoped_length":length,"scoped_get":scoped_get,
            "scoped_get_all":all_json,"explicit_new_get":explicit,"appended":appended,
            "pending":pending,"cancelled":cancelled,"rolled_back":tree(&d)?}))?;
    Ok(())
}

fn hydrated_json(value: &automerge::hydrate::Value) -> Result<Json> {
    // Use public hydrate traversal. Text Display is the reference's native renderer.
    use automerge::hydrate::Value as H;
    Ok(match value {
        H::Scalar(s) => serde_json::to_value(s)?,
        H::Map(m) => {
            let mut result = serde_json::Map::new();
            for (k,v) in m.iter() { result.insert(k.clone(),hydrated_json(&v.value)?); }
            Json::Object(result)
        },
        H::List(l) => Json::Array(l.iter().map(|v|hydrated_json(&v.value)).collect::<Result<Vec<_>>>()?),
        H::Text(t) => json!(t.to_string()),
    })
}
fn native_text(out: &mut dyn Write) -> Result {
    // text_value.rs:244-268 are private. Reach them through hydrate::Value::apply_patches
    // and hydrate/text.rs:29-55, without changing or building the upstream crate.
    for (label,encoding,initial) in [
        ("utf8",TextEncoding::Utf8CodeUnit,"é"),
        ("utf16",TextEncoding::Utf16CodeUnit,"😀"),
        ("codepoint",TextEncoding::UnicodeCodePoint,"a"),
        ("grapheme",TextEncoding::GraphemeCluster,"a") ] {
        let mut value = automerge::hydrate::Value::text(encoding,initial);
        let insert = if label == "utf8" || label == "utf16" { "X" } else { "\u{301}" };
        value.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::SpliceText{
            index:1,value:automerge::ConcreteTextValue::new(insert,encoding),marks:None}}])?;
        let inserted = hydrated_json(&value)?;
        value.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::DeleteSeq{index:0,length:1}}])?;
        let removed = hydrated_json(&value)?;
        let mut second_unit = automerge::hydrate::Value::text(encoding,initial);
        second_unit.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::SpliceText{
            index:1,value:automerge::ConcreteTextValue::new(insert,encoding),marks:None}}])?;
        second_unit.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::DeleteSeq{index:1,length:1}}])?;
        value.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::DeleteSeq{
            index:0,length:if label=="utf8" || label=="utf16" {2} else {1}}}])?;
        let mut remove_original = automerge::hydrate::Value::text(encoding,initial);
        remove_original.apply_patches(encoding,[Patch{obj:ROOT,path:vec![],action:PatchAction::DeleteSeq{index:0,length:1}}])?;
        record(out,&format!("native-text-{label}"),"text_value.rs:38-189,hydrate/text.rs:29-55",json!({
            "initial":initial,"insert":insert,"after_insert":inserted,"after_remove_first":removed,
            "remove_original_first":hydrated_json(&remove_original)?,
            "remove_inserted_unit":hydrated_json(&second_unit)?,"remove_remaining":hydrated_json(&value)?,
            "initial_native_debug":format!("{:?}",automerge::ConcreteTextValue::new(initial,encoding)),
            "insert_native_debug":format!("{:?}",automerge::ConcreteTextValue::new(insert,encoding))}))?;
    }
    Ok(())
}

fn load_result(result: std::result::Result<Automerge,automerge::AutomergeError>) -> Result<Json> {
    match result { Ok(d) => Ok(json!({"ok":snapshot(&d)?})),Err(e) => Ok(error_observation(&e)) }
}
fn unchecked_head_load_result(result: std::result::Result<Automerge,automerge::AutomergeError>) -> Result<Json> {
    // Intentionally unchecked stored heads need not name a reconstructed graph node.
    // Observe the real accepted state, but do not invoke save: change_graph.rs:141-144
    // dereferences those unchecked heads with unwrap while producing head indexes.
    match result {
        Ok(d)=>Ok(json!({"ok":{"value":tree(&d)?,"heads":d.get_heads()}})),
        Err(e)=>Ok(error_observation(&e)),
    }
}
fn replace_actor(change: &mut automerge::ExpandedChange, actor: ActorId) {
    use automerge::legacy::{ObjectId,Key,ElementId,SortedVec};
    let old=std::mem::replace(&mut change.actor_id,actor.clone());
    let replace=|id:&mut automerge::legacy::OpId| { if id.1==old { id.1=actor.clone(); } };
    for op in &mut change.operations {
        if let ObjectId::Id(id)=&mut op.obj {replace(id);}
        if let Key::Seq(ElementId::Id(id))=&mut op.key {replace(id);}
        let mut pred=op.pred.iter().cloned().collect::<Vec<_>>();
        for id in &mut pred {replace(id);}
        op.pred=SortedVec::from(pred);
    }
    change.hash=None;
}
fn take_uleb(bytes: &[u8], pos: &mut usize) -> Result<usize> {
    let mut value=0usize;
    for shift in (0..usize::BITS).step_by(7) {
        let byte=*bytes.get(*pos).ok_or("truncated local fixture ULEB")?; *pos+=1;
        let part=usize::from(byte&127);
        if part>usize::MAX>>shift {return Err("overflow local fixture ULEB".into());}
        value|=part<<shift;
        if byte&128==0 {return Ok(value);}
    }
    Err("oversized local fixture ULEB".into())
}
fn wrong_stored_heads(doc: &Automerge) -> Result<Vec<u8>> {
    // storage/document.rs:208-219; chunk.rs:302-310. Mutate a real writer's
    // stored head, leaving its derived history untouched, then restore checksum.
    let mut bytes=doc.save_with_options(automerge::SaveOptions{deflate:false,..Default::default()});
    if bytes.get(8)!=Some(&0) {return Err("expected reference document chunk".into());}
    let mut pos=9; let body_len=take_uleb(&bytes,&mut pos)?;
    let end=pos.checked_add(body_len).ok_or("fixture body overflow")?;
    if end!=bytes.len() {return Err("expected single document chunk".into());}
    let actors=take_uleb(&bytes,&mut pos)?;
    for _ in 0..actors {let len=take_uleb(&bytes,&mut pos)?;pos=pos.checked_add(len).ok_or("actor overflow")?;}
    let heads=take_uleb(&bytes,&mut pos)?;
    if heads==0 || pos.checked_add(32).is_none_or(|end|end>bytes.len()) {return Err("fixture missing head".into());}
    bytes[pos]^=1;
    let digest=Sha256::digest(&bytes[8..end]);
    bytes[4..8].copy_from_slice(&digest[..4]);
    Ok(bytes)
}
fn loads(out: &mut dyn Write) -> Result {
    // automerge.rs:855-1030; partial Ignore retains snapshot, not successfully decoded tail.
    let mut d = auto()?; d.put(ROOT,"base",1i64)?; d.commit_with(options());
    let base = d.save();
    let wrong_heads=wrong_stored_heads(&Automerge::load(&base)?)?;
    record(out,"load-unverified-mismatching-heads","storage/document.rs:208-219,311-320,storage/chunk.rs:302-310",json!({
        "input_hex":hex_encode(&wrong_heads),"check":load_result(Automerge::load(&wrong_heads))?,
        "unverified":unchecked_head_load_result(Automerge::load_unverified_heads(&wrong_heads))?,
        "dont_check":unchecked_head_load_result(Automerge::load_with_options(&wrong_heads,LoadOptions::new()
            .verification_mode(automerge::VerificationMode::DontCheck)))?}))?;
    d.put(ROOT,"tail",2i64)?; d.commit_with(options());
    let first_tail = d.save_incremental();
    d.put(ROOT,"partial",3i64)?; d.commit_with(options());
    let partial = d.save_incremental();
    let mut stream = base.clone(); stream.extend_from_slice(&first_tail); stream.extend_from_slice(&partial[..partial.len()-1]);
    let changes = d.get_changes(&[]);
    let mut change_first = Vec::new();
    for c in &changes[..changes.len()-1] { change_first.extend_from_slice(c.raw_bytes()); }
    change_first.extend_from_slice(&partial[..partial.len()-1]);
    let mut bad_checksum = base.clone(); bad_checksum[4] ^= 1;
    let mut log = PatchLog::active();
    let logged = Automerge::load_with_options(&base,LoadOptions::new().patch_log(&mut log))?;
    let active_patches = patches(&logged,&mut log);
    let mut inc = Automerge::load(&base)?; let count = inc.load_incremental(&stream)?;
    record(out,"load-partial-checksum","automerge.rs:855-1030,storage/load.rs",json!({
        "input_hex":hex_encode(&stream),"change_first_hex":hex_encode(&change_first),
        "refuse":load_result(Automerge::load(&stream))?,
        "ignore":load_result(Automerge::load_with_options(&stream,LoadOptions::new().on_partial_load(OnPartialLoad::Ignore)))?,
        "change_first_ignore":load_result(Automerge::load_with_options(&change_first,LoadOptions::new().on_partial_load(OnPartialLoad::Ignore)))?,
        "unverified_valid":load_result(Automerge::load_unverified_heads(&base))?,
        "checksum_hex":hex_encode(&bad_checksum),
        "checksum_unverified":load_result(Automerge::load_unverified_heads(&bad_checksum))?,
        "active_load_patches":active_patches,"incremental_count":count,"incremental":snapshot(&inc)? }))?;
    let mut string_doc = auto()?;
    let nested = string_doc.put_object(ROOT,"nested",ObjType::Map)?;
    string_doc.put(&nested,"s","legacy")?; string_doc.commit_with(options());
    let input = string_doc.save();
    let migrated = Automerge::load_with_options(&input,LoadOptions::new()
        .migrate_strings(StringMigration::ConvertToText).author(Author::from(vec![0xff,0,0x80])))?;
    // LoadOptions has no actor option: the migration internally allocates a random actor.
    // Preserve its actual author/state observations, and re-encode its actual decoded ops
    // with a deterministic actor for the binary comparison record (not a handwritten fixture).
    let source_changes = string_doc.get_changes(&[]);
    let all = migrated.get_changes(&[]);
    let migration = all.last().ok_or("missing migration change")?;
    let migration_author = migration.author().map(Author::into_owned);
    let mut canonical = migration.decode();
    replace_actor(&mut canonical,actor(ACTOR_B)?);
    let canonical_change:Change = canonical.into();
    let mut normalized = Automerge::load(&input)?;
    normalized.apply_changes([canonical_change.clone()])?;
    let migrated_value = tree(&migrated)?;
    let same_value = migrated_value == tree(&normalized)?;
    normalized.set_author(Some(Author::from(vec![0xff,0,0x80])));
    normalized.set_actor(actor("c3c3")?);
    { let mut tx=normalized.transaction(); tx.put(ROOT,"next",true)?; tx.commit_with(options()); }
    record(out,"load-string-migration-author","automerge.rs:991-999,1973-2020",json!({
        "input_hex":hex_encode(&input),"value":migrated_value,"author":migrated.get_author(),
        "base_change_count":source_changes.len(),"migration_author":migration_author,
        "migration_op_count":migration.len(),"normalized_equal":same_value,
        "canonical_migration":canonical_change.decode(),"canonical_hex":hex_encode(canonical_change.raw_bytes()),
        "canonical_hash":canonical_change.hash(),"next":snapshot(&normalized)?,
        "next_author":normalized.get_changes(&[]).last().and_then(Change::author),
        "object_type":object_type(migrated.object_type(migrated.get(&nested,"s")?.ok_or("migrated s")?.1)?)}))?;
    // Actual untrusted upstream regression bytes; no synthesized valid substitute.
    let fixture = std::fs::read(std::path::Path::new(FIXTURE_DIR).join("broken_zero_width_mark.automerge"))?;
    let rescue = match Automerge::rescue(&fixture) { Ok(v)=>json!({"ok":hydrated_json(&v)?}),Err(e)=>error_observation(&e) };
    record(out,"load-rescue-broken-mark","tests/rich_text_fuzz_crash.rs:222-243",json!({
        "fixture":"broken_zero_width_mark.automerge","input_hex":hex_encode(&fixture),
        "strict":load_result(Automerge::load(&fixture))?,"rescue":rescue}))?;
    Ok(())
}

fn fixture() -> Result<Automerge> {
    let mut d = raw()?;
    let mut tx = d.transaction();
    let m = tx.put_object(ROOT,"map",ObjType::Map)?; tx.put(&m,"k",7i64)?;
    let l = tx.put_object(ROOT,"list",ObjType::List)?; tx.insert(&l,0,true)?; tx.insert(&l,1,"two")?;
    let t = tx.put_object(ROOT,"text",ObjType::Text)?; tx.splice_text(&t,0,0,"a😀b")?;
    tx.commit_with(options());
    Ok(d)
}
fn logged_routes(out: &mut dyn Write) -> Result {
    // All four public external-log paths execute the same causal history.
    let source = fixture()?; let changes = source.get_changes(&[]);
    for route in ["apply","incremental","merge","sync"] {
        let mut target = Automerge::new().with_actor(actor(ACTOR_B)?);
        let mut log = PatchLog::active(); let mut messages = Vec::new();
        match route {
            "apply" => target.apply_changes_log_patches(changes.clone(),&mut log)?,
            "incremental" => { target.load_incremental_log_patches(&source.save(),&mut log)?; },
            "merge" => { target.merge_and_log_patches(&mut source.clone(),&mut log)?; },
            "sync" => {
                let mut sender = source.clone(); let mut ss = State::new(); let mut ts = State::new();
                for _ in 0..6 {
                    if let Some(m) = sender.generate_sync_message(&mut ss) {
                        messages.push(json!({"direction":"send","json":serde_json::to_value(&m)?,"hex":hex_encode(&m.clone().encode())}));
                        target.receive_sync_message_log_patches(&mut ts,m,&mut log)?;
                    }
                    if let Some(m) = target.generate_sync_message(&mut ts) { sender.receive_sync_message(&mut ss,m)?; }
                }
            }, _=>unreachable!(),
        }
        let ps = patches(&target,&mut log);
        record(out,&format!("external-log-{route}"),"automerge.rs:1033-1138,sync.rs:128-133",json!({
            "state":snapshot(&target)?,"patches":ps,"messages":messages}))?;
    }
    // Bind a log through a successful transaction, then offer it to another owner.
    let mut owner = raw()?;
    let mut tx = owner.transaction_log_patches(PatchLog::active())?; tx.put(ROOT,"owned",true)?;
    let (_,mut log) = tx.commit_with(options());
    let mut sender=source.clone(); let mut handshake_peer=Automerge::new().with_actor(actor(ACTOR_B)?);
    let mut ss=State::new(); let mut rs=State::new(); let mut data_message=None;
    for _ in 0..6 {
        if let Some(m)=sender.generate_sync_message(&mut ss) {
            if !m.changes.is_empty() {data_message=Some(m);break;}
            handshake_peer.receive_sync_message(&mut rs,m)?;
        }
        if let Some(m)=handshake_peer.generate_sync_message(&mut rs) {sender.receive_sync_message(&mut ss,m)?;}
    }
    let message=data_message.ok_or("sync did not generate data message")?;
    for route in ["apply","incremental","merge","sync"] {
        let mut foreign=Automerge::new().with_actor(actor(ACTOR_B)?);
        let mut offered=log.clone(); let before=snapshot(&foreign)?;
        let result=match route {
            "apply"=>foreign.apply_changes_log_patches(changes.clone(),&mut offered),
            "incremental"=>foreign.load_incremental_log_patches(&source.save(),&mut offered).map(|_|()),
            "merge"=>foreign.merge_and_log_patches(&mut source.clone(),&mut offered).map(|_|()),
            "sync"=>foreign.receive_sync_message_log_patches(&mut State::new(),message.clone(),&mut offered),
            _=>unreachable!(),
        };
        record(out,&format!("external-log-wrong-owner-{route}"),"patches/patch_log.rs:begin_transaction,automerge.rs:1106",
            json!({"error":result.err().as_ref().map(error_observation),"before":before,
                "after":snapshot(&foreign)?,"retained_log":patches(&owner,&mut offered)}))?;
    }
    // A retained A-only log cannot migrate to a nonempty B-only actor table:
    // B sorts after A, so migrate_actors rejects the missing A entry.
    let mut base_b=Automerge::new().with_actor(actor(ACTOR_B)?);
    { let mut tx=base_b.transaction(); tx.put(ROOT,"base",true)?; tx.commit_with(options()); }
    let base_heads=base_b.get_heads();
    let mut source_b=base_b.clone();
    {
        let mut tx=source_b.transaction();
        let m=tx.put_object(ROOT,"map",ObjType::Map)?; tx.put(&m,"k",7i64)?;
        let l=tx.put_object(ROOT,"list",ObjType::List)?; tx.insert(&l,0,true)?; tx.insert(&l,1,"two")?;
        let t=tx.put_object(ROOT,"text",ObjType::Text)?; tx.splice_text(&t,0,0,"a😀b")?;
        tx.commit_with(options());
    }
    let delta_b=source_b.get_changes(&base_heads);
    let base_hex=hex_encode(&base_b.save());
    let source_bytes=source_b.save();
    let source_hex=hex_encode(&source_bytes);
    let changes_hex=delta_b.iter().map(|c|hex_encode(c.raw_bytes())).collect::<Vec<_>>();
    let mut sender_b=source_b.clone(); let mut handshake_b=base_b.clone();
    let mut ss_b=State::new(); let mut rs_b=State::new(); let mut data_message_b=None;
    for _ in 0..6 {
        if let Some(m)=sender_b.generate_sync_message(&mut ss_b) {
            if !m.changes.is_empty() {data_message_b=Some(m);break;}
            handshake_b.receive_sync_message(&mut rs_b,m)?;
        }
        if let Some(m)=handshake_b.generate_sync_message(&mut rs_b) {
            sender_b.receive_sync_message(&mut ss_b,m)?;
        }
    }
    let message_b=data_message_b.ok_or("B sync did not generate data message")?;
    for route in ["apply","incremental","merge","sync"] {
        let mut foreign=base_b.clone(); let mut offered=log.clone();
        let before=snapshot(&foreign)?;
        let result=match route {
            "apply"=>foreign.apply_changes_log_patches(delta_b.clone(),&mut offered),
            "incremental"=>foreign.load_incremental_log_patches(&source_bytes,&mut offered).map(|_|()),
            "merge"=>foreign.merge_and_log_patches(&mut source_b.clone(),&mut offered).map(|_|()),
            "sync"=>foreign.receive_sync_message_log_patches(&mut State::new(),message_b.clone(),&mut offered),
            _=>unreachable!(),
        };
        let message_input=if route=="sync" {
            json!({"json":serde_json::to_value(&message_b)?,"hex":hex_encode(&message_b.clone().encode())})
        } else {Json::Null};
        record(out,&format!("external-log-incompatible-{route}"),
            "patches/patch_log.rs:634-658,automerge.rs:1033-1138,sync.rs:386-422",
            json!({"error":result.err().as_ref().map(error_observation),"before":before,
                "after":snapshot(&foreign)?,"retained_log":patches(&owner,&mut offered),
                "input":{"base_hex":base_hex,"source_hex":source_hex,
                    "changes_hex":changes_hex,"message":message_input}}))?;
    }
    record(out,"external-log-owner-retained","patches/patch_log.rs:begin_transaction",
        json!({"value":tree(&owner)?,"patches":patches(&owner,&mut log)}))?;
    // Prefix insertion preserves the old B actor tail and its retained ROOT event.
    let mut owner_b=Automerge::new().with_actor(actor(ACTOR_B)?);
    let mut tx=owner_b.transaction_log_patches(PatchLog::active())?;
    tx.put(ROOT,"owned",true)?; let (_,mut tail_log)=tx.commit_with(options());
    let mut target_a=raw()?;
    { let mut tx=target_a.transaction(); tx.put(ROOT,"base",true)?; tx.commit_with(options()); }
    let base_a_heads=target_a.get_heads();
    let base_a_hex=hex_encode(&target_a.save());
    let mut source_a=target_a.clone();
    { let mut tx=source_a.transaction(); tx.put(ROOT,"added",7i64)?; tx.commit_with(options()); }
    let delta_a=source_a.get_changes(&base_a_heads);
    let delta_a_hex=delta_a.iter().map(|c|hex_encode(c.raw_bytes())).collect::<Vec<_>>();
    let before=snapshot(&target_a)?;
    let result=target_a.apply_changes_log_patches(delta_a,&mut tail_log);
    // Retained event IDs export through the target document, not the log's
    // retained actor table. Observe a reference panic if that index is absent.
    let retained_log=match std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        ||patches(&target_a,&mut tail_log))) {
        Ok(value)=>value,
        Err(value)=>{
            let message=value.downcast_ref::<String>().map(String::as_str)
                .or_else(||value.downcast_ref::<&str>().copied());
            match message {
                Some("index out of bounds: the len is 1 but the index is 1")=>
                    json!({"outcome":"panic","class":"IndexOutOfBounds","index":1,"len":1}),
                _=>std::panic::resume_unwind(value),
            }
        },
    };
    record(out,"external-log-retained-tail-apply","patches/patch_log.rs:634-658,automerge.rs:1106-1138",
        json!({"error":result.err().as_ref().map(error_observation),"before":before,
            "after":snapshot(&target_a)?,"retained_log":retained_log,
            "input":{"base_hex":base_a_hex,"source_hex":hex_encode(&source_a.save()),
                "changes_hex":delta_a_hex,"message":Json::Null}}))?;
    Ok(())
}

fn transactions(out: &mut dyn Write) -> Result {
    let mut d = raw()?;
    let (list,text,h1) = {
        let mut tx = d.transaction(); tx.put(ROOT,"k",1i64)?;
        let l = tx.put_object(ROOT,"list",ObjType::List)?; tx.insert(&l,0,1i64)?;
        let t = tx.put_object(ROOT,"text",ObjType::Text)?; tx.splice_text(&t,0,0,"old")?;
        let (h,_) = tx.commit_with(options()); (l,t,h.ok_or("tx base hash")?)
    };
    { let mut tx = d.transaction(); tx.put(ROOT,"k",2i64)?; tx.splice_text(&text,0,3,"new")?; tx.commit_with(options()); }
    let heads = d.get_heads();
    let mut tx = d.transaction_at(PatchLog::active(),&[h1])?;
    tx.put(ROOT,"p",3i64)?; tx.insert(&list,1,4i64)?;
    let pending = tx.pending_ops();
    let held_keys=tx.keys_at(ROOT,&[h1]);
    let empty_read=tx.get_at(ROOT,"k",&[])?;
    let held_keys=held_keys.collect::<Vec<_>>();
    let cursor=tx.get_cursor(&text,1,None)?;
    let read = json!({"serde":tree(&tx)?,"get":read_option(tx.get(ROOT,"k")?),
        "get_at":read_option(tx.get_at(ROOT,"p",&heads)?),
        "keys":tx.keys(ROOT).collect::<Vec<_>>(),"map_range":tx.map_range(ROOT,..).map(map_item).collect::<Vec<_>>(),
        "list_range":tx.list_range(&list,..).map(list_item).collect::<Vec<_>>(),
        "length":tx.length(&list),"text":tx.text(&text)?,"text_at":tx.text_at(&text,&heads)?,
        "marks":tx.marks(&text)?.iter().map(mark).collect::<Vec<_>>(),
        "spans":tx.spans(&text)?.map(span).collect::<Result<Vec<_>>>()?,
        "parents":tx.parents(&text)?.map(parent).collect::<Vec<_>>(),
        "keys_at_held":held_keys,"empty_heads_read":read_option(empty_read),
        "get_all":tx.get_all(ROOT,"k")?.iter().map(read_value).collect::<Vec<_>>(),
        "get_all_at":tx.get_all_at(ROOT,"p",&[h1])?.iter().map(read_value).collect::<Vec<_>>(),
        "map_range_at":tx.map_range_at(ROOT,..,&[h1]).map(map_item).collect::<Vec<_>>(),
        "list_range_at":tx.list_range_at(&list,..,&[h1]).map(list_item).collect::<Vec<_>>(),
        "values":tx.values(ROOT).map(|value|read_value(&value)).collect::<Vec<_>>(),
        "values_at":tx.values_at(ROOT,&[h1]).map(|value|read_value(&value)).collect::<Vec<_>>(),
        "length_at":tx.length_at(&list,&[h1]),"object_type":object_type(tx.object_type(&list)?),
        "marks_at":tx.marks_at(&text,&[h1])?.iter().map(mark).collect::<Vec<_>>(),
        "spans_at":tx.spans_at(&text,&[h1])?.map(span).collect::<Result<Vec<_>>>()?,
        "parents_at":tx.parents_at(&text,&[h1])?.map(parent).collect::<Vec<_>>(),
        "cursor":cursor.to_string(),"cursor_position":tx.get_cursor_position(&text,&cursor,None)?,
        "cursor_moving":tx.get_cursor_moving(&text,1,Some(&[h1]),automerge::MoveCursor::Before)?.to_string(),
        "cursor_position_at":tx.get_cursor_position(&text,&cursor,Some(&[h1]))?,
        "iter":tx.iter().map(doc_item).collect::<Result<Vec<_>>>()?,
        "iter_at":tx.iter_at(ROOT,Some(&[h1])).map(doc_item).collect::<Result<Vec<_>>>()?,
        "change_hash_lookup":tx.get_change_by_hash(&h1).map(|c|json!({"hash":c.hash(),"hex":hex_encode(c.raw_bytes())})),
        "stats":{"num_ops":tx.stats().num_ops,"num_changes":tx.stats().num_changes,"num_actors":tx.stats().num_actors},
        "stats_debug":format!("{:?}",tx.stats()),
        "missing_deps":tx.get_missing_deps(&heads),"text_encoding":encoding(tx.text_encoding()),
        "hydrate_null":hydrated_json(&tx.hydrate(ROOT,None)?)?,
        "hydrate_at":hydrated_json(&tx.hydrate(ROOT,Some(&[h1]))?)?});
    let (hash,mut log) = tx.commit_with(options());
    record(out,"transaction-scoped-read-doc","transaction.rs:impl_read_doc_for_tx,automerge.rs:501",json!({
        "base":h1,"full_heads":heads,"pending":pending,"reads":read,"hash":hash,
        "committed":snapshot(&d)?,"patches":patches(&d,&mut log)}))?;
    let mut owned = d.clone().into_transaction(Some(PatchLog::active()),None)?;
    owned.put(ROOT,"owned",true)?; let owned_read = tree(&owned)?;
    let (committed,hash,mut log) = owned.commit_with(options());
    let mut rollback = committed.clone().into_transaction(None,None)?;
    rollback.put(ROOT,"discard",true)?; let (rolled,count) = rollback.rollback();
    record(out,"owned-transaction-terminal","transaction/owned_transaction.rs:70-95",json!({
        "pending_read":owned_read,"hash":hash,"state":snapshot(&committed)?,
        "patches":patches(&committed,&mut log),"cancelled":count,"rollback":snapshot(&rolled)?}))?;
    let before = snapshot(&d)?;
    let failure = d.transact::<_,(),_>(|tx| { tx.put(ROOT,"reject",true).map_err(|_|"unexpected-operation-error")?; Err("consumer-error") });
    let f = failure.err().ok_or("closure did not fail")?;
    let after_failure=snapshot(&d)?;
    let success = d.transact_with(|result:&usize|options().with_message(format!("result:{result}")),|tx| {
        tx.put(ROOT,"accepted",true)?; Ok::<usize,automerge::AutomergeError>(17)
    }).map_err(|f|f.error)?;
    record(out,"closure-user-error","automerge.rs:586-666,transaction/result.rs",json!({
        "error":f.error,"cancelled":f.cancelled,"before":before,"after_failure":after_failure,"state":snapshot(&d)?,
        "result":success.result,"hash":success.hash}))?;
    let logged=d.transact_and_log_patches_with(|_:&()|options(),|tx| {
        tx.put(ROOT,"logged",true)?; Ok::<(),automerge::AutomergeError>(())
    }).map_err(|f|f.error)?;
    let mut log=logged.patch_log;
    record(out,"closure-logged-success","automerge.rs:635-666",json!({
        "hash":logged.hash,"patches":patches(&d,&mut log),"state":snapshot(&d)?}))?;
    let mut nested=raw()?;
    let (map,list,text)={
        let mut tx=nested.transaction();
        let map=tx.put_object(ROOT,"nested",ObjType::Map)?;tx.put(&map,"value",1i64)?;
        let list=tx.put_object(ROOT,"sequence",ObjType::List)?;tx.insert(&list,0,2i64)?;
        let text=tx.put_object(ROOT,"text",ObjType::Text)?;tx.splice_text(&text,0,0,"old")?;
        tx.commit_with(options());(map,list,text)
    };
    let historical=nested.get_heads();
    {let mut tx=nested.transaction();tx.put(&map,"value",9i64)?;tx.put(&list,0,8i64)?;
        tx.splice_text(&text,0,3,"new")?;tx.commit_with(options());}
    let full=tree(&nested)?;
    let mut tx=nested.transaction_at(PatchLog::inactive(),&historical)?;
    tx.splice_text(&text,3,0,"!")?;
    let before=tx.pending_ops();let projected=tree(&tx)?;let after=tx.pending_ops();
    tx.rollback();
    record(out,"autoserde-nested-transaction-scope","autoserde.rs:22-127",
        json!({"heads":historical,"full":full,"projected":projected,
            "pending_before":before,"pending_after":after}))?;
    let mut equal=raw()?;
    { let mut tx=equal.transaction(); tx.put(ROOT,"old",1i64)?; tx.commit_with(options()); }
    let committed=equal.get_heads();
    let mut tx=equal.transaction_at(PatchLog::inactive(),&committed)?;
    tx.put(ROOT,"pending",2i64)?;
    let keys=tx.keys_at(ROOT,&committed);
    let historical=tx.get_at(ROOT,"pending",&committed)?;
    let empty_heads=tx.get_at(ROOT,"old",&[])?;
    let keys=keys.collect::<Vec<_>>();
    let data=json!({"heads":committed,"current":tree(&tx)?,"pending":tx.pending_ops(),
        "historical_pending":read_option(historical),"empty_heads":read_option(empty_heads),
        "retained_historical_keys":keys,"hydrate_null":hydrated_json(&tx.hydrate(ROOT,None)?)?,
        "hydrate_historical":hydrated_json(&tx.hydrate(ROOT,Some(&committed))?)?});
    tx.rollback();
    record(out,"transaction-explicit-equal-heads","transaction.rs:impl_read_doc_for_tx",data)?;
    let mut tx=equal.transaction();
    tx.put(ROOT,"pending",2i64)?;
    let data=json!({"heads":committed,"current":tree(&tx)?,
        "get_at_pending":read_option(tx.get_at(ROOT,"pending",&committed)?),
        "hydrate_null":hydrated_json(&tx.hydrate(ROOT,None)?)?,
        "pending_hydrate_same_heads":hydrated_json(&tx.hydrate(ROOT,Some(&committed))?)?});
    tx.rollback();
    record(out,"transaction-unscoped-equal-heads-hydrate","transaction.rs:221-229,automerge.rs:1241-1246,1644",data)?;
    Ok(())
}

fn scalar_cases() -> Vec<ScalarValue> {
    vec![ScalarValue::Null,ScalarValue::Boolean(true),ScalarValue::Int(-7),
        ScalarValue::Uint(i64::MAX as u64),ScalarValue::Uint(1u64<<63),ScalarValue::Uint(u64::MAX),
        ScalarValue::F64(1.25),ScalarValue::Str("é".into()),ScalarValue::Bytes(vec![0,255,128]),
        ScalarValue::Counter(5i64.into()),ScalarValue::Timestamp(-123),
        ScalarValue::Unknown{type_code:15,bytes:vec![0,255]}]
}
fn expanded(out: &mut dyn Write) -> Result {
    use automerge::legacy::{Op,OpType,ObjectId,Key,ElementId,OpId,SortedVec,MarkData};
    // Structured binary codec roundtrips need not apply fabricated causality to a document.
    // Each action below is passed through Change::from and Change::try_from, not echoed.
    let a = actor(ACTOR_A)?; let b = actor(ACTOR_B)?;
    let mut actions = vec![OpType::Make(ObjType::Map),OpType::Make(ObjType::List),
        OpType::Make(ObjType::Text),OpType::Make(ObjType::Table),OpType::Delete,OpType::Increment(-3)];
    actions.extend(scalar_cases().into_iter().map(OpType::Put));
    for expand in [false,true] {
        actions.push(OpType::MarkBegin(MarkData{name:"bold".into(),value:ScalarValue::Boolean(true),expand}));
        actions.push(OpType::MarkEnd(expand));
    }
    let operations = actions.into_iter().enumerate().map(|(i,action)| Op{action,
        obj:if i%2==0 {ObjectId::Root} else {ObjectId::Id(OpId(1,a.clone()))},
        key:match i%3 {0=>Key::Map(format!("k{i}").into()),1=>Key::Seq(ElementId::Head),_=>Key::Seq(ElementId::Id(OpId(2,b.clone())))},
        pred:SortedVec::from(vec![OpId(2,b.clone()),OpId(1,a.clone())]),insert:i%2!=0}).collect();
    let e = automerge::ExpandedChange{operations,actor_id:a.clone(),author:None,hash:None,seq:1,
        start_op:std::num::NonZeroU64::new(17).unwrap(),time:0,message:Some("all-variants".into()),
        deps:fixture()?.get_heads(),extra_bytes:vec![0,255,128]};
    let input_json = serde_json::to_value(&e)?;
    let mut c: Change = e.into(); let raw_bytes = c.raw_bytes().to_vec(); let wire = c.bytes().into_owned();
    let reparsed = Change::try_from(raw_bytes.as_slice())?;
    let decoded = reparsed.decode(); let rebuilt:Change = decoded.clone().into();
    let json_roundtrip = match serde_json::from_value::<automerge::ExpandedChange>(serde_json::to_value(&decoded)?) {
        Ok(e) => { let c:Change=e.into(); json!({"outcome":"ok","hash":c.hash()}) },
        Err(_)=>json!({"outcome":"error","class":"InvalidScalarValue"}),
    };
    record(out,"expanded-all-variants","legacy/mod.rs:213-367,serde_impls/op_type.rs,change.rs:135-216",json!({
        "input":input_json,"decoded":decoded,"raw_hex":hex_encode(&raw_bytes),"wire_hex":hex_encode(&wire),
        "hash":reparsed.hash(),"rebuilt_hash":rebuilt.hash(),"json_roundtrip":json_roundtrip,
        "len":reparsed.len(),"start_op":reparsed.start_op().get(),"max_op":reparsed.max_op(),
        "actors":reparsed.actors().collect::<Vec<_>>(),"other_actors":reparsed.other_actor_ids(),"author":reparsed.author()}))?;
    for (i,op) in decoded.operations.iter().enumerate() {
        let mut single=decoded.clone(); single.operations=vec![op.clone()]; single.hash=None;
        let c:Change=single.into(); let j=serde_json::to_value(c.decode())?;
        let deserialized=match serde_json::from_value::<automerge::ExpandedChange>(j.clone()) {
            Ok(e)=>{ let rebuilt:Change=e.into(); json!({"outcome":"ok","hash":rebuilt.hash()}) },
            Err(_)=>json!({"outcome":"error","class":"InvalidScalarValue"}),
        };
        record(out,&format!("expanded-variant-{i}"),"serde_impls/op_type.rs,serde_impls/scalar_value.rs",
            json!({"json":j,"hash":c.hash(),"hex":hex_encode(c.raw_bytes()),"json_roundtrip":deserialized}))?;
    }
    let mut authored = auto()?.with_author(Some(Author::from(vec![255,0,128]))).with_actor(a);
    authored.put(ROOT,"authored",true)?; let h = authored.commit_with(options()).ok_or("authored hash")?;
    let mut e = authored.get_change_by_hash(&h).ok_or("authored missing")?.decode();
    e.extra_bytes.extend_from_slice(&[0,255,128,66]); let c:Change = e.into();
    record(out,"expanded-author-opaque-footer","change.rs:48-49,decode_author_footer:395-402",json!({
        "json":c.decode(),"hash":c.hash(),"author":c.author(),"extra_hex":hex_encode(c.extra_bytes()),"raw_hex":hex_encode(c.raw_bytes())}))?;
    let mut empty = c.decode(); empty.operations.clear(); empty.seq = 2; empty.start_op = std::num::NonZeroU64::new(17).unwrap();
    empty.extra_bytes.clear(); empty.author=None; empty.hash=None;
    let c:Change = empty.into();
    record(out,"expanded-empty","change.rs:66-75",json!({"json":c.decode(),"hash":c.hash(),"len":c.len(),"max_op":c.max_op(),"author":c.author(),"hex":hex_encode(c.raw_bytes())}))?;
    for footer in [vec![],vec![2,0],vec![1],vec![1,3,255],vec![0x80]] {
        let mut e=c.decode(); e.extra_bytes=footer; e.author=None; e.hash=None;
        let c:Change=e.into(); let parsed=Change::try_from(c.raw_bytes())?;
        record(out,"change-author-footer-total","change.rs:395-402",json!({
            "extra_hex":hex_encode(parsed.extra_bytes()),"author":parsed.author(),
            "hash":parsed.hash(),"hex":hex_encode(parsed.raw_bytes())}))?;
    }
    Ok(())
}

fn identities(out: &mut dyn Write) -> Result {
    for (i,s) in scalar_cases().into_iter().enumerate() {
        let hydrated = automerge::hydrate::Value::Scalar(s.clone());
        record(out,&format!("scalar-{i}"),"value.rs:517-540,629-887,hydrate.rs:129",json!({
            "datatype":scalar_type(&s),"scalar_debug":format!("{s:?}"),"json":serde_json::to_value(&s)?,"display":s.to_string(),
            "i64":s.as_i64(),"u64":s.as_u64(),"f64":s.as_f64(),"hydrate_i64":hydrated.as_i64()}))?;
    }
    let a = ActorId::from(vec![0,255,128]);
    let hash = ChangeHash(std::array::from_fn(|i|i as u8));
    for (i,id) in [ROOT,ObjId::Id(1,a.clone(),7),ObjId::Id(u64::MAX,a.clone(),7),ObjId::Id(0,a.clone(),0)].into_iter().enumerate() {
        let bytes = id.to_bytes(); let parsed = ObjId::try_from(bytes.as_slice())?;
        let mut trailing=bytes.clone(); trailing.push(255);
        record(out,&format!("exid-{i}"),"exid.rs:17-67,97-175",json!({"display":id.to_string(),"json":id,
            "hex":hex_encode(&bytes),"bytes":bytes,"parsed":parsed,"equal":id==parsed,
            "trailing":exid_result(ObjId::try_from(trailing.as_slice()))}))?;
    }
    for bytes in [vec![],vec![1],vec![0x20],vec![0x10,0x80],vec![0x10,3,0],vec![0x10,0,0x80],vec![0x10,0,0,0x80]] {
        record(out,"exid-invalid","exid.rs:97-122",json!({"hex":hex_encode(&bytes),"result":exid_result(ObjId::try_from(bytes.as_slice()))}))?;
    }
    for bytes in [vec![],vec![0,255,128]] {
        let author = Author::from(bytes); let hex=author.to_hex_string();
        record(out,"author-codec","author.rs:135-220",json!({"bytes":author.as_bytes(),"hex":hex,"json":author,
            "roundtrip":Author::try_from(hex.as_str())?==author}))?;
    }
    let wide=ObjId::Id(1u64<<32,a.clone(),7);let wide_bytes=wide.to_bytes();
    let wide_parsed=ObjId::try_from(wide_bytes.as_slice())?;
    let mut overflow=ObjId::Id(u64::MAX,a.clone(),7).to_bytes();
    *overflow.last_mut().ok_or("empty maximum ExId bytes")?=2;
    record(out,"actor-hash-codec","types.rs:ActorId,ChangeHash",json!({"actor":a,"actor_hex":a.to_hex_string(),
        "actor_bytes":a.to_bytes(),"hash":hash,"hash_display":hash.to_string(),
        "hash_parse":hash.to_string().parse::<ChangeHash>()?,
        "wide32":{"id":wide,"display":wide.to_string(),"bytes":wide_bytes,
            "hex":hex_encode(&wide_bytes),"parsed":wide_parsed,"equal":wide==wide_parsed},
        "counter_overflow":{"bytes":overflow,"result":exid_result(ObjId::try_from(overflow.as_slice()))}}))?;
    for text in ["","0","gg","00FF80"] {
        let author=match Author::try_from(text) {
            Ok(value)=>json!({"outcome":"ok","value":value}),
            Err(_)=>json!({"outcome":"error","class":"InvalidAuthor"}),
        };
        let actor=match text.parse::<ActorId>() {
            Ok(value)=>json!({"outcome":"ok","value":value}),
            Err(_)=>json!({"outcome":"error","class":"InvalidActorId"}),
        };
        let hash=match text.parse::<ChangeHash>() {
            Ok(value)=>json!({"outcome":"ok","value":value}),
            Err(e)=>{
                let class=match e {automerge::ParseChangeHashError::HexDecode(_)=>"HexDecode",
                    automerge::ParseChangeHashError::IncorrectLength{..}=>"IncorrectLength"};
                json!({"outcome":"error","class":class})
            },
        };
        record(out,"hex-codec-input","author.rs:194-219,types.rs:ActorId,ChangeHash",
            json!({"input":text,"author":author,"actor":actor,"hash":hash}))?;
    }
    for kind in [ObjType::Map,ObjType::List,ObjType::Text,ObjType::Table] {
        let v = Value::Object(kind);
        record(out,"value-object","value.rs:Value",json!({"kind":object_type(kind),"value_debug":format!("{v:?}"),
            "object":v.is_object(),"scalar":v.is_scalar(),"to_objtype":v.to_objtype().map(object_type)}))?;
    }
    let d=fixture()?;
    let map=d.get(ROOT,"map")?.ok_or("map missing")?.1;
    let id=map.to_string();
    let imported=d.import(&id)?;let root=d.import("_root")?;
    record(out,"object-import","automerge.rs:1320-1361",json!({"id":id,
        "import":{"id":imported.0,"object_type":object_type(imported.1)},"import_obj":d.import_obj(&id)?,
        "root":{"id":root.0,"object_type":object_type(root.1)}}))?;
    for text in ["missing","-1@a1","1@","1@ff","1@xyz"] {
        let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||d.import(text)));
        let result=match result {
            Ok(Ok((id,kind)))=>json!({"outcome":"ok","value":{"id":id,"object_type":object_type(kind)}}),
            Ok(Err(e))=>error_observation(&e),
            Err(p)=>panic_observation(p),
        };
        record(out,"object-import-invalid","automerge.rs:1344-1361",json!({"input":text,"observation":result}))?;
    }
    let h=d.hydrate(None);
    let m=match h {automerge::hydrate::Value::Map(m)=>m,_=>return Err("root map".into())};
    let mut initialized=raw()?;
    initialized.init_from_hydrate(&m)?;
    record(out,"init-from-hydrate","automerge.rs:300-303",json!({
        "state":snapshot(&initialized)?,"change_count":initialized.get_changes(&[]).len()}))?;
    Ok(())
}

fn rich(out: &mut dyn Write) -> Result {
    // Build fresh nested hydrated payload via the reference's public document hydration.
    let enc = TextEncoding::UnicodeCodePoint;
    let mut payload = auto()?;
    let ty = payload.put_object(ROOT,"type",ObjType::Text)?; payload.splice_text(&ty,0,0,"paragraph")?;
    let parents = payload.put_object(ROOT,"parents",ObjType::List)?;
    let div = payload.insert_object(&parents,0,ObjType::Text)?; payload.splice_text(&div,0,0,"div")?;
    let attrs = payload.put_object(ROOT,"attrs",ObjType::Map)?; payload.put(&attrs,"bytes",ScalarValue::Bytes(vec![0,255]))?;
    payload.commit_with(options());
    let root = payload.hydrate(ROOT,None)?;
    let block = match root {automerge::hydrate::Value::Map(m)=>m,_=>return Err("block map".into())};
    let mut target = auto()?; let t = target.put_object(ROOT,"text",ObjType::Text)?;
    target.update_spans(&t,automerge::marks::UpdateSpansConfig::default(),[
        automerge::iter::Span::Block(block.clone()),automerge::iter::Span::Text{text:"hello".into(),marks:None}])?;
    target.commit_with(options());
    let spans = target.spans(&t)?.map(span).collect::<Result<Vec<_>>>()?;
    record(out,"fresh-nested-block-spans","transaction/transactable.rs:139-152,iter/spans.rs:Span",json!({
        "payload":hydrated_json(&automerge::hydrate::Value::Map(block))?,"value":tree(&target)?,"spans":spans,
        "save_hex":hex_encode(&target.save())}))?;
    payload.put(&attrs,"changed",true)?; payload.commit_with(options());
    let block=match payload.hydrate(ROOT,None)? {automerge::hydrate::Value::Map(m)=>m,_=>return Err("block map".into())};
    target.update_spans(&t,automerge::marks::UpdateSpansConfig::default(),[
        automerge::iter::Span::Block(block),automerge::iter::Span::Text{text:"changed".into(),marks:None}])?;
    target.commit_with(options());
    let changed_spans = target.spans(&t)?.map(span).collect::<Result<Vec<_>>>()?;
    record(out,"nested-block-reconcile","transaction/inner.rs:update_spans",
        json!({"spans":changed_spans,"save_hex":hex_encode(&target.save()),"heads":target.get_heads()}))?;
    let list = target.put_object(ROOT,"list",ObjType::List)?;
    let mut list_value_doc = auto()?; let lv = list_value_doc.put_object(ROOT,"l",ObjType::List)?;
    list_value_doc.insert(&lv,0,7i64)?; list_value_doc.insert(&lv,1,true)?;
    let new_list = list_value_doc.hydrate(&lv,None)?;
    target.update_object(&list,&new_list)?;
    target.update_object(&t,&automerge::hydrate::Value::text(enc,"replacement"))?;
    let wrong = target.update_object(&list,&automerge::hydrate::Value::map()).err().map(|e|match e {
        automerge::error::UpdateObjectError::ChangeType=>json!("ChangeType"),
        automerge::error::UpdateObjectError::Automerge(e)=>error_observation(&e),
    });
    target.commit_with(options());
    record(out,"update-object-list-text","transaction/inner.rs:update_object",json!({"value":tree(&target)?,"wrong_type":wrong,
        "save_hex":hex_encode(&target.save())}))?;
    target.update_object(&list,&automerge::hydrate::Value::list())?;
    target.commit_with(options());
    record(out,"update-object-list-empty","transaction/inner.rs:update_object",json!({
        "value":tree(&target)?,"length":target.length(&list),"heads":target.get_heads()}))?;
    let mut hydrated = target.hydrate(ROOT,None)?;
    let different_id = ObjId::Id(999,actor(ACTOR_B)?,0);
    hydrated.apply_patches(enc,[Patch{obj:different_id.clone(),path:vec![],action:PatchAction::PutMap{
        key:"portable".into(),value:(Value::Scalar(std::borrow::Cow::Owned(ScalarValue::Boolean(true))),different_id),conflict:false}}])?;
    record(out,"hydrate-patch-portable-path","hydrate.rs:78-111",json!({"value":hydrated_json(&hydrated)?}))?;
    let mut h=new_list.clone();
    let result=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||h.apply_patches(enc,[
        Patch{obj:ROOT,path:vec![],action:PatchAction::DeleteSeq{index:1,length:3}}
    ])));
    let result=match result {
        Ok(Ok(()))=>json!({"outcome":"ok"}),Ok(Err(e))=>hydrate_error(&e),
        Err(p)=>panic_observation(p),
    };
    record(out,"hydrate-oversized-delete","hydrate/list.rs:63-67,sequence_tree.rs:111-112",
        json!({"result":result,"remaining":hydrated_json(&h)?}))?;
    Ok(())
}

fn marks(out: &mut dyn Write) -> Result {
    // MarkSet has no public insertion API. Obtain real visible/tombstone sets via
    // span queries and a real unmark; do not fabricate private mark state.
    let mut d=auto()?; let t=d.put_object(ROOT,"text",ObjType::Text)?; d.splice_text(&t,0,0,"abc")?;
    d.mark(&t,automerge::marks::Mark::new("bold".into(),true,0,3),automerge::marks::ExpandMark::Both)?;
    d.commit_with(options());
    let visible=d.spans(&t)?.filter_map(|s|match s {automerge::iter::Span::Text{marks,..}=>marks,_=>None}).next().ok_or("mark set missing")?;
    d.unmark(&t,"deleted",0,3,automerge::marks::ExpandMark::Both)?; d.commit_with(options());
    let after=d.spans(&t)?.filter_map(|s|match s {automerge::iter::Span::Text{marks,..}=>marks,_=>None}).next().ok_or("mark set missing")?;
    record(out,"non-deleted-marks","marks.rs:208-209,434-463",json!({
        "visible_len":visible.non_deleted_marks().len(),"visible_empty":visible.non_deleted_marks().is_empty(),
        "after_len":after.non_deleted_marks().len(),"equal":visible.non_deleted_marks()==after.non_deleted_marks(),
        "visible":visible.iter().map(|(k,v)|json!([k,v])).collect::<Vec<_>>(),
        "after":after.iter().map(|(k,v)|json!([k,v])).collect::<Vec<_>>(),"hashes":d.get_heads()}))?;
    d.unmark(&t,"bold",0,3,automerge::marks::ExpandMark::Both)?; d.commit_with(options());
    let no_marks=automerge::marks::MarkSet::default();
    record(out,"non-deleted-marks-empty","marks.rs:434-463",json!({
        "empty_len":no_marks.non_deleted_marks().len(),"empty":no_marks.non_deleted_marks().is_empty(),
        "equal_bold_empty":visible.non_deleted_marks()==no_marks.non_deleted_marks(),
        "marks_after_unmark":d.marks(&t)?.iter().map(mark).collect::<Vec<_>>(),"heads":d.get_heads()}))?;
    Ok(())
}
fn sync_serde(out: &mut dyn Write) -> Result {
    let d=fixture()?; let mut sender=d.clone(); let mut receiver=Automerge::new().with_actor(actor(ACTOR_B)?);
    let mut ss=State::new(); let mut rs=State::new();
    for round in 0..4 {
        if let Some(m)=sender.generate_sync_message(&mut ss) {
            record(out,"sync-message-serde","sync.rs:603-614",json!({"round":round,"json":serde_json::to_value(&m)?,
                "hex":hex_encode(&m.clone().encode()),"heads":m.heads,"need":m.need,
                "changes_hex":m.changes.iter().map(hex_encode).collect::<Vec<_>>() }))?;
            receiver.receive_sync_message(&mut rs,m)?;
        }
        if let Some(m)=receiver.generate_sync_message(&mut rs) {sender.receive_sync_message(&mut ss,m)?;}
    }
    record(out,"sync-serde-final","autoserde.rs:22-127,sync.rs:603-614",json!({"sender":snapshot(&sender)?,"receiver":snapshot(&receiver)?}))?;
    Ok(())
}
