-- widgets.lua -- buttons, for a UI that is not only a text editor.
--
-- The editor core this app grew out of has no widget layer at all: it is a
-- text editor, and a text editor's entire interface is a keymap and a command
-- palette. That is a coherent position for an editor and the wrong one for a
-- chat application, where the person using it should be able to see what they
-- can do without first learning the names of the commands.
--
-- So: buttons. Deliberately the smallest thing that deserves the name -- a
-- label, a rect, a hover state, and a callback. There is no widget tree, no
-- layout engine and no event bubbling, because a row of buttons does not need
-- any of that and every one of them would be a thing to maintain forever.
--
-- The caller owns layout and hit-testing state. Draw a button, get its rect
-- back, keep the rects in a list, and hand mouse events to widgets.hit.
local style = require "core.style"
local common = require "core.common"

local widgets = {}

widgets.PAD_X = 0.55   -- horizontal padding, in multiples of style.padding.x
widgets.GAP   = 0.4    -- gap between buttons, likewise

function widgets.height(font)
  return font:get_height() + style.padding.y * 1.6
end

function widgets.width(font, label)
  return font:get_width(label) + style.padding.x * widgets.PAD_X * 2
end

-- Draw one button and return its rect: x, y, w, h.
--
-- opts.active marks a toggled-on state (accent fill), opts.hover a pointer
-- over it, opts.dim a button that is present but not currently useful --
-- shown rather than hidden, because a control that disappears is a control
-- you have to rediscover.
function widgets.button(font, label, x, y, opts)
  opts = opts or {}
  local w = opts.w or widgets.width(font, label)
  local h = opts.h or widgets.height(font)

  local bg = style.background2
  if opts.active then bg = style.accent
  elseif opts.hover and not opts.dim then bg = style.line_highlight end
  renderer.draw_rect(x, y, w, h, bg)

  local fg = style.text
  if opts.active then fg = style.background
  elseif opts.dim then fg = style.dim
  elseif opts.tone then fg = opts.tone end
  -- Centred by default because a row of pills reads better that way; the
  -- sidebar asks for "left", where a column of left-aligned labels reads as a
  -- list rather than a row of buttons that happen to be stacked.
  local ax = x
  if opts.align == "left" then ax = x + style.padding.x * widgets.PAD_X end
  common.draw_text(font, fg, label, opts.align or "center", ax, y,
    w - (opts.align == "left" and style.padding.x * widgets.PAD_X or 0), h)

  return { x = x, y = y, w = w, h = h }
end

-- Lay a row of buttons left to right, wrapping is not attempted: a row that
-- does not fit is clipped, which is honest and keeps this trivial.
--
-- `items` is a list of { label, command|action, active?, dim?, tone? }.
-- `limit` is an optional right edge: a button that would cross it is dropped
-- rather than drawn. Clipping at the edge of a *view* is fine -- you can widen
-- the window -- but a row that runs under a neighbouring button leaves two
-- controls stacked on the same pixels, and the hit test then answers with
-- whichever was registered first.
-- Returns the list of hit rects, each carrying its item.
function widgets.row(font, items, x, y, hover, limit)
  local gap = style.padding.x * widgets.GAP
  local hits = {}
  for _, it in ipairs(items) do
    local w = widgets.width(font, it.label)
    if limit and x + w > limit then break end
    local is_hover = hover and hover.x and widgets.inside(
      { x = x, y = y, w = w, h = widgets.height(font) }, hover.x, hover.y)
    local r = widgets.button(font, it.label, x, y, {
      w = w, active = it.active, dim = it.dim, tone = it.tone, hover = is_hover,
    })
    r.item = it
    hits[#hits + 1] = r
    x = x + w + gap
  end
  return hits
end

function widgets.inside(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Find the item under a point, if any.
function widgets.hit(hits, x, y)
  for _, r in ipairs(hits or {}) do
    if widgets.inside(r, x, y) then return r.item, r end
  end
end

return widgets
