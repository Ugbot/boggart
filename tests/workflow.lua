local workflow=require('workflow')
assert(workflow.hash('')=='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
assert(workflow.hash('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
assert(workflow.hash(string.rep('a',1000000))=='cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0')
print('workflow: SHA-256 vectors passed')
local invoke,cap=require('invoke'),require('capability')
local passed=3
local function check(v,m) assert(v,m);passed=passed+1 end
local auth=invoke.context{state={mode='auto',guards=false}}
local function start(id,opts) opts=opts or {};opts.authority=auth;return assert(workflow.start(id,opts)) end
local function register(d) return assert(workflow.register(d)) end
local source=[[return {run=function(ctx) local v=ctx:resolve('x');ctx:yield('paused');return v,ctx:resolve('x') end,verify=function() return true end}]]
local desc={id='versioned',version='1',source=source}
local ident=register(desc)
check(ident.source_kind=='lua_source' and ident.source_hash==workflow.hash(source),'exact source hash')
desc.source='return function() return 99 end';ident.source_hash='mutated'
local provider={revision='1',resolve=function()return 10 end}
local context_map={x=provider}
local run=start('versioned',{context=context_map})
check(run:snapshot().status=='suspended','source suspended')
provider.resolve=function()return 90 end;provider.revision='2';context_map.x=100
register{id='versioned',version='2',source='return function() return 2 end'}
assert(workflow.activate('versioned','2'))
check(start('versioned'):snapshot().result==2,'new run activates v2')
local result=run:resume()
check(result.status=='succeeded' and result.result==10 and result.verified,'v1 stays pinned')
check(result.manifest.providers.injected.x.revision=='1','provider revision pin')
check(workflow.resolve('versioned','1').source_hash==workflow.hash(source),'registration copies source')
check(not workflow.register{id='mismatch',version='1',source=source,source_hash='bad'},'source hash mismatch rejects')
check(not workflow.register(setmetatable({id='meta',version='1',source=source},{})),'descriptor metatable rejected')
check(not workflow.register{id='meta',version='1',source=source,capabilities=setmetatable({},{})},'dependency metatable rejected')
check(not workflow.register{id='versioned',version='1',source=source},'immutable duplicate')
local calls=0
for _,v in ipairs({'1','2'}) do assert(cap.register({id='workflow.fixture',version=v,effect='pure'},function()calls=calls+1;return v end)) end
local pins={['workflow.fixture']='1'}
register{id='pins',version='1',capabilities=pins,run=function(ctx)ctx:yield();return ctx:call('workflow.fixture',{}).result end}
run=start('pins');pins['workflow.fixture']='2'
check(run:resume().result=='1','capability pin stable across suspension')
check(run:snapshot().invocations[1].receipt.invocation_id~=nil,'invocation receipt retained')
register{id='loops',version='1',run=function(ctx)
 for i=1,3 do ctx:step('loop',function()ctx:step('inside',function()return i end)end) end
 return false
end}
result=start('loops'):snapshot()
local ids={};for _,step in ipairs(result.steps) do check(not ids[step.id],'occurrences unique');ids[step.id]=true end
check(#result.steps==6 and result.result==false and result.status=='succeeded' and not result.verified,'false and unverified success')
register{id='child',version='1',run=function(ctx)return ctx:step('child',function()return ctx:resolve('x') end)end}
register{id='parent',version='1',workflows={child='1'},run=function(ctx)return ctx:workflow('child')end}
check(start('parent',{context={x=33}}):snapshot().result==33,'nested workflow shares current injection')
register{id='missing',version='1',run=function(ctx)ctx:resolve('absent');return 'ignored' end,verify=function()return true end}
check(start('missing'):snapshot().status=='failed','ignored required resolution cannot succeed')
register{id='optional',version='1',run=function(ctx)ctx:resolve('absent',nil,{required=false});return 1 end}
check(start('optional'):snapshot().status=='succeeded','explicit optional resolution')
assert(cap.register({id='workflow.fail',version='1',effect='pure'},function()return nil,{status='failed',error={code='unavailable'}} end))
assert(cap.register({id='workflow.uncertain',version='1',effect='pure'},function()return nil,{status='uncertain',error={code='uncertain'}} end))
for _,status in ipairs({'fail','uncertain'}) do
 register{id=status,version='1',capabilities={['workflow.'..status]='1'},run=function(ctx)ctx:step('attempt',function()ctx:call('workflow.'..status,{})end);return true end,verify=function()return true end}
 result=start(status):snapshot();check(result.status==(status=='fail' and 'failed' or status) and not result.verified,'required capability status sticky')
end
register{id='caught',version='1',run=function(ctx)pcall(function()ctx:step('throws',function()error('secret')end)end);return true end}
result=start('caught'):snapshot();check(result.status=='failed' and not require('json').encode(result):find('secret',1,true),'caught step error remains redacted failure')
register{id='verify',version='1',run=function()return true end,verify=function()return false end}
check(start('verify'):snapshot().error.code=='workflow_verification_failed','verifier failure sticky')
register{id='cancel',version='1',run=function(ctx)ctx:step('wait',function()ctx:yield()end);calls=calls+1 end}
run=start('cancel');local before=calls
check(run:cancel().status=='cancelled' and run:resume().status=='cancelled' and calls==before,'cancel terminal no resumed effects')
register{id='budget',version='1',source='return function() while true do end end'}
check(start('budget',{instructions=10000}):snapshot().error.code=='workflow_budget','CPU runaway budget')
register{id='sandbox',version='1',source='return function() return require == nil and debug == nil and io == nil and tools.register == nil end'}
check(start('sandbox'):snapshot().result==true,'source restricted environment')
print('workflow: '..passed..' checks passed')
-- Slack-shaped local fixture: no network or account, different Lua branches.
local model_calls,reports=0,{}
assert(cap.register({id='fixture.slack.replies',version='1',effect='pure'},function(args)return args.replies end))
assert(cap.register({id='fixture.model.report',version='1',effect='pure'},function(args)model_calls=model_calls+1;return 'Follow up: '..table.concat(args.missing,', ') end))
assert(cap.register({id='fixture.report.record',version='1',effect='pure'},function(args)reports[#reports+1]=args;return {recorded=true,report=args.report} end))
local example=assert(io.open('examples/workflows/slack_followup.lua','rb'));local body=example:read('a');example:close()
register{id='slack',version='1',source=body,capabilities={['fixture.slack.replies']='1',['fixture.model.report']='1',['fixture.report.record']='1'}}
local first=start('slack',{context={expected_people={'Ada','Ben'},query={replies={'Ada'}}}}):snapshot()
local second=start('slack',{context={expected_people=function()return {'Ada','Ben'}end,query={replies={'Ada','Ben'}}}}):snapshot()
check(first.verified and second.verified and model_calls==1 and #reports==2,'Slack branches verified with optional fake model')
check(first.result.report=='Follow up: Ben' and second.result.report=='Everyone has replied.','Slack reports reflect current input')
check(first.workflow.source_hash==second.workflow.source_hash,'same Lua source for both branches')
-- Provider implementation is copied while its external data remains fresh.
local external=1
provider={revision='p1',resolve=function()return external end}
register{id='provider-pin',version='1',run=function(ctx)ctx:yield();return ctx:resolve('x')end}
run=start('provider-pin',{context={x=provider}});provider.resolve=function()return 90 end;external=2
check(run:resume().result==2,'pinned provider reads fresh external data')
register{id='provider-failure',version='1',capabilities={['workflow.fail']='1'},run=function(ctx)return ctx:resolve('x')end}
check(start('provider-failure',{context={x=function(ctx)ctx:call('workflow.fail',{});return true end}}):snapshot().status=='failed','ignored failed provider call is sticky')
print('workflow final: '..passed..' checks passed')
local events=require('events')
local observed
assert(cap.register({id='workflow.correlation',version='1',effect='pure'},function()observed=workflow.current();return true end))
register{id='correlation',version='1',capabilities={['workflow.correlation']='1'},run=function(ctx)return ctx:step('site',function()return ctx:call('workflow.correlation',{}).result end)end}
result=start('correlation'):snapshot()
check(observed.run_id==result.id and observed.step_id==result.steps[1].id and observed.attempt==1,'read-only current correlation in capability dispatch')
check(workflow.current()==nil,'correlation cleared outside run')
local denied=invoke.context{state={mode='auto',guards=false,tool_policy={['workflow.correlation']='deny'}}}
local denied_result=invoke.with_context(denied,function()return start('correlation'):snapshot()end)
check(denied_result.status=='failed' and denied_result.invocations[1].receipt.dispatched==false,'ancestor policy survives workflow authority')
assert(cap.register({id='workflow.wait',version='1',effect='pure'},function()coroutine.yield('pending');return 'done' end))
register{id='inflight',version='1',capabilities={['workflow.wait']='1'},run=function(ctx)return ctx:call('workflow.wait',{})end}
run=start('inflight');result=run:cancel()
check(result.status=='cancelled' and result.effects_incomplete and result.invocations[1].status=='incomplete','cancel does not claim remote dispatch stopped')
local returned=run:resume();check(returned.status=='cancelled','incomplete cancelled run cannot resume')
register{id='verify-throw',version='1',run=function()return true end,verify=function()error('private')end}
check(start('verify-throw'):snapshot().status=='failed','throwing verifier cannot succeed')
register{id='child-budget',version='1',source='return function() local co=coroutine.create(function() while true do end end);coroutine.resume(co);return true end'}
check(start('child-budget',{instructions=10000}):snapshot().status=='failed','child coroutine budget cannot be swallowed into success')
print('workflow complete: '..passed..' checks passed')

check(not workflow.start('budget',{instructions=0/0,defer=true}),'NaN budget rejects')
register{id='requests',version='1',run=function(ctx) local f=function()end;return ctx:resolve('x',false)==false and ctx:resolve('x',42)==42 and ctx:resolve('x',f)==f end}
check(start('requests',{context={x=function(_,r)return r end}}):snapshot().result==true,'scalar and closure request fidelity')
print('workflow final checks: '..passed)

register{id='retained',version='1',capabilities={['workflow.fixture']='1'},run=function(ctx)return function()return ctx:call('workflow.fixture',{})end end}
result=start('retained'):snapshot();before=calls
check(not pcall(result.result) and calls==before,'retained context cannot extend terminal run')
print('workflow total: '..passed..' checks passed')

-- Review regressions: optionality never proves an uncertain effect absent.
for _,variant in ipairs({'optional','nil_error','throw','cached_failed','cached_uncertain','composed_cached'}) do
 local cap_id=(variant=='cached_failed' or variant=='composed_cached') and 'workflow.fail' or 'workflow.uncertain'
 local provider={cache='run',revision='1',resolve=function(ctx)
  ctx:call(cap_id,{})
  if variant=='nil_error' then return nil,'private provider failure' end
  if variant=='throw' then error('private provider failure') end
  return true
 end}
 local values={x=provider}
 if variant=='composed_cached' then
  values.child=provider;values.x={cache='run',resolve=function(ctx)return ctx:resolve('child')end}
 end
 register{id='review.'..variant,version='1',capabilities={[cap_id]='1'},run=function(ctx)
  ctx:resolve('x',{}, {required=false})
  if variant:find('cached') then ctx:resolve('x',{}) end
  return true
 end,verify=function()return true end}
 result=start('review.'..variant,{context=values}):snapshot()
 local expected=(variant=='cached_failed' or variant=='composed_cached') and 'failed' or 'uncertain'
 check(result.status==expected and not result.verified,'provider review status '..variant)
 if variant=='nil_error' or variant=='throw' then
  check(result.resolutions[1].provenance.capabilities[1].status=='uncertain','failure-path uncertainty retained '..variant)
 end
end
local legacy_calls=0
local tools=require('tools')
tools.registry['workflow.review.legacy']={description='fixture',run=function()legacy_calls=legacy_calls+1;return 'old' end}
register{id='review.legacy',version='1',source="return {run=function(ctx)ctx:yield();pcall(function()tools.call('workflow.review.legacy',{})end);return true end,verify=function()return true end}"}
run=start('review.legacy')
tools.registry['workflow.review.legacy']={description='fixture',run=function()legacy_calls=legacy_calls+1;return 'replacement' end}
result=run:resume()
check(result.status=='failed' and result.error.code=='workflow_unversioned_effect' and legacy_calls==0,'suspended source cannot dispatch replaced unpinned legacy tool')
tools.registry['workflow.review.legacy']=nil
for index,expression in ipairs({"sys.cwd()","gold.fs.read('unused')","events.notify('unused')","tools.names()","os.getenv('PATH')"}) do
 register{id='review.route.'..index,version='1',source='return function() pcall(function() '..expression..' end);return true end'}
 check(start('review.route.'..index):snapshot().status=='failed','unpinned source route refused '..index)
end
register{id='collision',version='1',defaults={kind={revision='default-kind',resolve=function()return true end},revision={revision='default-revision',resolve=function()return true end}},run=function()return true end}
result=start('collision',{context={['9:collision1:1']={revision='injected-revision',resolve=function()return true end}}}):snapshot()
check(result.manifest.providers.injected['9:collision1:1'].kind=='trusted_host' and result.manifest.providers.injected['9:collision1:1'].revision=='injected-revision','provider namespaces cannot overwrite injection descriptor')
check(result.manifest.providers.occurrences['9:collision1:1'].defaults.kind.revision=='default-kind','default provider namespace retained')
register{id='review.nested',version='1',workflows={child='1'},run=function(ctx)
 ctx:workflow('child',{context={x={revision='a',resolve=function()return 1 end}}})
 return ctx:workflow('child',{context={x={revision='b',resolve=function()return 2 end}}})
end}
result=start('review.nested'):snapshot()
local nested_revisions={}
for _,entry in pairs(result.manifest.providers.occurrences) do if entry.workflow_id=='child' then nested_revisions[entry.injected.x.revision]=true end end
check(nested_revisions.a and nested_revisions.b,'nested injection provenance is occurrence scoped')
print('workflow reviewed: '..passed..' checks passed')

register{id='review.abrupt',version='1',capabilities={['workflow.uncertain']='1'},run=function(ctx)return ctx:resolve('x')end,verify=function()return true end}
result=start('review.abrupt',{instructions=30000,context={x=function(ctx)ctx:call('workflow.uncertain',{});while true do end end}}):snapshot()
check(result.status=='failed' and result.effects_incomplete and not result.verified and result.resolutions[1].status=='incomplete','budget-aborted provider preserves explicit unresolved effect record')
print('workflow reviewed final: '..passed..' checks passed')

-- Source work, unlike trusted host workflows, enters bounded native resumes.
local source_limit=tools.LIMITS.memory_kb;tools.LIMITS.memory_kb=512
for i,body in ipairs({
 "pcall(function()return string.rep('x',8*1024*1024)end);return 'escaped'",
 "return ('aaa'):match('a*a*a*b')",
 "return function()while true do end end",
 "return setmetatable({}, {__pairs=function()while true do end end})",
 "return ctx:step('callback',function()return ('aaa'):match('a*a*a*b')end)",
}) do
 register{id='brain16.source.'..i,version='1',source='return function(ctx) '..body..' end'}
 check(start('brain16.source.'..i):snapshot().status=='failed','source native/callback boundary '..i)
end
register{id='brain16.yield',version='1',source="return function(ctx)ctx:yield('pause');return string.rep('x',8*1024*1024)end"}
local bounded_run=start('brain16.yield')
check(bounded_run:snapshot().status=='suspended','source native budget can suspend')
local host_allocation=string.rep('h',2*1024*1024)
check(#host_allocation==2*1024*1024,'suspended source leaves host allocator live')
check(bounded_run:resume().status=='failed','resumed source keeps allocation ceiling')
local cancelled_run=start('brain16.yield');cancelled_run:cancel()
check(cancelled_run:snapshot().status=='cancelled','cancelled source closes protected child')
tools.LIMITS.memory_kb=source_limit
print('workflow BRAIN-16: '..passed..' checks passed')

-- Reviewer probes: eliminated provider frames cannot confer host authority.
for i,body in ipairs({
 "return ('aaa'):match('a*a*a*')",
 "local value=('aaa'):match('a*a*a*'); return value",
 "local alias=('aaa').match;return alias('aaa','a*a*a*')",
 "return ('aaa')['match']('aaa','a*a*a*')",
 "local function tail()return ('aaa'):match('a*a*a*')end;return tail()",
 "local ok,value=pcall(function()return ('aaa'):match('a*a*a*')end);return value",
}) do
 register{id='brain16.provider.tail.'..i,version='1',source="return {defaults={x=function() "..body.." end},run=function(ctx)return ctx:resolve('x')end}"}
 check(start('brain16.provider.tail.'..i):snapshot().status=='failed','provider native admission survives tail elimination '..i)
end
local close_effects=0
tools.register('_brain16_close_effect',{effect='write',run=function()close_effects=close_effects+1;return 'effect'end})
local close_state=require('perm').state();local old_headless=close_state.headless;close_state.headless='allow'
local close_narrow=invoke.context{state={mode='auto',guards=false,tool_policy={_brain16_close_effect='deny'}}}
for i,body in ipairs({"return ctx:resolve('x')", "local co=coroutine.create(function()return ctx:resolve('x')end);coroutine.resume(co);coroutine.yield('outer');coroutine.close(co)", "return ctx:resolve('x')"}) do
 register{id='brain16.provider.close.'..i,version='1',source='return function(ctx) '..body..' end'}
 local closed_run=start('brain16.provider.close.'..i,{context={x=function()
  local closer <close> = setmetatable({},{__close=function()
   tools.run('_brain16_close_effect',{})
   if i==3 then error('trusted cleanup failure') end
  end})
  coroutine.yield('paused');return 'done'
 end}})
 check(closed_run:snapshot().status=='suspended','trusted provider suspends inside protected source '..i)
 invoke.with_context(close_narrow,function()
  if i==2 then closed_run:resume() else closed_run:cancel() end
 end)
 check(close_effects==0,'protected close intersects closer authority '..i)
end
check(tools.run('_brain16_close_effect',{})=='effect' and close_effects==1,'protected close restores ordinary host authority')
close_state.headless=old_headless
print('workflow BRAIN-16 review: '..passed..' checks passed')
