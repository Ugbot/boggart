if package.config:sub(1,1)=='\\' then return end
local uv=require 'uv';local proc=require 'proc';local json=require 'json'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-notify-XXXXXX'));local path=dir..'/control.sock'
local registry=require('fleet').new{prefix='notify',max_records=8}
local service=require('manualfleet').new{registry=registry,clock=function()return uv.hrtime()/1e9 end}
local pane=service:pane{focus=function()return true end,alive=function()return true end}
local registrations,states={},{ }
local server=assert(serve.listen{socket=path,handler=function(req)
  assert(not (req.body or ''):find('PRIVATE_PROMPT',1,true),'native projection must discard prompt/tool contents')
  local code,body,headers=service:handle(req)
  if req.path=='/bmux/agents/register' and code==201 then registrations[#registrations+1]=json.decode(body)end
  local rec=registry.agents[registry.order[1]]
  if rec then states[#states+1]={path=req.path,state=rec.state,event=rec.reported_event}end
  return code,body,headers
end})
local context='BOGGART_SOCKET='..q(path)..' BOGGART_PANE_ID='..q(pane.id)..' BOGGART_PANE_TOKEN='..q(pane.token)..' '
local cli=q(uv.exepath())..' ctl '
local script=dir..'/provider.sh';local f=assert(io.open(script,'w'))
f:write('#!/bin/sh\n[ "$BOGGART_AGENT_EVENT_TOKEN" != stale ] || exit 91\n',
  'printf \'%s\' ',q('{"hook_event_name":"SessionStart","session_id":"fixture-session","prompt":"PRIVATE_PROMPT","tool_input":{"secret":"PRIVATE_PROMPT"}}'),
  ' | ',cli,'notify --provider claude\n/bin/sleep 1.1\n')
f:close()
local result=proc.run(context..'BOGGART_AGENT_ID=stale BOGGART_AGENT_EVENT_TOKEN=stale BOGGART_AGENT_PROVIDER=stale '..cli..'run --provider claude -- /bin/sh '..q(script),8)
assert(result.code==0,result.out)
local rec=assert(registry.agents[registry.order[1]]);assert(rec.state=='exited' and rec.session_id=='fixture-session')
local semantic,heartbeat=false,false
for _,state in ipairs(states)do
  if state.path=='/bmux/agents/notify' and state.state=='idle'then semantic=true end
  if semantic and state.path=='/bmux/agents/heartbeat' and state.state=='idle'then heartbeat=true end
end
assert(semantic and heartbeat,'native event is accepted and preserved by wrapper heartbeat')
local registration=registrations[1]
local event_env=context..'BOGGART_AGENT_ID='..q(registration.agent_id)..' BOGGART_AGENT_EVENT_TOKEN='..q(registration.event_token)..' '
local input=dir..'/event.json'
local function notify(text,env)
  local file=assert(io.open(input,'w'));file:write(text);file:close()
  return proc.run((env or event_env)..cli..'notify --provider claude < '..q(input),8)
end
result=notify('{"hook_event_name":"Stop","session_id":"fixture-session"}')
assert(result.code==0 and rec.state=='exited','late native callback cannot revive an exited process')
result=notify('{broken');assert(result.code==0 and not result.out:find('{broken',1,true))
result=notify(string.rep('x',256*1024+1));assert(result.code==0)
local live,body=service:handle{authenticated=true,remote='unix',method='POST',path='/bmux/agents/register',
  body=json.encode{pane=pane.id,pane_token=pane.token,provider='claude',name='Native hook fixture'}}
assert(live==201);local active=json.decode(body);local active_rec=registry.agents[active.agent_id]
local active_env=context..'BOGGART_AGENT_ID='..q(active.agent_id)..' BOGGART_AGENT_EVENT_TOKEN='..q(active.event_token)..' '
result=notify('{"hook_event_name":"SessionStart","session_id":"active","last_assistant_message":"PRIVATE_PROMPT"}',active_env)
assert(result.code==0 and result.out=='' and active_rec.state=='idle','valid hook emits no stdout or decision JSON')
result=notify('{"hook_event_name":"Stop","session_id":"active"} trailing',active_env)
assert(result.code==0 and active_rec.state=='idle' and active_rec.reported_event=='SessionStart','trailing junk is rejected')
result=notify('{"hook_event_name":"Stop","session_id":"active"}\0trailing',active_env)
assert(result.code==0 and active_rec.reported_event=='SessionStart','embedded NUL cannot truncate the input check')
result=notify('{"hook_event_name":"Stop","session_id":"active","agent_id":123}',active_env)
assert(result.code==0 and active_rec.reported_event=='SessionStart','invalid identity metadata cannot become a root event')
server:stop();uv.run('nowait');uv.fs_unlink(script);uv.fs_unlink(input);assert(uv.fs_rmdir(dir))
print('provider_notify: native scoped events, environment replacement, privacy projection, heartbeat, finish, malformed/oversized input and empty stdout pass')
return 0
