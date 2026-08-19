-- railview.lua -- the far-left activity bar.
--
-- One icon, one destination. Settings, workflows and welcome sit on the bar
-- like everything else; there is no More popover. Width is fixed -- a rail
-- the user can drag into a second sidebar is no longer a rail.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

config.rail_size = 44 * SCALE

local ITEMS = {
  { id = "agent",     glyph = "C", font = "font",      label = "Chat",      caption = "Chat" },
  { id = "edit",      glyph = "f", font = "icon_font", label = "Files",     caption = "Files" },
  { id = "fleet",     glyph = "S", font = "font",      label = "Fleet",     caption = "Fleet" },
  { id = "library",   glyph = "L", font = "font",      label = "Library",   caption = "Lib" },
  { id = "settings",  glyph = "s", font = "font",      label = "Settings",  caption = "Set" },
  { id = "workflows", glyph = "W", font = "font",      label = "Workflows", caption = "Flow" },
  { id = "welcome",   glyph = "?", font = "font",      label = "Welcome",   caption = "Hi" },
}

local RailView = View:extend()

function RailView:new()
  RailView.super.new(self)
  self.visible = true
  self.init_size = true
  self.hits = {}
  self.active = "agent"
  self.mouse = nil
end

function RailView:get_name() return "Rail" end

function RailView:set_target_size(axis, value)
  return false
end

function RailView:get_target_size(axis)
  if axis ~= "x" then return nil end
  return self.visible and config.rail_size or 0
end

function RailView:update()
  local dest = self:get_target_size("x")
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self.size.x = dest
  end
  RailView.super.update(self)
end

function RailView:active_id()
  local studio = core.studio
  local ws = studio and studio.workspace
  if ws == "settings" or ws == "workflows" or ws == "welcome"
      or ws == "fleet" or ws == "library" then
    return ws
  end
  local mode = package.loaded["core.workspaces"]
      and require("core.workspaces").layout
  if mode == "files" then return "edit" end
  return "agent"
end

local function item_font(spec)
  if spec.font == "icon_font" then return style.icon_font end
  return style.font
end

function RailView:draw()
  self:draw_background(style.background2)
  self.hits = {}
  if self.size.x < 8 then return end

  local w = self.size.x
  local cap_h = style.font:get_height()
  local cell = math.max(w, 36 * SCALE) + cap_h
  local y = self.position.y + style.padding.y
  local active = self:active_id()

  for _, it in ipairs(ITEMS) do
    local r = { x = self.position.x, y = y, w = w, h = cell }
    local hov = self.mouse and widgets.inside(r, self.mouse.x, self.mouse.y)
    if it.id == active or hov then
      renderer.draw_rect(r.x + 2, r.y + 2, r.w - 4, r.h - 4,
        it.id == active and style.selection or style.line_highlight)
    end
    if it.id == active then
      renderer.draw_rect(r.x, r.y + 6, math.max(2, SCALE), r.h - 12, style.accent)
    end
    local font = item_font(it)
    local color = it.id == active and style.accent or style.dim
    common.draw_text(font, color, it.glyph, "center", r.x, r.y, r.w, r.h - cap_h)
    common.draw_text(style.font, color, it.caption or it.label, "center",
      r.x, r.y + r.h - cap_h - 2, r.w, cap_h)
    r.item = { id = it.id, label = it.label, dest = it.id }
    self.hits[#self.hits + 1] = r
    y = y + cell
  end
end

function RailView:on_mouse_moved(x, y, dx, dy)
  RailView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  core.redraw = true
end

function RailView:select(id)
  self.active = id
  local studio = require "core.studio"
  if studio.switch_workspace then studio.switch_workspace(id) end
end

function RailView:on_mouse_pressed(button, x, y, clicks)
  if RailView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local item = widgets.hit(self.hits, x, y)
  if item and item.id then self:select(item.id); return true end
  return true
end

return RailView
