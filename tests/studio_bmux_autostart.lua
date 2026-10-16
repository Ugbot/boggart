-- Prove default Studio Bmux entry owns a stable detached project server and
-- reconnects to its live agents after the entire Studio process is replaced.
local application=require 'core'
application.add_thread(function()
  local uv=require 'uv';local core=require 'core';local shell=require 'shell'
  local config=require 'core.config';local ws=require 'shell.workspaces.bmux'
  local launcher=require 'core.agentlauncher';local Local=require 'core.bmuxlocal'
  local Native=require 'terminal.client';local json=require 'json'
  local marker=os.getenv('BMUX_AUTOSTART_STATE');local pidfile=os.getenv('BMUX_AUTOSTART_PIDFILE')
  local phase=os.getenv('BMUX_AUTOSTART_PHASE');local fixture_dir;local wrong_handle,wrong_pid
  local function tick()core.redraw=true;coroutine.yield(0)end
  local function await(check,label,seconds)
    local deadline=system.get_time()+(seconds or 20)
    repeat tick();if check()then return true end until system.get_time()>deadline
    local state=Local.status(core.project_dir)
    error((label or 'managed Bmux deadline')..' expired: '
      ..json.encode{local_status=ws.local_status,connecting=ws.local_connecting,manager_status=state and state.status,
        manager_message=state and state.message,project=core.project_dir,userdir=bog.userdir})
  end
  local function write(path,value)
    local file=assert(io.open(path,'wb'));assert(file:write(value));assert(file:close())
  end
  local function read(path)
    local file=assert(io.open(path,'rb'));local data=assert(file:read('*a'));assert(file:close());return data
  end
  local function rpc(socket,method,path,body)
    local client=Native.new{socket=socket,timeout_ms=3000};local done,why,value=false
    client:request(method,path,body,function(e,v)why=e;value=v;done=true end)
    await(function()return done end,'managed server request');client:close();assert(not why,why and why.message);return value
  end
  local function stop_wrong_server()
    if wrong_pid then pcall(uv.kill,wrong_pid,'sigterm')end
    if wrong_handle and not wrong_handle:is_closing()then wrong_handle:close()end
    wrong_handle=nil;wrong_pid=nil
  end
  local function check_project_paths()
    local root=assert(uv.fs_mkdtemp('/tmp/bmux-project-paths-XXXXXX'))
    local other=assert(uv.fs_mkdtemp('/tmp/bmux-project-paths-XXXXXX'))
    local alias=root..'-alias';assert(uv.fs_symlink(root,alias))
    local first=assert(Local.project_paths(root,bog.userdir))
    local same=assert(Local.project_paths(alias,bog.userdir))
    local distinct=assert(Local.project_paths(other,bog.userdir))
    assert(first.root==same.root and first.socket==same.socket,'symlink spelling resolves to one project identity')
    assert(first.socket~=distinct.socket and first.session~=distinct.session,'separate projects get separate servers')
    local private=assert(uv.fs_stat(bog.userdir..'/bmux'))
    assert(private.type=='directory' and private.mode&63==0,'project socket directory is private')
    local long,long_error=Local.project_paths(root,'/'..string.rep('x',100))
    assert(not long and long_error.message:find('Unix%-socket limit'),'long native socket paths fail with a clear error')
    assert(uv.fs_chmod(bog.userdir..'/bmux',493))
    local unsafe,unsafe_error=Local.project_paths(root,bog.userdir)
    assert(not unsafe and unsafe_error.message:find('private directory'),'unsafe socket directory is refused')
    assert(uv.fs_chmod(bog.userdir..'/bmux',448))
    assert(uv.fs_unlink(alias));assert(uv.fs_rmdir(root));assert(uv.fs_rmdir(other))
  end
  local function check_wrong_session(project)
    local paths=assert(Local.project_paths(project,bog.userdir))
    local handle,pid=uv.spawn(launcher.boggart_command(),{args={'serve','--socket',paths.socket,'--bmux-session','wrong-project-session'},
      cwd=project,detached=true,stdio={nil,nil,nil}},function()end)
    assert(handle,'start identity-check fixture server');wrong_handle,wrong_pid=handle,pid;uv.unref(handle)
    write(pidfile,tostring(pid))
    await(function()local st=uv.fs_lstat(paths.socket);return st and st.type=='socket'end,'wrong-session fixture socket')
    core.project_dir=project;local done,why=false
    Local.ensure(function(e)why=e;done=true end)
    await(function()return done end,'wrong-session rejection')
    assert(why and why.kind=='identity','an unrelated named session is rejected without adopting it')
    local state=Local.status(project);assert(state and not state.spawned,'identity mismatch never starts a second daemon')
    assert(uv.kill(pid,0),'wrong-session server remains untouched after refusal')
    shell.switch('bmux')
    local View=require 'core.terminalview'
    await(function()
      return ws.local_status and not ws.local_connecting and core.active_view and core.active_view:is(View)
        and core.active_view.terminal
    end,'safe local fallback for a wrong-session socket')
    local fallback=core.active_view
    assert(not ws.session and uv.kill(pid,0)and uv.fs_lstat(paths.socket),
      'fallback remains usable without stopping or adopting the unrelated server')
    shell.switch('edit')
    if fallback.terminal then fallback:try_close(function()end)end
    stop_wrong_server()
    write(pidfile,'')
    await(function()return not uv.fs_lstat(paths.socket)end,'wrong-session socket cleanup')
  end
  local function row(client,id)
    return client and client:find(id)
  end
  local function add_agents()
    local session=assert(ws.session);local client=assert(session.agents.client)
    local function wait_placed(id,label)
      await(function()
        if session.sending or session.launching then return false end
        for _,view in pairs(session.pool)do if view.bmux_agent_id==id then return true end end
        return false
      end,label)
    end
    session.agents:launch{provider='boggart',name='Boggart TUI'}
    await(function()
      for _,item in pairs(client.records or {})do if item.provider=='boggart'and item.pid and item.terminal_id then return true end end
    end,'Boggart Fleet registration')
    local boggart
    for _,item in pairs(client.records)do if item.provider=='boggart'and item.pid and item.terminal_id then boggart=item end end
    wait_placed(boggart.id,'Boggart layout placement')
    session.agents:launch{provider='codex',cmd='codex',name='Codex fixture'}
    await(function()
      for _,item in pairs(client.records or {})do if item.provider=='codex'and item.pid and item.terminal_id then return true end end
    end,'Codex Fleet registration')
    local codex
    for _,item in pairs(client.records)do if item.provider=='codex'and item.pid and item.terminal_id then codex=item end end
    assert(boggart and codex,'both providers are published by the server')
    wait_placed(codex.id,'Codex layout placement')
    local registry=require('core.fleetagents').registry
    for _,item in ipairs{boggart,codex}do
      local wire=row(client,item.id);local shared=registry:get('remote:'..client.host_id..':string:'..item.id)
      assert(wire and shared and shared.remote_id==item.id and shared.fleet_remote,'server agents appear in common Fleet')
    end
    return {boggart={id=boggart.id,generation=boggart.generation,pid=boggart.pid},
      codex={id=codex.id,generation=codex.generation,pid=codex.pid}}
  end
  local function focus(record)
    local session=assert(ws.session);local item=session.agents.client:find(record.id)
    assert(item and item.generation==record.generation and item.pid==record.pid,'restored Fleet identity and process are unchanged')
    session.agents:focus(item.id,item.generation)
    await(function()return core.active_view and core.active_view.bmux_agent_id==item.id end,'focus existing Fleet agent')
  end

  local ok,err=xpcall(function()
    assert(phase=='first'or phase=='second','unknown integration-test phase')
    local project=assert(uv.fs_realpath(os.getenv('BMUX_AUTOSTART_PROJECT')))
    core.project_dir=project;config.bmux_server=nil
    if phase=='first'then
      check_project_paths()
      local wrong=assert(uv.fs_mkdtemp('/tmp/bmux-wrong-session-XXXXXX'))
      check_wrong_session(wrong);assert(uv.fs_rmdir(wrong))
      core.project_dir=project
      fixture_dir=assert(uv.fs_mkdtemp('/tmp/bmux-codex-fixture-XXXXXX'))
      local fixture=assert(io.open(fixture_dir..'/codex','wb'))
      fixture:write(read('tests/fixtures/bmux_fake_codex.sh'));assert(fixture:close())
      assert(uv.fs_chmod(fixture_dir..'/codex',493))
      assert(uv.os_setenv('PATH',fixture_dir..':'..(os.getenv('PATH')or'')))
      shell.switch('bmux')
      await(function()
        local managed=Local.status(project);if managed and managed.pid then write(pidfile,tostring(managed.pid))end
        return ws.session and ws.session.managed_local and ws.session.client.status=='live'
      end,'automatic project-server entry')
      local paths=assert(Local.project_paths(project,bog.userdir));local state=assert(Local.status(project))
      assert(state.status=='ready'and state.pid and uv.kill(state.pid,0),'Studio owns a live detached server process')
      local first_pid=state.pid;local completed,problem
      Local.ensure(function(e)problem=e;completed=true end)
      await(function()return completed end,'single-flight ready-server check')
      assert(not problem and state.pid==first_pid,'reentry reuses the one project server')
      local agents=add_agents()
      ws.session:open_terminal()
      local shell_record
      await(function()
        local list=rpc(paths.socket,'GET','/terminals')
        for _,item in ipairs(list.terminals)do
          if item.cmd=='/bin/sh'and item.cwd==project and item.pid then shell_record=item;return true end
        end
      end,'project shell terminal')
      await(function()return rpc(paths.socket,'GET','/layout/session').writes>0 end,'checkpoint journal writes')
      local value={socket=paths.socket,session=paths.session,host_id=ws.session.client.host_id,server_pid=first_pid,
        project=project,fixture_dir=fixture_dir,shell={id=shell_record.id,pid=shell_record.pid},agents=agents}
      write(marker,json.encode(value));write(pidfile,tostring(first_pid))
      print('studio Bmux autostart phase one: private stable identity, wrong-session refusal, detached server and common Boggart/Codex Fleet pass')
    else
      local value=json.decode(read(marker));assert(value.project==project,'both Studio launches use the same project')
      assert(uv.kill(value.server_pid,0),'project server process survives the first Studio process')
      assert(uv.os_setenv('PATH',value.fixture_dir..':'..(os.getenv('PATH')or'')))
      shell.switch('bmux')
      await(function()return ws.session and ws.session.managed_local and ws.session.client.status=='live'end,'automatic rejoin after Studio restart')
      assert(ws.session.client.host_id==value.host_id,'rejoin preserves the server identity')
      local state=assert(Local.status(project));assert(state.status=='ready'and not state.spawned,'rejoin adopts the existing daemon')
      local agents=ws.session.agents.client
      await(function()
        local a=agents:find(value.agents.boggart.id);local b=agents:find(value.agents.codex.id)
        return a and b and a.pid==value.agents.boggart.pid and b.pid==value.agents.codex.pid
      end,'same live agents after Studio restart')
      focus(value.agents.boggart);focus(value.agents.codex)
      for _,record in pairs(value.agents)do assert(uv.kill(record.pid,0),'agent PTY process survives Studio restart')end
      assert(rpc(value.socket,'GET','/layout/session').writes>0,'rejoined project retains its journal')
      local server_pid=value.server_pid;assert(uv.kill(server_pid,'sigterm'))
      await(function()return not uv.kill(server_pid,0)end,'managed server shutdown')
      await(function()return not uv.fs_lstat(value.socket)end,'managed socket shutdown')
      for _,record in pairs(value.agents)do await(function()return not uv.kill(record.pid,0)end,'agent shutdown')end
      await(function()return not uv.kill(value.shell.pid,0)end,'shell shutdown')
      ws.retry_local()
      await(function()
        local managed=Local.status(project)
        if managed and managed.pid then write(pidfile,tostring(managed.pid))end
        return managed and managed.pid and ws.session and ws.session.managed_local
          and ws.session.client.status=='live'and ws.session.client.host_id~=value.host_id
      end,'managed server journal restart',30)
      local restored=rpc(value.socket,'GET','/layout/session')
      assert(restored.name==value.session and restored.restored and not restored.blocked,
        'daemon restart keeps the project session name and restores its journal')
      local codex
      await(function()
        for _,item in pairs(ws.session.agents.client.records)do
          if item.provider=='codex'and item.name=='Codex fixture'then codex=item;return true end
        end
      end,'foreign agent inactive checkpoint')
      assert(codex.state=='stopped'and not codex.pid and not codex.capabilities.stop,
        'foreign Codex is restored as an inactive Fleet preview')
      local restored_shell
      await(function()
        local list=rpc(value.socket,'GET','/terminals')
        for _,item in ipairs(list.terminals)do
          if item.cmd=='/bin/sh'and item.cwd==project and item.pid then restored_shell=item;return true end
        end
      end,'supported project shell recipe restore')
      assert(restored_shell.id~=value.shell.id and restored_shell.pid~=value.shell.pid
        and uv.kill(restored_shell.pid,0),'saved project shell starts with a fresh process identity')
      assert(ws.session.client.host_id~=value.host_id,'server restart creates a fresh host identity')
      local server_pid=assert(Local.status(project).pid);assert(uv.kill(server_pid,'sigterm'))
      await(function()return not uv.fs_lstat(value.socket)end,'restored server socket shutdown')
      print('studio Bmux autostart phase two: live rejoin, shell journal restore, inactive foreign Codex and cleanup pass')
    end
  end,debug.traceback)
  stop_wrong_server()
  if not ok then
    local project=core.project_dir
    local managed=project and Local.status(project)
    local server_pid=managed and managed.pid
    if not server_pid and phase=='second'and marker then
      pcall(function()server_pid=json.decode(read(marker)).server_pid end)
    end
    if server_pid then pcall(uv.kill,server_pid,'sigterm')end
  end
  if phase=='second'and marker then
    local success,value=pcall(function()return json.decode(read(marker))end)
    if success and value.fixture_dir then
      pcall(uv.fs_unlink,value.fixture_dir..'/codex');pcall(uv.fs_rmdir,value.fixture_dir)
    end
  end
  if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  application.quit(true)
end)
