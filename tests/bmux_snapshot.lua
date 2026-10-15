local Snapshot=require 'bmux.snapshot'
local Layout=require 'bmux.layout';local Tree=require 'bmux.tree';local json=require 'json'
local host=Layout.new{host_id='snapshot-fixture',resolve=function()return true end}
local function command(op,args)
  local c={host_id=host.host_id,revision=host.revision,op=op}
  for k,v in pairs(args or {})do c[k]=v end
  return assert(host:command(c))
end
local empty=assert(Snapshot.validate(host:snapshot()));assert(#empty.workspaces==0)
local value=command('workspace_create',{title='Build 🦊'});local w=value.workspaces[1];local s=w.surfaces[1]
command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,
  view={kind='terminal',terminal_id='term-one',generation=1,title='日本語 é'}})
value=command('pane_split',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,direction='right',
  view={kind='agent',agent_id='external:one'}})
local right=value.workspaces[1].surfaces[1].tree.b.id
value=command('pane_zoom',{workspace_id=w.id,surface_id=s.id,pane_id=right})
local copy=assert(Snapshot.validate(value));assert(copy~=value and copy.workspaces[1]~=value.workspaces[1])
local focuses=0;local Class=Tree.class{focus=function()focuses=focuses+1 end}
local views={};local function view(desc)views[desc.id]=views[desc.id]or {name=desc.id};return views[desc.id]end
local root,selected,nodes=Snapshot.project(copy.host_id,copy.workspaces[1].surfaces[1],Class,view)
assert(focuses==0 and root.zoomed and root.remote_id==right and root.active_view==selected)
assert(#root:get_leaves()==1 and #root.zoomed:get_leaves()==2 and nodes[right].active_view==selected)
local again=Snapshot.project(copy.host_id,copy.workspaces[1].surfaces[1],Class,view)
assert(again.id==root.id and again.active_view==selected,'stable projection identity and reused views')
local wire=json.encode(value)
local function reject(edit)
  local bad=json.decode(wire);edit(bad)
  local accepted,why=Snapshot.validate(bad);assert(not accepted and why.kind=='protocol')
  assert(json.encode(value)==wire and focuses==0,'validation never mutates the source or presentation')
end
local function surface(v)return v.workspaces[1].surfaces[1]end
for _,edit in ipairs{
  function(v)v.v=2 end,function(v)v.host_id=''end,function(v)v.revision=-1 end,
  function(v)v.revision=math.huge end,function(v)v.workspaces.extra=true end,
  function(v)v.selected_workspace_id='missing'end,
  function(v)v.workspaces[1].title='\27bad'end,function(v)v.workspaces[1].title='\255'end,
  function(v)v.workspaces[1].selected_surface_id='missing'end,
  function(v)local s=v.workspaces[1].surfaces;s[3]=s[1]end,
  function(v)surface(v).focused_pane_id=surface(v).tree.id end,
  function(v)surface(v).zoomed_pane_id=surface(v).tree.a.id end,
  function(v)surface(v).tree.a.id=surface(v).tree.b.id end,
  function(v)surface(v).tree.divider=0/0 end,function(v)surface(v).tree.divider=1 end,
  function(v)surface(v).tree.a=surface(v).tree end,
  function(v)surface(v).tree.a.views[1].kind='browser'end,
  function(v)surface(v).tree.a.views[1].generation=false end,
  function(v)surface(v).tree.a.views[1].title=string.rep('x',257)end,
  function(v)surface(v).tree.b.views[1].id=surface(v).tree.a.views[1].id end,
  function(v)surface(v).tree.a.active_view_id=json.null end,
  function(v)surface(v).tree.a.views[1].agent_id='extra'end,
  function(v)surface(v).tree.a.views[33]=surface(v).tree.a.views[1]end,
}do reject(edit)end
local deep=json.decode(wire);local tree=surface(deep).tree
for i=1,25 do tree={id=100+i,type='hsplit',divider=.5,a=tree,b={id=200+i,type='leaf',views={},active_view_id=json.null}}end
surface(deep).tree=tree;assert(not Snapshot.validate(deep),'depth is bounded before projection')
local many=json.decode(wire);many.workspaces={}
for i=1,17 do many.workspaces[i]={id='w'..i}end
assert(not Snapshot.validate(many),'workspace collection bound')
local Empty=Tree.class{empty=function()return {placeholder=true}end,focus=function()error('staging focus')end}
local blank=assert(Snapshot.validate(command('surface_create',{workspace_id=w.id,title='Empty'})))
local empty_root,empty_view=Snapshot.project(blank.host_id,blank.workspaces[1].surfaces[2],Empty,function()error('no wire views')end)
assert(empty_root.views[1].placeholder and empty_view==empty_root.active_view)
print('bmux_snapshot: strict copied hierarchy, malformed/cyclic/sparse/bounded rejection, stable shared projection and focus-free zoom/empty staging pass')
return 0
