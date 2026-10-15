-- Opaque action keys keep focus independent of row position and redraw objects.
local M={};local Focus={};Focus.__index=Focus
function M.new()return setmetatable({},Focus)end
function Focus:clear()self.key=nil end
function Focus:current(items)
  if self.key then
    for _,item in ipairs(items)do if item.key==self.key and not item.disabled then return item end end
    self:clear()
  end
end
function Focus:move(items,delta)
  local enabled={}
  for _,item in ipairs(items)do if item.key and not item.disabled then enabled[#enabled+1]=item end end
  local current=self:current(enabled);if #enabled==0 then return end
  local index=delta>0 and 0 or 1
  for i,item in ipairs(enabled)do if item==current then index=i;break end end
  local item=enabled[(index-1+delta)%#enabled+1];self.key=item.key;return item
end
return M
