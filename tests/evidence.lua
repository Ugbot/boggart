local evidence=require('evidence')
local db=assert(require('db').open(os.tmpname()))
assert(evidence.configure{db=db})
local id=assert(evidence.append{run_id='roundtrip',kind='fixture',payload={args={text='quoted "value"\nnext line'},nested={false,{answer=42}}}})
local roundtrip=evidence.read_run('roundtrip')[1]
assert(roundtrip.event_id==id and roundtrip.payload.args.text=='quoted "value"\nnext line')
print('evidence: roundtrip passed')
local passed=1
local function check(v,label) assert(v,label);passed=passed+1 end
local json=require('json')
local path=os.tmpname()
local a=assert(require('db').open(path));local b=assert(require('db').open(path))
assert(evidence.configure{db=a,inline_bytes=100,max_bytes=10000,secrets={'fixture-credential-239'}})
local secret='fixture-credential-239'
assert(evidence.append{run_id='secrets',kind='fixture',payload={password=secret,nested={text=secret..' '..string.rep('x',200)},usage={tokens=42,input_tokens=20,output_tokens=22}}})
local records=evidence.read_run('secrets');local art=evidence.artifact(records[1].payload.id)
check(art.password.evidence_marker=='redacted' and art.nested.text:find('[REDACTED]',1,true),'nested artifacts redacted before persistence')
check(art.usage.tokens==42 and art.usage.input_tokens==20 and art.usage.output_tokens==22,'accounting preserved')
for _,table_name in ipairs({'evidence_events','evidence_artifacts'}) do
  for _,row in ipairs(a:query('SELECT body FROM '..table_name)) do check(not row.body:find(secret,1,true),'raw storage contains no credential') end
end
assert(evidence.configure{inline_bytes=16384,secrets={'start','run'}})
local structural=evidence.begin('invocation',{run_id='r1',correlation_id='c1'},{run='start'})
check(structural.event_id and evidence.read_run('r1')[2].kind=='coverage.incomplete','schema fields and lifecycle kinds preserved')
check(evidence.finish(structural,{status='succeeded'}),'structural terminal saved')
check(#evidence.read_run('r1')==2,'terminal still correlated')
assert(evidence.configure{secrets={secret}})
local span=evidence.begin('invocation',{run_id='restart',correlation_id='pending'},{args={text='work'}})
local rows=assert(evidence.read_run('restart'));check(#rows==2 and rows[2].kind=='coverage.incomplete','live incomplete explicit')
assert(evidence.configure{db=b})
check(#evidence.read_run('restart')==2,'second connection sees same incomplete coverage')
check(#a:query("SELECT * FROM evidence_events WHERE run_id='restart'")==1,'read does not fabricate persisted terminal')
assert(evidence.finish(span,{status='succeeded'}));check(#evidence.read_run('restart')==2,'second writer terminal closes start')
local new_id=evidence.id('restart')
package.loaded.evidence=nil
local reopened=require('evidence');assert(reopened.configure{db=b})
check(reopened.id('restart')~=new_id,'fresh module restart-safe identifiers')
local unfinished=evidence.begin('invocation',{run_id='crashed',correlation_id='crashed-call'},{args={}})
a:close();b:close()
local reopened_db=assert(require('db').open(path));assert(reopened_db:exec('PRAGMA busy_timeout=0'));assert(reopened.configure{db=reopened_db})
check(reopened.read_run('crashed')[2].payload.reason=='terminal_not_observed','SQLite close/reopen preserves incomplete invocation')
package.loaded.evidence=evidence;assert(evidence.configure{db=reopened_db,secrets={secret}})
local workflow,cap,invoke=require('workflow'),require('capability'),require('invoke')
local authority=invoke.context{state={mode='auto',guards=false}}
local effects=0
assert(cap.register({id='evidence.fixture',version='1',effect='pure'},function(args)
  effects=effects+1;coroutine.yield('wait');return {text=args.text,password=secret}, {usage={tokens=7}}
end))
assert(workflow.register{id='evidence.flow',version='1',capabilities={['evidence.fixture']='1'},run=function(ctx)
  return ctx:step('outer',function()
    local v=ctx:resolve('value');ctx:observe('branch',true,{input='value'})
    local o=ctx:call('evidence.fixture',{text=v,secret=secret});return o.result
  end)
end,verify=function(_,value)return value.text~=nil end})
local h1=assert(workflow.start('evidence.flow',{authority=authority,context={value='one'}}))
local h2=assert(workflow.start('evidence.flow',{authority=authority,context={value='two'}}))
local s2=h2:resume();local s1=h1:resume()
for _,s in ipairs({s1,s2}) do
  check(s.status=='succeeded' and s.verified,'interleaved workflow verified')
  local found={}
  for _,e in ipairs(assert(evidence.read_run(s.id))) do
    check(e.run_id==s.id and e.kind~='coverage.incomplete','run reconstruction isolated and complete')
    found[e.kind]=e
  end
  check(found['invocation.start'].parent_id==s.steps[1].id,'invocation parent is actual step')
  check(found['context.terminal'].payload.value==s.result.text,'concrete context snapshot captured')
  check(found['invocation.terminal'].payload.receipt.usage.tokens==7,'capability usage captured')
  check(found['workflow.terminal'].payload.verified and found['observation.branch'].payload.value,'verifier and annotated branch captured')
end
-- Storage admission failure cannot dispatch an effect.
local blocker=assert(require('db').open(path));assert(blocker:exec('BEGIN IMMEDIATE'))
local before=effects
local outcome=cap.call(authority,'evidence.fixture','1',{})
local value,err,receipt=outcome.result,outcome.error,outcome.receipt
check(value==nil and err.code=='evidence_unavailable' and effects==before and not receipt.dispatched,'locked evidence fails closed before dispatch')
check(receipt.evidence.coverage=='incomplete' and evidence.status().failures>0,'failure surfaced in receipt and health')
assert(blocker:exec('ROLLBACK'));blocker:close()
-- Explicitly disabled capture remains visible while ordinary execution is allowed.
evidence.configure{enabled=false}
value,err,receipt=invoke.call(authority,'missing.fixture',{})
check(err.code=='tool_not_found' and receipt.evidence.error=='evidence_disabled','disabled capture explicit')
evidence.configure{enabled=true}
local start=evidence.now();local x=0;for i=1,100000 do x=x+i end
check(evidence.now()>start,'monotonic hrtime advances during CPU-only Lua')
local tick=100
evidence.configure{monotonic=function()tick=tick+10;return tick end,wall=function()return 123 end}
local timed=evidence.begin('step',{run_id='timed',correlation_id='t1'},{})
evidence.finish(timed,{})
rows=evidence.read_run('timed')
check(rows[1].timestamp==123 and rows[2].payload.duration_ns==10,'separate deterministic clocks')
evidence.configure{monotonic=require('uv').hrtime,wall=os.time}
check(evidence.redact(setmetatable({secret=secret},{})).evidence_marker=='unavailable','opaque handles not inspected')
check(evidence.redact(string.rep('x',10001)).evidence_marker=='truncated','oversized scalar marked')
-- A dropped terminal leaves durable incomplete coverage and an explicit receipt.
local terminal_blocker=assert(require('db').open(path))
assert(cap.register({id='evidence.dropterminal',version='1',effect='pure'},function()
  assert(terminal_blocker:exec('BEGIN IMMEDIATE'));return 'ran'
end))
local dropped=cap.call(authority,'evidence.dropterminal','1',{})
check(dropped.status=='succeeded' and dropped.receipt.evidence.coverage=='incomplete','effect success distinguished from terminal capture failure')
assert(terminal_blocker:exec('ROLLBACK'));terminal_blocker:close()
rows=evidence.read_run(dropped.receipt.evidence.run_id)
check(rows[#rows].kind=='coverage.incomplete','failed terminal remains incomplete on durable read')
assert(cap.register({id='evidence.child',version='1',effect='pure'},function()return 9 end))
assert(workflow.register{id='evidence.childflow',version='1',capabilities={['evidence.child']='1'},source=[[
return function(ctx)
  return ctx:step('parent',function()
    local co=coroutine.create(function()return ctx:call('evidence.child',{}).result end)
    local ok,result=coroutine.resume(co);assert(ok);return result
  end)
end
]]})
local child=assert(workflow.start('evidence.childflow',{authority=authority})):snapshot()
check(child.result==9,'safe child workflow executes')
local child_call,thread
for _,e in ipairs(evidence.read_run(child.id)) do
  if e.kind=='invocation.start' then child_call=e end
  if e.kind=='workflow.thread' and e.parent_id==child.steps[1].id then thread=e end
end
check(thread and child_call.parent_id==thread.step_id,'child coroutine retains observed parent step')
local learned=evidence.redact({password='labelled-credential-808',echo='labelled-credential-808'})
check(learned.echo=='[REDACTED]','labelled secret learned before sibling snapshot')
-- Observer exceptions do not erase the already captured invocation terminal.
local events=require('events')
local observer=events.on('tool:after',function()error('fixture observer failure')end)
local observed=cap.call(authority,'evidence.child','1',{})
events.off(observer)
rows=evidence.read_run(observed.receipt.evidence.run_id)
check(rows[#rows].kind=='invocation.terminal','terminal persisted independently of observer failure')
assert(workflow.register{id='evidence.budget',version='1',source=[[
return function(ctx) while true do ctx:observe('branch',true) end end
]]})
local budgeted=assert(workflow.start('evidence.budget',{authority=authority,instructions=10000})):snapshot()
check(budgeted.status=='failed' and budgeted.error.code=='workflow_budget','short evidence writes cannot starve workflow budget')
-- Force the public alias to be visited before its sensitive alias.
local alias_secret='alias-credential-991'
local candidate
for i=1,1000 do
  local shared={value=alias_secret};local benign='public'..i
  local v={[benign]=shared,password=shared}
  if next(v)==benign then candidate=v;break end
end
assert(candidate,'fixture must force benign alias first')
for _,inline in ipairs({16384,1}) do
  evidence.configure{inline_bytes=inline}
  assert(evidence.append{run_id='alias-regression',kind='fixture',payload=candidate})
end
for _,name in ipairs({'evidence_events','evidence_artifacts'}) do
  for _,row in ipairs(reopened_db:query('SELECT body FROM '..name)) do
    check(not row.body:find(alias_secret,1,true),'shared-table credential absent from durable '..name)
  end
end
evidence.configure{inline_bytes=16384,max_bytes=8}
local omitted=evidence.redact({['long-unrepresentable-key']='value'})
check(omitted.evidence_marker=='partial' and omitted.omissions.key_truncated==1,'oversized key explicitly omitted')
evidence.configure{max_bytes=10000,secrets={'collision-one','collision-two'}}
omitted=evidence.redact({['collision-one']=1,['collision-two']=2,_evidence_omissions='user content',[{}]='opaque key'})
check(omitted.omissions.key_collision==1 and omitted.omissions.unsupported_key==1 and omitted.value._evidence_omissions=='user content','collisions and unsupported keys cannot overwrite omission metadata')
assert(evidence.append{run_id='omissions',kind='fixture',payload={['collision-one']=1,['collision-two']=2}})
check(evidence.read_run('omissions')[1].payload.omissions.key_collision==1,'collision coverage persists')
check(evidence.redact({[1]='number',['1']='string'}).omissions.key_collision==1,'JSON object key stringification collision explicit')
evidence.configure{secrets={}}
-- Interleaved ordinary invocations, including a safe child coroutine, share
-- their actual parent run without borrowing another coroutine's active run.
local children={}
assert(cap.register({id='evidence.nested-inner',version='1',effect='pure'},function(args)return args.tag end))
assert(cap.register({id='evidence.nested-outer',version='1',effect='pure'},function(args)
  coroutine.yield('outer waiting')
  children[args.tag]=cap.call(authority,'evidence.nested-inner','1',{tag=args.tag})
  local safe=require('tools').tool_env().coroutine
  local child=safe.create(function()return cap.call(authority,'evidence.nested-inner','1',{tag=args.tag..'-child'})end)
  local ok,result=safe.resume(child);assert(ok);children[args.tag..'-child']=result
  return args.tag
end))
local c1=coroutine.create(function()return cap.call(authority,'evidence.nested-outer','1',{tag='first'})end)
local c2=coroutine.create(function()return cap.call(authority,'evidence.nested-outer','1',{tag='second'})end)
assert(coroutine.resume(c1));assert(coroutine.resume(c2))
local ok2,o2=coroutine.resume(c2);local ok1,o1=coroutine.resume(c1);assert(ok1 and ok2)
check(o1.receipt.evidence.run_id~=o2.receipt.evidence.run_id,'interleaved nonworkflow roots remain separate')
for i,o in ipairs({o1,o2}) do
  local tag=i==1 and 'first' or 'second'
  check(children[tag].receipt.evidence.run_id==o.receipt.evidence.run_id and children[tag..'-child'].receipt.evidence.run_id==o.receipt.evidence.run_id,'nested and safe-child run inheritance')
  local starts=0
  for _,e in ipairs(evidence.read_run(o.receipt.evidence.run_id)) do
    if e.kind=='invocation.start' then
      starts=starts+1
      if e.correlation_id~=o.receipt.invocation_id then check(e.parent_id==o.receipt.invocation_id,'nested invocation actual parent') end
    end
  end
  check(starts==3,'parent run reconstructs both children')
end
-- Capacity failures are sticky and cannot be cleared by resetting configured
-- literals. Use fresh module instances so deliberate poison stays isolated.
local function fresh_evidence()
  package.loaded.evidence=nil;local isolated=require('evidence');package.loaded.evidence=evidence
  isolated.configure{db=reopened_db};return isolated
end
local key_alias=fresh_evidence()
local key_shared={['credential-in-key-554']=true}
local key_snapshot=key_alias.redact({public=key_shared,password=key_shared})
check(not json.encode(key_snapshot):find('credential-in-key-554',1,true),'sensitive aliases protect string keys as well as values')
local bounded=fresh_evidence()
for i=1,256 do assert(bounded.append{run_id='capacity',kind='fixture',payload={password='unique-credential-'..i}}) end
local before_rows=#reopened_db:query("SELECT * FROM evidence_events WHERE run_id='capacity'")
local refused,reason=bounded.append{run_id='capacity',kind='fixture',payload={password='capacity-overflow-credential'}}
check(not refused and reason=='evidence_capture_failed' and bounded.status().learned_secrets==256,'learned count bounded and capture refused')
bounded.configure{secrets={}}
check(not bounded.append{run_id='capacity',kind='fixture',payload={echo='capacity-overflow-credential'}},'capacity poison cannot silently reset or expose later echo')
check(#reopened_db:query("SELECT * FROM evidence_events WHERE run_id='capacity'")==before_rows,'capacity failure writes no partial observation')
local large=fresh_evidence()
check(not large.append{run_id='large-secret',kind='fixture',payload={password=string.rep('s',8193)}},'single oversized credential fails closed before scanning')
check(large.status().learned_bytes==0 and large.status().redaction_blocked,'oversized credential not retained and poison visible')
local total=fresh_evidence()
for i=1,8 do total.redact({password=tostring(i)..string.rep('s',8191)}) end
check(not pcall(total.redact,{password='one-more-secret'}) and total.status().learned_bytes==65536,'total learned credential bytes bounded')
local costly=fresh_evidence();costly.configure{secrets={string.rep('x',100)}}
check(not costly.append{run_id='costly',kind='fixture',payload={text=string.rep('y',200000)}},'literal matching work budget fails closed')
check(costly.status().redaction_blocked,'work capacity poison visible')
reopened_db:close();os.remove(path)
print('evidence: '..passed..' checks passed')
