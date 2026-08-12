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

-- The rail computed content_height every frame and nobody asked for it. The
-- base View answers math.huge, which get_scrollbar_rect reads as "no bar" and
-- clamp_scroll_position reads as "no bottom" -- so the scrollbar was a
-- zero-sized rect that never appeared, and the wheel could push every session
-- off the top with nothing on screen to say where you were or how to get back.
function SidebarView:get_scrollable_size()
  return self.content_height or math.huge
end

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
  -- Reopening by drag restores the width the rail had, rather than starting
  -- again from zero. RootView drags against get_target_size, which answers 0
  -- while collapsed and must -- the rail really does occupy nothing -- so a
  -- single pixel of mouse movement with the button still held after ctrl+b had
  -- hidden the rail both undid the collapse and threw the user's width away,
  -- snapping to the minimum with the animation skipped. The first drag pixel
  -- now reopens it at the width it had; the ones after it resize as usual.
  if not self.visible then
    self.visible = true
    self.init_size = true
    return true
  end
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

-- A title cut to fit a pixel width, on character boundaries, by bisection.
--
-- The previous loop shortened the string two BYTES at a time and measured
-- again, which cut an accented or CJK title part-way through a character and
-- then measured the invalid result -- and cost one font measurement per two
-- bytes per row per frame, so a session auto-titled from a pasted log ran that
-- loop thousands of times, forty rows deep, sixty times a second. The ellipsis
-- is part of what is fitted rather than appended afterwards, which is how the
-- finished label used to come out wider than the space it had just been fitted
-- to. A title that is not valid UTF-8 -- nothing stops one reaching the
-- database -- falls back to walking off continuation bytes, because
-- utf8.offset raises on one.
local function fit(font, text, room)
  if room <= 0 then return "" end
  if font:get_width(text) <= room then return text end
  local n = utf8.len(text)
  local function upto(chars)
    if n then
      return text:sub(1, (utf8.offset(text, chars + 1) or (#text + 1)) - 1)
    end
    local i = math.min(chars, #text)
    while i > 0 and common.is_utf8_cont(text:sub(i + 1, i + 1)) do i = i - 1 end
    return text:sub(1, i)
  end
  local lo, hi = 0, n or #text
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:get_width(upto(mid) .. "…") <= room then lo = mid else hi = mid - 1 end
  end
  return upto(lo) .. "…"
end

function SidebarView:draw()
  self:draw_background(style.background2)
  -- Cleared before the early return, not after it. Once the collapsing rail
  -- narrowed past this the draw bailed while self.hits still held the last
  -- full-width layout, so for the ten frames of the animation a click near the
  -- left edge opened a session in a rail that was no longer on screen.
  self.hits = {}
  if self.size.x < 20 then return end

  local font = style.font
  local lh = font:get_height() * config.line_height
  local pad = style.padding.x * 0.6
  local vpad = style.padding.y
  local x = self.position.x + pad
  local w = self.size.x - pad * 2
  local y = self.position.y + vpad - self.scroll.y

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

  -- Where the footer starts. The list used to run to the bottom of the VIEW,
  -- so the last row or two were drawn under the model name -- and because a
  -- session's rect is registered before the footer's, and widgets.hit answers
  -- with the first rect containing the point, clicking the model name opened a
  -- session instead of the settings.
  local footer_top = self.position.y + self.size.y - lh - vpad * 2

  -- Only the rows between the scroll offset and the footer are drawn, and
  -- content_height counts the WHOLE list rather than the part that fitted.
  -- Measuring what was drawn made the scrollable size equal the viewport, so
  -- the clamp pinned the scroll at zero and the rows past the fold could not
  -- be reached at all -- with no scrollbar to say they were there.
  local list_top = y
  local n = #self.sessions
  local first = math.max(1, math.floor(self.scroll.y / lh) + 1)
  local current = bog.session and bog.session.id
  for i = first, n do
    local s = self.sessions[i]
    y = list_top + (i - first) * lh
    if y + lh > footer_top then break end
    local title = tostring(s.title or "")
    if title == "" then title = "(untitled)" end
    local active = (s.id == current)
    local hov = self.mouse and widgets.inside(
      { x = x, y = y, w = w, h = lh }, self.mouse.x, self.mouse.y)
    if active or hov then
      renderer.draw_rect(x, y, w, lh, active and style.selection or style.line_highlight)
    end
    local label = fit(font, title, w - pad * 2)
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

  self.content_height = (list_top + self.scroll.y - self.position.y)
    + n * lh + lh + vpad * 3

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
