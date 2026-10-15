local core=require 'core'
local uv=require 'uv'
local registry=require('fleet').default
local M={}
function M.start()
  if M.server then return end
  local template=bog.userdir..'/bmux-XXXXXX'
  if #template>80 then template='/tmp/boggart-bmux-XXXXXX'end
  local directory,why_dir=uv.fs_mkdtemp(template);assert(directory,why_dir)
  M.service=require('manualfleet').new{registry=registry,clock=system.get_time}
  local server,why=serve.listen{socket=directory..'/control.sock',body_limit=32768,
    handler=function(req)return M.service:handle(req)end}
  if not server then uv.fs_rmdir(directory);error(why)end
  M.server,M.directory,M.socket=server,directory,directory..'/control.sock'
  core.add_thread(function()
    while M.server do M.service:expire();coroutine.yield(.25)end
  end)
end
function M.attach(view,cwd)
  M.start();local revision=-1;local alive=true
  local pane=M.service:pane{cwd=cwd,focus=function()return require('shell.workspaces.bmux').show(view)end,
    alive=function()
      if not view.terminal then return false end
      local current=view.terminal:process_revision()
      if current~=revision then revision=current;local state=view.terminal:process_state();alive=state and not state.exited end
      return alive
    end}
  view.manual_pane=pane.id
  return {'BOGGART_SOCKET='..M.socket,'BOGGART_PANE_ID='..pane.id,'BOGGART_PANE_TOKEN='..pane.token}
end
function M.revoke(view)
  if M.service and view.manual_pane then M.service:revoke(view.manual_pane);view.manual_pane=nil end
end
function M.shutdown()
  if not M.server then return end
  for id in pairs(M.service.panes)do M.service:revoke(id)end
  M.server:stop();M.server=nil;uv.fs_rmdir(M.directory)
end
local quit=core.quit
function core.quit(...)
  local result=quit(...);if core.quit_requested then M.shutdown()end;return result
end
return M
