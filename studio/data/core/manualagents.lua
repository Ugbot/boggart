local core=require 'core'
local uv=require 'uv'
local registry=require('fleet').default
local M={}
function M.start()
  if M.server then return end
  local template=bog.userdir..'/bmux-XXXXXX'
  if #template>80 then template='/tmp/boggart-bmux-XXXXXX'end
  local directory,why_dir=uv.fs_mkdtemp(template);assert(directory,why_dir)
  M.service=require('manualfleet').new{registry=registry,clock=system.get_time,changed=function()core.redraw=true end}
  local server,why=serve.listen{socket=directory..'/control.sock',body_limit=32768,
    handler=function(req)return M.service:handle(req)end}
  if not server then uv.fs_rmdir(directory);error(why)end
  M.server,M.directory,M.socket=server,directory,directory..'/control.sock'
  if os.getenv('BOGGART_AGENT_HOOKS')~='0' then
    local why
    M.hooks,why=require('agenthooks').install{directory=directory,
      executable=require('core.agentlauncher').boggart_command(),path=os.getenv('PATH'),cwd=uv.cwd(),
      previous_bin=os.getenv('BOGGART_AGENT_BIN')}
    if not M.hooks then core.log('Automatic agent wrappers unavailable: %s',tostring(why))end
  end
  core.add_thread(function()
    while M.server==server do M.service:expire();coroutine.yield(.25)end
  end)
end
function M.attach(view,cwd,rec)
  M.start();local revision=-1;local alive=true
  local pane=M.service:pane{cwd=cwd,focus=function()return require('shell.workspaces.bmux').show(view)end,
    alive=function()
      if not view.terminal then return false end
      local current=view.terminal:process_revision()
      if current~=revision then revision=current;local state=view.terminal:process_state();alive=state and not state.exited end
      return alive
    end}
  view.manual_pane=pane.id
  local env={'BOGGART_SOCKET='..M.socket,'BOGGART_PANE_ID='..pane.id,'BOGGART_PANE_TOKEN='..pane.token}
  if rec and rec.provider=='claude' then
    local entry=M.service:observe(rec,pane);view.provider_events=entry.events
    env[#env+1]='BOGGART_AGENT_ID='..rec.id;env[#env+1]='BOGGART_AGENT_EVENT_TOKEN='..entry.event_token
    env[#env+1]='BOGGART_AGENT_PROVIDER='..rec.provider;rec.pane_id=pane.id
  end
  if M.hooks then env[#env+1]='PATH='..M.hooks.path;env[#env+1]='BOGGART_AGENT_BIN='..M.hooks.bin end
  return env
end
function M.revoke(view)
  if M.service and view.manual_pane then M.service:revoke(view.manual_pane);view.manual_pane=nil end
end
function M.shutdown()
  if not M.server then return end
  for id in pairs(M.service.panes)do M.service:revoke(id)end
  M.server:stop();M.server=nil
  if M.hooks then M.hooks:cleanup();M.hooks=nil end
  uv.fs_rmdir(M.directory)
end
local quit=core.quit
function core.quit(...)
  local result=quit(...);if core.quit_requested then M.shutdown()end;return result
end
return M
