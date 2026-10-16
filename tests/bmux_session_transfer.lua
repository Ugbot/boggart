if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json';local proc=require 'proc'
local control=require 'control';local Codec=require 'bmux.checkpoint';local Journal=require 'bmux.journal'
local Native=require 'terminal.client';local Transfer=require 'bmux.sessionclient'
local fixture=assert(loadfile('tests/fixtures/bmux_checkpoint.lua'))()
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-transfer-XXXXXX'));local socket=dir..'/sock'
local name='transfer-'..serve.token(8);local store=bog.store;local clients={};local daemon
local function key(n)return 'bmux.session.v1:'..(n or name)end
local function owner(n)return 'bmux.owner.v1:'..(n or name)end
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(fn)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if fn()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('transfer deadline\n'..(daemon and daemon:result().out or ''))
end
local function good(fn)
  local done,e,v=false;fn(function(why,value)done=true;e=why;v=value end)
  await(function()return done end);assert(not e,e and e.message);return v
end
local function client(module,opts)local c=module.new(opts or {socket=socket});clients[#clients+1]=c;return c end
local function request(c,method,path,body,status)
  local done,e,v,s=false;c:request(method,path,body,function(why,value,code)done=true;e=why;v=value;s=code end)
  await(function()return done end);assert(s==(status or 200),tostring(s)..': '..tostring(e and e.message))
  if not status or status<300 then assert(not e,e and e.message)end;return v
end
local function close_clients()for _,c in ipairs(clients)do c:close()end;clients={}end
local function stop()
  close_clients();control.stop();uv.run('nowait')
  if daemon then assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0);daemon=nil end
end
local marker=dir..'/should-not-run';local shell=dir..'/marker-shell'
local ok,why=xpcall(function()
  local _,doc=fixture();for _,t in ipairs(doc.terminals)do t.cwd=dir end
  local resume=store.thread_create{title='Import must remain idle',model='fixture',status='idle'}
  doc.agents[1].resume_id=resume
  doc.terminals[1].program='/bin/sh -c touch '..marker
  doc.terminals[1].lines={'touch '..marker,'é 👩‍💻 🇬🇧'}
  local raw=assert(Codec.encode(doc));local before=store.kv_get(key())
  assert(not before)
  -- Even a valid local saved session cannot be overwritten by import.
  store.kv_set(key(),'corrupt saved bytes')
  local value,e=Journal.import(name,raw);assert(not value and e.status==409 and store.kv_get(key())=='corrupt saved bytes')
  assert(not store.kv_get(owner()));store.kv_del(key())
  store.kv_set(owner(),json.encode{v=1,pid=uv.os_getpid(),token='live'})
  value,e=Journal.import(name,raw);assert(not value and e.status==409 and not store.kv_get(key()))
  assert(store.kv_get(owner()):find('live',1,true));store.kv_del(owner())
  store.kv_set(owner(),'invalid owner')
  value,e=Journal.import(name,raw);assert(not value and e.status==409 and not store.kv_get(key()))
  assert(store.kv_get(owner())=='invalid owner');store.kv_del(owner())
  value,e=Journal.import(name,'{broken');assert(not value and e.status==400 and not store.kv_get(owner()))
  assert(not Journal.import('',raw))
  -- Failed storage must release just its own lease and retain its real error.
  local fault={is_open=store.is_open,kv_get=store.kv_get,kv_compare_set=function(k,old,new)
    if k==key()then return nil,'fixture disk full'end
    return store.kv_compare_set(k,old,new)
  end}
  value,e=Journal.import(name,raw,fault);assert(not value and e.status==503 and e.message:find('disk full',1,true))
  assert(not store.kv_get(owner())and not store.kv_get(key()))
  local claim_fault={is_open=store.is_open,kv_get=function()error('fixture read failed')end,kv_compare_set=store.kv_compare_set}
  value,e=Journal.import(name,raw,claim_fault);assert(not value and e.status==503 and e.message:find('read failed',1,true))
  -- Read-only control credentials cannot create saved sessions.
  assert(control.start{socket=socket,capabilities={'control:GET:/layout','control:GET:/layout/checkpoint'}})
  local admin=client(Native);local host=request(admin,'GET','/layout').host_id
  local path='/layout/checkpoints/'..host..'/'..name
  request(admin,'POST',path,raw,403);assert(not store.kv_get(key()));stop()
  assert(control.start{socket=socket,session=name..'-source'});admin=client(Native);host=request(admin,'GET','/layout').host_id
  path='/layout/checkpoints/'..host..'/'..name
  local current=assert(control.terminals:open{cmd='/bin/sh',args={'-c','printf LIVE_HISTORY; IFS= read -r line'},cwd=dir,cols=20,rows=4,history=8})
  local transfer=client(Transfer,{socket=socket,host_id=host})
  local status=good(function(cb)transfer:status(cb)end)
  assert(status.host_id==host and status.persistent and status.name==name..'-source'and not status.blocked)
  local exported=assert(Codec.decode(good(function(cb)transfer:export(cb)end)))
  assert(exported.layout.host_id==host and #exported.terminals==1 and exported.terminals[1].id==current.id)
  request(admin,'POST','/layout/checkpoints/wrong/'..name,raw,409)
  request(admin,'POST',path..'?x=1',raw,400)
  request(admin,'POST',path,'{broken',400)
  request(admin,'POST',path..string.rep('x',128),raw,400)
  assert(not store.kv_get(key())and not store.kv_get(owner()))
  -- Send the original trusted recipes directly: server demotion is mandatory.
  local imported=request(admin,'POST',path,raw)
  assert(imported.name==name and imported.inactive and imported.restart_required)
  assert(#control.terminals.order==1 and next(control.fleet.sessions)==nil and control.layout.host_id==host)
  assert(control.terminals:get(current.id).pid==current.pid and uv.kill(current.pid,0),'import leaves the active terminal owner running')
  local saved=assert(Codec.decode(store.kv_get(key())))
  assert(saved.terminals[1].launch=='saved'and saved.agents[1].launch=='saved'and saved.agents[1].resume_id==resume)
  assert(Codec.decode(raw).terminals[1].launch=='shell','source bytes remain trusted-local data')
  assert(good(function(cb)transfer:saved(name,cb)end)==store.kv_get(key()))
  request(admin,'POST',path,raw,409);request(admin,'GET',path..'?x=1',nil,400)
  local second=good(function(cb)transfer:import(name..'-client',raw,cb)end)
  assert(second.inactive and Codec.decode(store.kv_get(key(name..'-client'))).agents[1].launch=='saved')
  local entry=assert(control.terminals:find(current.id))
  await(function()return table.concat(entry.term:plain_tail()):find('LIVE_HISTORY',1,true)end)
  assert(control.journal:flush());control.terminals:release(entry)
  local closed=assert(Codec.decode(good(function(cb)transfer:export(cb)end)))
  assert(table.concat(closed.terminals[1].lines):find('LIVE_HISTORY',1,true),'export retains journal history after a parser is released')
  stop()
  -- Malformed/lost success ACKs stop mutation. Observation never replays one.
  local original=Native.new;local pending,calls=nil,0
  Native.new=function()return {request=function(_,method,path,body,cb)
    calls=calls+1;pending={method=method,path=path,body=body,callback=cb};return {done=false}
  end,close=function()end}end
  local fake=Transfer.new{host_id=host};Native.new=original;clients[#clients+1]=fake
  local failure
  fake:import('uncertain',raw,function(e)failure=e end)
  assert(pending.method=='POST'and Codec.decode(pending.body).terminals[1].launch=='saved')
  pending.callback(nil,{name='wrong',inactive=true,restart_required=true},200)
  assert(failure and fake.uncertain and calls==1)
  fake:import('uncertain',raw,function(e)assert(e)end);assert(calls==1)
  fake:saved('uncertain',function(e,v)assert(not e and v)end)
  assert(calls==2 and pending.method=='GET');pending.callback(nil,assert(Codec.import(raw)),200)
  assert(fake.uncertain,'inspection cannot enable replay of the ambiguous POST')
  local bad_status
  fake:status(function(e)bad_status=e end)
  pending.callback(nil,{host_id='changed',persistent=false},200)
  assert(bad_status and fake.uncertain,'status cannot silently follow a new host or clear uncertain mutations')
  fake:close();close_clients()
  local f=assert(io.open(shell,'w'));f:write('#!/bin/sh\nprintf x >> '..q(marker)..'\nexec /bin/sh\n');f:close();assert(uv.fs_chmod(shell,448))
  -- Actual daemon startup reads the same SQLite checkpoint with a valid local
  -- Boggart thread and an executable default shell that would leave a marker.
  -- Repeat after a real final save: imports never acquire trust by resaving.
  local last_host
  for iteration=1,2 do
    daemon=proc.start('exec env BOGGART_HOME='..q(assert(os.getenv('BOGGART_HOME')))..' SHELL='..q(shell)..' '
      ..q(uv.exepath())..' serve --socket '..q(socket)..' --bmux-session '..q(name),60)
    await(function()
      local info=uv.fs_lstat(socket)
      return info and info.type=='socket'and info.mode&63==0
    end)
    admin=client(Native);local ready,probing=false,false
    await(function()
      if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
      return ready
    end)
    local state=request(admin,'GET','/layout/session');assert(state.restored and not state.blocked and state.name==name)
    local layout=request(admin,'GET','/layout');assert(layout.host_id~=host and layout.host_id~=last_host);last_host=layout.host_id
    local t=client(Transfer,{socket=socket,host_id=layout.host_id})
    local captured=assert(Codec.decode(good(function(cb)t:export(cb)end)))
    assert(#captured.terminals==2 and #captured.agents==2 and #captured.layout.workspaces==2)
    for _,entry in ipairs(captured.terminals)do
      assert(entry.launch=='saved');local p=request(admin,'GET','/terminals/'..entry.id)
      assert(not p.pid and p.state=='stopped'and p.process_exited)
      request(admin,'POST','/terminals/'..entry.id..'/input',{generation=entry.generation,text='touch '..marker..'\n'},409)
    end
    for _,a in ipairs(captured.agents)do assert(a.launch=='saved')end
    assert(captured.agents[1].resume_id==resume)
    local history=false
    for _,t in ipairs(captured.terminals)do for _,line in ipairs(t.lines)do
      if line:find('é 👩‍💻 🇬🇧',1,true)then history=true end
    end end
    assert(history,'Unicode history survives import, daemon restoration and resave')
    local tree=layout.workspaces[1].surfaces[1].tree
    assert(tree.a.views[1].terminal_id==tree.a.views[2].terminal_id,'aliases retain one inactive resource')
    assert(tree.divider==.7 and layout.workspaces[1].surfaces[1].zoomed_pane_id==tree.a.id)
    assert(not uv.fs_lstat(marker),'imported shell, program label and history never execute')
    stop();assert(not uv.fs_lstat(marker))
    local resaved=assert(Codec.decode(store.kv_get(key())))
    assert(resaved.terminals[1].launch=='saved'and resaved.agents[1].launch=='saved')
  end
end,debug.traceback)
close_clients();control.stop()
if daemon then daemon:kill('sigkill');daemon:wait()end
for _,n in ipairs{name,name..'-client',name..'-source'}do store.kv_del(key(n));store.kv_del(owner(n))end
uv.run('nowait');os.remove(shell);os.remove(marker)
local removed,cleanup_error=uv.fs_rmdir(dir)
assert(ok,why);assert(removed,cleanup_error)
print('Bmux transfer: bounded native routes/client, owner guards, no overwrite, inactive imports across actual daemon restart/resave pass')
return 0
