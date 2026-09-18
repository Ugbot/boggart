-- vim.lua -- the shared modal-editing core (docs/vim-unify.md), promoted from
-- tui/vim.lua (P1). Pure grammar over a BUFFER ADAPTER: every read and
-- mutation goes through the adapter `a` passed into M.key, so the same state
-- machine can drive any surface that implements the interface (today: the
-- cTUI composer via lua/tui/vim.lua). The core never indexes a raw line
-- string itself -- it walks positions via a:next_pos/a:prev_pos and reads via
-- a:get_char, so byte-vs-codepoint column indexing is entirely the adapter's
-- problem, not this file's.
--
-- The adapter interface (docs/vim-unify.md section 1), everything this file
-- calls on `a`:
--   reading:  line_count, get_line, line_len, first_nonblank, get_char,
--             next_pos, prev_pos, get_text
--   cursor:   get_cursor, set_cursor, clamp_caret, mode, set_mode,
--             set_selection, clear_selection
--   mutation: delete_range, insert_at, set_lines
--   undo/reg: begin_undo, end_undo, undo, redo, get_register, set_register
--   optional: motion (core supplies the default below), on_command_done,
--             set_enabled (a TUI-only extension for ":set vim"/":set novim")
--
-- Phases 1-4 (docs/tui-vim.md section 8): normal/insert + core motions (incl.
-- W B E and { } paragraph jumps), operators d c y with motions/doubled forms,
-- x D C s r, p P over the unnamed register, u/Ctrl-R undo, text objects
-- iw/aw, i"/a" (and ' `), brackets, ip/ap, visual + visual-line with
-- operators over the selection, / ? n N * # substring search, and a minimal
-- ex line (:w :q :wq :x :{N} :set vim|novim).
--
-- Deferred, on purpose: named/numbered registers, macros, dot-repeat, marks,
-- visual-block, multi-cursor -- adapter-side extensions for a later phase
-- (docs/vim-unify.md section 2/3, DocView).
local M = {}

local vimmode = require("vimmode")

-- ---- pending state for multi-key sequences -----------------------------------
-- Attached directly to the adapter instance, which is bound to (and persists
-- for) one buffer -- the same trick tui/vim.lua used to play with buf._vs.
local function vstate(a)
  a._vs = a._vs or {}
  return a._vs
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

-- ---- word classing (w b e / W B E) -------------------------------------------
-- Class 0 = blank or off-the-end-of-line, 1 = word (or, `big`, any non-blank),
-- 2 = punctuation. A char one past a line's end is "" from get_char, which
-- decodes to codepoint 0 and so falls into class 0 for free -- that is what
-- lets word motions step across line breaks without special-casing them.
local function is_word(cp)
  return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90)
      or (cp >= 97 and cp <= 122) or cp == 95
end
local function cp_of(ch)
  if ch == "" then return 0 end
  if not utf8 then return ch:byte(1) or 0 end
  local ok, cp = pcall(utf8.codepoint, ch)
  return ok and cp or 0
end
local function class(cp, big)
  if cp == 0 or cp == 32 or cp == 9 then return 0 end
  if big then return 1 end
  if is_word(cp) then return 1 end
  return 2
end
local function class_at(a, y, x, big) return class(cp_of(a:get_char(y, x)), big) end

local function is_blank(a, y) return (a:get_line(y)):match("^%s*$") ~= nil end

-- Pure position computers: given the adapter's CURRENT caret as the start,
-- return the target (ty, tx) without moving the caret. Used both as a direct
-- motion (caller moves the caret) and as an operator target.
local function pos_w(a, count, big)
  local y, x = a:get_cursor()
  for _ = 1, count do
    local c0 = class_at(a, y, x, big)
    if c0 ~= 0 then
      while true do
        local ny, nx = a:next_pos(y, x)
        if not ny then break end
        y, x = ny, nx
        if class_at(a, y, x, big) ~= c0 then break end
      end
    end
    while class_at(a, y, x, big) == 0 do
      local ny, nx = a:next_pos(y, x)
      if not ny then break end
      y, x = ny, nx
    end
  end
  return y, x
end
local function pos_e(a, count, big)
  local y, x = a:get_cursor()
  for _ = 1, count do
    local ny, nx = a:next_pos(y, x)
    if not ny then break end
    y, x = ny, nx
    while class_at(a, y, x, big) == 0 do
      local ny2, nx2 = a:next_pos(y, x)
      if not ny2 then break end
      y, x = ny2, nx2
    end
    local c = class_at(a, y, x, big)
    while true do
      local ny2, nx2 = a:next_pos(y, x)
      if not ny2 or class_at(a, ny2, nx2, big) ~= c then break end
      y, x = ny2, nx2
    end
  end
  return y, x
end
local function pos_b(a, count, big)
  local y, x = a:get_cursor()
  for _ = 1, count do
    local py, px = a:prev_pos(y, x)
    if not py then break end
    y, x = py, px
    while class_at(a, y, x, big) == 0 do
      local py2, px2 = a:prev_pos(y, x)
      if not py2 then break end
      y, x = py2, px2
    end
    local c = class_at(a, y, x, big)
    while true do
      local py2, px2 = a:prev_pos(y, x)
      if not py2 or class_at(a, py2, px2, big) ~= c then break end
      y, x = py2, px2
    end
  end
  return y, x
end

-- ---- operators: d c y over a char range or whole lines -----------------------
local function linewise_text(a, l1, l2)
  local t = {}
  for i = l1, l2 do t[#t + 1] = a:get_line(i) end
  return table.concat(t, "\n") .. "\n"
end

local function op_linewise(a, op, minl, maxl)
  minl, maxl = math.max(1, minl), math.min(a:line_count(), maxl)
  local text = linewise_text(a, minl, maxl)
  if op == "y" then
    a:set_register(nil, text, true)
    a:set_cursor(minl, a:first_nonblank(minl))
    a:clamp_caret()
    return
  end
  a:begin_undo()
  a:set_register(nil, text, true)
  local indent = a:get_line(minl):match("^[ \t]*") or ""
  if op == "d" then
    a:set_lines(minl, maxl, {})
    local ny = math.min(minl, a:line_count())
    a:set_cursor(ny, a:first_nonblank(ny))
  else -- c: replace the block with one fresh (indented) line and start typing
    a:set_lines(minl, maxl, { indent })
    a:set_cursor(minl, a:line_len(minl) + 1)
    a:set_mode("insert")
  end
  a:end_undo()
  a:clamp_caret()
end

-- Apply `op` over [l1,c1)..(l2,c2] (order-independent) per `kind`:
-- "exc" -- range is already the exclusive [minc, maxc); "inc" -- maxc is the
-- last INCLUDED column, extend it by one position (clamped to the line) to
-- make it exclusive; "line" -- whole lines, delegate to op_linewise.
local function do_operator(a, op, l1, c1, l2, c2, kind)
  local a_first = (l1 < l2) or (l1 == l2 and c1 <= c2)
  local minl, minc, maxl, maxc
  if a_first then minl, minc, maxl, maxc = l1, c1, l2, c2
  else minl, minc, maxl, maxc = l2, c2, l1, c1 end
  if kind == "line" then return op_linewise(a, op, minl, maxl) end

  if kind == "inc" then
    local n = a:line_len(maxl)
    maxc = (maxc <= n) and (maxc + 1) or (n + 1)
  end

  local text = a:get_text(minl, minc, maxl, maxc)
  if op == "y" then
    a:set_register(nil, text, false)
    a:set_cursor(minl, minc)
    a:clamp_caret()
    return
  end
  a:begin_undo()
  a:set_register(nil, text, false)
  a:delete_range(minl, minc, maxl, maxc)
  a:end_undo()
  a:set_cursor(minl, minc)
  a:clamp_caret()
  if op == "c" then a:set_mode("insert") end
end

-- ---- text objects: iw aw i"/a" i(/a( ip/ap -----------------------------------
local function scan_back_open(a, y, x, open, close)
  local ly, lx, depth = y, x, 0
  while true do
    local ch = a:get_char(ly, lx)
    if ch == close and not (ly == y and lx == x) then depth = depth + 1
    elseif ch == open then
      if depth == 0 then return ly, lx end
      depth = depth - 1
    end
    local py, px = a:prev_pos(ly, lx)
    if not py then return nil end
    ly, lx = py, px
  end
end
local function scan_fwd_close(a, y, x, open, close)
  local ly, lx, depth = y, x, 0
  while true do
    local ch = a:get_char(ly, lx)
    if ch == open and not (ly == y and lx == x) then depth = depth + 1
    elseif ch == close then
      if depth == 0 then return ly, lx end
      depth = depth - 1
    end
    local ny, nx = a:next_pos(ly, lx)
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
local function text_object(a, ia, obj, y, x)
  if obj == "w" or obj == "W" then
    local big = (obj == "W")
    local function cls(yy, xx) return class_at(a, yy, xx, big) end
    local c0 = cls(y, x)
    local ay, ax, by, bx = y, x, y, x
    if c0 ~= 0 then
      while true do
        local py, px = a:prev_pos(ay, ax)
        if not py or py ~= y or cls(py, px) ~= c0 then break end
        ay, ax = py, px
      end
      while true do
        local ny, nx = a:next_pos(by, bx)
        if not ny or ny ~= y or cls(ny, nx) ~= c0 then break end
        by, bx = ny, nx
      end
    end
    if ia == "a" then
      local ey, ex, extended = by, bx, false
      while true do
        local ny, nx = a:next_pos(ey, ex)
        if not ny or ny ~= y or cls(ny, nx) ~= 0 then break end
        ey, ex, extended = ny, nx, true
      end
      if extended then by, bx = ey, ex
      else
        while true do
          local py, px = a:prev_pos(ay, ax)
          if not py or py ~= y or cls(py, px) ~= 0 then break end
          ay, ax = py, px
        end
      end
    end
    return y, ax, y, bx, false

  elseif PAIRS[obj] then
    local open, close = PAIRS[obj][1], PAIRS[obj][2]
    local ol, oc = scan_back_open(a, y, x, open, close)
    if not ol then return nil end
    local cl, cc = scan_fwd_close(a, y, x, open, close)
    if not cl then return nil end
    if ia == "a" then return ol, oc, cl, cc, false end
    local il, ic = a:next_pos(ol, oc)
    if not il then return nil end
    local jl, jc = a:prev_pos(cl, cc)
    if not jl then return nil end
    if il > jl or (il == jl and ic > jc) then return nil end -- empty pair "()"
    return il, ic, jl, jc, false

  elseif QUOTES[obj] then
    local n = a:line_len(y)
    local positions = {}
    for i = 1, n do if a:get_char(y, i) == obj then positions[#positions + 1] = i end end
    for i = 1, #positions - 1, 2 do
      local qa, qb = positions[i], positions[i + 1]
      if x <= qb then
        if ia == "a" then return y, qa, y, qb, false end
        local il, ic = a:next_pos(y, qa)
        local jl, jc = a:prev_pos(y, qb)
        if not il or not jl or il ~= y or jl ~= y then return nil end
        if il > jl or (il == jl and ic > jc) then return nil end
        return il, ic, jl, jc, false
      end
    end
    return nil

  elseif obj == "p" then
    local total = a:line_count()
    local ay, by = y, y
    local on_blank = is_blank(a, y)
    while ay > 1 and is_blank(a, ay - 1) == on_blank do ay = ay - 1 end
    while by < total and is_blank(a, by + 1) == on_blank do by = by + 1 end
    if ia == "a" and not on_blank then
      while by < total and is_blank(a, by + 1) do by = by + 1 end
    end
    return ay, 1, by, 1, true
  end
  return nil
end

-- Resolve a text-object range under the caret and either feed the pending
-- operator, or (in visual/vline mode) set it as the selection.
local function apply_object(a, vs, ia, obj, op, mode)
  local cy, cx = a:get_cursor()
  local l1, c1, l2, c2, linewise = text_object(a, ia, obj, cy, cx)
  if not l1 then return end
  if op then
    do_operator(a, op, l1, c1, l2, c2, linewise and "line" or "inc")
  elseif mode == "visual" or mode == "vline" then
    vs.anchor = { cy = l1, cx = c1 }
    a:set_cursor(l2, c2)
    a:clamp_caret()
    a:set_selection(l1, c1, l2, c2)
  end
end

-- ---- r{char} replace, p/P paste -----------------------------------------------
local function do_replace(a, ch, count)
  if ch == "" then return end
  local cy, cx = a:get_cursor()
  local n = a:line_len(cy)
  if n - cx + 1 < count then return end -- vim: r past EOL is a no-op
  a:begin_undo()
  a:delete_range(cy, cx, cy, cx + count)
  a:insert_at(cy, cx, ch:rep(count))
  a:end_undo()
  a:set_cursor(cy, cx + count - 1)
  a:clamp_caret()
end

local function do_paste(a, after, count)
  local text, linewise = a:get_register()
  if not text or text == "" then return end
  if count and count > 1 then text = text:rep(count) end
  a:begin_undo()
  if linewise then
    local body = text:gsub("\n$", "")
    local newlines = {}
    for ln in (body .. "\n"):gmatch("(.-)\n") do newlines[#newlines + 1] = ln end
    local cy = a:get_cursor()
    local at = after and (cy + 1) or cy
    a:set_lines(at, at - 1, newlines) -- y2 < y1: insert before `at`, nothing removed
    a:set_cursor(at, a:first_nonblank(at))
  else
    local il, ic = a:get_cursor()
    if after then
      local n = a:line_len(il)
      if ic <= n then ic = ic + 1 end
    end
    local ey, ex = a:insert_at(il, ic, text)
    if ey then a:set_cursor(ey, math.max(1, ex - 1)) end
  end
  a:end_undo()
  a:clamp_caret()
end

-- ---- find-in-line (f t F T, repeated by ; and ,) -----------------------------
-- Pure: returns the target (ty, tx, kind) without moving the caret, walking
-- one position at a time via next_pos/prev_pos so it never leaves row y and
-- never assumes columns are contiguous integers. `nudge` (a `;`/`,` repeat of
-- t/T) starts one position further so the search does not immediately
-- re-match the character it is already sitting beside.
local function find_target(a, cmd, ch, count, nudge)
  if ch == "" then return nil end
  local fwd = (cmd == "f" or cmd == "t")
  local till = (cmd == "t" or cmd == "T")
  local y, pos = a:get_cursor()
  local moved = false
  for _ = 1, count do
    local step = (nudge and till) and 2 or 1
    local px, ok = pos, true
    for _ = 1, step do
      -- NOT "fwd and a:next_pos(...) or a:prev_pos(...)": and/or truncates a
      -- multi-return call to one value when it isn't the LAST operand,
      -- dropping the second return whenever the "next_pos" branch is taken.
      local ny, nx
      if fwd then ny, nx = a:next_pos(y, px) else ny, nx = a:prev_pos(y, px) end
      if not ny or ny ~= y then ok = false; break end
      px = nx
    end
    local found
    if ok then
      local sx = px
      while true do
        if a:get_char(y, sx) == ch then found = sx; break end
        local ny, nx
        if fwd then ny, nx = a:next_pos(y, sx) else ny, nx = a:prev_pos(y, sx) end
        if not ny or ny ~= y then break end
        sx = nx
      end
    end
    if not found then break end
    if till then
      local ty, tx
      if fwd then ty, tx = a:prev_pos(y, found) else ty, tx = a:next_pos(y, found) end
      pos = (ty == y) and tx or found -- found at the line edge: stay put
    else
      pos = found
    end
    nudge, moved = false, true
  end
  if not moved then return nil end
  return y, pos, fwd and "inc" or "exc"
end

local FLIP = { f = "F", F = "f", t = "T", T = "t" }
local function repeat_find_target(a, vs, dir, count)
  local lf = vs.last_find
  if not lf then return nil end
  return find_target(a, dir < 0 and FLIP[lf.cmd] or lf.cmd, lf.char, count, true)
end

-- ---- paragraph motion ({ }) -- next/previous blank-line boundary, exclusive --
local function motion_para_target(a, dir, count)
  local y = a:get_cursor()
  local total = a:line_count()
  for _ = 1, count do
    local ny = y
    repeat ny = ny + dir until ny < 1 or ny > total or is_blank(a, ny)
    y = math.max(1, math.min(total, ny))
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
-- h/l/j/k step the adapter's own column/line units directly -- the naive
-- default docs/vim-unify.md flags as a:motion's override point for a surface
-- whose columns are not one unit per character (DocView's byte offsets).
local function resolve_motion(a, vs, c, n, had)
  local y, x = a:get_cursor()
  if c == "h" then return y, math.max(1, x - n), "exc"
  elseif c == "l" then return y, x + n, "exc"
  elseif c == "j" then return math.min(a:line_count(), y + n), x, "line"
  elseif c == "k" then return math.max(1, y - n), x, "line"
  elseif c == "w" then local ty, tx = pos_w(a, n, false); return ty, tx, "exc"
  elseif c == "W" then local ty, tx = pos_w(a, n, true); return ty, tx, "exc"
  elseif c == "b" then local ty, tx = pos_b(a, n, false); return ty, tx, "exc"
  elseif c == "B" then local ty, tx = pos_b(a, n, true); return ty, tx, "exc"
  elseif c == "e" then local ty, tx = pos_e(a, n, false); return ty, tx, "inc"
  elseif c == "E" then local ty, tx = pos_e(a, n, true); return ty, tx, "inc"
  elseif c == "0" then return y, 1, "exc"
  elseif c == "^" then return y, a:first_nonblank(y), "exc"
  elseif c == "$" then
    local ny = math.min(a:line_count(), y + n - 1)
    return ny, a:line_len(ny) + 1, "exc" -- +1 is already the exclusive boundary
  elseif c == "{" then return motion_para_target(a, -1, n)
  elseif c == "}" then return motion_para_target(a, 1, n)
  elseif c == "G" then
    local ny = had and math.min(n, a:line_count()) or a:line_count()
    return ny, a:first_nonblank(ny), "line"
  elseif c == ";" then return repeat_find_target(a, vs, 1, n)
  elseif c == "," then return repeat_find_target(a, vs, -1, n)
  end
  return nil
end

-- ---- search: / ? n N * # (plain substring, case-insensitive) ----------------
-- Character-by-character, via get_char/next_pos, never Lua's byte-based
-- string.find -- so this never has to convert a byte offset back to a column.
local function pat_chars(pat)
  local chars = {}
  if utf8 then
    for _, cp in utf8.codes(pat) do chars[#chars + 1] = utf8.char(cp):lower() end
  else
    for i = 1, #pat do chars[#chars + 1] = pat:sub(i, i):lower() end
  end
  return chars
end
-- Does `chars` (lower-cased, one entry per character) match starting at
-- (row, x)? Never crosses out of `row`.
local function match_at(a, row, x, chars)
  local px = x
  for i = 1, #chars do
    local ch = a:get_char(row, px)
    if ch == "" or ch:lower() ~= chars[i] then return false end
    if i < #chars then
      local ny, nx = a:next_pos(row, px)
      if not ny or ny ~= row then return false end
      px = nx
    end
  end
  return true
end
local function search_row(a, row, chars, from_x)
  local x = from_x
  while x do
    if match_at(a, row, x, chars) then return x end
    local ny, nx = a:next_pos(row, x)
    if not ny or ny ~= row then break end
    x = nx
  end
  return nil
end
local function search_row_last(a, row, chars, upto_x)
  local best, x = nil, 1
  while x do
    if upto_x and x > upto_x then break end
    if match_at(a, row, x, chars) then best = x end
    local ny, nx = a:next_pos(row, x)
    if not ny or ny ~= row then break end
    x = nx
  end
  return best
end
local function search_fwd(a, chars, y, x)
  local n = a:line_count()
  if n == 0 then return nil end
  for step = 0, n do
    local yy = ((y - 1 + step) % n) + 1
    local col
    if step == 0 then
      local ny, nx = a:next_pos(y, x)
      if ny == y then col = search_row(a, yy, chars, nx) end
    else
      col = search_row(a, yy, chars, 1)
    end
    if col then return yy, col end
  end
  return nil
end
local function search_bwd(a, chars, y, x)
  local n = a:line_count()
  if n == 0 then return nil end
  for step = 0, n do
    local yy = ((y - 1 - step) % n) + 1
    if step == 0 then
      local py, px = a:prev_pos(y, x)
      if py == y then
        local col = search_row_last(a, yy, chars, px)
        if col then return yy, col end
      end
    else
      local col = search_row_last(a, yy, chars, nil)
      if col then return yy, col end
    end
  end
  return nil
end
local function do_search_jump(a, dir, pat)
  local chars = pat_chars(pat)
  if #chars == 0 then return end
  local y, x = a:get_cursor()
  local ty, tx
  if dir > 0 then ty, tx = search_fwd(a, chars, y, x)
  else ty, tx = search_bwd(a, chars, y, x) end
  if ty then a:set_cursor(ty, tx); a:clamp_caret() end
end
local function word_under_caret(a)
  local cy, cx = a:get_cursor()
  local l1, c1, l2, c2 = text_object(a, "i", "w", cy, cx)
  if not l1 then return "" end
  return a:get_text(l1, c1, l2, c2 + 1) -- text_object's end is inclusive
end

-- ---- insert-mode entry points (i a I A o O) ----------------------------------
-- One undo point per insert SESSION (pushed here, at entry), not per keystroke:
-- typed text inside insert mode never routes through this module at all (only
-- Esc, Ctrl-R and, in normal/visual/vline mode, plain char keys are claimed),
-- so this is the only point that could snapshot it.
local function enter_insert(a, which)
  a:begin_undo()
  local cy, cx = a:get_cursor()
  if which == "a" then
    a:set_cursor(cy, math.min(cx + 1, a:line_len(cy) + 1))
  elseif which == "I" then
    a:set_cursor(cy, a:first_nonblank(cy))
  elseif which == "A" then
    a:set_cursor(cy, a:line_len(cy) + 1)
  elseif which == "o" then
    a:insert_at(cy, a:line_len(cy) + 1, "\n")
    a:set_cursor(cy + 1, 1)
  elseif which == "O" then
    a:insert_at(cy, 1, "\n")
    a:set_cursor(cy, 1)
  end
  -- "i": caret already sits before the target column, nothing to move.
  a:end_undo()
  a:set_mode("insert")
  a:clamp_caret()
end

-- ---- single-key normal-mode commands (not motions or operators) -------------
-- Returns true only when it left NEW pending state behind (just "r", which
-- sets vs.await) so the caller knows not to reset_pending over it.
local function do_action(a, vs, c, mode)
  if mode ~= "normal" then return end
  local n = eff_count(vs)
  local cy, cx = a:get_cursor()
  if c == "i" or c == "a" or c == "I" or c == "A" or c == "o" or c == "O" then
    enter_insert(a, c)
  elseif c == "x" then
    do_operator(a, "d", cy, cx, cy, cx + n, "exc")
  elseif c == "D" then
    do_operator(a, "d", cy, cx, cy, a:line_len(cy) + 1, "exc")
  elseif c == "C" then
    do_operator(a, "c", cy, cx, cy, a:line_len(cy) + 1, "exc")
  elseif c == "s" then
    do_operator(a, "c", cy, cx, cy, cx + n, "exc")
  elseif c == "r" then
    vs.await = "r"
    return true
  elseif c == "p" then do_paste(a, true, n)
  elseif c == "P" then do_paste(a, false, n)
  elseif c == "u" then for _ = 1, n do a:undo() end
  elseif c == "v" then
    a:set_mode("visual"); vs.anchor = { cy = cy, cx = cx }; a:set_selection(cy, cx, cy, cx)
  elseif c == "V" then
    a:set_mode("vline"); vs.anchor = { cy = cy, cx = cx }; a:set_selection(cy, cx, cy, cx)
  elseif c == ":" then vs.prompt = { kind = "ex", text = "" }
  elseif c == "/" then vs.prompt = { kind = "fwd", text = "" }
  elseif c == "?" then vs.prompt = { kind = "bwd", text = "" }
  elseif c == "n" then
    local ls = vs.last_search
    if ls then do_search_jump(a, ls.dir, ls.pat) end
  elseif c == "N" then
    local ls = vs.last_search
    if ls then do_search_jump(a, -ls.dir, ls.pat) end
  elseif c == "*" or c == "#" then
    local w = word_under_caret(a)
    if w ~= "" then
      local dir = (c == "*") and 1 or -1
      vs.last_search = { pat = w, dir = dir }
      do_search_jump(a, dir, w)
    end
  end
end

-- ---- visual / visual-line ----------------------------------------------------
-- An action key ends (or acts on) the selection; returns nil to let the caller
-- try the key as a selection-extending motion instead.
local function visual_key(a, vs, c)
  local linewise = a:mode() == "vline"
  if c == "v" then
    if linewise then a:set_mode("visual")
    else a:set_mode("normal"); vs.anchor = nil; a:clear_selection() end
    a:clamp_caret()
    return true
  end
  if c == "V" then
    if linewise then a:set_mode("normal"); vs.anchor = nil; a:clear_selection()
    else a:set_mode("vline") end
    a:clamp_caret()
    return true
  end
  local OPS = { d = "d", x = "d", c = "c", s = "c", y = "y" }
  local op = OPS[c]
  if op then
    local an = vs.anchor
    local cy, cx = a:get_cursor()
    do_operator(a, op, an.cy, an.cx, cy, cx, linewise and "line" or "inc")
    vs.anchor = nil
    a:clear_selection()
    if op ~= "c" then a:set_mode("normal") end
    return true
  end
  if c == "i" or c == "a" then
    vs.await, vs.textobj = "object", c
    return true
  end
  return nil
end

-- ---- the grammar dispatcher ---------------------------------------------------
-- Consumes one printable char in normal/visual/vline mode; mutates via `a`.
local function dispatch(a, vs, c)
  if vs.await == "r" then
    local cnt = eff_count(vs)
    reset_pending(vs)
    do_replace(a, c, cnt)
    return
  end
  if vs.await == "object" then
    local ia, op, mode = vs.textobj, vs.op, a:mode()
    reset_pending(vs)
    apply_object(a, vs, ia, c, op, mode)
    return
  end
  if vs.find then
    local cmd, cnt, op = vs.find, eff_count(vs), vs.op
    reset_pending(vs)
    local ty, tx, kind = find_target(a, cmd, c, cnt, false)
    if ty then
      vs.last_find = { cmd = cmd, char = c }
      if op then
        local cy, cx = a:get_cursor()
        do_operator(a, op, cy, cx, ty, tx, kind)
      else a:set_cursor(ty, tx); a:clamp_caret() end
    end
    return
  end
  if vs.g then
    local cnt, op = vs.count, vs.op
    reset_pending(vs)
    if c == "g" then
      local ny = cnt and math.min(cnt, a:line_count()) or 1
      local tx = a:first_nonblank(ny)
      if op then
        local cy, cx = a:get_cursor()
        do_operator(a, op, cy, cx, ny, tx, "line")
      else a:set_cursor(ny, tx); a:clamp_caret() end
    end
    return
  end

  local mode = a:mode()
  if mode == "visual" or mode == "vline" then
    if visual_key(a, vs, c) then return end
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
      local cy = a:get_cursor()
      op_linewise(a, c, cy, math.min(a:line_count(), cy + n - 1))
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
      local cy, cx = a:get_cursor()
      if class(cp_of(a:get_char(cy, cx)), c == "W") ~= 0 then mc = (c == "w") and "e" or "E" end
    end
    local had = had_count(vs)
    local n = eff_count(vs)
    local ty, tx, kind = resolve_motion(a, vs, mc, n, had)
    if not ty then reset_pending(vs); return end
    if vs.op then
      local cy, cx = a:get_cursor()
      do_operator(a, vs.op, cy, cx, ty, tx, kind)
    else a:set_cursor(ty, tx); a:clamp_caret() end
    reset_pending(vs)
    return
  end

  if vs.op then reset_pending(vs); return end -- pending operator, unrecognised key: cancel

  local set_pending = do_action(a, vs, c, mode)
  if not set_pending then reset_pending(vs) end
end

-- ---- ":" / "/" / "?" prompt line ---------------------------------------------
-- Lives entirely off to the side (vs.prompt.text), never touching the buffer,
-- so a draft in progress survives a search or an ex command untouched. This is
-- scratch text, not buffer content, so it is edited with plain UTF-8 chopping
-- rather than going through the adapter.
local function drop_last_char(s)
  if s == "" then return s end
  if not utf8 then return s:sub(1, #s - 1) end
  local n = utf8.len(s)
  if not n or n <= 1 then return "" end
  local off = utf8.offset(s, n)
  return off and s:sub(1, off - 1) or s:sub(1, #s - 1)
end

local function run_ex(a, vs, line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "w" or line == "wq" or line == "x" then
    return true, "submit"
  elseif line == "q" then
    a:set_lines(1, a:line_count(), { "" })
    a:set_cursor(1, 1)
    a:set_mode("normal")
    return true
  elseif line == "set vim" then
    vimmode.set("on")
    if a.set_enabled then a:set_enabled(true) end
    a:set_mode("insert")
    return true
  elseif line == "set novim" then
    vimmode.set("off")
    if a.set_enabled then a:set_enabled(false) end
    a:set_mode("insert")
    return true
  elseif line:match("^%d+$") then
    local ny = math.max(1, math.min(a:line_count(), tonumber(line)))
    a:set_cursor(ny, a:first_nonblank(ny))
    a:clamp_caret()
    return true
  end
  return true -- unknown ex command: silent no-op, same as an unmapped key
end

local function run_search(a, vs, kind, pat)
  if pat == "" and vs.last_search then pat = vs.last_search.pat end
  if pat == "" then return true end
  local dir = (kind == "fwd") and 1 or -1
  vs.last_search = { pat = pat, dir = dir }
  do_search_jump(a, dir, pat)
  return true
end

local function handle_prompt(a, vs, ev)
  local p = vs.prompt
  if ev.key == "esc" or ev.key == "escape" then vs.prompt = nil; return true end
  if ev.key == "backspace" then
    if p.text == "" then vs.prompt = nil else p.text = drop_last_char(p.text) end
    return true
  end
  if ev.key == "enter" then
    vs.prompt = nil
    if p.kind == "ex" then return run_ex(a, vs, p.text) end
    return run_search(a, vs, p.kind, p.text)
  end
  if ev.key == "char" and ev.char then p.text = p.text .. ev.char end
  return true
end

-- ---- the grammar --------------------------------------------------------------
-- Consumes an event; returns (handled, action). action is only ever "submit"
-- (from ":w"/":wq"/":x", handled by the surface exactly like a real Enter).
function M.key(a, ev)
  if ev.type ~= "key" then return false end
  local vs = vstate(a)

  if vs.prompt then return handle_prompt(a, vs, ev) end

  local mode = a:mode() or "insert"

  if ev.key == "esc" or ev.key == "escape" then
    if mode == "normal" then
      -- A pending operator/count/find is cancelled without leaving normal
      -- mode; an otherwise-idle Esc is untouched -- still a no-op here, still
      -- falls through to whatever the surface's own Esc means.
      local was_pending = has_pending(vs)
      reset_pending(vs)
      return was_pending
    end
    a._vs = nil -- leaving insert/visual/vline: drop all pending state, incl. any selection
    a:set_mode("normal")
    a:clear_selection()
    a:clamp_caret()
    return true
  end

  if mode == "normal" and ev.key == "ctrl" and (ev.char or ""):lower() == "r" then
    a:redo()
    return true
  end

  if (mode ~= "normal" and mode ~= "visual" and mode ~= "vline") or ev.key ~= "char" then
    return false
  end

  dispatch(a, vs, ev.char or "")
  if a.on_command_done and a:mode() == "normal" and not has_pending(vs) then
    a:on_command_done()
  end
  return true
end

-- After a message is sent, return the buffer to its starting mode (insert for
-- "on", normal for "mandatory") and drop any visual selection, so the next
-- message does not inherit the mode or selection the last one ended in.
function M.after_submit(a)
  a._vs = nil
  a:set_mode(vimmode.starts_normal() and "normal" or "insert")
end

return M
