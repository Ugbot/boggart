if package.config:sub(1,1)=='\\' then return 0 end
local uv=require 'uv';local json=require 'json';local proc=require 'proc'
local control=require 'control';local C=require 'terminal.client'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-layout-XXXXXX'));local socket=dir..'/sock'
local clients={};local daemon
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(check)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('layout server deadline: '..(daemon and daemon:result().out or 'in-process server'))
end
local function client(token)
  local c=C.new{socket=socket,token=token};clients[#clients+1]=c;return c
end
local function request(c,method,path,body,wanted)
  local done,why,result,status=false
  c:request(method,path,body,function(e,v,s)done=true;why=e;result=v;status=s end)
  await(function()return done end)
  assert(status==(wanted or 200),'HTTP '..tostring(status)..' expected '..tostring(wanted or 200)..': '..tostring(why and why.message))
  if (wanted or 200)<300 then assert(not why,why and why.message) end
  return result
end
local function good(fn)
  local done,why,result=false
  fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
  assert(not why,why and why.message);return result
end
local function stop()
  for _,c in ipairs(clients)do c:close()end;clients={}
  control.stop();uv.run('nowait')
end
local ok,err=xpcall(function()
  assert(control.start{socket=socket,capabilities={'control:GET:/layout'}})
  local c=client();local page=request(c,'GET','/layout')
  local first_host=page.host_id
  request(c,'POST','/layout/commands',{host_id=page.host_id,revision=0,op='workspace_create',title='Denied'},403)
  request(c,'POST','/terminals',{cmd='/bin/sh'},403)
  assert(control.layout.revision==0 and #control.layout.workspaces==0,'read grant cannot mutate or spawn')
  stop()
  assert(control.start{socket=socket,token='layout-test-token'})
  request(client(),'GET','/layout',nil,401)
  page=request(client('layout-test-token'),'GET','/layout')
  assert(page.host_id~=first_host)
  stop()
  assert(control.start{socket=socket,capabilities={'control:GET:/layout','control:POST:/layout/commands'}})
  c=client();page=request(c,'GET','/layout')
  local function local_command(op,fields,wanted)
    local body={host_id=page.host_id,revision=page.revision,op=op}
    for k,v in pairs(fields or {})do body[k]=v end
    local value=request(c,'POST','/layout/commands',body,wanted)
    if value then page=value end;return value
  end
  local_command('workspace_create',{title='Fleet'})
  local w=page.workspaces[1];local s=w.surfaces[1]
  local agent=require('fleet').default:register{provider='foreign',name='Layout agent'}
  local_command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,view={kind='agent',agent_id=agent.id}})
  assert(page.workspaces[1].surfaces[1].tree.views[1].agent_id==agent.id)
  local owned=assert(control.terminals:open{cmd='/bin/sh',args={'-c','IFS= read -r line'},cols=8,rows=2,history=0})
  local_command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
    view={kind='terminal',terminal_id=owned.id,generation=owned.generation}})
  request(c,'POST','/terminals/'..owned.id..'/input',{generation=owned.generation,text='DENIED\n'},403)
  request(c,'POST','/terminals/'..owned.id..'/close',{generation=owned.generation},403)
  assert(control.terminals:get(owned.id).pid==owned.pid,'layout write grants no terminal execution authority')
  local before=json.encode(page)
  local_command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
    view={kind='terminal',terminal_id=owned.id,generation=owned.generation+1}},409)
  assert(control.terminals:close(owned.id,owned.generation))
  local_command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
    view={kind='terminal',terminal_id=owned.id,generation=owned.generation}},409)
  local_command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,view={kind='agent',agent_id='unknown'}},404)
  assert(json.encode(request(c,'GET','/layout'))==before)
  local oversized=string.rep(' ',8192)..json.encode{host_id=page.host_id,revision=page.revision,
    op='workspace_select',workspace_id=w.id}
  request(c,'POST','/layout/commands',oversized,400)
  for _,body in ipairs{'{broken','[]','null','false','{"op":'..string.rep('[',100)..'0'..string.rep(']',100)..'}'}do
    request(c,'POST','/layout/commands',body,400)
  end
  request(c,'GET','/layout?extra=1',nil,400)
  assert(json.encode(request(c,'GET','/layout'))==before,'HTTP validation preserves owner state')
  local old_host=page.host_id;stop()

  -- A separate daemon owns both layout and PTYs after every requesting client disconnects.
  assert(uv.fs_mkdir(dir..'/home',448))
  daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
    ..q(uv.exepath())..' serve --socket '..q(socket),60)
  await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket' and info.mode&63==0 end)
  local a,b=client(),client()
  local ready,probing=false,false
  await(function()
    if not ready and not probing then
      probing=true
      a:request('GET','/health',nil,function(why,value)probing=false;ready=not why and value.ok end)
    end
    return ready
  end)
  page=request(a,'GET','/layout');assert(page.host_id~=old_host and page.revision==0)
  local initial=page
  local function command(c,op,fields,wanted)
    local body={host_id=page.host_id,revision=page.revision,op=op}
    for k,v in pairs(fields or {})do body[k]=v end
    local value=request(c,'POST','/layout/commands',body,wanted)
    if value then page=value end;return value
  end
  command(a,'workspace_create',{title='Shared 🦊'})
  request(b,'POST','/layout/commands',{host_id=initial.host_id,revision=initial.revision,op='workspace_create',title='Stale'},409)
  request(b,'POST','/layout/commands',{host_id=old_host,revision=page.revision,op='workspace_create',title='Old runtime'},409)
  assert(json.encode(request(b,'GET','/layout'))==json.encode(page),'competing stale commands have no effects')
  w=page.workspaces[1];s=w.surfaces[1]
  local function edit(op,fields)
    local args={workspace_id=w.id,surface_id=s.id}
    for k,v in pairs(fields or {})do args[k]=v end
    return command(b,op,args)
  end
  local script=[[stty -echo; printf 'READY\r\n'; while IFS= read -r line; do printf 'ECHO:%s\r\n' "$line"; [ "$line" = EXIT ] && exit 0; done]]
  local one=request(a,'POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=40,rows=6,history=16},201)
  local two=request(b,'POST','/terminals',{cmd='/bin/sh',args={'-c','printf SECOND; IFS= read -r line'},cols=40,rows=6,history=0},201)
  edit('view_add',{pane_id=s.tree.id,view={kind='terminal',terminal_id=one.id,generation=one.generation,title='Main'}})
  edit('pane_split',{pane_id=s.tree.id,direction='right',view={kind='terminal',terminal_id=two.id,generation=two.generation}})
  local surface=page.workspaces[1].surfaces[1];local left,right=surface.tree.a.id,surface.tree.b.id
  local first_view=surface.tree.a.views[1].id;local second_view=surface.tree.b.views[1].id
  edit('pane_zoom',{pane_id=left});a:close()
  local fresh=client();local rejoined=request(fresh,'GET','/layout')
  assert(rejoined.workspaces[1].surfaces[1].zoomed_pane_id==left and rejoined.workspaces[1].surfaces[1].tree.b.views[1].id==second_view)
  local session=good(function(cb)b:attach(one.id,one.generation,{tail=16},cb)end)
  await(function()return session:view().process and session:view().process.pid==one.pid end)
  edit('split_resize',{split_id=surface.tree.id,ratio=.65})
  edit('view_move',{pane_id=right,view_id=second_view,target_pane_id=left})
  assert(page.workspaces[1].surfaces[1].tree.views[1].id==first_view)
  edit('view_close',{pane_id=left})
  assert(request(fresh,'GET','/terminals/'..two.id).pid==two.pid and uv.kill(two.pid,0),'closing a view does not kill its PTY')
  command(b,'workspace_remove',{workspace_id=w.id})
  assert(#page.workspaces==0 and request(fresh,'GET','/terminals/'..one.id).pid==one.pid)
  assert(request(fresh,'GET','/terminals/'..one.id).cols==40,'layout resize never resizes a terminal without a controller lease')
  good(function(cb)session:control(false,cb)end)
  good(function(cb)session:input('AFTER_LAYOUT 🦊\n',cb)end)
  await(function()
    local out={};for _,row in ipairs(session:view().screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end end
    return table.concat(out):find('ECHO:AFTER_LAYOUT 🦊',1,true)
  end)
  for _,item in ipairs(clients)do item:close()end
  assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
  await(function()return not uv.kill(one.pid,0) and not uv.kill(two.pid,0)end)
end,debug.traceback)
stop()
if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
if not ok then error(err)end
print('bmux_layout_server: real UDS auth/policy, Fleet references, epoch/revision conflicts, independent daemon layout and unchanged native PTYs pass')
return 0
