-- shell/menubar.lua -- the in-app menu bar with REAL dropdown panels. The bar is
-- a locked top dock; the open dropdown is drawn as an overlay (on top of the
-- content, not pushing it) and its input is handled through a RootView wrap
-- installed by shell.install_menu_overlay(). Titles open/switch on click;
-- clicking a row runs it; clicking anywhere else closes.
local core = require "core"
local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"
local registry = require "shell.registry"

local MenuBar = View:extend()

MenuBar.menus = {
  "boggart", "File", "Edit", "Selection", "View", "Go",
  "Agent", "Run", "Fleet", "Service", "Tools", "Help",
}

local GAP = 10  -- px around each title
local WS_SEP = "  \u{00b7}  "  -- the "  ·  " divider drawn between workspace tabs

function MenuBar:new()
  MenuBar.super.new(self)
  self.hovered = nil
  self.open = nil       -- open menu name
  self.hover_row = nil  -- hovered row index in the open menu
end

function MenuBar:update()
  self.size.y = style.font:get_height() + style.padding.y
  MenuBar.super.update(self)
end

function MenuBar:items()
  local font = style.font
  local x = self.position.x + style.padding.x
  local out = {}
  for _, name in ipairs(MenuBar.menus) do
    local w = font:get_width(name)
    out[#out + 1] = { name = name, x = x, w = w }
    x = x + w + GAP * 2
  end
  return out
end

local function title_hit(it, px) return px >= it.x - GAP and px < it.x + it.w + GAP end

-- The title the pointer is over (or nil).
function MenuBar:title_at(px, py)
  if py < self.position.y or py >= self.position.y + self.size.y then return nil end
  for _, it in ipairs(self:items()) do
    if title_hit(it, px) then return it.name, it.x end
  end
  return nil
end

-- ---- workspace tabs (right side of the bar) --------------------------------
-- The three workspaces (AGENT / EDIT / FLEET) as tab-like segments, laid out
-- right-aligned so the current one reads as the active view. Same shape as
-- items() so draw and hit-testing share one geometry.
function MenuBar:workspace_items()
  local font = style.font
  local order = require("shell").workspaces or {}
  local sepw = font:get_width(WS_SEP)
  local total = 0
  for i, name in ipairs(order) do
    total = total + font:get_width(name:upper())
    if i < #order then total = total + sepw end
  end
  local x = self.position.x + self.size.x - style.padding.x - total
  local out = {}
  for i, name in ipairs(order) do
    local label = name:upper()
    local w = font:get_width(label)
    out[#out + 1] = { name = name, label = label, x = x, w = w }
    x = x + w + (i < #order and sepw or 0)
  end
  return out
end

-- The workspace tab the pointer is over (or nil).
function MenuBar:workspace_at(px, py)
  if py < self.position.y or py >= self.position.y + self.size.y then return nil end
  for _, it in ipairs(self:workspace_items()) do
    if px >= it.x and px < it.x + it.w then return it.name end
  end
  return nil
end

-- ---- dropdown geometry -----------------------------------------------------
local ROW_PAD = 6
local MIN_W = 220

function MenuBar:dropdown_rect()
  if not self.open then return nil end
  local rows = registry.tree[self.open] or {}
  local font = style.font
  local rowh = font:get_height() + ROW_PAD * 2
  -- width: widest label + key hint
  local w = MIN_W
  for _, r in ipairs(rows) do
    if not r.sep then
      local key = keymap.get_binding(r[2]) or ""
      w = math.max(w, font:get_width(r[1]) + font:get_width(key) + 60)
    end
  end
  local anchor = self._open_x or (self.position.x + style.padding.x)
  local x = math.min(anchor, self.position.x + self.size.x - w - 4)
  local y = self.position.y + self.size.y
  local h = ROW_PAD
  for _, r in ipairs(rows) do h = h + (r.sep and 9 or rowh) end
  h = h + ROW_PAD
  return x, y, w, h, rows, rowh
end

-- Row index under (px,py), or nil.
function MenuBar:row_at(px, py)
  local x, y, w, h, rows, rowh = self:dropdown_rect()
  if not x or px < x or px >= x + w or py < y or py >= y + h then return nil end
  local cy = y + ROW_PAD
  for i, r in ipairs(rows) do
    local rh = r.sep and 9 or rowh
    if not r.sep and py >= cy and py < cy + rh then return i end
    cy = cy + rh
  end
  return nil
end

-- Handle a global mouse press while a menu is (or isn't) open. Returns true if
-- consumed.
function MenuBar:handle_press(px, py)
  local title = self:title_at(px, py)
  if title then
    if self.open == title then self.open = nil
    else self.open = title; self._open_x = select(2, self:title_at(px, py)) end
    core.redraw = true
    return true
  end
  -- A workspace tab switches to that workspace (and closes any open menu).
  local ws = self:workspace_at(px, py)
  if ws then
    self.open = nil
    require("shell").switch(ws)
    core.redraw = true
    return true
  end
  if self.open then
    local i = self:row_at(px, py)
    if i then
      local r = (registry.tree[self.open] or {})[i]
      self.open = nil
      core.redraw = true
      if r and r[2] then require("core.command").perform(r[2]) end
      return true
    end
    -- clicked outside an open menu: close it (and swallow the click)
    self.open = nil
    core.redraw = true
    return true
  end
  return false
end

function MenuBar:handle_move(px, py)
  local was = self.hovered
  self.hovered = self:title_at(px, py)
  -- classic behaviour: with a menu open, hovering another title switches to it
  if self.open and self.hovered and self.hovered ~= self.open then
    self.open = self.hovered
    self._open_x = select(2, self:title_at(px, py))
  end
  self.hover_row = self.open and self:row_at(px, py) or nil
  if self.hovered ~= was then core.redraw = true end
end

-- ---- keyboard navigation (wired from modal.intercept while a menu is open) --
function MenuBar:close()
  self.open, self.hover_row = nil, nil
  core.redraw = true
end

-- Open a menu by name from the keyboard (Alt/F10 or leader), landing on its first
-- selectable row and anchoring the panel under the title.
function MenuBar:open_menu(name)
  for _, it in ipairs(self:items()) do
    if it.name == name then self.open, self._open_x = name, it.x break end
  end
  if not self.open then self.open, self._open_x = name, self.position.x + style.padding.x end
  self.hover_row = nil
  self:move_hover(1)
  core.redraw = true
end

-- Step the highlight to the next/prev selectable (non-separator) row, wrapping.
function MenuBar:move_hover(dir)
  local rows = registry.tree[self.open] or {}
  if #rows == 0 then return end
  local i = self.hover_row or (dir > 0 and 0 or #rows + 1)
  for _ = 1, #rows do
    i = ((i - 1 + dir) % #rows) + 1
    if not rows[i].sep then self.hover_row = i; core.redraw = true; return end
  end
end

-- Step to the next/prev menu title, keeping a menu open (Left/Right in a dropdown).
function MenuBar:cycle_title(dir)
  local names = MenuBar.menus
  local i = 1
  for j, n in ipairs(names) do if n == self.open then i = j end end
  self:open_menu(names[((i - 1 + dir) % #names) + 1])
end

function MenuBar:activate_hover()
  local rows = registry.tree[self.open] or {}
  local r = self.hover_row and rows[self.hover_row]
  self:close()
  if r and r[2] then require("core.command").perform(r[2]) end
end

-- ---- drawing ---------------------------------------------------------------
function MenuBar:draw()
  self:draw_background(style.background2)
  local font = style.font
  local y = self.position.y + (self.size.y - font:get_height()) / 2
  for _, it in ipairs(self:items()) do
    local on = (it.name == self.hovered) or (it.name == self.open)
    local color = (on or it.name == "boggart") and style.accent or style.text
    renderer.draw_text(font, it.name, it.x, y, color)
  end
  -- Right-aligned workspace tabs (clickable via handle_press): the current one
  -- accented, the rest dim, with a dim divider between.
  local wsitems = self:workspace_items()
  local cur = require("shell").current
  for i, it in ipairs(wsitems) do
    renderer.draw_text(font, it.label, it.x, y, it.name == cur and style.accent or style.dim)
    if i < #wsitems then renderer.draw_text(font, WS_SEP, it.x + it.w, y, style.dim) end
  end
  renderer.draw_rect(self.position.x, self.position.y + self.size.y - 1,
    self.size.x, 1, style.divider)
end

-- Drawn as an overlay by the RootView wrap (after content), so it's on top.
function MenuBar:draw_dropdown()
  local x, y, w, h, rows, rowh = self:dropdown_rect()
  if not x then return end
  local font = style.font
  renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, w, h, style.background)
  local cy = y + ROW_PAD
  for i, r in ipairs(rows) do
    if r.sep then
      renderer.draw_rect(x + 8, cy + 4, w - 16, 1, style.divider)
      cy = cy + 9
    else
      if i == self.hover_row then
        renderer.draw_rect(x, cy, w, rowh, style.line_highlight)
      end
      local ty = cy + ROW_PAD
      renderer.draw_text(font, r[1], x + 12, ty, style.text)
      local key = keymap.get_binding(r[2])
      if key then
        renderer.draw_text(font, key, x + w - font:get_width(key) - 12, ty, style.dim)
      end
      cy = cy + rowh
    end
  end
end

return MenuBar
