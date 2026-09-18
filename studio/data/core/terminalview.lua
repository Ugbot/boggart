-- terminalview.lua -- phase 3 of docs/studio-panels.md: a PTY-backed
-- terminal pane. This file owns the cell grid and a small ANSI/VT parser;
-- pty.c (studio/src/api/pty.c) owns the child process and the byte pipe.
-- An ordinary View: it lives in any pane, tabs, splits and closes like the
-- rest (core/rootview.lua, core/view.lua).
--
-- v1: no alt-screen (so vim/htop/tmux render wrong or not at all -- out of
-- v1 on purpose), no 256-colour/truecolor (approximated to the 16 SGR
-- colours), no mouse reporting, no reflow on resize (scrollback keeps its
-- old width). See docs/studio-panels.md section 3 for the rest of the split.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"

local TerminalView = View:extend()

-- Scrollback beyond the visible screen, in rows. The screen itself is
-- always exactly the last `self.rows` entries of self.lines -- see top().
local SCROLLBACK = 2000

-- The 16 SGR colours (8 base + 8 bright) -- v1's "map to the theme's 16"
-- (docs/studio-panels.md). Picked to sit with style.lua's own palette
-- (style.error/good/warn/keyword) rather than a raw xterm cube, so a
-- coloured `ls` or a shell prompt looks native instead of borrowed.
local PALETTE = {
  [0] = { common.color "#3f3f46" }, [8]  = { common.color "#6b6b72" },
  [1] = { common.color "#F77483" }, [9]  = { common.color "#ff8f9c" },
  [2] = { common.color "#7FB77E" }, [10] = { common.color "#96d194" },
  [3] = { common.color "#FFA94D" }, [11] = { common.color "#ffc06b" },
  [4] = { common.color "#93DDFA" }, [12] = { common.color "#b0e6ff" },
  [5] = { common.color "#E58AC9" }, [13] = { common.color "#f0a8de" },
  [6] = { common.color "#f7c95c" }, [14] = { common.color "#ffe08a" },
  [7] = { common.color "#e1e1e6" }, [15] = { common.color "#ffffff" },
}

-- Non-text keys that turn into a fixed escape sequence. Plain characters do
-- NOT go through here -- they arrive as on_text_input, the same path
-- DocView and AgentView use, which is what keeps IME/unicode composition
-- working for free (see on_key_pressed below for why this table must not
-- grow to cover printable keys).
local KEY_SEQ = {
  up = "\27[A", down = "\27[B", right = "\27[C", left = "\27[D",
  home = "\27[H", ["end"] = "\27[F",
  pageup = "\27[5~", pagedown = "\27[6~",
  insert = "\27[2~", delete = "\27[3~",
  ["return"] = "\r", ["keypad enter"] = "\r",
  tab = "\t", backspace = "\127", escape = "\27",
}


local function blank_row() return {} end


function TerminalView:new(opts)
  TerminalView.super.new(self)
  opts = opts or {}
  self.scrollable = true
  -- Take raw keys before global commands (keymap.on_key_pressed), so Ctrl-W and
  -- friends reach the shell. on_key_pressed still returns false for the reserved
  -- Ctrl-Alt-* pane chords, which then fall through to their commands.
  self.raw_keys = true

  self.font = style.code_font
  self.cw = self.font:get_width("M")
  self.lh = self.font:get_height()

  self.cols, self.rows = 80, 24
  self.lines = {}
  for i = 1, self.rows do self.lines[i] = blank_row() end
  self.cursor = { row = 1, col = 1 }
  self.saved_cursor = nil
  self.cursor_visible = true

  -- Current SGR pen. nil fg/bg means "the terminal's default", not palette
  -- index 0 -- that is what lets style.text/style.background keep showing
  -- through for text nothing ever coloured.
  self.fg, self.bg, self.bold, self.reverse, self.underline = nil, nil, false, false, false

  -- Parser state, carried across feed() calls so a sequence split across two
  -- pty:read()s (or two frames) still parses correctly.
  self.parse_state = "ground"
  self.csi_buf = ""
  self.utf8_buf, self.utf8_need = "", 0

  self.last_size = { x = 0, y = 0 }
  self.dead = false

  local cmd = opts.cmd or os.getenv("SHELL") or "/bin/sh"
  self.title = opts.title or cmd:match("([^/]+)$") or "terminal"

  if pty.open then
    local h, err = pty.open {
      cmd = cmd, args = opts.args, cwd = opts.cwd,
      cols = self.cols, rows = self.rows,
    }
    if h then
      self.pty = h
    else
      self.dead = true
      self.spawn_error = err or "spawn failed"
    end
  else
    self.dead = true
    self.spawn_error = "no pty support on this platform"
  end
end


function TerminalView:get_name()
  if self.dead then return self.title .. " [exited]" end
  return self.title
end


function TerminalView:is_text_input()
  -- v1 has no cooked/raw distinction (that needs reading the slave's
  -- termios) -- a terminal always takes every key. Ctrl-Alt-arrows etc still
  -- reach it: keymap.on_key_pressed checks command bindings before ever
  -- asking the view (core/keymap.lua), so panes.lua's fallback bindings are
  -- the way out of a terminal pane (docs/studio-panels.md section 4).
  return not self.dead
end


function TerminalView:try_close(do_close)
  if self.pty then self.pty:close() end
  do_close()
end


-- ---- the screen model -------------------------------------------------
--
-- self.lines is every row ever emitted, oldest first; the screen is always
-- exactly the last `self.rows` of them (top()..#self.lines). Moving the
-- cursor within that range needs no separate scroll-region bookkeeping: a
-- linefeed off the bottom appends a new row (new_line), which is exactly
-- what "the screen scrolled" means when the screen is just "the tail of the
-- list". Scroll regions (DECSTBM) are not modelled -- deferred, along with
-- alt-screen and everything else section 3 defers.

function TerminalView:top()
  return math.max(1, #self.lines - self.rows + 1)
end


function TerminalView:new_line()
  self.lines[#self.lines + 1] = blank_row()
  if #self.lines - self.rows > SCROLLBACK then
    table.remove(self.lines, 1)
    self.cursor.row = self.cursor.row - 1
  end
end


function TerminalView:linefeed()
  if self.cursor.row >= #self.lines then
    self:new_line()
    self.cursor.row = #self.lines
  else
    self.cursor.row = self.cursor.row + 1
  end
end


function TerminalView:carriage_return()
  self.cursor.col = 1
end


-- Cursor motion relative to the current position, clamped to the screen
-- (not the whole scrollback -- a running program addresses the screen).
function TerminalView:move_cursor(drow, dcol)
  self.cursor.row = common.clamp(self.cursor.row + drow, self:top(), #self.lines)
  self.cursor.col = common.clamp(self.cursor.col + dcol, 1, self.cols)
end


-- 1-based screen coordinates (CUP/HVP/CHA), not scrollback-absolute.
function TerminalView:set_cursor(row1, col1)
  if row1 then
    self.cursor.row = common.clamp(self:top() + row1 - 1, self:top(), #self.lines)
  end
  if col1 then
    self.cursor.col = common.clamp(col1, 1, self.cols)
  end
end


function TerminalView:put_char(ch)
  -- Delayed wrap: writing past the last column parks the cursor one past
  -- the edge (below) rather than wrapping immediately, so a full line drawn
  -- right up to the margin does not spuriously blank-line before the next
  -- char -- the same thing a real terminal does.
  if self.cursor.col > self.cols then
    self:linefeed()
    self:carriage_return()
  end
  self.lines[self.cursor.row][self.cursor.col] = {
    ch = ch, fg = self.fg, bg = self.bg,
    bold = self.bold, reverse = self.reverse, underline = self.underline,
  }
  self.cursor.col = self.cursor.col + 1
end


function TerminalView:clear_range(row, from_col, to_col)
  local r = self.lines[row]
  for c = from_col, to_col do r[c] = nil end
end


function TerminalView:erase_in_line(mode)
  if mode == 1 then self:clear_range(self.cursor.row, 1, self.cursor.col)
  elseif mode == 2 then self:clear_range(self.cursor.row, 1, self.cols)
  else self:clear_range(self.cursor.row, self.cursor.col, self.cols) end
end


function TerminalView:erase_in_display(mode)
  local top = self:top()
  if mode == 2 or mode == 3 then
    for r = top, #self.lines do self.lines[r] = blank_row() end
  elseif mode == 1 then
    for r = top, self.cursor.row - 1 do self.lines[r] = blank_row() end
    self:clear_range(self.cursor.row, 1, self.cursor.col)
  else
    self:clear_range(self.cursor.row, self.cursor.col, self.cols)
    for r = self.cursor.row + 1, #self.lines do self.lines[r] = blank_row() end
  end
end


-- ---- SGR (colour/attribute) ---------------------------------------------

local function split_params(s)
  local t = {}
  for p in (s .. ";"):gmatch("([^;]*);") do
    t[#t + 1] = tonumber(p)
  end
  return t
end


function TerminalView:apply_sgr(params)
  if #params == 0 then params = { 0 } end
  local i = 1
  while i <= #params do
    local p = params[i] or 0
    if p == 0 then
      self.fg, self.bg = nil, nil
      self.bold, self.reverse, self.underline = false, false, false
    elseif p == 1 then self.bold = true
    elseif p == 4 then self.underline = true
    elseif p == 7 then self.reverse = true
    elseif p == 22 then self.bold = false
    elseif p == 24 then self.underline = false
    elseif p == 27 then self.reverse = false
    elseif p >= 30 and p <= 37 then self.fg = p - 30
    elseif p == 38 then
      -- 256-colour/truecolor is deferred (docs/studio-panels.md) -- consume
      -- the trailing params ("5;N" or "2;R;G;B") so they are not misread as
      -- unrelated SGR codes on the next loop.
      if params[i + 1] == 5 then i = i + 2
      elseif params[i + 1] == 2 then i = i + 4 end
    elseif p == 39 then self.fg = nil
    elseif p >= 40 and p <= 47 then self.bg = p - 40
    elseif p == 48 then
      if params[i + 1] == 5 then i = i + 2
      elseif params[i + 1] == 2 then i = i + 4 end
    elseif p == 49 then self.bg = nil
    elseif p >= 90 and p <= 97 then self.fg = p - 90 + 8
    elseif p >= 100 and p <= 107 then self.bg = p - 100 + 8
    end
    i = i + 1
  end
end


-- ---- CSI dispatch ---------------------------------------------------------

function TerminalView:handle_csi(final, raw)
  local private = raw:sub(1, 1) == "?"
  local params = split_params(private and raw:sub(2) or raw)
  local function n(idx, default)
    local v = params[idx]
    if not v or v == 0 then return default end
    return v
  end

  if final == "A" then self:move_cursor(-n(1, 1), 0)
  elseif final == "B" then self:move_cursor(n(1, 1), 0)
  elseif final == "C" then self:move_cursor(0, n(1, 1))
  elseif final == "D" then self:move_cursor(0, -n(1, 1))
  elseif final == "G" then self:set_cursor(nil, n(1, 1))
  elseif final == "H" or final == "f" then self:set_cursor(n(1, 1), n(2, 1))
  elseif final == "J" then self:erase_in_display(params[1] or 0)
  elseif final == "K" then self:erase_in_line(params[1] or 0)
  elseif final == "m" then self:apply_sgr(params)
  elseif final == "s" then
    self.saved_cursor = { row = self.cursor.row - self:top() + 1, col = self.cursor.col }
  elseif final == "u" then
    if self.saved_cursor then self:set_cursor(self.saved_cursor.row, self.saved_cursor.col) end
  elseif private and params[1] == 25 and final == "h" then self.cursor_visible = true
  elseif private and params[1] == 25 and final == "l" then self.cursor_visible = false
  end
  -- Everything else -- scroll regions, alt-screen (?1049), mouse reporting,
  -- bracketed paste (?2004), 256-colour set via other codes -- is deferred:
  -- silently consumed so it never leaks into the grid as literal text.
end


-- ---- byte-level parser -----------------------------------------------

function TerminalView:step_byte(b)
  if self.utf8_need > 0 then
    if b >= 0x80 and b < 0xC0 then
      self.utf8_buf = self.utf8_buf .. string.char(b)
      self.utf8_need = self.utf8_need - 1
      if self.utf8_need == 0 then
        self:put_char(self.utf8_buf)
        self.utf8_buf = ""
      end
      return
    end
    -- Malformed continuation: drop the partial char and re-process this
    -- byte fresh rather than eating it silently.
    self.utf8_buf, self.utf8_need = "", 0
  end

  local st = self.parse_state
  if st == "ground" then
    if b == 0x1B then self.parse_state = "esc"
    elseif b == 0x0D then self:carriage_return()
    elseif b == 0x0A then self:linefeed()
    elseif b == 0x08 then self:move_cursor(0, -1)
    elseif b == 0x09 then
      self.cursor.col = math.min(self.cols, (math.floor((self.cursor.col - 1) / 8) + 1) * 8 + 1)
    elseif b == 0x07 then -- bell: no-op
    elseif b < 0x20 or b == 0x7F then -- other control bytes: no-op
    elseif b < 0x80 then self:put_char(string.char(b))
    elseif b >= 0xF0 then self.utf8_buf, self.utf8_need = string.char(b), 3
    elseif b >= 0xE0 then self.utf8_buf, self.utf8_need = string.char(b), 2
    elseif b >= 0xC0 then self.utf8_buf, self.utf8_need = string.char(b), 1
    end -- else: a stray continuation byte with nothing pending -- drop it

  elseif st == "esc" then
    if b == 0x5B then self.parse_state, self.csi_buf = "csi", ""       -- '['
    elseif b == 0x5D then self.parse_state = "osc"                     -- ']'
    else self.parse_state = "ground" end -- a single-char ESC sequence: swallow it

  elseif st == "csi" then
    if b >= 0x40 and b <= 0x7E then
      self:handle_csi(string.char(b), self.csi_buf)
      self.parse_state = "ground"
    else
      self.csi_buf = self.csi_buf .. string.char(b)
      if #self.csi_buf > 64 then self.parse_state = "ground" end -- runaway guard
    end

  elseif st == "osc" then
    -- Window-title / colour-query sequences: not rendered (v1 has no tab
    -- title from OSC), just consumed so they cannot leak into the grid.
    if b == 0x07 then self.parse_state = "ground"
    elseif b == 0x1B then self.parse_state = "osc_esc" end

  elseif st == "osc_esc" then
    if b == 0x5C then self.parse_state = "ground" else self.parse_state = "osc" end
  end
end


function TerminalView:feed(data)
  for i = 1, #data do self:step_byte(data:byte(i)) end
end


-- ---- input: keys and pasted/typed text -------------------------------

function TerminalView:send(bytes)
  if self.dead or not self.pty then return end
  self.pty:write(bytes)
  if self:at_bottom() then self:scroll_to_bottom() end
end


function TerminalView:on_key_pressed(key)
  if self.dead or not self.pty then return false end

  if key == "cmd+v" or key == "ctrl+v" then
    local text = system.get_clipboard()
    if text and text ~= "" then self:send(text) end
    return true
  end

  local seq = KEY_SEQ[key]
  if seq then self:send(seq); return true end

  -- Ctrl+<letter> -> the matching C0 control byte (Ctrl-C is SIGINT,
  -- Ctrl-D is EOF, and so on) -- the one piece of chording a shell needs
  -- that on_text_input cannot express.
  local letter = key:match("^ctrl%+(%a)$")
  if letter then
    self:send(string.char(letter:lower():byte() - 96))
    return true
  end

  return false
end


-- Plain typed characters arrive here, not through on_key_pressed -- the
-- same split DocView and AgentView use, so unicode input keeps working.
function TerminalView:on_text_input(text)
  self:send(text)
end


-- ---- layout: resize follows the pane ----------------------------------

function TerminalView:resize_to_fit()
  local cols = math.max(1, math.floor(self.size.x / self.cw))
  local rows = math.max(1, math.floor(self.size.y / self.lh))
  if cols == self.cols and rows == self.rows then return end
  self.cols, self.rows = cols, rows
  -- v1 does not reflow scrollback to the new width (docs/studio-panels.md) --
  -- only pad so the screen (top()..#self.lines) always has `rows` entries.
  while #self.lines < self.rows do self.lines[#self.lines + 1] = blank_row() end
  self.cursor.row = common.clamp(self.cursor.row, self:top(), #self.lines)
  self.cursor.col = common.clamp(self.cursor.col, 1, self.cols)
  if self.pty then self.pty:resize(self.cols, self.rows) end
end


function TerminalView:get_scrollable_size()
  return #self.lines * self.lh
end


function TerminalView:at_bottom()
  return self.scroll.to.y >= self:get_scrollable_size() - self.size.y - self.lh
end


function TerminalView:scroll_to_bottom()
  self.scroll.to.y = math.max(0, self:get_scrollable_size() - self.size.y)
end


function TerminalView:update()
  TerminalView.super.update(self)

  -- Node:update_layout writes self.size every frame regardless of whether
  -- it actually changed; only react when it did.
  if self.size.x ~= self.last_size.x or self.size.y ~= self.last_size.y then
    self.last_size.x, self.last_size.y = self.size.x, self.size.y
    if self.cw > 0 and self.lh > 0 then self:resize_to_fit() end
  end

  if self.dead or not self.pty then return end

  if not self.pty:alive() then
    self.dead = true   -- freeze the last screen; get_name() shows [exited]
    core.redraw = true
    return
  end

  local was_at_bottom = self:at_bottom()
  local got_data = false
  -- Bounded drain: a chatty child (`yes`, a build log) must not be allowed
  -- to starve the rest of the frame loop of a turn.
  for _ = 1, 256 do
    local data = self.pty:read()
    if data == nil then break end
    if data == "" then break end
    self:feed(data)
    got_data = true
  end
  if got_data then
    core.redraw = true
    if was_at_bottom then self:scroll_to_bottom() end
  end
end


-- ---- drawing ------------------------------------------------------------

local function style_eq(a, b)
  local afg, bfg = a and a.fg, b and b.fg
  local abg, bbg = a and a.bg, b and b.bg
  local abold, bbold = a and a.bold, b and b.bold
  local arev, brev = a and a.reverse, b and b.reverse
  local aund, bund = a and a.underline, b and b.underline
  return afg == bfg and abg == bbg and abold == bbold and arev == brev and aund == bund
end


-- Resolve a cell's SGR pen to actual draw colours, folding bold-brightens-
-- the-base-8-colours (the convention most terminals and most CLI tools that
-- colour their own output assume) and reverse-video into the result.
function TerminalView:resolve_colors(cell)
  local fg_idx, bg_idx = cell and cell.fg, cell and cell.bg
  local bold, reverse = cell and cell.bold, cell and cell.reverse

  local fg
  if fg_idx then
    fg = PALETTE[(bold and fg_idx < 8) and fg_idx + 8 or fg_idx]
  elseif bold then
    fg = PALETTE[15]
  end
  fg = fg or style.text
  local bg = bg_idx and PALETTE[bg_idx] or nil

  if reverse then
    fg, bg = bg or style.background, fg
  end
  return fg, bg
end


function TerminalView:draw_row(row, x0, y)
  local i = 1
  while i <= self.cols do
    local cell = row[i]
    local j = i + 1
    while j <= self.cols and style_eq(row[j], cell) do j = j + 1 end

    local chars = {}
    for k = i, j - 1 do chars[#chars + 1] = (row[k] and row[k].ch) or " " end
    local count = j - i
    local fg, bg = self:resolve_colors(cell)
    local x = x0 + (i - 1) * self.cw

    if bg then renderer.draw_rect(x, y, count * self.cw, self.lh, bg) end
    renderer.draw_text(self.font, table.concat(chars), x, y, fg)
    if cell and cell.underline then
      renderer.draw_rect(x, y + self.lh - 1, count * self.cw, 1, fg)
    end
    i = j
  end
end


function TerminalView:draw()
  self:draw_background(style.background)
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)

  local ox, oy = self:get_content_offset()
  local vmin = common.clamp(math.floor(self.scroll.y / self.lh) + 1, 1, #self.lines)
  local vmax = common.clamp(math.floor((self.scroll.y + self.size.y) / self.lh) + 1, 1, #self.lines)

  for r = vmin, vmax do
    self:draw_row(self.lines[r], ox, oy + (r - 1) * self.lh)
  end

  if self.cursor_visible and not self.dead
     and self.cursor.row >= vmin and self.cursor.row <= vmax then
    local col = math.min(self.cursor.col, self.cols)
    local cx, cy = ox + (col - 1) * self.cw, oy + (self.cursor.row - 1) * self.lh
    local alpha = core.active_view == self and 200 or 90
    renderer.draw_rect(cx, cy, self.cw, self.lh,
      { style.caret[1], style.caret[2], style.caret[3], alpha })
  end

  core.pop_clip_rect()
  self:draw_scrollbar()

  if self.spawn_error then
    common.draw_text(style.font, style.error, self.spawn_error, "left",
      self.position.x + style.padding.x, self.position.y + style.padding.y,
      self.size.x, self.font:get_height())
  end
end


return TerminalView
