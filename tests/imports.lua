local imports=require('imports')
local json,uv=require('json'),require('uv')
local passed=0
local function check(v,label) assert(v,label);passed=passed+1 end
local dbpath=os.tmpname();local db=assert(require('db').open(dbpath));imports.configure{db=db}
local root=uv.cwd()..'/tests/fixtures/process_logs'
local function options(format,scope,path)
  return {format=format,scope=scope or format,source={root=root,path=path or root..'/'..format..'.jsonl'},redaction={literals={'fixture-secret'}}}
end
local c=assert(imports.ingest(options('claude')))
check(c.added==6 and c.quarantined==3,'Claude messages/blocks and quarantine')
check(assert(imports.ingest(options('claude'))).added==0,'repeat adds no logical events')
local rows=imports.read('claude');local calls={}
for _,e in ipairs(rows) do
  check(e.origin=='imported' and e.verified==false and e.coverage=='observations_only','imported envelope')
  if e.kind=='tool.request' then calls[e.call_id]=e end
end
check(calls.call1.output.provenance=='observed','Claude request/result correlated')
check(calls.call2.output.provenance=='missing','absent result explicit')
check(#imports.quarantine('claude')==3,'durable quarantines')
local o=assert(imports.ingest(options('openai')))
check(o.duplicates==2 and o.quarantined==4,'Codex mirror dedup and unsupported coverage')
local operations=0;local summary=0
for _,e in ipairs(imports.read('openai')) do
  if e.kind=='tool.request' then
    operations=operations+1
    check(e.output.provenance==(e.call_id=='f2' and 'missing' or 'observed'),'Codex tool output presence')
    if e.call_id=='f1' then check(e.encoding=='json_string' and not e.value:find('argument-secret',1,true),'encoded argument secrets redacted') end
  elseif e.kind=='context.summary' then summary=summary+1
  elseif e.kind=='message' then check(#e.source_refs==2,'mirror refs preserved') end
end
check(operations==3 and summary==4,'completion summaries do not count operations')
local b=assert(imports.ingest(options('boggart')))
check(b.added==3 and b.duplicates==2,'Boggart legacy/native/checkpoint dedup')
rows=imports.read('boggart')
check(#rows[1].source_refs==3,'Boggart duplicate references retained')
check(rows[2].value_provenance=='missing' and rows[3].value_provenance=='partial','Boggart artifact/partial snapshots explicit')
for _,t in ipairs({'import_events','import_sources','import_refs','import_quarantine','import_checkpoints'}) do
  for _,r in ipairs(db:query('SELECT body FROM '..t)) do
    check(not r.body:find('fixture-secret',1,true) and not r.body:find('argument-secret',1,true),'no durable secrets')
    check(not r.body:find('PRIVATE-REASONING-SENTINEL',1,true) and not r.body:find('DO-NOT-',1,true),'no hidden reasoning or imported authorization')
  end
end
-- Restart on an appended file, including a partial final line and interior corruption.
local temp_seed=os.tmpname();os.remove(temp_seed)
local tmp=assert(uv.fs_mkdtemp(temp_seed..'-import-fixture-XXXXXX'))
local path=tmp..'/stream.jsonl'
local function write(p,s,mode) local f=assert(io.open(p,mode or 'wb'));assert(f:write(s));f:close() end
local function message(id,text) return json.encode({type='user',sessionId='incremental',uuid=id,message={role='user',content=text}}) end
local first=message('one','first')..'\n';local second=message('two','second')
write(path,first..'bad-json\n'..second:sub(1,20))
local opt=options('claude','incremental',path);opt.source.root=tmp;opt.max_records=1
local batch=assert(imports.ingest(opt));check(batch.added==1 and batch.checkpoint.offset==#first,'bounded checkpoint')
package.loaded.imports=nil;package.loaded['imports.init']=nil
imports=require('imports');db:close();db=assert(require('db').open(dbpath));imports.configure{db=db}
batch=assert(imports.ingest(opt));check(batch.quarantined==1,'restart skips committed event and quarantines malformed line')
batch=assert(imports.ingest(opt));check(batch.added==0 and batch.checkpoint.partial,'partial final record held')
write(path,second:sub(21)..'\n','ab')
batch=assert(imports.ingest(opt));check(batch.added==1,'completed append imported')
local copy=tmp..'/overlap.jsonl';write(copy,first..second..'\n')
local overlap=options('claude','incremental',copy);overlap.source.root=tmp
batch=assert(imports.ingest(overlap));check(batch.added==0 and batch.duplicates==2,'overlapping export dedups')
for _,e in ipairs(imports.read('incremental')) do check(#e.source_refs==2,'overlap source refs preserved') end
write(path,first)
batch=assert(imports.ingest(opt));check(batch.added==0 and batch.checkpoint.reset,'truncation resets safely')
write(path,message('three','third')..'\n')
batch=assert(imports.ingest(opt));check(batch.added==1 and batch.checkpoint.reset,'replacement detects changed prefix')
-- Same provider IDs in another scope/session cannot collapse ownership.
local separate=options('claude','another',copy);separate.source.root=tmp
check(assert(imports.ingest(separate)).added==2,'scope isolation')
check(imports.tombstone('another'),'tombstone stored')
check(not imports.ingest(separate),'tombstone prevents routine reimport')
local outside=options('claude');outside.source.root=tmp
check(not imports.ingest(outside),'root confinement')
local absent=options('claude');absent.redaction=nil
check(not imports.ingest(absent),'redaction selection required')
absent=options('claude');absent.scope=nil
check(not imports.ingest(absent),'explicit scope required')
-- A database writer lock cannot advance the checkpoint or expose partial rows.
write(path,message('four','fourth')..'\n','ab')
local blocker=assert(require('db').open(dbpath));assert(blocker:exec('BEGIN IMMEDIATE'))
local before=db:query('SELECT body FROM import_checkpoints WHERE source_id=?',{batch.checkpoint.source_id})[1].body
check(not imports.ingest(opt),'writer lock refuses whole batch')
assert(blocker:exec('ROLLBACK'));blocker:close()
check(db:query('SELECT body FROM import_checkpoints WHERE source_id=?',{batch.checkpoint.source_id})[1].body==before,'failed transaction leaves checkpoint')
check(assert(imports.ingest(opt)).added==1,'failed batch resumes without loss')
-- Oversized records are quarantined individually and do not strand later data.
write(path,string.rep('x',300000)..'\n'..message('five','fifth')..'\n')
opt.max_bytes=1024
check(assert(imports.ingest(opt)).quarantined==1,'oversized record quarantined')
check(assert(imports.ingest(opt)).added==1,'following valid record survives')
-- Redaction changes cannot silently leave older bytes under a stronger policy.
opt.redaction={literals={'different'}}
check(not imports.ingest(opt),'changed redaction policy requires deliberate migration')
-- Inject failure after an event insert: transaction must roll back all work.
local atomic=options('claude','atomic',copy);atomic.source.root=tmp
assert(db:exec([[CREATE TRIGGER import_test_abort BEFORE INSERT ON import_events
WHEN NEW.scope='atomic' AND (SELECT count(*) FROM import_events WHERE scope='atomic')=1
BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;]]))
check(not imports.ingest(atomic),'mid-batch storage failure')
check(#imports.read('atomic')==0 and #db:query("SELECT * FROM import_checkpoints WHERE scope='atomic'")==0,'mid-batch rollback has no records/checkpoint')
assert(db:exec('DROP TRIGGER import_test_abort'))
check(assert(imports.ingest(atomic)).added==2,'rolled back batch fully resumes')
-- Stable IDs isolate sessions; duplicate differing snapshots retain both observations.
local other=tmp..'/other.jsonl'
write(other,message('one','changed observed text')..'\n')
local changed=options('claude','incremental',other);changed.source.root=tmp
check(assert(imports.ingest(changed)).duplicates==1,'same event ID not another operation')
local variant=false
for _,e in ipairs(imports.read('incremental')) do for _,ref in ipairs(e.source_refs) do
  if ref.observed_variant and ref.observed_variant.value=='changed observed text' then variant=true end
end end
check(variant,'conflicting observed snapshot preserved')
write(other,json.encode({type='user',sessionId='different-session',uuid='one',message={role='user',content='first'}})..'\n')
check(assert(imports.ingest(changed)).added==1,'same UUID in another session distinct')
-- Realpath confinement follows symlinks rather than trusting the link location.
local link=tmp..'/escape.jsonl';assert(uv.fs_symlink(root..'/claude.jsonl',link))
local escaped=options('claude','escaped',link);escaped.source.root=tmp
check(not imports.ingest(escaped),'symlink escape refused')
os.remove(link)
-- Boggart repeats are preserved while each representation adds references.
local repeated=tmp..'/repeated.jsonl';local lines={}
for _,kind in ipairs({'entry','session.entry'}) do for i=1,2 do
  lines[#lines+1]=json.encode({kind=kind,run_id='repeat-run',payload={role='user',content='same'}})
end end
lines[#lines+1]=json.encode({session_id='repeat-run',messages={{role='user',content='same'},{role='user',content='same'}}})
lines[#lines+1]=json.encode({kind='entry',run_id='repeat-run',payload={role='assistant',content={{type='thinking',thinking='PRIVATE-REASONING-SENTINEL'}}}})
write(repeated,table.concat(lines,'\n')..'\n')
local ro=options('boggart','repeated',repeated);ro.source.root=tmp
local rr=assert(imports.ingest(ro));check(rr.added==3 and rr.duplicates==4,'repeated identical messages preserve occurrences across lanes')
check(not json.encode(imports.read('repeated')):find('PRIVATE-REASONING-SENTINEL',1,true),'legacy private reasoning omitted')
os.remove(other);os.remove(repeated)
-- Review regressions: encoded spellings must never preserve recoverable credentials.
local review_file=tmp..'/review.jsonl'
local function review_rows(scope,format,records,literals)
  local chunks={};for _,record in ipairs(records) do chunks[#chunks+1]=json.encode(record) end
  write(review_file,table.concat(chunks,'\n')..'\n')
  local options=options(format,scope,review_file);options.source.root=tmp;options.source.session=scope
  options.redaction={literals=literals or {}}
  local result,err=imports.ingest(options);assert(result,err)
  return imports.read(scope),result,options
end
local function response(id,value)
  return {type='response_item',payload={type='message',id=id,role='user',content=value}}
end
local function completed(id,value)
  return {type='event_msg',payload={type='item_completed',item={type='UserMessage',id=id,content=value}}}
end
local escaped=review_rows('review-escaped','openai',{
  {type='response_item',payload={type='function_call',call_id='quote',name='inspect',arguments=[[{"password":"alpha\u0022omega"}]]}},
  {type='response_item',payload={type='function_call',call_id='slash',name='inspect',arguments=[[{"password":"path\\credential"}]]}},
  {type='response_item',payload={type='function_call',call_id='literal',name='inspect',arguments=[[{"public":"lit\u0065ral-credential"}]]}},
},{'literal-credential'})
for _,e in ipairs(escaped) do
  local decoded=json.decode(e.value)
  check(e.representation.kind=='canonical_sanitized_json' and e.representation.original_bytes_preserved==false and e.representation.redacted,'canonical sanitized representation explicitly marked')
  check(e.value_provenance=='redacted','encoded argument value provenance redacted')
  check(e.call_id=='literal' and decoded.public=='[REDACTED]' or e.call_id~='literal' and decoded.password.evidence_marker=='redacted','escaped credentials structurally removed')
end
local batch_rows=review_rows('review-batch','openai',{
  response('echo','batch-labelled-credential'),
  response('echo','variant batch-labelled-credential'),
  {type='response_item',payload={type='function_call',call_id='later',name='inspect',arguments=[[{"password":"batch-labelled-credential"}]]}},
})
check(batch_rows[1].value=='[REDACTED]','earlier event sanitized after full batch credential discovery')
check(batch_rows[1].source_refs[2].observed_variant.value=='variant [REDACTED]','duplicate variant sanitized after full batch discovery')
-- Later metadata credentials also sanitize earlier snapshots; available metadata survives.
local metadata_rows=review_rows('review-metadata','boggart',{
  {kind='entry',run_id='review-metadata',id=1,ts=1700000001,payload={role='user',content='metadata-credential'}},
  {schema_version=1,kind='invocation.start',event_id='meta1',run_id='review-metadata',timestamp=1700000002,
    step_id='step-a',attempt_id='attempt-2',parent_id='parent-a',correlation_id='call-a',origin='native',
    provenance={observation='direct_runtime',password='metadata-credential'},artifact_refs={{id='artifact-a',bytes=99,encoding='json'}},
    payload={evidence_marker='artifact',id='artifact-a'}},
})
check(metadata_rows[1].timestamp==1700000001 and metadata_rows[1].field_provenance.timestamp=='observed','legacy ts retained as original observation')
check(metadata_rows[1].value=='[REDACTED]','late source-metadata secret learned before earlier event serialization')
local meta=metadata_rows[2]
check(meta.timestamp==1700000002 and meta.parent=='parent-a' and meta.call_id=='call-a','native timestamp/correlation retained')
check(meta.source_observation.step_id=='step-a' and meta.source_observation.attempt_id=='attempt-2','native step/attempt preserved')
check(meta.source_observation.provenance.observation=='direct_runtime' and meta.source_observation.provenance.password.evidence_marker=='redacted','source provenance preserved and sanitized')
check(meta.source_observation.artifact_refs[1].id=='artifact-a' and meta.value_provenance=='missing' and meta.origin=='imported' and not meta.verified,'artifact reference observation does not become resolved/native/verified')
local images=review_rows('review-blocks','openai',{
  response('image-only',{{type='input_image',image_url='synthetic-image'}}),
  response('mixed',{{type='input_text',text='visible'},{type='input_image',image_url='synthetic-image'},{type='reasoning',raw_content='PRIVATE-BLOCK-SENTINEL'}}),
  completed('reasoning-only',{{type='reasoning',raw_content='PRIVATE-BLOCK-SENTINEL'}}),
})
check(images[1].value==nil and images[1].provenance=='missing' and images[1].value_provenance=='missing' and images[1].content_omissions.unsupported==1,'image-only message explicitly missing/omitted')
check(images[2].value=='visible' and images[2].value_provenance=='partial' and images[2].content_omissions.unsupported==2,'mixed blocks retain text plus omissions')
check(images[3].value==nil and images[3].content_omissions.unsupported==1,'completed reasoning-only message explicit omission')
-- Mixed optional IDs must converge in both orders, across batches and DB reopen.
for order=1,2 do
  local scope='review-mirrors-'..order
  local sequence=order==1 and {response(nil,'repeat'),response(nil,'repeat'),completed('id1','repeat'),completed('id2','repeat')}
    or {completed('id1','repeat'),completed('id2','repeat'),response(nil,'repeat'),response(nil,'repeat')}
  local chunks={};for _,record in ipairs(sequence) do chunks[#chunks+1]=json.encode(record) end
  write(review_file,table.concat(chunks,'\n')..'\n')
  local mo=options('openai',scope,review_file);mo.source.root=tmp;mo.source.session=scope;mo.max_records=1
  for i=1,#sequence do
    assert(imports.ingest(mo))
    package.loaded.imports=nil;package.loaded['imports.init']=nil;imports=require('imports')
    db:close();db=assert(require('db').open(dbpath));imports.configure{db=db}
  end
  local messages=imports.read(scope)
  check(#messages==2,'both mirror orders preserve repeated identical occurrences across restart')
  for i,e in ipairs(messages) do
    check(#e.source_refs==2 and #e.observed_ids==1 and e.observed_ids[1]=='id'..i,'mirror preserves observed ID and both source refs')
  end
  check(assert(imports.ingest(mo)).added==0,'mirror aliases survive reimport')
end
local distinct=review_rows('review-distinct','openai',{
  response('a','same'),completed('b','same'),response('c','same'),completed('d','same')
})
check(#distinct==4,'differing explicit mirror IDs do not coalesce repeated identical content')
-- Replaying another export cannot use a prior missing-ID alias to merge a new ID.
local alias_rows,_,alias_options=review_rows('review-alias-conflict','openai',{
  response(nil,'same'),completed('known-id','same')
})
check(#alias_rows==1,'initial optional-ID alias joins')
local alias_file=tmp..'/alias-other.jsonl';write(alias_file,json.encode(completed('different-id','same'))..'\n')
alias_options.source.path=alias_file
check(assert(imports.ingest(alias_options)).added==1 and #imports.read('review-alias-conflict')==2,'known distinct ID cannot merge through missing-ID alias')
-- Source/checkpoint metadata must be checked after late credential discovery.
local private_path=tmp..'/source-name-credential.jsonl'
write(private_path,json.encode(response('path-echo','source-name-credential'))..'\n'..
  json.encode({type='response_item',payload={type='function_call',call_id='path-secret',arguments=[[{"password":"source-name-credential"}]]}})..'\n')
local path_options=options('openai','review-source-path',private_path);path_options.source.root=tmp;path_options.source.session='review-source-path'
assert(imports.ingest(path_options))
for _,record in ipairs(db:query("SELECT body FROM import_sources WHERE scope='review-source-path'")) do
  check(not record.body:find('source-name-credential',1,true),'source path redacted after late discovery')
end
write(review_file,json.encode({type='response_item',payload={type='function_call',call_id='sensitive-session',arguments=[[{"password":"checkpoint-credential"}]]}})..'\n')
local sensitive=options('openai','review-sensitive',review_file);sensitive.source.root=tmp;sensitive.source.session='checkpoint-credential'
check(not imports.ingest(sensitive),'late-learned credential cannot enter checkpoint session')
check(#db:query("SELECT * FROM import_checkpoints WHERE scope='review-sensitive'")==0,'sensitive checkpoint failure persists no checkpoint')
for _,table_name in ipairs({'import_events','import_sources','import_refs','import_quarantine','import_checkpoints','import_aliases'}) do
  for _,record in ipairs(db:query('SELECT * FROM '..table_name)) do
    local body=json.encode(record)
    check(not body:find('batch-labelled-credential',1,true) and not body:find('metadata-credential',1,true) and not body:find('source-name-credential',1,true),'all durable batch/metadata/alias rows sanitized')
    check(not body:find('PRIVATE-BLOCK-SENTINEL',1,true),'unsupported/private block bytes omitted everywhere')
  end
end
os.remove(review_file);os.remove(alias_file);os.remove(private_path)

db:close();os.remove(dbpath);os.remove(path);os.remove(copy);uv.fs_rmdir(tmp)
print('imports: '..passed..' checks passed')
