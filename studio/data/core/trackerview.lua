-- trackerview.lua -- the tracker as a studio tab: list or board, plus a card.
--
-- Draws lua/tracker_view.lua's models -- the same sections, rows, cards and
-- board columns the TUI prints -- so a ticket reads the same in the window and
-- in the terminal. Two modes share one right-hand card:
--   List   the "what's next" grouping (in progress / review / ready / blocked /
--          waiting), rows wrapped, the selected ticket's card beside it
--   Board  a column per status, cards in priority order
-- Keyboard: j/k (and the wheel) move the selection, b toggles the board, p
-- picks a project, r refreshes. Everything is also a click.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local View = require "core.view"

local tv = require "tracker_view"
local tc = require "tracker_core"

local M = {}
local TrackerView = View:extend()

M.LAST_PROJECT_KEY = "studio.tracker.project"
local REFRESH_S = 2.0

local function kv_get(k) return bog and bog.store and bog.store.kv_get and bog.store.kv_get(k) end
local function kv_set(k, v) if bog and bog.store and bog.store.kv_set then pcall(bog.store.kv_set, k, v) end end

-- status colours, always paired with the glyph (never colour alone)
local function status_colour(s)
  if s == "in_progress" or s == "in_review" then return style.accent end
  if s == "blocked" then return style.warn or style.accent end
  if s == "done" or s == "cancelled" then return style.dim end
  return style.text
end

-- ---- pixel wrapping ----------------------------------------------------------
local function wrap_px(font, text, width, max_lines)
  local lines, cur = {}, ""
  for w in tostring(text or ""):gmatch("%S+") do
    local try = cur == "" and w or (cur .. " " .. w)
    if font:get_width(try) <= width or cur == "" then cur = try
    else lines[#lines + 1] = cur; cur = w end
  end
  if cur ~= "" or #lines == 0 then lines[#lines + 1] = cur end
  if max_lines and #lines > max_lines then
    local keep = { table.unpack(lines, 1, max_lines) }
    local last = keep[max_lines]
    while last ~= "" and font:get_width(last .. "…") > width do last = last:sub(1, #last - 1) end
    keep[max_lines] = last .. "…"
    return keep
  end
  return lines
end

-- ---- state ---------------------------------------------------------------------
function TrackerView:new(project, key)
  TrackerView.super.new(self)
  self.scrollable = true
  self.mode = "list"
  self.project = project and project:upper() or kv_get(M.LAST_PROJECT_KEY)
  self.selected = key and key:upper() or nil
  self.hits = {}
  self.list_scroll, self.card_scroll = 0, 0
  self.next_refresh = 0
  self:refresh(true)
end

function TrackerView:get_name()
  return "Tracker" .. (self.project and (" · " .. self.project) or "")
end

function TrackerView:refresh(force)
  local now = system.get_time()
  if not force and now < self.next_refresh then return end
  self.next_refresh = now + REFRESH_S
  local ok = pcall(tc.ensure_schema)
  if not ok then self.error = "tracker store unavailable"; return end
  self.projects = tv.projects_model().projects
  if not self.project or not tc.project_row(self.project) then
    self.project = self.projects[1] and self.projects[1].key or nil
  end
  if not self.project then self.model, self.board, self.order = nil, nil, {}; return end
  self.model = tv.next_model(self.project)
  self.board = tv.board_model(self.project)
  -- selection order: the list's rows, or the board's cards column by column
  local order = {}
  if self.mode == "board" and self.board then
    for _, c in ipairs(self.board.columns) do for _, r in ipairs(c.rows) do order[#order + 1] = r.key end end
  elseif self.model then
    for _, s in ipairs(self.model.sections) do for _, r in ipairs(s.rows) do order[#order + 1] = r.key end end
  end
  self.order = order
  local still = false
  for _, k in ipairs(order) do if k == self.selected then still = true end end
  if not still and not (self.selected and tc.task_row(self.selected)) then self.selected = order[1] end
  self.card = self.selected and tv.card_model(self.selected) or nil
end

function TrackerView:set_project(key)
  self.project = key
  kv_set(M.LAST_PROJECT_KEY, key)
  self.selected, self.list_scroll, self.card_scroll = nil, 0, 0
  self:refresh(true)
  core.redraw = true
end

function TrackerView:select(key)
  self.selected = key
  self.card = key and tv.card_model(key) or nil
  self.card_scroll = 0
  self.follow = true
  core.redraw = true
end

function TrackerView:select_delta(d)
  local order = self.order or {}
  if #order == 0 then return end
  local i = 1
  for k, key in ipairs(order) do if key == self.selected then i = k end end
  self:select(order[common.clamp(i + d, 1, #order)])
end

function TrackerView:toggle_board()
  self.mode = self.mode == "board" and "list" or "board"
  self:refresh(true)
  core.redraw = true
end

function TrackerView:pick_project()
  local projects = self.projects or {}
  core.command_view:enter("Tracker project", function(text, item)
    local key = item and item.key or (text or ""):upper():match("^(%S+)")
    if key and tc.project_row(key) then self:set_project(key) end
  end, function(text)
    local out, needle = {}, (text or ""):lower()
    for _, p in ipairs(projects) do
      local hay = (p.key .. " " .. p.name):lower()
      if needle == "" or hay:find(needle, 1, true) then
        out[#out + 1] = { text = p.key, info = string.format("%s  (%d open)", p.name, p.open), key = p.key }
      end
    end
    return out
  end)
end

function TrackerView:update()
  TrackerView.super.update(self)
  self:refresh(false)
end

-- ---- input ------------------------------------------------------------------------
function TrackerView:on_spine_scroll(lines) self:select_delta(lines) end

function TrackerView:on_mouse_wheel(y)
  local mx = self.mouse_x or 0
  if self.split_x and mx > self.split_x then
    self.card_scroll = math.max(0, self.card_scroll - y * 40)
  else
    self:select_delta(y > 0 and -1 or 1)
  end
  core.redraw = true
end

function TrackerView:on_mouse_moved(x, y, ...)
  TrackerView.super.on_mouse_moved(self, x, y, ...)
  self.mouse_x, self.mouse_y = x, y
end

function TrackerView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then return end
  for i = #self.hits, 1, -1 do
    local h = self.hits[i]
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then h.action(); return true end
  end
end

local function key_action(self, key)
  if key == "b" then self:toggle_board() return true end
  if key == "p" then self:pick_project() return true end
  if key == "r" then self:refresh(true); core.redraw = true return true end
  if key == "down" then self:select_delta(1) return true end
  if key == "up" then self:select_delta(-1) return true end
end
function TrackerView:on_key_pressed(key) return key_action(self, key) end
function TrackerView:on_text_input(text) return key_action(self, text) end

-- ---- drawing -----------------------------------------------------------------------
local function hit(self, x, y, w, h, action) self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, action = action } end

function TrackerView:draw_toolbar(x, y, w)
  local font, lh = style.font, style.font:get_height()
  local pad = style.padding.x
  local cx = x
  local label = (self.project or "no project") .. "  ▾"
  local lw = font:get_width(label) + pad * 2
  renderer.draw_rect(cx, y, lw, lh + style.padding.y, style.background3 or style.background2)
  common.draw_text(font, style.accent, label, "center", cx, y, lw, lh + style.padding.y)
  hit(self, cx, y, lw, lh + style.padding.y, function() self:pick_project() end)
  cx = cx + lw + pad
  for _, m in ipairs{ { "list", "List" }, { "board", "Board" } } do
    local tw = font:get_width(m[2]) + pad * 2
    local on = self.mode == m[1]
    renderer.draw_rect(cx, y, tw, lh + style.padding.y, on and style.selection or style.background2)
    common.draw_text(font, on and style.text or style.dim, m[2], "center", cx, y, tw, lh + style.padding.y)
    hit(self, cx, y, tw, lh + style.padding.y, function() if self.mode ~= m[1] then self:toggle_board() end end)
    cx = cx + tw
  end
  if self.model then
    local counts = string.format("open %d · done %d · next %s", self.model.open, self.model.done, self.model.next)
    common.draw_text(font, style.dim, counts, "right", x, y, w, lh + style.padding.y)
  end
  if tc.backend() == "station" then
    common.draw_text(font, style.warn or style.dim, "backend: station (this view shows the native store)",
      "left", cx + pad, y, w - (cx - x) - 200, lh + style.padding.y)
  end
  return lh + style.padding.y * 2
end

-- One list row: glyph, key, title (wrapped, max 2 lines), dim note line.
function TrackerView:draw_row(r, x, y, w, selected)
  local font, lh = style.font, style.font:get_height()
  local gw = font:get_width("◐ ")
  local kw = font:get_width("WWWWW-000 ")
  local tx = x + gw + kw
  local lines = wrap_px(font, r.title, w - (tx - x) - style.padding.x, 2)
  local h = #lines * lh + (r.note and lh or 0) + style.padding.y
  if selected then renderer.draw_rect(x - style.padding.x / 2, y, w + style.padding.x, h, style.line_highlight) end
  renderer.draw_text(font, r.glyph, x, y, status_colour(r.status))
  renderer.draw_text(font, r.key, x + gw, y, style.accent)
  for i, l in ipairs(lines) do renderer.draw_text(font, l, tx, y + (i - 1) * lh, style.text) end
  if r.note then renderer.draw_text(font, r.note, tx, y + #lines * lh, style.dim) end
  hit(self, x, y, w, h, function() self:select(r.key) end)
  return h
end

function TrackerView:draw_list(x, y, w, h)
  local font, lh = style.font, style.font:get_height()
  if not self.model then return end
  -- lay out once to know where the selection sits, then scroll to keep it in view
  local items, cy = {}, 0
  for _, s in ipairs(self.model.sections) do
    items[#items + 1] = { head = s.title .. "  " .. #s.rows, y = cy }; cy = cy + lh + style.padding.y
    for _, r in ipairs(s.rows) do
      local lines = wrap_px(font, r.title, w - font:get_width("◐ WWWWW-000 ") - style.padding.x, 2)
      local rh = #lines * lh + (r.note and lh or 0) + style.padding.y
      items[#items + 1] = { row = r, y = cy, h = rh }; cy = cy + rh
    end
    cy = cy + style.padding.y
  end
  if self.model.done > 0 then items[#items + 1] = { head = "Done  " .. self.model.done, y = cy }; cy = cy + lh end
  if self.follow then
    for _, it in ipairs(items) do
      if it.row and it.row.key == self.selected then
        if it.y < self.list_scroll then self.list_scroll = it.y
        elseif it.y + it.h > self.list_scroll + h then self.list_scroll = it.y + it.h - h end
      end
    end
    self.follow = false
  end
  self.list_scroll = common.clamp(self.list_scroll, 0, math.max(0, cy - h))
  core.push_clip_rect(x, y, w, h)
  for _, it in ipairs(items) do
    local iy = y + it.y - self.list_scroll
    if iy + (it.h or lh) >= y and iy <= y + h then
      if it.head then renderer.draw_text(font, it.head, x, iy, style.dim)
      else self:draw_row(it.row, x, iy, w, it.row.key == self.selected) end
    end
  end
  if #self.model.sections == 0 then renderer.draw_text(font, "Nothing open.", x, y, style.dim) end
  core.pop_clip_rect()
end

function TrackerView:draw_board(x, y, w, h)
  local font, lh = style.font, style.font:get_height()
  if not self.board then return end
  local cols = {}
  for _, c in ipairs(self.board.columns) do
    -- empty review/cancelled columns are noise; the workflow ones always show
    if #c.rows > 0 or c.status == "open" or c.status == "in_progress" or c.status == "done" then cols[#cols + 1] = c end
  end
  local gap = style.padding.x
  local cw = math.max(160 * SCALE, (w - gap * (#cols - 1)) / #cols)
  -- keep the selected card's column in view when the columns do not all fit
  local sel_col = 1
  for i, c in ipairs(cols) do for _, r in ipairs(c.rows) do if r.key == self.selected then sel_col = i end end end
  local visible = math.max(1, math.floor((w + gap) / (cw + gap)))
  self.board_first = common.clamp(self.board_first or 1, 1, math.max(1, #cols - visible + 1))
  if sel_col < self.board_first then self.board_first = sel_col end
  if sel_col >= self.board_first + visible then self.board_first = sel_col - visible + 1 end
  core.push_clip_rect(x, y, w, h)
  local cx = x
  for i = self.board_first, math.min(#cols, self.board_first + visible - 1) do
    local c = cols[i]
    renderer.draw_text(font, c.glyph .. " " .. c.title .. "  " .. #c.rows, cx, y, status_colour(c.status))
    local cy = y + lh + style.padding.y
    for _, r in ipairs(c.rows) do
      local lines = wrap_px(font, r.title, cw - style.padding.x * 2, 3)
      local ch = (1 + #lines + (r.note and 1 or 0)) * lh + style.padding.y * 2
      if cy + ch > y + h then
        renderer.draw_text(font, "…", cx + style.padding.x, cy, style.dim); break
      end
      renderer.draw_rect(cx, cy, cw, ch, r.key == self.selected and style.selection or style.background2)
      local gx = cx + style.padding.x
      renderer.draw_text(font, r.glyph, gx, cy + style.padding.y, status_colour(r.note and "blocked" or r.status))
      renderer.draw_text(font, r.key .. "  P" .. r.priority .. " " .. r.kind, gx + font:get_width("◐ "), cy + style.padding.y, style.accent)
      for li, l in ipairs(lines) do
        renderer.draw_text(font, l, gx, cy + style.padding.y + li * lh, style.text)
      end
      if r.note then
        local note = wrap_px(font, r.note, cw - style.padding.x * 2, 1)[1]
        renderer.draw_text(font, note, gx, cy + style.padding.y + (#lines + 1) * lh, style.warn or style.dim)
      end
      hit(self, cx, cy, cw, ch, function() self:select(r.key) end)
      cy = cy + ch + style.padding.y
    end
    cx = cx + cw + gap
  end
  core.pop_clip_rect()
  if #cols > visible then
    renderer.draw_text(font, string.format("columns %d–%d of %d", self.board_first,
      math.min(#cols, self.board_first + visible - 1), #cols), x, y + h - lh, style.dim)
  end
end

-- The card: the same sections, in the same order, as the TUI's.
function TrackerView:draw_card(x, y, w, h)
  local c = self.card
  local font, lh = style.font, style.font:get_height()
  if not c then renderer.draw_text(font, "Select a ticket.", x, y, style.dim); return end
  local blocks = {}
  local function line(text, colour, indent) blocks[#blocks + 1] = { text = text, colour = colour or style.text, indent = indent or 0 } end
  local function gap() blocks[#blocks + 1] = { gap = true } end
  local function para(text, colour, indent)
    for _, l in ipairs(wrap_px(font, text, w - (indent or 0) - style.padding.x)) do line(l, colour, indent) end
  end
  local function keyref(label, list)
    local parts = {}
    for _, k in ipairs(list) do parts[#parts + 1] = k.key .. (k.status == "done" and " ✓" or "") end
    blocks[#blocks + 1] = { label = label, refs = list, text = table.concat(parts, ", ") }
  end
  para(c.key .. "  " .. c.title, style.accent)
  line(c.glyph .. " " .. c.label .. " · " .. c.kind .. " · P" .. c.priority .. (c.parent and (" · parent " .. c.parent) or ""), status_colour(c.status))
  -- The description is often a whole planning document; collapsed, it keeps
  -- acceptance and dependencies on screen. Click to expand (per ticket).
  local desc = tv.plain_description(c.description, c.key, c.title)
  if desc ~= "" then
    gap()
    local body = {}
    for p in (desc .. "\n"):gmatch("(.-)\n") do
      if p == "" then body[#body + 1] = false
      else for _, l in ipairs(wrap_px(font, p, w - style.padding.x * 2)) do body[#body + 1] = l end end
    end
    local full = self.card_full == c.key
    local limit = full and #body or math.min(#body, tv.CARD_DESC_LINES)
    for i = 1, limit do
      if body[i] == false then gap() else line(body[i], style.text, style.padding.x) end
    end
    if #body > tv.CARD_DESC_LINES then
      blocks[#blocks + 1] = { toggle = true,
        text = full and "Show less" or string.format("Show all  (%d more lines)", #body - limit) }
    end
  end
  if #c.criteria > 0 then
    gap(); line(string.format("Acceptance  %d of %d passing", c.criteria_pass, #c.criteria), style.dim)
    for _, k in ipairs(c.criteria) do
      -- unmet reads as outstanding, not disabled: only a FAILURE changes the text colour
      local col = k.result == "fail" and (style.error or style.warn or style.accent) or style.text
      local ls = wrap_px(font, k.text, w - style.padding.x * 3)
      for i, l in ipairs(ls) do line((i == 1 and (k.mark .. " ") or "   ") .. l, col, style.padding.x) end
      line("↳ " .. (k.test_ref ~= "" and k.test_ref or "no test linked"), style.dim, style.padding.x * 3)
    end
  end
  if #c.waits > 0 or #c.blocks > 0 or #c.tags > 0 or #c.commits > 0 then gap() end
  if #c.waits > 0 then keyref("Waits on", c.waits) end
  if #c.blocks > 0 then keyref("Blocks", c.blocks) end
  if #c.tags > 0 then line("Tags  " .. table.concat(c.tags, ", "), style.dim) end
  for i, cm in ipairs(c.commits) do
    if i > 5 then line("… " .. (#c.commits - 5) .. " more commits", style.dim); break end
    line((i == 1 and "Commits  " or "         ") .. cm.hash:sub(1, 7) .. " " .. cm.message, style.dim)
  end
  if #c.children > 0 then
    gap(); line("Subtasks  " .. #c.children, style.dim)
    for _, r in ipairs(c.children) do blocks[#blocks + 1] = { child = r } end
  end

  local total = 0
  for _, b in ipairs(blocks) do total = total + (b.gap and lh / 2 or lh) end
  self.card_scroll = common.clamp(self.card_scroll, 0, math.max(0, total - h))
  core.push_clip_rect(x, y, w, h)
  local cy = y - self.card_scroll
  for _, b in ipairs(blocks) do
    if b.gap then cy = cy + lh / 2
    else
      if cy + lh >= y and cy <= y + h then
        if b.toggle then
          renderer.draw_text(font, b.text, x + style.padding.x, cy, style.accent)
          local key = c.key
          hit(self, x + style.padding.x, cy, font:get_width(b.text), lh, function()
            self.card_full = (self.card_full == key) and nil or key
            core.redraw = true
          end)
        elseif b.child then
          renderer.draw_text(font, b.child.glyph, x + style.padding.x, cy, status_colour(b.child.status))
          renderer.draw_text(font, b.child.key .. "  " .. b.child.title, x + style.padding.x + font:get_width("◐ "), cy, style.text)
          local ck = b.child.key
          hit(self, x, cy, w, lh, function() self:select(ck) end)
        elseif b.refs then
          renderer.draw_text(font, b.label, x, cy, style.dim)
          local rx = x + font:get_width("Waits on    ")
          for _, k in ipairs(b.refs) do
            local t = k.key .. (k.status == "done" and " ✓" or "")
            renderer.draw_text(font, t, rx, cy, style.accent)
            local kk = k.key
            hit(self, rx, cy, font:get_width(t), lh, function() self:select(kk) end)
            rx = rx + font:get_width(t .. ",  ")
          end
        else
          renderer.draw_text(font, b.text, x + (b.indent or 0), cy, b.colour)
        end
      end
      cy = cy + lh
    end
  end
  core.pop_clip_rect()
end

function TrackerView:draw()
  self:draw_background(style.background)
  self.hits = {}
  local x, y = self.position.x + style.padding.x, self.position.y + style.padding.y
  local w, h = self.size.x - style.padding.x * 2, self.size.y - style.padding.y * 2
  if self.error then renderer.draw_text(style.font, self.error, x, y, style.dim); return end
  if not self.project then
    common.draw_text(style.font, style.dim,
      "No projects yet. Run /tracker import to bring in ai-grind's, or ask the agent to create one.",
      "left", x, y, w, style.font:get_height())
    return
  end
  local th = self:draw_toolbar(x, y, w)
  y, h = y + th, h - th
  local left = self.mode == "board" and math.floor(w * 0.64) or common.clamp(math.floor(w * 0.44), 260 * SCALE, 560 * SCALE)
  if w < 560 * SCALE then left = w end  -- narrow (a docked panel): the list alone, card below via selection
  self.split_x = x + left
  if self.mode == "board" then self:draw_board(x, y, left - style.padding.x, h)
  else self:draw_list(x, y, left - style.padding.x, h) end
  if left < w then
    renderer.draw_rect(x + left, y, 1, h, style.divider)
    self:draw_card(x + left + style.padding.x * 2, y, w - left - style.padding.x * 2, h)
  end
end

-- ---- opening ------------------------------------------------------------------------
function M.open(project, key)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(TrackerView) then
      if project then v:set_project(project:upper()) end
      if key then v:select(key:upper()) end
      local node = core.root_view.root_node:get_node_for_view(v)
      if node then node:set_active_view(v) else core.set_active_view(v) end
      return v
    end
  end
  local view = TrackerView(project, key)
  M.view = view
  core.root_view:get_primary_node():add_view(view)
  core.set_active_view(view)
  return view
end

local function in_tracker() return core.active_view and core.active_view.is and core.active_view:is(TrackerView) end

if not command.map["tracker:open"] then
  command.add(nil, { ["tracker:open"] = function() M.open() end })
  command.add(in_tracker, {
    ["tracker:toggle-board"] = function() core.active_view:toggle_board() end,
    ["tracker:pick-project"] = function() core.active_view:pick_project() end,
    ["tracker:refresh"] = function() core.active_view:refresh(true); core.redraw = true end,
    ["tracker:next-ticket"] = function() core.active_view:select_delta(1) end,
    ["tracker:previous-ticket"] = function() core.active_view:select_delta(-1) end,
  })
end

M.View = TrackerView
return M
