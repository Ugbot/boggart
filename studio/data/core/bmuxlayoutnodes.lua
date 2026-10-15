-- RootView presentation over a server-owned tree; local nodes keep their class.
local Tree=require 'bmux.tree'
local M={}
function M.new(Base)
  local Class=Tree.class(Base._adapter);getmetatable(Class).__index=Base
  Class.local_class=Base
  local function route(name,fn)
    Class[name]=function(node,...)
      if node.bmux_owner then return fn(node.bmux_owner,node,...) end
      return Base[name](node,...)
    end
  end
  route('set_active_view',function(owner,node,view)return owner:focus(node,view)end)
  route('add_view',function(owner,_,view)return owner:local_view(view)end)
  route('split',function(owner,node,dir,view,locked)
    if locked then return Base.split(node,dir,view,locked) end
    if view then return owner:local_view(view,dir) end
    return owner:command('pane_split',{pane_id=node.remote_id,direction=dir})
  end)
  route('close_view',function(owner,node,view)
    if not view then return false end
    return owner:command('view_close',{pane_id=node.remote_id,view_id=view.bmux_view_id})
  end)
  route('move_view',function(owner,node,view,target,_,index)
    if target.bmux_owner~=owner or not view.bmux_view_id then return false end
    return owner:command('view_move',{pane_id=node.remote_id,view_id=view.bmux_view_id,target_pane_id=target.remote_id,index=index})
  end)
  route('swap_views',function(owner,node,target)
    if target.bmux_owner~=owner then return false end
    return owner:command('pane_swap',{pane_id=node.remote_id,target_pane_id=target.remote_id})
  end)
  route('toggle_zoom',function(owner)return owner:command('pane_zoom',{pane_id=owner:focused_pane()})end)
  route('balance',function(owner)return owner:command('balance',{})end)
  route('set_divider',function(owner,node,value)return owner:resize(node,value)end)
  route('resize_by',function(owner,node,dx,dy)
    if node.type=='leaf'then return false end
    local axis=node.type=='hsplit' and 'x' or 'y'
    if node.size[axis]<=0 then return false end
    local previous=owner.resize_target and owner.resize_target.node==node and owner.resize_target.ratio or node.divider
    return owner:resize(node,previous+(axis=='x' and dx or dy)/node.size[axis])
  end)
  return Class
end
return M
