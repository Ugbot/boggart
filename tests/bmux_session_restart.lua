if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local proc=require 'proc';local Native=require 'terminal.client';local Fleet=require 'bmux.fleetclient';local Layout=require 'bmux.client'
local json=require 'json';local dir=assert(uv.fs_mkdtemp('/tmp/bmux-restart-XXXXXX'));local socket=dir..'/sock'
for _,p in ipairs{'home','start','changed directory'}do assert(uv.fs_mkdir(dir..'/'..p,448))end
local daemon,rival,admin,fleet,layout,reader;local clients={};local path=uv.cwd();local first_host
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(fn,label)
  local end_at=uv.hrtime()+10e9
  repeat uv.run('nowait');if fn()then return end;uv.sleep(1)until uv.hrtime()>end_at
  error((label or 'restart deadline')..'\n'..(daemon and daemon:result().out or ''))
end
local function good(fn)
  local done,e,v=false;fn(function(why,value)done=true;e=why;v=value end);await(function()return done end)
  assert(not e,e and e.message..' '..json.encode(e.response or {}));return v
end
local function request(method,route,body)return good(function(cb)admin:request(method,route,body,cb)end)end
local function close_clients()for _,c in ipairs(clients)do c:close()end;clients={};reader=nil end
local function start(explicit)
  daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' SHELL=/bin/sh '
    ..q(uv.exepath())..' serve --socket '..q(socket)..(explicit and ' --bmux-session '..q(socket)or ''),90)
  await(function()local s=uv.fs_lstat(socket);return s and s.type=='socket'end)
  admin=Native.new{socket=socket};clients[#clients+1]=admin
  local ready,probing=false,false
  await(function()
    if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
    return ready
  end)
  fleet=Fleet.new{socket=socket};layout=Layout.new{socket=socket};clients[#clients+1]=fleet;clients[#clients+1]=layout
  good(function(cb)fleet:start(cb)end);good(function(cb)layout:start(cb)end)
  local status=request('GET','/layout/session');assert(not status.blocked and status.name==socket)
end
local function stop(signal)
  close_clients();assert(uv.kill(daemon.pid,signal or 'sigterm'));local r=daemon:wait()
  if not signal then assert(r.code==0)end
end
local function command(op,fields)return good(function(cb)layout:command(op,fields,cb)end)end
local function text(session)
  local out={};local image=session:view()
  for _,r in ipairs(image.scrollback.rows)do for _,c in ipairs(r.cells)do if c.width>0 then out[#out+1]=c.text end end end
  for _,r in ipairs(image.screen)do for _,c in ipairs(r.cells)do if c.width>0 then out[#out+1]=c.text end end end
  return table.concat(out)
end
local ok,why=xpcall(function()
  start();first_host=layout.host_id
  local shell=request('POST','/terminals',{cwd=dir..'/start',cols=80,rows=12,history=128})
  local changed=dir..'/changed directory';local uri=changed:gsub(' ','%%20')
  request('POST','/terminals/'..shell.id..'/input',{generation=1,text="cd "..q(changed).."; printf 'PERSIST é 👩‍💻\\n'; printf '\\033]7;%s\\007' "..q('file://'..uri).."\n"})
  await(function()return request('GET','/terminals/'..shell.id).cwd==changed end,'OSC cwd is captured')
  -- A stock shell can change cwd without OSC integration. Native owner lookup
  -- must follow that change before the checkpoint is committed.
  request('POST','/terminals/'..shell.id..'/input',{generation=1,text='cd '..q(dir..'/start').."; printf 'NATIVE_CWD_READY\\n'\n"})
  await(function()return request('GET','/terminals/'..shell.id).cwd==uv.fs_realpath(dir..'/start')end,'native shell cwd without OSC')
  request('POST','/terminals/'..shell.id..'/input',{generation=1,text="cd "..q(changed).."; printf '\\033]7;%s\\007' "..q('file://'..uri).."\n"})
  await(function()return request('GET','/terminals/'..shell.id).cwd==changed end)
  local agent=good(function(cb)fleet:launch({provider='boggart',name='Resumable Boggart',cwd=path,cols=80,rows=24,history=128},cb)end)
  await(function()return fleet:find(agent.agent_id)and fleet:find(agent.agent_id).session_id and fleet:find(agent.agent_id).capabilities.prompt end)
  local session_id=fleet:find(agent.agent_id).session_id;local agent_pid=fleet:find(agent.agent_id).pid
  local marker=dir..'/foreign-runs'
  local foreign=good(function(cb)fleet:launch({provider='custom',name='Foreign marker',cmd='/bin/sh',args={'-c','printf x >> '..q(marker)..'; printf FOREIGN; IFS= read -r line'},cols=80,rows=12,history=128},cb)end)
  await(function()local f=io.open(marker,'r');if f then local v=f:read('a');f:close();return v=='x'end end)
  local w=command('workspace_create',{title='Persistent 🦊'}).workspaces[1];local s=w.surfaces[1];local pane=s.tree.id
  local scope={workspace_id=w.id,surface_id=s.id,pane_id=pane}
  command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=pane,view={kind='terminal',terminal_id=shell.id,generation=1,title='Shell one'}})
  command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=pane,view={kind='terminal',terminal_id=shell.id,generation=1,title='Same shell'}})
  local split=command('pane_split',{workspace_id=w.id,surface_id=s.id,pane_id=pane,direction='right',view={kind='agent',agent_id=agent.agent_id,title='Agent'}})
  local tree=split.workspaces[1].surfaces[1].tree
  command('split_resize',{workspace_id=w.id,surface_id=s.id,split_id=tree.id,ratio=.65})
  command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=tree.b.id,view={kind='agent',agent_id=foreign.agent_id,title='Foreign'}})
  command('pane_focus',scope);command('pane_zoom',scope)
  await(function()return request('GET','/layout/session').writes>0 end)
  local rival_socket=dir..'/rival.sock'
  rival=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' SHELL=/bin/sh '
    ..q(uv.exepath())..' serve --socket '..q(rival_socket)..' --bmux-session '..q(socket),60)
  await(function()return uv.fs_lstat(rival_socket)end)
  local rival_admin=Native.new{socket=rival_socket};clients[#clients+1]=rival_admin
  local claimed
  await(function()
    if not claimed then rival_admin:request('GET','/layout/session',nil,function(e,v)if not e then claimed=v end end)end
    return claimed
  end)
  assert(claimed.blocked and claimed.error:find('live process',1,true))
  assert(good(function(cb)rival_admin:request('GET','/terminals',nil,cb)end).total==0 and uv.kill(shell.pid,0))
  rival_admin:close();assert(uv.kill(rival.pid,'sigterm'));assert(rival:wait().code==0)
  stop();await(function()return not uv.kill(shell.pid,0)and not uv.kill(agent_pid,0)end,'clean shutdown ends old owned processes')
  start();assert(request('GET','/layout/session').restored and layout.host_id~=first_host)
  local restored=layout:view().workspaces[1].surfaces[1];tree=restored.tree
  assert(tree.divider==.65 and restored.zoomed_pane_id==tree.a.id and #tree.a.views==2)
  local shell_id=tree.a.views[1].terminal_id
  assert(shell_id==tree.a.views[2].terminal_id and shell_id~=shell.id)
  local p=request('GET','/terminals/'..shell_id)
  assert(p.cwd==changed and p.pid~=shell.pid and not p.process_exited)
  reader=good(function(cb)admin:attach(shell_id,1,{tail=128},cb)end)
  assert(text(reader):find('PERSIST é 👩‍💻',1,true),'plain history survives actual daemon restart')
  local resumed=tree.b.views[1].agent_id;local saved_foreign=tree.b.views[2].agent_id
  await(function()return fleet:find(resumed)and fleet:find(resumed).capabilities.prompt end)
  assert(fleet:find(resumed).session_id==session_id and fleet:find(resumed).pid~=agent_pid and fleet:find(resumed).state=='idle')
  local inactive=fleet:find(saved_foreign)
  assert(inactive and inactive.state=='stopped'and not inactive.pid and not inactive.capabilities.stop)
  local f=assert(io.open(marker,'r'));assert(f:read('a')=='x');f:close()
  assert(request('GET','/terminals').total==3,'one execution/image owner per restored resource')
  local done,status=false
  admin:request('POST','/layout/commands',{host_id=first_host,revision=1,op='workspace_create',title='Stale'},function(_,_,code)done=true;status=code end)
  await(function()return done end);assert(status==409)
  await(function()return request('GET','/layout/session').writes>0 end)
  local second_pid=p.pid;stop('sigkill')
  await(function()return not uv.kill(second_pid,0)end)
  start(true);assert(request('GET','/layout/session').restored,'dead owner claim is recovered after crash')
  f=assert(io.open(marker,'r'));assert(f:read('a')=='x');f:close();stop()
end,debug.traceback)
close_clients();if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
if rival and not rival.done then rival:kill('sigkill');rival:wait()end
uv.run('nowait');assert(ok,why)
print('real daemon restart: layout/zoom/aliases, cwd/history, real idle Boggart resume, inactive foreign command, fresh host/PIDs and crash claim recovery pass')
return 0
