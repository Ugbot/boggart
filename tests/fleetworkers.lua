local Source=require 'tui.fleetworkers';local Mirror=require 'fleetworkers';local Fleet=require 'fleet'
bog.activate_agents()
local thread,sched=bog.thread,bog.sched
thread.live_recs={};thread.live=0;thread.max_agents=4
local root=thread.new_agent{agent='coordinator'};bog.swarm_root=root
local st={coord=root};local source=Source.new(st)
local messages={};local function poll()
  assert(source:poll(function(frame)messages[#messages+1]=frame;return true end))
end
bog.api.run_on=function(session,text)
  if text=='fail' then error('worker fixture failure')end
  if text=='hold' then while true do coroutine.yield('approve')end end
end
local fast=thread.spawn{agent='coder',parent_id=root.id,task='done'}
local hold=thread.spawn{agent='coder',parent_id=root.id,task='hold'}
local fail=thread.spawn{agent='critic',parent_id=hold,task='fail'}
sched.resume_ready();poll()
local report={};for _,message in ipairs(messages)do report[message.worker.session_id]=message.worker end
assert(report[fast].state=='exited' and report[fail].state=='failed' and report[hold].can_stop)
assert(report[fail].parent_session_id==hold and report[fail].error:find('worker fixture failure',1,true))
local old=report[fast].incarnation
local reused=thread.spawn{agent='coder',parent_id=root.id,resume_id=fast,task='hold'}
assert(reused==fast);poll()
local latest=messages[#messages].worker;assert(latest.session_id==fast and latest.incarnation~=old)
assert(not source:stop(fast,old) and sched.alive(fast),'stale incarnation cannot cancel resumed session')
assert(source:stop(fast,latest.incarnation) and not sched.alive(fast) and sched.alive(hold))
poll();assert(messages[#messages].worker.state=='stopped')
assert(thread.live==2 and thread.live_recs[hold] and not thread.live_recs[fast])
for _=1,8 do
  thread.spawn{agent='coder',parent_id=root.id,task='done'};sched.resume_ready();poll()
  assert(thread.live==2 and not thread.at_capacity(),'completed workers release their live slot')
end
thread.max_agents=64
for _=1,40 do thread.spawn{agent='coder',parent_id=root.id,task='done'}end
sched.resume_ready();local before=#messages;poll();assert(#messages-before==32)
poll();assert(#messages-before==40 and thread.live==2,'bounded report batches retain every transient worker')
local backfill=Source.new(st);local captured={}
assert(backfill:poll(function(message)captured[#captured+1]=message;return true end))
assert(#captured==1 and captured[1].worker.session_id==hold,'a live scan backfills workers already running')
backfill:close()
assert(source:stop(hold,report[hold].incarnation));poll();source:close()
do
  local old_records,old_actors,old_by_id=thread.live_recs,sched.actors,sched.by_id
  thread.live_recs={};sched.actors={};sched.by_id={}
  local bounded=Source.new(st)
  for i=1,513 do
    local id=10000+i;local actor={id=id,status='runnable'}
    thread.live_recs[id]={session={model='fixture'}};sched.by_id[id]=actor;bounded:start(id)
  end
  local sent,error=bounded:poll(function()return true end)
  assert(not sent and error=='worker reporting capacity reached' and #bounded.order==512)
  bounded:close();thread.live_recs,sched.actors,sched.by_id=old_records,old_actors,old_by_id
end

-- One roster, bounded evictable worker history, routed identity and loss state.
local registry=Fleet.new{prefix='workers',max_records=4}
local parent=registry:register{provider='boggart',name='Parent TUI',session_id=100}
local focus,cancel=0,{}
local control={command=function(_,action,payload)cancel={action=action,payload=payload};return true,'command:1'end}
local mirror=Mirror.new(registry,parent,control,function()focus=focus+1;return true end)
local function update(id,inc,state,parent_id)
  return {session_id=id,incarnation=inc,state=state,name='Worker',model='fixture',activity=state,
    parent_session_id=parent_id or 100,error=false,can_stop=state=='running'}
end
assert(mirror:apply{update(101,1,'running'),update(102,2,'exited',101)})
assert(mirror:apply{update(101.0,1.0,'running')})
assert(#registry.order==3,'numeric spelling cannot create a second worker identity')
local child;for _,rec in ipairs(registry:records())do if rec.session_id==101 then child=rec end end
assert(child.parent==parent.id and child.worker and child.model=='fixture')
assert(registry:control(child.id,1,'focus') and focus==1)
assert(registry:control(child.id,1,'stop') and cancel.action=='worker_stop' and cancel.payload.worker_incarnation==1)
assert(mirror:apply(nil,{{worker_session_id=101,worker_incarnation=1,id='command:1',accepted=false,error='stale worker runtime'}}))
assert(child.control_result.error=='stale worker runtime')
for id=103,115 do assert(mirror:apply{update(id,id,'exited')})end
assert(#registry.order==4 and registry.agents[child.id]==child,'finished history yields to new rows, live workers never evict')
local count=0;for _ in pairs(mirror.children)do count=count+1 end;assert(count<=3)
mirror:unreachable('channel lost');assert(child.state=='unreachable' and not child.capabilities.stop and child.capabilities.focus)
mirror:close('parent exited');assert(child.state=='stopped')
mirror:close('pane closed',true);assert(not child.capabilities.focus)
local compact=Fleet.new{prefix='capacity',max_records=2};local p=compact:register{name='parent'}
local bounded=Mirror.new(compact,p,control,function()return true end)
assert(bounded:apply{update(1,1,'running')})
assert(not bounded:apply{update(2,2,'running')},'live capacity failure is explicit')
assert(bounded:apply{update(1,1,'exited')})
assert(not bounded:apply{update(1,1,'running')},'terminal incarnation cannot reactivate')
print('Fleet workers: transient/failure lifecycle, nested parent, reused-session guards, live-slot cleanup, one bounded roster, routing and loss/close pass')
return 0
