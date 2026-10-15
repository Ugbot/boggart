-- Actual cTUI/session/scheduler/permission gate, with only the remote model
-- replaced by deterministic local turns. Never sends a model API request.
local uv=require 'uv'
require('perm').set_mode('manual')
bog.api.run_on=function(session,text,sink,opts)
  assert(os.getenv('BOGGART_AGENT_CHANNEL_FD')==nil,'bootstrap capability must not leak to grandchildren')
  session.messages=session.messages or {}
  session.messages[#session.messages+1]={role='user',content=text}
  if text=='approval' then
    local result=opts.run_tool('read',{path='README.md'})
    sink(result:find('permission_error',1,true) and 'FIXTURE_REJECTED' or 'FIXTURE_APPROVED')
  elseif text=='wait' then
    sink('FIXTURE_WAITING')
    while not session.inbox or #session.inbox==0 do coroutine.yield('approve')end
    sink('FIXTURE_STEER:'..table.concat(session.inbox,'|'));session.inbox={}
  else sink('FIXTURE_ANSWER:'..text) end
  session.messages[#session.messages+1]={role='assistant',content='local fixture completed'}
end
assert(require('tui').run(),'fixture needs real PTY')
return 0
