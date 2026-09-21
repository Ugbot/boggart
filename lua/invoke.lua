-- Common admission boundary. Host APIs below are deliberately absent from tool_env.
local M = {}
local evidence=require("evidence")
local evidence_active=setmetatable({}, {__mode="k"})
local contexts = setmetatable({}, {__mode='k'})
local active = setmetatable({}, {__mode='k'})
local resumed = setmetatable({}, {__mode="k"})
local bindings = setmetatable({}, {__mode="k"})
local blocked_ledgers=setmetatable({}, {__mode="k"})
local serial = 0
local prefix = tostring({}):gsub('table: ', '') .. ':' .. tostring(os.time())
local function key() return coroutine.running() end
local function copy(t, seen)
  if type(t) ~= 'table' then return t end
  seen=seen or {}; if seen[t] then return seen[t] end
  local r = {}; seen[t]=r; for k,v in pairs(t) do r[k] = copy(v,seen) end; return r
end
local function same(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~="table" then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function intersect(a,b)
  if a==nil then return b end
  if b==nil or a==b then return a end
  local state=contexts[a]
  if state and (state.parent==b or state.extra==b) then return a end
  local h={}; contexts[h]={parent=a,extra=b,state={mode="auto"}}; return h
end
function M.current()
  local co=key()
  -- A suspended gate can restore a pre-yield local snapshot on return. Keep
  -- restrictions acquired on resume in a separate monotone coroutine floor.
  active[co]=intersect(active[co],resumed[co])
  return active[co]
end
-- Context handles are opaque; children retain every ancestor restriction.
function M.context(options, parent)
  options = options or {}
  local handle = {}
  local st = options.state or require('perm').state()
  local legacy = {}
  for _,k in ipairs({'mode','approve_all','tool_policy','rules','guards','agent_rules','headless'}) do
    legacy[k] = copy(st[k])
  end
  local policy = options.policy or st.policy
  local invalid
  if not policy and (options.policy_scopes or st.policy_scopes) then
    policy, invalid = require('policy').compile(options.policy_scopes or st.policy_scopes)
  end
  contexts[handle] = {parent=parent or M.current(), state=legacy, policy=policy,
    source=st, invalid=invalid, ledger=options.ledger or st.ledger, approve=options.approve,
    allow=copy(options.allow), estimate=options.estimate, actual=options.actual}
  return handle
end
function M.inherit(co, context)
  local workflow=package.loaded.workflow
  if workflow and workflow.inherit then workflow.inherit(co) end
  evidence_active[co]=evidence_active[key()]
  active[co]=intersect(active[co],context or M.current())
  resumed[co]=intersect(resumed[co],active[co])
end
local function resume_context(co)
  resumed[co]=intersect(intersect(resumed[co],active[co]),M.current())
  active[co]=intersect(active[co],resumed[co])
end
function M.resume(co,...)
  if type(co)=="thread" then resume_context(co) end
  return coroutine.resume(co,...)
end
function M.close(co)
  if type(co)=="thread" then resume_context(co) end
  return coroutine.close(co)
end
function M.with_context(context, fn, ...)
  assert(contexts[context], 'invalid invocation context')
  local k, old = key(), M.current()
  local joined={}; contexts[joined]={parent=context,extra=old,state={mode="auto"}}
  active[k] = joined
  local result = table.pack(pcall(fn, ...))
  local hook,mask,count=debug.gethook(); debug.sethook()
  active[k] = old
  debug.sethook(hook,mask,count)
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
end
-- Called by the trusted registry during module initialization/reload.
function M.bind(owner, resolver, runner, format_result, execution_receipts)
  assert(not bindings[owner], "registry generation already bound")
  bindings[owner]={resolve=resolver,dispatch=runner,format_result=format_result,execution_receipts=execution_receipts}
end
-- Trusted host adapter construction only; absent from generated environments.
function M.adapter(owner, name)
  local binding=assert(bindings[owner], "unknown registry generation")
  return function() return binding.resolve(name) end,
    function(args, execution) return binding.dispatch(name,args,execution) end
end
local function failure(code, message) return {code=code, message=tostring(message), retryable=false} end
local function chain(context)
  local out, seen = {}, {}
  local function add(c)
    if c == nil or seen[c] then return end
    local s = contexts[c]; if not s then error('invalid invocation context') end
    seen[c] = true; add(s.parent); add(s.extra); out[#out+1] = s
  end
  add(M.current()); add(context)
  return out
end
-- Persist restrictions, never executable authority. Unsupported accounting closures
-- cannot be reconstructed honestly and make durable opt-in fail closed.
function M.durable_restrictions(context)
  assert(contexts[context], 'durable authority required')
  local out={}
  local states=chain(context)
  states[#states+1]=contexts[M.context({state=require('perm').state()})]
  for _,s in ipairs(states) do
    assert(not s.invalid and not s.blocked and not s.estimate and not s.actual,
      'durable authority unsupported')
    local ledger=s.ledger and assert(require('quota').identity(s.ledger),'durable ledger unsupported')
    out[#out+1]={state=copy(s.state),allow=copy(s.allow),ledger=ledger,
      scopes=s.policy and require('policy').describe(s.policy).scopes or nil}
    if s.source then
      local live={}
      for _,k in ipairs({'mode','approve_all','tool_policy','rules','guards','agent_rules','headless'}) do live[k]=copy(s.source[k]) end
      local policy=s.source.policy or (s.source.policy_scopes and assert(require('policy').compile(s.source.policy_scopes)))
      out[#out+1]={state=live,ledger=ledger,scopes=policy and require('policy').describe(policy).scopes or nil}
    end
  end
  return out
end
function M.restrict_durable(current, restrictions)
  assert(contexts[current], 'current host authority required')
  local authority=current
  local states=chain(current)
  for _,r in ipairs(restrictions) do
    local ledger
    if r.ledger then
      for _,s in ipairs(states) do
        if s.ledger and same(require('quota').identity(s.ledger),r.ledger) then ledger=s.ledger;break end
      end
      assert(ledger,'durable ledger identity unavailable')
    end
    authority=M.context({state=r.state,allow=r.allow,policy_scopes=r.scopes,ledger=ledger},authority)
  end
  return authority
end
function M.call(context, name, args, options)
  options = options or {}
  if args==nil then args={} end
  args=copy(args)
  if context == nil then context = M.current() or M.context() end
  serial = serial + 1
  local id = evidence.id('invocation')
  local events, perm = require('events'), require('perm')
  local reservations = {}
  local revisions = {}
  local old, k = M.current(), key()
  local raised
  local workflow=package.loaded.workflow
  local correlation=workflow and workflow.current() or {}
  correlation=correlation or {}
  local parent_evidence=evidence_active[k]
  correlation.run_id=correlation.run_id or (parent_evidence and parent_evidence.run_id)
  correlation.parent_id=parent_evidence and parent_evidence.invocation_id or correlation.step_id
  correlation.correlation_id=id
  local span=evidence.begin("invocation",correlation,{name=name,args=args,operation_id=options.operation_id or id})
  local prior_evidence=evidence_active[k];evidence_active[k]={run_id=span.run_id,invocation_id=id}
  local receipt={invocation_id=id,operation_id=options.operation_id or id,id=name,dispatched=false,status="failed",usage={}}
  local execution_meta, dispatched_descriptor
  local entry_hook=debug.gethook()
  -- Explicit contexts cannot replace an active ancestor.
  local states
  local ok, result, err = pcall(function()
    if not span.event_id and span.error~="evidence_disabled" then return nil,failure("evidence_unavailable","Durable invocation start could not be recorded") end
    local joined={}; contexts[joined]={parent=context,extra=old,state={mode="auto"}}
    active[k]=joined
    events.emit('tool:before', {name=name, input=copy(args), invocation_id=id})
    states = chain(joined)
    -- Surface-local state is never a substitute for current global restrictions.
    local global_state=perm.state()
    local has_global=false
    for _,s in ipairs(states) do if s.source==global_state then has_global=true end end
    if not has_global then states[#states+1]=contexts[M.context({state=global_state})] end
    local binding=bindings[options.registry or require("tools")]
    local descriptor = binding and binding.resolve(name)
    if not descriptor then return nil, failure('tool_not_found','unknown tool: '..tostring(name)) end
    receipt.version=descriptor.version; receipt.target=descriptor.target; receipt.effect=descriptor.effect
    dispatched_descriptor=descriptor
    if descriptor.validate_input then
      local valid,why=descriptor.validate_input(args)
      if valid~=true then return nil,failure("input_validation",why) end
    end
    local adapter_estimate
    if options.reuse then
      adapter_estimate={}
      for metric in pairs(descriptor.bounded or {}) do adapter_estimate[metric]=0 end
    else
      local estimator=options.reconcile and descriptor.reconcile_estimate or descriptor.estimate
      adapter_estimate=estimator and estimator(copy(args)) or {}
    end
    adapter_estimate=copy(adapter_estimate); adapter_estimate.calls=1
    local asks, policies = {}, {}
    if binding.execution_receipts and (descriptor.requires_approval or descriptor.effect=="unknown") then
      asks[#asks+1]={mandatory=true,why="capability requires approval"}
    end
    local approver
    for _,s in ipairs(states) do
      if s.approve then approver=s.approve end
      if s.blocked then return nil,failure("permission_error","enclosing invocation failed") end
      if s.invalid then return nil, failure('permission_error',s.invalid) end
      if s.allow and not require('tools').allowed(s.allow,name) then
        return nil, failure('permission_error','tool is not permitted for this agent')
      end
      local legacy_name=descriptor.legacy_name or name
      local legacy_args=descriptor.legacy_args and descriptor.legacy_args(args) or args
      local verdict, why = perm.decide(legacy_name,legacy_args,s.state)
      -- Live host revocations narrow a pinned snapshot; later grants never widen it.
      if s.source then
        local live={}; for a,b in pairs(s.source) do if a~="policy" and a~="policy_scopes" then live[a]=b end end
        local latest,reason=perm.decide(legacy_name,legacy_args,live)
        verdict=perm.stricter(verdict,latest); why=reason or why
        if s.source.policy or s.source.policy_scopes then
          local current=s.source.policy or require("policy").compile(s.source.policy_scopes)
          if not s.policy or not same(require("policy").describe(s.policy),require("policy").describe(current)) then
            return nil,failure("policy_changed","live policy changed; acquire a new host context")
          end
          local latest_policy=require("policy").decide(current,descriptor,args)
          if latest_policy.verdict=="deny" then verdict="deny" end
          if latest_policy.verdict=="ask" then asks[#asks+1]={mandatory=true,why="live policy requires approval"} end
        end
      end
      if verdict == 'deny' then return nil, failure('permission_error',why or 'permission denied') end
      if verdict == 'ask' then asks[#asks+1]={state=s.state,why=why,name=legacy_name} end
      if s.policy then
        local estimate = copy(adapter_estimate)
        if s.estimate then for metric,amount in pairs(s.estimate(name,args)) do estimate[metric]=math.max(estimate[metric] or 0,amount) end end
        estimate.calls=1
        local decision = require('policy').decide(s.policy,descriptor,args,estimate)
        revisions[#revisions+1]=decision.policy_revision
        if decision.verdict == 'deny' then
          return nil,failure('permission_error',table.concat(decision.reasons,'; '))
        end
        if decision.verdict == 'ask' then asks[#asks+1]={mandatory=true,why='policy requires approval'} end
        policies[#policies+1]={state=s,estimate=estimate,decision=decision}
      end
    end
    local veto = events.ask('tool:authorize',{name=name,tool=name,input=copy(args),invocation_id=id},{fail_closed=true})
    if veto == 'deny' or type(veto)=='table' and veto.deny then
      return nil,failure('permission_error',type(veto)=='table' and veto.reason or 'authorization hook refused call')
    end
    local approved
    if #asks>0 then
      if approver then approved=approver(name,copy(args),asks[1].why)==true
      else
        approved=true
        for _,ask in ipairs(asks) do
          if ask.mandatory or perm.headless_decision(ask.name or name,ask.state)=='deny' then approved=false end
        end
      end
      if not approved then return nil,failure('permission_error','approval required or rejected') end
    end
    -- Approval/authorization callbacks may yield. Recheck live restrictions
    -- and extract resources again at the actual effect boundary, without a
    -- second event or approval prompt.
    if perm.state()~=global_state then
      return nil,failure("policy_changed","global permission state changed during admission")
    end
    for _,s in ipairs(states) do
      if s.source then
        local live={}
        for a,b in pairs(s.source) do
          if a~="policy" and a~="policy_scopes" and a~="recent" then live[a]=b end
        end
        local legacy_name=descriptor.legacy_name or name
        local legacy_args=descriptor.legacy_args and descriptor.legacy_args(args) or args
        local verdict,why=perm.decide(legacy_name,legacy_args,live)
        if verdict=="deny" then return nil,failure("permission_error",why or "permission revoked during admission") end
        if verdict=="ask" and not approved and perm.headless_decision(legacy_name,live)=="deny" then
          return nil,failure("permission_error","approval requirements changed during admission")
        end
        if s.source.policy or s.source.policy_scopes then
          local current=s.source.policy or require("policy").compile(s.source.policy_scopes)
          if not s.policy or not same(require("policy").describe(s.policy),require("policy").describe(current)) then
            return nil,failure("policy_changed","live policy changed during admission")
          end
        end
      end
    end
    for _,p in ipairs(policies) do
      local latest=require("policy").decide(p.state.policy,descriptor,args,p.estimate)
      if latest.verdict=="deny" then return nil,failure("permission_error",table.concat(latest.reasons,"; ")) end
    end
    -- Reserve the entire inherited quota set in ONE ledger transaction.
    local scopes, seen, ledger, estimate, accountant = {}, {}, nil, copy(adapter_estimate), nil
    local ceilings={}
    local bounded=binding.execution_receipts and ((options.reconcile and descriptor.reconcile_bounded) or ((not options.runner or options.reuse) and descriptor.bounded)) or {}
    local function equal(a,b)
      if type(a)~=type(b) then return false end
      if type(a)~="table" then return a==b end
      for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
      for k in pairs(b) do if a[k]==nil then return false end end
      return true
    end
    for _,p in ipairs(policies) do
      local obligations=p.decision.obligations
      local function require_bound(metric,limit)
        if metric=="calls" then return true end
        if not bounded[metric] then return nil,failure("unsupported_limit","runner cannot enforce "..metric.." ceiling") end
        local amount=p.estimate[metric]
        if type(amount)~="number" or amount<0 or amount~=amount or amount>9007199254740991 then
          return nil,failure("invalid_estimate","bounded estimate required for "..metric)
        end
        ceilings[metric]=math.min(ceilings[metric] or math.huge,amount,limit or math.huge)
        return true
      end
      for metric,limit in pairs(obligations.limits) do
        local valid,why=require_bound(metric,limit); if valid~=true then return nil,why end
      end
      for _,quota in ipairs(obligations.quotas) do
        local valid,why=require_bound(quota.metric); if valid~=true then return nil,why end
      end
      if #obligations.quotas>0 or next(obligations.limits) then
        if not p.state.ledger then return nil,failure('quota_unavailable','quota ledger required') end
        if ledger and ledger~=p.state.ledger then return nil,failure('quota_authority','multiple quota ledgers are unsupported') end
        ledger=p.state.ledger
        accountant=accountant or p.state
        for metric,amount in pairs(p.estimate) do estimate[metric]=math.max(estimate[metric] or 0,amount) end
        for _,scope in ipairs(require("policy").describe(p.state.policy).scopes) do
          if seen[scope.id] and not equal(seen[scope.id],scope) then
            return nil,failure("policy_conflict","conflicting revisions of inherited scope "..scope.id)
          end
          if not seen[scope.id] then scopes[#scopes+1]=scope; seen[scope.id]=scope end
        end
      end
    end
    for metric,amount in pairs(ceilings) do estimate[metric]=amount end
    local current_descriptor=binding.resolve(name)
    if not current_descriptor then return nil,failure("capability_changed","capability removed during admission") end
    for _,field in ipairs({"id","version","effect","_entry","_runner","_body","_resources"}) do
      if descriptor[field]~=current_descriptor[field] then
        return nil,failure("capability_changed","capability changed during admission")
      end
    end
    if ledger then
      if blocked_ledgers[ledger] then return nil,failure("quota_uncertain","quota authority requires accounting recovery") end
      local combined,ce=require("policy").compile(scopes)
      if not combined then return nil,failure("policy_conflict",ce) end
      local reservation_id=options.operation_id and not options.reconcile and not options.reuse and options.operation_id or id
      receipt.reservation_id=reservation_id
      local receipt,re=ledger:reserve(combined,reservation_id,estimate)
      if not receipt then return nil,re end
      if receipt.replayed then return nil,failure('replayed','reservation already exists; recovery required') end
      reservations[1]={ledger=ledger,id=receipt.id,state=accountant}
    end
    -- Trusted bounded adapters must enforce every supplied ceiling at the
    -- provider boundary; estimates are reservations, never enforcement alone.
    local admission_event,admission_error=evidence.append{run_id=span.run_id,step_id=span.step_id,parent_id=id,correlation_id=id,
      kind="invocation.admitted",payload={decision="allow",policy_revisions=revisions,descriptor={id=descriptor.id,version=descriptor.version,target=descriptor.target,effect=descriptor.effect},ceilings=ceilings}}
    if not admission_event and admission_error~="evidence_disabled" then return nil,failure("evidence_unavailable","Durable admission could not be recorded") end
    receipt.dispatched=true
    local value,metadata = (options.runner or binding.dispatch)(name,args,
      {invocation_id=id,operation_id=options.operation_id or id,ceilings=copy(ceilings),target=descriptor.target})
    if binding.execution_receipts then
      execution_meta=metadata or {status="succeeded"}
      receipt.usage=copy(execution_meta.usage or {})
      receipt.artifacts=copy(execution_meta.artifacts)
      receipt.execution=copy(execution_meta.receipt)
      receipt.status=execution_meta.status
      -- Retain authoritative usage before validating user output. A throwing
      -- validator (including an enclosing debug hook) exits through this gate's
      -- existing exception cleanup, which still settles the retained usage.
      if receipt.status=="succeeded" and descriptor.validate_output then
        local valid,why=descriptor.validate_output(value)
        if valid~=true then
          receipt.status="failed"; execution_meta.status="failed"
          execution_meta.error=failure("output_validation",why)
        end
      end
      for metric,ceiling in pairs(ceilings) do
        local actual=receipt.usage[metric]
        if receipt.status=="succeeded" and actual==nil then
          return nil,failure("usage_missing","adapter omitted actual usage for "..metric)
        end
        if actual and actual>ceiling then return nil,failure("quota_overrun","adapter exceeded enforced ceiling for "..metric) end
      end
      if receipt.status~="succeeded" then
        local e=execution_meta.error or {}
        return nil,failure(e.code or receipt.status,e.message or receipt.status)
      end
    end
    if options.legacy_string then value=(binding.format_result or tostring)(value) end
    if type(value)=='string' and value:find('^Tool error:') then
      return nil,failure(value:match('^Tool error: %[(.-)%]') or 'runtime_error',value)
    end
    return value
  end)
  -- Cleanup runs outside the caller's hook: an exhausted outer budget must not
  -- interrupt context restoration, settlement or the terminal notification.
  local hook,mask,count = debug.gethook(); debug.sethook()
  if not ok then raised=result; err=failure('runtime_error',result); result=nil end
  if err then
    local effect=dispatched_descriptor and dispatched_descriptor.effect
    local uncertain=receipt.dispatched and (effect=="write" or effect=="unknown")
      and not (execution_meta and execution_meta.effect_disproven==true)
    receipt.status=uncertain and "uncertain" or (execution_meta and execution_meta.status=="cancelled" and "cancelled" or "failed")
    if execution_meta and execution_meta.status=="uncertain" then receipt.status="uncertain" end
  else receipt.status="succeeded" end
  for _,r in ipairs(reservations) do
    local settled, receipt, se = pcall(function()
      local actual=execution_meta and receipt.usage or (r.state.actual and r.state.actual(name,args,result,err) or {})
      return r.ledger:settle(r.id,actual,receipt.status=="uncertain" and "uncertain" or (err and 'failure' or 'success'))
    end)
    if not settled or not receipt or receipt.overrun then
      blocked_ledgers[r.ledger]=true
      err=failure('quota_settlement',not settled and receipt or se and se.message or 'quota overrun'); result=nil
    end
  end
  if err and (err.code=="usage_missing" or err.code=="quota_overrun") then
    for _,r in ipairs(reservations) do blocked_ledgers[r.ledger]=true end
  end
  if err and receipt.status=="succeeded" then
    local effect=dispatched_descriptor and dispatched_descriptor.effect
    receipt.status=receipt.dispatched and (effect=="write" or effect=="unknown") and "uncertain" or "failed"
  end
  if perm.GATED[name] and bog and bog.telemetry then
    local aid=bog.sched and bog.sched.current and bog.sched.current()
    local rec=aid and bog.thread and bog.thread.live_recs and bog.thread.live_recs[aid]
    pcall(bog.telemetry.decision,{run_id=rec and rec.run_id or aid,agent_id=aid},
      {tool=name,decision=err and "deny" or "allow",invocation_id=id})
  end
  local terminal_event,capture_error=evidence.finish(span,{result=result,result_type=type(result),error=err,receipt=receipt,
    policy={decision=receipt.dispatched and "admitted" or "not_dispatched",revisions=revisions}})
  receipt.evidence={run_id=span.run_id,start_event_id=span.event_id,terminal_event_id=terminal_event,
    coverage=span.event_id and terminal_event and "observed" or "incomplete",error=capture_error or span.error}
  evidence_active[k]=prior_evidence
  -- Terminal observers keep the call's authority. A failed/budget-exhausted
  -- invocation cannot launch fresh effects while delivering its terminal record.
  local terminal={}; contexts[terminal]={parent=active[k] or context,state={mode="auto"},blocked=err~=nil}
  active[k]=terminal
  if not err then debug.sethook(hook,mask,count) end
  local observed, observation_error = pcall(events.emit,'tool:after',
    {name=name,invocation_id=id,policy_revisions=revisions,error=err~=nil,code=err and err.code,status=receipt.status,dispatched=receipt.dispatched,bytes=type(result)=='string' and #result or 0})
  debug.sethook()
  active[k]=old
  debug.sethook(hook,mask,count)
  if not ok then
    -- Preserve BRAIN-14's sticky enclosing hook failure across tools.run's adapter.
    if entry_hook then
      if old==nil and type(raised)=='table' and raised.error~=nil then error(raised.error,0) end
      error(raised,0)
    end
  end
  if not observed then error(observation_error,0) end
  return result,err,receipt
end
function M.string(context,name,args,options)
  local legacy={}; for k,v in pairs(options or {}) do legacy[k]=v end
  legacy.legacy_string=true
  local result,err=M.call(context,name,args,legacy)
  if err then
    if err.message:find('^Tool error:') then return err.message end
    return 'Tool error: ['..err.code..'] '..err.message
  end
  return result
end
return M
