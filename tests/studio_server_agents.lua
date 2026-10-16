local application=require 'core'
if package.config:sub(1,1)=='\\'then application.quit(true);return end
application.add_thread(function()
  local core=require 'core';local uv=require 'uv';local proc=require 'proc';local Native=require 'terminal.client'
  local shell=require 'shell';local ws=require 'shell.workspaces.bmux';local config=require 'core.config'
  local launcher=require 'core.agentlauncher';local registry=require('core.fleetagents').registry
  local View=require 'core.terminalview';local daemon,admin,joined,local_view
  local old_config=config.bmux_server
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function tick()core.redraw=true;coroutine.yield(0)end
  local function await(check,label)
    local until_at=system.get_time()+8
    repeat tick();if check()then return end until system.get_time()>until_at
    error((label or 'joined agent deadline')..'; daemon='..(daemon and daemon:result().out or 'none'))
  end
  local function good(fn)
    local done,why,value=false;fn(function(e,v)done=true;why=e;value=v end)
    await(function()return done end);assert(not why,why and why.message);return value
  end
  local function request(method,path,body)return good(function(cb)admin:request(method,path,body,cb)end)end
  local function key(name,mods)
    system._test_event{type='keypressed',key=name,modifiers=mods or 0};system._test_event{type='keyreleased',key=name,modifiers=mods or 0}
  end
  local function click(x,y)
    system._test_event{type='mousepressed',button=1,x=math.floor(x),y=math.floor(y)}
    system._test_event{type='mousereleased',button=1,x=math.floor(x),y=math.floor(y)}
  end
  local function toolbar(label)
    local hit
    await(function()for _,r in ipairs(ws.toolbar.hits)do if r.item.label==label then hit=r;return true end end end)
    click(hit.x+hit.w/2,hit.y+hit.h/2);tick()
  end
  local function remote(id)return joined.agents.source:find(id)end
  local fleet
  local function show_fleet(row)
    shell.switch('fleet');fleet=require('core.swarmview').ensure();fleet.selected=row.id
    for _=1,3 do tick()end
  end
  local function action(label)
    local hit
    await(function()for _,r in ipairs(fleet.hits)do if r.item.label==label then hit=r;return true end end end)
    click(hit.x+hit.w/2,hit.y+hit.h/2);tick()
  end
  local function prompt(row,text)
    show_fleet(row);action('Send prompt')
    assert(core.active_view==core.command_view);core.command_view:set_text(text);key('Return')
  end
  local function output(view)
    local out={};local snapshot=view.remote and view.remote.snapshot
    if snapshot then for _,row in ipairs(snapshot.screen)do for _,c in ipairs(row.cells)do out[#out+1]=c.text end;out[#out+1]='\n'end end
    return table.concat(out)
  end
  local ok,why=xpcall(function()
    core.project_dir=system.absolute_path('.')
    local dir=assert(uv.fs_mkdtemp('/tmp/bmux-studio-agents-XXXXXX'));local socket=dir..'/sock'
    assert(uv.fs_mkdir(dir..'/home',448))
    daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
      ..q(launcher.boggart_command())..' serve --socket '..q(socket),90)
    await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket'and info.mode&63==0 end)
    admin=Native.new{socket=socket};local ready,probing=false,false
    await(function()
      if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
      return ready
    end)
    local local_rec
    local_rec,local_view=launcher.launch{provider='custom',name='Local preserved',cmd='/bin/sh',args={'-c','printf LOCAL; IFS= read -r line'}}
    await(function()return local_rec.pid end)
    local local_source,local_pid=local_view.terminal,local_rec.pid
    config.bmux_server={socket=socket}
    toolbar('Join layout');key('Return')
    await(function()joined=ws.session;return joined and joined.agents.client and joined.agents.client.live end)
    -- Only the selected profile's model driver is substituted; all UI, native
    -- daemon/PTY/session/channel/control and permission paths remain actual.
    local launch=joined.agents.launch
    joined.agents.launch=function(self,profile)
      if profile.provider=='boggart'and not profile.args and not profile.resume_id then
        local copy={};for k,v in pairs(profile)do copy[k]=v end
        copy.cmd=launcher.boggart_command();copy.args={'--eval',core.project_dir..'/tests/fixtures/agent_control_tui.lua'};profile=copy
      end
      return launch(self,profile)
    end
    toolbar('+ New agent');assert(core.command_view.label=='New server agent: ');key('Return')
    local pane,agent
    await(function()
      pane=core.active_view
      if pane:is(View)and pane.bmux_agent_id then agent=remote(pane.bmux_agent_id)end
      return agent and agent.capabilities.prompt and pane.remote and pane.remote:status()=='read-only'
    end,'real server Boggart launch and agent view')
    local agent_id,pid,sid=agent.remote_id,agent.pid,agent.session_id
    assert(registry:get(agent.id)==agent and registry:get(local_rec.id)==local_rec and local_view.terminal==local_source)
    assert(pane.remote:process_state().pid==pid and request('GET','/terminals').total==1)
    local attachment=pane.remote.session.attachment_id;local render=pane.render_context
    prompt(agent,'from joined Fleet')
    await(function()return output(pane):find('FIXTURE_ANSWER:from joined Fleet',1,true)and agent.state=='idle'end)
    assert(shell.current=='fleet'and agent.pid==pid and agent.session_id==sid)
    action('New server agent');assert(core.command_view.label=='New server agent: ');key('Escape');tick()
    assert(request('GET','/terminals').total==1,'cancelling the Fleet server launcher creates no runtime')
    action('Focus pane');await(function()return shell.current=='bmux'and core.active_view==pane end)
    local hit
    await(function()for _,r in ipairs(pane.remote_header.hits)do if r.item.label=='Take control'then hit=r;return true end end end)
    click(hit.x+hit.w/2,hit.y+hit.h/2);await(function()return pane.remote:can_control()and not pane.remote.busy end)
    system._test_event{type='textinput',text='human draft'}
    await(function()return agent.draft_bytes==11 end)
    prompt(agent,'must not overwrite')
    await(function()return agent.control_result and not agent.control_result.accepted end)
    assert(agent.draft_bytes==11 and output(pane):find('human draft',1,true))
    assert(pane.remote:write('\21'));await(function()return agent.draft_bytes==0 end)
    prompt(agent,'approval');await(function()return agent.state=='waiting_for_approval'and agent.request end)
    local first=agent.request.id;local stale
    for _,item in ipairs(require('core.fleetactions').external(fleet,agent))do if item.label=='Approve'then stale=item;break end end
    if os.getenv('BMUX_RENDER_DIR')then tick();assert(system.save_screenshot(os.getenv('BMUX_RENDER_DIR')..'/server-agent-fleet.bmp'))end
    action('Reject');await(function()return agent.state=='idle'and output(pane):find('FIXTURE_REJECTED',1,true)end)
    prompt(agent,'approval');await(function()return agent.request and agent.request.id~=first end)
    local current=agent.request.id;local sequence=joined.agents.client.sequence
    stale.action();tick();assert(agent.request.id==current and joined.agents.client.sequence==sequence,'stale approval widget cannot transfer to another request')
    action('Approve');await(function()return agent.state=='idle'and output(pane):find('FIXTURE_APPROVED',1,true)end)
    prompt(agent,'wait');await(function()return agent.state=='running'and agent.capabilities.interrupt end)
    action('Interrupt');await(function()return agent.state=='idle'end)
    prompt(agent,'workers');local children
    await(function()
      children={};local live,done,failed=0,0,0
      for _,r in ipairs(joined.agents.source.rows)do if r.parent==agent.id then
        children[#children+1]=r
        if r.state=='running'then live=live+1 elseif r.state=='exited'then done=done+1 elseif r.state=='failed'then failed=failed+1 end
      end end
      return #children==5 and live==2 and done==2 and failed==1
    end)
    for _,child in ipairs(children)do if child.state=='running'then
      show_fleet(child);action('Focus pane');await(function()return core.active_view==pane end)
      show_fleet(child);action('Cancel worker');await(function()return child.state=='stopped'end)
    end end
    await(function()return agent.state=='idle'end)
    assert(pane.remote.session.attachment_id==attachment and pane.render_context==render and agent.pid==pid and agent.session_id==sid)
    show_fleet(agent);action('Focus pane');await(function()return core.active_view==pane end)
    toolbar('Close');await(function()return pane.remote.closed end)
    assert(uv.kill(pid,0)and agent.capabilities.prompt,'closing the agent view retains its server runtime')
    show_fleet(agent);action('Focus pane');local reopened
    await(function()reopened=core.active_view;return reopened:is(View)and reopened.bmux_agent_id==agent_id and reopened.remote:status()=='read-only'end)
    assert(reopened~=pane and reopened.remote:process_state().pid==pid)

    -- A real launch commits, but its acknowledgement is lost. Only the visible
    -- Retry choice may resend it, preserving exactly one native execution.
    local client=joined.agents.client;local original=client.transport.request;local sent={};local lost=false
    client.transport.request=function(self,method,path,body,cb,stream)
      if path=='/fleet/launch'then
        sent[#sent+1]=body
        return original(self,method,path,body,function(e,v,status)
          if not lost and not e then lost=true;cb({kind='timeout',message='fixture lost launch acknowledgement'})else cb(e,v,status)end
        end,stream)
      end
      return original(self,method,path,body,cb,stream)
    end
    toolbar('+ New agent');core.command_view:set_text('Custom agent command');key('Return')
    await(function()return core.command_view.label=='Server agent command (quoted arguments): 'end)
    core.command_view:set_text('/bin/sh -c "printf FOREIGN; IFS= read -r line"');key('Return')
    await(function()return client.pending and client.uncertain end)
    local before=request('GET','/terminals').total
    toolbar('+ New agent');key('Return')
    await(function()return not client.pending and not joined.sending and core.active_view:is(View)and core.active_view.bmux_agent_id~=agent_id end)
    assert(#sent==2 and sent[1]==sent[2]and request('GET','/terminals').total==before,'visible Retry cannot duplicate the committed agent')
    client.transport.request=original
    local foreign=remote(core.active_view.bmux_agent_id)
    await(function()return foreign and foreign.capabilities.stop end)
    assert(foreign.provider=='custom'and not foreign.capabilities.prompt)
    show_fleet(foreign);action('Stop');await(function()return foreign.state=='stopped'end)
    show_fleet(agent);action('Focus pane');await(function()return shell.current=='bmux'end)
    local mounted_id=agent.id
    toolbar('Disconnect layout');assert(not registry:get(mounted_id)and registry:get(local_rec.id)==local_rec)
    assert(core.active_view==local_view and local_view.terminal==local_source and uv.kill(local_pid,0)and uv.kill(pid,0))
    toolbar('Join layout');key('Return')
    await(function()joined=ws.session;return joined and joined.agents.source and joined.agents.source:find(agent_id)and core.active_view:is(View)and core.active_view.bmux_agent_id==agent_id and core.active_view.remote.snapshot end)
    assert(core.active_view.remote:process_state().pid==pid and remote(agent_id).session_id==sid)
    assert(registry:get(mounted_id)~=agent,'rejoin invalidates stale local action objects')
    toolbar('Disconnect layout')
    assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
    print('studio server agents: visible native launch/Fleet prompt/draft/approval/interrupt/workers, focus/reopen, exact retry, foreign Stop, local roster and same-PID rejoin pass')
  end,debug.traceback)
  config.bmux_server=old_config
  if ws.session then ws.session:disconnect()end
  if local_view and local_view.terminal then local_view:try_close(function()end)end
  if admin then admin:close()end
  if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
  if not ok then io.stderr:write(tostring(why),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  application.quit(true)
end)
