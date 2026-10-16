if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json';local control=require 'control'
local Native=require 'terminal.client'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-observers-XXXXXX'));local socket=dir..'/sock'
local client,session
local function await(check)
  local until_at=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>until_at
  error('terminal observer deadline')
end
local function good(fn)
  local done,why,result=false
  fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
  assert(not why,why and why.message);return result
end
local ok,why=xpcall(function()
  assert(control.start{socket=socket})
  local registry=control.terminals
  local rejected,problem=registry:open{cmd='/bin/sh',control=true}
  assert(not rejected and problem.status==400,'public terminal options cannot request private agent IPC')
  local rec=assert(registry:open{cmd='/bin/sh',args={'-c','stty -echo; printf READY; IFS= read -r line; printf FINISHED; exit 7'},cols=30,rows=4,history=0})
  local entry=assert(registry:find(rec.id,1));local changes,closed=0,0
  assert(registry:observe(entry,'fleet',function(owner,event)
    assert(owner==entry);changes=changes+1
    if event=='released'then
      closed=closed+1;assert(owner.closed and owner.term==nil and owner.cost==0)
      assert(registry:close(owner.id,owner.generation).closed,'release callback may inspect/idempotently close its owner')
    end
  end))
  assert(changes==0,'registry observation is deferred through the native watcher')
  await(function()return changes>0 and entry.term:process_state().bytes_read>0 end)
  client=Native.new{socket=socket}
  session=good(function(cb)client:attach(rec.id,1,{tail=0},cb)end)
  assert(registry:observing(entry,'attachments') and registry:observing(entry,'fleet'))
  local cursor=session:view().cursor;local before=changes
  entry.term:feed('\27[HSHARED')
  await(function()return changes>before and session:view().cursor>cursor end)
  assert(session:view().screen[1].cells[1].text=='S')
  assert(registry:observe(entry,'bad',function()error('OBSERVER_FAILURE')end))
  await(function()return entry.observer_errors.bad~=nil end)
  assert(not registry:observing(entry,'bad')and entry.observer_errors.bad:find('OBSERVER_FAILURE',1,true))
  assert(entry.term:watch_state().active and not entry.term:watch_state().error,'one observer error preserves the native watch and other listeners')
  before=changes;cursor=session:view().cursor;entry.term:feed('\27[2;1HSTILL_SHARED')
  await(function()return changes>before and session:view().cursor>cursor end)
  good(function(cb)session:detach(cb)end);session=nil
  assert(not registry:observing(entry,'attachments')and entry.term:watch_state().active,'reader detach preserves lifecycle observation')
  local idle=changes;for _=1,100 do uv.run('nowait')end
  assert(changes==idle,'idle multiplexed observers do not poll')
  local old,new=0,0
  registry:observe(entry,'replace',function()old=old+1 end)
  registry:observe(entry,'replace',function()new=new+1 end)
  await(function()return new>0 end);assert(old==0,'pending replacement never reaches the old observer')
  registry:observe(entry,'replace',nil)
  assert(entry.term:write('finish\n'))
  await(function()local p=registry:get(rec.id);return p.process_exited and p.eof end)
  assert(registry:get(rec.id).state=='failed')
  assert(registry:close(rec.id,1).closed and closed==1)
  assert(registry:close(rec.id,1).closed and closed==1 and next(entry.observers)==nil,'release retires listeners once')
  assert(not registry:observe(entry,'late',function()end))

  local live=assert(registry:open{cmd='/bin/sh',args={'-c','IFS= read -r line'},history=0})
  local owner=assert(registry:find(live.id,1))
  for i=1,8 do assert(registry:observe(owner,'slot'..i,function()end))end
  local admitted,capacity=registry:observe(owner,'overflow',function()end)
  assert(not admitted and capacity.status==503)
  for i=1,8 do registry:observe(owner,'slot'..i,nil)end
  assert(not owner.term:watch_state().active,'last unsubscribe releases native observation')
  local shutdown
  registry:observe(owner,'shutdown',function(_,event)
    if event=='released'then
      shutdown=true
      local result,err=registry:open{cmd='/bin/sh'}
      assert(not result and err.status==503,'shutdown cannot create fresh owners from callbacks')
    end
  end)

  local controlled=assert(registry:open({cmd=uv.exepath(),args={'--eval','tests/fixtures/agent_channel_echo.lua'},cols=20,rows=4,history=0},{control=true}))
  local controlled_entry=assert(registry:find(controlled.id,1));local channel=assert(controlled_entry.term:channel())
  local ready=false;channel:watch(function(c)while true do local text=c:receive();if not text then break end;if text=='READY'then ready=true end end end)
  await(function()return ready end)
  control.stop();assert(shutdown and channel:state().closed and not channel:watch_state().active)
end,debug.traceback)
if session then session:close()end;if client then client:close()end
control.stop();uv.run('nowait');assert(uv.fs_rmdir(dir));assert(ok,why)
print('terminal observers: shared stream/lifecycle readiness, isolated errors, bounds, replacement, release, shutdown and trusted agent IPC pass')
return 0
