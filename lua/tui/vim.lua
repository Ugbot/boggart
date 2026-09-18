-- tui/vim.lua -- the TUI buffer adapter (docs/vim-unify.md), presenting the
-- cTUI composer's {lines, cy, cx, edit_mode} buffer (an Input instance, see
-- tui/input.lua) through the adapter interface the shared grammar in
-- lua/vim.lua calls. Also the thin glue tui/input.lua calls directly:
-- M.key(buf, ev) wraps buf in its (persistent, cached) adapter and drives
-- lua/vim.lua; M.after_submit(buf) does the same for the post-send mode
-- reset. Net effect on the cTUI: byte-for-byte the same as before this file
-- became an adapter (P0/P1, docs/vim-unify.md) -- Esc, Ctrl-R and, in
-- normal/visual/vline mode, plain "char" events are the only things ever
-- intercepted; insert-mode typing and a bare Enter are untouched.
--
-- Codepoint-indexed columns throughout (matching tui/input.lua's own
-- cursor/line model), snapshot-based undo, one unnamed register.
local M = {}

local input = require("tui.input")
local cp_at, ulen = input.cp_at, input.ulen

-- ---- codepoint-indexed substring helpers ------------------------------------
-- Byte offset of the i-th (1-based) codepoint of s; i = ulen(s)+1 is valid and
-- gives the byte position just past the end (matches Lua's own utf8.offset).
local function cpbyte(s, i)
  if i < 1 then i = 1 end
  if not utf8 then return math.min(i, #s + 1) end
  return utf8.offset(s, i) or (#s + 1)
end
-- 1-based INCLUSIVE codepoint range [from, to], clamped to s's length.
local function sub_cp(s, from, to)
  local n = ulen(s)
  from = math.max(1, from)
  to = math.min(n, to)
  if to < from then return "" end
  return s:sub(cpbyte(s, from), cpbyte(s, to + 1) - 1)
end

-- ---- the unnamed register + undo ---------------------------------------------
-- Module-level like the old engine's M.register, so it carries over naturally
-- if a second buffer (the scratch editor) ever lands.
local register = { text = "", linewise = false }
local UNDO_MAX = 100

local function snapshot(buf)
  local lines = {}
  for i, l in ipairs(buf.lines) do lines[i] = l end
  return { lines = lines, cy = buf.cy, cx = buf.cx }
end
local function restore(buf, snap)
  buf.lines, buf.cy, buf.cx = snap.lines, snap.cy, snap.cx
  buf.edit_mode = "normal"
  buf:clamp_caret()
end

-- ---- the adapter object -------------------------------------------------------
-- One per Input instance, created lazily and cached on it (buf._va) so state
-- the core grammar attaches to the adapter (its pending-command bookkeeping,
-- vs. tui/vim.lua's old buf._vs) persists across key events.
local Adapter = {}
Adapter.__index = Adapter

local function get_adapter(buf)
  buf._va = buf._va or setmetatable({ buf = buf }, Adapter)
  return buf._va
end

-- reading
function Adapter:line_count() return #self.buf.lines end
function Adapter:get_line(y) return self.buf.lines[y] or "" end
function Adapter:line_len(y) return ulen(self.buf.lines[y] or "") end
-- Column of the first non-blank codepoint on a line, or 1 if there is none.
function Adapter:first_nonblank(y)
  local line = self.buf.lines[y] or ""
  local n = ulen(line)
  for i = 1, n do
    local cp = cp_at(line, i - 1)
    if cp ~= 32 and cp ~= 9 then return i end
  end
  return 1
end
function Adapter:get_char(y, x)
  local line = self.buf.lines[y] or ""
  if x < 1 or x > ulen(line) then return "" end
  return sub_cp(line, x, x)
end
function Adapter:next_pos(y, x)
  local buf = self.buf
  if x <= self:line_len(y) then return y, x + 1 end
  if y < #buf.lines then return y + 1, 1 end
  return nil
end
function Adapter:prev_pos(y, x)
  if x > 1 then return y, x - 1 end
  if y > 1 then return y - 1, self:line_len(y - 1) + 1 end
  return nil
end
function Adapter:get_text(l1, c1, l2, c2)
  local buf = self.buf
  if l1 == l2 then return sub_cp(buf.lines[l1] or "", c1, c2 - 1) end
  local parts = { sub_cp(buf.lines[l1] or "", c1, math.huge) }
  for i = l1 + 1, l2 - 1 do parts[#parts + 1] = buf.lines[i] or "" end
  parts[#parts + 1] = sub_cp(buf.lines[l2] or "", 1, c2 - 1)
  return table.concat(parts, "\n")
end

-- cursor and mode -- straight proxies onto the Input fields tui.lua and
-- tui/input.lua already read directly for the status chip and caret paint.
function Adapter:get_cursor() return self.buf.cy, self.buf.cx end
function Adapter:set_cursor(y, x) self.buf.cy, self.buf.cx = y, x end
function Adapter:clamp_caret() self.buf:clamp_caret() end
function Adapter:mode() return self.buf.edit_mode end
function Adapter:set_mode(m) self.buf.edit_mode = m end
-- No highlight to paint -- the mode chip + amber caret carry "you are in
-- visual mode" instead (docs/vim-unify.md section 2); the selection anchor
-- itself lives in the core's own pending state.
function Adapter:set_selection() end
function Adapter:clear_selection() end

-- mutation (all ranges half-open [start, end), per the interface)
function Adapter:delete_range(l1, c1, l2, c2)
  local buf = self.buf
  if l1 == l2 then
    local line = buf.lines[l1] or ""
    local n = ulen(line)
    c1 = math.max(1, math.min(c1, n + 1))
    c2 = math.max(c1, math.min(c2, n + 1))
    buf.lines[l1] = sub_cp(line, 1, c1 - 1) .. sub_cp(line, c2, n)
  else
    local first, last = buf.lines[l1] or "", buf.lines[l2] or ""
    local n1, n2 = ulen(first), ulen(last)
    local head = sub_cp(first, 1, math.min(c1, n1 + 1) - 1)
    local tail = sub_cp(last, math.min(c2, n2 + 1), n2)
    buf.lines[l1] = head .. tail
    for i = l2, l1 + 1, -1 do table.remove(buf.lines, i) end
  end
end
-- Beyond the base interface: returns the position right after the inserted
-- text, so the core can place the paste cursor without measuring an
-- arbitrary string in adapter-column units itself. Optional -- a caller that
-- ignores the return values still gets a correct edit, just no cursor move.
function Adapter:insert_at(y, x, text)
  local buf = self.buf
  local line = buf.lines[y] or ""
  local n = ulen(line)
  local ic = math.max(1, math.min(x, n + 1))
  local before, tail = sub_cp(line, 1, ic - 1), sub_cp(line, ic, n)
  local parts = {}
  for ln in (text .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = ln end
  if #parts == 1 then
    buf.lines[y] = before .. parts[1] .. tail
    return y, ic + ulen(parts[1])
  end
  buf.lines[y] = before .. parts[1]
  for i = 2, #parts - 1 do table.insert(buf.lines, y + i - 1, parts[i]) end
  table.insert(buf.lines, y + #parts - 1, parts[#parts] .. tail)
  return y + #parts - 1, ulen(parts[#parts]) + 1
end
-- Replace whole lines [y1, y2] (inclusive) with `list`, the linewise
-- primitive; y2 < y1 inserts `list` before y1 without removing anything.
-- Never leaves the buffer with zero lines.
function Adapter:set_lines(y1, y2, list)
  local buf = self.buf
  for i = math.min(y2, #buf.lines), y1, -1 do table.remove(buf.lines, i) end
  for i = #list, 1, -1 do table.insert(buf.lines, y1, list[i]) end
  if #buf.lines == 0 then buf.lines[1] = "" end
end

-- undo/redo -- snapshot-based, bounded, per buffer. Not a keystroke journal;
-- the composer is short and this is simpler than a real doc undo stack.
function Adapter:begin_undo()
  local buf = self.buf
  buf._undo = buf._undo or {}
  buf._undo[#buf._undo + 1] = snapshot(buf)
  if #buf._undo > UNDO_MAX then table.remove(buf._undo, 1) end
  buf._redo = nil -- a new change invalidates the redo stack
end
function Adapter:end_undo() end
function Adapter:undo()
  local buf = self.buf
  local stack = buf._undo
  if not stack or #stack == 0 then return end
  local snap = table.remove(stack)
  buf._redo = buf._redo or {}
  buf._redo[#buf._redo + 1] = snapshot(buf)
  restore(buf, snap)
end
function Adapter:redo()
  local buf = self.buf
  local stack = buf._redo
  if not stack or #stack == 0 then return end
  local snap = table.remove(stack)
  buf._undo = buf._undo or {}
  buf._undo[#buf._undo + 1] = snapshot(buf)
  restore(buf, snap)
end

-- registers -- only the unnamed register (docs/tui-vim.md section 4).
function Adapter:get_register() return register.text, register.linewise end
function Adapter:set_register(_, text, linewise) register = { text = text, linewise = linewise } end

-- Beyond the base interface: ":set vim"/":set novim" toggle whether the
-- composer's own key handler (tui/input.lua's Input:key) routes through the
-- vim layer at all. Not every adapter has this concept -- lua/vim.lua calls
-- it only if present.
function Adapter:set_enabled(on) self.buf.vim = on end

-- ---- the glue tui/input.lua calls ---------------------------------------------
local vim = require("vim")

function M.key(buf, ev)
  return vim.key(get_adapter(buf), ev)
end

function M.after_submit(buf)
  vim.after_submit(get_adapter(buf))
end

return M
