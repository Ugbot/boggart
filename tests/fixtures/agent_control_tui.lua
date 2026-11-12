-- Actual cTUI/session/scheduler/permission gate, with only the remote model
-- replaced by deterministic local turns. Never sends a model API request.
local uv=require 'uv'
require('perm').set_mode('manual')
bog.api.run_on=function(session,text,sink,opts)
  assert(os.getenv('BOGGART_AGENT_CHANNEL_FD')==nil,'bootstrap capability must not leak to grandchildren')
  session.messages=session.messages or {}
  session.messages[#session.messages+1]={role='user',content=text}
  if text=='workers asking' then
    local child=bog.thread.spawn{agent='coder',parent_id=session.id,task='fixture worker approval'}
    while bog.sched.alive(child)do coroutine.yield('approve')end
    sink('FIXTURE_WORKER_APPROVAL_ENDED')
  elseif text=='fixture worker approval' then
    opts.run_tool('read',{path='README.md'})
  elseif text=='workers' then
    bog.thread.max_agents=8
    local a=bog.thread.spawn{agent='coder',parent_id=session.id,task='fixture worker hold with child'}
    local b=bog.thread.spawn{agent='researcher',parent_id=session.id,task='fixture worker hold'}
    bog.thread.spawn{agent='critic',parent_id=session.id,task='fixture worker done'}
    bog.thread.spawn{agent='coder',parent_id=session.id,task='fixture worker fail'}
    sink('FIXTURE_WORKERS_STARTED')
    while bog.sched.alive(a) or bog.sched.alive(b)do coroutine.yield('approve')end
    sink('FIXTURE_WORKERS_FINISHED')
  elseif text=='fixture worker hold with child' then
    bog.thread.spawn{agent='coder',parent_id=session.id,task='fixture nested done'}
    while true do coroutine.yield('approve')end
  elseif text=='fixture worker hold' then
    while true do coroutine.yield('approve')end
  elseif text=='fixture worker fail' then error('fixture worker failure')
  elseif text=='approval' then
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
