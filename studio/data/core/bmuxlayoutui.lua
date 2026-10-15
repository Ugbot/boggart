-- Visible layout choices; session state and protocol live in their owners.
local core=require 'core';local config=require 'core.config';local M={}
local function session()local ws=package.loaded['shell.workspaces.bmux'];return ws and ws.session end
local function choose(label,choices,callback)require('shell.modal').chooser(label,choices,callback)end
function M.join()
  local opts=config.bmux_server or {};local socket=opts.socket or bog.userdir..'/control.sock'
  core.command_view:enter('Join Bmux server layout',function(path)
    local ok,why=pcall(require('core.bmuxlayout').join,path,path==opts.socket and opts.token or nil)
    if not ok then core.error('Join layout: %s',tostring(why))end
  end,nil,nil,socket)
end
function M.workspaces()
  local s=session();if not s then return end
  local choices={{text='+ New workspace',create=true}}
  for i,w in ipairs(s.client:view().workspaces)do choices[#choices+1]={text=i..' · '..w.title,id=w.id}end
  choose('Server workspaces',choices,function(pick)
    if pick.create then core.command_view:enter('Workspace name',function(title)s:command('workspace_create',{title=title})end)
    else s:command('workspace_select',{workspace_id=pick.id})end
  end)
end
function M.surfaces()
  local s=session();if not s or not s.workspace_id then return end
  local workspace
  for _,w in ipairs(s.client:view().workspaces)do if w.id==s.workspace_id then workspace=w;break end end
  if not workspace then return end
  local choices={{text='+ New surface',create=true}}
  for i,surface in ipairs(workspace.surfaces)do choices[#choices+1]={text=i..' · '..surface.title,id=surface.id}end
  choose('Server surfaces',choices,function(pick)
    if pick.create then core.command_view:enter('Surface name',function(title)s:command('surface_create',{workspace_id=workspace.id,title=title})end)
    else s:command('surface_select',{workspace_id=workspace.id,surface_id=pick.id})end
  end)
end
function M.refresh()local s=session();if s then s:refresh()end end
function M.disconnect()
  local layouts=package.loaded['core.bmuxlayout'];if layouts and layouts.pending then layouts.pending:disconnect()end
  local s=session();if s then s:disconnect()end
end
return M
