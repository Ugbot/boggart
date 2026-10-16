-- Start or reconnect to the detached Bmux server owned by this project.
-- The server, layout and PTYs outlive a Studio window; this module owns only
-- local discovery and its short-lived connection probes.
local core=require 'core'
local uv=require 'uv'
local Native=require 'terminal.client'
local M={}

local SOCKET_LIMIT=91 -- terminal.client's conservative native sockaddr_un bound
local STARTUP_LIMIT=10
local RETRY_MS={40,80,160,320,640,1000}
local states={}

local function fail(message)return nil,{kind='bmux_local',message=message}end

local function private_directory(path)
  local info=uv.fs_lstat(path)
  if not info then
    local made,why=uv.fs_mkdir(path,448) -- 0700
    if not made then
      info=uv.fs_lstat(path)
      if not info then return nil,'cannot create '..path..': '..tostring(why)end
    else info=uv.fs_lstat(path)end
  end
  if not info or info.type~='directory' or info.uid~=uv.getuid() or info.mode&63~=0 then
    return nil,'managed Bmux directory must be an owned private directory: '..path
  end
  return true
end

function M.project_paths(project_dir,userdir)
  if type(project_dir)~='string'or project_dir==''or type(userdir)~='string'or userdir:sub(1,1)~='/'then
    return fail('project directory or Boggart data directory is unavailable')
  end
  local root=uv.fs_realpath(project_dir)
  if not root then return fail('cannot resolve project directory: '..project_dir)end
  local hash=require('hash_c').sha256(root)
  local directory=userdir..'/bmux'
  local socket=directory..'/'..hash:sub(1,24)..'.sock'
  if #socket>SOCKET_LIMIT then
    return fail('project socket path exceeds the '..SOCKET_LIMIT..' byte Unix-socket limit; set BOGGART_HOME to a shorter private path')
  end
  local private,why=private_directory(directory)
  if not private then return fail(why)end
  return {root=root,hash=hash,socket=socket,session='studio-'..hash,
    title=root:match('([^/]+)/*$')or root}
end

local function private_socket_path(path)
  local info=uv.fs_lstat(path)
  if not info then return false end
  if info.type~='socket' or info.uid~=uv.getuid() or info.mode&63~=0 then
    return nil,'refusing non-private or non-socket path: '..path
  end
  return true
end

local function notify(state,why,info)
  local callbacks=state.callbacks;state.callbacks={}
  for _,callback in ipairs(callbacks)do
    local ok,err=pcall(callback,why,info)
    if not ok then core.error('Local Bmux callback: %s',tostring(err))end
  end
end

local function finish(state,why,status)
  if state.finished then return end
  state.finished=true;state.timer=nil;state.probe_client=nil
  if why then
    state.status='failed';state.message=why.message or tostring(why)
    notify(state,why)
    return
  end
  state.status='ready';state.message=status.blocked and 'Saved session needs recovery' or 'Connected to project server'
  state.session_status=status
  notify(state,nil,{socket=state.paths.socket,session=state.paths.session,root=state.paths.root,
    title=state.paths.title,status=status,managed=true})
end

local function schedule(state)
  if state.finished or state.timer then return end
  if uv.hrtime()/1e9>=state.deadline then
    finish(state,{kind='timeout',message=state.spawn_error or 'project Bmux server did not become ready before the deadline'})
    return
  end
  local delay=RETRY_MS[math.min(state.retry_index,#RETRY_MS)]
  state.retry_index=state.retry_index+1
  local timer=uv.new_timer();state.timer=timer
  timer:start(delay,0,function()
    timer:stop();timer:close()
    if state.timer==timer then state.timer=nil end
    if not state.finished then state:probe()end
  end)
end

local function spawn(state)
  if state.spawned or state.finished then return end
  state.spawned=true
  local executable=require('core.agentlauncher').boggart_command()
  local args={'serve','--socket',state.paths.socket,'--bmux-session',state.paths.session}
  local handle
  local ok,spawned_handle,pid=pcall(uv.spawn,executable,{args=args,cwd=state.paths.root,detached=true,stdio={nil,nil,nil}},function(code,signal)
    if handle and not handle:is_closing()then handle:close()end
    state.handle=nil
    if not state.finished then
      state.spawn_error=string.format('project Bmux server exited before ready (code %s, signal %s)',tostring(code),tostring(signal))
      schedule(state)
    else
      state.spawned=false;state.status='exited';state.message='Project Bmux server exited'
      core.redraw=true
    end
  end)
  handle=spawned_handle
  if not ok or not handle then
    state.spawn_error='cannot start Boggart server: '..tostring(ok and pid or spawned_handle)
    finish(state,{kind='spawn',message=state.spawn_error});return
  end
  state.handle,state.pid=handle,pid
  uv.unref(handle)
  state.spawned_at=uv.hrtime()/1e9
  schedule(state)
end

local function validate_status(state,value)
  if type(value)~='table'or value.persistent~=true or value.name~=state.paths.session
    or type(value.host_id)~='string'or type(value.blocked)~='boolean' then
    return nil,{kind='identity',message='socket is not the persistent Bmux session for this project'}
  end
  return value
end

function M.cancel(project_dir)
  local root=project_dir and uv.fs_realpath(project_dir)or nil
  local state=root and states[root]
  if not state or state.finished then return false end
  state.finished=true;state.status='cancelled'
  if state.timer then state.timer:stop();state.timer:close();state.timer=nil end
  if state.probe_client then state.probe_client:close();state.probe_client=nil end
  notify(state,{kind='cancelled',message='local Bmux connection cancelled'})
  return true
end

function M.status(project_dir)
  local root=uv.fs_realpath(project_dir or core.project_dir)
  return root and states[root]or nil
end

function M.ensure(callback)
  assert(type(callback)=='function','local Bmux callback required')
  local paths,why=M.project_paths(core.project_dir,bog.userdir)
  if not paths then callback(why);return nil end
  local state=states[paths.root]
  if state and (state.status=='starting'or state.status=='checking')then
    state.callbacks[#state.callbacks+1]=callback;return state
  end
  if state and state.status=='ready'then
    -- Every workspace re-entry revalidates the process. A retained path is not
    -- evidence that the daemon is still serving or that the checkpoint is safe.
    state.finished=false;state.status='checking';state.callbacks={callback}
    state.deadline=uv.hrtime()/1e9+STARTUP_LIMIT;state.retry_index=1
  else
    state={paths=paths,status='checking',callbacks={callback},retry_index=1,
      deadline=uv.hrtime()/1e9+STARTUP_LIMIT,finished=false}
    states[paths.root]=state
  end

  function state:probe()
    if self.finished then return end
    local exists,why=private_socket_path(self.paths.socket)
    if exists==nil then finish(self,{kind='path',message=why});return end
    if not exists then
      if not self.spawned then spawn(self)
      else schedule(self)end
      return
    end
    local ok,client=pcall(Native.new,{socket=self.paths.socket,timeout_ms=1200})
    if not ok then finish(self,{kind='path',message=tostring(client)});return end
    self.probe_client=client
    client:request('GET','/layout/session',nil,function(error,value,status)
      if self.probe_client==client then self.probe_client=nil end
      client:close()
      if self.finished then return end
      if error then
        if error.kind=='transport'and not self.spawned then spawn(self)
        elseif error.kind=='http'and status==503 then schedule(self)
        elseif error.kind=='transport'then schedule(self)
        else finish(self,error)end
        return
      end
      local valid,problem=validate_status(self,value)
      if not valid then finish(self,problem);return end
      finish(self,nil,valid)
    end)
  end
  state:probe()
  return state
end

return M
