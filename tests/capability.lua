local cap,invoke,tools=require('capability'),require('invoke'),require('tools')
local passed=0
local function check(v,msg) assert(v,msg); passed=passed+1 end
local count=0
local ctx=invoke.context{state={mode='auto',guards=false}}
local yes=invoke.context{state={mode='auto',guards=false},approve=function() return true end}
local function register(id,effect,runner,extra)
  local d=extra or {};d.id=id;d.version='1';d.effect=effect
  return assert(cap.register(d,runner))
end
register('structured','pure',function(a) count=count+1;return {status='user-data',n=a.n} end,{
  input_schema={type='object',properties={n={type='integer',minimum=0}},required={'n'},additionalProperties=false},
  output_schema={type='object',properties={n={type='integer'},status={type='string'}},required={'n'}}})
local out=cap.call(ctx,'structured','2',{n=1})
check(out.status=='failed' and not out.receipt.dispatched and count==0,'version mismatch before dispatch')
out=cap.call(ctx,'structured','1',{n='bad'})
check(out.error.code=='input_validation' and count==0,'input validates before dispatch')
out=cap.call(ctx,'structured','1',{n=3,extra=true})
check(out.status=='failed' and count==0,'additional properties refused')
out=cap.call(ctx,'structured','1',{n=3})
check(out.status=='succeeded' and out.result.status=='user-data' and out.result.n==3,'result is not receipt')
check(out.receipt.dispatched and out.receipt.version=='1' and out.receipt.invocation_id,'execution receipt')
local d=cap.resolve('structured','1');d.input_schema.required={'injected'};d.effect='write'
check(cap.call(ctx,'structured','1',{n=4}).status=='succeeded','resolve cannot mutate descriptor')
check(not cap.resolve('structured') and not cap.register({id='structured',version='1'},function() end),'explicit immutable versions')
for _,schema in ipairs({{type='string',pattern='x'},{type='array',items={type='string',format='email'}},{anyOf={}}}) do
  check(not cap.register({id='bad-schema',version='1',input_schema=schema},function() end),'unsupported schema rejected')
end
register('array','pure',function(a)return a end,{input_schema={type='array',items={type='boolean'},minItems=1,maxItems=2}})
check(cap.call(ctx,'array','1',{true,false}).status=='succeeded','nested array valid')
check(cap.call(ctx,'array','1',{true,'false'}).error.code=='input_validation','nested array invalid')
check(cap.call(ctx,'array','1',{[1]=true,[3]=true}).status=='failed','sparse array invalid')
register('trusted-validator','pure',function(a)return a end,{input_schema={pattern='host-owned'},input_validator=function(a)return a.ok==true,'expected ok' end})
check(cap.call(ctx,'trusted-validator','1',{}).status=='failed','explicit trusted validator applied')
register('invalid-output','pure',function()return 'bad' end,{output_schema={type='number'}})
check(cap.call(ctx,'invalid-output','1',{}).error.code=='output_validation','output validation')
register('timeout','write',function()error('timeout after dispatch')end)
out=cap.call(ctx,'timeout','1',{})
check(out.status=='uncertain' and out.error.retryable==false,'effectful timeout uncertain and no retry')
register('read-timeout','read',function()error('timeout')end)
check(cap.call(ctx,'read-timeout','1',{}).status=='failed','read failure')
register('cancelled','write',function()return nil,{status='cancelled',effect_disproven=true}end)
check(cap.call(ctx,'cancelled','1',{}).status=='cancelled','confirmed cancellation')
register('ambiguous-cancel','write',function()return nil,{status='cancelled'}end)
check(cap.call(ctx,'ambiguous-cancel','1',{}).status=='uncertain','cancel request is not disproven effect')
register('unknown',nil,function()return 42 end)
check(cap.call(ctx,'unknown','1',{}).error.code=='permission_error','unknown effect requires explicit approval')
check(cap.call(yes,'unknown','1',{}).result==42,'approved unknown returns number')
register('mandatory','pure',function()return true end,{requires_approval=true})
check(cap.call(ctx,'mandatory','1',{}).status=='failed','explicit approval metadata')
tools.register('_legacy_cap',{effect='pure',input_schema={type='object'},run=function(a)return {value=a.n}end})
assert(cap.adapt('_legacy_cap','1',tools))
local events=require('events'); local starts,ends=0,0
local eh1=events.on('tool:before',function()starts=starts+1 end)
local eh2=events.on('tool:after',function()ends=ends+1 end)
out=cap.call(ctx,'_legacy_cap','1',{n=9})
events.off(eh1);events.off(eh2)
check(starts==1 and ends==1,'legacy adaptation has one admission/event pair')
check(out.result.value==9,'legacy arguments and structured results preserved')
check(type(tools.run('_legacy_cap',{n=9}))=='string','legacy model string compatibility')
check(not cap.adapt('_legacy_cap','2',tools,{bounded={tokens=true}}),'legacy cannot claim bounds')
tools.register('_legacy_cap',{effect='pure',run=function()error('must not run')end})
check(cap.call(ctx,'_legacy_cap','1',{}).error.code=='tool_not_found','legacy adapter pins entry')
local policy=require('policy')
local function limited(ledger,id,quotas)
  return invoke.context{state={mode='auto',guards=false},ledger=ledger,policy=assert(policy.compile{{id=id,revision=1,
    capabilities={allow={'*'}},limits={tokens=10},quotas=quotas or {}}})}
end
local path=os.tmpname();local conn=assert(db.open(path));local ledger=assert(require('quota').open(conn))
local lctx=limited(ledger,'hard-only')
local ceiling
register('bounded','pure',function(a,execution)
  count=count+1;ceiling=execution.ceilings.tokens
  return a.n,{status='succeeded',usage={tokens=4},receipt={job_id='fixture'}}
end,{bounded={tokens=true},estimate=function()return {tokens=6}end,target='fixture-provider'})
out=cap.call(lctx,'bounded','1',{n=8})
check(out.status=='succeeded' and out.result==8 and ceiling==6,'provider receives reserved ceiling')
check(out.usage.tokens==4 and out.receipt.execution.job_id=='fixture','authoritative usage and delegated receipt')
local before=count
out=cap.call(lctx,'structured','1',{n=1})
check(out.error.code=='unsupported_limit' and count==before,'unbounded runner refused before dispatch')
register('costly','pure',function()error('must not run')end,{bounded={tokens=true},estimate=function()return {tokens=11}end})
check(cap.call(lctx,'costly','1',{}).status=='failed','over-limit estimate denied')
register('overrun','pure',function()return 'bad',{usage={tokens=7}}end,{bounded={tokens=true},estimate=function()return {tokens=6}end})
out=cap.call(lctx,'overrun','1',{})
check(out.status=='failed' and out.error.code=='quota_settlement','hard-limit-only overrun fails')
local reopened=assert(require('quota').open(conn))
check(cap.call(limited(reopened,'hard-only'),'bounded','1',{}).error.code=='overrun','hard-limit overrun halt persists across reopen')
local conn2=assert(db.open(os.tmpname()));local ledger2=assert(require('quota').open(conn2))
local qctx=limited(ledger2,'cost-bucket',{{id='tokens',metric='tokens',limit=10,window_seconds=60}})
check(cap.call(qctx,'bounded','1',{}).status=='succeeded','bounded quota admission')
check(cap.call(qctx,'bounded','1',{}).status=='succeeded','actual usage refunds unused reserved budget')
check(cap.call(qctx,'bounded','1',{}).status=='failed','cost quota exhausted before third dispatch')
register('missing-usage','pure',function()return 'bad' end,{bounded={tokens=true},estimate=function()return {tokens=1}end})
local conn3=assert(db.open(os.tmpname()));local ledger3=assert(require('quota').open(conn3))
local mctx=limited(ledger3,'missing')
check(cap.call(mctx,'missing-usage','1',{}).error.code=='usage_missing','missing usage fails closed')
check(cap.call(mctx,'bounded','1',{}).error.code=='quota_uncertain','missing usage quarantines authority')
local single=0
local singleledger={reserve=function(_,_,id) single=single+1;return {id=id} end,
  settle=function()return {overrun=false}end}
tools.register('_single_adapt',{effect='pure',run=function()return 1 end})
assert(tools.capability('_single_adapt','1'))
local singlectx=invoke.context{state={mode='auto',guards=false},ledger=singleledger,
  policy=assert(policy.compile{{id='single',revision=1,capabilities={allow={'*'}},
    quotas={{id='calls',metric='calls',limit=1,window_seconds=60}}}})}
check(cap.call(singlectx,'_single_adapt','1',{}).status=='succeeded' and single==1,'adapter reserves once')
local deniedctx=invoke.context{state={mode='auto',guards=false,tool_policy={_single_adapt='deny'}}}
check(cap.call(deniedctx,'_single_adapt','1',{}).error.code=='permission_error','adaptation preserves legacy deny')
register('resource','read',function()return true end,{resources=function()return {path='/host/private'}end})
local resourcectx=invoke.context{state={mode='auto',guards=false},policy=assert(policy.compile{{id='resource',revision=1,
  capabilities={allow={'*'}},resources={path={evaluator='prefix',allow={'/safe/'}}}}})}
check(cap.call(resourcectx,'resource','1',{path='/safe/forged'}).error.code=='permission_error','host resources defeat forged labels')
register('write-output','write',function()return 'bad' end,{output_schema={type='number'}})
check(cap.call(ctx,'write-output','1',{}).status=='uncertain','invalid output cannot disprove write')
register('disproven','write',function()return nil,{status='failed',effect_disproven=true,error={code='timeout',message='not dispatched at provider'}}end)
check(cap.call(ctx,'disproven','1',{}).status=='failed','authoritative disproof permits failed outcome')
register('artifact','read',function()return nil,{artifacts={{uri='fixture:artifact'}},usage={tokens=0}}end)
check(cap.call(ctx,'artifact','1',{}).artifacts[1].uri=='fixture:artifact','artifact references retained')
register('no-estimate','pure',function()error('must not run')end,{bounded={tokens=true},estimate=function()return {}end})
check(cap.call(lctx,'no-estimate','1',{}).error.code=='invalid_estimate','missing metric estimate is refused')
local first,second=0,0
tools.register('_connection_loss',{effect='write',run=function()
  first=first+1;return 'Tool error: [runtime_error] service is not connected after send'
end})
tools.register('_replacement',{effect='write',run=function()second=second+1;return 'duplicate' end})
tools.register_fallback('_uncertain_fallback','',{}, {'_connection_loss','_replacement'})
check(tools.run('_uncertain_fallback',{}):find('[uncertain]',1,true) and first==1 and second==0,
  'connection loss after effect never falls back')
tools.register('_typed_missing',{effect='read',run=function()return 'Tool error: [tool_not_found] unavailable' end})
tools.register_fallback('_safe_fallback','',{}, {'_typed_missing','_replacement'})
check(tools.run('_safe_fallback',{})=='duplicate' and second==1,'typed unavailable read can fall back')
for i,validator in ipairs({
  function()return false,'rejected'end,function()return nil,'rejected'end,
  function()return 'truthy'end,function()return {}end,function()error('validator threw')end,
}) do
  local input_id='bad-input-validator-'..i
  register(input_id,'write',function()error('must not dispatch')end,{input_validator=validator})
  local refused=cap.call(ctx,input_id,'1',{})
  check(refused.status=='failed' and not refused.receipt.dispatched,'input validator must return literal true '..i)
  local output_id='bad-output-validator-'..i
  register(output_id,'write',function()return 1 end,{output_validator=validator})
  refused=cap.call(ctx,output_id,'1',{})
  check(refused.status=='uncertain' and refused.receipt.dispatched,'output validator cannot disprove effect '..i)
end
-- Lua's sparse length border is not a density proof. These ordinary tables
-- place holes before several later keys, including a key-count border layout.
local sparse_forms={
  {[1]=true,[3]=true,[4]=true,[6]=true},
  {true,nil,true,true,nil,true},
  {[2]=true,[3]=true,[4]=true,[8]=true},
}
register('dense-only','pure',function(a)return a end,{input_schema={type='array',items={type='boolean'}}})
for i,sparse in ipairs(sparse_forms) do
  local sparseout=cap.call(ctx,'dense-only','1',sparse)
  check(sparseout.error and sparseout.error.code=='input_validation','reject sparse input layout '..i)
  local required={};for k in pairs(sparse) do required[k]='field'..k end
  check(not cap.register({id='sparse-required-'..i,version='1',input_schema={type='object',required=required}},function()end),
    'reject sparse required list '..i)
  check(not cap.register({id='sparse-enum-'..i,version='1',input_schema={enum=sparse}},function()end),
    'reject sparse enum list '..i)
  register('sparse-output-'..i,'pure',function()return sparse end,{output_schema={type='array',items={type='boolean'}}})
  check(cap.call(ctx,'sparse-output-'..i,'1',{}).error.code=='output_validation','reject sparse output layout '..i)
end
check(cap.call(ctx,'dense-only','1',{true,true,true,'invalid-tail'}).error.code=='input_validation','validate every dense array item')
local costthrowdb=assert(db.open(os.tmpname()));local costthrowledger=assert(require('quota').open(costthrowdb))
local output_checked=false
register('cost-throw','write',function()return 1,{usage={tokens=7},receipt={job_id='overrun-job'}}end,
  {bounded={tokens=true},estimate=function()return {tokens=6}end,
   output_validator=function()output_checked=true;error('output validator threw after provider cost')end})
local costthrow=cap.call(limited(costthrowledger,'cost-throw'),'cost-throw','1',{})
check(output_checked and costthrow.status=='uncertain' and costthrow.error.code=='quota_settlement','throwing output validator preserves overrun failure')
check(costthrow.usage.tokens==7 and costthrow.receipt.execution.job_id=='overrun-job','throwing output validator retains usage and job receipt')
local costreopened=assert(require('quota').open(costthrowdb))
check(cap.call(limited(costreopened,'cost-throw'),'bounded','1',{}).error.code=='overrun','validator throw overrun halt persists across reopen')
print('capability: '..passed..' checks passed')
