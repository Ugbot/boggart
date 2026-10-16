if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local control=require 'control';local Native=require 'terminal.client';local Client=require 'bmux.sessionclient'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-recovery-client-XXXXXX'));local socket=dir..'/sock'
local name='recover-client-'..serve.token(8);local key='bmux.session.v1:'..name;local owner='bmux.owner.v1:'..name
local store=bog.store;local clients,paths={},{}
local function await(fn)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if fn()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('recovery client deadline')
end
local function client(module,host)local c=module.new{socket=socket,host_id=host};clients[#clients+1]=c;return c end
local function good(fn)
  local done,e,v=false;fn(function(why,value)done=true;e=why;v=value end);await(function()return done end)
  assert(not e,e and e.message);return v
end
local function request(c,method,url,body,wanted)
  local done,status,v=false;c:request(method,url,body,function(_,value,code)done=true;status=code;v=value end)
  await(function()return done end);assert(status==(wanted or 200),tostring(status));return v
end
local function stop()for _,c in ipairs(clients)do c:close()end;clients={};control.stop();uv.run('nowait')end
local ok,why=xpcall(function()
  store.kv_set(key,'\255\0{original')
  assert(control.start{socket=socket,session=name,capabilities={'control:GET:/layout','control:GET:/layout/session','control:GET:/layout/session/recovery'}})
  local admin=client(Native);local host=request(admin,'GET','/layout').host_id
  local c=client(Client,host);local p=good(function(cb)c:recovery_preview(cb)end);paths[#paths+1]=p.archive.path
  assert(p.name==name and p.archive.present and p.revision==0 and not uv.fs_lstat(p.archive.path))
  request(admin,'POST','/layout/session/recover',{host_id=host,revision=p.revision,recovery_id=p.recovery_id},403)
  assert(store.kv_get(key)=='\255\0{original'and not uv.fs_lstat(p.archive.path));stop()
  assert(control.start{socket=socket,session=name});admin=client(Native);host=request(admin,'GET','/layout').host_id;c=client(Client,host)
  assert(good(function(cb)c:status(cb)end).blocked)
  request(admin,'GET','/layout/session/recovery?x=1',nil,400)
  request(admin,'POST','/layout/session/recover','{broken',400)
  request(admin,'POST','/layout/session/recover',string.rep(' ',4096)..'{}',400)
  request(admin,'POST','/layout/session/recover',{},409)
  p=good(function(cb)c:recovery_preview(cb)end);paths[#paths+1]=p.archive.path
  request(admin,'POST','/layout/session/recover',{host_id=host,revision=p.revision,recovery_id=p.recovery_id,argv={'unsafe'}},400)
  local files=require 'bmux.sessionfiles';local archive=files.archive;local blocked_edit=false
  files.archive=function(...)
    -- Exercise the same HTTP route admission while recovery is inside its
    -- archive/write interval, without recursively running libuv's event loop.
    for _,route in ipairs(control.routes)do if route.method=='POST'and route.pattern=='^/layout/commands$'then
      local code=route.fn{body=require('json').encode{host_id=host,revision=p.revision,op='workspace_create',title='Concurrent edit'}}
      blocked_edit=code==409;assert(control.layout.revision==p.revision)
    end end
    return archive(...)
  end
  local result=good(function(cb)c:recover(p,cb)end);files.archive=archive
  assert(blocked_edit,'layout admission is paused for the recovery critical section')
  assert(result.recovered and not result.status.blocked and result.archive.path==p.archive.path and not c.uncertain)
  assert(not good(function(cb)c:status(cb)end).last_recovery,'ordinary status retains its previous wire shape')
  local info=good(function(cb)c:recovery_status(cb)end);assert(info.last_recovery.id==p.recovery_id)
  assert(info.last_recovery~=control.journal.last_recovery)
  request(admin,'POST','/layout/session/recover',{host_id=host,revision=p.revision,recovery_id=p.recovery_id},409)
  request(admin,'POST','/layout/commands',{host_id=host,revision=p.revision,op='workspace_create',title='After recovery'})
  assert(#control.terminals.order==0 and not control.journal.blocked)
  local source=assert(io.open(p.archive.path,'rb'));assert(source:read('a')=='\255\0{original');source:close()
  stop()
  -- A malformed/lost success response is uncertain. Subsequent GET/status is
  -- allowed, but it cannot clear uncertainty or cause a second mutation.
  local original=Native.new;local pending,calls
  Native.new=function()return {request=function(_,method,url,body,cb)
    calls=(calls or 0)+1;pending={method=method,body=body,callback=cb};return {done=false}
  end,close=function()end}end
  local fake=Client.new{host_id=host};Native.new=original;clients[#clients+1]=fake
  local error
  fake:recover(p,function(e)error=e end)
  assert(calls==1 and pending.method=='POST'and pending.body.recovery_id==p.recovery_id)
  pending.callback(nil,{recovered=true,host_id=host,revision=p.revision,archive={id='wrong'},status={}},200)
  assert(error and fake.uncertain)
  fake:recover(p,function(e)assert(e)end);assert(calls==1)
  fake:recovery_status(function(e,value)assert(not e and value.last_recovery.id==p.recovery_id)end)
  pending.callback(nil,info,200);assert(calls==2 and fake.uncertain and pending.method=='GET')
  fake:close()
end,debug.traceback)
stop();store.kv_del(key);store.kv_del(owner)
for _,p in ipairs(paths)do uv.fs_unlink(p);uv.fs_unlink(p..'.json')end
uv.fs_rmdir(assert(uv.fs_realpath(bog.userdir))..'/bmux-recovery');uv.fs_rmdir(dir);assert(ok,why)
print('Recovery client: native scopes/validation, exact preview/archive/status ACKs, no duplicate mutation and uncertain observation pass')
return 0
