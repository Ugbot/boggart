local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local marks = require "core.marks"
local widgets = require "core.widgets"
local command = require "core.command"
local View = require "core.view"


local DocView = View:extend()


local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


-- Caret up/down by ONE VISUAL row (wrapping), preserving the target x offset
-- across repeated moves via last_x_offset -- so up/down through a wrapped line
-- tracks a column the way it does through unwrapped lines.
local function move_to_vrow_offset(dv, line, col, dir)
  dv:ensure_wrap()
  local v = dv:vrow_of(line, col)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:vrow_col_x(v, col)
  end
  local tv = common.clamp(v + dir, 1, #dv.wrap.rows)
  local newline = dv.wrap.rows[tv].line
  local newcol = dv:col_at_vrow(tv, xo.offset)
  xo.line, xo.col = newline, newcol
  return newline, newcol
end


DocView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if dv.wrapping then
      dv:ensure_wrap()
      if dv:vrow_of(line, col) <= 1 then return 1, 1 end
      return move_to_vrow_offset(dv, line, col, -1)
    end
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    if dv.wrapping then
      dv:ensure_wrap()
      if dv:vrow_of(line, col) >= #dv.wrap.rows then return #doc.lines, math.huge end
      return move_to_vrow_offset(dv, line, col, 1)
    end
    if line == #doc.lines then
      return #doc.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}

local blink_period = 0.8


function DocView:new(doc)
  DocView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  self.font = "code_font"
  self.last_x_offset = {}
  self.blink_timer = 0
  -- Rebuilt every frame from the visible lines only, so it is bounded by the
  -- height of the window rather than the length of the file.
  self.mark_hits = {}
  -- Soft-wrap. When on, long lines break to the view width at word boundaries
  -- and self.wrap maps document (line, col) <-> visual rows; when off, every
  -- function below takes its original one-row-per-line path (zero cost/risk).
  self.wrapping = config.line_wrap or false
  self.wrap = nil
end


-- ---- soft wrap -------------------------------------------------------------
-- The wrap cache: self.wrap = { rows, first, w, rev }. rows is the flat, ordered
-- list of visual rows { line = docline, s = start byte-col, e = end byte-col
-- (exclusive) }; first[line] is the index of a line's first visual row; w/rev
-- are the width and doc change-id it was built for, so it rebuilds on resize or
-- edit. Columns are byte offsets, matching the rest of DocView.
function DocView:get_wrap_width()
  return math.max(1, self.size.x - self:get_gutter_width() - style.padding.x)
end


function DocView:wrap_line_starts(line)
  local text = self.doc.lines[line]
  local font = self:get_font()
  local avail = self:get_wrap_width()
  local starts = { 1 }
  local x, start, last_space = 0, 1, nil
  local i, n = 1, #text
  while i <= n do
    local c = text:byte(i)
    if c == 10 then break end                       -- the trailing newline
    local clen = 1
    if c >= 0xF0 then clen = 4 elseif c >= 0xE0 then clen = 3 elseif c >= 0xC0 then clen = 2 end
    local ch = text:sub(i, i + clen - 1)
    local w = font:get_width(ch)
    if x + w > avail and i > start then
      local brk = (last_space and last_space > start) and last_space or i
      starts[#starts + 1] = brk
      start = brk
      x = font:get_width(text:sub(start, i - 1))
      last_space = nil
    end
    x = x + w
    if ch == " " or ch == "\t" then last_space = i + clen end
    i = i + clen
  end
  return starts
end


function DocView:build_wrap()
  local rows, first = {}, {}
  local lines = self.doc.lines
  for line = 1, #lines do
    first[line] = #rows + 1
    local starts = self:wrap_line_starts(line)
    for k = 1, #starts do
      rows[#rows + 1] = { line = line, s = starts[k], e = starts[k + 1] or (#lines[line] + 1) }
    end
  end
  self.wrap = { rows = rows, first = first, w = self:get_wrap_width(), rev = self.doc:get_change_id() }
end


function DocView:ensure_wrap()
  if not self.wrapping then self.wrap = nil; return end
  if not self.wrap or self.wrap.w ~= self:get_wrap_width()
     or self.wrap.rev ~= self.doc:get_change_id() then
    self:build_wrap()
  end
end


-- The visual-row index holding (line, col). A caret at a soft break belongs to
-- the start of the next row.
function DocView:vrow_of(line, col)
  self:ensure_wrap()
  local rows, v = self.wrap.rows, self.wrap.first[line]
  while v < #rows and rows[v + 1].line == line and rows[v + 1].s <= col do v = v + 1 end
  return v
end


-- The byte-column at horizontal pixel `tx` (measured from the text-area origin)
-- within visual row `v`. Mirrors get_x_offset_col but over the row's slice.
function DocView:col_at_vrow(v, tx)
  local row = self.wrap.rows[v]
  local text = self.doc.lines[row.line]
  local font = self:get_font()
  local xoff, last_i, i = 0, row.s, row.s
  while i < row.e do
    local c = text:byte(i)
    if c == 10 then break end
    local clen = 1
    if c >= 0xF0 then clen = 4 elseif c >= 0xE0 then clen = 3 elseif c >= 0xC0 then clen = 2 end
    local ch = text:sub(i, i + clen - 1)
    local w = font:get_width(ch)
    if xoff >= tx then return (xoff - tx > w / 2) and last_i or i end
    xoff = xoff + w; last_i = i; i = i + clen
  end
  -- past the last glyph: the row's end, but never past a trailing newline.
  local endc = row.e
  if endc > row.s and text:byte(endc - 1) == 10 then endc = endc - 1 end
  return endc
end


-- The x pixel offset of `col` within its visual row (measured from the row's
-- start, i.e. the text-area origin), for the caret and selection.
function DocView:vrow_col_x(v, col)
  local row = self.wrap.rows[v]
  local text = self.doc.lines[row.line]
  local a = math.max(row.s, math.min(col, row.e))
  return self:get_font():get_width(text:sub(row.s, a - 1))
end


function DocView:try_close(do_close)
  if self.doc:is_dirty()
  and #core.get_views_referencing_doc(self.doc) == 1 then
    core.command_view:enter("Unsaved Changes; Confirm Close", function(_, item)
      if item.text:match("^[cC]") then
        do_close()
      elseif item.text:match("^[sS]") then
        self.doc:save()
        do_close()
      end
    end, function(text)
      local items = {}
      if not text:find("^[^cC]") then table.insert(items, "Close Without Saving") end
      if not text:find("^[^sS]") then table.insert(items, "Save And Close") end
      return items
    end)
  else
    do_close()
  end
end


function DocView:get_name()
  local post = self.doc:is_dirty() and "*" or ""
  local name = self.doc:get_name()
  return name:match("[^/%\\]*$") .. post
end


-- How far this document can be scrolled.
--
-- This used to be `line_height * (nlines - 1) + size.y`, which is lite's
-- formula and means the maximum scroll puts the LAST line at the TOP -- a whole
-- viewport of nothing below the end of the file. That is a scrollbar that lies
-- (its thumb never reaches the bottom at the bottom) and a wheel that keeps
-- going after the document has run out.
--
-- The height of the content is the lines plus a line of breathing room, so the
-- furthest you can scroll leaves the last line at the BOTTOM. A document
-- shorter than the view yields a negative maximum, which clamp_scroll_position
-- pins to zero, so short files do not move at all.
function DocView:get_scrollable_size()
  local rows
  if self.wrapping then
    self:ensure_wrap()
    rows = #self.wrap.rows
  else
    rows = #self.doc.lines
  end
  return self:get_line_height() * rows + style.padding.y
end


function DocView:get_font()
  return style[self.font]
end


function DocView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


function DocView:get_gutter_width()
  return self:get_font():get_width(#self.doc.lines) + style.padding.x * 2
end


function DocView:get_line_screen_position(idx, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  if self.wrapping then
    local v = self:vrow_of(idx, col or 1)
    return x + gw, y + (v - 1) * lh + style.padding.y
  end
  return x + gw, y + (idx-1) * lh + style.padding.y
end


function DocView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


function DocView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  if self.wrapping then
    self:ensure_wrap()
    local rows = self.wrap.rows
    local vmin = common.clamp(math.floor(y / lh), 1, #rows)
    local vmax = common.clamp(math.floor(y2 / lh) + 1, 1, #rows)
    return rows[vmin].line, rows[vmax].line
  end
  local minline = math.max(1, math.floor(y / lh))
  local maxline = math.min(#self.doc.lines, math.floor(y2 / lh) + 1)
  return minline, maxline
end


-- The visible visual-row range (wrapping only), for the draw loop.
function DocView:get_visible_vrow_range()
  self:ensure_wrap()
  local _, y, _, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local n = #self.wrap.rows
  return common.clamp(math.floor(y / lh), 1, n), common.clamp(math.floor(y2 / lh) + 1, 1, n)
end


function DocView:get_col_x_offset(line, col)
  local text = self.doc.lines[line]
  if not text then return 0 end
  return self:get_font():get_width(text:sub(1, col - 1))
end


function DocView:get_x_offset_col(line, x)
  local text = self.doc.lines[line]

  local xoffset, last_i, i = 0, 1, 1
  for char in common.utf8_chars(text) do
    local w = self:get_font():get_width(char)
    if xoffset >= x then
      return (xoffset - x > w / 2) and last_i or i
    end
    xoffset = xoffset + w
    last_i = i
    i = i + #char
  end

  return #text
end


function DocView:resolve_screen_position(x, y)
  if self.wrapping then
    self:ensure_wrap()
    local ox, oy = self:get_content_offset()
    local lh = self:get_line_height()
    local v = math.floor((y - (oy + style.padding.y)) / lh) + 1
    v = common.clamp(v, 1, #self.wrap.rows)
    local gw = self:get_gutter_width()
    local col = self:col_at_vrow(v, x - (ox + gw))
    return self.wrap.rows[v].line, col
  end
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, #self.doc.lines)
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


function DocView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line > min and line < max) then
    local lh = self:get_line_height()
    self.scroll.to.y = math.max(0, lh * (line - 1) - self.size.y / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end


function DocView:scroll_to_make_visible(line, col)
  local lh = self:get_line_height()
  if self.wrapping then
    -- Vertical only -- wrapped text never scrolls sideways -- and by visual row.
    local v = self:vrow_of(line, col or 1)
    local min = lh * (v - 1)
    local max = lh * (v + 2) - self.size.y
    self.scroll.to.y = math.min(self.scroll.to.y, min)
    self.scroll.to.y = math.max(self.scroll.to.y, max)
    self.scroll.to.x = 0
    return
  end
  local min = lh * (line - 1)
  local max = lh * (line + 2) - self.size.y
  self.scroll.to.y = math.min(self.scroll.to.y, min)
  self.scroll.to.y = math.max(self.scroll.to.y, max)
  local gw = self:get_gutter_width()
  local xoffset = self:get_col_x_offset(line, col)
  local mx = xoffset - self.size.x + gw + self.size.x / 5
  self.scroll.to.x = math.max(0, mx)
end


local function mouse_selection(doc, clicks, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if clicks == 2 then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
  elseif clicks == 3 then
    if line2 == #doc.lines and doc.lines[#doc.lines] ~= "\n" then
      doc:insert(math.huge, math.huge, "\n")
    end
    line1, col1, line2, col2 = line1, 1, line2 + 1, 1
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


function DocView:on_mouse_pressed(button, x, y, clicks)
  local caught = DocView.super.on_mouse_pressed(self, button, x, y, clicks)
  if caught then
    return
  end
  -- A mark's controls take the click before the text does. They are drawn on
  -- top of it, so they have to be hit-tested on top of it too, or you click
  -- "revert" and get a caret.
  local item = widgets.hit(self.mark_hits, x, y)
  if item and button == "left" then
    if item.action == "revert" then
      self:revert_mark(item.mark)
    elseif item.action == "accept" then
      self:accept_mark(item.mark)
    else
      self:select_mark(item.mark)
    end
    return
  end
  if keymap.modkeys["shift"] then
    if clicks == 1 then
      local line1, col1 = select(3, self.doc:get_selection())
      local line2, col2 = self:resolve_screen_position(x, y)
      self.doc:set_selection(line2, col2, line1, col1)
    end
  else
    local line, col = self:resolve_screen_position(x, y)
    self.doc:set_selection(mouse_selection(self.doc, clicks, line, col, line, col))
    self.mouse_selecting = { line, col, clicks = clicks }
  end
  self.blink_timer = 0
end


function DocView:on_mouse_moved(x, y, ...)
  DocView.super.on_mouse_moved(self, x, y, ...)

  -- Only repaint when the answer changed. The hit list is at most one entry
  -- per visible line, so asking is cheap, but repainting on every pixel of
  -- pointer movement is not.
  local over = widgets.hit(self.mark_hits, x, y)
  if over ~= self.mark_over then
    self.mark_over = over
    core.redraw = true
  end
  self.mark_hover = { x = x, y = y }

  if self:scrollbar_overlaps_point(x, y) or self.dragging_scrollbar then
    self.cursor = "arrow"
  elseif over then
    self.cursor = "arrow"
  else
    self.cursor = "ibeam"
  end

  if self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2 = table.unpack(self.mouse_selecting)
    local clicks = self.mouse_selecting.clicks
    self.doc:set_selection(mouse_selection(self.doc, clicks, l1, c1, l2, c2))
  end
end


function DocView:on_mouse_released(button)
  DocView.super.on_mouse_released(self, button)
  self.mouse_selecting = nil
end


function DocView:on_text_input(text)
  self.doc:text_input(text)
end


function DocView:update()
  -- scroll to make caret visible and reset blink timer if it moved
  local line, col = self.doc:get_selection()
  if (line ~= self.last_line or col ~= self.last_col) and self.size.x > 0 then
    if core.active_view == self then
      self:scroll_to_make_visible(line, col)
    end
    self.blink_timer = 0
    self.last_line, self.last_col = line, col
  end

  -- update blink timer. Advance by real elapsed time, not a fixed 1/config.fps:
  -- the idle main loop no longer runs update() at the frame rate (it blocks and
  -- wakes ~once per blink half-period), so assuming a full-fps step would make
  -- the caret blink many times too slowly.
  if self == core.active_view and not self.mouse_selecting then
    local n = blink_period / 2
    local prev = self.blink_timer
    local now = system.get_time()
    local dt = self.blink_last and (now - self.blink_last) or (1 / config.fps)
    self.blink_last = now
    self.blink_timer = (self.blink_timer + dt) % blink_period
    if (self.blink_timer > n) ~= (prev > n) then
      core.redraw = true
    end
  else
    self.blink_last = nil
  end

  DocView.super.update(self)
end


function DocView:draw_line_highlight(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
end


function DocView:draw_line_text(idx, x, y)
  local tx, ty = x, y + self:get_line_text_y_offset()
  local font = self:get_font()
  for _, type, text in self.doc.highlighter:each_token(idx) do
    local color = style.syntax[type]
    tx = renderer.draw_text(font, text, tx, ty, color)
  end
  return tx
end


-- Virtual text, and whatever controls the mark carries, drawn past the end of
-- the line.
--
-- All of this is pixels. It is placed with get_col_x_offset, which measures the
-- document's own text, and it never feeds back into it: get_x_offset_col still
-- walks only doc.lines, so there is no column out here for the caret to land
-- on, no selection that can cover it, and no click that resolves into it. The
-- caret stops at the end of the real line and the annotation begins after it.
-- That is the entire reason this is drawn rather than inserted.
function DocView:draw_line_marks(idx, at, x, y)
  local m
  for _, k in ipairs(at) do
    if k.text or (k.data and k.data.revert) then m = k; break end
  end
  if not m then return end

  local font, lh = self:get_font(), self:get_line_height()
  -- The column after the last real character: the trailing newline is part of
  -- the line's text but has no business being measured.
  local bare = #(self.doc.lines[idx]:gsub("\n$", ""))
  local tx = x + self:get_col_x_offset(idx, bare + 1) + style.padding.x

  if m.text then
    renderer.draw_text(font, m.text, tx, y + self:get_line_text_y_offset(), style.dim)
    tx = tx + font:get_width(m.text) + style.padding.x * 0.5
  end

  if m.data and m.data.revert then
    local hover = self.mark_hover
    -- Revert and accept sit side by side: the two answers to "what about this
    -- change?" are a pair, so they are drawn as a pair. Accept is the quieter
    -- of the two -- it only lifts the decoration, never the text -- so it takes
    -- the calm "good" tone against revert's "warn", the same inversion the two
    -- words carry.
    local rw = widgets.width(font, "revert")
    local rect = { x = tx, y = y, w = rw, h = lh }
    widgets.button(font, "revert", tx, y, {
      w = rw, h = lh, tone = style.warn,
      hover = hover and widgets.inside(rect, hover.x, hover.y),
    })
    rect.item = { mark = m, action = "revert" }
    self.mark_hits[#self.mark_hits + 1] = rect
    tx = tx + rw + style.padding.x * 0.5

    local aw = widgets.width(font, "accept")
    local arect = { x = tx, y = y, w = aw, h = lh }
    widgets.button(font, "accept", tx, y, {
      w = aw, h = lh, tone = style.good,
      hover = hover and widgets.inside(arect, hover.x, hover.y),
    })
    arect.item = { mark = m, action = "accept" }
    self.mark_hits[#self.mark_hits + 1] = arect
  end
end


function DocView:draw_line_body(idx, x, y)
  local line, col = self.doc:get_selection()

  -- The mark's wash goes down before anything else, so the selection and the
  -- current-line highlight still read on top of it. A decoration that hides
  -- where the caret is has stopped being a decoration.
  local at = self.mark_store and self.mark_store.by_line[idx]
  if at then
    renderer.draw_rect(x + self.scroll.x, y, self.size.x,
      self:get_line_height(), marks.wash(at[1]))
  end

  -- draw selection if it overlaps this line
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  if idx >= line1 and idx <= line2 then
    local text = self.doc.lines[idx]
    if line1 ~= idx then col1 = 1 end
    if line2 ~= idx then col2 = #text + 1 end
    local x1 = x + self:get_col_x_offset(idx, col1)
    local x2 = x + self:get_col_x_offset(idx, col2)
    local lh = self:get_line_height()
    renderer.draw_rect(x1, y, x2 - x1, lh, style.selection)
  end

  -- draw line highlight if caret is on this line
  if config.highlight_current_line and not self.doc:has_selection()
  and line == idx and core.active_view == self then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  -- draw line's text
  self:draw_line_text(idx, x, y)

  -- ...and the annotations after it
  if at then self:draw_line_marks(idx, at, x, y) end

  -- draw caret if it overlaps this line. In a modal (vim) mode the caret is a
  -- steady block over the character; the usual blinking bar otherwise.
  local shape = core.vim_caret and core.vim_caret(self)
  local block = shape == "block"
  if line == idx and core.active_view == self
  and (block or self.blink_timer < blink_period / 2)
  and system.window_has_focus() then
    local lh = self:get_line_height()
    local x1 = x + self:get_col_x_offset(line, col)
    local w = style.caret_width
    if block then
      w = self:get_col_x_offset(line, col + 1) - self:get_col_x_offset(line, col)
      if w <= 1 then w = self:get_font():get_width(" ") end
    end
    renderer.draw_rect(x1, y, w, lh, style.caret)
  end

  -- modal (vim) overlays: visual-block column + extra multi-cursor carets.
  -- Same coordinate basis as the caret/selection above (plain x).
  if core.vim_overlay then core.vim_overlay(self, idx, x, y) end
end


function DocView:draw_line_gutter(idx, x, y)
  local color = style.line_number
  local line1, _, line2, _ = self.doc:get_selection(true)
  if idx >= line1 and idx <= line2 then
    color = style.line_number2
  end

  -- The sign column lives in the padding the line numbers already leave empty,
  -- so nothing else has to move to make room for it and a file with no marks
  -- looks exactly as it did.
  local at = self.mark_store and self.mark_store.by_line[idx]
  if at then
    local lh = self:get_line_height()
    local w = math.max(2, math.floor(3 * SCALE))
    local sx = x + math.floor(style.padding.x * 0.3)
    renderer.draw_rect(sx, y + 1, w, lh - 2, marks.color(at[1].kind))
    -- Clicking a sign selects the hunk it belongs to: the obvious question
    -- when you see one is "what changed here", and a selection answers it
    -- without the risk a one-click revert would carry.
    self.mark_hits[#self.mark_hits + 1] = {
      x = sx - style.padding.x * 0.3, y = y, w = w + style.padding.x * 0.6, h = lh,
      item = { mark = at[1], action = "select" },
    }
  end

  local yoffset = self:get_line_text_y_offset()
  x = x + style.padding.x
  renderer.draw_text(self:get_font(), idx, x, y + yoffset, color)
end


-- Draw the highlighter tokens of a wrapped row's byte slice [row.s, row.e) at
-- (x, y), clipping each token to the slice and advancing by drawn width (so the
-- whole row costs one measure, not one per token).
function DocView:draw_wrapped_text(row, x, y)
  local font = self:get_font()
  local text = self.doc.lines[row.line]
  local bpos, drawn_x = 1, nil
  for _, type, ttext in self.doc.highlighter:each_token(row.line) do
    local tstart, tend = bpos, bpos + #ttext
    bpos = tend
    if tstart >= row.e then break end
    local a, b = math.max(tstart, row.s), math.min(tend, row.e)
    if b > a then
      local sub = ttext:sub(a - tstart + 1, b - tstart)
      if not drawn_x then drawn_x = x + font:get_width(text:sub(row.s, a - 1)) end
      drawn_x = renderer.draw_text(font, sub, drawn_x, y, style.syntax[type])
    end
  end
end


function DocView:draw()
  self.mark_store = marks.store(self.doc)
  self.mark_hits = {}
  local font = self:get_font()
  font:set_tab_width(font:get_width(" ") * config.indent_size)
  local lh = self:get_line_height()
  local pos = self.position

  if self.wrapping then
    self:draw_background(style.background)
    self:ensure_wrap()
    local rows = self.wrap.rows
    local ox, oy = self:get_content_offset()
    local gw = self:get_gutter_width()
    local yoff = self:get_line_text_y_offset()
    local vmin, vmax = self:get_visible_vrow_range()
    local sl1, sc1, sl2, sc2 = self.doc:get_selection(true)
    local cline, ccol = self.doc:get_selection()

    for v = vmin, vmax do
      local row = rows[v]
      local y = oy + (v - 1) * lh + style.padding.y
      if row.s == 1 then self:draw_line_gutter(row.line, pos.x, y) end
    end

    core.push_clip_rect(pos.x + gw, pos.y, self.size.x, self.size.y)
    for v = vmin, vmax do
      local row = rows[v]
      local text = self.doc.lines[row.line]
      local y = oy + (v - 1) * lh + style.padding.y
      local x0 = ox + gw
      -- selection intersected with this row's byte slice
      if row.line >= sl1 and row.line <= sl2 then
        local c1 = (row.line == sl1) and sc1 or 1
        local c2 = (row.line == sl2) and sc2 or (#text + 1)
        local a, b = math.max(c1, row.s), math.min(c2, row.e)
        if b > a then
          local xa = x0 + font:get_width(text:sub(row.s, a - 1))
          local xb = x0 + font:get_width(text:sub(row.s, b - 1))
          renderer.draw_rect(xa, y, xb - xa, lh, style.selection)
        end
      end
      if config.highlight_current_line and not self.doc:has_selection()
         and cline == row.line and core.active_view == self then
        renderer.draw_rect(x0, y, self.size.x, lh, style.line_highlight)
      end
      self:draw_wrapped_text(row, x0, y + yoff)
      -- caret, only on the visual row that holds it
      if cline == row.line and core.active_view == self
         and (self.blink_timer < blink_period / 2 or (core.vim_caret and core.vim_caret(self) == "block"))
         and system.window_has_focus() and self:vrow_of(cline, ccol) == v then
        local cx = x0 + font:get_width(text:sub(row.s, ccol - 1))
        local w = (core.vim_caret and core.vim_caret(self) == "block")
          and font:get_width(" ") or style.caret_width
        renderer.draw_rect(cx, y, w, lh, style.caret)
      end
    end
    core.pop_clip_rect()
    self:draw_scrollbar()
    return
  end

  self:draw_background(style.background)
  local minline, maxline = self:get_visible_line_range()
  local _, y = self:get_line_screen_position(minline)
  local x = self.position.x
  for i = minline, maxline do
    self:draw_line_gutter(i, x, y)
    y = y + lh
  end

  local x, y = self:get_line_screen_position(minline)
  local gw = self:get_gutter_width()
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x, self.size.y)
  for i = minline, maxline do
    self:draw_line_body(i, x, y)
    y = y + lh
  end
  core.pop_clip_rect()

  self:draw_scrollbar()
end


-- ---------------------------------------------------------------------------
-- Reviewing the agent's changes
-- ---------------------------------------------------------------------------

-- The span of the hunk a mark belongs to. Marks made one at a time have no
-- group and are their own span.
function DocView:mark_span(m)
  if not m or not m.group then return m and m.line, m and m.line end
  local first, last = m.line, m.line
  for _, k in ipairs(marks.all(self.doc)) do
    if k.group == m.group then
      first, last = math.min(first, k.line), math.max(last, k.line)
    end
  end
  return first, last
end


function DocView:select_mark(m)
  local first, last = self:mark_span(m)
  if not first then return end
  last = math.min(last, #self.doc.lines)
  self.doc:set_selection(first, 1, last, #self.doc.lines[last])
  self:scroll_to_line(first, true)
end


function DocView:revert_mark(m)
  local ok, err = marks.revert(self.doc, m)
  if ok then
    core.log("reverted the agent's change at line %d", m.line)
  else
    core.log("cannot revert: %s", err)
  end
  core.redraw = true
end


-- Accept is the calm twin of revert: it keeps the agent's text and only clears
-- the hunk's marks, so it cannot fail on a buffer that has moved on. The line
-- named is the head of the span, taken before the marks go.
function DocView:accept_mark(m)
  local first = self:mark_span(m)
  local ok, err = marks.accept(self.doc, m)
  if ok then
    core.log("kept the agent's change at line %d", first or m.line)
  else
    core.log("cannot accept: %s", err)
  end
  core.redraw = true
end


-- The head mark of the hunk under the caret -- the one carrying the recorded
-- text and the controls -- or nil. Anywhere inside a hunk will do: a mark that
-- is not itself the head is followed to the head of its group, because standing
-- on line four of a six-line change and being told there is nothing here would
-- be a lie. Returns the head (or nil) and the caret line, so the caller can name
-- the line it found nothing on.
function DocView:head_at_caret()
  local line = self.doc:get_selection()
  local here = (marks.get(self.doc, line) or {})[1]
  if not here then return nil, line end
  if here.data and here.data.revert then return here, line end
  if here.group then
    for _, m in ipairs(marks.all(self.doc)) do
      if m.group == here.group and m.data and m.data.revert then return m, line end
    end
  end
  return nil, line
end


-- Walk to the next or previous annotation. `dir` is 1 or -1.
function DocView:goto_mark(dir)
  local line = self.doc:get_selection()
  -- Spelled out rather than folded into an and/or: `next` returning nil would
  -- otherwise fall through and search backwards instead.
  local at
  if dir > 0 then at = marks.next(self.doc, line)
  else at = marks.prev(self.doc, line) end
  if not at then
    core.log("no agent changes in this file")
    return
  end
  self.doc:set_selection(at, 1)
  self:scroll_to_line(at, false, true)
end


-- The caret-driven hunk actions, shared by their command names below. Each
-- finds the head of the hunk under the caret and hands it to the matching
-- view method; a caret sitting on no hunk is told so, on the line it is on.
local function accept_at_caret()
  local dv = core.active_view
  local found, line = dv:head_at_caret()
  if not found then
    core.log("no agent change to accept at line %d", line)
    return
  end
  dv:accept_mark(found)
end

local function revert_at_caret()
  local dv = core.active_view
  local found, line = dv:head_at_caret()
  if not found then
    core.log("no agent change to revert at line %d", line)
    return
  end
  dv:revert_mark(found)
end


-- These are registered here rather than in core/commands/doc.lua because they
-- are the view's, not the document's: walking to the next annotation is a thing
-- you do to a buffer you are looking at, and the drawing and the navigation
-- should not be able to drift into two different files.
--
-- marks:next / marks:prev are the plain names the keymap binds. The older
-- -change / -hunk spellings are kept beside them so that nothing already
-- reaching for one -- keymap.lua binds alt+n/alt+p/alt+r to them -- breaks.
command.add(DocView, {
  ["marks:next"] = function() core.active_view:goto_mark(1) end,
  ["marks:prev"] = function() core.active_view:goto_mark(-1) end,
  ["marks:next-change"] = function() core.active_view:goto_mark(1) end,
  ["marks:previous-change"] = function() core.active_view:goto_mark(-1) end,

  ["marks:accept-hunk"] = accept_at_caret,
  ["marks:revert-hunk"] = revert_at_caret,
  ["marks:revert-change"] = revert_at_caret,

  ["marks:accept-all"] = function()
    local n = marks.accept_all(core.active_view.doc)
    core.log("kept %d agent mark%s", n, n == 1 and "" or "s")
    core.redraw = true
  end,

  -- Revert-all refuses per hunk exactly as the button does: a hunk the buffer
  -- has been edited on is counted among those left, never overwritten.
  ["marks:revert-all"] = function()
    local done, refused = marks.revert_all(core.active_view.doc)
    if refused > 0 then
      core.log("reverted %d change%s; left %d the buffer has changed since",
        done, done == 1 and "" or "s", refused)
    else
      core.log("reverted %d agent change%s", done, done == 1 and "" or "s")
    end
    core.redraw = true
  end,

  ["marks:clear-changes"] = function()
    local n = marks.clear(core.active_view.doc)
    core.log("cleared %d agent mark%s", n, n == 1 and "" or "s")
    core.redraw = true
  end,
})


-- The bindings live here, next to the commands they name, for the same reason
-- the commands do: a chord and the thing it runs should not be able to drift
-- into two files. alt+down / alt+up are free -- the arrows are spoken for under
-- ctrl and shift but never under alt -- and "down to the next change, up to the
-- previous" is the direction the eye already reads a diff in. alt+n / alt+p in
-- keymap.lua reach the same jump under the older marks:*-change names.
command.add(DocView, {
  -- Soft-wrap toggle, per view. Wrapping never scrolls sideways, so reset the
  -- horizontal scroll when turning it on.
  ["doc:toggle-line-wrapping"] = function()
    local dv = core.active_view
    dv.wrapping = not dv.wrapping
    dv.wrap = nil
    if dv.wrapping then dv.scroll.to.x, dv.scroll.x = 0, 0 end
    core.log("line wrapping %s", dv.wrapping and "on" or "off")
    core.redraw = true
  end,
})


keymap.add {
  ["alt+down"] = "marks:next",
  ["alt+up"] = "marks:prev",
  ["alt+z"] = "doc:toggle-line-wrapping",
}


return DocView
