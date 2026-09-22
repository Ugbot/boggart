package.path='lua/?.lua;lua/?/init.lua;'..package.path
local evaluate=require('learning.evaluate')
local fixture=dofile('tests/fixtures/process_bench/followup.lua')
local count=0
local function check(value,message)assert(value,message);count=count+1 end
local candidate=fixture.candidate(false)
local data,policy=fixture.dataset(false),fixture.policy()
data.examples[4].context.call_1_args.recipient='wrong-person'
local report=evaluate.run(candidate,data,policy)
check(report.eligibility==false,'plausible report cannot certify wrong recipient')
check(report.regressions.wrong_recipient==1,'independent verifier catches actual recipient')
print('learning_evaluate: '..count..' checks passed')
local function clone(v)if type(v)~='table' then return v end;local out={};for k,x in pairs(v)do out[k]=clone(x)end;return out end
local function has(report,reason)for _,v in ipairs(report.reasons)do if v==reason then return true end end;return false end
local function run(change,backed)
 local c,d,p=fixture.candidate(backed),fixture.dataset(backed),fixture.policy()
 if change then change(c,d,p) end
 return evaluate.run(c,d,p),c,d,p
end
for _,backed in ipairs({false,true})do
 local good,c,d=run(nil,backed)
 check(good.eligibility,'real compiler route eligible: '..tostring(backed)..' '..table.concat(good.reasons,','))
 check(good.coverage.executed==2 and good.coverage.fresh_heldout==1,'training and applicability-negative excluded from execution')
 check(c.manifest.compiler==(backed and 'source-subset-v1' or 'trace-sequence-v1'),'compiler route exercised')
 check(c.manifest.evaluated==false and c.manifest.activation_eligible==false,'candidate not mutated or activated')
 check(good.costs.candidate.total_known==14 and good.costs.baseline.total_known==30,'all startup and recurring costs included')
 check(good.costs.break_even_tasks==1 and good.costs.candidate.total_at_horizon==28,'amortized break even derived from positive savings')
 check(good.costs.candidate.per_verified_outcome==7,'declined task is not a verified successful outcome cost denominator')
 check(good.evidence_refs.candidate.source_hash==c.source_hash and good.evidence_refs.dataset.hash,'report pins evaluated source and dataset')
end
report=run(function(c,d,p)p.verifiers[1].verify=function()return {passed=false}end end)
check(not report.eligibility and report.regressions.false_success==2,'independent verifier failure defeats successful adapter text')
report=run(function(c,d,p)p.verifiers[1].verify=function()error('offline')end end)
check(not report.eligibility and report.regressions.failed==2,'verifier exceptions fail closed')
report=run(function(c,d,p)p.verifiers[1].verify=function()return true end end)
check(not report.eligibility,'boolean transcript is not a verifier verdict')
report=run(function(c,d,p)p.applicability.check=function(context,metadata)
 check(metadata.applicable==nil and metadata.expected==nil and metadata.costs==nil,'applicability never sees ground truth')
 return true
end end)
check(not report.eligibility and report.regressions.wrong_applicability==1 and report.regressions.applicability_false_positive==1,'wrong applicability executes negative case and rejects')
report=run(function(c,d,p)p.applicability.check=function()return false end end)
check(not report.eligibility and report.regressions.applicability_false_negative==2,'false-negative applicability rejected')
for _,dimension in ipairs({'task','session','variant'})do
 local calls=0
 report=run(function(c,d,p)d.examples[4][dimension]=d.examples[1][dimension];p.adapters['bench.send'].call=function()calls=calls+1 end end)
 check(has(report,'split_leakage') and calls==0,'preflight rejects '..dimension..' leakage before execution')
end
report=run(function(c,d)d.examples[4].trace=d.examples[1].trace end)
check(has(report,'split_leakage'),'trace lineage cannot cross splits')
report=run(function(c,d)c.manifest.sources[1].trace=d.examples[4].trace end)
check(has(report,'synthesis_lineage_unproven'),'heldout manifest provenance rejected')
report=run(function(c)c.manifest.sources={}end)
check(has(report,'candidate_manifest_invalid'),'missing synthesis provenance rejected')
report=run(function(c)c.source=c.source..' 'end)
check(has(report,'candidate_source_hash_mismatch'),'source tampering refused')
report=run(function(c,d,p)p.source_authority.check=function()return false end end)
check(has(report,'source_authority_unverified'),'revoked sources rejected')
report=run(function(c,d,p)p.adapters['bench.send'].version='2'end)
check(has(report,'adapter_invalid'),'capability version mismatch rejected')
report=run(function(c,d,p)p.adapters['bench.send'].isolation='production'end)
check(has(report,'adapter_invalid'),'production effects refused')
report=run(function(c,d,p)p.adapters['bench.send'].call=function()return {status='failed',error={code='fixture'}}end end)
check(not report.eligibility and report.outcomes[1].observation.status=='failed','failed required adapter is sticky')
report=run(function(c,d,p)p.adapters['bench.send'].call=function()return 'Looks successful' end end)
check(not report.eligibility,'opaque callback transcript not proof')
report=run(function(c,d,p)p.adapters['bench.send'].call=function()return {status='uncertain'}end end)
check(not report.eligibility and report.outcomes[1].observation.status=='uncertain','uncertain effect preserved')
local good=run()
local executions=0
report=run(function(c,d,p)
 for _,i in ipairs({3,4})do d.examples[i].mode='recorded';d.examples[i].recorded={source_hash=c.source_hash,observation=clone(good.outcomes[i-2].observation)}end
 p.adapters['bench.send'].call=function()executions=executions+1;error('must not execute replay')end
end)
check(not report.eligibility and report.coverage.recorded==2 and executions==0,'recorded-result evaluation never executes adapters or claims fresh proof')
check(report.outcomes[1].verified and has(report,'recorded_evidence_only'),'recorded output still independently verified')
report=run(function(c,d)d.costs.candidate.synthesis=nil end)
check(not report.eligibility and not report.costs.complete and report.costs.break_even_tasks==nil,'unknown lifecycle costs cannot fabricate break even')
report=run(function(c,d)d.examples[4].costs.candidate.failed_runs=nil end)
check(not report.costs.complete,'missing failure cost remains unknown')
report=run(function(c,d)d.examples[4].costs.candidate.execution=40 end)
check(report.costs.break_even_tasks==nil and report.costs.break_even_reason=='no_positive_savings','negative savings has no break even')
report=run(function(c,d,p)d.costs.candidate.synthesis=100;p.require_savings=true end)
check(has(report,'cost_gate_failed'),'amortization horizon controls optional savings gate')
report=run(function(c,d)d.examples[4].costs.candidate.fallback=3;d.examples[4].costs.candidate.repairs=4;d.examples[4].costs.candidate.failed_runs=5 end)
check(report.costs.candidate.total_known==26,'fallback repairs and failed attempts charged')
report=run(function(c,d)
 d.examples[4].context.call_1_args=function()return {recipient='current-person-4'}end
 d.examples[4].context_revisions={call_1_args='fresh-provider-1'}
end)
check(report.eligibility,'versioned injected function resolves current input')
report=run(function(c,d)
 d.examples[4].context.call_1_args={revision='1',resolve=function(ctx)return ctx:resolve('provided')end}
 d.examples[4].context.provided={recipient='current-person-4'}
end)
check(report.eligibility,'composable injected provider resolves lazily')
report=run(function(c,d)d.examples[5].context.call_1_args=function()error('unused')end end)
check(report.eligibility,'unselected providers remain lazy')
report=run(function(c,d)d.examples[4].context.call_1_args={revision='1',cache='run',resolve=function()return {}end}end)
check(not report.eligibility,'unsupported provider caching refused')
report=run(function(c,d)d.examples[4].context.call_1_args={revision='1',resolve=function(ctx)return ctx:resolve('call_1_args')end}end)
check(not report.eligibility,'provider cycles refused')
-- Deliberately tampered executable candidates exercise boundary/error semantics.
local function source_report(source,change)
 return run(function(c,d,p)c.source=source;c.source_hash=require('workflow').hash(source);if change then change(c,d,p)end end)
end
report=source_report([[return function(ctx) ctx:call('bench.send',{}) return {text='All done'} end]],function(c,d,p)
 p.adapters['bench.send'].call=function()return {status='denied'}end
end)
check(not report.eligibility and report.outcomes[1].observation.status=='denied','ignored required failure cannot look successful')
report=source_report([[return function(ctx) ctx:resolve('absent') return {text='All done'} end]])
check(not report.eligibility,'ignored missing context failure is sticky')
for _,source in ipairs({[[while true do end]],[[return function(ctx) while true do end end]],[[return function(ctx) return require('os').execute('true') end]],[[return function(ctx) return debug.getregistry() end]],[[return function(ctx) return coroutine.create(function()end) end]],[[return {defaults={},run=function(ctx)return {}end}]]})do
 report=source_report(source,function(c,d,p)p.instructions=50000 end)
 check(not report.eligibility,'source-init/run/host bypass or unsupported contract refused')
end
report=source_report([[return function(ctx)
 local first=ctx:call('bench.send',ctx:resolve('call_1_args'))
 ctx:observe('dataflow',nil,{producer=first.receipt.invocation_id,consumer=first.receipt.invocation_id,output='',input=''})
 return first.result
end]])
check(report.eligibility and #report.outcomes[1].observation.observations==1,'compiler-retained dataflow receipt identities supported')
check(report.outcomes[1].observation.calls[1].outcome.receipt.evaluation_only,'synthetic receipt never claims real dispatch')
report=run(function(c,d,p)p.verifiers[#p.verifiers+1]={id='isolation',revision='1',verify=function(observed)
 observed.result.text='poison';observed.calls[1].args.recipient='poison';return {passed=true}
end}end)
check(report.eligibility and report.outcomes[1].observation.result.text=='All done','verifiers cannot mutate captured evidence')
print('learning_evaluate final: '..count..' checks passed')
report=run(function(c,d,p)
 p.adapters['bench.send'].model=true
 p.adapters['bench.send'].call=function(args)return {status='succeeded',result={text='All done',recipient=args.recipient},usage={tokens=3}}end
 p.verifiers[1].verify=function()return {passed=true,duplicated_effects=0}end
 for _,e in ipairs(d.examples)do e.measurements={fallback=0,user_correction_ms=0}end
end)
check(report.measurements.model_decisions.known==2 and report.measurements.model_decisions.complete,'actual model adapter calls counted')
check(report.measurements.usage.known.tokens==6 and report.measurements.usage.complete,'adapter usage is separate from host monetary estimates')
check(report.measurements.latency_ms.complete and report.measurements.latency_ms.known>=0,'fresh execution latency observed')
check(report.measurements.duplicated_effects.complete and report.measurements.user_correction_ms.complete,'explicit duplicate and correction evidence measured')
report=run()
check(not report.measurements.model_decisions.complete and not report.measurements.usage.complete and not report.measurements.duplicated_effects.complete,'unobserved auxiliary metrics stay unknown')
report=run(function(c,d,p)p.verifiers[1].verify=function()return {passed=true,duplicated_effects=1}end end)
check(has(report,'duplicated_effects'),'independent duplicate effects verdict rejects')
local contract_a=run()
local contract_b=run(function(c)c.manifest.capabilities['bench.send']='2'end)
check(contract_a.evidence_refs.candidate.contract_hash~=contract_b.evidence_refs.candidate.contract_hash,'candidate identity binds pins beyond Lua source')
report=run(function(c)c.manifest.sources[2]=clone(c.manifest.sources[1])end)
check(has(report,'synthesis_lineage_ambiguous'),'duplicate training source provenance refused')
report=run(function(c)c.manifest.sources[3]=c.manifest.sources[2];c.manifest.sources[2]=nil end)
check(has(report,'candidate_manifest_invalid'),'sparse candidate provenance refused')
report=source_report([[return function(ctx)local t={} for i=1,100000 do t[i]={i,i,i,i} end return t end]],function(c,d,p)p.memory_bytes=65536;p.instructions=10000000 end)
check(not report.eligibility,'native allocation ceiling bounds candidate memory')
report=run(function(c,d,p)p.adapters['bench.send'].call=function()coroutine.yield('unsupported')end end)
check(not report.eligibility,'yielding adapter refused without resuming external work')
print('learning_evaluate complete: '..count..' checks passed')
-- Review regression: providers use resolver-only contexts and production request semantics.
local parity_report=run(function(c,d)
 for _,row in ipairs(d.examples)do
  local recipient=row.expected.recipient
  row.context.args={revision='request-step-1',resolve=function(provider_ctx,request)
   assert(type(request.step_id)=='string','root provider receives current step_id')
   assert(provider_ctx.step==nil and provider_ctx.observe==nil and provider_ctx.workflow==nil,'provider resolver-only facade')
   return {recipient=recipient}
  end}
 end
end,true)
check(parity_report.eligibility,'valid compiler candidate provider gets production request and restricted facade')
local facade_report=run(function(c,d)
 for _,row in ipairs(d.examples)do
  row.context.args={revision='workflow-method-1',resolve=function(provider_ctx)
   return provider_ctx:step('invalid-provider-step',function()return {recipient=row.expected.recipient}end)
  end}
 end
end,true)
check(not facade_report.eligibility,'providers cannot use workflow-only methods that production denies')
local requests={}
report=source_report([[return function(ctx)
 local request={step_id='forged',tag='root'}
 local args=ctx:step('resolve-step',function()return ctx:resolve('args',request)end)
 assert(request.step_id=='forged')
 local sent=ctx:call('bench.send',args)
 return sent.result
end]],function(c,d)
 for _,row in ipairs(d.examples)do
  local recipient=row.expected.recipient
  row.context.args={revision='root-request-1',resolve=function(provider_ctx,request)
   assert(request.step_id~='forged' and request.tag=='root')
   requests[#requests+1]=request.step_id
   local no_request=provider_ctx:resolve('nil-child')
   local explicit={step_id='child-owned',tag='child'}
   local child=provider_ctx:resolve('explicit-child',explicit)
   assert(explicit.step_id=='child-owned' and explicit.tag=='mutated','nested provider request retains caller identity')
   assert(no_request and child)
   return {recipient=recipient}
  end}
  row.context['nil-child']={revision='nil-request-1',resolve=function(_,request)assert(request==nil);return true end}
  row.context['explicit-child']={revision='child-request-1',resolve=function(_,request)
   assert(request.step_id=='child-owned' and request.tag=='child');request.tag='mutated';return true
  end}
 end
end)
check(report.eligibility and #requests==2,'root copies/injects step_id; nested requests preserve explicit or nil shape')
report=source_report([[return function(ctx)
 local args=ctx:resolve('args',false)
 return ctx:call('bench.send',args).result
end]],function(c,d)
 for _,row in ipairs(d.examples)do
  row.context.args={revision='false-request-1',resolve=function(_,request)
   assert(request==false);return {recipient=row.expected.recipient}
  end}
 end
end)
check(report.eligibility,'scalar false provider request stays false')
print('learning_evaluate provider parity: '..count..' checks passed')
local function provider_failure_case(optional,status)
 return source_report("return function(ctx) local args=ctx:resolve('args',nil,{required="..tostring(not optional).."}) return ctx:call('bench.send',args).result end",function(c,d,p)
  p.adapters['bench.send'].call=function(args)
   if args.probe then return {status=status,error={code='fixture-provider-probe'}} end
   return {status='succeeded',result={text='All done',recipient=args.recipient}}
  end
  for _,row in ipairs(d.examples)do
   row.context.args={revision='provider-call-failure-1',resolve=function(provider_ctx)
    local first=provider_ctx:call('bench.send',{recipient=row.expected.recipient,probe=true},{required=false})
    assert(first.status==status)
    local second=provider_ctx:call('bench.send',{recipient=row.expected.recipient})
    assert(second.status=='succeeded','provider may handle an outcome and continue locally')
    return {recipient=row.expected.recipient}
   end}
  end
 end)
end
report=provider_failure_case(false,'failed')
check(not report.eligibility and #report.outcomes[1].observation.calls==2,'provider processes failures before root required-resolution gate')
report=provider_failure_case(true,'failed')
check(report.eligibility and #report.outcomes[1].observation.calls==3,'optional root resolution permits handled provider failure; provider call workflow opts ignored')
report=provider_failure_case(true,'uncertain')
check(not report.eligibility and report.outcomes[1].observation.status=='uncertain','uncertain provider effect fails even optional root resolution')
report=run(function(c,d)
 for _,row in ipairs(d.examples)do
  row.context.call_1_args={revision='recover-missing-child-1',resolve=function(provider_ctx)
   local value,why=provider_ctx:resolve('missing-child')
   assert(value==nil and why.code=='context_missing')
   return {recipient=row.expected.recipient}
  end}
 end
end)
check(report.eligibility,'recoverable nested missing context does not poison root resolution')
report=run(function(c,d)
 for _,row in ipairs(d.examples)do
  row.context.call_1_args={revision='nonnull-result-error-1',resolve=function()
   return {recipient=row.expected.recipient},{code='ignored-with-nonnil-value'}
  end}
 end
end)
check(report.eligibility,'production accepts nonnil provider result with ignored second return')
report=run(function(c,d)
 for _,row in ipairs(d.examples)do row.context.call_1_args={revision='nil-result-error-1',resolve=function()return nil,'provider unavailable'end}end
end)
check(not report.eligibility and report.outcomes[1].observation.resolutions[1].error.code=='context_provider_error','nil-result provider diagnostics distinguish returned error')
report=run(function(c,d)
 for _,row in ipairs(d.examples)do row.context.call_1_args={revision='forward-child-error-1',resolve=function(provider_ctx)return provider_ctx:resolve('missing-child')end}end
end)
check(not report.eligibility and report.outcomes[1].observation.resolutions[1].error.code=='context_missing','nested resolver error identity survives provider forwarding')
print('learning_evaluate provider failure semantics: '..count..' checks passed')

report=run(function(c,d) for _,row in ipairs(d.examples)do row.context.call_1_args={resolve=false,recipient=row.expected.recipient}end end)
check(not report.eligibility,'nonfunction provider resolve field is invalid as in production')
print('learning_evaluate reviewed parity: '..count..' checks passed')
