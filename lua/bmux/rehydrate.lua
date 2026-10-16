-- Rebuild a fresh authoritative tree; remappers bind resources, never wire IDs.
local Layout=require 'bmux.layout';local Snapshot=require 'bmux.snapshot'
local Reference=require('bmux.layoutcommands').reference;local json=require 'json'
local M={}
local function need(ok,message)if not ok then error(message,0)end end
local function build(snapshot,opts)
  need(type(opts)=='table'and type(opts.resolve)=='function'and type(opts.remap)=='function','trusted restore callbacks required')
  need(opts.host_id==nil,'restored host identity must be fresh')
  need(opts.changed==nil or type(opts.changed)=='function','invalid layout change callback')
  local host=Layout.new{resolve=opts.resolve,limits=opts.limits,changed=opts.changed}
  local limits=host.limits;local counts={surfaces=0,panes=0,views=0}
  local function check(node,depth)
    need(depth<=limits.depth,'restored tree depth exceeds host limit')
    if node.type=='leaf'then
      counts.panes=counts.panes+1;counts.views=counts.views+#node.views
      need(counts.panes<=limits.panes and counts.views<=limits.views and #node.views<=limits.tabs,'restored panes/views exceed host limit')
    else check(node.a,depth+1);check(node.b,depth+1)end
  end
  need(#snapshot.workspaces<=limits.workspaces,'restored workspaces exceed host limit')
  for _,w in ipairs(snapshot.workspaces)do for _,s in ipairs(w.surfaces)do
    counts.surfaces=counts.surfaces+1;need(counts.surfaces<=limits.surfaces,'restored surfaces exceed host limit')
    check(s.tree,1)
  end end
  local function tree(wire,nodes)
    local node=host.Node._blank(wire.type);nodes[wire.id]=node
    if wire.type=='leaf'then
      for i,v in ipairs(wire.views)do
        local copied={id=v.id,kind=v.kind,terminal_id=v.terminal_id,generation=v.generation,agent_id=v.agent_id,title=v.title}
        local mapped,why=opts.remap(copied)
        need(mapped,why and why.message or 'saved view has no runtime mapping')
        need(type(mapped)=='table'and getmetatable(mapped)==nil,'mapped reference must be a plain record')
        local reference;reference,why=Reference(host,mapped)
        need(reference,why and why.message or 'mapped reference is unavailable')
        reference.id=host:_id('view');reference.title=v.title or reference.title;node.views[i]=reference
        if v.id==wire.active_view_id then node.active_view=reference end
      end
      if #node.views==0 then local empty={empty=true};node.views={empty};node.active_view=empty end
    else node.divider=wire.divider;node.a=tree(wire.a,nodes);node.b=tree(wire.b,nodes)end
    return node
  end
  for i,w in ipairs(snapshot.workspaces)do
    local workspace={id=host:_id('workspace'),title=w.title,surfaces={}}
    for j,s in ipairs(w.surfaces)do
      local nodes={};local surface={id=host:_id('surface'),title=s.title,tree=tree(s.tree,nodes)}
      local focused=nodes[s.focused_pane_id]
      surface.focused_pane=focused.id;host._focused=focused.active_view
      if s.zoomed_pane_id~=json.null then surface.tree:toggle_zoom()end
      workspace.surfaces[j]=surface
      if s.id==w.selected_surface_id then workspace.selected_surface=surface.id end
    end
    host.workspaces[i]=workspace
    if w.id==snapshot.selected_workspace_id then host.selected_workspace=workspace.id end
  end
  if host.selected_workspace then
    local w=host:_workspace(host.selected_workspace);host:_activate(host:_surface(w,w.selected_surface))
  end
  host.revision=1;return host
end
function M.new(input,opts)
  local snapshot,why=Snapshot.validate(input);if not snapshot then return nil,why end
  local ok,host=pcall(build,snapshot,opts)
  if ok then return host end
  return nil,{kind='restore',message=('Cannot restore Bmux layout: '..tostring(host)):sub(1,512)}
end
return M
