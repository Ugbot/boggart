local application=require 'core'
if package.config:sub(1,1)=='\\'then application.quit(true);return end
application.add_thread(function()
  local core=require 'core';local uv=require 'uv';local proc=require 'proc';local Native=require 'terminal.client'
  local ws=require 'shell.workspaces.bmux';local Codec=require 'bmux.checkpoint';local Files=require 'bmux.sessionfiles'
  local daemon,admin,joined,second,other;local name='studio-'..serve.token(8);local imported=name..'-imported'
  local dir=assert(uv.fs_mkdtemp('/tmp/bmux-studio-sessions-XXXXXX'));local socket=dir..'/sock';local path=dir..'/é👩‍💻🇬🇧.json'
  local marker=dir..'/marker';local marker_shell=dir..'/marker-shell';assert(uv.fs_mkdir(dir..'/home',448))
  local executable=require('core.agentlauncher').boggart_command()
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function tick()core.redraw=true;coroutine.yield(0)end
  local function await(fn)
    local deadline=system.get_time()+8
    repeat tick();if fn()then return end until system.get_time()>deadline
    error('Studio Sessions deadline: '..core.command_view.label..'; '..tostring(joined and joined.session_actions and joined.session_actions.message)
      ..'\n'..(daemon and daemon:result().out or ''))
  end
  local function good(fn)
    local done,e,v=false;fn(function(why,value)done=true;e=why;v=value end);await(function()return done end)
    assert(not e,e and e.message);return v
  end
  local function req(c,method,url,body)return good(function(cb)c:request(method,url,body,cb)end)end
  local function key(name)
    system._test_event{type='keypressed',key=name};system._test_event{type='keyreleased',key=name}
  end
  local function text(value)
    system._test_event{type='keypressed',key='S'};system._test_event{type='textinput',text=value};system._test_event{type='keyreleased',key='S'}
  end
  local function submit(value)if value then text(value)end;key('Return');tick()end
  local function dialog(label)await(function()return core.active_view==core.command_view and core.command_view.label:find(label,1,true)end)end
  local function button(label)
    local hit;await(function()for _,h in ipairs(ws.toolbar.hits or {})do if h.item.label==label then hit=h;return true end end end)
    local x,y=math.floor(hit.x+hit.w/2),math.floor(hit.y+hit.h/2)
    system._test_event{type='mousepressed',button=1,x=x,y=y};system._test_event{type='mousereleased',button=1,x=x,y=y};tick()
  end
  local function menu()button('Sessions');dialog('Bmux sessions')end
  local ok,why=xpcall(function()
    local env='HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')
    daemon=proc.start('exec env '..env..' '..q(executable)..' serve --socket '..q(socket)..' --bmux-session '..q(name),90)
    await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket'and info.mode&63==0 end)
    admin=Native.new{socket=socket};local ready,probing=false,false
    await(function()if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end;return ready end)
    local layout=req(admin,'GET','/layout')
    layout=req(admin,'POST','/layout/commands',{host_id=layout.host_id,revision=layout.revision,op='workspace_create',title='Saved sessions 🦊'})
    local w=layout.workspaces[1];local s=w.surfaces[1]
    local record=req(admin,'POST','/terminals',{cmd='/bin/sh',args={'-c',"printf 'STUDIO_SESSION é 👩‍💻\\r\\n'; IFS= read -r line"},cols=80,rows=12,history=32})
    req(admin,'POST','/layout/commands',{host_id=layout.host_id,revision=layout.revision,op='view_add',workspace_id=w.id,surface_id=s.id,
      pane_id=s.tree.id,view={kind='terminal',terminal_id=record.id,generation=record.generation,title='Keep running'}})
    good(function(cb)require('core.bmuxlayout').join(socket,nil,function(e,s)joined=s;cb(e,s)end)end)
    await(function()for _,view in pairs(joined.pool)do if view.remote and view.remote.snapshot then return true end end end)
    menu();await(function()return joined.session_actions.info and not joined.session_actions.busy end)
    assert(joined.session_actions.info.name==name)
    if os.getenv('BMUX_RENDER_DIR')then tick();assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/session-controls.bmp'))end
    submit('Export session to new file');dialog('Export session to new file')
    -- Hold a real status reply to exercise a user submitting the file prompt
    -- while another request is pending. Keep the chosen path for explicit retry.
    local a=joined.session_actions;local status=a.client.status;local reply,held
    a.client.status=function(self,cb)reply=cb;return status(self,function(...)held=table.pack(...)end)end
    a:refresh();await(function()return held end);submit(path)
    assert(core.active_view==core.command_view and not uv.fs_stat(path),'pending status retains the export prompt and path')
    reply(table.unpack(held,1,held.n));a.client.status=status;submit()
    await(function()return not joined.session_actions.busy and uv.fs_stat(path)end)
    assert(not joined.session_actions.error and Codec.decode(assert(Files.read(path))).layout.host_id==layout.host_id)
    menu();submit('Export session to new file');dialog('Export session to new file');submit(path)
    await(function()return not joined.session_actions.busy and joined.session_actions.error end)
    assert(joined.session_actions.message:find('EEXIST',1,true))
    local saved=assert(Codec.decode(assert(Files.read(path))));saved.terminals[1].launch='shell'
    saved.terminals[1].lines={'touch '..marker,'é 👩‍💻 🇬🇧'}
    local f=assert(io.open(path,'w'));f:write(assert(Codec.encode(saved)));f:close()
    menu();submit('Import file as inactive session');dialog('Import checkpoint file');submit(path)
    dialog('New saved session name (inactive)');submit(imported)
    await(function()return not joined.session_actions.busy and joined.session_actions.saved_name==imported end)
    assert(not joined.session_actions.error)
    menu();submit('Inspect saved session');dialog('Saved session name');submit()
    await(function()return not joined.session_actions.busy and joined.session_actions.message:find('all inactive',1,true)end)
    assert(req(admin,'GET','/terminals/'..record.id).pid==record.pid and uv.kill(record.pid,0))
    -- Escape at the second import prompt performs no import and sends no text
    -- or newline to the selected remote terminal.
    menu();submit('Import file as inactive session');dialog('Import checkpoint file');submit(path)
    dialog('New saved session name (inactive)');text('CANCEL_MUST_NOT_TYPE');key('Escape');tick()
    assert(uv.kill(record.pid,0)and not joined.session_actions.busy)
    f=assert(io.open(marker_shell,'w'));f:write('#!/bin/sh\nprintf x >> '..q(marker)..'\nexec /bin/sh\n');f:close();assert(uv.fs_chmod(marker_shell,448))
    local target=dir..'/restored.sock'
    second=proc.start('exec env '..env..' SHELL='..q(marker_shell)..' '..q(executable)..' serve --socket '..q(target)..' --bmux-session '..q(imported),60)
    await(function()local info=uv.fs_lstat(target);return info and info.type=='socket'and info.mode&63==0 end)
    other=Native.new{socket=target};ready,probing=false,false
    await(function()if not ready and not probing then probing=true;other:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end;return ready end)
    local state=req(other,'GET','/layout/session');assert(state.restored and not state.blocked and state.name==imported)
    local restored=req(other,'GET','/layout');assert(restored.host_id~=layout.host_id)
    local id=restored.workspaces[1].surfaces[1].tree.views[1].terminal_id
    local p=req(other,'GET','/terminals/'..id);assert(p.state=='stopped'and not p.pid and not uv.fs_lstat(marker))
    local a=joined.session_actions;joined:disconnect();assert(a.closed and a.client.closed)
    assert(uv.kill(record.pid,0),'disconnecting session controls leaves the server PTY alive')
    good(function(cb)require('core.bmuxlayout').join(target,nil,function(e,s)joined=s;cb(e,s)end)end)
    local restored_view
    await(function()for _,v in pairs(joined.pool)do if v.remote and v.remote.snapshot then restored_view=v;return true end end end)
    local image=restored_view.remote.snapshot;local output={}
    for _,row in ipairs(image.screen)do for _,cell in ipairs(row.cells)do if cell.width>0 then output[#output+1]=cell.text end end end
    output=table.concat(output)
    assert(output:find('Saved output; process is inactive',1,true)and output:find('é 👩‍💻 🇬🇧',1,true))
    assert(restored_view.remote:status()=='read-only'and not restored_view.remote:process_state().pid and not uv.fs_lstat(marker))
    print('Actual SDL Sessions: toolbar/chooser/export/refusal/import/inspect/cancel, retained owners and inactive imported daemon relaunch pass')
  end,debug.traceback)
  if joined then joined:disconnect()end;if admin then admin:close()end;if other then other:close()end
  for _,p in ipairs{second or false,daemon or false}do if p and not p.done then uv.kill(p.pid,'sigterm');p:wait()end end
  if not ok then io.stderr:write(tostring(why),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  core.quit(true)
end)
