-- Synthetic-only host adapters; also reusable by subprocess qualification.
local workflow,cap,invoke=require('workflow'),require('capability'),require('invoke')
local runstore,json=require('runstore'),require('json')
local function fixture(path)
 -- Isolated fixture process: disable interactive repetition guards, keep policy admission.
 require('perm').state().guards=false
 local db=assert(require('db').open(path or os.tmpname()))
 assert(require('evidence').configure{db=db});assert(runstore.configure{db=db})
 assert(db:exec([[
 CREATE TABLE IF NOT EXISTS slack_campaign(key TEXT PRIMARY KEY,intent TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS slack_effect(key TEXT PRIMARY KEY,intent TEXT NOT NULL,body TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS slack_progress(key TEXT PRIMARY KEY,body TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS slack_artifact(key TEXT PRIMARY KEY,body TEXT NOT NULL);
 ]]))
 local f={db=db,world={},sent={},calls={},models=0,late={},race={},uncertain={},crash={},unavailable=false}
 local authority=invoke.context{state={mode='auto',guards=false},ledger=assert(require('quota').open(db)),
  policy=assert(require('policy').compile{{id='slack-fixture',revision=1,capabilities={allow={'*'}},limits={tokens=128}}})}
 f.authority=authority
 local function canonical(v)local _,s=runstore.snapshot(v);return s end
 local function descriptor(role,effect,runner,reconcile)
  local id='slack.fixture.'..role
  local function bounded(fn)
   return function(a,e)
    local result,meta=fn(a,e);meta=meta or {};meta.usage=meta.usage or {tokens=0};return result,meta
   end
  end
  assert(cap.register({id=id,version='1',revision='fixture-1',provider_revision='synthetic-1',source_revision='fixture-source-1',effect=effect,
   bounded={tokens=true},estimate=function(a)return {tokens=role=='model' and a.max_tokens or 0} end,
   reconcile=reconcile and bounded(reconcile),reconcile_bounded=reconcile and {tokens=true},
   reconcile_estimate=reconcile and function()return {tokens=0}end},bounded(runner)))
  return id
 end
 local pins,roles={},{}
 local function add(role,effect,runner,reconcile)roles[role]=descriptor(role,effect,runner,reconcile);pins[roles[role]]='1' end
 local function row(table_name,key)return assert(db:query('SELECT * FROM '..table_name..' WHERE key=?',{key}))[1] end
 add('bind','write',function(a)
  assert(db:exec('BEGIN IMMEDIATE'));local prior=row('slack_campaign',a.key);local intent=canonical(a.intent)
  if prior and prior.intent~=intent then assert(db:exec('COMMIT'));return {accepted=false,reason='intent_conflict'} end
  assert(db:run('INSERT OR IGNORE INTO slack_campaign(key,intent) VALUES(?,?)',{a.key,intent}))
  assert(db:exec('COMMIT'));return {accepted=true}
 end)
 add('source','read',function(a)
  f.calls[#f.calls+1]=a
  if f.unavailable then return {available=false} end
  if a.recipient and f.late[a.recipient] then f.world[a.recipient]=f.late[a.recipient];f.late[a.recipient]=nil end
  local people={}
  for _,id in ipairs(a.expected) do people[id]=f.world[id] or {kind='missing',revision='0'} end
  return {available=true,people=people,observed_at=a.now,provenance='fixture-source-1',atomic_conditional_send=f.atomic~=false}
 end)
 local function conditional(a)
  assert(db:exec('BEGIN IMMEDIATE'));local prior=row('slack_effect',a.key);local intent=canonical(a.intent)
  if prior then
   assert(db:exec('COMMIT'))
   if prior.intent~=intent then return {status='denied',reason='intent_conflict'} end
   local result=json.decode(prior.body)
   if result.status=='uncertain' then return {status='uncertain',reason='authoritative_reconciliation_required'} end
   return result
  end
  if f.race[a.recipient] then f.world[a.recipient]=f.race[a.recipient];f.race[a.recipient]=nil end
  local latest=f.world[a.recipient] or {kind='missing',revision='0'}
  local result
  if latest.kind=='opted_out' or latest.kind=='replied' then result={status=latest.kind}
  elseif latest.revision~=a.revision then result={status='pending',reason='precondition_changed'}
  elseif latest.kind~='missing' and latest.kind~='ignored' then result={status='pending',reason='not_missing'}
  else result={status='confirmed',receipt='fixture-receipt:'..a.key} end
  assert(db:run('INSERT INTO slack_effect(key,intent,body) VALUES(?,?,?)',{a.key,intent,json.encode(result)}))
  assert(db:exec('COMMIT'))
  if result.status=='confirmed' then f.sent[a.recipient]=(f.sent[a.recipient] or 0)+1 end
  if f.crash[a.recipient] then coroutine.yield('after_dispatch_before_ack') end
  if f.uncertain[a.recipient] then return nil,{status='uncertain'} end
  return result
 end
 add('send','write',conditional,function(a)
  local prior=row('slack_effect',a.key)
  if prior and json.decode(prior.body).status=='uncertain' then return nil,{status='uncertain'} end
  if not prior or prior.intent~=canonical(a.intent) then return nil,{status='uncertain'} end
  return json.decode(prior.body)
 end)
 add('model','read',function(a,execution)
  f.models=f.models+1
  assert(a.max_tokens<=128 and a.provider=='synthetic')
  assert(execution.ceilings.tokens==a.max_tokens,'provider ceiling enforced')
  if execution.ceilings.tokens<12 then return {classification='unknown',text=''},{usage={tokens=0}} end
  if a.task=='baseline' then
   local kind=a.observation.kind
   if kind=='ambiguous' and a.observation.text=='submitted yesterday' then kind='replied' end
   return {classification=kind},{usage={tokens=8}}
  end
  if a.task=='interpret' then return {classification=a.text=='submitted yesterday' and 'replied' or 'unknown'},{usage={tokens=8}} end
  assert(a.task=='report' and type(a.rows)=='table' and type(a.counts)=='table','report receives factual rows/counts')
  return {text='Synthetic report; structured rows are authoritative.'},{usage={tokens=12}}
 end)
 add('progress','write',function(a)
  assert(db:run('INSERT OR REPLACE INTO slack_progress(key,body) VALUES(?,?)',{a.key,json.encode(a)}));return {reference='progress:'..a.key}
 end)
 add('artifact','write',function(a)
  assert(db:run('INSERT OR REPLACE INTO slack_artifact(key,body) VALUES(?,?)',{a.target,json.encode(a.report)}));return {reference='artifact:'..a.target}
 end)
 local file=assert(io.open('examples/workflows/slack_followup.lua'));local source=file:read('*a');file:close()
 assert(workflow.register{id='slack.followup',version='1',source=source,durable='replay-v1',capabilities=pins})
 function f.config(cohort,period,expected)
  return {campaign='weekly',cohort=cohort,period=period,channel='fixture-channel',window={start=10,finish=20},now=21,
   expected=expected,report_target='fixture-report:'..cohort..':'..period,reminder='Please send your update',capabilities=roles,
   policy={ignored='remind',ambiguous='hold',max_model_calls=2,max_tokens=128},model_provider='synthetic'}
 end
 function f.run(c,auth)return assert(workflow.start('slack.followup',{authority=auth or authority,context={config=c}})) end
 function f.row(t,k)return row(t,k) end
 -- Deliberately model-heavy reference task, under isolated logical effect keys.
 -- Returns report, actually dispatched model calls, and its effective config.
 function f.baseline(config)
  local c=runstore.snapshot(config)
  c.campaign=c.campaign..':baseline';c.report_target=c.report_target..':baseline'
  c.policy.max_model_calls=#c.expected+1
  local before=f.models
  local function call(role,args)
   local outcome=cap.call(authority,roles[role],'1',args)
   assert(outcome.status=='succeeded',json.encode(outcome.error));return outcome.result
  end
  local function segment(value)return #value..':'..value end
  local key=segment(c.campaign)..segment(c.cohort)..segment(c.period)
  local expected=runstore.snapshot(c.expected);table.sort(expected)
  local intent={channel=c.channel,expected=expected,window=c.window,reminder=c.reminder,
   report_target=c.report_target,policy=c.policy,model_provider=c.model_provider,capabilities=c.capabilities}
  assert(call('bind',{key=key,intent=intent}).accepted)
  local function current(recipient)
   return call('source',{channel=c.channel,window=c.window,expected=expected,recipient=recipient,now=c.now})
  end
  local gathered=current()
  local report={campaign=c.campaign,cohort=c.cohort,period=c.period,channel=c.channel,window=c.window,
   observed_at=c.now,provenance=gathered.provenance,rows={},counts={},complete=false,receipts={}}
  for _,id in ipairs(expected) do
   local observation=gathered.available and gathered.people[id] or {kind='unavailable'}
   local decision=call('model',{task='baseline',provider=c.model_provider,observation=observation,max_tokens=c.policy.max_tokens})
   local row={recipient=id,status=decision.classification};report.rows[#report.rows+1]=row
   if row.status=='missing' or row.status=='ignored' and c.policy.ignored=='remind' then
    local fresh=current(id);local state=fresh.available and fresh.people[id]
    if not state then row.status='unavailable'
    elseif state.kind=='replied' or state.kind=='opted_out' then row.status=state.kind
    elseif state.kind~='missing' and not (state.kind=='ignored' and c.policy.ignored=='remind') then row.status=state.kind
    elseif not fresh.atomic_conditional_send then row.status='pending'
    else
     row.operation_id=key..segment(id);row.status='pending'
     call('progress',{key=key,report=report})
     local effect=call('send',{key=row.operation_id,intent=intent,recipient=id,channel=c.channel,
      window=c.window,revision=state.revision,reminder=c.reminder})
     row.status=effect.status;row.receipt=effect.receipt;row.reason=effect.reason
     if effect.receipt then report.receipts[#report.receipts+1]=effect.receipt end
    end
   end
  end
  report.complete=true
  for _,row in ipairs(report.rows) do
   report.counts[row.status]=(report.counts[row.status] or 0)+1
   if row.status~='confirmed' and row.status~='replied' and row.status~='opted_out' then report.complete=false end
  end
  report.narrative=call('model',{task='report',provider=c.model_provider,rows=report.rows,counts=report.counts,max_tokens=c.policy.max_tokens}).text
  report.model_calls=f.models-before
  report.progress=call('progress',{key=key,report=report}).reference
  report.artifact=call('artifact',{target=c.report_target,report=report}).reference
  return report,report.model_calls,c
 end
 return f
end
if rawget(_G,'SLACK_FIXTURE_ONLY') then return fixture end
local f=fixture()
local c=f.config('alpha','week-1',{'late','missing'})
f.late.late={kind='replied',revision='1'}
local first=f.run(c):snapshot()
assert(first.status=='succeeded',json.encode(first))
assert((f.sent.late or 0)==0,'late reply must prevent reminder')
assert(f.sent.missing==1,'missing person gets one reminder')
local duplicate=f.run(c):snapshot()
assert(duplicate.status=='succeeded' and f.sent.missing==1,'duplicate trigger must deduplicate')
print('workflow_slack: late reply and duplicate trigger passed')
local checks=3
local function check(v,label)assert(v,label);checks=checks+1 end
local function verify_report(c,r,expected)
 local seen,counts={},{}
 for _,row in ipairs(r.rows) do
  check(expected[row.recipient]==row.status,'independent expected status '..row.recipient..': '..row.status)
  check(not seen[row.recipient],'unique report recipient');seen[row.recipient]=true
  counts[row.status]=(counts[row.status] or 0)+1
 end
 for id in pairs(expected) do check(seen[id],'report includes '..id) end
 for status,n in pairs(counts) do check(r.counts[status]==n,'independent count '..status) end
 for status,n in pairs(r.counts) do check(counts[status]==n,'no extra reported count') end
 local stored=json.decode(assert(f.row('slack_artifact',c.report_target)).body)
 check(stored.campaign==c.campaign and stored.cohort==c.cohort and stored.period==c.period,'artifact scoped to current campaign/cohort/period')
 check(#stored.rows==#c.expected,'persisted report coverage')
 for _,row in ipairs(stored.rows) do check(expected[row.recipient]==row.status,'persisted factual status') end
 return r
end
local function report(c,expected)
 local r=f.run(c):snapshot();check(r.status=='succeeded' and r.verified,'verified artifact: '..c.cohort..' '..json.encode(r.error)..' '..r.status)
 return verify_report(c,r.result,expected)
end
-- Independently verify actual reminder increments AND durable receipt attribution
-- for each reference and workflow campaign, so baseline dedup cannot mask sends.
local function measured_task(c,expected,baseline)
 local before,sent=f.models,{}
 for _,id in ipairs(c.expected) do sent[id]=f.sent[id] or 0 end
 local result,actual,used
 if baseline then result,actual,used=f.baseline(c);verify_report(used,result,expected)
 else result=report(c,expected);actual=f.models-before;used=c end
 local function segment(value)return #value..':'..value end
 local key=segment(used.campaign)..segment(used.cohort)..segment(used.period)
 for _,id in ipairs(c.expected) do
  local should_send=expected[id]=='confirmed'
  check((f.sent[id] or 0)-sent[id]==(should_send and 1 or 0),'independent reminder decision '..used.campaign..' '..id)
  local effect=f.row('slack_effect',key..segment(id))
  check((effect~=nil)==should_send,'campaign-specific effect coverage '..id)
  if should_send then
   local receipt=json.decode(effect.body)
   check(receipt.status=='confirmed' and receipt.receipt=='fixture-receipt:'..key..segment(id),'campaign receipt identity')
  end
 end
 check(actual==f.models-before and result.model_calls==actual,'actual dispatched model count')
 return result,actual
end
f.world={ada={kind='replied',revision='1'},bea={kind='ambiguous',text='submitted yesterday',revision='1'},
 cy={kind='opted_out',revision='1'},dee={kind='ignored',revision='1'}}
local a=f.config('cohort-A','week-2',{'ada','bea','cy','dee','eli'})
local expected_a={ada='replied',bea='replied',cy='opted_out',dee='confirmed',eli='confirmed'}
local reference_a,baseline_a=measured_task(a,expected_a,true)
local ra,actual_a=measured_task(a,expected_a,false)
check(reference_a.complete==ra.complete,'cohort A equivalent completion')
local before
check(ra.complete and actual_a==2 and ra.model_calls==2,'cohort A actual bounded model calls')
f.world={fox={kind='ambiguous',text='maybe later',revision='1'},gia={kind='ignored',revision='1'},hal={kind='replied',revision='1'}}
local b=f.config('cohort-B','week-3',{'fox','gia','hal','ian'});b.policy.ignored='hold'
local expected_b={fox='ambiguous',gia='ignored',hal='replied',ian='confirmed'}
local reference_b,baseline_b=measured_task(b,expected_b,true)
local rb,actual_b=measured_task(b,expected_b,false)
check(reference_b.complete==rb.complete,'cohort B equivalent completion')
check(not rb.complete and actual_b==2 and rb.model_calls==2,'cohort B honest partial report')
check(not f.sent.fox and not f.sent.gia,'ambiguity and ignored hold cannot grant authority')
check(baseline_a==6 and baseline_b==5 and actual_a+actual_b==4,'measured baseline 11 versus workflow 4')
print('workflow_slack: measured actual synthetic model calls baseline='..(baseline_a+baseline_b)..' workflow='..(actual_a+actual_b))
-- Reply/opt-out arriving inside the send boundary suppresses the effect.
f.world={};f.race.racer={kind='replied',revision='2'};f.race.opt={kind='opted_out',revision='2'}
report(f.config('race','week-4',{'racer','opt'}),{racer='replied',opt='opted_out'})
check(not f.sent.racer and not f.sent.opt,'atomic race check suppresses obsolete sends')
-- Identical logical identity binds exact recipient/window/channel intent.
local conflict=f.config('alpha','week-1',{'late','missing','intruder'})
check(f.run(conflict):snapshot().status=='failed' and not f.sent.intruder,'changed cohort refuses stable key reuse')
conflict=f.config('alpha','week-1',{'late','missing'});conflict.window.finish=19
check(f.run(conflict):snapshot().status=='failed','changed window refuses stable key reuse')
f.unavailable=true
local unavailable=report(f.config('unavailable','week-5',{'nobody'}),{nobody='unavailable'})
check(not unavailable.complete and not f.sent.nobody,'unavailable source fails closed');f.unavailable=false
-- The persisted pending record is inspectable even if runstore halts on uncertainty.
f.uncertain.uncertain=true
local uncertain_config=f.config('uncertain','week-6',{'uncertain'})
local uncertain=f.run(uncertain_config):snapshot()
check(uncertain.status=='uncertain' and f.sent.uncertain==1,'uncertain acknowledgement is not failure proof')
local progress=assert(f.db:query('SELECT body FROM slack_progress WHERE body LIKE ?',{ '%"recipient":"uncertain"%' }))[1]
local pending=json.decode(assert(progress).body).report
check(pending.rows[1].status=='pending' and not pending.complete,'pending progress durable before dispatch')
local recovered=assert(runstore.resume(uncertain.id,{authority=f.authority})):snapshot()
check(recovered.status=='succeeded' and recovered.result.rows[1].status=='confirmed' and f.sent.uncertain==1,'authoritative reconciliation avoids repeat')
check(f.run(uncertain_config):snapshot().status=='succeeded' and f.sent.uncertain==1,'new trigger reuses reconciled logical receipt')
f.crash.interrupted=true
local crash=f.run(f.config('interrupted','week-7',{'interrupted'})):snapshot()
check(crash.status=='suspended' and f.sent.interrupted==1,'interrupted after durable dispatch')
local resumed=assert(runstore.resume(crash.id,{authority=f.authority})):snapshot()
check(resumed.status=='succeeded' and f.sent.interrupted==1,'durable resume reconciles interrupted effect')
-- Current authority remains effective at the send boundary and on recovery.
local denied=invoke.context({state={mode='auto',guards=false,tool_policy={['slack.fixture.send']='deny'}}},f.authority)
local denied_run=f.run(f.config('denied','week-8',{'denied'}),denied):snapshot()
check(denied_run.result and denied_run.result.rows[1].status=='denied' and not f.sent.denied,'denied send reported honestly')
local zero=f.config('zero','week-9',{'unknown'});zero.policy.max_model_calls=0
f.world.unknown={kind='ambiguous',text='submitted yesterday',revision='1'};before=f.models
report(zero,{unknown='ambiguous'});check(f.models==before,'zero budget makes no model calls')
-- No claimed atomic primitive means no reminder, even with a fresh read.
f.atomic=false
report(f.config('no-atomic','week-10',{'unsafe'}),{unsafe='pending'})
check(not f.sent.unsafe,'missing conditional primitive fails closed');f.atomic=true
local sparse=f.config('sparse','week-11',{'one'});sparse.expected={[1]='one',[3]='three'}
check(f.run(sparse):snapshot().status=='failed' and not f.sent.one,'sparse participant list rejected')
local mixed=f.config('mixed','week-11',{'one'});mixed.expected.extra='hidden'
check(f.run(mixed):snapshot().status=='failed','mixed participant list rejected')
local reordered=f.config('alpha','week-1',{'missing','late'});reordered.now=30
check(f.run(reordered):snapshot().status=='succeeded' and f.sent.missing==1,'later trigger and reordered cohort deduplicate')
f.uncertain.unresolved=true
local unresolved_config=f.config('unresolved','week-12',{'unresolved'})
local unresolved=f.run(unresolved_config):snapshot()
check(unresolved.status=='uncertain','unresolved effect halts')
assert(f.db:run('UPDATE slack_effect SET body=? WHERE body LIKE ?',{json.encode({status='uncertain'}),'%unresolved%'}))
local stopped=assert(runstore.resume(unresolved.id,{authority=f.authority})):snapshot()
check(stopped.status=='uncertain' and f.sent.unresolved==1,'unknown reconciliation cannot repeat send')
local pending_report=report(unresolved_config,{unresolved='uncertain'})
check(not pending_report.complete and f.sent.unresolved==1,'new trigger reports unresolved without repeat')
print('workflow_slack: '..checks..' checks passed')
