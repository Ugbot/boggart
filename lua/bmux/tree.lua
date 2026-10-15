-- One structural tree for descriptor, Studio and terminal-cell adapters.
-- Views are opaque values. This module neither starts nor closes processes.
local M={};local Node={}
local directions={left='hsplit',right='hsplit',up='vsplit',down='vsplit'}
local function adapter(self)return getmetatable(self)._adapter end
local function divider(self)
  local value=adapter(self).divider
  return type(value)=='function' and value() or value or 1
end
local function focused(self)
  local a=adapter(self);if a.focused then return a.focused()end;return a.selected
end
function M.class(opts)
  local serial=0;local class={_adapter=opts or {}};class.__index=class
  local function make(proto,kind,populate)
    kind=kind or 'leaf';assert(kind=='leaf' or kind=='hsplit' or kind=='vsplit','invalid tree node type')
    serial=serial+1
    local self=setmetatable({id=serial,type=kind,position={x=0,y=0},size={x=0,y=0},views={},divider=0.5},proto)
    if populate and kind=='leaf' and adapter(self).empty then self:add_view(adapter(self).empty())end
    return self
  end
  class._blank=function(kind)return make(class,kind,false)end
  return setmetatable(class,{__index=Node,__call=function(proto,kind)return make(proto,kind,true)end})
end
function Node:consume(other)
  if self==other then return end
  for key in pairs(self)do self[key]=nil end
  for key,value in pairs(other)do self[key]=value end
end
function Node:set_active_view(view)
  assert(self.type=='leaf','cannot focus a split node')
  assert(view==nil and #self.views==0 or view~=nil and self:get_view_idx(view),'view is not in this pane')
  self.active_view=view;local a=adapter(self);a.selected=view
  if a.focus then a.focus(view)end
end
function Node:get_view_idx(view)
  for i,item in ipairs(self.views)do if item==view then return i end end
end
function Node:add_view(view)
  assert(self.type=='leaf' and not self.locked,'cannot add a view to this pane');assert(view~=nil,'view required')
  local empty=adapter(self).is_empty
  if self.views[1] and empty and empty(self.views[1])then table.remove(self.views,1)end
  self.views[#self.views+1]=view;self:set_active_view(view)
end
function Node:split(dir,view,locked)
  assert(self.type=='leaf' and (not self.locked or locked),'cannot split this pane')
  local kind=assert(directions[dir],'invalid split direction')
  if self.zoomed then
    local active=self.active_view;self:unzoom()
    return assert(self:get_node_for_view(active)):split(dir,view,locked)
  end
  local class=getmetatable(self)
  local child=class._blank('leaf');child:consume(self);self:consume(class._blank(kind))
  self.a=child;self.b=class._blank('leaf')
  if locked then
    self.b.locked=locked;view=view or adapter(self).empty and adapter(self).empty()
    if view then self.b.views={view};self.b.active_view=view end
  elseif view then self.b:add_view(view)
  elseif adapter(self).empty then self.b:add_view(adapter(self).empty())end
  if dir=='up' or dir=='left'then self.a,self.b=self.b,self.a end
  return child
end
function Node:get_node_for_view(view)
  if view==nil then return end
  for _,item in ipairs(self.views)do if item==view then return self end end
  if self.type~='leaf'then return self.a:get_node_for_view(view) or self.b:get_node_for_view(view)end
end
function Node:get_parent_node(root)
  if root.a==self or root.b==self then return root end
  if root.type~='leaf'then return self:get_parent_node(root.a) or self:get_parent_node(root.b)end
end
function Node:find_node(id)
  if self.id==id then return self end
  if self.type~='leaf'then return self.a:find_node(id) or self.b:find_node(id)end
end
function Node:get_leaves(out)
  out=out or {}
  if self.type=='leaf'then if not self.locked then out[#out+1]=self end
  else self.a:get_leaves(out);self.b:get_leaves(out)end
  return out
end
function Node:get_children(out)
  out=out or {};for _,view in ipairs(self.views)do out[#out+1]=view end
  if self.type~='leaf'then self.a:get_children(out);self.b:get_children(out)end;return out
end
function Node:is_locked()
  if self.type=='leaf'then return not not self.locked end
  return self.a:is_locked() and self.b:is_locked()
end
function Node:get_primary_node()
  if self.type=='leaf'then return not self.locked and self or nil end
  return self.a:get_primary_node() or self.b:get_primary_node()
end
function Node:get_content_root(root)
  local top=self;local parent=top:get_parent_node(root)
  while parent do
    local sibling=parent.a==top and parent.b or parent.a
    if sibling:is_locked()then break end
    top=parent;parent=top:get_parent_node(root)
  end
  return top
end
function Node:_remove_view(view,root,activate)
  local idx=self:get_view_idx(view);if not idx then return false end
  local previous=self.active_view
  local function select(node,value)
    node.active_view=value;if activate~=false then node:set_active_view(value)end
  end
  table.remove(self.views,idx)
  if #self.views>0 then select(self,previous~=view and previous or self.views[idx] or self.views[#self.views]);return true end
  local parent=self:get_parent_node(root);local is_a=parent and parent.a==self
  local other=parent and parent[is_a and 'b' or 'a']
  if not parent or other:is_locked()then
    local empty=adapter(self).empty and adapter(self).empty()
    self.views=empty and {empty} or {};select(self,empty)
  else
    parent:consume(other);local leaf=parent
    while leaf.type~='leaf'do
      local preferred=leaf[is_a and 'a' or 'b']
      leaf=preferred:is_locked() and leaf[is_a and 'b' or 'a'] or preferred
    end
    select(leaf,leaf.active_view)
  end
  return true
end
function Node:close_active_view(root)
  if self.type~='leaf' or self.locked or self.active_view==nil then return false end
  local view=self.active_view;local a=adapter(self);local done=false
  local function remove()
    if done then return end;done=true;local activate=focused(root)==view;root:unzoom()
    local current=root:get_node_for_view(view)
    if current then current:_remove_view(view,root,activate);if a.after_close then a.after_close()end end
  end
  if a.close then a.close(view,remove)else remove()end;return true
end
function Node:swap_views(target)
  if self.type~='leaf' or not target or target.type~='leaf' or self.locked or target.locked then return false end
  self.views,target.views=target.views,self.views
  self.active_view,target.active_view=target.active_view,self.active_view
  target:set_active_view(target.active_view);return true
end
function Node:move_view(view,target,root,index)
  if self.type~='leaf' or not target or target.type~='leaf' or self.locked or target.locked then return false end
  if index~=nil then assert(type(index)=='number' and index%1==0 and index>=1 and index<=#target.views+1,'invalid tab index')end
  local source_id=self.id;local target_view=target.zoomed and target.active_view;root:unzoom()
  if target_view then target=root:get_node_for_view(target_view)end
  local source=root:get_node_for_view(view)
  if not source or source.id~=source_id or source.locked or not target or (target~=root and not target:get_parent_node(root))then return false end
  local destination_id=target.id
  if source==target then table.remove(source.views,source:get_view_idx(view))else source:_remove_view(view,root,false)end
  -- A collapse may have moved the destination into its parent object.
  target=assert(root:find_node(destination_id))
  local empty=adapter(target).is_empty
  if target.views[1] and empty and empty(target.views[1])then table.remove(target.views,1)end
  table.insert(target.views,math.min(index or #target.views+1,#target.views+1),view);target:set_active_view(view);return true
end
function Node:set_divider(value)
  assert(type(value)=='number' and value==value and math.abs(value)<math.huge,'invalid split ratio')
  self.divider=math.max(0.01,math.min(0.99,value))
end
function Node:resize_by(dx,dy)
  if self.type=='leaf'then return false end
  local axis=self.type=='hsplit' and 'x' or 'y';if self.size[axis]<=0 then return false end
  self:set_divider(self.divider+(axis=='x' and dx or dy)/self.size[axis]);return true
end
function Node:balance()
  if self.type~='leaf'then self.divider=0.5;self.a:balance();self.b:balance()end
end
function Node:toggle_zoom()
  if self.zoomed then
    local saved,active=self.zoomed,self.active_view;local focus=focused(self);self:consume(saved)
    local node=self:get_node_for_view(active)
    if node then node.active_view=active;if focus==active then node:set_active_view(active)end end;return
  end
  local leaf=self:get_node_for_view(focused(self));if not leaf or leaf==self then return end
  local class=getmetatable(self);local saved=class._blank('leaf');saved:consume(self)
  local fresh=class._blank('leaf');fresh.id=leaf.id;fresh.views=leaf.views;fresh.active_view=leaf.active_view;fresh.zoomed=saved
  fresh.position,fresh.size=self.position,self.size
  self:consume(fresh)
end
function Node:unzoom()
  if self.zoomed then self:toggle_zoom()end
  if self.type~='leaf'then self.a:unzoom();self.b:unzoom()end
end
function Node:get_child_overlapping_point(x,y)
  if self.type=='leaf'then return self end
  local first=self.type=='hsplit' and x<self.b.position.x or self.type=='vsplit' and y<self.b.position.y
  return (first and self.a or self.b):get_child_overlapping_point(x,y)
end
function Node:get_node_in_direction(root,dir)
  assert(directions[dir],'invalid focus direction')
  local x,y
  if dir=='left' or dir=='right'then
    y=self.position.y+self.size.y/2;x=self.position.x+(dir=='left' and -1 or self.size.x+divider(self))
  else x=self.position.x+self.size.x/2;y=self.position.y+(dir=='up' and -1 or self.size.y+divider(self))end
  local target=root:get_child_overlapping_point(x,y)
  if target~=self and not target:is_locked()then return target end
end
function Node:get_divider_rect()
  local x,y=self.position.x,self.position.y
  if self.type=='hsplit'then return x+self.a.size.x,y,math.max(0,self.b.position.x-x-self.a.size.x),math.max(0,self.size.y)
  elseif self.type=='vsplit'then return x,y+self.a.size.y,math.max(0,self.size.x),math.max(0,self.b.position.y-y-self.a.size.y)end
end
function Node:get_locked_size()
  if self.type=='leaf'then
    if self.locked then local fn=adapter(self).locked_size;if fn then return fn(self.active_view)end;return 0,0 end
  else
    local x1,y1=self.a:get_locked_size();local x2,y2=self.b:get_locked_size()
    if x1 and x2 then
      if self.type=='hsplit'then return x1+x2+((x1<1 or x2<1)and 0 or divider(self)),math.max(y1,y2)end
      return math.max(x1,x2),y1+y2+((y1<1 or y2<1)and 0 or divider(self))
    end
  end
end
local function split_sizes(self,axis,cross,first,second)
  local total=math.max(0,self.size[axis]);local span=math.max(0,self.size[cross])
  local gap=(first and first<1 or second and second<1)and 0 or math.min(total,math.max(0,divider(self)))
  local n=first and first+gap or second and total-second or math.floor(total*self.divider)
  n=math.max(gap,math.min(total,n))
  self.a.position[axis],self.a.position[cross]=self.position[axis],self.position[cross]
  self.a.size[axis],self.a.size[cross]=n-gap,span
  self.b.position[axis],self.b.position[cross]=self.position[axis]+n,self.position[cross]
  self.b.size[axis],self.b.size[cross]=total-n,span
end
function Node:update_layout()
  if self.type=='leaf'then local fn=adapter(self).arrange_leaf;if fn then fn(self)end;return end
  local x1,y1=self.a:get_locked_size();local x2,y2=self.b:get_locked_size()
  if self.type=='hsplit'then split_sizes(self,'x','y',x1,x2)else split_sizes(self,'y','x',y1,y2)end
  self.a:update_layout();self.b:update_layout()
end
return M
