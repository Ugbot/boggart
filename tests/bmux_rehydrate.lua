local Layout=require 'bmux.layout';local Snapshot=require 'bmux.snapshot';local json=require 'json'
local fixture=assert(loadfile('tests/fixtures/bmux_checkpoint.lua'))()
local old,document=fixture();local before=json.encode(old:snapshot());local publications,remaps=0,0
local function remap(view)
  remaps=remaps+1
  if view.kind=='terminal'then return {kind='terminal',terminal_id='new-shell',generation=1,title='resource default'}end
  return {kind='agent',agent_id=view.agent_id==11 and 22 or 'new-agent',title=view.title}
end
local function resolve(v)
  return v.kind=='terminal'and v.terminal_id=='new-shell'and v.generation==1
    or v.kind=='agent'and(v.agent_id=='new-agent'or v.agent_id==22)
end
local restored,why=Layout.restore(document.layout,{remap=remap,resolve=resolve,changed=function()publications=publications+1 end})
assert(restored,why and why.message)
assert(restored.host_id~=old.host_id and restored.revision==1 and remaps==4 and publications==0)
assert(json.encode(old:snapshot())==before,'rehydration never mutates the original owner')
local snapshot=restored:snapshot();assert(Snapshot.validate(snapshot))
local ids={};local new_w=snapshot.workspaces[1];local old_w=document.layout.workspaces[1]
local function same_tree(a,b)
  assert(a.type==b.type and not ids[b.id]);ids[b.id]=true
  if a.type=='leaf'then
    local av=a.views==json.array and {}or a.views;local bv=b.views==json.array and {}or b.views
    assert(#av==#bv)
    for i,v in ipairs(av)do
      local mapped=remap(v);local actual=bv[i]
      assert(actual.kind==mapped.kind and actual.terminal_id==mapped.terminal_id and actual.agent_id==mapped.agent_id
        and actual.generation==mapped.generation and actual.title==v.title)
      assert((a.active_view_id==v.id)==(b.active_view_id==actual.id))
    end
  else assert(a.divider==b.divider);same_tree(a.a,b.a);same_tree(a.b,b.b)end
end
assert(#snapshot.workspaces==#document.layout.workspaces)
for i,w in ipairs(document.layout.workspaces)do
  local actual=snapshot.workspaces[i];assert(w.title==actual.title and #w.surfaces==#actual.surfaces)
  assert((document.layout.selected_workspace_id==w.id)==(snapshot.selected_workspace_id==actual.id))
  for j,s in ipairs(w.surfaces)do
    local a=actual.surfaces[j]
    assert(a.title==s.title and (w.selected_surface_id==s.id)==(actual.selected_surface_id==a.id))
    same_tree(s.tree,a.tree)
    assert((s.zoomed_pane_id==json.null)==(a.zoomed_pane_id==json.null))
  end
end
assert(new_w.selected_surface_id==new_w.surfaces[1].id and old_w.selected_surface_id==old_w.surfaces[1].id)
local surface=new_w.surfaces[1]
assert(surface.focused_pane_id==surface.tree.a.id and surface.zoomed_pane_id==surface.tree.a.id)
assert(surface.tree.a.views[1].terminal_id==surface.tree.a.views[2].terminal_id,'alias views bind the same mapped resource')
local function command(op,fields)
  local c={host_id=restored.host_id,revision=restored.revision,op=op}
  for k,v in pairs(fields)do c[k]=v end
  local value,error=restored:command(c);assert(value,error and error.message);return value
end
local stale,conflict=restored:command{host_id=old.host_id,revision=1,op='workspace_create',title='Stale'}
assert(not stale and conflict.status==409 and publications==0)
command('pane_zoom',{workspace_id=new_w.id,surface_id=surface.id,pane_id=surface.focused_pane_id})
command('pane_split',{workspace_id=new_w.id,surface_id=surface.id,pane_id=surface.focused_pane_id,direction='down',
  view={kind='terminal',terminal_id='new-shell',generation=1,title='Fresh'}})
command('workspace_create',{title='Later'})
assert(publications==3 and Snapshot.validate(restored:snapshot()),'restored Host retains ordinary command behavior and unique future IDs')
local function reject(input,options)
  local n=remaps;local host,error=Layout.restore(input,options or {remap=remap,resolve=resolve})
  assert(not host and error and #error.message<=512)
  assert(remaps==n and json.encode(old:snapshot())==before and publications==3,'reject before mapping/publishing or mutating source')
end
for _,limits in ipairs{{workspaces=1},{surfaces=1},{panes=1},{views=1},{tabs=1},{depth=1},{depth=25},{unknown=1}}do
  reject(document.layout,{limits=limits,remap=remap,resolve=resolve})
end
local bad=json.decode(before);bad.workspaces[1].surfaces[1].focused_pane_id=99999;reject(bad)
reject(document.layout,{remap=remap,resolve=resolve,host_id=old.host_id})
reject(document.layout,{resolve=resolve});reject(document.layout,{remap=remap,resolve=resolve,changed=true})
for _,mapping in ipairs{
  function()return nil,{message='runtime not available'}end,
  function()error('mapping failed')end,
  function()return {kind='terminal',terminal_id='missing',generation=1}end,
  function()return {kind='terminal',terminal_id='new-shell',generation=1,control_token='secret'}end,
  function()return {kind='terminal',terminal_id='new-shell',generation=1,id='old-id'}end,
  function()return {kind='browser',url='https://example.com'}end,
  function()return 7 end,
}do
  local value,error=Layout.restore(document.layout,{remap=mapping,resolve=resolve,changed=function()error('must not publish')end})
  assert(not value and error and #error.message<=512 and json.encode(old:snapshot())==before)
end
local empty=Layout.new{resolve=function()return true end}:snapshot()
local value=assert(Layout.restore(empty,{resolve=resolve,remap=function()error('empty layout has no references')end}))
assert(value:snapshot().workspaces==json.array and value:snapshot().selected_workspace_id==json.null)
assert(value:command{host_id=value.host_id,revision=1,op='workspace_create',title='First'})
print('Bmux rehydrate: actual shared tree, fresh host, aliases, selected tabs/focus/zoom, bounded atomic rejection and future commands pass')
return 0
