if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local terminal=require 'terminal';local control=require 'control';local Codec=require 'bmux.checkpoint'
local Native=require 'terminal.client';local Layout=require 'bmux.client';local Files=require 'bmux.sessionfiles';local proc=require 'proc'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-session-ui-XXXXXX'));assert(uv.fs_mkdir(dir..'/home',448))
local socket=dir..'/sock';local name='ui-'..serve.token(8);local imported=name..'-imported'
local path=dir..'/é👩‍💻🇬🇧.json';local marker=dir..'/marker';local shell=dir..'/marker-shell'
local child,admin,layout,daemon,restored;local store=bog.store
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function screen()
  if not child then return ''end
  local out={};local _,rows=child:geometry()
  for y=1,rows do for _,c in ipairs(child:row(y).cells)do if c.width>0 then out[#out+1]=c.text end end;out[#out+1]='\n'end
  return table.concat(out)
end
local function await(check)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('Session cTUI deadline\n'..screen()..'\n'..(daemon and daemon:result().out or ''))
end
local function good(fn)
  local done,e,v=false;fn(function(why,value)done=true;e=why;v=value end);await(function()return done end)
  assert(not e,e and e.message);return v
end
local function req(c,method,url,body)return good(function(cb)c:request(method,url,body,cb)end)end
local function write(text)assert(child:write(text)==#text)end
local function prefix(key)write('\2'..key)end
local function paste(text)write('\27[200~'..text..'\27[201~')end
local function menu()
  prefix('e');await(function()local text=screen();return text:find('Bmux | Sessions',1,true)and not text:find('| working',1,true)end)
end
local ok,why=xpcall(function()
  assert(control.start{socket=socket,session=name});admin=Native.new{socket=socket};layout=Layout.new{socket=socket}
  good(function(cb)layout:start(cb)end)
  local page=good(function(cb)layout:command('workspace_create',{title='Session controls 🦊'},cb)end)
  local w=page.workspaces[1];local s=w.surfaces[1]
  local record=req(admin,'POST','/terminals',{cmd='/bin/sh',args={'-c',"stty -echo; printf 'READY é 👩‍💻\\r\\n'; while IFS= read -r line; do printf 'ECHO:%s\\r\\n' \"$line\"; done"},cols=80,rows=12,history=32})
  good(function(cb)layout:command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
    view={kind='terminal',terminal_id=record.id,generation=record.generation,title='Running terminal'}},cb)end)
  child=assert(terminal.open{cmd=uv.exepath(),args={'bmux','--socket',socket},cols=110,rows=24,history=16,
    env={'HOME='..dir..'/home','BOGGART_HOME='..dir..'/home/.boggart'}})
  await(function()return screen():find('READY é 👩‍💻',1,true)end)
  prefix('c');await(function()return screen():find('[controlling]',1,true)end)
  menu();await(function()return screen():find(name..' · ',1,true)end)
  write('\27[<0;3;3M\27[<0;3;3m') -- actual pointer click on Export
  await(function()return screen():find('Export session to new file',1,true)and not screen():find('> e ',1,true)end)
  paste(path);write('\r');await(function()return screen():find('Exported to',1,true)and uv.fs_stat(path)end)
  local exported=assert(Codec.decode(assert(Files.read(path))))
  assert(exported.layout.workspaces[1].title=='Session controls 🦊'and #exported.terminals==1)
  write('e');paste(path);write('\r');await(function()return screen():find('EEXIST',1,true)end)
  -- Give the file a shell recipe; the entire visible import path must demote it.
  exported.terminals[1].launch='shell';exported.terminals[1].lines={'touch '..marker,'é 👩‍💻 🇬🇧'}
  local f=assert(io.open(path,'w'));f:write(assert(Codec.encode(exported)));f:close()
  write('i');await(function()return screen():find('Import checkpoint file',1,true)end)
  paste(path);write('\r');await(function()return screen():find('New saved session name (inactive)',1,true)end)
  paste(imported);write('\r');await(function()return screen():find('Saved inactive session',1,true)end)
  write('c');await(function()return screen():find('Saved session name',1,true)end)
  write('\r');await(function()return screen():find('all inactive',1,true)end)
  assert(req(admin,'GET','/terminals/'..record.id).pid==record.pid and uv.kill(record.pid,0))
  child:resize(28,10);await(function()return screen():find('Sessions',1,true)end)
  write('e');paste(path);await(function()return screen():find('👩‍💻🇬🇧.json',1,true)end)
  write('\27');await(function()return screen():find('> e ',1,true)end)
  paste('MODAL_MUST_NOT_TYPE\r');write('\27')
  await(function()return not screen():find('Bmux | Sessions',1,true)end)
  child:resize(110,24);await(function()return screen():find('Running terminal [controlling]',1,true)end)
  local e=assert(control.terminals:find(record.id));assert(not table.concat(e.term:plain_tail()):find('MODAL_MUST_NOT_TYPE',1,true))
  -- A real external checkpoint replacement blocks the next write. The modal
  -- must show recovery status without overwriting the damaged bytes.
  store.kv_set('bmux.session.v1:'..name,'{corrupt checkpoint')
  e.term:feed('CHECKPOINT_CHANGED\r\n');assert(not control.journal:flush()and control.journal.blocked)
  menu();await(function()return screen():find('Recovery needed:',1,true)end)
  assert(store.kv_get('bmux.session.v1:'..name)=='{corrupt checkpoint')
  write('\27');await(function()return screen():find('Running terminal [controlling]',1,true)end)
  prefix('q');await(function()local p=child:process_state();return p.exited and p.eof end)
  assert(child:process_state().exit_status==0);child:close();child=nil
  assert(uv.kill(record.pid,0),'detaching Sessions UI leaves server execution alive')
  f=assert(io.open(shell,'w'));f:write('#!/bin/sh\nprintf x >> '..q(marker)..'\nexec /bin/sh\n');f:close();assert(uv.fs_chmod(shell,448))
  local restored_socket=dir..'/restored.sock'
  daemon=proc.start('exec env BOGGART_HOME='..q(assert(os.getenv('BOGGART_HOME')))..' SHELL='..q(shell)..' '..q(uv.exepath())
    ..' serve --socket '..q(restored_socket)..' --bmux-session '..q(imported),30)
  await(function()local info=uv.fs_lstat(restored_socket);return info and info.type=='socket'and info.mode&63==0 end)
  restored=Native.new{socket=restored_socket};local ready,probing=false,false
  await(function()if not ready and not probing then probing=true;restored:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end;return ready end)
  local status=req(restored,'GET','/layout/session');assert(status.restored and not status.blocked and status.name==imported)
  local snapshot=req(restored,'GET','/layout');assert(snapshot.host_id~=layout.host_id)
  local id=snapshot.workspaces[1].surfaces[1].tree.views[1].terminal_id
  local process=req(restored,'GET','/terminals/'..id);assert(not process.pid and process.state=='stopped'and not uv.fs_lstat(marker))
  child=assert(terminal.open{cmd=uv.exepath(),args={'bmux','--socket',restored_socket},cols=110,rows=24,history=0,
    env={'HOME='..dir..'/home','BOGGART_HOME='..dir..'/home/.boggart'}})
  await(function()return screen():find('Saved output; process is inactive',1,true)and screen():find('é 👩‍💻 🇬🇧',1,true)end)
  prefix('c');await(function()return screen():find('control request refused',1,true)end)
  assert(not uv.fs_lstat(marker),'joining and requesting control never starts an imported shell')
  prefix('q');await(function()local p=child:process_state();return p.exited and p.eof end)
  assert(child:process_state().exit_status==0);child:close();child=nil
  restored:close();restored=nil;assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0);daemon=nil
end,debug.traceback)
if child then child:close()end;if admin then admin:close()end;if layout then layout:close()end;if restored then restored:close()end
if daemon then daemon:kill('sigkill');daemon:wait()end
control.stop();uv.run('nowait')
for _,n in ipairs{name,imported}do store.kv_del('bmux.session.v1:'..n);store.kv_del('bmux.owner.v1:'..n)end
os.remove(path);os.remove(shell);os.remove(marker)
assert(ok,why)
print('Actual cTUI Sessions: status/export/refusal/import/inspection, Unicode/narrow editor isolation, retained PTY and inactive daemon relaunch pass')
return 0
