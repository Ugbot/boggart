local Layout=require 'bmux.layout'
local json=require 'json'
local referenced={terminal=0,agent=0}
for _,limits in ipairs{false,{tabs=false},{tabs=0},{depth=25},{unknown=1}}do
  assert(not pcall(Layout.new,{resolve=function()return true end,limits=limits}),'invalid trusted limits must not silently use defaults')
end
assert(not pcall(Layout.new,{resolve=function()return true end,host_id=''}))
local host=Layout.new{host_id='layout-fixture',resolve=function(view)
  referenced[view.kind]=referenced[view.kind]+1
  return view.kind=='terminal' and view.terminal_id=='term-fixture' and view.generation==1
    or view.kind=='agent' and view.agent_id=='foreign-agent'
end}
local function command(op,fields)
  local cmd={host_id=host.host_id,revision=host.revision,op=op}
  for k,v in pairs(fields or {})do cmd[k]=v end
  local result,why=host:command(cmd);assert(result,why and why.message);return result
end
local empty=host:snapshot();assert(empty.v==1 and empty.revision==0 and empty.workspaces==json.array)
local snapshot=command('workspace_create',{title='Build 🦊'})
local workspace=snapshot.workspaces[1];local surface=workspace.surfaces[1]
assert(workspace.title=='Build 🦊' and surface.tree.type=='leaf' and surface.tree.views==json.array)
local scope={workspace_id=workspace.id,surface_id=surface.id}
local function pane_command(op,fields)
  local all={workspace_id=scope.workspace_id,surface_id=scope.surface_id}
  for k,v in pairs(fields or {})do all[k]=v end
  return command(op,all)
end
local descriptor={kind='terminal',terminal_id='term-fixture',generation=1,title='Shell é'}
snapshot=pane_command('view_add',{pane_id=surface.tree.id,view=descriptor})
local leaf=snapshot.workspaces[1].surfaces[1].tree
assert(leaf.views[1].terminal_id=='term-fixture' and leaf.active_view_id==leaf.views[1].id)
descriptor.title='changed';assert(host:snapshot().workspaces[1].surfaces[1].tree.views[1].title=='Shell é')
local function current()
  for _,w in ipairs(host:snapshot().workspaces)do
    if w.id==scope.workspace_id then
      for _,s in ipairs(w.surfaces)do if s.id==scope.surface_id then return s,w end end
    end
  end
end
local function reject(status,op,fields)
  local before,serial=json.encode(host:snapshot()),host.serial
  local c={host_id=host.host_id,revision=host.revision,op=op,workspace_id=scope.workspace_id,surface_id=scope.surface_id}
  for k,v in pairs(fields or {})do c[k]=v end
  local value,why=host:command(c);assert(not value and why.status==status,(why and why.message)or'unexpected acceptance')
  assert(json.encode(host:snapshot())==before and host.serial==serial,'rejection is atomic: '..op)
end
local first_view=leaf.views[1].id;local first_pane=leaf.id
snapshot=pane_command('pane_split',{pane_id=first_pane,direction='right',view={kind='agent',agent_id='foreign-agent',title='Foreign agent'}})
surface=current();local root_id=surface.tree.id;local right=surface.tree.b.id
assert(surface.tree.a.id==first_pane and surface.focused_pane_id==right)
pane_command('split_resize',{split_id=root_id,ratio=.7});assert(current().tree.divider==.7)
pane_command('balance');assert(current().tree.divider==.5)
pane_command('pane_zoom',{pane_id=first_pane});surface=current()
assert(surface.zoomed_pane_id==first_pane and surface.tree.a.views[1].id==first_view and surface.tree.b.views[1].kind=='agent')
local rejected={
  {400,'pane_split',{pane_id=first_pane,direction='diagonal'}},
  {400,'view_add',{pane_id=first_pane,view={kind='terminal',terminal_id='term-fixture',generation=1,control_token='never'}}},
  {404,'view_add',{pane_id=first_pane,view={kind='terminal',terminal_id='term-fixture',generation=2}}},
  {400,'view_add',{pane_id=first_pane,view={kind='agent',agent_id='foreign-agent',generation=1}}},
  {400,'view_add',{pane_id=first_pane,view={kind='browser',url='https://example.com'}}},
  {400,'view_add',{pane_id=first_pane,view={kind='terminal',terminal_id='term-fixture',generation=1,title='\255'}}},
  {400,'view_add',{pane_id=first_pane,view={kind='agent',agent_id='foreign-agent',title='escape\27'}}},
  {404,'view_move',{pane_id=first_pane,view_id=first_view,target_pane_id=9999}},
  {404,'view_move',{pane_id=right,view_id=first_view,target_pane_id=first_pane}},
  {400,'view_move',{pane_id=first_pane,view_id=first_view,target_pane_id=right,index=5}},
  {400,'split_resize',{split_id=root_id,ratio=0/0}},
  {400,'split_resize',{split_id=root_id,ratio=math.huge}},
  {400,'split_resize',{split_id=first_pane,ratio=.5}},
  {404,'pane_focus',{pane_id=first_pane,view_id='foreign-view'}},
  {400,'pane_focus',{pane_id=first_pane,extra=true}},
  {409,'pane_focus',{pane_id=first_pane,revision=host.revision-1}},
  {409,'pane_focus',{pane_id=first_pane,host_id='old-host'}},
  {400,'pane_focus',{pane_id=first_pane,revision=false}},
  {404,'pane_focus',{pane_id=first_pane,surface_id='surface-absent'}},
}
for _,case in ipairs(rejected)do reject(table.unpack(case))end
pane_command('pane_focus',{pane_id=right});assert(current().zoomed_pane_id==json.null,'focus a hidden pane restores the complete layout')
pane_command('pane_swap',{pane_id=first_pane,target_pane_id=right})
assert(current().tree.b.views[1].id==first_view and current().focused_pane_id==right)
pane_command('view_move',{pane_id=right,view_id=first_view,target_pane_id=first_pane})
surface=current();assert(surface.tree.type=='leaf' and surface.tree.id==first_pane and #surface.tree.views==2)
pane_command('view_move',{pane_id=first_pane,view_id=first_view,target_pane_id=first_pane,index=1})
assert(current().tree.views[1].id==first_view)
pane_command('view_close',{pane_id=first_pane});assert(#current().tree.views==1)
pane_command('view_close',{pane_id=first_pane});assert(current().tree.views==json.array)
pane_command('pane_split',{pane_id=first_pane,direction='down'});surface=current();local empty_pane=surface.tree.b.id
pane_command('pane_zoom',{pane_id=empty_pane});assert(current().zoomed_pane_id==empty_pane,'empty panes can zoom without synthetic wire views')
pane_command('pane_zoom',{pane_id=empty_pane});assert(current().zoomed_pane_id==json.null)
pane_command('view_close',{pane_id=empty_pane});assert(current().tree.type=='leaf')

local other=command('workspace_create',{title='Other'}).workspaces[2]
pane_command('pane_focus',{pane_id=first_pane})
assert(host:snapshot().selected_workspace_id==other.id,'editing an inactive surface does not select its workspace')
command('workspace_select',{workspace_id=scope.workspace_id})
command('workspace_rename',{workspace_id=scope.workspace_id,title='Renamed 🧑‍💻'})
snapshot=command('surface_create',{workspace_id=scope.workspace_id,title='Tests'})
local second_surface=snapshot.workspaces[1].surfaces[2]
command('surface_select',{workspace_id=scope.workspace_id,surface_id=scope.surface_id})
command('surface_rename',{workspace_id=scope.workspace_id,surface_id=second_surface.id,title='Checks'})
command('surface_remove',{workspace_id=scope.workspace_id,surface_id=second_surface.id})
reject(409,'surface_remove')
command('workspace_remove',{workspace_id=other.id})
local copied=host:snapshot();copied.workspaces[1].title='tampered';copied.workspaces[1].surfaces[1].tree.id=0
assert(host:snapshot().workspaces[1].title=='Renamed 🧑‍💻' and current().tree.id==first_pane,'snapshots never alias owner state')
assert(json.decode(json.encode(host:snapshot())).workspaces[1].surfaces[1].tree.type=='leaf')

local full=Layout.new{host_id='small',resolve=function()return true end,limits={workspaces=1,surfaces=1,panes=2,views=2,tabs=1,depth=2}}
local function small(op,args,wanted)
  local c={host_id=full.host_id,revision=full.revision,op=op}
  for k,v in pairs(args or {})do c[k]=v end
  local before=json.encode(full:snapshot());local value,why=full:command(c)
  if wanted then assert(not value and why.status==wanted);assert(json.encode(full:snapshot())==before)
  else assert(value,why and why.message);return value end
end
snapshot=small('workspace_create',{title='Budget'});local w=snapshot.workspaces[1];local s=w.surfaces[1]
small('workspace_create',{title='Too many'},413)
small('surface_create',{workspace_id=w.id,title='Too many'},413)
local fields={workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,view={kind='agent',agent_id='a'}}
small('view_add',fields);small('view_add',fields,413)
fields.direction='right';snapshot=small('pane_split',fields)
fields.pane_id=snapshot.workspaces[1].surfaces[1].tree.b.id;small('pane_split',fields,413)
fields.direction=nil;small('view_add',fields,413)
command('workspace_remove',{workspace_id=scope.workspace_id});assert(host:snapshot().workspaces==json.array)
assert(host:snapshot().selected_workspace_id==json.null)
-- Keep each budget independent so another full resource cannot mask a missing gate.
local function budget(limits,exercise)
  local owner=Layout.new{host_id='budget',limits=limits,resolve=function()return true end}
  local function run(op,args,status)
    local c={host_id=owner.host_id,revision=owner.revision,op=op}
    for k,v in pairs(args or {})do c[k]=v end
    local before=json.encode(owner:snapshot());local value,why=owner:command(c)
    if status then assert(not value and why.status==status);assert(json.encode(owner:snapshot())==before)
    else assert(value,why and why.message);return value end
  end
  local w=run('workspace_create',{title='Budget'}).workspaces[1];local s=w.surfaces[1]
  exercise(function(op,fields,status)
    local c={workspace_id=w.id,surface_id=s.id};for k,v in pairs(fields or {})do c[k]=v end
    return run(op,c,status)
  end,s.tree.id)
end
budget({views=1},function(run,pane)
  local ref={kind='agent',agent_id='a'}
  run('view_add',{pane_id=pane,view=ref});run('view_add',{pane_id=pane,view=ref},413)
end)
budget({panes=2},function(run,pane)
  local s=run('pane_split',{pane_id=pane,direction='right'})
  run('pane_split',{pane_id=s.workspaces[1].surfaces[1].tree.b.id,direction='down'},413)
end)
budget({depth=2},function(run,pane)
  local s=run('pane_split',{pane_id=pane,direction='right'})
  run('pane_split',{pane_id=s.workspaces[1].surfaces[1].tree.b.id,direction='down'},413)
end)
budget({tabs=1},function(run,pane)
  local ref={kind='agent',agent_id='a'}
  local s=run('pane_split',{pane_id=pane,direction='right',view=ref})
  run('view_add',{pane_id=pane,view=ref})
  run('view_move',{pane_id=s.workspaces[1].surfaces[1].tree.b.id,
    view_id=s.workspaces[1].surfaces[1].tree.b.views[1].id,target_pane_id=pane},413)
end)
local exhausted=Layout.new{host_id='exhausted',resolve=function()return true end}
exhausted.revision=9007199254740990
local before=json.encode(exhausted:snapshot())
local value,why=exhausted:command{host_id=exhausted.host_id,revision=exhausted.revision,op='workspace_create',title='Too late'}
assert(not value and why.status==503 and json.encode(exhausted:snapshot())==before and exhausted.serial==0)
print('bmux_layout: hierarchy, all structural commands, copied references, zoom, atomic rejection, epoch/revision, capacities and selection pass')
return 0
