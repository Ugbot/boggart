package.path='lua/?.lua;lua/?/init.lua;'..package.path
local T=require('workflow_triggers')
local n=0
local function check(v,m)assert(v,m);n=n+1 end
local fixture=dofile('tests/fixtures/process_bench/followup.lua')
local db=assert(require('db').open(os.tmpname()))
local registry=assert(require('learning.registry').open{db=db,project='process-bench',validate=function()return true,'fixture:authority'end,
 qualification={id='fixture',revision='1',check=function()return true,'fixture:runtime'end,
 profiles={['replay-v1']=function(candidate,report,phase,ctx) return ctx.options.execution_profile=='replay-v1','fixture:replay-v1' end}}})
assert(registry:register('followup','1',fixture.candidate(false)))
local report=assert(registry:evaluate('followup','1',fixture.dataset(false),fixture.policy()))
assert(registry:activate('followup','1',report,{expected_generation=0}))
local state={mode='auto',guards=false};local effects=0;local lose_ack=false;local remote={}
assert(require('capability').register({id='bench.send',version='1',effect='write',revision='fixture-send-v1',
 reconcile=function(args,execution)return remote[execution.operation_id],{status=remote[execution.operation_id] and 'succeeded' or 'uncertain'}end},
 function(args,execution)effects=effects+1;local value={recipient=args.recipient,text='All done'}
 if lose_ack then remote[execution.operation_id]=value;coroutine.yield('ack_lost')end;return value end))
local now=1700000000;local queue={}
local coordinator=T.open{db=db,now=function()return now end,enqueue=function(job)queue[#queue+1]=job end}
local spec={id='followups',workflow='followup',project='process-bench',registry=registry,
 authority=function()return require('invoke').context{state=state}end,
 context_provider={call_1_args={recipient='current-person'}},schedule={every=60},timezone='UTC',misfire='once'}
assert(coordinator:bind(spec))
check(coordinator:preview('followups').effects==false and effects==0,'preview has no provider or effects')
local h=assert(coordinator:run('followups','named','named-1'))
check(h:snapshot().status=='succeeded' and effects==1,'named executes real promoted source')
local b=assert(coordinator:run('followups','button','button-1'))
check(b:snapshot().workflow.version==h:snapshot().workflow.version and effects==2,'button shares registry pin')
now=now+61;check(coordinator:tick(now)==1,'timer enqueues one occurrence')
check(effects==2,'timer does not execute inline')
local timer=assert(coordinator:execute(queue[#queue]));check(timer:snapshot().status=='succeeded' and effects==3,'timer executes same current registry')
check(not coordinator:claim('followups',tostring(1700000060),'timer'),'duplicate occurrence refused')
check(not coordinator:cancel('followups','named-1'),'cancel cannot rewrite terminal success')
local second=T.open{db=db,now=function()return now end};assert(second:bind(spec))
check(not second:claim('followups',tostring(1700000060),'timer'),'restart shares durable deduplication')
local pending=assert(coordinator:enqueue('followups','revoked','hook'))
state.policy_scopes={{id='revoked',revision=1,capabilities={allow={}}}}
local denied=assert(coordinator:execute(pending))
check(denied:snapshot().status~='succeeded' and effects==3,'post-enqueue revocation denies actual capability')
state.policy_scopes=nil
assert(coordinator:pause('followups'))
check(not coordinator:run('followups','button','paused'),'paused binding refuses admission')
local Z=require('trigger_timezone')
-- Independently specified epoch values: New York 2024 gap and fold.
check(Z.next('02:30','America/New_York',1710046800)==1710138600,'DST spring gap skips absent civil minute')
check(Z.next('01:30','America/New_York',1730606400)==1730611800,'DST fold selects first physical instant')
check(Z.next('01:30','America/New_York',1730611800)==1730701800,'DST second folded minute does not duplicate')
check(Z.next('09:00','UTC',1700000000)==1700038800,'UTC conversion independent of local timezone')
local A=require('trigger_authority');local invoke=require('invoke')
A.register('client',{mode='auto',guards=false,policy_scopes={{id='client',revision=1,capabilities={allow={'bench.read'}}}}})
local event=A.attach({},'client');local propagated=A.propagate(event,{})
local value,why=A.execute(propagated,function()return require('capability').call(nil,'bench.send','1',{recipient='forbidden'})end)
check(value.status~='succeeded' and effects==3,'queued narrowed authority refuses write: '..require('json').encode(value))
-- A fresh opaque authority replaces the host binding during context resolution.
local current_auth=require('invoke').context{state={mode='auto',guards=false}}
assert(coordinator:bind{id='replacement',workflow='followup',project='process-bench',registry=registry,
 authority=function()return current_auth end,
 context_provider={call_1_args=function()
  current_auth=require('invoke').context{state={mode='auto',guards=false},allow={}}
  return {recipient='current-person'}
 end}})
local replacement=assert(coordinator:run('replacement','named','replacement-1'))
check(replacement:snapshot().status~='succeeded' and effects==3,'provider replacement revokes subsequent write')
assert(coordinator:pause('followups',false))
local overlap=assert(coordinator:enqueue('followups','overlap-1','named'))
check(not coordinator:enqueue('followups','overlap-2','named'),'one outstanding occurrence enforces overlap')
overlap.id='replacement';overlap.occurrence='forged'
local original=assert(coordinator:execute(overlap))
check(original:snapshot().status=='succeeded' and effects==4,'queue fields cannot retarget private occurrence')
local missing=T.open{db=db}
check(missing:status('followups').available==false and not missing:claim('followups','missing','timer'),'restart lacks executable authority until host rebind')
local before=effects
A.register('allowed-hook',{mode='auto',guards=false})
assert(coordinator:bind{id='hooked',workflow='followup',project='process-bench',registry=registry,
 authority=function()return require('invoke').context{state={mode='auto',guards=false}}end,
 context_provider={call_1_args={recipient='current-person'}},on='hook:brain35'})
local hookevent=A.attach({},'allowed-hook')
bog.events.emit('hook:brain35',hookevent)
check(effects==before,'hook callback only enqueues')
A.revoke('allowed-hook')
local revoked=coordinator:execute(queue[#queue])
check((not revoked or revoked:snapshot().status~='succeeded') and effects==before,'post-hook revocation preserves origin authority')
check(Z.next('09:00','Asia/Kathmandu',1790035200)==1790046900,'fixed-footer timezone remains valid after last transition')
assert(require('evidence').configure{db=db})
assert(require('runstore').configure{db=db})
local durable_spec={id='durable',workflow='followup',project='process-bench',registry=registry,
 execution_profile='replay-v1',authority=function()return require('invoke').context{state={mode='auto',guards=false}}end,
 context_provider={call_1_args={recipient='current-person'}}}
assert(coordinator:bind(durable_spec))
lose_ack=true;local before_durable=effects
local lost,why=coordinator:run('durable','timer','durable-1')
assert(lost,why and why.code)
check(lost:snapshot().status=='suspended' and effects==before_durable+1,'learned replay-v1 suspends after actual effect')
check(not coordinator:recover('durable','durable-1'),'recovery requires explicit executor quiescence')
local reopened=T.open{db=db};assert(reopened:bind(durable_spec))
local restored,restore_error=reopened:recover('durable','durable-1',function(_,_,_,ticket)return true,{owner=ticket.owner,monitor_owner=ticket.monitor.owner,ref='fixture:executor-will-not-resume'}end)
assert(restored,restore_error and require('json').encode(restore_error))
check(restored:snapshot().status=='succeeded' and effects==before_durable+1,'learned pinned recovery reconciles without duplicate effect')
check(not reopened:recover('durable','durable-1',function(_,_,_,ticket)return true,{owner=ticket.owner,monitor_owner=ticket.monitor.owner,ref='fixture'}end),'terminal occurrence cannot recover again')
io.write('workflow_triggers: ',n,' passed\n')
