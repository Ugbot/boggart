local Tree=require 'bmux.tree'
local selected;local pending={}
local Node=Tree.class{focus=function(view)selected=view end,focused=function()return selected end,
  close=function(view,done)pending[view]=done end,
  locked_size=function(view)return view.width,view.height end,divider=function()return 1 end}
local a,b,c,d={name='a'},{name='b'},{name='c'},{name='d'}
local root=Node();root:add_view(a);local first_id=root.id
local left=root:split('right',b);assert(left==root.a and left.id==first_id and selected==b)
root.b:split('down',c);assert(#root:get_leaves()==3 and root:get_node_for_view(c)==root.b.b)
root.position={x=0,y=0};root.size={x=101,y=61};root:update_layout()
assert(root.a.size.x==49 and root.b.size.x==51 and root.b.a.size.y==29 and root.b.b.size.y==31)
assert(root.a:get_node_in_direction(root,'right')==root.b.b)
assert(root.b.b:get_node_in_direction(root,'up')==root.b.a)
assert(not root.a:get_node_in_direction(root,'left'))
root:set_divider(0.8);root.b:set_divider(0.2);root:balance();assert(root.divider==0.5 and root.b.divider==0.5)
assert(root.a:swap_views(root.b.b));assert(root.a.active_view==c and root.b.b.active_view==a and selected==a)
local source=root:get_node_for_view(a);source:add_view(d)
assert(source:move_view(d,root.a,root));assert(root.a.views[2]==d and root.a.active_view==d)
assert(source.active_view==a and #root:get_leaves()==3)
source:close_active_view(root);assert(pending[a]);root.a:set_active_view(c)
pending[a]();assert(not root:get_node_for_view(a) and root:get_node_for_view(c) and selected==c,'background close preserves the current focus')
-- Deferred close is tied to the requested view, even after a move.
root.a:set_active_view(d);root.a:close_active_view(root)
local other=root:get_node_for_view(b);assert(root.a:move_view(d,other,root))
pending[d]();assert(not root:get_node_for_view(d) and root:get_node_for_view(c))
-- Zoom retains neighbours; a structural edit first restores the saved tree.
root:get_node_for_view(c):set_active_view(c);local before=#root:get_leaves()
root:toggle_zoom();assert(root.zoomed and root.active_view==c and #root:get_leaves()==1)
root:split('right',d);assert(not root.zoomed and #root:get_leaves()==before+1 and root:get_node_for_view(b))
root:get_node_for_view(c):set_active_view(c);root:toggle_zoom();root:close_active_view(root);pending[c]()
assert(not root.zoomed and not root:get_node_for_view(c) and root:get_node_for_view(b))
local single=Node();single:add_view(a);single:close_active_view(single);pending[a]();assert(#single.views==0 and not single.active_view)
local tabs=Node();tabs:add_view(a);tabs:add_view(b);tabs:close_view(a,tabs);pending[a]()
assert(tabs.active_view==b and selected==b and #tabs.views==1,'closing a named background tab does not focus it first')
local content=Node();content:add_view(b);content:split('left',{width=10,height=20},true)
local dock=content.a;local body=content.b;assert(dock:is_locked() and #content:get_leaves()==1)
assert(not dock:swap_views(body));body:close_active_view(content);pending[b]()
assert(content.a==dock and #content.b.views==0,'closing last content view preserves a dock')
for _,size in ipairs{0,1,2,3,10}do
  content.position={x=0,y=0};content.size={x=size,y=size};content:update_layout()
  for _,node in ipairs{content.a,content.b}do assert(node.size.x>=0 and node.size.y>=0 and node.position.x>=0)end
  local x,y,w,h=content:get_divider_rect();assert(x>=0 and y>=0 and x+w<=size and y+h<=size,'divider stays within tiny bounds')
end
local prior=content.divider;assert(not pcall(content.set_divider,content,0/0));assert(content.divider==prior)
local nested=Node();nested:add_view(a)
local body=nested:split('left',{width=10,height=20},true)
nested.a:split('down',{width=15,height=30},true)
local w,h=nested.a:get_locked_size();assert(w==15 and h==51,'vertical dock bounds use max width and summed height')
assert(body:get_content_root(nested)==body,'content boundary excludes a composite locked dock')
nested.position={x=0,y=0};nested.size={x=100,y=100};nested:update_layout()
assert(body.size.x==84 and nested.a.size.x==15,'shared dock measurement controls the content boundary')
local collapse=Node();collapse:add_view(a);local closing=collapse:split('right',b)
collapse.b:split('left',{width=10,height=20},true)
closing:set_active_view(a);closing:close_active_view(collapse);pending[a]()
assert(selected==b and collapse:get_node_for_view(b),'collapse focuses content rather than a dock inside the promoted subtree')
assert(not pcall(content.split,content,'diagonal',a))
local identity=root.id;root:consume(root);assert(root.id==identity and root:get_node_for_view(b))
local moving=Node();moving:add_view(a);local origin=moving:split('right')
assert(origin:move_view(a,moving.b,moving) and moving:get_node_for_view(a)==moving and moving.active_view==a,'last tab moves into empty sibling through collapse')
local separate=Node();separate:add_view(d)
assert(not moving:move_view(a,separate,moving) and moving:get_node_for_view(a)==moving,'foreign destination rejected')
local old=moving:split('right',b)
assert(not old:move_view(b,old,moving),'cannot move a view on behalf of another pane')
assert(not pcall(old.set_active_view,old,nil),'a populated pane must have a selected view')
local active,focuses=nil,0
local Presented=Tree.class{empty=function()return {empty=true}end,is_empty=function(v)return v.empty end,
  focus=function(v)assert(v);active=v;focuses=focuses+1 end,focused=function()return active end}
local presented=Presented();presented:add_view(a);presented:split('right',b)
local focus_before=focuses;presented:toggle_zoom()
assert(active==b and focuses==focus_before,'zoom snapshots do not focus temporary empty views')
presented:unzoom();focus_before=focuses;local selected_view=active
presented:get_node_for_view(a):split('up',{name='dock'},true)
assert(active==selected_view and focuses==focus_before,'locked splits preserve focus without temporary transitions')
local dock_node=presented:get_node_for_view(a):get_parent_node(presented).a
dock_node:split('down',{name='second dock'},true)
assert(dock_node:is_locked() and active==selected_view and focuses==focus_before,'a dock can subdivide into locked children without stealing focus')
assert(not pcall(dock_node.a.split,dock_node.a,'right',c),'locked docks reject user-content splits')
local Unfocused=Tree.class{focused=function()return nil end};local unfocused=Unfocused()
unfocused:add_view(a);unfocused:split('right',b);unfocused:toggle_zoom()
assert(not unfocused.zoomed,'host reporting no focused view overrides cached selection')
-- A reproducible mixed-operation trace checks loss/duplication and selection
-- through promotions, tab movement and zoomed structural edits.
local Plain=Tree.class();local trace=Plain();local expected={};local serial,seed=0,193
local function random(n)seed=(seed*48271)%2147483647;return seed%n+1 end
local function add(node)serial=serial+1;local v={name='trace-'..serial};expected[v]=true;node:add_view(v);return v end
add(trace)
for step=1,240 do
  local leaves=trace:get_leaves();local source=leaves[random(#leaves)];local target=leaves[random(#leaves)]
  local op=random(6)
  if not source.active_view then add(source)
  elseif op==1 and #leaves<16 then serial=serial+1;local v={name='trace-'..serial};expected[v]=true;source:split(random(2)==1 and 'right' or 'down',v)
  elseif op==2 then source:swap_views(target)
  elseif op==3 then source:move_view(source.active_view,target,trace)
  elseif op==4 then expected[source.active_view]=nil;source:close_active_view(trace)
  elseif op==5 then source:set_active_view(source.active_view);trace:toggle_zoom()
  else trace:balance()end
  trace.position={x=3,y=7};trace.size={x=123,y=49};trace:update_layout()
  local seen,ids={},{}
  local function check(node)
    if node.zoomed then check(node.zoomed);return end
    assert(not ids[node.id]);ids[node.id]=true
    if node.type=='leaf'then
      assert(#node.views==0 and node.active_view==nil or node:get_view_idx(node.active_view))
      for _,v in ipairs(node.views)do assert(expected[v] and not seen[v]);seen[v]=true end
    else check(node.a);check(node.b)end
  end
  check(trace);for v in pairs(expected)do assert(seen[v],'mixed trace lost a view')end
  for _,leaf in ipairs(trace:get_leaves())do assert(leaf.size.x>=0 and leaf.size.y>=0)end
end
print('bmux_tree: shared descriptor split/close/focus/resize/move/swap/zoom, deferred identity, docks and bounded geometry pass')
return 0
