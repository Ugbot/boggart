local Events=require 'providerevents'
local e=Events.new('claude')
local function apply(name,stamp,extra)
  local event={hook_event_name=name,session_id='one'}
  for k,v in pairs(extra or {})do event[k]=v end
  return e:apply(event,stamp)
end
assert(apply('SessionStart',1));assert(e.status.state=='idle')
assert(apply('UserPromptSubmit',2));assert(e.status.state=='running')
assert(not apply('Stop',1),'older hook cannot overwrite a newer report')
assert(apply('PermissionRequest',3));assert(e.status.state=='waiting_for_approval' and e.status.attention)
assert(not e.status.capabilities and not e.status.request,'a report grants no response authority')
assert(apply('PostToolUse',4));assert(e.status.state=='running' and not e.status.attention)
assert(not apply('Stop',5,{agent_id='child'}),'subagent cannot overwrite root status')
assert(not apply('SessionStart',5,{agent_id='child',session_id='child-session'}),'subagent start cannot rebind root identity')
assert(apply('Stop',6));assert(e.status.state=='idle' and e.status.attention)
assert(e:poll() and not e:poll(),'only changed observations publish')
assert(apply('SessionStart',7,{session_id='two'}));assert(e.status.session_id=='two')
assert(not apply('UserPromptSubmit',8),'retired session cannot update current status')
assert(not apply('SessionStart',9),'old session cannot rebind')
assert(apply('StopFailure',10,{session_id='two'}));assert(e.status.state=='idle' and e.status.attention)
assert(apply('SessionEnd',11,{session_id='two'}));assert(e.status.state=='alive','session end is not process exit')
assert(not apply('Stop',12,{session_id='two'}),'ended session does not revive')
for _,bad in ipairs{{},{hook_event_name='Stop',session_id='bad\0id'}}do assert(not e:apply(bad,13))end
assert(not Events.new('custom'):apply({hook_event_name='Stop',session_id='x'},1))
local Fleet=require 'fleet';local json=require 'json';local clock=0
local registry=Fleet.new{prefix='events',max_records=8}
local service=require('manualfleet').new{registry=registry,clock=function()return clock end}
local pane=service:pane{focus=function()return true end,alive=function()return true end}
local other=service:pane{focus=function()return true end,alive=function()return true end}
local function request(path,body,p)
  p=p or pane;body.pane=p.id;body.pane_token=p.token
  local code,text=service:handle{authenticated=true,remote='unix',method='POST',path='/bmux/agents/'..path,body=json.encode(body)}
  return code,json.decode(text)
end
local code,registered=request('register',{provider='claude',name='Claude fixture'});assert(code==201)
local rec=registry.agents[registered.agent_id]
local report={agent_id=rec.id,event_token=registered.event_token,provider='claude',stamp=1,
  event={hook_event_name='SessionStart',session_id='root'}}
assert(request('notify',report)==200 and rec.state=='idle' and rec.reported_event=='SessionStart')
assert(request('heartbeat',{agent_id=rec.id,lease=registered.lease,pid=42})==200 and rec.state=='idle','liveness does not erase provider phase')
assert(request('notify',report,other)==403,'cross-pane event rejected')
assert(request('heartbeat',{agent_id=rec.id,lease=registered.event_token})==403,'event capability is not a process lease')
assert(request('finish',{agent_id=rec.id,lease=registered.event_token,exit_status=0,term_signal=0})==403)
report.event_token=registered.lease;assert(request('notify',report)==403,'process lease is not an event capability')
report.event_token=registered.event_token;report.provider='codex';assert(request('notify',report)==403)
report.provider='claude';assert(request('notify',report)==409,'same stamp is rejected')
report.stamp=2;report.event.hook_event_name='PermissionRequest';assert(request('notify',report)==200 and rec.attention)
assert(registry:control(rec.id,1,'focus') and not rec.attention)
assert(request('heartbeat',{agent_id=rec.id,lease=registered.lease})==200 and not rec.attention,'heartbeat cannot restore acknowledged attention')
clock=5;service:expire();assert(rec.state=='unreachable')
assert(request('heartbeat',{agent_id=rec.id,lease=registered.lease})==200 and rec.state=='alive','lost reporting does not restore an old phase')
assert(request('finish',{agent_id=rec.id,lease=registered.lease,exit_status=0,term_signal=0})==200 and rec.state=='exited')
report.stamp=3;assert(request('notify',report)==403,'finished capability cannot resurrect process history')
local managed=registry:register{provider='claude',name='Managed'}
local binding=service:observe(managed,pane)
assert(request('heartbeat',{agent_id=managed.id,lease=binding.event_token})==403,'managed observer cannot claim process ownership')
report.agent_id=managed.id;report.event_token=binding.event_token;report.stamp=4
report.event.hook_event_name='SessionStart';assert(request('notify',report)==200 and managed.state=='idle')
clock=100;service:expire();assert(managed.state=='idle','native managed runtime does not require a wrapper heartbeat')
service:revoke(pane.id);assert(not managed.retired,'native adapter keeps ownership after observer revocation')
report.stamp=5;assert(request('notify',report)==403)
print('providerevents: reported phases, attention, ordering, session identity and subagent isolation pass')
return 0
