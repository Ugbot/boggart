local application=require 'core'
if package.config:sub(1,1)=='\\'then application.quit(true);return end
application.add_thread(function()
  local core=require 'core';local uv=require 'uv';local proc=require 'proc';local Client=require 'terminal.client'
  local shell=require 'shell';local ws=require 'shell.workspaces.bmux';local config=require 'core.config'
  local command=require 'core.command';local TerminalView=require 'core.terminalview'
  local daemon,admin,joined,local_view;local original_config=config.bmux_server
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function tick()core.redraw=true;coroutine.yield(0)end
  local function await(check)
    local until_at=system.get_time()+8
    repeat tick();if check()then return end until system.get_time()>until_at
    error('Studio layout deadline; current='..tostring(shell.current)..'; session='..tostring(joined and joined.client.status)..'; error='..tostring(joined and joined.error)..'; daemon='..(daemon and daemon:result().out or ''))
  end
  local function good(fn)
    local done,why,result=false
    fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
    assert(not why,why and why.message);return result
  end
  local function request(method,path,body)return good(function(cb)admin:request(method,path,body,cb)end)end
  local function key(name,mods)
    system._test_event{type='keypressed',key=name,modifiers=mods or 0};system._test_event{type='keyreleased',key=name,modifiers=mods or 0}
  end
  local function text(value)
    system._test_event{type='keypressed',key='T'};system._test_event{type='textinput',text=value};system._test_event{type='keyreleased',key='T'}
  end
  local function click(x,y)
    system._test_event{type='mousepressed',button=1,x=math.floor(x),y=math.floor(y)}
    system._test_event{type='mousereleased',button=1,x=math.floor(x),y=math.floor(y)}
  end
  local function button(label)
    local hit
    await(function()for _,r in ipairs(ws.toolbar.hits)do if r.item.label==label then hit=r;return true end end end)
    click(hit.x+hit.w/2,hit.y+hit.h/2);tick()
  end
  local ok,err=xpcall(function()
    local dir=assert(uv.fs_mkdtemp('/tmp/bmux-studio-layout-XXXXXX'));local socket=dir..'/sock'
    assert(uv.fs_mkdir(dir..'/home',448))
    daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
      ..q(require('core.agentlauncher').boggart_command())..' serve --socket '..q(socket),60)
    await(function()local info=uv.fs_lstat(socket);return info and info.mode&63==0 end)
    admin=Client.new{socket=socket};local ready,probing=false,false
    await(function()
      if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
      return ready
    end)
    local layout=request('GET','/layout')
    local function edit(op,args)
      layout=request('GET','/layout')
      local c={op=op,host_id=layout.host_id,revision=layout.revision}
      for k,v in pairs(args or {})do c[k]=v end
      layout=request('POST','/layout/commands',c);return layout
    end
    edit('workspace_create',{title='Shared 🦊'});local w=layout.workspaces[1];local s=w.surfaces[1]
    local script=[[stty -echo; printf 'SERVER_READY 🦊\r\n'; while IFS= read -r line; do printf 'ECHO:%s\r\n' "$line"; done]]
    local one=request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=60,rows=8,history=16})
    local two=request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=60,rows=8,history=16})
    edit('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,view={kind='terminal',terminal_id=one.id,generation=1,title='One 🦊'}})
    edit('pane_split',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,direction='right',view={kind='terminal',terminal_id=two.id,generation=1,title='Two'}})
    local left,right=layout.workspaces[1].surfaces[1].tree.a.id,layout.workspaces[1].surfaces[1].tree.b.id
    local previous_mode=shell.current
    local pending=require('core.bmuxlayout').join(socket)
    core.command_view:enter('Hold join',function()end)
    await(function()return pending.client.status=='live'end)
    assert(not ws.session and shell.current==previous_mode,'a delayed join does not steal an open dialog')
    key('Escape');await(function()return ws.session==pending end);pending:disconnect()
    ws.suppress_initial=true;shell.switch('bmux');ws.suppress_initial=nil
    local_view=ws.open(nil,{cmd='/bin/sh',args={'-c','printf LOCAL; IFS= read -r line'},title='Local preserved'})
    local local_pid=local_view.terminal:process_state().pid;local local_source=local_view.terminal
    local before_node=core.root_view.root_node:get_node_for_view(local_view);local local_id=before_node.id
    local local_doc=core.open_doc();local_doc:text_input('unsaved local text')
    local local_doc_view=require('core.docview')(local_doc)
    before_node:add_view(local_doc_view);before_node:set_active_view(local_view)
    config.bmux_server={socket=socket}
    button('Join layout');assert(core.active_view==core.command_view);key('Return')
    await(function()joined=ws.session;return joined and joined.applied_revision==layout.revision end)
    local v1,v2
    await(function()
      for _,view in pairs(joined.pool)do if view.remote.id==one.id then v1=view elseif view.remote.id==two.id then v2=view end end
      return v1 and v2 and v1.remote:status()=='read-only' and v2.remote:status()=='read-only'
    end)
    assert(core.active_view==v2 and not local_view.remote and local_view.terminal==local_source)
    local retained=false;for _,doc in ipairs(core.docs)do if doc==local_doc then retained=true end end
    assert(retained and local_doc:is_dirty(),'hidden local documents retain unsaved-change tracking while joined')
    assert(v1.remote:process_state().pid==one.pid and v2.remote:process_state().pid==two.pid)
    local attachment=v1.remote.session.attachment_id;local renderer_context=v1.render_context
    edit('pane_swap',{workspace_id=w.id,surface_id=s.id,pane_id=left,target_pane_id=right})
    await(function()return joined.applied_revision==layout.revision end)
    assert(joined.pool[v1.bmux_view_id]==v1 and v1.remote.session.attachment_id==attachment and v1.render_context==renderer_context)
    -- Closing a named background tab sends one mutation, preserving its foreground.
    edit('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=left,view={kind='terminal',terminal_id=one.id,generation=1,title='Background'}})
    local background=layout.workspaces[1].surfaces[1].tree.a.views[2].id
    edit('pane_focus',{workspace_id=w.id,surface_id=s.id,pane_id=left,view_id=v2.bmux_view_id})
    await(function()return joined.applied_revision==layout.revision end)
    local node=joined:content():get_node_for_view(v2);local revision=layout.revision
    local x,y,size=node:get_tab_close_rect(2);click(x+size/2,y+size/2)
    await(function()return joined.pool[background]==nil and not joined.sending end)
    layout=request('GET','/layout');assert(layout.revision==revision+1 and core.active_view==v2,'tab close is one server command without focus theft')
    -- Actual controller-header click and SDL text reach the reused server PTY.
    local control_hit
    await(function()for _,r in ipairs(v1.remote_header.hits)do if r.item.label=='Take control'then control_hit=r;return true end end end)
    click(control_hit.x+control_hit.w/2,control_hit.y+control_hit.h/2)
    await(function()return core.active_view==v1 and v1.remote:can_control()and not v1.remote.busy end)
    text('AFTER_JOIN 🦊');key('Return')
    await(function()
      local out={};for _,row in ipairs(v1.remote.snapshot.screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end end
      return table.concat(out):find('ECHO:AFTER_JOIN 🦊',1,true)
    end)
    -- Drag several motions in one frame; all deltas contribute to the final ratio.
    local content=joined:content();local ratio=content.divider;local width=content.size.x
    local dx,dy,dw,dh=content:get_divider_rect();local px,py=math.floor(dx+dw/2),math.floor(dy+dh/2)
    system._test_event{type='mousepressed',button=1,x=px,y=py}
    for i=1,3 do system._test_event{type='mousemoved',x=px+i*10,y=py,dx=10,dy=0}end
    system._test_event{type='mousereleased',button=1,x=px+30,y=py}
    await(function()return not joined.sending and not joined.resize_pending and math.abs(joined:content().divider-(ratio+30/width))<.002 end)
    assert(command.perform('root:move-pane-left'))
    await(function()return joined:content():get_node_for_view(v1).remote_id==left and not joined.sending end)
    local terminal=require 'terminal';local mods=terminal.CTRL|terminal.ALT
    system._test_event{type='keypressed',key='Left Ctrl',modifiers=terminal.CTRL}
    system._test_event{type='keypressed',key='Left Alt',modifiers=mods};key('Right',mods)
    system._test_event{type='keyreleased',key='Left Alt',modifiers=terminal.CTRL}
    system._test_event{type='keyreleased',key='Left Ctrl',modifiers=0}
    await(function()return core.active_view==v2 and not joined.sending end)
    assert(command.perform('bmux:zoom'))
    await(function()return joined:content().zoomed~=nil and not joined.sending end)
    assert(command.perform('bmux:next-pane'))
    await(function()return not joined:content().zoomed and not joined.sending end)
    button('Workspaces');key('Return');tick();assert(core.command_view.label=='Workspace name: ')
    text('Scratch 🦊');key('Return')
    await(function()return joined.applied_workspace and joined.applied_workspace.title=='Scratch 🦊'and not joined.sending end)
    assert(not core.active_view:is(TerminalView),'empty server workspace does not spawn a local PTY')
    button('Surfaces');key('Return');tick();assert(core.command_view.label=='Surface name: ')
    text('Extra');key('Return')
    await(function()return joined.applied_surface.title=='Extra'and not joined.sending end)
    button('Workspaces');core.command_view:set_text('1 · Shared');key('Return')
    await(function()return joined.workspace_id==w.id and not joined.sending end)
    assert(joined.pool[v1.bmux_view_id]==v1 and v1.remote.session.attachment_id==attachment,'surface switching reuses the original attachment')
    button('+ New terminal')
    local third
    await(function()
      for _,view in pairs(joined.pool)do if view~=v1 and view~=v2 and view.remote and view.remote:status()=='read-only'then third=view end end
      return third and not joined.sending and not joined.launching
    end)
    assert(third.remote:process_state().pid~=local_pid and core.active_view==third,'New terminal creates a server process and a layout reference')
    button('Split down');local fourth
    await(function()
      for _,view in pairs(joined.pool)do if view~=v1 and view~=v2 and view~=third and view.remote and view.remote:status()=='read-only'then fourth=view end end
      return fourth and not joined.sending and not joined.launching
    end)
    assert(#joined:content():get_leaves()==3 and core.active_view==fourth)
    button('Close');await(function()return not joined.pool[fourth.bmux_view_id]and not joined.sending end)
    local closed_reference=request('GET','/terminals/'..fourth.remote.id)
    assert(closed_reference.state=='alive'and uv.kill(closed_reference.pid,0),'Close removes a reference without stopping the server terminal')
    button('Close');await(function()return not joined.pool[third.bmux_view_id]and not joined.sending end)
    assert(#joined:content():get_leaves()==2)
    shell.switch('edit');local edit_view=core.active_view
    layout=request('GET','/layout');edit('workspace_rename',{workspace_id=w.id,title='Changed while editing'})
    await(function()return joined.applied_revision==layout.revision end)
    assert(shell.current=='edit' and core.active_view==edit_view,'server updates do not replace the active Edit tree')
    shell.switch('bmux');assert(core.root_view:get_active_node().bmux_owner==joined)
    core.command_view:enter('Keep focus',function()end)
    local applied=joined.applied_revision
    edit('workspace_rename',{workspace_id=w.id,title='Shared layout 🦊'})
    await(function()return joined.client.revision==layout.revision end)
    assert(core.active_view==core.command_view and joined.applied_revision==applied,'modal owns focus until it closes')
    key('Escape');await(function()return joined.applied_revision==layout.revision end)
    assert(v1.remote.session.attachment_id==attachment)
    joined.client.watch:cancel();await(function()return joined.client.status=='disconnected'end)
    button('Refresh / reconnect');await(function()return joined.client.status=='live'and joined.applied_revision==layout.revision end)
    assert(v1.remote.session.attachment_id==attachment and v1.render_context==renderer_context,'layout observation reconnect preserves terminal input/renderer attachments')
    if os.getenv('BMUX_RENDER_DIR')then tick();assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/joined-layout.bmp'))end
    -- The process is created by the real server, then observation drops before
    -- its reference can be admitted. The UI must report where to recover it.
    local real_request=joined.client.transport.request;local unplaced
    joined.client.transport.request=function(self,method,path,body,callback,stream)
      if method=='POST'and path=='/terminals'then
        return real_request(self,method,path,body,function(why,record,status)
          if not why then joined.client.watch:cancel();unplaced=record end
          callback(why,record,status)
        end,stream)
      end
      return real_request(self,method,path,body,callback,stream)
    end
    button('+ New terminal');await(function()return unplaced and not joined.launching end)
    joined.client.transport.request=real_request
    local reported=false
    for _,item in ipairs(core.log_items)do if item.text:find('Terminal remains on server',1,true)and item.text:find(unplaced.id,1,true)then reported=true end end
    assert(joined.client.status=='disconnected'and reported,
      'unplaced process is reported for explicit recovery after reconnect')
    assert(request('GET','/terminals/'..unplaced.id).state=='alive')
    button('Refresh / reconnect');await(function()return joined.client.status=='live'end)
    button('Disconnect layout')
    assert(not ws.session and core.active_view==local_view and local_view.terminal==local_source)
    assert(core.root_view.root_node:get_node_for_view(local_view).id==local_id and uv.kill(local_pid,0))
    assert(request('GET','/terminals/'..one.id).pid==one.pid and request('GET','/terminals/'..two.id).pid==two.pid)
    assert(uv.kill(one.pid,0)and uv.kill(two.pid,0),'disconnect keeps both original processes alive')
    button('Join layout');key('Return');await(function()return ws.session and ws.session~=joined and not ws.session.sending end)
    button('+ Local agent');assert(ws.session and core.active_view==core.command_view and core.command_view.label=='New agent: ')
    core.command_view:set_text('Custom agent command');key('Return')
    await(function()return core.command_view.label=='Agent command (quoted arguments): 'end)
    text('/bin/sh -c "printf LOCAL_AGENT; IFS= read -r line"');key('Return')
    local agent_view
    await(function()
      agent_view=core.active_view
      return not ws.session and agent_view:is(TerminalView)and not agent_view.remote and agent_view.fleet_agent_id
    end)
    local agent=require('fleet').default.agents[agent_view.fleet_agent_id]
    assert(agent.provider=='custom'and agent.capabilities.focus and local_view.terminal==local_source,'local agent launch retains Fleet registration and the original local tree')
    assert(command.perform('bmux:close-terminal'));tick()
    assert(agent.retired);core.root_view.root_node:get_node_for_view(local_view):set_active_view(local_view)
    layout=request('GET','/layout');local workspaces=layout.workspaces
    for _,workspace in ipairs(workspaces)do edit('workspace_remove',{workspace_id=workspace.id})end
    button('Join layout');key('Return');await(function()return ws.session and not ws.session.applied_workspace end)
    button('+ New terminal')
    await(function()return ws.session.applied_workspace and ws.session.applied_workspace.title=='Bmux'
      and core.active_view:is(TerminalView)and core.active_view.remote and core.active_view.remote:status()=='read-only'end)
    button('Disconnect layout');assert(core.active_view==local_view and not ws.session)
    assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
    print('studio_bmux_layout: server tree, SDL join/tab/focus/drag/input/selectors/create/close, retained docs/attachments/modes, reconnect/Fleet and local restoration pass')
  end,debug.traceback)
  config.bmux_server=original_config
  if ws.session then ws.session:disconnect()end
  if local_view and local_view.terminal then local_view:try_close(function()end)end
  if admin then admin:close()end
  if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
  if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  application.quit(true)
end)
