if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local terminal=require 'terminal';local proc=require 'proc'
local children={}
local function spawn()
  local t=assert(terminal.open{cmd=uv.exepath(),args={'--eval','tests/fixtures/agent_channel_echo.lua'},control=true})
  children[#children+1]=t;return t,t:channel()
end
local function await(check)
  local until_at=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>until_at
  error('agent channel watch deadline')
end
local ok,why=xpcall(function()
  local t,c=spawn();local calls,old=0,0;local received={}
  local function drain(owner)
    assert(owner==c);calls=calls+1
    while true do local text=owner:receive();if not text then break end;received[text]=true end
  end
  c:watch(function()old=old+1;error('replaced callback ran')end)
  c:watch(drain);assert(calls==0 and old==0,'installing a watch never enters Lua inline')
  await(function()return received.READY end)
  assert(old==0 and c:watch_state().active)
  local before=calls
  for i=1,32 do assert(c:send('FRAME'..i))end
  assert(calls==before,'sending does not reenter the observer')
  await(function()return received.FRAME32 end)
  for i=1,32 do assert(received['FRAME'..i])end
  before=calls
  for _=1,100 do uv.run('nowait')end
  assert(calls==before,'idle observation has no periodic callbacks')
  c:watch(function()error('cancelled callback ran')end);c:watch(nil);uv.run('nowait')
  assert(not c:watch_state().active)
  c:watch(function()error('CHANNEL_WATCH_FAILURE')end);uv.run('nowait')
  assert(not c:watch_state().active and c:watch_state().error:find('CHANNEL_WATCH_FAILURE',1,true))
  assert(not c:state().closed and c:send('AFTER_ERROR'),'callback failure does not close transport')
  c:watch(drain);await(function()return received.AFTER_ERROR end)
  assert(c:watch_state().error==nil)
  local replaced=0
  c:watch(function(owner)
    replaced=replaced+1;owner:watch(drain);error('OLD_CALLBACK_FAILURE')
  end)
  uv.run('nowait');uv.run('nowait')
  assert(replaced==1 and c:watch_state().active and c:watch_state().error==nil,'a failing replaced callback cannot disable its successor')
  assert(c:send('EXIT'));await(function()return c:state().closed and received.FINAL end)
  await(function()return t:process_state().exited and t:process_state().eof end)
  assert(t:process_state().exit_status==0)
  c:watch(function(owner)assert(owner:state().closed);owner:close()end)
  uv.run('nowait');uv.run('nowait');assert(not c:watch_state().active,'callback may close a closed native owner')
  t:close();uv.run('nowait');assert(not uv.loop_alive(),'idle/closed notification handle keeps no loop reference')

  local creator=coroutine.create(function()
    local child,channel=spawn();local ready=false
    channel:watch(function(owner)
      while true do local text=owner:receive();if not text then break end;if text=='READY'then ready=true end end
    end)
    return child,channel,function()return ready end
  end)
  local started,child,channel,ready=coroutine.resume(creator);assert(started);creator=nil
  collectgarbage('collect');collectgarbage('collect');await(ready)
  channel:watch(function(owner)owner:close()end);uv.run('nowait')
  assert(not channel:watch_state().active,'self-close cancels native readiness safely')
  child:close();uv.run('nowait')

  local weak=setmetatable({}, {__mode='v'})
  do
    local native=assert(terminal.open{cmd='/bin/sh',args={'-c','sleep 30'},control=true})
    local owner=native:channel();weak[1]=owner;weak[2]=native
    owner:watch(function()owner:state()end)
  end
  collectgarbage('collect');collectgarbage('collect');uv.run('nowait')
  assert(not weak[1] and not weak[2],'watch/callback/native-owner cycles remain collectable')
  for _=1,16 do
    local native=assert(terminal.open{cmd='/bin/sh',args={'-c','exit 0'},control=true})
    native:channel():watch(function()error('closed terminal callback ran')end);native:close()
  end
  uv.run('nowait')
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local directory=assert(uv.fs_mkdtemp('/tmp/bmux-channel-watch-XXXXXX'));local marker=directory..'/callback'
  local result=proc.run(q(uv.exepath())..' --eval tests/fixtures/agent_channel_watch_shutdown.lua -- '..q(marker),5)
  assert(result.code==0,result.out)
  assert(not uv.fs_lstat(marker),'interpreter teardown must not enter a pending Lua callback')
  assert(uv.fs_rmdir(directory))
  local handle=worker.spawn([[
    local t=assert(require('terminal').open{cmd='/bin/sh',args={'-c','sleep 30'},control=true})
    rawset(_G,'retained_worker_channel',t)
    t:channel():watch(function()worker.post('BAD_CHANNEL_CALLBACK')end)
    worker.post('channel watch retained')
  ]])
  assert(worker.recv(handle,5000)=='channel watch retained' and worker.join(handle))
  assert(worker.recv(handle,0)==nil,'worker teardown must not enter pending Lua callbacks')
end,debug.traceback)
for _,t in ipairs(children)do t:close()end
uv.run('nowait');assert(ok,why)
print('agent channel watches: deferred/coalesced readiness, idle, replacement, errors, EOF, self-close, GC, coroutine and shutdown pass')
return 0
