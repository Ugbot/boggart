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
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
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


function DocView:get_scrollable_size()
  return self:get_line_height() * (#self.doc.lines - 1) + self.size.y
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


function DocView:get_line_screen_position(idx)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
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
  local minline = math.max(1, math.floor(y / lh))
  local maxline = math.min(#self.doc.lines, math.floor(y2 / lh) + 1)
  return minline, maxline
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
  local min = self:get_line_height() * (line - 1)
  local max = self:get_line_height() * (line + 2) - self.size.y
  self.scroll.to.y = math.min(self.scroll.to.y, min)
  self.scroll.to.y = math.max(self.scroll.to.y, max)
  local gw = self:get_gutter_width()
  local xoffset = self:get_col_x_offset(line, col)
  local max = xoffset - self.size.x + gw + self.size.x / 5
  self.scroll.to.x = math.max(0, max)
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

  -- update blink timer
  if self == core.active_view and not self.mouse_selecting then
    local n = blink_period / 2
    local prev = self.blink_timer
    self.blink_timer = (self.blink_timer + 1 / config.fps) % blink_period
    if (self.blink_timer > n) ~= (prev > n) then
      core.redraw = true
    end
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
    local w = widgets.width(font, "revert")
    local hover = self.mark_hover
    local rect = { x = tx, y = y, w = w, h = lh }
    widgets.button(font, "revert", tx, y, {
      w = w, h = lh, tone = style.warn,
      hover = hover and widgets.inside(rect, hover.x, hover.y),
    })
    rect.item = { mark = m, action = "revert" }
    self.mark_hits[#self.mark_hits + 1] = rect
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


function DocView:draw()
  self:draw_background(style.background)

  local font = self:get_font()
  font:set_tab_width(font:get_width(" ") * config.indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  -- Once a frame, not once a line: resolving the store is a couple of table
  -- lookups, and from here on a mark costs one hash probe per visible line.
  -- A ten-thousand-line file with ten thousand marks draws the same forty the
  -- window can show and never touches the rest.
  self.mark_store = marks.store(self.doc)
  self.mark_hits = {}

  local _, y = self:get_line_screen_position(minline)
  local x = self.position.x
  for i = minline, maxline do
    self:draw_line_gutter(i, x, y)
    y = y + lh
  end

  local x, y = self:get_line_screen_position(minline)
  local gw = self:get_gutter_width()
  local pos = self.position
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


-- These are registered here rather than in core/commands/doc.lua because they
-- are the view's, not the document's: walking to the next annotation is a thing
-- you do to a buffer you are looking at, and the drawing and the navigation
-- should not be able to drift into two different files.
command.add(DocView, {
  ["marks:next-change"] = function() core.active_view:goto_mark(1) end,
  ["marks:previous-change"] = function() core.active_view:goto_mark(-1) end,

  ["marks:revert-change"] = function()
    local dv = core.active_view
    local line = dv.doc:get_selection()
    -- Anywhere inside a hunk will do: find the mark under the caret, then the
    -- head of its group, which is the one carrying the recorded text. Standing
    -- on line four of a six-line change and being told there is nothing to
    -- revert would be a lie.
    local here = (marks.get(dv.doc, line) or {})[1]
    local found
    if here then
      if here.data and here.data.revert then
        found = here
      elseif here.group then
        for _, m in ipairs(marks.all(dv.doc)) do
          if m.group == here.group and m.data and m.data.revert then found = m end
        end
      end
    end
    if not found then
      core.log("no agent change to revert at line %d", line)
      return
    end
    dv:revert_mark(found)
  end,

  ["marks:clear-changes"] = function()
    local n = marks.clear(core.active_view.doc)
    core.log("cleared %d agent mark%s", n, n == 1 and "" or "s")
    core.redraw = true
  end,
})


return DocView
