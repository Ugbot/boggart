local Fleet=require 'fleet';local Manual=require 'manualfleet';local json=require 'json'
local now=0;local registry=Fleet.new{prefix='manual-test',max_records=3}
local service=Manual.new{registry=registry,clock=function()return now end}
local focused=0;local live=true
local pane=service:pane{focus=function()focused=focused+1;return true end,alive=function()return live end,cwd='/tmp'}
local other=service:pane{focus=function()return true end,alive=function()return true end}
local function call(path,fields,context)
  local body={pane=(context or pane).id,pane_token=(context or pane).token}
  for k,v in pairs(fields or {})do body[k]=v end
  local code,text=service:handle{authenticated=true,remote='unix',method='POST',path='/bmux/agents/'..path,body=json.encode(body)}
  return code,json.decode(text)
end
local code,registered=call('register',{provider='foreign',name='Foreign TUI'})
assert(code==201);local rec=assert(registry.agents[registered.agent_id])
assert(rec.manual and rec.cwd=='/tmp' and rec.pane_id==pane.id and rec.state=='starting')
assert(rec.capabilities.focus and not rec.capabilities.stop and not rec.capabilities.prompt)
assert(registry:control(rec.id,1,'focus') and focused==1)
local lease={agent_id=rec.id,lease=registered.lease,pid=123}
assert(call('heartbeat',lease)==200 and rec.state=='alive' and rec.pid==123)
assert(call('heartbeat',lease,other)==403,'cross-pane lease cannot update an agent')
assert(call('heartbeat',{agent_id=rec.id,lease='wrong'})==403)
assert(call('heartbeat',{agent_id=rec.id,lease=registered.lease,pid=-1})==400)
now=5;service:expire();assert(rec.state=='unreachable' and rec.capabilities.focus)
assert(call('heartbeat',lease)==200 and rec.state=='alive','live lease may recover after pause')
local _,page=call('list');assert(page.total==1 and #page.agents==1 and not json.encode(page):find(registered.lease,1,true))
local _,empty=call('list',nil,other);assert(empty.total==0 and #empty.agents==0)
assert(call('list',{limit=65})==400)
assert(call('finish',{agent_id=rec.id,lease=registered.lease,exit_status=7,term_signal=0})==200)
assert(rec.state=='failed' and rec.exit_status==7 and rec.capabilities.focus)
assert(call('heartbeat',lease)==403,'finished lease cannot resurrect history')
local _,second=call('register',{provider='codex',name='Manual code agent'})
local second_rec=registry.agents[second.agent_id]
live=false;service:expire()
assert(rec.retired and rec.state=='failed' and not rec.capabilities.focus)
assert(second_rec.retired and second_rec.state=='unreachable' and not second_rec.capabilities.focus,'pane loss does not assert process completion')
assert(call('heartbeat',{agent_id=second.agent_id,lease=second.lease})==403)
assert(not pcall(registry.bind,registry,second_rec.id,1,{}),'retired unknown process cannot regain controls')
for i=1,3 do assert(call('register',{provider='custom',name='history '..i},other)==201)end
-- Two retired registrations may be evicted; live registrations are bounded.
assert(#registry.order==3 and not registry.agents[rec.id] and not registry.agents[second_rec.id])
assert(call('register',{provider='custom',name='overflow'},other)==503)
assert(service:handle{authenticated=true,remote='127.0.0.1',method='GET',path='/health'}==403)
assert(service:handle{authenticated=true,remote='unix',method='POST',path='/bmux/agents/register',body='[]'}==403)
local broken=service:pane{focus=function()end,alive=function()error('closed terminal')end}
service:expire();assert(not service.panes[broken.id],'native terminal close cannot break lease sweeper')
print('manualfleet: identity, capabilities, leases, cross-pane rejection, expiry, retirement and bounded history pass')
return 0
