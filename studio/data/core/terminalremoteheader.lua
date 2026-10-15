-- Discoverable controller actions, separate from the terminal body geometry.
local style=require 'core.style';local widgets=require 'core.widgets';local common=require 'core.common'
local Header={};Header.__index=Header
function Header.new(remote)return setmetatable({remote=remote,hits={}},Header)end
function Header:items()
  local r=self.remote;local status=r:status();local items={}
  local function add(label,method,arg)items[#items+1]={label=label,method=method,arg=arg,dim=r.busy}end
  if status=='uncertain'then add('Retry pending command','retry')
  elseif status=='controlling'then add('View only','view_only')
  elseif status=='read-only'then add(r.conflict and 'Take over' or 'Take control','control',r.conflict==true)end
  if r.session and r.session.status=='disconnected' or status=='closed'then add('Reconnect','reconnect')end
  return items
end
function Header:layout(x,y,width)
  local top=y+style.padding.y;local text_height=style.font:get_height()
  local items=self:items();local bottom=top+text_height
  local hits={}
  if #items>0 then hits,bottom=widgets.wrap_layout(style.font,items,x+style.padding.x,bottom+style.padding.y,x+width-style.padding.x)end
  -- Keep the error line reserved: a resize refusal must not resize the body
  -- again merely because its message appeared/disappeared.
  bottom=bottom+text_height+style.padding.y
  return bottom-y+style.padding.y,hits
end
function Header:height(width)return self:layout(0,0,width)end
function Header:draw(x,y,width)
  local height=self:height(width);local r=self.remote
  renderer.draw_rect(x,y,width,height,style.background)
  renderer.draw_rect(x,y+height-1,width,1,style.divider)
  common.draw_text(style.font,style.dim,'Attached  |  '..r:status()..'  |  '..r.id,'left',x+style.padding.x,y+style.padding.y,width-style.padding.x*2,style.font:get_height())
  self.hits=widgets.wrap_row(style.font,self:items(),x+style.padding.x,y+style.padding.y*2+style.font:get_height(),self.mouse,x+width-style.padding.x)
  if r.error then
    common.draw_text(style.font,style.error,r.error.message,'left',x+style.padding.x,y+height-style.padding.y-style.font:get_height(),width-style.padding.x*2,style.font:get_height())
  end
  return height
end
function Header:pressed(button,x,y)
  if button~='left'then return false end
  local item=widgets.hit(self.hits,x,y)
  if not item then return false end
  if not item.dim then self.remote[item.method](self.remote,item.arg)end
  return true
end
return Header
