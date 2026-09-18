-- tui/vim.lua -- the cTUI's vim-style composer layer (docs/tui-vim.md).
-- Pure state machine driven from tui/input.lua's key handler, over a
-- {lines, cy, cx} buffer (an Input instance). Insert mode is untouched --
-- plain keys still type, this module only ever intercepts Esc, Ctrl-R, and,
-- while in normal/visual/vline mode, plain "char" events. Enter is never
-- claimed except to finish a ":"/"/"/"?" prompt line, so a plain Enter always
-- falls through to Input's own submit path ("Enter must never break").
--
-- Phases 1-4 (docs/tui-vim.md section 8): normal/insert + core motions (incl.
-- W B E and { } paragraph jumps), operators d c y with motions/doubled forms,
-- x D C s r, p P over the unnamed register, u/Ctrl-R undo (snapshot based),
-- text objects iw/aw, i"/a" (and ' `), brackets, ip/ap, visual + visual-line
-- with operators over the selection, / ? n N * # substring search, and a
-- minimal ex line (:w :q :wq :x :{N} :set vim|novim).
--
-- Deferred, on purpose (docs/tui-vim.md section 9 and section 8 phase 5):
-- named/numbered registers, macros, dot-repeat, marks, visual-block,
-- multi-cursor, the scratch/file buffer, and painting the visual selection
-- with a background highlight in the cell grid (the mode chip + amber caret
-- carry the "you are in visual mode" signal instead).
local M = {}

local input = require("tui.input")
local cp_at, is_word, ulen = input.cp_at, input.is_word, input.ulen
local vimmode = require("vimmode")

-- Per-buffer pending state for multi-key sequences -- mirrors `vstate` in the
-- studio's vim.lua. Lazily attached to the Input instance so the module
-- itself stays stateless between buffers.
local function vstate(buf)
  buf._vs = buf._vs or {}
  return buf._vs
end

-- Fields that describe a grammar sequence IN PROGRESS (a count being typed, an
-- operator waiting for its motion, ...). Cleared once a command completes.
-- Deliberately excludes vs.anchor (visual selection), vs.prompt (: / ? line),
-- vs.last_find / vs.last_search (persist across commands) and vs.reg (unused).
local function reset_pending(vs)
  vs.op, vs.opcount, vs.await, vs.find, vs.g, vs.count, vs.textobj = nil
end
local function has_pending(vs)
  return vs.op ~= nil or vs.opcount ~= nil or vs.await ~= nil or vs.find ~= nil
      or vs.g or vs.count ~= nil
end
-- The effective repeat count: a count typed before the operator times one
-- typed after it (vim's "2d3w" == 6). Defaults to 1.
local function eff_count(vs)
  local a, b = vs.count, vs.opcount
  if not a and not b then return 1 end
  return (a or 1) * (b or 1)
end
local function had_count(vs) return vs.count ~= nil or vs.opcount ~= nil end

local function line_len(buf, cy) return ulen(buf.lines[cy] or "") end

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
local function is_blank(buf, cy) return (buf.lines[cy] or ""):match("^%s*$") ~= nil end

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

-- ---- word classing (w b e / W B E) -------------------------------------------
-- Class 0 = blank or off-the-end-of-line, 1 = word (or, `big`, any non-blank),
-- 2 = punctuation. cp_at already returns 0 past a line's end, so a position one
-- past the last codepoint falls into class 0 for free -- that is what lets word
-- motions step across line breaks without special-casing them.
local function class(cp, big)
  if cp == 0 or cp == 32 or cp == 9 then return 0 end
  if big then return 1 end
  if is_word(cp) then return 1 end
  return 2
end
local function class_at(buf, y, x, big) return class(cp_at(buf.lines[y] or "", x - 1), big) end

local function next_pos(buf, y, x)
  if x <= line_len(buf, y) then return y, x + 1 end
  if y < #buf.lines then return y + 1, 1 end
  return nil
end
local function prev_pos(buf, y, x)
  if x > 1 then return y, x - 1 end
  if y > 1 then return y - 1, line_len(buf, y - 1) + 1 end
  return nil
end

-- Pure position computers: given buf's CURRENT caret as the start, return the
-- target (ty, tx) without mutating buf. Used both as a direct motion (caller
-- moves the caret) and as an operator target (caller feeds do_operator).
local function pos_w(buf, count, big)
  local y, x = buf.cy, buf.cx
  for _ = 1, count do
    local c0 = class_at(buf, y, x, big)
    if c0 ~= 0 then
      while true do
        local ny, nx = next_pos(buf, y, x)
        if not ny then break end
        y, x = ny, nx
        if class_at(buf, y, x, big) ~= c0 then break end
      end
    end
    while class_at(buf, y, x, big) == 0 do
      local ny, nx = next_pos(buf, y, x)
      if not ny then break end
      y, x = ny, nx
    end
  end
  return y, x
end
local function pos_e(buf, count, big)
  local y, x = buf.cy, buf.cx
  for _ = 1, count do
    local ny, nx = next_pos(buf, y, x)
    if not ny then break end
    y, x = ny, nx
    while class_at(buf, y, x, big) == 0 do
      local ny2, nx2 = next_pos(buf, y, x)
      if not ny2 then break end
      y, x = ny2, nx2
    end
    local c = class_at(buf, y, x, big)
    while true do
      local ny2, nx2 = next_pos(buf, y, x)
      if not ny2 or class_at(buf, ny2, nx2, big) ~= c then break end
      y, x = ny2, nx2
    end
  end
  return y, x
end
local function pos_b(buf, count, big)
  local y, x = buf.cy, buf.cx
  for _ = 1, count do
    local py, px = prev_pos(buf, y, x)
    if not py then break end
    y, x = py, px
    while class_at(buf, y, x, big) == 0 do
      local py2, px2 = prev_pos(buf, y, x)
      if not py2 then break end
      y, x = py2, px2
    end
    local c = class_at(buf, y, x, big)
    while true do
      local py2, px2 = prev_pos(buf, y, x)
      if not py2 or class_at(buf, py2, px2, big) ~= c then break end
      y, x = py2, px2
    end
  end
  return y, x
end

-- ---- buffer text primitives (charwise, exclusive-end [c1, c2)) --------------
local function get_text(buf, l1, c1, l2, c2)
  if l1 == l2 then return sub_cp(buf.lines[l1] or "", c1, c2 - 1) end
  local parts = { sub_cp(buf.lines[l1] or "", c1, math.huge) }
  for i = l1 + 1, l2 - 1 do parts[#parts + 1] = buf.lines[i] or "" end
  parts[#parts + 1] = sub_cp(buf.lines[l2] or "", 1, c2 - 1)
  return table.concat(parts, "\n")
end
local function remove_range(buf, l1, c1, l2, c2)
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
  buf.cy, buf.cx = l1, c1
end
local function linewise_text(buf, l1, l2)
  local t = {}
  for i = l1, l2 do t[#t + 1] = buf.lines[i] or "" end
  return table.concat(t, "\n") .. "\n"
end

-- ---- the unnamed register + undo/redo ----------------------------------------
-- Only the unnamed register (docs section 4): {text, linewise}, written by
-- d c x y, read by p P. Module-level like the studio's M.register, so it will
-- carry over naturally if a second buffer (the scratch editor) ever lands.
M.register = { text = "", linewise = false }

-- Snapshot-based undo, bounded, per buffer. Not a keystroke journal -- the
-- composer is short and this is simpler than the studio's replay recorder.
local UNDO_MAX = 100
local function snapshot(buf)
  local lines = {}
  for i, l in ipairs(buf.lines) do lines[i] = l end
  return { lines = lines, cy = buf.cy, cx = buf.cx }
end
local function push_undo(buf)
  buf._undo = buf._undo or {}
  buf._undo[#buf._undo + 1] = snapshot(buf)
  if #buf._undo > UNDO_MAX then table.remove(buf._undo, 1) end
  buf._redo = nil -- a new change invalidates the redo stack
end
local function restore(buf, snap)
  buf.lines, buf.cy, buf.cx = snap.lines, snap.cy, snap.cx
  buf.edit_mode = "normal"
  buf:clamp_caret()
end
local function do_undo(buf)
  local stack = buf._undo
  if not stack or #stack == 0 then return end
  local snap = table.remove(stack)
  buf._redo = buf._redo or {}
  buf._redo[#buf._redo + 1] = snapshot(buf)
  restore(buf, snap)
end
local function do_redo(buf)
  local stack = buf._redo
  if not stack or #stack == 0 then return end
  local snap = table.remove(stack)
  buf._undo = buf._undo or {}
  buf._undo[#buf._undo + 1] = snapshot(buf)
  restore(buf, snap)
end

-- ---- operators: d c y over a char range or whole lines -----------------------
local function op_linewise(buf, op, minl, maxl)
  minl, maxl = math.max(1, minl), math.min(#buf.lines, maxl)
  local text = linewise_text(buf, minl, maxl)
  if op == "y" then
    M.register = { text = text, linewise = true }
    buf.cy, buf.cx = minl, first_nonblank(buf, minl)
    buf:clamp_caret()
    return
  end
  push_undo(buf)
  M.register = { text = text, linewise = true }
  local indent = (buf.lines[minl] or ""):match("^[ \t]*") or ""
  for i = maxl, minl, -1 do table.remove(buf.lines, i) end
  if op == "d" then
    if #buf.lines == 0 then buf.lines[1] = "" end
    local ny = math.min(minl, #buf.lines)
    buf.cy, buf.cx = ny, first_nonblank(buf, ny)
  else -- c: open a fresh (indented) line where the block was, and start typing
    local at = math.min(minl, #buf.lines + 1)
    table.insert(buf.lines, at, indent)
    buf.cy, buf.cx = at, ulen(indent) + 1
    buf.edit_mode = "insert"
  end
  buf:clamp_caret()
end

-- Apply `op` over [l1,c1)..(l2,c2] (order-independent) per `kind`:
-- "exc" -- range is already the exclusive [minc, maxc); "inc" -- maxc is the
-- last INCLUDED column, extend it by one char (clamped to the line) to make it
-- exclusive; "line" -- whole lines, delegate to op_linewise.
local function do_operator(buf, op, l1, c1, l2, c2, kind)
  local a_first = (l1 < l2) or (l1 == l2 and c1 <= c2)
  local minl, minc, maxl, maxc
  if a_first then minl, minc, maxl, maxc = l1, c1, l2, c2
  else minl, minc, maxl, maxc = l2, c2, l1, c1 end
  if kind == "line" then return op_linewise(buf, op, minl, maxl) end

  if kind == "inc" then
    local n = line_len(buf, maxl)
    maxc = (maxc <= n) and (maxc + 1) or (n + 1)
  end

  local text = get_text(buf, minl, minc, maxl, maxc)
  if op == "y" then
    M.register = { text = text, linewise = false }
    buf.cy, buf.cx = minl, minc
    buf:clamp_caret()
    return
  end
  push_undo(buf)
  M.register = { text = text, linewise = false }
  remove_range(buf, minl, minc, maxl, maxc)
  buf:clamp_caret()
  if op == "c" then buf.edit_mode = "insert" end
end

-- ---- text objects: iw aw i"/a" i(/a( ip/ap -----------------------------------
local function char_at(buf, y, x)
  local line = buf.lines[y] or ""
  if x < 1 or x > ulen(line) then return "" end
  return sub_cp(line, x, x)
end
local function scan_back_open(buf, y, x, open, close)
  local ly, lx, depth = y, x, 0
  while true do
    local ch = char_at(buf, ly, lx)
    if ch == close and not (ly == y and lx == x) then depth = depth + 1
    elseif ch == open then
      if depth == 0 then return ly, lx end
      depth = depth - 1
    end
    local py, px = prev_pos(buf, ly, lx)
    if not py then return nil end
    ly, lx = py, px
  end
end
local function scan_fwd_close(buf, y, x, open, close)
  local ly, lx, depth = y, x, 0
  while true do
    local ch = char_at(buf, ly, lx)
    if ch == open and not (ly == y and lx == x) then depth = depth + 1
    elseif ch == close then
      if depth == 0 then return ly, lx end
      depth = depth - 1
    end
    local ny, nx = next_pos(buf, ly, lx)
    if not ny then return nil end
    ly, lx = ny, nx
  end
end
local PAIRS = {
  ["("] = { "(", ")" }, [")"] = { "(", ")" }, b = { "(", ")" },
  ["{"] = { "{", "}" }, ["}"] = { "{", "}" }, B = { "{", "}" },
  ["["] = { "[", "]" }, ["]"] = { "[", "]" },
}
local QUOTES = { ['"'] = true, ["'"] = true, ["`"] = true }

-- Returns an INCLUSIVE range l1,c1,l2,c2 and a linewise flag for the text
-- object `obj` under (y,x); ia is "i" (inner) or "a" (around). nil if empty.
local function text_object(buf, ia, obj, y, x)
  if obj == "w" or obj == "W" then
    local big = (obj == "W")
    local line = buf.lines[y] or ""
    local n = ulen(line)
    local function cls(i) return class(cp_at(line, i - 1), big) end
    local c0 = cls(x)
    local a, b = x, x
    if c0 ~= 0 then
      while a > 1 and cls(a - 1) == c0 do a = a - 1 end
      while b < n and cls(b + 1) == c0 do b = b + 1 end
    end
    if ia == "a" then
      local e = b
      while e < n and cls(e + 1) == 0 do e = e + 1 end
      if e > b then b = e
      else while a > 1 and cls(a - 1) == 0 do a = a - 1 end end
    end
    return y, a, y, b, false

  elseif PAIRS[obj] then
    local open, close = PAIRS[obj][1], PAIRS[obj][2]
    local ol, oc = scan_back_open(buf, y, x, open, close)
    if not ol then return nil end
    local cl, cc = scan_fwd_close(buf, y, x, open, close)
    if not cl then return nil end
    if ia == "a" then return ol, oc, cl, cc, false end
    local il, ic = next_pos(buf, ol, oc)
    if not il then return nil end
    local jl, jc = prev_pos(buf, cl, cc)
    if not jl then return nil end
    if il > jl or (il == jl and ic > jc) then return nil end -- empty pair "()"
    return il, ic, jl, jc, false

  elseif QUOTES[obj] then
    local line = buf.lines[y] or ""
    local n = ulen(line)
    local positions = {}
    for i = 1, n do if sub_cp(line, i, i) == obj then positions[#positions + 1] = i end end
    for i = 1, #positions - 1, 2 do
      local a, b = positions[i], positions[i + 1]
      if x <= b then
        if ia == "a" then return y, a, y, b, false end
        if b - 1 < a + 1 then return nil end
        return y, a + 1, y, b - 1, false
      end
    end
    return nil

  elseif obj == "p" then
    local a, b = y, y
    local on_blank = is_blank(buf, y)
    while a > 1 and is_blank(buf, a - 1) == on_blank do a = a - 1 end
    while b < #buf.lines and is_blank(buf, b + 1) == on_blank do b = b + 1 end
    if ia == "a" and not on_blank then
      while b < #buf.lines and is_blank(buf, b + 1) do b = b + 1 end
    end
    return a, 1, b, 1, true
  end
  return nil
end

-- Resolve a text-object range under the caret and either feed the pending
-- operator, or (in visual/vline mode) set it as the selection.
local function apply_object(buf, vs, ia, obj, op, mode)
  local l1, c1, l2, c2, linewise = text_object(buf, ia, obj, buf.cy, buf.cx)
  if not l1 then return end
  if op then
    do_operator(buf, op, l1, c1, l2, c2, linewise and "line" or "inc")
  elseif mode == "visual" or mode == "vline" then
    vs.anchor = { cy = l1, cx = c1 }
    buf.cy, buf.cx = l2, c2
    buf:clamp_caret()
  end
end

-- ---- r{char} replace, p/P paste -----------------------------------------------
local function do_replace(buf, ch, count)
  if ch == "" then return end
  local line = buf.lines[buf.cy] or ""
  local n = ulen(line)
  if n - buf.cx + 1 < count then return end -- vim: r past EOL is a no-op
  push_undo(buf)
  local rep = ch:rep(count)
  buf.lines[buf.cy] = sub_cp(line, 1, buf.cx - 1) .. rep .. sub_cp(line, buf.cx + count, n)
  buf.cx = buf.cx + count - 1
  buf:clamp_caret()
end

local function do_paste(buf, after, count)
  local reg = M.register
  if not reg or reg.text == "" then return end
  local text = (count and count > 1) and reg.text:rep(count) or reg.text
  push_undo(buf)
  if reg.linewise then
    local body = text:gsub("\n$", "")
    local newlines = {}
    for ln in (body .. "\n"):gmatch("(.-)\n") do newlines[#newlines + 1] = ln end
    local at = after and (buf.cy + 1) or buf.cy
    for i = #newlines, 1, -1 do table.insert(buf.lines, at, newlines[i]) end
    buf.cy, buf.cx = at, first_nonblank(buf, at)
  else
    local il, ic = buf.cy, buf.cx
    if after then
      local n = line_len(buf, buf.cy)
      if buf.cx <= n then ic = buf.cx + 1 end
    end
    local line = buf.lines[il] or ""
    local before, tail = sub_cp(line, 1, ic - 1), sub_cp(line, ic, ulen(line))
    local parts = {}
    for ln in (text .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = ln end
    if #parts == 1 then
      buf.lines[il] = before .. parts[1] .. tail
      buf.cy, buf.cx = il, ic + math.max(0, ulen(parts[1]) - 1)
    else
      buf.lines[il] = before .. parts[1]
      for i = 2, #parts - 1 do table.insert(buf.lines, il + i - 1, parts[i]) end
      table.insert(buf.lines, il + #parts - 1, parts[#parts] .. tail)
      buf.cy, buf.cx = il + #parts - 1, ulen(parts[#parts])
    end
  end
  buf:clamp_caret()
end

-- ---- find-in-line (f t F T, repeated by ; and ,) -----------------------------
local function target_cp(ch)
  if not (utf8 and ch and ch ~= "") then return nil end
  local ok, cp = pcall(utf8.codepoint, ch)
  return ok and cp or nil
end

-- Pure: returns the target (ty, tx, kind) without moving the caret. `nudge`
-- (a `;`/`,` repeat of t/T) starts one column further so the search does not
-- immediately re-match the character it is already sitting beside.
local function find_target(buf, cmd, ch, count, nudge)
  local target = target_cp(ch)
  if not target then return nil end
  local line = buf.lines[buf.cy] or ""
  local n = ulen(line)
  local fwd = (cmd == "f" or cmd == "t")
  local till = (cmd == "t" or cmd == "T")
  local pos, moved = buf.cx, false
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
    nudge, moved = false, true
  end
  if not moved then return nil end
  return buf.cy, pos, fwd and "inc" or "exc"
end

local FLIP = { f = "F", F = "f", t = "T", T = "t" }
local function repeat_find_target(buf, vs, dir, count)
  local lf = vs.last_find
  if not lf then return nil end
  return find_target(buf, dir < 0 and FLIP[lf.cmd] or lf.cmd, lf.char, count, true)
end

-- ---- paragraph motion ({ }) -- next/previous blank-line boundary, exclusive --
local function motion_para_target(buf, dir, count)
  local y = buf.cy
  for _ = 1, count do
    local ny = y
    repeat ny = ny + dir until ny < 1 or ny > #buf.lines or is_blank(buf, ny)
    y = math.max(1, math.min(#buf.lines, ny))
  end
  return y, 1, "exc"
end

-- ---- the motion table ---------------------------------------------------------
local MOTION_NAMES = {
  h = 1, l = 1, j = 1, k = 1, w = 1, b = 1, e = 1, W = 1, B = 1, E = 1,
  ["0"] = 1, ["^"] = 1, ["$"] = 1, ["{"] = 1, ["}"] = 1, G = 1, [";"] = 1, [","] = 1,
}

-- Returns (ty, tx, kind) for named motion `c` from the caret, or nil if it
-- cannot move (an empty find, an unset last-find). `n` is the effective
-- count; `had` is whether a count was actually typed (gg/G's "go to line N").
local function resolve_motion(buf, vs, c, n, had)
  local y, x = buf.cy, buf.cx
  if c == "h" then return y, math.max(1, x - n), "exc"
  elseif c == "l" then return y, x + n, "exc"
  elseif c == "j" then return math.min(#buf.lines, y + n), x, "line"
  elseif c == "k" then return math.max(1, y - n), x, "line"
  elseif c == "w" then local ty, tx = pos_w(buf, n, false); return ty, tx, "exc"
  elseif c == "W" then local ty, tx = pos_w(buf, n, true); return ty, tx, "exc"
  elseif c == "b" then local ty, tx = pos_b(buf, n, false); return ty, tx, "exc"
  elseif c == "B" then local ty, tx = pos_b(buf, n, true); return ty, tx, "exc"
  elseif c == "e" then local ty, tx = pos_e(buf, n, false); return ty, tx, "inc"
  elseif c == "E" then local ty, tx = pos_e(buf, n, true); return ty, tx, "inc"
  elseif c == "0" then return y, 1, "exc"
  elseif c == "^" then return y, first_nonblank(buf, y), "exc"
  elseif c == "$" then
    local ny = math.min(#buf.lines, y + n - 1)
    return ny, line_len(buf, ny) + 1, "exc" -- +1 is already the exclusive boundary
  elseif c == "{" then return motion_para_target(buf, -1, n)
  elseif c == "}" then return motion_para_target(buf, 1, n)
  elseif c == "G" then
    local ny = had and math.min(n, #buf.lines) or #buf.lines
    return ny, first_nonblank(buf, ny), "line"
  elseif c == ";" then return repeat_find_target(buf, vs, 1, n)
  elseif c == "," then return repeat_find_target(buf, vs, -1, n)
  end
  return nil
end

-- ---- search: / ? n N * # (plain substring, case-insensitive) ----------------
local function search_line(line, patlower, from_col)
  local hit = line:lower():find(patlower, cpbyte(line, from_col), true)
  if not hit then return nil end
  return ulen(line:sub(1, hit - 1)) + 1
end
local function search_line_last(line, patlower, upto_col)
  local best, i, ll = nil, 1, line:lower()
  while true do
    local hit = ll:find(patlower, i, true)
    if not hit then break end
    local col = ulen(line:sub(1, hit - 1)) + 1
    if not upto_col or col <= upto_col then best = col end
    i = hit + 1
  end
  return best
end
local function search_fwd(buf, pat, y, x)
  local patlower, n = pat:lower(), #buf.lines
  if n == 0 or pat == "" then return nil end
  for step = 0, n do
    local yy = ((y - 1 + step) % n) + 1
    local from = (step == 0) and (x + 1) or 1
    local col = search_line(buf.lines[yy] or "", patlower, from)
    if col then return yy, col end
  end
  return nil
end
local function search_bwd(buf, pat, y, x)
  local patlower, n = pat:lower(), #buf.lines
  if n == 0 or pat == "" then return nil end
  for step = 0, n do
    local yy = ((y - 1 - step) % n) + 1
    local upto = (step == 0) and (x - 1) or nil
    local col = search_line_last(buf.lines[yy] or "", patlower, upto)
    if col then return yy, col end
  end
  return nil
end
local function do_search_jump(buf, dir, pat)
  -- NOT "dir>0 and search_fwd(...) or search_bwd(...)": and/or truncates a
  -- multi-return call to one value when it isn't the last operand, dropping x.
  local y, x
  if dir > 0 then y, x = search_fwd(buf, pat, buf.cy, buf.cx)
  else y, x = search_bwd(buf, pat, buf.cy, buf.cx) end
  if y then buf.cy, buf.cx = y, x; buf:clamp_caret() end
end
local function word_under_caret(buf)
  local l1, c1, l2, c2 = text_object(buf, "i", "w", buf.cy, buf.cx)
  if not l1 then return "" end
  return get_text(buf, l1, c1, l2, c2 + 1) -- text_object's end is inclusive
end

-- ---- insert-mode entry points (i a I A o O) ----------------------------------
-- One undo point per insert SESSION (pushed here, at entry), not per keystroke:
-- typed text inside insert mode never routes through this module at all (see
-- the header), so this is the only point that could snapshot it.
local function enter_insert(buf, which)
  push_undo(buf)
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

-- ---- single-key normal-mode commands (not motions or operators) -------------
-- Returns true only when it left NEW pending state behind (just "r", which
-- sets vs.await) so the caller knows not to reset_pending over it.
local function do_action(buf, vs, c, mode)
  if mode ~= "normal" then return end
  local n = eff_count(vs)
  if c == "i" or c == "a" or c == "I" or c == "A" or c == "o" or c == "O" then
    enter_insert(buf, c)
  elseif c == "x" then
    do_operator(buf, "d", buf.cy, buf.cx, buf.cy, buf.cx + n, "exc")
  elseif c == "D" then
    do_operator(buf, "d", buf.cy, buf.cx, buf.cy, line_len(buf, buf.cy) + 1, "exc")
  elseif c == "C" then
    do_operator(buf, "c", buf.cy, buf.cx, buf.cy, line_len(buf, buf.cy) + 1, "exc")
  elseif c == "s" then
    do_operator(buf, "c", buf.cy, buf.cx, buf.cy, buf.cx + n, "exc")
  elseif c == "r" then
    vs.await = "r"
    return true
  elseif c == "p" then do_paste(buf, true, n)
  elseif c == "P" then do_paste(buf, false, n)
  elseif c == "u" then for _ = 1, n do do_undo(buf) end
  elseif c == "v" then buf.edit_mode = "visual"; vs.anchor = { cy = buf.cy, cx = buf.cx }
  elseif c == "V" then buf.edit_mode = "vline"; vs.anchor = { cy = buf.cy, cx = buf.cx }
  elseif c == ":" then vs.prompt = { kind = "ex", text = "" }
  elseif c == "/" then vs.prompt = { kind = "fwd", text = "" }
  elseif c == "?" then vs.prompt = { kind = "bwd", text = "" }
  elseif c == "n" then
    local ls = vs.last_search
    if ls then do_search_jump(buf, ls.dir, ls.pat) end
  elseif c == "N" then
    local ls = vs.last_search
    if ls then do_search_jump(buf, -ls.dir, ls.pat) end
  elseif c == "*" or c == "#" then
    local w = word_under_caret(buf)
    if w ~= "" then
      local dir = (c == "*") and 1 or -1
      vs.last_search = { pat = w, dir = dir }
      do_search_jump(buf, dir, w)
    end
  end
end

-- ---- visual / visual-line ----------------------------------------------------
-- An action key ends (or acts on) the selection; returns nil to let the caller
-- try the key as a selection-extending motion instead.
local function visual_key(buf, vs, c)
  local linewise = buf.edit_mode == "vline"
  if c == "v" then
    if linewise then buf.edit_mode = "visual" else buf.edit_mode = "normal"; vs.anchor = nil end
    buf:clamp_caret()
    return true
  end
  if c == "V" then
    if linewise then buf.edit_mode = "normal"; vs.anchor = nil else buf.edit_mode = "vline" end
    buf:clamp_caret()
    return true
  end
  local OPS = { d = "d", x = "d", c = "c", s = "c", y = "y" }
  local op = OPS[c]
  if op then
    local a = vs.anchor
    do_operator(buf, op, a.cy, a.cx, buf.cy, buf.cx, linewise and "line" or "inc")
    vs.anchor = nil
    if op ~= "c" then buf.edit_mode = "normal" end
    return true
  end
  if c == "i" or c == "a" then
    vs.await, vs.textobj = "object", c
    return true
  end
  return nil
end

-- ---- the grammar dispatcher ---------------------------------------------------
-- Consumes one printable char in normal/visual/vline mode; mutates buf/vs.
local function dispatch(buf, vs, c)
  if vs.await == "r" then
    local cnt = eff_count(vs)
    reset_pending(vs)
    do_replace(buf, c, cnt)
    return
  end
  if vs.await == "object" then
    local ia, op, mode = vs.textobj, vs.op, buf.edit_mode
    reset_pending(vs)
    apply_object(buf, vs, ia, c, op, mode)
    return
  end
  if vs.find then
    local cmd, cnt, op = vs.find, eff_count(vs), vs.op
    reset_pending(vs)
    local ty, tx, kind = find_target(buf, cmd, c, cnt, false)
    if ty then
      vs.last_find = { cmd = cmd, char = c }
      if op then do_operator(buf, op, buf.cy, buf.cx, ty, tx, kind)
      else buf.cy, buf.cx = ty, tx; buf:clamp_caret() end
    end
    return
  end
  if vs.g then
    local cnt, op = vs.count, vs.op
    reset_pending(vs)
    if c == "g" then
      local ny = cnt and math.min(cnt, #buf.lines) or 1
      local tx = first_nonblank(buf, ny)
      if op then do_operator(buf, op, buf.cy, buf.cx, ny, tx, "line")
      else buf.cy, buf.cx = ny, tx; buf:clamp_caret() end
    end
    return
  end

  local mode = buf.edit_mode
  if mode == "visual" or mode == "vline" then
    if visual_key(buf, vs, c) then return end
  end

  -- counts (a leading "0" is the start-of-line motion, not a count digit)
  if c:match("^%d$") then
    local buffering = (vs.op and vs.opcount ~= nil) or (not vs.op and vs.count ~= nil)
    if not (c == "0" and not buffering) then
      if vs.op then vs.opcount = (vs.opcount or 0) * 10 + tonumber(c)
      else vs.count = (vs.count or 0) * 10 + tonumber(c) end
      return
    end
  end

  -- operators (visual mode already consumed d/c/y above)
  if mode == "normal" and (c == "d" or c == "c" or c == "y") then
    if vs.op == c then
      local n = eff_count(vs)
      op_linewise(buf, c, buf.cy, math.min(#buf.lines, buf.cy + n - 1))
      reset_pending(vs)
      return
    end
    if vs.op then reset_pending(vs); return end
    vs.op = c
    return
  end

  -- text object (i/a) after a pending operator
  if vs.op and (c == "i" or c == "a") then
    vs.await, vs.textobj = "object", c
    return
  end

  if c == "g" then vs.g = true; return end
  if c == "f" or c == "t" or c == "F" or c == "T" then vs.find = c; return end

  if MOTION_NAMES[c] then
    -- vim's cw quirk: cw/cW on a non-blank acts like ce/cE, so it does not
    -- also swallow the trailing whitespace a plain `w` target would.
    local mc = c
    if vs.op == "c" and (c == "w" or c == "W") then
      local cp = cp_at(buf.lines[buf.cy] or "", buf.cx - 1)
      if class(cp, c == "W") ~= 0 then mc = (c == "w") and "e" or "E" end
    end
    local had = had_count(vs)
    local n = eff_count(vs)
    local ty, tx, kind = resolve_motion(buf, vs, mc, n, had)
    if not ty then reset_pending(vs); return end
    if vs.op then do_operator(buf, vs.op, buf.cy, buf.cx, ty, tx, kind)
    else buf.cy, buf.cx = ty, tx; buf:clamp_caret() end
    reset_pending(vs)
    return
  end

  if vs.op then reset_pending(vs); return end -- pending operator, unrecognised key: cancel

  local set_pending = do_action(buf, vs, c, mode)
  if not set_pending then reset_pending(vs) end
end

-- ---- ":" / "/" / "?" prompt line ---------------------------------------------
-- Lives entirely off to the side (vs.prompt.text), never touching buf.lines,
-- so a draft in progress survives a search or an ex command untouched. Rendered
-- via Input:overlay_runs -- "the composer's own single-row render" (docs
-- section 5), the same mechanism as the completion menu / history search.
local function run_ex(buf, vs, line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "w" or line == "wq" or line == "x" then
    return true, "submit"
  elseif line == "q" then
    buf.lines, buf.cy, buf.cx = { "" }, 1, 1
    buf.edit_mode = "normal"
    return true
  elseif line == "set vim" then
    vimmode.set("on")
    buf.vim, buf.edit_mode = true, "insert"
    return true
  elseif line == "set novim" then
    vimmode.set("off")
    buf.vim, buf.edit_mode = false, "insert"
    return true
  elseif line:match("^%d+$") then
    local ny = math.max(1, math.min(#buf.lines, tonumber(line)))
    buf.cy, buf.cx = ny, first_nonblank(buf, ny)
    buf:clamp_caret()
    return true
  end
  return true -- unknown ex command: silent no-op, same as an unmapped key
end

local function run_search(buf, vs, kind, pat)
  if pat == "" and vs.last_search then pat = vs.last_search.pat end
  if pat == "" then return true end
  local dir = (kind == "fwd") and 1 or -1
  vs.last_search = { pat = pat, dir = dir }
  do_search_jump(buf, dir, pat)
  return true
end

local function handle_prompt(buf, vs, ev)
  local p = vs.prompt
  if ev.key == "esc" or ev.key == "escape" then vs.prompt = nil; return true end
  if ev.key == "backspace" then
    if p.text == "" then vs.prompt = nil else p.text = sub_cp(p.text, 1, ulen(p.text) - 1) end
    return true
  end
  if ev.key == "enter" then
    vs.prompt = nil
    if p.kind == "ex" then return run_ex(buf, vs, p.text) end
    return run_search(buf, vs, p.kind, p.text)
  end
  if ev.key == "char" and ev.char then p.text = p.text .. ev.char end
  return true
end

-- ---- the grammar --------------------------------------------------------------
-- Consumes an event; returns (handled, action). action is only ever "submit"
-- (from ":w"/":wq"/":x", handled by Input:key exactly like a real Enter).
function M.key(buf, ev)
  if ev.type ~= "key" then return false end
  local vs = vstate(buf)

  if vs.prompt then return handle_prompt(buf, vs, ev) end

  local mode = buf.edit_mode or "insert"

  if ev.key == "esc" or ev.key == "escape" then
    if mode == "normal" then
      -- A pending operator/count/find is cancelled without leaving normal mode
      -- (and without falling through to the cTUI's own Esc meaning); an
      -- otherwise-idle Esc is untouched -- still a no-op here, still falls
      -- through to abort a running turn / dismiss help.
      local was_pending = has_pending(vs)
      reset_pending(vs)
      return was_pending
    end
    buf._vs = nil -- leaving insert/visual/vline: drop all pending state, incl. any selection
    buf.edit_mode = "normal"
    buf:clamp_caret()
    return true
  end

  if mode == "normal" and ev.key == "ctrl" and (ev.char or ""):lower() == "r" then
    do_redo(buf)
    return true
  end

  if (mode ~= "normal" and mode ~= "visual" and mode ~= "vline") or ev.key ~= "char" then
    return false
  end

  dispatch(buf, vs, ev.char or "")
  return true
end

-- After a message is sent, return the buffer to its starting mode (insert for
-- "on", normal for "mandatory") and drop any visual selection, so the next
-- message does not inherit the mode or selection the last one ended in.
function M.after_submit(buf)
  buf.edit_mode = vimmode.starts_normal() and "normal" or "insert"
  buf._vs = nil
end

return M
