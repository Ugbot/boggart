-- Session dialogs use the same transfer/file actions as terminal Bmux.
local core=require 'core';local common=require 'core.common';local M={}
local function current(s)return s and not s.closed and require('shell.workspaces.bmux').session==s end
local function actions()
  local s=require('shell.workspaces.bmux').session
  if not current(s)or not s.client.host_id then core.error('Join a Bmux server layout first');return end
  if not s.session_actions then
    local ok,value=pcall(require('bmux.sessionactions').new,{socket=s.socket,token=s.token,host_id=s.client.host_id},function(a)
      core.redraw=true
      if not a.busy and a.message and current(s)then
        if a.error then core.error('Bmux sessions: %s',a.message)else core.log('%s',a.message)end
      end
    end)
    if not ok then core.error('Bmux sessions: %s',tostring(value));return end
    s.session_actions=value
  end
  return s.session_actions,s
end
local function prompt(s,title,submit,suggest,default)
  core.command_view:enter(title,function(text)
    if not current(s)then core.error('Bmux session connection changed; open Sessions again');return end
    if s.session_actions.busy then
      core.log('Session request is working; press Enter again when it finishes')
      prompt(s,title,submit,suggest,text);return
    end
    submit(text)
  end,suggest,nil,default)
end
function M.show()
  local a,s=actions();if not a then return end
  if not a.info and not a.busy then a:refresh()end
  require('shell.modal').chooser('Bmux sessions',{
    {text='Export session to new file',run=function()
      prompt(s,'Export session to new file',function(path)a:export(path)end,common.path_suggest,(core.project_dir or require('uv').cwd())..'/bmux-session.json')
    end},
    {text='Import file as inactive session',run=function()
      prompt(s,'Import checkpoint file',function(path)
        prompt(s,'New saved session name (inactive)',function(name)a:import(path,name)end,nil,'imported-'..os.date('%Y%m%d-%H%M%S'))
      end,common.path_suggest)
    end},
    {text='Inspect saved session',run=function()
      prompt(s,'Saved session name',function(name)a:inspect(name)end,nil,a.import_name or a.saved_name)
    end},
    {text='Refresh session status',run=function()a:refresh()end},
  },function(item)if current(s)then item.run()end end)
end
return M
