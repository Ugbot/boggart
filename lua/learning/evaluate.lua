-- Privileged host evaluator. Candidate Lua only sees isolated context methods;
-- host adapters/providers/verifiers are trusted, versioned integration code.
local M={}
local hash=require('workflow').hash
local monotonic=require('uv').hrtime
local function fail(code)error({code=code},0)end
local function text(v)return type(v)=='string' and #v>0 end
local function finite(v)return type(v)=='number' and v==v and v>=0 and v<math.huge end
local function copy(value,host,seen,depth,budget)
 local kind=type(value)
 if kind=='nil' or kind=='boolean' then return value end
 if kind=='string' then if #value>262144 then fail('data_limit') end;return value end
 if kind=='number' then if value~=value or math.abs(value)==math.huge then fail('invalid_data') end;return value end
 if kind=='function' and host then return value end
 if kind~='table' or getmetatable(value) then fail('invalid_data') end
 seen,depth,budget=seen or {},depth or 0,budget or {n=0}
 if seen[value] or depth>32 then fail('invalid_data') end
 seen[value]=true
 local out={}
 for k,v in pairs(value)do
  budget.n=budget.n+1;if budget.n>32768 then fail('data_limit') end
  if type(k)~='string' and type(k)~='number' then fail('invalid_data') end
  out[k]=copy(v,host,seen,depth+1,budget)
 end
 seen[value]=nil;return out
end
local canonical=require('learning.identity').canonical
local function reason(report,code)
 if not report._reasons[code] then report._reasons[code]=true;report.reasons[#report.reasons+1]=code end
 report.eligibility=false
end
local function array(value,maximum)
 if type(value)~='table' or #value>maximum then return false end
 local count=0;for key in pairs(value)do
  if type(key)~='number' or key%1~=0 or key<1 or key>#value then return false end
  count=count+1
 end
 return count==#value
end
local function descriptor(v,fn)
 return type(v)=='table' and text(v.id) and text(v.revision) and type(v[fn])=='function'
end
local function bounded(fn,instructions,memory)
 if not sys or not sys.memcapable or not sys.memcapable() then fail('restricted_allocator_unavailable') end
 local co=coroutine.create(fn)
 local ticks=0
 debug.sethook(co,function()
  ticks=ticks+1000;if ticks>instructions then fail('instruction_limit') end
 end,'',1000)
 local limit=sys.memlimit(memory)
 local ok,result=sys.memresume(limit,co)
 local exhausted=sys.memfailed(limit)
 if coroutine.status(co)~='dead' then
  -- Candidate has neither coroutine nor yielding primitives. Host adapters must
  -- be synchronous. Close with the same allocator cap and hook still installed.
  sys.memclose(limit,co)
  ok,result=false,{code='unsupported_yield'}
 end
 if exhausted then return false,{code='memory_limit'} end
 if ticks>instructions then return false,{code='instruction_limit'} end
 return ok,result
end
local statuses={succeeded=true,failed=true,cancelled=true,denied=true,unavailable=true,uncertain=true}
local function execute(candidate,example,policy)
 local started=monotonic()
 local observation={status='running',calls={},resolutions={},steps={},observations={},runtime='isolated-compiler-subset-v1'}
 local fatal,defaults,active_resolution,step=nil,{}, {},'root'
 local function mark(code,status)
  if not fatal or status=='uncertain' then fatal={code=code,status=status or 'failed'} end
 end
 local function alive()if fatal then fail(fatal.code) end end
 local ctx={}
 local function dispatch(id,args)
  alive();args=copy(args)
  if type(args)~='table' then mark('invalid_call');fail('invalid_call') end
  local adapter=policy.adapters[id]
  local call={id=id,version=candidate.manifest.capabilities[id],args=copy(args),step=step}
  observation.calls[#observation.calls+1]=call
  if #observation.calls>policy.max_calls then mark('call_limit');fail('call_limit') end
  local outcome
  if not call.version or not adapter or adapter.version~=call.version then
   outcome={status='denied',error={code='capability_unpinned'}}
  else
   call.adapter={id=adapter.id,revision=adapter.revision,isolation=adapter.isolation,effect=adapter.effect}
   local ok,value=pcall(adapter.call,copy(args),{example_id=example.id,mode=example.mode,step=step})
   if ok then outcome=copy(value) else outcome={status='failed',error={code='adapter_error'}} end
  end
  if type(outcome)~='table' or not statuses[outcome.status] then outcome={status='failed',error={code='adapter_outcome_invalid'}} end
  outcome.receipt=outcome.receipt or {}
  outcome.receipt.invocation_id='evaluation:'..example.id..':'..#observation.calls
  outcome.receipt.evaluation_only=true
  outcome.receipt.isolation=adapter and adapter.isolation or 'denied'
  call.outcome=copy(outcome)
  return copy(outcome)
 end
 function ctx:call(id,args,opts)
  opts=copy(opts)
  if opts~=nil and type(opts)~='table' then mark('invalid_call');fail('invalid_call') end
  local outcome=dispatch(id,args)
  if outcome.status=='uncertain' or outcome.status~='succeeded' and not (opts and opts.required==false) then
   mark('required_call_'..outcome.status,outcome.status)
  end
  return outcome
 end
 local resolution_errors=setmetatable({}, {__mode='k'})
 local function resolution_error(code)
  local why={code=code};resolution_errors[why]=true;return why
 end
 local resolve
 resolve=function(key,request)
  alive()
  if not text(key) then return nil,resolution_error('context_invalid') end
  local value=example.context[key];if value==nil then value=defaults[key] end
  local record={key=key,step=step,request=copy(request),revision=example.context_revisions and example.context_revisions[key]}
  observation.resolutions[#observation.resolutions+1]=record
  if #observation.resolutions>policy.max_calls then mark('resolution_limit');fail('resolution_limit') end
  if active_resolution[key] then record.status='failed';record.error={code='context_cycle'};return nil,resolution_error('context_cycle') end
  active_resolution[key]=true
  local provider
  if type(value)=='function' then provider=value elseif type(value)=='table' then provider=value.resolve end
  if provider~=nil then
   if type(provider)~='function' then active_resolution[key]=nil;record.status='failed';record.error={code='context_invalid'};return nil,resolution_error('context_invalid') end
   local revision=type(value)=='table' and value.revision or record.revision
   if not text(revision) then mark('provider_revision_required');fail('provider_revision_required') end
   if type(value)=='table' and (value.cache and value.cache~='none' or value.cache_key) then mark('unsupported_provider_cache');fail('unsupported_provider_cache') end
   record.revision=revision
   -- Production providers receive resolver methods, never workflow methods.
   -- Nested requests pass through without the root workflow's step injection.
   local provider_ctx={}
   function provider_ctx:resolve(child,child_request)return resolve(child,child_request)end
   function provider_ctx:call(id,args)return dispatch(id,args)end
   local ok,result,why=pcall(provider,provider_ctx,request)
   active_resolution[key]=nil
   if not ok or result==nil then
    local failure=ok and resolution_errors[why] and why or resolution_error((not ok or why~=nil) and 'context_provider_error' or 'context_missing')
    record.status='failed';record.error=copy(failure)
    return nil,failure
   end
   value=result
  end
  active_resolution[key]=nil
  value=copy(value);record.value=copy(value);record.status=value==nil and 'failed' or 'succeeded'
  if value==nil then
   record.error={code='context_missing'}
   return nil,resolution_error('context_missing')
  end
  return value,{source='injected',revision=record.revision}
 end
 function ctx:resolve(key,request,opts)
  alive();request=copy(request);opts=copy(opts)
  if opts~=nil and type(opts)~='table' then mark('invalid_context');fail('invalid_context') end
  if request==nil then request={} end
  if type(request)=='table' then request.step_id=step end
  local first_call=#observation.calls+1
  local value,provenance=resolve(key,request)
  local required=not (opts and opts.required==false)
  if value==nil and required then mark(provenance.code) end
  -- Provider calls are allowed to return failures for provider-local handling.
  -- The workflow applies the root resolution's requirement to every dependency.
  for i=first_call,#observation.calls do
   local call=observation.calls[i]
   local status=call.outcome and call.outcome.status or 'failed'
   if status=='uncertain' or required and status~='succeeded' then
    mark('required_provider_call_'..status,status)
   end
  end
  return value,provenance
 end
 function ctx:step(site,fn)
  alive();if not text(site) or type(fn)~='function' then mark('invalid_step');fail('invalid_step') end
  local previous=step;step=previous..'/'..site
  local record={site=site,status='running'};observation.steps[#observation.steps+1]=record
  if #observation.steps>policy.max_calls then mark('step_limit');fail('step_limit') end
  local ok,value=pcall(fn,ctx)
  record.status=ok and not fatal and 'succeeded' or 'failed';step=previous
  if not ok then mark('step_error');error(value,0) end
  return value
 end
 function ctx:observe(kind,value,links)
  alive();if kind~='branch' and kind~='dataflow' then mark('invalid_observation');fail('invalid_observation') end
  observation.observations[#observation.observations+1]={kind=kind,value=copy(value),links=copy(links),step=step}
  if #observation.observations>policy.max_calls then mark('observation_limit');fail('observation_limit') end
 end
 -- No debug, coroutine, pcall, require, loaders, host libraries or registries.
 local env={assert=assert,error=error,type=type,ipairs=ipairs,pairs=pairs,next=next,tonumber=tonumber,tostring=tostring,select=select}
 local ok,result=bounded(function()
  local chunk,why=load(candidate.source,'@evaluation:'..candidate.source_hash,'t',env)
  if not chunk then fail('source_invalid') end
  local spec=chunk()
  if type(spec)=='function' then spec={run=spec} end
  if type(spec)~='table' or type(spec.run)~='function' then fail('source_contract') end
  for key in pairs(spec)do if key~='run' then fail('unsupported_source_contract') end end
  return copy(spec.run(ctx))
 end,policy.instructions,policy.memory_bytes)
 observation.status=fatal and fatal.status or ok and 'succeeded' or 'failed'
 observation.result=ok and result or nil
 observation.latency_ms=(monotonic()-started)/1000000
 observation.error=fatal or not ok and {code=type(result)=='table' and result.code or 'source_error'} or nil
 return observation
end
local startup={'discovery','imports','mining','synthesis','evaluation'}
local recurring={'execution','failed_runs','fallback','repairs'}
local function costs(dataset,outcomes)
 local report={unit=dataset.costs and dataset.costs.unit,provenance='host_supplied',unknowns={},candidate={},baseline={}}
 local function sum(values,fields,path)
  local total=0
  for _,key in ipairs(fields)do
   local value=values and values[key]
   if not finite(value) then report.unknowns[#report.unknowns+1]=path..'.'..key else total=total+value end
  end
  return total
 end
 if not text(report.unit) then report.unknowns[#report.unknowns+1]='unit' end
 local horizon=dataset.costs and dataset.costs.horizon
 if not finite(horizon) or horizon<1 or horizon%1~=0 then report.unknowns[#report.unknowns+1]='horizon';horizon=nil end
 report.horizon=horizon
 for _,side in ipairs({'candidate','baseline'})do
  local item=report[side];item.learning_known=sum(dataset.costs and dataset.costs[side],startup,side)
  item.learning_components=copy(dataset.costs and dataset.costs[side])
  item.execution_by_example={}
  item.execution_known=0;item.verified_outcomes=0
  for _,outcome in ipairs(outcomes)do
   local row=outcome._example
   item.execution_by_example[row.id]={components=copy(row.costs and row.costs[side]),evidence_ref=row.cost_evidence_ref or row.evidence_ref}
   item.execution_known=item.execution_known+sum(row.costs and row.costs[side],recurring,side..'.'..row.id)
   if side=='candidate' and outcome.verified and row.applicable or side=='baseline' and row.applicable and row.baseline_verified==true and text(row.baseline_evidence_ref) then item.verified_outcomes=item.verified_outcomes+1 end
   if side=='baseline' and (type(row.baseline_verified)~='boolean' or not text(row.baseline_evidence_ref)) then report.unknowns[#report.unknowns+1]='baseline.'..row.id..'.verification' end
  end
  item.total_known=item.learning_known+item.execution_known
 end
 report.complete=#report.unknowns==0 and #outcomes>0
 if report.complete then
  for _,side in ipairs({'candidate','baseline'})do
   local item=report[side]
   item.per_task=item.execution_known/#outcomes
   item.amortized_per_task=item.per_task+item.learning_known/horizon
   item.total_at_horizon=item.per_task*horizon+item.learning_known
   if item.verified_outcomes>0 then item.per_verified_outcome=item.total_known/item.verified_outcomes end
  end
  local savings=report.baseline.per_task-report.candidate.per_task
  report.savings_per_task=savings
  if savings>0 then report.break_even_tasks=math.max(0,math.ceil((report.candidate.learning_known-report.baseline.learning_known)/savings))
  else report.break_even_reason='no_positive_savings' end
 else report.break_even_reason='unknown_costs' end
 return report
end
local function run(candidate,dataset,policy,report)
 candidate=copy(candidate);dataset=copy(dataset,true);policy=copy(policy,true)
 if type(candidate)~='table' or type(candidate.source)~='string' or #candidate.source>262144 or candidate.source_hash~=hash(candidate.source) then fail('candidate_source_hash_mismatch') end
 if type(candidate.manifest)~='table' or candidate.manifest.kind~='mined_lua_candidate' or type(candidate.manifest.capabilities)~='table' or not array(candidate.manifest.sources,8) or #candidate.manifest.sources==0 or candidate.manifest.schema_version~=1 or not ({['trace-sequence-v1']=true,['source-subset-v1']=true})[candidate.manifest.compiler] then fail('candidate_manifest_invalid') end
 if type(dataset)~='table' or not text(dataset.id) or not text(dataset.revision) or not array(dataset.examples,1024) then fail('dataset_invalid') end
 if not text(policy.id) or not text(policy.revision) or not descriptor(policy.applicability,'check') or not descriptor(policy.source_authority,'check') or type(policy.adapters)~='table' or not array(policy.verifiers,64) or #policy.verifiers==0 then fail('policy_invalid') end
 policy.instructions=policy.instructions or 1000000;policy.memory_bytes=policy.memory_bytes or 8*1024*1024;policy.max_calls=policy.max_calls or 256
 for _,key in ipairs({'instructions','memory_bytes','max_calls'})do if not finite(policy[key]) or policy[key]<1 or policy[key]%1~=0 then fail('policy_invalid') end end
 if policy.instructions>10000000 or policy.memory_bytes>64*1024*1024 or policy.max_calls>1024 then fail('policy_limit') end
 report.evidence_refs={dataset={id=dataset.id,revision=dataset.revision,hash=hash(canonical(dataset))},policy={id=policy.id,revision=policy.revision,contract_hash=hash(canonical(policy))},candidate={contract_hash=hash(canonical(candidate)),source_hash=candidate.source_hash,manifest=copy(candidate.manifest),unknowns=copy(candidate.unknowns)},verifiers={},adapters={},examples={}}
 for _,verifier in ipairs(policy.verifiers)do
  if not descriptor(verifier,'verify') then fail('verifier_invalid') end
  report.evidence_refs.verifiers[#report.evidence_refs.verifiers+1]={id=verifier.id,revision=verifier.revision}
 end
 for id,version in pairs(candidate.manifest.capabilities)do
  local adapter=policy.adapters[id]
  if not text(version) or not descriptor(adapter,'call') or adapter.version~=version or not ({mock=true,isolated=true})[adapter.isolation] or not ({pure=true,read=true,write=true})[adapter.effect] then fail('adapter_invalid') end
  report.evidence_refs.adapters[id]={id=adapter.id,revision=adapter.revision,version=version,isolation=adapter.isolation,effect=adapter.effect}
 end
 local seen,groups,training={}, {task={},session={},variant={}},{}
 for _,example in ipairs(dataset.examples)do
  if not text(example.id) or seen[example.id] or not ({train=true,validation=true,heldout=true})[example.split] then fail('example_invalid') end
  seen[example.id]=true
  for dimension,index in pairs(groups)do
   local identity=example[dimension]
   if not text(identity) then fail('lineage_required') end
   if index[identity] and index[identity]~=example.split then fail('split_leakage') end
   index[identity]=example.split
  end
  if not text(example.trace) or not text(example.scope) then fail('lineage_required') end
  local key=example.scope..'\0'..example.trace
  if training[key] and training[key]~=example.split then fail('split_leakage') end
  training[key]=example.split
  report.coverage[example.split]=report.coverage[example.split]+1
 end
 local source_keys={}
 for _,source in ipairs(candidate.manifest.sources)do
  if not text(source.trace) or not text(source.scope) or training[source.scope..'\0'..source.trace]~='train' then fail('synthesis_lineage_unproven') end
  local key=source.scope..'\0'..source.trace
  if source_keys[key] then fail('synthesis_lineage_ambiguous') end
  source_keys[key]=true
 end
 if report.coverage.validation==0 or report.coverage.heldout==0 then fail('evaluation_splits_required') end
 local authority_ok,authorized,authority_ref=pcall(policy.source_authority.check,copy(candidate.manifest.sources),copy(candidate.manifest.capabilities),candidate.source_hash)
 if not authority_ok or authorized~=true or not text(authority_ref) then fail('source_authority_unverified') end
 report.evidence_refs.source_authority={id=policy.source_authority.id,revision=policy.source_authority.revision,evidence_ref=authority_ref}
 for _,example in ipairs(dataset.examples)do
  if example.split~='train' then
   if type(example.context)~='table' or type(example.applicable)~='boolean' or not ({fresh=true,recorded=true})[example.mode] or not text(example.evidence_ref) then fail('example_invalid') end
   report.evidence_refs.examples[#report.evidence_refs.examples+1]=example.evidence_ref
   local label=example.applicable and 'applicable' or 'inapplicable'
   report.coverage[label]=report.coverage[label]+1
   local outcome={id=example.id,split=example.split,mode=example.mode,_example=example,verifiers={}}
   report.outcomes[#report.outcomes+1]=outcome
   -- No expected labels, verifier inputs or recorded outputs enter selection.
   local ok,selected=pcall(policy.applicability.check,copy(example.context,true),{id=example.id,task=example.task,session=example.session,variant=example.variant})
   outcome.selected=selected==true
   if not ok or type(selected)~='boolean' then reason(report,'applicability_error') end
   if outcome.selected~=example.applicable then
    report.regressions.wrong_applicability=report.regressions.wrong_applicability+1
    local key=outcome.selected and 'applicability_false_positive' or 'applicability_false_negative'
    report.regressions[key]=report.regressions[key]+1;reason(report,'wrong_applicability')
   end
   if example.mode=='recorded' then
    report.coverage.recorded=report.coverage.recorded+1;reason(report,'recorded_evidence_only')
   else report.coverage.fresh=report.coverage.fresh+1 end
   if outcome.selected then
    report.coverage.selected=report.coverage.selected+1
    local observed
    if example.mode=='fresh' then
     observed=execute(candidate,example,policy);report.coverage.executed=report.coverage.executed+1
     if example.split=='heldout' and example.applicable then report.coverage.fresh_heldout=report.coverage.fresh_heldout+1 end
    else
     if type(example.recorded)~='table' or example.recorded.source_hash~=candidate.source_hash or type(example.recorded.observation)~='table' then fail('recorded_evidence_invalid') end
     observed=copy(example.recorded.observation)
     if not statuses[observed.status] or type(observed.calls)~='table' then fail('recorded_evidence_invalid') end
    end
    outcome.observation=observed
    local verified=observed.status=='succeeded'
    local wrong_recipient=false
    local duplicate_count,duplicates_known=0,false
    for _,verifier in ipairs(policy.verifiers)do
     local vok,verdict=pcall(verifier.verify,copy(observed),copy(example.expected),{id=example.id,mode=example.mode,source_hash=candidate.source_hash})
     if not vok or type(verdict)~='table' or type(verdict.passed)~='boolean' then verdict={passed=false,error='verifier_error'} end
     verdict=copy(verdict);verdict.id=verifier.id;verdict.revision=verifier.revision
     outcome.verifiers[#outcome.verifiers+1]=verdict
     verified=verified and verdict.passed
     wrong_recipient=wrong_recipient or verdict.wrong_recipient==true
     if finite(verdict.duplicated_effects) and verdict.duplicated_effects%1==0 then
      duplicates_known=true;duplicate_count=math.max(duplicate_count,verdict.duplicated_effects)
     end
    end
    outcome.duplicated_effects=duplicates_known and duplicate_count or nil
    if duplicate_count>0 then reason(report,'duplicated_effects');verified=false end
    if wrong_recipient then report.regressions.wrong_recipient=report.regressions.wrong_recipient+1;verified=false;reason(report,'wrong_recipient') end
    outcome.verified=verified and example.applicable
    if not verified then
     report.regressions.failed=report.regressions.failed+1;reason(report,'verification_failed')
     if observed.status=='succeeded' then report.regressions.false_success=report.regressions.false_success+1 end
    end
    if outcome.verified then report.coverage.verified=report.coverage.verified+1 end
   else outcome.verified=not example.applicable;outcome.status='declined' end
  end
 end
 report.measurements={model_decisions={known=0,complete=true},duplicated_effects={known=0,complete=true},latency_ms={known=0,complete=true},fallback={known=0,complete=true},user_correction_ms={known=0,complete=true},usage={known={},complete=true}}
 for _,outcome in ipairs(report.outcomes)do
  local observed=outcome.observation
  local measurements=report.measurements
  if observed then
   if finite(observed.latency_ms) then measurements.latency_ms.known=measurements.latency_ms.known+observed.latency_ms else measurements.latency_ms.complete=false end
   if outcome.duplicated_effects~=nil then measurements.duplicated_effects.known=measurements.duplicated_effects.known+outcome.duplicated_effects else measurements.duplicated_effects.complete=false end
   for _,call in ipairs(observed.calls)do
    local adapter=policy.adapters[call.id]
    if not adapter or type(adapter.model)~='boolean' then measurements.model_decisions.complete=false
    elseif adapter.model then measurements.model_decisions.known=measurements.model_decisions.known+1 end
    local usage=call.outcome and call.outcome.usage
    if type(usage)~='table' then measurements.usage.complete=false else
     for key,value in pairs(usage)do
      if finite(value) then measurements.usage.known[key]=(measurements.usage.known[key] or 0)+value else measurements.usage.complete=false end
     end
    end
   end
  end
  for _,field in ipairs({'fallback','user_correction_ms'})do
   local value=outcome._example.measurements and outcome._example.measurements[field]
   if finite(value) then measurements[field].known=measurements[field].known+value else measurements[field].complete=false end
  end
 end
 if report.coverage.fresh_heldout==0 then reason(report,'fresh_heldout_required') end
 if report.coverage.selected>0 then report.coverage.applicability_precision=(report.coverage.selected-report.regressions.applicability_false_positive)/report.coverage.selected end
 report.costs=costs(dataset,report.outcomes)
 if not report.costs.complete then reason(report,'incomplete_costs') end
 if policy.require_savings and (not report.costs.complete or report.costs.savings_per_task<=0 or report.costs.candidate.total_at_horizon>report.costs.baseline.total_at_horizon) then reason(report,'cost_gate_failed') end
end
function M.run(candidate,dataset,policy)
 local report={schema_version=1,eligibility=true,reasons={},_reasons={},outcomes={},coverage={train=0,validation=0,heldout=0,fresh=0,recorded=0,executed=0,selected=0,verified=0,fresh_heldout=0,applicable=0,inapplicable=0,runtime='isolated-compiler-subset-v1',production_runtime_qualified=false},costs={complete=false,unknowns={'not_evaluated'}},regressions={wrong_recipient=0,false_success=0,wrong_applicability=0,applicability_false_positive=0,applicability_false_negative=0,failed=0},evidence_refs={}}
 local ok,why=pcall(run,candidate,dataset,policy,report)
 if not ok then reason(report,type(why)=='table' and why.code or 'invalid_input') end
 for _,outcome in ipairs(report.outcomes)do outcome._example=nil end
 report._reasons=nil
 return report
end
return M
