-- Validate an entire wire hierarchy before any renderer or attachment changes.
local json=require 'json'
local M={};local MAX=9007199254740991
local function need(ok,message)if not ok then error(message,0)end end
local function integer(n,low,high)return type(n)=='number' and n%1==0 and n>=low and n<=(high or MAX)end
local function object(t)need(type(t)=='table' and getmetatable(t)==nil,'expected plain object');return t end
local function array(t,limit)
  if t==json.array then return {} end
  object(t);local n=#t;need(n<=limit,'collection limit exceeded')
  local count=0;for k in pairs(t)do need(integer(k,1,n),'invalid array index');count=count+1 end
  need(count==n,'sparse array');return t
end
local function identifier(s)
  need(type(s)=='string' and #s<=128 and s:match('^[%w_-]+$'),'invalid identity');return s
end
local function title(s)
  need(type(s)=='string' and #s>0 and #s<=256 and not s:find('[%z\1-\31\127]') and utf8.len(s)~=nil,'invalid UTF-8 label');return s
end
local function unique(set,id)need(not set[id],'duplicate identity');set[id]=true end
local function view(input,state)
  object(input);local id=identifier(input.id);unique(state.views,id)
  state.view_count=state.view_count+1;need(state.view_count<=512,'view limit exceeded')
  local out={id=id,kind=input.kind}
  if input.kind=='terminal' then
    out.terminal_id=identifier(input.terminal_id)
    need(integer(input.generation,1) and input.agent_id==nil,'invalid terminal reference')
    out.generation=input.generation
  elseif input.kind=='agent' then
    need(input.terminal_id==nil and input.generation==nil,'invalid agent reference')
    if type(input.agent_id)=='string' then out.agent_id=title(input.agent_id)
    else need(integer(input.agent_id,1),'invalid agent identity');out.agent_id=input.agent_id end
  else error('unsupported view kind',0) end
  if input.title~=nil then out.title=title(input.title) end
  return out
end
local function node(input,state,leaves,depth)
  object(input);need(depth<=24,'tree depth exceeded')
  need(integer(input.id,1),'invalid node identity');unique(state.nodes,input.id)
  local out={id=input.id,type=input.type}
  if input.type=='leaf' then
    state.panes=state.panes+1;need(state.panes<=256,'pane limit exceeded')
    leaves[input.id]=out;out.views={};local selected=false
    for i,item in ipairs(array(input.views,32))do
      local copy=view(item,state);out.views[i]=copy
      if copy.id==input.active_view_id then selected=true end
    end
    need(#out.views==0 and input.active_view_id==json.null or #out.views>0 and selected,'invalid selected tab')
    out.active_view_id=input.active_view_id
  else
    need(input.type=='hsplit' or input.type=='vsplit','invalid node kind')
    need(type(input.divider)=='number' and input.divider>=.01 and input.divider<=.99,'invalid split ratio')
    out.divider=input.divider
    out.a=node(input.a,state,leaves,depth+1);out.b=node(input.b,state,leaves,depth+1)
  end
  return out
end
local function validate(input)
  object(input);need(input.v==1,'unsupported layout version')
  need(integer(input.revision,0),'invalid revision')
  local out={v=1,host_id=identifier(input.host_id),revision=input.revision,workspaces={}}
  local state={nodes={},views={},view_count=0,panes=0,surface_count=0}
  local workspaces,surfaces={},{}
  for i,workspace in ipairs(array(input.workspaces,16))do
    object(workspace);local id=identifier(workspace.id);unique(workspaces,id)
    local w={id=id,title=title(workspace.title),surfaces={},selected_surface_id=identifier(workspace.selected_surface_id)}
    local selected=false
    for j,surface in ipairs(array(workspace.surfaces,64))do
      object(surface);state.surface_count=state.surface_count+1;need(state.surface_count<=64,'surface limit exceeded')
      local sid=identifier(surface.id);unique(surfaces,sid)
      local s={id=sid,title=title(surface.title)};local leaves={}
      s.tree=node(surface.tree,state,leaves,1)
      need(integer(surface.focused_pane_id,1) and leaves[surface.focused_pane_id],'invalid focused pane')
      s.focused_pane_id=surface.focused_pane_id
      local zoom=surface.zoomed_pane_id
      need(zoom==json.null or integer(zoom,1) and leaves[zoom] and zoom==s.focused_pane_id,'invalid zoomed pane')
      s.zoomed_pane_id=zoom;w.surfaces[j]=s
      if sid==w.selected_surface_id then selected=true end
    end
    need(selected,'invalid selected surface');out.workspaces[i]=w
  end
  need(#out.workspaces==0 and input.selected_workspace_id==json.null
    or #out.workspaces>0 and workspaces[input.selected_workspace_id],'invalid selected workspace')
  out.selected_workspace_id=input.selected_workspace_id
  return out
end
function M.validate(input)
  local ok,value=pcall(validate,input)
  if ok then return value end
  return nil,{kind='protocol',message='Invalid layout snapshot: '..tostring(value)}
end

-- Input is a validated surface. make_view reuses existing presentation values.
-- Staging uses blank nodes, never the adapter's focus/empty callbacks.
function M.project(host_id,surface,Class,make_view)
  local nodes={}
  local function build(wire)
    local n=Class._blank(wire.type);n.remote_id=wire.id
    n.id='layout:'..host_id..':'..math.tointeger(wire.id);nodes[wire.id]=n
    if wire.type=='leaf' then
      n.views={}
      for i,desc in ipairs(wire.views)do
        local value=make_view(desc);need(value~=nil,'view factory returned nil');n.views[i]=value
        if desc.id==wire.active_view_id then n.active_view=value end
      end
      if #n.views==0 and Class._adapter.empty then
        local empty=Class._adapter.empty();n.views={empty};n.active_view=empty
      end
    else n.divider=wire.divider;n.a=build(wire.a);n.b=build(wire.b) end
    return n
  end
  local root=build(surface.tree);local selected=nodes[surface.focused_pane_id].active_view
  if surface.zoomed_pane_id~=json.null then
    local leaf=nodes[surface.zoomed_pane_id];local proxy=Class._blank('leaf')
    proxy:consume(leaf);proxy.zoomed=root;root=proxy
  end
  return root,selected,nodes
end
return M
