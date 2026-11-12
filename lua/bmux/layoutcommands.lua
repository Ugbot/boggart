-- Validate the complete command before constructing an authoritative mutation.
local M = {}
local function failure(status, message) return nil, {status=status, message=message} end
local function integer(n, low)
  return type(n)=='number' and n%1==0 and n>=low and n<=9007199254740991
end
local function label(s)
  return type(s)=='string' and #s>0 and #s<=256 and not s:find('[%z\1-\31\127]') and utf8.len(s)~=nil
end
local validators = {
  id=function(s) return type(s)=='string' and #s<=128 and s:match('^[%w_-]+$') end,
  integer=function(n) return integer(n, 1) end,
  title=label,
  direction=function(s) return s=='left' or s=='right' or s=='up' or s=='down' end,
  ratio=function(n) return type(n)=='number' and n>=0.01 and n<=0.99 end,
  view=function(v) return type(v)=='table' end,
}
local schemas = {
  workspace_create={title='title'}, workspace_select={workspace_id='id'},
  workspace_rename={workspace_id='id',title='title'}, workspace_remove={workspace_id='id'},
  surface_create={workspace_id='id',title='title'},
  surface_select={workspace_id='id',surface_id='id'},
  surface_rename={workspace_id='id',surface_id='id',title='title'},
  surface_remove={workspace_id='id',surface_id='id'},
  view_add={pane_id='integer',view='view'}, view_close={pane_id='integer',view_id='id?'},
  view_move={pane_id='integer',view_id='id',target_pane_id='integer',index='integer?'},
  pane_split={pane_id='integer',direction='direction',view='view?'},
  pane_focus={pane_id='integer',view_id='id?'},
  pane_swap={pane_id='integer',target_pane_id='integer'},
  pane_zoom={pane_id='integer'}, split_resize={split_id='integer',ratio='ratio'},
  balance={},
}
for name, schema in pairs(schemas) do
  if not name:match('^workspace_') and not name:match('^surface_') then
    schema.workspace_id, schema.surface_id = 'id', 'id'
  end
end
local common = {op=true, host_id=true, revision=true}
local function validate(command)
  if type(command)~='table' or type(command.op)~='string' or not schemas[command.op]
    or not validators.id(command.host_id) or not integer(command.revision,0) then
    return failure(400, 'invalid layout command')
  end
  local schema = schemas[command.op]
  for key in pairs(command) do
    if not common[key] and not schema[key] then return failure(400, 'unknown layout field') end
  end
  for key, kind in pairs(schema) do
    local optional = kind:sub(-1)=='?'
    if optional then kind=kind:sub(1,-2) end
    if not (optional and command[key]==nil) and not validators[kind](command[key]) then
      return failure(400, 'invalid layout field: '..key)
    end
  end
  return true
end

local function descriptor(host, view)
  local keys = {kind=true,terminal_id=true,generation=true,agent_id=true,title=true}
  for key in pairs(view) do if not keys[key] then return failure(400,'unknown view field') end end
  if view.title~=nil and not label(view.title) then return failure(400,'invalid view title') end
  local terminal = view.kind=='terminal' and validators.id(view.terminal_id)
    and integer(view.generation,1) and view.agent_id==nil
  local agent = view.kind=='agent' and (label(view.agent_id) or integer(view.agent_id,1))
    and view.terminal_id==nil and view.generation==nil
  if not terminal and not agent then return failure(400,'invalid layout view reference') end
  local out = {kind=view.kind,terminal_id=view.terminal_id,generation=view.generation,
    agent_id=view.agent_id,title=view.title}
  local resolved, why = host.resolve(out)
  if not resolved then return nil, why or {status=404,message='unknown layout view reference'} end
  return out
end
local function room(host, kind, extra)
  return host:_stats()[kind]+(extra or 1)<=host.limits[kind]
end
local function remove(items, id)
  for i, item in ipairs(items) do if item.id==id then table.remove(items,i);return end end
end
local function hierarchy(host, c)
  if c.op=='workspace_create' then
    if not room(host,'workspaces') or not room(host,'surfaces') or not room(host,'panes') then
      return failure(413,'layout capacity reached')
    end
    return function()
      local surface = host:_new_surface('Main')
      local workspace = {id=host:_id('workspace'),title=c.title,surfaces={surface},selected_surface=surface.id}
      host.workspaces[#host.workspaces+1]=workspace;host.selected_workspace=workspace.id
    end
  end
  local workspace = host:_workspace(c.workspace_id)
  if not workspace then return failure(404,'unknown layout workspace') end
  if c.op=='workspace_select' then return function() host.selected_workspace=workspace.id end end
  if c.op=='workspace_rename' then return function() workspace.title=c.title end end
  if c.op=='workspace_remove' then
    return function()
      remove(host.workspaces,workspace.id)
      if host.selected_workspace==workspace.id then
        host.selected_workspace=host.workspaces[1] and host.workspaces[1].id
      end
    end
  end
  if c.op=='surface_create' then
    if not room(host,'surfaces') or not room(host,'panes') then return failure(413,'layout capacity reached') end
    return function()
      local surface=host:_new_surface(c.title)
      workspace.surfaces[#workspace.surfaces+1]=surface;workspace.selected_surface=surface.id
    end
  end
  local surface = host:_surface(workspace,c.surface_id)
  if not surface then return failure(404,'unknown layout surface') end
  if c.op=='surface_select' then return function() workspace.selected_surface=surface.id end end
  if c.op=='surface_rename' then return function() surface.title=c.title end end
  if c.op=='surface_remove' then
    if #workspace.surfaces==1 then return failure(409,'workspace must retain one surface') end
    return function()
      remove(workspace.surfaces,surface.id)
      if workspace.selected_surface==surface.id then workspace.selected_surface=workspace.surfaces[1].id end
    end
  end
end

local function locate(node, id, depth)
  if node.id==id then return node,depth end
  if node.type~='leaf' then
    local found, level = locate(node.a,id,depth+1)
    if found then return found,level end
    return locate(node.b,id,depth+1)
  end
end
local function tab_count(node)
  local n=0;for _,view in ipairs(node.views) do if not view.empty then n=n+1 end end;return n
end
local function pane_effect(host, c, surface, node, depth)
  if c.op=='split_resize' then
    if node.type=='leaf' then return failure(400,'resize requires a split') end
    return function(tree) tree:find_node(c.split_id):set_divider(c.ratio) end
  end
  if c.op=='balance' then return function(tree) tree:balance() end end
  if node.type~='leaf' then return failure(400,'operation requires a pane') end
  local reference
  if c.view then
    local why;reference,why=descriptor(host,c.view);if not reference then return nil,why end
    if not room(host,'views') then return failure(413,'layout view capacity reached') end
  end
  local function fresh_view()
    if reference then reference.id=host:_id('view') end
    return reference
  end
  if c.op=='view_add' then
    if tab_count(node)>=host.limits.tabs then return failure(413,'pane tab capacity reached') end
    return function(tree) tree:find_node(c.pane_id):add_view(fresh_view()) end
  end
  if c.op=='pane_split' then
    if not room(host,'panes') or depth>=host.limits.depth then return failure(413,'layout split capacity reached') end
    return function(tree) tree:find_node(c.pane_id):split(c.direction,fresh_view()) end
  end
  local view = node.active_view
  if c.view_id then
    view=nil
    for _,item in ipairs(node.views) do if item.id==c.view_id then view=item;break end end
    if not view then return failure(404,'view is not in the requested pane') end
  end
  if c.op=='pane_focus' or c.op=='pane_zoom' then
    return function(tree) tree:find_node(c.pane_id):set_active_view(view) end
  end
  if c.op=='view_close' then return function(tree) tree:find_node(c.pane_id):close_view(view,tree) end end
  local target = host:_canonical(surface):find_node(c.target_pane_id)
  if not target or target.type~='leaf' then return failure(404,'unknown destination pane') end
  if c.op=='pane_swap' then
    return function(tree) tree:find_node(c.pane_id):swap_views(tree:find_node(c.target_pane_id)) end
  end
  if target~=node and tab_count(target)>=host.limits.tabs then return failure(413,'pane tab capacity reached') end
  if c.index and c.index>tab_count(target)+1 then return failure(400,'invalid tab index') end
  return function(tree)
    tree:find_node(c.pane_id):move_view(view,tree:find_node(c.target_pane_id),tree,c.index)
  end
end

M.reference=descriptor -- shared with trusted checkpoint reconstruction

function M.prepare(host, c)
  local valid, why=validate(c);if not valid then return nil,why end
  if c.host_id~=host.host_id or c.revision~=host.revision then return failure(409,'stale layout; fetch a current snapshot') end
  if c.op:match('^workspace_') or c.op:match('^surface_') then return hierarchy(host,c) end
  local workspace=host:_workspace(c.workspace_id)
  local surface=workspace and host:_surface(workspace,c.surface_id)
  if not surface then return failure(404,'unknown layout surface') end
  local node,depth=locate(host:_canonical(surface),c.pane_id or c.split_id or host:_canonical(surface).id,1)
  if not node then return failure(404,'unknown layout pane or split') end
  local effect;effect,why=pane_effect(host,c,surface,node,depth)
  if not effect then return nil,why end
  return function()
    host:_activate(surface)
    local was_zoomed=surface.tree.zoomed and surface.tree.id==c.pane_id
    surface.tree:unzoom()
    effect(surface.tree)
    if c.op=='pane_zoom' and not was_zoomed then surface.tree:toggle_zoom() end
    host:_finish(surface)
  end
end
return M
