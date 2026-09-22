-- Privileged, per-request recognition. Similarity only retrieves; it never admits effects.
local M={}
local decisions=setmetatable({}, {__mode='k'})
local function copy(v,seen)
 if type(v)~='table' or getmetatable(v) then return v end
 seen=seen or {};if seen[v] then return seen[v] end
 local out={};seen[v]=out;for k,x in pairs(v)do out[k]=copy(x,seen)end;return out
end
local function code(e)return type(e)=='table' and e.code or tostring(e)end
local function bounded(fn,...)
 local used=0
 local function guard()used=used+1000;if used>50000 then error('recognition_budget',0)end end
 local invoke=require('invoke')
 local pure=invoke.context{policy=assert(require('policy').compile({{id='recognition',revision='1',capabilities={allow={}}}}))}
 return require('tools').with_count_hook(guard,1000,invoke.with_context,pure,fn,...)
end
local function applicable(entry,request,binding)
 local ok,yes,ref=bounded(entry.applicability,request,copy(binding))
 return ok and yes==true and type(ref)=='string' and ref~='',ok and (ref or 'inapplicable') or 'judgment_budget_or_error'
end
function M.select(request,context,policy)
 local supplied=policy or {};policy={};for k,v in pairs(supplied)do policy[k]=v end
 if type(policy.planning)=='table' then local plan={};for k,v in pairs(policy.planning)do plan[k]=v end;policy.planning=plan end
 context=context or {}
 local evidence={schema_version=1,alternatives={},coverage={backend='local_terms',semantic=false,complete=false},cost={model_calls=0,considered=0,max_candidates=32,max_callback_instructions=50000}}
 local span=require('evidence').begin('learning_route',{scope=policy.project},{request=request})
 local function finish(result,private)
  result.evidence=evidence
  local event,err=require('evidence').finish(span,{status=result.workflow and 'selected' or 'fallback',workflow=result.workflow,version=result.version,reason=result.reason,evidence=evidence})
  evidence.event_id=event;evidence.capture_error=err
  if private then private.workflow=result.workflow;private.reason=result.reason;private.terminal=result.terminal;decisions[result]=private end
  return result
 end
 local function fallback(reason,terminal)return finish({fallback='model_planning',reason=reason,terminal=terminal}, {request=request,binding=copy(context),policy=policy})end
 if type(request)~='string' or #request>4096 or type(context)~='table' then return fallback('invalid_request',true)end
 if type(policy.project)~='string' or not policy.authority or type(policy.registry)~='table' then return fallback('routing_configuration_required',true)end
 local catalog=policy.catalog
 if type(catalog)~='table' or #catalog>32 then return fallback('retrieval_budget')end
 local memory_hits={}
 if policy.memory then
  -- The memory port is host-configured, scoped and uses its ordinary capability budgets.
  evidence.cost.memory_calls=1
  local ok,page=pcall(policy.memory.search,policy.memory,request,{scope=policy.project,limit=32,mode='text'})
  if ok and type(page)=='table' then
   evidence.coverage.memory=page.coverage;evidence.coverage.backend=page.backend
   for i,hit in ipairs(page.hits or {})do
    if i>32 then break end
    if hit.scope==policy.project and hit.source_ref then memory_hits[hit.source_ref]=true end
   end
   evidence.provenance=page.provenance
  else evidence.coverage.memory_error='unavailable' end
 end
 local matches={};local lower=request:lower()
 for _,entry in ipairs(catalog)do
  evidence.cost.considered=evidence.cost.considered+1
  local record={workflow=entry.id};evidence.alternatives[#evidence.alternatives+1]=record
  local score=entry.source_ref and memory_hits[entry.source_ref] and 1 or 0
  for i,term in ipairs(entry.terms or {})do
   if i>64 then return fallback('retrieval_budget')end
   if type(term)=='string' and #term>0 and #term<=128 and lower:find(term:lower(),1,true) then score=score+1 end
  end
  record.score=score
  if entry.scope~=policy.project then record.reason='wrong_scope'
  elseif score==0 then record.reason='no_match'
  elseif type(entry.applicability)~='function' then record.reason='applicability_required'
  else
   local binding=copy(context);local missing
   for _,key in ipairs(entry.required or {})do if binding[key]==nil then missing=key;break end end
   if missing then record.reason='missing_context';record.key=missing
   else
    local yes,reason=applicable(entry,request,binding);record.reason=yes and 'applicable' or (reason=='judgment_budget_or_error' and reason or 'inapplicable');record.applicability_evidence=reason
    if yes then matches[#matches+1]={entry=entry,binding=binding,record=record}end
   end
  end
 end
 if #matches==0 then return fallback('no_applicable_workflow')end
 if #matches>1 then return fallback('ambiguous')end
 local match=matches[1]
 local options={authority=policy.authority,scope=policy.project,context=copy(match.binding),run_id=policy.run_id or require('evidence').id('request')}
 local definition,why=policy.registry:select(match.entry.id,options)
 if not definition then
  match.record.reason=code(why)
  -- Registry authority/qualification failure is terminal; never evade it through planning.
  return fallback(code(why),true)
 end
 match.record.reason='selected'
 local private={request=request,binding=match.binding,policy=policy,entry=copy(match.entry),options=options,version=definition.version}
 return finish({workflow=match.entry.id,version=definition.version,binding=copy(match.binding)},private)
end
function M.execute(selection)
 local d=decisions[selection]
 if not d then return nil,{code='selection_required'}end
 if d.executed then return nil,{code='selection_already_executed'}end
 d.executed=true
 local p=d.policy
 if d.terminal then return nil,{code=d.reason}end
 local workflow=require('workflow')
 if d.workflow then
  local opts=copy(d.options);opts.authority=p.authority;opts.version=d.version
  local bound=copy(d.binding)
  local resolved_binding=copy(d.binding)
  local binding_denied=false
  -- Values are snapshotted; providers retain Lua behavior, and resolved values are
  -- checked before the learned body can consume them or dispatch its effects.
  for key,value in pairs(bound)do
   if type(value)=='function' or type(value)=='table' and type(value.resolve)=='function' then
    local fn=type(value)=='function' and value or value.resolve
    -- Opaque/metatable-bearing tables retain identity in copy(). A provider
    -- wrapper must always be fresh, just as workflow/context bindings are.
    local provider={}
    if type(value)=='table' then
     for field,metadata in pairs(value)do provider[field]=copy(metadata)end
    end
    provider.resolve=function(ctx,...)
     local resolved,why=fn(ctx,...)
     if resolved==nil then return nil,why end
     local next_binding=copy(resolved_binding);next_binding[key]=resolved
     local yes=applicable(d.entry,d.request,next_binding)
     if not yes then binding_denied=true;error({code='applicability_changed'},0)end
     resolved_binding[key]=copy(resolved)
     return resolved,why
    end
    bound[key]=provider
   end
  end
  opts.context=bound
  opts.admit=function()
   if binding_denied then return nil,{code='applicability_changed'}end
   local yes=applicable(d.entry,d.request,resolved_binding)
   if not yes then return nil,{code='applicability_changed'}end
   return true
  end
  return p.registry:start(d.workflow,opts)
 end
 local plan=p.planning
 if type(plan)~='table' or type(plan.capability)~='string' or type(plan.version)~='string' or type(plan.max_tokens)~='number' or plan.max_tokens~=plan.max_tokens or plan.max_tokens%1~=0 or plan.max_tokens<1 or plan.max_tokens>100000 then return nil,{code='planning_configuration_required'}end
 local policy=assert(require('policy').compile({{id='learning-planning',revision='1',limits={tokens=plan.max_tokens},capabilities={allow={plan.capability}},quotas={{id=require('evidence').id('planning-call'),metric='calls',limit=1,window_seconds=86400}}}}))
 local source=string.format([[return function(ctx)
 return ctx:step('model_planning',function()
  local result=ctx:call(%q,{request=ctx:resolve('request'),context=ctx:resolve('current'),reason=ctx:resolve('reason'),max_tokens=ctx:resolve('max_tokens')})
  return result.result
 end)
end]],plan.capability)
 local id='learning-planning:'..workflow.hash(source..plan.version)
 if not workflow.resolve(id,'1')then
  local registered,why=workflow.register{id=id,version='1',source=source,capabilities={[plan.capability]=plan.version}}
  if not registered then return nil,why end
 end
 -- Context is injected as a provider so functions remain functions until normal
 -- resolution inside this workflow; historical defaults are never supplied.
 local injected={request=d.request,reason=d.reason,max_tokens=plan.max_tokens}
 local mapping={};local n=0
 for key,value in pairs(d.binding)do n=n+1;mapping[key]='input_'..n;injected[mapping[key]]=value end
 injected.current=function(ctx)
  local out={};for key,name in pairs(mapping)do local value,why=ctx:resolve(name);if value==nil and why then error(why,0)end;out[key]=value end;return out
 end
 local authority=require('invoke').context({policy=policy,ledger=plan.ledger or p.ledger},p.authority)
 return workflow.start(id,{authority=authority,scope=p.project,context=injected,run_id=p.run_id})
end
function M.run(request,context,policy)
 local selection=M.select(request,context,policy)
 local handle,why=M.execute(selection)
 return handle,selection,why
end
return M
