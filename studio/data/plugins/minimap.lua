-- minimap.lua -- the code-shape silhouette: one rect per line, no glyphs.
--
-- A minimap earns its keep by showing the SHAPE of the file -- indent rhythm,
-- block sizes, where the long lines are -- and shape needs no font. Each line
-- is a single rect whose width tracks its character count; blank lines leave a
-- gap so the silhouette breathes. That keeps the whole strip at one draw call
-- per visible row and makes it cheap enough to redraw with every frame the
-- rencache already repaints.
--
-- Long files scroll the strip like a second scrollbar: when the document has
-- more lines than the strip has rows, the window into it tracks the view's own
-- scroll fraction, so the translucent viewport box always sits under the
-- pointer where you expect it. Click to jump; the box follows.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"

config.minimap = true
config.minimap_width = 80

local ROW_COLOR   = { style.dim[1], style.dim[2], style.dim[3], 120 }
local BLANK_COLOR = { style.dim[1], style.dim[2], style.dim[3], 46 }
local VIEW_COLOR  = { style.accent[1], style.accent[2], style.accent[3], 22 }

local function strip_rect(self)
  local w = math.floor(config.minimap_width * SCALE)
  local x = self.position.x + self.size.x - style.scrollbar_size - w
  return x, self.position.y, w, self.size.y
end

-- The geometry shared by drawing and hit-testing: pixels per row, how many
-- rows fit, and which document line the strip starts at.
local function geometry(self)
  local _, _, _, h = strip_rect(self)
  local count = #self.doc.lines
  local plh = math.max(1, math.min(math.floor(2.5 * SCALE), h / count))
  local rows = math.floor(h / plh)
  local first = 1
  if count > rows then
    local range = self:get_scrollable_size() - self.size.y
    local frac = range > 0 and math.max(0, math.min(1, self.scroll.y / range)) or 0
    first = math.floor(frac * (count - rows)) + 1
  end
  return plh, rows, first, count
end

local function wide_enough(self)
  return self.size.x >= 300 * SCALE
end

local draw = DocView.draw
function DocView:draw()
  draw(self)
  if not config.minimap or not wide_enough(self) then return end
  local x, y, w, h = strip_rect(self)
  local plh, rows, first, count = geometry(self)
  renderer.draw_rect(x, y, w, h, style.background2)

  -- ~120 columns spans the strip; anything longer saturates. Byte length is
  -- close enough to character count for a silhouette.
  local cw = (w - 2) / 120
  local last = math.min(count, first + rows - 1)
  for i = first, last do
    local ry = y + (i - first) * plh
    local n = #self.doc.lines[i] - 1
    if n <= 0 then
      renderer.draw_rect(x + 1, ry, math.floor(4 * SCALE), math.max(1, plh - 1), BLANK_COLOR)
    else
      local rw = math.max(2, math.min(w - 2, math.floor(n * cw)))
      renderer.draw_rect(x + 1, ry, rw, math.max(1, plh - 1), ROW_COLOR)
    end
  end

  -- The viewport box: the lines currently on screen, in strip coordinates.
  local minline, maxline = self:get_visible_line_range()
  local vy = y + (minline - first) * plh
  local vh = math.max(plh, (maxline - minline + 1) * plh)
  if vy < y + h and vy + vh > y then
    renderer.draw_rect(x, math.max(y, vy), w, math.min(vh, y + h - vy), VIEW_COLOR)
  end
end

local function hit_strip(self, px, py)
  if not config.minimap or not wide_enough(self) then return nil end
  local x, y, w, h = strip_rect(self)
  if px < x or px >= x + w or py < y or py >= y + h then return nil end
  local plh, _, first = geometry(self)
  return math.max(1, math.min(#self.doc.lines,
    first + math.floor((py - y) / plh)))
end

local on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" then
    local line = hit_strip(self, x, y)
    if line then
      self:scroll_to_line(line, false, true)
      return
    end
  end
  return on_mouse_pressed(self, button, x, y, clicks)
end

local on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  on_mouse_moved(self, x, y, ...)
  if hit_strip(self, x, y) then self.cursor = "arrow" end
end

command.add("core.docview", {
  ["minimap:toggle"] = function()
    config.minimap = not config.minimap
    core.log("minimap: %s", config.minimap and "on" or "off")
  end,
})

return {}
