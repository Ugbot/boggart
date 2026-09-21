-- Synthetic fixture databases only: no personal-store or external deletion.
local retention,evidence=require('evidence_retention'),require('evidence')
local json,dbmod=require('json'),require('db')
local path=os.tmpname();local db=assert(dbmod.open(path));local peer=assert(dbmod.open(path))
retention.configure{db=db};evidence.configure{db=db,inline_bytes=100}
local count=0
local function check(v,label) assert(v,label);count=count+1 end
local function n(table_name,where,args) return assert(db:query('SELECT COUNT(*) AS n FROM '..table_name..(where and ' WHERE '..where or ''),args))[1].n end
local function append(id,scope,text)
  return evidence.append{run_id=id,scope=scope,kind='fixture',payload={text=text}}
end
assert(append('owned-a','project-a','private-a'..string.rep('x',200)))
assert(append('owned-b','project-b','private-b'..string.rep('y',200)))
local span=evidence.begin('workflow',{run_id='export',scope='project-a'},{password='fixture-export-credential',text='fixture-export-credential'})
assert(evidence.finish(span,{status='succeeded'}))
local export=assert(retention.export_run('export','redacted'))
check(export.evidence_complete and not export.promotion_qualified,'export evidence is not evaluation qualification')
check(not json.encode(export):find('fixture-export-credential',1,true),'export cannot recover credentials')
assert(retention.register_lineage('evaluation-a',{'export'}))
check(retention.lineage('evaluation-a').valid,'complete evidence lineage initially valid')
local incomplete=evidence.begin('workflow',{run_id='unfinished',scope='project-a'},{})
check(not retention.export_run(incomplete.run_id).evidence_complete,'unmatched boundary excludes complete evidence')
assert(append('missing-artifact','project-a',string.rep('m',200)))
local missing=evidence.read_run('missing-artifact')[1].artifact_refs[1].id
assert(db:run('DELETE FROM evidence_artifacts WHERE id=?',{missing}))
check(not retention.export_run('missing-artifact'),'missing artifact fails export')
check(not retention.export_run('absent'),'missing run fails export')
check(not pcall(retention.delete_scope,'fixture-export-credential'),'deletion metadata cannot persist a credential as a new scope label')
local artifacts_before=n('evidence_artifacts')
local deleted=assert(retention.delete_scope('project-a'))
check(deleted.local_deleted and deleted.external_status=='pending' and not deleted.physical_erasure,'truthful local/external/physical status')
check(#evidence.read_run('owned-a')==0,'deleted scope has no native retrieval entries')
check(#evidence.read_run('owned-b')==1,'unrelated native evidence preserved')
check(n('evidence_artifacts')<artifacts_before and n('evidence_artifacts')==1,'only owned artifacts removed')
check(not retention.lineage('evaluation-a').valid,'deletion invalidates evaluation lineage')
check(not retention.export_run('owned-a'),'deleted run cannot export')
check(not append('owned-a',nil,'resurrection'),'existing unscoped writer cannot resurrect owned run')
check(not append('new-a','project-a','resurrection'),'new run cannot enter tombstoned scope')
check(not peer:run('INSERT INTO evidence_events(event_id,run_id,body) VALUES(?,?,?)',{'late','owned-a','{}'}),'second connection native insert fenced')
check(not peer:run('INSERT INTO evidence_artifacts(id,body) VALUES(?,?)',{missing,'{}'}),'second connection artifact insert fenced')
check(retention.delete_scope('project-a').id==deleted.id,'deletion retry stable identifier')
local ack=retention.reconcile(function()return true end)
check(ack.acknowledged==0 and #ack.unresolved==1,'ambiguous daemon success not accepted')
ack=retention.reconcile(function()error('fixture private error')end)
check(ack.acknowledged==0 and #ack.unresolved==1,'adapter failure remains durably pending')
ack=retention.reconcile(function(job)return {id=job.id,acknowledged=true} end)
check(ack.acknowledged==1 and #ack.unresolved==0,'specific acknowledgement reconciles')
check(retention.delete_scope('project-a').external_status=='acknowledged','ack persists on idempotent deletion')
-- R1: durable capture gaps cannot become complete after evidence reload/restart.
local gap_path=os.tmpname();local gap_db=assert(dbmod.open(gap_path))
evidence.configure{db=gap_db};retention.configure{db=gap_db}
local fail_insert,fail_gap=false,false
local gap_proxy=setmetatable({},{__index=function(_,name)return function(_,...)
 if name=='run' and fail_insert and select(1,...):find('INSERT INTO evidence_events',1,true) then fail_insert=false;return nil,'synthetic capture outage' end
 if name=='run' and fail_gap and select(1,...):find('INSERT OR IGNORE INTO evidence_gaps',1,true) then fail_gap=false;return nil,'synthetic gap outage' end
 return gap_db[name](gap_db,...)
end end})
evidence.configure{db=gap_proxy};fail_insert=true
local absent_start=evidence.begin('workflow',{run_id='failed-start',scope='gap-scope'},{})
check(not absent_start.event_id,'failed start fixture actually lost its event')
assert(evidence.finish(absent_start,{status='failed'}))
local missing_middle=evidence.begin('workflow',{run_id='missing-middle',scope='gap-scope'},{})
fail_insert=true;fail_gap=true
check(not evidence.append{run_id='missing-middle',kind='observation.branch',payload={private='omitted'}},'middle observation fixture actually failed')
evidence.configure{db=gap_db}
assert(evidence.finish(missing_middle,{status='succeeded'}))
assert(retention.register_lineage('gap-evaluation',{'failed-start','missing-middle'}))
package.loaded.evidence=nil
local fresh_evidence=require('evidence');fresh_evidence.configure{db=gap_db}
check(not retention.export_run('failed-start').evidence_complete,'orphan terminal stays incomplete after evidence reload')
check(not retention.export_run('missing-middle').evidence_complete,'persisted middle capture gap stays incomplete after reload')
check(not retention.lineage('gap-evaluation').valid,'restart cannot validate missing evidence lineage')
assert(fresh_evidence.append{run_id='orphan',scope='gap-scope',kind='workflow.terminal',correlation_id='orphan',payload={status='succeeded'}})
check(not retention.export_run('orphan').evidence_complete,'terminal without a matching start is incomplete even without capture metadata')
local attempt=fresh_evidence.begin('workflow',{run_id='attempt-mismatch',scope='gap-scope',attempt_id='1'},{})
attempt.attempt_id='2';assert(fresh_evidence.finish(attempt,{status='succeeded'}))
check(not retention.export_run('attempt-mismatch').evidence_complete,'lifecycle attempts must pair exactly')
assert(fresh_evidence.append{run_id='explicit-incomplete',scope='gap-scope',kind='fixture',payload={evidence={coverage='incomplete'}}})
check(not retention.export_run('explicit-incomplete').evidence_complete,'durable explicit incomplete coverage remains incomplete')
local restart_script=os.tmpname()..'.lua'
local f=assert(io.open(restart_script,'w'));f:write(string.format([[
local db=assert(require('db').open(%q))
require('evidence').configure{db=db}
local r=require('evidence_retention');r.configure{db=db}
assert(not r.export_run('failed-start').evidence_complete)
assert(not r.export_run('missing-middle').evidence_complete)
assert(not r.lineage('gap-evaluation').valid)
print('capture gaps remain incomplete in a fresh process')
]],gap_path));f:close()
local function quote(v)return "'"..v:gsub("'","'\\''").."'" end
local restarted=sys.exec(quote(assert(require('uv').exepath()))..' --eval '..quote(restart_script)..' 2>&1',20)
check(restarted.code==0,'fresh-process capture gap check: '..(restarted.out or '')..(restarted.err or ''))
os.remove(restart_script)
assert(retention.delete_scope('gap-scope'))
check(#gap_db:query('SELECT run_id FROM evidence_gaps')==0,'capture gap metadata is scope-deletion safe')
package.loaded.evidence=evidence;evidence.configure{db=db};retention.configure{db=db};gap_db:close()
-- Legacy ownership is explicitly attested, never guessed from private payload.
assert(append('legacy',nil,'project-b'))
check(not retention.export_run('legacy').evidence_complete,'legacy export never claims owned complete evidence')
check(not append('legacy','project-b','relabel'),'ordinary observation cannot assign legacy ownership')
assert(retention.adopt_run('legacy','migration'))
assert(retention.delete_scope('migration'))
check(#evidence.read_run('legacy')==0,'explicit migration makes deletion addressable')
-- Scope isolation in caches, portable runs, suspended providers, and nested calls.
local workflow,cap,invoke,runstore=require('workflow'),require('capability'),require('invoke'),require('runstore')
runstore.configure{db=db}
local authority=invoke.context{state={mode='auto',guards=false}}
local reads=0
local descriptor=assert(cap.register({id='retention.read',version='1',effect='read',cache='result',revision='r',provider_revision='p',source_revision='s'},function(args)reads=reads+1;return args end))
local outcome=cap.call(authority,descriptor.id,'1',{text='cache-private'})
local freshness={ttl=60,revision='f'}
assert(runstore.cache.store(descriptor,{text='cache-private'},{},freshness,outcome,{scope='cache-a'}))
assert(runstore.cache.store(descriptor,{text='cache-private'},{},freshness,outcome,{scope='cache-b'}))
check(n('durable_cache')==2,'same cache arguments owned independently')
assert(retention.delete_scope('cache-a'))
check(n('durable_cache')==1,'deleting one cache owner preserves another')
check(not pcall(runstore.cache.lookup,descriptor,{text='cache-private'},{},freshness,{scope='cache-a',authority=authority}),'deleted cache lookup blocked')
check(runstore.cache.lookup(descriptor,{text='cache-private'},{},freshness,{scope='cache-b',authority=authority})~=nil,'unrelated cache still usable')
local effects=0
assert(cap.register({id='retention.pause',version='1',effect='pure',revision='1'},function()coroutine.yield('fixture pause');return true end))
assert(cap.register({id='retention.effect',version='1',effect='write',revision='1'},function()effects=effects+1;return true end))
assert(workflow.register{id='retention.flow',version='1',durable='replay-v1',capabilities={['retention.pause']='1',['retention.effect']='1'},source=[[
return function(ctx)
 ctx:step('pause',function()ctx:call('retention.pause',{})end)
 return ctx:step('effect',function()return ctx:call('retention.effect',{}).result end)
end]]})
local h=assert(workflow.start('retention.flow',{scope='run-a',authority=authority,context={private='durable-private'}}))
local run=h:snapshot().id
check(h:snapshot().status=='suspended','fixture suspended before later effect')
check(n('durable_runs')==1 and n('durable_steps')>0,'durable private copies exist before deletion')
assert(retention.delete_scope('run-a'))
check(n('durable_runs')==0 and n('durable_steps')==0,'portable package and step payloads removed')
check(h:snapshot().status=='failed' and h:snapshot().result==nil,'deleted in-memory handle cannot export its private snapshot')
check(h:resume().status=='failed' and effects==0,'suspended run visibly refuses continuation')
check(not runstore.resume(run,{authority=authority}),'portable resume cannot reconstruct deleted context')
check(not append(run,nil,'late terminal'),'late terminal cannot repopulate')
-- R2: standalone invocation ancestry owns nested context, workflow and cache.
local context=require('context')
local resolver=context.new({private='nested-private-sentinel'},nil,authority)
local explicit_context=context.new({private='nested-private-sentinel'},nil,authority,{scope='conflicting-scope'})
assert(append('unrelated-global','global','global-retained-sentinel'))
assert(append('explicit-context-run','other-context-scope','other-retained'))
local explicit_run=context.new({private='nested-private-sentinel'},nil,authority,{run_id='explicit-context-run'})
assert(workflow.register{id='retention.nested',version='1',run=function(ctx)return ctx:resolve('private')end})
local nested_id,child,child_scope
local safe=require('tools').tool_env().coroutine
local registry={}
invoke.bind(registry,function()return {id='retention.outer',version='1',effect='pure'}end,function()
 local before=invoke.correlation()
 check(before.scope=='nested-scope','standalone invocation exposes trusted active scope')
 local copied=invoke.correlation();copied.scope='tampered'
 check(invoke.correlation().scope=='nested-scope','correlation accessor returns a private copy')
 check(resolver:resolve('private')=='nested-private-sentinel','nested context resolves inherited scope')
 local denied,why=explicit_context:resolve('private')
 check(not denied and why.code=='retention_scope_mismatch','nested context explicit scope conflict refused')
 denied,why=explicit_run:resolve('private')
 check(not denied and why.code=='retention_scope_mismatch','nested context conflicting persisted run refused')
 denied,why=workflow.start('retention.nested',{scope='conflicting-scope',authority=authority})
 check(not denied and why.code=='retention_scope_mismatch','nested workflow explicit scope conflict refused')
 local nested=assert(workflow.start('retention.nested',{authority=authority,context={private='nested-private-sentinel'}}))
 nested_id=nested:snapshot().id
 check(nested:snapshot().result=='nested-private-sentinel','nested workflow executes with inherited ownership')
 assert(runstore.cache.store(descriptor,{text='cache-private'},{},freshness,outcome))
 check(not pcall(runstore.cache.store,descriptor,{text='cache-private'},{},freshness,outcome,{scope='conflicting-scope'}),'nested cache explicit scope conflict refused')
 local value,conflict=invoke.call(authority,'retention.outer',{}, {registry=registry,scope='conflicting-scope'})
 check(not value and conflict.code=='retention_scope_mismatch','nested invocation explicit scope conflict refused')
 child=safe.create(function()
   child_scope=invoke.correlation().scope
   coroutine.yield('child suspended')
   check(invoke.correlation().scope=='nested-scope','coroutine preserves inherited owner after parent invocation returns')
   return resolver:resolve('private')
 end)
 assert(safe.resume(child))
 check(child_scope=='nested-scope' and invoke.correlation().run_id==before.run_id,'child coroutine does not replace parent correlation')
 return 'nested-private-sentinel'
end)
check(invoke.correlation().scope==nil,'host starts without active invocation scope')
local nested_value=assert(invoke.call(authority,'retention.outer',{}, {registry=registry,scope='nested-scope'}))
check(nested_value=='nested-private-sentinel' and invoke.correlation().scope==nil,'invocation completion restores host correlation')
local resumed,value=safe.resume(child)
check(resumed and value=='nested-private-sentinel' and invoke.correlation().scope==nil,'resuming inherited coroutine does not contaminate resumer')
check(evidence.scope_for_run(nested_id)=='nested-scope','nested workflow has parent scope in durable ownership')
check(n('retention_cache','scope=?',{'nested-scope'})==1,'nested default cache belongs to active invocation scope')
local standalone=context.new({private=function()
  check(invoke.correlation().scope=='standalone-context','standalone scoped provider establishes correlation')
  assert(runstore.cache.store(descriptor,{text='cache-private'},{},freshness,outcome))
  return 'standalone-private-sentinel'
end},nil,authority,{scope='standalone-context'})
check(standalone:resolve('private')=='standalone-private-sentinel' and invoke.correlation().scope==nil,'standalone context restores host correlation')
local throwing=context.new({private=function()error('synthetic provider failure')end},nil,authority,{scope='standalone-context'})
check(not throwing:resolve('private') and invoke.correlation().scope==nil,'throwing provider also restores correlation')
check(n('retention_cache','scope=?',{'standalone-context'})==1,'standalone provider cache inherits context scope')
local yielding=context.new({private=function()
  check(invoke.correlation().scope=='standalone-context','yielding provider has scoped correlation')
  coroutine.yield('provider suspended')
  check(invoke.correlation().scope=='standalone-context','provider retains scoped correlation on resume')
  return 'standalone-private-sentinel'
end},nil,authority,{scope='standalone-context'})
local provider_thread=safe.create(function()
  local value=yielding:resolve('private')
  check(invoke.correlation().scope==nil,'provider return restores coroutine correlation')
  return value
end)
local suspended,marker=safe.resume(provider_thread)
check(suspended and marker=='provider suspended' and invoke.correlation().scope==nil,'provider yield does not leak scope into resumer')
local completed,provider_value=safe.resume(provider_thread)
check(completed and provider_value=='standalone-private-sentinel' and invoke.correlation().scope==nil,'provider resume preserves host restoration')
assert(retention.delete_scope('standalone-context'))
check(n('evidence_events','body LIKE ?',{'%standalone-private-sentinel%'})==0,'standalone context payload removed with its scope')
assert(retention.delete_scope('nested-scope'))
check(n('evidence_events',"body LIKE ?",{'%nested-private-sentinel%'})==0,'parent deletion removes all nested private observations')
check(n('durable_cache','key IN (SELECT key FROM retention_cache WHERE scope=?)',{'nested-scope'})==0,'parent deletion removes inherited cache body')
check(#evidence.read_run('unrelated-global')==1,'unrelated global evidence survives nested-scope deletion')
-- Imports have independent identity/alias/checkpoint payloads and same tombstone.
local imports=require('imports');imports.configure{db=db}
local fixture_root=assert(require('uv').cwd())..'/tests/fixtures/process_logs'
local import_options={format='claude',scope='import-a',source={root=fixture_root,path=fixture_root..'/claude.jsonl'},redaction={literals={}}}
local imported,why=imports.ingest(import_options)
assert(imported,why)
check(n('import_events','scope=?',{'import-a'})>0,'synthetic import populated')
assert(retention.delete_scope('import-a'))
for _,name in ipairs({'import_events','import_sources','import_refs','import_quarantine','import_checkpoints','import_aliases'}) do
 check(n(name,'scope=?',{'import-a'})==0,name..' payloads removed')
end
check(not imports.ingest(import_options),'loaded importer cannot resurrect old source')
import_options.source.path=fixture_root..'/boggart.jsonl';import_options.format='boggart'
check(not imports.ingest(import_options),'new source cannot enter tombstoned scope')
local racing=setmetatable({},{__index=function(_,name)return function(_,...)
 if name=='exec' and select(1,...)=='BEGIN IMMEDIATE' then retention.delete_scope('import-race') end
 return db[name](db,...)
end end})
imports.configure{db=racing};import_options.scope='import-race'
check(not imports.ingest(import_options),'import parsed before deletion cannot commit after tombstone')
check(n('import_events','scope=?',{'import-race'})==0 and n('import_checkpoints','scope=?',{'import-race'})==0,'racing import leaves no payload or checkpoint')
imports.configure{db=db}
check(not peer:run('INSERT INTO import_aliases VALUES(?,?,?,?,?,?,?)',{'late','import-a','m','p','l','e','lane'}),'second connection alias insert fenced')
-- Rollback must not claim deletion or leave a half-written tombstone.
assert(append('rollback','rollback-scope','rollback-private'))
local broken=setmetatable({},{__index=function(_,name)return function(_,...) if name=='run' and select(1,...):find('DELETE FROM evidence_events',1,true) then return nil,'fixture storage outage' end;return db[name](db,...) end end})
retention.configure{db=broken}
check(not pcall(retention.delete_scope,'rollback-scope'),'storage failure does not return success')
retention.configure{db=db}
check(n('retention_scopes','scope=? AND deleted_at IS NOT NULL',{'rollback-scope'})==0 and #evidence.read_run('rollback')==1,'failed deletion rolls back tombstone and payload changes')
assert(retention.configure_scope('rollback-scope',{expires_at=100}))
local swept=retention.sweep(99);check(swept.deleted_scopes==0,'scope retained until expiry')
swept=retention.sweep(100)
check(swept.deleted_scopes==1 and swept.counts.evidence_events==1 and #swept.unresolved>0,'sweep returns counts and unresolved external deletion')
-- Real store APIs on the synthetic profile store; preserve globals and FTS.
evidence.configure{db=bog.db};retention.configure{db=bog.db}
local store=bog.store
local fixture_id=evidence.id('retention-fixture')
local token=fixture_id:gsub('[^%w]','')
local session_scope_a,session_scope_b=fixture_id..':a',fixture_id..':b'
local legacy_artifact,legacy_event=fixture_id..':artifact',fixture_id..':event'
local private_search,other_search,global_search='privatesearch'..token,'othersearch'..token,'globalsearch'..token
local degraded_scope,saturated_scope,saturated_run=fixture_id..':degraded',fixture_id..':saturated',fixture_id..':run'
local global_id=store.sess_create('global fixture','fixture')
local other=store.sess_create('unrelated fixture','fixture',session_scope_b)
assert(evidence.read_run('initialize-native-schema'))
local legacy_sid=store.sess_create('legacy private session','fixture',session_scope_a)
assert(bog.db:run('INSERT INTO evidence_artifacts(id,body) VALUES(?,?)',{legacy_artifact,'{"text":"legacy-private"}'}))
assert(bog.db:run('INSERT INTO evidence_events(event_id,run_id,body) VALUES(?,?,?)',{legacy_event,tostring(legacy_sid),json.encode{run_id=legacy_sid,kind='session.entry',artifact_refs={{id=legacy_artifact}},payload={evidence_marker='artifact',id=legacy_artifact}}}))
local sid=store.sess_create('private session sentinel','fixture',session_scope_a)
local child=store.thread_create{parent_id=sid,title='private child',model='fixture',spec={private='child-private'}}
check(store.sess_load(child).project==session_scope_a,'child session inherits trusted parent project')
store.sess_save(sid,'private session sentinel','fixture',{{role='user',content=private_search}})
store.sess_save(other,'other session','fixture',{{role='user',content=other_search}})
store.mem_put('private memory',private_search,session_scope_a)
store.mem_put('other memory',other_search,session_scope_b)
store.mem_put('global memory',global_search)
assert(require('sessionlog').append(sid,sid,'user','private transcript'))
assert(bog.db:run('INSERT INTO journal(from_id,to_id,payload) VALUES(?,?,?)',{sid,sid,'private journal'}))
check(not pcall(store.sess_assign,sid,session_scope_b),'observed session cannot silently move ownership')
check(not pcall(store.project_absorb,session_scope_a),'project absorb cannot separate observed transcript from evidence')
check(store.sess_load(sid).project==session_scope_a,'failed transfer leaves owner unchanged')
local sm=assert(retention.delete_scope(session_scope_a))
check(sm.counts.sessions==3 and sm.counts.records==1 and sm.counts.journal==1,'sessions records and journal private copies removed')
local search_deleted_scope=bog.db:query("SELECT COUNT(*) AS total FROM sessions_fts WHERE sessions_fts MATCH ?",{private_search})[1]
assert(search_deleted_scope.total==0);count=count+1
check(#store.mem_search(private_search,session_scope_a)==0,'memory FTS removed')
check(#store.mem_search(other_search,session_scope_b)==1 and #store.mem_search(global_search)==1,'unrelated and global memory survive')
check(#store.sess_search(other_search)==1 and store.sess_load(global_id),'unrelated and global sessions survive')
check(not evidence.artifact(legacy_artifact),'legacy session artifact copy removed by trusted session ownership')
check(not bog.db:run('INSERT INTO evidence_artifacts(id,body) VALUES(?,?)',{legacy_artifact,'{}'}),'legacy artifact ID cannot resurrect')
check(not require('sessionlog').replay(sid),'deleted transcript replay visibly fails')
check(not bog.db:run('INSERT INTO journal(from_id,payload) VALUES(?,?)',{sid,'late'}),'late journal write fenced')
check(not bog.db:run('INSERT INTO memory(title,body,project) VALUES(?,?,?)',{'late','private',session_scope_a}),'memory reinsertion fenced')
local insert_ok,insert_error=pcall(store.sess_create,'denied session','fixture',session_scope_a)
check(not insert_ok and tostring(insert_error):find('retention_scope_deleted',1,true),'session insertion surfaces tombstone refusal rather than nil dereference')
local next_id=store.sess_create('new unrelated session','fixture',session_scope_b)
check(next_id>child,'deleted maximum session ID never reused')
-- Stop/degraded policy gates effects even when capture fails; tombstones always win.
local real_append=evidence.append
local failure_count=evidence.status().failures
evidence.append=function()return nil,'evidence_capture_failed' end
local failed_effect=cap.call(authority,'retention.effect','1',{})
check(failed_effect.status~='succeeded' and effects==0,'stop policy refuses effect before dispatch')
evidence.configure{failure_policy='degraded'}
local degraded=cap.call(authority,'retention.effect','1',{})
check(degraded.status~='succeeded' and effects==0,'degraded policy still refuses external effects')
local pure_count=0
assert(cap.register({id='retention.pure',version='1',effect='pure'},function()pure_count=pure_count+1;return true end))
local pure=cap.call(authority,'retention.pure','1',{})
check(pure.status=='succeeded' and pure.receipt.evidence.coverage=='incomplete','degraded pure computation exposes incomplete evidence')
assert(retention.delete_scope(degraded_scope))
local blocked=invoke.call(authority,'retention.pure',{}, {registry=cap,scope=degraded_scope})
check(blocked==nil and pure_count==1,'degraded capture cannot bypass deleted scope')
evidence.append=real_append;evidence.configure{failure_policy='stop'}
-- Module reload keeps durable tombstones/outbox; learned redaction is not reset.
local learned=evidence.status().learned_secrets
package.loaded.evidence_retention=nil
local reopened=require('evidence_retention');reopened.configure{db=peer}
check(not pcall(reopened.assert_run,peer,'owned-a'),'new module and second connection see tombstone')
check(#reopened.pending()>0 and evidence.status().learned_secrets==learned,'outbox persists without quota/redaction capacity reset')
db:close();peer:close()
check(not reopened.export_run('owned-b'),'storage outage cannot export successfully')
-- Bounded, fair, payload-free outage bookkeeping; no tombstone resurrection.
local saved_evidence=package.loaded.evidence
package.loaded.evidence=nil
local bounded=require('evidence')
local function outage_fixture(label)
 local database=assert(dbmod.open(os.tmpname()))
 bounded.configure{db=database}
 assert(bounded.append{run_id=label..':seed',scope=label,kind='fixture',payload={value='synthetic'}})
 local state={outage=true,gap_attempts=0,marker_attempts=0}
 local wrapper=setmetatable({},{__index=function(_,name)return function(_,...)
   local sql=select(1,...)
   if name=='run' and sql:find('INSERT OR IGNORE INTO evidence_gaps',1,true) then state.gap_attempts=state.gap_attempts+1;if state.outage then return nil,'gap outage' end end
   if name=='run' and sql:find('INSERT OR IGNORE INTO evidence_capture_state',1,true) then state.marker_attempts=state.marker_attempts+1;if state.outage then return nil,'marker outage' end end
   if name=='run' and state.outage and sql:find('INSERT INTO evidence_events',1,true) then return nil,'event outage' end
   return database[name](database,...)
 end end})
 return database,wrapper,state
end
local outage_a,proxy_a,state_a=outage_fixture('outage-a')
local outage_b,proxy_b,state_b=outage_fixture('outage-b')
for _,fixture in ipairs({{proxy_a,'outage-a'},{proxy_b,'outage-b'}}) do
 bounded.configure{db=fixture[1]}
 for i=1,30 do assert(not bounded.append{run_id=fixture[2]..':'..i,scope=fixture[2],kind='fixture'}) end
end
check(bounded.status().pending_gaps==60,'outages retain one bounded metadata entry per failed run')
state_b.outage=false;bounded.configure{db=proxy_b}
for i=1,8 do
 local before=state_a.gap_attempts+state_b.gap_attempts
 assert(bounded.append{run_id='outage-b:seed',kind='fixture'})
 check(state_a.gap_attempts+state_b.gap_attempts-before<=bounded.status().gap_retry_limit,'capture performs at most bounded retry work')
end
check(#outage_b:query('SELECT run_id FROM evidence_gaps')==30 and bounded.status().pending_gaps==30,'healthy queue drains despite another database staying unavailable')
reopened.configure{db=outage_a};assert(reopened.delete_scope('outage-a'))
for i=1,2 do assert(bounded.append{run_id='outage-b:seed',kind='fixture'}) end
check(bounded.status().pending_gaps==0,'retries discard entries proved tombstoned')
bounded.configure{db=proxy_a}
for i=1,20 do assert(not bounded.append{run_id='outage-a:'..i,kind='fixture'}) end
check(bounded.status().pending_gaps==0,'repeated deleted-scope failures cannot grow retry memory')
bounded.configure{secrets={'malformed-fixture-credential'}}
assert(not bounded.append{run_id='malformed-fixture-credential',scope='another',kind='fixture'})
check(bounded.status().pending_gaps==0,'malformed secret correlation label is not retained in retry memory')
-- Use a fresh evidence instance for overflow, so its persisted refusal is the
-- reason reload remains incomplete rather than an unrelated process counter.
package.loaded.evidence=nil;bounded=require('evidence')
local overflow_db,overflow_proxy,overflow_state=outage_fixture('overflow')
bounded.configure{db=overflow_db}
assert(bounded.append{run_id='overflow-survivor',scope='overflow-unrelated',kind='fixture',payload={value='retained'}})
bounded.configure{db=overflow_proxy}
for i=1,300 do assert(not bounded.append{run_id='overflow:'..i,scope='overflow',kind='fixture'}) end
local bounded_status=bounded.status()
check(bounded_status.capture_blocked and bounded_status.pending_gaps<=256 and bounded_status.pending_gap_bytes<=65536,'overflow is bounded and enters sticky refusal')
check(#overflow_db:query('SELECT id FROM evidence_capture_state')==0,'outage cannot falsely claim its overflow marker was persisted')
overflow_state.outage=false
check(not bounded.append{run_id='overflow:seed',kind='fixture'},'recovered storage does not clear sticky capture refusal')
check(#overflow_db:query('SELECT id FROM evidence_capture_state')==1,'overflow marker persists when storage next permits')
package.loaded.evidence=nil;local after_overflow=require('evidence');after_overflow.configure{db=overflow_db}
reopened.configure{db=overflow_db}
check(not reopened.export_run('overflow-survivor').evidence_complete,'persisted overflow prevents complete export after reload')
check(not after_overflow.append{run_id='new-after-overflow',scope='new',kind='fixture'} and after_overflow.status().capture_blocked,'reload still refuses capture in overflowed store')
assert(reopened.delete_scope('overflow'))
check(not reopened.export_run('overflow-survivor').evidence_complete,'scope deletion cannot clear database-wide overflow uncertainty')
package.loaded.evidence=nil;bounded=require('evidence')
local byte_db,byte_proxy=outage_fixture('byte-outage')
bounded.configure{db=byte_proxy}
for i=1,20 do assert(not bounded.append{run_id=tostring(i)..string.rep('x',4000),scope='byte-outage',kind='fixture'}) end
bounded_status=bounded.status()
check(bounded_status.capture_blocked and bounded_status.pending_gaps<256 and bounded_status.pending_gap_bytes<=65536,'byte cap bounds large labels independently of entry count')
-- R4: GC and handle replacement cannot erase unresolved knowledge. All queue
-- registry metadata and labels also have aggregate bounds across distinct stores.
local function registry_regressions()
 local function fresh() package.loaded.evidence=nil;bounded=require('evidence') end
 fresh()
 local path=os.tmpname();local actual=assert(dbmod.open(path))
 bounded.configure{db=actual}
 local span=bounded.begin('workflow',{run_id='gc-gap',scope='gc-scope'},{})
 local identity=actual:query('SELECT identity FROM evidence_store_identity')[1].identity
 do
   local wrapper=setmetatable({},{__index=function(_,name)return function(_,...)
     local sql=select(1,...)
     if name=='run' and (sql:find('INSERT INTO evidence_events',1,true) or sql:find('INSERT OR IGNORE INTO evidence_gaps',1,true)) then return nil,'synthetic gc outage' end
     return actual[name](actual,...)
   end end})
   bounded.configure{db=wrapper}
   assert(not bounded.append{run_id=span.run_id,kind='observation.branch'})
   check(bounded.status().pending_gaps==1,'GC fixture records an unresolved middle capture gap')
   bounded.configure{db=actual}
 end
 collectgarbage('collect')
 check(bounded.status().pending_gaps==1,'wrapper collection cannot erase pending gap')
 assert(bounded.finish(span,{status='succeeded'}))
 check(#actual:query('SELECT run_id FROM evidence_gaps')==1,'verified underlying connection persists released-wrapper gap')
 fresh();bounded.configure{db=actual};reopened.configure{db=actual}
 check(not reopened.export_run('gc-gap').evidence_complete,'GC recovery remains incomplete after evidence reload')
 -- A genuine closed handle needs a verified same-store replacement; an unrelated
 -- live database must never receive the closed store's gap.
 local before=bounded.begin('workflow',{run_id='reopen-gap',scope='reopen-scope'},{})
 do
   local wrapper=setmetatable({},{__index=function(_,name)return function(_,...)
     local sql=select(1,...)
     if name=='run' and (sql:find('INSERT INTO evidence_events',1,true) or sql:find('INSERT OR IGNORE INTO evidence_gaps',1,true)) then return nil,'synthetic close outage' end
     return actual[name](actual,...)
   end end})
   bounded.configure{db=wrapper};assert(not bounded.append{run_id=before.run_id,kind='observation.branch'})
 end
 actual:close()
 local unrelated=assert(dbmod.open(os.tmpname()));bounded.configure{db=unrelated}
 assert(bounded.append{run_id='unrelated-switch',scope='unrelated-switch',kind='fixture'})
 collectgarbage('collect')
 check(bounded.status().pending_gaps==1 and #unrelated:query('SELECT run_id FROM evidence_gaps')==0,'closed-store gaps survive switching without crossing store identities')
 local reopened_db=assert(dbmod.open(path));bounded.configure{db=reopened_db}
 check(reopened_db:query('SELECT identity FROM evidence_store_identity')[1].identity==identity,'store identity persists across genuine close/reopen')
 assert(bounded.finish(before,{status='succeeded'}))
 check(#reopened_db:query("SELECT run_id FROM evidence_gaps WHERE run_id='reopen-gap'")==1,'same-store reopened connection recovers pending gap')
 local peer_db=assert(dbmod.open(path));bounded.configure{db=peer_db}
 check(peer_db:query('SELECT identity FROM evidence_store_identity')[1].identity==identity,'independent connection reads the elected singleton identity')
 peer_db:close();reopened_db:close();unrelated:close()
 -- Strong handle ownership is capped globally, including pending marker-only
 -- stores. Excess unknown stores cause conservative process-wide refusal.
 fresh()
 local fixtures={}
 for i=1,9 do local d,p,state=outage_fixture('registry-'..i);fixtures[i]={db=d,proxy=p,state=state} end
 for i,fixture in ipairs(fixtures) do
   bounded.configure{db=fixture.proxy}
   assert(not bounded.append{run_id='registry-'..i..':missing',scope='registry-'..i,kind='fixture'})
 end
 local status=bounded.status()
 check(status.capture_blocked and status.gap_registry_overflow and status.pending_gap_stores<=status.gap_store_limit,'distinct-store registry admission is globally bounded and sticky')
 check(status.pending_gaps<=status.gap_total_limit and status.pending_gap_bytes<=status.gap_total_byte_limit,'aggregate queued labels/count remain bounded with excess stores')
 local weak=setmetatable({},{__mode='v'})
 for i=1,8 do weak[i]=fixtures[i].proxy end
 for _,fixture in ipairs(fixtures) do fixture.proxy=nil end
 collectgarbage('collect')
 local all_retained=true;for i=1,8 do all_retained=all_retained and weak[i]~=nil end
 check(all_retained,'all unresolved markers/gaps retain their database wrappers strongly')
 for _,fixture in ipairs(fixtures) do fixture.state.outage=false end
 bounded.configure{db=fixtures[9].db}
 check(not bounded.append{run_id='registry-9:seed',kind='fixture'},'registry recovery does not reset refusal')
 for _,fixture in ipairs(fixtures) do
   bounded.configure{db=fixture.db}
   assert(not bounded.append{run_id='recovery-attempt',kind='fixture'})
 end
 local all_marked=true
 for _,fixture in ipairs(fixtures) do all_marked=all_marked and #fixture.db:query('SELECT id FROM evidence_capture_state')==1 end
 check(all_marked,'retained and initially excess stores receive conservative markers when recovered')
 fresh();bounded.configure{db=fixtures[9].db};reopened.configure{db=fixtures[9].db}
 check(not reopened.export_run('registry-9:seed').evidence_complete,'excess-store refusal marker survives module reload')
 for _,fixture in ipairs(fixtures) do fixture.db:close() end
 -- Aggregate run count and byte limits are independent of the per-store caps.
 fresh();fixtures={}
 for i=1,3 do local d,p,state=outage_fixture('total-count-'..i);fixtures[i]={db=d,proxy=p} end
 for i,fixture in ipairs(fixtures) do
   bounded.configure{db=fixture.proxy}
   for n=1,200 do assert(not bounded.append{run_id='total-count-'..i..':'..n,scope='total-count-'..i,kind='fixture'}) end
 end
 status=bounded.status()
 check(status.capture_blocked and status.gap_registry_overflow and status.pending_gaps==status.gap_total_limit,'aggregate run limit refuses before three per-store queues fill')
 for _,fixture in ipairs(fixtures) do fixture.db:close() end
 fresh();fixtures={}
 for i=1,3 do local d,p,state=outage_fixture('total-bytes-'..i);fixtures[i]={db=d,proxy=p} end
 for i,fixture in ipairs(fixtures) do
   bounded.configure{db=fixture.proxy}
   for n=1,15 do assert(not bounded.append{run_id=i..':'..n..string.rep('b',4000),scope='total-bytes-'..i,kind='fixture'}) end
 end
 status=bounded.status()
 check(status.capture_blocked and status.gap_registry_overflow and status.pending_gap_bytes<=status.gap_total_byte_limit and status.pending_gaps<status.gap_total_limit,'aggregate byte limit bounds several individually small queues')
 for _,fixture in ipairs(fixtures) do fixture.db:close() end
end
registry_regressions()
package.loaded.evidence=saved_evidence
outage_a:close();outage_b:close();overflow_db:close();byte_db:close()
-- Saturated redaction stays saturated, but does not prevent deletion of evidence.
reopened.configure{db=bog.db}
assert(append(saturated_run,saturated_scope,'private-to-remove'))
check(not pcall(evidence.redact,{password=string.rep('s',8193)}),'synthetic credential exceeds redactor bound')
assert(reopened.delete_scope(saturated_scope))
check(evidence.status().redaction_blocked and #evidence.read_run(saturated_run)==0,'deletion preserves fail-closed redactor state')
check(not reopened.export_run('export'),'saturated redaction cannot produce successful export')
print('evidence_retention: '..count..' checks passed')
