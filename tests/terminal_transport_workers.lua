if package.config:sub(1,1)=='\\'then return 0 end
local setup=[[
  local uv=require 'uv';local T=require 'terminal.transport'
  local dir=assert(uv.fs_mkdtemp('/tmp/bmux-worker-exit-XXXXXX'));local socket=dir..'/sock'
  local listener=uv.new_pipe(false);assert(listener:bind(socket));assert(listener:listen(8,function()end))
]]
local pending=worker.spawn(setup..[[
  T.request({socket=socket,method='GET',path='/pending'},function()end)
  uv.stop() -- leave a connect/timer pending when the worker loop returns
  return 'pending-exit'
]])
local ok,value=worker.join(pending);assert(ok and value=='pending-exit')
local completes=worker.spawn(setup..[[
  T.request({socket=socket,method='GET',path='/timeout',timeout_ms=15},function(e)
    assert(e.kind=='timeout');worker.post('completed');listener:close()
  end)
  -- Plain workers run their asynchronous work out after the source returns.
  -- The final teardown gate must not cancel this request prematurely.
  return 'normal-exit'
]])
assert(worker.recv(completes,5000)=='completed')
ok,value=worker.join(completes);assert(ok and value=='normal-exit')
print('Worker transport teardown cancels abandoned connects and preserves ordinary async completion')
return 0
