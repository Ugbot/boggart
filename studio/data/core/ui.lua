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
local common = require "core.common"

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

-- Truncate `text` to `width` with a trailing ellipsis. UTF-8-safe, and safe on
-- text that is not valid UTF-8 at all (a stored credential can be anything).
-- Was hand-copied into settingsview and welcomeview; one home now.
function ui.elide(font, text, width)
  if font:get_width(text) <= width then return text end
  local n = utf8.len(text)
  local function upto(chars)
    if n then return text:sub(1, (utf8.offset(text, chars + 1) or (#text + 1)) - 1) end
    local i = math.min(chars, #text)
    while i > 0 and common.is_utf8_cont(text:sub(i + 1, i + 1)) do i = i - 1 end
    return text:sub(1, i)
  end
  local lo, hi = 0, n or #text
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:get_width(upto(mid) .. "...") <= width then lo = mid else hi = mid - 1 end
  end
  return upto(lo) .. "..."
end

-- ---------------------------------------------------------------------------
-- ui.textfield -- one single-line editable field
-- ---------------------------------------------------------------------------
--
-- settingsview / welcomeview / the sidebar search / the file picker each rolled
-- their own: a plain string appended to on input and trimmed from the END on
-- backspace, with no caret, no arrows, and no paste -- so pasting a key or fixing
-- a typo mid-string was impossible, and each got a slightly different subset of
-- UTF-8 right. This is the one implementation: a caret (a byte offset into text),
-- UTF-8-safe insert/delete, word-delete, Home/End, arrows, and clipboard paste.
-- A view holds one and forwards on_text_input -> :input and on_key_pressed -> :key.
local TextField = {}
TextField.__index = TextField

function ui.textfield(text)
  return setmetatable({ text = text or "", caret = #(text or "") }, TextField)
end

-- Byte offset of the codepoint boundary before / after `i`.
local function prev_cp(s, i)
  if i <= 0 then return 0 end
  i = i - 1
  while i > 0 and common.is_utf8_cont(s:sub(i + 1, i + 1)) do i = i - 1 end
  return i
end
local function next_cp(s, i)
  local len = #s
  if i >= len then return len end
  i = i + 1
  while i < len and common.is_utf8_cont(s:sub(i + 1, i + 1)) do i = i + 1 end
  return i
end

-- Replace the whole value (and drop the caret at the end), for a view seeding
-- the field from stored state.
function TextField:set(text)
  self.text = text or ""
  self.caret = #self.text
  return self
end

function TextField:value() return self.text end

function TextField:input(t)
  t = tostring(t or ""):gsub("[\n\r]", "")
  if t == "" then return end
  self.text = self.text:sub(1, self.caret) .. t .. self.text:sub(self.caret + 1)
  self.caret = self.caret + #t
end

-- Handle an editing key; returns true if it consumed it (so the view knows to
-- redraw and stop). Non-editing keys (escape/return/tab) are the view's own.
function TextField:key(k)
  local text, caret = self.text, self.caret
  if k == "backspace" then
    if caret > 0 then
      local p = prev_cp(text, caret)
      self.text, self.caret = text:sub(1, p) .. text:sub(caret + 1), p
    end
  elseif k == "delete" then
    if caret < #text then
      local nx = next_cp(text, caret)
      self.text = text:sub(1, caret) .. text:sub(nx + 1)
    end
  elseif k == "ctrl+backspace" then
    local i = caret
    while i > 0 and text:sub(i, i):match("%s") do i = prev_cp(text, i) end
    while i > 0 and not text:sub(i, i):match("%s") do i = prev_cp(text, i) end
    self.text, self.caret = text:sub(1, i) .. text:sub(caret + 1), i
  elseif k == "left" then self.caret = prev_cp(text, caret)
  elseif k == "right" then self.caret = next_cp(text, caret)
  elseif k == "home" or k == "ctrl+a" then self.caret = 0
  elseif k == "end" or k == "ctrl+e" then self.caret = #text
  elseif k == "ctrl+v" or k == "cmd+v" then
    local ok, clip = pcall(system.get_clipboard)
    self:input(ok and clip or "")
  else
    return false
  end
  return true
end

-- Draw the field's text and caret at (x, y), elided to `width`. Returns nothing;
-- the view owns the box/background. `focused` draws the caret.
function ui.draw_field(font, field, x, y, w, h, color, focused)
  local text = field.text
  local before = text:sub(1, field.caret)
  local shown = ui.elide(font, text, w)
  local voff = (h - font:get_height()) / 2
  renderer.draw_text(font, shown, x, y + voff, color or style.text)
  if focused then
    -- Caret at the caret offset, clamped into the box so it stays visible even
    -- when the text is elided.
    local cx = math.min(x + font:get_width(before), x + w - 1)
    renderer.draw_rect(cx, y + voff, math.max(1, SCALE), font:get_height(), style.caret or color or style.text)
  end
end

return ui
