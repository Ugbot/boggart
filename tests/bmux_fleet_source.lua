if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local Fleet=require 'bmux.fleetclient';local Source=require 'bmux.fleetsource';local control=require 'control'
local json=require 'json'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-fleet-source-XXXXXX'));local socket=dir..'/sock'
local client,source;local registry=require('fleet').default
local function await(check)
  local until_at=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>until_at
  error('Fleet source deadline')
end
local function good(fn)
  local done,why,value=false;fn(function(e,v)done=true;why=e;value=v end)
  await(function()return done end);assert(not why,why and why.message);return value
end
local ok,why=xpcall(function()
  assert(control.start{socket=socket})
  local focused
  client=Fleet.new{socket=socket,on_change=function()if source then source:update()end end}
  source=Source.new(registry,client,function(id,generation)focused={id,generation};return true end)
  good(function(cb)client:start(cb)end)
  local local_agent=registry:register{provider='local',name='Keep local'};local stopped=0
  registry:bind(local_agent.id,1,{stop=function()stopped=stopped+1;return true end})
  local launched=good(function(cb)client:launch({provider='custom',name='Remote 👩‍💻',cmd='/bin/sh',args={'-c','printf READY; IFS= read -r line'},history=0},cb)end)
  await(function()return source:find(launched.agent_id)and source:find(launched.agent_id).capabilities.stop end)
  local row=source:find(launched.agent_id);local owner=registry.owners[launched.agent_id];local pid=row.pid
  assert(row.id~=launched.agent_id and registry:get(row.id)==row and row.fleet_remote and not registry.agents[row.id])
  assert(registry:control(local_agent.id,1,'stop')and stopped==1,'local ownership remains intact')
  assert(registry:control(row.id,1,'focus')and focused[1]==launched.agent_id and focused[2]==1)
  good(function(cb)client:refresh(cb)end)
  assert(source:find(launched.agent_id)==row and registry.owners[launched.agent_id]==owner,'updates retain presentation identity and original execution owner')
  local wire=assert(control.fleet:snapshot())
  assert(#wire.agents==#registry.order,'client-only view rows cannot be reflected back through the server')
  for _,r in ipairs(wire.agents)do assert(not tostring(r.id):match('^remote:'))end
  for _=1,20 do uv.run('nowait')end
  assert(#source.rows==#registry.order,'joining the same host does not create recursive aliases')
  assert(registry:control(row.id,1,'stop'))
  await(function()return source:find(launched.agent_id).state=='stopped'end)
  assert(not row.capabilities.stop and control.terminals:get(launched.terminal_id).closed)
  assert(registry.agents[launched.agent_id].pid==pid)
  local replacement=json.decode(json.encode(client:view()));replacement.revision=replacement.revision+1
  for _,r in ipairs(replacement.agents)do if r.id==launched.agent_id then
    r.generation=2;r.state='alive';r.capabilities={stop=true};r.terminal_id='term-new-runtime'
  end end
  assert(client:_accept(replacement));source:update()
  local current=source:find(launched.agent_id);local sequence=client.sequence
  assert(current~=row and current.id==row.id and current.generation==2)
  assert(not registry:control(row.id,row.generation,'stop')and client.sequence==sequence,'a stale action cannot transfer to a replaced runtime')
  assert(registry.owners[launched.agent_id]==owner,'a new view generation never replaces the actual execution owner')
  source:close();assert(not registry:get(row.id)and registry:get(local_agent.id)==local_agent)
  client:close()
end,debug.traceback)
if source then source:close()end;if client then client:close()end
control.stop();uv.run('nowait');assert(uv.fs_rmdir(dir));assert(ok,why)
print('Fleet source: source-owned actions, stable aliases, shared execution owner, local roster preservation, self-host reflection guard and detach pass')
return 0
