local View = require "core.view"
local style = require "core.style"
local widgets = require "core.widgets"
local command = require "core.command"
local Toolbar = View:extend()

local items = {
  { label = "+ New terminal", command = "bmux:new-terminal" },
  { label = "+ New agent", command = "bmux:new-agent" },
  { label = "Attach", command = "terminal:attach" },
  { label = "Join layout", command = "bmux:join-layout" },
  { label = "Split right", command = "bmux:split-right" },
  { label = "Split down", command = "bmux:split-down" },
  { label = "Close", command = "bmux:close-terminal" },
  { label = "Zoom", command = "bmux:zoom" },
  { label = "Next pane", command = "bmux:next-pane" },
}
function Toolbar:items()
  local out={};local session=self.workspace.session
  for _,item in ipairs(items)do
    local copy={label=item.label,command=item.command}
    out[#out+1]=copy
  end
  if session then
    out[#out+1]={label='+ Local agent',command='bmux:new-local-agent'}
    out[#out+1]={label='Workspaces',command='bmux:server-workspaces'}
    out[#out+1]={label='Surfaces',command='bmux:server-surfaces'}
    out[#out+1]={label='Sessions',command='bmux:sessions'}
    out[#out+1]={label='Refresh / reconnect',command='bmux:refresh-layout'}
    out[#out+1]={label='Disconnect layout',command='bmux:disconnect-layout'}
  elseif self.workspace.local_status then
    out[#out+1]={label='Retry project server',command='bmux:retry-local'}
  end
  return out
end

function Toolbar:new(workspace)
  Toolbar.super.new(self)
  self.workspace, self.visible = workspace, true
  self.hits = {}
end

function Toolbar:get_target_size(axis)
  if axis ~= "y" then return nil end
  if not self.visible then return 0 end
  local font, gap = style.font, style.padding.x * widgets.GAP
  local width = math.max(1, self.size.x - style.padding.x * 2)
  local rows, used = 1, 0
  for _, item in ipairs(self:items()) do
    local w = widgets.width(font, item.label)
    if used > 0 and used + w > width then rows, used = rows + 1, 0 end
    used = used + w + gap
  end
  return rows * widgets.height(font) + (rows - 1) * gap + style.padding.y * 2
    + ((self.workspace.session or self.workspace.local_status) and font:get_height()+style.padding.y or 0)
end

function Toolbar:update()
  self.workspace.remember_focus()
  self.size.y = self:get_target_size("y")
  Toolbar.super.update(self)
end

function Toolbar:draw()
  if not self.visible then return end
  self:draw_background(style.background)
  local bottom
  self.hits,bottom = widgets.wrap_row(style.font, self:items(),
    self.position.x + style.padding.x, self.position.y + style.padding.y,
    self.mouse, self.position.x + self.size.x - style.padding.x)
  local session=self.workspace.session
  if session then
    local w,s=session.applied_workspace,session.applied_surface
    local text='Server layout · '..(w and w.title or 'No workspace')..' / '..(s and s.title or '')..' · '..session.client.status
    if session.session_actions then text=text..' · '..(session.session_actions.busy and 'Session transfer working…'or session.session_actions:summary())end
    require('core.common').draw_text(style.font,style.dim,text,'left',self.position.x+style.padding.x,bottom+style.padding.y,
      self.size.x-style.padding.x*2,style.font:get_height())
  elseif self.workspace.local_status then
    require('core.common').draw_text(style.font,style.dim,'Local project server · '..self.workspace.local_status,'left',
      self.position.x+style.padding.x,bottom+style.padding.y,self.size.x-style.padding.x*2,style.font:get_height())
  end
end

function Toolbar:on_mouse_moved(x, y)
  self.mouse = { x = x, y = y }
  require("core").redraw = true
end

function Toolbar:on_mouse_pressed(button, x, y)
  if button ~= "left" then return end
  local item = widgets.hit(self.hits, x, y)
  if item then self.workspace.remember_focus();command.perform(item.command); return true end
end

return Toolbar
