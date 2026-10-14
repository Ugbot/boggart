local View = require "core.view"
local style = require "core.style"
local widgets = require "core.widgets"
local command = require "core.command"
local Toolbar = View:extend()

local items = {
  { label = "+ New terminal", command = "bmux:new-terminal" },
  { label = "+ New agent", command = "bmux:new-agent" },
  { label = "Split right", command = "bmux:split-right" },
  { label = "Split down", command = "bmux:split-down" },
  { label = "Close", command = "bmux:close-terminal" },
  { label = "Zoom", command = "bmux:zoom" },
  { label = "Next pane", command = "bmux:next-pane" },
}

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
  for _, item in ipairs(items) do
    local w = widgets.width(font, item.label)
    if used > 0 and used + w > width then rows, used = rows + 1, 0 end
    used = used + w + gap
  end
  return rows * widgets.height(font) + (rows - 1) * gap + style.padding.y * 2
end

function Toolbar:update()
  self.workspace.remember_focus()
  self.size.y = self:get_target_size("y")
  Toolbar.super.update(self)
end

function Toolbar:draw()
  if not self.visible then return end
  self:draw_background(style.background)
  self.hits = widgets.wrap_row(style.font, items,
    self.position.x + style.padding.x, self.position.y + style.padding.y,
    self.mouse, self.position.x + self.size.x - style.padding.x)
end

function Toolbar:on_mouse_moved(x, y)
  self.mouse = { x = x, y = y }
  require("core").redraw = true
end

function Toolbar:on_mouse_pressed(button, x, y)
  if button ~= "left" then return end
  local item = widgets.hit(self.hits, x, y)
  if item then command.perform(item.command); return true end
end

return Toolbar
