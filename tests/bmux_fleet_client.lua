if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json';local proc=require 'proc';local Native=require 'terminal.client'
local Fleet=require 'bmux.fleetclient';local Snapshot=require 'bmux.fleetsnapshot';local control=require 'control'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-fleet-client-XXXXXX'));local socket=dir..'/sock'
local clients={};local daemon
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(check,label)
  local end_at=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>end_at
  error((label or 'Fleet client deadline')..': '..(daemon and daemon:result().out or 'in-process'))
end
local function call(fn)
  local done,why,value,status=false
  fn(function(e,v,s)done=true;why=e;value=v;status=s end);await(function()return done end)
  return why,value,status
end
local function good(fn)local why,value=call(fn);assert(not why,why and why.message);return value end
local function make(opts)
  opts=opts or {};opts.socket=socket
  local c=Fleet.new(opts);clients[#clients+1]=c;return c
end
local function stop()
  for _,c in ipairs(clients)do c:close()end;clients={};control.stop();uv.run('nowait')
end
local ok,why=xpcall(function()
  local wire={v=1,host_id='host',revision=0,agents={{id='agent',generation=1,provider='custom',name='é 👩‍💻',state='alive',activity='',capabilities={},terminal_id='term-one',terminal_generation=1}}}
  local copy=assert(Snapshot.validate(wire));wire.agents[1].name='changed';assert(copy.agents[1].name=='é 👩‍💻')
  local function malformed(edit)
    local bad=json.decode(json.encode(wire));edit(bad);assert(not Snapshot.validate(bad))
  end
  malformed(function(b)b.agents[2]=b.agents[1]end)
  malformed(function(b)b.agents[1].capabilities.prompt=true end)
  malformed(function(b)b.agents[1].capabilities.approve=true end)
  malformed(function(b)b.agents[1].terminal_generation=nil end)
  malformed(function(b)b.agents[1].generation=0 end)
  malformed(function(b)b.agents[1].name='bad\255'end)
  malformed(function(b)b.agents[1].parent='agent'end)
  malformed(function(b)b.agents[1].control_result={id='cmd',accepted='yes'}end)
  malformed(function(b)b.agents[1].capabilities.stop=true;b.agents[1].state='exited'end)
  malformed(function(b)b.agents.extra={}end)

  assert(control.start{socket=socket,capabilities={'control:GET:/fleet'}})
  local c=make();local err=call(function(cb)c:start(cb)end)
  assert(err.status==403 and c.status=='disconnected');stop()
  assert(control.start{socket=socket,capabilities={'control:GET:/fleet/stream'}})
  c=make();good(function(cb)c:start(cb)end)
  err=call(function(cb)c:launch({provider='custom',cmd='/bin/sh'},cb)end)
  assert(err.status==403 and not c.pending and c.sequence==0,'admission refusal consumes no command sequence')
  local before=json.encode(c:view());control.server:broadcast('message','{"v":1}',control.fleet.channel)
  await(function()return c.status=='disconnected'end)
  assert(c.error.kind=='protocol'and json.encode(c:view())==before)
  good(function(cb)c:start(cb)end)
  local alien=control.fleet:snapshot();alien.host_id='new-server'
  control.server:broadcast('message',json.encode(alien),control.fleet.channel)
  await(function()return c.status=='disconnected'end)
  assert(c.host_id~=alien.host_id and json.encode(c:view())==before);stop()
  assert(control.start{socket=socket})
  c=make();good(function(cb)c:start(cb)end)
  local original_launch=control.fleet._launch
  control.fleet._launch=function(self,body)
    assert(original_launch(self,body));error('fixture loses outcome after native launch')
  end
  err=call(function(cb)c:launch({provider='custom',cmd='/bin/sh',args={'-c','IFS= read -r line'},history=0},cb)end)
  assert(err.status==500 and err.response.receipt.command_seq==1 and c.sequence==1 and not c.pending,
    'consumed internal failures preserve sequence progress without resending the operation')
  control.fleet._launch=original_launch
  assert(#control.terminals.order==1);stop()

  assert(uv.fs_mkdir(dir..'/home',448))
  daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
    ..q(uv.exepath())..' serve --socket '..q(socket),90)
  await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket'and info.mode&63==0 end)
  local admin=Native.new{socket=socket};clients[#clients+1]=admin
  local ready,probing=false,false
  await(function()
    if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
    return ready
  end)
  local layout=good(function(cb)admin:request('GET','/layout',nil,cb)end)
  local a,b=make{host_id=layout.host_id},make{host_id=layout.host_id}
  good(function(cb)a:start(cb)end);good(function(cb)b:start(cb)end)
  local initial=a:view();local count=a.transport.request_count
  err=call(function(cb)a:launch({provider='boggart',host_id='override'},cb)end)
  assert(err and a.transport.request_count==count and not a.pending)
  local launched=good(function(cb)a:launch({provider='boggart',name='Remote TUI 🦊',cmd=uv.exepath(),
    args={'--eval',uv.cwd()..'/tests/fixtures/agent_control_tui.lua'},cwd=uv.cwd(),history=32},cb)end)
  assert(a.sequence==1 and not a.pending)
  await(function()local r=a:find(launched.agent_id);return r and r.capabilities.prompt and r.state=='idle'end)
  await(function()return b:find(launched.agent_id)and b:find(launched.agent_id).pid==a:find(launched.agent_id).pid end)
  local rec=a:find(launched.agent_id);local pid,sid=rec.pid,rec.session_id
  err=call(function(cb)a:command(rec.id,rec.generation+1,'stop',nil,cb)end);assert(err and a.sequence==1)
  err=call(function(cb)a:command(rec.id,1,'stop',{agent_id='override'},cb)end);assert(err and a.sequence==1)
  err=call(function(cb)a:command(rec.id,1,'prompt',{text='stale',input_revision=rec.input_revision+100},cb)end)
  assert(err.status==409 and err.response.receipt.command_seq==2 and a.sequence==2 and not a.pending,'a consumed refusal advances the sequence')
  local sent=good(function(cb)a:command(rec.id,1,'prompt',{text='hello'},cb)end)
  assert(a.sequence==3)
  await(function()local r=a:find(rec.id);return r.control_result and r.control_result.id==sent.command_id and r.state=='idle'end)
  assert(a:find(rec.id).pid==pid and a:find(rec.id).session_id==sid)

  -- The daemon commits once; this fixture drops only the HTTP acknowledgement.
  local original=a.transport.request;local bodies={};local lost=false
  a.transport.request=function(self,method,path,body,callback,stream)
    if method=='POST'then
      bodies[#bodies+1]=body
      return original(self,method,path,body,function(e,v,status)
        if not lost and not e then lost=true;callback({kind='timeout',message='lost acknowledgement'})else callback(e,v,status)end
      end,stream)
    end
    return original(self,method,path,body,callback,stream)
  end
  err=call(function(cb)a:launch({provider='custom',cmd='/bin/sh',args={'-c','printf FOREIGN; IFS= read -r line'},history=0},cb)end)
  assert(err and a.pending and a.uncertain and not a:can_command())
  local pending=a.pending;good(function(cb)a:refresh(cb)end)
  assert(a.pending==pending and a.uncertain,'metadata refresh cannot resolve execution uncertainty')
  a.watch:cancel();good(function(cb)a:start(cb)end)
  assert(a.pending==pending and a.uncertain and #bodies==1,'stream reconnect observes without replaying a pending operation')
  err=call(function(cb)a:launch({provider='custom',cmd='/bin/sh'},cb)end);assert(err and #bodies==1)
  local retry=good(function(cb)a:retry(cb)end)
  assert(#bodies==2 and bodies[1]==bodies[2]and not a.pending and a.sequence==4)
  a.transport.request=original
  local records=good(function(cb)admin:request('GET','/terminals',nil,cb)end)
  assert(records.total==2,'uncertain launch/retry creates one process')
  await(function()return a:find(retry.agent_id)and a:find(retry.agent_id).capabilities.stop end)

  -- A successful-looking acknowledgement without the receipt must stay blocked.
  lost=false;bodies={}
  a.transport.request=function(self,method,path,body,callback,stream)
    if method=='POST'then
      bodies[#bodies+1]=body
      return original(self,method,path,body,function(e,v,status)
        if not lost and not e then lost=true;v.receipt=nil end;callback(e,v,status)
      end,stream)
    end
    return original(self,method,path,body,callback,stream)
  end
  err=call(function(cb)a:command(retry.agent_id,1,'stop',nil,cb)end)
  assert(err.kind=='protocol'and a.uncertain and a.sequence==4)
  good(function(cb)a:retry(cb)end);assert(a.sequence==5 and #bodies==2 and bodies[1]==bodies[2])
  a.transport.request=original
  local stable=json.encode(a:view());local revision=a.revision
  local bad=json.decode(stable);bad.revision=revision+1
  for _,r in ipairs(bad.agents)do if r.id==rec.id then r.terminal_id='term-retargeted'end end
  assert(not a:_accept(bad)and json.encode(a:view())==stable)
  bad=json.decode(stable);bad.agents[1].name='unrevisioned';assert(not a:_accept(bad))
  assert(a:_accept(initial)and a.revision==revision,'old coherent frames do not replace current state')
  a:close();assert(a.transport.request_count==0)
  good(function(cb)b:command(rec.id,1,'stop',nil,cb)end)
  assert(a:find(rec.id).pid==pid,'closed observation retains its final coherent image')
  b:close();assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
end,debug.traceback)
stop();if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
assert(ok,why)
print('Fleet client: strict identity/copy, scoped streams, consumed errors, exact uncertain retries, no duplicate launch, coherent state and teardown pass')
return 0
