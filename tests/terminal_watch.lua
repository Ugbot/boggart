local terminal=require 'terminal';local uv=require 'uv';local proc=require 'proc'
local calls=0;local t=terminal.new(80,6,16)
assert(t:watch(function(owner)assert(owner==t);calls=calls+1 end))
for _=1,100 do t:feed('x')end
assert(calls==0,'feed must never enter Lua callbacks')
uv.run('nowait');assert(calls==1 and t:watch_state().active,'changes coalesce at the loop boundary')
for _=1,100 do uv.run('nowait')end
assert(calls==1 and not uv.loop_alive(),'idle parser watch neither polls nor keeps the loop alive')
local old,new=0,0
t:watch(function()old=old+1 end);t:watch(function()new=new+1 end)
uv.run('nowait');assert(old==0 and new==1,'pending replaced watchers cannot fire')
t:watch(function()error('WATCH_FIXTURE_FAILURE')end);uv.run('nowait')
local state=t:watch_state();assert(not state.active and state.error:find('WATCH_FIXTURE_FAILURE',1,true))
t:feed('still usable');uv.run('nowait');assert(not t:watch_state().active)
t:watch(function(owner)owner:close()end);uv.run('nowait');uv.run('nowait')
assert(not t:watch_state().active,'callback may close its owner safely')
local weak=setmetatable({}, {__mode='v'})
do
  local owner=terminal.new();weak[1]=owner
  owner:watch(function()owner:state()end)
end
collectgarbage('collect');collectgarbage('collect');uv.run('nowait')
assert(not weak[1],'watch/callback cycle does not root an abandoned terminal')
for _=1,32 do
  local owner=terminal.new();owner:watch(function()error('cancelled callback fired')end);owner:close()
end
uv.run('nowait')
if package.config:sub(1,1)~='\\'then
  local native=assert(terminal.open{cmd='/bin/sh',args={'-c','stty -echo; printf READY; IFS= read -r line; printf DONE; exit 7'},cols=40,rows=4})
  local statuses={};native:watch(function(owner)statuses[#statuses+1]=owner:process_state()end)
  local function await(check)
    local deadline=uv.hrtime()+5e9
    repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
    error('native watch deadline')
  end
  await(function()return #statuses>0 and statuses[#statuses].bytes_read>0 end)
  local idle=native:watch_state().callbacks
  for _=1,100 do uv.run('nowait')end
  assert(native:watch_state().callbacks==idle,'idle native terminal emits no periodic notifications')
  assert(native:write('finish\n'));await(function()local s=statuses[#statuses];return s and s.exited and s.eof end)
  assert(statuses[#statuses].exit_status==7)
  native:watch(nil);native:close();uv.run('nowait')
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local result=proc.run(q(uv.exepath())..' --eval tests/fixtures/terminal_watch_shutdown.lua',5)
  assert(result.code==0,result.out)
  result=proc.run(q(uv.exepath())..' --eval tests/fixtures/terminal_watch_coroutine.lua',5)
  assert(result.code==0,result.out)
  local w=worker.spawn([[
    local t=require('terminal').new();rawset(_G,'retained_watch',t)
    t:watch(function()error('worker callback during teardown')end)
    worker.post('watch retained')
  ]])
  assert(worker.recv(w,5000)=='watch retained' and worker.join(w),'worker teardown closes pending native watches')
end
print('terminal_watch: deferred/coalesced changes, idle, replacement, errors, GC cycles, self-close, native exit and interpreter teardown pass')
return 0
