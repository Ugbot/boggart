if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local terminal=require 'terminal';local control=require 'control'
local Client=require 'terminal.client';local Layout=require 'bmux.client';local Canvas=require 'bmux.canvas'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-ctui-XXXXXX'));local socket=dir..'/sock'
assert(uv.fs_mkdir(dir..'/home',448))
local child,admin,layout,competitor;local ended=false
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function image()
  if not child then return ''end
  local out={};local _,rows,history=child:geometry()
  for y=1,history do local row=child:row(y,true);for _,c in ipairs(row.cells)do if c.width>0 then out[#out+1]=c.text end end;out[#out+1]='\n'end
  for y=1,rows do local row=child:row(y);for _,c in ipairs(row.cells)do if c.width>0 then out[#out+1]=c.text end end;out[#out+1]='\n'end
  return table.concat(out)
end
local function screen()
  local out={};local _,rows=child:geometry()
  for y=1,rows do for _,c in ipairs(child:row(y).cells)do if c.width>0 then out[#out+1]=c.text end end;out[#out+1]='\n'end
  return table.concat(out)
end
local function await(check,label)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error((label or 'cTUI deadline')..'\n'..image())
end
local function good(fn)
  local done,why,result=false
  fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
  assert(not why,why and why.message);return result
end
local function command(op,args)return good(function(cb)layout:command(op,args,cb)end)end
local function request(method,path,body)return good(function(cb)admin:request(method,path,body,cb)end)end
local function prefix(key)assert(child:write('\2'..key)==#key+1)end
local ok,why=xpcall(function()
  assert(control.start{socket=socket})
  admin=Client.new{socket=socket};layout=Layout.new{socket=socket};good(function(cb)layout:start(cb)end)
  command('workspace_create',{title='Shared 🦊'})
  local w=layout:view().workspaces[1];local s=w.surfaces[1];local pane=s.tree.id
  local script=[[stty -echo; printf 'READY é 👩‍💻 🇬🇧\r\n'; while IFS= read -r line; do printf 'ECHO:%s\r\n' "$line"; done]]
  local record=request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=80,rows=24,history=32})
  command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=pane,view={kind='terminal',terminal_id=record.id,generation=record.generation,title='One 🦊'}})
  local scene=Canvas.layout(layout:view(),100,24)
  assert(scene.focused.remote_id==pane and #scene.leaves==1 and scene.leaves[1].w==100)
  local command_line='before=$(stty -g); '..q(uv.exepath())..' bmux --socket '..q(socket)
    ..'; status=$?; after=$(stty -g); [ "$before" = "$after" ] || exit 91; exit "$status"'
  child=assert(terminal.open{cmd='/bin/sh',args={'-c',command_line},cols=100,rows=24,history=128,
    env={'HOME='..dir..'/home','BOGGART_HOME='..dir..'/home/.boggart'}})
  await(function()return screen():find('READY',1,true)and screen():find('[read-only]',1,true)end,'real CLI joins read-only')
  assert(screen():find('é',1,true)and screen():find('👩‍💻',1,true)and screen():find('🇬🇧',1,true),'actual emitted frame preserves complete clusters')
  assert(request('GET','/terminals/'..record.id).pid==record.pid)
  child:write('FORBIDDEN\r');uv.run('nowait')
  competitor=good(function(cb)admin:attach(record.id,record.generation,{tail=0},cb)end)
  good(function(cb)competitor:control(false,cb)end)
  prefix('c');await(function()return screen():find('control request refused',1,true)end,'control conflict stays read-only')
  assert(screen():find('[read-only]',1,true))
  prefix('!');await(function()return screen():find('[controlling]',1,true)end,'explicit takeover')
  child:write('AFTER_JOIN🦊\r')
  await(function()return screen():find('ECHO:AFTER_JOIN🦊',1,true)end,'semantic input reaches same server PTY')
  child:write('\27[200~SPLIT_PASTE\27[20')
  uv.sleep(40);uv.run('nowait') -- delimiter intentionally crosses two reads
  child:write('1~\r')
  await(function()return screen():find('ECHO:SPLIT_PASTE',1,true)end,'fragmented bracketed-paste delimiter')
  local encoder <close> =terminal.new()
  local map=require('bmux.tui').key
  assert(encoder:key(map{key='ctrl',char='b'})=='\2')
  assert(encoder:key(map{key='up'})=='\27[A')
  assert(encoder:key(map{key='char',char='é'})=='é')
  assert(not screen():find('ECHO:FORBIDDEN',1,true))
  await(function()local e=control.terminals:find(record.id);return e.cols==100 and e.rows==20 end,'controller-only resize')
  prefix('v');await(function()return screen():find('[read-only]',1,true)end)
  control.server:broadcast('message','{"v":1}','layout:'..layout.host_id)
  await(function()return layout.status=='disconnected' and screen():find('disconnected',1,true)end,'invalid stream retains last coherent layout')
  prefix('r');good(function(cb)layout:start(cb)end)
  await(function()return screen():find('Main | live',1,true)and screen():find('One 🦊',1,true)end,'explicit stream reconnect')
  local b=request('POST','/terminals',{cmd='/bin/sh',args={'-c',"printf 'SECOND 🇬🇧\\r\\n'; cat"},cols=40,rows=8,history=0})
  command('pane_split',{workspace_id=w.id,surface_id=s.id,pane_id=pane,direction='right',
    view={kind='terminal',terminal_id=b.id,generation=b.generation,title='Two'}})
  await(function()return screen():find('One 🦊',1,true)and screen():find('Two [read-only]',1,true)and screen():find('SECOND',1,true)end,'server edit updates actual cTUI')
  scene=Canvas.layout(layout:view(),100,24);assert(#scene.leaves==2 and not scene.narrow)
  local canonical=layout:view().workspaces[1].surfaces[1];local focused=canonical.focused_pane_id
  child:resize(24,12)
  await(function()return screen():find('Two [read-only]',1,true)and not screen():find('One 🦊',1,true)end,'SIGWINCH alone redraws narrow focused pane')
  scene=Canvas.layout(layout:view(),24,12);assert(scene.narrow and #scene.leaves==1 and scene.focused.remote_id==focused)
  prefix('p');await(function()return screen():find('One 🦊',1,true)end,'narrow pane navigation')
  child:resize(100,24)
  await(function()return screen():find('One 🦊',1,true)and screen():find('Two [read-only]',1,true)end,'SIGWINCH restores tiling')
  prefix('z');await(function()return not screen():find('Two [read-only]',1,true)end)
  prefix('z');await(function()return screen():find('Two [read-only]',1,true)end)
  prefix('t');await(function()return #control.terminals.order==3 end,'new server terminal')
  await(function()local t=layout:view().workspaces[1].surfaces[1].tree;return #t.a.views==2 or #t.b.views==2 end)
  prefix('x');await(function()local t=layout:view().workspaces[1].surfaces[1].tree;return #t.a.views==1 and #t.b.views==1 end)
  assert(#control.terminals.order==3,'closing a reference leaves the execution owner running')
  prefix('c');await(function()return screen():find('[controlling]',1,true)end)
  prefix('?');await(function()return screen():find('explicit takeover',1,true)end)
  child:write('\27[200~HELP_MUST_NOT_TYPE\r\27[201~');uv.sleep(40);uv.run('nowait')
  child:write('\27');await(function()return not screen():find('explicit takeover',1,true)end)
  child:write('AFTER_HELP\r');await(function()return screen():find('ECHO:AFTER_HELP',1,true)end)
  assert(not screen():find('ECHO:HELP_MUST_NOT_TYPE',1,true),'help consumes paste instead of typing through it')
  prefix('q');await(function()return child:process_state().exited and child:process_state().eof end,'clean detach')
  assert(child:process_state().exit_status==0,'CLI exit and exact termios restoration: '..image())
  assert(not request('GET','/terminals/'..record.id).process_exited,'detach leaves original server PTY running')
  ended=true
end,debug.traceback)
if child then child:close()end
if competitor then competitor:close()end
if layout then layout:close()end
if admin then admin:close()end
control.stop();uv.run('nowait')
assert(ok,why)
assert(ended)
print('real Bmux cTUI: native clusters, server layout, semantic input, resize, narrow navigation, reference close and detach pass')
