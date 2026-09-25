-- Real compiled/evaluated/promoted source with synthetic durable effects.
-- open{path, interrupt=true, monitor=true} reconstructs the same binding in a
-- fresh process. Effect receipts/counts live in the supplied SQLite database.
local M={}
local deployments={}
function M.open(o)
 local db=assert(require('db').open(assert(o.path)))
 assert(require('evidence').configure{db=db});assert(require('runstore').configure{db=db})
 assert(db:exec('CREATE TABLE IF NOT EXISTS trigger_fixture_effects(operation TEXT PRIMARY KEY,body TEXT NOT NULL)'))
 local json=require('json')
 local f=assert(io.open('tests/fixtures/process_bench/followup.lua','r'));local source=f:read('*a');f:close()
 local fixture=assert(load(source:gsub('bench%.send','trigger_fixture.send'),'@trigger-fixture-source'))()
 local registry=assert(require('learning.registry').open{db=db,project='process-bench',validate=function()return true,'fixture:authority'end,
  qualification={id='trigger-fixture',revision='1',check=function()return true,'fixture:runtime'end,
   profiles={['replay-v1']=function(_,_,_,ctx)return ctx.options.execution_profile=='replay-v1','fixture:durable-source-contract'end}}})
 if not registry:get('followup','1')then
  assert(registry:register('followup','1',fixture.candidate(false)))
  local report=assert(registry:evaluate('followup','1',fixture.dataset(false),fixture.policy()))
  assert(registry:activate('followup','1',report,{expected_generation=0}))
 end
 local cap=require('capability')
 local deployment=deployments[o.path]
 if not deployment then deployment={dispatches=0,reconciliations=0};deployments[o.path]=deployment end
 deployment.db=db;deployment.interrupt=o.interrupt
 if not cap.resolve('trigger_fixture.send','1')then
 assert(cap.register({id='trigger_fixture.send',version='1',effect='write',revision='trigger-fixture-send-v1',
  reconcile=function(_,execution)
   deployment.reconciliations=deployment.reconciliations+1
   local row=assert(deployment.db:query('SELECT body FROM trigger_fixture_effects WHERE operation=?',{execution.operation_id}))[1]
   return row and json.decode(row.body),{status=row and 'succeeded' or 'uncertain'}
  end},function(args,execution)
   deployment.dispatches=deployment.dispatches+1
   local value={recipient=args.recipient,text='All done'}
   assert(deployment.db:run('INSERT INTO trigger_fixture_effects VALUES(?,?)',{execution.operation_id,json.encode(value)}))
   if deployment.interrupt then coroutine.yield('fixture_ack_lost')end
   return value
  end))
 end
 local mon
 if o.monitor then
  mon=assert(require('learning.monitor').open{db=db,project='process-bench',registry=registry,
   assess=function(snapshot)return {variant='fixture',verifier={passed=snapshot.result and snapshot.result.text=='All done',ref='fixture:independent-result'},cost={value=1,unit='units'}}end,
   policy={cost_unit='units'}})
 end
 local invoke=require('invoke');local state={mode='auto',guards=false}
 local current=invoke.context{state=state}
 local queue={}
 local c=require('workflow_triggers').open{db=db,enqueue=function(job)queue[#queue+1]=job end,now=o.now}
 assert(c:bind{id='fixture',workflow='followup',project='process-bench',registry=registry,execution_profile='replay-v1',
  authority=function()return current end,context_provider={call_1_args={recipient='current-person'}},schedule={every=60},timezone='UTC',misfire='once'})
 return {db=db,registry=registry,coordinator=c,monitor=mon,queue=queue,
  count=function()return assert(db:query('SELECT COUNT(*) AS n FROM trigger_fixture_effects'))[1].n end,
  dispatch_count=function()return deployment.dispatches end,
  reconcile_count=function()return deployment.reconciliations end,
  replace_authority=function(a)current=a end,
  proof=function(_,_,_,ticket)return true,{owner=ticket.owner,monitor_owner=ticket.monitor.owner,ref='fixture:supervisor-stopped-exact-owner:'..ticket.owner}end}
end
return M
