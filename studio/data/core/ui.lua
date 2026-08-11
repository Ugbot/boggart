-- ui.lua -- named, composable styles for the studio's own widgets.
--
-- Taken from TypeStyle's good idea, which is not caching: it is that a style
-- should be a *value* you can name, compose and pass around, instead of six
-- lines of colour-and-padding arithmetic repeated in every draw function. The
-- app now has a chat panel, a sidebar, a settings form, a workflow builder, a
-- library and agent-written panels, and "make the buttons slightly tighter"
-- currently means editing all of them.
--
-- On performance, honestly: this is not an optimisation. Measured on a
-- 400-entry transcript, a full draw() costs 0.53 ms of a 16.6 ms frame, of
-- which text measurement is 28 calls at 0.05 us each -- about 1.4 microseconds.
-- Memoising that would be optimising nothing. What actually carries the frame
-- rate is the per-entry layout cache in agentview.lua (21.7 ms cold, 0.04 ms
-- warm, 559x) and the fact that drawing clips to the viewport rather than the
-- transcript. Those are the invariants worth protecting, and tools/uibench.lua
-- fails the build if they regress.
--
-- So the rule here is "must not become a cost", not "makes it faster":
--   * resolution is cached by table identity, so a derive() in a draw loop
--     returns the same table every frame rather than allocating one;
--   * nothing here allocates per frame if you follow that discipline;
--   * metrics are computed once per font.
-- The discipline it asks of callers is the same one TypeStyle asks: declare
-- your styles once, at the top of the module, not inside the loop. A style
-- built inline every frame defeats the cache and allocates -- so `ui.derive`
-- says so out loud the first time it sees a table it has not seen before too
-- many times.
local style = require "core.style"
local config = require "core.config"

local ui = {}

-- ---------------------------------------------------------------------------
-- Metrics
-- ---------------------------------------------------------------------------
--
-- Everything a widget needs to lay itself out, computed once per font. Fonts
-- are rebuilt when the scale changes, so keying on the font object is enough --
-- a new scale means a new font means a new entry, and the old one falls out
-- with the font.

local metrics_cache = setmetatable({}, { __mode = "k" })

function ui.metrics(font)
  font = font or style.code_font
  local m = metrics_cache[font]
  if m then return m end
  local h = font:get_height()
  m = {
    height      = h,
    line_height = h * config.line_height,
    char_width  = font:get_width("0"),   -- meaningful for the monospace fonts
    button      = h + style.padding.y * 1.6,
    pad_x       = style.padding.x,
    pad_y       = style.padding.y,
  }
  metrics_cache[font] = m
  return m
end

-- ---------------------------------------------------------------------------
-- Styles
-- ---------------------------------------------------------------------------
--
-- A style is a plain table. Colours are the theme's tables (style.text and
-- friends), so a style holds a reference and follows a theme change rather
-- than copying a colour and going stale.

-- derive(base, override) -> a merged style, the same table every time.
--
-- Cached on the identity of both arguments, which is what makes it free in a
-- draw loop -- and what requires the override to be a constant. Pass a literal
-- and you get a new table, a new cache entry, and a slow leak; hence the
-- warning below, which fires once rather than every frame because a warning
-- inside a draw loop is its own denial of service.
local derive_cache = setmetatable({}, { __mode = "k" })
local derive_count = setmetatable({}, { __mode = "k" })
local warned = false

function ui.derive(base, override)
  if not override then return base end
  local by_base = derive_cache[base]
  if not by_base then
    by_base = setmetatable({}, { __mode = "k" })
    derive_cache[base] = by_base
  end
  local hit = by_base[override]
  if hit then return hit end

  local n = (derive_count[base] or 0) + 1
  derive_count[base] = n
  if n > 64 and not warned then
    warned = true
    local core = require "core"
    core.log("ui.derive has seen 64+ distinct overrides for one style -- "
      .. "a style built inline in a draw loop will not cache")
  end

  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(override) do out[k] = v end
  by_base[override] = out
  return out
end

-- The studio's vocabulary. Every widget draws from one of these, so the look
-- of the application has one definition.
ui.styles = {
  button = {
    bg = style.background2, fg = style.text,
    pad_x = 0.55,          -- multiples of style.padding.x
    align = "center",
  },
  button_hover  = { bg = style.line_highlight },
  button_active = { bg = style.accent, fg = style.background },
  button_dim    = { fg = style.dim },
  button_left   = { align = "left" },

  panel   = { bg = style.background2, fg = style.text },
  field   = { bg = style.background2, fg = style.text, border = style.divider },
  field_focused = { border = style.accent },

  bubble  = { bg = style.selection, fg = style.text },
  code    = { bg = style.background2, fg = style.text },
  notice  = { fg = style.dim },
  danger  = { fg = style.error },
  success = { fg = style.good },
}

-- Draw a box with an optional one-pixel border, which is the shape almost
-- every widget in the app starts from.
function ui.box(s, x, y, w, h)
  if s.bg then renderer.draw_rect(x, y, w, h, s.bg) end
  if s.border then
    local t = math.max(1, SCALE)
    renderer.draw_rect(x, y, w, t, s.border)
    renderer.draw_rect(x, y + h - t, w, t, s.border)
    renderer.draw_rect(x, y, t, h, s.border)
    renderer.draw_rect(x + w - t, y, t, h, s.border)
  end
end

return ui
