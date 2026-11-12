local ok,err=xpcall(function()
  local core=require 'core';local Tree=require 'bmux.tree';local View=require 'core.view'
  local TerminalView=require 'core.terminalview';local terminal=require 'terminal'
  local whole=core.root_view.root_node;local Class=getmetatable(whole);local Plain=Tree.class()
  whole.position={x=0,y=0};whole.size={x=1000,y=700}
  for _,name in ipairs{'split','close_active_view','move_view','swap_views','toggle_zoom','resize_by','get_leaves','get_node_in_direction','get_locked_size','update_layout'}do
    assert(Class[name]==Plain[name],'Studio uses the shared structural operation: '..name)
  end
  local first <close> =terminal.new(80,24,8);local second <close> =terminal.new(80,24,8)
  local sent={};local a=TerminalView{terminal=first,send=function(bytes)sent[#sent+1]=bytes end}
  local b=TerminalView{terminal=second,send=function(bytes)sent[#sent+1]=bytes end}
  local node=core.root_view:get_primary_node();node:add_view(a);node:split('right',b)
  whole:update_layout();local content=whole:get_node_for_view(b):get_content_root(whole)
  first:feed('\27[?1004h');second:feed('\27[?1004h');core.window_focused=true;b:on_focus_gained();sent={}
  local a_id=whole:get_node_for_view(a).id;local b_id=whole:get_node_for_view(b).id
  content:toggle_zoom();assert(core.active_view==b and content.active_view==b and content.id==b_id)
  assert(#sent==0,'zoom never focuses a temporary placeholder or sends spurious terminal focus')
  content:unzoom();assert(whole:get_node_for_view(a).id==a_id and whole:get_node_for_view(b).id==b_id)
  local before=table.concat(sent);local active=core.active_view
  local Dock=View:extend();function Dock:get_name()return 'tree-test dock'end
  local dock=Dock();dock.size.x=10;dock.size.y=20
  whole:get_node_for_view(a):split('up',dock,true)
  assert(core.active_view==active and table.concat(sent)==before,'locked split preserves terminal focus')
  whole:update_layout()
  -- Model admission captures the requested view rather than whatever is active
  -- when an asynchronous confirmation eventually completes.
  local Deferred=View:extend();local confirm
  function Deferred:get_name()return 'deferred close'end
  function Deferred:try_close(done)confirm=done end
  local deferred=Deferred();local owner=whole:get_node_for_view(b);owner:add_view(deferred)
  owner:close_active_view(whole);owner:set_active_view(b)
  local destination=whole:get_node_for_view(a);assert(owner:move_view(deferred,destination,whole))
  confirm();confirm();assert(not whole:get_node_for_view(deferred) and whole:get_node_for_view(b))
  local background=Deferred();owner=whole:get_node_for_view(b);owner:add_view(background);owner:close_active_view(whole)
  owner:set_active_view(b);whole:get_node_for_view(a):set_active_view(a);sent={};confirm()
  assert(core.active_view==a and owner.active_view==b and #sent==0,'background close preserves pane selection and native terminal focus')
  local command=require 'core.command';local extra=Dock();owner=whole:get_node_for_view(b);owner:add_view(extra)
  assert(command.perform('root:move-tab-left'));assert(owner.views[1]==extra and core.active_view==extra)
  assert(command.perform('root:move-tab-right'));assert(owner.views[2]==extra)
  owner:close_active_view(whole);owner:set_active_view(b)
  whole:update_layout();local width=owner.size.x
  assert(command.perform('root:grow'));whole:update_layout();assert(owner.size.x>width,'resize command uses the shared divider operation')
  assert(command.perform('root:balance'));whole:update_layout()
  assert(command.perform('root:switch-to-left') and core.active_view==a,'directional command uses shared geometry')
  assert(command.perform('root:move-pane-right') and whole:get_node_for_view(a).id==b_id,'pane swap command follows its unchanged terminal view')
  assert(a.terminal==first and b.terminal==second,'tree edits preserve terminal source identities')
  local divider=whole:get_node_for_view(a):get_content_root(whole)
  local x,y,w,h=divider:get_divider_rect();local px,py=math.floor(x+w/2),math.floor(y+h/2)
  local ratio,span=divider.divider,divider.size.x
  system._test_event{type='mousepressed',button=1,x=px,y=py}
  system._test_event{type='mousemoved',x=px+10,y=py,dx=10,dy=0}
  system._test_event{type='mousemoved',x=px+30,y=py,dx=20,dy=0}
  system._test_event{type='mousereleased',button=1,x=px+30,y=py}
  core.redraw=true;core.frame_start=system.get_time();core.step()
  assert(math.abs(divider.divider-(ratio+30/span))<.0001 and not core.root_view.dragged_divider,
    'coalesced motion is dispatched before the same-batch release')
  whole.position={x=0,y=0};whole.size={x=1,y=1};whole:update_layout()
  for _,leaf in ipairs(whole:get_leaves())do assert(leaf.size.x>=0 and leaf.size.y>=0 and leaf.active_view.size.y>=0)end
  print('studio_bmux_tree: actual shared model, stable IDs, native focus, dock/zoom, deferred moved close and source identity pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
