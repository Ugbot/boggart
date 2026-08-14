-- tui/input.lua -- the input-line editor for the full-screen cTUI (Contract C).
--
-- A line editor driven by `tc` key events. It is the terminal-input twin of the
-- isocline line in the scrolling REPL: same completion policy (bog.complete on
-- Tab) and the same highlighter policy (bog.repl_style for colour), so the two
-- surfaces edit and colour a line from one source of truth rather than two that
-- drift.
--
-- It is deliberately PURE state + logic. It does NO terminal control of its own:
-- no cursor moves, no clearing, no reads, no writes, no global state. You feed it
-- one decoded key event at a time (Contract A shape -- see below) and it mutates
-- its own fields; when you want to draw it you ask for styled runs (Contract B
-- shape) which the cTUI layout blits wherever the input line lives. That keeps
-- the frame owner (sched.lua's one-paint-per-iteration loop) in charge of the
-- terminal, exactly as termctl.h's ownership model requires.
--
-- Contract A -- the key event this consumes is the Lua projection of a C tc_event
-- (src/termctl.h). The fields it reads:
--   ev.key  : a logical-key name -- "char", "enter", "tab", "backspace",
--             "delete", "left", "right", "home", "end", "up", "down", "esc",
--             "ctrl".
--   ev.char : for key=="char", the printable character (a UTF-8 string, possibly
--             multibyte); for key=="ctrl", the control letter ("c", ...).
-- Anything else is ignored (returns nil), so a RESIZE or a key the editor does
-- not bind never disturbs the line.
--
-- Contract B -- a styled run is { text=, fg=, bg=, attr= }: text is a UTF-8
-- slice, fg/bg are "#rrggbb" hexes (or nil for the terminal default), attr is a
-- reserved attribute field (nil here). :runs returns the prompt run followed by
-- the coloured text runs.
local M = {}
local Input = {}
Input.__index = Input

-- The prompt. Two display columns; it leads every drawn line and every reported
-- cursor column is measured from its start.
local PROMPT = "> "

-- bog.repl_style's named styles -> run foreground hexes. These echo the studio /
-- termrender palette: good/green for a known command, error/red for an unknown
-- one, link/blue for an @file reference. A style we do not know maps to nil,
-- i.e. the terminal default -- never a raise.
local STYLE_FG = {
  ["bog-cmd"]  = "#7fb77e",   -- a known /command
  ["bog-bad"]  = "#f77483",   -- an unknown /command, flagged before Enter
  ["bog-file"] = "#93ddfa",   -- an @file reference
}

-- ---- utf8 helpers ----------------------------------------------------------
-- The line is stored as a UTF-8 byte string; the cursor is a *codepoint* index
-- (0 == before the first character), so a move or a delete never splits a
-- multibyte character. Display width approximates one column per codepoint --
-- the same "a cell is a codepoint" simplification termrender.lua documents,
-- exact for the Latin/command text a prompt mostly shows.

-- Number of codepoints in s.
local function ulen(s)
  return (utf8 and utf8.len(s)) or #s
end

-- 1-based byte offset at which codepoint index i (0-based) begins. i == ulen(s)
-- returns one past the end, so a slice line:sub(1, byteat(s, i) - 1) is the text
-- before the cursor.
local function byteat(s, i)
  if i <= 0 then return 1 end
  if not utf8 then return math.min(i, #s) + 1 end
  return utf8.offset(s, i + 1) or (#s + 1)
end

-- Trim a byte string back to the nearest valid UTF-8 boundary, so a byte-wise
-- longest-common-prefix that happened to cut mid-character is never returned.
local function utf8_trim(s)
  if not utf8 then return s end
  while #s > 0 and not utf8.len(s) do s = s:sub(1, #s - 1) end
  return s
end

-- A guarded call into a policy global (bog.complete / bog.repl_style): these run
-- inside a keystroke and must never raise on a bad line, so a failure degrades
-- to nil exactly as complete.lua's own `safe` does.
local function safe(fn, arg)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, arg)
  return ok and v or nil
end

-- ---- construction ----------------------------------------------------------
-- new{ history = { "prev line", ... } } -- history is optional and copied, so
-- this session's submissions extend our own list without mutating the caller's.
function M.new(opts)
  opts = opts or {}
  local hist = {}
  for _, h in ipairs(opts.history or {}) do hist[#hist + 1] = tostring(h) end
  local self = setmetatable({
    line    = "",     -- current text (UTF-8)
    cursor  = 0,      -- cursor position, in codepoints from the start
    history = hist,   -- seeded history + this session's submissions
    prompt  = opts.prompt or PROMPT,
    _hpos   = nil,    -- history cursor while navigating; nil == editing live
    _draft  = nil,    -- the live line stashed when history navigation began
  }, Input)
  return self
end

-- ---- editing primitives ----------------------------------------------------
-- Each mutates self.line / self.cursor and leaves history navigation as it found
-- it (an edit detaches from a recalled entry only implicitly -- the recalled
-- text simply becomes the working line).

function Input:_insert(str)
  if str == nil or str == "" then return end
  local bp = byteat(self.line, self.cursor)
  self.line = self.line:sub(1, bp - 1) .. str .. self.line:sub(bp)
  self.cursor = self.cursor + ulen(str)
end

function Input:_backspace()
  if self.cursor <= 0 then return end
  local a = byteat(self.line, self.cursor - 1)
  local b = byteat(self.line, self.cursor)
  self.line = self.line:sub(1, a - 1) .. self.line:sub(b)
  self.cursor = self.cursor - 1
end

function Input:_delete()
  local n = ulen(self.line)
  if self.cursor >= n then return end
  local a = byteat(self.line, self.cursor)
  local b = byteat(self.line, self.cursor + 1)
  self.line = self.line:sub(1, a - 1) .. self.line:sub(b)
end

function Input:_set(text)
  self.line = text or ""
  self.cursor = ulen(self.line)
end

-- ---- history ---------------------------------------------------------------
-- Up walks toward older entries, Down toward newer; stepping past the newest
-- restores the draft that was being typed when navigation started. Empty history
-- is a no-op, so Up on a fresh box does nothing.
function Input:_history_up()
  local n = #self.history
  if n == 0 then return end
  if self._hpos == nil then
    self._draft = self.line
    self._hpos = n
  elseif self._hpos > 1 then
    self._hpos = self._hpos - 1
  end
  self:_set(self.history[self._hpos])
end

function Input:_history_down()
  if self._hpos == nil then return end
  if self._hpos < #self.history then
    self._hpos = self._hpos + 1
    self:_set(self.history[self._hpos])
  else
    self._hpos = nil
    self:_set(self._draft or "")
    self._draft = nil
  end
end

function Input:_reset_history()
  self._hpos, self._draft = nil, nil
end

-- ---- completion ------------------------------------------------------------
-- Longest common byte prefix of the items' texts, trimmed to a UTF-8 boundary.
local function common_prefix(items)
  local first = items[1].text or ""
  local n = #first
  for i = 2, #items do
    local t = items[i].text or ""
    local m, k = math.min(n, #t), 0
    while k < m and first:byte(k + 1) == t:byte(k + 1) do k = k + 1 end
    n = k
    if n == 0 then break end
  end
  return utf8_trim(first:sub(1, n))
end

-- Tab: ask bog.complete about the text up to the cursor and rewrite the trailing
-- word. bog.complete returns { {text=, display?, help?}, ... }, each text a
-- full-token replacement for that word (complete.lua's contract). One item
-- replaces the word outright; several insert their longest common prefix (only
-- when it actually extends the word); none does nothing.
function Input:_complete()
  local bp = byteat(self.line, self.cursor)
  local head = self.line:sub(1, bp - 1)          -- text left of the cursor
  local tail = self.line:sub(bp)                 -- text right of it, preserved
  local items = safe(bog.complete, head)
  if type(items) ~= "table" or #items == 0 then return end

  -- The current word is the trailing run of non-space, exactly what complete.lua
  -- treats as replaceable, so a returned text swaps in cleanly.
  local word = head:match("(%S*)$") or ""
  local repl
  if #items == 1 then
    repl = items[1].text
  else
    local lcp = common_prefix(items)
    if #lcp > #word then repl = lcp end          -- only if it adds something
  end
  if not repl then return end

  local newhead = head:sub(1, #head - #word) .. repl
  self.line = newhead .. tail
  self.cursor = ulen(newhead)
end

-- ---- the key handler -------------------------------------------------------
-- key(ev) -> action, value
--   "submit", line  -- Enter: the line is returned, then cleared and pushed to
--                      history.
--   "cancel", nil   -- Ctrl-C, or Esc on an empty line.
--   nil             -- edited in place (or the key was not bound).
function Input:key(ev)
  if type(ev) ~= "table" then return nil end
  local k = ev.key

  if k == "char" then
    self:_insert(ev.char)

  elseif k == "backspace" then
    self:_backspace()
  elseif k == "delete" or k == "del" then
    self:_delete()

  elseif k == "left" then
    if self.cursor > 0 then self.cursor = self.cursor - 1 end
  elseif k == "right" then
    if self.cursor < ulen(self.line) then self.cursor = self.cursor + 1 end
  elseif k == "home" then
    self.cursor = 0
  elseif k == "end" then
    self.cursor = ulen(self.line)

  elseif k == "up" then
    self:_history_up()
  elseif k == "down" then
    self:_history_down()

  elseif k == "tab" then
    self:_complete()

  elseif k == "enter" then
    local value = self.line
    if value ~= "" then self.history[#self.history + 1] = value end
    self.line, self.cursor = "", 0
    self:_reset_history()
    return "submit", value

  elseif k == "ctrl" and ev.char == "c" then
    return "cancel", nil

  elseif k == "esc" or k == "escape" then
    -- Esc cancels only an empty line; on a non-empty line it clears the input
    -- (edited in place) so a mistaken line is dropped without leaving the mode.
    if self.line == "" then return "cancel", nil end
    self.line, self.cursor = "", 0
    self:_reset_history()
  end

  return nil
end

-- ---- rendering -------------------------------------------------------------
-- The whole line as per-codepoint { ch, fg } cells, coloured by bog.repl_style.
-- repl_style returns byte-offset spans { {pos (0-based), len, style}, ... }; a
-- codepoint takes the foreground of the first span covering its starting byte,
-- else nil (the default). Reconstructing per codepoint keeps the join exact:
-- concatenating every cell's ch reproduces self.line byte-for-byte.
function Input:_cells()
  local line = self.line
  local spans = safe(bog.repl_style, line) or {}
  local function fg_at(b)          -- b: 0-based byte offset
    for _, sp in ipairs(spans) do
      local pos, len = sp.pos, sp.len
      if pos and len and b >= pos and b < pos + len then
        return STYLE_FG[sp.style]
      end
    end
    return nil
  end

  local cells = {}
  if utf8 then
    for bytepos, cp in utf8.codes(line) do
      cells[#cells + 1] = { ch = utf8.char(cp), fg = fg_at(bytepos - 1) }
    end
  else
    for i = 1, #line do
      cells[#cells + 1] = { ch = line:sub(i, i), fg = fg_at(i - 1) }
    end
  end
  return cells
end

-- runs(width) -> line_runs, cursor_col
--   line_runs  : Contract B runs { text, fg, bg, attr }, the prompt run first
--                then the coloured text; adjacent same-colour cells coalesce.
--   cursor_col : the display column of the cursor, measured from the prompt's
--                start (prompt width + codepoints left of the cursor).
-- width, when given and exceeded, scrolls the text horizontally so the cursor
-- stays visible; the prompt is always shown. When everything fits (the common
-- case) there is no scroll and the text runs join to exactly self.line.
function Input:runs(width)
  local cells = self:_cells()
  local total = #cells
  local pw = ulen(self.prompt)

  -- The window over the text, in codepoint columns. avail is how many text
  -- columns remain beside the prompt; nil means unlimited (no clipping).
  local avail = (width and width > pw) and (width - pw) or nil
  local start = 0                        -- first visible text codepoint
  if avail and total > avail then
    if self.cursor > avail then start = self.cursor - avail end
    if start > total - avail then start = total - avail end
    if start < 0 then start = 0 end
  end
  local last = avail and math.min(total, start + avail) or total

  local runs = { { text = self.prompt, fg = nil, bg = nil, attr = nil } }
  local i = start + 1
  while i <= last do
    local fg = cells[i].fg
    local buf = {}
    while i <= last and cells[i].fg == fg do
      buf[#buf + 1] = cells[i].ch
      i = i + 1
    end
    runs[#runs + 1] = { text = table.concat(buf), fg = fg, bg = nil, attr = nil }
  end

  local cursor_col = pw + (self.cursor - start)
  return runs, cursor_col
end

return M
