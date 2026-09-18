-- tui/vim.lua -- Phase 1 of the cTUI's vim-style composer layer (docs/tui-vim.md).
-- Pure state machine driven from tui/input.lua's key handler: normal-mode motions
-- over a {lines, cy, cx} buffer (an Input instance). Insert mode is untouched --
-- plain keys still type, this module only ever intercepts Esc and, while in
-- normal mode, plain "char" events. Enter is never claimed here, so it always
-- falls through to Input's own submit path ("Enter must never break").
--
-- Deferred to later phases (docs/tui-vim.md section 8): operators (d c y),
-- text objects, registers, undo/redo, visual/visual-line, search (/ ? n N),
-- ex-lite (:), W B E (WORD motions), and the {/} paragraph motions -- normal
-- mode silently swallows any key it does not recognise, exactly like real vim
-- ignoring an unmapped key.
local M = {}

local input = require("tui.input")
local cp_at, is_word, ulen = input.cp_at, input.is_word, input.ulen

-- Per-buffer pending state for multi-key sequences (count digits, g-pending,
-- find-pending) -- mirrors `vstate` in the studio's vim.lua. Lazily attached to
-- the Input instance so the module itself stays stateless between buffers.
local function vstate(buf)
  buf._vs = buf._vs or {}
  return buf._vs
end

local function line_len(buf, cy) return ulen(buf.lines[cy] or "") end

local function clamp_cy(buf)
  local n = #buf.lines
  if buf.cy < 1 then buf.cy = 1 end
  if buf.cy > n then buf.cy = n end
end

-- Column of the first non-blank codepoint on a line, or 1 if there is none.
local function first_nonblank(buf, cy)
  local line = buf.lines[cy] or ""
  local n = ulen(line)
  for i = 1, n do
    local cp = cp_at(line, i - 1)
    if cp ~= 32 and cp ~= 9 then return i end
  end
  return 1
end

-- ---- char motions -----------------------------------------------------------
local function move_h(buf, delta) buf.cx = buf.cx + delta; buf:clamp_caret() end
local function move_v(buf, delta)
  buf.cy = buf.cy + delta
  clamp_cy(buf)
  buf:clamp_caret() -- simple clamp to the new line's length, no virtual column
end
local function move_eol(buf, count)
  if count > 1 then buf.cy = math.min(#buf.lines, buf.cy + count - 1) end
  buf.cx = math.max(1, line_len(buf, buf.cy))
  buf:clamp_caret()
end
local function do_gg(buf, count)
  buf.cy = count or 1
  clamp_cy(buf)
  buf.cx = first_nonblank(buf, buf.cy)
  buf:clamp_caret()
end
local function do_G(buf, count)
  buf.cy = count or #buf.lines
  clamp_cy(buf)
  buf.cx = first_nonblank(buf, buf.cy)
  buf:clamp_caret()
end

-- ---- word motions (w b e) ----------------------------------------------------
-- Class 0 = blank or off-the-end-of-line (a run boundary), 1 = word (is_word),
-- 2 = punctuation. cp_at already returns 0 past the line's end, so treating a
-- position one past the last codepoint as class 0 falls out for free -- that is
-- what lets these motions step across line breaks without special-casing them.
local function class(cp)
  if cp == 0 or cp == 32 or cp == 9 then return 0 end
  if is_word(cp) then return 1 end
  return 2
end
local function class_at(buf, cy, cx) return class(cp_at(buf.lines[cy] or "", cx - 1)) end

local function next_pos(buf, cy, cx)
  if cx <= line_len(buf, cy) then return cy, cx + 1 end
  if cy < #buf.lines then return cy + 1, 1 end
  return nil
end
local function prev_pos(buf, cy, cx)
  if cx > 1 then return cy, cx - 1 end
  if cy > 1 then return cy - 1, line_len(buf, cy - 1) + 1 end
  return nil
end

local function motion_w(buf, count)
  local cy, cx = buf.cy, buf.cx
  for _ = 1, count do
    local c0 = class_at(buf, cy, cx)
    if c0 ~= 0 then
      while true do
        local ny, nx = next_pos(buf, cy, cx)
        if not ny then break end
        cy, cx = ny, nx
        if class_at(buf, cy, cx) ~= c0 then break end
      end
    end
    while class_at(buf, cy, cx) == 0 do
      local ny, nx = next_pos(buf, cy, cx)
      if not ny then break end
      cy, cx = ny, nx
    end
  end
  buf.cy, buf.cx = cy, cx
  buf:clamp_caret()
end

local function motion_e(buf, count)
  local cy, cx = buf.cy, buf.cx
  for _ = 1, count do
    local ny, nx = next_pos(buf, cy, cx)
    if not ny then break end
    cy, cx = ny, nx
    while class_at(buf, cy, cx) == 0 do
      local ny2, nx2 = next_pos(buf, cy, cx)
      if not ny2 then break end
      cy, cx = ny2, nx2
    end
    local c = class_at(buf, cy, cx)
    while true do
      local ny2, nx2 = next_pos(buf, cy, cx)
      if not ny2 or class_at(buf, ny2, nx2) ~= c then break end
      cy, cx = ny2, nx2
    end
  end
  buf.cy, buf.cx = cy, cx
  buf:clamp_caret()
end

local function motion_b(buf, count)
  local cy, cx = buf.cy, buf.cx
  for _ = 1, count do
    local py, px = prev_pos(buf, cy, cx)
    if not py then break end
    cy, cx = py, px
    while class_at(buf, cy, cx) == 0 do
      local py2, px2 = prev_pos(buf, cy, cx)
      if not py2 then break end
      cy, cx = py2, px2
    end
    local c = class_at(buf, cy, cx)
    while true do
      local py2, px2 = prev_pos(buf, cy, cx)
      if not py2 or class_at(buf, py2, px2) ~= c then break end
      cy, cx = py2, px2
    end
  end
  buf.cy, buf.cx = cy, cx
  buf:clamp_caret()
end

-- ---- insert-mode entry points (i a I A o O) ----------------------------------
local function enter_insert(buf, which)
  if which == "a" then
    buf.cx = math.min(buf.cx + 1, line_len(buf, buf.cy) + 1)
  elseif which == "I" then
    buf.cx = first_nonblank(buf, buf.cy)
  elseif which == "A" then
    buf.cx = line_len(buf, buf.cy) + 1
  elseif which == "o" then
    table.insert(buf.lines, buf.cy + 1, "")
    buf.cy, buf.cx = buf.cy + 1, 1
  elseif which == "O" then
    table.insert(buf.lines, buf.cy, "") -- old line at cy shifts down to cy+1
    buf.cx = 1
  end
  -- "i": caret already sits before the target column, nothing to move.
  buf.edit_mode = "insert"
  buf:clamp_caret()
end

-- ---- find-in-line (f t F T, repeated by ; and ,) -----------------------------
local function target_cp(ch)
  if not (utf8 and ch and ch ~= "") then return nil end
  local ok, cp = pcall(utf8.codepoint, ch)
  return ok and cp or nil
end

-- nudge: on a `;`/`,` repeat of `t`/`T`, start one column further so the search
-- does not immediately re-match the character it is already sitting beside.
local function do_find(buf, cmd, ch, count, nudge)
  local target = target_cp(ch)
  if not target then return end
  local line = buf.lines[buf.cy] or ""
  local n = ulen(line)
  local fwd = (cmd == "f" or cmd == "t")
  local till = (cmd == "t" or cmd == "T")
  local pos = buf.cx
  for _ = 1, count do
    local step = (nudge and till) and 2 or 1
    local found
    if fwd then
      for i = pos + step, n do
        if cp_at(line, i - 1) == target then found = i; break end
      end
    else
      for i = pos - step, 1, -1 do
        if cp_at(line, i - 1) == target then found = i; break end
      end
    end
    if not found then break end
    pos = till and (fwd and found - 1 or found + 1) or found
    nudge = false -- only the first hop of a multi-count repeat gets nudged
  end
  buf.cx = pos
  buf:clamp_caret()
end

local FLIP = { f = "F", F = "f", t = "T", T = "t" }
local function repeat_find(buf, vs, dir, count)
  local lf = vs.last_find
  if not lf then return end
  do_find(buf, dir < 0 and FLIP[lf.cmd] or lf.cmd, lf.char, count, true)
end

-- ---- the grammar --------------------------------------------------------------
-- Consumes an event in normal mode; returns true if it handled it. Insert mode
-- only ever offers Esc here -- every other key types, unchanged.
function M.key(buf, ev)
  if ev.type ~= "key" then return false end
  local mode = buf.edit_mode or "insert"

  if ev.key == "esc" or ev.key == "escape" then
    buf._vs = nil -- always drop a half-typed count/find, even when this Esc is a no-op below
    if mode == "normal" then return false end -- no-op here; falls through (abort/cancel)
    buf.edit_mode = "normal"
    buf:clamp_caret()
    return true
  end

  if mode ~= "normal" or ev.key ~= "char" then return false end

  local c = ev.char or ""
  local vs = vstate(buf)

  if vs.find then
    local cmd, cnt = vs.find, vs.count
    vs.find, vs.count = nil, nil
    do_find(buf, cmd, c, cnt or 1, false)
    vs.last_find = { cmd = cmd, char = c }
    return true
  end

  if vs.g then
    vs.g = false
    local cnt = vs.count; vs.count = nil
    if c == "g" then do_gg(buf, cnt) end
    return true
  end

  if c == "0" and not vs.count then
    buf.cx = 1; buf:clamp_caret()
    return true
  end
  if c:match("^%d$") then
    vs.count = (vs.count or 0) * 10 + tonumber(c)
    return true
  end
  if c == "g" then vs.g = true; return true end
  if c == "f" or c == "t" or c == "F" or c == "T" then vs.find = c; return true end

  local had_count = vs.count ~= nil
  local n = vs.count or 1
  vs.count = nil

  if c == "h" then move_h(buf, -n)
  elseif c == "l" then move_h(buf, n)
  elseif c == "j" then move_v(buf, n)
  elseif c == "k" then move_v(buf, -n)
  elseif c == "w" then motion_w(buf, n)
  elseif c == "b" then motion_b(buf, n)
  elseif c == "e" then motion_e(buf, n)
  elseif c == "^" then buf.cx = first_nonblank(buf, buf.cy); buf:clamp_caret()
  elseif c == "$" then move_eol(buf, n)
  elseif c == "G" then do_G(buf, had_count and n or nil)
  elseif c == "i" or c == "a" or c == "I" or c == "A" or c == "o" or c == "O" then
    enter_insert(buf, c)
  elseif c == ";" then repeat_find(buf, vs, 1, n)
  elseif c == "," then repeat_find(buf, vs, -1, n)
  end
  -- Anything else (operators, visual, search, ex -- later phases) is a silent
  -- no-op, same as an unmapped key in real vim's normal mode.
  return true
end

return M
