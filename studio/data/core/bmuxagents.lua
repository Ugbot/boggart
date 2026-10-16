-- Joined Studio Fleet/pane presentation. The server retains every runtime.
local core=require 'core';local Fleet=require 'bmux.fleetclient';local Source=require 'bmux.fleetsource'
local M={};local Agents={};Agents.__index=Agents
local function selected(snapshot)
  for _,w in ipairs(snapshot.workspaces)do if w.id==snapshot.selected_workspace_id then
    for _,s in ipairs(w.surfaces)do if s.id==w.selected_surface_id then return w,s end end
  end end
end
function M.new(session)return setmetatable({session=session},Agents)end
function Agents:resolve(id)
  local r=self.client and self.client:find(id)
  if r and r.terminal_id then return r,r.terminal_id..':'..r.terminal_generation..':'..r.generation end
  return nil,'unavailable'
end
function Agents:_changed()
  if self.closed then return end
  if self.source then self.source:update()end
  local s=self.session;local content=s.active and s:content()
  if content then for _,view in pairs(s.pool)do
    if view.bmux_agent_id and content:get_node_for_view(view)then
      local _,signature=self:resolve(view.bmux_agent_id)
      if signature~=view.bmux_agent_signature then s.applied_revision=nil;s.failed_revision=nil;break end
    end
  end end
  core.redraw=true
end
function Agents:start(host_id)
  if self.client then return end
  local s=self.session
  self.client=Fleet.new{socket=s.socket,token=s.token,host_id=host_id,on_change=function()self:_changed()end}
  self.source=Source.new(require('core.fleetagents').registry,self.client,function(id,generation)return self:focus(id,generation)end,function()core.redraw=true end)
  self.client:start()
end
function Agents:focus(id,generation)
  local s=self.session;local r=self.client:find(id)
  if self.closed or not s.active or s.closed or not r or r.generation~=generation or not r.terminal_id or s.client.status~='live'then
    return nil,'agent presentation is unavailable'
  end
  require('shell').switch('bmux')
  local snapshot=s.client:view();local w,current=selected(snapshot)
  if not w then
    return s:command('workspace_create',{title=s.project_title or 'Bmux'},
      function(why)if not why then self:focus(id,generation)end end)
  end
  local workspace,surface,pane,view=require('bmux.agentviews').find(snapshot,r,self.client)
    if pane then
      local operations={}
      if snapshot.selected_workspace_id~=workspace.id then operations[#operations+1]={'workspace_select',{workspace_id=workspace.id}}end
      if workspace.selected_surface_id~=surface.id then operations[#operations+1]={'surface_select',{workspace_id=workspace.id,surface_id=surface.id}}end
      operations[#operations+1]={'pane_focus',{workspace_id=workspace.id,surface_id=surface.id,pane_id=pane,view_id=view}}
      local function next_operation(index)
        local op=operations[index];if not op then return end
        local accepted=s:command(op[1],op[2],function(why)if not why then next_operation(index+1)end end)
        if not accepted then core.error('Agent Focus unavailable; refresh the layout')end
        return accepted
      end
      return next_operation(1)
    end
  return s:command('view_add',{workspace_id=w.id,surface_id=current.id,pane_id=current.focused_pane_id,
    view={kind='agent',agent_id=id,title=r.name}})
end
function Agents:_placed(record,target)
  local s=self.session;self.pending_launch=nil
  if s.closed then return end
  local function retained()core.error('Agent remains on server; use Fleet Focus to find %s (terminal %s)',record.agent_id,record.terminal_id)end
  local accepted=s:command('view_add',{workspace_id=target.workspace_id,surface_id=target.surface_id,pane_id=target.pane_id,
    view={kind='agent',agent_id=record.agent_id}},function(why)if why then retained()end end)
  if not accepted then retained()end
end
function Agents:launch(profile)
  local s=self.session
  if self.closed or not self.client or not self.client:can_command()or s.sending or s.launching or s.client.status~='live'then
    core.error('Server agent launch unavailable; refresh or retry its pending command');return
  end
  local w,surface=selected(s.client:view())
  if not w then
    s:command('workspace_create',{title=s.project_title or 'Bmux'},
      function(why)if not why then self:launch(profile)end end);return
  end
  local target={workspace_id=w.id,surface_id=surface.id,pane_id=s:focused_pane()or surface.focused_pane_id}
  local opts={provider=profile.provider,name=profile.name,cmd=profile.cmd,args=profile.args,
    cwd=profile.cwd or core.project_dir,resume_id=profile.resume_id,cols=80,rows=24,history=2000}
  self.pending_launch=target;s.launching=true
  self.client:launch(opts,function(why,record)
    s.launching=false;if self.closed or s.closed then return end
    if why then
      if not self.client.pending then self.pending_launch=nil end
      core.error('Server agent: %s',why.message)
    else self:_placed(record,target)end
    core.redraw=true
  end)
end
function Agents:retry()
  if not self.client or not self.client.pending then core.error('No pending server agent command');return end
  local target=self.pending_launch
  self.client:retry(function(why,record)
    if self.closed then return end
    if why then core.error('Server agent retry: %s',why.message)
    elseif target then self:_placed(record,target)end
    core.redraw=true
  end)
end
function Agents:choose()
  local choices={{text='Boggart TUI',provider='boggart',name='Boggart TUI'},
    {text='Resume Boggart TUI',resume=true},{text='Codex',provider='codex',cmd='codex',name='Codex'},
    {text='Claude Code',provider='claude',cmd='claude',name='Claude Code'},{text='Custom agent command',custom=true}}
  if self.client and self.client.pending then table.insert(choices,1,{text='Retry pending agent command',retry=true})end
  require('shell.modal').chooser('New server agent',choices,function(pick)
    if self.closed then return end
    if pick.retry then self:retry()
    elseif pick.resume then
      core.command_view:enter('Server session ID',function(id)self:launch{provider='boggart',name='Boggart TUI',resume_id=id}end)
    elseif pick.custom then
      core.command_view:enter('Server agent command (quoted arguments)',function(text)
        local ok,argv=pcall(require('agentargv').parse,text)
        if not ok then core.error('%s',argv);return end
        local args={};for i=2,#argv do args[#args+1]=argv[i]end
        self:launch{provider='custom',cmd=argv[1],args=args,name=argv[1]:match('([^/\\]+)$')or 'Custom agent'}
      end)
    else self:launch(pick)end
  end)
end
function Agents:refresh()
  if not self.client then return end
  if self.client.watch then self.client:refresh()else self.client:start()end
end
function Agents:close()
  if self.closed then return end;self.closed=true
  if self.source then self.source:close()end
  if self.client then self.client:close()end
end
return M
