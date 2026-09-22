-- Authored source package: register exact bytes with durable='replay-v1'.
-- See docs/examples/slack-followup.md for the required host atomicity contract.
local function segment(s) assert(type(s)=='string' and #s>0);return #s..':'..s end
local function identity(c)
 return segment(c.campaign)..segment(c.cohort)..segment(c.period)
end
local function run(ctx)
 local c=assert(ctx:resolve('config'))
 local key=identity(c)
 assert(type(c.channel)=='string' and type(c.report_target)=='string' and type(c.reminder)=='string')
 assert(type(c.now)=='number' and c.window.start<c.window.finish and c.now>=c.window.finish)
 assert(c.policy.ambiguous=='hold' and (c.policy.ignored=='hold' or c.policy.ignored=='remind'))
 assert(c.policy.max_model_calls>=0 and c.policy.max_model_calls<=16 and c.policy.max_model_calls%1==0)
 assert(c.policy.max_tokens>=1 and c.policy.max_tokens<=4096 and c.policy.max_tokens%1==0)
 local count=0
 for index in pairs(c.expected) do
  assert(type(index)=='number' and index%1==0 and index>=1,'dense participant sequence required');count=count+1
 end
 for index=1,count do assert(c.expected[index]~=nil,'dense participant sequence required') end
 local expected,seen={},{}
 for _,id in ipairs(c.expected) do
  segment(id);assert(not seen[id],'duplicate recipient');seen[id]=true;expected[#expected+1]=id
 end
 assert(#expected>0 and #expected<=1000);table.sort(expected)
 local intent={channel=c.channel,expected=expected,window=c.window,reminder=c.reminder,
  report_target=c.report_target,policy=c.policy,model_provider=c.model_provider,capabilities=c.capabilities}
 local function call(role,args,optional)
  return ctx:step(role,function()return ctx:call(assert(c.capabilities[role]),args,{required=not optional})end)
 end
 local function required(role,args)
  local o=call(role,args);assert(o.status=='succeeded',role..' unavailable');return o.result,o.receipt
 end
 local bound=required('bind',{key=key,intent=intent})
 assert(bound.accepted,'campaign intent conflict')
 local report={campaign=c.campaign,cohort=c.cohort,period=c.period,channel=c.channel,window=c.window,
  observed_at=c.now,rows={},counts={},model_calls=0,complete=false,receipts={}}
 local function progress()return required('progress',{key=key,report=report}) end
 local function source(recipient)
  local result=required('source',{channel=c.channel,window=c.window,expected=expected,recipient=recipient,now=c.now})
  assert(type(result)=='table','invalid source')
  return result
 end
 local snapshot=source()
 report.provenance=snapshot.provenance
 local function interpret(state)
  if state.kind~='ambiguous' then return state.kind end
  -- Reserve a model call for the optional narrative. Unknown never authorizes send.
  if report.model_calls>=c.policy.max_model_calls-1 then return 'ambiguous' end
  report.model_calls=report.model_calls+1
  local o=call('model',{task='interpret',provider=c.model_provider,text=state.text,max_tokens=c.policy.max_tokens},true)
  if o.status=='succeeded' and type(o.result)=='table' and o.result.classification=='replied' then return 'replied' end
  return 'ambiguous'
 end
 for _,recipient in ipairs(expected) do
  local row={recipient=recipient,status='unavailable'};report.rows[#report.rows+1]=row
  if snapshot.available then
   local state=snapshot.people and snapshot.people[recipient]
   if state then
    row.status=interpret(state)
    if row.status=='missing' or row.status=='ignored' and c.policy.ignored=='remind' then
     -- This read is evidence; ONLY the host conditional send closes the race.
     local fresh=source(recipient)
     local latest=fresh.available and fresh.people and fresh.people[recipient]
     if not latest then row.status='unavailable'
     elseif latest.kind=='replied' or latest.kind=='opted_out' then row.status=latest.kind
     elseif latest.kind~='missing' and not (latest.kind=='ignored' and c.policy.ignored=='remind') then row.status=latest.kind=='ambiguous' and 'ambiguous' or 'pending'
     elseif fresh.atomic_conditional_send~=true then row.status='pending';row.reason='conditional_send_unavailable'
     else
      row.status='pending';row.operation_id=key..segment(recipient);progress()
      local outcome=call('send',{key=row.operation_id,intent=intent,recipient=recipient,channel=c.channel,
       window=c.window,revision=latest.revision,reminder=c.reminder},true)
      report.receipts[#report.receipts+1]=outcome.receipt
      if outcome.status=='succeeded' and type(outcome.result)=='table' then
       local effect=outcome.result
       local allowed={confirmed=true,pending=true,uncertain=true,failed=true,denied=true,replied=true,opted_out=true}
       row.status=allowed[effect.status] and effect.status or 'uncertain';row.reason=effect.reason;row.receipt=effect.receipt
      else
       local permission=outcome.error and (outcome.error.code=='permission_error' or outcome.error.code=='policy_changed')
       row.status=(outcome.status=='denied' or permission) and 'denied' or outcome.status=='uncertain' and 'uncertain' or 'failed'
      end
     end
    elseif row.status=='ignored' then row.reason='policy_hold'
    elseif row.status~='replied' and row.status~='opted_out' and row.status~='ambiguous' then row.status='pending' end
   end
  end
  progress()
 end
 report.complete=true
 for _,row in ipairs(report.rows) do
  report.counts[row.status]=(report.counts[row.status] or 0)+1
  if row.status~='confirmed' and row.status~='replied' and row.status~='opted_out' then report.complete=false end
 end
 if report.model_calls<c.policy.max_model_calls then
  report.model_calls=report.model_calls+1
  local narrative=call('model',{task='report',provider=c.model_provider,rows=report.rows,counts=report.counts,max_tokens=c.policy.max_tokens},true)
  if narrative.status=='succeeded' and type(narrative.result)=='table' and type(narrative.result.text)=='string' then
   report.narrative=narrative.result.text -- Untrusted prose; never replaces factual rows/counts.
  end
 end
 local saved=progress();report.progress=saved.reference
 local artifact=required('artifact',{target=c.report_target,report=report})
 report.artifact=artifact.reference
 return report
end
return {run=run,verify=function(_,r)
 if type(r)~='table' or type(r.artifact)~='string' or type(r.progress)~='string' then return false end
 local total=0;for _,n in pairs(r.counts) do total=total+n end
 return total==#r.rows -- Host acceptance tests independently verify participant facts.
end}
