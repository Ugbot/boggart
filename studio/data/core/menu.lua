-- menu.lua -- one anchored overlay, drawn after the node tree.
--
-- Permission mode (and anything else that used to raise the command bar from
-- a composer pill) pops from the button that opened it. RootView sees every
-- press first so a click on the menu does not fall through to the view under
-- it. There is no widget tree: a list of items, an opener rect, defer_draw.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local widgets = require "core.widgets"

local menu = {
  open = false,
  items = {},
  hits = {},
  anchor = nil,
  mouse = nil,
}

function menu.show(anchor, items)
  menu.anchor = anchor
  menu.items = items or {}
  menu.hits = {}
  menu.open = #menu.items > 0 and anchor ~= nil
  core.redraw = true
end

function menu.hide()
  if not menu.open then return end
  menu.open = false
  menu.items = {}
  menu.hits = {}
  core.redraw = true
end

function menu.draw()
  if not menu.open or not menu.anchor then return end
  menu.hits = {}
  local font = style.font
  local bh = widgets.height(font)
  local pad = style.padding.x
  local width = 0
  for _, it in ipairs(menu.items) do
    width = math.max(width, widgets.width(font, it.label or ""))
  end
  width = math.max(width + pad, menu.anchor.w or 0)
  local h = #menu.items * bh + pad
  local win_w, win_h = renderer.get_size()
  local x = menu.anchor.x
  if x + width > win_w then x = math.max(0, win_w - width) end
  local y = menu.anchor.y - h - 4
  if y < 0 then y = menu.anchor.y + (menu.anchor.h or bh) + 4 end
  if y + h > win_h then y = math.max(0, win_h - h) end

  renderer.draw_rect(x - 1, y - 1, width + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, width, h, style.background2)
  local iy = y + pad / 2
  for _, it in ipairs(menu.items) do
    local r = { x = x, y = iy, w = width, h = bh }
    local hov = menu.mouse and widgets.inside(r, menu.mouse.x, menu.mouse.y)
    if hov then renderer.draw_rect(x, iy, width, bh, style.line_highlight) end
    common.draw_text(font, style.text, it.label or "", "left",
      x + pad / 2, iy, width, bh)
    r.item = it
    menu.hits[#menu.hits + 1] = r
    iy = iy + bh
  end
end

function menu.handle_press(x, y)
  if not menu.open then return false end
  local item = widgets.hit(menu.hits, x, y)
  menu.hide()
  if item then
    if item.action then item.action()
    elseif item.command then
      require("core.command").perform(item.command)
    end
    return true
  end
  if menu.anchor and widgets.inside(menu.anchor, x, y) then
    return true
  end
  return true -- dismiss; swallow so the click is "close the menu"
end

function menu.install()
  if menu._installed then return end
  menu._installed = true
  local RootView = require "core.rootview"
  local omp = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if menu.open then
      menu.mouse = { x = x, y = y }
      if menu.handle_press(x, y) then return end
    end
    return omp(self, button, x, y, clicks)
  end
  local omm = RootView.on_mouse_moved
  function RootView:on_mouse_moved(x, y, dx, dy)
    if menu.open then
      menu.mouse = { x = x, y = y }
      core.redraw = true
    end
    return omm(self, x, y, dx, dy)
  end
  local od = RootView.draw
  function RootView:draw()
    od(self)
    if menu.open then menu.draw() end
  end
end

return menu
