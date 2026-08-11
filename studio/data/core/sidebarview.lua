-- sidebarview.lua -- the left rail: chats, not files.
--
-- This is the structural decision the app turns on. The editor core this grew
-- out of puts a file tree here, because its subject is a directory. boggart's
-- subject is a conversation, so the rail lists conversations, and the file
-- tree moves behind the Code tab -- present, one click away, and no longer the
-- thing the window is about.
--
-- Shaped after Claude's desktop app: a segmented Chat/Code control at the top,
-- a New button, then Recents. The flat rectangles are not an aesthetic
-- preference -- this renderer draws rectangles and text, and nothing else. No
-- rounded corners, no shadows, no icons beyond what a font provides.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

config.sidebar_size = 210 * SCALE
config.sidebar_min  = 120 * SCALE

local SidebarView = View:extend()

function SidebarView:new()
  SidebarView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.tab = "chat"           -- "chat" | "code"
  self.sessions = {}
  self.hits = {}
  self.last_refresh = 0
end

function SidebarView:get_name() return "Sidebar" end

-- A rail wider than a third of the window is no longer a rail, and below the
-- minimum the labels are unreadable. One function owns both ends so the drag,
-- the animation and the frame-by-frame ceiling cannot disagree about them.
function SidebarView:allowed_size(value)
  local max = math.max(config.sidebar_min, core.root_view.size.x / 3)
  return common.clamp(value, config.sidebar_min, max)
end

-- Dragging the edge. Dragging a collapsed sidebar back open is deliberate --
-- if you can grab the edge at all, pulling it should work.
function SidebarView:set_target_size(axis, value)
  if axis ~= "x" then return false end
  config.sidebar_size = self:allowed_size(value)
  self.visible = true
  self.init_size = true       -- take the new width immediately, do not glide
  return true
end

-- Where the rail is heading, which is not where it is during a collapse or an
-- expand. RootView drags against this so that grabbing the edge mid-animation
-- adjusts the width you asked for rather than the width you happen to see.
function SidebarView:get_target_size(axis)
  if axis ~= "x" then return nil end
  return self.visible and self:allowed_size(config.sidebar_size) or 0
end

function SidebarView:toggle()
  self.visible = not self.visible
  core.redraw = true
  return self.visible
end

-- Recents. Re-read on a timer rather than on every frame: it is a SQLite
-- query, and the list changes when a session is created or renamed, which is
-- not sixty times a second.
function SidebarView:refresh(force)
  local now = os.time()
  if not force and now - self.last_refresh < 3 then return end
  self.last_refresh = now
  local ok, rows = pcall(bog.store.sess_list, 40)
  self.sessions = (ok and rows) or {}
end

function SidebarView:update()
  -- The same ceiling the drag honours, applied every frame. Only the drag
  -- enforced it, so a window made narrow after the fact kept the width it was
  -- dragged to: at 840px the rail took 420 of them and the conversation -- the
  -- thing this application is -- got the other half.
  local dest = self:get_target_size("x")
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end
  self:refresh()

  -- The segmented control follows what is actually on screen. Opening a file
  -- from the tree, from ctrl+p or from a tool all put you in code; the control
  -- would otherwise still claim you were in the chat.
  local active = core.active_view
  if active then
    if active.doc then self.tab = "code"
    elseif active == (core.studio and core.studio.view) then self.tab = "chat" end
  end

  SidebarView.super.update(self)
end

function SidebarView:set_tab(tab)
  if self.tab == tab then return end
  self.tab = tab
  local studio = require "core.studio"
  studio.show_surface(tab)
  core.redraw = true
end

function SidebarView:on_mouse_moved(x, y, dx, dy)
  SidebarView.super.on_mouse_moved(self, x, y, dx, dy)
  local was = self.hover
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  self.hover = item and (item.label or item.id) or nil
  if self.hover ~= was then core.redraw = true end
  self.cursor = item and "arrow" or "arrow"
end

function SidebarView:on_mouse_pressed(button, x, y, clicks)
  if SidebarView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local item = widgets.hit(self.hits, x, y)
  if item and item.action then item.action(); return true end
  return true
end

function SidebarView:draw()
  self:draw_background(style.background2)
  if self.size.x < 20 then return end

  local font = style.font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x * 0.6
  local vpad = style.padding.y
  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  local y = self.position.y + vpad - self.scroll.y
  self.hits = {}

  local function add(hit, item) hit.item = item; self.hits[#self.hits + 1] = hit end

  -- ---- Chat / Code --------------------------------------------------------
  local bh = widgets.height(font)
  local halfw = (w - style.padding.x * widgets.GAP) / 2
  for i, tab in ipairs { { "chat", "Chat" }, { "code", "Code" } } do
    local bx = x + (i - 1) * (halfw + style.padding.x * widgets.GAP)
    local hovered = self.mouse and widgets.inside(
      { x = bx, y = y, w = halfw, h = bh }, self.mouse.x, self.mouse.y)
    local r = widgets.button(font, tab[2], bx, y,
      { w = halfw, active = self.tab == tab[1], hover = hovered })
    add(r, { label = tab[2], action = function() self:set_tab(tab[1]) end })
  end
  y = y + bh + vpad

  if self.tab == "code" then
    local hov = self.mouse and widgets.inside(
      { x = x, y = y, w = w, h = bh }, self.mouse.x, self.mouse.y)
    add(widgets.button(font, "Open a file...", x, y,
          { w = w, hover = hov, align = "left" }),
        { label = "open", action = function() command.perform("core:find-file") end })
    y = y + bh + vpad
    common.draw_text(font, style.dim, "The tree is on the right.",
      "left", x + pad / 2, y, w, lh)
    self.content_height = (y + lh + self.scroll.y) - self.position.y
    self:draw_scrollbar()
    return
  end

  -- ---- New ----------------------------------------------------------------
  local hovered = self.mouse and widgets.inside(
    { x = x, y = y, w = w, h = bh }, self.mouse.x, self.mouse.y)
  add(widgets.button(font, "+  New chat", x, y,
        { w = w, hover = hovered, align = "left" }),
      { label = "New", action = function() command.perform("agent:new-session") end })
  y = y + bh + vpad * 1.5

  -- ---- Recents ------------------------------------------------------------
  common.draw_text(font, style.dim, "Recents", "left", x, y, w, lh)
  y = y + lh

  local current = bog.session and bog.session.id
  for _, s in ipairs(self.sessions) do
    if y > self.position.y + self.size.y then break end
    local title = s.title
    if not title or title == "" then title = "(untitled)" end
    local active = (s.id == current)
    local hov = self.mouse and widgets.inside(
      { x = x, y = y, w = w, h = lh }, self.mouse.x, self.mouse.y)
    if active or hov then
      renderer.draw_rect(x, y, w, lh, active and style.selection or style.line_highlight)
    end
    -- Truncated by measurement, not by a guessed character count: the sidebar
    -- font is proportional, so "iiii" and "WWWW" are not the same width.
    local label = title
    while font:get_width(label) > w - pad * 2 and #label > 4 do
      label = label:sub(1, #label - 2)
    end
    if label ~= title then label = label .. "…" end
    common.draw_text(font, active and style.text or style.dim, label,
      "left", x + pad / 2, y, w, lh)
    add({ x = x, y = y, w = w, h = lh }, {
      id = "sess" .. tostring(s.id),
      action = function()
        local studio = require "core.studio"
        studio.open_session(s.id)
      end,
    })
    y = y + lh
  end

  self.content_height = (y + self.scroll.y) - self.position.y

  -- ---- footer: who and what -----------------------------------------------
  local fy = self.position.y + self.size.y - lh - vpad
  renderer.draw_rect(self.position.x, fy - vpad, self.size.x, 1, style.divider)
  local model = (bog.session and bog.session.model) or "no model"
  local hovf = self.mouse and widgets.inside(
    { x = x, y = fy, w = w, h = lh }, self.mouse.x, self.mouse.y)
  if hovf then renderer.draw_rect(x, fy, w, lh, style.line_highlight) end
  common.draw_text(font, style.dim, model, "left", x + pad / 2, fy, w, lh)
  add({ x = x, y = fy, w = w, h = lh },
      { id = "model", action = function() command.perform("agent:settings") end })

  self:draw_scrollbar()
end

return SidebarView
