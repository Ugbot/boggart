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
  sel = nil,      -- index of the keyboard-highlighted row
  scroll = 0,     -- first drawn row, when the list is taller than the space
}

-- An item is one of:
--   { label =, action = | command = }   a row you can pick
--   { heading = "xAI" }                 a non-selectable section label
--   { label =, checked = true }         the current value, marked
--
-- Headings exist because a model list is long and unordered without them: with
-- a dozen providers you are hunting, and grouping is the difference between a
-- list and a menu.
local function selectable(it) return it and not it.heading end

function menu.show(anchor, items)
  menu.anchor = anchor
  menu.items = items or {}
  menu.hits = {}
  menu.scroll = 0
  -- Open on the current value when there is one, so the highlighted row is the
  -- answer to "what am I on?" before you have moved anything.
  menu.sel = nil
  for i, it in ipairs(menu.items) do
    if it.checked and selectable(it) then menu.sel = i; break end
  end
  if not menu.sel then
    for i, it in ipairs(menu.items) do
      if selectable(it) then menu.sel = i; break end
    end
  end
  menu.open = #menu.items > 0 and anchor ~= nil
  core.redraw = true
end

-- Move the highlight to the next selectable row, skipping headings, stopping at
-- the ends rather than wrapping (a wrap in a long list loses your place).
function menu.move(dir)
  if not menu.open then return end
  local i = menu.sel or 0
  for _ = 1, #menu.items do
    i = i + dir
    if i < 1 or i > #menu.items then return end
    if selectable(menu.items[i]) then menu.sel = i; core.redraw = true; return end
  end
end

function menu.activate()
  local it = menu.sel and menu.items[menu.sel]
  if not selectable(it) then return false end
  menu.hide()
  if it.action then it.action()
  elseif it.command then require("core.command").perform(it.command) end
  return true
end

function menu.hide()
  if not menu.open then return end
  menu.open = false
  menu.items = {}
  menu.hits = {}
  menu.sel, menu.scroll = nil, 0
  core.redraw = true
end

function menu.draw()
  if not menu.open or not menu.anchor then return end
  menu.hits = {}
  local font = style.font
  local bh = widgets.height(font)
  local pad = style.padding.x
  local mark = "\u{2713} "          -- the current value's tick
  local width = 0
  for _, it in ipairs(menu.items) do
    width = math.max(width, widgets.width(font, (it.heading or it.label or "") .. mark))
  end
  width = math.max(width + pad, menu.anchor.w or 0)

  local win_w, win_h = renderer.get_size()
  -- How many rows fit above (preferred) or below the anchor. A dropdown that
  -- runs off the screen is worse than one that scrolls, and a model list can be
  -- long, so the height is clamped to what there is room for.
  local above = menu.anchor.y - 8
  local below = win_h - (menu.anchor.y + (menu.anchor.h or bh)) - 8
  local space = math.max(above, below)
  local rows = math.max(1, math.min(#menu.items, math.floor((space - pad) / bh)))
  menu.rows = rows

  -- keep the highlighted row in view
  if menu.sel then
    if menu.sel <= menu.scroll then menu.scroll = menu.sel - 1
    elseif menu.sel > menu.scroll + rows then menu.scroll = menu.sel - rows end
  end
  menu.scroll = math.max(0, math.min(menu.scroll, math.max(0, #menu.items - rows)))

  local h = rows * bh + pad
  local x = menu.anchor.x
  if x + width > win_w then x = math.max(0, win_w - width) end
  local y = (above >= h) and (menu.anchor.y - h - 4)
    or (menu.anchor.y + (menu.anchor.h or bh) + 4)
  if y + h > win_h then y = math.max(0, win_h - h) end

  renderer.draw_rect(x - 1, y - 1, width + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, width, h, style.background2)
  local iy = y + pad / 2
  for i = menu.scroll + 1, math.min(#menu.items, menu.scroll + rows) do
    local it = menu.items[i]
    local r = { x = x, y = iy, w = width, h = bh }
    if it.heading then
      common.draw_text(font, style.dim, it.heading, "left", x + pad / 2, iy, width, bh)
    else
      local hov = (menu.mouse and widgets.inside(r, menu.mouse.x, menu.mouse.y))
        or (menu.sel == i)
      if hov then renderer.draw_rect(x, iy, width, bh, style.line_highlight) end
      common.draw_text(font, it.checked and style.accent or style.text,
        (it.checked and mark or "") .. (it.label or ""), "left",
        x + pad / 2, iy, width, bh)
      r.item = it
      menu.hits[#menu.hits + 1] = r
    end
    iy = iy + bh
  end
  -- Say that there is more, rather than silently truncating.
  if #menu.items > rows then
    local hidden = #menu.items - rows - menu.scroll
    if hidden > 0 then
      common.draw_text(font, style.dim, "  " .. hidden .. " more \u{2193}", "left",
        x + pad / 2, y + h - bh, width, bh)
    end
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

  -- The wheel scrolls the list rather than the view underneath it.
  local omw = RootView.on_mouse_wheel
  function RootView:on_mouse_wheel(y, ...)
    if menu.open then
      menu.scroll = math.max(0, menu.scroll - (y > 0 and 1 or -1))
      core.redraw = true
      return
    end
    return omw(self, y, ...)
  end

  -- Keyboard. A dropdown you can only use with the mouse is half a control,
  -- and this one opens from a keyboard-reachable button.
  local keymap = require "core.keymap"
  local okp = keymap.on_key_pressed
  function keymap.on_key_pressed(k, ...)
    if menu.open then
      if k == "up" then menu.move(-1); return true end
      if k == "down" then menu.move(1); return true end
      if k == "return" or k == "keypad enter" then return menu.activate() end
      if k == "escape" then menu.hide(); return true end
    end
    return okp(k, ...)
  end
end

return menu
