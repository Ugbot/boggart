-- A joined Studio presentation, with all structural edits admitted by the host.
local core=require 'core';local View=require 'core.view';local style=require 'core.style'
local Snapshot=require 'bmux.snapshot';local Client=require 'bmux.client'
local Session={};Session.__index=Session;local M={}
local Notice=View:extend()
function Notice:new(title,detail)Notice.super.new(self);self.title=title;self.detail=detail end
function Notice:get_name()return self.title end
function Notice:draw()
  self:draw_background(style.background)
  local x,y=self.position.x+style.padding.x,self.position.y+style.padding.y
  renderer.draw_text(style.font,self.title,x,y,style.text)
  renderer.draw_text(style.font,self.detail,x,y+style.font:get_height()+style.padding.y,style.dim)
end
local function selected(snapshot)
  for _,w in ipairs(snapshot.workspaces)do if w.id==snapshot.selected_workspace_id then
    for _,s in ipairs(w.surfaces)do if s.id==w.selected_surface_id then return w,s end end
  end end
end
local function close(view)if view.try_close then view:try_close(function()end)end end
local function modal()
  local shell=package.loaded.shell
  return core.active_view==core.command_view or shell and shell.menubar and shell.menubar.open
end
function Session:content()
  local shell=require 'shell'
  if shell.current=='bmux' then local root=core.root_view.root_node;return root:get_primary_node():get_content_root(root) end
  local st=shell._stash.bmux;return st and st.tree
end
function Session:_stage(snapshot)
  local w,s=selected(snapshot);local created={};local pool={}
  local function make(desc)
    local value=self.pool[desc.id]
    local agent,signature
    if desc.kind=='agent'then
      agent,signature=self.agents:resolve(desc.agent_id)
      if value and value.bmux_agent_signature~=signature then value=nil end
    end
    if not value then
      if desc.kind=='terminal'or agent then
        value=require('core.terminalview'){title=desc.title or agent and agent.name or 'Terminal '..desc.terminal_id,
          attachment={socket=self.socket,token=self.token,id=agent and agent.terminal_id or desc.terminal_id,
            generation=agent and agent.terminal_generation or desc.generation,tail=32}}
      else value=Notice(desc.title or 'Agent '..tostring(desc.agent_id),'Agent view unavailable in this connection') end
      value.bmux_view_id=desc.id;value.bmux_layout=self;created[#created+1]=value
      if desc.kind=='agent'then value.bmux_agent_id=desc.agent_id;value.bmux_agent_signature=signature end
    end
    pool[desc.id]=value;return value
  end
  local ok,root,active,nodes=pcall(function()
    if s then return Snapshot.project(snapshot.host_id,s,self.Class,make) end
    local node=self.Class._blank('leaf');local value=Notice('No server workspaces','Use Workspaces to create one')
    node.views={value};node.active_view=value;return node,value,{}
  end)
  if not ok then for _,v in ipairs(created)do close(v)end;error(root,0)end
  for _,node in pairs(nodes)do node.bmux_owner=self end;root.bmux_owner=self
  return {root=root,active=active,nodes=nodes,pool=pool,workspace=w,surface=s}
end
function Session:apply(prepared)
  if not self.active or self.closed or modal()then return end
  local snapshot=self.client:view()
  if not snapshot or self.applied_revision==snapshot.revision or self.failed_revision==snapshot.revision then return end
  local ok,stage=true,prepared
  if not stage then ok,stage=pcall(self._stage,self,snapshot)end
  if not ok then self.failed_revision=snapshot.revision;self.error=tostring(stage);core.error('Layout: %s',self.error);return end
  local content=self:content();if not content then for _,v in pairs(stage.pool)do if not self.pool[v.bmux_view_id]then close(v)end end;return end
  local pos,size=content.position,content.size
  content:consume(stage.root);setmetatable(content,self.Class);content.position,content.size=pos,size
  local replaced={}
  for id,v in pairs(stage.pool)do
    if self.pool[id]and self.pool[id]~=v then replaced[#replaced+1]=self.pool[id]end
    self.pool[id]=v
  end
  local refs=self.client.refs or {};local removed={}
  for id,v in pairs(self.pool)do if not refs[id]then removed[#removed+1]=v;self.pool[id]=nil end end
  self.workspace_id=stage.workspace and stage.workspace.id;self.surface_id=stage.surface and stage.surface.id
  self.nodes=stage.nodes;self.applied_workspace=stage.workspace;self.applied_surface=stage.surface;self.applied_revision=snapshot.revision
  local shell=require 'shell';local ws=require 'shell.workspaces.bmux'
  if shell.current=='bmux' then
    core.set_active_view(stage.active or content:get_primary_node().active_view)
    ws.focused=core.active_view;core.root_view.root_node:update_layout()
  else
    local st=shell._stash.bmux
    st.active=stage.active;st.views=content:get_children()
  end
  for _,v in ipairs(removed)do close(v)end
  for _,v in ipairs(replaced)do close(v)end
  self.error=nil;core.redraw=true
end
function Session:_changed()
  if self.closed then return end
  if self.client and (self.client.status=='disconnected' or self.client.uncertain)then
    self.queue={};self.resize_pending=nil;self.pending_focus_id=nil
  end
  self:apply();core.redraw=true
end
function Session:_pump()
  if self.closed or self.sending or self.launching or self.client.status~='live' then return end
  local item=table.remove(self.queue,1);if not item then self.pending_focus_id=nil;return end
  self.sending=true
  self.client:command(item.op,item.args,function(why,snapshot)
    self.sending=false;if self.closed then return end
    if why then self.queue={};self.resize_pending=nil;self.pending_focus_id=nil;core.error('Layout: %s',why.message)end
    if item.callback then item.callback(why,snapshot)end
    if not why then self:_pump();self:_pump_resize()end
  end)
end
function Session:command(op,args,callback)
  if self.closed or self.launching or self.client.status~='live' or #self.queue>=16 then return false end
  local body={};for k,v in pairs(args or {})do body[k]=v end
  if not op:match('^workspace_') and not op:match('^surface_')then
    body.workspace_id=body.workspace_id or self.workspace_id;body.surface_id=body.surface_id or self.surface_id
    if not body.workspace_id or not body.surface_id then return false end
  end
  self.queue[#self.queue+1]={op=op,args=body,callback=callback};self:_pump();return true
end
function Session:focused_pane()
  local content=self:content();local node=content and content:get_node_for_view(core.active_view)
  return node and node.remote_id or self.applied_surface and self.applied_surface.focused_pane_id
end
function Session:focus(node,view)
  if not node.remote_id then core.set_active_view(view);return true end
  if not self.pending_focus_id and self.applied_surface and self.applied_surface.focused_pane_id==node.remote_id and node.active_view==view then
    core.set_active_view(view);return true
  end
  self.pending_focus_id=node.remote_id
  local accepted=self:command('pane_focus',{pane_id=node.remote_id,view_id=view.bmux_view_id})
  if not accepted then self.pending_focus_id=nil end
  return accepted
end
function Session:cycle(delta)
  local content=self:content();content=content.zoomed or content
  local leaves=content:get_leaves();local focused=self.pending_focus_id or self:focused_pane()
  for i,node in ipairs(leaves)do if node.remote_id==focused then
    local target=leaves[(i-1+delta)%#leaves+1];return self:focus(target,target.active_view)
  end end
end
function Session:_pump_resize()
  if self.sending or self.launching or not self.resize_pending then return end
  local value=self.resize_pending;self.resize_pending=nil
  self:command('split_resize',{split_id=value.id,ratio=value.ratio},function(why)
    if why then self.resize_target=nil;core.root_view.dragged_divider=nil end
  end)
end
function Session:resize(node,ratio)
  if not node.remote_id then return false end
  self.resize_target={id=node.remote_id,node=node,ratio=math.max(.01,math.min(.99,ratio))}
  self.resize_pending=self.resize_target;self:_pump_resize();return true
end
function Session:local_view(view,dir)
  require('shell').switch('edit')
  local node=core.root_view:get_primary_node()
  if dir then return node:split(dir,view)end
  node:add_view(view);return view
end
function Session:open_terminal(dir,opts)
  opts=opts or {}
  if self.sending or self.launching or self.client.status~='live' then return end
  local snapshot=self.client:view();local w,s=selected(snapshot)
  if not w then
    self:command('workspace_create',{title='Bmux'},function(why)if not why then self:open_terminal(dir,opts)end end);return
  end
  local pane=self:focused_pane() or s.focused_pane_id
  local op=dir and 'pane_split' or 'view_add'
  local function place(record)
    self.launching=false
    local function unplaced()core.error('Terminal remains on server; reconnect and use Attach to find %s',record.id)end
    local queued=self:command(op,{workspace_id=w.id,surface_id=s.id,pane_id=pane,direction=dir,
      view={kind='terminal',terminal_id=record.id,generation=record.generation,title=opts.title}},function(why)
      if why then unplaced()end
    end)
    if not queued then unplaced()end
  end
  if opts.attachment then
    if opts.attachment.socket~=self.socket then core.error('Join that server layout before adding its terminal');return end
    place(opts.attachment);return
  end
  self.launching=true
  self.client.transport:request('POST','/terminals',{cmd=opts.cmd,args=opts.args,cwd=opts.cwd or core.project_dir,cols=80,rows=24,history=2000},function(why,record)
    if self.closed then return end
    if why then self.launching=false;core.error('Create server terminal: %s',why.message)else place(record)end
    core.redraw=true
  end)
end
function Session:disconnect()
  if self.closed then return end
  local content=self.active and self:content();self.closed=true;self.client:close()
  if self.agents then self.agents:close()end
  self.queue={};self.resize_pending=nil;self.pending_focus_id=nil
  if core.root_view.dragged_divider and core.root_view.dragged_divider.bmux_owner==self then core.root_view.dragged_divider=nil end
  if content and self.local_tree then
    local pos,size=content.position,content.size
    content:consume(self.local_tree);setmetatable(content,self.Base);content.position,content.size=pos,size
    local shell=require 'shell'
    if shell.current=='bmux' then
      core.set_active_view(self.local_active or content:get_primary_node().active_view)
      core.root_view.root_node:update_layout()
    else local st=shell._stash.bmux;st.active=self.local_active;st.views=content:get_children()end
  end
  for _,v in pairs(self.pool)do close(v)end;self.pool={}
  local ws=require 'shell.workspaces.bmux';if ws.session==self then ws.session=nil;ws.focused=self.local_active end
  if M.pending==self then M.pending=nil end
  core.redraw=true
end
function Session:refresh()
  if self.agents then self.agents:refresh()end
  self.failed_revision=nil;self.applied_revision=nil
  local function done(why)if why then core.error('Layout: %s',why.message)else self:apply()end end
  if self.client.watch then self.client:refresh(done)else self.client:start(done)end
end
function Session:_activate()
  local ok,stage=pcall(self._stage,self,self.client:view())
  if not ok then
    self:disconnect()
    if self.callback then self.callback({kind='presentation',message=tostring(stage)})else core.error('Join layout: %s',tostring(stage))end
    return
  end
  local ws=require 'shell.workspaces.bmux';if ws.session then ws.session:disconnect()end
  ws.suppress_initial=true;require('shell').switch('bmux');ws.suppress_initial=nil
  local content=self:content();self.local_tree=self.Base._blank('leaf');self.local_tree:consume(content);self.local_active=core.active_view
  if not self.local_tree:get_node_for_view(self.local_active)then
    self.local_active=self.local_tree:get_node_for_view(ws.last_content_view) and ws.last_content_view or self.local_tree:get_primary_node().active_view
  end
  ws.session=self;self.active=true;M.pending=nil;self:apply(stage)
  if self.callback then self.callback(nil,self)end
end
function M.update()
  if M.pending and M.pending.client.status=='live' and not modal()then M.pending:_activate()end
end
-- Resume deferred presentation on the next UI frame, even before a Bmux toolbar
-- has been created. This adds no timer or background layout poll.
local root_update=core.root_view.update
function core.root_view:update(...)
  M.update()
  local ws=package.loaded['shell.workspaces.bmux'];if ws and ws.session then ws.session:apply()end
  return root_update(self,...)
end
function M.join(socket,token,callback)
  if M.pending then M.pending:disconnect()end
  local Base=getmetatable(core.root_view.root_node);Base=Base.local_class or Base
  local self=setmetatable({socket=socket,token=token,Base=Base,pool={},queue={},callback=callback},Session)
  self.Class=require('core.bmuxlayoutnodes').new(Base)
  self.client=Client.new{socket=socket,token=token,on_change=function()self:_changed()end}
  self.agents=require('core.bmuxagents').new(self)
  M.pending=self
  self.client:start(function(why)
    if why then self:disconnect();if callback then callback(why)else core.error('Join layout: %s',why.message)end;return end
    self.agents:start(self.client.host_id)
    M.update()
  end)
  return self
end
-- Hidden mode trees and the preserved local layout still own their documents.
-- Keep them in core.docs so joining/zooming cannot bypass unsaved-change checks.
local doc_views=core.get_views_referencing_doc
function core.get_views_referencing_doc(doc)
  local result=doc_views(doc);local seen={}
  for _,view in ipairs(result)do seen[view]=true end
  local function add(view)
    if view.doc==doc and not seen[view]then seen[view]=true;result[#result+1]=view end
  end
  local function visit(node)
    if node.zoomed then visit(node.zoomed)
    elseif node.type=='leaf'then for _,view in ipairs(node.views)do add(view)end
    else visit(node.a);visit(node.b)end
  end
  visit(core.root_view.root_node)
  local shell=package.loaded.shell
  for _,st in pairs(shell and shell._stash or {})do
    if st.tree then visit(st.tree)else for _,view in ipairs(st.views or {})do add(view)end end
  end
  local ws=package.loaded['shell.workspaces.bmux']
  if ws and ws.session and ws.session.local_tree then visit(ws.session.local_tree)end
  return result
end
local quit=core.quit
function core.quit(...)
  local result=quit(...)
  if core.quit_requested then
    if M.pending then M.pending:disconnect()end
    local ws=package.loaded['shell.workspaces.bmux'];if ws and ws.session then ws.session:disconnect()end
  end
  return result
end
return M
