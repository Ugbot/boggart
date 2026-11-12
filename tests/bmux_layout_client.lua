if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local proc=require 'proc';local json=require 'json'
local Layout=require 'bmux.client';local Native=require 'terminal.client';local control=require 'control'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-layout-client-XXXXXX'));local socket=dir..'/sock'
local clients={};local daemon
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(check)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('layout client deadline: '..(daemon and daemon:result().out or 'in-process server'))
end
local function call(fn)
  local done,why,result=false
  fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
  return why,result
end
local function good(fn)local why,value=call(fn);assert(not why,why and why.message);return value end
local function layout()
  local c=Layout.new{socket=socket};clients[#clients+1]=c;return c
end
local function native()
  local c=Native.new{socket=socket};clients[#clients+1]=c;return c
end
local function stop()
  for _,c in ipairs(clients)do c:close()end;clients={};control.stop();uv.run('nowait')
end
local ok,err=xpcall(function()
  assert(control.start{socket=socket,capabilities={'control:GET:/layout'}})
  local c=layout();local why=call(function(cb)c:start(cb)end)
  assert(why.status==403 and c.status=='disconnected','ordinary layout read does not grant stream observation');stop()
  assert(control.start{socket=socket,capabilities={'control:GET:/layout/stream'}})
  c=layout();good(function(cb)c:start(cb)end)
  local channel='layout:'..c.host_id
  assert(control.server:clients(channel)==1 and c.watch.operation.timer==nil,'one native observer without an idle polling timer')
  why=call(function(cb)c:command('workspace_create',{title='Denied'},cb)end)
  assert(why.status==403 and c.revision==0 and c.status=='live')
  assert(control.layout:command{host_id=c.host_id,revision=0,op='workspace_create',title='Host edit'})
  await(function()return c.revision==1 end)
  local before=json.encode(c:view())
  control.server:broadcast('message','{"v":1}',channel)
  await(function()return c.status=='disconnected'end)
  assert(c.error.kind=='protocol' and json.encode(c:view())==before,'malformed events never publish partial state')
  good(function(cb)c:start(cb)end)
  local alien=control.layout:snapshot();alien.host_id='different-server'
  control.server:broadcast('message',json.encode(alien),channel)
  await(function()return c.status=='disconnected'end)
  assert(c.host_id==control.layout.host_id and json.encode(c:view())==before,'host identity is pinned across observation reconnect')
  good(function(cb)c:start(cb)end);control.revoke()
  await(function()return c.status=='disconnected'end);stop()

  assert(uv.fs_mkdir(dir..'/home',448))
  daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
    ..q(uv.exepath())..' serve --socket '..q(socket),60)
  await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket' and info.mode&63==0 end)
  local admin=native();local ready,probing=false,false
  await(function()
    if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
    return ready
  end)
  local a,b=layout(),layout()
  good(function(cb)a:start(cb)end);good(function(cb)b:start(cb)end)
  local initial=a:view()
  good(function(cb)a:command('workspace_create',{title='Shared 🦊'},cb)end)
  await(function()return b.revision==a.revision end)
  local w=a:view().workspaces[1];local s=w.surfaces[1]
  local base=a.revision;local done_a,done_b,err_a,err_b
  a:command('surface_create',{workspace_id=w.id,title='Tests'},function(e)done_a=true;err_a=e end)
  b:command('workspace_rename',{workspace_id=w.id,title='Other client'},function(e)done_b=true;err_b=e end)
  await(function()return done_a and done_b and a.status=='live' and b.status=='live' and a.revision==base+1 and b.revision==base+1 end)
  assert((err_a and err_a.status==409 and not err_b) or (err_b and err_b.status==409 and not err_a),'competing revisions commit once and refetch without replay')
  local function request(method,path,body)
    return good(function(cb)admin:request(method,path,body,cb)end)
  end
  assert(request('GET','/layout').revision==base+1)
  local count=a.transport.request_count
  why=call(function(cb)a:command('workspace_create',{host_id='forged',title='No'},cb)end)
  assert(why and a.transport.request_count==count)
  why=call(function(cb)a:command('workspace_create',{title=string.rep('x',8192)},cb)end)
  assert(why and a.transport.request_count==count,'oversized command rejected before transport')
  local record=request('POST','/terminals',{cmd='/bin/sh',args={'-c',[[stty -echo; printf 'READY\r\n'; while IFS= read -r line; do printf 'ECHO:%s\r\n' "$line"; done]]},cols=40,rows=6,history=0})
  good(function(cb)a:command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
    view={kind='terminal',terminal_id=record.id,generation=record.generation}},cb)end)
  await(function()return b.revision==a.revision end)
  local stable=json.encode(a:view());local current=a.revision
  local bad=json.decode(stable);bad.revision=current+1
  bad.workspaces[1].surfaces[1].tree.views[1].terminal_id='term-retargeted'
  assert(not a:_accept(bad) and json.encode(a:view())==stable,'retained view IDs cannot retarget execution')
  bad=json.decode(stable);bad.workspaces[1].title='Unrevisioned edit'
  assert(not a:_accept(bad) and json.encode(a:view())==stable)
  assert(a:_accept(initial) and a.revision==current,'older snapshots cannot replace newer stream state')
  assert(not a:_accept(initial,current+1),'command acknowledgements require the exact committed revision')

  -- The real server commits; this fixture loses only the acknowledgement.
  local original=a.transport.request;local writes=0
  a.transport.request=function(self,method,path,body,callback,stream)
    if method=='POST' then
      writes=writes+1
      return original(self,method,path,body,function(e,v,status)
        assert(not e and status==200)
        callback({kind='timeout',message='fixture lost acknowledgement'})
      end,stream)
    end
    return original(self,method,path,body,callback,stream)
  end
  why=call(function(cb)a:command('workspace_rename',{workspace_id=w.id,title='Committed once'},cb)end)
  assert(why and a.uncertain and a.status=='uncertain')
  why=call(function(cb)a:command('workspace_create',{title='Must not send'},cb)end)
  assert(why and writes==1,'uncertainty blocks another mutation and never replays the first')
  a.transport.request=original
  good(function(cb)a:refresh(cb)end)
  assert(not a.uncertain and a.status=='live' and a.revision==current+1 and a:view().workspaces[1].title=='Committed once')
  await(function()return b.revision==a.revision end)
  local owner=good(function(cb)admin:attach(record.id,record.generation,{tail=0},cb)end)
  good(function(cb)owner:control(false,cb)end)
  good(function(cb)owner:input('AFTER_LAYOUT 🦊\n',cb)end)
  await(function()
    local out={};for _,row in ipairs(owner:view().screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end end
    return table.concat(out):find('ECHO:AFTER_LAYOUT 🦊',1,true)
  end)
  assert(request('GET','/terminals/'..record.id).pid==record.pid)
  a:close();assert(a.transport.request_count==0 and a.status=='closed')
  good(function(cb)b:command('workspace_rename',{workspace_id=w.id,title='Remaining observer'},cb)end)
  assert(a:view().workspaces[1].title=='Committed once','closed clients never publish later revisions')
  for _,item in ipairs(clients)do item:close();if item.transport then assert(item.transport.request_count==0)end end
  assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
  await(function()return not uv.kill(record.pid,0)end)
end,debug.traceback)
stop();if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
if not ok then error(err)end
print('bmux_layout_client: native dedicated streams, policy, malformed/epoch rejection, concurrent conflicts, uncertainty, monotonic identity, leased Unicode input and teardown pass')
return 0
