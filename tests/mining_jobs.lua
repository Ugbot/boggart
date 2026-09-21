local jobs=require('mining.jobs')
local dbpath=os.tmpname()
local db=assert(require('db').open(dbpath))
local evidence,retention=require('evidence'),require('evidence_retention')
assert(evidence.configure{db=db});assert(retention.configure{db=db})
local invoke,cap=require('invoke'),require('capability')
local authority=invoke.context{state={mode='auto',guards=false}}
assert(cap.register({id='jobs.read',version='1',effect='pure'},function(a)return {text=a.text}end))
local function record(text)
 local id=evidence.id('jobs-source')
 invoke.with_correlation({run_id=id,scope='jobs-fixture'},function()
  assert(cap.call(authority,'jobs.read','1',{text=text}).status=='succeeded')
 end)
 return id
end
local range={record('synthetic-a'),record('synthetic-b'),record('synthetic-c')}
local policy=assert(require('policy').compile{{id='mining',revision=1,capabilities={allow={'mining.analyze'}},quotas={{id='cpu',metric='analysis_ms',limit=100000000,window_seconds=60}}}})
local ledger=assert(require('quota').open(db))
local options={db=db,authority=authority,scopes={['jobs-fixture']={revision='1',enabled=true}},ledger=ledger,policy=policy,background_enabled=true}
local engine=assert(jobs.open(options))
local function start(mode,r)
 local id,e=engine:start{scope='jobs-fixture',range=r or range,objective='read text',mode=mode,budget={ticks=20,wall_ms=1000}};assert(id,e and require('json').encode(e));return id
end
local directed,background=start('directed'),start('background')
local function step(id)
 local cursor=assert(engine:status(id)).cursor
 for _=1,2000 do
  local r,e=engine:tick(id);assert(r,e and require('json').encode(e))
  local status=assert(engine:status(id))
  if status.cursor>cursor then return status end
  require('uv').sleep(1)
 end
 error('mining did not progress')
end
step(directed);step(background)
local d,b=assert(engine:status(directed)),assert(engine:status(background))
assert(d.candidates[1].source_hash==b.candidates[1].source_hash,'equivalent real compiler provenance')
assert(d.candidates[1].id==b.candidates[1].id,'overlap deduplicates admission')
assert(d.candidates[1].candidate.manifest.activation_eligible==false)
print('mining_jobs: initial compiler/overlap checks passed')
local count=3
local function check(v,msg)assert(v,msg);count=count+1 end
-- Every pair is eventually compared, including non-adjacent sources.
while assert(engine:status(directed)).status~='completed' do step(directed) end
local all=assert(engine:status(directed))
check(all.cursor==3 and #all.results==3,'all three corpus pairs covered')
check(#assert(db:query('SELECT id FROM mining_candidates'))==1,'same generated source admitted once across different evidence pairs')
-- Cancellation retains cursor, and a new host object resumes the durable job.
step(background)
local before=assert(engine:status(background)).cursor
assert(engine:cancel(background));check(assert(engine:status(background)).status=='cancelled','cancel persisted')
engine=assert(jobs.open(options))
check(assert(engine:status(background)).cursor==before,'restart keeps cursor')
assert(engine:resume(background));step(background)
check(assert(engine:status(background)).status=='completed','restart completes remaining pair')
-- Defaults and priority are independent from activation.
engine:background(false)
local bg=start('background',{range[1],range[2]})
check(assert(engine:tick(bg)).status=='disabled','background switch enforced')
local fg=start('directed',{range[1],range[2]})
engine:foreground(true);check(assert(engine:tick(fg)).status=='deferred','foreground defers admission')
engine:foreground(false)
local selected=assert(engine:tick());check(selected.job_id==fg,'directed priority over background')
engine:background(true)
-- Revalidate live registry, current policy and actual native evidence on resume.
local revoked=start('directed',{range[1],range[2]})
engine:set_scope('jobs-fixture',{revision='1',enabled=false})
check(engine:tick(revoked)==nil,'live scope revocation enforced')
engine:set_scope('jobs-fixture',{revision='2',enabled=true})
check(engine:tick(revoked)==nil,'scope version mismatch fails closed')
engine:set_scope('jobs-fixture',{revision='1',enabled=true})
local oldpolicy=options.policy
options.policy=assert(require('policy').compile{{id='mining',revision=2,capabilities={deny={'mining.analyze'}}}})
check(engine:tick(revoked)==nil,'current mining authority revocation enforced')
options.policy=oldpolicy
local changed=start('directed',{range[1],range[2]})
local row=assert(db:query('SELECT seq,body FROM evidence_events WHERE run_id=? LIMIT 1',{range[1]}))[1]
assert(db:run('UPDATE evidence_events SET body=? WHERE seq=?',{row.body..' ',row.seq}))
check(engine:tick(changed)==nil,'immutable snapshot detects changed source bytes')
assert(db:run('UPDATE evidence_events SET body=? WHERE seq=?',{row.body,row.seq}))
-- Real SQLite writer collision cannot duplicate an admission.
local path=os.tmpname()
local locked=assert(require('db').open(path));local other=assert(require('db').open(path))
local smallpolicy=assert(require('policy').compile{{id='collision',revision=1,capabilities={allow={'mining.analyze'}}}})
local otherengine=assert(jobs.open{db=other,ledger=assert(require('quota').open(other)),policy=smallpolicy,authority=authority,scopes=options.scopes})
assert(locked:exec('BEGIN IMMEDIATE'))
check(otherengine:start{scope='jobs-fixture',objective='locked',range=range,mode='directed'}==nil,'writer lock refuses without candidate admission')
assert(locked:exec('ROLLBACK'));other:close();locked:close();os.remove(path)
-- Quotas for actual foreground invoke stay available while a worker analyzes.
local fgdb=assert(require('db').open(os.tmpname()))
local fgledger=assert(require('quota').open(fgdb))
local fgpolicy=assert(require('policy').compile{{id='interactive',revision=1,capabilities={allow={'jobs.read'}},quotas={{id='calls',metric='calls',limit=21,window_seconds=60}}}})
local fgcontext=invoke.context{state={mode='auto',guards=false},ledger=fgledger,policy=fgpolicy}
-- New scope and distinct capability force uncached actual compilation.
local fresh={record('fresh-a'),record('fresh-b')}
local active=start('directed',fresh)
local t0=require('uv').hrtime()
check(assert(engine:tick(active)).status=='running','real worker dispatched')
local dispatch_ms=(require('uv').hrtime()-t0)/1000000
local worst,heartbeats=0,0
local timer=require('uv').new_timer()
require('uv').timer_start(timer,1,1,function()heartbeats=heartbeats+1 end)
for i=1,20 do
 local t=require('uv').hrtime()
 check(cap.call(fgcontext,'jobs.read','1',{text='interactive'}).status=='succeeded','foreground configured quota available')
 worst=math.max(worst,(require('uv').hrtime()-t)/1000000)
 require('uv').run('nowait');require('uv').sleep(1)
end
require('uv').timer_stop(timer);require('uv').close(timer)
for _=1,2000 do
 if assert(engine:status(active)).status=='completed' then break end
 assert(engine:tick(active));require('uv').sleep(1)
end
check(assert(engine:status(active)).status=='completed','worker completes with concurrent foreground calls')
check(heartbeats>0 and worst<100 and dispatch_ms<100,'measured foreground latency bound on qualification host')
print(('mining_jobs fairness: dispatch=%.3fms foreground_max=%.3fms heartbeats=%d'):format(dispatch_ms,worst,heartbeats))
-- A transient lock at settlement must retain the completed worker result.
local retry=start('directed',{record('retry-a'),record('retry-b')})
assert(engine:tick(retry))
local blocker=assert(require('db').open(dbpath))
assert(blocker:exec('BEGIN IMMEDIATE'))
require('uv').sleep(100)
local blocked,blocked_error=engine:tick(retry)
check(blocked==nil and blocked_error~=nil,'settlement lock surfaced')
assert(blocker:exec('ROLLBACK'));blocker:close()
local retried,retry_error=engine:tick(retry)
check(retried and retried.status=='completed','completed analysis survives transient settlement lock')
-- Cancellation during analysis fences late completion, including immediate resume.
local cancelling=start('directed',{record('cancel-a'),record('cancel-b')})
assert(engine:tick(cancelling));assert(engine:cancel(cancelling));assert(engine:resume(cancelling))
for _=1,2000 do
 local r,e=engine:tick(cancelling);assert(r,e and require('json').encode(e))
 if assert(engine:status(cancelling)).status=='completed' then break end
 require('uv').sleep(1)
end
check(assert(engine:status(cancelling)).cursor==1,'cancelled generation cannot advance or poison resumed work')
-- Host trigger and supervisor use the same durable engine, not a second miner.
local controlled=assert(jobs.configure(options))
local control_id=assert(controlled:start{scope='jobs-fixture',range={range[1],range[2]},objective='control',mode='directed'})
assert(require('supervisor').mining_cancel(control_id))
check(assert(controlled:status(control_id)).status=='cancelled','supervisor cancellation persists')
assert(controlled:resume(control_id))
assert(controlled:schedule('mining-fixture',{every=1},control_id))
assert(require('triggers').fire('mining-fixture'))
check(assert(controlled:status(control_id)).status=='completed','existing trigger advances queued mining')
require('triggers').remove('mining-fixture',true)
-- Source-backed refinement uses real workflow evidence and the actual AST compiler.
local workflow=require('workflow')
local source=[[return {run=function(ctx)
 local value=ctx:call('jobs.read',{text=ctx:resolve('text')})
 if value.status=='succeeded' then return value.result end
 return {}
end}]]
local source_hash=workflow.hash(source)
options.sources={[source_hash]={scope='jobs-fixture',revision='registry-1',version='1',source=source,parameters={}}}
assert(workflow.register{id='jobs-source-workflow',version='1',source=source,capabilities={['jobs.read']='1'}})
local source_runs={}
for i=1,2 do
 local run=assert(workflow.start('jobs-source-workflow',{scope='jobs-fixture',authority=authority,context={text='source-'..i}})):snapshot()
 check(run.status=='succeeded','source-backed evidence genuinely executed')
 source_runs[i]=run.id
end
local refined=start('directed',source_runs)
step(refined)
local refined_status=assert(engine:status(refined))
check(refined_status.candidates[1].candidate.manifest.compiler=='source-subset-v1','source-backed actual lowering')
local late_source=start('background',source_runs)
options.sources[source_hash].revision='registry-2'
check(engine:tick(late_source)==nil,'source registry revision checked again')
options.sources[source_hash].revision='registry-1'
step(late_source)
check(assert(engine:status(late_source)).candidates[1].id==refined_status.candidates[1].id,'source-backed background provenance equivalent')
-- Equal generated Lua must not merge different capability-version contracts.
local versions={}
for _,version in ipairs({'1','2'})do
 assert(cap.register({id='jobs.versioned',version=version,effect='pure'},function(a)return a end))
 local ids={}
 for i=1,2 do
  ids[i]=evidence.id('jobs-versioned')
  invoke.with_correlation({run_id=ids[i],scope='jobs-fixture'},function()
   assert(cap.call(authority,'jobs.versioned',version,{text='versioned'}).status=='succeeded')
  end)
 end
 local job=start('directed',ids);step(job)
 versions[#versions+1]=assert(engine:status(job)).candidates[1]
end
check(versions[1].source_hash==versions[2].source_hash,'versioned fixture emits equal Lua')
check(versions[1].id~=versions[2].id and versions[2].candidate.manifest.capabilities['jobs.versioned']=='2','equal source cannot erase a different capability pin')
-- Inherited accounting obligations are refused instead of silently dropped.
local restricted_policy=assert(require('policy').compile{{id='inherited-mining',revision=1,capabilities={allow={'mining.analyze'}},quotas={{id='q',metric='calls',limit=1,window_seconds=60}}}})
local restricted_authority=invoke.context{state={mode='auto',guards=false},ledger=fgledger,policy=restricted_policy}
local restricted=assert(jobs.open{db=db,authority=restricted_authority,scopes=options.scopes,ledger=ledger,policy=policy})
local denied,denied_error=restricted:start{scope='jobs-fixture',range={range[1],range[2]},objective='restricted',mode='directed'}
check(not denied and denied_error.code:find('mining_inherited_quotas_unsupported',1,true),'inherited quotas cannot be erased')
-- A missed cancellation deadline rejects the result, retains cursor, accounts
-- actual elapsed usage and blocks only the dedicated mining ledger.
local budgetdb=assert(require('db').open(os.tmpname()))
local budgetledger=assert(require('quota').open(budgetdb))
local budgetengine=assert(jobs.open{db=db,authority=authority,scopes=options.scopes,ledger=budgetledger,policy=policy})
local budgetrange={record('budget-a'),record('budget-b')}
local tiny=assert(budgetengine:start{scope='jobs-fixture',range=budgetrange,objective='budget',mode='directed',budget={wall_ms=1}})
assert(budgetengine:tick(tiny));require('uv').sleep(25)
for _=1,1000 do
 assert(budgetengine:tick(tiny))
 if assert(budgetengine:status(tiny)).status~='queued' then break end
 require('uv').sleep(1)
end
local expired=assert(budgetengine:status(tiny))
check(expired.status=='budget_exhausted' and expired.cursor==0 and expired.deadline_overrun and expired.last_elapsed_ms>1,'late result refused with measured deadline overrun')
local after=assert(budgetengine:start{scope='jobs-fixture',range=budgetrange,objective='after-overrun',mode='directed',budget={wall_ms=1000}})
check(assert(budgetengine:tick(after)).status=='quota_denied','overrun stops later mining admissions')
check(cap.call(fgcontext,'jobs.read','1',{text='still-interactive'}).status=='succeeded','mining overrun preserves remaining foreground quota')
-- Review regression: legacy restrictions and allow sets are authority too.
local function restricted_engine(auth)
 return assert(jobs.open{db=db,authority=auth,scopes=options.scopes,ledger=ledger,policy=policy})
end
local function refused_authority(auth)
 return restricted_engine(auth):start{scope='jobs-fixture',range={range[1],range[2]},objective='authority-review',mode='directed'}==nil
end
check(refused_authority(invoke.context{state={mode='auto',guards=false},allow={['other.*']=true}}),'inherited allow set cannot be widened')
for _,state in ipairs({{mode='chat'}, {mode='manual'}, {mode='auto',tool_policy={['mining.analyze']='deny'}},
 {mode='auto',rules={['mining.analyze']='ask'}}, {mode='auto',agent_rules={['mining.analyze']='deny'}}})do
 check(refused_authority(invoke.context{state=state}),'legacy deny/approval cannot be widened')
end
local mutable={mode='auto',guards=false}
local mutable_engine=restricted_engine(invoke.context{state=mutable,allow={['mining.*']=true}})
local mutable_job=assert(mutable_engine:start{scope='jobs-fixture',range={range[1],range[2]},objective='live-revoke',mode='directed'})
mutable.tool_policy={['mining.analyze']='deny'}
check(mutable_engine:tick(mutable_job)==nil,'current legacy revocation enforced')
-- An independent writer completes the selected pair after lookup but before claim.
local race_db=assert(require('db').open(dbpath))
local race_options={db=race_db,authority=authority,scopes=options.scopes,ledger=assert(require('quota').open(race_db)),policy=policy}
local competitor=assert(jobs.open(race_options))
local race_id,interleave
local proxy={}
for _,name in ipairs({'exec','run','query'})do proxy[name]=function(_,sql,args)
 local result,why=db[name](db,sql,args)
 if name=='query' and interleave and sql=='SELECT body FROM mining_pairs WHERE id=?' then
  interleave=false
  for _=1,1000 do
   assert(competitor:tick(race_id))
   if assert(competitor:status(race_id)).cursor==1 then break end
   require('uv').sleep(1)
  end
  assert(assert(competitor:status(race_id)).cursor==1)
 end
 return result,why
end end
local racing=assert(jobs.open{db=proxy,authority=authority,scopes=options.scopes,ledger=ledger,policy=policy})
race_id=assert(racing:start{scope='jobs-fixture',range={record('race-a'),record('race-b'),record('race-c')},objective='race',mode='directed',budget={wall_ms=1000}})
interleave=true
for _=1,2000 do
 assert(racing:tick(race_id))
 if assert(racing:status(race_id)).status=='completed' then break end
 require('uv').sleep(1)
end
local raced=assert(racing:status(race_id));local unique={}
for _,result in ipairs(raced.results)do unique[result.pair]=true end
local pair_count=0;for _ in pairs(unique)do pair_count=pair_count+1 end
check(raced.cursor==3 and pair_count==3,'stale pair selection cannot advance a newer cursor')
race_db:close()
-- A real quota refusal followed by a cleanup write lock remains recoverable.
local cleanup_blocker=assert(require('db').open(dbpath))
local cleanup_lock,claim_written=false,false
local cleanup_proxy={}
for _,name in ipairs({'exec','query','run'})do cleanup_proxy[name]=function(_,sql,args)
 if cleanup_lock and ((name=='run' and sql:find("UPDATE mining_slot SET owner=''",1,true)) or (name=='exec' and sql=='BEGIN IMMEDIATE' and claim_written)) then
  cleanup_lock=false;assert(cleanup_blocker:exec('BEGIN IMMEDIATE'))
 end
 local result,why=db[name](db,sql,args)
 if name=='run' and sql=='UPDATE mining_slot SET owner=?,expires=? WHERE id=1' then claim_written=true end
 return result,why
end end
local zero=assert(require('policy').compile{{id='review-zero',revision=1,capabilities={allow={'mining.analyze'}},quotas={{id='zero',metric='analysis_ms',limit=0,window_seconds=60}}}})
local cleanup=assert(jobs.open{db=cleanup_proxy,authority=authority,scopes=options.scopes,ledger=ledger,policy=zero})
local cleanup_id=assert(cleanup:start{scope='jobs-fixture',range={record('cleanup-a'),record('cleanup-b')},objective='cleanup',mode='directed'})
cleanup_lock=true
check(cleanup:tick(cleanup_id)==nil,'claim cleanup writer lock surfaces')
assert(cleanup_blocker:exec('ROLLBACK'))
local recovered=assert(cleanup:tick(cleanup_id))
check(recovered.status=='quota_denied' and assert(db:query('SELECT owner FROM mining_slot WHERE id=1'))[1].owner=='','quota-denial cleanup retries without live-PID wedge')
cleanup_blocker:close()
-- Revocation invalidates stored candidate access, including after restart.
assert(retention.delete_scope('jobs-fixture'))
check(engine:status(directed)==nil,'retention deletion hides persisted candidates')
check(engine:tick(bg)==nil,'retention deletion rejects queued work')
print('mining_jobs: '..count..' checks passed')
