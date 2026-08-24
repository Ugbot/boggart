-- sidebarview.lua -- the session list that lives in the one sidebar slot.
--
-- Used by the default workspaces attach and by the legacy studio composition
-- (core.studio.attach_legacy / BOGGART_STUDIO_LEGACY=1). The experimental
-- shell does not reuse this view as a Chat/Code control: sessions live in the
-- Agent menu when it is docked as a recents rail (`shell_rail`).
--
-- Chat puts this view in the locked leaf. Files swaps the file tree into
-- the same leaf. More is the rail popover, not a second list here. The
-- legacy attach (BOGGART_STUDIO_LEGACY) still draws the Chat/Code
-- segmented control this file grew up with.
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
  self.tab = "chat"           -- legacy Chat/Code segmented control
  self.sessions = {}
  self.hits = {}
  self.last_refresh = 0
  self.confirm_delete = nil   -- the session id armed for deletion, if any
  self.search = ""            -- the search box text; "" shows plain recents
  self.results = {}           -- store.sess_search rows for the current query
  self.searching = false      -- the box has focus and is taking keystrokes
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

-- Run the FTS query behind the box. Kept off the draw path -- it is a SQLite
-- query, so it runs when the text changes, not once per frame. An empty query
-- means "show recents", so results is emptied and draw falls back to sessions.
function SidebarView:set_search(text)
  self.search = text or ""
  self.confirm_delete = nil
  if self.search == "" then
    self.results = {}
  else
    local ok, rows = pcall(bog.store.sess_search, self.search, 40)
    self.results = (ok and rows) or {}
  end
  core.redraw = true
end

-- Put the caret in the search box. The command routes here, and so does a click
-- on the field. Search is a chat-tab thing, so switch there first; then take
-- focus so on_text_input/on_key_pressed start arriving.
function SidebarView:focus_search()
  if (core.studio and core.studio.legacy) and self.tab ~= "chat" then
    self:set_tab("chat")
  end
  self.searching = true
  core.set_active_view(self)
  core.redraw = true
end

-- Typed characters land here only while the box holds focus; every other key
-- (backspace, escape, return) is a stroke and arrives via on_key_pressed.
function SidebarView:on_text_input(text)
  if not self.searching then return end
  self:set_search(self.search .. text)
end

-- Editing keys for the search box. keymap hands a view the strokes no command
-- claimed (see keymap.on_key_pressed), and none of the doc:* editing commands
-- match while the rail -- not a DocView -- is focused, so backspace/escape/
-- return fall through to here. The full stroke is passed, so plain keys are
-- distinguishable from chords.
function SidebarView:on_key_pressed(stroke)
  if not self.searching then return false end
  if stroke == "escape" then
    self.searching = false
    if self.search ~= "" then self:set_search("") end
    if core.last_active_view then core.set_active_view(core.last_active_view) end
    core.redraw = true
    return true
  elseif stroke == "backspace" then
    local q = self.search
    if q ~= "" then
      -- Drop one whole UTF-8 character, not one byte.
      local n = utf8.len(q)
      if n and n > 0 then
        self:set_search(q:sub(1, (utf8.offset(q, n) or #q) - 1))
      else
        self:set_search(q:sub(1, -2))
      end
    end
    return true
  elseif stroke == "return" or stroke == "keypad enter" then
    -- Open the top hit, the same way clicking its row would.
    local rows = (self.search ~= "" and self.results) or self.sessions
    local s = rows and rows[1]
    if s then
      self.searching = false
      require("core.studio").open_session(s.id)
    end
    return true
  end
  return false
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

  -- Focus is single-owner: once anything else takes it (a session opened, the
  -- composer clicked) the box stops swallowing keystrokes. The query text is
  -- left intact, so the results stay on screen until cleared with escape or ×.
  if self.searching and core.active_view ~= self then self.searching = false end

  -- Follow Chat/Code when this is the legacy segmented rail, not the
  -- workspaces sidebar (studio.legacy == false) or a shell recents dock.
  if not self.shell_rail and not (core.studio and core.studio.legacy == false) then
    local active = core.active_view
    if active then
      if active.doc then self.tab = "code"
      elseif active == (core.studio and core.studio.view) then self.tab = "chat" end
    end
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

  local bh = widgets.height(font)
  local legacy = core.studio and core.studio.legacy

  -- ---- Chat / Code (legacy attach only) -----------------------------------
  if legacy then
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
  end

  if legacy and self.tab == "code" then
    local hov = self.mouse and widgets.inside(
      { x = x, y = y, w = w, h = bh }, self.mouse.x, self.mouse.y)
    add(widgets.button(font, "Open a file...", x, y,
          { w = w, hover = hov, align = "left" }),
        { label = "open", action = function() command.perform("core:find-file") end })
    y = y + bh + vpad
    common.draw_text(font, style.dim, "The tree is on the left.",
      "left", x + pad / 2, y, w, lh)
    self.content_height = (y + lh + self.scroll.y) - self.position.y
    self:draw_scrollbar()
    return
  end

  -- ---- New / Prompts ------------------------------------------------------
  local gap = style.padding.x * widgets.GAP
  local halfw = (w - gap) / 2
  local hovered = self.mouse and widgets.inside(
    { x = x, y = y, w = halfw, h = bh }, self.mouse.x, self.mouse.y)
  add(widgets.button(font, "+  New", x, y,
        { w = halfw, hover = hovered, align = "left" }),
      { label = "New", action = function() command.perform("agent:new-session") end })
  local rx = x + halfw + gap
  local rhov = self.mouse and widgets.inside(
    { x = rx, y = y, w = halfw, h = bh }, self.mouse.x, self.mouse.y)
  add(widgets.button(font, "Prompts", rx, y,
        { w = halfw, hover = rhov }),
      { label = "Prompts", command = "agent:run-recipe",
        action = function() command.perform("agent:run-recipe") end })
  y = y + bh + vpad * 1.5

  -- ---- Search -------------------------------------------------------------
  -- One flat field, the height of the buttons but recessed. Typing swaps
  -- Recents for live FTS results; an empty box falls back to Recents. The whole
  -- field is a hit that takes focus; the × clears the query. Registering the ×
  -- hit BEFORE the field's is what lets a click on it win the overlap, the same
  -- rule the row delete relies on -- widgets.hit answers with the first rect.
  local sh = bh
  local focused = self.searching and core.active_view == self
  renderer.draw_rect(x, y, w, sh, style.background)
  renderer.draw_rect(x, y + sh - 1, w, 1, focused and style.accent or style.divider)
  local q = self.search or ""
  local placeholder = (q == "")
  local cxw = font:get_width("×") + pad
  local shown = fit(font, placeholder and "Search chats" or q, w - pad * 2 - cxw)
  common.draw_text(font, placeholder and style.dim or style.text, shown,
    "left", x + pad / 2, y, w, sh)
  -- A still caret -- the rail keeps no per-frame timer and does not want one --
  -- sitting just after the query while the box is focused.
  if focused then
    local cx = x + pad / 2 + (placeholder and 0 or font:get_width(shown))
    renderer.draw_rect(cx, y + (sh - lh) / 2 + 2, math.max(1, SCALE), lh - 4,
      style.caret or style.text)
  end
  if not placeholder then
    local chov = self.mouse and widgets.inside(
      { x = x + w - cxw, y = y, w = cxw, h = sh }, self.mouse.x, self.mouse.y)
    common.draw_text(font, chov and style.text or style.dim, "×",
      "left", x + w - cxw + pad / 2, y, cxw, sh)
    add({ x = x + w - cxw, y = y, w = cxw, h = sh },
        { id = "search-clear",
          action = function() self:set_search(""); self:focus_search() end })
  end
  add({ x = x, y = y, w = w, h = sh },
      { id = "search", action = function() self:focus_search() end })
  y = y + sh + vpad * 1.5

  -- ---- Recents / Results --------------------------------------------------
  -- One list, two sources: search results while a query is live, plain recents
  -- otherwise. The row draw and open path below are identical for both, so a
  -- hit opens exactly like a recent does.
  local rows = (self.search ~= "" and self.results) or self.sessions
  common.draw_text(font, style.dim, self.search ~= "" and "Results" or "Recents",
    "left", x, y, w, lh)
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
  local n = #rows
  local first = math.max(1, math.floor(self.scroll.y / lh) + 1)
  local current = bog.session and bog.session.id
  if n == 0 and self.search ~= "" then
    common.draw_text(font, style.dim, "No matches", "left", x + pad / 2, y, w, lh)
  end
  for i = first, n do
    local s = rows[i]
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
    -- Room kept for the delete control at all times, so the title does not
    -- reflow on hover and the target does not jump under the cursor. Sized as
    -- a real button (not a single × glyph): the hit box is the row height by
    -- the width of "Yes", which is the armed label.
    local dw = math.max(lh, widgets.width(font, "Yes"))
    local label = fit(font, title, w - pad * 2 - dw)
    common.draw_text(font, active and style.text or style.dim, label,
      "left", x + pad / 2, y, w, lh)

    -- Delete, guarded. Shows on hover, or stays as "Yes" on the armed row; the
    -- first click arms, a second click confirms, opening any row disarms.
    -- Registered BEFORE the row's open hit so a click on Del lands on it first.
    local armed = (self.confirm_delete == s.id)
    if hov or armed then
      local bx = x + w - dw
      local dhov = self.mouse and widgets.inside(
        { x = bx, y = y, w = dw, h = lh }, self.mouse.x, self.mouse.y)
      local r = widgets.button(font, armed and "Yes" or "Del", bx, y, {
        w = dw, h = lh, hover = dhov, active = armed,
        tone = armed and (style.error or style.text) or nil,
      })
      add(r, {
        id = "del" .. tostring(s.id),
        action = function()
          if self.confirm_delete == s.id then
            self.confirm_delete = nil
            require("core.studio").delete_session(s.id)
          else
            self.confirm_delete = s.id      -- arm; the next click on Yes confirms
          end
          core.redraw = true
        end,
      })
    end
    add({ x = x, y = y, w = w, h = lh }, {
      id = "sess" .. tostring(s.id),
      action = function()
        self.confirm_delete = nil           -- a stray delete never survives an open
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

-- Registered from here, not studio.lua, so the rail owns its own command. The
-- sidebar instance is built later (studio.setup), so it is looked up at call
-- time rather than captured now.
command.add(nil, {
  ["agent:search-sessions"] = function()
    local sh = package.loaded["shell"]
    if sh and sh.attached then sh.switch("agent") end
    local sb = core.studio and core.studio.sidebar
    if sb then sb:focus_search() end
  end,
})

return SidebarView
